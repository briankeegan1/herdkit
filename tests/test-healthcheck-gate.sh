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
#   (8) SHA-CACHE (PR #65 every-tick re-run): with a head sha passed, the FULL suite runs exactly
#       ONCE for a given sha and later ticks REUSE the cached verdict (no re-run):
#         (a) unchanged sha → run once, then reused (CLEAN); stub invoked once total
#         (b) a NEW commit sha invalidates the cache and re-runs; stale result marker discarded
#         (c) retry-before-red + solo mutex for the FIRST run of a sha is unchanged (fail-then-pass
#             still runs twice and caches FLAKY; the cached FLAKY is then reused without re-running)
#         (d) a cached CODEERROR keeps showing the red row on later ticks WITHOUT re-running
#         (e) an empty sha (pre-cache callers) disables the cache — every call runs the suite
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
export JOURNAL_FILE="$T/journal.jsonl"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# Override render() to a no-op — the intermediate frames add no verification value here.
render() { :; }

# Helper: reset per-scenario state (ledger, invocation log, markers, DISPLAY, sequence file).
reset_scenario() {
  rm -f "$HEALTH_STATE" "$STUB_HC_LOG" "$T/trees"/.health-inflight-* "$T/trees"/.health-result-* \
        "$T/trees"/.health-dispatch-* 2>/dev/null || true
  : > "$STUB_HC_LOG"
  : > "$JOURNAL_FILE"
  DISPLAY=(); _HC_RESULT=""
}

# hc_run <pr> <slug> <dir> <idx> [sha] — drive the now-ASYNC gate (HERD-185) to a TERMINAL verdict:
# dispatch, then poll for the background worker's dispatch result and RE-ENTER the gate to collect it.
# Leaves _HC_RESULT + DISPLAY exactly as the collecting call did. This mirrors how the watcher tick
# re-enters _healthcheck_gate across successive ticks, compressed into one blocking helper so the
# assertions below can stay verdict-oriented. A cache hit or a QUEUED slot returns immediately (nothing
# to await); a RUNNING dispatch is awaited then collected.
hc_run() {
  local _p="$1" _s="$2" _d="$3" _i="$4" _sha="${5:-}" _key _disp _n=0
  _HC_RESULT=""
  _healthcheck_gate "$_p" "$_s" "$_d" "$_i" "$_sha"
  case "$_HC_RESULT" in CLEAN|FLAKY|CODEERROR|QUEUED) return 0 ;; esac   # terminal/queued → done
  _key="${_p}-${_sha}"; _disp="$(_health_dispatch_file "$_key")"
  while [ "$_n" -lt 500 ]; do [ -f "$_disp" ] && break; sleep 0.02; _n=$((_n + 1)); done
  _HC_RESULT=""
  _healthcheck_gate "$_p" "$_s" "$_d" "$_i" "$_sha"    # collect
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
hc_run 1 slug-clean "$T/wt" 0
[ "$_HC_RESULT" = "CLEAN" ] || fail "clean healthcheck should yield CLEAN (got '$_HC_RESULT')"
ok
[ "$(ledger_outcomes 1)" = "clean" ] || fail "ledger should record 'clean' (got '$(ledger_outcomes 1)')"
printf '%s\n' "${DISPLAY[0]:-}" | grep -q "needs you" && fail "clean run must not paint 'needs you'"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 1 ] || fail "clean run should invoke healthcheck exactly once"
[ ! -e "$(_health_inflight_file "1-")" ] || fail "clean run must release its mutex marker"
ok

# ── (3) tolerated data/env (rc 0, ⚠️ prefix) → CLEAN, ledger 'dataenv' ────────
reset_scenario
printf '0|⚠️  data/env (not a code bug) — missing fixture\n' > "$STUB_HC_SEQ"
hc_run 2 slug-env "$T/wt" 0
[ "$_HC_RESULT" = "CLEAN" ] || fail "data/env (rc 0) should yield CLEAN (got '$_HC_RESULT')"
[ "$(ledger_outcomes 2)" = "dataenv" ] || fail "ledger should record 'dataenv' (got '$(ledger_outcomes 2)')"
printf '%s\n' "${DISPLAY[0]:-}" | grep -q "needs you" && fail "data/env run must not paint 'needs you'"
ok

# ── (4) FLAKY: fail-then-pass → flaky/infra, NOT red, proceeds as passing ─────
reset_scenario
printf '1|❌ code error — TESTS FAILED: 27\n0|✅ clean — 30 sh, 0 py ok\n' > "$STUB_HC_SEQ"
hc_run 3 slug-flaky "$T/wt" 0
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
[ ! -e "$(_health_inflight_file "3-")" ] || fail "flaky run must release its mutex marker"
ok

# ── (5) REAL: fail-then-fail → red 'needs you', CODEERROR, exactly two runs ───
reset_scenario
printf '1|❌ code error — real bug on line 5\n1|❌ code error — real bug on line 5\n' > "$STUB_HC_SEQ"
hc_run 4 slug-real "$T/wt" 0
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
[ ! -e "$(_health_inflight_file "4-")" ] || fail "real failure must still release its mutex marker"
ok

# ── (5b) HERD-76: the FLAKY offender's identity is persisted before the passing retry ─────────────
# A fail-then-pass run must record WHICH test failed on the code-error attempt into the journal —
# on the healthcheck_attempted event AND the FLAKY outcome — so a retry-that-passes can no longer
# erase the flaky offender (which blocked deflaking #185/#188).
type _health_fail_identity >/dev/null 2>&1 || fail "_health_fail_identity not defined after sourcing"
ok
# The extractor prefers a concrete test-file token, dedupes, and falls back to the failing step.
[ "$(_health_fail_identity '❌ code error — app/greet.test.sh: assertion failed')" = "app/greet.test.sh" ] \
  || fail "identity should extract the test file (got '$(_health_fail_identity '❌ code error — app/greet.test.sh: assertion failed')')"
[ "$(_health_fail_identity '❌ light syntax — bash -n scripts/foo.sh → line 3: syntax error')" = "scripts/foo.sh" ] \
  || fail "identity should extract the syntax-erroring file"
[ "$(_health_fail_identity '❌ code error — TESTS FAILED: 27 assertions')" = "TESTS FAILED: 27 assertions" ] \
  || fail "identity should fall back to the failing step when no file is named"
ok
reset_scenario
printf '1|❌ code error — tests/test-widget.sh: FAILED\n0|✅ clean — 30 sh, 0 py ok\n' > "$STUB_HC_SEQ"
hc_run 30 slug-flakyid "$T/wt" 0
[ "$_HC_RESULT" = "FLAKY" ] || fail "5b: fail-then-pass should yield FLAKY (got '$_HC_RESULT')"
# The failing attempt's journal event carries failed=<file> …
grep -q '"event":"healthcheck_attempted"' "$JOURNAL_FILE" || fail "5b: expected a healthcheck_attempted event"
python3 - "$JOURNAL_FILE" <<'PY' || fail "5b: healthcheck_attempted must carry failed=tests/test-widget.sh"
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
a=[r for r in rows if r.get("event")=="healthcheck_attempted" and r.get("result")=="code-error"]
assert a and a[-1].get("failed")=="tests/test-widget.sh", a
PY
ok
# … and the FLAKY outcome carries the offender too — a passing retry no longer erases it.
python3 - "$JOURNAL_FILE" <<'PY' || fail "5b: FLAKY outcome must carry failed=tests/test-widget.sh"
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
o=[r for r in rows if r.get("event")=="healthcheck_outcome" and r.get("outcome")=="FLAKY"]
assert o and o[-1].get("failed")=="tests/test-widget.sh", o
PY
ok
# A reproduced (fail-then-fail) code error also records the offender on the retry attempt.
reset_scenario
printf '1|❌ code error — tests/test-broken.sh: line 5\n1|❌ code error — tests/test-broken.sh: line 5\n' > "$STUB_HC_SEQ"
hc_run 31 slug-realid "$T/wt" 0
[ "$_HC_RESULT" = "CODEERROR" ] || fail "5b: fail-then-fail should yield CODEERROR (got '$_HC_RESULT')"
python3 - "$JOURNAL_FILE" <<'PY' || fail "5b: retry code-error attempt must carry failed=tests/test-broken.sh"
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r2=[r for r in rows if r.get("event")=="healthcheck_retried" and r.get("result")=="code-error"]
assert r2 and r2[-1].get("failed")=="tests/test-broken.sh", r2
PY
ok

# ── (6) mutex serialization: a live holder → QUEUED, stub not invoked ─────────
reset_scenario
HEALTH_CONCURRENCY=1
printf '0|✅ clean — should not run while queued\n' > "$STUB_HC_SEQ"
# Plant a live external holder (this test process's own pid is alive) occupying the only slot.
printf '%s\n' "$$" > "$(_health_inflight_file 999)"
[ "$(_count_live_healthchecks)" -eq 1 ] || fail "planted holder should count as 1 live healthcheck"
_health_slot_free && fail "no slot should be free while a holder is live at HEALTH_CONCURRENCY=1"
hc_run 5 slug-queued "$T/wt" 0
[ "$_HC_RESULT" = "QUEUED" ] || fail "PR should QUEUE while the slot is busy (got '$_HC_RESULT')"
ok
printf '%s\n' "${DISPLAY[0]:-}" | grep -q "health-check · queued" \
  || fail "queued PR should show 'health-check · queued' (got: ${DISPLAY[0]:-})"
[ ! -s "$STUB_HC_LOG" ] || fail "a queued PR must NOT invoke the healthcheck"
[ ! -e "$(_health_inflight_file "5-")" ] || fail "a queued PR must not claim a marker"
ok
# Free the slot → the PR now runs to CLEAN.
_health_release 999
hc_run 5 slug-queued "$T/wt" 0
[ "$_HC_RESULT" = "CLEAN" ] || fail "once the slot frees, the queued PR should run (got '$_HC_RESULT')"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 1 ] || fail "freed PR should invoke the healthcheck exactly once"
ok

# ── (7) HEALTH_CONCURRENCY override + solo retry stays solo ───────────────────
reset_scenario
# With one live holder and HEALTH_CONCURRENCY=2, a slot is still free → runs.
printf '%s\n' "$$" > "$(_health_inflight_file 998)"
HEALTH_CONCURRENCY=2
printf '0|✅ clean — override lets it run\n' > "$STUB_HC_SEQ"
hc_run 6 slug-override "$T/wt" 0
[ "$_HC_RESULT" = "CLEAN" ] || fail "HEALTH_CONCURRENCY=2 with one holder should still run (got '$_HC_RESULT')"
ok
# Now HEALTH_CONCURRENCY=1 with the same holder → queues.
reset_scenario
printf '%s\n' "$$" > "$(_health_inflight_file 998)"
HEALTH_CONCURRENCY=1
printf '0|✅ clean\n' > "$STUB_HC_SEQ"
hc_run 7 slug-override2 "$T/wt" 0
[ "$_HC_RESULT" = "QUEUED" ] || fail "HEALTH_CONCURRENCY=1 with one holder should queue (got '$_HC_RESULT')"
_health_release 998
ok
# The retry stays SOLO: across a fail-then-pass run the stub must observe exactly ONE live marker
# (this PR's) on BOTH invocations — proving the mutex is held for the whole run+retry window.
reset_scenario
export STUB_HC_MARKERCOUNT_LOG="$T/hc-markercount.log"; : > "$STUB_HC_MARKERCOUNT_LOG"
HEALTH_CONCURRENCY=1
printf '1|❌ code error — transient\n0|✅ clean — passed solo\n' > "$STUB_HC_SEQ"
hc_run 8 slug-solo "$T/wt" 0
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
hc_run 10 slug-a "$T/wt" 0
[ "$_HC_RESULT" = "CLEAN" ] || fail "PR 10 should run clean"
printf '0|✅ clean\n' > "$STUB_HC_SEQ"
hc_run 11 slug-b "$T/wt" 1
[ "$_HC_RESULT" = "CLEAN" ] || fail "PR 11 should run clean after PR 10 released the slot"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "two sequential PRs should invoke the healthcheck twice total"
[ ! -e "$(_health_inflight_file "10-")" ] && [ ! -e "$(_health_inflight_file "11-")" ] \
  || fail "both PRs must release their markers after running"
ok

# ── (8) SHA-CACHE: an unchanged commit must NOT re-run the suite (PR #65 every-tick re-run) ───────
# The helpers exist and are sha-keyed like the review gate's.
for fn in _health_result_file record_health_result _discard_stale_health; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
[ "$(_health_result_file 42 abc)" = "$T/trees/.health-result-42-abc" ] \
  || fail "_health_result_file should key by pr+sha (got '$(_health_result_file 42 abc)')"
ok

# (8a) unchanged sha → full suite runs exactly ONCE; every later tick REUSES the cached CLEAN.
reset_scenario
HEALTH_CONCURRENCY=1
printf '0|✅ clean — 30 sh, 0 py ok\n' > "$STUB_HC_SEQ"
hc_run 1000 slug-cache "$T/wt" 0 "deadbeef01"
[ "$_HC_RESULT" = "CLEAN" ] || fail "8a: first run of a fresh sha should yield CLEAN (got '$_HC_RESULT')"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 1 ] || fail "8a: first run should invoke the healthcheck exactly once"
[ -f "$(_health_result_file 1000 deadbeef01)" ] || fail "8a: a terminal CLEAN must be cached for this sha"
# Two more ticks on the SAME sha — cache hits, suite NEVER re-runs, verdict still CLEAN.
_HC_RESULT=""; hc_run 1000 slug-cache "$T/wt" 0 "deadbeef01"
[ "$_HC_RESULT" = "CLEAN" ] || fail "8a: cached sha should REUSE CLEAN (got '$_HC_RESULT')"
_HC_RESULT=""; hc_run 1000 slug-cache "$T/wt" 0 "deadbeef01"
[ "$_HC_RESULT" = "CLEAN" ] || fail "8a: cached sha should REUSE CLEAN on every later tick"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 1 ] \
  || fail "8a: an UNCHANGED sha must NOT re-run the suite ($(wc -l < "$STUB_HC_LOG") invocations, expected 1)"
# Cache reuse must not append phantom attempts to the ledger — still exactly the one real run.
[ "$(ledger_outcomes 1000)" = "clean" ] \
  || fail "8a: cache hits must not append ledger attempts (got '$(ledger_outcomes 1000)')"
ok

# (8b) a NEW commit sha invalidates the cache → full re-run, and the stale marker is discarded.
printf '0|✅ clean — new commit\n' > "$STUB_HC_SEQ"
_HC_RESULT=""; hc_run 1000 slug-cache "$T/wt" 0 "feed123402"
[ "$_HC_RESULT" = "CLEAN" ] || fail "8b: a new sha should re-run and yield CLEAN (got '$_HC_RESULT')"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] \
  || fail "8b: a NEW commit sha must invalidate the cache and re-run ($(wc -l < "$STUB_HC_LOG") invocations, expected 2)"
[ -f "$(_health_result_file 1000 feed123402)" ] || fail "8b: the new sha's terminal verdict must be cached"
[ ! -f "$(_health_result_file 1000 deadbeef01)" ] || fail "8b: the stale sha's result marker must be discarded"
ok

# (8c) retry-before-red + solo mutex is UNCHANGED for the FIRST run of a sha; the FLAKY verdict is
# then cached and reused without re-running.
reset_scenario
HEALTH_CONCURRENCY=1
export STUB_HC_MARKERCOUNT_LOG="$T/hc-markercount.log"; : > "$STUB_HC_MARKERCOUNT_LOG"
printf '1|❌ code error — transient\n0|✅ clean — passed solo\n' > "$STUB_HC_SEQ"
hc_run 1001 slug-cflaky "$T/wt" 0 "cafe567803"
[ "$_HC_RESULT" = "FLAKY" ] || fail "8c: fail-then-pass on a fresh sha should still yield FLAKY (got '$_HC_RESULT')"
[ "$(ledger_outcomes 1001)" = "code-error flaky-pass" ] \
  || fail "8c: retry-before-red ledger unchanged (got '$(ledger_outcomes 1001)')"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "8c: first run of a sha still runs twice (initial + solo retry)"
# The solo retry stayed solo — the stub saw exactly one live marker on both invocations.
[ "$(wc -l < "$STUB_HC_MARKERCOUNT_LOG")" -eq 2 ] || fail "8c: stub should have observed two invocations"
if grep -qvx '1' "$STUB_HC_MARKERCOUNT_LOG"; then
  fail "8c: healthcheck ran while >1 marker was live — mutex did not keep the first run solo"
fi
unset STUB_HC_MARKERCOUNT_LOG
[ -f "$(_health_result_file 1001 cafe567803)" ] || fail "8c: the FLAKY verdict must be cached for this sha"
# Next tick, same sha → reuse FLAKY, no re-run, shows the flaky/infra row (never red).
_HC_RESULT=""; DISPLAY=()
hc_run 1001 slug-cflaky "$T/wt" 0 "cafe567803"
[ "$_HC_RESULT" = "FLAKY" ] || fail "8c: cached sha should REUSE FLAKY (got '$_HC_RESULT')"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "8c: reusing a cached FLAKY must NOT re-run the suite"
printf '%s\n' "${DISPLAY[0]:-}" | grep -q "flaky · infra (passed on retry)" \
  || fail "8c: reused FLAKY should show the flaky/infra row (got: ${DISPLAY[0]:-})"
printf '%s\n' "${DISPLAY[0]:-}" | grep -q "needs you" && fail "8c: reused FLAKY must never paint red"
ok

# (8d) a cached CODEERROR keeps surfacing the red row on later ticks WITHOUT re-running.
reset_scenario
HEALTH_CONCURRENCY=1
printf '1|❌ code error — real bug on line 5\n1|❌ code error — real bug on line 5\n' > "$STUB_HC_SEQ"
hc_run 1002 slug-cred "$T/wt" 0 "face9abc04"
[ "$_HC_RESULT" = "CODEERROR" ] || fail "8d: fail-then-fail should yield CODEERROR (got '$_HC_RESULT')"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "8d: first run of a red sha runs twice (initial + solo retry)"
[ -f "$(_health_result_file 1002 face9abc04)" ] || fail "8d: a terminal CODEERROR must be cached"
# Later ticks on the same sha → reuse CODEERROR, red row stays, suite never re-runs.
_HC_RESULT=""; DISPLAY=()
hc_run 1002 slug-cred "$T/wt" 0 "face9abc04"
[ "$_HC_RESULT" = "CODEERROR" ] || fail "8d: cached sha should REUSE CODEERROR (got '$_HC_RESULT')"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] \
  || fail "8d: a cached CODEERROR must keep the red row WITHOUT re-running ($(wc -l < "$STUB_HC_LOG") invocations, expected 2)"
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "needs you" || fail "8d: reused CODEERROR must still paint red 'needs you' (got: $d)"
printf '%s\n' "$d" | grep -q "real bug on line 5" || fail "8d: reused red row should carry the cached oneline reason (got: $d)"
ok

# (8e) an empty sha disables the cache — the pre-cache behavior (every call runs the suite).
reset_scenario
HEALTH_CONCURRENCY=1
printf '0|✅ clean — no sha\n' > "$STUB_HC_SEQ"
hc_run 1003 slug-nosha "$T/wt" 0 ""
[ "$_HC_RESULT" = "CLEAN" ] || fail "8e: empty-sha run should yield CLEAN"
_HC_RESULT=""; hc_run 1003 slug-nosha "$T/wt" 0 ""
[ "$_HC_RESULT" = "CLEAN" ] || fail "8e: empty-sha second run should yield CLEAN"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] \
  || fail "8e: an empty sha must NOT cache — both calls run the suite ($(wc -l < "$STUB_HC_LOG") invocations, expected 2)"
[ -z "$(ls "$T/trees"/.health-result-* 2>/dev/null)" ] || fail "8e: an empty sha must not write any result marker"
ok

echo "ALL PASS ($pass checks)"
