#!/usr/bin/env bash
# health-pane-view.sh <log-path> [inflight-marker] — the HEALTH_PANE (HERD-313/HERD-568) view command:
# what actually runs INSIDE the disposable health·<slug> pane, execed directly as the pane's foreground
# process (no interactive shell prompt left sitting under it, no lingering greeting/fastfetch on screen
# once this takes over — see the `clear` below).
#
# SIDECAR-AWARE (HERD-568 addendum): the two health-worker engines disagree on where the LIVE per-test
# stream lands. agent-watch.sh's bash worker (_health_worker) points HEALTHCHECK_PROGRESS_LOG at
# <log-path> ITSELF, so <log-path> grows live throughout the run. live_runtime.py's worker (HERD-533)
# points it at "<log-path>.progress" instead, a SEPARATE sidecar, and writes <log-path> itself in ONE
# SHOT at the very end (the final verdict) — tailing <log-path> alone under that engine shows nothing
# for the suite's entire runtime. This viewer follows whichever one is actually live (the sidecar when
# present, else <log-path> directly — the same preference order agent-watch.sh's own
# _health_progress_source helper uses for the console's live k/N counter), then prints the FINAL
# verdict from <log-path> the moment the suite ends and keeps following <log-path> afterward so the
# pane never goes stale/idle at a bare shell prompt.
#
# "The suite ended" is read off the OBSERVED inflight marker (the same $TREES/.health-inflight-<pr>-
# <sha> file the reconcile's retire half watches) rather than "<log-path> became non-empty" — the bash
# engine's <log-path> is non-empty almost from the first appended byte, so that signal alone would
# declare the suite done seconds after it started. No marker path (an older caller) falls back to the
# non-empty heuristic, which is still correct for the common (python-engine) case.
#
# A VIEW ONLY: no model, no gate authority — a bug here can never affect a merge decision.
#
# Run:  bash health-pane-view.sh /path/to/.health-log-<pr>-<sha> [/path/to/.health-inflight-<pr>-<sha>]
set -uo pipefail
LOG="${1:?usage: health-pane-view.sh <log-path> [inflight-marker]}"
MARK="${2:-}"
PROG="$LOG.progress"

clear 2>/dev/null || true

# NOTE: `tail … &` is started directly at top level (never inside `$(…)`) — a backgrounded process
# whose stdout is not redirected keeps the write end of a command-substitution pipe open, which would
# block that substitution on EOF until the tail exits, i.e. forever. TPID is a plain global instead.
TPID=""
_hpv_stop() { [ -n "$TPID" ] || return 0; kill "$TPID" 2>/dev/null || true; wait "$TPID" 2>/dev/null || true; TPID=""; }

SRC="$LOG"
[ -e "$PROG" ] && SRC="$PROG"
tail -n +1 -F "$SRC" 2>/dev/null & TPID=$!

if [ -n "$MARK" ]; then
  while [ -e "$MARK" ]; do
    # The sidecar can appear AFTER we already latched onto the main log (a spawn that raced the
    # worker's own truncate of .progress) — swap onto it the first tick it shows up. Happens at most
    # once per pane lifetime.
    if [ "$SRC" != "$PROG" ] && [ -e "$PROG" ]; then
      _hpv_stop
      SRC="$PROG"
      tail -n +1 -F "$SRC" 2>/dev/null & TPID=$!
    fi
    sleep 1
  done
else
  while [ ! -s "$LOG" ]; do sleep 1; done
fi
_hpv_stop

printf '\n── suite ended — final result ──\n'
[ -s "$LOG" ] || printf '(no output captured)\n'

# `tail -n +1` prints the whole file before following, so this both shows the final verdict AND keeps
# the pane open on it instead of dropping to a bare prompt. `exec` replaces this script's own process
# with tail so the pane's foreground process is the tail itself.
exec tail -n +1 -F "$LOG" 2>/dev/null
