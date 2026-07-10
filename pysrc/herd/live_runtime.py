"""herd.live_runtime — the LIVE watcher tick, ported to Python (HERD-320, P3f, EPIC HERD-300).

This is P3f of the strangler port: the FIRST Python engine core that can be AUTHORITATIVE. Where P3c
(:mod:`herd.shadow_runtime`) walked the candidate → gate → decision → apply pipeline in DRY-RUN and
its only footprint was a shadow journal, this module walks the SAME pipeline for real — it discovers
open PRs, DISPATCHES the gate rails by shelling out to the existing leaf scripts, consumes their
verdicts, and — on green — MERGES and REAPS. It is the minimal-but-correct loop the cutover needs:

    discover candidates  →  gate dispatch (health, review)  →  verdict/outcome consumption
                         →  merge-on-green  →  reap        (with holds recognized and HELD)

DESIGN PILLARS (contract §2, spike §0 — the port replaces LOOP+STATE+DECISIONS, shells out for the
leaves):

  * **Python replaces the loop; bash leaves stay leaves.** The gate RAILS are the existing shell
    scripts — ``scripts/herd/herd-review.sh`` (the adversarial review gate) and
    ``scripts/herd/healthcheck.sh`` (the health runner). This module never re-implements a gate; it
    DISPATCHES one (:class:`LiveGates`, which ``subprocess``-execs the leaf and parses its contract
    output) and consumes the result. The *decision* core it reuses VERBATIM from P2
    (:mod:`herd.decisions`) — merge-policy resolution and the hold/merge/observe selector are pure
    functions, never re-derived here.

  * **Same flat state files, real journal, same event shapes.** Actuation writes the SAME
    ``.herd/journal.jsonl`` the bash engine owns, in ``journal.sh``-identical event shapes
    (:class:`LiveJournal` reuses :func:`herd.shadow_journal.encode_event`), so ``herd why`` / ``herd
    log`` / the parity diff read one coherent stream regardless of which implementation wrote a line.
    NO SQLite — that is P4; this phase keeps the append-only flat-file substrate unchanged.

  * **A typed lifecycle, reused from the shadow port.** Candidate lifecycle transitions run through
    the SAME state machine P3b/P3c use (:data:`SM`), as an assertion layer over the real output — an
    illegal transition is journaled, never fatal, exactly as in shadow mode.

  * **Bash stays the resident supervisor; Python is the tick, instant-fallback the kill-switch.** The
    watcher (``agent-watch.sh``) still owns the ``while true`` loop and every sweep. Under
    ``ENGINE_IMPL=python`` it hands ONE tick to ``python3 -m herd.live_runtime --tick``; if that exits
    nonzero the bash tick body runs instead (``herd_engine_live_tick`` returns non-zero → fallback),
    and flipping ``ENGINE_IMPL`` back to ``bash`` disables the port instantly. Ship default ``bash``
    ⇒ this module is never invoked and the watcher is byte-identical to before it existed.

THE VERIFY DISCIPLINE (why this module is safe to test). Every side effect is behind a pluggable
seam with a DRY-RUN twin:

    layer        live (actuates)         dry-run / sim (side-effect-free)
    ─────────    ─────────────────       ────────────────────────────────
    discovery    discover_via_graphql    FixtureDiscovery   (reads a scenario JSON)
    gates        LiveGates               FixtureGates       (scripted rail outcomes)
    apply        LiveActuator            DryRunActuator      (journals only — no gh / git / pane)

``--dry-run`` wires the RIGHT column exclusively: it invokes NO subprocess, touches NO gh/git/pane,
and writes only a caller-named journal (never the real ``.herd/journal.jsonl`` unless explicitly
pointed there). The unit + gate tests drive ONLY that column, so a test run can never actuate against
the live control room — the sim rig "drives behavior through stubs, not bash internals" (spike §3).
The live column's ``subprocess`` calls exist and are real, but are reached only by ``--tick`` against
a genuine repo with ``ENGINE_IMPL=python`` armed.

Stdlib-only (the P1 packaging rule). CLI:
    python3 -m herd.live_runtime --dry-run [--fixture FILE]   # smoke: sim in, result JSON out
    python3 -m herd.live_runtime --tick                       # live: one authoritative tick
Unit-driven by ``tests/test_live_runtime.py`` + gate wrapper ``tests/test-py-live-runtime.sh``.
"""

import json
import os
import subprocess
import sys

from herd import decisions as D
from herd import shadow_runtime as _shadow
from herd.shadow_journal import encode_event

# ── the typed lifecycle, reused from P3b/P3c (single source of truth for the state vocabulary) ────
# Live mode drives the SAME lifecycle the shadow runtime drives — reusing its resolved state machine
# (real P3b when present, the local mirror otherwise) keeps one authoritative transition table across
# the port. The lifecycle is an ASSERTION layer over the journal here too: a disagreement is observed
# (journaled ``illegal_transition``), never fatal to a tick.
SM = _shadow.SM
_S_INTAKE = _shadow._S_INTAKE
IllegalTransition = _shadow.IllegalTransition

# The four normalized gate outcomes a rail resolves to (contract §2.2) — shared with shadow mode.
PASS, BLOCK, ESCALATE, HOLD = "PASS", "BLOCK", "ESCALATE", "HOLD"


# ── the subject under gate ────────────────────────────────────────────────────────────────────────

class LiveCandidate:
    """One PR at a specific head sha, plus the facts the gate walk needs.

    In live mode these fields come from :func:`discover_via_graphql` (``gh``); in dry-run/sim they
    are injected fixtures. ``stale`` is the cheap behind-base gate (a PR behind its base holds, never
    merges); ``hv_hold`` marks a declared HUMAN-VERIFY block; ``approved`` a sha-keyed approval
    record; ``worktree`` is the path reaped on merge.
    """

    __slots__ = ("pr", "sha", "slug", "base", "worktree", "stale", "hv_hold", "approved", "hv_body")

    def __init__(self, pr, sha, slug="", base="", worktree="", stale=False,
                 hv_hold=False, approved=False, hv_body=""):
        self.pr = str(pr)
        self.sha = str(sha)
        self.slug = slug or ("pr-%s" % pr)
        self.base = str(base)
        self.worktree = str(worktree)
        self.stale = bool(stale)
        self.hv_hold = bool(hv_hold)
        self.approved = bool(approved)
        self.hv_body = str(hv_body)

    @classmethod
    def from_dict(cls, d):
        return cls(
            pr=d["pr"], sha=d["sha"], slug=d.get("slug", ""), base=d.get("base", ""),
            worktree=d.get("worktree", ""), stale=d.get("stale", False),
            hv_hold=d.get("hv_hold", False), approved=d.get("approved", False),
            hv_body=d.get("hv_body", ""),
        )


# ── the real journal (journal.sh-identical shapes, best-effort, never raises) ──────────────────────

class LiveJournal:
    """Append-only writer to the REAL ``.herd/journal.jsonl``, in ``journal.sh`` shapes.

    Reuses :func:`herd.shadow_journal.encode_event` — the exact bash encoding contract (``ts``+``event``
    first, integer coercion, ``separators=(",", ":")``) — so a line this writer emits is
    indistinguishable from one the bash watcher emits for the same ``(event, kv…)``. Like
    ``journal_append`` (and :class:`ShadowJournal`) it is BEST-EFFORT and SILENT: an unwritable path or
    an encoding fault drops the entry and returns ``False``, never raising into the tick. A ``path`` of
    ``None`` is a black hole (every append is a no-op) — the safe default when no destination resolves.
    """

    def __init__(self, path=None):
        self.path = path

    @classmethod
    def resolve_live_path(cls):
        """Resolve the LIVE journal path: ``JOURNAL_FILE`` (the bash engine's own knob) else
        ``<WORKTREES_DIR>/.herd/journal.jsonl``; ``None`` when neither is set."""
        override = os.environ.get("JOURNAL_FILE")
        if override:
            return override
        base = os.environ.get("WORKTREES_DIR")
        if not base:
            return None
        return os.path.join(base, ".herd", "journal.jsonl")

    def append(self, event, *pairs, **kv):
        """Append one event. Best-effort + silent — a journal hiccup is never fatal to a tick."""
        try:
            if not self.path:
                return False
            items = list(_iter_pairs(list(pairs)))
            items.extend(kv.items())
            line = encode_event(event, items)
            if not line:
                return False
            directory = os.path.dirname(self.path)
            if directory and not os.path.isdir(directory):
                os.makedirs(directory, exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
            return True
        except Exception:
            return False


def _iter_pairs(seq):
    """Yield ``(k, v)`` from a flat ``[k, v, …]`` list (dangling final key dropped, journal.sh:136)."""
    for i in range(0, len(seq) - 1, 2):
        yield seq[i], seq[i + 1]


# ── discovery: where candidates come from ─────────────────────────────────────────────────────────

def discover_via_graphql(repo=None, limit=50):
    """Discover open-PR candidates in ONE batched GraphQL round-trip (contract §6, spike §0.3).

    LIVE ONLY — shells out to ``gh api graphql``. Replaces the bash tree's per-PR ``gh`` fan-out with a
    single query for every open PR's number, head sha, base ref, and merge state, so N candidates cost
    ONE request, not N. ``stale`` is derived from ``mergeStateStatus == BEHIND`` (the PR is behind its
    base and must rebuild before it can merge). Raises ``subprocess.CalledProcessError`` /
    ``json.JSONDecodeError`` on a transport/parse failure — the caller (the ``--tick`` entrypoint)
    catches it and returns non-zero so the bash supervisor falls back for that tick.

    Never called under ``--dry-run`` (that path uses :class:`FixtureDiscovery`), so a test never runs
    ``gh``.
    """
    query = (
        "query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){"
        "pullRequests(states:OPEN,first:$n){nodes{number headRefName mergeStateStatus "
        "headRefOid baseRefName}}}}"
    )
    owner, name = _repo_owner_name(repo)
    out = subprocess.run(
        ["gh", "api", "graphql", "-f", "query=%s" % query,
         "-F", "owner=%s" % owner, "-F", "name=%s" % name, "-F", "n=%d" % int(limit)],
        capture_output=True, text=True, check=True,
    )
    data = json.loads(out.stdout)
    nodes = (((data.get("data") or {}).get("repository") or {})
             .get("pullRequests") or {}).get("nodes") or []
    cands = []
    for node in nodes:
        cands.append(LiveCandidate(
            pr=node.get("number"), sha=node.get("headRefOid", ""),
            slug=node.get("headRefName", ""), base=node.get("baseRefName", ""),
            stale=(node.get("mergeStateStatus") == "BEHIND"),
        ))
    return cands


def _repo_owner_name(repo=None):
    """``(owner, name)`` for the current repo — ``repo`` arg (``owner/name``) else ``gh repo view``."""
    if repo and "/" in repo:
        owner, name = repo.split("/", 1)
        return owner, name
    out = subprocess.run(
        ["gh", "repo", "view", "--json", "owner,name",
         "-q", "[.owner.login,.name]|@tsv"],
        capture_output=True, text=True, check=True,
    )
    parts = out.stdout.strip().split("\t")
    return (parts[0], parts[1]) if len(parts) == 2 else ("", "")


class FixtureDiscovery:
    """Sim/dry-run discovery: candidates injected from a scenario dict, never the live control room."""

    def __init__(self, scenario):
        self._cands = [LiveCandidate.from_dict(c) for c in (scenario.get("candidates") or [])]

    def discover(self):
        return list(self._cands)


class _GraphQLDiscovery:
    """Thin adapter so the live entrypoint has the same ``.discover()`` shape as the fixture one."""

    def __init__(self, repo=None):
        self._repo = repo

    def discover(self):
        return discover_via_graphql(self._repo)


# ── gate dispatch: shell out to the existing leaf scripts, consume their contract output ───────────

class LiveGates:
    """Dispatch the gate rails by SHELLING OUT to the existing leaf scripts (the port's whole point).

    ``health`` runs ``scripts/herd/healthcheck.sh <worktree> --heavy --oneline`` and maps its exit
    code by the leaf's documented contract (healthcheck.sh:2): ``0`` clean, ``2`` tolerated data/env
    (a FLAKY pass), ``1`` a real CODE error. ``review`` runs ``scripts/herd/herd-review.sh <pr>
    <slug>`` and parses its single ``REVIEW:`` verdict line (herd-review.sh CONTRACT): ``PASS`` /
    ``BLOCK`` are recorded verdicts, ``INFRA-FAIL`` (or no parseable line) is a transient INFRA outcome
    — NEVER a cached code verdict. Never reached under ``--dry-run`` (that uses :class:`FixtureGates`).
    """

    def __init__(self, home):
        self.home = home

    def _script(self, name):
        return os.path.join(self.home, "scripts", "herd", name)

    def health(self, cand):
        rc = subprocess.run(
            ["bash", self._script("healthcheck.sh"), cand.worktree, "--heavy", "--oneline"],
            capture_output=True, text=True,
        ).returncode
        if rc == 0:
            return "CLEAN"
        if rc == 2:
            return "FLAKY"          # tolerated data/env — counts as a health pass (contract §2.2)
        return "CODEERROR"

    def review(self, cand):
        out = subprocess.run(
            ["bash", self._script("herd-review.sh"), cand.pr, cand.slug],
            capture_output=True, text=True,
        )
        return parse_review_verdict(out.stdout)


def parse_review_verdict(text):
    """The LAST ``REVIEW:`` line's verdict → ``PASS`` | ``BLOCK`` | ``INFRA`` (herd-review.sh CONTRACT).

    ``REVIEW: PASS`` / ``REVIEW: BLOCK`` map to the recorded verdict; ``REVIEW: INFRA-FAIL`` and ANY
    absent/unparseable output map to ``INFRA`` — a transient the caller retries and NEVER caches as a
    per-PR code verdict (contract §2.2/§3.2). Pure, so the parser is unit-tested without a subprocess.
    """
    verdict = "INFRA"
    for line in text.splitlines():
        s = line.strip()
        if not s.upper().startswith("REVIEW:"):
            continue
        body = s.split(":", 1)[1].strip().upper()   # everything after the first colon
        if body.startswith("PASS"):
            verdict = "PASS"
        elif body.startswith("BLOCK"):
            verdict = "BLOCK"
        else:
            # INFRA-FAIL, an empty body, or any unrecognized word — a transient, never a code verdict.
            verdict = "INFRA"
    return verdict


class FixtureGates:
    """Sim/dry-run gates: return the rail outcomes SCRIPTED per-candidate in the scenario.

    Reads ``health`` ∈ CLEAN|FLAKY|CODEERROR and ``review`` ∈ PASS|BLOCK|INFRA off the candidate's own
    fixture fields (stashed on the object by :meth:`_stash`), so a scenario drives the whole DAG with
    NO subprocess — the side-effect-free VERIFY path.
    """

    def __init__(self, scenario):
        self._by_pr = {str(c["pr"]): c for c in (scenario.get("candidates") or [])}

    def _spec(self, cand):
        return self._by_pr.get(cand.pr, {})

    def health(self, cand):
        v = str(self._spec(cand).get("health", "CLEAN")).upper()
        return v if v in ("CLEAN", "FLAKY", "CODEERROR") else "CLEAN"

    def review(self, cand):
        v = str(self._spec(cand).get("review", "PASS")).upper()
        return v if v in ("PASS", "BLOCK", "INFRA") else "PASS"


# ── apply: actuate the terminal action (merge / reap) or, in dry-run, journal only ────────────────

class DryRunActuator:
    """The side-effect-free apply twin: journals the SAME terminal events, actuates NOTHING.

    ``merge`` / ``reap`` write ``journal.sh``-shaped ``merge`` / ``reap`` lines so a dry-run stream is
    diff-comparable against a live one, but no ``gh``, no ``git worktree remove``, no pane op runs.
    This is the actuator ``--dry-run`` (and a dry-run watcher tick) always uses.
    """

    def __init__(self, journal):
        self.journal = journal

    def merge(self, cand):
        self.journal.append("merge", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "method", "squash", "reason", "gates_passed")
        return True

    def reap(self, cand):
        self.journal.append("reap", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "reason", "merged")
        return True


class LiveActuator:
    """The REAL apply layer: merge via ``gh``, reap the worktree via ``git`` (contract §2, §6.1).

    ``merge`` squash-merges the PR (``gh pr merge --squash --delete-branch``); ``reap`` removes the
    builder worktree (``git worktree remove --force``). Both journal the SAME event the dry-run twin
    does, so the forensic stream is identical shape whether or not actuation ran. Each actuation is
    guarded so a single failing merge/reap surfaces (returns ``False``) without sinking the whole tick.
    Reached only from ``--tick`` in genuine live mode — never from any test.
    """

    def __init__(self, home, journal):
        self.home = home
        self.journal = journal

    def merge(self, cand):
        try:
            subprocess.run(["gh", "pr", "merge", cand.pr, "--squash", "--delete-branch"],
                           capture_output=True, text=True, check=True)
        except Exception as exc:
            self.journal.append("merge_gh_unreadable", "pr", cand.pr, "sha", cand.sha,
                                "detail", str(exc)[:200])
            return False
        self.journal.append("merge", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "method", "squash", "reason", "gates_passed")
        return True

    def reap(self, cand):
        if cand.worktree:
            try:
                subprocess.run(["git", "worktree", "remove", "--force", cand.worktree],
                               capture_output=True, text=True, check=True)
            except Exception:
                pass  # a reap that cannot remove the worktree is not fatal — the sweep retries it
        self.journal.append("reap", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "reason", "merged")
        return True


# ── the live tick: the minimal correct loop ───────────────────────────────────────────────────────

class LiveTick:
    """Walk every discovered candidate through the gate DAG to a terminal, actuating on green.

    Construct with the resolved config, a discovery, a gates dispatcher, an actuator and a journal;
    :meth:`run` processes the tick and returns a summary the tests assert on. The gate ORDER is the
    cost-classed DAG (contract §2.1): stale/dup (cheap) → health (slow) → review (LLM) → blessing →
    hold decision → apply, a non-pass at any stage short-circuiting the rest. The pure hold/merge/
    observe decision is :func:`herd.decisions.hold_decision`, reused verbatim.
    """

    def __init__(self, config, discovery, gates, actuator, journal):
        self.config = config or {}
        self.discovery = discovery
        self.gates = gates
        self.actuator = actuator
        self.journal = journal
        self._merge_policy = D.effective_merge_policy(
            self.config.get("MERGE_POLICY"), self.config.get("WATCHER_AUTOMERGE"))
        self._hv_policy = self.config.get("HUMAN_VERIFY_POLICY", "hold")
        self._state = {}       # pr -> lifecycle state (the assertion layer)
        self._outcome = {}     # pr -> terminal action string

    # lifecycle transition through SM; journal it, never let a disagreement sink the tick (as shadow).
    def _advance(self, cand, event):
        prev = self._state.get(cand.pr, _S_INTAKE)
        try:
            nxt = SM.transition(prev, event)
        except Exception as exc:
            self.journal.append("illegal_transition", "pr", cand.pr, "sha", cand.sha,
                                "state", prev, "attempted_event", event, "detail", str(exc))
            return prev
        self._state[cand.pr] = nxt
        self.journal.append("live_state", "pr", cand.pr, "sha", cand.sha, "trigger", event,
                            "state_from", prev, "state_to", nxt)
        return nxt

    def _walk(self, cand):
        """Walk one candidate's gate DAG; actuate the terminal; return the action string."""
        self._state.setdefault(cand.pr, _S_INTAKE)

        # 1. stale/dup gate (deterministic-cheap): a behind-base PR HOLDS — parking is always safe.
        if cand.stale:
            self.journal.append("stale_dup_hold", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "kind", "stale", "reason", "behind base")
            self._advance(cand, "stale_detected")
            return HOLD

        # 2. health rail (deterministic-slow) — dispatched by shelling out to the health runner.
        self._advance(cand, "dispatch_health")
        self.journal.append("healthcheck_started", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha)
        health = self.gates.health(cand)
        health = health if health in ("CLEAN", "FLAKY", "CODEERROR") else "CLEAN"
        self.journal.append("healthcheck_outcome", "pr", cand.pr, "slug", cand.slug, "outcome", health)
        self._advance(cand, {"CLEAN": "health_clean", "FLAKY": "health_flaky",
                             "CODEERROR": "health_codeerror"}[health])
        if health == "CODEERROR":
            self.journal.append("refix_bounce", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "round", 1, "rule", "healthcheck")
            return BLOCK

        # 3. review rail (LLM) — dispatched by shelling out to the adversarial reviewer.
        self.journal.append("review_dispatched", "pr", cand.pr, "sha", cand.sha, "pin", cand.sha)
        verdict = self.gates.review(cand)
        verdict = verdict if verdict in ("PASS", "BLOCK", "INFRA") else "PASS"
        if verdict == "INFRA":
            # Infra death is not a verdict — forensic record is infra_event, the caller retries (§2.2).
            self.journal.append("infra_event", "pr", cand.pr, "sha", cand.sha, "rail", "review",
                                "detail", "no parseable verdict")
            self._advance(cand, "review_infra")
            return ESCALATE
        self.journal.append("verdict_recorded", "pr", cand.pr, "sha", cand.sha, "value", verdict,
                            "source", "reviewer")
        self._advance(cand, "review_block" if verdict == "BLOCK" else "review_pass")
        if verdict == "BLOCK":
            self.journal.append("refix_bounce", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "round", 1, "rule", "review")
            return BLOCK

        # 4. the blessing — both rails passed (review_pass advanced the lifecycle to BLESSED).
        self.journal.append("blessing", "pr", cand.pr, "sha", cand.sha, "context", "herd/gates",
                            "state", "success")

        # 5. the pure hold / merge / observe decision (reused from P2, contract §2.2/§5.4-§5.5).
        action = D.hold_decision(self._merge_policy, cand.hv_hold, cand.approved, self._hv_policy)
        self._advance(cand, {"MERGE": "decide_merge", "HOLD": "decide_hold",
                             "OBSERVE": "decide_observe"}[action])

        # 6. apply — the ONLY step that actuates (and only under LiveActuator).
        if action == "MERGE":
            if self.actuator.merge(cand):
                self.actuator.reap(cand)          # reap-on-merge (contract §6.1)
                return "MERGE"
            return ESCALATE                        # merge failed → escalate, never a silent drop
        if action == "HOLD":
            self.journal.append("hold_applied", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug,
                                "kind", "approval" if self._merge_policy == "approve" else "human-verify")
            return HOLD
        # OBSERVE — observe mode never merges.
        self.journal.append("observe_noted", "pr", cand.pr, "sha", cand.sha, "slug", cand.slug)
        return "OBSERVE"

    def run(self):
        """Run one tick over all discovered candidates; return the summary."""
        candidates = self.discovery.discover()
        self.journal.append("live_tick_start", "candidates", len(candidates), "impl", "python",
                            "merge_policy", self._merge_policy)
        for cand in candidates:
            try:
                self._outcome[cand.pr] = self._walk(cand)
            except Exception as exc:
                # A single candidate's failure must never abort the tick or actuate wrongly — journal
                # it and move on (parking/skipping is safe; a wrong merge is the only unrecoverable error).
                self.journal.append("live_candidate_error", "pr", cand.pr, "sha", cand.sha,
                                    "detail", str(exc)[:200])
                self._outcome[cand.pr] = ESCALATE
        merged = [pr for pr, a in self._outcome.items() if a == "MERGE"]
        held = [pr for pr, a in self._outcome.items() if a == HOLD]
        self.journal.append("live_tick_end", "merged", len(merged), "held", len(held))
        return {"outcomes": dict(self._outcome), "merged": merged, "held": held,
                "journal": self.journal.path}


# ── config assembly (read the same knobs the bash watcher reads; env is READ-ONLY) ────────────────

def _config_from_env(scenario=None):
    config = dict((scenario or {}).get("config") or {})
    for knob in ("MERGE_POLICY", "WATCHER_AUTOMERGE", "HUMAN_VERIFY_POLICY"):
        if knob not in config and os.environ.get(knob) is not None:
            config[knob] = os.environ[knob]
    return config


def _dryrun_env():
    """True iff the watcher's dry-run switch is set — so ``--tick`` inherits it and never actuates."""
    return os.environ.get("AGENT_WATCH_DRYRUN") in ("1", "true", "yes", "on") \
        or bool(os.environ.get("DRYRUN"))


def _home():
    """The herdkit checkout root — ``HERDKIT_HOME`` else two dirs up from this file (pysrc/herd)."""
    env = os.environ.get("HERDKIT_HOME")
    if env:
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", ".."))


# ── CLI harness (the impure glue; the classes above hold the logic) ───────────────────────────────

def _parse_argv(argv):
    opts = {"dry_run": False, "tick": False, "fixture": None}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--dry-run":
            opts["dry_run"] = True
        elif a == "--tick":
            opts["tick"] = True
        elif a == "--fixture" and i + 1 < len(argv):
            opts["fixture"] = argv[i + 1]
            i += 1
        i += 1
    return opts


def _run_dry_run(fixture):
    """``--dry-run`` smoke mode: sim in, result JSON out, ZERO subprocess / gh / git / pane.

    Wires the side-effect-free column exclusively (FixtureDiscovery + FixtureGates + DryRunActuator).
    The journal path is ``LIVE_DRYRUN_JOURNAL`` if set, else ``None`` (a black hole) — it defaults to
    NEVER writing the real ``.herd/journal.jsonl``, honoring the VERIFY discipline.
    """
    raw = open(fixture, encoding="utf-8").read() if fixture else sys.stdin.read()
    scenario = json.loads(raw) if raw.strip() else {}
    config = _config_from_env(scenario)
    journal = LiveJournal(os.environ.get("LIVE_DRYRUN_JOURNAL"))
    tick = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario),
                    DryRunActuator(journal), journal)
    return tick.run()


def _run_live_tick():
    """``--tick``: one AUTHORITATIVE live tick — discover via gh, dispatch leaves, merge/reap on green.

    Inherits the watcher's dry-run switch: under ``AGENT_WATCH_DRYRUN``/``DRYRUN`` the actuator is the
    DryRunActuator (journals, no gh/git), exactly as the bash watcher's dry-run does everything except
    the real merge/remove. Returns the summary; the ``main`` wrapper turns any exception into a
    non-zero exit so the bash supervisor falls back to its own tick body for this cycle.
    """
    home = _home()
    config = _config_from_env()
    journal = LiveJournal(LiveJournal.resolve_live_path())
    actuator = DryRunActuator(journal) if _dryrun_env() else LiveActuator(home, journal)
    tick = LiveTick(config, _GraphQLDiscovery(), LiveGates(home), actuator, journal)
    return tick.run()


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    opts = _parse_argv(argv)
    try:
        if opts["tick"] and not opts["dry_run"]:
            result = _run_live_tick()
        else:
            # Default (and explicit --dry-run) is the safe smoke path — a bare invocation never actuates.
            result = _run_dry_run(opts["fixture"])
    except Exception as exc:
        # Loud to stderr, non-zero to the caller: the bash supervisor reads the exit code and falls
        # back to its own tick body (the instant-fallback kill-switch), so a port fault never stalls.
        sys.stderr.write("herd.live_runtime: tick aborted: %s\n" % exc)
        return 1
    sys.stdout.write(json.dumps(result, separators=(",", ":"), sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
