#!/usr/bin/env bash
# test-py-live-refix-complete.sh — regression for HERD-420: post-bounce COMPLETION tracking.
#
# THE BUG (live, PR #531): a review-BLOCK bounced the builder, refix_wake_result recorded woke=1
# (the agent's pane came back to "working"), the builder edited bin/herd, then went back to "done"
# WITHOUT ever committing or pushing. The PR head stayed on the blocked sha and the sha-keyed
# once-guard (refix_attempted) held silently forever — nothing re-evaluates a sha the ledger already
# recorded a bounce for, so the console read "fix-in-progress" indefinitely until a human noticed.
#
# WHAT THIS FILE PROVES, driving `python3 -m herd.live_runtime --dry-run` as an INDEPENDENT process
# per tick (fresh process = fresh runtime, matching production — the same shape as
# test-py-live-refix-budget.sh, which this file is the sibling of):
#  (a) A stub builder that wakes, edits, then goes silent (agent_status flips to "done", no new
#      sha) triggers refix_incomplete once REFIX_COMPLETE_MIN has elapsed, then re-bounces through
#      the SAME rail's round budget; a second silent round after budget exhaustion escalates.
#  (b) Before REFIX_COMPLETE_MIN elapses, the same silent signature holds BLOCK with no
#      refix_incomplete event — the window is genuinely respected, not a hair trigger.
#  (c) A builder that pushes a real fix (a NEW sha) never trips refix_incomplete, regardless of how
#      much time has passed.
#  (d) REFIX_COMPLETE_MIN=0 is a hard opt-out: the pre-HERD-420 once-guard-holds-forever behavior is
#      byte-identical (no refix_incomplete, no second bounce) no matter how long the sha sits.
#
# Run: bash tests/test-py-live-refix-complete.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
PASS=0; pass() { PASS=$((PASS + 1)); }

T0=2000000000   # an arbitrary fixed epoch — HERD_FAKE_NOW makes every tick's clock explicit

# ── helpers ───────────────────────────────────────────────────────────────────
run_tick() {
  # run_tick <fixture> <journal> <fake-now>
  local _fixture="$1" _journal="$2" _now="$3"
  WORKTREES_DIR="$T/state" \
    LIVE_DRYRUN_JOURNAL="$_journal" \
    HERD_FAKE_NOW="$_now" \
    PYTHONPATH="$REPO/pysrc" \
    python3 -m herd.live_runtime --dry-run --fixture "$_fixture" 2>/dev/null
}

count_event() {
  local _jf="$1" _event="$2"
  python3 - "$_jf" "$_event" <<'PY'
import json, sys
jf, ev = sys.argv[1], sys.argv[2]
n = 0
try:
    for line in open(jf):
        if json.loads(line).get("event") == ev:
            n += 1
except FileNotFoundError:
    pass
print(n)
PY
}

field_of_last() {
  # field_of_last <journal> <event> <field>
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
jf, ev, field = sys.argv[1], sys.argv[2], sys.argv[3]
last = None
try:
    for line in open(jf):
        d = json.loads(line)
        if d.get("event") == ev:
            last = d.get(field)
except FileNotFoundError:
    pass
print("" if last is None else last)
PY
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

# ── (a) wakes, edits, goes silent → refix_incomplete → re-bounce → escalate ───
rm -rf "$T/state"; mkdir -p "$T/state"

cat > "$T/a1.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"2","REFIX_COMPLETE_MIN":"10"},
 "candidates":[{"pr":531,"sha":"sha-531","slug":"feat-531","health":"CODEERROR","review":"PASS",
                "agent_status":"idle"}]}
JSON
out_a1="$(run_tick "$T/a1.json" "$T/a1.jsonl" "$T0")"
outcome_is "$out_a1" 531 BLOCK || fail "(a) tick1: expected BLOCK, got: ${out_a1}"
[ "$(field_of_last "$T/a1.jsonl" refix_bounce round)" = "1" ] \
  || fail "(a) tick1: expected round=1 bounce"
[ "$(count_event "$T/a1.jsonl" refix_incomplete)" = "0" ] \
  || fail "(a) tick1: refix_incomplete must not fire on the very first bounce"

# +10 minutes: SAME sha, agent now reads "done" (woke, edited, never pushed) — INCOMPLETE.
cat > "$T/a2.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"2","REFIX_COMPLETE_MIN":"10"},
 "candidates":[{"pr":531,"sha":"sha-531","slug":"feat-531","health":"CODEERROR","review":"PASS",
                "agent_status":"done"}]}
JSON
out_a2="$(run_tick "$T/a2.json" "$T/a2.jsonl" "$((T0 + 10 * 60))")"
outcome_is "$out_a2" 531 BLOCK || fail "(a) tick2: expected BLOCK (re-bounced), got: ${out_a2}"
[ "$(count_event "$T/a2.jsonl" refix_incomplete)" = "1" ] \
  || fail "(a) tick2: expected exactly one refix_incomplete"
[ "$(field_of_last "$T/a2.jsonl" refix_incomplete round)" = "1" ] \
  || fail "(a) tick2: refix_incomplete must name the INCOMPLETE round (1)"
[ "$(field_of_last "$T/a2.jsonl" refix_incomplete dirty)" = "no" ] \
  || fail "(a) tick2: dirty defaults to 'no' when the fixture doesn't set it"
[ "$(field_of_last "$T/a2.jsonl" refix_bounce round)" = "2" ] \
  || fail "(a) tick2: expected a fresh round=2 bounce spending the SAME rail budget"
[ "$(field_of_last "$T/a2.jsonl" refix_wake_result woke)" = "1" ] \
  || fail "(a) tick2: the completion re-bounce must still verify + record the wake"

# +another 10 minutes: still the SAME sha, still "done" — budget (cap=2) is now exhausted.
out_a3="$(run_tick "$T/a2.json" "$T/a3.jsonl" "$((T0 + 20 * 60))")"
outcome_is "$out_a3" 531 ESCALATE || fail "(a) tick3: expected ESCALATE, got: ${out_a3}"
[ "$(count_event "$T/a3.jsonl" refix_incomplete)" = "1" ] \
  || fail "(a) tick3: expected refix_incomplete for the second silent round"
[ "$(count_event "$T/a3.jsonl" refix_bounce)" = "0" ] \
  || fail "(a) tick3: budget exhausted — must NOT bounce a third time"
[ "$(count_event "$T/a3.jsonl" health_refix_escalated)" = "1" ] \
  || fail "(a) tick3: expected the standard health_refix_escalated needs-you event"
pass

# ── (b) window respects REFIX_COMPLETE_MIN — 9 minutes is not yet 10 ─────────
rm -rf "$T/state"; mkdir -p "$T/state"

cat > "$T/b1.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"3","REFIX_COMPLETE_MIN":"10"},
 "candidates":[{"pr":532,"sha":"sha-532","slug":"feat-532","health":"CODEERROR","review":"PASS",
                "agent_status":"idle"}]}
JSON
run_tick "$T/b1.json" "$T/b1.jsonl" "$T0" >/dev/null || fail "(b) tick1 exited nonzero"

cat > "$T/b2.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"3","REFIX_COMPLETE_MIN":"10"},
 "candidates":[{"pr":532,"sha":"sha-532","slug":"feat-532","health":"CODEERROR","review":"PASS",
                "agent_status":"done"}]}
JSON
out_b2="$(run_tick "$T/b2.json" "$T/b2.jsonl" "$((T0 + 9 * 60))")"
outcome_is "$out_b2" 532 BLOCK || fail "(b) tick2 (9min): expected silent BLOCK, got: ${out_b2}"
[ "$(count_event "$T/b2.jsonl" refix_incomplete)" = "0" ] \
  || fail "(b) tick2 (9min): window not yet elapsed — refix_incomplete must not fire"
[ "$(count_event "$T/b2.jsonl" refix_bounce)" = "0" ] \
  || fail "(b) tick2 (9min): must not re-bounce before the window elapses"
pass

# ── (c) a real push (new sha) never trips the completion leg ─────────────────
rm -rf "$T/state"; mkdir -p "$T/state"

cat > "$T/c1.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"3","REFIX_COMPLETE_MIN":"10"},
 "candidates":[{"pr":533,"sha":"sha-a","slug":"feat-533","health":"CODEERROR","review":"PASS",
                "agent_status":"idle"}]}
JSON
run_tick "$T/c1.json" "$T/c1.jsonl" "$T0" >/dev/null || fail "(c) tick1 exited nonzero"

# a real push: a NEW sha, and the fix actually landed (health now CLEAN) — long after the window.
cat > "$T/c2.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"3","REFIX_COMPLETE_MIN":"10"},
 "candidates":[{"pr":533,"sha":"sha-b","slug":"feat-533","health":"CLEAN","review":"PASS"}]}
JSON
out_c2="$(run_tick "$T/c2.json" "$T/c2.jsonl" "$((T0 + 30 * 60))")"
outcome_is "$out_c2" 533 MERGE || fail "(c) tick2: expected MERGE after a real push, got: ${out_c2}"
[ "$(count_event "$T/c2.jsonl" refix_incomplete)" = "0" ] \
  || fail "(c) tick2: a genuine new-sha push must never trigger refix_incomplete"
pass

# ── (d) REFIX_COMPLETE_MIN=0 is a hard opt-out — byte-identical to pre-HERD-420 ──
rm -rf "$T/state"; mkdir -p "$T/state"

cat > "$T/d1.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"3","REFIX_COMPLETE_MIN":"0"},
 "candidates":[{"pr":534,"sha":"sha-534","slug":"feat-534","health":"CODEERROR","review":"PASS",
                "agent_status":"idle"}]}
JSON
run_tick "$T/d1.json" "$T/d1.jsonl" "$T0" >/dev/null || fail "(d) tick1 exited nonzero"

cat > "$T/d2.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto","REFIX_MAX_ROUNDS":"3","REFIX_COMPLETE_MIN":"0"},
 "candidates":[{"pr":534,"sha":"sha-534","slug":"feat-534","health":"CODEERROR","review":"PASS",
                "agent_status":"done"}]}
JSON
out_d2="$(run_tick "$T/d2.json" "$T/d2.jsonl" "$((T0 + 24 * 60 * 60))")"   # a full day later
outcome_is "$out_d2" 534 BLOCK || fail "(d) tick2: expected silent BLOCK forever, got: ${out_d2}"
[ "$(count_event "$T/d2.jsonl" refix_incomplete)" = "0" ] \
  || fail "(d) tick2: REFIX_COMPLETE_MIN=0 must never fire refix_incomplete"
[ "$(count_event "$T/d2.jsonl" refix_bounce)" = "0" ] \
  || fail "(d) tick2: REFIX_COMPLETE_MIN=0 must never re-bounce"
pass

echo "ALL PASS ($PASS)"
exit 0
