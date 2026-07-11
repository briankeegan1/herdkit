"""herd.statemachine — the typed lifecycle state machine of a gated subject (HERD-315, P3b).

Part of EPIC HERD-300 (strangler port of the engine core). P0 (``docs/engine-contract.md``)
froze the gate contract as prose + live-code anchors; P2 (:mod:`herd.decisions`) ported the
*pure arithmetic* the watcher already factored out (merge-policy resolver, ``_hold_decision``,
refix-budget). This module is the next seam: the **doctrine-by-comment lifecycle becomes a typed
transition table** — the "win" named in ``docs/spikes/engine-port-python.md`` §0.2. It carries a
subject ``(pr, sha)`` through the gate pipeline (contract §2.1) and lands it in exactly one of the
four normalized outcomes (§2.2) and the holds around them (§5.4–§5.6).

WHAT THIS IS — pure data + functions, no I/O. There is no clock, no subprocess, no journal, no
``asyncio`` here: :data:`STATES`, :data:`EVENTS`, :data:`TRANSITIONS`, and :func:`transition` are a
deterministic table the bash watcher's control flow can be shadowed against (the P3 shadow-mode
plan, ``docs/spikes/engine-port-python.md`` §3). The bash tree is UNCHANGED; this exists to be
diffed against it, decision-for-decision.

WHAT IT DELEGATES — the two *decision points* on the pipeline are NOT re-implemented here; they
are consumed from :mod:`herd.decisions` (the P2 core), so the arithmetic lives in exactly one
place (contract §4, §5.4–§5.5):

  * a rail **BLOCK** → bounce-or-escalate is decided by ``decisions.refix_budget_reason`` — see
    :func:`classify_block`.
  * a **blessed** sha → merge/hold/observe is decided by ``decisions.hold_decision`` (itself over
    ``decisions.effective_merge_policy``) — see :func:`classify_gates_passed`.

The state machine's own job is the *shape* of the pipeline — which states exist, which events are
legal from each, where supersession cuts in — while the numbers stay in :mod:`herd.decisions`.

THE PIPELINE (contract §2.1 fixed linear order; each transition cites its section in
:data:`TRANSITIONS`). The cheap deterministic gates run first, then the two model/suite rails, then
the blessing and the policy decision::

    INTAKE ──dispatch_health──▶ HEALTH ──health_clean/flaky──▶ REVIEW ──review_pass──▶ BLESSED
       │  ╲                        │                              │                       │
       │   ╲stale_detected         │health_codeerror              │review_block           ├─decide_merge──▶ MERGED
       │    ╲                      ▼                              ▼                       ├─decide_hold───▶ HOLD ──approved──▶ MERGED
       │     ▶ STALE_HELD        BLOCKED ◀───────────────────────┘                       └─decide_observe▶ OBSERVE
       │breaker_open                │  ╲refix_exhausted
       ▼                            │   ╲
    BREAKER_HELD          refix_bounce▼    ▶ ESCALATED
                                   INTAKE (re-gate the fix)

INFRA is NOT an outcome (§2.2): a reviewer/health death with no parseable verdict is a bounded
retry, never a cached BLOCK — modelled as the ``review_infra`` / ``health_infra`` self-loops on
:data:`REVIEW` / :data:`HEALTH` (the ONLY self-loops in the table).

SUPERSESSION (§2.4, §6.1). A new head sha, or a *sibling merge* that re-stales this sha, discards
the subject's in-flight work and terminates its workers. Every non-terminal state therefore carries
``new_sha`` and ``sibling_restale`` edges to :data:`SUPERSEDED` — generalizing the live new-sha
cancel (``_discard_stale_reviews`` / ``_discard_stale_health``) to the cross-sibling cancel §6.1
names as TARGET. The re-armed subject starts a fresh :data:`INTAKE` for the new ``(pr, sha)``.
"""

from herd import decisions


# ── states (the lifecycle of one (pr, sha) subject) ──────────────────────────────────────────
# Each names a resting position in the gate pipeline (§2.1) or a terminal outcome (§2.2 / §5).

INTAKE = "INTAKE"              # a fresh (pr, sha) candidate entering the action pass (§2.1)
BREAKER_HELD = "BREAKER_HELD"  # infra circuit breaker OPEN; dispatch halted (§3.3; §2.1 step 1)
STALE_HELD = "STALE_HELD"      # stale-base/dup; builder bounced to rebase (§2.1 step 3/7; §6.2)
HEALTH = "HEALTH"              # health rail in flight (§2.1 step 5; §2.3)
REVIEW = "REVIEW"              # review rail in flight (§2.1 step 8; §2.3)
BLOCKED = "BLOCKED"            # a rail found a real defect; builder bounced (§2.2 BLOCK; §4)
BLESSED = "BLESSED"            # both rails passed; herd/gates=success posted (§2.3; §2.1 step 10)
HOLD = "HOLD"                  # gates passed, policy hold: human-verify / approval (§5.4–§5.6)
OBSERVE = "OBSERVE"            # observe mode; never merges from this seat (§5.5)
ESCALATED = "ESCALATED"        # cannot progress autonomously — needs-you (§2.2 ESCALATE; §4)
MERGED = "MERGED"              # do_merge applied at-most-once per sha (§2.4)
SUPERSEDED = "SUPERSEDED"      # new head sha / sibling re-stale; in-flight cancelled (§2.4; §6.1)

STATES = (
    INTAKE, BREAKER_HELD, STALE_HELD, HEALTH, REVIEW, BLOCKED,
    BLESSED, HOLD, OBSERVE, ESCALATED, MERGED, SUPERSEDED,
)

# Terminal states have NO outgoing transition — not even supersession (the subject is done: it
# merged, it was handed to a human, or it was already discarded). §2.4 apply-at-most-once, §4.
TERMINAL = frozenset({MERGED, ESCALATED, SUPERSEDED})


# ── events (§3.4 event catalog + the four gate outcomes §2.2) ─────────────────────────────────

BREAKER_OPEN = "breaker_open"        # infra breaker opened (§3.3)
BREAKER_CLOSE = "breaker_close"      # a real verdict proved the env alive; breaker closed (§3.3)
STALE_DETECTED = "stale_detected"    # stale/dup gate found the base moved (§2.1 step 3/7)
BASE_FRESH = "base_fresh"            # rebased onto the live base; stale rail refunded (§4)
DISPATCH_HEALTH = "dispatch_health"  # health rail dispatched (§2.1 step 5; §3.4 healthcheck_started)
HEALTH_CLEAN = "health_clean"        # healthcheck CLEAN (§2.3; §3.4 healthcheck_outcome)
HEALTH_FLAKY = "health_flaky"        # healthcheck FLAKY — tolerated, counts as pass (§2.2)
HEALTH_CODEERROR = "health_codeerror"  # healthcheck real code error → BLOCK (§2.2; §2.3)
HEALTH_INFRA = "health_infra"        # health worker died with no verdict → bounded retry (§2.2)
REVIEW_PASS = "review_pass"          # REVIEW: PASS recorded (§2.2; §2.3; §3.4 verdict_recorded)
REVIEW_BLOCK = "review_block"        # REVIEW: BLOCK — a correctness defect (§2.2; §2.3)
REVIEW_INFRA = "review_infra"        # REVIEW: INFRA-FAIL → bounded retry, never cached (§2.2)
REFIX_BOUNCE = "refix_bounce"        # budget remains; builder re-woken to fix (§4)
REFIX_EXHAUSTED = "refix_exhausted"  # rail or total cap reached → needs-you (§4)
BLESSING_POSTED = "blessing_posted"  # both rails green; herd/gates=success posted (§2.3)
DECIDE_MERGE = "decide_merge"        # policy decision = MERGE (§5.4–§5.5, decisions.hold_decision)
DECIDE_HOLD = "decide_hold"          # policy decision = HOLD (§5.4–§5.5)
DECIDE_OBSERVE = "decide_observe"    # policy decision = OBSERVE, never merge (§5.5)
APPROVED = "approved"                # a sha-keyed approval cleared the hold (§5.5)
MERGE_REFUSED = "merge_refused"      # --match-head-commit refused: sha moved at apply (§2.4)
NEW_SHA = "new_sha"                  # a new head sha superseded this one (§2.4)
SIBLING_RESTALE = "sibling_restale"  # a sibling merge re-staled this still-valid sha (§6.1)

EVENTS = (
    BREAKER_OPEN, BREAKER_CLOSE, STALE_DETECTED, BASE_FRESH,
    DISPATCH_HEALTH, HEALTH_CLEAN, HEALTH_FLAKY, HEALTH_CODEERROR, HEALTH_INFRA,
    REVIEW_PASS, REVIEW_BLOCK, REVIEW_INFRA,
    REFIX_BOUNCE, REFIX_EXHAUSTED, BLESSING_POSTED,
    DECIDE_MERGE, DECIDE_HOLD, DECIDE_OBSERVE, APPROVED, MERGE_REFUSED,
    NEW_SHA, SIBLING_RESTALE,
)

# The two events that supersede a subject from ANY non-terminal state (§2.4 new-sha cancel; §6.1
# cross-sibling cancel). Added to every non-terminal state's row programmatically below.
_SUPERSESSION = (NEW_SHA, SIBLING_RESTALE)


# ── the transition table ─────────────────────────────────────────────────────────────────────
# TRANSITIONS[(state, event)] = next_state. This dict IS the contract; :func:`transition` is a pure
# lookup over it. The explicit rows below are the pipeline proper; the supersession rows (§2.4/§6.1)
# are added programmatically so every non-terminal state carries them without 22 hand-copied lines.

_BASE_TRANSITIONS = {
    # INTAKE — the cheap deterministic pre-checks fire first (§2.1 steps 1–3), then dispatch.
    (INTAKE, BREAKER_OPEN): BREAKER_HELD,     # step 1: infra breaker open halts dispatch (§3.3)
    (INTAKE, STALE_DETECTED): STALE_HELD,     # step 3: base moved / textual dup (§2.1)
    (INTAKE, DISPATCH_HEALTH): HEALTH,        # step 5: health rail is the first suite/model gate (§2.3)

    # BREAKER_HELD — a real PASS/BLOCK elsewhere proves the env alive and re-opens the pass (§3.3).
    (BREAKER_HELD, BREAKER_CLOSE): INTAKE,

    # STALE_HELD — the stale rail carries a refix budget (§4). base_fresh is progress (rail reset,
    # §4 refund-on-green) and re-enters the pipeline; an exhausted budget escalates to a human.
    # A SURVIVING budget has NO edge here on purpose: an open stale bounce is an implicit self-hold
    # (wake the builder to rebase), and re-gating is deferred to base_fresh — a
    # `(STALE_HELD, refix_bounce)` mapping would wrongly re-gate before the rebase (§6.2). Stale
    # callers branch on :func:`classify_block` themselves rather than composing through the table.
    (STALE_HELD, BASE_FRESH): INTAKE,
    (STALE_HELD, REFIX_EXHAUSTED): ESCALATED,

    # HEALTH — the healthcheck rail (§2.3). CLEAN or the tolerated FLAKY passes and advances to the
    # review rail (§2.1 step 8 follows step 5); CODEERROR blocks; an infra death retries, never
    # caches (§2.2 "INFRA is not an outcome").
    (HEALTH, HEALTH_CLEAN): REVIEW,
    (HEALTH, HEALTH_FLAKY): REVIEW,
    (HEALTH, HEALTH_CODEERROR): BLOCKED,
    (HEALTH, HEALTH_INFRA): HEALTH,

    # REVIEW — the adversarial correctness rail (§2.3). PASS blesses (both rails now green);
    # BLOCK bounces; INFRA-FAIL retries (§2.2), never a cached code BLOCK.
    (REVIEW, REVIEW_PASS): BLESSED,
    (REVIEW, REVIEW_BLOCK): BLOCKED,
    (REVIEW, REVIEW_INFRA): REVIEW,

    # BLOCKED — a rail found a real defect (§2.2 BLOCK). The bounce/escalate fork is decided by the
    # refix budget (§4, via :func:`classify_block`): a bounce re-gates the builder's fix (a fresh
    # INTAKE), an exhausted budget hands the subject to a human (needs-you).
    (BLOCKED, REFIX_BOUNCE): INTAKE,
    (BLOCKED, REFIX_EXHAUSTED): ESCALATED,

    # BLESSED — both rails passed and herd/gates=success is posted (§2.3). The merge-policy decision
    # (§5.4–§5.5, via :func:`classify_gates_passed`) selects exactly one action. merge_refused is
    # the apply-time race: the head moved out from under --match-head-commit (§2.4).
    (BLESSED, DECIDE_MERGE): MERGED,
    (BLESSED, DECIDE_HOLD): HOLD,
    (BLESSED, DECIDE_OBSERVE): OBSERVE,
    (BLESSED, MERGE_REFUSED): SUPERSEDED,

    # HOLD — a gates-green PR awaiting a human/coordinator signal (§5.4 human-verify, §5.5 approval).
    # The hold is loud and owned (§5.6); an approval clears it to merge. A hold is sha-keyed, so a
    # new sha re-arms it (handled by the universal supersession edges below).
    (HOLD, APPROVED): MERGED,

    # OBSERVE — observe mode never merges from this seat (§5.5). It rests here until a new sha
    # supersedes it (the universal edges below); there is no approval path out of observe.
}


def _build_transitions():
    """Assemble the full table: the explicit pipeline rows + universal supersession (§2.4/§6.1).

    Every non-:data:`TERMINAL` state gains ``new_sha`` and ``sibling_restale`` → :data:`SUPERSEDED`,
    so any in-flight subject is cancellable the instant its sha is superseded — the generalization
    §6.1 marks as TARGET. Terminal states get no edges (the subject is done).
    """
    table = dict(_BASE_TRANSITIONS)
    for state in STATES:
        if state in TERMINAL:
            continue
        for ev in _SUPERSESSION:
            table[(state, ev)] = SUPERSEDED
    return table


TRANSITIONS = _build_transitions()


class IllegalTransition(Exception):
    """Raised by :func:`transition` for a ``(state, event)`` pair the table does not define."""


def transition(state, event):
    """The pure transition function: return the next state for ``(state, event)``.

    A table lookup and nothing more — no side effects, no clock. Raises :class:`IllegalTransition`
    for any undefined pair (an unknown state/event, or an event illegal from that state, including
    ANY event from a terminal state). Callers that want a soft check use :func:`can` first.
    """
    try:
        return TRANSITIONS[(state, event)]
    except KeyError:
        raise IllegalTransition("no transition from %r on %r" % (state, event))


def can(state, event):
    """True iff ``(state, event)`` is a defined transition (the soft form of :func:`transition`)."""
    return (state, event) in TRANSITIONS


def events_from(state):
    """The events legal from ``state``, sorted — ``()`` for a terminal state."""
    return tuple(sorted(ev for (s, ev) in TRANSITIONS if s == state))


def is_terminal(state):
    """True iff ``state`` is a terminal outcome (no outgoing transition): merged / escalated / superseded."""
    return state in TERMINAL


# ── the decisions.py bridges — the two decision points on the pipeline ────────────────────────
# These map a decision-bearing context onto the event the table then consumes. ALL the arithmetic
# lives in :mod:`herd.decisions`; these functions only translate its result into a lifecycle event,
# so the budget/policy semantics have exactly one home (contract §4, §5.4–§5.5).

def classify_block(rows, pr, sha, kind, refix_max_rounds):
    """Which event a rail BLOCK produces: :data:`REFIX_BOUNCE` (budget remains) or
    :data:`REFIX_EXHAUSTED` (rail/total cap reached).

    Delegates the whole decision to ``decisions.refix_budget_reason`` (§4): a non-``None`` reason
    means this rail may not bounce again → escalate; ``None`` means budget remains → bounce.
    ``kind`` is the rail (``review`` | ``health`` | ``stale`` | ``ci``); ``rows`` is a parsed refix
    ledger (:func:`herd.decisions.parse_refix_ledger`). ``sha`` is unused by the budget arithmetic
    (the budget is per-rail, not sha-keyed — §4) but is kept in the signature so a caller passes the
    subject's full version key and a future sha-keyed rule needs no signature change.
    """
    reason = decisions.refix_budget_reason(rows, pr, kind, refix_max_rounds)
    return REFIX_EXHAUSTED if reason is not None else REFIX_BOUNCE


def classify_gates_passed(mode, hv_hold, approved, hv_policy="hold"):
    """Which event a BLESSED sha produces: :data:`DECIDE_MERGE` / :data:`DECIDE_HOLD` /
    :data:`DECIDE_OBSERVE`.

    Delegates to ``decisions.hold_decision`` (§5.4–§5.5), which itself resolves the effective merge
    policy — so a typo'd ``MERGE_POLICY`` fails strict to observe, a human-verify block holds once,
    and an approval merges, all in exactly one place. ``mode`` is the effective merge policy
    (``auto`` | ``approve`` | ``observe``); ``hv_hold`` truthy iff a HUMAN-VERIFY block is present;
    ``approved`` truthy iff a sha-keyed approval exists; ``hv_policy`` is ``HUMAN_VERIFY_POLICY``.
    """
    action = decisions.hold_decision(mode, hv_hold, approved, hv_policy)
    return {"MERGE": DECIDE_MERGE, "HOLD": DECIDE_HOLD, "OBSERVE": DECIDE_OBSERVE}[action]


def next_after_block(state, rows, pr, sha, kind, refix_max_rounds):
    """Drive one rail BLOCK step end-to-end: classify the budget, then transition. Convenience over
    ``transition(state, classify_block(...))`` — the composed form callers use from :data:`BLOCKED`,
    where BOTH budget outcomes are table events (``refix_bounce`` → :data:`INTAKE`,
    ``refix_exhausted`` → :data:`ESCALATED`).

    NOT the stale rail's path for a surviving budget. From :data:`STALE_HELD` only the EXHAUSTED
    branch is a table event (``refix_exhausted`` → :data:`ESCALATED`); an open stale budget is an
    implicit self-hold that stays in :data:`STALE_HELD` awaiting ``base_fresh`` (the rebase), NOT a
    ``refix_bounce`` edge — there is deliberately no ``(STALE_HELD, refix_bounce)`` transition (a
    stale bounce only wakes the builder to rebase; re-gating happens later, on ``base_fresh``). So a
    STALE_HELD caller must branch on :func:`classify_block` itself — escalate on
    :data:`REFIX_EXHAUSTED`, self-hold on :data:`REFIX_BOUNCE` — rather than composing through this
    function, which raises :class:`IllegalTransition` by design on a surviving stale budget."""
    return transition(state, classify_block(rows, pr, sha, kind, refix_max_rounds))


def next_after_gates(state, mode, hv_hold, approved, hv_policy="hold"):
    """Drive one gates-passed step end-to-end: classify the policy, then transition. Convenience
    over ``transition(state, classify_gates_passed(...))`` — the composed form callers use from
    :data:`BLESSED`."""
    return transition(state, classify_gates_passed(mode, hv_hold, approved, hv_policy))


# ── table export ─────────────────────────────────────────────────────────────────────────────

def export_table():
    """The transition table as a sorted list of ``(from_state, event, to_state)`` triples.

    Deterministic (LC_ALL=C-style sort by the string tuple) so it is a stable artifact to diff, to
    render into docs, or to shadow the bash control flow against. Round-trips :data:`TRANSITIONS`
    exactly: ``{(f, e): t for f, e, t in export_table()} == TRANSITIONS``.
    """
    return sorted((s, ev, t) for (s, ev), t in TRANSITIONS.items())


def export_tsv():
    """The transition table as a TSV string: a ``from\\tevent\\tto`` header + one row per triple.

    Same order as :func:`export_table`; trailing newline. A greppable, VCS-friendly rendering of the
    machine — the file form of the diagram in this module's docstring.
    """
    lines = ["from\tevent\tto"]
    lines.extend("%s\t%s\t%s" % triple for triple in export_table())
    return "\n".join(lines) + "\n"
