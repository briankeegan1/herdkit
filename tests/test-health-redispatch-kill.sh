#!/usr/bin/env bash
# test-health-redispatch-kill.sh — hermetic tests for the HERD-283 health inflight-timeout FORK-BOMB
# guard. Grounded incident 2026-07-10: when a slow suite exceeded HEALTH_INFLIGHT_TIMEOUT, the corpse
# sweep `kill <worker-pid>`'d only the worker SUBSHELL and removed the marker, orphaning the suite's
# child processes while a fresh suite was dispatched — concurrent duplicate suites piled up on one
# worktree. The fix: dispatch each health worker into its OWN process group (_bg_health_worker) and, at
# the ONE shared kill seam (_health_terminate_worker) used by BOTH the timeout re-dispatch and the
# stale-sha discard, TERM → grace → KILL that whole group and verify it is gone BEFORE freeing the slot.
#
# Covers:
#   (1) the new seams are defined after sourcing
#   (2) _bg_health_worker puts the worker in its own process group (pgid == leader pid, != watcher pgid)
#   (3) _health_terminate_worker reaps the WHOLE recorded group — leader AND its children — and rc 0
#   (4) a WATCHER-IDENTITY pid (watcher_canonical_pid, from watcher-exempt.sh) is NEVER signaled → rc 1
#   (5) the watcher's own pid ($$) is never signaled → rc 1
#   (6) a dead/recycled marker is a no-op (nothing to signal) → rc 0
#   (7) the corpse sweep's health-TIMEOUT branch terminates the group BEFORE it frees the slot
#       (the marker is removed only once the worker subtree is verifiably gone)
#   (8) _discard_stale_health TERMINATES a superseded-sha worker (and leaves the current sha's untouched)
#   (9) BYTE-IDENTICAL marker: _marker_write with no pgid still writes exactly the legacy 3 lines
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1). Uses REAL short-lived processes in real process
# groups (no ps stubbing needed) under an isolated temp WORKTREES_DIR; stubs gh/git/herdr on PATH so
# nothing touches the network or the live control room. Run:  bash tests/test-health-redispatch-kill.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"; _kill_leftovers' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# Track any helper processes we spawn so a failed assertion never leaks a real `sleep` past the run.
_LEFTOVERS=""
_track() { _LEFTOVERS="$_LEFTOVERS $1"; }
_kill_leftovers() { local p; for p in $_LEFTOVERS; do kill -KILL "$p" 2>/dev/null || true; kill -KILL "-$p" 2>/dev/null || true; done; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

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
# Keep the grace loop near-instant so the tests never spend real wall-clock waiting on a doomed worker.
export HERD_HEALTH_TERM_SLEEP="0.02"
# No watcher lockfile by default (each test that needs one plants it explicitly).
unset HERD_WATCHER_LOCK 2>/dev/null || true
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }   # silence any intermediate frame

TREES="$WORKTREES_DIR"   # what _health_inflight_file / the sweep key off

# poll_gone <pid> — wait up to ~2s for <pid> to disappear; 0 iff gone.
poll_gone() { local p="$1" n=0; while [ "$n" -lt 100 ]; do kill -0 "$p" 2>/dev/null || return 0; sleep 0.02; n=$((n+1)); done; return 1; }
# poll_file <path> — wait up to ~2s for a file to appear; 0 iff it exists.
poll_file() { local f="$1" n=0; while [ "$n" -lt 100 ]; do [ -e "$f" ] && return 0; sleep 0.02; n=$((n+1)); done; return 1; }

# ── (1) seams defined ────────────────────────────────────────────────────────
for fn in _bg_health_worker _health_terminate_worker _marker_pgid _pid_pgid _health_term_sleep; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# A "fake suite": emulate `bash healthcheck.sh` forking a child that outlives a naive single-pid kill.
# It records its own grandchild's pid to $CHILDF so the group reap can be verified on the WHOLE subtree.
fake_suite() { sleep 300 & printf '%s\n' "$!" > "$CHILDF"; wait; }

# ── (2) _bg_health_worker → own process group ────────────────────────────────
export CHILDF="$T/child-2.pid"; : > "$CHILDF"
_bg_health_worker fake_suite
W2="$_BG_HEALTH_PID"; G2="$_BG_HEALTH_PGID"; _track "$W2"
[ -n "$W2" ] && [ -n "$G2" ] || fail "_bg_health_worker did not set pid/pgid"
[ "$G2" = "$W2" ] || fail "worker should LEAD its own group (pgid $G2 != leader pid $W2)"
selfpg="$(_pid_pgid "$$")"
[ "$G2" != "$selfpg" ] || fail "worker group ($G2) must not be the watcher's group ($selfpg)"
ok
# clean up (2)'s worker before the next test
poll_file "$CHILDF" || true; kill -KILL "-$G2" 2>/dev/null || true

# ── (3) terminate reaps the WHOLE group (leader + child) and returns 0 ────────
export CHILDF="$T/child-3.pid"; : > "$CHILDF"
_bg_health_worker fake_suite
W3="$_BG_HEALTH_PID"; G3="$_BG_HEALTH_PGID"; _track "$W3"
poll_file "$CHILDF" || fail "fake suite never recorded its child pid"
CHILD3="$(cat "$CHILDF")"; _track "$CHILD3"
kill -0 "$W3" 2>/dev/null    || fail "worker leader $W3 should be alive pre-kill"
kill -0 "$CHILD3" 2>/dev/null || fail "suite child $CHILD3 should be alive pre-kill"
M3="$(_health_inflight_file "31337-abc123")"
_marker_write "$M3" "$W3" "$G3"
[ "$(_marker_pgid "$M3")" = "$G3" ] || fail "marker did not record the pgid on line 4"
_health_terminate_worker "$M3"; rc=$?
[ "$rc" -eq 0 ] || fail "terminate should return 0 when the group is reaped (got $rc)"
poll_gone "$W3"    || fail "worker leader $W3 survived the group kill"
poll_gone "$CHILD3" || fail "suite CHILD $CHILD3 survived — single-pid kill leaked the subtree (the fork-bomb)"
ok

# ── (4) a watcher-identity pid is NEVER signaled ─────────────────────────────
# Plant a live 'watcher' and a lockfile naming it; a marker that (wrongly) records that pid must be
# refused by the watcher_canonical_pid guard — the watcher process survives, terminate returns 1.
sleep 300 & WPID=$!; disown %+ 2>/dev/null || true; _track "$WPID"
export HERD_WATCHER_LOCK="$T/watcher.lock"; printf '%s\n' "$WPID" > "$HERD_WATCHER_LOCK"
[ "$(watcher_canonical_pid)" = "$WPID" ] || fail "watcher_canonical_pid should resolve the live lock pid"
M4="$(_health_inflight_file "44-deadsha")"
_marker_write "$M4" "$WPID" "$WPID"
_health_terminate_worker "$M4"; rc=$?
[ "$rc" -eq 1 ] || fail "terminate must refuse a watcher-identity pid (expected rc 1, got $rc)"
kill -0 "$WPID" 2>/dev/null || fail "the watcher process was SIGNALED — the identity guard failed"
grep -q '"reason":"health_term_refused"' "$JOURNAL_FILE" 2>/dev/null \
  || grep -q 'health_term_refused' "$JOURNAL_FILE" 2>/dev/null \
  || fail "a refused terminate should journal health_term_refused"
kill -KILL "$WPID" 2>/dev/null || true
unset HERD_WATCHER_LOCK; rm -f "$T/watcher.lock" "$M4" 2>/dev/null || true
ok

# ── (5) the watcher's own pid ($$) is never signaled ─────────────────────────
M5="$(_health_inflight_file "55-selfsha")"
_marker_write "$M5" "$$" "$(_pid_pgid "$$")"
_health_terminate_worker "$M5"; rc=$?
[ "$rc" -eq 1 ] || fail "terminate must refuse \$\$ (expected rc 1, got $rc)"
rm -f "$M5" 2>/dev/null || true
ok

# ── (6) a dead/recycled marker is a no-op ────────────────────────────────────
sleep 0.05 & DPID=$!; wait "$DPID" 2>/dev/null || true   # DPID is now a DEAD pid
M6="$(_health_inflight_file "66-dead")"
_marker_write "$M6" "$DPID" "$DPID"
_health_terminate_worker "$M6"; rc=$?
[ "$rc" -eq 0 ] || fail "a dead marker should be a no-op returning 0 (got $rc)"
rm -f "$M6" 2>/dev/null || true
ok

# ── (7) the corpse-sweep TIMEOUT branch terminates the group before freeing the slot ─
export CHILDF="$T/child-7.pid"; : > "$CHILDF"
_bg_health_worker fake_suite
W7="$_BG_HEALTH_PID"; G7="$_BG_HEALTH_PGID"; _track "$W7"
poll_file "$CHILDF" || fail "(7) fake suite never recorded its child pid"
CHILD7="$(cat "$CHILDF")"; _track "$CHILD7"
M7="$(_health_inflight_file "70000-oldsha")"
# Write a LIVE marker whose dispatch ts is far in the past so the sweep's age exceeds the timeout.
{ printf '%s\n' "$W7"; printf '%s\n' "$(_pid_starttime "$W7")"; printf '%s\n' "$(( $(date +%s) - 99999 ))"; printf '%s\n' "$G7"; } > "$M7"
HEALTH_INFLIGHT_TIMEOUT=1 HEALTH_TIMEOUT_HEADROOM=0 DRYRUN="" _sweep_gate_corpses
[ ! -e "$M7" ] || fail "(7) the sweep should REMOVE the timed-out marker (slot freed)"
poll_gone "$W7"    || fail "(7) the timed-out worker leader survived the sweep"
poll_gone "$CHILD7" || fail "(7) the timed-out worker's CHILD survived — slot freed over a live suite (fork-bomb)"
grep -q 'health_timeout' "$JOURNAL_FILE" 2>/dev/null || fail "(7) sweep should journal health_timeout"
ok

# ── (8) _discard_stale_health terminates a superseded-sha worker, spares the current sha ─
export CHILDF="$T/child-8.pid"; : > "$CHILDF"
_bg_health_worker fake_suite
W8="$_BG_HEALTH_PID"; G8="$_BG_HEALTH_PGID"; _track "$W8"
poll_file "$CHILDF" || fail "(8) fake suite never recorded its child pid"
CHILD8="$(cat "$CHILDF")"; _track "$CHILD8"
OLD="$(_health_inflight_file "42-oldsha")"; _marker_write "$OLD" "$W8" "$G8"
# A current-sha marker for the SAME pr must be left completely alone (use a harmless dead-pid marker).
CUR="$(_health_inflight_file "42-newsha")"; _marker_write "$CUR" "$DPID" "$DPID"
_discard_stale_health 42 newsha
[ ! -e "$OLD" ] || fail "(8) the superseded-sha inflight marker should be removed"
poll_gone "$W8"    || fail "(8) the superseded-sha worker survived"
poll_gone "$CHILD8" || fail "(8) the superseded-sha worker's CHILD survived"
[ -e "$CUR" ] || fail "(8) the CURRENT sha's marker must NOT be touched"
grep -q 'health_stale_sha_term' "$JOURNAL_FILE" 2>/dev/null || fail "(8) should journal health_stale_sha_term"
rm -f "$CUR" 2>/dev/null || true
ok

# ── (9) byte-identical marker when no pgid is supplied ───────────────────────
M9="$T/legacy-marker"
_marker_write "$M9" "$$"
[ "$(wc -l < "$M9" | tr -d ' ')" = "3" ] || fail "(9) a pgid-less marker must be exactly 3 lines (legacy shape)"
[ -z "$(_marker_pgid "$M9")" ] || fail "(9) a pgid-less marker must have no line 4"
ok

echo "ALL PASS ($pass checks)"
