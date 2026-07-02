#!/usr/bin/env bash
# test-journal.sh — hermetic tests for the persistent engine journal (scripts/herd/journal.sh)
# and its readers (`herd log`, `herd why`). Covers:
#   (1) journal_append writes one valid JSON line per call; ts + event always present; integer-
#       looking values (pid, attempt, exit_code) become JSON numbers; strings stay strings
#   (2) per-event schema — each event type the engine emits carries the fields consumers rely on
#   (3) concurrent-append integrity — N racing writers → exactly N whole, parseable lines
#   (4) rotation trigger — past JOURNAL_MAX_BYTES the live journal is archived and a fresh one starts
#   (5) unwritable journal NEVER breaks the caller, even under `set -euo pipefail`
#   (6) `herd why <pr>` aggregates one PR's history chronologically and excludes other PRs
#   (7) `herd log --pr N` filters to a single PR
#
# Fully hermetic: writes only under a mktemp dir, never touches the live watcher/panes/real HOME.
# Run:  bash tests/test-journal.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
JOURNAL_SH="$REPO/scripts/herd/journal.sh"
HERD_BIN="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$JOURNAL_SH" ] || fail "journal.sh not found at $JOURNAL_SH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# jq-free JSON field reader: _field <file> <line-index-0based> <key> — prints the value (int or str).
_field() {
  python3 -c '
import sys, json
with open(sys.argv[1]) as f:
    lines = [l for l in f if l.strip()]
o = json.loads(lines[int(sys.argv[2])])
v = o.get(sys.argv[3], "<MISSING>")
sys.stdout.write(str(v))
' "$1" "$2" "$3"
}
# _is_int_json <file> <line> <key> — exit 0 iff the JSON value is an int (not a string).
_is_int_json() {
  python3 -c '
import sys, json
with open(sys.argv[1]) as f:
    lines = [l for l in f if l.strip()]
o = json.loads(lines[int(sys.argv[2])])
sys.exit(0 if isinstance(o.get(sys.argv[3]), int) else 1)
' "$1" "$2" "$3"
}
# _all_valid_json <file> — exit 0 iff every non-empty line parses as a JSON object.
_all_valid_json() {
  python3 -c '
import sys, json
n = 0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        o = json.loads(line)   # raises on a torn/partial line → non-zero exit
        assert isinstance(o, dict)
        n += 1
print(n)
' "$1"
}

# ── (1) basic append: one valid JSON line, ts + event present, int coercion ──
export JOURNAL_FILE="$T/j1/journal.jsonl"
# shellcheck source=/dev/null
. "$JOURNAL_SH" || fail "sourcing journal.sh failed"
type journal_append >/dev/null 2>&1 || fail "journal_append not defined after sourcing"
ok

journal_append review_dispatched pr 54 sha abc123 pid 9876 model claude-opus-4-8
[ -f "$JOURNAL_FILE" ] || fail "journal file not created on first append"
ok
[ "$(_all_valid_json "$JOURNAL_FILE")" = "1" ] || fail "first append should yield exactly 1 valid JSON line"
ok
[ "$(_field "$JOURNAL_FILE" 0 event)" = "review_dispatched" ] || fail "event field wrong"
ok
[ "$(_field "$JOURNAL_FILE" 0 pr)" = "54" ]   || fail "pr field wrong"
ok
[ "$(_field "$JOURNAL_FILE" 0 model)" = "claude-opus-4-8" ] || fail "model field wrong"
ok
# ts present and ISO-8601-ish (YYYY-MM-DDTHH:MM:SSZ).
printf '%s' "$(_field "$JOURNAL_FILE" 0 ts)" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  || fail "ts should be ISO-8601 UTC (got '$(_field "$JOURNAL_FILE" 0 ts)')"
ok
# pid/pr are ints in JSON; model/sha are strings.
_is_int_json "$JOURNAL_FILE" 0 pid || fail "pid should be a JSON number"
ok
_is_int_json "$JOURNAL_FILE" 0 pr  || fail "pr should be a JSON number"
ok
_is_int_json "$JOURNAL_FILE" 0 model && fail "model should be a JSON string, not a number"
ok

# empty event type is a no-op (never writes a garbage line).
_before="$(wc -l < "$JOURNAL_FILE")"
journal_append ""
[ "$(wc -l < "$JOURNAL_FILE")" -eq "$_before" ] || fail "empty event type must not append"
ok

# ── (2) per-event schema: every event the engine emits carries its consumer fields ──
export JOURNAL_FILE="$T/j2/journal.jsonl"
journal_append verdict_recorded pr 54 sha deadbeef value PASS source reviewer
journal_append healthcheck_attempted pr 54 slug feat-x attempt 1 result clean
journal_append healthcheck_retried pr 54 slug feat-x attempt 2 result flaky-pass
journal_append healthcheck_outcome pr 54 slug feat-x outcome CLEAN
journal_append refix_bounce pr 54 sha deadbeef slug feat-x round 1 agent_status_before idle
journal_append refix_wake_result pr 54 sha deadbeef slug feat-x round 1 agent_status_before idle agent_status_after working woke 1 escalated false
journal_append merge pr 54 slug feat-x sha deadbeef method --merge reason gates_passed
journal_append reap pr 54 slug feat-x sha deadbeef reason merged
journal_append review_log_retained pr 54 slug feat-x path /tmp/herd-review-54-abcdef keep 5
journal_append infra_event component herd-review pr 54 slug feat-x exit_code 2 stderr_tail "review severed (SIGTERM/SIGPIPE) before a verdict"
journal_append sweep_closed tab_id tab-123 reason orphan
journal_append reload_outcome component watcher result "pane below coordinator"

nlines="$(_all_valid_json "$JOURNAL_FILE")" || fail "schema batch produced a non-JSON line"
[ "$nlines" = "12" ] || fail "expected 12 event lines, got $nlines"
ok

# Spot-check the fields consumers depend on, by event type.
python3 -c '
import sys, json
events = {}
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        o = json.loads(line)
        events[o["event"]] = o

def need(ev, *keys):
    o = events.get(ev)
    assert o is not None, "missing event "+ev
    for k in keys:
        assert k in o, "%s missing field %s" % (ev, k)

need("verdict_recorded", "pr", "sha", "value", "source")
need("healthcheck_attempted", "pr", "slug", "attempt", "result")
need("healthcheck_retried", "pr", "slug", "attempt", "result")
need("healthcheck_outcome", "pr", "slug", "outcome")
need("refix_bounce", "pr", "sha", "slug", "round", "agent_status_before")
need("refix_wake_result", "pr", "sha", "agent_status_before", "agent_status_after", "escalated")
need("merge", "pr", "slug", "sha", "method", "reason")
need("reap", "pr", "slug", "sha", "reason")
need("review_log_retained", "pr", "slug", "path")
need("infra_event", "component", "exit_code", "stderr_tail")
need("sweep_closed", "tab_id", "reason")
need("reload_outcome", "component", "result")
# provenance value survives verbatim
assert events["verdict_recorded"]["source"] == "reviewer"
# a stderr tail carrying spaces/parens round-trips intact (JSON escaping works)
assert "SIGTERM/SIGPIPE" in events["infra_event"]["stderr_tail"]
assert events["infra_event"]["exit_code"] == 2
print("schema OK")
' "$JOURNAL_FILE" >/dev/null || fail "per-event schema assertions failed"
ok

# ── (3) concurrent-append integrity: N racing writers → N whole parseable lines ──
export JOURNAL_FILE="$T/j3/journal.jsonl"
mkdir -p "$T/j3"   # pre-create so all writers skip the mkdir race and just append
N=40
for i in $(seq 1 "$N"); do
  ( journal_append concurrent_probe pr "$i" slug "writer-$i" note "line number $i with spaces" ) &
done
wait
got="$(_all_valid_json "$JOURNAL_FILE")" || fail "concurrent append produced a torn/partial JSON line"
[ "$got" = "$N" ] || fail "concurrent append: expected $N whole lines, got $got"
ok
# every writer's unique pr appears exactly once (no lost or duplicated appends).
uniq_prs="$(python3 -c '
import sys, json
seen=set()
for line in open(sys.argv[1]):
    line=line.strip()
    if line: seen.add(json.loads(line)["pr"])
print(len(seen))
' "$JOURNAL_FILE")"
[ "$uniq_prs" = "$N" ] || fail "concurrent append: expected $N distinct writers, got $uniq_prs"
ok

# ── (4) rotation trigger: past JOURNAL_MAX_BYTES → archive + fresh live journal ──
export JOURNAL_FILE="$T/j4/journal.jsonl"
export JOURNAL_MAX_BYTES=400          # tiny threshold so a handful of events trips it
for i in $(seq 1 12); do
  journal_append rotate_probe pr "$i" slug "s-$i" padding "some filler text to grow the file quickly"
done
# At least one archive was created, and the live journal still exists (fresh, smaller than a full run).
archives="$(ls -1 "$T"/j4/journal-*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
[ "$archives" -ge 1 ] || fail "rotation: expected ≥1 archived journal-<stamp>.jsonl, found $archives"
ok
[ -f "$JOURNAL_FILE" ] || fail "rotation: a fresh live journal should exist after rotating"
ok
# No events were lost across the rotation boundary: total lines (archives + live) == 12.
total="$(cat "$T"/j4/journal-*.jsonl "$JOURNAL_FILE" 2>/dev/null | grep -c . )"
[ "$total" -eq 12 ] || fail "rotation: expected 12 total events across archive+live, got $total"
ok
unset JOURNAL_MAX_BYTES

# ── (5) unwritable journal NEVER breaks the caller, even under set -euo pipefail ──
# Parent path is a FILE, so mkdir of the journal dir can't succeed → append is silently dropped.
: > "$T/blocker"
out="$(bash -c '
  set -euo pipefail
  . "'"$JOURNAL_SH"'"
  export JOURNAL_FILE="'"$T"'/blocker/sub/journal.jsonl"
  journal_append test_event k v
  echo SURVIVED
' 2>/dev/null)"
[ "$out" = "SURVIVED" ] || fail "unwritable (bad parent) journal must not abort a set -e caller (got '$out')"
ok
# A read-only existing journal file: the append fails but the caller still survives.
mkdir -p "$T/ro"; : > "$T/ro/journal.jsonl"; chmod 0444 "$T/ro/journal.jsonl"
out="$(bash -c '
  set -euo pipefail
  . "'"$JOURNAL_SH"'"
  export JOURNAL_FILE="'"$T"'/ro/journal.jsonl"
  journal_append test_event k v
  echo SURVIVED
' 2>/dev/null)"
[ "$out" = "SURVIVED" ] || fail "read-only journal must not abort a set -e caller (got '$out')"
ok
chmod 0644 "$T/ro/journal.jsonl" 2>/dev/null || true
unset JOURNAL_FILE

# ── seed a hermetic project + journal for the reader tests (herd why / herd log) ──
PROJ="$T/proj"; TREES="$T/trees"
mkdir -p "$PROJ/.herd" "$TREES/.herd"
cat > "$PROJ/.herd/config" <<CFG
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$TREES"
WORKSPACE_NAME="jtest"
CFG
cat > "$TREES/.herd/journal.jsonl" <<'JNL'
{"ts":"2026-07-02T14:03:12Z","event":"review_dispatched","pr":54,"sha":"abc1234def","pid":12345,"model":"claude-opus-4-8"}
{"ts":"2026-07-02T14:09:44Z","event":"healthcheck_attempted","pr":54,"slug":"feat-x","attempt":1,"result":"clean"}
{"ts":"2026-07-02T14:09:45Z","event":"healthcheck_outcome","pr":54,"slug":"feat-x","outcome":"CLEAN"}
{"ts":"2026-07-02T14:10:01Z","event":"verdict_recorded","pr":54,"sha":"abc1234def","value":"PASS","source":"reviewer"}
{"ts":"2026-07-02T14:10:02Z","event":"merge","pr":54,"slug":"feat-x","sha":"abc1234def","method":"--merge","reason":"gates_passed"}
{"ts":"2026-07-02T14:10:05Z","event":"reap","pr":54,"slug":"feat-x","sha":"abc1234def","reason":"merged"}
{"ts":"2026-07-02T15:00:00Z","event":"verdict_recorded","pr":55,"sha":"9999","value":"BLOCK","source":"reviewer"}
{"ts":"2026-07-02T15:00:30Z","event":"infra_event","component":"herd-review","pr":55,"exit_code":2,"stderr_tail":"severed"}
JNL

# ── (6) herd why <pr> — chronological, PR-scoped, excludes other PRs ──
why_out="$(cd "$PROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" why 54 2>&1)"
printf '%s\n' "$why_out" | grep -q "PR #54" || fail "herd why: header should name PR #54"
ok
printf '%s\n' "$why_out" | grep -q "review dispatched" || fail "herd why: should list review dispatch"
ok
printf '%s\n' "$why_out" | grep -q "PASS (reviewer)" || fail "herd why: should show verdict + provenance"
ok
printf '%s\n' "$why_out" | grep -q "MERGED" || fail "herd why: should show the merge"
ok
printf '%s\n' "$why_out" | grep -q "reaped worktree" || fail "herd why: should show the reap"
ok
# PR 55's events must NOT bleed into PR 54's history.
printf '%s\n' "$why_out" | grep -q "BLOCK" && fail "herd why 54: must not include PR #55's BLOCK"
ok
# Chronological order: dispatch line appears before the merge line.
disp_ln="$(printf '%s\n' "$why_out" | grep -n "review dispatched" | head -1 | cut -d: -f1)"
merge_ln="$(printf '%s\n' "$why_out" | grep -n "MERGED" | head -1 | cut -d: -f1)"
[ -n "$disp_ln" ] && [ -n "$merge_ln" ] && [ "$disp_ln" -lt "$merge_ln" ] \
  || fail "herd why: events must be chronological (dispatch before merge)"
ok
# A PR with no journal entries reports cleanly (never errors).
why_none="$(cd "$PROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" why 999 2>&1)"
printf '%s\n' "$why_none" | grep -q "no journal entries" || fail "herd why: unknown PR should report no entries"
ok

# ── (7) herd log --pr N filters to a single PR ──
log_out="$(cd "$PROJ" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" log --pr 55 2>&1)"
printf '%s\n' "$log_out" | grep -q "pr=55" || fail "herd log --pr 55 should show PR 55 events"
ok
printf '%s\n' "$log_out" | grep -q "pr=54" && fail "herd log --pr 55 must not show PR 54 events"
ok
# herd log with no journal → friendly message, exit 0.
EMPTYP="$T/emptyproj"; mkdir -p "$EMPTYP/.herd"
cat > "$EMPTYP/.herd/config" <<CFG
PROJECT_ROOT="$EMPTYP"
WORKTREES_DIR="$T/emptytrees"
WORKSPACE_NAME="empty"
CFG
log_empty="$(cd "$EMPTYP" && HERD_NONINTERACTIVE=1 bash "$HERD_BIN" log 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "herd log with no journal should exit 0"
ok
printf '%s\n' "$log_empty" | grep -q "no engine journal yet" || fail "herd log: empty case should say so"
ok

echo "ALL PASS ($pass checks)"
