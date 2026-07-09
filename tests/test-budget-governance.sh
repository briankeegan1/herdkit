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
# DORMANCY (byte-identical when BUDGET_DAILY unset) is asserted throughout, plus fail-soft on a typo'd value.
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
) | grep -q PART-A-OK || exit 1
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
sed -n '/^_drain_spawn_queue()/,/^}/p' "$WATCH" > "$DRAIN_SRC"
grep -q '_drain_spawn_queue()' "$DRAIN_SRC" || fail "could not extract _drain_spawn_queue from agent-watch.sh"

JLOG="$T/journal.evt"
# run_drain <BUDGET_DAILY> [FORCE] — one drain pass with the REAL budget predicate over the fixture journal.
run_drain() {
  ( export LANELOG JLOG
    HERE="$ENG"; TREES="$TREES"; FEATS=()
    REVIEW_CONCURRENCY=2; SPAWN_AHEAD=1; DRYRUN=""
    export WORKTREES_DIR="$TREES"
    export BUDGET_DAILY="$1"
    [ "${2:-}" = "force" ] && export HERD_FORCE_SPAWN=1
    _BUDGET_DRAIN_PAUSED=""
    # shellcheck source=/dev/null
    . "$JOURNAL"; . "$COST"
    journal_append(){ printf '%s\n' "$*" >> "$JLOG"; }   # log-only stub (overrides journal.sh's real one)
    . "$DRAIN_SRC"
    _drain_spawn_queue
    # A second tick while still over budget must NOT re-journal the pause (once per stretch).
    _drain_spawn_queue )
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

echo "ALL PASS ($PASS checks)"
