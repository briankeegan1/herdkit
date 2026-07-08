#!/usr/bin/env bash
# herd42-score.sh — the DETERMINISTIC scorer for the HERD-42 herdkit-vs-bare-harness A/B experiment
# (falsification EPIC step 5; protocol: docs/herd42-protocol.md).
#
# It normalizes BOTH arms of the A/B to ONE metric set and writes a machine-readable scorecard.json:
#   • herdkit arm — derived entirely from the engine's own artifacts: `.herd/journal.jsonl` (the
#     append-only gate journal that scripts/herd/journal.sh writes) plus the `cost` events in that
#     same journal (exactly what `herd cost` aggregates — reading them here is equivalent AND
#     deterministic, so the scorer's herdkit dollar figure equals `herd cost` by construction).
#   • bare arm — derived from the hand-kept accounting LEDGER the protocol mandates (a bare native
#     Claude Code operator leaves no engine journal, so the protocol's instrumentation-parity section
#     specifies the exact ledger fields the operator records instead).
# Each arm also supplies its acceptance-suite RESULT (suite_total / escaped) — the fixed oracle that
# both arms are graded against — so defect-escape rate is computed identically for both.
#
# CONTRACT (why this is safe to trust as the experiment's judge):
#   • PURELY DETERMINISTIC + READ-ONLY: same inputs → BYTE-IDENTICAL scorecard.json. It NEVER calls
#     `date`, reads no clock, embeds no random/volatile value, and mutates no engine state — so the
#     unit test (tests/test-herd42-score.sh) can assert known inputs → an EXACT expected scorecard.
#   • ZERO ENGINE COUPLING: it does not source herd-config.sh, touch a worktree, a pane, a tracker,
#     or the live journal. It only READS the files named on its command line.
#   • NO HIDDEN HELP: it derives each arm ONLY from that arm's own declared artifacts, with the SAME
#     normalization math, so neither arm can be silently advantaged by the scorer (instrumentation
#     parity — see the protocol's parity checklist).
#
# Usage:
#   herd42-score.sh --herd-journal <journal.jsonl> --herd-defects <defects.json> \
#                   --bare-ledger  <ledger.json>   --bare-defects  <defects.json> \
#                   [--out <scorecard.json>]
#
#   defects.json (per arm):  {"suite_total": <int>, "escaped": <int>}
#     suite_total — number of merged changes graded by the FIXED acceptance suite.
#     escaped     — merged changes that FAIL that suite (defects that escaped review into main).
#   ledger.json (bare arm):  {"merged_tasks": <int>, "usd_total": <num>,
#                             "human_interventions": <int>, "limit_events": <int>}
#
# Exit: 0 = scorecard written · 1 = bad/missing input or usage error. Prints the scorecard path.
set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage: herd42-score.sh --herd-journal <journal.jsonl> --herd-defects <defects.json> \
                       --bare-ledger  <ledger.json>   --bare-defects  <defects.json> \
                       [--out <scorecard.json>]
EOF
  exit 1
}

HERD_JOURNAL=""; HERD_DEFECTS=""; BARE_LEDGER=""; BARE_DEFECTS=""; OUT="scorecard.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --herd-journal) HERD_JOURNAL="${2:-}"; shift 2 ;;
    --herd-defects) HERD_DEFECTS="${2:-}"; shift 2 ;;
    --bare-ledger)  BARE_LEDGER="${2:-}";  shift 2 ;;
    --bare-defects) BARE_DEFECTS="${2:-}"; shift 2 ;;
    --out)          OUT="${2:-}";          shift 2 ;;
    -h|--help)      usage ;;
    *) echo "herd42-score.sh: unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$HERD_JOURNAL" ] && [ -n "$HERD_DEFECTS" ] && [ -n "$BARE_LEDGER" ] && [ -n "$BARE_DEFECTS" ] \
  || { echo "herd42-score.sh: all four inputs are required" >&2; usage; }
[ -n "$OUT" ] || { echo "herd42-score.sh: --out cannot be empty" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "herd42-score.sh: python3 is required" >&2; exit 1; }

for f in "$HERD_JOURNAL" "$HERD_DEFECTS" "$BARE_LEDGER" "$BARE_DEFECTS"; do
  [ -f "$f" ] || { echo "herd42-score.sh: no such file: $f" >&2; exit 1; }
done

HERD_JOURNAL="$HERD_JOURNAL" HERD_DEFECTS="$HERD_DEFECTS" \
BARE_LEDGER="$BARE_LEDGER" BARE_DEFECTS="$BARE_DEFECTS" OUT="$OUT" python3 -c '
import sys, os, json

def die(msg):
    sys.stderr.write("herd42-score.sh: " + msg + "\n"); sys.exit(1)

def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        die("could not parse %s (%s): %s" % (what, path, e))

def as_int(d, key, what):
    v = d.get(key)
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        die("%s: field %r must be a number" % (what, key))
    return int(v)

def as_num(d, key, what):
    v = d.get(key)
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        die("%s: field %r must be a number" % (what, key))
    return float(v)

# ── herdkit arm — derive from the engine journal (one JSON object per line; malformed lines skipped,
#    matching journal.sh best-effort semantics) ────────────────────────────────────────────────
merged_prs = set()
usd_total = 0.0
holds = 0
limit_parks = 0
limit_manual_wakes = 0
jpath = os.environ["HERD_JOURNAL"]
try:
    jf = open(jpath, encoding="utf-8")
except OSError as e:
    die("could not open herd journal %s: %s" % (jpath, e))
with jf:
    for raw in jf:
        raw = raw.strip()
        if not raw:
            continue
        try:
            o = json.loads(raw)
        except Exception:
            continue  # journal.sh guarantees whole lines, but never trust a corrupt tail
        if not isinstance(o, dict):
            continue
        ev = o.get("event")
        if ev == "merge":
            # A merge event marks a change landed on main. Dedup by pr so a re-journaled merge of the
            # same PR is never double-counted; a merge with no pr still counts as one landed change.
            merged_prs.add(str(o.get("pr", "__nopr_%d__" % len(merged_prs))))
        elif ev == "cost":
            try:
                usd_total += float(o.get("usd", 0) or 0)
            except (TypeError, ValueError):
                pass
        elif ev == "hold_applied":
            # A human-verify hold hands control to a human (operator must run herd-approve).
            holds += 1
        elif ev == "limit_detected":
            # The arm hit a usage limit and PARKED — proof the limit window was exercised.
            limit_parks += 1
        elif ev == "limit_resume_result":
            # woke==0 means auto-resume could NOT wake the builder and a human had to — an intervention.
            try:
                if int(o.get("woke", 1)) == 0:
                    limit_manual_wakes += 1
            except (TypeError, ValueError):
                pass

herd_merged = len(merged_prs)
# Human interventions in the herdkit arm = human-verify holds (each needs an operator approval) plus
# limit auto-resume failures that forced a manual wake. Documented in docs/herd42-protocol.md.
herd_interventions = holds + limit_manual_wakes
herd_spanned = limit_parks > 0

herd_def = load_json(os.environ["HERD_DEFECTS"], "herd defects")
herd_suite_total = as_int(herd_def, "suite_total", "herd defects")
herd_escaped = as_int(herd_def, "escaped", "herd defects")

# ── bare arm — derive from the hand-kept accounting ledger the protocol mandates ────────────────
bare = load_json(os.environ["BARE_LEDGER"], "bare ledger")
bare_merged = as_int(bare, "merged_tasks", "bare ledger")
bare_usd = as_num(bare, "usd_total", "bare ledger")
bare_interventions = as_int(bare, "human_interventions", "bare ledger")
bare_limit_events = as_int(bare, "limit_events", "bare ledger")
bare_spanned = bare_limit_events > 0

bare_def = load_json(os.environ["BARE_DEFECTS"], "bare defects")
bare_suite_total = as_int(bare_def, "suite_total", "bare defects")
bare_escaped = as_int(bare_def, "escaped", "bare defects")

# ── normalize BOTH arms to ONE metric set (identical math for each — instrumentation parity) ────
def per_merged(total, merged):
    return round(total / merged, 4) if merged > 0 else None

def escape_rate(escaped, merged):
    return round(escaped / merged, 6) if merged > 0 else None

def arm(merged, usd, interventions, spanned, suite_total, escaped):
    return {
        "merged_tasks": merged,
        "usd_total": round(usd, 4),
        "usd_per_merged_change": per_merged(usd, merged),
        "acceptance_suite_total": suite_total,
        "defects_escaped": escaped,
        "defect_escape_rate": escape_rate(escaped, merged),
        "human_interventions": interventions,
        "spanned_limit_window": spanned,
    }

herd = arm(herd_merged, usd_total, herd_interventions, herd_spanned, herd_suite_total, herd_escaped)
barm = arm(bare_merged, bare_usd, bare_interventions, bare_spanned, bare_suite_total, bare_escaped)

# ── pairwise comparison (winner per metric; higher-is-better for throughput, lower for the rest) ─
def win_high(a, b):
    if a is None or b is None or a == b:
        return "tie"
    return "herdkit" if a > b else "bare"

def win_low(a, b):
    if a is None or b is None or a == b:
        return "tie"
    return "herdkit" if a < b else "bare"

comparison = {
    "throughput_winner":   win_high(herd["merged_tasks"], barm["merged_tasks"]),
    "cost_winner":         win_low(herd["usd_per_merged_change"], barm["usd_per_merged_change"]),
    "defect_winner":       win_low(herd["defect_escape_rate"], barm["defect_escape_rate"]),
    "intervention_winner": win_low(herd["human_interventions"], barm["human_interventions"]),
}

# ── verdict: the protocol commits to these criteria IN ADVANCE (docs/herd42-protocol.md §falsify) ─
both_spanned = herd_spanned and bare_spanned

# ABORT — the run cannot yield a valid verdict.
abort_reasons = []
if herd_suite_total == 0 or bare_suite_total == 0:
    abort_reasons.append("acceptance suite graded 0 merged changes for an arm — no defect oracle")
if herd_merged == 0 and bare_merged == 0:
    abort_reasons.append("neither arm merged any task — nothing to score")
if not (herd_spanned or bare_spanned):
    abort_reasons.append("no usage-limit window was exercised by either arm — limit-park/auto-resume untested")

def le(a, b):
    return a is not None and b is not None and a <= b

def ge(a, b):
    return a is not None and b is not None and a >= b

# FALSIFICATION — herdkit LOSES iff, across a fairly-crossed limit window, the well-run bare arm
# matches-or-beats herdkit on EVERY metric (throughput, dollars-per-merged, defect escape, human
# interventions). If bare dominates on all four, herdkit adds nothing the raw harness cannot do.
bare_dominates = (
    ge(bare_merged, herd_merged) and
    le(barm["usd_per_merged_change"], herd["usd_per_merged_change"]) and
    le(barm["defect_escape_rate"], herd["defect_escape_rate"]) and
    le(bare_interventions, herd_interventions)
)
herd_dominates = (
    ge(herd_merged, bare_merged) and
    le(herd["usd_per_merged_change"], barm["usd_per_merged_change"]) and
    le(herd["defect_escape_rate"], barm["defect_escape_rate"]) and
    le(herd_interventions, bare_interventions)
)

falsified = bool(both_spanned and bare_dominates)
herd_confirmed = bool(both_spanned and herd_dominates and not bare_dominates)

verdict = {
    "both_spanned_limit_window": both_spanned,
    "abort": bool(abort_reasons),
    "abort_reasons": abort_reasons,
    "falsified": falsified,
    "herdkit_thesis_confirmed": herd_confirmed,
}

scorecard = {
    "experiment": "herd42-ab",
    "schema_version": 1,
    "inputs": {
        "herd_journal": os.environ["HERD_JOURNAL"],
        "herd_defects": os.environ["HERD_DEFECTS"],
        "bare_ledger": os.environ["BARE_LEDGER"],
        "bare_defects": os.environ["BARE_DEFECTS"],
    },
    "arms": {"herdkit": herd, "bare": barm},
    "comparison": comparison,
    "verdict": verdict,
}

out = os.environ["OUT"]
with open(out, "w", encoding="utf-8") as f:
    json.dump(scorecard, f, indent=2, sort_keys=True)
    f.write("\n")
sys.stdout.write(out + "\n")
' || exit 1
