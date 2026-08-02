#!/usr/bin/env bash
# tests/test-sandbox-posture-matrix-observe-only.sh — observe-only slice of the posture matrix
# (HERD-477 split of HERD-153's test-sandbox-posture-matrix.sh; see
# tests/lib/sandbox-posture-matrix-case.sh for what this asserts and why the test family is split this
# way). observe-only must run every gate and report/notify but NEVER merge (merges stays 0).
#
# Fully hermetic. Run:  bash tests/test-sandbox-posture-matrix-observe-only.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/sandbox-posture-matrix-case.sh
. "$HERE/lib/sandbox-posture-matrix-case.sh"
posture_matrix_case observe-only 40
