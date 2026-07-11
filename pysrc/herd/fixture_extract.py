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
deliverable, never force a green by over-canonicalizing"). The two engines emit DIFFERENT event
vocabularies: the bash tree journals ``healthcheck_started`` / ``review_pin_soft`` /
``symbol_index_refresh`` / ``reap`` / ``main_health`` that the shadow runtime does not model, and
the shadow runtime journals ``shadow_tick_start`` / ``shadow_state`` / ``shadow_blessing`` the
bash tree does not. So an ``auto`` head-to-head is EXPECTED to diverge, and that divergence report
is the deliverable. This extractor's job is only to give the shadow engine the same INPUTS
(subjects + rail outcomes); it never rewrites the real stream to manufacture agreement.

EXTRACTION RULES — every rule cites the engine contract section (``docs/engine-contract.md``) that
gives it meaning, so each mapping from a real event to a candidate field is auditable:

  * CANDIDATE SUBJECTS (contract §2.1, the candidate pass). Only the events in
    :data:`CANDIDATE_EVENTS` establish a PR as a gate subject. Every OTHER journal event —
    ``main_health`` (§3.4, a post-merge default-branch tick, not a gate subject), ``infra_breaker_*``
    (§3.3), ``review_pin_soft`` / ``symbol_index_refresh`` / ``reap`` / ``cost`` / ``step_*`` — is an
    AUXILIARY engine event and is counted in the excluded tally, never fabricated into a candidate.
    Dropping them is honest SCOPING (the shadow runtime models the candidate pass, contract §2.1),
    not canonicalization.
  * HEALTH ← ``healthcheck_outcome.outcome`` (CLEAN|FLAKY|CODEERROR, contract §2.2 / §3.4), with
    ``healthcheck_cache_hit.outcome`` and ``healthcheck_attempted.result`` as fallbacks (§3.4).
  * REVIEW ← ``verdict_recorded.value`` (PASS|BLOCK) but ONLY when ``source == reviewer`` — the sole
    provenance that may bounce a builder (contract §3.2). A non-reviewer verdict is ignored. An
    ``infra_event`` with ``rail == review`` and no reviewer verdict maps to INFRA (a bounded retry,
    never a cached BLOCK — contract §2.2 / §3.3).
  * STALE ← ``stale_dup_hold`` (kind=stale, §2.1 step 1) OR ``pr_restale`` / ``pr_starvation`` (the
    starvation-freeze seam, contract §6.2) — a behind-base sha holds, it never merges.
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
    "review_dispatched", "verdict_recorded", "infra_event",
    "stale_dup_hold", "refix_bounce", "hold_applied", "human_verify_policy", "approval_recorded",
    "merge", "merge_refused_sha_moved", "pr_restale", "pr_starvation",
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
                 "_saw_reviewer_verdict")

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

    def observe(self, ev, obj):
        # SHA (contract §2.4): the last candidate-signal sha wins (lap-bumped / merged sha over an
        # earlier one). Input order is parity-run.sh's deterministic path-sorted union.
        sha = obj.get("sha")
        if isinstance(sha, str) and sha:
            self.sha = sha
        slug = obj.get("slug")
        if isinstance(slug, str) and slug:
            self.slug = slug

        if ev == "healthcheck_outcome":                       # contract §2.2 / §3.4
            self.health = _norm_health(obj.get("outcome"))
        elif ev == "healthcheck_cache_hit" and self.health is None:
            self.health = _norm_health(obj.get("outcome"))
        elif ev == "healthcheck_attempted" and self.health is None:
            self.health = _norm_health(obj.get("result"))
        elif ev == "verdict_recorded":                        # contract §3.2: reviewer provenance only
            if obj.get("source") == "reviewer":
                val = str(obj.get("value", "")).upper()
                if val in _REVIEW_VERDICTS:
                    self.review = val
                    self._saw_reviewer_verdict = True
        elif ev == "infra_event":                             # contract §3.3: INFRA, never a BLOCK
            if obj.get("rail") == "review" and not self._saw_reviewer_verdict:
                self.review = "INFRA"
        elif ev in ("stale_dup_hold", "pr_restale", "pr_starvation"):   # contract §2.1 step 1 / §6.2
            self.stale = True
        elif ev == "hold_applied":                            # contract §5.4
            if str(obj.get("kind", "")).startswith("human"):
                self.hv_hold = True
        elif ev == "human_verify_policy":                     # contract §5.4
            self.hv_hold = True
        elif ev == "approval_recorded":                       # contract §5.5
            if obj.get("state") == "approved":
                self.approved = True

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
        if isinstance(sha, str):
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
    fresh execution outcome, so it never overwrites the row's real pass/fail.
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
        elif ev == "step_hold_awaiting":
            self.dir = obj.get("dir") or self.dir
            self._row(obj.get("step", ""))["hold"] = "approve"

    def to_dict(self):
        return {"slug": self.slug, "sha": self.sha, "dir": self.dir or "(shadow)",
                "rows": self.rows}


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
    pending_review = {}        # pr(str) -> [(ev, obj)] shared review notes buffered until a panel anchors
    steps = {}                 # slug(str) -> _StepFold (pipeline-steps runs, first-seen order)
    step_order = []
    gate_statuses = []         # ordered herd/gates commit-status posts
    excluded = {}              # event name -> count, for the provenance tally
    saw_gates_passed_merge = False

    def _get_panel(pr):
        panel = panels.get(pr)
        if panel is None:
            panel = panels[pr] = _PanelFold(pr)
            panel_order.append(pr)
            for bev, bobj in pending_review.pop(pr, ()):   # flush buffered log/pin notes into it
                panel.observe(bev, bobj)
        return panel

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
                if pr in panels:
                    panels[pr].observe(ev, obj)          # a panel already anchored — attach directly
                else:
                    pending_review.setdefault(pr, []).append((ev, obj))  # buffer until one anchors
                continue
            # A note with no PR falls through to the excluded tally.

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

    # Review notes that never anchored a panel (a lone single-reviewer log/pin, or a panel that only
    # ever emitted bookkeeping) are plain review-rail auxiliary events — tally them as excluded,
    # exactly as they were before panels existed (no spurious 0-panelist panel is ever fabricated).
    for buffered in pending_review.values():
        for bev, _ in buffered:
            excluded[bev] = excluded.get(bev, 0) + 1

    candidates = [folds[pr].to_dict() for pr in order]
    panel_list = [panels[pr].to_dict() for pr in panel_order]
    step_list = [steps[slug].to_dict() for slug in step_order]

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
    fixture["_extracted"] = {
        "candidate_count": len(candidates),
        "panel_count": len(panel_list),
        "step_run_count": len(step_list),
        "gate_status_count": len(gate_statuses),
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
