#!/usr/bin/env bash
# tests/lib/sandbox-posture-matrix-case.sh — shared assertion body for the per-posture
# sandbox-posture-matrix test family (HERD-477).
#
# HERD-477 splits the combined tests/test-sandbox-posture-matrix.sh (9 sequential
# scripts/herd/sim/sandbox-scenario.sh / sandbox-concurrency-scenario.sh invocations through
# scripts/herd/sim/sandbox-posture-matrix.sh, ~116s measured) into one THIN wrapper file per posture —
# tests/test-sandbox-posture-matrix-<posture>.sh — so each is its own test invocation and
# scripts/herd/suite-shard.sh's stable filename hash distributes them across the 4 CI shards, instead
# of one file paying for all 8 postures serially and riding the shared 120s per-test cap
# (scripts/ci/run-suite.sh HERD_CI_TEST_TIMEOUT default; see tests/known-env-sensitive.tsv's now-removed
# HERD-440 row, and #588 which added the yolo posture row that tipped it over on ubuntu too).
#
# This file is NOT itself a tests/test-*.sh file (no `test-` prefix) — invisible to the curated-suite
# glob/shard assignment (scripts/herd/suite-shard.sh globs test-*.sh only); only the wrapper files that
# source it are selected. tests/test-sandbox-posture-matrix-data.sh covers the postures.tsv DATA-SHAPE
# assertions once (no scenario execution, so no need to duplicate it in every posture file below).
#
# posture_matrix_case <posture> <budget_seconds>
#   Runs scripts/herd/sim/sandbox-posture-matrix.sh --posture <posture> and asserts:
#     (b) MATRIX GREEN — matrix.json is valid JSON, result=pass, postures_total=postures_green=1, and
#         the posture's own scorecard is result=pass, tagged posture=<posture>, with its invariant
#         checkpoint(s) passing (same invariants tests/test-sandbox-posture-matrix.sh asserted).
#     (c) FAULT CAUGHT — custom-steps only: the injected PR #249 defect
#         (SANDBOX_FORCE_STEPS_FAULT=1) comes back RED with exactly posture_invariant flipped.
#     (d) SOLO-AUTO BYTE-IDENTICAL — solo-auto only: matrix.json reports solo_auto_byte_identical=yes
#         (the wrapper's own internal comparison against a plain single-posture concurrency run).
#     (e) HERMETIC — the whole run leaves NO new entry in the real repo tree.
#     WALL-CLOCK HEADROOM — elapsed <= <budget_seconds>, comfortably under the shared 120s per-test CI
#         cap, so a future change that creeps this posture's runtime up fails LOUDLY here instead of
#         silently re-riding the cap (the exact defect class this split exists to prevent).
#   Exits the caller's process (via `fail`, defined below) on any assertion failure — this function
#   runs sourced into the caller's shell, not in a subshell.
#
# ONE TRANSIENT-HOST RETRY (main-red repro, 2026-08-02: full-auto came back fail(rc=1) on a real CI
# run, but was unreproducible after ~100 local re-runs — the fingerprint of a one-off host hiccup, not
# a deterministic defect). A first attempt is run in a SUBSHELL so a `fail()` there exits only the
# subshell, not the caller — a single scheduling/IO stall on a contended box can blow the wall-clock
# headroom budget, or even a tick budget inside the concurrency scenario, on an otherwise-correct run.
# Only on that first-attempt failure do we re-run the WHOLE case for real (no subshell — a second
# failure calls the top-level `fail` and exits the caller, exactly as before). This never masks a real
# regression: a deterministic defect fails identically on the retry. Mirrors the same "retry the
# transient, never the correctness check itself" doctrine already used by HERD-331's review_cap_gated
# direct-probe fallback in scripts/herd/sim/sandbox-concurrency-scenario.sh.
set -uo pipefail

_pmc_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_PMC_MATRIX="$_pmc_HERE/../scripts/herd/sim/sandbox-posture-matrix.sh"
_PMC_GATE="$_pmc_HERE/../scripts/herd/sim/sandbox-scenario.sh"
_PMC_POSTURES="$_pmc_HERE/../templates/postures.tsv"
_PMC_CAP_SECONDS=120   # scripts/ci/run-suite.sh HERD_CI_TEST_TIMEOUT default — the shared per-test cap

fail() { echo "FAIL: $1" >&2; exit 1; }

_pmc_sc()  { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
_pmc_scg() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }
_pmc_cp_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["checkpoints"]:
    if c["name"]==sys.argv[2]: print(c["status"]); break
' "$1" "$2"
}

posture_matrix_case() {
  local POSTURE="$1" BUDGET_SECONDS="$2"
  if ( _pmc_attempt "$POSTURE" "$BUDGET_SECONDS" ); then return 0; fi
  echo "RETRY (posture $POSTURE): first attempt failed — re-running once to rule out a transient host hiccup before failing for real" >&2
  _pmc_attempt "$POSTURE" "$BUDGET_SECONDS"
}

_pmc_attempt() {
  local POSTURE="$1" BUDGET_SECONDS="$2"

  command -v git     >/dev/null 2>&1 || fail "git required"
  command -v python3 >/dev/null 2>&1 || fail "python3 required"
  for f in "$_PMC_MATRIX" "$_PMC_GATE" "$_PMC_POSTURES"; do [ -f "$f" ] || fail "missing $f"; done

  local REPO_ROOT T BASELINE_STATUS ART t0 t1 elapsed rc card MJ
  REPO_ROOT="$(cd "$_pmc_HERE/.." && pwd)"
  BASELINE_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"

  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

  # ── MATRIX GREEN for this one posture ──────────────────────────────────────────
  ART="$T/matrix"
  t0=$(date +%s)
  SANDBOX_NO_SCREENSHOT=1 SANDBOX_REVIEW_DELAY=1 POSTURES_FILE="$_PMC_POSTURES" \
    bash "$_PMC_MATRIX" --posture "$POSTURE" --artifacts "$ART" >"$T/matrix.out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "matrix exited non-zero for posture $POSTURE"$'\n'"$(cat "$T/matrix.out")"

  MJ="$ART/matrix.json"
  [ -f "$MJ" ] || fail "matrix.json not emitted for posture $POSTURE"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MJ" || fail "matrix.json is not valid JSON"
  [ "$(_pmc_sc "$MJ" result)" = "pass" ]      || fail "matrix result should be pass for posture $POSTURE"
  [ "$(_pmc_sc "$MJ" postures_total)" -eq 1 ] || fail "postures_total should be 1 for a single-posture run"
  [ "$(_pmc_sc "$MJ" postures_green)" -eq 1 ] || fail "postures_green should be 1 for posture $POSTURE"

  card="$ART/$POSTURE/scorecard.json"
  [ -f "$card" ]                              || fail "no scorecard for posture $POSTURE"
  [ "$(_pmc_sc "$card" result)" = "pass" ]     || fail "posture $POSTURE result should be pass"
  [ "$(_pmc_scg "$card" posture)" = "$POSTURE" ] || fail "posture $POSTURE scorecard not tagged with posture=$POSTURE"

  case "$POSTURE" in
    solo-auto|full-auto|docs-lab|yolo)
      [ "$(_pmc_cp_status "$card" queue_drained)" = "pass" ] \
        || fail "$POSTURE must fully drain (queue_drained pass)"
      ;;
    team-approve)
      [ "$(_pmc_cp_status "$card" posture_approve_no_merge_preapproval)" = "pass" ] \
        || fail "team-approve must not merge before an approval"
      [ "$(_pmc_cp_status "$card" posture_approve_merges_only_approved)" = "pass" ] \
        || fail "team-approve must merge only the approved PR"
      ;;
    observe-only)
      [ "$(_pmc_cp_status "$card" posture_observe_never_merges)" = "pass" ] \
        || fail "observe-only must never merge"
      [ "$(_pmc_sc "$card" merges)" -eq 0 ] || fail "observe-only merges must be 0"
      ;;
    gated-push|custom-steps)
      [ "$(_pmc_cp_status "$card" posture_invariant)" = "pass" ] \
        || fail "$POSTURE posture_invariant must pass"
      ;;
    *) fail "posture_matrix_case: no invariant mapping for posture $POSTURE" ;;
  esac
  echo "PASS (b) matrix green for posture=$POSTURE — scorecard pass + invariant checkpoint(s)"

  # ── (c) FAULT CAUGHT — custom-steps only ───────────────────────────────────────
  if [ "$POSTURE" = custom-steps ]; then
    [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fault_injection"]["caught"])' "$MJ")" = "yes" ] \
      || fail "(c) matrix.json must report the fault as caught"
    local FART frc FC _flipped
    FART="$T/fault"
    frc=0
    SANDBOX_NO_SCREENSHOT=1 SANDBOX_REVIEW_DELAY=1 SANDBOX_FORCE_STEPS_FAULT=1 POSTURES_FILE="$_PMC_POSTURES" \
      bash "$_PMC_GATE" --posture custom-steps --artifacts "$FART" >"$T/fault.out" 2>&1 || frc=$?
    [ "$frc" -ne 0 ] || fail "(c) forced-fault run must exit non-zero"
    FC="$FART/scorecard.json"
    [ -f "$FC" ] || fail "(c) fault scorecard not emitted"
    [ "$(_pmc_sc "$FC" result)" = "fail" ] || fail "(c) forced fault must yield result=fail"
    [ "$(_pmc_sc "$FC" failed)" -eq 1 ]    || fail "(c) forced fault must flip exactly 1 checkpoint (got $(_pmc_sc "$FC" failed))"
    _flipped="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(c["name"] for c in d["checkpoints"] if c["status"]=="fail"))' "$FC")"
    [ "$_flipped" = "posture_invariant" ] || fail "(c) the flipped checkpoint must be posture_invariant (got: $_flipped)"
    echo "PASS (c) injected PR #249 defect caught RED — exactly posture_invariant flipped"
  fi

  # ── (d) SOLO-AUTO BYTE-IDENTICAL — solo-auto only ──────────────────────────────
  if [ "$POSTURE" = solo-auto ]; then
    [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["solo_auto_byte_identical"])' "$MJ")" = "yes" ] \
      || fail "(d) matrix.json must report solo-auto byte-identical"
    echo "PASS (d) solo-auto byte-identical to a plain single-posture concurrency run"
  fi

  t1=$(date +%s)
  elapsed=$((t1 - t0))

  # ── (e) HERMETIC — nothing leaked into the real repo tree ──────────────────────
  local NOW_STATUS NEW_ENTRIES
  NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
  NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
  [ -z "$NEW_ENTRIES" ] || fail "(e) posture $POSTURE leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
  echo "PASS (e) hermetic — no leak into the real repo"

  # ── WALL-CLOCK HEADROOM — fail loudly long before this posture could threaten the shared cap ──
  [ "$elapsed" -le "$BUDGET_SECONDS" ] \
    || fail "posture $POSTURE took ${elapsed}s — over its ${BUDGET_SECONDS}s headroom budget (shared CI per-test cap is ${_PMC_CAP_SECONDS}s); investigate before this creeps back toward the cap the way HERD-440/#588 did"
  echo "PASS wall-clock headroom: ${elapsed}s <= ${BUDGET_SECONDS}s budget (shared cap ${_PMC_CAP_SECONDS}s)"

  rm -rf "$T"; trap - EXIT
  echo "ALL PASS ($POSTURE)"
}
