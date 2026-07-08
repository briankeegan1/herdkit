#!/usr/bin/env bats
# herd.bats — bats smoke tests for the herdkit engine + CLI. Run:  bats tests/herd.bats
# (When bats isn't installed, the hermetic tests/test-*.sh cover the same ground and the dogfood
# healthcheck runs those directly.)

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

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

@test "hermetic config-loader test passes" {
  run bash "$REPO/tests/test-herd-config.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic research-queue test passes" {
  run bash "$REPO/tests/test-research-step.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic changelog-backend test passes" {
  run bash "$REPO/tests/test-backend-changelog.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic linear-backend test passes" {
  run bash "$REPO/tests/test-backend-linear.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic file-backend test passes" {
  run bash "$REPO/tests/test-backend-file.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic planned-work-visibility test passes" {
  run bash "$REPO/tests/test-planned-work-visibility.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic CLI init/render/upgrade test passes" {
  run bash "$REPO/tests/test-cli.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic model-flag wiring test passes" {
  run bash "$REPO/tests/test-model-flags.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic generalized start-agent seam (driver launch-agent) test passes" {
  run bash "$REPO/tests/test-driver-launch-agent.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic backlog-archive rotation test passes" {
  run bash "$REPO/tests/test-backlog-archive.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic backend-aware backlog-view test passes" {
  run bash "$REPO/tests/test-backlog-view-backend.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic backlog-view manual-refresh key (HERD-48) test passes" {
  run bash "$REPO/tests/test-backlog-view-refresh-key.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic TOKEN_MODE=eco tier test passes" {
	run bash "$REPO/tests/test-token-mode.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic Claude Code plugin manifest test passes" {
  run bash "$REPO/tests/test-plugin-manifest.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "hermetic tab-leak-guard engine-whitelist test passes" {
  run bash "$REPO/tests/test-tab-leak-whitelist.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic tab-leak-guard deflake (HERD-93) test passes" {
  run bash "$REPO/tests/test-tab-leak-deflake.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic tab-leak-guard worktree-slug whitelist (HERD-115) test passes" {
  run bash "$REPO/tests/test-tab-leak-worktree-whitelist.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic builder-secrets-isolation test passes" {
  run bash "$REPO/tests/test-builder-secrets-isolation.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic approval-purge (HERD-90) test passes" {
  run bash "$REPO/tests/test-approval-purge.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic coordinator progress-ledger (HERD-103) test passes" {
  run bash "$REPO/tests/test-ledger.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic mid-flight advisor (HERD-101) test passes" {
  run bash "$REPO/tests/test-advise.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic project-mode codemap test passes" {
  run bash "$REPO/tests/test-codemap-project.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "hermetic dependency-aware spawn queue (HERD-94) test passes" {
  run bash "$REPO/tests/test-spawn-queue-deps.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic reviewer-pane lifecycle (HERD-113) test passes" {
  run bash "$REPO/tests/test-reviewer-pane-lifecycle.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic drainer singleton liveness (HERD-109) test passes" {
  run bash "$REPO/tests/test-drainer-liveness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "herd render produces no leftover template tokens for this repo" {
  run bash "$REPO/bin/herd" render
  [ "$status" -eq 0 ]
  run grep -q '{{' "$REPO/.claude/commands/coordinator.md"
  [ "$status" -ne 0 ]
}
