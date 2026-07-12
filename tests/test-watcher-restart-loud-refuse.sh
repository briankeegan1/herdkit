#!/usr/bin/env bash
# test-watcher-restart-loud-refuse.sh — hermetic regression for HERD-342: blocked watcher restart
# must fail LOUDLY instead of silently no-opping.
#
# Covers:
#   (I)   _acquire_watcher_singleton: LIVE lock holder → nonzero + loud stderr + journal event
#   (II)  Stale-flock adoption (leg b): bypass journal event carries holder info (flock platforms)
#   (III) Leg (a) — _watcher_restart_verify: same-pid case (old watcher survived) → BLOCKED
#   (IV)  Leg (a) — _watcher_restart_verify: empty/dead watch_pid → clean no-op (NOT blocked)
#   (V)   Leg (a) — _watcher_restart_verify: live new pid + empty pre → SUCCESS (not blocked)
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

# Guaranteed-dead pid.
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
# Stub live tools so sourcing doesn't touch real state.
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

acquire() {
  if ( _acquire_watcher_singleton >/dev/null 2>&1 ); then echo ACQUIRE; else echo REFUSE; fi
}

# ── (I) LIVE lock holder → REFUSE nonzero + loud stderr + journal watcher_restart_blocked ──────────
# Use a separate sleep process whose pid we write to the lockfile — no BASHPID, no flock needed.
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

# ── (II) Stale-flock adoption (leg b): bypass journal event (only on platforms with flock cmd) ──────
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
  echo "SKIP (II) flock command not available — stale-flock adoption test skipped"
fi
rm -f "$LOCK"

# ── (III/IV/V) Leg (a): _watcher_restart_verify fires on the right cases ─────────────────────────
# Extract the helpers we need from bin/herd into a sourceable snippet.
grep -q "_watcher_restart_verify()" "$HERD_BIN" \
  || fail "(III) bin/herd is missing _watcher_restart_verify (HERD-342)"

{
  awk '/^_watcher_proc_start_ticks\(\) \{/{f=1} f{print} f&&/^\}/{f=0;exit}' "$HERD_BIN"
  awk '/^_watcher_lock_holder_msg\(\) \{/{f=1} f{print} f&&/^\}/{f=0;exit}' "$HERD_BIN"
  awk '/^_watcher_restart_verify\(\) \{/{f=1} f{print} f&&/^\}/{f=0;exit}' "$HERD_BIN"
} > "$T/leg_a.sh"

# Minimal stubs so the extracted functions work standalone.
c_red=""; c_rst=""
export c_red c_rst
export JOURNAL_FILE="$JOURNAL"
export WORKSPACE_NAME="restart-loud-refuse-test"
export HERD_WATCHER_LOCK="$LOCK"
export WORKTREES_DIR="$T/trees"

# Stub watcher_pid_exempt (always returns 1 = "IS a watcher main / not a worker") for basic tests.
# Tests that need real worker detection override this.
watcher_pid_exempt() { return 1; }
export -f watcher_pid_exempt 2>/dev/null || true

# shellcheck source=/dev/null
. "$T/leg_a.sh" || fail "(III) could not source extracted helpers"
type _watcher_restart_verify >/dev/null 2>&1 \
  || fail "(III) _watcher_restart_verify not defined after extraction"

# (III) Same pid as pre → BLOCKED (old watcher survived stop — case i).
sleep 300 &
OLD_WATCHER=$!; track "$OLD_WATCHER"
printf '%s\n' "$OLD_WATCHER" > "$LOCK"
: > "$JOURNAL"
_iii_err="$T/iii.err"; _iii_rc=0
( _watcher_restart_verify "$OLD_WATCHER" "$OLD_WATCHER" "0" "herd reload" \
    >"$T/iii.out" 2>"$_iii_err" ) || _iii_rc=$?
[ "$_iii_rc" -ne 0 ] \
  || fail "(III) same-pid (old watcher survived) must return NON-ZERO"
ok; echo "PASS (III) same-pid → non-zero (old watcher survived stop)"
grep -q "BLOCKED" "$_iii_err" \
  || fail "(III) same-pid case must print BLOCKED (got: $(cat "$_iii_err"))"
ok; echo "PASS (III) same-pid → BLOCKED on stderr"
grep -q '"event".*"watcher_restart_verify_failed"' "$JOURNAL" \
  || fail "(III) must journal watcher_restart_verify_failed"
ok; echo "PASS (III) same-pid → watcher_restart_verify_failed journaled"
kill "$OLD_WATCHER" 2>/dev/null || true; rm -f "$LOCK"

# (IV) empty watch_pid → clean no-op, NOT blocked (hermetic env case that was false-positiving).
: > "$JOURNAL"
_iv_rc=0
( _watcher_restart_verify "" "" "0" "herd reload" >"$T/iv.out" 2>"$T/iv.err" ) || _iv_rc=$?
[ "$_iv_rc" -eq 0 ] \
  || fail "(IV) empty watch_pid must return 0 (clean no-op, not a blocked restart; got: $(cat "$T/iv.err"))"
ok; echo "PASS (IV) empty watch_pid → 0 (clean no-op, not blocked)"

# (V) dead watch_pid → clean no-op, NOT blocked.
_v_rc=0
( _watcher_restart_verify "$DEAD" "" "0" "herd reload" >"$T/v.out" 2>"$T/v.err" ) || _v_rc=$?
[ "$_v_rc" -eq 0 ] \
  || fail "(V) dead watch_pid must return 0 (not a blocked restart; got: $(cat "$T/v.err"))"
ok; echo "PASS (V) dead watch_pid → 0 (clean no-op, not blocked)"

# (VI) live new pid, no pre, no ticks → SUCCESS (the normal case after a successful restart).
sleep 300 &
NEW_WATCHER=$!; track "$NEW_WATCHER"
printf '%s\n' "$NEW_WATCHER" > "$LOCK"
_vi_rc=0
( _watcher_restart_verify "$NEW_WATCHER" "" "0" "herd reload" >/dev/null 2>&1 ) || _vi_rc=$?
[ "$_vi_rc" -eq 0 ] \
  || fail "(VI) live new pid with empty pre_pid must return 0 (successful restart)"
ok; echo "PASS (VI) live new pid + empty pre_pid → 0 (success)"
kill "$NEW_WATCHER" 2>/dev/null || true; rm -f "$LOCK"

echo "ALL PASS ($pass checks)"
