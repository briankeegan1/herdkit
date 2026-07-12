#!/usr/bin/env bash
# test-watcher-restart-loud-refuse.sh — hermetic regression for HERD-342: blocked watcher restart
# must fail LOUDLY instead of silently no-opping.
#
# Covers four scenarios:
#   (I)   LIVE lock holder → _acquire_watcher_singleton REFUSE: nonzero + loud stderr + journal event
#   (II)  Stale-flock adoption (leg b): bypass journal event carries holder info (Linux/flock only)
#   (III) Leg (a) — bin/herd post-restart verify: empty watch_pid (blocked) → loud error + nonzero
#   (IV)  Leg (a) — bin/herd post-restart verify: dead watch_pid → loud error + nonzero
#
# Run:  bash tests/test-watcher-restart-loud-refuse.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
HERD_BIN="$HERE/../bin/herd"

T="$(mktemp -d)"; pass=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { pass=$((pass + 1)); }

LIVE_PROCS=""
cleanup_test() {
  local p
  for p in $LIVE_PROCS; do kill -KILL "$p" 2>/dev/null || true; done
  rm -rf "$T"
}
trap 'cleanup_test' EXIT
track() { LIVE_PROCS="$LIVE_PROCS $1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
[ -f "$HERD_BIN" ] || fail "bin/herd not found at $HERD_BIN"

# ── Guaranteed-dead pid (spawn+reap before any test).
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null || true

# ── Source agent-watch.sh in lib mode.
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKSPACE_NAME="restart-loud-refuse-test"
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
LOCK="$T/.watcher.pid"
export HERD_WATCHER_LOCK="$LOCK"
JOURNAL="$T/journal.jsonl"; : > "$JOURNAL"
export JOURNAL_FILE="$JOURNAL"
# Stub out live tools so sourcing agent-watch.sh / bin/herd helpers don't touch real state.
BIN="$T/bin"; mkdir -p "$BIN"
for _cmd in gh git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$_cmd"; chmod +x "$BIN/$_cmd"
done
export PATH="$BIN:$PATH"

# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
# Re-pin after sourcing (herd-config.sh defaults may override).
export HERD_WATCHER_LOCK="$LOCK"
export JOURNAL_FILE="$JOURNAL"

type _acquire_watcher_singleton >/dev/null 2>&1 || fail "_acquire_watcher_singleton not defined"
type _watcher_singleton_refuse   >/dev/null 2>&1 || fail "_watcher_singleton_refuse not defined (HERD-342)"

# Helper: run _acquire_watcher_singleton in a subshell; echoes ACQUIRE or REFUSE.
acquire() {
  if ( _acquire_watcher_singleton >/dev/null 2>&1 ); then echo ACQUIRE; else echo REFUSE; fi
}

# ── (I) LIVE lock holder → REFUSE nonzero + loud stderr + journal watcher_restart_blocked ──────────
# A live holder: separate sleep process whose pid we write to the lockfile (no BASHPID, no flock).
sleep 300 &
FAKE_WORKER=$!; track "$FAKE_WORKER"
printf '%s\n' "$FAKE_WORKER" > "$LOCK"
kill -0 "$FAKE_WORKER" 2>/dev/null || fail "(I) fake worker unexpectedly dead"

: > "$JOURNAL"
_i_err="$T/i.err"; _i_rc=0
( _acquire_watcher_singleton >"$T/i.out" 2>"$_i_err" ) || _i_rc=$?

[ "$_i_rc" -ne 0 ] \
  || fail "(I.i) acquisition under a live lock must return NON-ZERO (got rc=$_i_rc)"
ok; echo "PASS (I.i) exits non-zero when lock holder is alive"

grep -q "already running" "$_i_err" \
  || fail "(I.ii) stderr must contain 'already running' (got: $(cat "$_i_err"))"
grep -qE "pid[[:space:]]*${FAKE_WORKER}|\\(pid ${FAKE_WORKER}\\)" "$_i_err" \
  || fail "(I.ii) stderr must name the holder pid $FAKE_WORKER (got: $(cat "$_i_err"))"
ok; echo "PASS (I.ii) stderr names the holder pid $FAKE_WORKER"

grep -q '"event".*"watcher_restart_blocked"' "$JOURNAL" \
  || fail "(I.iii) journal must contain watcher_restart_blocked event (got: $(cat "$JOURNAL"))"
grep -qE '"holder_pid"[[:space:]]*:[[:space:]]*"?'"${FAKE_WORKER}"'"?' "$JOURNAL" \
  || fail "(I.iii) journal must record holder_pid=$FAKE_WORKER (got: $(cat "$JOURNAL"))"
ok; echo "PASS (I.iii) watcher_restart_blocked journaled with holder_pid"

kill "$FAKE_WORKER" 2>/dev/null || true; rm -f "$LOCK"

# ── (II) Stale-flock adoption (leg b): bypass journal event (Linux + flock command only) ────────────
if command -v flock >/dev/null 2>&1; then
  printf '%s\n' "$DEAD" > "$LOCK"
  ( exec 9>>"$LOCK"; flock 9 2>/dev/null || true; sleep 60 ) &
  ORPHAN=$!; track "$ORPHAN"
  sleep 0.2
  kill -0 "$ORPHAN" 2>/dev/null || fail "(II) orphan unexpectedly dead"

  : > "$JOURNAL"
  [ "$(acquire)" = "ACQUIRE" ] \
    || fail "(II) stale-flock adoption must succeed (new inode after unlink)"
  ok; echo "PASS (II) stale-flock adoption ACQUIRES (HERD-344 path intact)"

  grep -q '"event".*"watcher_singleton_bypass"' "$JOURNAL" \
    || fail "(II) stale-flock adoption must journal watcher_singleton_bypass (got: $(cat "$JOURNAL"))"
  ok; echo "PASS (II) watcher_singleton_bypass journaled for bypass (leg b)"

  kill "$ORPHAN" 2>/dev/null || true
else
  echo "SKIP (II) flock command not available on this platform — stale-flock adoption test skipped"
fi
rm -f "$LOCK"

# ── (III/IV) Leg (a): bin/herd _watcher_restart_verify fires on empty and dead watch_pid ───────────
# Extract _watcher_restart_verify + its two helpers from bin/herd into a sourceable snippet.
grep -q "_watcher_restart_verify()" "$HERD_BIN" \
  || fail "(III) bin/herd is missing _watcher_restart_verify (HERD-342)"

{
  awk '/^_watcher_proc_start_ticks\(\) \{/{f=1} f{print} f&&/^\}/{f=0;exit}' "$HERD_BIN"
  awk '/^_watcher_lock_holder_msg\(\) \{/{f=1} f{print} f&&/^\}/{f=0;exit}' "$HERD_BIN"
  awk '/^_watcher_restart_verify\(\) \{/{f=1} f{print} f&&/^\}/{f=0;exit}' "$HERD_BIN"
} > "$T/leg_a.sh"
# Minimal stubs so the extracted functions work standalone.
c_red=""; c_rst=""
JOURNAL_FILE="$JOURNAL"
WORKSPACE_NAME="restart-loud-refuse-test"
export JOURNAL_FILE WORKSPACE_NAME c_red c_rst
# journal_append is already defined from sourcing agent-watch.sh above.
# shellcheck source=/dev/null
. "$T/leg_a.sh" || fail "(III) could not source extracted _watcher_restart_verify"

type _watcher_restart_verify >/dev/null 2>&1 || fail "(III) _watcher_restart_verify not defined after extraction"

# (III) empty watch_pid → BLOCKED (no live watcher after restart).
: > "$JOURNAL"
_iii_err="$T/iii.err"; _iii_rc=0
( _watcher_restart_verify "" "" "0" "herd reload" >"$T/iii.out" 2>"$_iii_err" ) || _iii_rc=$?
[ "$_iii_rc" -ne 0 ] \
  || fail "(III) _watcher_restart_verify with empty watch_pid must return NON-ZERO"
ok; echo "PASS (III) empty watch_pid → non-zero (blocked)"
grep -q "BLOCKED" "$_iii_err" \
  || fail "(III) stderr must contain BLOCKED (got: $(cat "$_iii_err"))"
ok; echo "PASS (III) empty watch_pid → BLOCKED on stderr"
grep -q '"event".*"watcher_restart_verify_failed"' "$JOURNAL" \
  || fail "(III) must journal watcher_restart_verify_failed (got: $(cat "$JOURNAL"))"
ok; echo "PASS (III) empty watch_pid → watcher_restart_verify_failed journaled"

# (IV) dead watch_pid → BLOCKED (no live watcher, proc is gone).
: > "$JOURNAL"
_iv_err="$T/iv.err"; _iv_rc=0
( _watcher_restart_verify "$DEAD" "" "0" "herd reload" >"$T/iv.out" 2>"$_iv_err" ) || _iv_rc=$?
[ "$_iv_rc" -ne 0 ] \
  || fail "(IV) _watcher_restart_verify with dead watch_pid must return NON-ZERO"
ok; echo "PASS (IV) dead watch_pid → non-zero (blocked)"
grep -q "BLOCKED" "$_iv_err" \
  || fail "(IV) stderr must contain BLOCKED (got: $(cat "$_iv_err"))"
ok; echo "PASS (IV) dead watch_pid → BLOCKED on stderr"

# (V) live, genuinely-new watch_pid → should succeed (NOT blocked).
sleep 300 &
NEW_WATCHER=$!; track "$NEW_WATCHER"
: > "$JOURNAL"
_v_rc=0
( _watcher_restart_verify "$NEW_WATCHER" "" "0" "herd reload" >/dev/null 2>&1 ) || _v_rc=$?
[ "$_v_rc" -eq 0 ] \
  || fail "(V) _watcher_restart_verify with a live new pid and empty pre_pid must return 0 (not blocked)"
ok; echo "PASS (V) live new watch_pid + empty pre_pid → success (not blocked)"
kill "$NEW_WATCHER" 2>/dev/null || true

echo "ALL PASS ($pass checks)"
