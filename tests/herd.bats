#!/usr/bin/env bats
# herd.bats — bats smoke tests for the herdkit engine + CLI. Run:  bats tests/herd.bats
# (When bats isn't installed, the hermetic tests/test-*.sh cover the same ground and the dogfood
# healthcheck / scripts/ci/run-suite.sh run those directly.)
#
# ── HERD-295: DYNAMIC test discovery ─────────────────────────────────────────────────────────────
# This file no longer carries one hand-written @test block per tests/test-*.sh. That made it the #1
# stale-base collision point — every new hermetic test edited it, and six PRs touching it in one day
# starved the resolver. Instead, the block near the bottom GLOBS tests/test-*.sh and registers each
# as its own reported bats test, so ADDING a test file never edits herd.bats again. Two escape hatches
# (both honored by scripts/herd/gate-coverage-lint.sh and scripts/ci/run-suite.sh):
#   • tests/gate-coverage-exempt.tsv — files deliberately NOT run in the gate (flaky / live-env).
#   • HERD_DISCOVERY_BESPOKE below   — files kept as a hand-written @test block because they do MORE
#     than a plain shellout; discovery skips them so they are never double-run.
# Every hand-written block that remains does something a plain `run bash <test>.sh; ALL PASS` cannot:
# an inline structural assertion, a SKIP-tolerant optional-dep check, a sim, or a description another
# gate keys on (the codemap test — .herd/healthcheck.project.sh's env-vs-code classifier matches its
# exact description "hermetic project-mode codemap test passes").

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# ── inline structural blocks (no single tests/test-*.sh to shell out to) ─────────────────────────
@test "all engine + CLI scripts are bash -n clean" {
  for f in "$REPO"/scripts/herd/*.sh "$REPO"/scripts/herd/backends/*.sh "$REPO"/bin/herd; do
    run bash -n "$f"
    [ "$status" -eq 0 ] || { echo "syntax error in $f"; return 1; }
  done
}

@test "no single-consumer literal leaked into the generic engine" {
  run grep -rilE 'northstar|app/dashboard\.py|streamlit' "$REPO/scripts/herd"
  [ "$status" -ne 0 ]
}

@test "herd render produces no leftover template tokens for this repo" {
  run bash "$REPO/bin/herd" render
  [ "$status" -eq 0 ]
  run grep -q '{{' "$REPO/.claude/commands/coordinator.md"
  [ "$status" -ne 0 ]
}

# ── bespoke shellout blocks kept out of discovery (they do MORE than a plain shellout) ───────────
# glow is an OPTIONAL dep — a clean SKIP is a pass here, never a red row; discovery's uniform PASS
# marker would red a SKIP-only run, so this stays hand-written.
@test "backlog-view rendered frame fits its render width (HERD-288)" {
  run bash "$REPO/tests/test-backlog-view-width.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* || "$output" == *"SKIP"* ]]
}

# .herd/healthcheck.project.sh's ENV-vs-CODE bats classifier (_HK_ENV_TEST, HERD-187) matches this
# test's EXACT description to tolerate the one known real-repo/ENGINE env failure. Keep it verbatim.
@test "hermetic project-mode codemap test passes" {
  run bash "$REPO/tests/test-codemap-project.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ── sim blocks (run scripts/herd/sim/*.sh — not tests/test-*.sh, so discovery never sees them) ───
@test "hermetic rubric-screening disagreement-surface sim (HERD-166) passes" {
  run bash "$REPO/scripts/herd/sim/rubric-screen-sim.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SIM PASS"* ]]
}

@test "builder-chaos sim: a builder killed at every lifecycle stage leaves no corpse (HERD-162)" {
  run bash "$REPO/scripts/herd/sim/builder-chaos-sim.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "retirement-invariant sim: watcher killed at every teardown step still converges (HERD-164)" {
  run bash "$REPO/scripts/herd/sim/retirement-invariant-sim.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "post-merge reconcile sim: a foreign or crashed merge still gets its hooks (HERD-232)" {
  run bash "$REPO/scripts/herd/sim/postmerge-reconcile-sim.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "tick availability sim: a hung gh and a slow lane never wedge the tick (HERD-237)" {
  run bash "$REPO/scripts/herd/sim/tick-availability-sim.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

# ── DYNAMIC discovery: one registered test per tests/test-*.sh ───────────────────────────────────
# bats_test_function is bats-core's registration primitive (exactly what `@test "…" { … }` desugars
# to during preprocessing). Calling it in a loop over the glob yields dynamic, individually-reported
# tests. The list is LC_ALL=C sorted for a deterministic registration order across bats's gather and
# exec phases (both source this file). Adding a tests/test-*.sh is now auto-covered — no edit here.
HERD_DISCOVERY_BESPOKE="test-codemap-project.sh test-backlog-view-width.sh"

# Shared body for a discovered test: run the script, require exit 0 AND a PASS marker. The marker
# ("ALL PASS" / "PASS" / "checks passed" / …) catches a script that exits 0 WITHOUT running (an early
# skip / missing-dep guard) — a plain exit-0 check would pass it silently.
herd_run_discovered_test() {
  run bash "$BATS_TEST_DIRNAME/$1"
  if [ "$status" -ne 0 ]; then
    echo "tests/$1 FAILED (exit $status)"; echo "$output"; return 1
  fi
  if [[ "$output" != *PASS* && "$output" != *passed* ]]; then
    echo "tests/$1 exited 0 but printed no PASS marker — did it actually run?"; echo "$output"; return 1
  fi
}

# shellcheck source=discover-tests.bash
source "$BATS_TEST_DIRNAME/discover-tests.bash"
# `|| _herd_disc_rc=$?` captures the rc WITHOUT tripping the `set -e` bats sources this file under —
# a bare `var="$(cmd-that-exits-2)"` would abort the whole gather phase before we can register the
# loud zero-match test below.
_herd_disc_rc=0
_herd_disc_list="$(herd_bats_discover "$BATS_TEST_DIRNAME" "$BATS_TEST_DIRNAME/gate-coverage-exempt.tsv" "$HERD_DISCOVERY_BESPOKE")" || _herd_disc_rc=$?
if [ "$_herd_disc_rc" -eq 2 ]; then
  # LOUD: the glob matched ZERO tests/test-*.sh. A typo / wrong dir must never pass an empty suite.
  test_herd_discovery_glob_matched_zero_files() {
    echo "FATAL: HERD-295 dynamic discovery matched ZERO tests/test-*.sh under $BATS_TEST_DIRNAME"
    echo "       (glob typo, wrong dir, or empty suite) — refusing to pass an empty suite."
    return 1
  }
  bats_test_function --description "HERD-295 discovery matched zero tests/test-*.sh (glob typo / empty suite)" \
    -- test_herd_discovery_glob_matched_zero_files
else
  _herd_disc_i=0
  while IFS= read -r _herd_disc_base; do
    [ -n "$_herd_disc_base" ] || continue
    eval "test_herd_disc_${_herd_disc_i}() { herd_run_discovered_test $(printf '%q' "$_herd_disc_base"); }"
    bats_test_function --description "hermetic $_herd_disc_base (dynamic)" -- "test_herd_disc_${_herd_disc_i}"
    _herd_disc_i=$((_herd_disc_i + 1))
  done <<HERD_DISC_EOF
$_herd_disc_list
HERD_DISC_EOF
fi
