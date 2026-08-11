#!/usr/bin/env bash
# journal-act.sh — THE RAIL-DISPATCH half of "journal-audit findings become ACTIONS" (HERD-544).
#
# THE GAP THIS CLOSES. journal-audit.sh (HERD-238) already has the DETECTION half: it replays a
# bounded journal window and finds the stall classes nothing else watches — a `*_dispatched` with no
# terminal outcome, a `refix_bounce` with no wake, a MAIN RED standing past its TTL, a merge with no
# reap. But every finding is ADVISORY: it renders an inbox row and waits for a human. Meanwhile each
# stall class that DOES auto-resolve has its own rail (refix, stale-base, wedge, dead-builder,
# limit-park, resurrect). Stalls survive exactly in the seam between the two — work that EXISTS but
# that no rail owns. This file is that seam's owner: given one finding class, it drives the ONE rail
# that already knows how to unstick that class, so the auditor becomes the safety net UNDER all rails.
#
# COMPOSITION, NOT REIMPLEMENTATION — the same discipline retirement.sh and sweep.sh follow. Every
# action below is an existing engine primitive invoked through agent-watch.sh's LIB mode
# (AGENT_WATCH_LIB=1); nothing here re-derives what a rail already decides:
#
#   dispatch_no_outcome    → _sweep_gate_corpses (the HERD-185 restart-safe gate hygiene). Frees the
#                            concurrency slot the dead/timed-out worker still holds; the NEXT tick's
#                            gate step then re-dispatches that PR exactly once, through its own
#                            budget/breaker accounting. We free the slot; the gate owns the re-dispatch.
#   refix_bounce_no_wake   → re-deliver the review bounce to the builder's agent pane ONCE and verify
#                            the wake. A wake that lands journals a real `refix_wake_result`, which is
#                            precisely what was missing — the finding closes itself. A wake that does
#                            NOT land journals nothing, so the finding stands and the auditor escalates
#                            it loudly on the next sweep. No refix ROUND is charged: the round for this
#                            bounce was already recorded when the bounce that lost its wake was sent.
#   red_state_stale        → arm the main-health RE-VERIFY rail: drop the run-once marker for the
#                            CURRENT $MAIN HEAD so reconcile_main_health's observed-sha branch
#                            re-dispatches the suite next tick (the MAIN_HEALTH_RECHECK_MINS path,
#                            forced once). A red that was already fixed clears itself through the
#                            existing green→clear path instead of standing for hours.
#   merge_without_reap     → retirement_tick (HERD-164's reconciled invariant) RIGHT NOW instead of
#                            waiting for a tick that may never come: a slug whose PR is merged has no
#                            right to hold an agent, a tab, a worktree or a branch.
#   gates_passed_no_merge  → HERD-634: a re-verify NUDGE for a blessed PR sitting unmerged past its TTL
#                            with NO hold evidence (journal-audit.sh already routed the HELD case — a
#                            core_surface_hold/merge_queue_hold/hold_applied event for the same pr+sha
#                            — to the gates_passed_held no-action reason, so this rail only ever sees
#                            the genuinely unowned kind). Frees any concurrency slot the candidate's
#                            own worker might still be holding (the same HERD-185 hygiene sweep
#                            dispatch_no_outcome uses) and journals a `gates_recheck_requested` re-check
#                            intent so the next tick — and any human reading the log — sees this
#                            candidate was explicitly nudged. NEVER forces a merge: the live engine's
#                            own gate/hold logic is the only thing allowed to decide that.
#   anything else          → `unmapped` on stdout; journal-audit.sh then files a dedup-keyed tracker
#                            item so the gap becomes WORK instead of another report.
#
# BINDING CONSTRAINTS:
#   • NEVER SELF-ARMING — this file is only ever reached from journal-audit.sh's action pass, which is
#     itself dormant unless JOURNAL_AUDIT_ACT=on. Executing it by hand is possible (and is how the
#     unit test drives the unmapped path); nothing schedules it.
#   • ONE BOUNDED ACTION PER INVOCATION — one rail call, no loop, no retry. "Once per finding key" is
#     the CALLER's guarantee (a shared-pool once-guard), so this file never needs its own ledger.
#   • FAIL-SOFT AND ALWAYS rc 0 — an unavailable rail, an unreadable roster, a missing pane, a
#     `gh` outage: each prints an honest result token and exits 0. The auditor's sweep must never fail
#     because a heal could not be attempted, and a heal must never be reported as one that happened.
#   • HONEST RESULT TOKENS — stdout is a SINGLE lowercase token naming what actually happened; it is
#     journaled verbatim as `audit_acted result=<token>`. `retired`/`slot_freed`/`rebounced`/
#     `reverify_armed`/`recheck_armed` mean the rail ran; `rail_off`/`no_pane`/`no_wake`/
#     `pr_lookup_failed`/`unavailable`/`no_head`/`no_slug`/`no_pr`/`unmapped` mean it did not, and say
#     why.
#
# Usage:
#   journal-act.sh <class> <finding-key> [k=v ...]
#     <class>        the journal-audit finding kind (merge_without_reap, dispatch_no_outcome, …).
#     <finding-key>  the finding's stable dedup token — carried for provenance/log only.
#     [k=v ...]      the finding's context, as emitted by the auditor's replay: pr=, sha=, slug=,
#                    round=, event=. Absent fields are simply absent; every rail below states what it
#                    does without them.
#
# Test seam: HERD_JOURNAL_ACT_SELFTEST=1 skips the agent-watch.sh LIB source entirely, so the
# argument parsing + unmapped path can be proven hermetically without standing up a control room.
set -uo pipefail
_JACT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLASS="${1:-}"
# shellcheck disable=SC2034  # provenance only: the caller journals the key; we accept it so the
# invocation reads the same in a log as it does in the auditor that produced it.
KEY="${2:-}"
[ "$#" -ge 2 ] && shift 2 || shift $#

# ── context parse (k=v, from the auditor's replay) ───────────────────────────────────────────────
# Unknown keys are IGNORED, not an error: the auditor may grow a context field before every rail here
# has a use for it, and a finding must never fail to act because it carried one extra fact.
_ja_pr=""; _ja_sha=""; _ja_slug=""; _ja_round=""
for _kv in "$@"; do
  case "$_kv" in
    pr=*)    _ja_pr="${_kv#pr=}" ;;
    sha=*)   _ja_sha="${_kv#sha=}" ;;
    slug=*)  _ja_slug="${_kv#slug=}" ;;
    round=*) _ja_round="${_kv#round=}" ;;
  esac
done

# UNMAPPED IS ANSWERED BEFORE ANY LIB LOAD. An unknown class has no rail to drive, so standing up the
# whole watcher library to say so would be pure cost — and it keeps the unmapped path (the one the
# auditor turns into a filed tracker item) provable with zero control-room fixture.
case "$CLASS" in
  merge_without_reap|dispatch_no_outcome|refix_bounce_no_wake|red_state_stale|gates_passed_no_merge) : ;;
  *) printf 'unmapped\n'; exit 0 ;;
esac

# DRY RUN ACTS ON NOTHING. The watcher's own sweep already returns before reaching the auditor when
# DRYRUN is set, but journal-audit.sh is also a hand-runnable CLI — and two of the arms below (the
# pane re-bounce, the marker drop) are real mutations that the rails they compose would not self-guard.
# Answer honestly and touch nothing.
if [ -n "${DRYRUN:-}" ]; then
  printf 'dryrun\n'; exit 0
fi

if [ "${HERD_JOURNAL_ACT_SELFTEST:-}" = "1" ]; then
  # Self-test: report the class as recognized WITHOUT touching a live control room.
  printf 'selftest\n'; exit 0
fi

# ── helper substrate ─────────────────────────────────────────────────────────────────────────────
# Every primitive below — _sweep_gate_corpses, retirement_tick, _main_health_marker,
# _find_builder_pane_id_any, herd_driver_send_text, _prs_fetch_tick, journal_append, and the resolved
# MAIN/TREES — already lives in agent-watch.sh (and the files it sources). Source it in LIB mode when
# those functions are not already in scope: the same two-caller, no-recursion pattern sweep.sh and
# retirement.sh use. AGENT_WATCH_LIB stays UNEXPORTED so it can never leak into a child process.
if ! command -v _sweep_gate_corpses >/dev/null 2>&1; then
  # shellcheck disable=SC2034  # read by agent-watch.sh on the next line (its lib-mode guard)
  AGENT_WATCH_LIB=1
  # The `[ -f ]` test is LOAD-BEARING (HERD-632): `.` is a bash SPECIAL BUILTIN, so sourcing a path
  # that does not exist KILLS THE SHELL outright, bypassing the `|| { ...; exit 0; }` fallback below.
  # shellcheck source=/dev/null
  [ -f "$_JACT_HERE/agent-watch.sh" ] && . "$_JACT_HERE/agent-watch.sh" || { printf 'unavailable\n'; exit 0; }
  unset AGENT_WATCH_LIB
fi

# ── borrow journal.sh if not already in scope (seam-conformance B4) ──────────────────────────────
# The refix arm journals a `refix_wake_result` on a proven wake. The borrow above already pulls
# journal.sh in on every real path (agent-watch.sh sources it), so this is a no-op there; it only
# fires for a caller that pre-defines _sweep_gate_corpses — skipping the borrow — without having
# sourced journal.sh itself, which would make that record silently vanish. Same explicit-dependency
# form retirement.sh (HERD-439) and sweep.sh adopted: say where journal_append comes from.
if ! command -v journal_append >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$_JACT_HERE/journal.sh"
fi

# _jact_have <fn> — true iff the named rail primitive actually loaded. A LIB source that partially
# failed (an older engine, a consuming project without the watcher) must degrade to `unavailable`,
# never to a call into nothing under `set -u`.
_jact_have() { command -v "$1" >/dev/null 2>&1; }

case "$CLASS" in

  # ── (a) merge without reap → run the retirement invariant NOW ──────────────────────────────────
  merge_without_reap)
    _jact_have retirement_tick || { printf 'unavailable\n'; exit 0; }
    # Fetch the open-PR roster HONESTLY first. retirement_tick's fast path reads $PRS_JSON to skip
    # slugs with an open PR; an EMPTY roster from a failed `gh pr list` would make every live builder
    # look PR-less. The per-slug terminality proof still protects them (an unproven ref is never
    # retired), but running the invariant on a roster we know is blind is exactly the "false red"
    # posture this engine refuses — so a failed lookup declines the action and says so.
    if _jact_have _prs_fetch_tick; then
      _prs_fetch_tick || true
      [ "${PRS_LOOKUP_OK:-0}" = "1" ] || { printf 'pr_lookup_failed\n'; exit 0; }
    fi
    retirement_tick >/dev/null 2>&1 || true
    printf 'retired\n'
    ;;

  # ── (b) dispatched with no terminal → free the slot (HERD-185 hygiene) ─────────────────────────
  dispatch_no_outcome)
    _jact_have _sweep_gate_corpses || { printf 'unavailable\n'; exit 0; }
    # The sweep is the AUTHORITATIVE reaper for both inflight-marker families and is idempotent,
    # mutex-guarded and dry-run-inert. It frees the slot a dead/timed-out worker still holds; the
    # next tick's gate step owns the re-dispatch (with its own retry budget + infra breaker), which
    # is why this action re-dispatches exactly ONCE and can never loop.
    # HERD-607: the sweep itself has no heartbeat blind spot to close — it walks $TREES/.review-inflight-*
    # and .health-inflight-* markers by GLOB, never by the finding's pr/sha/slug context, so it was
    # already a no-op for a heartbeat dispatch (engine_live_dispatched carries neither marker). The
    # real fix is upstream: journal-audit.sh's detector no longer emits dispatch_no_outcome for a
    # dispatch with no pr and no slug, so this arm is never even reached for one.
    _sweep_gate_corpses >/dev/null 2>&1 || true
    printf 'slot_freed\n'
    ;;

  # ── (c) refix bounce with no wake → re-deliver the bounce ONCE ─────────────────────────────────
  refix_bounce_no_wake)
    [ -n "$_ja_slug" ] || { printf 'no_slug\n'; exit 0; }
    _jact_have _find_builder_pane_id_any || { printf 'unavailable\n'; exit 0; }
    _jact_pane="$(_find_builder_pane_id_any "$_ja_slug" 2>/dev/null || true)"
    [ -n "$_jact_pane" ] || { printf 'no_pane\n'; exit 0; }
    _jact_before="$(_agent_status "$_ja_slug" 2>/dev/null || true)"
    # Same shape as the review rail's own bounce prompt, minus the structured finding (the sha-keyed
    # BLOCK cache belongs to the tick that collected the verdict and may be long gone) — the builder
    # is pointed at the PR, which always carries the full review.
    _jact_prompt="PR #${_ja_pr:-?} was review-blocked and the earlier auto-refix bounce never woke you.
Read the full review: gh pr view ${_ja_pr:-?}
Fix every issue the reviewer raised, run the healthcheck, push your fix, and reply to the review comment once done."
    herd_driver_send_text "$_jact_pane" "$_jact_prompt" >/dev/null 2>&1 || true
    if _wait_agent_working "$_ja_slug" "${HERD_REFIX_WAIT_TIMEOUT:-15}" >/dev/null 2>&1; then
      # The wake LANDED. Journal the real `refix_wake_result` the lost bounce never got to write —
      # same (pr, sha, round) the finding keys on — so the very gap that was found is now closed in
      # the journal and no later sweep re-finds it. Only ever journaled on a PROVEN wake: a failed
      # re-bounce must leave the finding standing so the auditor escalates it.
      _jact_after="$(_agent_status "$_ja_slug" 2>/dev/null || true)"
      journal_append refix_wake_result pr "${_ja_pr:-}" sha "${_ja_sha:-}" slug "$_ja_slug" \
        round "${_ja_round:-}" agent_status_before "${_jact_before:-unknown}" \
        agent_status_after "${_jact_after:-unknown}" woke 1 escalated false \
        reason "journal-audit re-bounce (HERD-544): the original bounce recorded no wake result" \
        2>/dev/null || true
      printf 'rebounced\n'
    else
      printf 'no_wake\n'
    fi
    ;;

  # ── (d) standing MAIN RED past TTL → arm the re-verify rail ────────────────────────────────────
  red_state_stale)
    _jact_have _main_health_marker || { printf 'unavailable\n'; exit 0; }
    # A rail that is OFF cannot be triggered, and pretending otherwise would report a heal that never
    # happened. MAIN_HEALTH_TICK=off ⇒ nothing re-verifies $MAIN at all; say so honestly and let the
    # auditor escalate the finding on its next sweep.
    if _jact_have _main_health_enabled && ! _main_health_enabled; then
      printf 'rail_off\n'; exit 0
    fi
    _jact_head="$(git -C "${MAIN:-.}" rev-parse HEAD 2>/dev/null || true)"
    [ -n "$_jact_head" ] || { printf 'no_head\n'; exit 0; }
    _jact_marker="$(_main_health_marker "$_jact_head")"
    # No run-once marker yet ⇒ this sha has NO verdict and reconcile_main_health's observed-sha branch
    # already owns dispatching it. Nothing to arm; deleting nothing would be a lie.
    [ -e "$_jact_marker" ] || { printf 'reverify_pending\n'; exit 0; }
    rm -f "$_jact_marker" 2>/dev/null || true
    printf 'reverify_armed\n'
    ;;

  # ── (e) gates passed, no merge, no hold evidence → re-verify nudge (HERD-634) ──────────────────
  # journal-audit.sh only ever routes the genuinely UNOWNED flavor here — a blessed PR with a
  # core_surface_hold/merge_queue_hold/hold_applied event for the same pr+sha is the gates_passed_held
  # no-action class instead (see journal-audit.sh's _ja_act_no_action_reason). NEVER a forced merge:
  # the live engine's own gate/hold decision owns whether this PR is allowed to land.
  gates_passed_no_merge)
    [ -n "$_ja_pr" ] || { printf 'no_pr\n'; exit 0; }
    # Free any concurrency slot a dead/stuck worker for this candidate might still be holding — the
    # SAME bounded, idempotent, mutex-guarded sweep dispatch_no_outcome uses above.
    if _jact_have _sweep_gate_corpses; then
      _sweep_gate_corpses >/dev/null 2>&1 || true
    fi
    # The re-check intent itself: a record that the next tick (and any human reading the log) should
    # treat this candidate as due for re-evaluation, never a mutation of the merge decision.
    journal_append gates_recheck_requested pr "$_ja_pr" sha "${_ja_sha:-}" slug "${_ja_slug:-}" \
      reason "journal-audit re-verify (HERD-634): gates passed, no hold evidence, TTL exceeded" \
      2>/dev/null || true
    printf 'recheck_armed\n'
    ;;
esac

exit 0
