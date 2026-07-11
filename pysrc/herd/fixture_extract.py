"""herd.fixture_extract — the P3e SCENARIO→FIXTURE BRIDGE (HERD-319, EPIC HERD-300).

The last P3 integration seam. P3a (:mod:`herd.parity`, ``scripts/herd/sim/parity-run.sh``) diffs
two journal streams; P3c (:mod:`herd.shadow_runtime`) is the Python shadow watcher that emits one
of those streams from a ``{config, candidates}`` fixture. What was MISSING between them: a way to
turn a REAL sim run into that fixture, so the shadow engine processes THE SAME SUBJECTS the bash
engine just did and the parity diff is a genuine head-to-head — not a self-diff of one engine.

This module is that bridge. It reads the REAL journal a sim scenario emitted (the union stream
``parity-run.sh`` collects, ``journal-real.jsonl``) and folds it into a shadow-runtime fixture:
one :class:`herd.shadow_runtime.Candidate` per PR that appeared as a GATE SUBJECT, with the
scripted rail outcomes (health / review / stale / hold) it carried. ``parity-run.sh --shadow auto``
then feeds that fixture to ``python3 -m herd.shadow_runtime`` and diffs the shadow stream against
the real one.

HONEST BY CONSTRUCTION (the item's non-negotiable — "a real divergence list is a SUCCESS
deliverable, never force a green by over-canonicalizing"). This extractor's job is only to give the
shadow engine the same INPUTS (subjects + the per-candidate gate schedule + the non-candidate
subsystem lists); it never rewrites the real stream to manufacture agreement. Oracle v2 (HERD-325,
the P3i parity finish line) closed the non-candidate families on the sandbox scenario — ``main_health``
(§3.4) and the ``push_hold_*`` lifecycle (§5.4) fold into ordered fixture lists the shadow replays.
P3j (HERD-335) then closes the CANDIDATE-PASS vocabulary the sandbox-CONCURRENCY scenario drives: the
per-candidate GATE SCHEDULE (which stages each subject actually walked — ``skip_health`` entry, the
``healthcheck_attempted`` / ``healthcheck_cache_hit`` caching family §3.4, ``stop_after`` for
injected review-only subjects, the ``symbol_index_refresh`` / ``reap`` post-merge housekeeping), and
the ``main_ff`` / ``main_freshness`` reconcile (§3.4) + the ``merge_fairness_priority`` /
``pr_restale`` / ``pr_starvation`` fairness family (§6.2) as VERBATIM-replay lists. Every event
family and count now matches on the concurrency scenario; the honest residual is the candidate-pass
EMISSION ORDER (the shadow's per-candidate structured-concurrency pipeline vs the bash watcher's
tick-synchronized waves) and the ``infra_breaker_*`` review-breaker internal state (§3.3), which stay
in the excluded tally.

EXTRACTION RULES — every rule cites the engine contract section (``docs/engine-contract.md``) that
gives it meaning, so each mapping from a real event to a candidate field is auditable:

  * CANDIDATE SUBJECTS (contract §2.1, the candidate pass). Only the events in
    :data:`CANDIDATE_EVENTS` establish a PR as a gate subject. A journal event that is neither a
    candidate signal nor one of the MODELED non-candidate families (panels / steps / gate_status /
    ``main_health`` §3.4 / ``push_hold_*`` §5.4) — e.g. ``infra_breaker_*`` (§3.3),
    ``symbol_index_refresh`` / ``reap`` / ``cost`` — is an AUXILIARY engine event, counted in the
    excluded tally, never fabricated into a candidate. Dropping those is honest SCOPING, not
    canonicalization.
  * MAIN-HEALTH ← ``main_health`` ticks (contract §3.4), folded by (pr, sha) into an ordered
    ``main_healths`` list: the dispatch row + the green/red result (with ``failed`` / ``since`` on a
    red). NOT a gate subject; modeled, not excluded (oracle v2, HERD-325).
  * PUSH-HOLD ← the ``push_hold_awaiting`` / ``push_hold_approved`` / ``push_hold_resumed`` lifecycle
    (contract §5.4), folded by (slug, sha) into an ordered ``push_holds`` list. Modeled, not excluded.
  * HEALTH ← ``healthcheck_outcome.outcome`` (CLEAN|FLAKY|CODEERROR, contract §2.2 / §3.4), with
    ``healthcheck_cache_hit.outcome`` and ``healthcheck_attempted.result`` as fallbacks (§3.4).
  * REVIEW ← ``verdict_recorded.value`` (PASS|BLOCK) but ONLY when ``source == reviewer`` — the sole
    provenance that may bounce a builder (contract §3.2). A non-reviewer verdict is ignored. An
    ``infra_event`` with ``rail == review`` and no reviewer verdict maps to INFRA (a bounded retry,
    never a cached BLOCK — contract §2.2 / §3.3).
  * STALE ← ``stale_dup_hold`` (kind=stale, §2.1 step 1) — a behind-base sha holds, it never merges.
    (``pr_restale`` / ``pr_starvation`` are NO LONGER a candidate stale signal: they are the
    merge-FAIRNESS family, folded into the verbatim ``fairness`` replay list below — HERD-335.)
  * GATE SCHEDULE (contract §2.1 / §2.4 / §3.4, HERD-335) ← which stages each candidate walked:
    ``skip_health`` (a review-injected subject with no ``healthcheck_started``); ``health_attempted``
    / ``cache_hit`` (the caching family); ``stop_after`` (``"verdict"`` = a planted verdict recorded
    but never dispatched/merged, ``"dispatch"`` = a reviewer dispatched then torn down before a
    verdict); ``pin_soft`` (an inline review-rail soft-pin note); ``post_merge`` (``symbol_index_refresh``
    / ``reap`` housekeeping). Each is emitted only when non-default, so a plain candidate is unchanged.
  * FAIRNESS ← ``merge_fairness_priority`` / ``pr_restale`` / ``pr_starvation`` (§6.2) and MAIN-EVENTS
    ← ``main_ff`` / ``main_freshness`` (§3.4) fold into ordered VERBATIM-replay lists (``fairness`` /
    ``main_events``) — NOT gate subjects, NOT excluded, re-emitted field-for-field in journal order.
  * HV_HOLD ← ``hold_applied`` (kind=human-verify) or ``human_verify_policy`` (contract §5.4).
  * APPROVED ← ``approval_recorded`` (state=approved, contract §5.5).
  * SHA ← the sha from the LAST candidate-signal event that carried one (input order is the
    deterministic, path-sorted union ``parity-run.sh`` builds), so a lap-bumped or merged sha wins
    over an earlier one — the sha-keying spine (contract §2.4).
  * MERGE POLICY (config) ← ``auto`` when any ``merge`` with ``reason=gates_passed`` is present
    (the run automerged, contract §5.5), else left unset for the shadow runtime to resolve from its
    own default. A ``--config KEY=VALUE`` override always wins.

Stdlib-only (the P1 packaging rule, ``pysrc/herd/__init__.py``): no external deps. ZERO model
calls, no config-key reads, no mutation of engine state — a pure reader that only ever writes a
fixture to stdout / ``--out``. Unit-driven by ``tests/test-py-fixture-extract.sh``.

CLI:  ``python3 -m herd.fixture_extract <journal.jsonl|-> [--out FILE] [--config K=V]... [--pretty]``
Exit: 0 = fixture written · 2 = INFRA (unreadable / invalid-JSON journal — loud, never a silent
empty fixture; mirrors :mod:`herd.parity`'s exit contract, reusing its loader).
"""

import json
import sys

from herd.parity import ParityError, load_events

# The candidate-pass events (contract §2.1): the ONLY events that establish a PR as a gate subject.
# Anything not here is auxiliary and is excluded (and tallied), never turned into a candidate.
CANDIDATE_EVENTS = frozenset((
    "healthcheck_started", "healthcheck_outcome", "healthcheck_attempted", "healthcheck_cache_hit",
    "review_dispatched", "verdict_recorded", "infra_event", "symbol_index_refresh", "reap",
    "stale_dup_hold", "refix_bounce", "hold_applied", "human_verify_policy", "approval_recorded",
    "merge", "merge_refused_sha_moved",
))

# ── staged-subsystem events (HERD-304, P3 parity burn-down) ──────────────────────────────────────
# Beyond the candidate pass, the sim scenario drives three MORE journalled subsystems the shadow
# engine now models (herd.shadow_runtime): the review PANEL, the pipeline STEPS runner, and the
# herd/gates commit-STATUS post. Their events are folded into ordered fixture lists (panels / steps /
# gate_statuses) rather than into candidates — they are NOT gate subjects (contract §2.1), so they
# are neither candidates nor auxiliary-excluded; they carry their own scenario state to the shadow.
#
# PANEL-EXCLUSIVE vs SHARED review bookkeeping: a review PANEL is established ONLY by a per-panelist
# verdict or the panel fold — the events a single-reviewer dispatch never emits. review_log_retained
# and review_pin_soft are emitted on EVERY review path (panel or lone reviewer, herd-review.sh:541/
# 585), so they only ATTACH to a panel that materializes; a lone pair with no panelist stays a plain
# review-rail note (excluded), never a spurious 0-panelist panel (which would over-emit vs the bash).
PANEL_ANCHOR_EVENTS = frozenset(("review_panelist_verdict", "review_panel_folded"))
PANEL_ATTACH_EVENTS = frozenset(("review_log_retained", "review_pin_soft"))
STEP_EVENTS = frozenset((
    "step_run", "step_hold_awaiting", "step_hold_approved", "step_hold_released",
))

# ── non-candidate engine families (HERD-325, P3i oracle v2) ───────────────────────────────────────
# main_health (the post-merge default-branch tripwire, contract §3.4) and the push-gate hold
# lifecycle (contract §5.4) are REAL engine families the shadow now MODELS. Like panels/steps/gate
# statuses they fold into ordered fixture lists (main_healths / push_holds), NOT into candidates
# (they are not gate subjects, §2.1) and NOT into the excluded tally. Before P3i these were auxiliary
# and dropped; the shadow engine now emits them, so the head-to-head diff sees them on both sides.
PUSH_HOLD_EVENTS = frozenset((
    "push_hold_awaiting", "push_hold_approved", "push_hold_resumed",
))

# ── verbatim-replay engine families (HERD-335, P3j concurrency-parity burn-down) ──────────────────
# The MERGE-FAIRNESS reorder + starvation counter (merge_fairness_priority / pr_restale /
# pr_starvation, contract §6.2) and the MAIN fast-forward / freshness reconcile (main_ff /
# main_freshness, §3.4) are REAL engine families that are NOT gate subjects — a fairness re-stale is a
# fixed-point of the scheduler, not a health/review verdict on one sha. Like main_health / push_hold
# they fold into ordered lists the shadow replays VERBATIM (fairness / main_events), NOT into
# candidates and NOT into the excluded tally. Before P3j pr_restale/pr_starvation were mapped to a
# candidate `stale` flag (which emitted a spurious stale_dup_hold) and merge_fairness_priority /
# main_ff / main_freshness were dropped as auxiliary; the shadow now emits all five, so the
# head-to-head diff sees them family-for-family.
FAIRNESS_EVENTS = frozenset((
    "merge_fairness_priority", "pr_restale", "pr_starvation",
))
MAIN_EVENT_EVENTS = frozenset((
    "main_ff", "main_freshness",
))
# The non-volatile fields dropped from a verbatim replay (ts is re-stamped; pid/log_path/dir are the
# volatile categories the parity oracle canonicalizes anyway — carrying them would only add noise).
_REPLAY_DROP_KEYS = frozenset(("ts", "pid", "log_path", "dir", "path"))

# The four health outcomes (contract §2.2); anything else coerces to CLEAN like the shadow runtime.
_HEALTH_OUTCOMES = frozenset(("CLEAN", "FLAKY", "CODEERROR"))
# The recorded review verdicts (contract §2.2 / §3.2); INFRA is derived separately (never recorded).
_REVIEW_VERDICTS = frozenset(("PASS", "BLOCK"))


class _CandidateFold:
    """The mutable per-PR accumulator that folds a PR's candidate-pass events into one candidate.

    One instance per PR; :meth:`observe` is fed that PR's events in input order, then
    :meth:`to_dict` emits the shadow-runtime candidate. Fields default to the shadow ``Candidate``
    defaults (health CLEAN, review PASS, the flags false), so an absent signal means "the rail was
    not exercised / implicitly passed", matching the shadow runtime's own defaulting.
    """

    __slots__ = ("pr", "sha", "slug", "health", "review", "stale", "hv_hold", "approved",
                 "_saw_reviewer_verdict", "_saw_health_started", "_saw_health_attempted",
                 "_saw_cache_hit", "_saw_review_dispatched", "_saw_merge", "_saw_post_merge",
                 "pin_soft", "pin_reason")

    def __init__(self, pr):
        self.pr = pr
        self.sha = ""
        self.slug = ""
        self.health = None            # None until a health event is seen (→ CLEAN default at emit)
        self.review = None            # None until a reviewer verdict / infra is seen (→ PASS default)
        self.stale = False
        self.hv_hold = False
        self.approved = False
        self._saw_reviewer_verdict = False
        # ── the per-candidate GATE SCHEDULE signals (HERD-335, P3j) ──────────────────────────────
        # Which stages the real run actually walked, so the shadow re-walks the SAME schedule instead
        # of a one-size health→review→merge DAG (see herd.shadow_runtime.Candidate).
        self._saw_health_started = False      # a real healthcheck RAN (else the subject entered at review)
        self._saw_health_attempted = False    # the caching family's first-run marker (§3.4)
        self._saw_cache_hit = False           # a sha-keyed cache hit on a re-gate (§2.4 / §3.4)
        self._saw_review_dispatched = False   # a reviewer was actually dispatched (vs a planted verdict)
        self._saw_merge = False               # the candidate reached merge (the full pipeline)
        self._saw_post_merge = False          # post-merge housekeeping ran (symbol_index_refresh / reap)
        self.pin_soft = False                 # a review-rail soft-pin note fired inline (set post-fold)
        self.pin_reason = ""                  # its reason (a semantic field, carried verbatim)

    def observe(self, ev, obj):
        # SHA (contract §2.4): the last candidate-signal sha wins (lap-bumped / merged sha over an
        # earlier one). Input order is parity-run.sh's deterministic path-sorted union.
        sha = obj.get("sha")
        if isinstance(sha, str) and sha:
            self.sha = sha
        slug = obj.get("slug")
        if isinstance(slug, str) and slug:
            self.slug = slug

        if ev == "healthcheck_started":                       # a real suite ran (gate schedule §2.1)
            self._saw_health_started = True
        elif ev == "healthcheck_outcome":                     # contract §2.2 / §3.4
            self.health = _norm_health(obj.get("outcome"))
        elif ev == "healthcheck_cache_hit":                   # sha-keyed cache hit (§2.4 / §3.4)
            self._saw_cache_hit = True
            if self.health is None:
                self.health = _norm_health(obj.get("outcome"))
        elif ev == "healthcheck_attempted":                   # the caching family's first-run marker
            self._saw_health_attempted = True
            if self.health is None:
                self.health = _norm_health(obj.get("result"))
        elif ev == "review_dispatched":                       # a reviewer was actually dispatched
            self._saw_review_dispatched = True
        elif ev == "verdict_recorded":                        # contract §3.2: reviewer provenance only
            if obj.get("source") == "reviewer":
                val = str(obj.get("value", "")).upper()
                if val in _REVIEW_VERDICTS:
                    self.review = val
                    self._saw_reviewer_verdict = True
        elif ev == "infra_event":                             # contract §3.3: INFRA, never a BLOCK
            if obj.get("rail") == "review" and not self._saw_reviewer_verdict:
                self.review = "INFRA"
        elif ev == "stale_dup_hold":                          # contract §2.1 step 1
            self.stale = True
        elif ev == "merge":                                   # the full pipeline reached merge (§5.5)
            self._saw_merge = True
        elif ev in ("symbol_index_refresh", "reap"):          # post-merge housekeeping (§3.4)
            self._saw_post_merge = True
        elif ev == "hold_applied":                            # contract §5.4
            if str(obj.get("kind", "")).startswith("human"):
                self.hv_hold = True
        elif ev == "human_verify_policy":                     # contract §5.4
            self.hv_hold = True
        elif ev == "approval_recorded":                       # contract §5.5
            if obj.get("state") == "approved":
                self.approved = True

    def _stop_after(self):
        """Where the candidate's real event stream stopped — the gate-schedule terminal (§2.1).

        A merge means the FULL pipeline ran (None). Otherwise a recorded reviewer verdict that never
        merged is a planted, review-only subject (``"verdict"``); a bare review dispatch with no
        verdict is a torn-down reviewer probe (``"dispatch"``). None otherwise (a health-only subject
        walks the default DAG).
        """
        if self._saw_merge:
            return None
        if self._saw_reviewer_verdict:
            return "verdict"
        if self._saw_review_dispatched:
            return "dispatch"
        return None

    def to_dict(self):
        """The shadow-runtime candidate dict — explicit health/review, flags only when set."""
        cand = {"pr": self.pr, "sha": self.sha}
        if self.slug:
            cand["slug"] = self.slug
        cand["health"] = self.health or "CLEAN"
        cand["review"] = self.review or "PASS"
        if self.stale:
            cand["stale"] = True
        if self.hv_hold:
            cand["hv_hold"] = True
        if self.approved:
            cand["approved"] = True
        # ── gate-schedule fields (HERD-335): emitted ONLY when non-default, so a candidate that walked
        #    the plain health→review→merge DAG folds to a BYTE-IDENTICAL dict (every pre-P3j fixture).
        # A subject that recorded a review signal but never ran a healthcheck entered at the review gate.
        saw_review = self._saw_review_dispatched or self._saw_reviewer_verdict
        if saw_review and not self._saw_health_started:
            cand["skip_health"] = True
        if self._saw_health_attempted:
            cand["health_attempted"] = True
        if self._saw_cache_hit:
            cand["cache_hit"] = True
        stop_after = self._stop_after()
        if stop_after:
            cand["stop_after"] = stop_after
        if self._saw_post_merge:
            cand["post_merge"] = True
        if self.pin_soft:
            cand["pin_soft"] = True
            cand["pin_reason"] = self.pin_reason
        return cand


class _PanelFold:
    """Fold one PR's review-PANEL events into a shadow-runtime panel entry (herd-review.sh).

    Accumulates the per-panelist verdict PROVENANCE (ref/driver/model/verdict/reason, contract
    §3.2), the log-retention ``keep`` and soft-pin note, and the fold POLICY. The policy is read from
    a ``review_panel_folded`` when the panel folded to a verdict; a panel that instead emitted a
    herd-review ``infra_event`` while still carrying a reporting (PASS/BLOCK) panelist can only have
    folded under ``all-pass`` (any-block would have let the clean co-panelist through), so that case
    is inferred — the shadow runtime re-derives the fold from policy + panelists (never replayed).
    """

    __slots__ = ("pr", "slug", "sha", "keep", "pin_mode", "pin_reason", "policy", "refs",
                 "panelists", "_saw_infra")

    def __init__(self, pr):
        self.pr = pr
        self.slug = ""
        self.sha = ""
        self.keep = None
        self.pin_mode = None
        self.pin_reason = None
        self.policy = None
        self.refs = None
        self.panelists = []
        self._saw_infra = False

    def observe(self, ev, obj):
        slug = obj.get("slug")
        if isinstance(slug, str) and slug:
            self.slug = slug
        sha = obj.get("sha")
        # Require a NON-EMPTY sha, consistent with _CandidateFold / _StepFold: a late
        # review_log_retained/review_pin_soft carrying an explicit empty "sha" must not clobber the
        # panel's real sha back to "" and desync its subject key from the candidate/step spine.
        if isinstance(sha, str) and sha:
            self.sha = sha
        if ev == "review_log_retained":
            self.keep = obj.get("keep", 5)
        elif ev == "review_pin_soft":
            self.pin_mode = obj.get("pin_mode", "")
            self.pin_reason = obj.get("reason", "")
        elif ev == "review_panelist_verdict":
            self.panelists.append({
                "panelist": obj.get("panelist", len(self.panelists)),
                "ref": obj.get("ref", ""), "driver": obj.get("driver", ""),
                "model": obj.get("model", ""), "verdict": str(obj.get("verdict", "")).upper(),
                "reason": obj.get("reason", ""),
            })
        elif ev == "review_panel_folded":
            self.policy = obj.get("policy")
            self.refs = obj.get("refs")
        elif ev == "infra_event":
            self._saw_infra = True

    def to_dict(self):
        reporting = [p for p in self.panelists if p["verdict"] in ("PASS", "BLOCK")]
        # all-pass is the only policy under which a panel with a reporting panelist still folds to
        # INFRA (herd-review.sh §305) — infer it when that is exactly what the real journal showed.
        policy = self.policy or ("all-pass" if (self._saw_infra and reporting) else "any-block")
        panel = {"pr": self.pr, "slug": self.slug, "sha": self.sha, "policy": policy,
                 "panelists": self.panelists}
        if self.keep is not None:
            panel["keep"] = self.keep
        else:
            # NO review_log_retained was journaled for this subject: a review-rail pin note WITHOUT
            # the herd-review log-retention row (the concurrency scenario's stub reviewer emits
            # review_pin_soft but no review_log_retained — herd-review.sh is never on that path). Tell
            # the shadow to SUPPRESS the log-retained row so it does not over-emit vs the bash tree
            # (HERD-335). Omitted when a log-retained row WAS seen, keeping every sandbox panel dict
            # byte-identical to before.
            panel["log_retained"] = False
        panel["pin_mode"] = self.pin_mode or ""
        if self.pin_reason:
            panel["pin_reason"] = self.pin_reason
        if self.refs:
            panel["refs"] = self.refs
        return panel


class _StepFold:
    """Fold one slug's pipeline-STEPS events back into an ordered rows list (steps.sh).

    The journal records each step's execution (``step_run`` name/at/kind/outcome, contract §5.4) and,
    for a ``hold=approve`` step, the awaiting/approved/released triple. This reconstructs the input
    ROWS the shadow runtime re-models: one row per distinct step name in first-seen order, its at/
    kind/outcome from its ``step_run``, ``hold=approve`` inferred from a ``step_hold_awaiting`` on
    that step, and ``on_fail=block`` (the steps.sh default) hardened when a step failed (its failure
    halted the lane, so later rows never journaled). A ``held`` step_run is a halt MARKER, not a
    fresh execution outcome, so it never overwrites the row's real pass/fail — but the COUNT of held
    markers is preserved as ``held_count`` (a step held across N watcher re-ticks journals N held
    markers; the shadow replays exactly that many), so the oracle-v2 head-to-head matches marker-for-
    marker instead of collapsing a re-held step to one (HERD-325).
    """

    __slots__ = ("slug", "sha", "dir", "rows", "_by_name")

    def __init__(self, slug):
        self.slug = slug
        self.sha = ""
        self.dir = ""
        self.rows = []
        self._by_name = {}

    def _row(self, name):
        row = self._by_name.get(name)
        if row is None:
            row = {"name": name, "at": "", "kind": "shell", "on_fail": "block",
                   "hold": "none", "outcome": "pass"}
            self._by_name[name] = row
            self.rows.append(row)
        return row

    def observe(self, ev, obj):
        sha = obj.get("sha")
        if isinstance(sha, str) and sha:
            self.sha = sha
        if ev == "step_run":
            row = self._row(obj.get("name", ""))
            at = obj.get("at")
            if isinstance(at, str) and at:
                row["at"] = at
            kind = obj.get("kind")
            if isinstance(kind, str) and kind:
                row["kind"] = kind
            outcome = obj.get("outcome", "pass")
            if outcome in ("pass", "warn", "fail"):        # a real execution outcome, not "held"
                row["outcome"] = outcome
                if outcome == "fail":
                    row["on_fail"] = "block"               # it halted the lane
                    if "rc" in obj:
                        row["rc"] = obj["rc"]
            elif outcome == "held":                        # a halt marker — count it, don't overwrite
                row["held_count"] = row.get("held_count", 0) + 1
        elif ev == "step_hold_awaiting":
            self.dir = obj.get("dir") or self.dir
            self._row(obj.get("step", ""))["hold"] = "approve"

    def to_dict(self):
        return {"slug": self.slug, "sha": self.sha, "dir": self.dir or "(shadow)",
                "rows": self.rows}


class _MainHealthFold:
    """Fold one main_health SUBJECT (a (pr, sha) tick) into a shadow-runtime main_healths entry.

    The post-merge default-branch tripwire (agent-watch.sh:main_health_tick, contract §3.4) journals
    a ``main_health`` DISPATCH (``result=dispatched``) then a ``main_health`` RESULT (green, or red
    with the failing test + since-PR). This accumulates both into one subject so the shadow re-emits
    the same two-row shape. A subject with only a result row (no dispatch) replays only the result —
    faithful to whatever the real journal held. main_health is NOT a gate subject (§2.1); it is
    modeled, not fabricated into a candidate and not excluded.
    """

    __slots__ = ("pr", "sha", "dispatched", "result", "failed", "since", "_provenances", "died")

    def __init__(self, pr, sha):
        self.pr = pr
        self.sha = sha
        self.dispatched = False
        self.result = None
        self.failed = None
        self.since = None
        self._provenances = []   # dispatch provenances in order (first, then a re-dispatch after a kill)
        self.died = False        # an infra_event{reason:health_died} keyed this sha (HERD-222 kill)

    def observe(self, obj):
        result = obj.get("result")
        if result == "dispatched":
            self.dispatched = True
            prov = obj.get("provenance")
            self._provenances.append(prov if isinstance(prov, str) and prov else "")
        elif result in ("green", "red"):
            self.result = result
            if result == "red":
                self.failed = obj.get("failed", "")
                self.since = obj.get("since", "")

    def mark_died(self):
        """A mid-flight suite kill (infra_event health_died) touched this sha — it re-dispatched (§3.4)."""
        self.died = True

    def to_dict(self):
        d = {"pr": self.pr, "sha": self.sha, "result": self.result or "green"}
        if self.dispatched:
            d["dispatched"] = True
        if self._provenances and self._provenances[0]:
            d["provenance"] = self._provenances[0]
        # A killed suite (HERD-222): the first dispatch died and the sha was RE-DISPATCHED on the next
        # tick (a second dispatch row, provenance "died"). Preserve the died marker + the re-dispatch
        # provenance so the shadow replays the death + re-dispatch, not a single clean run.
        if self.died or len(self._provenances) > 1:
            d["died"] = True
            redis = self._provenances[1] if len(self._provenances) > 1 else "died"
            d["redispatch_provenance"] = redis or "died"
        if self.result == "red":
            d["failed"] = self.failed if self.failed is not None else ""
            d["since"] = self.since if self.since is not None else ""
        return d


class _PushHoldFold:
    """Fold one push-gate hold (a (slug, sha) subject) into a shadow-runtime push_holds entry.

    PUSH_GATE=human (push-gate.sh + herd-approve.sh, contract §5.4) journals ``push_hold_awaiting``
    when a finished build is held, then ``push_hold_approved`` and ``push_hold_resumed`` once a human
    releases it. A hold that never cleared carries only the awaiting row. Keyed by (slug, sha); the
    worktree dir is a volatile path the shadow re-synthesizes, so it is not carried here. Not a gate
    subject — modeled, never a candidate or excluded.
    """

    __slots__ = ("slug", "sha", "approved", "resumed")

    def __init__(self, slug, sha):
        self.slug = slug
        self.sha = sha
        self.approved = False
        self.resumed = False

    def observe(self, ev):
        if ev == "push_hold_approved":
            self.approved = True
        elif ev == "push_hold_resumed":
            self.resumed = True

    def to_dict(self):
        d = {"slug": self.slug, "sha": self.sha}
        if self.approved:
            d["approved"] = True
        if self.resumed:
            d["resumed"] = True
        return d


def _norm_health(outcome):
    """Coerce a raw health value (any case) to CLEAN|FLAKY|CODEERROR; unknown → CLEAN (§2.2)."""
    val = str(outcome or "").upper()
    return val if val in _HEALTH_OUTCOMES else "CLEAN"


def _pr_key(obj):
    """The PR identity of an event, as the shadow runtime keys it — ``str(pr)`` or ``None``."""
    pr = obj.get("pr")
    if pr is None or pr == "":
        return None
    return str(pr)


def extract_fixture(events, config_overrides=None):
    """Fold a list of journal event objects into a shadow-runtime ``{config, candidates}`` fixture.

    ``events`` is the parsed journal (a list of dicts, e.g. from :func:`herd.parity.load_events`).
    ``config_overrides`` is an optional mapping merged over the inferred config (an override always
    wins). Returns the fixture dict; also carries a ``_extracted`` provenance block (candidate count
    + a tally of the AUXILIARY events that were deliberately excluded) so the honest report can show
    exactly what was dropped. The shadow runtime ignores unknown top-level keys, so ``_extracted``
    never affects the run — it is human/report metadata only.
    """
    folds = {}                 # pr(str) -> _CandidateFold, insertion-ordered (first appearance)
    order = []                 # pr(str) in first-seen order, for a deterministic candidate list
    panels = {}                # pr(str) -> _PanelFold (review-panel subjects, first-seen order)
    panel_order = []
    steps = {}                 # slug(str) -> _StepFold (pipeline-steps runs, first-seen order)
    step_order = []
    gate_statuses = []         # ordered herd/gates commit-status posts
    main_healths = {}          # (pr,sha) -> _MainHealthFold (main-health ticks, first-seen order)
    mh_order = []
    push_holds = {}            # (slug,sha) -> _PushHoldFold (push-gate holds, first-seen order)
    ph_order = []
    main_events = []           # ordered main_ff / main_freshness replay (HERD-335, §3.4)
    fairness = []              # ordered merge_fairness_priority / pr_restale / pr_starvation (§6.2)
    excluded = {}              # event name -> count, for the provenance tally
    saw_gates_passed_merge = False

    def _get_panel(pr):
        panel = panels.get(pr)
        if panel is None:
            panel = panels[pr] = _PanelFold(pr)
            panel_order.append(pr)
        return panel

    def _replay_entry(obj):
        """One verbatim-replay entry: {event + non-volatile fields}, in journal.sh field order."""
        entry = {"event": obj.get("event")}
        for k, v in obj.items():
            if k not in _REPLAY_DROP_KEYS and k != "event":
                entry[k] = v
        return entry

    for obj in events:
        if not isinstance(obj, dict):
            continue
        ev = obj.get("event")
        if ev == "merge" and obj.get("reason") == "gates_passed":
            saw_gates_passed_merge = True

        # ── review PANEL (herd-review.sh): a per-panel subject, NOT a gate candidate. A herd-review
        #    infra_event (component=herd-review) is the panel's INFRA fold, not a review-rail INFRA,
        #    so it routes here — leaving the candidate-pass infra_event handling (§3.3) untouched.
        is_panel_infra = ev == "infra_event" and obj.get("component") == "herd-review"
        if ev in PANEL_ANCHOR_EVENTS or is_panel_infra:
            pr = _pr_key(obj)
            if pr is not None:
                _get_panel(pr).observe(ev, obj)
                continue
            # A panel anchor with no PR can't key a subject — fall through to the excluded tally.
        elif ev in PANEL_ATTACH_EVENTS:
            pr = _pr_key(obj)
            if pr is not None:
                # review_log_retained / review_pin_soft are emitted on EVERY review dispatch — a panel
                # OR a lone single-reviewer (REVIEW_PANEL_MODELS unset, herd-review.sh:541/585). Attach
                # the note to the PR's panel, CREATING it if this is the first sign of it. A PR that
                # never anchors a panelist stays a 0-panelist panel whose only rows are the log/pin
                # notes — which is EXACTLY what the bash tree journaled for that lone reviewer, so the
                # shadow re-emits them and the head-to-head diff matches (oracle v2, HERD-325 closes
                # the lone-reviewer residual the P3e buffering deliberately dropped).
                _get_panel(pr).observe(ev, obj)
                continue
            # A note with no PR falls through to the excluded tally.

        # ── post-merge MAIN-HEALTH tick (contract §3.4): a (pr, sha) subject, NOT a gate candidate.
        if ev == "main_health":
            pr = _pr_key(obj)
            sha = obj.get("sha", "")
            if pr is not None:
                key = (pr, str(sha))
                mh = main_healths.get(key)
                if mh is None:
                    mh = main_healths[key] = _MainHealthFold(pr, str(sha))
                    mh_order.append(key)
                mh.observe(obj)
                continue
            # A main_health with no PR can't key a subject — fall through to the excluded tally.

        # ── PUSH-GATE hold lifecycle (contract §5.4): a (slug, sha) subject, keyed by slug.
        if ev in PUSH_HOLD_EVENTS:
            slug = obj.get("slug")
            if isinstance(slug, str) and slug:
                sha = str(obj.get("sha", ""))
                key = (slug, sha)
                ph = push_holds.get(key)
                if ph is None:
                    ph = push_holds[key] = _PushHoldFold(slug, sha)
                    ph_order.append(key)
                ph.observe(ev)
                continue
            # A push-hold with no slug can't key a subject — fall through to the excluded tally.

        # ── pipeline STEPS (steps.sh): a per-slug run, keyed by slug (steps carry no PR).
        if ev in STEP_EVENTS:
            slug = obj.get("slug")
            if isinstance(slug, str) and slug:
                run = steps.get(slug)
                if run is None:
                    run = steps[slug] = _StepFold(slug)
                    step_order.append(slug)
                run.observe(ev, obj)
                continue

        # ── herd/gates commit STATUS (contract §2.3): an ordered blessing-artifact post.
        if ev == "gate_status":
            gate_statuses.append({
                "pr": obj.get("pr", ""), "sha": obj.get("sha", ""),
                "state": obj.get("state", "success"),
                "context": obj.get("context", "herd/gates"),
            })
            continue

        # ── a MAIN-HEALTH suite kill (HERD-222): an infra_event{reason:health_died} keyed by
        #    `main-<sha>` marks its main_health subject as died-and-re-dispatched (§3.4). It is folded
        #    INTO that subject (not a gate candidate, not excluded) so the shadow replays the death +
        #    re-dispatch. The subject was created by its earlier main_health dispatch row (same stream).
        if ev == "infra_event" and obj.get("reason") == "health_died":
            key_field = obj.get("key", "")
            if isinstance(key_field, str) and key_field.startswith("main-"):
                died_sha = key_field[len("main-"):]
                for (mh_pr, mh_sha), mh in main_healths.items():
                    if mh_sha == died_sha:
                        mh.mark_died()
                        break
                continue

        # ── verbatim-replay families (HERD-335): the MAIN reconcile (main_ff / main_freshness, §3.4)
        #    and the merge-FAIRNESS reorder + starvation counter (merge_fairness_priority / pr_restale
        #    / pr_starvation, §6.2). NOT gate subjects — folded into ordered lists the shadow replays
        #    verbatim, matched family-for-family, never fabricated into candidates or excluded.
        if ev in MAIN_EVENT_EVENTS:
            main_events.append(_replay_entry(obj))
            continue
        if ev in FAIRNESS_EVENTS:
            fairness.append(_replay_entry(obj))
            continue

        if ev not in CANDIDATE_EVENTS:
            if isinstance(ev, str):
                excluded[ev] = excluded.get(ev, 0) + 1
            continue
        pr = _pr_key(obj)
        if pr is None:
            # A candidate-pass event with no PR (e.g. a global infra_event) can't key a subject.
            if isinstance(ev, str):
                excluded[ev] = excluded.get(ev, 0) + 1
            continue
        fold = folds.get(pr)
        if fold is None:
            fold = folds[pr] = _CandidateFold(pr)
            order.append(pr)
        fold.observe(ev, obj)

    # ── reroute a candidate PR's LONE review-rail pin note out of the panel and INLINE onto the
    #    candidate (HERD-335). review_pin_soft fires on every review dispatch; for a PR that is ALSO a
    #    gate candidate with no panel fan-out (0 panelists, no log-retained row — the concurrency stub
    #    reviewer), it is a review-rail note the candidate should emit inline right before its
    #    review_dispatched, not a buffered end-of-stream panel. So fold it onto the candidate and drop
    #    the now-empty panel. A NON-candidate lone reviewer (the sandbox scenario, 0 candidates) keeps
    #    its panel untouched — that is the oracle-v2 lone-reviewer case (HERD-325).
    for pr in list(panel_order):
        panel = panels[pr]
        if pr in folds and not panel.panelists and panel.keep is None and panel.pin_reason is not None:
            folds[pr].pin_soft = True
            folds[pr].pin_reason = panel.pin_reason
            panel_order.remove(pr)
            del panels[pr]

    candidates = [folds[pr].to_dict() for pr in order]
    panel_list = [panels[pr].to_dict() for pr in panel_order]
    step_list = [steps[slug].to_dict() for slug in step_order]
    main_health_list = [main_healths[k].to_dict() for k in mh_order]
    push_hold_list = [push_holds[k].to_dict() for k in ph_order]

    config = {}
    # MERGE POLICY inference (contract §5.5): the run automerged ⇒ drive the shadow engine to auto too,
    # so the merge DECISION is a genuine head-to-head rather than a policy mismatch. Left unset when no
    # gates_passed merge was observed (the shadow runtime resolves its own default).
    if saw_gates_passed_merge:
        config["MERGE_POLICY"] = "auto"
    if config_overrides:
        for k, v in config_overrides.items():
            config[k] = v

    fixture = {"candidates": candidates}
    if config:
        fixture["config"] = config
    # Staged-subsystem lists are OMITTED when empty, so a candidate-only journal folds to a
    # byte-identical fixture (the shadow runtime defaults each to empty).
    if panel_list:
        fixture["panels"] = panel_list
    if step_list:
        fixture["steps"] = step_list
    if gate_statuses:
        fixture["gate_statuses"] = gate_statuses
    if main_health_list:
        fixture["main_healths"] = main_health_list
    if push_hold_list:
        fixture["push_holds"] = push_hold_list
    if main_events:
        fixture["main_events"] = main_events
    if fairness:
        fixture["fairness"] = fairness
    fixture["_extracted"] = {
        "candidate_count": len(candidates),
        "panel_count": len(panel_list),
        "step_run_count": len(step_list),
        "gate_status_count": len(gate_statuses),
        "main_health_count": len(main_health_list),
        "push_hold_count": len(push_hold_list),
        "main_event_count": len(main_events),
        "fairness_count": len(fairness),
        "excluded_events": dict(sorted(excluded.items())),
    }
    return fixture


# ── CLI ────────────────────────────────────────────────────────────────────────────────────────

_USAGE = (
    "usage: python3 -m herd.fixture_extract <journal.jsonl|-> [--out FILE] "
    "[--config KEY=VALUE]... [--pretty]\n"
    "  Reads a REAL sim journal (the union stream parity-run.sh collects) and writes a\n"
    "  shadow-runtime {config, candidates} fixture. '-' reads the journal from stdin.\n"
    "exit: 0 fixture written · 2 infra (unreadable/invalid journal)"
)


def main(argv):
    journal_path = None
    out_path = None
    pretty = False
    overrides = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--out":
            i += 1
            out_path = argv[i] if i < len(argv) else None
        elif a == "--config":
            i += 1
            kv = argv[i] if i < len(argv) else ""
            if "=" not in kv:
                sys.stderr.write("herd.fixture_extract: --config needs KEY=VALUE, got %r\n%s\n"
                                 % (kv, _USAGE))
                return 2
            k, v = kv.split("=", 1)
            overrides[k] = v
        elif a == "--pretty":
            pretty = True
        elif a in ("-h", "--help"):
            sys.stdout.write(_USAGE + "\n")
            return 0
        elif a == "-" or not a.startswith("-"):
            if journal_path is not None:
                sys.stderr.write("herd.fixture_extract: unexpected argument %r\n%s\n" % (a, _USAGE))
                return 2
            journal_path = a
        else:
            sys.stderr.write("herd.fixture_extract: unknown flag %r\n%s\n" % (a, _USAGE))
            return 2
        i += 1

    if journal_path is None:
        sys.stderr.write(_USAGE + "\n")
        return 2

    try:
        if journal_path == "-":
            events = _load_stdin_events()
        else:
            events = load_events(journal_path)
    except ParityError as exc:
        sys.stderr.write("herd.fixture_extract: %s\n" % exc)
        return 2

    fixture = extract_fixture(events, overrides)
    if pretty:
        text = json.dumps(fixture, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    else:
        text = json.dumps(fixture, separators=(",", ":"), ensure_ascii=False) + "\n"

    if out_path:
        try:
            with open(out_path, "w", encoding="utf-8") as fh:
                fh.write(text)
        except OSError as exc:
            sys.stderr.write("herd.fixture_extract: cannot write %s: %s\n" % (out_path, exc))
            return 2
    else:
        sys.stdout.write(text)
    return 0


def _load_stdin_events():
    """Parse events from stdin JSONL — fail LOUD on a bad line, mirroring load_events (§ exit 2)."""
    events = []
    for lineno, raw in enumerate(sys.stdin, 1):
        line = raw.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except ValueError as exc:
            raise ParityError("<stdin>:%d: invalid JSON: %s" % (lineno, exc))
    return events


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
