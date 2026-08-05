#!/usr/bin/env bash
# herd-watch.sh — launcher / pane wrapper for the live "herd watch" status console (agent-watch.sh).
#
# Runs the watcher in the foreground of the current pane. It discovers active feature worktrees,
# renders one compact line per feature, and AUTO-MERGES PRs that pass the healthcheck + review
# gate (full-auto, safety-railed — see agent-watch.sh), unless WATCHER_AUTOMERGE=false.
#
# Pane placement is intentionally OUT OF SCOPE here: the coordinator wires the actual herdr pane
# (e.g. splitting this BELOW the coordinator pane) when it launches the control room. To run it in
# a dedicated pane yourself:
#
#     herdr pane run <pane_id> "bash scripts/herd/herd-watch.sh"
#
# Dry-run (renders + gates but performs NO merge/remove/scribe/ff):
#
#     AGENT_WATCH_DRYRUN=1 bash scripts/herd/herd-watch.sh
#
# Singleton (HERD-209 / HERD-252): agent-watch.sh acquires HERD_WATCHER_LOCK at startup. If a LIVE
# watcher already holds it, this process prints the holder pid on stderr
# (`herd-watch: already running (pid <N>) — refusing duplicate`) and EXITS NON-ZERO immediately —
# never blocks/hangs. A free or stale (dead-pid) lock is adopted and the console starts normally.
#
# ── CRASH-LOOP GUARD (HERD-548, WATCHER_CRASHLOOP_GUARD=on, default off — ship-dormant) ───────────
# GROUNDED 2026-08-05: post-reload the watcher crash-looped silently for ~2 minutes (repeated fast
# child pid churn, zero journal entry, zero console beyond the header) then self-resolved with nobody
# the wiser. off (default): this wrapper does exactly what it always did — a bare `exec` into
# agent-watch.sh, byte-identical, no capture file, no marker, no journal from this file.
#
# on: this wrapper stops using `exec` (which REPLACES its own process image and can therefore never
# observe how the child died) and instead runs agent-watch.sh as a supervised child in a loop:
#   • a death that is a DELIBERATE STOP SIGNAL (SIGHUP/SIGINT/SIGTERM — rc 129/130/143) simply ends
#     the wrapper. NEVER fought: `_stop_project_watcher` (cmd_pane_watch / cmd_reload / the sweep)
#     expects the pane to go quiet and then drives its OWN verified relaunch — a wrapper that raced it
#     with an unsolicited respawn would double-launch into the exact singleton race HERD-266/450 exist
#     to prevent.
#   • a clean exit (rc 0) also just ends the wrapper — nothing to retry.
#   • any OTHER nonzero death that survived less than HERD_WATCH_CRASHLOOP_FAST_SECS (default 5s)
#     counts as FAST. Fewer than HERD_WATCH_CRASHLOOP_N (default 3) CONSECUTIVE fast deaths and the
#     wrapper retries immediately (a genuine transient — a cold clone, a momentary lock contention —
#     self-heals this way, same as any other retry-once pattern in this engine). At N consecutive fast
#     deaths the wrapper STOPS: it prints the LAST captured child stderr LOUDLY to the pane (so the
#     real fault is never scrolled out of the pane's backing scrollback by the churn itself), journals
#     `watcher_crashloop`, and trips the shared watcher-exempt.sh marker (watcher_crashloop_trip) —
#     cleared automatically once a LATER watcher PROVES it survives past the same settle window
#     (agent-watch.sh does this itself, immediately before entering its tick loop). Child stderr is
#     captured to a bounded per-attempt file (HERD_WATCH_CRASH_TAIL_LINES lines, default 80).
#
# watcher-resurrect.sh checks the SAME marker before ever calling `herd reload`, so an unattended
# external cron cadence can never fight a standing loop by relaunching the identical broken build on a
# timer. A plain operator-run `herd pane watch` is NOT gated by the marker — only the unattended probe
# treats a standing crash loop as a hard stop; a human retrying after fixing the underlying fault is
# always free to.
set -uo pipefail
# BASH_SOURCE (not $0) so HERE resolves correctly whether this file is executed or sourced (the
# HERD_WATCH_WRAPPER_LIB hermetic test seam sources it to exercise the wrapper loop directly).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$HERE/herd-config.sh"
# shellcheck source=/dev/null
[ -f "$HERE/watcher-exempt.sh" ] && . "$HERE/watcher-exempt.sh"
# shellcheck source=/dev/null
[ -f "$HERE/journal.sh" ] && . "$HERE/journal.sh"

HERD_WATCH_CRASHLOOP_N="${HERD_WATCH_CRASHLOOP_N:-3}"
HERD_WATCH_CRASHLOOP_FAST_SECS="${HERD_WATCH_CRASHLOOP_FAST_SECS:-5}"
HERD_WATCH_CRASH_TAIL_LINES="${HERD_WATCH_CRASH_TAIL_LINES:-80}"

# _watch_crash_capture / _watch_child_script — resolved FRESH on every call (never frozen at source
# time) so a hermetic test can source this file ONCE in lib mode and vary
# $HERD_WATCH_CRASH_CAPTURE / $HERD_WATCH_CHILD_SCRIPT across independent cases. Byte-identical
# outcome in production, where a process sources this file exactly once anyway.
_watch_crash_capture() { printf '%s' "${HERD_WATCH_CRASH_CAPTURE:-${WORKTREES_DIR:-.}/.watcher-crash-stderr}"; }
_watch_child_script()  { printf '%s' "${HERD_WATCH_CHILD_SCRIPT:-$HERE/agent-watch.sh}"; }

# _watch_wrapper_bound_capture <file> — truncate a stderr capture file to its last N lines, so a
# genuinely noisy crash can never grow the file unbounded.
_watch_wrapper_bound_capture() {
  local f="$1" tmp
  [ -f "$f" ] || return 0
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 0
  if tail -n "$HERD_WATCH_CRASH_TAIL_LINES" "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# _watch_wrapper_is_stop_signal_rc <rc> — true iff <rc> is bash's 128+signal encoding for a DELIBERATE
# stop: SIGHUP=129, SIGINT=130, SIGTERM=143 — the shapes `_stop_project_watcher` / an operator's Ctrl-C
# produce. See the header: the wrapper must never respawn over one of these.
_watch_wrapper_is_stop_signal_rc() {
  case "${1:-0}" in 129|130|143) return 0 ;; *) return 1 ;; esac
}

# watch_wrapper_loop — the HERD-548 supervising loop. Runs $_WATCH_CHILD_SCRIPT to completion,
# repeatedly, until a deliberate stop, a clean exit, or HERD_WATCH_CRASHLOOP_N consecutive fast deaths.
# Returns 0 on a deliberate stop/clean exit, 1 once the crash loop trips. A test seam
# ($HERD_WATCH_CHILD_SCRIPT) lets a hermetic test point this at a stub script instead of the real
# watcher — the elapsed-time math is real wall-clock ($SECONDS), never faked, because a stub that
# actually exits fast IS a fast death; nothing here needs a clock-override seam to prove it.
watch_wrapper_loop() {
  local fast=0 rc t0 elapsed capture child
  capture="$(_watch_crash_capture)"
  child="$(_watch_child_script)"
  while :; do
    t0=$SECONDS
    : > "$capture" 2>/dev/null || true
    bash "$child" 2> >(tee -a "$capture" >&2)
    rc=$?
    elapsed=$(( SECONDS - t0 ))
    _watch_wrapper_bound_capture "$capture"

    if _watch_wrapper_is_stop_signal_rc "$rc"; then
      return 0
    fi
    if [ "$rc" -eq 0 ]; then
      return 0
    fi

    if [ "$elapsed" -lt "$HERD_WATCH_CRASHLOOP_FAST_SECS" ]; then
      fast=$((fast + 1))
    else
      fast=0
    fi

    if [ "$fast" -ge "$HERD_WATCH_CRASHLOOP_N" ]; then
      declare -f watcher_crashloop_trip >/dev/null 2>&1 \
        && watcher_crashloop_trip "herd-watch: $fast consecutive fast deaths (last rc=$rc)"
      declare -f journal_append >/dev/null 2>&1 && journal_append watcher_crashloop \
        consecutive "$fast" last_rc "$rc" fast_threshold_secs "$HERD_WATCH_CRASHLOOP_FAST_SECS" \
        workspace "${WORKSPACE_NAME:-}" component herd-watch
      printf '\n⚠ herd-watch: watcher crash-looped (%s consecutive fast deaths, last rc=%s) — STOPPING respawn\n' \
        "$fast" "$rc" >&2
      printf '── last captured child stderr (%s) ──\n' "$capture" >&2
      cat "$capture" >&2 2>/dev/null
      return 1
    fi
    # Fewer than N consecutive fast deaths so far — retry immediately.
  done
}

# HERD_WATCH_WRAPPER_LIB=1 sources this in lib mode (functions only, no launch) for hermetic tests —
# same convention as agent-watch.sh / sweep.sh / watcher-resurrect.sh.
if [ "${HERD_WATCH_WRAPPER_LIB:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

if [ "${WATCHER_CRASHLOOP_GUARD:-off}" != "on" ]; then
  # The launch-binding banner + foreign-cwd guard (issue #60) runs inside agent-watch.sh, which this
  # execs into (same process): it sets HERD_REQUIRE_PROJECT_CONFIG, prints the resolved
  # WORKSPACE_NAME/PROJECT_ROOT banner, and refuses a foreign $PWD unless HERD_ALLOW_FOREIGN_CWD=1.
  # LIVE-lock refusal (HERD-252) also lives there: loud stderr + non-zero exit, never a silent hang.
  exec bash "$(_watch_child_script)"
fi

watch_wrapper_loop
exit $?
