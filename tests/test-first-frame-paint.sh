#!/usr/bin/env bash
# test-first-frame-paint.sh — hermetic proof for HERD-615: the cold-start FIRST FRAME.
#
# GROUNDED (operator report 2026-08-10, after `herd reload`): the watch pane's render loop used to
# perform every startup probe — `gh pr list`, per-PR mergeability/CI checks, the driver's agent
# roster — SYNCHRONOUSLY before the tick's ONE `render` call at the bottom of _tick_render_reconcile,
# so a cold `gh` path (fresh process, no warm auth/DNS cache) held the WHOLE first paint for up to
# ~60s and the pane read as stuck at the banner.
#
# THE FIX: _first_frame_paint (agent-watch.sh) fires once, immediately after the tick's last purely
# local/ledger build_* call and BEFORE _prs_fetch_tick (the first `gh` call): it paints everything
# already known via one `render` call, with DISPLAY still empty and render()'s _RENDER_GATHERING flag
# telling the "in flight" section to say so honestly ("⏳ gathering…") instead of fabricating
# "— idle —". The tick then falls straight through to the slow probes exactly as before, and the
# tick's normal end-of-function `render` call repaints for free once the real rows land (render()'s
# own last_frame diff means a no-op if nothing changed).
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) — the same harness test-pr-match-truth.sh and
# test-tick-split.sh use — so this proof runs against the REAL functions, not a re-implementation.
# Proves, in order:
#   (1) ORDERING — _tick_render_reconcile calls _first_frame_paint BEFORE _prs_fetch_tick (structural:
#       the property that makes the fix work at all, independent of how slow `gh` happens to be).
#   (2) CONTENT — one call to _first_frame_paint paints the header, every already-built ledger section
#       (LANDED/BLOCKED/SPAWN_HOLDS proven directly), and an honest "gathering" row in place of a
#       fabricated "— idle —" (DISPLAY is empty only because nothing has been fetched yet).
#   (3) ONE-SHOT — a second call is a hard no-op (_FIRST_FRAME_PAINTED guards it): no output, no
#       second journal line, _RENDER_GATHERING never leaks into a later, real render() call.
#   (4) OBSERVABILITY — it journals `first_frame elapsed_ms=<N>` (N >= 0) unconditionally, feeding the
#       ANOMALY_BASELINES rail via _phase_anomaly_observe (ship-dormant; never errors with the lever
#       off, proven by a clean stderr).
#   (5) LIVE COLD-START PROOF — with a REAL `gh` stub that sleeps 5s on `pr list`, _first_frame_paint
#       still returns and paints the gathering note in well under 2 seconds; the subsequent
#       _prs_fetch_tick (the slow probe the fix defers past) genuinely takes the full ~5s — proving
#       the paint is not merely "before" the probe in source order but actually returns before the
#       probe would even finish, exactly the operator-visible property HERD-615 asks for.
#   (6) STEADY STATE UNCHANGED — render() with _RENDER_GATHERING unset (every tick after the first,
#       and every tick before this feature existed) still paints the ordinary "— idle —" row —
#       byte-identical to before this feature for the only case that previously existed.
#
# Run:  bash tests/test-first-frame-paint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
[ -f "$WATCH" ] || { echo "FAIL: missing $WATCH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# ── (1) ORDERING: _first_frame_paint precedes _prs_fetch_tick in _tick_render_reconcile's body ────
(
  export AGENT_WATCH_LIB=1
  export WORKTREES_DIR="$T/trees-order"; mkdir -p "$WORKTREES_DIR"
  export HERD_CONFIG_FILE="$T/no-such-config"
  # shellcheck source=/dev/null
  . "$WATCH" || exit 1
  declare -F _first_frame_paint >/dev/null 2>&1 || { echo "no-fn" >&2; exit 1; }
  declare -F _tick_render_reconcile >/dev/null 2>&1 || { echo "no-tick" >&2; exit 1; }
  body="$(declare -f _tick_render_reconcile)"
  before="${body%%_prs_fetch_tick*}"
  case "$before" in
    *_first_frame_paint*) exit 0 ;;
    *) echo "wrong-order" >&2; exit 2 ;;
  esac
) || fail "(1) _tick_render_reconcile must call _first_frame_paint before _prs_fetch_tick"
ok

# ── shared lib-mode fixture for (2)-(4) and (6) ─────────────────────────────────────────────────
FIX="$T/fix"; mkdir -p "$FIX/trees"
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$FIX/trees"
export HERD_CONFIG_FILE="$FIX/no-such-config"
export JOURNAL_FILE="$FIX/journal.jsonl"
export TERM=dumb
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# Stand in for "whatever rows the pool ledgers already hold" — set as build_* would have, BEFORE
# _first_frame_paint runs, exactly like the real tick.
HDR_LINE="HEADER-ROW"; RULE="RULE-ROW"
LANDED="    landed-thing"$'\n'
BLOCKED="    blocked-thing"$'\n'
SPAWN_HOLDS="    spawn-hold-thing"$'\n'
DISPLAY=()

# ── (2) CONTENT ──────────────────────────────────────────────────────────────────────────────────
_first_frame_paint > "$T/frame1.txt" 2>"$T/err1.txt" || fail "(2) _first_frame_paint must exit 0"
[ -s "$T/err1.txt" ] && fail "(2) _first_frame_paint wrote to stderr: $(cat "$T/err1.txt")"
grep -q "HEADER-ROW" "$T/frame1.txt"       || fail "(2) header must paint on the first frame"
grep -q "landed-thing" "$T/frame1.txt"     || fail "(2) an already-built LANDED ledger row must paint"
grep -q "blocked-thing" "$T/frame1.txt"    || fail "(2) an already-built BLOCKED ledger row must paint"
grep -q "spawn-hold-thing" "$T/frame1.txt" || fail "(2) an already-built SPAWN_HOLDS ledger row must paint"
grep -q "gathering" "$T/frame1.txt"        || fail "(2) the honest gathering row must paint in place of 'idle'"
grep -q "idle" "$T/frame1.txt"             && fail "(2) must NEVER claim idle before the PR roster is fetched"
ok

# ── (3) ONE-SHOT ─────────────────────────────────────────────────────────────────────────────────
[ "${_FIRST_FRAME_PAINTED:-}" = "1" ] || fail "(3) the guard must be armed after the first call"
[ -z "${_RENDER_GATHERING:-}" ] || fail "(3) _RENDER_GATHERING must not leak past the first call"
_first_frame_paint > "$T/frame2.txt" 2>"$T/err2.txt"
[ ! -s "$T/frame2.txt" ] || fail "(3) a second call must paint NOTHING (byte-inert past the first tick)"
[ ! -s "$T/err2.txt" ]   || fail "(3) a second call must not error"
ok

# ── (4) OBSERVABILITY ────────────────────────────────────────────────────────────────────────────
[ -s "$JOURNAL_FILE" ] || fail "(4) first_frame must be journaled"
line="$(grep -m1 '"event":"first_frame"' "$JOURNAL_FILE")"
[ -n "$line" ] || fail "(4) no first_frame journal line found: $(cat "$JOURNAL_FILE")"
ms="$(printf '%s' "$line" | sed -n 's/.*"elapsed_ms":\([0-9][0-9]*\).*/\1/p')"
[ -n "$ms" ] || fail "(4) first_frame journal line missing a numeric elapsed_ms: $line"
[ "$ms" -ge 0 ] || fail "(4) elapsed_ms must be non-negative, got $ms"
n_first_frame="$(grep -c '"event":"first_frame"' "$JOURNAL_FILE")"
[ "$n_first_frame" = "1" ] || fail "(4) first_frame must journal exactly once, got $n_first_frame"
ok

# ── (5) LIVE COLD-START PROOF: a REAL slow gh stub ──────────────────────────────────────────────
(
  BIN="$T/bin5"; mkdir -p "$BIN"
  cat > "$BIN/gh" << 'STUB'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) sleep 5; echo '[]'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
  FIX5="$T/fix5"; mkdir -p "$FIX5/trees"
  export AGENT_WATCH_LIB=1
  export WORKTREES_DIR="$FIX5/trees"
  export HERD_CONFIG_FILE="$FIX5/no-such-config"
  export JOURNAL_FILE="$FIX5/journal.jsonl"
  export TERM=dumb
  # shellcheck source=/dev/null
  . "$WATCH" || exit 1
  # This subshell forked from the outer test script, which already ran (2)-(4) and armed the guard
  # there — reset it so this block starts exactly as a freshly-launched watcher process would.
  unset _FIRST_FRAME_PAINTED _RENDER_GATHERING
  last_frame=""
  HDR_LINE="H"; RULE="R"; DISPLAY=()

  t0=$(date +%s)
  _first_frame_paint > "$T/frame5.txt" || exit 1
  t1=$(date +%s)
  paint_secs=$(( t1 - t0 ))
  grep -q "gathering" "$T/frame5.txt" || { echo "no-gathering-row" >&2; exit 1; }
  [ "$paint_secs" -lt 2 ] || { echo "paint took ${paint_secs}s (>= 2s) even with no slow work of its own" >&2; exit 1; }

  # The probe the fix defers past really is the slow one — proves the stub (and thus the timing
  # comparison above) is real, not a no-op that would make (5) trivially pass.
  _prs_fetch_tick
  t2=$(date +%s)
  fetch_secs=$(( t2 - t1 ))
  [ "$fetch_secs" -ge 4 ] || { echo "gh stub did not actually sleep (fetch took ${fetch_secs}s)" >&2; exit 1; }
  exit 0
) || fail "(5) a real slow gh must not delay the first paint past 2s"
ok

# ── (6) STEADY STATE UNCHANGED: render() with _RENDER_GATHERING unset still says '— idle —' ────────
last_frame=""
DISPLAY=()
unset _RENDER_GATHERING
render > "$T/frame6.txt" 2>"$T/err6.txt" || fail "(6) render must exit 0"
grep -q -- "— idle —" "$T/frame6.txt" || fail "(6) render() outside the first-frame path must still paint '— idle —'"
grep -q "gathering" "$T/frame6.txt" && fail "(6) render() must never paint 'gathering' outside the first-frame path"
ok

echo "ALL PASS ($pass checks)"
