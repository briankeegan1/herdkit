#!/usr/bin/env bash
# herd-quick.sh <slug> [task...] — the *lightweight* sibling of herd-feature.sh, for TRIVIAL,
# non-render changes: one-liners, config/string tweaks, script edits.
#
# Same sacred invariant as herd-feature.sh — the coordinator NEVER edits code in the main
# checkout — so this STILL spins up an isolated worktree off the latest default branch, and the
# spawned agent STILL branches, builds, and opens a PR. What it drops is the *ceremony* a trivial
# non-app change doesn't need:
#
#   - NO live app-preview pane (no free-port app server, no [app│agent] split).
#   - just ONE pane: the Claude sub-agent, in the worktree, yolo by default.
#
# The pre-PR healthcheck is SHARED with herd-feature.sh and auto-adapts: if the diff matches
# HEALTHCHECK_HEAVY_GLOB it runs the full heavy profile; otherwise the LIGHT profile (per-changed
# -file syntax + the project test command). See healthcheck.sh.
#
# Pick the lane:
#   herd-feature.sh  — app-facing features; you want the live preview.
#   herd-quick.sh    — non-app / trivial changes (scripts, docs, config).
#
# Env overrides:
#   HERD_CLAUDE_FLAGS   flags passed to claude (default: --dangerously-skip-permissions)
#   HERD_QUICK_MODEL    builder model (default: $MODEL_QUICK — Sonnet, the trivial lane)
#
# Standalone:
#   herd-quick.sh fix-readme-typo "Fix the typo in README.md"
# Or driven by the /coordinator skill.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
SLUG="${1:?usage: herd-quick.sh <slug> [task...]   (slug must be kebab-case)}"; shift || true
TASK="${*:-}"
DIR="$WORKTREES_DIR/$SLUG"
CLAUDE_FLAGS="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"
MODEL="${HERD_QUICK_MODEL:-$MODEL_QUICK}"
_WS_ID="$(herd_resolve_workspace_id)"

# 1. Worktree off the latest default branch + SHARE_LINKS symlinks (same isolation as the full
#    lane — fails loudly if the slug already exists). Abort if it can't be created.
if ! bash "$HERE/new-feature.sh" "$SLUG"; then
  echo "❌ new-feature.sh failed for '$SLUG' — worktree/branch not created; not spawning a herdr tab." >&2
  exit 1
fi

# 2. New herdr tab rooted in the worktree; grab tab id + root pane id. If herdr is unavailable
#    the parse yields empty ids — bail loudly instead of failing cryptically.
created=$(herdr tab create ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$DIR" --label "$SLUG" --no-focus)
read -r TAB ROOT < <(printf '%s' "$created" | python3 -c \
  'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' 2>/dev/null || true)
if [ -z "$TAB" ] || [ -z "$ROOT" ]; then
  echo "❌ herdr unavailable (could not create a tab for '$SLUG'); worktree is ready at $DIR but no panes were launched." >&2
  exit 1
fi

# 3. The Claude sub-agent — the ONLY pane (no app-preview split). It runs in the tab's root pane
#    (no --split right). Yolo by default is fine: the worktree is isolated. Seeded task + the
#    standing workflow rules become its opening prompt.
RULES="[workflow rules] Build ONLY this change in this worktree. Before running 'gh pr create',
run:  bash $HERE/healthcheck.sh \"$DIR\"  and get a clean pass (fix any CODE errors; data/env
warnings are fine). Do NOT merge the PR and do NOT edit $BACKLOG_FILE — the auto-merge watcher merges ready PRs (healthcheck + review gate); the coordinator owns the backlog.
If your change needs a manual step you cannot perform yourself (a live smoke test, a UI/pane check, anything needing a running app or human eyes), declare each such step in a 'HUMAN-VERIFY:' block in the PR body — one step per line. That switches this PR to a human-verify hold: all gates still run, but the watcher waits for a human to run 'herd-approve.sh approve <pr#>' instead of auto-merging, so the step is never silently skipped."
if [ -n "$TASK" ]; then TASK="$TASK"$'\n\n'"$RULES"; else TASK="$RULES"; fi
herdr agent start "$SLUG" ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$DIR" --tab "$TAB" --no-focus -- claude --model "$MODEL" $CLAUDE_FLAGS "$TASK"

echo "🐑 Quick sub-agent '$SLUG' running (claude --model $MODEL $CLAUDE_FLAGS) in herdr tab $TAB   dir: $DIR"
[ -n "$TASK" ] && echo "   seeded task: $TASK"
echo "   ⚡ light lane — no app preview; healthcheck auto-runs the light profile unless the diff matches the heavy glob."
echo "   jump to it:   herdr agent focus $SLUG"
echo "   when its PR is up: the watcher reviews & merges, then  git worktree remove $DIR"
