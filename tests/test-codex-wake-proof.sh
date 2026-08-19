#!/usr/bin/env bash
# test-codex-wake-proof.sh — hermetic tests for HERD-789: Codex post-send wake verification.
#
# Regression target: stale-base bounces for PRs #850/#851 journaled woke=1 (working→working)
# even though their idle Codex panes showed no delivered/consumed prompt and no SHA movement.
# Root cause: _wait_agent_working's _waw_progressed accepted ANY pane cksum delta as delivery
# proof for a working→working re-task, but Codex animates a spinner continuously — the cksum
# changes every repaint even when the agent is sitting at the idle prompt doing nothing.
#
# Fix (HERD-789): when a structured lifecycle source is live (Codex stop-hook markers via
# _herd_codex_hook_lifecycle, or a durable session via _herd_codex_durable_lifecycle), a
# working→working re-task is only accepted as woke when the outer poll loop observed a
# non-working state at least once (proving the agent cycled through idle/done before picking
# up the new prompt). A cksum-only delta is rejected as unproven. For drivers without a
# structured source (non-Codex, CODEX_STOP_HOOK=off) the pre-fix cksum-delta path is
# preserved byte-identically.
#
# Tests:
#   (A) Negative control — working→working + stop-hook (same turn, spinner motion only).
#       The pane cksum changes every read (active-looking repaint) but the stop-hook
#       lifecycle never cycles through idle. Must return woke=0 (unproven, fail soft).
#   (B) Positive control — working→working + stop-hook (real lifecycle cycle).
#       The hook lifecycle transitions working→idle→working during the poll window, proving
#       the agent consumed the prompt and started a new turn. Must return woke=1.
#   (C) Byte-identical — working→working with CODEX_STOP_HOOK=off (default).
#       No structured source available; cksum delta is the only signal and is accepted
#       exactly as before HERD-789. Must return woke=1 (behavior unchanged for non-Codex).
#   (D) Done/idle→working: baseline status is "done", transition to "working". The
#       structured lifecycle guard must NOT fire (only guards working→working). woke=1.
#
# All tests source agent-watch.sh in lib mode and drive _wait_agent_working directly with
# a hermetic Codex-pane fixture (stop-hook marker files, no real Codex binary or network).
#
# Run:  bash tests/test-codex-wake-proof.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v cksum  >/dev/null 2>&1 || fail "cksum required to run this test"

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done

# herdr stub:
#   agent list — always reports the agent named STUB_AGENT_NAME with status from $STUB_STATUS_FILE.
#                The structured lifecycle (stop-hook markers) overrides this in herd_driver_agent_
#                status_resolved, so this value is only consulted when no structured source is live.
#   pane read  — returns text from $STUB_PANE_READ_TEXT. If STUB_PANE_READ_VARY=1, appends a per-call
#                frame counter (from $STUB_PANE_READ_COUNTER) so consecutive reads differ — simulating
#                an active-repainting Codex pane (spinner motion). Unset/0 → byte-identical every read.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    st="$(cat "${STUB_STATUS_FILE:-/dev/null}" 2>/dev/null || true)"; st="${st:-idle}"
    printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
      "${STUB_AGENT_NAME:-}" "$st" "${STUB_AGENT_PANE_ID:-pane-x}"
    ;;
  "pane read")
    if [ "${STUB_PANE_READ_VARY:-0}" = "1" ]; then
      _n=0
      if [ -n "${STUB_PANE_READ_COUNTER:-}" ]; then
        _n="$(cat "$STUB_PANE_READ_COUNTER" 2>/dev/null || echo 0)"
        _n=$((_n + 1)); echo "$_n" > "$STUB_PANE_READ_COUNTER"
      fi
      printf '%s (frame %s)\n' "${STUB_PANE_READ_TEXT:-}" "$_n"
    else
      printf '%s\n' "${STUB_PANE_READ_TEXT:-}"
    fi
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# Verify the HERD-789 fix is present: _wait_agent_working must exist and _waw_progressed
# must be defined inside it (the nested function is the fix site).
command -v _wait_agent_working >/dev/null 2>&1 \
  || fail "_wait_agent_working not defined — agent-watch.sh sourcing failed"

# ── Mock clock: file-backed so subshells see the same counter ─────────────────
CLOCK="$T/mock-clock"; echo 1000 > "$CLOCK"
date() {
  if [ "${1:-}" = "+%s" ]; then
    local n; n=$(( $(cat "$CLOCK" 2>/dev/null || echo 1000) + 1 ))
    echo "$n" > "$CLOCK"; printf '%s\n' "$n"
  else command date "$@"; fi
}
export -f date

# ── Lifecycle trigger: sleep mock reads a trigger file to advance hook markers ─
# When LIFECYCLE_TRIGGER_FILE contains a sequence of state words (one per line),
# sleep() pops the next state and updates the hook directory (LIFECYCLE_HOOK_DIR)
# accordingly. An empty / exhausted file → no-op (plain spinner poll).
LIFECYCLE_HOOK_DIR=""
LIFECYCLE_TRIGGER_FILE="$T/lifecycle-trigger"
: > "$LIFECYCLE_TRIGGER_FILE"
sleep() {
  if [ -s "${LIFECYCLE_TRIGGER_FILE:-}" ] && [ -n "${LIFECYCLE_HOOK_DIR:-}" ] && \
     [ -d "${LIFECYCLE_HOOK_DIR:-}" ]; then
    local _next_state
    _next_state="$(head -1 "$LIFECYCLE_TRIGGER_FILE" 2>/dev/null || true)"
    # Advance the file (remove the first line).
    { tail -n +2 "$LIFECYCLE_TRIGGER_FILE" 2>/dev/null || true; } > "$T/lc-tmp" && \
      mv "$T/lc-tmp" "$LIFECYCLE_TRIGGER_FILE" 2>/dev/null || true
    case "$_next_state" in
      working)
        touch "$LIFECYCLE_HOOK_DIR/current-turn"
        rm -f "$LIFECYCLE_HOOK_DIR/last-turn"
        ;;
      idle)
        rm -f "$LIFECYCLE_HOOK_DIR/current-turn"
        touch "$LIFECYCLE_HOOK_DIR/last-turn"
        ;;
    esac
  fi
}
export -f sleep

# ── Fixture helpers ───────────────────────────────────────────────────────────
# _setup_codex_hook <slug> <state(working|idle)> — create the stop-hook marker dir for a
# slug and put it in the requested initial state.  Also writes "codex" as the persisted
# spawn driver so _herd_codex_hook_lifecycle's driver guard passes.
_setup_codex_hook() {
  local _slug="$1" _state="$2"
  local _adir="$WORKTREES_DIR/.herd/agents/$_slug"
  mkdir -p "$_adir/hook"
  printf 'codex' > "$_adir/driver"
  rm -f "$_adir/hook/current-turn" "$_adir/hook/last-turn"
  case "$_state" in
    working) touch "$_adir/hook/current-turn" ;;
    idle)    touch "$_adir/hook/last-turn" ;;
  esac
}

# _reset_lifecycle — clear the trigger file and hook-dir pointer for the next test.
_reset_lifecycle() {
  : > "$LIFECYCLE_TRIGGER_FILE"
  LIFECYCLE_HOOK_DIR=""
}

STAT="$T/agent-status"
PANE_COUNTER="$T/pane-read-counter"
export STUB_STATUS_FILE="$STAT"
export STUB_PANE_READ_COUNTER="$PANE_COUNTER"

# Poll window: small so the mocked clock loop terminates in a handful of iterations.
HERD_REFIX_WAIT_TIMEOUT=4
export CODEX_STOP_HOOK=off   # default; individual tests set to "on"

# ── (A) NEGATIVE CONTROL: working→working + stop-hook, spinner-only (no lifecycle cycle) ─────
# The Codex pane reprints its spinner every read (cksum changes), but the stop-hook lifecycle
# stays on the same old working turn — no idle transition ever occurs. The fix must reject the
# cksum delta as unproven and return woke=0 (fail soft).
: > "$JOURNAL_FILE"; rm -f "$PANE_COUNTER"
export STUB_AGENT_NAME="wkproof-a" STUB_AGENT_PANE_ID="pane-A"
echo working > "$STAT"
CODEX_STOP_HOOK=on _setup_codex_hook "wkproof-a" "working"
export STUB_PANE_READ_TEXT="✳ Processing… (esc to interrupt)" STUB_PANE_READ_VARY=1
LIFECYCLE_HOOK_DIR="$WORKTREES_DIR/.herd/agents/wkproof-a/hook"
: > "$LIFECYCLE_TRIGGER_FILE"   # no lifecycle transitions queued
MARK_A="$(_pane_progress_mark "pane-A")"   # pre-send pane cksum (spinner baseline)
CODEX_STOP_HOOK=on _wait_agent_working "wkproof-a" "$HERD_REFIX_WAIT_TIMEOUT" "pane-A" "$MARK_A" "working"
_rc=$?
[ "$_rc" -ne 0 ] \
  || fail "A: working→working with stop-hook + spinner-only must NOT be woke (cksum delta alone is not proof)"
ok
# Confirm the cksum DID change (spinner was animating — the test would be vacuous otherwise).
_mark_a2="$(_pane_progress_mark "pane-A")"
[ "$_mark_a2" != "$MARK_A" ] \
  || fail "A: pane cksum must change between reads (spinner fixture not working — test is vacuous)"
ok
_reset_lifecycle
unset STUB_PANE_READ_TEXT STUB_PANE_READ_VARY

# ── (B) POSITIVE CONTROL: working→working + stop-hook, real lifecycle cycle ───────────────────
# The lifecycle trigger drives: working → idle (turn ended) → working (new turn started).
# The first poll sees "idle" (sets _waw_saw_nonworking=1); after one sleep the hook flips to
# working (new turn). The fix must accept this as delivery evidence and return woke=1.
: > "$JOURNAL_FILE"
export STUB_AGENT_NAME="wkproof-b" STUB_AGENT_PANE_ID="pane-B"
echo working > "$STAT"   # herdr always reports working (Codex idle-at-prompt signature)
CODEX_STOP_HOOK=on _setup_codex_hook "wkproof-b" "idle"   # hook starts at idle (turn just finished)
LIFECYCLE_HOOK_DIR="$WORKTREES_DIR/.herd/agents/wkproof-b/hook"
# After first sleep, flip to working (new turn). The outer loop will see idle on the first
# immediate check (deadline check before any sleep), so _waw_saw_nonworking=1 is already set;
# then sleep fires and the hook → working; next poll returns woke=1.
printf 'working\n' > "$LIFECYCLE_TRIGGER_FILE"   # one transition queued
MARK_B="$(printf 'baseline' | cksum)"             # non-empty placeholder baseline cksum
CODEX_STOP_HOOK=on _wait_agent_working "wkproof-b" "$HERD_REFIX_WAIT_TIMEOUT" "pane-B" "$MARK_B" "working"
_rc=$?
[ "$_rc" -eq 0 ] \
  || fail "B: working→working with stop-hook + real lifecycle cycle must be woke (lifecycle cycle is proof)"
ok
_reset_lifecycle

# ── (C) BYTE-IDENTICAL: working→working with CODEX_STOP_HOOK=off (default) ───────────────────
# No structured source available. Cksum delta (from spinner motion) is the only signal and
# must still be accepted — byte-identical to the pre-HERD-789 behavior for non-Codex drivers.
: > "$JOURNAL_FILE"; rm -f "$PANE_COUNTER"
export STUB_AGENT_NAME="wkproof-c" STUB_AGENT_PANE_ID="pane-C"
echo working > "$STAT"
export STUB_PANE_READ_TEXT="✳ Processing…" STUB_PANE_READ_VARY=1
MARK_C="$(_pane_progress_mark "pane-C")"   # baseline cksum
# CODEX_STOP_HOOK=off (the export at the top of the test); no agent dir / hook dir needed.
CODEX_STOP_HOOK=off _wait_agent_working "wkproof-c" "$HERD_REFIX_WAIT_TIMEOUT" "pane-C" "$MARK_C" "working"
_rc=$?
[ "$_rc" -eq 0 ] \
  || fail "C: working→working with CODEX_STOP_HOOK=off must be woke (cksum-delta path is byte-identical)"
ok
unset STUB_PANE_READ_TEXT STUB_PANE_READ_VARY

# ── (D) DONE/IDLE → WORKING: structured guard must NOT block the valid transition ──────────────
# The structured lifecycle guard only fires when _waw_status_before = "working". A done/idle
# → working transition must still succeed immediately (the existing fast path).
: > "$JOURNAL_FILE"; rm -f "$PANE_COUNTER"
export STUB_AGENT_NAME="wkproof-d" STUB_AGENT_PANE_ID="pane-D"
echo working > "$STAT"   # herdr reports working immediately
CODEX_STOP_HOOK=on _setup_codex_hook "wkproof-d" "working"   # stop-hook also says working
LIFECYCLE_HOOK_DIR="$WORKTREES_DIR/.herd/agents/wkproof-d/hook"
: > "$LIFECYCLE_TRIGGER_FILE"
MARK_D="$(printf 'baseline' | cksum)"   # non-empty placeholder; status_before = "done"
CODEX_STOP_HOOK=on _wait_agent_working "wkproof-d" "$HERD_REFIX_WAIT_TIMEOUT" "pane-D" "$MARK_D" "done"
_rc=$?
[ "$_rc" -eq 0 ] \
  || fail "D: done→working must be woke immediately — structured guard must not block it (got rc=$_rc)"
ok
_reset_lifecycle

# ── (E) GUARD NOT ACTIVATED WITHOUT BASELINE: no _waw_before → non-bounce legacy path ─────────
# When _waw_before is empty (the non-bounce callers that do not pass a delivery baseline),
# _waw_progressed must return 0 immediately regardless of the structured lifecycle state.
: > "$JOURNAL_FILE"
export STUB_AGENT_NAME="wkproof-e" STUB_AGENT_PANE_ID="pane-E"
echo working > "$STAT"
CODEX_STOP_HOOK=on _setup_codex_hook "wkproof-e" "working"   # stop-hook says working (same turn)
LIFECYCLE_HOOK_DIR="$WORKTREES_DIR/.herd/agents/wkproof-e/hook"
: > "$LIFECYCLE_TRIGGER_FILE"
# Empty _waw_before: the non-bounce path — must still return woke=1 immediately.
CODEX_STOP_HOOK=on _wait_agent_working "wkproof-e" "$HERD_REFIX_WAIT_TIMEOUT" "pane-E" "" ""
_rc=$?
[ "$_rc" -eq 0 ] \
  || fail "E: empty baseline (non-bounce path) must be woke regardless of structured lifecycle state"
ok
_reset_lifecycle

echo "ALL PASS ($pass checks)"
