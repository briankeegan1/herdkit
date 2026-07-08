#!/usr/bin/env bash
# test-limit-resume.sh — hermetic tests for the usage-limit auto-resume feature:
#   (1) new helpers exist after sourcing (lib mode)
#   (2) _resume_builder: `claude --continue` in the correct worktree, wake-verify + retry-once shape
#   (3) detection: hook-sentinel path, banner-scrape fallback, clean transcript → no detection,
#       HERD_LIMIT_DETECT=off kill-switch, numeric-epoch reset passthrough
#   (4) _handle_limit_blocked scheduler: distinct (non-red) hold row before reset; at reset+buffer
#       it resumes-in-place, clears the record+sentinel on success; escalates loudly + records
#       `failed` (no re-attempt) when the agent never wakes; journals limit_detected/scheduled
#   (5) auto-refix wakes a 'done' builder by submitting the raw re-task prompt via `herdr pane run`
#       (text + Enter), NOT `claude --continue` — issue #86: the --continue command was typed into
#       the still-present TUI as literal text and never re-tasked the agent (woke=0 → escalated)
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

# 3b. Banner-scrape fallback: no sentinel, last assistant line is the real usage-limit BANNER shape.
WT_B="$T/trees/lim-b"; mkdir -p "$WT_B"
mk_transcript "$WT_B" "You have hit your usage limit - resets at 7:30pm"
r="$(_detect_limit_hit "lim-b" "$WT_B")" || fail "3b: banner in transcript should detect (return 0)"
ok

# 3c. Clean transcript, no sentinel → NOT detected.
WT_C="$T/trees/lim-c"; mkdir -p "$WT_C"
mk_transcript "$WT_C" "All done, opening a PR now."
r="$(_detect_limit_hit "lim-c" "$WT_C")" && fail "3c: clean transcript must not detect a limit"
ok

# 3c-immune (HERD-155 F4). This repo's builders BUILD limit features, so a builder's own output
# DISCUSSES usage/session limits. The banner-scrape must NOT self-trigger on such discussion — it must
# require the banner SHAPE ("limit reached" / "limit will reset at <time>"), not the bare phrase.
WT_CI="$T/trees/lim-ci"; mkdir -p "$WT_CI"
mk_transcript "$WT_CI" "I hardened the usage-limit auto-resume actuator and added session limit handling; the reset scheduler now anchors on the banner."
r="$(_detect_limit_hit "lim-ci" "$WT_CI")" && fail "3c-immune: a builder DISCUSSING usage limits must not be detected as a limit hit"
ok
# The genuine banner IS still detected (positive control for the tightened matcher).
_text_is_limit_banner "Claude usage limit reached. Your limit will reset at 3pm." || fail "3c-immune: the real banner shape must still match"
ok
_text_is_limit_banner "I added a usage limit handler to the session limit module." && fail "3c-immune: mere discussion must NOT match the banner shape"
ok

# 3d. HERD_LIMIT_DETECT=off kill-switch → never detects even with a sentinel.
HERD_LIMIT_DETECT=off _detect_limit_hit "lim-a" "$WT_A" && fail "3d: HERD_LIMIT_DETECT=off must disable detection"
ok

# 3e. _parse_reset_epoch numeric passthrough + no-time → empty.
[ "$(_parse_reset_epoch "3999999999")" = "3999999999" ] || fail "3e: numeric epoch must pass through"
ok
[ -z "$(_parse_reset_epoch "no time here at all")" ] || fail "3e: text with no time must yield empty"
ok
# 3e-anchor (HERD-155 F3). A clock time is trusted ONLY inside an anchored "reset at/in" context — a
# stray digit anywhere else (a JSON stdin blob, a token count) must NEVER be misparsed as a reset time.
export HERD_NOW_EPOCH=1000000
[ -n "$(_parse_reset_epoch "Your limit will reset at 7:30pm")" ] || fail "3e-anchor: an anchored 'reset at 7:30pm' must parse"
ok
[ -z "$(_parse_reset_epoch '{"session_id":"a1","n_tokens":8,"duration":42}')" ] || fail "3e-anchor: a JSON blob with stray digits must NOT parse a reset time"
ok
[ -z "$(_parse_reset_epoch "2 files changed, 7 insertions at line 30")" ] || fail "3e-anchor: unrelated numbers (no reset anchor) must not parse"
ok
[ -z "$(_parse_reset_epoch "your limit will reset in 5 hours")" ] || fail "3e-anchor: a bare 'reset in N hours' duration (no clock) must fall to unknown-wait (empty)"
ok
[ -n "$(_parse_reset_epoch "reset at 19:30 tonight")" ] || fail "3e-anchor: a 24h clock after the anchor must parse"
ok
unset HERD_NOW_EPOCH

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

# ── (5) auto-refix wakes a 'done' builder via a raw `herdr pane run` submit (issue #86) ──
rm -f "$REFIX_STATE"; : > "$PANE_LOG"; : > "$JOURNAL_FILE"
# Agent exists but is 'done' (not idle, not working) → _find_builder_pane_id_any finds it and the
# bounce submits the RAW re-task prompt via `herdr pane run` (text + Enter), the mechanism that
# actually wakes a done builder. It must NOT type a `claude --continue` command line (that was the
# 2026-07-02 woke=0 escalation: the command was typed into the still-present TUI as literal text).
export STUB_AGENT_NAME="fix-slug" STUB_AGENT_STATUS="done" STUB_AGENT_PANE_ID="pane-FIX"
printf '0\n' > "$STUB_WAIT_FILE"
DISPLAY=(); REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
_handle_block_verdict "70" "fix-slug" "sha-70" "0"
grep -q "review-blocked" "$PANE_LOG" || fail "5: refix on a 'done' builder must submit the 'review-blocked' fix prompt (log: $(cat "$PANE_LOG"))"
ok
grep -q -- "--continue" "$PANE_LOG" && fail "5: refix on a 'done' builder must NOT type a claude --continue command (log: $(cat "$PANE_LOG"))"
ok
refix_attempted "70" "sha-70" || fail "5: the refix bounce must still be recorded"
ok

# When the 'done' builder never wakes (both submit windows expire) → escalate (not a silent woke=0).
rm -f "$REFIX_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="fix-dead" STUB_AGENT_STATUS="done" STUB_AGENT_PANE_ID="pane-DEAD"
printf '1\n1\n' > "$STUB_WAIT_FILE"
DISPLAY=(); REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
_handle_block_verdict "71" "fix-dead" "sha-71" "0"
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "needs you · auto-refix failed" || fail "5: a submit that never wakes must escalate (got: $d)"
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

# 6-writer (HERD-155 F3): the hook COMMAND must extract the banner TEXT from a JSON stdin blob, NOT
# write the raw blob (whose stray numeric fields would misparse as a reset time). Execute the exact
# command the writer installed against realistic stdin and inspect what lands in the sentinel.
HOOK_CMD="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print([h["command"] for e in d["hooks"]["StopFailure"] if e.get("matcher")=="rate_limit" for h in e["hooks"]][0])' "$S")"
printf '%s' '{"session_id":"abc","transcript_path":"/x.jsonl","reason":"Claude usage limit reached. Your limit will reset at 7:30pm.","n_tokens":48213}' | bash -c "$HOOK_CMD"
SENT="$WT_H/.herd-limit-sentinel"
grep -q "reset at 7:30pm" "$SENT" || fail "6-writer: the sentinel must capture the reset banner text (got: $(cat "$SENT"))"
ok
grep -q "session_id" "$SENT" && fail "6-writer: the sentinel must NOT contain the raw JSON stdin blob (got: $(cat "$SENT"))"
ok
# Its extracted text round-trips through the anchored parser to a real epoch (no misparse from n_tokens=48213).
export HERD_NOW_EPOCH=1000000
[ -n "$(_parse_reset_epoch "$(cat "$SENT")")" ] || fail "6-writer: the captured banner must parse to a reset epoch"
ok
# A blob with NO limit/reset phrase → empty sentinel (still marks the hit → unknown-wait), never a stray digit.
printf '%s' '{"session_id":"9999999999","n_tokens":42,"stop_hook_active":true}' | bash -c "$HOOK_CMD"
[ ! -s "$SENT" ] || fail "6-writer: a reset-less blob must yield an EMPTY sentinel, not a numeric field (got: $(cat "$SENT"))"
ok
unset HERD_NOW_EPOCH

# ── (7) HERD-155 F4: a working builder's stale sentinel is cleared unconditionally ───────────────
# The tick's working-branch now calls clear_limit + clear_sendkeys UNCONDITIONALLY (not gated on an
# existing ledger row), so a sentinel left behind with NO ledger record can never re-trigger a false
# park on a later idle tick. Verify the clear removes a record-less sentinel and detection then fails.
WT_W="$T/trees/lim-w"; mkdir -p "$WT_W"
rm -f "$LIMIT_STATE" "$SENDKEYS_STATE"
printf '4000000000' > "$(_limit_sentinel_file "$WT_W")"
[ -z "$(limit_state "lim-w")" ] || fail "7: precondition — no ledger record for lim-w"
_detect_limit_hit "lim-w" "$WT_W" >/dev/null || fail "7: precondition — the stale sentinel is detectable before the clear"
clear_limit "lim-w" "$WT_W"; clear_sendkeys "lim-w"   # what the working-tick branch now does unconditionally
[ ! -f "$(_limit_sentinel_file "$WT_W")" ] || fail "7: a working tick must remove the stale sentinel even with no ledger record"
ok
_detect_limit_hit "lim-w" "$WT_W" && fail "7: after the clear, a later tick must NOT re-detect a phantom limit"
ok

# ── (8) HERD-155 F5: a LIMIT-PARKED post-PR builder is never typed into by the auto-refix bounce ──
# A builder that hit the usage limit AFTER opening its PR is parked at the limit menu. The review-block
# bounce must NOT `herdr pane run` the fix prompt into that menu — it must route to the park/resume
# handler instead (schedule the resume; leave refix-once unburned so the bounce fires once it is back).
rm -f "$REFIX_STATE" "$LIMIT_STATE" "$SENDKEYS_STATE"; : > "$PANE_LOG"; : > "$JOURNAL_FILE"
export HERD_NOW_EPOCH=1000000
WT_PK="$T/trees/fix-parked"; mkdir -p "$WT_PK"
printf '4000000000' > "$(_limit_sentinel_file "$WT_PK")"   # future reset → schedules a hold, no immediate resume
export STUB_AGENT_NAME="fix-parked" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-PK"
DISPLAY=(); REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
# The F5 limit guard sits at the TOP of the REVIEW_AUTOFIX block — ahead of the provenance/round
# checks — so a parked builder is diverted before any refix bookkeeping runs.
_handle_block_verdict "80" "fix-parked" "sha-80" "0" "$WT_PK"
[ ! -s "$PANE_LOG" ] || fail "8: a limit-parked builder must NOT be typed a refix prompt (log: $(cat "$PANE_LOG"))"
ok
[ "$(limit_state "fix-parked")" = "scheduled" ] || fail "8: a limit-parked builder must be routed to the scheduled resume path"
ok
refix_attempted "80" "sha-80" && fail "8: refix-once must NOT be burned while the builder is limit-parked"
ok
grep -q '"event":"refix_deferred_limit"' "$JOURNAL_FILE" || fail "8: the deferral must be journaled refix_deferred_limit"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "limit-hit" || fail "8: the row must show the limit-hold, not a refix row (got: $d)"
ok
unset HERD_NOW_EPOCH

echo "ALL PASS ($pass checks)"
