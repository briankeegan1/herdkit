"""test_decisions_props.py — stdlib property/unit tests for herd.decisions (HERD-303, P2).

These assert the INTERNAL invariants of the pure decision core directly (no bash oracle) — the
cross-implementation parity is proved by tests/test-py-decisions.sh, which drives this module and
the live bash functions off one argv. Stdlib-only (unittest + itertools) so the gate never needs an
external dep; an OPTIONAL hypothesis pass runs only when hypothesis happens to be installed and is
skip-soft otherwise (a missing optional tool is never a red — AGENTS.md, the P1 packaging rule).

Run:  PYTHONPATH=pysrc python3 tests/test_decisions_props.py
"""
import itertools
import unittest

from herd import decisions as D


def ledger(*rows):
    """Build a parsed ledger from ('pr','sha','kind', reset?) tuples (kind '' == legacy 4-field)."""
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


class CapCoercion(unittest.TestCase):
    def test_fallback_to_three(self):
        for bad in (None, "", "0", "abc", "-1", "3x", " "):
            self.assertEqual(D.refix_cap_num(bad), 3, "bad cap %r should coerce to 3" % (bad,))

    def test_numeric_passthrough(self):
        self.assertEqual(D.refix_cap_num("5"), 5)
        self.assertEqual(D.refix_cap_num(1), 1)
        self.assertEqual(D.refix_cap_num("10"), 10)

    def test_total_is_triple_rail(self):
        for v in (None, "", "1", "3", "5", "garbage"):
            self.assertEqual(D.refix_total_cap(v), 3 * D.refix_rail_cap(v))


class LegacyKindReadsAsReview(unittest.TestCase):
    def test_no_kind_line_counts_as_review(self):
        led = ledger(("42", "aaa", ""))  # legacy 4-field bounce
        self.assertEqual(D.refix_rail_count(led, "42", "review"), 1)
        self.assertEqual(D.refix_rail_count(led, "42", "health"), 0)
        self.assertTrue(D.refix_attempted(led, "42", "aaa", "review"))
        self.assertTrue(D.refix_attempted(led, "42", "aaa"))  # no-kind arg ⇒ any rail
        self.assertFalse(D.refix_attempted(led, "42", "aaa", "health"))


class RefundOnGreen(unittest.TestCase):
    def test_reset_zeroes_rail_but_not_total_or_evidence(self):
        led = ledger(
            ("7", "s1", "review"),
            ("7", "s2", "review"),
            ("7", "s3", "review", True),   # reset — refund the rail
            ("7", "s4", "review"),
        )
        self.assertEqual(D.refix_rail_count(led, "7", "review"), 1)        # reset zeroed, then 1 more
        self.assertEqual(D.refix_total_count(led, "7"), 3)                 # resets never refund total
        self.assertEqual(D.refix_round_count_kind(led, "7", "review"), 3)  # nor the evidence counter

    def test_reset_row_is_not_a_bounce(self):
        led = ledger(("7", "s3", "review", True))
        self.assertFalse(D.refix_attempted(led, "7", "s3", "review"))
        self.assertEqual(D.refix_total_count(led, "7"), 0)


class ShaKeying(unittest.TestCase):
    def test_attempted_is_per_pr_sha(self):
        led = ledger(("42", "aaa", "review"))
        self.assertTrue(D.refix_attempted(led, "42", "aaa", "review"))
        self.assertFalse(D.refix_attempted(led, "42", "bbb", "review"))  # a new sha re-opens
        self.assertFalse(D.refix_attempted(led, "43", "aaa", "review"))  # different PR


class BudgetReason(unittest.TestCase):
    def test_rail_cap_phrase(self):
        led = ledger(("8", "a", "review"), ("8", "b", "review"), ("8", "c", "review"))
        self.assertEqual(D.refix_budget_reason(led, "8", "review", "3"),
                         "refix limit (3 rounds) reached")
        self.assertIsNone(D.refix_budget_reason(led, "8", "health", "3"))  # other rail still open

    def test_total_cap_phrase_when_no_single_rail_maxed(self):
        led = ledger(
            ("9", "a", "review"), ("9", "a", "health"), ("9", "a", "stale"),
            ("9", "a", "review"), ("9", "a", "health"), ("9", "a", "stale"),
        )
        # cap 2 ⇒ total cap 6; ci rail is empty (0<2) but total 6>=6.
        self.assertEqual(D.refix_budget_reason(led, "9", "ci", "2"),
                         "refix limit (6 total rounds across rails) reached")
        # review rail is 2>=2, so the RAIL phrase wins (checked first).
        self.assertEqual(D.refix_budget_reason(led, "9", "review", "2"),
                         "refix limit (2 rounds) reached")

    def test_open_budget_is_none(self):
        self.assertIsNone(D.refix_budget_reason(ledger(), "1", "review", "3"))


class MergePolicy(unittest.TestCase):
    def test_recognized_verbatim(self):
        for p in ("auto", "approve", "observe"):
            self.assertEqual(D.effective_merge_policy(p), p)
            self.assertFalse(D.merge_policy_is_typo(p))

    def test_typo_fails_strict_to_observe(self):
        for p in ("AUTO", "Approve", "garbage", "auto ", " observe"):
            self.assertEqual(D.effective_merge_policy(p), "observe")
            self.assertTrue(D.merge_policy_is_typo(p))

    def test_empty_derives_from_legacy(self):
        for mp in ("", None):
            self.assertEqual(D.effective_merge_policy(mp, None), "auto")      # unset WA ⇒ auto
            self.assertEqual(D.effective_merge_policy(mp, "true"), "auto")
            for off in ("false", "no", "off", "0"):
                self.assertEqual(D.effective_merge_policy(mp, off), "approve")
        self.assertFalse(D.merge_policy_is_typo(""))
        self.assertFalse(D.merge_policy_is_typo(None))

    def test_legacy_helper_directly(self):
        self.assertEqual(D.legacy_automerge_policy(None), "auto")
        self.assertEqual(D.legacy_automerge_policy("yes"), "auto")
        for off in ("false", "no", "off", "0"):
            self.assertEqual(D.legacy_automerge_policy(off), "approve")


class HoldDecision(unittest.TestCase):
    def test_exhaustive_truth_table(self):
        for mode, hv, ap, hvpol in itertools.product(
            ("observe", "approve", "auto", "bogus"),
            ("", "1"),
            ("", "1"),
            ("hold", "coordinator", "auto"),
        ):
            got = D.hold_decision(mode, hv, ap, hvpol)
            if mode == "observe":
                want = "OBSERVE"
            elif mode == "approve":
                want = "MERGE" if ap else "HOLD"
            elif mode == "auto":
                if hv and hvpol != "auto":
                    want = "MERGE" if ap else "HOLD"
                else:
                    want = "MERGE"
            else:
                want = "MERGE"  # catch-all
            self.assertEqual(got, want, "mode=%s hv=%s ap=%s hvpol=%s" % (mode, hv, ap, hvpol))

    def test_truthiness_matches_bash_dash_n(self):
        # Non-empty string / True == set; ""/None/False == unset — matches bash [ -n ... ].
        self.assertEqual(D.hold_decision("approve", "", True), "MERGE")
        self.assertEqual(D.hold_decision("approve", "", None), "HOLD")
        self.assertEqual(D.hold_decision("approve", "", False), "HOLD")
        self.assertEqual(D.hold_decision("auto", True, "", "hold"), "HOLD")


class CrossInvariants(unittest.TestCase):
    """Exhaustive small-space check: rail_count <= round_count_kind <= total_count, always."""

    def test_counter_ordering(self):
        prs, shas, kinds = ("1", "2"), ("a", "b"), ("review", "health", "")
        # every ledger of up to 3 rows drawn from the small space, bounce-or-reset
        cells = list(itertools.product(prs, shas, kinds, (False, True)))
        for n in range(0, 4):
            for combo in itertools.product(cells, repeat=n):
                led = ledger(*combo)
                for pr in prs:
                    total = D.refix_total_count(led, pr)
                    for k in ("review", "health", "stale", "ci"):
                        rail = D.refix_rail_count(led, pr, k)
                        kind_total = D.refix_round_count_kind(led, pr, k)
                        self.assertLessEqual(rail, kind_total)
                        self.assertLessEqual(kind_total, total)
                        self.assertGreaterEqual(rail, 0)


# ── OPTIONAL hypothesis pass — extra fuzz when installed; skip-soft otherwise (never a red) ──────
try:
    from hypothesis import given, settings, strategies as st
    _HAS_HYPOTHESIS = True
except Exception:  # ImportError, or a broken partial install — either way, skip soft.
    _HAS_HYPOTHESIS = False


@unittest.skipUnless(_HAS_HYPOTHESIS, "hypothesis not installed (optional; stdlib checks cover this)")
class HypothesisProperties(unittest.TestCase):
    def test_counter_ordering_property(self):
        pr_s = st.sampled_from(["1", "2", "42"])
        sha_s = st.sampled_from(["a", "b", "c"])
        kind_s = st.sampled_from(["review", "health", "stale", "ci", ""])
        row_s = st.tuples(pr_s, sha_s, kind_s, st.booleans())

        @given(st.lists(row_s, max_size=12))
        @settings(max_examples=200, deadline=None)
        def check(rows):
            led = ledger(*rows)
            for pr in ("1", "2", "42"):
                total = D.refix_total_count(led, pr)
                for k in ("review", "health", "stale", "ci"):
                    rail = D.refix_rail_count(led, pr, k)
                    kind_total = D.refix_round_count_kind(led, pr, k)
                    self.assertLessEqual(rail, kind_total)
                    self.assertLessEqual(kind_total, total)

        check()

    def test_budget_reason_matches_predicate(self):
        @given(
            st.lists(st.tuples(st.sampled_from(["1"]), st.sampled_from(["a", "b"]),
                               st.sampled_from(["review", "health"]), st.booleans()), max_size=10),
            st.sampled_from([None, "", "0", "2", "3", "junk"]),
        )
        @settings(max_examples=200, deadline=None)
        def check(rows, rmr):
            led = ledger(*rows)
            rcap, tcap = D.refix_rail_cap(rmr), D.refix_total_cap(rmr)
            rail = D.refix_rail_count(led, "1", "review")
            total = D.refix_total_count(led, "1")
            reason = D.refix_budget_reason(led, "1", "review", rmr)
            blocked = rail >= rcap or total >= tcap
            self.assertEqual(reason is not None, blocked)

        check()


if __name__ == "__main__":
    unittest.main(verbosity=1)
