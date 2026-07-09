#!/usr/bin/env bash
# sweep.sh — the engine behind `herd sweep`: ONE-COMMAND CONTROL-ROOM CLEANUP (HERD-191).
#
# A long-running control room accumulates DEBRIS that no single feature owns: worktrees whose PR
# merged hours ago, tabs whose slug is gone, inflight markers left by a killed worker, orphaned
# bats/healthcheck process trees reparented to init, and duplicate watchers. Each of those already
# has a REAPER somewhere in the engine — but each only fires on ITS OWN trigger (a merge tick, a
# watcher restart, a 15-tick interval). When the watcher itself dies, nothing fires at all, and the
# debris compounds until an operator hunts it down by hand.
#
# `herd sweep` is the ONE command that runs every reaper on demand. It COMPOSES the shipped helpers
# (it does not reimplement them) by sourcing agent-watch.sh in its LIB mode (AGENT_WATCH_LIB=1 —
# functions only, no tick loop, the same seam the hermetic tests use):
#
#   leg 1  worktrees   sha-anchored reap of merged/closed-PR worktrees (mirrors _startup_reap_sweep's
#                      proof obligation), plus unowned tmp/detached scratch trees → _reap_slug
#   leg 2  tabs        stale engine tabs, registry-allowlisted + workspace-scoped → _sweep_orphan_tabs
#                      / _sweep_stale_resolve_tabs (via the extracted _orphan_tab_ids detector)
#   leg 3  markers     dead-pid inflight markers → _sweep_gate_corpses (HERD-185's restart-safe sweep,
#                      including its pid-RECYCLING guard via _marker_live)
#   leg 4  processes   orphaned (ppid=1) bats/healthcheck trees + duplicate argv0-tagged watchers
#   leg 5  watcher     restart the watcher pane + verify it survives one tick (driven by bin/herd's
#                      cmd_sweep, which owns the pane helpers; never run from inside the watcher)
#
# SAFE vs JUDGMENT legs. A leg is SAFE when its precondition is a PROOF (a merged PR whose headRefOid
# equals the worktree's HEAD; a pid that is provably dead; a tab in the engine's own registry whose
# slug has no worktree and no open PR). A leg is JUDGMENT when acting could destroy work a human
# still wants: a worktree carrying REAL dirt, or a closed-PR branch carrying commits that exist
# nowhere else. Judgment findings are FLAGGED WITH EVIDENCE and NEVER deleted — not by `herd sweep`,
# not in --dry-run, not under SWEEP_AUTO=auto. The only cure for a flag is a human.
#
# TRIGGERS (SWEEP_AUTO=off|advise|auto, default advise). The watcher runs a CHEAP detection pass on
# its orphan-sweep cadence and renders one '🧹 sweep recommended: …' console row, journaling
# `sweep_advice` ONCE per distinct condition-set (a re-detected identical set is silent). Under
# `auto` it additionally runs the SAFE legs itself. Under `off` it is byte-inert: no scan, no row,
# no journal. Judgment legs stay advisory in every mode.
#
# DRY-RUN (`herd sweep --dry-run`) prints the FULL plan — every reap, close, marker, and kill it
# WOULD perform, plus every flag — and touches nothing. Every action, in every mode, is journaled.
#
# Idempotent + fail-soft throughout: a worktree already gone, a tab already closed, a pid already
# dead all no-op, so a second run is harmless. Fully offline-tolerant — an unreachable `gh` yields
# NO reaps (the sha anchor cannot be proven), never a blind delete.
#
# Sourced as a library (SWEEP_LIB=1) by agent-watch.sh for the trigger pass; executed directly by
# bin/herd's cmd_sweep for legs 1–4.
#
# Run:  bash scripts/herd/sweep.sh [--dry-run] [--auto]

_SWEEP_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── helper substrate ────────────────────────────────────────────────────────────────────────────
# Every primitive this file needs — _marker_live (pid + start-time recycling guard), _reap_slug,
# _orphan_tab_ids, _sweep_gate_corpses, journal_append, and the resolved MAIN/TREES/DEFAULT_BRANCH —
# already lives in agent-watch.sh. Source it in LIB mode when (and only when) those functions are
# not already in scope. Two callers, two paths, no duplication:
#   • bin/herd / a test executes this file  → _marker_live is undefined → source agent-watch.sh
#   • agent-watch.sh sources THIS file      → _marker_live is already defined → skip (no recursion)
# AGENT_WATCH_LIB is set UNEXPORTED so it can never leak into a child process (notably the watcher
# that leg 5 relaunches, which must come up as a real watcher, not a library).
if ! command -v _marker_live >/dev/null 2>&1; then
  # shellcheck disable=SC2034  # read by agent-watch.sh on the next line (its lib-mode guard)
  AGENT_WATCH_LIB=1
  # shellcheck source=/dev/null
  . "$_SWEEP_HERE/agent-watch.sh"
  unset AGENT_WATCH_LIB
fi

# ── tunables (deliberate constants, not config keys) ─────────────────────────────────────────────
# REGENERABLE DIRT: untracked paths a merged worktree may carry without blocking its reap. These are
# build/test/editor droppings that any checkout regenerates for free — refusing to reap over a stray
# .DS_Store or __pycache__ would make the sweep useless in practice (the #289 corpse incidents all
# had them). Matched per PATH SEGMENT, so `x/__pycache__/y.pyc` is regenerable. A MODIFIED, DELETED,
# STAGED, or RENAMED TRACKED file is NEVER regenerable, whatever its name: that is real work.
SWEEP_REGENERABLE_GLOBS='.DS_Store:*.log:*.pyc:*.pyo:*.tmp:__pycache__:.pytest_cache:.mypy_cache:.ruff_cache:.coverage:coverage:node_modules:.venv:venv:dist:build:target'

# Basenames that mark a DETACHED worktree as engine/agent scratch, wherever it lives. A detached
# worktree UNDER $TREES also qualifies. Anything else detached is left alone: `git worktree add
# --detach` is the documented way to A/B a change against base, and that tree is precious.
SWEEP_SCRATCH_GLOBS='tmp-*:*-tmp:tmp:scratch-*:herd-tmp-*:.tmp*'

# Command patterns for leg 4's orphan hunt: a bats runner or a healthcheck/test script.
SWEEP_ORPHAN_CMD_RE='(^|/| )(bats|healthcheck\.sh)( |$)|/tests/test-[A-Za-z0-9._-]*\.sh'

SWEEP_KILL_GRACE="${HERD_SWEEP_KILL_GRACE:-3}"   # seconds between SIGTERM and SIGKILL (test seam)

# The checkout `herd sweep` was invoked from, never a sweep target. Set by sweep_main; always DEFINED
# (empty) so the watcher's auto path — which never calls sweep_main — reads it safely under `set -u`
# without a ${:-} default (which the config-manifest ghost-key lint would read as an undeclared knob).
SWEEP_SELF=""

# ── plan accumulation ───────────────────────────────────────────────────────────────────────────
# Legs append one PLAN LINE per finding: "<verb>\t<what>\t<detail>". _sweep_emit prints it (the
# dry-run plan IS the same text the live run narrates) and counts it. Counters drive the summary.
SWEEP_N_REAP=0; SWEEP_N_FLAG=0; SWEEP_N_TAB=0; SWEEP_N_MARKER=0; SWEEP_N_PROC=0

# _sweep_reset_counters — zero the counters before a run. Load-bearing for the watcher's SWEEP_AUTO=auto
# path, which calls sweep_run_safe_legs on EVERY cadence tick inside ONE long-lived process: without
# this the counters accumulate for the life of the watcher and each `sweep_auto` journal line reports a
# running total instead of what that tick actually swept.
_sweep_reset_counters() {
  SWEEP_N_REAP=0; SWEEP_N_FLAG=0; SWEEP_N_TAB=0; SWEEP_N_MARKER=0; SWEEP_N_PROC=0
}

# _sweep_say <icon> <line> — one narration line, themed when the console palette is loaded.
_sweep_say() { printf '  %s %s\n' "$1" "$2"; }

# ── leg 1: worktrees ─────────────────────────────────────────────────────────────────────────────
# _sweep_worktree_rows — parse `git worktree list --porcelain` into "dir\x1fslug\x1fbranch\x1fdetached"
# rows, skipping the main checkout. Mirrors _startup_reap_sweep's parser, extended with the detached
# flag that leg 1's scratch-tree branch needs.
_sweep_worktree_rows() {
  local wt; wt="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null || true)"
  [ -n "$wt" ] || return 0
  WT="$wt" MAIN="$MAIN" python3 -c '
import os
MAIN = os.environ["MAIN"]
def emit(wt, branch, det):
    if wt and wt != MAIN:
        print("\x1f".join([wt, os.path.basename(wt), branch or "", "1" if det else "0"]))
wt = None; branch = None; det = False
for line in (os.environ.get("WT") or "").splitlines():
    if line.startswith("worktree "):
        emit(wt, branch, det); wt = line[9:]; branch = None; det = False
    elif line.startswith("branch "):
        branch = line[7:].replace("refs/heads/", "")
    elif line.strip() == "detached":
        det = True
emit(wt, branch, det)
' 2>/dev/null || true
}

# _sweep_classify_dirt <dir> — classify a worktree's working tree as one of:
#   clean                      — nothing to see
#   regenerable                — only untracked, regenerable droppings (safe to reap over)
#   dirty<TAB><evidence>       — real work present; evidence is "<n> path(s): a, b, c"
# The evidence string is what a FLAG row shows the operator, so it names the actual files.
_sweep_classify_dirt() {
  local dir="$1" porcelain
  porcelain="$(git -C "$dir" status --porcelain 2>/dev/null || true)"
  [ -n "$porcelain" ] || { printf 'clean'; return 0; }
  printf '%s\n' "$porcelain" | GLOBS="$SWEEP_REGENERABLE_GLOBS" python3 -c '
import os, sys, fnmatch
globs = [g for g in os.environ["GLOBS"].split(":") if g]
def regenerable(path):
    # Match per path SEGMENT so nested droppings (a/__pycache__/b.pyc) classify correctly.
    for seg in path.rstrip("/").split("/"):
        if any(fnmatch.fnmatch(seg, g) for g in globs):
            return True
    return False
real = []
for line in sys.stdin.read().splitlines():
    if len(line) < 4:
        continue
    xy, path = line[:2], line[3:]
    # A tracked file that is modified/staged/deleted/renamed is ALWAYS real work. Only an untracked
    # ("??") path can be excused as a regenerable dropping.
    if xy != "??" or not regenerable(path):
        real.append(path)
if not real:
    sys.stdout.write("regenerable")
else:
    shown = ", ".join(real[:3]) + (", …" if len(real) > 3 else "")
    sys.stdout.write("dirty\t%d path(s): %s" % (len(real), shown))
' 2>/dev/null || printf 'dirty\tunreadable status (assumed dirty)'
}

# _sweep_is_scratch <dir> <slug> — success iff a DETACHED worktree is engine/agent scratch: it lives
# under $TREES, or its basename matches a scratch glob. Deliberately narrow — an operator's detached
# A/B checkout elsewhere is never swept.
_sweep_is_scratch() {
  local dir="$1" slug="$2" g
  case "$dir/" in "$TREES"/*) return 0 ;; esac
  local IFS=':'
  for g in $SWEEP_SCRATCH_GLOBS; do
    # shellcheck disable=SC2254
    case "$slug" in $g) return 0 ;; esac
  done
  return 1
}

# _sweep_unique_commits <dir> — count commits on this worktree's HEAD that exist nowhere on the
# default branch (i.e. work a delete would destroy). Prints a count, or "?" when the base ref cannot
# be resolved — an unverifiable tree is FLAGGED, never reaped.
# DEFAULT_BRANCH is already a FULL ref ("origin/main", per templates/config.example) — never prefix it.
_sweep_unique_commits() {
  local dir="$1" base="${DEFAULT_BRANCH:-origin/main}" n
  git -C "$dir" rev-parse --verify --quiet "$base" >/dev/null 2>&1 || { printf '?'; return 0; }
  n="$(git -C "$dir" rev-list --count "$base..HEAD" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) printf '?' ;; *) printf '%s' "$n" ;; esac
}

# _sweep_registry_has_slug <slug> — success iff the tab registry records a tab for this slug (an
# "owned" scratch tree; leave it to its owner).
_sweep_registry_has_slug() {
  local reg="$TREES/.herd-tabs" slug="$1"
  [ -f "$reg" ] || return 1
  awk -v s="$slug" '{ lbl=$1; sub(/^review·/,"",lbl); sub(/^resolve·/,"",lbl); if (lbl==s) found=1 }
                    END { exit(found?0:1) }' "$reg" 2>/dev/null
}

# sweep_leg_worktrees <dry> — leg 1. For each feature worktree, PROVE a reap or FLAG the finding.
#
# The proof obligation is _startup_reap_sweep's, unchanged: a PR whose headRefOid EQUALS this
# worktree's current HEAD. Only that anchor distinguishes "the branch this tree built, and it
# landed" from "a reused slug with new commits". No anchor ⇒ no action, ever.
#
#   MERGED + anchored + (clean | regenerable-only)  → REAP   (safe)
#   MERGED + anchored + real dirt                   → FLAG   (judgment — uncommitted work)
#   CLOSED + anchored + 0 unique commits + clean    → REAP   (safe — abandoned, nothing to lose)
#   CLOSED + anchored + unique commits / dirt / "?" → FLAG   (judgment — work exists only here)
#   detached scratch  + clean + unowned             → REAP   (safe)
#   detached scratch  + dirt                        → FLAG   (judgment)
#   anything else (open PR, no anchor, gh down)     → silently skipped
sweep_leg_worktrees() {
  local dry="$1" dir slug branch det head st oid num dirt evidence uniq
  while IFS=$'\x1f' read -r dir slug branch det; do
    [ -n "${slug:-}" ] || continue
    [ -d "$dir" ] || continue
    # Never sweep the checkout we (or the watcher) are running from.
    [ "$dir" = "$SELF_WT" ] && continue
    [ "$dir" = "$SWEEP_SELF" ] && continue

    dirt="$(_sweep_classify_dirt "$dir")"
    evidence="${dirt#*$'\t'}"; [ "$evidence" = "$dirt" ] && evidence=""
    dirt="${dirt%%$'\t'*}"

    # ── detached scratch trees ──
    if [ "$det" = "1" ]; then
      _sweep_is_scratch "$dir" "$slug" || continue
      _sweep_registry_has_slug "$slug" && continue          # owned by a live tab → not ours to reap
      if [ "$dirt" = "dirty" ]; then
        _sweep_emit_flag "$slug" scratch-dirty "$evidence"
      else
        _sweep_emit_reap "$slug" "$dir" "" "" scratch-detached "$dry"
      fi
      continue
    fi

    # ── branch-backed feature trees: the sha anchor ──
    [ -n "${branch:-}" ] || continue
    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
    [ -n "$head" ] || continue
    IFS=$'\t' read -r st oid num <<EOF
$(_srs_gh_view "$branch")
EOF
    [ -n "${oid:-}" ] && [ "$oid" = "$head" ] || continue   # no sha anchor → never touch it
    case "${st:-}" in
      MERGED)
        if [ "$dirt" = "dirty" ]; then
          _sweep_emit_flag "$slug" merged-dirty "$evidence (PR #$num merged; commit or discard, then re-run)"
        else
          _sweep_emit_reap "$slug" "$dir" "$num" "$head" merged "$dry"
        fi
        ;;
      CLOSED)
        uniq="$(_sweep_unique_commits "$dir")"
        if [ "$uniq" = "?" ]; then
          _sweep_emit_flag "$slug" closed-unverifiable "cannot resolve ${DEFAULT_BRANCH:-origin/main} to prove no unique work (PR #$num closed)"
        elif [ "$uniq" != "0" ]; then
          _sweep_emit_flag "$slug" closed-unique-commits "$uniq commit(s) exist only here (PR #$num closed unmerged)"
        elif [ "$dirt" = "dirty" ]; then
          _sweep_emit_flag "$slug" closed-dirty "$evidence (PR #$num closed)"
        else
          _sweep_emit_reap "$slug" "$dir" "$num" "$head" closed "$dry"
        fi
        ;;
    esac
  done < <(_sweep_worktree_rows)
  return 0
}

# _sweep_emit_reap <slug> <dir> <pr> <sha> <reason> <dry> — narrate + (unless dry) perform the reap
# via the SHIPPED _reap_slug primitive (worktree remove, tracker-ref marker, step-holds, journal,
# tab teardown). Journaling of the `reap` event happens inside _reap_slug; the dry-run path journals
# nothing (it touches nothing) but still prints the exact line the live run would.
_sweep_emit_reap() {
  local slug="$1" dir="$2" pr="$3" sha="$4" reason="$5" dry="$6"
  SWEEP_N_REAP=$(( SWEEP_N_REAP + 1 ))
  _sweep_say "🌳" "reap worktree ${slug} (${reason}${pr:+ · PR #$pr})"
  [ -n "$dry" ] && return 0
  _reap_slug "$slug" "$dir" "$pr" "$sha" "sweep-$reason"
}

# _sweep_emit_flag <slug> <reason> <evidence> — a JUDGMENT finding. Printed loudly with its evidence
# and journaled, NEVER acted on, in every mode. This is the sweep's whole safety contract: anything
# it cannot prove disposable, it hands to a human with the receipts.
_sweep_emit_flag() {
  local slug="$1" reason="$2" evidence="$3"
  SWEEP_N_FLAG=$(( SWEEP_N_FLAG + 1 ))
  _sweep_say "🚩" "FLAG ${slug} — ${reason}: ${evidence}"
  journal_append sweep_flag slug "$slug" reason "$reason" evidence "$evidence"
}

# ── leg 2: stale tabs ────────────────────────────────────────────────────────────────────────────
# Composes the watcher's own tab reapers. _orphan_tab_ids is the AUTHORITATIVE detector (registry
# allowlist + workspace scope + self-tab exclusion + live-slug/open-PR check) — the dry-run plan and
# the live sweep therefore agree by construction. _sweep_stale_resolve_tabs adds the resolve·<slug>
# case, which needs a live-resolver-agent check the generic detector does not do.
sweep_leg_tabs() {
  local dry="$1" ids id n=0
  command -v herdr >/dev/null 2>&1 || return 0
  ids="$(_orphan_tab_ids 2>/dev/null || true)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    n=$(( n + 1 )); SWEEP_N_TAB=$(( SWEEP_N_TAB + 1 ))
    _sweep_say "🗂 " "close stale tab ${id}"
  done <<< "$ids"
  [ -n "$dry" ] && return 0
  # Act through the shipped sweeps (they journal `sweep_closed` and prune the registry row).
  [ "$n" -gt 0 ] && _sweep_orphan_tabs
  # _sweep_stale_resolve_tabs reads AGENTS_JSON (the agent roster) to spare a LIVE resolver; the
  # watcher's tick primes it, so a CLI sweep must prime it too or every resolve tab reads "no live
  # resolver". shellcheck cannot see the read across the sourced file.
  # shellcheck disable=SC2034
  AGENTS_JSON="$(herd_driver_agent_list_json 2>/dev/null || echo '{}')"
  _sweep_stale_resolve_tabs
  return 0
}

# ── leg 3: dead inflight markers ─────────────────────────────────────────────────────────────────
# sweep_dead_marker_keys — the CHEAP detector (filesystem + kill -0 + start-time), shared by the
# watcher's trigger pass and the CLI. A marker is DEAD when its worker's pid is gone or recycled
# (_marker_live, HERD-185) AND no finished result/dispatch file is waiting to be collected. A LIVE
# but past-deadline marker is NOT reported here: timing a running worker out is the watcher's job,
# not a cleanup command's.
sweep_dead_marker_keys() {
  local f base rest pr sha
  for f in "$TREES"/.review-inflight-* "$TREES"/.health-inflight-*; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    case "$base" in
      .review-inflight-*)
        rest="${base#.review-inflight-}"; pr="${rest%-*}"; sha="${rest##*-}"
        [ -n "$pr" ] && [ -n "$sha" ] || continue
        [ -f "$(_review_result_file "$pr" "$sha")" ] && continue ;;
      .health-inflight-*)
        rest="${base#.health-inflight-}"
        [ -n "$rest" ] || continue
        [ -f "$(_health_dispatch_file "$rest")" ] && continue ;;
      *) continue ;;
    esac
    _marker_live "$f" && continue
    printf '%s\n' "$base"
  done
}

# sweep_leg_markers <dry> — narrate every dead marker, then hand the actual reap to HERD-185's
# _sweep_gate_corpses, which additionally frees the concurrency slot, retires an orphaned reviewer
# pane, counts the review retry budget, and feeds the INFRA breaker. Reusing it (rather than `rm`-ing
# the markers here) is what keeps a CLI sweep and a watcher tick accounting-identical.
sweep_leg_markers() {
  local dry="$1" k n=0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    n=$(( n + 1 )); SWEEP_N_MARKER=$(( SWEEP_N_MARKER + 1 ))
    _sweep_say "🩻" "drop dead inflight marker ${k}"
  done < <(sweep_dead_marker_keys)
  [ -n "$dry" ] && return 0
  [ "$n" -gt 0 ] && _sweep_gate_corpses
  return 0
}

# ── leg 4: orphaned processes + duplicate watchers ───────────────────────────────────────────────
# _sweep_ps / _sweep_proc_cwd — the two OS probes, behind test seams so the unit test can plant a
# synthetic process table and cwd map with no real processes at all.
_sweep_ps() {
  if [ -n "${HERD_SWEEP_PS_CMD:-}" ]; then "$HERD_SWEEP_PS_CMD"; return 0; fi
  ps -eo pid=,ppid=,pgid=,command= 2>/dev/null || true
}
_sweep_proc_cwd() {
  if [ -n "${HERD_SWEEP_PROC_CWD_CMD:-}" ]; then "$HERD_SWEEP_PROC_CWD_CMD" "$1"; return 0; fi
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}

# _sweep_live_marker_pids — the pids owned by a LIVE inflight marker (review or health), one per line.
#
# CRITICAL EXEMPTION. The async gate workers (HERD-185) are BACKGROUNDED, so a watcher restart
# reparents a still-running healthcheck/review worker to init — it becomes ppid==1 while remaining
# perfectly alive, and its result WILL be collected by the next watcher tick (the marker is on disk;
# that is the whole point of restart-safe dispatch). Such a process looks exactly like an orphan to a
# naive ppid==1 scan. Killing it would destroy in-flight gate work and strand the PR behind a
# corpse — the precise failure HERD-185 set out to end. So leg 4 skips any pid a live marker owns,
# and leaves it to _sweep_gate_corpses, which reaps it only once it is provably dead or past deadline.
_sweep_live_marker_pids() {
  local f
  for f in "$TREES"/.review-inflight-* "$TREES"/.health-inflight-*; do
    [ -e "$f" ] || continue
    _marker_live "$f" || continue
    _marker_pid "$f"
  done
}

# _sweep_owns_path <path> — success iff <path> lies inside this project's main checkout or worktrees
# dir. Uses a PATH-BOUNDARY test ("$MAIN/" …), never a bare substring: `/src/herdkit` is a prefix of
# the sibling `/src/herdkit-trees`, so a substring match would attribute (and kill) another project's
# processes — issue #60's cross-project kill, in a new costume. Same trailing-slash discipline as
# herd-config.sh's foreign-cwd guard. An empty MAIN/TREES never matches.
_sweep_owns_path() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  [ -n "$MAIN" ]  && case "$p/" in "$MAIN"/*)  return 0 ;; esac
  [ -n "$TREES" ] && case "$p/" in "$TREES"/*) return 0 ;; esac
  return 1
}

# sweep_orphan_procs — emit "pid\tpgid\tcommand" for every ORPHANED (ppid==1) bats/healthcheck
# process tree ATTRIBUTED TO THIS PROJECT. Attribution is the whole safety story (issue #60: a
# careless pattern kill once reaped a sibling project's watcher), so a candidate must satisfy ALL of:
#   • ppid == 1                     — genuinely reparented to init; a child of a live runner is busy
#   • command matches a bats/healthcheck/test-script shape
#   • it is not us, not our process group, and not the live watcher
#   • it is NOT the worker of a live inflight marker (see _sweep_live_marker_pids)
#   • its command line names a path UNDER $MAIN/$TREES, or its cwd resolves under one of them
# A candidate we cannot attribute is DROPPED, never killed.
sweep_orphan_procs() {
  local pid ppid pgid cmd cwd tok mypgid wpid="" live owned
  mypgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
  [ -f "${HERD_WATCHER_LOCK:-/nonexistent}" ] && wpid="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
  live=" $(_sweep_live_marker_pids | tr '\n' ' ')"
  while read -r pid ppid pgid cmd; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$ppid" = "1" ] || continue
    [ "$pid" = "$$" ] && continue
    [ -n "$wpid" ] && [ "$pid" = "$wpid" ] && continue
    [ -n "$mypgid" ] && [ "$pgid" = "$mypgid" ] && continue
    case "$live" in *" $pid "*) continue ;; esac
    printf '%s' "$cmd" | grep -Eq "$SWEEP_ORPHAN_CMD_RE" || continue
    # Project attribution: some whitespace-separated token of the command line is a path we own …
    # (noglob: a command line legitimately contains `*`, which must never pathname-expand here)
    owned=""
    set -f
    for tok in $cmd; do
      _sweep_owns_path "$tok" && { owned=1; break; }
    done
    set +f
    # … else fall back to the process's cwd. Neither ⇒ not ours ⇒ never touched.
    if [ -z "$owned" ]; then
      cwd="$(_sweep_proc_cwd "$pid")"
      _sweep_owns_path "$cwd" || continue
    fi
    printf '%s\t%s\t%s\n' "$pid" "$pgid" "$cmd"
  done < <(_sweep_ps)
}

# sweep_stray_watchers — pids of argv0-tagged watchers for THIS workspace that are NOT the lockfile's
# watcher: duplicates/zombies left by a crashed reload. Detection only — the KILL is delegated to
# bin/herd's _stop_project_watcher during leg 5, so there is exactly ONE watcher-killing code path in
# the engine (its SIGTERM-poll-SIGKILL-abort discipline, not a second copy here).
sweep_stray_watchers() {
  command -v pgrep >/dev/null 2>&1 || return 0
  local marker="${HERD_WATCH_ARGV0:-}" pid argv0 wpid=""
  [ -n "$marker" ] || return 0
  [ -f "${HERD_WATCHER_LOCK:-/nonexistent}" ] && wpid="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ -n "$wpid" ] && [ "$pid" = "$wpid" ] && continue
    argv0="$(ps -o command= -p "$pid" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    [ "$argv0" = "$marker" ] || continue
    printf '%s\n' "$pid"
  done < <(pgrep -f "$marker" 2>/dev/null || true)
}

# _sweep_pgid_of <pid> — the process group id of <pid> (via the same seam as the process table, so a
# test's synthetic table answers consistently). Empty when the pid is gone.
_sweep_pgid_of() {
  local p="${1:-}"; [ -n "$p" ] || return 0
  if [ -n "${HERD_SWEEP_PS_CMD:-}" ]; then
    _sweep_ps | awk -v want="$p" '$1==want { print $3; exit }'
    return 0
  fi
  ps -o pgid= -p "$p" 2>/dev/null | tr -d ' '
}

# _sweep_spare_pgids — process groups a GROUP kill must never signal, as " g1 g2 … " for substring
# matching. Observed live: several orphans legitimately SHARE one pgid, so `kill -TERM -<pgid>` can
# reach far beyond the pid that was listed. If that group also contains this process, the live
# watcher, or the worker of a live inflight marker (a backgrounded gate worker reparented to init
# still shares its launcher's group), the group kill would take a healthy process down with the
# corpses. For those groups we fall back to signalling the single orphan pid.
_sweep_spare_pgids() {
  local out p g
  out=" $(_sweep_pgid_of $$) "
  if [ -f "${HERD_WATCHER_LOCK:-/nonexistent}" ]; then
    p="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
    g="$(_sweep_pgid_of "$p")"; [ -n "$g" ] && out="$out$g "
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    g="$(_sweep_pgid_of "$p")"; [ -n "$g" ] && out="$out$g "
  done < <(_sweep_live_marker_pids)
  printf '%s' "$out"
}

# _sweep_kill_tree <pid> <pgid> <starttime> — kill an orphan, PID-RECYCLING-GUARDED. The start-time
# token was captured when the process was LISTED; if it no longer matches, that pid number now
# belongs to an unrelated process and we must not signal it. Signals the whole PROCESS GROUP (a bats
# run is a tree; TERMing only the leader strands its children) — except for a group we must spare
# (see _sweep_spare_pgids), and never group 0/1. SIGTERM, grace, then SIGKILL. Idempotent: a pid a
# previous group kill already reaped simply fails the liveness check and returns.
_sweep_kill_tree() {
  local pid="$1" pgid="$2" st="$3" cur target waited=0 spare
  cur="$(_pid_starttime "$pid")"
  if [ -n "$st" ] && [ -n "$cur" ] && [ "$cur" != "$st" ]; then
    journal_append sweep_proc_skip pid "$pid" reason pid-recycled
    return 0
  fi
  kill -0 "$pid" 2>/dev/null || return 0
  spare="$(_sweep_spare_pgids)"
  target="$pid"
  case "$pgid" in
    ''|0|1|*[!0-9]*) : ;;
    *) case "$spare" in
         *" $pgid "*) journal_append sweep_proc_pidonly pid "$pid" pgid "$pgid" reason spared-group ;;
         *) target="-$pgid" ;;
       esac ;;
  esac
  kill -TERM "$target" 2>/dev/null || true
  while [ "$waited" -lt "$SWEEP_KILL_GRACE" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1; waited=$(( waited + 1 ))
  done
  kill -KILL "$target" 2>/dev/null || true
  return 0
}

# sweep_leg_procs <dry> — leg 4. LISTS every orphan first (the plan), then kills. Listing before
# acting is deliberate: an operator reading the console must see what is about to die BEFORE it does,
# and a dry-run must print exactly the same list.
sweep_leg_procs() {
  local dry="$1" pid pgid cmd st rows strays
  rows="$(sweep_orphan_procs)"
  strays="$(sweep_stray_watchers)"

  while IFS=$'\t' read -r pid pgid cmd; do
    [ -n "${pid:-}" ] || continue
    SWEEP_N_PROC=$(( SWEEP_N_PROC + 1 ))
    _sweep_say "🧟" "kill orphan pid ${pid} (pgid ${pgid}) — ${cmd:0:70}"
  done <<< "$rows"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    _sweep_say "👻" "duplicate watcher pid ${pid} — stopped by the leg-5 watcher restart"
  done <<< "$strays"

  [ -n "$dry" ] && return 0
  while IFS=$'\t' read -r pid pgid cmd; do
    [ -n "${pid:-}" ] || continue
    st="$(_pid_starttime "$pid")"
    _sweep_kill_tree "$pid" "$pgid" "$st"
    journal_append sweep_proc pid "$pid" pgid "$pgid" cmd "${cmd:0:120}"
  done <<< "$rows"
  return 0
}

# ── the trigger pass (SWEEP_AUTO) ────────────────────────────────────────────────────────────────
# sweep_auto_mode — the normalized lever: off | advise | auto. Anything unrecognized reads as advise
# (the ship default), so a typo degrades to "tell me", never to "act on my control room".
sweep_auto_mode() {
  case "$(printf '%s' "${SWEEP_AUTO:-advise}" | tr '[:upper:]' '[:lower:]')" in
    off|0|false|no)  printf 'off' ;;
    auto|on|1|true)  printf 'auto' ;;
    *)               printf 'advise' ;;
  esac
}

# sweep_cheap_tab_count — the trigger pass's stale-tab estimate. Deliberately CHEAP: a registry row
# whose slug has no worktree directory. NO herdr RPC, NO `gh pr list` — the watcher must not pay a
# network round-trip to decide whether to print an advisory line. It can therefore over-count (a slug
# whose worktree was reaped but whose PR is still open); the authoritative check is `herd sweep`
# itself, which runs the full _orphan_tab_ids detector before closing anything.
sweep_cheap_tab_count() {
  local reg="$TREES/.herd-tabs" n=0 lbl slug rest
  [ -f "$reg" ] || { printf '0'; return 0; }
  while read -r lbl rest; do
    [ -n "${lbl:-}" ] || continue
    slug="${lbl#review·}"; slug="${slug#resolve·}"
    [ -n "$slug" ] || continue
    [ -d "$TREES/$slug" ] && continue
    n=$(( n + 1 ))
  done < "$reg"
  printf '%s' "$n"
}

# sweep_scan_counts — one line "<tabs> <markers> <procs>": the whole trigger-pass signal. Cheap
# enough for the watcher's orphan-sweep cadence (filesystem + kill -0 + one `ps -e`), and the exact
# quantities the '🧹 sweep recommended' row renders.
sweep_scan_counts() {
  local tabs markers procs
  tabs="$(sweep_cheap_tab_count)"
  markers="$(sweep_dead_marker_keys | grep -c . || true)"
  procs="$(sweep_orphan_procs | grep -c . || true)"
  printf '%s %s %s' "${tabs:-0}" "${markers:-0}" "${procs:-0}"
}

# sweep_advice_line <tabs> <markers> <procs> — the console text, or EMPTY when there is nothing to
# recommend. Only non-zero conditions appear, joined by '·', so the row never pads itself with "0
# orphan procs" noise.
sweep_advice_line() {
  local tabs="$1" markers="$2" procs="$3" segs=""
  _seg() { [ "$1" -gt 0 ] 2>/dev/null || return 0; [ -n "$segs" ] && segs="$segs · "; segs="$segs$1 $2"; }
  _seg "$tabs"    "stale tab$([ "$tabs" = 1 ] || printf s)"
  _seg "$markers" "dead marker$([ "$markers" = 1 ] || printf s)"
  _seg "$procs"   "orphan proc$([ "$procs" = 1 ] || printf s)"
  unset -f _seg
  [ -n "$segs" ] || return 0
  printf '🧹 sweep recommended: %s' "$segs"
}

# sweep_journal_advice_once <tabs> <markers> <procs> — journal `sweep_advice` ONCE per distinct
# CONDITION-SET. The signature of the current set is memoized on disk; an unchanged set (the same
# mess still sitting there tick after tick) is silent, while a set that GROWS or SHRINKS to a new
# shape journals again. A fully-clean set clears the memo, so the next mess is reported afresh.
sweep_journal_advice_once() {
  local tabs="$1" markers="$2" procs="$3"
  local memo="$TREES/.sweep-advice" sig="t=$tabs m=$markers p=$procs" prev=""
  if [ "$tabs" = 0 ] && [ "$markers" = 0 ] && [ "$procs" = 0 ]; then
    rm -f "$memo" 2>/dev/null || true
    return 0
  fi
  [ -f "$memo" ] && prev="$(cat "$memo" 2>/dev/null || true)"
  [ "$prev" = "$sig" ] && return 0
  printf '%s\n' "$sig" > "$memo" 2>/dev/null || true
  journal_append sweep_advice tabs "$tabs" markers "$markers" procs "$procs"
}

# sweep_run_safe_legs — the SAFE subset, for SWEEP_AUTO=auto (and reused by the CLI). Markers,
# orphan processes, PROVABLY-disposable worktrees, and registry tabs. Judgment findings are flagged
# by sweep_leg_worktrees and, by construction, never acted on — so `auto` cannot destroy work.
# NEVER restarts the watcher (leg 5): a watcher must not restart itself mid-tick.
#
# LEG ORDER IS LOAD-BEARING: worktrees are reaped BEFORE tabs. A tab is "stale" only when its slug
# has no worktree and no open PR, so sweeping tabs first would see every about-to-be-reaped slug as
# still LIVE and leave its tab behind for a whole cadence. Reaping first frees the slug, and the tab
# leg then recognizes (and prunes the registry row for) any tab the reap's teardown missed.
sweep_run_safe_legs() {
  _sweep_reset_counters
  sweep_leg_markers ""
  sweep_leg_procs ""
  sweep_leg_worktrees ""
  sweep_leg_tabs ""
  journal_append sweep_auto reaped "$SWEEP_N_REAP" flagged "$SWEEP_N_FLAG" \
    tabs "$SWEEP_N_TAB" markers "$SWEEP_N_MARKER" procs "$SWEEP_N_PROC"
  return 0
}

# ── CLI entry point (legs 1–4; leg 5 lives in bin/herd's cmd_sweep) ──────────────────────────────
sweep_main() {
  local dry="" mode="run"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; mode="dry-run" ;;
      --auto)    mode="auto" ;;
      *) printf 'usage: sweep.sh [--dry-run] [--auto]\n' >&2; return 2 ;;
    esac
    shift
  done

  # The checkout `herd sweep` was invoked from is never a sweep target.
  SWEEP_SELF="$(git rev-parse --show-toplevel 2>/dev/null || true)"

  _sweep_reset_counters
  journal_append sweep_start mode "$mode"
  printf '🧹 herd sweep — %s · workspace=%s\n\n' \
    "$([ -n "$dry" ] && printf 'DRY RUN (nothing will be touched)' || printf 'live')" \
    "${WORKSPACE_NAME:-?}"

  # Worktrees before tabs — see sweep_run_safe_legs on why the order is load-bearing.
  sweep_leg_markers   "$dry"
  sweep_leg_procs     "$dry"
  sweep_leg_worktrees "$dry"
  sweep_leg_tabs      "$dry"

  local total=$(( SWEEP_N_REAP + SWEEP_N_TAB + SWEEP_N_MARKER + SWEEP_N_PROC ))
  printf '\n'
  if [ "$total" -eq 0 ] && [ "$SWEEP_N_FLAG" -eq 0 ]; then
    printf '  ✅ control room clean — nothing to sweep\n'
  else
    printf '  %s %d worktree(s) · %d tab(s) · %d marker(s) · %d process(es)%s\n' \
      "$([ -n "$dry" ] && printf 'would sweep:' || printf 'swept:')" \
      "$SWEEP_N_REAP" "$SWEEP_N_TAB" "$SWEEP_N_MARKER" "$SWEEP_N_PROC" \
      "$([ "$SWEEP_N_FLAG" -gt 0 ] && printf ' · %d FLAGGED for you' "$SWEEP_N_FLAG")"
    [ "$SWEEP_N_FLAG" -gt 0 ] && printf '  🚩 flagged items are NEVER auto-deleted — resolve them by hand\n'
  fi

  journal_append sweep_done mode "$mode" reaped "$SWEEP_N_REAP" flagged "$SWEEP_N_FLAG" \
    tabs "$SWEEP_N_TAB" markers "$SWEEP_N_MARKER" procs "$SWEEP_N_PROC"
  return 0
}

# Library mode: agent-watch.sh (and the unit test) source this file for the helpers above.
if [ "${SWEEP_LIB:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi
# Guard against being sourced by agent-watch.sh without SWEEP_LIB (belt and braces: never run the
# CLI from inside the watcher).
case "${BASH_SOURCE[0]}" in "$0") sweep_main "$@" ;; esac
