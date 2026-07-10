#!/usr/bin/env bash
# spawn-step.sh — atomic queue mechanics for the durable spawn queue. Called from the watcher's
# _drain_spawn_queue (agent-watch.sh), NOT by a Claude drainer — the drain is purely mechanical.
#
# Subcommands:
#   next              Reclaim stale claims (>5 min old); atomically claim the oldest pending
#                     intent via a rename (.req → .req.mine); print:
#                       "CLAIMED <path>"
#                       <slug>
#                       <lane>
#                       <tracker ref>    (HERD-64; the $INTENT_ID.ref sidecar, EMPTY line when absent)
#                       <after dep>      (HERD-94; the $INTENT_ID.after sidecar, EMPTY line when absent)
#                       <task text>
#                     Or print "EMPTY" when the queue has no pending intents. Returns immediately
#                     (no polling wait — the watcher calls this on every tick). The ref AND after lines
#                     are ALWAYS emitted (empty for an untracked / no-dependency / older-engine intent)
#                     so the drain's positional read stays fixed; the watcher re-exports the ref as
#                     HERD_ITEM_REF and HOLDS the intent while the after dependency is unmet (HERD-94).
#   own <path> <pid>  Record <pid> as the LIVE OWNER of a claim, so the stale reclaim in `next` can
#                     tell "a lane is still running this intent" from "a dead watcher abandoned it".
#                     Writes the $INTENT_ID.owner sidecar (pid + its process start-time).
#   done <path>       Remove the claimed intent file (intent was successfully launched) + its sidecars.
#   release <path>    Put a claimed intent BACK in the queue (.req.mine → .req) unconsumed — used
#                     when the lane's advisory saturation gate deferred the spawn (held, not
#                     failed): the intent must survive for a later tick, not be consumed. This is
#                     what makes the queue's durability guarantee hold under a saturated gate.
#   skip <path> <why> Warn to stderr and remove the claimed file (malformed or bad intent).
#                     The watcher loop continues; the watcher never crashes on a bad intent.
#
# done / release / skip EXIT NON-ZERO (3) when the claim they were handed no longer exists. Silently
# `rm -f`-ing a vanished path (as they did before HERD-237) turns a lost claim into a phantom success:
# the caller journals spawn_launched for an intent that is still queued, and it spawns again.
#
# Paths honor the standard WORKTREES_DIR so the queue is co-located with the scribe and research
# queues under the same .herd worktree pool.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
TREES="$WORKTREES_DIR"
Q="$TREES/spawn-queue"
mkdir -p "$Q"
cmd="${1:-}"

# _spawn_pid_starttime <pid> — the pid's process start-time, or empty. The recycling guard: a pid
# reused by an unrelated process reports a different start-time. Mirrors agent-watch.sh's _pid_starttime
# EXACTLY, including its HERD_PID_STARTTIME_CMD test seam — the two helpers read and write the same
# .owner sidecar, so a hermetic test that stubs the seam on one side must not see the other shell out
# to a real `ps`.
_spawn_pid_starttime() {
  local p="${1:-}"; [ -n "$p" ] || return 0
  if [ -n "${HERD_PID_STARTTIME_CMD:-}" ]; then "$HERD_PID_STARTTIME_CMD" "$p" 2>/dev/null; return 0; fi
  ps -o lstart= -p "$p" 2>/dev/null | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# _spawn_owner_alive <owner-sidecar> — true iff the sidecar names a process that is STILL RUNNING and
# is still the same process it named (pid alive AND start-time unchanged). Absent sidecar, malformed
# pid, dead pid or a recycled pid ⇒ false, i.e. the claim is reclaimable. An unreadable CURRENT
# start-time trusts the bare `kill -0` so a transient `ps` hiccup never reclaims a live lane's intent.
_spawn_owner_alive() {
  local f="$1" pid st cur
  [ -f "$f" ] || return 1
  pid="$(sed -n 1p "$f" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  st="$(sed -n 2p "$f" 2>/dev/null || true)"; [ -n "$st" ] || return 0
  cur="$(_spawn_pid_starttime "$pid")"; [ -n "$cur" ] || return 0
  [ "$cur" = "$st" ]
}

# _spawn_require_claim <path> <verb> — a claimed path that has vanished is NEVER a silent no-op.
_spawn_require_claim() {
  [ -f "$1" ] && return 0
  printf 'spawn-step: WARNING — %s: claim %s no longer exists (reclaimed or already consumed)\n' \
    "$2" "$(basename "${1%.req.mine}")" >&2
  exit 3
}

case "$cmd" in
  next)
    # Reclaim any .mine claims abandoned by a dead or restarted watcher (>5 min old). Staleness is the
    # CLAIM age, not the enqueue age: `next` and `release` (below) touch the file whenever it changes
    # hands, so `-mmin +5` measures time-since-last-claim. Without that touch, `mv` preserves the
    # enqueue mtime, so an intent enqueued >5 min ago (e.g. a dependency-held intent, HERD-94) would be
    # re-served on EVERY reclaim within a single tick — the drain loop spins forever (HERD-116). A
    # genuinely abandoned claim still ages past 5 min from its last claim/release, so the legitimate
    # dead-watcher reclaim is preserved.
    #
    # HERD-237 — LIVENESS, NOT AGE, IS THE PREDICATE. The blanket age reclaim rested on a premise that
    # no longer holds: that a claim can only outlive a tick if its watcher died. The drain now launches
    # its lane in a BACKGROUND worker that holds the claim for the lane's whole duration, and a lane
    # that exceeds five minutes (a slow clone, a wedged driver call — precisely the fault this design
    # exists to tolerate) is normal. Age-reclaiming it re-serves an intent that is being launched right
    # now: the lane's `done` then rm's a path that has moved, the intent is never consumed, and the
    # next free tick spawns the SAME slug a second time — a duplicate worktree, branch and agent.
    # So an aged claim is reclaimed only when its owner is provably gone: `.owner` names the worker's
    # pid + start-time (written via `own`, below), and a live owner keeps its claim indefinitely. A
    # claim with NO owner sidecar (a dependency hold, an older engine's intent, a watcher killed
    # between `next` and `own`) reclaims on age exactly as before.
    while IFS= read -r _stale; do
      [ -n "$_stale" ] || continue
      _owner="${_stale%.req.mine}.owner"
      _spawn_owner_alive "$_owner" && continue     # a live lane still owns this intent — hands off
      rm -f "$_owner" 2>/dev/null || true
      mv -f "$_stale" "${_stale%.mine}" 2>/dev/null || true
    done < <(find "$Q" -name '*.mine' -mmin +5 2>/dev/null || true)
    # GC owner sidecars whose claim is gone (a worker that exited between `own` and its own cleanup).
    for _orph in "$Q"/*.owner; do
      [ -e "$_orph" ] || continue
      [ -f "${_orph%.owner}.req.mine" ] || rm -f "$_orph" 2>/dev/null || true
    done
    # Atomic claim: walk the queue oldest-first and try to win each candidate via an atomic
    # rename. If mv fails another process already claimed that file — skip to the next candidate.
    claimed=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if mv "$f" "$f.mine" 2>/dev/null; then
        claimed="$f.mine"; break
      fi
    done < <(ls -1 "$Q"/*.req 2>/dev/null | sort)
    if [ -n "$claimed" ]; then
      # Restart the 5-minute stale clock on the fresh claim so a held intent (re-claimed every tick
      # while its dependency is unmet) is not instantly reclaimed as "stale" by a later `next` in the
      # same tick — that resurrect-and-re-serve loop is exactly the HERD-116 watcher freeze.
      touch "$claimed" 2>/dev/null || true
      printf 'CLAIMED %s\n' "$claimed"
      head -1 "$claimed"        # line 1: slug
      sed -n '2p' "$claimed"    # line 2: lane
      # line 3: tracker ref (HERD-64) — from the $INTENT_ID.ref sidecar, keyed off the claim path.
      # ALWAYS one line: the sidecar's first line when present, else an empty line (untracked / older
      # intent). The task follows on subsequent lines, so this keeps the reader's positional parse fixed.
      _ref="${claimed%.req.mine}.ref"
      if [ -f "$_ref" ]; then head -1 "$_ref"; else printf '\n'; fi
      # after dependency (HERD-94) — from the $INTENT_ID.after sidecar, keyed off the claim path.
      # ALWAYS one line: the sidecar's first line when present, else an empty line (no dependency /
      # older intent). Keeps the reader's positional parse fixed just as the ref line above does.
      _after="${claimed%.req.mine}.after"
      if [ -f "$_after" ]; then head -1 "$_after"; else printf '\n'; fi
      tail -n +3 "$claimed"     # line 3+ of the .req: task text
      exit 0
    fi
    printf 'EMPTY\n'; exit 0
    ;;
  own)
    # Bind a claim to the live process that is working it (HERD-237). Called by the drain's background
    # lane worker as its FIRST act, with its own pid: from here until the worker consumes or releases
    # the claim, `next` will not reclaim it however long the lane takes. The window between the claim
    # (which touches the file, restarting its 5-minute clock) and this call is microseconds wide, and a
    # watcher that dies inside it simply leaves an unowned claim that ages out normally.
    mine="${2:?usage: spawn-step.sh own <claimed-path> <pid>}"
    pid="${3:?usage: spawn-step.sh own <claimed-path> <pid>}"
    _spawn_require_claim "$mine" own
    { printf '%s\n' "$pid"; printf '%s\n' "$(_spawn_pid_starttime "$pid")"; } \
      > "${mine%.req.mine}.owner" 2>/dev/null || true
    ;;
  done)
    mine="${2:?usage: spawn-step.sh done <claimed-path>}"
    _spawn_require_claim "$mine" done
    # intent + its sidecars: ref (HERD-64), after-dependency (HERD-94), owner (HERD-237)
    rm -f "$mine" "${mine%.req.mine}.ref" "${mine%.req.mine}.after" "${mine%.req.mine}.owner" 2>/dev/null || true
    ;;
  release)
    mine="${2:?usage: spawn-step.sh release <claimed-path>}"
    _spawn_require_claim "$mine" release
    # Put the intent back for a later tick; KEEP both sidecars (.ref, .after) so the re-queued intent
    # stays tracked AND keeps its dependency hold (HERD-94) — a dependency-held intent is released to
    # .req every tick until its dep merges, and must not lose its after= on the round-trip. The owner
    # sidecar does NOT survive: the intent is back in the queue, owned by nobody.
    released="${mine%.mine}"
    rm -f "${mine%.req.mine}.owner" 2>/dev/null || true
    # Restart the stale clock BEFORE the rename, not after (HERD-237). `release` used to `mv` and then
    # `touch "$released"`. Pre-HERD-237 that pair only ever ran in the drain's foreground, serialized
    # against `next`; it now runs in the background lane worker while the parent tick's `next` walks the
    # queue. If `next` re-claims the just-released intent in the gap, the trailing `touch` CREATES an
    # empty `<id>.req` beside the live `<id>.req.mine` — a phantom intent. Touching the claim first and
    # letting `mv` carry the fresh mtime across makes the release a single atomic rename with no window.
    # (The clock still restarts: a just-released intent must not be instantly reclaimable as "stale", or
    # the enqueue age leaks back in and revives the HERD-116 spin.)
    touch "$mine" 2>/dev/null || true
    mv -f "$mine" "$released" 2>/dev/null || true
    ;;
  skip)
    mine="${2:?usage: spawn-step.sh skip <claimed-path> <reason>}"
    reason="${3:-malformed intent}"
    _spawn_require_claim "$mine" skip
    printf 'spawn-step: WARNING — skipping intent %s: %s\n' "$(basename "${mine%.req.mine}")" "$reason" >&2
    # drop the bad intent + its sidecars: ref (HERD-64), after-dependency (HERD-94), owner (HERD-237)
    rm -f "$mine" "${mine%.req.mine}.ref" "${mine%.req.mine}.after" "${mine%.req.mine}.owner" 2>/dev/null || true
    ;;
  *) printf 'usage: spawn-step.sh next | own <path> <pid> | done <path> | release <path> | skip <path> <reason>\n' >&2; exit 2 ;;
esac
