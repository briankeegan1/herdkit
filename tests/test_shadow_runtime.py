"""test_shadow_runtime.py — stdlib unit tests for the P3c shadow watcher (HERD-316, EPIC HERD-300).

Asserts the INTERNAL invariants of the async shadow runtime + its journal writer directly (no bash
oracle here — the byte-for-byte parity of the journal ENCODING against the live journal.sh is proved
by the shell wrapper tests/test-py-shadow-runtime.sh, which drives both off one set of args). Stdlib
only (unittest + asyncio), so the gate never needs an external dep — the P1 packaging rule.

Coverage:
  * DRY-RUN: the runtime mutates NOTHING but .herd/journal-shadow.jsonl — no gh/merge/pane surface in
    the module source, and a run writes only the shadow file (the real journal.jsonl is never touched).
  * Journal shapes: ts+event first, bash-parity integer coercion, journal.sh JSON separators.
  * Gate outcomes: PASS->MERGE, health CODEERROR->BLOCK, review BLOCK->BLOCK, INFRA->ESCALATE (no
    verdict cached), stale->HOLD, human-verify->HOLD, approve-without-approval->HOLD, observe->OBSERVE.
  * Semaphores: peak review/health occupancy never exceeds REVIEW_CONCURRENCY/HEALTH_CONCURRENCY and
    reaches the cap when enough candidates overlap; a garbage knob coerces to the default.
  * Cancel-on-supersession: a new sha mid-gate cancels the in-flight rail and re-gates the new sha.
  * Guarded P3b import: SM satisfies STATES/EVENTS/transition and the fallback throws on illegal edges.

Run:  PYTHONPATH=pysrc python3 tests/test_shadow_runtime.py
"""
import asyncio
import json
import os
import re
import tempfile
import unittest

from herd import shadow_runtime as SR
from herd.shadow_journal import ShadowJournal, encode_event


def _strip_py_comments_and_strings(src):
    """Crudely blank out Python comments and string/docstring literals, leaving CODE tokens.

    Enough to keep the DRY-RUN mutation-surface assertion from tripping on prose in the module
    docstring (which legitimately names gh/merge/herdr as things it does NOT do). Not a real parser
    — it drops triple-quoted blocks, single/double-quoted strings, and #-comments.
    """
    import re as _re
    src = _re.sub(r'\'\'\'.*?\'\'\'', "", src, flags=_re.S)
    src = _re.sub(r'""".*?"""', "", src, flags=_re.S)
    src = _re.sub(r"#[^\n]*", "", src)
    src = _re.sub(r"'[^'\n]*'", "''", src)
    src = _re.sub(r'"[^"\n]*"', '""', src)
    return src


def run(watcher, cands):
    return watcher.run(cands)


def cand(pr, **kw):
    kw.setdefault("sha", "sha%s" % pr)
    return SR.Candidate.from_dict(dict(pr=pr, **kw))


def events(path):
    with open(path, encoding="utf-8") as fh:
        return [json.loads(l) for l in fh if l.strip()]


class TempJournalCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.jpath = os.path.join(self.tmp, "journal-shadow.jsonl")
        # A deterministic ts so assertions never race the clock (the journal.sh test seam).
        os.environ["HERD_JOURNAL_NOW"] = "2026-07-10T00:00:00Z"

    def tearDown(self):
        os.environ.pop("HERD_JOURNAL_NOW", None)

    def watcher(self, config=None, stage_delay=0.0):
        return SR.ShadowWatcher(config=config or {}, journal=ShadowJournal(self.jpath),
                                stage_delay=stage_delay)


class TestDryRun(TempJournalCase):
    def test_module_has_no_mutation_surface(self):
        """The runtime must not carry any real-world mutation surface (the DRY-RUN non-negotiable).

        Checked against CODE, not prose: the module docstring legitimately DESCRIBES what it does not
        do (no gh, no merge, no herdr), so we assert the absence of the actual shell-out / process
        primitives — no subprocess, no os.system/os.popen — that a real mutation would require.
        """
        src = open(SR.__file__, encoding="utf-8").read()
        code = _strip_py_comments_and_strings(src)
        for forbidden in ("subprocess", "os.system", "os.popen", "os.exec", "Popen"):
            self.assertNotIn(forbidden, code,
                             "shadow runtime code must not reference %r (DRY-RUN)" % forbidden)

    def test_only_shadow_journal_is_written(self):
        w = self.watcher({"MERGE_POLICY": "auto"})
        run(w, [cand(1, review="PASS", health="CLEAN")])
        self.assertTrue(os.path.exists(self.jpath))
        # The runtime writes ONLY journal-shadow.jsonl — never the real journal.jsonl.
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "journal.jsonl")))
        # And the shadow journal basename is the guarded one.
        self.assertEqual(ShadowJournal.BASENAME, "journal-shadow.jsonl")

    def test_journal_failure_never_raises(self):
        """A journal that cannot resolve a path drops entries silently and the run still completes."""
        j = ShadowJournal(path=None)
        self.assertFalse(j.append("x", pr=1))  # no destination -> advisory False, no raise
        w = SR.ShadowWatcher(config={"MERGE_POLICY": "auto"}, journal=j)
        res = run(w, [cand(1)])  # must not raise despite the black-hole journal
        self.assertEqual(res["outcomes"]["1"], "MERGE")


class TestJournalShapes(TempJournalCase):
    def test_ts_and_event_lead_every_object(self):
        w = self.watcher({"MERGE_POLICY": "auto"})
        run(w, [cand(1, review="PASS", health="CLEAN")])
        objs = events(self.jpath)
        self.assertTrue(objs)
        for o in objs:
            keys = list(o.keys())
            self.assertEqual(keys[0], "ts")
            self.assertEqual(keys[1], "event")
            self.assertEqual(o["ts"], "2026-07-10T00:00:00Z")

    def test_integer_coercion_parity(self):
        # Mirrors journal.sh: integer-looking -> JSON number, else string; "-"/""/"1.5" stay strings.
        line = encode_event("e", ["a", "5", "b", "-5", "c", "007", "d", "-", "e", "", "f", "1.5"],
                            ts="T")
        o = json.loads(line)
        self.assertEqual(o["a"], 5)
        self.assertEqual(o["b"], -5)
        self.assertEqual(o["c"], 7)
        self.assertEqual(o["d"], "-")
        self.assertEqual(o["e"], "")
        self.assertEqual(o["f"], "1.5")
        # journal.sh serialization: no spaces after separators.
        self.assertNotIn(", ", line)
        self.assertNotIn(": ", line)

    def test_merge_event_is_dry_run_shaped(self):
        w = self.watcher({"MERGE_POLICY": "auto"})
        run(w, [cand(1, slug="feat-a", review="PASS", health="CLEAN")])
        merges = [o for o in events(self.jpath) if o["event"] == "merge"]
        self.assertEqual(len(merges), 1)
        m = merges[0]
        self.assertEqual(m["reason"], "gates_passed")
        self.assertEqual(m["pr"], 1)  # numeric, per coercion


class TestGateOutcomes(TempJournalCase):
    def _run_one(self, policy="auto", **kw):
        w = self.watcher({"MERGE_POLICY": policy})
        res = run(w, [cand(1, **kw)])
        return res["outcomes"]["1"], events(self.jpath)

    def test_clean_pass_merges(self):
        out, ev = self._run_one(review="PASS", health="CLEAN")
        self.assertEqual(out, "MERGE")

    def test_flaky_still_passes_health(self):
        out, _ = self._run_one(review="PASS", health="FLAKY")
        self.assertEqual(out, "MERGE")

    def test_codeerror_blocks(self):
        out, ev = self._run_one(review="PASS", health="CODEERROR")
        self.assertEqual(out, "BLOCK")
        # A health block short-circuits BEFORE the review rail dispatches.
        self.assertFalse([o for o in ev if o["event"] == "review_dispatched"])
        self.assertTrue([o for o in ev if o["event"] == "refix_bounce"])

    def test_review_block_blocks(self):
        out, ev = self._run_one(review="BLOCK", health="CLEAN")
        self.assertEqual(out, "BLOCK")
        verdicts = [o for o in ev if o["event"] == "verdict_recorded"]
        self.assertEqual(verdicts[0]["value"], "BLOCK")
        self.assertEqual(verdicts[0]["source"], "reviewer")

    def test_infra_is_never_a_cached_verdict(self):
        out, ev = self._run_one(review="INFRA", health="CLEAN")
        self.assertEqual(out, "ESCALATE")
        # INFRA routes to infra_event, never verdict_recorded (contract §2.2/§3.2).
        self.assertFalse([o for o in ev if o["event"] == "verdict_recorded"])
        self.assertTrue([o for o in ev if o["event"] == "infra_event"])

    def test_stale_holds_before_any_rail(self):
        out, ev = self._run_one(stale=True)
        self.assertEqual(out, "HOLD")
        self.assertTrue([o for o in ev if o["event"] == "stale_dup_hold"])
        self.assertFalse([o for o in ev if o["event"] == "healthcheck_started"])

    def test_human_verify_holds_under_auto(self):
        out, ev = self._run_one(policy="auto", review="PASS", health="CLEAN", hv_hold=True)
        self.assertEqual(out, "HOLD")

    def test_approve_policy_holds_without_approval(self):
        out, _ = self._run_one(policy="approve", review="PASS", health="CLEAN")
        self.assertEqual(out, "HOLD")

    def test_approve_policy_merges_with_approval(self):
        out, _ = self._run_one(policy="approve", review="PASS", health="CLEAN", approved=True)
        self.assertEqual(out, "MERGE")

    def test_observe_never_merges(self):
        out, ev = self._run_one(policy="observe", review="PASS", health="CLEAN")
        self.assertEqual(out, "OBSERVE")
        self.assertFalse([o for o in ev if o["event"] == "merge"])


class TestSemaphores(TempJournalCase):
    def test_review_peak_never_exceeds_and_reaches_cap(self):
        # Health wide open (10), review capped at 2, 4 overlapping candidates + a small delay so the
        # rail critical sections genuinely overlap. Peak review must reach 2 and never exceed it.
        w = self.watcher({"REVIEW_CONCURRENCY": 2, "HEALTH_CONCURRENCY": 10}, stage_delay=0.05)
        res = run(w, [cand(i, review="PASS", health="CLEAN") for i in range(1, 5)])
        self.assertLessEqual(res["peak_review"], 2)
        self.assertEqual(res["peak_review"], 2)

    def test_health_serializes_at_one(self):
        w = self.watcher({"REVIEW_CONCURRENCY": 5, "HEALTH_CONCURRENCY": 1}, stage_delay=0.03)
        res = run(w, [cand(i, review="PASS", health="CLEAN") for i in range(1, 5)])
        self.assertEqual(res["peak_health"], 1)

    def test_garbage_concurrency_coerces_to_default(self):
        self.assertEqual(SR._pos_int("banana", 2), 2)
        self.assertEqual(SR._pos_int("0", 2), 2)
        self.assertEqual(SR._pos_int(None, 1), 1)
        self.assertEqual(SR._pos_int("3", 2), 3)


class TestSupersession(TempJournalCase):
    def test_new_sha_cancels_and_regates(self):
        w = self.watcher({"MERGE_POLICY": "auto"}, stage_delay=0.02)
        res = run(w, [cand(1, sha="old", review="PASS", health="CLEAN",
                           supersede_to="new", supersede_at="review")])
        self.assertEqual(res["outcomes"]["1"], "MERGE")
        ev = events(self.jpath)
        sup = [o for o in ev if o["event"] == "shadow_supersede"]
        self.assertEqual(len(sup), 1)
        self.assertEqual(sup[0]["old_sha"], "old")
        self.assertEqual(sup[0]["new_sha"], "new")
        self.assertTrue([o for o in ev if o["event"] == "shadow_regate"])
        # The lifecycle passed through SUPERSEDED and the final merge is on the NEW sha.
        terminal_super = getattr(SR.SM, "SUPERSEDED", "SUPERSEDED")
        self.assertTrue([o for o in ev if o["event"] == "shadow_state" and o["state_to"] == terminal_super])
        merge = [o for o in ev if o["event"] == "merge"][0]
        self.assertEqual(merge["sha"], "new")


class TestStateMachineGuard(unittest.TestCase):
    def test_active_sm_satisfies_p3b_interface(self):
        for name in ("STATES", "EVENTS", "transition"):
            self.assertTrue(hasattr(SR.SM, name), "state machine missing %s" % name)

    def test_fallback_transition_is_legal_and_throws(self):
        # The LOCAL mirror mirrors P3b's vocabulary (INTAKE/HEALTH/... + lowercase events).
        fsm = SR._FallbackStateMachine
        self.assertEqual(fsm.transition("INTAKE", "dispatch_health"), "HEALTH")
        self.assertEqual(fsm.transition("BLESSED", "decide_merge"), "MERGED")
        with self.assertRaises(SR.IllegalTransition):
            fsm.transition("MERGED", "dispatch_health")  # a terminal state has no outgoing edge

    def test_illegal_transition_is_observed_not_fatal(self):
        # If the state model rejects an event mid-run, the runtime journals illegal_transition and
        # keeps going (the lifecycle is an assertion layer over the journal, never a run-killer).
        tmp = tempfile.mkdtemp()
        jpath = os.path.join(tmp, "journal-shadow.jsonl")
        w = SR.ShadowWatcher(config={"MERGE_POLICY": "auto"}, journal=ShadowJournal(jpath))
        # Force an illegal event through _advance directly: no event is legal from a terminal state.
        c = cand(9)
        w._state["9"] = getattr(SR.SM, "MERGED", "MERGED")
        w._advance(c, "dispatch_health")  # MERGED (terminal) --dispatch_health--> illegal
        objs = events(jpath)
        self.assertTrue([o for o in objs if o["event"] == "illegal_transition"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
