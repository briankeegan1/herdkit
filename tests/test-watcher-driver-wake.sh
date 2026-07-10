#!/usr/bin/env bash
# test-watcher-driver-wake.sh — HERD-176 (HERD-150 P4): the watcher's resume / limit-banner /
# refix-wake / model-switch paths route through per-driver bindings.
#
# Proves:
#   (A) herd_driver_agent_resume_cmd is BYTE-IDENTICAL to the pre-P4 hardcoded
#       `claude --dangerously-skip-permissions --continue <prompt>` for herdr-claude / headless.
#   (B) a non-Claude driver (stub / codex / grok) composes ITS DRIVER_AGENT_RESUME binding — not claude.
#   (C) herd_driver_agent_limit_pattern returns the herdr-claude phrase by default; @degrade: sentinels
#       for codex/grok never match a real banner via _text_is_limit_banner.
#   (D) herd_driver_switch_model delivers DRIVER_AGENT_MODEL_SWITCH via the send-text seam.
#   (E) agent-watch wiring: _resume_builder / _text_is_limit_banner / refix wakes route through the seam
#       (no raw `claude … --continue` compose; no raw herdr pane run on the three refix rails).
#   (F) end-to-end: _resume_builder under default driver still fires `claude … --continue` in the
#       correct worktree (byte-identical wake).
#
# Fully hermetic: fake PATH, temp dirs. NO real claude/herdr/gh/network/model.
# Run:  bash tests/test-watcher-driver-wake.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPTS="$ROOT/scripts/herd"
WATCH="$SCRIPTS/agent-watch.sh"
DRIVER_SH="$SCRIPTS/driver.sh"
HC="$ROOT/templates/drivers/herdr-claude.driver"
GREP=/usr/bin/grep; command -v "$GREP" >/dev/null 2>&1 || GREP=grep

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

[ -f "$WATCH" ] && [ -f "$DRIVER_SH" ] && [ -f "$HC" ] || fail "missing required sources"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# _code_has <file> <ere> — non-comment line matches <ere>.
_code_has() { "$GREP" -qE "$2" < <(awk '{ s=$0; sub(/^[ \t]+/,"",s); if (s !~ /^#/) print }' "$1"); }

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# (A) resume compose — byte-identical for herdr-claude
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# shellcheck source=/dev/null
. "$DRIVER_SH" || fail "sourcing driver.sh failed"

got="$(herd_driver_agent_resume_cmd "continue")"
# shlex.quote leaves barewords unquoted when safe: claude --dangerously-skip-permissions --continue continue
want="claude --dangerously-skip-permissions --continue continue"
[ "$got" = "$want" ] || fail "(A) default resume cmd not byte-identical:
  got:  $got
  want: $want"
pass

got="$(herd_driver_agent_resume_cmd "please fix the review")"
printf '%s' "$got" | "$GREP" -qF "claude --dangerously-skip-permissions --continue" \
  || fail "(A2) multi-word resume missing claude shape: $got"
printf '%s' "$got" | "$GREP" -qE "please fix the review|'please fix the review'" \
  || fail "(A2) multi-word prompt not carried: $got"
pass

# Explicit flags override the permission token.
got="$(herd_driver_agent_resume_cmd "continue" "--dangerously-skip-permissions --verbose")"
printf '%s' "$got" | "$GREP" -qF -- "--verbose" || fail "(A3) flags override not applied: $got"
printf '%s' "$got" | "$GREP" -qF -- "--continue" || fail "(A3) --continue dropped: $got"
pass

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# (B) foreign-runtime resume routing
# ══════════════════════════════════════════════════════════════════════════════════════════════════
for pair in "stub:stub-agent" "codex:codex" "grok:grok"; do
  drv="${pair%%:*}"; bin="${pair#*:}"
  got="$(herd_driver_agent_resume_cmd "continue" "" "$drv")"
  printf '%s' "$got" | "$GREP" -qE "^${bin}( |$)" \
    || fail "(B) $drv resume must start with $bin (got: $got)"
  printf '%s' "$got" | "$GREP" -qF "claude" \
    && fail "(B) $drv resume must NOT invoke claude (got: $got)"
done
pass

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# (C) limit pattern
# ══════════════════════════════════════════════════════════════════════════════════════════════════
pat="$(herd_driver_agent_limit_pattern)"
[ "$pat" = 'usage limit|session limit|hit your (usage|session) limit' ] \
  || fail "(C) default limit pattern drifted: $pat"
# Binding on disk is the source of truth.
exact="$(awk -F= '$1=="DRIVER_AGENT_LIMIT_PATTERN"{sub(/^[^=]+=/,""); gsub(/^'\''|'\''$/,""); print}' "$HC")"
[ "$pat" = "$exact" ] || fail "(C) helper output != herdr-claude.driver binding ($pat vs $exact)"
pass

# codex/grok degrade sentinels
for drv in codex grok; do
  p="$(herd_driver_agent_limit_pattern "$drv")"
  case "$p" in @degrade:*) : ;; *) fail "(C) $drv limit pattern should be @degrade:… (got: $p)" ;; esac
done
pass

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# (D) model-switch via send-text
# ══════════════════════════════════════════════════════════════════════════════════════════════════
BIN="$T/bin"; mkdir -p "$BIN"
PANE_LOG="$T/pane-run.log"; SEND_LOG="$T/send-keys.log"
: > "$PANE_LOG"; : > "$SEND_LOG"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pane run")
    [ -n "${STUB_PANE_RUN_LOG:-}" ] && printf '%s\n' "$4" >> "$STUB_PANE_RUN_LOG" ;;
  "pane send-keys")
    [ -n "${STUB_SENDKEYS_LOG:-}" ] && printf '%s %s\n' "$3" "$*" >> "$STUB_SENDKEYS_LOG" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH" STUB_PANE_RUN_LOG="$PANE_LOG" STUB_SENDKEYS_LOG="$SEND_LOG"
# Force herdr-claude mux path (not headless queue).
export HERD_DRIVER=herdr-claude
: > "$PANE_LOG"; : > "$SEND_LOG"
herd_driver_switch_model "pane-MS" "claude-opus-4-8"
grep -qxF '/model claude-opus-4-8' "$PANE_LOG" \
  || fail "(D) switch-model must type '/model <model>' (log: $(cat "$PANE_LOG"))"
grep -qE 'Enter' "$SEND_LOG" \
  || fail "(D) switch-model must submit via send-keys Enter (log: $(cat "$SEND_LOG"))"
pass

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# (E) agent-watch wiring (source-level ratchet)
# ══════════════════════════════════════════════════════════════════════════════════════════════════
_code_has "$WATCH" 'herd_driver_agent_resume_cmd' \
  || fail "(E) agent-watch.sh does not call herd_driver_agent_resume_cmd"
_code_has "$WATCH" 'herd_driver_agent_limit_pattern' \
  || fail "(E) agent-watch.sh does not call herd_driver_agent_limit_pattern"
# The three refix rails must all use the send-text seam (not raw herdr pane run of the re-task prompt).
for needle in '_handle_block_verdict' '_handle_stale_dup' '_handle_health_codeerror'; do
  : # names for humans; the real check is the three call counts of send_text vs raw pane run below
done
n_send="$("$GREP" -cE 'herd_driver_send_text' "$WATCH" || true)"
[ "$n_send" -ge 6 ] || fail "(E) expected >=6 herd_driver_send_text call sites on the three refix rails (got $n_send)"
# No live COMPOSE of `claude … --continue` remains (notification prose mentioning the phrase is fine
# and stays baselined in the hardcode lint). The pre-P4 compose was `_rb_cmd=… && claude … --continue`.
if awk '{ s=$0; sub(/^[ \t]+/,"",s); if (s !~ /^#/ && s ~ /_rb_cmd=.*claude/ ) print }' "$WATCH" | grep -q .; then
  fail "(E) agent-watch.sh still composes resume via a raw _rb_cmd=…claude line"
fi
if awk '{ s=$0; sub(/^[ \t]+/,"",s); if (s !~ /^#/ && s ~ /&& claude /) print }' "$WATCH" | grep -q .; then
  fail "(E) agent-watch.sh still has a live '&& claude ' resume compose"
fi
# Raw `herdr pane run` of a re-task prompt on the stale/health rails is gone (resume still uses
# pane run for the shell relaunch — that is intentional and not a re-task wake).
! _code_has "$WATCH" 'herdr pane run "\$_hsd_pane_id"' \
  || fail "(E) stale refix still uses raw herdr pane run"
! _code_has "$WATCH" 'herdr pane run "\$_hhc_pane_id"' \
  || fail "(E) health refix still uses raw herdr pane run"
pass

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# (F) _resume_builder end-to-end under default driver
# ══════════════════════════════════════════════════════════════════════════════════════════════════
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

STUB_WAIT_FILE="$T/wait-codes.txt"
_wait_agent_working() {
  local _c; _c="$(head -1 "$STUB_WAIT_FILE" 2>/dev/null || true)"
  { tail -n +2 "$STUB_WAIT_FILE" 2>/dev/null || true; } > "${STUB_WAIT_FILE}.tmp"
  mv "${STUB_WAIT_FILE}.tmp" "$STUB_WAIT_FILE" 2>/dev/null || true
  return "${_c:-0}"
}
# menu probe → never confirmed (empty read)
_pane_menu_confirmed() { return 1; }

: > "$PANE_LOG"; printf '0\n' > "$STUB_WAIT_FILE"
export STUB_AGENT_NAME="wake-f" STUB_AGENT_STATUS="done" STUB_AGENT_PANE_ID="pane-F"
WT="$T/trees/wake-f"; mkdir -p "$WT"
_resume_builder "wake-f" "$WT" "pane-F" || fail "(F) _resume_builder should return 0 when agent wakes"
cmd="$(head -1 "$PANE_LOG")"
printf '%s\n' "$cmd" | "$GREP" -q -- "--continue" || fail "(F) resume must use --continue (got: $cmd)"
printf '%s\n' "$cmd" | "$GREP" -q "claude" || fail "(F) default resume must invoke claude (got: $cmd)"
printf '%s\n' "$cmd" | "$GREP" -q "$WT" || fail "(F) resume must cd into the worktree (got: $cmd)"
printf '%s\n' "$cmd" | "$GREP" -q -- "--dangerously-skip-permissions" \
  || fail "(F) default permission flag missing (got: $cmd)"
pass

# Foreign driver through the REAL _resume_builder path.
export HERD_DRIVER=stub
: > "$PANE_LOG"; printf '0\n' > "$STUB_WAIT_FILE"
_resume_builder "wake-f" "$WT" "pane-F" "go on" || fail "(F2) stub resume should wake"
cmd="$(head -1 "$PANE_LOG")"
printf '%s\n' "$cmd" | "$GREP" -q "stub-agent" || fail "(F2) stub resume must invoke stub-agent (got: $cmd)"
printf '%s\n' "$cmd" | "$GREP" -q "claude" && fail "(F2) stub resume must NOT invoke claude (got: $cmd)"
printf '%s\n' "$cmd" | "$GREP" -q "go on" || fail "(F2) custom prompt not carried (got: $cmd)"
pass

# Limit banner under default driver still matches the real banner; discussion does not.
export HERD_DRIVER=herdr-claude
_text_is_limit_banner "Claude usage limit reached. Your limit will reset at 3pm." \
  || fail "(F3) real banner must still match under routed pattern"
_text_is_limit_banner "I added a usage limit handler to the session limit module." \
  && fail "(F3) discussion must still NOT match"
# codex degrade: never match even a real-looking banner.
export HERD_DRIVER=codex
_text_is_limit_banner "Claude usage limit reached. Your limit will reset at 3pm." \
  && fail "(F3) codex @degrade pattern must never match a banner"
pass

echo "ALL PASS ($PASS checks)"
