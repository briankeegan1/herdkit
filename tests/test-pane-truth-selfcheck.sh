#!/usr/bin/env bash
# test-pane-truth-selfcheck.sh — hermetic mutation-prove for HERD-619: the watch pane must never show
# false info in EITHER direction (operator directive 2026-08-10, grounded in the 4-day ghost MAIN RED
# where the pane painted a red row the live ledger no longer backed).
#
# Sources the REAL agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) — the same harness
# test-first-frame-paint.sh / test-render-pass-clock-pin.sh use — so this proof runs against the real
# functions, not a re-implementation. Three legs:
#
#   (a) _render_pass_desync_check — at the end of a render pass, recomputes each section's presence
#       bit fresh from the live ledger and compares it to what render() actually painted. A ledger row
#       written AFTER the frame snapshot but BEFORE the check (simulating another writer moving the
#       ledger mid-tick) must journal `pane_desync` naming the diverging section — and only that
#       section. Symmetric: painted-but-now-empty must fire too, not only empty-but-now-painted.
#       Agreement (no drift) must journal nothing.
#   (b) build_header — the timestamp now carries seconds, and paints a visible "stale" qualifier once
#       _LAST_PAINT_EPOCH is older than _RENDER_STALE_AGE_SECS. Never fabricated before a first paint.
#   (c) _render_pass_frame_age_journal — journals `render_pass frame_age_ms=<N>` (N >= 0) from a t0-ms
#       reading, unconditionally (ship-dormant ANOMALY_BASELINES only gates the anomaly filing, never
#       the journal line itself — matches _first_frame_paint's own observability contract).
#
# Plus the render byte-identity contract: two renders of the SAME section state a second apart differ
# ONLY in the header's seconds field, never elsewhere in the frame.
#
# Run:  bash tests/test-pane-truth-selfcheck.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
[ -f "$WATCH" ] || { echo "FAIL: missing $WATCH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

FIX="$T/fix"; mkdir -p "$FIX/trees"
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$FIX/trees"
export HERD_CONFIG_FILE="$FIX/no-such-config"
export JOURNAL_FILE="$FIX/journal.jsonl"
export TERM=dumb
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# ── (a1) DESYNC: main-red painted iff MAIN_HEALTH_STATE non-empty ─────────────────────────────────
# The frame snapshot: render() already painted an EMPTY main-red section (MAIN_HEALTH="", as
# build_main_health would leave it against an empty ledger). A writer now appends a ledger row —
# AFTER the snapshot, BEFORE the assert — exactly the race the 4-day ghost MAIN RED came from in
# reverse (there the ledger healed after the paint; here the ledger reds after an empty paint).
: > "$JOURNAL_FILE"
MAIN_HEALTH=""; TRACKER_DRIFT=""; BUILDER_NOTES_ROWS=""
printf 'deadbeef\x1f1700000000\x1flocal-fail\x1fci-fail\n' > "$MAIN_HEALTH_STATE"
_render_pass_desync_check
line="$(grep -m1 '"event":"pane_desync"' "$JOURNAL_FILE" || true)"
[ -n "$line" ] || fail "(a1) a ledger row written after the paint snapshot must journal pane_desync"
case "$line" in *'"section":"main_red"'*) : ;; *) fail "(a1) wrong section named: $line" ;; esac
case "$line" in *'"painted":0'*) : ;; *) fail "(a1) painted bit must read 0 (what render() actually showed): $line" ;; esac
case "$line" in *'"ledger":1'*) : ;; *) fail "(a1) ledger bit must read 1 (what the file holds now): $line" ;; esac
n="$(grep -c '"event":"pane_desync"' "$JOURNAL_FILE")"
[ "$n" = "1" ] || fail "(a1) exactly one pane_desync line expected, got $n"
ok

# ── (a2) DESYNC is SYMMETRIC: a row painted RED that the ledger has since cleared must fire too ────
: > "$JOURNAL_FILE"
MAIN_HEALTH="    MAIN RED — stale claim"$'\n'
: > "$MAIN_HEALTH_STATE"    # healed since the paint snapshot
_render_pass_desync_check
line="$(grep -m1 '"event":"pane_desync"' "$JOURNAL_FILE" || true)"
[ -n "$line" ] || fail "(a2) a painted row the ledger no longer backs must journal pane_desync"
case "$line" in *'"section":"main_red"'*) : ;; *) fail "(a2) wrong section named: $line" ;; esac
case "$line" in *'"painted":1'*) : ;; *) fail "(a2) painted bit must read 1: $line" ;; esac
case "$line" in *'"ledger":0'*) : ;; *) fail "(a2) ledger bit must read 0 (healed): $line" ;; esac
ok

# ── (a3) tracker-healed section named correctly ─────────────────────────────────────────────────
: > "$JOURNAL_FILE"
MAIN_HEALTH=""; TRACKER_DRIFT=""; BUILDER_NOTES_ROWS=""
: > "$MAIN_HEALTH_STATE"
printf '%s\tHERD-1\thealed\t#1\twas-red\n' "$(date +%s)" > "$TRACKER_HEAL_FILE"
_render_pass_desync_check
line="$(grep -m1 '"event":"pane_desync"' "$JOURNAL_FILE" || true)"
[ -n "$line" ] || fail "(a3) a fresh tracker-heal ledger row must journal pane_desync"
case "$line" in *'"section":"tracker_healed"'*) : ;; *) fail "(a3) wrong section named: $line" ;; esac
ok

# ── (a4) builder-notes section named correctly ──────────────────────────────────────────────────
: > "$JOURNAL_FILE"
MAIN_HEALTH=""; TRACKER_DRIFT=""; BUILDER_NOTES_ROWS=""
: > "$MAIN_HEALTH_STATE"
: > "$TRACKER_HEAL_FILE"
printf '%s\tsome-slug\ta finding\t%s\n' "$(date +%s)" "$(date +%s)" > "$BUILDER_NOTES_LEDGER"
_render_pass_desync_check
line="$(grep -m1 '"event":"pane_desync"' "$JOURNAL_FILE" || true)"
[ -n "$line" ] || fail "(a4) a fresh builder-note ledger row must journal pane_desync"
case "$line" in *'"section":"builder_notes"'*) : ;; *) fail "(a4) wrong section named: $line" ;; esac
ok

# ── (a5) AGREEMENT: painted matches ledger on every section → nothing journaled ────────────────────
: > "$JOURNAL_FILE"
: > "$MAIN_HEALTH_STATE"; : > "$TRACKER_HEAL_FILE"; : > "$BUILDER_NOTES_LEDGER"
MAIN_HEALTH=""; TRACKER_DRIFT=""; BUILDER_NOTES_ROWS=""
_render_pass_desync_check
[ ! -s "$JOURNAL_FILE" ] || fail "(a5) agreement must journal nothing, got: $(cat "$JOURNAL_FILE")"
ok

# ── (a6) never a crash: an unreadable/garbage ledger path is fail-soft ─────────────────────────────
: > "$JOURNAL_FILE"
MAIN_HEALTH_STATE="$FIX/no/such/dir/marker"
MAIN_HEALTH=""; TRACKER_DRIFT=""; BUILDER_NOTES_ROWS=""
_render_pass_desync_check
rc=$?
[ "$rc" = "0" ] || fail "(a6) _render_pass_desync_check must always return 0, got $rc"
ok
MAIN_HEALTH_STATE="$FIX/trees/.agent-watch-main-health"    # restore for the sections below

# ── (b1) header carries seconds now ─────────────────────────────────────────────────────────────
unset HERD_FAKE_NOW HERD_NOW_EPOCH 2>/dev/null || true
export HERD_FAKE_NOW=1700000000
build_header
case "$HDR_LINE" in *"$(epoch_to_hhmmss 1700000000)"*) : ;; *) fail "(b1) header must stamp HH:MM:SS: $HDR_LINE" ;; esac
ok

# ── (b2) no fabricated staleness before any paint has happened ─────────────────────────────────────
unset _LAST_PAINT_EPOCH
build_header
case "$HDR_LINE" in *stale*) fail "(b2) must never claim staleness with no prior paint recorded: $HDR_LINE" ;; esac
ok

# ── (b3) a last-paint epoch within the fresh window paints no qualifier ────────────────────────────
_LAST_PAINT_EPOCH=$(( 1700000000 - 2 ))
build_header
case "$HDR_LINE" in *stale*) fail "(b3) a fresh last-paint must not qualify as stale: $HDR_LINE" ;; esac
ok

# ── (b4) a last-paint epoch past _RENDER_STALE_AGE_SECS paints a visible qualifier ─────────────────
_LAST_PAINT_EPOCH=$(( 1700000000 - _RENDER_STALE_AGE_SECS - 500 ))
build_header
case "$HDR_LINE" in *stale*) : ;; *) fail "(b4) an old last-paint must paint the stale qualifier: $HDR_LINE" ;; esac
ok

# ── (b5) render() itself advances _LAST_PAINT_EPOCH on an actual repaint ───────────────────────────
unset _LAST_PAINT_EPOCH
HDR_LINE="H"; RULE="R"; LANDED=""; BLOCKED=""; DISPLAY=(); last_frame=""
render > /dev/null 2>&1
[ -n "${_LAST_PAINT_EPOCH:-}" ] || fail "(b5) render() must stamp _LAST_PAINT_EPOCH after a real repaint"
[ "$_LAST_PAINT_EPOCH" = "1700000000" ] || fail "(b5) _LAST_PAINT_EPOCH must read the pinned clock: $_LAST_PAINT_EPOCH"
ok
unset HERD_FAKE_NOW

# ── (c1) frame_age_ms journals unconditionally, non-negative, and feeds the anomaly rail seam ──────
: > "$JOURNAL_FILE"
t0="$(( $(_now_ms) - 250 ))"
_render_pass_frame_age_journal "$t0"
line="$(grep -m1 '"event":"render_pass"' "$JOURNAL_FILE" || true)"
[ -n "$line" ] || fail "(c1) render_pass must be journaled: $(cat "$JOURNAL_FILE")"
ms="$(printf '%s' "$line" | sed -n 's/.*"frame_age_ms":\([0-9][0-9]*\).*/\1/p')"
[ -n "$ms" ] || fail "(c1) render_pass journal line missing a numeric frame_age_ms: $line"
[ "$ms" -ge 200 ] || fail "(c1) frame_age_ms should reflect the ~250ms span, got $ms"
ok

# ── (c2) an empty/missing t0 is a silent no-op — never a fabricated measurement ────────────────────
: > "$JOURNAL_FILE"
_render_pass_frame_age_journal ""
[ ! -s "$JOURNAL_FILE" ] || fail "(c2) an empty t0 must journal nothing, got: $(cat "$JOURNAL_FILE")"
ok

# ── (3) BYTE-IDENTICAL apart from the header's seconds field ───────────────────────────────────────
# A 1s gap — well under _RENDER_STALE_AGE_SECS, so the ONLY expected difference is the seconds digits
# themselves, not the stale qualifier from (b4)/(b5) above (that is its own, separately-proven feature).
HDR_LINE=""; RULE=""; LANDED="    landed-thing"$'\n'; BLOCKED="    blocked-thing"$'\n'
MAIN_HEALTH=""; TRACKER_DRIFT=""; BUILDER_NOTES_ROWS=""; DISPLAY=(); FLAIR_STATE=()
unset _LAST_PAINT_EPOCH
export HERD_FAKE_NOW=1700000000
build_header; last_frame=""; render > "$T/frame_a.txt" 2>/dev/null
export HERD_FAKE_NOW=1700000001
build_header; last_frame=""; render > "$T/frame_b.txt" 2>/dev/null
[ -s "$T/frame_a.txt" ] && [ -s "$T/frame_b.txt" ] || fail "(3) both frames must render non-empty"
a_stripped="$(sed "s/$(epoch_to_hhmmss 1700000000)/HH:MM:SS/" "$T/frame_a.txt")"
b_stripped="$(sed "s/$(epoch_to_hhmmss 1700000001)/HH:MM:SS/" "$T/frame_b.txt")"
[ "$a_stripped" = "$b_stripped" ] || fail "(3) frames 1s apart must be byte-identical apart from the header seconds stamp"
ok
unset HERD_FAKE_NOW _LAST_PAINT_EPOCH

echo "ALL PASS ($pass checks) — pane-truth self-check (HERD-619)"
