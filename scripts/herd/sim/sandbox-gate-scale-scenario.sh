#!/usr/bin/env bash
# scripts/herd/sim/sandbox-gate-scale-scenario.sh — GATE_SCALE (HERD-542) concurrency-derivation
# scenario: open N (default 8) stub-builder worktrees and drive the REAL watcher gate-cap functions
# (_review_conc / _health_conc / build_gate_scale_note, agent-watch.sh sourced in lib mode) against
# them — not a re-implementation. The scenario asserts the same formula the LIVE Python engine core
# now receives every tick (herd_engine_live_tick, engine-version.sh, passes these exact two values as
# an explicit env override), so what this proves is what actually gates merges when GATE_SCALE=on.
#
# Asserts, as scorecard checkpoints:
#   (a) builders_counted   — the builder-count primitive (_gate_scale_builders, which reuses
#                             herd-spawn-gate.sh's own _sg_count_inflight_builders) sees exactly N
#                             live worktrees.
#   (b) flag_off_byte_identical — GATE_SCALE=off: _review_conc / _health_conc return the CONFIGURED
#                             values exactly (no derivation), and build_gate_scale_note never journals
#                             a gate_scale line and renders an empty console note.
#   (c) scaled_within_bounds — GATE_SCALE=on, N=8 builders, a deterministic cores-ceiling override:
#                             the derived review/health caps sit inside [floor, ceiling] and equal the
#                             expected ceil(builders/2) clamp.
#   (d) ceiling_honored    — a SMALL cores-ceiling override caps the derived value below the raw
#                             ceil(builders/2) scaled figure, proving the ceiling actually bites.
#   (e) floor_honored      — an operator REVIEW_CONCURRENCY set ABOVE the cores ceiling is NEVER
#                             lowered by scaling.
#   (f) journal_once       — build_gate_scale_note journals `gate_scale` exactly once per DISTINCT
#                             (review,health,builders) triple — an unchanged fleet across repeated
#                             calls writes no duplicate line; a changed builder count writes a new one.
#
# HERMETIC: fixture-repo only (scripts/herd/sim/sandbox-fixture.sh), an isolated WORKSPACE_NAME +
# temp WORKTREES_DIR, HERD_DRIVER=headless, HERD_CONFIG_FILE pointed at a deliberately absent path —
# never touches the real herdkit repo's worktrees, panes, or journal. `git` is NOT stubbed: the
# fixture and its worktrees are real local git.
#
# Usage:
#   bash scripts/herd/sim/sandbox-gate-scale-scenario.sh [--artifacts DIR] [--keep] [-n N]
#     --artifacts DIR   put the repo + scorecard + artifacts here (default: a fresh mktemp dir)
#     --keep            do not delete the artifacts dir on exit (implied when --artifacts is given)
#     -n, --builders N  number of simultaneous stub-builder worktrees (default 8; minimum 4)
#
# Exit: 0 = every checkpoint passed · 1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"

c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

ART=""; KEEP=""; NBUILD=8
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) [ $# -ge 2 ] || { echo "sandbox-gate-scale-scenario: --artifacts requires a value" >&2; exit 1; }; ART="$2"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -n|--builders) [ $# -ge 2 ] || { echo "sandbox-gate-scale-scenario: -n/--builders requires a value" >&2; exit 1; }; NBUILD="$2"; shift 2 ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-gate-scale-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
case "$NBUILD" in ''|*[!0-9]*) echo "sandbox-gate-scale-scenario: -n must be an integer" >&2; exit 1 ;; esac
[ "$NBUILD" -ge 4 ] || NBUILD=4   # the scenario needs enough builders for a real ceil()/2 spread
if [ -z "$ART" ]; then ART="$(mktemp -d)"; fi
mkdir -p "$ART"
if [ -z "$KEEP" ]; then trap 'rm -rf "$ART"' EXIT; fi

SCENARIO="gate-scale-derivation"
REPO="$ART/repo"
TREES="$ART/trees"
mkdir -p "$TREES"

CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail="$*"
  detail="$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
  esac
}

printf '%s══ Sandbox GATE_SCALE scenario: %s (N=%d builders) ══%s\n' "$c_bold" "$SCENARIO" "$NBUILD" "$c_rst"
printf '  artifacts: %s\n' "$ART"

step init "build deterministic local fixture"
FIXTURE_SHA="$(sandbox_fixture_build "$REPO")" || { bad "fixture build failed"; exit 1; }
info "fixture HEAD: $FIXTURE_SHA"

step open "open $NBUILD stub-builder worktrees (deterministic; no model call, no PRs)"
_sf_git_env
i=1
while [ "$i" -le "$NBUILD" ]; do
  git -C "$REPO" worktree add -q -b "sim/feat-$i" "$TREES/feat-$i" main 2>/dev/null \
    || { bad "worktree add failed for feat-$i"; exit 1; }
  i=$((i+1))
done
_ntrees="$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')"
[ "$_ntrees" -eq $((NBUILD + 1)) ] \
  && checkpoint worktrees_opened pass "$NBUILD builder worktrees opened simultaneously off main" \
  || checkpoint worktrees_opened fail "expected $((NBUILD + 1)) worktrees (N+main), found $_ntrees"

step source "source the REAL agent-watch.sh (lib mode) with the GATE_SCALE knobs"
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$ART/no-such-config"   # ignore any ambient .herd/config
export HERD_DRIVER=headless
export WORKSPACE_NAME="sandbox-gate-scale-sim"
export PROJECT_ROOT="$REPO"
export WORKTREES_DIR="$TREES"
export DEFAULT_BRANCH="main"
export MERGE_POLICY=auto
export JOURNAL_FILE="$ART/journal.jsonl"; : > "$JOURNAL_FILE"
export REVIEW_CONCURRENCY=2 HEALTH_CONCURRENCY=1
export GATE_SCALE=off
ENGINE_DIR="$(cd "$HERE/.." && pwd)"
WATCH="$HERE/../agent-watch.sh"
[ -f "$WATCH" ] || { bad "agent-watch.sh not found at $WATCH"; exit 1; }
# shellcheck source=/dev/null
. "$WATCH" || { bad "sourcing agent-watch.sh (lib mode) failed"; exit 1; }

_missing=""
for fn in _gate_scale_enabled _gate_scale_cores _gate_scale_builders _gate_scale_derive \
          _gate_scale_journal_once build_gate_scale_note _review_conc _health_conc \
          _sg_count_inflight_builders; do
  type "$fn" >/dev/null 2>&1 || _missing="$_missing $fn"
done
[ -z "$_missing" ] \
  && checkpoint watcher_bound pass "real agent-watch.sh GATE_SCALE functions sourced (lib mode)" \
  || checkpoint watcher_bound fail "missing functions:$_missing"

# ── (a) builder count sees exactly N ────────────────────────────────────────────────────────────
step count "(a) builder-count primitive"
_BCOUNT="$(_gate_scale_builders)"
[ "$_BCOUNT" = "$NBUILD" ] \
  && checkpoint builders_counted pass "_gate_scale_builders reports $_BCOUNT (== $NBUILD live worktrees)" \
  || checkpoint builders_counted fail "_gate_scale_builders reports $_BCOUNT, expected $NBUILD"

# ── (b) flag off: byte-identical to the configured values, no journal, no console note ──────────
step off "(b) GATE_SCALE=off — byte-identical to the configured values"
export GATE_SCALE=off
_off_r="$(_review_conc)"; _off_h="$(_health_conc)"
if [ "$_off_r" = "2" ] && [ "$_off_h" = "1" ]; then
  checkpoint flag_off_values pass "_review_conc=$_off_r _health_conc=$_off_h (== configured 2/1, no scaling)"
else
  checkpoint flag_off_values fail "_review_conc=$_off_r _health_conc=$_off_h (expected 2/1 — GATE_SCALE=off must be a strict pass-through)"
fi
build_gate_scale_note
_off_journal_before="$(grep -c '"event":"gate_scale"' "$JOURNAL_FILE" 2>/dev/null; :)"
if [ -z "${GATE_SCALE_NOTE:-}" ] && [ "$_off_journal_before" -eq 0 ]; then
  checkpoint flag_off_byte_identical pass "empty console note, zero gate_scale journal lines while the lever is off"
else
  checkpoint flag_off_byte_identical fail "GATE_SCALE=off leaked a console note or a journal line (note='${GATE_SCALE_NOTE:-}' journal_lines=$_off_journal_before)"
fi

# ── (c)/(d) scaled + ceiling, GATE_SCALE=on ──────────────────────────────────────────────────────
step on "(c)/(d) GATE_SCALE=on — scaled caps within bounds, ceiling honored"
export GATE_SCALE=on
export GATE_SCALE_CORES_OVERRIDE=4   # deterministic ceiling — independent of the box running this sim
_expect_scaled=$(( (NBUILD + 1) / 2 ))   # ceil(NBUILD/2)
_want_r=$(( _expect_scaled > 4 ? 4 : _expect_scaled ))   # clamp to the ceiling override
_want_h="$_want_r"   # HEALTH_CONCURRENCY floor=1 also clamps to the same ceiling here
_on_r="$(_review_conc)"; _on_h="$(_health_conc)"
if [ "$_on_r" -ge 2 ] && [ "$_on_r" -le 4 ] && [ "$_on_r" = "$_want_r" ] \
   && [ "$_on_h" -ge 1 ] && [ "$_on_h" -le 4 ] && [ "$_on_h" = "$_want_h" ]; then
  checkpoint scaled_within_bounds pass "review=$_on_r health=$_on_h (builders=$NBUILD, ceil/2=$_expect_scaled, ceiling=4) — within [floor,ceiling] and matches the formula"
else
  checkpoint scaled_within_bounds fail "review=$_on_r health=$_on_h did not match the expected clamp (want review=$_want_r health=$_want_h)"
fi

# Small ceiling override — proves the ceiling actually caps the raw scaled figure, not just coincides.
export GATE_SCALE_CORES_OVERRIDE=2
_small_h="$(_health_conc)"
if [ "$_small_h" = "2" ] && [ "$_expect_scaled" -gt 2 ]; then
  checkpoint ceiling_honored pass "cores-ceiling override=2 caps health=$_small_h below the raw scaled figure ($_expect_scaled)"
else
  checkpoint ceiling_honored fail "cores-ceiling override=2 did not cap health (got $_small_h, raw scaled=$_expect_scaled)"
fi
export GATE_SCALE_CORES_OVERRIDE=4   # restore for the remaining legs

# ── (e) floor honored — an operator value above the ceiling is never lowered ────────────────────
step floor "(e) floor honored — an explicit operator value above the ceiling stays the floor"
export REVIEW_CONCURRENCY=10   # well above the GATE_SCALE_CORES_OVERRIDE=4 ceiling
_floor_r="$(_review_conc)"
if [ "$_floor_r" = "10" ]; then
  checkpoint floor_honored pass "REVIEW_CONCURRENCY=10 (> ceiling=4) stayed 10 — scaling never lowers an explicit operator value"
else
  checkpoint floor_honored fail "REVIEW_CONCURRENCY=10 was scaled DOWN to $_floor_r — a configured floor must never be lowered"
fi
export REVIEW_CONCURRENCY=2   # restore

# ── (f) journal-once — unchanged triple writes no duplicate; a changed triple writes a new line ──
step journal "(f) journal-once semantics"
: > "$JOURNAL_FILE"
_GATE_SCALE_LAST_SIG=""   # reset the per-process once-guard so this leg starts clean
build_gate_scale_note
build_gate_scale_note
build_gate_scale_note
_rep_lines="$(grep -c '"event":"gate_scale"' "$JOURNAL_FILE" 2>/dev/null; :)"
if [ "$_rep_lines" -eq 1 ]; then
  checkpoint journal_once_unchanged pass "3 identical-state calls to build_gate_scale_note produced exactly 1 journal line"
else
  checkpoint journal_once_unchanged fail "expected exactly 1 gate_scale journal line for an unchanged triple, got $_rep_lines"
fi
# Change the builder count → a NEW distinct triple must journal a second line.
git -C "$REPO" worktree add -q -b "sim/feat-extra" "$TREES/feat-extra" main 2>/dev/null \
  || { bad "worktree add failed for feat-extra"; exit 1; }
build_gate_scale_note
_chg_lines="$(grep -c '"event":"gate_scale"' "$JOURNAL_FILE" 2>/dev/null; :)"
if [ "$_chg_lines" -eq 2 ]; then
  checkpoint journal_once_on_change pass "adding a builder changed the triple — a 2nd distinct gate_scale line was journaled ($_chg_lines total)"
else
  checkpoint journal_once_on_change fail "expected 2 gate_scale journal lines after the triple changed, got $_chg_lines"
fi
[ -n "${GATE_SCALE_NOTE:-}" ] && printf '%s' "$GATE_SCALE_NOTE" | grep -q 'scaled' \
  && checkpoint console_note_scaled pass "console note carries the 'scaled' qualifier: $(printf '%s' "$GATE_SCALE_NOTE" | tr -d '\n')" \
  || checkpoint console_note_scaled fail "console note missing or lacks the 'scaled' qualifier (note='${GATE_SCALE_NOTE:-}')"

# ── SCORECARD ──────────────────────────────────────────────────────────────────────────────────
write_scorecard() {
  local out="$ART/scorecard.json" result="$1"
  local i n; n=${#CP_NAMES[@]}
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
    printf '  "artifacts_dir": "%s",\n' "$ART"
    printf '  "repo_dir": "%s",\n' "$REPO"
    printf '  "fixture_sha": "%s",\n' "$FIXTURE_SHA"
    printf '  "builders": %d,\n' "$NBUILD"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "checkpoints": [\n'
    for ((i=0; i<n; i++)); do
      printf '    {"name": "%s", "status": "%s", "detail": "%s"}' \
        "${CP_NAMES[$i]}" "${CP_STATUS[$i]}" "${CP_DETAIL[$i]}"
      [ "$i" -lt "$((n-1))" ] && printf ',\n' || printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
  } > "$out"
  printf '%s' "$out"
}

RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$(write_scorecard "$RESULT")"
printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:      %s\n' "$SCENARIO"
printf '  result:        %s\n' "$RESULT"
printf '  passed/failed: %d / %d\n' "$_pass" "$_fail"
printf '  scorecard:     %s\n' "$SCARD"
printf '  artifacts:     %s\n' "$ART"

[ "$RESULT" = "pass" ] && exit 0 || exit 1
