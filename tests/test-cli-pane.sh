#!/usr/bin/env bash
# test-cli-pane.sh — hermetic tests for `herd pane <watch|backlog|coordinator>`.
#
# The single-pane restart shortcuts re-run ONE control-room pane in place without a full reload.
# These tests reuse the rich file-backed herdr stub from test-cli-reload.sh (a simulation of the
# workspace/tab/pane/agent JSON API) and add an `agent start` op for the coordinator relaunch.
#
# HERMETICITY (same contract as test-cli-reload.sh; the tab-leak-guard enforces it):
#   • herdr is STUBBED on PATH — no real workspace/tab/pane is ever created; `pane run` only
#     RECORDS the command, it never spawns a process.
#   • pgrep is STUBBED — returns only $FAKE_STRAY_PIDS, so the real process table (other
#     workspaces' watchers) is never consulted.
#   • Kill/abort tests use innocuous `sleep` processes as fake watchers, never the real
#     agent-watch.sh; HERD_RELOAD_SIGTERM_POLLS=3 shortens the SIGTERM window.
#   • The verify polls are shortened so a stub that never "shows" a command fails fast.
#
# Run:  bash tests/test-cli-pane.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0
ok(){ pass=$((pass+1)); }

BIN="$T/bin"; mkdir -p "$BIN"
# pgrep stub — echoes each colon-separated PID in $FAKE_STRAY_PIDS; ignores all other args so the
# real process table is never consulted (cmd never sees production agent-watch PIDs).
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
IFS=':' read -ra pids <<< "${FAKE_STRAY_PIDS:-}"
for p in "${pids[@]}"; do [ -n "$p" ] && printf '%s\n' "$p"; done
exit 0
STUB
chmod +x "$BIN/pgrep"
export PATH="$BIN:$PATH"

# _make_project ROOT WORKSPACE [extra config lines...] — realpath PROJECT_ROOT so lsof cwd
# comparisons match on macOS where /var/folders is a symlink to /private/var/folders.
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
COORDINATOR_CMD="/coordinator"
CFG
  for line in "$@"; do printf '%s\n' "$line" >> "$r/.herd/config"; done
}

# ── Rich herdr stub (mirrors test-cli-reload.sh + an `agent start` op) ────────────────────────────
# State under $HERDR_STATE:
#   tabs/<tab_id>        file content = tab label
#   panes/<pane_id>/tab  pane's current tab id
#   panes/<pane_id>/cmd  last `pane run` command (recorded, NEVER executed)
#   panes/<pane_id>/noshow  marker: process-info never shows cmd (invisible-pane bug sim)
#   neighbors/<pane>.<dir>  neighbor pane id for `pane neighbor`
#   agents.json          canned `agent list` response
#   log                  every invocation, one line, for assertions
# Env: FAKE_WS_LABEL (workspace label); FAKE_RUN_WRITES_LOCK=path:pid (a `pane run` writes pid to
# path — simulates a detached watcher grabbing the lockfile).
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
    for pd in "$S"/panes/*; do
      [ -d "$pd" ] || continue
      [ -f "$pd/tab" ] && [ "$(cat "$pd/tab")" = "$tid" ] && rm -rf "$pd"
    done
    printf '{"result":{}}\n' ;;
  "agent list")
    if [ -f "$S/agents.json" ]; then cat "$S/agents.json"; else printf '{"result":{"agents":[]}}\n'; fi ;;
  "agent start")
    # agent start <name> --workspace W --cwd R --tab T --split D -- claude /coordinator
    name="${3:-}"; tab=""; shift 3 2>/dev/null || shift $#
    while [ $# -gt 0 ]; do case "$1" in --tab) tab="${2:-}"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
    pid="p$(next_id)"; mkdir -p "$S/panes/$pid"; printf '%s' "$tab" > "$S/panes/$pid/tab"
    printf 'claude' > "$S/panes/$pid/cmd"
    # Reflect the new agent into agent list so a follow-up anchor resolve finds it.
    printf '{"result":{"agents":[{"name":"%s","pane_id":"%s","tab_id":"%s","workspace_id":"w1"}]}}\n' \
      "$name" "$pid" "$tab" > "$S/agents.json"
    printf '{"result":{"agent":{"pane_id":"%s"}}}\n' "$pid" ;;
  "pane list")
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
    if [ ! -d "$S/panes/$p" ]; then printf '{"result":{}}\n'; exit 0; fi
    cmd=""
    [ -f "$S/panes/$p/cmd" ] && [ ! -f "$S/panes/$p/noshow" ] && cmd="$(cat "$S/panes/$p/cmd")"
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

# _pane_run PROJECT STATE SUB [env VAR=VAL ...] [-- extra args] — run `herd pane SUB` against the
# rich stub. Non-interactive (HERD_NONINTERACTIVE=1) and hermetic (no real process ever spawns).
_pane_run() {
  local proj="$1" state="$2" sub="$3"; shift 3
  local envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; args=("$@"); break ;;
      *) envs+=("$1"); shift ;;
    esac
  done
  ( cd "$proj" && env PATH="$RICH:$PATH" HERDR_STATE="$state" FAKE_WS_LABEL="panetest" \
      HERD_NONINTERACTIVE=1 HERD_RELOAD_PANE_POLLS=2 HERD_RELOAD_VERIFY_POLLS=2 \
      HERD_RELOAD_LOCKPID_POLLS=1 \
      ${envs[@]+"${envs[@]}"} bash "$HERD" pane "$sub" ${args[@]+"${args[@]}"} 2>&1 )
}

# _coord_state STATE — coordinator control-room fixture: tab tC labeled as the coordinator, agent
# pane pA (live coordinator), bare backlog pane pL left of it, bare watch pane pW below. The
# registry points at all three. Mirrors _rich_coord_state from test-cli-reload.sh.
_coord_state() {
  local S="$1" R="$2"
  mkdir -p "$S/tabs" "$S/panes/pA" "$S/panes/pL" "$S/panes/pW" "$S/neighbors"
  printf 'coordinator-panetest' > "$S/tabs/tC"
  printf 'tC' > "$S/panes/pA/tab"
  printf 'tC' > "$S/panes/pL/tab"
  printf 'tC' > "$S/panes/pW/tab"
  printf 'pL' > "$S/neighbors/pA.left"
  printf 'pW' > "$S/neighbors/pA.down"
  printf '%s\n' '{"result":{"agents":[{"name":"coordinator-panetest","pane_id":"pA","tab_id":"tC","workspace_id":"w1"}]}}' \
    > "$S/agents.json"
  cat > "$R/trees/.herd-panes" <<REG
coordinator-agent pA tC
backlog pL tC
watch pW tC
REG
}

# ═══ herd pane watch ═════════════════════════════════════════════════════════════════════════════

# ── 1. watch restart reuses the registered watch pane; no new pane/tab created ────────────────────
P="$T/p1"; mkdir "$P"; _make_project "$P" "panetest"; R1="$(cd "$P" && pwd -P)"
S="$T/s1"; _coord_state "$S" "$R1"
out="$(_pane_run "$P" "$S" watch)" || fail "pane watch failed (reuse registered pane)"
grep -q "pane run pW" "$S/log" || fail "watcher not rerun in the registered watch pane pW"
grep -q "herd-watch.sh" "$S/panes/pW/cmd" 2>/dev/null || fail "watch pane did not receive herd-watch.sh"
grep -q "pane split" "$S/log" && fail "split a new pane when the registered watch pane was reusable" || true
grep -q "tab create" "$S/log" && fail "created a tab when the registered watch pane was reusable" || true
grep -q "pane run pA" "$S/log" && fail "wrote into the coordinator (anchor) pane" || true
printf '%s' "$out" | grep -q "visible ✓" || fail "watch summary missing 'visible ✓'"
# Registry rewritten with all three roles.
grep -q "^watch pW tC" "$R1/trees/.herd-panes" || fail "registry watch row not rewritten to pW"
grep -q "^coordinator-agent pA" "$R1/trees/.herd-panes" || fail "registry coordinator-agent row missing"
grep -q "^backlog pL" "$R1/trees/.herd-panes" || fail "registry backlog row not preserved"
ok

# ── 2. watch pane GONE → recreated below the coordinator (canonical spot) ─────────────────────────
P="$T/p2"; mkdir "$P"; _make_project "$P" "panetest"; R2="$(cd "$P" && pwd -P)"
S="$T/s2"; _coord_state "$S" "$R2"
rm -rf "$S/panes/pW"           # user closed the watch pane → GONE
rm -f "$S/neighbors/pA.down"   # no downward neighbor either
cat > "$R2/trees/.herd-panes" <<REG
coordinator-agent pA tC
backlog pL tC
watch pW_gone tC
REG
out="$(_pane_run "$P" "$S" watch)" || fail "pane watch failed (recreate when gone)"
grep -q "pane split pA --direction down" "$S/log" || fail "gone watch pane not recreated by splitting below the coordinator"
grep -rl "herd-watch.sh" "$S/panes" >/dev/null || fail "recreated pane did not receive herd-watch.sh"
printf '%s' "$out" | grep -q "recreated ✓" || fail "recreated watch pane not reported"
# Registry watch row points at the newly created pane (not the dead pW_gone).
new_w="$(awk '$1=="watch" {print $2}' "$R2/trees/.herd-panes")"
[ -n "$new_w" ] && [ "$new_w" != "pW_gone" ] || fail "registry watch row not updated to the recreated pane (got '$new_w')"
grep -q "herd-watch.sh" "$S/panes/$new_w/cmd" 2>/dev/null || fail "registry watch pane did not receive the script"
ok

# ── 3. watch restart escalates SIGTERM → SIGKILL for a stubborn watcher, then relaunches once ─────
# A watcher blocked in a long child ignores SIGTERM; the stop sequence must escalate to SIGKILL and
# then relaunch a single fresh watcher (never a duplicate). HERD_RELOAD_SIGTERM_POLLS=3 (0.6s)
# triggers the SIGKILL branch fast.
P="$T/p3"; mkdir "$P"; _make_project "$P" "panetest"; R3="$(cd "$P" && pwd -P)"
S="$T/s3"; _coord_state "$S" "$R3"
lockfile="$R3/trees/.watcher-panetest.pid"
( trap '' TERM; sleep 9999 ) & STUBBORN=$!
printf '%s\n' "$STUBBORN" > "$lockfile"
set +e
out="$(_pane_run "$P" "$S" watch HERD_RELOAD_SIGTERM_POLLS=3)"
rc=$?
set -e
kill -9 "$STUBBORN" 2>/dev/null || true
printf '%s' "$out" | grep -q "sending SIGKILL" || fail "SIGTERM-ignoring watcher did not trigger SIGKILL escalation"
[ "$rc" -eq 0 ] || fail "pane watch should succeed once the stubborn watcher is SIGKILLed (rc=$rc)"
runs="$(grep -c "pane run pW" "$S/log" || true)"
[ "$runs" -eq 1 ] || fail "expected exactly one watcher relaunch after SIGKILL, got $runs"
ok

# ── 3b. true abort: the command dies loudly when the lock PID cannot be stopped at all ─────────────
# A process that survives SIGKILL is not portably reproducible, and `kill` is a bash builtin (a PATH
# stub cannot override it). The portable stand-in is a ZOMBIE we own: `kill -0 <zombie>` succeeds
# (it is still in the process table, unreaped), while SIGTERM/SIGKILL are no-ops (it is already
# dead). That is exactly "alive but cannot be stopped", forcing _stop_project_watcher's abort
# branch. A guard process holds the zombie unreaped for the poll window; we reap it at the end.
cat > "$BIN/mkzombie.sh" <<'MZ'
#!/usr/bin/env bash
# Spawn a child, kill it, publish its pid, then exec sleep so this process never reaps the child —
# the child stays a zombie (owned by us) until THIS process is killed.
sleep 999 & z=$!
kill -9 "$z" 2>/dev/null
printf '%s\n' "$z" > "$1"
exec sleep 999
MZ
chmod +x "$BIN/mkzombie.sh"
P="$T/p3b"; mkdir "$P"; _make_project "$P" "panetest"; R3B="$(cd "$P" && pwd -P)"
S="$T/s3b"; _coord_state "$S" "$R3B"
ZFILE="$T/zpid"; rm -f "$ZFILE"
bash "$BIN/mkzombie.sh" "$ZFILE" & GUARD=$!
zi=0; while [ ! -s "$ZFILE" ] && [ "$zi" -lt 25 ]; do sleep 0.1; zi=$((zi+1)); done
ZPID="$(cat "$ZFILE" 2>/dev/null || true)"
if [ -n "$ZPID" ] && kill -0 "$ZPID" 2>/dev/null; then
  printf '%s\n' "$ZPID" > "$R3B/trees/.watcher-panetest.pid"
  set +e
  out="$(_pane_run "$P" "$S" watch HERD_RELOAD_SIGTERM_POLLS=1)"
  rc=$?
  set -e
  kill -9 "$GUARD" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "pane watch should abort (non-zero) when the watcher cannot be stopped"
  printf '%s' "$out" | grep -q "could not be stopped" || fail "abort did not print the unstoppable-watcher error"
  printf '%s' "$out" | grep -q "duplicate watchers" || fail "abort message should warn about duplicate watchers"
  grep -q "pane run pW" "$S/log" && fail "a new watcher was launched despite the abort" || true
  ok
else
  # Could not stage a zombie on this platform — skip rather than false-fail the suite.
  kill -9 "$GUARD" 2>/dev/null || true
  ok
fi

# ═══ herd pane backlog ═══════════════════════════════════════════════════════════════════════════

# ── 4. backlog rerun IN PLACE: live viewer interrupted, script rerun in the SAME pane ─────────────
P="$T/p4"; mkdir "$P"; _make_project "$P" "panetest"; R4="$(cd "$P" && pwd -P)"
S="$T/s4"; _coord_state "$S" "$R4"
printf 'bash /x/backlog-view.sh' > "$S/panes/pL/cmd"   # backlog viewer currently live in pL
out="$(_pane_run "$P" "$S" backlog)" || fail "pane backlog failed (in-place rerun)"
grep -q "pane run pL" "$S/log" || fail "backlog not rerun in the registered backlog pane pL"
grep -q "backlog-view.sh" "$S/panes/pL/cmd" 2>/dev/null || fail "backlog pane did not receive backlog-view.sh"
grep -q "pane split" "$S/log" && fail "split a new pane when the backlog pane was reusable (should rerun in place)" || true
grep -q "pane swap"  "$S/log" && fail "swapped panes when rerunning in place" || true
grep -q "tab create" "$S/log" && fail "created a tab when rerunning the backlog in place" || true
printf '%s' "$out" | grep -q "visible ✓" || fail "backlog summary missing 'visible ✓'"
grep -q "^backlog pL tC" "$R4/trees/.herd-panes" || fail "registry backlog row not rewritten to pL"
grep -q "^watch pW"      "$R4/trees/.herd-panes" || fail "registry watch row not preserved on backlog restart"
ok

# ── 5. backlog pane GONE → recreated beside the coordinator + swapped into the LEFT slot ──────────
P="$T/p5"; mkdir "$P"; _make_project "$P" "panetest"; R5="$(cd "$P" && pwd -P)"
S="$T/s5"; _coord_state "$S" "$R5"
rm -rf "$S/panes/pL"           # user closed the backlog pane → GONE
rm -f "$S/neighbors/pA.left"   # no left neighbor either
cat > "$R5/trees/.herd-panes" <<REG
coordinator-agent pA tC
backlog pL_gone tC
watch pW tC
REG
out="$(_pane_run "$P" "$S" backlog)" || fail "pane backlog failed (recreate when gone)"
grep -q "pane split pA --direction right" "$S/log" || fail "gone backlog pane not recreated by splitting the coordinator"
grep -q "pane swap --source-pane" "$S/log" || fail "recreated backlog pane not swapped into the left slot"
printf '%s' "$out" | grep -q "recreated ✓" || fail "recreated backlog pane not reported"
ok

# ═══ herd pane coordinator ═══════════════════════════════════════════════════════════════════════

# ── 6. coordinator REFUSES without confirmation (non-interactive, no --yes) ───────────────────────
P="$T/p6"; mkdir "$P"; _make_project "$P" "panetest"; R6="$(cd "$P" && pwd -P)"
S="$T/s6"; _coord_state "$S" "$R6"
set +e
out="$(_pane_run "$P" "$S" coordinator)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "coordinator relaunch should refuse (non-zero) without confirmation"
printf '%s' "$out" | grep -qi "refusing to relaunch the coordinator without confirmation" \
  || fail "refusal message missing"
grep -q "agent start" "$S/log" && fail "coordinator relaunched despite no confirmation" || true
grep -q "pane close pA" "$S/log" && fail "killed the live coordinator pane despite no confirmation" || true
# Registry untouched (still points at the original pA).
grep -q "^coordinator-agent pA tC" "$R6/trees/.herd-panes" || fail "registry coordinator row changed on refusal"
ok

# ── 7. coordinator PROCEEDS with --yes: kills old pane, starts a fresh agent, rewrites registry ───
P="$T/p7"; mkdir "$P"; _make_project "$P" "panetest"; R7="$(cd "$P" && pwd -P)"
S="$T/s7"; _coord_state "$S" "$R7"
out="$(_pane_run "$P" "$S" coordinator -- --yes)" || fail "coordinator relaunch failed with --yes"
grep -q "pane close pA" "$S/log" || fail "did not kill the old coordinator pane"
grep -q "agent start coordinator-panetest" "$S/log" || fail "did not start a fresh coordinator agent"
printf '%s' "$out" | grep -q "relaunched ✓" || fail "coordinator summary missing 'relaunched ✓'"
# Registry rewritten with the NEW coordinator pane id (not the killed pA), backlog/watch preserved.
new_c="$(awk '$1=="coordinator-agent" {print $2}' "$R7/trees/.herd-panes")"
[ -n "$new_c" ] && [ "$new_c" != "pA" ] || fail "registry coordinator-agent not updated to the new pane (got '$new_c')"
grep -q "^backlog pL" "$R7/trees/.herd-panes" || fail "registry backlog row not preserved on coordinator relaunch"
grep -q "^watch pW"   "$R7/trees/.herd-panes" || fail "registry watch row not preserved on coordinator relaunch"
ok

# ── 7b. coordinator PROCEEDS with -y (short flag) ─────────────────────────────────────────────────
P="$T/p7b"; mkdir "$P"; _make_project "$P" "panetest"; R7B="$(cd "$P" && pwd -P)"
S="$T/s7b"; _coord_state "$S" "$R7B"
out="$(_pane_run "$P" "$S" coordinator -- -y)" || fail "coordinator relaunch failed with -y"
grep -q "agent start coordinator-panetest" "$S/log" || fail "-y did not start a fresh coordinator agent"
ok

# ═══ refusal / guard tests ═══════════════════════════════════════════════════════════════════════

# ── 8. refuses when no .herd/config resolves (no dogfood fallback) ────────────────────────────────
P="$T/p8"; mkdir "$P"
git -C "$P" init -q; git -C "$P" config user.email t@t.t; git -C "$P" config user.name t
( cd "$P" && git commit -q --allow-empty -m init )
S="$T/s8"; mkdir -p "$S/tabs"
set +e
out="$( cd "$P" && env PATH="$RICH:$BIN:$PATH" HERDR_STATE="$S" FAKE_WS_LABEL="panetest" \
    HERD_NONINTERACTIVE=1 bash "$HERD" pane watch 2>&1 )"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "pane watch should fail without a .herd/config"
printf '%s' "$out" | grep -qi "no .herd/config" || fail "missing-config error not clear"
printf '%s' "$out" | grep -qi "dogfood" || fail "should mention refusing the dogfood fallback"
ok

# ── 9. refuses when the coordinator tab is absent (control room not up) ────────────────────────────
P="$T/p9"; mkdir "$P"; _make_project "$P" "panetest"
S="$T/s9"; mkdir -p "$S/tabs" "$S/panes"   # workspace resolves, but NO coordinator tab
printf '{"result":{"agents":[]}}\n' > "$S/agents.json"
set +e
out="$(_pane_run "$P" "$S" watch)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "pane watch should fail when the coordinator tab is absent"
printf '%s' "$out" | grep -qi "no coordinator tab" || fail "missing-coordinator-tab error not clear"
ok

# ── 10. unknown pane target fails clearly ─────────────────────────────────────────────────────────
P="$T/p10"; mkdir "$P"; _make_project "$P" "panetest"
S="$T/s10"; _coord_state "$S" "$(cd "$P" && pwd -P)"
set +e
out="$(_pane_run "$P" "$S" bogus)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "unknown pane target should fail"
printf '%s' "$out" | grep -qi "unknown 'herd pane' target" || fail "unknown-target error not clear"
ok

echo "ALL PASS ($pass checks)"
