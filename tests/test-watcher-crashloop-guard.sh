#!/usr/bin/env bash
# test-watcher-crashloop-guard.sh — hermetic proof of HERD-548 leg 2: the pane wrapper's crash-loop
# hard stop (WATCHER_CRASHLOOP_GUARD, default off; scripts/herd/herd-watch.sh).
#
# GROUNDED 2026-08-05: post-reload the watcher crash-looped silently for ~2 minutes (repeated fast
# child pid churn, zero journal entry, zero console beyond the header) then self-resolved with nobody
# the wiser. This suite drives the REAL watch_wrapper_loop (sourced in lib mode) against REAL stub
# child scripts — never a mocked loop — asserting:
#
#   (1) helpers are defined after sourcing in lib mode
#   (2) N (default 3) CONSECUTIVE FAST deaths → the loop STOPS: exactly N invocations (never a 4th),
#       return 1, the last stderr is preserved (bounded) in the capture file, `watcher_crashloop` is
#       journaled with the right consecutive count, and the shared crash-loop marker trips
#   (3) a DELIBERATE STOP SIGNAL (rc=143, the SIGTERM shape `_stop_project_watcher` produces) on the
#       very first attempt ends the loop immediately: return 0, exactly ONE invocation, no marker, no
#       journal — the wrapper must never fight a deliberate stop
#   (4) a SLOW failure (survived past the fast threshold) RESETS the consecutive-fast counter: one
#       slow failure + (N-1) fast failures must NOT trip the loop; it takes N consecutive fast ones
#       counted fresh from the reset
#   (5) the stderr capture file is BOUNDED to HERD_WATCH_CRASH_TAIL_LINES even when the child is noisy
#   (6) the DEFAULT (WATCHER_CRASHLOOP_GUARD unset/off) real end-to-end launch is a bare, single-shot
#       exec — one invocation only, no capture file, no marker, no journal, exit code passed through
#
# No herdr, no gh, no network. Run:  bash tests/test-watcher-crashloop-guard.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/scripts/herd/herd-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { pass=$((pass + 1)); }

[ -f "$SCRIPT" ] || fail "herd-watch.sh not found at $SCRIPT"

PROJ="$T/proj"; mkdir -p "$PROJ/.herd" "$T/trees"
cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$T/trees"
WORKSPACE_NAME="crashloop-test"
EOF

BIN="$T/bin"; mkdir -p "$BIN"

# ── (1) source in lib mode ───────────────────────────────────────────────────────────────────────
export HERD_WATCH_WRAPPER_LIB=1
export HERD_CONFIG_FILE="$PROJ/.herd/config"
JOURNAL="$T/journal.jsonl"
export JOURNAL_FILE="$JOURNAL"
# shellcheck source=/dev/null
. "$SCRIPT" || fail "sourcing herd-watch.sh (lib mode) failed"
for fn in watch_wrapper_loop _watch_wrapper_is_stop_signal_rc _watch_wrapper_bound_capture _watch_wrapper_lock_taken; do
  type "$fn" >/dev/null 2>&1 || fail "(1) $fn not defined after sourcing"
done
declare -f watcher_crashloop_active >/dev/null 2>&1 || fail "(1) watcher_crashloop_active (watcher-exempt.sh) not in scope"
ORIG_LOCK="$HERD_WATCHER_LOCK"
ok
echo "PASS (1) wrapper helpers load in lib mode"

reset() {
  rm -f "$JOURNAL"; : > "$JOURNAL"
  rm -f "$T"/attempts-* "$T"/capture-*
  declare -f watcher_crashloop_clear >/dev/null 2>&1 && watcher_crashloop_clear
}

# ── (2) N consecutive fast deaths → stop, preserve stderr, journal, trip marker ─────────────────────
reset
FAST_STUB="$BIN/fast-fail.sh"
COUNTER_2="$T/attempts-2"
cat > "$FAST_STUB" <<EOF
#!/usr/bin/env bash
c=0; [ -f "$COUNTER_2" ] && c=\$(cat "$COUNTER_2")
c=\$((c + 1)); printf '%s' "\$c" > "$COUNTER_2"
echo "fatal: synthetic crash #\$c" >&2
exit 7
EOF
chmod +x "$FAST_STUB"

export HERD_WATCH_CHILD_SCRIPT="$FAST_STUB"
export HERD_WATCH_CRASHLOOP_N=3
export HERD_WATCH_CRASHLOOP_FAST_SECS=5
export HERD_WATCH_CRASH_TAIL_LINES=80
CAPTURE_2="$T/capture-2"
export HERD_WATCH_CRASH_CAPTURE="$CAPTURE_2"

rc=0
watch_wrapper_loop || rc=$?
[ "$rc" -eq 1 ] || fail "(2) loop must return 1 once the crash loop trips (got $rc)"
ok
[ "$(cat "$COUNTER_2")" = "3" ] || fail "(2) child must run exactly 3 times, never a 4th (got $(cat "$COUNTER_2"))"
ok
grep -q "synthetic crash #3" "$CAPTURE_2" || fail "(2) capture file must preserve the LAST attempt's stderr (got: $(cat "$CAPTURE_2" 2>/dev/null))"
ok
grep -q '"watcher_crashloop"' "$JOURNAL" || fail "(2) journal must contain watcher_crashloop (got: $(cat "$JOURNAL"))"
grep -q '"consecutive"[[:space:]]*:[[:space:]]*3' "$JOURNAL" || fail "(2) journal must record consecutive=3 (got: $(cat "$JOURNAL"))"
ok
watcher_crashloop_active || fail "(2) the shared crash-loop marker must be tripped"
ok
echo "PASS (2) 3 consecutive fast deaths → stop respawn, preserve stderr, journal, trip marker"

# ── (3) deliberate stop signal on first attempt → immediate clean stop, never fought ────────────────
reset
STOP_STUB="$BIN/stop-signal.sh"
COUNTER_3="$T/attempts-3"
cat > "$STOP_STUB" <<EOF
#!/usr/bin/env bash
c=0; [ -f "$COUNTER_3" ] && c=\$(cat "$COUNTER_3")
c=\$((c + 1)); printf '%s' "\$c" > "$COUNTER_3"
exit 143
EOF
chmod +x "$STOP_STUB"
export HERD_WATCH_CHILD_SCRIPT="$STOP_STUB"
CAPTURE_3="$T/capture-3"; export HERD_WATCH_CRASH_CAPTURE="$CAPTURE_3"

rc=0
watch_wrapper_loop || rc=$?
[ "$rc" -eq 0 ] || fail "(3) a deliberate stop signal must return 0 (got $rc)"
ok
[ "$(cat "$COUNTER_3")" = "1" ] || fail "(3) a deliberate stop must NEVER be respawned (ran $(cat "$COUNTER_3") times)"
ok
watcher_crashloop_active && fail "(3) a deliberate stop must never trip the crash-loop marker"
ok
[ ! -s "$JOURNAL" ] || fail "(3) a deliberate stop must never journal watcher_crashloop (got: $(cat "$JOURNAL"))"
ok
echo "PASS (3) deliberate stop signal (rc=143, the narrow pre-trap-install window) ends the loop, never fought, never journaled"

# ── (3b) THE REAL SHAPE (review fix): a REAL SIGTERM delivered to a stub that traps it exactly like
# agent-watch.sh does (`trap '...; exit 1' INT TERM`) must ALSO be recognized as a deliberate stop —
# rc 1, not 143. This is the actual code path `_stop_project_watcher` produces in production (it sends
# a bare SIGTERM via `_watcher_term_verified`, and agent-watch.sh's own trap turns that into exit 1),
# and the bug this case was written to catch: an earlier cut of _watch_wrapper_is_stop_signal_rc
# recognized only 129/130/143 and therefore RESPAWNED right after a real stop — the exact
# duplicate-watcher singleton race (HERD-266/450) this feature exists to prevent.
reset
STOPTRAP_STUB="$BIN/stop-trap-realistic.sh"
COUNTER_3B="$T/attempts-3b"
STOPTRAP_PIDFILE="$T/stoptrap-pid"
rm -f "$STOPTRAP_PIDFILE"
cat > "$STOPTRAP_STUB" <<EOF
#!/usr/bin/env bash
c=0; [ -f "$COUNTER_3B" ] && c=\$(cat "$COUNTER_3B")
c=\$((c + 1)); printf '%s' "\$c" > "$COUNTER_3B"
trap 'exit 1' INT TERM
printf '%s' \$\$ > "$STOPTRAP_PIDFILE"
# A SHORT-interval loop, not one long blocking \`sleep 100\` — bash famously does NOT interrupt a
# trap-bearing process's CURRENT foreground wait() for a signal; the trap only runs once that
# foreground command returns. A single 100s sleep would defer the trap for the full 100s (needing
# SIGKILL to prove anything in a test), which is NOT how the real watcher behaves: agent-watch.sh's
# own tick loop blocks in a 4s \`sleep\` between iterations, so a real SIGTERM is deferred for at most
# ~4s, never effectively forever. This loop mirrors that shape.
while :; do sleep 0.2; done
EOF
chmod +x "$STOPTRAP_STUB"
export HERD_WATCH_CHILD_SCRIPT="$STOPTRAP_STUB"
CAPTURE_3B="$T/capture-3b"; export HERD_WATCH_CRASH_CAPTURE="$CAPTURE_3B"

( watch_wrapper_loop; echo "$?" > "$T/loop-rc-3b" ) &
LOOP_PID=$!
i=0
while [ ! -f "$STOPTRAP_PIDFILE" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -f "$STOPTRAP_PIDFILE" ] || fail "(3b) setup: the stub never reported its pid"
CHILD_PID="$(cat "$STOPTRAP_PIDFILE")"
kill -TERM "$CHILD_PID" 2>/dev/null || fail "(3b) setup: could not SIGTERM the stub"
wait "$LOOP_PID" 2>/dev/null
[ -f "$T/loop-rc-3b" ] || fail "(3b) the wrapper loop never finished"
[ "$(cat "$T/loop-rc-3b")" = "0" ] \
  || fail "(3b) a REAL SIGTERM against agent-watch.sh's own trap shape (rc=1) must return 0 (got $(cat "$T/loop-rc-3b"))"
ok
[ "$(cat "$COUNTER_3B")" = "1" ] \
  || fail "(3b) a real deliberate SIGTERM (rc=1) must NEVER be respawned — this is the singleton-race bug (ran $(cat "$COUNTER_3B") times)"
ok
watcher_crashloop_active && fail "(3b) a real deliberate stop must never trip the crash-loop marker"
ok
echo "PASS (3b) a REAL SIGTERM against agent-watch.sh's actual INT/TERM trap shape (rc=1) is recognized as a deliberate stop — never respawned"

# ── (3c) rc=1 with NO signal at all (the live-singleton-lock refusal shape, `_acquire_watcher_singleton
# || exit 1`) must ALSO never respawn — "another main is already up" means the same thing as a stop.
reset
REFUSE_STUB="$BIN/singleton-refuse.sh"
COUNTER_3C="$T/attempts-3c"
cat > "$REFUSE_STUB" <<EOF
#!/usr/bin/env bash
c=0; [ -f "$COUNTER_3C" ] && c=\$(cat "$COUNTER_3C")
c=\$((c + 1)); printf '%s' "\$c" > "$COUNTER_3C"
echo "herd-watch: already running (pid 12345) — refusing duplicate" >&2
exit 1
EOF
chmod +x "$REFUSE_STUB"
export HERD_WATCH_CHILD_SCRIPT="$REFUSE_STUB"
CAPTURE_3C="$T/capture-3c"; export HERD_WATCH_CRASH_CAPTURE="$CAPTURE_3C"
rc=0
watch_wrapper_loop || rc=$?
[ "$rc" -eq 0 ] || fail "(3c) a bare exit 1 (singleton-refusal shape) must return 0 (got $rc)"
ok
[ "$(cat "$COUNTER_3C")" = "1" ] || fail "(3c) a singleton refusal must never be respawned (ran $(cat "$COUNTER_3C") times)"
ok
echo "PASS (3c) a bare exit 1 (the live-singleton-lock refusal shape) is never respawned"

# ── (3d) rc=137 (128+SIGKILL, _watcher_term_verified's escalation) must also never respawn ──────────
reset
KILL_STUB="$BIN/sigkill-shape.sh"
COUNTER_3D="$T/attempts-3d"
cat > "$KILL_STUB" <<EOF
#!/usr/bin/env bash
c=0; [ -f "$COUNTER_3D" ] && c=\$(cat "$COUNTER_3D")
c=\$((c + 1)); printf '%s' "\$c" > "$COUNTER_3D"
exit 137
EOF
chmod +x "$KILL_STUB"
export HERD_WATCH_CHILD_SCRIPT="$KILL_STUB"
CAPTURE_3D="$T/capture-3d"; export HERD_WATCH_CRASH_CAPTURE="$CAPTURE_3D"
rc=0
watch_wrapper_loop || rc=$?
[ "$rc" -eq 0 ] || fail "(3d) rc=137 (SIGKILL escalation shape) must return 0 (got $rc)"
ok
[ "$(cat "$COUNTER_3D")" = "1" ] || fail "(3d) rc=137 must never be respawned (ran $(cat "$COUNTER_3D") times)"
ok
echo "PASS (3d) rc=137 (the SIGKILL escalation shape) is never respawned"

# ── (3e) belt-and-suspenders: a LIVE watcher already holds the lock → never respawn regardless of rc ─
# Simulates a concurrent relaunch (another cmd_pane_watch/cmd_reload invocation) beating us to it in
# the gap since our child died — even a genuine-looking crash exit code must not respawn on top of it.
reset
sleep 100 & OTHER_LIVE_WATCHER=$!
OTHER_LOCK="$T/other-watcher.pid"
printf '%s\n' "$OTHER_LIVE_WATCHER" > "$OTHER_LOCK"
export HERD_WATCHER_LOCK="$OTHER_LOCK"
CRASHY_STUB="$BIN/crashy-someone-else-alive.sh"
COUNTER_3E="$T/attempts-3e"
cat > "$CRASHY_STUB" <<EOF
#!/usr/bin/env bash
c=0; [ -f "$COUNTER_3E" ] && c=\$(cat "$COUNTER_3E")
c=\$((c + 1)); printf '%s' "\$c" > "$COUNTER_3E"
exit 7
EOF
chmod +x "$CRASHY_STUB"
export HERD_WATCH_CHILD_SCRIPT="$CRASHY_STUB"
CAPTURE_3E="$T/capture-3e"; export HERD_WATCH_CRASH_CAPTURE="$CAPTURE_3E"
rc=0
watch_wrapper_loop || rc=$?
[ "$rc" -eq 0 ] || fail "(3e) a lock already held by another live watcher must return 0 (got $rc)"
ok
[ "$(cat "$COUNTER_3E")" = "1" ] \
  || fail "(3e) must never respawn while another live watcher holds the lock (ran $(cat "$COUNTER_3E") times)"
ok
kill -9 "$OTHER_LIVE_WATCHER" 2>/dev/null || true
export HERD_WATCHER_LOCK="$ORIG_LOCK"
echo "PASS (3e) a live watcher already holding the lock is never doubled, regardless of the child's exit code"

# ── (4) a slow failure resets the consecutive-fast counter ──────────────────────────────────────────
reset
SLOW_STUB="$BIN/slow-then-fast.sh"
COUNTER_4="$T/attempts-4"
cat > "$SLOW_STUB" <<EOF
#!/usr/bin/env bash
c=0; [ -f "$COUNTER_4" ] && c=\$(cat "$COUNTER_4")
c=\$((c + 1)); printf '%s' "\$c" > "$COUNTER_4"
if [ "\$c" -eq 1 ]; then sleep 3; fi
echo "attempt \$c" >&2
exit 9
EOF
chmod +x "$SLOW_STUB"
export HERD_WATCH_CHILD_SCRIPT="$SLOW_STUB"
export HERD_WATCH_CRASHLOOP_N=2
# A wide margin (3s sleep vs a 1s threshold) — $SECONDS is whole-second granularity, and a tighter
# margin (e.g. 1.5s) flaked under load: process-spawn overhead alone can eat several hundred ms, and
# a slow CI box can round the elapsed time across the threshold either way.
export HERD_WATCH_CRASHLOOP_FAST_SECS=1
CAPTURE_4="$T/capture-4"; export HERD_WATCH_CRASH_CAPTURE="$CAPTURE_4"

rc=0
watch_wrapper_loop || rc=$?
[ "$rc" -eq 1 ] || fail "(4) loop must eventually trip once 2 CONSECUTIVE fast deaths follow the reset (got $rc)"
ok
# 1 slow (not counted) + 2 fast (trips at N=2) == 3 total invocations.
[ "$(cat "$COUNTER_4")" = "3" ] || fail "(4) expected exactly 3 invocations (1 slow reset + 2 fast to trip), got $(cat "$COUNTER_4")"
ok
echo "PASS (4) a slow failure resets the consecutive-fast counter instead of counting toward the trip"

# ── (5) stderr capture is bounded ────────────────────────────────────────────────────────────────
reset
NOISY_STUB="$BIN/noisy-fail.sh"
COUNTER_5="$T/attempts-5"
cat > "$NOISY_STUB" <<EOF
#!/usr/bin/env bash
c=0; [ -f "$COUNTER_5" ] && c=\$(cat "$COUNTER_5")
c=\$((c + 1)); printf '%s' "\$c" > "$COUNTER_5"
i=0; while [ "\$i" -lt 500 ]; do echo "noisy line \$i (attempt \$c)" >&2; i=\$((i+1)); done
exit 7
EOF
chmod +x "$NOISY_STUB"
export HERD_WATCH_CHILD_SCRIPT="$NOISY_STUB"
export HERD_WATCH_CRASHLOOP_N=1
export HERD_WATCH_CRASHLOOP_FAST_SECS=5
export HERD_WATCH_CRASH_TAIL_LINES=10
CAPTURE_5="$T/capture-5"; export HERD_WATCH_CRASH_CAPTURE="$CAPTURE_5"

rc=0
watch_wrapper_loop || rc=$?
[ "$rc" -eq 1 ] || fail "(5) loop must trip on the very first fast death when N=1 (got $rc)"
ok
lines="$(wc -l < "$CAPTURE_5" 2>/dev/null | tr -d ' ')"
[ "$lines" -le 10 ] || fail "(5) capture file must be bounded to HERD_WATCH_CRASH_TAIL_LINES=10 (got $lines lines)"
ok
grep -q "noisy line 499" "$CAPTURE_5" || fail "(5) the bounded tail must keep the MOST RECENT lines (got: $(cat "$CAPTURE_5")))"
ok
echo "PASS (5) stderr capture is bounded to HERD_WATCH_CRASH_TAIL_LINES, keeping the most recent lines"

unset HERD_WATCH_CHILD_SCRIPT HERD_WATCH_CRASHLOOP_N HERD_WATCH_CRASHLOOP_FAST_SECS HERD_WATCH_CRASH_TAIL_LINES HERD_WATCH_CRASH_CAPTURE

# ── (6) DEFAULT (off) real end-to-end launch: bare single-shot exec ─────────────────────────────────
reset
unset HERD_WATCH_WRAPPER_LIB
DEFAULT_STUB="$BIN/default-fail.sh"
COUNTER_6="$T/attempts-6"
cat > "$DEFAULT_STUB" <<EOF
#!/usr/bin/env bash
c=0; [ -f "$COUNTER_6" ] && c=\$(cat "$COUNTER_6")
c=\$((c + 1)); printf '%s' "\$c" > "$COUNTER_6"
exit 42
EOF
chmod +x "$DEFAULT_STUB"

out="$(HERD_CONFIG_FILE="$PROJ/.herd/config" JOURNAL_FILE="$JOURNAL" HERD_WATCH_CHILD_SCRIPT="$DEFAULT_STUB" \
  bash "$SCRIPT" 2>&1)"
rc=$?
[ "$rc" -eq 42 ] || fail "(6) default OFF must pass the child's exit code straight through (got $rc)"
ok
[ "$(cat "$COUNTER_6")" = "1" ] || fail "(6) default OFF must be single-shot — never retried (ran $(cat "$COUNTER_6") times)"
ok
[ ! -s "$JOURNAL" ] || fail "(6) default OFF must never journal anything from the wrapper (got: $(cat "$JOURNAL"))"
ok
echo "PASS (6) default OFF is a bare single-shot exec — no retry, no capture, no marker, no journal"

echo "ALL PASS ($pass checks)"
