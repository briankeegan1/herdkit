#!/usr/bin/env bash
# test-watcher-singleton.sh — hermetic proof of the watcher SINGLETON spawn-lock (HERD-209 / HERD-252).
#
# The incident: control-room recovery (herd pane watch / herd reload / manual herd-watch.sh) spawned a
# SECOND agent-watch main WITHOUT killing the first, so two watchers polled the same PRs and raced the
# shared .git object store — healthchecks restarted endlessly. The fix enforces a REAL singleton at
# every launch: an ATOMIC check of HERD_WATCHER_LOCK (kill -0 on the recorded pid) that REFUSES a
# duplicate and ADOPTS a stale/absent lock.
#
# HERD-252: a LIVE-lock collision must refuse LOUDLY (stderr names the holder pid) and EXIT NON-ZERO
# immediately — never block/hang. Operator report: a second `bash scripts/herd/herd-watch.sh` under a
# live pane watcher printed the banner then hung silently. Correct refusal, wrong manners.
#
# This test drives the SHIPPED acquisition function _acquire_watcher_singleton (agent-watch.sh, sourced
# in lib mode via the AGENT_WATCH_LIB guard) and bin/herd's mirror helper _watcher_lock_pid_if_live,
# asserting:
#   (a) a SECOND launch under a LIVE HERD_WATCHER_LOCK REFUSES (returns non-zero) within ~1s, prints
#       the holder pid on stderr, and spawns no duplicate — the recorded pid is left untouched.
#   (b) a launch under a STALE lock (dead pid) PROCEEDS (returns 0) and adopts the lock (writes its
#       own pid).
#   (c) a launch under an ABSENT lock PROCEEDS.
#   (d) bin/herd's launch-path helper _watcher_lock_pid_if_live echoes a live recorded pid (ADOPT
#       signal) and stays silent on a stale/absent lock (so the caller (re)launches).
#
# No `set -e`: some checks deliberately expect a non-zero return; we assert explicitly.
# Run:  bash tests/test-watcher-singleton.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
HERD_BIN="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# A GUARANTEED-DEAD pid: spawn a trivial process, reap it, reuse its pid. kill -0 on it fails.
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null || true
# A GUARANTEED-LIVE pid we own for the duration of the test.
sleep 300 & LIVE=$!
trap 'kill "$LIVE" 2>/dev/null || true; rm -rf "$T"' EXIT
kill -0 "$LIVE" 2>/dev/null || fail "setup: live helper pid $LIVE is not actually alive"

# ── Source the watcher's helpers WITHOUT its live loop (lib mode). Point config discovery at a
#    nonexistent file so herd-config.sh falls back to generic defaults — fully hermetic. Override
#    HERD_WATCHER_LOCK to a temp path so we never touch a real workspace lock.
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKSPACE_NAME="singleton-test"
LOCK="$T/.watcher.pid"
export HERD_WATCHER_LOCK="$LOCK"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
# Sourcing may reset HERD_WATCHER_LOCK from herd-config.sh defaults — pin it back to our temp path.
export HERD_WATCHER_LOCK="$LOCK"
type _acquire_watcher_singleton >/dev/null 2>&1 || fail "_acquire_watcher_singleton not defined after sourcing"

# acquire runs the gate in a SUBSHELL so a flock fd / EXIT trap it installs never leaks into this
# shell (the real watcher process holds them for life; a subshell models a separate launch). Echoes
# REFUSE (non-zero return) or ACQUIRE (zero return).
acquire() { if ( _acquire_watcher_singleton >/dev/null 2>&1 ); then echo ACQUIRE; else echo REFUSE; fi; }

# ── (a) LIVE lock → REFUSE LOUDLY + non-zero + fast, no duplicate, recorded pid untouched ─────
printf '%s\n' "$LIVE" > "$LOCK"
# Capture stderr + wall time: must name the holder pid and finish within ~1s (never hang).
_a_err="$T/a.err"
_a_start=$(date +%s)
_a_rc=0
( _acquire_watcher_singleton >"$T/a.out" 2>"$_a_err" ) || _a_rc=$?
_a_end=$(date +%s)
_a_elapsed=$((_a_end - _a_start))
[ "$_a_rc" -ne 0 ] || fail "(a) a second launch under a LIVE lock must exit NON-ZERO (got rc=$_a_rc)"
[ "$_a_elapsed" -le 1 ] || fail "(a) live-lock refuse must complete within ~1s (took ${_a_elapsed}s — hung/blocked?)"
grep -q "already running" "$_a_err" || fail "(a) stderr must say already running (got: $(cat "$_a_err"))"
grep -qE "pid[[:space:]]*$LIVE|PID[[:space:]]*$LIVE|\\(pid $LIVE\\)" "$_a_err" \
  || fail "(a) stderr must name the holder pid $LIVE (got: $(cat "$_a_err"))"
[ "$(cat "$LOCK")" = "$LIVE" ] || fail "(a) the live recorded pid must be left untouched by the refused launch"
# Sanity: the quiet acquire() helper still reports REFUSE for the same state.
[ "$(acquire)" = "REFUSE" ] || fail "(a) acquire() helper must also REFUSE under a LIVE lock"
ok
echo "PASS (a) live lock → refuse loudly (pid $LIVE), non-zero, ≤1s, no duplicate"

# ── (b) STALE lock (dead pid) → PROCEED and adopt ───────────────────────────────
printf '%s\n' "$DEAD" > "$LOCK"
[ "$(acquire)" = "ACQUIRE" ] || fail "(b) a launch under a STALE lock (dead pid) must PROCEED"
# The subshell that acquired wrote its own (now-exited) pid; the point is it OVERWROTE the dead pid.
[ "$(cat "$LOCK")" != "$DEAD" ] || fail "(b) a stale lock must be adopted (dead pid overwritten), not preserved"
ok
echo "PASS (b) stale lock → proceed + adopt"

# ── (c) ABSENT lock → PROCEED ───────────────────────────────────────────────────
rm -f "$LOCK"
[ "$(acquire)" = "ACQUIRE" ] || fail "(c) a launch under an ABSENT lock must PROCEED"
ok
echo "PASS (c) absent lock → proceed"

# ── (d) bin/herd launch-path mirror: _watcher_lock_pid_if_live ───────────────────
# Extract the helper from bin/herd and source it standalone (it depends only on HERD_WATCHER_LOCK).
grep -q "_watcher_lock_pid_if_live()" "$HERD_BIN" || fail "(d) bin/herd is missing _watcher_lock_pid_if_live"
# Pull just the function body into a sourceable snippet.
awk '/^_watcher_lock_pid_if_live\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$HERD_BIN" > "$T/helper.sh"
# shellcheck source=/dev/null
. "$T/helper.sh" || fail "(d) could not source the extracted _watcher_lock_pid_if_live"

printf '%s\n' "$LIVE" > "$LOCK"
[ "$(_watcher_lock_pid_if_live)" = "$LIVE" ] || fail "(d) helper must echo a LIVE recorded pid (adopt signal)"
printf '%s\n' "$DEAD" > "$LOCK"
[ -z "$(_watcher_lock_pid_if_live)" ] || fail "(d) helper must be silent on a STALE (dead-pid) lock"
rm -f "$LOCK"
[ -z "$(_watcher_lock_pid_if_live)" ] || fail "(d) helper must be silent on an ABSENT lock"
ok
echo "PASS (d) bin/herd _watcher_lock_pid_if_live adopt/stale/absent signalling"

# ── (e) HERD-344: flock held by orphan but recorded pid DEAD → adopt (stale-flock backstop) ───
# Simulate the exact incident: a gate worker inherits fd 9, holding the flock via the SHARED
# open-file description, while the main watcher dies (recorded pid goes dead). A new watcher
# must adopt the lock rather than refusing forever.
#
# PLATFORM GUARD (HERD-450): this case is only meaningful where flock(1) exists. Without it the
# ORPHAN takes no lock at all AND _acquire_watcher_singleton runs its atomic-mkdir primitive instead
# of the flock branch — so on macOS the case used to "pass" while exercising nothing it claims to.
# Skip honestly there; CI's ubuntu leg is the seat that actually proves this path.
if ! command -v flock >/dev/null 2>&1; then
  echo "SKIP (e) flock(1) absent on this platform — the stale-flock adoption branch is unreachable here"
else
# Build a dead pid guaranteed to not be recycled for the duration of this test.
sleep 0 & DEAD2=$!; wait "$DEAD2" 2>/dev/null || true
# Write the dead pid to the lock so the pre-flock check sees a stale holder.
printf '%s\n' "$DEAD2" > "$LOCK"
# Spawn an "orphan" that opens the lockfile, takes the flock, and holds it for 60s.
# Use a subshell so bash can wait on it cleanly. Two distinct layers: outer (gets the fd)
# and inner (holds it via flock 9), so "wait" on the outer process proves the inner is live.
ORPHAN_READY="$T/orphan-ready"
( exec 9>>"$LOCK"; flock 9 || exit 1; : > "$ORPHAN_READY"; sleep 60 ) &
ORPHAN=$!
trap 'kill "$LIVE" 2>/dev/null || true; kill "$ORPHAN" 2>/dev/null || true; rm -rf "$T"' EXIT
# READINESS HANDSHAKE, not a fixed sleep (HERD-450). This case asserts ACQUIRE, so if the orphan has
# not taken the flock yet the acquire succeeds for the WRONG reason and the case passes VACUOUSLY —
# it would stop covering the stale-flock adoption path entirely, on exactly the loaded/cold runners
# where a fixed sleep is least reliable. The orphan touches the marker only once flock(1) granted it.
_ok_i=0
while [ "$_ok_i" -lt 100 ] && [ ! -e "$ORPHAN_READY" ]; do sleep 0.1; _ok_i=$((_ok_i + 1)); done
[ -e "$ORPHAN_READY" ] || fail "(e) FIXTURE: the orphan never acquired the flock within 10s"
# Prove from OUTSIDE that the lock really is held, so the adoption below is a real adoption.
if flock -n "$LOCK" true 2>/dev/null; then
  fail "(e) FIXTURE: an outside flock -n SUCCEEDED — the orphan does not hold the lock, the case would be vacuous"
fi
# Verify the orphan is alive and holds a lock on the lockfile, otherwise the test is vacuous.
kill -0 "$ORPHAN" 2>/dev/null || fail "(e) orphan process unexpectedly dead before the test"
# The acquire must succeed despite the orphan holding the flock — stale-flock adoption.
[ "$(acquire)" = "ACQUIRE" ] || fail "(e) a launch with a dead recorded pid and an orphan-held flock must ADOPT (got REFUSE)"
# A subsequent acquire must also succeed (the new lock is on the fresh inode).
[ "$(acquire)" = "ACQUIRE" ] || fail "(e) second acquire after stale-flock adoption must also succeed"
# Clean up the orphan.
kill "$ORPHAN" 2>/dev/null || true
ok
echo "PASS (e) stale-flock adoption: dead recorded pid + orphan-held flock → ACQUIRE"
fi

echo "ALL PASS ($pass checks)"
