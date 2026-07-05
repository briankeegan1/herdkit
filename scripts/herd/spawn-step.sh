#!/usr/bin/env bash
# spawn-step.sh — atomic queue mechanics for the durable spawn queue. Called from the watcher's
# _drain_spawn_queue (agent-watch.sh), NOT by a Claude drainer — the drain is purely mechanical.
#
# Subcommands:
#   next              Reclaim stale claims (>5 min old); atomically claim the oldest pending
#                     intent via a rename (.req → .req.mine); print four lines:
#                       "CLAIMED <path>"
#                       <slug>
#                       <lane>
#                       <task text>
#                     Or print "EMPTY" when the queue has no pending intents. Returns immediately
#                     (no polling wait — the watcher calls this on every tick).
#   done <path>       Remove the claimed intent file (intent was successfully launched).
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
      tail -n +3 "$claimed"     # line 3+: task text
      exit 0
    fi
    printf 'EMPTY\n'; exit 0
    ;;
  done)
    mine="${2:?usage: spawn-step.sh done <claimed-path>}"
    rm -f "$mine" 2>/dev/null || true
    ;;
  skip)
    mine="${2:?usage: spawn-step.sh skip <claimed-path> <reason>}"
    reason="${3:-malformed intent}"
    printf 'spawn-step: WARNING — skipping intent %s: %s\n' "$(basename "${mine%.req.mine}")" "$reason" >&2
    rm -f "$mine" 2>/dev/null || true
    ;;
  *) printf 'usage: spawn-step.sh next | done <path> | skip <path> <reason>\n' >&2; exit 2 ;;
esac
