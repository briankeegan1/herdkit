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

from herd import cost_emit as CE
from herd import live_runtime as LR
from herd.live_runtime import (LiveTick, LiveJournal, LiveState, LiveGates, LiveCandidate,
                               LiveActuator,
                               FixtureDiscovery, FixtureGates, DryRunActuator, parse_review_verdict,
                               parse_rubric_verdicts,
                               _select_candidates, _marker_write, _marker_live, _terminate_worker,
                               _marker_nonce, _dispatch_nonce,
                               _main_health_pending,
                               WAIT, PENDING,
                               branch_to_slug, _branch_worktree_slug, _worktree_for_slug,
                               _is_worktree, _pool_scoped)
from herd import work_unit as WU

# HERMETICITY (HERD-331 gate red): a watcher/healthcheck-descended environment EXPORTS the live
# engine's main-health coordinates — herd-config.sh exports MAIN_HEALTH_TICK (HERD-359) and
# PROJECT_ROOT, and this repo's .herd/config arms the tick. Inside these fixtures,
# _main_health_pending() would then consult the REAL repo's HEAD and reserve the single health
# slot, deterministically failing every dispatch assert whenever real main happens to sit
# verdict-pending (exactly the window in which a PR gate runs after a merge). Scrub the trio once
# at import — the same set TestMainHealthSlotPriority scrubs per-test; tests that exercise the
# reservation set them explicitly.
for _k in ("MAIN_HEALTH_TICK", "MAIN", "PROJECT_ROOT"):
    os.environ.pop(_k, None)


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
        """A dry-run tick over injected candidates; returns (summary, events).

        Passes the per-test tmp dir as the LiveState dir so the durable ledger path is always
        hermetic (never leaks to WORKTREES_DIR from the environment) and each test method gets
        an isolated ledger.  Within a single test method multiple tick() calls share the same
        tmp dir — that is intentional: the once-guard should hold intra-method just as it does
        across ticks in production."""
        scenario = {"candidates": candidates, "config": config or {"MERGE_POLICY": "auto"}}
        journal = LiveJournal(self.jpath)
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     DryRunActuator(journal), journal, state=LiveState(self.tmp))
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
        # HERD-328 S2 / HERD-358: the round a refix_bounce carries is the per-(pr, rule) bounce count
        # + 1 read from the DURABLE ledger, NOT a hardcoded 1 and NOT a process-local counter.
        # First bounce (no state dir): round=1 regardless.
        _, ev = self._out(health="CODEERROR")
        rb = [o for o in ev if o["event"] == "refix_bounce" and o.get("rule") == "healthcheck"]
        self.assertEqual(rb[0]["round"], 1)

    def test_refix_round_advances_per_new_sha(self):
        # HERD-358: round climbs 1→2→3 only when a NEW SHA is pushed (each sha bounces exactly once).
        # Each push is a new commit → different sha → once-guard opens → round counter advances.
        # This MUST use a fresh LiveTick per tick (process boundary is the bug scenario).
        state_dir = os.path.join(self.tmp, "state-sha-advance")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3"}
        rounds = []
        for i, sha in enumerate(["sha-a", "sha-b", "sha-c"], 1):
            cand = {"pr": 77, "sha": sha, "slug": "feat-adv", "health": "CODEERROR"}
            scenario = {"candidates": [cand], "config": config}
            jpath = os.path.join(self.tmp, "adv-%d.jsonl" % i)
            j = LiveJournal(jpath)
            state = LiveState(state_dir)
            t = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario),
                         DryRunActuator(j), j, state=state)
            t.run()
            evs = events(jpath) if os.path.exists(jpath) else []
            rb = [o for o in evs if o["event"] == "refix_bounce" and o.get("rule") == "healthcheck"]
            self.assertEqual(len(rb), 1, "sha %s: expected exactly 1 refix_bounce" % sha)
            rounds.append(rb[0]["round"])
        self.assertEqual(rounds, [1, 2, 3], "round must advance per new sha: %s" % rounds)

    def test_refix_same_sha_bounces_exactly_once(self):
        # HERD-358 once-guard: walking the SAME (pr,sha,kind) 5 times (simulating 5 ticks on an
        # unchanged sha) must produce exactly ONE refix_bounce — not 5.
        state_dir = os.path.join(self.tmp, "state-once-guard")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "5"}
        cand = {"pr": 88, "sha": "same-sha", "slug": "feat-og", "health": "CODEERROR"}
        total_bounces = 0
        for i in range(5):
            scenario = {"candidates": [cand], "config": config}
            jpath = os.path.join(self.tmp, "og-%d.jsonl" % i)
            j = LiveJournal(jpath)
            state = LiveState(state_dir)
            t = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario),
                         DryRunActuator(j), j, state=state)
            t.run()
            evs = events(jpath) if os.path.exists(jpath) else []
            total_bounces += sum(1 for o in evs
                                 if o["event"] == "refix_bounce" and o.get("rule") == "healthcheck")
        self.assertEqual(total_bounces, 1,
                         "same sha walked 5 times must produce 1 bounce, got %d" % total_bounces)


class TestRefixWakeVerification(LiveCase):
    """HERD-370: a review-BLOCK refix bounced PR #471 with the wake never even attempted — no
    refix_wake_result followed, and the PR sat BLOCKED ~70 minutes with the once-guard silently
    holding any retry. Asserts the fix, driven entirely through the fixture wake surface
    (LiveCandidate.agent_status / .wake_succeeds — see DryRunActuator.wake_builder):

      * every refix_bounce is paired with exactly one refix_wake_result (journal-audit.sh's
        refix_bounce_no_wake check reads this pairing as ground truth) — for BOTH rails;
      * a wake that lands (idle/done -> working, or already working) records woke=1, escalated=false,
        and the candidate stays BLOCK;
      * a wake that fails (idle/done that never flips) OR a dead/missing/absent agent records woke=0,
        escalated=true, and the candidate ESCALATES immediately in the SAME tick;
      * an escalated (unwoken) bounce REFUNDS its round: the rail's ledger count goes back to 0, so a
        later, actually-woken bounce on a fresh sha starts at round=1, not round=2;
      * a legacy fixture that never sets agent_status (every scenario written before this task) stays
        byte-identical: BLOCK, no escalation, woke=1.
    """

    def test_legacy_fixture_default_wakes_and_blocks(self):
        # No agent_status at all (every pre-HERD-370 fixture) — byte-compatible: BLOCK, woke=1.
        out, ev = (lambda r, e: (r["outcomes"]["1"], e))(
            *self.tick([self.one(1, health="CODEERROR")]))
        self.assertEqual(out, "BLOCK")
        wr = [o for o in ev if o["event"] == "refix_wake_result"]
        self.assertEqual(len(wr), 1)
        self.assertEqual(wr[0]["woke"], 1)
        self.assertEqual(wr[0]["escalated"], "false")

    def test_idle_agent_wakes_blocks_and_records_transition(self):
        res, ev = self.tick([self.one(1, health="CODEERROR", agent_status="idle")])
        self.assertEqual(res["outcomes"]["1"], "BLOCK")
        wr = [o for o in ev if o["event"] == "refix_wake_result"]
        self.assertEqual(len(wr), 1)
        self.assertEqual(wr[0]["woke"], 1)
        self.assertEqual(wr[0]["escalated"], "false")
        self.assertEqual(wr[0]["agent_status_before"], "idle")
        self.assertEqual(wr[0]["agent_status_after"], "working")

    def test_done_agent_that_never_wakes_escalates_immediately(self):
        # The exact PR #471 shape: a 'done' pane that the bounce could not actually wake.
        res, ev = self.tick([self.one(1, health="CODEERROR", agent_status="done",
                                      wake_succeeds=False)])
        self.assertEqual(res["outcomes"]["1"], "ESCALATE")
        rb = [o for o in ev if o["event"] == "refix_bounce"]
        wr = [o for o in ev if o["event"] == "refix_wake_result"]
        self.assertEqual(len(rb), 1, "the bounce is still recorded (round consumed then refunded)")
        self.assertEqual(len(wr), 1, "every refix_bounce must pair with exactly one refix_wake_result")
        self.assertEqual(wr[0]["woke"], 0)
        self.assertEqual(wr[0]["escalated"], "true")
        self.assertEqual(wr[0]["agent_status_before"], "done")
        esc = [o for o in ev if o["event"] == "refix_escalated_no_wake"]
        self.assertEqual(len(esc), 1)
        self.assertEqual(esc[0]["reason"], "no-live-builder")

    def test_dead_agent_escalates_without_attempting_a_submit(self):
        res, ev = self.tick([self.one(1, review="BLOCK", health="CLEAN", agent_status="dead")])
        self.assertEqual(res["outcomes"]["1"], "ESCALATE")
        wr = [o for o in ev if o["event"] == "refix_wake_result"]
        self.assertEqual(wr[0]["woke"], 0)
        self.assertEqual(wr[0]["agent_status_before"], "dead")

    def test_missing_agent_escalates(self):
        res, ev = self.tick([self.one(1, health="CODEERROR", agent_status="missing")])
        self.assertEqual(res["outcomes"]["1"], "ESCALATE")
        wr = [o for o in ev if o["event"] == "refix_wake_result"]
        self.assertEqual(wr[0]["woke"], 0)

    def test_unwoken_bounce_refunds_the_round(self):
        # sha-1: agent dead -> escalate, round refunded (rail reset to 0).
        # sha-2 (a fresh push): a real, woken bounce must start at round=1, not round=2 — proving the
        # failed sha-1 attempt never counted against the rail budget.
        state_dir = os.path.join(self.tmp, "refund-state")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3"}

        cand1 = {"pr": 5, "sha": "sha-dead", "slug": "feat-refund", "health": "CODEERROR",
                 "agent_status": "dead"}
        j1 = LiveJournal(os.path.join(self.tmp, "refund-1.jsonl"))
        t1 = LiveTick(config, FixtureDiscovery({"candidates": [cand1], "config": config}),
                     FixtureGates({"candidates": [cand1], "config": config}),
                     DryRunActuator(j1), j1, state=LiveState(state_dir))
        r1 = t1.run()
        self.assertEqual(r1["outcomes"]["5"], "ESCALATE")
        reset_ev = [o for o in events(j1.path) if o["event"] == "refix_rail_reset"]
        self.assertEqual(len(reset_ev), 1, "the refund must write a refix_rail_reset row")

        cand2 = {"pr": 5, "sha": "sha-fixed", "slug": "feat-refund", "health": "CODEERROR",
                 "agent_status": "idle"}
        j2 = LiveJournal(os.path.join(self.tmp, "refund-2.jsonl"))
        t2 = LiveTick(config, FixtureDiscovery({"candidates": [cand2], "config": config}),
                     FixtureGates({"candidates": [cand2], "config": config}),
                     DryRunActuator(j2), j2, state=LiveState(state_dir))
        r2 = t2.run()
        self.assertEqual(r2["outcomes"]["5"], "BLOCK")
        rb2 = [o for o in events(j2.path) if o["event"] == "refix_bounce"]
        self.assertEqual(rb2[0]["round"], 1,
                         "round must be 1 (refunded), not 2, after the unwoken sha-1 attempt")

    def test_review_rail_wake_also_paired_and_escalates(self):
        # The review rail (not just health) must carry the same wake-verification contract.
        res, ev = self.tick([self.one(1, review="BLOCK", health="CLEAN", agent_status="done",
                                      wake_succeeds=False)])
        self.assertEqual(res["outcomes"]["1"], "ESCALATE")
        rb = [o for o in ev if o["event"] == "refix_bounce" and o.get("rule") == "review"]
        wr = [o for o in ev if o["event"] == "refix_wake_result"]
        self.assertEqual(len(rb), 1)
        self.assertEqual(len(wr), 1)
        self.assertEqual(wr[0]["woke"], 0)


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


class TestWorkUnitDualWrite(unittest.TestCase):
    """HERD-397 (work-unit dual-write, spike docs/spikes/work-unit-abstraction.md Sec 5 Phase 2):
    every LiveJournal event carrying a `pr` pair also carries an additive `unit="git-pr:<n>"` pair —
    mirroring bash journal.sh's own dual-write (tests/test-journal-unit-dualwrite.sh)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.jpath = os.path.join(self.tmp, "j.jsonl")
        os.environ["HERD_JOURNAL_NOW"] = "2026-07-19T00:00:00Z"

    def tearDown(self):
        os.environ.pop("HERD_JOURNAL_NOW", None)

    def test_pr_event_gets_additive_unit(self):
        j = LiveJournal(self.jpath)
        j.append("merge", "pr", 42, "slug", "feat-x", "sha", "deadbeef")
        ev = events(self.jpath)[0]
        self.assertEqual(ev["pr"], 42)
        self.assertEqual(ev["unit"], "git-pr:42")
        # additive, not a replacement: every original field survives unchanged.
        self.assertEqual(ev["slug"], "feat-x")
        self.assertEqual(ev["sha"], "deadbeef")

    def test_no_pr_no_unit(self):
        j = LiveJournal(self.jpath)
        j.append("sweep_closed", "tab_id", "tab-1", "reason", "orphan")
        ev = events(self.jpath)[0]
        self.assertNotIn("unit", ev)

    def test_explicit_unit_not_overridden(self):
        j = LiveJournal(self.jpath)
        j.append("custom", "pr", 7, "unit", "doc:xyz")
        ev = events(self.jpath)[0]
        self.assertEqual(ev["unit"], "doc:xyz")

    def test_kwargs_call_shape_also_dual_writes(self):
        j = LiveJournal(self.jpath)
        j.append("healthcheck_outcome", pr=9, slug="feat-y", outcome="CLEAN")
        ev = events(self.jpath)[0]
        self.assertEqual(ev["unit"], "git-pr:9")

    def test_bash_and_python_writers_emit_the_same_unit_format(self):
        # Cross-implementation parity: bash journal.sh's journal_unit_ref and Python's
        # shadow_journal._journal_unit_ref (the single encoder LiveJournal AND ShadowJournal both
        # route through) must compose IDENTICAL refs for the same (kind, id) — the exact invariant
        # HERD-397 exists to keep from drifting apart.
        from herd.shadow_journal import _journal_unit_ref
        self.assertEqual(_journal_unit_ref("git-pr", 42), "git-pr:42")

    def test_shadow_journal_also_dual_writes(self):
        # The parity oracle (tests/test-py-shadow-runtime.sh) diffs journal.sh against
        # herd.shadow_journal.encode_event byte-for-byte — the dual-write MUST live in the shared
        # encoder both LiveJournal and ShadowJournal call, not be duplicated per-writer, or the two
        # journals would disagree on every pr-carrying event.
        from herd.shadow_journal import ShadowJournal
        spath = os.path.join(self.tmp, "shadow.jsonl")
        sj = ShadowJournal(spath)
        sj.append("merge", "pr", 42, "slug", "feat-x", "sha", "deadbeef")
        ev = events(spath)[0]
        self.assertEqual(ev["unit"], "git-pr:42")


class TestReviewDispatchShape(LiveCase):
    """HERD-321: the real _dispatch_review path (bypassed by FixtureGates) must emit review_dispatched
    with the full contract §3.4 shape (pr, sha, pid, model, log_path, pin). Hermetic: a fresh temp
    state dir forces a dispatch and subprocess.Popen is stubbed, so no reviewer is ever launched."""

    class _RecordingReviewSub:
        """A subprocess stand-in that RECORDS the env handed to Popen — proves the reviewer is launched
        with the SAME model the dispatch journals (HERD-353 single resolution point), never a divergent
        second lookup, without ever launching a reviewer."""

        DEVNULL = LR.subprocess.DEVNULL

        class _Proc:
            pid = 4242

        def __init__(self):
            self.env = None

        def Popen(self, *a, **k):
            self.env = k.get("env")
            return self._Proc()

    def _dispatch_once(self, env_overrides):
        """Force ONE real _dispatch_review with a stubbed subprocess; return (verdict, journal, sub)."""
        state = LiveState(state_dir=self.tmp)          # real (empty) state dir -> no cached verdict/marker
        journal = LiveJournal(self.jpath)
        gates = LiveGates("/nonexistent-home", state, journal)
        sub = self._RecordingReviewSub()
        orig = LR.subprocess
        LR.subprocess = sub
        saved = {k: os.environ.get(k) for k in env_overrides}
        os.environ.update(env_overrides)
        try:
            v = gates.review(LiveCandidate(7, "deadbeef", slug="feat-x"))
        finally:
            LR.subprocess = orig
            for k, old in saved.items():
                if old is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = old
        return v, [o for o in events(self.jpath) if o["event"] == "review_dispatched"], sub

    def test_review_dispatched_carries_contract_fields(self):
        v, rd, sub = self._dispatch_once({"MODEL_REVIEW": "opus-x"})
        self.assertEqual(v, WAIT)                       # dispatched -> WAIT
        self.assertEqual(len(rd), 1)
        for k in ("pr", "sha", "pid", "model", "log_path", "pin"):
            self.assertIn(k, rd[0])
        self.assertEqual(rd[0]["model"], "opus-x")      # bash env-fallback chain
        self.assertTrue(rd[0]["log_path"])              # the reviewer's result-file path, non-empty

    def test_journaled_model_is_pinned_into_reviewer_env(self):
        # SINGLE RESOLUTION POINT (HERD-353): the model journaled is the SAME value handed to the
        # reviewer process — never empty when MODEL_REVIEW resolves, never a drifting second lookup.
        v, rd, sub = self._dispatch_once({"MODEL_REVIEW": "claude-opus-4-8", "HERD_REVIEW_MODEL": ""})
        self.assertEqual(rd[0]["model"], "claude-opus-4-8")
        self.assertTrue(rd[0]["model"])                 # regression guard: NEVER empty when config resolves
        self.assertEqual(sub.env.get("HERD_REVIEW_MODEL"), rd[0]["model"])  # reviewer runs EXACTLY this

    def test_review_model_override_wins_and_is_journaled(self):
        # An operator HERD_REVIEW_MODEL override wins the fallback chain and is what the reviewer runs.
        v, rd, sub = self._dispatch_once({"MODEL_REVIEW": "claude-opus-4-8",
                                          "HERD_REVIEW_MODEL": "claude-sonnet-4-6"})
        self.assertEqual(rd[0]["model"], "claude-sonnet-4-6")
        self.assertEqual(sub.env.get("HERD_REVIEW_MODEL"), "claude-sonnet-4-6")


class TestHealthDispatchFreshness(LiveCase):
    """HERD-349: the REAL _dispatch_health path (bypassed by the stubs above) must (a) DELETE any
    pre-existing out-file before spawning the worker and (b) stamp a nonce into BOTH the in-flight
    marker and the worker's argv — the two ends the collector matches. Hermetic: subprocess.Popen is
    stubbed, so no worker is ever launched."""

    class _RecordingHealthSub:
        """A subprocess stand-in that RECORDS the argv handed to Popen — proves the worker receives the
        dispatch nonce as its final script arg, without ever launching a suite."""

        DEVNULL = LR.subprocess.DEVNULL

        class _Proc:
            pid = 5151

        def __init__(self):
            self.argv = None

        def Popen(self, argv, *a, **k):
            self.argv = list(argv)
            return self._Proc()

    def test_predispatch_deletes_stale_out_and_stamps_matching_nonce(self):
        state = LiveState(state_dir=self.tmp)
        gates = LiveGates("/nonexistent-home", state, LiveJournal(self.jpath))
        cand = LiveCandidate(7, "deadbeef", slug="feat-x", worktree=self.tmp)
        disp, inflight = state.health_dispatch_file(cand), state.health_inflight_file(cand)
        with open(disp, "w") as fh:                       # a leftover out-file a prior run left in the slot
            fh.write("old.1\tCLEAN\tclean\n")
        sub = self._RecordingHealthSub()
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            gates._dispatch_health(cand)
        finally:
            LR.subprocess = orig
        # (a) the pre-existing out-file is deleted BEFORE the worker is spawned — the slot is owned.
        self.assertFalse(os.path.exists(disp))
        # (b) the worker argv carries the nonce as its final arg, and it equals the marker's nonce line —
        #     the exact pair the collector compares to prove a result belongs to this dispatch.
        self.assertIsNotNone(sub.argv)
        worker_nonce = sub.argv[-1]
        self.assertTrue(worker_nonce)
        self.assertEqual(_marker_nonce(inflight), worker_nonce)

    def test_nonce_written_only_for_health_marker_review_byte_identical(self):
        # A review marker (no nonce) stays 4 lines; a health marker adds the 5th nonce line. Guards the
        # byte-identical-when-absent contract for the shared _marker_write.
        review_m = os.path.join(self.tmp, ".review-inflight-x")
        health_m = os.path.join(self.tmp, ".health-inflight-x")
        _marker_write(review_m, os.getpid())
        _marker_write(health_m, os.getpid(), nonce=_dispatch_nonce())
        self.assertEqual(len(open(review_m).read().splitlines()), 4)
        self.assertEqual(_marker_nonce(review_m), "")     # legacy 4-line marker → no nonce
        self.assertEqual(len(open(health_m).read().splitlines()), 5)
        self.assertTrue(_marker_nonce(health_m))


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


class TestLiveMergeMethodConfig(LiveCase):
    """HERD-354: the live merge actuator composes ``gh pr merge`` from MERGE_METHOD +
    DELETE_BRANCH_ON_MERGE exactly as bash do_merge does (agent-watch.sh:_merge_method_flag /
    _delete_branch_flag), NOT a hardcoded ``--squash --delete-branch``. A repo whose branch protection
    disallows squash refused every engine merge until this landed. Hermetic: subprocess is stubbed."""

    def _run(self, config):
        sub = _RecordingSub(view_state="MERGED")
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        act = LiveActuator("/nonexistent-home", LiveJournal(self.jpath), config)
        self.assertTrue(act.merge(LiveCandidate(7, "deadbeef", slug="feat-x", worktree="")))
        merges = [c for c in sub.calls if c[:3] == ["gh", "pr", "merge"]]
        self.assertEqual(len(merges), 1)
        return merges[0]

    def _method_journaled(self):
        m = [o for o in events(self.jpath) if o["event"] == "merge"]
        self.assertEqual(len(m), 1)
        return m[0]["method"]

    def test_default_is_merge_no_delete(self):
        # No config → bash default MERGE_METHOD=merge, DELETE_BRANCH_ON_MERGE=false. The old code
        # hardcoded --squash --delete-branch here; that is the exact 53-refusal bug HERD-354 fixes.
        argv = self._run({})
        self.assertEqual(argv, ["gh", "pr", "merge", "7", "--merge"])
        self.assertEqual(self._method_journaled(), "merge")

    def test_merge_method_maps_to_flag(self):
        for method, flag in (("merge", "--merge"), ("squash", "--squash"), ("rebase", "--rebase")):
            with self.subTest(method=method):
                argv = self._run({"MERGE_METHOD": method})
                self.assertEqual(argv[-1], flag)
                self.assertNotIn("--delete-branch", argv)     # deletion default false

    def test_unrecognized_method_falls_back_to_merge(self):
        argv = self._run({"MERGE_METHOD": "ff-only"})
        self.assertEqual(argv, ["gh", "pr", "merge", "7", "--merge"])

    def test_delete_branch_appends_flag_when_true(self):
        for truthy in ("true", "1", "yes", "on"):
            with self.subTest(val=truthy):
                argv = self._run({"MERGE_METHOD": "squash", "DELETE_BRANCH_ON_MERGE": truthy})
                self.assertEqual(argv, ["gh", "pr", "merge", "7", "--squash", "--delete-branch"])

    def test_delete_branch_false_omits_flag(self):
        for falsy in ("false", "0", "no", "off", ""):
            with self.subTest(val=falsy):
                argv = self._run({"DELETE_BRANCH_ON_MERGE": falsy})
                self.assertNotIn("--delete-branch", argv)


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


class TestRubricVerdictParser(unittest.TestCase):
    """parse_rubric_verdicts (HERD-400): a second, independent pass over the SAME text
    parse_review_verdict reads — never able to change its PASS/BLOCK/INFRA result."""

    def test_extracts_well_formed_lines(self):
        text = "RUBRIC: scoped | PASS | tight diff\nRUBRIC: tested | FAIL | no new test\nREVIEW: BLOCK — rule: x | why: y | location: f:1"
        got = parse_rubric_verdicts(text)
        self.assertEqual(got, [
            {"id": "scoped", "verdict": "PASS", "reason": "tight diff"},
            {"id": "tested", "verdict": "FAIL", "reason": "no new test"},
        ])

    def test_no_rubric_lines_is_empty_list(self):
        self.assertEqual(parse_rubric_verdicts("REVIEW: PASS"), [])
        self.assertEqual(parse_rubric_verdicts(""), [])

    def test_malformed_lines_are_skipped_not_raised(self):
        text = "\n".join([
            "RUBRIC: missing-fields | PASS",                 # only 2 fields
            "RUBRIC: | PASS | empty id",                     # empty id
            "RUBRIC: bad-verdict | MAYBE | not pass or fail", # unrecognized verdict word
            "RUBRIC: ok | PASS | this one is fine",
            "REVIEW: PASS",
        ])
        self.assertEqual(parse_rubric_verdicts(text),
                          [{"id": "ok", "verdict": "PASS", "reason": "this one is fine"}])

    def test_case_insensitive_verdict_and_prefix(self):
        self.assertEqual(parse_rubric_verdicts("rubric: x | pass | ok"),
                          [{"id": "x", "verdict": "PASS", "reason": "ok"}])

    def test_duplicate_ids_all_kept_not_folded(self):
        # A review PANEL: every panelist judges the same criterion independently (docs/rubric-primitive.md).
        text = "RUBRIC: scoped | PASS | panelist a\nRUBRIC: scoped | FAIL | panelist b"
        got = parse_rubric_verdicts(text)
        self.assertEqual(len(got), 2)
        self.assertEqual([g["verdict"] for g in got], ["PASS", "FAIL"])

    def test_never_affects_the_review_verdict(self):
        text = "RUBRIC: x | MAYBE | garbage\nRUBRIC: y | PASS | fine\nREVIEW: BLOCK — rule: x | why: y | location: f:1"
        self.assertEqual(parse_review_verdict(text), "BLOCK")   # unaffected by rubric lines, garbled or not
        self.assertEqual(len(parse_rubric_verdicts(text)), 1)   # only the well-formed one survives


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

    # ── rubric-primitive (HERD-400): a fixture rubric through the review-collect gate ──
    def test_collect_pass_with_rubric_journals_event(self):
        c = self.cand()
        with open(self.state.review_result_file(c), "w") as fh:
            fh.write("RUBRIC: scoped | PASS | tight diff\nRUBRIC: tested | FAIL | no new test\nREVIEW: BLOCK — rule: x | why: y | location: f:1\n")
        g, dr, _ = self._gates()
        self.assertEqual(g.review(c), "BLOCK")          # the REVIEW: line alone decides — unchanged contract
        self.assertEqual(self.state.recorded_review(c.pr, c.sha), "BLOCK")
        rows = [e for e in events(self.journal.path) if e["event"] == "rubric_verdicts"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["pr"], 1)
        self.assertEqual(rows[0]["verdict"], "BLOCK")
        self.assertEqual(rows[0]["criteria_count"], 2)
        criteria = json.loads(rows[0]["criteria"])
        self.assertEqual(criteria, [
            {"id": "scoped", "verdict": "PASS", "reason": "tight diff"},
            {"id": "tested", "verdict": "FAIL", "reason": "no new test"},
        ])

    def test_collect_pass_no_rubric_lines_journals_nothing(self):
        # RUBRIC_FILE-unset (or a rubric-blind reviewer): byte-identical to before the primitive existed.
        c = self.cand()
        with open(self.state.review_result_file(c), "w") as fh:
            fh.write("REVIEW: PASS\n")
        g, dr, _ = self._gates()
        self.assertEqual(g.review(c), "PASS")
        rows = [e for e in events(self.journal.path) if e["event"] == "rubric_verdicts"] \
            if os.path.exists(self.journal.path) else []
        self.assertEqual(rows, [])

    def test_collect_malformed_rubric_lines_degrades_to_plain_verdict(self):
        # Every RUBRIC: line is malformed — the review verdict is STILL a clean PASS (never INFRA-FAIL),
        # and no rubric_verdicts event is journaled (zero criteria parsed cleanly).
        c = self.cand()
        with open(self.state.review_result_file(c), "w") as fh:
            fh.write("RUBRIC: only-two-fields | PASS\nRUBRIC: | PASS | empty id\nRUBRIC: x | MAYBE | bad verdict word\nREVIEW: PASS\n")
        g, dr, _ = self._gates()
        self.assertEqual(g.review(c), "PASS")
        self.assertEqual(self.state.recorded_review(c.pr, c.sha), "PASS")
        rows = [e for e in events(self.journal.path) if e["event"] == "rubric_verdicts"] \
            if os.path.exists(self.journal.path) else []
        self.assertEqual(rows, [])

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
        # HERD-349: a result is collected ONLY when its first-field nonce matches the LIVE dispatch
        # marker. Plant the matched pair (marker nonce == out-file first field) a real dispatch would lay.
        _marker_write(self.state.health_inflight_file(c), os.getpid(), nonce="n-live")
        with open(self.state.health_dispatch_file(c), "w") as fh:
            fh.write("n-live\tCODEERROR\tnot ok 3 - foo.bats\n")
        g, _, dh = self._gates()
        self.assertEqual(g.health(c), "CODEERROR")
        self.assertEqual(self.state.health_cached_verdict(c), "CODEERROR")
        self.assertFalse(os.path.exists(self.state.health_dispatch_file(c)))
        self.assertFalse(os.path.exists(self.state.health_inflight_file(c)))  # marker cleared on collect

    def test_health_stale_out_file_ignored_and_redispatched(self):
        """HERD-349: an out-file that predates the live dispatch (no live marker, so no matching nonce)
        is NEVER consumed — it is dropped, `stale_result_ignored` is journaled, and a fresh suite is
        re-dispatched so a real run actually happens (the 2026-07-11 PR450/451 same-tick stale-consume)."""
        c = self.cand()
        # A leftover verdict from a prior/garbage run, with NO live in-flight marker keying it.
        with open(self.state.health_dispatch_file(c), "w") as fh:
            fh.write("old.999\tCLEAN\tclean\n")
        g, _, dh = self._gates()
        self.assertEqual(g.health(c), WAIT)                        # holds; never the stale CLEAN
        self.assertIsNone(self.state.health_cached_verdict(c))     # stale result is never cached
        self.assertEqual(dh, ["1"])                                # a real suite IS re-dispatched
        self.assertFalse(os.path.exists(self.state.health_dispatch_file(c)))  # stale file removed
        evs = events(os.path.join(self.tmp, "j.jsonl"))
        stale = [e for e in evs if e["event"] == "stale_result_ignored"]
        self.assertEqual(len(stale), 1)
        self.assertEqual(stale[0]["rail"], "health")
        self.assertEqual(str(stale[0]["pr"]), "1")

    def test_health_nonce_mismatch_ignored_under_live_marker(self):
        """A stale out-file whose nonce does NOT match a LIVE dispatch marker is ignored, and the tick
        WAITS on the live worker instead of consuming the mismatched result (never a second suite)."""
        c = self.cand()
        _marker_write(self.state.health_inflight_file(c), os.getpid(), nonce="fresh-nonce")
        with open(self.state.health_dispatch_file(c), "w") as fh:
            fh.write("stale-nonce\tCODEERROR\tnot ok 9 - boom\n")   # predates the live dispatch
        g, _, dh = self._gates()
        self.assertEqual(g.health(c), WAIT)                        # waits on the live worker
        self.assertIsNone(self.state.health_cached_verdict(c))     # mismatched result never cached
        self.assertEqual(dh, [])                                   # marker live → no re-dispatch
        self.assertFalse(os.path.exists(self.state.health_dispatch_file(c)))  # mismatched file removed
        self.assertTrue(os.path.exists(self.state.health_inflight_file(c)))   # live marker preserved
        evs = events(os.path.join(self.tmp, "j.jsonl"))
        self.assertEqual(len([e for e in evs if e["event"] == "stale_result_ignored"]), 1)

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


class MergeFairnessFreeze(unittest.TestCase):
    """MERGE_FAIRNESS starvation freeze (§6.2, HERD-340): a would-be sibling merge is held one window
    for a starved head-of-line PR, and the whole feature is byte-identical when the lever is off."""

    def _run(self, scenario):
        # A fresh, isolated state dir per run: the dry-run tick uses it as the freeze substrate, so the
        # one-window guard never carries across scenarios that reuse a (pr,sha). Passing an explicit dir
        # (not LiveState(None)) also keeps the test hermetic if the gate env has WORKTREES_DIR set.
        tmp = tempfile.mkdtemp()
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        tick = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                        DryRunActuator(journal), journal, state=LiveState(os.path.join(tmp, "state")))
        return tick.run(), journal.path

    def _scenario(self, fairness, starved_laps=3, starved_review="PASS"):
        return {"config": {"MERGE_POLICY": "auto", "MERGE_FAIRNESS": fairness},
                "candidates": [
                    {"pr": 1, "sha": "a1", "slug": "starved", "review": starved_review,
                     "health": "CLEAN", "worktree": "/wt/1", "restale_laps": starved_laps},
                    {"pr": 2, "sha": "a2", "slug": "sibling", "review": "PASS",
                     "health": "CLEAN", "worktree": "/wt/2"}]}

    def test_off_is_byte_identical_the_sibling_merges(self):
        # Lever off: the exact scenario that freezes when on must merge the ready sibling, with NO
        # fairness event of any kind — the byte-identical-when-off doctrine (AGENTS.md).
        res, jpath = self._run(self._scenario("off"))
        self.assertIn("2", res["merged"])
        self.assertEqual(res["outcomes"]["2"], "MERGE")
        evs = {e["event"] for e in events(jpath)}
        self.assertNotIn("merge_fairness_freeze", evs)
        self.assertNotIn("pr_restale", evs)
        self.assertNotIn("pr_starvation", evs)

    def test_on_freezes_the_sibling_while_the_starved_pr_is_still_gating(self):
        # pr1 starved and still finishing its final gate (review WAIT → PENDING); pr2 would merge but is
        # frozen for one window so pr1 keeps its clean base.
        res, jpath = self._run(self._scenario("on", starved_review="WAIT"))
        self.assertEqual(res["merged"], [])
        self.assertEqual(res["outcomes"]["1"], PENDING)
        self.assertEqual(res["outcomes"]["2"], "HOLD")     # frozen, not merged
        frz = [e for e in events(jpath) if e["event"] == "merge_fairness_freeze"]
        self.assertEqual(len(frz), 1)
        self.assertEqual(frz[0]["pr"], 2)
        # journal.sh integer-coercion renders a lone "1" as 1 — the head-of-line PR it is held for.
        self.assertEqual(str(frz[0]["starved"]), "1")

    def test_starved_pr_is_excluded_from_its_own_freeze_and_still_merges(self):
        # When the starved PR is itself gates-ready this tick it MERGES (the win), while its sibling
        # freezes — a starved PR never blocks itself.
        res, _ = self._run(self._scenario("on", starved_review="PASS"))
        self.assertEqual(res["merged"], ["1"])
        self.assertEqual(res["outcomes"]["2"], "HOLD")

    def test_below_threshold_never_freezes(self):
        # laps=2 < threshold(3): no head-of-line starvation, so both green PRs merge exactly as off.
        res, jpath = self._run(self._scenario("on", starved_laps=2))
        self.assertEqual(sorted(res["merged"]), ["1", "2"])
        self.assertNotIn("merge_fairness_freeze", {e["event"] for e in events(jpath)})

    def test_human_verify_hold_never_triggers_a_freeze(self):
        # A starved PR parked on a human-verify hold would NOT auto-merge even with a clean window, so it
        # must never freeze siblings (that would deadlock the queue behind a human). The sibling merges.
        scen = {"config": {"MERGE_POLICY": "auto", "MERGE_FAIRNESS": "on"},
                "candidates": [
                    {"pr": 1, "sha": "a1", "slug": "held", "review": "PASS", "health": "CLEAN",
                     "hv_hold": True, "restale_laps": 5},
                    {"pr": 2, "sha": "a2", "slug": "sibling", "review": "PASS", "health": "CLEAN",
                     "worktree": "/wt/2"}]}
        res, jpath = self._run(scen)
        self.assertIn("2", res["merged"])
        self.assertNotIn("merge_fairness_freeze", {e["event"] for e in events(jpath)})

    def test_lever_off_leaves_the_candidate_out_of_the_starved_set(self):
        # The internal starved set is only populated under the lever — a direct assertion on the guard.
        scen = self._scenario("off")
        t = LiveTick(scen["config"], FixtureDiscovery(scen), FixtureGates(scen),
                     DryRunActuator(LiveJournal(None)), LiveJournal(None), state=LiveState(None))
        t.run()
        self.assertEqual(t._starved, set())
        self.assertFalse(t._fairness)

    def test_threshold_is_configurable(self):
        # MERGE_FAIRNESS_STARVE_THRESHOLD lowers the bar: laps=1 now starves and freezes the sibling.
        scen = self._scenario("on", starved_laps=1, starved_review="WAIT")
        scen["config"]["MERGE_FAIRNESS_STARVE_THRESHOLD"] = "1"
        res, _ = self._run(scen)
        self.assertEqual(res["outcomes"]["2"], "HOLD")


class MergeFairnessState(unittest.TestCase):
    """The re-stale ledger (LiveState) — the always-local counter the freeze reads (§6.2 / HERD-340)."""

    def test_restale_ledger_counts_and_dedups(self):
        tmp = tempfile.mkdtemp()
        st = LiveState(tmp)
        self.assertEqual(st.restale_count("7"), 0)
        # first lap on sha a → 1; a REPEAT of the same (pr,sha,kind) is deduped (no inflation).
        self.assertEqual(st.note_restale("7", "a", "stale"), 1)
        self.assertIsNone(st.note_restale("7", "a", "stale"))
        self.assertEqual(st.restale_count("7"), 1)
        # a new sha is a new lap.
        self.assertEqual(st.note_restale("7", "b", "stale"), 2)
        self.assertEqual(st.restale_count("7"), 2)
        # ledger row format matches the bash tree: "<epoch> <pr> <sha> <kind>".
        with open(st.restale_ledger(), encoding="utf-8") as fh:
            rows = [ln.split() for ln in fh if ln.strip()]
        self.assertTrue(all(len(r) == 4 and r[1] == "7" and r[3] == "stale" for r in rows))

    def test_black_hole_state_records_nothing(self):
        st = LiveState(None)
        st.dir = None                    # force the no-dir degrade, independent of the ambient env
        self.assertIsNone(st.note_restale("7", "a", "stale"))
        self.assertEqual(st.restale_count("7"), 0)

    def test_gate_work_invested_needs_real_investment(self):
        tmp = tempfile.mkdtemp()
        st = LiveState(tmp)
        cand = LiveCandidate(pr=9, sha="s9")
        self.assertFalse(st.gate_work_invested(cand))       # nothing spent yet → no lap owed
        st.record_review("9", "s9", "PASS")
        self.assertTrue(st.gate_work_invested(cand))         # a recorded verdict IS investment

    def test_fairness_prepass_journals_starvation_past_threshold(self):
        tmp = tempfile.mkdtemp()
        st = LiveState(tmp)
        # pre-seed 2 laps so this tick's 3rd lap crosses the threshold and journals pr_starvation.
        st.note_restale("3", "x1", "stale")
        st.note_restale("3", "x2", "stale")
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        cand = LiveCandidate(pr=3, sha="x3", stale=True)
        st.record_review("3", "x3", "PASS")                  # investment on the re-staled sha
        scen = {"config": {"MERGE_FAIRNESS": "on"}, "candidates": []}
        tick = LiveTick(scen["config"], FixtureDiscovery(scen), FixtureGates(scen),
                        DryRunActuator(journal), journal, state=st)
        tick._fairness_prepass([cand])
        evs = [e["event"] for e in events(journal.path)]
        self.assertIn("pr_restale", evs)
        self.assertIn("pr_starvation", evs)

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

    def test_branch_worktree_slug_matches_branch_to_slug_when_it_fits(self):
        # The common case (branch fits BRANCH_TEMPLATE): identical to branch_to_slug, no fallback.
        self.assertEqual(_branch_worktree_slug("feat/gizmo"), "gizmo")
        self.assertEqual(_branch_worktree_slug("feat/python-draft-pr-hold"), "python-draft-pr-hold")

    def test_branch_worktree_slug_falls_back_when_slash_remains(self):
        # HERD-377: a branch that does not fit BRANCH_TEMPLATE keeps its raw form (branch_to_slug does
        # not strip an unmatched prefix) — a bare '/' left in that would nest a stray subdirectory
        # under $TREES/<slug>, so the fallback flattens it. This is the SAME fallback herd_branch_slug
        # (herd-config.sh) applies for the bash ADOPT_REMOTE_PRS leg — one shared convention.
        self.assertEqual(_branch_worktree_slug("someuser:feature/x"), "someuser:feature-x")

    def test_branch_worktree_slug_empty_branch_is_empty(self):
        self.assertEqual(_branch_worktree_slug(""), "")

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


class TestDraftPRDiscovery(unittest.TestCase):
    """HERD-374: draft PRs must be skipped at discovery and never reach the merge actuator.
    Parity target: agent-watch.sh ~line 1805 `if pr.get("isDraft"): continue`."""

    def setUp(self):
        self._saved = os.environ.get("TREES")
        self._pool = tempfile.mkdtemp()
        os.environ["TREES"] = self._pool

    def tearDown(self):
        if self._saved is None:
            os.environ.pop("TREES", None)
        else:
            os.environ["TREES"] = self._saved

    def _stub_graphql(self, nodes):
        payload = {"data": {"repository": {"pullRequests": {"nodes": nodes}}}}

        class _Stub:
            def run(self, *a, **k):
                class R:
                    stdout = json.dumps(payload)
                return R()
        return _Stub()

    def test_draft_pr_is_skipped_at_discovery(self):
        # A draft PR must never appear in the returned candidates.
        _make_worktree(self._pool, "my-feature")
        node = {"number": 479, "headRefName": "feat/my-feature", "headRefOid": "abc123",
                "baseRefName": "main", "mergeStateStatus": "CLEAN", "isDraft": True,
                "reviewDecision": "", "author": {"login": "me"},
                "assignees": {"nodes": []}, "labels": {"nodes": []}}
        orig = LR.subprocess
        LR.subprocess = self._stub_graphql([node])
        try:
            cands = LR.discover_via_graphql(repo="owner/repo")
        finally:
            LR.subprocess = orig
        self.assertEqual(cands, [], "draft PR must be excluded from discovery results")

    def test_non_draft_pr_is_unaffected(self):
        # A non-draft PR with isDraft=False must still be returned (byte-identical behavior).
        _make_worktree(self._pool, "ready-feature")
        node = {"number": 480, "headRefName": "feat/ready-feature", "headRefOid": "def456",
                "baseRefName": "main", "mergeStateStatus": "CLEAN", "isDraft": False,
                "reviewDecision": "", "author": {"login": "me"},
                "assignees": {"nodes": []}, "labels": {"nodes": []}}
        orig = LR.subprocess
        LR.subprocess = self._stub_graphql([node])
        try:
            cands = LR.discover_via_graphql(repo="owner/repo")
        finally:
            LR.subprocess = orig
        self.assertEqual(len(cands), 1)
        self.assertEqual(cands[0].pr, "480")

    def test_missing_is_draft_field_treated_as_non_draft(self):
        # Legacy nodes with no isDraft field must be treated as non-draft (fail-soft).
        _make_worktree(self._pool, "legacy-feature")
        node = {"number": 481, "headRefName": "feat/legacy-feature", "headRefOid": "ghi789",
                "baseRefName": "main", "mergeStateStatus": "CLEAN",
                "reviewDecision": "", "author": {"login": "me"},
                "assignees": {"nodes": []}, "labels": {"nodes": []}}
        orig = LR.subprocess
        LR.subprocess = self._stub_graphql([node])
        try:
            cands = LR.discover_via_graphql(repo="owner/repo")
        finally:
            LR.subprocess = orig
        self.assertEqual(len(cands), 1, "absent isDraft must be treated as non-draft")
        self.assertEqual(cands[0].pr, "481")

    def test_draft_pr_never_reaches_merge_actuator(self):
        # Verify that the tick produces no merge_refused events when only non-draft PRs are present.
        # This exercises the end-to-end path: discovery skips drafts, so no merge_refused hot-loop.
        tmp = tempfile.mkdtemp()
        journal_path = os.path.join(tmp, "j.jsonl")
        journal = LiveJournal(journal_path)
        # A non-draft candidate with all gates green should merge, never merge_refused.
        cand_dict = {"pr": 482, "sha": "aaa", "slug": "ready", "stale": False,
                     "approved": True, "review_decision": "APPROVED",
                     "hv_hold": False, "hv_body": ""}
        scenario = {"candidates": [cand_dict],
                    "health": "PASS", "review": "PASS", "config": {}}
        disc = FixtureDiscovery(scenario)
        gates = FixtureGates(scenario)
        act = DryRunActuator(journal)
        tick = LiveTick({}, disc, gates, act, journal)
        tick.run()
        with open(journal_path) as f:
            events = [json.loads(l)["event"] for l in f if l.strip()]
        self.assertNotIn("merge_refused", events,
                         "merge_refused must never appear when no draft reaches the actuator")
        self.assertIn("merge", events, "a ready non-draft PR must merge")


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


class TestAdoptSlugParityRegression(unittest.TestCase):
    """HERD-377 REGRESSION: the ADOPT_REMOTE_PRS leg (agent-watch.sh) and candidate discovery
    (branch_to_slug/_worktree_for_slug, above) must resolve the SAME worktree path for the same
    branch. Before the fix, the adopt leg flattened the RAW branch ('feat/x' -> 'feat-x') while
    discovery derived the slug via branch_to_slug ('feat/x' -> 'x') — so an adopted PR's candidate
    carried a worktree path nothing on disk backed, and it was silently dropped from classification
    for as long as an hour (PR #484) despite `pr_adopted` having already claimed success.

    Both directions of the fixture, entirely in Python terms (worktree existing at a path or not),
    mirroring what tests/test-adopt-remote-prs.sh proves for the bash slugifier itself:
      (a) MISMATCH reproduces the drop — a candidate whose worktree is the pre-fix (flattened-raw-
          branch) path is dropped by pool-scoping and refused at the health gate.
      (b) POST-FIX the adopted PR gates — a candidate whose worktree is the SAME path
          _branch_worktree_slug/discover_via_graphql would resolve survives pool-scoping and reaches
          health dispatch (candidates>=1 and a health dispatch for it).
    """

    def setUp(self):
        self.pool = tempfile.mkdtemp()
        self._saved_trees = os.environ.get("TREES")
        os.environ["TREES"] = self.pool
        os.environ["HERD_JOURNAL_NOW"] = "2026-07-16T00:00:00Z"
        self.jpath = os.path.join(self.pool, "j.jsonl")
        self.journal = LiveJournal(self.jpath)
        self.state = LiveState(self.pool)

    def tearDown(self):
        if self._saved_trees is None:
            os.environ.pop("TREES", None)
        else:
            os.environ["TREES"] = self._saved_trees
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

    def test_mismatched_slug_worktree_is_dropped(self):
        # The PRE-FIX adopt leg only ever created TREES/feat-python-draft-pr-hold — never the
        # slug-parity path — so a candidate resolved the way discovery resolves it (branch ->
        # _branch_worktree_slug -> _worktree_for_slug) points at a directory that does not exist.
        branch = "feat/python-draft-pr-hold"
        correct_slug = _branch_worktree_slug(branch)
        self.assertEqual(correct_slug, "python-draft-pr-hold")
        mismatched_dir = os.path.join(self.pool, "feat-python-draft-pr-hold")  # the pre-fix path
        _make_worktree(self.pool, "feat-python-draft-pr-hold")                # only THIS dir exists
        cand = LiveCandidate(pr=484, sha="deadbeef", slug=correct_slug,
                              worktree=_worktree_for_slug(correct_slug))       # discovery's resolution
        self.assertNotEqual(cand.worktree, mismatched_dir)
        # Dropped at pool-scoping — never even reaches classification.
        self.assertEqual(_pool_scoped([cand]), [])
        # And belt-and-suspenders: the health gate itself refuses a resolved-but-absent worktree.
        g, dispatched = self._gates()
        self.assertEqual(g.health(cand), WAIT)
        self.assertEqual(dispatched, [])
        refused = [e for e in self._events() if e["event"] == "dispatch_refused"]
        self.assertEqual(len(refused), 1)
        self.assertEqual(refused[0]["reason"], "no-worktree")

    def test_slug_parity_worktree_gates(self):
        # POST-FIX: the adopt leg (herd_branch_slug) and discovery (_branch_worktree_slug) resolve the
        # SAME path, so the worktree the adopt leg actually created on disk is exactly the one the
        # candidate carries.
        branch = "feat/python-draft-pr-hold"
        slug = _branch_worktree_slug(branch)
        _make_worktree(self.pool, slug)                    # what the FIXED adopt leg creates
        cand = LiveCandidate(pr=484, sha="deadbeef", slug=slug,
                              worktree=_worktree_for_slug(slug))   # what discovery resolves
        # candidates >= 1: the adopted PR survives pool-scoping.
        kept = _pool_scoped([cand])
        self.assertEqual([c.pr for c in kept], ["484"])
        # A health dispatch for it: the gate proceeds past the worktree guard to a real dispatch.
        g, dispatched = self._gates()
        self.assertEqual(g.health(cand), WAIT)
        self.assertEqual(dispatched, ["484"])
        self.assertEqual([e for e in self._events() if e["event"] == "dispatch_refused"], [])


def _git_init_repo(path):
    """Create a bare-minimum git repo with one commit; return the HEAD SHA."""
    os.makedirs(path, exist_ok=True)
    subprocess.run(["git", "init", "-q", "-b", "main", path], check=True)
    subprocess.run(["git", "-C", path, "config", "user.email", "t@test"], check=True)
    subprocess.run(["git", "-C", path, "config", "user.name", "t"], check=True)
    open(os.path.join(path, "f"), "w").write("x")
    subprocess.run(["git", "-C", path, "add", "f"], check=True)
    subprocess.run(["git", "-C", path, "commit", "-q", "-m", "init"], check=True)
    return subprocess.check_output(["git", "-C", path, "rev-parse", "HEAD"]).decode().strip()


class TestMainHealthSlotPriority(unittest.TestCase):
    """HERD-359 regression: PR health must never starve main-health when HEALTH_CONCURRENCY=1.

    _main_health_pending() is the sentinel; LiveGates.health() reserves a slot when it is True."""

    def setUp(self):
        self._orig_env = {}
        for k in ("MAIN_HEALTH_TICK", "MAIN", "PROJECT_ROOT"):
            self._orig_env[k] = os.environ.pop(k, None)
        import tempfile as _t
        self.tmp = _t.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)
        for k, v in self._orig_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def _main_repo(self):
        p = os.path.join(self.tmp, "main")
        sha = _git_init_repo(p)
        os.environ["MAIN"] = p
        return p, sha

    def _make_gates(self, jpath):
        """LiveGates wired to self.tmp as state dir."""
        state = LiveState(state_dir=self.tmp)
        state.dir = self.tmp
        journal = LiveJournal(jpath)
        return LiveGates("/nonexistent-home", state, journal, config={"HEALTH_CONCURRENCY": "1"})

    # ── _main_health_pending unit tests ───────────────────────────────────────────────────────────

    def test_off_by_default(self):
        """MAIN_HEALTH_TICK unset → False (byte-inert)."""
        self.assertFalse(_main_health_pending(self.tmp))

    def test_off_explicit(self):
        os.environ["MAIN_HEALTH_TICK"] = "off"
        self.assertFalse(_main_health_pending(self.tmp))

    def test_no_state_dir(self):
        os.environ["MAIN_HEALTH_TICK"] = "on"
        self.assertFalse(_main_health_pending(None))

    def test_no_main_env(self):
        """Neither MAIN nor PROJECT_ROOT set → False (fail-safe, never blocks the PR rail)."""
        os.environ["MAIN_HEALTH_TICK"] = "on"
        self.assertFalse(_main_health_pending(self.tmp))

    def test_project_root_fallback(self):
        """MAIN unset (a plain var in agent-watch.sh, it never crosses the --tick subprocess
        boundary) → the exported PROJECT_ROOT resolves the main checkout (HERD-345 precedent)."""
        os.environ["MAIN_HEALTH_TICK"] = "on"
        p = os.path.join(self.tmp, "main")
        _git_init_repo(p)
        os.environ["PROJECT_ROOT"] = p
        self.assertTrue(_main_health_pending(self.tmp))

    def test_truthy_set_matches_bash(self):
        """The truthy set matches bash _main_health_enabled (1|true|on|yes|enable|enabled) —
        a value that arms the bash reconcile must also arm the python-side reservation."""
        self._main_repo()
        for v in ("1", "true", "on", "yes", "enable", "enabled", "ON", "Enabled"):
            os.environ["MAIN_HEALTH_TICK"] = v
            self.assertTrue(_main_health_pending(self.tmp), "expected pending for %r" % v)
        for v in ("off", "0", "no", "false", "bogus"):
            os.environ["MAIN_HEALTH_TICK"] = v
            self.assertFalse(_main_health_pending(self.tmp), "expected off for %r" % v)

    def test_pending_when_no_markers(self):
        """MAIN_HEALTH_TICK=on, valid MAIN, no markers → True (main-health needs a slot)."""
        os.environ["MAIN_HEALTH_TICK"] = "on"
        self._main_repo()
        self.assertTrue(_main_health_pending(self.tmp))

    def test_false_when_run_once_marker_exists(self):
        """Run-once marker present → this sha already has a verdict → not pending."""
        os.environ["MAIN_HEALTH_TICK"] = "on"
        _, sha = self._main_repo()
        open(os.path.join(self.tmp, ".main-health-" + sha), "w").close()
        self.assertFalse(_main_health_pending(self.tmp))

    def test_false_when_live_inflight(self):
        """A live in-flight marker for this sha → already dispatched → not pending."""
        os.environ["MAIN_HEALTH_TICK"] = "on"
        _, sha = self._main_repo()
        inflight = os.path.join(self.tmp, ".health-inflight-main-" + sha)
        _marker_write(inflight, os.getpid())
        self.assertFalse(_main_health_pending(self.tmp))

    # ── LiveGates.health() slot reservation tests ─────────────────────────────────────────────────

    def test_pr_health_waits_when_main_pending(self):
        """With HEALTH_CONCURRENCY=1 and main-health pending, no PR health starts (slot reserved)."""
        os.environ["MAIN_HEALTH_TICK"] = "on"
        self._main_repo()
        _make_worktree(self.tmp, "feat-1")
        cand = LiveCandidate(pr=1, sha="abc123", slug="feat-1",
                             worktree=os.path.join(self.tmp, "feat-1"))
        jpath = os.path.join(self.tmp, "j1.jsonl")
        gates = self._make_gates(jpath)
        result = gates.health(cand)
        self.assertEqual(result, WAIT)
        # No inflight marker must exist for this PR (dispatch must not have happened).
        inflight = os.path.join(self.tmp, ".health-inflight-1-abc123")
        self.assertFalse(os.path.exists(inflight), "PR health must not lay inflight marker when main-health is pending")
        with open(jpath, encoding="utf-8") as fh:
            evs = [json.loads(l) for l in fh if l.strip()]
        queued = [e for e in evs if e.get("event") == "health_queued"]
        self.assertEqual(len(queued), 1, "health_queued must be journaled for the deferred PR")

    def test_pr_health_proceeds_when_main_done(self):
        """Main-health done (run-once marker written) → PR health proceeds past the slot check."""
        os.environ["MAIN_HEALTH_TICK"] = "on"
        _, sha = self._main_repo()
        open(os.path.join(self.tmp, ".main-health-" + sha), "w").close()
        _make_worktree(self.tmp, "feat-2")
        cand = LiveCandidate(pr=2, sha="def456", slug="feat-2",
                             worktree=os.path.join(self.tmp, "feat-2"))
        jpath = os.path.join(self.tmp, "j2.jsonl")
        gates = self._make_gates(jpath)
        result = gates.health(cand)
        self.assertEqual(result, WAIT)
        # With no PR inflight and main-health done, the slot check passes — no health_queued event.
        with open(jpath, encoding="utf-8") as fh:
            evs = [json.loads(l) for l in fh if l.strip()]
        queued = [e for e in evs if e.get("event") == "health_queued"]
        self.assertEqual(queued, [], "health_queued must NOT be emitted when main-health slot is free")

    # ── HERD-373: tick-scoped memoization of _main_health_pending ────────────────────────────────

    class _CountingCheckOutputSub:
        """Subprocess stand-in counting `check_output` calls — proves the memo collapses N candidates'
        identical rev-parse subprocess spawns into exactly one per tick, never zero and never N."""

        DEVNULL = subprocess.DEVNULL

        def __init__(self, sha):
            self.sha = sha
            self.calls = 0

        def check_output(self, *a, **k):
            self.calls += 1
            return (self.sha + "\n").encode()

    def test_memo_one_rev_parse_across_multiple_candidates_same_tick(self):
        """Two PR candidates walked through the SAME LiveGates (one tick) → exactly ONE rev-parse
        subprocess spawn, not one per candidate (HERD-373)."""
        os.environ["MAIN_HEALTH_TICK"] = "on"
        _, sha = self._main_repo()
        _make_worktree(self.tmp, "feat-a")
        _make_worktree(self.tmp, "feat-b")
        cand_a = LiveCandidate(pr=10, sha="aaa111", slug="feat-a",
                               worktree=os.path.join(self.tmp, "feat-a"))
        cand_b = LiveCandidate(pr=11, sha="bbb222", slug="feat-b",
                               worktree=os.path.join(self.tmp, "feat-b"))
        gates = self._make_gates(os.path.join(self.tmp, "j-memo.jsonl"))
        sub = self._CountingCheckOutputSub(sha)
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            r1 = gates.health(cand_a)
            r2 = gates.health(cand_b)
        finally:
            LR.subprocess = orig
        self.assertEqual(r1, WAIT)
        self.assertEqual(r2, WAIT)
        self.assertEqual(sub.calls, 1,
                         "expected exactly ONE rev-parse across two candidates in the same tick")

    def test_memo_new_tick_reevaluates(self):
        """A NEW LiveGates instance (a new tick) re-runs the rev-parse — the memo is tick-scoped
        ONLY, never cross-tick / persisted."""
        os.environ["MAIN_HEALTH_TICK"] = "on"
        _, sha = self._main_repo()
        _make_worktree(self.tmp, "feat-c")
        cand = LiveCandidate(pr=12, sha="ccc333", slug="feat-c",
                             worktree=os.path.join(self.tmp, "feat-c"))
        sub = self._CountingCheckOutputSub(sha)
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            gates1 = self._make_gates(os.path.join(self.tmp, "j-tick1.jsonl"))
            gates1.health(cand)
            gates2 = self._make_gates(os.path.join(self.tmp, "j-tick2.jsonl"))
            gates2.health(cand)
        finally:
            LR.subprocess = orig
        self.assertEqual(sub.calls, 2, "a new LiveGates (new tick) must re-run the rev-parse")


def _write_jsonl(path, rows):
    with open(path, "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row) + "\n")


class TestCostEmitScanner(unittest.TestCase):
    """HERD-375: the ported cost.sh summer (herd.cost_emit) — dedup by message id, builder/review
    split by the reviewer fingerprint, priced against a stubbed table. Mirrors tests/test-cost.sh's
    scanner coverage (items 1-3) for the Python port."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.prices_path = os.path.join(self.tmp, "prices.json")
        with open(self.prices_path, "w", encoding="utf-8") as fh:
            json.dump({"claude-opus-4-8": {"in": 10.0, "out": 100.0}}, fh)
        os.environ["HERD_COST_PRICE_FILE"] = self.prices_path

    def tearDown(self):
        os.environ.pop("HERD_COST_PRICE_FILE", None)

    def test_dedup_and_split_and_price(self):
        d = os.path.join(self.tmp, "transcript")
        os.makedirs(d)
        _write_jsonl(os.path.join(d, "builder.jsonl"), [
            {"type": "user", "message": {"role": "user", "content": "build the thing"}},
            {"type": "assistant", "message": {"role": "assistant", "id": "a1", "model": "claude-opus-4-8",
             "usage": {"input_tokens": 1000000, "output_tokens": 0,
                       "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}},
            {"type": "assistant", "message": {"role": "assistant", "id": "b2", "model": "claude-opus-4-8",
             "usage": {"input_tokens": 0, "output_tokens": 1000000,
                       "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}},
            {"type": "assistant", "message": {"role": "assistant", "id": "a1", "model": "claude-opus-4-8",
             "usage": {"input_tokens": 1000000, "output_tokens": 0,   # duplicate a1 — must dedup
                       "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}},
        ])
        _write_jsonl(os.path.join(d, "review.jsonl"), [
            {"type": "user", "message": {"role": "user",
             "content": "You are an ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for the project "
                         "'herdkit'. THIS REVIEW: PR #42 (branch slug 'slug1')."}},
            {"type": "assistant", "message": {"role": "assistant", "id": "r1", "model": "claude-opus-4-8",
             "usage": {"input_tokens": 0, "output_tokens": 500000,
                       "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}},
        ])
        prices = CE._load_prices()
        comps = CE._scan_dir(d, prices)
        self.assertEqual(comps["builder"]["in"], 1000000)
        self.assertEqual(comps["builder"]["out"], 1000000)
        self.assertEqual(len(comps["builder"]["msgs"]), 2)     # a1 counted once despite the replay
        self.assertAlmostEqual(comps["builder"]["usd"], 110.0)
        self.assertEqual(comps["review"]["out"], 500000)
        self.assertAlmostEqual(comps["review"]["usd"], 50.0)

    def test_unknown_model_flagged_and_zero(self):
        d = os.path.join(self.tmp, "unknown")
        os.makedirs(d)
        _write_jsonl(os.path.join(d, "b.jsonl"), [
            {"type": "assistant", "message": {"role": "assistant", "id": "u1", "model": "claude-mystery-9",
             "usage": {"input_tokens": 1000000, "output_tokens": 1000000,
                       "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}},
        ])
        prices = CE._load_prices()
        comps = CE._scan_dir(d, prices)
        self.assertEqual(comps["builder"]["usd"], 0.0)           # unpriced -> $0, never guessed
        self.assertEqual(CE._primary_model(comps["builder"], prices), "claude-mystery-9?")


class TestCostEmitPricing(unittest.TestCase):
    def test_claude_sonnet_5_priced_nonzero(self):
        # HERD-375(c): claude-sonnet-5 is now the default builder tier — it must price non-zero,
        # not silently bill as $0 (herd cost flags an unpriced model with a `?` suffix instead).
        self.assertIn("claude-sonnet-5", CE.BUILTIN_PRICES)
        pin, pout = CE._price_of("claude-sonnet-5", CE.BUILTIN_PRICES)
        self.assertGreater(pin, 0)
        self.assertGreater(pout, 0)


class TestCostEmitMerge(LiveCase):
    """HERD-375: emit_merge_cost resolves the transcript dir via the exact munging cost.sh used and
    journals `cost` events with the fields herd.cost's reader expects (tests/test-cost.sh item 4,
    ported), and both actuators' reap() wire it in before the worktree is reaped."""

    def setUp(self):
        super().setUp()
        self.root = os.path.join(self.tmp, "transcript-root")
        os.environ["HERD_TRANSCRIPT_ROOT"] = self.root
        self.prices_path = os.path.join(self.tmp, "prices.json")
        with open(self.prices_path, "w", encoding="utf-8") as fh:
            json.dump({"claude-opus-4-8": {"in": 10.0, "out": 100.0}}, fh)
        os.environ["HERD_COST_PRICE_FILE"] = self.prices_path

    def tearDown(self):
        os.environ.pop("HERD_TRANSCRIPT_ROOT", None)
        os.environ.pop("HERD_COST_PRICE_FILE", None)
        super().tearDown()

    def _seed_transcript(self, worktree):
        munged = worktree.replace("/", "-").replace(".", "-")
        d = os.path.join(self.root, munged)
        os.makedirs(d)
        _write_jsonl(os.path.join(d, "builder.jsonl"), [
            {"type": "user", "message": {"role": "user", "content": "build the thing"}},
            {"type": "assistant", "message": {"role": "assistant", "id": "a1", "model": "claude-opus-4-8",
             "usage": {"input_tokens": 1000000, "output_tokens": 500000,
                       "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}},
        ])
        return d

    def test_emit_merge_cost_journals_typed_fields(self):
        wt = "/fake/wt/slug1"
        self._seed_transcript(wt)
        journal = LiveJournal(self.jpath)
        CE.emit_merge_cost(journal, "42", "slug1", wt)
        cost = [o for o in events(self.jpath) if o["event"] == "cost"]
        self.assertEqual(len(cost), 1)
        b = cost[0]
        self.assertEqual(b["component"], "builder")
        self.assertEqual(b["pr"], 42)
        self.assertIsInstance(b["pr"], int)
        self.assertEqual(b["slug"], "slug1")
        self.assertEqual(b["model"], "claude-opus-4-8")
        self.assertEqual(b["in"], 1000000)
        self.assertEqual(b["out"], 500000)
        self.assertIsInstance(b["in"], int)
        self.assertEqual(b["usd"], "60.000000")
        self.assertEqual(b["msgs"], 1)

    def test_no_transcript_dir_is_silent_noop(self):
        journal = LiveJournal(self.jpath)
        CE.emit_merge_cost(journal, "42", "slug1", "/no/such/worktree")
        self.assertFalse(os.path.exists(self.jpath))

    def test_empty_worktree_never_scans_real_transcript_root(self):
        # Guard: a fixture/dry-run candidate carries no real worktree ("") — this must never resolve
        # to the bare $HERD_TRANSCRIPT_ROOT and scan whatever transcripts happen to sit there.
        journal = LiveJournal(self.jpath)
        CE.emit_merge_cost(journal, "42", "slug1", "")
        self.assertFalse(os.path.exists(self.jpath))

    def test_reap_wiring_emits_cost_before_worktree_removed(self):
        wt = os.path.join(self.tmp, "pool", "slug1")
        os.makedirs(wt)
        self._seed_transcript(wt)
        sub = _RecordingSub(view_state="MERGED")
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        journal = LiveJournal(self.jpath)
        act = LiveActuator("/nonexistent-home", journal)
        cand = LiveCandidate(42, "deadbeef", slug="slug1", worktree=wt)
        act.reap(cand)
        names = [o["event"] for o in events(self.jpath)]
        self.assertIn("cost", names)
        self.assertIn("reap", names)
        self.assertLess(names.index("cost"), names.index("reap"))

    def test_dry_run_reap_also_emits_cost(self):
        wt = os.path.join(self.tmp, "pool", "slug2")
        os.makedirs(wt)
        self._seed_transcript(wt)
        journal = LiveJournal(self.jpath)
        act = DryRunActuator(journal)
        cand = LiveCandidate(43, "cafebabe", slug="slug2", worktree=wt)
        act.reap(cand)
        self.assertTrue([o for o in events(self.jpath) if o["event"] == "cost"])


class TestWorkUnitAdapterSkeleton(unittest.TestCase):
    """HERD-403 (post-port amendment, docs/spikes/work-unit-abstraction.md §9): the python-side
    WorkUnit adapter interface skeleton — resolve_adapter's WORK_UNIT_KIND selection, the base
    adapter's named NotImplementedError, and GitPrAdapter's composition of the EXISTING gate/apply
    pieces. Unwired from the live tick (nothing in live_runtime calls herd.work_unit), so these tests
    exercise the skeleton directly, hermetically — FixtureGates/DryRunActuator, never a subprocess."""

    def tearDown(self):
        os.environ.pop("WORK_UNIT_KIND", None)

    # ── resolve_adapter: kind selection ───────────────────────────────────────────────────────────
    def test_default_kind_resolves_to_git_pr_adapter(self):
        adapter = WU.resolve_adapter()
        self.assertEqual(adapter.kind, "git-pr")
        self.assertIsInstance(adapter, WU.GitPrAdapter)

    def test_explicit_kind_arg_wins(self):
        adapter = WU.resolve_adapter("git-pr")
        self.assertEqual(adapter.kind, "git-pr")

    def test_config_work_unit_kind_selects_adapter(self):
        adapter = WU.resolve_adapter(config={"WORK_UNIT_KIND": "git-pr"})
        self.assertEqual(adapter.kind, "git-pr")

    def test_env_work_unit_kind_is_read_when_no_explicit_kind_or_config(self):
        os.environ["WORK_UNIT_KIND"] = "git-pr"
        adapter = WU.resolve_adapter()
        self.assertEqual(adapter.kind, "git-pr")

    def test_explicit_kind_wins_over_env(self):
        os.environ["WORK_UNIT_KIND"] = "does-not-matter"
        with self.assertRaises(WU.UnsupportedWorkUnitKind):
            WU.resolve_adapter()  # env value is bogus and nothing overrides it -> hard refusal
        adapter = WU.resolve_adapter("git-pr")  # explicit arg wins regardless
        self.assertEqual(adapter.kind, "git-pr")

    def test_unsupported_kind_is_a_hard_refusal_not_a_silent_fallback(self):
        # "doc-apply" itself is now a REAL, supported kind (HERD-399) — a genuinely unshipped kind
        # name (a hypothetical future git-pr sibling per the spike's own open-questions §5) proves the
        # same hard-refusal contract without going stale the moment a second kind ships.
        with self.assertRaises(WU.UnsupportedWorkUnitKind):
            WU.resolve_adapter("git-mr")

    def test_unsupported_kind_from_config_is_also_a_hard_refusal(self):
        with self.assertRaises(WU.UnsupportedWorkUnitKind):
            WU.resolve_adapter(config={"WORK_UNIT_KIND": "config-apply"})

    # ── base adapter: every op is a NAMED NotImplementedError ────────────────────────────────────
    def test_base_adapter_ops_are_unimplemented_and_named(self):
        base = WU.WorkUnitAdapter()
        ops = (("open", (None,)), ("list_open", ()), ("inspect", (None,)),
               ("gate", (None, None)), ("apply", (None, None)),
               ("reconcile", (None,)), ("teardown", (None,)))
        for op, args in ops:
            with self.assertRaises(NotImplementedError) as ctx:
                getattr(base, op)(*args)
            self.assertIn(op, str(ctx.exception))

    # ── GitPrAdapter: open/reconcile/teardown are honest gaps, not silent no-ops ────────────────
    def test_git_pr_adapter_open_reconcile_teardown_not_implemented(self):
        adapter = WU.GitPrAdapter()
        with self.assertRaises(NotImplementedError):
            adapter.open(None)
        with self.assertRaises(NotImplementedError):
            adapter.reconcile(None)
        with self.assertRaises(NotImplementedError):
            adapter.teardown(None)

    # ── GitPrAdapter.list_open: one-line delegation to the injected discovery ───────────────────
    def test_git_pr_adapter_list_open_delegates_to_injected_discovery(self):
        calls = {}

        class _StubDiscovery:
            def discover(self):
                calls["called"] = True
                return ["stub-unit"]

        adapter = WU.GitPrAdapter(discovery=_StubDiscovery())
        self.assertEqual(adapter.list_open(), ["stub-unit"])
        self.assertTrue(calls.get("called"))

    # ── GitPrAdapter.gate: composes LiveGates.health/.review into a GateResult ──────────────────
    def _gate_adapter(self, tmp, pr, sha, **spec):
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        scenario = {"candidates": [dict(pr=pr, sha=sha, **spec)]}
        return WU.GitPrAdapter(gates=FixtureGates(scenario), actuator=DryRunActuator(journal))

    def test_gate_passes_on_clean_health_and_pass_review(self):
        tmp = tempfile.mkdtemp()
        adapter = self._gate_adapter(tmp, 1, "abc", health="CLEAN", review="PASS")
        cand = LiveCandidate(pr=1, sha="abc", slug="feat-x")
        result = adapter.gate(cand, cand.sha)
        self.assertIsInstance(result, WU.GateResult)
        self.assertEqual(result.status, "pass")
        self.assertEqual(result.evidence, {"health": "CLEAN", "review": "PASS"})

    def test_gate_blocks_on_health_codeerror(self):
        tmp = tempfile.mkdtemp()
        adapter = self._gate_adapter(tmp, 2, "def", health="CODEERROR", review="PASS")
        cand = LiveCandidate(pr=2, sha="def", slug="feat-y")
        self.assertEqual(adapter.gate(cand, cand.sha).status, "block")

    def test_gate_blocks_on_review_block(self):
        tmp = tempfile.mkdtemp()
        adapter = self._gate_adapter(tmp, 3, "ghi", health="CLEAN", review="BLOCK")
        cand = LiveCandidate(pr=3, sha="ghi", slug="feat-z")
        self.assertEqual(adapter.gate(cand, cand.sha).status, "block")

    def test_gate_errors_on_review_infra(self):
        tmp = tempfile.mkdtemp()
        adapter = self._gate_adapter(tmp, 4, "jkl", health="CLEAN", review="INFRA")
        cand = LiveCandidate(pr=4, sha="jkl", slug="feat-w")
        self.assertEqual(adapter.gate(cand, cand.sha).status, "error")

    def test_gate_waits_while_a_rail_is_still_dispatching(self):
        tmp = tempfile.mkdtemp()
        adapter = self._gate_adapter(tmp, 5, "mno", health=WAIT, review="PASS")
        cand = LiveCandidate(pr=5, sha="mno", slug="feat-v")
        self.assertEqual(adapter.gate(cand, cand.sha).status, "wait")

    # ── GitPrAdapter.apply: one-line delegation to the injected actuator's merge ────────────────
    def test_apply_wraps_actuator_merge_success(self):
        tmp = tempfile.mkdtemp()
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.GitPrAdapter(actuator=DryRunActuator(journal))
        cand = LiveCandidate(pr=6, sha="pqr", slug="feat-u")
        result = adapter.apply(cand, cand.sha)
        self.assertIsInstance(result, WU.ApplyResult)
        self.assertEqual(result.status, "applied")
        names = [e["event"] for e in events(os.path.join(tmp, "j.jsonl"))]
        self.assertIn("merge", names)

    def test_apply_reports_refused_when_actuator_merge_returns_false(self):
        class _RefusingActuator:
            def merge(self, cand):
                return False

        adapter = WU.GitPrAdapter(actuator=_RefusingActuator())
        cand = LiveCandidate(pr=7, sha="stu", slug="feat-t")
        self.assertEqual(adapter.apply(cand, cand.sha).status, "refused")

    # ── GitPrAdapter.to_unit: spike-shaped WorkUnit, unit_id matches the HERD-397 journal ref ────
    def test_to_unit_shape_matches_journal_unit_ref(self):
        adapter = WU.GitPrAdapter()
        cand = LiveCandidate(pr=42, sha="deadbeef", slug="feat-w", base="main")
        unit = adapter.to_unit(cand)
        self.assertIsInstance(unit, WU.WorkUnit)
        self.assertEqual(unit.unit_id, "git-pr:42")
        self.assertEqual(unit.kind, "git-pr")
        self.assertEqual(unit.slug, "feat-w")
        self.assertEqual(unit.revision, "deadbeef")
        self.assertEqual(unit.artifact["pr_number"], cand.pr)
        self.assertEqual(unit.artifact["base_ref"], "main")


def _doc_apply_fixture(tmp):
    """A real, minimal doc-apply scenario on disk: a bare 'origin', a 'main' checkout on branch
    ``main`` (one commit, docs/x.md == "orig"), and a builder worktree on branch ``feat/doc`` carrying
    ONE extra commit that changes docs/x.md to "updated". Returns ``(main, worktree, revision)`` — no
    fixture/mock anywhere, so a test that drives :class:`WU.LiveDocApply` through this exercises the
    REAL git plumbing the way the live engine would, just against a throwaway temp repo (mirrors
    ``_git_init_repo`` above, extended with the origin/worktree shape doc-apply's apply() needs)."""
    bare = os.path.join(tmp, "origin.git")
    subprocess.run(["git", "init", "-q", "--bare", bare], check=True)
    main = os.path.join(tmp, "main")
    subprocess.run(["git", "init", "-q", "-b", "main", main], check=True)
    subprocess.run(["git", "-C", main, "config", "user.email", "t@test"], check=True)
    subprocess.run(["git", "-C", main, "config", "user.name", "t"], check=True)
    subprocess.run(["git", "-C", main, "remote", "add", "origin", bare], check=True)
    os.makedirs(os.path.join(main, "docs"), exist_ok=True)
    with open(os.path.join(main, "docs", "x.md"), "w", encoding="utf-8") as fh:
        fh.write("orig\n")
    subprocess.run(["git", "-C", main, "add", "."], check=True)
    subprocess.run(["git", "-C", main, "commit", "-q", "-m", "init"], check=True)
    subprocess.run(["git", "-C", main, "push", "-q", "-u", "origin", "main"], check=True)
    worktree = os.path.join(tmp, "wt-slug")
    subprocess.run(["git", "-C", main, "worktree", "add", "-q", "-b", "feat/doc", worktree], check=True)
    with open(os.path.join(worktree, "docs", "x.md"), "w", encoding="utf-8") as fh:
        fh.write("updated\n")
    subprocess.run(["git", "-C", worktree, "add", "docs/x.md"], check=True)
    subprocess.run(["git", "-C", worktree, "commit", "-q", "-m", "docs: update x"], check=True)
    revision = subprocess.check_output(["git", "-C", worktree, "rev-parse", "HEAD"]).decode().strip()
    return main, worktree, revision


class TestDocApplyAdapter(unittest.TestCase):
    """HERD-399 (spike §9.4's re-planned Phase 4): the doc-apply work-unit adapter — the SECOND kind,
    proving the interface generalizes past git-pr. open/list_open/inspect/gate are driven hermetically
    (a FixtureGates twin, never a subprocess for health/review); apply() is driven against REAL
    throwaway git repos (:func:`_doc_apply_fixture`) because "landed by direct push to the default
    branch" is exactly the claim that must be proven with real git, not simulated."""

    def tearDown(self):
        os.environ.pop("WORK_UNIT_KIND", None)

    # ── resolve_adapter: doc-apply is now a real, selectable kind ────────────────────────────────
    def test_resolve_doc_apply_kind_selects_adapter(self):
        adapter = WU.resolve_adapter("doc-apply", worktrees_dir=tempfile.mkdtemp(),
                                     journal=LiveJournal(None))
        self.assertIsInstance(adapter, WU.DocApplyAdapter)
        self.assertEqual(adapter.kind, "doc-apply")

    def test_default_kind_is_still_git_pr_byte_identical(self):
        # STRICTLY OPT-IN (byte-identical checklist): shipping doc-apply changes nothing about the
        # default resolution — no kind argument, no config, no env still yields git-pr.
        adapter = WU.resolve_adapter()
        self.assertIsInstance(adapter, WU.GitPrAdapter)

    # ── open: manifest convention (spike §3.2 step 1) ────────────────────────────────────────────
    def test_open_writes_manifest_with_the_documented_shape(self):
        tmp = tempfile.mkdtemp()
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=LiveJournal(None))
        unit = adapter.open({"slug": "s3", "worktree": "", "revision": "rev3",
                             "item_ref": "HERD-9", "paths": ["docs/a.md"],
                             "title": "t", "body": "Refs: HERD-9"})
        self.assertEqual(unit.unit_id, "doc-apply:s3")
        self.assertEqual(unit.kind, "doc-apply")
        self.assertEqual(unit.item_ref, "HERD-9")
        with open(os.path.join(tmp, "s3.unit.json"), encoding="utf-8") as fh:
            obj = json.load(fh)
        self.assertEqual(obj["kind"], "doc-apply")
        self.assertEqual(obj["slug"], "s3")
        self.assertEqual(obj["paths"], ["docs/a.md"])
        self.assertEqual(obj["state"], "open")

    def test_open_is_idempotent_on_an_unchanged_revision(self):
        tmp = tempfile.mkdtemp()
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=LiveJournal(None))
        u1 = adapter.open({"slug": "s2", "worktree": "", "revision": "rev1", "paths": ["docs/a.md"]})
        u2 = adapter.open({"slug": "s2", "worktree": "", "revision": "rev1", "paths": ["docs/a.md"]})
        self.assertEqual(u1.unit_id, u2.unit_id)
        self.assertEqual(u1.revision, u2.revision)

    # ── list_open: strictly opt-in + fail-soft (spike §3.2 step 2) ───────────────────────────────
    def test_list_open_empty_with_no_manifests_strictly_opt_in(self):
        tmp = tempfile.mkdtemp()
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=LiveJournal(None))
        self.assertEqual(adapter.list_open(), [])

    def test_list_open_skips_malformed_manifest_fail_soft_never_crashes(self):
        tmp = tempfile.mkdtemp()
        with open(os.path.join(tmp, "broken.unit.json"), "w", encoding="utf-8") as fh:
            fh.write("{not json")
        jpath = os.path.join(tmp, "j.jsonl")
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=LiveJournal(jpath))
        self.assertEqual(adapter.list_open(), [])   # never raises
        self.assertIn("doc_apply_manifest_invalid", [e["event"] for e in events(jpath)])

    def test_list_open_excludes_applied_units(self):
        tmp = tempfile.mkdtemp()
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=LiveJournal(None))
        adapter.open({"slug": "s1", "worktree": "", "revision": "abc", "paths": ["docs/a.md"]})
        self.assertEqual(len(adapter.list_open()), 1)
        path = adapter._manifest_path("s1")
        obj = WU._read_manifest(path)
        obj["state"] = "applied"
        WU._write_manifest(path, obj)
        self.assertEqual(adapter.list_open(), [])

    # ── gate: fail-closed path allowlist + the SAME health/review composition as GitPrAdapter ────
    def _gated_unit(self, tmp, journal, gates, paths, config=None):
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal, gates=gates,
                                     config=config or {})
        unit = adapter.open({"slug": "doc-slug", "worktree": "", "revision": "rev-x", "paths": paths})
        return adapter, unit

    def test_gate_blocks_on_a_disallowed_non_doc_path(self):
        tmp = tempfile.mkdtemp()
        jpath = os.path.join(tmp, "j.jsonl")
        adapter, unit = self._gated_unit(tmp, LiveJournal(jpath), None, ["scripts/herd/agent-watch.sh"])
        result = adapter.gate(unit, unit.revision)
        self.assertEqual(result.status, "block")
        self.assertIn("doc_apply_gate_refused", [e["event"] for e in events(jpath)])

    def test_gate_blocks_with_no_paths_at_all(self):
        tmp = tempfile.mkdtemp()
        adapter, unit = self._gated_unit(tmp, LiveJournal(None), None, [])
        self.assertEqual(adapter.gate(unit, unit.revision).status, "block")

    def test_gate_errors_when_no_gates_collaborator_injected(self):
        tmp = tempfile.mkdtemp()
        adapter, unit = self._gated_unit(tmp, LiveJournal(None), None, ["docs/a.md"])
        self.assertEqual(adapter.gate(unit, unit.revision).status, "error")

    def test_gate_passes_on_clean_health_and_pass_review(self):
        tmp = tempfile.mkdtemp()
        scenario = {"candidates": [dict(pr="doc-slug", sha="rev-x", health="CLEAN", review="PASS")]}
        adapter, unit = self._gated_unit(tmp, LiveJournal(None), FixtureGates(scenario), ["docs/a.md"])
        result = adapter.gate(unit, unit.revision)
        self.assertEqual(result.status, "pass")
        self.assertEqual(result.evidence["health"], "CLEAN")
        self.assertEqual(result.evidence["review"], "PASS")

    def test_gate_blocks_on_health_codeerror(self):
        tmp = tempfile.mkdtemp()
        scenario = {"candidates": [dict(pr="doc-slug", sha="rev-x", health="CODEERROR", review="PASS")]}
        adapter, unit = self._gated_unit(tmp, LiveJournal(None), FixtureGates(scenario), ["docs/a.md"])
        self.assertEqual(adapter.gate(unit, unit.revision).status, "block")

    def test_gate_blocks_on_review_block(self):
        tmp = tempfile.mkdtemp()
        scenario = {"candidates": [dict(pr="doc-slug", sha="rev-x", health="CLEAN", review="BLOCK")]}
        adapter, unit = self._gated_unit(tmp, LiveJournal(None), FixtureGates(scenario), ["docs/a.md"])
        self.assertEqual(adapter.gate(unit, unit.revision).status, "block")

    def test_gate_respects_operator_docs_only_glob_as_the_allowlist(self):
        tmp = tempfile.mkdtemp()
        scenario = {"candidates": [dict(pr="doc-slug", sha="rev-x", health="CLEAN", review="PASS")]}
        adapter, unit = self._gated_unit(tmp, LiveJournal(None), FixtureGates(scenario),
                                         ["notes/readme.txt"], config={"DOCS_ONLY_GLOB": r"\.(md|txt)$"})
        self.assertEqual(adapter.gate(unit, unit.revision).status, "pass")

    # ── apply: real git — scoped checkout + commit + push onto the default branch, no PR ──────────
    def test_apply_lands_a_real_commit_on_the_default_branch(self):
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        jpath = os.path.join(tmp, "j.jsonl")
        journal = LiveJournal(jpath)
        scenario = {"candidates": [dict(pr="doc-slug", sha=revision, health="CLEAN", review="PASS")]}
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal, gates=FixtureGates(scenario),
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "doc-slug", "worktree": worktree, "revision": revision,
                             "item_ref": "HERD-1", "paths": ["docs/x.md"],
                             "title": "docs: update x", "body": "Refs: HERD-1"})
        self.assertEqual(adapter.gate(unit, revision).status, "pass")
        result = adapter.apply(unit, revision)
        self.assertEqual(result.status, "applied")
        with open(os.path.join(main, "docs", "x.md"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "updated\n")
        log = subprocess.check_output(["git", "-C", main, "log", "-1", "--pretty=%B"]).decode()
        self.assertIn("HERD-1", log)
        self.assertIn("doc-apply:doc-slug", log)
        # pushed: origin's main tip now matches $MAIN's (never left ahead-of-origin locally only)
        origin_head = subprocess.check_output(
            ["git", "-C", main, "rev-parse", "origin/main"]).decode().strip()
        main_head = subprocess.check_output(["git", "-C", main, "rev-parse", "HEAD"]).decode().strip()
        self.assertEqual(origin_head, main_head)
        applied = [e for e in events(jpath) if e["event"] == "apply"][0]
        self.assertEqual(applied["unit"], "doc-apply:doc-slug")
        self.assertEqual(applied["kind"], "doc-apply")

    def test_apply_is_at_most_once(self):
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "doc-slug", "worktree": worktree, "revision": revision,
                             "paths": ["docs/x.md"], "title": "t", "body": "b"})
        first = adapter.apply(unit, revision)
        self.assertEqual(first.status, "applied")
        head_after_first = subprocess.check_output(["git", "-C", main, "rev-parse", "HEAD"]).decode()
        second = adapter.apply(unit, revision)
        self.assertEqual(second.status, "already")
        head_after_second = subprocess.check_output(["git", "-C", main, "rev-parse", "HEAD"]).decode()
        self.assertEqual(head_after_first, head_after_second)   # no second commit landed

    def test_a_failing_gate_blocks_the_apply(self):
        """The core interface proof (spike §9.4 point 2): a doc-apply unit whose gate BLOCKS must
        never land — proven at the git level, not just by inspecting a return value."""
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        # A non-doc path never clears the allowlist -> gate blocks -> apply refuses (defense in depth).
        unit = adapter.open({"slug": "bad-slug", "worktree": worktree, "revision": revision,
                             "paths": ["scripts/herd/agent-watch.sh"], "title": "t", "body": "b"})
        self.assertEqual(adapter.gate(unit, revision).status, "block")
        result = adapter.apply(unit, revision)
        self.assertEqual(result.status, "refused")
        log = subprocess.check_output(["git", "-C", main, "log", "--oneline"]).decode().strip().splitlines()
        self.assertEqual(len(log), 1)   # still just the init commit — nothing landed

    def test_apply_refuses_when_manifest_unreadable(self):
        tmp = tempfile.mkdtemp()
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=LiveJournal(None))
        unit = WU.WorkUnit(unit_id="doc-apply:ghost", kind="doc-apply", slug="ghost", revision="x")
        self.assertEqual(adapter.apply(unit, "x").status, "error")

    # ── reconcile/teardown: honest gaps (bash-owned, spike §9.1/§9.4), never a silent no-op ──────
    def test_reconcile_and_teardown_are_not_implemented(self):
        adapter = WU.DocApplyAdapter(worktrees_dir=tempfile.mkdtemp(), journal=LiveJournal(None))
        with self.assertRaises(NotImplementedError) as ctx:
            adapter.reconcile(None)
        self.assertIn("reconcile", str(ctx.exception))
        with self.assertRaises(NotImplementedError) as ctx:
            adapter.teardown(None)
        self.assertIn("teardown", str(ctx.exception))


if __name__ == "__main__":
    unittest.main(verbosity=2)
