#!/usr/bin/env bash
# test-watcher-self-restart.sh — hermetic proof for the WATCHER SELF-RESTART quiesce (HERD-251).
#
# The watcher executes the engine code it loaded at startup. HERD-233 already detects a pull that
# rewrote agent-watch.sh and leaves a "restart recommended" note; WATCHER_SELF_RESTART=on turns that
# note into a QUIESCE-THEN-EXEC so no operator has to restart by hand.
#
#   (1)  lever OFF (default) → byte-identical: the note never arms, no dispatch is held, no journal
#   (2)  lever ON + note     → arms the quiesce ONCE and journals watcher_quiesce
#   (3)  quiesce refuses NEW gate dispatch: _dispatch_review, _healthcheck_gate, spawn_resolver — and
#        the two defence-in-depth refusals return NON-ZERO, so no caller reads them as a live spawn
#   (3b) the stale-base heal (_handle_stale_dup) holds ABOVE record_refix: the refix once-guard is NOT
#        burned, no rail round is spent, nothing is journaled — a dropped dispatch behind a spent guard
#        would strand the PR on a needs-you row forever (PR #376 review)
#   (4)  a collected verdict is NOT held — an in-flight review still lands its PASS in the ledger
#   (5)  _self_restart_journal emits watcher_self_restart reason=engine-update shas=<a>..<b>, and the
#        real _self_restart_exec runs its refusal guards BEFORE that journal (a refused exec is silent)
#   (6)  fail-soft: an exec that cannot happen DISARMS, so gate dispatch resumes on the old code
#   (7)  the drain needs TWO consecutive zero-worker ticks (one quiet tick is not enough)
#   (8)  a live gate worker keeps the watcher waiting, and resets the idle streak
#   (9)  the 15-minute cap expires with a worker STILL live → restarts anyway (trigger=cap-expiry)
#   (10) DRYRUN never arms
#   (11) the console row flips to 'restarting on new engine code · draining N workers' while quiescing
#
# Sources agent-watch.sh in lib mode and drives the shipped functions directly. Legs (5) and (6) run
# the REAL _self_restart_exec under HERD_HERMETIC_GUARD — the same guard that already forbids a live
# watcher inside a test — which returns BEFORE the exec, so this test never replaces its own process
# image. Only the later legs, which must observe the restart DECISION rather than perform it, swap the
# function for a recorder. Fully hermetic: temp dirs only, NO herdr, gh, network, or model.
# Run:  bash tests/test-watcher-self-restart.sh
set -uo pipefail
HERE_T="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE_T/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# ── Stub the pane/network surfaces on PATH (git stays REAL, as in test-main-freshness.sh) ─────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _self_restart_enabled _self_restart_quiescing _self_restart_hold_dispatch \
          _self_restart_arm _self_restart_should_exec _self_restart_exec _self_restart_tick \
          _self_restart_journal _count_gate_workers _dispatch_review _healthcheck_gate \
          spawn_resolver _handle_stale_dup build_main_freshness; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

JLOG="$T/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }

# SEAT BELT: the guard agent-watch.sh already honors to refuse a live watcher inside a test also makes
# _self_restart_exec refuse. Exported for the WHOLE run so a regression that decides to restart one tick
# early can never silently replace THIS process (an exec into a lib-mode source exits 0 with no output —
# a green run that proved nothing). Every leg below therefore observes the decision, never the exec.
export HERD_HERMETIC_GUARD="$T/guard.log"

MAIN_FRESH_RESTART="$TREES/.agent-watch-main-restart"
jhas()   { grep -q "$1" "$JLOG"; }
jcount() { grep -c "$1" "$JLOG" 2>/dev/null || printf '0'; }

EXECED=""
# reset_state — back to a cold, un-armed watcher with no note, no markers, and an empty journal.
reset_state() {
  : > "$JLOG"
  rm -f "$MAIN_FRESH_RESTART" "$TREES"/.review-inflight-* "$TREES"/.health-inflight-* 2>/dev/null || true
  _SELF_RESTART_ARMED=""; _SELF_RESTART_IDLE_TICKS=0; _SELF_RESTART_GAVE_UP=""
  _SELF_RESTART_FROM="oldsha"; _SELF_RESTART_TO=""
  EXECED=""
}
# note — plant the HERD-233 "the pull rewrote agent-watch.sh" note that arms the quiesce.
note() { printf '%s\n' "newsha" > "$MAIN_FRESH_RESTART"; }
# worker <review|health> — a LIVE inflight marker (this pid + its real start time) to drain.
worker() { _marker_write "$TREES/.${1}-inflight-99-shaQ" "$$"; }

# ── (1) lever OFF (default) → byte-inert ─────────────────────────────────────────────────────────
reset_state; note
WATCHER_SELF_RESTART=off _self_restart_tick
_self_restart_quiescing            && fail "(1) OFF armed the quiesce"
[ ! -s "$JLOG" ]                   || fail "(1) OFF journaled: $(cat "$JLOG")"
WATCHER_SELF_RESTART=off _self_restart_hold_dispatch && fail "(1) OFF held a gate dispatch"
build_main_freshness
case "${MAIN_FRESHNESS:-}" in *"restart recommended"*) ;; *) fail "(1) OFF lost the recommendation row: ${MAIN_FRESHNESS:-<empty>}" ;; esac
ok

# ── (2) lever ON + note → arms ONCE, journals watcher_quiesce ────────────────────────────────────
reset_state; note
export WATCHER_SELF_RESTART=on
_self_restart_tick                                       # arms; 0 workers → idle=1 (no exec yet)
_self_restart_quiescing            || fail "(2) ON did not arm on the note"
jhas 'watcher_quiesce reason engine-update shas oldsha..newsha' \
                                   || fail "(2) missing watcher_quiesce journal: $(cat "$JLOG")"
_self_restart_arm                                        # a second arm is a no-op
[ "$(jcount 'watcher_quiesce')" = "1" ] || fail "(2) re-armed / re-journaled: $(jcount 'watcher_quiesce')"
ok

# ── (3) quiesce REFUSES new gate dispatch ────────────────────────────────────────────────────────
# Still armed from (2): every dispatch site must return without spawning or recording anything.
_self_restart_hold_dispatch        || fail "(3) armed watcher does not hold dispatch"

# Both defence-in-depth refusals must return NON-ZERO. `_resolver_in_flight … || spawn_resolver …`
# reads a zero rc as "a resolver is now running" and paints 'rebasing · awaiting push' over nothing.
_dispatch_review 77 quiesce-slug shaZ && fail "(3) _dispatch_review returned 0 while refusing to spawn"
[ -z "$(ls "$TREES"/.review-inflight-77-* 2>/dev/null)" ] || fail "(3) _dispatch_review spawned a reviewer while quiescing"
jhas 'review_dispatched'           && fail "(3) _dispatch_review journaled a dispatch while quiescing"

_RESOLVE_RECORDED=""
record_resolve_attempt() { _RESOLVE_RECORDED=1; }
spawn_resolver quiesce-slug 77 feat/quiesce-slug shaZ && fail "(3) spawn_resolver returned 0 while refusing to spawn"
[ -z "$_RESOLVE_RECORDED" ]        || fail "(3) spawn_resolver burned a respawn round while quiescing"

# _healthcheck_gate reaches its dispatch branch past the sha-cache + in-flight checks; both are empty
# here, so a held tick must report QUEUED, paint an honest row, and leave no suite marker behind.
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate 77 quiesce-slug "$T" 0 shaZ
[ "$_HC_RESULT" = "QUEUED" ]       || fail "(3) _healthcheck_gate did not hold (got '${_HC_RESULT:-<empty>}')"
[ -z "$(ls "$TREES"/.health-inflight-* 2>/dev/null)" ] || fail "(3) _healthcheck_gate ran a suite while quiescing"
case "${DISPLAY[0]:-}" in *"restarting on new engine code"*) ;; *) fail "(3) health hold row not honest: ${DISPLAY[0]:-<empty>}" ;; esac
ok

# ── (3b) the stale-base heal holds ABOVE record_refix — the once-guard is never burned ───────────
# The PR #376 review's blocking finding. _handle_stale_dup writes the refix once-guard and journals
# stale_refix_resolver BEFORE it calls spawn_resolver, so a refusal further down would drop the
# dispatch behind a spent guard: refix_attempted(pr,sha,stale) is permanently true, one rail round is
# gone, no builder exists to advance the head sha, and every later tick renders a durable needs-you row
# for a heal the watcher itself declined. The hold therefore sits with its sibling deferrals, above the
# ledger write. Still armed from (2).
reset_state; note; _self_restart_tick
export STALE_BASE_AUTOFIX=on
_STALE_PR=80; _STALE_SHA=shaSTALE; _STALE_SLUG=stale-slug
_STALE_WT="$T/stale-wt"; mkdir -p "$_STALE_WT"
render() { :; }                    # the heal renders mid-dispatch; the console is not under test here
DISPLAY=()
# A worktree that EXISTS with no live builder is exactly the reviewed path: without the hold this
# reaches `record_refix` → journal stale_refix_resolver → spawn_resolver. (An absent worktree would
# escalate harmlessly before the ledger write, and would prove nothing.)
_handle_stale_dup "$_STALE_PR" "$_STALE_SLUG" "$_STALE_SHA" 0 "$_STALE_WT" "feat/$_STALE_SLUG" stale-base "base moved"
refix_attempted "$_STALE_PR" "$_STALE_SHA" stale && fail "(3b) the quiesce burned the refix once-guard"
[ "$(refix_rail_count "$_STALE_PR" stale)" = "0" ] || fail "(3b) the quiesce spent a refix rail round: $(refix_rail_count "$_STALE_PR" stale)"
jhas 'stale_refix'                 && fail "(3b) the quiesce journaled a stale heal it never dispatched: $(cat "$JLOG")"
case "${DISPLAY[0]:-}" in *"stale base"*"restarting on new engine code"*) ;;
  *) fail "(3b) stale hold row not honest: ${DISPLAY[0]:-<empty>}" ;; esac
case "${DISPLAY[0]:-}" in *"awaiting push"*) fail "(3b) painted work in flight with nothing running" ;; esac
# …and once the quiesce clears, the SAME sha is still healable: nothing was consumed.
_SELF_RESTART_ARMED=""; _SELF_RESTART_IDLE_TICKS=0
_self_restart_hold_dispatch        && fail "(3b) still holding after the quiesce cleared"
refix_attempted "$_STALE_PR" "$_STALE_SHA" stale && fail "(3b) the sha is no longer healable after the hold"
unset STALE_BASE_AUTOFIX
ok

# ── (4) an in-flight review still COLLECTS its verdict while quiescing ───────────────────────────
# The collect branch of _review_gate_step sits UPSTREAM of the hold: a worker that finished mid-drain
# lands its PASS in the ledger, or the drain would throw away work the watcher already paid for.
reset_state; note; _self_restart_tick
printf 'REVIEW: PASS\n' > "$(_review_result_file 78 shaC)"
step="$(_review_gate_step 78 collect-slug shaC)"
[ "$step" = "PASS" ]               || fail "(4) a finished review did not collect while quiescing (got '$step')"
[ "$(review_verdict 78 shaC)" = "PASS" ] || fail "(4) the collected PASS never reached the ledger"
# …and with no result waiting, a fresh candidate is HELD rather than re-dispatched.
[ "$(_review_gate_step 79 hold-slug shaD)" = "QUEUED" ] || fail "(4) a fresh candidate was not held"
ok

# ── (5) the restart event's shape, and that a REFUSED exec never emits it ────────────────────────
reset_state
_SELF_RESTART_FROM=oldsha; _SELF_RESTART_TO=newsha
_self_restart_journal drained 0 8
jhas 'watcher_self_restart reason engine-update shas oldsha..newsha' \
                                   || fail "(5) missing watcher_self_restart journal: $(cat "$JLOG")"
jhas 'trigger drained'             || fail "(5) the restart line does not name its trigger"
# The real exec runs its refusal guards ABOVE the journal, so an exec that cannot happen emits NO
# watcher_self_restart event — a consumer counting them counts restarts that actually occurred.
: > "$JLOG"
_self_restart_exec drained 0 8     && fail "(5) exec returned 0 under the hermetic guard — it must refuse"
[ ! -s "$JLOG" ]                   || fail "(5) a refused exec journaled a restart: $(cat "$JLOG")"
ok

# ── (6) fail-soft: an exec that cannot happen DISARMS (dispatch resumes on the old code) ─────────
reset_state; note
_self_restart_tick; _self_restart_tick                   # two quiet ticks → tries to exec, is refused
_self_restart_quiescing            && fail "(6) a refused exec left the watcher quiesced forever"
_self_restart_hold_dispatch        && fail "(6) a refused exec kept holding gate dispatch"
jhas 'watcher_self_restart result skipped reason exec-unavailable' \
                                   || fail "(6) the fail-soft fallback was not journaled: $(cat "$JLOG")"
[ -s "$MAIN_FRESH_RESTART" ]       || fail "(6) the fail-soft path dropped the recommendation note"
# The refusal LATCHES: the note is still on disk, so without the latch the next ticks would re-arm,
# hold dispatch, refuse again, and spin — stalling every other tick's gates and spamming the journal.
_self_restart_tick; _self_restart_tick; _self_restart_tick
_self_restart_quiescing            && fail "(6) a refused exec re-armed on a later tick"
_self_restart_hold_dispatch        && fail "(6) a refused exec held dispatch on a later tick"
[ "$(jcount 'watcher_quiesce')" = "1" ]        || fail "(6) re-armed: $(jcount 'watcher_quiesce') quiesce lines"
[ "$(jcount 'result skipped')" = "1" ]         || fail "(6) refusal re-journaled: $(jcount 'result skipped') lines"
ok

# From here on the restart DECISION is what is under test, not the process replacement: record it.
_self_restart_exec() { EXECED="$1"; return 0; }

# ── (7) the drain needs TWO consecutive zero-worker ticks ────────────────────────────────────────
reset_state; note
_self_restart_tick                                       # tick 1: arms, sees 0 workers, idle=1
[ -z "$EXECED" ]                   || fail "(7) restarted after a single quiet tick"
[ "$_SELF_RESTART_IDLE_TICKS" = "1" ] || fail "(7) idle streak not 1 after one tick"
_self_restart_tick                                       # tick 2: idle=2 → exec
[ "$EXECED" = "drained" ]          || fail "(7) did not restart after two quiet ticks (got '${EXECED:-<none>}')"
ok

# ── (8) a LIVE gate worker keeps the watcher waiting, and resets the idle streak ─────────────────
reset_state; note
_self_restart_tick                                       # arms; 0 workers → idle=1
worker health                                            # a suite is still draining
_self_restart_tick
[ -z "$EXECED" ]                   || fail "(8) restarted with a live worker in flight"
[ "$_SELF_RESTART_IDLE_TICKS" = "0" ] || fail "(8) a live worker did not reset the idle streak"
[ "$(_count_gate_workers)" = "1" ] || fail "(8) _count_gate_workers miscounted the live worker"
rm -f "$TREES"/.health-inflight-*                        # the suite collects
_self_restart_tick; [ -z "$EXECED" ] || fail "(8) restarted on the first quiet tick after the drain"
_self_restart_tick
[ "$EXECED" = "drained" ]          || fail "(8) never restarted once the worker drained"
ok

# ── (9) cap expiry restarts even with a worker STILL live ────────────────────────────────────────
# The offset is an ABSOLUTE 15 min + 1 s — never $SELF_RESTART_CAP_SECS itself, or a widened cap would
# widen the test with it and this leg would pass against a watcher that waits forever.
reset_state; note
_self_restart_tick                                       # arms
worker review                                            # a reviewer that never finishes
_SELF_RESTART_ARMED=$(( $(date +%s) - 901 ))             # armed 15 min + 1 s ago
_self_restart_tick
[ "$EXECED" = "cap-expiry" ]       || fail "(9) the max-wait cap did not fire (got '${EXECED:-<none>}')"
# …and one second INSIDE the cap it is still waiting on the live worker.
reset_state; note; _self_restart_tick; worker review
_SELF_RESTART_ARMED=$(( $(date +%s) - 899 ))
_self_restart_tick
[ -z "$EXECED" ]                   || fail "(9) restarted before the 15-minute cap expired"
ok

# ── (10) DRYRUN never arms ───────────────────────────────────────────────────────────────────────
reset_state; note
DRYRUN=1 _self_restart_tick
_self_restart_quiescing            && fail "(10) DRYRUN armed the quiesce"
[ -z "$EXECED" ]                   || fail "(10) DRYRUN restarted the watcher"
[ ! -s "$JLOG" ]                   || fail "(10) DRYRUN journaled: $(cat "$JLOG")"
ok

# ── (11) the console row names the restart + the workers it still drains ─────────────────────────
reset_state; note
_self_restart_tick                                       # arm (0 workers, idle=1 — no exec)
worker health; worker review
build_main_freshness
case "${MAIN_FRESHNESS:-}" in *"restarting on new engine code"*"draining 2 gate workers"*) ;;
  *) fail "(11) quiesce row not rendered: ${MAIN_FRESHNESS:-<empty>}" ;; esac
case "${MAIN_FRESHNESS:-}" in *"restart recommended"*) fail "(11) still asking the operator to restart" ;; esac
case "${MAIN_FRESHNESS:-}" in *"MAIN STALE"*) fail "(11) a quiesce must not paint a STALE row" ;; esac
ok

echo "PASS: test-watcher-self-restart.sh ($pass checks)"
