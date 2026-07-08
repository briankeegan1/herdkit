#!/usr/bin/env bash
# scripts/herd/sim/sandbox-posture-matrix.sh — the POSTURE MATRIX wrapper (HERD-153).
#
# Proves the shipped gate loop under EVERY canonical config posture (templates/postures.tsv) at zero
# quota. For each posture it runs the scenario that structurally exercises that posture's invariant —
# the merge-policy postures through the CONCURRENCY scenario (which drives the real do_merge gate loop),
# the push/steps postures through the linear GATE scenario (which drives the real push-gate + pipeline-
# steps seams) — passing --posture, and collects ONE scorecard PER posture under <artifacts>/<posture>/.
# It then runs the REGRESSION self-check: the custom-steps posture with SANDBOX_FORCE_STEPS_FAULT=1
# (the PR #249 defect class — a steps ledger that double-releases / releases a stale sha) MUST come back
# RED, proving the sim catches the regression. Finally it asserts solo-auto is byte-identical (checkpoint
# name+status) to a plain single-posture concurrency run, and emits a combined <artifacts>/matrix.json.
#
# This is an EXPLICIT invocation (a nightly candidate, not a per-merge gate): the default single-posture
# scenarios stay byte-identical and cheap; the matrix is opt-in. Fully hermetic — local git only, NO
# herdr, NO network, NO model, NO screenshots (the caller sets SANDBOX_NO_SCREENSHOT=1).
#
# Usage:
#   bash scripts/herd/sim/sandbox-posture-matrix.sh [--artifacts DIR] [--keep] [--posture NAME]
#     --artifacts DIR   put every per-posture run + matrix.json here (default: a fresh mktemp dir)
#     --keep            do not delete the artifacts dir on exit (implied when --artifacts is given)
#     --posture NAME    run ONLY this posture (default: every posture in templates/postures.tsv)
#   Env passthrough: SANDBOX_NO_SCREENSHOT, SANDBOX_REVIEW_DELAY, POSTURES_FILE.
#
# Exit: 0 = every posture green AND the injected fault was caught red AND solo-auto byte-identical ·
#       1 = a posture failed, the fault was NOT caught, or solo-auto diverged (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/herd/sim/posture-lib.sh
. "$HERE/posture-lib.sh"

CONC="$HERE/sandbox-concurrency-scenario.sh"
GATE="$HERE/sandbox-scenario.sh"

c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ──────────────────────────────────────────────────────────────────────────
ART=""; KEEP=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    --posture)   ONLY="${2:-}"; shift 2 ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-posture-matrix: unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [ -z "$ART" ]; then ART="$(mktemp -d)"; fi
mkdir -p "$ART"
if [ -z "$KEEP" ]; then trap 'rm -rf "$ART"' EXIT; fi

# _scenario_for <posture> — echo the scenario path that proves this posture's invariant.
_scenario_for() {
  case "$1" in
    solo-auto|team-approve|observe-only) printf '%s' "$CONC" ;;
    gated-push|custom-steps)             printf '%s' "$GATE" ;;
    *) return 1 ;;
  esac
}

# _sc_field <scorecard> <key> — read a top-level scalar from a scorecard (empty if absent/bad JSON).
_sc_field() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2],""))
except Exception: print("")' "$1" "$2" 2>/dev/null; }

printf '%s══ POSTURE MATRIX — proving the gate loop under every canonical posture ══%s\n' "$c_bold" "$c_rst"
printf '  postures file: %s\n' "$(posture_file)"
printf '  artifacts:     %s\n' "$ART"

# The list of postures to run (all, or a single --posture).
if [ -n "$ONLY" ]; then
  posture_exists "$ONLY" || { echo "sandbox-posture-matrix: unknown posture: $ONLY" >&2; exit 1; }
  POSTURES="$ONLY"
else
  POSTURES="$(posture_names | tr '\n' ' ')"
fi

# Parallel result arrays (bash 3.2: no assoc arrays).
M_NAMES=(); M_SCEN=(); M_RESULT=(); M_CARD=()
GREEN=0; TOTAL=0

# run_posture <name> — run its scenario with --posture, record the result. Returns 0 iff green.
run_posture() {
  local p="$1" scen card rc result
  scen="$(_scenario_for "$p")" || { bad "$p — no scenario mapping"; return 1; }
  step "$p" "$(posture_intent "$p")"
  info "scenario: ${scen##*/}"
  local dir="$ART/$p"; mkdir -p "$dir"
  SANDBOX_NO_SCREENSHOT="${SANDBOX_NO_SCREENSHOT:-1}" \
    bash "$scen" --posture "$p" --artifacts "$dir" >"$dir/run.out" 2>&1
  rc=$?
  card="$dir/scorecard.json"
  if [ -f "$card" ]; then result="$(_sc_field "$card" result)"; else result="ERROR"; fi
  M_NAMES+=("$p"); M_SCEN+=("${scen##*/}"); M_RESULT+=("$result"); M_CARD+=("$card")
  TOTAL=$((TOTAL+1))
  if [ "$rc" -eq 0 ] && [ "$result" = pass ]; then
    GREEN=$((GREEN+1)); ok "$p → $result (scorecard: $card)"; return 0
  else
    bad "$p → ${result:-ERROR} (rc=$rc) — see $dir/run.out"; return 1
  fi
}

for p in $POSTURES; do run_posture "$p" || true; done

# ── REGRESSION SELF-CHECK: the injected PR #249 fault must be CAUGHT RED ──────────────────────────
# Only meaningful when custom-steps is in the run set (it carries the fault seam).
FAULT_CAUGHT="n/a"; FAULT_RESULT=""
case " $POSTURES " in
  *" custom-steps "*)
    step fault "regression self-check — custom-steps + SANDBOX_FORCE_STEPS_FAULT=1 must come back RED"
    fdir="$ART/custom-steps-fault"; mkdir -p "$fdir"
    frc=0
    SANDBOX_NO_SCREENSHOT="${SANDBOX_NO_SCREENSHOT:-1}" SANDBOX_FORCE_STEPS_FAULT=1 \
      bash "$GATE" --posture custom-steps --artifacts "$fdir" >"$fdir/run.out" 2>&1 || frc=$?
    FAULT_RESULT="$(_sc_field "$fdir/scorecard.json" result)"
    _fault_flip="$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(",".join(c["name"] for c in d["checkpoints"] if c["status"]=="fail"))
except Exception: print("")' "$fdir/scorecard.json" 2>/dev/null)"
    if [ "$frc" -ne 0 ] && [ "$FAULT_RESULT" = fail ] && [ "$_fault_flip" = posture_invariant ]; then
      FAULT_CAUGHT="yes"; ok "fault caught: result=fail, flipped exactly [$_fault_flip] (exit $frc)"
    else
      FAULT_CAUGHT="no"; bad "fault NOT caught cleanly (rc=$frc, result=$FAULT_RESULT, flipped=[$_fault_flip])"
    fi
    ;;
esac

# ── BYTE-IDENTICAL SOLO-AUTO: --posture solo-auto == a plain single-posture concurrency run ───────
# Only meaningful when solo-auto is in the run set. Compare checkpoint (name,status) arrays — the detail
# strings carry per-run paths/counts, but the gate DECISIONS (names + statuses) must be identical.
SOLO_IDENTICAL="n/a"
case " $POSTURES " in
  *" solo-auto "*)
    step byte-identical "solo-auto must be byte-identical (checkpoint name+status) to a plain concurrency run"
    plain="$ART/plain-concurrency"; mkdir -p "$plain"
    SANDBOX_NO_SCREENSHOT="${SANDBOX_NO_SCREENSHOT:-1}" \
      bash "$CONC" --artifacts "$plain" >"$plain/run.out" 2>&1 || true
    if python3 -c '
import json,sys
def cps(f):
    d=json.load(open(f))
    return [(c["name"],c["status"]) for c in d["checkpoints"]]
a=cps(sys.argv[1]); b=cps(sys.argv[2])
sys.exit(0 if a==b else 1)
' "$plain/scorecard.json" "$ART/solo-auto/scorecard.json" 2>/dev/null; then
      SOLO_IDENTICAL="yes"; ok "solo-auto checkpoints byte-identical to the plain run"
    else
      SOLO_IDENTICAL="no"; bad "solo-auto DIVERGED from the plain single-posture run"
    fi
    ;;
esac

# ── emit matrix.json ──────────────────────────────────────────────────────────────
OVERALL="pass"
[ "$GREEN" -ne "$TOTAL" ] && OVERALL="fail"
case " $POSTURES " in *" custom-steps "*) [ "$FAULT_CAUGHT" = yes ] || OVERALL="fail" ;; esac
case " $POSTURES " in *" solo-auto "*)    [ "$SOLO_IDENTICAL" = yes ] || OVERALL="fail" ;; esac

MATRIX="$ART/matrix.json"
{
  printf '{\n'
  printf '  "matrix": "posture-matrix",\n'
  printf '  "postures_total": %d,\n' "$TOTAL"
  printf '  "postures_green": %d,\n' "$GREEN"
  printf '  "fault_injection": {"posture": "custom-steps", "caught": "%s", "result": "%s"},\n' "$FAULT_CAUGHT" "${FAULT_RESULT:-}"
  printf '  "solo_auto_byte_identical": "%s",\n' "$SOLO_IDENTICAL"
  printf '  "result": "%s",\n' "$OVERALL"
  printf '  "postures": [\n'
  _n=${#M_NAMES[@]}
  for ((i=0; i<_n; i++)); do
    printf '    {"posture": "%s", "scenario": "%s", "result": "%s", "scorecard": "%s"}' \
      "${M_NAMES[$i]}" "${M_SCEN[$i]}" "${M_RESULT[$i]}" "${M_CARD[$i]}"
    [ "$i" -lt "$((_n-1))" ] && printf ',\n' || printf '\n'
  done
  printf '  ]\n'
  printf '}\n'
} > "$MATRIX"

printf '\n%s══ matrix summary ══%s\n' "$c_bold" "$c_rst"
_n=${#M_NAMES[@]}
for ((i=0; i<_n; i++)); do
  _mk="${c_grn}✓${c_rst}"; [ "${M_RESULT[$i]}" != pass ] && _mk="${c_red}✗${c_rst}"
  printf '  %s %-14s %-34s %s\n' "$_mk" "${M_NAMES[$i]}" "${M_SCEN[$i]}" "${M_RESULT[$i]}"
done
printf '  postures green:  %d/%d\n' "$GREEN" "$TOTAL"
printf '  fault caught:    %s (result=%s)\n' "$FAULT_CAUGHT" "${FAULT_RESULT:-n/a}"
printf '  solo-auto ident: %s\n' "$SOLO_IDENTICAL"
printf '  overall:         %s\n' "$OVERALL"
printf '  matrix.json:     %s\n' "$MATRIX"

[ "$OVERALL" = pass ] && exit 0 || exit 1
