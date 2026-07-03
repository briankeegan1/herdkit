#!/usr/bin/env bash
# test-limit-resume.sh — hermetic tests for the usage-limit auto-resume feature:
#   (1) new helpers exist after sourcing (lib mode)
#   (2) _resume_builder: `claude --continue` in the correct worktree, wake-verify + retry-once shape
#   (3) detection: hook-sentinel path, banner-scrape fallback, clean transcript → no detection,
#       HERD_LIMIT_DETECT=off kill-switch, numeric-epoch reset passthrough
#   (4) _handle_limit_blocked scheduler: distinct (non-red) hold row before reset; at reset+buffer
#       it resumes-in-place, clears the record+sentinel on success; escalates loudly + records
#       `failed` (no re-attempt) when the agent never wakes; journals limit_detected/scheduled
#   (5) auto-refix REUSES _resume_builder when the target builder session is 'done' (idle-only
#       pane lookup misses it) — the 2026-07-02 woke=0 escalation is now a --continue resume
#   (6) herd_write_ratelimit_hook writes a merge-safe, idempotent StopFailure/rate_limit hook
#
# Sources agent-watch.sh in lib mode. Stubs herdr/gh/git and pins the clock (HERD_NOW_EPOCH).
# NETWORK-FREE, launches no real claude, touches no live watcher/panes/processes.
# Run:  bash tests/test-limit-resume.sh
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
# herdr stub: agent list returns a configurable agent; pane run logs the FULL command text.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
      "${STUB_AGENT_NAME:-}" "${STUB_AGENT_STATUS:-idle}" "${STUB_AGENT_PANE_ID:-pane-000}"
    ;;
  "pane run")
    # args: pane(1) run(2) <pane_id>(3) <command-text>(4) — log the COMMAND so shape is assertable.
    [ -n "${STUB_PANE_RUN_LOG:-}" ] && printf '%s\n' "$4" >> "$STUB_PANE_RUN_LOG"
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

# Verify new helpers are defined.
for fn in _resume_builder _find_builder_pane_id_any _detect_limit_hit _parse_reset_epoch \
          _handle_limit_blocked limit_state limit_target_epoch record_limit clear_limit \
          _now _shq _transcript_last_assistant_text herd_write_ratelimit_hook; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

render() { :; }   # no-op: tests don't need terminal output

# Override _wait_agent_working to avoid real sleeps; STUB_WAIT_FILE lines = return codes in order.
STUB_WAIT_FILE="$T/wait-codes.txt"
_wait_agent_working() {
  local _c; _c="$(head -1 "$STUB_WAIT_FILE" 2>/dev/null || true)"
  { tail -n +2 "$STUB_WAIT_FILE" 2>/dev/null || true; } > "${STUB_WAIT_FILE}.tmp"
  mv "${STUB_WAIT_FILE}.tmp" "$STUB_WAIT_FILE" 2>/dev/null || true
  return "${_c:-0}"
}

PANE_LOG="$T/pane-run.log"
export STUB_PANE_RUN_LOG="$PANE_LOG"

# ── (2) _resume_builder: claude --continue in the correct worktree, wake + retry ─
: > "$PANE_LOG"
printf '0\n' > "$STUB_WAIT_FILE"                     # wakes on first poll
export STUB_AGENT_NAME="rb-slug" STUB_AGENT_STATUS="done" STUB_AGENT_PANE_ID="pane-RB"
_resume_builder "rb-slug" "$T/trees/rb-slug" "pane-RB" || fail "_resume_builder should return 0 when agent wakes"
ok
[ "$(wc -l < "$PANE_LOG")" -eq 1 ] || fail "_resume_builder wake-first: pane run should fire once (got $(wc -l < "$PANE_LOG"))"
ok
cmd="$(head -1 "$PANE_LOG")"
printf '%s\n' "$cmd" | grep -q -- "--continue" || fail "_resume_builder: command must use claude --continue (got: $cmd)"
ok
printf '%s\n' "$cmd" | grep -q "$T/trees/rb-slug" || fail "_resume_builder: command must cd into the correct worktree (got: $cmd)"
ok
printf '%s\n' "$cmd" | grep -q "claude" || fail "_resume_builder: command must invoke claude (got: $cmd)"
ok

# Never wakes → returns 1, pane run twice (initial + retry).
: > "$PANE_LOG"; printf '1\n1\n' > "$STUB_WAIT_FILE"
_resume_builder "rb-slug" "$T/trees/rb-slug" "pane-RB" && fail "_resume_builder should return 1 when agent never wakes"
ok
[ "$(wc -l < "$PANE_LOG")" -eq 2 ] || fail "_resume_builder never-wakes: pane run should fire twice (got $(wc -l < "$PANE_LOG"))"
ok
# Empty pane_id → immediate failure, no pane run.
: > "$PANE_LOG"
_resume_builder "rb-slug" "$T/trees/rb-slug" "" && fail "_resume_builder must fail on empty pane_id"
ok
[ ! -s "$PANE_LOG" ] || fail "_resume_builder empty-pane: must not call pane run"
ok

# A custom prompt is passed through to --continue.
: > "$PANE_LOG"; printf '0\n' > "$STUB_WAIT_FILE"
_resume_builder "rb-slug" "$T/trees/rb-slug" "pane-RB" "please fix the review" >/dev/null
grep -q "please fix the review" "$PANE_LOG" || fail "_resume_builder: custom prompt must reach the --continue command"
ok

# ── (3) Detection ────────────────────────────────────────────────────────────
export HERD_TRANSCRIPT_ROOT="$T/transcripts"
mk_transcript() {  # <worktree> <last-assistant-text>
  local wt="$1" text="$2" munged d
  munged="$(printf '%s' "$wt" | tr '/.' '-')"
  d="$HERD_TRANSCRIPT_ROOT/$munged"; mkdir -p "$d"
  python3 - "$d/session.jsonl" "$text" <<'PY'
import sys, json
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(json.dumps({"type": "user", "message": {"content": "go"}}) + "\n")
    f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": sys.argv[2]}]}}) + "\n")
PY
}

# 3a. Hook sentinel present (numeric epoch) → detected, reset echoed verbatim.
WT_A="$T/trees/lim-a"; mkdir -p "$WT_A"
printf '4000000000' > "$(_limit_sentinel_file "$WT_A")"
r="$(_detect_limit_hit "lim-a" "$WT_A")" || fail "3a: sentinel present should detect (return 0)"
[ "$r" = "4000000000" ] || fail "3a: numeric-epoch reset should pass through (got '$r')"
ok

# 3b. Banner-scrape fallback: no sentinel, last assistant line is the usage-limit banner.
WT_B="$T/trees/lim-b"; mkdir -p "$WT_B"
mk_transcript "$WT_B" "You have hit your usage limit - resets 7:30pm"
r="$(_detect_limit_hit "lim-b" "$WT_B")" || fail "3b: banner in transcript should detect (return 0)"
ok

# 3c. Clean transcript, no sentinel → NOT detected.
WT_C="$T/trees/lim-c"; mkdir -p "$WT_C"
mk_transcript "$WT_C" "All done, opening a PR now."
r="$(_detect_limit_hit "lim-c" "$WT_C")" && fail "3c: clean transcript must not detect a limit"
ok

# 3d. HERD_LIMIT_DETECT=off kill-switch → never detects even with a sentinel.
HERD_LIMIT_DETECT=off _detect_limit_hit "lim-a" "$WT_A" && fail "3d: HERD_LIMIT_DETECT=off must disable detection"
ok

# 3e. _parse_reset_epoch numeric passthrough + no-time → empty.
[ "$(_parse_reset_epoch "3999999999")" = "3999999999" ] || fail "3e: numeric epoch must pass through"
ok
[ -z "$(_parse_reset_epoch "no time here at all")" ] || fail "3e: text with no time must yield empty"
ok

# ── (4) Scheduler _handle_limit_blocked ──────────────────────────────────────
rm -f "$LIMIT_STATE" "$JOURNAL_FILE"
export HERD_NOW_EPOCH=1000000
# First sighting with a future reset → records scheduled, shows a distinct NON-RED hold row.
DISPLAY=()
_handle_limit_blocked "sched-x" "$T/trees/sched-x" "0" "1005000"   # target = 1005000 + 60 buffer
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "auto-resume at" || fail "4: waiting row should say 'auto-resume at' (got: $d)"
ok
printf '%s\n' "$d" | grep -q "needs you" && fail "4: waiting row must NOT be a red 'needs you' row (got: $d)"
ok
[ "$(limit_state "sched-x")" = "scheduled" ] || fail "4: state should be 'scheduled'"
ok
[ "$(limit_target_epoch "sched-x")" = "1005060" ] || fail "4: target should be reset+buffer=1005060 (got $(limit_target_epoch sched-x))"
ok
grep -q '"event":"limit_detected"' "$JOURNAL_FILE" || fail "4: limit_detected must be journaled"
ok
grep -q '"event":"limit_resume_scheduled"' "$JOURNAL_FILE" || fail "4: limit_resume_scheduled must be journaled"
ok

# Advance past the target → resume succeeds, record + sentinel cleared, green resumed row.
WT_S="$T/trees/sched-x"; mkdir -p "$WT_S"
printf '4000000000' > "$(_limit_sentinel_file "$WT_S")"
export HERD_NOW_EPOCH=1006000
export STUB_AGENT_NAME="sched-x" STUB_AGENT_STATUS="done" STUB_AGENT_PANE_ID="pane-SX"
printf '0\n' > "$STUB_WAIT_FILE"; : > "$PANE_LOG"; : > "$JOURNAL_FILE"
DISPLAY=()
_handle_limit_blocked "sched-x" "$WT_S" "0" "0"
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "resumed via --continue" || fail "4: past-reset success row should say 'resumed via --continue' (got: $d)"
ok
grep -q -- "--continue" "$PANE_LOG" || fail "4: resume must run claude --continue"
ok
grep -q "$WT_S" "$PANE_LOG" || fail "4: resume must target the correct worktree"
ok
[ -z "$(limit_state "sched-x")" ] || fail "4: record must be cleared after a successful resume"
ok
[ ! -f "$(_limit_sentinel_file "$WT_S")" ] || fail "4: sentinel must be removed after a successful resume"
ok
grep -q '"event":"limit_resume_result"' "$JOURNAL_FILE" || fail "4: limit_resume_result must be journaled"
ok
grep -q '"woke":1' "$JOURNAL_FILE" || fail "4: successful resume must journal woke:1"
ok

# Escalation: agent never wakes → state 'failed', loud needs-you row, no re-attempt on the next tick.
rm -f "$LIMIT_STATE"; : > "$PANE_LOG"
export HERD_NOW_EPOCH=2000000
export STUB_AGENT_NAME="esc-y" STUB_AGENT_STATUS="done" STUB_AGENT_PANE_ID="pane-EY"
printf '1\n1\n' > "$STUB_WAIT_FILE"
DISPLAY=()
_handle_limit_blocked "esc-y" "$T/trees/esc-y" "0" "1000"   # target 1060 << now → resume immediately
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "needs you · limit-resume failed" || fail "4: failed resume must escalate 'needs you · limit-resume failed' (got: $d)"
ok
[ "$(limit_state "esc-y")" = "failed" ] || fail "4: state should be 'failed' after a failed resume"
ok
calls_before="$(wc -l < "$PANE_LOG")"
DISPLAY=(); printf '0\n' > "$STUB_WAIT_FILE"
_handle_limit_blocked "esc-y" "$T/trees/esc-y" "0" "1000"   # next tick: state=failed → no re-attempt
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "needs you · limit-resume failed" || fail "4: failed state must keep showing needs-you (got: $d)"
ok
[ "$(wc -l < "$PANE_LOG")" -eq "$calls_before" ] || fail "4: a failed record must NOT re-attempt resume every tick"
ok

# ── (5) auto-refix reuses _resume_builder when the builder session is 'done' ──
rm -f "$REFIX_STATE"; : > "$PANE_LOG"; : > "$JOURNAL_FILE"
# Agent exists but is 'done' (not idle, not working) → _find_builder_pane_id (idle-only) misses it,
# _find_builder_pane_id_any finds it → resume-in-place with the refix prompt.
export STUB_AGENT_NAME="fix-slug" STUB_AGENT_STATUS="done" STUB_AGENT_PANE_ID="pane-FIX"
printf '0\n' > "$STUB_WAIT_FILE"
DISPLAY=(); REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
_handle_block_verdict "70" "fix-slug" "sha-70" "0"
grep -q -- "--continue" "$PANE_LOG" || fail "5: refix on a 'done' builder must resume via claude --continue (log: $(cat "$PANE_LOG"))"
ok
grep -q "review-blocked" "$PANE_LOG" || fail "5: refix resume must carry the 'review-blocked' fix prompt"
ok
grep -q "$WORKTREES_DIR/fix-slug" "$PANE_LOG" || fail "5: refix resume must cd into the builder's worktree"
ok
refix_attempted "70" "sha-70" || fail "5: the refix bounce must still be recorded"
ok

# When the 'done' builder's resume never wakes → escalate (not a silent woke=0).
rm -f "$REFIX_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="fix-dead" STUB_AGENT_STATUS="done" STUB_AGENT_PANE_ID="pane-DEAD"
printf '1\n1\n' > "$STUB_WAIT_FILE"
DISPLAY=(); REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
_handle_block_verdict "71" "fix-dead" "sha-71" "0"
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "needs you · auto-refix failed" || fail "5: a resume that never wakes must escalate (got: $d)"
ok

# ── (6) herd_write_ratelimit_hook: merge-safe + idempotent ───────────────────
WT_H="$T/wt-hook"; mkdir -p "$WT_H"
# Pre-existing settings with an unrelated key that MUST survive the merge.
mkdir -p "$WT_H/.claude"
printf '{"model":"opus","permissions":{"allow":["Bash"]}}\n' > "$WT_H/.claude/settings.json"
herd_write_ratelimit_hook "$WT_H"
S="$WT_H/.claude/settings.json"
[ -f "$S" ] || fail "6: settings.json must be written"
ok
python3 - "$S" <<'PY' || fail "6: hook JSON malformed or missing StopFailure/rate_limit"
import sys, json
d = json.load(open(sys.argv[1]))
assert d.get("model") == "opus", "unrelated key clobbered"
assert d["permissions"]["allow"] == ["Bash"], "unrelated permissions clobbered"
sf = d["hooks"]["StopFailure"]
assert any(e.get("matcher") == "rate_limit" for e in sf), "no rate_limit matcher"
cmd = [h["command"] for e in sf if e.get("matcher") == "rate_limit" for h in e["hooks"]][0]
assert ".herd-limit-sentinel" in cmd, "sentinel path not in hook command"
PY
ok
# Idempotent: a second call must not duplicate the matcher.
herd_write_ratelimit_hook "$WT_H"
n="$(python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); print(sum(1 for e in d["hooks"]["StopFailure"] if e.get("matcher")=="rate_limit"))' "$S")"
[ "$n" -eq 1 ] || fail "6: rate_limit matcher must not be duplicated on re-run (got $n)"
ok
# HERD_LIMIT_HOOK=off is a no-op on a fresh worktree.
WT_OFF="$T/wt-off"; mkdir -p "$WT_OFF"
HERD_LIMIT_HOOK=off herd_write_ratelimit_hook "$WT_OFF"
[ ! -f "$WT_OFF/.claude/settings.json" ] || fail "6: HERD_LIMIT_HOOK=off must not write a hook"
ok

echo "ALL PASS ($pass checks)"
