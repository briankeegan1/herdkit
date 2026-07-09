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
#   • a dead-pid inflight marker                       → dropped
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
trap 'kill "${VICTIM:-}" "${LIVEWORKER:-}" 2>/dev/null || true; rm -rf "$T"' EXIT
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
  tab/list) printf '%s\n' '{"result":{"tabs":[{"tab_id":"tabSTALE","label":"ghost","workspace_id":"ws1"},{"tab_id":"tabLIVE","label":"open-live","workspace_id":"ws1"}]}}' ;;
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
          _sweep_live_marker_pids _orphan_tab_ids build_sweep_note _sweep_trigger_tick; do
  type "$fn" >/dev/null 2>&1 || fail "(1) $fn not defined after sourcing"
done
case "$(_journal_file)" in "$T"/*) : ;; *) fail "(1) journal path escapes the sandbox: $(_journal_file)" ;; esac
[ "$MAIN" = "$MAINDIR" ] || fail "(1) MAIN did not bind to the fixture repo (got '$MAIN')"
ok; echo "PASS (1) sweep library loads via AGENT_WATCH_LIB; journal sandboxed"

jcount(){ local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }

# ── plant the rest of the mess: registry, markers, orphan process ────────────
cat > "$TREESDIR/.herd-tabs" <<'EOF'
ghost tabSTALE builder
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

# ── (2) detection + console row ──────────────────────────────────────────────
read -r C_TABS C_MARKERS C_PROCS <<< "$(sweep_scan_counts)"
[ "$C_MARKERS" = "1" ] || fail "(2) expected 1 dead marker, got '$C_MARKERS'"
[ "$C_PROCS" = "1" ]   || fail "(2) expected 1 orphan proc, got '$C_PROCS'"
# 'ghost' has no worktree → counted; 'open-live' does → not counted.
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
ok; echo "PASS (5) judgment legs FLAGGED with evidence, never auto-deleted (auto mode)"
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
sleep 1
kill -0 "$VICTIM" 2>/dev/null && fail "(4) the orphan process survived the sweep"
kill -0 "$LIVEWORKER" 2>/dev/null || fail "(4) the LIVE gate worker was killed"
ok; echo "PASS (4) safe legs reaped worktrees, closed the stale tab, dropped the dead marker, killed the orphan"

# ── (7) pid-recycling guard ──────────────────────────────────────────────────
: > "$JOURNAL_FILE"
bash -c 'sleep 30' & SURVIVOR=$!
disown 2>/dev/null || true
_sweep_kill_tree "$SURVIVOR" 0 "a start-time that will never match"
kill -0 "$SURVIVOR" 2>/dev/null || fail "(7) a start-time MISMATCH must REFUSE the kill (pid recycled)"
grep -q '"reason":"pid-recycled"' "$JOURNAL_FILE" || fail "(7) the refused kill was not journaled"
kill "$SURVIVOR" 2>/dev/null || true
ok; echo "PASS (7) a start-time mismatch refuses the kill (pid-recycling guard)"

# ── (11) shared-pgid guard: never GROUP-kill a group holding a process we must spare ─────────────
# Observed live: several orphans share one pgid. If a live gate worker (or the watcher) sits in that
# group, `kill -TERM -<pgid>` would reap it too. The sweep must degrade to a single-pid kill instead.
: > "$JOURNAL_FILE"
SHARED_PGID=777001
bash -c 'sleep 30' & SPARE_VICTIM=$!
disown 2>/dev/null || true
# Present BOTH the still-live gate worker (LIVEWORKER, whose marker LIVEMARK reads live) and a fresh
# orphan as members of ONE process group. A group kill here would reap the healthy worker.
cat > "$T/ps-shared" <<EOF
#!/usr/bin/env bash
printf '%s 1 %s bash %s/scripts/herd/healthcheck.sh %s/x\n' "$SPARE_VICTIM" "$SHARED_PGID" "$MAINDIR" "$TREESDIR"
printf '%s 1 %s bash %s/scripts/herd/healthcheck.sh %s/y\n' "$LIVEWORKER" "$SHARED_PGID" "$MAINDIR" "$TREESDIR"
EOF
chmod +x "$T/ps-shared"
kill -0 "$LIVEWORKER" 2>/dev/null || fail "(11) precondition: the live gate worker must still be running"
PS_SAVED="$HERD_SWEEP_PS_CMD"; export HERD_SWEEP_PS_CMD="$T/ps-shared"
_sweep_kill_tree "$SPARE_VICTIM" "$SHARED_PGID" "$(_pid_starttime "$SPARE_VICTIM")"
export HERD_SWEEP_PS_CMD="$PS_SAVED"
grep -q '"reason":"spared-group"' "$JOURNAL_FILE" \
  || fail "(11) a group holding a live gate worker was GROUP-killed (would reap the healthy worker)"
kill -0 "$LIVEWORKER" 2>/dev/null || fail "(11) the live gate worker sharing the pgid was killed"
kill -0 "$SPARE_VICTIM" 2>/dev/null && fail "(11) the orphan itself must still be killed (single-pid)"
ok; echo "PASS (11) a shared pgid holding a spared process degrades to a single-pid kill"

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
# The two judgment worktrees (merged-dirty, closed-unique) survive every pass and are re-flagged each
# time, so `flagged` is the field that exposes accumulation: it must read 2 on EVERY pass, not 2,4,6…
: > "$JOURNAL_FILE"
sweep_run_safe_legs >/dev/null 2>&1 || true
sweep_run_safe_legs >/dev/null 2>&1 || true
LAST="$(grep '"event":"sweep_auto"' "$JOURNAL_FILE" | tail -1)"
printf '%s' "$LAST" | grep -q '"flagged":2' \
  || fail "(12) counters accumulated across runs (expected flagged=2 on every pass): $LAST"
printf '%s' "$LAST" | grep -q '"reaped":0' || fail "(12) reaped counter accumulated across runs: $LAST"
ok; echo "PASS (12) SWEEP_N_* counters reset per run (auto ticks never report a lifetime total)"

echo
echo "ALL PASS ($PASS checks)"
