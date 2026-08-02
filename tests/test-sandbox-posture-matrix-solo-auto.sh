#!/usr/bin/env bash
# tests/test-sandbox-posture-matrix-solo-auto.sh — solo-auto slice of the posture matrix (HERD-477
# split of HERD-153's test-sandbox-posture-matrix.sh; see tests/lib/sandbox-posture-matrix-case.sh for
# what this asserts and why the test family is split this way). solo-auto must fully drain
# (queue_drained) AND be byte-identical (checkpoint name+status) to a plain single-posture concurrency
# run — the SAME two invariants the combined test proved for this posture.
#
# Budget 65s: this is the one posture whose matrix run also re-runs a plain concurrency scenario for
# the byte-identical comparison (measured ~32s locally) — the slowest of the eight split files.
# Fully hermetic. Run:  bash tests/test-sandbox-posture-matrix-solo-auto.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/sandbox-posture-matrix-case.sh
. "$HERE/lib/sandbox-posture-matrix-case.sh"
posture_matrix_case solo-auto 65
