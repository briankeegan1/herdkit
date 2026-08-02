#!/usr/bin/env bash
# tests/test-sandbox-posture-matrix-gated-push.sh — gated-push slice of the posture matrix (HERD-477
# split of HERD-153's test-sandbox-posture-matrix.sh; see tests/lib/sandbox-posture-matrix-case.sh for
# what this asserts and why the test family is split this way). gated-push must let nothing reach the
# remote before a human approves the push.
#
# Fully hermetic. Run:  bash tests/test-sandbox-posture-matrix-gated-push.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/sandbox-posture-matrix-case.sh
. "$HERE/lib/sandbox-posture-matrix-case.sh"
posture_matrix_case gated-push 40
