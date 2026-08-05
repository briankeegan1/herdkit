#!/usr/bin/env bash
# test-red-ledger.sh — hermetic proof of the shared RED-ROW LEDGER (HERD-539, scripts/herd/red-ledger.sh).
#
# Asserted here, driving the REAL functions (AGENT_WATCH_LIB=1, fake clock):
#   (a) RED_LEDGER=off (default) — every function is a pure no-op: no file, no journal line, empty
#       reads, empty suffix. Byte-identical to before this file existed.
#   (b) note()/get() round-trip — a NEW key records first-seen=now; a REPEAT note on the SAME key
#       keeps first-seen and refreshes why + last-verified.
#   (c) suffix rendering — herd_red_ledger_row_suffix reads back a note()'d entry as " · verified Xm
#       ago"; a missing/never-noted key renders nothing.
#   (d) recheck_due — 0 (due) iff recheck-mins > 0 AND the row is at least that old; a mins=0 lever,
#       or a not-yet-elapsed row, is never due.
#   (e) clear() — removes the row and journals red_cleared key=<k> reason=<reason> exactly once;
#       returns non-zero (no journal line) when the key was already gone.
#   (f) two keys are independent — clearing one never touches the other's row.
#   (g) the ledger file is tail-trimmed at CONSOLE_LEDGER_MAX rows on write.
#
# Fully hermetic: temp dirs only, no network, no live watcher loop (AGENT_WATCH_LIB=1), fake clock.
# Run:  bash tests/test-red-ledger.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"
LIB="$REPO/scripts/herd/red-ledger.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf 'ok — %s\n' "$1"; }

[ -f "$LIB" ]   || fail "scripts/herd/red-ledger.sh not found"
[ -f "$WATCH" ] || fail "agent-watch.sh not found"

if [ -f "$REPO/scripts/herd/hermetic-env-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$REPO/scripts/herd/hermetic-env-scrub.sh"
  herd_hermetic_env_scrub "$REPO/scripts/herd/herd-config.sh"
fi

MAIN="$T/main"; TREES="$T/trees"
mkdir -p "$MAIN/.herd" "$TREES"
git -C "$MAIN" init -q -b main 2>/dev/null || true

BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

NOW=1700000000
export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=headless
export HERD_CONFIG_FILE="$T/no-such-config"
export PROJECT_ROOT="$MAIN" WORKTREES_DIR="$TREES"
export JOURNAL_FILE="$T/journal.jsonl"
export HERD_FAKE_NOW="$NOW"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in herd_red_ledger_note herd_red_ledger_get herd_red_ledger_clear herd_red_ledger_age_mins \
          herd_red_ledger_recheck_due herd_red_ledger_suffix herd_red_ledger_row_suffix; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

LEDGER="$T/red-ledger"
jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
reset_all() { rm -f "$LEDGER"; : > "$JOURNAL_FILE"; }

# ── (a) RED_LEDGER=off (default): every function is a pure no-op ────────────────────────────────────
reset_all
RED_LEDGER=off
herd_red_ledger_note "$LEDGER" "k1" main_health "app/greet.test.sh"
[ -e "$LEDGER" ] && fail "(a) RED_LEDGER=off still wrote a ledger file"
[ -z "$(herd_red_ledger_get "$LEDGER" "k1")" ] || fail "(a) RED_LEDGER=off still returned a row"
[ -z "$(herd_red_ledger_row_suffix "$LEDGER" "k1")" ] || fail "(a) RED_LEDGER=off still rendered a suffix"
herd_red_ledger_clear "$LEDGER" "k1" reverified && fail "(a) RED_LEDGER=off reported a clear"
[ "$(jcount red_cleared)" -eq 0 ] || fail "(a) RED_LEDGER=off journaled red_cleared"
ok "(a) RED_LEDGER=off (default): note/get/clear/suffix are pure no-ops, byte-identical"

# ── (b) note()/get() round-trip ──────────────────────────────────────────────────────────────────────
reset_all
RED_LEDGER=on
herd_red_ledger_note "$LEDGER" "main_health:sha1" main_health "app/greet.test.sh"
[ -s "$LEDGER" ] || fail "(b) note() with RED_LEDGER=on wrote nothing"
ROW="$(herd_red_ledger_get "$LEDGER" "main_health:sha1")"
[ -n "$ROW" ] || fail "(b) get() found nothing after note()"
CLASS="$(cut -f1 <<<"$ROW")"; WHY="$(cut -f2 <<<"$ROW")"; FS="$(cut -f3 <<<"$ROW")"; LV="$(cut -f4 <<<"$ROW")"
[ "$CLASS" = main_health ]              || fail "(b) class mismatch: $CLASS"
[ "$WHY" = "app/greet.test.sh" ]        || fail "(b) why mismatch: $WHY"
[ "$FS" = "$NOW" ]                      || fail "(b) first-seen not stamped at note time: $FS"
[ "$LV" = "$NOW" ]                      || fail "(b) last-verified not stamped at note time: $LV"
ok "(b) a NEW key records class/why/first-seen/last-verified"

# A repeat note KEEPS first-seen and REFRESHES why + last-verified.
LATER=$((NOW + 1800))
export HERD_FAKE_NOW="$LATER"
herd_red_ledger_note "$LEDGER" "main_health:sha1" main_health "app/other.test.sh"
ROW="$(herd_red_ledger_get "$LEDGER" "main_health:sha1")"
WHY="$(cut -f2 <<<"$ROW")"; FS="$(cut -f3 <<<"$ROW")"; LV="$(cut -f4 <<<"$ROW")"
[ "$WHY" = "app/other.test.sh" ] || fail "(b) repeat note did not refresh why: $WHY"
[ "$FS" = "$NOW" ]               || fail "(b) repeat note clobbered first-seen: $FS"
[ "$LV" = "$LATER" ]             || fail "(b) repeat note did not refresh last-verified: $LV"
[ "$(grep -c . "$LEDGER")" -eq 1 ] || fail "(b) repeat note duplicated the row instead of replacing it"
export HERD_FAKE_NOW="$NOW"
ok "(b) a repeat note() keeps first-seen and refreshes why + last-verified in place"

# ── (c) suffix rendering ─────────────────────────────────────────────────────────────────────────────
reset_all
herd_red_ledger_note "$LEDGER" "k1" main_health "why text" "$NOW"
export HERD_FAKE_NOW=$((NOW + 300))   # 5 minutes later
SUFFIX="$(herd_red_ledger_row_suffix "$LEDGER" "k1")"
grep -q 'verified 5m ago' <<<"$SUFFIX" || fail "(c) suffix did not read '5m ago': $SUFFIX"
export HERD_FAKE_NOW="$NOW"
[ -z "$(herd_red_ledger_row_suffix "$LEDGER" "no-such-key")" ] || fail "(c) an unnoted key rendered a suffix"
ok "(c) herd_red_ledger_row_suffix renders the note()'d last-verified age; a missing key renders nothing"

# ── (d) recheck_due cadence math ─────────────────────────────────────────────────────────────────────
herd_red_ledger_recheck_due "$NOW" 0 "$NOW" && fail "(d) mins=0 read as due"
herd_red_ledger_recheck_due "$NOW" 30 "$((NOW + 60))" && fail "(d) an under-cadence row read as due"
herd_red_ledger_recheck_due "$NOW" 30 "$((NOW + 1800))" || fail "(d) an over-cadence row did not read as due"
herd_red_ledger_recheck_due "" 30 "$NOW" && fail "(d) an empty last-verified epoch read as due"
ok "(d) herd_red_ledger_recheck_due: 0 (off) and under-cadence never due; over-cadence due"

# ── (e) clear() removes the row and journals red_cleared exactly once ──────────────────────────────────
reset_all
herd_red_ledger_note "$LEDGER" "k1" main_health "why"
herd_red_ledger_clear "$LEDGER" "k1" reverified || fail "(e) clear() on a present key returned non-zero"
[ -z "$(herd_red_ledger_get "$LEDGER" "k1")" ] || fail "(e) the row survived clear()"
[ "$(jcount '"event":"red_cleared".*"key":"k1".*"reason":"reverified"')" -eq 1 ] \
  || fail "(e) red_cleared was not journaled with the right key+reason"
herd_red_ledger_clear "$LEDGER" "k1" reverified && fail "(e) a SECOND clear on an already-clear key returned success"
[ "$(jcount red_cleared)" -eq 1 ] || fail "(e) a no-op clear journaled a duplicate red_cleared"
ok "(e) clear() removes the row, journals red_cleared once, and no-ops (no re-journal) on an already-clear key"

# ── (f) two keys are independent ────────────────────────────────────────────────────────────────────
reset_all
herd_red_ledger_note "$LEDGER" "k1" main_health "why1"
herd_red_ledger_note "$LEDGER" "k2" ref_unparsed "why2"
herd_red_ledger_clear "$LEDGER" "k1" reverified
[ -z "$(herd_red_ledger_get "$LEDGER" "k1")" ] || fail "(f) k1 survived its own clear"
[ -n "$(herd_red_ledger_get "$LEDGER" "k2")" ] || fail "(f) clearing k1 dropped k2 too"
ok "(f) clearing one key never touches another key's row"

# ── (g) ledger file is tail-trimmed at CONSOLE_LEDGER_MAX rows ─────────────────────────────────────────
reset_all
i=0
while [ "$i" -lt 30 ]; do
  herd_red_ledger_note "$LEDGER" "k$i" main_health "why $i"
  i=$((i + 1))
done
LINES="$(grep -c . "$LEDGER" 2>/dev/null || printf 0)"
[ "$LINES" -le "${CONSOLE_LEDGER_MAX:-20}" ] || fail "(g) ledger grew past CONSOLE_LEDGER_MAX: $LINES rows"
ok "(g) the ledger file is tail-trimmed at CONSOLE_LEDGER_MAX rows on write"

echo "PASS: $pass red-ledger assertions ($0)"
