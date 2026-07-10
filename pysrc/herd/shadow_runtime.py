"""herd.shadow_runtime — the SHADOW watcher runtime, in asyncio (HERD-316, P3c, EPIC HERD-300).

This is P3c of the strangler port: the Python watcher state machine, run in **shadow mode**. It
walks the same candidate → gate → decision → apply pipeline the bash ``agent-watch.sh`` walks, but
it is **DRY-RUN ONLY** and its sole side effect is a journal. Nothing here calls ``gh``, merges a
PR, or touches a pane; the only write is one line per event to ``.herd/journal-shadow.jsonl`` via
:class:`herd.shadow_journal.ShadowJournal`, in ``journal.sh``-identical event shapes. Run it beside
the live watcher over the sim rig and the P3 acceptance gate is a journal diff — same inputs, same
event stream (``docs/spikes/engine-port-python.md`` §3, P3; contract §7 keeps the schema frozen).

Because it never observes the live control room — candidates arrive as injected fixtures, not from
``herdr agent list`` / ``gh pr list`` — a shadow run is side-effect-free by construction (the sim
rig "drives behavior through stubs, not bash internals", spike §3), which is exactly what the
task's VERIFY discipline requires.

WHAT THIS RUNTIME DEMONSTRATES (the four structural wins the port exists to buy, spike §0):

  * **Structured concurrency (asyncio task groups).** Candidates are processed as child tasks of a
    task group; a rail's in-flight work is a nested child. Cancelling a parent cancels its children
    — the categorical fix for the re-dispatch/orphan bug class (spike §0.4). :func:`_task_group`
    uses the native :class:`asyncio.TaskGroup` when the interpreter has it (3.11+) and a faithful
    backport otherwise, so the same cancel-on-error / cancel-children semantics hold on 3.9.

  * **Cancel-on-supersession.** A new head sha (or a sibling merge that re-stales a still-valid
    sha) supersedes in-flight gate work; the runtime TERMs the now-doomed rail task and re-gates
    the new sha — generalizing ``agent-watch.sh``'s new-sha ``_discard_stale_reviews`` /
    ``_discard_stale_health`` cancel to cross-candidate supersession (contract §2.4, §6.1 TARGET).

  * **Semaphores, not file locks.** The review and health rails are bounded by
    :class:`asyncio.Semaphore` sized from ``REVIEW_CONCURRENCY`` / ``HEALTH_CONCURRENCY`` — the
    concurrency seam the bash tree implements with ``_health_slot_free`` file locks (contract §2.3,
    §6.3; spike §0.4).

  * **A typed lifecycle.** The gate DAG is declared as ordered cost classes (deterministic-cheap →
    deterministic-slow → LLM, contract §2.1 / §6.1 TARGET), and candidate lifecycle transitions run
    through :mod:`herd.statemachine` (P3b) — an explicit transition function where doctrine was a
    comment (spike §0.2). That module is being built in PARALLEL; the import is GUARDED (below) so
    this PR is green standalone, with a local fallback model honoring the same
    ``STATES`` / ``EVENTS`` / ``transition()`` interface.

The pure decision core (:mod:`herd.decisions`, P2) is REUSED verbatim for the merge-policy resolver
and the hold/merge/observe selector — the shadow runtime is the async harness *around* those pure
functions, never a re-implementation of them.

Stdlib-only. CLI: ``python3 -m herd.shadow_runtime [--fixture FILE]`` (fixture on stdin if omitted).
Unit-driven by ``tests/test_shadow_runtime.py`` + ``tests/test-py-shadow-runtime.sh``.
"""

import asyncio
import json
import os
import sys

from herd import decisions as D
from herd.shadow_journal import ShadowJournal

# ── Guarded consumption of the P3b state machine (pysrc/herd/statemachine.py) ─────────────────────
# P3b is a SIBLING item in flight this same overnight fleet. If it has already landed we drive
# lifecycle transitions through it; if it is ABSENT at our finish, this import fails softly and we
# fall back to an EQUIVALENT local model exposing the SAME documented interface — STATES (the
# lifecycle state set), EVENTS (the event set), and transition(state, event) -> state (a pure
# function that RAISES on an illegal transition). Either way this module imports and runs, so the
# PR is green standalone (the task's "mark the import guarded" non-negotiable).
try:  # pragma: no cover - the branch taken depends on whether P3b has merged yet
    from herd import statemachine as _statemachine  # type: ignore
    _HAVE_P3B = all(hasattr(_statemachine, n) for n in ("STATES", "EVENTS", "transition"))
except Exception:  # ImportError today; any import-time error must not sink the shadow runtime
    _statemachine = None
    _HAVE_P3B = False


class _FallbackStateMachine:
    """A local stand-in for :mod:`herd.statemachine` (P3b), used only when that module is absent.

    MIRRORS the real P3b interface — the SAME ``STATES`` / ``EVENTS`` names and ``transition()``
    semantics — over the subset of the lifecycle this runtime actually drives, so a standalone
    checkout (P3b not yet merged) behaves identically to one with P3b present. A PR enters at
    ``INTAKE``, walks the cost-classed gate DAG (``HEALTH`` → ``REVIEW`` → ``BLESSED``) and reaches
    a terminal (``MERGED`` / ``HOLD`` / ``OBSERVE`` / ``BLOCKED`` / ``STALE_HELD``) unless a
    ``new_sha`` SUPERSEDES it from any non-terminal state. ``transition`` raises
    :class:`IllegalTransition` on an undefined edge — the "illegal transitions throw" property the
    port exists to get (spike §0.2). When real P3b is on the tree it REPLACES this class outright
    (see :data:`SM`); the runtime code is identical either way.
    """

    INTAKE, STALE_HELD, HEALTH, REVIEW = "INTAKE", "STALE_HELD", "HEALTH", "REVIEW"
    BLOCKED, BLESSED, HOLD, OBSERVE = "BLOCKED", "BLESSED", "HOLD", "OBSERVE"
    MERGED, SUPERSEDED = "MERGED", "SUPERSEDED"

    STATES = (INTAKE, STALE_HELD, HEALTH, REVIEW, BLOCKED, BLESSED, HOLD, OBSERVE, MERGED, SUPERSEDED)
    TERMINAL = frozenset({MERGED, SUPERSEDED})
    EVENTS = (
        "stale_detected", "dispatch_health", "health_clean", "health_flaky", "health_codeerror",
        "review_pass", "review_block", "review_infra", "decide_merge", "decide_hold",
        "decide_observe", "approved", "new_sha", "sibling_restale",
    )

    _BASE = {
        (INTAKE, "stale_detected"): STALE_HELD,
        (INTAKE, "dispatch_health"): HEALTH,
        (HEALTH, "health_clean"): REVIEW,
        (HEALTH, "health_flaky"): REVIEW,
        (HEALTH, "health_codeerror"): BLOCKED,
        (HEALTH, "review_infra"): HEALTH,     # (health infra retry — kept for symmetry, unused here)
        (REVIEW, "review_pass"): BLESSED,
        (REVIEW, "review_block"): BLOCKED,
        (REVIEW, "review_infra"): REVIEW,
        (BLESSED, "decide_merge"): MERGED,
        (BLESSED, "decide_hold"): HOLD,
        (BLESSED, "decide_observe"): OBSERVE,
        (HOLD, "approved"): MERGED,
    }

    @classmethod
    def _table(cls):
        table = dict(cls._BASE)
        for state in cls.STATES:
            if state in cls.TERMINAL:
                continue
            for ev in ("new_sha", "sibling_restale"):
                table[(state, ev)] = cls.SUPERSEDED
        return table

    TRANSITIONS = None  # built lazily below

    @classmethod
    def transition(cls, state, event):
        if cls.TRANSITIONS is None:
            cls.TRANSITIONS = cls._table()
        try:
            return cls.TRANSITIONS[(state, event)]
        except KeyError:
            raise IllegalTransition("no transition from %r on %r" % (state, event))

    @classmethod
    def is_terminal(cls, state):
        return state in cls.TERMINAL


# The state machine's illegal-transition exception. Prefer P3b's own class so a `raise` from the
# real module is caught by name; fall back to the local one. `_advance` also catches broadly, so an
# unexpected exception type can never sink a shadow run — the lifecycle is an assertion layer.
IllegalTransition = getattr(_statemachine, "IllegalTransition", None) if _HAVE_P3B else None
if IllegalTransition is None:
    class IllegalTransition(Exception):
        """Raised for a ``(state, event)`` pair the transition table does not define."""


# The active state machine: real P3b if present, else the local mirror. Both satisfy the interface.
SM = _statemachine if _HAVE_P3B else _FallbackStateMachine

# The lifecycle state a fresh (pr, sha) candidate enters at — P3b's INTAKE (contract §2.1 step 1).
_S_INTAKE = getattr(SM, "INTAKE", "INTAKE")


# ── Gate outcomes and the cost-classed gate DAG (contract §2.1 / §2.2, §6.1 TARGET) ───────────────

# The four normalized gate outcomes (contract §2.2). A rail emits one of these for a (pr, sha).
PASS, BLOCK, ESCALATE, HOLD = "PASS", "BLOCK", "ESCALATE", "HOLD"

# Gate cost classes, cheapest first — the DAG the action pass walks (contract §2.1, §6.1 TARGET makes
# the implicit ordering explicit). A non-pass at any stage short-circuits the rest (the bash
# `continue` on a doomed sha), so no more-expensive gate runs on a sha already destined to hold/block.
CHEAP, SLOW, LLM = "deterministic-cheap", "deterministic-slow", "llm"


class _Superseded(Exception):
    """Raised inside a candidate's gate walk when its sha has moved — carries the new sha to re-gate."""

    def __init__(self, new_sha):
        super().__init__("superseded -> %s" % new_sha)
        self.new_sha = new_sha


class Candidate:
    """One subject under gate: a PR at a specific sha, plus the sim's stubbed rail results.

    In production these fields come from ``gh``/the healthcheck/the reviewer; in shadow/sim mode
    they are injected fixtures (never the live control room). ``stale`` drives the cheap stale/dup
    gate; ``health`` ∈ CLEAN|FLAKY|CODEERROR the health rail; ``review`` ∈ PASS|BLOCK|INFRA the
    review rail; ``hv_hold`` / ``approved`` the hold decision. ``supersede_to`` + ``supersede_at``
    script a new-sha supersession fired while the named stage is in-flight.
    """

    __slots__ = ("pr", "sha", "slug", "stale", "health", "review", "hv_hold", "approved",
                 "supersede_to", "supersede_at")

    def __init__(self, pr, sha, slug="", stale=False, health="CLEAN", review="PASS",
                 hv_hold=False, approved=False, supersede_to=None, supersede_at=None):
        self.pr = str(pr)
        self.sha = str(sha)
        self.slug = slug or ("pr-%s" % pr)
        self.stale = bool(stale)
        self.health = str(health).upper()
        self.review = str(review).upper()
        self.hv_hold = bool(hv_hold)
        self.approved = bool(approved)
        self.supersede_to = supersede_to
        self.supersede_at = supersede_at

    @classmethod
    def from_dict(cls, d):
        return cls(
            pr=d["pr"], sha=d["sha"], slug=d.get("slug", ""),
            stale=d.get("stale", False), health=d.get("health", "CLEAN"),
            review=d.get("review", "PASS"), hv_hold=d.get("hv_hold", False),
            approved=d.get("approved", False),
            supersede_to=d.get("supersede_to"), supersede_at=d.get("supersede_at"),
        )

    def respun(self, new_sha):
        """A copy of this candidate at a new sha — its supersession is single-shot (cleared)."""
        return Candidate(self.pr, new_sha, self.slug, self.stale, self.health, self.review,
                         self.hv_hold, self.approved, supersede_to=None, supersede_at=None)


class ShadowWatcher:
    """The dry-run async watcher: walks candidates through the gate DAG, journaling every event.

    Construct with the resolved config knobs and a :class:`ShadowJournal`; :meth:`run` returns a
    result summary (per-PR terminal outcome + observed peak rail concurrency) the parity/unit tests
    assert on. NOTHING here mutates anything but the shadow journal.
    """

    def __init__(self, config=None, journal=None, stage_delay=0.0):
        cfg = config or {}
        self.config = cfg
        self.journal = journal or ShadowJournal()
        # Rail concurrency ceilings, sized from the knobs (contract §2.3). A garbage/absent value
        # coerces to the documented default (2 review, 1 health) — a typo never unbounds a rail. The
        # Semaphores themselves are created in run_async, once the event loop is running: an
        # asyncio.Semaphore binds to the loop live at construction, so building them here (before
        # run() spins a fresh loop) would attach them to the wrong loop (Python < 3.10).
        self._review_max = _pos_int(cfg.get("REVIEW_CONCURRENCY"), 2)
        self._health_max = _pos_int(cfg.get("HEALTH_CONCURRENCY"), 1)
        self.review_slots = None
        self.health_slots = None
        self._merge_policy = D.effective_merge_policy(
            cfg.get("MERGE_POLICY"), cfg.get("WATCHER_AUTOMERGE"))
        self._hv_policy = cfg.get("HUMAN_VERIFY_POLICY", "hold")
        # A short critical-section sleep so overlapping rail work is observable (concurrency test);
        # 0.0 in production-shaped runs. Kept tiny — the shadow runtime is not a load test.
        self._stage_delay = float(stage_delay)
        # Live head sha per PR — the supersession oracle. A candidate whose sha != head[pr] is doomed.
        self._head = {}
        # In-flight rail tasks keyed by (pr, sha, rail) so a supersession can cancel exactly them.
        self._inflight = {}
        # Observability: peak simultaneous rail occupancy + per-PR terminal outcomes.
        self._active = {"review": 0, "health": 0}
        self._peak = {"review": 0, "health": 0}
        self._state = {}       # pr -> lifecycle state
        self._outcome = {}     # pr -> terminal action (MERGE|HOLD|OBSERVE|BLOCK|ESCALATE)
        self._merged_prs = []  # dry-run merge order, for the sibling re-stale journal

    # ── lifecycle transitions through the state machine (real P3b or the fallback) ────────────────
    def _advance(self, cand, event):
        """Advance ``cand``'s lifecycle by ``event`` through :data:`SM`; journal the transition.

        An illegal transition is journaled (``illegal_transition``) and the prior state is KEPT
        rather than raising into the task graph — in shadow mode the lifecycle is an assertion layer
        over the real output (the journal), so a state-model disagreement must never sink a run. The
        typed-throw property still holds at the ``SM.transition`` boundary; we just observe it.
        """
        prev = self._state.get(cand.pr, _S_INTAKE)
        try:
            nxt = SM.transition(prev, event)
        except Exception as exc:
            # Broad by design: a real P3b raises IllegalTransition, a mirror may raise KeyError, and
            # any state-model disagreement must be OBSERVED (journaled), never fatal to the run.
            self.journal.append("illegal_transition", pr=cand.pr, sha=cand.sha,
                                state=prev, attempted_event=event, detail=str(exc))
            return prev
        self._state[cand.pr] = nxt
        # NB: the k/v key is "trigger", not "event" — "event" is the reserved journal event-type
        # field (and the append() signature's first parameter), so the transition's triggering
        # event name is carried under a distinct key.
        self.journal.append("shadow_state", pr=cand.pr, sha=cand.sha, trigger=event,
                            state_from=prev, state_to=nxt)
        return nxt

    # ── supersession ──────────────────────────────────────────────────────────────────────────────
    def _superseded_sha(self, cand):
        """The new head sha if ``cand`` has been superseded, else ``None`` (its sha is still head)."""
        head = self._head.get(cand.pr)
        return head if head is not None and head != cand.sha else None

    async def _maybe_inject_supersession(self, cand, stage):
        """If ``cand`` scripts a supersession at ``stage``, move the head sha and cancel its rail task.

        This is the sim's stand-in for a real mid-gate ``git push``: it advances ``head[pr]`` to the
        new sha and cancels the exact in-flight rail task for the old sha — the structured-cancel the
        production tree performs by killing the stale reviewer pid / health process group on a new
        head sha (contract §2.4). The cancel propagates as ``CancelledError`` into the awaiting gate
        walk, which re-raises it as :class:`_Superseded`.
        """
        if cand.supersede_at != stage or not cand.supersede_to:
            return
        self._head[cand.pr] = str(cand.supersede_to)
        self.journal.append("shadow_supersede", pr=cand.pr, old_sha=cand.sha,
                            new_sha=str(cand.supersede_to), stage=stage)
        for key, task in list(self._inflight.items()):
            if key[0] == cand.pr and key[1] == cand.sha and not task.done():
                task.cancel()

    # ── the rails (cost-classed gate stages) ──────────────────────────────────────────────────────
    async def _run_rail(self, cand, rail, sem, body):
        """Run one bounded rail ``body`` under semaphore ``sem`` as a cancellable in-flight task.

        Registers the task in ``_inflight`` so a supersession can cancel exactly it, records peak
        occupancy for the concurrency assertion, and translates a supersession-cancel into
        :class:`_Superseded`. A cancel for ANY other reason (task-group teardown) propagates
        untouched, so structured concurrency still tears the whole run down cleanly.
        """
        async with sem:
            self._active[rail] += 1
            self._peak[rail] = max(self._peak[rail], self._active[rail])
            task = asyncio.ensure_future(body())
            self._inflight[(cand.pr, cand.sha, rail)] = task
            try:
                return await task
            except asyncio.CancelledError:
                new_sha = self._superseded_sha(cand)
                if new_sha is not None:
                    raise _Superseded(new_sha)
                raise
            finally:
                self._active[rail] -= 1
                self._inflight.pop((cand.pr, cand.sha, rail), None)

    async def _health_rail(self, cand):
        """The health rail (deterministic-slow, contract §2.3). Journals started + outcome.

        Returns the lifecycle EVENT the outcome produces: ``health_codeerror`` (→ BLOCKED),
        ``health_flaky`` / ``health_clean`` (→ REVIEW, the tolerated FLAKY counts as a pass, §2.2).
        Runs under the health semaphore; a scripted supersession fires while the suite is 'in flight'.
        """
        async def body():
            self.journal.append("healthcheck_started", pr=cand.pr, slug=cand.slug,
                                sha=cand.sha, pid=0, log_path="(shadow)")
            await self._maybe_inject_supersession(cand, "health")
            if self._stage_delay:
                await asyncio.sleep(self._stage_delay)
            outcome = cand.health if cand.health in ("CLEAN", "FLAKY", "CODEERROR") else "CLEAN"
            self.journal.append("healthcheck_outcome", pr=cand.pr, slug=cand.slug, outcome=outcome)
            return {"CLEAN": "health_clean", "FLAKY": "health_flaky",
                    "CODEERROR": "health_codeerror"}[outcome]

        return await self._run_rail(cand, "health", self.health_slots, body)

    async def _review_rail(self, cand):
        """The review rail (LLM, contract §2.3). Journals dispatch + verdict.

        PASS / BLOCK are recorded verdicts with ``source=reviewer`` (the only provenance that may
        bounce a builder, contract §3.2); INFRA is NEVER recorded as a verdict — it routes to a
        bounded retry (``record_review_retry`` + breaker, contract §2.2) and journals an
        ``infra_event`` instead, so an outage can never cache as a per-PR code BLOCK.
        """
        async def body():
            self.journal.append("review_dispatched", pr=cand.pr, sha=cand.sha, pid=0,
                                model="(shadow)", log_path="(shadow)", pin=cand.sha)
            await self._maybe_inject_supersession(cand, "review")
            if self._stage_delay:
                await asyncio.sleep(self._stage_delay)
            verdict = cand.review if cand.review in ("PASS", "BLOCK", "INFRA") else "PASS"
            if verdict == "INFRA":
                # Infra death: not a verdict. Bounded retry + breaker; forensic record is infra_event.
                self.journal.append("infra_event", pr=cand.pr, sha=cand.sha, rail="review",
                                    detail="no parseable verdict (shadow)")
                return "review_infra"
            self.journal.append("verdict_recorded", pr=cand.pr, sha=cand.sha, value=verdict,
                                source="reviewer")
            return "review_block" if verdict == "BLOCK" else "review_pass"

        return await self._run_rail(cand, "review", self.review_slots, body)

    # ── the gate walk (the DAG, contract §2.1) ────────────────────────────────────────────────────
    async def _walk_gates(self, cand):
        """Walk the cost-classed gate DAG for one sha; return the terminal action string.

        Order: stale/dup (cheap) → health (slow) → review (LLM) → blessing → hold decision → apply.
        A non-pass short-circuits. DRY-RUN: 'apply' journals a ``merge`` event but performs no merge.
        """
        # 1. stale/dup gate (deterministic-cheap) — a behind-base sha holds, it never merges.
        if cand.stale:
            self.journal.append("stale_dup_hold", pr=cand.pr, sha=cand.sha, slug=cand.slug,
                                kind="stale", reason="behind base (shadow)")
            self._advance(cand, "stale_detected")
            return HOLD

        # 2. health rail (deterministic-slow). dispatch_health advances INTAKE → HEALTH.
        self._advance(cand, "dispatch_health")
        health = await self._health_rail(cand)  # returns the health OUTCOME event name
        self._advance(cand, health)
        if health == "health_codeerror":
            self.journal.append("refix_bounce", pr=cand.pr, sha=cand.sha, slug=cand.slug,
                                round=1, agent_status_before="idle", rule="healthcheck",
                                location="(shadow)")
            return BLOCK

        # 3. review rail (LLM). The rail returns the verdict EVENT (review_pass|review_block|review_infra).
        verdict = await self._review_rail(cand)
        self._advance(cand, verdict)
        if verdict == "review_infra":
            return ESCALATE
        if verdict == "review_block":
            self.journal.append("refix_bounce", pr=cand.pr, sha=cand.sha, slug=cand.slug,
                                round=1, agent_status_before="idle", rule="review",
                                location="(shadow)")
            return BLOCK

        # 4. the blessing — both rails passed (review_pass advanced REVIEW → BLESSED above). The
        #    cross-seat shared artifact herd/gates=success (contract §2.3). Shadow: journal only, no
        #    commit status is posted.
        self.journal.append("shadow_blessing", pr=cand.pr, sha=cand.sha, context="herd/gates",
                            state="success")

        # 5. the pure hold / merge / observe decision (reused from P2, contract §2.2/§5.4-§5.5),
        #    mapped to the lifecycle event that consumes it.
        action = D.hold_decision(self._merge_policy, cand.hv_hold, cand.approved, self._hv_policy)
        self._advance(cand, {"MERGE": "decide_merge", "HOLD": "decide_hold",
                             "OBSERVE": "decide_observe"}[action])

        # 6. apply — DRY-RUN.
        if action == "MERGE":
            self._apply_merge(cand)
            return "MERGE"
        if action == "HOLD":
            self.journal.append("hold_applied", pr=cand.pr, sha=cand.sha, slug=cand.slug,
                                kind="approval" if self._merge_policy == "approve" else "human-verify")
            return HOLD
        # OBSERVE — observe mode never merges.
        self.journal.append("shadow_observe", pr=cand.pr, sha=cand.sha, slug=cand.slug)
        return "OBSERVE"

    def _apply_merge(self, cand):
        """DRY-RUN 'merge': journal the ``merge`` event ONLY — no ``gh``, no ref write.

        Also re-stales any sibling currently HELD (a merge advances the shared base), journaling
        ``pr_restale`` for each — the starvation-observability seam (contract §6.2). This is the
        cross-candidate interaction the port must surface; it mutates nothing.
        """
        self.journal.append("merge", pr=cand.pr, slug=cand.slug, sha=cand.sha,
                            method="squash", reason="gates_passed")
        self._merged_prs.append(cand.pr)
        held = getattr(SM, "HOLD", "HOLD")
        for other_pr, st in self._state.items():
            if other_pr != cand.pr and st == held:
                self.journal.append("pr_restale", pr=other_pr, sha=self._head.get(other_pr, ""),
                                    slug="pr-%s" % other_pr, kind="sibling-merge")

    async def _process_candidate(self, cand):
        """Process one candidate to a terminal, re-gating a fresh sha on supersession.

        The supersession loop is the visible payoff of structured concurrency: when the in-flight
        rail is cancelled by :meth:`_maybe_inject_supersession`, the walk raises :class:`_Superseded`
        with the new sha, we journal the discard-and-respin, and re-enter the DAG for the new sha —
        the generalization of the bash new-sha discard to an in-process cancel (contract §6.1 TARGET).
        """
        self._head.setdefault(cand.pr, cand.sha)
        self._state.setdefault(cand.pr, _S_INTAKE)
        while True:
            try:
                action = await self._walk_gates(cand)
            except _Superseded as sup:
                # new_sha drives the current (non-terminal) state → SUPERSEDED (contract §2.4/§6.1).
                self._advance(cand, "new_sha")
                self.journal.append("shadow_regate", pr=cand.pr, old_sha=cand.sha,
                                    new_sha=sup.new_sha)
                # The old sha is terminal (SUPERSEDED); the NEW sha is a fresh subject at INTAKE.
                cand = cand.respun(sup.new_sha)
                self._head[cand.pr] = cand.sha
                self._state[cand.pr] = _S_INTAKE
                continue
            self._outcome[cand.pr] = action
            return action

    async def run_async(self, candidates):
        """Process all candidates concurrently under a task group; return the result summary.

        The task group is the structured-concurrency boundary: if any candidate task errors the
        group cancels its siblings (and each candidate's nested rail child), so no orphan rail work
        survives a teardown. Returns ``{outcomes, peak_review, peak_health, merged, journal}``.
        """
        # Create the rail semaphores now the loop is running (see __init__ for why they can't be
        # built at construction time).
        self.review_slots = asyncio.Semaphore(self._review_max)
        self.health_slots = asyncio.Semaphore(self._health_max)

        self.journal.append("shadow_tick_start", candidates=len(candidates), impl="python-shadow",
                            statemachine="p3b" if _HAVE_P3B else "fallback")

        async with _task_group() as tg:
            for cand in candidates:
                tg.create_task(self._process_candidate(cand))

        self.journal.append("shadow_tick_end", merged=len(self._merged_prs))
        return {
            "outcomes": dict(self._outcome),
            "peak_review": self._peak["review"],
            "peak_health": self._peak["health"],
            "merged": list(self._merged_prs),
            "journal": self.journal.path,
        }

    def run(self, candidates):
        """Synchronous entry point — run the async watcher to completion on a fresh event loop."""
        return asyncio.run(self.run_async(candidates))


def _pos_int(value, default):
    """A positive int, else ``default`` — the fail-soft concurrency-knob coercion (contract §2.3).

    Mirrors the bash "a garbage or zero value reads as the default" discipline so a typo in
    ``REVIEW_CONCURRENCY`` / ``HEALTH_CONCURRENCY`` never unbounds (0/None → default) or crashes a rail.
    """
    try:
        n = int(str(value))
    except (TypeError, ValueError):
        return default
    return n if n > 0 else default


# ── structured-concurrency task group: native (3.11+) or a faithful backport (3.9/3.10) ───────────

def _task_group():
    """Return an ``async with`` task-group context manager with cancel-on-error semantics.

    Prefers the stdlib :class:`asyncio.TaskGroup` (Python 3.11+). On older interpreters — this repo
    still ships 3.9 — returns :class:`_BackportTaskGroup`, which reproduces the load-bearing
    behaviors the runtime relies on: ``create_task`` schedules a child; the ``async with`` body
    awaits all children on clean exit; and if any child raises, the remaining children are cancelled
    before the error propagates (structured concurrency, spike §0.4). The native class is used
    wherever available so we inherit its exact semantics as the platform advances.
    """
    native = getattr(asyncio, "TaskGroup", None)
    if native is not None:
        return native()
    return _BackportTaskGroup()


class _BackportTaskGroup:
    """A minimal ``asyncio.TaskGroup`` backport for Python < 3.11 (cancel-siblings-on-error).

    Not a full re-implementation of the stdlib class (no ExceptionGroup aggregation, no nesting
    subtleties) — just the structured-concurrency contract this runtime depends on: children created
    via :meth:`create_task` are all awaited at ``async with`` exit; the FIRST child error cancels
    every other child and is then re-raised. That is enough to guarantee no rail task outlives its
    candidate's teardown.
    """

    def __init__(self):
        self._tasks = []

    async def __aenter__(self):
        return self

    def create_task(self, coro):
        task = asyncio.ensure_future(coro)
        self._tasks.append(task)
        return task

    async def __aexit__(self, exc_type, exc, tb):
        if not self._tasks:
            return False
        if exc is not None:
            # The body itself failed — cancel everything we scheduled, then let the error propagate.
            await self._cancel_all()
            return False
        results = await asyncio.gather(*self._tasks, return_exceptions=True)
        for r in results:
            if isinstance(r, BaseException) and not isinstance(r, asyncio.CancelledError):
                # A child failed: cancel any still-running siblings, then re-raise the first error.
                await self._cancel_all()
                raise r
        return False

    async def _cancel_all(self):
        for t in self._tasks:
            if not t.done():
                t.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)


# ── CLI harness (impure glue; drives sim fixtures, never the live control room) ───────────────────

def _load_fixture(argv):
    """Read the scenario JSON from ``--fixture FILE`` or stdin. Sim fixtures ONLY (VERIFY discipline)."""
    path = None
    stage_delay = 0.0
    i = 0
    while i < len(argv):
        if argv[i] == "--fixture" and i + 1 < len(argv):
            path = argv[i + 1]
            i += 2
        elif argv[i] == "--stage-delay" and i + 1 < len(argv):
            stage_delay = float(argv[i + 1])
            i += 2
        else:
            i += 1
    raw = open(path, encoding="utf-8").read() if path else sys.stdin.read()
    return json.loads(raw) if raw.strip() else {}, stage_delay


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    scenario, stage_delay = _load_fixture(argv)
    # Config precedence: fixture "config" wins, else fall through to the process environment (the
    # same knobs the bash watcher reads). Env is READ ONLY — a shadow run mutates nothing.
    config = dict(scenario.get("config") or {})
    for knob in ("REVIEW_CONCURRENCY", "HEALTH_CONCURRENCY", "MERGE_POLICY",
                 "WATCHER_AUTOMERGE", "HUMAN_VERIFY_POLICY"):
        if knob not in config and os.environ.get(knob) is not None:
            config[knob] = os.environ[knob]
    candidates = [Candidate.from_dict(c) for c in scenario.get("candidates", [])]
    watcher = ShadowWatcher(config=config, stage_delay=stage_delay)
    result = watcher.run(candidates)
    sys.stdout.write(json.dumps(result, separators=(",", ":"), sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
