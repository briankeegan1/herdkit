#!/usr/bin/env bash
# test-limit-menu-select.sh — hermetic tests for the CLEAN limit-menu resume via
# `herdr pane send-keys` (builders + coordinator), folded into agent-watch.sh. Verifies:
#   (1) new helpers exist after sourcing (lib mode)
#   (2) _limit_menu_keys default "Down Enter"; HERD_LIMIT_MENU_KEYS override
#   (3) _pane_shows_limit_menu: menu text present → true; menu gone → false; EMPTY read fails SAFE
#       (treated as still-present) so a blind capture never declares a false success
#   (4) _try_clean_limit_menu_select: sends the keys via `herdr pane send-keys` and returns 0 when the
#       re-read pane shows NO menu (records journal), returns 1 when the menu persists across the
#       bounded attempts; HERD_LIMIT_MENU_SELECT=off kill-switch → immediate 1, no keys sent
#   (5) _handle_limit_blocked (builder) first-sighting: clean select success records sendkeys 'cleared'
#       AND still schedules the `claude --continue` backstop (additive, never removes it); a menu that
#       persists records 'fallback' and keeps the existing scheduled backstop unchanged
#   (6) working-guard at reset: an agent already 'working' at reset resolves WITHOUT a second
#       `claude --continue` (native auto-resume won) and clears both ledgers
#   (7) no-op when no limit is detected: with no sentinel/banner the limit path is never entered, so
#       no send-keys and no sendkeys record
#   (8) coordinator watchdog: ON + limit-parked first sighting attempts the clean select and records
#       the sendkeys outcome; a 'working' coordinator clears any stale sendkeys record
#
# Sources agent-watch.sh in lib mode. Stubs herdr (agent list / pane run / pane send-keys / pane read),
# gh, git; pins the clock (HERD_NOW_EPOCH). NETWORK-FREE; launches no real claude; touches no live panes.
# Run:  bash tests/test-limit-menu-select.sh
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
#   agent list         → a single configurable agent
#   pane run           → log the COMMAND text (col 4) to STUB_PANE_RUN_LOG (the --continue backstop)
#   pane send-keys     → log "<pane> <keys…>" to STUB_SENDKEYS_LOG (the clean menu-select)
#   pane read          → echo STUB_PANE_READ_TEXT (the pane snapshot used to verify the menu is gone)
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
      "${STUB_AGENT_NAME:-}" "${STUB_AGENT_STATUS:-idle}" "${STUB_AGENT_PANE_ID:-pane-000}"
    ;;
  "pane run")
    [ -n "${STUB_PANE_RUN_LOG:-}" ] && printf '%s\n' "$4" >> "$STUB_PANE_RUN_LOG"
    ;;
  "pane send-keys")
    # args: pane(1) send-keys(2) <pane_id>(3) <key…>(4..) — log pane + all keys.
    if [ -n "${STUB_SENDKEYS_LOG:-}" ]; then shift 2; printf '%s\n' "$*" >> "$STUB_SENDKEYS_LOG"; fi
    ;;
  "pane read")
    printf '%s\n' "${STUB_PANE_READ_TEXT:-}"
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

# Override _wait_agent_working to avoid real sleeps; STUB_WAIT_FILE lines = return codes in order.
STUB_WAIT_FILE="$T/wait-codes.txt"
_wait_agent_working() {
  local _c; _c="$(head -1 "$STUB_WAIT_FILE" 2>/dev/null || true)"
  { tail -n +2 "$STUB_WAIT_FILE" 2>/dev/null || true; } > "${STUB_WAIT_FILE}.tmp"
  mv "${STUB_WAIT_FILE}.tmp" "$STUB_WAIT_FILE" 2>/dev/null || true
  return "${_c:-0}"
}

PANE_LOG="$T/pane-run.log";      export STUB_PANE_RUN_LOG="$PANE_LOG"
KEYS_LOG="$T/send-keys.log";     export STUB_SENDKEYS_LOG="$KEYS_LOG"
MENU_TEXT="1. Upgrade your plan   2. Stop and wait for limit to reset"
CLEAR_TEXT="esc to interrupt · Claude is working…"

# ── (1) New helpers defined ───────────────────────────────────────────────────
for fn in _limit_menu_keys _pane_shows_limit_menu _try_clean_limit_menu_select \
          sendkeys_state record_sendkeys clear_sendkeys; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# ── (2) key vocabulary default + override ─────────────────────────────────────
[ "$(_limit_menu_keys)" = "Down Enter" ] || fail "2: default keys must be 'Down Enter' (got '$(_limit_menu_keys)')"
ok
[ "$(HERD_LIMIT_MENU_KEYS='Down Return' _limit_menu_keys)" = "Down Return" ] || fail "2: HERD_LIMIT_MENU_KEYS must override"
ok

# ── (3) _pane_shows_limit_menu ────────────────────────────────────────────────
STUB_PANE_READ_TEXT="$MENU_TEXT" _pane_shows_limit_menu "pane-X" || fail "3: menu text present → should report menu still showing"
ok
STUB_PANE_READ_TEXT="$CLEAR_TEXT" _pane_shows_limit_menu "pane-X" && fail "3: menu-gone text → should report NO menu"
ok
STUB_PANE_READ_TEXT="" _pane_shows_limit_menu "pane-X" || fail "3: EMPTY read must FAIL SAFE (assume menu still present)"
ok

# ── (4) _try_clean_limit_menu_select ──────────────────────────────────────────
export STUB_AGENT_NAME="cs-slug" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-CS"
# 4a. Success: after keys, the pane read shows NO menu → returns 0, keys sent, journal recorded.
: > "$KEYS_LOG"; : > "$JOURNAL_FILE"
STUB_PANE_READ_TEXT="$CLEAR_TEXT" _try_clean_limit_menu_select "cs-slug" "$T/trees/cs-slug" \
  || fail "4a: clean select should return 0 when the re-read pane shows no menu"
ok
grep -qi "Down Enter" "$KEYS_LOG" || fail "4a: the menu-select keys (Down Enter) must be sent (log: $(cat "$KEYS_LOG"))"
ok
grep -q '"event":"limit_menu_selected"' "$JOURNAL_FILE" || fail "4a: a cleared select must journal limit_menu_selected"
ok
# 4b. Persist: pane read STILL shows the menu → returns 1 after the bounded attempts; keys attempted.
: > "$KEYS_LOG"; : > "$JOURNAL_FILE"
STUB_PANE_READ_TEXT="$MENU_TEXT" _try_clean_limit_menu_select "cs-slug" "$T/trees/cs-slug" \
  && fail "4b: clean select must return 1 when the menu persists"
ok
[ "$(wc -l < "$KEYS_LOG")" -ge 1 ] || fail "4b: keys must have been attempted at least once before giving up"
ok
[ "$(wc -l < "$KEYS_LOG")" -le 2 ] || fail "4b: attempts must be BOUNDED (default 2)"
ok
grep -q '"event":"limit_menu_select_failed"' "$JOURNAL_FILE" || fail "4b: a persistent menu must journal limit_menu_select_failed"
ok
# 4c. Kill-switch: HERD_LIMIT_MENU_SELECT=off → immediate 1, NO keys sent.
: > "$KEYS_LOG"
HERD_LIMIT_MENU_SELECT=off _try_clean_limit_menu_select "cs-slug" "$T/trees/cs-slug" \
  && fail "4c: kill-switch off must return 1"
ok
[ ! -s "$KEYS_LOG" ] || fail "4c: kill-switch off must send NO keys"
ok
# 4d. No pane → immediate 1, no keys (agent is 'working' so _find_builder_pane_id_any yields nothing).
: > "$KEYS_LOG"
export STUB_AGENT_STATUS="working"
STUB_PANE_READ_TEXT="$CLEAR_TEXT" _try_clean_limit_menu_select "cs-slug" "$T/trees/cs-slug" \
  && fail "4d: no resolvable pane must return 1"
ok
[ ! -s "$KEYS_LOG" ] || fail "4d: no pane must send no keys"
ok
export STUB_AGENT_STATUS="idle"

# ── (5) _handle_limit_blocked builder first-sighting: clean select + backstop still scheduled ──
export HERD_NOW_EPOCH=1000000
export STUB_AGENT_NAME="lim-ok" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-OK"
rm -f "$LIMIT_STATE" "$SENDKEYS_STATE"; : > "$KEYS_LOG"; : > "$JOURNAL_FILE"
DISPLAY=()
STUB_PANE_READ_TEXT="$CLEAR_TEXT" _handle_limit_blocked "lim-ok" "$T/trees/lim-ok" "0" "1005000"
[ "$(sendkeys_state "lim-ok")" = "cleared" ] || fail "5: a successful clean select must record sendkeys 'cleared'"
ok
grep -qi "Down Enter" "$KEYS_LOG" || fail "5: first sighting must attempt the clean menu-select"
ok
# The scheduled `claude --continue` backstop is NEVER removed — the limit ledger still says scheduled.
[ "$(limit_state "lim-ok")" = "scheduled" ] || fail "5: the scheduled backstop must remain (additive)"
ok
[ "$(limit_target_epoch "lim-ok")" = "1005060" ] || fail "5: target must still be reset+buffer=1005060"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "native auto-resume" || fail "5: cleared hold row should mention native auto-resume (got: $d)"
ok
printf '%s\n' "$d" | grep -q "needs you" && fail "5: cleared hold row must NOT be a red needs-you row (got: $d)"
ok

# 5b. Menu persists on first sighting → sendkeys 'fallback', backstop unchanged, generic hold row.
export HERD_NOW_EPOCH=1000000
export STUB_AGENT_NAME="lim-fb" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-FB"
rm -f "$LIMIT_STATE" "$SENDKEYS_STATE"; : > "$KEYS_LOG"
DISPLAY=()
STUB_PANE_READ_TEXT="$MENU_TEXT" _handle_limit_blocked "lim-fb" "$T/trees/lim-fb" "0" "1005000"
[ "$(sendkeys_state "lim-fb")" = "fallback" ] || fail "5b: a persistent menu must record sendkeys 'fallback'"
ok
[ "$(limit_state "lim-fb")" = "scheduled" ] || fail "5b: fallback must keep the scheduled backstop"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "auto-resume at" || fail "5b: fallback hold row keeps the generic 'auto-resume at' phrasing (got: $d)"
ok
# Second tick must NOT re-attempt the keys (dedup via the sendkeys ledger).
keys_before="$(wc -l < "$KEYS_LOG")"
DISPLAY=(); STUB_PANE_READ_TEXT="$MENU_TEXT" _handle_limit_blocked "lim-fb" "$T/trees/lim-fb" "0" "1005000"
[ "$(wc -l < "$KEYS_LOG")" -eq "$keys_before" ] || fail "5b: keys must be attempted AT MOST ONCE per park"
ok

# ── (6) working-guard at reset: agent already working → no second --continue, ledgers cleared ──
export HERD_NOW_EPOCH=2000000
export STUB_AGENT_NAME="lim-wk" STUB_AGENT_STATUS="working" STUB_AGENT_PANE_ID="pane-WK"
# Pre-seed a scheduled record whose target is already in the past + a 'cleared' sendkeys record.
rm -f "$LIMIT_STATE" "$SENDKEYS_STATE"; : > "$PANE_LOG"; : > "$JOURNAL_FILE"
record_limit "lim-wk" "1990000" "1990100" "scheduled"
record_sendkeys "lim-wk" "1990000" "cleared"
DISPLAY=()
STUB_PANE_READ_TEXT="$CLEAR_TEXT" _handle_limit_blocked "lim-wk" "$T/trees/lim-wk" "0" "0"
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "native auto-resume" || fail "6: an already-working agent at reset should show a native-resume resolve row (got: $d)"
ok
[ ! -s "$PANE_LOG" ] || fail "6: an already-working agent must NOT get a second claude --continue (log: $(cat "$PANE_LOG"))"
ok
[ -z "$(limit_state "lim-wk")" ] || fail "6: the limit record must be cleared once resolved"
ok
[ -z "$(sendkeys_state "lim-wk")" ] || fail "6: the sendkeys record must be cleared once resolved"
ok
grep -q '"reason":"native_or_manual"' "$JOURNAL_FILE" || fail "6: the native-resume resolve must be journaled"
ok

# ── (7) no-op when no limit is detected ───────────────────────────────────────
# _detect_limit_hit returns 1 for a clean worktree (no sentinel, no banner) → the caller never calls
# _handle_limit_blocked, so nothing is sent and no sendkeys record is written.
export HERD_TRANSCRIPT_ROOT="$T/transcripts"
WT_CLEAN="$T/trees/clean"; mkdir -p "$WT_CLEAN"
rm -f "$SENDKEYS_STATE"; : > "$KEYS_LOG"
_detect_limit_hit "clean" "$WT_CLEAN" && fail "7: a clean worktree must NOT detect a limit"
ok
[ -z "$(sendkeys_state "clean")" ] || fail "7: no limit → no sendkeys record"
ok
[ ! -s "$KEYS_LOG" ] || fail "7: no limit → no keys sent"
ok

# ── (8) coordinator watchdog: clean select on first sighting; working clears stale record ──
export COORDINATOR_WATCHDOG=on
export HERD_NOW_EPOCH=3000000
COORD="$HERD_AGENT_COORDINATOR"
# Limit-parked coordinator (sentinel present, agent not working) → first sighting attempts the select.
printf '3005000' > "$(_limit_sentinel_file "$MAIN")"
export STUB_AGENT_NAME="$COORD" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-COORD"
rm -f "$LIMIT_STATE" "$SENDKEYS_STATE"; : > "$KEYS_LOG"; : > "$JOURNAL_FILE"
STUB_PANE_READ_TEXT="$CLEAR_TEXT" _handle_coordinator_watchdog
grep -qi "Down Enter" "$KEYS_LOG" || fail "8: coordinator first sighting must attempt the clean menu-select (log: $(cat "$KEYS_LOG"))"
ok
[ "$(sendkeys_state "$COORD")" = "cleared" ] || fail "8: coordinator clean select success must record 'cleared'"
ok
grep -q '"event":"coordinator_limit_menu_selected"' "$JOURNAL_FILE" || fail "8: coordinator clean select must journal coordinator_limit_menu_selected"
ok
# A 'working' coordinator on a later tick clears the stale sendkeys record (singleton name reuse).
clear_limit "$COORD" "$MAIN"
export STUB_AGENT_STATUS="working"
_handle_coordinator_watchdog
[ -z "$(sendkeys_state "$COORD")" ] || fail "8: a working coordinator must clear the stale sendkeys record"
ok
unset COORDINATOR_WATCHDOG

echo "ALL PASS ($pass checks)"
