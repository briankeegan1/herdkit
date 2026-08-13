#!/usr/bin/env bash
# test-cli-reload.sh — hermetic tests for `herd reload`.
#
# Design principles (mirrors test-watcher-checks.sh / test-merge-policy.sh):
#   • pgrep is STUBBED on PATH — returns only $FAKE_STRAY_PIDS (colon-separated list).
#     This prevents the real pgrep from finding actual agent-watch.sh processes in
#     other workspaces (production or other worktrees), making every test independent of
#     the ambient process table.
#   • herdr is STUBBED (exits 1) — forces the background-fallback path without a real
#     herdr instance. Tests 11+ prepend a RICH herdr stub (file-backed simulation of the
#     workspace/tab/pane/agent JSON API) to exercise the herdr control-room path — still
#     hermetic: pane run only records the command, no process is ever spawned.
#   • HERD_RELOAD_SKIP_LAUNCH=1 suppresses the background watcher launch so no
#     persistent herd-watch.sh / agent-watch.sh processes are spawned.
#   • HERD_RELOAD_SIGTERM_POLLS=3 (3×0.2s) shortens the SIGTERM wait in tests that
#     kill live processes, so we do not wait the full 10s production window.
#   • Kill tests use real, innocuous sleep processes as fake watchers — never the real
#     agent-watch.sh; stray-guard tests control the cwd of those processes.
#
# Run:  bash tests/test-cli-reload.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

# HERD-458: pin our own precondition — a CONFIGURED caller (herd-config.sh sourced ambient, e.g. by
# scripts/herd/healthcheck.sh --heavy) can leave MERGE_POLICY/WATCHER_AUTOMERGE/… already set, which
# defeats the reload-derivation assertions below (the derive-from-WATCHER_AUTOMERGE path only fires
# when MERGE_POLICY is genuinely unset). The shared harness scrub (scripts/herd/hermetic-env-scrub.sh)
# already does this once per suite run; re-arm it here too so this test is self-sufficient run alone.
if [ -f "$HERE/../scripts/herd/hermetic-env-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$HERE/../scripts/herd/hermetic-env-scrub.sh"
  herd_hermetic_env_scrub "$HERE/../scripts/herd/herd-config.sh"
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0
ok(){ pass=$((pass+1)); }

# HERD-462: bats-core dup's a live pipe onto fd 3 (and a higher fd, observed fd 12 on bats 1.14) before
# running each test, so it can stream the "ok N …" line back to its own aggregator. A backgrounded fake
# watcher in the tests below inherits that fd by default and, unless it explicitly closes it, keeps the
# WRITE end open long after the test that spawned it has finished — bats' aggregator then blocks
# forever on a read() that will never see EOF, wedging the whole `bats` run behind ONE leaked child
# (reproduced live: an unguarded background sleep hangs `bats` even though every test itself reports
# "ok"). `_bg_close_fds` mirrors the exact technique bats-exec-test's OWN internal per-test-timeout
# watchdog uses on itself (`(eval exec {0..255}">&-"; sleep "$timeout") &`) — close the whole high-fd
# range, not just fd 3, since which fd bats happens to dup onto is an implementation detail. A plain
# numeric `for` loop (not bash 4's `{3..255}>&-` brace-range redirection) keeps this bash-3.2-safe —
# macOS still ships bash 3.2 as `/bin/bash` and this suite runs under it. Every backgrounded
# fake-watcher spawn below runs this FIRST, before anything else — and each spawn is `exec`'d into its
# final command (never left as a plain forked child) so a lone `kill` fully reaps it, no orphan left
# holding the (now-closed) fd open.
_bg_close_fds() {
  local fd
  for fd in $(seq 3 255); do eval "exec $fd>&-" 2>/dev/null; done
}

# _BG_PIDS / _bg_track / _bg_reap_all: safety net for the "known sleep-9999 orphan fallout" (HERD-462).
# fd-closing (above) stops a leaked child from wedging bats even while it's alive, but an unexpected
# `fail()` between spawning a fake watcher and this file's own explicit `kill` of it would still leave
# a live sleep-9999 process running for hours. Track every backgrounded pid and SIGKILL the lot
# unconditionally on exit, on top of the existing tempdir cleanup.
_BG_PIDS=()
_bg_track() { _BG_PIDS+=("$1"); }
_bg_reap_all() {
  local p
  for p in "${_BG_PIDS[@]:-}"; do
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true
  done
}
trap '_bg_reap_all; rm -rf "$T"' EXIT

# Portability (HERD-53): the one env -i below strips LANG/LC_*; pin a UTF-8 locale (fallback C) so the
# harness stays byte-consistent with the rest of the suite on Git Bash. Byte-identical on Linux. (That
# env -i exercises the herdr-absent bail, which returns before any python3 subcall, so no shim needed.)
UTF8_LOCALE=C; [ "$(LC_ALL=C.UTF-8 locale charmap 2>/dev/null)" = "UTF-8" ] && UTF8_LOCALE=C.UTF-8

# ── Stub pgrep and herdr on PATH ─────────────────────────────────────────────
# pgrep stub: echoes each colon-separated PID in $FAKE_STRAY_PIDS.  All other args
# (e.g. -f "agent-watch.sh") are ignored so the real process table is never consulted.
# This is the key safety property: cmd_reload never sees production agent-watch PIDs.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
IFS=':' read -ra pids <<< "${FAKE_STRAY_PIDS:-}"
for p in "${pids[@]}"; do [ -n "$p" ] && printf '%s\n' "$p"; done
exit 0
STUB
chmod +x "$BIN/pgrep"

# herdr stub: always exits 1 — forces the background-fallback path.
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"

export PATH="$BIN:$PATH"

# _make_project ROOT WORKSPACE [extra config lines...]
# PROJECT_ROOT is set to the canonical (realpath) of ROOT so lsof cwd comparisons
# match on macOS where /var/folders is a symlink to /private/var/folders.
_make_project() {
  local r="$1" ws="$2"; shift 2
  local r_real; r_real="$(cd "$r" && pwd -P)"
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
WATCHER_AUTOMERGE="true"
CFG
  for line in "$@"; do printf '%s\n' "$line" >> "$r/.herd/config"; done
}

# ── 1. reload renders the coordinator skill ───────────────────────────────────
P="$T/p1"; mkdir "$P"
_make_project "$P" "reloadtest"
( cd "$P" && HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload >/dev/null 2>&1 ) \
  || fail "reload failed (basic run)"
[ -f "$P/.claude/commands/coordinator.md" ] || fail "reload did not render coordinator skill"
grep -q "GENERATED BY herdkit" "$P/.claude/commands/coordinator.md" \
  || fail "rendered skill missing generated banner"
grep -q '{{' "$P/.claude/commands/coordinator.md" \
  && fail "rendered skill has unrendered {{tokens}}" || true
ok

# ── 2a. MERGE_POLICY=auto is printed ─────────────────────────────────────────
P="$T/p2a"; mkdir "$P"
_make_project "$P" "reloadtest" 'MERGE_POLICY="auto"'
out="$( cd "$P" && HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload 2>&1 )"
grep -q "MERGE_POLICY:" <<< "$out" || fail "output missing MERGE_POLICY line"
grep -q "auto" <<< "$out" || fail "MERGE_POLICY should be 'auto'"
ok

# ── 2b. MERGE_POLICY=approve ──────────────────────────────────────────────────
P="$T/p2b"; mkdir "$P"
_make_project "$P" "reloadtest" 'MERGE_POLICY="approve"'
out="$( cd "$P" && HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload 2>&1 )"
grep -q "approve" <<< "$out" || fail "MERGE_POLICY should be 'approve'"
ok

# ── 2c. MERGE_POLICY=observe ──────────────────────────────────────────────────
P="$T/p2c"; mkdir "$P"
_make_project "$P" "reloadtest" 'MERGE_POLICY="observe"'
out="$( cd "$P" && HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload 2>&1 )"
grep -q "observe" <<< "$out" || fail "MERGE_POLICY should be 'observe'"
ok

# ── 2d. WATCHER_AUTOMERGE=false → approve when MERGE_POLICY unset ────────────
P="$T/p2d"; mkdir "$P"
_make_project "$P" "reloadtest" 'WATCHER_AUTOMERGE="false"'
out="$( cd "$P" && HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload 2>&1 )"
grep -q "approve" <<< "$out" || fail "WATCHER_AUTOMERGE=false should derive approve"
ok

# ── 2e. Default (WATCHER_AUTOMERGE=true, no MERGE_POLICY) → auto ─────────────
P="$T/p2e"; mkdir "$P"
_make_project "$P" "reloadtest"
out="$( cd "$P" && HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload 2>&1 )"
grep -q "auto" <<< "$out" || fail "default WATCHER_AUTOMERGE=true should derive auto"
ok

# ── 2f. TYPO'd MERGE_POLICY fails STRICT to observe (HERD-210) ───────────────
# A non-empty unrecognized MERGE_POLICY is a typo, not a legacy-derivation trigger: the watcher
# resolves it to observe, so reload's summary must say observe too. Reporting the legacy
# WATCHER_AUTOMERGE derivation ("auto") here would tell the operator the watcher auto-merges
# while it is actually observing — the inconsistency that let #317 merge past a live BLOCK.
P="$T/p2f"; mkdir "$P"
_make_project "$P" "reloadtest" 'MERGE_POLICY="aprove"'
out="$( cd "$P" && HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload 2>&1 )"
pol_line="$(printf '%s\n' "$out" | grep "MERGE_POLICY:" || true)"
grep -q "observe" <<< "$pol_line" \
  || fail "typo MERGE_POLICY=aprove must report observe, got: $pol_line"
grep -q "auto" <<< "$pol_line" \
  && fail "typo MERGE_POLICY=aprove reported 'auto' from the legacy WATCHER_AUTOMERGE derivation" || true
ok

# ── 3. reload removes lockfile with a non-existent PID ───────────────────────
P="$T/p3"; mkdir "$P"
_make_project "$P" "reloadtest"
lockfile="$P/trees/.watcher-reloadtest.pid"
printf '%s\n' "99999999" > "$lockfile"   # almost certainly a non-existent PID
( cd "$P" && HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload >/dev/null 2>&1 ) \
  || fail "reload failed with dead-PID lockfile"
[ -f "$lockfile" ] && fail "reload did not remove the lockfile" || true
ok

# ── 4. reload kills a live process recorded in the lockfile (SIGTERM path) ────
# HERD_RELOAD_SIGTERM_POLLS=3 (3×0.2s = 0.6s) so we do not wait the full 10s.
P="$T/p4"; mkdir "$P"
_make_project "$P" "reloadtest"
lockfile="$P/trees/.watcher-reloadtest.pid"
( _bg_close_fds; exec sleep 999 ) &
FAKEPID=$!
_bg_track "$FAKEPID"
printf '%s\n' "$FAKEPID" > "$lockfile"
( cd "$P" && HERD_RELOAD_SIGTERM_POLLS=3 HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload >/dev/null 2>&1 ) \
  || { kill "$FAKEPID" 2>/dev/null || true; fail "reload failed when a live PID was in lockfile"; }
sleep 0.3
kill -0 "$FAKEPID" 2>/dev/null \
  && { kill "$FAKEPID" 2>/dev/null || true; fail "reload did not kill the fake watcher (PID $FAKEPID)"; } \
  || true
[ -f "$lockfile" ] && fail "reload did not remove the lockfile after killing watcher" || true
ok

# ── 5. reload notes no running watcher when lockfile is absent ───────────────
P="$T/p5"; mkdir "$P"
_make_project "$P" "reloadtest"
out="$( cd "$P" && HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload 2>&1 )"
grep -qi "no running watcher\|not found" <<< "$out" \
  || fail "reload should note no running watcher when lockfile is absent"
ok

# ── 6. reload fails clearly with no .herd/config ─────────────────────────────
P="$T/p6"; mkdir "$P"
git -C "$P" init -q; git -C "$P" config user.email t@t.t; git -C "$P" config user.name t
( cd "$P" && git commit -q --allow-empty -m init )
out="$( cd "$P" && HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload 2>&1 || true )"
grep -qi "herd init\|no .herd/config" <<< "$out" \
  || fail "reload should report missing .herd/config clearly"
ok

# A legacy (pre-argv0-marker) watcher shows in `ps` as `bash …/agent-watch.sh`. HERD-524 (#636): the
# phase-2 leg finds its candidates with a `pgrep -f agent-watch.sh` SUBSTRING match and then SIGKILLs
# them, so it now PROVES a candidate is executing the script before signalling it. The fixture must
# therefore be a real one — a bare `sleep` that merely sits in the project root is a BYSTANDER (7b).
# The script loops over short sleeps rather than `exec`ing one: the process must still READ as
# `bash …/agent-watch.sh` when reload samples it, and a killed parent then orphans at most 1s of sleep.
LEGACY_DIR="$T/legacy"; mkdir -p "$LEGACY_DIR"
printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$LEGACY_DIR/agent-watch.sh"
chmod +x "$LEGACY_DIR/agent-watch.sh"

# ── 7. Stray guard — OUR workspace: stray cwd == PROJECT_ROOT → killed ───────
# A process whose current working directory IS our PROJECT_ROOT is treated as a stray
# watcher belonging to this workspace and must be killed.
P="$T/p7"; mkdir "$P"
_make_project "$P" "reloadtest"
P_REAL="$(cd "$P" && pwd -P)"
# Start an untagged legacy watcher under the canonical PROJECT_ROOT so lsof -d cwd reports P_REAL.
( cd "$P_REAL"; _bg_close_fds; exec bash "$LEGACY_DIR/agent-watch.sh" ) &
STRAY_PID=$!
_bg_track "$STRAY_PID"
# … and a BYSTANDER in the very same directory: pgrep hands it over too (its command line would match
# a substring scan just as a coordinator's `bash -c '… agent-watch.sh …'` wrapper does), but it is not
# executing the script, so reload must leave it alone.
( cd "$P_REAL"; _bg_close_fds; exec sleep 9999 ) &
BYSTANDER_PID=$!
_bg_track "$BYSTANDER_PID"
# pgrep stub will return both (as strays not in the lockfile).
( cd "$P" && FAKE_STRAY_PIDS="$STRAY_PID:$BYSTANDER_PID" HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload >/dev/null 2>&1 ) \
  || { kill "$STRAY_PID" "$BYSTANDER_PID" 2>/dev/null || true; fail "reload failed (stray-our test)"; }
sleep 0.3
kill -0 "$STRAY_PID" 2>/dev/null \
  && { kill "$STRAY_PID" 2>/dev/null || true; fail "stray in OUR workspace was not killed"; } \
  || true
ok

# ── 7b. HERD-524 (#636): a bystander in OUR cwd that is NOT running the script survives ──────────
if kill -0 "$BYSTANDER_PID" 2>/dev/null; then
  kill "$BYSTANDER_PID" 2>/dev/null || true
  ok   # bystander survived — the script-path guard worked
else
  fail "reload SIGKILLed a bystander process in the project root that was not executing agent-watch.sh"
fi

# ── 8. Stray guard — OTHER workspace: stray cwd != PROJECT_ROOT → NOT killed ─
# A process whose cwd is a DIFFERENT directory must never be killed — this is the
# guard against cmd_reload touching another workspace's watcher.
P="$T/p8"; mkdir "$P"
_make_project "$P" "reloadtest"
OTHER="$T/other_project"; mkdir -p "$OTHER"
OTHER_REAL="$(cd "$OTHER" && pwd -P)"
# Start an untagged legacy watcher from OTHER_REAL (simulates another workspace's watcher). It is a
# REAL one, so the ONLY thing standing between it and a SIGKILL is the cwd guard this test asserts.
( cd "$OTHER_REAL"; _bg_close_fds; exec bash "$LEGACY_DIR/agent-watch.sh" ) &
OTHER_PID=$!
_bg_track "$OTHER_PID"
( cd "$P" && FAKE_STRAY_PIDS="$OTHER_PID" HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload >/dev/null 2>&1 ) \
  || { kill "$OTHER_PID" 2>/dev/null || true; fail "reload failed (stray-other test)"; }
sleep 0.2
if kill -0 "$OTHER_PID" 2>/dev/null; then
  kill "$OTHER_PID" 2>/dev/null || true
  ok   # process survived — guard worked correctly
else
  fail "reload killed a process from another workspace (guard failure)"
fi

# ── 9. SIGKILL escalation: SIGTERM-ignoring process is killed by SIGKILL ──────
# Verifies the bounded-wait → SIGKILL path: a process that traps and ignores SIGTERM
# (as a watcher mid-review/merge would via deferred bash SIGTERM) must still be stopped.
# HERD_RELOAD_SIGTERM_POLLS=3 (0.6s wait) triggers the SIGKILL branch quickly.
P="$T/p9"; mkdir "$P"
_make_project "$P" "reloadtest"
lockfile="$P/trees/.watcher-reloadtest.pid"
# Fake watcher that ignores SIGTERM (simulates watcher blocked in a long child). SIG_IGN survives
# exec, so `trap '' TERM` before the `exec sleep` still leaves the final process ignoring TERM.
( trap '' TERM; _bg_close_fds; exec sleep 9999 ) &
STUBBORN=$!
_bg_track "$STUBBORN"
printf '%s\n' "$STUBBORN" > "$lockfile"
( cd "$P" && HERD_RELOAD_SIGTERM_POLLS=3 HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload >/dev/null 2>&1 ) \
  || { kill -9 "$STUBBORN" 2>/dev/null || true; fail "reload failed (SIGKILL escalation test)"; }
sleep 0.3
kill -0 "$STUBBORN" 2>/dev/null \
  && { kill -9 "$STUBBORN" 2>/dev/null || true; fail "SIGTERM-ignoring process was not killed by SIGKILL"; } \
  || true
[ -f "$lockfile" ] && fail "lockfile not removed after SIGKILL" || true
ok

# ── 10. EXIT trap guard: dying old watcher does not delete new watcher's lock ─
# The no-flock EXIT trap in agent-watch.sh guards with [ $(cat lockfile) = $$ ].
# Simulate: old watcher writes its PID, we replace it with a new PID (simulating
# cmd_reload relaunching a new watcher), then kill the old watcher — its EXIT trap
# must see the lockfile no longer contains its own PID and leave it alone.
P="$T/p10"; mkdir "$P"
_make_project "$P" "reloadtest"
lockfile="$P/trees/.watcher-reloadtest.pid"
mkdir -p "$P/trees"
# Old watcher subprocess with the guarded EXIT trap (mirrors agent-watch.sh exactly). This one can't
# `exec` its way into `sleep` (the EXIT trap needs a live bash to run when it's killed below), so
# `sleep 9999` stays a genuine forked CHILD of this subshell — close fds first so at least that child
# never holds bats's fd open; it is reaped explicitly (not just SIGTERM'd) right after the kill below.
(
  _bg_close_fds
  printf '%s\n' "$$" > "$lockfile"
  _watcher_lock_cleanup() {
    [ "$(cat "$lockfile" 2>/dev/null)" = "$$" ] \
      && rm -f "$lockfile" 2>/dev/null || true
  }
  trap '_watcher_lock_cleanup' EXIT
  trap '_watcher_lock_cleanup; exit 1' INT TERM
  sleep 9999
) &
OLD_WATCHER=$!
_bg_track "$OLD_WATCHER"
sleep 0.15   # let it write its PID

# Simulate cmd_reload removing old lock and new watcher writing its PID.
rm -f "$lockfile" 2>/dev/null || true
NEW_PID="77777"
printf '%s\n' "$NEW_PID" > "$lockfile"

# Kill the old watcher — its EXIT trap fires. The forked `sleep 9999` inside it is NOT auto-reaped
# when bash exits via a trap-driven `exit` (the "sleep-9999 orphan fallout" HERD-462 calls out) — grab
# it via `ps` (real `pgrep` is stubbed on PATH above, so it can't be used for our own bookkeeping)
# while the parent link still resolves, and reap it too once the parent is gone.
OLD_CHILD="$(ps -ax -o pid=,ppid= 2>/dev/null | awk -v pp="$OLD_WATCHER" '$2==pp{print $1; exit}')"
kill "$OLD_WATCHER" 2>/dev/null || true
sleep 0.3
[ -n "$OLD_CHILD" ] && kill -9 "$OLD_CHILD" 2>/dev/null || true

# The guarded EXIT trap should have left the lockfile alone (PID mismatch).
[ -f "$lockfile" ] \
  || fail "EXIT trap deleted the new watcher's lockfile (guard missing)"
cur="$(cat "$lockfile" 2>/dev/null || true)"
[ "$cur" = "$NEW_PID" ] \
  || fail "EXIT trap modified the new watcher's lockfile (got '$cur', want '$NEW_PID')"
ok

# Sanity: EXIT trap DOES remove the lock when file still contains the old PID.
rm -f "$lockfile" 2>/dev/null || true
(
  printf '%s\n' "$$" > "$lockfile"
  _watcher_lock_cleanup() {
    [ "$(cat "$lockfile" 2>/dev/null)" = "$$" ] \
      && rm -f "$lockfile" 2>/dev/null || true
  }
  trap '_watcher_lock_cleanup' EXIT
  # Exit naturally — no replacement PID written.
)
[ -f "$lockfile" ] \
  && fail "EXIT trap did not remove lockfile on natural exit (guard too aggressive)" || true
ok

# ═══ herdr control-room path (tests 11+) ═════════════════════════════════════
# Rich herdr stub: a file-backed simulation of the JSON API surface cmd_reload uses.
# State lives under $HERDR_STATE:
#   tabs/<tab_id>            file content = tab label
#   panes/<pane_id>/cmd      last `pane run` command (recorded, NEVER executed)
#   panes/<pane_id>/noshow   marker: process-info never shows cmd (invisible-pane bug sim)
#   neighbors/<pane>.<dir>   neighbor pane id for `pane neighbor`
#   agents.json              canned `agent list` response
#   log                      every invocation, one line, for assertions
# Env: FAKE_WS_LABEL (workspace label), FAKE_RUN_WRITES_LOCK=path:pid (pane run writes
# pid to path — simulates a detached watcher grabbing the lockfile).
RICH="$T/richbin"; mkdir -p "$RICH"
cat > "$RICH/herdr" <<'STUB'
#!/usr/bin/env bash
S="${HERDR_STATE:?}"; mkdir -p "$S/tabs" "$S/panes" "$S/neighbors"
echo "$*" >> "$S/log"
next_id(){ local n=0; [ -f "$S/seq" ] && n="$(cat "$S/seq")"; n=$((n+1)); echo "$n" > "$S/seq"; printf '%s' "$n"; }
case "${1:-} ${2:-}" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"%s"}]}}\n' "${FAKE_WS_LABEL:-}" ;;
  "tab list")
    python3 - "$S" <<'PY'
import sys,os,json
S=sys.argv[1]; d=os.path.join(S,"tabs")
tabs=[{"tab_id":t,"label":open(os.path.join(d,t)).read().strip()} for t in sorted(os.listdir(d))]
print(json.dumps({"result":{"tabs":tabs}}))
PY
    ;;
  "tab create")
    label=""; shift 2
    while [ $# -gt 0 ]; do case "$1" in --label) label="${2:-}"; shift 2 ;; *) shift ;; esac; done
    tid="t$(next_id)"; printf '%s' "$label" > "$S/tabs/$tid"
    pid="p$(next_id)"; mkdir -p "$S/panes/$pid"; printf '%s' "$tid" > "$S/panes/$pid/tab"
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tid" "$pid" ;;
  "tab close")
    tid="${3:-}"; rm -f "$S/tabs/$tid"
    # Closing a tab removes its panes (mirrors herdr: the panes go with the tab).
    for pd in "$S"/panes/*; do
      [ -d "$pd" ] || continue
      [ -f "$pd/tab" ] && [ "$(cat "$pd/tab")" = "$tid" ] && rm -rf "$pd"
    done
    printf '{"result":{}}\n' ;;
  "agent list")
    if [ -f "$S/agents.json" ]; then cat "$S/agents.json"; else printf '{"result":{"agents":[]}}\n'; fi ;;
  "agent start")
    # agent start <name> --workspace W --cwd R --tab T --split D -- claude /coordinator
    # (mirrors test-cli-pane.sh's stub — the --with-coordinator launch reuses the SAME
    # _pane_agent_start/herd_driver_launch_agent path `herd pane coordinator` exercises there)
    name="${3:-}"; tab=""; shift 3 2>/dev/null || shift $#
    while [ $# -gt 0 ]; do case "$1" in --tab) tab="${2:-}"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
    pid="p$(next_id)"; mkdir -p "$S/panes/$pid"; printf '%s' "$tab" > "$S/panes/$pid/tab"
    printf 'claude' > "$S/panes/$pid/cmd"
    # Reflect the new agent into agent list so a follow-up anchor resolve finds it.
    printf '{"result":{"agents":[{"name":"%s","pane_id":"%s","tab_id":"%s","workspace_id":"w1"}]}}\n' \
      "$name" "$pid" "$tab" > "$S/agents.json"
    printf '{"result":{"agent":{"pane_id":"%s"}}}\n' "$pid" ;;
  "pane list")
    # Enumerate every pane with its current tab_id (from $S/panes/<id>/tab). --workspace is
    # accepted and ignored; cmd_reload filters by tab_id itself.
    python3 - "$S" <<'PY'
import sys,os,json
S=sys.argv[1]; d=os.path.join(S,"panes")
panes=[]
for p in sorted(os.listdir(d)):
    tf=os.path.join(d,p,"tab")
    tab=open(tf).read().strip() if os.path.exists(tf) else ""
    panes.append({"pane_id":p,"tab_id":tab})
print(json.dumps({"result":{"panes":panes}}))
PY
    ;;
  "pane run")
    p="${3:-}"; mkdir -p "$S/panes/$p"; printf '%s' "${4:-}" > "$S/panes/$p/cmd"
    if [ -n "${FAKE_RUN_WRITES_LOCK:-}" ]; then
      printf '%s\n' "${FAKE_RUN_WRITES_LOCK##*:}" > "${FAKE_RUN_WRITES_LOCK%:*}"
    fi
    printf '{"result":{}}\n' ;;
  "pane close")
    rm -rf "$S/panes/${3:-}"; printf '{"result":{}}\n' ;;
  "pane move")
    # Forms: pane move <pane> --tab T --split D --target-pane P --ratio R --no-focus
    #        pane move <pane> --new-tab --no-focus
    p="${3:-}"; tgt_tab=""; new_tab=0; shift 3 2>/dev/null || shift $#
    while [ $# -gt 0 ]; do case "$1" in
      --tab) tgt_tab="${2:-}"; shift 2 ;;
      --new-tab) new_tab=1; shift ;;
      *) shift ;;
    esac; done
    mkdir -p "$S/panes/$p"
    cur=""; [ -f "$S/panes/$p/tab" ] && cur="$(cat "$S/panes/$p/tab")"
    if [ "$new_tab" -eq 1 ]; then
      tid="t$(next_id)"; printf 'temp-move' > "$S/tabs/$tid"; printf '%s' "$tid" > "$S/panes/$p/tab"
      printf '{"result":{"changed":true}}\n'
    elif [ -n "$tgt_tab" ] && [ "$cur" = "$tgt_tab" ]; then
      printf '{"result":{"changed":false,"reason":"same_tab"}}\n'
    else
      printf '%s' "$tgt_tab" > "$S/panes/$p/tab"
      printf '{"result":{"changed":true}}\n'
    fi ;;
  "pane process-info")
    p="${4:-}"
    # WEDGE sim (HERD-208): when FAKE_HANG names this pane ("all" or its id), NEVER return — model the
    # WSL2 hang where `herdr pane process-info` blocks forever. exec sleep so the process IS the sleep
    # and the caller's `timeout` kills it directly (no orphaned child left behind).
    case "${FAKE_HANG:-}" in
      "") : ;;
      all) exec sleep 120 ;;
      *) case " ${FAKE_HANG} " in *" $p "*) exec sleep 120 ;; esac ;;
    esac
    if [ ! -d "$S/panes/$p" ]; then printf '{"result":{}}\n'; exit 0; fi
    cmd=""
    [ -f "$S/panes/$p/cmd" ] && [ ! -f "$S/panes/$p/noshow" ] && cmd="$(cat "$S/panes/$p/cmd")"
    # fgcmd: what the pane's FOREGROUND process reports ONCE something has been run in it, when that
    # differs from the command that was typed. Real launches diverge the moment the launched process
    # re-execs — agent-watch.sh re-execs ONCE under its per-workspace argv0 marker, after which the
    # cmdline is `herd-watch-<slug> …/agent-watch.sh` and carries no `bash` token at all (HERD-458 /
    # GH #572). Gated on a recorded `cmd` so the pane still reads BARE (adoptable) before the run.
    [ -f "$S/panes/$p/fgcmd" ] && [ -f "$S/panes/$p/cmd" ] && cmd="$(cat "$S/panes/$p/fgcmd")"
    if [ -n "$cmd" ]; then
      printf '{"result":{"process_info":{"shell_pid":4242,"foreground_processes":[{"pid":5151,"cmdline":"%s"}]}}}\n' "$cmd"
    else
      printf '{"result":{"process_info":{"shell_pid":4242,"foreground_processes":[]}}}\n'
    fi ;;
  "pane neighbor")
    d="${4:-}"; p="${6:-}"; nb=""
    [ -f "$S/neighbors/$p.$d" ] && nb="$(cat "$S/neighbors/$p.$d")"
    if [ -n "$nb" ]; then
      printf '{"result":{"neighbor":{"pane_id":"%s","neighbor_pane_id":"%s"}}}\n' "$p" "$nb"
    else
      printf '{"result":{"neighbor":{"pane_id":"%s"}}}\n' "$p"
    fi ;;
  "pane split")
    # New pane inherits the split target's tab (positional target is $3).
    tgt="${3:-}"; p="p$(next_id)"; mkdir -p "$S/panes/$p"
    if [ -n "$tgt" ] && [ -f "$S/panes/$tgt/tab" ]; then cp "$S/panes/$tgt/tab" "$S/panes/$p/tab"; fi
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$p" ;;
  "pane swap")
    printf '{"result":{}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
exit 0
STUB
chmod +x "$RICH/herdr"

# _rich_reload PROJECT STATE [env VAR=VAL ...] — run reload against the rich stub.
# HERD_RELOAD_SKIP_LAUNCH=fallback keeps it hermetic: even if the herdr path fails,
# no real background watcher is ever spawned.
_rich_reload() {
  local proj="$1" state="$2"; shift 2
  ( cd "$proj" && env PATH="$RICH:$PATH" HERDR_STATE="$state" FAKE_WS_LABEL="reloadtest" \
      HERD_RELOAD_SKIP_LAUNCH=fallback HERD_RELOAD_PANE_POLLS=2 HERD_RELOAD_VERIFY_POLLS=2 \
      HERD_RELOAD_LOCKPID_POLLS=1 \
      "$@" bash "$HERD" reload 2>&1 )
}

# _rich_coord_state STATE — coordinator control-room fixture: tab tC labeled as the
# coordinator, agent pane pA, bare backlog pane pL left of it, bare watch pane pW below.
# All three panes carry tab=tC so the coordinator-tab SNAPSHOT (pane list) sees them.
_rich_coord_state() {
  local S="$1"
  mkdir -p "$S/tabs" "$S/panes/pA" "$S/panes/pL" "$S/panes/pW" "$S/neighbors"
  printf 'coordinator-reloadtest' > "$S/tabs/tC"
  printf 'tC' > "$S/panes/pA/tab"
  printf 'tC' > "$S/panes/pL/tab"
  printf 'tC' > "$S/panes/pW/tab"
  printf 'pL' > "$S/neighbors/pA.left"
  printf 'pW' > "$S/neighbors/pA.down"
  printf '%s\n' '{"result":{"agents":[{"name":"coordinator-reloadtest","pane_id":"pA","tab_id":"tC","workspace_id":"w1"}]}}' \
    > "$S/agents.json"
}

# ── 11. no coordinator tab → build ONE canonical control room (never standalone tabs) ─
# When the coordinator tab is entirely gone (e.g. run from a brand-new external terminal with
# no control room up), reload builds the full canonical tab shape [ backlog | coordinator ⟂
# watch ] in a SINGLE coordinator-labelled tab. It never creates stray watch-*/backlog-* tabs,
# and — per its invariant — never starts the coordinator agent; that pane is left with a hint.
P="$T/p11"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state11"
out="$(_rich_reload "$P" "$S")" || fail "reload failed (canonical rebuild path)"
grep -q "building a fresh canonical control room" <<< "$out" || fail "did not announce a canonical rebuild"
grep -q "tab create .*--label coordinator-reloadtest" "$S/log" || fail "coordinator tab not created"
grep -q "tab create .*--label watch-reloadtest" "$S/log" && fail "created a stray standalone watch tab" || true
grep -q "tab create .*--label backlog-reloadtest" "$S/log" && fail "created a stray standalone backlog tab" || true
grep -rl "herd-watch.sh" "$S/panes" >/dev/null || fail "no pane received the watch script"
grep -rl "backlog-view.sh" "$S/panes" >/dev/null || fail "no pane received backlog-view.sh"
grep -q "start it yourself" <<< "$out" || fail "missing coordinator-agent restart hint"
# Registry written from the observed rebuilt panes.
P11_REAL="$(cd "$P" && pwd -P)"
grep -q "coordinator-agent" "$P11_REAL/trees/.herd-panes" || fail "registry missing coordinator-agent row"
grep -q "^watch "   "$P11_REAL/trees/.herd-panes" || fail "registry missing watch row"
grep -q "^backlog " "$P11_REAL/trees/.herd-panes" || fail "registry missing backlog row"
ok

# ── 12. coordinator layout: watch below + backlog left reused; coordinator untouched ─
P="$T/p12"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state12"; _rich_coord_state "$S"
out="$(_rich_reload "$P" "$S")" || fail "reload failed (coordinator layout)"
grep -q "herd-watch.sh" "$S/panes/pW/cmd" 2>/dev/null || fail "watch script not run in the pane below the coordinator"
grep -q "backlog-view.sh" "$S/panes/pL/cmd" 2>/dev/null || fail "backlog-view not run in the pane left of the coordinator"
grep -q "pane below coordinator" <<< "$out" || fail "output missing 'pane below coordinator'"
grep -q "visible ✓" <<< "$out" || fail "watcher visibility not reported (coordinator layout)"
grep -q "tab close tC" "$S/log" && fail "reload CLOSED the coordinator tab (must never happen)" || true
grep -q "pane split" "$S/log" && fail "reload split a pane when both panes were reusable" || true
[ -f "$S/tabs/tC" ] || fail "coordinator tab is gone from state"
# HERD-650: reload labels all three control-room panes on every pass, not just at create.
grep -q "pane rename pA coordinator·reloadtest" "$S/log" || fail "reload did not label the coordinator pane"
grep -q "pane rename pL backlog·reloadtest"     "$S/log" || fail "reload did not label the backlog pane"
grep -q "pane rename pW watch·reloadtest"       "$S/log" || fail "reload did not label the watch pane"
ok

# ── 13. live backlog pane is left completely untouched ────────────────────────
P="$T/p13"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state13"; _rich_coord_state "$S"
printf 'bash /somewhere/backlog-view.sh' > "$S/panes/pL/cmd"   # already live
out="$(_rich_reload "$P" "$S")" || fail "reload failed (live backlog test)"
grep -q "already live ✓" <<< "$out" || fail "live backlog pane not reported as already live"
grep -q "pane run pL" "$S/log" && fail "reload re-ran a command in the LIVE backlog pane" || true
ok

# ── 14. invisible-watcher bug: run lands detached → retry once, then LOUD report ─
# The watch pane never shows the command (noshow), but each pane run "starts" a detached
# watcher that grabs the lockfile (FAKE_RUN_WRITES_LOCK with a live PID). Reload must
# retry the pane run once, detect the running-but-invisible watcher via the lockfile,
# and report it loudly — never a silent zombie pane, never a duplicate spawn.
P="$T/p14"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state14"; _rich_coord_state "$S"
touch "$S/panes/pW/noshow"
( _bg_close_fds; exec sleep 999 ) & ZPID=$!
_bg_track "$ZPID"
lockfile="$P/trees/.watcher-reloadtest.pid"
out="$(_rich_reload "$P" "$S" FAKE_RUN_WRITES_LOCK="$lockfile:$ZPID")" \
  || { kill "$ZPID" 2>/dev/null || true; fail "reload failed (invisible-watcher test)"; }
runs="$(grep -c "pane run pW" "$S/log" || true)"
[ "$runs" -eq 2 ] || { kill "$ZPID" 2>/dev/null || true; fail "expected exactly 2 pane run attempts (retry once), got $runs"; }
grep -q "RUNNING but NOT visible" <<< "$out" \
  || { kill "$ZPID" 2>/dev/null || true; fail "invisible watcher not reported loudly"; }
grep -q "DETACHED" <<< "$out" \
  || { kill "$ZPID" 2>/dev/null || true; fail "summary missing DETACHED watcher state"; }
[ "$(cat "$lockfile" 2>/dev/null)" = "$ZPID" ] \
  || { kill "$ZPID" 2>/dev/null || true; fail "detached watcher's lockfile was clobbered"; }
kill "$ZPID" 2>/dev/null || true
ok

# ── 15. missing backlog pane → split coordinator + swap into the LEFT slot ────
P="$T/p15"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state15"; _rich_coord_state "$S"
rm -f "$S/neighbors/pA.left"   # user closed the backlog pane
out="$(_rich_reload "$P" "$S")" || fail "reload failed (missing backlog pane)"
grep -q "pane split pA --direction right" "$S/log" || fail "missing backlog pane did not split the coordinator pane"
grep -q "pane swap --source-pane" "$S/log" || fail "recreated backlog pane was not swapped into the left slot"
grep -q "recreated ✓" <<< "$out" || fail "recreated backlog pane not verified/reported"
ok

# ── 16. verify-failure without a detached watcher → loud warning, fallback suppressed ─
P="$T/p16"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state16"; _rich_coord_state "$S"
touch "$S/panes/pW/noshow"     # pane run never becomes visible, and nothing grabs the lock
out="$(_rich_reload "$P" "$S")" || fail "reload failed (verify-failure test)"
grep -q "NOT relaunched" <<< "$out" || fail "suppressed fallback not reported after verify failure"
ok

# ═══ pane registry path (tests 17+) ══════════════════════════════════════════
# coordinator.sh writes $WORKTREES_DIR/.herd-panes on creation; reload reads it to
# refresh panes in-place rather than always creating standalone tabs.

# ── 17. registry panes adopted in-place; no duplicate pane/tab created ─────────
# Pre-populate .herd-panes pointing to pW_r (watch) and pL_r (backlog) — panes that differ
# from the neighbour-derived pW/pL. Reload must ADOPT the registry panes (run the scripts in
# pW_r / pL_r) and never split a fresh duplicate or create a tab. (A read-only geometry
# neighbour check may still run — it is the SPLIT that would strand a duplicate pane.)
P="$T/p17"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state17"; _rich_coord_state "$S"
# Create the registry-specified panes as BARE panes in the stub, tagged into the coord tab.
mkdir -p "$S/panes/pW_r" "$S/panes/pL_r"; printf 'tC' > "$S/panes/pW_r/tab"; printf 'tC' > "$S/panes/pL_r/tab"
P17_REAL="$(cd "$P" && pwd -P)"
cat > "$P17_REAL/trees/.herd-panes" <<REG
coordinator-agent pA tC
backlog pL_r tC
watch pW_r tC
REG
out="$(_rich_reload "$P" "$S")" || fail "reload failed (registry in-place test)"
grep -q "pane run pW_r" "$S/log" || fail "watch script not run in registry-specified watch pane"
grep -q "pane run pL_r" "$S/log" || fail "backlog script not run in registry-specified backlog pane"
grep -q "pane split" "$S/log" && fail "split a duplicate pane when registry panes were usable" || true
grep -q "tab create" "$S/log" && fail "created a tab when registry panes were usable" || true
ok

# ── 18. registry watch pane GONE → falls back to neighbor/split; backlog from registry ─
# The watch pane in the registry no longer exists (pane dir absent = GONE); the
# registered backlog pane (pL_r) still exists and should be used without a neighbor query.
P="$T/p18"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state18"; _rich_coord_state "$S"
mkdir -p "$S/panes/pL_r"   # pW_gone intentionally absent — GONE
P18_REAL="$(cd "$P" && pwd -P)"
cat > "$P18_REAL/trees/.herd-panes" <<REG
coordinator-agent pA tC
backlog pL_r tC
watch pW_gone tC
REG
out="$(_rich_reload "$P" "$S")" || fail "reload failed (registry watch pane gone)"
# pW_gone is GONE → reload falls through to neighbor (pA.down=pW) or splits; either way
# the watch ends up in the coordinator tab.
grep -q "pane below coordinator" <<< "$out" \
  || fail "watch not placed in coordinator tab after registry pane was gone"
# backlog from registry (pL_r) used without a neighbor query.
grep -q "pane run pL_r" "$S/log" \
  || fail "backlog not run in registry pane when registry backlog pane was still valid"
ok

# ── 19. coordinator tab gone with STALE registry → canonical rebuild, not standalone ─
# The registry exists but the coordinator tab no longer appears in herdr tab list (its panes
# are gone too). A stale registry must NOT resurrect standalone tabs: reload rebuilds the full
# canonical control room in one coordinator tab, ignoring the dead registry pane IDs.
P="$T/p19"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state19"
mkdir -p "$S/tabs" "$S/panes" "$S/neighbors"
# No coordinator tab in state; agent list is empty → no anchor from the live roster.
printf '{"result":{"agents":[]}}\n' > "$S/agents.json"
P19_REAL="$(cd "$P" && pwd -P)"
cat > "$P19_REAL/trees/.herd-panes" <<REG
coordinator-agent pA_dead tC
backlog pL_dead tC
watch pW_dead tC
REG
out="$(_rich_reload "$P" "$S")" || fail "reload failed (coordinator tab gone)"
grep -q "building a fresh canonical control room" <<< "$out" \
  || fail "stale registry: expected a canonical rebuild when the coordinator tab is gone"
grep -q "tab create .*--label coordinator-reloadtest" "$S/log" \
  || fail "coordinator tab not rebuilt when tab was gone"
grep -q "tab create .*--label watch-reloadtest" "$S/log" \
  && fail "resurrected a standalone watch tab from a stale registry" || true
grep -rl "herd-watch.sh" "$S/panes" >/dev/null || fail "watcher not placed after rebuild"
ok

# ── 20. pid in summary comes from lockfile, not transient process-info ────────
# FAKE_RUN_WRITES_LOCK makes the stub write a specific pid to the lockfile during
# pane run. The summary must show that pid — not the 5151 returned by process-info —
# confirming the fix for the transient-fork-pid bug.
P="$T/p20"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state20"; _rich_coord_state "$S"
P20_REAL="$(cd "$P" && pwd -P)"
lockfile="$P20_REAL/trees/.watcher-reloadtest.pid"
FAKE_PID="55555"
out="$(_rich_reload "$P" "$S" FAKE_RUN_WRITES_LOCK="$lockfile:$FAKE_PID")" \
  || fail "reload failed (lockfile pid test)"
grep -q "pid $FAKE_PID" <<< "$out" \
  || fail "summary pid should come from lockfile (expected pid $FAKE_PID, got: $(printf '%s' "$out" | grep pid || echo none))"
ok

# ═══ bootstrap / seeding tests (tests 21+) ════════════════════════════════════
# These cover the gap found in the reload-in-place live-smoke: a long-lived control room
# that predates coordinator.sh writing .herd-panes has no registry, so reload must
# SEED it on the first run and REUSE those IDs on every subsequent run.

# ── 21. migration: coordinator tab present, legacy agent name → splits in coordinator tab, registry written ─
# Simulates a long-lived control room whose coordinator agent has an old name ("coordinator"
# instead of the workspace-scoped "coordinator-reloadtest"). The fallback agent search must
# find the agent by tab_id match, use it as anchor for watch/backlog splits inside the
# coordinator tab, and write the registry — all without creating standalone tabs.
P="$T/p21"; mkdir "$P"
_make_project "$P" "reloadtest"
P21_REAL="$(cd "$P" && pwd -P)"
S="$T/state21"
mkdir -p "$S/tabs" "$S/panes/pA" "$S/panes/pL" "$S/panes/pW" "$S/neighbors"
printf 'coordinator-reloadtest' > "$S/tabs/tC"
printf 'tC' > "$S/panes/pA/tab"
printf 'pL' > "$S/neighbors/pA.left"
printf 'pW' > "$S/neighbors/pA.down"
# Agent registered under a LEGACY name ("coordinator", not "coordinator-reloadtest").
printf '%s\n' '{"result":{"agents":[{"name":"coordinator","pane_id":"pA","tab_id":"tC","workspace_id":"w1"}]}}' \
  > "$S/agents.json"
# No .herd-panes registry.
out="$(_rich_reload "$P" "$S")" || fail "reload failed (legacy agent name migration)"
# Watch and backlog scripts must be placed inside the coordinator tab (not standalone tabs).
grep -q "herd-watch.sh" "$S/panes/pW/cmd" 2>/dev/null \
  || fail "migration: watch script not in coordinator-tab pane (should not take standalone path)"
grep -q "backlog-view.sh" "$S/panes/pL/cmd" 2>/dev/null \
  || fail "migration: backlog script not in coordinator-tab pane"
# No standalone watch tab should have been created.
grep -q "watch-reloadtest" <<< "$(grep "tab create" "$S/log" 2>/dev/null || true)" && fail "migration: standalone watch tab created — fallback not suppressed" || true
# Registry must be written with the pane IDs actually used.
[ -f "$P21_REAL/trees/.herd-panes" ] \
  || fail "migration: .herd-panes not written after seeding run"
grep -q "watch" "$P21_REAL/trees/.herd-panes" \
  || fail "migration: registry missing watch row"
grep -q "backlog" "$P21_REAL/trees/.herd-panes" \
  || fail "migration: registry missing backlog row"
ok

# ── 22. second reload with registry → same pane IDs reused, zero new tabs/panes ─
# After the first reload writes the registry (path A, coordinator tab present), the second
# reload must reuse the recorded pane IDs and issue no tab create or pane split calls.
P="$T/p22"; mkdir "$P"
_make_project "$P" "reloadtest"
P22_REAL="$(cd "$P" && pwd -P)"
S="$T/state22"; _rich_coord_state "$S"
# First reload: no registry → creates panes via neighbor/split, writes registry.
_rich_reload "$P" "$S" >/dev/null || fail "first reload failed (second-reload reuse test)"
[ -f "$P22_REAL/trees/.herd-panes" ] \
  || fail "first reload did not write the registry"
# Record tab-create and pane-split call counts after first reload.
tabs_after_1="$(grep -c "tab create" "$S/log" 2>/dev/null || true)"
splits_after_1="$(grep -c "pane split" "$S/log" 2>/dev/null || true)"
# Second reload: registry exists → should reuse pane IDs; no new tabs or splits.
_rich_reload "$P" "$S" >/dev/null || fail "second reload failed (reuse test)"
tabs_after_2="$(grep -c "tab create" "$S/log" 2>/dev/null || true)"
splits_after_2="$(grep -c "pane split" "$S/log" 2>/dev/null || true)"
[ "$tabs_after_2" -eq "$tabs_after_1" ] \
  || fail "second reload created new tabs (tab create count: $tabs_after_1 → $tabs_after_2)"
[ "$splits_after_2" -eq "$splits_after_1" ] \
  || fail "second reload split new panes (pane split count: $splits_after_1 → $splits_after_2)"
ok

# ── 23. canonical-rebuild path writes registry from the OBSERVED rebuilt panes ─────
# When the coordinator tab is absent, reload rebuilds it and must write .herd-panes with the
# coordinator-agent / backlog / watch pane IDs it actually created — the panes that received
# the scripts — so the next reload adopts them in-place.
P="$T/p23"; mkdir "$P"
_make_project "$P" "reloadtest"
P23_REAL="$(cd "$P" && pwd -P)"
S="$T/state23"
mkdir -p "$S/tabs" "$S/panes" "$S/neighbors"
# No coordinator tab; empty agent list → forces the canonical-rebuild path.
printf '{"result":{"agents":[]}}\n' > "$S/agents.json"
out="$(_rich_reload "$P" "$S")" || fail "reload failed (canonical-rebuild registry test)"
[ -f "$P23_REAL/trees/.herd-panes" ] \
  || fail "canonical-rebuild path did not write .herd-panes"
reg="$(cat "$P23_REAL/trees/.herd-panes")"
grep -q "coordinator-agent" <<< "$reg" || fail "registry missing coordinator-agent row"
grep -q "watch" <<< "$reg" || fail "registry missing watch row"
grep -q "backlog" <<< "$reg" || fail "registry missing backlog row"
# The pane IDs in the registry must be the ones that actually received the scripts.
watch_pane_id="$(awk '$1=="watch"  {print $2}' "$P23_REAL/trees/.herd-panes")"
backlog_pane_id="$(awk '$1=="backlog" {print $2}' "$P23_REAL/trees/.herd-panes")"
[ -n "$watch_pane_id" ] && grep -q "herd-watch.sh" "$S/panes/$watch_pane_id/cmd" 2>/dev/null \
  || fail "registry watch pane did not receive the watch script"
[ -n "$backlog_pane_id" ] && grep -q "backlog-view.sh" "$S/panes/$backlog_pane_id/cmd" 2>/dev/null \
  || fail "registry backlog pane did not receive backlog-view.sh"
ok

# ═══ convergence tests (tests 24+) — reach the canonical state from ANY context ══
# The anchor bug: the coordinator tab, its panes, and the registry are all intact, but the
# coordinator claude was Ctrl+C'd so `herdr agent list` shows no agent in the tab. Reload must
# still rebuild INSIDE the coordinator tab (adopting the registry anchor) — never fall through
# to standalone tabs — and leave a hint to restart the agent.

# ── 24. run-from-bare-shell: coordinator tab present, ZERO live agents, registry intact ─
P="$T/p24"; mkdir "$P"
_make_project "$P" "reloadtest"
P24_REAL="$(cd "$P" && pwd -P)"
S="$T/state24"; _rich_coord_state "$S"
printf '{"result":{"agents":[]}}\n' > "$S/agents.json"   # claude Ctrl+C'd — no live agent
printf 'bash /x/backlog-view.sh' > "$S/panes/pL/cmd"     # backlog viewer still running
cat > "$P24_REAL/trees/.herd-panes" <<REG
coordinator-agent pA tC
backlog pL tC
watch pW tC
REG
out="$(_rich_reload "$P" "$S")" || fail "reload failed (bare-shell no-agent path)"
grep -q "tab create" "$S/log" && fail "no-agent reload created a tab (must rebuild in coordinator tab)" || true
grep -q "herd-watch.sh" "$S/panes/pW/cmd" 2>/dev/null \
  || fail "watch not (re)launched in the coordinator-tab watch pane"
grep -q "pane run pA" "$S/log" && fail "reload ran a command in the coordinator (anchor) pane" || true
grep -q "pane run pL" "$S/log" && fail "reload re-ran the still-live backlog viewer" || true
grep -q "start it yourself" <<< "$out" || fail "missing restart hint for the dead coordinator agent"
[ -f "$S/tabs/tC" ] || fail "coordinator tab was destroyed"
# Registry preserved with coordinator-tab pane IDs.
grep -q "^coordinator-agent pA tC" "$P24_REAL/trees/.herd-panes" || fail "registry coordinator-agent row not preserved"
grep -q "^watch pW tC"   "$P24_REAL/trees/.herd-panes" || fail "registry watch row not updated to coord-tab pane"
grep -q "^backlog pL tC" "$P24_REAL/trees/.herd-panes" || fail "registry backlog row not preserved"
ok

# ── 25. run-with-live-agent / external terminal: adopt, coordinator pane never hijacked ─
P="$T/p25"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state25"; _rich_coord_state "$S"
printf 'bash /x/backlog-view.sh' > "$S/panes/pL/cmd"   # live backlog
out="$(_rich_reload "$P" "$S")" || fail "reload failed (live-agent adopt path)"
grep -q "pane run pA" "$S/log" && fail "reload wrote into the live coordinator pane" || true
grep -q "tab create" "$S/log" && fail "reload created a tab when the control room was up" || true
grep -q "herd-watch.sh" "$S/panes/pW/cmd" 2>/dev/null || fail "watcher not relaunched below coordinator"
grep -q "already live ✓" <<< "$out" || fail "live backlog not adopted"
grep -q "start it yourself" <<< "$out" && fail "printed a restart hint while the agent was live" || true
ok

# ── 26. watch-pane-spanning-bottom geometry repair via re-parent (bounce out/in) ─
# The watch pane spans the full bottom (it is the downward neighbour of BOTH the backlog and
# the coordinator), robbing the backlog of its full-height left column. Reload must re-parent
# it BELOW the coordinator. A same-tab move is a no-op, so the recipe bounces it out to a temp
# tab (--new-tab) and back (--target-pane pA).
P="$T/p26"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state26"; _rich_coord_state "$S"
printf 'bash /x/backlog-view.sh' > "$S/panes/pL/cmd"   # live backlog
printf 'pW' > "$S/neighbors/pL.down"                    # watch spans below the backlog too
cat > "$(cd "$P" && pwd -P)/trees/.herd-panes" <<REG
coordinator-agent pA tC
backlog pL tC
watch pW tC
REG
out="$(_rich_reload "$P" "$S")" || fail "reload failed (geometry repair path)"
grep -q "pane move pW --new-tab" "$S/log" || fail "spanning watch pane not bounced out for re-parenting"
grep -q "pane move pW --tab tC --split down --target-pane pA" "$S/log" \
  || fail "watch pane not re-parented below the coordinator"
ok

# ── 27. duplicate backlog viewer adoption: one adopted, the other closed ──────────
# A stale registry + missed neighbour query once split a SECOND backlog-view pane beside a
# still-live one in the same tab. Reload must adopt one and CLOSE the duplicate — never leave
# two viewers, never split a third.
P="$T/p27"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state27"; _rich_coord_state "$S"
mkdir -p "$S/panes/pD"; printf 'tC' > "$S/panes/pD/tab"
printf 'bash /x/backlog-view.sh' > "$S/panes/pL/cmd"   # viewer 1
printf 'bash /x/backlog-view.sh' > "$S/panes/pD/cmd"   # viewer 2 (duplicate)
out="$(_rich_reload "$P" "$S")" || fail "reload failed (duplicate backlog test)"
closed="$(grep -c "pane close" "$S/log" 2>/dev/null || true)"
[ "$closed" -eq 1 ] || fail "expected exactly one duplicate backlog pane closed, got $closed"
grep -q "pane split" "$S/log" && fail "split a new backlog pane when two already existed" || true
# Exactly one backlog viewer pane survives.
survivors=0
for pd in "$S"/panes/*; do
  [ -f "$pd/cmd" ] && grep -q "backlog-view.sh" "$pd/cmd" 2>/dev/null && survivors=$((survivors+1))
done
[ "$survivors" -eq 1 ] || fail "expected exactly one surviving backlog viewer, got $survivors"
ok

# ── 28. stray standalone tabs folded back into the coordinator tab ────────────────
# Earlier bad reloads left watch-<ws>/backlog-<ws> standalone tabs. Reload must close them and
# re-establish both roles inside the coordinator tab.
P="$T/p28"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state28"; _rich_coord_state "$S"
# Stray standalone tabs with their own panes.
printf 'watch-reloadtest'   > "$S/tabs/tW"; mkdir -p "$S/panes/pSW"; printf 'tW' > "$S/panes/pSW/tab"; printf 'bash /x/herd-watch.sh' > "$S/panes/pSW/cmd"
printf 'backlog-reloadtest' > "$S/tabs/tB"; mkdir -p "$S/panes/pSB"; printf 'tB' > "$S/panes/pSB/tab"; printf 'bash /x/backlog-view.sh' > "$S/panes/pSB/cmd"
out="$(_rich_reload "$P" "$S")" || fail "reload failed (stray fold-back test)"
grep -q "tab close tW" "$S/log" || fail "stray watch tab not closed"
grep -q "tab close tB" "$S/log" || fail "stray backlog tab not closed"
[ ! -f "$S/tabs/tW" ] || fail "stray watch tab still present after fold-back"
[ ! -f "$S/tabs/tB" ] || fail "stray backlog tab still present after fold-back"
grep -q "herd-watch.sh"  "$S/panes/pW/cmd" 2>/dev/null || fail "watch role not re-established in coordinator tab"
grep -q "backlog-view.sh" "$S/panes/pL/cmd" 2>/dev/null || fail "backlog role not re-established in coordinator tab"
[ -f "$S/tabs/tC" ] || fail "coordinator tab was closed during fold-back"
ok

# ═══ issue #60 fix 1: argv0 watcher attribution across two projects (tests 29+) ══════════════════
# A fake watcher = an innocuous `sleep` re-exec'd under a distinctive per-workspace argv0
# (herd-watch-<slug>), exactly as agent-watch.sh tags itself at startup. `ps -o command=` shows that
# argv0; the pgrep stub returns whichever pids the test declares (FAKE_STRAY_PIDS), and the REAL
# `ps` argv0 check inside _list_project_watchers / _stop_project_watcher is what distinguishes them.
# `exec -a M sleep` (NOT `exec -a M bash …`) keeps argv0==M AND lets a plain SIGTERM stop it promptly.
# Fully hermetic — never touches a real watcher, only sleeps we spawn and reap.
# Redirect the sleep's std fds so the backgrounded process does NOT hold the command-substitution
# pipe open (else `$(_spawn_tagged …)` blocks for the full sleep). `exec -a M sleep` keeps argv0==M.
# `_bg_close_fds` first (HERD-462) so this fake watcher can never hold bats's own fd open either.
# NOTE: callers capture the printed pid via `$(...)`, which runs this function in a SUBSHELL — a
# `_bg_track` call made IN HERE would only update that subshell's copy of `_BG_PIDS`. Callers must
# `_bg_track` the captured pid themselves.
_spawn_tagged() { ( _bg_close_fds; exec -a "$1" sleep 9999 ) >/dev/null 2>&1 & echo $!; }   # $1 = marker → prints pid

# ── 29. reload in project X reaps X's argv0 watchers (lock + lock-absent stray); Y SURVIVES ──────
# Two fake projects share the engine. Project X has TWO tagged watchers — one recorded in its
# lockfile, one a lock-ABSENT stray — plus project Y has its own tagged watcher. `herd reload` in X
# must SIGTERM both of X's (proving the lock-absent stray is now reaped) and be PROVABLY INERT for
# Y's, even though all three are the identical `sleep` re-exec differing only in argv0.
PX="$T/px"; mkdir "$PX"; _make_project "$PX" "projx"
PY="$T/py"; mkdir "$PY"; _make_project "$PY" "projy"
X_LOCK="$(_spawn_tagged herd-watch-projx)"     # X's lockfile watcher
X_STRAY="$(_spawn_tagged herd-watch-projx)"    # X's lock-ABSENT stray (invisible to the old code)
Y_LIVE="$(_spawn_tagged herd-watch-projy)"     # project Y's live watcher — must never be touched
_bg_track "$X_LOCK"; _bg_track "$X_STRAY"; _bg_track "$Y_LIVE"
sleep 0.3
printf '%s\n' "$X_LOCK" > "$PX/trees/.watcher-projx.pid"
# The stubbed pgrep returns all three pids (as a real pgrep across the process table would); the
# argv0 ps-check does the attribution.
( cd "$PX" && FAKE_STRAY_PIDS="$X_LOCK:$X_STRAY:$Y_LIVE" HERD_RELOAD_SIGTERM_POLLS=3 \
    HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload >/dev/null 2>&1 ) \
  || { kill "$X_LOCK" "$X_STRAY" "$Y_LIVE" 2>/dev/null; fail "reload failed (two-project argv0 test)"; }
sleep 0.4
kill -0 "$X_LOCK"  2>/dev/null && { kill "$X_LOCK" "$X_STRAY" "$Y_LIVE" 2>/dev/null; fail "X's lockfile watcher not reaped"; }
kill -0 "$X_STRAY" 2>/dev/null && { kill "$X_STRAY" "$Y_LIVE" 2>/dev/null; fail "X's lock-ABSENT argv0 stray not reaped (the 'no running watcher while 2 alive' bug)"; }
kill -0 "$Y_LIVE"  2>/dev/null || fail "project Y's argv0 watcher was reaped by X's reload (cross-project kill)"
kill "$Y_LIVE" 2>/dev/null || true
ok

# ── 30. stop is inert for Y even when Y shares X's PROJECT_ROOT cwd — argv0 gate beats cwd ───────
# A sibling watcher tagged for Y whose cwd happens to match X's PROJECT_ROOT must STILL survive: the
# foreign-argv0 guard in the legacy cwd fallback skips any herd-watch-* process that is not ours.
PX2="$T/px2"; mkdir "$PX2"; _make_project "$PX2" "projx"
PX2_REAL="$(cd "$PX2" && pwd -P)"
# A Y-tagged watcher whose cwd IS X's root (would be killed by the cwd fallback if argv0 weren't gated).
( cd "$PX2_REAL"; _bg_close_fds; exec -a "herd-watch-projy" sleep 9999 ) & YCWD=$!
_bg_track "$YCWD"
sleep 0.3
( cd "$PX2" && FAKE_STRAY_PIDS="$YCWD" HERD_RELOAD_SIGTERM_POLLS=3 \
    HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload >/dev/null 2>&1 ) \
  || { kill "$YCWD" 2>/dev/null; fail "reload failed (argv0-beats-cwd test)"; }
sleep 0.3
kill -0 "$YCWD" 2>/dev/null || fail "a foreign-argv0 watcher sharing our cwd was killed (argv0 guard failed)"
kill "$YCWD" 2>/dev/null || true
ok

# ── 31. legacy UNTAGGED watcher (no argv0 marker) in our cwd is still reaped via the cwd fallback ─
# Back-compat: a watcher started before the argv0 marker existed shows as `bash …/agent-watch.sh` with
# no herd-watch-* argv0. It must still be reaped when its cwd is our PROJECT_ROOT. HERD-524: the leg
# proves the candidate is EXECUTING the script (a bystander in the same cwd is spared — test 7b), so
# this fixture runs the real thing rather than a bare `sleep`.
PX3="$T/px3"; mkdir "$PX3"; _make_project "$PX3" "projx"
PX3_REAL="$(cd "$PX3" && pwd -P)"
( cd "$PX3_REAL"; _bg_close_fds; exec bash "$LEGACY_DIR/agent-watch.sh" ) & LEGACY=$!   # untagged (argv0 == "bash")
_bg_track "$LEGACY"
sleep 0.3
( cd "$PX3" && FAKE_STRAY_PIDS="$LEGACY" HERD_RELOAD_SIGTERM_POLLS=3 \
    HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" reload >/dev/null 2>&1 ) \
  || { kill "$LEGACY" 2>/dev/null; fail "reload failed (legacy untagged reap test)"; }
sleep 0.3
kill -0 "$LEGACY" 2>/dev/null && { kill "$LEGACY" 2>/dev/null; fail "legacy untagged watcher in our cwd was not reaped"; }
ok

# ═══ issue #60 fix 2: reload silent no-op → FAIL LOUD (tests 32+) ═════════════════════════════════

# ── 32. herdr present but NO workspace matches WORKSPACE_NAME → fail loud, name the open labels ───
# The rich stub reports one workspace labelled FAKE_WS_LABEL; we point WORKSPACE_NAME elsewhere so
# the label lookup misses. Reload must NOT silently slide into a headless relaunch: it names the
# expected label, lists the observed open labels, and the summary says the control room was NOT
# rebuilt. HERD_RELOAD_SKIP_LAUNCH=fallback keeps it hermetic (no real background watcher).
P="$T/p32"; mkdir "$P"; _make_project "$P" "reloadtest"
S="$T/state32"; mkdir -p "$S/tabs" "$S/panes" "$S/neighbors"
out="$( cd "$P" && env PATH="$RICH:$PATH" HERDR_STATE="$S" FAKE_WS_LABEL="someotherlabel" \
    HERD_RELOAD_SKIP_LAUNCH=fallback bash "$HERD" reload 2>&1 )" || fail "reload failed (empty-ws fail-loud)"
grep -q "no herdr workspace labelled 'reloadtest'" <<< "$out" || fail "empty-ws: expected label not named"
grep -q "someotherlabel" <<< "$out" || fail "empty-ws: observed open labels not listed"
grep -qi "control room" <<< "$out" || fail "empty-ws: summary missing control-room verdict"
grep -qi "NOT rebuilt" <<< "$out" || fail "empty-ws: summary did not flag control room NOT rebuilt"
ok

# ── 33. herdr CLI/parse error (list exits non-zero) is distinguished from a genuine no-match ──────
# The basic herdr stub exits 1 for every call. Reload must report the LIST FAILURE explicitly, not
# collapse it into "no such workspace".
P="$T/p33"; mkdir "$P"; _make_project "$P" "reloadtest"
out="$( cd "$P" && HERD_RELOAD_SKIP_LAUNCH=fallback bash "$HERD" reload 2>&1 )" || fail "reload failed (parse-error path)"
grep -qi "workspace list' failed" <<< "$out" || fail "herdr list failure not surfaced distinctly"
grep -qi "NOT rebuilt" <<< "$out" || fail "parse-error: control room not flagged NOT rebuilt"
ok

# ── 34. herdr NOT installed → its OWN distinct message (not the no-match one) ─────────────────────
# Curate a PATH that has every tool EXCEPT herdr (robust on a box that really has herdr installed),
# with the pgrep stub overriding the real one so the process table is never consulted.
NOHERDR="$T/noherdr"; mkdir -p "$NOHERDR"
for d in /usr/bin /bin /usr/sbin /sbin /opt/homebrew/bin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"; [ "$b" = "herdr" ] && continue
    [ -e "$NOHERDR/$b" ] || ln -s "$f" "$NOHERDR/$b" 2>/dev/null || true
  done
done
rm -f "$NOHERDR/pgrep"; cp "$BIN/pgrep" "$NOHERDR/pgrep"; chmod +x "$NOHERDR/pgrep"
P="$T/p34"; mkdir "$P"; _make_project "$P" "reloadtest"
out="$( cd "$P" && env -i LC_ALL="$UTF8_LOCALE" PATH="$NOHERDR" HOME="$HOME" HERD_RELOAD_SKIP_LAUNCH=fallback \
    bash "$HERD" reload 2>&1 )" || fail "reload failed (herdr-absent path)"
grep -qi "herdr not found" <<< "$out" || fail "herdr-absent: distinct 'herdr not found' message missing"
grep -q "no herdr workspace labelled" <<< "$out" && fail "herdr-absent wrongly reported as a no-match" || true
ok

# ═══ issue #60 fix 3: .herd-panes per-workspace + role validation (tests 35+) ═════════════════════

# ── 35. a registry row stamped with a FOREIGN workspace_id is NOT adopted ────────────────────────
# The coordinator tab resolves to w1. Registry backlog/watch rows name pL_r/pW_r but are stamped for
# workspace 'wZZZ' — reload must drop those hints (never run scripts in pL_r/pW_r) and re-establish
# the roles from the live roster (the coordinator's neighbors pL/pW).
P="$T/p35"; mkdir "$P"; _make_project "$P" "reloadtest"
S="$T/state35"; _rich_coord_state "$S"
mkdir -p "$S/panes/pW_r" "$S/panes/pL_r"; printf 'tC' > "$S/panes/pW_r/tab"; printf 'tC' > "$S/panes/pL_r/tab"
P35_REAL="$(cd "$P" && pwd -P)"
cat > "$P35_REAL/trees/.herd-panes" <<REG
coordinator-agent pA tC w1
backlog pL_r tC wZZZ
watch pW_r tC wZZZ
REG
out="$(_rich_reload "$P" "$S")" || fail "reload failed (foreign workspace_id test)"
grep -q "pane run pW_r" "$S/log" && fail "adopted a watch pane stamped for a FOREIGN workspace" || true
grep -q "pane run pL_r" "$S/log" && fail "adopted a backlog pane stamped for a FOREIGN workspace" || true
grep -q "herd-watch.sh"  "$S/panes/pW/cmd" 2>/dev/null || fail "watch role not re-established from the live roster"
grep -q "backlog-view.sh" "$S/panes/pL/cmd" 2>/dev/null || fail "backlog role not re-established from the live roster"
# The rewritten registry must be stamped with THIS workspace (w1) as the 4th column.
grep -qx "w1" <<< "$(awk '$1=="watch" {print $4}' "$P35_REAL/trees/.herd-panes")" || fail "rewritten watch row not stamped with workspace_id w1"
ok

# ── 36. a registry row whose pane serves the WRONG role is dropped + recreated ────────────────────
# The `watch` row points at pX, but pX is LIVE running the backlog viewer (wrong role for a watch
# pane — the drifted-registry misroute from the incident). Reload must NOT run the watcher into pX;
# it drops the hint and (re)creates the watcher below the coordinator instead.
P="$T/p36"; mkdir "$P"; _make_project "$P" "reloadtest"
S="$T/state36"; _rich_coord_state "$S"
mkdir -p "$S/panes/pX"; printf 'tC' > "$S/panes/pX/tab"
printf 'bash /x/backlog-view.sh' > "$S/panes/pX/cmd"   # pX is LIVE in the backlog role
P36_REAL="$(cd "$P" && pwd -P)"
cat > "$P36_REAL/trees/.herd-panes" <<REG
coordinator-agent pA tC w1
backlog pL tC w1
watch pX tC w1
REG
out="$(_rich_reload "$P" "$S")" || fail "reload failed (wrong-role test)"
grep -q "herd-watch.sh" "$S/panes/pX/cmd" 2>/dev/null && fail "watcher run into a pane serving the WRONG role (backlog)" || true
grep -q "herd-watch.sh" "$S/panes/pW/cmd" 2>/dev/null || fail "watcher not recreated below the coordinator after dropping the wrong-role hint"
ok

# ── 37. WEDGED herdr pane-verify → HARD timeout + headless fallback, never blocks (HERD-208) ──────
# The residual live 2026-07-09 WSL2 hang: `herdr pane process-info` never returns for an idle pane, so
# reload's pane-verify blocked FOREVER (had to be killed) instead of degrading. Model it with the
# rich stub's FAKE_HANG=all wedge (every process-info exec-sleeps). The verify must abort on its hard
# wall-clock deadline and fall back to the headless watcher — and the OUTER `timeout 45` is the real
# assertion: reload RETURNS (exit != 124) rather than hanging. Poll/deadline knobs are shrunk so the
# bounded degrade is fast; without the fix the inner run would sit past the outer bound and trip 124.
P="$T/p37"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state37"; _rich_coord_state "$S"
set +e
out="$( cd "$P" && timeout 45 env PATH="$RICH:$PATH" HERDR_STATE="$S" FAKE_WS_LABEL="reloadtest" \
    FAKE_HANG=all HERD_RELOAD_SKIP_LAUNCH=fallback \
    HERD_RELOAD_PANE_POLLS=2 HERD_RELOAD_VERIFY_POLLS=2 HERD_RELOAD_LOCKPID_POLLS=1 \
    HERD_RELOAD_HERDR_TIMEOUT=1 HERD_RELOAD_VERIFY_DEADLINE=2 \
    bash "$HERD" reload 2>&1 )"
rc=$?
set -e
[ "$rc" -ne 124 ] || fail "reload BLOCKED on a wedged herdr pane-verify (outer timeout fired) — HERD-208 regression"
grep -qi "hard timeout" <<< "$out" || fail "wedged verify did not emit the hard-timeout degraded note"
grep -qi "headless" <<< "$out" || fail "wedged verify did not name the headless-watcher fallback"
grep -q  "NOT relaunched" <<< "$out" || fail "wedged verify did not reach the (suppressed) watcher fallback"
ok

# ═══ --with-coordinator (HERD-427): opt-in coordinator start on `herd reload` ═══════════════════════
# Default is OFF (ship-dormant). herd reload never HIJACKS a live coordinator agent; the flag only
# opts into STARTING one when none is live, reusing the exact launch path `herd pane coordinator`
# already uses (_pane_agent_start → herd_driver_launch_agent — see the "agent start" stub op above,
# mirrored from test-cli-pane.sh).

# ── 38. flag OFF (default): coordinator pane stays bare, restart hint is BYTE-IDENTICAL to before ──
P="$T/p38"; mkdir "$P"
_make_project "$P" "reloadtest"
P38_REAL="$(cd "$P" && pwd -P)"
S="$T/state38"; _rich_coord_state "$S"
printf '{"result":{"agents":[]}}\n' > "$S/agents.json"   # no live coordinator agent
cat > "$P38_REAL/trees/.herd-panes" <<REG
coordinator-agent pA tC
backlog pL tC
watch pW tC
REG
out="$(_rich_reload "$P" "$S")" || fail "reload failed (--with-coordinator OFF, no agent)"
grep -qF "no coordinator agent is live in pane pA — start it yourself:  claude /coordinator" <<< "$out" \
  || fail "default reload's restart hint changed — must stay byte-identical with the flag off"
grep -q "agent start" "$S/log" && fail "flag OFF but reload started a coordinator agent" || true
grep -q "pane close pA" "$S/log" && fail "flag OFF but reload closed the (bare) coordinator anchor pane" || true
grep -q "^coordinator-agent pA tC" "$P38_REAL/trees/.herd-panes" || fail "registry coordinator-agent row changed with the flag off"
ok

# ── 39. --with-coordinator, no live agent: starts one via the SAME path 'herd pane coordinator' uses ─
P="$T/p39"; mkdir "$P"
_make_project "$P" "reloadtest"
P39_REAL="$(cd "$P" && pwd -P)"
S="$T/state39"; _rich_coord_state "$S"
printf '{"result":{"agents":[]}}\n' > "$S/agents.json"   # no live coordinator agent
cat > "$P39_REAL/trees/.herd-panes" <<REG
coordinator-agent pA tC
backlog pL tC
watch pW tC
REG
out="$( cd "$P" && env PATH="$RICH:$PATH" HERDR_STATE="$S" FAKE_WS_LABEL="reloadtest" \
    HERD_RELOAD_SKIP_LAUNCH=fallback HERD_RELOAD_PANE_POLLS=2 HERD_RELOAD_VERIFY_POLLS=2 \
    HERD_RELOAD_LOCKPID_POLLS=1 \
    bash "$HERD" reload --with-coordinator 2>&1 )" || fail "reload failed (--with-coordinator, no agent)"
grep -q "pane close pA" "$S/log" || fail "did not close the bare coordinator anchor before relaunching"
grep -q "agent start coordinator-reloadtest" "$S/log" || fail "did not start a fresh coordinator agent"
grep -q "started ✓" <<< "$out" || fail "summary missing the coordinator 'started ✓' line"
grep -q "start it yourself" <<< "$out" && fail "printed the manual-start hint despite --with-coordinator succeeding" || true
new_c="$(awk '$1=="coordinator-agent" {print $2}' "$P39_REAL/trees/.herd-panes")"
[ -n "$new_c" ] && [ "$new_c" != "pA" ] || fail "registry coordinator-agent not updated to the freshly-started pane (got '$new_c')"
grep -q "^backlog pL" "$P39_REAL/trees/.herd-panes" || fail "registry backlog row not preserved"
grep -q "^watch "     "$P39_REAL/trees/.herd-panes" || fail "registry watch row not preserved"
ok

# ── 40. --with-coordinator, agent ALREADY live: refuses, never kills it ─────────────────────────────
P="$T/p40"; mkdir "$P"
_make_project "$P" "reloadtest"
P40_REAL="$(cd "$P" && pwd -P)"
S="$T/state40"; _rich_coord_state "$S"   # fixture's agents.json already has a live agent at pA
cat > "$P40_REAL/trees/.herd-panes" <<REG
coordinator-agent pA tC
backlog pL tC
watch pW tC
REG
out="$( cd "$P" && env PATH="$RICH:$PATH" HERDR_STATE="$S" FAKE_WS_LABEL="reloadtest" \
    HERD_RELOAD_SKIP_LAUNCH=fallback HERD_RELOAD_PANE_POLLS=2 HERD_RELOAD_VERIFY_POLLS=2 \
    HERD_RELOAD_LOCKPID_POLLS=1 \
    bash "$HERD" reload --with-coordinator 2>&1 )" || fail "reload failed (--with-coordinator, agent live)"
grep -q "pane close pA" "$S/log" && fail "--with-coordinator killed the LIVE coordinator pane" || true
grep -q "agent start" "$S/log" && fail "--with-coordinator started a second agent over a live one" || true
grep -qi "refusing to restart it" <<< "$out" || fail "missing the live-agent refusal message"
grep -q "herd pane coordinator" <<< "$out" || fail "refusal message did not point at 'herd pane coordinator'"
grep -q "^coordinator-agent pA tC" "$P40_REAL/trees/.herd-panes" || fail "registry coordinator-agent row changed despite the refusal"
ok

# ═══ HERD-458 / GH #572: the pane-visibility probe must be honest in BOTH directions (tests 41+) ═══
# THE DEFECT. `herd reload` verified its watcher launch by demanding a `bash …/agent-watch.sh` (or
# herd-watch.sh) cmdline in the pane's foreground. That shape survives only for the instant BEFORE
# agent-watch.sh re-execs under its per-workspace argv0 marker (`exec -a "$HERD_WATCH_ARGV0" bash
# …/agent-watch.sh`, issue #60) — after which the foreground cmdline is `herd-watch-<slug>
# …/agent-watch.sh` with no `bash` token at all. So "visible ✓" was decided by a race between the
# ~0.2s poll and the re-exec, and a second operator's WSL2 seat lost that race on EVERY (re)start:
# four invocations, four fresh pids, every one reporting "RUNNING but NOT visible … kill <pid> and
# inspect the pane" while `herdr pane read` showed the watcher rendering with a live clock.
# An always-red probe is exactly as blind as an always-green one — and this one told the operator to
# kill a healthy watcher, which produces another pid and another warning: a loop that never converges.
# The fix ALSO accepts the identity the process actually keeps (argv0, matched as the FIRST TOKEN,
# exactly), which is the same attribution the stop leg reaps by.

# ── 41. watcher re-exec'd under its argv0 → VISIBLE, not DETACHED (the GH #572 regression) ────────
P="$T/p41"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state41"; _rich_coord_state "$S"
# The pane run lands, then the watcher re-execs: the foreground carries the argv0 and nothing else.
printf 'herd-watch-reloadtest /engine/scripts/herd/agent-watch.sh' > "$S/panes/pW/fgcmd"
out="$(_rich_reload "$P" "$S")" || fail "reload failed (argv0-visible watcher)"
grep -q "visible ✓" <<< "$out" \
  || fail "a watcher rendering under its argv0 was not recognised as visible (HERD-458)"
grep -q "DETACHED" <<< "$out" \
  && fail "a healthy argv0-tagged watcher was reported DETACHED (the GH #572 false negative)" || true
grep -q "RUNNING but NOT visible" <<< "$out" \
  && fail "reload told the operator to kill a healthy, visible watcher" || true
ok

# ── 42. the argv0 match is EXACT — a FOREIGN workspace's tag is not our watcher (issue #60) ───────
# The probe accepts an argv0 only as the command's first token and only when it equals THIS
# workspace's marker, so workspace "reloadtest" can never read "reloadtest-other"'s watcher as its
# own launch (the same rule that keeps the reaper from cross-project kills).
P="$T/p42"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state42"; _rich_coord_state "$S"
printf 'herd-watch-reloadtest-other /engine/scripts/herd/agent-watch.sh' > "$S/panes/pW/fgcmd"
out="$(_rich_reload "$P" "$S")" || fail "reload failed (foreign argv0)"
grep -q "visible ✓" <<< "$out" \
  && fail "a FOREIGN workspace's argv0 was accepted as this workspace's watcher" || true
ok

# ── 43. the OTHER direction: a merely-echoed argv0 token is NOT a running watcher ─────────────────
# The fix must not buy visibility by going always-green. argv0 counts only as the command's FIRST
# token: a stale shell whose foreground merely CONTAINS the marker (the 2026-07-06 incident shape — a
# dead viewer's typed-ahead keystrokes concatenated onto our run) is still a MISS, so with a live
# watcher on the lockfile this must report the genuine detached case, loudly.
P="$T/p43"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state43"; _rich_coord_state "$S"
printf 'bash -c echo herd-watch-reloadtest' > "$S/panes/pW/fgcmd"
( _bg_close_fds; exec sleep 999 ) & ZPID43=$!
_bg_track "$ZPID43"
lockfile="$P/trees/.watcher-reloadtest.pid"
out="$(_rich_reload "$P" "$S" FAKE_RUN_WRITES_LOCK="$lockfile:$ZPID43")" \
  || { kill "$ZPID43" 2>/dev/null || true; fail "reload failed (genuinely-detached test)"; }
grep -q "RUNNING but NOT visible" <<< "$out" \
  || { kill "$ZPID43" 2>/dev/null || true; fail "a genuinely detached watcher no longer warns — the probe went always-green"; }
grep -q "DETACHED" <<< "$out" \
  || { kill "$ZPID43" 2>/dev/null || true; fail "summary missing DETACHED for a genuinely detached watcher"; }
kill "$ZPID43" 2>/dev/null || true
ok

# ── 44. HERD-668 review finding (PR #791): AGENTS_PANE off (default) is a HARD no-op on reload ────
# _reload_agents_pane_resolve's off-path sentinel used to be SPACE-joined ("<pane_id> <created>");
# `read`'s default IFS collapses/strips a LEADING separator, so an empty pane_id + "0" silently
# became aPane="0" (the flag, misread as a pane id) instead of aPane="". That fabricated a PHANTOM
# `agents 0 <tab> <ws>` registry row and a spurious `pane run 0 …` on EVERY default reload — exactly
# the "off is byte-identical" guarantee this lever promises. Comma-delimited now; this proves it.
P="$T/p44"; mkdir "$P"
_make_project "$P" "reloadtest"
S="$T/state44"; _rich_coord_state "$S"
out="$(_rich_reload "$P" "$S")" || fail "reload failed (AGENTS_PANE off/default)"
P44_REAL="$(cd "$P" && pwd -P)"
grep -q "^agents " "$P44_REAL/trees/.herd-panes" \
  && fail "registry carries an 'agents' row despite AGENTS_PANE never being set (got: $(grep '^agents ' "$P44_REAL/trees/.herd-panes"))" \
  || true
grep -qE "pane run 0[[:space:]]" "$S/log" \
  && fail "reload ran a command in phantom pane '0' — the space-sentinel collapse bug" || true
grep -q "agents-pane-view.sh" "$S/log" \
  && fail "agents-pane-view.sh was launched despite AGENTS_PANE off" || true
grep -q "pane rename .* agents·reloadtest" "$S/log" \
  && fail "an agents pane was labelled despite AGENTS_PANE off" || true
grep -qi "did not appear in pane" <<< "$out" \
  && fail "spurious agents-pane-view visibility warning printed despite AGENTS_PANE off: $out" || true
ok

# ── 45. AGENTS_PANE=on: reload splits + labels a REAL pane off the watch pane, registry row correct ─
P="$T/p45"; mkdir "$P"
_make_project "$P" "reloadtest" 'AGENTS_PANE="on"'
S="$T/state45"; _rich_coord_state "$S"
out="$(_rich_reload "$P" "$S")" || fail "reload failed (AGENTS_PANE on)"
P45_REAL="$(cd "$P" && pwd -P)"
new_ag="$(awk '$1=="agents" {print $2}' "$P45_REAL/trees/.herd-panes")"
[ -n "$new_ag" ] || fail "AGENTS_PANE=on: no 'agents' registry row written"
[ "$new_ag" != "0" ] || fail "AGENTS_PANE=on: registry 'agents' row is the phantom pane id '0'"
grep -rl "agents-pane-view.sh" "$S/panes" >/dev/null || fail "AGENTS_PANE=on: no pane received agents-pane-view.sh"
grep -q "pane rename $new_ag agents·reloadtest" "$S/log" || fail "AGENTS_PANE=on: agents pane not labelled 'agents·reloadtest'"
grep -q "pane split pW --direction right --ratio 0.72" "$S/log" \
  || fail "AGENTS_PANE=on: agents pane not split off the watch pane at ratio 0.72"
ok

echo "ALL PASS ($pass checks)"
