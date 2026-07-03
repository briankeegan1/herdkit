#!/usr/bin/env bash
# test-dep-states.sh — hermetic tests for the richer dep STATE model, stall surfacing, capped
# backoff (dep-watcher.sh) and the "blocked on" console section (agent-watch.sh).
#
# Sources both scripts in their respective lib modes (no polling loop, no live console), so no
# network, no gh/herdr, no tabs. Exercises the pure helpers plus one end-to-end pass where a dep
# transitions through states driven ONLY by a stubbed upstream state.
# Run:  bash tests/test-dep-states.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCHER="$HERE/../scripts/herd/dep-watcher.sh"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$WATCHER" ] || fail "dep-watcher.sh not found at $WATCHER"
[ -f "$WATCH" ]   || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Source dep-watcher helpers (lib mode: helpers only, no loop) ─────────────────────────────────
export DEP_WATCHER_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"   # falls back to generic defaults
export WORKTREES_DIR="$T"
export PROJECT_ROOT="$T/project"
export WORKSPACE_NAME="test-proj"
mkdir -p "$PROJECT_ROOT/.herd"
# shellcheck source=/dev/null
. "$WATCHER" || fail "sourcing dep-watcher.sh (lib mode) failed"
type _dw_derive_state >/dev/null 2>&1 || fail "_dw_derive_state not defined"
type _dw_next_interval >/dev/null 2>&1 || fail "_dw_next_interval not defined"
type _dw_write_states  >/dev/null 2>&1 || fail "_dw_write_states not defined"

TTL=100   # small TTL so "stalled" is reachable in-test

# ── 1. _dw_derive_state: a dep transitions through states from the stubbed upstream state ─────────
# Each pair is "<raw-upstream-state> <age> => <expected-derived>". age below TTL keeps the raw
# state; a still-open dep past TTL becomes `stalled`; closed/unknown pass through.
check_derive(){
  local raw="$1" age="$2" want="$3" got
  got="$(_dw_derive_state "$raw" "$age" "$TTL")"
  [ "$got" = "$want" ] || fail "_dw_derive_state('$raw', $age, $TTL) = '$got', want '$want'"
  pass
}
check_derive open        10  open          # fresh open dep
check_derive in-progress 20  in-progress   # upstream work started
check_derive in-review   30  in-review     # upstream out for review
check_derive in-review   150 stalled       # still in-review past TTL → stalled (surfaced, not frozen)
check_derive open        150 stalled       # any open-ish state past TTL stalls
check_derive closed      150 closed        # closed passes through regardless of age
check_derive unknown     10  unknown       # unresolved upstream → unknown
check_derive garbage     10  unknown       # unexpected raw → unknown (safe default)

# TTL disabled (0) never stalls, no matter how old.
[ "$(_dw_derive_state open 999999 0)" = "open" ] || fail "TTL=0 must disable stalling"
pass

# ── 2. Stall surfacing end-to-end: a stubbed upstream drives one dep to `stalled` ────────────────
# Override _dw_check_state to script the upstream state, then run the derive pipeline the loop uses.
_now=1700000000
UPSTREAM="in-review"
_dw_check_state(){ printf '%s\n' "$UPSTREAM"; }
SINCE_FILE="$T/.dep.since"; STATES_FILE="$T/.dep.states"
_dw_record_since "provider-lib#42" "$_now"

drive_state(){
  # Mirror the loop's per-dep derivation for ref $1 at wall-clock $2.
  local ref="$1" now="$2" raw since age
  raw="$(_dw_check_state "$ref")"
  since="$(_dw_get_since "$ref")"; age=$(( now - ${since:-now} ))
  _dw_derive_state "$raw" "$age" "$TTL"
}

[ "$(drive_state provider-lib#42 $((_now + 10)))" = "in-review" ] \
  || fail "young in-review dep should read in-review"
pass
[ "$(drive_state provider-lib#42 $((_now + TTL + 5)))" = "stalled" ] \
  || fail "in-review dep past TTL should surface as stalled"
pass
# A stall must NOT remove the dep (never a freeze / never auto-unblocks) — deps file untouched here.

# ── 3. _dw_write_states writes the console surface atomically ─────────────────────────────────────
_dw_write_states "provider-lib#42 stalled 105"$'\n'"other-repo#7 in-progress 12"$'\n'
grep -q "^provider-lib#42 stalled 105$" "$STATES_FILE" || fail "states file missing stalled line"
grep -q "^other-repo#7 in-progress 12$" "$STATES_FILE" || fail "states file missing in-progress line"
[ -e "${STATES_FILE}.$$" ] && fail "temp states file should have been moved, not left behind" || true
pass

# ── 4. _dw_next_interval: capped exponential backoff widens the poll interval ────────────────────
MIN=30; MAX=300
i="$MIN"
prev="$i"
for _ in 1 2 3; do
  i="$(_dw_next_interval "$i" "$MIN" "$MAX" 1)"   # widen=1 each idle tick
  [ "$i" -gt "$prev" ] || fail "backoff must widen: $prev -> $i"
  prev="$i"
done
[ "$i" = "240" ] || fail "30->60->120->240 expected after 3 widens (got $i)"
pass
# Widening is capped at MAX and never exceeds it.
capped="$(_dw_next_interval "$MAX" "$MIN" "$MAX" 1)"
[ "$capped" = "$MAX" ] || fail "backoff must cap at MAX=$MAX (got $capped)"
pass
# widen=0 (a state change) resets to MIN.
[ "$(_dw_next_interval 240 "$MIN" "$MAX" 0)" = "$MIN" ] || fail "no-widen must reset to MIN"
pass

# ── 5. agent-watch build_blocked renders the dep-state surface (console display) ─────────────────
(
  export AGENT_WATCH_LIB=1
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "FAIL: sourcing agent-watch.sh (lib mode) failed" >&2; exit 1; }
  type build_blocked >/dev/null 2>&1 || { echo "FAIL: build_blocked not defined" >&2; exit 1; }

  DEP_STATES_FILE="$T/.dep.states.console"
  printf '%s\n' "provider-lib#42 stalled 105" "other-repo#7 in-progress 12" > "$DEP_STATES_FILE"
  BLOCKED=""
  build_blocked
  plain="$(printf '%s' "$BLOCKED" | sed $'s/\033\\[[0-9;]*m//g')"
  case "$plain" in *"provider-lib#42"*"stalled"*) ;; *) echo "FAIL: blocked row missing stalled dep" >&2; exit 1 ;; esac
  case "$plain" in *"other-repo#7"*"in-progress"*) ;; *) echo "FAIL: blocked row missing in-progress dep" >&2; exit 1 ;; esac

  # No file → empty section (render omits it), never an error.
  DEP_STATES_FILE="$T/.dep.states.absent"
  BLOCKED="sentinel"
  build_blocked
  [ -z "$BLOCKED" ] || { echo "FAIL: build_blocked should clear BLOCKED when file absent" >&2; exit 1; }
  echo "SUBPASS"
) | grep -q "SUBPASS" || fail "agent-watch build_blocked checks failed (see above)"
pass

echo "ALL PASS ($PASS checks)"
