#!/usr/bin/env bash
# new-feature.sh <name> — spin up an isolated worktree off the latest default branch.
# Each worktree is a fully independent working dir on its own feat/<name> branch, sharing one
# .git. Edits/tests in one never touch the others or the coordinator.
set -euo pipefail

NAME="${1:?usage: new-feature.sh <feature-name>   (e.g. new-feature.sh dividend-history)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
# Fail fast if herdr is missing or its CLI/JSON contract has skewed before we set up a worktree
# that the lanes (which all shell out to herdr) would then fail to drive.
. "$HERE/herd-preflight.sh"
herd_preflight || exit 1
REPO="$PROJECT_ROOT"
TREES="$WORKTREES_DIR"
BRANCH="feat/$NAME"
DIR="$TREES/$NAME"

git -C "$REPO" fetch -q "$HERD_REMOTE"
# Branch off the freshly-fetched remote default branch so new worktrees always start from the
# latest pushed state, regardless of which branch the main checkout sits on.
git -C "$REPO" worktree add "$DIR" -b "$BRANCH" "$DEFAULT_BRANCH"

# SHARE_LINKS (from .herd/config) are gitignored shared dirs that live only in the main checkout
# (e.g. "data .venv") — symlink each into the worktree so the app/tooling can run here. A worktree
# missing a required link silently can't run anything, so treat a failed/broken link as fatal: we
# never report success on a half-built worktree. Empty SHARE_LINKS → a pure code-only worktree.
link_or_die() {
  local target="$1" link="$2"
  if [ ! -e "$target" ]; then
    echo "⚠️  skip symlink: $target does not exist in the main checkout." >&2
    return 0
  fi
  if ! ln -s "$target" "$link" || [ ! -e "$link" ]; then
    echo "❌ Failed to symlink $link -> $target — worktree at $DIR is unusable." >&2
    exit 1
  fi
}
for share in $SHARE_LINKS; do
  link_or_die "$REPO/$share" "$DIR/$share"
done

# Pre-trust the worktree for Claude Code so agents launched with
# --dangerously-skip-permissions don't stall on the "Is this a project you trust?"
# interactive gate. Claude Code treats a project-level .claude/settings.json as a
# trust marker and skips the prompt. Write a minimal one now, before the agent starts.
# The file is gitignored (.gitignore: .claude/settings.json) — never committed.
mkdir -p "$DIR/.claude"
printf '{}\n' > "$DIR/.claude/settings.json"

echo "✅ Worktree ready: $DIR   (branch $BRANCH, off $DEFAULT_BRANCH @ $(git -C "$REPO" rev-parse --short "$DEFAULT_BRANCH"))"
echo "   Start an agent here:   cd $DIR && claude"
echo "   When done:             gh pr create   # then the watcher reviews & merges"
