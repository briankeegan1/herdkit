#!/usr/bin/env bash
# test-budget-governance.sh — hermetic sandbox sim of the DAILY BUDGET GOVERNANCE rail (HERD-95).
#
# BUDGET_DAILY turns `herd cost`'s ledger into an ENFORCED ceiling. This test proves the whole rail
# end-to-end against a FIXTURE journal (real `cost` events, no merges, no network, no real lanes):
#
#   A. THE SUMMER (cost.sh cost_day_total / budget_daily_exceeded) — the daily total sums ONLY today's
#      (UTC) `cost` events' usd (prior-day events and non-cost events excluded), and the predicate is
#      DORMANT when BUDGET_DAILY is empty or non-numeric, TRUE only when today's spend strictly exceeds it.
#   B. WATCHER DRAIN PAUSE (_drain_spawn_queue, extracted from agent-watch.sh) — over budget → the drain
#      RETURNS without spawning, leaves the intent queued, and journals budget_drain_paused ONCE per
#      stretch; back under budget (or HERD_FORCE_SPAWN=1) → it drains normally + journals budget_drain_resumed.
#   C. LANE REFUSAL (real herd-quick.sh in a throwaway git sandbox) — over budget → the lane REFUSES with
#      a loud 🛑 line, creates NO worktree / starts NO agent, and journals budget_spawn_refused; --force
#      and HERD_FORCE_SPAWN=1 both OVERRIDE (spawn proceeds, budget_spawn_forced journaled).
#
# HERD-738 (the degradation ladder, per-item cap, forecast and manual rescue) extends this same rig:
#   D. THE LADDER PREDICATE (cost.sh budget_ladder_rung) — dormant unless BUDGET_LADDER=on AND
#      BUDGET_DAILY is set; rungs 1/2/3 fire at BUDGET_LADDER_RUNGS' ascending percent thresholds
#      (default 60/80/95); a partial-typo'd RUNGS list falls back per-field, never aborts.
#   E. CONCURRENCY REDUCTION (agent-watch.sh _review_conc/_health_conc, extracted) — rung >= 1 divides
#      the (GATE_SCALE-composed) floor by BUDGET_LADDER_CONCURRENCY_DIVISOR, floored at 1; byte-identical
#      pass-through at rung 0 / BUDGET_LADDER off.
#   F. THE FORECAST (cost.sh budget_forecast) — burn-rate + projected-EOD math against a deterministic
#      HERD_FORECAST_NOW; dormant (empty output) when BUDGET_DAILY is unset.
#   G. THE MANUAL RESCUE (cost.sh budget_override_set/clear/active) — journals `budget_override`
#      distinctly, and BYPASSES both budget_daily_exceeded and budget_ladder_rung while armed.
#   H. RUNG-3 TRIGGER POSTPONEMENT (triggers.sh triggers_run_one, sourced) — a non-critical trigger
#      (BUDGET_LADDER_NONCRITICAL_GLOB match) at rung 3 is skipped with its snapshot/last-fired
#      UNTOUCHED (a deferral) + budget_degrade_postponed journaled; a non-matching trigger still fires.
#   I. `herd budget` (real bin/herd, fixture project) — status/override/override --clear.
#
# DORMANCY (byte-identical when BUDGET_DAILY/BUDGET_LADDER/BUDGET_ITEM_MAX unset) is asserted
# throughout, plus fail-soft on a typo'd value.
# Run:  bash tests/test-budget-governance.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
COST="$ROOT/scripts/herd/cost.sh"
JOURNAL="$ROOT/scripts/herd/journal.sh"
WATCH="$ROOT/scripts/herd/agent-watch.sh"
STEP="$ROOT/scripts/herd/spawn-step.sh"
SPAWN="$ROOT/scripts/herd/spawn.sh"
QUICK="$ROOT/scripts/herd/herd-quick.sh"
TRIG="$ROOT/scripts/herd/triggers.sh"
HERD_BIN="$ROOT/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git    >/dev/null 2>&1 || fail "git required to run this test"

TODAY="$(date -u +%Y-%m-%d)"

# write_journal <dir> — a fixture .herd/journal.jsonl with today's spend = $7.50 (6.00 builder + 1.50
# review), plus a $100 prior-day cost event and a $50 today NON-cost event — both must be IGNORED.
write_journal() {
  local dir="$1"; mkdir -p "$dir/.herd"
  cat > "$dir/.herd/journal.jsonl" <<EOF
{"ts":"${TODAY}T10:00:00Z","event":"cost","component":"builder","pr":1,"usd":6.0}
{"ts":"${TODAY}T11:00:00Z","event":"cost","component":"review","pr":1,"usd":1.5}
{"ts":"2000-01-01T10:00:00Z","event":"cost","component":"builder","pr":2,"usd":100.0}
{"ts":"${TODAY}T12:00:00Z","event":"merge","pr":1,"usd":50.0}
EOF
}

# ══ Part A — the summer + predicate (cost.sh, sourced) ═══════════════════════════════════════════
WT_A="$T/a"; write_journal "$WT_A"
(
  set -uo pipefail
  # shellcheck source=/dev/null
  . "$JOURNAL"; . "$COST"
  export WORKTREES_DIR="$WT_A"
  # HERD-440: re-export JOURNAL_FILE to THIS fixture — journal.sh's JOURNAL_FILE test seam outranks
  # WORKTREES_DIR resolution (by design, so a forgetful test never pollutes a live journal), so under
  # scripts/ci/run-suite.sh (which pins JOURNAL_FILE suite-wide for that same reason) an unset override
  # here would silently read/write the WRONG file. Convention documented in run-suite.sh: "a test that
  # needs its own journal re-exports JOURNAL_FILE."
  export JOURNAL_FILE="$WT_A/.herd/journal.jsonl"

  total="$(cost_day_total)"
  case "$total" in 7.5*) : ;; *) fail "cost_day_total should sum ONLY today's cost usd (=7.50), got '$total'" ;; esac

  # Explicit day arg with no spend → 0 (prior-day-only assertion).
  z="$(cost_day_total 1999-12-31)"; case "$z" in 0*) : ;; *) fail "cost_day_total for an empty day should be 0, got '$z'" ;; esac

  # Dormant: empty / non-numeric BUDGET_DAILY → not exceeded, no output.
  BUDGET_DAILY=""  out="$(budget_daily_exceeded)"; rc=$?
  [ "$rc" -ne 0 ] || fail "empty BUDGET_DAILY must be DORMANT (return non-zero)"
  [ -z "$out" ]   || fail "dormant budget must emit nothing (got '$out')"
  BUDGET_DAILY="abc" out="$(budget_daily_exceeded)"; rc=$?
  [ "$rc" -ne 0 ] || fail "non-numeric BUDGET_DAILY must be treated as DORMANT (typo fail-soft)"

  # Under ceiling: 7.50 !> 10 → not exceeded.
  BUDGET_DAILY="10" budget_daily_exceeded >/dev/null && fail "7.50 must NOT exceed a 10 ceiling"

  # Over ceiling: 7.50 > 5 → exceeded, echoes "<spent> <cap>".
  BUDGET_DAILY="5" msg="$(budget_daily_exceeded)"; rc=$?
  [ "$rc" -eq 0 ] || fail "7.50 must EXCEED a 5 ceiling"
  case "$msg" in 7.5*" 5") : ;; *) fail "exceeded budget must echo '<spent> <cap>', got '$msg'" ;; esac
  echo "PART-A-OK"
) > "$T/parta.log" || exit 1
grep -q PART-A-OK "$T/parta.log" || exit 1
pass

# ══ Part B — watcher drain PAUSE (real budget predicate + fixture journal, extracted drain) ═══════
# Reuse the extraction harness from test-spawn-queue-drain.sh: real spawn-step.sh + fake lanes, but wire
# the REAL cost.sh/journal.sh so the pause decision flows journal → cost_day_total → budget_daily_exceeded.
ENG="$T/eng"; mkdir -p "$ENG"
cp "$STEP" "$ENG/spawn-step.sh"
TREES="$T/trees"; mkdir -p "$TREES/spawn-queue"
printf 'WORKTREES_DIR="%s"\nexport WORKTREES_DIR\n' "$TREES" > "$ENG/herd-config.sh"
write_journal "$TREES"
LANELOG="$T/lane.log"
for lane in herd-feature.sh herd-quick.sh; do
  cat > "$ENG/$lane" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$1" >> "$LANELOG"
exit 0
FAKE
  chmod +x "$ENG/$lane"
done

# Hermetic project config so spawn.sh's real herd-config.sh can't override WORKTREES_DIR to a real tree.
PROJ="$T/proj"; mkdir -p "$PROJ/.herd"
cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKSPACE_NAME="testws"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$TREES"
EOF
enqueue(){ ( cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$SPAWN" "$@" >/dev/null ); }

DRAIN_SRC="$T/drain.sh"
: > "$DRAIN_SRC"
# HERD-237: the drain fires its lane through a background worker behind an inflight marker.
for fn in _spawn_slug_key _spawn_inflight_file _lane_lifecycle_key _lane_lifecycle_spawn \
          _lane_lifecycle_retire _spawn_inflight_bg _spawn_inflight_sweep _lane_spawn_inflight \
          _drain_lane_worker _drain_spawn_queue; do
  sed -n "/^$fn()/,/^}/p" "$WATCH" >> "$DRAIN_SRC"
  grep -q "^$fn()" "$DRAIN_SRC" || fail "could not extract $fn from agent-watch.sh"
done

JLOG="$T/journal.evt"
# run_drain <BUDGET_DAILY> [FORCE] — one drain pass with the REAL budget predicate over the fixture journal.
run_drain() {
  ( export LANELOG JLOG
    HERE="$ENG"; TREES="$TREES"; FEATS=()
    SPAWN_INFLIGHT_PREFIX="$TREES/.spawn-inflight-"
    _marker_write(){ printf '%s\n' "$2" > "$1" 2>/dev/null || true; }
    _marker_live(){ local p; p="$(sed -n 1p "$1" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
    REVIEW_CONCURRENCY=2; SPAWN_AHEAD=1; DRYRUN=""
    export WORKTREES_DIR="$TREES"
    export JOURNAL_FILE="$TREES/.herd/journal.jsonl"   # HERD-440: see Part A note — re-export over any suite-wide pin
    export BUDGET_DAILY="$1"
    [ "${2:-}" = "force" ] && export HERD_FORCE_SPAWN=1
    _BUDGET_DRAIN_PAUSED=""
    # shellcheck source=/dev/null
    . "$JOURNAL"; . "$COST"
    journal_append(){ printf '%s\n' "$*" >> "$JLOG"; }   # log-only stub (overrides journal.sh's real one)
    . "$DRAIN_SRC"
    _drain_spawn_queue
    wait
    # A second tick while still over budget must NOT re-journal the pause (once per stretch).
    _drain_spawn_queue
    wait )
}

# Over budget (ceiling 5, spend 7.50) → PAUSE: no lane invoked, intent survives, budget_drain_paused ONCE.
enqueue slug-over quick "task while over budget"
: > "$LANELOG"; : > "$JLOG"
run_drain 5
grep -q '^herd-quick.sh' "$LANELOG" && fail "over-budget drain must NOT invoke any lane"$'\n'"$(cat "$LANELOG")"
ls "$TREES/spawn-queue"/*.req >/dev/null 2>&1 || fail "over-budget drain must LEAVE the intent queued (not consume it)"
[ "$(grep -c 'budget_drain_paused' "$JLOG")" = "1" ] || fail "budget_drain_paused must be journaled EXACTLY once per stretch ($(cat "$JLOG"))"
pass

# Over budget but HERD_FORCE_SPAWN=1 → override: the drain proceeds and spawns the queued intent.
: > "$LANELOG"; : > "$JLOG"
run_drain 5 force
grep -q '^herd-quick.sh slug-over' "$LANELOG" || fail "HERD_FORCE_SPAWN=1 must OVERRIDE the drain pause"$'\n'"$(cat "$LANELOG")"
pass

# Under budget (ceiling 100, spend 7.50) → drains normally.
enqueue slug-under quick "task under budget"
: > "$LANELOG"; : > "$JLOG"
run_drain 100
grep -q '^herd-quick.sh slug-under' "$LANELOG" || fail "under-budget drain must proceed normally"$'\n'"$(cat "$LANELOG")"
grep -q 'budget_drain_paused' "$JLOG" && fail "under-budget drain must NOT journal a pause"
pass

# Dormant (BUDGET_DAILY empty) → byte-identical to no budget: drains, no budget journal at all.
rm -f "$TREES/spawn-queue"/*.req 2>/dev/null || true
enqueue slug-dormant quick "task with no budget"
: > "$LANELOG"; : > "$JLOG"
run_drain ""
grep -q '^herd-quick.sh slug-dormant' "$LANELOG" || fail "dormant budget must drain (byte-identical to no budget)"
grep -q 'budget_' "$JLOG" && fail "dormant budget must journal NO budget event ($(cat "$JLOG"))"
pass

# ══ Part C — LANE refusal + override (real herd-quick.sh, throwaway git sandbox) ══════════════════
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "tab list")    printf '{"result":{"tabs":[]}}\n' ;;
  "tab create")  printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start") printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  "pane split")  printf '{"result":{"pane":{"pane_id":"pTest"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then printf '[]'; exit 0; fi
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

REPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
: > "$REPO/seed.txt"
git -C "$REPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null

export HOME="$T"                 # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit"
export HERD_SKIP_PREFLIGHT=1
export HERD_NO_APP=1
LTREES="$T/ltrees"; mkdir -p "$LTREES"
write_journal "$LTREES"          # $7.50 spent today, in this lane's own worktrees journal
export JOURNAL_FILE="$LTREES/.herd/journal.jsonl"   # HERD-440: see Part A note — re-export over any suite-wide pin
CFG="$T/lane-config"; export HERD_CONFIG_FILE="$CFG"
cat > "$CFG" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$LTREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit"
APP_PREVIEW_CMD=""
REVIEW_CONCURRENCY="2"
SPAWN_AHEAD="1"
BUDGET_DAILY="5"
EOF

# run_quick <slug> [--force] — run the real quick lane; capture output + rc + the herdr call log.
run_quick() {
  local slug="$1"; shift
  export HERDR_CALL_LOG="$T/$slug.herdr.log"; : > "$HERDR_CALL_LOG"
  OUT="$T/$slug.out"
  bash "$QUICK" "$@" "$slug" "do a thing" > "$OUT" 2>&1
  echo $?
}
started(){ grep -q "agent start" "$T/$1.herdr.log"; }

# C1: over budget, no force → REFUSE loudly, exit 1, no worktree, no agent start, budget_spawn_refused.
rc="$(run_quick refuse-me)"
[ "$rc" = "1" ] || fail "over-budget lane must exit 1 (got $rc)"$'\n'"$(cat "$T/refuse-me.out")"
grep -q '🛑' "$T/refuse-me.out"          || fail "refusal must print a loud 🛑 line"$'\n'"$(cat "$T/refuse-me.out")"
grep -q 'BUDGET_DAILY' "$T/refuse-me.out" || fail "refusal must name BUDGET_DAILY"$'\n'"$(cat "$T/refuse-me.out")"
grep -q 'HERD_FORCE_SPAWN' "$T/refuse-me.out" || fail "refusal must advertise the HERD_FORCE_SPAWN override"$'\n'"$(cat "$T/refuse-me.out")"
started refuse-me           && fail "over-budget lane must NOT start an agent"
[ -e "$LTREES/refuse-me" ]  && fail "over-budget lane must NOT create a worktree"
grep -q 'budget_spawn_refused' "$LTREES/.herd/journal.jsonl" || fail "refusal must journal budget_spawn_refused"
pass

# C2: over budget + --force flag → OVERRIDE (spawn proceeds; agent started; budget_spawn_forced).
rc="$(run_quick force-flag --force)"
[ "$rc" = "0" ] || fail "--force must let an over-budget spawn proceed (rc=$rc)"$'\n'"$(cat "$T/force-flag.out")"
started force-flag || fail "--force: an agent should have been started"$'\n'"$(cat "$T/force-flag.out")"
grep -q 'force set' "$T/force-flag.out" || fail "--force must print the override notice"$'\n'"$(cat "$T/force-flag.out")"
grep -q 'budget_spawn_forced' "$LTREES/.herd/journal.jsonl" || fail "--force override must journal budget_spawn_forced"
pass

# C3: over budget + HERD_FORCE_SPAWN=1 env → OVERRIDE (spawn proceeds).
rc="$( HERD_FORCE_SPAWN=1 run_quick force-env )"
[ "$rc" = "0" ] || fail "HERD_FORCE_SPAWN=1 must let an over-budget spawn proceed (rc=$rc)"$'\n'"$(cat "$T/force-env.out")"
started force-env || fail "HERD_FORCE_SPAWN=1: an agent should have been started"$'\n'"$(cat "$T/force-env.out")"
pass

# C4: DORMANT — empty BUDGET_DAILY → the lane proceeds byte-identically (no refusal, agent started).
sed -i.bak 's/^BUDGET_DAILY="5"/BUDGET_DAILY=""/' "$CFG"; rm -f "$CFG.bak"
rc="$(run_quick dormant-lane)"
[ "$rc" = "0" ] || fail "dormant budget: lane must proceed (rc=$rc)"$'\n'"$(cat "$T/dormant-lane.out")"
started dormant-lane || fail "dormant budget: agent should have been started"$'\n'"$(cat "$T/dormant-lane.out")"
grep -q '🛑' "$T/dormant-lane.out" && fail "dormant budget must print NO refusal line"
pass

# ══ Part D — the LADDER PREDICATE (cost.sh budget_ladder_rung, sourced) ═══════════════════════════
# A clean $<N> spend against BUDGET_DAILY=100 makes the spend PERCENT equal N, so a rung boundary is
# exactly N.
write_journal_spend() {
  local dir="$1" usd="$2"; mkdir -p "$dir/.herd"
  printf '{"ts":"%sT09:00:00Z","event":"cost","component":"builder","pr":9,"usd":%s}\n' "$TODAY" "$usd" \
    > "$dir/.herd/journal.jsonl"
}
WT_D="$T/d"
(
  set -uo pipefail
  . "$JOURNAL"; . "$COST"
  export WORKTREES_DIR="$WT_D"
  export JOURNAL_FILE="$WT_D/.herd/journal.jsonl"
  export BUDGET_DAILY=100 BUDGET_LADDER=on

  write_journal_spend "$WT_D" 50
  [ "$(budget_ladder_rung)" = "0" ] || fail "50% spend must be rung 0, got '$(budget_ladder_rung)'"
  write_journal_spend "$WT_D" 60
  [ "$(budget_ladder_rung)" = "1" ] || fail "60% spend (rung-1 threshold) must be rung 1, got '$(budget_ladder_rung)'"
  write_journal_spend "$WT_D" 79
  [ "$(budget_ladder_rung)" = "1" ] || fail "79% spend must still be rung 1, got '$(budget_ladder_rung)'"
  write_journal_spend "$WT_D" 80
  [ "$(budget_ladder_rung)" = "2" ] || fail "80% spend (rung-2 threshold) must be rung 2, got '$(budget_ladder_rung)'"
  write_journal_spend "$WT_D" 95
  [ "$(budget_ladder_rung)" = "3" ] || fail "95% spend (rung-3 threshold) must be rung 3, got '$(budget_ladder_rung)'"
  write_journal_spend "$WT_D" 200
  [ "$(budget_ladder_rung)" = "3" ] || fail "spend past the ceiling must still cap at rung 3, got '$(budget_ladder_rung)'"

  # Custom BUDGET_LADDER_RUNGS.
  write_journal_spend "$WT_D" 30
  BUDGET_LADDER_RUNGS="20,40,60" out="$(budget_ladder_rung)"
  [ "$out" = "1" ] || fail "custom RUNGS=20,40,60 at 30% must be rung 1, got '$out'"
  # A partial typo falls back per-field, not all-or-nothing.
  BUDGET_LADDER_RUNGS="20,abc,60" out="$(budget_ladder_rung)"   # field 2 → default 80
  [ "$out" = "1" ] || fail "typo'd RUNGS field must fall back to ITS OWN default, not abort, got '$out'"

  # DORMANT: BUDGET_LADDER off → always 0, whatever the spend.
  write_journal_spend "$WT_D" 99
  BUDGET_LADDER=off out="$(budget_ladder_rung)"
  [ "$out" = "0" ] || fail "BUDGET_LADDER=off must always read rung 0, got '$out'"
  # DORMANT: BUDGET_LADDER=on but BUDGET_DAILY empty → always 0 (nothing to rung on).
  BUDGET_LADDER=on BUDGET_DAILY="" out="$(budget_ladder_rung)"
  [ "$out" = "0" ] || fail "BUDGET_LADDER=on with no BUDGET_DAILY must read rung 0, got '$out'"
  echo "PART-D-OK"
) > "$T/partd.log" || exit 1
grep -q PART-D-OK "$T/partd.log" || { cat "$T/partd.log" >&2; exit 1; }
pass

# ══ Part E — CONCURRENCY REDUCTION (agent-watch.sh _review_conc/_health_conc, extracted) ══════════
CONC_SRC="$T/conc.sh"
: > "$CONC_SRC"
for fn in _gate_scale_enabled _gate_scale_cores _gate_scale_builders _gate_scale_derive \
          _gate_scale_journal_once _budget_ladder_reduce_conc _review_conc _health_conc; do
  sed -n "/^$fn()[[:space:]]*{/,/^}/p" "$WATCH" >> "$CONC_SRC"
  grep -q "^$fn()" "$CONC_SRC" || fail "could not extract $fn from agent-watch.sh"
done
WT_E="$T/e"
(
  set -uo pipefail
  . "$JOURNAL"; . "$COST"
  export WORKTREES_DIR="$WT_E"
  export JOURNAL_FILE="$WT_E/.herd/journal.jsonl"
  write_journal_spend "$WT_E" 80
  export BUDGET_DAILY=100 BUDGET_LADDER=on GATE_SCALE=off
  REVIEW_CONCURRENCY=6; HEALTH_CONCURRENCY=4
  herd_numeric() { local k="$1" d="$2" v; eval "v=\"\${$k:-}\""; case "$v" in ''|*[!0-9]*) printf '%s' "$d" ;; *) printf '%s' "$v" ;; esac; }
  _GATE_SCALE_LAST_SIG=""
  journal_append(){ :; }   # quiet stub — this part proves the NUMBER, not the journal line
  # shellcheck source=/dev/null
  . "$CONC_SRC"

  # 80% spend → rung 2 (>=1) → REVIEW_CONCURRENCY 6/2=3, HEALTH_CONCURRENCY 4/2=2 (default divisor).
  [ "$(_review_conc)" = "3" ] || fail "rung >=1 must halve REVIEW_CONCURRENCY 6→3, got '$(_review_conc)'"
  [ "$(_health_conc)" = "2" ] || fail "rung >=1 must halve HEALTH_CONCURRENCY 4→2, got '$(_health_conc)'"

  # A custom divisor of 4: 6/4=1 (int division), floored at 1 either way.
  BUDGET_LADDER_CONCURRENCY_DIVISOR=4
  [ "$(_review_conc)" = "1" ] || fail "divisor=4 on REVIEW_CONCURRENCY=6 must floor-divide to 1, got '$(_review_conc)'"
  BUDGET_LADDER_CONCURRENCY_DIVISOR=2

  # Below rung 1 (spend 50%) → pass-through, unchanged.
  write_journal_spend "$WT_E" 50
  [ "$(_review_conc)" = "6" ] || fail "below rung 1, REVIEW_CONCURRENCY must be unchanged, got '$(_review_conc)'"
  [ "$(_health_conc)" = "4" ] || fail "below rung 1, HEALTH_CONCURRENCY must be unchanged, got '$(_health_conc)'"

  # BUDGET_LADDER off → byte-identical pass-through even at 80% spend.
  write_journal_spend "$WT_E" 80
  BUDGET_LADDER=off
  [ "$(_review_conc)" = "6" ] || fail "BUDGET_LADDER=off must be byte-identical (REVIEW_CONCURRENCY), got '$(_review_conc)'"
  [ "$(_health_conc)" = "4" ] || fail "BUDGET_LADDER=off must be byte-identical (HEALTH_CONCURRENCY), got '$(_health_conc)'"
  echo "PART-E-OK"
) > "$T/parte.log" || exit 1
grep -q PART-E-OK "$T/parte.log" || { cat "$T/parte.log" >&2; exit 1; }
pass

# ══ Part F — THE FORECAST (cost.sh budget_forecast, sourced) ══════════════════════════════════════
WT_F="$T/f"
(
  set -uo pipefail
  . "$JOURNAL"; . "$COST"
  export WORKTREES_DIR="$WT_F"
  export JOURNAL_FILE="$WT_F/.herd/journal.jsonl"
  write_journal_spend "$WT_F" 12

  # Dormant: no BUDGET_DAILY → empty output, rc != 0.
  BUDGET_DAILY="" out="$(budget_forecast)"; rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ] || fail "budget_forecast must be dormant with no BUDGET_DAILY (rc=$rc out='$out')"

  # 12 hours into the UTC day, $12 spent → burn $1.00/hr → projected EOD = 12 + 1*12 = 24.
  BUDGET_DAILY=40 HERD_FORECAST_NOW="12:00:00" out="$(budget_forecast)"
  set -- $out
  spent="$1"; burn="$2"; proj="$3"; cap="$4"
  case "$spent" in 12.00000*) : ;; *) fail "forecast spent should be 12.0, got '$spent'" ;; esac
  case "$burn"  in 1.000000|1.0000000*) : ;; *) fail "forecast burn should be ~1.0/hr, got '$burn'" ;; esac
  case "$proj"  in 24.00000*) : ;; *) fail "forecast projected EOD should be ~24.0, got '$proj'" ;; esac
  case "$cap"   in 40.00000*) : ;; *) fail "forecast cap should echo BUDGET_DAILY=40, got '$cap'" ;; esac
  echo "PART-F-OK"
) > "$T/partf.log" || exit 1
grep -q PART-F-OK "$T/partf.log" || { cat "$T/partf.log" >&2; exit 1; }
pass

# ══ Part G — THE MANUAL RESCUE (cost.sh budget_override_set/clear/active, sourced) ═════════════════
WT_G="$T/g"
(
  set -uo pipefail
  . "$JOURNAL"; . "$COST"
  export WORKTREES_DIR="$WT_G"
  export JOURNAL_FILE="$WT_G/.herd/journal.jsonl"
  write_journal_spend "$WT_G" 200
  export BUDGET_DAILY=100 BUDGET_LADDER=on

  budget_override_active && fail "override must start INACTIVE"
  budget_daily_exceeded >/dev/null || fail "sanity: 200 spend on a 100 ceiling must exceed BEFORE any override"
  [ "$(budget_ladder_rung)" = "3" ] || fail "sanity: 200%% spend must be rung 3 BEFORE any override"

  budget_override_set "operator judged this safe"
  budget_override_active || fail "override_set must ARM the marker"
  budget_daily_exceeded >/dev/null && fail "an ARMED override must bypass budget_daily_exceeded"
  [ "$(budget_ladder_rung)" = "0" ] || fail "an ARMED override must force the ladder to rung 0, got '$(budget_ladder_rung)'"
  grep -q 'action":"set' "$WT_G/.herd/journal.jsonl" || fail "budget_override_set should have journaled action=set to WORKTREES_DIR's journal"

  budget_override_clear
  budget_override_active && fail "override_clear must DISARM the marker"
  budget_daily_exceeded >/dev/null || fail "clearing the override must restore ENFORCEMENT (200 over 100)"
  [ "$(budget_ladder_rung)" = "3" ] || fail "clearing the override must restore the ladder rung, got '$(budget_ladder_rung)'"
  echo "PART-G-OK"
) > "$T/partg.log" || exit 1
grep -q PART-G-OK "$T/partg.log" || { cat "$T/partg.log" >&2; exit 1; }
pass

# ══ Part H — RUNG-3 TRIGGER POSTPONEMENT (triggers.sh triggers_run_one, sourced) ═══════════════════
WT_H="$T/h"; TDIR_H="$WT_H/.herd/trigger-state"
(
  set -uo pipefail
  . "$JOURNAL"; . "$COST"
  export WORKTREES_DIR="$WT_H"
  export JOURNAL_FILE="$WT_H/.herd/journal.jsonl"
  write_journal_spend "$WT_H" 99
  export BUDGET_DAILY=100 BUDGET_LADDER=on
  export HERD_TRIGGERS_STATE_DIR="$TDIR_H" HERD_TRIGGERS_INPUT_DIR="$T"
  # shellcheck source=/dev/null
  . "$TRIG"

  # A non-critical (gardener-shaped) trigger name is POSTPONED at rung 3: no spawn, snapshot untouched.
  out="$(HERD_TRIGGERS_SPAWN_CMD="$T/should-not-run.sh" triggers_run_one maintenance-gardener @weekly quick "task {item}" 'echo item-x')"
  case "$out" in *postponed*) : ;; *) fail "a non-critical trigger at rung 3 must report postponed, got: $out" ;; esac
  [ -f "$(_triggers_snapshot_file maintenance-gardener)" ] && fail "a postponed trigger must NOT write a snapshot (it never ran)"
  grep -q 'budget_degrade_postponed' "$JOURNAL_FILE" || fail "postponement must journal budget_degrade_postponed"

  # A trigger name NOT matching the noncritical glob still fires normally even at rung 3.
  RAN="$T/ran-marker"
  triggers_run_one deploy-check @daily mechanical 'touch '"$RAN" 'echo item-y' >/dev/null
  [ -f "$RAN" ] || fail "a trigger NOT matching BUDGET_LADDER_NONCRITICAL_GLOB must still fire at rung 3"

  # BUDGET_LADDER off → the SAME gardener-named trigger fires (byte-identical to no ladder).
  BUDGET_LADDER=off
  RAN2="$T/ran-marker-2"
  triggers_run_one maintenance-gardener @weekly mechanical 'touch '"$RAN2" 'echo item-z' >/dev/null
  [ -f "$RAN2" ] || fail "BUDGET_LADDER=off must let even a gardener-named trigger fire normally"
  echo "PART-H-OK"
) > "$T/parth.log" || exit 1
grep -q PART-H-OK "$T/parth.log" || { cat "$T/parth.log" >&2; exit 1; }
pass

# ══ Part I — `herd budget` (real bin/herd, fixture project) ════════════════════════════════════════
WT_I="$T/i"; mkdir -p "$WT_I"
PROJ_I="$T/proj-i"; mkdir -p "$PROJ_I/.herd"
cat > "$PROJ_I/.herd/config" <<EOF
PROJECT_ROOT="$PROJ_I"
WORKSPACE_NAME="testws-i"
WORKTREES_DIR="$WT_I"
BUDGET_DAILY="100"
BUDGET_LADDER="on"
EOF
write_journal_spend "$WT_I" 80
# HERD-440: an earlier part's `export JOURNAL_FILE` outranks WORKTREES_DIR resolution and otherwise
# leaks into this part's child `herd` invocations — re-export over it, mirroring every other part here.
run_budget() { HERD_CONFIG_FILE="$PROJ_I/.herd/config" JOURNAL_FILE="$WT_I/.herd/journal.jsonl" bash "$HERD_BIN" budget "$@"; }

OUT_STATUS="$(run_budget status)"
grep -q 'BUDGET_DAILY:.*100' <<<"$OUT_STATUS"   || fail "herd budget status must show BUDGET_DAILY"$'\n'"$OUT_STATUS"
grep -q 'ladder rung:.*2/3'  <<<"$OUT_STATUS"   || fail "herd budget status must show the current ladder rung (80%% → 2)"$'\n'"$OUT_STATUS"
grep -qi 'under budget'      <<<"$OUT_STATUS"   || fail "herd budget status must show the ceiling is not yet exceeded"$'\n'"$OUT_STATUS"
pass

OUT_OV="$(run_budget override "proving HERD-738")"
grep -q 'ARMED' <<<"$OUT_OV" || fail "herd budget override must confirm ARMED"$'\n'"$OUT_OV"
grep -q 'budget_override' "$WT_I/.herd/journal.jsonl" || fail "herd budget override must journal budget_override"
grep -q 'action":"set'      "$WT_I/.herd/journal.jsonl" || fail "herd budget override must journal action=set"
OUT_STATUS2="$(run_budget status)"
grep -q 'ARMED' <<<"$OUT_STATUS2" || fail "herd budget status must reflect the armed override"$'\n'"$OUT_STATUS2"
pass

OUT_CLR="$(run_budget override --clear)"
grep -qi 'cleared' <<<"$OUT_CLR" || fail "herd budget override --clear must confirm cleared"$'\n'"$OUT_CLR"
grep -q 'action":"clear' "$WT_I/.herd/journal.jsonl" || fail "herd budget override --clear must journal action=clear"
pass

# ══ Part J — BUDGET ITEM CAP (agent-watch.sh build_budget_item_rows, extracted) ════════════════════
ITEM_SRC="$T/item.sh"
: > "$ITEM_SRC"
for fn in _budget_item_seen_once build_budget_item_rows; do
  sed -n "/^$fn()[[:space:]]*{/,/^}/p" "$WATCH" >> "$ITEM_SRC"
  grep -q "^$fn()" "$ITEM_SRC" || fail "could not extract $fn from agent-watch.sh"
done
WT_J="$T/j"; WTDIR_J="$WT_J/some-builder"
mkdir -p "$WTDIR_J"
# A fixture Claude transcript dir + price table where ONE assistant message with output_tokens=20
# prices at EXACTLY $20 (out price pinned to $1,000,000/M tokens — deterministic, no real model math).
TDIR_J="$T/herd-test-journal-project--some-builder"   # any munged-looking name; _cost_transcript_dir output is what matters
PRICEFILE_J="$T/prices.json"
printf '{"test-model": {"in": 0, "out": 1000000}}\n' > "$PRICEFILE_J"
(
  set -uo pipefail
  . "$JOURNAL"; . "$COST"
  export WORKTREES_DIR="$WT_J"
  export JOURNAL_FILE="$WT_J/.herd/journal.jsonl"
  export HERD_COST_PRICE_FILE="$PRICEFILE_J"
  C_RED=""; C_RESET=""; C_BOLD=""; C_DIM=""; C_YELLOW=""
  _slug_cell() { printf '%s' "$1"; }
  _BUDGET_ITEM_SEEN=""
  # shellcheck source=/dev/null
  . "$ITEM_SRC"

  # Real transcript for the worktree's OWN munged dir (_cost_transcript_dir does the munging).
  XDIR="$(_cost_transcript_dir "$WTDIR_J")"
  mkdir -p "$XDIR"
  cat > "$XDIR/session1.jsonl" <<'EOF'
{"message":{"role":"user","content":"do a thing"}}
{"message":{"role":"assistant","id":"m1","model":"test-model","usage":{"input_tokens":0,"output_tokens":20}}}
EOF

  FEATS=("$WTDIR_J"$'\037'"item-slug"$'\037'"feat/item-slug"$'\037'"77"$'\037'"rest-of-record")

  # BUDGET_ITEM_MAX=15, spend=$20 → OVER cap: a row is painted + budget_item_over journaled ONCE.
  BUDGET_ITEM_MAX="15"
  build_budget_item_rows
  [ -n "$BUDGET_ITEM_ROWS" ] || fail "an over-cap item must produce a console row"
  case "$BUDGET_ITEM_ROWS" in *item-slug*77*) : ;; *) fail "the row must name the slug and PR, got: $BUDGET_ITEM_ROWS" ;; esac
  [ "$(grep -c 'budget_item_over' "$JOURNAL_FILE" 2>/dev/null || echo 0)" = "1" ] \
    || fail "budget_item_over must journal exactly once on first detection"

  # A SECOND tick over the same item must NOT re-journal (dedup), but the row must still rewrite.
  build_budget_item_rows
  [ -n "$BUDGET_ITEM_ROWS" ] || fail "the row must persist on a later tick while still over cap"
  [ "$(grep -c 'budget_item_over' "$JOURNAL_FILE" 2>/dev/null || echo 0)" = "1" ] \
    || fail "budget_item_over must NOT re-journal on a later tick for the SAME item"

  # Under cap (BUDGET_ITEM_MAX=100) → no row.
  BUDGET_ITEM_MAX="100"
  build_budget_item_rows
  [ -z "$BUDGET_ITEM_ROWS" ] || fail "an under-cap item must produce NO row, got: $BUDGET_ITEM_ROWS"

  # Dormant: BUDGET_ITEM_MAX empty → no scan at all, no row.
  BUDGET_ITEM_MAX=""
  build_budget_item_rows
  [ -z "$BUDGET_ITEM_ROWS" ] || fail "BUDGET_ITEM_MAX empty must be fully dormant, got: $BUDGET_ITEM_ROWS"
  echo "PART-J-OK"
) > "$T/partj.log" || exit 1
grep -q PART-J-OK "$T/partj.log" || { cat "$T/partj.log" >&2; exit 1; }
pass

echo "ALL PASS ($PASS checks)"
