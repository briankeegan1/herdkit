#!/usr/bin/env bash
# test-healthcheck-gate.sh — hermetic tests for the SERIALIZED, retry-before-red healthcheck gate.
# A red healthcheck row must mean VERIFIED-REAL: a transient (from concurrent suites racing on the
# shared git object store) must self-heal on a solo retry and surface as flaky/infra, never red.
#
# Covers:
#   (1) helpers defined + HEALTH_CONCURRENCY default (1)
#   (2) clean pass → CLEAN, ledger records "clean", not red
#   (3) tolerated data/env (rc 0, ⚠️ prefix) → CLEAN, ledger records "dataenv"
#   (4) FLAKY: fail-then-pass → "flaky · infra (passed on retry)", NOT red, proceeds as passing;
#       ledger records code-error then flaky-pass; healthcheck ran exactly twice
#   (5) REAL: fail-then-fail → red "needs you", CODEERROR; ledger records two code-errors;
#       healthcheck ran exactly twice (initial + one solo retry — never more)
#   (6) mutex serialization: a live holder + HEALTH_CONCURRENCY=1 → QUEUED + "health-check · queued"
#       wording, stub NOT invoked; freeing the slot lets it run
#   (7) HEALTH_CONCURRENCY override: with one live holder, =2 runs (slot free), =1 queues
#       and the retry stays SOLO — the stub observes exactly one live healthcheck marker per run
#
# Sources agent-watch.sh in lib mode with HERD_HEALTHCHECK_BIN pointed at a scripted stub. Stubs
# gh/git/herdr (NETWORK-FREE); temp WORKTREES_DIR. Run:  bash tests/test-healthcheck-gate.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH (network-free) ─────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

# ── Scripted stub healthcheck (stands in for healthcheck.sh via HERD_HEALTHCHECK_BIN) ─
# Consumes one line per invocation from $STUB_HC_SEQ ("<rc>|<oneline output>"); repeats the last
# line once the sequence is exhausted. Logs each invocation dir to $STUB_HC_LOG. When
# $STUB_HC_MARKERCOUNT_LOG is set, records how many .health-inflight-* markers are live in
# $STUB_HC_TREES at run time — proving the gate holds the mutex SOLO across the run+retry.
STUB_HC="$T/stub-healthcheck.sh"
cat > "$STUB_HC" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_HC_LOG:-}" ] && printf '%s\n' "$1" >> "$STUB_HC_LOG"
if [ -n "${STUB_HC_MARKERCOUNT_LOG:-}" ] && [ -n "${STUB_HC_TREES:-}" ]; then
  c=0; for f in "$STUB_HC_TREES"/.health-inflight-*; do [ -e "$f" ] && c=$((c+1)); done
  printf '%s\n' "$c" >> "$STUB_HC_MARKERCOUNT_LOG"
fi
line="$(head -1 "$STUB_HC_SEQ" 2>/dev/null || true)"
n="$(wc -l < "$STUB_HC_SEQ" 2>/dev/null || echo 0)"
# Consume the line unless it is the last remaining one (so an exhausted seq repeats its tail).
if [ "${n:-0}" -gt 1 ]; then
  { tail -n +2 "$STUB_HC_SEQ" 2>/dev/null || true; } > "$STUB_HC_SEQ.tmp"
  mv "$STUB_HC_SEQ.tmp" "$STUB_HC_SEQ" 2>/dev/null || true
fi
if [ -z "$line" ]; then printf '✅ clean — stub default\n'; exit 0; fi
rc="${line%%|*}"; out="${line#*|}"
printf '%s\n' "$out"
exit "${rc:-0}"
STUB
chmod +x "$STUB_HC"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export HERD_HEALTHCHECK_BIN="$STUB_HC"
export STUB_HC_SEQ="$T/hc-seq.txt"
export STUB_HC_LOG="$T/hc-invocations.log"
export STUB_HC_TREES="$T/trees"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# Override render() to a no-op — the intermediate frames add no verification value here.
render() { :; }

# Helper: reset per-scenario state (ledger, invocation log, markers, DISPLAY, sequence file).
reset_scenario() {
  rm -f "$HEALTH_STATE" "$STUB_HC_LOG" "$T/trees"/.health-inflight-* 2>/dev/null || true
  : > "$STUB_HC_LOG"
  DISPLAY=(); _HC_RESULT=""
}
# Helper: outcome tokens recorded in the ledger for a given PR, space-joined in order.
ledger_outcomes() { awk -v p="$1" '$2==p{print $5}' "$HEALTH_STATE" 2>/dev/null | paste -sd' ' -; }

# ── (1) helpers defined + HEALTH_CONCURRENCY default ─────────────────────────
for fn in _healthcheck_gate _count_live_healthchecks _health_slot_free _health_acquire \
          _health_release _health_inflight_file _health_pid_live record_healthcheck; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok
[ "${HEALTH_CONCURRENCY:-}" = "1" ] || fail "HEALTH_CONCURRENCY should default to 1 (got '${HEALTH_CONCURRENCY:-}')"
ok
[ "$(_count_live_healthchecks)" -eq 0 ] || fail "no markers yet → count should be 0"
_health_slot_free || fail "a slot should be free when no healthcheck is running"
ok

# ── (2) clean pass → CLEAN, ledger 'clean', not red ──────────────────────────
reset_scenario
printf '0|✅ clean — 30 sh, 0 py ok\n' > "$STUB_HC_SEQ"
_healthcheck_gate 1 slug-clean "$T/wt" 0
[ "$_HC_RESULT" = "CLEAN" ] || fail "clean healthcheck should yield CLEAN (got '$_HC_RESULT')"
ok
[ "$(ledger_outcomes 1)" = "clean" ] || fail "ledger should record 'clean' (got '$(ledger_outcomes 1)')"
printf '%s\n' "${DISPLAY[0]:-}" | grep -q "needs you" && fail "clean run must not paint 'needs you'"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 1 ] || fail "clean run should invoke healthcheck exactly once"
[ ! -e "$(_health_inflight_file 1)" ] || fail "clean run must release its mutex marker"
ok

# ── (3) tolerated data/env (rc 0, ⚠️ prefix) → CLEAN, ledger 'dataenv' ────────
reset_scenario
printf '0|⚠️  data/env (not a code bug) — missing fixture\n' > "$STUB_HC_SEQ"
_healthcheck_gate 2 slug-env "$T/wt" 0
[ "$_HC_RESULT" = "CLEAN" ] || fail "data/env (rc 0) should yield CLEAN (got '$_HC_RESULT')"
[ "$(ledger_outcomes 2)" = "dataenv" ] || fail "ledger should record 'dataenv' (got '$(ledger_outcomes 2)')"
printf '%s\n' "${DISPLAY[0]:-}" | grep -q "needs you" && fail "data/env run must not paint 'needs you'"
ok

# ── (4) FLAKY: fail-then-pass → flaky/infra, NOT red, proceeds as passing ─────
reset_scenario
printf '1|❌ code error — TESTS FAILED: 27\n0|✅ clean — 30 sh, 0 py ok\n' > "$STUB_HC_SEQ"
_healthcheck_gate 3 slug-flaky "$T/wt" 0
[ "$_HC_RESULT" = "FLAKY" ] || fail "fail-then-pass should yield FLAKY (got '$_HC_RESULT')"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "flaky · infra (passed on retry)" \
  || fail "flaky run should show 'flaky · infra (passed on retry)' (got: $d)"
printf '%s\n' "$d" | grep -q "needs you" && fail "flaky run must NEVER paint 'needs you' red"
ok
[ "$(ledger_outcomes 3)" = "code-error flaky-pass" ] \
  || fail "ledger should record 'code-error flaky-pass' (got '$(ledger_outcomes 3)')"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "flaky run should invoke healthcheck exactly twice (initial + solo retry)"
[ ! -e "$(_health_inflight_file 3)" ] || fail "flaky run must release its mutex marker"
ok

# ── (5) REAL: fail-then-fail → red 'needs you', CODEERROR, exactly two runs ───
reset_scenario
printf '1|❌ code error — real bug on line 5\n1|❌ code error — real bug on line 5\n' > "$STUB_HC_SEQ"
_healthcheck_gate 4 slug-real "$T/wt" 0
[ "$_HC_RESULT" = "CODEERROR" ] || fail "fail-then-fail should yield CODEERROR (got '$_HC_RESULT')"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "needs you" || fail "reproduced code error should paint red 'needs you' (got: $d)"
printf '%s\n' "$d" | grep -q "real bug on line 5" || fail "red row should carry the healthcheck's oneline reason"
printf '%s\n' "$d" | grep -q "flaky" && fail "reproduced failure must not be called flaky"
ok
[ "$(ledger_outcomes 4)" = "code-error code-error" ] \
  || fail "ledger should record 'code-error code-error' (got '$(ledger_outcomes 4)')"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "real failure should invoke healthcheck exactly twice — never a third retry"
[ ! -e "$(_health_inflight_file 4)" ] || fail "real failure must still release its mutex marker"
ok

# ── (6) mutex serialization: a live holder → QUEUED, stub not invoked ─────────
reset_scenario
HEALTH_CONCURRENCY=1
printf '0|✅ clean — should not run while queued\n' > "$STUB_HC_SEQ"
# Plant a live external holder (this test process's own pid is alive) occupying the only slot.
printf '%s\n' "$$" > "$(_health_inflight_file 999)"
[ "$(_count_live_healthchecks)" -eq 1 ] || fail "planted holder should count as 1 live healthcheck"
_health_slot_free && fail "no slot should be free while a holder is live at HEALTH_CONCURRENCY=1"
_healthcheck_gate 5 slug-queued "$T/wt" 0
[ "$_HC_RESULT" = "QUEUED" ] || fail "PR should QUEUE while the slot is busy (got '$_HC_RESULT')"
ok
printf '%s\n' "${DISPLAY[0]:-}" | grep -q "health-check · queued" \
  || fail "queued PR should show 'health-check · queued' (got: ${DISPLAY[0]:-})"
[ ! -s "$STUB_HC_LOG" ] || fail "a queued PR must NOT invoke the healthcheck"
[ ! -e "$(_health_inflight_file 5)" ] || fail "a queued PR must not claim a marker"
ok
# Free the slot → the PR now runs to CLEAN.
_health_release 999
_healthcheck_gate 5 slug-queued "$T/wt" 0
[ "$_HC_RESULT" = "CLEAN" ] || fail "once the slot frees, the queued PR should run (got '$_HC_RESULT')"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 1 ] || fail "freed PR should invoke the healthcheck exactly once"
ok

# ── (7) HEALTH_CONCURRENCY override + solo retry stays solo ───────────────────
reset_scenario
# With one live holder and HEALTH_CONCURRENCY=2, a slot is still free → runs.
printf '%s\n' "$$" > "$(_health_inflight_file 998)"
HEALTH_CONCURRENCY=2
printf '0|✅ clean — override lets it run\n' > "$STUB_HC_SEQ"
_healthcheck_gate 6 slug-override "$T/wt" 0
[ "$_HC_RESULT" = "CLEAN" ] || fail "HEALTH_CONCURRENCY=2 with one holder should still run (got '$_HC_RESULT')"
ok
# Now HEALTH_CONCURRENCY=1 with the same holder → queues.
reset_scenario
printf '%s\n' "$$" > "$(_health_inflight_file 998)"
HEALTH_CONCURRENCY=1
printf '0|✅ clean\n' > "$STUB_HC_SEQ"
_healthcheck_gate 7 slug-override2 "$T/wt" 0
[ "$_HC_RESULT" = "QUEUED" ] || fail "HEALTH_CONCURRENCY=1 with one holder should queue (got '$_HC_RESULT')"
_health_release 998
ok
# The retry stays SOLO: across a fail-then-pass run the stub must observe exactly ONE live marker
# (this PR's) on BOTH invocations — proving the mutex is held for the whole run+retry window.
reset_scenario
export STUB_HC_MARKERCOUNT_LOG="$T/hc-markercount.log"; : > "$STUB_HC_MARKERCOUNT_LOG"
HEALTH_CONCURRENCY=1
printf '1|❌ code error — transient\n0|✅ clean — passed solo\n' > "$STUB_HC_SEQ"
_healthcheck_gate 8 slug-solo "$T/wt" 0
[ "$_HC_RESULT" = "FLAKY" ] || fail "solo-retry scenario should end FLAKY (got '$_HC_RESULT')"
[ "$(wc -l < "$STUB_HC_MARKERCOUNT_LOG")" -eq 2 ] || fail "stub should have observed two invocations"
if grep -qvx '1' "$STUB_HC_MARKERCOUNT_LOG"; then
  fail "healthcheck ran while >1 marker was live — the mutex did not keep the run solo ($(paste -sd' ' - < "$STUB_HC_MARKERCOUNT_LOG"))"
fi
unset STUB_HC_MARKERCOUNT_LOG
ok

# ── Two PRs → sequential invocations (each ran solo, each recorded once) ──────
reset_scenario
HEALTH_CONCURRENCY=1
printf '0|✅ clean\n' > "$STUB_HC_SEQ"
_healthcheck_gate 10 slug-a "$T/wt" 0
[ "$_HC_RESULT" = "CLEAN" ] || fail "PR 10 should run clean"
printf '0|✅ clean\n' > "$STUB_HC_SEQ"
_healthcheck_gate 11 slug-b "$T/wt" 1
[ "$_HC_RESULT" = "CLEAN" ] || fail "PR 11 should run clean after PR 10 released the slot"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "two sequential PRs should invoke the healthcheck twice total"
[ ! -e "$(_health_inflight_file 10)" ] && [ ! -e "$(_health_inflight_file 11)" ] \
  || fail "both PRs must release their markers after running"
ok

echo "ALL PASS ($pass checks)"
