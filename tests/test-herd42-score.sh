#!/usr/bin/env bash
# test-herd42-score.sh — hermetic tests for the HERD-42 A/B scorer (scripts/herd/experiment/
# herd42-score.sh). The scorer is the experiment's deterministic judge, so this asserts KNOWN INPUTS
# → an EXACT expected scorecard.json (byte-for-byte), plus the falsification / abort verdict paths.
# Covers:
#   (1) EXACT scorecard from fixture journal + ledger + defects (throughput tie, herdkit wins the
#       rest, thesis confirmed) — full byte-for-byte diff, proving the scorer is deterministic.
#   (2) herdkit-arm derivation from the journal: merges deduped by pr, cost usd summed = `herd cost`,
#       human interventions = human-verify holds + failed-auto-resume manual wakes, limit_detected
#       ⇒ spanned_limit_window.
#   (3) FALSIFICATION: when the well-run bare arm matches-or-beats herdkit on every metric across a
#       crossed limit window, verdict.falsified == true (herdkit loses, as committed in advance).
#   (4) ABORT: no limit window exercised, or the acceptance suite graded 0 merged changes.
#   (5) input validation: missing file / missing flag / malformed ledger fail with exit 1.
#
# Fully hermetic: writes only under a mktemp dir, runs the scorer with RELATIVE input paths (so the
# echoed `inputs` block is stable), and touches no engine state, worktree, pane, or live journal.
# Run:  bash tests/test-herd42-score.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCORER="$REPO/scripts/herd/experiment/herd42-score.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$SCORER" ] || fail "scorer not found at $SCORER"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
bash -n "$SCORER" || fail "scorer has a syntax error"

# ── (1)+(2) EXACT scorecard from a known fixture ──
# herdkit journal: two merges (pr1 twice-journaled → deduped; pr2), builder+review cost, one
# human-verify hold, one FAILED auto-resume (woke=0 → a manual wake), and a limit_detected park.
cd "$T" || fail "cannot cd to temp dir"
cat > herd.jsonl <<'JNL'
{"ts":"2026-07-10T01:00:00Z","event":"limit_detected","slug":"a","reset_at":"x"}
{"ts":"2026-07-10T02:00:00Z","event":"merge","pr":1,"slug":"a"}
{"ts":"2026-07-10T02:00:00Z","event":"merge","pr":1,"slug":"a"}
{"ts":"2026-07-10T02:00:01Z","event":"cost","component":"builder","pr":1,"usd":5.0}
{"ts":"2026-07-10T02:00:02Z","event":"cost","component":"review","pr":1,"usd":1.0}
{"ts":"2026-07-10T03:00:00Z","event":"merge","pr":2,"slug":"b"}
{"ts":"2026-07-10T03:00:01Z","event":"cost","component":"builder","pr":2,"usd":6.0}
{"ts":"2026-07-10T03:10:00Z","event":"hold_applied","pr":3,"kind":"human-verify"}
{"ts":"2026-07-10T04:00:00Z","event":"limit_resume_result","slug":"b","woke":0,"escalated":"true"}
{"ts":"2026-07-10T04:00:00Z","event":"review_dispatched","pr":9,"sha":"deadbeef"}
JNL
echo '{"suite_total":2,"escaped":0}' > herd-def.json
echo '{"merged_tasks":2,"usd_total":18.0,"human_interventions":9,"limit_events":1}' > bare.json
echo '{"suite_total":2,"escaped":1}' > bare-def.json

cat > expected.json <<'EXP'
{
  "arms": {
    "bare": {
      "acceptance_suite_total": 2,
      "defect_escape_rate": 0.5,
      "defects_escaped": 1,
      "human_interventions": 9,
      "merged_tasks": 2,
      "spanned_limit_window": true,
      "usd_per_merged_change": 9.0,
      "usd_total": 18.0
    },
    "herdkit": {
      "acceptance_suite_total": 2,
      "defect_escape_rate": 0.0,
      "defects_escaped": 0,
      "human_interventions": 2,
      "merged_tasks": 2,
      "spanned_limit_window": true,
      "usd_per_merged_change": 6.0,
      "usd_total": 12.0
    }
  },
  "comparison": {
    "cost_winner": "herdkit",
    "defect_winner": "herdkit",
    "intervention_winner": "herdkit",
    "throughput_winner": "tie"
  },
  "experiment": "herd42-ab",
  "inputs": {
    "bare_defects": "bare-def.json",
    "bare_ledger": "bare.json",
    "herd_defects": "herd-def.json",
    "herd_journal": "herd.jsonl"
  },
  "schema_version": 1,
  "verdict": {
    "abort": false,
    "abort_reasons": [],
    "both_spanned_limit_window": true,
    "falsified": false,
    "herdkit_thesis_confirmed": true
  }
}
EXP

bash "$SCORER" --herd-journal herd.jsonl --herd-defects herd-def.json \
  --bare-ledger bare.json --bare-defects bare-def.json --out got.json >/dev/null \
  || fail "(1) scorer exited non-zero on a valid run"
if ! diff -u expected.json got.json; then
  fail "(1) scorecard does not byte-match the expected fixture (see diff above)"
fi
ok

# ── (3) FALSIFICATION: bare arm matches-or-beats herdkit on every metric across a crossed window ──
# Same herdkit fixture (2 merged, $12, 2 interventions, 0 escaped). Bare: MORE merged, cheaper,
# fewer interventions, no worse defect rate, limit crossed → herdkit loses.
echo '{"merged_tasks":3,"usd_total":15.0,"human_interventions":1,"limit_events":2}' > bare-fals.json
echo '{"suite_total":3,"escaped":0}' > bare-fals-def.json
bash "$SCORER" --herd-journal herd.jsonl --herd-defects herd-def.json \
  --bare-ledger bare-fals.json --bare-defects bare-fals-def.json --out got-fals.json >/dev/null \
  || fail "(3) scorer exited non-zero"
python3 - got-fals.json <<'PY' || fail "(3) falsification verdict wrong"
import sys, json
v = json.load(open(sys.argv[1]))["verdict"]
assert v["falsified"] is True, v
assert v["herdkit_thesis_confirmed"] is False, v
assert v["abort"] is False, v
assert v["both_spanned_limit_window"] is True, v
PY
ok

# ── (4a) ABORT: no limit window exercised by either arm ──
cat > herd-nolimit.jsonl <<'JNL'
{"ts":"2026-07-10T02:00:00Z","event":"merge","pr":1,"slug":"a"}
{"ts":"2026-07-10T02:00:01Z","event":"cost","component":"builder","pr":1,"usd":5.0}
JNL
echo '{"merged_tasks":1,"usd_total":6.0,"human_interventions":0,"limit_events":0}' > bare-nolimit.json
bash "$SCORER" --herd-journal herd-nolimit.jsonl --herd-defects herd-def.json \
  --bare-ledger bare-nolimit.json --bare-defects bare-def.json --out got-abort.json >/dev/null \
  || fail "(4a) scorer exited non-zero"
python3 - got-abort.json <<'PY' || fail "(4a) abort verdict wrong"
import sys, json
v = json.load(open(sys.argv[1]))["verdict"]
assert v["abort"] is True, v
assert v["falsified"] is False, v
assert any("usage-limit window" in r for r in v["abort_reasons"]), v
PY
ok

# ── (4b) ABORT: acceptance suite graded 0 merged changes (no defect oracle) ──
echo '{"suite_total":0,"escaped":0}' > herd-def-empty.json
bash "$SCORER" --herd-journal herd.jsonl --herd-defects herd-def-empty.json \
  --bare-ledger bare.json --bare-defects bare-def.json --out got-abort2.json >/dev/null \
  || fail "(4b) scorer exited non-zero"
python3 - got-abort2.json <<'PY' || fail "(4b) abort verdict wrong"
import sys, json
v = json.load(open(sys.argv[1]))["verdict"]
assert v["abort"] is True, v
assert any("acceptance suite" in r for r in v["abort_reasons"]), v
PY
ok

# ── (5) input validation ──
if bash "$SCORER" --herd-journal herd.jsonl --herd-defects herd-def.json \
     --bare-ledger bare.json --out got.json >/dev/null 2>&1; then
  fail "(5) scorer should reject a missing required flag"
fi
if bash "$SCORER" --herd-journal nope.jsonl --herd-defects herd-def.json \
     --bare-ledger bare.json --bare-defects bare-def.json --out got.json >/dev/null 2>&1; then
  fail "(5) scorer should reject a missing input file"
fi
echo '{"merged_tasks":"two"}' > bad-ledger.json
if bash "$SCORER" --herd-journal herd.jsonl --herd-defects herd-def.json \
     --bare-ledger bad-ledger.json --bare-defects bare-def.json --out got.json >/dev/null 2>&1; then
  fail "(5) scorer should reject a malformed ledger (non-numeric field)"
fi
ok

echo "ALL PASS: test-herd42-score.sh ($pass assertions)"
