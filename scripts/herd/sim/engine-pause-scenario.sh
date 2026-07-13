#!/usr/bin/env bash
# engine-pause-scenario.sh — SIM for the OPERATOR EMERGENCY PAUSE lever (HERD-347).
#
# P5b left the Python live engine (pysrc/herd/live_runtime.py) as the SOLE engine core, handed every
# tick through _engine_tick_watchdog (agent-watch.sh). This scenario proves the first-class ENGINE_PAUSE
# switch that restores the pre-P5b emergency-off move config validation now refuses — WITHOUT the
# blunt instrument of killing the whole watcher. It drives the REAL watchdog against a REAL (clean)
# injected engine module and toggles ENGINE_PAUSE in a REAL config file mid-scenario, asserting:
#
#   zero_dispatch   — while ENGINE_PAUSE=on the Python tick is NEVER shelled out to (the injected
#                     module records one line per real invocation; it must stay empty), so no gate /
#                     merge / refix / resolver action can run.
#   paused_row      — a loud '⏸ engine paused by operator' banner is painted while paused.
#   no_fault        — a skipped (paused) tick is NOT a fault: the fault streak stays 0 and the
#                     engine-down banner never arms (a pause must never masquerade as a crash).
#   paused_once     — engine_paused is journaled + notified exactly ONCE per pause episode, not per tick.
#   zero_actions    — no bash gate/merge/resolver tripwire fires while paused (the safe hold).
#   resume_clean    — flipping ENGINE_PAUSE=off makes the very next tick dispatch the engine again
#                     (a real Python invocation), clears the banner, and journals engine_resumed once.
#   fresh_read      — the toggle is read from the config FILE each tick (no restart, no seat-local
#                     cache): the same long-lived watcher process honors on→off with no re-source.
#
# Drives the REAL engine-version.sh seam (herd_engine_live_tick shells to `python3 -m herd.live_runtime
# --tick` against an injected pysrc) and the REAL watchdog sourced from agent-watch.sh in lib mode — no
# gh, git, herdr, or network. Emits a machine-readable scorecard so the tier table can read the result.
#
# Usage:  bash scripts/herd/sim/engine-pause-scenario.sh [--artifacts DIR] [--keep]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"
SCENARIO="engine-operator-pause"

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

# ── inject a CLEAN engine module: `python3 -m herd.live_runtime --tick` exits 0 and records the
#    invocation, so we can COUNT real dispatches. A PAUSED tick must produce ZERO of these lines. ──
PYP="$ART/pysrc"; mkdir -p "$PYP/herd"
: > "$PYP/herd/__init__.py"
DISPATCH="$ART/dispatch.log"; : > "$DISPATCH"
cat > "$PYP/herd/live_runtime.py" <<PY
import sys
open("$DISPATCH", "a").write("x\n")   # one line per REAL engine dispatch (a paused tick writes none)
sys.exit(0)                           # clean tick
PY

# ── a REAL config file we toggle mid-scenario (the fresh-read path resolves off \$HERD_CONFIG_FILE) ──
CFGDIR="$ART/.herd"; mkdir -p "$CFGDIR"
CFG="$CFGDIR/config"
printf 'ENGINE_PAUSE=on\n' > "$CFG"   # START paused

TRACE="$ART/trace"; : > "$TRACE"
(
  export AGENT_WATCH_LIB=1
  export HERD_CONFIG_FILE="$CFG"
  export WORKTREES_DIR="$ART/trees"; mkdir -p "$ART/trees"
  export JOURNAL_FILE="$ART/journal.jsonl"
  export HERDKIT_HOME="$ART"          # so herd_engine_live_tick resolves the INJECTED module
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "src-fail" > "$TRACE"; exit 1; }

  _rec() { printf '%s\n' "$1" >> "$TRACE"; }
  # record the side effects we assert on (journal + notify + banner via render)
  journal_append() { _rec "journal:$1"; }
  herd_driver_notify() { _rec "notify:$1"; }
  render() { _rec render; }
  # action-pass tripwires: nothing may run while paused (the safe hold)
  do_merge() { _rec ACTION:do_merge; }
  spawn_resolver() { _rec ACTION:spawn_resolver; }
  post_gate_status() { _rec ACTION:post_gate_status; }
  _review_gate_step() { _rec ACTION:review; }
  _healthcheck_gate() { _rec ACTION:health; }

  DRYRUN=1
  ENGINE_DOWN_ROW=""; ENGINE_PAUSE_ROW=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_RESET=""; C_DIM=""
  _ENGINE_FAULT_STREAK=0; _ENGINE_FAULT_MAX=3; _ENGINE_TICK_RETRIES=2; _ENGINE_BACKOFF_BASE=1
  _ENGINE_DOWN_DECLARED=""; _ENGINE_PAUSE_DECLARED=""

  # THREE paused ticks — zero dispatch, one paused episode, no fault
  _engine_tick_watchdog || true
  _engine_tick_watchdog || true
  _engine_tick_watchdog || true
  printf 'PAUSED_ROW=%s\n' "$ENGINE_PAUSE_ROW" >> "$TRACE"
  printf 'PAUSED_STREAK=%s\n' "$_ENGINE_FAULT_STREAK" >> "$TRACE"
  printf 'PAUSED_DOWNROW=%s\n' "$ENGINE_DOWN_ROW" >> "$TRACE"

  # RESUME: flip the config file (same process, no restart) → next tick dispatches the engine
  printf 'ENGINE_PAUSE=off\n' > "$HERD_CONFIG_FILE"
  _engine_tick_watchdog || true
  printf 'RESUME_ROW=%s\n' "$ENGINE_PAUSE_ROW" >> "$TRACE"
) || true

dispatch_paused_then_resume="$(wc -l < "$DISPATCH" | tr -d ' ')"
paused_row="$(grep -m1 '^PAUSED_ROW=' "$TRACE" | sed 's/^PAUSED_ROW=//')"
paused_streak="$(grep -m1 '^PAUSED_STREAK=' "$TRACE" | sed 's/^PAUSED_STREAK=//')"
paused_downrow="$(grep -m1 '^PAUSED_DOWNROW=' "$TRACE" | sed 's/^PAUSED_DOWNROW=//')"
resume_row="$(grep -m1 '^RESUME_ROW=' "$TRACE" | sed 's/^RESUME_ROW=//')"
n_paused="$(grep -c '^journal:engine_paused$' "$TRACE" || true)"
n_paused_notify="$(grep -c '^notify:.*paused' "$TRACE" || true)"
n_resumed="$(grep -c '^journal:engine_resumed$' "$TRACE" || true)"
n_actions="$(grep -c '^ACTION:' "$TRACE" || true)"

# The dispatch log accrues across the whole run; after resume it must be EXACTLY 1 (the resume tick),
# which also proves the three paused ticks dispatched ZERO.
[ "$dispatch_paused_then_resume" = 1 ] \
  && check zero_dispatch 0 "0 dispatches across 3 paused ticks, then exactly 1 on resume (log=$dispatch_paused_then_resume)" \
  || check zero_dispatch 1 "expected exactly 1 total dispatch (resume only), got $dispatch_paused_then_resume"
case "$paused_row" in *"engine paused by operator"*) check paused_row 0 "loud '⏸ engine paused by operator' banner painted while paused" ;;
                      *) check paused_row 1 "paused banner not set (got: '$paused_row')" ;; esac
[ "$paused_streak" = 0 ] && check no_fault 0 "a paused tick is not a fault (streak stayed 0)" \
                        || check no_fault 1 "paused tick counted as a fault (streak=$paused_streak)"
[ -z "$paused_downrow" ] && check no_engine_down 0 "the engine-down banner never armed from a pause" \
                         || check no_engine_down 1 "engine-down banner wrongly armed while paused (got: '$paused_downrow')"
[ "$n_paused" = 1 ] && check paused_once 0 "engine_paused journaled exactly once for the episode" \
                    || check paused_once 1 "engine_paused journaled ${n_paused}x (want 1)"
[ "$n_paused_notify" = 1 ] && check one_notification 0 "exactly one pause notification fired" \
                           || check one_notification 1 "pause notifications fired ${n_paused_notify}x (want 1)"
[ "$n_actions" = 0 ] && check zero_actions 0 "NO bash gate/merge/resolver ran while paused (safe hold)" \
                     || check zero_actions 1 "$n_actions bash action-pass call(s) leaked while paused"
{ [ -z "$resume_row" ] && [ "$n_resumed" = 1 ]; } \
  && check resume_clean 0 "flipping the config file off cleared the banner + journaled engine_resumed once (fresh read, no restart)" \
  || check resume_clean 1 "resume incomplete (banner_after='$resume_row', resumed=$n_resumed)"

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
  printf '  "dispatches_total": %s,\n' "${dispatch_paused_then_resume:-0}"
  printf '  "paused_fault_streak": %s,\n' "${paused_streak:-0}"
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
