#!/usr/bin/env bash
# rubric-screen-sim.sh — a self-contained VERIFY/SIM for the rubric-screening primitive (HERD-166).
#
# It runs the dual-screener MERGE (scripts/herd/experiment/rubric-screen-merge.sh) over the committed
# worked example (scripts/herd/experiment/fixtures/rubric-screening/) — two independent screener
# passes over the SAME five items, one emitted as CSV, one as JSON — and RENDERS the disagreement
# surface a human would review, then asserts the surface matches what the worked example promises.
#
# This is the "does the primitive actually surface disagreement?" demonstration: it drives the real
# merge script (no re-implementation), shows the agreement stats + the review pile, and fails loudly
# if the surface ever drifts from the expected 1 disagreement + 2 agree-unsure cells.
#
# Fully hermetic + read-only: writes only under a mktemp dir, touches no engine state, and — like the
# merge script it drives — never calls the clock or any random source. Ships DORMANT: nothing in the
# engine invokes it.  Run:  bash scripts/herd/sim/rubric-screen-sim.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
MERGE="$REPO/scripts/herd/experiment/rubric-screen-merge.sh"
FIX="$REPO/scripts/herd/experiment/fixtures/rubric-screening"

fail() { echo "SIM FAIL: $1" >&2; exit 1; }

[ -f "$MERGE" ] || fail "merge script not found at $MERGE"
[ -f "$FIX/screener-a.csv" ] || fail "fixture screener-a.csv missing"
[ -f "$FIX/screener-b.json" ] || fail "fixture screener-b.json missing"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "── rubric-screening sim ─────────────────────────────────────────────"
echo "rubric : $FIX/rubric.md  (criteria: scoped | testable | safe)"
echo "items  : 5 backlog items, screened twice (screener-a=CSV, screener-b=JSON)"
echo

bash "$MERGE" --a "$FIX/screener-a.csv" --b "$FIX/screener-b.json" \
  --out "$T/report.json" --surface-csv "$T/surface.csv" >/dev/null \
  || fail "merge exited non-zero over the worked example"

# Render the stats + the disagreement surface from the report the merge just wrote.
REPORT="$T/report.json" python3 - <<'PY' || fail "could not render / verify the report"
import os, sys, json

r = json.load(open(os.environ["REPORT"], encoding="utf-8"))
ag, cov, vd = r["agreement"], r["coverage"], r["verdict"]

print("agreement stats")
print("  compared cells : %d" % ag["compared_cells"])
print("  agree / disagree: %d / %d" % (ag["agreements"], ag["disagreements"]))
print("  agreement rate : %s" % ag["agreement_rate"])
print("  cohen kappa    : %s" % ag["cohen_kappa"])
print("  coverage gap   : %s (only_in_a=%d, only_in_b=%d)"
      % (vd["coverage_gap"], len(cov["only_in_a"]), len(cov["only_in_b"])))
print()

surface = r["review_surface"]
print("DISAGREEMENT SURFACE — %d cell(s) for human review" % len(surface))
print("  %-9s %-9s %-13s %-6s %-6s" % ("item", "criterion", "kind", "A", "B"))
print("  " + "-" * 52)
for s in surface:
    print("  %-9s %-9s %-13s %-6s %-6s"
          % (s["item_id"], s["criterion"], s["kind"], s["verdict_a"], s["verdict_b"]))
    print("      A: %s" % s["reason_a"])
    print("      B: %s" % s["reason_b"])

# ── assertions: the surface must match what the worked example promises ──
errs = []
def want(cond, msg):
    if not cond:
        errs.append(msg)

want(ag["compared_cells"] == 15, "expected 15 compared cells, got %d" % ag["compared_cells"])
want(vd["disagreement_count"] == 1, "expected 1 disagreement, got %d" % vd["disagreement_count"])
want(vd["unsure_agreement_count"] == 2,
     "expected 2 agree-unsure cells, got %d" % vd["unsure_agreement_count"])
want(vd["review_count"] == 3, "expected review_count 3, got %d" % vd["review_count"])
want(vd["needs_human_review"] is True, "expected needs_human_review True")
want(vd["clean_merge"] is False, "expected clean_merge False")
want(vd["coverage_gap"] is False, "expected no coverage gap")

# The one true disagreement is item-04 / safe (destructive-path reading vs routine-job reading).
dis = [s for s in surface if s["kind"] == "disagreement"]
want(len(dis) == 1 and dis[0]["item_id"] == "item-04" and dis[0]["criterion"] == "safe",
     "expected the sole disagreement to be item-04/safe, got %r" % dis)

if errs:
    for e in errs:
        sys.stderr.write("  ASSERT: " + e + "\n")
    sys.exit(1)
PY

echo
echo "surface CSV (opens in any spreadsheet for triage):"
sed 's/^/  /' "$T/surface.csv"
echo
echo "SIM PASS: disagreement surface rendered and verified (1 disagreement + 2 agree-unsure)."
