#!/usr/bin/env bash
# test-stats.sh — hermetic tests for the shepherd's digest card (`herd stats`, HERD-146). Covers:
#   (1) default (all-time) aggregate over a fixture journal: PRs merged, review verdicts (by value
#       AND provenance), refix bounces, limit park/resume, reaps, and recorded cost
#   (2) --pr N scopes the card to a single PR
#   (3) --since <date> bounds by the ISO ts (lexical compare); a future date excludes everything
#   (4) --today restricts to today's UTC entries (computed the same way the command does)
#   (5) fail-soft: an empty/missing journal prints an all-zeros card and exits 0 (never an error)
#   (6) aggregation spans a rotated archive (journal-*.jsonl) as well as the live journal
#
# Fully hermetic: writes only under a mktemp dir with a fixture .herd/config + journal, and NEVER
# touches the live watcher/panes/real HOME.
# Run:  bash tests/test-stats.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD_BIN="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { printf 'FAIL: '; printf "$@" >&2; echo >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$HERD_BIN" ] || fail "herd not found at $HERD_BIN"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── fixture project + journal ──
PROJ="$T/proj"; TREES="$T/trees"
mkdir -p "$PROJ/.herd" "$TREES/.herd"
cat > "$PROJ/.herd/config" <<CFG
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$TREES"
WORKSPACE_NAME="stest"
CFG

# 2 merges, 3 verdicts (2 APPROVE reviewer + 1 BLOCK gate_default), 1 refix bounce, 1 limit park +
# 1 resume, 2 reaps, and cost $110 (builder) + $50 (review) = $160 across 2 events.  All dated 07-02.
cat > "$TREES/.herd/journal.jsonl" <<'JNL'
{"ts":"2026-07-02T10:00:00Z","event":"merge","pr":42,"slug":"s1","sha":"abc","method":"--merge","reason":"gates_passed"}
{"ts":"2026-07-02T10:00:01Z","event":"merge","pr":43,"slug":"s2","sha":"def","method":"--merge","reason":"gates_passed"}
{"ts":"2026-07-02T10:00:02Z","event":"verdict_recorded","pr":42,"sha":"abc","value":"APPROVE","source":"reviewer"}
{"ts":"2026-07-02T10:00:03Z","event":"verdict_recorded","pr":42,"sha":"abc","value":"APPROVE","source":"reviewer"}
{"ts":"2026-07-02T10:00:04Z","event":"verdict_recorded","pr":43,"sha":"def","value":"BLOCK","source":"gate_default"}
{"ts":"2026-07-02T10:00:05Z","event":"refix_bounce","pr":43,"sha":"def","slug":"s2","round":"1"}
{"ts":"2026-07-02T10:00:06Z","event":"limit_detected","slug":"s2","reset_at":"x","resume_at":"y"}
{"ts":"2026-07-02T10:00:07Z","event":"limit_resume_result","slug":"s2","woke":1,"escalated":false}
{"ts":"2026-07-02T10:00:08Z","event":"reap","pr":99,"slug":"s9","sha":"zzz","reason":"dead"}
{"ts":"2026-07-02T10:00:09Z","event":"reap","pr":98,"slug":"s8","sha":"yyy","reason":"conflict"}
{"ts":"2026-07-02T10:00:10Z","event":"cost","component":"builder","pr":42,"slug":"s1","model":"claude-opus-4-8","in":100,"out":200,"cache_read":0,"cache_write":0,"usd":"110.000000","msgs":2}
{"ts":"2026-07-02T10:00:11Z","event":"cost","component":"review","pr":42,"slug":"s1","model":"claude-opus-4-8","in":0,"out":50,"cache_read":0,"cache_write":0,"usd":"50.000000","msgs":1}
JNL

run() { (cd "$PROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" stats "$@" 2>&1); }

# ── (1) default all-time aggregate ──
out="$(run)"
printf '%s\n' "$out" | grep -qE 'all time'                     || fail "default: scope should say 'all time'\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Merged PRs +2'               || fail "default: 2 merges expected\n%s" "$out"
# a 🐑 per merge (exactly 2).
sheep="$(printf '%s\n' "$out" | grep 'Merged PRs' | grep -o '🐑' | wc -l | tr -d ' ')"
[ "$sheep" = "2" ]                                             || fail "default: expected 2 sheep, got %s\n%s" "$sheep" "$out"
printf '%s\n' "$out" | grep -qE 'Review verdicts +3'          || fail "default: 3 verdicts expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'APPROVE 2'                   || fail "default: APPROVE 2 expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'BLOCK 1'                     || fail "default: BLOCK 1 expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'reviewer 2'                  || fail "default: provenance reviewer 2 expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'gate_default 1'              || fail "default: provenance gate_default 1 expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Refix bounces +1'           || fail "default: 1 refix bounce expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Limit park/resume +1 / 1'   || fail "default: limit 1/1 expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Reaps +2'                   || fail "default: 2 reaps expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Cost recorded +\$160\.0000 \(2 events\)' || fail "default: cost \$160.0000/2 expected\n%s" "$out"
ok

# ── (2) --pr scopes to one PR ──
out="$(run --pr 42)"
printf '%s\n' "$out" | grep -qE 'PR #42'                     || fail "--pr: scope should name PR #42\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Merged PRs +1'             || fail "--pr 42: 1 merge expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Review verdicts +2'       || fail "--pr 42: 2 verdicts expected (both APPROVE)\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Refix bounces +0'        || fail "--pr 42: refix bounce belongs to PR 43, expect 0\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Cost recorded +\$160\.0000' || fail "--pr 42: cost \$160.0000 expected\n%s" "$out"
ok
# PR 43 sees the BLOCK + the refix bounce, but no cost (no cost event for 43).
out="$(run --pr 43)"
printf '%s\n' "$out" | grep -qE 'BLOCK 1'                  || fail "--pr 43: BLOCK 1 expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Refix bounces +1'        || fail "--pr 43: 1 refix bounce expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Cost recorded +\$0\.0000 \(0 events\)' || fail "--pr 43: no cost expected\n%s" "$out"
ok

# ── (3) --since bounds by ts; a future date excludes everything (all zeros) ──
out="$(run --since 2026-07-03)"
printf '%s\n' "$out" | grep -qE 'since 2026-07-03'         || fail "--since: scope wrong\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Merged PRs +0'           || fail "--since future: 0 merges expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'all zeros'               || fail "--since future: should note all zeros\n%s" "$out"
ok
# A date at/just before the entries keeps them.
out="$(run --since 2026-07-02)"
printf '%s\n' "$out" | grep -qE 'Merged PRs +2'           || fail "--since 07-02: 2 merges expected\n%s" "$out"
ok

# ── (4) --today restricts to today's UTC entries ──
TODAY="$(date -u +%Y-%m-%d)"
# Append a merge stamped today so --today is non-empty while the 07-02 fixture rows are excluded.
printf '{"ts":"%sT08:00:00Z","event":"merge","pr":77,"slug":"today","sha":"t","method":"--merge","reason":"gates_passed"}\n' "$TODAY" >> "$TREES/.herd/journal.jsonl"
out="$(run --today)"
printf '%s\n' "$out" | grep -qE "today \($TODAY UTC\)"     || fail "--today: scope should name today\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Merged PRs +1'           || fail "--today: only today's 1 merge expected (07-02 excluded)\n%s" "$out"
ok

# ── (5) empty / missing journal → all-zeros card, exit 0 ──
EMPTYP="$T/emptyp"; mkdir -p "$EMPTYP/.herd"
cat > "$EMPTYP/.herd/config" <<CFG
PROJECT_ROOT="$EMPTYP"
WORKTREES_DIR="$T/emptytrees"
WORKSPACE_NAME="stest2"
CFG
out="$(cd "$EMPTYP" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" stats 2>&1)"; rc=$?
[ "$rc" -eq 0 ]                                            || fail "empty journal must exit 0 (got %d)\n%s" "$rc" "$out"
printf '%s\n' "$out" | grep -qE 'Merged PRs +0'          || fail "empty: 0 merges expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'Cost recorded +\$0\.0000' || fail "empty: \$0 cost expected\n%s" "$out"
printf '%s\n' "$out" | grep -qE 'all zeros'              || fail "empty: should note all zeros\n%s" "$out"
ok

# ── (6) aggregation spans a rotated archive + the live journal ──
ROTP="$T/rotp"; ROTT="$T/rott"
mkdir -p "$ROTP/.herd" "$ROTT/.herd"
cat > "$ROTP/.herd/config" <<CFG
PROJECT_ROOT="$ROTP"
WORKTREES_DIR="$ROTT"
WORKSPACE_NAME="stest3"
CFG
# One merge in a rotated archive, one in the live journal → the card must sum to 2.
cat > "$ROTT/.herd/journal-20260601T000000Z.jsonl" <<'JNL'
{"ts":"2026-06-01T09:00:00Z","event":"merge","pr":1,"slug":"old","sha":"o","method":"--merge","reason":"gates_passed"}
JNL
cat > "$ROTT/.herd/journal.jsonl" <<'JNL'
{"ts":"2026-07-02T09:00:00Z","event":"merge","pr":2,"slug":"new","sha":"n","method":"--merge","reason":"gates_passed"}
JNL
out="$(cd "$ROTP" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" stats 2>&1)"
printf '%s\n' "$out" | grep -qE 'Merged PRs +2'          || fail "rotation: should sum archive + live = 2 merges\n%s" "$out"
ok

# ── bad --pr is rejected ──
if (cd "$PROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" stats --pr abc >/dev/null 2>&1); then
  fail "stats --pr abc should be rejected"
fi
ok

echo "PASS test-stats.sh ($pass checks)"
