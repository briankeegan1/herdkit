#!/usr/bin/env bash
# test-lifecycle-lane-workers.sh — hermetic proof that the two BACKGROUNDED LANE WORKERS HERD-237
# forks off the tick are supervised processes like every other population (HERD-268).
#
# The populations: the builder lane worker (`.spawn-inflight-lane-*`) and the resolver lane worker
# (`.spawn-inflight-resolve-*`). Both already had an OWNER (agent-watch) and a LIVENESS probe (the
# marker's pid + start-time, via _marker_write); what they lacked was DEADLINE + RETIRE bookkeeping,
# so a lane worker orphaned by a watcher killed mid-dispatch left a marker and a process that no
# supervisor could attribute.
#
# Drives the REAL agent-watch.sh (sourced in lib mode) against the REAL lifecycle.sh, through their
# documented seams (LIFECYCLE_CONTRACTS, HERD_LIFECYCLE_DIR, HERD_LIFECYCLE_INBOX, HERD_LIFECYCLE_NOW,
# JOURNAL_FILE). Asserts:
#
#   (1) THE RECORD KEY — a marker path maps to exactly one (population, id); a marker of any other
#       kind is not supervised by this leg.
#   (2) BYTE-IDENTICAL WHEN OFF — with LIFECYCLE_CONTRACTS unset (the default), a full dispatch →
#       complete → sweep cycle writes NO record, NO journal line, NO inbox row. The worker still runs
#       and its marker still lands and clears, unchanged.
#   (3) A LIVE WORKER IS REGISTERED — the dispatch writes one record carrying all four properties
#       (owner=agent-watch · probe=pid:<worker> · deadline · route) and journals lifecycle_spawn.
#   (4) A CLEAN COMPLETION CLOSES THE CONTRACT — when the worker's body returns it clears its marker
#       and retires its own record with reason=completed. Nothing lingers.
#   (5) BOTH POPULATIONS — a resolver lane dispatch registers/retires as `resolver-lane`.
#   (6) A DEAD WORKER IS RETIRED AND JOURNALED — `_spawn_inflight_sweep`, the lane populations' corpse
#       sweep, reaps the marker of a worker killed mid-flight AND retires its record (reason=swept).
#       A LIVE marker is left completely alone.
#   (7) THE BACKSTOP — a record whose marker sweep never ran is reconciled by lifecycle_sweep: a dead
#       pid becomes reason=exited once the exit grace lapses; a worker still ALIVE past its deadline is
#       journaled `lifecycle_expired` + inboxed with its route, and is NEVER killed.
#   (8) THE TABLE — both populations carry a deadline and a route naming a real actor.
#
# Fully hermetic: writes only under a mktemp dir; no herdr, no gh, no network, no model, no watcher.
# Run:  bash tests/test-lifecycle-lane-workers.sh
# No `set -e`: several checks deliberately assert a non-zero predicate return.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# ── Hermetic surfaces. Nothing below may escape $T ───────────────────────────────────────────────
export HERD_HERMETIC_GUARD=1
export AGENT_WATCH_LIB=1
export HERD_DRIVER=headless
export PROJECT_ROOT="$T/main";   mkdir -p "$PROJECT_ROOT"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_LIFECYCLE_DIR="$T/trees/.lifecycle"
export HERD_LIFECYCLE_INBOX="$T/trees/.agent-watch-inbox"; : > "$HERD_LIFECYCLE_INBOX"
export DRYRUN=""

# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
TREES="$WORKTREES_DIR"
SPAWN_INFLIGHT_PREFIX="$TREES/.spawn-inflight-"

reset_surfaces() {
  rm -rf "$HERD_LIFECYCLE_DIR"
  rm -f "$SPAWN_INFLIGHT_PREFIX"* 2>/dev/null || true
  : > "$JOURNAL_FILE"
  : > "$HERD_LIFECYCLE_INBOX"
}
jcount() { grep -c "\"event\":\"$1\"" "$JOURNAL_FILE" 2>/dev/null | tr -cd '0-9' | sed 's/^$/0/'; }
jfield() {  # jfield <event> <key> — the key's value on the LAST matching event line
  python3 - "$JOURNAL_FILE" "$1" "$2" <<'PY'
import json, sys
path, ev, key = sys.argv[1], sys.argv[2], sys.argv[3]
val = ""
for line in open(path, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("event") == ev:
        val = str(o.get(key, ""))
print(val, end="")
PY
}
inbox_rows() { wc -l < "$HERD_LIFECYCLE_INBOX" 2>/dev/null | tr -cd '0-9' | sed 's/^$/0/'; }
records()    { find "$HERD_LIFECYCLE_DIR" -maxdepth 1 -type f -name '*__*' ! -name '*.expired' ! -name '*.gone' 2>/dev/null | wc -l | tr -cd '0-9'; }

# A pid that is certainly not running: fork a true subshell and reap it.
dead_pid()    { ( exit 0 ) & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
# A real, long-lived child the sweep must never kill. Its stdio is detached so it cannot hold a pipe open.
start_sleeper() { sleep 300 >/dev/null 2>&1 & printf '%s' "$!"; }
cleanup_children() { pkill -P $$ 2>/dev/null || true; }
trap 'cleanup_children; rm -rf "$T"' EXIT

# The two marker names a real dispatch produces (_spawn_inflight_file's own output — never hand-rolled).
LANE_M="$(_spawn_inflight_file lane fixit "intent42-1")"
RESOLVE_M="$(_spawn_inflight_file resolve fixit "77-abc123-1")"

# The lane workers under test. `lane_body` is what a real _drain_lane_worker / _spawn_resolver_lane
# stands in for here: a body that takes long enough to be observed mid-flight, then returns.
LANE_RAN="$T/lane.ran"
lane_body() { printf 'ran\n' >> "$LANE_RAN"; sleep 2; }

# ── (1) the record key: marker path → (population, id) ───────────────────────────────────────────
[ "$(_lane_lifecycle_key "$LANE_M")"    = "$(printf 'lane-worker\tfixit-intent42_1')" ] \
  || fail "(1) lane marker did not key to lane-worker: [$(_lane_lifecycle_key "$LANE_M")]"
[ "$(_lane_lifecycle_key "$RESOLVE_M")" = "$(printf 'resolver-lane\tfixit-77_abc123_1')" ] \
  || fail "(1) resolve marker did not key to resolver-lane: [$(_lane_lifecycle_key "$RESOLVE_M")]"
_lane_lifecycle_key "$TREES/.review-inflight-77-abc" >/dev/null 2>&1 \
  && fail "(1) a non-lane marker must not be supervised by this leg"
# An unsupervised marker is a HARD no-op on both seams, never a half-written record.
LIFECYCLE_CONTRACTS=on _lane_lifecycle_spawn "$TREES/.review-inflight-77-abc" 4242
[ "$(records)" = "0" ] || fail "(1) an unsupervised marker wrote a lifecycle record"
pass; echo "PASS (1) marker path keys to exactly one (population, id); other marker kinds are untouched"

# ── (2) SHIP-DORMANT: with the lever off, the whole cycle writes nothing ─────────────────────────
reset_surfaces
(
  unset LIFECYCLE_CONTRACTS            # the DEFAULT, not an explicit off
  _spawn_inflight_bg "$LANE_M" lane_body
  [ -f "$LANE_M" ] || fail "(2) dispatch did not write the inflight marker"
  wait "$_SPAWN_INFLIGHT_BG_PID" 2>/dev/null
  _spawn_inflight_sweep
) || fail "(2) a dispatch with the lever off must not fail its caller"
[ -f "$LANE_RAN" ]                  || fail "(2) the lane worker never ran"
[ ! -f "$LANE_M" ]                  || fail "(2) the worker did not clear its marker"
[ ! -d "$HERD_LIFECYCLE_DIR" ] || [ "$(records)" = "0" ] || fail "(2) default-off wrote a record"
[ ! -s "$JOURNAL_FILE" ]            || fail "(2) default-off wrote a journal line"
[ "$(inbox_rows)" = "0" ]           || fail "(2) default-off wrote an inbox row"
pass; echo "PASS (2) LIFECYCLE_CONTRACTS unset ⇒ the lane dispatch/complete/sweep cycle is byte-inert"

export LIFECYCLE_CONTRACTS=on

# ── (3) a live worker is REGISTERED with all four properties ─────────────────────────────────────
reset_surfaces
: > "$LANE_RAN"
_spawn_inflight_bg "$LANE_M" lane_body
LANE_PID="$_SPAWN_INFLIGHT_BG_PID"
[ -f "$LANE_M" ]                                            || fail "(3) no inflight marker"
[ "$(records)" = "1" ]                                      || fail "(3) dispatch did not register exactly one contract"
[ "$(jcount lifecycle_spawn)" = "1" ]                       || fail "(3) dispatch did not journal lifecycle_spawn"
[ "$(jfield lifecycle_spawn population)" = "lane-worker" ]  || fail "(3) POPULATION not journaled"
[ "$(jfield lifecycle_spawn id)"         = "fixit-intent42_1" ] || fail "(3) id not journaled"
[ "$(jfield lifecycle_spawn owner)"      = "agent-watch" ]  || fail "(3) OWNER not journaled at spawn"
[ "$(jfield lifecycle_spawn probe)"      = "pid:$LANE_PID" ]|| fail "(3) LIVENESS probe is not the worker's pid"
[ "$(jfield lifecycle_spawn deadline)"   = "1800" ]         || fail "(3) DEADLINE not journaled"
[ "$(jfield lifecycle_spawn route)"      = "operator" ]     || fail "(3) RETIRE route not journaled"
# A live worker's record survives its own sweep untouched — a lane that is merely SLOW is not a leak.
_spawn_inflight_sweep
[ -f "$LANE_M" ]                       || fail "(3) the sweep reaped a LIVE worker's marker"
[ "$(records)" = "1" ]                 || fail "(3) the sweep retired a LIVE worker's contract"
[ "$(jcount lifecycle_retire)" = "0" ] || fail "(3) the sweep journaled a retirement for a live worker"
pass; echo "PASS (3) a live lane worker is registered with owner + deadline + liveness + route, and left alone"

# ── (4) a clean completion CLOSES the contract ───────────────────────────────────────────────────
wait "$LANE_PID" 2>/dev/null
[ -s "$LANE_RAN" ]                                     || fail "(4) the lane worker never ran"
[ ! -f "$LANE_M" ]                                     || fail "(4) a finished worker left its marker behind"
[ "$(records)" = "0" ]                                 || fail "(4) a finished worker left its contract open"
[ "$(jcount lifecycle_retire)" = "1" ]                 || fail "(4) clean completion did not journal lifecycle_retire"
[ "$(jfield lifecycle_retire reason)" = "completed" ]  || fail "(4) clean completion must retire with reason=completed"
[ "$(jfield lifecycle_retire lived_secs)" -ge 0 ] 2>/dev/null || fail "(4) lived_secs not measured"
# And a sweep over the settled world is a no-op: no second retirement for an already-closed contract.
_spawn_inflight_sweep
[ "$(jcount lifecycle_retire)" = "1" ]                 || fail "(4) the sweep re-journaled a closed contract"
pass; echo "PASS (4) a completed lane worker clears its marker and retires its own contract (reason=completed)"

# ── (5) the resolver lane is the same contract, under its own population ─────────────────────────
reset_surfaces
# `true` is the WORST CASE for the dispatch race: the worker's whole body runs before the parent has
# recorded anything. Whichever way the writes interleave, the worker must end up accounted for — either
# it retired itself, or its marker survived naming a dead pid and the corpse sweep retires it.
_spawn_inflight_bg "$RESOLVE_M" true
RESOLVE_PID="$_SPAWN_INFLIGHT_BG_PID"
[ "$(jfield lifecycle_spawn population)" = "resolver-lane" ] || fail "(5) resolve marker did not register as resolver-lane"
wait "$RESOLVE_PID" 2>/dev/null
_spawn_inflight_sweep
[ "$(records)" = "0" ]                 || fail "(5) a finished resolver lane left its contract open"
[ "$(jcount lifecycle_retire)" = "1" ] || fail "(5) a finished resolver lane did not retire exactly once"
[ "$(jfield lifecycle_retire population)" = "resolver-lane" ] || fail "(5) retire carried the wrong population"
pass; echo "PASS (5) the resolver lane registers + retires under its own population"

# ── (6) a DEAD worker is reaped AND retired by the lane populations' corpse sweep ────────────────
reset_surfaces
DEAD="$(dead_pid)"
_marker_write "$LANE_M" "$DEAD"                 # a watcher killed mid-dispatch: marker + record, no worker
_lane_lifecycle_spawn "$LANE_M" "$DEAD"
[ "$(records)" = "1" ] || fail "(6) fixture did not register the orphaned worker"
# A LIVE sibling marker must survive the same sweep — the sweep keys on liveness, not on age.
SLEEPER="$(start_sleeper)"
_marker_write "$RESOLVE_M" "$SLEEPER"
_lane_lifecycle_spawn "$RESOLVE_M" "$SLEEPER"
_spawn_inflight_sweep
[ ! -f "$LANE_M" ]                                 || fail "(6) the sweep did not reap the dead worker's marker"
[ "$(jcount lifecycle_retire)" = "1" ]             || fail "(6) the sweep did not retire the dead worker's contract"
[ "$(jfield lifecycle_retire reason)" = "swept" ]  || fail "(6) a swept corpse must retire with reason=swept"
[ "$(jfield lifecycle_retire population)" = "lane-worker" ] || fail "(6) the wrong population was retired"
[ -f "$RESOLVE_M" ]                                || fail "(6) the sweep reaped a LIVE worker's marker"
[ "$(records)" = "1" ]                             || fail "(6) the sweep retired the LIVE worker's contract too"
kill -0 "$SLEEPER" 2>/dev/null                     || fail "(6) the sweep KILLED a live worker"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
pass; echo "PASS (6) a dead lane worker is reaped + retired (reason=swept); a live one is untouched"

# ── (7) the per-tick backstop: lifecycle_sweep reconciles what the marker sweep never saw ────────
# (7a) DEAD PID, marker sweep never ran (a watcher that died before its next tick). Past deadline, the
# record is NEVER reported as a hang: death wins, and after the exit grace it is retired as `exited`.
reset_surfaces
DEAD2="$(dead_pid)"
_lane_lifecycle_spawn "$LANE_M" "$DEAD2"
FUTURE="$(( $(date +%s) + 7200 ))"                 # 2h past the 1800s deadline
OUT="$(HERD_LIFECYCLE_NOW="$FUTURE" lifecycle_sweep)"
[ "$OUT" = "" ]                          || fail "(7a) an exited lane worker must never be routed as expired"
[ "$(jcount lifecycle_expired)" = "0" ]  || fail "(7a) an exited lane worker must never journal an expiry"
[ "$(jcount lifecycle_retire)" = "0" ]   || fail "(7a) the sweep must not claim an exit inside the grace"
OUT="$(HERD_LIFECYCLE_NOW="$(( FUTURE + 120 ))" lifecycle_sweep)"   # grace lapsed
[ "$(jcount lifecycle_retire)" = "1" ]   || fail "(7a) an abandoned exited lane worker must be retired"
[ "$(jfield lifecycle_retire reason)" = "exited" ] || fail "(7a) backstop retire reason must be 'exited'"
[ "$(records)" = "0" ]                   || fail "(7a) the exited record must not linger"

# (7b) ALIVE past its deadline — the genuine leak this contract exists to surface. Journaled once,
# inboxed once, routed to the operator, and the process is left running for its owner to judge.
reset_surfaces
SLEEPER2="$(start_sleeper)"
_marker_write "$RESOLVE_M" "$SLEEPER2"
_lane_lifecycle_spawn "$RESOLVE_M" "$SLEEPER2"
OUT="$(HERD_LIFECYCLE_NOW="$FUTURE" lifecycle_sweep)"
[ "$OUT" = "$(printf 'resolver-lane\tfixit-77_abc123_1\toperator')" ] \
  || fail "(7b) a live-but-overdue lane worker must route to its owner: [$OUT]"
[ "$(jcount lifecycle_expired)" = "1" ]                       || fail "(7b) expiry not journaled exactly once"
[ "$(jfield lifecycle_expired route)" = "operator" ]          || fail "(7b) lifecycle_expired must carry the route"
[ "$(jfield lifecycle_expired population)" = "resolver-lane" ]|| fail "(7b) lifecycle_expired must carry the population"
[ "$(inbox_rows)" = "1" ]                                     || fail "(7b) expiry did not append exactly one inbox row"
grep -q "lifecycle:resolver-lane" "$HERD_LIFECYCLE_INBOX"     || fail "(7b) inbox row missing the lifecycle:<population> ref"
kill -0 "$SLEEPER2" 2>/dev/null                               || fail "(7b) the sweep KILLED an overdue lane worker"
[ "$(records)" = "1" ]                                        || fail "(7b) an expired-but-live record must survive for its owner"
OUT="$(HERD_LIFECYCLE_NOW="$FUTURE" lifecycle_sweep)"
[ "$OUT" = "" ]                                               || fail "(7b) a second sweep re-flooded an already-surfaced expiry"
kill "$SLEEPER2" 2>/dev/null; wait "$SLEEPER2" 2>/dev/null
pass; echo "PASS (7) backstop: dead ⇒ exited after the grace; alive-past-deadline ⇒ one expiry + one inbox row, never a kill"

# ── (8) the table: both populations carry a deadline and a route naming a real actor ─────────────
[ "$(lifecycle_deadline lane-worker)"   = "1800" ] || fail "(8) lane-worker deadline"
[ "$(lifecycle_deadline resolver-lane)" = "1800" ] || fail "(8) resolver-lane deadline"
[ "$(lifecycle_route lane-worker)"      = "operator" ] || fail "(8) lane-worker route"
[ "$(lifecycle_route resolver-lane)"    = "operator" ] || fail "(8) resolver-lane route"
# The lane populations must not disturb the ones HERD-193 shipped.
[ "$(lifecycle_route reviewer)"  = "gate-corpse-sweep"   ] || fail "(8) reviewer route regressed"
[ "$(lifecycle_route resolver)"  = "resolver-escalation" ] || fail "(8) resolver (agent) route regressed"
pass; echo "PASS (8) both lane populations carry a deadline + a route; the shipped populations are unchanged"

echo
echo "✅ test-lifecycle-lane-workers.sh — $PASS/8 checks passed — ALL PASS"
