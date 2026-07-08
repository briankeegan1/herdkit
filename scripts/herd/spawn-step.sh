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
#   done <path>       Remove the claimed intent file (intent was successfully launched) + its sidecars.
#   release <path>    Put a claimed intent BACK in the queue (.req.mine → .req) untouched — used
#                     when the lane's advisory saturation gate deferred the spawn (held, not
#                     failed): the intent must survive for a later tick, not be consumed. This is
#                     what makes the queue's durability guarantee hold under a saturated gate.
#   skip <path> <why> Warn to stderr and remove the claimed file (malformed or bad intent).
#                     The watcher loop continues; the watcher never crashes on a bad intent.
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

case "$cmd" in
  next)
    # Reclaim any .mine claims abandoned by a dead or restarted watcher (>5 min old).
    find "$Q" -name '*.mine' -mmin +5 -exec sh -c 'mv -f "$1" "${1%.mine}"' _ {} \; 2>/dev/null || true
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
  done)
    mine="${2:?usage: spawn-step.sh done <claimed-path>}"
    # intent + its sidecars: ref (HERD-64) and after-dependency (HERD-94)
    rm -f "$mine" "${mine%.req.mine}.ref" "${mine%.req.mine}.after" 2>/dev/null || true
    ;;
  release)
    mine="${2:?usage: spawn-step.sh release <claimed-path>}"
    # Put the intent back for a later tick; KEEP both sidecars (.ref, .after) so the re-queued intent
    # stays tracked AND keeps its dependency hold (HERD-94) — a dependency-held intent is released to
    # .req every tick until its dep merges, and must not lose its after= on the round-trip.
    mv -f "$mine" "${mine%.mine}" 2>/dev/null || true
    ;;
  skip)
    mine="${2:?usage: spawn-step.sh skip <claimed-path> <reason>}"
    reason="${3:-malformed intent}"
    printf 'spawn-step: WARNING — skipping intent %s: %s\n' "$(basename "${mine%.req.mine}")" "$reason" >&2
    # drop the bad intent + its sidecars: ref (HERD-64) and after-dependency (HERD-94)
    rm -f "$mine" "${mine%.req.mine}.ref" "${mine%.req.mine}.after" 2>/dev/null || true
    ;;
  *) printf 'usage: spawn-step.sh next | done <path> | release <path> | skip <path> <reason>\n' >&2; exit 2 ;;
esac
