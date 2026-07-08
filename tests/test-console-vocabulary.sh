#!/usr/bin/env bash
# test-console-vocabulary.sh — hermetic tests for the CLOSED operator-facing console vocabulary
# (HERD-172). The console is scanned by an operator hunting the ONE row that needs THEM; a bare
# "idle" row defeats that scan (no owner → whose move? no age → fresh-and-fine or forgotten-and-stuck?)
# so the word is BANNED from operator-facing rows. This suite proves the ban is a ratchet, not a
# convention, and that the replacement row carries an OWNER + an AGE:
#   (A) _row_awaiting_task renders a live spare builder as the closed-vocabulary "awaiting task ·
#       assign or retire · <age>" row — an owner (yours) + a real age — and never the word 'idle'.
#   (B) the age is honest + deterministic under HERD_FAKE_NOW (a just-freed spare vs a forgotten one).
#   (C) the row is CALM (the benign 💤 glyph, not a red needs-you/💀 alarm) — a spare is not a fault.
#   (D) CLOSED-VOCABULARY GUARD — no operator-facing DISPLAY[…] assignment in agent-watch.sh contains
#       the banned 'idle' word; the internal FLAIR_STATE enum (glyph feed, never operator text) is
#       exempt so the pasture frame stays byte-identical.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1 → helpers only, no loop). NETWORK-FREE.
# Run:  bash tests/test-console-vocabulary.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "missing $WATCH"

# ── source the SHIPPED watcher in lib mode (functions only, no re-exec / no loop / no config) ──
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

WT="$T/wt-spare"; mkdir -p "$WT"

# ── (A) closed-vocabulary row: owner + age, never 'idle' ──────────────────────────────────────────
out="$(_row_awaiting_task "spare-a" "$WT")"
printf '%s' "$out" | grep -q 'awaiting task · assign or retire' \
  || fail "(A) row missing the closed-vocabulary label, got: $out"
printf '%s' "$out" | grep -qE 'assign or retire · [0-9]+[smhd]' \
  || fail "(A) row missing an age, got: $out"
printf '%s' "$out" | grep -qw 'idle' \
  && fail "(A) row leaked the banned 'idle' word, got: $out"
printf '%s' "$out" | grep -q 'spare-a' \
  || fail "(A) row dropped the slug, got: $out"
ok

# ── (B) age is honest + deterministic under HERD_FAKE_NOW ─────────────────────────────────────────
born="$(_worktree_born "$WT")"
# A spare freed just now reads as ~0s (whose-move: mine, but nothing lost yet).
out_fresh="$(HERD_FAKE_NOW="$born" _row_awaiting_task "spare-a" "$WT")"
printf '%s' "$out_fresh" | grep -qE 'assign or retire · 0s' \
  || fail "(B) fresh spare should read 0s, got: $out_fresh"
# A spare forgotten for 1h+ reads as an hour — the operator can tell it apart at a glance and reap it.
out_old="$(HERD_FAKE_NOW="$(( born + 3700 ))" _row_awaiting_task "spare-a" "$WT")"
printf '%s' "$out_old" | grep -qE 'assign or retire · 1h' \
  || fail "(B) 1h-old spare should read 1h, got: $out_old"
# A clock that ran backwards (fake-now before birth) must never emit a negative age — floors to 0s.
out_neg="$(HERD_FAKE_NOW="$(( born - 500 ))" _row_awaiting_task "spare-a" "$WT")"
printf '%s' "$out_neg" | grep -qE 'assign or retire · 0s' \
  || fail "(B) backwards clock should floor to 0s, got: $out_neg"
ok

# ── (C) the row is CALM — the benign 💤 glyph, never a loud alarm ─────────────────────────────────
printf '%s' "$out" | grep -q '💤' \
  || fail "(C) awaiting-task row lost its calm 💤 glyph, got: $out"
printf '%s' "$out" | grep -qE 'needs.you|💀|⚠️' \
  && fail "(C) a benign spare must not render a red needs-you/dead alarm, got: $out"
ok

# ── (D) CLOSED-VOCABULARY GUARD — no operator DISPLAY row contains the banned 'idle' word ──────────
# The ratchet: every DISPLAY[…]= assignment is operator-facing text. None may say 'idle'. (FLAIR_STATE
# enum tokens are internal glyph feeds, not DISPLAY text, so they are correctly exempt from this grep.)
leaked="$(grep -nE 'DISPLAY\[[^]]*\][+]?=' "$WATCH" | grep -iw 'idle' || true)"
[ -z "$leaked" ] || fail "(D) operator-facing DISPLAY row leaked the banned 'idle' word:
$leaked"
ok

echo "ALL PASS ($pass checks)"
