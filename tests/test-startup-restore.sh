#!/usr/bin/env bash
# test-startup-restore.sh — hermetic tests for the HERD-112 coordinator startup-restore health
# probe: _herd_control_room_down_reason (in herd-preflight.sh) + its wiring in coordinator.sh.
#
# The probe is the DETERMINISTIC, no-LLM signal behind the "control room looks down — run herd
# reload" hint printed on control-room launch. It mirrors `herd status`'s watcher-liveness check
# ($HERD_WATCHER_LOCK pid + kill -0) and flags a missing backlog/watch pane in the role registry.
# It must FAIL-SOFT + DEFAULT-SAFE: a healthy room yields EMPTY output (so the launch summary stays
# byte-identical), and every degraded/absent-signal case never crashes or false-reds.
#
# Verifies:
#   (1) the helper exists after sourcing herd-preflight.sh (side-effect-free lib load)
#   (2) HEALTHY (alive watcher lock + backlog & watch rows) → EMPTY reason (byte-identical launch)
#   (3) no lock file at all → "watcher not alive (no watcher lock/pid)"
#   (4) empty lock file → "watcher not alive (no watcher lock/pid)"
#   (5) STALE lock (pid not alive) → "watcher not alive (stale lock pid …)"
#   (6) alive watcher but MISSING backlog row → "backlog pane missing …"
#   (7) alive watcher but MISSING watch row → "watch pane missing …"
#   (8) alive watcher + NO registry file → EMPTY (registry absence is not a down signal)
#   (9) the probe ALWAYS returns 0 (safe to call inline under `set -e`)
#  (10) coordinator.sh wires the probe: guarded by HERD_NO_WATCH, prints the exact hint string
#
# No `set -e`: several cases deliberately expect a non-empty (down) reason; we assert explicitly.
# Run:  bash tests/test-startup-restore.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFLIGHT="$HERE/../scripts/herd/herd-preflight.sh"
COORD="$HERE/../scripts/herd/coordinator.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$PREFLIGHT" ] || fail "herd-preflight.sh not found at $PREFLIGHT"
[ -f "$COORD" ]     || fail "coordinator.sh not found at $COORD"

# Sourcing herd-preflight.sh is side-effect-free (defines functions only).
# shellcheck source=/dev/null
. "$PREFLIGHT" || fail "sourcing herd-preflight.sh failed"

# (1) helper defined
type _herd_control_room_down_reason >/dev/null 2>&1 \
  || fail "_herd_control_room_down_reason not defined after sourcing herd-preflight.sh"
ok

# A live pid we control: a backgrounded sleep. kill -0 on it succeeds until we reap it.
sleep 30 & LIVE_PID=$!
# A definitely-dead pid: spawn then reap a trivial process, reuse its (now-free) pid.
sleep 0 & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null || true

LOCK="$T/.watcher.pid"
REG="$T/.herd-panes"
export HERD_WATCHER_LOCK="$LOCK"

# healthy registry: both roles present (matches layout_write_registry's row shape).
write_healthy_reg(){ printf 'coordinator-agent pane-a tab-1 ws-1\nbacklog pane-b tab-1 ws-1\nwatch pane-c tab-1 ws-1\n' > "$REG"; }

# assert_reason <label> <expected-substr-or-EMPTY> — run the probe, check reason + always-0 return.
assert_reason(){
  local label="$1" want="$2" got rc
  got="$(_herd_control_room_down_reason "$REG")"; rc=$?
  [ "$rc" -eq 0 ] || fail "$label: probe returned $rc (must always be 0)"
  if [ "$want" = "EMPTY" ]; then
    [ -z "$got" ] || fail "$label: expected EMPTY reason, got '$got'"
  else
    case "$got" in *"$want"*) : ;; *) fail "$label: expected reason containing '$want', got '$got'" ;; esac
  fi
  ok
}

# (2) HEALTHY → empty
printf '%s\n' "$LIVE_PID" > "$LOCK"; write_healthy_reg
assert_reason "healthy" EMPTY

# (3) no lock file
rm -f "$LOCK"; write_healthy_reg
assert_reason "no-lock" "no watcher lock/pid"

# (4) empty lock file
: > "$LOCK"; write_healthy_reg
assert_reason "empty-lock" "no watcher lock/pid"

# (5) stale lock (dead pid)
printf '%s\n' "$DEAD_PID" > "$LOCK"; write_healthy_reg
assert_reason "stale-lock" "stale lock pid"

# (6) alive watcher, missing backlog row
printf '%s\n' "$LIVE_PID" > "$LOCK"
printf 'coordinator-agent pane-a tab-1 ws-1\nwatch pane-c tab-1 ws-1\n' > "$REG"
assert_reason "missing-backlog" "backlog pane missing"

# (7) alive watcher, missing watch row
printf 'coordinator-agent pane-a tab-1 ws-1\nbacklog pane-b tab-1 ws-1\n' > "$REG"
assert_reason "missing-watch" "watch pane missing"

# (8) alive watcher, NO registry file → not a down signal (fail-soft)
printf '%s\n' "$LIVE_PID" > "$LOCK"; rm -f "$REG"
got="$(_herd_control_room_down_reason "$REG")" || fail "no-registry: probe returned nonzero"
[ -z "$got" ] || fail "no-registry: expected EMPTY (registry absence is not a down signal), got '$got'"
ok

# (9) always-0 return under a hostile input (garbage pid) — no crash, no false abort.
printf 'not-a-pid\n' > "$LOCK"; write_healthy_reg
_herd_control_room_down_reason "$REG" >/dev/null; [ $? -eq 0 ] || fail "garbage-pid: probe returned nonzero"
ok

kill "$LIVE_PID" 2>/dev/null || true; wait "$LIVE_PID" 2>/dev/null || true

# (10) coordinator.sh wiring: the probe is called, guarded by HERD_NO_WATCH, with the exact hint.
grep -q '_herd_control_room_down_reason' "$COORD" \
  || fail "coordinator.sh does not call _herd_control_room_down_reason"
grep -q 'HERD_NO_WATCH' "$COORD" \
  || fail "coordinator.sh startup probe is not guarded by HERD_NO_WATCH"
grep -q 'control room looks down — run herd reload' "$COORD" \
  || fail "coordinator.sh does not print the exact startup-restore hint"
ok

echo "PASS ($pass checks) — test-startup-restore.sh"
