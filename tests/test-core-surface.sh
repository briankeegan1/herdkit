#!/usr/bin/env bash
# test-core-surface.sh — SIM-OF-SIMS for the CORE-SURFACE gate (CORE_SURFACE_GLOB, HERD-577).
#
# A "sim of sims": the thing under test is the gate leg that REQUIRES a sandbox-sim scorecard, so the
# scenarios themselves are STUBBED (HERD_CORE_SURFACE_SIM_DIR) and each stub emits a scorecard of the
# shape this suite wants to prove the gate reacts to. That keeps the proof hermetic and instant while
# still driving the REAL rail — the real match, the real seam map, the real async dispatch/collect,
# the real decide-path leg, and the real serialization prepass — through a real LiveTick walk.
#
#   (1) LIBRARY      — the shared bash implementation: glob resolver, merge-base-scoped match, the
#                      seam→scenario map, the jq-free scorecard read, and the worker's three verdicts
#   (2) CORE, NO SCORECARD → the gate REDS: no merge, `core_surface_gate result=fail`, ONE bounce on
#                      the `coresim` rail (never the health rail's budget)
#   (3) CORE, GREEN SCORECARD → merges, `core_surface_gate result=pass`
#   (4) TWO CORE PRs → SERIALIZE: only the lower-numbered lands; the other is visibly HELD
#                      (`core_surface_hold` + the render marker the console row reads)
#   (5) NON-CORE PR  → byte-identical: zero core_surface_* events, zero markers, merges
#   (6) LEVER OFF    — the SAME core worktree with an empty glob: byte-inert (no event, no marker,
#                      no dispatch), which is the ship-dormant contract
#   (7) SCENARIO ABSENT → SKIP, LOUDLY (`core_surface_skipped`) — never a silent pass
#   (8) CONSOLE ROW  — agent-watch.sh (lib mode) paints the calm "serialized behind PR #N" row from
#                      the SAME marker the walk wrote, and paints nothing when the lever is off
#
# Hermetic: no network, no gh, no real sandbox scenario, no merge (DryRunActuator). The health and
# review rails are short-circuited in the driver so the walk reaches the core leg and the merge
# decision without dispatching a suite or a reviewer.
#
# NO `# suite-deps:` header, deliberately: this file is name-paired with scripts/herd/core-surface.sh
# (the tests/test-<name>.sh ↔ scripts/herd/<name>.sh convention), which is all the diff-scoped
# selection needs. Declaring a dep on pysrc/herd/live_runtime.py would make that path MAPPABLE to a
# narrow selection, and HERD-585's fail-closed rule is that an unmappable engine-core path selects
# the FULL curated set — tests/test-suite-scope.sh (6) asserts exactly that.
# Run: bash tests/test-core-surface.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/herd/core-surface.sh"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$LIB" ] || { echo "FAIL: missing scripts/herd/core-surface.sh" >&2; exit 1; }

T="${HERD_CORE_SURFACE_KEEP:-$(mktemp -d)}"
[ -n "${HERD_CORE_SURFACE_KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
mkdir -p "$T"
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); echo "PASS: $1"; }

# The glob this suite gates on: two core files (one per seam) plus a decoy the fixtures never touch.
GLOB='^scripts/herd/(agent-watch|capacity-ledger)\.sh$|^pysrc/herd/live_runtime\.py$'

# ══ (1) the shared library ════════════════════════════════════════════════════════════════════════
# shellcheck source=scripts/herd/core-surface.sh
. "$LIB" || fail "(1) sourcing core-surface.sh failed"
for fn in herd_core_surface_glob herd_core_surface_enabled herd_core_surface_paths \
          herd_core_surface_scenarios herd_core_surface_scorecard_ok herd_core_surface_run; do
  type "$fn" >/dev/null 2>&1 || fail "(1) $fn not defined after sourcing"
done

CORE_SURFACE_GLOB="" herd_core_surface_enabled && fail "(1) an empty glob must read as the feature OFF"
CORE_SURFACE_GLOB="$GLOB" herd_core_surface_enabled || fail "(1) a non-empty glob must read as armed"
ok "(1a) the glob resolver is the one on/off answer"

# The seam map: each family lands on the scenario that actually models it, and an unmapped core path
# falls to the GATE scenario (fail toward MORE proof, never less).
[ "$(herd_core_surface_scenarios scripts/herd/agent-watch.sh)" = "sandbox-scenario.sh" ] \
  || fail "(1) agent-watch.sh must map to the gate scenario"
[ "$(herd_core_surface_scenarios scripts/herd/capacity-ledger.sh)" = "sandbox-concurrency-scenario.sh" ] \
  || fail "(1) capacity-ledger.sh must map to the concurrency scenario"
[ "$(herd_core_surface_scenarios scripts/herd/resolver-pane.sh)" = "sandbox-real-panes-scenario.sh" ] \
  || fail "(1) resolver-pane.sh must map to the panes scenario"
[ "$(herd_core_surface_scenarios pysrc/herd/anything_new.py)" = "sandbox-scenario.sh" ] \
  || fail "(1) an unmapped core path must fall to the gate scenario"
# Deduped AND stably ordered: two seats gating the same sha must dispatch the same argv.
GOT="$(herd_core_surface_scenarios scripts/herd/capacity-ledger.sh scripts/herd/agent-watch.sh pysrc/herd/live_runtime.py | tr '\n' ' ')"
[ "$GOT" = "sandbox-concurrency-scenario.sh sandbox-scenario.sh " ] \
  || fail "(1) scenarios must be deduped + stably sorted (got: $GOT)"
ok "(1b) the seam→scenario map is deduped, stable, and falls toward more proof"

# The scorecard read.
printf '{\n  "result": "pass",\n  "failed": 0\n}\n' > "$T/green.json"
printf '{\n  "result": "fail",\n  "failed": 3\n}\n' > "$T/red.json"
herd_core_surface_scorecard_ok "$T/green.json" || fail "(1) a result=pass scorecard must read green"
herd_core_surface_scorecard_ok "$T/red.json"   && fail "(1) a result=fail scorecard must NOT read green"
herd_core_surface_scorecard_ok "$T/nope.json"  && fail "(1) a MISSING scorecard must never read green"
[ "$(herd_core_surface_scorecard_result "$T/nope.json")" = "missing" ] \
  || fail "(1) a missing scorecard must report 'missing', not an empty string"
ok "(1c) the scorecard read is green ONLY on an existing result=pass"

# The match, against a real git tree: merge-base scoped, and NOT fooled by a non-core neighbour.
FIX="$T/fixture"; mkdir -p "$FIX"
git -C "$FIX" init -q 2>/dev/null || fail "(1) git init failed"
git -C "$FIX" config user.email t@e; git -C "$FIX" config user.name t
mkdir -p "$FIX/scripts/herd" "$FIX/docs"
printf 'base\n' > "$FIX/docs/readme.md"
git -C "$FIX" add -A >/dev/null; git -C "$FIX" commit -qm base >/dev/null
git -C "$FIX" branch -M main 2>/dev/null
git -C "$FIX" checkout -qb feat/noncore 2>/dev/null
printf 'edit\n' >> "$FIX/docs/readme.md"
git -C "$FIX" commit -aqm noncore >/dev/null
CORE_SURFACE_GLOB="$GLOB" herd_core_surface_paths "$FIX" main >/dev/null \
  && fail "(1) a docs-only diff must NOT match the core glob"
git -C "$FIX" checkout -qb feat/core main 2>/dev/null
printf 'watcher\n' > "$FIX/scripts/herd/agent-watch.sh"
git -C "$FIX" add -A >/dev/null; git -C "$FIX" commit -qm core >/dev/null
MATCHED="$(CORE_SURFACE_GLOB="$GLOB" herd_core_surface_paths "$FIX" main)" \
  || fail "(1) a core diff must match"
[ "$MATCHED" = "scripts/herd/agent-watch.sh" ] || fail "(1) wrong match: $MATCHED"
CORE_SURFACE_GLOB="" herd_core_surface_paths "$FIX" main >/dev/null \
  && fail "(1) an empty glob must never match, even on a core diff"
CORE_SURFACE_GLOB="$GLOB" herd_core_surface_paths "$T/not-a-repo" main; [ "$?" = "2" ] \
  || fail "(1) a non-git path must SKIP (rc 2), never claim 'not core'"
ok "(1d) the match is merge-base scoped, glob-gated, and skips (never lies) on an unreadable tree"

# ── the stub scenario dirs ────────────────────────────────────────────────────────────────────────
# GREEN: writes a result=pass scorecard.  RED: runs, writes NO scorecard at all (the literal
# "a core diff without a scorecard" case).  EMPTY: no scenario file at all.
mk_stub() { # mk_stub <dir> <green|nocard>
  mkdir -p "$1"
  cat > "$1/sandbox-scenario.sh" <<'STUB'
#!/usr/bin/env bash
ART=""
while [ $# -gt 0 ]; do case "$1" in --artifacts) ART="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$ART"
if [ -n "${STUB_WRITE_SCORECARD:-}" ]; then
  cat > "$ART/scorecard.json" <<'JSON'
{
  "scenario": "stub",
  "result": "pass",
  "passed": 1,
  "failed": 0,
  "skipped": 0
}
JSON
fi
exit 0
STUB
  # The GREEN stub bakes the write in; the NOCARD stub runs and produces nothing — the literal
  # "a core diff without a scorecard" case the gate has to red.
  [ "$2" = "green" ] && sed -i.bak 's/^if \[ -n "${STUB_WRITE_SCORECARD:-}" \]; then$/if true; then/' \
    "$1/sandbox-scenario.sh" && rm -f "$1/sandbox-scenario.sh.bak"
  chmod +x "$1/sandbox-scenario.sh"
}
mk_stub "$T/sim-green"  green
mk_stub "$T/sim-nocard" nocard
mkdir -p "$T/sim-empty"

# the worker's three verdicts, driven directly.
HERD_CORE_SURFACE_SIM_DIR="$T/sim-green" herd_core_surface_run "$T/w1" "$T/w1.out" "$T/w1.log" N1 sandbox-scenario.sh \
  || fail "(1) a green scenario must make the worker succeed"
grep -q $'^N1\tPASS\t' "$T/w1.out" || fail "(1) green worker line wrong: $(cat "$T/w1.out")"
HERD_CORE_SURFACE_SIM_DIR="$T/sim-nocard" herd_core_surface_run "$T/w2" "$T/w2.out" "$T/w2.log" N2 sandbox-scenario.sh
grep -q $'^N2\tFAIL\t' "$T/w2.out" || fail "(1) a run with no scorecard must be FAIL: $(cat "$T/w2.out")"
HERD_CORE_SURFACE_SIM_DIR="$T/sim-empty" herd_core_surface_run "$T/w3" "$T/w3.out" "$T/w3.log" N3 sandbox-scenario.sh
grep -q $'^N3\tSKIP\t' "$T/w3.out" || fail "(1) an ABSENT scenario must be SKIP, never PASS: $(cat "$T/w3.out")"
grep -q 'nothing was proven' "$T/w3.out" || fail "(1) the SKIP detail must say nothing was proven"
ok "(1e) the worker: green→PASS · ran-but-no-scorecard→FAIL · nothing-ran→SKIP (never a silent pass)"

# ══ the driver: real LiveTick walks with the REAL core-surface rail ═══════════════════════════════
cat > "$T/drive.py" <<'PY'
"""Drive real LiveTick walks with the core-surface rail LIVE; print each candidate's outcome.

argv: <state-dir> <journal> <config-json> <candidates-json>
Health and review are short-circuited (CLEAN/PASS) so the walk reaches the core leg and the merge
decision with no suite and no reviewer; everything else — the match, the dispatch, the collect, the
decide-path leg and the serialization prepass — is the shipped implementation.
"""
import json
import sys

from herd.live_runtime import (LiveTick, LiveState, LiveJournal, LiveGates,
                               FixtureDiscovery, DryRunActuator)

state_dir, jpath, cfg_json, cands_json = sys.argv[1:5]


class _CoreOnlyGates(LiveGates):
    def health(self, cand):
        self.reused_health = False
        return "CLEAN"

    def review(self, cand):
        self.reused_review = False
        return "PASS"


config = dict(json.loads(cfg_json))
config.setdefault("MERGE_POLICY", "auto")
config.setdefault("DEFAULT_BRANCH", "main")
journal = LiveJournal(jpath)
state = LiveState(state_dir)
home = sys.argv[5]
gates = _CoreOnlyGates(home, state, journal, config=config)
scenario = {"candidates": json.loads(cands_json), "config": config}
tick = LiveTick(config, FixtureDiscovery(scenario), gates, DryRunActuator(journal), journal,
                state=state)
sys.stdout.write(json.dumps(tick.run()["outcomes"]) + "\n")
PY

# drive <case> <sim-dir> <config-json> <candidates-json> — one tick.
drive() {
  local case="$1" simdir="$2" cfg="$3" cands="$4"
  mkdir -p "$T/$case"
  HERD_CORE_SURFACE_SIM_DIR="$simdir" PYTHONPATH="$REPO/pysrc" \
  HERD_JOURNAL_NOW="2026-08-10T00:00:00Z" \
    python3 "$T/drive.py" "$T/$case" "$T/$case/j.jsonl" "$cfg" "$cands" "$REPO"
}
# settle <case> — poll the tick until the async sim worker's out-file has been collected (or give up).
settle() {
  local case="$1" simdir="$2" cfg="$3" cands="$4" i out
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    out="$(drive "$case" "$simdir" "$cfg" "$cands")"
    case "$out" in *PENDING*) sleep 0.4 ;; *) printf '%s' "$out"; return 0 ;; esac
  done
  printf '%s' "$out"
}
ev()  { local n; n="$(grep -c "\"event\":\"$2\"" "$T/$1/j.jsonl" 2>/dev/null)"; printf '%s' "${n:-0}"; }
GLOB_JSON="${GLOB//\\/\\\\}"            # the glob's backslashes are JSON escapes until doubled
CFG_ON="{\"CORE_SURFACE_GLOB\":\"$GLOB_JSON\"}"
CFG_OFF='{"CORE_SURFACE_GLOB":""}'
CORE_WT="$FIX"           # currently on feat/core: a diff that touches scripts/herd/agent-watch.sh
CAND_1="[{\"pr\":\"11\",\"sha\":\"shaA\",\"slug\":\"core-a\",\"worktree\":\"$CORE_WT\"}]"

# ══ (2) core diff, NO scorecard → the gate REDS ═══════════════════════════════════════════════════
OUT="$(settle red "$T/sim-nocard" "$CFG_ON" "$CAND_1")" || fail "(2) driver errored"
grep -q '"11": *"MERGE"' <<<"$OUT" && fail "(2) a core diff with no green scorecard must NEVER merge"
grep -q '"result":"fail"' "$T/red/j.jsonl" || fail "(2) must journal core_surface_gate result=fail"
[ "$(ev red core_surface_dispatched)" -ge 1 ] || fail "(2) the sim must actually have been dispatched"
[ "$(ev red refix_bounce)" = "1" ] || fail "(2) expected exactly ONE bounce (got $(ev red refix_bounce))"
grep -q '"rule":"core-surface-sim"' "$T/red/j.jsonl" \
  || fail "(2) the bounce must ride the core-surface rail, not the health rail"
grep -q ' coresim$' "$T/red/.agent-watch-refixed" 2>/dev/null \
  || fail "(2) the bounce must be recorded on the SEPARATE coresim ledger rail"
ok "(2) a CORE diff whose sim produced no scorecard reds its gate and bounces on the coresim rail"

# ══ (3) core diff, GREEN scorecard → merges ═══════════════════════════════════════════════════════
OUT="$(settle green "$T/sim-green" "$CFG_ON" "$CAND_1")" || fail "(3) driver errored"
grep -q '"11": *"MERGE"' <<<"$OUT" || fail "(3) a green scorecard must let the core diff merge (got: $OUT)"
grep -q '"result":"pass"' "$T/green/j.jsonl" || fail "(3) must journal core_surface_gate result=pass"
[ "$(ev green refix_bounce)" = "0" ] || fail "(3) a green scorecard must bounce nobody"
# The verdict is sha-cached: a re-walk must NOT re-dispatch the sim.
BEFORE="$(ev green core_surface_dispatched)"
drive green "$T/sim-green" "$CFG_ON" "$CAND_1" >/dev/null
[ "$(ev green core_surface_dispatched)" = "$BEFORE" ] \
  || fail "(3) an unchanged head sha must REUSE the scorecard, never re-run the sim"
ok "(3) a green scorecard merges the core diff, and the verdict is reused for the same sha"

# ══ (4) two core PRs SERIALIZE, second visibly held ═══════════════════════════════════════════════
CAND_2="[{\"pr\":\"21\",\"sha\":\"shaB\",\"slug\":\"core-b\",\"worktree\":\"$CORE_WT\"},
         {\"pr\":\"12\",\"sha\":\"shaC\",\"slug\":\"core-c\",\"worktree\":\"$CORE_WT\"}]"
OUT="$(settle two "$T/sim-green" "$CFG_ON" "$CAND_2")" || fail "(4) driver errored"
grep -q '"12": *"MERGE"' <<<"$OUT" || fail "(4) the LOWER-numbered core PR is the front and must merge (got: $OUT)"
grep -q '"21": *"HOLD"' <<<"$OUT"  || fail "(4) the second core PR must HOLD, not merge (got: $OUT)"
grep -q '"event":"core_surface_hold".*"front_pr":12' "$T/two/j.jsonl" \
  || fail "(4) the hold must name the PR it waits on"
[ "$(ev two core_surface_window)" -ge 1 ] || fail "(4) the core window must be journaled for observability"
[ -f "$T/two/.core-surface-wait-21-shaB" ] \
  || fail "(4) the held PR must leave the render marker the console row reads"
[ "$(cat "$T/two/.core-surface-wait-21-shaB")" = "12" ] \
  || fail "(4) the render marker must carry the front PR number"
[ -f "$T/two/.core-surface-wait-12-shaC" ] \
  && fail "(4) the FRONT must never be marked as waiting on itself"
ok "(4) two core PRs serialize: the front merges, the second is held and says what it waits on"

# ══ (5) a NON-CORE PR is untouched ════════════════════════════════════════════════════════════════
git -C "$FIX" checkout -q feat/noncore 2>/dev/null
CAND_NC="[{\"pr\":\"31\",\"sha\":\"shaD\",\"slug\":\"docs\",\"worktree\":\"$CORE_WT\"}]"
OUT="$(drive noncore "$T/sim-nocard" "$CFG_ON" "$CAND_NC")" || fail "(5) driver errored"
grep -q '"31": *"MERGE"' <<<"$OUT" || fail "(5) a non-core PR must merge exactly as before (got: $OUT)"
grep -c '"event":"core_surface' "$T/noncore/j.jsonl" >/dev/null 2>&1 \
  && [ "$(grep -c '"event":"core_surface' "$T/noncore/j.jsonl")" != "0" ] \
  && fail "(5) a non-core PR must journal ZERO core_surface_* events"
ls "$T/noncore"/.core-surface-* >/dev/null 2>&1 && fail "(5) a non-core PR must leave NO core-surface marker"
ok "(5) a non-core diff is byte-identical: no event, no marker, merges unchanged"

# ══ (6) LEVER OFF is byte-inert, even on the very same core diff ══════════════════════════════════
git -C "$FIX" checkout -q feat/core 2>/dev/null
OUT="$(drive off "$T/sim-nocard" "$CFG_OFF" "$CAND_1")" || fail "(6) driver errored"
grep -q '"11": *"MERGE"' <<<"$OUT" || fail "(6) with the lever off a core diff must merge as before"
[ "$(grep -c '"event":"core_surface' "$T/off/j.jsonl")" = "0" ] \
  || fail "(6) an empty CORE_SURFACE_GLOB must journal NO core_surface_* event"
ls "$T/off"/.core-surface-* >/dev/null 2>&1 && fail "(6) an empty glob must write NO marker"
ok "(6) CORE_SURFACE_GLOB empty is ship-dormant: same merge, no event, no marker, no dispatch"

# ══ (7) an ABSENT scenario SKIPs LOUDLY ══════════════════════════════════════════════════════════
OUT="$(settle skip "$T/sim-empty" "$CFG_ON" "$CAND_1")" || fail "(7) driver errored"
grep -q '"verdict":"SKIP"' "$T/skip/j.jsonl" \
  || fail "(7) a run in which nothing could execute must record SKIP, never PASS"
grep -q '"event":"core_surface_gate"' "$T/skip/j.jsonl" \
  && fail "(7) a SKIP must not be recorded as a gate result (pass OR fail) — nothing was proven"
ok "(7) an absent sandbox scenario skips LOUDLY (journaled SKIP), never a silent pass"

# ══ (8) the console row reads the SAME marker the walk wrote ══════════════════════════════════════
export AGENT_WATCH_LIB=1 NO_COLOR=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T/two"; export TREES="$T/two"
export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT/.herd"
export WORKSPACE_NAME="coretest"; export JOURNAL_FILE="$T/console-journal.jsonl"
# shellcheck source=/dev/null
CORE_SURFACE_GLOB="$GLOB" . "$REPO/scripts/herd/agent-watch.sh" \
  || fail "(8) sourcing agent-watch.sh (lib mode) failed"
type _gate_phase_row >/dev/null 2>&1 || fail "(8) _gate_phase_row not defined"
ROW="$(CORE_SURFACE_GLOB="$GLOB" _gate_phase_row "core-b" " #21" 21 shaB "FALLBACK")"
grep -q 'serialized behind PR #12' <<<"$ROW" \
  || fail "(8) the console must paint the calm serialized row naming the front (got: $ROW)"
grep -q 'FALLBACK' <<<"$ROW" && fail "(8) the serialized row must REPLACE the fallback, not append to it"
ROW_OFF="$(CORE_SURFACE_GLOB="" _gate_phase_row "core-b" " #21" 21 shaB "FALLBACK")"
[ "$ROW_OFF" = "FALLBACK" ] \
  || fail "(8) with the lever off the row must be byte-identical to the fallback (got: $ROW_OFF)"
ok "(8) the console row is rendered from the SAME marker the gate wrote, and is inert when off"

echo "ALL PASS ($pass checks) — CORE_SURFACE_GLOB core-surface gate (HERD-577)"
