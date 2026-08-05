#!/usr/bin/env bash
# test-ref-unparsed-reverify.sh — hermetic proof of HERD-539 leg 2's second red class: the 'unlinked
# merges' alarm (HERD-522) gets a standing-red REVERIFY, mirroring the MAIN_HEALTH_RECHECK_MINS
# pattern (docs/multi-seat-doctrine.md Rule 1). Before this, REF_UNPARSED_FILE had NO clear mechanism
# at all — an alarmed row stood forever, however the PR body later changed.
#
# Asserted here, driving reconcile_ref_unparsed directly (AGENT_WATCH_LIB=1, fake clock, stub gh):
#   (a) LEVERS OFF (both default: RED_LEDGER=off, RED_ROW_RECHECK_MINS=0) → byte-inert: no gh call,
#       REF_UNPARSED_FILE untouched, no ledger file.
#   (b) RED_LEDGER=on but RED_ROW_RECHECK_MINS=0 → still byte-inert (both levers required).
#   (c) cadence NOT yet elapsed → no gh call, row untouched.
#   (d) cadence elapsed, the PR body STILL has no parseable ref → the ledger's last-verified stamp
#       refreshes (one gh call), but REF_UNPARSED_FILE and the row are UNCHANGED — no re-alarm.
#   (e) cadence elapsed again, the PR body NOW parses (edited post-merge) → the row is REMOVED from
#       REF_UNPARSED_FILE, the ledger entry clears, and red_cleared key=ref_unparsed:<pr>
#       reason=reverified is journaled exactly once. build_ref_unparsed renders nothing afterward.
#
# Fully hermetic: temp dirs only, a stub `gh` (no network), no live watcher loop, fake clock.
# Run:  bash tests/test-ref-unparsed-reverify.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf 'ok — %s\n' "$1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found"

if [ -f "$REPO/scripts/herd/hermetic-env-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$REPO/scripts/herd/hermetic-env-scrub.sh"
  herd_hermetic_env_scrub "$REPO/scripts/herd/herd-config.sh"
fi

MAIN="$T/main"; TREES="$T/trees"; mkdir -p "$MAIN/.herd" "$TREES"
git -C "$MAIN" init -q -b main 2>/dev/null || true

BIN="$T/bin"; mkdir -p "$BIN"
export GH_CALLS="$T/gh-calls.log"; : > "$GH_CALLS"
export GH_BODY_FILE="$T/gh-body.txt"; : > "$GH_BODY_FILE"
cat > "$BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  [ -n "${GH_BODY_FILE:-}" ] && [ -f "$GH_BODY_FILE" ] && cat "$GH_BODY_FILE"
  exit 0
fi
exit 0
GHSTUB
chmod +x "$BIN/gh"
for cmd in git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"
gcount() { local n; n="$(grep -c "$1" "$GH_CALLS" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

NOW=1700000000
export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=headless
export HERD_CONFIG_FILE="$T/no-such-config"
export PROJECT_ROOT="$MAIN" WORKTREES_DIR="$TREES"
export JOURNAL_FILE="$T/journal.jsonl"
export HERD_FAKE_NOW="$NOW"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in reconcile_ref_unparsed build_ref_unparsed herd_pr_ref_from_body; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
reset_all() {
  : > "$JOURNAL_FILE"; : > "$GH_CALLS"
  rm -f "$RED_LEDGER_FILE"
  printf '%s\t501\t## Refs: HERD-999 (as a heading, unparsed)\n' "$NOW" > "$REF_UNPARSED_FILE"
}

RED_LEDGER=off
RED_ROW_RECHECK_MINS=0

# ── (a) LEVERS OFF (both default): byte-inert ────────────────────────────────────────────────────────
reset_all
printf 'not a ref line\n' > "$GH_BODY_FILE"
reconcile_ref_unparsed || fail "(a) reconcile_ref_unparsed returned non-zero"
[ "$(gcount 'pr view')" -eq 0 ]           || fail "(a) both levers off still called gh"
[ "$(grep -c . "$REF_UNPARSED_FILE")" -eq 1 ] || fail "(a) both levers off touched REF_UNPARSED_FILE"
[ -e "$RED_LEDGER_FILE" ] && fail "(a) both levers off wrote a ledger file"
ok "(a) RED_LEDGER=off + RED_ROW_RECHECK_MINS=0 (both default): byte-inert, no gh call"

# ── (b) RED_LEDGER=on alone (RECHECK_MINS still 0): still byte-inert ────────────────────────────────
reset_all
RED_LEDGER=on
reconcile_ref_unparsed
[ "$(gcount 'pr view')" -eq 0 ] || fail "(b) RECHECK_MINS=0 still called gh"
ok "(b) RED_LEDGER=on alone (RED_ROW_RECHECK_MINS=0) is still byte-inert — both levers are required"
RED_LEDGER=off

# ── (c) both levers on, but the cadence has NOT elapsed → no gh call ────────────────────────────────
reset_all
RED_LEDGER=on
RED_ROW_RECHECK_MINS=30
export HERD_FAKE_NOW=$((NOW + 60))     # 1 minute later — well under the 30m cadence
reconcile_ref_unparsed
[ "$(gcount 'pr view')" -eq 0 ] || fail "(c) an under-cadence row was re-probed"
export HERD_FAKE_NOW="$NOW"
ok "(c) an under-cadence row is never re-probed (rate-limited, mirrors main-health)"

# ── (d) cadence elapsed, body STILL unparsed → ledger last-verified refreshes, row UNCHANGED ─────────
export HERD_FAKE_NOW=$((NOW + 1900))   # >30m past the row's own epoch
reconcile_ref_unparsed
[ "$(gcount 'pr view')" -eq 1 ] || fail "(d) an elapsed-cadence row was not re-probed exactly once"
[ "$(grep -c . "$REF_UNPARSED_FILE")" -eq 1 ] || fail "(d) a still-unparsed body changed REF_UNPARSED_FILE's row count"
grep -q $'\t501\t' "$REF_UNPARSED_FILE" || fail "(d) the still-unparsed row for PR 501 disappeared"
[ "$(jcount red_cleared)" -eq 0 ] || fail "(d) a still-unparsed re-probe journaled a clear"
ROW="$(herd_red_ledger_get "$RED_LEDGER_FILE" "ref_unparsed:501")"
[ -n "$ROW" ] || fail "(d) the re-probe did not leave a ledger entry"
LV="$(cut -f4 <<<"$ROW")"
[ "$LV" = "$((NOW + 1900))" ] || fail "(d) the ledger's last-verified was not refreshed by the re-probe: $LV"
ok "(d) an elapsed-cadence re-probe of a STILL-unparsed body refreshes the ledger clock, never re-alarms"

# ── (e) cadence elapsed again, body NOW parses → row cleared, ledger cleared, red_cleared journaled ──
printf 'Refs: HERD-999\n' > "$GH_BODY_FILE"
export HERD_FAKE_NOW=$((NOW + 1900 + 1900))
reconcile_ref_unparsed
[ "$(gcount 'pr view')" -eq 2 ] || fail "(e) the second elapsed-cadence tick did not re-probe"
[ -s "$REF_UNPARSED_FILE" ] && fail "(e) the now-parseable PR's row survived in REF_UNPARSED_FILE"
[ -z "$(herd_red_ledger_get "$RED_LEDGER_FILE" "ref_unparsed:501")" ] || fail "(e) the ledger entry survived the clear"
[ "$(jcount '"event":"red_cleared".*"key":"ref_unparsed:501".*"reason":"reverified"')" -eq 1 ] \
  || fail "(e) red_cleared was not journaled with the right key+reason"
ROWS="$(build_ref_unparsed; printf '%s' "${REF_UNPARSED_ROWS:-}")"
[ -z "$ROWS" ] || fail "(e) the unlinked-merges section still renders after the clear: $ROWS"
ok "(e) a now-parseable body clears REF_UNPARSED_FILE + the ledger, journals red_cleared once, and the section disappears"

export HERD_FAKE_NOW="$NOW"
echo "PASS: $pass ref-unparsed-reverify assertions ($0)"
