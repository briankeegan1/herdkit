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
#                      proof obligation), plus unowned tmp/detached scratch trees that carry no unique
#                      commits → _reap_slug
#   leg 2  tabs        stale engine tabs, registry-allowlisted + workspace-scoped → _sweep_orphan_tabs
#                      / _sweep_stale_resolve_tabs (via the extracted _orphan_tab_ids detector)
#   leg 3  markers     dead-pid inflight markers AND past-deadline live workers (both narrated) →
#                      _sweep_gate_corpses (HERD-185's restart-safe sweep, under an atomic claim so a
#                      CLI sweep and the watcher tick never double-charge the retry ledger / breaker)
#   leg 4  processes   orphaned (ppid=1) bats/healthcheck trees (pgid + start-time captured at LISTING,
#                      re-verified immediately before the signal) + duplicate argv0-tagged watchers
#   leg 5  watcher     restart the watcher pane + verify it survives one tick (driven by bin/herd's
#                      cmd_sweep, which owns the pane helpers; never run from inside the watcher)
#
# SAFE vs JUDGMENT legs. A leg is SAFE when its precondition is a PROOF (a merged PR whose headRefOid
# equals the worktree's HEAD; a pid that is provably dead; a tab in the engine's own registry whose
# slug has no worktree and no open PR). A leg is JUDGMENT when acting could destroy work a human
# still wants: a worktree carrying REAL dirt, or ANY tree — a closed-PR branch or a DETACHED scratch
# HEAD — carrying commits that exist nowhere else. Judgment findings are FLAGGED WITH EVIDENCE and
# NEVER deleted — not by `herd sweep`, not in --dry-run, not under SWEEP_AUTO=auto. The only cure for
# a flag is a human.
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
# Run:  bash scripts/herd/sweep.sh [--dry-run] [--no-restart] [--auto]

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

# The shared regenerable-derived-files list (HERD-214). Idempotent guard inside, so sourcing it here
# is free when agent-watch.sh (above) already pulled it in.
# shellcheck source=/dev/null
. "$_SWEEP_HERE/derived-files.sh"

# The durable tracker-create retry queue (HERD-267). Leg 6 narrates its rows and its own findings ride
# the same queue's enqueue primitive. Pure library; inert while CREATE_SELFHEAL=off.
# shellcheck source=/dev/null
. "$_SWEEP_HERE/create-retry.sh"

# The shared watcher-identity check (HERD-266): watcher_list_mains + the exemption clauses that tell a
# duplicate watcher apart from the canonical watcher's own argv0-inherited forks. Idempotent guard
# inside. `herd status` (bin/herd) and leg 4 below now read the SAME answer from the SAME code.
# shellcheck source=/dev/null
. "$_SWEEP_HERE/watcher-exempt.sh"

# ── tunables (deliberate constants, not config keys) ─────────────────────────────────────────────
# REGENERABLE DIRT: untracked paths a merged worktree may carry without blocking its reap. These are
# build/test/editor droppings that any checkout regenerates for free — refusing to reap over a stray
# .DS_Store or __pycache__ would make the sweep useless in practice (the #289 corpse incidents all
# had them). Matched per PATH SEGMENT, so `x/__pycache__/y.pyc` is regenerable. A MODIFIED, DELETED,
# STAGED, or RENAMED TRACKED file is NEVER regenerable, whatever its name: that is real work — with
# ONE exception, the shared regenerable-derived-files list from derived-files.sh (HERD-214). Those
# paths (the rendered coordinator skill, .herd/config.local) are rewritten from committed inputs by
# every init/update/reload/render, so they are regenerable in ANY status — including tracked-and-
# modified, which is exactly how they appear in a worktree cut before the untracking migration.
SWEEP_REGENERABLE_GLOBS='.DS_Store:*.log:*.pyc:*.pyo:*.tmp:__pycache__:.pytest_cache:.mypy_cache:.ruff_cache:.coverage:coverage:node_modules:.venv:venv:dist:build:target'

# Basenames that mark a DETACHED worktree as engine/agent scratch, wherever it lives. A detached
# worktree UNDER $TREES also qualifies. Anything else detached is left alone: `git worktree add
# --detach` is the documented way to A/B a change against base, and that tree is precious. Even a
# MATCHING scratch tree is only reaped when it carries zero unique commits (see sweep_leg_worktrees).
SWEEP_SCRATCH_GLOBS='tmp-*:*-tmp:tmp:scratch-*:herd-tmp-*:.tmp*'

# Command patterns for leg 4's orphan hunt: a bats runner or a healthcheck/test script.
SWEEP_ORPHAN_CMD_RE='(^|/| )(bats|healthcheck\.sh)( |$)|/tests/test-[A-Za-z0-9._-]*\.sh'

SWEEP_KILL_GRACE="${HERD_SWEEP_KILL_GRACE:-3}"   # seconds between SIGTERM and SIGKILL (test seam)

# The checkout `herd sweep` was invoked from, never a sweep target. Set by sweep_main; always DEFINED
# (empty) so the watcher's auto path — which never calls sweep_main — reads it safely under `set -u`
# without a ${:-} default (which the config-manifest ghost-key lint would read as an undeclared knob).
SWEEP_SELF=""

# Whether LEG 5 (the watcher pane restart, owned by bin/herd's cmd_sweep) will actually run after
# legs 1-4. Leg 5 is what STOPS the duplicate watchers leg 4 merely lists — so the narration for a
# stray must not claim it was handled when --dry-run / --no-restart, or the watcher's own SWEEP_AUTO
# path, means no restart follows. 0 = no leg 5 (the safe default for every non-CLI caller).
SWEEP_LEG5=0

# ── plan accumulation ───────────────────────────────────────────────────────────────────────────
# Legs append one PLAN LINE per finding: "<verb>\t<what>\t<detail>". _sweep_emit prints it (the
# dry-run plan IS the same text the live run narrates) and counts it. Counters drive the summary.
SWEEP_N_REAP=0; SWEEP_N_FLAG=0; SWEEP_N_TAB=0; SWEEP_N_MARKER=0; SWEEP_N_PROC=0
# Leg 6 (HERD-267) counts merged PRs whose tracker item never got created. Deliberately EXCLUDED from
# the swept total and from sweep_swept_total: a relink is an ADVISORY enqueue, not a reap, and folding
# it into the total would make the watcher's auto path read "progress" on a tick that deleted nothing.
SWEEP_N_LINK=0

# _sweep_reset_counters — zero the counters before a run. Load-bearing for the watcher's SWEEP_AUTO=auto
# path, which calls sweep_run_safe_legs on EVERY cadence tick inside ONE long-lived process: without
# this the counters accumulate for the life of the watcher and each `sweep_auto` journal line reports a
# running total instead of what that tick actually swept.
_sweep_reset_counters() {
  SWEEP_N_REAP=0; SWEEP_N_FLAG=0; SWEEP_N_TAB=0; SWEEP_N_MARKER=0; SWEEP_N_PROC=0; SWEEP_N_LINK=0
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
  printf '%s\n' "$porcelain" | GLOBS="$SWEEP_REGENERABLE_GLOBS" DERIVED="$(herd_derived_paths | tr '\n' ':')" python3 -c '
import os, sys, fnmatch
globs = [g for g in os.environ["GLOBS"].split(":") if g]
derived = {p for p in os.environ.get("DERIVED", "").split(":") if p}
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
    # A DERIVED file (the rendered coordinator skill, .herd/config.local) is regenerable whatever its
    # status: the engine rewrites it from the template + config, so no state of it is real work.
    if path in derived:
        continue
    # Otherwise a tracked file that is modified/staged/deleted/renamed is ALWAYS real work. Only an
    # untracked ("??") path can be excused as a regenerable dropping.
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

# _sweep_dir_in_use <dir> — success iff some live process has <dir> (or anything under it) open,
# most importantly as its CWD. A detached scratch tree at origin/main is clean and carries no unique
# commits, so nothing is LOST by reaping it — but a human or agent may be sitting in it (the A/B
# checkout this project's own builder guidance recommends), and pulling the directory out from under
# them is hostile. The .herd-tabs registry only spares trees that own a TAB, which such a tree does not.
# Seam: HERD_SWEEP_DIR_INUSE_CMD (test stub). Without lsof we cannot check, and we PROCEED — the
# data-safety guarantee rests on the unique-commit proof, not on this occupancy courtesy check.
_sweep_dir_in_use() {
  local dir="${1:-}"; [ -n "$dir" ] || return 1
  if [ -n "${HERD_SWEEP_DIR_INUSE_CMD:-}" ]; then "$HERD_SWEEP_DIR_INUSE_CMD" "$dir"; return $?; fi
  command -v lsof >/dev/null 2>&1 || return 1
  [ -n "$(lsof -t +D "$dir" 2>/dev/null | head -1)" ]  # pipe-ok: head in a command or process substitution; pipeline status not gated
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
    # A detached tree carries the SAME proof obligation as the CLOSED branch-backed path, and then
    # some: its commits are reachable from NO branch ref, so `git worktree remove --force` (which also
    # deletes .git/worktrees/<name>/ and with it that HEAD's reflog) destroys them UNRECOVERABLY. A
    # committed-but-unpushed detached HEAD reads `clean` to `git status --porcelain`, so a dirt check
    # alone would sail straight into the reap — and this is exactly the shape of this project's own
    # documented A/B practice (`git worktree add --detach HEAD` under $WORKTREES_DIR). So: reap only
    # when the tree is clean-or-regenerable AND carries ZERO unique commits; flag everything else.
    if [ "$det" = "1" ]; then
      _sweep_is_scratch "$dir" "$slug" || continue
      _sweep_registry_has_slug "$slug" && continue          # owned by a live tab → not ours to reap
      uniq="$(_sweep_unique_commits "$dir")"
      if [ "$dirt" = "dirty" ]; then
        _sweep_emit_flag "$slug" scratch-dirty "$evidence"
      elif _sweep_dir_in_use "$dir"; then
        _sweep_emit_flag "$slug" scratch-in-use "a live process holds this directory open (cwd or file) — reaping it would pull the checkout out from under its user"
      elif [ "$uniq" = "?" ]; then
        _sweep_emit_flag "$slug" scratch-unverifiable "cannot resolve ${DEFAULT_BRANCH:-origin/main} to prove no unique work in this detached tree"
      elif [ "$uniq" != "0" ]; then
        _sweep_emit_flag "$slug" scratch-unique-commits "$uniq commit(s) exist only here, on a DETACHED HEAD reachable from no branch — removing the worktree would destroy them"
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
  local dry="$1" ids id n=0 rslug rtab
  command -v herdr >/dev/null 2>&1 || return 0
  # _sweep_stale_resolve_tabs / _stale_resolve_tab_ids read AGENTS_JSON (the agent roster) to spare a
  # LIVE resolver; the watcher's tick primes it, so a CLI sweep must prime it too or every resolve tab
  # reads "no live resolver". Primed BEFORE detection so the plan and the action agree.
  # shellcheck disable=SC2034
  AGENTS_JSON="$(herd_driver_agent_list_json 2>/dev/null || echo '{}')"

  ids="$(_orphan_tab_ids 2>/dev/null || true)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    n=$(( n + 1 )); SWEEP_N_TAB=$(( SWEEP_N_TAB + 1 ))
    _sweep_say "🗂 " "close stale tab ${id}"
  done <<< "$ids"
  # Stale resolve·<slug> tabs are closed by the same leg — narrate + count them, or they would be
  # invisible in both the plan and SWEEP_N_TAB while still being closed. DEDUPE against the orphan
  # list: a resolve tab whose slug is entirely dead is ALSO an orphan-tab candidate, and
  # _sweep_orphan_tabs closes it first; counting it in both detectors would double-report one tab.
  while IFS=$'\t' read -r rslug rtab; do
    [ -n "${rtab:-}" ] || continue
    case "$(printf '%s\n' "$ids")" in *"$rtab"*) continue ;; esac
    SWEEP_N_TAB=$(( SWEEP_N_TAB + 1 ))
    _sweep_say "🗂 " "close stale resolve tab ${rtab} (resolve·${rslug})"
  done <<< "$(_stale_resolve_tab_ids 2>/dev/null || true)"

  [ -n "$dry" ] && return 0
  # Act through the shipped sweeps (they journal `sweep_closed` / `reap_resolve_tab` and prune the
  # closed tab's registry row). Hand the orphan ids we already computed back so those round-trips
  # happen ONCE. _sweep_orphan_tabs is invoked UNCONDITIONALLY — even with zero orphan candidates it
  # runs _herd_tabs_prune_orphans first (HERD-215), self-healing registry rows whose tab was closed
  # outside the sweep so the stale-tab tally stops counting them forever.
  _sweep_orphan_tabs "$ids"
  _sweep_stale_resolve_tabs
  return 0
}

# ── leg 3: dead inflight markers ─────────────────────────────────────────────────────────────────
# sweep_dead_marker_keys — the CHEAP detector (filesystem + kill -0 + start-time), shared by the
# watcher's trigger pass and the CLI. A marker is DEAD when its worker's pid is gone or recycled
# (_marker_live, HERD-185) AND no finished result/dispatch file is waiting to be collected.
# LIVE-but-past-deadline markers are reported separately by sweep_timedout_marker_keys — the action
# (_sweep_gate_corpses) reaps BOTH, so the plan must show both or `herd sweep` would perform a
# destructive SIGTERM that never appeared in its narration or in --dry-run.
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

# sweep_timedout_marker_keys — markers whose worker is still LIVE but whose age exceeds its family's
# timeout. _sweep_gate_corpses SIGTERMs these, so they belong in the plan: a `herd sweep` that prints
# only dead markers while silently killing a running (merely slow) reviewer or healthcheck would be
# lying about what it does. Mirrors the family timeouts + the never-TERM-the-watcher-itself guard.
sweep_timedout_marker_keys() {
  local f base rest pr sha age pid timeout
  for f in "$TREES"/.review-inflight-* "$TREES"/.health-inflight-*; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    case "$base" in
      .review-inflight-*)
        rest="${base#.review-inflight-}"; pr="${rest%-*}"; sha="${rest##*-}"
        [ -n "$pr" ] && [ -n "$sha" ] || continue
        [ -f "$(_review_result_file "$pr" "$sha")" ] && continue
        timeout="${REVIEW_INFLIGHT_TIMEOUT:-1800}" ;;
      .health-inflight-*)
        rest="${base#.health-inflight-}"
        [ -n "$rest" ] || continue
        [ -f "$(_health_dispatch_file "$rest")" ] && continue
        timeout="${HEALTH_INFLIGHT_TIMEOUT:-1800}" ;;
      *) continue ;;
    esac
    _marker_live "$f" || continue                     # dead → the other detector owns it
    age="$(_marker_age "$f")"
    case "$age" in ''|-1|*[!0-9]*) continue ;; esac   # no deadline recorded → runs forever
    [ "$age" -lt "$timeout" ] 2>/dev/null && continue
    pid="$(_marker_pid "$f")"
    [ "$pid" = "$$" ] && continue                     # never TERM ourselves
    printf '%s\t%s\n' "$base" "$age"
  done
}

# sweep_leg_markers <dry> — narrate every dead marker, then hand the actual reap to HERD-185's
# _sweep_gate_corpses, which additionally frees the concurrency slot, retires an orphaned reviewer
# pane, counts the review retry budget, and feeds the INFRA breaker. Reusing it (rather than `rm`-ing
# the markers here) is what keeps a CLI sweep and a watcher tick accounting-identical.
sweep_leg_markers() {
  local dry="$1" k age n=0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    n=$(( n + 1 )); SWEEP_N_MARKER=$(( SWEEP_N_MARKER + 1 ))
    _sweep_say "🩻" "drop dead inflight marker ${k}"
  done < <(sweep_dead_marker_keys)
  # Past-deadline LIVE workers are SIGTERMed by the same action — narrate them (and count them) too.
  while IFS=$'\t' read -r k age; do
    [ -n "$k" ] || continue
    n=$(( n + 1 )); SWEEP_N_MARKER=$(( SWEEP_N_MARKER + 1 ))
    _sweep_say "⏱ " "SIGTERM past-deadline worker for ${k} (running ${age}s) + drop its marker"
  done < <(sweep_timedout_marker_keys)
  [ -n "$dry" ] && return 0
  [ "$n" -gt 0 ] && _sweep_gate_corpses
  return 0
}

# ── leg 4: orphaned processes + duplicate watchers ───────────────────────────────────────────────
# _sweep_ps / _sweep_proc_cwd — the two OS probes, behind test seams so the unit test can plant a
# synthetic process table and cwd map with no real processes at all. _sweep_ps is the historical name
# for watcher-exempt.sh's watcher_ps_table (same $HERD_SWEEP_PS_CMD seam, one implementation): the
# duplicate-watcher check reads the table through it from bin/herd too, so a planted table answers
# every seat identically.
_sweep_ps() { watcher_ps_table; }
_sweep_proc_cwd() {
  if [ -n "${HERD_SWEEP_PROC_CWD_CMD:-}" ]; then "$HERD_SWEEP_PROC_CWD_CMD" "$1"; return 0; fi
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1  # pipe-ok: head in a command or process substitution; pipeline status not gated
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
# HERD-237: .spawn-inflight-* joins the two gate families. The tick now forks its builder-lane and
# resolver dispatches too, and a lane reparented to init by a watcher death is a live worker holding a
# claimed spawn intent — not an orphan. Killing it strands the claim behind a lane that never lands.
_sweep_live_marker_pids() { watcher_marker_pids; }

# _sweep_sess_of <pid> — the SESSION id of <pid>, via the same seam discipline as the process table so
# a test can inject sessions deterministically (HERD_SWEEP_SESS_CMD). `ps -o sess=` is NOT portable
# for this: on macOS it prints an opaque session-structure address (often 0), not the leader pid, so it
# cannot be compared against the leader pid the python worker records. `os.getsid` returns the real
# session-leader pid on both macOS and Linux, and it is exactly what live_runtime.py:_pid_session writes
# — so the marker's recorded session and a candidate's computed session are the SAME kind of token and
# compare cleanly. Empty when the pid is gone / python is absent (fail-soft: a caller then skips the
# session exemption for that candidate rather than treating an empty token as a match).
_sweep_sess_of() {
  local p="${1:-}"; [ -n "$p" ] || return 0
  if [ -n "${HERD_SWEEP_SESS_CMD:-}" ]; then "$HERD_SWEEP_SESS_CMD" "$p"; return 0; fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys
try: print(os.getsid(int(sys.argv[1])))
except Exception: pass' "$p" 2>/dev/null
    return 0
  fi
  return 0
}

# _sweep_live_marker_sessions — the SESSION ids owned by LIVE inflight markers, one per line. Companion
# to _sweep_live_marker_pids for the HERD-348 exemption: the python gate worker detaches into its OWN
# session (start_new_session=True) and its bats subtree runs in a DIFFERENT process group within that
# session (GNU `timeout` re-groups its child), so the recorded marker PID never names the pid the sweep
# is about to kill — but the SESSION does. Two sources, unioned (dedup is unnecessary for substring
# matching):
#   • the session the python worker RECORDS in the marker (leg b, live_runtime.py:_marker_write line 4),
#     read straight back through watcher_marker_sessions — a direct lookup, no ps;
#   • each live marker pid EXPANDED to its session (leg a) — covers bash-written 3-line markers and any
#     marker predating the recorded-session line. Gated on the SAME liveness (_sweep_live_marker_pids
#     only returns pids of markers that are live), so a dead marker's session is never spared.
_sweep_live_marker_sessions() {
  watcher_marker_sessions
  local p s
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # Normalize onto its own line: _sweep_sess_of's backends differ on the trailing newline (python
    # print adds one, ps/seam do not), and two newline-less expansions would otherwise concatenate.
    s="$(_sweep_sess_of "$p")"
    [ -n "$s" ] && printf '%s\n' "$s"
  done < <(_sweep_live_marker_pids)
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

# sweep_orphan_procs — emit "pid\tpgid\tSTARTTIME\tcommand" for every ORPHANED (ppid==1) bats/healthcheck
# process tree ATTRIBUTED TO THIS PROJECT. Attribution is the whole safety story (issue #60: a
# careless pattern kill once reaped a sibling project's watcher), so a candidate must satisfy ALL of:
#   • ppid == 1                     — genuinely reparented to init; a child of a live runner is busy
#   • command matches a bats/healthcheck/test-script shape
#   • it is not us, not our process group, and not the live watcher
#   • it is NOT the worker of a live inflight marker (see _sweep_live_marker_pids)
#   • its command line names a path UNDER $MAIN/$TREES, or its cwd resolves under one of them
# A candidate we cannot attribute is DROPPED, never killed.
#
# The START-TIME is captured HERE, at listing time, and travels with the row — it is the identity
# token the kill path re-verifies against. Sampling it again at kill time (as an earlier revision did)
# compares two `ps` calls microseconds apart and can never disagree, which makes the recycling guard
# dead code. Real time elapses between listing and TERM: the cwd fallback below runs an `lsof` per
# unattributed candidate, so hundreds of ms can pass, and a listed orphan may exit and have its
# pid/pgid recycled inside that window. Same discipline as _marker_write, which persists the
# start-time at dispatch rather than re-reading it at collect.
sweep_orphan_procs() {
  local pid ppid pgid cmd cwd tok mypgid wpid="" live livesess csess owned st
  mypgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
  [ -f "${HERD_WATCHER_LOCK:-/nonexistent}" ] && wpid="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
  live=" $(_sweep_live_marker_pids | tr '\n' ' ')"
  livesess=" $(_sweep_live_marker_sessions | tr '\n' ' ')"
  while read -r pid ppid pgid cmd; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$ppid" = "1" ] || continue
    [ "$pid" = "$$" ] && continue
    [ -n "$wpid" ] && [ "$pid" = "$wpid" ] && continue
    [ -n "$mypgid" ] && [ "$pgid" = "$mypgid" ] && continue
    case "$live" in *" $pid "*) continue ;; esac
    printf '%s' "$cmd" | grep -Eq "$SWEEP_ORPHAN_CMD_RE" || continue  # pipe-ok: single short scalar (one line), far under a pipe buffer
    # HERD-348: spare any candidate whose SESSION matches a live gate worker's session. The python
    # health/review worker detaches into its own session and its bats subtree runs in a DIFFERENT pgid
    # inside it, so the marker's recorded PID misses the pid that is about to be killed — the session
    # does not. A candidate whose session is unknowable (python absent, pid gone) yields no token and is
    # judged on attribution alone, exactly as before this change. Only a NON-empty match spares.
    csess="$(_sweep_sess_of "$pid")"
    if [ -n "$csess" ]; then
      case "$livesess" in *" $csess "*) continue ;; esac
    fi
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
    # Capture the identity token NOW, while the listing decision is being made.
    st="$(_pid_starttime "$pid")"
    printf '%s\t%s\t%s\t%s\n' "$pid" "$pgid" "$st" "$cmd"
  done < <(_sweep_ps)
}

# _sweep_watcher_has_gate_child <pid> <process-table> — the historical name for watcher-exempt.sh's
# watcher_has_gate_child (the child-based half of the HERD-217 gate-worker exemption). One
# implementation, shared with bin/herd's duplicate-watcher check since HERD-266.
_sweep_watcher_has_gate_child() { watcher_has_gate_child "$@"; }

# sweep_stray_watchers — pids of argv0-tagged watcher MAINS for THIS workspace that are NOT the
# lockfile's watcher: duplicates/zombies left by a crashed reload. Detection only — the KILL is
# delegated to bin/herd's _stop_project_watcher during leg 5, so there is exactly ONE watcher-killing
# code path in the engine (its SIGTERM-poll-SIGKILL-abort discipline, not a second copy here).
#
# "Watcher main" is decided by watcher_list_mains (scripts/herd/watcher-exempt.sh), the ONE shared
# check — so this leg and `herd status` can never disagree about what a duplicate is (HERD-266). Its
# listing already spares the canonical watcher's own argv0-inherited forks that can be PROVEN as such:
# a marker-owned gate worker (clause 1) and a child of the canonical watcher (clause 2).
#
# On top of that, and ONLY here, we re-apply the HERD-217 gate-child guard: skip a tagged pid that
# PARENTS a live healthcheck.sh / herd-review.sh gate worker. That guard belongs on this surface and
# no other. It is a HEURISTIC — it cannot tell a reparented fork from a stray watcher MAIN that merely
# dispatched a gate worker — and the cost of each mistake is asymmetric:
#   • HERE (detection): a missed stray is re-detected on the next sweep, but a FALSE stray is handed to
#     leg 5's _stop_project_watcher, which SIGKILLs it — destroying in-flight gate work and stranding
#     the PR behind a corpse (observed live 2026-07-09: a MAIN_HEALTH_TICK heavy-healthcheck worker, a
#     child of the canonical watcher, flagged '👻 duplicate watcher'). So we err toward sparing.
#   • In watcher_list_mains: erring toward sparing would hide a gate-running duplicate from BOTH the
#     `herd status` count and _stop_project_watcher's kill loop — the very safety rail. So we do not.
# A GENUINE orphan duplicate (parent dead, no gate child) is still listed here and still killed.
#
# We subtract the RECORDED lockfile pid (not merely the live one): watcher_list_mains omits it when
# alive, and a dead recorded pid can only appear in a synthetic table. The process table is read ONCE
# (through the _sweep_ps seam) and every argv0 match and parent/child exemption resolves against that
# single snapshot.
sweep_stray_watchers() {
  local marker="${HERD_WATCH_ARGV0:-}" wpid pid table
  [ -n "$marker" ] || return 0
  wpid="$(watcher_lock_pid)"
  table="$(_sweep_ps)"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ -n "$wpid" ] && [ "$pid" = "$wpid" ] && continue
    _sweep_watcher_has_gate_child "$pid" "$table" && continue
    printf '%s\n' "$pid"
  done < <(watcher_list_mains "$table")
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

# _sweep_term_one <pid> <pgid> <listed-starttime> — IDENTITY-VERIFIED SIGTERM.
#
# The start-time token was captured by sweep_orphan_procs at LISTING time; here we re-read the pid's
# CURRENT start-time and refuse to signal unless they match. That is the whole recycling guard: if the
# listed orphan exited and an unrelated process inherited its pid number, the tokens differ and we
# signal nothing. (Re-sampling the token here instead of threading the listed one through would
# compare a value against itself — the guard would be inert.)
#
# The PGID gets the SAME treatment. It is a snapshot value used as a GROUP-kill target, so it is the
# more dangerous of the two: a stale pgid aims SIGTERM/SIGKILL at an entire unrelated process group.
# We re-read the pid's current pgid and group-kill only when it still equals the listed one; on any
# mismatch (or an unreadable pgid) we fall back to signalling the single pid.
#
# Group kills also skip a group we must spare (see _sweep_spare_pgids) and never group 0/1.
# Prints the signalled TARGET ("<pid>" or "-<pgid>") for the later SIGKILL; prints nothing when the
# kill was refused or the pid is already gone.
_sweep_term_one() {
  local pid="$1" pgid="$2" st="$3" cur curpgid target spare
  cur="$(_pid_starttime "$pid")"
  if [ -n "$st" ] && [ -n "$cur" ] && [ "$cur" != "$st" ]; then
    journal_append sweep_proc_skip pid "$pid" reason pid-recycled
    return 0
  fi
  kill -0 "$pid" 2>/dev/null || return 0
  target="$pid"
  case "$pgid" in
    ''|0|1|*[!0-9]*) : ;;
    *)
      curpgid="$(_sweep_pgid_of "$pid")"
      if [ -z "$curpgid" ] || [ "$curpgid" != "$pgid" ]; then
        # The pid moved groups (or we cannot read its group) since listing — the recorded pgid no
        # longer provably names THIS process's group, so it is not a safe group-kill target.
        journal_append sweep_proc_pidonly pid "$pid" pgid "$pgid" reason pgid-changed
      else
        spare="$(_sweep_spare_pgids)"
        case "$spare" in
          *" $pgid "*) journal_append sweep_proc_pidonly pid "$pid" pgid "$pgid" reason spared-group ;;
          *) target="-$pgid" ;;
        esac
      fi ;;
  esac
  kill -TERM "$target" 2>/dev/null || true
  printf '%s' "$target"
}

# _sweep_await_dead <deadline-secs> <target…> — poll until every TARGET is gone or the deadline
# expires. Targets, not pids: a group target ("-<pgid>") is only dead when the WHOLE group is empty
# (`kill -0 -<pgid>` succeeds while any member lives). Waiting on the leader pid alone would return
# success the moment the leader exits, skip the follow-up SIGKILL, and strand the surviving children —
# exactly the "TERMing only the leader strands its children" case the group kill exists to prevent.
#
# ONE deadline for the WHOLE batch, not one per target: under SWEEP_AUTO=auto this runs inside the
# watcher tick, and a per-target grace would stall the tick by (orphans × grace) seconds. Most orphans
# die together anyway (they share a process group), so the batch usually clears on the first poll.
_sweep_await_dead() {
  local deadline="$1"; shift
  local waited=0 t alive
  while [ "$waited" -lt "$deadline" ]; do
    alive=0
    for t in "$@"; do kill -0 "$t" 2>/dev/null && { alive=1; break; }; done
    [ "$alive" -eq 0 ] && return 0
    sleep 1; waited=$(( waited + 1 ))
  done
  return 1
}

# sweep_leg_procs <dry> — leg 4. LISTS every orphan first (the plan), then kills. Listing before
# acting is deliberate: an operator reading the console must see what is about to die BEFORE it does,
# and a dry-run must print exactly the same list.
sweep_leg_procs() {
  local dry="$1" pid pgid cmd st tgt rows strays
  rows="$(sweep_orphan_procs)"
  strays="$(sweep_stray_watchers)"

  while IFS=$'\t' read -r pid pgid st cmd; do
    [ -n "${pid:-}" ] || continue
    SWEEP_N_PROC=$(( SWEEP_N_PROC + 1 ))
    _sweep_say "🧟" "kill orphan pid ${pid} (pgid ${pgid}) — ${cmd:0:70}"
  done <<< "$rows"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if [ "$SWEEP_LEG5" = "1" ]; then
      _sweep_say "👻" "duplicate watcher pid ${pid} — stopped by the leg-5 watcher restart"
    else
      _sweep_say "👻" "duplicate watcher pid ${pid} — NOT stopped (leg 5 skipped); run 'herd sweep' to stop it"
    fi
  done <<< "$strays"

  [ -n "$dry" ] && return 0
  # TERM the whole batch, then wait ONE shared grace period, then SIGKILL whatever survived. Under
  # SWEEP_AUTO=auto this runs inside the watcher tick, so the wall-clock cost must be O(grace), not
  # O(orphans × grace).
  local targets=()
  while IFS=$'\t' read -r pid pgid st cmd; do
    [ -n "${pid:-}" ] || continue
    # $st is the token captured at LISTING — never re-sampled here, or the guard would be inert.
    tgt="$(_sweep_term_one "$pid" "$pgid" "$st")"
    [ -n "$tgt" ] || continue                     # refused (recycled / already gone)
    targets+=("$tgt")
    journal_append sweep_proc pid "$pid" pgid "$pgid" target "$tgt" cmd "${cmd:0:120}"
  done <<< "$rows"
  [ "${#targets[@]}" -gt 0 ] || return 0
  _sweep_await_dead "$SWEEP_KILL_GRACE" "${targets[@]}" && return 0
  for tgt in "${targets[@]}"; do kill -KILL "$tgt" 2>/dev/null || true; done
  return 0
}

# ── leg 6: retroactive tracker linkage (HERD-267) ────────────────────────────────────────────────
# The OTHER half of the create-failure incident. When a coordinator's `scribe add` was eaten by the
# Linear issue cap, the lane still spawned a builder — and that builder shipped a PR whose `Refs:`
# line named a SLUG, not a tracker id, because no id was ever minted. The PR merged. The work is in
# main. Nothing on the tracker records it, and no reaper looks for that shape, so the item is lost
# forever unless a human happens to remember.
#
# This leg looks. For each recently-merged PR it reads the `Refs:` value and asks whether it points at
# a tracker item that EXISTS. Two outcomes are PROVABLE, and only those are acted on:
#   • the ref is not a tracker identifier at all (a slug, a branch name) — no lookup needed;
#   • the ref parses as an identifier but the backend cannot resolve it to an issue.
# Anything else (a resolvable item, an unreachable API, a backend with no single-item read op) is
# left alone. Fail-soft to the point of uselessness is the correct failure mode here: a false relink
# files a duplicate issue, and a control room that cries duplicate is a control room nobody reads.
#
# ADVISORY BY CONSTRUCTION. The leg never writes the tracker. It drops a scribe request into the
# ordinary backlog queue — the same `.req` file `herd scribe` writes — asking the drainer to SEARCH
# for an existing item first and only then file one, with the PR link attached. A seen-ledger keys
# the enqueue by PR number so a leg that runs every cadence tick enqueues each PR exactly once.
SWEEP_RELINK_LIMIT="${HERD_RELINK_LIMIT:-20}"   # merged PRs examined per run (test seam: HERD_RELINK_LIMIT)

# Set by _sweep_relink_missing when a lookup could NOT be resolved (no credential, unreachable host,
# auth/rate-limit refusal, a backend with no tri-state probe). Always DEFINED so the watcher — which
# sources this file under `set -u` — reads it safely. Reset per leg run.
_SWEEP_RELINK_UNPROVEN=0

# _sweep_relink_pr_rows — one "<number>\t<url>\t<ref>" row per recently-merged PR that carries a
# `Refs:` line, ref-less PRs omitted. The ref extraction is NOT re-implemented here: it reuses
# agent-watch.sh's HERD_PR_REF_PY, the same snippet merge-time reconcile parses with, so the two
# surfaces cannot drift apart on HTML-comment stripping, placeholders, or trailing punctuation.
# HERD_RELINK_PR_JSON is the hermetic seam (a file holding the same JSON `gh pr list` returns), so
# the test never touches the network.
_sweep_relink_pr_rows() {
  local raw
  if [ -n "${HERD_RELINK_PR_JSON-}" ] && [ -f "${HERD_RELINK_PR_JSON-}" ]; then
    raw="$(cat "$HERD_RELINK_PR_JSON" 2>/dev/null || true)"
  else
    command -v gh >/dev/null 2>&1 || return 0
    raw="$(gh pr list --state merged --limit "$SWEEP_RELINK_LIMIT" --json number,url,body 2>/dev/null || true)"
  fi
  [ -n "$raw" ] || return 0
  printf '%s' "$raw" | python3 -c "$HERD_PR_REF_PY"'
import sys, json
try: prs = json.load(sys.stdin)
except Exception: sys.exit(0)
if not isinstance(prs, list): sys.exit(0)
for p in prs:
    ref = pr_ref_from_body(p.get("body") or "")
    if not ref:
        continue
    print("%s\t%s\t%s" % (p.get("number", ""), p.get("url", ""), ref))
' 2>/dev/null || true
}

# _sweep_relink_backend_file — the ACTIVE backend's implementation path (test seam: SCRIBE_BACKEND_DIR).
_sweep_relink_backend_file() {
  printf '%s' "${SCRIBE_BACKEND_DIR:-$_SWEEP_HERE/backends}/${SCRIBE_BACKEND:-file}.sh"
}

# _sweep_relink_backend_capable — can the ACTIVE backend answer "does this item exist?" at all?
# True only when it implements the TRI-STATE probe `_backend_item_missing`. The default `file` backend
# and `changelog` do not (and cannot: `file` records state in $BACKLOG_FILE, `changelog` is append-only
# with no per-item identity), so on those projects this whole leg is inert — no `gh pr list`, no rows,
# no enqueue. That is the correct answer, not a degraded one: a tracker with no minted ids has no
# "the id was never minted" failure to heal.
_sweep_relink_backend_capable() {
  local bfile; bfile="$(_sweep_relink_backend_file)"
  [ -f "$bfile" ] || return 1
  (
    # The probe must describe THE ACTIVE BACKEND, never a definition some earlier caller left in this
    # process. `command -v` finds inherited shell functions, so a stray _backend_item_missing sourced
    # upstream would make an incapable backend look capable — and a capable-looking `file` backend is
    # exactly how a title slug gets judged a missing identifier.
    unset -f _backend_item_missing _backend_ref_is_identifier 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$bfile" 2>/dev/null || exit 1
    command -v _backend_item_missing >/dev/null 2>&1 || exit 1
    exit 0
  )
}

# _sweep_relink_missing <ref> — 0 ONLY when the tracker PROVABLY holds no item for this ref.
#
# "PROVABLY" is doing all the work, and getting it wrong is a LIVE WRITE: sweep_run_safe_legs calls
# this leg with dry="" on the watcher's auto path, so a wrong verdict enqueues a scribe request that
# files a duplicate tracker item, and stamps the PR into the one-way seen-ledger so the verdict is
# never revisited. Two states are provable, and they are asked in this order:
#
#   1. the backend says the ref is not one of ITS identifiers (`_backend_ref_is_identifier` — a bare
#      slug or branch name where the tracker mints TEAMKEY-42). Proof-positive that no id was ever
#      minted, and it needs no network. This is the incident's own shape: the create failed, so the
#      lane had no id to write and shipped the slug.
#   2. the ref IS an identifier and the backend's TRI-STATE probe answers "the API replied cleanly
#      with zero matches".
#
# THE SHAPE TEST BELONGS TO THE BACKEND, NOT TO US. An earlier revision of this function hardcoded the
# Linear/GitHub id shape (`#N` / `KEY-N`) into the engine. On the DEFAULT `file` backend, whose item ref
# IS a title slug, every healthy merged PR carrying `Refs: healthcheck-sha-cache` then failed the shape
# test and was declared missing WITHOUT THE BACKEND EVER BEING CONSULTED — up to HERD_RELINK_LIMIT
# duplicate filings per run, each PR stamped seen so the verdict was never revisited. So step 1 now asks
# the backend, and a backend that does not define the op cannot reach step 1 at all.
#
# EVERYTHING ELSE IS UNPROVEN and the leg says nothing: a resolvable item, a backend with no probe op,
# an unreadable backend file, no credential, an unreachable host, an auth or rate-limit refusal, a 5xx.
# We deliberately do NOT fall back to _backend_show_item, whose single non-zero return collapses
# not-found together with every transport and API failure — reading that as "missing" turns a tracker
# OUTAGE into a burst of duplicate filings (and does so precisely when an expired key is already making
# create_retry_class mark creates auth/permanent). A tracker that will not answer is not a tracker that
# said no, and a tracker that does not mint ids never failed to mint one.
#
# Sets _SWEEP_RELINK_UNPROVEN=1 when a lookup could not be resolved, so the leg can tell the operator
# it stood down rather than silently reporting a clean sweep over an unreachable tracker.
#
# The backend is sourced in a SUBSHELL so no _backend_* function leaks into the long-lived watcher's
# namespace (the same isolation _reconcile_via_ref uses).
_sweep_relink_missing() {
  local ref="$1" bfile rc
  bfile="$(_sweep_relink_backend_file)"
  [ -f "$bfile" ] || { _SWEEP_RELINK_UNPROVEN=1; return 1; }
  (
    # Only the ACTIVE backend's ops may answer here — see _sweep_relink_backend_capable.
    unset -f _backend_item_missing _backend_ref_is_identifier 2>/dev/null || true
    # shellcheck source=/dev/null
    [ -f "$MAIN/.herd/secrets" ] && . "$MAIN/.herd/secrets"
    # shellcheck source=/dev/null
    . "$bfile" 2>/dev/null || exit 2
    command -v _backend_item_missing >/dev/null 2>&1 || exit 2   # no tri-state probe → UNPROVEN
    # (1) The backend's OWN shape test. Only a backend that mints identifiers can declare a ref
    #     "not one of mine"; without the op we cannot tell a slug-because-the-create-failed from a
    #     slug-because-that-is-what-this-tracker-calls-an-item.
    if command -v _backend_ref_is_identifier >/dev/null 2>&1; then
      _backend_ref_is_identifier "$ref" >/dev/null 2>&1 || exit 0
    fi
    # (2) The API's own answer.
    _backend_item_missing "$ref" >/dev/null 2>&1
    exit $?
  )
  rc=$?
  case "$rc" in
    0) return 0 ;;                                      # provably missing
    1) return 1 ;;                                      # the item exists
    *) _SWEEP_RELINK_UNPROVEN=1; return 1 ;;            # we do not know — never act on that
  esac
}

# _sweep_relink_request <pr> <url> <ref> — the scribe request text. First line is a SHORT title (the
# Linear backend derives an issue title from it, and an essay-length first line becomes an essay-length
# title); the body carries the SEARCH-FIRST instruction so a relink can never blindly duplicate an
# item that was filed by hand in the meantime.
_sweep_relink_request() {
  local pr="$1" url="$2" ref="$3"
  printf 'Relink merged PR #%s — its tracker item is missing\n\n' "$pr"
  printf 'PR #%s (%s) merged with "Refs: %s", but no tracker item exists for that ref — the original create failed (see HERD-267: the tracker refused it, e.g. an issue cap, and the lane shipped a slug-only ref).\n\n' "$pr" "$url" "$ref"
  printf 'SEARCH FIRST: look for an existing open or completed item covering this PR. If one exists, amend it with the PR link instead of filing a duplicate. Only if none exists, file a new item describing the merged work and link %s.\n' "$url"
}

# sweep_leg_links <dry> — narrate every merged PR with a missing tracker item, enqueue its retroactive
# linkage request (once per PR), and surface the durable create-retry queue's coalesced rows. Emits
# NOTHING and touches nothing when the queue is empty and every merged PR resolves, so a healthy
# control room's sweep output is byte-identical to before HERD-267.
# _sweep_relink_scan_due <throttle> — may we spend a `gh pr list` round-trip now? The CLI (throttle
# empty) always may. The watcher's SWEEP_AUTO=auto path passes throttle=1 and gets at most one scan
# per hour: a merged PR's missing tracker item is hours-old debris, not a per-tick emergency, and the
# rest of the trigger pass is deliberately network-free.
_sweep_relink_scan_due() {
  [ -n "${1:-}" ] || return 0
  local stamp="$TREES/.create-relink-stamp" prev now
  now="$(_now_epoch 2>/dev/null || date +%s)"
  prev="$(cat "$stamp" 2>/dev/null || echo 0)"
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  [ $(( now - prev )) -ge 3600 ] || return 1
  printf '%s\n' "$now" > "$stamp" 2>/dev/null || true
  return 0
}

sweep_leg_links() {
  # Every name declared local: this runs inside the long-lived watcher process, and a leaked `state`
  # or `title` would quietly collide with the next caller's.
  local dry="$1" throttle="${2:-}" seen="$TREES/.create-relink-seen" pr url ref q tmp
  local state class attempts title
  create_retry_enabled || return 0
  _SWEEP_RELINK_UNPROVEN=0

  # The durable retry queue's own rows first: ONE line per distinct request, carrying its attempt
  # count. A cap-killed filing that has failed nine times renders once here reading attempts=9 —
  # coalesced, not stacked, so the console stays readable while the failure is impossible to miss.
  while IFS=$'\t' read -r state class attempts title; do
    [ -n "${state:-}" ] || continue
    if [ "$state" = permanent ]; then
      _sweep_say "🚫" "tracker create BLOCKED (${class}) after ${attempts} attempt(s) — request saved, NOT retrying: ${title}"
    else
      _sweep_say "⏳" "tracker create queued for retry (${class}, ${attempts} attempt(s)): ${title}"
    fi
  done <<< "$(create_retry_rows 2>/dev/null || true)"

  # A backend that cannot answer "does this item exist?" gets no scan at all — not a `gh pr list`, not
  # a row, not a stand-down line. On the DEFAULT `file` backend (and on `changelog`) there are no minted
  # ids, so there is no missing-id failure to heal, and the leg is completely inert.
  _sweep_relink_backend_capable || return 0

  _sweep_relink_scan_due "$throttle" || return 0

  q="$TREES/backlog-queue"
  while IFS=$'\t' read -r pr url ref; do
    [ -n "${pr:-}" ] && [ -n "${ref:-}" ] || continue
    grep -qxF "$pr" "$seen" 2>/dev/null && continue
    _sweep_relink_missing "$ref" || continue
    SWEEP_N_LINK=$(( SWEEP_N_LINK + 1 ))
    _sweep_say "🔗" "relink PR #${pr} — 'Refs: ${ref}' names no tracker item (the create failed)"
    [ -n "$dry" ] && continue
    # Enqueue through the ordinary backlog-queue primitive (temp then atomic mv), never by touching
    # the tracker directly. Record the PR in the seen-ledger only after the request is really queued,
    # so a write that fails is retried on the next sweep rather than silently forgotten.
    mkdir -p "$q" 2>/dev/null || continue
    tmp="$(mktemp "$q/.tmp.relink.XXXXXX" 2>/dev/null)" || continue
    _sweep_relink_request "$pr" "$url" "$ref" > "$tmp" 2>/dev/null || { rm -f "$tmp"; continue; }
    mv "$tmp" "$q/$(_now_epoch 2>/dev/null || date +%s)-relink-${pr}.req" 2>/dev/null || { rm -f "$tmp"; continue; }
    printf '%s\n' "$pr" >> "$seen" 2>/dev/null || true
    journal_append link_heal pr "$pr" ref "$ref" result enqueued
  done <<< "$(_sweep_relink_pr_rows)"
  # A tracker we could not reach is not a clean tracker. Say so once, so an operator reading a
  # zero-finding sweep during a Linear outage knows the leg stood down rather than passed.
  if [ "$_SWEEP_RELINK_UNPROVEN" -ne 0 ]; then
    _sweep_say "⏸ " "relink check stood down — the tracker did not answer for at least one ref (unproven ≠ missing)"
    journal_append link_heal result unproven
  fi
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
# sweep_swept_total — how many things the last sweep_run_safe_legs actually acted on (flags excluded:
# a flag is a report, not an action). Lets the watcher's auto path detect a no-progress run.
sweep_swept_total() { printf '%s' "$(( SWEEP_N_REAP + SWEEP_N_TAB + SWEEP_N_MARKER + SWEEP_N_PROC ))"; }

# _sweep_stamp_tally — record this sweep's completion wall-clock in $TREES/.sweep-tally-stamp so a LIVE
# watcher recomputes its cached housekeeping tally the very next tick instead of advertising the
# now-cleaned mess until its throttled ~60 s scan (HERD-215 cry-wolf fix). A MANUAL `herd sweep` runs
# in a SEPARATE process from the watcher, so a shared file is the only channel — the watcher polls it in
# _sweep_trigger_tick. Best-effort; the watcher falls back to its cadence when the stamp cannot be read.
_sweep_stamp_tally() {
  [ -n "${TREES:-}" ] || return 0
  local _st_now; _st_now="$(_now_epoch 2>/dev/null || date +%s)"
  printf '%s\n' "$_st_now" > "$TREES/.sweep-tally-stamp" 2>/dev/null || true
}

sweep_run_safe_legs() {
  _sweep_reset_counters
  sweep_leg_markers ""
  sweep_leg_procs ""
  sweep_leg_worktrees ""
  sweep_leg_tabs ""
  # Leg 6 is SAFE by the same definition as the rest of this set: it deletes nothing and writes no
  # tracker state — it only enqueues an advisory scribe request, once per PR (seen-ledger). Throttled
  # here (and only here): the watcher runs this every cadence tick, and the rest of its trigger pass
  # is network-free by design.
  sweep_leg_links "" 1
  journal_append sweep_auto reaped "$SWEEP_N_REAP" flagged "$SWEEP_N_FLAG" \
    tabs "$SWEEP_N_TAB" markers "$SWEEP_N_MARKER" procs "$SWEEP_N_PROC"
  # Tell a live watcher the tally is stale so it recomputes now (HERD-215). Harmless in the auto path,
  # which recomputes in-process anyway; load-bearing for a manual `herd sweep` from another process.
  _sweep_stamp_tally
  return 0
}

# ── CLI entry point (legs 1–4; leg 5 lives in bin/herd's cmd_sweep) ──────────────────────────────
sweep_main() {
  local dry="" mode="run" norestart=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)    dry=1; mode="dry-run" ;;
      --no-restart) norestart=1 ;;
      --auto)       mode="auto" ;;
      *) printf 'usage: sweep.sh [--dry-run] [--no-restart] [--auto]\n' >&2; return 2 ;;
    esac
    shift
  done
  # cmd_sweep runs leg 5 iff neither flag is set — mirror that so the stray-watcher narration is honest.
  if [ -z "$dry" ] && [ -z "$norestart" ]; then SWEEP_LEG5=1; else SWEEP_LEG5=0; fi

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
  sweep_leg_links     "$dry"

  local total=$(( SWEEP_N_REAP + SWEEP_N_TAB + SWEEP_N_MARKER + SWEEP_N_PROC ))
  printf '\n'
  if [ "$SWEEP_N_LINK" -gt 0 ]; then
    printf '  🔗 %d merged PR(s) with a missing tracker item — retroactive linkage %s\n' \
      "$SWEEP_N_LINK" "$([ -n "$dry" ] && printf 'would be enqueued' || printf 'enqueued for the scribe')"
  fi
  if [ "$total" -eq 0 ] && [ "$SWEEP_N_FLAG" -eq 0 ]; then
    # A leg-6 finding is not a "sweep", but it is not clean either — the 🔗 line above already said
    # what happened, so stay silent rather than claiming a clean room over the top of it.
    [ "$SWEEP_N_LINK" -eq 0 ] && printf '  ✅ control room clean — nothing to sweep\n'
  else
    printf '  %s %d worktree(s) · %d tab(s) · %d marker(s) · %d process(es)%s\n' \
      "$([ -n "$dry" ] && printf 'would sweep:' || printf 'swept:')" \
      "$SWEEP_N_REAP" "$SWEEP_N_TAB" "$SWEEP_N_MARKER" "$SWEEP_N_PROC" \
      "$([ "$SWEEP_N_FLAG" -gt 0 ] && printf ' · %d FLAGGED for you' "$SWEEP_N_FLAG")"
    [ "$SWEEP_N_FLAG" -gt 0 ] && printf '  🚩 flagged items are NEVER auto-deleted — resolve them by hand\n'
  fi

  journal_append sweep_done mode "$mode" reaped "$SWEEP_N_REAP" flagged "$SWEEP_N_FLAG" \
    tabs "$SWEEP_N_TAB" markers "$SWEEP_N_MARKER" procs "$SWEEP_N_PROC"
  # Invalidate a live watcher's cached tally so its housekeeping line recomputes next tick (HERD-215).
  # Skip on --dry-run: it touched nothing, so the mess is still there and the cached count is still true.
  [ -z "$dry" ] && _sweep_stamp_tally
  return 0
}

# Library mode: agent-watch.sh (and the unit test) source this file for the helpers above.
if [ "${SWEEP_LIB:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi
# Guard against being sourced by agent-watch.sh without SWEEP_LIB (belt and braces: never run the
# CLI from inside the watcher).
case "${BASH_SOURCE[0]}" in "$0") sweep_main "$@" ;; esac
