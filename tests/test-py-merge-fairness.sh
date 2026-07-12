#!/usr/bin/env bash
# test-py-merge-fairness.sh — gate proof for the MERGE_FAIRNESS starvation freeze (HERD-340, §6.2 of
# docs/engine-contract.md; folds closed HERD-294, the #399 livelock). The freeze is the promotion of
# the ship-dormant _merge_fairness_reorder from observability to enforcement, ported to the typed
# engine core (pysrc/herd/statemachine.py + pysrc/herd/live_runtime.py).
#
# Proves — HERMETICALLY (python3 stdlib only; NO gh, git, herdr, network, or model) — via the
# side-effect-free dry-run column, so a test run can never actuate the live control room:
#
#   (1) UNIT INVARIANTS — the statemachine `merge_frozen` edge (BLESSED→HOLD) and the live-runtime
#       freeze/ledger, asserted directly in tests/test_statemachine_props.py + tests/test_live_runtime.py.
#   (2) FREEZE ON — a starved head-of-line PR (re-staled past threshold) still finishing its final gate
#       causes a would-be sibling merge to be HELD for one window (merge_fairness_freeze journaled), so
#       the shared base stays put and the starved PR keeps its clean window.
#   (3) BYTE-IDENTICAL OFF — the SAME scenario with MERGE_FAIRNESS off merges the sibling and emits NO
#       fairness event of any kind (the ship-dormant / byte-identical-when-off doctrine, AGENTS.md).
#   (4) STARVED PR IS NOT SELF-BLOCKED — when the starved PR is itself gates-ready it MERGES (the win)
#       while its sibling freezes; a PR never freezes itself.
#   (5) HUMAN-HELD NEVER FREEZES — a starved PR parked on a human-verify hold does NOT freeze siblings
#       (freezing behind a human would deadlock the queue); the sibling merges.
#
# Run:  bash tests/test-py-merge-fairness.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
for f in pysrc/herd/live_runtime.py pysrc/herd/statemachine.py; do
  [ -f "$REPO/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
PASS=0
pass() { PASS=$((PASS + 1)); }

run() {  # run <fixture> <journal> — dry-run the tick, echo the result JSON (never touches real journal)
  # Each call gets its OWN state dir: the dry-run tick uses WORKTREES_DIR as its state substrate, so the
  # one-window freeze guard (.live-noted-fairness_window-*) must not carry across sub-tests that reuse a
  # (pr,sha). A per-call dir keeps each scenario a clean, independent window.
  local sd; sd="$(mktemp -d "$T/state.XXXXXX")"
  LIVE_DRYRUN_JOURNAL="$2" WORKTREES_DIR="$sd" \
    PYTHONPATH="$REPO/pysrc" python3 -m herd.live_runtime --dry-run --fixture "$1"
}

# ── (1) unit invariants ─────────────────────────────────────────────────────────────────────────
mkdir -p "$T/hermetic"
HERD_CONFIG_FILE="$T/no-such-config" WORKTREES_DIR="$T/hermetic" \
  PYTHONPATH="$REPO/pysrc" python3 "$HERE/test_statemachine_props.py" >/dev/null 2>&1 \
  || fail "statemachine unit invariants failed (run: PYTHONPATH=pysrc python3 tests/test_statemachine_props.py)"
HERD_CONFIG_FILE="$T/no-such-config" WORKTREES_DIR="$T/hermetic" \
  PYTHONPATH="$REPO/pysrc" python3 "$HERE/test_live_runtime.py" >/dev/null 2>&1 \
  || fail "live-runtime unit invariants failed (run: PYTHONPATH=pysrc python3 tests/test_live_runtime.py)"
pass

# The base fixture: a starved PR (pr1) still on its final gate (review WAIT) + a ready sibling (pr2).
cat > "$T/on.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","MERGE_FAIRNESS":"on"},
 "candidates":[
   {"pr":1,"sha":"a1","slug":"starved","review":"WAIT","health":"CLEAN","restale_laps":3},
   {"pr":2,"sha":"a2","slug":"sibling","review":"PASS","health":"CLEAN","worktree":"/wt/2"}]}
JSON

# ── (2) freeze ON: the sibling is held for one window, not merged ────────────────────────────────
OUT="$(run "$T/on.json" "$T/on.jsonl")" || fail "freeze-on dry-run exited nonzero"
printf '%s' "$OUT" | grep -q '"1":"PENDING"' || fail "starved pr1 should still be PENDING ($OUT)"
printf '%s' "$OUT" | grep -q '"2":"HOLD"'    || fail "sibling pr2 should be FROZEN→HOLD ($OUT)"
grep -q '"event":"merge_fairness_freeze"' "$T/on.jsonl" || fail "no merge_fairness_freeze event"
[ "$(grep -c '"event":"merge"' "$T/on.jsonl")" = 0 ] || fail "a merge leaked past the freeze"
pass

# ── (3) byte-identical OFF: same scenario merges the sibling, no fairness event ──────────────────
sed 's/"MERGE_FAIRNESS":"on"/"MERGE_FAIRNESS":"off"/' "$T/on.json" > "$T/off.json"
OUT="$(run "$T/off.json" "$T/off.jsonl")" || fail "freeze-off dry-run exited nonzero"
printf '%s' "$OUT" | grep -q '"2":"MERGE"' || fail "with the lever off pr2 must MERGE ($OUT)"
grep -Eq '"event":"(merge_fairness_freeze|pr_restale|pr_starvation)"' "$T/off.jsonl" \
  && fail "lever off leaked a fairness/restale event (must be byte-identical)"
[ "$(grep -c '"event":"merge"' "$T/off.jsonl")" = 1 ] || fail "off: the sibling merge is missing"
pass

# ── (4) starved PR is not self-blocked: when itself ready it MERGES, sibling freezes ─────────────
cat > "$T/ready.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","MERGE_FAIRNESS":"on"},
 "candidates":[
   {"pr":1,"sha":"a1","slug":"starved","review":"PASS","health":"CLEAN","worktree":"/wt/1","restale_laps":3},
   {"pr":2,"sha":"a2","slug":"sibling","review":"PASS","health":"CLEAN","worktree":"/wt/2"}]}
JSON
OUT="$(run "$T/ready.json" "$T/ready.jsonl")" || fail "starved-ready dry-run exited nonzero"
printf '%s' "$OUT" | grep -q '"1":"MERGE"' || fail "a gates-ready starved pr1 must MERGE, not self-block ($OUT)"
printf '%s' "$OUT" | grep -q '"2":"HOLD"'  || fail "sibling pr2 should still freeze ($OUT)"
pass

# ── (5) a human-verify hold never triggers a freeze (no deadlock behind a human) ─────────────────
cat > "$T/hv.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","MERGE_FAIRNESS":"on"},
 "candidates":[
   {"pr":1,"sha":"a1","slug":"held","review":"PASS","health":"CLEAN","hv_hold":true,"restale_laps":5},
   {"pr":2,"sha":"a2","slug":"sibling","review":"PASS","health":"CLEAN","worktree":"/wt/2"}]}
JSON
OUT="$(run "$T/hv.json" "$T/hv.jsonl")" || fail "human-verify dry-run exited nonzero"
printf '%s' "$OUT" | grep -q '"2":"MERGE"' || fail "a human-held starved PR must not freeze the sibling ($OUT)"
grep -q '"event":"merge_fairness_freeze"' "$T/hv.jsonl" \
  && fail "a human-verify hold must never trigger a freeze (would deadlock behind a human)"
pass

# The dry-run smoke must NOT write the real journal.jsonl anywhere under a state dir (it writes only
# the caller-named LIVE_DRYRUN_JOURNAL) — the VERIFY side-effect-free discipline.
[ -n "$(find "$T" -name journal.jsonl -print -quit 2>/dev/null)" ] \
  && fail "dry-run smoke leaked into a REAL journal.jsonl"

echo "ALL PASS ($PASS/5 merge-fairness checks: unit invariants, freeze on, byte-identical off, no self-block, human-hold never freezes)"
