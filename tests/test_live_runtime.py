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

from herd import live_runtime as LR
from herd.live_runtime import (LiveTick, LiveJournal, FixtureDiscovery, FixtureGates,
                               DryRunActuator, parse_review_verdict)


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


class TestReapAndActuation(LiveCase):
    def test_merge_reaps(self):
        _, ev = self.tick([self.one(1, review="PASS", health="CLEAN", worktree="/wt/1")])
        self.assertTrue([o for o in ev if o["event"] == "merge"])
        reaps = [o for o in ev if o["event"] == "reap"]
        self.assertEqual(len(reaps), 1)
        self.assertEqual(reaps[0]["reason"], "merged")

    def test_failed_merge_escalates_and_never_reaps(self):
        class FailMerge(DryRunActuator):
            def merge(self, cand):
                return False
        scenario = {"candidates": [self.one(1, review="PASS", health="CLEAN")],
                    "config": {"MERGE_POLICY": "auto"}}
        journal = LiveJournal(self.jpath)
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     FailMerge(journal), journal)
        res = t.run()
        self.assertEqual(res["outcomes"]["1"], "ESCALATE")
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
