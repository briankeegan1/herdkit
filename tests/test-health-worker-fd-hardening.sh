#!/usr/bin/env bash
# test-health-worker-fd-hardening.sh — hermetic regression tests for the HERD-339 health-worker FD leak.
#
# Grounded live incident (2026-07-11): a background health worker was dispatched with a bare
# `( "$@" ) &`, so the whole ~9-min suite subtree INHERITED the watcher's own descriptors — its
# stdout/stderr (a PIPE when the watcher runs under `herd-watch | reader`, the render seam the recent
# healthcheck-visibility merges lean on) AND its singleton-lock fd 9. Two failures followed:
#   • UNDRAINED PIPE — the worker held the pipe write-end for the suite's whole life, so a downstream
#     reader never saw EOF and the merge console froze on an "invisible" (but full-speed) healthcheck.
#   • LOCK PIN — the worker held the flock singleton lock via the shared open-file description, so a
#     HERD-266 self-restart that deliberately outlives its in-flight workers could not re-`flock -n 9`.
# The fix detaches BOTH gate-worker launch seams (_bg_health_worker and _bg_new_session) at the subshell
# boundary — stdin/stdout/stderr → /dev/null and `9>&-` — exactly as live_runtime's _HEALTH_WORKER_SH is
# launched (stdout/stderr=DEVNULL). The suite still streams to its log via the worker's OWN inner
# `bash healthcheck > "$log" 2>&1`, so visibility is unchanged; only the inherited-fd hold is gone.
#
# Covers:
#   (1) the launch seams are defined after sourcing
#   (2) UNDRAINED PIPE: a worker dispatched under a pipe-stdout parent does NOT hold the pipe — once the
#       parent releases its end the reader sees EOF within ~2 s, NOT after the suite finishes
#   (3) FULL SPEED: the suite's own log grows within seconds while that same worker runs (detaching the
#       parent fds never throttled the suite — it streams to its log exactly as before)
#   (4) LOCK PIN: a worker inherits NO open fd 9 — with the watcher's fd 9 open, the worker cannot write
#       to it (it was closed at the boundary)
#   (5) _bg_new_session (the reviewer seam) closes fd 9 for the same reason
#   (6) process-group isolation (HERD-283) is PRESERVED — the worker still leads its own group, so the
#       redirects did not disturb the killable-subtree invariant
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1); stubs gh/git/herdr on PATH so nothing touches
# the network or the live control room. No `set -e`: a couple of checks assert non-zero explicitly.
# Run:  bash tests/test-health-worker-fd-hardening.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"; _kill_leftovers' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

_LEFTOVERS=""
_track() { _LEFTOVERS="$_LEFTOVERS $1"; }
_kill_leftovers() { local p; for p in $_LEFTOVERS; do kill -KILL "$p" 2>/dev/null || true; kill -KILL "-$p" 2>/dev/null || true; done; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# ── Stub binaries on PATH (network-free) ─────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
unset HERD_WATCHER_LOCK 2>/dev/null || true
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }

TREES="$WORKTREES_DIR"

# poll_grows <file> <deadline-ticks> — 0 iff <file> becomes non-empty within deadline (ticks of 0.05s).
poll_grows() { local f="$1" n="${2:-40}" i=0; while [ "$i" -lt "$n" ]; do [ -s "$f" ] && return 0; sleep 0.05; i=$((i+1)); done; return 1; }
# poll_file <file> <deadline-ticks> — 0 iff <file> exists within deadline.
poll_file()  { local f="$1" n="${2:-40}" i=0; while [ "$i" -lt "$n" ]; do [ -e "$f" ] && return 0; sleep 0.05; i=$((i+1)); done; return 1; }

# ── (1) launch seams defined ─────────────────────────────────────────────────
for fn in _bg_health_worker _bg_new_session; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# A "fake suite" that streams to its OWN log for ~6 s (mirrors the worker's inner `> "$log"` redirect),
# long enough that a leaked pipe hold would dwarf the ~2 s EOF budget below.
fake_suite() { local log="$1" i=0; while [ "$i" -lt 60 ]; do printf 'tap %s\n' "$i" >> "$log"; sleep 0.1; i=$((i+1)); done; }

# ── (2)+(3) UNDRAINED PIPE + FULL SPEED ──────────────────────────────────────
# A FIFO models the watcher's stdout pipe. A reader blocks on it until EVERY writer closes. A short-lived
# "watcher" opens the FIFO as its stdout, dispatches the worker, records the log, then EXITS. If the
# worker inherited (and holds) the FIFO, the reader blocks for the suite's whole ~6 s; with the fd
# detached, the watcher's exit leaves no writer and the reader sees EOF at once.
FIFO="$T/watch.pipe"; mkfifo "$FIFO"
HW_LOG="$T/hw.log"; : > "$HW_LOG"
( cat "$FIFO" >/dev/null 2>&1; : > "$T/reader-eof" ) & reader=$!; _track "$reader"
(
  exec >"$FIFO" 2>/dev/null                    # this "watcher" subshell's stdout IS the pipe
  _bg_health_worker fake_suite "$HW_LOG"       # dispatch: worker must NOT keep the pipe
  printf '%s\n' "$_BG_HEALTH_PID" > "$T/wpid"
) & watcher=$!
wait "$watcher" 2>/dev/null || true            # the watcher returns immediately after dispatch
poll_file "$T/wpid" 40 || fail "(2) worker pid was never recorded"
WPID="$(cat "$T/wpid" 2>/dev/null)"; _track "$WPID"

# EOF must arrive fast — a ~2 s budget is far under the suite's ~6 s runtime, so a leaked hold fails here.
poll_file "$T/reader-eof" 40 \
  || fail "(2) reader saw no EOF within ~2s — the worker still holds the watcher's stdout pipe (undrained-pipe hang)"
# And the worker must still be running (proving the EOF came from detachment, not the suite ending).
kill -0 "$WPID" 2>/dev/null || fail "(2) the fake suite exited too early — EOF is not proof of detachment"
ok

# The suite streams to its log at full speed despite the detached parent fds.
poll_grows "$HW_LOG" 40 || fail "(3) the suite log never grew — detaching the fds throttled the worker"
ok

kill -KILL "-$WPID" 2>/dev/null || kill -KILL "$WPID" 2>/dev/null || true

# ── (4) LOCK PIN: worker inherits no open fd 9 ───────────────────────────────
# Probe fn: try to write to fd 9; report OPEN/CLOSED to a file (its own stdout is /dev/null'd at the
# boundary, so it MUST report out-of-band). Its last positional is a dummy "log" the caller convention
# passes; the probe ignores it.
_fd9_probe_health() { { echo x >&9; } 2>/dev/null && printf OPEN > "$T/fd9-health" || printf CLOSED > "$T/fd9-health"; }
(
  exec 9>"$T/lock9h"                           # the "watcher" holds fd 9 (the singleton lock stand-in)
  _bg_health_worker _fd9_probe_health "$T/fd9-health-log"
  wait
) 2>/dev/null
poll_file "$T/fd9-health" 40 || fail "(4) the fd9 probe never reported"
[ "$(cat "$T/fd9-health")" = CLOSED ] \
  || fail "(4) health worker inherited the watcher's OPEN fd 9 — it pins the singleton lock"
ok

# ── (5) _bg_new_session also closes fd 9 ─────────────────────────────────────
export FD9OUT="$T/fd9-newsess"
(
  exec 9>"$T/lock9r"
  _bg_new_session bash -c '{ echo x >&9; } 2>/dev/null && printf OPEN > "$FD9OUT" || printf CLOSED > "$FD9OUT"'
  wait
) 2>/dev/null
poll_file "$T/fd9-newsess" 40 || fail "(5) the _bg_new_session fd9 probe never reported"
[ "$(cat "$T/fd9-newsess")" = CLOSED ] \
  || fail "(5) _bg_new_session inherited the watcher's OPEN fd 9 — a reviewer pins the singleton lock"
ok

# ── (6) process-group isolation PRESERVED (HERD-283) ─────────────────────────
export CHILDF="$T/child-6.pid"; : > "$CHILDF"
fake_group_suite() { sleep 300 & printf '%s\n' "$!" > "$CHILDF"; wait; }
_bg_health_worker fake_group_suite "$T/grp.log"
W6="$_BG_HEALTH_PID"; G6="$_BG_HEALTH_PGID"; _track "$W6"
[ -n "$W6" ] && [ -n "$G6" ] || fail "(6) _bg_health_worker did not set pid/pgid"
[ "$G6" = "$W6" ] || fail "(6) worker must LEAD its own group (pgid $G6 != leader pid $W6) — redirects broke isolation"
selfpg="$(_pid_pgid "$$")"
[ "$G6" != "$selfpg" ] || fail "(6) worker group ($G6) must not be the watcher's group ($selfpg)"
poll_file "$CHILDF" 40 || true
kill -KILL "-$G6" 2>/dev/null || true
ok

echo "ALL PASS ($pass checks)"
