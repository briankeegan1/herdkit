#!/usr/bin/env bash
# drainer-liveness.sh — shared LIVENESS helpers for the async drainer singletons (HERD-109).
#
# The scribe (backlog) and researcher drainers are per-project SINGLETONS: scribe.sh / research.sh
# spawn exactly ONE drainer and, on every subsequent enqueue, short-circuit with "already running"
# when an agent of that name is found in `herdr agent list`. That check is a LIVENESS BLIND SPOT: an
# agent that is LISTED but HUNG (a wedged claude session, a stuck step) still looks "running", so no
# replacement is ever spawned and the queue never drains — a hung drainer blocks the queue forever.
# (The existing >5-min stale-CLAIM reclaim in the *-step.sh scripts only recovers a drainer that has
# already EXITED; it does nothing for one that is hung-but-listed.)
#
# These helpers add a heartbeat so the singleton check can tell HUNG from ALIVE:
#   • herd_drainer_heartbeat <file>  — the *-step.sh scripts touch <file> on every drain step and on
#                                      each poll-loop iteration, so a LIVE drainer keeps its mtime fresh.
#   • herd_drainer_hung <file> <t>   — scribe.sh / research.sh consult this when the name-match found a
#                                      "running" drainer: a heartbeat older than <t> seconds is HUNG, so
#                                      the caller reclaims the singleton and spawns a FRESH drainer.
#
# NO DOUBLE-DRAIN: reclaiming only spawns a second drainer; the queue's atomic per-request claim
# (`.req` -> `.req.mine` rename) plus the >5-min stale-claim reclaim still guarantee each request is
# processed once — same guarantees as today. Because the hung timeout (default 900s) is far larger than
# the 5-min claim window, by the time a replacement spawns the hung drainer has been silent long enough
# that its claim (if any) is already reclaimable.
#
# FAIL-SOFT + BYTE-IDENTICAL when nothing is hung: the heartbeat write is best-effort and silent (no
# stdout), an ABSENT heartbeat is treated as ALIVE (never reclaimed), and a disabled/zero/non-numeric
# timeout is never hung — so a healthy drainer keeps the exact "already running" path it has today.
#
# Pure library: sourcing this file only DEFINES functions (no top-level side effects), so it is safe to
# source from any lane/step script. No output on source.

# herd_drainer_heartbeat <heartbeat-file>
#   Record a liveness beat: touch <heartbeat-file> so its mtime == now. Best-effort and swallow-all —
#   a drainer must never die on a heartbeat write, so every error is ignored and nothing is printed.
herd_drainer_heartbeat() {
  local _hb="${1:-}"
  [ -n "$_hb" ] || return 0
  { mkdir -p "$(dirname "$_hb")" && touch "$_hb"; } >/dev/null 2>&1 || true
  return 0
}

# herd_drainer_hung <heartbeat-file> <timeout-secs>
#   Liveness verdict for a drainer the singleton check already found "running". Returns 0 (HUNG →
#   caller reclaims the singleton and spawns a fresh drainer) ONLY when ALL of:
#     • <timeout-secs> is a POSITIVE integer  (empty / 0 / non-numeric → feature OFF → never hung), AND
#     • <heartbeat-file> EXISTS               (absent → assume ALIVE; fail-soft, byte-identical legacy), AND
#     • its mtime is strictly OLDER than <timeout-secs> ago.
#   Returns 1 (alive / not-hung / disabled) otherwise. Read-only; prints nothing.
#
#   Age is measured with `find -mmin` — the SAME portable mtime idiom the step scripts already use for
#   the stale-claim reclaim (`find … -mmin +5`), so this never depends on GNU-vs-uutils `stat`/`date`
#   differences. The seconds timeout is floored to whole minutes for -mmin (min 1), which is plenty of
#   granularity for a hung-drainer timeout measured in minutes.
herd_drainer_hung() {
  local _hb="${1:-}" _t="${2:-0}"
  case "$_t" in ''|*[!0-9]*) return 1 ;; esac   # empty / non-numeric → OFF
  [ "$_t" -gt 0 ] || return 1                   # 0 → disabled
  [ -n "$_hb" ] && [ -f "$_hb" ] || return 1    # absent heartbeat → assume alive (fail-soft)
  local _mins=$(( _t / 60 ))
  [ "$_mins" -ge 1 ] || _mins=1
  [ -n "$(find "$_hb" -mmin "+$_mins" 2>/dev/null)" ]
}
