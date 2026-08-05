#!/usr/bin/env bash
# test-healthcheck-profile-forward.sh — HERD-551 / GH #674 regression: the wrapper must actually
# FORWARD the resolved profile to $HEALTHCHECK_CMD, and must hard-fail when a project script admits
# it skipped heavy work despite being asked for --heavy.
#
# Before this fix, run_heavy() invoked $HEALTHCHECK_CMD as `<dir>` (full mode) or `<dir> --oneline`
# (oneline mode) — the profile flag stopped at the wrapper. A profile-aware project script (one that
# only runs its slow/extra probes under --heavy) had no way to see the request, so it silently ran
# its light behavior while the wrapper reported clean — GH #674 found this in the wild: six heavy
# probes + a visual-regression harness never ran at merge time on emberglen-godot.
#
# Covers:
#   (1) --heavy forces MODE=heavy and the project script receives "--heavy" as $2 (dir stays $1).
#   (2) --heavy --oneline: the project script receives "--heavy" as $2 AND "--oneline" as $3.
#   (3) CONTRADICTION hard-error: a stub that received --heavy but still emits a line starting with
#       the documented "HEAVY-SKIPPED:" marker (even though it exits 0) reds the wrapper (exit 1),
#       and the wrapper's own output surfaces the marker line so the contradiction is visible.
#   (4) negative control: ordinary output that merely MENTIONS "skipped" / "heavy" without the exact
#       anchored marker must NOT trip the hard-error — only the documented literal token does.
#
# Fully hermetic: a throwaway git repo, stub HEALTHCHECK_CMD scripts, NO network, NO model.
# Mirrors tests/test-healthcheck-routing.sh's fixture shape.
# Run:  bash tests/test-healthcheck-profile-forward.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HC="$HERE/../scripts/herd/healthcheck.sh"
[ -f "$HC" ] || { echo "healthcheck.sh not found at $HC" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git required to run this test" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# ── a worktree that looks like a real repo (committed seed on 'main') ─────────
WT="$T/wt"; mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" checkout -q -b main 2>/dev/null || git -C "$WT" checkout -q main
git -C "$WT" config user.email t@t.test
git -C "$WT" config user.name  herd-test
echo seed > "$WT/seed.txt"; git -C "$WT" add seed.txt; git -C "$WT" commit -qm seed

CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
write_cfg() {  # write_cfg <healthcheck-cmd>
  {
    printf 'PROJECT_ROOT="%s"\n'  "$WT"
    printf 'WORKTREES_DIR="%s"\n' "$T/trees"
    printf 'DEFAULT_BRANCH="main"\n'
    printf 'WORKSPACE_NAME="ptest"\n'
    printf 'HEALTHCHECK_CMD="bash %s"\n' "$1"
    printf 'HEALTHCHECK_HEAVY_GLOB=""\n'
  } > "$CFG"
}

# ── (1) + (2): a RECORDING stub — dumps its own argv, one per line, to $RECORDER ──────────────────
RECORDER="$T/recorder.txt"
RECORD_CMD="$T/stub-record.sh"
cat > "$RECORD_CMD" <<STUB
#!/usr/bin/env bash
: > "$RECORDER"
for a in "\$@"; do printf '%s\n' "\$a" >> "$RECORDER"; done
printf 'STUB_RAN\n'
exit 0
STUB
chmod +x "$RECORD_CMD"
write_cfg "$RECORD_CMD"

# (1) full mode, forced --heavy: dir=$1, profile=$2="--heavy"
out="$(bash "$HC" "$WT" --heavy 2>"$T/stderr1")"; rc=$?
[ "$rc" -eq 0 ] || fail "(1) a clean stub must exit 0 (got $rc): $out"
arg1="$(sed -n '1p' "$RECORDER")"; arg2="$(sed -n '2p' "$RECORDER")"
[ "$arg1" = "$WT" ] || fail "(1) \$1 must stay the worktree dir (got '$arg1')"
[ "$arg2" = "--heavy" ] || fail "(1) \$2 must be the forwarded profile '--heavy' (got '$arg2'): recorder=$(cat "$RECORDER")"
ok

# (2) oneline mode: dir=$1, profile=$2="--heavy", --oneline=$3
out="$(bash "$HC" "$WT" --heavy --oneline 2>"$T/stderr2")"; rc=$?
[ "$rc" -eq 0 ] || fail "(2) a clean stub must exit 0 (got $rc): $out"
arg2="$(sed -n '2p' "$RECORDER")"; arg3="$(sed -n '3p' "$RECORDER")"
[ "$arg2" = "--heavy" ] || fail "(2) \$2 must still be '--heavy' under --oneline (got '$arg2'): recorder=$(cat "$RECORDER")"
[ "$arg3" = "--oneline" ] || fail "(2) \$3 must be '--oneline' (got '$arg3'): recorder=$(cat "$RECORDER")"
ok

# ── (3) CONTRADICTION: a stub that received --heavy but reports it skipped heavy work anyway ──────
# It exits 0 (a project script that thinks it's clean) — the wrapper must override that and hard-fail.
SKIP_CMD="$T/stub-skip.sh"
cat > "$SKIP_CMD" <<'STUB'
#!/usr/bin/env bash
echo "some normal preamble output"
echo "HEAVY-SKIPPED: no GPU available in this sandbox, ran light probes only"
echo "trailing line"
exit 0
STUB
chmod +x "$SKIP_CMD"
write_cfg "$SKIP_CMD"

out="$(bash "$HC" "$WT" --heavy 2>"$T/stderr3")"; rc=$?
[ "$rc" -eq 1 ] || fail "(3) a --heavy run whose project script admits HEAVY-SKIPPED must hard-fail (exit 1), got rc=$rc: $out"
grep -qi "CONTRADICTION" <<< "$out" \
  || fail "(3) the wrapper's output must name the contradiction: $out"
grep -q "HEAVY-SKIPPED:" <<< "$out" \
  || fail "(3) the wrapper must surface the offending marker line so the contradiction is diagnosable: $out"
ok

# ── (4) negative control: output that merely MENTIONS skipping heavy work, but not via the exact ──
# anchored marker, must NOT trip the hard-error (only the documented literal token does — a wrapper
# that pattern-matches too loosely would false-red ordinary prose).
NEARMISS_CMD="$T/stub-nearmiss.sh"
cat > "$NEARMISS_CMD" <<'STUB'
#!/usr/bin/env bash
echo "note: heavy probes skipped this run (not the documented marker)"
echo "clean"
exit 0
STUB
chmod +x "$NEARMISS_CMD"
write_cfg "$NEARMISS_CMD"

out="$(bash "$HC" "$WT" --heavy 2>"$T/stderr4")"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) prose that mentions skipping without the exact HEAVY-SKIPPED: marker must NOT hard-fail (got rc=$rc): $out"
ok

echo "ALL PASS ($pass checks) — healthcheck.sh forwards the resolved profile to \$HEALTHCHECK_CMD and hard-fails a --heavy/HEAVY-SKIPPED contradiction."
