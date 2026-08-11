#!/usr/bin/env bash
# intent-queue.sh — THE shared intent-queue library (HERD-639, Phase 2 of HERD-625; design doc
# docs/spikes/coordinator-work-queue.md §3.2 Option B + §6 Phase 2).
#
# ONE implementation of the pool-queue mechanics every intent tenant needs — claim / own / release /
# skip / done / cancel / escalate, plus the priority ordering, the enqueue-epoch TTL predicate and the
# owner-liveness rule those ops are built on. Phase 1 (HERD-630) wrote its policy block
# "extraction-shaped by construction": PURE over a queue directory passed as an ARGUMENT, reading no
# `$Q`, no `$TREES`, no tenant global. This file is that extraction, plus the claim mechanics the same
# argument shape makes portable, and it is what turns the doc's §3.2 warning into structure rather than
# discipline — the pool already carries three near-identical `next` implementations (spawn / scribe /
# research) whose reclaim, linger and ordering behavior have DRIFTED, which docs/multi-seat-doctrine.md
# Rule 2 calls a correctness defect, not a style one.
#
# SOURCED, never executed: every entry point is a function over an explicit queue dir or claim path.
# The two tenants that ride it today:
#   • tenant #1 — the SPAWN queue ($WORKTREES_DIR/spawn-queue/), through spawn-step.sh (the frozen
#     operator/drain CLI) and spawn.sh (enqueue). Byte-identical to Phase 1; tests/test-spawn-queue-drain.sh
#     passes UNMODIFIED against it, which is the proof.
#   • tenant #2 — the M3 QUEUE-MARKER queue ($WORKTREES_DIR/intent-queue/), through agent-watch.sh's
#     _drain_intent_queue → _backend_queue_item / _backend_unqueue_item. Deliberately the smallest real
#     non-spawn intent (doc §2.2 / §6): it exists to prove a non-spawn intent rides these rails end to
#     end before anything load-bearing does.
#
# MULTI-SEAT SAFETY, and where it lives. The at-most-one-CLAIM guarantee below IS cross-seat safe on
# its own (it is one atomic rename). The at-most-one-ADMISSION guarantee is NOT this library's — it was
# the doc's §5.5 open question, and Phase 4 (HERD-641) closed it one level up, in the spawn drain's own
# admission: agent-watch.sh:_drain_spawn_queue leases a MACHINE-WIDE unit of the HERD-581 `agent`
# capacity tenant before dispatching a lane, instead of sizing a budget from its own roster. Deliberately
# NOT pushed down here: only the spawn tenant consumes a builder slot, so only it has an admission to
# bound — a marker intent leases nothing and needs nothing.
#
# GENERATIONS + THE PLAN SURFACE (HERD-642, Phase 5). The queue also owns the coordinator's PUBLISHED
# PLAN: iq_gen_* stamp / swap / retire a whole priority-ordered generation of spawn intents through one
# atomic pointer rename (doc §4.4 "supersede over delete"), and iq_plan_rows is the ONE reader both
# `herd queue list` and the watcher's "planned work" console section render, so a second seat READS the
# plan instead of re-deriving it. Both are inert on a queue no plan was ever published into.
#
# NO NEW CONFIG KEY. Phase 1's single operator lever (INTENT_QUEUE, herd-config.sh) governs every
# behavior here that is not plain FIFO, exactly as it did before the extraction.
#
# Tenant knobs — set BEFORE sourcing (each has a safe default, so a tenant may set none):
#   IQ_LOG_PREFIX     the name warnings are prefixed with (spawn-step.sh sets "spawn-step" so its
#                     stderr stays byte-identical to Phase 1's).
#   IQ_ENGINE_DIR     where iq_journal looks for journal.sh. Defaults to THIS file's directory, which
#                     is right for a normal engine; a tenant whose own engine dir may differ (a script
#                     copied into a hermetic harness) sets it explicitly so a harness never reaches a
#                     real project's journal.
#   IQ_SIDECARS       the sidecar suffixes a claim owns, GC'd together with it by done/skip/cancel.
#                     (Includes `gen` — HERD-642's generation stamp — so a consumed intent never leaves
#                     a stamp behind for a later id to collide with.)
#   IQ_PRIO_DEFAULT   the band an intent with no .prio sidecar drains in.
#   IQ_RECLAIM_MMIN   the abandoned-claim age threshold, in minutes.

# The band an intent with NO .prio sidecar drains in. Deliberately mid-range so a coordinator can
# publish work BOTH above and below the unmarked default without restamping the rest of the queue.
IQ_PRIO_DEFAULT="${IQ_PRIO_DEFAULT:-50}"

# The sidecar suffixes an intent owns. A tenant that writes none of them is unaffected — every op
# below `rm -f`s them, which is a no-op on a suffix that queue never uses.
#   ref      HERD-64  tracker ref threaded to the lane
#   after    HERD-94  dependency hold
#   owner    HERD-237 the live pid working this claim
#   prio     HERD-630 priority band
#   attempts HERD-639 transient-failure counter (doc §4.3), used by the M3 tenant
#   gen      HERD-642 the published GENERATION this intent belongs to (doc §4.4 supersede-over-delete)
IQ_SIDECARS="${IQ_SIDECARS:-ref after owner prio attempts gen}"

# Abandoned-claim threshold in MINUTES. Staleness is the CLAIM age, not the enqueue age: iq_claim and
# iq_release deliberately touch the file whenever it changes hands (see below), so this measures
# time-since-last-claim.
IQ_RECLAIM_MMIN="${IQ_RECLAIM_MMIN:-5}"

# The prefix on this library's operator-facing warnings.
IQ_LOG_PREFIX="${IQ_LOG_PREFIX:-intent-queue}"

# Where iq_journal looks for journal.sh. `${BASH_SOURCE[0]}` resolves to THIS file even when the
# library is sourced from a directory other than the caller's.
IQ_ENGINE_DIR="${IQ_ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ── Policy: lever, identity, priority, staleness ─────────────────────────────────────────────────

# iq_lever_on — is the INTENT_QUEUE lever armed? Delegates to herd-config.sh's ONE resolver
# (herd_intent_queue_on) rather than re-deciding truthiness here: a per-surface copy of a rule is what
# docs/multi-seat-doctrine.md Rule 2 calls a correctness defect, and "is the lever on" is exactly the
# rule the drain, the queue mechanics and every tenant must never disagree about. Absent resolver (a
# hermetic harness running a tenant beside a STUB herd-config.sh) reads as OFF — fail toward the
# byte-identical FIFO drain, never toward re-ordering a queue on a missing definition.
iq_lever_on() {
  command -v herd_intent_queue_on >/dev/null 2>&1 || return 1
  herd_intent_queue_on
}

# iq_id_of <path-or-id> — the bare INTENT_ID behind any of the queue's file forms.
iq_id_of() {
  local _iqi="${1:-}"
  _iqi="${_iqi##*/}"
  _iqi="${_iqi%.req.mine}"; _iqi="${_iqi%.req}"
  _iqi="${_iqi%.escalated}"; _iqi="${_iqi%.cancelled}"
  printf '%s' "$_iqi"
}

# iq_prio <qdir> <intent-id> — this intent's priority BAND: the first line of its .prio sidecar, else
# IQ_PRIO_DEFAULT. LOWEST DRAINS FIRST. Fail-soft: an absent, empty, negative or non-numeric sidecar
# reads as the default band, so a malformed priority degrades to today's FIFO position rather than
# wedging or re-ordering the queue unpredictably.
iq_prio() {
  local _iqp_q="$1" _iqp_id="$2" _iqp_p=""
  if [ -f "$_iqp_q/$_iqp_id.prio" ]; then
    _iqp_p="$(sed -n 1p "$_iqp_q/$_iqp_id.prio" 2>/dev/null | tr -cd '0-9')"   # pipe-ok: one short sidecar line, far under a pipe buffer
  fi
  case "${_iqp_p:-}" in ''|*[!0-9]*) _iqp_p="$IQ_PRIO_DEFAULT" ;; esac
  printf '%s' "$_iqp_p"
}

# ── Generations: the coordinator's PUBLISHED PLAN, superseded atomically (HERD-642, doc §4.4) ─────
#
# "Supersede over delete." A coordinator changing its mind must not have to delete N intents one at a
# time — "did I get all of them?" is the failure mode the design doc names. So every intent published
# by ONE `herd queue plan` call carries the SAME opaque GENERATION id in a `.gen` sidecar, and a single
# pointer file — `<qdir>/.gen` — names the generation that is LIVE. An intent is in the drain set only
# when its stamp matches that pointer, which makes replacing the pointer the WHOLE supersede: one
# atomic rename retires the previous generation and admits the new one in the same instant. There is no
# moment when both generations are claimable, and none where neither is — which is why the new
# generation's intents are published (stamped, un-live) BEFORE the swap rather than after it.
#
# UNSTAMPED INTENTS ARE ALWAYS LIVE, and that is what keeps this byte-identical on a queue nobody ever
# published a plan into: an intent with no `.gen` sidecar — every ad-hoc `spawn.sh` enqueue, and every
# intent written by an engine older than this one — belongs to no generation, so no publish can retire
# it and no missing pointer can hide it (tests/test-spawn-queue-drain.sh passes UNMODIFIED).
#
# NO NEW CONFIG KEY: like the priority band, a generation stamp is only CONSULTED under the INTENT_QUEUE
# lever (iq_order's lever-on branch), so publishing a plan on an unarmed project is inert.

# iq_gen_pointer <qdir> — the LIVE-generation pointer path. A dotfile on purpose: the queue's own
# `*.req` globs must never see it.
iq_gen_pointer() { printf '%s/.gen' "${1:-}"; }

# iq_generation <qdir> — the generation id currently LIVE here, empty when no plan was ever published.
# Fail-soft: an absent, empty or unreadable pointer reads as "no generation", under which every STAMPED
# intent is superseded and every unstamped one drains exactly as today.
iq_generation() {
  local _iqgn=""
  _iqgn="$(sed -n 1p "$(iq_gen_pointer "${1:-}")" 2>/dev/null | tr -cd '0-9A-Za-z._-')"   # pipe-ok: one short pointer line, far under a pipe buffer
  printf '%s' "$_iqgn"
}

# iq_gen_of <qdir> <intent-id> — the generation THIS intent was published under; empty when unstamped.
# The empty-id guard is not defensive noise: `<qdir>/<empty>.gen` IS the pointer path, so without it a
# caller that lost an id would read the LIVE generation back as that phantom intent's own stamp and
# conclude it is current.
iq_gen_of() {
  local _iqgo=""
  [ -n "${2:-}" ] || return 0
  _iqgo="$(sed -n 1p "${1:-}/${2}.gen" 2>/dev/null | tr -cd '0-9A-Za-z._-')"              # pipe-ok: one short sidecar line
  printf '%s' "$_iqgo"
}

# iq_gen_superseded <qdir> <intent-id> — 0 when this intent belongs to a RETIRED generation and must
# therefore never be served again. THE one place that rule lives: iq_order, iq_gen_retire and the plan
# readers all ask this function rather than comparing stamps themselves, because a per-surface copy of
# "is this candidate still live" is exactly what docs/multi-seat-doctrine.md Rule 2 calls a correctness
# defect. Unstamped intent, no live pointer, or a stamp equal to the pointer ⇒ NOT superseded.
iq_gen_superseded() {
  local _iqgs_stamp; _iqgs_stamp="$(iq_gen_of "${1:-}" "${2:-}")"
  [ -n "$_iqgs_stamp" ] || return 1
  [ "$_iqgs_stamp" != "$(iq_generation "${1:-}")" ]
}

# iq_order <qdir> — the PENDING intents (.req) in DRAIN ORDER, one path per line.
#
#   lever OFF → EXACTLY the pre-HERD-630 `ls -1 <q>/*.req | sort`: enqueue-ordered FIFO by INTENT_ID,
#               which HERD-443 made deterministic even within one second.
#   lever ON  → lowest priority band first, and FIFO by INTENT_ID *within* a band, MINUS the intents of
#               any superseded generation (HERD-642 — a retired plan is not in the drain set at all). A
#               queue where NO intent carries a .prio or a .gen is therefore STILL exactly that FIFO
#               (every intent lands in the same default band and belongs to no generation) — the lever
#               alone changes nothing; only a published priority or plan does.
iq_order() {
  local _iqo_q="$1"
  if ! iq_lever_on; then
    ls -1 "$_iqo_q"/*.req 2>/dev/null | sort || true
    return 0
  fi
  local _iqo_f _iqo_id
  for _iqo_f in "$_iqo_q"/*.req; do
    [ -e "$_iqo_f" ] || continue
    _iqo_id="$(iq_id_of "$_iqo_f")"
    # HERD-642: an intent stamped with a generation the pointer no longer names was countermanded by a
    # later `herd queue plan`. Dropping it HERE — in the one function every claim walks — is what makes
    # the pointer swap a complete supersede: no drain can serve a retired plan even for one tick, and
    # the physical cleanup (iq_gen_retire) is then pure housekeeping rather than a correctness step.
    iq_gen_superseded "$_iqo_q" "$_iqo_id" && continue
    printf '%s\t%s\t%s\n' "$(iq_prio "$_iqo_q" "$_iqo_id")" "$_iqo_id" "$_iqo_f"
  done | sort -t"$(printf '\t')" -k1,1n -k2,2 | cut -f3-
  return 0
}

# iq_enqueue_epoch <intent-id> — the wall-clock second the intent was ENQUEUED, read from the
# INTENT_ID's own leading field (iq_mint_id mints "<epoch>-<0-padded seq>-<pid>"). This — not the file
# mtime — is the ONLY honest staleness clock here: iq_claim and iq_release deliberately TOUCH the file
# on every claim handoff (the HERD-116 anti-spin fix), so an mtime measures time-since-last-claim, and
# a dependency-held intent re-claimed every tick would look eternally fresh. Prints nothing for an id
# whose shape does not parse (an older engine, a hand-made file) — the caller then never expires it.
iq_enqueue_epoch() {
  local _iqe="${1:-}"; _iqe="${_iqe%%-*}"
  case "$_iqe" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$_iqe"
}

# iq_expired <intent-id> <ttl-seconds> [<now-epoch>] — 0 when the intent has sat undrained longer than
# <ttl>. FAIL-SOFT IN THE SAFE DIRECTION: a zero/absent/non-numeric TTL, an unparseable id, an
# unreadable clock or a clock that ran backwards all read as NOT expired, so the intent drains exactly
# as it does today. Escalating is the loud path; never reach it on a parse accident.
iq_expired() {
  local _iqx_id="${1:-}" _iqx_ttl="${2:-0}" _iqx_now="${3:-}" _iqx_e _iqx_age
  case "$_iqx_ttl" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_iqx_ttl" -gt 0 ] || return 1
  [ -n "$_iqx_now" ] || _iqx_now="$(date +%s 2>/dev/null || true)"
  case "$_iqx_now" in ''|*[!0-9]*) return 1 ;; esac
  _iqx_e="$(iq_enqueue_epoch "$_iqx_id")"; [ -n "$_iqx_e" ] || return 1
  _iqx_age=$(( _iqx_now - _iqx_e ))
  [ "$_iqx_age" -ge 0 ] || return 1
  [ "$_iqx_age" -gt "$_iqx_ttl" ]
}

# iq_journal <event> [k v]... — journal a terminal intent transition, LAZILY sourcing journal.sh only
# when one actually fires. Never sourced on the claim/own/done/release/skip path, so those stay
# byte-identical; fail-soft everywhere (a queue mechanic must never die because the journal is absent —
# the hermetic harnesses copy a tenant beside a stub herd-config.sh and nothing else).
# The `[ -f ]` test is LOAD-BEARING, not belt-and-braces: bash treats `.` as a SPECIAL BUILTIN, so
# sourcing a path that does not exist KILLS the shell outright — `|| true` does not catch it, and
# neither does `2>/dev/null`. Without the test, a tenant running anywhere journal.sh is not beside it
# would turn a queue transition into a silent whole-process death.
iq_journal() {
  if ! command -v journal_append >/dev/null 2>&1; then
    [ -f "$IQ_ENGINE_DIR/journal.sh" ] || return 0
    # shellcheck source=/dev/null
    . "$IQ_ENGINE_DIR/journal.sh" 2>/dev/null || return 0
  fi
  command -v journal_append >/dev/null 2>&1 || return 0
  journal_append "$@" 2>/dev/null || true
}

# ── Owner liveness (HERD-237) ────────────────────────────────────────────────────────────────────

# iq_pid_starttime <pid> — the pid's process start-time, or empty. The recycling guard: a pid reused
# by an unrelated process reports a different start-time. Mirrors agent-watch.sh's _pid_starttime
# EXACTLY, including its HERD_PID_STARTTIME_CMD test seam — the two helpers read and write the same
# .owner sidecar, so a hermetic test that stubs the seam on one side must not see the other shell out
# to a real `ps`.
iq_pid_starttime() {
  local _iqs_p="${1:-}"; [ -n "$_iqs_p" ] || return 0
  if [ -n "${HERD_PID_STARTTIME_CMD:-}" ]; then "$HERD_PID_STARTTIME_CMD" "$_iqs_p" 2>/dev/null; return 0; fi
  ps -o lstart= -p "$_iqs_p" 2>/dev/null | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# iq_owner_alive <owner-sidecar> — true iff the sidecar names a process that is STILL RUNNING and is
# still the same process it named (pid alive AND start-time unchanged). Absent sidecar, malformed pid,
# dead pid or a recycled pid ⇒ false, i.e. the claim is reclaimable. An unreadable CURRENT start-time
# trusts the bare `kill -0` so a transient `ps` hiccup never reclaims a live worker's intent.
iq_owner_alive() {
  local _iqa_f="$1" _iqa_pid _iqa_st _iqa_cur
  [ -f "$_iqa_f" ] || return 1
  _iqa_pid="$(sed -n 1p "$_iqa_f" 2>/dev/null || true)"
  case "$_iqa_pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_iqa_pid" 2>/dev/null || return 1
  _iqa_st="$(sed -n 2p "$_iqa_f" 2>/dev/null || true)"; [ -n "$_iqa_st" ] || return 0
  _iqa_cur="$(iq_pid_starttime "$_iqa_pid")"; [ -n "$_iqa_cur" ] || return 0
  [ "$_iqa_cur" = "$_iqa_st" ]
}

# ── Claim mechanics ──────────────────────────────────────────────────────────────────────────────

# iq_require_claim <claimed-path> <verb> — a claimed path that has vanished is NEVER a silent no-op.
# Returns 1 (the CLI tenant maps that to its exit 3; an in-process tenant such as the watcher's drain
# BRANCHES on it — a library must never `exit` out from under a long-lived caller).
iq_require_claim() {
  [ -f "$1" ] && return 0
  printf '%s: WARNING — %s: claim %s no longer exists (reclaimed or already consumed)\n' \
    "$IQ_LOG_PREFIX" "$2" "$(basename "${1%.req.mine}")" >&2
  return 1
}

# iq_reclaim <qdir> — return ABANDONED claims to the queue and GC orphaned owner sidecars.
#
# HERD-237 — LIVENESS, NOT AGE, IS THE PREDICATE. The blanket age reclaim rested on a premise that no
# longer holds: that a claim can only outlive a tick if its watcher died. A drain now launches its work
# in a BACKGROUND worker that holds the claim for the whole run, and a run that exceeds the threshold
# (a slow clone, a wedged driver call — precisely the fault this design exists to tolerate) is normal.
# Age-reclaiming it re-serves an intent that is being executed right now: the worker's `done` then rm's
# a path that has moved, the intent is never consumed, and the next free tick executes it a SECOND
# time. So an aged claim is reclaimed only when its owner is provably gone: `.owner` names the worker's
# pid + start-time (iq_own), and a live owner keeps its claim indefinitely. A claim with NO owner
# sidecar (a dependency hold, an older engine's intent, a drain killed between claim and own) reclaims
# on age exactly as before.
iq_reclaim() {
  local _iqr_q="$1" _iqr_stale _iqr_owner _iqr_orph
  while IFS= read -r _iqr_stale; do
    [ -n "$_iqr_stale" ] || continue
    _iqr_owner="${_iqr_stale%.req.mine}.owner"
    iq_owner_alive "$_iqr_owner" && continue     # a live worker still owns this intent — hands off
    rm -f "$_iqr_owner" 2>/dev/null || true
    mv -f "$_iqr_stale" "${_iqr_stale%.mine}" 2>/dev/null || true
  done < <(find "$_iqr_q" -name '*.mine' -mmin +"$IQ_RECLAIM_MMIN" 2>/dev/null || true)
  # GC owner sidecars whose claim is gone (a worker that exited between `own` and its own cleanup).
  for _iqr_orph in "$_iqr_q"/*.owner; do
    [ -e "$_iqr_orph" ] || continue
    [ -f "${_iqr_orph%.owner}.req.mine" ] || rm -f "$_iqr_orph" 2>/dev/null || true
  done
  return 0
}

# iq_claim <qdir> — reclaim abandoned claims, then atomically claim the highest-priority pending intent
# and PRINT its claim path (nothing, rc 1, when the queue has no claimable intent).
#
# The claim is one atomic rename (.req → .req.mine), which is the whole at-most-one-claim argument: two
# seats racing the same intent, one `mv` wins and the other's fails, so the loser simply walks on to
# the next candidate. A failed `mv` also covers `cancel` renaming the file out from under us.
#
# The trailing `touch` restarts the abandoned-claim clock on the fresh claim, so a held intent
# (re-claimed every tick while its dependency is unmet) is not instantly reclaimed as "stale" by a
# later claim in the same tick — that resurrect-and-re-serve loop is the HERD-116 watcher freeze.
iq_claim() {
  local _iqc_q="$1" _iqc_f
  iq_reclaim "$_iqc_q"
  while IFS= read -r _iqc_f; do
    [ -n "$_iqc_f" ] || continue
    if mv "$_iqc_f" "$_iqc_f.mine" 2>/dev/null; then
      touch "$_iqc_f.mine" 2>/dev/null || true
      printf '%s' "$_iqc_f.mine"
      return 0
    fi
  done < <(iq_order "$_iqc_q")
  return 1
}

# iq_own <claimed-path> <pid> — record <pid> as the LIVE OWNER of a claim, so iq_reclaim can tell "a
# worker is still running this intent" from "a dead drain abandoned it". Writes the .owner sidecar
# (pid + its process start-time).
iq_own() {
  local _iqw_mine="$1" _iqw_pid="$2"
  { printf '%s\n' "$_iqw_pid"; printf '%s\n' "$(iq_pid_starttime "$_iqw_pid")"; } \
    > "${_iqw_mine%.req.mine}.owner" 2>/dev/null || true
  return 0
}

# iq_sidecars_rm <intent-base-path> — drop every sidecar an intent owns.
iq_sidecars_rm() {
  local _iqk_base="$1" _iqk_s
  for _iqk_s in $IQ_SIDECARS; do
    rm -f "$_iqk_base.$_iqk_s" 2>/dev/null || true
  done
  return 0
}

# iq_done <claimed-path> — CONSUME the intent (it was executed): drop the claim and its sidecars.
iq_done() {
  local _iqd_mine="$1"
  rm -f "$_iqd_mine" 2>/dev/null || true
  iq_sidecars_rm "${_iqd_mine%.req.mine}"
  return 0
}

# iq_release <claimed-path> — put a claimed intent BACK in the queue UNCONSUMED, for a later tick.
# KEEPS its sidecars (.ref, .after, .prio, .attempts) so a re-queued intent stays tracked, keeps its
# dependency hold and its place in the priority order. The owner sidecar does NOT survive: the intent
# is back in the queue, owned by nobody.
#
# The `touch` happens BEFORE the rename, not after (HERD-237). A release used to `mv` and then touch
# the RELEASED path; run from a background worker, that races the parent tick's own claim walk — if the
# claim wins the gap, the trailing touch CREATES an empty `<id>.req` beside the live `<id>.req.mine`, a
# phantom intent. Touching the CLAIM first and letting `mv` carry the fresh mtime across makes the
# release a single atomic rename with no window. (The clock still restarts, so a just-released intent
# is not instantly reclaimable as "stale" — otherwise the enqueue age leaks back in and revives the
# HERD-116 spin.)
#
# tests/test-spawn-queue-drain.sh case 9 asserts that ORDER by source inspection, and it asserts it
# inside spawn-step.sh's own `release)` case — that frozen test is why the spawn tenant keeps those two
# lines inline rather than calling this function. tests/test-intent-queue-lib.sh asserts the same order
# HERE, and asserts the two bodies agree, so the mirror cannot drift silently.
iq_release() {
  local _iqe_mine="$1" _iqe_released="${1%.mine}"
  rm -f "${_iqe_mine%.req.mine}.owner" 2>/dev/null || true
  touch "$_iqe_mine" 2>/dev/null || true
  mv -f "$_iqe_mine" "$_iqe_released" 2>/dev/null || true
  return 0
}

# iq_skip <claimed-path> <reason> — DROP a bad intent loudly (malformed, unknown kind, terminal
# refusal): warn to stderr and remove the claim + its sidecars. The caller's loop continues; a drain
# never dies on one bad intent.
iq_skip() {
  local _iqp_mine="$1" _iqp_reason="${2:-malformed intent}"
  printf '%s: WARNING — skipping intent %s: %s\n' \
    "$IQ_LOG_PREFIX" "$(basename "${_iqp_mine%.req.mine}")" "$_iqp_reason" >&2
  rm -f "$_iqp_mine" 2>/dev/null || true
  iq_sidecars_rm "${_iqp_mine%.req.mine}"
  return 0
}

# iq_cancel <qdir> <intent-id> — doc §4.4 LEVEL 1: COUNTERMAND an intent that has NOT been claimed yet.
# The rename is the whole safety argument: it races a drain's own claim rename on the SAME path, so
# exactly one of the two wins. If the drain won, this `mv` fails and we return 1 — the caller must be
# LOUD (never a silent no-op: the operator has to learn the work is already launching, which is §4.4
# level 2's problem, not this op's). If we won, the drain simply never sees the file and moves to the
# next candidate: no double-execution, and no phantom .req left behind either way.
iq_cancel() {
  local _iqn_q="$1" _iqn_id; _iqn_id="$(iq_id_of "${2:-}")"
  [ -n "$_iqn_id" ] || return 1
  mv "$_iqn_q/$_iqn_id.req" "$_iqn_q/$_iqn_id.cancelled" 2>/dev/null || return 1
  # Terminal: the sidecars have no further reader. The .cancelled file itself carries the payload as
  # evidence until the drain's retention sweep GCs it.
  iq_sidecars_rm "$_iqn_q/$_iqn_id"
  return 0
}

# iq_escalate <claimed-path> <reason> — doc §4.3, TERMINAL. An intent the drain REFUSES to execute
# (today: it aged past its TTL) must never be servable again: renaming the claim to <id>.escalated
# takes it out of the drain set for good (no glob reaches it), while keeping the payload on disk as the
# evidence the caller's operator-facing row points at. The CALLER owns that row, its ack path and its
# age-to-retired sweep — shipping the escalation without those is the HERD-613 defect, not a safety
# feature. Returns 1 when the claim could not be retired (it vanished under us).
iq_escalate() {
  local _iqg_mine="$1"
  mv -f "$_iqg_mine" "${_iqg_mine%.req.mine}.escalated" 2>/dev/null || return 1
  # The owner sidecar names a worker that will never run this intent; the rest stay as the escalated
  # record's evidence and are GC'd with it when the row retires.
  rm -f "${_iqg_mine%.req.mine}.owner" 2>/dev/null || true
  return 0
}

# ── Enqueue ──────────────────────────────────────────────────────────────────────────────────────

# iq_next_seq <qdir> — the queue-scoped enqueue sequence counter (HERD-443).
#
# The INTENT_ID used to be `date +%s`-$$-$RANDOM. `date +%s` alone TIES for any two intents enqueued in
# the SAME second (routine — a coordinator wave fires several enqueues back to back), and $$/$RANDOM
# have no relationship to call order, so the `sort` in iq_order could silently invert real enqueue
# order. A queue-scoped counter makes same-second ordering deterministic regardless of PID allocation.
# Serialize the read-increment-write with flock(1) when present, else a plain atomic-mkdir spin-wait
# (stock macOS has no flock). No eager "is the lock stale" heuristic: under a 40-way concurrent stress
# test, a `find -mmin` staleness probe on the lock DIR raced with a peer's own hold-and-release cycle
# often enough to `rmdir` a lock that was still legitimately held, letting two callers into the
# critical section at once (proven live: duplicate .seq values). The critical section is one tiny file
# read+write, sub-millisecond, so a bounded spin clears in practice.
iq_next_seq() {
  local _iqq_q="$1" _iqq_f="$1/.seq" _iqq_lockdir="$1/.seq.lock.d" _iqq_tries=0 _iqq_n
  if command -v flock >/dev/null 2>&1; then
    exec 8>"$_iqq_q/.seq.lock"
    flock 8
  else
    while ! mkdir "$_iqq_lockdir" 2>/dev/null; do
      _iqq_tries=$((_iqq_tries + 1))
      [ "$_iqq_tries" -ge 300 ] && break   # ~3s waited; proceed unlocked rather than wedge the enqueue
      sleep 0.01
    done
  fi
  _iqq_n="$(cat "$_iqq_f" 2>/dev/null || echo 0)"
  case "$_iqq_n" in ''|*[!0-9]*) _iqq_n=0 ;; esac
  _iqq_n=$((_iqq_n + 1))
  printf '%s' "$_iqq_n" > "$_iqq_f"
  if command -v flock >/dev/null 2>&1; then exec 8>&-; else rmdir "$_iqq_lockdir" 2>/dev/null || true; fi
  printf '%s' "$_iqq_n"
}

# iq_mint_id <qdir> — a fresh INTENT_ID: "<enqueue-epoch>-<0-padded queue sequence>-<pid>". The leading
# epoch field is what iq_enqueue_epoch reads for the TTL, and the padded sequence is what keeps `sort`
# FIFO-honest within one second.
iq_mint_id() {
  local _iqm_q="$1"
  printf '%s-%s-%s' "$(date +%s)" "$(printf '%010d' "$(iq_next_seq "$_iqm_q")")" "$$"
}

# iq_publish <qdir> <intent-id> <payload> — publish a minted intent ATOMICALLY (temp file, then one
# rename), so a drain never observes a half-written intent. Sidecars are written by the caller BEFORE
# this call, so every sidecar is present the instant the intent becomes claimable.
iq_publish() {
  local _iqb_q="$1" _iqb_id="$2" _iqb_payload="$3" _iqb_tmp
  _iqb_tmp="$(mktemp "$_iqb_q/.tmp.XXXXXX")" || return 1
  printf '%s\n' "$_iqb_payload" > "$_iqb_tmp" || { rm -f "$_iqb_tmp" 2>/dev/null; return 1; }
  mv "$_iqb_tmp" "$_iqb_q/$_iqb_id.req" 2>/dev/null || { rm -f "$_iqb_tmp" 2>/dev/null; return 1; }
  return 0
}

# iq_enqueue <qdir> <payload> — mint + publish in one call, printing the INTENT_ID. The convenience
# form for a tenant with no sidecars to write (the M3 marker tenant); a tenant that DOES write sidecars
# (the spawn queue) calls iq_mint_id, writes them, then iq_publish.
iq_enqueue() {
  local _iqz_q="$1" _iqz_payload="$2" _iqz_id
  mkdir -p "$_iqz_q" 2>/dev/null || return 1
  _iqz_id="$(iq_mint_id "$_iqz_q")" || return 1
  [ -n "$_iqz_id" ] || return 1
  iq_publish "$_iqz_q" "$_iqz_id" "$_iqz_payload" || return 1
  printf '%s' "$_iqz_id"
  return 0
}

# iq_attempts <qdir> <intent-id> — the transient-failure count so far (0 when never recorded).
iq_attempts() {
  local _iqt_n=""
  [ -f "$1/$2.attempts" ] && _iqt_n="$(sed -n 1p "$1/$2.attempts" 2>/dev/null | tr -cd '0-9')"   # pipe-ok: one short sidecar line
  case "${_iqt_n:-}" in ''|*[!0-9]*) _iqt_n=0 ;; esac
  printf '%s' "$_iqt_n"
}

# iq_attempt_bump <qdir> <intent-id> — record one more transient failure and print the new count. The
# counter rides a sidecar that survives iq_release (so it accrues across ticks) and is GC'd with the
# intent by done/skip/cancel — doc §4.3's "never loop silently, never loop forever".
iq_attempt_bump() {
  local _iqu_n; _iqu_n=$(( $(iq_attempts "$1" "$2") + 1 ))
  printf '%s\n' "$_iqu_n" > "$1/$2.attempts" 2>/dev/null || true
  printf '%s' "$_iqu_n"
}

# ── Publish / supersede a generation (HERD-642) ───────────────────────────────────────────────────

# iq_gen_mint <qdir> — a fresh, OPAQUE generation id.
#
# Deliberately iq_mint_id's shape (epoch + queue sequence + pid) rather than an incrementing "N+1"
# counter: two seats publishing a plan in the same window would both compute the same N+1 and both
# stamp their intents with it, so BOTH plans would go live on the first swap — precisely the state this
# mechanism exists to make impossible. A unique id per publish makes the pointer the only arbiter: last
# writer wins atomically, and the loser's intents are superseded the instant it does.
iq_gen_mint() { iq_mint_id "${1:-}"; }

# iq_gen_publish <qdir> <gen-id> — make <gen-id> the live generation in ONE atomic rename.
#
# The temp file is created INSIDE the queue dir so the rename can never cross a filesystem and degrade
# into a copy (a copy has a window; a rename does not). rc 1 when the swap could not be made — and the
# caller must be LOUD about that, because nothing was superseded: the previous generation is still live
# and still draining, which is the safe direction but not the one the operator asked for.
iq_gen_publish() {
  local _iqgp_q="${1:-}" _iqgp_gen="${2:-}" _iqgp_tmp
  [ -n "$_iqgp_q" ] && [ -n "$_iqgp_gen" ] || return 1
  _iqgp_tmp="$(mktemp "$_iqgp_q/.tmp.gen.XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$_iqgp_gen" > "$_iqgp_tmp" 2>/dev/null || { rm -f "$_iqgp_tmp" 2>/dev/null; return 1; }
  mv "$_iqgp_tmp" "$(iq_gen_pointer "$_iqgp_q")" 2>/dev/null || { rm -f "$_iqgp_tmp" 2>/dev/null; return 1; }
  return 0
}

# iq_gen_retire <qdir> — drop the PENDING intents of every superseded generation, silently (doc §4.4:
# "older un-claimed intents retire silently"). Prints how many were retired.
#
# Correctness does NOT depend on this — the pointer already took them out of iq_order — so it runs AFTER
# the swap and a crash between the two leaves dead-but-harmless files rather than a half-published plan.
#
# The `mv` is the race guard, not a flourish: `rm -f` reports success on a path a drain renamed to
# `.req.mine` a microsecond earlier, and we would then GC the sidecars out from under a LIVE claim.
# Renaming first fails when the drain won, so a claimed intent is left strictly alone — which is also
# the right semantics: a claim means the lane is already launching, and doc §4.4 level 2 says that is
# countermanded through the BUILDER, never by editing the queue underneath it.
iq_gen_retire() {
  local _iqgr_q="${1:-}" _iqgr_f _iqgr_id _iqgr_n=0
  for _iqgr_f in "$_iqgr_q"/*.req; do
    [ -e "$_iqgr_f" ] || continue
    _iqgr_id="$(iq_id_of "$_iqgr_f")"
    iq_gen_superseded "$_iqgr_q" "$_iqgr_id" || continue
    mv "$_iqgr_f" "$_iqgr_f.retiring" 2>/dev/null || continue
    rm -f "$_iqgr_f.retiring" 2>/dev/null || true
    iq_sidecars_rm "$_iqgr_q/$_iqgr_id"
    _iqgr_n=$(( _iqgr_n + 1 ))
  done
  printf '%s' "$_iqgr_n"
}

# iq_plan_rows <qdir> [ttl-seconds] [now-epoch] — THE PUBLISHED PLAN, one TAB row per still-pending
# candidate, in DRAIN ORDER:
#
#     <enqueue-epoch>\t<intent-id>\t<prio>\t<slug>\t<lane>\t<ref>\t<blocker>
#
# ONE implementation for BOTH readers — `herd queue list` (bin/herd) and the watcher's "planned work"
# console section (agent-watch.sh's build_queue_plan) — so the CLI and the pane can never disagree about
# what the plan is. Two surfaces re-deriving one queue is the drift this library exists to prevent.
#
# Prints NOTHING when no generation is live. That is deliberate and load-bearing: with no published plan
# there is no plan to show, so a project that only ever ran ad-hoc `spawn.sh` renders no new console
# section and its watch frame stays byte-identical. Superseded candidates are dropped through the same
# iq_gen_superseded rule the drain uses, so a stale plan cannot linger on a surface after being retired
# (including under a lever-off read, where iq_order itself does not filter).
#
# Reads the spawn tenant's FROZEN positional payload (line 1 = slug, line 2 = lane; doc §3.2) — the plan
# surface is about builder candidates, and that shape is exactly what the doc froze so it could be.
#
# The blocker column is what the queue KNOWS, never a guess: `after=<dep>` names a published dependency
# hold (whether the dep has since merged is the drain's live read, not a plan-time fact), `ttl` marks a
# candidate the drain will ESCALATE rather than launch, and empty means nothing is in its way.
iq_plan_rows() {
  local _iqpr_q="${1:-}" _iqpr_ttl="${2:-0}" _iqpr_now="${3:-}"
  local _iqpr_f _iqpr_id _iqpr_slug _iqpr_lane _iqpr_ref _iqpr_blk _iqpr_e
  [ -n "$(iq_generation "$_iqpr_q")" ] || return 0
  while IFS= read -r _iqpr_f; do
    [ -n "$_iqpr_f" ] || continue
    _iqpr_id="$(iq_id_of "$_iqpr_f")"
    iq_gen_superseded "$_iqpr_q" "$_iqpr_id" && continue
    _iqpr_slug="$(sed -n 1p "$_iqpr_f" 2>/dev/null || true)"
    _iqpr_lane="$(sed -n 2p "$_iqpr_f" 2>/dev/null || true)"
    _iqpr_ref=""
    [ -f "$_iqpr_q/$_iqpr_id.ref" ] && _iqpr_ref="$(sed -n 1p "$_iqpr_q/$_iqpr_id.ref" 2>/dev/null || true)"
    _iqpr_blk=""
    [ -f "$_iqpr_q/$_iqpr_id.after" ] \
      && _iqpr_blk="after=$(sed -n 1p "$_iqpr_q/$_iqpr_id.after" 2>/dev/null || true)"
    iq_expired "$_iqpr_id" "$_iqpr_ttl" "$_iqpr_now" && _iqpr_blk="ttl"
    _iqpr_e="$(iq_enqueue_epoch "$_iqpr_id")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${_iqpr_e:-0}" "$_iqpr_id" "$(iq_prio "$_iqpr_q" "$_iqpr_id")" \
      "${_iqpr_slug:-?}" "${_iqpr_lane:-?}" "$_iqpr_ref" "$_iqpr_blk"
  done < <(iq_order "$_iqpr_q")
  return 0
}
