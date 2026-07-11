#!/usr/bin/env bash
# test-tick-split.sh — gate proof for the tick after the P5 CUTOVER (HERD-306, EPIC HERD-300 FINALE).
#
# P5b DELETED the bash action pass (_tick_act): pysrc/herd/live_runtime.py is now the SOLE engine core,
# and the supervisor hands it every tick through a WATCHDOG instead of a bash fallback. The tick shape:
#
#   _engine_tick_watchdog  — runs the Python live tick (herd_engine_live_tick); a FAULT is retried
#                            in-tick with backoff, a fault streak past _ENGINE_FAULT_MAX paints a loud
#                            'engine down' banner + journals engine_down + fires ONE notification, and it
#                            NEVER runs a gate/merge in bash (there is none) — a fault is a safe HOLD.
#   _tick_render_reconcile — runs EVERY cycle: observe + console paint (Phase A), the engine watchdog,
#                            then the spawn-queue drain + reconcile/sweep legs (Phase C).
#
# The load-bearing claims are about CONTROL FLOW, proven hermetically by sourcing the REAL watcher in
# lib mode and driving the entry points with the leaf helpers stubbed as trace recorders:
#
#   (1) _tick_render_reconcile + _engine_tick_watchdog are defined after a lib-mode source, and the
#       DELETED _tick_act is gone (no bash action pass survives).
#   (2) STRUCTURE — _tick_render_reconcile drives the action pass through _engine_tick_watchdog (never a
#       direct _tick_act), and the watchdog gates the action on herd_engine_live_tick.
#   (3) CLEAN tick — a Python tick that exits 0: the watchdog reports success (no engine-down banner) and
#       runs NO bash action pass.
#   (4) FAULTED tick — a Python tick that keeps faulting: NO merge/gate/resolver runs in bash (there is
#       no action pass), and past _ENGINE_FAULT_MAX consecutive faulty ticks the watchdog paints the loud
#       engine-down banner, journals engine_down, and fires exactly one notification — the safe HOLD.
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

# Source the REAL watcher in lib mode: helpers + the factored halves, no loop, no re-exec.
source_lib() {
  export AGENT_WATCH_LIB=1
  export HERD_CONFIG_FILE="$T/no-such-config"
  export WORKTREES_DIR="$T/trees"
  export JOURNAL_FILE="$T/journal.jsonl"
  mkdir -p "$T/trees" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "FAIL: lib-mode source failed" >&2; exit 1; }
}

# ── (1) the watchdog + render half are defined; the deleted action pass is GONE ──────────────────
(
  source_lib
  declare -F _tick_render_reconcile >/dev/null || exit 1
  declare -F _engine_tick_watchdog  >/dev/null || exit 1
  declare -F _tick_act >/dev/null && { echo "still-defined" >&2; exit 2; }
  exit 0
) || fail "post-cutover the watchdog + render half must be defined and _tick_act must be DELETED"
pass

# ── (2) structure: the render half drives the action through the watchdog, which gates on the live tick
(
  source_lib
  rbody="$(declare -f _tick_render_reconcile)"
  case "$rbody" in *_engine_tick_watchdog*) : ;; *) echo "no-watchdog" >&2; exit 1 ;; esac
  case "$rbody" in *_tick_act*) echo "still-calls-action-pass" >&2; exit 1 ;; *) : ;; esac
  wbody="$(declare -f _engine_tick_watchdog)"
  case "$wbody" in *herd_engine_live_tick*) : ;; *) echo "no-live-tick" >&2; exit 1 ;; esac
) || fail "_tick_render_reconcile must drive the action pass via _engine_tick_watchdog, which gates on herd_engine_live_tick"
pass

# ── shared harness: drive _engine_tick_watchdog with the leaves stubbed as recorders ─────────────
# $1 = a shell snippet defining herd_engine_live_tick (the tick outcome under test); prints the trace.
run_watchdog() {
  local live_def="$1" ticks="${2:-1}" trace="$T/wd.trace"
  (
    source_lib
    : > "$trace"
    _rec(){ printf '%s\n' "$1" >> "$trace"; }
    # the engine-down side effects we assert on
    journal_append(){ _rec "journal:$1"; }
    herd_driver_notify(){ _rec "notify:$1"; }
    render(){ _rec render; }
    # any bash action-pass leaf MUST NOT be reachable — record it loudly if it ever runs
    do_merge(){ _rec ACTION:do_merge; }
    spawn_resolver(){ _rec ACTION:spawn_resolver; }
    post_gate_status(){ _rec ACTION:post_gate_status; }
    _review_gate_step(){ _rec ACTION:review; }
    _healthcheck_gate(){ _rec ACTION:health; }
    # the tick outcome under test
    eval "$live_def"
    # watchdog state (initialised after the lib-return in real runs) — tuned tiny, DRYRUN skips sleeps
    DRYRUN=1
    ENGINE_DOWN_ROW=""
    C_RED=""; C_BOLD=""; C_RESET=""; C_DIM=""
    _ENGINE_FAULT_STREAK=0; _ENGINE_FAULT_MAX=3; _ENGINE_TICK_RETRIES=2; _ENGINE_BACKOFF_BASE=1
    _ENGINE_DOWN_DECLARED=""
    local i
    for (( i=0; i<ticks; i++ )); do _engine_tick_watchdog || true; done
    [ -n "$ENGINE_DOWN_ROW" ] && _rec "BANNER_SET"
  )
  cat "$trace"
}

# ── (3) clean tick: succeeds, NO engine-down, NO bash action ─────────────────────────────────────
CLEAN="$(run_watchdog 'herd_engine_live_tick(){ return 0; }' 1)"
printf '%s\n' "$CLEAN" | grep -q '^journal:engine_down$'  && fail "clean tick must not journal engine_down"
printf '%s\n' "$CLEAN" | grep -q '^BANNER_SET$'           && fail "clean tick must not set the engine-down banner"
printf '%s\n' "$CLEAN" | grep -q '^ACTION:'               && fail "clean tick must run NO bash action pass (Python owns it)"
pass

# ── (4) faulted tick: no bash action, and past the fault streak → loud banner + journal + one notify ─
FAULT="$(run_watchdog 'herd_engine_live_tick(){ return 1; }' 3)"
printf '%s\n' "$FAULT" | grep -q '^ACTION:' && fail "a faulted tick must run NO bash gate/merge/resolver (no action pass exists)"
printf '%s\n' "$FAULT" | grep -q '^BANNER_SET$' || fail "past _ENGINE_FAULT_MAX faulty ticks the engine-down banner must be set"
printf '%s\n' "$FAULT" | grep -q '^journal:engine_down$' || fail "engine down must be journaled"
[ "$(printf '%s\n' "$FAULT" | grep -c '^journal:engine_down$')" = 1 ] || fail "engine_down must be journaled exactly once per episode"
[ "$(printf '%s\n' "$FAULT" | grep -c '^notify:')" = 1 ] || fail "engine down must fire exactly one notification per episode"
pass

echo "ok — post-cutover tick (HERD-306): $PASS checks passed"
