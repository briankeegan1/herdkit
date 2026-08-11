#!/usr/bin/env bash
# test-spawn-wake-verify.sh — hermetic tests for HERD-516 / issue #632: post-spawn wake verification.
#
# Regression target: herd_driver_start_agent / herd_driver_launch_agent return 0 as soon as the
# `herdr agent start` / `herdr agent start`-via-launch CALL succeeds — nothing verifies the agent ever
# transitions to "working", so a swallowed kickoff prompt is a silent stall (real incident: money-bets
# 2026-08-04, ~40 minutes lost, recovered only by a manual send-keys Enter). herd_spawn_wake_verify
# (scripts/herd/driver.sh) closes that gap: poll on a backed-off cadence, retry once with a bare Enter,
# retry once more by re-sending the pointer prompt, then escalate loudly without killing the builder.
#
# These tests drive the REAL herd_spawn_wake_verify against a herdr stub, with only `date +%s`/`sleep`
# mocked (so no wall-clock time passes) and a small HERD_SPAWN_WAKE_WINDOW test seam (shrinks the
# backed-off poll window so the mocked-clock loop terminates in a handful of iterations). Asserts:
#   (a) an agent already "working" on the first poll → woke=1, retried=none, no Enter/text ever sent.
#   (b) an agent that only wakes after the bare-Enter retry → woke=1, retried=enter, exactly one
#       send-keys Enter, the pointer text NEVER re-sent via pane run.
#   (c) an agent that never wakes → both retries fire (Enter, then pane run + Enter for the pointer),
#       woke=0, the loud escalation warning prints, and the function still returns 0 (never blocks the
#       spawn / never "kills" anything).
#
# Sources driver.sh directly in lib mode (no herd-config.sh — driver.sh's own documented contract).
# Stubs herdr/gh/git. NETWORK-FREE, launches no real claude.
# Run:  bash tests/test-spawn-wake-verify.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/../scripts/herd/driver.sh"
JOURNAL_SRC="$HERE/../scripts/herd/journal.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$DRIVER" ] || fail "driver.sh not found at $DRIVER"
[ -f "$JOURNAL_SRC" ] || fail "journal.sh not found at $JOURNAL_SRC"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done

# herdr stub:
#   agent list     — reports STUB_AGENT_NAME with agent_status read from $STUB_STATUS_FILE (default idle).
#   pane run       — logs the submitted pointer TEXT ($4) to $STUB_PANE_RUN_LOG/CALLS (the prompt-resend retry).
#   pane send-keys — logs pane+keys to $STUB_SENDKEYS_LOG; when keys include Enter AND
#                    STUB_WAKE_ON_ENTER=1, flips $STUB_STATUS_FILE to "working" (models a kickoff that
#                    was sitting unsubmitted in the TUI buffer — the bare-Enter retry wakes it).
#   pane read      — HERD-647: serves $STUB_PANE_READ_TEXT (the pane's visible content, independent of
#                    $STUB_STATUS_FILE — models herdr's own status word staying stuck 'idle' while the
#                    pane keeps rendering). STUB_PANE_READ_VARY=1 appends a per-call frame counter
#                    (tracked in $STUB_PANE_READ_COUNTER) so consecutive reads DIFFER — a repainting
#                    pane; unset/0 serves byte-identical text every call — a FROZEN pane (the
#                    genuinely-dead signature: the process crashed mid-paint and nothing repaints it).
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    st="$(cat "${STUB_STATUS_FILE:-/dev/null}" 2>/dev/null || true)"; st="${st:-idle}"
    printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
      "${STUB_AGENT_NAME:-}" "$st" "${STUB_AGENT_PANE_ID:-pane-x}"
    ;;
  "pane run")
    # args: pane(1) run(2) <pane_id>(3) <text>(4).
    [ -n "${STUB_PANE_RUN_CALLS:-}" ] && printf '%s\n' "$3" >> "$STUB_PANE_RUN_CALLS"
    [ -n "${STUB_PANE_RUN_LOG:-}" ]   && printf '%s\n' "$4" >> "$STUB_PANE_RUN_LOG"
    ;;
  "pane send-keys")
    # args: pane(1) send-keys(2) <pane_id>(3) <key…>(4..).
    _sk_pane="${3:-}"; shift 3 || true
    _sk_keys="$*"
    [ -n "${STUB_SENDKEYS_LOG:-}" ] && printf '%s %s\n' "$_sk_pane" "$_sk_keys" >> "$STUB_SENDKEYS_LOG"
    case " ${_sk_keys} " in
      *" Enter "*)
        if [ "${STUB_WAKE_ON_ENTER:-0}" = "1" ] && [ -n "${STUB_STATUS_FILE:-}" ]; then
          echo working > "$STUB_STATUS_FILE"
        fi
        ;;
    esac
    ;;
  "pane read")
    if [ "${STUB_PANE_READ_VARY:-0}" = "1" ]; then
      _pr_n=0
      if [ -n "${STUB_PANE_READ_COUNTER:-}" ]; then
        _pr_n="$(cat "$STUB_PANE_READ_COUNTER" 2>/dev/null || echo 0)"; _pr_n=$((_pr_n + 1))
        echo "$_pr_n" > "$STUB_PANE_READ_COUNTER"
      fi
      printf '%s (frame %s)\n' "${STUB_PANE_READ_TEXT:-}" "$_pr_n"
    else
      printf '%s\n' "${STUB_PANE_READ_TEXT:-}"
    fi
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source driver.sh (lib mode: not executed, WORKTREES_DIR unneeded for this seam) + journal.sh ──
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export JOURNAL_FILE="$T/journal.jsonl"
# shellcheck source=/dev/null
. "$JOURNAL_SRC" || fail "sourcing journal.sh failed"
# shellcheck source=/dev/null
. "$DRIVER" || fail "sourcing driver.sh (lib mode) failed"

# Mock the clock so the REAL backed-off _herd_spawn_wait_working loop terminates without real time.
# File-backed counter (date is called inside command substitutions → subshells; a shell var would
# increment in the child and be lost).
CLOCK="$T/mock-clock"; echo 1000 > "$CLOCK"
date() {
  if [ "${1:-}" = "+%s" ]; then
    local n; n=$(( $(cat "$CLOCK" 2>/dev/null || echo 1000) + 1 )); echo "$n" > "$CLOCK"; printf '%s\n' "$n"
  else command date "$@"; fi
}
sleep() { :; }   # no real sleeping — the mocked clock drives loop termination
export -f date sleep
# Test seam only (undocumented in templates/capabilities.tsv — same class as HERD_JOURNAL_NOW /
# JOURNAL_MAX_BYTES): shrink the poll window so the mocked-clock loop needs only a few iterations.
export HERD_SPAWN_WAKE_WINDOW=4

PANE_LOG="$T/pane-run.log"; PANE_CALLS="$T/pane-run.calls"; SENDKEYS_LOG="$T/send-keys.log"
STAT="$T/agent-status"
export STUB_PANE_RUN_LOG="$PANE_LOG" STUB_PANE_RUN_CALLS="$PANE_CALLS" STUB_SENDKEYS_LOG="$SENDKEYS_LOG" \
       STUB_STATUS_FILE="$STAT"

POINTER="Read your task spec and build exactly what it specifies."

# ── (a) already working on the first poll → woke=1, retried=none, no retry sends at all ──────────
: > "$PANE_LOG"; : > "$PANE_CALLS"; : > "$SENDKEYS_LOG"; : > "$JOURNAL_FILE"
export STUB_AGENT_NAME="wake-a" STUB_AGENT_PANE_ID="pane-A" STUB_WAKE_ON_ENTER=0
echo working > "$STAT"
herd_spawn_wake_verify "wake-a" "pane-A" "$POINTER"
[ "$?" -eq 0 ] || fail "A: herd_spawn_wake_verify must return 0 on a woken agent"
ok
[ ! -s "$SENDKEYS_LOG" ] || fail "A: no Enter should ever be sent when the agent is already working (log: $(cat "$SENDKEYS_LOG"))"
ok
[ ! -s "$PANE_CALLS" ] || fail "A: the pointer must never be re-sent when the agent is already working (log: $(cat "$PANE_CALLS"))"
ok
wl="$(grep 'spawn_wake_result' "$JOURNAL_FILE" | tail -1)"
grep -q '"woke":1' <<< "$wl" || fail "A: spawn_wake_result must record woke=1 (got: $wl)"
ok
grep -q '"retried":"none"' <<< "$wl" || fail "A: spawn_wake_result must record retried=none (got: $wl)"
ok

# ── (b) wakes only after the bare-Enter retry → woke=1, retried=enter, prompt never re-sent ────────
: > "$PANE_LOG"; : > "$PANE_CALLS"; : > "$SENDKEYS_LOG"; : > "$JOURNAL_FILE"
export STUB_AGENT_NAME="wake-b" STUB_AGENT_PANE_ID="pane-B" STUB_WAKE_ON_ENTER=1
echo idle > "$STAT"
herd_spawn_wake_verify "wake-b" "pane-B" "$POINTER"
[ "$?" -eq 0 ] || fail "B: herd_spawn_wake_verify must return 0 on a woken agent"
ok
[ "$(grep -cE 'Enter' "$SENDKEYS_LOG" || true)" -eq 1 ] \
  || fail "B: exactly one send-keys Enter for the bare-Enter retry (log: $(cat "$SENDKEYS_LOG"))"
ok
[ ! -s "$PANE_CALLS" ] || fail "B: a wake on the Enter retry must never re-send the pointer prompt (log: $(cat "$PANE_CALLS"))"
ok
wl="$(grep 'spawn_wake_result' "$JOURNAL_FILE" | tail -1)"
grep -q '"woke":1' <<< "$wl" || fail "B: spawn_wake_result must record woke=1 (got: $wl)"
ok
grep -q '"retried":"enter"' <<< "$wl" || fail "B: spawn_wake_result must record retried=enter (got: $wl)"
ok

# ── (c) never wakes → both retries fire, woke=0, loud escalation, still returns 0 (never blocks) ───
: > "$PANE_LOG"; : > "$PANE_CALLS"; : > "$SENDKEYS_LOG"; : > "$JOURNAL_FILE"
export STUB_AGENT_NAME="wake-c" STUB_AGENT_PANE_ID="pane-C" STUB_WAKE_ON_ENTER=0
echo idle > "$STAT"   # never flips to working
warn_out="$(herd_spawn_wake_verify "wake-c" "pane-C" "$POINTER" 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || fail "C: a never-woken agent must still return 0 (never blocks the spawn), got rc=$rc"
ok
[ "$(grep -cE 'Enter' "$SENDKEYS_LOG" || true)" -ge 2 ] \
  || fail "C: both the bare-Enter retry AND the resend's own Enter must fire (log: $(cat "$SENDKEYS_LOG"))"
ok
[ "$(wc -l < "$PANE_CALLS")" -eq 1 ] \
  || fail "C: the pointer prompt must be re-sent exactly once via pane run (got $(wc -l < "$PANE_CALLS"))"
ok
grep -q "Read your task spec" "$PANE_LOG" \
  || fail "C: the resend must carry the ORIGINAL pointer prompt (log: $(cat "$PANE_LOG"))"
ok
wl="$(grep 'spawn_wake_result' "$JOURNAL_FILE" | tail -1)"
grep -q '"woke":0' <<< "$wl" || fail "C: spawn_wake_result must record woke=0 (got: $wl)"
ok
grep -q '"retried":"prompt"' <<< "$wl" || fail "C: spawn_wake_result must record retried=prompt (got: $wl)"
ok
grep -qi "never picked up its kickoff prompt" <<< "$warn_out" \
  || fail "C: a final failure must print a LOUD warning with the manual-recovery hint (got: $warn_out)"
ok
grep -q "send-keys pane-C Enter" <<< "$warn_out" \
  || fail "C: the loud warning must include the manual recovery one-liner (got: $warn_out)"
ok

# ── HERD_SPAWN_WAKE_VERIFY=off is a clean, total no-op kill switch ─────────────────────────────────
: > "$PANE_LOG"; : > "$PANE_CALLS"; : > "$SENDKEYS_LOG"; : > "$JOURNAL_FILE"
export STUB_AGENT_NAME="wake-d" STUB_AGENT_PANE_ID="pane-D" STUB_WAKE_ON_ENTER=0
echo idle > "$STAT"
HERD_SPAWN_WAKE_VERIFY=off herd_spawn_wake_verify "wake-d" "pane-D" "$POINTER"
[ "$?" -eq 0 ] || fail "kill-switch: must still return 0"
ok
[ ! -s "$SENDKEYS_LOG" ] && [ ! -s "$PANE_CALLS" ] && [ ! -s "$JOURNAL_FILE" ] \
  || fail "kill-switch: HERD_SPAWN_WAKE_VERIFY=off must skip verification entirely (no sends, no journal)"
ok

# ── HERD-647: STATUS CORROBORATION ─────────────────────────────────────────────────────────────────
# Replays the grounded 2026-08-11 incident: herdr's OWN agent_status word never leaves "idle" (the
# stub's $STAT file is never flipped — models the #632 nudge path herdr's state machine seemingly
# never observes), but the pane keeps rendering the live-activity chrome (spinner glyph + "esc to
# interrupt") with fresh content every read. The shared resolver must corroborate this into "working"
# WITHOUT ever needing the Enter/prompt retry ladder, and must journal status_disagreement recording
# exactly what it overrode.
# ── (e) idle status word + active, REPAINTING pane → corroborated working, retried=none ───────────
: > "$PANE_LOG"; : > "$PANE_CALLS"; : > "$SENDKEYS_LOG"; : > "$JOURNAL_FILE"
export STUB_AGENT_NAME="wake-e" STUB_AGENT_PANE_ID="pane-E" STUB_WAKE_ON_ENTER=0
echo idle > "$STAT"   # herdr's own status word never flips — the whole point of this fixture
export STUB_PANE_READ_TEXT="✳ Cogitating… (esc to interrupt)" STUB_PANE_READ_VARY=1
STUB_PANE_READ_COUNTER="$T/pane-read-counter-e"; rm -f "$STUB_PANE_READ_COUNTER"; export STUB_PANE_READ_COUNTER
herd_spawn_wake_verify "wake-e" "pane-E" "$POINTER"
[ "$?" -eq 0 ] || fail "E: herd_spawn_wake_verify must return 0"
ok
wl="$(grep 'spawn_wake_result' "$JOURNAL_FILE" | tail -1)"
grep -q '"woke":1' <<< "$wl" || fail "E: a corroborated agent must report woke=1 (got: $wl)"
ok
grep -q '"retried":"none"' <<< "$wl" \
  || fail "E: corroboration must resolve inside the FIRST poll window, no Enter/prompt retry needed (got: $wl)"
ok
[ ! -s "$SENDKEYS_LOG" ] || fail "E: a corroborated-working agent must never be sent Enter (log: $(cat "$SENDKEYS_LOG"))"
ok
[ ! -s "$PANE_CALLS" ] || fail "E: a corroborated-working agent must never have its pointer re-sent (log: $(cat "$PANE_CALLS"))"
ok
dl="$(grep 'status_disagreement' "$JOURNAL_FILE" | tail -1)"
[ -n "$dl" ] || fail "E: status_disagreement must be journaled when corroboration overrides idle (journal: $(cat "$JOURNAL_FILE"))"
ok
grep -q '"slug":"wake-e"' <<< "$dl" || fail "E: status_disagreement must carry the slug (got: $dl)"
ok
grep -q '"agent_status":"idle"' <<< "$dl" || fail "E: status_disagreement must record the raw idle status (got: $dl)"
ok
grep -q '"resolved":"working"' <<< "$dl" || fail "E: status_disagreement must record the resolved status (got: $dl)"
ok

# ── (f) GUARDRAIL — active-LOOKING but FROZEN pane (no delta) must still classify idle ─────────────
# This is the genuinely-dead signature: a process that crashed mid-paint leaves the spinner/interrupt
# chrome sitting in the pane forever, with nothing ever repainting it. Corroboration must NOT rescue
# it — never weaken dead/wedge detection — so it runs the full retry ladder exactly like case (c) and
# ends woke=0, with no status_disagreement ever journaled.
: > "$PANE_LOG"; : > "$PANE_CALLS"; : > "$SENDKEYS_LOG"; : > "$JOURNAL_FILE"
export STUB_AGENT_NAME="wake-f" STUB_AGENT_PANE_ID="pane-F" STUB_WAKE_ON_ENTER=0
echo idle > "$STAT"
export STUB_PANE_READ_TEXT="✳ Cogitating… (esc to interrupt)" STUB_PANE_READ_VARY=0   # frozen: byte-identical every read
herd_spawn_wake_verify "wake-f" "pane-F" "$POINTER" >/dev/null 2>&1
[ "$?" -eq 0 ] || fail "F: a never-woken agent must still return 0"
ok
wl="$(grep 'spawn_wake_result' "$JOURNAL_FILE" | tail -1)"
grep -q '"woke":0' <<< "$wl" \
  || fail "F: a frozen active-looking pane with no content delta must NOT be rescued — dead-builder guardrail (got: $wl)"
ok
[ -z "$(grep 'status_disagreement' "$JOURNAL_FILE" || true)" ] \
  || fail "F: status_disagreement must never fire without a genuine content delta (journal: $(cat "$JOURNAL_FILE"))"
ok

# ── (g) a genuinely-idle pane (no spinner chrome at all) is unchanged, even if its content churns ──
# Proves the active-signal gate matters independently of delta: a static idle prompt box that merely
# reflows (cursor blink, timestamp) must never be misread as work.
: > "$PANE_LOG"; : > "$PANE_CALLS"; : > "$SENDKEYS_LOG"; : > "$JOURNAL_FILE"
export STUB_AGENT_NAME="wake-g" STUB_AGENT_PANE_ID="pane-G" STUB_WAKE_ON_ENTER=0
echo idle > "$STAT"
export STUB_PANE_READ_TEXT="> " STUB_PANE_READ_VARY=1
STUB_PANE_READ_COUNTER="$T/pane-read-counter-g"; rm -f "$STUB_PANE_READ_COUNTER"; export STUB_PANE_READ_COUNTER
herd_spawn_wake_verify "wake-g" "pane-G" "$POINTER" >/dev/null 2>&1
wl="$(grep 'spawn_wake_result' "$JOURNAL_FILE" | tail -1)"
grep -q '"woke":0' <<< "$wl" \
  || fail "G: a static idle prompt (no spinner chrome) must never be rescued even if content churns (got: $wl)"
ok
[ -z "$(grep 'status_disagreement' "$JOURNAL_FILE" || true)" ] \
  || fail "G: status_disagreement must never fire over a genuinely idle pane (journal: $(cat "$JOURNAL_FILE"))"
ok

# ── (h) HERD_STATUS_CORROBORATE=off disables the rescue, same fixture as (e) ────────────────────────
: > "$PANE_LOG"; : > "$PANE_CALLS"; : > "$SENDKEYS_LOG"; : > "$JOURNAL_FILE"
export STUB_AGENT_NAME="wake-h" STUB_AGENT_PANE_ID="pane-H" STUB_WAKE_ON_ENTER=0
echo idle > "$STAT"
export STUB_PANE_READ_TEXT="✳ Cogitating… (esc to interrupt)" STUB_PANE_READ_VARY=1
STUB_PANE_READ_COUNTER="$T/pane-read-counter-h"; rm -f "$STUB_PANE_READ_COUNTER"; export STUB_PANE_READ_COUNTER
HERD_STATUS_CORROBORATE=off herd_spawn_wake_verify "wake-h" "pane-H" "$POINTER" >/dev/null 2>&1
wl="$(grep 'spawn_wake_result' "$JOURNAL_FILE" | tail -1)"
grep -q '"woke":0' <<< "$wl" || fail "H: HERD_STATUS_CORROBORATE=off must disable corroboration (got: $wl)"
ok
unset STUB_PANE_READ_TEXT STUB_PANE_READ_VARY STUB_PANE_READ_COUNTER

echo "ALL PASS ($pass checks)"
