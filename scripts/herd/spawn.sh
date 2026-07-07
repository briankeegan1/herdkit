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
# Journal (HERD-64): sourced so herd_tracked_spawn_or_abort can record a TRACKED_SPAWNS bypass.
. "$HERE/journal.sh"
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

# Tracked-spawn policy gate (HERD-64) — enforced at ENQUEUE. When TRACKED_SPAWNS=required an intent
# carrying no tracker ref (HERD_CLAIM_ID / HERD_ITEM_REF) is REFUSED here so it never enters the
# durable queue; HERD_FORCE_SPAWN=1 bypasses and journals it. Off (default) → returns 0, unchanged.
# spawn.sh parses no --force flag, so pass "" — the env escape hatch is honored inside the helper.
if ! herd_tracked_spawn_or_abort "$SLUG" ""; then
  exit 1
fi
# Resolve the ref to THREAD forward: the durable queue otherwise drops it, so a watcher-launched lane
# would see no ref and (under TRACKED_SPAWNS=required) refuse the very spawn this enqueue accepted.
# Same ref set as the gate; empty when none (untracked spawn under an off/bypass policy).
ITEM_REF="${HERD_CLAIM_ID:-${HERD_ITEM_REF:-}}"

# Enqueue atomically (temp then mv); filename sorts FIFO so oldest is drained first. The tracker ref
# rides in a SIDECAR ($INTENT_ID.ref) rather than the .req body, so the positional slug/lane/task
# parse (spawn-step.sh) is unchanged and an intent enqueued by an OLDER engine (no sidecar) still
# drains correctly (empty ref). Write the sidecar FIRST, then publish the .req, so the ref is present
# the instant the intent becomes claimable.
INTENT_ID="$(date +%s)-$$-$RANDOM"
mkdir -p "$Q"
[ -n "$ITEM_REF" ] && printf '%s\n' "$ITEM_REF" > "$Q/$INTENT_ID.ref"
tmp=$(mktemp "$Q/.tmp.XXXXXX")
printf '%s\n%s\n%s\n' "$SLUG" "$LANE" "$TASK" > "$tmp"
mv "$tmp" "$Q/$INTENT_ID.req"

printf '🚀 queued: %s (%s)%s\n' "$SLUG" "$LANE" "${ITEM_REF:+  ref: $ITEM_REF}"
printf 'INTENT_ID %s\n' "$INTENT_ID"
