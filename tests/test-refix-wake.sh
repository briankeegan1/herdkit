#!/usr/bin/env bash
# test-refix-wake.sh — hermetic tests for the issue-#86 auto-refix WAKE fix.
#
# Regression target: when a review returned BLOCK, the auto-refix bounce could not wake a builder
# whose agent read 'done' — the old path reserved 'done' builders for a `claude --continue` relaunch,
# but that command line was typed into the still-present Claude TUI as literal prompt text and never
# re-tasked the agent (journal: 'auto-refix wake woke=0 escalated=true (done → done)'). A manual
# `herdr pane run <pane> <text>` (command text + Enter) wakes the same agent instantly.
#
# These tests drive the REAL _handle_block_verdict + the REAL backed-off _wait_agent_working (only
# `date +%s`/`sleep` are mocked so no wall-clock time passes) against a herdr stub whose `pane run`
# actually flips the stubbed agent from 'done' → 'working' — modelling the real wake — and assert:
#   (A) a 'done' builder is woken by a RAW-prompt `herdr pane run` submit (not `claude --continue`);
#       the agent transitions done→working and the bounce records woke=1 / escalated=false.
#   (B) the backed-off poll catches a wake that arrives a few checks after the submit (single submit).
#   (C) a submit that never wakes exhausts both backed-off windows → re-sent once, then escalates.
#
# Sources agent-watch.sh in lib mode. Stubs herdr/gh/git. NETWORK-FREE, launches no real claude.
# Run:  bash tests/test-refix-wake.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done

# herdr stub:
#   agent list — reports the agent named STUB_AGENT_NAME with a status read from $STUB_STATUS_FILE
#                (default "done"). If STUB_WAKE_COUNTDOWN_FILE holds N>0, force "done" and decrement
#                (a wake that arrives only after N status checks — exercises the backed-off poll).
#   pane run   — logs the submitted COMMAND TEXT ($4) to $STUB_PANE_RUN_LOG; when STUB_WAKE_ON_RUN=1
#                it flips $STUB_STATUS_FILE to "working" (the submit woke the agent).
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    st="$(cat "${STUB_STATUS_FILE:-/dev/null}" 2>/dev/null || true)"; st="${st:-done}"
    if [ -n "${STUB_WAKE_COUNTDOWN_FILE:-}" ] && [ -f "$STUB_WAKE_COUNTDOWN_FILE" ]; then
      n="$(cat "$STUB_WAKE_COUNTDOWN_FILE" 2>/dev/null || echo 0)"
      if [ "${n:-0}" -gt 0 ]; then st="done"; echo "$((n-1))" > "$STUB_WAKE_COUNTDOWN_FILE"; else st="working"; fi
    fi
    printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
      "${STUB_AGENT_NAME:-}" "$st" "${STUB_AGENT_PANE_ID:-pane-x}"
    ;;
  "pane run")
    # args: pane(1) run(2) <pane_id>(3) <command-text>(4). Log the pane_id (single line) to the
    # CALLS file for exact per-invocation counting — the command text ($4) is MULTI-LINE, so it is
    # logged separately (for content greps) and must never be line-counted.
    [ -n "${STUB_PANE_RUN_CALLS:-}" ] && printf '%s\n' "$3" >> "$STUB_PANE_RUN_CALLS"
    [ -n "${STUB_PANE_RUN_LOG:-}" ]   && printf '%s\n' "$4" >> "$STUB_PANE_RUN_LOG"
    [ "${STUB_WAKE_ON_RUN:-0}" = "1" ] && [ -n "${STUB_STATUS_FILE:-}" ] && echo working > "$STUB_STATUS_FILE"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

render() { :; }   # no-op: tests don't need terminal output

# Mock the clock so the REAL backed-off _wait_agent_working loop terminates without real time.
# Only `date +%s` is intercepted; every other date format (journal timestamps, epoch_to_hhmm)
# delegates to the real binary. The counter is FILE-backed on purpose: agent-watch calls `date +%s`
# inside command substitutions ($(date +%s)), which run in subshells — a shell var would be
# incremented in the child and lost, so the clock would never advance and the loop would spin.
CLOCK="$T/mock-clock"; echo 1000 > "$CLOCK"
date() {
  if [ "${1:-}" = "+%s" ]; then
    local n; n=$(( $(cat "$CLOCK" 2>/dev/null || echo 1000) + 1 )); echo "$n" > "$CLOCK"; printf '%s\n' "$n"
  else command date "$@"; fi
}
sleep() { :; }   # no real sleeping — the mocked clock drives loop termination
# Keep windows short: with the mocked clock, the window value ≈ number of poll iterations.
export HERD_REFIX_WAIT_TIMEOUT=6

PANE_LOG="$T/pane-run.log"          # command text ($4) — multi-line; for content greps only
PANE_CALLS="$T/pane-run.calls"      # pane_id ($3) — one line per invocation; for exact counts
STAT="$T/agent-status"
export STUB_PANE_RUN_LOG="$PANE_LOG" STUB_PANE_RUN_CALLS="$PANE_CALLS" STUB_STATUS_FILE="$STAT"

REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3

# ── (A) a 'done' builder is woken by a raw-prompt herdr pane run submit ───────
rm -f "$REFIX_STATE"; : > "$PANE_LOG"; : > "$PANE_CALLS"; : > "$JOURNAL_FILE"
unset STUB_WAKE_COUNTDOWN_FILE
export STUB_AGENT_NAME="wake-a" STUB_AGENT_PANE_ID="pane-A" STUB_WAKE_ON_RUN=1
echo done > "$STAT"                       # builder session reads 'done'
DISPLAY=()
_handle_block_verdict "80" "wake-a" "sha-80" "0"

[ "$(wc -l < "$PANE_CALLS")" -eq 1 ] \
  || fail "A: a done builder woken on first submit → exactly one pane run (got $(wc -l < "$PANE_CALLS"))"
ok
grep -q "review-blocked" "$PANE_LOG" \
  || fail "A: the submit must carry the raw 'review-blocked' re-task prompt (log: $(cat "$PANE_LOG"))"
ok
grep -q -- "--continue" "$PANE_LOG" \
  && fail "A: a done builder must be woken by a raw pane run submit, NOT a claude --continue command"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "refixing" \
  || fail "A: display should show 'refixing', not an escalation (got: $d)"
ok
printf '%s\n' "$d" | grep -q "auto-refix failed" \
  && fail "A: a woken builder must NOT escalate to 'auto-refix failed' (got: $d)"
ok
refix_attempted "80" "sha-80" || fail "A: the refix bounce must be recorded"
ok
# The wake result must journal woke=1 / escalated=false and the done→working transition.
wl="$(grep 'refix_wake_result' "$JOURNAL_FILE" | tail -1)"
printf '%s\n' "$wl" | grep -q '"woke":1' \
  || fail "A: refix_wake_result must record woke=1 (got: $wl)"
ok
printf '%s\n' "$wl" | grep -q '"escalated":"false"' \
  || fail "A: refix_wake_result must record escalated=false (got: $wl)"
ok
printf '%s\n' "$wl" | grep -q '"agent_status_before":"done"' \
  && printf '%s\n' "$wl" | grep -q '"agent_status_after":"working"' \
  || fail "A: refix_wake_result must record the done→working transition (got: $wl)"
ok

# ── (B) the backed-off poll catches a wake that arrives a few checks later ────
rm -f "$REFIX_STATE"; : > "$PANE_LOG"; : > "$PANE_CALLS"; : > "$JOURNAL_FILE"
export STUB_AGENT_NAME="wake-b" STUB_AGENT_PANE_ID="pane-B" STUB_WAKE_ON_RUN=0
echo done > "$STAT"
CD="$T/countdown-b"; echo 4 > "$CD"       # 'done' for the first 4 status reads, then 'working'
export STUB_WAKE_COUNTDOWN_FILE="$CD"
DISPLAY=()
_handle_block_verdict "81" "wake-b" "sha-81" "0"
[ "$(wc -l < "$PANE_CALLS")" -eq 1 ] \
  || fail "B: a wake caught within the first backed-off window → a single submit, no re-send (got $(wc -l < "$PANE_CALLS"))"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "refixing" \
  || fail "B: a delayed-but-successful wake should show 'refixing' (got: $d)"
ok
grep 'refix_wake_result' "$JOURNAL_FILE" | tail -1 | grep -q '"woke":1' \
  || fail "B: a delayed wake must still record woke=1"
ok
unset STUB_WAKE_COUNTDOWN_FILE

# ── (C) a submit that never wakes → re-sent once, then escalates ──────────────
rm -f "$REFIX_STATE"; : > "$PANE_LOG"; : > "$PANE_CALLS"; : > "$JOURNAL_FILE"
export STUB_AGENT_NAME="wake-c" STUB_AGENT_PANE_ID="pane-C" STUB_WAKE_ON_RUN=0
echo done > "$STAT"                        # never flips to working
DISPLAY=()
_handle_block_verdict "82" "wake-c" "sha-82" "0"
[ "$(wc -l < "$PANE_CALLS")" -eq 2 ] \
  || fail "C: a never-waking submit must be re-sent exactly once (got $(wc -l < "$PANE_CALLS"))"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "needs you · auto-refix failed" \
  || fail "C: a submit that never wakes must escalate to 'needs you · auto-refix failed' (got: $d)"
ok
grep 'refix_wake_result' "$JOURNAL_FILE" | tail -1 | grep -q '"woke":0' \
  || fail "C: a failed wake must record woke=0"
ok
grep 'refix_wake_result' "$JOURNAL_FILE" | tail -1 | grep -q '"escalated":"true"' \
  || fail "C: a failed wake must record escalated=true"
ok

echo "ALL PASS ($pass checks)"
