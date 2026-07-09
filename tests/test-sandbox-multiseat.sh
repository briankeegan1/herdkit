#!/usr/bin/env bash
# test-sandbox-multiseat.sh — hermetic proof of the HERD-236 multi-seat + starvation simulation
# (scripts/herd/sim/sandbox-multiseat-scenario.sh), which drives TWO REAL watcher gate loops
# (agent-watch.sh, sourced in lib mode) against one shared stub remote + N stub-builder PRs.
#
# Asserts:
#   (a) END-TO-END DRAIN — the scenario exits 0; scorecard result=pass, failed=0.
#   (b) SCORECARD SHAPE — multi-seat fields present with sane values.
#   (c) duplicate_gate_runs=0, duplicate_hold_comments=0, resolver_double_dispatch=0.
#   (d) max_restale_cycles bounded (≤ restale_threshold) under MERGE_FAIRNESS=on.
#   (e) all-PRs-drained — merges == prs, double_merges == 0, queue_drained == true.
#   (f) HERMETIC — the run leaves NO artifacts in the real repo tree.
#
# Fully hermetic: local git only, NO herdr, NO network, NO model.
# Run:  bash tests/test-sandbox-multiseat.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-multiseat-scenario.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCENARIO" ] || fail "missing $SCENARIO"
[ -x "$SCENARIO" ] || fail "scenario not executable: $SCENARIO"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
BASELINE_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"

sc() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
cp_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["checkpoints"]:
    if c["name"]==sys.argv[2]: print(c["status"]); break
' "$1" "$2"
}

# ── (a) END-TO-END DRAIN + SCORECARD SHAPE ────────────────────────────────────
ART="$T/run-default"
SANDBOX_NO_SCREENSHOT=1 SANDBOX_REVIEW_DELAY=0 \
  bash "$SCENARIO" --artifacts "$ART" -n 4 >"$T/default.out" 2>&1 \
  || fail "(a) multiseat scenario exited non-zero"$'\n'"$(cat "$T/default.out")"

SCARD="$ART/scorecard.json"
[ -f "$SCARD" ] || fail "(a) scorecard.json not emitted at $SCARD"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCARD" || fail "(a) scorecard.json is not valid JSON"

[ "$(sc "$SCARD" scenario)" = "stub-multiseat-drain" ] || fail "(a) unexpected scenario name"
[ "$(sc "$SCARD" result)" = "pass" ]                   || fail "(a) result should be pass (got $(sc "$SCARD" result))"
[ "$(sc "$SCARD" failed)" -eq 0 ]                      || fail "(a) failed should be 0 (got $(sc "$SCARD" failed))"
[ "$(sc "$SCARD" passed)" -ge 1 ]                      || fail "(a) passed should be >= 1"
[ "$(sc "$SCARD" seats)" -eq 2 ]                       || fail "(a) seats should be 2"

for k in prs ticks merges double_merges duplicate_gate_runs duplicate_hold_comments \
         resolver_double_dispatch max_restale_cycles restale_threshold queue_drained \
         blessings_posted merge_fairness; do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert sys.argv[2] in d' "$SCARD" "$k" \
    || fail "(a) scorecard missing multi-seat field: $k"
done
echo "PASS (a) end-to-end drain + scorecard shape"

# ── (b) multi-seat invariants ─────────────────────────────────────────────────
[ "$(sc "$SCARD" duplicate_gate_runs)" -eq 0 ]       || fail "(b) duplicate_gate_runs must be 0"
[ "$(sc "$SCARD" duplicate_hold_comments)" -eq 0 ]   || fail "(b) duplicate_hold_comments must be 0"
[ "$(sc "$SCARD" resolver_double_dispatch)" -eq 0 ]  || fail "(b) resolver_double_dispatch must be 0"
[ "$(cp_status "$SCARD" duplicate_gate_runs)" = "pass" ]      || fail "(b) duplicate_gate_runs checkpoint not pass"
[ "$(cp_status "$SCARD" duplicate_hold_comments)" = "pass" ]  || fail "(b) duplicate_hold_comments checkpoint not pass"
[ "$(cp_status "$SCARD" resolver_double_dispatch)" = "pass" ] || fail "(b) resolver_double_dispatch checkpoint not pass"
echo "PASS (b) duplicate_gate_runs=0, duplicate_hold_comments=0, resolver_double_dispatch=0"

# ── (c) max_restale_cycles bounded ────────────────────────────────────────────
MAX_R="$(sc "$SCARD" max_restale_cycles)"
THRESH="$(sc "$SCARD" restale_threshold)"
[ "$MAX_R" -le "$THRESH" ] || fail "(c) max_restale_cycles $MAX_R exceeded threshold $THRESH"
[ "$(cp_status "$SCARD" max_restale_cycles_bounded)" = "pass" ] || fail "(c) max_restale_cycles_bounded not pass"
echo "PASS (c) max_restale_cycles bounded ($MAX_R <= $THRESH)"

# ── (d) all-PRs-drained ───────────────────────────────────────────────────────
NPRS="$(sc "$SCARD" prs)"
[ "$(sc "$SCARD" merges)" -eq "$NPRS" ]      || fail "(d) merges should equal prs ($NPRS)"
[ "$(sc "$SCARD" double_merges)" -eq 0 ]     || fail "(d) double_merges must be 0"
[ "$(sc "$SCARD" queue_drained)" = "True" ]  || fail "(d) queue_drained must be true (got $(sc "$SCARD" queue_drained))"
[ "$(cp_status "$SCARD" all_prs_drained)" = "pass" ] || fail "(d) all_prs_drained checkpoint not pass"
[ "$(cp_status "$SCARD" no_double_merge)" = "pass" ] || fail "(d) no_double_merge checkpoint not pass"
echo "PASS (d) all $NPRS PRs drained, 0 double-merges"

# ── (e) two seat dirs + shared remote artifacts exist ─────────────────────────
[ -d "$ART/seat-a/trees" ] || fail "(e) missing seat-a TREES"
[ -d "$ART/seat-b/trees" ] || fail "(e) missing seat-b TREES"
[ -f "$ART/shared/merges.log" ] || fail "(e) missing shared merges log"
[ -f "$ART/shared/statuses.log" ] || fail "(e) missing shared statuses log"
[ "$(sc "$SCARD" blessings_posted)" -ge "$NPRS" ] || fail "(e) blessings_posted < prs"
echo "PASS (e) two TREES dirs + shared remote + blessings present"

# ── (f) HERMETIC — nothing leaked into the real repo tree ─────────────────────
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "(f) scenario leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (f) hermetic — no leak into the real repo tree"

echo "ALL PASS — test-sandbox-multiseat.sh"
