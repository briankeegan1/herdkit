#!/usr/bin/env bash
# test-watcher-singleton-reconcile.sh — the HERD-450 / HERD-458 proof: the watcher singleton as a
# RECONCILED INVARIANT, a stop leg that VERIFIES DEATH, and a pane-visibility probe that is honest in
# BOTH directions.
#
# THE INCIDENTS
#   HERD-450 (2026-07-31, this seat) — a watcher SURVIVED a `herd reload`: it re-parented to init
#   (ppid 1) and kept ticking for 41 minutes alongside its replacement, both gating the same PRs and
#   both counting the same concurrency slots. Two independent defects made that possible:
#     (a) the stop leg's argv0-stray branch sent a bare `kill` and never checked whether it worked.
#         `kill` DELIVERS a signal; it does not stop anything. A watcher defers its SIGTERM trap for
#         as long as its foreground child runs (a review takes minutes, a heavy suite ~9), so the
#         stop printed "stopped stray watcher PID N", the launch leg span up a replacement, and the
#         survivor kept going.
#     (b) the singleton lockfile was EMPTY the whole time, so the guard held nothing — and an empty
#         lockfile blinds every seat at once (`herd status`, sweep.sh, the launch paths'
#         adopt-or-refuse read, and clause (2) of the fork exemption all key off the recorded pid).
#   HERD-458 / GH #572 (second operator, WSL2) — EVERY watcher (re)start reported "RUNNING but NOT
#   visible in pane X — detached from tty" while the watcher was demonstrably rendering in that pane,
#   with a live clock. The pane probe demanded a `bash …/agent-watch.sh` cmdline, which exists only
#   for the instant before agent-watch.sh re-execs under its per-workspace argv0 marker — so whether
#   a healthy launch was called visible was a pure race, and one seat lost it every single time.
#   That probe is covered by tests/test-cli-reload.sh (which owns the rich herdr pane stub); this
#   file covers the two identity halves and the stop leg.
#
# WHAT IS ASSERTED HERE
#   1. watcher_singleton_verdict (the shared seam) classifies OK / LOCK_DRIFT / DUPLICATE / HANDOFF /
#      NONE, and — CRITICALLY — does NOT call a legitimate review-tick FORK a duplicate.
#   2. reconcile_watcher_singleton is byte-inert with WATCHER_SINGLETON_RECONCILE off, repairs an
#      EMPTY lockfile when it is the sole live main, journals a duplicate ONCE per signature, and
#      never kills anything.
#   3. build_watcher_singleton paints the violation row only when the lever is on.
#   4. `herd reload`'s stop leg KILLS an orphan that ignores SIGTERM (escalation verified against a
#      real process that traps it away) and SPARES a review-tick fork.
#   5. WATCHER_STOP_REAP_MAIN_HEALTH: off → an orphaned main-health chain and its slot-holding marker
#      survive (byte-identical); on → the chain is killed and its marker removed.
#
# HERMETIC: the process table is planted via $HERD_SWEEP_PS_CMD (watcher-exempt.sh's seam), so no
# real process is ever consulted for identity. Every process this test signals is one it spawned
# itself — innocuous `sleep`/`bash` re-execs under a per-test argv0, never a real watcher.
#
# Run:  bash tests/test-watcher-singleton-reconcile.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WATCH="$ROOT/scripts/herd/agent-watch.sh"
EXEMPT="$ROOT/scripts/herd/watcher-exempt.sh"
HERD_BIN="$ROOT/bin/herd"

T="$(mktemp -d)"
KIDS=""
cleanup() { local p; for p in $KIDS; do kill -9 "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# _spawn_tagged <argv0> [trap-term] → pid of a live, innocuous process carrying <argv0>.
# `exec -a M sleep` keeps argv0 == M and dies promptly on SIGTERM. With trap-term=noterm the process
# IGNORES SIGTERM entirely — the shape that produced the 41-minute survivor, and the only way to
# prove the SIGKILL escalation is real rather than decorative.
_spawn_tagged() {
  local m="$1" mode="${2:-}" p
  if [ "$mode" = noterm ]; then
    ( exec -a "$m" bash -c 'trap "" TERM; while :; do sleep 0.2; done' ) >/dev/null 2>&1 &
  else
    ( exec -a "$m" sleep 300 ) >/dev/null 2>&1 &
  fi
  p=$!
  KIDS="$KIDS $p"
  printf '%s' "$p"
}

# _plant_table <rows…> — write a synthetic "pid ppid pgid command" table and point the shared
# watcher_ps_table seam at it. One row per argument.
_plant_table() {
  local f="$T/ps-table.sh" r
  { printf '#!/usr/bin/env bash\ncat <<'"'"'TBL'"'"'\n'
    for r in "$@"; do printf '%s\n' "$r"; done
    printf 'TBL\n'
  } > "$f"
  chmod +x "$f"
  export HERD_SWEEP_PS_CMD="$f"
}

# ══ 1. the shared classifier: watcher_singleton_verdict ══════════════════════════════════════════
export WORKSPACE_NAME="sgtest"
export HERD_WATCH_ARGV0="herd-watch-sgtest"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_WATCHER_LOCK="$WORKTREES_DIR/.watcher-sgtest.pid"
# shellcheck source=/dev/null
. "$EXEMPT" || fail "sourcing watcher-exempt.sh failed"
type watcher_singleton_verdict >/dev/null 2>&1 || fail "watcher_singleton_verdict not defined"

# A guaranteed-live pid we own, used as "the running watcher" in the planted tables.
LIVE="$(_spawn_tagged "$HERD_WATCH_ARGV0")"
kill -0 "$LIVE" 2>/dev/null || fail "setup: helper pid $LIVE is not alive"

_verdict_state() { watcher_singleton_verdict | cut -f1; }

# ── 1a. one main, lockfile names it → OK ────────────────────────────────────────────────────────
printf '%s\n' "$LIVE" > "$HERD_WATCHER_LOCK"
_plant_table "$LIVE 1 $LIVE $HERD_WATCH_ARGV0 /x/agent-watch.sh"
[ "$(_verdict_state)" = OK ] || fail "1a: healthy singleton did not classify OK (got $(watcher_singleton_verdict))"
ok

# ── 1b. one main, EMPTY lockfile → LOCK_DRIFT (the blind-guard state) ───────────────────────────
: > "$HERD_WATCHER_LOCK"
[ "$(_verdict_state)" = LOCK_DRIFT ] \
  || fail "1b: an EMPTY lockfile beside a live watcher must be LOCK_DRIFT (got $(watcher_singleton_verdict))"
ok

# ── 1c. a REVIEW-TICK FORK is not a duplicate ───────────────────────────────────────────────────
# The tick loop forks constantly and every fork inherits the argv0. A fork whose ppid is the recorded
# watcher is that watcher's own child by construction. Calling it a duplicate is how a reaper ends up
# caching a bogus BLOCK verdict against a PR nobody reviewed.
printf '%s\n' "$LIVE" > "$HERD_WATCHER_LOCK"
_plant_table "$LIVE 1 $LIVE $HERD_WATCH_ARGV0 /x/agent-watch.sh" \
             "424242 $LIVE $LIVE $HERD_WATCH_ARGV0 /x/agent-watch.sh"
[ "$(_verdict_state)" = OK ] \
  || fail "1c: a fork whose ppid is the canonical watcher was counted as a duplicate ($(watcher_singleton_verdict))"
ok

# ── 1d. a GENUINE ORPHAN (ppid 1, unowned) IS a duplicate ───────────────────────────────────────
_plant_table "$LIVE 1 $LIVE $HERD_WATCH_ARGV0 /x/agent-watch.sh" \
             "424243 1 424243 $HERD_WATCH_ARGV0 /x/agent-watch.sh"
[ "$(_verdict_state)" = DUPLICATE ] \
  || fail "1d: an orphaned second main (ppid 1) was not reported as DUPLICATE ($(watcher_singleton_verdict))"
# Resolve the verdict FIRST, then split it. `IFS=$'\t' read … <<< "$(watcher_singleton_verdict)"`
# looks equivalent but is not: the assignment prefix is already in effect while the here-string's
# command substitution runs, so the seam would do its own table parsing under a tab IFS (see 1h).
_1d_line="$(watcher_singleton_verdict)"
IFS=$'\t' read -r _1d_st _1d_lock _1d_mains _1d_n <<< "$_1d_line"
case "$_1d_mains" in *424243*) : ;; *) fail "1d: the verdict does not name the orphan pid (mains=[$_1d_mains])" ;; esac
ok

# ── 1h. the seam is IFS-INDEPENDENT ─────────────────────────────────────────────────────────────
# Found while writing 1d, and it is not cosmetic. The process-table rows are space-separated, so a
# caller whose IFS is set to something else makes every row fail the numeric-pid test and
# watcher_list_mains returns NOTHING. That list is also the KILL LIST: an empty result makes
# _stop_project_watcher report "no running watcher found", drop the lockfile, and let its caller spawn
# a second main on top of a live one — this PR's own incident, reachable from an inherited IFS.
_1h_default="$(watcher_list_mains | tr '\n' ',')"   # pipe-ok: bounded pid list, far under a pipe buffer
_1h_tabbed="$( IFS=$'\t'; watcher_list_mains | tr '\n' ',' )"   # pipe-ok: bounded pid list, far under a pipe buffer
[ "$_1h_default" = "$_1h_tabbed" ] \
  || fail "1h: watcher_list_mains depends on the caller's IFS (default=[$_1h_default] tab=[$_1h_tabbed]) — an empty kill list spawns a duplicate"
case "$_1h_tabbed" in *424243*) : ;; *) fail "1h: under a tab IFS the orphan vanished from the kill list" ;; esac
ok

# ── 1e. a foreign workspace's watcher is NEVER ours (cross-project kill guard, issue #60) ───────
_plant_table "$LIVE 1 $LIVE $HERD_WATCH_ARGV0 /x/agent-watch.sh" \
             "424244 1 424244 herd-watch-sgtest-other /x/agent-watch.sh"
[ "$(_verdict_state)" = OK ] \
  || fail "1e: another workspace's argv0 was counted against this workspace ($(watcher_singleton_verdict))"
ok

# ── 1f. a self-restart HANDOFF window reads as HANDOFF, not DUPLICATE ───────────────────────────
_plant_table "$LIVE 1 $LIVE $HERD_WATCH_ARGV0 /x/agent-watch.sh" \
             "424245 1 424245 $HERD_WATCH_ARGV0 /x/agent-watch.sh"
watcher_handoff_begin "$LIVE"
[ "$(_verdict_state)" = HANDOFF ] \
  || fail "1f: a live self-restart handoff was reported as a hard DUPLICATE ($(watcher_singleton_verdict))"
watcher_handoff_clear
[ "$(_verdict_state)" = DUPLICATE ] || fail "1f: clearing the handoff did not restore the DUPLICATE verdict"
ok

# ── 1g. nothing running → NONE ──────────────────────────────────────────────────────────────────
_plant_table "1 0 1 /sbin/init"
rm -f "$HERD_WATCHER_LOCK"
[ "$(_verdict_state)" = NONE ] || fail "1g: an empty control room did not classify NONE"
ok

# ══ 2. reconcile_watcher_singleton — the tick leg ════════════════════════════════════════════════
# Drive the SHIPPED function out of agent-watch.sh in lib mode (no live loop). Journal writes land in
# a temp dir so nothing touches a real project.
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export TREES="$WORKTREES_DIR"
JOURNAL="$T/journal.jsonl"
export JOURNAL_FILE="$JOURNAL"
# shellcheck source=/dev/null
. "$WATCH" >/dev/null 2>&1 || fail "sourcing agent-watch.sh (lib mode) failed"
# Sourcing re-derives paths from herd-config.sh defaults — pin them back to this test's temp dirs.
export HERD_WATCHER_LOCK="$WORKTREES_DIR/.watcher-sgtest.pid"
export HERD_WATCH_ARGV0="herd-watch-sgtest"
TREES="$WORKTREES_DIR"
WATCHER_SINGLETON_STATE="$TREES/.agent-watch-singleton"
type reconcile_watcher_singleton >/dev/null 2>&1 || fail "reconcile_watcher_singleton not defined"
type build_watcher_singleton    >/dev/null 2>&1 || fail "build_watcher_singleton not defined"

_journal_count() { [ -f "$JOURNAL" ] && grep -c "$1" "$JOURNAL" 2>/dev/null || printf '0'; }

# ── 2a. lever OFF → byte-inert: no state file, no journal, and an EMPTY lock stays empty ────────
# The lockfile-repair write is the one side effect that could leak with the lever off; assert the
# file is untouched, not merely that no row painted.
WATCHER_SINGLETON_RECONCILE=off
: > "$HERD_WATCHER_LOCK"
_plant_table "$$ 1 $$ $HERD_WATCH_ARGV0 /x/agent-watch.sh"
rm -f "$JOURNAL" "$WATCHER_SINGLETON_STATE"
reconcile_watcher_singleton || fail "2a: reconcile returned non-zero with the lever off"
[ -s "$HERD_WATCHER_LOCK" ] && fail "2a: the lever is OFF but the lockfile was written"
[ -e "$WATCHER_SINGLETON_STATE" ] && fail "2a: the lever is OFF but a state file was written"
[ -s "$JOURNAL" ] && fail "2a: the lever is OFF but a journal event was emitted"
build_watcher_singleton
[ -z "${WATCHER_SINGLETON:-}" ] || fail "2a: the lever is OFF but a console row rendered"
ok

# ── 2b. lever ON + EMPTY lockfile + we are the sole main → REPAIRED in place ────────────────────
WATCHER_SINGLETON_RECONCILE=on
reconcile_watcher_singleton || fail "2b: reconcile returned non-zero"
[ "$(cat "$HERD_WATCHER_LOCK" 2>/dev/null)" = "$$" ] \
  || fail "2b: the empty lockfile was not repaired to this process's pid (got '$(cat "$HERD_WATCHER_LOCK" 2>/dev/null)')"
[ "$(_journal_count watcher_lock_repaired)" -ge 1 ] || fail "2b: the repair was not journaled"
[ -e "$WATCHER_SINGLETON_STATE" ] && fail "2b: a repaired lock must leave no standing violation row"
build_watcher_singleton
[ -z "${WATCHER_SINGLETON:-}" ] || fail "2b: a repaired lock still painted a row"
ok

# ── 2c. a healthy singleton is silent and re-journals nothing ───────────────────────────────────
rm -f "$JOURNAL"
reconcile_watcher_singleton || fail "2c: reconcile returned non-zero"
[ -s "$JOURNAL" ] && fail "2c: a healthy singleton emitted a journal event"
ok

# ── 2d. DUPLICATE → state file + ONE journal event per signature + a loud row, and NO kill ──────
_plant_table "$$ 1 $$ $HERD_WATCH_ARGV0 /x/agent-watch.sh" \
             "$LIVE 1 $LIVE $HERD_WATCH_ARGV0 /x/agent-watch.sh"
rm -f "$JOURNAL"
reconcile_watcher_singleton || fail "2d: reconcile returned non-zero"
[ -s "$WATCHER_SINGLETON_STATE" ] || fail "2d: a duplicate left no state file"
grep -q '^DUPLICATE ' "$WATCHER_SINGLETON_STATE" || fail "2d: state file does not record the DUPLICATE verdict"
[ "$(_journal_count watcher_singleton_violation)" -eq 1 ] \
  || fail "2d: expected exactly one watcher_singleton_violation, got $(_journal_count watcher_singleton_violation)"
reconcile_watcher_singleton || fail "2d: second reconcile returned non-zero"
[ "$(_journal_count watcher_singleton_violation)" -eq 1 ] \
  || fail "2d: a persisting duplicate re-journaled (the row persists; the journal must not spam)"
kill -0 "$LIVE" 2>/dev/null \
  || fail "2d: the tick reconcile KILLED a process — it must only classify (a 'duplicate' is often a fork)"
build_watcher_singleton
case "${WATCHER_SINGLETON:-}" in
  *DUPLICATE\ WATCHER*) : ;;
  *) fail "2d: the duplicate row did not render" ;;
esac
case "${WATCHER_SINGLETON:-}" in
  *"$LIVE"*) : ;;
  *) fail "2d: the duplicate row does not name the offending pid" ;;
esac
case "${WATCHER_SINGLETON:-}" in
  *"herd reload"*) : ;;
  *) fail "2d: the duplicate row carries no remedy" ;;
esac
ok

# ── 2e. the violation clears when the invariant heals ───────────────────────────────────────────
_plant_table "$$ 1 $$ $HERD_WATCH_ARGV0 /x/agent-watch.sh"
reconcile_watcher_singleton || fail "2e: reconcile returned non-zero"
[ -e "$WATCHER_SINGLETON_STATE" ] && fail "2e: the standing violation did not clear once the duplicate was gone"
build_watcher_singleton
[ -z "${WATCHER_SINGLETON:-}" ] || fail "2e: a healed control room still painted a row"
ok

# ── 2f. the acquire gate REFUSES rather than bypasses a live watcher main holding the flock ─────
# The OTHER half of the empty-lockfile incident. HERD-344 lets a launch ADOPT a lock whose recorded
# pid is dead but whose flock is held by an orphaned GATE WORKER, by unlinking the file and re-keying
# to a fresh inode. With an EMPTY lockfile there is no recorded pid to be dead, so that bypass fires
# against a LIVE WATCHER MAIN too — it re-keys the canonical path out from under the running watcher
# and starts a SECOND main on top of it, which is exactly the state the incident was found in. The
# holder must be identified through the shared exemption seam first: a worker still adopts, a watcher
# main is refused loudly. flock(1) is Linux-only, so this case SKIPS on a seat without it (macOS)
# rather than pretending to prove something.
if command -v flock >/dev/null 2>&1; then
  FLK="$T/flocktest"; mkdir -p "$FLK"
  export HERD_WATCHER_LOCK="$FLK/.watcher-sgtest.pid"
  export WORKTREES_DIR="$FLK"; TREES="$FLK"
  : > "$HERD_WATCHER_LOCK"                       # EMPTY — the incident's blind state
  READY="$FLK/holder-ready"
  # READINESS HANDSHAKE, not a sleep. The holder touches $READY only AFTER flock(1) has actually
  # granted the lock. A fixed `sleep` here is a race on a cold/loaded runner, and — worse — a race
  # this assertion CANNOT distinguish from a real engine miss: if the holder has not taken the lock
  # yet, the acquire legitimately succeeds and the test reports an engine defect that did not happen.
  # (Its sibling in test-watcher-singleton.sh asserts ACQUIRE, so the same race leaves that one
  # vacuously green — which is why this is the case that surfaced it.)
  # The holder runs a SCRIPT FILE, not `bash -c '…; sleep 60'`. When `sleep` is the last command of a
  # -c string, bash may exec into it — which REPLACES argv0, so the holder silently stops carrying the
  # watcher marker it is supposed to be impersonating. That is platform-dependent (ubuntu's bash does
  # it, this macOS build does not: CI reported `argv0=[sleep]` where a local probe showed the marker),
  # so it is never safe to rely on. A bash running a script file with a loop cannot exec away, which is
  # also the real watcher's shape (`exec -a "$HERD_WATCH_ARGV0" bash …/agent-watch.sh`).
  HOLDER_SH="$FLK/holder.sh"
  cat > "$HOLDER_SH" <<'HS'
exec 9>>"$1"
flock 9 || exit 1
: > "$2"
while :; do sleep 1; done
HS
  ( exec -a "$HERD_WATCH_ARGV0" bash "$HOLDER_SH" "$HERD_WATCHER_LOCK" "$READY" ) &
  HOLDER=$!; KIDS="$KIDS $HOLDER"
  _fk=0
  while [ "$_fk" -lt 100 ] && [ ! -e "$READY" ]; do sleep 0.1; _fk=$((_fk + 1)); done
  [ -e "$READY" ] || fail "2f FIXTURE: the holder never acquired the flock within 10s — fixture broken, not an engine verdict"
  # The scenario is "a live WATCHER MAIN holds the lock", so the holder must actually carry the marker.
  # Assert it: if the shell exec'd it away the case would silently degrade into a different scenario.
  _holder_argv0="$(ps -o command= -p "$HOLDER" 2>/dev/null | awk '{print $1}')"
  [ "$_holder_argv0" = "$HERD_WATCH_ARGV0" ] \
    || fail "2f FIXTURE: the holder lost its argv0 marker (is [$_holder_argv0], want [$HERD_WATCH_ARGV0]) — it is no longer impersonating a watcher main"
  # INDEPENDENT precondition. Prove from OUTSIDE the engine that the lock is genuinely held, so a
  # vacuous fixture can never be reported as an engine failure.
  if flock -n "$HERD_WATCHER_LOCK" true 2>/dev/null; then
    fail "2f FIXTURE: an outside flock -n SUCCEEDED, so the lock is not actually held — fixture broken, not an engine verdict"
  fi
  _lock_ino_before="$(ls -i "$HERD_WATCHER_LOCK" 2>/dev/null | awk '{print $1}')"
  acq_out="$( _acquire_watcher_singleton 2>&1 )"; acq_rc=$?
  if [ "$acq_rc" -eq 0 ]; then
    # Self-diagnosing failure: print the exact inputs the decision was made on, so a future CI red
    # says WHY rather than only THAT.
    echo "  diag: holder pid=$HOLDER argv0=[$(ps -o command= -p "$HOLDER" 2>/dev/null | awk '{print $1}')]" >&2
    echo "  diag: HERD_WATCH_ARGV0=[$HERD_WATCH_ARGV0]" >&2
    echo "  diag: _watcher_lock_flock_holder=[$(_watcher_lock_flock_holder 2>/dev/null)]" >&2
    echo "  diag: lockfile=[$(cat "$HERD_WATCHER_LOCK" 2>/dev/null)] acq_out=[$acq_out]" >&2
    fail "2f: a second watcher ACQUIRED the singleton while a live watcher main held the flock (the duplicate-watcher path)"
  fi
  case "$acq_out" in *"already running"*) : ;; *) fail "2f: the refusal was not loud (no holder named on stderr): [$acq_out]" ;; esac
  # The refusal must be INERT: it may not kill the holder, and it may not re-key the lockfile inode
  # out from under it (re-keying IS the duplicate-watcher mechanism).
  kill -0 "$HOLDER" 2>/dev/null \
    || fail "2f: the acquire gate KILLED the live watcher holding the lock — it may only refuse"
  [ "$(ls -i "$HERD_WATCHER_LOCK" 2>/dev/null | awk '{print $1}')" = "$_lock_ino_before" ] \
    || fail "2f: the refused acquire still re-keyed the lockfile to a fresh inode (defeats the holder's singleton)"
  kill -9 "$HOLDER" 2>/dev/null || true
  ok
else
  echo "SKIP (2f) flock(1) absent on this platform — the flock acquisition branch is unreachable here"
fi

unset HERD_SWEEP_PS_CMD AGENT_WATCH_LIB JOURNAL_FILE

# ══ 3. `herd reload`'s stop leg: VERIFY DEATH, and spare the forks ═══════════════════════════════
# A real reload against a scratch project. herdr is stubbed absent and the launch is suppressed, so
# nothing is ever spawned; only the stop leg runs. The process table is planted, so the pids reload
# targets are exactly the ones this test created.
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/pgrep"; chmod +x "$BIN/pgrep"   # no legacy strays
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"   # forces the headless path

_make_project() {
  local r="$1" ws="$2" r_real
  mkdir -p "$r"
  r_real="$(cd "$r" && pwd -P)"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  ( cd "$r" && git commit -q --allow-empty -m init )
  mkdir -p "$r/.herd" "$r/trees"
  cat > "$r/.herd/config" <<CFG
HERD_VERSION=1
PROJECT_ROOT="$r_real"
WORKTREES_DIR="$r_real/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="$ws"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
CFG
}

# ── 3a. an ORPHAN that IGNORES SIGTERM is still dead when reload returns ────────────────────────
# THE HERD-450 REGRESSION. Pre-fix, the argv0-stray branch was a bare `kill` with no verification:
# this process traps SIGTERM away, so it survived the stop and reload went on to launch a second
# watcher on top of it — the 41-minute duplicate. The fix escalates to SIGKILL and verifies.
P="$T/p3a"
_make_project "$P" "stoptest"
ARGV0="herd-watch-stoptest"
ORPH="$(_spawn_tagged "$ARGV0" noterm)"
sleep 0.3
kill -0 "$ORPH" 2>/dev/null || fail "3a: setup — the SIGTERM-ignoring orphan is not alive"
kill -TERM "$ORPH" 2>/dev/null || true
sleep 0.3
kill -0 "$ORPH" 2>/dev/null || fail "3a: setup — the orphan did NOT ignore SIGTERM, so the test proves nothing"
_plant_table "$ORPH 1 $ORPH $ARGV0 /x/agent-watch.sh"
out="$( cd "$P" && env PATH="$BIN:$PATH" HERD_SWEEP_PS_CMD="$HERD_SWEEP_PS_CMD" \
        HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=3 bash "$HERD_BIN" reload 2>&1 )" \
  || fail "3a: reload failed"
sleep 0.3
kill -0 "$ORPH" 2>/dev/null \
  && fail "3a: the orphaned watcher SURVIVED the stop leg — a bare kill is not a stop (HERD-450)"
case "$out" in *"still alive — sending SIGKILL"*) : ;; *) fail "3a: reload did not report the SIGKILL escalation" ;; esac
case "$out" in *"stopped stray watcher PID $ORPH"*) : ;; *) fail "3a: the stopped stray was not reported" ;; esac
ok

# ── 3b. a REVIEW-TICK FORK of the canonical watcher is NOT reaped by the stop ───────────────────
# SAFETY RAIL (2026-07-08 incident): reaping a fork caches a bogus BLOCK verdict. The fork exemption
# reads the LOCKFILE, so this also pins the ordering fix — the stop must list the strays BEFORE it
# removes the lockfile, or clause (2) is blind and every tick fork looks like a duplicate main.
P="$T/p3b"
_make_project "$P" "stoptest"
MAINW="$(_spawn_tagged "$ARGV0")"
FORK="$(_spawn_tagged "$ARGV0")"
printf '%s\n' "$MAINW" > "$P/trees/.watcher-stoptest.pid"
_plant_table "$MAINW 1 $MAINW $ARGV0 /x/agent-watch.sh" \
             "$FORK $MAINW $MAINW $ARGV0 /x/agent-watch.sh"
out="$( cd "$P" && env PATH="$BIN:$PATH" HERD_SWEEP_PS_CMD="$HERD_SWEEP_PS_CMD" \
        HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=3 bash "$HERD_BIN" reload 2>&1 )" \
  || fail "3b: reload failed"
sleep 0.3
kill -0 "$MAINW" 2>/dev/null && fail "3b: the canonical watcher was not stopped"
kill -0 "$FORK" 2>/dev/null \
  || fail "3b: a review-tick FORK (ppid == the canonical watcher) was reaped by the stop leg — reaping one caches a bogus BLOCK verdict"
[ -e "$P/trees/.watcher-stoptest.pid" ] && fail "3b: the lockfile was not removed after the stop"
ok

# ── 3c. a FOREIGN workspace's watcher is never touched (cross-project kill, issue #60) ──────────
P="$T/p3c"
_make_project "$P" "stoptest"
FOREIGN="$(_spawn_tagged "herd-watch-otherproject")"
_plant_table "$FOREIGN 1 $FOREIGN herd-watch-otherproject /x/agent-watch.sh"
( cd "$P" && env PATH="$BIN:$PATH" HERD_SWEEP_PS_CMD="$HERD_SWEEP_PS_CMD" \
    HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=3 bash "$HERD_BIN" reload >/dev/null 2>&1 ) \
  || fail "3c: reload failed"
sleep 0.3
kill -0 "$FOREIGN" 2>/dev/null || fail "3c: another workspace's watcher was killed (cross-project kill)"
ok

# ══ 4. WATCHER_STOP_REAP_MAIN_HEALTH — stop orphaning main-health chains ═════════════════════════
# _spawn_main_health PROJECT → pid of a fake main-health worker with a live inflight marker naming it.
_spawn_main_health() {
  local p="$1" w
  w="$(_spawn_tagged "fake-main-health")"
  printf '%s\n' "$w" > "$p/trees/.health-inflight-main-deadbeef"
  printf '%s' "$w"
}

# ── 4a. lever OFF → byte-identical: the orphaned chain and its marker both survive ──────────────
P="$T/p4a"
_make_project "$P" "stoptest"
W1="$(_spawn_tagged "$ARGV0")"
H1="$(_spawn_main_health "$P")"
printf '%s\n' "$W1" > "$P/trees/.watcher-stoptest.pid"
_plant_table "$W1 1 $W1 $ARGV0 /x/agent-watch.sh"
( cd "$P" && env PATH="$BIN:$PATH" HERD_SWEEP_PS_CMD="$HERD_SWEEP_PS_CMD" \
    HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=3 bash "$HERD_BIN" reload >/dev/null 2>&1 ) \
  || fail "4a: reload failed"
sleep 0.3
kill -0 "$H1" 2>/dev/null || fail "4a: the lever is OFF but the main-health chain was killed"
[ -f "$P/trees/.health-inflight-main-deadbeef" ] || fail "4a: the lever is OFF but the marker was removed"
kill -9 "$H1" 2>/dev/null || true
ok

# ── 4b. lever ON → the orphaned chain is killed and its slot-holding marker removed ─────────────
P="$T/p4b"
_make_project "$P" "stoptest"
printf 'WATCHER_STOP_REAP_MAIN_HEALTH="on"\n' >> "$P/.herd/config"
W2="$(_spawn_tagged "$ARGV0")"
H2="$(_spawn_main_health "$P")"
printf '%s\n' "$W2" > "$P/trees/.watcher-stoptest.pid"
_plant_table "$W2 1 $W2 $ARGV0 /x/agent-watch.sh"
out="$( cd "$P" && env PATH="$BIN:$PATH" HERD_SWEEP_PS_CMD="$HERD_SWEEP_PS_CMD" \
        HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=3 bash "$HERD_BIN" reload 2>&1 )" \
  || fail "4b: reload failed"
sleep 0.3
kill -0 "$H2" 2>/dev/null \
  && fail "4b: the lever is ON but the orphaned main-health chain kept running (it holds a health slot for a watcher that no longer exists)"
[ -f "$P/trees/.health-inflight-main-deadbeef" ] \
  && fail "4b: the lever is ON but the abandoned marker still holds its slot"
case "$out" in *"stopped orphaned main-health chain PID $H2"*) : ;; *) fail "4b: the reap was not reported to the operator" ;; esac
ok

# ── 4c. lever ON never touches a REVIEW worker's chain (its verdict IS collected later) ─────────
P="$T/p4c"
_make_project "$P" "stoptest"
printf 'WATCHER_STOP_REAP_MAIN_HEALTH="on"\n' >> "$P/.herd/config"
W3="$(_spawn_tagged "$ARGV0")"
R3="$(_spawn_tagged "fake-reviewer")"
printf '%s\n' "$R3" > "$P/trees/.review-inflight-77"
printf '%s\n' "$W3" > "$P/trees/.watcher-stoptest.pid"
_plant_table "$W3 1 $W3 $ARGV0 /x/agent-watch.sh"
( cd "$P" && env PATH="$BIN:$PATH" HERD_SWEEP_PS_CMD="$HERD_SWEEP_PS_CMD" \
    HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=3 bash "$HERD_BIN" reload >/dev/null 2>&1 ) \
  || fail "4c: reload failed"
sleep 0.3
kill -0 "$R3" 2>/dev/null \
  || fail "4c: an in-flight REVIEW worker was reaped — its verdict file is collected by the next watcher, so killing it destroys real work"
ok

echo "PASS ($pass checks) — watcher singleton reconcile + verified stop (HERD-450 / HERD-458)"
