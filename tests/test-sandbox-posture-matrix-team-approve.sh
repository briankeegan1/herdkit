#!/usr/bin/env bash
# tests/test-sandbox-posture-matrix-team-approve.sh — team-approve slice of the posture matrix
# (HERD-477 split of HERD-153's test-sandbox-posture-matrix.sh; see
# tests/lib/sandbox-posture-matrix-case.sh for what this asserts and why the test family is split this
# way). team-approve must gate merge on a sha-keyed human approval and merge only the approved PR.
#
# Fully hermetic. Run:  bash tests/test-sandbox-posture-matrix-team-approve.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/sandbox-posture-matrix-case.sh
. "$HERE/lib/sandbox-posture-matrix-case.sh"
posture_matrix_case team-approve 40
