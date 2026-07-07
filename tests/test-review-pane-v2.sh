#!/usr/bin/env bash
# test-review-pane-v2.sh — hermetic tests for Review pane v2:
#   (1) agent-pane placement: review spawned as bottom split inside the builder's existing tab
#   (2) tab-gone fallback: standalone review·<slug> tab when builder tab/pane not found
#   (3) agent-pane BLOCK: BLOCK verdict collected from result file written by the agent
#   (4) headless fallback: herdr absent → falls back to headless claude -p (verdict captured)
#   (5) INFRA retry: agent never writes result file → INFRA-FAIL emitted on timeout
#   (6) re-review REUSE (HERD-81): a stale review·<slug> split in the builder tab is closed and
#       the re-review re-splits into the SAME tab — no new tail tab, pane count stays stable
#
# Stubs herdr/gh/git/claude (NETWORK-FREE). Run:  bash tests/test-review-pane-v2.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REVIEW="$HERE/../scripts/herd/herd-review.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$REVIEW" ] || fail "herd-review.sh not found at $REVIEW"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# wait_for <timeout-s> <test-cmd...> — poll every 0.2 s; fail-friendly (returns 1).
wait_for() {
  local deadline=$(( $(date +%s) + $1 )); shift
  while ! "$@" 2>/dev/null; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
  return 0
}

# ── Common stubs ──────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"

# gh stub: always succeeds (pr comment, pr diff, etc.)
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/gh"; chmod +x "$BIN/gh"
# git stub: always succeeds
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git"; chmod +x "$BIN/git"

# herdr stub: behaviour controlled per-test via log files and response files.
#   HERDR_AGENT_LIST_RESP   — JSON for 'herdr agent list'
#   HERDR_TAB_LIST_RESP     — JSON for 'herdr tab list'
#   HERDR_AGENT_START_RESP  — JSON for 'herdr agent start'
#   HERDR_CALL_LOG          — appends each herdr call as one line
#   HERD_REVIEW_AGENT_TEMP  — (herd-review.sh env) points the script to the test's agent temp
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wA","label":"herdkit"}]}}\n' ;;
  "agent list")
    cat "${HERDR_AGENT_LIST_RESP:-/dev/null}" 2>/dev/null \
      || printf '{"result":{"agents":[]}}\n' ;;
  "tab list")
    cat "${HERDR_TAB_LIST_RESP:-/dev/null}" 2>/dev/null \
      || printf '{"result":{"tabs":[]}}\n' ;;
  "agent start")
    cat "${HERDR_AGENT_START_RESP:-/dev/null}" 2>/dev/null \
      || printf '{"result":{"agent":{"pane_id":""}}}\n' ;;
  "tab create")
    printf '{"result":{"tab":{"tab_id":"newTab1"},"root_pane":{"pane_id":"rootPane1"}}}\n' ;;
  "pane rename"|"pane run"|"tab close"|"pane close")
    : ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"

# claude stub for headless tests: emit stream-json with a PASS verdict.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","result":"REVIEW: PASS"}\n'
exit 0
STUB
chmod +x "$BIN/claude"

export PATH="$BIN:$PATH"

# Shared env used by all herd-review.sh invocations.
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKSPACE_NAME="herdkit"
export HERDR_CALL_LOG="$T/herdr-calls.log"

# ── Reset helpers ─────────────────────────────────────────────────────────────
_reset_logs() { : > "$HERDR_CALL_LOG"; }
_agent_list_with_builder() {
  printf '{"result":{"agents":[{"name":"test-slug","pane_id":"builderPane1","agent_status":"idle"}]}}\n' \
    > "$HERDR_AGENT_LIST_RESP"
}
_tab_list_with_builder() {
  printf '{"result":{"tabs":[{"tab_id":"builderTab1","label":"test-slug","workspace_id":"wA"}]}}\n' \
    > "$HERDR_TAB_LIST_RESP"
}
_agent_start_success() {
  printf '{"result":{"agent":{"pane_id":"reviewPane1"}}}\n' > "$HERDR_AGENT_START_RESP"
}
_agent_start_failure() {
  printf '{"result":{"agent":{"pane_id":""}}}\n' > "$HERDR_AGENT_START_RESP"
}
_no_builder() {
  printf '{"result":{"agents":[]}}\n' > "$HERDR_AGENT_LIST_RESP"
  printf '{"result":{"tabs":[]}}\n'   > "$HERDR_TAB_LIST_RESP"
}

export HERDR_AGENT_LIST_RESP="$T/agent-list.json"
export HERDR_TAB_LIST_RESP="$T/tab-list.json"
export HERDR_AGENT_START_RESP="$T/agent-start.json"

# ── (1) agent-pane mode: review split inside builder's tab ───────────────────
_reset_logs
_agent_list_with_builder
_tab_list_with_builder
_agent_start_success

AGENT_TEMP1="$T/agent-temp-1"   # private temp the "agent" writes to
RES="$T/result-1-sha1"           # $HERD_REVIEW_RESULT_FILE — atomically written by herd-review.sh
# Simulate the agent writing its verdict to the private temp 1s after start.
# herd-review.sh reads this and then atomically writes $RES itself via _emit_verdict.
( sleep 1; printf 'REVIEW: PASS\n' > "$AGENT_TEMP1" ) &

out="$(HERD_REVIEW_AGENT_TEMP="$AGENT_TEMP1" \
       HERD_REVIEW_RESULT_FILE="$RES" \
       HERD_REVIEW_AGENT_TIMEOUT=15 HERD_REVIEW_AGENT_POLL=1 \
       bash "$REVIEW" 1 test-slug 2>/dev/null)"
rc=$?

# Verify: agent start was called (contains 'agent start')
grep -q 'agent start' "$HERDR_CALL_LOG" || fail "1: herdr agent start should be called in agent-pane mode"
ok
# Verify: --split down was passed
grep -q 'split down' "$HERDR_CALL_LOG" || fail "1: herdr agent start should use --split down"
ok
# Verify: builder tab was targeted (builderTab1)
grep -q 'builderTab1' "$HERDR_CALL_LOG" || fail "1: herdr agent start should target the builder tab"
ok
# Verify: no new tab was created (the review is inside the builder's tab)
grep -q 'tab create' "$HERDR_CALL_LOG" && fail "1: herdr tab create should NOT be called in agent-pane mode" || true
ok
# Verify: verdict collected, PASS
[ "$rc" -eq 0 ] || fail "1: herd-review.sh should exit 0 on PASS (got $rc)"
ok
printf '%s\n' "$out" | grep -q '^REVIEW: PASS$' || fail "1: should print REVIEW: PASS to stdout"
ok
[ -f "$RES" ] || fail "1: result file should exist"
ok
grep -q '^REVIEW: PASS$' "$RES" || fail "1: result file should contain REVIEW: PASS"
ok

wait 2>/dev/null || true   # reap background job

# ── (2) tab-gone fallback: standalone review·<slug> tab ──────────────────────
_reset_logs
_no_builder

RES="$T/result-2-sha2"
out="$(HERD_NO_PANE=0 HERD_REVIEW_RESULT_FILE="$RES" \
       bash "$REVIEW" 2 test-slug 2>/dev/null)"
rc=$?

# Verify: agent start was NOT called (no builder pane/tab)
grep -q 'agent start' "$HERDR_CALL_LOG" && fail "2: herdr agent start should NOT be called without a builder tab" || true
ok
# Verify: standalone tab was created
grep -q 'tab create' "$HERDR_CALL_LOG" || fail "2: herdr tab create should be called for the standalone fallback"
ok
# Verify: tail -f was set up (pane run with tail)
grep -q 'pane run' "$HERDR_CALL_LOG" || fail "2: herdr pane run should be called to tail the log"
ok
# Verify: registry entry written for the standalone tab
grep -q 'review·test-slug' "$WORKTREES_DIR/.herd-tabs" 2>/dev/null || fail "2: standalone review tab should be registered in .herd-tabs"
ok
# Verdict comes from headless claude (stub returns PASS)
[ "$rc" -eq 0 ] || fail "2: herd-review.sh should exit 0 on PASS from headless fallback (got $rc)"
ok
printf '%s\n' "$out" | grep -q '^REVIEW: PASS$' || fail "2: headless fallback should produce REVIEW: PASS"
ok

# ── (3) agent-pane BLOCK: BLOCK verdict from result file ─────────────────────
_reset_logs
_agent_list_with_builder
_tab_list_with_builder
_agent_start_success

AGENT_TEMP3="$T/agent-temp-3"
RES="$T/result-3-sha3"
( sleep 1; printf 'REVIEW: BLOCK — off by one in the accumulation loop\n' > "$AGENT_TEMP3" ) &

out="$(HERD_REVIEW_AGENT_TEMP="$AGENT_TEMP3" \
       HERD_REVIEW_RESULT_FILE="$RES" \
       HERD_REVIEW_AGENT_TIMEOUT=15 HERD_REVIEW_AGENT_POLL=1 \
       bash "$REVIEW" 3 test-slug 2>/dev/null)"
rc=$?

[ "$rc" -eq 1 ] || fail "3: herd-review.sh should exit 1 on BLOCK (got $rc)"
ok
printf '%s\n' "$out" | grep -q '^REVIEW: BLOCK' || fail "3: should print REVIEW: BLOCK to stdout"
ok
grep -q '^REVIEW: BLOCK' "$RES" || fail "3: result file should contain REVIEW: BLOCK"
ok
printf '%s\n' "$out" | grep -q 'off by one' || fail "3: BLOCK reason should be preserved"
ok

wait 2>/dev/null || true

# ── (4) headless fallback: HERD_NO_PANE=1 forces the headless claude -p pipeline ─
# What is under test: the headless review pipeline that runs when there is NO live pane surface.
# We force it with the documented HERD_NO_PANE=1 knob (herd-review.sh:59), which gates the SAME
# branch as `command -v herdr` (herd-review.sh:226) — so the downstream headless pipeline
# exercised here is byte-for-byte identical to the 'herdr genuinely absent' case.
#
# We do NOT try to make herdr unfindable by stripping PATH: the previous approach stripped only
# the stub bin dir while KEEPING every system path, so on any machine with herdr actually
# installed herd-review.sh found the REAL herdr, took the live-pane route, failed to find a
# builder named 'test-slug', hit the tab-gone fallback, and created a REAL 'review·test-slug' tab
# (with an orphaned 'tail -f') in the user's live workspace — a hermeticity leak that fired on
# every full test-suite run. The HERD_NO_PANE knob reaches the identical headless code with zero
# dependence on PATH contents. (The suite's tab/pane leak-guard in .herd/healthcheck.project.sh
# now also fails loudly if any test ever escapes its stubs like this again.)
_reset_logs
RES="$T/result-4-sha4"
out="$(HERD_NO_PANE=1 \
       HERD_REVIEW_RESULT_FILE="$RES" \
       bash "$REVIEW" 4 test-slug 2>/dev/null)"
rc=$?

[ "$rc" -eq 0 ] || fail "4: headless mode (HERD_NO_PANE=1) should exit 0 on PASS (got $rc)"
ok
printf '%s\n' "$out" | grep -q '^REVIEW: PASS$' || fail "4: headless fallback should produce REVIEW: PASS"
ok
[ -f "$RES" ] || fail "4: headless mode should still write the result file"
ok
grep -q '^REVIEW: PASS$' "$RES" || fail "4: result file should contain REVIEW: PASS in headless mode"
ok
# Hermeticity: the headless path must touch NO pane surface — no live-pane route, no tab create.
grep -q 'agent start' "$HERDR_CALL_LOG" && fail "4: headless mode must NOT call herdr agent start" || true
ok
grep -q 'tab create' "$HERDR_CALL_LOG" && fail "4: headless mode must NOT call herdr tab create" || true
ok

# ── (5) INFRA retry: agent never writes result file → INFRA-FAIL on timeout ──
_reset_logs
_agent_list_with_builder
_tab_list_with_builder
_agent_start_success

AGENT_TEMP5="$T/agent-temp-5"
RES="$T/result-5-sha5"
# Nobody writes $AGENT_TEMP5 — simulates agent pane never completing its verdict.
out="$(HERD_REVIEW_AGENT_TEMP="$AGENT_TEMP5" \
       HERD_REVIEW_RESULT_FILE="$RES" \
       HERD_REVIEW_AGENT_TIMEOUT=3 HERD_REVIEW_AGENT_POLL=1 \
       bash "$REVIEW" 5 test-slug 2>/dev/null)"
rc=$?

[ "$rc" -eq 2 ] || fail "5: timed-out agent-pane reviewer should exit 2 (INFRA-FAIL, got $rc)"
ok
printf '%s\n' "$out" | grep -q '^REVIEW: INFRA-FAIL' || fail "5: should emit REVIEW: INFRA-FAIL on timeout"
ok
# INFRA-FAIL must be written to the result file so the watcher sees it (and retries).
[ -f "$RES" ] || fail "5: INFRA-FAIL should be written to the result file"
ok
grep -q '^REVIEW: INFRA-FAIL' "$RES" || fail "5: result file should contain REVIEW: INFRA-FAIL"
ok
# INFRA-FAIL must NOT say 'BLOCK' (it is not a verdict; watcher must not cache it).
grep -q 'BLOCK' "$RES" && fail "5: INFRA-FAIL result file must not contain BLOCK" || true
ok
# On timeout the orphaned reviewer pane must be closed so it cannot later overwrite the verdict.
grep -q 'pane close reviewPane1' "$HERDR_CALL_LOG" || fail "5: herdr pane close should be called to kill orphaned reviewer on timeout"
ok

# ── (6) re-review REUSES the builder tab: stale review·<slug> split closed, no new tab ───────
# HERD-81: a round-2 dispatch while the round-1 review·<slug> pane still occupies the builder
# tab. `herdr agent start "review·<slug>"` can't re-split under the duplicate agent name, so the
# pre-fix code fell through to `herdr tab create` — a brand-new tail tab per round (observed on
# PR #195). The fix closes the stale pane first and re-splits into the SAME builder tab, so the
# net pane count is stable across the two dispatches (close one, open one) — never a new tab.
_reset_logs
# Agent list now carries BOTH the builder AND a stale review pane left by the prior round.
printf '{"result":{"agents":[{"name":"test-slug","pane_id":"builderPane1","agent_status":"idle"},{"name":"review·test-slug","pane_id":"staleReviewPane1","agent_status":"idle"}]}}\n' \
  > "$HERDR_AGENT_LIST_RESP"
_tab_list_with_builder
_agent_start_success

AGENT_TEMP6="$T/agent-temp-6"
RES="$T/result-6-sha6"
( sleep 1; printf 'REVIEW: PASS\n' > "$AGENT_TEMP6" ) &

out="$(HERD_REVIEW_AGENT_TEMP="$AGENT_TEMP6" \
       HERD_REVIEW_RESULT_FILE="$RES" \
       HERD_REVIEW_AGENT_TIMEOUT=15 HERD_REVIEW_AGENT_POLL=1 \
       bash "$REVIEW" 6 test-slug 2>/dev/null)"
rc=$?

# The stale round-1 review pane is closed BEFORE the re-split (this is what frees the tab).
grep -q 'pane close staleReviewPane1' "$HERDR_CALL_LOG" || fail "6: stale review·<slug> pane should be closed before re-splitting"
ok
# The re-review re-splits into the SAME builder tab (reuse) …
grep -q 'split down' "$HERDR_CALL_LOG" || fail "6: re-review should re-split into the builder tab (--split down)"
ok
grep -q 'builderTab1' "$HERDR_CALL_LOG" || fail "6: re-review split should target the builder tab"
ok
# … and must NOT open a brand-new tab while the builder tab is still there.
grep -q 'tab create' "$HERDR_CALL_LOG" && fail "6: re-review must NOT open a new tab when the builder tab exists" || true
ok
# Verdict still collected, PASS.
[ "$rc" -eq 0 ] || fail "6: re-review should exit 0 on PASS (got $rc)"
ok
grep -q '^REVIEW: PASS$' "$RES" || fail "6: re-review result file should contain REVIEW: PASS"
ok

wait 2>/dev/null || true

echo "ALL PASS ($pass checks)"
