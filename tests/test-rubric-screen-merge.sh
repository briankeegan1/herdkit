#!/usr/bin/env bash
# test-rubric-screen-merge.sh — hermetic tests for the rubric-screening dual-screener MERGE
# (scripts/herd/experiment/rubric-screen-merge.sh). The merge is the primitive's deterministic
# cross-check, so this asserts KNOWN INPUTS → an EXACT report.json (byte-for-byte), plus the
# agreement stats, the disagreement surface, the coverage-gap path, and every contract-violation.
# Covers:
#   (1) EXACT report + EXACT surface CSV from a fixture with one agree, one disagree, one
#       agree-unsure, a coverage gap on each side, and a null confidence — proving determinism and
#       exercising BOTH loaders (screener-a=CSV, screener-b=JSON), kappa, and the confusion matrix.
#   (2) CLEAN MERGE: two identical passes → clean_merge true, zero review surface, no coverage gap.
#   (3) TSV loader + extension-less format sniff both parse.
#   (4) custom --labels vocabulary (include/exclude) is honored.
#   (5) contract violations each fail with exit 1: unknown verdict, out-of-range confidence,
#       duplicate cell, missing column, missing flag, missing file, empty item_id.
#
# Fully hermetic: writes only under a mktemp dir, runs the merge with RELATIVE input paths (so the
# echoed `inputs` block is stable), and touches no engine state, worktree, pane, or live journal.
# Run:  bash tests/test-rubric-screen-merge.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MERGE="$REPO/scripts/herd/experiment/rubric-screen-merge.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$MERGE" ] || fail "merge not found at $MERGE"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
bash -n "$MERGE" || fail "merge has a syntax error"

cd "$T" || fail "cannot cd to temp dir"

# ── (1) EXACT report + surface from a known fixture ──
cat > a.csv <<'CSV'
item_id,criterion,verdict,reason,confidence
i1,c1,pass,ok,0.9
i1,c2,pass,looks fine,0.8
i2,c1,unsure,cannot tell,0.3
i2,c2,fail,,
CSV
cat > b.json <<'JSON'
[
 {"item_id":"i1","criterion":"c1","verdict":"pass","reason":"agree","confidence":0.7},
 {"item_id":"i1","criterion":"c2","verdict":"fail","reason":"nope","confidence":0.6},
 {"item_id":"i2","criterion":"c1","verdict":"unsure","reason":"unclear","confidence":0.2},
 {"item_id":"i3","criterion":"c1","verdict":"pass","reason":"new item","confidence":0.5}
]
JSON

cat > expected.json <<'EXP'
{
  "agreement": {
    "agreement_rate": 0.666667,
    "agreements": 2,
    "cohen_kappa": 0.5,
    "compared_cells": 3,
    "confusion": {
      "pass|fail": 1,
      "pass|pass": 1,
      "unsure|unsure": 1
    },
    "disagreements": 1
  },
  "coverage": {
    "cells_a": 4,
    "cells_b": 4,
    "common_cells": 3,
    "only_in_a": [
      {
        "criterion": "c2",
        "item_id": "i2"
      }
    ],
    "only_in_b": [
      {
        "criterion": "c1",
        "item_id": "i3"
      }
    ]
  },
  "inputs": {
    "screener_a": "a.csv",
    "screener_b": "b.json"
  },
  "labels": [
    "pass",
    "fail",
    "unsure"
  ],
  "primitive": "rubric-screen-merge",
  "review_surface": [
    {
      "confidence_a": 0.8,
      "confidence_b": 0.6,
      "criterion": "c2",
      "item_id": "i1",
      "kind": "disagreement",
      "reason_a": "looks fine",
      "reason_b": "nope",
      "verdict_a": "pass",
      "verdict_b": "fail"
    },
    {
      "confidence_a": 0.3,
      "confidence_b": 0.2,
      "criterion": "c1",
      "item_id": "i2",
      "kind": "unsure",
      "reason_a": "cannot tell",
      "reason_b": "unclear",
      "verdict_a": "unsure",
      "verdict_b": "unsure"
    }
  ],
  "schema_version": 1,
  "verdict": {
    "clean_merge": false,
    "coverage_gap": true,
    "disagreement_count": 1,
    "needs_human_review": true,
    "review_count": 2,
    "unsure_agreement_count": 1
  }
}
EXP

cat > expected-surface.csv <<'EXP'
item_id,criterion,kind,verdict_a,verdict_b,confidence_a,confidence_b,reason_a,reason_b
i1,c2,disagreement,pass,fail,0.8,0.6,looks fine,nope
i2,c1,unsure,unsure,unsure,0.3,0.2,cannot tell,unclear
EXP

bash "$MERGE" --a a.csv --b b.json --out got.json --surface-csv got-surface.csv >/dev/null 2>&1 \
  || fail "(1) merge exited non-zero on a valid run"
diff -u expected.json got.json || fail "(1) report does not byte-match the expected fixture"
diff -u expected-surface.csv got-surface.csv || fail "(1) surface CSV does not byte-match"
ok

# ── (2) CLEAN MERGE: two identical passes ──
cp a.csv c.csv   # A vs an identical A over the SAME cells → perfect agreement, no gap
# Rebuild b as the exact same cells as a.csv so there is no coverage gap and no disagreement.
cat > b-clean.csv <<'CSV'
item_id,criterion,verdict,reason,confidence
i1,c1,pass,ok,0.9
i1,c2,pass,looks fine,0.8
i2,c1,pass,now sure,0.7
i2,c2,fail,,
CSV
cat > a-clean.csv <<'CSV'
item_id,criterion,verdict,reason,confidence
i1,c1,pass,ok,0.9
i1,c2,pass,looks fine,0.8
i2,c1,pass,now sure,0.7
i2,c2,fail,,
CSV
bash "$MERGE" --a a-clean.csv --b b-clean.csv --out clean.json >/dev/null 2>&1 \
  || fail "(2) merge exited non-zero"
python3 - clean.json <<'PY' || fail "(2) clean-merge verdict wrong"
import sys, json
v = json.load(open(sys.argv[1]))["verdict"]
assert v["clean_merge"] is True, v
assert v["needs_human_review"] is False, v
assert v["review_count"] == 0, v
assert v["coverage_gap"] is False, v
PY
ok

# ── (3) TSV loader + extension-less format sniff ──
printf 'item_id\tcriterion\tverdict\treason\tconfidence\ni1\tc1\tpass\tok\t0.9\n' > a.tsv
printf 'item_id\tcriterion\tverdict\treason\tconfidence\ni1\tc1\tfail\tno\t0.5\n' > b.tsv
bash "$MERGE" --a a.tsv --b b.tsv --out tsv.json >/dev/null 2>&1 \
  || fail "(3) TSV merge exited non-zero"
python3 - tsv.json <<'PY' || fail "(3) TSV verdict wrong"
import sys, json
r = json.load(open(sys.argv[1]))
assert r["agreement"]["disagreements"] == 1, r["agreement"]
PY
# extension-less files → sniff (JSON array vs delimited). Give JSON one, delimited the other.
cp b.json sniffme_json   # no extension, starts with '['
cp a.csv  sniffme_csv    # no extension, starts with 'item_id'
bash "$MERGE" --a sniffme_csv --b sniffme_json --out sniff.json >/dev/null 2>&1 \
  || fail "(3) sniffed formats failed to parse"
ok

# ── (4) custom --labels vocabulary ──
cat > inc-a.csv <<'CSV'
item_id,criterion,verdict,reason,confidence
i1,c1,include,keep,0.9
CSV
cat > inc-b.csv <<'CSV'
item_id,criterion,verdict,reason,confidence
i1,c1,exclude,drop,0.8
CSV
bash "$MERGE" --a inc-a.csv --b inc-b.csv --out inc.json --labels include,exclude >/dev/null 2>&1 \
  || fail "(4) custom-vocabulary merge exited non-zero"
python3 - inc.json <<'PY' || fail "(4) custom-vocabulary verdict wrong"
import sys, json
r = json.load(open(sys.argv[1]))
assert r["labels"] == ["include", "exclude"], r["labels"]
assert r["agreement"]["disagreements"] == 1, r["agreement"]
PY
# a verdict OUTSIDE the custom vocabulary (the default "pass") must now be rejected.
cat > bad-vocab.csv <<'CSV'
item_id,criterion,verdict,reason,confidence
i1,c1,pass,keep,0.9
CSV
if bash "$MERGE" --a bad-vocab.csv --b inc-b.csv --out x.json --labels include,exclude >/dev/null 2>&1; then
  fail "(4) merge should reject a verdict outside the custom vocabulary"
fi
ok

# ── (5) contract violations ──
mkfail() { # mkfail "<desc>" <fileA> — run merge (A=<file>, B=b.json) and require exit 1
  if bash "$MERGE" --a "$2" --b b.json --out x.json >/dev/null 2>&1; then
    fail "(5) merge should reject: $1"
  fi
}
# unknown verdict
printf 'item_id,criterion,verdict,reason,confidence\ni1,c1,maybe,x,0.5\n' > bad-verdict.csv
mkfail "unknown verdict" bad-verdict.csv
# confidence out of range
printf 'item_id,criterion,verdict,reason,confidence\ni1,c1,pass,x,1.5\n' > bad-conf.csv
mkfail "out-of-range confidence" bad-conf.csv
# non-numeric confidence
printf 'item_id,criterion,verdict,reason,confidence\ni1,c1,pass,x,high\n' > bad-conf2.csv
mkfail "non-numeric confidence" bad-conf2.csv
# duplicate cell
printf 'item_id,criterion,verdict,reason,confidence\ni1,c1,pass,x,0.5\ni1,c1,fail,y,0.6\n' > dup.csv
mkfail "duplicate cell" dup.csv
# missing required column (no confidence column)
printf 'item_id,criterion,verdict,reason\ni1,c1,pass,x\n' > missing-col.csv
mkfail "missing required column" missing-col.csv
# empty item_id
printf 'item_id,criterion,verdict,reason,confidence\n,c1,pass,x,0.5\n' > empty-id.csv
mkfail "empty item_id" empty-id.csv

# missing required flag
if bash "$MERGE" --a a.csv --out x.json >/dev/null 2>&1; then
  fail "(5) merge should reject a missing --b flag"
fi
# missing input file
if bash "$MERGE" --a nope.csv --b b.json --out x.json >/dev/null 2>&1; then
  fail "(5) merge should reject a missing input file"
fi
ok

echo "ALL PASS: test-rubric-screen-merge.sh ($pass assertions)"
