#!/usr/bin/env bash
# test-watcher-resurrect.sh — hermetic MUTATION-PROOF for the external-cadence watcher resurrection
# probe (WATCHER_RESURRECT, default off; scripts/herd/watcher-resurrect.sh; HERD-489).
#
# Drives the REAL watcher_singleton_verdict (watcher-exempt.sh, HERD-450) against REAL backgrounded
# processes standing in for "the watcher" — a genuine kill/liveness proof, not a mocked verdict —
# while the relaunch leg is stubbed via a fake `herd` on PATH (the same PATH-first resolution
# run_backend_mode uses in backlog-view.sh) so the test never spawns a real herdr pane or touches
# this repo's own live watcher.
#
# Asserts:
#   (1) helpers exist after sourcing in lib mode
#   (2) DEFAULT OFF is byte-inert: even with ZERO live mains, the probe never calls `herd reload`,
#       never journals, exits 0
#   (3) explicit OFF is byte-inert too
#   (4) ON + a LIVE watcher (a real backgrounded process holding the lockfile, state OK) is NEVER
#       touched: no relaunch call, no journal write, the live process survives untouched — NEVER
#       DOUBLED
#   (5) ON + ZERO live mains (state NONE) → RESURRECTED: exactly one `herd reload` call, journals
#       watcher_resurrect_detected then watcher_resurrected with the new pid, and a REAL live
#       process now holds the lockfile
#   (6) running the probe AGAIN against that now-live replacement is A COMPLETE NO-OP: no second
#       `herd reload` call, no additional journal rows — NEVER DOUBLED, the mirror of (4) starting
#       from a resurrection instead of an original watcher
#   (7) a relaunch that leaves no live pid journals watcher_resurrect_failed and exits 1 (the cron
#       job's own failure signal)
#
# NETWORK-FREE, no herdr, no gh. Spawns only `sleep` as stand-ins for "a watcher process", each one
# fd-closed + exec'd (HERD-462) and tracked for a forced reap in the EXIT trap.
# Run:  bash tests/test-watcher-resurrect.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/watcher-resurrect.sh"

T="$(mktemp -d)"

# HERD-462: bats-core dup's a live pipe onto a high fd (its own "ok N …" aggregator) before running
# each test; a backgrounded stand-in process inherits that fd unless it explicitly closes it, and
# keeps the WRITE end open long after this test finishes — bats then blocks forever on a read() that
# never sees EOF, wedging the whole run behind one leaked child even though every test itself
# reported "ok" (see tests/test-cli-reload.sh's `_bg_close_fds` for the original writeup). Close the
# whole high-fd range and always `exec` into the final command (never leave a plain forked child), so
# a lone `kill` fully reaps it.
_bg_close_fds() {
  local fd
  for fd in $(seq 3 255); do eval "exec $fd>&-" 2>/dev/null; done
}
_BG_PIDS=""
_bg_track() { _BG_PIDS="$_BG_PIDS $1"; }
cleanup() {
  local p
  for p in $_BG_PIDS; do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$T"
}
trap cleanup EXIT

pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$SCRIPT" ] || fail "watcher-resurrect.sh not found at $SCRIPT"

# spawn_stub_process — start a real long-lived background process and remember its pid for cleanup,
# in $SPAWN_PID. Deliberately NOT called via `$(...)` — backgrounding inside a command-substitution
# subshell orphans the job to a subshell that exits (and reaps it) before the caller can observe it
# alive, which is a real bash gotcha, not a herdkit one. Called directly at top level instead.
spawn_stub_process() {
  ( _bg_close_fds; exec sleep 100 ) &
  SPAWN_PID=$!
  _bg_track "$SPAWN_PID"
}

# ── Stub `herd` on PATH ───────────────────────────────────────────────────────────────────────────
# reload → logs the call, then simulates the VERIFIED relaunch by spawning a real detached process
# and recording its pid in the lockfile — exactly the observable outcome `herd reload`'s own
# background fallback produces, without exercising the real (herdr/pane-dependent) machinery here.
# It closes its own high fds before backgrounding (same HERD-462 reason as _bg_close_fds above) —
# this stub is a SEPARATE process invoked by watcher-resurrect.sh, so it inherits the same bats fds.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herd" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  reload)
    [ -n "${STUB_HERD_CALL_LOG:-}" ] && printf 'reload\n' >> "$STUB_HERD_CALL_LOG"
    if [ "${STUB_RELOAD_SUCCEEDS:-1}" = "1" ]; then
      ( for fd in $(seq 3 255); do eval "exec $fd>&-" 2>/dev/null; done
        exec sleep 100 ) & echo $! > "${STUB_WATCHER_LOCK:-/dev/null}"
    fi
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herd"
export PATH="$BIN:$PATH"

CALL_LOG="$T/herd-calls.log"
export STUB_HERD_CALL_LOG="$CALL_LOG"
call_count() { [ -f "$CALL_LOG" ] && grep -c . "$CALL_LOG" 2>/dev/null || printf 0; }

# ── Source watcher-resurrect.sh in lib mode ──────────────────────────────────────────────────────
export WATCHER_RESURRECT_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export WORKSPACE_NAME="resurrecttest"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"
# shellcheck source=/dev/null
. "$SCRIPT" || fail "sourcing watcher-resurrect.sh (lib mode) failed"

# ── (1) helpers defined ───────────────────────────────────────────────────────────────────────────
for fn in watcher_resurrect_enabled watcher_resurrect_probe watcher_resurrect_herd_bin; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
declare -f watcher_singleton_verdict >/dev/null 2>&1 || fail "watcher_singleton_verdict (watcher-exempt.sh) not in scope"
[ -n "${HERD_WATCHER_LOCK:-}" ] || fail "HERD_WATCHER_LOCK must be set by herd-config.sh"
mkdir -p "$(dirname "$HERD_WATCHER_LOCK")" 2>/dev/null || true
export STUB_WATCHER_LOCK="$HERD_WATCHER_LOCK"
ok

reset_state() { rm -f "$HERD_WATCHER_LOCK" "$JOURNAL_FILE" "$CALL_LOG"; }

# ── (2) DEFAULT OFF is byte-inert, even against ZERO live mains ─────────────────────────────────
reset_state
unset WATCHER_RESURRECT
watcher_resurrect_probe
rc=$?
[ "$rc" -eq 0 ] || fail "2: OFF (unset) must exit 0 (got $rc)"
ok
[ "$(call_count)" -eq 0 ] || fail "2: OFF (unset) must never call herd reload"
ok
[ ! -s "$JOURNAL_FILE" ] || fail "2: OFF (unset) must never journal anything"
ok

# ── (3) explicit OFF is byte-inert too ────────────────────────────────────────────────────────────
reset_state
WATCHER_RESURRECT=off watcher_resurrect_probe
rc=$?
[ "$rc" -eq 0 ] || fail "3: OFF (explicit) must exit 0 (got $rc)"
ok
[ "$(call_count)" -eq 0 ] || fail "3: OFF (explicit) must never call herd reload"
ok

export WATCHER_RESURRECT=on   # from here on the probe is opted in

# ── (4) ON + a LIVE watcher is NEVER touched — never doubled ────────────────────────────────────
reset_state
spawn_stub_process
LIVE_PID="$SPAWN_PID"
printf '%s\n' "$LIVE_PID" > "$HERD_WATCHER_LOCK"
verdict="$(watcher_singleton_verdict)"
case "$verdict" in OK*) : ;; *) fail "4: precondition failed — expected state OK, got: $verdict" ;; esac
watcher_resurrect_probe
rc=$?
[ "$rc" -eq 0 ] || fail "4: a live watcher must yield exit 0 (got $rc)"
ok
[ "$(call_count)" -eq 0 ] || fail "4: a live watcher must NEVER trigger herd reload"
ok
[ ! -s "$JOURNAL_FILE" ] || fail "4: a live watcher must never be journaled as a resurrection"
ok
kill -0 "$LIVE_PID" 2>/dev/null || fail "4: the live watcher process must survive untouched"
ok
[ "$(cat "$HERD_WATCHER_LOCK")" = "$LIVE_PID" ] || fail "4: the lockfile must still name the same live pid (no double-spawn)"
ok
kill -9 "$LIVE_PID" 2>/dev/null || true

# ── (5) ON + ZERO live mains → RESURRECTED ────────────────────────────────────────────────────────
reset_state
verdict="$(watcher_singleton_verdict)"
case "$verdict" in NONE*) : ;; *) fail "5: precondition failed — expected state NONE, got: $verdict" ;; esac
export STUB_RELOAD_SUCCEEDS=1
watcher_resurrect_probe
rc=$?
[ "$rc" -eq 0 ] || fail "5: a successful resurrection must exit 0 (got $rc)"
ok
[ "$(call_count)" -eq 1 ] || fail "5: a confirmed-dead watcher must trigger EXACTLY ONE herd reload call (got $(call_count))"
ok
grep -q '"event":"watcher_resurrect_detected"' "$JOURNAL_FILE" || fail "5: watcher_resurrect_detected must be journaled"
ok
grep -q '"event":"watcher_resurrected"' "$JOURNAL_FILE" || fail "5: watcher_resurrected must be journaled"
ok
[ -f "$HERD_WATCHER_LOCK" ] || fail "5: the lockfile must now exist"
ok
NEW_PID="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
_bg_track "$NEW_PID"
kill -0 "$NEW_PID" 2>/dev/null || fail "5: the resurrected pid must be a REAL live process"
ok
# journal.sh emits an integer-looking value as a bare JSON number (pid), never a quoted string.
grep -q "\"pid\":$NEW_PID" "$JOURNAL_FILE" || fail "5: watcher_resurrected must record the new pid"
ok

# ── (6) running the probe AGAIN against the resurrected watcher is a no-op — never doubled ───────
calls_before="$(call_count)"
lines_before="$(grep -c . "$JOURNAL_FILE" 2>/dev/null || printf 0)"
verdict="$(watcher_singleton_verdict)"
case "$verdict" in OK*) : ;; *) fail "6: precondition failed — the resurrected watcher should read OK, got: $verdict" ;; esac
watcher_resurrect_probe
rc=$?
[ "$rc" -eq 0 ] || fail "6: a re-probe of a healthy resurrection must exit 0 (got $rc)"
ok
[ "$(call_count)" -eq "$calls_before" ] || fail "6: a re-probe must NOT call herd reload again (double-spawn)"
ok
[ "$(grep -c . "$JOURNAL_FILE" 2>/dev/null || printf 0)" -eq "$lines_before" ] || fail "6: a re-probe must not add journal rows"
ok
[ "$(cat "$HERD_WATCHER_LOCK")" = "$NEW_PID" ] || fail "6: the lockfile must still name the SAME resurrected pid"
ok
kill -9 "$NEW_PID" 2>/dev/null || true

# ── (7) a relaunch that fails to produce a live pid journals failure + exits 1 ───────────────────
reset_state
export STUB_RELOAD_SUCCEEDS=0
watcher_resurrect_probe
rc=$?
[ "$rc" -eq 1 ] || fail "7: a failed relaunch must exit 1 (got $rc)"
ok
grep -q '"event":"watcher_resurrect_failed"' "$JOURNAL_FILE" || fail "7: watcher_resurrect_failed must be journaled"
ok
[ ! -f "$HERD_WATCHER_LOCK" ] || fail "7: a failed relaunch must not fabricate a lockfile"
ok
unset STUB_RELOAD_SUCCEEDS

echo "ALL PASS ($pass checks)"
