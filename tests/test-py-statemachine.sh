#!/usr/bin/env bash
# test-py-statemachine.sh — gate wrapper for the P3b lifecycle state machine (HERD-315, EPIC HERD-300).
#
# P3b ports the watcher's doctrine-by-comment lifecycle to a typed transition table in stdlib Python
# (pysrc/herd/statemachine.py): STATES, EVENTS, TRANSITIONS, transition(), and the two decision
# bridges that CONSUME pysrc/herd/decisions.py (the P2 core) rather than re-deriving the budget /
# merge-policy arithmetic. There is no bash oracle to diff against — the bash tree has no explicit
# state machine (that is the whole point of the port) — so the proof is the exhaustive stdlib unit
# suite tests/test_statemachine_props.py: the STATES x EVENTS grid is total and well-formed, every
# non-terminal is reachable, terminals are dead, INFRA is the only self-loop, and the two bridges
# match herd.decisions decision-for-decision over their whole small input space.
#
# This wrapper exists so HERD-295 dynamic discovery (tests/herd.bats globs tests/test-*.sh) registers
# the python suite as a gate test — a plain test_*.py is invisible to the glob. It runs the module
# with PYTHONPATH=pysrc (the P1 packaging rule: pysrc/ on the path, python3 stdlib only, no deps).
#
# Fully hermetic: no journal/watcher/panes/gh/network/HOME touched. Run:  bash tests/test-py-statemachine.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$REPO/pysrc/herd/statemachine.py" ] || fail "pysrc/herd/statemachine.py missing"
[ -f "$REPO/pysrc/herd/decisions.py" ]    || fail "pysrc/herd/decisions.py missing (state machine consumes it)"
[ -f "$HERE/test_statemachine_props.py" ] || fail "tests/test_statemachine_props.py missing"

# (1) the exhaustive stdlib unit suite (hypothesis pass is skip-soft when the dep is absent).
PYTHONPATH="$REPO/pysrc" python3 "$HERE/test_statemachine_props.py" >/dev/null 2>&1 \
  || fail "state-machine unit suite failed (run: PYTHONPATH=pysrc python3 tests/test_statemachine_props.py)"

# (2) the module imports clean and the exported table round-trips — a fast smoke over the public API
#     (STATES / EVENTS / TRANSITIONS / export_table) that the gate ratchet keys on.
PYTHONPATH="$REPO/pysrc" python3 - <<'PY' || fail "state-machine public API smoke failed"
import sys
from herd import statemachine as SM
assert SM.STATES and SM.EVENTS and SM.TRANSITIONS, "empty public tables"
assert {(f, e): t for f, e, t in SM.export_table()} == SM.TRANSITIONS, "export_table must round-trip"
assert SM.transition(SM.INTAKE, SM.DISPATCH_HEALTH) == SM.HEALTH, "canonical intake edge missing"
try:
    SM.transition(SM.MERGED, SM.NEW_SHA)          # a terminal state accepts nothing
except SM.IllegalTransition:
    pass
else:
    sys.exit("terminal MERGED should reject every event")
PY

echo "ALL PASS (state-machine exhaustive units + public API smoke)"
