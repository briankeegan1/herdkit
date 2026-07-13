#!/usr/bin/env bash
# test-engine-pause.sh — hermetic unit tests for the OPERATOR EMERGENCY PAUSE lever (HERD-347): the
# ENGINE_PAUSE=on|off switch that lets an operator hold the action engine WITHOUT killing the watcher.
# Proves the lever BOTH ways, per AGENTS.md, plus the invariants the feature must hold:
#
#   • OFF (default/unset) is byte-inert: _engine_tick_watchdog runs the engine tick exactly as before,
#     ENGINE_PAUSE_ROW stays empty so render() adds NO row (byte-identical console), and no
#     engine_paused journal/notify fires.
#   • ON SKIPS the Python live tick entirely (zero dispatch — herd_engine_live_tick is never called),
#     does NOT count the skipped tick as a fault (the fault streak is untouched), paints the loud
#     '⏸ engine paused by operator' banner, and journals + notifies exactly ONCE per pause episode.
#   • The value is read FRESH from the config file each tick (machine-scope: .herd/config.local wins
#     over .herd/config), so any seat's set takes effect on the next tick with no restart / no cache.
#   • RESUME (on → off) clears the banner, journals engine_resumed once, and lets the engine tick again.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1 — helpers only, no polling loop, no network),
# with config discovery pointed at a file this test controls so the fresh-read path resolves to it.
# Run:  bash tests/test-engine-pause.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# ── config files the fresh-read path resolves: baseline .herd/config + .herd/config.local overlay ──
CFGDIR="$T/.herd"; mkdir -p "$CFGDIR"
CFG="$CFGDIR/config"; LOCAL="$CFGDIR/config.local"
: > "$CFG"

# ── Source the watcher's helpers WITHOUT its live loop (lib mode), colors blanked (NO_COLOR) ───────
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$CFG"
export WORKTREES_DIR="$T"
export NO_COLOR=1
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _engine_pause_config_value _engine_paused _engine_tick_watchdog render; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
# The fresh-read path resolves off $HERD_CONFIG_FILE (still exported) + its sibling config.local — the
# loader unsets its own internal _HERD_CONFIG_* path vars, so the helper must NOT depend on them.
[ "${HERD_CONFIG_FILE:-}" = "$CFG" ] || fail "HERD_CONFIG_FILE=${HERD_CONFIG_FILE:-} (want $CFG)"
pass

# ── 1. _engine_paused: default OFF; recognized truthy tokens ON; garbage OFF (fail toward running) ─
: > "$CFG"; rm -f "$LOCAL"
_engine_paused && fail "_engine_paused must be OFF with no ENGINE_PAUSE in config"; pass
for v in on ON true TRUE 1 yes YES; do
  printf 'ENGINE_PAUSE=%s\n' "$v" > "$CFG"
  _engine_paused || fail "_engine_paused should be ON for ENGINE_PAUSE=$v"
done; pass
for v in off OFF "" 0 no garbage maybe; do
  printf 'ENGINE_PAUSE=%s\n' "$v" > "$CFG"
  _engine_paused && fail "_engine_paused should be OFF for ENGINE_PAUSE=$v"
done; pass

# ── 2. Fresh read + quoting + machine-scope overlay precedence (.herd/config.local wins) ───────────
printf 'ENGINE_PAUSE="on"\n' > "$CFG"                 # quoted value parses
_engine_paused || fail "quoted ENGINE_PAUSE=\"on\" should be ON"; pass
printf 'ENGINE_PAUSE = on   # inline comment\n' > "$CFG"   # spaces + trailing comment tolerated
_engine_paused || fail "spaced/commented ENGINE_PAUSE should be ON"; pass
printf 'ENGINE_PAUSE=on\n' > "$CFG"                   # baseline ON …
printf 'ENGINE_PAUSE=off\n' > "$LOCAL"                # … overlay OFF wins
_engine_paused && fail "config.local overlay (off) must win over baseline (on)"; pass
printf 'ENGINE_PAUSE=off\n' > "$CFG"                  # baseline OFF …
printf 'ENGINE_PAUSE=on\n' > "$LOCAL"                 # … overlay ON wins
_engine_paused || fail "config.local overlay (on) must win over baseline (off)"; pass
rm -f "$LOCAL"

# ── test harness: record the effectful seams so the watchdog can be driven hermetically ────────────
EVENTS="$T/events"; : > "$EVENTS"
journal_append(){ printf 'journal:%s\n' "$1" >> "$EVENTS"; }
herd_driver_notify(){ printf 'notify:%s\n' "$1" >> "$EVENTS"; }
render(){ printf 'render\n' >> "$EVENTS"; }
# THE dispatch seam: a real tick shells out through here. Paused ⇒ this must NEVER be called.
herd_engine_live_tick(){ printf 'live_tick\n' >> "$EVENTS"; return 0; }
# real watchdog tuning shape (fast: DRYRUN skips the backoff sleep)
DRYRUN=1
_ENGINE_FAULT_STREAK=0; _ENGINE_FAULT_MAX=3; _ENGINE_TICK_RETRIES=2; _ENGINE_BACKOFF_BASE=1
_ENGINE_DOWN_DECLARED=""; ENGINE_DOWN_ROW=""; _ENGINE_PAUSE_DECLARED=""; ENGINE_PAUSE_ROW=""

count(){ grep -c "^$1\$" "$EVENTS" 2>/dev/null || true; }

# ── 3. OFF is byte-inert: the tick runs, no banner, no pause journal/notify ────────────────────────
: > "$CFG"; : > "$EVENTS"
ENGINE_PAUSE_ROW=""; _ENGINE_PAUSE_DECLARED=""; _ENGINE_FAULT_STREAK=0
_engine_tick_watchdog || fail "watchdog should return 0 on a clean unpaused tick"
[ "$(count live_tick)" = 1 ] || fail "OFF: engine tick must run exactly once (got $(count live_tick))"
[ -z "$ENGINE_PAUSE_ROW" ] || fail "OFF: ENGINE_PAUSE_ROW must stay empty (byte-inert console)"
[ "$(count journal:engine_paused)" = 0 ] || fail "OFF: engine_paused must not journal"
[ "$(count journal:engine_resumed)" = 0 ] || fail "OFF: engine_resumed must not journal"
pass

# ── 4. ON: zero dispatch, no fault, loud banner, journal+notify exactly once per episode ───────────
printf 'ENGINE_PAUSE=on\n' > "$CFG"
: > "$EVENTS"; _ENGINE_FAULT_STREAK=0; _ENGINE_PAUSE_DECLARED=""; ENGINE_PAUSE_ROW=""
_engine_tick_watchdog || fail "watchdog paused-tick must return 0 (a pause is not a fault)"
_engine_tick_watchdog || fail "watchdog paused-tick must return 0 (repeat)"
_engine_tick_watchdog || fail "watchdog paused-tick must return 0 (repeat)"
[ "$(count live_tick)" = 0 ] || fail "ON: engine tick must NEVER be dispatched while paused (got $(count live_tick))"
[ "$_ENGINE_FAULT_STREAK" = 0 ] || fail "ON: a skipped tick must not count as a fault (streak=$_ENGINE_FAULT_STREAK)"
[ -z "$ENGINE_DOWN_ROW" ] || fail "ON: the engine-down banner must never arm from a pause"
case "$ENGINE_PAUSE_ROW" in *"engine paused by operator"*) : ;; *) fail "ON: loud pause banner not set (got: '$ENGINE_PAUSE_ROW')" ;; esac
[ "$(count journal:engine_paused)" = 1 ] || fail "ON: engine_paused must journal ONCE per episode (got $(count journal:engine_paused))"
[ "$(count notify:*)" -le 1 ] 2>/dev/null || true
np="$(grep -c '^notify:' "$EVENTS" || true)"
[ "$np" = 1 ] || fail "ON: exactly one pause notification per episode (got $np)"
pass

# ── 5. RESUME (on → off): banner clears, engine_resumed journaled once, the tick runs again ────────
printf 'ENGINE_PAUSE=off\n' > "$CFG"
: > "$EVENTS"
_engine_tick_watchdog || fail "watchdog should return 0 when the engine resumes cleanly"
[ -z "$ENGINE_PAUSE_ROW" ] || fail "RESUME: ENGINE_PAUSE_ROW must clear on resume"
[ -z "$_ENGINE_PAUSE_DECLARED" ] || fail "RESUME: _ENGINE_PAUSE_DECLARED must clear on resume"
[ "$(count journal:engine_resumed)" = 1 ] || fail "RESUME: engine_resumed must journal once (got $(count journal:engine_resumed))"
[ "$(count live_tick)" = 1 ] || fail "RESUME: the engine tick must dispatch again after resume (got $(count live_tick))"
pass

# ── 6. render(): the banner appears ONLY when ENGINE_PAUSE_ROW is set (byte-identical when off) ────
# Restore the REAL render (unstub) by re-sourcing the function body is heavy; instead assert the frame
# the real render builds. Re-source in a clean subshell so the real render() is in scope.
(
  export AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$CFG" WORKTREES_DIR="$T" NO_COLOR=1
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "resource-fail" >&2; exit 1; }
  ENGINE_PAUSE_ROW=""; frame=""; render >/dev/null 2>&1; off="$frame"
  row=$'    PAUSE_MARKER_ROW\n'
  ENGINE_PAUSE_ROW="$row"; frame=""; render >/dev/null 2>&1; on="$frame"
  case "$off" in *PAUSE_MARKER_ROW*) echo "OFF frame leaked the pause row" >&2; exit 1 ;; esac
  case "$on"  in *PAUSE_MARKER_ROW*) : ;; *) echo "ON frame missing the pause row" >&2; exit 1 ;; esac
  # byte-identical-when-off: the ON frame is the OFF frame with ONLY the banner block inserted
  # (render appends `  engine` + NL + $ENGINE_PAUSE_ROW + NL; C_* are blank under NO_COLOR).
  block="  engine"$'\n'"${row}"$'\n'
  stripped="${on/"$block"/}"
  [ "$stripped" = "$off" ] || { echo "ON frame differs from OFF beyond the banner block" >&2; exit 1; }
) || fail "render() pause-banner gating (byte-identical when off) failed"
pass

echo "ok — $PASS engine-pause checks passed"
