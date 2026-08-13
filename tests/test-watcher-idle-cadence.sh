#!/usr/bin/env bash
# test-watcher-idle-cadence.sh — hermetic unit tests for HERD-671 leg 2: WATCHER_IDLE_CADENCE, the
# lever that widens the watcher's REMOTE gh polling (the render leg's `gh pr list` + the Python engine
# core's own pooled `gh api graphql` discovery) while the watcher is genuinely idle — zero open PRs AND
# zero local in-flight builder worktrees — reconciled fresh every tick so any local activity snaps
# cadence back to full speed immediately.
#
# Proves the lever BOTH ways, per AGENTS.md:
#   • OFF (default/unset) is byte-inert: _watcher_remote_tick_due is ALWAYS due, the countdown never
#     advances, no matter how idle the local/remote signals look.
#   • ON widens the remote cadence to WATCHER_IDLE_REMOTE_SECS worth of ticks ONLY while BOTH signals
#     read idle, and RECONCILES every call: a local worktree, or a nonzero/unknown last-known open-PR
#     count, forces due immediately and resets the countdown — the snap-back-on-activity contract.
#
# Fully hermetic: a real local git repo (worktrees are a real git feature, not worth faking), no gh/
# network/model. Run:  bash tests/test-watcher-idle-cadence.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required to run this test"

export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"
export NO_COLOR=1
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _watcher_idle_cadence_enabled _watcher_idle_remote_interval \
          _watcher_local_worktrees_present _watcher_prs_open_count _watcher_remote_tick_due; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing agent-watch.sh"
done

TREES="$WORKTREES_DIR"

# A real committed repo so `git worktree add`/`list` behave exactly as production sees them.
MAIN="$T/main"; mkdir -p "$MAIN"
git -C "$MAIN" init -q
git -C "$MAIN" config user.email t@example.com
git -C "$MAIN" config user.name Test
printf 'x\n' > "$MAIN/f"
git -C "$MAIN" add f
git -C "$MAIN" commit -q -m init

reset_idle_state() { _WATCHER_IDLE_REMOTE_TICK=0; _WATCHER_LAST_PRS_OPEN=""; }

# ── 1. _watcher_idle_cadence_enabled: default off; recognized truthy tokens on; garbage off ────────
unset WATCHER_IDLE_CADENCE
_watcher_idle_cadence_enabled && fail "idle cadence must default OFF"; pass
for v in on ON true TRUE 1 yes YES; do
  WATCHER_IDLE_CADENCE="$v"
  _watcher_idle_cadence_enabled || fail "idle cadence should be ON for WATCHER_IDLE_CADENCE=$v"
done; pass
for v in off OFF "" 0 no garbage; do
  WATCHER_IDLE_CADENCE="$v"
  _watcher_idle_cadence_enabled && fail "idle cadence should be OFF for WATCHER_IDLE_CADENCE=$v"
done; pass
unset WATCHER_IDLE_CADENCE

# ── 2. _watcher_idle_remote_interval: seconds -> tick count at the ~4s loop cadence ─────────────────
unset WATCHER_IDLE_REMOTE_SECS
[ "$(_watcher_idle_remote_interval)" = 15 ] || fail "default interval should be 15 ticks (60s/4s)"; pass
WATCHER_IDLE_REMOTE_SECS=120
[ "$(_watcher_idle_remote_interval)" = 30 ] || fail "120s should be 30 ticks"; pass
WATCHER_IDLE_REMOTE_SECS=2   # sub-4s floors to 1 tick, never 0 (never a busy-spin)
[ "$(_watcher_idle_remote_interval)" = 1 ] || fail "sub-4s should floor to 1 tick, got $(_watcher_idle_remote_interval)"; pass
WATCHER_IDLE_REMOTE_SECS="garbage"
[ "$(_watcher_idle_remote_interval)" = 15 ] || fail "non-numeric should fall back to 15 ticks"; pass
unset WATCHER_IDLE_REMOTE_SECS

# ── 3. _watcher_local_worktrees_present: LOCAL-only, real git worktree list ─────────────────────────
_watcher_local_worktrees_present && fail "no builder worktree exists yet — must read absent"; pass
git -C "$MAIN" worktree add -q -b feat/x "$TREES/feat-x" >/dev/null 2>&1 \
  || fail "could not create a builder worktree"
_watcher_local_worktrees_present || fail "a builder worktree exists under \$TREES — must read present"; pass
git -C "$MAIN" worktree remove --force "$TREES/feat-x" >/dev/null 2>&1
_watcher_local_worktrees_present && fail "worktree was removed — must read absent again"; pass

# ── 4. _watcher_prs_open_count: array length, or -1 on anything unparseable ─────────────────────────
[ "$(_watcher_prs_open_count '[]')" = 0 ] || fail "empty array should count 0"; pass
[ "$(_watcher_prs_open_count '[{"number":1},{"number":2}]')" = 2 ] || fail "two-element array should count 2"; pass
# (PRS_JSON is never actually empty in production — _prs_fetch_tick always defaults it to '[]' before
# any caller sees it — so an empty/blank read here safely counts as -1 (unparseable), same as garbage.)
[ "$(_watcher_prs_open_count '')" = -1 ] || fail "empty string should count -1 (unparseable), never a false 0"; pass
[ "$(_watcher_prs_open_count 'not json')" = -1 ] || fail "malformed JSON should count -1, never a false 0"; pass
[ "$(_watcher_prs_open_count '{"not":"an array"}')" = -1 ] || fail "a non-array JSON value should count -1"; pass

# ── 5. _watcher_remote_tick_due: OFF is byte-inert — always due, countdown never advances ───────────
unset WATCHER_IDLE_CADENCE
reset_idle_state
for i in 1 2 3 4 5; do
  _watcher_remote_tick_due || fail "OFF: tick $i must be due (lever off = always poll)"
done
[ "$_WATCHER_IDLE_REMOTE_TICK" = 0 ] || fail "OFF: countdown must never advance while the lever is off"
pass

# ── 6. ON + genuinely idle (no worktrees, last known open-PR count is 0): widened cadence ───────────
WATCHER_IDLE_CADENCE=on
WATCHER_IDLE_REMOTE_SECS=12   # -> 3-tick interval, keeps the test fast
reset_idle_state
_WATCHER_LAST_PRS_OPEN=0
due_count=0
for i in 1 2 3 4 5 6 7 8 9; do
  if _watcher_remote_tick_due; then due_count=$((due_count+1)); fi
done
# interval=3: due on ticks 3,6,9 -> 3 of 9 (the countdown reset to 0 on each due tick, not carried over)
[ "$due_count" = 3 ] || fail "ON+idle: expected 3 due ticks out of 9 at interval 3, got $due_count"
pass

# ── 7. ON + a local worktree present: ALWAYS due, and resets the countdown ──────────────────────────
WATCHER_IDLE_CADENCE=on
WATCHER_IDLE_REMOTE_SECS=120  # a long interval — proves it is bypassed by local activity, not just short
reset_idle_state
_WATCHER_LAST_PRS_OPEN=0
_WATCHER_IDLE_REMOTE_TICK=25  # pretend we were already deep into an idle countdown
git -C "$MAIN" worktree add -q -b feat/y "$TREES/feat-y" >/dev/null 2>&1 \
  || fail "could not create a second builder worktree"
_watcher_remote_tick_due || fail "ON: a local worktree must force this tick due immediately"
[ "$_WATCHER_IDLE_REMOTE_TICK" = 0 ] || fail "ON: local activity must reset the countdown to 0"
_watcher_remote_tick_due || fail "ON: due again next tick while the worktree persists"
git -C "$MAIN" worktree remove --force "$TREES/feat-y" >/dev/null 2>&1

# ── 8. ON + last known open-PR count nonzero (or unknown): ALWAYS due ───────────────────────────────
WATCHER_IDLE_CADENCE=on
reset_idle_state
_WATCHER_LAST_PRS_OPEN=3
_watcher_remote_tick_due || fail "ON: a nonzero last-known open-PR count must force due"
[ "$_WATCHER_IDLE_REMOTE_TICK" = 0 ] || fail "ON: nonzero PR count must reset the countdown"
reset_idle_state   # "" = not yet observed
_watcher_remote_tick_due || fail "ON: an UNKNOWN last-known PR count (first tick) must force due"
pass

# ── 9. Snap-back: idle countdown builds up, then local activity interrupts it mid-window ────────────
WATCHER_IDLE_CADENCE=on
WATCHER_IDLE_REMOTE_SECS=40   # 10-tick interval
reset_idle_state
_WATCHER_LAST_PRS_OPEN=0
for i in 1 2 3 4; do _watcher_remote_tick_due && fail "tick $i should still be idle-skipped"; done
[ "$_WATCHER_IDLE_REMOTE_TICK" = 4 ] || fail "countdown should read 4 after 4 idle ticks, got $_WATCHER_IDLE_REMOTE_TICK"
git -C "$MAIN" worktree add -q -b feat/z "$TREES/feat-z" >/dev/null 2>&1 \
  || fail "could not create a third builder worktree"
_watcher_remote_tick_due || fail "snap-back: activity mid-countdown must force due THIS tick"
[ "$_WATCHER_IDLE_REMOTE_TICK" = 0 ] || fail "snap-back: countdown must reset to 0, not merely pause"
git -C "$MAIN" worktree remove --force "$TREES/feat-z" >/dev/null 2>&1
for i in 1 2 3; do _watcher_remote_tick_due && fail "post-snap-back tick $i should be idle-skipped again"; done
[ "$_WATCHER_IDLE_REMOTE_TICK" = 3 ] || fail "countdown should resume cleanly from 0, got $_WATCHER_IDLE_REMOTE_TICK"
pass

echo "OK ($PASS assertions) — $0"
