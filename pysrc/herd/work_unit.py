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

import glob
import json
import os
import re
import subprocess
import time

from herd.live_runtime import (LiveGates, LiveActuator, LiveJournal, LiveCandidate,
                               _GraphQLDiscovery, _is_worktree, _pool_dir, WAIT)
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


# ── doc-apply: the second kind (HERD-399, spike §9.4's re-planned Phase 4) ─────────────────────────
# WHY PYTHON-FIRST, NOT A BASH RAIL: the spike's original §5 Phase 4 target was a bash
# scripts/herd/work-units/doc-apply.sh, written before the engine port. The post-port amendment (§9.4)
# re-scoped it: git-pr's own bash adapter is already reference-model-only (§9.1's HERD-401 finding), so
# a bash doc-apply rail would ship a SECOND reference-model-only adapter nobody actuates. doc-apply
# instead lands here, in the live python engine's own adapter module, following §3.2's lifecycle.

# The manifest convention (spike §3.2 step 1, capabilities.tsv row 'doc-apply <slug>.unit.json'):
# `<WORKTREES_DIR>/<slug>.unit.json` — kind, slug, revision, item_ref, paths, title, body, worktree,
# opened_at, state. STRICTLY OPT-IN: with no manifest on disk, `list_open` returns `[]` and nothing
# about the git-pr path is touched — this file adds no new call site to `live_runtime.py`, exactly as
# the §9.2 skeleton's `GitPrAdapter` did not.

_DOC_APPLY_MANIFEST_SUFFIX = ".unit.json"

# The default PATH ALLOWLIST (fail-CLOSED, spike §3.2 step 3): only paths under docs/ may ever be
# landed by a doc-apply unit. An operator may override the prefix via DOC_APPLY_PATH_GLOB — a
# DEDICATED key (review fix, HERD-399 round 3), NOT a reuse of DOCS_ONLY_GLOB. The two rounds of prior
# review here are why: round 1 found that reusing DOCS_ONLY_GLOB unanchored (re.search) let an
# un-anchored operator pattern match ANYWHERE in a path; the round-2 fix (re.match, prefix-anchored)
# then made the SAME reused key silently WRONG the other way — this repo's own .herd/config sets
# DOCS_ONLY_GLOB="[.](md|txt)" (a suffix-shaped egrep pattern, by design, for its ACTUAL job: classifying
# a diff into the cheapest review tier), which under re.match can never match "docs/x.md" at all,
# refusing every doc-apply unit outright. The two consumers want genuinely different semantics — one an
# unanchored "does this diff touch only docs-ish files" classifier, the other a prefix-anchored
# write-authorization allowlist — so they can never safely share one key's format. DOC_APPLY_PATH_GLOB
# is unset by default (the hardcoded ^docs/ prefix applies); an unparseable operator pattern is DROPPED
# in favor of that hardcoded default rather than raising — this is a safety gate, so a bad regex must
# never silently widen it.
#
# MATCHED WITH re.match, NOT re.search: a PREFIX-anchored allowlist by construction, never a substring
# search — a path like "src/docs/x" is NOT a docs path just because the substring "docs/" occurs in it.
_DEFAULT_DOC_APPLY_PATH_RE = re.compile(r"^docs/")


def _doc_apply_path_pattern(config):
    pattern = (config or {}).get("DOC_APPLY_PATH_GLOB") or ""
    if pattern:
        try:
            return re.compile(pattern)
        except re.error:
            pass
    return _DEFAULT_DOC_APPLY_PATH_RE


def _safe_manifest_path(path):
    """Normalize ONE manifest path and reject anything unsafe — empty, absolute, drive-qualified, or
    escaping via any ``..`` component — BEFORE the allowlist pattern (or git) ever sees it (review fix,
    HERD-399). The allowlist is a STRING match, not a filesystem-containment check: an un-normalized
    ``"docs/../src/x.py"`` clears ``^docs/`` while actually resolving to ``src/x.py`` — verified
    empirically, ``git checkout <rev> -- "docs/../src/x.py"`` exits 0 and lands the OTHER file. Returns
    the normalized POSIX-relative path (the form used for every downstream check AND every git
    operation — the raw manifest string is never trusted again once this returns), or ``None`` when the
    path is unsafe.
    """
    if not path:
        return None
    p = str(path).replace("\\", "/")
    if p.startswith("/") or p.startswith("~") or (len(p) > 1 and p[1] == ":"):
        return None
    norm = os.path.normpath(p).replace("\\", "/")
    if norm in (".", ""):
        return None
    if norm == ".." or norm.startswith("../"):
        return None
    return norm


def _path_allowed(path, config):
    """A single manifest path clears the doc-apply allowlist: normalize FIRST (rejecting any ``..``
    escape or absolute path), THEN match the allowlist pattern against the normalized form — so a
    traversal path can never borrow a legitimate ``docs/`` prefix to smuggle a non-docs path past the
    gate (review fix, HERD-399). Empty/unsafe is NEVER allowed — the caller treats that the same as "a
    disallowed path" (fail closed, never an empty no-op mistaken for a passing gate)."""
    safe = _safe_manifest_path(path)
    if safe is None:
        return False
    return bool(_doc_apply_path_pattern(config).match(safe))


def _safe_paths(paths, config):
    """Normalize + allowlist-check every manifest path in one pass. Returns ``(safe_paths,
    disallowed_raw)``: ``safe_paths`` is the CANONICAL form — the ONLY form ever handed to git — for
    every path that cleared the gate; ``disallowed_raw`` lists the original (raw) strings that did not,
    for the caller to journal exactly what was rejected. A caller must refuse whenever ``disallowed_raw``
    is non-empty (fail closed on ANY bad path, not just drop it silently from the set)."""
    safe_paths, disallowed = [], []
    for p in paths:
        if _path_allowed(p, config):
            safe_paths.append(_safe_manifest_path(p))
        else:
            disallowed.append(p)
    return safe_paths, disallowed


def _is_tree_path(worktree, revision, path):
    """True iff ``path`` names a TREE (directory), not a blob, at ``revision`` in ``worktree``'s repo.
    Used to fail closed on directory-shaped manifest paths (review advisory, HERD-399): a scoped
    ``git checkout <rev> -- <dir>`` can only ADD/UPDATE files present in ``<dir>`` at ``<rev>`` — it
    never removes a file that existed in MAIN's copy of ``<dir>`` but was deleted in ``<rev>``, so a doc
    deletion expressed via a directory path would silently fail to land while ``apply`` still reports
    ``applied``. Best-effort: an unreadable ``ls-tree`` (no worktree, bad revision) returns False rather
    than blocking on an inconclusive read — the worktree-HEAD divergence guard elsewhere already covers
    an unreadable/absent worktree."""
    if not worktree or not path:
        return False
    try:
        out = subprocess.run(["git", "-C", worktree, "ls-tree", revision, "--", path],
                             capture_output=True, text=True, check=True)
    except Exception:
        return False
    line = (out.stdout or "").strip()
    if not line:
        return False
    fields = line.split("\t", 1)[0].split()
    return len(fields) >= 2 and fields[1] == "tree"


def _read_manifest(path):
    """Read one `<slug>.unit.json`; ``None`` on ANY fault (missing file, bad JSON, not an object) —
    the spike's explicit fail-soft contract: 'malformed manifest = journaled skip, never a crash or a
    red row'. The caller journals the skip; this function itself never raises."""
    try:
        with open(path, encoding="utf-8") as fh:
            obj = json.load(fh)
    except Exception:
        return None
    return obj if isinstance(obj, dict) else None


def _write_manifest(path, obj):
    """Atomic write (temp file + :func:`os.replace`) so a crash mid-write can never leave a
    half-written, malformed manifest for the next ``list_open`` to trip over. Best-effort: returns
    False on any fault, never raises into the caller."""
    try:
        directory = os.path.dirname(path)
        if directory and not os.path.isdir(directory):
            os.makedirs(directory, exist_ok=True)
        tmp = "%s.tmp-%d" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, separators=(",", ":"), ensure_ascii=False)
        os.replace(tmp, path)
        return True
    except Exception:
        return False


def _git_head(path):
    """``git rev-parse HEAD`` at ``path``; ``""`` on any fault (not a repo, no commits, git missing)."""
    if not path:
        return ""
    try:
        out = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"],
                             capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except Exception:
        return ""


def _git_attached(path, branch):
    """True iff ``path`` is a git checkout with HEAD attached to ``branch`` (never detached) — the
    same invariant agent-watch.sh's post-merge refresh legs guard before committing (HERD-336)."""
    try:
        out = subprocess.run(["git", "-C", path, "symbolic-ref", "--quiet", "--short", "HEAD"],
                             capture_output=True, text=True)
        return out.returncode == 0 and out.stdout.strip() == branch
    except Exception:
        return False


def _unit_candidate(unit, manifest):
    """A synthetic :class:`herd.live_runtime.LiveCandidate` for a doc-apply unit, for reuse of
    ``LiveGates.health`` (spike §3.2 step 3): the health rail is entirely worktree-shaped — it never
    reads PR semantics beyond using ``cand.pr`` as a ledger-file identity key — so the unit's own slug
    (unique per builder, exactly as a real PR number is unique per PR) stands in for it unchanged."""
    art = manifest or {}
    return LiveCandidate(pr=unit.slug, sha=unit.revision, slug=unit.slug,
                         worktree=str(art.get("worktree") or ""))


class LiveDocApply:
    """The REAL doc-apply landing op (spike §3.2 step 4): a SCOPED checkout of the manifest's declared
    paths from the builder worktree's revision onto the shared default-branch checkout (``MAIN``),
    committed and pushed ff-only (never ``--force``) — the SAME direct-commit posture
    ``agent-watch.sh``'s post-merge codemap/symbol-index refresh already uses (spike §3.1), just for a
    builder-declared path set instead of a generated map. NO ``gh pr create``, NO ``gh pr merge``
    anywhere in this chain.

    On a rejected push: one ``pull --rebase`` retry, then — ONLY when it is safe (HEAD attached AND
    still exactly the commit this call made) — a hard rollback (``reset --hard HEAD~1``) so ``MAIN``
    is restored to its pre-apply state (docstring corrected, review fix HERD-399 round 3: this is
    narrower than "MAIN can never strand ahead of origin" — a detached-HEAD or HEAD-moved race
    DELIBERATELY leaves the commit in place rather than risk a worse rollback, see the two guards in
    ``apply`` below). Because that leave-in-place path is real (not just a rare race — the ordinary
    "push rejected, rebase, still rejected" case for a genuinely protected branch lands there via the
    head-moved guard, since ``pull --rebase`` necessarily rewrites HEAD on success), a LOCALLY
    committed-but-never-pushed state can persist across ticks. A later ``apply`` call on the SAME
    revision therefore never trusts "the working tree already matches" as proof the content reached
    ``origin`` — it verifies against the remote-tracking ref first (:meth:`_ahead_of_remote`) before
    ever returning a terminal ``already``, so that state can never be mistaken for a genuine landing.

    Every git subprocess failure is caught and journaled (never raised) — an apply that cannot land
    returns :class:`ApplyResult` status ``error``, leaving the manifest untouched so the unit is
    retried, never left half-applied.
    """

    def __init__(self, journal, config=None):
        self.journal = journal
        self.config = config or {}

    def _main(self):
        return self.config.get("MAIN") or os.environ.get("MAIN") or os.environ.get("PROJECT_ROOT") or ""

    def _remote(self):
        return self.config.get("HERD_REMOTE") or os.environ.get("HERD_REMOTE") or "origin"

    def _branch(self):
        return self.config.get("HERD_BRANCH_NAME") or os.environ.get("HERD_BRANCH_NAME") or "main"

    def _err(self, unit, reason, **extra):
        self.journal.append("doc_apply_apply_error", unit=unit.unit_id, kind="doc-apply",
                            slug=unit.slug, reason=reason, **extra)
        return ApplyResult(status="error", reason=reason)

    def _refused(self, unit, reason, **extra):
        self.journal.append("doc_apply_apply_refused", unit=unit.unit_id, kind="doc-apply",
                            slug=unit.slug, reason=reason, **extra)
        return ApplyResult(status="refused", reason=reason)

    def _landed(self, unit, revision, paths):
        new_sha = _git_head(self._main())
        self.journal.append("apply", unit=unit.unit_id, kind="doc-apply", slug=unit.slug,
                            sha=new_sha, revision=revision, item_ref=unit.item_ref or "",
                            paths=",".join(paths), reason="gates_passed")
        return ApplyResult(status="applied", reason="gates_passed")

    def _already(self, unit, revision, reason):
        """A no-op terminal: nothing to land because ``origin`` ALREADY carries this revision's content
        for these paths (verified against the remote-tracking ref, not merely the local tree — see
        :meth:`_ahead_of_remote`). Journaled explicitly (review fix, HERD-399 round 3): the reviewer's
        whole finding was that this exit was SILENT — an ``open -> applied`` state transition with no
        journal record on either the engine or adapter layer, so a mis-classification here left NO trace.
        Every exit of :meth:`apply` now emits exactly one event; silence is the bug class this fix
        closes, so the benign no-op is journaled too, not just the failures."""
        self.journal.append("doc_apply_apply_noop", unit=unit.unit_id, kind="doc-apply",
                            slug=unit.slug, sha=_git_head(self._main()), revision=revision, reason=reason)
        return ApplyResult(status="already", reason=reason)

    def _ahead_of_remote(self, main, remote, branch):
        """True iff local HEAD carries commits the remote-tracking ref does not (review BLOCK fix,
        HERD-399 round 3): the two deliberate leave-in-place exits below
        (``push-rejected-detached-head`` / ``push-rejected-head-moved``) commit LOCALLY but never reach
        ``origin`` — a later no-diff comparison against the WORKING TREE alone cannot tell "already
        pushed" from "committed here but never landed remotely". A live ``fetch`` (not just the cached
        remote-tracking ref) so a genuinely stale local view is never mistaken for "synced": a failed or
        unreadable fetch/rev-list is treated as "cannot prove synced" -> True, so the caller never
        silently trusts an unverifiable state."""
        try:
            subprocess.run(["git", "-C", main, "fetch", "-q", remote, branch],
                           capture_output=True, text=True, timeout=30, check=True)
            out = subprocess.run(["git", "-C", main, "rev-list", "--count",
                                  "%s/%s..HEAD" % (remote, branch)],
                                 capture_output=True, text=True, check=True)
            return int((out.stdout or "0").strip() or "0") > 0
        except Exception:
            return True

    def apply(self, unit, paths=None):
        """``paths`` is normally the caller's already-normalized+allowlisted list (``DocApplyAdapter.
        apply`` passes it explicitly rather than mutating ``unit.artifact`` in place — review fix,
        HERD-399 round 3: mutating a caller-owned ``WorkUnit`` was a surprising side effect, and would
        raise if a caller ever handed in one with ``artifact=None``). When omitted (a direct caller,
        e.g. a test), falls back to ``unit.artifact['paths']``, re-normalized+re-validated here exactly
        as before — the defense-in-depth re-check is unconditional either way."""
        art = unit.artifact or {}
        main = self._main()
        worktree = str(art.get("worktree") or "")
        revision = unit.revision
        remote, branch = self._remote(), self._branch()

        # DEFENSE IN DEPTH (review fix, HERD-399): this is "the ONLY thing standing between a
        # builder-authored manifest ... and a direct commit to main" — it never trusts a caller's
        # allowlist check alone. Re-normalize + re-validate every path here too, and use ONLY the
        # normalized form for every git invocation below (never the raw manifest string, which is
        # exactly what let a "docs/../src/x.py" traversal clear an un-normalized "^docs/" match).
        raw_paths = list(paths if paths is not None else (art.get("paths") or []))
        safe_paths, disallowed = _safe_paths(raw_paths, self.config)
        if not raw_paths or disallowed:
            return self._refused(unit, "path allowlist refused",
                                 disallowed=",".join(str(p) for p in disallowed))
        paths = safe_paths

        if not main or not os.path.isdir(main):
            return self._err(unit, "no-main")
        if worktree:
            live_head = _git_head(worktree)
            if live_head and revision and live_head != revision:
                return self._err(unit, "revision-diverged")
        # A directory-shaped path cannot express a DELETION (a scoped checkout only ever adds/updates
        # files present at <revision> — a file removed there but still on MAIN silently survives). Fail
        # closed rather than silently under-apply (review advisory, HERD-399). Checked against `main`,
        # NOT gated on `worktree` being set (review fix, HERD-399 round 2): main and the builder worktree
        # share the same object store (a `git worktree add` sibling), so <revision> is reachable from
        # main regardless of whether the manifest happens to carry a worktree path — gating this check
        # on worktree presence let an empty-worktree manifest skip it entirely, exactly the silent-
        # under-apply case the guard exists to close.
        tree_paths = [p for p in paths if _is_tree_path(main, revision, p)]
        if tree_paths:
            return self._refused(unit, "directory-path-not-supported", paths=",".join(tree_paths))
        if not _git_attached(main, branch):
            return self._err(unit, "detached-head")

        # Never checkout OVER uncommitted local edits under these paths in the shared checkout — that
        # would silently discard them (review advisory, HERD-399).
        pre_status = subprocess.run(["git", "-C", main, "status", "--porcelain", "--"] + paths,
                                    capture_output=True, text=True)
        if (pre_status.stdout or "").strip():
            return self._err(unit, "dirty-local-changes")

        try:
            subprocess.run(["git", "-C", main, "checkout", revision, "--"] + paths,
                           capture_output=True, text=True, check=True)
        except Exception as exc:
            return self._err(unit, "checkout-failed", detail=str(exc)[:160])

        status = subprocess.run(["git", "-C", main, "status", "--porcelain", "--"] + paths,
                                capture_output=True, text=True)
        if not (status.stdout or "").strip():
            # BLOCK fix (review round 3, HERD-399): a clean working tree does NOT by itself prove the
            # content reached origin — a PRIOR apply attempt may have committed locally and then hit one
            # of the two deliberate leave-in-place exits below (push-rejected-detached-head / -head-
            # moved), leaving MAIN ahead of its upstream. Verify against the remote-tracking ref before
            # ever calling this terminal; if we're ahead, the local commit might just need a retry push
            # (a prior failure can be transient) rather than being silently declared "already landed".
            if self._ahead_of_remote(main, remote, branch):
                retry = subprocess.run(["git", "-C", main, "push", "-q", remote, branch],
                                       capture_output=True, text=True)
                if retry.returncode == 0:
                    return self._landed(unit, revision, paths)
                return self._err(unit, "committed-locally-but-unpushed")
            return self._already(unit, revision, "no diff to land")

        title = str(art.get("title") or "") or ("doc-apply: %s" % unit.slug)
        body = str(art.get("body") or "")
        msg = title if not body else "%s\n\n%s" % (title, body)
        if "Work-Unit:" not in msg:
            msg = "%s\n\nWork-Unit: %s" % (msg, unit.unit_id)
        try:
            subprocess.run(["git", "-C", main, "add", "--"] + paths,
                           capture_output=True, text=True, check=True)
            subprocess.run(["git", "-C", main, "commit", "-q", "-m", msg, "--"] + paths,
                           capture_output=True, text=True, check=True)
        except Exception as exc:
            # BLOCK fix (review round 2, HERD-399): "checkout -- <paths>" restores from the INDEX, and
            # the index already holds the new content (the scoped checkout a few lines above wrote both
            # index AND worktree) — that "rollback" was a no-op, permanently leaving MAIN's shared
            # checkout dirty (staged + working tree) whenever the commit itself fails (missing
            # user.email/user.name, a rejecting pre-commit hook, gpgsign with no key, ...). "checkout
            # HEAD -- <paths>" is the form that actually discards the index change and restores the
            # pre-apply content — verified: only the HEAD-qualified form reverts a path whose index was
            # already updated by a prior scoped checkout.
            subprocess.run(["git", "-C", main, "checkout", "HEAD", "--"] + paths,
                           capture_output=True, text=True)
            return self._err(unit, "commit-failed", detail=str(exc)[:160])

        commit_sha = _git_head(main)   # OUR commit — checked before any rollback ever touches HEAD

        push = subprocess.run(["git", "-C", main, "push", "-q", remote, branch],
                              capture_output=True, text=True)
        if push.returncode == 0:
            return self._landed(unit, revision, paths)

        pull = subprocess.run(["git", "-C", main, "pull", "--rebase", "--quiet", remote, branch],
                              capture_output=True, text=True)
        if pull.returncode == 0:
            if not _git_attached(main, branch):
                # HERD-336: a rebase-pull can leave HEAD detached — NEVER reset a detached HEAD (that
                # would strand the branch further, the exact corpse agent-watch.sh's refresh legs
                # guard against). Stop here; a human/reconcile sweep resumes.
                return self._err(unit, "push-rejected-detached-head")
            push = subprocess.run(["git", "-C", main, "push", "-q", remote, branch],
                                  capture_output=True, text=True)
            if push.returncode == 0:
                return self._landed(unit, revision, paths)

        # Rollback path. PER-EXIT DECISION (review fix, HERD-399 round 3): each of the three exits below
        # is a DELIBERATE choice between "roll back" and "leave the commit and mark the unit retryable":
        #   - the two guarded exits (detached-HEAD, HEAD-moved) LEAVE the commit — resetting either would
        #     do more damage than the diverge it repairs (strand the branch / destroy a concurrent seat's
        #     work), so we prefer a stuck-but-honest MAIN-ahead-of-origin over an unsafe reset;
        #   - the fully-safe exit (attached, HEAD still exactly ours) ROLLS BACK, restoring pre-apply MAIN.
        # A left-in-place commit is NOT silently accepted as landed: every one of these exits returns
        # `error` (journaled, manifest stays `open` -> retried), and the next apply() on this revision
        # cannot mistake the resulting clean tree for a landing because the no-diff terminal is grounded
        # in `_ahead_of_remote` (fetch + rev-list), which re-attempts the push and only ever declares
        # `already` once origin genuinely carries it. That is what makes a MAIN-ahead-of-origin corpse
        # impossible to persist silently (the exact ff-only-forever break refresh_codemap warns about).
        # A conflicted `pull --rebase` may have left the checkout mid-rebase — abort it
        # (best-effort) BEFORE inspecting HEAD, mirroring agent-watch.sh's refresh_codemap discipline
        # (HERD-336). Two independent guards before the destructive reset (review fix, HERD-399):
        #   (1) never reset a DETACHED HEAD — that stresses/strands the branch rather than repairing it;
        #   (2) never reset unless HEAD is still EXACTLY the commit we just made — if a concurrent seat
        #       committed to this shared checkout in between, `reset --hard HEAD~1` would destroy THEIR
        #       work, not ours. Either guard failing leaves the commit in place (a stuck-but-honest state
        #       a human/reconcile sweep resolves) rather than risk a bigger loss than the one being fixed.
        subprocess.run(["git", "-C", main, "rebase", "--abort"], capture_output=True, text=True)
        if not _git_attached(main, branch):
            return self._err(unit, "push-rejected-detached-head")
        if _git_head(main) != commit_sha:
            return self._err(unit, "push-rejected-head-moved")
        # NOTE (review round 2, HERD-399, non-blocking by design): `reset --hard HEAD~1` here discards
        # the ENTIRE working tree back to the pre-apply commit, not just the paths this unit touched —
        # any unrelated uncommitted edit elsewhere in the shared MAIN checkout is lost too. This mirrors
        # `refresh_codemap`'s own posture (agent-watch.sh) exactly; it is not a regression this module
        # introduces, and narrowing the reset to only this unit's paths is a separate, larger change to
        # the shared-checkout contract than this fix round scopes.
        subprocess.run(["git", "-C", main, "reset", "--hard", "HEAD~1"], capture_output=True, text=True)
        return self._err(unit, "push-rejected")


class DocApplyAdapter(WorkUnitAdapter):
    """The doc-apply work-unit adapter — HERD-399, spike §9.4's re-planned Phase 4: a real SECOND
    kind, landed PYTHON-FIRST (there is no bash doc-apply rail; see the module-level note above).
    Delivers a documentation change-set to the default branch WITHOUT a GitHub PR: ``open`` writes a
    manifest file (``<WORKTREES_DIR>/<slug>.unit.json``, spike §3.2), ``list_open``/``inspect`` read it
    back, ``gate`` composes a FAIL-CLOSED path allowlist with the SAME health+review rail-readiness
    shape :class:`GitPrAdapter`'s own ``gate`` composes, and ``apply`` lands the manifest's declared
    paths onto ``MAIN`` via :class:`LiveDocApply` — never ``gh pr create``, never ``gh pr merge``.

    STRICTLY OPT-IN (byte-identical checklist): with no ``<slug>.unit.json`` manifest on disk,
    ``list_open`` returns ``[]`` and nothing about the git-pr path changes — this adapter is reached
    only when a caller explicitly resolves ``WORK_UNIT_KIND=doc-apply`` AND a manifest exists.

    UNLIKE :class:`GitPrAdapter`, this adapter does NOT auto-construct a live ``gates`` collaborator:
    ``LiveGates.review``'s dispatch argv (``herd-review.sh <pr> <slug>``, no ``--local``) is git-pr
    shaped — reusing it unmodified for a doc-apply unit (which has no real PR number) would dispatch a
    REAL reviewer subprocess against a fabricated PR identity. A caller must inject a ``gates``
    collaborator that knows how to gate a doc-apply unit (the hermetic :class:`herd.live_runtime.
    FixtureGates` today, a local-review-aware live dispatcher in a future phase); with none injected,
    ``gate`` fails CLOSED (``status="error"``) rather than guess.

    ``reconcile``/``teardown`` are deliberately NOT IMPLEMENTED here, mirroring :class:`GitPrAdapter`'s
    own honest gaps: the spike's post-port amendment (§9.1/§9.4) keeps those two legs BASH's job for
    every kind, including doc-apply — ``_reconcile_via_ref`` and ``_reap_slug``
    (``scripts/herd/work-units/git-pr.sh``'s own header comments) are ALREADY kind-agnostic, and the
    spike names them, by function, as reusable AS-IS by "a future manifest-based kind" with no code
    change on either side. Wiring this python adapter's ``reconcile``/``teardown`` to actually call them
    (or a python-native equivalent) is future work this build does not ship.
    """

    kind = "doc-apply"

    def __init__(self, home=None, journal=None, config=None, worktrees_dir=None, gates=None, land=None):
        self.home = home
        self.journal = journal if journal is not None else LiveJournal(None)
        self.config = config or {}
        self._worktrees_dir = worktrees_dir or _pool_dir()
        self._gates = gates
        self._land = land if land is not None else LiveDocApply(self.journal, self.config)

    def _manifest_path(self, slug):
        return os.path.join(self._worktrees_dir, "%s%s" % (slug, _DOC_APPLY_MANIFEST_SUFFIX))

    def _unit_from_manifest(self, slug, obj):
        return WorkUnit(
            unit_id=_journal_unit_ref(self.kind, slug),
            kind=self.kind,
            slug=slug,
            revision=obj.get("revision", ""),
            item_ref=obj.get("item_ref"),
            artifact={"paths": list(obj.get("paths") or []), "title": obj.get("title", ""),
                      "body": obj.get("body", ""), "worktree": obj.get("worktree", "")},
        )

    def open(self, ctx):
        """Publish a candidate doc-apply delivery: write ``<slug>.unit.json`` (spike §3.2 step 1).
        Idempotent on an unchanged revision (a re-open with the SAME revision returns the existing
        unit rather than clobbering it — the interface's own "Idempotent on same revision when the
        kind allows" semantics, spike §2.2)."""
        ctx = ctx or {}
        slug = str(ctx.get("slug") or "")
        if not slug or not self._worktrees_dir:
            return None
        worktree = str(ctx.get("worktree") or "")
        revision = str(ctx.get("revision") or "") or _git_head(worktree)
        paths = list(ctx.get("paths") or [])
        manifest_path = self._manifest_path(slug)
        existing = _read_manifest(manifest_path)
        # Idempotent on an unchanged revision REGARDLESS of state (review fix, HERD-399 round 3): the
        # prior condition also required state != "applied", which INVERTED the intent — a re-open of an
        # ALREADY-APPLIED unit at the same revision fell through to the write below and reset state back
        # to "open", re-opening a completed unit instead of leaving it alone.
        if existing and existing.get("revision") == revision:
            return self._unit_from_manifest(slug, existing)
        obj = {
            "kind": self.kind, "slug": slug, "revision": revision,
            "item_ref": ctx.get("item_ref"), "paths": paths,
            "title": str(ctx.get("title") or ""), "body": str(ctx.get("body") or ""),
            "worktree": worktree, "opened_at": ctx.get("opened_at", int(time.time())),
            "state": "open",
        }
        if not _write_manifest(manifest_path, obj):
            self.journal.append("doc_apply_open_error", kind=self.kind, slug=slug,
                                reason="manifest-write-failed")
            return None
        self.journal.append("doc_apply_opened", unit=_journal_unit_ref(self.kind, slug),
                            kind=self.kind, slug=slug, sha=revision)
        return self._unit_from_manifest(slug, obj)

    def list_open(self):
        """Filesystem-glob discovery (spike §3.2 step 2): every ``*.unit.json`` of this kind whose
        state is not terminal. STRICTLY OPT-IN — an empty/absent ``WORKTREES_DIR`` or no manifests at
        all returns ``[]``, never an error. A malformed manifest is journaled and skipped, never a
        crash (the spike's explicit fail-soft contract); a manifest whose worktree HEAD has moved past
        its declared revision is STALE and is skipped too (re-evaluated once the builder re-opens it)."""
        if not self._worktrees_dir:
            return []
        units = []
        for path in sorted(glob.glob(os.path.join(self._worktrees_dir, "*" + _DOC_APPLY_MANIFEST_SUFFIX))):
            obj = _read_manifest(path)
            if obj is None:
                self.journal.append("doc_apply_manifest_invalid", path=os.path.basename(path))
                continue
            if obj.get("kind") != self.kind:
                continue
            if obj.get("state") in ("applied", "reaped"):
                continue
            slug = str(obj.get("slug") or "")
            if not slug:
                self.journal.append("doc_apply_manifest_invalid", path=os.path.basename(path),
                                    reason="no-slug")
                continue
            worktree = str(obj.get("worktree") or "")
            if worktree and _is_worktree(worktree):
                live_head = _git_head(worktree)
                if live_head and live_head != obj.get("revision"):
                    self.journal.append("doc_apply_manifest_stale", slug=slug,
                                        manifest_revision=obj.get("revision", ""),
                                        worktree_revision=live_head)
                    continue
            units.append(self._unit_from_manifest(slug, obj))
        return units

    def inspect(self, unit):
        obj = _read_manifest(self._manifest_path(unit.slug)) or {}
        return {
            "revision": obj.get("revision", ""), "state": obj.get("state", "open"),
            "body": obj.get("body", ""), "paths": list(obj.get("paths") or []),
            "item_ref": obj.get("item_ref"),
        }

    def gate(self, unit, revision):
        """Path allowlist (cheap, fail-closed) FIRST, then the SAME health+review composition
        :class:`GitPrAdapter.gate` runs — cost-classed DAG order (spike's own LiveTick docstring: cheap
        checks before slow ones). The ``revision`` argument MUST agree with ``unit.revision`` (review
        advisory, HERD-399 round 2) — a caller that gates one revision and applies another must be
        caught here, not silently gate a different change than the one that lands."""
        if revision and unit.revision and revision != unit.revision:
            return GateResult(status="error", reason="revision argument does not match unit.revision")
        manifest = _read_manifest(self._manifest_path(unit.slug))
        if manifest is None:
            return GateResult(status="error", reason="doc-apply manifest unreadable")
        paths = list(manifest.get("paths") or [])
        _safe, disallowed = _safe_paths(paths, self.config)
        if not paths or disallowed:
            self.journal.append("doc_apply_gate_refused", unit=unit.unit_id, kind=self.kind,
                                slug=unit.slug, disallowed=",".join(str(p) for p in disallowed))
            return GateResult(status="block", reason="doc-apply path allowlist refused",
                              evidence={"disallowed": disallowed, "paths": paths})
        if self._gates is None:
            return GateResult(status="error", reason="no gates collaborator injected")
        cand = _unit_candidate(unit, manifest)
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
            return GateResult(status="pass", reason="health+review both green + path allowlist clean",
                              evidence=evidence)
        return GateResult(status="wait", reason="rail outcome not yet terminal", evidence=evidence)

    def apply(self, unit, revision):
        """Re-checks the allowlist (defense in depth — a caller MUST have already gated, but apply
        never trusts that alone) then delegates the actual landing to :class:`LiveDocApply` (or an
        injected twin), handing it the NORMALIZED path list — never the raw manifest strings (review
        fix, HERD-399: a raw ``docs/../src/x.py`` would clear an un-normalized allowlist check while
        resolving to a completely different file once it reaches git). At-most-once via the manifest's
        own ``state`` field: an already-applied unit short-circuits to ``already`` with no git op and
        no double journal (spike §3.2 step 4). A terminal ``already`` (nothing to land — MAIN already
        matches) is ALSO persisted (review advisory, HERD-399) — else a no-diff unit stays in
        ``list_open`` and re-runs a checkout+status probe forever. Like ``gate``, ``revision`` MUST
        agree with ``unit.revision`` — never land a different revision than the one that was gated."""
        if revision and unit.revision and revision != unit.revision:
            self.journal.append("doc_apply_apply_error", unit=unit.unit_id, kind=self.kind,
                                slug=unit.slug, reason="revision-argument-mismatch")
            return ApplyResult(status="error", reason="revision argument does not match unit.revision")
        manifest_path = self._manifest_path(unit.slug)
        manifest = _read_manifest(manifest_path)
        if manifest is None:
            self.journal.append("doc_apply_apply_error", unit=unit.unit_id, kind=self.kind,
                                slug=unit.slug, reason="manifest-unreadable")
            return ApplyResult(status="error", reason="doc-apply manifest unreadable")
        if manifest.get("state") == "applied":
            return ApplyResult(status="already", reason="already applied")
        paths = list(manifest.get("paths") or [])
        safe_paths, disallowed = _safe_paths(paths, self.config)
        if not paths or disallowed:
            self.journal.append("doc_apply_apply_refused", unit=unit.unit_id, kind=self.kind,
                                slug=unit.slug, disallowed=",".join(str(p) for p in disallowed))
            return ApplyResult(status="refused", reason="path allowlist refused")
        result = self._land.apply(unit, paths=safe_paths)
        if result.status in ("applied", "already"):
            manifest["state"] = "applied"
            _write_manifest(manifest_path, manifest)
        return result

    def reconcile(self, unit):
        self._unimplemented("reconcile")

    def teardown(self, unit):
        self._unimplemented("teardown")


# ── resolve: WORK_UNIT_KIND selects the adapter (spike §9) ─────────────────────────────────────────

SUPPORTED_KINDS = ("git-pr", "doc-apply")
DEFAULT_KIND = "git-pr"

_ADAPTERS = {"git-pr": GitPrAdapter, "doc-apply": DocApplyAdapter}


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
