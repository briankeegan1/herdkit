#!/usr/bin/env bash
# test-ci-as-gate.sh — GATE SIM for HEALTH_SOURCE=ci (HERD-578), driven with a stubbed `gh`.
#
# Under HEALTH_SOURCE=ci the watcher stops dispatching local PR suites and reads the PR's OWN GitHub
# Actions conclusion for its exact head sha as the health verdict. This suite drives the REAL gate
# rail (pysrc/herd/live_runtime.py's LiveGates.health, through a real LiveTick walk) with a fake `gh`
# on PATH, and proves every mapping end to end — plus the one thing that matters more than any of
# them: that HEALTH_SOURCE=local is byte-identical to before this feature existed.
#
#   (1) green checks-run for the head sha        → CLEAN, the PR merges
#   (2) red naming a real test                   → CODEERROR, ONE bounce carrying the extracted
#                                                  identity (the same kind=health rail a local red
#                                                  uses — never a second rail, never a second budget)
#   (3) run still in progress                    → WAIT (never a red, never a merge)
#   (4) cancelled-run chain                      → WAIT, QUALIFIED with the cancelled count
#   (5) CI absent entirely (no runs at all)      → falls back to the local rail, LOUDLY
#       (5b) gh missing from PATH altogether     → same loud fallback (fail-soft, never a red)
#   (6) HERD-609 infra signature                 → WAIT-infra-transient with exactly ONE bounded
#                                                  `gh run rerun --failed`, and NEVER a CODEERROR —
#                                                  a repeat tick re-reads and reruns nothing more
#   (7) HEALTH_SOURCE=local                      → ZERO gh calls, zero ci_* events: byte-inert
#
# Hermetic: no network, no real gh, no suite dispatch, no merge (DryRunActuator). The review rail is
# stubbed to PASS in the driver so the walk reaches a merge decision without shelling a reviewer.
# Run: bash tests/test-ci-as-gate.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$REPO/pysrc/herd/ci_verdict.py" ] || { echo "FAIL: missing pysrc/herd/ci_verdict.py" >&2; exit 1; }

T="${HERD_CI_GATE_SIM_KEEP:-$(mktemp -d)}"     # keep-the-tmp seam for debugging a failed assertion
[ -n "${HERD_CI_GATE_SIM_KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
mkdir -p "$T"
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); echo "PASS: $1"; }

# ── the gh stub: logs every argv line, answers from the scenario's env ────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
case "$1 $2" in
  "run list")  printf '%s\n' "${GH_RUNS:-[]}" ;;
  "run view")  printf '%s\n' "${GH_LOG:-}" ;;
  "run rerun") : ;;
  *) : ;;
esac
exit 0
GHSTUB
chmod +x "$BIN/gh"

# ── the driver: one real LiveTick walk over one candidate, health rail LIVE ───────────────────────
cat > "$T/drive.py" <<'PY'
"""Drive the REAL health rail for one candidate and print its terminal outcome.

argv: <state-dir> <journal> <pr> <sha> <branch> <worktree>
Everything but the health rail is the side-effect-free column: FixtureDiscovery for the candidate,
DryRunActuator for the merge/wake, and a review override so no reviewer is ever dispatched.
"""
import json
import sys

from herd import live_runtime as LR
from herd.live_runtime import (LiveTick, LiveState, LiveJournal, LiveGates,
                               FixtureDiscovery, DryRunActuator)

state_dir, jpath, pr, sha, branch, worktree = sys.argv[1:7]


class _ReviewlessGates(LiveGates):
    """The health rail exactly as it ships; the review rail short-circuited to PASS so the walk can
    reach a merge decision without shelling out to herd-review.sh."""

    def review(self, cand):
        self.reused_review = False
        return "PASS"


config = dict(json.loads(sys.argv[7]) if len(sys.argv) > 7 else {})
config.setdefault("MERGE_POLICY", "auto")
journal = LiveJournal(jpath)
state = LiveState(state_dir)
gates = _ReviewlessGates("/nonexistent-home", state, journal, config=config)
scenario = {"candidates": [{"pr": pr, "sha": sha, "slug": "feat-x", "branch": branch,
                            "worktree": worktree}], "config": config}
tick = LiveTick(config, FixtureDiscovery(scenario), gates, DryRunActuator(journal), journal,
                state=state)
res = tick.run()
sys.stdout.write(json.dumps(res["outcomes"]) + "\n")
PY

WT="$T/wt-absent"          # a path that is NOT a git worktree: the local rail REFUSES to dispatch a
                           # suite at it (dispatch_refused/no-worktree) instead of running one for real
CFG_CI='{"HEALTH_SOURCE":"ci"}'
drive() {
  # drive <scenario-dir> <pr> <sha> [config-json]
  local dir="$1" pr="$2" sha="$3" cfg="${4:-$CFG_CI}"
  mkdir -p "$T/$dir"
  GH_CALLS="$T/$dir/gh-calls.log" \
  PYTHONPATH="$REPO/pysrc" HERD_JOURNAL_NOW="2026-08-10T00:00:00Z" \
    python3 "$T/drive.py" "$T/$dir" "$T/$dir/j.jsonl" "$pr" "$sha" "feat/x" "$WT" "$cfg"
}
# grep -c prints 0 AND exits 1 on no-match, so a `|| printf 0` fallback would emit "00" — capture the
# count and default the empty case instead.
ev()    { local n; n="$(grep -c "\"event\":\"$2\"" "$T/$1/j.jsonl" 2>/dev/null)"; printf '%s' "${n:-0}"; }
hits()  { local n; n="$(grep -c "$2" "$T/$1/gh-calls.log" 2>/dev/null)"; printf '%s' "${n:-0}"; }
calls() { awk 'END{print NR+0}' "$T/$1/gh-calls.log" 2>/dev/null || printf 0; }

# ── (1) green → CLEAN → merge ─────────────────────────────────────────────────────────────────────
export GH_RUNS='[{"headSha":"shaG","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI","databaseId":101}]'
export GH_LOG=''
export GH_CALLS="$T/green/gh-calls.log"; mkdir -p "$T/green"; : > "$GH_CALLS"
OUT="$(PATH="$BIN:$PATH" drive green 1 shaG)" || fail "(1) driver errored"
grep -q '"1": *"MERGE"' <<< "$OUT" || fail "(1) a green CI run must merge (got: $OUT)"
grep -q '"reason":"ci-green"' "$T/green/j.jsonl" || fail "(1) must journal the ci-green verdict"
[ "$(ev green healthcheck_started)" = "0" ] || fail "(1) a CI-sourced verdict must dispatch NO local suite"
ok "(1) green checks-run for the head sha → CLEAN, the PR merges, no local suite runs"

# ── (2) red naming a real test → CODEERROR bounce carrying the extracted identity ─────────────────
export GH_RUNS='[{"headSha":"shaR","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI","databaseId":202}]'
export GH_LOG=$'ci-suite\t✗ tests/test-thing.sh (rc=1)\nci-suite\t✗ tests/test-other.sh\n'
export GH_CALLS="$T/red/gh-calls.log"; mkdir -p "$T/red"; : > "$GH_CALLS"
OUT="$(PATH="$BIN:$PATH" drive red 2 shaR)" || fail "(2) driver errored"
grep -q '"2": *"BLOCK"' <<< "$OUT" || fail "(2) a CI red must BLOCK, never merge (got: $OUT)"
grep -q '"reason":"ci-code-red"' "$T/red/j.jsonl" || fail "(2) must journal the ci-code-red verdict"
grep -q 'tests/test-thing.sh (rc=1),tests/test-other.sh' "$T/red/j.jsonl" \
  || fail "(2) the verdict must carry the identity extracted from the run's own log"
[ "$(ev red refix_bounce)" = "1" ] || fail "(2) expected exactly one bounce (got $(ev red refix_bounce))"
grep -q '"rule":"healthcheck"' "$T/red/j.jsonl" || fail "(2) the bounce must ride the health rail"
[ "$(ev red healthcheck_started)" = "0" ] || fail "(2) a CI red must dispatch NO local suite"
grep -q 'run view 202 --log-failed' "$T/red/gh-calls.log" || fail "(2) must read the failing run's own log"
ok "(2) red naming a real test → CODEERROR, one health-rail bounce with the extracted identity"

# ── (3) pending → WAIT ────────────────────────────────────────────────────────────────────────────
export GH_RUNS='[{"headSha":"shaP","status":"IN_PROGRESS","conclusion":null,"workflowName":"CI","databaseId":303}]'
export GH_LOG=''
export GH_CALLS="$T/pend/gh-calls.log"; mkdir -p "$T/pend"; : > "$GH_CALLS"
OUT="$(PATH="$BIN:$PATH" drive pend 3 shaP)" || fail "(3) driver errored"
grep -q '"3": *"PENDING"' <<< "$OUT" || fail "(3) an in-progress run must WAIT (got: $OUT)"
grep -q '"reason":"ci-pending"' "$T/pend/j.jsonl" || fail "(3) must journal the ci-pending verdict"
grep -q '"verdict":"CODEERROR"' "$T/pend/j.jsonl" && fail "(3) pending must NEVER read as a red"
ok "(3) a run still in progress → WAIT, never a red, never a merge"

# ── (4) cancelled chain → WAIT, qualified ─────────────────────────────────────────────────────────
export GH_RUNS='[{"headSha":"shaC","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"CI","databaseId":404},
                 {"headSha":"shaC","status":"COMPLETED","conclusion":"CANCELLED","workflowName":"CI","databaseId":405}]'
export GH_LOG=''
export GH_CALLS="$T/cxl/gh-calls.log"; mkdir -p "$T/cxl"; : > "$GH_CALLS"
OUT="$(PATH="$BIN:$PATH" drive cxl 4 shaC)" || fail "(4) driver errored"
grep -q '"4": *"PENDING"' <<< "$OUT" || fail "(4) a cancelled chain must WAIT (got: $OUT)"
grep -q '"reason":"ci-cancelled-chain"' "$T/cxl/j.jsonl" || fail "(4) must journal ci-cancelled-chain"
grep -q '"detail":"2 cancelled runs — awaiting a completed run"' "$T/cxl/j.jsonl" \
  || fail "(4) the WAIT must be QUALIFIED with the cancelled count, not a bare wait"
grep -q '"verdict":"CODEERROR"' "$T/cxl/j.jsonl" && fail "(4) a cancelled run must NEVER read as a red"
ok "(4) cancelled-run chain → WAIT, qualified with the cancelled count"

# ── (5) CI absent entirely → loud fallback to the local rail ──────────────────────────────────────
export GH_RUNS='[]'
export GH_LOG=''
export GH_CALLS="$T/absent/gh-calls.log"; mkdir -p "$T/absent"; : > "$GH_CALLS"
OUT="$(PATH="$BIN:$PATH" drive absent 5 shaA)" || fail "(5) driver errored"
grep -q '"reason":"ci-absent"' "$T/absent/j.jsonl" || fail "(5) must journal the LOUD ci-absent fallback"
[ "$(ev absent ci_health_fallback)" = "1" ] || fail "(5) the fallback must be journaled exactly once"
grep -q '"event":"dispatch_refused"' "$T/absent/j.jsonl" \
  || fail "(5) the fallback must reach the LOCAL health rail (it refused the absent worktree)"
grep -q '"5": *"MERGE"' <<< "$OUT" && fail "(5) an unverified PR must never merge on a fallback"
ok "(5) CI absent entirely → falls back to the local rail with a loud note"

# ── (5b) gh missing from PATH → the same loud fallback, never a red ───────────────────────────────
mkdir -p "$T/nogh"; : > "$T/nogh/gh-calls.log"
OUT="$(GH_CALLS="$T/nogh/gh-calls.log" PATH="/usr/bin:/bin" \
        PYTHONPATH="$REPO/pysrc" HERD_JOURNAL_NOW="2026-08-10T00:00:00Z" \
        python3 "$T/drive.py" "$T/nogh" "$T/nogh/j.jsonl" 6 shaN "feat/x" "$WT" \
        '{"HEALTH_SOURCE":"ci"}')" || fail "(5b) driver errored"
grep -q '"reason":"gh-unavailable"' "$T/nogh/j.jsonl" || fail "(5b) an unusable gh must fall back loudly"
grep -q '"verdict":"CODEERROR"' "$T/nogh/j.jsonl" && fail "(5b) an unusable gh must NEVER produce a red"
ok "(5b) an unreachable gh is fail-soft: loud fallback, never a red"

# ── (6) HERD-609: infra signature → WAIT-infra-transient + exactly ONE bounded rerun ──────────────
export GH_RUNS='[{"headSha":"shaI","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI","databaseId":606}]'
export GH_LOG=$'setup\tError: Failed to resolve action download info. Error: Service Unavailable\n'
export GH_CALLS="$T/infra/gh-calls.log"; mkdir -p "$T/infra"; : > "$GH_CALLS"
OUT="$(PATH="$BIN:$PATH" drive infra 7 shaI)" || fail "(6) driver errored"
grep -q '"7": *"PENDING"' <<< "$OUT" || fail "(6) an infra-transient red must WAIT (got: $OUT)"
grep -q '"reason":"ci-infra-transient"' "$T/infra/j.jsonl" || fail "(6) must journal ci-infra-transient"
grep -q '"verdict":"CODEERROR"' "$T/infra/j.jsonl" && fail "(6) an infra red must NEVER be a code red"
[ "$(ev infra refix_bounce)" = "0" ] || fail "(6) an infra red must never bounce the builder"
grep -q '"result":"rerun"' "$T/infra/j.jsonl" || fail "(6) must journal the bounded rerun it performed"
[ "$(hits infra 'run rerun 606 --failed')" = "1" ] \
  || fail "(6) expected exactly one rerun (got $(hits infra 'run rerun'))"
# A SECOND tick on the same still-red run re-reads live state and reruns NOTHING more (the bound).
OUT="$(PATH="$BIN:$PATH" drive infra 7 shaI)" || fail "(6b) second driver run errored"
[ "$(hits infra 'run rerun 606 --failed')" = "1" ] \
  || fail "(6b) the rerun is bounded to ONE per run id (got $(hits infra 'run rerun'))"
[ "$(hits infra 'run list')" -ge 2 ] \
  || fail "(6b) each tick must RE-READ CI state fresh (HERD-612), never reuse a cached verdict"
ok "(6) infra signature → WAIT-infra-transient, exactly one bounded rerun, re-read fresh each tick"

# ── (7) HEALTH_SOURCE=local is byte-inert: no gh call, no ci_* event ──────────────────────────────
export GH_RUNS='[{"headSha":"shaL","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI","databaseId":707}]'
export GH_CALLS="$T/local/gh-calls.log"; mkdir -p "$T/local"; : > "$GH_CALLS"
OUT="$(PATH="$BIN:$PATH" drive local 8 shaL '{}')" || fail "(7) driver errored"
[ "$(calls local)" = "0" ] || fail "(7) HEALTH_SOURCE=local must never call gh (got $(calls local) calls)"
grep -q '"event":"ci_health' "$T/local/j.jsonl" && fail "(7) HEALTH_SOURCE=local must journal no ci_* event"
grep -q '"8": *"MERGE"' <<< "$OUT" && fail "(7) local mode must not merge on CI's word"
grep -q '"event":"dispatch_refused"' "$T/local/j.jsonl" \
  || fail "(7) local mode must take the classic local dispatch path, unchanged"
# The same inertness for a typo'd value — a lever that cannot be read runs the AUTHORITATIVE suite.
export GH_CALLS="$T/typo/gh-calls.log"; mkdir -p "$T/typo"; : > "$GH_CALLS"
PATH="$BIN:$PATH" drive typo 9 shaL '{"HEALTH_SOURCE":"CI-please"}' >/dev/null || fail "(7b) driver errored"
[ "$(calls typo)" = "0" ] || fail "(7b) an unrecognized HEALTH_SOURCE must read as local (no gh call)"
ok "(7) HEALTH_SOURCE=local (and any unrecognized value) is byte-inert: no gh call, no ci_* event"

echo
echo "ALL PASS ($pass checks) — HEALTH_SOURCE=ci gate sim (HERD-578 / HERD-609 / HERD-612)"
