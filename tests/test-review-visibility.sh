#!/usr/bin/env bash
# test-review-visibility.sh — hermetic tests for the review-visibility feature:
#   (1) agent-watch.sh override helpers: override_exists + the blocked/override gate logic
#   (2) herd-approve.sh why / override subcommands
#   (3) herd-review.sh stream-json formatter (inline python3 logic)
#   (4) herd-review.sh log-tracking cleanup
#
# Stubs gh/herdr/claude/git (NETWORK-FREE). Run:  bash tests/test-review-visibility.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
APPROVE="$HERE/../scripts/herd/herd-approve.sh"
REVIEW="$HERE/../scripts/herd/herd-review.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"

cat > "$BIN/gh" << 'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr merge")   printf 'merge %s\n' "$3" >> "${GH_MERGE_LOG:?GH_MERGE_LOG unset}"; exit 0 ;;
  "pr comment") exit 0 ;;
  "pr view")
    # Support --json headRefOid and --json comments
    if printf '%s\n' "$@" | grep -q 'headRefOid'; then
      printf '{"headRefOid":"%s"}\n' "${GH_HEAD_SHA:-abc1234567890}"
    elif printf '%s\n' "$@" | grep -q 'comments'; then
      printf '{"comments":[{"author":{"login":"reviewer"},"body":"REVIEW: BLOCK — off by one"}]}\n'
    else
      printf '{"mergeable":"%s","mergeStateStatus":"%s","headRefName":"feat/test","headRefOid":"%s"}\n' \
        "${GH_MERGEABLE:-MERGEABLE}" "${GH_MSTATE:-CLEAN}" "${GH_HEAD_SHA:-abc1234567890}"
    fi
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"

for cmd in git herdr claude; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# Verify new helpers are defined.
type override_exists   >/dev/null 2>&1 || fail "override_exists not defined after sourcing"
type review_verdict    >/dev/null 2>&1 || fail "review_verdict not defined after sourcing"
ok

# ── override_exists: empty / absent ledger ───────────────────────────────────
rm -f "$OVERRIDES"
! override_exists "1" "aaa" || fail "override_exists: empty ledger should return false"
ok

# ── override_exists: after writing a record ───────────────────────────────────
printf '1000 override 1 aaa\n' > "$OVERRIDES"
  override_exists "1" "aaa" || fail "override_exists: should detect record"
ok
! override_exists "1" "bbb" || fail "override_exists: wrong sha should not match"
ok
! override_exists "2" "aaa" || fail "override_exists: wrong PR should not match"
ok

# ── override_exists: non-override lines are not matched ───────────────────────
printf '1001 approved 1 aaa\n' >> "$OVERRIDES"
! override_exists "1" "aaa2" || fail "override_exists: 'approved' line should not match override_exists"
ok

# ── Gate logic: BLOCK + no override → skips (continue path) ──────────────────
# Set up a BLOCK verdict in the review ledger for PR 5, sha "blocked1".
rm -f "$REVIEW_STATE" "$OVERRIDES"
record_review "5" "blocked1" "BLOCK"
v="$(review_verdict "5" "blocked1" || true)"
[ "$v" = "BLOCK" ] || fail "review_verdict should return BLOCK"
ok
! override_exists "5" "blocked1" || fail "no override yet"
ok

# ── Gate logic: BLOCK + override present → override_exists returns true ───────
printf '1000 override 5 blocked1\n' > "$OVERRIDES"
override_exists "5" "blocked1" || fail "override should be detected after writing"
ok

# ── Gate logic: PASS → override_exists irrelevant, verdict is PASS ────────────
rm -f "$REVIEW_STATE" "$OVERRIDES"
record_review "7" "sha7" "PASS"
v="$(review_verdict "7" "sha7" || true)"
[ "$v" = "PASS" ] || fail "review_verdict should return PASS"
ok

# ── herd-approve.sh: why subcommand ──────────────────────────────────────────
rm -f "$REVIEW_STATE" "$OVERRIDES"
export REVIEW_STATE OVERRIDES

# No verdict → non-zero exit and error message.
out="$(bash "$APPROVE" why 99 2>&1)" && fail "why with no verdict should exit non-zero" || true
printf '%s\n' "$out" | grep -q "No review verdict" || fail "why: expected 'No review verdict' message"
ok

# Write a BLOCK verdict, run why.
printf '1000 99 deadbeef BLOCK\n' > "$REVIEW_STATE"
out="$(bash "$APPROVE" why 99 2>&1)"
printf '%s\n' "$out" | grep -q "BLOCK" || fail "why: should show BLOCK in output"
ok
printf '%s\n' "$out" | grep -q "deadbeef" || fail "why: should show sha"
ok
printf '%s\n' "$out" | grep -q "99" || fail "why: should show PR number"
ok

# With an override written, why should note it.
printf '1001 override 99 deadbeef\n' > "$OVERRIDES"
out="$(bash "$APPROVE" why 99 2>&1)"
printf '%s\n' "$out" | grep -q "override" || fail "why: should note override when present"
ok

# ── herd-approve.sh: override subcommand ─────────────────────────────────────
rm -f "$OVERRIDES"
export GH_HEAD_SHA="newsha123456789"

# Idempotent: running override twice is safe.
bash "$APPROVE" override 10 2>/dev/null || fail "override should exit 0 on success"
grep -q "override 10 newsha123456789" "$OVERRIDES" || fail "override: record not written to ledger"
ok

# Second call: idempotent, should still succeed without duplicating.
bash "$APPROVE" override 10 2>/dev/null || fail "override idempotent call should exit 0"
count="$(grep -c "override 10 newsha123456789" "$OVERRIDES")"
[ "$count" -eq 1 ] || fail "override: idempotent — should not write duplicate record (got $count)"
ok

# If SHA already has a PASS verdict, override should exit 0 with a message.
printf '999 10 newsha123456789 PASS\n' > "$REVIEW_STATE"
rm -f "$OVERRIDES"
out="$(bash "$APPROVE" override 10 2>/dev/null)"
printf '%s\n' "$out" | grep -qi "PASS\|already" || fail "override: should report existing PASS"
ok
[ ! -s "$OVERRIDES" ] || fail "override: should not write to ledger when PASS already recorded"
ok

# ── herd-review.sh: stream-json formatter (inline python3 logic) ─────────────
# Feed canned stream-json NDJSON to the formatter and verify output.
FORMATTER='
import sys, json
for line in sys.stdin:
    line = line.rstrip()
    if not line: continue
    try: obj = json.loads(line)
    except Exception: print(line, flush=True); continue
    t = obj.get("type", "")
    if t == "assistant":
        for b in obj.get("message", {}).get("content", []):
            if b.get("type") == "text":
                txt = b.get("text", "").strip()
                if txt: print("  " + txt.split("\n")[0][:100], flush=True)
            elif b.get("type") == "tool_use":
                print("  [tool] " + b.get("name", "?"), flush=True)
    elif t == "result":
        r = obj.get("result", "")
        if r: print(r, flush=True)
'

INPUT='{"type":"system","subtype":"init"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Reviewing the diff now."}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"gh","input":{"cmd":"pr diff 5"}}]}}
{"type":"result","subtype":"success","result":"After reviewing the diff carefully.\nREVIEW: PASS"}
'

out="$(printf '%s\n' "$INPUT" | python3 -uc "$FORMATTER")"
printf '%s\n' "$out" | grep -q "Reviewing the diff now" || fail "formatter: assistant text not printed"
ok
printf '%s\n' "$out" | grep -q "\[tool\] gh" || fail "formatter: tool_use not printed"
ok
printf '%s\n' "$out" | grep -q "REVIEW: PASS" || fail "formatter: final result text not printed"
ok

# Non-JSON passthrough.
out2="$(printf 'plain text line\n{"type":"result","result":"REVIEW: BLOCK — reason"}\n' | python3 -uc "$FORMATTER")"
printf '%s\n' "$out2" | grep -q "plain text line" || fail "formatter: non-JSON should pass through"
ok
printf '%s\n' "$out2" | grep -q "REVIEW: BLOCK" || fail "formatter: result with BLOCK should be printed"
ok

# ── herd-review.sh: log RETENTION (rolling window) ───────────────────────────
# herd-review.sh no longer deletes the previous log on the next review — that log is the forensic
# evidence a post-mortem needs. The slug-keyed tracker is now a rolling LIST (newest last) and the
# last $REVIEW_LOG_KEEP logs per slug are KEPT; only those that roll off the window are deleted.
# Simulate that startup step with REVIEW_LOG_KEEP=2 across three successive reviews.
_log_track="$T/trees/.review-log-myslug"
REVIEW_LOG_KEEP=2
_l1="$T/log1.txt"; _l2="$T/log2.txt"; _l3="$T/log3.txt"
printf 'one\n'   > "$_l1"
printf 'two\n'   > "$_l2"
printf 'three\n' > "$_l3"

# roll_log <new> — mirror herd-review.sh's rolling-window logic against $_log_track.
roll_log() {
  local newlog="$1" tmp="${_log_track}.tmp.$$"
  { [ -f "$_log_track" ] && cat "$_log_track" 2>/dev/null; printf '%s\n' "$newlog"; } 2>/dev/null \
    | awk 'NF' > "$tmp"
  local total; total="$(wc -l < "$tmp" | tr -cd '0-9')"; total="${total:-0}"
  if [ "$total" -gt "$REVIEW_LOG_KEEP" ]; then
    local drop=$(( total - REVIEW_LOG_KEEP ))
    head -n "$drop" "$tmp" | while IFS= read -r old; do
      [ -n "$old" ] && [ "$old" != "$newlog" ] && rm -f "$old" 2>/dev/null || true
    done
    tail -n "$REVIEW_LOG_KEEP" "$tmp" > "${tmp}.2" && mv -f "${tmp}.2" "$tmp"
  fi
  mv -f "$tmp" "$_log_track"
}

roll_log "$_l1"   # window: [l1]
roll_log "$_l2"   # window: [l1, l2] — both kept (≤ keep)
[ -f "$_l1" ] && [ -f "$_l2" ] || fail "log retention: within-window logs must be kept"
ok
roll_log "$_l3"   # window rolls: l1 falls off and is deleted, [l2, l3] kept
[ ! -f "$_l1" ] || fail "log retention: the log that rolled off the window should be deleted"
ok
[ -f "$_l2" ] && [ -f "$_l3" ] || fail "log retention: the newest \$REVIEW_LOG_KEEP logs must survive"
ok
# Tracker holds exactly the retained window, newest last.
[ "$(cat "$_log_track")" = "$(printf '%s\n%s' "$_l2" "$_l3")" ] \
  || fail "log retention: tracker should list the retained window (newest last)"
ok

echo "ALL PASS ($pass checks)"
