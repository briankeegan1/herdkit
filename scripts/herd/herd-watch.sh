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
#   • a death that is a DELIBERATE STOP simply ends the wrapper. NEVER fought:
#     `_stop_project_watcher` (cmd_pane_watch / cmd_reload / the sweep) expects the pane to go quiet
#     and then drives its OWN verified relaunch — a wrapper that raced it with an unsolicited respawn
#     would double-launch into the exact singleton race HERD-266/450 exist to prevent. Recognized by
#     exit code — rc 1 is the COMMON shape: agent-watch.sh's own `trap '...; exit 1' INT TERM`
#     (installed so it can clean up the lockfile before dying) turns the bare SIGTERM
#     `_watcher_term_verified` sends into a plain `exit 1`, NOT bash's bare 128+signal encoding; rc 1
#     is ALSO what a live-singleton-lock refusal produces, and "another main is already up" means the
#     same thing here — never respawn. rc 137 is the SIGKILL escalation (uncatchable, always this
#     code); rc 129/130/143 cover the narrow pre-trap-install window. Belt-and-suspenders beyond exit
#     codes entirely: if $HERD_WATCHER_LOCK already names a LIVE pid by the time a respawn would fork
#     (a concurrent relaunch beat us to it), the wrapper also stops rather than doubling it.
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

# _watch_wrapper_is_stop_signal_rc <rc> — true iff <rc> is a shape a DELIBERATE stop of the real
# watcher produces. See the header: the wrapper must never respawn over one of these.
#
# HERD-548 review fix: the FIRST cut of this predicate recognized only bash's bare 128+signal
# encoding (129/130/143 for SIGHUP/SIGINT/SIGTERM) — the shape a process with NO trap installed
# produces. But agent-watch.sh installs `trap '_watcher_lock_cleanup; exit 1' INT TERM`
# (agent-watch.sh, the watcher-lock section) SPECIFICALLY so it can clean up the lockfile before
# dying, and that trap ends in a plain `exit 1` — NOT 130/143. `_watcher_term_verified` (bin/herd,
# the ONE stop primitive `_stop_project_watcher` / `herd reload` / `herd pane watch` / the sweep all
# route through) sends a bare SIGTERM first, so `1` is the REAL, common shape a deliberate stop
# produces — the 128+signal codes only ever fire if a signal lands before agent-watch.sh reaches the
# trap line (a narrow startup window). Recognizing only 129/130/143 therefore let the WRAPPER
# MISREAD THE ORDINARY CASE as a crash and respawn RIGHT AFTER `_stop_project_watcher` had just
# confirmed the old watcher dead — the exact duplicate-watcher singleton race (HERD-266/450) this
# feature's own header claims it never fights.
#   1   = agent-watch.sh's own INT/TERM trap (the common `_stop_project_watcher` SIGTERM shape) —
#         ALSO the shape `_acquire_watcher_singleton || exit 1` produces on a live-lock refusal
#         (another main is already up); both cases mean "do not respawn", identically, so both are
#         folded into this one code.
#   137 = 128+SIGKILL, `_watcher_term_verified`'s escalation when SIGTERM did not land in time —
#         uncatchable, always exactly this code, never anything a trap could reshape.
#   129/130/143 = the narrow pre-trap-install window above; kept for completeness.
_watch_wrapper_is_stop_signal_rc() {
  case "${1:-0}" in 1|129|130|137|143) return 0 ;; *) return 1 ;; esac
}

# _watch_wrapper_lock_taken — belt-and-suspenders beyond the exit-code shapes above: true iff
# $HERD_WATCHER_LOCK currently names a LIVE pid. If a concurrent relaunch (another `cmd_pane_watch` /
# `cmd_reload` invocation, another operator action) has ALREADY stood up a fresh watcher in the gap
# since our child died — regardless of what exit code got us here — respawning now would double it.
# Read fresh on every call, never cached, so it reflects the world exactly as of the instant before a
# respawn would fork.
_watch_wrapper_lock_taken() {
  local lock="${HERD_WATCHER_LOCK:-}" p
  [ -n "$lock" ] && [ -f "$lock" ] || return 1
  p="$(cat "$lock" 2>/dev/null || true)"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null
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
    # Plain file redirection, deliberately NOT `2> >(tee … >&2)`: one fewer async subprocess/pipe in
    # the path between a SIGTERM landing on the child and this loop observing its exit, and nothing
    # here needs stderr mirrored live — the crash-loop trip below prints the full captured tail
    # explicitly, which is the one place this file promises loud visibility. stdout (the actual
    # render) is untouched either way. NOTE for anyone hermetically testing a deliberate-stop case
    # against a stub child: bash does NOT interrupt a trap-bearing process's CURRENT foreground
    # wait() for an already-blocking command — a stub that blocks in one long `sleep 100` defers its
    # own INT/TERM trap for the full 100s (needing SIGKILL to prove anything within a test timeout).
    # The real agent-watch.sh never does this: its tick loop blocks in a 4s `sleep` between
    # iterations, so a real SIGTERM is deferred for at most ~4s — a stub proving this case must mirror
    # that short-interval shape (see tests/test-watcher-crashloop-guard.sh case 3b), not a long sleep.
    bash "$child" 2> "$capture"
    rc=$?
    elapsed=$(( SECONDS - t0 ))
    _watch_wrapper_bound_capture "$capture"

    if _watch_wrapper_is_stop_signal_rc "$rc"; then
      return 0
    fi
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    if _watch_wrapper_lock_taken; then
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
