#!/usr/bin/env bash
# engine-down-scenario.sh — FAULT-INJECTION sim for the P5b engine watchdog (HERD-306, EPIC HERD-300).
#
# P5b DELETED the bash action pass: pysrc/herd/live_runtime.py is now the SOLE engine core, and the
# supervisor hands it every tick through _engine_tick_watchdog (agent-watch.sh) — there is NO bash
# fallback. This scenario BREAKS THE MODULE for real (a live_runtime that exits non-zero) and drives the
# watchdog through the fault, asserting the replacement failure story the deletion is on the hook for:
#
#   restart_attempts  — the watchdog RETRIES the Python tick in-tick (backoff), so a broken module is
#                       re-invoked multiple times, not abandoned after one shot.
#   loud_row          — past _ENGINE_FAULT_MAX consecutive faulty ticks it sets the LOUD
#                       'ENGINE DOWN · manual intervention' console banner (ENGINE_DOWN_ROW).
#   engine_down       — it journals engine_down and fires exactly ONE notification per episode.
#   zero_actions      — NO gate / merge / resolver ever runs in bash on a fault (the safe HOLD, never a
#                       partial merge): the action-pass tripwires are never tripped.
#   recovery          — when the module is fixed (a clean tick), the banner clears, the fault streak
#                       resets, and engine_recovered is journaled once.
#
# This drives the REAL engine-version.sh seam (herd_engine_live_tick actually shells out to
# `python3 -m herd.live_runtime --tick` against an injected pysrc) and the REAL watchdog sourced from
# agent-watch.sh in lib mode — no gh, git, herdr, or network. It emits a machine-readable scorecard so
# the tier table / parity-run can read the result from a file.
#
# Usage:  bash scripts/herd/sim/engine-down-scenario.sh [--artifacts DIR] [--keep]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"
SCENARIO="engine-down-fault-injection"

ART=""; KEEP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
[ -n "$KEEP" ] || trap 'rm -rf "$ART"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required" >&2; exit 0; }
[ -f "$WATCH" ] || { echo "FAIL: missing $WATCH" >&2; exit 1; }

c_bold=""; c_rst=""; if [ -t 1 ]; then c_bold=$'\033[1m'; c_rst=$'\033[0m'; fi
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=(); _pass=0; _fail=0
check() { # <name> <ok:0/1> <detail>
  CP_NAMES+=("$1"); CP_DETAIL+=("$3")
  if [ "$2" = 0 ]; then CP_STATUS+=("pass"); _pass=$((_pass+1)); printf '  %s✓%s %s — %s\n' "$c_bold" "$c_rst" "$1" "$3"
  else CP_STATUS+=("fail"); _fail=$((_fail+1)); printf '  ✗ %s — %s\n' "$1" "$3" >&2; fi
}

# ── inject a BROKEN engine module: python3 -m herd.live_runtime --tick exits non-zero and records the
#    invocation, so we can COUNT how many restart attempts the watchdog made through the real seam. ──
PYP="$ART/pysrc"; mkdir -p "$PYP/herd"
: > "$PYP/herd/__init__.py"
ATTEMPTS="$ART/attempts.log"; : > "$ATTEMPTS"
cat > "$PYP/herd/live_runtime.py" <<PY
import os, sys
open("$ATTEMPTS", "a").write("x\n")   # one line per invocation = one restart attempt
sys.exit(3)                            # BROKEN: the module faults on every tick
PY

# ── the run: source the real watcher lib, stub only the observation leaves, drive the watchdog ──────
TRACE="$ART/trace"; : > "$TRACE"
(
  export AGENT_WATCH_LIB=1
  export HERD_CONFIG_FILE="$ART/no-config"
  export WORKTREES_DIR="$ART/trees"; mkdir -p "$ART/trees"
  export JOURNAL_FILE="$ART/journal.jsonl"
  export HERDKIT_HOME="$ART"          # so herd_engine_live_tick resolves the INJECTED (broken) module
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "src-fail" > "$TRACE"; exit 1; }

  _rec() { printf '%s\n' "$1" >> "$TRACE"; }
  # record the side effects we assert on (journal + notify + banner via render)
  journal_append() { _rec "journal:$1"; }
  herd_driver_notify() { _rec "notify:$1"; }
  render() { _rec render; }
  # action-pass tripwires: a fault must trip NONE of these
  do_merge() { _rec ACTION:do_merge; }
  spawn_resolver() { _rec ACTION:spawn_resolver; }
  post_gate_status() { _rec ACTION:post_gate_status; }
  _review_gate_step() { _rec ACTION:review; }
  _healthcheck_gate() { _rec ACTION:health; }

  # watchdog state (initialised after the lib-return in a real watcher). DRYRUN skips the backoff sleep
  # so the sim is fast; retries + fault-max are the real defaults' shape.
  DRYRUN=1
  ENGINE_DOWN_ROW=""; C_RED=""; C_BOLD=""; C_RESET=""; C_DIM=""
  _ENGINE_FAULT_STREAK=0; _ENGINE_FAULT_MAX=3; _ENGINE_TICK_RETRIES=2; _ENGINE_BACKOFF_BASE=1
  _ENGINE_DOWN_DECLARED=""

  # three faulty ticks → streak reaches the max → engine down
  _engine_tick_watchdog || true
  _engine_tick_watchdog || true
  _engine_tick_watchdog || true
  printf 'DOWN_ROW=%s\n' "$ENGINE_DOWN_ROW" >> "$TRACE"
  printf 'STREAK=%s\n' "$_ENGINE_FAULT_STREAK" >> "$TRACE"

  # FIX the module (clean tick) → recovery
  cat > "$HERDKIT_HOME/pysrc/herd/live_runtime.py" <<'OK'
import sys
sys.exit(0)
OK
  _engine_tick_watchdog || true
  printf 'DOWN_ROW_AFTER=%s\n' "$ENGINE_DOWN_ROW" >> "$TRACE"
) || true

attempts="$(wc -l < "$ATTEMPTS" | tr -d ' ')"
downrow="$(grep -m1 '^DOWN_ROW=' "$TRACE" | sed 's/^DOWN_ROW=//')"
downrow_after="$(grep -m1 '^DOWN_ROW_AFTER=' "$TRACE" | sed 's/^DOWN_ROW_AFTER=//')"
streak="$(grep -m1 '^STREAK=' "$TRACE" | sed 's/^STREAK=//')"
n_down="$(grep -c '^journal:engine_down$' "$TRACE" || true)"
n_notify="$(grep -c '^notify:.*engine down' "$TRACE" || true)"
n_actions="$(grep -c '^ACTION:' "$TRACE" || true)"
n_recovered="$(grep -c '^journal:engine_recovered$' "$TRACE" || true)"

# ── checkpoints ────────────────────────────────────────────────────────────────────────────────
[ "$attempts" -ge 3 ] && check restart_attempts 0 "$attempts real Python re-invocations (retried, not abandoned)" \
                       || check restart_attempts 1 "expected ≥3 restart attempts, got $attempts"
case "$downrow" in *ENGINE\ DOWN*) check loud_row 0 "loud engine-down banner set past the fault streak" ;;
                   *) check loud_row 1 "engine-down banner not set (got: '$downrow')" ;; esac
[ "$streak" = 3 ] && check fault_streak 0 "fault streak reached _ENGINE_FAULT_MAX (3)" \
                  || check fault_streak 1 "expected streak 3, got '$streak'"
[ "$n_down" = 1 ] && check engine_down_journaled 0 "engine_down journaled exactly once" \
                  || check engine_down_journaled 1 "engine_down journaled ${n_down}x (want 1)"
[ "$n_notify" = 1 ] && check one_notification 0 "exactly one engine-down notification fired" \
                    || check one_notification 1 "notifications fired ${n_notify}x (want 1)"
[ "$n_actions" = 0 ] && check zero_actions 0 "NO bash gate/merge/resolver ran on the fault (safe hold)" \
                     || check zero_actions 1 "$n_actions bash action-pass call(s) leaked on a fault"
{ [ -z "$downrow_after" ] && [ "$n_recovered" = 1 ]; } \
  && check recovery 0 "a clean tick cleared the banner and journaled engine_recovered" \
  || check recovery 1 "recovery incomplete (banner_after='$downrow_after', recovered=$n_recovered)"

# ═══ scorecard ═══════════════════════════════════════════════════════════════════════════════════
RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
out="$ART/scorecard.json"; n=${#CP_NAMES[@]}
{
  printf '{\n'
  printf '  "scenario": "%s",\n' "$SCENARIO"
  printf '  "artifacts_dir": "%s",\n' "$ART"
  printf '  "result": "%s",\n' "$RESULT"
  printf '  "passed": %d,\n' "$_pass"
  printf '  "failed": %d,\n' "$_fail"
  printf '  "restart_attempts": %d,\n' "$attempts"
  printf '  "fault_streak": %s,\n' "${streak:-0}"
  printf '  "checkpoints": [\n'
  for ((i=0; i<n; i++)); do
    printf '    {"name": "%s", "status": "%s", "detail": "%s"}' "${CP_NAMES[$i]}" "${CP_STATUS[$i]}" "${CP_DETAIL[$i]}"
    [ "$i" -lt "$((n-1))" ] && printf ',\n' || printf '\n'
  done
  printf '  ]\n}\n'
} > "$out"

printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:      %s\n' "$SCENARIO"
printf '  result:        %s\n' "$RESULT"
printf '  passed/failed: %d / %d\n' "$_pass" "$_fail"
printf '  scorecard:     %s\n' "$out"
printf '  artifacts:     %s\n' "$ART"

[ "$_fail" -eq 0 ] || exit 1
