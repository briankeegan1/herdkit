#!/usr/bin/env bash
# tests/test-sandbox-posture-matrix-full-auto.sh — full-auto slice of the posture matrix (HERD-477
# split of HERD-153's test-sandbox-posture-matrix.sh; see tests/lib/sandbox-posture-matrix-case.sh for
# what this asserts and why the test family is split this way). full-auto (MERGE_POLICY=auto) must
# fully drain (queue_drained).
#
# Fully hermetic. Run:  bash tests/test-sandbox-posture-matrix-full-auto.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/sandbox-posture-matrix-case.sh
. "$HERE/lib/sandbox-posture-matrix-case.sh"
posture_matrix_case full-auto 40
