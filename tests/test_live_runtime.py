"""test_live_runtime.py — stdlib unit tests for the P3f LIVE watcher tick (HERD-320, EPIC HERD-300).

Asserts the internal invariants of the live runtime directly, HERMETICALLY: every test drives the
side-effect-free column (FixtureDiscovery + FixtureGates + DryRunActuator), so no test ever runs gh,
git, a leaf script, or a pane op. Stdlib only (unittest), so the gate needs no external dep.

Coverage:
  * DRY-RUN: the dry-run tick invokes NO subprocess (proved by poisoning live_runtime.subprocess) and
    writes only its own journal — the real journal.jsonl is never touched.
  * Gate DAG outcomes: PASS->MERGE, health CODEERROR->BLOCK (short-circuits review), review BLOCK->BLOCK,
    INFRA->ESCALATE (no verdict cached), stale->HOLD (before any rail), human-verify->HOLD,
    approve-without-approval->HOLD, approve-with->MERGE, observe->OBSERVE.
  * Reap-on-merge: a MERGE journals both a `merge` and a `reap`; a failed merge ESCALATES (never a
    silent drop and never a reap).
  * Journal shapes: ts+event first, journal.sh integer coercion, merge event dry-run shaped.
  * The review-verdict parser: PASS / BLOCK / INFRA-FAIL / advisory / empty / garbage.
  * Lifecycle assertion: an illegal transition is journaled, never fatal (as in shadow mode).
  * LiveJournal best-effort: a None path is a silent black hole that never raises.

Run:  PYTHONPATH=pysrc python3 tests/test_live_runtime.py
"""
import json
import os
import tempfile
import unittest

import subprocess
import time

from herd import live_runtime as LR
from herd.live_runtime import (LiveTick, LiveJournal, LiveState, LiveGates, LiveCandidate,
                               LiveActuator,
                               FixtureDiscovery, FixtureGates, DryRunActuator, parse_review_verdict,
                               _select_candidates, _marker_write, _marker_live, _terminate_worker,
                               WAIT, PENDING,
                               branch_to_slug, _worktree_for_slug, _is_worktree, _pool_scoped)


def _make_worktree(pool, slug):
    """Create a minimal on-disk git worktree ``<pool>/<slug>`` (a dir with a ``.git`` pointer) so the
    pool-membership / pre-dispatch guards see a real worktree — hermetic, no ``git`` invoked."""
    d = os.path.join(pool, slug)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, ".git"), "w", encoding="utf-8") as fh:
        fh.write("gitdir: /pool/.git/worktrees/%s\n" % slug)
    return d


def events(path):
    with open(path, encoding="utf-8") as fh:
        return [json.loads(l) for l in fh if l.strip()]


class _Poison:
    """A stand-in for the subprocess module whose .run() blows up — proves the dry-run path is pure."""

    def run(self, *a, **k):  # noqa: D401 - test double
        raise AssertionError("dry-run must not shell out (subprocess.run called)")


class LiveCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.jpath = os.path.join(self.tmp, "live-test.jsonl")
        os.environ["HERD_JOURNAL_NOW"] = "2026-07-10T00:00:00Z"

    def tearDown(self):
        os.environ.pop("HERD_JOURNAL_NOW", None)

    def tick(self, candidates, config=None):
        """A dry-run tick over injected candidates; returns (summary, events)."""
        scenario = {"candidates": candidates, "config": config or {"MERGE_POLICY": "auto"}}
        journal = LiveJournal(self.jpath)
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     DryRunActuator(journal), journal)
        res = t.run()
        return res, (events(self.jpath) if os.path.exists(self.jpath) else [])

    def one(self, pr=1, **kw):
        kw.setdefault("sha", "sha%s" % pr)
        return dict(pr=pr, **kw)


class TestDryRun(LiveCase):
    def test_dry_run_invokes_no_subprocess(self):
        # Poison subprocess: if the dry-run path shells out at all, the run raises.
        orig = LR.subprocess
        LR.subprocess = _Poison()
        try:
            res, _ = self.tick([self.one(1, review="PASS", health="CLEAN")])
        finally:
            LR.subprocess = orig
        self.assertEqual(res["outcomes"]["1"], "MERGE")

    def test_only_named_journal_written_not_real_journal(self):
        self.tick([self.one(1, review="PASS", health="CLEAN")])
        self.assertTrue(os.path.exists(self.jpath))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "journal.jsonl")))

    def test_black_hole_journal_never_raises(self):
        j = LiveJournal(path=None)
        self.assertFalse(j.append("x", "pr", 1))         # no destination -> advisory False, no raise
        scenario = {"candidates": [self.one(1)], "config": {"MERGE_POLICY": "auto"}}
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     DryRunActuator(j), j)
        self.assertEqual(t.run()["outcomes"]["1"], "MERGE")


class TestGateOutcomes(LiveCase):
    def _out(self, **kw):
        res, ev = self.tick([self.one(1, **{k: v for k, v in kw.items() if k != "config"})],
                            config=kw.get("config"))
        return res["outcomes"]["1"], ev

    def test_clean_pass_merges(self):
        out, _ = self._out(review="PASS", health="CLEAN")
        self.assertEqual(out, "MERGE")

    def test_flaky_still_passes_health(self):
        out, _ = self._out(review="PASS", health="FLAKY")
        self.assertEqual(out, "MERGE")

    def test_codeerror_blocks_and_short_circuits_review(self):
        out, ev = self._out(review="PASS", health="CODEERROR")
        self.assertEqual(out, "BLOCK")
        self.assertFalse([o for o in ev if o["event"] == "review_dispatched"])
        self.assertTrue([o for o in ev if o["event"] == "refix_bounce"])

    def test_review_block_blocks(self):
        out, ev = self._out(review="BLOCK", health="CLEAN")
        self.assertEqual(out, "BLOCK")
        v = [o for o in ev if o["event"] == "verdict_recorded"]
        self.assertEqual(v[0]["value"], "BLOCK")
        self.assertEqual(v[0]["source"], "reviewer")

    def test_infra_never_cached_as_verdict(self):
        out, ev = self._out(review="INFRA", health="CLEAN")
        self.assertEqual(out, "ESCALATE")
        self.assertFalse([o for o in ev if o["event"] == "verdict_recorded"])
        self.assertTrue([o for o in ev if o["event"] == "infra_event"])

    def test_stale_holds_before_any_rail(self):
        out, ev = self._out(stale=True)
        self.assertEqual(out, "HOLD")
        self.assertTrue([o for o in ev if o["event"] == "stale_dup_hold"])
        self.assertFalse([o for o in ev if o["event"] == "healthcheck_started"])

    def test_human_verify_holds_under_auto(self):
        out, _ = self._out(review="PASS", health="CLEAN", hv_hold=True)
        self.assertEqual(out, "HOLD")

    def test_approve_policy_holds_without_approval(self):
        out, _ = self._out(review="PASS", health="CLEAN", config={"MERGE_POLICY": "approve"})
        self.assertEqual(out, "HOLD")

    def test_approve_policy_merges_with_approval(self):
        out, _ = self._out(review="PASS", health="CLEAN", approved=True,
                           config={"MERGE_POLICY": "approve"})
        self.assertEqual(out, "MERGE")

    def test_observe_never_merges(self):
        out, ev = self._out(review="PASS", health="CLEAN", config={"MERGE_POLICY": "observe"})
        self.assertEqual(out, "OBSERVE")
        self.assertFalse([o for o in ev if o["event"] == "merge"])

    def test_refix_bounce_carries_contract_fields(self):
        # HERD-321: the authoritative live writer must emit the full contract §3.4 refix_bounce shape
        # for BOTH rails (pr, sha, slug, round, agent_status_before, rule, location) — matching the
        # shadow twin so a shadow<->live parity diff stays clean.
        for rule, kw in (("healthcheck", dict(health="CODEERROR")),
                         ("review", dict(review="BLOCK", health="CLEAN"))):
            _, ev = self._out(**kw)
            # ev reads the shared per-test journal (setUp runs once), so filter by rail.
            rb = [o for o in ev if o["event"] == "refix_bounce" and o.get("rule") == rule]
            self.assertEqual(len(rb), 1, rule)
            for k in ("pr", "sha", "slug", "round", "agent_status_before", "rule", "location"):
                self.assertIn(k, rb[0], "%s missing %s" % (rule, k))

    def test_refix_round_is_real_not_hardcoded(self):
        # HERD-328 S2: the round a refix_bounce carries is the per-(pr, rule) bounce count + 1
        # (bash's `refix_rail_count + 1`), NOT a hardcoded 1. The first bounce reads round=1, then the
        # rail counter increments per rail INDEPENDENTLY of the other rail and of other PRs.
        _, ev = self._out(health="CODEERROR")
        rb = [o for o in ev if o["event"] == "refix_bounce" and o.get("rule") == "healthcheck"]
        self.assertEqual(rb[0]["round"], 1)
        # Drive the counter directly on one tick instance: it is per (pr, rule), monotonic, isolated.
        t = LiveTick({"MERGE_POLICY": "auto"}, FixtureDiscovery({"candidates": []}),
                     FixtureGates({"candidates": []}), DryRunActuator(LiveJournal(None)),
                     LiveJournal(None))
        self.assertEqual([t._next_refix_round(1, "review") for _ in range(3)], [1, 2, 3])
        self.assertEqual(t._next_refix_round(1, "healthcheck"), 1)   # a different rail is its own count
        self.assertEqual(t._next_refix_round(2, "review"), 1)        # a different pr is its own count


class TestReapAndActuation(LiveCase):
    def test_merge_reaps(self):
        _, ev = self.tick([self.one(1, review="PASS", health="CLEAN", worktree="/wt/1")])
        self.assertTrue([o for o in ev if o["event"] == "merge"])
        reaps = [o for o in ev if o["event"] == "reap"]
        self.assertEqual(len(reaps), 1)
        self.assertEqual(reaps[0]["reason"], "merged")

    def test_refused_merge_stays_blessed_and_never_reaps(self):
        # HERD-352: a refused merge (actuator returns False) STAYS BLESSED — it HOLDS and re-attempts next
        # tick, never reaps, never a silent drop. Escalation is only after N consecutive refusals (below).
        class FailMerge(DryRunActuator):
            def merge(self, cand):
                return False
        scenario = {"candidates": [self.one(1, review="PASS", health="CLEAN")],
                    "config": {"MERGE_POLICY": "auto"}}
        journal = LiveJournal(self.jpath)
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     FailMerge(journal), journal)
        res = t.run()
        self.assertEqual(res["outcomes"]["1"], "HOLD")   # stays blessed, not ESCALATE on the first refusal
        self.assertFalse([o for o in events(self.jpath) if o["event"] == "reap"])

    def test_repeated_refusals_escalate_with_loud_row_after_n(self):
        # HERD-352: with a REAL state dir the refusal counter persists across ticks; the Nth consecutive
        # refusal escalates and journals a loud needs_you row so a wedged merge cannot fail silently.
        class FailMerge(DryRunActuator):
            def merge(self, cand):
                return False
        scenario = {"candidates": [self.one(1, review="PASS", health="CLEAN")],
                    "config": {"MERGE_POLICY": "auto"}}
        outcomes = []
        for _ in range(LR._MERGE_REFUSE_MAX):
            journal = LiveJournal(self.jpath)
            t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                         FailMerge(journal), journal, state=LiveState(self.tmp))
            outcomes.append(t.run()["outcomes"]["1"])
        self.assertEqual(outcomes[:-1], ["HOLD"] * (LR._MERGE_REFUSE_MAX - 1))  # below N: stays blessed
        self.assertEqual(outcomes[-1], "ESCALATE")                               # at N: escalate
        needs = [o for o in events(self.jpath) if o["event"] == "merge_refused_escalated"]
        self.assertEqual(len(needs), 1)
        self.assertEqual(needs[0]["reason"], "merge refused")
        self.assertEqual(needs[0]["count"], LR._MERGE_REFUSE_MAX)
        self.assertFalse([o for o in events(self.jpath) if o["event"] == "reap"])


class TestJournalShapes(LiveCase):
    def test_ts_and_event_lead_and_merge_shaped(self):
        _, ev = self.tick([self.one(1, slug="feat-a", review="PASS", health="CLEAN")])
        self.assertTrue(ev)
        for o in ev:
            keys = list(o.keys())
            self.assertEqual(keys[0], "ts")
            self.assertEqual(keys[1], "event")
        m = [o for o in ev if o["event"] == "merge"][0]
        self.assertEqual(m["reason"], "gates_passed")
        self.assertEqual(m["method"], "squash")
        self.assertEqual(m["pr"], 1)          # integer coercion (journal.sh parity)
        start = [o for o in ev if o["event"] == "live_tick_start"][0]
        self.assertEqual(start["impl"], "python")


class TestReviewDispatchShape(LiveCase):
    """HERD-321: the real _dispatch_review path (bypassed by FixtureGates) must emit review_dispatched
    with the full contract §3.4 shape (pr, sha, pid, model, log_path, pin). Hermetic: a fresh temp
    state dir forces a dispatch and subprocess.Popen is stubbed, so no reviewer is ever launched."""

    def test_review_dispatched_carries_contract_fields(self):
        class _Proc:
            pid = 4242

        class _FakeSub:
            DEVNULL = LR.subprocess.DEVNULL

            def Popen(self, *a, **k):
                return _Proc()

        state = LiveState(state_dir=self.tmp)          # real (empty) state dir -> no cached verdict/marker
        journal = LiveJournal(self.jpath)
        gates = LiveGates("/nonexistent-home", state, journal)
        orig = LR.subprocess
        LR.subprocess = _FakeSub()
        os.environ["MODEL_REVIEW"] = "opus-x"
        try:
            v = gates.review(LiveCandidate(7, "deadbeef", slug="feat-x"))
        finally:
            LR.subprocess = orig
            os.environ.pop("MODEL_REVIEW", None)
        self.assertEqual(v, WAIT)                       # dispatched -> WAIT
        rd = [o for o in events(self.jpath) if o["event"] == "review_dispatched"]
        self.assertEqual(len(rd), 1)
        for k in ("pr", "sha", "pid", "model", "log_path", "pin"):
            self.assertIn(k, rd[0])
        self.assertEqual(rd[0]["model"], "opus-x")      # bash env-fallback chain
        self.assertTrue(rd[0]["log_path"])              # the reviewer's result-file path, non-empty


class _FakeCompleted:
    """Stand-in for a subprocess.CompletedProcess — carries a captured stdout for the API verify read."""

    def __init__(self, stdout=""):
        self.stdout = stdout


class _RecordingSub:
    """A subprocess stand-in that RECORDS every argv and returns scripted results — proves the LIVE
    actuator's gh shape without ever launching gh. ``view_state`` scripts what ``gh pr view`` reports;
    ``fail`` (a set of subcommand tokens) makes those calls raise, simulating a gh outage / non-zero exit."""

    DEVNULL = subprocess.DEVNULL

    def __init__(self, view_state="MERGED", fail=()):
        self.calls = []
        self.view_state = view_state
        self.fail = set(fail)

    def run(self, argv, *a, **k):
        self.calls.append(list(argv))
        # argv[1] is the gh subcommand: "pr" (merge/view) or "api" (statuses post).
        if "api" in argv and "api" in self.fail:
            raise subprocess.CalledProcessError(1, argv)
        if argv[:3] == ["gh", "pr", "merge"]:
            if "merge" in self.fail:
                raise subprocess.CalledProcessError(1, argv)
            return _FakeCompleted("")
        if argv[:3] == ["gh", "pr", "view"]:
            if "view" in self.fail:
                raise subprocess.CalledProcessError(1, argv)
            return _FakeCompleted(self.view_state + "\n")
        return _FakeCompleted("")


class TestLiveMergeVerify(LiveCase):
    """HERD-352: the LIVE merge actuator verifies via the GitHub API that the PR actually reached MERGED
    before it treats the merge as done — a stubbed-gh 'refusal sim' proves an unconfirmed merge is
    journaled `merge_refused`, never `merge`, never reaped. Hermetic: subprocess is stubbed, no gh runs."""

    def _actuator(self, sub):
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        return LiveActuator("/nonexistent-home", LiveJournal(self.jpath))

    def _cand(self):
        return LiveCandidate(7, "deadbeef", slug="feat-x", worktree="")

    def test_merged_state_journals_merge_and_returns_true(self):
        sub = _RecordingSub(view_state="MERGED")
        act = self._actuator(sub)
        self.assertTrue(act.merge(self._cand()))
        ev = events(self.jpath)
        self.assertEqual(len([o for o in ev if o["event"] == "merge"]), 1)
        self.assertFalse([o for o in ev if o["event"] == "merge_refused"])
        # It ran `gh pr view` to VERIFY, not just `gh pr merge`.
        self.assertTrue(any(c[:3] == ["gh", "pr", "view"] for c in sub.calls))

    def test_unmerged_state_is_refused_not_merged(self):
        sub = _RecordingSub(view_state="OPEN")
        act = self._actuator(sub)
        self.assertFalse(act.merge(self._cand()))
        ev = events(self.jpath)
        self.assertFalse([o for o in ev if o["event"] == "merge"])       # never claims a merge it can't confirm
        ref = [o for o in ev if o["event"] == "merge_refused"]
        self.assertEqual(len(ref), 1)
        self.assertEqual(ref[0]["state"], "OPEN")

    def test_nonzero_merge_exit_but_api_confirms_merged(self):
        # HERD-221 shape: gh pr merge exits non-zero (e.g. branch-delete race) yet the PR IS merged —
        # the API state, not the exit code, is authoritative, so this is a real merge, not a refusal.
        sub = _RecordingSub(view_state="MERGED", fail={"merge"})
        act = self._actuator(sub)
        self.assertTrue(act.merge(self._cand()))
        self.assertEqual(len([o for o in events(self.jpath) if o["event"] == "merge"]), 1)

    def test_unreadable_state_fails_closed_with_honest_label(self):
        # HONEST LABELS (HERD-232): a gh outage on the verify read is NOT a genuine refusal — it fails
        # CLOSED as merge_gh_unreadable (an infra event), never merge, never a fabricated merge_refused.
        sub = _RecordingSub(fail={"view"})
        act = self._actuator(sub)
        self.assertFalse(act.merge(self._cand()))
        ev = events(self.jpath)
        self.assertEqual(len([o for o in ev if o["event"] == "merge_gh_unreadable"]), 1)
        self.assertFalse([o for o in ev if o["event"] == "merge_refused"])
        self.assertFalse([o for o in ev if o["event"] == "merge"])


class TestLiveGateStatusPost(LiveCase):
    """HERD-352: on gates-clear the LIVE actuator posts a herd/gates=success commit status (GATE_STATUS=on
    contract) and journals `gate_status`; GATE_STATUS=off is byte-inert. Hermetic: subprocess is stubbed."""

    def _actuator(self, sub):
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        return LiveActuator("/nonexistent-home", LiveJournal(self.jpath))

    def test_post_uses_success_only_status_shape(self):
        sub = _RecordingSub()
        act = self._actuator(sub)
        self.assertTrue(act.post_gate_status(LiveCandidate(7, "deadbeef", slug="feat-x")))
        # The gh api call carries the exact success-only status shape bash posts.
        api = [c for c in sub.calls if "api" in c][0]
        self.assertIn("repos/{owner}/{repo}/statuses/deadbeef", api)
        self.assertIn("state=success", api)
        self.assertIn("context=herd/gates", api)
        gs = [o for o in events(self.jpath) if o["event"] == "gate_status"]
        self.assertEqual(len(gs), 1)
        self.assertEqual(gs[0]["state"], "success")
        self.assertEqual(gs[0]["context"], "herd/gates")

    def test_failed_post_journals_nothing_and_retries(self):
        sub = _RecordingSub(fail={"api"})
        act = self._actuator(sub)
        self.assertFalse(act.post_gate_status(LiveCandidate(7, "deadbeef", slug="feat-x")))
        ev = events(self.jpath) if os.path.exists(self.jpath) else []   # a failed post journals nothing
        self.assertFalse([o for o in ev if o["event"] == "gate_status"])

    def test_tick_posts_once_when_on_and_never_when_off(self):
        # Drive the whole blessed tick with a recording actuator to prove the LEVER: on → exactly one post
        # per (pr,sha) across re-walks; off → byte-inert (zero posts, zero gate_status journal lines).
        class Recorder(DryRunActuator):
            def __init__(self, journal):
                super().__init__(journal)
                self.posts = 0

            def post_gate_status(self, cand):
                self.posts += 1
                self.journal.append("gate_status", "pr", cand.pr, "sha", cand.sha, "state", "success",
                                    "context", "herd/gates")
                return True

        def run(config):
            journal = LiveJournal(self.jpath)
            rec = Recorder(journal)
            state = LiveState(self.tmp)
            t1 = LiveTick(config, FixtureDiscovery({"candidates": [self.one(1, review="PASS", health="CLEAN")]}),
                          FixtureGates({"candidates": [self.one(1, review="PASS", health="CLEAN")]}),
                          rec, journal, state=state)
            t1.run()
            # Re-walk the same (pr,sha): the ledger marker must suppress a second post.
            t2 = LiveTick(config, FixtureDiscovery({"candidates": [self.one(1, review="PASS", health="CLEAN")]}),
                          FixtureGates({"candidates": [self.one(1, review="PASS", health="CLEAN")]}),
                          rec, journal, state=LiveState(self.tmp))
            t2.run()
            return rec.posts

        self.assertEqual(run({"MERGE_POLICY": "observe", "GATE_STATUS": "on"}), 1)   # posted once, deduped
        # Fresh state dir for the off run so the on-run's ledger marker doesn't mask the lever.
        self.tmp = tempfile.mkdtemp()
        self.jpath = os.path.join(self.tmp, "live-test.jsonl")
        self.assertEqual(run({"MERGE_POLICY": "observe", "GATE_STATUS": "off"}), 0)  # byte-inert


class TestVerdictParser(unittest.TestCase):
    def test_pass(self):
        self.assertEqual(parse_review_verdict("REVIEW: PASS"), "PASS")

    def test_pass_with_advisory(self):
        self.assertEqual(parse_review_verdict("REVIEW: PASS — advisory: tidy up later"), "PASS")

    def test_block_structured(self):
        self.assertEqual(
            parse_review_verdict("REVIEW: BLOCK — rule: x | why: y | location: f:1"), "BLOCK")

    def test_infra(self):
        self.assertEqual(parse_review_verdict("REVIEW: INFRA-FAIL — model timed out"), "INFRA")

    def test_no_line_is_infra(self):
        self.assertEqual(parse_review_verdict("some log\nno verdict here"), "INFRA")

    def test_last_review_line_wins(self):
        self.assertEqual(parse_review_verdict("REVIEW: BLOCK\nREVIEW: PASS"), "PASS")

    def test_empty_is_infra(self):
        self.assertEqual(parse_review_verdict(""), "INFRA")


class TestLifecycleAssertion(LiveCase):
    def test_illegal_transition_is_observed_not_fatal(self):
        scenario = {"candidates": [], "config": {"MERGE_POLICY": "auto"}}
        journal = LiveJournal(self.jpath)
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     DryRunActuator(journal), journal)
        c = LR.LiveCandidate(pr=9, sha="s9")
        t._state["9"] = getattr(LR.SM, "MERGED", "MERGED")   # terminal state — no outgoing edge
        t._advance(c, "dispatch_health")                     # illegal; must be journaled, not raised
        self.assertTrue([o for o in events(self.jpath) if o["event"] == "illegal_transition"])


class TestManyCandidates(LiveCase):
    def test_mixed_tick(self):
        res, ev = self.tick([
            self.one(1, review="PASS", health="CLEAN"),
            self.one(2, stale=True),
            self.one(3, review="BLOCK", health="CLEAN"),
            self.one(4, review="PASS", health="CLEAN", hv_hold=True),
        ])
        self.assertEqual(res["outcomes"]["1"], "MERGE")
        self.assertEqual(res["outcomes"]["2"], "HOLD")
        self.assertEqual(res["outcomes"]["3"], "BLOCK")
        self.assertEqual(res["outcomes"]["4"], "HOLD")
        end = [o for o in ev if o["event"] == "live_tick_end"][0]
        self.assertEqual(end["merged"], 1)
        self.assertEqual(end["held"], 2)


class TestPendingDAG(LiveCase):
    """The async DISPATCH-AND-WAIT path: a WAIT rail holds the candidate as PENDING, never a BLOCK,
    and never merges (task HERD-324 leg 1)."""

    def test_health_wait_is_pending_not_block(self):
        res, ev = self.tick([self.one(1, health=WAIT)])
        self.assertEqual(res["outcomes"]["1"], PENDING)
        self.assertTrue([o for o in ev if o["event"] == "health_pending"])
        self.assertFalse([o for o in ev if o["event"] == "merge"])
        # A missing health verdict must never short-circuit to review.
        self.assertFalse([o for o in ev if o["event"] == "verdict_recorded"])

    def test_review_wait_is_pending_not_merge(self):
        res, ev = self.tick([self.one(1, health="CLEAN", review=WAIT)])
        self.assertEqual(res["outcomes"]["1"], PENDING)
        self.assertTrue([o for o in ev if o["event"] == "review_pending"])
        self.assertFalse([o for o in ev if o["event"] == "merge"])

    def test_pending_counted_in_summary(self):
        res, _ = self.tick([self.one(1, health="CLEAN", review="PASS"),
                            self.one(2, review=WAIT)])
        self.assertEqual(res["merged"], ["1"])
        self.assertEqual(res["pending"], ["2"])


class TestReviewOnceAndMarkers(unittest.TestCase):
    """Leg 1: the sha-keyed review-once ledger + in-flight markers shared with bash. All hermetic —
    the actual dispatch (Popen herd-review.sh / the health worker) is stubbed, so no gh / git / suite
    runs; only the shared on-disk contract under $TREES is exercised."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["HERD_JOURNAL_NOW"] = "2026-07-10T00:00:00Z"
        self.state = LiveState(self.tmp)
        self.journal = LiveJournal(os.path.join(self.tmp, "j.jsonl"))

    def tearDown(self):
        os.environ.pop("HERD_JOURNAL_NOW", None)

    def _gates(self):
        disp_r, disp_h = [], []

        class Stub(LiveGates):
            def _dispatch_review(self, cand):
                disp_r.append(cand.pr)
                _marker_write(self.state.review_inflight_file(cand), os.getpid())

            def _dispatch_health(self, cand):
                disp_h.append(cand.pr)
                _marker_write(self.state.health_inflight_file(cand), os.getpid())

        g = Stub("/home", self.state, self.journal)
        return g, disp_r, disp_h

    def cand(self, pr=1, sha="s1"):
        return LiveCandidate(pr=pr, sha=sha, slug="feat-%s" % pr)

    # ── review-once reuse ──
    def test_recorded_verdict_reused_no_dispatch(self):
        c = self.cand()
        self.state.record_review(c.pr, c.sha, "PASS")
        g, dr, _ = self._gates()
        self.assertEqual(g.review(c), "PASS")
        self.assertTrue(g.reused_review)
        self.assertEqual(dr, [])                       # review-once: a recorded verdict never re-dispatches

    def test_recorded_verdict_is_sha_keyed(self):
        c1, c2 = self.cand(1, "old"), self.cand(1, "new")
        self.state.record_review(c1.pr, c1.sha, "PASS")
        g, dr, _ = self._gates()
        self.assertEqual(g.review(c1), "PASS")         # old sha: reuse
        self.assertEqual(g.review(c2), WAIT)           # new sha: no verdict → dispatch-and-wait
        self.assertEqual(dr, ["1"])

    # ── dispatch-and-wait + no double-dispatch across a flip ──
    def test_missing_verdict_dispatches_and_waits(self):
        g, dr, _ = self._gates()
        self.assertEqual(g.review(self.cand()), WAIT)  # a missing verdict is WAIT, never BLOCK
        self.assertEqual(dr, ["1"])

    def test_live_inflight_marker_blocks_second_dispatch(self):
        c = self.cand()
        g, dr, _ = self._gates()
        self.assertEqual(g.review(c), WAIT)            # tick 1: dispatch, lay marker
        self.assertEqual(g.review(c), WAIT)            # tick 2 (a bash↔python flip): marker live → wait
        self.assertEqual(dr, ["1"])                    # dispatched exactly once — no double-Opus

    def test_registry_live_blocks_dispatch(self):
        c = self.cand()
        with open(self.state.review_registry_file(c), "w") as fh:
            fh.write("%s pane-7\n" % os.getpid())      # a live reviewer pane, poller dead
        g, dr, _ = self._gates()
        self.assertEqual(g.review(c), WAIT)
        self.assertEqual(dr, [])

    # ── collect a finished verdict into the ledger ──
    def test_collect_pass_records_ledger_and_clears_scratch(self):
        c = self.cand()
        result = self.state.review_result_file(c)
        with open(result, "w") as fh:
            fh.write("REVIEW: PASS\n")
        g, dr, _ = self._gates()
        self.assertEqual(g.review(c), "PASS")
        self.assertFalse(g.reused_review)              # freshly collected, not reused
        self.assertEqual(self.state.recorded_review(c.pr, c.sha), "PASS")   # durably recorded
        self.assertFalse(os.path.exists(result))       # scratch dropped after the durable record
        # A later tick reuses the ledger verdict without re-dispatch.
        self.assertEqual(g.review(c), "PASS")
        self.assertEqual(dr, [])

    def test_collect_infra_never_cached(self):
        c = self.cand()
        with open(self.state.review_result_file(c), "w") as fh:
            fh.write("REVIEW: INFRA-FAIL — model timed out\n")
        g, _, _ = self._gates()
        self.assertEqual(g.review(c), "INFRA")
        self.assertIsNone(self.state.recorded_review(c.pr, c.sha))   # infra death is never a verdict

    # ── health: sha-cache reuse, collect, dispatch-and-wait ──
    def test_health_cache_reused(self):
        c = self.cand()
        self.state.record_health_result(c, "CLEAN", "clean")
        g, _, dh = self._gates()
        self.assertEqual(g.health(c), "CLEAN")
        self.assertTrue(g.reused_health)
        self.assertEqual(dh, [])

    def test_health_collect_writes_sha_cache(self):
        c = self.cand()
        with open(self.state.health_dispatch_file(c), "w") as fh:
            fh.write("CODEERROR\tnot ok 3 - foo.bats\n")
        g, _, dh = self._gates()
        self.assertEqual(g.health(c), "CODEERROR")
        self.assertEqual(self.state.health_cached_verdict(c), "CODEERROR")
        self.assertFalse(os.path.exists(self.state.health_dispatch_file(c)))

    def test_health_missing_dispatches_and_waits_once(self):
        c = self.cand()
        g, _, dh = self._gates()
        self.assertEqual(g.health(c), WAIT)
        self.assertEqual(g.health(c), WAIT)            # marker live → no second suite
        self.assertEqual(dh, ["1"])

    def test_marker_live_dead_pid(self):
        c = self.cand()
        f = self.state.review_inflight_file(c)
        with open(f, "w") as fh:
            fh.write("999999\n\n0\n")                  # a pid that isn't alive
        self.assertFalse(_marker_live(f))


class TestJournalWiring(unittest.TestCase):
    """Leg 2: a live actuating tick REFUSES to run unjournaled — never journal:null."""

    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in
                       ("JOURNAL_FILE", "WORKTREES_DIR", "TREES", "AGENT_WATCH_DRYRUN", "DRYRUN")}
        for k in self._saved:
            os.environ.pop(k, None)

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_live_tick_refuses_unjournaled(self):
        # No JOURNAL_FILE, no WORKTREES_DIR, not dry-run → resolve_live_path is None → FAIL LOUD before
        # any discovery/actuation (so no gh runs). main() turns the raise into a non-zero exit.
        with self.assertRaises(RuntimeError):
            LR._run_live_tick()
        self.assertEqual(LR.main(["--tick"]), 1)

    def test_resolve_live_path_from_worktrees_dir(self):
        os.environ["WORKTREES_DIR"] = "/pool"
        self.assertEqual(LR.LiveJournal.resolve_live_path(), "/pool/.herd/journal.jsonl")

    def test_journal_file_override_wins(self):
        os.environ["WORKTREES_DIR"] = "/pool"
        os.environ["JOURNAL_FILE"] = "/x/j.jsonl"
        self.assertEqual(LR.LiveJournal.resolve_live_path(), "/x/j.jsonl")


class TestScopeFilter(unittest.TestCase):
    """Leg 3: WATCHER_SCOPE/WATCHER_VIEW/owner filters narrow discovery so a foreign-owner PR never
    enters classification — identical to the bash tick, hermetic (owner supplied, no gh)."""

    def cands(self):
        return [LiveCandidate(pr=1, sha="a", author="alice", labels=["dependencies"],
                              review_decision="REVIEW_REQUIRED", assignees=["carol"]),
                LiveCandidate(pr=2, sha="b", author="bob", labels=[], assignees=[])]

    def prs(self, cs):
        return sorted(c.pr for c in cs)

    def test_default_passthrough(self):
        self.assertEqual(self.prs(_select_candidates(self.cands(), {})), ["1", "2"])

    def test_scope_all_drops_foreign_owner(self):
        got = _select_candidates(self.cands(), {"WATCHER_SCOPE": "all", "WATCHER_OWNER": "alice"})
        self.assertEqual(self.prs(got), ["1"])          # bob's PR never enters classification

    def test_scope_all_failclosed_when_owner_unresolved(self):
        orig = LR._resolve_owner
        LR._resolve_owner = lambda cfg: ""
        try:
            got = _select_candidates(self.cands(), {"WATCHER_SCOPE": "all"})
        finally:
            LR._resolve_owner = orig
        self.assertEqual(got, [])                        # fail-closed: no owner → never merge a foreign PR

    def test_scope_mine_default_no_owner_probe(self):
        # solo default: no ownership gate, every candidate flows (byte-identical to today's solo watcher).
        got = _select_candidates(self.cands(), {"WATCHER_SCOPE": "mine"})
        self.assertEqual(self.prs(got), ["1", "2"])

    def test_view_mine_lens(self):
        got = _select_candidates(self.cands(), {"WATCHER_VIEW": "mine", "WATCHER_VIEW_AUTHOR": "bob"})
        self.assertEqual(self.prs(got), ["2"])

    def test_view_label_filter(self):
        got = _select_candidates(self.cands(), {"WATCHER_VIEW_LABEL": "dependencies"})
        self.assertEqual(self.prs(got), ["1"])

    def test_view_deps_lens(self):
        got = _select_candidates(self.cands(), {"WATCHER_VIEW": "deps"})
        self.assertEqual(self.prs(got), ["1"])

    def test_view_review_queue_lens(self):
        got = _select_candidates(self.cands(), {"WATCHER_VIEW": "review-queue"})
        self.assertEqual(self.prs(got), ["1"])

    def test_fixture_discovery_applies_scope(self):
        scenario = {"config": {"WATCHER_SCOPE": "all", "WATCHER_OWNER": "alice"},
                    "candidates": [{"pr": 1, "sha": "a", "author": "alice"},
                                   {"pr": 2, "sha": "b", "author": "bob"}]}
        got = FixtureDiscovery(scenario).discover()
        self.assertEqual([c.pr for c in got], ["1"])

    def test_foreign_owner_never_merges_end_to_end(self):
        # A green teammate PR under scope=all is dropped at discovery → no merge event for it.
        os.environ["HERD_JOURNAL_NOW"] = "2026-07-10T00:00:00Z"
        try:
            tmp = tempfile.mkdtemp()
            jpath = os.path.join(tmp, "j.jsonl")
            journal = LiveJournal(jpath)
            scenario = {"config": {"MERGE_POLICY": "auto", "WATCHER_SCOPE": "all",
                                   "WATCHER_OWNER": "alice"},
                        "candidates": [
                            {"pr": 1, "sha": "a", "author": "alice", "review": "PASS", "health": "CLEAN"},
                            {"pr": 2, "sha": "b", "author": "bob", "review": "PASS", "health": "CLEAN"}]}
            t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                         DryRunActuator(journal), journal, state=LiveState(None))
            res = t.run()
            self.assertEqual(res["merged"], ["1"])
            self.assertNotIn("2", res["outcomes"])       # bob never classified
        finally:
            os.environ.pop("HERD_JOURNAL_NOW", None)


class TestSupersessionCancel(unittest.TestCase):
    """HERD-341: discovery → supersession-cancel. A candidate whose head sha has moved past an in-flight
    worker's sha TERMs that doomed worker — by a SESSION kill of its whole detached subtree (HERD-283/348:
    the worker is a session leader, so the leader's process group alone would miss the timeout-re-grouped
    suite children), plus the reviewer's STAMPED PANE retired — and journals `gate_superseded` (contract
    §2.4/§6.1). Hermetic: the only processes are throwaway `sleep`s this test spawns; no gh/git/model."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = LiveState(self.tmp)
        self.journal = LiveJournal(os.path.join(self.tmp, "j.jsonl"))
        os.environ["HERD_JOURNAL_NOW"] = "2026-07-10T00:00:00Z"
        os.environ["HERD_HEALTH_TERM_SLEEP"] = "0.01"    # no real wall-clock in the TERM→KILL grace
        self._procs = []

    def tearDown(self):
        for p in self._procs:
            try:
                p.kill(); p.wait(timeout=2)
            except Exception:
                pass
        os.environ.pop("HERD_JOURNAL_NOW", None)
        os.environ.pop("HERD_HEALTH_TERM_SLEEP", None)

    def _worker(self):
        """A throwaway worker in its OWN session (start_new_session → session leader, sid == pid), like a
        dispatched gate worker. Its marker records that session; a supersession reaps it. Returns Popen."""
        p = subprocess.Popen(["sleep", "300"], start_new_session=True)
        self._procs.append(p)
        return p

    def _events(self):
        jp = self.journal.path
        return events(jp) if os.path.exists(jp) else []

    def _tick(self):
        return LiveTick({"MERGE_POLICY": "observe"}, FixtureDiscovery({"candidates": []}),
                        FixtureGates({"candidates": []}), DryRunActuator(self.journal),
                        self.journal, state=self.state)

    def _alive(self, pid):
        try:
            os.kill(pid, 0)
            return True
        except Exception:
            return False

    # ── health rail: a superseded sha's suite worker is session-killed + journaled ──
    def test_stale_health_worker_terminated_and_journaled(self):
        p = self._worker()
        marker = self.state._sha_path(".health-inflight", 5, "oldsha")
        _marker_write(marker, p.pid)                       # records the worker's session (line 4)
        # scratch the worker left behind, keyed to the OLD sha, must be reaped too.
        for f in (self.state.health_dispatch_file_sha(5, "oldsha"),
                  self.state.health_result_file_sha(5, "oldsha")):
            open(f, "w").close()
        self._tick()._supersede_stale([LiveCandidate(5, "newsha")])
        self.assertFalse(self._alive(p.pid))              # the doomed worker is dead
        self.assertFalse(os.path.exists(marker))          # marker reaped
        self.assertFalse(os.path.exists(self.state.health_dispatch_file_sha(5, "oldsha")))
        gs = [o for o in self._events() if o["event"] == "gate_superseded"]
        self.assertEqual(len(gs), 1)
        self.assertEqual((gs[0]["rail"], gs[0]["old_sha"], gs[0]["new_sha"], gs[0]["action"]),
                         ("health", "oldsha", "newsha", "session_kill"))

    # ── review rail: a superseded reviewer is terminated + its stamped pane retired ──
    def test_stale_reviewer_terminated_pane_retired_and_journaled(self):
        p = self._worker()
        marker = self.state._sha_path(".review-inflight", 8, "old8")
        _marker_write(marker, p.pid)
        with open(self.state.review_registry_file_sha(8, "old8"), "w") as fh:
            fh.write("%s review-pane-42\n" % p.pid)        # the reviewer's STAMPED pane
        self._tick()._supersede_stale([LiveCandidate(8, "new8")])
        self.assertFalse(self._alive(p.pid))
        self.assertFalse(os.path.exists(marker))
        self.assertFalse(os.path.exists(self.state.review_registry_file_sha(8, "old8")))
        gs = [o for o in self._events() if o["event"] == "gate_superseded" and o["rail"] == "review"]
        self.assertEqual(len(gs), 1)
        self.assertEqual(gs[0]["action"], "pane_retired")
        self.assertEqual(gs[0]["pane"], "review-pane-42")   # the stamp is carried into the forensic record

    # ── the CURRENT sha's worker is NEVER touched ──
    def test_current_sha_worker_is_preserved(self):
        p = self._worker()
        marker = self.state._sha_path(".health-inflight", 5, "cur")
        _marker_write(marker, p.pid)
        self._tick()._supersede_stale([LiveCandidate(5, "cur")])
        self.assertTrue(self._alive(p.pid))               # still running — its sha IS the head
        self.assertTrue(os.path.exists(marker))
        self.assertEqual([o for o in self._events() if o["event"] == "gate_superseded"], [])

    # ── a foreign PR's stale worker is not touched by an unrelated candidate ──
    def test_only_matching_pr_is_superseded(self):
        p = self._worker()
        marker = self.state._sha_path(".health-inflight", 7, "old7")
        _marker_write(marker, p.pid)
        self._tick()._supersede_stale([LiveCandidate(5, "newsha")])   # candidate is PR 5, not 7
        self.assertTrue(self._alive(p.pid))
        self.assertTrue(os.path.exists(marker))

    # ── a dead/recycled marker is reaped with no signal, no false gate_superseded ──
    def test_dead_marker_reaped_without_signal(self):
        marker = self.state._sha_path(".health-inflight", 5, "old")
        with open(marker, "w") as fh:
            fh.write("999999\n\n0\n999999\n")             # a pid that isn't alive
        self.assertTrue(_terminate_worker(marker))        # already gone → True
        self._tick()._supersede_stale([LiveCandidate(5, "new")])
        self.assertFalse(os.path.exists(marker))          # reaped
        gs = [o for o in self._events() if o["event"] == "gate_superseded"]
        self.assertEqual(len(gs), 1)                      # journaled once (the stale sha was cleared)

    # ── the session kill reaps a whole SUBTREE, not just the leader (the HERD-283/348 property) ──
    def test_session_kill_reaps_child_subtree(self):
        # A leader in its own session that forks a child sharing that session; a single-pid kill of the
        # leader would leave the child running — the SESSION kill reaps both.
        script = ("import os,sys,time\n"
                  "cpid=os.fork()\n"
                  "if cpid==0:\n"
                  "  os.execvp('sleep',['sleep','300'])\n"
                  "open(sys.argv[1],'w').write(str(cpid))\n"
                  "time.sleep(300)\n")
        pidfile = os.path.join(self.tmp, "child.pid")
        leader = subprocess.Popen(["python3", "-c", script, pidfile], start_new_session=True)
        self._procs.append(leader)
        for _ in range(200):
            if os.path.exists(pidfile) and open(pidfile).read().strip():
                break
            time.sleep(0.01)
        child = int(open(pidfile).read().strip())
        marker = self.state._sha_path(".health-inflight", 9, "old9")
        _marker_write(marker, leader.pid)                 # records the leader's session
        self._tick()._supersede_stale([LiveCandidate(9, "new9")])
        self.assertFalse(self._alive(leader.pid))
        # The child (a separate pid in the same session) must also be gone — proves the session kill.
        for _ in range(200):
            if not self._alive(child):
                break
            time.sleep(0.01)
        self.assertFalse(self._alive(child), "session-kill must reap the child subtree, not just the leader")

    # ── sim/dry-run (no state dir) is a hard no-op ──
    def test_no_state_dir_is_noop(self):
        j = LiveJournal(None)
        t = LiveTick({"MERGE_POLICY": "auto"}, FixtureDiscovery({"candidates": []}),
                     FixtureGates({"candidates": []}), DryRunActuator(j), j, state=LiveState(None))
        t._supersede_stale([LiveCandidate(1, "s1")])       # must not raise, must not journal
        self.assertEqual(list(LiveState(None).stale_inflight(".health-inflight", 1, "s1")), [])

    # ── end-to-end: a full tick supersedes a stale worker, then walks the fresh candidate to merge ──
    def test_full_tick_supersedes_then_walks(self):
        p = self._worker()
        _marker_write(self.state._sha_path(".health-inflight", 3, "old3"), p.pid)
        scenario = {"candidates": [{"pr": 3, "sha": "new3", "review": "PASS", "health": "CLEAN"}],
                    "config": {"MERGE_POLICY": "auto"}}
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     DryRunActuator(self.journal), self.journal, state=self.state)
        res = t.run()
        self.assertEqual(res["outcomes"]["3"], "MERGE")
        self.assertFalse(self._alive(p.pid))
        ev = self._events()
        self.assertTrue([o for o in ev if o["event"] == "gate_superseded"])
        self.assertTrue([o for o in ev if o["event"] == "merge"])


class TestSlugDerivation(unittest.TestCase):
    """HERD-346 leg 1: derive the SLUG from the head branch (bash ``herd_branch_parse`` convention) so the
    worktree resolves — the live tick shelled healthcheck.sh with slug=full-branch + an empty worktree (#453)."""

    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in ("BRANCH_TEMPLATE", "TREES", "WORKTREES_DIR")}
        for k in self._saved:
            os.environ.pop(k, None)

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_default_template_strips_feat_prefix(self):
        self.assertEqual(branch_to_slug("feat/unlock-supersession-cancel"), "unlock-supersession-cancel")

    def test_empty_branch_is_empty_slug(self):
        self.assertEqual(branch_to_slug(""), "")

    def test_non_matching_branch_keeps_whole_name(self):
        # A branch without the template prefix parses to itself (bash herd_branch_parse: no prefix strip).
        self.assertEqual(branch_to_slug("hotfix-1"), "hotfix-1")

    def test_custom_prefix_template(self):
        os.environ["BRANCH_TEMPLATE"] = "wip/{slug}"
        self.assertEqual(branch_to_slug("wip/foo-bar"), "foo-bar")

    def test_ref_prefix_template_treats_ref_as_wildcard(self):
        # '{ref}/{slug}' — strip up to the last '/' (the separator trailing {ref}), leaving the slug.
        os.environ["BRANCH_TEMPLATE"] = "{ref}/{slug}"
        self.assertEqual(branch_to_slug("HERD-346/live-slug-regression"), "live-slug-regression")

    def test_suffix_template(self):
        os.environ["BRANCH_TEMPLATE"] = "{slug}-dev"
        self.assertEqual(branch_to_slug("payment-dev"), "payment")

    def test_unusable_template_degrades_to_default(self):
        os.environ["BRANCH_TEMPLATE"] = "no-placeholder"     # no {slug} → default feat/{slug}
        self.assertEqual(branch_to_slug("feat/x"), "x")

    def test_worktree_for_slug_is_pool_join(self):
        os.environ["TREES"] = "/pool"
        self.assertEqual(_worktree_for_slug("unlock-supersession-cancel"),
                         "/pool/unlock-supersession-cancel")

    def test_worktree_for_slug_empty_without_pool(self):
        self.assertEqual(_worktree_for_slug("x"), "")        # no pool configured → no fabricated path

    def test_discovery_derives_slug_and_worktree(self):
        # discover_via_graphql maps headRefName -> slug -> worktree; stub gh so nothing shells out.
        pool = tempfile.mkdtemp()
        os.environ["TREES"] = pool
        _make_worktree(pool, "unlock-supersession-cancel")
        payload = {"data": {"repository": {"pullRequests": {"nodes": [
            {"number": 450, "headRefName": "feat/unlock-supersession-cancel",
             "headRefOid": "3ca3eab", "baseRefName": "main", "mergeStateStatus": "CLEAN",
             "reviewDecision": "", "author": {"login": "brian"},
             "assignees": {"nodes": []}, "labels": {"nodes": []}}]}}}}

        class _Stub:
            def run(self, *a, **k):
                class R:
                    stdout = json.dumps(payload)
                return R()
        orig = LR.subprocess
        LR.subprocess = _Stub()
        try:
            cands = LR.discover_via_graphql(repo="owner/name")
        finally:
            LR.subprocess = orig
        self.assertEqual(len(cands), 1)
        self.assertEqual(cands[0].slug, "unlock-supersession-cancel")     # not the full branch
        self.assertEqual(cands[0].worktree, os.path.join(pool, "unlock-supersession-cancel"))


class TestPoolScope(unittest.TestCase):
    """HERD-346 leg 3: a PR with NO worktree in this pool is FOREIGN and never a candidate — the port of
    bash's worktree-first discovery (_discover_feature_worktrees). Fail-soft when no pool is configured."""

    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in ("TREES", "WORKTREES_DIR")}
        for k in self._saved:
            os.environ.pop(k, None)

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_foreign_pool_pr_is_dropped(self):
        pool = tempfile.mkdtemp()
        os.environ["TREES"] = pool
        _make_worktree(pool, "mine")                          # PR 1 has a real worktree
        mine = LiveCandidate(pr=1, sha="a", slug="mine", worktree=os.path.join(pool, "mine"))
        foreign = LiveCandidate(pr=2, sha="b", slug="theirs", worktree=os.path.join(pool, "theirs"))
        kept = _pool_scoped([mine, foreign])
        self.assertEqual([c.pr for c in kept], ["1"])         # #2 (no worktree on disk) never classified

    def test_fail_soft_passthrough_without_pool(self):
        # No $TREES/$WORKTREES_DIR configured → the pool check no-ops (byte-identical to before).
        a = LiveCandidate(pr=1, sha="a", slug="x", worktree="/nope/x")
        b = LiveCandidate(pr=2, sha="b", slug="y", worktree="")
        self.assertEqual([c.pr for c in _pool_scoped([a, b])], ["1", "2"])

    def test_is_worktree_predicate(self):
        pool = tempfile.mkdtemp()
        real = _make_worktree(pool, "real")
        self.assertTrue(_is_worktree(real))
        self.assertFalse(_is_worktree(os.path.join(pool, "absent")))
        self.assertFalse(_is_worktree(""))
        os.makedirs(os.path.join(pool, "bare"))              # a dir with no .git is not a worktree
        self.assertFalse(_is_worktree(os.path.join(pool, "bare")))

    def test_graphql_discovery_applies_pool_scope(self):
        pool = tempfile.mkdtemp()
        os.environ["TREES"] = pool
        _make_worktree(pool, "mine")
        cands = [LiveCandidate(pr=1, sha="a", slug="mine", author="me",
                               worktree=os.path.join(pool, "mine")),
                 LiveCandidate(pr=2, sha="b", slug="gone", author="me",
                               worktree=os.path.join(pool, "gone"))]
        disc = LR._GraphQLDiscovery({"WATCHER_SCOPE": "mine"})
        orig = LR.discover_via_graphql
        LR.discover_via_graphql = lambda repo=None: list(cands)
        try:
            got = disc.discover()
        finally:
            LR.discover_via_graphql = orig
        self.assertEqual([c.pr for c in got], ["1"])


class TestPreDispatchWorktreeGuard(unittest.TestCase):
    """HERD-346 leg 2: a resolved-but-ABSENT worktree REFUSES health dispatch (dispatch_refused,
    reason=no-worktree) and HOLDS — never shells healthcheck.sh into a phantom CODEERROR (#453)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["HERD_JOURNAL_NOW"] = "2026-07-10T00:00:00Z"
        self.state = LiveState(self.tmp)
        self.jpath = os.path.join(self.tmp, "j.jsonl")
        self.journal = LiveJournal(self.jpath)

    def tearDown(self):
        os.environ.pop("HERD_JOURNAL_NOW", None)

    def _gates(self):
        dispatched = []

        class Stub(LiveGates):
            def _dispatch_health(self, cand):
                dispatched.append(cand.pr)
                _marker_write(self.state.health_inflight_file(cand), os.getpid())

        return Stub("/home", self.state, self.journal), dispatched

    def _events(self):
        return events(self.jpath) if os.path.exists(self.jpath) else []

    def test_missing_worktree_refuses_dispatch(self):
        c = LiveCandidate(pr=7, sha="s", slug="gone", worktree=os.path.join(self.tmp, "gone"))
        g, dispatched = self._gates()
        self.assertEqual(g.health(c), WAIT)                  # holds, never CODEERROR
        self.assertEqual(dispatched, [])                     # the suite is never shelled at a missing tree
        refused = [e for e in self._events() if e["event"] == "dispatch_refused"]
        self.assertEqual(len(refused), 1)
        self.assertEqual(refused[0]["reason"], "no-worktree")
        self.assertEqual(refused[0]["rail"], "health")
        self.assertEqual(str(refused[0]["pr"]), "7")

    def test_present_worktree_dispatches(self):
        _make_worktree(self.tmp, "here")
        c = LiveCandidate(pr=8, sha="s", slug="here", worktree=os.path.join(self.tmp, "here"))
        g, dispatched = self._gates()
        self.assertEqual(g.health(c), WAIT)
        self.assertEqual(dispatched, ["8"])                  # real worktree → normal async dispatch
        self.assertEqual([e for e in self._events() if e["event"] == "dispatch_refused"], [])

    def test_empty_worktree_is_byte_identical(self):
        # A hermetic/legacy candidate carrying no worktree is UNKNOWN, not absent → dispatch unchanged.
        c = LiveCandidate(pr=9, sha="s", slug="feat-9")
        g, dispatched = self._gates()
        self.assertEqual(g.health(c), WAIT)
        self.assertEqual(dispatched, ["9"])
        self.assertEqual([e for e in self._events() if e["event"] == "dispatch_refused"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
