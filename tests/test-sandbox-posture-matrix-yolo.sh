#!/usr/bin/env bash
# tests/test-sandbox-posture-matrix-yolo.sh — yolo slice of the posture matrix (HERD-477 split of
# HERD-153's test-sandbox-posture-matrix.sh; see tests/lib/sandbox-posture-matrix-case.sh for what this
# asserts and why the test family is split this way). yolo (MERGE_POLICY=auto) must fully drain
# (queue_drained) — the posture #588 added, whose extra row is what tipped the combined test over the
# shared 120s per-test cap in the first place.
#
# Fully hermetic. Run:  bash tests/test-sandbox-posture-matrix-yolo.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/sandbox-posture-matrix-case.sh
. "$HERE/lib/sandbox-posture-matrix-case.sh"
posture_matrix_case yolo 40
