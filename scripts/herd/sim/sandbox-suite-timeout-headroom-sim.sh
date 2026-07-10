#!/usr/bin/env bash
# scripts/herd/sim/sandbox-suite-timeout-headroom-sim.sh
# HERD-281: sim for the suite-duration vs inflight-timeout headroom check.
#
# Probes the SHIPPED helper functions and the corpse-sweep path of agent-watch.sh
# (lib mode) for the HEALTH_TIMEOUT_HEADROOM feature. All fixtures are in a temp dir —
# no real PR, no herdr panes, no network.
#
# Checkpoints:
#   helpers_bound              — all HERD-281 helpers present in lib mode
#   dormant_no_early_kill      — HEALTH_TIMEOUT_HEADROOM=0: NOT killed before timeout
#   dormant_byte_identical     — HEALTH_TIMEOUT_HEADROOM=0: killed AT timeout exactly
#   no_advisory_before_window  — margin>0, age < timeout-margin: no advisory, no defer
#   advisory_fires             — margin>0, age >= timeout-margin: advisory signal set
#   deferred_kill_in_window    — age in [timeout-margin, timeout+margin): marker NOT killed
#   deferred_kill_near_edge    — age = timeout+margin-1: still NOT killed
#   kill_past_margin           — age >= timeout+margin: marker IS killed
#   duration_record            — _health_duration_record persists max observed duration
#   duration_max_only_up       — larger value replaces current max
#   duration_max_only_no_down  — smaller value does NOT replace current max
#   fail_soft_no_file          — missing duration file → _health_duration_observed returns 0
#   fail_soft_corrupt          — corrupt duration file → _health_duration_observed returns 0
#   headroom_non_numeric_safe  — non-numeric HEALTH_TIMEOUT_HEADROOM → _health_timeout_headroom returns 0
#   build_note_dormant         — build_health_headroom_note is a no-op when margin=0
#   build_note_off_outside     — no advisory when observed duration leaves adequate headroom
#   build_note_observed        — advisory fires when observed duration is within margin of timeout
#   build_note_approaching     — advisory fires when _HEALTH_HEADROOM_APPROACHING is set
#   journal_throttle_first     — first advisory call writes the throttle file
#   journal_throttle_suppress  — second call within 600s window is suppressed
#
# Usage:
#   bash scripts/herd/sim/sandbox-suite-timeout-headroom-sim.sh [--artifacts DIR] [--keep]
#     --artifacts DIR   write artifacts + scorecard.json here (default: fresh mktemp dir)
#     --keep            do not remove the artifacts dir on exit
#
# Exit: 0 = all checkpoints passed · 1 = at least one failed (or hard error)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
skip() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────
ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'sandbox-suite-timeout-headroom-sim: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -z "$ART" ] && ART="$(mktemp -d)"
mkdir -p "$ART"
[ -z "$KEEP" ] && trap 'rm -rf "$ART"' EXIT

# ── checkpoint recording ────────────────────────────────────────────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0; _skip=0
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail; detail="$(printf '%s' "$*" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok  "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
    skip) _skip=$((_skip+1)); skip "$name — $detail" ;;
  esac
}

SCENARIO="suite-timeout-headroom"
printf '%s══ HERD-281 sandbox sim: %s ══%s\n' "$c_bold" "$SCENARIO" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# ── source agent-watch.sh in lib mode ──────────────────────────────────────────
step init "source agent-watch.sh (lib mode) with isolated TREES"
TREES="$ART/trees"; mkdir -p "$TREES/.herd"
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$ART/no-such-config"
export HERD_DRIVER=headless
export WORKSPACE_NAME="sandbox-headroom-sim"
export WORKTREES_DIR="$TREES"
export PROJECT_ROOT="$ART"
export DEFAULT_BRANCH="main"
WATCH="$HERE/../agent-watch.sh"
[ -f "$WATCH" ] || { bad "agent-watch.sh not found at $WATCH"; exit 1; }
# shellcheck source=/dev/null
. "$WATCH" || { bad "sourcing agent-watch.sh (lib mode) failed"; exit 1; }

# Verify the HERD-281 helpers are present.
_missing=""
for fn in _health_duration_file _health_duration_record _health_duration_observed \
          _health_timeout_headroom _health_headroom_advisory_file \
          _health_headroom_journal_once build_health_headroom_note; do
  type "$fn" >/dev/null 2>&1 || _missing="$_missing $fn"
done
if [ -z "$_missing" ]; then
  checkpoint helpers_bound pass "all HERD-281 helper functions present (lib mode)"
else
  checkpoint helpers_bound fail "missing:$_missing"
  # Hard dependency — emit a minimal scorecard and abort.
  SCARD="$ART/scorecard.json"
  printf '{"scenario":"%s","result":"fail","passed":%d,"failed":%d,"skipped":%d,"checkpoints":[]}\n' \
    "$SCENARIO" "$_pass" "$_fail" "$_skip" > "$SCARD"
  printf 'scorecard: %s\n' "$SCARD"
  exit 1
fi

# ── helper: plant a .health-inflight-<key> with a controlled age ───────────────
# Marker format: line 1 = pid, line 2 = start_time (blank → bare kill -0 fallback), line 3 = dispatch_ts.
# _marker_age(f) = now - dispatch_ts.
_plant_marker() {
  local key="$1" pid="$2" age_secs="$3"
  local now; now="$(_now_epoch)"
  local dispatch_ts=$(( now - age_secs ))
  local f="$TREES/.health-inflight-$key"
  printf '%s\n\n%s\n' "$pid" "$dispatch_ts" > "$f"
  printf '%s' "$f"
}

# Spawn a background process we CAN kill (for "should be killed" tests). Using $$ would
# hit the watcher-self guard ([ "$pid" = "$$" ] && continue) and never be killed.
# IMPORTANT: spawn directly into _SIM_KILL_PID (not inside $(...)) — a background sleep
# inside command substitution blocks the subshell until the sleep exits.
_SIM_KILL_PID=""
_spawn_kill_target() {
  sleep 300 &
  _SIM_KILL_PID="$!"
}

# ── 1. SHIP-DORMANT: HEALTH_TIMEOUT_HEADROOM=0 ─────────────────────────────────
step dormant "ship-dormant: HEALTH_TIMEOUT_HEADROOM=0 is byte-identical to the old path"
export HEALTH_INFLIGHT_TIMEOUT=10
unset HEALTH_TIMEOUT_HEADROOM 2>/dev/null || true

# 1a. Age < timeout (5 < 10) → NOT killed.
_f1a="$(_plant_marker hrd-early "$$" 5)"
_HEALTH_HEADROOM_APPROACHING=""
_sweep_gate_corpses
if [ -f "$_f1a" ]; then
  checkpoint dormant_no_early_kill pass "age=5 < timeout=10: marker survived (HEALTH_TIMEOUT_HEADROOM=0)"
else
  checkpoint dormant_no_early_kill fail "marker killed at age=5 before timeout=10"
fi
rm -f "$_f1a" 2>/dev/null || true

# 1b. Age >= timeout (10 >= 10) → KILLED. Use a real background process (not $$).
_spawn_kill_target; _kill_pid="$_SIM_KILL_PID"
_f1b="$(_plant_marker hrd-attimeout "$_kill_pid" 10)"
_HEALTH_HEADROOM_APPROACHING=""
_sweep_gate_corpses
if [ ! -f "$_f1b" ]; then
  checkpoint dormant_byte_identical pass "age=10 >= timeout=10: marker killed (HEALTH_TIMEOUT_HEADROOM=0 byte-identical)"
else
  checkpoint dormant_byte_identical fail "marker survived at age=10 >= timeout=10 — sweep did not kill"
  kill "$_kill_pid" 2>/dev/null || true; rm -f "$_f1b" 2>/dev/null || true
fi
kill "$_kill_pid" 2>/dev/null || true

# ── 2. HEADROOM: advisory + deferred kill ──────────────────────────────────────
step headroom "headroom active: advisory fires and kill deferred within [timeout-margin, timeout+margin)"
export HEALTH_INFLIGHT_TIMEOUT=10
export HEALTH_TIMEOUT_HEADROOM=3   # window: age in [7, 13)

# 2a. Age < timeout-margin (5 < 7) → NOT killed, no advisory.
_f2a="$(_plant_marker hrd-before-window "$$" 5)"
_HEALTH_HEADROOM_APPROACHING=""
_sweep_gate_corpses
if [ -f "$_f2a" ]; then
  checkpoint no_advisory_before_window pass "age=5 < threshold=7: marker untouched"
else
  checkpoint no_advisory_before_window fail "marker killed at age=5 before advisory window [7,13)"
fi
if [ -z "${_HEALTH_HEADROOM_APPROACHING:-}" ]; then
  info "_HEALTH_HEADROOM_APPROACHING correctly empty at age=5"
else
  bad "_HEALTH_HEADROOM_APPROACHING unexpectedly set at age=5"
fi
rm -f "$_f2a" 2>/dev/null || true

# 2b. Age = timeout-margin (7, start of window) → NOT killed, advisory set.
_HEALTH_HEADROOM_APPROACHING=""
_f2b="$(_plant_marker hrd-at-window "$$" 7)"
_sweep_gate_corpses
if [ -f "$_f2b" ]; then
  checkpoint deferred_kill_in_window pass "age=7 in [7,13): marker NOT killed (deferred)"
else
  checkpoint deferred_kill_in_window fail "marker killed at age=7 — should be deferred within grace window"
fi
if [ -n "${_HEALTH_HEADROOM_APPROACHING:-}" ]; then
  checkpoint advisory_fires pass "age=7 >= threshold=7: _HEALTH_HEADROOM_APPROACHING set (age='${_HEALTH_HEADROOM_APPROACHING}')"
else
  checkpoint advisory_fires fail "age=7 >= threshold=7: _HEALTH_HEADROOM_APPROACHING was NOT set"
fi
rm -f "$_f2b" 2>/dev/null || true

# 2c. Age = timeout+margin-1 (12, near the edge of the window) → still NOT killed.
_HEALTH_HEADROOM_APPROACHING=""
_f2c="$(_plant_marker hrd-near-edge "$$" 12)"
_sweep_gate_corpses
if [ -f "$_f2c" ]; then
  checkpoint deferred_kill_near_edge pass "age=12 in [7,13): marker NOT killed (still in grace window)"
else
  checkpoint deferred_kill_near_edge fail "marker killed at age=12 — past timeout but within grace margin"
fi
rm -f "$_f2c" 2>/dev/null || true

# 2d. Age = timeout+margin (13, past the grace window) → KILLED.
_spawn_kill_target; _kill2_pid="$_SIM_KILL_PID"
_f2d="$(_plant_marker hrd-past-margin "$_kill2_pid" 13)"
_HEALTH_HEADROOM_APPROACHING=""
_sweep_gate_corpses
if [ ! -f "$_f2d" ]; then
  checkpoint kill_past_margin pass "age=13 >= timeout+margin=13: marker killed (grace window expired)"
else
  checkpoint kill_past_margin fail "marker survived at age=13 >= timeout+margin=13 — should have been killed"
  kill "$_kill2_pid" 2>/dev/null || true; rm -f "$_f2d" 2>/dev/null || true
fi
kill "$_kill2_pid" 2>/dev/null || true

unset HEALTH_INFLIGHT_TIMEOUT HEALTH_TIMEOUT_HEADROOM

# ── 3. DURATION RECORDING ──────────────────────────────────────────────────────
step duration "suite-duration recording helpers"
rm -f "$(_health_duration_file)" 2>/dev/null || true

# 3a. First record.
_health_duration_record 120
_obs="$(_health_duration_observed)"
if [ "$_obs" = "120" ]; then
  checkpoint duration_record pass "first record 120s persisted (observed=$_obs)"
else
  checkpoint duration_record fail "expected 120, got '$_obs'"
fi

# 3b. Larger value replaces.
_health_duration_record 180
_obs="$(_health_duration_observed)"
if [ "$_obs" = "180" ]; then
  checkpoint duration_max_only_up pass "180 > 120: observed updated to 180"
else
  checkpoint duration_max_only_up fail "expected 180, got '$_obs'"
fi

# 3c. Smaller value does NOT replace.
_health_duration_record 90
_obs="$(_health_duration_observed)"
if [ "$_obs" = "180" ]; then
  checkpoint duration_max_only_no_down pass "90 < 180: max holds at 180 (no regression)"
else
  checkpoint duration_max_only_no_down fail "expected max=180, got '$_obs'"
fi

# 3d. Missing file → 0 (fail-soft).
rm -f "$(_health_duration_file)" 2>/dev/null || true
_obs="$(_health_duration_observed)"
if [ "$_obs" = "0" ]; then
  checkpoint fail_soft_no_file pass "missing duration file → observed=0 (fail-soft)"
else
  checkpoint fail_soft_no_file fail "expected 0 for missing file, got '$_obs'"
fi

# 3e. Corrupt content → 0 (fail-soft).
printf 'not-a-number\n' > "$(_health_duration_file)"
_obs="$(_health_duration_observed)"
if [ "$_obs" = "0" ]; then
  checkpoint fail_soft_corrupt pass "corrupt duration file → observed=0 (fail-soft)"
else
  checkpoint fail_soft_corrupt fail "expected 0 for corrupt file, got '$_obs'"
fi
rm -f "$(_health_duration_file)" 2>/dev/null || true

# 3f. Non-numeric HEALTH_TIMEOUT_HEADROOM → _health_timeout_headroom returns 0.
export HEALTH_TIMEOUT_HEADROOM="abc"
_hth="$(_health_timeout_headroom)"
if [ "$_hth" = "0" ]; then
  checkpoint headroom_non_numeric_safe pass "non-numeric HEALTH_TIMEOUT_HEADROOM → 0 (fail-soft)"
else
  checkpoint headroom_non_numeric_safe fail "expected 0 for non-numeric, got '$_hth'"
fi
unset HEALTH_TIMEOUT_HEADROOM

# ── 4. BUILD_HEALTH_HEADROOM_NOTE ─────────────────────────────────────────────
step buildnote "build_health_headroom_note: no-op when dormant; fires when headroom is low"
export HEALTH_INFLIGHT_TIMEOUT=1800

# 4a. Margin=0 (dormant): note must be empty.
unset HEALTH_TIMEOUT_HEADROOM 2>/dev/null || true
rm -f "$(_health_duration_file)" 2>/dev/null || true
HEALTH_HEADROOM_NOTE=""; _HEALTH_HEADROOM_APPROACHING=""
build_health_headroom_note
if [ -z "${HEALTH_HEADROOM_NOTE:-}" ]; then
  checkpoint build_note_dormant pass "build_health_headroom_note is a no-op (HEALTH_HEADROOM_NOTE='') when margin=0"
else
  checkpoint build_note_dormant fail "HEALTH_HEADROOM_NOTE set when margin=0 — NOT byte-identical (value='${HEALTH_HEADROOM_NOTE:-}')"
fi

# 4b. Margin>0, adequate headroom (timeout-obs >> margin) → no note.
export HEALTH_TIMEOUT_HEADROOM=200
_health_duration_record 1500   # headroom = 1800-1500 = 300 > margin=200
HEALTH_HEADROOM_NOTE=""; _HEALTH_HEADROOM_APPROACHING=""
build_health_headroom_note
if [ -z "${HEALTH_HEADROOM_NOTE:-}" ]; then
  checkpoint build_note_off_outside pass "obs=1500, headroom=300 > margin=200: no advisory"
else
  checkpoint build_note_off_outside fail "advisory fired with adequate headroom (obs=1500, margin=200, timeout=1800)"
fi
rm -f "$(_health_duration_file)" 2>/dev/null || true

# 4c. Margin>0, low headroom (timeout-obs < margin) → note set.
_health_duration_record 1700   # headroom = 1800-1700 = 100 < margin=200
HEALTH_HEADROOM_NOTE=""; _HEALTH_HEADROOM_APPROACHING=""
build_health_headroom_note
if [ -n "${HEALTH_HEADROOM_NOTE:-}" ]; then
  checkpoint build_note_observed pass "obs=1700, headroom=100 < margin=200: advisory note set"
else
  checkpoint build_note_observed fail "advisory NOT fired (obs=1700, margin=200, timeout=1800)"
fi
rm -f "$(_health_duration_file)" 2>/dev/null || true

# 4d. Margin>0, _HEALTH_HEADROOM_APPROACHING set (live suite in sweep window) → note set.
HEALTH_HEADROOM_NOTE=""; _HEALTH_HEADROOM_APPROACHING="1650"
build_health_headroom_note
if [ -n "${HEALTH_HEADROOM_NOTE:-}" ]; then
  checkpoint build_note_approaching pass "_HEALTH_HEADROOM_APPROACHING=1650: live-suite advisory note set"
else
  checkpoint build_note_approaching fail "live-suite advisory NOT set when _HEALTH_HEADROOM_APPROACHING=1650"
fi

unset HEALTH_INFLIGHT_TIMEOUT HEALTH_TIMEOUT_HEADROOM

# ── 5. JOURNAL THROTTLE ────────────────────────────────────────────────────────
step journal "journal advisory throttle: fires once per 600s window, suppressed on repeat calls"
export HEALTH_INFLIGHT_TIMEOUT=10
export HEALTH_TIMEOUT_HEADROOM=3
_jfile="$(_health_headroom_advisory_file)"
rm -f "$_jfile" 2>/dev/null || true

# First call (no throttle file) → writes it.
_health_headroom_journal_once "sim-key" "8" "10" "3" 2>/dev/null || true
if [ -f "$_jfile" ]; then
  checkpoint journal_throttle_first pass "first advisory call wrote the throttle timestamp file"
else
  checkpoint journal_throttle_first fail "first advisory call did NOT write the throttle file"
fi

# Second call within the same 600s window → timestamp unchanged (suppressed).
_ts_before="$(cat "$_jfile" 2>/dev/null || printf 0)"
_health_headroom_journal_once "sim-key" "8" "10" "3" 2>/dev/null || true
_ts_after="$(cat "$_jfile" 2>/dev/null || printf 0)"
if [ "$_ts_before" = "$_ts_after" ]; then
  checkpoint journal_throttle_suppress pass "second call within 600s: timestamp unchanged (throttled)"
else
  checkpoint journal_throttle_suppress fail "second call re-journaled (ts: ${_ts_before}→${_ts_after})"
fi
rm -f "$_jfile" 2>/dev/null || true
unset HEALTH_INFLIGHT_TIMEOUT HEALTH_TIMEOUT_HEADROOM

# ── SCORECARD ──────────────────────────────────────────────────────────────────
step scorecard "write scorecard.json"
RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$ART/scorecard.json"
{
  printf '{\n'
  printf '  "scenario": "%s",\n' "$SCENARIO"
  printf '  "feature": "HERD-281",\n'
  printf '  "result": "%s",\n' "$RESULT"
  printf '  "passed": %d,\n' "$_pass"
  printf '  "failed": %d,\n' "$_fail"
  printf '  "skipped": %d,\n' "$_skip"
  printf '  "artifacts_dir": "%s",\n' "$ART"
  n=${#CP_NAMES[@]}
  printf '  "checkpoints": [\n'
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '    {"name": "%s", "status": "%s", "detail": "%s"}' \
      "${CP_NAMES[$i]}" "${CP_STATUS[$i]}" "${CP_DETAIL[$i]}"
    [ "$i" -lt "$((n-1))" ] && printf ',\n' || printf '\n'
    i=$((i+1))
  done
  printf '  ]\n'
  printf '}\n'
} > "$SCARD"

printf '\n%s══ result: %s ══%s\n' "$c_bold" "$RESULT" "$c_rst"
printf '  passed:   %d\n' "$_pass"
printf '  failed:   %d\n' "$_fail"
printf '  skipped:  %d\n' "$_skip"
printf '  scorecard: %s\n' "$SCARD"
[ "$RESULT" = "pass" ] && exit 0 || exit 1
