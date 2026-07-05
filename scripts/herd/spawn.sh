#!/usr/bin/env bash
# spawn.sh <slug> <lane> <task> — ENQUEUE a builder spawn intent to the durable spawn queue and
# return instantly with an INTENT_ID. The watcher (agent-watch.sh) drains the queue each tick,
# launching herd-quick.sh (lane=quick) or herd-feature.sh (lane=feature) for each claimed intent,
# bounded by REVIEW_CONCURRENCY + SPAWN_AHEAD so the coordinator never builds faster than the
# review gate can keep up.
#
# Queue model: every intent is a file in $WORKTREES_DIR/spawn-queue/. The watcher claims and
# launches atomically (rename .req → .req.mine, launch lane, remove) so intents are never
# double-spawned even across watcher restarts. A malformed or reclaimed-stale intent is skipped
# with a logged warning; the watcher loop never crashes.
#
# Usage:
#   spawn.sh <slug> quick  "<task text>"
#   spawn.sh <slug> feature "<task text>"
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
TREES="$WORKTREES_DIR"
Q="$TREES/spawn-queue"
SLUG="${1:?usage: spawn.sh <slug> <lane=quick|feature> \"<task text>\"}"
LANE="${2:?usage: spawn.sh <slug> <lane=quick|feature> \"<task text>\"}"
shift 2
TASK="${*:?usage: spawn.sh <slug> <lane=quick|feature> \"<task text>\"}"

case "$LANE" in
  quick|feature) ;;
  *) printf 'spawn.sh: invalid lane "%s" — must be quick or feature\n' "$LANE" >&2; exit 1 ;;
esac

# Enqueue atomically (temp then mv); filename sorts FIFO so oldest is drained first.
INTENT_ID="$(date +%s)-$$-$RANDOM"
mkdir -p "$Q"
tmp=$(mktemp "$Q/.tmp.XXXXXX")
printf '%s\n%s\n%s\n' "$SLUG" "$LANE" "$TASK" > "$tmp"
mv "$tmp" "$Q/$INTENT_ID.req"

printf '🚀 queued: %s (%s)\n' "$SLUG" "$LANE"
printf 'INTENT_ID %s\n' "$INTENT_ID"
