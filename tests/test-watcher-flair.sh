#!/usr/bin/env bash
# test-watcher-flair.sh — hermetic unit tests for the watcher-console FLAIR pack (HERD-147): the
# WATCHER_FLAIR=on|off lever, the merge CELEBRATION line, and the PASTURE HEADER — plus the two
# invariants the feature MUST hold:
#   • OFF (default) is byte-inert: build_celebrate/build_pasture leave CELEBRATE/PASTURE empty, so
#     render() adds nothing and the console is identical to before the feature.
#   • Flair NEVER softens a red/dead/needs-you state: a dead/attention builder keeps the LOUD C_RED
#     color + its 💀/⚠️ glyph in the pasture header, exactly as loud as its row.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1 — helpers only, no polling loop, no console,
# no network), pointing config discovery at a nonexistent file so herd-config.sh falls back to its
# generic defaults (WATCHER_FLAIR defaults off). Exercises only the pure/near-pure flair helpers.
# Run:  bash tests/test-watcher-flair.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# ── Source the watcher's helpers WITHOUT its live loop (lib mode), colors blanked (NO_COLOR) ───────
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T"          # $TREES / $FLAIR_CELEBRATE_STATE live under here
export NO_COLOR=1                  # deterministic plain output for byte-exact assertions
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _flair_enabled _flair_glyph _flair_celebration_line build_pasture build_celebrate; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
pass

# ── 1. _flair_enabled: default OFF; on|true|1|yes|enable enable it; anything else is OFF ───────────
unset WATCHER_FLAIR
_flair_enabled && fail "_flair_enabled must be OFF by default (unset)"; pass
for v in on ON true 1 yes enable enabled; do
  WATCHER_FLAIR="$v" _flair_enabled || fail "_flair_enabled should be ON for '$v'"
done; pass
for v in off "" 0 no garbage maybe; do
  WATCHER_FLAIR="$v" _flair_enabled && fail "_flair_enabled should be OFF for '$v'"
done; pass

# ── 2. _flair_celebration_line: exact plain bytes (the tracker-mandated wording) ──────────────────
got="$(_flair_celebration_line 42 3)"
[ "$got" = "  🐑 #42 joins the flock · 3 grazing" ] || fail "celebration line wrong: [$got]"; pass

# ── 3. build_pasture: OFF → byte-inert (empty); idle herd → empty even when ON ────────────────────
WATCHER_FLAIR=off; FLAIR_STATE=(grazing idle dead); PASTURE="dirty"
build_pasture
[ -z "$PASTURE" ] || fail "build_pasture must leave PASTURE empty when OFF (got [$PASTURE])"; pass
WATCHER_FLAIR=on; FLAIR_STATE=(); PASTURE="dirty"
build_pasture
[ -z "$PASTURE" ] || fail "build_pasture must be empty for an idle (0-builder) herd"; pass

# ── 4. build_pasture ON: one glyph per builder, in row order, under a 'pasture' label ─────────────
WATCHER_FLAIR=on; FLAIR_STATE=(grazing idle pen)
build_pasture
case "$PASTURE" in
  *"pasture"*"🐑"*"💤"*"✅"*) pass ;;
  *) fail "pasture header missing expected ordered glyphs: [$PASTURE]" ;;
esac
# Exactly three glyph cells for three builders (count the 🐑/💤/✅ marks present).
_ng="$(printf '%s' "$PASTURE" | grep -o -e '🐑' -e '💤' -e '✅' | grep -c . || true)"
[ "$_ng" -eq 3 ] || fail "expected 3 glyphs for 3 builders, counted $_ng"; pass

# ── 5. build_celebrate: OFF → empty AND the marker is left untouched (never even read) ────────────
WATCHER_FLAIR=off; printf '77\n' > "$FLAIR_CELEBRATE_STATE"; CELEBRATE="dirty"
build_celebrate 5
[ -z "$CELEBRATE" ] || fail "build_celebrate must be empty when OFF"; pass
[ -s "$FLAIR_CELEBRATE_STATE" ] || fail "OFF build_celebrate must not consume the marker"; pass

# ── 6. build_celebrate ON: one line per pending merged PR, then the marker is CONSUMED ────────────
WATCHER_FLAIR=on; printf '101\n102\n' > "$FLAIR_CELEBRATE_STATE"
build_celebrate 2
printf '%s' "$CELEBRATE" | grep -q '🐑 #101 joins the flock · 2 grazing' || fail "missing #101 celebration"; pass
printf '%s' "$CELEBRATE" | grep -q '🐑 #102 joins the flock · 2 grazing' || fail "missing #102 celebration"; pass
[ ! -e "$FLAIR_CELEBRATE_STATE" ] || fail "ON build_celebrate must consume (delete) the marker"; pass
# No pending merges → empty, no error.
CELEBRATE="dirty"; build_celebrate 0
[ -z "$CELEBRATE" ] || fail "build_celebrate must be empty with no pending marker"; pass

# ── 7. HARD RULE — a dead/needs-you builder keeps the LOUD C_RED color in the header (never cozy) ──
# Re-colorize with sentinel escapes so we can prove which color each glyph carries.
C_RED='<RED>'; C_YELLOW='<YEL>'; C_GREEN='<GRN>'; C_DIM='<DIM>'; C_RESET='<RST>'
case "$(_flair_glyph dead)"      in "<RED>💀<RST>")  pass ;; *) fail "dead glyph must be C_RED 💀: [$(_flair_glyph dead)]" ;; esac
case "$(_flair_glyph attention)" in "<RED>⚠️<RST>")  pass ;; *) fail "attention glyph must be C_RED ⚠️" ;; esac
case "$(_flair_glyph grazing)"   in "<GRN>🐑<RST>")  pass ;; *) fail "grazing glyph must be C_GREEN 🐑" ;; esac
case "$(_flair_glyph idle)"      in "<DIM>💤<RST>")  pass ;; *) fail "idle glyph must be C_DIM 💤" ;; esac
case "$(_flair_glyph pen)"       in "<GRN>✅<RST>")  pass ;; *) fail "pen glyph must be C_GREEN ✅" ;; esac
# And in a full header the dead builder's LOUD red glyph survives beside the cozy calm ones.
WATCHER_FLAIR=on; FLAIR_STATE=(grazing dead)
build_pasture
printf '%s' "$PASTURE" | grep -q '<RED>💀<RST>' || fail "pasture header softened the dead builder — MUST stay C_RED 💀"; pass

echo "PASS ($PASS assertions) — tests/test-watcher-flair.sh"
