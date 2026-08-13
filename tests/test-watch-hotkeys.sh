#!/usr/bin/env bash
# test-watch-hotkeys.sh — hermetic tests for the in-console 'v' hotkey (HERD-674).
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) with a stubbed PATH (git/herdr/gh no-ops,
# a `stty` SPY that records every invocation instead of touching a real terminal), then exercises the
# pure/testable seam directly:
#   • _watch_hotkeys_enabled   — WATCH_HOTKEYS on/off recognition (default off)
#   • _watch_hotkeys_active    — enabled AND tty-ok; HERD_WATCH_HOTKEYS_FORCE_TTY is the test-only hook
#                                 that stands in for a real pty (mirrors backlog-view.sh's own
#                                 BACKLOG_VIEW_TTY/KEY_CMD hooks, same reason: never touch a real tty)
#   • _watch_hotkeys_poll_tick — the marker-file-driven mine<->all flip, and its NON-BLOCKING timing
#   • build_hotkey_hint        — the rendered hint row, empty unless active
#   • _watch_hotkeys_listener_spawn/_stop — off never calls stty; on does, and stop kills the PID
# No real terminal is ever touched: stdin is explicitly /dev/null for the whole run, and `stty` is a
# recording stub, so this suite is safe to run inside a live watcher pane exactly like every other
# hermetic test here.
# Run:  bash tests/test-watch-hotkeys.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

# Never touch whatever real tty this suite happens to be invoked from.
exec </dev/null

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Stub PATH ─────────────────────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in git herdr gh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
# stty SPY: records every invocation's argv to $STTY_LOG (one line per call) instead of touching a
# real terminal. `-g` (save) prints a fake opaque state token so callers that gate on its success
# proceed past the guard; every other invocation (raw-mode set, restore) just succeeds.
STTY_LOG="$T/stty.log"; : > "$STTY_LOG"
cat > "$BIN/stty" << STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STTY_LOG"
case "\$1" in
  -g) printf 'fake-saved-tty-state\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/stty"
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"   # falls back to generic defaults
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _watch_hotkeys_enabled _watch_hotkeys_tty_ok _watch_hotkeys_active \
          _watch_hotkeys_marker_file _watch_hotkeys_listener_loop _watch_hotkeys_listener_spawn \
          _watch_hotkeys_listener_stop _watch_hotkeys_poll_tick build_hotkey_hint; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

stty_calls() { wc -l < "$STTY_LOG" | tr -d ' '; }

# ── 1. _watch_hotkeys_enabled — default off, recognizes on-ish values ──────────────────────────────
unset WATCH_HOTKEYS
_watch_hotkeys_enabled && fail "unset WATCH_HOTKEYS must read as OFF"
ok
WATCH_HOTKEYS=off  _watch_hotkeys_enabled && fail "WATCH_HOTKEYS=off must be OFF"
ok
for v in on ON On 1 true yes; do
  WATCH_HOTKEYS="$v" _watch_hotkeys_enabled || fail "WATCH_HOTKEYS=$v must be ON"
done
ok
WATCH_HOTKEYS=garbage _watch_hotkeys_enabled && fail "an unrecognized value must fail toward OFF"
ok

# ── 2. _watch_hotkeys_active — real tty check (stdin is /dev/null here, never a tty) ───────────────
unset HERD_WATCH_HOTKEYS_FORCE_TTY
WATCH_HOTKEYS=on _watch_hotkeys_active && fail "on with a non-tty stdin must still be INACTIVE"
ok
# The test-only hook stands in for a real pty.
WATCH_HOTKEYS=on  HERD_WATCH_HOTKEYS_FORCE_TTY=1 _watch_hotkeys_active \
  || fail "on + forced-tty must be ACTIVE"
ok
WATCH_HOTKEYS=off HERD_WATCH_HOTKEYS_FORCE_TTY=1 _watch_hotkeys_active \
  && fail "off must stay INACTIVE even with a forced tty"
ok

# ── 3. build_hotkey_hint — empty unless active; names the current lens when active ─────────────────
unset WATCHER_VIEW HERD_WATCH_HOTKEYS_FORCE_TTY
WATCH_HOTKEYS=on build_hotkey_hint
[ -z "$HOTKEY_HINT_ROW" ] || fail "hint row must be empty when inactive (non-tty)"
ok
WATCH_HOTKEYS=on HERD_WATCH_HOTKEYS_FORCE_TTY=1 build_hotkey_hint
case "$HOTKEY_HINT_ROW" in
  *"v: view"*"all"*) ok ;;
  *) fail "active hint row must name the hotkey and the current (default) lens 'all' (got: $HOTKEY_HINT_ROW)" ;;
esac

# ── 4. _watch_hotkeys_poll_tick — inactive is a no-op even if a marker file is present ──────────────
marker="$(_watch_hotkeys_marker_file)"
mkdir -p "$(dirname "$marker")"
printf '1\n' > "$marker"
unset WATCHER_VIEW _WATCH_HOTKEYS_SEEN HERD_WATCH_HOTKEYS_FORCE_TTY
WATCH_HOTKEYS=on _watch_hotkeys_poll_tick
[ -z "${WATCHER_VIEW:-}" ] || fail "poll_tick must be a no-op while inactive (got WATCHER_VIEW=$WATCHER_VIEW)"
ok

# ── 5. _watch_hotkeys_poll_tick — active: a changed marker flips mine<->all, in memory only ─────────
export HERD_WATCH_HOTKEYS_FORCE_TTY=1
export WATCH_HOTKEYS=on
unset WATCHER_VIEW; _WATCH_HOTKEYS_SEEN=""
printf '1\n' > "$marker"
_watch_hotkeys_poll_tick
[ "${WATCHER_VIEW:-}" = "mine" ] || fail "first flip from unset(=all) must land on 'mine' (got: ${WATCHER_VIEW:-<unset>})"
ok
# Re-polling with the SAME marker content must NOT flip again.
_watch_hotkeys_poll_tick
[ "${WATCHER_VIEW:-}" = "mine" ] || fail "an unchanged marker must never re-flip (got: ${WATCHER_VIEW:-<unset>})"
ok
# A fresh keystroke (marker content changes) flips back.
printf '2\n' > "$marker"
_watch_hotkeys_poll_tick
[ "${WATCHER_VIEW:-}" = "all" ] || fail "second flip from mine must land on 'all' (got: ${WATCHER_VIEW:-<unset>})"
ok
# The flip is pure in-memory: no config file was ever touched.
[ -f "$HERD_CONFIG_FILE" ] && fail "poll_tick must never write .herd/config"
ok
[ -f "$(dirname "$HERD_CONFIG_FILE")/config.local" ] && fail "poll_tick must never write config.local"
ok
unset HERD_WATCH_HOTKEYS_FORCE_TTY WATCH_HOTKEYS

# ── 6. NON-BLOCKING proof: many poll_tick calls (active and inactive) cost a few ms each ────────────
# 60 calls (30 active, 30 inactive) is enough to distinguish "a plain file read" from "a tty read
# blocking indefinitely for a keystroke that never comes" without making the bound so tight it flakes
# on a loaded/sandboxed CI box (each call forks a handful of subshells; per-call cost here is a real
# few-ms bash-fork cost, not the tty-block failure mode this proves absent).
t0="$(python3 -c 'import time; print(time.time())')"
export HERD_WATCH_HOTKEYS_FORCE_TTY=1 WATCH_HOTKEYS=on
i=0; while [ "$i" -lt 30 ]; do _watch_hotkeys_poll_tick; i=$((i + 1)); done
unset HERD_WATCH_HOTKEYS_FORCE_TTY WATCH_HOTKEYS
i=0; while [ "$i" -lt 30 ]; do _watch_hotkeys_poll_tick; i=$((i + 1)); done
t1="$(python3 -c 'import time; print(time.time())')"
dt="$(python3 -c "print($t1 - $t0)")"
# A single blocking tty read alone would run this well past 10s (there is no key to receive, ever);
# 60 non-blocking file-backed calls finish in well under 1s per call on any real machine.
python3 -c "import sys; sys.exit(0 if $dt < 10.0 else 1)" \
  || fail "60 poll_tick calls took ${dt}s — a non-blocking poll must never approach a tick's own cadence"
ok

# ── 7. off is byte-inert: no stty call, no listener PID, spawn is a pure no-op ──────────────────────
: > "$STTY_LOG"
rm -f "$marker"
_WATCH_HOTKEYS_LISTENER_PID=""
WATCH_HOTKEYS=off HERD_WATCH_HOTKEYS_FORCE_TTY=1 _watch_hotkeys_listener_spawn
[ "$(stty_calls)" -eq 0 ] || fail "WATCH_HOTKEYS=off must never call stty (got $(stty_calls) call(s): $(cat "$STTY_LOG"))"
ok
[ -z "$_WATCH_HOTKEYS_LISTENER_PID" ] || fail "WATCH_HOTKEYS=off must never spawn a listener"
ok
[ -f "$marker" ] && fail "WATCH_HOTKEYS=off must never touch the marker file"
ok

# ── 8. on + tty: spawn arms stty at least once; stop terminates the process ──────────────────────────
: > "$STTY_LOG"
WATCH_HOTKEYS=on HERD_WATCH_HOTKEYS_FORCE_TTY=1 _watch_hotkeys_listener_spawn
sleep 0.2   # let the backgrounded listener actually run its first `stty -g` before checking the spy log
[ "$(stty_calls)" -ge 1 ] || fail "WATCH_HOTKEYS=on + tty must call stty at least once"
ok
[ -n "$_WATCH_HOTKEYS_LISTENER_PID" ] || fail "WATCH_HOTKEYS=on + tty must record a listener PID"
ok
# stdin is /dev/null here, so the real listener hits EOF at once and exits on its own; give it a
# moment, then prove _watch_hotkeys_listener_stop's mechanics independently with a long-lived stand-in
# so a slow CI box can never make this a flaky pass either way.
sleep 0.2
_watch_hotkeys_listener_stop
[ -z "$_WATCH_HOTKEYS_LISTENER_PID" ] || fail "listener_stop must clear the PID var"
ok
sleep 5 &
standin_pid=$!
_WATCH_HOTKEYS_LISTENER_PID="$standin_pid"
_watch_hotkeys_listener_stop
# `wait` on OUR OWN child (not a poll-by-PID loop): bash tracks a backgrounded job by its internal
# job-control record, not just the raw PID number, so this is immune to the PID-reuse false negative
# a `kill -0 <pid>` poll would risk under heavy forking (this suite spawns 100+ subshells earlier) —
# some OTHER, unrelated process can be handed the exact same PID moments after ours actually exits.
# `wait` blocks until THIS process exits either way; timing distinguishes "killed early" (well under
# the sleep's own 5s) from "kill silently did nothing and it ran to completion".
_whs_t0="$(python3 -c 'import time; print(time.time())')"
wait "$standin_pid" 2>/dev/null
_whs_t1="$(python3 -c 'import time; print(time.time())')"
_whs_dt="$(python3 -c "print($_whs_t1 - $_whs_t0)")"
python3 -c "import sys; sys.exit(0 if $_whs_dt < 3.0 else 1)" \
  || fail "listener_stop must terminate the tracked PID (stand-in ran its full natural duration: ${_whs_dt}s)"
ok

echo "PASS ($pass assertions) — tests/test-watch-hotkeys.sh"
