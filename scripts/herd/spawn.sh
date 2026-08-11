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
#   HERD_SPAWN_GEN=<id> spawn.sh <slug> feature "<task>"           # part of published plan <id> (HERD-642;
#                                                                  #   set by `herd queue plan`, not by hand)
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

# Generation stamp (HERD-642, Phase 5 of HERD-625; doc §4.4) — an OPTIONAL opaque id shared by every
# intent that ONE `herd queue plan` publishes, recorded in its own SIDECAR ($INTENT_ID.gen) for the same
# reason .ref/.after/.prio are: the .req body's positional parse is frozen. A stamped intent is
# claimable only while the queue's `.gen` pointer still names its generation, so `herd queue plan`
# publishes the whole new plan here FIRST (stamped, therefore not yet live) and then flips the pointer
# in one rename — the atomic supersede.
#
# Set only by that command; empty on every ordinary enqueue (the default), in which case NO sidecar is
# written, the intent belongs to no generation, no publish can ever retire it, and this enqueue is
# byte-for-byte a pre-HERD-642 one. A value carrying anything other than plain id characters is dropped
# rather than written — a typo must degrade to an unstamped (always-live) intent, never to a stamp that
# silently makes the intent unclaimable.
GEN="${HERD_SPAWN_GEN:-}"
case "$GEN" in *[!0-9A-Za-z._-]*) GEN="" ;; esac

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
# HERD-639 (Phase 2 of HERD-625): the id minting, the queue-scoped sequence lock and the atomic
# publish all live in the SHARED intent-queue library now — one implementation for every tenant of the
# pool, rather than a per-queue copy whose ordering rules drift (docs/spikes/coordinator-work-queue.md
# §3.2). The `[ -f ]` test is LOAD-BEARING (HERD-632): bash treats `.` as a SPECIAL BUILTIN, so
# sourcing an absent path kills the shell outright, which `|| true` does not catch. The library is a
# HARD dependency of an enqueue (like journal.sh above); the guard turns a broken engine tree into a
# clean unbound-function error instead of a silent whole-process death.
IQ_LOG_PREFIX="spawn.sh"
IQ_ENGINE_DIR="$HERE"
# shellcheck source=/dev/null
[ -f "$HERE/intent-queue.sh" ] && . "$HERE/intent-queue.sh"
INTENT_ID="$(iq_mint_id "$Q")"
[ -n "$ITEM_REF" ] && printf '%s\n' "$ITEM_REF" > "$Q/$INTENT_ID.ref"
[ -n "$AFTER" ] && printf '%s\n' "$AFTER" > "$Q/$INTENT_ID.after"
[ -n "$PRIO" ] && printf '%s\n' "$PRIO" > "$Q/$INTENT_ID.prio"
[ -n "$GEN" ] && printf '%s\n' "$GEN" > "$Q/$INTENT_ID.gen"
# Sidecars FIRST, then the atomic publish (temp + one rename), so every sidecar is present the instant
# the intent becomes claimable.
iq_publish "$Q" "$INTENT_ID" "$SLUG
$LANE
$TASK"

# M3 · QUEUE-MARKER PUBLISH (HERD-639, doc §1.3 / §2.2) — the intent queue's SECOND tenant. Enqueuing
# a tracked spawn is precisely the moment a 📌 planned marker should appear on the item, and today
# nothing publishes one unless an operator hand-runs `herd backlog queue`. Rides the same rails as the
# spawn intent above (mint → publish → the watcher's drain → the backend op → journal), through the
# same library, into a SIBLING queue dir so it can never consume a builder slot or queue behind one.
# Ship-dormant: no new config key — Phase 1's INTENT_QUEUE lever governs, and with it off (the ship
# default) this block is a hard no-op and the enqueue is byte-for-byte the pre-HERD-639 one. Fail-soft:
# an unwritable pool is never an enqueue failure — the spawn is what matters, the marker is advisory.
if [ -n "$ITEM_REF" ] && command -v herd_intent_queue_on >/dev/null 2>&1 && herd_intent_queue_on; then
  iq_enqueue "$TREES/intent-queue" "marker-publish
$ITEM_REF
${WATCHER_OWNER:-}
sequenced next (spawn intent $INTENT_ID)" >/dev/null 2>&1 || true
fi

printf '🚀 queued: %s (%s)%s%s%s%s\n' "$SLUG" "$LANE" "${ITEM_REF:+  ref: $ITEM_REF}" "${AFTER:+  after: $AFTER}" "${PRIO:+  prio: $PRIO}" "${GEN:+  gen: $GEN}"
printf 'INTENT_ID %s\n' "$INTENT_ID"
