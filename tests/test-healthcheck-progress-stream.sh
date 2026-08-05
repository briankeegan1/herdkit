#!/usr/bin/env bash
# test-healthcheck-progress-stream.sh — hermetic proof for HERD-533 leg 1 (STREAM).
#
# ROOT CAUSE (pinned live 2026-08-05): scripts/herd/healthcheck.sh's run_heavy captured the WHOLE
# $HEALTHCHECK_CMD suite via a bare command substitution — nothing reached its own stdout (and thus
# the async health worker's tailable log) until the entire suite had already exited. A ~9-minute suite
# therefore left its log at 0 bytes for its whole runtime — indistinguishable from wedged.
#
# The fix tees $HEALTHCHECK_CMD's raw output into HEALTHCHECK_PROGRESS_LOG (HERD-494's convention: the
# async worker sets this to a per-run companion path) AS THE SUITE RUNS, while $out/$rc — and so the
# final verdict text/exit code healthcheck.sh prints — stay byte-identical, computed exactly as before.
#
# Covers:
#   (1) STREAM: with HEALTHCHECK_PROGRESS_LOG set, the companion file is NON-EMPTY while the suite is
#       still running (not merely once it exits) — the load-bearing "growing log during the run" proof.
#   (2) BYTE-IDENTICAL VERDICT: the final exit code + header text (clean) match today's contract with
#       the env var set.
#   (3) CODE ERROR: a failing suite still exits 1 with "❌ CODE ERROR" and 'not ok' reaches the log —
#       proving `set -o pipefail` (not tee's own rc) drives healthcheck.sh's exit code.
#   (4) OFF BY DEFAULT: with HEALTHCHECK_PROGRESS_LOG unset (every caller except the async worker),
#       behavior — exit code + verdict header — is unchanged; no companion file is fabricated.
#
# Fully hermetic: a throwaway git repo, a stub HEALTHCHECK_CMD emitting staggered TAP, NO network,
# NO model. Run:  bash tests/test-healthcheck-progress-stream.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HC="$HERE/../scripts/herd/healthcheck.sh"
[ -f "$HC" ] || { echo "healthcheck.sh not found at $HC" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git required to run this test" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# poll_true <deadline-ticks> <cmd...> — 0 iff <cmd> becomes true within deadline (ticks of 0.05s).
poll_true() { local n="$1"; shift; local i=0; while [ "$i" -lt "$n" ]; do "$@" && return 0; sleep 0.05; i=$((i+1)); done; return 1; }

# ── A worktree that looks like a real repo ─────────────────────────────────
WT="$T/wt"; mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" checkout -q -b main 2>/dev/null || git -C "$WT" checkout -q main
git -C "$WT" config user.email t@t.test
git -C "$WT" config user.name  herd-test
echo seed > "$WT/seed.txt"; git -C "$WT" add seed.txt; git -C "$WT" commit -qm seed

# A stub project health command that STAGGERS its TAP output (~1s total) so a poll mid-run can prove
# the progress companion grew BEFORE the stub exits. CLEAN_STUB always passes; CODEERROR_STUB fails.
CLEAN_STUB="$T/stub-clean.sh"
cat > "$CLEAN_STUB" <<'STUB'
#!/usr/bin/env bash
printf '1..5\n'
for i in 1 2 3 4 5; do
  sleep 0.15
  printf 'ok %d test-%d\n' "$i" "$i"
done
exit 0
STUB
chmod +x "$CLEAN_STUB"

CODEERROR_STUB="$T/stub-red.sh"
cat > "$CODEERROR_STUB" <<'STUB'
#!/usr/bin/env bash
printf '1..3\n'
sleep 0.15; printf 'ok 1 test-1\n'
sleep 0.15; printf 'not ok 2 test-2 — deliberate failure\n'
sleep 0.15; printf 'ok 3 test-3\n'
exit 1
STUB
chmod +x "$CODEERROR_STUB"

CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
write_cfg() {  # write_cfg <stub-path>
  {
    printf 'PROJECT_ROOT="%s"\n'  "$WT"
    printf 'WORKTREES_DIR="%s"\n' "$T/trees"
    printf 'DEFAULT_BRANCH="main"\n'
    printf 'WORKSPACE_NAME="ptest"\n'
    printf 'HEALTHCHECK_CMD="bash %s"\n' "$1"
  } > "$CFG"
}

# ── (1)+(2) STREAM + byte-identical clean verdict ──────────────────────────
write_cfg "$CLEAN_STUB"
PROG="$T/prog1.log"; FULLOUT="$T/full1.log"
rm -f "$PROG"
HEALTHCHECK_PROGRESS_LOG="$PROG" bash "$HC" "$WT" --heavy > "$FULLOUT" 2>&1 &
bg=$!
poll_true 60 kill -0 "$bg" || fail "(1) background healthcheck.sh never started"
# The suite runs ~0.75s; assert the companion grows to non-zero WHILE the job is still alive.
grew_while_running=1
poll_true 40 bash -c '[ -s "'"$PROG"'" ]' && kill -0 "$bg" 2>/dev/null && grew_while_running=0
wait "$bg"; rc=$?
[ "$grew_while_running" -eq 0 ] \
  || fail "(1) HEALTHCHECK_PROGRESS_LOG never showed growth while the suite was still running (0-byte-until-exit regression)"
ok
[ "$rc" -eq 0 ] || fail "(2) clean suite must exit 0 (got $rc): $(cat "$FULLOUT")"
[ "$(sed -n '1p' "$FULLOUT")" = "✅ HEALTHCHECK CLEAN" ] \
  || fail "(2) line 1 of a clean run must stay the classic header (first-line semantics): $(sed -n '1p' "$FULLOUT")"
grep -q 'ok 5 test-5' "$FULLOUT" || fail "(2) full suite output must still land in the final assembly: $(cat "$FULLOUT")"
grep -qE '^(ok|not ok) ' "$PROG" || fail "(2) the progress companion must carry real TAP lines, not just noise: $(cat "$PROG")"
ok

# ── (3) CODE ERROR: healthcheck.sh's own exit code (not tee's) drives the result ───────────────────
write_cfg "$CODEERROR_STUB"
PROG3="$T/prog3.log"; FULLOUT3="$T/full3.log"
HEALTHCHECK_PROGRESS_LOG="$PROG3" bash "$HC" "$WT" --heavy > "$FULLOUT3" 2>&1
rc3=$?
[ "$rc3" -eq 1 ] || fail "(3) a reproducible code error must exit 1 (got $rc3) — pipefail/rc plumbing regressed: $(cat "$FULLOUT3")"
[ "$(sed -n '1p' "$FULLOUT3")" = "❌ CODE ERROR" ] \
  || fail "(3) line 1 of a code-error run must stay '❌ CODE ERROR': $(sed -n '1p' "$FULLOUT3")"
grep -qi 'not ok' "$FULLOUT3" || fail "(3) the reproduced failure must still be visible in the final output: $(cat "$FULLOUT3")"
grep -qi 'not ok' "$PROG3" || fail "(3) the failure must also have streamed into the progress companion: $(cat "$PROG3")"
ok

# ── (4) OFF BY DEFAULT: HEALTHCHECK_PROGRESS_LOG unset → no companion, unchanged verdict ───────────
write_cfg "$CLEAN_STUB"
FULLOUT4="$T/full4.log"
env -u HEALTHCHECK_PROGRESS_LOG bash "$HC" "$WT" --heavy > "$FULLOUT4" 2>&1
rc4=$?
[ "$rc4" -eq 0 ] || fail "(4) unset env var must still yield a clean exit 0 (got $rc4): $(cat "$FULLOUT4")"
[ "$(sed -n '1p' "$FULLOUT4")" = "✅ HEALTHCHECK CLEAN" ] \
  || fail "(4) unset env var must still print the classic header: $(sed -n '1p' "$FULLOUT4")"
[ -e "$T/.progress" ] && fail "(4) no companion file should be fabricated when the env var is unset"
ok

echo "ALL PASS ($pass checks) — healthcheck.sh streams live progress via HEALTHCHECK_PROGRESS_LOG while its own verdict stays byte-identical."
