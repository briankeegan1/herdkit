#!/usr/bin/env bash
# test-sweep.sh — hermetic proof of `herd sweep`, the one-command control-room cleanup (HERD-191).
#
# Drives the SHIPPED functions in scripts/herd/sweep.sh (loaded through agent-watch.sh's
# AGENT_WATCH_LIB=1 seam, exactly as the CLI loads them) against a planted FIXTURE MESS:
#   • a merged-PR worktree (clean)                     → reaped
#   • a merged-PR worktree with only regenerable dirt  → reaped (droppings tolerated)
#   • a merged-PR worktree with REAL dirt              → FLAGGED, never deleted   [judgment]
#   • a closed-PR worktree carrying unique commits     → FLAGGED, never deleted   [judgment]
#   • an open-PR worktree                              → untouched
#   • a stale tab registry entry                       → closed + registry row pruned
#   • a stale resolve·<slug> tab on a LIVE slug whose conflict is gone → closed, counted, in the plan
#   • a dead-pid inflight marker                       → dropped
#   • a detached scratch tree, clean, no unique commits → reaped
#   • a detached scratch tree with a unique commit      → FLAGGED, never deleted  [judgment]
#   • an orphaned (ppid=1) healthcheck process stub    → killed
#
# Asserts:
#   (1) LOADING — every sweep_* entry point is defined after sourcing, and the journal is sandboxed.
#   (2) DETECTION — the cheap trigger pass counts the mess; sweep_advice_line renders the console row
#       (with correct singular/plural) and stays EMPTY on a clean control room.
#   (3) DRY-RUN IS INERT — --dry-run prints the full plan but every worktree, tab, marker and process
#       survives byte-for-byte, and nothing is journaled as done.
#   (4) SAFE LEGS ACT + JOURNAL — the live run reaps the clean/regenerable worktrees, closes the stale
#       tab, drops the dead marker, kills the orphan; each emits its journal event.
#   (5) JUDGMENT LEGS ARE NEVER AUTO-DELETED — the dirty worktree and the closed-PR worktree with
#       unique commits survive a LIVE run AND an `auto` run, each journaling a `sweep_flag` with
#       evidence. This is the sweep's whole safety contract.
#   (6) ATTRIBUTION — a sibling project's path (/x/proj-trees vs MAIN=/x/proj) is never attributed to
#       us (issue #60 cross-project kill), and a LIVE inflight marker's worker is never killed as an
#       orphan (a backgrounded HERD-185 gate worker is ppid=1 but still collectable).
#   (7) PID-RECYCLING GUARD — a kill whose recorded start-time no longer matches is refused.
#   (8) ADVICE IS JOURNALED ONCE PER CONDITION-SET — an unchanged set is silent; a changed set speaks.
#   (9) SWEEP_AUTO — off | advise | auto normalize correctly; an unknown value degrades to advise.
#  (10) NO SHA ANCHOR ⇒ NO REAP — a worktree whose HEAD != the merged PR's headRefOid is untouched.
#  (11) SHARED-PGID GUARD — a process group that also holds a spared process (the watcher, a live gate
#       worker, ourselves) is never GROUP-killed; the sweep degrades to a single-pid kill.
#  (14) INERT-GUARD REGRESSION — the start-time is captured at LISTING and threaded to the kill; if the
#       kill path re-samples it, the recycling guard is dead code and a recycled pid gets signalled.
#  (15) A stale pgid is re-verified before any process-GROUP kill.
#  (16) The corpse sweep holds an atomic claim, so `herd sweep` + a live watcher cannot double-charge
#       a PR's review-retry budget or the global infra breaker.
#  (17) Leg 3 narrates the past-deadline LIVE workers it will SIGTERM (plan == action).
#  (18) SWEEP_AUTO=auto stands down on a repeated no-progress condition-set.
#  (13) DETACHED SCRATCH — a detached tree whose commits are reachable from no branch ref is FLAGGED,
#       never reaped (removing the worktree destroys them irrecoverably); a clean one still reaps.
#  (12) COUNTERS RESET PER RUN — the watcher's auto path reuses one process, so SWEEP_N_* must not
#       accumulate across cadence ticks (a `sweep_auto` line would otherwise report a lifetime total).
#
# Fully hermetic: a temp git repo + real worktrees, stubbed gh/herdr, headless driver, seams for the
# process table and cwd probe. NO network, NO model, NO panes, NO real processes killed but our own.
# Run:  bash tests/test-sweep.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
SWEEPSH="$HERE/../scripts/herd/sweep.sh"

T="$(mktemp -d)"
trap 'kill "${VICTIM:-}" "${LIVEWORKER:-}" "${SESS_WRAP:-}" "${SESS_BATS:-}" 2>/dev/null || true; rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); }
[ -f "$WATCH" ]   || fail "agent-watch.sh not found at $WATCH"
[ -f "$SWEEPSH" ] || fail "sweep.sh not found at $SWEEPSH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── fixture: a real git repo + worktrees ─────────────────────────────────────
export MAINDIR="$T/proj"; export TREESDIR="$T/proj-trees"
mkdir -p "$MAINDIR" "$TREESDIR"
git init -q -b main "$MAINDIR"
git -C "$MAINDIR" config user.email t@t.local; git -C "$MAINDIR" config user.name t
echo base > "$MAINDIR/f.txt"; git -C "$MAINDIR" add -A; git -C "$MAINDIR" commit -qm base
# A local ref standing in for the remote default branch (DEFAULT_BRANCH is a FULL ref).
git -C "$MAINDIR" update-ref refs/remotes/origin/main HEAD

mk_wt(){ git -C "$MAINDIR" worktree add -q -b "feat/$1" "$TREESDIR/$1" main >/dev/null 2>&1; }
for s in merged-clean merged-regen merged-dirty closed-unique open-live stale-sha; do mk_wt "$s"; done
# regenerable droppings only
touch "$TREESDIR/merged-regen/.DS_Store"; mkdir -p "$TREESDIR/merged-regen/__pycache__"; touch "$TREESDIR/merged-regen/__pycache__/a.pyc"
# REAL dirt: a modified tracked file
echo changed > "$TREESDIR/merged-dirty/f.txt"
# a unique commit that exists nowhere on origin/main
echo uniq > "$TREESDIR/closed-unique/u.txt"
git -C "$TREESDIR/closed-unique" add -A
git -C "$TREESDIR/closed-unique" -c user.email=t@t.local -c user.name=t commit -qm "unique work"
# tmp-clean: a DETACHED scratch tree at origin/main, no unique work → safe to reap.
git -C "$MAINDIR" worktree add -q --detach "$TREESDIR/tmp-clean" main >/dev/null 2>&1
# tmp-precious: a DETACHED scratch tree carrying a commit reachable from NO branch ref. `git status`
# reads CLEAN, so only a unique-commit check can save it. Removing the worktree would destroy the
# commit AND its reflog (.git/worktrees/<name>/ goes with it). Must be FLAGGED, never reaped.
git -C "$MAINDIR" worktree add -q --detach "$TREESDIR/tmp-precious" main >/dev/null 2>&1
echo precious > "$TREESDIR/tmp-precious/only-here.txt"
git -C "$TREESDIR/tmp-precious" add -A
git -C "$TREESDIR/tmp-precious" -c user.email=t@t.local -c user.name=t commit -qm "unique A/B work"
PRECIOUS_SHA="$(git -C "$TREESDIR/tmp-precious" rev-parse HEAD)"
[ -z "$(git -C "$TREESDIR/tmp-precious" status --porcelain)" ] \
  || fail "fixture: tmp-precious must read CLEAN to git status (that is the trap)"

# tmp-inuse: a DETACHED scratch tree, clean, zero unique commits — but a live process holds it open.
# Reaping it loses no data, yet pulls the checkout out from under its user. Must be FLAGGED.
git -C "$MAINDIR" worktree add -q --detach "$TREESDIR/tmp-inuse" main >/dev/null 2>&1

# stale-sha: HEAD moves past the sha the (merged) PR recorded → no anchor → must be untouched
echo drift > "$TREESDIR/stale-sha/d.txt"
git -C "$TREESDIR/stale-sha" add -A
git -C "$TREESDIR/stale-sha" -c user.email=t@t.local -c user.name=t commit -qm drift

# ── stubs on PATH ────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
export GH_LOG="$T/gh.log" TAB_CLOSED="$T/closed.log"
: > "$TAB_CLOSED"

# gh stub: `pr view <branch> --json state,number,headRefOid -q …` → "<STATE>\t<oid>\t<num>"
#          `pr list --json headRefName …`                        → the OPEN PRs only
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
  case "\${3:-}" in
    feat/merged-clean) printf 'MERGED\t%s\t101\n' "\$(git -C "$TREESDIR/merged-clean" rev-parse HEAD)" ;;
    feat/merged-regen) printf 'MERGED\t%s\t102\n' "\$(git -C "$TREESDIR/merged-regen" rev-parse HEAD)" ;;
    feat/merged-dirty) printf 'MERGED\t%s\t103\n' "\$(git -C "$TREESDIR/merged-dirty" rev-parse HEAD)" ;;
    feat/closed-unique) printf 'CLOSED\t%s\t104\n' "\$(git -C "$TREESDIR/closed-unique" rev-parse HEAD)" ;;
    feat/open-live)    printf 'OPEN\t%s\t105\n'   "\$(git -C "$TREESDIR/open-live" rev-parse HEAD)" ;;
    # stale-sha: the PR merged at an OLDER sha than the worktree's current HEAD → anchor must fail
    feat/stale-sha)    printf 'MERGED\t%s\t106\n' "0000000000000000000000000000000000000000" ;;
    *) : ;;
  esac
  exit 0
fi
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "list" ]; then printf '[{"headRefName":"feat/open-live"}]\n'; exit 0; fi
exit 0
EOF

# herdr stub: one workspace, two tabs — a STALE one whose slug ("ghost") has neither a worktree nor an
# open PR (the watcher died before its teardown ran), and the open-live builder's, which must survive.
cat > "$BIN/herdr" <<EOF
#!/usr/bin/env bash
case "\${1:-}/\${2:-}" in
  workspace/list) printf '{"result":{"workspaces":[{"workspace_id":"ws1","label":"sweepws"}]}}\n' ;;
  tab/list) printf '%s\n' '{"result":{"tabs":[{"tab_id":"tabSTALE","label":"ghost","workspace_id":"ws1"},{"tab_id":"tabRESOLVE","label":"resolve·open-live","workspace_id":"ws1"},{"tab_id":"tabLIVE","label":"open-live","workspace_id":"ws1"}]}}' ;;
  tab/close) printf '%s\n' "\${3:-}" >> "$TAB_CLOSED" ;;
  agent/list) printf '{"result":{"agents":[]}}\n' ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$BIN/gh" "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── source the engine in lib mode ────────────────────────────────────────────
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless
export PROJECT_ROOT="$MAINDIR" WORKTREES_DIR="$TREESDIR" WORKSPACE_NAME=sweepws
export DEFAULT_BRANCH="origin/main"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_SWEEP_KILL_GRACE=2
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }

# ── (1) loading + hermetic seal ──────────────────────────────────────────────
for fn in sweep_main sweep_auto_mode sweep_scan_counts sweep_advice_line sweep_dead_marker_keys \
          sweep_orphan_procs sweep_run_safe_legs sweep_leg_worktrees sweep_leg_tabs \
          sweep_leg_markers sweep_leg_procs sweep_journal_advice_once _sweep_owns_path \
          _sweep_live_marker_pids _sweep_live_marker_sessions _sweep_sess_of \
          _orphan_tab_ids build_sweep_note _sweep_trigger_tick; do
  type "$fn" >/dev/null 2>&1 || fail "(1) $fn not defined after sourcing"
done
case "$(_journal_file)" in "$T"/*) : ;; *) fail "(1) journal path escapes the sandbox: $(_journal_file)" ;; esac
[ "$MAIN" = "$MAINDIR" ] || fail "(1) MAIN did not bind to the fixture repo (got '$MAIN')"
ok; echo "PASS (1) sweep library loads via AGENT_WATCH_LIB; journal sandboxed"

jcount(){ local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }

# ── plant the rest of the mess: registry, markers, orphan process ────────────
cat > "$TREESDIR/.herd-tabs" <<'EOF'
ghost tabSTALE builder
resolve·open-live tabRESOLVE resolver
open-live tabLIVE builder
EOF

DEADPID="$(bash -c 'exit 0' & p=$!; wait "$p" 2>/dev/null; printf '%s' "$p")"
DEADMARK="$TREESDIR/.review-inflight-777-deadsha"
printf '%s\n%s\n%s\n' "$DEADPID" "stale start time" "$(date +%s)" > "$DEADMARK"

# A LIVE gate worker: backgrounded, so its marker reads live. Leg 4 must never kill it (assert 6).
bash -c 'sleep 60' & LIVEWORKER=$!
disown 2>/dev/null || true   # keep bash from printing a "Terminated" job notice when we reap it
LIVEMARK="$TREESDIR/.health-inflight-888-livesha"
printf '%s\n%s\n%s\n' "$LIVEWORKER" "$(_pid_starttime "$LIVEWORKER")" "$(date +%s)" > "$LIVEMARK"

# The orphan victim: a real process we own, presented to the sweep as a ppid=1 healthcheck tree.
bash -c 'sleep 60' & VICTIM=$!
disown 2>/dev/null || true
cat > "$T/ps-stub" <<EOF
#!/usr/bin/env bash
# pid ppid pgid command   — the victim (orphan), the live gate worker (must be spared by the marker
# exemption), and a SIBLING project's healthcheck (must be spared by path attribution).
printf '%s 1 0 bash %s/scripts/herd/healthcheck.sh %s/merged-clean\n' "$VICTIM" "$MAINDIR" "$TREESDIR"
printf '%s 1 0 bash %s/scripts/herd/healthcheck.sh %s/merged-clean\n' "$LIVEWORKER" "$MAINDIR" "$TREESDIR"
printf '9999901 1 0 bash /elsewhere/other-proj/tests/test-x.sh\n'
EOF
chmod +x "$T/ps-stub"
export HERD_SWEEP_PS_CMD="$T/ps-stub"
printf '#!/usr/bin/env bash\nprintf ""\n' > "$T/cwd-stub"; chmod +x "$T/cwd-stub"
export HERD_SWEEP_PROC_CWD_CMD="$T/cwd-stub"
# Occupancy stub: only tmp-inuse is held open by a live process.
cat > "$T/inuse-stub" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in *tmp-inuse) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$T/inuse-stub"; export HERD_SWEEP_DIR_INUSE_CMD="$T/inuse-stub"
# Session seam (HERD-348): resolve a pid's SESSION deterministically instead of shelling `os.getsid`,
# so the session-exemption is exercised hermetically. A pid's session is the LEADER recorded for it in
# sess-map ("<pid> <leader>" lines), else the pid itself — i.e. every process is its own session island
# unless we explicitly place it in another's. So the genuine orphan VICTIM never shares a live worker's
# session, while (19) plants a bats subtree that does.
: > "$T/sess-map"
cat > "$T/sess-stub" <<EOF
#!/usr/bin/env bash
led="\$(awk -v p="\${1:-}" '\$1==p{print \$2; exit}' "$T/sess-map" 2>/dev/null)"
printf '%s' "\${led:-\${1:-}}"
EOF
chmod +x "$T/sess-stub"; export HERD_SWEEP_SESS_CMD="$T/sess-stub"

# ── (6) attribution + live-marker exemption ──────────────────────────────────
MAIN=/x/proj TREES=/x/proj-trees _sweep_owns_path /x/proj-other/t.sh \
  && fail "(6) a sibling project's path was attributed to us (cross-project kill, issue #60)"
MAIN=/x/proj TREES=/x/proj-trees _sweep_owns_path /x/proj/scripts/t.sh \
  || fail "(6) our own path was not attributed to us"
_sweep_live_marker_pids | grep -qx "$LIVEWORKER" || fail "(6) the live marker's pid was not reported live"
PROCS="$(sweep_orphan_procs)"
printf '%s' "$PROCS" | grep -q "^$VICTIM	" || fail "(6) the orphan victim was not detected"
printf '%s' "$PROCS" | grep -q "^$LIVEWORKER	" && fail "(6) a LIVE gate worker was listed as an orphan — killing it strands the PR"
printf '%s' "$PROCS" | grep -q '9999901' && fail "(6) a foreign project's process was listed as an orphan"
ok; echo "PASS (6) attribution rejects sibling/foreign paths; a live gate worker is never an orphan"

# ── (20) HERD-348: session exemption spares a detached gate worker's WHOLE subtree ────────────────
# The python engine dispatches the health suite with start_new_session=True, so the worker is a session
# LEADER and its `timeout … bats` subtree runs in a DIFFERENT process group inside that session (GNU
# timeout re-groups its child). The marker records the worker PID — which is NOT the pid the sweep sees
# for the reparented bats — so a pid-ONLY exemption reaps a LIVE suite mid-run: logs freeze, no outcome
# lands, the inflight times out and re-dispatches forever (the #450/#451/#452 stall). The fix spares by
# SESSION. Here SESS_BATS shares the live worker's session but carries its own pid/pgid.
# NB: sourcing agent-watch.sh reassigned HERE to scripts/herd, so derive pysrc from the stable $WATCH.
PYSRC="$(cd "$(dirname "$WATCH")/../.." && pwd)/pysrc"
bash -c 'sleep 60' & SESS_WRAP=$!; disown 2>/dev/null || true   # the detached worker (session leader)
bash -c 'sleep 60' & SESS_BATS=$!; disown 2>/dev/null || true   # its bats subtree: own pid/pgid, same session
printf '%s %s\n' "$SESS_BATS" "$SESS_WRAP" >> "$T/sess-map"     # bats' session leader is the worker
SESSMARK="$TREESDIR/.health-inflight-919-sesssha"
# leg (b): the REAL python worker writes its SESSION on the marker's 4th line. Assert the writer does so
# — this is the "direct lookup" half of the fix (a candidate whose recorded session matches is spared
# without any ps of the marker pid).
PYTHONPATH="$PYSRC" python3 -c 'import sys
from herd.live_runtime import _marker_write
_marker_write(sys.argv[1], int(sys.argv[2]))' "$SESSMARK" "$SESS_WRAP" \
  || fail "(20) real _marker_write raised"
L4="$(sed -n '4p' "$SESSMARK" | tr -d '[:space:]')"
EXP4="$(PYTHONPATH="$PYSRC" python3 -c 'import os,sys; print(os.getsid(int(sys.argv[1])))' "$SESS_WRAP")"
[ -n "$L4" ] && [ "$L4" = "$EXP4" ] \
  || fail "(20) leg-b: the python marker did not record the worker's session on line 4 (got '$L4', want '$EXP4')"
# SURVIVE MID-SWEEP: with the marker live, neither the worker pid (marker-exempt) nor its bats subtree
# (session-exempt) is listed as an orphan.
cat > "$T/ps-sess" <<EOF
#!/usr/bin/env bash
printf '%s 1 %s bash %s/scripts/herd/healthcheck.sh %s/merged-clean\n' "$SESS_WRAP" "$SESS_WRAP" "$MAINDIR" "$TREESDIR"
printf '%s 1 %s bash %s/scripts/herd/healthcheck.sh %s/merged-clean\n' "$SESS_BATS" "$SESS_BATS" "$MAINDIR" "$TREESDIR"
EOF
chmod +x "$T/ps-sess"
_sweep_live_marker_sessions | grep -qx "$SESS_WRAP" \
  || fail "(20) leg-a/b: the live marker's session was not reported"
PROCS2="$(HERD_SWEEP_PS_CMD="$T/ps-sess" sweep_orphan_procs)"
printf '%s' "$PROCS2" | grep -q "^$SESS_WRAP	" && fail "(20) the live worker (marker pid) was listed as an orphan"
printf '%s' "$PROCS2" | grep -q "^$SESS_BATS	" \
  && fail "(20) a LIVE suite's bats subtree (session-exempt) was reaped mid-run — the #450/#451/#452 stall"
# GENUINE ORPHAN: once the marker is gone, nothing proves the session live, so the same bats IS reaped.
rm -f "$SESSMARK"
PROCS3="$(HERD_SWEEP_PS_CMD="$T/ps-sess" sweep_orphan_procs)"
printf '%s' "$PROCS3" | grep -q "^$SESS_BATS	" \
  || fail "(20) a genuinely orphaned bats (marker gone) must still be reaped"
kill "$SESS_WRAP" "$SESS_BATS" 2>/dev/null || true
ok; echo "PASS (20) a detached gate worker's whole subtree is session-exempt; a marker-gone orphan is still reaped"

# ── (2) detection + console row ──────────────────────────────────────────────
read -r C_TABS C_MARKERS C_PROCS <<< "$(sweep_scan_counts)"
[ "$C_MARKERS" = "1" ] || fail "(2) expected 1 dead marker, got '$C_MARKERS'"
[ "$C_PROCS" = "1" ]   || fail "(2) expected 1 orphan proc, got '$C_PROCS'"
# 'ghost' has no worktree → counted. 'open-live' (and its resolve· tab) does → not counted.
[ "$C_TABS" = "1" ]    || fail "(2) expected 1 stale tab, got '$C_TABS'"
LINE="$(sweep_advice_line 2 1 0)"
[ "$LINE" = "🧹 sweep recommended: 2 stale tabs · 1 dead marker" ] || fail "(2) advice line wrong: '$LINE'"
[ -z "$(sweep_advice_line 0 0 0)" ] || fail "(2) a clean control room must render NO advisory row"
[ "$(sweep_advice_line 1 0 1)" = "🧹 sweep recommended: 1 stale tab · 1 orphan proc" ] || fail "(2) singular form wrong"
ok; echo "PASS (2) cheap detection counts the mess; advisory row renders (and stays empty when clean)"

# ── (3) dry-run is inert ─────────────────────────────────────────────────────
PLAN="$(cd "$T" && sweep_main --dry-run 2>&1)" || fail "(3) dry-run exited non-zero"
printf '%s' "$PLAN" | grep -q "reap worktree merged-clean" || fail "(3) plan omits the merged worktree reap"
printf '%s' "$PLAN" | grep -q "drop dead inflight marker"  || fail "(3) plan omits the dead marker"
printf '%s' "$PLAN" | grep -q "kill orphan pid $VICTIM"    || fail "(3) plan omits the orphan process"
printf '%s' "$PLAN" | grep -q "FLAG merged-dirty"          || fail "(3) plan omits the dirty-worktree flag"
printf '%s' "$PLAN" | grep -q "close stale resolve tab tabRESOLVE" \
  || fail "(3) plan omits the stale resolve tab it would close (invisible destructive action)"
[ -d "$TREESDIR/merged-clean" ] || fail "(3) DRY-RUN DELETED a worktree"
[ -f "$DEADMARK" ]              || fail "(3) DRY-RUN removed the dead marker"
kill -0 "$VICTIM" 2>/dev/null   || fail "(3) DRY-RUN killed the orphan process"
[ ! -s "$TAB_CLOSED" ]          || fail "(3) DRY-RUN closed a tab"
[ "$(jcount '"event":"reap"')" = "0" ] || fail "(3) DRY-RUN journaled a reap"
ok; echo "PASS (3) --dry-run prints the full plan and touches nothing"

# ── (5a) judgment legs under AUTO: flagged, never deleted ────────────────────
: > "$JOURNAL_FILE"
sweep_run_safe_legs >/dev/null 2>&1 || fail "(5a) sweep_run_safe_legs exited non-zero"
[ -d "$TREESDIR/merged-dirty" ]  || fail "(5a) AUTO DELETED a worktree carrying real dirt"
[ -d "$TREESDIR/closed-unique" ] || fail "(5a) AUTO DELETED a worktree carrying unique commits"
[ -d "$TREESDIR/open-live" ]     || fail "(5a) AUTO deleted an OPEN PR's worktree"
[ -d "$TREESDIR/stale-sha" ]     || fail "(10) AUTO reaped a worktree with NO sha anchor"
grep -q '"reason":"merged-dirty"' "$JOURNAL_FILE"          || fail "(5a) no sweep_flag for the dirty worktree"
grep -q '"reason":"closed-unique-commits"' "$JOURNAL_FILE" || fail "(5a) no sweep_flag for the unique-commit worktree"
grep '"event":"sweep_flag"' "$JOURNAL_FILE" | grep -q 'f.txt' || fail "(5a) the dirty flag carries no file evidence"
grep -q '"reason":"scratch-unique-commits"' "$JOURNAL_FILE" \
  || fail "(5a) no sweep_flag for the DETACHED tree carrying unique commits"
grep -q '"reason":"scratch-in-use"' "$JOURNAL_FILE" \
  || fail "(5a) no sweep_flag for the DETACHED tree a live process holds open"
[ -d "$TREESDIR/tmp-inuse" ] || fail "(5a) reaped a detached tree a live process holds open"
ok; echo "PASS (5) judgment legs FLAGGED with evidence, never auto-deleted (auto mode)"

# ── (13) detached scratch: unique commits are unrecoverable → FLAG, never reap ───────────────────
[ -d "$TREESDIR/tmp-precious" ] \
  || fail "(13) AUTO DELETED a detached scratch tree whose commit exists on NO branch (unrecoverable)"
git -C "$MAINDIR" cat-file -e "$PRECIOUS_SHA^{commit}" 2>/dev/null \
  || fail "(13) the detached tree's unique commit is gone from the object store"
[ ! -d "$TREESDIR/tmp-clean" ] \
  || fail "(13) a CLEAN detached scratch tree with zero unique commits should still be reaped"
ok; echo "PASS (13) detached scratch: unique commits FLAGGED (unrecoverable); clean scratch still reaped"
ok; echo "PASS (10) a worktree whose HEAD != the merged PR's headRefOid is never reaped"

# ── (4) safe legs acted + journaled ──────────────────────────────────────────
[ ! -d "$TREESDIR/merged-clean" ] || fail "(4) the clean merged worktree was not reaped"
[ ! -d "$TREESDIR/merged-regen" ] || fail "(4) the merged worktree with only regenerable dirt was not reaped"
[ ! -f "$DEADMARK" ]              || fail "(4) the dead inflight marker was not dropped"
[ -f "$LIVEMARK" ]                || fail "(4) a LIVE inflight marker was dropped"
grep -q '"event":"reap"' "$JOURNAL_FILE"        || fail "(4) no reap journaled"
grep -q '"event":"sweep_closed"' "$JOURNAL_FILE" || fail "(4) no tab close journaled"
grep -q 'tabSTALE' "$TAB_CLOSED"                     || fail "(4) the stale tab was not closed"
grep -q 'tabLIVE'  "$TAB_CLOSED"                     && fail "(4) a LIVE builder's tab was closed"
grep -q 'tabSTALE' "$TREESDIR/.herd-tabs"            && fail "(4) the swept tab's registry row was not pruned"
grep -q '"event":"sweep_proc"' "$JOURNAL_FILE"  || fail "(4) no orphan-process kill journaled"
grep -q 'tabRESOLVE' "$TAB_CLOSED"                   || fail "(4) the stale resolve tab was not closed"
grep -q '"event":"reap_resolve_tab"' "$JOURNAL_FILE"  || fail "(4) the resolve-tab close was not journaled"
grep -q 'tabRESOLVE' "$TREESDIR/.herd-tabs"          && fail "(4) the resolve tab's registry row was not pruned"
sleep 1
kill -0 "$VICTIM" 2>/dev/null && fail "(4) the orphan process survived the sweep"
kill -0 "$LIVEWORKER" 2>/dev/null || fail "(4) the LIVE gate worker was killed"
ok; echo "PASS (4) safe legs reaped worktrees, closed the stale tab, dropped the dead marker, killed the orphan"

# ── (7) pid-recycling guard — exercised through the REAL kill primitive ─────────────────────────
# _sweep_term_one is what sweep_leg_procs actually calls. (An earlier revision tested the guard only
# through a _sweep_kill_tree wrapper with ZERO production callers, so the suite stayed green while the
# shipped path was unguarded. That wrapper is gone; these drive the real thing.)
: > "$JOURNAL_FILE"
bash -c 'sleep 30' & SURVIVOR=$!
disown 2>/dev/null || true
OUT="$(_sweep_term_one "$SURVIVOR" 0 "a start-time that will never match")"
[ -z "$OUT" ] || fail "(7) a start-time MISMATCH must signal NOTHING (got target '$OUT')"
kill -0 "$SURVIVOR" 2>/dev/null || fail "(7) a start-time MISMATCH must REFUSE the kill (pid recycled)"
grep -q '"reason":"pid-recycled"' "$JOURNAL_FILE" || fail "(7) the refused kill was not journaled"
kill "$SURVIVOR" 2>/dev/null || true
ok; echo "PASS (7) a start-time mismatch refuses the kill (pid-recycling guard, real path)"

# ── (14) the guard is NOT inert: the token comes from LISTING, not from kill time ────────────────
# THE REGRESSION TEST. sweep_orphan_procs must emit the start-time as a 4th field, and sweep_leg_procs
# must compare that LISTED token against the pid's CURRENT one. If the kill path re-samples the token
# itself (as it once did), st and cur are two ps calls microseconds apart, can never differ, and the
# recycling guard is dead code. Here _pid_starttime returns "ST-A" on its first call (listing) and
# "ST-B" thereafter — simulating a pid recycled between listing and TERM. The victim MUST survive.
: > "$JOURNAL_FILE"
bash -c 'sleep 30' & RECYCLED=$!
disown 2>/dev/null || true
cat > "$T/ps-recycle" <<EOF
#!/usr/bin/env bash
printf '%s 1 0 bash %s/scripts/herd/healthcheck.sh %s/x\n' "$RECYCLED" "$MAINDIR" "$TREESDIR"
EOF
chmod +x "$T/ps-recycle"
# Per-pid call counter: the FIRST read of a pid's start-time (the listing) reports ST-A; every later
# read (the kill-time re-verify) reports ST-B — i.e. the pid number was recycled inside the window
# between the listing that authorized the kill and the TERM. Other pids (the live gate worker's
# marker) are untouched. sweep_leg_procs relists internally, so the flip must key on the pid, not on
# wall-clock ordering.
ST_DIR="$T/st"; mkdir -p "$ST_DIR"
_pid_starttime() {
  local p="${1:-}" f="$ST_DIR/${1:-none}"
  case "$p" in
    "$RECYCLED")
      if [ -f "$f" ]; then printf 'ST-B'; else : > "$f"; printf 'ST-A'; fi ;;
    *) printf 'ST-OTHER-%s' "$p" ;;
  esac
}
ROWS="$(HERD_SWEEP_PS_CMD="$T/ps-recycle" sweep_orphan_procs)"
[ "$(printf '%s' "$ROWS" | awk -F'\t' '{print NF; exit}')" = "4" ] \
  || fail "(14) sweep_orphan_procs must emit pid/pgid/STARTTIME/cmd — got: $ROWS"
printf '%s' "$ROWS" | cut -f3 | grep -qx 'ST-A' || fail "(14) the row must carry the LISTING-time token"
rm -f "$ST_DIR/$RECYCLED"                # re-arm: the coming sweep_leg_procs does its own listing
HERD_SWEEP_PS_CMD="$T/ps-recycle" sweep_leg_procs "" >/dev/null 2>&1
kill -0 "$RECYCLED" 2>/dev/null \
  || fail "(14) INERT GUARD: a pid recycled between listing and TERM was killed"
grep -q '"reason":"pid-recycled"' "$JOURNAL_FILE" || fail "(14) the recycled pid was not journaled as skipped"
unset -f _pid_starttime
. "$WATCH" >/dev/null 2>&1 || true       # restore the real _pid_starttime
kill "$RECYCLED" 2>/dev/null || true
ok; echo "PASS (14) start-time is captured at LISTING and re-verified at kill (guard is live, not inert)"

# ── (15) a stale pgid is never used as a GROUP-kill target ───────────────────────────────────────
: > "$JOURNAL_FILE"
bash -c 'sleep 30' & MOVED=$!
disown 2>/dev/null || true
_sweep_pgid_of() { printf '999002'; }    # current pgid ≠ the listed one
OUT="$(_sweep_term_one "$MOVED" 999001 "")"
[ "$OUT" = "$MOVED" ] || fail "(15) a pid whose pgid changed since listing must be pid-killed, not group-killed (target '$OUT')"
grep -q '"reason":"pgid-changed"' "$JOURNAL_FILE" || fail "(15) the pgid mismatch was not journaled"
unset -f _sweep_pgid_of
. "$WATCH" >/dev/null 2>&1 || true
kill "$MOVED" 2>/dev/null || true
ok; echo "PASS (15) a stale pgid is re-verified and never aimed at as a process group"

# ── (11) shared-pgid guard: never GROUP-kill a group holding a process we must spare ─────────────
: > "$JOURNAL_FILE"
SHARED_PGID=777001
bash -c 'sleep 30' & SPARE_VICTIM=$!
disown 2>/dev/null || true
cat > "$T/ps-shared" <<EOF
#!/usr/bin/env bash
printf '%s 1 %s bash %s/scripts/herd/healthcheck.sh %s/x\n' "$SPARE_VICTIM" "$SHARED_PGID" "$MAINDIR" "$TREESDIR"
printf '%s 1 %s bash %s/scripts/herd/healthcheck.sh %s/y\n' "$LIVEWORKER" "$SHARED_PGID" "$MAINDIR" "$TREESDIR"
EOF
chmod +x "$T/ps-shared"
kill -0 "$LIVEWORKER" 2>/dev/null || fail "(11) precondition: the live gate worker must still be running"
PS_SAVED="$HERD_SWEEP_PS_CMD"; export HERD_SWEEP_PS_CMD="$T/ps-shared"
OUT="$(_sweep_term_one "$SPARE_VICTIM" "$SHARED_PGID" "$(_pid_starttime "$SPARE_VICTIM")")"
export HERD_SWEEP_PS_CMD="$PS_SAVED"
[ "$OUT" = "$SPARE_VICTIM" ] || fail "(11) a spared group must degrade to a single-pid kill (target '$OUT')"
grep -q '"reason":"spared-group"' "$JOURNAL_FILE" \
  || fail "(11) a group holding a live gate worker was GROUP-killed (would reap the healthy worker)"
kill -0 "$LIVEWORKER" 2>/dev/null || fail "(11) the live gate worker sharing the pgid was killed"
kill "$SPARE_VICTIM" 2>/dev/null || true
ok; echo "PASS (11) a shared pgid holding a spared process degrades to a single-pid kill"

# ── (16) corpse-sweep is serialized: no double-charged retry budget / infra breaker ──────────────
# `herd sweep`'s leg 3 makes _sweep_gate_corpses a SECOND concurrent caller alongside the live watcher
# tick (cmd_sweep runs legs 1-4 before leg 5 restarts the watcher). Without a claim, both can win the
# same corpse and both run record_review_retry (bare `>>` append) and _breaker_record_infra (a
# read-modify-write) — silently double-charging the PR's review-retry budget.
: > "$JOURNAL_FILE"
DEADPID2="$(bash -c 'exit 0' & p=$!; wait "$p" 2>/dev/null; printf '%s' "$p")"
CORPSE="$TREESDIR/.review-inflight-901-shaX"
printf '%s\n%s\n%s\n' "$DEADPID2" "stale" "$(date +%s)" > "$CORPSE"
_gate_corpse_claim || fail "(16) precondition: the mutex must be free"
_sweep_gate_corpses                       # a CONCURRENT caller: must stand down, touch nothing
[ -f "$CORPSE" ] || fail "(16) a concurrent corpse sweep acted while another holder had the claim"
[ "$(jcount '"reason":"review_died"')" = "0" ] || fail "(16) the locked-out sweep still journaled/charged a retry"
_gate_corpse_release
_sweep_gate_corpses                       # now the claim is free: it reaps exactly once
[ ! -f "$CORPSE" ] || fail "(16) the corpse was not reaped once the claim was free"
[ "$(jcount '"reason":"review_died"')" = "1" ] || fail "(16) expected exactly ONE review_died charge"
_sweep_gate_corpses                       # idempotent re-run must not double-charge
[ "$(jcount '"reason":"review_died"')" = "1" ] || fail "(16) a re-run double-charged the review retry budget"
ok; echo "PASS (16) corpse sweep holds an atomic claim — no double-charged retry budget / breaker"

# ── (17) past-deadline LIVE workers appear in the plan (leg 3 narrates what it will kill) ────────
# _sweep_gate_corpses SIGTERMs them, so --dry-run must show them or the sweep performs a destructive
# action it never announced.
: > "$JOURNAL_FILE"
bash -c 'sleep 30' & SLOWPID=$!
disown 2>/dev/null || true
SLOWMARK="$TREESDIR/.review-inflight-902-shaY"
printf '%s\n%s\n%s\n' "$SLOWPID" "$(_pid_starttime "$SLOWPID")" "$(( $(date +%s) - 9999 ))" > "$SLOWMARK"
REVIEW_INFLIGHT_TIMEOUT=1 sweep_timedout_marker_keys | grep -q '.review-inflight-902-shaY' \
  || fail "(17) a past-deadline LIVE marker was not detected"
PLAN2="$(REVIEW_INFLIGHT_TIMEOUT=1 sweep_leg_markers 1 2>&1)"
printf '%s' "$PLAN2" | grep -q 'SIGTERM past-deadline worker for .review-inflight-902-shaY' \
  || fail "(17) the plan omits the past-deadline worker it would SIGTERM: $PLAN2"
kill -0 "$SLOWPID" 2>/dev/null || fail "(17) the dry-run plan killed the worker"
kill "$SLOWPID" 2>/dev/null || true; rm -f "$SLOWMARK"
ok; echo "PASS (17) leg 3 narrates the past-deadline workers it will SIGTERM (plan == action)"

# ── (18) auto stands down on a no-progress condition-set (false-positive tab count) ──────────────
# sweep_cheap_tab_count knowingly over-counts. Without a memo, one false positive re-runs every safe
# leg — a `gh pr view` per worktree plus a `gh pr list` — on every cadence tick, forever.
rm -f "$TREESDIR/.sweep-auto-acted"
_sweep_auto_should_act 1 0 0 || fail "(18) a fresh condition-set must be acted on"
_sweep_auto_record 1 0 0 0                    # …and it swept NOTHING
_sweep_auto_should_act 1 0 0 && fail "(18) a repeat no-progress condition-set must stand down"
_sweep_auto_should_act 2 0 0 || fail "(18) a CHANGED condition-set must re-arm"
_sweep_auto_record 2 0 0 3                    # this one swept 3 things
_sweep_auto_should_act 2 0 0 || fail "(18) a condition-set whose last run made progress must retry"
ok; echo "PASS (18) auto stands down on a no-progress repeat, re-arms on change or progress"

# ── (8) advice journaled once per condition-set ──────────────────────────────
: > "$JOURNAL_FILE"; rm -f "$TREESDIR/.sweep-advice"
sweep_journal_advice_once 2 1 0
[ "$(jcount '"event":"sweep_advice"')" = "1" ] || fail "(8) the first condition-set was not journaled"
sweep_journal_advice_once 2 1 0
[ "$(jcount '"event":"sweep_advice"')" = "1" ] || fail "(8) an UNCHANGED condition-set journaled twice"
sweep_journal_advice_once 3 1 0
[ "$(jcount '"event":"sweep_advice"')" = "2" ] || fail "(8) a CHANGED condition-set did not journal"
sweep_journal_advice_once 0 0 0
[ -f "$TREESDIR/.sweep-advice" ] && fail "(8) a clean scan must clear the memo"
ok; echo "PASS (8) sweep_advice journals once per distinct condition-set"

# ── (9) SWEEP_AUTO normalization + off is inert ──────────────────────────────
[ "$(SWEEP_AUTO=off    sweep_auto_mode)" = off ]    || fail "(9) off"
[ "$(SWEEP_AUTO=auto   sweep_auto_mode)" = auto ]   || fail "(9) auto"
[ "$(SWEEP_AUTO=advise sweep_auto_mode)" = advise ] || fail "(9) advise"
[ "$(unset SWEEP_AUTO; sweep_auto_mode)" = advise ] || fail "(9) unset must default to advise"
[ "$(SWEEP_AUTO=wat    sweep_auto_mode)" = advise ] || fail "(9) an unknown value must degrade to advise (never auto)"
SWEEP_AUTO=off; _SWEEP_C_TABS=5; _SWEEP_C_MARKERS=5; _SWEEP_C_PROCS=5
build_sweep_note
[ -z "${SWEEP_NOTE:-}" ] || fail "(9) SWEEP_AUTO=off must render NO console row"
SWEEP_AUTO=advise; build_sweep_note
printf '%s' "${SWEEP_NOTE:-}" | grep -q 'sweep recommended' || fail "(9) advise must render the console row"
ok; echo "PASS (9) SWEEP_AUTO off|advise|auto normalize; off is byte-inert; unknown degrades to advise"

# ── (12) counters reset per run ──────────────────────────────────────────────
# The watcher (SWEEP_AUTO=auto) calls sweep_run_safe_legs on every cadence tick inside ONE long-lived
# process. Without a per-run reset the SWEEP_N_* globals accumulate and each `sweep_auto` journal line
# reports a lifetime total rather than what that tick actually swept. Everything is already clean here,
# so a second pass must journal all-zero counts.
# The four judgment worktrees (merged-dirty, closed-unique, tmp-precious, tmp-inuse) survive every pass
# and are re-flagged each time, so `flagged` exposes accumulation: it must read 4 EVERY pass, not 4,8…
: > "$JOURNAL_FILE"
sweep_run_safe_legs >/dev/null 2>&1 || true
sweep_run_safe_legs >/dev/null 2>&1 || true
LAST="$(grep '"event":"sweep_auto"' "$JOURNAL_FILE" | tail -1)"
printf '%s' "$LAST" | grep -q '"flagged":4' \
  || fail "(12) counters accumulated across runs (expected flagged=4 on every pass): $LAST"
printf '%s' "$LAST" | grep -q '"reaped":0' || fail "(12) reaped counter accumulated across runs: $LAST"
ok; echo "PASS (12) SWEEP_N_* counters reset per run (auto ticks never report a lifetime total)"

# ── (19) stray-watcher detection EXEMPTS live gate-worker forks (HERD-217) ───────────────────────
# Leg 5 delegates the kill of every pid sweep_stray_watchers lists to _stop_project_watcher, which
# SIGKILLs it. But the canonical watcher FORKS its healthcheck/review gate workers, and each re-execs
# under the SAME argv0 ($HERD_WATCH_ARGV0) — so a live gate worker is argv0-indistinguishable from a
# duplicate watcher. Listing one strands the PR behind a corpse (the live 2026-07-09 failure). This
# asserts sweep_stray_watchers exempts a gate-worker fork two ways — a CHILD of the canonical watcher,
# and a reparented fork that still PARENTS a live healthcheck/review worker — while STILL listing a
# genuine orphan duplicate whose parent is dead and which owns no gate child.
WPID=700001        # the canonical (lockfile) watcher
FORK_A=700002      # a gate-worker fork: ppid == canonical  → exempt (ppid guard)
FORK_B=700003      # a gate-worker fork reparented to init, still parenting a healthcheck  → exempt (child guard)
HC_CHILD=700004    # FORK_B's live healthcheck worker (not argv0-tagged; it is the gate child)
ORPHAN=700005      # a GENUINE orphan duplicate: parent dead, no gate child  → must be LISTED
printf '%s\n' "$WPID" > "$T/watch.lock"
cat > "$T/ps-stray" <<EOF
#!/usr/bin/env bash
# pid ppid pgid command  — argv0 (first token) == the marker tags a watcher.
printf '%s 1 %s herd-watch-sweepws bash %s/scripts/herd/agent-watch.sh --watch\n'         "$WPID"     "$WPID"   "$MAINDIR"
printf '%s %s %s herd-watch-sweepws bash %s/scripts/herd/agent-watch.sh\n'                 "$FORK_A"   "$WPID"   "$FORK_A"  "$MAINDIR"
printf '%s 1 %s herd-watch-sweepws bash %s/scripts/herd/agent-watch.sh\n'                  "$FORK_B"   "$FORK_B" "$MAINDIR"
printf '%s %s %s bash %s/scripts/herd/healthcheck.sh %s/merged-clean\n'                    "$HC_CHILD" "$FORK_B" "$FORK_B"  "$MAINDIR" "$TREESDIR"
printf '%s 1 %s herd-watch-sweepws bash %s/scripts/herd/agent-watch.sh\n'                  "$ORPHAN"   "$ORPHAN" "$MAINDIR"
EOF
chmod +x "$T/ps-stray"
STRAY="$(HERD_SWEEP_PS_CMD="$T/ps-stray" HERD_WATCH_ARGV0=herd-watch-sweepws HERD_WATCHER_LOCK="$T/watch.lock" sweep_stray_watchers)"
printf '%s\n' "$STRAY" | grep -qx "$ORPHAN" \
  || fail "(19) a GENUINE orphan duplicate watcher (parent dead, no gate child) was not listed: '$STRAY'"
printf '%s\n' "$STRAY" | grep -qx "$WPID" \
  && fail "(19) the canonical lockfile watcher was listed as a stray"
printf '%s\n' "$STRAY" | grep -qx "$FORK_A" \
  && fail "(19) a live gate-worker fork (child of the canonical watcher) was listed — leg 5 would SIGKILL it and strand the PR"
printf '%s\n' "$STRAY" | grep -qx "$FORK_B" \
  && fail "(19) a reparented gate-worker fork still parenting a live healthcheck was listed — leg 5 would SIGKILL in-flight gate work"
printf '%s\n' "$STRAY" | grep -qx "$HC_CHILD" \
  && fail "(19) a non-argv0-tagged healthcheck worker was mistaken for a watcher"
# MUTATION CHECK: exactly these two exemptions are load-bearing. Deleting the ppid guard lists FORK_A;
# deleting the gate-child guard lists FORK_B — either regression flips one assertion above to FAIL.
ok; echo "PASS (19) stray-watcher detection exempts live gate-worker forks, still lists a genuine orphan"

echo
echo "ALL PASS ($PASS checks)"
