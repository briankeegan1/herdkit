#!/usr/bin/env bash
# test-parallel-review.sh — hermetic tests for BACKGROUND review dispatch (parallel review):
#   (1) never double-dispatch the same pr+sha (inflight-marker guard)
#   (2) REVIEW_CONCURRENCY bounds simultaneous reviews; excess PRs report QUEUED
#   (3) verdicts are collected across ticks and recorded to the review ledger (PASS + BLOCK)
#   (4) a result file for a STALE sha (PR moved to a newer head) is discarded unread
#   (5) a dead inflight marker (severed reviewer) is reaped and the pr+sha re-dispatched
#   (6) INFRA-FAIL results are retried (never cached to the ledger), bounded by the retry cap
#   (7) herd-review.sh writes its verdict line to $HERD_REVIEW_RESULT_FILE as its last act
#   (8) herd-review.sh traps SIGTERM and reports INFRA-FAIL instead of dying silently
#
# Sources agent-watch.sh in lib mode with HERD_REVIEW_BIN pointed at a stub reviewer whose
# duration/verdict are controlled per-dispatch via env. Stubs gh/git/herdr/claude (NETWORK-FREE).
# Run:  bash tests/test-parallel-review.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
REVIEW="$HERE/../scripts/herd/herd-review.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ]  || fail "agent-watch.sh not found at $WATCH"
[ -f "$REVIEW" ] || fail "herd-review.sh not found at $REVIEW"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# wait_for <timeout-s> <test-cmd...> — poll a condition every 0.2 s; fail-friendly (returns 1).
wait_for() {
  local deadline=$(( $(date +%s) + $1 )); shift
  while ! "$@" 2>/dev/null; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
  return 0
}

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

# ── Stub reviewer (stands in for herd-review.sh via the HERD_REVIEW_BIN seam) ─
# Controlled per-dispatch through exported env (captured at spawn time):
#   STUB_SPAWN_LOG — every invocation appends "<pr> <slug>" (proves dispatch counts)
#   STUB_DELAY     — seconds to sleep before writing the result (simulates a slow Opus review)
#   STUB_VERDICT   — the verdict line to write (default REVIEW: PASS)
# Mirrors the real result-file contract: atomic temp+mv write as the LAST act.
STUB_REVIEW="$T/stub-review.sh"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
pr="$1"; slug="$2"
[ -n "${STUB_SPAWN_LOG:-}" ] && printf '%s %s\n' "$pr" "$slug" >> "$STUB_SPAWN_LOG"
sleep "${STUB_DELAY:-0}"
if [ -n "${HERD_REVIEW_RESULT_FILE:-}" ]; then
  printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}" > "$HERD_REVIEW_RESULT_FILE.tmp.$$"
  mv "$HERD_REVIEW_RESULT_FILE.tmp.$$" "$HERD_REVIEW_RESULT_FILE"
fi
printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}"
STUB
chmod +x "$STUB_REVIEW"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export HERD_REVIEW_BIN="$STUB_REVIEW"
export REVIEW_CONCURRENCY=2
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _review_gate_step _dispatch_review _count_live_reviews _discard_stale_reviews \
          _review_retry_count record_review_retry _review_inflight_file _review_result_file; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

export STUB_SPAWN_LOG="$T/spawns.log"

# ── (1) dispatch + no double-dispatch for the same pr+sha ────────────────────
: > "$STUB_SPAWN_LOG"
export STUB_DELAY=3 STUB_VERDICT="REVIEW: PASS"
s="$(_review_gate_step 1 slug-a aaa111)"
[ "$s" = "RUNNING" ] || fail "first step should dispatch and report RUNNING (got $s)"
ok
wait_for 5 test -s "$STUB_SPAWN_LOG" || fail "stub reviewer was never spawned"
[ -f "$(_review_inflight_file 1 aaa111)" ] || fail "inflight marker not written"
ok
s="$(_review_gate_step 1 slug-a aaa111)"
[ "$s" = "RUNNING" ] || fail "second step while in flight should report RUNNING (got $s)"
_review_gate_step 1 slug-a aaa111 >/dev/null   # a few more ticks…
_review_gate_step 1 slug-a aaa111 >/dev/null
[ "$(grep -c '^1 slug-a$' "$STUB_SPAWN_LOG")" -eq 1 ] || fail "same pr+sha was dispatched more than once"
ok

# ── (2) concurrency cap: third PR queues while two are in flight ─────────────
s="$(_review_gate_step 2 slug-b bbb222)"
[ "$s" = "RUNNING" ] || fail "second PR should get the second slot (got $s)"
ok
s="$(_review_gate_step 3 slug-c ccc333)"
[ "$s" = "QUEUED" ] || fail "third PR should be QUEUED at REVIEW_CONCURRENCY=2 (got $s)"
grep -q '^3 slug-c$' "$STUB_SPAWN_LOG" && fail "queued PR must not be dispatched"
ok
[ "$(_count_live_reviews)" -eq 2 ] || fail "expected exactly 2 live reviews (got $(_count_live_reviews))"
ok

# ── (3) verdicts collected across ticks, recorded to the ledger, files reaped ─
rm -f "$REVIEW_STATE"
wait_for 8 test -f "$(_review_result_file 1 aaa111)" || fail "result file for PR 1 never arrived"
s="$(_review_gate_step 1 slug-a aaa111)"
[ "$s" = "PASS" ] || fail "collect tick should report PASS (got $s)"
[ "$(review_verdict 1 aaa111)" = "PASS" ] || fail "PASS not recorded to the review ledger"
[ ! -f "$(_review_result_file 1 aaa111)" ]   || fail "result file not cleaned up after collection"
[ ! -f "$(_review_inflight_file 1 aaa111)" ] || fail "inflight marker not cleaned up after collection"
ok
# …and the freed slot lets the queued PR dispatch on its next tick.
wait_for 8 test -f "$(_review_result_file 2 bbb222)" || fail "result file for PR 2 never arrived"
_review_gate_step 2 slug-b bbb222 >/dev/null   # collect PR 2 too, freeing its slot
export STUB_DELAY=0
s="$(_review_gate_step 3 slug-c ccc333)"
[ "$s" = "RUNNING" ] || fail "queued PR should dispatch once a slot frees (got $s)"
wait_for 5 grep -q '^3 slug-c$' "$STUB_SPAWN_LOG" || fail "queued PR was never dispatched after slot freed"
ok
# A BLOCK verdict is collected and recorded the same way.
export STUB_VERDICT="REVIEW: BLOCK — off by one"
s="$(_review_gate_step 4 slug-d ddd444)"
[ "$s" = "RUNNING" ] || fail "PR 4 should dispatch (got $s)"
wait_for 5 test -f "$(_review_result_file 4 ddd444)" || fail "result file for PR 4 never arrived"
s="$(_review_gate_step 4 slug-d ddd444)"
[ "$s" = "BLOCK" ] || fail "collect tick should report BLOCK (got $s)"
[ "$(review_verdict 4 ddd444)" = "BLOCK" ] || fail "BLOCK not recorded to the review ledger"
ok

# ── (4) stale-sha result is discarded unread ─────────────────────────────────
printf 'REVIEW: PASS\n' > "$(_review_result_file 5 oldsha)"
_discard_stale_reviews 5 newsha
[ ! -f "$(_review_result_file 5 oldsha)" ] || fail "stale result file was not discarded"
ok
# Discard is per-PR: a same-sha file and another PR's files are untouched.
printf 'REVIEW: PASS\n' > "$(_review_result_file 5 newsha)"
printf 'REVIEW: PASS\n' > "$(_review_result_file 55 oldsha)"
_discard_stale_reviews 5 newsha
[ -f "$(_review_result_file 5 newsha)" ]  || fail "current-sha result must survive the discard"
[ -f "$(_review_result_file 55 oldsha)" ] || fail "another PR's result must survive the discard"
rm -f "$(_review_result_file 5 newsha)" "$(_review_result_file 55 oldsha)"
ok
# And the gate step itself discards a stale verdict rather than collecting it.
rm -f "$REVIEW_STATE" "$STUB_SPAWN_LOG"; : > "$STUB_SPAWN_LOG"
printf 'REVIEW: BLOCK — stale\n' > "$(_review_result_file 6 oldsha)"
export STUB_VERDICT="REVIEW: PASS" STUB_DELAY=3
s="$(_review_gate_step 6 slug-f newsha)"
[ "$s" = "RUNNING" ] || fail "gate step should discard stale result then dispatch fresh (got $s)"
review_verdict 6 oldsha >/dev/null 2>&1 && fail "stale BLOCK must never reach the ledger"
[ ! -f "$(_review_result_file 6 oldsha)" ] || fail "gate step left the stale result file behind"
ok

# ── (5) dead inflight marker: reaped + re-dispatched ─────────────────────────
rm -f "$REVIEW_RETRIES" "$STUB_SPAWN_LOG"; : > "$STUB_SPAWN_LOG"
bash -c 'exit 0' & _dead_pid=$!; wait "$_dead_pid" 2>/dev/null   # a pid that is definitely dead
printf '%s\n' "$_dead_pid" > "$(_review_inflight_file 7 sha777)"
export STUB_DELAY=3
s="$(_review_gate_step 7 slug-g sha777)"
[ "$s" = "RUNNING" ] || fail "dead inflight should be reaped and re-dispatched (got $s)"
wait_for 5 grep -q '^7 slug-g$' "$STUB_SPAWN_LOG" || fail "re-dispatch after dead inflight never happened"
[ "$(_review_retry_count 7 sha777)" -eq 1 ] || fail "dead inflight should count as one retry"
ok

# ── (6) INFRA-FAIL: retried (never cached), bounded by the retry cap ─────────
rm -f "$REVIEW_STATE" "$REVIEW_RETRIES"
printf 'REVIEW: INFRA-FAIL — severed\n' > "$(_review_result_file 8 sha888)"
s="$(_review_gate_step 8 slug-h sha888)"
[ "$s" = "RETRY" ] || fail "INFRA-FAIL result should report RETRY (got $s)"
review_verdict 8 sha888 >/dev/null 2>&1 && fail "INFRA-FAIL must never be cached to the review ledger"
[ "$(_review_retry_count 8 sha888)" -eq 1 ] || fail "INFRA-FAIL should count as one retry"
ok
# Two more failures reach the cap (3) → FAILED, and no further dispatch happens.
printf 'REVIEW: INFRA-FAIL — severed\n' > "$(_review_result_file 8 sha888)"
s="$(_review_gate_step 8 slug-h sha888)"
[ "$s" = "RETRY" ] || fail "second INFRA-FAIL should still RETRY (got $s)"
printf 'REVIEW: INFRA-FAIL — severed\n' > "$(_review_result_file 8 sha888)"
s="$(_review_gate_step 8 slug-h sha888)"
[ "$s" = "FAILED" ] || fail "third INFRA-FAIL should exhaust retries → FAILED (got $s)"
: > "$STUB_SPAWN_LOG"
s="$(_review_gate_step 8 slug-h sha888)"
[ "$s" = "FAILED" ] || fail "exhausted pr+sha should stay FAILED (got $s)"
[ ! -s "$STUB_SPAWN_LOG" ] || fail "exhausted pr+sha must not be re-dispatched"
ok
# A new sha resets the count: same PR, fresh head → dispatches again.
# (Earlier slow stub reviews may still hold slots — wait for them to finish first.)
_no_live_reviews() { [ "$(_count_live_reviews)" -eq 0 ]; }
wait_for 8 _no_live_reviews || fail "earlier stub reviews never drained"
export STUB_DELAY=0 STUB_VERDICT="REVIEW: PASS"
s="$(_review_gate_step 8 slug-h sha999)"
[ "$s" = "RUNNING" ] || fail "a new head sha should get a fresh retry budget (got $s)"
ok

# ── (7) real herd-review.sh writes the verdict to the result file ────────────
# Stub claude emits stream-json whose 'result' event carries the verdict; HERD_NO_PANE skips herdr.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","result":"Diff verified carefully.\\nREVIEW: PASS"}\n'
exit 0
STUB
chmod +x "$BIN/claude"
RES="$T/real-result-9-sha9"
out="$(HERD_NO_PANE=1 HERD_REVIEW_RESULT_FILE="$RES" WORKTREES_DIR="$T/trees" \
       HERD_CONFIG_FILE="$T/no-such-config" bash "$REVIEW" 9 slug-real 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] || fail "herd-review.sh should exit 0 on PASS (got $rc)"
printf '%s\n' "$out" | grep -q '^REVIEW: PASS$' || fail "herd-review.sh should still print the verdict to stdout"
[ -f "$RES" ] || fail "herd-review.sh did not write the result file"
grep -q '^REVIEW: PASS$' "$RES" || fail "result file does not contain the PASS verdict"
ok

# ── (8) SIGTERM mid-review → INFRA-FAIL written to the result file ───────────
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
sleep 3
exit 0
STUB
chmod +x "$BIN/claude"
RES="$T/real-result-10-sha10"
HERD_NO_PANE=1 HERD_REVIEW_RESULT_FILE="$RES" WORKTREES_DIR="$T/trees" \
  HERD_CONFIG_FILE="$T/no-such-config" bash "$REVIEW" 10 slug-term >/dev/null 2>&1 &
_rev_pid=$!
sleep 1
kill -TERM "$_rev_pid" 2>/dev/null
wait "$_rev_pid" 2>/dev/null
wait_for 10 test -f "$RES" || fail "severed herd-review.sh never wrote its result file"
grep -q '^REVIEW: INFRA-FAIL' "$RES" || fail "severed review should report INFRA-FAIL (got: $(cat "$RES"))"
ok

echo "ALL PASS ($pass checks)"
