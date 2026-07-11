"""test_statemachine_props.py — exhaustive stdlib unit tests for herd.statemachine (HERD-315, P3b).

These assert the lifecycle state machine's invariants directly — no bash oracle, because the bash
tree has NO explicit state machine (the point of P3b is that the doctrine-by-comment control flow
BECOMES a typed table). What is checked:

  * the transition table is TOTAL and WELL-FORMED — every (state, event) either maps to a real
    STATE or is cleanly rejected; terminals have no exits; every non-terminal is live and reachable;
  * supersession (§2.4/§6.1) reaches every non-terminal;
  * INFRA is not an outcome (§2.2) — the ONLY self-loops are the review/health retry edges;
  * the two decision bridges MATCH herd.decisions exactly, over their whole small input space
    (this is the "consume decisions.py, do not duplicate it" contract — the state machine must not
    grow its own copy of the budget/policy arithmetic);
  * export_table round-trips TRANSITIONS.

Stdlib-only (unittest + itertools) so the gate never needs an external dep; an OPTIONAL hypothesis
pass runs only when hypothesis is installed and is skip-soft otherwise (a missing optional tool is
never a red — AGENTS.md, the P1 packaging rule).

Run:  PYTHONPATH=pysrc python3 tests/test_statemachine_props.py
"""
import itertools
import unittest

from herd import statemachine as SM
from herd import decisions as D


def ledger(*rows):
    """Build a parsed refix ledger from ('pr','sha','kind', reset?) tuples (kind '' == legacy 4-field)."""
    lines = []
    for i, row in enumerate(rows):
        pr, sha, kind = row[0], row[1], row[2]
        is_reset = len(row) > 3 and row[3]
        if is_reset:
            lines.append("%d %s %s slug%d %s reset" % (i, pr, sha, i, kind))
        elif kind == "":
            lines.append("%d %s %s slug%d" % (i, pr, sha, i))  # legacy 4-field
        else:
            lines.append("%d %s %s slug%d %s" % (i, pr, sha, i, kind))
    return D.parse_refix_ledger("\n".join(lines))


class TableWellFormed(unittest.TestCase):
    """Every target is a real state; every key is a known (state, event) pair."""

    def test_targets_are_states(self):
        for (state, event), target in SM.TRANSITIONS.items():
            self.assertIn(state, SM.STATES, "unknown from-state %r" % (state,))
            self.assertIn(event, SM.EVENTS, "unknown event %r" % (event,))
            self.assertIn(target, SM.STATES, "%r-on-%r targets non-state %r" % (state, event, target))

    def test_states_and_events_are_unique(self):
        self.assertEqual(len(SM.STATES), len(set(SM.STATES)))
        self.assertEqual(len(SM.EVENTS), len(set(SM.EVENTS)))

    def test_terminal_subset_of_states(self):
        self.assertTrue(SM.TERMINAL.issubset(set(SM.STATES)))


class ExhaustiveTransition(unittest.TestCase):
    """The whole STATES x EVENTS grid: each cell is either a table hit or a clean rejection."""

    def test_every_cell_is_defined_or_rejected(self):
        for state, event in itertools.product(SM.STATES, SM.EVENTS):
            if SM.can(state, event):
                nxt = SM.transition(state, event)
                self.assertEqual(nxt, SM.TRANSITIONS[(state, event)])
                self.assertIn(nxt, SM.STATES)
            else:
                with self.assertRaises(SM.IllegalTransition):
                    SM.transition(state, event)

    def test_transition_matches_can(self):
        for state, event in itertools.product(SM.STATES, SM.EVENTS):
            self.assertEqual(SM.can(state, event), (state, event) in SM.TRANSITIONS)


class TerminalsAreDead(unittest.TestCase):
    def test_no_event_leaves_a_terminal(self):
        for state in SM.TERMINAL:
            self.assertEqual(SM.events_from(state), ())
            self.assertTrue(SM.is_terminal(state))
            for event in SM.EVENTS:
                self.assertFalse(SM.can(state, event), "%r must not accept %r" % (state, event))

    def test_non_terminals_are_live(self):
        for state in SM.STATES:
            if state in SM.TERMINAL:
                continue
            self.assertFalse(SM.is_terminal(state))
            self.assertTrue(SM.events_from(state), "non-terminal %r has no outgoing event" % (state,))


class Supersession(unittest.TestCase):
    """§2.4 new-sha cancel + §6.1 cross-sibling cancel reach every non-terminal state."""

    def test_supersession_from_every_non_terminal(self):
        for state in SM.STATES:
            if state in SM.TERMINAL:
                continue
            for ev in (SM.NEW_SHA, SM.SIBLING_RESTALE):
                self.assertEqual(SM.transition(state, ev), SM.SUPERSEDED)

    def test_terminals_do_not_supersede(self):
        for state in SM.TERMINAL:
            for ev in (SM.NEW_SHA, SM.SIBLING_RESTALE):
                self.assertFalse(SM.can(state, ev))


class InfraIsNotAnOutcome(unittest.TestCase):
    """§2.2: an infra death is a bounded RETRY, never a cached verdict — the only self-loops."""

    def test_only_self_loops_are_infra_retries(self):
        self_loops = {(s, ev) for (s, ev), t in SM.TRANSITIONS.items() if s == t}
        self.assertEqual(self_loops, {(SM.REVIEW, SM.REVIEW_INFRA), (SM.HEALTH, SM.HEALTH_INFRA)})


class Reachability(unittest.TestCase):
    """Every state is reachable from INTAKE — no dead code in the table."""

    def test_all_reachable_from_intake(self):
        seen = {SM.INTAKE}
        frontier = [SM.INTAKE]
        while frontier:
            state = frontier.pop()
            for event in SM.events_from(state):
                nxt = SM.transition(state, event)
                if nxt not in seen:
                    seen.add(nxt)
                    frontier.append(nxt)
        self.assertEqual(seen, set(SM.STATES), "unreachable: %s" % (set(SM.STATES) - seen))


class ExportRoundTrips(unittest.TestCase):
    def test_export_table_reconstructs_transitions(self):
        triples = SM.export_table()
        self.assertEqual(triples, sorted(triples), "export_table must be deterministically sorted")
        self.assertEqual({(f, e): t for f, e, t in triples}, SM.TRANSITIONS)

    def test_export_tsv_header_and_rows(self):
        tsv = SM.export_tsv()
        self.assertTrue(tsv.endswith("\n"))
        rows = tsv.rstrip("\n").split("\n")
        self.assertEqual(rows[0], "from\tevent\tto")
        self.assertEqual(len(rows) - 1, len(SM.TRANSITIONS))
        for row in rows[1:]:
            f, e, t = row.split("\t")
            self.assertEqual(SM.TRANSITIONS[(f, e)], t)


class BlockBridgeMatchesDecisions(unittest.TestCase):
    """classify_block MUST agree with decisions.refix_budget_reason over its whole small space —
    the state machine consumes the budget arithmetic, never re-derives it (§4)."""

    def test_bridge_is_exactly_the_budget_predicate(self):
        prs, shas, kinds = ("1", "2"), ("a", "b"), ("review", "health", "")
        cells = list(itertools.product(prs, shas, kinds, (False, True)))
        for n in range(0, 3):
            for combo in itertools.product(cells, repeat=n):
                led = ledger(*combo)
                for rmr in (None, "", "0", "1", "2", "junk"):
                    for pr in prs:
                        for k in ("review", "health", "stale", "ci"):
                            ev = SM.classify_block(led, pr, "a", k, rmr)
                            blocked = D.refix_budget_reason(led, pr, k, rmr) is not None
                            self.assertEqual(ev, SM.REFIX_EXHAUSTED if blocked else SM.REFIX_BOUNCE)

    def test_next_after_block_drives_the_table(self):
        # exhausted budget escalates; open budget bounces back to a fresh gate.
        maxed = ledger(("8", "a", "review"), ("8", "b", "review"), ("8", "c", "review"))
        self.assertEqual(SM.next_after_block(SM.BLOCKED, maxed, "8", "c", "review", "3"), SM.ESCALATED)
        self.assertEqual(SM.next_after_block(SM.BLOCKED, ledger(), "8", "a", "review", "3"), SM.INTAKE)
        # the stale rail escalates through STALE_HELD's exhausted edge when its own budget is spent
        # (STALE_HELD's other exit, base_fresh, is progress and re-enters INTAKE — tested below).
        stale_maxed = ledger(("8", "a", "stale"), ("8", "b", "stale"), ("8", "c", "stale"))
        self.assertEqual(SM.next_after_block(SM.STALE_HELD, stale_maxed, "8", "c", "stale", "3"), SM.ESCALATED)
        self.assertEqual(SM.transition(SM.STALE_HELD, SM.BASE_FRESH), SM.INTAKE)


class StaleBounceIsAnImplicitSelfHold(unittest.TestCase):
    """HERD-328 S1: an OPEN stale budget is an implicit self-hold awaiting ``base_fresh`` — there is
    deliberately NO ``(STALE_HELD, refix_bounce)`` table edge, and a ``→INTAKE`` mapping would be
    wrong (a stale bounce only wakes the builder to rebase; re-gating is deferred to ``base_fresh``).
    The repro that surfaced the docstring lie is pinned here as the regression guard."""

    def test_no_refix_bounce_edge_from_stale_held(self):
        # NO →INTAKE (or any) mapping: the edge must stay absent from the table.
        self.assertFalse(SM.can(SM.STALE_HELD, SM.REFIX_BOUNCE))
        self.assertNotIn((SM.STALE_HELD, SM.REFIX_BOUNCE), SM.TRANSITIONS)

    def test_open_stale_budget_classifies_as_a_bounce_not_a_crash(self):
        # classify_block is a PURE budget read and must return REFIX_BOUNCE for a surviving stale
        # budget (the branch a stale caller keys on) — it never itself raises.
        self.assertEqual(SM.classify_block(ledger(), "8", "a", "stale", "3"), SM.REFIX_BOUNCE)

    def test_next_after_block_raises_on_a_surviving_stale_budget(self):
        # THE REPRO (PR #435 forensics): composing through the table from STALE_HELD on a surviving
        # budget raises IllegalTransition BY DESIGN — stale callers must branch on classify_block,
        # not use this composite for the bounce case.
        with self.assertRaises(SM.IllegalTransition):
            SM.next_after_block(SM.STALE_HELD, ledger(), "8", "a", "stale", "3")

    def test_the_only_progress_out_of_stale_held_is_base_fresh_or_exhaustion(self):
        # A stale caller's two real exits: escalate on an exhausted budget, else self-hold in
        # STALE_HELD until base_fresh (the rebase) re-enters the pipeline at INTAKE.
        self.assertEqual(SM.events_from(SM.STALE_HELD),
                         tuple(sorted((SM.BASE_FRESH, SM.REFIX_EXHAUSTED,
                                       SM.NEW_SHA, SM.SIBLING_RESTALE))))
        self.assertEqual(SM.transition(SM.STALE_HELD, SM.BASE_FRESH), SM.INTAKE)


class GatesPassedBridgeMatchesDecisions(unittest.TestCase):
    """classify_gates_passed MUST agree with decisions.hold_decision over the whole truth table
    (§5.4–§5.5) — the policy decision has exactly one home."""

    def test_bridge_is_exactly_hold_decision(self):
        for mode, hv, ap, hvpol in itertools.product(
            ("observe", "approve", "auto", "bogus"),
            ("", "1"),
            ("", "1"),
            ("hold", "coordinator", "auto"),
        ):
            ev = SM.classify_gates_passed(mode, hv, ap, hvpol)
            action = D.hold_decision(mode, hv, ap, hvpol)
            want = {"MERGE": SM.DECIDE_MERGE, "HOLD": SM.DECIDE_HOLD, "OBSERVE": SM.DECIDE_OBSERVE}[action]
            self.assertEqual(ev, want, "mode=%s hv=%s ap=%s hvpol=%s" % (mode, hv, ap, hvpol))

    def test_next_after_gates_lands_each_outcome(self):
        self.assertEqual(SM.next_after_gates(SM.BLESSED, "auto", "", ""), SM.MERGED)
        self.assertEqual(SM.next_after_gates(SM.BLESSED, "approve", "", ""), SM.HOLD)      # unapproved holds
        self.assertEqual(SM.next_after_gates(SM.BLESSED, "approve", "", "1"), SM.MERGED)   # approved merges
        self.assertEqual(SM.next_after_gates(SM.BLESSED, "observe", "", ""), SM.OBSERVE)
        # a human-verify block under the default hold policy holds a would-be auto-merge.
        self.assertEqual(SM.next_after_gates(SM.BLESSED, "auto", "1", "", "hold"), SM.HOLD)
        self.assertEqual(SM.transition(SM.HOLD, SM.APPROVED), SM.MERGED)                   # HOLD clears on approval


class HappyPath(unittest.TestCase):
    """The canonical green run, transition by transition (§2.1 order → §2.2 PASS → §5 merge)."""

    def test_intake_to_merged(self):
        s = SM.INTAKE
        for ev, expect in (
            (SM.DISPATCH_HEALTH, SM.HEALTH),
            (SM.HEALTH_CLEAN, SM.REVIEW),
            (SM.REVIEW_PASS, SM.BLESSED),
            (SM.DECIDE_MERGE, SM.MERGED),
        ):
            s = SM.transition(s, ev)
            self.assertEqual(s, expect)
        self.assertTrue(SM.is_terminal(s))

    def test_flaky_health_still_advances(self):
        self.assertEqual(SM.transition(SM.HEALTH, SM.HEALTH_FLAKY), SM.REVIEW)

    def test_infra_retries_in_place(self):
        self.assertEqual(SM.transition(SM.REVIEW, SM.REVIEW_INFRA), SM.REVIEW)
        self.assertEqual(SM.transition(SM.HEALTH, SM.HEALTH_INFRA), SM.HEALTH)


# ── OPTIONAL hypothesis pass — extra fuzz when installed; skip-soft otherwise (never a red) ──────
try:
    from hypothesis import given, settings, strategies as st
    _HAS_HYPOTHESIS = True
except Exception:  # ImportError, or a broken partial install — either way, skip soft.
    _HAS_HYPOTHESIS = False


@unittest.skipUnless(_HAS_HYPOTHESIS, "hypothesis not installed (optional; stdlib checks cover this)")
class HypothesisProperties(unittest.TestCase):
    def test_random_event_walks_stay_well_typed(self):
        """From any state, any event sequence either advances to a real STATE or is cleanly rejected —
        the machine never lands somewhere untyped and never raises anything but IllegalTransition."""

        @given(st.sampled_from(SM.STATES), st.lists(st.sampled_from(SM.EVENTS), max_size=20))
        @settings(max_examples=300, deadline=None)
        def check(start, events):
            state = start
            for ev in events:
                if SM.can(state, ev):
                    state = SM.transition(state, ev)
                    self.assertIn(state, SM.STATES)
                else:
                    with self.assertRaises(SM.IllegalTransition):
                        SM.transition(state, ev)

        check()

    def test_gates_bridge_matches_hold_decision(self):
        @given(
            st.sampled_from(["observe", "approve", "auto", "junk", ""]),
            st.sampled_from(["", "1", "x"]),
            st.sampled_from(["", "1", "x"]),
            st.sampled_from(["hold", "coordinator", "auto"]),
        )
        @settings(max_examples=300, deadline=None)
        def check(mode, hv, ap, hvpol):
            ev = SM.classify_gates_passed(mode, hv, ap, hvpol)
            action = D.hold_decision(mode, hv, ap, hvpol)
            self.assertEqual(ev, {"MERGE": SM.DECIDE_MERGE, "HOLD": SM.DECIDE_HOLD,
                                  "OBSERVE": SM.DECIDE_OBSERVE}[action])

        check()


if __name__ == "__main__":
    unittest.main(verbosity=1)
