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

# herd_drainer_live_status <agent-name> [agent-list-json]
#   CORROBORATE a listed drainer's liveness before a heartbeat-stale reclaim (HERD-122). A stale
#   heartbeat is NOT, by itself, proof of a hang: a fresh drainer that has not yet written its first
#   beat, or a live drainer mid-long-step, is ALIVE. The 2026-07-08 false positive reclaimed a
#   healthy seconds-old drainer (status=working throughout) and then failed the respawn with
#   `herdr agent_name_taken`. This helper answers "is the agent actually alive?" with one token:
#     alive   — POSITIVE liveness: the agent's DRIVER status is working/idle (a live, responsive
#               session) OR the process-liveness probe reports a live agent process. NEVER reclaim it.
#     dead    — POSITIVE evidence the process is GONE (a bare pane after a kill / a recorded-but-dead
#               pid). This is a genuine hang → reclaim is warranted.
#     unknown — cannot tell (no record, probe absent/opaque). Fail-soft: never fabricate a death.
#   The optional 2nd arg is a captured `herdr agent list` JSON blob — the caller captures it ONCE for
#   both the singleton presence check and this corroboration, avoiding a second list call / TOCTOU. A
#   working/idle status there short-circuits to "alive" (the exact signal the incident report names:
#   "a working/idle live agent is NEVER hung regardless of heartbeat age"). Only when the status is
#   NOT positively-live does it consult the deeper process probe herd_driver_agent_liveness (HERD-114)
#   for ground truth. Read-only; prints exactly one token; never fails.
herd_drainer_live_status() {
  local _name="${1:-}" _json="${2:-}"
  [ -n "$_name" ] || { printf 'unknown'; return 0; }
  local _status=""
  if [ -n "$_json" ]; then
    _status="$(NAME="$_name" JSON="$_json" python3 -c '
import os, json
name = os.environ["NAME"]
try:
  ags = (json.loads(os.environ["JSON"]).get("result") or {}).get("agents") or []
except Exception:
  ags = []
st = ""
for a in ags:
  if a.get("name") == name or a.get("agent") == name:
    st = (a.get("agent_status") or a.get("status") or ""); break
print(st.strip().lower(), end="")
' 2>/dev/null || true)"
  fi
  case "$_status" in
    working|idle|busy|active|running) printf 'alive'; return 0 ;;
  esac
  # Status is not positively-live (empty / done / a stale word). Fall back to the process-level probe
  # for ground truth. The step scripts source this lib WITHOUT driver.sh, but they never call this
  # function; the lanes that do (scribe.sh / research.sh) source driver.sh first. Guard anyway so a
  # bare source is safe.
  if command -v herd_driver_agent_liveness >/dev/null 2>&1; then
    herd_driver_agent_liveness "$_name"
  else
    printf 'unknown'
  fi
}

# herd_drainer_should_reclaim <heartbeat-file> <timeout-secs> <live-status>
#   The full HERD-122 reclaim gate the enqueue lanes use. Returns 0 (RECLAIM the singleton + spawn a
#   fresh drainer) ONLY when BOTH:
#     • the heartbeat is stale past <timeout-secs>  (herd_drainer_hung — off/absent/fresh → keep), AND
#     • the corroborated <live-status> is POSITIVE death ("dead").
#   A live (working/idle) agent, an unknown/unprobeable agent, a fresh or absent heartbeat, or a
#   disabled timeout ALL keep the legacy "already running" short-circuit — so a fresh/live drainer is
#   NEVER falsely reclaimed (no-false-red), while a genuinely dead one (dead pid + stale heartbeat)
#   still reclaims. Returns 1 → keep. Read-only; prints nothing.
herd_drainer_should_reclaim() {
  local _hb="${1:-}" _t="${2:-0}" _live="${3:-}"
  herd_drainer_hung "$_hb" "$_t" || return 1   # not stale (or feature off / absent) → keep
  [ "$_live" = "dead" ]                         # reclaim ONLY on POSITIVE death
}
