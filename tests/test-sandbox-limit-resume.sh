#!/usr/bin/env bash
# test-sandbox-limit-resume.sh — hermetic proof of the P2a LIMIT-PARK / AUTO-RESUME e2e simulation
# (scripts/herd/sim/sandbox-limit-resume-scenario.sh), which drives the REAL watcher limit path
# (agent-watch.sh, sourced in lib mode): detect the park via the hook sentinel → schedule the resume
# honoring HERD_LIMIT_RESUME_BUFFER → relaunch via `claude --continue` (a stub shim) → complete.
#
# Asserts:
#   (a) END-TO-END + SCORECARD SHAPE — the scenario exits 0, every checkpoint passes, and a
#       machine-readable scorecard.json is emitted in the sandbox-sim shape PLUS the limit fields.
#   (b) THE FIVE MOAT CHECKPOINTS — detect, park, scheduled, resume, complete all pass; the resume
#       actually relaunched `claude --continue` exactly once and the parked task completed.
#   (c) BUFFER HONORED — resume_target == reset_epoch + resume_buffer, at a NON-default buffer.
#   (d) NEGATIVE PATH — HERD_LIMIT_DETECT=off yields NO park (the negative_no_park checkpoint passes).
#   (e) ARTIFACTS — pane text captured THROUGH the driver read-pane surface (pane-*.txt exist,
#       non-empty, carry the watcher's limit-hit row); screenshots DEGRADE GRACEFULLY under the
#       opt-out (their checkpoints are `skip`, never `fail`) — the no-false-red rule.
#   (f) HERMETIC — the run leaves NO new entry in the real repo tree and touches no real gh/panes.
#
# Fully hermetic: local git only, NO herdr, NO network, NO model, NO screenshots (opt-out). Mirrors
# the conventions of tests/test-sandbox-sim.sh and tests/test-sandbox-concurrency.sh.
# Run:  bash tests/test-sandbox-limit-resume.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-limit-resume-scenario.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCENARIO" ] || fail "missing $SCENARIO"

# Baseline of the real repo's working-tree status BEFORE any scenario runs, so check (f) can prove
# the scenario adds NOTHING of its own to the real tree.
REPO_ROOT="$(cd "$HERE/.." && pwd)"
BASELINE_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"

# jq-free scorecard readers.
sc() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
cp_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["checkpoints"]:
    if c["name"]==sys.argv[2]: print(c["status"]); break
' "$1" "$2"
}
cp_count_prefix_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
pfx,st=sys.argv[2],sys.argv[3]
print(sum(1 for c in d["checkpoints"] if c["name"].startswith(pfx) and c["status"]==st))
' "$1" "$2" "$3"
}

# ── (a) END-TO-END + SCORECARD SHAPE (non-default buffer to prove the knob) ──────
ART="$T/run"
SANDBOX_NO_SCREENSHOT=1 HERD_LIMIT_RESUME_BUFFER=120 \
  bash "$SCENARIO" --artifacts "$ART" >"$T/run.out" 2>&1 \
  || fail "(a) limit-resume scenario exited non-zero"$'\n'"$(cat "$T/run.out")"

SCARD="$ART/scorecard.json"
[ -f "$SCARD" ] || fail "(a) scorecard.json not emitted at $SCARD"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCARD" || fail "(a) scorecard.json is not valid JSON"

[ "$(sc "$SCARD" scenario)" = "stub-limit-resume-e2e" ] || fail "(a) unexpected scenario name"
[ "$(sc "$SCARD" result)" = "pass" ]                    || fail "(a) result should be pass"
[ "$(sc "$SCARD" failed)" -eq 0 ]                       || fail "(a) failed should be 0 (got $(sc "$SCARD" failed))"
[ "$(sc "$SCARD" passed)" -ge 1 ]                       || fail "(a) passed should be >= 1"
# Sandbox-sim shape + limit fields present.
for k in scenario artifacts_dir repo_dir fixture_sha result passed failed skipped \
         reset_epoch resume_buffer resume_target claude_relaunches task_completed \
         pane_captures screenshots checkpoints; do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert sys.argv[2] in d' "$SCARD" "$k" \
    || fail "(a) scorecard missing field: $k"
done
echo "PASS (a) end-to-end + scorecard shape"

# ── (b) THE FIVE MOAT CHECKPOINTS + a single real relaunch + completion ──────────
for cpn in detect park scheduled resume complete; do
  [ "$(cp_status "$SCARD" "$cpn")" = "pass" ] || fail "(b) checkpoint $cpn not pass"
done
[ "$(sc "$SCARD" claude_relaunches)" -eq 1 ] || fail "(b) claude should relaunch exactly once (got $(sc "$SCARD" claude_relaunches))"
[ "$(sc "$SCARD" task_completed)" = "True" ] || fail "(b) task_completed must be true"
echo "PASS (b) detect → park → scheduled → resume → complete (1 relaunch)"

# ── (c) BUFFER HONORED — target == reset + buffer, at the non-default buffer ──────
RESET="$(sc "$SCARD" reset_epoch)"; BUF="$(sc "$SCARD" resume_buffer)"; TGT="$(sc "$SCARD" resume_target)"
[ "$BUF" -eq 120 ]                 || fail "(c) resume_buffer should be the non-default 120 (got $BUF)"
[ "$TGT" -eq "$((RESET + BUF))" ]  || fail "(c) resume_target $TGT != reset $RESET + buffer $BUF"
echo "PASS (c) HERD_LIMIT_RESUME_BUFFER honored (target $TGT == $RESET + $BUF)"

# ── (d) NEGATIVE PATH — kill-switch means no park ────────────────────────────────
[ "$(cp_status "$SCARD" negative_no_park)" = "pass" ] || fail "(d) negative_no_park not pass"
echo "PASS (d) HERD_LIMIT_DETECT=off yields no park"

# ── (e) ARTIFACTS: pane text via driver read-pane; screenshots degrade gracefully ─
[ "$(sc "$SCARD" pane_captures)" -ge 1 ] || fail "(e) no pane text captured via driver read-pane"
shopt -s nullglob
_panes=( "$ART"/pane-*.txt )
[ "${#_panes[@]}" -ge 1 ] || fail "(e) no pane-*.txt artifacts on disk"
for p in "${_panes[@]}"; do [ -s "$p" ] || fail "(e) empty pane artifact: $p"; done
# The captured console frame carries the REAL watcher's limit-hit row (not a re-render).
grep -q 'limit-hit' "$ART/pane-parked.txt" || fail "(e) parked pane text lacks the watcher limit-hit row"
[ "$(cp_count_prefix_status "$SCARD" screenshot_ skip)" -ge 1 ] || fail "(e) expected skipped screenshot checkpoints under opt-out"
[ "$(cp_count_prefix_status "$SCARD" screenshot_ fail)" -eq 0 ] || fail "(e) a screenshot step FAILED — must degrade gracefully, never fail"
[ "$(sc "$SCARD" screenshots)" -eq 0 ] || fail "(e) screenshots should be 0 under the opt-out"
echo "PASS (e) pane text captured via driver read-pane; screenshots degraded gracefully"

# ── (f) HERMETIC — nothing leaked into the real repo tree ────────────────────────
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "(f) scenario leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (f) hermetic — no leak into the real repo"

# ── (g) DETERMINISM — a second run reproduces the same fixture + moat outcome ─────
ART2="$T/run2"
SANDBOX_NO_SCREENSHOT=1 HERD_LIMIT_RESUME_BUFFER=120 \
  bash "$SCENARIO" --artifacts "$ART2" >"$T/run2.out" 2>&1 \
  || fail "(g) second run exited non-zero"$'\n'"$(cat "$T/run2.out")"
SC2="$ART2/scorecard.json"
[ "$(sc "$SCARD" fixture_sha)" = "$(sc "$SC2" fixture_sha)" ] || fail "(g) fixture sha differs between runs"
[ "$(sc "$SC2" result)" = "pass" ]                           || fail "(g) second run result should be pass"
[ "$(sc "$SCARD" resume_target)" = "$(sc "$SC2" resume_target)" ] || fail "(g) resume_target not reproducible"
echo "PASS (g) deterministic across runs"

echo "ALL PASS"
