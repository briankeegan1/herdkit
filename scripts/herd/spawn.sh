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
#   HERD_SPAWN_AFTER=<slug|pr#> spawn.sh <slug> feature "<task>"   # HELD until the dep merges (HERD-94)
#   HERD_SPAWN_PRIO=<n> spawn.sh <slug> feature "<task>"           # drains in band <n> (HERD-630)
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

# Dependency ordering (HERD-94): an OPTIONAL after=<slug|pr#> makes the watcher's drainer HOLD this
# intent until that dependency shows MERGED (spawn B only after A lands), so a coordinator's wave plan
# survives without the coordinator's live session. Sourced from HERD_SPAWN_AFTER (env). A leading '#'
# on a PR number is stripped so 'after=#123' and 'after=123' are identical. Empty when unset — the
# intent drains immediately, BYTE-IDENTICAL to a pre-HERD-94 spawn. Recorded in a SIDECAR
# ($INTENT_ID.after), mirroring the .ref sidecar, so the positional slug/lane/task parse is unchanged
# and an intent enqueued by an OLDER engine (no sidecar) still drains correctly (empty = no dependency).
AFTER="${HERD_SPAWN_AFTER:-}"
AFTER="${AFTER#\#}"

# Priority band (HERD-630, Phase 1 of HERD-625) — an OPTIONAL non-negative integer; the drain serves
# the LOWEST band first and stays FIFO by INTENT_ID within a band. Rides its own SIDECAR
# ($INTENT_ID.prio) exactly as .ref and .after do, for exactly the same reason: the .req body's
# slug/lane/task parse is POSITIONAL AND FROZEN (docs/spikes/coordinator-work-queue.md §3.2), so an
# intent enqueued by an older engine — or drained by one — must keep working with no sidecar at all.
# Absent (the default) = no sidecar written, no output change, and the intent drains in the default
# band: byte-for-byte a pre-HERD-630 enqueue. A non-numeric value is dropped rather than written, so a
# typo degrades to today's FIFO instead of publishing a priority nobody intended. The band is only
# CONSULTED when INTENT_QUEUE=on — writing one on an unarmed project is inert, which is what makes the
# key safe to arm later against a queue that already carries bands.
PRIO="${HERD_SPAWN_PRIO:-}"
case "$PRIO" in ''|*[!0-9]*) PRIO="" ;; esac

# Enqueue atomically (temp then mv); filename sorts FIFO so oldest is drained first. The tracker ref
# rides in a SIDECAR ($INTENT_ID.ref) rather than the .req body, so the positional slug/lane/task
# parse (spawn-step.sh) is unchanged and an intent enqueued by an OLDER engine (no sidecar) still
# drains correctly (empty ref). Write the sidecar FIRST, then publish the .req, so the ref is present
# the instant the intent becomes claimable.
#
# HERD-443: the ID used to be `date +%s`-$$-$RANDOM. `date +%s` alone ties for any two intents
# enqueued in the SAME second (routine — a coordinator wave fires several spawn.sh calls back to
# back), and $$/$RANDOM have no relationship to call order, so the `sort` in spawn-step.sh's `next`
# could silently invert real enqueue order — the exact bug tests/test-spawn-queue-drain.sh case 2
# caught intermittently (moving-victim macOS CI red, not a timeout). agent-watch.sh's dependency-hold
# drain (_drain_spawn_queue) explicitly relies on "FIFO order is preserved by the INTENT_ID filenames"
# — so this was a real production race, not merely a test assumption. A queue-scoped sequence counter
# makes same-second ordering deterministic regardless of PID allocation or $RANDOM. Serialize the
# read-increment-write with flock(1) when present, else a plain atomic-mkdir spin-wait (stock macOS
# has no flock). No eager "is the lock stale" heuristic: under a 40-way concurrent stress test, a
# `find -mmin` staleness probe on the lock DIR raced with a peer's own hold-and-release cycle often
# enough to `rmdir` a lock that was still legitimately held, letting two callers into the critical
# section at once (proven live: duplicate .seq values). The critical section is one tiny file
# read+write, sub-millisecond, so a bounded spin (no staleness shortcut) clears in practice; the
# give-up-after-N-tries branch is the only recovery path, same tradeoff scribe.sh/research.sh accept.
mkdir -p "$Q"
_spawn_next_seq() {
  local f="$Q/.seq" lockdir="$Q/.seq.lock.d" tries=0 n
  if command -v flock >/dev/null 2>&1; then
    exec 8>"$Q/.seq.lock"
    flock 8
  else
    while ! mkdir "$lockdir" 2>/dev/null; do
      tries=$((tries + 1))
      [ "$tries" -ge 300 ] && break   # ~3s waited; proceed unlocked rather than wedge the enqueue
      sleep 0.01
    done
  fi
  n="$(cat "$f" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  printf '%s' "$n" > "$f"
  if command -v flock >/dev/null 2>&1; then exec 8>&-; else rmdir "$lockdir" 2>/dev/null || true; fi
  printf '%s' "$n"
}
INTENT_ID="$(date +%s)-$(printf '%010d' "$(_spawn_next_seq)")-$$"
[ -n "$ITEM_REF" ] && printf '%s\n' "$ITEM_REF" > "$Q/$INTENT_ID.ref"
[ -n "$AFTER" ] && printf '%s\n' "$AFTER" > "$Q/$INTENT_ID.after"
[ -n "$PRIO" ] && printf '%s\n' "$PRIO" > "$Q/$INTENT_ID.prio"
tmp=$(mktemp "$Q/.tmp.XXXXXX")
printf '%s\n%s\n%s\n' "$SLUG" "$LANE" "$TASK" > "$tmp"
mv "$tmp" "$Q/$INTENT_ID.req"

printf '🚀 queued: %s (%s)%s%s%s\n' "$SLUG" "$LANE" "${ITEM_REF:+  ref: $ITEM_REF}" "${AFTER:+  after: $AFTER}" "${PRIO:+  prio: $PRIO}"
printf 'INTENT_ID %s\n' "$INTENT_ID"
