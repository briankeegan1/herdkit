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
# BRANCH_TEMPLATE (HERD-120): render the lane's branch name through the ONE shared helper instead of
# hardcoding feat/<name>. Default 'feat/{slug}' → byte-identical to before. When the coordinator
# spawned from a TRACKED item it exports HERD_ITEM_REF, feeding the optional {ref} token.
BRANCH="$(herd_branch_render "$NAME" "${HERD_ITEM_REF:-}")"
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
# Secrets-isolation guard (HERD-87): a SHARE_LINK must never expose .herd/secrets — the tracker's
# workspace API credentials — into a builder worktree. Builders run --dangerously-skip-permissions,
# so a symlink to .herd (which holds secrets) or to .herd/secrets itself would let a builder read the
# API key and mutate tracker state, violating "the coordinator owns all backlog/tracker updates".
# Refuse any share that IS, CONTAINS, or SITS UNDER the secrets path — loudly, then skip it (fail-soft:
# the worktree is still built; only the dangerous link is dropped). main-checkout filesystem perms are
# out of scope; this closes only the lane-provisioned vector.
_SECRETS_REL=".herd/secrets"
share_exposes_secrets() {
  local s="${1#./}"; s="${s%/}"   # normalize ./x and trailing slash
  case "$s" in
    "$_SECRETS_REL"|"$_SECRETS_REL"/*) return 0 ;;  # the secrets file, or anything under it
    ""|.|.herd) return 0 ;;                         # the repo root or the whole .herd dir contains it
  esac
  return 1
}
for share in $SHARE_LINKS; do
  if share_exposes_secrets "$share"; then
    echo "🚫 refusing SHARE_LINK '$share': it would expose .herd/secrets into the builder worktree (HERD-87)." >&2
    echo "   Builders must never reach tracker credentials; the coordinator owns all tracker state. Skipping this link." >&2
    continue
  fi
  link_or_die "$REPO/$share" "$DIR/$share"
done

# Pre-trust the worktree for Claude Code so a builder agent launched here doesn't stall on the
# interactive "Do you trust the files in this folder?" gate and die with zero commits. Trust is
# recorded in ~/.claude.json (projects["<abs-path>"].hasTrustDialogAccepted), NOT in any
# project-level settings file, and --dangerously-skip-permissions does not suppress the dialog in a
# pane session — so seed the entry now, before the agent starts. See herd_pretrust_worktree in
# herd-config.sh for the additive/atomic/backup guarantees. Best-effort: never fatal.
herd_pretrust_worktree "$DIR"

# Configure the per-project rate-limit hook so a builder that freezes on the account usage limit
# writes a sentinel the watcher polls — the primary, version-robust limit-hit signal that drives
# auto-resume-in-place via `claude --continue` (agent-watch.sh). Best-effort; the watcher's
# banner-scrape fallback covers environments where the hook is unavailable. See herd-config.sh.
herd_write_ratelimit_hook "$DIR"

# Wire any project-configured MCP servers (MCP_PROVISION) into this worktree's project-level
# settings.json so the builder can reach them as needed — the tools SIBLING of the context-provisioning
# surface. Same ADDITIVE / NON-CLOBBER / atomic guarantees as the rate-limit hook above (it merges into
# the very same settings.json without clobbering that hook). Empty MCP_PROVISION (the default) → a
# no-op and settings.json stays byte-identical. Secrets are never written — only "${VAR}" passthrough
# references. Best-effort; never fatal to worktree creation. See herd_write_mcp_servers in herd-config.sh.
herd_write_mcp_servers "$DIR"

echo "✅ Worktree ready: $DIR   (branch $BRANCH, off $DEFAULT_BRANCH @ $(git -C "$REPO" rev-parse --short "$DEFAULT_BRANCH"))"
echo "   Start an agent here:   cd $DIR && claude"
echo "   When done:             gh pr create   # then the watcher reviews & merges"
