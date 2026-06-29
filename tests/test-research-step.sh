#!/usr/bin/env bash
# test-research-step.sh — hermetic test of research-step.sh queue/report mechanics against a TEMP
# trees dir. No herdr, no agents, no $HOME mutation: exercises enqueue → next → report → get →
# finish end to end. Run:  bash tests/test-research-step.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STEP="$HERE/../scripts/herd/research-step.sh"
GET="$HERE/../scripts/herd/research-get.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export RESEARCH_TREES="$T"
export RESEARCH_QUEUE="$T/research-queue"
export RESEARCH_REPORTS="$T/research-reports"
export RESEARCH_INBOX="$T/.research-reports"
export RESEARCH_POLL=0   # don't block when the queue is empty
export RESEARCH_TAB=""   # finish must not call herdr

fail(){ echo "FAIL: $1" >&2; exit 1; }

# 1. Enqueue a fake request with a known id (mirrors research.sh's "<id>.req" naming).
mkdir -p "$RESEARCH_QUEUE"
ID="1700000000-99-12345"
QUESTION="Where is the watcher state machine?"
printf '%s\n' "$QUESTION" > "$RESEARCH_QUEUE/$ID.req"

# 2. next: should CLAIM it, echo the id and the question; queue file becomes .mine.
out="$(bash "$STEP" next)"
echo "$out" | grep -q "^CLAIMED " || fail "next did not print CLAIMED ($out)"
echo "$out" | grep -qx "$ID" || fail "next did not echo the REQ_ID ($out)"
echo "$out" | grep -qF "$QUESTION" || fail "next did not echo the question ($out)"
claimed="$(echo "$out" | sed -n 's/^CLAIMED //p')"
[ -f "$claimed" ] || fail "claimed file missing: $claimed"
[ -f "$RESEARCH_QUEUE/$ID.req" ] && fail "original .req still present after claim"
ls "$RESEARCH_QUEUE"/*.mine >/dev/null 2>&1 || fail "no .mine claim file present"

# 3. next again: nothing left, POLL=0 -> EMPTY.
[ "$(bash "$STEP" next)" = "EMPTY" ] || fail "second next not EMPTY"

# 4. report: file fake findings -> report appears, inbox line added, claim + temp gone.
findings="$(mktemp)"; printf '# Findings\n\nAnswer: scripts/herd/agent-watch.sh:1\n' > "$findings"
rep="$(bash "$STEP" report "$claimed" "$findings")"
echo "$rep" | grep -q "^DONE $ID" || fail "report did not print DONE ($rep)"
[ -f "$RESEARCH_REPORTS/$ID.md" ] || fail "report file not created"
grep -q "agent-watch.sh:1" "$RESEARCH_REPORTS/$ID.md" || fail "report content wrong"
[ -f "$findings" ] && fail "findings temp file should have been moved, not copied"
[ -f "$claimed" ] && fail "claim file should be removed after report"
grep -qF "$ID" "$RESEARCH_INBOX" || fail "inbox missing id line"
grep -qF "$QUESTION" "$RESEARCH_INBOX" || fail "inbox missing question"

# 5. research-get.sh: known id prints the report, unknown id prints PENDING.
bash "$GET" "$ID" | grep -q "agent-watch.sh:1" || fail "research-get did not print report"
[ "$(bash "$GET" nonexistent-id)" = "PENDING" ] || fail "research-get unknown id not PENDING"

# 6. finish: empty queue -> STOP (no RESEARCH_TAB so no herdr call); pending req -> MORE.
[ "$(bash "$STEP" finish)" = "STOP" ] || fail "finish on empty queue not STOP"
printf 'q2\n' > "$RESEARCH_QUEUE/1700000001-99-22222.req"
[ "$(bash "$STEP" finish)" = "MORE" ] || fail "finish with pending req not MORE"

echo "ALL PASS"
