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
from herd.live_runtime import (LiveTick, LiveJournal, LiveState, LiveGates, LiveCandidate,
                               FixtureDiscovery, FixtureGates, DryRunActuator, parse_review_verdict,
                               _select_candidates, _marker_write, _marker_live, WAIT, PENDING)


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
