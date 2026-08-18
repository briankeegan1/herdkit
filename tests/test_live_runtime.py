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
import hashlib
import json
import os
import shlex
import shutil
import sys
import tempfile
import unittest
from unittest import mock

import subprocess
import time

from herd import ci_verdict as CVD
from herd import cost_emit as CE
from herd import decisions as D
from herd import live_runtime as LR
from herd.live_runtime import (LiveTick, LiveJournal, LiveState, LiveGates, LiveCandidate,
                               LiveActuator, LiveHoldSource,
                               FixtureDiscovery, FixtureGates, DryRunActuator, parse_review_verdict,
                               parse_rubric_verdicts, parse_block_fields, parse_block_reason,
                               _select_candidates, _watcher_scope, _marker_write, _marker_live, _terminate_worker,
                               _marker_nonce, _dispatch_nonce,
                               _main_health_pending,
                               WAIT, PENDING,
                               branch_to_slug, _branch_worktree_slug, _worktree_for_slug,
                               _is_worktree, _pool_scoped,
                               _merge_result_gate_enabled, _resolve_default_branch_sha,
                               _dispatch_nonce_with_base, _nonce_base, _total_health_inflight)
from herd import work_unit as WU
from herd import human_verify as _hv

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


class _PromptRecordingActuator(DryRunActuator):
    """HERD-420: a DryRunActuator that records every prompt text handed to wake_builder, so a test
    can assert the completion leg's "finish your uncommitted work" nudge (LiveTick._refix_finish_prompt)
    is genuinely a different string from the original bounce prompt — the journal itself never
    carries the prompt text, so this is the only observable seam."""

    def __init__(self, journal):
        super().__init__(journal)
        self.prompts = []

    def wake_builder(self, cand, prompt):
        self.prompts.append(prompt)
        return super().wake_builder(cand, prompt)


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

    # ── HUMAN_VERIFY_POLICY forensics (HERD-59, restored HERD-439) ────────────────────────────────
    # HERD-306 P5b deleted the bash action pass and the port never re-emitted the two policy-keyed
    # journal surfaces bash carried, so `human_verify_policy` became a consumer-only event (read by
    # journal-audit.sh §5.4 and fixture_extract.py, produced by nobody). A hold or an auto-merge that
    # leaves no forensic trace is invisible to exactly the post-mortem that would explain it, so both
    # emissions are pinned here BEHAVIORALLY — and pinned OFF on the default policy.

    def test_default_hold_policy_hold_applied_carries_no_policy_field(self):
        # Byte-identical-when-off: HUMAN_VERIFY_POLICY unset (=hold) must emit today's exact event.
        out, ev = self._out(review="PASS", health="CLEAN", hv_hold=True)
        self.assertEqual(out, "HOLD")
        held = [o for o in ev if o["event"] == "hold_applied"]
        self.assertEqual(len(held), 1)
        self.assertEqual(held[0]["kind"], "human-verify")
        self.assertNotIn("human_verify_policy", held[0])

    def test_coordinator_policy_hold_applied_names_the_policy(self):
        out, ev = self._out(review="PASS", health="CLEAN", hv_hold=True,
                            config={"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "coordinator"})
        self.assertEqual(out, "HOLD")            # coordinator STILL holds — it is not an auto-merge
        held = [o for o in ev if o["event"] == "hold_applied"]
        self.assertEqual(len(held), 1)
        self.assertEqual(held[0]["human_verify_policy"], "coordinator")

    def test_auto_policy_merges_and_journals_the_declared_steps(self):
        out, ev = self._out(review="PASS", health="CLEAN", hv_hold=True,
                            config={"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "auto"})
        self.assertEqual(out, "MERGE")
        hv = [o for o in ev if o["event"] == "human_verify_policy"]
        self.assertEqual(len(hv), 1)
        self.assertEqual(hv[0]["policy"], "auto")
        self.assertEqual(hv[0]["action"], "merged-with-declared-steps")
        self.assertEqual(str(hv[0]["pr"]), "1")

    def test_auto_policy_silent_when_the_pr_declared_no_steps(self):
        # No HUMAN-VERIFY block => nothing was skipped => no event to record.
        out, ev = self._out(review="PASS", health="CLEAN",
                            config={"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "auto"})
        self.assertEqual(out, "MERGE")
        self.assertFalse([o for o in ev if o["event"] == "human_verify_policy"])

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


class TestRefixCapDurableLatch(LiveCase):
    """HERD-576 leg 1: the durable per-(pr, rail) exhaustion latch — a restart-safe marker FILE
    (mirroring the HERD-185 inflight-marker pattern of "one small file names one fact") that STOPS a
    rail bouncing once its budget is spent, independent of re-deriving the count from the ledger, and
    is cleared the instant the rail's red genuinely resolves. Every tick() call below is its own
    fresh LiveTick (its own process, in production) sharing only the on-disk state dir — the process
    boundary IS the scenario, exactly like test_refix_round_advances_per_new_sha above."""

    def _tick(self, cand, config, state_dir, tag):
        scenario = {"candidates": [cand], "config": config}
        jpath = os.path.join(self.tmp, "latch-%s.jsonl" % tag)
        j = LiveJournal(jpath)
        t = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario),
                     DryRunActuator(j), j, state=LiveState(state_dir))
        t.run()
        return events(jpath) if os.path.exists(jpath) else []

    def _latch_path(self, state_dir, pr, kind="health"):
        return os.path.join(state_dir, ".refix-escalated-%s-%s" % (pr, kind))

    def test_three_bounces_then_needs_you_latches_durably_across_restart(self):
        state_dir = os.path.join(self.tmp, "state-latch")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3"}
        pr = 700
        # Three DIFFERENT shas, each its own "restart" — rounds 1, 2, 3, exactly at the cap.
        for i, sha in enumerate(["sha-a", "sha-b", "sha-c"], 1):
            cand = {"pr": pr, "sha": sha, "slug": "feat-cap", "health": "CODEERROR"}
            evs = self._tick(cand, config, state_dir, "r%d" % i)
            rb = [e for e in evs if e["event"] == "refix_bounce" and e.get("rule") == "healthcheck"]
            self.assertEqual(len(rb), 1, "sha %s round %d" % (sha, i))
            self.assertEqual(rb[0]["round"], i)
        self.assertFalse(os.path.exists(self._latch_path(state_dir, pr)),
                         "the latch must not exist before the budget is actually spent")

        # A 4th trigger (a fresh sha, a fresh "restart") — budget exhausted → ESCALATE, no bounce,
        # and the durable latch is now written to disk.
        cand4 = {"pr": pr, "sha": "sha-d", "slug": "feat-cap", "health": "CODEERROR"}
        evs4 = self._tick(cand4, config, state_dir, "r4")
        self.assertFalse([e for e in evs4 if e["event"] == "refix_bounce"],
                         "budget-exhausted trigger must not bounce")
        esc = [e for e in evs4 if e["event"] == "health_refix_escalated"]
        self.assertEqual(len(esc), 1)
        self.assertIn("refix limit (3 rounds) reached", esc[0]["reason"])
        latch_path = self._latch_path(state_dir, pr)
        self.assertTrue(os.path.exists(latch_path), "cap exhaustion must write the durable latch")

        # PROVE the latch carries genuine, INDEPENDENT restart-safety value: even with the durable
        # ledger itself gone (simulating the exact loss the ledger-count arithmetic alone cannot
        # survive), the latch ALONE must still stop a brand-new sha from bouncing.
        os.remove(os.path.join(state_dir, ".agent-watch-refixed"))
        cand5 = {"pr": pr, "sha": "sha-e", "slug": "feat-cap", "health": "CODEERROR"}
        evs5 = self._tick(cand5, config, state_dir, "r5")
        self.assertFalse([e for e in evs5 if e["event"] == "refix_bounce"],
                         "the durable latch alone must still stop a bounce even with the ledger gone")

    def test_rail_reset_clears_the_durable_latch_and_restores_budget(self):
        state_dir = os.path.join(self.tmp, "state-latch-reset")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "1"}
        pr = 701
        latch_path = self._latch_path(state_dir, pr)

        cand1 = {"pr": pr, "sha": "sha-x", "slug": "feat-reset", "health": "CODEERROR"}
        self._tick(cand1, config, state_dir, "x1")          # round 1 == cap
        cand2 = {"pr": pr, "sha": "sha-y", "slug": "feat-reset", "health": "CODEERROR"}
        evs2 = self._tick(cand2, config, state_dir, "x2")   # exhausted -> latched
        self.assertTrue([e for e in evs2 if e["event"] == "health_refix_escalated"])
        self.assertTrue(os.path.exists(latch_path))

        # The rail's red genuinely RESOLVES (CLEAN) — the latch clears at the same instant the
        # ledger count itself zeroes (contract §4 refund-on-green).
        cand_clean = {"pr": pr, "sha": "sha-z", "slug": "feat-reset", "health": "CLEAN"}
        self._tick(cand_clean, config, state_dir, "x3")
        self.assertFalse(os.path.exists(latch_path), "a genuine resolve must clear the durable latch")

        # A fresh CODEERROR after the reset bounces at round 1 again — the budget is truly restored,
        # not just cosmetically unlatched.
        cand4 = {"pr": pr, "sha": "sha-w", "slug": "feat-reset", "health": "CODEERROR"}
        evs4 = self._tick(cand4, config, state_dir, "x4")
        rb = [e for e in evs4 if e["event"] == "refix_bounce"]
        self.assertEqual(len(rb), 1)
        self.assertEqual(rb[0]["round"], 1)


class TestGateConfigGenerationHint(LiveCase):
    """HERD-576 leg 2: a sha-cached CODEERROR verdict that predates the gate config running THIS
    tick renders an advisory hint — so an operator reading a long-standing red can tell a stale
    verdict from a fresh one instead of wondering why an old red survived a config change."""

    class _ReusedHealthGates:
        """A minimal gates stub whose `health()` always reports a REUSED cache hit (`reused_health`
        True) — the one shape the live `LiveGates.health()` never produces on the SAME tick a verdict
        is freshly collected (a fresh collect always stamps the CURRENT generation, by construction;
        only a later tick reusing an OLDER stamp can ever observe a mismatch)."""

        reused_review = True

        def __init__(self, verdict="CODEERROR"):
            self.reused_health = True
            self._verdict = verdict

        def health(self, cand):
            return self._verdict

        def review(self, cand):
            return "PASS"

    def _run(self, cand_dict, config, state, tag):
        scenario = {"candidates": [cand_dict], "config": config}
        jpath = os.path.join(self.tmp, "genhint-%s.jsonl" % tag)
        j = LiveJournal(jpath)
        t = LiveTick(config, FixtureDiscovery(scenario), self._ReusedHealthGates(),
                     DryRunActuator(j), j, state=state)
        t.run()
        return events(jpath) if os.path.exists(jpath) else []

    def test_hint_fires_when_cached_generation_predates_current_config(self):
        state_dir = os.path.join(self.tmp, "state-genhint-a")
        os.makedirs(state_dir)
        state = LiveState(state_dir)
        cand_dict = {"pr": 900, "sha": "sha-old", "slug": "feat-gen", "agent_status": "idle"}
        cand = LiveCandidate.from_dict(cand_dict)

        # Plant a cache entry as if it were collected under an OLDER config (REFIX_MAX_ROUNDS=3).
        old_gen = D.gate_config_generation({"REFIX_MAX_ROUNDS": "3"})
        state.record_health_result(cand, "CODEERROR", "not ok 1 - foo.bats")
        state.record_health_generation(cand, old_gen)

        # This tick runs under a DIFFERENT config (REFIX_MAX_ROUNDS=5) — the operator changed posture
        # since the red was cached — and the gates stub reports it as a REUSED cache hit.
        new_config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "5"}
        self.assertNotEqual(old_gen, D.gate_config_generation(new_config))
        evs = self._run(cand_dict, new_config, state, "a")
        hint_rows = [e for e in evs if e["event"] == "health_gate_config_stale"]
        self.assertEqual(len(hint_rows), 1)
        self.assertEqual(hint_rows[0]["pr"], 900)
        self.assertIn("cached verdict predates gate config", hint_rows[0]["detail"])
        self.assertIn("new sha required", hint_rows[0]["detail"])

    def test_no_hint_when_cached_generation_matches_current_config(self):
        state_dir = os.path.join(self.tmp, "state-genhint-b")
        os.makedirs(state_dir)
        state = LiveState(state_dir)
        cand_dict = {"pr": 901, "sha": "sha-same", "slug": "feat-gen2", "agent_status": "idle"}
        cand = LiveCandidate.from_dict(cand_dict)

        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3"}
        gen = D.gate_config_generation(config)
        state.record_health_result(cand, "CODEERROR", "not ok 1 - foo.bats")
        state.record_health_generation(cand, gen)

        evs = self._run(cand_dict, config, state, "b")
        self.assertFalse([e for e in evs if e["event"] == "health_gate_config_stale"],
                         "an unchanged gate config must never render the hint")

    def test_no_hint_when_no_generation_was_ever_recorded(self):
        # A cache written before this feature existed (or a store-backend pool) carries no generation
        # stamp — fail-soft: silence, never a false "predates config" flag with nothing to compare to.
        state_dir = os.path.join(self.tmp, "state-genhint-c")
        os.makedirs(state_dir)
        state = LiveState(state_dir)
        cand_dict = {"pr": 902, "sha": "sha-legacy", "slug": "feat-gen3", "agent_status": "idle"}
        cand = LiveCandidate.from_dict(cand_dict)
        state.record_health_result(cand, "CODEERROR", "not ok 1 - foo.bats")   # no generation stamped

        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3"}
        evs = self._run(cand_dict, config, state, "c")
        self.assertFalse([e for e in evs if e["event"] == "health_gate_config_stale"])

    def test_fresh_collect_never_hints_same_tick(self):
        # LiveGates.health()'s REAL collect path stamps the CURRENT generation the same instant it
        # caches the verdict — the hint's non-reused guard means a genuinely fresh red never
        # self-flags. Exercised directly against the real LiveGates (not the stub above).
        state_dir = os.path.join(self.tmp, "state-genhint-fresh")
        os.makedirs(state_dir)
        state = LiveState(state_dir)
        cand = LiveCandidate(5, "deadbeef", slug="feat-fresh")
        _marker_write(state.health_inflight_file(cand), os.getpid(), nonce="n-live")
        with open(state.health_dispatch_file(cand), "w", encoding="utf-8") as fh:
            fh.write("n-live\tCODEERROR\tnot ok 1 - foo.bats\n")
        journal = LiveJournal(os.path.join(self.tmp, "fresh.jsonl"))
        gates = LiveGates("/nonexistent-home", state, journal, config={"REFIX_MAX_ROUNDS": "3"})
        self.assertEqual(gates.health(cand), "CODEERROR")
        self.assertFalse(gates.reused_health)
        self.assertEqual(state.health_cached_generation(cand),
                         D.gate_config_generation({"REFIX_MAX_ROUNDS": "3"}))


class TestTransitionDedupe(LiveCase):
    """HERD-459 (GH #573): the watcher must journal a lifecycle transition when it CHANGES, not once
    per poll tick that re-derives the same cached conclusion.

    ``LiveTick._state`` is in-memory and a LiveTick lives exactly one tick, so every ~6s tick re-walks
    a still-open candidate from INTAKE and replays the identical chain of edges — measured at ~88k
    events/day from ONE idle blocked PR, which buries the real history `herd why` exists to show and
    ages it out through JOURNAL_MAX_MB rotation. The guard is a reconciled once-marker keyed by
    (pr, sha, from, to, trigger, re-entry generation), so every GENUINE change still journals."""

    def _tick(self, cand, config, state_dir, tag):
        """One fresh tick (its own LiveTick + journal) over ``cand``, against a SHARED durable state
        dir — the process boundary is the whole point: an in-memory dedupe would not survive it."""
        scenario = {"candidates": [cand], "config": config}
        jpath = os.path.join(self.tmp, "dedupe-%s.jsonl" % tag)
        j = LiveJournal(jpath)
        t = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario),
                     DryRunActuator(j), j, state=LiveState(state_dir))
        t.run()
        return events(jpath) if os.path.exists(jpath) else []

    @staticmethod
    def _chain(evs):
        return [(o["state_from"], o["state_to"], o["trigger"])
                for o in evs if o["event"] == "live_state"]

    def _state_dir(self, name):
        d = os.path.join(self.tmp, name)
        os.makedirs(d)
        return d

    # A parked PR: gates green, held for human verify under auto — the shape that sits for hours
    # re-deriving the same chain off cached verdicts, with no bounce to re-arm anything.
    _PARKED = dict(pr=12, sha="75068de0", slug="feat-parked",
                   health="CLEAN", review="PASS", hv_hold=True)
    _CONFIG = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "5"}

    def test_n_identical_ticks_journal_exactly_one_chain(self):
        state_dir = self._state_dir("identical")
        chains = [self._chain(self._tick(dict(self._PARKED), self._CONFIG, state_dir, i))
                  for i in range(20)]
        self.assertEqual(chains[0],
                         [("INTAKE", "HEALTH", "dispatch_health"),
                          ("HEALTH", "REVIEW", "health_clean"),
                          ("REVIEW", "BLESSED", "review_pass"),
                          ("BLESSED", "HOLD", "decide_hold")],
                         "the FIRST tick must journal the whole chain, unchanged")
        for i, c in enumerate(chains[1:], 1):
            self.assertEqual(c, [], "tick %d re-journaled an unchanged chain: %s" % (i, c))

    def test_a_new_sha_re_journals_the_whole_chain(self):
        state_dir = self._state_dir("new-sha")
        first = self._chain(self._tick(dict(self._PARKED), self._CONFIG, state_dir, "a"))
        again = self._chain(self._tick(dict(self._PARKED), self._CONFIG, state_dir, "b"))
        pushed = dict(self._PARKED, sha="9c1f77aa")
        after = self._chain(self._tick(pushed, self._CONFIG, state_dir, "c"))
        self.assertEqual(len(first), 4)
        self.assertEqual(again, [], "the unchanged re-walk must stay silent")
        self.assertEqual(after, first, "a new head sha is a genuine re-entry — journal it in full")

    def test_a_refix_bounce_re_journals_the_chain_once(self):
        # A review BLOCK bounces the builder; the sha has NOT moved, but the re-dispatch is a genuine
        # re-entry the operator must see, so the NEXT tick journals the chain again — exactly once.
        # Further identical ticks (the once-guard holds the bounce) go quiet again.
        state_dir = self._state_dir("bounce")
        cand = dict(pr=13, sha="c0ffee11", slug="feat-bounced", health="CLEAN", review="BLOCK")
        chains = [self._chain(self._tick(dict(cand), self._CONFIG, state_dir, "b%d" % i))
                  for i in range(5)]
        expected = [("INTAKE", "HEALTH", "dispatch_health"),
                    ("HEALTH", "REVIEW", "health_clean"),
                    ("REVIEW", "BLOCKED", "review_block")]
        self.assertEqual(chains[0], expected, "the bouncing tick journals its chain")
        self.assertEqual(chains[1], expected,
                         "the tick AFTER a bounce is a re-entry and must re-journal")
        for i, c in enumerate(chains[2:], 2):
            self.assertEqual(c, [], "tick %d re-journaled with no new bounce: %s" % (i, c))

    def test_no_state_dir_never_suppresses(self):
        # Every sim / fixture / dry-run tick runs with no durable state dir (LiveState(None)) — the
        # once-guard always proceeds there, so those journals are BYTE-IDENTICAL to before HERD-459.
        # TREES/WORKTREES_DIR are scrubbed because LiveState(None) falls back to them, and a
        # watcher- or gate-wrapper-descended environment exports one (tests/test-py-live-runtime.sh
        # runs this suite with WORKTREES_DIR set) — which would hand this "stateless" tick a real
        # ledger and make the assertion read the opposite invariant.
        with mock.patch.dict(os.environ, {}, clear=False):
            for k in ("TREES", "WORKTREES_DIR"):
                os.environ.pop(k, None)
            self.assertIsNone(LiveState(None).dir, "the fixture column must have no state dir")
            chains = [self._chain(self._tick(dict(self._PARKED), self._CONFIG, None, "sim%d" % i))
                      for i in range(3)]
        self.assertEqual([len(c) for c in chains], [4, 4, 4],
                         "a stateless tick must journal every transition, exactly as before")

    def test_a_different_trigger_on_the_same_edge_still_journals(self):
        # BLESSED→HOLD is reached by four DISTINCT triggers (merge_frozen / queue_wait /
        # cross_seat_block / decide_hold) and which one fired is the forensic bit `herd why` is read
        # for — so the trigger is part of the dedupe key, and a second cause is never swallowed.
        state_dir = self._state_dir("triggers")
        jpath = os.path.join(self.tmp, "dedupe-triggers.jsonl")
        j = LiveJournal(jpath)
        scenario = {"candidates": [], "config": self._CONFIG}
        t = LiveTick(self._CONFIG, FixtureDiscovery(scenario), FixtureGates(scenario),
                     DryRunActuator(j), j, state=LiveState(state_dir))
        cand = LiveCandidate(pr=14, sha="deadbeef", slug="feat-edges")
        t._state[cand.pr] = "BLESSED"
        t._advance(cand, "decide_hold")
        t._state[cand.pr] = "BLESSED"
        t._advance(cand, "decide_hold")          # the SAME cause again — suppressed
        t._state[cand.pr] = "BLESSED"
        t._advance(cand, "cross_seat_block")     # a DIFFERENT cause, same edge — journaled
        triggers = [o["trigger"] for o in events(jpath) if o["event"] == "live_state"]
        self.assertEqual(triggers, ["decide_hold", "cross_seat_block"])

    def test_health_pending_is_journaled_once_per_sha(self):
        # "still waiting on the suite" is a PHASE, not a per-tick event (GH #573: live_tick_start /
        # live_tick_end already carry per-tick liveness).
        state_dir = self._state_dir("pending")
        cand = dict(pr=15, sha="ab12cd34", slug="feat-waiting", health=WAIT)
        pend = 0
        for i in range(6):
            pend += sum(1 for o in self._tick(dict(cand), self._CONFIG, state_dir, "p%d" % i)
                        if o["event"] == "health_pending")
        self.assertEqual(pend, 1, "6 ticks on one in-flight suite must journal 1 health_pending")
        pushed = dict(cand, sha="ef56ab78")
        after = sum(1 for o in self._tick(pushed, self._CONFIG, state_dir, "p-new")
                    if o["event"] == "health_pending")
        self.assertEqual(after, 1, "a new sha re-arms the phase marker")


class TestInfraBreakerGate(LiveCase):
    """HERD-447: HERD-306's P5b deleted the bash action pass (_tick_act) that consulted
    ``_breaker_gate`` at the top of every candidate — the HERD-442 audit found the breaker's READ
    side had had no caller since ede7d45, so it kept recording consecutive infra deaths but never
    actually halted dispatch (a valve that records and never fires). This proves BOTH halves restored
    in the PYTHON tick, driven end-to-end through :meth:`LiveTick.run` — never the bash helpers
    directly (those are proven separately, unchanged, by tests/test-infra-breaker.sh):

      * the READ (the breaker consult at the top of ``LiveTick._walk``) actually SUPPRESSES dispatch
        while open — the mutation-provable core: delete that consult and
        ``test_open_breaker_suppresses_dispatch_entirely`` goes from HOLD/no-events to MERGE.
      * the RECORD side (the review rail's verdict classification in the same walk) counts a real
        INFRA death and resets on a real verdict, exactly like bash's ``_review_gate_step``.
      * BYTE-INERT by default (``INFRA_BREAKER_MAX`` unset) — every existing gate-outcome test above
        already proves this implicitly (none of them set the key and all still pass), so this class
        adds one direct proof rather than repeating the whole suite.

    Every test drives independent ``LiveTick`` instances sharing one on-disk state dir (the
    ``TestGateOutcomes.test_refix_round_advances_per_new_sha`` / ``TestRefixCompletionTracking``
    multi-tick pattern — a fresh ``LiveTick`` per tick is the real production process-boundary
    shape) with ``HERD_FAKE_NOW`` pinned per call, so the cooldown arithmetic is exact and hermetic.
    """

    def _tick(self, state_dir, jpath, cands, config, fake_now):
        old = os.environ.get("HERD_FAKE_NOW")
        os.environ["HERD_FAKE_NOW"] = str(fake_now)
        try:
            scenario = {"candidates": cands, "config": config}
            j = LiveJournal(jpath)
            t = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario),
                        DryRunActuator(j), j, state=LiveState(state_dir))
            res = t.run()
        finally:
            if old is None:
                os.environ.pop("HERD_FAKE_NOW", None)
            else:
                os.environ["HERD_FAKE_NOW"] = old
        return res, (events(jpath) if os.path.exists(jpath) else [])

    def _death(self, pr, i):
        return dict(pr=pr, sha="sha-%s-%d" % (pr, i), slug="feat-%s" % pr, review="INFRA",
                   health="CLEAN")

    def _ledger(self, state_dir):
        path = os.path.join(state_dir, ".agent-watch-infra-breaker")
        if not os.path.exists(path):
            return None
        with open(path, encoding="utf-8") as fh:
            return fh.readline().split()

    def test_byte_inert_when_disabled(self):
        # No INFRA_BREAKER_MAX at all: a storm of consecutive INFRA deaths across many ticks must
        # never suppress a later, unrelated clean candidate and must never write a breaker ledger.
        state_dir = os.path.join(self.tmp, "state-off")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto"}
        T0 = 3_000_000_000
        for i in range(6):
            res, _ = self._tick(state_dir, os.path.join(self.tmp, "off-%d.jsonl" % i),
                                [self._death(900, i)], config, T0 + i)
            self.assertEqual(res["outcomes"]["900"], "ESCALATE")
        self.assertIsNone(self._ledger(state_dir))
        res, _ = self._tick(state_dir, os.path.join(self.tmp, "off-clean.jsonl"),
                            [dict(pr=901, sha="s901", slug="feat-901", review="PASS", health="CLEAN")],
                            config, T0 + 100)
        self.assertEqual(res["outcomes"]["901"], "MERGE")

    def test_opens_after_n_consecutive_deaths_and_journals_once(self):
        state_dir = os.path.join(self.tmp, "state-open")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "INFRA_BREAKER_MAX": "3", "INFRA_BREAKER_COOLDOWN": "300"}
        T0 = 3_000_000_000
        opens = []
        for i in range(3):
            res, ev = self._tick(state_dir, os.path.join(self.tmp, "open-%d.jsonl" % i),
                                 [self._death(910, i)], config, T0 + i)
            self.assertEqual(res["outcomes"]["910"], "ESCALATE")
            opens += [o for o in ev if o["event"] == "infra_breaker_open"]
        self.assertEqual(len(opens), 1)
        st, fa, _op, _pb = self._ledger(state_dir)
        self.assertEqual(st, "open")
        self.assertEqual(fa, "3")

    def test_open_breaker_suppresses_dispatch_entirely(self):
        # THE mutation-provable core: once open, an otherwise-clean candidate is HELD with NO rail
        # ever consulted — no verdict_recorded, no healthcheck_outcome, no review/health dispatch at
        # all. Delete the breaker consult at the top of LiveTick._walk and this candidate merges
        # instead — see the PR body for the neutralize/red/restore/green demonstration.
        state_dir = os.path.join(self.tmp, "state-suppress")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "INFRA_BREAKER_MAX": "2", "INFRA_BREAKER_COOLDOWN": "300"}
        T0 = 3_000_000_000
        for i in range(2):
            self._tick(state_dir, os.path.join(self.tmp, "trip-%d.jsonl" % i), [self._death(915, i)],
                      config, T0 + i)
        res, ev = self._tick(state_dir, os.path.join(self.tmp, "blocked.jsonl"),
                             [dict(pr=916, sha="s916", slug="feat-916", review="PASS", health="CLEAN")],
                             config, T0 + 5)
        self.assertEqual(res["outcomes"]["916"], "HOLD")
        self.assertFalse([o for o in ev
                          if o["event"] in ("verdict_recorded", "healthcheck_outcome",
                                             "healthcheck_started", "review_dispatched")])
        # A sibling gets the SAME treatment — the halt is global, not per-PR.
        res2, ev2 = self._tick(state_dir, os.path.join(self.tmp, "blocked2.jsonl"),
                              [dict(pr=917, sha="s917", slug="feat-917", review="PASS", health="CLEAN")],
                              config, T0 + 6)
        self.assertEqual(res2["outcomes"]["917"], "HOLD")
        self.assertFalse([o for o in ev2 if o["event"] == "verdict_recorded"])

    def test_real_verdict_resets_counter_and_never_trips(self):
        state_dir = os.path.join(self.tmp, "state-reset")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "INFRA_BREAKER_MAX": "3", "INFRA_BREAKER_COOLDOWN": "300"}
        T0 = 3_000_000_000
        # Two deaths (below threshold)...
        for i in range(2):
            self._tick(state_dir, os.path.join(self.tmp, "pre-%d.jsonl" % i), [self._death(925, i)],
                      config, T0 + i)
        st, fa, _op, _pb = self._ledger(state_dir)
        self.assertEqual((st, fa), ("closed", "2"))
        # ...then a REAL verdict (PASS) resets the counter to 0 — the env is provably alive.
        res, ev = self._tick(state_dir, os.path.join(self.tmp, "verdict.jsonl"),
                             [dict(pr=925, sha="s925-ok", slug="feat-925", review="PASS",
                                   health="CLEAN")], config, T0 + 10)
        self.assertEqual(res["outcomes"]["925"], "MERGE")
        st, fa, _op, _pb = self._ledger(state_dir)
        self.assertEqual((st, fa), ("closed", "0"))
        # Two MORE deaths after the reset must NOT open it (would have, without the reset).
        for i in range(2):
            res, _ = self._tick(state_dir, os.path.join(self.tmp, "post-%d.jsonl" % i),
                                [self._death(925, 100 + i)], config, T0 + 20 + i)
            self.assertEqual(res["outcomes"]["925"], "ESCALATE")
        st, _fa, _op, _pb = self._ledger(state_dir)
        self.assertEqual(st, "closed")

    def test_half_open_admits_exactly_one_probe_and_it_persists_the_claim(self):
        state_dir = os.path.join(self.tmp, "state-half")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "INFRA_BREAKER_MAX": "2", "INFRA_BREAKER_COOLDOWN": "50"}
        T0 = 3_000_000_000
        for i in range(2):
            self._tick(state_dir, os.path.join(self.tmp, "trip-%d.jsonl" % i), [self._death(930, i)],
                      config, T0 + i)
        # cooldown not yet elapsed (opened at T0+1; 49s later is 50-1=49 < 50) — still BLOCKED.
        res, _ = self._tick(state_dir, os.path.join(self.tmp, "cooling.jsonl"),
                            [dict(pr=931, sha="s931a", slug="f931", review="PASS", health="CLEAN")],
                            config, T0 + 49)
        self.assertEqual(res["outcomes"]["931"], "HOLD")
        # cooldown elapsed: TWO siblings walked the SAME tick, neither resolving (WAIT) — only the
        # FIRST claims the probe; the second, walked after, is still BLOCKED (the claim is exclusive
        # even within one tick, not just across ticks).
        res, _ = self._tick(state_dir, os.path.join(self.tmp, "probe.jsonl"),
                            [dict(pr=931, sha="s931b", slug="f931", review="WAIT"),
                             dict(pr=932, sha="s932a", slug="f932", review="WAIT")],
                            config, T0 + 60)
        self.assertEqual(res["outcomes"]["931"], "PENDING")
        self.assertEqual(res["outcomes"]["932"], "HOLD")
        _st, _fa, _op, pb = self._ledger(state_dir)
        self.assertEqual(pb, "931")
        # The claim PERSISTS across ticks for the SAME probe PR (still unresolved) — 932 stays BLOCKED.
        res, _ = self._tick(state_dir, os.path.join(self.tmp, "probe2.jsonl"),
                            [dict(pr=931, sha="s931b", slug="f931", review="WAIT"),
                             dict(pr=932, sha="s932a", slug="f932", review="WAIT")],
                            config, T0 + 61)
        self.assertEqual(res["outcomes"]["931"], "PENDING")
        self.assertEqual(res["outcomes"]["932"], "HOLD")

    def test_probe_success_closes_and_resumes_normal_dispatch(self):
        state_dir = os.path.join(self.tmp, "state-close")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "INFRA_BREAKER_MAX": "2", "INFRA_BREAKER_COOLDOWN": "50"}
        T0 = 3_000_000_000
        for i in range(2):
            self._tick(state_dir, os.path.join(self.tmp, "trip-%d.jsonl" % i), [self._death(940, i)],
                      config, T0 + i)
        res, ev = self._tick(state_dir, os.path.join(self.tmp, "probe.jsonl"),
                             [dict(pr=941, sha="s941", slug="f941", review="PASS", health="CLEAN")],
                             config, T0 + 60)
        self.assertEqual(res["outcomes"]["941"], "MERGE")
        self.assertTrue([o for o in ev if o["event"] == "infra_breaker_close"])
        st, fa, _op, pb = self._ledger(state_dir)
        self.assertEqual((st, fa, pb), ("closed", "0", "-"))
        # Dispatch resumes for EVERYONE, immediately, no further cooldown wait.
        res2, _ = self._tick(state_dir, os.path.join(self.tmp, "resumed.jsonl"),
                             [dict(pr=942, sha="s942", slug="f942", review="PASS", health="CLEAN")],
                             config, T0 + 61)
        self.assertEqual(res2["outcomes"]["942"], "MERGE")

    def test_probe_failure_reopens_with_fresh_cooldown(self):
        state_dir = os.path.join(self.tmp, "state-reopen")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "INFRA_BREAKER_MAX": "2", "INFRA_BREAKER_COOLDOWN": "50"}
        T0 = 3_000_000_000
        for i in range(2):
            self._tick(state_dir, os.path.join(self.tmp, "trip-%d.jsonl" % i), [self._death(950, i)],
                      config, T0 + i)
        res, ev = self._tick(state_dir, os.path.join(self.tmp, "probe.jsonl"),
                             [self._death(950, 900)], config, T0 + 60)
        self.assertEqual(res["outcomes"]["950"], "ESCALATE")
        self.assertTrue([o for o in ev if o["event"] == "infra_breaker_reopen"])
        st, _fa, op, _pb = self._ledger(state_dir)
        self.assertEqual(st, "open")
        self.assertEqual(op, str(T0 + 60))   # opened stamped at THIS tick's HERD_FAKE_NOW
        # Immediately after the re-open (fresh cooldown), everyone is BLOCKED again — no probe yet.
        res2, _ = self._tick(state_dir, os.path.join(self.tmp, "reblocked.jsonl"),
                             [dict(pr=951, sha="s951", slug="f951", review="PASS", health="CLEAN")],
                             config, T0 + 61)
        self.assertEqual(res2["outcomes"]["951"], "HOLD")


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


class TestRefixCompletionTracking(LiveCase):
    """HERD-420: a refix_wake_result woke=1 only proves the agent's pane came back to "working" —
    NOT that it committed or pushed anything. Live incident: PR #531 — a review-BLOCK bounced the
    builder, it edited bin/herd, then went back to "done" with the edit never committed or pushed;
    the sha-keyed once-guard held silently forever and the PR sat blocked on the same sha
    indefinitely, caught only because a human happened to look.

    Every test drives independent LiveTick instances sharing one on-disk state dir (the multi-tick
    pattern TestGateOutcomes.test_refix_round_advances_per_new_sha already establishes — a fresh
    LiveTick per tick is the production process-boundary shape) with HERD_FAKE_NOW pinned per call,
    so the completion window's elapsed-time arithmetic is exact and hermetic (no real sleeping)."""

    def _tick(self, state_dir, jpath, cand, config, fake_now, actuator_cls=DryRunActuator):
        old = os.environ.get("HERD_FAKE_NOW")
        os.environ["HERD_FAKE_NOW"] = str(fake_now)
        try:
            scenario = {"candidates": [cand], "config": config}
            j = LiveJournal(jpath)
            act = actuator_cls(j)
            t = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario), act, j,
                        state=LiveState(state_dir))
            res = t.run()
        finally:
            if old is None:
                os.environ.pop("HERD_FAKE_NOW", None)
            else:
                os.environ["HERD_FAKE_NOW"] = old
        return res, (events(jpath) if os.path.exists(jpath) else []), act

    def test_window_not_yet_elapsed_holds_silently(self):
        state_dir = os.path.join(self.tmp, "state-window")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3", "REFIX_COMPLETE_MIN": "10"}
        T0 = 2_000_000_000
        pr, sha, slug = 531, "sha-531", "feat-531"

        cand = {"pr": pr, "sha": sha, "slug": slug, "health": "CODEERROR", "agent_status": "idle"}
        res1, ev1, _ = self._tick(state_dir, os.path.join(self.tmp, "w1.jsonl"), cand, config, T0)
        self.assertEqual(res1["outcomes"][str(pr)], "BLOCK")
        rb1 = [o for o in ev1 if o["event"] == "refix_bounce"]
        self.assertEqual(rb1[0]["round"], 1)

        cand_done = {"pr": pr, "sha": sha, "slug": slug, "health": "CODEERROR",
                     "agent_status": "done"}
        res2, ev2, _ = self._tick(state_dir, os.path.join(self.tmp, "w2.jsonl"), cand_done, config,
                                  T0 + 9 * 60)   # 9 minutes < REFIX_COMPLETE_MIN=10
        self.assertEqual(res2["outcomes"][str(pr)], "BLOCK")
        self.assertFalse([o for o in ev2 if o["event"] == "refix_incomplete"])
        self.assertFalse([o for o in ev2 if o["event"] == "refix_bounce"])

    def test_incomplete_after_window_rebounces_then_escalates_on_budget_exhaustion(self):
        state_dir = os.path.join(self.tmp, "state-completion")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "2", "REFIX_COMPLETE_MIN": "10"}
        T0 = 2_000_000_000
        pr, sha, slug = 531, "sha-531", "feat-531"

        # tick 1: health CODEERROR, idle builder wakes — round 1 bounce recorded.
        cand = {"pr": pr, "sha": sha, "slug": slug, "health": "CODEERROR", "agent_status": "idle"}
        res1, ev1, _ = self._tick(state_dir, os.path.join(self.tmp, "c1.jsonl"), cand, config, T0)
        self.assertEqual(res1["outcomes"][str(pr)], "BLOCK")
        self.assertEqual([o for o in ev1 if o["event"] == "refix_bounce"][0]["round"], 1)

        # tick 2 (+10 min, window elapsed): SAME sha, builder now reads "done" — INCOMPLETE: journal
        # refix_incomplete for round 1, then spend round 2 of the SAME rail's budget.
        cand_done = {"pr": pr, "sha": sha, "slug": slug, "health": "CODEERROR",
                     "agent_status": "done"}
        res2, ev2, _ = self._tick(state_dir, os.path.join(self.tmp, "c2.jsonl"), cand_done, config,
                                  T0 + 10 * 60)
        self.assertEqual(res2["outcomes"][str(pr)], "BLOCK")
        inc2 = [o for o in ev2 if o["event"] == "refix_incomplete"]
        self.assertEqual(len(inc2), 1)
        self.assertEqual(inc2[0]["pr"], pr)
        self.assertEqual(inc2[0]["sha"], sha)
        self.assertEqual(inc2[0]["kind"], "health")
        self.assertEqual(inc2[0]["round"], 1)
        self.assertEqual(inc2[0]["agent_status"], "done")
        self.assertEqual(inc2[0]["dirty"], "no")
        rb2 = [o for o in ev2 if o["event"] == "refix_bounce"]
        self.assertEqual(len(rb2), 1)
        self.assertEqual(rb2[0]["round"], 2)
        wr2 = [o for o in ev2 if o["event"] == "refix_wake_result"]
        self.assertEqual(len(wr2), 1)
        self.assertEqual(wr2[0]["woke"], 1)

        # tick 3 (+another 10 min, same sha, still "done"): the rail's budget (cap=2) is now
        # exhausted — escalate through the SAME needs-you path a normal BLOCK exhaustion uses,
        # never a third bounce.
        res3, ev3, _ = self._tick(state_dir, os.path.join(self.tmp, "c3.jsonl"), cand_done, config,
                                  T0 + 20 * 60)
        self.assertEqual(res3["outcomes"][str(pr)], "ESCALATE")
        inc3 = [o for o in ev3 if o["event"] == "refix_incomplete"]
        self.assertEqual(len(inc3), 1)
        self.assertEqual(inc3[0]["round"], 2)
        self.assertFalse([o for o in ev3 if o["event"] == "refix_bounce"],
                         "budget exhausted — no third bounce")
        esc3 = [o for o in ev3 if o["event"] == "health_refix_escalated"]
        self.assertEqual(len(esc3), 1)

    def test_review_rail_also_tracked_with_its_own_finish_prompt(self):
        state_dir = os.path.join(self.tmp, "state-review-completion")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3", "REFIX_COMPLETE_MIN": "10"}
        T0 = 2_100_000_000
        pr, sha, slug = 532, "sha-532", "feat-532"

        cand = {"pr": pr, "sha": sha, "slug": slug, "review": "BLOCK", "health": "CLEAN",
                "agent_status": "idle"}
        _, ev1, act1 = self._tick(state_dir, os.path.join(self.tmp, "r1.jsonl"), cand, config, T0,
                                  actuator_cls=_PromptRecordingActuator)
        self.assertEqual(len(act1.prompts), 1)
        self.assertIn("review-blocked", act1.prompts[0])

        cand_done = {"pr": pr, "sha": sha, "slug": slug, "review": "BLOCK", "health": "CLEAN",
                     "agent_status": "done"}
        res2, ev2, act2 = self._tick(state_dir, os.path.join(self.tmp, "r2.jsonl"), cand_done,
                                     config, T0 + 10 * 60, actuator_cls=_PromptRecordingActuator)
        self.assertEqual(res2["outcomes"][str(pr)], "BLOCK")
        inc2 = [o for o in ev2 if o["event"] == "refix_incomplete"]
        self.assertEqual(len(inc2), 1)
        self.assertEqual(inc2[0]["kind"], "review")
        rb2 = [o for o in ev2 if o["event"] == "refix_bounce" and o.get("rule") == "review"]
        self.assertEqual(len(rb2), 1)
        # the completion nudge is a DIFFERENT prompt from the original review-BLOCK bounce — it
        # tells the builder its wake did not ship anything, not the original review findings.
        self.assertEqual(len(act2.prompts), 1)
        self.assertIn("finish it now", act2.prompts[0])
        self.assertNotIn("Read the full review", act2.prompts[0])

    def test_dirty_worktree_recorded_on_the_incomplete_event(self):
        state_dir = os.path.join(self.tmp, "state-dirty")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3", "REFIX_COMPLETE_MIN": "10"}
        T0 = 2_200_000_000
        pr, sha, slug = 533, "sha-533", "feat-533"

        cand = {"pr": pr, "sha": sha, "slug": slug, "health": "CODEERROR", "agent_status": "idle"}
        self._tick(state_dir, os.path.join(self.tmp, "d1.jsonl"), cand, config, T0)

        cand_done = {"pr": pr, "sha": sha, "slug": slug, "health": "CODEERROR",
                     "agent_status": "done", "dirty": True}
        _, ev, _ = self._tick(state_dir, os.path.join(self.tmp, "d2.jsonl"), cand_done, config,
                              T0 + 10 * 60)
        inc = [o for o in ev if o["event"] == "refix_incomplete"]
        self.assertEqual(inc[0]["dirty"], "yes")

    def test_still_working_never_triggers_completion(self):
        # The agent may just be slow, not silently done-without-shipping — only an observed
        # done/idle after the window elapses is evidence of an incomplete round.
        state_dir = os.path.join(self.tmp, "state-working")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3", "REFIX_COMPLETE_MIN": "10"}
        T0 = 2_300_000_000
        pr, sha, slug = 534, "sha-534", "feat-534"

        cand = {"pr": pr, "sha": sha, "slug": slug, "health": "CODEERROR", "agent_status": "idle"}
        self._tick(state_dir, os.path.join(self.tmp, "wk1.jsonl"), cand, config, T0)

        cand_working = {"pr": pr, "sha": sha, "slug": slug, "health": "CODEERROR",
                        "agent_status": "working"}
        res, ev, _ = self._tick(state_dir, os.path.join(self.tmp, "wk2.jsonl"), cand_working,
                                config, T0 + 60 * 60)
        self.assertEqual(res["outcomes"][str(pr)], "BLOCK")
        self.assertFalse([o for o in ev if o["event"] == "refix_incomplete"])

    def test_normal_push_never_triggers_completion(self):
        # A builder that pushes a real fix opens a NEW sha — the once-guard for that sha was never
        # attempted, so the walk takes the ordinary fresh-gate path, never the completion leg, no
        # matter how much time has passed since the earlier sha's bounce.
        state_dir = os.path.join(self.tmp, "state-pushed")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3", "REFIX_COMPLETE_MIN": "10"}
        T0 = 2_400_000_000
        pr, slug = 535, "feat-535"

        cand1 = {"pr": pr, "sha": "sha-a", "slug": slug, "health": "CODEERROR",
                 "agent_status": "idle"}
        self._tick(state_dir, os.path.join(self.tmp, "p1.jsonl"), cand1, config, T0)

        cand2 = {"pr": pr, "sha": "sha-b", "slug": slug, "health": "CLEAN", "review": "PASS"}
        res2, ev2, _ = self._tick(state_dir, os.path.join(self.tmp, "p2.jsonl"), cand2, config,
                                  T0 + 30 * 60)
        self.assertEqual(res2["outcomes"][str(pr)], "MERGE")
        self.assertFalse([o for o in ev2 if o["event"] == "refix_incomplete"])

    def test_disabled_by_zero_never_fires_byte_identical(self):
        state_dir = os.path.join(self.tmp, "state-off")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3", "REFIX_COMPLETE_MIN": "0"}
        T0 = 2_500_000_000
        pr, sha, slug = 536, "sha-536", "feat-536"

        cand = {"pr": pr, "sha": sha, "slug": slug, "review": "BLOCK", "health": "CLEAN",
                "agent_status": "idle"}
        self._tick(state_dir, os.path.join(self.tmp, "o1.jsonl"), cand, config, T0)

        cand_done = {"pr": pr, "sha": sha, "slug": slug, "review": "BLOCK", "health": "CLEAN",
                     "agent_status": "done"}
        res2, ev2, _ = self._tick(state_dir, os.path.join(self.tmp, "o2.jsonl"), cand_done, config,
                                  T0 + 24 * 60 * 60)   # a full day later — still never fires
        self.assertEqual(res2["outcomes"][str(pr)], "BLOCK")
        self.assertFalse([o for o in ev2 if o["event"] == "refix_incomplete"])
        self.assertFalse([o for o in ev2 if o["event"] == "refix_bounce"])

    def test_default_is_ten_minutes_when_unset(self):
        state_dir = os.path.join(self.tmp, "state-default")
        os.makedirs(state_dir)
        config = {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3"}   # REFIX_COMPLETE_MIN unset
        T0 = 2_600_000_000
        pr, sha, slug = 537, "sha-537", "feat-537"

        cand = {"pr": pr, "sha": sha, "slug": slug, "health": "CODEERROR", "agent_status": "idle"}
        self._tick(state_dir, os.path.join(self.tmp, "def1.jsonl"), cand, config, T0)

        cand_done = {"pr": pr, "sha": sha, "slug": slug, "health": "CODEERROR",
                     "agent_status": "done"}
        _, ev_early, _ = self._tick(state_dir, os.path.join(self.tmp, "def2.jsonl"), cand_done,
                                    config, T0 + 9 * 60)
        self.assertFalse([o for o in ev_early if o["event"] == "refix_incomplete"])

        _, ev_late, _ = self._tick(state_dir, os.path.join(self.tmp, "def3.jsonl"), cand_done,
                                   config, T0 + 10 * 60)
        self.assertTrue([o for o in ev_late if o["event"] == "refix_incomplete"],
                        "unset REFIX_COMPLETE_MIN must default to 10 minutes (ships ON)")


class TestReapAndActuation(LiveCase):
    def test_merge_reaps(self):
        _, ev = self.tick([self.one(1, review="PASS", health="CLEAN", worktree="/wt/1")])
        self.assertTrue([o for o in ev if o["event"] == "merge"])
        reaps = [o for o in ev if o["event"] == "reap"]
        self.assertEqual(len(reaps), 1)
        self.assertEqual(reaps[0]["reason"], "merged")

    def test_merge_defers_reap_when_builder_still_working(self):
        # HERD-444: a candidate whose fixture models a still-WORKING builder must merge (the merge is
        # unconditional and irreversible) but NOT reap — reaping unconditionally the instant the merge
        # lands destroyed a builder's in-progress fix (PR #560, 2026-07-30) because the coordinator can
        # re-task the SAME builder onto a red BEFORE this tick's own merge runs.
        _, ev = self.tick([self.one(1, review="PASS", health="CLEAN", worktree="/wt/1",
                                     agent_status="working")])
        self.assertTrue([o for o in ev if o["event"] == "merge"], "the merge itself must still land")
        self.assertFalse([o for o in ev if o["event"] == "reap"],
                          "a WORKING builder's worktree must not be reaped on the merge tick")
        deferred = [o for o in ev if o["event"] == "reap_deferred"]
        self.assertEqual(len(deferred), 1)
        self.assertEqual(deferred[0]["reason"], "merged-worktree-live")

    def test_merge_defers_reap_when_worktree_dirty(self):
        # Same defer, but for the OTHER unsafe condition: real uncommitted work, whether or not a
        # builder is currently reporting "working" (a paused/crashed agent leaves edits behind too).
        _, ev = self.tick([self.one(1, review="PASS", health="CLEAN", worktree="/wt/1", dirty=True)])
        self.assertTrue([o for o in ev if o["event"] == "merge"])
        self.assertFalse([o for o in ev if o["event"] == "reap"],
                          "a dirty worktree must not be reaped on the merge tick")
        self.assertTrue([o for o in ev if o["event"] == "reap_deferred"])

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

    def __init__(self, stdout="", returncode=0):
        self.stdout = stdout
        self.returncode = returncode


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


class _RecordingSubWithRoster(_RecordingSub):
    """HERD-444: extends ``_RecordingSub`` to script ``herdr agent list`` (LiveActuator._agent_lookup)
    and ``git status --porcelain`` (LiveActuator.worktree_dirty) — the two real-subprocess reads the
    reap-liveness guard makes. ``agent_status=""`` (default) reports an empty roster, exactly like a
    genuinely absent/idle agent; ``dirty=True`` scripts one modified TRACKED path."""

    def __init__(self, view_state="MERGED", fail=(), agent_status="", dirty=False):
        super().__init__(view_state=view_state, fail=fail)
        self.agent_status = agent_status
        self.dirty = dirty

    def run(self, argv, *a, **k):
        if argv[:2] == ["herdr", "agent"]:
            self.calls.append(list(argv))
            agents = [{"name": "slug1", "agent_status": self.agent_status}] if self.agent_status else []
            return _FakeCompleted(json.dumps({"result": {"agents": agents}}))
        if argv[:2] == ["git", "-C"] and "status" in argv:
            self.calls.append(list(argv))
            return _FakeCompleted(" M file.txt\n" if self.dirty else "")
        return super().run(argv, *a, **k)


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


class _RosterPaneSub(_RecordingSub):
    """HERD-648: stubs `herdr agent list` (a constant agent_status/pane_id row), `herdr pane read` (a
    scripted sequence of pane-text frames, consumed in call order, empty once exhausted), and `cksum`
    (a deterministic content-keyed stand-in for the real binary — sufficient for these unit tests,
    which only ever compare a python-stubbed read against an earlier python-stubbed write, never a
    bash-written line; TestPaneContentDeltaCksumInterop below is what proves REAL cksum-format
    compatibility with the bash twin) — the reads LiveActuator._status_resolved / _agent_lookup make."""

    def __init__(self, agent_status, pane_texts, pane_id="pane-1", name="slug1"):
        super().__init__()
        self.agent_status = agent_status
        self.pane_texts = list(pane_texts)
        self.pane_id = pane_id
        self.name = name

    def run(self, argv, *a, **k):
        if argv[:2] == ["herdr", "agent"]:
            self.calls.append(list(argv))
            agents = [{"name": self.name, "agent_status": self.agent_status, "pane_id": self.pane_id}]
            return _FakeCompleted(json.dumps({"result": {"agents": agents}}))
        if argv[:3] == ["herdr", "pane", "read"]:
            self.calls.append(list(argv))
            text = self.pane_texts.pop(0) if self.pane_texts else ""
            return _FakeCompleted(text)
        if argv[:1] == ["cksum"]:
            self.calls.append(list(argv))
            text = k.get("input") or ""
            digest = hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()
            return _FakeCompleted("%s %d\n" % (digest, len(text)))
        return super().run(argv, *a, **k)


class TestStatusCorroboratePort(LiveCase):
    """HERD-648: unit coverage for LiveActuator._status_resolved / _agent_lookup, the python port of
    driver.sh's herd_driver_agent_status_resolved (HERD-647) — mirrors tests/test-status-corroborate.sh's
    bash fixtures one for one so the two suites stay provably in sync."""

    ACTIVE = "✳ Cogitating… (esc to interrupt)"
    IDLE_PROMPT = "> "

    def setUp(self):
        super().setUp()
        self.pool = tempfile.mkdtemp()
        self._orig_trees = os.environ.get("WORKTREES_DIR")
        self._orig_TREES = os.environ.get("TREES")
        os.environ["WORKTREES_DIR"] = self.pool
        os.environ.pop("TREES", None)

    def tearDown(self):
        if self._orig_trees is None:
            os.environ.pop("WORKTREES_DIR", None)
        else:
            os.environ["WORKTREES_DIR"] = self._orig_trees
        if self._orig_TREES is not None:
            os.environ["TREES"] = self._orig_TREES
        super().tearDown()

    def _actuator(self, sub):
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        return LiveActuator("/nonexistent-home", LiveJournal(self.jpath))

    def test_non_idle_status_passes_through_with_no_pane_read(self):
        for raw in ("working", "done", "", "parked"):
            sub = _RosterPaneSub(raw, [self.ACTIVE])
            act = self._actuator(sub)
            status, _ = act._agent_lookup("slug1")
            self.assertEqual(status, raw)
            self.assertFalse(any(c[:3] == ["herdr", "pane", "read"] for c in sub.calls))

    def test_idle_active_delta_corroborates_to_working_and_journals(self):
        sub = _RosterPaneSub("idle", [self.ACTIVE + " (frame 1)", self.ACTIVE + " (frame 2)"])
        act = self._actuator(sub)
        first, pane1 = act._agent_lookup("slug1")
        second, _ = act._agent_lookup("slug1")
        self.assertEqual(first, "idle")           # frame 1: chrome present, no prior snapshot -> no delta yet
        self.assertEqual(second, "working")        # frame 2: chrome + real repaint -> corroborated
        ev = [o for o in events(self.jpath) if o["event"] == "status_disagreement"]
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]["slug"], "slug1")
        self.assertEqual(ev[0]["pane"], pane1)
        self.assertEqual(ev[0]["agent_status"], "idle")
        self.assertEqual(ev[0]["resolved"], "working")

    def test_frozen_active_pane_never_corroborates(self):
        # dead/wedge guardrail: a crashed process leaves the spinner frame sitting forever.
        frozen = self.ACTIVE + " (frozen)"
        sub = _RosterPaneSub("idle", [frozen, frozen, frozen])
        act = self._actuator(sub)
        for _ in range(3):
            status, _ = act._agent_lookup("slug1")
            self.assertEqual(status, "idle")
        self.assertFalse(os.path.exists(self.jpath) and events(self.jpath))

    def test_idle_static_prompt_with_delta_but_no_chrome_stays_idle(self):
        sub = _RosterPaneSub("idle", [self.IDLE_PROMPT + " a", self.IDLE_PROMPT + " b"])
        act = self._actuator(sub)
        act._agent_lookup("slug1")
        status, _ = act._agent_lookup("slug1")
        self.assertEqual(status, "idle")
        self.assertFalse(os.path.exists(self.jpath) and events(self.jpath))

    def test_kill_switch_disables_corroboration(self):
        sub = _RosterPaneSub("idle", [self.ACTIVE + " (frame 1)", self.ACTIVE + " (frame 2)"])
        act = self._actuator(sub)
        os.environ["HERD_STATUS_CORROBORATE"] = "off"
        self.addCleanup(lambda: os.environ.pop("HERD_STATUS_CORROBORATE", None))
        act._agent_lookup("slug1")
        status, _ = act._agent_lookup("slug1")
        self.assertEqual(status, "idle")
        self.assertFalse(any(c[:3] == ["herdr", "pane", "read"] for c in sub.calls))

    def test_missing_pane_id_fails_soft_to_raw(self):
        sub = _RosterPaneSub("idle", [self.ACTIVE], pane_id="")
        act = self._actuator(sub)
        status, pane = act._agent_lookup("slug1")
        self.assertEqual(status, "idle")
        self.assertEqual(pane, "")


class TestWakeBuilderCorroboratedNudge(LiveCase):
    """HERD-648 VERIFY: replays the #632 nudge signature end to end through wake_builder — raw
    agent_status stays 'idle' throughout (herdr's own state machine never observes the bare Enter as a
    work-start signal, per HERD-647's root-cause hypothesis), but the pane's own active chrome plus a
    real repaint corroborate a genuine wake, so wake_builder reports woke=True from the FIRST wait poll
    with NO escalation — a single send_wake round, not the doomed second retry."""

    def setUp(self):
        super().setUp()
        self.pool = tempfile.mkdtemp()
        self._orig_trees = os.environ.get("WORKTREES_DIR")
        os.environ["WORKTREES_DIR"] = self.pool
        os.environ.pop("TREES", None)

    def tearDown(self):
        if self._orig_trees is None:
            os.environ.pop("WORKTREES_DIR", None)
        else:
            os.environ["WORKTREES_DIR"] = self._orig_trees
        super().tearDown()

    def test_nudge_signature_wakes_without_escalation(self):
        active = "✳ Cogitating… (esc to interrupt)"
        idle_prompt = "> "
        # pane-read sequence: (1) the pre-wake status_before check sees a genuinely static prompt (no
        # chrome, so the delta store is never primed by it — active_signal gates the store write, same
        # short-circuit the bash original uses); (2) the FIRST poll after send_wake sees the active
        # chrome for the first time (chrome present but nothing to diff against YET, so still 'idle');
        # (3) the SECOND poll sees a real repaint against frame 1's now-stored snapshot -> corroborated.
        sub = _RosterPaneSub("idle", [idle_prompt, active + " (frame 1)", active + " (frame 2)"])
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        act = LiveActuator("/nonexistent-home", LiveJournal(self.jpath))
        cand = LiveCandidate(1, "sha1", slug="slug1", worktree="")
        result = act.wake_builder(cand, "resume please")
        self.assertEqual(result.status_before, "idle")
        self.assertEqual(result.status_after, "working")
        self.assertTrue(result.woke)
        self.assertEqual(len([c for c in sub.calls if c[:3] == ["herdr", "pane", "run"]]), 1)


class TestStatusCorroborateBashPythonParity(unittest.TestCase):
    """HERD-648: per docs/multi-seat-doctrine.md there must not be a THIRD divergent copy of the
    agent_status corroboration decision. driver.sh's herd_driver_agent_status_resolved is the bash
    original; LiveActuator._status_resolved (via TestStatusCorroboratePort above) is this port. THIS
    test runs both implementations over the SAME fixtures and asserts they agree, rather than trusting
    each suite's own isolated assertions to stay in sync by hand."""

    ACTIVE = "✳ Cogitating… (esc to interrupt)"
    IDLE_PROMPT = "> "

    FIXTURES = [
        ("active_then_delta", [ACTIVE + " (frame 1)", ACTIVE + " (frame 2)"], "working"),
        ("active_frozen", [ACTIVE + " (same)", ACTIVE + " (same)"], "idle"),
        ("idle_static", [IDLE_PROMPT, IDLE_PROMPT], "idle"),
        ("idle_changing_no_chrome", [IDLE_PROMPT + " a", IDLE_PROMPT + " b"], "idle"),
    ]

    def setUp(self):
        if shutil.which("bash") is None:
            self.skipTest("bash not on PATH")
        self.driver_sh = os.path.abspath(
            os.path.join(os.path.dirname(__file__), "..", "scripts", "herd", "driver.sh"))
        if not os.path.exists(self.driver_sh):
            self.skipTest("driver.sh not found at %s" % self.driver_sh)

    def _bash_resolve(self, slug, frames):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, True)
        binp = os.path.join(tmp, "bin")
        os.makedirs(binp)
        herdr = os.path.join(binp, "herdr")
        with open(herdr, "w", encoding="utf-8") as fh:
            fh.write(
                "#!/usr/bin/env bash\n"
                'case "$1 $2" in\n'
                '  "pane read") printf \'%s\' "$STUB_PANE_TEXT" ;;\n'
                "  *) exit 0 ;;\n"
                "esac\n"
            )
        os.chmod(herdr, 0o755)
        script = [
            "set -uo pipefail",
            "export PATH=%s:$PATH" % shlex.quote(binp),
            "export WORKTREES_DIR=%s" % shlex.quote(tmp),
            ". %s" % shlex.quote(self.driver_sh),
            "got=idle",
        ]
        for frame in frames:
            script.append("export STUB_PANE_TEXT=%s" % shlex.quote(frame))
            script.append("got=\"$(herd_driver_agent_status_resolved %s idle pane-1)\"" % shlex.quote(slug))
        script.append('printf \'%s\' "$got"')
        out = subprocess.run(["bash", "-c", "\n".join(script)],
                             capture_output=True, text=True, timeout=15)
        return out.stdout.strip()

    def _python_resolve(self, slug, frames):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, True)
        orig_trees = os.environ.get("WORKTREES_DIR")
        orig_TREES = os.environ.get("TREES")
        os.environ["WORKTREES_DIR"] = tmp
        os.environ.pop("TREES", None)
        orig = LR.subprocess
        LR.subprocess = _RosterPaneSub("idle", list(frames), pane_id="pane-1", name=slug)
        try:
            act = LiveActuator("/nonexistent-home", LiveJournal(os.path.join(tmp, "journal.jsonl")))
            status = "idle"
            for _ in frames:
                status, _ = act._agent_lookup(slug)
            return status
        finally:
            LR.subprocess = orig
            if orig_trees is None:
                os.environ.pop("WORKTREES_DIR", None)
            else:
                os.environ["WORKTREES_DIR"] = orig_trees
            if orig_TREES is not None:
                os.environ["TREES"] = orig_TREES

    def test_bash_and_python_agree_on_every_fixture(self):
        mismatches = []
        for name, frames, expected in self.FIXTURES:
            slug = "parity-" + name
            bash_got = self._bash_resolve(slug, frames)
            python_got = self._python_resolve(slug, frames)
            if bash_got != expected or python_got != expected or bash_got != python_got:
                mismatches.append((name, bash_got, python_got, expected))
        self.assertFalse(mismatches, "bash/python status-resolve disagreement: %r" % (mismatches,))


class TestPaneContentDeltaCksumInterop(unittest.TestCase):
    """HERD-648 adversarial review finding: in production the content-delta snapshot store is SHARED
    on disk between the bash and python engines — agent-watch.sh:391 sets `TREES=$WORKTREES_DIR` and
    the python engine is launched with `WORKTREES_DIR=${TREES:-}`, so driver.sh's
    `${WORKTREES_DIR:-${TREES:-.}}/.herd/status-resolve/<slug>` and this module's `_pool_dir()`-rooted
    store resolve to the IDENTICAL file. The original port hashed with python's sha256 while the bash
    twin pipes text through `cksum` — the two encodings can never compare equal, so a snapshot written
    by one side always reads as "changed" to the other, permanently defeating the frozen-pane/dead-
    builder guardrail the instant both engines touch the same slug. This test proves the fix (python
    now shells to the SAME `cksum` binary) by sharing one real on-disk store between a genuine bash
    `_herd_pane_content_delta` call and a genuine python `_pane_content_delta` call — no subprocess
    stubbing on either side, so a re-introduced encoding mismatch would be caught here even though
    TestStatusCorroborateBashPythonParity (separate tmpdirs per language) could not catch it."""

    def setUp(self):
        if shutil.which("bash") is None or shutil.which("cksum") is None:
            self.skipTest("bash/cksum not on PATH")
        self.driver_sh = os.path.abspath(
            os.path.join(os.path.dirname(__file__), "..", "scripts", "herd", "driver.sh"))
        if not os.path.exists(self.driver_sh):
            self.skipTest("driver.sh not found at %s" % self.driver_sh)
        self.pool = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.pool, True)
        self._orig_trees = os.environ.get("WORKTREES_DIR")
        self._orig_TREES = os.environ.get("TREES")
        os.environ["WORKTREES_DIR"] = self.pool
        os.environ.pop("TREES", None)

    def tearDown(self):
        if self._orig_trees is None:
            os.environ.pop("WORKTREES_DIR", None)
        else:
            os.environ["WORKTREES_DIR"] = self._orig_trees
        if self._orig_TREES is not None:
            os.environ["TREES"] = self._orig_TREES

    def _bash_delta(self, slug, text):
        # Calls driver.sh's _herd_pane_content_delta DIRECTLY (slug + text args) — no herdr stub
        # needed, since this function never reads a pane itself.
        script = (
            "set -uo pipefail\n"
            ". %s\n"
            "_herd_pane_content_delta %s %s && echo DELTA || echo NODELTA\n"
        ) % (shlex.quote(self.driver_sh), shlex.quote(slug), shlex.quote(text))
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=15)
        return out.stdout.strip() == "DELTA"

    def _python_delta(self, slug, text):
        return LR._pane_content_delta(slug, text)

    def test_bash_writes_first_python_reads_the_same_store(self):
        slug = "interop-a"
        frame1, frame2 = "✳ frame one", "✳ frame two — different"
        self.assertFalse(self._bash_delta(slug, frame1))     # bash: no prior snapshot yet
        self.assertFalse(self._python_delta(slug, frame1))   # python reads bash's frame-1 snapshot: SAME text
        self.assertTrue(self._python_delta(slug, frame2))    # snapshot (frame 1) vs frame 2: a REAL delta

    def test_python_writes_first_bash_reads_the_same_store(self):
        slug = "interop-b"
        frame1, frame2 = "✳ frame one", "✳ frame two — different"
        self.assertFalse(self._python_delta(slug, frame1))   # python: no prior snapshot yet
        self.assertFalse(self._bash_delta(slug, frame1))     # bash reads python's frame-1 snapshot: SAME text
        self.assertTrue(self._bash_delta(slug, frame2))      # snapshot (frame 1) vs frame 2: a REAL delta


class _RecordingResolverSub:
    """Records every argv `LiveActuator.dispatch_resolver` runs and scripts a bare `bash
    herd-resolve.sh <slug>` success/failure — proves the HERD-584 dispatch shape without ever
    launching herdr/git/claude."""

    def __init__(self, rc=0):
        self.calls = []
        self.rc = rc

    def run(self, argv, *a, **k):
        self.calls.append((list(argv), dict(k)))
        return _FakeCompleted("", returncode=self.rc)


class TestLiveDispatchResolver(LiveCase):
    """HERD-584: LiveActuator.dispatch_resolver is the live twin of agent-watch.sh's spawn_resolver —
    a best-effort, bounded shell-out to the EXISTING scripts/herd/herd-resolve.sh, never raising."""

    def _actuator(self, sub):
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        return LiveActuator("/some/home", LiveJournal(self.jpath))

    def _cand(self):
        return LiveCandidate(7, "deadbeef", slug="feat-x", worktree="/wt/feat-x")

    def test_success_runs_herd_resolve_with_the_slug_and_pr_sha_env(self):
        sub = _RecordingResolverSub(rc=0)
        act = self._actuator(sub)
        self.assertTrue(act.dispatch_resolver(self._cand()))
        self.assertEqual(len(sub.calls), 1)
        argv, kwargs = sub.calls[0]
        self.assertEqual(argv[0], "bash")
        self.assertTrue(argv[1].endswith("scripts/herd/herd-resolve.sh"))
        self.assertEqual(argv[2], "feat-x")
        self.assertEqual(kwargs["env"]["HERD_RESOLVE_PR"], "7")
        self.assertEqual(kwargs["env"]["HERD_RESOLVE_SHA"], "deadbeef")
        self.assertIn("timeout", kwargs)

    def test_nonzero_exit_reports_failure(self):
        act = self._actuator(_RecordingResolverSub(rc=1))
        self.assertFalse(act.dispatch_resolver(self._cand()))

    def test_a_raised_exception_never_escapes(self):
        class _Raising:
            def run(self, *a, **k):
                raise OSError("herdr not found")
        act = self._actuator(_Raising())
        self.assertFalse(act.dispatch_resolver(self._cand()))


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
        # The gh api call carries the exact success-only status shape bash posts. Matched by the
        # unique "statuses/deadbeef" segment — the cross-seat setter guard (HERD-446) now makes its
        # OWN read-only gh api calls first (commit date, current status), so the status POST is no
        # longer necessarily the first "api" call recorded.
        api = [c for c in sub.calls if any("statuses/deadbeef" in str(a) for a in c)][0]
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


class TestGateStatusPendingLever(LiveCase):
    """HERD-453 count 4: GATE_STATUS_PENDING posts `herd/gates`=pending at GATE-CYCLE START so the PR
    page explains its 'Expected — waiting' row instead of leaving it unattributed. SHIP-DORMANT and
    STRICT — off (the default) and every unrecognized value are byte-inert, preserving the SUCCESS-ONLY
    contract that keeps a CLEAN sha out of mergeStateStatus=UNSTABLE. Hermetic: subprocess is stubbed."""

    def _actuator(self, sub):
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        return LiveActuator("/nonexistent-home", LiveJournal(self.jpath))

    def test_lever_is_strict_and_defaults_off(self):
        self.assertFalse(LR._gate_status_pending_enabled({}))
        self.assertFalse(LR._gate_status_pending_enabled({"GATE_STATUS_PENDING": ""}))
        self.assertFalse(LR._gate_status_pending_enabled({"GATE_STATUS_PENDING": "onn"}))
        self.assertFalse(LR._gate_status_pending_enabled({"GATE_STATUS_PENDING": "off"}))
        for token in ("on", "ON", "1", "true", "yes", "enabled"):
            self.assertTrue(LR._gate_status_pending_enabled({"GATE_STATUS_PENDING": token}), token)

    def test_pending_post_shape_and_journal(self):
        sub = _RecordingSub()
        act = self._actuator(sub)
        self.assertTrue(act.post_gate_status_pending(LiveCandidate(7, "deadbeef", slug="feat-x")))
        api = [c for c in sub.calls if any("statuses/deadbeef" in str(a) for a in c)][0]
        self.assertIn("state=pending", api)
        self.assertIn("context=herd/gates", api)
        self.assertIn("description=review in progress", api)
        gs = [o for o in events(self.jpath) if o["event"] == "gate_status"]
        self.assertEqual([o["state"] for o in gs], ["pending"])

    def test_failed_pending_post_journals_nothing_and_retries(self):
        sub = _RecordingSub(fail={"api"})
        act = self._actuator(sub)
        self.assertFalse(act.post_gate_status_pending(LiveCandidate(7, "deadbeef", slug="feat-x")))
        ev = events(self.jpath) if os.path.exists(self.jpath) else []
        self.assertFalse([o for o in ev if o["event"] == "gate_status"])

    def test_tick_posts_pending_once_when_on_and_never_when_off(self):
        """MUTATION PROOF: with the lever ON a candidate entering the gate DAG posts pending exactly
        once across re-walks; OFF (and with GATE_STATUS=off) it is byte-inert — zero posts."""

        class Recorder(DryRunActuator):
            def __init__(self, journal):
                super().__init__(journal)
                self.pending = 0

            def post_gate_status_pending(self, cand):
                self.pending += 1
                self.journal.append("gate_status", "pr", cand.pr, "sha", cand.sha, "state", "pending",
                                    "context", "herd/gates")
                return True

        def run(config):
            self.tmp = tempfile.mkdtemp()
            self.jpath = os.path.join(self.tmp, "live-test.jsonl")
            journal = LiveJournal(self.jpath)
            rec = Recorder(journal)
            for _ in range(2):    # re-walk the SAME (pr,sha): the ledger marker must suppress a repost
                LiveTick(config,
                         FixtureDiscovery({"candidates": [self.one(1, review=None, health=None)]}),
                         FixtureGates({"candidates": [self.one(1, review=None, health=None)]}),
                         rec, journal, state=LiveState(self.tmp)).run()
            return rec.pending

        self.assertEqual(run({"MERGE_POLICY": "observe", "GATE_STATUS": "on",
                              "GATE_STATUS_PENDING": "on"}), 1)
        self.assertEqual(run({"MERGE_POLICY": "observe", "GATE_STATUS": "on"}), 0)          # default off
        self.assertEqual(run({"MERGE_POLICY": "observe", "GATE_STATUS": "off",
                              "GATE_STATUS_PENDING": "on"}), 0)   # requires the master lever


class _XseatSub:
    """Subprocess stand-in scripting the gh reads/writes the cross-seat guard (HERD-446) and the
    ordinary merge/post-status actuation make — proves the guard end-to-end through the REAL
    LiveActuator, hermetically. Unmatched argvs fall through to a benign default so a test only
    scripts what it cares about; ``fail`` (a set of tokens) makes the matching read raise, simulating
    an unreadable gh call — never a crash, the guard's own fail-soft must absorb it."""

    def __init__(self, commit_date="2026-07-09T16:10:00Z", comments=None,
                 current_status=("", ""), view_state="MERGED", fail=()):
        self.calls = []
        self.commit_date = commit_date
        self.comments = comments if comments is not None else []
        self.current_status = current_status       # (state, creator_login)
        self.view_state = view_state
        self.fail = set(fail)

    def run(self, argv, *a, **k):
        self.calls.append(list(argv))
        joined = " ".join(str(x) for x in argv)
        if argv[:2] == ["gh", "api"] and "/statuses" in joined and "/commits/" in joined:
            if "statuses" in self.fail:
                raise subprocess.CalledProcessError(1, argv)
            state, creator = self.current_status
            rows = ([{"context": "herd/gates", "state": state, "creator": {"login": creator}}]
                    if state else [])
            return _FakeCompleted(json.dumps(rows))
        if argv[:2] == ["gh", "api"] and "/commits/" in joined:
            if "commit_date" in self.fail:
                raise subprocess.CalledProcessError(1, argv)
            return _FakeCompleted(self.commit_date)
        if argv[:2] == ["gh", "api"] and "/statuses/" in joined:
            if "post" in self.fail:
                raise subprocess.CalledProcessError(1, argv)
            return _FakeCompleted("")
        if argv[:3] == ["gh", "pr", "view"] and "comments" in argv:
            if "comments" in self.fail:
                raise subprocess.CalledProcessError(1, argv)
            return _FakeCompleted(json.dumps({"comments": self.comments}))
        if argv[:3] == ["gh", "pr", "view"]:
            if "view_state" in self.fail:
                raise subprocess.CalledProcessError(1, argv)
            return _FakeCompleted(self.view_state + "\n")
        if argv[:3] == ["gh", "pr", "merge"]:
            if "merge" in self.fail:
                raise subprocess.CalledProcessError(1, argv)
            return _FakeCompleted("")
        return _FakeCompleted("")


class TestCrossSeatBlockPrecedence(LiveCase):
    """HERD-247/HERD-446: cross-seat BLOCK precedence, restored at BOTH enforcement surfaces from ONE
    shared implementation (``_cross_seat_block_standing``) — the merge decision (``LiveTick._walk``)
    and the gate-status setter (``LiveActuator.post_gate_status``). Grounded in PR #343 (2026-07-09):
    two seats gated the same PR concurrently; one posted a correctness BLOCK, the other's later PASS
    blessed the sha and merged over it, silently. Hermetic: gh is stubbed via :class:`_XseatSub` — no
    network, no real PR, no model call.

    Each test drives a REAL :class:`LiveActuator` (not the dry-run twin) through a green candidate
    (health=CLEAN, review=PASS, pr=7, sha=deadbeef) via :class:`LiveTick`, so a standing block is
    proven to withhold the ACTUAL merge/post-status subprocess calls, not just a return value.
    """

    FOREIGN_BLOCK = 'REVIEW: **BLOCK** — rule: safety-rail bypass | why: a limit-parked resolver reads idle'
    FOREIGN_PASS = '**Pre-merge correctness review — PASS (no blocking findings).**'

    def _drive(self, sub, config=None, fail_hold_source=False):
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        journal = LiveJournal(self.jpath)
        state = LiveState(self.tmp)
        config = dict(config if config is not None else {"MERGE_POLICY": "auto", "WATCHER_OWNER": "mySeat"})
        actuator = LiveActuator("/nonexistent-home", journal, config, state)
        hold_source = LiveHoldSource(state, config)
        scenario = {"candidates": [self.one(7, sha="deadbeef", review="PASS", health="CLEAN")],
                    "config": config}
        t = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario), actuator, journal,
                     state=state, hold_source=hold_source)
        res = t.run()
        return res, events(self.jpath), sub

    def _merge_calls(self, sub):
        return [c for c in sub.calls if c[:3] == ["gh", "pr", "merge"]]

    def _post_calls(self, sub):
        return [c for c in sub.calls
                if c[:2] == ["gh", "api"] and any("statuses/deadbeef" in str(x) for x in c)]

    def test_standing_foreign_block_holds_never_blesses_never_merges(self):
        sub = _XseatSub(comments=[
            {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z",
             "body": self.FOREIGN_BLOCK},
        ])
        res, ev, sub = self._drive(sub)
        self.assertEqual(res["outcomes"]["7"], "HOLD")
        self.assertFalse(self._merge_calls(sub), "a standing foreign BLOCK must never be merged over")
        self.assertFalse(self._post_calls(sub), "a standing foreign BLOCK must never be blessed")
        honored = [o for o in ev if o["event"] == "cross_seat_block_honored"]
        self.assertEqual(len(honored), 1)
        self.assertEqual(honored[0]["seat"], "otherSeat")
        self.assertEqual(honored[0]["stage"], "merge")
        self.assertEqual(honored[0]["pr"], 7)
        self.assertEqual(honored[0]["sha"], "deadbeef")

    def test_no_foreign_block_is_byte_identical(self):
        sub = _XseatSub(comments=[])
        res, ev, sub = self._drive(sub)
        self.assertEqual(res["outcomes"]["7"], "MERGE")
        self.assertTrue(self._merge_calls(sub))
        self.assertTrue(self._post_calls(sub))
        self.assertTrue([o for o in ev if o["event"] == "gate_status"])
        self.assertFalse([o for o in ev if o["event"].startswith("cross_seat_block")])

    def test_foreign_gate_failure_status_withholds_blessing_and_merge(self):
        sub = _XseatSub(current_status=("failure", "otherSeat"))
        res, ev, sub = self._drive(sub)
        self.assertEqual(res["outcomes"]["7"], "HOLD")
        self.assertFalse(self._merge_calls(sub))
        honored = [o for o in ev if o["event"] == "cross_seat_block_honored"]
        self.assertEqual(len(honored), 1)
        self.assertEqual(honored[0]["seat"], "otherSeat")

    def test_own_block_is_not_a_cross_seat_block(self):
        # THIS seat's own local BLOCK is not a cross-seat block — a solo watcher must not hold its
        # own blocked PRs behind a reconcile row (agent-watch.sh test (b)-own-block equivalent).
        sub = _XseatSub(comments=[
            {"author": {"login": "mySeat"}, "createdAt": "2026-07-09T16:19:00Z",
             "body": self.FOREIGN_BLOCK},
        ])
        res, ev, sub = self._drive(sub)
        self.assertEqual(res["outcomes"]["7"], "MERGE")
        self.assertFalse([o for o in ev if o["event"] == "cross_seat_block_honored"])

    def test_override_resolves_the_standing_block(self):
        with open(os.path.join(self.tmp, ".agent-watch-overrides"), "w", encoding="utf-8") as fh:
            fh.write("%d override 7 deadbeef\n" % int(time.time()))
        sub = _XseatSub(comments=[
            {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z",
             "body": self.FOREIGN_BLOCK},
        ])
        res, ev, sub = self._drive(sub)
        self.assertEqual(res["outcomes"]["7"], "MERGE")
        self.assertFalse([o for o in ev if o["event"] == "cross_seat_block_honored"])

    def test_override_is_sha_keyed_and_does_not_carry_to_a_new_commit(self):
        with open(os.path.join(self.tmp, ".agent-watch-overrides"), "w", encoding="utf-8") as fh:
            fh.write("%d override 7 someothersha\n" % int(time.time()))
        sub = _XseatSub(comments=[
            {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z",
             "body": self.FOREIGN_BLOCK},
        ])
        res, ev, sub = self._drive(sub)
        self.assertEqual(res["outcomes"]["7"], "HOLD")

    def test_blocking_seats_later_pass_resolves_its_own_block(self):
        sub = _XseatSub(comments=[
            {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z",
             "body": self.FOREIGN_BLOCK},
            {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:40:00Z",
             "body": self.FOREIGN_PASS},
        ])
        res, ev, sub = self._drive(sub)
        self.assertEqual(res["outcomes"]["7"], "MERGE")

    def test_third_seats_pass_does_not_resolve_another_seats_block(self):
        # The #343 incident, exactly: a DIFFERENT seat's PASS is a second opinion, not a resolution.
        sub = _XseatSub(comments=[
            {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z",
             "body": self.FOREIGN_BLOCK},
            {"author": {"login": "thirdSeat"}, "createdAt": "2026-07-09T16:40:00Z",
             "body": self.FOREIGN_PASS},
        ])
        res, ev, sub = self._drive(sub)
        self.assertEqual(res["outcomes"]["7"], "HOLD")
        honored = [o for o in ev if o["event"] == "cross_seat_block_honored"]
        self.assertEqual(honored[0]["seat"], "otherSeat")

    def test_block_predating_the_head_sha_never_holds_the_new_commit(self):
        sub = _XseatSub(commit_date="2026-07-09T17:00:00Z", comments=[
            {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z",
             "body": self.FOREIGN_BLOCK},
        ])
        res, ev, sub = self._drive(sub)
        self.assertEqual(res["outcomes"]["7"], "MERGE")

    def test_degraded_scan_fails_soft_and_still_merges(self):
        sub = _XseatSub(commit_date="")   # unreadable commit date -> degraded, never a false hold
        res, ev, sub = self._drive(sub)
        self.assertEqual(res["outcomes"]["7"], "MERGE")
        scan = [o for o in ev if o["event"] == "cross_seat_block_scan"]
        self.assertEqual(len(scan), 1)
        self.assertEqual(scan[0]["state"], "degraded")

    def test_unresolvable_seat_identity_fails_soft(self):
        sub = _XseatSub(comments=[
            {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z",
             "body": self.FOREIGN_BLOCK},
        ])
        res, ev, sub = self._drive(sub, config={"MERGE_POLICY": "auto"})   # no WATCHER_OWNER configured
        self.assertEqual(res["outcomes"]["7"], "MERGE")
        scan = [o for o in ev if o["event"] == "cross_seat_block_scan"]
        self.assertEqual(len(scan), 1)

    def test_identity_probe_does_not_scale_with_candidate_count(self):
        # HERD-446: with no WATCHER_OWNER configured, resolving this seat's identity means a real
        # `gh api user` call. Bash memoized that probe for the life of the (long-running) watcher
        # process; Python is a fresh process per --tick, so LiveTick/LiveActuator each memoize it
        # per-INSTANCE instead (a fixed, small cost per tick — 1 probe per surface class touched),
        # never growing per candidate. Proved by comparing 1 candidate against 5: SAME call count.
        def run(n):
            sub = _XseatSub(comments=[])
            orig = LR.subprocess
            LR.subprocess = sub
            self.addCleanup(lambda: setattr(LR, "subprocess", orig))
            journal = LiveJournal(os.path.join(self.tmp, "j-%d.jsonl" % n))
            state = LiveState(os.path.join(self.tmp, "state-%d" % n))
            os.makedirs(state.dir, exist_ok=True)
            config = {"MERGE_POLICY": "auto"}   # no WATCHER_OWNER -> _resolve_owner shells out
            actuator = LiveActuator("/nonexistent-home", journal, config, state)
            hold_source = LiveHoldSource(state, config)
            candidates = [self.one(100 + i, sha="sha%d" % i, review="PASS", health="CLEAN")
                          for i in range(n)]
            scenario = {"candidates": candidates, "config": config}
            t = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario), actuator, journal,
                         state=state, hold_source=hold_source)
            res = t.run()
            for i in range(n):
                self.assertEqual(res["outcomes"][str(100 + i)], "MERGE")
            return len([c for c in sub.calls if c[:3] == ["gh", "api", "user"]])

        self.assertEqual(run(1), run(5),
                         "the identity probe must not scale with the number of candidates walked")

    def test_setter_guard_independently_withholds_a_direct_post(self):
        """Proves the SECOND surface (LiveActuator.post_gate_status) on its own, calling it directly —
        bypassing the merge-decision surface entirely. Defense in depth (multi-seat doctrine Rule 2):
        the setter must never bless a standing foreign BLOCK regardless of how it is reached."""
        sub = _XseatSub(comments=[
            {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z",
             "body": self.FOREIGN_BLOCK},
        ])
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        journal = LiveJournal(self.jpath)
        state = LiveState(self.tmp)
        act = LiveActuator("/nonexistent-home", journal, {"WATCHER_OWNER": "mySeat"}, state)
        self.assertFalse(act.post_gate_status(LiveCandidate(7, "deadbeef", slug="feat-x")))
        self.assertFalse(self._post_calls(sub))
        honored = [o for o in events(self.jpath) if o["event"] == "cross_seat_block_honored"]
        self.assertEqual(len(honored), 1)
        self.assertEqual(honored[0]["stage"], "setter")

    def test_setter_guard_posts_normally_with_no_standing_block(self):
        sub = _XseatSub(comments=[])
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        journal = LiveJournal(self.jpath)
        state = LiveState(self.tmp)
        act = LiveActuator("/nonexistent-home", journal, {"WATCHER_OWNER": "mySeat"}, state)
        self.assertTrue(act.post_gate_status(LiveCandidate(7, "deadbeef", slug="feat-x")))
        self.assertTrue(self._post_calls(sub))
        self.assertFalse([o for o in events(self.jpath) if o["event"].startswith("cross_seat_block")])


def _make_stale_base_repo(tmp):
    """A two-worktree repo (``main`` + ``feature``) where BOTH sides edit the same file after the
    branch's fork point — the deterministic overlap :func:`herd.live_runtime._stale_dup_base_overlap`
    proves against. Returns ``(feature_worktree_dir, feature_head_sha)``."""
    main_dir = os.path.join(tmp, "main")
    sha0 = _git_init_repo(main_dir)
    feat_dir = os.path.join(tmp, "feat")
    subprocess.run(["git", "-C", main_dir, "worktree", "add", "-q", "-b", "feature", feat_dir, sha0],
                   check=True)
    with open(os.path.join(feat_dir, "f"), "w", encoding="utf-8") as fh:
        fh.write("feature-change")
    subprocess.run(["git", "-C", feat_dir, "add", "f"], check=True)
    subprocess.run(["git", "-C", feat_dir, "commit", "-q", "-m", "feature edits f"], check=True)
    feat_sha = subprocess.check_output(
        ["git", "-C", feat_dir, "rev-parse", "HEAD"]).decode().strip()
    with open(os.path.join(main_dir, "f"), "w", encoding="utf-8") as fh:
        fh.write("main-change")
    subprocess.run(["git", "-C", main_dir, "add", "f"], check=True)
    subprocess.run(["git", "-C", main_dir, "commit", "-q", "-m", "main edits f"], check=True)
    return feat_dir, feat_sha


class _StaleDupHermeticHoldSource(LiveHoldSource):
    """LiveHoldSource twin for TestStaleDupGate (HERD-596): the class means to prove ONLY the
    stale-dup gate (:func:`_stale_dup_check`, which already honors the ``HERD_STALE_DUP_*_FILE``
    seams below) — never the separate ``hv_body`` human-verify read, which has no seam of its own
    and shells straight out to a REAL ``gh pr view``. On the maintainer's authenticated box that
    call happens to succeed against whatever the fixture's pr# resolves to in the real repo,
    masking the miss; on an unauthenticated/gh-less CI runner it fails per HERD-237's fail-CLOSED
    contract, forcing every candidate to HOLD before the stale-dup gate is even reached — which
    happened to match the already-HOLD/ESCALATE/BLOCK-expecting tests below but broke the two
    MERGE-expecting ones (CI-environment-specific: same sha, same fixtures, red only where `gh`
    can't reach a real PR). Stub the read to always succeed with an empty, non-human-verify body;
    ``approved()`` stays the real ledger read (hermetic already — nothing in this class writes an
    approval row)."""

    def hv_body(self, pr):
        return "", 0


class TestStaleDupGate(LiveCase):
    """HERD-566 (P5b HERD-561 child 1/2): the deterministic duplicate-ref / stale-base file-overlap
    pre-merge gate (HERD-188), restored into the live decide path — its only bash caller
    (agent-watch.sh:_stale_dup_gate_step) lost its wiring at the P5b port (HERD-556 reachability
    lint), so every merge under ENGINE_IMPL=python has run with NEITHER hold. LIVE-ONLY (gated on
    ``hold_source is not None``, exactly like cross-seat): every OTHER test in this module passes no
    hold_source and so never shells to `gh`/`git` for this gate — proved directly below. Uses
    :class:`_StaleDupHermeticHoldSource`, not the bare :class:`LiveHoldSource`, so this class's own
    hermeticity claim actually holds (HERD-596)."""

    def setUp(self):
        super().setUp()
        for k in ("HERD_STALE_DUP_BODY_FILE", "HERD_STALE_DUP_MERGED_FILE"):
            self.addCleanup(os.environ.pop, k, None)

    def _seam_file(self, name, content):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return path

    def _tick_live(self, cand_kwargs, config, actuator=None):
        config = dict(config)
        journal = LiveJournal(self.jpath)
        state = LiveState(self.tmp)
        actuator = actuator or DryRunActuator(journal)
        scenario = {"candidates": [self.one(**cand_kwargs)], "config": config}
        t = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario), actuator, journal,
                     state=state, hold_source=_StaleDupHermeticHoldSource(state, config))
        res = t.run()
        return res, events(self.jpath)

    # ── duplicate flavor — always a human judgment call ──────────────────────────────────────────

    def test_duplicate_ref_escalates_needs_you(self):
        body_file = self._seam_file("body.txt", "Refs: HERD-999\n")
        merged_file = self._seam_file("merged.tsv", "555\tHERD-999\n")
        os.environ["HERD_STALE_DUP_BODY_FILE"] = body_file
        os.environ["HERD_STALE_DUP_MERGED_FILE"] = merged_file
        res, ev = self._tick_live(
            dict(pr=42, sha="dupsha", health="CLEAN", review="PASS"),
            {"MERGE_POLICY": "auto"})
        self.assertEqual(res["outcomes"]["42"], "ESCALATE")
        hold = [o for o in ev if o["event"] == "stale_dup_hold"]
        self.assertEqual(len(hold), 1)
        self.assertEqual(hold[0]["kind"], "duplicate")
        self.assertIn("HERD-999", hold[0]["reason"])
        self.assertIn("555", hold[0]["reason"])
        # Never autofix, never consumes a refix round.
        self.assertFalse([o for o in ev if o["event"] in ("refix_bounce", "stale_refix_escalated")])

    def test_own_pr_never_counts_as_its_own_duplicate(self):
        body_file = self._seam_file("body.txt", "Refs: HERD-999\n")
        merged_file = self._seam_file("merged.tsv", "42\tHERD-999\n")   # same pr# as this PR
        os.environ["HERD_STALE_DUP_BODY_FILE"] = body_file
        os.environ["HERD_STALE_DUP_MERGED_FILE"] = merged_file
        res, ev = self._tick_live(
            dict(pr=42, sha="dupsha", health="CLEAN", review="PASS"),
            {"MERGE_POLICY": "auto"})
        self.assertEqual(res["outcomes"]["42"], "MERGE")
        self.assertFalse([o for o in ev if o["event"] == "stale_dup_hold"])

    # ── stale-base flavor — mechanical; autofix is opt-in (STALE_BASE_AUTOFIX, default off) ────────

    def test_stale_base_overlap_holds_without_autofix(self):
        feat_dir, feat_sha = _make_stale_base_repo(self.tmp)
        os.environ["HERD_STALE_DUP_BODY_FILE"] = self._seam_file("body.txt", "no ref here\n")
        res, ev = self._tick_live(
            dict(pr=7, sha=feat_sha, worktree=feat_dir, base="main", health="CLEAN", review="PASS"),
            {"MERGE_POLICY": "auto", "DEFAULT_BRANCH": "main"})
        self.assertEqual(res["outcomes"]["7"], "HOLD")
        hold = [o for o in ev if o["event"] == "stale_dup_hold"]
        self.assertEqual(len(hold), 1)
        self.assertEqual(hold[0]["kind"], "stale-base")
        self.assertIn("f", hold[0]["reason"])
        self.assertFalse([o for o in ev if o["event"] == "refix_bounce"],
                         "STALE_BASE_AUTOFIX off must never bounce — byte-identical to the pre-"
                         "HERD-199 hold")

    def test_stale_base_autofix_engages_and_bounces_the_live_builder(self):
        feat_dir, feat_sha = _make_stale_base_repo(self.tmp)
        os.environ["HERD_STALE_DUP_BODY_FILE"] = self._seam_file("body.txt", "no ref here\n")
        res, ev = self._tick_live(
            dict(pr=7, sha=feat_sha, worktree=feat_dir, base="main", health="CLEAN", review="PASS",
                 author="dev1"),
            {"MERGE_POLICY": "auto", "DEFAULT_BRANCH": "main", "STALE_BASE_AUTOFIX": "on",
             "WATCHER_OWNER": "dev1"})
        self.assertEqual(res["outcomes"]["7"], "BLOCK")
        bounce = [o for o in ev if o["event"] == "refix_bounce"]
        self.assertEqual(len(bounce), 1)
        self.assertEqual(bounce[0]["rule"], "stale")
        self.assertEqual(bounce[0]["round"], 1)
        wake = [o for o in ev if o["event"] == "refix_wake_result"]
        self.assertEqual(wake[0]["woke"], 1)

    def test_stale_base_autofix_dispatches_resolver_when_nobody_wakes(self):
        # HERD-584: the old bash healer dispatched the EXISTING conflict resolver
        # (herd-resolve.sh) when there is no live builder to bounce, rather than escalate a
        # MECHANICAL fix straight to a human. A worktree exists here, so the resolver fallback
        # engages: BLOCK (awaiting the resolver's push), not ESCALATE.
        feat_dir, feat_sha = _make_stale_base_repo(self.tmp)
        os.environ["HERD_STALE_DUP_BODY_FILE"] = self._seam_file("body.txt", "no ref here\n")
        res, ev = self._tick_live(
            dict(pr=7, sha=feat_sha, worktree=feat_dir, base="main", health="CLEAN", review="PASS",
                 agent_status="dead", author="dev1"),
            {"MERGE_POLICY": "auto", "DEFAULT_BRANCH": "main", "STALE_BASE_AUTOFIX": "on",
             "WATCHER_OWNER": "dev1"})
        self.assertEqual(res["outcomes"]["7"], "BLOCK")
        self.assertFalse([o for o in ev if o["event"] == "refix_escalated_no_wake"])
        bounce = [o for o in ev if o["event"] == "stale_base_autofix_bounce"]
        self.assertEqual(len(bounce), 1)
        self.assertEqual(bounce[0]["pr"], 7)
        self.assertEqual(bounce[0]["sha"], feat_sha)
        wake = [o for o in ev if o["event"] == "refix_wake_result"]
        self.assertEqual(wake[0]["woke"], 0)
        self.assertEqual(wake[0]["escalated"], "false")
        # The round is still spent (a resolver dispatch IS a real heal attempt, unlike the
        # unwoken-bounce refund path) — never refunded via a reset row.
        self.assertFalse([o for o in ev if o["event"] == "refix_rail_reset"])

    def test_stale_base_autofix_escalates_when_resolver_dispatch_fails(self):
        # The fallback engages (a worktree exists) but the resolver spawn itself fails (herdr down,
        # script missing, …) — the caller must fall through to the same honest needs-you escalation
        # a plain unwoken bounce takes, round refunded.
        feat_dir, feat_sha = _make_stale_base_repo(self.tmp)
        os.environ["HERD_STALE_DUP_BODY_FILE"] = self._seam_file("body.txt", "no ref here\n")

        class _NoResolverActuator(DryRunActuator):
            def dispatch_resolver(self, cand):
                return False

        journal = LiveJournal(self.jpath)
        state = LiveState(self.tmp)
        actuator = _NoResolverActuator(journal)
        config = {"MERGE_POLICY": "auto", "DEFAULT_BRANCH": "main", "STALE_BASE_AUTOFIX": "on",
                  "WATCHER_OWNER": "dev1"}
        scenario = {"candidates": [self.one(pr=7, sha=feat_sha, worktree=feat_dir, base="main",
                                            health="CLEAN", review="PASS", agent_status="dead",
                                            author="dev1")],
                   "config": config}
        t = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario), actuator, journal,
                     state=state, hold_source=_StaleDupHermeticHoldSource(state, config))
        res = t.run()
        ev = events(self.jpath)
        self.assertEqual(res["outcomes"]["7"], "ESCALATE")
        self.assertFalse([o for o in ev if o["event"] == "stale_base_autofix_bounce"])
        self.assertTrue([o for o in ev if o["event"] == "refix_escalated_no_wake"])

    # ── HERD-601 LIVE-FIRING PROOF: the lever resolved through the SAME os.environ seam a real
    # `--tick` child uses (_config_from_env), not a hand-built dict. Every test above injects
    # STALE_BASE_AUTOFIX directly into a literal config dict passed to LiveTick — that proves the
    # bounce/resolver-dispatch CODE works, but it never exercises the actual wire from an operator's
    # `.herd/config` to this process's config dict, and that wire is exactly where the bug was: the
    # key was missing from _CORE_ENV_KEYS/herd-config.sh's export sweep, so a real live tick's
    # `self.config.get("STALE_BASE_AUTOFIX")` always read "" no matter what herd-config.sh resolved
    # STALE_BASE_AUTOFIX to in the shell — the ported healer (HERD-584/PR #716) sat live in
    # production with the lever reading "on" (`.herd/config: STALE_BASE_AUTOFIX="on"`) and fired
    # ZERO `stale_base_autofix_bounce` events across two real holds (#714, #718). This test fails on
    # the pre-fix tree (config.get returns None, not "on") and proves the SAME LiveTick.run() call
    # every test above already exercises actually reaches BLOCK/stale_base_autofix_bounce when the
    # value arrives the way production delivers it — env, not a fixture dict.
    def test_stale_base_autofix_reaches_live_tick_via_config_from_env(self):
        self.addCleanup(os.environ.pop, "STALE_BASE_AUTOFIX", None)
        self.addCleanup(os.environ.pop, "MERGE_POLICY", None)
        self.addCleanup(os.environ.pop, "DEFAULT_BRANCH", None)
        self.addCleanup(os.environ.pop, "WATCHER_OWNER", None)
        self.addCleanup(os.environ.pop, "WATCHER_SCOPE", None)
        os.environ["STALE_BASE_AUTOFIX"] = "on"
        os.environ["MERGE_POLICY"] = "auto"
        os.environ["DEFAULT_BRANCH"] = "main"
        os.environ["WATCHER_OWNER"] = "dev1"
        # HERD-653: an intact (explicit) WATCHER_SCOPE stays byte-identical — this test is about
        # STALE_BASE_AUTOFIX/AUTOFIX_SCOPE plumbing, not WATCHER_SCOPE itself, so it declares the
        # solo default explicitly rather than relying on the now fail-closed "never set" default the
        # env genuinely has in this process.
        os.environ["WATCHER_SCOPE"] = "mine"
        config = LR._config_from_env()
        self.assertEqual(config.get("STALE_BASE_AUTOFIX"), "on",
                          "_config_from_env must thread an exported STALE_BASE_AUTOFIX through — "
                          "the HERD-601 gap (missing from _CORE_ENV_KEYS/herd-config.sh's export)")
        feat_dir, feat_sha = _make_stale_base_repo(self.tmp)
        os.environ["HERD_STALE_DUP_BODY_FILE"] = self._seam_file("body.txt", "no ref here\n")
        res, ev = self._tick_live(
            dict(pr=7, sha=feat_sha, worktree=feat_dir, base="main", health="CLEAN", review="PASS",
                 agent_status="dead", author="dev1"),
            config)
        self.assertEqual(res["outcomes"]["7"], "BLOCK")
        bounce = [o for o in ev if o["event"] == "stale_base_autofix_bounce"]
        self.assertEqual(len(bounce), 1,
                         "stale_base_autofix_bounce must land in the journal off an env-sourced "
                         "config — this is the exact event that never fired live")
        self.assertEqual(bounce[0]["pr"], 7)
        self.assertEqual(bounce[0]["sha"], feat_sha)

    def test_stale_no_wake_fallback_declines_without_a_worktree(self):
        # Unit-level: no worktree to resolve in place -> the fallback is inapplicable, never
        # dispatches, and never journals (mirrors _handle_stale_dup's "no builder/worktree" branch,
        # which stays a plain needs-you). Exercised directly since the full stale-dup gate can only
        # PROVE a stale-base hold against a real worktree in the first place.
        journal = LiveJournal(self.jpath)
        t = LiveTick({}, FixtureDiscovery({"candidates": [], "config": {}}),
                     FixtureGates({"candidates": [], "config": {}}), DryRunActuator(journal), journal,
                     state=LiveState(self.tmp))
        cand = LiveCandidate(pr=9, sha="deadbeef", slug="feat-nowt", worktree="")
        self.assertFalse(t._stale_no_wake_fallback(cand))
        self.assertFalse(os.path.exists(self.jpath), "a declined fallback must journal nothing")

    # ── the lever ─────────────────────────────────────────────────────────────────────────────────

    def test_lever_off_is_byte_identical(self):
        feat_dir, feat_sha = _make_stale_base_repo(self.tmp)
        os.environ["HERD_STALE_DUP_BODY_FILE"] = self._seam_file("body.txt", "Refs: HERD-999\n")
        os.environ["HERD_STALE_DUP_MERGED_FILE"] = self._seam_file("merged.tsv", "555\tHERD-999\n")
        res, ev = self._tick_live(
            dict(pr=7, sha=feat_sha, worktree=feat_dir, base="main", health="CLEAN", review="PASS"),
            {"MERGE_POLICY": "auto", "DEFAULT_BRANCH": "main", "STALE_DUP_DETECT": "off"})
        self.assertEqual(res["outcomes"]["7"], "MERGE")
        self.assertFalse([o for o in ev if o["event"] == "stale_dup_hold"])

    # ── fixture/dry-run/sim ticks never shell out for this gate ─────────────────────────────────────

    def test_no_hold_source_never_shells_out(self):
        orig = LR.subprocess
        LR.subprocess = _Poison()
        try:
            res, _ = self.tick([self.one(1, review="PASS", health="CLEAN")])
        finally:
            LR.subprocess = orig
        self.assertEqual(res["outcomes"]["1"], "MERGE")


class TestAutofixScope(LiveCase):
    """HERD-655 (GitHub issue #771): AUTOFIX_SCOPE, the multi-operator ownership gate shared by every
    autofix WRITE rail. GROUNDED (emberglen, two operators): a seat's RESOLVE_AUTOFIX rail adopted the
    OTHER operator's conflicting PR and dispatched a resolver against his branch — no author/operator
    filter existed on any autofix write rail.

    Two halves:
      (a) the shared pure functions (_autofix_scope / _autofix_scope_permits) — own (default) | all,
          fail-closed on an empty/unknown author or an unresolvable identity, journals
          autofix_scope_withheld on every withhold, mirrors agent-watch.sh's bash twin exactly.
      (b) the ONE rail that is actually LIVE in this ported engine, STALE_BASE_AUTOFIX
          (:meth:`LiveTick._walk`'s stale-base branch) — end-to-end proof that a foreign PR's
          stale-base hold is withheld (never bounced, never resolver-dispatched) while an owned PR's
          heal proceeds exactly as :class:`TestStaleDupGate` already proves. REVIEW_AUTOFIX and
          HEALTHCHECK_AUTOFIX have no python-side gate of their own to hook — see
          docs/multi-operator-ownership.md for why (unreachable bash since the P5b port, HERD-556) —
          so their scope wiring is proved in agent-watch.sh's own suites instead
          (tests/test-auto-refix.sh, tests/test-health-autofix.sh).
    """

    # ── (a) the shared pure functions ────────────────────────────────────────────────────────────

    def test_default_is_own(self):
        self.assertEqual(LR._autofix_scope({}), "own")

    def test_unknown_value_falls_back_to_own(self):
        self.assertEqual(LR._autofix_scope({"AUTOFIX_SCOPE": "bogus"}), "own")

    def test_own_permits_the_resolved_owner(self):
        journal = LiveJournal(self.jpath)
        config = {"WATCHER_OWNER": "alice"}
        self.assertTrue(LR._autofix_scope_permits(config, "alice", "resolve", 1, journal))
        self.assertFalse(os.path.exists(self.jpath), "a permitted call must never journal a withhold")

    def test_own_withholds_a_foreign_author_and_journals(self):
        journal = LiveJournal(self.jpath)
        config = {"WATCHER_OWNER": "alice"}
        self.assertFalse(LR._autofix_scope_permits(config, "bob", "stale", 2, journal))
        ev = events(self.jpath)
        withheld = [o for o in ev if o["event"] == "autofix_scope_withheld"]
        self.assertEqual(len(withheld), 1)
        self.assertEqual(withheld[0]["pr"], 2)
        self.assertEqual(withheld[0]["author"], "bob")
        self.assertEqual(withheld[0]["rail"], "stale")
        self.assertEqual(withheld[0]["reason"], "not-owner")

    def test_own_withholds_an_empty_author_fail_closed(self):
        journal = LiveJournal(self.jpath)
        config = {"WATCHER_OWNER": "alice"}
        self.assertFalse(LR._autofix_scope_permits(config, "", "review", 3, journal))

    def test_own_withholds_on_unresolvable_identity_and_journals_noowner(self):
        journal = LiveJournal(self.jpath)
        self.assertFalse(LR._autofix_scope_permits({}, "alice", "health", 4, journal, me=""))
        ev = events(self.jpath)
        withheld = [o for o in ev if o["event"] == "autofix_scope_withheld"]
        self.assertEqual(len(withheld), 1)
        self.assertEqual(withheld[0]["reason"], "noowner")

    def test_all_permits_every_author_including_empty(self):
        journal = LiveJournal(self.jpath)
        config = {"AUTOFIX_SCOPE": "all", "WATCHER_OWNER": "alice"}
        self.assertTrue(LR._autofix_scope_permits(config, "bob", "resolve", 5, journal))
        self.assertTrue(LR._autofix_scope_permits(config, "", "resolve", 6, journal))
        self.assertFalse(os.path.exists(self.jpath), "'all' must never journal a withhold")

    def test_all_never_resolves_the_identity(self):
        # 'all' must short-circuit before _resolve_owner — proved by poisoning subprocess (the gh
        # fallback _resolve_owner would otherwise reach with no WATCHER_OWNER configured).
        orig = LR.subprocess
        LR.subprocess = _Poison()
        try:
            self.assertTrue(LR._autofix_scope_permits({"AUTOFIX_SCOPE": "all"}, "bob", "resolve", 7))
        finally:
            LR.subprocess = orig

    def test_me_precomputed_skips_a_second_resolve(self):
        # The memoized-identity seam LiveTick._xseat_identity feeds in: passing `me` explicitly must
        # be honored verbatim, never re-derived from config.
        config = {"WATCHER_OWNER": "someone-else"}
        self.assertTrue(LR._autofix_scope_permits(config, "alice", "resolve", 8, me="alice"))

    # ── (b) end-to-end: the ONE live rail, STALE_BASE_AUTOFIX ───────────────────────────────────────

    def _seam_file(self, name, content):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return path

    def _tick_live(self, cand_kwargs, config, actuator=None):
        config = dict(config)
        journal = LiveJournal(self.jpath)
        state = LiveState(self.tmp)
        actuator = actuator or DryRunActuator(journal)
        scenario = {"candidates": [self.one(**cand_kwargs)], "config": config}
        t = LiveTick(config, FixtureDiscovery(scenario), FixtureGates(scenario), actuator, journal,
                     state=state, hold_source=_StaleDupHermeticHoldSource(state, config))
        res = t.run()
        return res, events(self.jpath)

    def test_stale_base_autofix_withholds_a_foreign_prs_heal(self):
        feat_dir, feat_sha = _make_stale_base_repo(self.tmp)
        os.environ["HERD_STALE_DUP_BODY_FILE"] = self._seam_file("body.txt", "no ref here\n")
        self.addCleanup(os.environ.pop, "HERD_STALE_DUP_BODY_FILE", None)
        res, ev = self._tick_live(
            dict(pr=7, sha=feat_sha, worktree=feat_dir, base="main", health="CLEAN", review="PASS",
                 author="bob"),
            {"MERGE_POLICY": "auto", "DEFAULT_BRANCH": "main", "STALE_BASE_AUTOFIX": "on",
             "WATCHER_OWNER": "alice"})
        self.assertEqual(res["outcomes"]["7"], "HOLD")
        self.assertFalse([o for o in ev if o["event"] == "refix_bounce"],
                         "a foreign PR must never be bounced")
        self.assertFalse([o for o in ev if o["event"] == "stale_base_autofix_bounce"],
                         "a foreign PR must never get the resolver dispatched at it")
        withheld = [o for o in ev if o["event"] == "autofix_scope_withheld"]
        self.assertEqual(len(withheld), 1)
        self.assertEqual(withheld[0]["rail"], "stale")

    def test_stale_base_autofix_permits_the_owners_own_pr(self):
        feat_dir, feat_sha = _make_stale_base_repo(self.tmp)
        os.environ["HERD_STALE_DUP_BODY_FILE"] = self._seam_file("body.txt", "no ref here\n")
        self.addCleanup(os.environ.pop, "HERD_STALE_DUP_BODY_FILE", None)
        res, ev = self._tick_live(
            dict(pr=7, sha=feat_sha, worktree=feat_dir, base="main", health="CLEAN", review="PASS",
                 author="alice"),
            {"MERGE_POLICY": "auto", "DEFAULT_BRANCH": "main", "STALE_BASE_AUTOFIX": "on",
             "WATCHER_OWNER": "alice"})
        self.assertEqual(res["outcomes"]["7"], "BLOCK")
        self.assertTrue([o for o in ev if o["event"] == "refix_bounce"])
        self.assertFalse([o for o in ev if o["event"] == "autofix_scope_withheld"])

    def test_autofix_scope_all_bypasses_the_ownership_gate(self):
        feat_dir, feat_sha = _make_stale_base_repo(self.tmp)
        os.environ["HERD_STALE_DUP_BODY_FILE"] = self._seam_file("body.txt", "no ref here\n")
        self.addCleanup(os.environ.pop, "HERD_STALE_DUP_BODY_FILE", None)
        res, ev = self._tick_live(
            dict(pr=7, sha=feat_sha, worktree=feat_dir, base="main", health="CLEAN", review="PASS",
                 author="bob"),
            {"MERGE_POLICY": "auto", "DEFAULT_BRANCH": "main", "STALE_BASE_AUTOFIX": "on",
             "AUTOFIX_SCOPE": "all", "WATCHER_OWNER": "alice"})
        self.assertEqual(res["outcomes"]["7"], "BLOCK")
        self.assertTrue([o for o in ev if o["event"] == "refix_bounce"])

    def test_stale_base_autofix_withholds_on_unresolvable_identity(self):
        # No WATCHER_OWNER configured — force the gh-fallback leg of _resolve_owner to prove genuinely
        # unresolvable (never dependent on whether this machine happens to have an authenticated gh).
        feat_dir, feat_sha = _make_stale_base_repo(self.tmp)
        os.environ["HERD_STALE_DUP_BODY_FILE"] = self._seam_file("body.txt", "no ref here\n")
        self.addCleanup(os.environ.pop, "HERD_STALE_DUP_BODY_FILE", None)
        orig = LR._resolve_owner
        LR._resolve_owner = lambda cfg: ""
        try:
            res, ev = self._tick_live(
                dict(pr=7, sha=feat_sha, worktree=feat_dir, base="main", health="CLEAN", review="PASS",
                     author="alice"),
                {"MERGE_POLICY": "auto", "DEFAULT_BRANCH": "main", "STALE_BASE_AUTOFIX": "on"})
        finally:
            LR._resolve_owner = orig
        self.assertEqual(res["outcomes"]["7"], "HOLD")
        withheld = [o for o in ev if o["event"] == "autofix_scope_withheld"]
        self.assertEqual(len(withheld), 1)
        self.assertEqual(withheld[0]["reason"], "noowner")

    def test_autofix_scope_key_reaches_live_tick_via_config_from_env(self):
        # HERD-601 lesson (see test_stale_base_autofix_reaches_live_tick_via_config_from_env above):
        # a key missing from _CORE_ENV_KEYS/herd-config.sh's export sweep silently never arrives in a
        # real --tick child even when .herd/config sets it. Prove AUTOFIX_SCOPE threads the SAME seam.
        self.addCleanup(os.environ.pop, "AUTOFIX_SCOPE", None)
        os.environ["AUTOFIX_SCOPE"] = "all"
        config = LR._config_from_env()
        self.assertEqual(config.get("AUTOFIX_SCOPE"), "all",
                          "_config_from_env must thread an exported AUTOFIX_SCOPE through")


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
            def _dispatch_review(self, cand, tier_model=""):
                disp_r.append(cand.pr)
                _marker_write(self.state.review_inflight_file(cand), os.getpid())

            def _dispatch_health(self, cand, profile=""):
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

    # ── HERD-567: the python half of the env-suspect port — _collect_env_suspect ────────────────────
    def test_health_collect_journals_env_suspect_from_sidechannel(self):
        """The live worker (_HEALTH_WORKER_SH) drops a `<log>.envsuspect` side-channel the instant it
        classifies a run-1 timeout as env-suspect (see that string's docstring for why the log itself
        is not a reliable channel for this at collect time — a reproduced failure overwrites it). The
        collector must read it, journal `health_env_suspect`, and remove the marker."""
        c = self.cand()
        _marker_write(self.state.health_inflight_file(c), os.getpid(), nonce="n-live")
        with open(self.state.health_dispatch_file(c), "w") as fh:
            fh.write("n-live\tCODEERROR\tnot ok 2 - foo.bats # timeout after 120s\n")
        log = self.state.health_log_file(c)
        os.makedirs(os.path.dirname(log), exist_ok=True)
        with open(log + ".envsuspect", "w") as fh:
            fh.write("not ok 2 - foo.bats # timeout after 120s\n")
        g, _, _ = self._gates()
        self.assertEqual(g.health(c), "CODEERROR")
        rows = [e for e in events(self.journal.path) if e["event"] == "health_env_suspect"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["dir"], c.slug)
        self.assertIn("timeout after 120s", rows[0]["detail"])
        self.assertFalse(os.path.exists(log + ".envsuspect"))     # side-channel consumed, not left behind

    def test_health_collect_without_sidechannel_journals_nothing(self):
        """Byte-identical baseline: ENV_SUSPECT_TIMEOUT off (or on but never classified) means the
        live worker never drops the side-channel file — the collector must not journal anything for a
        plain CODEERROR/FLAKY/CLEAN collect, exactly as before this lever existed."""
        c = self.cand()
        _marker_write(self.state.health_inflight_file(c), os.getpid(), nonce="n-live")
        with open(self.state.health_dispatch_file(c), "w") as fh:
            fh.write("n-live\tCODEERROR\tnot ok 2 - foo.bats\n")
        g, _, _ = self._gates()
        self.assertEqual(g.health(c), "CODEERROR")
        rows = [e for e in events(self.journal.path) if e["event"] == "health_env_suspect"] \
            if os.path.exists(self.journal.path) else []
        self.assertEqual(rows, [])

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


class TestInflightVerifiedLive(unittest.TestCase):
    """HERD-451: a health/merge-result-inflight marker's liveness must be IDENTITY-verified, not bare
    existence — a recycled pid must not wedge the shared HEALTH_CONCURRENCY slot forever. GROUNDED
    2026-07-31: stale ``.health-inflight-*`` markers whose recorded pids had been recycled by the OS
    (twice onto the watcher itself, once onto a `sleep`) were counted live indefinitely, because
    ``_count_live_inflight`` used to trust a bare ``kill -0`` whenever the marker recorded no start-time
    at all — the exact shape of a legacy pre-restart-safe marker."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ.pop("HERD_FAKE_NOW", None)
        os.environ.pop("HEALTH_INFLIGHT_TIMEOUT", None)

    def tearDown(self):
        os.environ.pop("HERD_FAKE_NOW", None)
        os.environ.pop("HEALTH_INFLIGHT_TIMEOUT", None)

    def _marker(self, name, body):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        return path

    def test_no_identity_marker_not_counted_once_expired(self):
        """MUTATION-PROVE: a marker naming a live-but-wrong pid — the exact observed failure — must not
        be counted once its age (via the file-mtime fallback) exceeds HEALTH_INFLIGHT_TIMEOUT. Reverting
        ``_count_live_inflight`` to plain ``_marker_live`` reds this assertion (count reads 1, not 0)."""
        os.environ["HEALTH_INFLIGHT_TIMEOUT"] = "3"
        self._marker(".health-inflight-285-shaNOID", "%d\n" % os.getpid())   # 1-line legacy marker
        os.environ["HERD_FAKE_NOW"] = str(int(time.time()) + 9999)
        self.assertEqual(LR._total_health_inflight(self.tmp), 0)

    def test_no_identity_marker_counted_within_grace_window(self):
        """A FRESH no-identity marker (age ~0) is still trusted — a legit worker whose ps couldn't
        answer start-time at dispatch is not punished immediately."""
        os.environ["HEALTH_INFLIGHT_TIMEOUT"] = "1800"
        self._marker(".health-inflight-286-shaFRESH", "%d\n" % os.getpid())
        self.assertEqual(LR._total_health_inflight(self.tmp), 1)

    def test_merge_result_inflight_prefix_shares_the_same_identity_check(self):
        os.environ["HEALTH_INFLIGHT_TIMEOUT"] = "3"
        self._marker(".merge-result-inflight-99-shaNOID", "%d\n" % os.getpid())
        os.environ["HERD_FAKE_NOW"] = str(int(time.time()) + 9999)
        self.assertEqual(LR._total_health_inflight(self.tmp), 0)

    def test_review_inflight_prefix_unaffected_stays_unbounded_trust(self):
        # HERD-451 scopes the fix to the HEALTH_CONCURRENCY-shared families only — review deliberately
        # keeps the OLD unbounded _marker_live semantics (out of scope; no grounded incident there).
        self._marker(".review-inflight-1-sha1", "%d\n" % os.getpid())
        os.environ["HERD_FAKE_NOW"] = str(int(time.time()) + 999999)
        self.assertEqual(LR._count_live_inflight(self.tmp, ".review-inflight"), 1)

    def test_matching_starttime_stays_trusted_unbounded(self):
        pid = os.getpid()
        st = LR._pid_starttime(pid)
        self._marker(".health-inflight-1-shaLIVE",
                      "%s\n%s\n%s\n" % (pid, st, int(time.time()) - 999999))
        self.assertEqual(LR._total_health_inflight(self.tmp), 1)

    def test_mismatched_starttime_never_counted(self):
        pid = os.getpid()
        self._marker(".health-inflight-1-shaRECY",
                      "%s\nBOGUS START TIME\n%s\n" % (pid, int(time.time())))
        self.assertEqual(LR._total_health_inflight(self.tmp), 0)


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


class TestScopeEnvUnresolved(unittest.TestCase):
    """HERD-653 (GH #769): the missing-env path. Grounded on emberglen — the engine auto-merged a
    teammate's PR while the console correctly showed 'not mine - manual' because WATCHER_SCOPE never
    reached the python core's os.environ. A safety gate must never degrade permissive on a missing
    env var: _config_from_env (the ONLY environment-resolution boundary) must mark this unresolved,
    and the gate must WITHHOLD rather than pass every candidate through."""

    def setUp(self):
        for k in ("WATCHER_SCOPE", "WATCHER_OWNER", "WATCHER_VIEW_AUTHOR"):
            os.environ.pop(k, None)
            self.addCleanup(os.environ.pop, k, None)

    def cands(self):
        return [LiveCandidate(pr=1, sha="a", author="alice"),
                LiveCandidate(pr=2, sha="b", author="bob")]

    def test_config_from_env_marks_missing_scope_unresolved(self):
        config = LR._config_from_env()
        self.assertNotIn("WATCHER_SCOPE", config)
        self.assertEqual(_watcher_scope(config), "unresolved")

    def test_config_from_env_leaves_an_intact_scope_untouched(self):
        # An explicit env value is a RESOLVED (if garbled) config, not a missing one — byte-identical.
        for val, want in (("mine", "mine"), ("all", "all"), ("bogus", "mine")):
            os.environ["WATCHER_SCOPE"] = val
            self.assertEqual(_watcher_scope(LR._config_from_env()), want)
        os.environ.pop("WATCHER_SCOPE", None)

    def test_bare_fixture_config_is_unaffected(self):
        # A raw scenario/test dict never passes through _config_from_env, so its silence about
        # WATCHER_SCOPE still means "solo, byte-identical passthrough" — never fail-closed.
        self.assertEqual(_watcher_scope({}), "mine")

    def test_unresolved_scope_withholds_every_candidate_when_owner_also_unresolvable(self):
        config = LR._config_from_env()
        orig = LR._resolve_owner
        LR._resolve_owner = lambda cfg: ""      # no live gh call in a hermetic test
        try:
            got = _select_candidates(self.cands(), config)
        finally:
            LR._resolve_owner = orig
        self.assertEqual(got, [])

    def test_unresolved_scope_still_keeps_the_seats_own_pr(self):
        # A solo operator with no WATCHER_SCOPE configured still resolves their OWN identity (e.g. via
        # gh) and keeps merging their own PRs — only a foreign-author candidate is newly dropped.
        config = LR._config_from_env()
        orig = LR._resolve_owner
        LR._resolve_owner = lambda cfg: "alice"
        try:
            got = _select_candidates(self.cands(), config)
        finally:
            LR._resolve_owner = orig
        self.assertEqual([c.pr for c in got], ["1"])

    def test_unresolved_scope_journals_once_per_signature_and_self_heals(self):
        tmp = tempfile.mkdtemp()
        jpath = os.path.join(tmp, "j.jsonl")
        journal = LiveJournal(jpath)
        state_dir = os.path.join(tmp, "state")
        os.makedirs(state_dir, exist_ok=True)
        orig = LR._resolve_owner
        LR._resolve_owner = lambda cfg: ""
        try:
            unresolved_config = LR._config_from_env()
            scenario = {"config": unresolved_config, "candidates": []}
            for _ in range(3):
                t = LiveTick(unresolved_config, FixtureDiscovery(scenario), FixtureGates(scenario),
                             DryRunActuator(journal), journal, state=LiveState(state_dir))
                t.run()
            scope_events = [e for e in events(jpath) if e["event"] == "scope_unresolved"]
            self.assertEqual(len(scope_events), 1, "must journal exactly once while unresolved persists")

            # Recovery: an intact scope clears the marker so a LATER regression is loud again.
            os.environ["WATCHER_SCOPE"] = "mine"
            resolved_config = LR._config_from_env()
            scenario2 = {"config": resolved_config, "candidates": []}
            t = LiveTick(resolved_config, FixtureDiscovery(scenario2), FixtureGates(scenario2),
                         DryRunActuator(journal), journal, state=LiveState(state_dir))
            t.run()
            os.environ.pop("WATCHER_SCOPE", None)

            reunresolved_config = LR._config_from_env()
            scenario3 = {"config": reunresolved_config, "candidates": []}
            t = LiveTick(reunresolved_config, FixtureDiscovery(scenario3), FixtureGates(scenario3),
                         DryRunActuator(journal), journal, state=LiveState(state_dir))
            t.run()
            scope_events = [e for e in events(jpath) if e["event"] == "scope_unresolved"]
            self.assertEqual(len(scope_events), 2, "a later regression must journal again after recovery")
        finally:
            LR._resolve_owner = orig


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


class TestMergeQueueConfig(unittest.TestCase):
    """MERGE_QUEUE (§6.3, HERD-273): a STRICT validated key — an unrecognized/absent value is OFF,
    never accidentally on from a typo (mirrors MERGE_RESULT_GATE / MERGE_FAIRNESS)."""

    def test_recognized_truthy_values_are_on(self):
        for v in ("1", "true", "on", "yes", "enable", "enabled", "ON", "True"):
            self.assertTrue(LR._merge_queue_enabled({"MERGE_QUEUE": v}), v)

    def test_unrecognized_or_absent_is_off(self):
        for cfg in ({}, {"MERGE_QUEUE": ""}, {"MERGE_QUEUE": "flase"}, {"MERGE_QUEUE": "0"},
                    {"MERGE_QUEUE": "off"}, {"MERGE_QUEUE": "no"}):
            self.assertFalse(LR._merge_queue_enabled(cfg), cfg)

    def test_queue_on_forces_merge_result_gate_even_when_explicitly_off(self):
        # The "avoid a second contradictory config requirement" posture: MERGE_QUEUE=on implies the
        # SAME per-slot verification MERGE_RESULT_GATE=on would provide, regardless of that key's own
        # (even explicitly-off) value — a project never has to set both coherently.
        state = LiveState(tempfile.mkdtemp())
        journal = LiveJournal(None)
        gates = LiveGates("/no/such/home", state, journal,
                          config={"MERGE_QUEUE": "on", "MERGE_RESULT_GATE": "off"})
        self.assertTrue(gates._merge_result_gate)

    def test_merge_result_gate_alone_does_not_imply_queue(self):
        state = LiveState(tempfile.mkdtemp())
        t = LiveTick({"MERGE_RESULT_GATE": "on"}, FixtureDiscovery({}), FixtureGates({}),
                     DryRunActuator(LiveJournal(None)), LiveJournal(None), state=state)
        self.assertFalse(t._queue)


class TestMergeQueueOrdering(unittest.TestCase):
    """MERGE_QUEUE ordered integration queue (§6.3, HERD-273): at most one blessed candidate applies
    a merge per window — the deterministic front (ascending PR number) — and every other candidate
    that would otherwise merge now HOLDS, even one whose own gates are green. Off is byte-identical."""

    def _run(self, config, candidates, state=None):
        tmp = tempfile.mkdtemp()
        state = state if state is not None else LiveState(os.path.join(tmp, "state"))
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        scen = {"config": config, "candidates": candidates}
        tick = LiveTick(config, FixtureDiscovery(scen), FixtureGates(scen),
                        DryRunActuator(journal), journal, state=state)
        res = tick.run()
        return res, events(journal.path), state

    def _cand(self, pr, **kw):
        kw.setdefault("sha", "s%s" % pr)
        kw.setdefault("review", "PASS")
        kw.setdefault("health", "CLEAN")
        kw.setdefault("worktree", "/wt/%s" % pr)
        return dict(pr=pr, **kw)

    def test_off_is_byte_identical_both_merge_same_tick(self):
        cfg = {"MERGE_POLICY": "auto", "MERGE_QUEUE": "off"}
        cands = [self._cand(7), self._cand(3)]
        res, evs, _ = self._run(cfg, cands)
        self.assertEqual(sorted(res["merged"]), ["3", "7"])
        self.assertFalse([e for e in evs if "queue" in e["event"]])

    def test_on_only_the_lowest_pr_merges_this_window(self):
        # Two candidates both green in the SAME tick: only pr 3 (lower) merges; pr 7 HOLDS even though
        # its own gates are just as green — no cold-start lag (works on each candidate's VERY FIRST
        # tick, unlike a scheme keyed off a lagging cross-tick ledger).
        cfg = {"MERGE_POLICY": "auto", "MERGE_QUEUE": "on"}
        cands = [self._cand(7), self._cand(3)]
        res, evs, _ = self._run(cfg, cands)
        self.assertEqual(res["merged"], ["3"])
        self.assertEqual(res["outcomes"]["7"], "HOLD")
        holds = [e for e in evs if e["event"] == "merge_queue_hold"]
        self.assertEqual(len(holds), 1)
        self.assertEqual(holds[0]["pr"], 7)
        self.assertEqual(str(holds[0]["front_pr"]), "3")

    def test_front_promotes_next_tick_after_merge(self):
        cfg = {"MERGE_POLICY": "auto", "MERGE_QUEUE": "on"}
        state = LiveState(tempfile.mkdtemp())
        cands = [self._cand(7), self._cand(3)]
        res1, _, _ = self._run(cfg, cands, state=state)
        self.assertEqual(res1["merged"], ["3"])
        # pr 3 is gone (merged+reaped); pr 7 is now the only — and therefore front — candidate.
        res2, _, _ = self._run(cfg, [self._cand(7)], state=state)
        self.assertEqual(res2["merged"], ["7"])

    def test_a_stuck_front_blocks_a_ready_later_candidate(self):
        # pr 3 (lower/front) is CODEERROR with no live builder to bounce -> ESCALATE, never reaching
        # MERGE. pr 7 is individually green but must NOT be promoted to fill the window.
        cfg = {"MERGE_POLICY": "auto", "MERGE_QUEUE": "on", "REFIX_MAX_ROUNDS": "0"}
        cands = [self._cand(3, health="CODEERROR", agent_status="dead"), self._cand(7)]
        res, _, _ = self._run(cfg, cands)
        self.assertEqual(res["outcomes"]["3"], "ESCALATE")
        self.assertEqual(res["outcomes"]["7"], "HOLD")
        self.assertEqual(res["merged"], [])

    def test_hv_hold_candidate_is_not_queue_eligible_and_does_not_block(self):
        # A human-verify hold would never auto-merge, so it must not occupy a queue slot (mirrors the
        # fairness freeze's own "a human hold never triggers a freeze" rule).
        cfg = {"MERGE_POLICY": "auto", "MERGE_QUEUE": "on"}
        cands = [self._cand(3, hv_hold=True), self._cand(7)]
        res, _, _ = self._run(cfg, cands)
        self.assertEqual(res["outcomes"]["3"], "HOLD")
        self.assertEqual(res["merged"], ["7"])

    def test_stale_candidate_is_not_queue_eligible_and_does_not_block(self):
        cfg = {"MERGE_POLICY": "auto", "MERGE_QUEUE": "on"}
        cands = [self._cand(3, stale=True), self._cand(7)]
        res, _, _ = self._run(cfg, cands)
        self.assertEqual(res["outcomes"]["3"], "HOLD")
        self.assertEqual(res["merged"], ["7"])

    def test_queue_hold_once_guard_no_duplicate_journal_across_ticks(self):
        cfg = {"MERGE_POLICY": "auto", "MERGE_QUEUE": "on", "REFIX_MAX_ROUNDS": "0"}
        state = LiveState(tempfile.mkdtemp())
        cands = [self._cand(3, health="CODEERROR", agent_status="dead"), self._cand(7)]
        self._run(cfg, cands, state=state)
        _, evs2, _ = self._run(cfg, cands, state=state)
        self.assertFalse([e for e in evs2 if e["event"] == "merge_queue_hold"])

    def test_lone_ready_candidate_merges_immediately_no_lag(self):
        cfg = {"MERGE_POLICY": "auto", "MERGE_QUEUE": "on"}
        res, _, _ = self._run(cfg, [self._cand(9)])
        self.assertEqual(res["merged"], ["9"])

    def test_lever_off_leaves_queue_front_none(self):
        cfg = {"MERGE_POLICY": "auto", "MERGE_QUEUE": "off"}
        state = LiveState(tempfile.mkdtemp())
        tick = LiveTick(cfg, FixtureDiscovery({"candidates": [self._cand(3), self._cand(7)],
                                              "config": cfg}),
                        FixtureGates({"candidates": [self._cand(3), self._cand(7)]}),
                        DryRunActuator(LiveJournal(None)), LiveJournal(None), state=state)
        tick.run()
        self.assertFalse(tick._queue)
        self.assertIsNone(tick._queue_front)

    def test_fairness_and_queue_compose_without_ever_merging_the_non_front(self):
        # Both levers on: FAIRNESS freezes every non-starved sibling (pr 3, the queue front) because
        # pr 9 is starved; QUEUE holds pr 9 because it is not the front. The two levers AND — each may
        # independently veto a merge — and never contradict each other into merging the wrong PR: this
        # tick lands nobody, but nobody lands OUT OF ORDER either.
        cfg = {"MERGE_POLICY": "auto", "MERGE_QUEUE": "on", "MERGE_FAIRNESS": "on"}
        cands = [self._cand(3), self._cand(9, restale_laps=5)]
        res, evs, _ = self._run(cfg, cands)
        self.assertEqual(res["merged"], [])
        self.assertEqual(res["outcomes"]["3"], "HOLD")
        self.assertEqual(res["outcomes"]["9"], "HOLD")
        self.assertTrue([e for e in evs if e["event"] == "merge_fairness_freeze"])
        self.assertFalse([e for e in evs if e["event"] == "merge_queue_hold" and e["pr"] == 3])


class TestCoreSurfaceConfig(unittest.TestCase):
    """CORE_SURFACE_GLOB (§6.5, HERD-577): a GLOB key, not a boolean — empty/absent is the feature
    OFF and any non-empty pattern arms it. Unlike the strict-validated on/off levers there is no
    "typo turns it on" hazard: a pattern is either something the operator wrote or it is nothing."""

    def test_absent_or_empty_is_off(self):
        for cfg in ({}, None, {"CORE_SURFACE_GLOB": ""}, {"CORE_SURFACE_GLOB": "   "}):
            self.assertFalse(LR._core_surface_enabled(cfg), cfg)
            self.assertEqual(LR._core_surface_glob(cfg), "")

    def test_a_pattern_arms_it_and_is_carried_verbatim(self):
        cfg = {"CORE_SURFACE_GLOB": r"^scripts/herd/agent-watch\.sh$"}
        self.assertTrue(LR._core_surface_enabled(cfg))
        self.assertEqual(LR._core_surface_glob(cfg), r"^scripts/herd/agent-watch\.sh$")

    def test_the_key_crosses_into_the_python_child_process(self):
        # HERD-449's bug class: a knob this module reads from os.environ that herd-config.sh does not
        # export is silently the built-in default no matter what .herd/config says. env-export-lint.sh
        # imports this tuple directly, so membership here is what makes the lint cover the key.
        self.assertIn("CORE_SURFACE_GLOB", LR._CORE_ENV_KEYS)

    def test_off_never_reads_a_diff(self):
        # The ship-dormant claim at its narrowest: with no glob the gate answers SKIP without ever
        # resolving a worktree, so an unarmed project pays nothing — not even a subprocess.
        gates = LiveGates("/no/such/home", LiveState(tempfile.mkdtemp()), LiveJournal(None),
                          config={})
        cand = LiveCandidate(pr="1", sha="s1", worktree="/definitely/not/a/worktree")
        self.assertEqual(gates.core_surface(cand), "SKIP")
        self.assertEqual(gates.core_surface_paths(cand), ())
        self.assertFalse(gates.core_surface_is_core(cand))


class TestCoreSurfaceWalk(unittest.TestCase):
    """The decide-path leg (§6.5 leg 1). Driven through FixtureGates' scripted `core_surface`, so the
    walk's own composition is under test independently of the sim dispatch (that half is proven end
    to end by tests/test-core-surface.sh)."""

    def _run(self, config, candidates, state=None):
        tmp = tempfile.mkdtemp()
        if state is None:
            sdir = os.path.join(tmp, "state")
            os.makedirs(sdir)                      # a real dir: the refix ledger + markers are the proof
            state = LiveState(sdir)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        scen = {"config": config, "candidates": candidates}
        tick = LiveTick(config, FixtureDiscovery(scen), FixtureGates(scen),
                        DryRunActuator(journal), journal, state=state)
        res = tick.run()
        return res, events(journal.path), state

    def _cand(self, pr, **kw):
        kw.setdefault("sha", "s%s" % pr)
        kw.setdefault("review", "PASS")
        kw.setdefault("health", "CLEAN")
        kw.setdefault("worktree", "/wt/%s" % pr)
        return dict(pr=pr, **kw)

    _ON = {"MERGE_POLICY": "auto", "CORE_SURFACE_GLOB": r"^core/"}

    def test_a_green_scorecard_merges_and_is_journaled_once(self):
        res, evs, _ = self._run(self._ON, [self._cand(4, core_surface="PASS")])
        self.assertEqual(res["merged"], ["4"])
        gate = [e for e in evs if e["event"] == "core_surface_gate"]
        self.assertEqual([e["result"] for e in gate], ["pass"])

    def test_a_red_scorecard_never_merges_and_bounces_on_its_own_rail(self):
        res, evs, state = self._run(self._ON, [self._cand(5, core_surface="FAIL")])
        self.assertEqual(res["merged"], [])
        self.assertEqual([e["result"] for e in evs if e["event"] == "core_surface_gate"], ["fail"])
        bounces = [e for e in evs if e["event"] == "refix_bounce"]
        self.assertEqual([e["rule"] for e in bounces], ["core-surface-sim"])
        # The ledger row rides the SEPARATE `coresim` kind, so a sim red can never spend the health
        # rail's budget (and a later health red still gets its own full REFIX_MAX_ROUNDS).
        rows = LR.D.parse_refix_ledger(LR._read_refix_ledger(state.dir))
        self.assertEqual(LR.D.refix_rail_count(rows, "5", "coresim"), 1)
        self.assertEqual(LR.D.refix_rail_count(rows, "5", "health"), 0)

    def test_wait_holds_the_candidate_pending_without_reaching_the_reviewer(self):
        res, evs, _ = self._run(self._ON, [self._cand(6, core_surface="WAIT", review="BLOCK")])
        self.assertEqual(res["outcomes"]["6"], "PENDING")
        # review=BLOCK would have bounced had the walk reached the reviewer — it must not have.
        self.assertFalse([e for e in evs if e["event"] == "refix_bounce"])
        self.assertTrue([e for e in evs if e["event"] == "core_surface_pending"])

    def test_skip_is_indistinguishable_from_the_feature_being_off(self):
        # A NON-CORE diff under an ARMED glob and the SAME candidate with the lever off must produce
        # identical outcomes and identical (zero) core_surface_* events — leg 1's byte-identical claim.
        on_res, on_evs, _ = self._run(self._ON, [self._cand(7, core_surface="SKIP")])
        off_res, off_evs, _ = self._run({"MERGE_POLICY": "auto"}, [self._cand(7)])
        self.assertEqual(on_res["merged"], off_res["merged"], ["7"])
        for evs in (on_evs, off_evs):
            self.assertFalse([e for e in evs if str(e["event"]).startswith("core_surface")])


class TestCoreSurfaceSerialize(unittest.TestCase):
    """Core-diff serialization (§6.5 leg 2): among CORE candidates that would merge, only the
    deterministic front lands per window — and NON-core candidates are never held by it."""

    def _run(self, config, candidates, state=None):
        tmp = tempfile.mkdtemp()
        if state is None:
            sdir = os.path.join(tmp, "state")
            os.makedirs(sdir)                      # a real dir: the wait marker IS the render proof
            state = LiveState(sdir)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        scen = {"config": config, "candidates": candidates}
        tick = LiveTick(config, FixtureDiscovery(scen), FixtureGates(scen),
                        DryRunActuator(journal), journal, state=state)
        return tick.run(), events(journal.path), state, tick

    def _core(self, pr):
        return dict(pr=pr, sha="s%s" % pr, review="PASS", health="CLEAN",
                    worktree="/wt/%s" % pr, core_surface="PASS")

    def _plain(self, pr):
        return dict(pr=pr, sha="s%s" % pr, review="PASS", health="CLEAN",
                    worktree="/wt/%s" % pr, core=False, core_surface="SKIP")

    _ON = {"MERGE_POLICY": "auto", "CORE_SURFACE_GLOB": r"^core/"}

    def test_only_the_lowest_numbered_core_pr_merges_this_window(self):
        res, evs, state, _ = self._run(self._ON, [self._core(8), self._core(3)])
        self.assertEqual(res["merged"], ["3"])
        self.assertEqual(res["outcomes"]["8"], "HOLD")
        holds = [e for e in evs if e["event"] == "core_surface_hold"]
        self.assertEqual(len(holds), 1)
        self.assertEqual(holds[0]["pr"], 8)
        self.assertEqual(str(holds[0]["front_pr"]), "3")
        # The render side channel the console row reads — a hold nobody can see is the stall this
        # leg must never become.
        self.assertTrue(os.path.exists(state.core_wait_file("8", "s8")))
        self.assertFalse(os.path.exists(state.core_wait_file("3", "s3")))

    def test_a_non_core_sibling_is_never_held_by_a_core_front(self):
        res, evs, _, _ = self._run(self._ON, [self._core(9), self._plain(2)])
        # pr 2 is NOT core, so the core mutex never applies to it: both land, and only the single
        # core candidate (which IS the core front) merges through the leg at all.
        self.assertEqual(sorted(res["merged"]), ["2", "9"])
        self.assertFalse([e for e in evs if e["event"] == "core_surface_hold"])

    def test_the_held_pr_promotes_once_the_front_lands(self):
        state = LiveState(tempfile.mkdtemp())
        res1, _, _, _ = self._run(self._ON, [self._core(8), self._core(3)], state=state)
        self.assertEqual(res1["merged"], ["3"])
        # pr 3 merged + reaped; pr 8 is now the only core candidate, hence the front.
        res2, _, _, _ = self._run(self._ON, [self._core(8)], state=state)
        self.assertEqual(res2["merged"], ["8"])
        # …and its stale wait marker is cleared the moment it is no longer held.
        self.assertFalse(os.path.exists(state.core_wait_file("8", "s8")))

    def test_lever_off_leaves_no_core_front_and_merges_both(self):
        res, evs, _, tick = self._run({"MERGE_POLICY": "auto"}, [self._core(8), self._core(3)])
        self.assertFalse(tick._core_surface)
        self.assertIsNone(tick._core_front)
        self.assertEqual(sorted(res["merged"]), ["3", "8"])
        self.assertFalse([e for e in evs if str(e["event"]).startswith("core_surface")])


class TestCoreSurfaceSupersession(unittest.TestCase):
    """_supersede_stale must cancel a stale core-surface sim exactly like the other rails (§6.1). It
    matters MORE here than anywhere else: a sandbox sim forks whole repos, it is the most expensive
    worker on the tree, and it holds the single project-wide core-sim slot — a doomed one left
    running starves every other core candidate while proving a sha the PR has already moved past."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.jpath = os.path.join(self.tmp, "j.jsonl")
        os.environ["HERD_JOURNAL_NOW"] = "2026-08-10T00:00:00Z"

    def tearDown(self):
        os.environ.pop("HERD_JOURNAL_NOW", None)

    def test_stale_core_sim_terminated_reaped_and_journaled(self):
        journal = LiveJournal(self.jpath)
        state = LiveState(self.tmp)
        # A DEAD marker for a superseded sha — _terminate_worker treats a dead/recycled marker as
        # already-gone, so the cancel is exercised without spawning a real process.
        old = state.core_surface_inflight_file("77", "aaaaaa1")
        _marker_write(old, 999999)
        for p in (state.core_surface_dispatch_file("77", "aaaaaa1"),
                  state.core_surface_log_file("77", "aaaaaa1"),
                  state.core_wait_file("77", "aaaaaa1")):
            open(p, "w").close()
        t = LiveTick({"MERGE_POLICY": "observe", "CORE_SURFACE_GLOB": r"^core/"},
                     None, None, DryRunActuator(journal), journal, state=state)
        t._supersede_stale([LiveCandidate(pr=77, sha="newsha")])
        self.assertFalse(os.path.exists(old))
        self.assertFalse(os.path.exists(state.core_surface_dispatch_file("77", "aaaaaa1")))
        self.assertFalse(os.path.exists(state.core_surface_log_file("77", "aaaaaa1")))
        self.assertFalse(os.path.exists(state.core_wait_file("77", "aaaaaa1")))
        sup = [e for e in events(self.jpath)
               if e["event"] == "gate_superseded" and e.get("rail") == "core_surface"]
        self.assertEqual(len(sup), 1)
        self.assertEqual(sup[0]["old_sha"], "aaaaaa1")
        self.assertEqual(sup[0]["new_sha"], "newsha")

    def test_off_lever_leaves_nothing_to_supersede(self):
        # With no .core-surface-* marker ever written (the lever-off default) the glob is empty and
        # this rail journals nothing — byte-inert.
        journal = LiveJournal(self.jpath)
        state = LiveState(self.tmp)
        t = LiveTick({"MERGE_POLICY": "observe"}, None, None, DryRunActuator(journal), journal,
                     state=state)
        t._supersede_stale([LiveCandidate(pr=78, sha="newsha")])
        # Byte-inert at its strictest: the journal file is not even CREATED, because nothing had
        # anything to say. (A missing file and an empty one are the same claim here.)
        evs = events(self.jpath) if os.path.exists(self.jpath) else []
        self.assertFalse([e for e in evs
                          if e["event"] == "gate_superseded" and e.get("rail") == "core_surface"])


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
        marker = self.state._sha_path(".health-inflight", 5, "aaaaaa1")
        _marker_write(marker, p.pid)                       # records the worker's session (line 4)
        # scratch the worker left behind, keyed to the OLD sha, must be reaped too.
        for f in (self.state.health_dispatch_file_sha(5, "aaaaaa1"),
                  self.state.health_result_file_sha(5, "aaaaaa1")):
            open(f, "w").close()
        self._tick()._supersede_stale([LiveCandidate(5, "newsha")])
        self.assertFalse(self._alive(p.pid))              # the doomed worker is dead
        self.assertFalse(os.path.exists(marker))          # marker reaped
        self.assertFalse(os.path.exists(self.state.health_dispatch_file_sha(5, "aaaaaa1")))
        gs = [o for o in self._events() if o["event"] == "gate_superseded"]
        self.assertEqual(len(gs), 1)
        self.assertEqual((gs[0]["rail"], gs[0]["old_sha"], gs[0]["new_sha"], gs[0]["action"]),
                         ("health", "aaaaaa1", "newsha", "session_kill"))

    # ── review rail: a superseded reviewer is terminated + its stamped pane retired ──
    def test_stale_reviewer_terminated_pane_retired_and_journaled(self):
        p = self._worker()
        marker = self.state._sha_path(".review-inflight", 8, "aaaaaa8")
        _marker_write(marker, p.pid)
        with open(self.state.review_registry_file_sha(8, "aaaaaa8"), "w") as fh:
            fh.write("%s review-pane-42\n" % p.pid)        # the reviewer's STAMPED pane
        self._tick()._supersede_stale([LiveCandidate(8, "new8")])
        self.assertFalse(self._alive(p.pid))
        self.assertFalse(os.path.exists(marker))
        self.assertFalse(os.path.exists(self.state.review_registry_file_sha(8, "aaaaaa8")))
        gs = [o for o in self._events() if o["event"] == "gate_superseded" and o["rail"] == "review"]
        self.assertEqual(len(gs), 1)
        self.assertEqual(gs[0]["action"], "pane_retired")
        self.assertEqual(gs[0]["pane"], "review-pane-42")   # the stamp is carried into the forensic record

    # ── the CURRENT sha's worker is NEVER touched ──
    def test_current_sha_worker_is_preserved(self):
        p = self._worker()
        marker = self.state._sha_path(".health-inflight", 5, "ccccccc")
        _marker_write(marker, p.pid)
        self._tick()._supersede_stale([LiveCandidate(5, "ccccccc")])
        self.assertTrue(self._alive(p.pid))               # still running — its sha IS the head
        self.assertTrue(os.path.exists(marker))
        self.assertEqual([o for o in self._events() if o["event"] == "gate_superseded"], [])

    # ── a foreign PR's stale worker is not touched by an unrelated candidate ──
    def test_only_matching_pr_is_superseded(self):
        p = self._worker()
        marker = self.state._sha_path(".health-inflight", 7, "aaaaaa7")
        _marker_write(marker, p.pid)
        self._tick()._supersede_stale([LiveCandidate(5, "newsha")])   # candidate is PR 5, not 7
        self.assertTrue(self._alive(p.pid))
        self.assertTrue(os.path.exists(marker))

    # ── a dead/recycled marker is reaped with no signal, no false gate_superseded ──
    def test_dead_marker_reaped_without_signal(self):
        marker = self.state._sha_path(".health-inflight", 5, "aaaaaaa")
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
        marker = self.state._sha_path(".health-inflight", 9, "aaaaaa9")
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
        _marker_write(self.state._sha_path(".health-inflight", 3, "aaaaaa3"), p.pid)
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


class TestMarkerShaParsing(unittest.TestCase):
    """HERD-471: a marker's sha field is sliced off the KNOWN ``<prefix>-<pr>-`` stem and shape-checked
    ([0-9a-f]{7,40}) by the shared ``_parse_marker_sha`` helper — not a blind ``rsplit("-", 1)`` on the
    basename's last hyphen. A real git sha never contains a hyphen, so any hyphenated (or otherwise
    non-hex) sha field names a malformed marker; the old rsplit code silently truncated it to whatever
    followed the LAST hyphen — a plausible-looking but WRONG sha — instead of recognizing it as
    unparseable. The fix must never do that: a malformed name is skipped, loud-journaled, never yielded."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.jpath = os.path.join(self.tmp, "j.jsonl")
        self.journal = LiveJournal(self.jpath)
        self.state = LiveState(self.tmp)

    def _events(self):
        return events(self.jpath) if os.path.exists(self.jpath) else []

    def test_well_formed_hex_sha_parses_byte_identical(self):
        marker = self.state._p(".health-inflight-5-1a2b3c4")
        open(marker, "w").close()
        self.assertEqual(
            LR._parse_marker_sha(marker, ".health-inflight", 5, journal=self.journal), "1a2b3c4")
        self.assertEqual(self._events(), [])   # no malformed-skip noise for a well-formed marker

    # ── MUTATION PROOF: a hyphenated non-hex sha is skipped, never truncated into a wrong-but-plausible
    #    value. Under the pre-fix rsplit("-", 1)[-1], this basename would silently yield "def456" — a
    #    fragment of the real field — instead of being caught as malformed.
    def test_hyphenated_non_hex_sha_is_skipped_not_corrupted(self):
        marker = self.state._p(".health-inflight-5-abc123-def456")
        open(marker, "w").close()
        got = LR._parse_marker_sha(marker, ".health-inflight", 5, journal=self.journal)
        self.assertIsNone(got)
        self.assertNotEqual(got, "def456")      # never the corrupted rsplit fragment
        evs = self._events()
        self.assertEqual(len(evs), 1)
        self.assertEqual(evs[0]["event"], "marker_sha_malformed")
        self.assertEqual(evs[0]["path"], marker)
        self.assertEqual(evs[0]["prefix"], ".health-inflight")
        self.assertEqual(evs[0]["pr"], 5)

    def test_malformed_skip_without_journal_does_not_raise(self):
        marker = self.state._p(".health-inflight-5-not-a-sha")
        open(marker, "w").close()
        self.assertIsNone(LR._parse_marker_sha(marker, ".health-inflight", 5))   # no journal passed

    def test_stale_inflight_yields_only_the_well_formed_marker(self):
        good = self.state._p(".health-inflight-5-1a2b3c4")
        bad = self.state._p(".health-inflight-5-abc123-def456")
        open(good, "w").close()
        open(bad, "w").close()
        found = list(self.state.stale_inflight(".health-inflight", 5, "9999999", journal=self.journal))
        self.assertEqual(found, [(good, "1a2b3c4")])
        malformed = [e for e in self._events() if e["event"] == "marker_sha_malformed"]
        self.assertEqual(len(malformed), 1)
        self.assertEqual(malformed[0]["path"], bad)


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

    def test_discovery_pools_the_pr_body(self):
        # HERD-671 leg 1: the SAME graphql round-trip now carries `body`, so the hold layer's
        # per-PR `gh pr view --json body` never has to run for a candidate this call discovered.
        pool = tempfile.mkdtemp()
        os.environ["TREES"] = pool
        _make_worktree(pool, "pooled-body")
        payload = {"data": {"repository": {"pullRequests": {"nodes": [
            {"number": 451, "headRefName": "feat/pooled-body",
             "headRefOid": "deadbeef", "baseRefName": "main", "mergeStateStatus": "CLEAN",
             "reviewDecision": "", "body": "HUMAN-VERIFY:\n- smoke test\n",
             "author": {"login": "brian"},
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
        self.assertEqual(cands[0].hv_body, "HUMAN-VERIFY:\n- smoke test\n")
        self.assertTrue(cands[0].hv_body_pooled)

    def test_discovery_pools_an_absent_body_as_empty_string(self):
        # A PR with no body at all: GraphQL returns `body: null`; the pool must still mark it
        # POOLED (a real "no body" answer), not fall through to a live per-PR re-read.
        pool = tempfile.mkdtemp()
        os.environ["TREES"] = pool
        _make_worktree(pool, "no-body")
        payload = {"data": {"repository": {"pullRequests": {"nodes": [
            {"number": 452, "headRefName": "feat/no-body", "headRefOid": "cafef00d",
             "baseRefName": "main", "mergeStateStatus": "CLEAN", "reviewDecision": "",
             "body": None, "author": {"login": "brian"},
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
        self.assertEqual(cands[0].hv_body, "")
        self.assertTrue(cands[0].hv_body_pooled)


class TestPrFetchUnifyCache(unittest.TestCase):
    """HERD-675: unify the per-tick PR-list fetch. Python is the FETCH OWNER — `discover_via_graphql`
    writes its raw roster to a tick-scoped, seat-stamped cache the bash render leg's `_prs_fetch_tick`
    (git-pr.sh) reads instead of paying its own `gh pr list` round-trip. Proves the lever both ways
    (AGENTS.md): PR_FETCH_UNIFY off is a hard no-op (byte-identical — no file is ever written); on
    writes an atomic, correctly-shaped cache a bash consumer can project fields out of."""

    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in
                        ("TREES", "WORKTREES_DIR", "PR_FETCH_UNIFY", "HERD_ENGINE_SEAT_ID")}
        for k in self._saved:
            os.environ.pop(k, None)
        self.pool = tempfile.mkdtemp()
        os.environ["TREES"] = self.pool

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    _PAYLOAD = {"data": {"repository": {"pullRequests": {"nodes": [
        {"number": 500, "title": "unify the fetch", "headRefName": "feat/unify",
         "headRefOid": "cafefeed", "baseRefName": "main", "mergeable": "MERGEABLE",
         "mergeStateStatus": "CLEAN", "reviewDecision": "REVIEW_REQUIRED", "isDraft": False,
         "body": "HUMAN-VERIFY:\n- nothing\n", "author": {"login": "brian"},
         "assignees": {"nodes": [{"login": "sam"}]}, "labels": {"nodes": [{"name": "bug"}]}},
        {"number": 501, "title": "wip draft", "headRefName": "feat/wip", "headRefOid": "deadc0de",
         "baseRefName": "main", "mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN",
         "reviewDecision": "", "isDraft": True, "body": "", "author": {"login": "brian"},
         "assignees": {"nodes": []}, "labels": {"nodes": []}},
    ]}}}}

    def _discover(self):
        class _Stub:
            def run(self, *a, **k):
                class R:
                    stdout = json.dumps(TestPrFetchUnifyCache._PAYLOAD)
                return R()
        orig = LR.subprocess
        LR.subprocess = _Stub()
        try:
            return LR.discover_via_graphql(repo="owner/name")
        finally:
            LR.subprocess = orig

    def test_gate_default_off(self):
        self.assertFalse(LR._pr_fetch_unify_enabled())
        for v in ("off", "OFF", "", "0", "no", "garbage"):
            os.environ["PR_FETCH_UNIFY"] = v
            self.assertFalse(LR._pr_fetch_unify_enabled(), v)

    def test_gate_recognized_on_spellings(self):
        for v in ("on", "ON", "true", "TRUE", "1", "yes", "YES"):
            os.environ["PR_FETCH_UNIFY"] = v
            self.assertTrue(LR._pr_fetch_unify_enabled(), v)

    def test_off_never_writes_a_cache_file(self):
        # SHIP-DORMANT: the default (unset) lever must leave the pool byte-identical — no new file.
        self._discover()
        self.assertEqual(os.listdir(self.pool), [])

    def test_on_writes_an_atomic_cache_with_no_leftover_tmp_file(self):
        os.environ["PR_FETCH_UNIFY"] = "on"
        os.environ["HERD_ENGINE_SEAT_ID"] = "seat-alpha"
        self._discover()
        entries = os.listdir(self.pool)
        self.assertEqual(entries, [".pr-list-cache-seat-alpha.json"])   # no ".NNNN.tmp" survivor

    def test_cache_includes_drafts_unfiltered(self):
        # Bash's own `gh pr list` fetch never filters drafts at fetch time either — only downstream —
        # so the cache must carry BOTH PRs even though discover_via_graphql's own `cands` return value
        # (LiveCandidate list) skips the draft.
        os.environ["PR_FETCH_UNIFY"] = "on"
        cands = self._discover()
        self.assertEqual([c.pr for c in cands], ["500"])   # the draft never becomes a candidate

        with open(LR._pr_fetch_cache_path(), encoding="utf-8") as fh:
            doc = json.load(fh)
        self.assertEqual(sorted(p["number"] for p in doc["prs"]), [500, 501])

    def test_cache_row_shapes_match_gh_pr_list_json(self):
        # author/assignees/labels must be gh's OWN REST-json shapes (flat objects/lists), not
        # GraphQL's {"nodes": [...]} connection wrapper — bash's login()/has_label() readers
        # (agent-watch.sh) assume the flat shape.
        os.environ["PR_FETCH_UNIFY"] = "on"
        self._discover()
        with open(LR._pr_fetch_cache_path(), encoding="utf-8") as fh:
            doc = json.load(fh)
        row = next(p for p in doc["prs"] if p["number"] == 500)
        self.assertEqual(row["title"], "unify the fetch")
        self.assertEqual(row["headRefName"], "feat/unify")
        self.assertEqual(row["headRefOid"], "cafefeed")
        self.assertEqual(row["mergeable"], "MERGEABLE")
        self.assertEqual(row["mergeStateStatus"], "CLEAN")
        self.assertEqual(row["baseRefName"], "main")
        self.assertEqual(row["reviewDecision"], "REVIEW_REQUIRED")
        self.assertIs(row["isDraft"], False)
        self.assertEqual(row["body"], "HUMAN-VERIFY:\n- nothing\n")
        self.assertEqual(row["author"], {"login": "brian"})
        self.assertEqual(row["assignees"], [{"login": "sam"}])
        self.assertEqual(row["labels"], [{"name": "bug"}])

    def test_written_at_is_current_epoch(self):
        os.environ["PR_FETCH_UNIFY"] = "on"
        before = int(time.time())
        self._discover()
        after = int(time.time())
        with open(LR._pr_fetch_cache_path(), encoding="utf-8") as fh:
            doc = json.load(fh)
        self.assertTrue(before <= doc["written_at"] <= after, doc["written_at"])

    def test_cache_path_is_seat_stamped_and_sanitized(self):
        os.environ["HERD_ENGINE_SEAT_ID"] = "host.name:1234/weird chars"
        path = LR._pr_fetch_cache_path()
        self.assertTrue(path.startswith(self.pool))
        self.assertNotIn("/", os.path.basename(path).replace(".json", "")[len(".pr-list-cache-"):])
        self.assertNotIn(" ", path)

    def test_cache_path_falls_back_to_solo_seat(self):
        os.environ.pop("HERD_ENGINE_SEAT_ID", None)
        self.assertEqual(os.path.basename(LR._pr_fetch_cache_path()), ".pr-list-cache-solo.json")

    def test_cache_path_empty_without_a_pool(self):
        os.environ.pop("TREES", None)
        os.environ.pop("WORKTREES_DIR", None)
        self.assertEqual(LR._pr_fetch_cache_path(), "")

    def test_write_failure_is_fail_soft(self):
        # An unwritable pool must never raise out of discover_via_graphql — the candidate walk this
        # call produces is the load-bearing return value; a cache write is a pure side effect.
        os.environ["PR_FETCH_UNIFY"] = "on"
        os.environ["TREES"] = os.path.join(self.pool, "does", "not", "exist")
        cands = self._discover()   # must not raise
        self.assertEqual([c.pr for c in cands], ["500"])


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
            def _dispatch_health(self, cand, profile=""):
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
            def _dispatch_health(self, cand, profile=""):
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


class TestHealthTrustBuilder(unittest.TestCase):
    """HERD-531/555: the sha-matched builder-local HEALTH TRUST read, ported from
    scripts/herd/health-trust.sh's ``herd_health_trust_check`` into the Python health dispatch that
    actually runs today (the old bash reader, agent-watch.sh:_healthcheck_gate, has been dead code
    since the P5b port). Mirrors tests/test-health-trust.sh's disqualifier matrix; the WRITE side (the
    provenance record) stays bash-authored, so these tests plant records by hand exactly as
    healthcheck.sh's ``herd_health_trust_write`` would."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.trees = os.path.join(self.tmp, "trees")
        os.makedirs(self.trees, exist_ok=True)
        self.wt = os.path.join(self.tmp, "wt")
        self.sha = _git_init_repo(self.wt)
        self.wt_abs = os.path.realpath(self.wt)

    def _rec_file(self, sha):
        return os.path.join(self.trees, ".health-provenance-%s" % sha)

    def _log_file(self, sha):
        return os.path.join(self.trees, ".health-provenance-log-%s" % sha)

    def _plant(self, sha, wt, prof, outcome, dur, prov, state, epoch, digest="-"):
        """Write a FORMAT VERSION 2 (HERD-560) record directly. ``digest`` defaults to ``"-"`` — the
        right shape for every disqualifier this class proves gets caught BEFORE the digest check ever
        runs; a test that needs to reach TRUSTED supplies a real digest via :meth:`_write_log`."""
        with open(self._rec_file(sha), "w", encoding="utf-8") as fh:
            fh.write("\t".join(["2", sha, wt, prof, outcome, str(dur), prov, state, str(epoch),
                                digest]) + "\n")

    def _plant_old(self, sha, wt, prof, outcome, dur, prov, state, epoch):
        """Write a PRE-HERD-560 (8-field, no version, no digest) record — the exact shape the engine
        wrote before this hardening — to prove it now reads as ABSENT, never half-parsed."""
        with open(self._rec_file(sha), "w", encoding="utf-8") as fh:
            fh.write("\t".join([sha, wt, prof, outcome, str(dur), prov, state, str(epoch)]) + "\n")

    def _write_log(self, sha, content):
        """Write the companion suite-log file for ``sha`` and return its sha256 hex digest — the same
        pairing herd_health_trust_write produces on a CLEAN run."""
        path = self._log_file(sha)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return LR._health_trust_digest_file(path)

    def _commit_epoch(self, sha=None):
        out = subprocess.check_output(
            ["git", "-C", self.wt, "show", "-s", "--format=%ct", sha or self.sha])
        return int(out.decode().strip())

    # ── _health_trust_on: the lever ───────────────────────────────────────────────────────────────
    def test_lever_truthy_set_matches_other_gate_keys(self):
        for v in ("1", "true", "on", "yes", "enable", "enabled", "ON", "Enabled"):
            self.assertTrue(LR._health_trust_on({"HEALTH_TRUST_BUILDER": v}), v)

    def test_lever_absent_off_and_typo_all_read_off(self):
        for cfg in ({}, {"HEALTH_TRUST_BUILDER": ""}, {"HEALTH_TRUST_BUILDER": "off"},
                    {"HEALTH_TRUST_BUILDER": "0"}, {"HEALTH_TRUST_BUILDER": "bogus"}, None):
            self.assertFalse(LR._health_trust_on(cfg), cfg)

    # ── _health_trust_file ────────────────────────────────────────────────────────────────────────
    def test_trust_file_empty_when_either_arg_empty(self):
        self.assertEqual(LR._health_trust_file("", self.sha), "")
        self.assertEqual(LR._health_trust_file(self.trees, ""), "")

    # ── _health_trust_check: the happy path + every disqualifier ─────────────────────────────────
    def test_no_record_is_not_trusted(self):
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertEqual(reason, "no record for sha")

    def test_no_sha_is_not_trusted(self):
        prov, reason = LR._health_trust_check(self.trees, "", self.wt)
        self.assertEqual(prov, "")
        self.assertEqual(reason, "no head sha")

    def test_clean_heavy_record_from_clean_tree_is_trusted(self):
        epoch = self._commit_epoch() + 60
        digest = self._write_log(self.sha, "the real suite log body")
        self._plant(self.sha, self.wt_abs, "heavy", "CLEAN", 1234, "builder-local", "clean", epoch,
                    digest)
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "builder-local")
        self.assertEqual(reason, "")

    def test_non_clean_outcome_not_trusted(self):
        epoch = self._commit_epoch() + 60
        for outcome in ("CODEERROR", "DATAENV"):
            self._plant(self.sha, self.wt_abs, "heavy", outcome, 1, "builder-local", "clean", epoch)
            prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
            self.assertEqual(prov, "")
            self.assertIn("outcome=%s" % outcome, reason)

    def test_light_profile_record_not_trusted(self):
        epoch = self._commit_epoch() + 60
        self._plant(self.sha, self.wt_abs, "light", "CLEAN", 1, "builder-local", "clean", epoch)
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertIn("profile=light", reason)

    def test_watcher_provenance_never_trusted(self):
        """Trust must always trace back to a real builder-local heavy suite — a record the watcher
        itself authored (a prior TRUSTED light smoke) can never justify the next trusted skip."""
        epoch = self._commit_epoch() + 60
        self._plant(self.sha, self.wt_abs, "heavy", "CLEAN", 1, "watcher", "clean", epoch)
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertIn("provenance=watcher", reason)

    def test_dirty_tree_state_not_trusted(self):
        epoch = self._commit_epoch() + 60
        self._plant(self.sha, self.wt_abs, "heavy", "CLEAN", 1, "builder-local", "dirty", epoch)
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertIn("tree_state=dirty", reason)

    def test_worktree_mismatch_not_trusted(self):
        epoch = self._commit_epoch() + 60
        self._plant(self.sha, os.path.join(self.wt_abs, "elsewhere"), "heavy", "CLEAN", 1,
                    "builder-local", "clean", epoch)
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertIn("record worktree", reason)

    def test_record_older_than_commit_not_trusted(self):
        ct = self._commit_epoch()
        self._plant(self.sha, self.wt_abs, "heavy", "CLEAN", 1, "builder-local", "clean", ct - 60)
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertEqual(reason, "record predates the commit")

    def test_unresolvable_commit_not_trusted(self):
        nogit = os.path.join(self.tmp, "not-a-repo")
        os.makedirs(nogit, exist_ok=True)
        epoch = self._commit_epoch() + 60
        self._plant(self.sha, os.path.realpath(nogit), "heavy", "CLEAN", 1, "builder-local",
                    "clean", epoch)
        prov, reason = LR._health_trust_check(self.trees, self.sha, nogit)
        self.assertEqual(prov, "")

    def test_stale_sha_never_trusts_the_new_head(self):
        """A record planted for the FIRST commit never trusts a SECOND, later commit — the new sha
        has no record of its own (each record is keyed by its own filename)."""
        epoch = self._commit_epoch() + 60
        self._plant(self.sha, self.wt_abs, "heavy", "CLEAN", 1, "builder-local", "clean", epoch)
        open(os.path.join(self.wt, "g"), "w").write("y")
        subprocess.run(["git", "-C", self.wt, "add", "g"], check=True)
        subprocess.run(["git", "-C", self.wt, "commit", "-q", "-m", "two"], check=True)
        sha2 = subprocess.check_output(["git", "-C", self.wt, "rev-parse", "HEAD"]).decode().strip()
        self.assertNotEqual(sha2, self.sha)
        prov, reason = LR._health_trust_check(self.trees, sha2, self.wt)
        self.assertEqual(prov, "")
        self.assertEqual(reason, "no record for sha")

    def test_body_sha_mismatch_is_malformed_not_guessed_at(self):
        """A record whose BODY disagrees with its own filename (a hand-forged/corrupt file) is
        refused as stale, never trusted on the strength of the filename alone."""
        epoch = self._commit_epoch() + 60
        other = "b" * 40
        with open(self._rec_file(self.sha), "w", encoding="utf-8") as fh:
            fh.write("\t".join(["2", other, self.wt_abs, "heavy", "CLEAN", "1", "builder-local",
                                "clean", str(epoch), "-"]) + "\n")
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertEqual(reason, "stale sha in record")

    def test_truncated_record_is_malformed(self):
        with open(self._rec_file(self.sha), "w", encoding="utf-8") as fh:
            fh.write("only\ttwo\n")
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertEqual(reason, "malformed record")

    def test_empty_record_is_malformed(self):
        open(self._rec_file(self.sha), "w").close()
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertEqual(reason, "malformed record")

    # ── HERD-560: FORMAT VERSION 2 — old-format / unrecognized-version reads as ABSENT ─────────────
    def test_pre_hardening_eight_field_record_reads_as_absent(self):
        epoch = self._commit_epoch() + 60
        self._plant_old(self.sha, self.wt_abs, "heavy", "CLEAN", 1, "builder-local", "clean", epoch)
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertEqual(reason, "old-format record (absent)")

    def test_unrecognized_version_reads_as_absent_not_an_error(self):
        epoch = self._commit_epoch() + 60
        digest = self._write_log(self.sha, "some log")
        self._plant(self.sha, self.wt_abs, "heavy", "CLEAN", 1, "builder-local", "clean", epoch, digest)
        with open(self._rec_file(self.sha), encoding="utf-8") as fh:
            line = fh.read()
        with open(self._rec_file(self.sha), "w", encoding="utf-8") as fh:
            fh.write("99" + line[len("2"):])
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertEqual(reason, "old-format record (absent)")

    # ── HERD-560: DIGEST — a CLEAN record is re-verified against its companion suite log ───────────
    def test_digest_mismatch_never_trusted(self):
        epoch = self._commit_epoch() + 60
        digest = self._write_log(self.sha, "the real suite log body")
        self._plant(self.sha, self.wt_abs, "heavy", "CLEAN", 1, "builder-local", "clean", epoch, digest)
        prov, _reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "builder-local")   # fixture precondition: trusted before tampering
        with open(self._log_file(self.sha), "w", encoding="utf-8") as fh:
            fh.write("tampered")
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertEqual(reason, "digest mismatch")

    def test_missing_companion_log_never_trusted(self):
        epoch = self._commit_epoch() + 60
        digest = self._write_log(self.sha, "a log that will be deleted")
        self._plant(self.sha, self.wt_abs, "heavy", "CLEAN", 1, "builder-local", "clean", epoch, digest)
        os.remove(self._log_file(self.sha))
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertEqual(reason, "no suite log for record")

    def test_clean_record_with_no_digest_never_trusted(self):
        """A CLEAN record whose digest field is still the "-" placeholder (a writer that had no log
        to hash) is refused — a digest with nothing behind it proves nothing."""
        epoch = self._commit_epoch() + 60
        self._plant(self.sha, self.wt_abs, "heavy", "CLEAN", 1, "builder-local", "clean", epoch)
        prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        self.assertEqual(prov, "")
        self.assertEqual(reason, "no suite log for record")

    # ── HERD-560: BOUNDED AGE — a record older than HEALTH_TRUST_MAX_AGE_SECS is refused ───────────
    def test_stale_by_age_never_trusted(self):
        epoch = self._commit_epoch() + 60
        digest = self._write_log(self.sha, "aging suite log body")
        self._plant(self.sha, self.wt_abs, "heavy", "CLEAN", 1, "builder-local", "clean", epoch, digest)
        old = os.environ.get("HERD_FAKE_NOW")
        os.environ["HERD_FAKE_NOW"] = str(epoch + 100)
        try:
            os.environ["HEALTH_TRUST_MAX_AGE_SECS"] = "50"
            try:
                prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
            finally:
                os.environ.pop("HEALTH_TRUST_MAX_AGE_SECS", None)
        finally:
            if old is None:
                os.environ.pop("HERD_FAKE_NOW", None)
            else:
                os.environ["HERD_FAKE_NOW"] = old
        self.assertEqual(prov, "")
        self.assertEqual(reason, "record older than 50s (stale by age)")

    def test_default_age_bound_does_not_reject_a_fresh_record(self):
        epoch = self._commit_epoch() + 60
        digest = self._write_log(self.sha, "fresh suite log body")
        self._plant(self.sha, self.wt_abs, "heavy", "CLEAN", 1, "builder-local", "clean", epoch, digest)
        old = os.environ.get("HERD_FAKE_NOW")
        os.environ["HERD_FAKE_NOW"] = str(epoch + 100)   # 100s old, far under the 21600s default
        try:
            prov, reason = LR._health_trust_check(self.trees, self.sha, self.wt)
        finally:
            if old is None:
                os.environ.pop("HERD_FAKE_NOW", None)
            else:
                os.environ["HERD_FAKE_NOW"] = old
        self.assertEqual(prov, "builder-local")
        self.assertEqual(reason, "")

    # ── wired into LiveGates.health(): lever off is byte-identical ───────────────────────────────
    def _gates(self, config=None, jpath=None):
        state = LiveState(state_dir=self.trees)
        journal = LiveJournal(jpath or os.path.join(self.tmp, "j.jsonl"))
        return LiveGates("/nonexistent-home", state, journal, config=config or {})

    def test_lever_off_never_calls_trust_check(self):
        """Poison _health_trust_check: with the lever off (the default), health() must never even
        open the provenance file — the same byte-identical proof TestMergeResultGateByteIdentical
        uses for MERGE_RESULT_GATE."""
        cand = LiveCandidate(pr=1, sha=self.sha, slug="feat-x", worktree=self.wt)
        g = self._gates(config={})
        self.assertFalse(g._health_trust_on)
        orig = LR._health_trust_check
        LR._health_trust_check = lambda *a, **k: (_ for _ in ()).throw(
            AssertionError("trust check reached with HEALTH_TRUST_BUILDER off"))
        try:
            dispatched = []
            g._dispatch_health = lambda cand, profile="": dispatched.append((cand.pr, profile))
            self.assertEqual(g.health(cand), WAIT)
        finally:
            LR._health_trust_check = orig
        self.assertEqual(dispatched, [("1", "")])

    def test_lever_on_trusted_record_dispatches_light_and_journals(self):
        epoch = self._commit_epoch() + 60
        digest = self._write_log(self.sha, "gate happy-path suite log")
        self._plant(self.sha, self.wt_abs, "heavy", "CLEAN", 1, "builder-local", "clean", epoch, digest)
        jpath = os.path.join(self.tmp, "j.jsonl")
        g = self._gates(config={"HEALTH_TRUST_BUILDER": "on"}, jpath=jpath)
        self.assertTrue(g._health_trust_on)
        cand = LiveCandidate(pr=1, sha=self.sha, slug="feat-x", worktree=self.wt)
        dispatched = []
        g._dispatch_health = lambda cand, profile="": dispatched.append((cand.pr, profile))
        self.assertEqual(g.health(cand), WAIT)
        self.assertEqual(dispatched, [("1", "--light")])
        rows = [e for e in events(jpath) if e["event"] == "health_trusted"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(str(rows[0]["pr"]), "1")
        self.assertEqual(rows[0]["provenance"], "builder-local")
        self.assertEqual(rows[0]["profile"], "light")

    def test_lever_on_no_record_dispatches_full_and_journals_nothing(self):
        jpath = os.path.join(self.tmp, "j.jsonl")
        g = self._gates(config={"HEALTH_TRUST_BUILDER": "on"}, jpath=jpath)
        cand = LiveCandidate(pr=1, sha=self.sha, slug="feat-x", worktree=self.wt)
        dispatched = []
        g._dispatch_health = lambda cand, profile="": dispatched.append((cand.pr, profile))
        self.assertEqual(g.health(cand), WAIT)
        self.assertEqual(dispatched, [("1", "")])
        rows = [e for e in events(jpath)] if os.path.exists(jpath) else []
        self.assertEqual([e for e in rows if e["event"] == "health_trusted"], [])

    # ── the REAL _dispatch_health: profile forwarded as the worker's final argv element ───────────
    def test_dispatch_health_forwards_profile_as_final_argv(self):
        state = LiveState(state_dir=self.trees)
        gates = LiveGates("/nonexistent-home", state, LiveJournal(os.path.join(self.tmp, "j2.jsonl")))
        cand = LiveCandidate(pr=7, sha="deadbeef", slug="feat-x", worktree=self.wt)
        sub = TestHealthDispatchFreshness._RecordingHealthSub()
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            gates._dispatch_health(cand, "--light")
        finally:
            LR.subprocess = orig
        self.assertIsNotNone(sub.argv)
        self.assertEqual(sub.argv[-1], "--light")
        # the nonce (matching the live marker) is now second-to-last, not last, when a profile rides.
        inflight = state.health_inflight_file(cand)
        self.assertEqual(_marker_nonce(inflight), sub.argv[-2])

    def test_dispatch_health_no_profile_argv_unchanged(self):
        state = LiveState(state_dir=self.trees)
        gates = LiveGates("/nonexistent-home", state, LiveJournal(os.path.join(self.tmp, "j3.jsonl")))
        cand = LiveCandidate(pr=7, sha="deadbeef", slug="feat-x", worktree=self.wt)
        sub = TestHealthDispatchFreshness._RecordingHealthSub()
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            gates._dispatch_health(cand)
        finally:
            LR.subprocess = orig
        inflight = state.health_inflight_file(cand)
        self.assertEqual(sub.argv[-1], _marker_nonce(inflight))


class TestMainHealthSlotPriority(unittest.TestCase):
    """HERD-359 regression: PR health must never starve main-health when HEALTH_CONCURRENCY=1.

    _main_health_pending() is the sentinel; LiveGates.health() reserves a slot when it is True."""

    def setUp(self):
        self._orig_env = {}
        for k in ("MAIN_HEALTH_TICK", "MAIN", "PROJECT_ROOT", "HEALTH_CONCURRENCY"):
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

    def test_health_queued_is_journaled_once_per_sha(self):
        """HERD-459: "queued behind a full slot budget" is a standing condition, not a per-tick event —
        journal it once per (pr, sha, phase), and re-arm on a new sha."""
        os.environ["MAIN_HEALTH_TICK"] = "on"
        self._main_repo()
        _make_worktree(self.tmp, "feat-q")
        jpath = os.path.join(self.tmp, "jq.jsonl")
        gates = self._make_gates(jpath)
        wt = os.path.join(self.tmp, "feat-q")
        for _ in range(5):
            self.assertEqual(gates.health(LiveCandidate(pr=9, sha="q1", slug="feat-q", worktree=wt)),
                             WAIT)
        with open(jpath, encoding="utf-8") as fh:
            evs = [json.loads(l) for l in fh if l.strip()]
        self.assertEqual(len([e for e in evs if e.get("event") == "health_queued"]), 1,
                         "5 queued ticks on one sha must journal 1 health_queued")
        gates.health(LiveCandidate(pr=9, sha="q2", slug="feat-q", worktree=wt))
        with open(jpath, encoding="utf-8") as fh:
            evs = [json.loads(l) for l in fh if l.strip()]
        self.assertEqual(len([e for e in evs if e.get("event") == "health_queued"]), 2,
                         "a new sha re-arms the phase marker")

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

    # ── HERD-449: HEALTH_CONCURRENCY resolved through the SAME os.environ seam a correctly-exported
    # herd-config.sh feeds the `live_runtime --tick` child (_config_from_env) — not a hand-built config
    # dict, which is what a proper shell export makes possible and an unexported var silently defeats.

    def test_health_concurrency_env_value_dispatches_despite_main_pending(self):
        """HEALTH_CONCURRENCY=3, resolved via _config_from_env (the env seam HERD-449 fixed, not a
        literal dict): with main-health pending and ZERO PR-health in flight, effective_max = 3 - 1 =
        2 > 0, so PR health actually DISPATCHES this tick. Under the pre-fix bug (the export missing,
        HEALTH_CONCURRENCY always read as its built-in default of 1) effective_max would have been
        1 - 1 = 0, and NO PR health could ever dispatch while main-health was pending — the live
        deadlock this item closes."""
        os.environ["MAIN_HEALTH_TICK"] = "on"
        os.environ["HEALTH_CONCURRENCY"] = "3"
        self._main_repo()
        d = _make_worktree(self.tmp, "feat-3")
        cand = LiveCandidate(pr=3, sha="cafef00d", slug="feat-3", worktree=d)
        jpath = os.path.join(self.tmp, "j3.jsonl")
        state = LiveState(state_dir=self.tmp)
        state.dir = self.tmp
        journal = LiveJournal(jpath)
        config = LR._config_from_env()
        self.assertEqual(config.get("HEALTH_CONCURRENCY"), "3",
                          "_config_from_env must thread an exported HEALTH_CONCURRENCY through")
        gates = LiveGates("/nonexistent-home", state, journal, config=config)
        result = gates.health(cand)
        self.assertEqual(result, WAIT)   # health() always returns WAIT (async); assert on WHAT happened
        with open(jpath, encoding="utf-8") as fh:
            evs = [json.loads(l) for l in fh if l.strip()]
        queued = [e for e in evs if e.get("event") == "health_queued"]
        self.assertEqual(queued, [], "with room in the slot (limit 3 - 1 main reservation = 2 > 0 "
                                      "inflight), PR health must NOT be queued")
        started = [e for e in evs if e.get("event") == "healthcheck_started"]
        self.assertEqual(len(started), 1, "PR health must actually DISPATCH while main-health is "
                                           "pending once HEALTH_CONCURRENCY leaves room in the slot")

    def test_health_concurrency_env_value_in_queued_journal_limit_field(self):
        """HEALTH_CONCURRENCY=3, resolved via _config_from_env: with 2 OTHER PR healths already in
        flight (effective_max = 3 - 1 = 2, inflight >= limit), a 3rd candidate is queued — and the
        journaled health_queued event's 'limit' field reads 3, not the broken always-1 default."""
        os.environ["MAIN_HEALTH_TICK"] = "on"
        os.environ["HEALTH_CONCURRENCY"] = "3"
        self._main_repo()
        state = LiveState(state_dir=self.tmp)
        state.dir = self.tmp
        jpath = os.path.join(self.tmp, "j4.jsonl")
        journal = LiveJournal(jpath)
        config = LR._config_from_env()
        gates = LiveGates("/nonexistent-home", state, journal, config=config)
        # Plant 2 live PR-health in-flight markers (other candidates) so the global inflight count is 2.
        for i in range(2):
            other = LiveCandidate(pr=100 + i, sha="other%d" % i, slug="other-%d" % i,
                                  worktree=_make_worktree(self.tmp, "other-%d" % i))
            _marker_write(state.health_inflight_file(other), os.getpid())
        d = _make_worktree(self.tmp, "feat-4")
        cand = LiveCandidate(pr=4, sha="deadbeef", slug="feat-4", worktree=d)
        result = gates.health(cand)
        self.assertEqual(result, WAIT)
        with open(jpath, encoding="utf-8") as fh:
            evs = [json.loads(l) for l in fh if l.strip()]
        queued = [e for e in evs if e.get("event") == "health_queued"]
        self.assertEqual(len(queued), 1, "health_queued must be journaled once the slot is full")
        self.assertEqual(queued[0].get("limit"), 3,
                          "the journaled limit must read the CONFIGURED HEALTH_CONCURRENCY (3), not "
                          "the engine core's broken always-1 fallback (HERD-449)")
        self.assertEqual(queued[0].get("inflight"), 2)

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


class TestLiveReapDefersOnLiveWorktree(LiveCase):
    """HERD-444: the LIVE actuator's reap() must not force-remove a worktree whose builder is
    confirmed WORKING (a fresh `herdr agent list` read) or whose tree carries real uncommitted work (a
    fresh `git status --porcelain`) — see LiveActuator.reap's incident comment. Hermetic: subprocess is
    fully stubbed via _RecordingSubWithRoster, no gh/git/herdr ever runs for real."""

    def _actuator(self, sub):
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        return LiveActuator("/nonexistent-home", LiveJournal(self.jpath))

    def test_reap_defers_when_agent_confirmed_working(self):
        sub = _RecordingSubWithRoster(agent_status="working")
        act = self._actuator(sub)
        cand = LiveCandidate(1, "deadbeef", slug="slug1", worktree="/wt/1")
        self.assertFalse(act.reap(cand))
        names = [o["event"] for o in events(self.jpath)]
        self.assertNotIn("reap", names)
        deferred = [o for o in events(self.jpath) if o["event"] == "reap_deferred"]
        self.assertEqual(len(deferred), 1)
        self.assertEqual(deferred[0]["reason"], "merged-worktree-live")
        self.assertFalse(any(c[:3] == ["git", "worktree", "remove"] for c in sub.calls),
                          "a WORKING builder's worktree must never reach `git worktree remove`")

    def test_reap_defers_when_worktree_dirty(self):
        sub = _RecordingSubWithRoster(agent_status="idle", dirty=True)
        act = self._actuator(sub)
        cand = LiveCandidate(1, "deadbeef", slug="slug1", worktree="/wt/1")
        self.assertFalse(act.reap(cand))
        self.assertFalse(any(c[:3] == ["git", "worktree", "remove"] for c in sub.calls))

    def test_reap_proceeds_when_idle_and_clean(self):
        sub = _RecordingSubWithRoster(agent_status="idle", dirty=False)
        act = self._actuator(sub)
        cand = LiveCandidate(1, "deadbeef", slug="slug1", worktree="/wt/1")
        self.assertTrue(act.reap(cand))
        names = [o["event"] for o in events(self.jpath)]
        self.assertIn("reap", names)
        self.assertNotIn("reap_deferred", names)
        self.assertTrue(any(c[:3] == ["git", "worktree", "remove"] for c in sub.calls))

    def test_reap_proceeds_when_roster_absent(self):
        # Fail-soft: an empty/unreadable roster is BLINDNESS, never evidence of a working agent — it
        # must never itself block a reap (mirrors _reap_agent_working's bash contract).
        sub = _RecordingSubWithRoster(agent_status="", dirty=False)
        act = self._actuator(sub)
        cand = LiveCandidate(1, "deadbeef", slug="slug1", worktree="/wt/1")
        self.assertTrue(act.reap(cand))


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

    def test_resolve_adapter_filters_kwargs_to_what_each_kinds_constructor_accepts(self):
        # review advisory (HERD-399 round 4): the kwarg vocabulary is the UNION across kinds — a
        # generic caller resolving doc-apply with the git-pr kwarg set (state/repo/actuator/discovery)
        # must get a working adapter, never a TypeError; and vice versa with doc-apply's own extras.
        journal = LiveJournal(None)
        doc = WU.resolve_adapter("doc-apply", home="/h", journal=journal, state=object(),
                                 config={"MAIN": "/m"}, repo="o/r", gates=None,
                                 actuator=object(), discovery=object())
        self.assertIsInstance(doc, WU.DocApplyAdapter)
        self.assertIs(doc.journal, journal)              # shared kwargs still land
        self.assertEqual(doc.config, {"MAIN": "/m"})
        gitpr = WU.resolve_adapter("git-pr", journal=journal, config={},
                                   worktrees_dir="/tmp/x", land=object())
        self.assertIsInstance(gitpr, WU.GitPrAdapter)
        self.assertIs(gitpr.journal, journal)

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
    os.makedirs(os.path.join(main, "docs", "sub"), exist_ok=True)
    with open(os.path.join(main, "docs", "x.md"), "w", encoding="utf-8") as fh:
        fh.write("orig\n")
    with open(os.path.join(main, "docs", "sub", "y.md"), "w", encoding="utf-8") as fh:
        fh.write("sub\n")   # gives directory-path tests a real "docs/sub" tree to target
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

    def test_open_at_same_revision_is_idempotent_even_when_already_applied(self):
        # review fix (HERD-399 round 3): the prior condition also required state != "applied", which
        # INVERTED the documented idempotent-on-same-revision contract — re-opening an ALREADY-APPLIED
        # unit at the same revision reset its state back to "open", re-opening a completed unit.
        tmp = tempfile.mkdtemp()
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=LiveJournal(None))
        unit = adapter.open({"slug": "s9", "worktree": "", "revision": "rev9", "paths": ["docs/a.md"]})
        path = adapter._manifest_path("s9")
        obj = WU._read_manifest(path)
        obj["state"] = "applied"
        WU._write_manifest(path, obj)
        self.assertEqual(adapter.list_open(), [])   # correctly excluded

        reopened = adapter.open({"slug": "s9", "worktree": "", "revision": "rev9",
                                 "paths": ["docs/a.md"]})
        self.assertEqual(reopened.unit_id, unit.unit_id)
        still = WU._read_manifest(path)
        self.assertEqual(still["state"], "applied")   # NOT reset back to "open"
        self.assertEqual(adapter.list_open(), [])   # still excluded after the re-open

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

    def test_gate_respects_operator_doc_apply_path_glob_as_the_allowlist(self):
        # DOC_APPLY_PATH_GLOB (HERD-399 round 3) — a DEDICATED key, not a DOCS_ONLY_GLOB reuse (round 2
        # discovered reusing DOCS_ONLY_GLOB is unsafe in BOTH matching directions: unanchored search
        # widens it, anchored match breaks it for that key's own real-world suffix-shaped patterns).
        # Matched via re.match (prefix-anchored) — a custom operator pattern is a PREFIX by construction,
        # never an un-anchored substring search, so "notes/" here allows "notes/readme.txt" without also
        # (wrongly) allowing something like "src/notes/x".
        tmp = tempfile.mkdtemp()
        scenario = {"candidates": [dict(pr="doc-slug", sha="rev-x", health="CLEAN", review="PASS")]}
        adapter, unit = self._gated_unit(tmp, LiveJournal(None), FixtureGates(scenario),
                                         ["notes/readme.txt"],
                                         config={"DOC_APPLY_PATH_GLOB": r"^(docs|notes)/"})
        self.assertEqual(adapter.gate(unit, unit.revision).status, "pass")

    def test_gate_operator_doc_apply_path_glob_is_prefix_anchored_not_substring_search(self):
        # The exact footgun round 1 flagged: an operator pattern without its own "^" must NOT match a
        # path merely because the substring occurs somewhere inside it.
        tmp = tempfile.mkdtemp()
        scenario = {"candidates": [dict(pr="doc-slug", sha="rev-x", health="CLEAN", review="PASS")]}
        adapter, unit = self._gated_unit(tmp, LiveJournal(None), FixtureGates(scenario),
                                         ["src/docs/x.py"], config={"DOC_APPLY_PATH_GLOB": r"docs/"})
        self.assertEqual(adapter.gate(unit, unit.revision).status, "block")

    def test_gate_a_docs_only_glob_shaped_for_review_tier_no_longer_breaks_doc_apply(self):
        # The round-2 regression this repo's OWN .herd/config would have hit: DOCS_ONLY_GLOB="[.](md|txt)"
        # is a suffix-shaped egrep pattern for review-tier classification — under the round-2 fix
        # (re.match against a REUSED DOCS_ONLY_GLOB) this could never match "docs/x.md" at all, refusing
        # every doc-apply unit. Now that the two keys are fully decoupled, DOCS_ONLY_GLOB in config has
        # NO effect on doc-apply's allowlist — the hardcoded ^docs/ default still applies.
        tmp = tempfile.mkdtemp()
        scenario = {"candidates": [dict(pr="doc-slug", sha="rev-x", health="CLEAN", review="PASS")]}
        adapter, unit = self._gated_unit(tmp, LiveJournal(None), FixtureGates(scenario),
                                         ["docs/x.md"], config={"DOCS_ONLY_GLOB": r"[.](md|txt)"})
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
        # review advisory (HERD-399 round 5): the at-most-once short-circuit was the ONE apply exit
        # with no journal event — it now emits a noop like every other exit.
        noops = [e for e in events(os.path.join(tmp, "j.jsonl"))
                 if e.get("event") == "doc_apply_apply_noop"]
        self.assertEqual([e.get("reason") for e in noops], ["already-applied"])

    def test_apply_no_diff_result_is_persisted_so_it_never_reruns_forever(self):
        # review advisory (HERD-399): "already" (nothing to land) must ALSO flip manifest state, or
        # the unit stays in list_open and re-probes checkout+status every tick forever.
        tmp = tempfile.mkdtemp()
        main, _worktree, _revision = _doc_apply_fixture(tmp)
        init_sha = subprocess.check_output(["git", "-C", main, "rev-parse", "HEAD"]).decode().strip()
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        # declared at MAIN's OWN init revision -> checking it out changes nothing (no diff to land).
        unit = adapter.open({"slug": "no-diff-slug", "worktree": "", "revision": init_sha,
                             "paths": ["docs/x.md"], "title": "t", "body": "b"})
        self.assertEqual(len(adapter.list_open()), 1)
        result = adapter.apply(unit, init_sha)
        self.assertEqual(result.status, "already")
        self.assertEqual(adapter.list_open(), [])   # persisted -> never re-offered
        # ...and the no-diff terminal is NO LONGER a silent state transition (review fix, HERD-399
        # round 3): a genuine "already landed" now journals a doc_apply_apply_noop event, so an
        # open -> applied flip always leaves exactly one trace on this path just like every other exit.
        noops = [e for e in events(os.path.join(tmp, "j.jsonl"))
                 if e.get("event") == "doc_apply_apply_noop"]
        self.assertEqual(len(noops), 1)
        self.assertEqual(noops[0].get("reason"), "no diff to land")

    # ── review BLOCK fix, round 3 (HERD-399): a locally-committed-but-never-pushed apply must NEVER
    #    be silently reclassified as "already"/"applied" ──────────────────────────────────────────
    def test_second_apply_after_a_leave_in_place_exit_never_marks_applied_until_actually_pushed(self):
        """The core composition bug the review caught: LiveDocApply's two deliberate leave-in-place
        exits (detached-head / head-moved) commit LOCALLY without pushing. A prior fix already proved
        neither exit resets that commit away; this proves the NEXT apply() call doesn't then mistake
        the resulting clean working tree for proof the change reached origin."""
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        bare = os.path.join(tmp, "origin.git")
        subprocess.run(["git", "-C", main, "remote", "set-url", "origin", "/no/such/path"], check=True)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "doc-slug", "worktree": worktree, "revision": revision,
                             "paths": ["docs/x.md"], "title": "t", "body": "b"})

        real_head = WU._git_head
        main_calls = {"n": 0}

        def fake_head(path):
            if path == main:
                main_calls["n"] += 1
                if main_calls["n"] >= 2:
                    return "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
            return real_head(path)

        with mock.patch.object(WU, "_git_head", side_effect=fake_head):
            first = adapter.apply(unit, revision)
        self.assertEqual(first.status, "error")
        self.assertEqual(first.reason, "push-rejected-head-moved")
        self.assertEqual(len(adapter.list_open()), 1)   # NEVER marked applied
        local_log = subprocess.check_output(
            ["git", "-C", main, "log", "--oneline"]).decode().strip().splitlines()
        self.assertEqual(len(local_log), 2)   # init + our commit — real, but unpushed

        # A bare "apply again with a broken remote" retry must ALSO refuse — never silently "already".
        second = adapter.apply(unit, revision)
        self.assertEqual(second.status, "error")
        self.assertEqual(second.reason, "committed-locally-but-unpushed")
        self.assertEqual(len(adapter.list_open()), 1)   # still never marked applied

        # "the transient issue is now resolved" — point the remote back at the real origin and retry.
        subprocess.run(["git", "-C", main, "remote", "set-url", "origin", bare], check=True)
        third = adapter.apply(unit, revision)
        self.assertEqual(third.status, "applied")
        origin_head = subprocess.check_output(["git", "-C", bare, "rev-parse", "main"]).decode().strip()
        main_head = subprocess.check_output(["git", "-C", main, "rev-parse", "HEAD"]).decode().strip()
        self.assertEqual(origin_head, main_head)   # NOW genuinely landed
        self.assertEqual(adapter.list_open(), [])   # correctly marked applied ONLY now

        # ...and EVERY exit was journaled (review fix, HERD-399 round 3: silence was the bug class —
        # the leave-in-place, the never-pushed refusal, and the eventual real landing each leave a trace,
        # and NO "already"/noop event was ever emitted, because it was never a genuine no-diff landing).
        reasons = [e.get("reason") for e in events(os.path.join(tmp, "j.jsonl"))]
        kinds = [e.get("event") for e in events(os.path.join(tmp, "j.jsonl"))]
        self.assertIn("push-rejected-head-moved", reasons)       # tick 1 leave-in-place, journaled
        self.assertIn("committed-locally-but-unpushed", reasons)  # tick 2 refusal, journaled
        self.assertIn("apply", kinds)                             # tick 3 real landing, journaled
        self.assertNotIn("doc_apply_apply_noop", kinds)          # never a silent "already" masquerade

    # ── review advisory, round 3 (HERD-399): apply() must never mutate the caller's WorkUnit ───────
    def test_apply_does_not_mutate_the_callers_unit_artifact(self):
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        # a raw path that NORMALIZES to something different ("docs/./x.md" -> "docs/x.md") so an
        # in-place mutation to the normalized form would be observable.
        unit = adapter.open({"slug": "doc-slug", "worktree": worktree, "revision": revision,
                             "paths": ["docs/./x.md"], "title": "t", "body": "b"})
        before_paths = list(unit.artifact["paths"])
        result = adapter.apply(unit, revision)
        self.assertEqual(result.status, "applied")
        self.assertEqual(unit.artifact["paths"], before_paths)   # never mutated in place

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

    # ── review fix (HERD-399): ".." path traversal must never clear the allowlist ─────────────────
    def test_path_normalization_rejects_absolute_and_root_escaping_paths(self):
        # Genuinely unsafe: absolute, or normalizes to something ABOVE the repo root.
        self.assertIsNone(WU._safe_manifest_path("/etc/passwd"))
        self.assertIsNone(WU._safe_manifest_path("../docs/x.md"))
        self.assertIsNone(WU._safe_manifest_path("docs/../../.herd/config"))   # normalizes to "../.herd/config"
        self.assertIsNone(WU._safe_manifest_path(""))
        # Safe: normalizes to a canonical relative path — "escapes" docs/ but stays inside the repo,
        # so it is NOT unsafe by itself; it is the allowlist PATTERN match (below) that refuses it.
        self.assertEqual(WU._safe_manifest_path("docs/../src/foo.py"), "src/foo.py")
        self.assertEqual(WU._safe_manifest_path("docs/x.md"), "docs/x.md")
        self.assertEqual(WU._safe_manifest_path("docs/./x.md"), "docs/x.md")

    def test_path_allowed_rejects_traversal_even_though_the_raw_string_starts_with_docs(self):
        # The exact bypass the review flagged: "docs/../src/foo.py" string-starts with "docs/", so an
        # un-normalized check would wrongly clear it.
        self.assertFalse(WU._path_allowed("docs/../src/foo.py", {}))
        self.assertFalse(WU._path_allowed("docs/../../.herd/config", {}))
        self.assertTrue(WU._path_allowed("docs/x.md", {}))

    def test_gate_blocks_a_traversal_path_disguised_as_a_docs_path(self):
        tmp = tempfile.mkdtemp()
        jpath = os.path.join(tmp, "j.jsonl")
        adapter, unit = self._gated_unit(tmp, LiveJournal(jpath), None, ["docs/../src/foo.py"])
        self.assertEqual(adapter.gate(unit, unit.revision).status, "block")

    def test_apply_lands_nothing_for_a_traversal_path_even_bypassing_the_gate(self):
        """Defense in depth: apply() must independently refuse a traversal path even if a caller
        skipped gate() entirely — proven at the git level (src/ is never touched, no commit lands)."""
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        os.makedirs(os.path.join(main, "src"), exist_ok=True)
        with open(os.path.join(main, "src", "s.py"), "w", encoding="utf-8") as fh:
            fh.write("orig-src\n")
        subprocess.run(["git", "-C", main, "add", "src/s.py"], check=True)
        subprocess.run(["git", "-C", main, "commit", "-q", "-m", "add src"], check=True)
        subprocess.run(["git", "-C", main, "push", "-q", "origin", "main"], check=True)
        # give the WORKTREE the same src/s.py at a different revision, plus its own docs change
        subprocess.run(["git", "-C", worktree, "fetch", "-q", "origin", "main"], check=True)
        subprocess.run(["git", "-C", worktree, "merge", "-q", "origin/main"], check=True)
        os.makedirs(os.path.join(worktree, "src"), exist_ok=True)
        with open(os.path.join(worktree, "src", "s.py"), "w", encoding="utf-8") as fh:
            fh.write("smuggled\n")
        subprocess.run(["git", "-C", worktree, "add", "src/s.py"], check=True)
        subprocess.run(["git", "-C", worktree, "commit", "-q", "-m", "smuggle"], check=True)
        smuggle_rev = subprocess.check_output(["git", "-C", worktree, "rev-parse", "HEAD"]).decode().strip()

        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "smuggle-slug", "worktree": worktree, "revision": smuggle_rev,
                             "paths": ["docs/../src/s.py"], "title": "t", "body": "b"})
        result = adapter.apply(unit, smuggle_rev)
        self.assertEqual(result.status, "refused")
        with open(os.path.join(main, "src", "s.py"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "orig-src\n")   # untouched — the traversal never reached git

        # AND: even calling the land layer directly (skipping the adapter's own check entirely) refuses.
        land = WU.LiveDocApply(journal, config={"MAIN": main})
        raw_unit = WU.WorkUnit(unit_id="doc-apply:smuggle-slug", kind="doc-apply", slug="smuggle-slug",
                               revision=smuggle_rev,
                               artifact={"worktree": worktree, "paths": ["docs/../src/s.py"]})
        direct = land.apply(raw_unit)
        self.assertEqual(direct.status, "refused")
        with open(os.path.join(main, "src", "s.py"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "orig-src\n")

    # ── review advisory (HERD-399): never silently discard uncommitted local edits under MAIN ─────
    def test_apply_refuses_when_main_has_dirty_local_changes_under_the_target_paths(self):
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        with open(os.path.join(main, "docs", "x.md"), "w", encoding="utf-8") as fh:
            fh.write("uncommitted-local-edit\n")
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "doc-slug", "worktree": worktree, "revision": revision,
                             "paths": ["docs/x.md"], "title": "t", "body": "b"})
        result = adapter.apply(unit, revision)
        self.assertEqual(result.status, "error")
        with open(os.path.join(main, "docs", "x.md"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "uncommitted-local-edit\n")   # never discarded

    # ── review advisory (HERD-399): a directory-shaped path cannot express a deletion — fail closed ─
    def test_apply_refuses_a_directory_shaped_manifest_path(self):
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "dir-slug", "worktree": worktree, "revision": revision,
                             "paths": ["docs/sub"], "title": "t", "body": "b"})
        result = adapter.apply(unit, revision)
        self.assertEqual(result.status, "refused")
        self.assertEqual(result.reason, "directory-path-not-supported")
        log = subprocess.check_output(["git", "-C", main, "log", "--oneline"]).decode().strip().splitlines()
        self.assertEqual(len(log), 1)   # nothing landed

    def test_apply_refuses_directory_shaped_path_even_with_no_worktree_declared(self):
        # review fix, round 2: the guard used to live INSIDE `if worktree:`, so a manifest with a blank
        # worktree field skipped it entirely — exactly the silent-under-apply case it exists to close.
        # main and the builder worktree share the same object store, so the check must (and now does)
        # work off `main` alone, with no worktree field required.
        tmp = tempfile.mkdtemp()
        main, _worktree, revision = _doc_apply_fixture(tmp)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "dir-slug-2", "worktree": "", "revision": revision,
                             "paths": ["docs/sub"], "title": "t", "body": "b"})
        result = adapter.apply(unit, revision)
        self.assertEqual(result.status, "refused")
        self.assertEqual(result.reason, "directory-path-not-supported")
        log = subprocess.check_output(["git", "-C", main, "log", "--oneline"]).decode().strip().splitlines()
        self.assertEqual(len(log), 1)   # nothing landed

    # ── review BLOCK fix, round 4 (HERD-399): a WILDCARD manifest path is refused at BOTH surfaces ──
    def test_wildcard_manifest_path_is_refused_at_gate_and_apply_never_a_silent_under_apply(self):
        """The round-4 composition: "docs/*" cleared the allowlist, blinded the NON-recursive ls-tree
        tree-guard (a glob matches no root-tree entry -> guard says False), then matched RECURSIVELY at
        checkout — and a scoped checkout can only add/update, so a file DELETED at <revision> silently
        survived while apply recorded a clean landing (verified by the reviewer end-to-end). Manifest
        paths are literal file paths, period: any pathspec wildcard (* ? [) is refused loudly at gate
        AND apply, proven against the reviewer's exact delete-plus-rewrite scenario."""
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        # the reviewer's scenario: the worktree revision DELETES docs/x.md and rewrites docs/sub/y.md
        subprocess.run(["git", "-C", worktree, "rm", "-q", "docs/x.md"], check=True)
        with open(os.path.join(worktree, "docs", "sub", "y.md"), "w", encoding="utf-8") as fh:
            fh.write("rewritten\n")
        subprocess.run(["git", "-C", worktree, "add", "docs/sub/y.md"], check=True)
        subprocess.run(["git", "-C", worktree, "commit", "-q", "-m", "delete x, rewrite y"], check=True)
        del_rev = subprocess.check_output(["git", "-C", worktree, "rev-parse", "HEAD"]).decode().strip()

        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "glob-slug", "worktree": worktree, "revision": del_rev,
                             "paths": ["docs/*"], "title": "t", "body": "b"})

        # surface 1: gate refuses LOUDLY (path allowlist, before any gates collaborator is consulted)
        gate = adapter.gate(unit, del_rev)
        self.assertEqual(gate.status, "block")
        self.assertEqual(gate.reason, "doc-apply path allowlist refused")
        self.assertIn("doc_apply_gate_refused",
                      [e["event"] for e in events(os.path.join(tmp, "j.jsonl"))])

        # surface 2: apply refuses too (defense in depth), journaled — and NOTHING lands anywhere
        result = adapter.apply(unit, del_rev)
        self.assertEqual(result.status, "refused")
        self.assertIn("doc_apply_apply_refused",
                      [e["event"] for e in events(os.path.join(tmp, "j.jsonl"))])
        log = subprocess.check_output(["git", "-C", main, "log", "--oneline"]).decode().strip().splitlines()
        self.assertEqual(len(log), 1)                     # no commit on MAIN
        self.assertTrue(os.path.exists(os.path.join(main, "docs", "x.md")))
        with open(os.path.join(main, "docs", "sub", "y.md"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "sub\n")          # y.md NOT half-applied either
        self.assertNotEqual((WU._read_manifest(adapter._manifest_path("glob-slug")) or {}).get("state"),
                            "applied")                    # never recorded as landed
        self.assertEqual(len(adapter.list_open()), 1)     # still open, never silently terminal

        # AND the land layer refuses even when a caller bypasses the adapter's own check entirely
        land = WU.LiveDocApply(journal, config={"MAIN": main})
        raw_unit = WU.WorkUnit(unit_id="doc-apply:glob-slug", kind="doc-apply", slug="glob-slug",
                               revision=del_rev,
                               artifact={"worktree": worktree, "paths": ["docs/*"]})
        self.assertEqual(land.apply(raw_unit).status, "refused")

        # the other pathspec special forms are refused by the same clause
        for bad in ("docs/x?.md", "docs/[ab].md", ":(top)docs/x.md"):
            self.assertIsNone(WU._safe_manifest_path(bad))

    # ── review advisory, round 4 (HERD-399): compare-and-set on revision before the write-back ─────
    def test_apply_write_back_never_clobbers_a_reopen_at_a_new_revision(self):
        """A builder open() at a NEW revision landing during the apply window must not be clobbered
        back to the old object with state=applied — that would bury the new change forever."""
        tmp = tempfile.mkdtemp()
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))

        class _ReopeningLand:
            """A land twin whose apply simulates the race: mid-apply, a builder re-opens the manifest
            at a NEW revision, then the (old-revision) landing reports success."""
            def __init__(self, manifest_path):
                self.manifest_path = manifest_path
            def apply(self, unit, paths=None):
                obj = WU._read_manifest(self.manifest_path)
                obj["revision"] = "rev-NEW"
                obj["state"] = "open"
                WU._write_manifest(self.manifest_path, obj)
                return WU.ApplyResult(status="applied", reason="gates_passed")

        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal, config={})
        adapter._land = _ReopeningLand(adapter._manifest_path("race-slug"))
        unit = adapter.open({"slug": "race-slug", "worktree": "", "revision": "rev-OLD",
                             "paths": ["docs/a.md"], "title": "t", "body": "b"})
        result = adapter.apply(unit, "rev-OLD")
        self.assertEqual(result.status, "applied")        # the old-revision landing itself succeeded
        obj = WU._read_manifest(adapter._manifest_path("race-slug"))
        self.assertEqual(obj["revision"], "rev-NEW")      # the re-open SURVIVED — not clobbered
        self.assertEqual(obj["state"], "open")            # the new revision will be discovered
        self.assertEqual(len(adapter.list_open()), 1)
        self.assertIn("doc_apply_manifest_cas_skip",
                      [e["event"] for e in events(os.path.join(tmp, "j.jsonl"))])

    # ── review BLOCK fix, round 2 (HERD-399): the commit-failure rollback was a no-op ──────────────
    def test_apply_commit_failure_rollback_actually_reverts_not_a_no_op(self):
        """`checkout -- <paths>` restores from the INDEX, which the earlier scoped checkout already
        updated to the NEW content — so the old rollback left MAIN permanently dirty at the new content
        whenever the commit itself failed. `checkout HEAD -- <paths>` is the form that actually reverts."""
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        hook_path = os.path.join(main, ".git", "hooks", "pre-commit")
        with open(hook_path, "w", encoding="utf-8") as fh:
            fh.write("#!/bin/sh\nexit 1\n")
        os.chmod(hook_path, 0o755)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "doc-slug", "worktree": worktree, "revision": revision,
                             "paths": ["docs/x.md"], "title": "t", "body": "b"})
        result = adapter.apply(unit, revision)
        self.assertEqual(result.status, "error")
        self.assertEqual(result.reason, "commit-failed")
        with open(os.path.join(main, "docs", "x.md"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "orig\n")   # actually reverted, not left at the new content
        status = subprocess.check_output(
            ["git", "-C", main, "status", "--porcelain", "--", "docs/x.md"]).decode()
        self.assertEqual(status.strip(), "")   # index AND worktree both clean
        # not permanently wedged: the unit is retried (no stale "dirty-local-changes" false-positive).
        self.assertEqual(len(adapter.list_open()), 1)

    # ── review BLOCK fix, round 5 (HERD-399): the rollback must also cover a NEWLY-ADDED file ──────
    def test_apply_commit_failure_rollback_leaves_shared_checkout_clean_for_a_newly_added_file(self):
        """The round-2 form (`checkout HEAD -- <paths>`) no-ops for a path NOT present at HEAD — the
        pathspec matches nothing, git hard-errors, and the ADD stays staged. Verified worse: in a
        MIXED add+modify set the unmatched pathspec aborts the whole restore, so even the modify
        stayed dirty. Consequences the reviewer verified: the unit bricks forever on the
        dirty-local-changes pre-check, and the stray staged blob can ride the scribe backend's
        pathspec-less backlog commits (backends/file.sh) onto the default branch un-gated. The
        rollback must leave the WHOLE shared checkout clean — adds gone, modifies reverted."""
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        # the reviewer's shape PLUS the mixed-set aggravation: a NEW file and a modify in one unit
        with open(os.path.join(worktree, "docs", "new.md"), "w", encoding="utf-8") as fh:
            fh.write("brand new\n")
        subprocess.run(["git", "-C", worktree, "add", "docs/new.md"], check=True)
        subprocess.run(["git", "-C", worktree, "commit", "-q", "-m", "add new.md"], check=True)
        add_rev = subprocess.check_output(["git", "-C", worktree, "rev-parse", "HEAD"]).decode().strip()
        hook_path = os.path.join(main, ".git", "hooks", "pre-commit")
        with open(hook_path, "w", encoding="utf-8") as fh:
            fh.write("#!/bin/sh\nexit 1\n")
        os.chmod(hook_path, 0o755)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "add-slug", "worktree": worktree, "revision": add_rev,
                             "paths": ["docs/new.md", "docs/x.md"], "title": "t", "body": "b"})
        result = adapter.apply(unit, add_rev)
        self.assertEqual(result.status, "error")
        self.assertEqual(result.reason, "commit-failed")
        # THE core assertion: the WHOLE shared checkout is clean — no staged "A " row for the scribe
        # backend's index-wide backlog commits to sweep onto the default branch un-gated.
        status = subprocess.check_output(["git", "-C", main, "status", "--porcelain"]).decode()
        self.assertEqual(status.strip(), "")
        self.assertFalse(os.path.exists(os.path.join(main, "docs", "new.md")))   # the add is GONE
        with open(os.path.join(main, "docs", "x.md"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "orig\n")   # the modify reverted too (mixed set, round-5 find)
        # and NOT bricked: with the hook gone, the very next tick lands it
        os.remove(hook_path)
        retry = adapter.apply(unit, add_rev)
        self.assertEqual(retry.status, "applied")
        with open(os.path.join(main, "docs", "new.md"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "brand new\n")

    # ── review advisory, round 5 (HERD-399): "exactly one blob" is now PROVEN, never assumed ───────
    def test_apply_refuses_a_path_that_cannot_be_proven_a_blob_at_revision(self):
        """The old tree-guard answered "not a tree -> proceed" on ANY inconclusive read, so a missing
        path (e.g. a single-file deletion attempt) fell through to a retry-forever checkout error and
        a transient ls-tree failure re-opened the directory under-apply hole. Now: no proof, no apply."""
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "ghost-slug", "worktree": worktree, "revision": revision,
                             "paths": ["docs/does-not-exist.md"], "title": "t", "body": "b"})
        result = adapter.apply(unit, revision)
        self.assertEqual(result.status, "refused")
        self.assertEqual(result.reason, "path-not-a-blob-at-revision")
        log = subprocess.check_output(["git", "-C", main, "log", "--oneline"]).decode().strip().splitlines()
        self.assertEqual(len(log), 1)   # nothing landed
        # the classifier itself: blob/tree recognized, everything inconclusive is None (fail closed)
        self.assertEqual(WU._revision_path_kind(main, revision, "docs/x.md"), "blob")
        self.assertEqual(WU._revision_path_kind(main, revision, "docs/sub"), "tree")
        self.assertIsNone(WU._revision_path_kind(main, revision, "docs/absent.md"))
        self.assertIsNone(WU._revision_path_kind(os.path.join(tmp, "no-such-repo"), revision, "docs/x.md"))
        self.assertIsNone(WU._revision_path_kind(main, "not-a-revision", "docs/x.md"))

    # ── review advisory, round 5 (HERD-399): a typo'd kwarg still fails LOUD ────────────────────────
    def test_resolve_adapter_rejects_a_kwarg_no_kind_accepts(self):
        # the round-4 cross-kind filter must not swallow the typo signal: only kwargs some kind's
        # constructor declares are filterable; anything outside the union raises like before.
        with self.assertRaises(TypeError):
            WU.resolve_adapter("doc-apply", confg={"MAIN": "/m"})   # sic: misspelled "config"

    # ── review advisory, round 2 (HERD-399): gate/apply must catch a revision-argument mismatch ─────
    def test_gate_and_apply_refuse_when_revision_argument_disagrees_with_unit_revision(self):
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        scenario = {"candidates": [dict(pr="doc-slug", sha=revision, health="CLEAN", review="PASS")]}
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal, gates=FixtureGates(scenario),
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "doc-slug", "worktree": worktree, "revision": revision,
                             "paths": ["docs/x.md"], "title": "t", "body": "b"})
        self.assertEqual(adapter.gate(unit, "some-other-sha-entirely").status, "error")
        self.assertEqual(adapter.apply(unit, "some-other-sha-entirely").status, "error")
        # the correct revision still works fine
        self.assertEqual(adapter.gate(unit, revision).status, "pass")

    # ── review fix (HERD-399): the push-rejected rollback must never reset a detached HEAD or a HEAD
    #    that has moved past OUR OWN commit (a concurrent seat's work) ─────────────────────────────
    def test_rollback_never_resets_when_head_ends_up_detached(self):
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        subprocess.run(["git", "-C", main, "remote", "set-url", "origin", "/no/such/path"], check=True)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "doc-slug", "worktree": worktree, "revision": revision,
                             "paths": ["docs/x.md"], "title": "t", "body": "b"})

        real_attached = WU._git_attached
        calls = {"n": 0}

        def fake_attached(path, branch):
            calls["n"] += 1
            if calls["n"] == 1:
                return real_attached(path, branch)   # the early pre-checkout guard: let it proceed
            return False   # the rollback guard: simulate the HERD-336 detached-after-rebase race

        with mock.patch.object(WU, "_git_attached", side_effect=fake_attached):
            result = adapter.apply(unit, revision)

        self.assertEqual(result.status, "error")
        self.assertEqual(result.reason, "push-rejected-detached-head")
        log = subprocess.check_output(["git", "-C", main, "log", "--oneline"]).decode().strip().splitlines()
        self.assertEqual(len(log), 2)   # init + our commit — landed locally, but NEVER reset away

    def test_rollback_never_resets_when_head_moved_past_our_own_commit(self):
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        subprocess.run(["git", "-C", main, "remote", "set-url", "origin", "/no/such/path"], check=True)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "doc-slug", "worktree": worktree, "revision": revision,
                             "paths": ["docs/x.md"], "title": "t", "body": "b"})

        real_head = WU._git_head
        main_calls = {"n": 0}

        def fake_head(path):
            if path == main:
                main_calls["n"] += 1
                if main_calls["n"] >= 2:
                    # the SECOND main-HEAD read (the rollback comparison) sees a commit that is not
                    # ours — simulating a concurrent seat's commit landing on the shared checkout.
                    return "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
            return real_head(path)

        with mock.patch.object(WU, "_git_head", side_effect=fake_head):
            result = adapter.apply(unit, revision)

        self.assertEqual(result.status, "error")
        self.assertEqual(result.reason, "push-rejected-head-moved")
        log = subprocess.check_output(["git", "-C", main, "log", "--oneline"]).decode().strip().splitlines()
        self.assertEqual(len(log), 2)   # our commit is still there, never reset away

    def test_apply_rolls_back_our_own_commit_when_push_is_permanently_rejected(self):
        # The expected-safe case: nothing detached, HEAD is still exactly our commit -> the rollback
        # DOES run, restoring MAIN to its pre-apply content.
        tmp = tempfile.mkdtemp()
        main, worktree, revision = _doc_apply_fixture(tmp)
        subprocess.run(["git", "-C", main, "remote", "set-url", "origin", "/no/such/path"], check=True)
        journal = LiveJournal(os.path.join(tmp, "j.jsonl"))
        adapter = WU.DocApplyAdapter(worktrees_dir=tmp, journal=journal,
                                     config={"MAIN": main, "HERD_REMOTE": "origin",
                                            "HERD_BRANCH_NAME": "main"})
        unit = adapter.open({"slug": "doc-slug", "worktree": worktree, "revision": revision,
                             "paths": ["docs/x.md"], "title": "t", "body": "b"})
        result = adapter.apply(unit, revision)
        self.assertEqual(result.status, "error")
        self.assertEqual(result.reason, "push-rejected")
        with open(os.path.join(main, "docs", "x.md"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "orig\n")   # rolled back to pre-apply content
        log = subprocess.check_output(["git", "-C", main, "log", "--oneline"]).decode().strip().splitlines()
        self.assertEqual(len(log), 1)   # back to just the init commit

    # ── reconcile/teardown: honest gaps (bash-owned, spike §9.1/§9.4), never a silent no-op ──────
    def test_reconcile_and_teardown_are_not_implemented(self):
        adapter = WU.DocApplyAdapter(worktrees_dir=tempfile.mkdtemp(), journal=LiveJournal(None))
        with self.assertRaises(NotImplementedError) as ctx:
            adapter.reconcile(None)
        self.assertIn("reconcile", str(ctx.exception))
        with self.assertRaises(NotImplementedError) as ctx:
            adapter.teardown(None)
        self.assertIn("teardown", str(ctx.exception))


class TestMergeResultGateConfig(unittest.TestCase):
    """HERD-296/§6.4: MERGE_RESULT_GATE is a STRICT validated gate key — an unrecognized value must
    read off (the safe, byte-identical default), never accidentally on from a typo."""

    def test_truthy_set_matches_other_gate_keys(self):
        for v in ("1", "true", "on", "yes", "enable", "enabled", "ON", "Enabled"):
            self.assertTrue(_merge_result_gate_enabled({"MERGE_RESULT_GATE": v}), v)

    def test_absent_off_and_typo_all_read_off(self):
        for cfg in ({}, {"MERGE_RESULT_GATE": ""}, {"MERGE_RESULT_GATE": "off"},
                    {"MERGE_RESULT_GATE": "0"}, {"MERGE_RESULT_GATE": "bogus"}, None):
            self.assertFalse(_merge_result_gate_enabled(cfg), cfg)

    def test_nonce_with_base_round_trips(self):
        nonce = _dispatch_nonce_with_base("a" * 40)
        self.assertEqual(_nonce_base(nonce), "a" * 40)

    def test_nonce_without_base_component_yields_empty(self):
        self.assertEqual(_nonce_base(_dispatch_nonce()), "")
        self.assertEqual(_nonce_base(""), "")
        self.assertEqual(_nonce_base(None), "")


class TestMergeResultGateByteIdentical(LiveCase):
    """gate OFF (default, and every tick before this feature existed) must be a hard no-op: the
    classic health substrate is untouched, no `.merge-result-*` file is ever written, and every
    existing dry-run/fixture assertion in this file (never exercising MERGE_RESULT_GATE) keeps
    passing unmodified — that whole-file regression IS the strongest byte-identical proof; this
    class adds the targeted one: LiveGates.health() never even LOOKS at the merge-result path."""

    def test_health_off_never_reaches_merge_result_branch(self):
        state = LiveState(state_dir=self.tmp)
        journal = LiveJournal(self.jpath)
        gates = LiveGates("/nonexistent-home", state, journal, config={})
        self.assertFalse(gates._merge_result_gate)
        # Poison the merge-result path: if health() ever reached it with the lever off, this raises.
        gates._merge_result_health = lambda cand: (_ for _ in ()).throw(
            AssertionError("merge-result path reached with MERGE_RESULT_GATE off"))
        wt = _make_worktree(self.tmp, "feat-x")
        cand = LiveCandidate(pr=1, sha="deadbeef", slug="feat-x", worktree=wt)
        self.assertEqual(gates.health(cand), WAIT)   # classic dispatch-and-wait, untouched
        self.assertTrue(os.path.exists(state.health_inflight_file(cand)))
        self.assertFalse(any(n.startswith(".merge-result-") for n in os.listdir(self.tmp)))


class TestMergeResultGateDispatch(unittest.TestCase):
    """LiveGates._merge_result_health / _dispatch_merge_result: cache reuse keyed on (pr, sha, base),
    collect-and-cache, base-move re-arm, conflict sentinel, and combined concurrency accounting.
    Hermetic: `_materialize_merge_tree` and `subprocess.Popen` are both stubbed — no real git merge
    or suite runs here (the real end-to-end path is proven by tests/test-merge-result-gate-sim.sh)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.jpath = os.path.join(self.tmp, "j.jsonl")
        self._orig_materialize = LR._materialize_merge_tree
        self._orig_subprocess = LR.subprocess
        os.environ["HERD_JOURNAL_NOW"] = "2026-07-25T00:00:00Z"

    def tearDown(self):
        LR._materialize_merge_tree = self._orig_materialize
        LR.subprocess = self._orig_subprocess
        os.environ.pop("HERD_JOURNAL_NOW", None)

    def _gates(self, config=None):
        state = LiveState(state_dir=self.tmp)
        journal = LiveJournal(self.jpath)
        cfg = dict(config or {})
        cfg.setdefault("MERGE_RESULT_GATE", "on")
        return LiveGates("/nonexistent-home", state, journal, config=cfg), state, journal

    def _events(self):
        return events(self.jpath) if os.path.exists(self.jpath) else []

    class _PopenStub:
        DEVNULL = subprocess.DEVNULL

        class _Proc:
            pid = 9191

        def __init__(self):
            self.calls = 0

        def Popen(self, *a, **k):
            self.calls += 1
            return self._Proc()

    def test_conflict_never_cached_and_never_dispatches_a_suite(self):
        LR._materialize_merge_tree = lambda src, head, base, tree: (False, "merge conflict: boom")
        sub = self._PopenStub()
        LR.subprocess = sub
        gates, state, _ = self._gates()
        cand = LiveCandidate(pr=1, sha="head1", slug="feat-x", worktree=_make_worktree(self.tmp, "feat-x"))
        with mock.patch.object(LR, "_resolve_default_branch_sha", return_value="b" * 40):
            result = gates.health(cand)
        self.assertEqual(result, "CONFLICT")
        self.assertEqual(sub.calls, 0)               # no suite ever dispatched on a conflict
        self.assertIsNone(state.merge_result_verdict(cand.pr, cand.sha, "b" * 40))
        conflicts = [e for e in self._events() if e["event"] == "merge_result_conflict"]
        self.assertEqual(len(conflicts), 1)
        self.assertEqual(conflicts[0]["base"], "b" * 40)

    def test_base_unresolved_holds_never_dispatches(self):
        gates, state, _ = self._gates()
        cand = LiveCandidate(pr=1, sha="head1", slug="feat-x", worktree=_make_worktree(self.tmp, "feat-x2"))
        with mock.patch.object(LR, "_resolve_default_branch_sha", return_value=""):
            self.assertEqual(gates.health(cand), WAIT)
        self.assertEqual(len([e for e in self._events() if e["event"] == "dispatch_refused"]), 1)

    def test_dispatch_then_collect_caches_by_head_and_base(self):
        LR._materialize_merge_tree = lambda src, head, base, tree: (True, "")
        LR.subprocess = self._PopenStub()
        gates, state, _ = self._gates()
        cand = LiveCandidate(pr=2, sha="head2", slug="feat-y", worktree=_make_worktree(self.tmp, "feat-y"))
        base = "c" * 40
        with mock.patch.object(LR, "_resolve_default_branch_sha", return_value=base):
            self.assertEqual(gates.health(cand), WAIT)      # dispatched
            inflight = state.merge_result_inflight_file(cand.pr, cand.sha)
            self.assertTrue(os.path.exists(inflight))
            nonce = _marker_nonce(inflight)
            self.assertEqual(_nonce_base(nonce), base)      # the base actually tested travels in the nonce
            # Simulate the worker finishing: it echoes the nonce + the terminal verdict.
            disp = state.merge_result_dispatch_file(cand.pr, cand.sha)
            with open(disp, "w") as fh:
                fh.write("%s\tCODEERROR\tnot ok 1 - contract mismatch\n" % nonce)
            result = gates.health(cand)
            self.assertEqual(result, "CODEERROR")
            self.assertEqual(state.merge_result_verdict(cand.pr, cand.sha, base), "CODEERROR")
            self.assertFalse(os.path.exists(disp))
            self.assertFalse(os.path.exists(inflight))
            gate_ev = [e for e in self._events() if e["event"] == "merge_result_gate"]
            self.assertEqual(len(gate_ev), 1)
            self.assertEqual(gate_ev[0]["base"], base)
            self.assertEqual(gate_ev[0]["verdict"], "CODEERROR")
            # A later call reuses the cached verdict — no second dispatch.
            popen = LR.subprocess
            calls_before = popen.calls
            self.assertEqual(gates.health(cand), "CODEERROR")
            self.assertTrue(gates.reused_health)
            self.assertEqual(popen.calls, calls_before)

    def test_base_move_is_a_cache_miss_and_rearms(self):
        LR._materialize_merge_tree = lambda src, head, base, tree: (True, "")
        gates, state, _ = self._gates()
        cand = LiveCandidate(pr=3, sha="head3", slug="feat-z", worktree=_make_worktree(self.tmp, "feat-z"))
        state.record_merge_result_verdict(cand.pr, cand.sha, "old" + "d" * 37, "CLEAN", "clean")
        sub = self._PopenStub()
        LR.subprocess = sub
        with mock.patch.object(LR, "_resolve_default_branch_sha", return_value="new" + "e" * 37):
            result = gates.health(cand)
        self.assertEqual(result, WAIT)                 # cache miss on the NEW base -> fresh dispatch
        self.assertEqual(sub.calls, 1)

    def test_combined_concurrency_counts_both_prefixes(self):
        state = LiveState(state_dir=self.tmp)
        _marker_write(state._p(".health-inflight-1-a"), os.getpid())
        _marker_write(state._p(".merge-result-inflight-2-b"), os.getpid())
        self.assertEqual(_total_health_inflight(self.tmp), 2)

    def test_slot_check_refuses_dispatch_when_saturated(self):
        gates, state, _ = self._gates(config={"HEALTH_CONCURRENCY": "1"})
        # Occupy the ONE slot via the CLASSIC health-inflight namespace — the merge-result path must
        # still see it (combined accounting) and refuse to dispatch a second suite.
        _marker_write(state._p(".health-inflight-99-other"), os.getpid())
        cand = LiveCandidate(pr=4, sha="head4", slug="feat-w", worktree=_make_worktree(self.tmp, "feat-w"))
        sub = self._PopenStub()
        LR.subprocess = sub
        with mock.patch.object(LR, "_resolve_default_branch_sha", return_value="f" * 40):
            result = gates.health(cand)
        self.assertEqual(result, WAIT)
        self.assertEqual(sub.calls, 0)
        self.assertEqual(len([e for e in self._events() if e["event"] == "health_queued"]), 1)


class TestMergeResultGateWalk(LiveCase):
    """LiveTick._walk: the CONFLICT sentinel folds into the SAME honest hold path as the stale-dup
    gate — HOLD, once-guarded, never a bounce, never cached as a red — and is unreachable with the
    lever off."""

    class _ConflictGates:
        reused_health = False
        reused_review = False

        def health(self, cand):
            return "CONFLICT"

        def review(self, cand):
            raise AssertionError("review must never be reached past a merge-result CONFLICT")

    def _tick(self):
        journal = LiveJournal(self.jpath)
        state = LiveState(self.tmp)
        return LiveTick({"MERGE_POLICY": "auto", "MERGE_RESULT_GATE": "on"}, None,
                        self._ConflictGates(), DryRunActuator(journal), journal, state=state)

    def test_conflict_holds_never_blocks_or_merges(self):
        t = self._tick()
        cand = LiveCandidate(pr=1, sha="s1", slug="feat-x")
        self.assertEqual(t._walk(cand), "HOLD")
        evs = events(self.jpath)
        holds = [e for e in evs if e["event"] == "stale_dup_hold"]
        self.assertEqual(len(holds), 1)
        self.assertEqual(holds[0]["kind"], "merge_result_conflict")

    def test_conflict_hold_is_once_guarded(self):
        t = self._tick()
        cand = LiveCandidate(pr=1, sha="s1", slug="feat-x")
        t._walk(cand)
        t._walk(cand)   # a second tick over the SAME (pr, sha) must not re-journal the hold
        evs = events(self.jpath)
        holds = [e for e in evs if e["event"] == "stale_dup_hold"]
        self.assertEqual(len(holds), 1)


class TestMergeResultGateSupersession(unittest.TestCase):
    """_supersede_stale must cancel a stale merge-result-gate worker exactly like the classic
    health/review rails (§6.1) — same session-kill primitive, same gate_superseded event shape,
    with rail="merge_result"."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.jpath = os.path.join(self.tmp, "j.jsonl")
        os.environ["HERD_JOURNAL_NOW"] = "2026-07-25T00:00:00Z"

    def tearDown(self):
        os.environ.pop("HERD_JOURNAL_NOW", None)

    def test_stale_merge_result_worker_terminated_and_journaled(self):
        journal = LiveJournal(self.jpath)
        state = LiveState(self.tmp)
        # A DEAD marker for a superseded sha ("aaaaaa1") — _terminate_worker treats a dead/recycled
        # marker as already-gone, so this exercises the cancel WITHOUT spawning a real process.
        old_inflight = state._p(".merge-result-inflight-77-aaaaaa1")
        _marker_write(old_inflight, 999999)   # a pid that (almost certainly) is not alive
        open(state._p(".merge-result-dispatch-77-aaaaaa1"), "w").close()
        open(state._p(".merge-result-log-77-aaaaaa1"), "w").close()
        t = LiveTick({"MERGE_POLICY": "observe"}, None, None, DryRunActuator(journal), journal,
                    state=state)
        t._supersede_stale([LiveCandidate(pr=77, sha="newsha")])
        self.assertFalse(os.path.exists(old_inflight))
        self.assertFalse(os.path.exists(state._p(".merge-result-dispatch-77-aaaaaa1")))
        self.assertFalse(os.path.exists(state._p(".merge-result-log-77-aaaaaa1")))
        evs = events(self.jpath)
        superseded = [e for e in evs if e["event"] == "gate_superseded" and e.get("rail") == "merge_result"]
        self.assertEqual(len(superseded), 1)
        self.assertEqual(superseded[0]["old_sha"], "aaaaaa1")
        self.assertEqual(superseded[0]["new_sha"], "newsha")

    def test_off_lever_leaves_nothing_to_supersede(self):
        # With no .merge-result-* marker ever written (the gate-off default), the glob is empty and
        # _supersede_stale journals nothing for that rail — byte-inert.
        journal = LiveJournal(self.jpath)
        state = LiveState(self.tmp)
        t = LiveTick({"MERGE_POLICY": "observe"}, None, None, DryRunActuator(journal), journal,
                    state=state)
        t._supersede_stale([LiveCandidate(pr=1, sha="s1")])
        evs = events(self.jpath) if os.path.exists(self.jpath) else []
        self.assertEqual([e for e in evs if e.get("rail") == "merge_result"], [])


class TestChaosSeamGuard(LiveCase):
    """HERD-425: the three chaos-injection seams (_chaos_kill) must be ship-dormant, byte-identical-
    when-off, and fail-closed against accidental use outside tests/test-gate-reconciler-chaos-sim.sh
    — the ONLY caller that ever sets HERD_CHAOS_KILL_AT/HERD_CHAOS_GUARD. Every "inert" case here
    proves the guard logic in isolation (os.kill is monkeypatched, never actually invoked) so a
    regression that widens the guard is caught by a fast unit test, not only by the slow, real-SIGKILL
    chaos sim. The one "fires" case is proven with a REAL subprocess + a REAL SIGKILL (not a mock) —
    the mock only proves intent; the subprocess proves the kill is genuinely untrappable."""

    def setUp(self):
        super().setUp()
        self._env_saved = {}
        for k in ("HERD_CHAOS_KILL_AT", "HERD_CHAOS_GUARD"):
            self._env_saved[k] = os.environ.pop(k, None)
        self.addCleanup(self._restore_env)

    def _restore_env(self):
        for k, v in self._env_saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def _guard_file(self, present=True):
        p = os.path.join(self.tmp, "guard")
        if present:
            with open(p, "w", encoding="utf-8") as fh:
                fh.write("hermetic sentinel\n")
        return p

    def test_noop_when_kill_at_unset(self):
        # The default, always-true-in-production case: no env var set at all.
        os.environ["HERD_CHAOS_GUARD"] = self._guard_file()
        with mock.patch.object(LR.os, "kill") as mock_kill:
            LR._chaos_kill("mid_do_merge")
        mock_kill.assert_not_called()

    def test_noop_when_guard_unset(self):
        # A point IS armed but the fail-closed guard var is absent — must still be inert.
        os.environ["HERD_CHAOS_KILL_AT"] = "mid_do_merge"
        with mock.patch.object(LR.os, "kill") as mock_kill:
            LR._chaos_kill("mid_do_merge")
        mock_kill.assert_not_called()

    def test_noop_when_guard_file_missing(self):
        # A stray/leaked HERD_CHAOS_KILL_AT (operator typo, inherited shell env) in a real deployment
        # can never self-destruct a real watcher, because HERD_CHAOS_GUARD never also points at an
        # existing file there — this is the fail-closed invariant itself, not just an unset-var case.
        os.environ["HERD_CHAOS_KILL_AT"] = "mid_do_merge"
        os.environ["HERD_CHAOS_GUARD"] = self._guard_file(present=False)
        with mock.patch.object(LR.os, "kill") as mock_kill:
            LR._chaos_kill("mid_do_merge")
        mock_kill.assert_not_called()

    def test_noop_when_point_mismatches(self):
        # Armed for a DIFFERENT boundary than the one currently executing — every call site checks its
        # own literal point name, so arming one seam can never accidentally fire another.
        os.environ["HERD_CHAOS_KILL_AT"] = "mid_do_merge"
        os.environ["HERD_CHAOS_GUARD"] = self._guard_file()
        with mock.patch.object(LR.os, "kill") as mock_kill:
            LR._chaos_kill("mid_gate_collect")
        mock_kill.assert_not_called()

    def test_fires_when_point_and_guard_both_match(self):
        os.environ["HERD_CHAOS_KILL_AT"] = "mid_refix_bounce"
        os.environ["HERD_CHAOS_GUARD"] = self._guard_file()
        with mock.patch.object(LR.os, "kill") as mock_kill:
            LR._chaos_kill("mid_refix_bounce")
        mock_kill.assert_called_once_with(os.getpid(), LR.signal.SIGKILL)

    def test_all_three_call_sites_name_a_real_point(self):
        # A cheap regression guard against a seam's literal point string drifting out of sync with the
        # sim that arms it — every point tests/test-gate-reconciler-chaos-sim.sh sets must fire here.
        for point in ("mid_do_merge", "mid_gate_collect", "mid_refix_bounce"):
            with self.subTest(point=point):
                os.environ["HERD_CHAOS_KILL_AT"] = point
                os.environ["HERD_CHAOS_GUARD"] = self._guard_file()
                with mock.patch.object(LR.os, "kill") as mock_kill:
                    LR._chaos_kill(point)
                mock_kill.assert_called_once_with(os.getpid(), LR.signal.SIGKILL)

    def test_valid_sentinel_delivers_a_real_untrappable_sigkill_in_a_subprocess(self):
        # The mocked cases above prove the GUARD LOGIC; this proves the actual KILL is real — a
        # genuinely separate python3 process, armed exactly as tests/test-gate-reconciler-chaos-sim.sh
        # arms it, must die by SIGKILL (returncode -9), not raise a catchable exception and not exit
        # cleanly. No `try/except SystemExit` in the child could survive this if the seam is wired to
        # a real os.kill(SIGKILL) rather than, say, sys.exit().
        guard = self._guard_file()
        env = dict(os.environ)
        env["HERD_CHAOS_KILL_AT"] = "mid_do_merge"
        env["HERD_CHAOS_GUARD"] = guard
        env["PYTHONPATH"] = os.path.dirname(os.path.dirname(os.path.abspath(LR.__file__)))
        script = (
            "import herd.live_runtime as lr\n"
            "try:\n"
            "    lr._chaos_kill('mid_do_merge')\n"
            "except SystemExit:\n"
            "    pass\n"  # proves a trappable exit is NOT what happens — control never reaches here
            "print('SURVIVED')\n"
        )
        proc = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, -LR.signal.SIGKILL,
                         "child rc=%r stdout=%r stderr=%r" % (proc.returncode, proc.stdout, proc.stderr))
        self.assertNotIn("SURVIVED", proc.stdout)

    def test_valid_sentinel_is_inert_in_a_subprocess_when_guard_file_absent(self):
        # The subprocess-level twin of test_noop_when_guard_file_missing: proves the fail-closed
        # behavior holds even when nothing in-process could have monkeypatched anything away.
        env = dict(os.environ)
        env["HERD_CHAOS_KILL_AT"] = "mid_do_merge"
        env["HERD_CHAOS_GUARD"] = os.path.join(self.tmp, "does-not-exist")
        env["PYTHONPATH"] = os.path.dirname(os.path.dirname(os.path.abspath(LR.__file__)))
        script = ("import herd.live_runtime as lr\n"
                  "lr._chaos_kill('mid_do_merge')\n"
                  "print('SURVIVED')\n")
        proc = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, "stdout=%r stderr=%r" % (proc.stdout, proc.stderr))
        self.assertIn("SURVIVED", proc.stdout)


class TestChaosRestartReconciliation(LiveCase):
    """HERD-425: unit-level (no subprocess, no real SIGKILL) proof that a torn on-disk state — the
    EXACT residue each chaos-sim leg's kill point leaves behind — converges cleanly when a FRESH
    LiveGates / LiveTick / LiveActuator instance (a new object graph over the SAME LiveState dir,
    modeling a restarted process with zero in-memory carryover) reads it.
    tests/test-gate-reconciler-chaos-sim.sh proves the same claims end-to-end with genuine process
    kills; this class isolates just the recovery LOGIC so it runs in milliseconds."""

    def test_health_collect_recovers_from_a_result_file_with_no_cache_yet(self):
        # The exact residue mid_gate_collect's kill point leaves: a nonce-matched dispatch out-file and
        # its live-looking inflight marker are on disk, but NOTHING has been cached yet — the process
        # died between reading the out-file and calling record_health_result (LiveGates.health's own
        # "at-least-once" collect-step ordering).
        state = LiveState(self.tmp)
        journal = LiveJournal(self.jpath)
        cand = LiveCandidate(pr=9, sha="shaX", slug="feat-x", worktree="")
        inflight = state.health_inflight_file(cand)
        disp = state.health_dispatch_file(cand)
        nonce = _dispatch_nonce()
        _marker_write(inflight, 999999, nonce=nonce)
        with open(disp, "w", encoding="utf-8") as fh:
            fh.write("%s\tCLEAN\tclean\n" % nonce)
        self.assertIsNone(state.health_cached_verdict(cand))

        gates = LiveGates("/nonexistent-home", state, journal)   # a FRESH instance — models a restart
        verdict = gates.health(cand)

        self.assertEqual(verdict, "CLEAN")
        self.assertEqual(state.health_cached_verdict(cand), "CLEAN")
        self.assertFalse(os.path.exists(disp), "the dispatch scratch file must be swept on recovery")
        self.assertFalse(os.path.exists(inflight), "the inflight marker must be swept on recovery")

    def test_refix_once_guard_alone_holds_silently_on_a_fresh_instance(self):
        # The exact residue mid_refix_bounce's kill point leaves: _refix_check_and_record's ledger row
        # landed, but the bounce's own wake+journal never ran (the process died inside
        # _bounce_and_wake, after wake_builder actuated, before its journal pair).
        state = LiveState(self.tmp)
        journal = LiveJournal(self.jpath)
        cand = LiveCandidate(pr=11, sha="shaY", slug="feat-y", worktree="")
        actuator = DryRunActuator(journal)
        tick = LiveTick({"MERGE_POLICY": "auto"}, None, None, actuator, journal, state=state)
        # Hand-write the once-guard row directly, bypassing _bounce_and_wake entirely — this IS what a
        # fresh process finds on disk after the chaos leg's kill.
        ledger = os.path.join(self.tmp, ".agent-watch-refixed")
        with open(ledger, "w", encoding="utf-8") as fh:
            fh.write("1700000000 11 shaY feat-y health\n")

        round_num, reason = tick._refix_check_and_record(cand, "health")

        self.assertIsNone(round_num)
        self.assertIsNone(reason)   # once-guard holds silently: never a second wake, never ESCALATE

        # A fresh sha reopens the round (sha-keyed once-guard, contract §2.4) — proves the hold is
        # bounded, not a permanent wedge. round=2, not 1: only the ONCE-GUARD is sha-keyed (contract
        # §4) — the rail's per-PR lifetime round count is not, and correctly keeps counting.
        cand2 = LiveCandidate(pr=11, sha="shaZ", slug="feat-y", worktree="")
        round_num2, reason2 = tick._refix_check_and_record(cand2, "health")
        self.assertEqual(round_num2, 2)
        self.assertIsNone(reason2)

    def test_merge_state_verify_reads_true_state_on_a_fresh_actuator_instance(self):
        # The exact residue mid_do_merge's kill point leaves: the remote merge already landed (gh
        # reports MERGED) but no local journal 'merge' record exists yet. A fresh LiveActuator (models
        # a restarted tick) reading this candidate must confirm MERGED via the API read alone — the
        # read path tests/test-gate-reconciler-chaos-sim.sh's LEG A relies on end-to-end (there, via
        # the shared post-merge sweep, which is what actually discharges the reap/tracker obligations
        # in production — a duplicate direct .merge() call is deliberately NOT exercised here, since
        # de-duplicating repeat merge attempts is candidate-discovery's job, not the actuator's).
        sub = _RecordingSub(view_state="MERGED")
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        journal = LiveJournal(self.jpath)
        cand = LiveCandidate(13, "deadbeef2", slug="feat-z", worktree="")

        act = LiveActuator("/nonexistent-home", journal)   # a FRESH instance — models a restart
        self.assertEqual(act._merged_state(cand), "MERGED")
        self.assertTrue(act.merge(cand))
        merge_events = [e for e in events(self.jpath) if e["event"] == "merge"]
        self.assertEqual(len(merge_events), 1)


# ── the §5.4/§5.5 hold LAYER, restored (HERD-442) ─────────────────────────────────────────────────
# HERD-306 (P5b) deleted the bash action pass and the port never re-acquired the two INPUTS to the
# hold decision: discover_via_graphql fetches number/sha/base/mergeState and nothing else, so
# LiveCandidate.hv_hold and .approved sat at their constructor defaults on every live tick. Under the
# SHIP DEFAULT (MERGE_POLICY=auto + HUMAN_VERIFY_POLICY=hold) that auto-merged every PR that declared
# HUMAN-VERIFY steps (proven live: PR #555, 2026-07-30, merge{reason:gates_passed} with no hold_applied
# anywhere), and nothing ever wrote the `awaiting` row `herd approve` refuses to run without.
#
# Each test below FAILS without the restoration: delete the LiveHoldSource wiring and the hv tests see
# MERGE instead of HOLD, the ledger tests see an empty file, and hold_released disappears.

class _StubHoldSource:
    """A LiveHoldSource twin with no gh and no ledger — the body/rc and approval are injected."""

    def __init__(self, body="", rc=0, approved=False):
        self.body, self.rc, self._approved = body, rc, approved
        self.body_reads = 0

    def hv_body(self, pr):
        self.body_reads += 1
        return self.body, self.rc

    def approved(self, pr, sha):
        return self._approved


class _RefusingActuator(DryRunActuator):
    """A dry-run actuator whose merge is REFUSED (the API verify did not confirm MERGED) — the state
    in which the pre-merge ledger window is observable, because no purge runs."""

    def merge(self, cand):
        return False


_HV_BODY = "Some PR body.\n\nHUMAN-VERIFY:\n- run the live smoke test\n\nMore prose.\n"


class TestHoldLayerRestored(LiveCase):
    def tick_live(self, hold_source, config=None, **kw):
        """A tick with a hold_source wired — the LIVE shape, minus the network."""
        cand = self.one(1, **kw)
        scenario = {"candidates": [cand], "config": config or {"MERGE_POLICY": "auto"}}
        journal = LiveJournal(self.jpath)
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     DryRunActuator(journal), journal, state=LiveState(self.tmp),
                     hold_source=hold_source)
        res = t.run()
        return res["outcomes"]["1"], (events(self.jpath) if os.path.exists(self.jpath) else [])

    def ledger(self):
        path = os.path.join(self.tmp, ".agent-watch-approvals")
        return open(path).read() if os.path.exists(path) else ""

    # ── the input that was never read ────────────────────────────────────────────────────────────
    def test_declared_human_verify_block_holds_on_the_default_policy(self):
        # THE regression. Before the fix this merged: hv_hold was never set from the body.
        src = _StubHoldSource(body=_HV_BODY)
        out, ev = self.tick_live(src, review="PASS", health="CLEAN")
        self.assertEqual(out, "HOLD")
        self.assertEqual(src.body_reads, 1)
        held = [o for o in ev if o["event"] == "hold_applied"]
        self.assertEqual(len(held), 1)
        self.assertEqual(held[0]["kind"], "human-verify")
        self.assertFalse([o for o in ev if o["event"] == "merge"])

    def test_a_body_with_no_block_still_merges(self):
        # The other half of the same read: the gate must not hold a PR that declared nothing.
        out, ev = self.tick_live(_StubHoldSource(body="No manual steps here.\n"),
                                 review="PASS", health="CLEAN")
        self.assertEqual(out, "MERGE")
        self.assertFalse([o for o in ev if o["event"] == "hold_applied"])

    def test_bare_marker_with_no_steps_is_not_a_hold(self):
        # human-verify.sh: nothing for a human to verify => must never trip the gate.
        out, _ = self.tick_live(_StubHoldSource(body="HUMAN-VERIFY:\n\n"),
                                review="PASS", health="CLEAN")
        self.assertEqual(out, "MERGE")

    # ── fail CLOSED on an unreadable body (HERD-237) ─────────────────────────────────────────────
    def test_unreadable_body_holds_and_journals_hv_body_unreadable(self):
        out, ev = self.tick_live(_StubHoldSource(body="", rc=124), review="PASS", health="CLEAN")
        self.assertEqual(out, "HOLD")
        self.assertFalse([o for o in ev if o["event"] == "merge"])
        un = [o for o in ev if o["event"] == "hv_body_unreadable"]
        self.assertEqual(len(un), 1)
        self.assertEqual(str(un[0]["pr"]), "1")
        self.assertEqual(un[0]["rc"], 124)
        self.assertIn("holding rather than merging", un[0]["detail"])
        # No ledger row and no hold_applied: nothing was DECIDED, so the next tick re-decides clean.
        self.assertEqual(self.ledger(), "")
        self.assertFalse([o for o in ev if o["event"] == "hold_applied"])

    # ── the awaiting row `herd approve` refuses to run without ───────────────────────────────────
    def test_hold_writes_the_awaiting_row_herd_approve_reads(self):
        self.tick_live(_StubHoldSource(body=_HV_BODY), review="PASS", health="CLEAN")
        row = self.ledger().split()
        self.assertEqual(row[1:4], ["awaiting", "1", "sha1"])

    def test_approve_policy_holds_with_kind_approve_not_approval(self):
        # bash wrote kind=approve; fleet.sh:1556 matches that literal to render "approval hold".
        out, ev = self.tick_live(_StubHoldSource(), config={"MERGE_POLICY": "approve"},
                                 review="PASS", health="CLEAN")
        self.assertEqual(out, "HOLD")
        self.assertEqual([o for o in ev if o["event"] == "hold_applied"][0]["kind"], "approve")

    def test_approve_policy_never_spends_a_body_read(self):
        # bash only fetched the body in auto mode — approve/observe hold every PR anyway.
        src = _StubHoldSource()
        self.tick_live(src, config={"MERGE_POLICY": "approve"}, review="PASS", health="CLEAN")
        self.assertEqual(src.body_reads, 0)

    # ── release: the approval the port could not see ─────────────────────────────────────────────
    def test_approved_hold_merges_and_journals_hold_released(self):
        src = _StubHoldSource(body=_HV_BODY, approved=True)
        out, ev = self.tick_live(src, review="PASS", health="CLEAN")
        self.assertEqual(out, "MERGE")
        rel = [o for o in ev if o["event"] == "hold_released"]
        self.assertEqual(len(rel), 1)
        self.assertEqual(rel[0]["kind"], "human-verify")
        self.assertEqual(rel[0]["reason"], "approved")
        self.assertEqual(str(rel[0]["sha"]), "sha1")

    def test_approve_policy_release_carries_kind_approve(self):
        out, ev = self.tick_live(_StubHoldSource(approved=True), config={"MERGE_POLICY": "approve"},
                                 review="PASS", health="CLEAN")
        self.assertEqual(out, "MERGE")
        self.assertEqual([o for o in ev if o["event"] == "hold_released"][0]["kind"], "approve")

    def test_an_unheld_merge_journals_no_release(self):
        # Byte-identical for the ordinary case: nothing was held, so nothing is released.
        out, ev = self.tick_live(_StubHoldSource(), review="PASS", health="CLEAN")
        self.assertEqual(out, "MERGE")
        self.assertFalse([o for o in ev if o["event"] == "hold_released"])

    def test_hv_auto_records_the_hv_informed_row_in_the_pre_merge_window(self):
        # The ledger is EPHEMERAL by design (approvals.sh): a merge purges every row for the PR, so
        # the row is only observable BEFORE the merge lands. A REFUSED merge is exactly that window —
        # and is a real production state (the API verify did not confirm MERGED).
        journal = LiveJournal(self.jpath)
        scenario = {"candidates": [self.one(1, review="PASS", health="CLEAN")],
                    "config": {"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "auto"}}
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     _RefusingActuator(journal), journal, state=LiveState(self.tmp),
                     hold_source=_StubHoldSource(body=_HV_BODY))
        t.run()
        self.assertEqual(self.ledger().split()[1:4], ["hv-informed", "1", "sha1"])

    def test_a_merge_purges_only_this_prs_approval_rows(self):
        # HERD-90: an old sha whose `awaiting` row survives the merge is a phantom hold that
        # `herd approve list` keeps surfacing for a long-merged PR.
        st = LiveState(self.tmp)
        st.record_approval("awaiting", 1, "old-sha")
        st.record_approval("awaiting", 2, "sha2")
        out, _ = self.tick_live(_StubHoldSource(approved=True), review="PASS", health="CLEAN")
        self.assertEqual(out, "MERGE")
        self.assertFalse(st.approval_awaiting_noted(1, "old-sha"))
        self.assertTrue(st.approval_awaiting_noted(2, "sha2"))

    # ── OFF-PATH: no hold_source ⇒ nothing moves ─────────────────────────────────────────────────
    # The restoration is live-only. Every sim, fixture and dry-run tick passes hold_source=None and
    # must be byte-identical to before it existed — pinned here rather than asserted in prose.
    def test_without_a_hold_source_the_event_stream_is_unchanged(self):
        res_a, ev_a = self.tick([self.one(1, review="PASS", health="CLEAN")])
        self.assertEqual(res_a["outcomes"]["1"], "MERGE")
        names = [o["event"] for o in ev_a]
        self.assertNotIn("hv_body_unreadable", names)
        self.assertNotIn("hold_released", names)
        self.assertEqual(self.ledger(), "")          # no ledger path is ever written off the live path

    def test_without_a_hold_source_an_injected_hv_hold_is_honored_verbatim(self):
        # A scenario that injects hv_hold must NOT be overwritten by a body read that never happens.
        res, ev = self.tick([self.one(1, review="PASS", health="CLEAN", hv_hold=True)])
        self.assertEqual(res["outcomes"]["1"], "HOLD")
        self.assertEqual([o for o in ev if o["event"] == "hold_applied"][0]["kind"], "human-verify")

    # ── HERD-671 leg 1: a POOLED body (discovery already fetched it) skips the live read entirely ──
    def test_pooled_body_never_spends_a_live_read(self):
        src = _StubHoldSource(body="whatever the live read would have said")
        out, ev = self.tick_live(src, review="PASS", health="CLEAN",
                                  hv_body=_HV_BODY, hv_body_pooled=True)
        self.assertEqual(out, "HOLD")
        self.assertEqual(src.body_reads, 0, "a pooled body must not also spend a live gh call")
        held = [o for o in ev if o["event"] == "hold_applied"]
        self.assertEqual(len(held), 1)
        self.assertEqual(held[0]["kind"], "human-verify")

    def test_pooled_body_with_no_block_still_merges(self):
        src = _StubHoldSource(body="whatever the live read would have said")
        out, ev = self.tick_live(src, review="PASS", health="CLEAN",
                                  hv_body="No manual steps here.\n", hv_body_pooled=True)
        self.assertEqual(out, "MERGE")
        self.assertEqual(src.body_reads, 0)
        self.assertFalse([o for o in ev if o["event"] == "hold_applied"])

    def test_pooled_empty_body_never_falls_back_to_a_live_unreadable_hold(self):
        # A pooled "" (a real, successfully-fetched empty body) must merge — never mistaken for the
        # unreadable-body fail-closed case, which only applies to the LIVE per-PR fallback read.
        src = _StubHoldSource(body="", rc=124)
        out, ev = self.tick_live(src, review="PASS", health="CLEAN",
                                  hv_body="", hv_body_pooled=True)
        self.assertEqual(out, "MERGE")
        self.assertEqual(src.body_reads, 0)
        self.assertFalse([o for o in ev if o["event"] == "hv_body_unreadable"])


class _RecordingHoldActuator(DryRunActuator):
    """A DryRunActuator that RECORDS post_comment/notify calls instead of no-opping them — the only
    way to observe the HERD-448 hold/merge actuator surface without shelling out to gh, mirroring
    _PromptRecordingActuator's pattern for the refix-bounce wake surface."""

    def __init__(self, journal):
        super().__init__(journal)
        self.comments = []   # (pr, kind, body)
        self.notifies = []   # (title, body, sound)
        self.edits = []      # (pr, kind, body) — HERD-464 supersession edits

    def post_comment(self, cand, kind, body):
        self.comments.append((cand.pr, kind, body))
        return True

    def notify(self, title, body, sound="default"):
        self.notifies.append((title, body, sound))

    def edit_comment(self, cand, kind, body):
        self.edits.append((cand.pr, kind, body))
        return True


class TestHoldNotifyActuator(LiveCase):
    """HERD-448: a hold is not silent to the PR author — it posts a comment and/or fires an operator
    notify, exactly once per (pr, sha, branch). Mutation-proven: neutralizing
    LiveTick._apply_hold_actuation, or either of the hv-auto / observe call sites, reds every test
    in this class (each asserts on act.comments/act.notifies, which only a live actuator call can
    populate)."""

    def tick_live(self, hold_source, actuator, config=None, **kw):
        cand = self.one(1, **kw)
        scenario = {"candidates": [cand], "config": config or {"MERGE_POLICY": "auto"}}
        journal = LiveJournal(self.jpath)
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     actuator, journal, state=LiveState(self.tmp), hold_source=hold_source)
        res = t.run()
        return res["outcomes"]["1"], (events(self.jpath) if os.path.exists(self.jpath) else [])

    # ── the three HOLD branches (agent-watch.sh:11878-11901, ede7d45^) ──────────────────────────────
    def test_coordinator_hold_posts_comment_and_notifies(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        out, ev = self.tick_live(
            _StubHoldSource(body=_HV_BODY), act,
            config={"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "coordinator"},
            review="PASS", health="CLEAN")
        self.assertEqual(out, "HOLD")
        self.assertEqual(len(act.comments), 1)
        pr, kind, body = act.comments[0]
        self.assertEqual(kind, "coordinator")
        self.assertIn("coordinator-actionable", body)
        self.assertIn("run the live smoke test", body)          # the declared step, verbatim
        self.assertIn("herd approve 1", body)
        self.assertEqual(len(act.notifies), 1)
        title, note, sound = act.notifies[0]
        self.assertIn("coordinator action needed", title)
        self.assertIn("herd approve 1", note)

    def test_human_verify_hold_posts_comment_and_notifies(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        out, ev = self.tick_live(_StubHoldSource(body=_HV_BODY), act, review="PASS", health="CLEAN")
        self.assertEqual(out, "HOLD")
        self.assertEqual(len(act.comments), 1)
        pr, kind, body = act.comments[0]
        self.assertEqual(kind, "human-verify")
        self.assertIn("must be **human-verified**", body)
        self.assertIn("run the live smoke test", body)
        self.assertEqual(len(act.notifies), 1)
        self.assertIn("human-verify pending", act.notifies[0][0])

    def test_approve_hold_posts_comment_and_notifies(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        out, ev = self.tick_live(_StubHoldSource(), act, config={"MERGE_POLICY": "approve"},
                                 review="PASS", health="CLEAN")
        self.assertEqual(out, "HOLD")
        self.assertEqual(len(act.comments), 1)
        pr, kind, body = act.comments[0]
        self.assertEqual(kind, "approve")
        self.assertIn("awaiting approval before", body)
        self.assertNotIn("HUMAN-VERIFY", body)
        self.assertEqual(len(act.notifies), 1)
        self.assertIn("awaiting approval", act.notifies[0][0])

    # ── idempotency: same once-guard already dedups hold_applied ───────────────────────────────────
    def test_hold_actuation_fires_once_across_reticks(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        src = _StubHoldSource(body=_HV_BODY)
        self.tick_live(src, act, review="PASS", health="CLEAN")
        self.tick_live(src, act, review="PASS", health="CLEAN")   # re-walk the SAME (pr, sha)
        self.assertEqual(len(act.comments), 1)
        self.assertEqual(len(act.notifies), 1)

    # ── the MERGE-branch informational comment (the case that went unnoticed 19 days) ───────────────
    def test_hv_auto_merge_posts_comment_but_no_notify(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        out, ev = self.tick_live(
            _StubHoldSource(body=_HV_BODY), act,
            config={"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "auto"},
            review="PASS", health="CLEAN")
        self.assertEqual(out, "MERGE")
        self.assertEqual(len(act.comments), 1)
        pr, kind, body = act.comments[0]
        self.assertEqual(kind, "hv-auto")
        self.assertIn("NOT executed before merge", body)
        self.assertIn("run the live smoke test", body)
        self.assertFalse(act.notifies)      # comment only — bash never notified on this branch either

    def test_hv_auto_comment_fires_once_across_reticks(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        src = _StubHoldSource(body=_HV_BODY)
        cfg = {"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "auto"}
        self.tick_live(src, act, config=cfg, review="PASS", health="CLEAN")
        self.tick_live(src, act, config=cfg, review="PASS", health="CLEAN")
        self.assertEqual(len(act.comments), 1)

    # ── the OBSERVE branch: notify only, never a comment ────────────────────────────────────────────
    def test_observe_notifies_but_posts_no_comment(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        out, ev = self.tick_live(_StubHoldSource(), act, config={"MERGE_POLICY": "observe"},
                                 review="PASS", health="CLEAN")
        self.assertEqual(out, "OBSERVE")
        self.assertFalse(act.comments)
        self.assertEqual(len(act.notifies), 1)
        title, note, sound = act.notifies[0]
        self.assertIn("ready (observe)", title)
        self.assertIn("observe mode, not merging", note)

    def test_observe_notify_fires_once_across_reticks(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        src = _StubHoldSource()
        cfg = {"MERGE_POLICY": "observe"}
        self.tick_live(src, act, config=cfg, review="PASS", health="CLEAN")
        self.tick_live(src, act, config=cfg, review="PASS", health="CLEAN")
        self.assertEqual(len(act.notifies), 1)

    # ── byte-identical when no hold fires ───────────────────────────────────────────────────────────
    def test_plain_merge_posts_nothing(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        out, ev = self.tick_live(_StubHoldSource(), act, review="PASS", health="CLEAN")
        self.assertEqual(out, "MERGE")
        self.assertFalse(act.comments)
        self.assertFalse(act.notifies)

    # ── DryRunActuator: posts nothing, ever ─────────────────────────────────────────────────────────
    def test_dry_run_actuator_posts_nothing_on_a_hold(self):
        journal = LiveJournal(self.jpath)
        act = DryRunActuator(journal)
        cand = LiveCandidate(1, "sha1", slug="pr-1", hv_body=_HV_BODY, hv_hold=True)
        self.assertTrue(act.post_comment(cand, "human-verify", "body text"))
        self.assertTrue(act.edit_comment(cand, "superseded", "body text"))
        self.assertIsNone(act.notify("title", "body"))
        ev = events(self.jpath) if os.path.exists(self.jpath) else []
        self.assertFalse(ev)   # no gh, no driver.sh, no journal line of its own


class TestLiveHoldCommentActuator(LiveCase):
    """LiveActuator.post_comment / .notify — the REAL gh / driver-seam shape (HERD-448), hermetic:
    subprocess is stubbed, exactly as TestLiveGateStatusPost proves post_gate_status."""

    def _actuator(self, sub):
        orig = LR.subprocess
        LR.subprocess = sub
        self.addCleanup(lambda: setattr(LR, "subprocess", orig))
        return LiveActuator("/nonexistent-home", LiveJournal(self.jpath))

    def test_post_comment_uses_gh_pr_comment_shape(self):
        sub = _RecordingSub()
        act = self._actuator(sub)
        cand = LiveCandidate(7, "deadbeef", slug="feat-x")
        self.assertTrue(act.post_comment(cand, "approve", "the comment body"))
        calls = [c for c in sub.calls if c[:3] == ["gh", "pr", "comment"]]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0], ["gh", "pr", "comment", "7", "--body", "the comment body"])
        ev = events(self.jpath) if os.path.exists(self.jpath) else []
        self.assertFalse([o for o in ev if o["event"] == "hold_comment_failed"])

    def test_failed_post_journals_hold_comment_failed_and_never_retries(self):
        class _FailingCommentSub:
            def __init__(self):
                self.calls = []

            def run(self, argv, *a, **k):
                self.calls.append(list(argv))
                if argv[:3] == ["gh", "pr", "comment"]:
                    raise subprocess.CalledProcessError(1, argv)
                return _FakeCompleted("")

        sub = _FailingCommentSub()
        act = self._actuator(sub)
        cand = LiveCandidate(7, "deadbeef", slug="feat-x")
        self.assertFalse(act.post_comment(cand, "human-verify", "body"))
        failed = [o for o in events(self.jpath) if o["event"] == "hold_comment_failed"]
        self.assertEqual(len(failed), 1)
        self.assertEqual(str(failed[0]["pr"]), "7")
        self.assertEqual(str(failed[0]["sha"]), "deadbeef")
        self.assertEqual(failed[0]["slug"], "feat-x")
        self.assertEqual(failed[0]["kind"], "human-verify")
        # Called exactly once — "never retried" is the CALLER's once-guard, not this method's job.
        self.assertEqual(len(sub.calls), 1)

    def test_edit_comment_uses_gh_pr_comment_edit_last_shape(self):
        sub = _RecordingSub()
        act = self._actuator(sub)
        cand = LiveCandidate(7, "deadbeef", slug="feat-x")
        self.assertTrue(act.edit_comment(cand, "superseded", "the superseded body"))
        calls = [c for c in sub.calls if c[:3] == ["gh", "pr", "comment"]]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0],
                         ["gh", "pr", "comment", "7", "--edit-last", "--body", "the superseded body"])
        ev = events(self.jpath) if os.path.exists(self.jpath) else []
        self.assertFalse([o for o in ev if o["event"] == "hold_comment_edit_failed"])

    def test_failed_edit_journals_hold_comment_edit_failed_and_never_retries(self):
        class _FailingCommentSub:
            def __init__(self):
                self.calls = []

            def run(self, argv, *a, **k):
                self.calls.append(list(argv))
                if argv[:3] == ["gh", "pr", "comment"]:
                    raise subprocess.CalledProcessError(1, argv)
                return _FakeCompleted("")

        sub = _FailingCommentSub()
        act = self._actuator(sub)
        cand = LiveCandidate(7, "deadbeef", slug="feat-x")
        self.assertFalse(act.edit_comment(cand, "superseded", "body"))
        failed = [o for o in events(self.jpath) if o["event"] == "hold_comment_edit_failed"]
        self.assertEqual(len(failed), 1)
        self.assertEqual(str(failed[0]["pr"]), "7")
        self.assertEqual(str(failed[0]["sha"]), "deadbeef")
        self.assertEqual(failed[0]["slug"], "feat-x")
        self.assertEqual(failed[0]["kind"], "superseded")
        self.assertEqual(len(sub.calls), 1)

    def test_notify_shells_out_through_the_driver_seam(self):
        sub = _RecordingSub()
        act = self._actuator(sub)
        act.notify("a title", "a body", "default")
        calls = [c for c in sub.calls
                 if len(c) >= 2 and c[0] == "bash" and str(c[1]).endswith("driver.sh")]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][2:], ["notify", "a title", "a body", "default"])

    def test_notify_never_raises_on_a_broken_driver(self):
        class _BoomSub:
            def run(self, *a, **k):
                raise OSError("no such file")

        act = self._actuator(_BoomSub())
        act.notify("title", "body")   # must not raise


class TestHoldCommentSupersession(LiveCase):
    """HERD-464: a hold comment self-updates when it stops reflecting reality — a new sha lands, an
    approval lands, or a policy change makes re-holding it impossible — instead of standing stale
    and misleading an operator into thinking a merge-ready PR is still gated. Mutation-proven:
    neutralizing LiveTick._supersede_hold_comment (or its call site in _walk) drops every
    hold_comment_superseded event and every act.edits entry these tests assert on."""

    def tick_live(self, act, sha, config=None, **kw):
        cand = self.one(1, sha=sha, **kw)
        scenario = {"candidates": [cand], "config": config or {"MERGE_POLICY": "auto"}}
        journal = LiveJournal(self.jpath)
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     act, journal, state=LiveState(self.tmp))
        res = t.run()
        return res["outcomes"]["1"]

    def _superseded_events(self):
        return [o for o in events(self.jpath) if o["event"] == "hold_comment_superseded"]

    # ── (a) a new sha lands — the OLD comment now names the wrong commit ───────────────────────────
    # NOTE: sha values here are real-hex-shaped ([0-9a-f]{7,40}) — LiveState.stale_inflight validates
    # a marker's sha via the shared _parse_marker_sha helper (HERD-471) and loud-skips anything that
    # doesn't parse as one, so a fixture sha must look like a real git sha to be discovered as stale.
    def test_new_sha_supersedes_a_human_verify_hold(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        cfg = {"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "hold"}
        out1 = self.tick_live(act, "aaaaaa1", config=cfg, hv_hold=True, review="PASS", health="CLEAN")
        self.assertEqual(out1, "HOLD")
        self.assertEqual(len(act.comments), 1)
        self.assertFalse(act.edits)

        out2 = self.tick_live(act, "bbbbbb2", config=cfg, hv_hold=False, review="PASS", health="CLEAN")
        self.assertEqual(out2, "MERGE")
        self.assertEqual(len(act.edits), 1)
        pr, kind, body = act.edits[0]
        self.assertEqual(kind, "superseded")
        self.assertIn("superseded", body)
        self.assertIn("sha advanced", body)
        sup = self._superseded_events()
        self.assertEqual(len(sup), 1)
        self.assertEqual(sup[0]["old_sha"], "aaaaaa1")
        self.assertEqual(str(sup[0]["sha"]), "bbbbbb2")

    # ── (b) an approval lands at the SAME sha — no new commit, but the hold is resolved ─────────────
    def test_approval_at_the_same_sha_supersedes_an_approve_hold(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        cfg = {"MERGE_POLICY": "approve"}
        out1 = self.tick_live(act, "ccccccc3", config=cfg, review="PASS", health="CLEAN")
        self.assertEqual(out1, "HOLD")
        pr, kind, _ = act.comments[0]
        self.assertEqual(kind, "approve")

        out2 = self.tick_live(act, "ccccccc3", config=cfg, approved=True, review="PASS", health="CLEAN")
        self.assertEqual(out2, "MERGE")
        self.assertEqual(len(act.edits), 1)
        pr, kind, body = act.edits[0]
        self.assertEqual(kind, "superseded")
        self.assertIn("approved", body)
        self.assertNotIn("sha advanced", body)

    # ── (c) a policy change at the SAME sha makes re-holding it impossible ──────────────────────────
    def test_policy_change_at_the_same_sha_supersedes_a_human_verify_hold(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        out1 = self.tick_live(act, "ddddddd4", config={"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "hold"},
                              hv_hold=True, review="PASS", health="CLEAN")
        self.assertEqual(out1, "HOLD")

        out2 = self.tick_live(act, "ddddddd4", config={"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "auto"},
                              hv_hold=True, review="PASS", health="CLEAN")
        self.assertEqual(out2, "MERGE")
        self.assertEqual(len(act.edits), 1)          # the STALE human-verify comment, edited
        self.assertEqual(len(act.comments), 2)        # tick1's human-verify + tick2's hv-auto
        pr, kind, body = act.edits[0]
        self.assertEqual(kind, "superseded")
        self.assertIn("policy=auto", body)
        self.assertNotIn("sha advanced", body)        # same commit both ticks

    # ── idempotency: the SAME stale comment is never edited twice ──────────────────────────────────
    def test_never_double_edits_across_reticks(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        cfg = {"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "hold"}
        self.tick_live(act, "eeeeeee5", config=cfg, hv_hold=True, review="PASS", health="CLEAN")
        self.tick_live(act, "fffffff6", config=cfg, hv_hold=False, review="PASS", health="CLEAN")
        self.tick_live(act, "fffffff6", config=cfg, hv_hold=False, review="PASS", health="CLEAN")
        self.assertEqual(len(act.edits), 1)
        self.assertEqual(len(self._superseded_events()), 1)

    # ── a candidate that never held has nothing to supersede — byte-inert ──────────────────────────
    def test_plain_merge_with_no_prior_hold_supersedes_nothing(self):
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        out = self.tick_live(act, "aaaaaaa7", review="PASS", health="CLEAN")
        self.assertEqual(out, "MERGE")
        self.assertFalse(act.edits)
        self.assertFalse(self._superseded_events())

    # ── DryRunActuator: journals the terminal event like every other hold side effect, edits nothing ─
    def test_dry_run_journals_the_supersession_with_no_real_edit(self):
        cfg = {"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "hold"}
        self.tick([self.one(1, sha="aaaaaaa8", hv_hold=True, review="PASS", health="CLEAN")], config=cfg)
        res2, ev2 = self.tick(
            [self.one(1, sha="bbbbbbb9", hv_hold=False, review="PASS", health="CLEAN")], config=cfg)
        self.assertEqual(res2["outcomes"]["1"], "MERGE")
        self.assertTrue([o for o in ev2 if o["event"] == "hold_comment_superseded"])

    # ── no state dir (a hermetic fixture with a black-hole state) — never crashes, never journals ──
    def test_no_state_dir_is_byte_inert(self):
        journal = LiveJournal(self.jpath)
        act = _RecordingHoldActuator(journal)
        cand = self.one(1, sha="aaaaaaaa10", hv_hold=True, review="PASS", health="CLEAN")
        scenario = {"candidates": [cand], "config": {"MERGE_POLICY": "auto", "HUMAN_VERIFY_POLICY": "hold"}}
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     act, journal, state=LiveState(None))
        res = t.run()
        self.assertEqual(res["outcomes"]["1"], "HOLD")
        self.assertFalse(act.edits)


class TestApprovalsLedger(LiveCase):
    """LiveState's half of the ledger — the same flat file herd-approve.sh reads and writes."""

    def setUp(self):
        LiveCase.setUp(self)
        self.st = LiveState(self.tmp)

    def test_exact_sha_match_only(self):
        self.st.record_approval("approved", 7, "abcdef123456")
        self.assertTrue(self.st.approval_is_approved(7, "abcdef123456"))
        self.assertFalse(self.st.approval_is_approved(7, "abcdef"))     # a prefix is NOT an approval
        self.assertFalse(self.st.approval_is_approved(70, "abcdef123456"))

    def test_awaiting_is_not_an_approval(self):
        self.st.record_approval("awaiting", 7, "s7")
        self.assertTrue(self.st.approval_awaiting_noted(7, "s7"))
        self.assertFalse(self.st.approval_is_approved(7, "s7"))

    def test_hv_informed_is_not_an_approval(self):
        # approvals.sh: "a record, NOT an approval" — nobody ran the declared steps.
        self.st.record_approval("hv-informed", 7, "s7")
        self.assertFalse(self.st.approval_is_approved(7, "s7"))

    def test_row_shape_matches_bash(self):
        self.st.record_approval("awaiting", 7, "s7")
        f = open(os.path.join(self.tmp, ".agent-watch-approvals")).read().split()
        self.assertEqual(len(f), 4)
        self.assertTrue(f[0].isdigit())                                  # <epoch> <state> <pr> <sha>
        self.assertEqual(f[1:], ["awaiting", "7", "s7"])

    def test_purge_drops_only_this_prs_rows(self):
        self.st.record_approval("awaiting", 7, "s7")
        self.st.record_approval("approved", 70, "s70")
        self.st.purge_pr_approvals(7)
        self.assertFalse(self.st.approval_awaiting_noted(7, "s7"))
        self.assertTrue(self.st.approval_is_approved(70, "s70"))         # PR 70 is not PR 7

    def test_no_state_dir_is_a_silent_no_op(self):
        st = LiveState(None)
        st.record_approval("awaiting", 1, "s1")                          # must not raise
        self.assertFalse(st.approval_is_approved(1, "s1"))
        st.purge_pr_approvals(1)


class TestHumanVerifyParser(unittest.TestCase):
    """The parse contract of human-verify.sh, in Python (the bash twin is pinned by
    tests/test-human-verify-parity.sh; these are the shape assertions)."""

    def test_bulleted_block(self):
        self.assertEqual(_hv.steps("HUMAN-VERIFY:\n- one\n- two\n\ntail"), ["one", "two"])

    def test_one_liner_form(self):
        self.assertEqual(_hv.steps("HUMAN-VERIFY: just this"), ["just this"])

    def test_markdown_decorated_marker(self):
        # A builder naturally writes the whole block as a list; a missing bullet here fails OPEN.
        self.assertEqual(_hv.steps("- **HUMAN-VERIFY:**\n- step a\n"), ["step a"])

    def test_bare_marker_is_not_a_hold(self):
        self.assertFalse(_hv.has("HUMAN-VERIFY:\n\nprose"))

    def test_absent_marker_is_not_a_hold(self):
        self.assertFalse(_hv.has("nothing to see"))

    def test_block_ends_at_the_first_blank_line(self):
        self.assertEqual(_hv.steps("HUMAN-VERIFY:\n- a\n\n- b\n"), ["a"])


# ── HERD-473: a BLOCK verdict records a machine-readable reason ───────────────────────────────────
_BLOCK_LINE = ("REVIEW: BLOCK — rule: unchecked nil deref | why: cand.sha may be empty on an "
               "adopted PR | location: live_runtime.py:3120")
_BLOCK_REASON = ("rule: unchecked nil deref | why: cand.sha may be empty on an adopted PR | "
                 "location: live_runtime.py:3120")


class TestBlockReasonParser(unittest.TestCase):
    """The pure parser half (HERD-473). The bash twin `_compose_block_reason` (agent-watch.sh) is
    pinned against these same cases by tests/test-block-verdict-reason.sh."""

    def test_structured_block_line(self):
        self.assertEqual(parse_block_fields(_BLOCK_LINE), {
            "rule": "unchecked nil deref",
            "why": "cand.sha may be empty on an adopted PR",
            "location": "live_runtime.py:3120"})
        self.assertEqual(parse_block_reason(_BLOCK_LINE), _BLOCK_REASON)

    def test_legacy_freeform_block_becomes_why(self):
        self.assertEqual(parse_block_reason("REVIEW: BLOCK — the merge loses the last commit"),
                         "why: the merge loses the last commit")

    def test_partial_fields_omit_the_absent_ones(self):
        self.assertEqual(parse_block_reason("REVIEW: BLOCK — why: wrong sign | location: a.sh:3"),
                         "why: wrong sign | location: a.sh:3")

    def test_field_order_is_canonical_not_source_order(self):
        # An operator reads the SAME shape whichever order the reviewer emitted the segments in.
        self.assertEqual(parse_block_reason("REVIEW: BLOCK — location: a.sh:3 | rule: R | why: W"),
                         "rule: R | why: W | location: a.sh:3")

    def test_pass_and_infra_carry_no_reason(self):
        self.assertEqual(parse_block_reason("REVIEW: PASS — advisory: rename this"), "")
        self.assertEqual(parse_block_reason("REVIEW: INFRA-FAIL — reviewer died"), "")
        self.assertEqual(parse_block_reason(""), "")

    def test_bare_block_has_no_parseable_payload(self):
        self.assertEqual(parse_block_reason("REVIEW: BLOCK"), "")

    def test_last_block_line_wins_like_the_verdict_parser(self):
        text = "REVIEW: BLOCK — why: first\nnoise\nREVIEW: BLOCK — why: second"
        self.assertEqual(parse_block_reason(text), "why: second")

    def test_whitespace_is_collapsed_so_the_reason_is_one_ledger_field(self):
        # The ledger row is space-delimited and the journal is one JSON line — a reason may carry
        # neither a newline nor a tab, or it would split the row / break the reader.
        r = parse_block_reason("REVIEW: BLOCK — why: a\tb   c")
        self.assertEqual(r, "why: a b c")
        self.assertNotIn("\n", r)
        self.assertNotIn("\t", r)

    def test_a_pathological_line_is_capped_not_propagated(self):
        r = parse_block_reason("REVIEW: BLOCK — why: " + "x" * 5000)
        self.assertEqual(len(r), len("why: ") + 200)

    def test_parser_never_raises_on_garbage(self):
        for junk in ("REVIEW:", "REVIEW: BLOCK —", "REVIEW: block — | | |", "—", "REVIEW: BLOCK—x"):
            parse_block_reason(junk)          # the assertion IS that nothing raises


class TestBlockReasonLedger(LiveCase):
    """The ledger half (HERD-473): the reason rides the row's TRAILING field, so the five positional
    fields every other reader parses are untouched, and a legacy reason-less row reads back cleanly."""

    def test_reason_rides_as_the_trailing_field(self):
        st = LiveState(self.tmp)
        st.record_review(7, "shaA", "BLOCK", "reviewer", _BLOCK_REASON)
        row = open(st.review_ledger(), encoding="utf-8").read().strip()
        f = row.split()
        self.assertEqual((f[1], f[2], f[3], f[4]), ("7", "shaA", "BLOCK", "reviewer"))
        self.assertEqual(" ".join(f[5:]), _BLOCK_REASON)
        self.assertEqual(st.recorded_review(7, "shaA"), "BLOCK")
        self.assertEqual(st.recorded_review_reason(7, "shaA"), _BLOCK_REASON)

    def test_no_reason_writes_the_pre_herd473_row_byte_identically(self):
        st = LiveState(self.tmp)
        st.record_review(7, "shaB", "PASS", "reviewer")
        row = open(st.review_ledger(), encoding="utf-8").read().strip()
        self.assertEqual(len(row.split()), 5)
        self.assertEqual(st.recorded_review_reason(7, "shaB"), "")

    def test_legacy_reason_less_row_reads_back_empty_not_an_error(self):
        with open(os.path.join(self.tmp, ".agent-watch-reviewed"), "w", encoding="utf-8") as fh:
            fh.write("1720000000 9 shaC BLOCK reviewer\n")
        st = LiveState(self.tmp)
        self.assertEqual(st.recorded_review(9, "shaC"), "BLOCK")
        self.assertEqual(st.recorded_review_reason(9, "shaC"), "")

    def test_missing_ledger_reads_back_empty(self):
        self.assertEqual(LiveState(os.path.join(self.tmp, "nope")).recorded_review_reason(1, "s"), "")

    def test_last_matching_row_wins_like_the_verdict(self):
        st = LiveState(self.tmp)
        st.record_review(7, "shaD", "BLOCK", "reviewer", "why: first")
        st.record_review(7, "shaD", "BLOCK", "reviewer", "why: second")
        self.assertEqual(st.recorded_review_reason(7, "shaD"), "why: second")

    def test_another_prs_reason_is_never_returned(self):
        st = LiveState(self.tmp)
        st.record_review(7, "shaE", "BLOCK", "reviewer", "why: mine")
        self.assertEqual(st.recorded_review_reason(8, "shaE"), "")
        self.assertEqual(st.recorded_review_reason(7, "shaF"), "")

    def test_collecting_a_block_verdict_records_its_reason(self):
        # The real rail: LiveGates.review consumes the reviewer's result file, so the reason is
        # parsed and durably recorded in the SAME write that records the verdict.
        st = LiveState(self.tmp)
        cand = LiveCandidate(pr="7", slug="feat-x", sha="shaG")
        with open(st.review_result_file(cand), "w", encoding="utf-8") as fh:
            fh.write(_BLOCK_LINE + "\n")
        journal = LiveJournal(self.jpath)
        gates = LiveGates(self.tmp, st, journal, config={})
        self.assertEqual(gates.review(cand), "BLOCK")
        self.assertEqual(st.recorded_review_reason("7", "shaG"), _BLOCK_REASON)

    def test_collecting_a_pass_records_no_reason(self):
        st = LiveState(self.tmp)
        cand = LiveCandidate(pr="7", slug="feat-x", sha="shaH")
        with open(st.review_result_file(cand), "w", encoding="utf-8") as fh:
            fh.write("REVIEW: PASS\n")
        gates = LiveGates(self.tmp, st, LiveJournal(self.jpath), config={})
        self.assertEqual(gates.review(cand), "PASS")
        self.assertEqual(st.recorded_review_reason("7", "shaH"), "")


class TestBlockReasonJournal(LiveCase):
    """The journal half (HERD-473): `verdict_recorded` gains `reason` — read back from the ledger, so
    the two can never disagree — and stays byte-identical when there is none."""

    def test_verdict_recorded_carries_the_reason(self):
        LiveState(self.tmp).record_review(1, "sha1", "BLOCK", "reviewer", _BLOCK_REASON)
        res, ev = self.tick([self.one(1, review="BLOCK", health="CLEAN", agent_status="idle")])
        vr = [o for o in ev if o["event"] == "verdict_recorded"]
        self.assertEqual(len(vr), 1)
        self.assertEqual(vr[0]["value"], "BLOCK")
        self.assertEqual(vr[0]["reason"], _BLOCK_REASON)

    def test_reason_less_verdict_recorded_is_byte_identical(self):
        res, ev = self.tick([self.one(1, review="BLOCK", health="CLEAN", agent_status="idle")])
        vr = [o for o in ev if o["event"] == "verdict_recorded"]
        self.assertEqual(len(vr), 1)
        self.assertNotIn("reason", vr[0])

    def test_a_pass_never_carries_a_reason(self):
        res, ev = self.tick([self.one(1, review="PASS", health="CLEAN")])
        vr = [o for o in ev if o["event"] == "verdict_recorded"]
        self.assertNotIn("reason", vr[0])


class TestBlockReasonComment(LiveCase):
    """The PR surface (HERD-473, contract §5.6): a BLOCK that has spent its refix budget escalates to
    a human, and now TELLS that human what the objection was — through the same #577 comment actuator
    and the same once-guard. Mutation-proven: dropping the post_comment call reds the first three."""

    def _escalating_tick(self, reason=None, config=None):
        # Seed the refix ledger so the review rail's budget is already spent for this PR — the exact
        # state that escalates a standing BLOCK to a human instead of bouncing the builder again.
        LR._append_refix_ledger(self.tmp, "1720000000 1 sha-old feat-x review\n")
        if reason is not None:
            LiveState(self.tmp).record_review(1, "sha1", "BLOCK", "reviewer", reason)
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        cand = self.one(1, review="BLOCK", health="CLEAN", slug="feat-x", agent_status="idle")
        scenario = {"candidates": [cand],
                    "config": config or {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "1"}}
        journal = LiveJournal(self.jpath)
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     act, journal, state=LiveState(self.tmp))
        res = t.run()
        return res["outcomes"]["1"], act, events(self.jpath)

    def test_escalated_block_posts_the_reason_to_the_pr(self):
        out, act, ev = self._escalating_tick(reason=_BLOCK_REASON)
        self.assertEqual(out, "ESCALATE")
        self.assertEqual(len(act.comments), 1)
        pr, kind, body = act.comments[0]
        self.assertEqual(kind, "review-block")
        self.assertIn(_BLOCK_REASON, body)                  # the reviewer's words, verbatim
        self.assertIn("herd approve why 1", body)

    def test_a_reason_less_block_says_so_instead_of_going_quiet(self):
        # #576's actual harm was TEXT THAT WAS NOT THE OBJECTION reading as if it were. With no
        # reason recorded the comment must state that, and warn off exactly that misreading.
        out, act, ev = self._escalating_tick(reason=None)
        self.assertEqual(out, "ESCALATE")
        self.assertEqual(len(act.comments), 1)
        body = act.comments[0][2]
        self.assertIn("no structured reason", body)
        self.assertNotIn("Reviewer's stated reason:\n\n> ", body)

    def test_the_comment_is_posted_once_per_sha_not_once_per_tick(self):
        out, act, ev = self._escalating_tick(reason=_BLOCK_REASON)
        self.assertEqual(out, "ESCALATE")
        cand = self.one(1, review="BLOCK", health="CLEAN", slug="feat-x", agent_status="idle")
        scenario = {"candidates": [cand], "config": {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "1"}}
        journal = LiveJournal(self.jpath)
        t2 = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                      act, journal, state=LiveState(self.tmp))
        self.assertEqual(t2.run()["outcomes"]["1"], "ESCALATE")
        self.assertEqual(len(act.comments), 1, "a re-walked blocked PR must never re-post")

    def test_a_bounced_block_posts_nothing(self):
        # Budget REMAINING → the builder is re-tasked, not the human. No comment on that path.
        act = _RecordingHoldActuator(LiveJournal(self.jpath))
        cand = self.one(1, review="BLOCK", health="CLEAN", slug="feat-x", agent_status="idle")
        scenario = {"candidates": [cand], "config": {"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "3"}}
        journal = LiveJournal(self.jpath)
        t = LiveTick(scenario["config"], FixtureDiscovery(scenario), FixtureGates(scenario),
                     act, journal, state=LiveState(self.tmp))
        self.assertEqual(t.run()["outcomes"]["1"], "BLOCK")
        self.assertEqual(act.comments, [])

    def test_dry_run_actuator_posts_nothing(self):
        LR._append_refix_ledger(self.tmp, "1720000000 1 sha-old feat-x review\n")
        LiveState(self.tmp).record_review(1, "sha1", "BLOCK", "reviewer", _BLOCK_REASON)
        orig = LR.subprocess
        LR.subprocess = _Poison()
        try:
            res, ev = self.tick([self.one(1, review="BLOCK", health="CLEAN", slug="feat-x",
                                          agent_status="idle")],
                                config={"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "1"})
        finally:
            LR.subprocess = orig
        self.assertEqual(res["outcomes"]["1"], "ESCALATE")


class TestReviewFastPath(LiveCase):
    """HERD-559 — the review fast path ON THE LIVE CORE: the mechanical-red pre-gate, the risk-tier
    classification the engine port never carried across, and the latency telemetry.

    Every lever here ships DORMANT, so each leg is asserted BOTH ways: on (the new behavior) and off
    (byte-identical dispatch). The shared shell script is stubbed with a tiny fake so these stay pure
    unit tests — scripts/herd/review-pregate.sh's own behavior is pinned by tests/test-review-pregate.sh.
    """

    class _Sub:
        """subprocess stand-in: canned rc/stdout per argv[2] ('lint' | 'floor' | a gh call), and it
        records every Popen so a test can assert a reviewer was NOT launched."""

        DEVNULL = LR.subprocess.DEVNULL

        class _Proc:
            pid = 909

        class _Done:
            def __init__(self, rc, out):
                self.returncode, self.stdout, self.stderr = rc, out, ""

        def __init__(self, results):
            self.results = results          # {"lint": (rc, out), "floor": (rc, ""), "gh": (rc, out)}
            self.popens = []

        def run(self, argv, **k):
            key = "gh" if argv and argv[0] == "gh" else (argv[2] if len(argv) > 2 else "")
            rc, out = self.results.get(key, (0, ""))
            return self._Done(rc, out)

        def Popen(self, *a, **k):
            self.popens.append((a, k))
            return self._Proc()

    def _gates(self, config, results):
        state = LiveState(state_dir=self.tmp)
        journal = LiveJournal(self.jpath)
        gates = LiveGates(self.tmp, state, journal, config=config)
        sub = self._Sub(results)
        return gates, state, sub

    def _review(self, gates, sub, cand):
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            return gates.review(cand)
        finally:
            LR.subprocess = orig

    def _cand(self):
        # cand.worktree must be a real directory for the pre-gate/floor probes to run at all.
        wt = os.path.join(self.tmp, "wt"); os.makedirs(wt, exist_ok=True)
        return LiveCandidate(11, "shaX", slug="feat-fast", worktree=wt)

    def _script_present(self, gates):
        """The probes require the shared script to EXIST; LiveGates resolves it under its home."""
        p = os.path.join(self.tmp, "scripts", "herd")
        os.makedirs(p, exist_ok=True)
        open(os.path.join(p, "review-pregate.sh"), "w").close()
        return gates

    # ── leg 1: the mechanical-red pre-gate ────────────────────────────────────────────────────────
    def test_pregate_red_blocks_without_dispatching_a_reviewer(self):
        findings = "PREGATE pipe-safety: a producer piped into an early-exit consumer\n  scripts/herd/x.sh:3\n"
        gates, state, sub = self._gates({"REVIEW_PREGATE": "on"}, {"lint": (1, findings)})
        self._script_present(gates)
        v = self._review(gates, sub, self._cand())
        self.assertEqual(v, "BLOCK")
        self.assertEqual(sub.popens, [])                       # NO reviewer process was launched
        ev = [o for o in events(self.jpath) if o["event"] == "review_pregate_red"]
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]["lints"], "pipe-safety")
        self.assertEqual([o for o in events(self.jpath) if o["event"] == "review_dispatched"], [])
        # Provenance: a deterministic lint refusal is NOT a model's correctness finding.
        self.assertEqual(state.recorded_review(11, "shaX"), "BLOCK")
        self.assertEqual(state.recorded_review_source(11, "shaX"), "pregate")

    def test_pregate_skip_and_off_both_dispatch_as_today(self):
        # rc 2 (the script could not attribute its findings) is treated exactly like clean: a pre-gate
        # that is not sure must never bounce a builder onto a red it cannot fix.
        for label, config, lint in (("skip", {"REVIEW_PREGATE": "on"}, (2, "")),
                                    ("off", {}, (1, "PREGATE caps-sync: x\n"))):
            with self.subTest(label):
                self.setUp()
                gates, state, sub = self._gates(config, {"lint": lint})
                self._script_present(gates)
                v = self._review(gates, sub, self._cand())
                self.assertEqual(v, WAIT)                      # dispatched -> wait
                self.assertEqual(len(sub.popens), 1)
                self.assertEqual([o for o in events(self.jpath)
                                  if o["event"] == "review_pregate_red"], [])

    # ── leg 2: the risk tier + the mechanical floor ───────────────────────────────────────────────
    def test_tiering_off_is_byte_identical(self):
        # The lever off means no classification at all: no gh call, and the reviewer runs on the
        # project default exactly as it did before this feature existed.
        gates, state, sub = self._gates({"REVIEW_ESCALATE_GLOB": "^bin/"}, {})
        self.assertEqual(gates._review_tier(self._cand()), ("STRONG", ""))

    def test_tier_classification_matches_the_bash_contract(self):
        cfg = {"REVIEW_TIERING": "on", "REVIEW_ESCALATE_GLOB": "^bin/",
               "DOCS_ONLY_GLOB": r"[.](md|txt)", "REVIEW_MODEL_CHEAP": "cheap",
               "REVIEW_MODEL_DOCS": "docs-model", "REVIEW_ESCALATE_MAXFILES": "3"}
        cases = [
            ("README.md\ntests/test-x.sh\n", ("SKIP", "")),          # docs/test-only -> no reviewer
            ("bin/herd\n", ("STRONG", "")),                          # escalate glob wins
            ("a.txt\nb.txt\n", ("DOCS", "docs-model")),              # every path matches DOCS_ONLY_GLOB
            ("src/a.py\n", ("CHEAP", "cheap")),                      # small + low risk
            ("a.py\nb.py\nc.py\nd.py\n", ("STRONG", "")),            # over REVIEW_ESCALATE_MAXFILES
            ("", ("STRONG", "")),                                    # unreadable/empty diff fails SAFE
        ]
        for paths, want in cases:
            with self.subTest(paths=paths):
                gates, _, sub = self._gates(cfg, {"gh": (0, paths)})
                orig = LR.subprocess
                LR.subprocess = sub
                try:
                    self.assertEqual(gates._review_tier(self._cand()), want)
                finally:
                    LR.subprocess = orig

    def test_unparseable_escalate_glob_fails_to_strong(self):
        # A SAFETY glob that does not compile must never silently stop forcing the strong tier.
        gates, _, sub = self._gates({"REVIEW_TIERING": "on", "REVIEW_ESCALATE_GLOB": "([unclosed",
                                     "REVIEW_MODEL_CHEAP": "cheap"}, {"gh": (0, "src/a.py\n")})
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            self.assertEqual(gates._review_tier(self._cand()), ("STRONG", ""))
        finally:
            LR.subprocess = orig

    def test_mech_floor_lowers_only_the_strong_default(self):
        cfg = {"REVIEW_TIERING": "on", "REVIEW_MECH_FLOOR": "on", "REVIEW_MODEL_CHEAP": "cheap"}
        gates, _, sub = self._gates(cfg, {"gh": (0, "templates/capabilities.tsv\n"), "floor": (0, "")})
        self._script_present(gates)
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            self.assertEqual(gates._review_tier(self._cand()), ("CHEAP", "cheap"))
        finally:
            LR.subprocess = orig
        self.assertEqual(len([o for o in events(self.jpath) if o["event"] == "review_tier_floor"]), 1)

    def test_mech_floor_never_fires_on_a_non_mechanical_diff(self):
        cfg = {"REVIEW_TIERING": "on", "REVIEW_MECH_FLOOR": "on", "REVIEW_MODEL_CHEAP": "cheap"}
        # rc 1 = not mechanical, rc 2 = undecidable; BOTH must leave the strong default alone.
        for rc in (1, 2):
            with self.subTest(rc=rc):
                self.setUp()
                gates, _, sub = self._gates(cfg, {"gh": (0, "src/a.py\n"), "floor": (rc, "")})
                self._script_present(gates)
                orig = LR.subprocess
                LR.subprocess = sub
                try:
                    self.assertEqual(gates._review_tier(self._cand()), ("STRONG", ""))
                finally:
                    LR.subprocess = orig

    def test_tier_model_is_pinned_into_the_reviewer_env(self):
        # The tier's model must beat the project default AND be the value journaled — the HERD-353
        # single-resolution-point invariant, extended to the tier.
        # *.txt, not *.md: an all-.md diff hits the hardcoded docs/test-only SKIP before any tier,
        # so the DOCS tier is only reachable through a doc format that SKIP does not cover.
        cfg = {"REVIEW_TIERING": "on", "DOCS_ONLY_GLOB": r"[.]txt", "REVIEW_MODEL_DOCS": "docs-model"}
        gates, _, sub = self._gates(cfg, {"gh": (0, "docs/x.txt\ndocs/y.txt\n")})
        saved = os.environ.get("MODEL_REVIEW")
        os.environ["MODEL_REVIEW"] = "opus-default"
        try:
            v = self._review(gates, sub, self._cand())
        finally:
            if saved is None:
                os.environ.pop("MODEL_REVIEW", None)
            else:
                os.environ["MODEL_REVIEW"] = saved
        self.assertEqual(v, WAIT)
        rd = [o for o in events(self.jpath) if o["event"] == "review_dispatched"]
        self.assertEqual(rd[0]["model"], "docs-model")
        self.assertEqual(sub.popens[0][1]["env"].get("HERD_REVIEW_MODEL"), "docs-model")

    # ── leg 3: latency telemetry ──────────────────────────────────────────────────────────────────
    def test_review_latency_is_journaled_on_collect_and_off_is_a_no_op(self):
        for config, want in ({}, 1), ({"REVIEW_LATENCY": "off"}, 0):
            with self.subTest(config=config):
                self.setUp()
                gates, state, sub = self._gates(config, {})
                cand = self._cand()
                # A finished reviewer: a verdict file plus an inflight marker carrying a dispatch ts.
                with open(state.review_result_file(cand), "w") as fh:
                    fh.write("REVIEW: PASS\n")
                _marker_write(state.review_inflight_file(cand), os.getpid())
                self.assertEqual(self._review(gates, sub, cand), "PASS")
                # off must journal NOTHING at all — the file may not even exist, which is itself the
                # byte-identical proof, so a missing journal reads as zero events rather than an error.
                lat = [o for o in (events(self.jpath) if os.path.exists(self.jpath) else [])
                       if o["event"] == "review_latency"]
                self.assertEqual(len(lat), want)
                if want:
                    self.assertEqual(lat[0]["verdict"], "PASS")
                    self.assertGreaterEqual(int(lat[0]["secs"]), 0)


def _make_delta_review_repo(tmp, name, authored_after_merge=False):
    """A repo where `feat` branches off `main`, `main` then advances, and `feat` merges `main` back in —
    a pure integration merge unless `authored_after_merge` amends it with a post-merge edit. Returns
    (repo_dir, old_sha, new_sha): `old_sha` is feat's pre-merge head (the "last-passed" carry source),
    `new_sha` is the merge commit (or its amended twin). Mirrors tests/test-delta-review.sh's
    build_integration() fixture, single repo dir with serial checkouts (no worktrees needed — the git
    plumbing under test reads objects by sha, not working-tree state)."""
    d = os.path.join(tmp, name)
    _git_init_repo(d)
    subprocess.run(["git", "-C", d, "checkout", "-q", "-b", "feat"], check=True)
    with open(os.path.join(d, "feature.txt"), "w", encoding="utf-8") as fh:
        fh.write("branch work\n")
    subprocess.run(["git", "-C", d, "add", "feature.txt"], check=True)
    subprocess.run(["git", "-C", d, "commit", "-q", "-m", "feat work"], check=True)
    old = subprocess.check_output(["git", "-C", d, "rev-parse", "HEAD"]).decode().strip()
    subprocess.run(["git", "-C", d, "checkout", "-q", "main"], check=True)
    with open(os.path.join(d, "mainfile.txt"), "w", encoding="utf-8") as fh:
        fh.write("main advance\n")
    subprocess.run(["git", "-C", d, "add", "mainfile.txt"], check=True)
    subprocess.run(["git", "-C", d, "commit", "-q", "-m", "main advance"], check=True)
    subprocess.run(["git", "-C", d, "checkout", "-q", "feat"], check=True)
    subprocess.run(["git", "-C", d, "merge", "-q", "--no-edit", "main"], check=True)
    if authored_after_merge:
        with open(os.path.join(d, "feature.txt"), "a", encoding="utf-8") as fh:
            fh.write("sneaky authored change\n")
        subprocess.run(["git", "-C", d, "add", "feature.txt"], check=True)
        subprocess.run(["git", "-C", d, "commit", "-q", "--amend", "--no-edit"], check=True)
    new = subprocess.check_output(["git", "-C", d, "rev-parse", "HEAD"]).decode().strip()
    return d, old, new


class TestDeltaReviewCarryForward(LiveCase):
    """HERD-580: port DELTA_REVIEW (HERD-204) into the live core. agent-watch.sh's own implementation
    (_maybe_carry_forward_review) has had no reachable caller since the P5b engine port — its only
    caller was the dead _review_gate_step — so this is a fresh Python implementation, exercised here
    directly against LiveGates.review() (not FixtureGates) with REAL git repos, mirroring
    tests/test-delta-review.sh's own fixtures. The bash body is kept only for its own unit test."""

    def _gates(self, config):
        state = LiveState(state_dir=self.tmp)
        journal = LiveJournal(self.jpath)
        return LiveGates(self.tmp, state, journal, config=config), state, journal

    def test_integration_only_merge_carries_forward_without_dispatch(self):
        d, old, new = _make_delta_review_repo(self.tmp, "dr1")
        gates, state, _ = self._gates({"DELTA_REVIEW": "on"})
        state.record_review(11, old, "PASS", "reviewer", "")
        cand = LiveCandidate(11, new, slug="feat", worktree=d)
        v = gates.review(cand)
        self.assertEqual(v, "PASS")
        self.assertEqual(state.recorded_review(11, new), "PASS")
        self.assertEqual(state.recorded_review_source(11, new), "carried-forward")
        self.assertFalse(os.path.exists(state.review_inflight_file(cand)))
        ev = [o for o in events(self.jpath) if o["event"] == "review_carried_forward"]
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]["pr"], 11)
        self.assertEqual(ev[0]["from_sha"], old)

    def test_lever_off_dispatches_normally(self):
        d, old, new = _make_delta_review_repo(self.tmp, "dr2")
        gates, state, _ = self._gates({})
        state.record_review(12, old, "PASS", "reviewer", "")
        cand = LiveCandidate(12, new, slug="feat", worktree=d)
        sub = TestReviewFastPath._Sub({})
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            v = gates.review(cand)
        finally:
            LR.subprocess = orig
        self.assertEqual(v, WAIT)
        self.assertEqual(len(sub.popens), 1)
        self.assertNotEqual(state.recorded_review_source(12, new), "carried-forward")

    def test_authored_change_beyond_merge_never_carries_forward(self):
        d, old, new = _make_delta_review_repo(self.tmp, "dr3", authored_after_merge=True)
        gates, state, _ = self._gates({"DELTA_REVIEW": "on"})
        state.record_review(13, old, "PASS", "reviewer", "")
        cand = LiveCandidate(13, new, slug="feat", worktree=d)
        sub = TestReviewFastPath._Sub({})
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            v = gates.review(cand)
        finally:
            LR.subprocess = orig
        self.assertEqual(v, WAIT, "an authored edit beyond the merge must dispatch a full review")
        self.assertEqual(len(sub.popens), 1)
        self.assertEqual([o for o in events(self.jpath) if o["event"] == "review_carried_forward"], [])

    def test_no_prior_pass_never_carries_forward(self):
        d, _old, new = _make_delta_review_repo(self.tmp, "dr4")
        gates, state, _ = self._gates({"DELTA_REVIEW": "on"})
        cand = LiveCandidate(14, new, slug="feat", worktree=d)
        sub = TestReviewFastPath._Sub({})
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            v = gates.review(cand)
        finally:
            LR.subprocess = orig
        self.assertEqual(v, WAIT)
        self.assertEqual(len(sub.popens), 1)

    def test_unparseable_lever_value_is_off(self):
        self.assertFalse(LR._delta_review_enabled({"DELTA_REVIEW": "yes"}))
        self.assertFalse(LR._delta_review_enabled({}))
        self.assertTrue(LR._delta_review_enabled({"DELTA_REVIEW": "on"}))


class TestReviewModelEscalation(LiveCase):
    """HERD-580: port REVIEW_MODEL_ESCALATED / REVIEW_EVIDENCE_ESCALATE_ROUNDS (agent-watch.sh's
    _maybe_arm_review_escalation and the review dispatch's arm consumption) into the live core. Both
    keys' only consumers hung off the dead bash review pass since P5b; tests/test-review-escalation.sh
    pins the bash shape (kept for its own unit test, unreachable in production).

    The ARM side is driven through LiveTick (FixtureGates review=BLOCK across rounds, mirroring
    TestRefixWakeVerification's multi-round pattern — a fresh sha per round, same PR, so the once-guard
    never suppresses a round). The CONSUME side is driven directly through LiveGates.review(), the real
    live dispatch — the arm is a plain per-PR marker file, so both halves interoperate through the SAME
    LiveState exactly as the two bash halves did.
    """

    def _walk(self, pr, sha, config=None, **kw):
        cfg = dict({"MERGE_POLICY": "auto", "REFIX_MAX_ROUNDS": "5"}, **(config or {}))
        j = LiveJournal(os.path.join(self.tmp, "walk-%s-%s.jsonl" % (pr, sha)))
        cand = dict({"review": "BLOCK", "health": "CLEAN", "agent_status": "idle"}, pr=pr, sha=sha, **kw)
        t = LiveTick(cfg, FixtureDiscovery({"candidates": [cand], "config": cfg}),
                     FixtureGates({"candidates": [cand], "config": cfg}),
                     DryRunActuator(j), j, state=LiveState(self.tmp))
        return t.run(), events(j.path)

    def test_two_block_rounds_arm_the_escalation_marker(self):
        state = LiveState(self.tmp)
        res1, _ = self._walk(21, "sha-r1")
        self.assertEqual(res1["outcomes"]["21"], "BLOCK")
        self.assertFalse(os.path.exists(state.review_escalate_file(21)),
                         "one BLOCK round must not arm (default threshold is 2)")
        res2, _ = self._walk(21, "sha-r2")
        self.assertEqual(res2["outcomes"]["21"], "BLOCK")
        self.assertTrue(os.path.exists(state.review_escalate_file(21)),
                        "a second failed REVIEW round must arm the escalation marker")

    def test_lifetime_count_survives_a_rail_reset_between_bounces(self):
        # PR #711 review finding: arming must use the LIFETIME review-bounce count
        # (D.refix_round_count_kind), not the rail's reset-zeroable round_num. Reproduces the exact
        # counter-example: bounce (rail=1, lifetime=1) -> review PASSes, resetting the rail (rail=0,
        # lifetime=1, unchanged — a reset never refunds the lifetime count) -> a LATER sha bounces
        # review again (rail=1, lifetime=2) -> must still arm at the default threshold of 2, even
        # though the RAIL count alone never reaches 2 across this sequence.
        state = LiveState(self.tmp)
        res1, _ = self._walk(25, "sha-a")                       # review BLOCK -> rail=1, lifetime=1
        self.assertEqual(res1["outcomes"]["25"], "BLOCK")
        self.assertFalse(os.path.exists(state.review_escalate_file(25)))

        res2, _ = self._walk(25, "sha-b", review="PASS")        # review PASS -> resets the rail to 0
        self.assertNotEqual(res2["outcomes"]["25"], "BLOCK")
        self.assertFalse(os.path.exists(state.review_escalate_file(25)),
                         "a PASS must never arm anything on its own")

        res3, _ = self._walk(25, "sha-c")                       # review BLOCK again -> rail=1, lifetime=2
        self.assertEqual(res3["outcomes"]["25"], "BLOCK")
        self.assertTrue(os.path.exists(state.review_escalate_file(25)),
                        "the LIFETIME count (2) must arm even though the rail-budget round number is "
                        "only 1 at this bounce (the rail was reset by the intervening PASS)")

    def test_health_rounds_never_arm_review_escalation(self):
        # REVIEW_EVIDENCE_ESCALATE_ROUNDS counts REVIEW-kind bounces ONLY — a healthcheck bounce is
        # evidence about the SUITE, not the reviewer, and must never arm an Opus re-review.
        state = LiveState(self.tmp)
        self._walk(22, "h1", health="CODEERROR", review="PASS")
        self._walk(22, "h2", health="CODEERROR", review="PASS")
        self.assertFalse(os.path.exists(state.review_escalate_file(22)))

    def test_custom_threshold_honored(self):
        state = LiveState(self.tmp)
        res, _ = self._walk(23, "sha-x", config={"REVIEW_EVIDENCE_ESCALATE_ROUNDS": "1"})
        self.assertEqual(res["outcomes"]["23"], "BLOCK")
        self.assertTrue(os.path.exists(state.review_escalate_file(23)),
                        "threshold=1 must arm on the FIRST failed round")

    def test_garbage_threshold_never_arms(self):
        state = LiveState(self.tmp)
        cfg = {"REVIEW_EVIDENCE_ESCALATE_ROUNDS": "banana"}
        for sha in ("g1", "g2", "g3"):
            self._walk(24, sha, config=cfg)
        self.assertFalse(os.path.exists(state.review_escalate_file(24)),
                         "a non-numeric SET threshold must fail safe to 'never arm', matching bash's "
                         "`[ N -ge garbage ]` erroring to a non-zero test rather than defaulting to 2")

    def _gates(self, config):
        state = LiveState(state_dir=self.tmp)
        journal = LiveJournal(self.jpath)
        return LiveGates(self.tmp, state, journal, config=config), state, journal

    def test_armed_escalation_forces_the_model_and_consumes_the_marker(self):
        gates, state, _ = self._gates({"REVIEW_MODEL_ESCALATED": "opus-test"})
        open(state.review_escalate_file(31), "w").close()
        cand = LiveCandidate(31, "shaE", slug="feat-esc")
        sub = TestReviewFastPath._Sub({})
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            v = gates.review(cand)
        finally:
            LR.subprocess = orig
        self.assertEqual(v, WAIT)
        self.assertEqual(len(sub.popens), 1)
        self.assertEqual(sub.popens[0][1]["env"].get("HERD_REVIEW_MODEL"), "opus-test")
        self.assertFalse(os.path.exists(state.review_escalate_file(31)), "the arm must be one-shot")
        esc = [o for o in events(self.jpath) if o["event"] == "review_escalated"]
        self.assertEqual(len(esc), 1)
        self.assertEqual(esc[0]["model"], "opus-test")

    def test_armed_escalation_default_model_is_opus(self):
        gates, state, _ = self._gates({})
        open(state.review_escalate_file(32), "w").close()
        cand = LiveCandidate(32, "shaF", slug="feat-esc2")
        sub = TestReviewFastPath._Sub({})
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            gates.review(cand)
        finally:
            LR.subprocess = orig
        self.assertEqual(sub.popens[0][1]["env"].get("HERD_REVIEW_MODEL"), "claude-opus-4-8")

    def test_no_marker_dispatches_on_the_ordinary_tier(self):
        gates, state, _ = self._gates({"REVIEW_MODEL_ESCALATED": "opus-test"})
        cand = LiveCandidate(33, "shaG", slug="feat-esc3")
        sub = TestReviewFastPath._Sub({})
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            gates.review(cand)
        finally:
            LR.subprocess = orig
        self.assertNotEqual(sub.popens[0][1]["env"].get("HERD_REVIEW_MODEL"), "opus-test")
        self.assertEqual([o for o in events(self.jpath) if o["event"] == "review_escalated"], [])

    def test_queued_dispatch_leaves_the_arm_intact(self):
        # Consume ONLY when actually dispatching — a QUEUED tick must leave the marker armed so the
        # escalation still lands once a concurrency slot frees (mirrors bash's own placement note).
        gates, state, _ = self._gates({"REVIEW_CONCURRENCY": "1"})
        open(state.review_escalate_file(34), "w").close()
        other = LiveCandidate(999, "shaOther", slug="feat-other")
        _marker_write(state.review_inflight_file(other), os.getpid())
        cand = LiveCandidate(34, "shaH", slug="feat-esc4")
        v = gates.review(cand)
        self.assertEqual(v, WAIT)
        self.assertTrue(os.path.exists(state.review_escalate_file(34)),
                        "a QUEUED tick must never consume the arm")

    def test_hung_claude_leaves_the_arm_intact_and_recovers_escalated(self):
        # PR #711 review finding: the hang probe sat BELOW the escalation-consume block, so a HUNG tick
        # deleted the one-shot marker without ever dispatching — the recovery tick then ran on the
        # cheap/default tier instead of Opus, silently defeating the escalation the arm existed for.
        # The hang gate must sit ABOVE the consume block so a HUNG tick returns WAIT untouched.
        gates, state, journal = self._gates({"WATCH_CLAUDE_PROBE_TIMEOUT": "5",
                                             "REVIEW_MODEL_ESCALATED": "opus-test"})
        open(state.review_escalate_file(35), "w").close()
        cand = LiveCandidate(35, "shaI", slug="feat-esc5")
        hang_sub = TestClaudeExecHangProbe._HangSub()
        orig_sub, orig_which = LR.subprocess, LR.shutil.which
        LR.subprocess = hang_sub
        LR.shutil.which = lambda name: "/usr/bin/claude"
        try:
            v = gates.review(cand)
        finally:
            LR.subprocess = orig_sub
            LR.shutil.which = orig_which
        self.assertEqual(v, WAIT)
        self.assertEqual(hang_sub.popens, [], "no reviewer may dispatch while claude is hung")
        self.assertTrue(os.path.exists(state.review_escalate_file(35)),
                        "a HUNG tick must never consume the one-shot escalation arm")
        self.assertEqual([o for o in events(self.jpath) if o["event"] == "review_escalated"], [],
                         "no escalation dispatch happened, so no review_escalated event either")
        held = [o for o in events(self.jpath) if o["event"] == "review_escalation_held"]
        self.assertEqual(len(held), 1, "the held episode must be auditable")
        self.assertEqual(held[0]["pr"], 35)

        # Recovery tick: claude responds again — the SAME (untouched) arm now escalates as intended.
        # A FRESH LiveGates instance, exactly as a real recovery tick would construct one (the hang
        # memo is scoped to one tick/instance, so reusing `gates` here would just replay its cached
        # HUNG verdict rather than genuinely re-probing).
        gates2, _, _ = self._gates({"WATCH_CLAUDE_PROBE_TIMEOUT": "5", "REVIEW_MODEL_ESCALATED": "opus-test"})
        sub2 = TestReviewFastPath._Sub({})
        LR.subprocess = sub2
        LR.shutil.which = lambda name: "/usr/bin/claude"
        try:
            v2 = gates2.review(cand)
        finally:
            LR.subprocess = orig_sub
            LR.shutil.which = orig_which
        self.assertEqual(v2, WAIT)
        self.assertEqual(len(sub2.popens), 1)
        self.assertEqual(sub2.popens[0][1]["env"].get("HERD_REVIEW_MODEL"), "opus-test")
        self.assertFalse(os.path.exists(state.review_escalate_file(35)), "now consumed, one-shot")
        esc = [o for o in events(self.jpath) if o["event"] == "review_escalated"]
        self.assertEqual(len(esc), 1)
        self.assertEqual(esc[0]["model"], "opus-test")


class TestClaudeExecHangProbe(LiveCase):
    """HERD-580: port WATCH_CLAUDE_PROBE_TIMEOUT (HERD-108, agent-watch.sh's _claude_exec_hung) into
    the live core: a wedged `claude` binary would otherwise burn a REVIEW_CONCURRENCY slot forever
    (LiveGates._dispatch_review's Popen never returns a verdict). agent-watch.sh's own probe has had NO
    production caller since the bash action pass (_tick_act) that would have run it was deleted at
    P5b — this is a fresh port into LiveGates.review(), not a call-out to the bash body (kept for its
    own unit test, tests/test-watcher-claude-hang.sh)."""

    class _HangSub:
        """subprocess stand-in whose .run() always times out — proves the probe holds dispatch."""
        DEVNULL = subprocess.DEVNULL
        TimeoutExpired = subprocess.TimeoutExpired

        def __init__(self):
            self.run_calls = 0
            self.popens = []

        def run(self, argv, **k):
            self.run_calls += 1
            raise self.TimeoutExpired(argv, k.get("timeout"))

        def Popen(self, *a, **k):
            self.popens.append((a, k))
            raise AssertionError("must never dispatch a reviewer while claude is hung")

    def _gates(self, config):
        state = LiveState(state_dir=self.tmp)
        journal = LiveJournal(self.jpath)
        return LiveGates(self.tmp, state, journal, config=config), state, journal

    def _cand(self, pr, sha):
        return LiveCandidate(pr, sha, slug="feat-probe-%s" % pr)

    def _with_which(self, present):
        orig = LR.shutil.which
        LR.shutil.which = (lambda name: "/usr/bin/claude") if present else (lambda name: None)
        return orig

    def test_disabled_by_default_never_probes_or_holds(self):
        gates, state, _ = self._gates({})
        sub = TestReviewFastPath._Sub({})
        orig = LR.subprocess
        LR.subprocess = sub
        try:
            v = gates.review(self._cand(41, "shaP1"))
        finally:
            LR.subprocess = orig
        self.assertEqual(v, WAIT)
        self.assertEqual(len(sub.popens), 1, "0 (default) must dispatch normally — no probe exec")

    def test_timeout_holds_dispatch_and_probes_at_most_once_per_tick(self):
        gates, state, _ = self._gates({"WATCH_CLAUDE_PROBE_TIMEOUT": "5"})
        sub = self._HangSub()
        orig_sub, orig_which = LR.subprocess, self._with_which(True)
        LR.subprocess = sub
        try:
            v1 = gates.review(self._cand(41, "shaP1"))
            v2 = gates.review(self._cand(42, "shaP2"))   # a second candidate, SAME tick/gates instance
        finally:
            LR.subprocess = orig_sub
            LR.shutil.which = orig_which
        self.assertEqual(v1, WAIT)
        self.assertEqual(v2, WAIT)
        self.assertEqual(sub.popens, [], "no reviewer may dispatch while claude is hung")
        self.assertEqual(sub.run_calls, 1, "memoized once per tick (LiveGates instance), not per candidate")
        hang = [o for o in events(self.jpath) if o.get("reason") == "claude-exec-hang"]
        self.assertEqual(len(hang), 1, "one journal event per hang episode, not per candidate")
        self.assertTrue(os.path.exists(state.claude_hang_state_file()))

    def test_recovery_clears_the_marker_and_journals_once(self):
        gates, state, _ = self._gates({"WATCH_CLAUDE_PROBE_TIMEOUT": "5"})
        with open(state.claude_hang_state_file(), "w", encoding="utf-8") as fh:
            fh.write("12345\n")
        sub = TestReviewFastPath._Sub({})
        orig_sub, orig_which = LR.subprocess, self._with_which(True)
        LR.subprocess = sub
        try:
            v = gates.review(self._cand(43, "shaP3"))
        finally:
            LR.subprocess = orig_sub
            LR.shutil.which = orig_which
        self.assertEqual(v, WAIT)
        self.assertEqual(len(sub.popens), 1, "a responsive claude must dispatch normally")
        self.assertFalse(os.path.exists(state.claude_hang_state_file()))
        cleared = [o for o in events(self.jpath) if o.get("reason") == "claude-exec-hang-cleared"]
        self.assertEqual(len(cleared), 1)

    def test_absent_claude_is_fail_soft_not_a_hang(self):
        gates, state, _ = self._gates({"WATCH_CLAUDE_PROBE_TIMEOUT": "5"})
        sub = TestReviewFastPath._Sub({})
        orig_sub, orig_which = LR.subprocess, self._with_which(False)
        LR.subprocess = sub
        try:
            v = gates.review(self._cand(44, "shaP4"))
        finally:
            LR.subprocess = orig_sub
            LR.shutil.which = orig_which
        self.assertEqual(v, WAIT)
        self.assertEqual(len(sub.popens), 1)
        self.assertEqual([o for o in events(self.jpath)
                          if "claude-exec-hang" in str(o.get("reason", ""))], [])

    def test_garbage_and_zero_timeout_are_both_disabled(self):
        for raw in ("0", "", "banana", "-5"):
            with self.subTest(raw=raw):
                self.assertIsNone(LR._claude_probe_secs({"WATCH_CLAUDE_PROBE_TIMEOUT": raw}))
        self.assertEqual(LR._claude_probe_secs({"WATCH_CLAUDE_PROBE_TIMEOUT": "5"}), 5)


class TestGhRateLimitClassification(unittest.TestCase):
    """HERD-582: a gh call rejected on a rate limit must classify as BACKOFF, not a genuine fault.
    The live incident (2026-08-06 02:06): a GraphQL bucket exhausted after a 50-merge day made
    discover_via_graphql's gh call exit non-zero, which propagated straight to `main` — exit 1 —
    and rang the bash watchdog's fault streak into a false 'ENGINE DOWN' page for a wait-with-a-
    known-reset. Genuine failures (auth, network, malformed query) must still raise/fault verbatim."""

    def test_looks_gh_rate_limited_matches_graphql_text(self):
        self.assertTrue(LR._looks_gh_rate_limited(
            "gh: GraphQL: API rate limit already exceeded for user ID 123. (repository)\n"))

    def test_looks_gh_rate_limited_matches_rest_403_zero_remaining(self):
        self.assertTrue(LR._looks_gh_rate_limited(
            "HTTP/2.0 403 Forbidden\nX-RateLimit-Remaining: 0\n\n"
            '{"message":"API rate limit exceeded for user ID 123."}\n'))

    def test_looks_gh_rate_limited_false_for_genuine_failure(self):
        self.assertFalse(LR._looks_gh_rate_limited("gh: authentication failed, run 'gh auth login'\n"))
        self.assertFalse(LR._looks_gh_rate_limited("curl: (6) Could not resolve host\n"))
        self.assertFalse(LR._looks_gh_rate_limited(""))
        self.assertFalse(LR._looks_gh_rate_limited(None))

    def test_403_alone_without_the_header_is_not_classified_rate_limited(self):
        # A plain 403 (e.g. a permissions error) must NOT be mistaken for a rate limit — only the
        # X-RateLimit-Remaining: 0 header (or the GraphQL text) authorizes the reclassification.
        self.assertFalse(LR._looks_gh_rate_limited("gh: HTTP 403: Resource not accessible by integration"))

    def test_discover_via_graphql_raises_ghratelimited_with_reset(self):
        reset_epoch = 1735689600

        class _Stub:
            CalledProcessError = subprocess.CalledProcessError   # live_runtime references subprocess.CalledProcessError

            def run(self, argv, **k):
                if "graphql" in argv:
                    raise subprocess.CalledProcessError(
                        1, argv, output="",
                        stderr="gh: GraphQL: API rate limit already exceeded for user ID 123. (repository)\n")
                if "rate_limit" in argv:
                    class R:
                        returncode = 0
                        stdout = "%d\n" % reset_epoch
                    return R()
                raise AssertionError("unexpected gh call: %r" % (argv,))

        orig = LR.subprocess
        LR.subprocess = _Stub()
        try:
            with self.assertRaises(LR.GhRateLimited) as ctx:
                LR.discover_via_graphql(repo="owner/name")
            self.assertEqual(ctx.exception.reset_at, reset_epoch)
            # HERD-670: a GraphQL call's failure must classify against the "graphql" bucket, never
            # the default "core" — the exact mix-up that caused the flapping loop.
            self.assertEqual(ctx.exception.resource, "graphql")
        finally:
            LR.subprocess = orig

    def test_discover_via_graphql_genuine_failure_propagates_calledprocesserror(self):
        class _Stub:
            CalledProcessError = subprocess.CalledProcessError

            def run(self, argv, **k):
                raise subprocess.CalledProcessError(1, argv, output="", stderr="gh: authentication failed\n")

        orig = LR.subprocess
        LR.subprocess = _Stub()
        try:
            with self.assertRaises(subprocess.CalledProcessError):
                LR.discover_via_graphql(repo="owner/name")
        finally:
            LR.subprocess = orig

    def test_repo_owner_name_raises_ghratelimited_on_rest_403(self):
        class _Stub:
            CalledProcessError = subprocess.CalledProcessError

            def run(self, argv, **k):
                if "rate_limit" in argv:
                    class R:
                        returncode = 0
                        stdout = "1735689600\n"
                    return R()
                raise subprocess.CalledProcessError(
                    1, argv, output="", stderr="HTTP/2.0 403 Forbidden\nX-RateLimit-Remaining: 0\n")

        orig = LR.subprocess
        LR.subprocess = _Stub()
        try:
            with self.assertRaises(LR.GhRateLimited) as ctx:
                LR._repo_owner_name(None)
            # HERD-670: a REST call's failure classifies against "core" — the resource it actually draws.
            self.assertEqual(ctx.exception.resource, "core")
        finally:
            LR.subprocess = orig

    def test_gh_rate_limit_reset_probe_is_fail_soft(self):
        # The follow-up "when does it reset" probe failing must never itself raise — the caller
        # (GhRateLimited.reset_at is None) applies a default cooldown instead.
        class _Stub:
            def run(self, argv, **k):
                raise OSError("gh not found")

        orig = LR.subprocess
        LR.subprocess = _Stub()
        try:
            self.assertIsNone(LR._gh_rate_limit_reset())
        finally:
            LR.subprocess = orig

    def test_reset_and_remaining_probes_query_the_named_resource_not_the_core_alias(self):
        # HERD-670: the legacy `.rate` field is an ALIAS for `.resources.core` — a probe must ask for
        # `.resources.<resource>.*` explicitly so a graphql probe never silently reads core's numbers.
        calls = []

        class _Stub:
            def run(self, argv, **k):
                calls.append(argv)
                q = argv[argv.index("-q") + 1]

                class R:
                    returncode = 0
                    stdout = "42\n"
                return R()

        orig = LR.subprocess
        LR.subprocess = _Stub()
        try:
            self.assertEqual(LR._gh_rate_limit_reset("graphql"), 42)
            self.assertEqual(LR._gh_rate_limit_remaining("graphql"), 42)
            self.assertEqual(LR._gh_rate_limit_reset("core"), 42)
            self.assertEqual(LR._gh_rate_limit_remaining("core"), 42)
        finally:
            LR.subprocess = orig
        queried = [argv[argv.index("-q") + 1] for argv in calls]
        self.assertIn(".resources.graphql.reset", queried)
        self.assertIn(".resources.graphql.remaining", queried)
        self.assertIn(".resources.core.reset", queried)
        self.assertIn(".resources.core.remaining", queried)
        self.assertFalse(any(q in (".rate.reset", ".rate.remaining") for q in queried),
                          "must never read the ambiguous .rate alias (always core)")

    def test_bucket_selection_core_full_graphql_empty(self):
        # Direct simulation of a `gh api rate_limit` snapshot where core is comfortably full and
        # graphql is fully exhausted — the exact shape from the grounding incident (2026-08-13
        # 00:43-00:45Z: core 4709/5000, graphql 0/5000). Each probe must read its OWN named resource.
        snapshot = {"core": {"remaining": 4709, "reset": 1735689600},
                    "graphql": {"remaining": 0, "reset": 1735689900}}

        class _Stub:
            def run(self, argv, **k):
                q = argv[argv.index("-q") + 1]
                resource, field = q.split(".")[2], q.split(".")[3]

                class R:
                    returncode = 0
                    stdout = "%s\n" % snapshot[resource][field]
                return R()

        orig = LR.subprocess
        LR.subprocess = _Stub()
        try:
            self.assertEqual(LR._gh_rate_limit_remaining("core"), 4709)
            self.assertEqual(LR._gh_rate_limit_remaining("graphql"), 0)
            self.assertEqual(LR._gh_rate_limit_reset("core"), 1735689600)
            self.assertEqual(LR._gh_rate_limit_reset("graphql"), 1735689900)
        finally:
            LR.subprocess = orig

    def test_bucket_selection_inverse_core_empty_graphql_full(self):
        # Inverse of the above: core exhausted (a REST-heavy leg like _repo_owner_name), graphql full.
        snapshot = {"core": {"remaining": 0, "reset": 1735690200},
                    "graphql": {"remaining": 4988, "reset": 1735690800}}

        class _Stub:
            def run(self, argv, **k):
                q = argv[argv.index("-q") + 1]
                resource, field = q.split(".")[2], q.split(".")[3]

                class R:
                    returncode = 0
                    stdout = "%s\n" % snapshot[resource][field]
                return R()

        orig = LR.subprocess
        LR.subprocess = _Stub()
        try:
            self.assertEqual(LR._gh_rate_limit_remaining("core"), 0)
            self.assertEqual(LR._gh_rate_limit_remaining("graphql"), 4988)
            self.assertEqual(LR._gh_rate_limit_reset("core"), 1735690200)
            self.assertEqual(LR._gh_rate_limit_reset("graphql"), 1735690800)
        finally:
            LR.subprocess = orig


class TestGraphqlDiscoveryTimeout(unittest.TestCase):
    """HERD-764: one bounded discovery timeout fails soft without waking watchdog retries."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.jpath = os.path.join(self.tmp, "journal.jsonl")
        self._saved = {k: os.environ.get(k) for k in
                       ("JOURNAL_FILE", "HERD_GH_TIMEOUT_SECS")}
        os.environ["JOURNAL_FILE"] = self.jpath

    def tearDown(self):
        shutil.rmtree(self.tmp)
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_timeout_returns_empty_and_journals_once(self):
        os.environ["HERD_GH_TIMEOUT_SECS"] = "7"

        class _Stub:
            CalledProcessError = subprocess.CalledProcessError
            TimeoutExpired = subprocess.TimeoutExpired
            seen_timeout = None

            def run(self, argv, **kwargs):
                self.seen_timeout = kwargs.get("timeout")
                raise subprocess.TimeoutExpired(argv, self.seen_timeout)

        stub = _Stub()
        orig = LR.subprocess
        LR.subprocess = stub
        try:
            self.assertEqual(LR.discover_via_graphql(repo="owner/name"), [])
        finally:
            LR.subprocess = orig

        self.assertGreater(stub.seen_timeout, 0)
        self.assertLessEqual(stub.seen_timeout, 7)
        timed_out = [event for event in events(self.jpath)
                     if event.get("event") == "gh_timeout"]
        self.assertEqual(len(timed_out), 1)
        self.assertEqual(timed_out[0]["component"], "live_runtime")
        self.assertEqual(timed_out[0]["site"], "graphql_discovery")
        self.assertEqual(timed_out[0]["timeout_secs"], 7)

    def test_repo_lookup_and_graphql_share_one_deadline(self):
        seen = []

        class _Stub:
            CalledProcessError = subprocess.CalledProcessError
            TimeoutExpired = subprocess.TimeoutExpired

            def run(self, argv, **kwargs):
                seen.append(kwargs.get("timeout"))
                if argv[1:3] == ["repo", "view"]:
                    return mock.Mock(stdout="owner\tname\n")
                return mock.Mock(stdout='{"data":{"repository":{"pullRequests":{"nodes":[]}}}}')

        orig = LR.subprocess
        LR.subprocess = _Stub()
        try:
            with mock.patch.object(LR.time, "monotonic", side_effect=[100.0, 100.0, 102.0]):
                self.assertEqual(LR.discover_via_graphql(), [])
        finally:
            LR.subprocess = orig

        self.assertEqual(len(seen), 2)
        self.assertEqual(seen[0], 15)
        self.assertEqual(seen[1], 13)


class TestResumeJitter(unittest.TestCase):
    """HERD-670: the resume offset must be bounded, DETERMINISTIC (no random/Date — a rerun of the
    same tick must reproduce the same wakeup), and spread distinct workspaces apart so several
    watchers armed by the same exhaustion event don't all wake on the exact same epoch."""

    def test_deterministic_and_bounded(self):
        v1 = LR._resume_jitter_seconds("/trees/projA")
        v2 = LR._resume_jitter_seconds("/trees/projA")
        self.assertEqual(v1, v2)
        self.assertGreaterEqual(v1, 0)
        self.assertLess(v1, LR._GH_RATE_LIMIT_JITTER_MAX_SECONDS)

    def test_empty_or_missing_workspace_contributes_no_jitter(self):
        self.assertEqual(LR._resume_jitter_seconds(""), 0)
        self.assertEqual(LR._resume_jitter_seconds(None), 0)

    def test_distinct_workspaces_are_not_all_collapsed_to_one_offset(self):
        vals = {LR._resume_jitter_seconds("/trees/ws-%d" % i) for i in range(20)}
        self.assertGreater(len(vals), 1, "20 distinct workspaces should not all hash to one offset")


class TestGhRateLimitResourceMarker(unittest.TestCase):
    """HERD-670: the persisted backoff marker must round-trip the exhausted resource alongside the
    epoch, while staying byte-compatible with bash's `_gh_rate_limited_until` (agent-watch.sh), which
    reads ONLY `head -n1` and demands it be pure digits."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_round_trips_resource(self):
        state = LiveState(self.tmp)
        state.set_gh_rate_limited_until(123456, "graphql")
        self.assertEqual(state.gh_rate_limited_until(), 123456)
        self.assertEqual(state.gh_rate_limited_resource(), "graphql")

    def test_default_resource_is_core(self):
        state = LiveState(self.tmp)
        state.set_gh_rate_limited_until(123456)
        self.assertEqual(state.gh_rate_limited_resource(), "core")

    def test_first_line_stays_a_bare_epoch_for_bash_compat(self):
        state = LiveState(self.tmp)
        state.set_gh_rate_limited_until(123456, "graphql")
        with open(state.gh_rate_limit_path(), encoding="utf-8") as fh:
            first_line = fh.readline().strip()
        self.assertEqual(first_line, "123456")
        self.assertTrue(first_line.isdigit())

    def test_pre_herd670_marker_shape_reads_back_as_core(self):
        state = LiveState(self.tmp)
        with open(state.gh_rate_limit_path(), "w", encoding="utf-8") as fh:
            fh.write("123456\n")  # old shape: epoch only, no resource line
        self.assertEqual(state.gh_rate_limited_until(), 123456)
        self.assertEqual(state.gh_rate_limited_resource(), "core")

    def test_no_state_dir_defaults_core(self):
        state = LiveState(self.tmp)
        state.dir = None
        self.assertEqual(state.gh_rate_limited_resource(), "core")


class TestLiveTickRateLimitBackoff(LiveCase):
    """HERD-582: LiveTick.run() must never let a classified rate limit raise (no fault streak),
    must journal engine_rate_limited with the reset stamp, and must skip the gh round-trip
    entirely on a subsequent tick while the backoff window is still active."""

    def test_journals_engine_rate_limited_and_returns_calm_summary_without_raising(self):
        os.environ["HERD_FAKE_NOW"] = "1735689000"
        try:
            class _RLDiscovery:
                def discover(self):
                    raise LR.GhRateLimited(reset_at=1735689600)

            journal = LiveJournal(self.jpath)
            state = LiveState(self.tmp)
            t = LiveTick({}, _RLDiscovery(), FixtureGates({}), DryRunActuator(journal), journal,
                         state=state)
            result = t.run()  # must NOT raise
        finally:
            os.environ.pop("HERD_FAKE_NOW", None)
        # HERD-670: the armed deadline now carries a deterministic per-workspace jitter on top of
        # the buffer (same seed the production code uses — self.tmp is this test's state dir).
        jitter = LR._resume_jitter_seconds(self.tmp)
        want_until = 1735689600 + LR._GH_RATE_LIMIT_BUFFER_SECONDS + jitter
        self.assertTrue(result.get("rate_limited"))
        self.assertEqual(result.get("rate_limited_until"), want_until)
        # GhRateLimited(reset_at=...) with no explicit resource defaults to "core".
        self.assertEqual(result.get("rate_limited_resource"), "core")
        evs = events(self.jpath)
        rl = [e for e in evs if e["event"] == "engine_rate_limited"]
        self.assertEqual(len(rl), 1)
        self.assertEqual(int(rl[0]["reset"]), 1735689600)
        self.assertEqual(int(rl[0]["until"]), want_until)
        self.assertEqual(rl[0]["resource"], "core")
        self.assertEqual(int(rl[0]["jitter"]), jitter)
        # no ordinary tick bookkeeping ran — this tick did no candidate walk at all
        self.assertEqual([e["event"] for e in evs if e["event"] in ("live_tick_start", "live_tick_end")], [])
        # the marker persisted so the NEXT tick can skip the gh round-trip outright
        self.assertEqual(state.gh_rate_limited_until(), want_until)
        self.assertEqual(state.gh_rate_limited_resource(), "core")

    def test_journals_resource_from_the_raised_exception(self):
        # HERD-670: a discovery leg that classified against "graphql" must arm the marker and journal
        # against "graphql" — never silently default to "core".
        os.environ["HERD_FAKE_NOW"] = "1735689000"
        try:
            class _RLDiscovery:
                def discover(self):
                    raise LR.GhRateLimited(reset_at=1735689600, resource="graphql")

            journal = LiveJournal(self.jpath)
            state = LiveState(self.tmp)
            t = LiveTick({}, _RLDiscovery(), FixtureGates({}), DryRunActuator(journal), journal,
                         state=state)
            result = t.run()
        finally:
            os.environ.pop("HERD_FAKE_NOW", None)
        self.assertEqual(result.get("rate_limited_resource"), "graphql")
        self.assertEqual(state.gh_rate_limited_resource(), "graphql")
        rl = [e for e in events(self.jpath) if e["event"] == "engine_rate_limited"]
        self.assertEqual(rl[0]["resource"], "graphql")

    def test_falls_back_to_the_default_cooldown_when_the_reset_probe_itself_failed(self):
        # reset_at=None (the cheap follow-up probe failed too) must never block the calm path —
        # fall back to the default cooldown rather than raising or leaving the tick unbounded.
        os.environ["HERD_FAKE_NOW"] = "1735689000"
        try:
            class _RLDiscovery:
                def discover(self):
                    raise LR.GhRateLimited(reset_at=None)

            journal = LiveJournal(self.jpath)
            state = LiveState(self.tmp)
            t = LiveTick({}, _RLDiscovery(), FixtureGates({}), DryRunActuator(journal), journal,
                         state=state)
            result = t.run()
        finally:
            os.environ.pop("HERD_FAKE_NOW", None)
        jitter = LR._resume_jitter_seconds(self.tmp)
        want_until = (1735689000 + LR._GH_RATE_LIMIT_DEFAULT_COOLDOWN_SECONDS
                      + LR._GH_RATE_LIMIT_BUFFER_SECONDS + jitter)
        self.assertTrue(result.get("rate_limited"))
        self.assertEqual(result.get("rate_limited_until"), want_until)
        rl = [e for e in events(self.jpath) if e["event"] == "engine_rate_limited"]
        self.assertEqual(len(rl), 1)
        self.assertEqual(int(rl[0]["until"]), want_until)

    def test_skips_discovery_entirely_within_an_active_backoff_window(self):
        state = LiveState(self.tmp)
        state.set_gh_rate_limited_until(4102444800)  # far future (year 2100)
        calls = []

        class _CountingDiscovery:
            def discover(self):
                calls.append(1)
                return []

        journal = LiveJournal(self.jpath)
        t = LiveTick({}, _CountingDiscovery(), FixtureGates({}), DryRunActuator(journal), journal,
                     state=state)
        # HERD-649c: an active window now runs ONE cheap re-probe before honoring the backoff — a
        # genuinely-exhausted budget (mocked here so this stays hermetic, no real `gh`) must still
        # skip discovery exactly as before this leg existed.
        with mock.patch.object(LR, "_gh_rate_limit_remaining", return_value=0):
            result = t.run()
        self.assertEqual(calls, [], "discovery must not be called while the budget is still exhausted")
        self.assertTrue(result.get("rate_limited"))
        self.assertEqual(result.get("rate_limited_until"), 4102444800)

    def test_clears_the_marker_and_resumes_once_the_window_has_passed(self):
        state = LiveState(self.tmp)
        state.set_gh_rate_limited_until(1)  # already in the past
        calls = []

        class _CountingDiscovery:
            def discover(self):
                calls.append(1)
                return []

        journal = LiveJournal(self.jpath)
        t = LiveTick({"MERGE_POLICY": "auto"}, _CountingDiscovery(), FixtureGates({}),
                     DryRunActuator(journal), journal, state=state)
        result = t.run()
        self.assertEqual(len(calls), 1, "discovery must run again once the backoff window has passed")
        self.assertFalse(result.get("rate_limited"))
        self.assertEqual(state.gh_rate_limited_until(), 0, "the marker must clear on a clean discovery")

    def test_genuine_discovery_failure_still_raises_and_never_journals_rate_limited(self):
        class _BrokenDiscovery:
            def discover(self):
                raise subprocess.CalledProcessError(1, ["gh"], output="",
                                                    stderr="gh: authentication failed\n")

        journal = LiveJournal(self.jpath)
        state = LiveState(self.tmp)
        t = LiveTick({}, _BrokenDiscovery(), FixtureGates({}), DryRunActuator(journal), journal,
                     state=state)
        with self.assertRaises(subprocess.CalledProcessError):
            t.run()
        evs = events(self.jpath) if os.path.exists(self.jpath) else []
        self.assertEqual([e for e in evs if e["event"] == "engine_rate_limited"], [])


class TestCiVerdictMapping(unittest.TestCase):
    """HERD-578: the ONE shared CI-verdict mapping (herd.ci_verdict), read by the watcher's own
    HEALTH_SOURCE=ci health rail AND — through `python3 -m herd.ci_verdict` — by agent-watch.sh's
    main-health CI leg and CI_FAST_BOUNCE leg. Pure fixtures: no gh, no network.

    The end-to-end gate proof (all five mappings driven through a real LiveTick walk with a stubbed
    gh) lives in tests/test-ci-as-gate.sh; this class pins the mapping itself, including PARITY with
    the two inline programs it replaced — a mapping that quietly changed shape would break the
    main-health leg's console row and its autofix identity at once.
    """

    def _run(self, sha, status, conclusion, wf="CI", rid=1):
        return {"headSha": sha, "status": status, "conclusion": conclusion,
                "workflowName": wf, "databaseId": rid}

    # ── classify_runs: which run speaks for this sha ───────────────────────────────────────────────
    def test_green_run_for_the_head_sha_is_pass(self):
        scan = CVD.classify_runs([self._run("a", "COMPLETED", "SUCCESS")], "a")
        self.assertEqual(scan["bucket"], "pass")
        self.assertEqual(scan["run_id"], "1")

    def test_fail_vocabulary_is_exactly_the_branch_ci_leg_s(self):
        for concl in ("FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"):
            self.assertEqual(CVD.classify_runs([self._run("a", "COMPLETED", concl)], "a")["bucket"],
                             "fail", concl)
        for concl in ("SUCCESS", "NEUTRAL", "SKIPPED"):
            self.assertEqual(CVD.classify_runs([self._run("a", "COMPLETED", concl)], "a")["bucket"],
                             "pass", concl)

    def test_cancelled_and_unknown_conclusions_are_never_red(self):
        for concl in ("CANCELLED", "STALE", "SOMETHING_NEW", None):
            scan = CVD.classify_runs([self._run("a", "COMPLETED", concl)], "a")
            self.assertEqual(scan["bucket"], "cancelled", concl)
            self.assertNotEqual(CVD.map_verdict(scan)[0], CVD.CODEERROR)

    def test_in_progress_run_for_this_sha_is_pending(self):
        scan = CVD.classify_runs([self._run("a", "IN_PROGRESS", None)], "a")
        self.assertEqual(scan["bucket"], "pending")
        self.assertEqual(scan["in_progress"], 1)

    def test_runs_exist_but_none_for_this_sha_is_none_not_absent(self):
        # "CI has not picked this commit up yet" is a WAIT; only a branch with NO runs at all is the
        # absent-CI fallback, so a fresh push can never be mistaken for "this repo has no CI".
        scan = CVD.classify_runs([self._run("other", "COMPLETED", "SUCCESS")], "a")
        self.assertEqual(scan["bucket"], "none")
        self.assertEqual(CVD.map_verdict(scan)[0], CVD.WAIT)

    def test_empty_window_is_absent_and_maps_to_local(self):
        self.assertEqual(CVD.classify_runs([], "a")["bucket"], "absent")
        self.assertEqual(CVD.map_verdict(CVD.classify_runs([], "a"))[0], CVD.LOCAL)

    def test_non_list_input_never_raises(self):
        for junk in (None, {}, "nope", 7):
            self.assertEqual(CVD.classify_runs(junk, "a")["bucket"], "absent")

    def test_cancelled_count_qualifies_the_wait(self):
        runs = [self._run("a", "COMPLETED", "CANCELLED", rid=2),
                self._run("a", "COMPLETED", "CANCELLED", rid=3)]
        scan = CVD.classify_runs(runs, "a")
        verdict, reason, detail = CVD.map_verdict(scan)
        self.assertEqual((verdict, reason), (CVD.WAIT, "ci-cancelled-chain"))
        self.assertEqual(detail, "2 cancelled runs — awaiting a completed run")

    # ── classify_failure_log: code red vs platform outage ─────────────────────────────────────────
    def test_real_test_output_is_a_code_red(self):
        log = "ci-suite\t✗ tests/test-a.sh (rc=1)\nci-suite\t✗ tests/test-b.sh\n"
        self.assertEqual(CVD.classify_failure_log(log),
                         ("code", "tests/test-a.sh (rc=1),tests/test-b.sh"))

    def test_duplicate_identities_are_deduped_in_order(self):
        log = "x ✗ t1\ny ✗ t1\nz ✗ t2\n"
        self.assertEqual(CVD.classify_failure_log(log), ("code", "t1,t2"))

    def test_identity_is_capped(self):
        log = "\n".join("job ✗ tests/test-%d.sh" % i for i in range(200))
        kind, detail = CVD.classify_failure_log(log)
        self.assertEqual(kind, "code")
        self.assertLessEqual(len(detail), 200)

    def test_infra_signatures_classify_infra_not_code(self):
        for sig in ("Error: Failed to resolve action download info",
                    "The runner has received a shutdown signal",
                    "remote: Service Unavailable",
                    "The job was not acquired by runner within the timeout",
                    "The operation was canceled."):
            kind, detail = CVD.classify_failure_log(sig)
            self.assertEqual(kind, "infra", sig)
            self.assertTrue(detail)
            self.assertEqual(CVD.map_verdict({"bucket": "fail"}, (kind, detail))[0], CVD.WAIT, sig)

    def test_real_test_output_wins_over_an_incidental_infra_line(self):
        """A run that got far enough to fail a named test failed on the DIFF — the infra line may be
        a retried step's noise. Only a red with NO test output is ever infra-transient."""
        log = "setup\tService Unavailable\nci-suite\t✗ tests/test-a.sh\n"
        self.assertEqual(CVD.classify_failure_log(log)[0], "code")

    def test_unreadable_log_is_unknown_and_holds(self):
        for log in ("", None, "nothing interesting here\n"):
            self.assertEqual(CVD.classify_failure_log(log), ("unknown", ""))
        verdict, reason, _ = CVD.map_verdict({"bucket": "fail"}, ("unknown", ""))
        self.assertEqual((verdict, reason), (CVD.WAIT, "ci-log-unreadable"))

    def test_a_fail_with_no_log_at_all_never_guesses_a_red(self):
        self.assertEqual(CVD.map_verdict({"bucket": "fail"}, None)[0], CVD.WAIT)

    # ── PARITY with the pre-HERD-578 inline programs the bash legs used to carry ───────────────────
    _PARITY_FIXTURES = (
        [],
        [{"headSha": "a", "status": "COMPLETED", "conclusion": "SUCCESS",
          "workflowName": "CI", "databaseId": 1}],
        [{"headSha": "a", "status": "COMPLETED", "conclusion": "FAILURE",
          "workflowName": "CI\twith tab", "databaseId": 2}],
        [{"headSha": "a", "status": "IN_PROGRESS", "conclusion": None,
          "workflowName": "CI", "databaseId": 3}],
        [{"headSha": "b", "status": "COMPLETED", "conclusion": "CANCELLED",
          "workflowName": "CI", "databaseId": 4},
         {"headSha": "a", "status": "COMPLETED", "conclusion": "FAILURE",
          "workflowName": "CI", "databaseId": 5}],
        [{"headSha": "a", "status": "COMPLETED", "conclusion": "CANCELLED",
          "workflowName": "CI", "databaseId": 6}],
        [{"headSha": "c", "status": "QUEUED", "conclusion": None, "workflowName": "", "databaseId": None},
         {"headSha": "b", "status": "COMPLETED", "conclusion": "STALE", "workflowName": "CI",
          "databaseId": 7},
         {"headSha": "a", "status": "COMPLETED", "conclusion": "SUCCESS", "workflowName": "CI",
          "databaseId": 8}],
        ["not-a-dict", {"headSha": "a", "status": "COMPLETED", "conclusion": "FAILURE",
                        "workflowName": "CI", "databaseId": 9}],
    )

    @staticmethod
    def _legacy_classify(runs, expected):
        """agent-watch.sh's `_main_ci_classify` body, verbatim, as it stood before HERD-578."""
        PASS = {"SUCCESS", "NEUTRAL", "SKIPPED"}
        FAIL = {"FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"}

        def clean(s):
            return str(s or "").replace("\t", " ").replace("\n", " ").strip()
        for r in runs:
            if not isinstance(r, dict):
                continue
            if expected and r.get("headSha") != expected:
                continue
            if str(r.get("status") or "").upper() != "COMPLETED":
                continue
            concl = str(r.get("conclusion") or "").upper()
            if concl in FAIL:
                bucket = "fail"
            elif concl in PASS:
                bucket = "pass"
            else:
                bucket = "pending"
            run_id = r.get("databaseId")
            return "%s\t%s\t%s\t%s\n" % (bucket, clean(r.get("workflowName")), concl or "?",
                                         run_id if run_id else "")
        return ""

    @staticmethod
    def _legacy_starve_scan(runs):
        """agent-watch.sh's `_main_ci_starve_scan` body, verbatim, as it stood before HERD-578."""
        PASS = {"SUCCESS", "NEUTRAL", "SKIPPED"}
        FAIL = {"FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"}

        def clean(s):
            return str(s or "").replace("\x1f", " ").replace("\t", " ").replace("\n", " ").strip()
        in_progress = 0
        cancelled_shas = set()
        bucket, wf, concl, run_id, run_sha = "none", "", "", "", ""
        for r in runs:
            if not isinstance(r, dict):
                continue
            sha = clean(r.get("headSha"))
            if str(r.get("status") or "").upper() != "COMPLETED":
                in_progress = 1
                continue
            c = str(r.get("conclusion") or "").upper()
            if c in PASS or c in FAIL:
                bucket = "pass" if c in PASS else "fail"
                wf, concl, run_sha = clean(r.get("workflowName")), c, sha
                rid = r.get("databaseId")
                run_id = str(rid) if rid else ""
                break
            if sha:
                cancelled_shas.add(sha)
        return "\x1f".join([bucket, wf, concl, run_id, run_sha, str(len(cancelled_shas)),
                            str(in_progress)]) + "\n"

    def test_classify_emitter_is_byte_identical_to_the_program_it_replaced(self):
        for fixture in self._PARITY_FIXTURES:
            for sha in ("a", "", "zzz"):
                self.assertEqual(CVD._emit_classify(fixture, sha),
                                 self._legacy_classify(fixture, sha),
                                 "classify drift: %r sha=%r" % (fixture, sha))

    def test_starve_scan_emitter_is_byte_identical_to_the_program_it_replaced(self):
        for fixture in self._PARITY_FIXTURES:
            self.assertEqual(CVD._emit_starve_scan(fixture), self._legacy_starve_scan(fixture),
                             "starve-scan drift: %r" % (fixture,))

    def test_identity_from_log_matches_the_bash_grep_sed_pipeline(self):
        """The old identity leg was `grep -F ✗ | sed 's/^.*✗ *//' | tr -d '\\r' | awk NF |
        awk !seen | paste -sd,` capped at 200 chars — same answers, including the CRLF and
        blank-name cases."""
        cases = {
            "job\t✗ tests/a.sh\r\njob\t✗ tests/a.sh\njob\t✗ tests/b.sh\n": "tests/a.sh,tests/b.sh",
            "job\t✗   \n": "",
            "no failures here": "",
            "": "",
        }
        for log, want in cases.items():
            self.assertEqual(CVD.identity_from_log(log), want, repr(log))

    # ── the lever itself ──────────────────────────────────────────────────────────────────────────
    def test_health_source_lever_is_ci_only_on_the_exact_value(self):
        self.assertEqual(LR._health_source({"HEALTH_SOURCE": "ci"}), "ci")
        self.assertEqual(LR._health_source({"HEALTH_SOURCE": " CI "}), "ci")
        for cfg in ({}, None, {"HEALTH_SOURCE": ""}, {"HEALTH_SOURCE": "local"},
                    {"HEALTH_SOURCE": "on"}, {"HEALTH_SOURCE": "cirrus"}):
            self.assertEqual(LR._health_source(cfg), "local", cfg)

    def test_health_source_is_a_core_env_key(self):
        """A python-core knob unexported by herd-config.sh is invisible to the `--tick` child (the
        HERD-449 bug class) — scripts/herd/env-export-lint.sh reads this tuple to catch that."""
        self.assertIn("HEALTH_SOURCE", LR._CORE_ENV_KEYS)


class TestCiInfraRerunBound(unittest.TestCase):
    """HERD-609: the auto-rerun of an infra-transient CI red is BOUNDED — one per run id, ever, and
    at most one within the cooldown. A platform outage must cost a handful of reruns, not a storm."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_first_run_id_is_allowed_then_never_again(self):
        self.assertTrue(LR._ci_rerun_allowed(self.tmp, "77"))
        open(LR._ci_rerun_marker(self.tmp, "77"), "w").close()
        self.assertFalse(LR._ci_rerun_allowed(self.tmp, "77"))

    def test_cooldown_blocks_a_different_run_id(self):
        open(LR._ci_rerun_cooldown_marker(self.tmp), "w").close()
        self.assertFalse(LR._ci_rerun_allowed(self.tmp, "88"),
                         "a fresh cooldown stamp must hold off every run id, not just the last one")

    def test_expired_cooldown_allows_a_new_run_id(self):
        cooldown = LR._ci_rerun_cooldown_marker(self.tmp)
        open(cooldown, "w").close()
        old = time.time() - (LR._CI_RERUN_COOLDOWN_SECS + 60)
        os.utime(cooldown, (old, old))
        self.assertTrue(LR._ci_rerun_allowed(self.tmp, "88"))

    def test_no_state_dir_never_reruns(self):
        self.assertFalse(LR._ci_rerun_allowed("", "77"))
        self.assertFalse(LR._ci_rerun_allowed(self.tmp, ""))


class TestCiPoolPriming(unittest.TestCase):
    """HERD-649a: `LiveGates.prime_ci_pool` replaces one `gh run list` PER BRANCH with ONE pooled call
    for the whole tick, grouped locally by `headBranch`. Hermetic: `_ci_runs_pooled`/`_ci_runs` are
    mocked, never a real subprocess."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = LiveState(self.tmp)
        self.journal = LiveJournal(os.path.join(self.tmp, "j.jsonl"))
        self.gates = LiveGates("/nonexistent-home", self.state, self.journal,
                               config={"HEALTH_SOURCE": "ci"})

    def _cand(self, pr, sha, branch):
        return LiveCandidate(pr=pr, sha=sha, slug="feat-%s" % pr, branch=branch,
                             worktree="/nonexistent-wt-%s" % pr)

    def test_one_pooled_call_serves_every_candidate_branch(self):
        cands = [self._cand(1, "sha1", "feat/a"), self._cand(2, "sha2", "feat/b"),
                 self._cand(3, "sha3", "feat/c")]
        runs = [
            {"headSha": "sha1", "status": "COMPLETED", "conclusion": "SUCCESS",
             "workflowName": "CI", "databaseId": 1, "headBranch": "feat/a"},
            {"headSha": "sha2", "status": "COMPLETED", "conclusion": "SUCCESS",
             "workflowName": "CI", "databaseId": 2, "headBranch": "feat/b"},
            {"headSha": "sha3", "status": "IN_PROGRESS", "conclusion": None,
             "workflowName": "CI", "databaseId": 3, "headBranch": "feat/c"},
        ]
        with mock.patch.object(LR, "_ci_runs_pooled", return_value=runs) as pooled, \
             mock.patch.object(LR, "_ci_runs") as solo:
            self.gates.prime_ci_pool(cands)
            self.assertEqual(pooled.call_count, 1, "3 branches must cost exactly ONE pooled call")
            self.assertEqual(self.gates.health(cands[0]), "CLEAN")
            self.assertEqual(self.gates.health(cands[1]), "CLEAN")
            self.assertEqual(self.gates.health(cands[2]), WAIT)
            self.assertEqual(pooled.call_count, 1, "consuming 3 candidates must not trigger a 2nd poll")
            self.assertEqual(solo.call_count, 0, "the primed pool must serve every branch — no fallback")
        budget = self.gates.ci_poll_budget()
        self.assertEqual(budget["calls"], 1)
        self.assertEqual(budget["branches_polled"], 3)
        self.assertEqual(budget["branches_memoized"], 0)

    def test_pool_limit_scales_with_branch_count_and_caps(self):
        cands = [self._cand(i, "sha%d" % i, "feat/%d" % i) for i in range(6)]
        with mock.patch.object(LR, "_ci_runs_pooled", return_value=[]) as pooled:
            self.gates.prime_ci_pool(cands)
            limit = pooled.call_args[0][0]
            self.assertEqual(limit, min(LR._CI_POOL_LIMIT_CAP, LR._CI_RUN_LIMIT * 6))
            self.assertLessEqual(limit, LR._CI_POOL_LIMIT_CAP)

    def test_no_candidates_or_local_mode_makes_no_gh_call(self):
        local_gates = LiveGates("/nonexistent-home", self.state, self.journal, config={})
        with mock.patch.object(LR, "_ci_runs_pooled") as pooled:
            local_gates.prime_ci_pool([self._cand(1, "sha1", "feat/a")])
            self.gates.prime_ci_pool([])
            self.assertEqual(pooled.call_count, 0)
        self.assertIsNone(local_gates.ci_poll_budget())

    def test_a_branch_the_pool_never_covered_falls_back_to_a_solo_poll(self):
        """A branch discovered mid-tick (never passed to prime_ci_pool) still gets a correct answer —
        just via the pre-HERD-649a solo `_ci_runs` path, not the pooled one."""
        cand = self._cand(9, "sha9", "feat/late")
        with mock.patch.object(LR, "_ci_runs_pooled") as pooled, \
             mock.patch.object(LR, "_ci_runs", return_value=[
                 {"headSha": "sha9", "status": "COMPLETED", "conclusion": "SUCCESS",
                  "workflowName": "CI", "databaseId": 9}]) as solo:
            self.assertEqual(self.gates.health(cand), "CLEAN")
            self.assertEqual(pooled.call_count, 0)
            self.assertEqual(solo.call_count, 1)


class TestCiConclusiveMemo(unittest.TestCase):
    """HERD-649b: a CONCLUSIVE (CLEAN/CODEERROR) CI verdict is memoized per branch+sha so the NEXT
    tick needs no gh call for that exact commit; a WAIT is NEVER memoized (HERD-612)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = LiveState(self.tmp)

    def test_round_trip_clean_and_codeerror(self):
        self.assertIsNone(self.state.ci_conclusive_memo("feat/x"))
        self.state.record_ci_conclusive_memo("feat/x", "shaA", "CLEAN", "")
        self.assertEqual(self.state.ci_conclusive_memo("feat/x"),
                         {"sha": "shaA", "verdict": "CLEAN", "detail": ""})
        self.state.record_ci_conclusive_memo("feat/x", "shaB", "CODEERROR", "tests/a.sh")
        self.assertEqual(self.state.ci_conclusive_memo("feat/x"),
                         {"sha": "shaB", "verdict": "CODEERROR", "detail": "tests/a.sh"})

    def test_wait_is_never_written(self):
        """The ONLY writer refuses anything but CLEAN/CODEERROR — belt-and-suspenders under the real
        invariant, which is that `_ci_health` never calls it for a WAIT."""
        self.state.record_ci_conclusive_memo("feat/x", "shaA", "WAIT", "")
        self.assertIsNone(self.state.ci_conclusive_memo("feat/x"))

    def test_branch_with_a_slash_is_filesystem_safe(self):
        self.state.record_ci_conclusive_memo("feat/nested/thing", "shaA", "CLEAN", "")
        self.assertEqual(self.state.ci_conclusive_memo("feat/nested/thing")["sha"], "shaA")
        self.assertTrue(os.path.isfile(self.state.ci_conclusive_memo_file("feat/nested/thing")))

    def test_no_state_dir_is_inert(self):
        # LiveState(None) falls back to TREES/WORKTREES_DIR when either is set in the environment — a
        # watcher- or gate-wrapper-descended run exports one (tests/test-py-live-runtime.sh runs this
        # suite with WORKTREES_DIR set), which would hand this "stateless" probe a REAL ledger and
        # invert the assertion (see TestTransitionDedupe.test_no_state_dir_never_suppresses, same fix).
        with mock.patch.dict(os.environ, {}, clear=False):
            for k in ("TREES", "WORKTREES_DIR"):
                os.environ.pop(k, None)
            blackhole = LiveState(None)
            self.assertIsNone(blackhole.dir)
            blackhole.record_ci_conclusive_memo("feat/x", "shaA", "CLEAN", "")
            self.assertIsNone(blackhole.ci_conclusive_memo("feat/x"))

    def _gates(self, journal_path):
        return LiveGates("/nonexistent-home", self.state, LiveJournal(journal_path),
                         config={"HEALTH_SOURCE": "ci"})

    def _cand(self, sha):
        return LiveCandidate(pr=1, sha=sha, slug="feat-1", branch="feat/x", worktree="/nonexistent-wt")

    def test_conclusive_verdict_is_reused_with_no_gh_call_next_tick(self):
        cand = self._cand("shaA")
        runs = [{"headSha": "shaA", "status": "COMPLETED", "conclusion": "SUCCESS",
                "workflowName": "CI", "databaseId": 1, "headBranch": "feat/x"}]
        gates1 = self._gates(os.path.join(self.tmp, "j1.jsonl"))
        with mock.patch.object(LR, "_ci_runs_pooled", return_value=runs):
            gates1.prime_ci_pool([cand])
            self.assertEqual(gates1.health(cand), "CLEAN")
        # A FRESH LiveGates instance — models a new tick's own process (HERD-373: one instance lives
        # exactly one tick). The pooled/solo fetchers are poisoned: any gh call at all is a bug.
        gates2 = self._gates(os.path.join(self.tmp, "j2.jsonl"))
        with mock.patch.object(LR, "_ci_runs_pooled") as pooled, \
             mock.patch.object(LR, "_ci_runs") as solo:
            gates2.prime_ci_pool([cand])
            self.assertEqual(gates2.health(cand), "CLEAN")
            self.assertEqual(pooled.call_count, 0)
            self.assertEqual(solo.call_count, 0)
        self.assertTrue(gates2.reused_health)

    def test_pending_never_memoized_reruns_every_tick(self):
        cand = self._cand("shaP")
        pending_runs = [{"headSha": "shaP", "status": "IN_PROGRESS", "conclusion": None,
                         "workflowName": "CI", "databaseId": 2, "headBranch": "feat/x"}]
        for i in range(3):
            gates = self._gates(os.path.join(self.tmp, "j%d.jsonl" % i))
            with mock.patch.object(LR, "_ci_runs_pooled", return_value=pending_runs) as pooled:
                gates.prime_ci_pool([cand])
                self.assertEqual(gates.health(cand), WAIT)
                self.assertEqual(pooled.call_count, 1, "a pending verdict must re-poll EVERY tick")
        self.assertIsNone(self.state.ci_conclusive_memo("feat/x"))

    def test_new_sha_on_same_branch_invalidates_the_memo(self):
        runs_a = [{"headSha": "shaA", "status": "COMPLETED", "conclusion": "SUCCESS",
                  "workflowName": "CI", "databaseId": 1, "headBranch": "feat/x"}]
        gates1 = self._gates(os.path.join(self.tmp, "j1.jsonl"))
        with mock.patch.object(LR, "_ci_runs_pooled", return_value=runs_a):
            gates1.prime_ci_pool([self._cand("shaA")])
            self.assertEqual(gates1.health(self._cand("shaA")), "CLEAN")
        cand_b = self._cand("shaB")
        runs_b = [{"headSha": "shaB", "status": "COMPLETED", "conclusion": "SUCCESS",
                  "workflowName": "CI", "databaseId": 2, "headBranch": "feat/x"}]
        gates2 = self._gates(os.path.join(self.tmp, "j2.jsonl"))
        with mock.patch.object(LR, "_ci_runs_pooled", return_value=runs_b) as pooled:
            gates2.prime_ci_pool([cand_b])
            self.assertEqual(gates2.health(cand_b), "CLEAN")
            self.assertEqual(pooled.call_count, 1, "a new sha must re-poll, never trust the old memo")


class TestCiCodeerrorRecheckMarker(unittest.TestCase):
    """HERD-677: the throttle marker behind `ci_verdict_recheck` — a plain mtime-keyed file, exactly
    like `_ci_rerun_cooldown_marker`, so a standing CODEERROR gets re-verified on a bounded cadence
    instead of never again."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_due_when_no_marker_exists(self):
        self.assertTrue(LR._ci_codeerror_recheck_due(self.tmp, "feat/x", "shaR"))

    def test_not_due_immediately_after_marking(self):
        LR._mark_ci_codeerror_rechecked(self.tmp, "feat/x", "shaR")
        self.assertFalse(LR._ci_codeerror_recheck_due(self.tmp, "feat/x", "shaR"))

    def test_due_after_the_cadence_window_elapses(self):
        marker = LR._ci_codeerror_recheck_marker(self.tmp, "feat/x", "shaR")
        open(marker, "w").close()
        old = time.time() - (LR._CI_CODEERROR_RECHECK_SECS + 60)
        os.utime(marker, (old, old))
        self.assertTrue(LR._ci_codeerror_recheck_due(self.tmp, "feat/x", "shaR"))

    def test_no_state_dir_or_key_is_always_due(self):
        self.assertTrue(LR._ci_codeerror_recheck_due("", "feat/x", "shaR"))
        self.assertTrue(LR._ci_codeerror_recheck_due(self.tmp, "", "shaR"))
        self.assertTrue(LR._ci_codeerror_recheck_due(self.tmp, "feat/x", ""))

    def test_marker_is_keyed_on_branch_and_sha_not_just_branch(self):
        LR._mark_ci_codeerror_rechecked(self.tmp, "feat/x", "shaA")
        self.assertTrue(LR._ci_codeerror_recheck_due(self.tmp, "feat/x", "shaB"),
                        "a new sha must not inherit an old sha's recheck clock")


class TestCiVerdictHeal(unittest.TestCase):
    """HERD-677: a CI-sourced CODEERROR memo is not trusted forever — `ci_verdict_recheck` re-polls
    live CI on a bounded cadence and heals a stale BLOCKED red the instant a rerun flips the SAME sha
    green, exactly the gap that let PR #785 bounce a builder 4 dry rounds against evidence that had
    already healed minutes earlier."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = LiveState(self.tmp)
        self.jpath = os.path.join(self.tmp, "j.jsonl")

    def _gates(self, health_source="ci"):
        config = {"HEALTH_SOURCE": health_source} if health_source else {}
        return LiveGates("/nonexistent-home", self.state, LiveJournal(self.jpath), config=config)

    def _cand(self, sha="shaR", branch="feat/x"):
        return LiveCandidate(pr=1, sha=sha, slug="feat-1", branch=branch, worktree="/nonexistent-wt")

    def _events(self):
        out = []
        if not os.path.exists(self.jpath):
            return out
        with open(self.jpath, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    out.append(json.loads(line))
        return out

    def _backdated_codeerror_memo(self, sha="shaR", detail="tests/a.sh"):
        self.state.record_ci_conclusive_memo("feat/x", sha, "CODEERROR", detail)
        marker = LR._ci_codeerror_recheck_marker(self.tmp, "feat/x", sha)
        open(marker, "w").close()
        old = time.time() - (LR._CI_CODEERROR_RECHECK_SECS + 60)
        os.utime(marker, (old, old))

    def test_no_memo_is_a_noop(self):
        self.assertIsNone(self._gates().ci_verdict_recheck(self._cand()))

    def test_clean_memo_is_never_re_asked_about(self):
        self.state.record_ci_conclusive_memo("feat/x", "shaR", "CLEAN", "")
        gates = self._gates()
        with mock.patch.object(LR, "_ci_runs") as solo:
            self.assertIsNone(gates.ci_verdict_recheck(self._cand()))
            self.assertEqual(solo.call_count, 0, "only a CODEERROR memo is ever re-verified")

    def test_local_health_source_is_a_noop(self):
        self._backdated_codeerror_memo()
        gates = self._gates(health_source=None)
        with mock.patch.object(LR, "_ci_runs") as solo:
            self.assertIsNone(gates.ci_verdict_recheck(self._cand()))
            self.assertEqual(solo.call_count, 0)

    def test_just_recorded_codeerror_is_not_due_yet(self):
        """`_ci_health`'s own writer stamps the recheck marker the instant it records the memo — the
        very next call must not immediately re-poll."""
        self.state.record_ci_conclusive_memo("feat/x", "shaR", "CODEERROR", "tests/a.sh")
        LR._mark_ci_codeerror_rechecked(self.tmp, "feat/x", "shaR")
        gates = self._gates()
        with mock.patch.object(LR, "_ci_runs") as solo:
            self.assertIsNone(gates.ci_verdict_recheck(self._cand()))
            self.assertEqual(solo.call_count, 0, "a just-stamped recheck marker must not be due yet")

    def test_due_after_the_cadence_window_heals_to_clean(self):
        self._backdated_codeerror_memo()
        gates = self._gates()
        green = [{"headSha": "shaR", "status": "COMPLETED", "conclusion": "SUCCESS",
                 "workflowName": "CI", "databaseId": 2, "headBranch": "feat/x"}]
        with mock.patch.object(LR, "_ci_runs", return_value=green):
            self.assertEqual(gates.ci_verdict_recheck(self._cand()), "CLEAN")
        self.assertEqual(self.state.ci_conclusive_memo("feat/x"),
                         {"sha": "shaR", "verdict": "CLEAN", "detail": ""})
        self.assertFalse(gates.reused_health, "a genuine heal must not read as a reused cache hit")
        healed = [e for e in self._events() if e.get("event") == "ci_verdict_healed"]
        self.assertEqual(len(healed), 1)
        self.assertEqual(healed[0]["reason"], "rerun")
        self.assertEqual(healed[0]["pr"], 1)
        self.assertEqual(healed[0]["sha"], "shaR")

    def test_due_but_still_red_refreshes_evidence_and_rearms_the_throttle(self):
        self._backdated_codeerror_memo(detail="tests/old.sh")
        gates = self._gates()
        red = [{"headSha": "shaR", "status": "COMPLETED", "conclusion": "FAILURE",
               "workflowName": "CI", "databaseId": 3, "headBranch": "feat/x"}]
        with mock.patch.object(LR, "_ci_runs", return_value=red), \
             mock.patch.object(LR, "_ci_failed_log", return_value="ci-suite\t✗ tests/new.sh\n"):
            self.assertIsNone(gates.ci_verdict_recheck(self._cand()))
        self.assertEqual(self.state.ci_conclusive_memo("feat/x"),
                         {"sha": "shaR", "verdict": "CODEERROR", "detail": "tests/new.sh"})
        self.assertEqual([e for e in self._events() if e.get("event") == "ci_verdict_healed"], [])
        with mock.patch.object(LR, "_ci_runs") as solo:
            self.assertIsNone(gates.ci_verdict_recheck(self._cand()))
            self.assertEqual(solo.call_count, 0, "a re-confirmed red must re-arm the throttle too")

    def test_gh_unreadable_leaves_the_stale_verdict_standing(self):
        self._backdated_codeerror_memo()
        gates = self._gates()
        with mock.patch.object(LR, "_ci_runs", return_value=None):
            self.assertIsNone(gates.ci_verdict_recheck(self._cand()))
        self.assertEqual(self.state.ci_conclusive_memo("feat/x")["verdict"], "CODEERROR")

    def test_still_pending_leaves_the_stale_verdict_standing_and_does_not_memoize(self):
        self._backdated_codeerror_memo()
        gates = self._gates()
        pending = [{"headSha": "shaR", "status": "IN_PROGRESS", "conclusion": None,
                   "workflowName": "CI", "databaseId": 4, "headBranch": "feat/x"}]
        with mock.patch.object(LR, "_ci_runs", return_value=pending):
            self.assertIsNone(gates.ci_verdict_recheck(self._cand()))
        self.assertEqual(self.state.ci_conclusive_memo("feat/x")["verdict"], "CODEERROR")


class TestGhRateLimitStaleDeadlineReprobe(unittest.TestCase):
    """HERD-649c: a still-future rate-limit backoff deadline is a SNAPSHOT, not a promise — one cheap
    `gh api rate_limit` probe, only when a marker exists, can clear it early on a refilled budget."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.jpath = os.path.join(self.tmp, "j.jsonl")
        os.environ["HERD_JOURNAL_NOW"] = "2026-08-11T22:10:00Z"

    def tearDown(self):
        os.environ.pop("HERD_JOURNAL_NOW", None)

    def _tick(self):
        state = LiveState(self.tmp)
        journal = LiveJournal(self.jpath)
        scenario = {"candidates": [], "config": {}}
        return LiveTick({}, FixtureDiscovery(scenario), FixtureGates(scenario),
                        DryRunActuator(journal), journal, state=state), state

    def test_refilled_budget_clears_the_marker_early_and_runs_the_tick(self):
        tick, state = self._tick()
        future = int(LR._now_epoch()) + 1200
        state.set_gh_rate_limited_until(future)
        with mock.patch.object(LR, "_gh_rate_limit_remaining", return_value=500) as probe:
            res = tick.run()
            self.assertEqual(probe.call_count, 1)
            # HERD-670: the default-shape marker (no resource line) re-probes "core".
            probe.assert_called_once_with("core")
        self.assertNotIn("rate_limited", res)
        self.assertEqual(state.gh_rate_limited_until(), 0, "a refilled budget must clear the marker")
        self.assertTrue(any(e.get("event") == "gh_rate_limit_refilled_early"
                            for e in events(self.jpath)))

    def test_genuinely_exhausted_budget_keeps_the_backoff(self):
        tick, state = self._tick()
        future = int(LR._now_epoch()) + 1200
        state.set_gh_rate_limited_until(future)
        with mock.patch.object(LR, "_gh_rate_limit_remaining", return_value=0) as probe:
            res = tick.run()
            self.assertEqual(probe.call_count, 1)
        self.assertTrue(res.get("rate_limited"))
        self.assertEqual(state.gh_rate_limited_until(), future, "the marker must survive an exhausted probe")

    def test_a_failed_probe_keeps_the_backoff(self):
        tick, state = self._tick()
        future = int(LR._now_epoch()) + 1200
        state.set_gh_rate_limited_until(future)
        with mock.patch.object(LR, "_gh_rate_limit_remaining", return_value=None):
            res = tick.run()
        self.assertTrue(res.get("rate_limited"))
        self.assertEqual(state.gh_rate_limited_until(), future)

    def test_no_marker_never_spends_the_probe(self):
        """The re-probe is ONLY spent when a backoff is actually in force — a normal tick must never
        pay for it."""
        tick, _state = self._tick()
        with mock.patch.object(LR, "_gh_rate_limit_remaining") as probe:
            tick.run()
            self.assertEqual(probe.call_count, 0)

    def test_reprobe_reads_the_armed_resource_not_always_core(self):
        # HERD-670: a marker armed against "graphql" must re-probe "graphql", never default to "core".
        tick, state = self._tick()
        future = int(LR._now_epoch()) + 1200
        state.set_gh_rate_limited_until(future, "graphql")
        with mock.patch.object(LR, "_gh_rate_limit_remaining", return_value=0) as probe:
            tick.run()
        probe.assert_called_once_with("graphql")

    def test_graphql_exhaustion_does_not_refill_early_off_a_full_core_bucket(self):
        """HERD-670 regression: the exact grounding incident (2026-08-13 00:43-00:45Z) — core sat at
        4709/5000 the entire time graphql was 0/5000 exhausted. A core-only refill probe misread this
        as refilled every ~45s and flapped the backoff (engine_rate_limited / gh_rate_limit_refilled_
        early alternating). The probe must read graphql's own remaining count, not core's."""
        tick, state = self._tick()
        future = int(LR._now_epoch()) + 1200
        state.set_gh_rate_limited_until(future, "graphql")

        def _remaining(resource="core"):
            return {"core": 4709, "graphql": 0}.get(resource)

        with mock.patch.object(LR, "_gh_rate_limit_remaining", side_effect=_remaining):
            res = tick.run()
        self.assertTrue(res.get("rate_limited"), "a full core bucket must not clear a graphql backoff")
        self.assertEqual(state.gh_rate_limited_until(), future)
        evs = events(self.jpath) if os.path.exists(self.jpath) else []
        self.assertFalse(any(e.get("event") == "gh_rate_limit_refilled_early" for e in evs))

    def test_core_exhaustion_does_not_refill_early_off_a_full_graphql_bucket(self):
        """Inverse of the above: a core exhaustion (e.g. _repo_owner_name's REST call) must not be
        cleared by a full graphql bucket either — each resource's backoff is independent."""
        tick, state = self._tick()
        future = int(LR._now_epoch()) + 1200
        state.set_gh_rate_limited_until(future, "core")

        def _remaining(resource="core"):
            return {"core": 0, "graphql": 4988}.get(resource)

        with mock.patch.object(LR, "_gh_rate_limit_remaining", side_effect=_remaining):
            res = tick.run()
        self.assertTrue(res.get("rate_limited"))
        self.assertEqual(state.gh_rate_limited_until(), future)


if __name__ == "__main__":
    unittest.main(verbosity=2)
