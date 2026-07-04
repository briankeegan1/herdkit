#!/usr/bin/env bash
# test-coordinator-watchdog.sh — hermetic tests for the OPT-IN coordinator auto-resume watchdog
# (COORDINATOR_WATCHDOG, default off) folded into agent-watch.sh. Verifies:
#   (1) new helpers exist after sourcing (lib mode)
#   (2) DEFAULT OFF is byte-inert — with the flag off/unset the whole path never runs, even when the
#       coordinator is limit-parked (sentinel present + agent not 'working'): no ledger, no resume
#   (3) ON + a 'working' coordinator is NEVER touched (and a stale record is cleared)
#   (4) ON + non-working coordinator with NO limit signal → no action (not a fault, just idle)
#   (5) ON + limit-parked, future reset → records 'scheduled', journals detected/scheduled, no resume yet
#   (6) ON + past reset → EXACTLY ONE `claude --continue` relaunch in the coordinator pane ($MAIN),
#       record + sentinel cleared on success, journals woke:1
#   (7) launch lock prevents double-launch: a held lock makes the resume tick a no-op (no pane run)
#   (8) bounded-retry-then-escalate: a resume that never wakes → state 'failed', and the NEXT tick
#       does not re-attempt
#   (9) coordinator.sh installs the rate_limit hook on the coordinator repo (herd_write_ratelimit_hook)
#
# Sources agent-watch.sh in lib mode. Stubs herdr/gh/git, pins the clock (HERD_NOW_EPOCH), overrides
# MAIN to a temp "coordinator repo". NETWORK-FREE; launches no real claude; touches no live panes.
# Run:  bash tests/test-coordinator-watchdog.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
COORD="$HERE/../scripts/herd/coordinator.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
[ -f "$COORD" ] || fail "coordinator.sh not found at $COORD"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
# herdr stub: agent list returns a configurable agent; pane run logs the FULL command text so the
# resume shape is assertable; everything else is a harmless no-op (incl. notification show).
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
      "${STUB_AGENT_NAME:-}" "${STUB_AGENT_STATUS:-idle}" "${STUB_AGENT_PANE_ID:-pane-000}"
    ;;
  "pane run")
    [ -n "${STUB_PANE_RUN_LOG:-}" ] && printf '%s\n' "$4" >> "$STUB_PANE_RUN_LOG"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# (1) New helpers defined.
for fn in _handle_coordinator_watchdog _coordinator_pane_id \
          _coordinator_launch_lock_acquire _coordinator_launch_lock_release; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
[ -n "${HERD_AGENT_COORDINATOR:-}" ] || fail "HERD_AGENT_COORDINATOR must be set by herd-config.sh"
ok

render() { :; }   # no-op: tests don't need terminal output

# Override _wait_agent_working to avoid real sleeps; STUB_WAIT_FILE lines = return codes in order.
STUB_WAIT_FILE="$T/wait-codes.txt"
_wait_agent_working() {
  local _c; _c="$(head -1 "$STUB_WAIT_FILE" 2>/dev/null || true)"
  { tail -n +2 "$STUB_WAIT_FILE" 2>/dev/null || true; } > "${STUB_WAIT_FILE}.tmp"
  mv "${STUB_WAIT_FILE}.tmp" "$STUB_WAIT_FILE" 2>/dev/null || true
  return "${_c:-0}"
}

PANE_LOG="$T/pane-run.log"
export STUB_PANE_RUN_LOG="$PANE_LOG"

# The watchdog checks $MAIN (the coordinator's repo) for the limit sentinel. Point it at a temp dir
# so the test never pollutes the real checkout, and drive the coordinator agent via the herdr stub.
CO="$HERD_AGENT_COORDINATOR"
MAIN="$T/coord-repo"; mkdir -p "$MAIN"
SENT="$(_limit_sentinel_file "$MAIN")"
# The launch lock path is derived from HERD_WATCHER_LOCK; make sure its parent exists.
mkdir -p "$(dirname "$COORD_LAUNCH_LOCK")" 2>/dev/null || true

reset_state() { rm -f "$LIMIT_STATE" "$SENT"; rmdir "$COORD_LAUNCH_LOCK" 2>/dev/null || true; : > "$PANE_LOG"; : > "$JOURNAL_FILE"; }

# ── (2) DEFAULT OFF is byte-inert ─────────────────────────────────────────────
reset_state
printf '4000000000' > "$SENT"                                  # limit sentinel present
export STUB_AGENT_NAME="$CO" STUB_AGENT_STATUS="done" STUB_AGENT_PANE_ID="pane-CO"
export HERD_NOW_EPOCH=1000000
unset COORDINATOR_WATCHDOG
_handle_coordinator_watchdog
[ -z "$(limit_state "$CO")" ] || fail "2: OFF (unset) must not record any coordinator limit state"
ok
[ ! -s "$PANE_LOG" ] || fail "2: OFF (unset) must never run a resume (pane run)"
ok
COORDINATOR_WATCHDOG=off _handle_coordinator_watchdog
[ -z "$(limit_state "$CO")" ] || fail "2: OFF (explicit) must not record any coordinator limit state"
ok
[ ! -s "$PANE_LOG" ] || fail "2: OFF (explicit) must never run a resume"
ok

export COORDINATOR_WATCHDOG=on   # from here on the watchdog is opted in

# ── (3) ON + 'working' coordinator is NEVER touched; a stale record is cleared ─
reset_state
printf '4000000000' > "$SENT"
record_limit "$CO" "1" "9999999999" "scheduled"               # a stale scheduled record
export STUB_AGENT_STATUS="working"
_handle_coordinator_watchdog
[ -z "$(limit_state "$CO")" ] || fail "3: a working coordinator must clear the stale limit record"
ok
[ ! -f "$SENT" ] || fail "3: clearing on a working coordinator must also drop the sentinel"
ok
[ ! -s "$PANE_LOG" ] || fail "3: a working coordinator must never be resumed"
ok

# ── (4) ON + non-working coordinator with NO limit signal → no action ─────────
reset_state
export STUB_AGENT_STATUS="done"                               # not working, but no sentinel/banner
_handle_coordinator_watchdog
[ -z "$(limit_state "$CO")" ] || fail "4: an idle coordinator with no limit signal must not be recorded"
ok
[ ! -s "$PANE_LOG" ] || fail "4: an idle coordinator with no limit signal must not be resumed"
ok

# ── (5) ON + limit-parked, future reset → scheduled, journaled, no resume yet ──
# Sentinel holds a 10-digit epoch (what a real reset banner/hook writes); _parse_reset_epoch only
# treats 9+ digit strings as an epoch, so shorter numbers would parse as a time-of-day.
reset_state
printf '2000005000' > "$SENT"                                 # numeric-epoch reset in the future
export STUB_AGENT_STATUS="done"
export HERD_NOW_EPOCH=2000000000
_handle_coordinator_watchdog
[ "$(limit_state "$CO")" = "scheduled" ] || fail "5: a confirmed park must record 'scheduled'"
ok
[ "$(limit_target_epoch "$CO")" = "2000005060" ] || fail "5: target should be reset+buffer=2000005060 (got $(limit_target_epoch "$CO"))"
ok
[ ! -s "$PANE_LOG" ] || fail "5: before the reset there must be no resume"
ok
grep -q '"event":"coordinator_limit_detected"' "$JOURNAL_FILE" || fail "5: coordinator_limit_detected must be journaled"
ok
grep -q '"event":"coordinator_resume_scheduled"' "$JOURNAL_FILE" || fail "5: coordinator_resume_scheduled must be journaled"
ok

# ── (6) ON + past reset → exactly ONE claude --continue relaunch, then cleared ─
reset_state
printf '4000000000' > "$SENT"
record_limit "$CO" "1000000" "1005060" "scheduled"           # scheduled target already in the past
export STUB_AGENT_STATUS="done" STUB_AGENT_PANE_ID="pane-CO"
export HERD_NOW_EPOCH=1006000
printf '0\n' > "$STUB_WAIT_FILE"                             # wakes on first poll
_handle_coordinator_watchdog
[ "$(wc -l < "$PANE_LOG")" -eq 1 ] || fail "6: resume must fire EXACTLY ONE pane run (got $(wc -l < "$PANE_LOG"))"
ok
cmd="$(head -1 "$PANE_LOG")"
printf '%s\n' "$cmd" | grep -q -- "--continue" || fail "6: resume must use claude --continue (got: $cmd)"
ok
printf '%s\n' "$cmd" | grep -q "$MAIN" || fail "6: resume must cd into the coordinator repo \$MAIN (got: $cmd)"
ok
[ -z "$(limit_state "$CO")" ] || fail "6: record must be cleared after a successful resume"
ok
[ ! -f "$SENT" ] || fail "6: sentinel must be removed after a successful resume"
ok
grep -q '"event":"coordinator_resume_result"' "$JOURNAL_FILE" || fail "6: coordinator_resume_result must be journaled"
ok
grep -q '"woke":1' "$JOURNAL_FILE" || fail "6: successful resume must journal woke:1"
ok
# The launch lock must be RELEASED after a successful resume.
[ ! -d "$COORD_LAUNCH_LOCK" ] || fail "6: launch lock must be released after resume"
ok

# ── (7) launch lock prevents double-launch ────────────────────────────────────
reset_state
printf '4000000000' > "$SENT"
record_limit "$CO" "1000000" "1005060" "scheduled"
export HERD_NOW_EPOCH=1006000
printf '0\n' > "$STUB_WAIT_FILE"
mkdir -p "$COORD_LAUNCH_LOCK"                                 # a relaunch is "already in flight"
_handle_coordinator_watchdog
[ ! -s "$PANE_LOG" ] || fail "7: a held launch lock must suppress the resume (no pane run)"
ok
[ "$(limit_state "$CO")" = "scheduled" ] || fail "7: with the lock held the record must remain 'scheduled' (retry next tick)"
ok
rmdir "$COORD_LAUNCH_LOCK" 2>/dev/null || true

# ── (8) bounded-retry-then-escalate ───────────────────────────────────────────
reset_state
printf '4000000000' > "$SENT"
record_limit "$CO" "1000000" "1005060" "scheduled"
export HERD_NOW_EPOCH=1006000
printf '1\n1\n' > "$STUB_WAIT_FILE"                          # never wakes (both submit windows fail)
_handle_coordinator_watchdog
[ "$(limit_state "$CO")" = "failed" ] || fail "8: a resume that never wakes must record 'failed'"
ok
grep -q '"woke":0' "$JOURNAL_FILE" || fail "8: a failed resume must journal woke:0"
ok
calls_before="$(wc -l < "$PANE_LOG")"
printf '0\n' > "$STUB_WAIT_FILE"
_handle_coordinator_watchdog                                 # next tick: state=failed → no re-attempt
[ "$(wc -l < "$PANE_LOG")" -eq "$calls_before" ] || fail "8: a 'failed' record must NOT re-attempt resume every tick"
ok

# ── (9) coordinator.sh installs the rate_limit hook on the coordinator repo ────
grep -q 'herd_write_ratelimit_hook "\$REPO"' "$COORD" \
  || fail "9: coordinator.sh must install the rate_limit hook via herd_write_ratelimit_hook \"\$REPO\""
ok

echo "ALL PASS ($pass checks)"
