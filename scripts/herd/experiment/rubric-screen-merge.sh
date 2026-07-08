#!/usr/bin/env bash
# rubric-screen-merge.sh — the DETERMINISTIC dual-screener MERGE step for the rubric-screening
# primitive (HERD-166). It is the cross-check that turns two INDEPENDENT screener passes over the
# same batch of items into ONE reviewable artifact: it validates each pass against the verdict
# contract, computes inter-screener agreement stats, and SURFACES the disagreement pile (plus the
# agree-but-unsure cells) for a human to adjudicate.
#
# This is a NEW, STANDALONE step. It has NOTHING to do with the watcher's git-merge path — it never
# touches git, a worktree, a pane, a tracker, or the engine journal. It only READS the two verdict
# files named on its command line and WRITES the report (and, optionally, a surface CSV).
#
# VERDICT CONTRACT (what a screener agent emits — see docs/rubric-screening.md):
#   Five columns / keys per row:  item_id | criterion | verdict | reason | confidence
#     item_id     — stable id of the item being screened (free text; keys the batch).
#     criterion   — the rubric criterion this row judges (free text).
#     verdict     — one of the vocabulary (default: pass | fail | unsure), case-insensitive.
#     reason      — the screener's short justification (free text; may be empty).
#     confidence  — a number in [0,1], or empty (→ null). How sure the screener is.
#   Accepted as CSV (comma), TSV (tab), or JSON (an array of objects). Format is auto-detected from
#   the file extension, then by sniffing the first non-space byte ('['/'{' → JSON). A (item_id,
#   criterion) pair is a CELL and must be UNIQUE within one file (a duplicate cell is a hard error —
#   the screener contradicted itself).
#
# CONTRACT (why this is safe to trust as the cross-check):
#   • PURELY DETERMINISTIC + READ-ONLY: same inputs → BYTE-IDENTICAL report.json. It NEVER calls
#     `date`, reads no clock, embeds no random/volatile value, and mutates no engine state — so the
#     unit test (tests/test-rubric-screen-merge.sh) asserts known inputs → an EXACT report.
#   • ZERO ENGINE COUPLING: it does not source herd-config.sh and touches nothing the engine owns.
#   • FAIL-SOFT + DEFAULT-DORMANT: nothing in the engine calls it; it ships dormant. Bad input is a
#     clean exit 1 with an actionable message, never a stack trace or a partial report.
#
# Usage:
#   rubric-screen-merge.sh --a <screener-a> --b <screener-b> \
#                          [--out <report.json>] [--surface-csv <disagreements.csv>] \
#                          [--labels pass,fail,unsure]
#
# Exit: 0 = report written · 1 = bad/missing input, contract violation, or usage error.
# Prints the report path on stdout; a one-line human summary on stderr.
set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage: rubric-screen-merge.sh --a <screener-a> --b <screener-b> \
                             [--out <report.json>] [--surface-csv <disagreements.csv>] \
                             [--labels pass,fail,unsure]

  --a / --b       the two screener verdict files (CSV, TSV, or JSON) over the SAME items.
  --out           where to write the merge report JSON (default: rubric-merge.json).
  --surface-csv   also write the human-review pile (disagreements + unsure cells) as CSV.
  --labels        comma-separated verdict vocabulary (default: pass,fail,unsure).
EOF
  exit 1
}

A=""; B=""; OUT="rubric-merge.json"; SURFACE_CSV=""; LABELS="pass,fail,unsure"
while [ $# -gt 0 ]; do
  case "$1" in
    --a)            A="${2:-}";           shift 2 ;;
    --b)            B="${2:-}";           shift 2 ;;
    --out)          OUT="${2:-}";         shift 2 ;;
    --surface-csv)  SURFACE_CSV="${2:-}"; shift 2 ;;
    --labels)       LABELS="${2:-}";      shift 2 ;;
    -h|--help)      usage ;;
    *) echo "rubric-screen-merge.sh: unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$A" ] && [ -n "$B" ] || { echo "rubric-screen-merge.sh: both --a and --b are required" >&2; usage; }
[ -n "$OUT" ] || { echo "rubric-screen-merge.sh: --out cannot be empty" >&2; exit 1; }
[ -n "$LABELS" ] || { echo "rubric-screen-merge.sh: --labels cannot be empty" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "rubric-screen-merge.sh: python3 is required" >&2; exit 1; }

for f in "$A" "$B"; do
  [ -f "$f" ] || { echo "rubric-screen-merge.sh: no such file: $f" >&2; exit 1; }
done

A_PATH="$A" B_PATH="$B" OUT="$OUT" SURFACE_CSV="$SURFACE_CSV" LABELS="$LABELS" \
python3 - <<'PY' || exit 1
import sys, os, csv, json, io
from collections import Counter

PREFIX = "rubric-screen-merge.sh: "
def die(msg):
    sys.stderr.write(PREFIX + msg + "\n"); sys.exit(1)

LABELS = [x.strip().lower() for x in os.environ["LABELS"].split(",") if x.strip()]
if not LABELS:
    die("--labels resolved to an empty vocabulary")
LABEL_SET = set(LABELS)
UNSURE = "unsure"  # a label with this exact name (if present) always routes to human review

REQUIRED = ("item_id", "criterion", "verdict", "reason", "confidence")

def sniff_format(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".json":
        return "json"
    if ext == ".tsv":
        return "tsv"
    if ext == ".csv":
        return "csv"
    # No decisive extension: sniff the first non-space byte.
    try:
        with open(path, encoding="utf-8") as f:
            head = f.read(4096)
    except OSError as e:
        die("could not read %s: %s" % (path, e))
    for ch in head:
        if ch.isspace():
            continue
        return "json" if ch in "[{" else "csv"
    die("%s is empty" % path)

def norm_confidence(raw, what):
    if raw is None:
        return None
    if isinstance(raw, bool):
        die("%s: confidence must be a number in [0,1] or empty" % what)
    if isinstance(raw, (int, float)):
        val = float(raw)
    else:
        s = str(raw).strip()
        if s == "":
            return None
        try:
            val = float(s)
        except ValueError:
            die("%s: confidence %r is not a number" % (what, raw))
    if not (0.0 <= val <= 1.0):
        die("%s: confidence %s is outside [0,1]" % (what, val))
    return round(val, 6)

def norm_verdict(raw, what):
    v = str(raw).strip().lower()
    if v == "":
        die("%s: verdict is empty" % what)
    if v not in LABEL_SET:
        die("%s: verdict %r is not in the vocabulary %s" % (what, v, "|".join(LABELS)))
    return v

def add_cell(cells, path, item_id, criterion, verdict, reason, confidence):
    item_id = str(item_id).strip()
    criterion = str(criterion).strip()
    if item_id == "":
        die("%s: a row has an empty item_id" % path)
    if criterion == "":
        die("%s: item %r has a row with an empty criterion" % (path, item_id))
    key = (item_id, criterion)
    what = "%s [%s / %s]" % (path, item_id, criterion)
    if key in cells:
        die("%s: duplicate cell (item_id=%r, criterion=%r) — a screener must judge each cell once"
            % (path, item_id, criterion))
    cells[key] = {
        "verdict": norm_verdict(verdict, what),
        "reason": "" if reason is None else str(reason),
        "confidence": norm_confidence(confidence, what),
    }

def load_delimited(path, delim):
    cells = {}
    try:
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f, delimiter=delim)
            if reader.fieldnames is None:
                die("%s has no header row" % path)
            header = [h.strip().lower() for h in reader.fieldnames]
            missing = [c for c in REQUIRED if c not in header]
            if missing:
                die("%s is missing required column(s): %s" % (path, ", ".join(missing)))
            for row in reader:
                norm = {}
                for k, v in row.items():
                    if k is None:
                        continue
                    norm[k.strip().lower()] = v
                add_cell(cells, path, norm.get("item_id", ""), norm.get("criterion", ""),
                         norm.get("verdict", ""), norm.get("reason", ""), norm.get("confidence", ""))
    except (OSError, UnicodeDecodeError) as e:
        die("could not read %s: %s" % (path, e))
    if not cells:
        die("%s has a header but no data rows" % path)
    return cells

def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, UnicodeDecodeError, ValueError) as e:
        die("could not parse JSON %s: %s" % (path, e))
    if not isinstance(data, list):
        die("%s: JSON verdict file must be an array of objects" % path)
    cells = {}
    for i, row in enumerate(data):
        if not isinstance(row, dict):
            die("%s: element %d is not an object" % (path, i))
        missing = [c for c in REQUIRED if c not in row]
        if missing:
            die("%s: element %d is missing key(s): %s" % (path, i, ", ".join(missing)))
        add_cell(cells, path, row.get("item_id", ""), row.get("criterion", ""),
                 row.get("verdict", ""), row.get("reason", ""), row.get("confidence", ""))
    if not cells:
        die("%s: JSON array is empty" % path)
    return cells

def load(path):
    fmt = sniff_format(path)
    if fmt == "json":
        return load_json(path)
    return load_delimited(path, "\t" if fmt == "tsv" else ",")

A = load(os.environ["A_PATH"])
B = load(os.environ["B_PATH"])

keys_a, keys_b = set(A), set(B)
common = sorted(keys_a & keys_b)
only_in_a = sorted(keys_a - keys_b)
only_in_b = sorted(keys_b - keys_a)

def as_cell_list(keys):
    return [{"item_id": k[0], "criterion": k[1]} for k in keys]

agreements = disagreements = 0
unsure_agree = 0
confusion = Counter()
surface = []
for key in common:
    ca, cb = A[key], B[key]
    va, vb = ca["verdict"], cb["verdict"]
    confusion["%s|%s" % (va, vb)] += 1
    kind = None
    if va == vb:
        agreements += 1
        if va == UNSURE:
            unsure_agree += 1
            kind = "unsure"
    else:
        disagreements += 1
        kind = "disagreement"
    if kind is not None:
        surface.append({
            "item_id": key[0],
            "criterion": key[1],
            "kind": kind,
            "verdict_a": va,
            "verdict_b": vb,
            "confidence_a": ca["confidence"],
            "confidence_b": cb["confidence"],
            "reason_a": ca["reason"],
            "reason_b": cb["reason"],
        })

n = len(common)
agreement_rate = round(agreements / n, 6) if n else None

# Cohen's kappa over the common cells (chance-corrected agreement). Undefined (null) when there is
# nothing to compare or when both raters are perfectly constant on the same label (pe == 1).
kappa = None
if n:
    po = agreements / n
    marg_a = Counter(A[k]["verdict"] for k in common)
    marg_b = Counter(B[k]["verdict"] for k in common)
    pe = sum((marg_a.get(l, 0) / n) * (marg_b.get(l, 0) / n) for l in (set(marg_a) | set(marg_b)))
    kappa = None if pe == 1 else round((po - pe) / (1 - pe), 6)

review_count = len(surface)
coverage_gap = bool(only_in_a or only_in_b)
clean_merge = (review_count == 0) and not coverage_gap

report = {
    "primitive": "rubric-screen-merge",
    "schema_version": 1,
    "labels": LABELS,
    "inputs": {"screener_a": os.environ["A_PATH"], "screener_b": os.environ["B_PATH"]},
    "coverage": {
        "cells_a": len(A),
        "cells_b": len(B),
        "common_cells": n,
        "only_in_a": as_cell_list(only_in_a),
        "only_in_b": as_cell_list(only_in_b),
    },
    "agreement": {
        "compared_cells": n,
        "agreements": agreements,
        "disagreements": disagreements,
        "agreement_rate": agreement_rate,
        "cohen_kappa": kappa,
        "confusion": dict(confusion),
    },
    "review_surface": surface,   # already in (item_id, criterion) order — common is sorted
    "verdict": {
        "clean_merge": clean_merge,
        "needs_human_review": review_count > 0,
        "review_count": review_count,
        "disagreement_count": disagreements,
        "unsure_agreement_count": unsure_agree,
        "coverage_gap": coverage_gap,
    },
}

out = os.environ["OUT"]
try:
    with open(out, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, sort_keys=True)
        f.write("\n")
except OSError as e:
    die("could not write report %s: %s" % (out, e))

surface_csv = os.environ.get("SURFACE_CSV", "")
if surface_csv:
    try:
        with open(surface_csv, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f, lineterminator="\n")   # LF, not the csv default CRLF — deterministic
            w.writerow(["item_id", "criterion", "kind", "verdict_a", "verdict_b",
                        "confidence_a", "confidence_b", "reason_a", "reason_b"])
            for r in surface:
                w.writerow([
                    r["item_id"], r["criterion"], r["kind"], r["verdict_a"], r["verdict_b"],
                    "" if r["confidence_a"] is None else r["confidence_a"],
                    "" if r["confidence_b"] is None else r["confidence_b"],
                    r["reason_a"], r["reason_b"],
                ])
    except OSError as e:
        die("could not write surface CSV %s: %s" % (surface_csv, e))

# One-line human summary → stderr; the report path → stdout (so callers can capture it).
rate = "n/a" if agreement_rate is None else ("%.4f" % agreement_rate)
kap = "n/a" if kappa is None else ("%.4f" % kappa)
sys.stderr.write(
    "%s%d cells compared · %d agree · %d need review (%d disagree, %d agree-unsure) "
    "· rate=%s · kappa=%s%s\n" % (
        PREFIX, n, agreements, review_count, disagreements, unsure_agree, rate, kap,
        " · COVERAGE GAP" if coverage_gap else ""))
sys.stdout.write(out + "\n")
PY
