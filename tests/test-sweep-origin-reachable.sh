#!/usr/bin/env bash
# test-sweep-origin-reachable.sh — HERD-457 / GH #571 proof: `herd sweep`'s closed-unique-commits
# flag must consult ORIGIN (every remote-tracking ref), not just DEFAULT_BRANCH, before calling a
# commit "unique". A closed-unmerged PR usually leaves its branch intact on origin (closing a PR
# never deletes it; only a MERGE-time DELETE_BRANCH_ON_MERGE does), so every commit it ever pushed
# was previously flagged as "exists only here" — a false positive: the commit is byte-identical on
# the remote, nothing is at risk of being lost.
#
# Fully hermetic: a local bare repo stands in for "origin" (git init --bare + git push), no network.
#
# Asserts:
#   (1) PUSHED + CLOSED — a commit reachable from a remote-tracking ref (even though it is not on
#       DEFAULT_BRANCH) reads as 0 unique commits — safe to reap.
#   (2) UNPUSHED — a commit on NO remote-tracking ref anywhere still reads as genuinely unique — the
#       judgment flag survives; the fix never turns real risk into a silent reap.
#   (3) UNREACHABLE ORIGIN — a bogus/unfetchable remote URL fails soft: the fetch attempt errors
#       silently and the verdict falls back to the pre-fix, more-conservative local-diff count. Never
#       hangs, never crashes, never treats "could not check" as "safe".
#
# Run:  bash tests/test-sweep-origin-reachable.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"
[ -f "$WATCH" ] || { echo "FAIL: agent-watch.sh not found at $WATCH" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); }

# ── load _sweep_unique_commits via the shared AGENT_WATCH_LIB seam (never executes the tick loop) ──
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless
export PROJECT_ROOT="$T/unused" WORKTREES_DIR="$T/unused-trees" WORKSPACE_NAME=originreachws
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
mkdir -p "$PROJECT_ROOT" "$WORKTREES_DIR"
git init -q -b main "$PROJECT_ROOT"
git -C "$PROJECT_ROOT" config user.email t@t.local; git -C "$PROJECT_ROOT" config user.name t
echo base > "$PROJECT_ROOT/f.txt"; git -C "$PROJECT_ROOT" add -A; git -C "$PROJECT_ROOT" commit -qm base
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
unset AGENT_WATCH_LIB
command -v _sweep_unique_commits >/dev/null 2>&1 || fail "setup: _sweep_unique_commits not defined after sourcing"

# ── fixture: a bare repo as "origin", a main checkout, and worktrees off it ──────────────────────
BARE="$T/origin.git"; git init -q --bare "$BARE"
MAINDIR="$T/proj"; mkdir -p "$MAINDIR"
git init -q -b main "$MAINDIR"
git -C "$MAINDIR" config user.email t@t.local; git -C "$MAINDIR" config user.name t
echo base > "$MAINDIR/f.txt"; git -C "$MAINDIR" add -A; git -C "$MAINDIR" commit -qm base
git -C "$MAINDIR" remote add origin "$BARE"
git -C "$MAINDIR" push -q origin main
# The engine's own DEFAULT_BRANCH shape: a LOCAL ref standing in for the fetched remote-tracking ref
# (mirrors test-sweep.sh's fixture convention), pinned to the base commit only — never advanced past
# it, so every feature commit below is "not on DEFAULT_BRANCH" regardless of whether it's on origin.
git -C "$MAINDIR" update-ref refs/remotes/origin/main main
export DEFAULT_BRANCH="origin/main"

# ── (1) pushed + closed: origin has the branch → NOT unique, byte-identical-safe to reap ─────────
WT_PUSHED="$T/feat-pushed"
git -C "$MAINDIR" worktree add -q -b feat/pushed "$WT_PUSHED" main >/dev/null 2>&1
echo pushed > "$WT_PUSHED/p.txt"; git -C "$WT_PUSHED" add -A
git -C "$WT_PUSHED" -c user.email=t@t.local -c user.name=t commit -qm "pushed work"
git -C "$WT_PUSHED" push -q origin feat/pushed   # what a closed-unmerged PR usually leaves behind
out="$(_sweep_unique_commits "$WT_PUSHED")"
[ "$out" = "0" ] || fail "(1) a commit pushed to origin should read 0 unique commits, got '$out'"
ok; echo "PASS (1) pushed-and-closed branch reads 0 unique commits (origin has it)"

# ── (2) unpushed: no matching remote ref anywhere → still genuinely unique, still flagged ────────
WT_LOCAL="$T/feat-unpushed"
git -C "$MAINDIR" worktree add -q -b feat/unpushed "$WT_LOCAL" main >/dev/null 2>&1
echo local > "$WT_LOCAL/l.txt"; git -C "$WT_LOCAL" add -A
git -C "$WT_LOCAL" -c user.email=t@t.local -c user.name=t commit -qm "never pushed"
out="$(_sweep_unique_commits "$WT_LOCAL")"
[ "$out" = "1" ] || fail "(2) a commit never pushed anywhere should still read as 1 unique commit, got '$out'"
ok; echo "PASS (2) unpushed commit still reads as genuinely unique (judgment flag preserved)"

# ── (3) unreachable origin: fetch fails soft → falls back to the conservative local-diff count ───
MAINDIR2="$T/proj2"; mkdir -p "$MAINDIR2"
git init -q -b main "$MAINDIR2"
git -C "$MAINDIR2" config user.email t@t.local; git -C "$MAINDIR2" config user.name t
echo base > "$MAINDIR2/f.txt"; git -C "$MAINDIR2" add -A; git -C "$MAINDIR2" commit -qm base
git -C "$MAINDIR2" remote add origin "$T/does-not-exist.git"
git -C "$MAINDIR2" update-ref refs/remotes/origin/main main
WT_OFFLINE="$T/feat-offline"
git -C "$MAINDIR2" worktree add -q -b feat/offline "$WT_OFFLINE" main >/dev/null 2>&1
echo x > "$WT_OFFLINE/x.txt"; git -C "$WT_OFFLINE" add -A
git -C "$WT_OFFLINE" -c user.email=t@t.local -c user.name=t commit -qm "offline work"
DEFAULT_BRANCH="origin/main" out="$(DEFAULT_BRANCH="origin/main" _sweep_unique_commits "$WT_OFFLINE")"
[ "$out" = "1" ] || fail "(3) an unfetchable origin should fail soft to the local-diff count (1), got '$out'"
ok; echo "PASS (3) unreachable origin fails soft to the conservative local-diff verdict, no hang/crash"

echo "ALL PASS ($PASS)"
