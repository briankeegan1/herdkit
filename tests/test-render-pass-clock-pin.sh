#!/usr/bin/env bash
# test-render-pass-clock-pin.sh — hermetic mutation-prove for HERD-491: pin HERD_FAKE_NOW across every
# render-pass age reader (one shared now() helper), closing the test-clock race class where two rows
# built a fork apart in the same tick could read different wall-clock seconds under load (see
# test-console-truth-pass.sh's own COUNT 4 / case 4a comment, which pins the clock in ITS fixture but
# never in production).
#
# Extracts the real _now_epoch / _now / _render_pass_clock_begin / _render_pass_clock_end /
# build_spawn_holds (+ its small render helpers) from agent-watch.sh — no full source, no gh/herdr/
# config bootstrap needed — then stubs `date` with an ADVANCING fake clock (a fresh, higher second on
# every `date +%s` call): an exaggerated stand-in for forked-subprocess clock drift under load. Proves:
#
#   (1) _now_epoch and _now are now ONE shared seam: HERD_FAKE_NOW pins both, and HERD_NOW_EPOCH (the
#       older, _now()-only seam a dozen other tests already pin) still works standalone, unchanged.
#   (2) _render_pass_clock_begin/_end pin the advancing clock for their bracket — every read inside
#       returns the IDENTICAL instant — and release it cleanly after (a later read resumes advancing).
#   (3) A NESTED pin (an outer HERD_FAKE_NOW already set, mirroring a full-tick hermetic test like
#       test-console-rows-ageout.sh) is preserved exactly across begin/end — never overwritten, never
#       leaked on release.
#   (4) A REAL render-pass reader, build_spawn_holds (HERD-491 also fixed its raw `date +%s` bypass),
#       renders BYTE-DIFFERENT rows across two unpinned calls under the advancing clock (the race
#       reproduced) and BYTE-IDENTICAL rows across two calls inside one pin bracket (the race closed).
#
# Run:  bash tests/test-render-pass-clock-pin.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
[ -f "$WATCH" ] || { echo "FAIL: agent-watch.sh not found" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── Extract the real functions under test ───────────────────────────────────────────────────────────
# Handles BOTH function shapes in this file: single-line (`fn() { ...; }`) and multi-line (`fn() {`
# … `}`) definitions, so the extraction never silently over- or under-captures.
extract_fn() {
  local fn="$1" oneline
  oneline="$(grep -m1 -E "^${fn}\(\) \{.*\}[[:space:]]*\$" "$WATCH" || true)"
  if [ -n "$oneline" ]; then
    printf '%s\n' "$oneline"
  else
    sed -n "/^${fn}() {/,/^}/p" "$WATCH"
  fi
}

SRC="$T/extracted.sh"; : > "$SRC"
for fn in _now_epoch _now _render_pass_clock_begin _render_pass_clock_end \
          _slug_ref_file _slug_ref _slug_cell _fmt_age build_spawn_holds; do
  body="$(extract_fn "$fn")"
  [ -n "$body" ] || fail "could not extract $fn from agent-watch.sh"
  printf '%s\n' "$body" >> "$SRC"
done
# shellcheck source=/dev/null
. "$SRC" || fail "sourcing the extracted functions failed"

# ── Fake ADVANCING clock: every `date +%s` call returns a NEW, higher second — an exaggerated stand-in
# for the real wall clock ticking over between forked subshells under load. This shadows the real
# date(1) for every unqualified `date` call made from the sourced functions above (bash resolves
# functions before PATH), while `command date` (used below to compute expectations) still hits the
# real binary.
TICK_FILE="$T/date-tick"; printf '0' > "$TICK_FILE"
BASE_EPOCH=1700000000
date() {
  if [ "${1:-}" = "+%s" ]; then
    local n; n=$(( $(cat "$TICK_FILE") + 1 )); printf '%s' "$n" > "$TICK_FILE"
    printf '%s' "$(( BASE_EPOCH + n ))"
  else
    command date "$@"
  fi
}

unset HERD_FAKE_NOW HERD_NOW_EPOCH 2>/dev/null || true

# ── (1) shared seam ──────────────────────────────────────────────────────────────────────────────
# An unpinned clock genuinely advances call-to-call (the stub itself works)…
a1="$(_now_epoch)"; a2="$(_now_epoch)"; a3="$(_now)"
[ "$a1" != "$a2" ] || fail "the fake clock stub never advanced — the test fixture is broken"
[ "$a2" != "$a3" ] || fail "the fake clock stub never advanced for _now — the test fixture is broken"
ok

# …HERD_NOW_EPOCH still works standalone (the pre-HERD-491 seam), unchanged, for both readers now.
export HERD_NOW_EPOCH=555555555
[ "$(_now_epoch)" = "555555555" ] || fail "_now_epoch must honor HERD_NOW_EPOCH as a fallback (HERD-491 unify)"
[ "$(_now)" = "555555555" ] || fail "_now must still honor HERD_NOW_EPOCH (backward compat)"
unset HERD_NOW_EPOCH
ok

# HERD_FAKE_NOW now ALSO pins _now (previously _now()-only via HERD_NOW_EPOCH — the two-seam split
# that let one render-pass reader disagree with another about "now").
export HERD_FAKE_NOW=444444444
[ "$(_now_epoch)" = "444444444" ] || fail "_now_epoch must honor HERD_FAKE_NOW"
[ "$(_now)" = "444444444" ] || fail "_now must now ALSO honor HERD_FAKE_NOW (HERD-491 unify)"
unset HERD_FAKE_NOW
ok

# ── (2) the render-pass pin: reads inside the bracket are IDENTICAL despite the advancing clock ────
unset HERD_FAKE_NOW HERD_NOW_EPOCH 2>/dev/null || true
_render_pass_clock_begin
b1="$(_now_epoch)"; b2="$(_now_epoch)"; b3="$(_now)"
[ "$b1" = "$b2" ] && [ "$b2" = "$b3" ] || fail "pinned render pass disagreed on 'now': $b1 / $b2 / $b3"
ok
_render_pass_clock_end
[ -z "${HERD_FAKE_NOW:-}" ] || fail "the pin must not leak past _render_pass_clock_end when nothing was set before it"
c1="$(_now_epoch)"
[ "$c1" != "$b1" ] || fail "the clock must resume advancing once the render pass ends"
ok

# ── (3) a NESTED pin (an outer hermetic test's own HERD_FAKE_NOW) is preserved exactly ─────────────
export HERD_FAKE_NOW=999000111
_render_pass_clock_begin
[ "${HERD_FAKE_NOW:-}" = "999000111" ] || fail "an outer pin must survive _render_pass_clock_begin unchanged"
[ "$(_now_epoch)" = "999000111" ] || fail "a nested pin must still read the OUTER fixed instant"
_render_pass_clock_end
[ "${HERD_FAKE_NOW:-}" = "999000111" ] || fail "_render_pass_clock_end must RESTORE the outer pin, not unset it"
unset HERD_FAKE_NOW
ok

# ── (4) a real render row: build_spawn_holds byte-differs unpinned, byte-matches pinned ────────────
unset HERD_FAKE_NOW HERD_NOW_EPOCH 2>/dev/null || true
TREES="$T/trees"; SPAWN_HELD_STATE="$T/trees/.agent-watch-spawn-held"; DEP_STALE_TTL=86400; SLUGW=28
C_RESET='' C_DIM='' C_RED='' C_YELLOW='' C_GREEN='' C_CYAN=''
mkdir -p "$TREES/spawn-queue"
epoch_now="$(( BASE_EPOCH + $(cat "$TICK_FILE") ))"
printf '%s %s held-slug feature dep-x\n' "int-a" "$(( epoch_now - 5 ))" > "$SPAWN_HELD_STATE"
: > "$TREES/spawn-queue/int-a.req"

build_spawn_holds; r1="$SPAWN_HOLDS"
build_spawn_holds; r2="$SPAWN_HOLDS"
[ "$r1" != "$r2" ] || fail "expected the unpinned race to reproduce (rows should differ under the advancing clock — got '$r1' twice)"
ok

_render_pass_clock_begin
build_spawn_holds; r3="$SPAWN_HOLDS"
build_spawn_holds; r4="$SPAWN_HOLDS"
_render_pass_clock_end
[ -n "$r3" ] || fail "build_spawn_holds produced an empty row under the pin — fixture broken"
[ "$r3" = "$r4" ] || fail "HERD-491: build_spawn_holds must render byte-identically across one pinned render pass: '$r3' vs '$r4'"
ok

echo "ok — render-pass clock pin (HERD-491): $pass checks passed"
