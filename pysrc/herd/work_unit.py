"""herd.work_unit — the PYTHON-side work-unit adapter interface (HERD-403, Phase 3c of
docs/spikes/work-unit-abstraction.md's post-port amendment, §9).

WHY THIS MODULE EXISTS NOW, NOT IN P3/P3b: the spike's original phased migration (§5) planned to
extract a `git-pr` adapter and a `wunit_*` facade IN BASH (Phases 3/3b, HERD-398/HERD-401) and only
later add a python adapter once/if the engine ported. Between the spike landing and Phase 3b, a
SEPARATE epic (HERD-300, the engine port) already replaced the bash tick's production spine with
:mod:`herd.live_runtime` — so by the time Phase 3b shipped, `do_merge` (the function the bash git-pr
adapter wraps) had ZERO production call sites left (HERD-401's filed finding). The bash facade
(`scripts/herd/work-unit.sh` + `scripts/herd/work-units/git-pr.sh`) is real, tested, and stays the
REFERENCE MODEL the spike's interface was designed against — it is exercised by the sim scenario
suite and the hermetic bash tests — but the LIVE seam is this python engine. This module is the
adapter interface's python side: the same five ops (open/gate/apply/reconcile/teardown) plus the two
queries (list_open/inspect), landed as a SKELETON that WRAPS the existing live_runtime pieces rather
than reimplementing them, exactly as the bash facade wraps `do_merge`/`reconcile_backlog`/`_reap_slug`
instead of duplicating them.

SKELETON, NOT WIRED IN (byte-identical checklist, spike §5): nothing in :mod:`herd.live_runtime`
imports or calls this module. ``LiveTick`` still talks to ``_GraphQLDiscovery``/``LiveGates``/
``LiveActuator`` directly, by name, exactly as it did before this file existed. Landing this module
changes NO observable behavior of the live engine — it is additive surface a future phase wires a
call site through, not a call site itself.

Stdlib-only (the P1 packaging rule).
"""

import os

from herd.live_runtime import LiveGates, LiveActuator, _GraphQLDiscovery, WAIT
from herd.shadow_journal import _journal_unit_ref

# ── the shared vocabulary (spike §2.2) ──────────────────────────────────────────────────────────────
# Plain __slots__ classes, not @dataclass — matching live_runtime.py's own value-type convention
# (LiveCandidate, WakeResult) rather than introducing a second style for one module.


class WorkUnit:
    """Spike §2.2 ``unit`` — identity + kind-specific artifact for ONE delivery attempt.

    ``unit_id`` is the namespaced ref (:func:`herd.shadow_journal._journal_unit_ref`, e.g.
    ``"git-pr:42"``) — the SAME format the HERD-397 dual-write already stamps into every PR-carrying
    journal event, so a unit's identity and its journal footprint can never format-drift apart.
    """

    __slots__ = ("unit_id", "kind", "slug", "revision", "item_ref", "artifact")

    def __init__(self, unit_id, kind, slug="", revision="", item_ref=None, artifact=None):
        self.unit_id = str(unit_id)
        self.kind = str(kind)
        self.slug = str(slug or "")
        self.revision = str(revision or "")
        self.item_ref = item_ref
        self.artifact = dict(artifact or {})


class GateResult:
    """Spike §2.2 ``gate_result``. ``status`` is one of ``pass|hold|block|wait|error`` — the rail
    readiness a work-unit's ``gate`` op reports. This is deliberately narrower than the full merge
    DECISION (:mod:`herd.decisions` still owns human-verify / approve / observe holds verbatim,
    reused unchanged) — the spike's gate op is the rail-readiness leg only (§2.2's own row)."""

    __slots__ = ("status", "reason", "holds", "evidence")

    def __init__(self, status, reason="", holds=None, evidence=None):
        self.status = str(status)
        self.reason = str(reason or "")
        self.holds = list(holds or [])
        self.evidence = dict(evidence or {})


class ApplyResult:
    """Spike §2.2 ``apply_result``. ``status`` is one of ``applied|refused|already|error``."""

    __slots__ = ("status", "reason")

    def __init__(self, status, reason=""):
        self.status = str(status)
        self.reason = str(reason or "")


class UnsupportedWorkUnitKind(ValueError):
    """Raised by :func:`resolve_adapter` for any kind besides the ones this build actually ships.

    Mirrors ``wunit_resolve_adapter``'s HARD refusal (``scripts/herd/work-unit.sh``) — the facade
    names the one kind it implements and refuses anything else outright. That is a DIFFERENT check
    than the boot-time one ``agent-watch.sh`` runs on ``WORK_UNIT_KIND`` at startup, which SOFTENS an
    unsupported value to ``git-pr`` with a loud warning so the resident watcher process keeps running
    through a config typo. This module has no resident process to protect — a caller resolving an
    adapter is asking a direct question ("give me kind K"), so an unshipped kind refuses loudly
    instead of silently handing back a different adapter than the one asked for.
    """


# ── the interface (spike §2.2): five ops + two queries, one method per op ──────────────────────────

class WorkUnitAdapter:
    """Base adapter: every op raises :class:`NotImplementedError`, NAMED with the op and the
    adapter's own kind, so a half-built adapter fails loud rather than silently no-op-ing on an op
    nobody wrote yet. A concrete adapter overrides only the ops it actually implements."""

    kind = None

    def _unimplemented(self, op):
        raise NotImplementedError("%s adapter does not implement %r yet" % (self.kind, op))

    def open(self, ctx):
        """Publish a candidate delivery from a finished builder. → unit"""
        self._unimplemented("open")

    def list_open(self):
        """The tick's candidate set. → [unit…]"""
        self._unimplemented("list_open")

    def inspect(self, unit):
        """Read one unit's revision/state/body/labels. → dict"""
        self._unimplemented("inspect")

    def gate(self, unit, revision):
        """Rail readiness for this revision. → :class:`GateResult`"""
        self._unimplemented("gate")

    def apply(self, unit, revision):
        """Land the unit (merge-or-apply). → :class:`ApplyResult`"""
        self._unimplemented("apply")

    def reconcile(self, unit):
        """Mark the linked work item done."""
        self._unimplemented("reconcile")

    def teardown(self, unit):
        """Release isolation resources for this unit."""
        self._unimplemented("teardown")


class GitPrAdapter(WorkUnitAdapter):
    """The git-pr adapter body — WRAPS the existing python engine-core pieces; it reimplements
    NONE of them (spike §9's own invariant, ported from the bash facade's "one-line delegation"
    rule). Each op below either delegates to an already-existing live_runtime class/function or is
    left NOT IMPLEMENTED with a docstring naming exactly why, so the skeleton is honest about which
    legs of the spike's interface the python engine actually has today:

    ``open``
        NOT IMPLEMENTED. ``gh pr create`` is run by the BUILDER's own shell
        (``herd-feature.sh``/``herd-quick.sh``, ``PR_CREATE_CMD``) — a lane concern, not a watcher
        engine-core concern. The python engine core is watcher-tick-only; it has no opening leg to
        wrap, exactly as the bash facade's own ``wunit_open`` has no *function* to delegate to
        besides ``gh`` itself (it is the one op the bash facade ALSO just passes through raw).
    ``list_open``
        :class:`herd.live_runtime._GraphQLDiscovery` — already, in its own docstring, "a thin
        adapter" over :func:`herd.live_runtime.discover_via_graphql`. This method is a one-line
        delegation to it.
    ``inspect``
        The candidate :class:`herd.live_runtime.LiveCandidate` discovery already produced — the
        batched GraphQL query bundles every inspect-shaped field (state, body-adjacent labels,
        review decision, merge status) into the SAME round-trip as ``list_open``, so there is no
        separate fetch for git-pr to wrap.
    ``gate``
        :class:`herd.live_runtime.LiveGates`.health + .review, composed into ONE spike-shaped
        :class:`GateResult`. Deliberately excludes the merge-POLICY holds (human-verify / approve /
        observe) — :mod:`herd.decisions` already owns those verbatim and the spike's gate op is the
        rail-readiness leg only.
    ``apply``
        :class:`herd.live_runtime.LiveActuator`.merge — the merge-or-apply leg, unchanged. (Reap is
        the separate ``teardown`` op below, not folded into apply, matching the spike's own op
        split.)
    ``reconcile`` / ``teardown``
        NOT IMPLEMENTED. Post-port (HERD-401's filed finding, spike §9): these two legs stay BASH's
        job — ``agent-watch.sh``'s ``_pms_reconcile_one`` and ``_startup_reap_sweep`` call
        ``wunit_reconcile``/``wunit_teardown`` (→ ``reconcile_backlog``/``_reap_slug``) for EVERY
        merge, regardless of which engine actuated it. ``LiveActuator.reap`` only covers the
        same-tick "this tick just merged it" case and is explicit in its own docstring that the
        cross-seat reap authority is deliberately the bash sweep, not this actuator. A python
        reconcile/teardown leg is future work this build does not ship.
    """

    kind = "git-pr"

    def __init__(self, home=None, journal=None, state=None, config=None, repo=None,
                 gates=None, actuator=None, discovery=None):
        self.home = home
        self.journal = journal
        self.state = state
        self.config = config or {}
        self.repo = repo
        # Each collaborator is injectable (the same seam LiveTick already offers between
        # Live*/Fixture* twins) so a caller — or a test — can hand this adapter a hermetic
        # FixtureGates/DryRunActuator instead of the real, subprocess-shelling live pieces.
        self._gates = gates if gates is not None else (
            LiveGates(home, state, journal, self.config) if (home and state and journal) else None)
        self._actuator = actuator if actuator is not None else (
            LiveActuator(home, journal, self.config) if (home and journal) else None)
        self._discovery = discovery if discovery is not None else _GraphQLDiscovery(self.config, repo)

    def open(self, ctx):
        self._unimplemented("open")

    def list_open(self):
        return self._discovery.discover()

    def inspect(self, unit):
        return unit

    def gate(self, unit, revision):
        cand = unit
        health = self._gates.health(cand)
        review = self._gates.review(cand)
        evidence = {"health": health, "review": review}
        if health == "CODEERROR":
            return GateResult(status="block", reason="health CODEERROR", evidence=evidence)
        if review == "BLOCK":
            return GateResult(status="block", reason="review BLOCK", evidence=evidence)
        if review == "INFRA":
            return GateResult(status="error", reason="review INFRA-FAIL", evidence=evidence)
        if health == WAIT or review == WAIT:
            return GateResult(status="wait", reason="rail dispatch/collect in flight", evidence=evidence)
        if health in ("CLEAN", "FLAKY") and review == "PASS":
            return GateResult(status="pass", reason="health+review both green", evidence=evidence)
        return GateResult(status="wait", reason="rail outcome not yet terminal", evidence=evidence)

    def apply(self, unit, revision):
        if self._actuator.merge(unit):
            return ApplyResult(status="applied", reason="gates_passed")
        return ApplyResult(status="refused", reason="see merge_refused/merge_gh_unreadable journal event")

    def reconcile(self, unit):
        self._unimplemented("reconcile")

    def teardown(self, unit):
        self._unimplemented("teardown")

    def to_unit(self, cand):
        """Build a spike-shaped :class:`WorkUnit` from a discovered/injected candidate."""
        return WorkUnit(
            unit_id=_journal_unit_ref(self.kind, cand.pr),
            kind=self.kind,
            slug=cand.slug,
            revision=cand.sha,
            item_ref=None,
            artifact={"pr_number": cand.pr, "base_ref": cand.base},
        )


# ── resolve: WORK_UNIT_KIND selects the adapter (spike §9) ─────────────────────────────────────────

SUPPORTED_KINDS = ("git-pr",)
DEFAULT_KIND = "git-pr"

_ADAPTERS = {"git-pr": GitPrAdapter}


def resolve_adapter(kind=None, **kwargs):
    """Resolve the :class:`WorkUnitAdapter` for ``kind`` — else ``kwargs["config"]["WORK_UNIT_KIND"]``
    (the same config dict :func:`herd.live_runtime._config_from_env` assembles), else the
    ``WORK_UNIT_KIND`` env var, else :data:`DEFAULT_KIND` ("git-pr"). Any remaining ``kwargs`` (home,
    journal, state, config, repo, gates, actuator, discovery) pass straight through to the adapter's
    constructor.

    A kind this build does not ship raises :class:`UnsupportedWorkUnitKind` — a HARD refusal, mirroring
    ``wunit_resolve_adapter`` (``scripts/herd/work-unit.sh``), not ``agent-watch.sh``'s boot-time soft
    fallback (see that class's docstring for why the two differ).
    """
    config = kwargs.get("config") or {}
    resolved = kind or config.get("WORK_UNIT_KIND") or os.environ.get("WORK_UNIT_KIND") or DEFAULT_KIND
    adapter_cls = _ADAPTERS.get(resolved)
    if adapter_cls is None:
        raise UnsupportedWorkUnitKind(
            "work-unit kind %r is not supported yet — only %s ships today (P4 adds a second kind; "
            "HERD-395/HERD-398/HERD-403)" % (resolved, ", ".join(SUPPORTED_KINDS)))
    return adapter_cls(**kwargs)
