#!/usr/bin/env bash
# tests/test-sandbox-posture-matrix-custom-steps.sh — custom-steps slice of the posture matrix
# (HERD-477 split of HERD-153's test-sandbox-posture-matrix.sh; see
# tests/lib/sandbox-posture-matrix-case.sh for what this asserts and why the test family is split this
# way). custom-steps must release its approve-stage hold exactly once per (sha,step), AND the injected
# PR #249 defect (SANDBOX_FORCE_STEPS_FAULT=1) must come back RED — the regression self-check.
#
# Budget 70s: this posture's matrix run includes an internal fault-injection re-check, plus this file's
# own direct fault re-run to assert the scorecard precisely (measured ~28s locally combined, 3 total
# scenario invocations). The original 50s budget (1.79x local) rode too little headroom on a contended
# macOS CI runner: main-CI run 30819227199 (sha 78a38f19, shard macos 2/8) clocked it at 53s and FAILed
# the headroom assertion — the exact HERD-440/#588 flake class this file's own comments warn about, not
# a code regression in the release-once invariant itself (checkpoints (b)/(c)/(e) all passed that run).
# 70s matches solo-auto's ~2x-local headroom ratio (65s budget / 32s local) for the same multi-invocation
# shape, comfortably under the shared 120s per-test cap.
# Fully hermetic. Run:  bash tests/test-sandbox-posture-matrix-custom-steps.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/sandbox-posture-matrix-case.sh
. "$HERE/lib/sandbox-posture-matrix-case.sh"
posture_matrix_case custom-steps 70
