#!/usr/bin/env bash
# test-review-verdict-path-quote.sh — hermetic tests for HERD-133: the review-verdict RESULT_FILE
# path must be QUOTED in the rendered agent prompt, and the poll/timeout path must CONSUME a
# near-miss result file (trailing dot / whitespace) instead of burning an infra timeout + re-dispatch.
#
# Background: PR #249's reviewer wrote its verdict to 'herd-review-agent-249-Iw1smh.' (a trailing
# period) because herd-review.sh ended the AGENT_TASK prompt with the UNQUOTED result-file path
# immediately followed by the sentence's period; the model folded the period into the filename. The
# wrapper polled the dotless exact path for the full 1800s, declared an infra timeout, and
# double-dispatched a second review.
#
# Coverage:
#   (1) rendered prompt: the AGENT_TASK sent to the reviewer quotes the RESULT_FILE path ('…'), so a
#       trailing sentence period can't be absorbed into the filename (grep the rendered prompt)
#   (2) near-miss CONSUME (dotted): a fixture "agent" writes the verdict to "<path>." (trailing dot);
#       the wrapper consumes it as the verdict on timeout, exits PASS, journals verdict_path_nearmiss
#   (3) near-miss CONSUME (trailing space): same, for a "<path> " whitespace variant
#   (4) EXACT-path flow is UNCHANGED: agent writes the exact path → PASS, NO nearmiss journal event
#   (5) a genuine timeout with NO near-miss still emits INFRA-FAIL (near-miss must not swallow it)
#   (6) source guard: herd-review.sh renders the RESULT_FILE path single-quoted
#
# Stubs herdr/gh/git/claude (NETWORK-FREE). Run:  bash tests/test-review-verdict-path-quote.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REVIEW="$HERE/../scripts/herd/herd-review.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$REVIEW" ] || fail "herd-review.sh not found at $REVIEW"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Common stubs (mirror test-review-pane-v2.sh so agent-pane mode is exercised) ──────────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/gh";  chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git"; chmod +x "$BIN/git"

# herdr stub: logs its FULL argv (so the rendered AGENT_TASK 'pointer' is greppable), and answers the
# agent/tab list + agent start needed to reach agent-pane mode.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wA","label":"herdkit"}]}}\n' ;;
  "agent list")     cat "${HERDR_AGENT_LIST_RESP:-/dev/null}" 2>/dev/null || printf '{"result":{"agents":[]}}\n' ;;
  "tab list")       cat "${HERDR_TAB_LIST_RESP:-/dev/null}" 2>/dev/null || printf '{"result":{"tabs":[]}}\n' ;;
  "agent start")    cat "${HERDR_AGENT_START_RESP:-/dev/null}" 2>/dev/null || printf '{"result":{"agent":{"pane_id":""}}}\n' ;;
  "tab create")     printf '{"result":{"tab":{"tab_id":"newTab1"},"root_pane":{"pane_id":"rootPane1"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"

# claude stub: never used by the agent-pane path (the fixture writes the result file directly), but
# present so any headless fallthrough is deterministic rather than invoking a real binary.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","result":"REVIEW: PASS"}\n'
exit 0
STUB
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKSPACE_NAME="herdkit"
export HERDR_CALL_LOG="$T/herdr-calls.log"
export JOURNAL_FILE="$T/journal.jsonl"       # journal.sh honors this test seam
export HERDR_AGENT_LIST_RESP="$T/agent-list.json"
export HERDR_TAB_LIST_RESP="$T/tab-list.json"
export HERDR_AGENT_START_RESP="$T/agent-start.json"

# Agent-pane preconditions: a live builder pane + tab for the slug, and a successful review start.
_builder_ready() {
  printf '{"result":{"agents":[{"name":"nm-slug","pane_id":"builderPane1","agent_status":"idle"}]}}\n' > "$HERDR_AGENT_LIST_RESP"
  printf '{"result":{"tabs":[{"tab_id":"builderTab1","label":"nm-slug","workspace_id":"wA"}]}}\n'       > "$HERDR_TAB_LIST_RESP"
  printf '{"result":{"agent":{"pane_id":"reviewPane1"}}}\n'                                             > "$HERDR_AGENT_START_RESP"
}
_reset() { : > "$HERDR_CALL_LOG"; : > "$JOURNAL_FILE"; }

# ── (1) rendered prompt quotes the RESULT_FILE path ───────────────────────────────────────────────
# Drive a review whose agent temp is a KNOWN path; the rendered AGENT_TASK (the herdr 'pointer' argv)
# must contain that path SINGLE-QUOTED, so a trailing period can't be absorbed into the filename.
_reset; _builder_ready
AGENT_TEMP1="$T/agent-temp-quote"
RES1="$T/res-quote"
# Write the verdict to the exact path immediately so the poll returns fast (this test is about the
# prompt, not the timeout path).
printf 'REVIEW: PASS\n' > "$AGENT_TEMP1"
HERD_REVIEW_AGENT_TEMP="$AGENT_TEMP1" HERD_REVIEW_RESULT_FILE="$RES1" \
  HERD_REVIEW_AGENT_TIMEOUT=10 HERD_REVIEW_AGENT_POLL=1 \
  bash "$REVIEW" 1 nm-slug >/dev/null 2>&1
# The rendered prompt must carry the QUOTED form:  is: '<AGENT_TEMP1>'
grep -qF "is: '$AGENT_TEMP1'" "$HERDR_CALL_LOG" \
  || fail "(1) rendered AGENT_TASK should quote the RESULT_FILE path (is: '<path>')"
ok
# And it must NOT carry the old UNQUOTED trailing-period form: "…: <path>." (the HERD-133 bug shape).
grep -qF "is: $AGENT_TEMP1." "$HERDR_CALL_LOG" \
  && fail "(1) rendered AGENT_TASK must not emit the unquoted '<path>.' form" || true
ok

# ── (2) near-miss CONSUME: a dotted result file is adopted on timeout, PASS + journal ─────────────
_reset; _builder_ready
AGENT_TEMP2="$T/agent-temp-nm"
RES2="$T/res-nm"
rm -f "$AGENT_TEMP2" "$AGENT_TEMP2."   # exact path stays absent; verdict lands one char off (dotted)
printf 'REVIEW: PASS\n' > "$AGENT_TEMP2."
out="$(HERD_REVIEW_AGENT_TEMP="$AGENT_TEMP2" HERD_REVIEW_RESULT_FILE="$RES2" \
       HERD_REVIEW_AGENT_TIMEOUT=3 HERD_REVIEW_AGENT_POLL=1 \
       bash "$REVIEW" 2 nm-slug 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] || fail "(2) dotted near-miss should be consumed as PASS (exit 0), got $rc"
ok
printf '%s\n' "$out" | grep -q '^REVIEW: PASS$' || fail "(2) should print REVIEW: PASS from the near-miss verdict"
ok
grep -q '^REVIEW: PASS$' "$RES2" || fail "(2) result file should hold the consumed near-miss verdict"
ok
printf '%s\n' "$out" | grep -q 'INFRA-FAIL' && fail "(2) a consumed near-miss must NOT become INFRA-FAIL" || true
ok
grep -q '"event":"verdict_path_nearmiss"' "$JOURNAL_FILE" 2>/dev/null \
  || fail "(2) a verdict_path_nearmiss event should be journaled"
ok
# The journal event records the actual (near-miss) path so a post-mortem can see the byte offset.
grep -qF "$AGENT_TEMP2." "$JOURNAL_FILE" 2>/dev/null \
  || fail "(2) the nearmiss journal event should record the actual dotted path"
ok

# ── (3) near-miss CONSUME: a trailing-space variant is also adopted ───────────────────────────────
_reset; _builder_ready
AGENT_TEMP3="$T/agent-temp-sp"
RES3="$T/res-sp"
rm -f "$AGENT_TEMP3" "$AGENT_TEMP3 "
printf 'REVIEW: BLOCK — off-by-one in the accumulation loop\n' > "$AGENT_TEMP3 "  # trailing space
out="$(HERD_REVIEW_AGENT_TEMP="$AGENT_TEMP3" HERD_REVIEW_RESULT_FILE="$RES3" \
       HERD_REVIEW_AGENT_TIMEOUT=3 HERD_REVIEW_AGENT_POLL=1 \
       bash "$REVIEW" 3 nm-slug 2>/dev/null)"
rc=$?
[ "$rc" -eq 1 ] || fail "(3) trailing-space near-miss BLOCK should be consumed as BLOCK (exit 1), got $rc"
ok
grep -q '^REVIEW: BLOCK' "$RES3" || fail "(3) result file should hold the consumed BLOCK near-miss verdict"
ok
printf '%s\n' "$out" | grep -q 'off-by-one' || fail "(3) the BLOCK reason should survive near-miss consumption"
ok
grep -q '"event":"verdict_path_nearmiss"' "$JOURNAL_FILE" 2>/dev/null \
  || fail "(3) trailing-space near-miss should also journal verdict_path_nearmiss"
ok

# ── (4) EXACT-path flow unchanged: writes to the exact path → PASS, NO nearmiss event ─────────────
_reset; _builder_ready
AGENT_TEMP4="$T/agent-temp-exact"
RES4="$T/res-exact"
rm -f "$AGENT_TEMP4."   # ensure no near-miss decoy exists
printf 'REVIEW: PASS\n' > "$AGENT_TEMP4"   # verdict at the EXACT expected path
out="$(HERD_REVIEW_AGENT_TEMP="$AGENT_TEMP4" HERD_REVIEW_RESULT_FILE="$RES4" \
       HERD_REVIEW_AGENT_TIMEOUT=10 HERD_REVIEW_AGENT_POLL=1 \
       bash "$REVIEW" 4 nm-slug 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] || fail "(4) exact-path verdict should PASS (exit 0), got $rc"
ok
grep -q '^REVIEW: PASS$' "$RES4" || fail "(4) exact-path result file should hold REVIEW: PASS"
ok
grep -q '"event":"verdict_path_nearmiss"' "$JOURNAL_FILE" 2>/dev/null \
  && fail "(4) the exact-path flow must NOT journal a nearmiss event (byte-identical to before)" || true
ok

# ── (5) genuine timeout, NO near-miss present → INFRA-FAIL (near-miss must not swallow real timeouts) ─
_reset; _builder_ready
AGENT_TEMP5="$T/agent-temp-none"
RES5="$T/res-none"
rm -f "$AGENT_TEMP5" "$AGENT_TEMP5." "$AGENT_TEMP5 "   # nothing is ever written anywhere
out="$(HERD_REVIEW_AGENT_TEMP="$AGENT_TEMP5" HERD_REVIEW_RESULT_FILE="$RES5" \
       HERD_REVIEW_AGENT_TIMEOUT=3 HERD_REVIEW_AGENT_POLL=1 \
       bash "$REVIEW" 5 nm-slug 2>/dev/null)"
rc=$?
[ "$rc" -eq 2 ] || fail "(5) a genuine no-verdict timeout should still exit 2 (INFRA-FAIL), got $rc"
ok
grep -q '^REVIEW: INFRA-FAIL' "$RES5" || fail "(5) result file should hold INFRA-FAIL when there is no near-miss"
ok
grep -q '"event":"verdict_path_nearmiss"' "$JOURNAL_FILE" 2>/dev/null \
  && fail "(5) a real timeout with no near-miss must NOT journal a nearmiss event" || true
ok

# ── (6) source guard: the RESULT_FILE path is rendered single-quoted in AGENT_TASK ────────────────
grep -qF "path for rule 5 is: '\${_agent_result_file}'" "$REVIEW" \
  || fail "(6) herd-review.sh should render the RESULT_FILE path single-quoted in AGENT_TASK"
ok

echo "ALL PASS ($pass checks)"
