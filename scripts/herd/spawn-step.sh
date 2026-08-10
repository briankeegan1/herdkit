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
# HERD-630 (Phase 1 of HERD-625, docs/spikes/coordinator-work-queue.md) adds three ops and one
# ordering policy, all behind the INTENT_QUEUE lever (off = today's FIFO, byte-for-byte):
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

# ── Intent-queue policy (HERD-630 · Phase 1 of HERD-625) ─────────────────────────────────────────
# EXTRACTION-SHAPED BY CONSTRUCTION (docs/spikes/coordinator-work-queue.md §3.3): every function in
# this block is PURE over a queue directory (or a bare intent id) passed as an ARGUMENT — none of them
# reads $Q, $TREES or any other global — precisely so Phase 2 can lift the block into
# scripts/herd/intent-queue.sh verbatim and hand it a second tenant without a rewrite. The doc names
# that as a binding constraint on Phase 1, and it is the one thing a later builder cannot retrofit
# cheaply. NOT multi-seat-safe and never claimed to be: two seats each compute their own spawn budget
# from their own FEATS roster, which is Phase 4's job (§5.5), not this slice's.

# The band an intent with NO .prio sidecar drains in. Deliberately mid-range so a coordinator can
# publish work BOTH above and below the unmarked default without restamping the rest of the queue.
INTENT_PRIO_DEFAULT=50

# _intent_queue_on — is the INTENT_QUEUE lever armed? Delegates to herd-config.sh's ONE resolver
# (herd_intent_queue_on) rather than re-deciding truthiness here: a per-surface copy of a rule is what
# docs/multi-seat-doctrine.md Rule 2 calls a correctness defect, and "is the lever on" is exactly the
# rule the drain (agent-watch.sh) and these queue mechanics must never disagree about. Absent resolver
# (a hermetic harness running this script beside a STUB herd-config.sh) reads as OFF — fail toward the
# byte-identical FIFO drain, never toward re-ordering a queue on a missing definition.
_intent_queue_on() {
  command -v herd_intent_queue_on >/dev/null 2>&1 || return 1
  herd_intent_queue_on
}

# _intent_id_of <path-or-id> — the bare INTENT_ID behind any of the queue's file forms.
_intent_id_of() {
  local _iid="${1:-}"
  _iid="${_iid##*/}"
  _iid="${_iid%.req.mine}"; _iid="${_iid%.req}"
  _iid="${_iid%.escalated}"; _iid="${_iid%.cancelled}"
  printf '%s' "$_iid"
}

# _intent_prio <qdir> <intent-id> — this intent's priority BAND: the first line of its .prio sidecar,
# else INTENT_PRIO_DEFAULT. LOWEST DRAINS FIRST. Fail-soft: an absent, empty, negative or non-numeric
# sidecar reads as the default band, so a malformed priority degrades to today's FIFO position rather
# than wedging or re-ordering the queue unpredictably.
_intent_prio() {
  local _ip_q="$1" _ip_id="$2" _ip_p=""
  if [ -f "$_ip_q/$_ip_id.prio" ]; then
    _ip_p="$(sed -n 1p "$_ip_q/$_ip_id.prio" 2>/dev/null | tr -cd '0-9')"   # pipe-ok: one short sidecar line, far under a pipe buffer
  fi
  case "${_ip_p:-}" in ''|*[!0-9]*) _ip_p="$INTENT_PRIO_DEFAULT" ;; esac
  printf '%s' "$_ip_p"
}

# _intent_queue_order <qdir> — the PENDING intents (.req) in DRAIN ORDER, one path per line.
#
#   lever OFF → EXACTLY today's `ls -1 <q>/*.req | sort`: enqueue-ordered FIFO by INTENT_ID, which
#               HERD-443 made deterministic even within one second. Byte-for-byte the pre-HERD-630
#               expression, so an unarmed project's drain order cannot have moved.
#   lever ON  → lowest priority band first, and FIFO by INTENT_ID *within* a band. A queue where NO
#               intent carries a .prio is therefore STILL exactly today's FIFO (every intent lands in
#               the same default band) — the lever alone changes nothing; only a published priority
#               does. That is what makes assert (7) of the doc's §7 plan non-vacuous: force every
#               priority equal and the ordering assertion must go red.
_intent_queue_order() {
  local _iqo_q="$1"
  if ! _intent_queue_on; then
    ls -1 "$_iqo_q"/*.req 2>/dev/null | sort || true
    return 0
  fi
  local _iqo_f _iqo_id
  for _iqo_f in "$_iqo_q"/*.req; do
    [ -e "$_iqo_f" ] || continue
    _iqo_id="$(_intent_id_of "$_iqo_f")"
    printf '%s\t%s\t%s\n' "$(_intent_prio "$_iqo_q" "$_iqo_id")" "$_iqo_id" "$_iqo_f"
  done | sort -t"$(printf '\t')" -k1,1n -k2,2 | cut -f3-
  return 0
}

# _intent_enqueue_epoch <intent-id> — the wall-clock second the intent was ENQUEUED, read from the
# INTENT_ID's own leading field (spawn.sh mints "<epoch>-<0-padded seq>-<pid>"). This — not the file
# mtime — is the ONLY honest staleness clock here: `next` and `release` deliberately TOUCH the file on
# every claim handoff (the HERD-116 anti-spin fix), so an mtime measures time-since-last-claim, and a
# dependency-held intent re-claimed every tick would look eternally fresh. Prints nothing for an id
# whose shape does not parse (an older engine, a hand-made file) — the caller then never expires it.
_intent_enqueue_epoch() {
  local _iee_e="${1:-}"; _iee_e="${_iee_e%%-*}"
  case "$_iee_e" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$_iee_e"
}

# _intent_expired <intent-id> <ttl-seconds> [<now-epoch>] — 0 when the intent has sat undrained longer
# than <ttl>. FAIL-SOFT IN THE SAFE DIRECTION: a zero/absent/non-numeric TTL, an unparseable id, an
# unreadable clock or a clock that ran backwards all read as NOT expired, so the intent launches
# exactly as it does today. Escalating is the loud path; never reach it on a parse accident.
_intent_expired() {
  local _iex_id="${1:-}" _iex_ttl="${2:-0}" _iex_now="${3:-}" _iex_e _iex_age
  case "$_iex_ttl" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_iex_ttl" -gt 0 ] || return 1
  [ -n "$_iex_now" ] || _iex_now="$(date +%s 2>/dev/null || true)"
  case "$_iex_now" in ''|*[!0-9]*) return 1 ;; esac
  _iex_e="$(_intent_enqueue_epoch "$_iex_id")"; [ -n "$_iex_e" ] || return 1
  _iex_age=$(( _iex_now - _iex_e ))
  [ "$_iex_age" -ge 0 ] || return 1
  [ "$_iex_age" -gt "$_iex_ttl" ]
}

# _intent_journal <event> [k v]... — journal a terminal intent transition, LAZILY sourcing journal.sh
# only when one actually fires. Never sourced on the next/own/done/release/skip path, so those stay
# byte-identical; fail-soft everywhere (a queue mechanic must never die because the journal is absent —
# the hermetic harnesses copy this script beside a stub herd-config.sh and nothing else).
# The `[ -f ]` test is LOAD-BEARING, not belt-and-braces: bash treats `.` as a SPECIAL BUILTIN, so
# sourcing a path that does not exist KILLS the shell outright — `|| true` does not catch it, and
# neither does `2>/dev/null`. Without the test, running this script anywhere journal.sh is not beside
# it (a hermetic harness, a partially-copied engine) would turn `cancel`/`escalate` into a silent
# whole-process death mid-queue-transition.
_intent_journal() {
  if ! command -v journal_append >/dev/null 2>&1; then
    [ -f "$HERE/journal.sh" ] || return 0
    # shellcheck source=/dev/null
    . "$HERE/journal.sh" 2>/dev/null || return 0
  fi
  command -v journal_append >/dev/null 2>&1 || return 0
  journal_append "$@" 2>/dev/null || true
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
    # Atomic claim: walk the queue in DRAIN ORDER and try to win each candidate via an atomic
    # rename. If mv fails another process already claimed that file — or `cancel` (HERD-630) renamed
    # it out from under us — skip to the next candidate.
    #
    # HERD-630: the order comes from _intent_queue_order, whose lever-off branch IS the
    # `ls -1 "$Q"/*.req | sort` this line used to inline. One expression, one place, so the priority
    # policy and the FIFO fallback can never disagree about what "next" means.
    claimed=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if mv "$f" "$f.mine" 2>/dev/null; then
        claimed="$f.mine"; break
      fi
    done < <(_intent_queue_order "$Q")
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
    # intent + its sidecars: ref (HERD-64), after-dependency (HERD-94), owner (HERD-237), priority
    # band (HERD-630)
    rm -f "$mine" "${mine%.req.mine}.ref" "${mine%.req.mine}.after" "${mine%.req.mine}.owner" \
      "${mine%.req.mine}.prio" 2>/dev/null || true
    ;;
  release)
    mine="${2:?usage: spawn-step.sh release <claimed-path>}"
    _spawn_require_claim "$mine" release
    # Put the intent back for a later tick; KEEP its sidecars (.ref, .after, and HERD-630's .prio) so
    # the re-queued intent stays tracked, keeps its dependency hold (HERD-94) — a dependency-held
    # intent is released to .req every tick until its dep merges, and must not lose its after= on the
    # round-trip — and keeps its place in the priority order. The owner sidecar does NOT survive: the
    # intent is back in the queue, owned by nobody.
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
    # drop the bad intent + its sidecars: ref (HERD-64), after-dependency (HERD-94), owner (HERD-237),
    # priority band (HERD-630)
    rm -f "$mine" "${mine%.req.mine}.ref" "${mine%.req.mine}.after" "${mine%.req.mine}.owner" \
      "${mine%.req.mine}.prio" 2>/dev/null || true
    ;;
  cancel)
    # HERD-630 §4.4 LEVEL 1 — countermand an intent that has NOT been claimed yet. The rename is the
    # whole safety argument: it races the drain's own claim rename on the SAME path, so exactly one of
    # the two wins. If `next` won, this `mv` fails and we exit 3 LOUDLY (never a silent no-op — the
    # operator must learn the builder is already launching, which is §4.4 level 2's job to countermand,
    # not this op's). If we won, `next` simply never sees the file and moves to the next candidate:
    # no double-launch, and no phantom .req left behind either way.
    id="$(_intent_id_of "${2:?usage: spawn-step.sh cancel <intent-id>}")"
    if mv "$Q/$id.req" "$Q/$id.cancelled" 2>/dev/null; then
      # Terminal: the sidecars have no further reader. The .cancelled file itself carries the slug/lane/
      # task as evidence until the watcher's retention sweep GCs it.
      rm -f "$Q/$id.ref" "$Q/$id.after" "$Q/$id.prio" "$Q/$id.owner" 2>/dev/null || true
      _intent_journal spawn_intent_cancelled intent "$id" component spawn-queue
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
    _intent_expired "$(_intent_id_of "$mine")" "$ttl" && exit 0
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
    _spawn_require_claim "$mine" escalate
    if ! mv -f "$mine" "${mine%.req.mine}.escalated" 2>/dev/null; then
      printf 'spawn-step: WARNING — escalate: could not retire claim %s\n' "$(basename "${mine%.req.mine}")" >&2
      exit 3
    fi
    # The owner sidecar names a worker that will never run this intent; .ref/.after/.prio stay as the
    # escalated record's evidence and are GC'd with it when the row retires.
    rm -f "${mine%.req.mine}.owner" 2>/dev/null || true
    _intent_journal spawn_intent_escalated intent "$(basename "${mine%.req.mine}")" reason "$reason" component spawn-queue
    printf 'spawn-step: WARNING — escalating intent %s: %s\n' "$(basename "${mine%.req.mine}")" "$reason" >&2
    ;;
  *) printf 'usage: spawn-step.sh next | own <path> <pid> | done <path> | release <path> | skip <path> <reason> | cancel <intent-id> | expired <path> <ttl> | escalate <path> <reason>\n' >&2; exit 2 ;;
esac
