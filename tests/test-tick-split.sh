#!/usr/bin/env bash
# test-tick-split.sh — gate proof for the tick factoring (HERD-323, P3g, EPIC HERD-300).
#
# P3g splits agent-watch.sh's tick body into two halves so the live-engine cutover seat stops flying
# instrument-only: when ENGINE_IMPL=python owns a tick, the whole bash body used to be skipped, so
# nothing rendered and no queued spawn drained. The factoring:
#
#   _tick_act              — the ACTION pass (gate dispatch, the auto-merge candidate loop, conflict-
#                            resolver bounces). This is the half the Python engine replaces; it is
#                            SKIPPED in bash whenever Python owned the tick.
#   _tick_render_reconcile — runs EVERY cycle regardless of tick owner: observe + console paint
#                            (Phase A), the herd_engine_live_tick guard around the action pass, then
#                            the spawn-queue drain + reconcile/sweep legs (Phase C).
#
# This is a PURE factoring, so the load-bearing claims are about CONTROL FLOW, proven hermetically by
# sourcing the REAL watcher in lib mode and driving the two entry points with the leaf helpers stubbed
# as trace recorders (the leaves are unchanged; only which half runs when is under test):
#
#   (1) both halves are defined after a lib-mode source (i.e. before the lib-return, usable by tests).
#   (2) STRUCTURE — _tick_render_reconcile guards _tick_act behind herd_engine_live_tick; _tick_act
#       carries the action pass (do_merge + spawn_resolver moved into it wholesale).
#   (3) BASH MODE (byte-identical) — herd_engine_live_tick returns non-zero, so _tick_render_reconcile
#       paints (render), THEN runs the action pass (_tick_act), THEN drains + reconciles (Phase C).
#   (4) PYTHON-OWNED — herd_engine_live_tick returns zero, so _tick_act is SKIPPED, but the console
#       still renders AND the spawn queue still drains: the instrument panel keeps painting.
#
# Run:  bash tests/test-tick-split.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"
[ -f "$WATCH" ] || { echo "FAIL: missing $WATCH" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS + 1)); }

# Source the REAL watcher in lib mode: helpers + the factored halves, no loop, no re-exec. The
# lib-mode source returns before the startup one-shots and the while loop, so both halves must be
# defined BEFORE that return to be reachable here.
source_lib() {
  export AGENT_WATCH_LIB=1
  export HERD_CONFIG_FILE="$T/no-such-config"
  export WORKTREES_DIR="$T/trees"
  export JOURNAL_FILE="$T/journal.jsonl"
  mkdir -p "$T/trees" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "FAIL: lib-mode source failed" >&2; exit 1; }
}

# ── (1) both halves defined after a lib-mode source ─────────────────────────────────────────────
( source_lib; declare -F _tick_act >/dev/null || exit 1; declare -F _tick_render_reconcile >/dev/null || exit 1 ) \
  || fail "the factored halves are not both defined after a lib-mode source (must be before the lib-return)"
pass

# ── (2) structure: the guard wires the action pass; the action pass carries the merges/resolvers ──
(
  source_lib
  rbody="$(declare -f _tick_render_reconcile)"
  # herd_engine_live_tick must appear BEFORE _tick_act in the render half (the guard order)
  pre="${rbody%%_tick_act*}"
  case "$pre" in *herd_engine_live_tick*) : ;; *) echo "no-guard" >&2; exit 1 ;; esac
  abody="$(declare -f _tick_act)"
  case "$abody" in *do_merge*spawn_resolver*) : ;; *) echo "no-action-pass" >&2; exit 1 ;; esac
) || fail "_tick_render_reconcile must guard _tick_act behind herd_engine_live_tick, and _tick_act must carry the action pass (do_merge + spawn_resolver)"
pass

# ── shared harness: stub every leaf the two halves call, so only the tick's control flow runs ─────
# Records the ordered call trace to $TRACE; herd_engine_live_tick's return code (the tick owner) and
# the trace path are injected per scenario.
run_tick() {
  local owner_rc="$1" trace="$2"
  (
    source_lib
    : > "$trace"
    _rec(){ printf '%s\n' "$1" >> "$trace"; }

    # tick owner under test: 0 = Python owned this tick, non-zero = bash owns it
    herd_engine_live_tick(){ _rec engine_live_tick; return "$owner_rc"; }

    # the two things we assert on
    render(){ _rec render; }
    _drain_spawn_queue(){ _rec drain; }
    _tick_act(){ _rec ACT; }

    # Phase A leaves → recorders / inert stubs
    for fn in _sweep_gate_corpses _collect_main_health _sweep_lifecycle _sweep_trigger_tick \
              _engine_seat_reconcile_tick build_header build_landed build_blocked \
              build_tracker_drift build_spawn_holds build_engine_note build_engine_seat_note \
              build_main_health _main_fresh_recheck build_main_freshness build_sweep_note \
              build_health_headroom_note build_retiring build_celebrate build_pasture \
              _inbox_scan build_operator_inbox _builder_notes_scan build_builder_notes; do
      eval "$fn(){ :; }"
    done
    _prs_fetch_tick(){ PRS_JSON='[]'; PRS_LOOKUP_OK=1; }
    herd_driver_agent_list_json(){ printf '{}'; }
    retirement_tick(){ RETIRE_REAPED=0; }
    _discover_feature_worktrees(){ :; }                 # no worktrees → the classification loop is skipped
    _operator_inbox_enabled(){ return 1; }              # inbox off → _inbox_scan never reached

    # Phase C leaves → recorders / inert stubs (the gated sweeps are held off via high intervals below)
    for fn in _reconcile_resolver_panes _handle_coordinator_watchdog reconcile_main_freshness \
              reconcile_map_freshness _self_restart_tick reconcile_main_health \
              _sweep_orphan_tabs _sweep_tracker_state _sweep_journal_audit _sweep_merged_prs \
              herd_engine_autoupdate_tick herd_engine_shadow_tick; do
      eval "$fn(){ :; }"
    done

    # per-tick state the inline body reads (initialised after the lib-return in real runs)
    MAIN="$T"; TREES="$T/trees"; DEFAULT_BRANCH="main"; DRYRUN=""
    PRS_JSON='[]'; PRS_LOOKUP_OK=1; AGENTS_JSON='{}'; WT=""; RETIRE_REAPED=0
    _INBOX_SCAN_TICK=0;   _INBOX_SCAN_INTERVAL=999
    _ORPHAN_SWEEP_TICK=0; _ORPHAN_SWEEP_INTERVAL=999
    _TRACKER_SWEEP_TICK=0; _TRACKER_SWEEP_INTERVAL=999
    _PMS_SWEEP_TICK=0;    _PMS_SWEEP_INTERVAL=999
    _ENGINE_TICK=0;       _ENGINE_INTERVAL=999

    _tick_render_reconcile
  )
}

# an ordered-subsequence check: does $2 contain the space-separated markers of $1, in order?
has_order() {
  local want="$1" file="$2" line
  while read -r line; do
    grep -qxF "$line" "$file" || return 1
  done < <(printf '%s\n' $want)
  # order check
  local prev=0 n
  for tok in $want; do
    n="$(grep -nxF "$tok" "$file" | head -1 | cut -d: -f1)"
    [ -n "$n" ] || return 1
    [ "$n" -ge "$prev" ] || return 1
    prev="$n"
  done
  return 0
}

# ── (3) bash mode (byte-identical): render → action pass → drain, all in one cycle ───────────────
BTRACE="$T/bash.trace"
run_tick 1 "$BTRACE" || fail "bash-mode tick errored"
grep -qxF ACT   "$BTRACE" || fail "bash mode: the action pass (_tick_act) did not run"
grep -qxF render "$BTRACE" || fail "bash mode: the console did not render"
grep -qxF drain  "$BTRACE" || fail "bash mode: the spawn queue did not drain"
has_order "render ACT drain" "$BTRACE" || fail "bash mode: expected order render → action pass → drain"
pass

# ── (4) python-owned tick: action pass SKIPPED, but console renders + spawn queue drains ─────────
PTRACE="$T/py.trace"
run_tick 0 "$PTRACE" || fail "python-owned tick errored"
grep -qxF ACT   "$PTRACE" && fail "python-owned tick: the action pass must be SKIPPED (Python owns it)"
grep -qxF render "$PTRACE" || fail "python-owned tick: the console must still render (instrument panel)"
grep -qxF drain  "$PTRACE" || fail "python-owned tick: the spawn queue must still drain"
has_order "render drain" "$PTRACE" || fail "python-owned tick: render must precede the drain leg"
pass

echo "ok — tick factoring: $PASS checks passed"
