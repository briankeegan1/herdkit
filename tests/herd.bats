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

@test "hermetic resolver idle re-dispatch (HERD-225) test passes" {
  run bash "$REPO/tests/test-resolver-idle-redispatch.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic resolver limit-park guard (HERD-246) test passes" {
  run bash "$REPO/tests/test-resolver-limit-park.sh"
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

@test "hermetic leak-guard exemption + infra cap (HERD-228) test passes" {
  run bash "$REPO/tests/test-watcher-leakguard-exemption.sh"
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

@test "hermetic journal hermeticity guard (HERD-223) test passes" {
  run bash "$REPO/tests/test-journal-hermeticity.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic journal self-audit gap-finder (HERD-238) test passes" {
  run bash "$REPO/tests/test-journal-audit.sh"
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

@test "hermetic knob-aware operating doctrine (HERD-216) test passes" {
  run bash "$REPO/tests/test-knob-aware-doctrine.sh"
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

@test "hermetic doc-drift check (HERD-168 / HERD-96) test passes" {
  run bash "$REPO/tests/test-doc-drift.sh"
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

@test "hermetic CI auto-repair inherited red (HERD-250) unit test passes" {
  run bash "$REPO/tests/test-ci-autorepair.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic main-health reconciled invariant (HERD-222) unit test passes" {
  run bash "$REPO/tests/test-main-health-invariant.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

# HERD-259: this suite shipped with HERD-233 but no bats block ever ran it, so the MAIN-freshness
# reconcile was ungated for four months — including the recovery leg whose absence let a healed
# 'dirty-tree' row paint for 20+ minutes. Wired in with the recovery legs it now carries.
@test "hermetic MAIN-checkout freshness reconcile (HERD-233/259) unit test passes" {
  run bash "$REPO/tests/test-main-freshness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "hermetic gate order: stale-dup decides before review/health dispatch (HERD-227) test passes" {
  run bash "$REPO/tests/test-gate-order-stale-dup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic watcher discovery-scope / phantom detached-HEAD filter (HERD-182) test passes" {
  run bash "$REPO/tests/test-watcher-discovery-scope.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic watcher sha-resilient PR join + branch auto-repair (HERD-226) test passes" {
  run bash "$REPO/tests/test-watcher-sha-join.sh"
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

@test "hermetic control-room sweep (HERD-191) test passes" {
  run bash "$REPO/tests/test-sweep.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic retirement-invariant (HERD-164) test passes" {
  run bash "$REPO/tests/test-retirement-invariant.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "cross-seat BLOCK precedence: a foreign BLOCK outranks this seat's PASS (HERD-247)" {
  run bash "$REPO/tests/test-cross-seat-block.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS test-cross-seat-block.sh"* ]]
}

@test "retirement-invariant sim: watcher killed at every teardown step still converges (HERD-164)" {
  run bash "$REPO/scripts/herd/sim/retirement-invariant-sim.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic post-merge reconcile sweep (HERD-232) test passes" {
  run bash "$REPO/tests/test-postmerge-sweep.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: test-postmerge-sweep.sh"* ]]
}

@test "post-merge reconcile sim: a foreign or crashed merge still gets its hooks (HERD-232)" {
  run bash "$REPO/scripts/herd/sim/postmerge-reconcile-sim.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "hermetic gh availability guard (HERD-237) test passes" {
  run bash "$REPO/tests/test-watcher-gh-timeout.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "tick availability sim: a hung gh and a slow lane never wedge the tick (HERD-237)" {
  run bash "$REPO/scripts/herd/sim/tick-availability-sim.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
}

@test "herd render produces no leftover template tokens for this repo" {
  run bash "$REPO/bin/herd" render
  [ "$status" -eq 0 ]
  run grep -q '{{' "$REPO/.claude/commands/coordinator.md"
  [ "$status" -ne 0 ]
}

# ── HERD-257 test-wiring ratchet: previously-ungated hermetic tests ─────────────────
# Auto-generated bulk wiring so the merge gate (and scripts/ci/run-suite.sh curated
# mode) actually RUNS every tests/test-*.sh that is not in test-wiring-exempt.tsv.
# Prefer a hand-written descriptive @test name when revisiting a file; status-eq-0
# is the load-bearing pass criterion (output markers vary across the suite).

@test "hermetic test-agent-naming.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-agent-naming.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-agent-update.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-agent-update.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-app-preview-config.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-app-preview-config.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-attribution-lint.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-attribution-lint.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-auto-refix.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-auto-refix.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-autoreconcile.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-autoreconcile.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-backend-claim.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-backend-claim.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-backend-github.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-backend-github.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-backlog-reconcile-sweep.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-backlog-reconcile-sweep.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-backlog-reconcile.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-backlog-reconcile.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-backlog-view-bold.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-backlog-view-bold.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-backlog-view-extras.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-backlog-view-extras.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-backlog-view-render.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-backlog-view-render.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-backlog-view-rich.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-backlog-view-rich.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-backlog-view-untracked.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-backlog-view-untracked.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-benchmark-drain.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-benchmark-drain.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-budget-governance.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-budget-governance.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-builder-notes-journal.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-builder-notes-journal.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-caps-sync-light.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-caps-sync-light.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-changelog.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-changelog.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-ci-run-suite.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-ci-run-suite.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-claim.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-claim.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-cli-approve.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-cli-approve.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-cli-backlog.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-cli-backlog.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-cli-config-sync.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-cli-config-sync.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-cli-config.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-cli-config.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-cli-links.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-cli-links.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-cli-pane.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-cli-pane.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-cli-reload.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-cli-reload.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-cli-report.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-cli-report.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-cli-symlink.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-cli-symlink.sh"
  [ "$status" -eq 0 ]
}


@test "hermetic test-codemap-autorefresh.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-codemap-autorefresh.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-codemap-reconcile.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-codemap-reconcile.sh"
  [ "$status" -eq 0 ]
}


@test "hermetic test-codex-driver.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-codex-driver.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-commit-convention-lint.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-commit-convention-lint.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-config-dedup-lint.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-config-dedup-lint.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-config-key-docs.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-config-key-docs.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-config-list-hang.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-config-list-hang.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-config-local-dup-lint.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-config-local-dup-lint.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-config-local-overlay.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-config-local-overlay.sh"
  [ "$status" -eq 0 ]
}



@test "hermetic test-console-rows-ageout.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-console-rows-ageout.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-console-tracker-ids.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-console-tracker-ids.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-console-vocabulary.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-console-vocabulary.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-context-provision.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-context-provision.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-coordinator-watchdog.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-coordinator-watchdog.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-correctness-only-block.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-correctness-only-block.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-cost.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-cost.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-de-brand-output.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-de-brand-output.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-de-streamlit-docs.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-de-streamlit-docs.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-dead-builder-respawn.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-dead-builder-respawn.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-dead-builder.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-dead-builder.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-delta-review.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-delta-review.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-dep-states.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-dep-states.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-dep-watcher.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-dep-watcher.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-derived-skill.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-derived-skill.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-dispatch-deps.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-dispatch-deps.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-doctor-claude-quarantine.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-doctor-claude-quarantine.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-doctor-dep-tiering.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-doctor-dep-tiering.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-doctor-exechang-probe.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-doctor-exechang-probe.sh"
  [ "$status" -eq 0 ]
}


@test "hermetic test-doctor-posture.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-doctor-posture.sh"
  [ "$status" -eq 0 ]
}


@test "hermetic test-drainer-driver-seam.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-drainer-driver-seam.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-drainer-liveness-corroborate.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-drainer-liveness-corroborate.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-driver-abstraction.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-driver-abstraction.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-driver-lane-spawn.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-driver-lane-spawn.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-eco-starter-defaults.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-eco-starter-defaults.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-external-consumer-audit.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-external-consumer-audit.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-externalize-task-specs.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-externalize-task-specs.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-fleet-digest.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-fleet-digest.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-fleet-discover.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-fleet-discover.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-fleet-governance.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-fleet-governance.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-fleet-inbox.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-fleet-inbox.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-fleet-room.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-fleet-room.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-fleet.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-fleet.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-flow-preference.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-flow-preference.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-gate-dispatch.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-gate-dispatch.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-gate-keys-strict.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-gate-keys-strict.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-gate-status.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-gate-status.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-grok-driver.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-grok-driver.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-headless-driver.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-headless-driver.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-healthcheck-interaction.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-healthcheck-interaction.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-healthcheck-light-probes.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-healthcheck-light-probes.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-healthcheck-routing.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-healthcheck-routing.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-human-verify-hold.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-human-verify-hold.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-human-verify-policy.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-human-verify-policy.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-infra-breaker.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-infra-breaker.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-init-github-detection.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-init-github-detection.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-init-grounding-interview.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-init-grounding-interview.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-install.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-install.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-journal.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-journal.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-launch-binding-guard.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-launch-binding-guard.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-layout-reconcile.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-layout-reconcile.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-leakguard.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-leakguard.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-limit-menu-select.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-limit-menu-select.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-limit-resume.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-limit-resume.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-local-review-prepr.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-local-review-prepr.sh"
  [ "$status" -eq 0 ]
}



@test "hermetic test-mcp-provision.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-mcp-provision.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-merge-fairness.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-merge-fairness.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-merge-policy.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-merge-policy.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-model-escalate.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-model-escalate.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-oss-triage.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-oss-triage.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-parallel-review.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-parallel-review.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-pr-match-truth.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-pr-match-truth.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-pr-tracker-linking.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-pr-tracker-linking.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-preflight.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-preflight.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-pretrust.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-pretrust.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-prompt-order.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-prompt-order.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-quick-tab-register.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-quick-tab-register.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-read-project-config.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-read-project-config.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-reconcile-backend-gate.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-reconcile-backend-gate.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-refix-wake.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-refix-wake.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-report-repo-guard.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-report-repo-guard.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-review-escalation.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-review-escalation.sh"
  [ "$status" -eq 0 ]
}


@test "hermetic test-review-pin-dispatch-sha.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-review-pin-dispatch-sha.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-review-sever-protect.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-review-sever-protect.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-review-verdict-integrity.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-review-verdict-integrity.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-review-verdict-path-quote.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-review-verdict-path-quote.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-review-visibility.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-review-visibility.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-risk-scoped-prpr-review.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-risk-scoped-prpr-review.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-risk-tiered-review.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-risk-tiered-review.sh"
  [ "$status" -eq 0 ]
}


@test "hermetic test-sandbox-limit-resume.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-sandbox-limit-resume.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-sandbox-multiseat.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-sandbox-multiseat.sh"
  [ "$status" -eq 0 ]
}


@test "hermetic test-sandbox-real-panes.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-sandbox-real-panes.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-sandbox-real-remote.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-sandbox-real-remote.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-sandbox-resolver-respawn.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-sandbox-resolver-respawn.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-sandbox-shared-config.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-sandbox-shared-config.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-sandbox-sim.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-sandbox-sim.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-scoped-builder-verification.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-scoped-builder-verification.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-scribe-backend-flip.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-scribe-backend-flip.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-scribe-intent-dispatch.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-scribe-intent-dispatch.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-scribe-linger.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-scribe-linger.sh"
  [ "$status" -eq 0 ]
}


@test "hermetic test-spawn-queue-drain.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-spawn-queue-drain.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-spawn-rate-match.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-spawn-rate-match.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-stack-aware-init.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-stack-aware-init.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-stale-resolve-tab-sweep.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-stale-resolve-tab-sweep.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-stall-detector.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-stall-detector.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-startup-reap-sweep.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-startup-reap-sweep.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-stat-uutils-detection.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-stat-uutils-detection.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-stats.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-stats.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-status-driver-seam.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-status-driver-seam.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-status.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-status.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-steps-hold-supersession.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-steps-hold-supersession.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-structured-block-verdict.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-structured-block-verdict.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-sweep-registry-tally.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-sweep-registry-tally.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-symbol-index-autorefresh.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-symbol-index-autorefresh.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-symbol-index.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-symbol-index.sh"
  [ "$status" -eq 0 ]
}


@test "hermetic test-tab-leak-scope.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-tab-leak-scope.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-tab-teardown.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-tab-teardown.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-task-spec-pane.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-task-spec-pane.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-team-mode.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-team-mode.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-test-wiring.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-test-wiring.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-theme-cmd.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-theme-cmd.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-theme.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-theme.sh"
  [ "$status" -eq 0 ]
}


@test "hermetic test-tracker-state-sweep.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-tracker-state-sweep.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-upgrade-config-adoption.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-upgrade-config-adoption.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-upgrade-migrations.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-upgrade-migrations.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-utf8-control-room.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-utf8-control-room.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-watcher-checks.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-watcher-checks.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-watcher-claude-hang.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-watcher-claude-hang.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-watcher-singleton.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-watcher-singleton.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-watcher-views.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-watcher-views.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-workspace-pin.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-workspace-pin.sh"
  [ "$status" -eq 0 ]
}

@test "hermetic test-worktree-born-stat.sh (HERD-257 wiring) passes" {
  run bash "$REPO/tests/test-worktree-born-stat.sh"
  [ "$status" -eq 0 ]
}
