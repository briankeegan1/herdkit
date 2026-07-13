#!/usr/bin/env bash
# test-main-health-slot-priority.sh — hermetic regression for HERD-359
#
# Proves that when HEALTH_CONCURRENCY=1 is saturated by a live PR health check, the
# default-branch sha still reaches a verdict on the NEXT reconcile call once the slot is free:
# no-slot is a WAIT (deferred, retried), never a SKIP (silent drop).
#
# Also proves the Python sentinel _main_health_pending() correctly reports pending/done so
# LiveGates.health() can reserve the slot.
#
# Hermetic: local git only, no herdr, no network, no model. Sources agent-watch.sh in lib mode.
# Run:  bash tests/test-main-health-slot-priority.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"

command -v git     >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$WATCH" ]   || { echo "FAIL: missing $WATCH" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
PASS=0; pass() { PASS=$((PASS + 1)); }

# ── (a) Python sentinel: _main_health_pending() ─────────────────────────────────────────────────
# Create a minimal git repo as $MAIN and verify the sentinel's four conditions in Python.
PMAIN="$T/main_repo"
git init -q -b main "$PMAIN"
git -C "$PMAIN" config user.email sim@test; git -C "$PMAIN" config user.name sim
printf 'init\n' > "$PMAIN/README.md"
git -C "$PMAIN" add -A; git -C "$PMAIN" commit -q -m "init"
SHA="$(git -C "$PMAIN" rev-parse HEAD)"
PSTATE="$T/state"
mkdir -p "$PSTATE"

# off by default → False
PYTHONPATH="$REPO/pysrc" python3 - <<PYEOF || fail "(a) _main_health_pending() should be False when MAIN_HEALTH_TICK is unset"
import os, sys
sys.path.insert(0, "$REPO/pysrc")
from herd.live_runtime import _main_health_pending
os.environ.pop("MAIN_HEALTH_TICK", None)
assert not _main_health_pending("$PSTATE"), "expected False when MAIN_HEALTH_TICK unset"
PYEOF
pass

# on + valid MAIN + no markers → True
PYTHONPATH="$REPO/pysrc" python3 - <<PYEOF || fail "(a) _main_health_pending() should be True when unverified sha"
import os, sys
sys.path.insert(0, "$REPO/pysrc")
from herd.live_runtime import _main_health_pending
os.environ["MAIN_HEALTH_TICK"] = "on"
os.environ["MAIN"] = "$PMAIN"
assert _main_health_pending("$PSTATE"), "expected True: no markers for $SHA"
PYEOF
pass

# run-once marker present → False
touch "$PSTATE/.main-health-$SHA"
PYTHONPATH="$REPO/pysrc" python3 - <<PYEOF || fail "(a) _main_health_pending() should be False when run-once marker exists"
import os, sys
sys.path.insert(0, "$REPO/pysrc")
from herd.live_runtime import _main_health_pending
os.environ["MAIN_HEALTH_TICK"] = "on"
os.environ["MAIN"] = "$PMAIN"
assert not _main_health_pending("$PSTATE"), "expected False: run-once marker present"
PYEOF
rm -f "$PSTATE/.main-health-$SHA"
pass
echo "PASS (a) _main_health_pending(): off→False, no-markers→True, run-once→False"

# ── (b) Python gate: PR health WAITS when main-health is pending ────────────────────────────────
# Verify that LiveGates.health() returns WAIT (without laying the inflight marker) when
# MAIN_HEALTH_TICK=on and the main SHA has no verdict.
BSTATE="$T/bstate"; mkdir -p "$BSTATE"
BWTS="$T/bwts"; mkdir -p "$BWTS/feat-55"; printf 'gitdir: /pool\n' > "$BWTS/feat-55/.git"
PYTHONPATH="$REPO/pysrc" python3 - <<PYEOF || fail "(b) PR health should WAIT when main-health pending"
import os, sys, json
sys.path.insert(0, "$REPO/pysrc")
import herd.live_runtime as LR
from herd.live_runtime import LiveGates, LiveState, LiveJournal, LiveCandidate, WAIT

os.environ["MAIN_HEALTH_TICK"] = "on"
os.environ["MAIN"] = "$PMAIN"
os.environ["WORKTREES_DIR"] = "$BSTATE"

state = LiveState(state_dir="$BSTATE")
state.dir = "$BSTATE"
j = LiveJournal("$BSTATE/j.jsonl")
gates = LiveGates("/nonexistent-home", state, j, config={"HEALTH_CONCURRENCY": "1"})
cand = LiveCandidate(pr=55, sha="deadbeef1234", slug="feat-55", worktree="$BWTS/feat-55")
result = gates.health(cand)
assert result == WAIT, f"expected WAIT got {result!r}"
marker = "$BSTATE/.health-inflight-55-deadbeef1234"
assert not os.path.exists(marker), "inflight marker must NOT exist (slot was reserved, dispatch skipped)"
with open("$BSTATE/j.jsonl", encoding="utf-8") as fh:
    evs = [json.loads(l) for l in fh if l.strip()]
queued = [e for e in evs if e.get("event") == "health_queued"]
assert len(queued) == 1, f"expected 1 health_queued event, got {queued}"
print("slot reserved: health_queued emitted, no inflight marker written")
PYEOF
pass

# After main-health done, PR health dispatches.
touch "$PSTATE/.main-health-$SHA"
PYTHONPATH="$REPO/pysrc" python3 - <<PYEOF || fail "(b) PR health should dispatch once main-health done"
import os, sys
sys.path.insert(0, "$REPO/pysrc")
import herd.live_runtime as LR
from herd.live_runtime import LiveGates, LiveState, LiveJournal, LiveCandidate, WAIT

os.environ["MAIN_HEALTH_TICK"] = "on"
os.environ["MAIN"] = "$PMAIN"
os.environ["WORKTREES_DIR"] = "$PSTATE"

state = LiveState(state_dir="$PSTATE")
state.dir = "$PSTATE"
j = LiveJournal("$PSTATE/j.jsonl")
gates = LiveGates("/nonexistent-home", state, j, config={"HEALTH_CONCURRENCY": "1"})
cand = LR.LiveCandidate(pr=56, sha="cafebabe5678", slug="feat-56", worktree="$BWTS/feat-55")
result = gates.health(cand)
assert result == WAIT, f"expected WAIT got {result!r}"
# No health_queued — slot was NOT reserved (main done), dispatch proceeded (then failed on
# /nonexistent-home, which is expected; the gate exit is still WAIT for an async dispatch).
import json
with open("$PSTATE/j.jsonl", encoding="utf-8") as fh:
    evs = [json.loads(l) for l in fh if l.strip()]
queued = [e for e in evs if e.get("event") == "health_queued"]
assert queued == [], f"expected no health_queued (slot not reserved), got {queued}"
print("slot free: health_queued NOT emitted when main-health done")
PYEOF
rm -f "$PSTATE/.main-health-$SHA"
pass
echo "PASS (b) LiveGates.health() slot reservation: main pending → WAIT, main done → dispatch"

# ── (c) Bash starvation: no-slot defers then dispatches on the next call ───────────────────────
# Source agent-watch.sh in lib mode, set up a fixture repo, plant a live PR inflight holder,
# call reconcile_main_health → should defer; remove holder, call again → should dispatch + collect.
BROOT="$T/bash"
BREPO="$BROOT/main"; BTREES="$BROOT/trees"
mkdir -p "$BREPO" "$BTREES" "$BTREES/.herd"

git init -q -b main "$BREPO"
git -C "$BREPO" config user.email sim@test; git -C "$BREPO" config user.name sim
printf 'init\n' > "$BREPO/README.md"
git -C "$BREPO" add -A; git -C "$BREPO" commit -q -m "init"

# Stub healthcheck that exits 0 (green).
_HC="$BROOT/hc.sh"
printf '#!/usr/bin/env bash\nprintf "0\tclean"\nexit 0\n' > "$_HC"
chmod +x "$_HC"

_BASH_JOURNAL="$BTREES/.herd/journal.jsonl"

# Run in a subshell that sources agent-watch.sh then reassigns fixture coords (same pattern as sim).
(
  set -uo pipefail
  # Stub out herd-config.sh with a nonexistent path so sourcing doesn't load the real project config.
  export HERD_CONFIG_FILE="$BROOT/no-such-config"
  export AGENT_WATCH_LIB=1
  export WORKTREES_DIR="$BTREES"
  export PROJECT_ROOT="$BREPO"
  export JOURNAL_FILE="$_BASH_JOURNAL"
  source "$WATCH" 2>/dev/null || true

  # Re-assign fixture coords AFTER the source (source sets TREES/MAIN from env; then we override).
  MAIN="$BREPO"; TREES="$BTREES"
  MAIN_HEALTH_STATE="$BTREES/.agent-watch-main-health"
  MAIN_HEALTH_DEFER="$BTREES/.agent-watch-main-health-defer"
  MAIN_HEALTH_FIX_STATE="$BTREES/.agent-watch-main-health-fix"
  MAIN_HEALTH_TICK=on
  HERD_HEALTHCHECK_BIN="$_HC"

  # Plant a live PR-health inflight holder (this subshell's PID is alive for the duration).
  _holder="$BTREES/.health-inflight-9999-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  printf '%s\n' "$$" > "$_holder"

  _jcount() { local c; c="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null || true)"; printf '%s' "${c:-0}"; }

  # First reconcile: slot occupied → should defer (infra_event reason=no-slot).
  n_before="$(_jcount '"infra_event"')"
  reconcile_main_health 2>/dev/null || true
  n_after="$(_jcount '"infra_event"')"
  deferred=$(( n_after - n_before ))
  [ "$deferred" -ge 1 ] || { printf 'FAIL: expected deferral, got deferred=%d\n' "$deferred" >&2; exit 1; }

  # Remove holder (simulating the PR suite completing) — slot now free.
  rm -f "$_holder"

  # Second reconcile: slot free → should dispatch.
  n_disp_before="$(_jcount '"result":"dispatched"')"
  reconcile_main_health 2>/dev/null || true

  # Settle: wait for the background suite to produce its dispatch file, then collect.
  n=0
  while [ "$n" -lt 200 ]; do
    ls "$BTREES"/.health-dispatch-main-* >/dev/null 2>&1 && break
    ls "$BTREES"/.health-inflight-main-* >/dev/null 2>&1 || break
    sleep 0.05; n=$((n+1))
  done
  _collect_main_health 2>/dev/null || true

  n_disp_after="$(_jcount '"result":"dispatched"')"
  dispatched=$(( n_disp_after - n_disp_before ))
  green="$(_jcount '"result":"green"')"
  [ "$dispatched" -ge 1 ] || { printf 'FAIL: no dispatch after slot freed (disp=%d)\n' "$dispatched" >&2; exit 1; }
  [ "$green"      -ge 1 ] || { printf 'FAIL: no green verdict collected (green=%d)\n' "$green"      >&2; exit 1; }
  printf 'OK bash: deferred=%d dispatched=%d green=%d\n' "$deferred" "$dispatched" "$green"
) || fail "(c) bash starvation: deferred-then-dispatch invariant broken"
pass
echo "PASS (c) bash starvation: no-slot defers, then dispatches+collects once slot is free"

printf '\nALL PASS (%d)\n' "$PASS"
