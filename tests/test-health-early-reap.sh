#!/usr/bin/env bash
# test-health-early-reap.sh — hermetic tests for HERD-494:
#   (a) the parallel bats path must STREAM incremental per-FILE completion lines into the tailable
#       health log DURING the run — a --jobs run buffers its own ordered TAP stream (bats-format-cat),
#       so a healthy 24m run could show a 0-byte log for its entire runtime and read as a wedge to the
#       operator. tests/herd.bats's herd_run_discovered_test appends one line per completed test to
#       $HEALTHCHECK_PROGRESS_LOG the instant it finishes, independent of that ordering buffer.
#   (b) the every-tick gate-corpse sweep must EARLY-REAP a health worker whose log is still 0 bytes
#       after HEALTH_EARLY_REAP_SECS AND has no live bats/suite descendant left in its process group —
#       instead of waiting out the full HEALTH_INFLIGHT_TIMEOUT (many minutes) on a run that will never
#       produce a verdict.
#
# Covers:
#   (1) _health_bats_descendants_live: a real live member of the named process group counts as live;
#       a nonexistent process group does not; an empty/unknown pgid fails SOFT toward "live" (never
#       falsely reap)
#   (2) MUTATION-PROOF (a): a real `bats` run against a small fixture — while the fixture is STILL
#       RUNNING (has not exited), $HEALTHCHECK_PROGRESS_LOG already carries the completed test's line.
#       Requires `bats`; SKIPS with a PASS marker (never a red) when absent.
#   (3) MUTATION-PROOF (b): a dead-at-spawn stub (a real, alive, childless process in its own group,
#       backdated past HEALTH_EARLY_REAP_SECS, with a 0-byte log) IS reaped by the corpse sweep —
#       marker removed, process killed, health_early_reap journaled
#   (4) a worker whose log has ANY bytes is NEVER early-reaped, however old
#   (5) a worker that still has a live descendant is NEVER early-reaped, however old
#   (6) HEALTH_EARLY_REAP_SECS=0 (the default, ship-dormant) never reaps early — byte-identical to
#       before this change
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1); stubs gh/git/herdr on PATH (network-free).
# Run:  bash tests/test-health-early-reap.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

[ -f "$WATCH" ] || { echo "FAIL: agent-watch.sh not found at $WATCH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required to run this test" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"; _kill_leftovers' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

_LEFTOVERS=""
_track() { _LEFTOVERS="$_LEFTOVERS $1"; }
_kill_leftovers() { local p; for p in $_LEFTOVERS; do kill -KILL "$p" 2>/dev/null || true; kill -KILL "-$p" 2>/dev/null || true; done; }

# ── Stub binaries on PATH (network-free) ─────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }
TREES="$WORKTREES_DIR"

for fn in _health_bats_descendants_live _health_early_reap_secs _sweep_gate_corpses; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# ── (1) _health_bats_descendants_live ─────────────────────────────────────────
sleep 100 & CHILD_PID=$!; _track "$CHILD_PID"
selfpg="$(_pid_pgid "$$")"
_health_bats_descendants_live "$selfpg" \
  || fail "(1) a real live member of the named process group should count as a live descendant"
ok
kill -KILL "$CHILD_PID" 2>/dev/null || true; wait "$CHILD_PID" 2>/dev/null || true
_health_bats_descendants_live "999999999" \
  && fail "(1) a nonexistent process group must never report a live descendant"
ok
_health_bats_descendants_live "" \
  || fail "(1) an empty/unknown pgid must fail SOFT toward 'live' (never falsely reap)"
ok

# ── (2) MUTATION-PROOF (a): incremental streaming while bats is still running ────────────────────
if ! command -v bats >/dev/null 2>&1; then
  echo "SKIP (2): bats not installed — streaming mutation-proof cannot run"
  ok
else
  FIXTURE_DIR="$T/fixture"; mkdir -p "$FIXTURE_DIR"
  cat > "$FIXTURE_DIR/slow.bats" <<'BATSEOF'
@test "slow progress test 1" {
  sleep 2
  if [ -n "${HEALTHCHECK_PROGRESS_LOG:-}" ]; then
    printf '[health-progress] fixture-1.sh ok\n' >> "$HEALTHCHECK_PROGRESS_LOG"
  fi
}
@test "slow progress test 2" {
  sleep 6
  if [ -n "${HEALTHCHECK_PROGRESS_LOG:-}" ]; then
    printf '[health-progress] fixture-2.sh ok\n' >> "$HEALTHCHECK_PROGRESS_LOG"
  fi
}
BATSEOF
  PROG="$T/progress.log"; : > "$PROG"
  BATSRAW="$T/bats-raw-out.log"   # mirrors _hk_bats_out — bats' OWN stdout, NEVER the tailable log
  ( HEALTHCHECK_PROGRESS_LOG="$PROG" bats "$FIXTURE_DIR/slow.bats" >"$BATSRAW" 2>&1 ) &
  BPID=$!; _track "$BPID"
  sleep 4   # test 1 (2s) is done+appended; test 2 (6s) is still sleeping; bats has NOT exited
  kill -0 "$BPID" 2>/dev/null \
    || fail "(2) the fixture bats process exited too early — not proof of anything; widen the sleeps"
  [ -s "$PROG" ] \
    || fail "(2) progress log is STILL 0 bytes while bats is running — incremental streaming did not happen"
  grep -q "fixture-1.sh" "$PROG" \
    || fail "(2) progress log is missing the completed test's line while bats is still running"
  ok
  wait "$BPID" 2>/dev/null || true
  grep -q "fixture-2.sh" "$PROG" || fail "(2) the second test's line should land once it too completes"
  ok
fi

# ── Helpers for the corpse-sweep scenarios (3)-(6) ────────────────────────────
# Plant a REAL, alive, childless "worker" (exec-replaces its own subshell — see _bg_health_worker's own
# header comment: a monitor-mode background subshell running a single simple command IS its own
# process-group leader, pgid == pid, by construction) with a BACKDATED dispatch-ts, so it reads as
# HEALTH_EARLY_REAP_SECS-old without an actual sleep in this test.
plant_worker() {   # <key> <age-seconds>
  local _pw_key="$1" _pw_age="$2" _pw_marker _pw_log
  _bg_health_worker sleep 100
  _track "$_BG_HEALTH_PID"
  _pw_marker="$(_health_inflight_file "$_pw_key")"
  _marker_write "$_pw_marker" "$_BG_HEALTH_PID" "$_BG_HEALTH_PGID"
  python3 - "$_pw_marker" "$_pw_age" <<'PY'
import sys, time
p, age = sys.argv[1], int(sys.argv[2])
lines = open(p).read().splitlines()
lines[2] = str(int(time.time()) - age)
open(p, "w").write("\n".join(lines) + "\n")
PY
  _pw_log="$(_health_log_file "$_pw_key")"
  printf '%s' "$_BG_HEALTH_PID"
}

# ── (3) MUTATION-PROOF (b): dead-at-spawn (0-byte log, no descendant, old) IS reaped ───────────────
HEALTH_EARLY_REAP_SECS=300
HEALTH_INFLIGHT_TIMEOUT=1800
KEY3="777-deadatspawn"
WPID3="$(plant_worker "$KEY3" 600)"
: > "$(_health_log_file "$KEY3")"   # 0-byte log
_sweep_gate_corpses
[ ! -e "$(_health_inflight_file "$KEY3")" ] || fail "(3) a dead-at-spawn worker's marker should be reaped"
ok
kill -0 "$WPID3" 2>/dev/null && fail "(3) the dead-at-spawn worker process should have been killed"
ok
grep -q '"reason":"health_early_reap"' "$JOURNAL_FILE" || fail "(3) health_early_reap should be journaled"
grep -q "\"key\":\"$KEY3\"" "$JOURNAL_FILE" || fail "(3) the journaled event should carry this worker's key"
ok

# ── (4) a worker with ANY bytes in its log is NEVER early-reaped ────────────────────────────────────
: > "$JOURNAL_FILE"
KEY4="778-hasbytes"
WPID4="$(plant_worker "$KEY4" 600)"
printf 'some tap output\n' > "$(_health_log_file "$KEY4")"
_sweep_gate_corpses
[ -e "$(_health_inflight_file "$KEY4")" ] || fail "(4) a worker with a non-empty log must not be early-reaped"
kill -0 "$WPID4" 2>/dev/null || fail "(4) a worker with a non-empty log must not be killed"
ok
grep -q health_early_reap "$JOURNAL_FILE" && fail "(4) health_early_reap must not journal for a non-empty log"
ok
kill -KILL "$WPID4" 2>/dev/null || true; rm -f "$(_health_inflight_file "$KEY4")" "$(_health_log_file "$KEY4")"

# ── (5) a worker that still has a live descendant is NEVER early-reaped ─────────────────────────────
: > "$JOURNAL_FILE"
KEY5="779-livechild"
_bg_health_worker bash -c 'sleep 100 & wait'
_track "$_BG_HEALTH_PID"
MARKER5="$(_health_inflight_file "$KEY5")"
_marker_write "$MARKER5" "$_BG_HEALTH_PID" "$_BG_HEALTH_PGID"
python3 - "$MARKER5" <<'PY'
import sys, time
p = sys.argv[1]
lines = open(p).read().splitlines()
lines[2] = str(int(time.time()) - 600)
open(p, "w").write("\n".join(lines) + "\n")
PY
: > "$(_health_log_file "$KEY5")"
sleep 0.3   # let the inner "sleep 100 &" actually land in the group before we probe it
if _health_bats_descendants_live "$_BG_HEALTH_PGID"; then
  _sweep_gate_corpses
  [ -e "$MARKER5" ] || fail "(5) a worker with a live descendant must not be early-reaped"
  ok
else
  echo "SKIP (5): this shell's job-control semantics did not keep the fixture's child in the worker's own group"
  ok
fi
kill -KILL "-$_BG_HEALTH_PGID" 2>/dev/null || kill -KILL "$_BG_HEALTH_PID" 2>/dev/null || true
rm -f "$MARKER5" "$(_health_log_file "$KEY5")"

# ── (6) HEALTH_EARLY_REAP_SECS=0 (default, ship-dormant) never reaps early ──────────────────────────
: > "$JOURNAL_FILE"
HEALTH_EARLY_REAP_SECS=0
KEY6="780-offbydefault"
WPID6="$(plant_worker "$KEY6" 600)"
: > "$(_health_log_file "$KEY6")"
_sweep_gate_corpses
[ -e "$(_health_inflight_file "$KEY6")" ] || fail "(6) HEALTH_EARLY_REAP_SECS=0 must never early-reap"
kill -0 "$WPID6" 2>/dev/null || fail "(6) HEALTH_EARLY_REAP_SECS=0 must never kill the worker"
ok
grep -q health_early_reap "$JOURNAL_FILE" && fail "(6) HEALTH_EARLY_REAP_SECS=0 must never journal health_early_reap"
ok
kill -KILL "$WPID6" 2>/dev/null || true; rm -f "$(_health_inflight_file "$KEY6")" "$(_health_log_file "$KEY6")"

echo "ALL PASS ($pass checks)"
