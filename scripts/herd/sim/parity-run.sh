#!/usr/bin/env bash
# scripts/herd/sim/parity-run.sh — P3a journal-diff PARITY HARNESS orchestration (HERD-314).
#
# The acceptance instrument for the engine port (EPIC HERD-300, Phase 3): drive a sim scenario
# against the engine, collect the journal event stream it emits, and diff it against a SHADOW
# journal via pysrc/herd/parity.py (canonicalize away timestamps/pids/paths, then compare).
#   • Same events under canonicalization → exit 0 (parity).
#   • A divergence → parity.py prints a per-mismatch report → exit 1.
#
# INTERFACE CONTRACT (shared by all P3 builders, docs/engine-contract.md §3/§7):
#   The Python shadow engine journals to  .herd/journal-shadow.jsonl  in the SAME event shapes as
#   journal.sh. This harness compares the REAL sim journal (what the bash engine wrote) against that
#   shadow journal, per scenario. Shadow-journal resolution order:
#     1. --shadow FILE                                  (explicit; e.g. a captured P3c run)
#     2. $ART/.herd/journal-shadow.jsonl                (the P3c shadow engine, once it exists)
#     3. SELF-DIFF (default today): a --perturb copy of the real journal — volatile fields
#        (ts/pid/paths) rewritten, everything else identical. Canonicalization must fold the
#        perturbation back to identity, so a green self-diff is a live proof of the canonicalizer
#        on real journal data (item: "works TODAY with only the bash engine … proves canonicalization").
#
# It also READS THE SCORECARD the scenario wrote ($ART/scorecard.json) and surfaces its result, so a
# parity run reports both the event-stream verdict and the scenario's own pass/fail from file.
#
# Usage:
#   bash scripts/herd/sim/parity-run.sh [--scenario NAME] [--artifacts DIR] [--shadow FILE]
#                                       [--max N] [--keep]
#     --scenario NAME   sim scenario basename under scripts/herd/sim/ (default: sandbox-scenario.sh;
#                       a bare name or a *.sh name both resolve).
#     --artifacts DIR   run the scenario here and keep artifacts (default: fresh mktemp, kept).
#     --shadow FILE     use FILE as the shadow journal instead of the self-diff default.
#     --max N           cap the number of divergence records printed (passed to parity.py).
#     --keep            keep the artifacts dir (implied; the scenario needs --keep to leave journals).
#
# Exit: 0 = journal parity AND scorecard result not "fail" · 1 = journal divergence or scorecard
#       fail · 2 = infra (scenario could not run, no journal produced, unreadable inputs). Loud on 2 —
#       an empty or missing journal must NEVER read as a silent green (discover-tests.bash doctrine).
#
# Fail-soft / hermetic: no config keys, no model calls, no tracker/BACKLOG writes. python3 is the
# only hard dep (already an engine dependency).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PYSRC="$REPO/pysrc"

c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
info() { printf '  → %s\n' "$*"; }
good() { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
warn() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }

command -v python3 >/dev/null 2>&1 || { echo "parity-run: python3 required" >&2; exit 2; }

SCENARIO="sandbox-scenario.sh"; ART=""; SHADOW=""; MAX=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scenario)  SCENARIO="${2:-}"; shift 2 ;;
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --shadow)    SHADOW="${2:-}"; shift 2 ;;
    --max)       MAX="${2:-}"; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "parity-run: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Resolve the scenario script (accept "sandbox-scenario" or "sandbox-scenario.sh").
case "$SCENARIO" in *.sh) : ;; *) SCENARIO="$SCENARIO.sh" ;; esac
SCEN_PATH="$HERE/$SCENARIO"
[ -f "$SCEN_PATH" ] || { echo "parity-run: no such scenario: $SCEN_PATH" >&2; exit 2; }

if [ -z "$ART" ]; then ART="$(mktemp -d)"; fi
mkdir -p "$ART"
# Always --keep the scenario: the whole point is to inspect the journals it leaves behind.
KEEP=1

printf '%s══ Journal-diff parity harness: %s ══%s\n' "$c_bold" "$SCENARIO" "$c_rst"
info "artifacts: $ART"

# ── drive the scenario ───────────────────────────────────────────────────────────────────────────
# The scenario asserts its own checkpoints and writes $ART/scorecard.json + one-or-more journal
# JSONL files under $ART. We do NOT gate on the scenario's exit here (a scenario may legitimately
# exit 1 on a fault-injection leg); the scorecard is read separately below.
SCEN_LOG="$ART/scenario.log"
bash "$SCEN_PATH" --artifacts "$ART" >"$SCEN_LOG" 2>&1
scen_rc=$?
if [ "$scen_rc" -gt 1 ]; then
  bad "scenario errored hard (rc=$scen_rc); see $SCEN_LOG"
  tail -20 "$SCEN_LOG" >&2 || true
  exit 2
fi
info "scenario exit: $scen_rc"

# ── collect the REAL journal: every *.jsonl the scenario left, concatenated in a stable order ─────
# The sandbox scenarios journal per-leg to distinct files under $ART; the real event stream for the
# scenario is their union. Sort by path (LC_ALL=C) so the concatenation is deterministic. Exclude
# any pre-existing shadow file so it can never leak into the "real" side.
REAL="$ART/journal-real.jsonl"; : > "$REAL"
found=0
while IFS= read -r jf; do
  [ -n "$jf" ] || continue
  case "$jf" in */journal-real.jsonl|*/journal-shadow.jsonl) continue ;; esac
  cat "$jf" >> "$REAL"
  found=1
done < <(find "$ART" -type f -name '*.jsonl' 2>/dev/null | LC_ALL=C sort)

real_lines="$(grep -c . "$REAL" 2>/dev/null || echo 0)"
if [ "$found" -eq 0 ] || [ "${real_lines:-0}" -eq 0 ]; then
  bad "no journal events produced under $ART — cannot assess parity (loud: not a silent green)"
  exit 2
fi
good "collected real journal: $real_lines events → $REAL"

# ── resolve the SHADOW journal (see the interface-contract block above) ───────────────────────────
SHADOW_JOURNAL="$ART/journal-shadow.jsonl"
mode=""
if [ -n "$SHADOW" ]; then
  [ -f "$SHADOW" ] || { bad "--shadow file not found: $SHADOW"; exit 2; }
  cp "$SHADOW" "$SHADOW_JOURNAL"; mode="explicit (--shadow)"
elif [ -f "$ART/.herd/journal-shadow.jsonl" ]; then
  cp "$ART/.herd/journal-shadow.jsonl" "$SHADOW_JOURNAL"; mode="python shadow engine (.herd/journal-shadow.jsonl)"
else
  # Self-diff: perturb ONLY the volatile categories, so canonicalization must fold them back.
  if ! PYTHONPATH="$PYSRC" python3 -m herd.parity --perturb "$REAL" > "$SHADOW_JOURNAL" 2>"$ART/perturb.err"; then
    bad "could not build the self-diff shadow journal: $(cat "$ART/perturb.err" 2>/dev/null)"
    exit 2
  fi
  mode="self-diff (perturbed copy — no python shadow engine yet)"
fi
info "shadow journal: $mode"

# ── diff the two event streams via the canonicalizer ──────────────────────────────────────────────
parity_rc=0
PYTHONPATH="$PYSRC" python3 -m herd.parity "$REAL" "$SHADOW_JOURNAL" \
  --label-real "sim:$SCENARIO" --label-shadow "$mode" ${MAX:+--max "$MAX"} \
  || parity_rc=$?
case "$parity_rc" in
  0) good "journal parity: OK" ;;
  1) bad  "journal parity: DIVERGENT (see report above)" ;;
  *) bad  "journal parity: INFRA error (rc=$parity_rc)"; exit 2 ;;
esac

# ── read the SCORECARD from file and surface its result ───────────────────────────────────────────
SCORECARD="$ART/scorecard.json"
scorecard_result=""
if [ -f "$SCORECARD" ]; then
  scorecard_result="$(PYTHONPATH="$PYSRC" python3 - "$SCORECARD" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    sys.exit(0)
print("%s passed=%s failed=%s skipped=%s result=%s" % (
    d.get("scenario", "?"), d.get("passed", "?"), d.get("failed", "?"),
    d.get("skipped", "?"), d.get("result", "?")))
sys.stdout = sys.stderr  # nothing more
PY
)"
  if [ -n "$scorecard_result" ]; then
    case "$scorecard_result" in
      *"result=fail"*) bad  "scorecard: $scorecard_result" ;;
      *)               good "scorecard: $scorecard_result" ;;
    esac
  else
    warn "scorecard present but unreadable: $SCORECARD"
  fi
else
  warn "no scorecard written by scenario (no $SCORECARD)"
fi

# ── final verdict: parity AND the scorecard must both be clean ────────────────────────────────────
final=0
[ "$parity_rc" -ne 0 ] && final=1
case "$scorecard_result" in *"result=fail"*) final=1 ;; esac
if [ "$final" -eq 0 ]; then
  printf '%s✓ PARITY RUN CLEAN%s (journal parity + scorecard)\n' "$c_grn" "$c_rst"
else
  printf '%s✗ PARITY RUN FAILED%s (journal divergence or scorecard fail)\n' "$c_red" "$c_rst"
fi
exit "$final"
