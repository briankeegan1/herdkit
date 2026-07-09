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

@test "hermetic jira-backend test passes" {
  run bash "$REPO/tests/test-backend-jira.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic cli backend-switch test passes" {
  run bash "$REPO/tests/test-cli-backend-switch.sh"
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

@test "hermetic scribe AMEND verb (HERD-128) test passes" {
  run bash "$REPO/tests/test-scribe-amend.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic scribe auto planned-marker (HERD-183) test passes" {
  run bash "$REPO/tests/test-scribe-auto-marker.sh"
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

@test "hermetic agent-runtime exec-surface bindings (HERD-150 P1) test passes" {
  run bash "$REPO/tests/test-driver-agent-exec.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic drainer one-shot exec seam (HERD-150 P3) test passes" {
  run bash "$REPO/tests/test-oneshot-exec-seam.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic model-matrix (HERD-151) test passes" {
  run bash "$REPO/tests/test-model-matrix.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic no-new-hardcoded-claude lint (HERD-177 P5) test passes" {
  run bash "$REPO/tests/test-claude-hardcode-lint.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic stub proof driver + runtime seam (HERD-177 P6) test passes" {
  run bash "$REPO/tests/test-stub-driver.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic HERD-42 A/B scorer test passes" {
  run bash "$REPO/tests/test-herd42-score.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic rubric-screen dual-screener merge (HERD-166) test passes" {
  run bash "$REPO/tests/test-rubric-screen-merge.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic rubric-screening disagreement-surface sim (HERD-166) passes" {
  run bash "$REPO/scripts/herd/sim/rubric-screen-sim.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SIM PASS"* ]]
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

@test "hermetic sha-keyed resolver re-spawn test passes" {
  run bash "$REPO/tests/test-watcher-respawn-resolver.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic resolver liveness / false-dead (HERD-206) test passes" {
  run bash "$REPO/tests/test-resolver-liveness.sh"
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

@test "hermetic daemon-hermeticity guard (HERD-189) test passes" {
  run bash "$REPO/tests/test-daemon-hermeticity.sh"
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

@test "hermetic healthcheck env-vs-code classification (HERD-187) test passes" {
  run bash "$REPO/tests/test-healthcheck-env-classify.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic baseline-aware gate (HERD-190) test passes" {
  run bash "$REPO/tests/test-baseline-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic reviewer-pane lifecycle (HERD-113) test passes" {
  run bash "$REPO/tests/test-reviewer-pane-lifecycle.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic restart-safe gate dispatch (HERD-185) test passes" {
  run bash "$REPO/tests/test-restart-safe-dispatch.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic health-run observability (HERD-185) test passes" {
  run bash "$REPO/tests/test-health-observability.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic async healthcheck gate test passes" {
  run bash "$REPO/tests/test-healthcheck-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic healthcheck sha-cache test passes" {
  run bash "$REPO/tests/test-watcher-health-cache.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic healthcheck-autofix + row-truth test passes" {
  run bash "$REPO/tests/test-health-autofix.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic dead-agent-eyes liveness probe (HERD-114) test passes" {
  run bash "$REPO/tests/test-agent-liveness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic coordinator startup-restore probe (HERD-112) test passes" {
  run bash "$REPO/tests/test-startup-restore.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "hermetic drainer singleton liveness (HERD-109) test passes" {
  run bash "$REPO/tests/test-drainer-liveness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic builder handoff summary (HERD-106) test passes" {
  run bash "$REPO/tests/test-handoff-summary.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic native-burst fan-out seam (HERD-107) test passes" {
  run bash "$REPO/tests/test-native-burst.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic project-defined branch naming (HERD-120) test passes" {
  run bash "$REPO/tests/test-branch-template.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic governance adoption from CLAUDE.md (HERD-119) test passes" {
  run bash "$REPO/tests/test-init-governance-adoption.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic init merge-policy consequence-loud ask (HERD-140) test passes" {
  run bash "$REPO/tests/test-init-merge-policy-ask.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic governance profiles export/apply (HERD-126) test passes" {
  run bash "$REPO/tests/test-governance-profiles.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic governance hook-rendering (HERD-131) test passes" {
  run bash "$REPO/tests/test-governance-hooks-render.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic governance-drift sweep (HERD-125) test passes" {
  run bash "$REPO/tests/test-governance-drift.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic end-to-end governance sim (HERD-127) test passes" {
  run bash "$REPO/tests/test-sandbox-governance.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic capability conformance matrix (HERD-144) test passes" {
  run bash "$REPO/tests/test-conformance.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic watcher-flair pack (HERD-147) unit test passes" {
  run bash "$REPO/tests/test-watcher-flair.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "hermetic stale-duplicate gate (HERD-188) unit test passes" {
  run bash "$REPO/tests/test-stale-dup-detect.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic stale-base autofix (HERD-199) unit test passes" {
  run bash "$REPO/tests/test-stale-base-autofix.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic watcher discovery-scope / phantom detached-HEAD filter (HERD-182) test passes" {
  run bash "$REPO/tests/test-watcher-discovery-scope.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic watcher GH CI check-run gate events (HERD-197) test passes" {
  run bash "$REPO/tests/test-watcher-ci-gate-events.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic scheduled/triggered runs (HERD-169) test + sim passes" {
  run bash "$REPO/tests/test-triggers.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic operator inbox (HERD-184) unit test passes" {
  run bash "$REPO/tests/test-operator-inbox.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}


@test "hermetic connector seams edges (HERD-170) test passes" {
  run bash "$REPO/tests/test-connector-seams.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic engine version handshake + ENGINE_AUTOUPDATE (HERD-179) test passes" {
  run bash "$REPO/tests/test-engine-handshake.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "herd render produces no leftover template tokens for this repo" {
  run bash "$REPO/bin/herd" render
  [ "$status" -eq 0 ]
  run grep -q '{{' "$REPO/.claude/commands/coordinator.md"
  [ "$status" -ne 0 ]
}
