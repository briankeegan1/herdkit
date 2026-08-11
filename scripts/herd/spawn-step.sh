#!/usr/bin/env bash
# spawn-step.sh — the SPAWN QUEUE's tenant CLI over the shared intent-queue library
# (scripts/herd/intent-queue.sh). Called from the watcher's _drain_spawn_queue (agent-watch.sh), NOT
# by a Claude drainer — the drain is purely mechanical.
#
# HERD-639 (Phase 2 of HERD-625, docs/spikes/coordinator-work-queue.md §6) moved the mechanics this
# file used to own — the abandoned-claim reclaim, the atomic claim, own/done/skip/cancel/escalate, the
# priority ordering, the enqueue-epoch TTL predicate and the owner-liveness rule — into that library,
# and this file became its FIRST TENANT: it now supplies only what is spawn-specific (the queue dir,
# the positional payload format, the operator-facing messages and the spawn journal event names).
# Behavior is byte-identical to Phase 1 — tests/test-spawn-queue-drain.sh passes UNMODIFIED against it,
# which is the proof, and tests/test-intent-queue-lib.sh covers the library itself.
#
# Subcommands:
#   next              Reclaim abandoned claims; atomically claim the next pending intent in DRAIN
#                     ORDER; print:
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
#   own <path> <pid>  Record <pid> as the LIVE OWNER of a claim, so the abandoned-claim reclaim in
#                     `next` can tell "a lane is still running this intent" from "a dead watcher
#                     abandoned it". Writes the $INTENT_ID.owner sidecar (pid + process start-time).
#   done <path>       Remove the claimed intent file (intent was successfully launched) + its sidecars.
#   release <path>    Put a claimed intent BACK in the queue (.req.mine → .req) unconsumed — used
#                     when the lane's advisory saturation gate deferred the spawn (held, not
#                     failed): the intent must survive for a later tick, not be consumed. This is
#                     what makes the queue's durability guarantee hold under a saturated gate.
#   skip <path> <why> Warn to stderr and remove the claimed file (malformed or bad intent).
#                     The watcher loop continues; the watcher never crashes on a bad intent.
#
# HERD-630 (Phase 1 of HERD-625) added three ops and one ordering policy, all behind the INTENT_QUEUE
# lever (off = today's FIFO, byte-for-byte):
#   cancel <id>       §4.4 level 1 — COUNTERMAND a still-unclaimed intent: rename <id>.req →
#                     <id>.cancelled (terminal) and journal it. Atomic, so it races `next` safely —
#                     whichever rename wins decides, and the loser exits 3.
#   expired <p> <ttl> PREDICATE (no mutation): exit 0 when the intent aged past <ttl> seconds since
#                     ENQUEUE, else 1. Staleness is measured from the INTENT_ID's own epoch field, not
#                     from an mtime that `next`/`release` deliberately touch on every claim handoff.
#   escalate <p> <w>  §4.3 — TERMINAL: rename the claim <id>.req.mine → <id>.escalated so no later
#                     `next` can ever serve it again. The caller (the drain) owns the console row.
#
# done / release / skip / escalate EXIT NON-ZERO (3) when the claim they were handed no longer exists. Silently
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

# ── The shared queue library (HERD-639) ──────────────────────────────────────────────────────────
# Tenant knobs first, so the library adopts them: warnings keep the "spawn-step:" prefix Phase 1
# emitted, and iq_journal looks for journal.sh in THIS script's engine dir (never the library's), so a
# hermetic harness that copies this script beside a stub herd-config.sh still journals nothing.
IQ_LOG_PREFIX="spawn-step"
IQ_ENGINE_DIR="$HERE"
_IQ_LIB="${HERD_INTENT_QUEUE_LIB:-$HERE/intent-queue.sh}"
if [ ! -f "$_IQ_LIB" ]; then
  # This script COPIED OUT of its engine tree — which is exactly what the hermetic harnesses do
  # (tests/test-spawn-queue-drain.sh and tests/test-spawn-queue-priority.sh each `cp` it alone into a
  # temp dir beside a STUB herd-config.sh, so there is no sibling library there). Walk up from the
  # script and from the working directory for an engine tree's copy, so the code under test is still
  # the ONE shipped implementation rather than a second one kept in this file. Never reached by an
  # installed engine (the sibling always exists), and every leg is [ -f ]-guarded.
  for _iq_from in "$HERE" "$PWD"; do
    _iq_d="$_iq_from"
    while [ -n "$_iq_d" ] && [ "$_iq_d" != "/" ]; do
      if [ -f "$_iq_d/scripts/herd/intent-queue.sh" ]; then _IQ_LIB="$_iq_d/scripts/herd/intent-queue.sh"; break 2; fi
      _iq_d="$(dirname "$_iq_d")"
    done
  done
fi
# The `[ -f ]` test is LOAD-BEARING (HERD-632): bash treats `.` as a SPECIAL BUILTIN, so sourcing a
# path that does not exist KILLS the shell outright — neither `|| true` nor `2>/dev/null` catches it.
# shellcheck source=/dev/null
[ -f "$_IQ_LIB" ] && . "$_IQ_LIB"

case "$cmd" in
  next)
    # One atomic claim in drain order (iq_claim: reclaim abandoned claims, GC orphaned owner sidecars,
    # then win the top candidate by rename). Under INTENT_QUEUE=off that order IS the pre-HERD-630
    # `ls -1 "$Q"/*.req | sort` FIFO; under =on it is lowest priority band first, FIFO within a band.
    claimed="$(iq_claim "$Q" || true)"
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
  own)
    # Bind a claim to the live process that is working it (HERD-237). Called by the drain's background
    # lane worker as its FIRST act, with its own pid: from here until the worker consumes or releases
    # the claim, `next` will not reclaim it however long the lane takes. The window between the claim
    # (which touches the file, restarting its 5-minute clock) and this call is microseconds wide, and a
    # watcher that dies inside it simply leaves an unowned claim that ages out normally.
    mine="${2:?usage: spawn-step.sh own <claimed-path> <pid>}"
    pid="${3:?usage: spawn-step.sh own <claimed-path> <pid>}"
    iq_require_claim "$mine" own || exit 3
    iq_own "$mine" "$pid"
    ;;
  done)
    mine="${2:?usage: spawn-step.sh done <claimed-path>}"
    iq_require_claim "$mine" done || exit 3
    # intent + its sidecars: ref (HERD-64), after-dependency (HERD-94), owner (HERD-237), priority
    # band (HERD-630)
    iq_done "$mine"
    ;;
  release)
    mine="${2:?usage: spawn-step.sh release <claimed-path>}"
    iq_require_claim "$mine" release || exit 3
    # Put the intent back for a later tick; KEEP its sidecars (.ref, .after, and HERD-630's .prio) so
    # the re-queued intent stays tracked, keeps its dependency hold (HERD-94) — a dependency-held
    # intent is released to .req every tick until its dep merges, and must not lose its after= on the
    # round-trip — and keeps its place in the priority order. The owner sidecar does NOT survive: the
    # intent is back in the queue, owned by nobody.
    #
    # THIS IS THE ONE OP THAT STAYS INLINE (HERD-639). iq_release (intent-queue.sh) is the same three
    # statements and is what every other tenant calls, but tests/test-spawn-queue-drain.sh case 9
    # asserts the touch-BEFORE-rename order by inspecting THIS case body's source, and that test is
    # frozen by the Phase 2 item as the byte-identical proof. tests/test-intent-queue-lib.sh asserts
    # the same order inside iq_release AND asserts the two bodies still agree, so the mirror cannot
    # drift silently.
    #
    # Restart the stale clock BEFORE the rename, not after (HERD-237). `release` used to `mv` and then
    # `touch "$released"`. Pre-HERD-237 that pair only ever ran in the drain's foreground, serialized
    # against `next`; it now runs in the background lane worker while the parent tick's `next` walks the
    # queue. If `next` re-claims the just-released intent in the gap, the trailing `touch` CREATES an
    # empty `<id>.req` beside the live `<id>.req.mine` — a phantom intent. Touching the claim first and
    # letting `mv` carry the fresh mtime across makes the release a single atomic rename with no window.
    # (The clock still restarts: a just-released intent must not be instantly reclaimable as "stale", or
    # the enqueue age leaks back in and revives the HERD-116 spin.)
    released="${mine%.mine}"
    rm -f "${mine%.req.mine}.owner" 2>/dev/null || true
    touch "$mine" 2>/dev/null || true
    mv -f "$mine" "$released" 2>/dev/null || true
    ;;
  skip)
    mine="${2:?usage: spawn-step.sh skip <claimed-path> <reason>}"
    reason="${3:-malformed intent}"
    iq_require_claim "$mine" skip || exit 3
    # warn + drop the bad intent and its sidecars: ref (HERD-64), after-dependency (HERD-94),
    # owner (HERD-237), priority band (HERD-630)
    iq_skip "$mine" "$reason"
    ;;
  cancel)
    # HERD-630 §4.4 LEVEL 1 — countermand an intent that has NOT been claimed yet. The rename inside
    # iq_cancel is the whole safety argument: it races the drain's own claim rename on the SAME path,
    # so exactly one of the two wins. If `next` won, the `mv` fails and we exit 3 LOUDLY (never a
    # silent no-op — the operator must learn the builder is already launching, which is §4.4 level 2's
    # job to countermand, not this op's). If we won, `next` simply never sees the file and moves to the
    # next candidate: no double-launch, and no phantom .req left behind either way.
    id="$(iq_id_of "${2:?usage: spawn-step.sh cancel <intent-id>}")"
    if iq_cancel "$Q" "$id"; then
      iq_journal spawn_intent_cancelled intent "$id" component spawn-queue
      printf 'spawn-step: cancelled pending intent %s\n' "$id"
      exit 0
    fi
    printf 'spawn-step: WARNING — cancel: intent %s is not pending (already claimed, drained, or cancelled).\n' "$id" >&2
    printf '    A CLAIMED intent cannot be un-launched — countermand the BUILDER instead (close the PR, retire the worktree, release the claim).\n' >&2
    exit 3
    ;;
  expired)
    # PREDICATE ONLY — mutates nothing. exit 0 = past its TTL, 1 = still fresh (or unknowable).
    mine="${2:?usage: spawn-step.sh expired <intent-path-or-id> <ttl-seconds>}"
    ttl="${3:?usage: spawn-step.sh expired <intent-path-or-id> <ttl-seconds>}"
    iq_expired "$(iq_id_of "$mine")" "$ttl" && exit 0
    exit 1
    ;;
  escalate)
    # HERD-630 §4.3 — TERMINAL. An intent that aged past INTENT_TTL does NOT launch: a builder started
    # against a plan whose premises are a day old costs a full run plus a bounced PR, and fails
    # SILENTLY, which is the class this whole design exists to remove. Renaming the claim to
    # <id>.escalated takes it out of the drain set for good (no glob reaches it again), while keeping
    # the payload on disk as the evidence the caller's needs-you row points at. The CALLER owns the
    # console row, its ack path and its age-to-retired sweep — shipping the escalation without those
    # is the HERD-613 defect, not a safety feature.
    mine="${2:?usage: spawn-step.sh escalate <claimed-path> <reason>}"
    reason="${3:-aged past INTENT_TTL}"
    iq_require_claim "$mine" escalate || exit 3
    if ! iq_escalate "$mine"; then
      printf 'spawn-step: WARNING — escalate: could not retire claim %s\n' "$(basename "${mine%.req.mine}")" >&2
      exit 3
    fi
    iq_journal spawn_intent_escalated intent "$(basename "${mine%.req.mine}")" reason "$reason" component spawn-queue
    printf 'spawn-step: WARNING — escalating intent %s: %s\n' "$(basename "${mine%.req.mine}")" "$reason" >&2
    ;;
  *) printf 'usage: spawn-step.sh next | own <path> <pid> | done <path> | release <path> | skip <path> <reason> | cancel <intent-id> | expired <path> <ttl> | escalate <path> <reason>\n' >&2; exit 2 ;;
esac
