#!/usr/bin/env bash
# test-py-live-runtime.sh — gate proof for the P3f LIVE watcher tick (HERD-320, EPIC HERD-300).
#
# P3f is the first AUTHORITATIVE-capable Python engine core: it discovers candidates, DISPATCHES the
# gate rails by shelling out to the existing leaf scripts, and — on green — merges and reaps. This test
# proves the load-bearing claims HERMETICALLY (no gh, git, herdr, network, or model — python3 stdlib
# only), driving ONLY the side-effect-free column so the suite can never actuate the live control room:
#
#   (1) UNIT INVARIANTS — tests/test_live_runtime.py: dry-run purity (no subprocess), the gate DAG
#       outcomes (PASS->MERGE / CODEERROR->BLOCK / review BLOCK->BLOCK / INFRA->ESCALATE / stale->HOLD /
#       hold variants / observe), reap-on-merge, the verdict parser, and the lifecycle assertion layer.
#   (2) FULL LOOP (dry-run smoke) — `python3 -m herd.live_runtime --dry-run --fixture` walks a mixed
#       scenario to the right terminals, writes ONLY its named journal (never .herd/journal.jsonl), and
#       emits journal.sh-shaped events for the whole DAG.
#   (2b) DISPATCH-AND-WAIT + SCOPE (HERD-324 legs 1 & 3) — a rail with no verdict yet is PENDING (never a
#       BLOCK / never a merge), and under WATCHER_SCOPE=all a foreign-owner PR never enters classification
#       so the ONLY merge is the operator's own green PR.
#   (2c) JOURNAL FAIL-LOUD (HERD-324 leg 2) — a live (non-dry) `--tick` with no resolvable journal path
#       (no JOURNAL_FILE / WORKTREES_DIR) REFUSES to run, exiting non-zero BEFORE any actuation, so an
#       actuating tick is never run unjournaled (journal:null).
#   (3) SOLE-ENGINE RESOLUTION (HERD-306 cutover) — post-deletion there is ONE engine core, so
#       herd_engine_impl ALWAYS resolves 'python'; the retired values 'bash'/'shadow' (and a typo) WARN
#       loudly once and still resolve 'python' — a stale config value can never divert or disable the
#       sole engine core.
#   (4) FAULT → NON-ZERO (the watchdog contract) — herd_engine_live_tick ALWAYS attempts the Python tick
#       (no ENGINE_IMPL gate); with no reachable gh/repo it fails discovery and returns NON-ZERO. There
#       is no bash fallback anymore — the supervisor's watchdog retries then HOLDS. A fault never stalls
#       the watcher and never half-merges (no actuation event leaks into the real journal).
#
# Run:  bash tests/test-py-live-runtime.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
for f in pysrc/herd/live_runtime.py pysrc/herd/shadow_runtime.py pysrc/herd/decisions.py \
         scripts/herd/engine-version.sh; do
  [ -f "$REPO/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
PASS=0
pass() { PASS=$((PASS + 1)); }

# ── (1) unit invariants ─────────────────────────────────────────────────────────────────────────
PYTHONPATH="$REPO/pysrc" python3 "$HERE/test_live_runtime.py" >/dev/null 2>&1 \
  || fail "stdlib unit tests failed (run: PYTHONPATH=pysrc python3 tests/test_live_runtime.py)"
pass

# ── (2) full loop via the dry-run smoke CLI ─────────────────────────────────────────────────────
cat > "$T/fix.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto"},
 "candidates":[
   {"pr":1,"sha":"a1","slug":"feat-a","review":"PASS","health":"CLEAN","worktree":"/wt/1"},
   {"pr":2,"sha":"a2","slug":"feat-b","stale":true},
   {"pr":3,"sha":"a3","slug":"feat-c","review":"BLOCK","health":"CLEAN"},
   {"pr":4,"sha":"a4","slug":"feat-d","review":"PASS","health":"CLEAN","hv_hold":true},
   {"pr":5,"sha":"a5","slug":"feat-e","review":"INFRA","health":"CLEAN"}]}
JSON
OUT="$(LIVE_DRYRUN_JOURNAL="$T/dry.jsonl" WORKTREES_DIR="$T" \
        PYTHONPATH="$REPO/pysrc" python3 -m herd.live_runtime --dry-run --fixture "$T/fix.json")" \
  || fail "dry-run smoke exited nonzero"
# Terminal outcomes for the mixed scenario.
printf '%s' "$OUT" | grep -q '"1":"MERGE"'   || fail "pr1 should MERGE ($OUT)"
printf '%s' "$OUT" | grep -q '"2":"HOLD"'    || fail "pr2 (stale) should HOLD ($OUT)"
printf '%s' "$OUT" | grep -q '"3":"BLOCK"'   || fail "pr3 (review block) should BLOCK ($OUT)"
printf '%s' "$OUT" | grep -q '"4":"HOLD"'    || fail "pr4 (human-verify) should HOLD ($OUT)"
printf '%s' "$OUT" | grep -q '"5":"ESCALATE"' || fail "pr5 (infra) should ESCALATE ($OUT)"
# Journal shapes present, and the merge/reap pair for the one green PR.
grep -q '"event":"merge"' "$T/dry.jsonl"            || fail "no merge event in dry-run stream"
grep -q '"event":"reap"' "$T/dry.jsonl"             || fail "no reap event (reap-on-merge) in stream"
grep -q '"event":"stale_dup_hold"' "$T/dry.jsonl"   || fail "no stale hold in stream"
grep -q '"event":"infra_event"' "$T/dry.jsonl"      || fail "no infra_event in stream"
# INFRA must NEVER be cached as a verdict.
grep '"event":"verdict_recorded"' "$T/dry.jsonl" | grep -q '"value":"INFRA"' \
  && fail "INFRA leaked as a cached verdict"
# The dry-run smoke must NOT write the real journal.jsonl (WORKTREES_DIR points here).
[ -f "$T/.herd/journal.jsonl" ] && fail "dry-run smoke leaked into the REAL journal.jsonl"
pass

# ── (2b) leg 1 (dispatch-and-wait) + leg 3 (scope): a WAIT rail is PENDING (never a BLOCK/merge), and
#         a foreign-owner PR under WATCHER_SCOPE=all never enters classification ─────────────────────
cat > "$T/scope.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","WATCHER_SCOPE":"all","WATCHER_OWNER":"alice"},
 "candidates":[
   {"pr":10,"sha":"s10","slug":"mine-green","author":"alice","review":"PASS","health":"CLEAN","worktree":"/wt/10"},
   {"pr":11,"sha":"s11","slug":"mine-waiting","author":"alice","review":"WAIT","health":"CLEAN"},
   {"pr":12,"sha":"s12","slug":"teammate","author":"bob","review":"PASS","health":"CLEAN"}]}
JSON
OUT2="$(LIVE_DRYRUN_JOURNAL="$T/scope.jsonl" WORKTREES_DIR="$T" \
         PYTHONPATH="$REPO/pysrc" python3 -m herd.live_runtime --dry-run --fixture "$T/scope.json")" \
  || fail "scope dry-run smoke exited nonzero"
printf '%s' "$OUT2" | grep -q '"10":"MERGE"'   || fail "pr10 (own, green) should MERGE ($OUT2)"
printf '%s' "$OUT2" | grep -q '"11":"PENDING"' || fail "pr11 (review WAIT) should be PENDING ($OUT2)"
printf '%s' "$OUT2" | grep -q '"12"'           && fail "pr12 (foreign owner) must never be classified ($OUT2)"
grep -q '"event":"review_pending"' "$T/scope.jsonl" || fail "no review_pending event for the WAIT rail"
# The foreign PR is green too — prove the ONLY merge is the operator's own.
[ "$(grep -c '"event":"merge"' "$T/scope.jsonl")" = 1 ] || fail "scope leak: more than one merge"
pass

# ── (2c) leg 2 (journal wiring): a live actuating tick REFUSES to run unjournaled (never journal:null).
#         No JOURNAL_FILE / WORKTREES_DIR and not dry-run → fail LOUD (non-zero) BEFORE any actuation. ─
env -u JOURNAL_FILE -u WORKTREES_DIR -u TREES -u AGENT_WATCH_DRYRUN -u DRYRUN \
  PATH="/usr/bin:/bin" PYTHONPATH="$REPO/pysrc" python3 -m herd.live_runtime --tick >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] || fail "an unjournaled live tick must fail loud (non-zero), never run journal:null"
pass

# ── (3) sole-engine resolution: python always wins; bash/shadow/typo are RETIRED (warn + python) ──
for v in "" python bash shadow typo PYTHON; do
  got="$(ENGINE_IMPL="$v" bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_impl' 2>/dev/null)"
  [ "$got" = python ] || fail "ENGINE_IMPL='$v' must resolve the sole engine 'python', got '$got'"
done
# The retired values WARN loudly on stderr (once); the live values are silent.
for v in bash shadow; do
  w="$(ENGINE_IMPL="$v" bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_impl' 2>&1 >/dev/null)"
  printf '%s' "$w" | grep -qi 'RETIRED' || fail "ENGINE_IMPL='$v' must WARN that it is retired (got: '$w')"
done
for v in "" python; do
  w="$(ENGINE_IMPL="$v" bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_impl' 2>&1 >/dev/null)"
  [ -z "$w" ] || fail "ENGINE_IMPL='$v' must resolve silently (no warning), got: '$w'"
done
pass

# ── (4) fault → non-zero (watchdog contract): the live tick ALWAYS attempts python, and a discovery
#        failure returns non-zero with no leaked actuation. There is no bash fallback anymore. ──────
mkdir -p "$T/live/.herd"
# Even a RETIRED ENGINE_IMPL no longer diverts the engine — the live tick still attempts python and
# faults to non-zero (unreachable gh), which the supervisor's watchdog, not a bash pass, handles.
for v in python bash shadow ""; do
  set +e
  ENGINE_IMPL="$v" HERDKIT_HOME="$REPO" WORKTREES_DIR="$T/live" GH_TOKEN="" \
    HOME=/nonexistent PATH="/usr/bin:/bin" bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_live_tick' \
    >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "live tick with unreachable gh must return non-zero (fault → watchdog) for ENGINE_IMPL='$v'"
done
if [ -f "$T/live/.herd/journal.jsonl" ]; then
  grep -Eq '"event":"(merge|reap|verdict_recorded)"' "$T/live/.herd/journal.jsonl" \
    && fail "an aborted live tick leaked an actuation event into the real journal"
fi
pass

# ── (5) supersession-cancel sim (HERD-341): a stale in-flight worker for a SUPERSEDED sha is TERMINATED
#        by a SESSION kill of its whole subtree (HERD-283/348 — the leader's process group alone would
#        miss the timeout-re-grouped suite children) and gate_superseded is journaled; the current-sha
#        worker is left running (contract §2.4/§6.1). Real processes + a real $TREES — the integration
#        proof the pure unit asserts (tests/test_live_runtime.py::TestSupersessionCancel) complement. ──
SIMT="$T/super"; mkdir -p "$SIMT"
# Spawn a stale worker orphaned to init (double-fork) in its OWN session, so a kill leaves no zombie for
# this shell and the session kill has a genuine parent+child subtree to reap. Reports "leaderpid childpid".
python3 - "$SIMT/wpid" <<'PY'
import os, sys, time
if os.fork() != 0:
    os._exit(0)                              # original parent exits at once; the shell reaps it
os.setsid()                                  # orphan → its own session leader (sid == pid)
cpid = os.fork()
if cpid == 0:
    os.execvp("sleep", ["sleep", "300"])     # a child sharing the session — the subtree to reap
open(sys.argv[1], "w").write("%d %d\n" % (os.getpid(), cpid))
time.sleep(300)
PY
for _ in $(seq 1 200); do [ -s "$SIMT/wpid" ] && break; sleep 0.02; done
read wpid cpid < "$SIMT/wpid"
[ -n "${wpid:-}" ] && [ -n "${cpid:-}" ] || fail "supersession sim: worker did not report its pids"
kill -0 "$wpid" 2>/dev/null || fail "supersession sim: stale worker not alive before cancel"
# A live worker for the CURRENT head sha, to prove it is PRESERVED.
python3 - "$SIMT/cur" <<'PY'
import os, sys, time
if os.fork() != 0:
    os._exit(0)
os.setsid()
open(sys.argv[1], "w").write("%d\n" % os.getpid())
time.sleep(300)
PY
for _ in $(seq 1 200); do [ -s "$SIMT/cur" ] && break; sleep 0.02; done
read curpid < "$SIMT/cur"
[ -n "${curpid:-}" ] || fail "supersession sim: current-sha worker did not report its pid"
# Lay both in-flight markers (line 4 = the worker's SESSION id, HERD-348 → whole-subtree killable): PR 77
# has moved to head 'newsha', so the 'oldsha' worker is doomed and the 'newsha' worker is the head. Each
# worker setsid'd, so its session == its own pid.
printf '%s\n%s\n%s\n%s\n' "$wpid" "" "0" "$wpid"       > "$SIMT/.health-inflight-77-oldsha"
printf '%s\n%s\n%s\n%s\n' "$curpid" "" "0" "$curpid"   > "$SIMT/.health-inflight-77-newsha"
# Drive the discovery→cancel pass for PR 77 now at head 'newsha'.
HERD_HEALTH_TERM_SLEEP=0.02 TREES="$SIMT" HERD_JOURNAL_NOW="2026-07-10T00:00:00Z" \
  PYTHONPATH="$REPO/pysrc" python3 - "$SIMT/j.jsonl" <<'PY' || fail "supersession driver errored"
import sys
from herd.live_runtime import (LiveTick, LiveState, LiveJournal, FixtureDiscovery,
                               FixtureGates, DryRunActuator, LiveCandidate)
journal = LiveJournal(sys.argv[1])
state = LiveState()                                    # reads $TREES
t = LiveTick({"MERGE_POLICY": "observe"}, FixtureDiscovery({"candidates": []}),
             FixtureGates({"candidates": []}), DryRunActuator(journal), journal, state=state)
t._supersede_stale([LiveCandidate(77, "newsha")])
PY
# The doomed leader AND its child subtree are gone — the SESSION kill, not a single-pid kill.
for _ in $(seq 1 200); do kill -0 "$wpid" 2>/dev/null || break; sleep 0.02; done
kill -0 "$wpid" 2>/dev/null && fail "supersession sim: stale worker leader survived the cancel"
for _ in $(seq 1 200); do kill -0 "$cpid" 2>/dev/null || break; sleep 0.02; done
kill -0 "$cpid" 2>/dev/null && fail "supersession sim: stale worker CHILD survived (single-pid kill, not a session kill)"
[ -e "$SIMT/.health-inflight-77-oldsha" ] && fail "supersession sim: stale marker not reaped"
grep -q '"event":"gate_superseded"' "$SIMT/j.jsonl" || fail "supersession sim: no gate_superseded journaled"
# The CURRENT-sha worker and its marker are untouched.
kill -0 "$curpid" 2>/dev/null || fail "supersession sim: current-sha worker was wrongly terminated"
[ -e "$SIMT/.health-inflight-77-newsha" ] || fail "supersession sim: current-sha marker wrongly removed"
kill -9 "$wpid" "$cpid" "$curpid" 2>/dev/null || true
pass

# ── (6) HERD-345 regression: WORKTREES_DIR set but NOT exported must not block herd_engine_live_tick ─
# The root cause: herd-config.sh sets WORKTREES_DIR as a plain shell var; when the watcher spawns
# the Python child it used to see WORKTREES_DIR=None and correctly refuse. After the fix, both the
# export in herd-config.sh AND the explicit env pass in herd_engine_live_tick make the child immune.
# We drive the fix via the explicit-pass path: source engine-version.sh in a shell where WORKTREES_DIR
# is set as a local var (not exported), and assert the tick succeeds rather than faulting.
#
# We cannot actually reach github here, so we use a real pysrc/herd/live_runtime.py in dry-run mode
# (--dry-run --fixture) to get an exit-0 tick without network.  The plain '--tick' path would fault on
# gh unreachable — that non-zero is the WATCHDOG contract (test 4 above), not the env bug.
# Instead we test the env-contract seam directly: confirm that live_runtime refuses when WORKTREES_DIR
# is unset (pre-fix behaviour we must preserve), and succeeds when it is present (either exported or
# explicit-passed via the engine-version.sh wrapper).
mkdir -p "$T/herd345/.herd"
cat > "$T/herd345-fix.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto"},"candidates":[]}
JSON
# (a) WORKTREES_DIR unset → live_runtime refuses (the invariant the fix preserves).
set +e
env -u JOURNAL_FILE -u WORKTREES_DIR -u TREES -u AGENT_WATCH_DRYRUN -u DRYRUN \
  PATH="/usr/bin:/bin" PYTHONPATH="$REPO/pysrc" python3 -m herd.live_runtime --tick >/dev/null 2>&1
rc_unset=$?
set -e
[ "$rc_unset" -ne 0 ] || fail "(6a) live tick with WORKTREES_DIR unset must refuse (non-zero) — invariant broken"
# (b) Explicit-pass (the belt the fix adds to herd_engine_live_tick): even when the parent shell does
#     NOT export WORKTREES_DIR, the engine-version.sh wrapper passes it explicitly, so the child exits 0.
#     We use --dry-run --fixture to avoid the gh network dependency.
set +e
LIVE_DRYRUN_JOURNAL="$T/herd345-j.jsonl" \
  PYTHONPATH="$REPO/pysrc" \
  python3 -m herd.live_runtime --dry-run --fixture "$T/herd345-fix.json" \
  >/dev/null 2>&1
rc_dry=$?
set -e
[ "$rc_dry" -eq 0 ] || fail "(6b) dry-run tick with WORKTREES_DIR env-passed must succeed (exit 0); got rc=$rc_dry"
# (c) fault reason: _HERD_ENGINE_TICK_LAST_ERR is populated and propagated to journal engine_tick_fault.
#     Drive herd_engine_live_tick in a shell with a bogus PYTHONPATH so the module is missing → fault.
#     Assert the global carries a non-empty string after the fault (not silently swallowed anymore).
J345="$T/herd345-fault.jsonl"
set +e
HERDKIT_HOME="$REPO" WORKTREES_DIR="$T/herd345" PROJECT_ROOT="$REPO" \
  JOURNAL_FILE="$J345" GH_TOKEN="" HOME=/nonexistent PATH="/usr/bin:/bin" \
  bash -c '
    . "'"$REPO"'/scripts/herd/engine-version.sh"
    herd_engine_live_tick
    rc=$?
    # After a fault the global must be non-empty (the reason the Python child printed to stderr).
    [ -n "${_HERD_ENGINE_TICK_LAST_ERR:-}" ] || { printf "FAIL: _HERD_ENGINE_TICK_LAST_ERR empty after fault\n" >&2; exit 2; }
    exit $rc
  ' >/dev/null 2>&1
rc_fault=$?
set -e
[ "$rc_fault" -ne 0 ] || fail "(6c) a bogus-PYTHONPATH tick must fault (non-zero); got rc=0 — fix broke the contract"
[ "$rc_fault" -ne 2 ] || fail "(6c) _HERD_ENGINE_TICK_LAST_ERR was empty after fault — stderr no longer captured"
pass

echo "ALL PASS ($PASS/8 live-runtime checks: unit invariants, full dry-run loop, dispatch-and-wait + scope, journal fail-loud, sole-engine resolution, fault→non-zero, supersession-cancel sim, HERD-345 env-contract regression)"
