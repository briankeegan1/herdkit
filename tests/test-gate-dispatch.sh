#!/usr/bin/env bash
# test-gate-dispatch.sh — hermetic tests for GATE_DISPATCH (serial | parallel), HERD-73.
#
# GATE_DISPATCH governs WHEN the watcher's action pass fires the pre-merge review relative to the
# healthcheck for a (pr,sha):
#   serial   (default) — the review dispatches only AFTER the healthcheck outcome lands.
#   parallel           — the review dispatches at the same tick the healthcheck STARTS, concurrently.
#
# The hinge is _predispatch_review_if_parallel(), the early review kick the action pass runs BEFORE
# the healthcheck gate. These tests source agent-watch.sh in lib mode (the same seam test-parallel-
# review.sh uses) with HERD_REVIEW_BIN pointed at a stub reviewer, and assert:
#   (1) SERIAL (default + unknown value) — _predispatch_review_if_parallel is a strict NO-OP: no
#       reviewer is dispatched, no inflight marker written. This is the "serial mode's dispatch
#       ordering is UNCHANGED" guarantee — in serial the ONLY dispatch site is the merge-path gate.
#   (2) PARALLEL — the early kick dispatches the reviewer (inflight marker + spawn), reporting RUNNING.
#   (3) IDEMPOTENT — an early parallel dispatch + the later merge-path _review_gate_step for the SAME
#       pr+sha is exactly ONE review run (sha-keyed review-once respected).
#   (4) REVIEW_CONCURRENCY respected — an over-cap early dispatch reports QUEUED and does not spawn.
#   (5) HEALTH CODE-ERROR does NOT kill an in-flight review — a same-sha re-entry (the parallel path a
#       health-blocked candidate takes each tick) collects/records the finished verdict rather than
#       severing or re-dispatching the reviewer (spawned exactly once, PASS recorded).
#   (6) DRY-RUN — the early kick is a no-op even under parallel (never spawns a reviewer).
#
# Fully hermetic: local temp only; stubs gh/git/herdr (PATH) and the reviewer (HERD_REVIEW_BIN). No
# network, no model, no real PRs.
# Run:  bash tests/test-gate-dispatch.sh
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
# Logs every invocation to STUB_SPAWN_LOG and writes STUB_VERDICT to the result file (atomic mv) as
# its last act after STUB_DELAY seconds. NOTE: no TERM trap — so if a reviewer were killed mid-run it
# would write NO result (proving, in test 5, that a collected PASS means it ran to completion).
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

for fn in _gate_dispatch_mode _predispatch_review_if_parallel _review_gate_step \
          _review_inflight_file _review_result_file review_verdict; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

export STUB_SPAWN_LOG="$T/spawns.log"

# ── (0) _gate_dispatch_mode resolves unknown/empty → serial (fail safe) ──────
[ "$(GATE_DISPATCH=parallel _gate_dispatch_mode)" = "parallel" ] || fail "parallel not resolved"
[ "$(GATE_DISPATCH=serial   _gate_dispatch_mode)" = "serial" ]   || fail "serial not resolved"
[ "$(GATE_DISPATCH=bogus    _gate_dispatch_mode)" = "serial" ]   || fail "unknown value must fall back to serial"
[ "$(unset GATE_DISPATCH; _gate_dispatch_mode)" = "serial" ]     || fail "unset must default to serial"
ok

# ── (1) SERIAL (default): early kick is a strict NO-OP — dispatch ordering UNCHANGED ──────────
: > "$STUB_SPAWN_LOG"
export DRYRUN=""
export STUB_DELAY=3 STUB_VERDICT="REVIEW: PASS"
GATE_DISPATCH=serial _predispatch_review_if_parallel 1 slug-a aaa111
[ ! -f "$(_review_inflight_file 1 aaa111)" ] || fail "serial mode must NOT write an inflight marker (early dispatch leaked)"
sleep 0.4
[ ! -s "$STUB_SPAWN_LOG" ] || fail "serial mode must NOT spawn a reviewer early (ordering changed!)"
ok
# An unknown value must behave exactly like serial.
GATE_DISPATCH=nonsense _predispatch_review_if_parallel 1 slug-a aaa111
[ ! -f "$(_review_inflight_file 1 aaa111)" ] || fail "unknown GATE_DISPATCH must be serial (no early dispatch)"
[ ! -s "$STUB_SPAWN_LOG" ] || fail "unknown GATE_DISPATCH spawned a reviewer early"
ok

# ── (2) PARALLEL: the early kick dispatches the reviewer ─────────────────────
: > "$STUB_SPAWN_LOG"
GATE_DISPATCH=parallel _predispatch_review_if_parallel 2 slug-b bbb222
[ -f "$(_review_inflight_file 2 bbb222)" ] || fail "parallel mode must dispatch early (no inflight marker)"
wait_for 5 test -s "$STUB_SPAWN_LOG" || fail "parallel early dispatch never spawned the reviewer"
[ "$(grep -c '^2 slug-b$' "$STUB_SPAWN_LOG")" -eq 1 ] || fail "expected exactly one early dispatch for pr2"
ok

# ── (3) IDEMPOTENT: early kick + merge-path gate step = ONE review run ───────
# The merge-path _review_gate_step for the same pr+sha finds the in-flight reviewer and reports
# RUNNING — never a second dispatch (sha-keyed review-once respected).
s="$(_review_gate_step 2 slug-b bbb222)"
[ "$s" = "RUNNING" ] || fail "merge-path gate step after an early dispatch should report RUNNING (got $s)"
[ "$(grep -c '^2 slug-b$' "$STUB_SPAWN_LOG")" -eq 1 ] || fail "early kick + merge-path step double-dispatched pr2"
ok

# ── (4) REVIEW_CONCURRENCY respected by the early kick — over-cap → QUEUED, no spawn ──────────
# pr2 already holds one live slot (delay 3). Fill the second, then a third early kick must QUEUE.
GATE_DISPATCH=parallel _predispatch_review_if_parallel 3 slug-c ccc333   # takes the 2nd slot
wait_for 5 grep -q '^3 slug-c$' "$STUB_SPAWN_LOG" || fail "pr3 early dispatch never spawned"
[ "$(_count_live_reviews)" -eq 2 ] || fail "expected 2 live reviews before the cap bites (got $(_count_live_reviews))"
GATE_DISPATCH=parallel _predispatch_review_if_parallel 4 slug-d ddd444   # over the cap → QUEUED
[ ! -f "$(_review_inflight_file 4 ddd444)" ] || fail "an over-cap early kick must NOT dispatch (QUEUED)"
grep -q '^4 slug-d$' "$STUB_SPAWN_LOG" && fail "queued PR must not spawn a reviewer"
ok

# ── (5) HEALTH CODE-ERROR does not kill an in-flight review ──────────────────
# Model a candidate whose healthcheck code-errors while its parallel review is in flight: the action
# pass `continue`s (never reaching the merge-path gate), and the SAME-sha early kick re-runs each
# tick. That re-entry must COLLECT the finished verdict, not sever/re-dispatch the reviewer. With a
# no-trap stub, a killed reviewer would leave no result → the collected PASS proves it finished.
rm -f "$REVIEW_STATE" "$STUB_SPAWN_LOG"; : > "$STUB_SPAWN_LOG"
# Wait for slots to free from earlier slow reviews so this dispatch actually lands.
_no_live() { [ "$(_count_live_reviews)" -eq 0 ]; }
wait_for 8 _no_live || fail "earlier stub reviews never drained"
export STUB_DELAY=2 STUB_VERDICT="REVIEW: PASS"
GATE_DISPATCH=parallel _predispatch_review_if_parallel 5 slug-e eee555   # tick where health STARTS
[ -f "$(_review_inflight_file 5 eee555)" ] || fail "pr5 review not dispatched early"
_rev_pid="$(head -1 "$(_review_inflight_file 5 eee555)" 2>/dev/null)"
# Health code-errored → candidate continues; re-enter the SAME-sha early kick each tick until the
# reviewer finishes. It must never kill the reviewer, and must record the verdict when it lands.
wait_for 6 test -f "$(_review_result_file 5 eee555)" || fail "reviewer never wrote its result (killed?)"
kill -0 "$_rev_pid" 2>/dev/null && fail "reviewer should have exited on its own, not still running"
GATE_DISPATCH=parallel _predispatch_review_if_parallel 5 slug-e eee555   # collecting re-entry
[ "$(review_verdict 5 eee555)" = "PASS" ] || fail "same-sha re-entry must record the finished verdict"
[ "$(grep -c '^5 slug-e$' "$STUB_SPAWN_LOG")" -eq 1 ] || fail "health-blocked review was re-dispatched (should run exactly once)"
ok

# ── (5b) REVIEW-ONCE across MANY ticks: a candidate that stays a candidate but NEVER merges (health
# error, approve/observe/human-verify hold, branch-protection block) must NOT re-dispatch once its
# verdict is recorded. Before the ledger-precondition guard, the early kick found the collected markers
# gone and dispatched a brand-new (Opus) review every tick — spawns + duplicate ledger rows climbing
# 1→2→3. Re-enter the early kick several ticks AFTER the PASS was recorded and assert it stays at one.
for _ in 1 2 3 4; do GATE_DISPATCH=parallel _predispatch_review_if_parallel 5 slug-e eee555; done
[ "$(grep -c '^5 slug-e$' "$STUB_SPAWN_LOG")" -eq 1 ] || fail "held candidate re-dispatched the review after its verdict (spawns should stay 1)"
[ "$(awk -v p=5 -v s=eee555 '$2==p && $3==s' "$REVIEW_STATE" | grep -c .)" -eq 1 ] || fail "duplicate review-ledger rows accumulated for pr5+sha (review-once broken)"
ok
# Same for a BLOCK verdict: a blocked+held candidate must not re-review its sha either.
rm -f "$STUB_SPAWN_LOG"; : > "$STUB_SPAWN_LOG"
wait_for 8 _no_live || fail "reviews never drained before the BLOCK case"
export STUB_DELAY=0 STUB_VERDICT="REVIEW: BLOCK — held"
GATE_DISPATCH=parallel _predispatch_review_if_parallel 11 slug-k kkk111        # dispatch
wait_for 5 test -f "$(_review_result_file 11 kkk111)" || fail "pr11 result never arrived"
GATE_DISPATCH=parallel _predispatch_review_if_parallel 11 slug-k kkk111        # collect → record BLOCK
[ "$(review_verdict 11 kkk111)" = "BLOCK" ] || fail "BLOCK not recorded for pr11"
for _ in 1 2 3; do GATE_DISPATCH=parallel _predispatch_review_if_parallel 11 slug-k kkk111; done
[ "$(grep -c '^11 slug-k$' "$STUB_SPAWN_LOG")" -eq 1 ] || fail "blocked candidate re-dispatched after its BLOCK (spawns should stay 1)"
ok

# ── (6) DRY-RUN: early kick is a no-op even under parallel ────────────────────
rm -f "$REVIEW_STATE"; : > "$STUB_SPAWN_LOG"
export DRYRUN=1
GATE_DISPATCH=parallel _predispatch_review_if_parallel 9 slug-i iii999
[ ! -f "$(_review_inflight_file 9 iii999)" ] || fail "dry-run must not dispatch a reviewer"
sleep 0.4
[ ! -s "$STUB_SPAWN_LOG" ] || fail "dry-run early kick spawned a reviewer"
export DRYRUN=""
ok

# ── (7) empty head sha: early kick is a no-op (can't dispatch without a sha) ──
GATE_DISPATCH=parallel _predispatch_review_if_parallel 10 slug-j ""
[ ! -f "$(_review_inflight_file 10 '')" ] || fail "empty sha must not dispatch"
ok

echo "ALL PASS ($pass checks)"
