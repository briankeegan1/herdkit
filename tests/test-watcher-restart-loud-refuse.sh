#!/usr/bin/env bash
# test-watcher-restart-loud-refuse.sh — hermetic regression for HERD-342: blocked watcher restart
# must fail LOUDLY instead of silently no-opping.
#
# Scenario: a "fake worker" process PINS the singleton lock fd-9 and writes its pid to
# HERD_WATCHER_LOCK (simulating an orphaned gate worker that outlived the watcher main). A new
# watcher startup attempt via _acquire_watcher_singleton must:
#   (i)  exit NON-ZERO — never lie "restart succeeded" when it was blocked
#   (ii) print a LOUD row on stderr naming the holder pid
#   (iii) journal a watcher_restart_blocked event with holder_pid in the JOURNAL_FILE
#
# Also confirms the bypass journal event fires when stale-flock adoption succeeds (leg b).
#
# Run:  bash tests/test-watcher-restart-loud-refuse.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'cleanup_test' EXIT
pass=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { pass=$((pass + 1)); }

LIVE_PROCS=""
cleanup_test() {
  local p
  for p in $LIVE_PROCS; do
    kill -KILL "$p" 2>/dev/null || true
    kill -KILL "-$p" 2>/dev/null || true
  done
  rm -rf "$T"
}
track() { LIVE_PROCS="$LIVE_PROCS $1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# ── Source agent-watch.sh in lib mode (defines _acquire_watcher_singleton without starting the loop)
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKSPACE_NAME="restart-loud-refuse-test"
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
LOCK="$T/.watcher.pid"
export HERD_WATCHER_LOCK="$LOCK"
JOURNAL="$T/journal.jsonl"; : > "$JOURNAL"
export JOURNAL_FILE="$JOURNAL"
# Avoid live herdr/gh touching real state
BIN="$T/bin"; mkdir -p "$BIN"
for _cmd in gh git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$_cmd"; chmod +x "$BIN/$_cmd"
done
export PATH="$BIN:$PATH"

# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
# Re-pin after sourcing (herd-config.sh defaults may override):
export HERD_WATCHER_LOCK="$LOCK"
export JOURNAL_FILE="$JOURNAL"

type _acquire_watcher_singleton >/dev/null 2>&1 || fail "_acquire_watcher_singleton not defined"
type _watcher_singleton_refuse   >/dev/null 2>&1 || fail "_watcher_singleton_refuse not defined (HERD-342)"

# Helper: run _acquire_watcher_singleton in a subshell; echoes ACQUIRE or REFUSE.
acquire() {
  if ( _acquire_watcher_singleton >/dev/null 2>&1 ); then echo ACQUIRE; else echo REFUSE; fi
}

# ── (I) LIVE lock holder → REFUSE non-zero + LOUD stderr + journal watcher_restart_blocked ─────────
# Spawn a "fake worker" that writes its pid to the lockfile and holds flock on fd-9.
# Its argv0 is bash (not herd-watch-*), simulating an orphaned gate worker.
( exec 9>>"$LOCK"; flock 9; printf '%s\n' "$BASHPID" >"$LOCK"; sleep 300 ) &
FAKE_WORKER=$!; track "$FAKE_WORKER"
sleep 0.15   # let it take the flock and write its pid
kill -0 "$FAKE_WORKER" 2>/dev/null || fail "(I) fake worker unexpectedly dead"

# Clear the journal so we only see events from this acquisition attempt.
: > "$JOURNAL"

_i_err="$T/i.err"; _i_rc=0
( _acquire_watcher_singleton >"$T/i.out" 2>"$_i_err" ) || _i_rc=$?

# (i) must exit non-zero
[ "$_i_rc" -ne 0 ] || fail "(I) acquisition under a live lock must return NON-ZERO (got rc=$_i_rc)"
ok; echo "PASS (I.i) exits non-zero when lock holder is alive"

# (ii) stderr must name "already running" and the holder pid
grep -q "already running" "$_i_err" \
  || fail "(I.ii) stderr must contain 'already running' (got: $(cat "$_i_err"))"
grep -qE "pid[[:space:]]*${FAKE_WORKER}|\\(pid ${FAKE_WORKER}\\)" "$_i_err" \
  || fail "(I.ii) stderr must name the holder pid $FAKE_WORKER (got: $(cat "$_i_err"))"
ok; echo "PASS (I.ii) stderr names the holder pid $FAKE_WORKER"

# (iii) journal must have watcher_restart_blocked with the holder pid
sleep 0.05  # journal writes are async-but-fast
grep -q '"event".*"watcher_restart_blocked"' "$JOURNAL" \
  || fail "(I.iii) journal must contain watcher_restart_blocked event (got: $(cat "$JOURNAL"))"
grep -q "\"holder_pid\"" "$JOURNAL" \
  || fail "(I.iii) watcher_restart_blocked event must include holder_pid field"
ok; echo "PASS (I.iii) watcher_restart_blocked journaled with holder_pid"

# Also verify the holder pid in the journal matches the fake worker.
grep -qE "\"holder_pid\"[[:space:]]*:[[:space:]]*\"?${FAKE_WORKER}\"?" "$JOURNAL" \
  || fail "(I.iii) journal must record the fake worker's pid $FAKE_WORKER (got: $(cat "$JOURNAL"))"
ok; echo "PASS (I.iii) journal records correct holder pid"

# Clean up the fake worker; reset the lock for subsequent tests.
kill "$FAKE_WORKER" 2>/dev/null || true
sleep 0.1; rm -f "$LOCK"

# ── (II) Stale-flock adoption (leg b): bypass journal event carries holder info ─────────────────────
# A dead pid in the lockfile + an orphan holding fd-9 on the OLD inode → HERD-344 adoption.
# The adoption must journal watcher_singleton_bypass before unlinking.
sleep 0 & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null || true
printf '%s\n' "$DEAD_PID" > "$LOCK"
# Orphan holds fd-9 on the lockfile's inode and keeps it for 60s.
( exec 9>>"$LOCK"; flock 9; sleep 60 ) &
ORPHAN=$!; track "$ORPHAN"
sleep 0.15
kill -0 "$ORPHAN" 2>/dev/null || fail "(II) orphan unexpectedly dead"

: > "$JOURNAL"
# Adoption must succeed (new inode, fresh lock).
[ "$(acquire)" = "ACQUIRE" ] \
  || fail "(II) stale-flock adoption must succeed (new inode after unlink)"
ok; echo "PASS (II) stale-flock adoption ACQUIRES (HERD-344 path intact)"

grep -q '"event".*"watcher_singleton_bypass"' "$JOURNAL" \
  || fail "(II) stale-flock adoption must journal watcher_singleton_bypass (got: $(cat "$JOURNAL"))"
ok; echo "PASS (II) watcher_singleton_bypass journaled for bypass (leg b)"

kill "$ORPHAN" 2>/dev/null || true; rm -f "$LOCK"

echo "ALL PASS ($pass checks)"
