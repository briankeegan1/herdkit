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

# ── HERD-326: load-sensitive sim retry ───────────────────────────────────────────────────────────
# tests 7/8/9 below (builder-chaos / retirement-invariant / postmerge-reconcile) drive many
# short-lived child processes + real git under a hermetic fixture. Their asserts await terminal STATE
# (leg (a)), so they are correct — but under a heavily loaded box a single leg can still miss its poll
# window and paint a spurious red (the PR #431 false-red). These three legs — and ONLY these — are
# TAGGED load-sensitive by running through herd_run_loadsim: on a FIRST-attempt failure the harness
# waits a quiet interval and retries EXACTLY once before alarming. A leg that passes on the quiet retry
# is a flaky/load pass, not a code red — labeled 'flaky/load' distinctly in the console row (via bats
# FD 3). A leg that REPRODUCES the failure on the retry is a real red, surfaced with both attempts.
# Product-assert @tests are never tagged and never retry. BYTE-IDENTICAL when the sim passes first try:
# no retry, no label, no sleep — the tag path is inert on green.
HERD_SIM_LOAD_RETRY_QUIET="${HERD_SIM_LOAD_RETRY_QUIET:-3}"   # quiet interval (s) before the one retry

herd_run_loadsim() {   # <sim-basename> <pass-marker>
  local _sim="$1" _marker="$2" _path
  _path="$REPO/scripts/herd/sim/$_sim"   # separate stmt: `local a=$1 b=$a` expands $a BEFORE a is set
  run bash "$_path"
  if [ "$status" -eq 0 ] && [[ "$output" == *"$_marker"* ]]; then
    return 0                                    # passed first try — byte-identical happy path
  fi
  # First attempt failed. Quiet the box, then retry EXACTLY once before alarming.
  local _first_status="$status" _first_out="$output"
  sleep "$HERD_SIM_LOAD_RETRY_QUIET"
  run bash "$_path"
  if [ "$status" -eq 0 ] && [[ "$output" == *"$_marker"* ]]; then
    # Flaky/load: failed under load, passed on the quiet retry. A DISTINCT console row (FD 3 prints even
    # for a passing bats test), never a silent green and never a code red.
    echo "flaky/load: $_sim failed under load then PASSED on the quiet retry — not a code red" >&3
    return 0
  fi
  # Reproduced on the retry → a REAL red. Surface both attempts so it reads as code, not load.
  echo "$_sim reproduced its failure on the quiet retry — REAL red (not flaky/load)"
  echo "--- attempt 1 (status $_first_status) ---"; echo "$_first_out"
  echo "--- attempt 2 (status $status) ---";        echo "$output"
  return 1
}

@test "hermetic rubric-screening disagreement-surface sim (HERD-166) passes" {
  run bash "$REPO/scripts/herd/sim/rubric-screen-sim.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SIM PASS"* ]]
}

@test "builder-chaos sim: a builder killed at every lifecycle stage leaves no corpse (HERD-162)" {
  herd_run_loadsim builder-chaos-sim.sh "ALL PASS"
}

@test "retirement-invariant sim: watcher killed at every teardown step still converges (HERD-164)" {
  herd_run_loadsim retirement-invariant-sim.sh "ALL PASS"
}

@test "post-merge reconcile sim: a foreign or crashed merge still gets its hooks (HERD-232)" {
  herd_run_loadsim postmerge-reconcile-sim.sh "ALL PASS"
}

# HERD-331: test-sandbox-concurrency.sh exercises the review-cap semaphore in a timing-sensitive
# way (under load the cap may not naturally bite during the drain). The scenario's own cap probe
# makes the CHECK itself robust, but the whole test is still tagged load-sensitive here so a
# residual timing flake retries once before alarming — same class as tests 7/8/9 above.
@test "sandbox concurrency sim: review cap gated and health serialized (HERD-331)" {
  local _path="$BATS_TEST_DIRNAME/test-sandbox-concurrency.sh"
  run bash "$_path"
  if [ "$status" -eq 0 ] && [[ "$output" == *"ALL PASS"* ]]; then return 0; fi
  local _first_status="$status" _first_out="$output"
  sleep "${HERD_SIM_LOAD_RETRY_QUIET:-3}"
  run bash "$_path"
  if [ "$status" -eq 0 ] && [[ "$output" == *"ALL PASS"* ]]; then
    echo "flaky/load: test-sandbox-concurrency.sh failed under load then PASSED on quiet retry — not a code red" >&3
    return 0
  fi
  echo "test-sandbox-concurrency.sh reproduced its failure on quiet retry — REAL red (not flaky/load)"
  echo "--- attempt 1 (status $_first_status) ---"; echo "$_first_out"
  echo "--- attempt 2 (status $status) ---"; echo "$output"
  return 1
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
HERD_DISCOVERY_BESPOKE="test-codemap-project.sh test-backlog-view-width.sh test-sandbox-concurrency.sh"

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
