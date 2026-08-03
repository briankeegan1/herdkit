#!/usr/bin/env bash
# test-health-retry-targeted.sh — hermetic tests for HERD-498: the health-worker's retry-before-red
# must target ONLY the bats test(s) run 1 reported as 'not ok', never blindly re-run the whole
# tests/*.bats suite. Observed live on PR #610: run 1 reproduced a single deterministic failure, run 2
# was a full 'bats --jobs 4 tests/herd.bats' (~25m to confirm ONE test). The fix extracts the failing
# test's description(s) from run 1's TAP and re-invokes healthcheck.sh with HEALTHCHECK_BATS_FILTER set
# to a `bats --filter` regex naming exactly those — .herd/healthcheck.project.sh then runs bats SERIALLY
# and filtered instead of the full parallel suite.
#
# Covers:
#   (1) _health_bats_notok_descs / _health_bats_retry_filter extract + escape the right description(s)
#   (2) MUTATION-PROOF: a single-failure fixture's retry invocation carries HEALTHCHECK_BATS_FILTER
#       containing EXACTLY the failing file's name, and NOT the passing tests' names
#   (3) the retry that reproduces the failure still yields CODEERROR with the right detail
#   (4) a NON-bats failure (no TAP 'not ok' at all) retries with HEALTHCHECK_BATS_FILTER UNSET — the
#       full, unfiltered fallback, byte-identical to before this change
#   (5) a multi-failure run 1 builds an alternation naming BOTH failing tests
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) with HERD_HEALTHCHECK_BIN pointed at a scripted
# stub that records each invocation's worktree arg + HEALTHCHECK_BATS_FILTER value. Calls _health_worker
# directly (the unit under test) rather than driving the full async gate — simpler and just as faithful,
# since _health_worker owns the retry-before-red logic end to end. Network-free (gh/git/herdr stubbed).
# Run:  bash tests/test-health-retry-targeted.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

[ -f "$WATCH" ] || { echo "FAIL: agent-watch.sh not found at $WATCH" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# ── Stub binaries on PATH (network-free) ─────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }
TREES="$WORKTREES_DIR"
MAIN="$T/main"; mkdir -p "$MAIN"

# ── (1) unit: description extraction + escaping ───────────────────────────────
TAPLOG="$T/tap.log"
cat > "$TAPLOG" <<'TAP'
❌ CODE ERROR
BATS FAILED
1..3
ok 1 hermetic test-alpha.sh (dynamic)
not ok 2 hermetic test-beta.sh (dynamic)
# (in test file tests/herd.bats, line 42)
ok 3 hermetic test-gamma.sh (dynamic)
TAP
descs="$(_health_bats_notok_descs "$TAPLOG")"
[ "$descs" = "hermetic test-beta.sh (dynamic)" ] \
  || fail "(1) notok_descs should extract exactly the one failing description (got: $descs)"
ok
filt="$(_health_bats_retry_filter "$TAPLOG")"
case "$filt" in *"test-beta"*) ;; *) fail "(1) retry filter should name test-beta.sh (got: $filt)" ;; esac
case "$filt" in *"test-alpha"*|*"test-gamma"*) fail "(1) retry filter must NOT name the passing tests (got: $filt)" ;; esac
ok
# A description with NO 'not ok' at all yields an empty filter (non-bats failure).
: > "$T/nobats.log"; printf 'bash -n scripts/foo.sh -> line 3: syntax error\n' >> "$T/nobats.log"
[ -z "$(_health_bats_retry_filter "$T/nobats.log")" ] || fail "(1) a non-bats log must yield an empty filter"
ok

# ── Scripted stub healthcheck (stands in for healthcheck.sh via HERD_HEALTHCHECK_BIN) ────────────────
# Records "<dir>\t<HEALTHCHECK_BATS_FILTER>" per invocation to $STUB_HC_LOG. Returns $STUB_HC_OUT1/RC1
# on the FIRST invocation, $STUB_HC_OUT2/RC2 on every invocation after.
STUB_HC="$T/stub-healthcheck.sh"
cat > "$STUB_HC" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${HEALTHCHECK_BATS_FILTER:-}" >> "$STUB_HC_LOG"
n="$(cat "$STUB_HC_N" 2>/dev/null || echo 0)"; n=$((n+1)); printf '%s\n' "$n" > "$STUB_HC_N"
if [ "$n" -le 1 ]; then
  cat "$STUB_HC_OUT1" 2>/dev/null
  exit "$(cat "$STUB_HC_RC1" 2>/dev/null || echo 1)"
else
  cat "$STUB_HC_OUT2" 2>/dev/null
  exit "$(cat "$STUB_HC_RC2" 2>/dev/null || echo 0)"
fi
STUB
chmod +x "$STUB_HC"
export HERD_HEALTHCHECK_BIN="$STUB_HC"
export STUB_HC_LOG="$T/hc-invocations.log"
export STUB_HC_N="$T/hc-n"
export STUB_HC_OUT1="$T/hc-out1"
export STUB_HC_RC1="$T/hc-rc1"
export STUB_HC_OUT2="$T/hc-out2"
export STUB_HC_RC2="$T/hc-rc2"

reset_stub() {
  rm -f "$STUB_HC_LOG" "$STUB_HC_N"; : > "$STUB_HC_LOG"
  cp "$TAPLOG" "$STUB_HC_OUT1"; printf '1\n' > "$STUB_HC_RC1"
}

# ── (2)+(3) MUTATION-PROOF: single-failure fixture → retry invocation carries EXACTLY that file ──────
reset_stub
printf '✅ HEALTHCHECK CLEAN\n' > "$STUB_HC_OUT2"; printf '0\n' > "$STUB_HC_RC2"   # retry PASSES → FLAKY
DISP="$T/disp1"; LOG="$T/log1"; rm -f "$DISP" "$LOG"
_health_worker "$T/wt" "$DISP" "$LOG"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "(2) should invoke the stub exactly twice (initial + solo retry)"
ok
run1_filter="$(awk -F'\t' 'NR==1{print $2}' "$STUB_HC_LOG")"
run2_filter="$(awk -F'\t' 'NR==2{print $2}' "$STUB_HC_LOG")"
[ -z "$run1_filter" ] || fail "(2) run 1 must NEVER carry a retry filter (got: $run1_filter)"
ok
case "$run2_filter" in *"test-beta"*) ;; *) fail "(2) retry invocation must contain exactly the failing file 'test-beta.sh' (got: $run2_filter)" ;; esac
case "$run2_filter" in *"test-alpha"*|*"test-gamma"*) fail "(2) retry invocation must NOT contain the passing files (got: $run2_filter)" ;; esac
ok
IFS=$'\t' read -r verdict detail < "$DISP"
[ "$verdict" = "FLAKY" ] || fail "(3) fail-then-pass (targeted retry) should yield FLAKY (got '$verdict')"
ok

# ── (3b) reproduced failure: targeted retry still fails → CODEERROR, right detail ─────────────────
reset_stub
cp "$TAPLOG" "$STUB_HC_OUT2"; printf '1\n' > "$STUB_HC_RC2"    # retry FAILS again (reproduced)
DISP="$T/disp2"; LOG="$T/log2"; rm -f "$DISP" "$LOG"
_health_worker "$T/wt" "$DISP" "$LOG"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "(3b) reproduced failure should invoke the stub exactly twice — never a third retry"
ok
run2_filter="$(awk -F'\t' 'NR==2{print $2}' "$STUB_HC_LOG")"
case "$run2_filter" in *"test-beta"*) ;; *) fail "(3b) the reproduced-failure retry must still target test-beta.sh (got: $run2_filter)" ;; esac
ok
IFS=$'\t' read -r verdict detail < "$DISP"
[ "$verdict" = "CODEERROR" ] || fail "(3b) fail-then-fail should yield CODEERROR (got '$verdict')"
case "$detail" in *"test-beta.sh"*) ;; *) fail "(3b) CODEERROR detail should name the failing test (got: $detail)" ;; esac
ok
grep -q "not ok 2 hermetic test-beta.sh" "$LOG" || fail "(3b) the live log should be the reproduced-failure retry log"
ok

# ── (4) a non-bats failure retries FULL + UNFILTERED — byte-identical fallback ────────────────────
rm -f "$STUB_HC_LOG" "$STUB_HC_N"; : > "$STUB_HC_LOG"
printf '❌ CODE ERROR\nsyntax error in scripts/herd/foo.sh\n' > "$STUB_HC_OUT1"; printf '1\n' > "$STUB_HC_RC1"
printf '✅ HEALTHCHECK CLEAN\n' > "$STUB_HC_OUT2"; printf '0\n' > "$STUB_HC_RC2"
DISP="$T/disp3"; LOG="$T/log3"; rm -f "$DISP" "$LOG"
_health_worker "$T/wt" "$DISP" "$LOG"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "(4) non-bats failure should still invoke the stub exactly twice"
ok
run1_filter="$(awk -F'\t' 'NR==1{print $2}' "$STUB_HC_LOG")"
run2_filter="$(awk -F'\t' 'NR==2{print $2}' "$STUB_HC_LOG")"
[ -z "$run1_filter" ] || fail "(4) run 1 must never carry a filter"
[ -z "$run2_filter" ] || fail "(4) a non-bats failure's retry must be UNFILTERED (full suite) — got: $run2_filter"
ok

# ── (5) a multi-failure run 1 builds an alternation naming BOTH failing tests ──────────────────────
cat > "$T/tap2.log" <<'TAP'
❌ CODE ERROR
BATS FAILED
1..3
not ok 1 hermetic test-alpha.sh (dynamic)
ok 2 hermetic test-beta.sh (dynamic)
not ok 3 hermetic test-gamma.sh (dynamic)
TAP
filt2="$(_health_bats_retry_filter "$T/tap2.log")"
case "$filt2" in *"test-alpha"*) ;; *) fail "(5) multi-failure filter should name test-alpha.sh (got: $filt2)" ;; esac
case "$filt2" in *"test-gamma"*) ;; *) fail "(5) multi-failure filter should name test-gamma.sh (got: $filt2)" ;; esac
case "$filt2" in *"test-beta"*) fail "(5) multi-failure filter must NOT name the passing test (got: $filt2)" ;; esac
ok

echo "ALL PASS ($pass checks)"
