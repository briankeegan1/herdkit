#!/usr/bin/env bash
# test-py-live-refix-budget.sh — regression for HERD-358: durable refix budget under ENGINE_IMPL=python.
#
# THE BUG: the python engine re-runs as a FRESH PROCESS every ~8s tick.  The old in-process
# `_refix_rounds` dict was rebuilt empty each tick → round was always 1 → REFIX_MAX_ROUNDS never
# enforced → a red PR bounced at round=1 forever and never escalated to needs-you.
#
# THE SECOND DEFECT (introduced during the fix attempt): _refix_check_and_record appended a bounce
# row on EVERY tick without consulting D.refix_attempted (the per-(pr,sha,kind) once-guard).
# Because the live tick re-walks every candidate every ~8s using the cached verdict, an unchanged
# sha triggered a new ledger row on each tick → whole per-rail budget burned in ~24s while the
# agent was still working.
#
# WHAT THIS FILE PROVES:
#  (a) Round advances 1→2→3 when a NEW SHA is pushed after each fix (the intended enforcement path).
#  (b) The SAME sha walked across many fresh runtimes (no push between ticks) bounces EXACTLY ONCE
#      (the per-(pr,sha,kind) once-guard preserved across fresh processes via the durable ledger).
#  (c) Rail counter resets when the rail goes GREEN, and per-rail isolation holds.
#  (d) The 3× total ceiling escalates a cross-rail thrasher to ESCALATE.
#
# Run: bash tests/test-py-live-refix-budget.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
PASS=0; pass() { PASS=$((PASS + 1)); }

# ── helpers ───────────────────────────────────────────────────────────────────
run_tick() {
  # Run one dry-run tick via an independent python3 invocation (fresh process = fresh runtime,
  # matching production).  WORKTREES_DIR points at the hermetic state dir.
  local _fixture="$1" _journal="$2"
  WORKTREES_DIR="$T/state" \
    LIVE_DRYRUN_JOURNAL="$_journal" \
    PYTHONPATH="$REPO/pysrc" \
    python3 -m herd.live_runtime --dry-run --fixture "$_fixture" 2>/dev/null
}

last_round() {
  local _jf="$1" _rule="$2"
  python3 - "$_jf" "$_rule" <<'PY'
import json, sys
jf, rule = sys.argv[1], sys.argv[2]
last = None
try:
    for line in open(jf):
        ev = json.loads(line)
        if ev.get("event") == "refix_bounce" and ev.get("rule") == rule:
            last = ev.get("round")
except FileNotFoundError:
    pass
print("" if last is None else last)
PY
}

count_bounces() {
  local _jf="$1" _rule="$2"
  python3 - "$_jf" "$_rule" <<'PY'
import json, sys
jf, rule = sys.argv[1], sys.argv[2]
n = 0
try:
    for line in open(jf):
        ev = json.loads(line)
        if ev.get("event") == "refix_bounce" and ev.get("rule") == rule:
            n += 1
except FileNotFoundError:
    pass
print(n)
PY
}

has_event() {
  python3 -c "
import json, sys
for line in open(sys.argv[1]):
    if json.loads(line).get('event') == sys.argv[2]:
        sys.exit(0)
sys.exit(1)
" "$1" "$2" 2>/dev/null
}

outcome_is() {
  # outcome_is <json-stdout> <pr-number> <expected>
  printf '%s' "$1" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
got = str(d.get('outcomes', {}).get(str(sys.argv[1]), ''))
sys.exit(0 if got == sys.argv[2] else 1)
" "$2" "$3" 2>/dev/null
}

# ── (a) Round advances 1→2→3 on each NEW SHA push ─────────────────────────────
# Each sha represents one new commit after the previous fix attempt.  The
# once-guard means each sha bounces exactly once; the rail counter advances
# per-sha because each new sha is a new once-guard key.
mkdir -p "$T/state"

for i in 1 2 3; do
  cat > "$T/fix-sha${i}.json" <<JSON
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"3"},
 "candidates":[{"pr":1,"sha":"sha-r${i}","slug":"feat-red","health":"CODEERROR","review":"PASS"}]}
JSON
done

for expected_round in 1 2 3; do
  jf="$T/tick-round${expected_round}.jsonl"
  run_tick "$T/fix-sha${expected_round}.json" "$jf" >/dev/null \
    || fail "(a) tick for sha sha-r${expected_round} exited nonzero"
  got="$(last_round "$jf" healthcheck)"
  [ "$got" = "$expected_round" ] || \
    fail "(a) sha sha-r${expected_round}: expected round=${expected_round}, got '${got}'"
done
pass

# ── (b) Same sha across many fresh runtimes bounces EXACTLY ONCE (once-guard) ─
# The cached verdict returns CODEERROR on every tick for the same sha.  The
# durable ledger must stop a second bounce row from being written.
cat > "$T/fix-same-sha.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"5"},
 "candidates":[{"pr":2,"sha":"same-sha","slug":"feat-og","health":"CODEERROR","review":"PASS"}]}
JSON

total_bounces=0
for i in 1 2 3 4 5; do
  jf="$T/og-tick${i}.jsonl"
  run_tick "$T/fix-same-sha.json" "$jf" >/dev/null \
    || fail "(b) once-guard tick ${i} exited nonzero"
  n="$(count_bounces "$jf" healthcheck)"
  total_bounces=$(( total_bounces + n ))
done
[ "$total_bounces" -eq 1 ] || \
  fail "(b) same sha across 5 ticks: expected exactly 1 bounce, got ${total_bounces}"
pass

# ── (c) Rail reset: health goes GREEN → budget restored, next CODEERROR is round=1 ──
# PR 1 was bounced at round=1 (sha sha-r1) and round=2 (sha sha-r2) in test (a).
# A CLEAN verdict must reset the health rail → next CODEERROR on a new sha is round=1 again.
cat > "$T/fix-clean.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"3"},
 "candidates":[{"pr":1,"sha":"sha-clean","slug":"feat-red","health":"CLEAN","review":"PASS"}]}
JSON
jf_clean="$T/tick-clean.jsonl"
run_tick "$T/fix-clean.json" "$jf_clean" >/dev/null || fail "(c) CLEAN tick exited nonzero"
has_event "$jf_clean" refix_rail_reset || fail "(c) no refix_rail_reset event after health CLEAN"

# Now a new sha after the CLEAN: round should be 1 again (rail was reset)
cat > "$T/fix-after-reset.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"3"},
 "candidates":[{"pr":1,"sha":"sha-post-reset","slug":"feat-red","health":"CODEERROR","review":"PASS"}]}
JSON
jf_post="$T/tick-post-reset.jsonl"
run_tick "$T/fix-after-reset.json" "$jf_post" >/dev/null || fail "(c) post-reset tick exited nonzero"
got_post="$(last_round "$jf_post" healthcheck)"
[ "$got_post" = "1" ] || fail "(c) expected round=1 after rail reset, got '${got_post}'"
pass

# ── (d) Budget exhaustion → ESCALATE (rail cap + total ceiling) ───────────────
# Rail cap: REFIX_MAX_ROUNDS=1 → rail_cap=1.
# sha-y1: health CODEERROR → bounce (rail=1=cap).
# sha-y2: health CODEERROR → rail cap already spent → ESCALATE (no new bounce).
rm -rf "$T/state" && mkdir -p "$T/state"

cat > "$T/cap-y1.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"1"},
 "candidates":[{"pr":10,"sha":"sha-y1","slug":"feat-cap","health":"CODEERROR","review":"PASS"}]}
JSON
cat > "$T/cap-y2.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"1"},
 "candidates":[{"pr":10,"sha":"sha-y2","slug":"feat-cap","health":"CODEERROR","review":"PASS"}]}
JSON

# First push: bounce (round=1, rail=1, cap=1)
out_y1="$(run_tick "$T/cap-y1.json" "$T/d-y1.jsonl" 2>/dev/null)"
outcome_is "$out_y1" 10 BLOCK || fail "(d) sha-y1: expected BLOCK for first bounce, got: ${out_y1}"

# Second push: rail cap spent → ESCALATE (needs-you)
out_y2="$(run_tick "$T/cap-y2.json" "$T/d-y2.jsonl" 2>/dev/null)"
outcome_is "$out_y2" 10 ESCALATE || \
  fail "(d) sha-y2: expected ESCALATE after rail cap exhausted, got: ${out_y2}"
has_event "$T/d-y2.jsonl" health_refix_escalated || \
  fail "(d) no health_refix_escalated event after rail cap exhausted"

# Total ceiling: write ledger rows for a 3rd rail kind ("stale") directly so the total cap (3×1=3)
# is reached without requiring the live tick to dispatch a stale bounce.  Then a health CODEERROR
# must ESCALATE via the total ceiling check (even though health rail was reset).
# Reset the health rail via a CLEAN tick first.
cat > "$T/cap-clean.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"1"},
 "candidates":[{"pr":10,"sha":"sha-y2","slug":"feat-cap","health":"CLEAN","review":"PASS"}]}
JSON
run_tick "$T/cap-clean.json" "$T/d-yc.jsonl" >/dev/null || fail "(d) clean-reset tick failed"

# Inject a stale bounce directly into the ledger (simulating a stale-base bounce the bash engine
# would write; the live tick never writes stale rows so we must plant this to exercise the total cap).
printf '0 10 sha-y2 feat-cap stale\n' >> "$T/state/.agent-watch-refixed"

# Now try a health bounce on a new sha: health rail=0 (was reset), but total=3 (y1 + stale + ?)
# Wait: after the CLEAN reset, health_rail=0. total = 2 (y1-health + y2-stale).
# We need total to reach 3. Add one more stale row.
printf '0 10 sha-y3 feat-cap stale\n' >> "$T/state/.agent-watch-refixed"
# Now total=3 (y1-health + 2×stale). total_cap=3×1=3. Next health bounce → total ceiling → ESCALATE.
cat > "$T/cap-y4.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"1"},
 "candidates":[{"pr":10,"sha":"sha-y4","slug":"feat-cap","health":"CODEERROR","review":"PASS"}]}
JSON
out_y4="$(run_tick "$T/cap-y4.json" "$T/d-y4.jsonl" 2>/dev/null)"
outcome_is "$out_y4" 10 ESCALATE || \
  fail "(d) total-ceiling: expected ESCALATE, got: ${out_y4}"
pass

echo "ALL PASS ($PASS)"
exit 0
