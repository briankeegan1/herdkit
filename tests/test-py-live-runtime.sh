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
#   (3) BYTE-IDENTICAL-OFF — the bash ENGINE_IMPL wiring (engine-version.sh) is a HARD no-op under the
#       ship default: herd_engine_impl resolves 'bash' for unset / bash / a typo / mis-cased 'PYTHON',
#       and herd_engine_live_tick returns NON-ZERO (so the watcher runs its own tick) having written
#       nothing — the guard `if herd_engine_live_tick; then …` in agent-watch.sh's loop is inert.
#   (4) ARMED FALLBACK (the kill-switch) — with ENGINE_IMPL=python but no reachable gh/repo, the live
#       tick fails discovery and returns NON-ZERO, so the bash supervisor instantly falls back to its
#       own authoritative tick. A port fault never stalls the watcher and never half-merges.
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

# ── (3) byte-identical-off: the bash seam is inert under the ship default ────────────────────────
for v in "" bash typo PYTHON shadow; do
  got="$(ENGINE_IMPL="$v" bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_impl')"
  case "$v" in
    shadow) [ "$got" = shadow ] || fail "ENGINE_IMPL=shadow resolved '$got'" ;;
    *)      [ "$got" = bash ]   || fail "ENGINE_IMPL='$v' should resolve bash, got '$got'" ;;
  esac
done
[ "$(ENGINE_IMPL=python bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_impl')" = python ] \
  || fail "ENGINE_IMPL=python did not resolve python"
# herd_engine_live_tick returns NON-ZERO (bash owns the tick) for every non-python posture, silently.
for v in "" bash shadow typo; do
  o="$(ENGINE_IMPL="$v" bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_live_tick' 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || fail "herd_engine_live_tick should fall back (rc!=0) for ENGINE_IMPL='$v'"
  [ -z "$o" ]     || fail "herd_engine_live_tick emitted output while disabled ('$o')"
done
pass

# ── (4) armed fallback (kill-switch): python armed + unreachable gh -> non-zero, safe fallback ───
# A live tick with no reachable gh/repo fails discovery; herd_engine_live_tick must return non-zero so
# the bash supervisor runs its own tick body. Point WORKTREES_DIR at an empty dir and confirm no real
# journal gains a gate event from the aborted tick.
mkdir -p "$T/live/.herd"
set +e
ENGINE_IMPL=python HERDKIT_HOME="$REPO" WORKTREES_DIR="$T/live" GH_TOKEN="" \
  PATH="/usr/bin:/bin" bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_live_tick' \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "armed live tick with unreachable gh should return non-zero (fallback)"
if [ -f "$T/live/.herd/journal.jsonl" ]; then
  grep -Eq '"event":"(merge|reap|verdict_recorded)"' "$T/live/.herd/journal.jsonl" \
    && fail "an aborted live tick leaked an actuation event into the real journal"
fi
pass

echo "ALL PASS ($PASS/6 live-runtime checks: unit invariants, full dry-run loop, dispatch-and-wait + scope, journal fail-loud, byte-identical-off, armed fallback)"
