#!/usr/bin/env bash
# test-sandbox-concurrency.sh — hermetic proof of the P1 sandbox CONCURRENCY simulation
# (scripts/herd/sim/sandbox-concurrency-scenario.sh), which drives the REAL watcher gate loop
# (agent-watch.sh, sourced in lib mode) against N>=3 simultaneous stub-builder PRs.
#
# Asserts:
#   (a) END-TO-END DRAIN — the scenario exits 0 and every checkpoint passes; a machine-readable
#       scorecard.json is emitted in the P0 shape PLUS the concurrency fields.
#   (b) REVIEW_CONCURRENCY — the observed peak of simultaneous in-flight reviews never exceeds the
#       configured cap, and the cap ACTIVELY gated (>= 1 PR was QUEUED). Re-checked at cap=3.
#   (c) HEALTH_CONCURRENCY=1 — healthchecks never interleaved (max concurrent == 1) and every PR's
#       suite ran; the planted-holder probe recorded a QUEUED (health_mutex_queues passed).
#   (d) NO DOUBLE-MERGE / NO SKIPPED PR / QUEUE DRAINS — merges == prs, double_merges == 0,
#       skipped_prs == 0, queue_drained == true.
#   (e) ARTIFACTS — pane text was captured THROUGH the driver read-pane surface (pane-*.txt exist,
#       non-empty), and the macOS screenshot step DEGRADED GRACEFULLY (its checkpoints are `skip`,
#       never `fail`) under the hermetic opt-out — the no-false-red rule.
#   (f) HERMETIC — the run leaves NO artifacts in the real repo tree and touches no real gh/panes.
#
# Fully hermetic: local git only, NO herdr, NO network, NO model, NO screenshots (opt-out). Mirrors
# the conventions of tests/test-sandbox-sim.sh and tests/test-parallel-review.sh.
# Run:  bash tests/test-sandbox-concurrency.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-concurrency-scenario.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCENARIO" ] || fail "missing $SCENARIO"

# Baseline of the real repo's working-tree status BEFORE any scenario runs, so check (f) can prove
# the scenario adds NOTHING of its own (the sim's own not-yet-committed files are already here).
REPO_ROOT="$(cd "$HERE/.." && pwd)"
BASELINE_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"

# jq-free scorecard field reader: sc <file> <top-level-key>
sc() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
# checkpoint status reader: cp_status <file> <checkpoint-name>  (empty if absent)
cp_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["checkpoints"]:
    if c["name"]==sys.argv[2]: print(c["status"]); break
' "$1" "$2"
}
# count checkpoints whose name matches a prefix and whose status equals a value
cp_count_prefix_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
pfx,st=sys.argv[2],sys.argv[3]
print(sum(1 for c in d["checkpoints"] if c["name"].startswith(pfx) and c["status"]==st))
' "$1" "$2" "$3"
}

# ── (a) END-TO-END DRAIN + SCORECARD SHAPE (default N=3, cap=2) ──────────────────
ART="$T/run-default"
SANDBOX_NO_SCREENSHOT=1 SANDBOX_REVIEW_DELAY=1 \
  bash "$SCENARIO" --artifacts "$ART" >"$T/default.out" 2>&1 \
  || fail "(a) concurrency scenario exited non-zero"$'\n'"$(cat "$T/default.out")"

SCARD="$ART/scorecard.json"
[ -f "$SCARD" ] || fail "(a) scorecard.json not emitted at $SCARD"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCARD" || fail "(a) scorecard.json is not valid JSON"

[ "$(sc "$SCARD" scenario)" = "stub-concurrency-drain" ] || fail "(a) unexpected scenario name"
[ "$(sc "$SCARD" result)" = "pass" ]                     || fail "(a) result should be pass"
[ "$(sc "$SCARD" failed)" -eq 0 ]                        || fail "(a) failed should be 0 (got $(sc "$SCARD" failed))"
[ "$(sc "$SCARD" passed)" -ge 1 ]                        || fail "(a) passed should be >= 1"
# Concurrency fields present with sane values.
for k in prs review_concurrency health_concurrency peak_reviews_in_flight reviews_queued \
         health_runs max_health_in_flight merges double_merges skipped_prs queue_drained \
         ticks pane_captures screenshots; do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert sys.argv[2] in d' "$SCARD" "$k" \
    || fail "(a) scorecard missing concurrency field: $k"
done
echo "PASS (a) end-to-end drain + scorecard shape"

# ── (b) REVIEW_CONCURRENCY respected + actively gated ────────────────────────────
NPRS="$(sc "$SCARD" prs)"; RC="$(sc "$SCARD" review_concurrency)"
PEAK="$(sc "$SCARD" peak_reviews_in_flight)"; QD="$(sc "$SCARD" reviews_queued)"
[ "$NPRS" -eq 3 ]                 || fail "(b) default prs should be 3 (got $NPRS)"
[ "$PEAK" -le "$RC" ]             || fail "(b) peak reviews $PEAK exceeded cap $RC"
[ "$PEAK" -ge 1 ]                 || fail "(b) peak reviews should be >= 1"
[ "$QD" -ge 1 ]                   || fail "(b) at least one PR must have QUEUED (cap must actively gate)"
[ "$(cp_status "$SCARD" review_concurrency_respected)" = "pass" ] || fail "(b) review_concurrency_respected not pass"
[ "$(cp_status "$SCARD" review_cap_gated)" = "pass" ]            || fail "(b) review_cap_gated not pass"
echo "PASS (b) REVIEW_CONCURRENCY respected (peak=$PEAK <= $RC, queued=$QD)"

# ── (c) HEALTH_CONCURRENCY=1 serializes — no interleaving + mutex QUEUEs ─────────
[ "$(sc "$SCARD" health_concurrency)" -eq 1 ]      || fail "(c) health_concurrency should be 1"
[ "$(sc "$SCARD" max_health_in_flight)" -eq 1 ]    || fail "(c) max_health_in_flight must be 1 (no interleaving)"
[ "$(sc "$SCARD" health_runs)" -eq "$NPRS" ]       || fail "(c) each PR's healthcheck should run once ($NPRS)"
[ "$(cp_status "$SCARD" health_serialized)" = "pass" ]   || fail "(c) health_serialized not pass"
[ "$(cp_status "$SCARD" health_mutex_queues)" = "pass" ] || fail "(c) health_mutex_queues not pass"
echo "PASS (c) HEALTH_CONCURRENCY=1 serializes (runs=$NPRS, max concurrent=1)"

# ── (d) no double-merge / no skipped PR / queue drains ───────────────────────────
[ "$(sc "$SCARD" merges)" -eq "$NPRS" ]        || fail "(d) merges should equal prs ($NPRS)"
[ "$(sc "$SCARD" double_merges)" -eq 0 ]       || fail "(d) double_merges must be 0"
[ "$(sc "$SCARD" skipped_prs)" -eq 0 ]         || fail "(d) skipped_prs must be 0"
[ "$(sc "$SCARD" queue_drained)" = "True" ]    || fail "(d) queue_drained must be true (got $(sc "$SCARD" queue_drained))"
[ "$(cp_status "$SCARD" no_double_merge)" = "pass" ] || fail "(d) no_double_merge not pass"
[ "$(cp_status "$SCARD" no_skipped_pr)" = "pass" ]   || fail "(d) no_skipped_pr not pass"
[ "$(cp_status "$SCARD" queue_drained)" = "pass" ]   || fail "(d) queue_drained checkpoint not pass"
echo "PASS (d) no double-merge, no skipped PR, queue drained"

# ── (e) ARTIFACTS: pane text captured via driver read-pane; screenshots degrade gracefully ──────
[ "$(sc "$SCARD" pane_captures)" -ge 1 ] || fail "(e) no pane text captured via driver read-pane"
shopt -s nullglob
_panes=( "$ART"/pane-*.txt )
[ "${#_panes[@]}" -ge 1 ] || fail "(e) no pane-*.txt artifacts on disk"
for p in "${_panes[@]}"; do [ -s "$p" ] || fail "(e) empty pane artifact: $p"; done
# The console frame carries the REAL watcher's 🩺 health-check rows painted by _healthcheck_gate.
grep -q 'health-check' "$ART/pane-tick1-cap-bites.txt" || fail "(e) tick1 pane text lacks the watcher health-check rows"
# Screenshots: opt-out ⇒ every screenshot checkpoint is `skip`, and NONE is `fail` (no-false-red).
[ "$(cp_count_prefix_status "$SCARD" screenshot_ skip)" -ge 1 ] || fail "(e) expected skipped screenshot checkpoints under opt-out"
[ "$(cp_count_prefix_status "$SCARD" screenshot_ fail)" -eq 0 ] || fail "(e) a screenshot step FAILED — must degrade gracefully, never fail"
[ "$(sc "$SCARD" screenshots)" -eq 0 ] || fail "(e) screenshots should be 0 under the opt-out"
echo "PASS (e) pane text captured via driver read-pane; screenshots degraded gracefully"

# ── (h) WATCHER FLAIR PACK (HERD-147) — OFF byte-identical, ON adds the pasture header, dead LOUD ──
# The scenario drives the REAL flair helpers through the flair-aware console_frame. Lock in that all
# four flair invariants passed: off is byte-identical to a no-flag run, on renders the pasture header,
# the 💀 dead row is byte-identical in both modes (never softened), and a pending merge celebrates.
[ "$(sc "$SCARD" flair_tested)" = "True" ]                             || fail "(h) flair_tested flag not set"
[ "$(cp_status "$SCARD" flair_off_byte_identical)" = "pass" ]          || fail "(h) flair_off_byte_identical not pass"
[ "$(cp_status "$SCARD" flair_on_header_present)" = "pass" ]           || fail "(h) flair_on_header_present not pass"
[ "$(cp_status "$SCARD" flair_dead_row_unchanged)" = "pass" ]          || fail "(h) flair_dead_row_unchanged not pass (a red/dead row must never be softened)"
[ "$(cp_status "$SCARD" flair_merge_celebration)" = "pass" ]           || fail "(h) flair_merge_celebration not pass"
echo "PASS (h) flair pack: off byte-identical, on adds pasture header, dead rows unchanged, merge celebrated"

# ── (i) WATCHER SINGLETON spawn-lock (HERD-209) — reproduce the duplicate-watcher race ──────────
# The scenario drives the SHIPPED _acquire_watcher_singleton against a live and a stale lock. Lock in
# that a second launch under a LIVE lock REFUSED (no duplicate) and a STALE lock was ADOPTED.
[ "$(sc "$SCARD" watcher_singleton_tested)" = "True" ]                    || fail "(i) watcher_singleton_tested flag not set"
[ "$(sc "$SCARD" watcher_singleton_ok)" = "True" ]                        || fail "(i) watcher_singleton_ok should be true"
[ "$(cp_status "$SCARD" watcher_singleton_refuses_live)" = "pass" ]       || fail "(i) watcher_singleton_refuses_live not pass (a second live-lock launch must refuse)"
[ "$(cp_status "$SCARD" watcher_singleton_adopts_stale)" = "pass" ]       || fail "(i) watcher_singleton_adopts_stale not pass (a stale lock must be adopted)"
echo "PASS (i) watcher singleton: live lock → refuse (no duplicate), stale lock → adopt"

# ── (f) HERMETIC — nothing leaked into the real repo tree ────────────────────────
# The scenario writes only under its --artifacts dir. Compare against the baseline captured before
# any run: no NEW working-tree entry may appear because of the scenario.
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "(f) scenario leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (f) hermetic — no leak into the real repo"

# ── (g) PARAMETERIZED: a higher cap raises the observed peak (cap=3, N=4) ────────
ART2="$T/run-cap3"
SANDBOX_NO_SCREENSHOT=1 SANDBOX_REVIEW_DELAY=1 REVIEW_CONCURRENCY=3 \
  bash "$SCENARIO" --artifacts "$ART2" -n 4 >"$T/cap3.out" 2>&1 \
  || fail "(g) cap=3 scenario exited non-zero"$'\n'"$(cat "$T/cap3.out")"
SC2="$ART2/scorecard.json"
[ "$(sc "$SC2" result)" = "pass" ]              || fail "(g) cap=3 result should be pass"
[ "$(sc "$SC2" prs)" -eq 4 ]                    || fail "(g) cap=3 run should open 4 PRs"
[ "$(sc "$SC2" review_concurrency)" -eq 3 ]     || fail "(g) cap should be 3"
[ "$(sc "$SC2" peak_reviews_in_flight)" -le 3 ] || fail "(g) peak must not exceed cap=3"
[ "$(sc "$SC2" peak_reviews_in_flight)" -ge 2 ] || fail "(g) a cap of 3 with 4 PRs should overlap >= 2 reviews"
[ "$(sc "$SC2" max_health_in_flight)" -eq 1 ]   || fail "(g) health must still serialize at cap=3"
[ "$(sc "$SC2" double_merges)" -eq 0 ]          || fail "(g) cap=3 must not double-merge"
[ "$(sc "$SC2" queue_drained)" = "True" ]       || fail "(g) cap=3 queue must drain"
echo "PASS (g) parameterized cap=3 (peak=$(sc "$SC2" peak_reviews_in_flight))"

echo "ALL PASS"
