#!/usr/bin/env bash
# herd-feature.sh <slug> [task...] — spin up an isolated worktree AND a full per-feature herdr
# tab laid out as:  [ live app preview | Claude sub-agent ]
#
#   - worktree off the latest default branch (+ SHARE_LINKS symlinks)   via new-feature.sh
#   - LEFT pane:  the APP_PREVIEW_CMD on a free port — hot-reloads as the agent edits, so you
#                 can watch the feature take shape. Omitted when APP_PREVIEW_CMD is unset (then
#                 this lane behaves like the quick lane: a single agent pane).
#   - RIGHT pane: a Claude sub-agent, seeded with [task...] as its opening prompt, running with
#                 permissions skipped (yolo) — fine because the worktree is isolated.
#
# Env overrides:
#   HERD_CLAUDE_FLAGS   flags passed to claude (default: --dangerously-skip-permissions)
#   HERD_FEATURE_MODEL  builder model (default: $MODEL_FEATURE — Opus, for the judgment)
#   HERD_NO_APP=1       skip the app-preview pane
#
# Standalone:
#   herd-feature.sh dividend-history "Add a dividend income history tab"
# Or driven by the /coordinator skill.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
SLUG="${1:?usage: herd-feature.sh <slug> [task...]   (slug must be kebab-case)}"; shift || true
TASK="${*:-}"
DIR="$WORKTREES_DIR/$SLUG"
CLAUDE_FLAGS="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"
MODEL="${HERD_FEATURE_MODEL:-$MODEL_FEATURE}"

# 1. Worktree off the latest default branch + SHARE_LINKS symlinks (fails loudly if the slug
#    already exists — don't clobber in-flight work). Abort here if it can't be created: a herdr
#    tab rooted in a non-existent or half-built dir is worse than no tab at all.
if ! bash "$HERE/new-feature.sh" "$SLUG"; then
  echo "❌ new-feature.sh failed for '$SLUG' — worktree/branch not created; not spawning a herdr tab." >&2
  exit 1
fi

# 2. New herdr tab rooted in the worktree; grab tab id + root pane id. If herdr is unavailable
#    the parse yields empty ids and every later 'herdr pane/agent' call fails cryptically — bail.
created=$(herdr tab create --cwd "$DIR" --label "$SLUG" --no-focus)
read -r TAB ROOT < <(printf '%s' "$created" | python3 -c \
  'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' 2>/dev/null || true)
if [ -z "$TAB" ] || [ -z "$ROOT" ]; then
  echo "❌ herdr unavailable (could not create a tab for '$SLUG'); worktree is ready at $DIR but no panes were launched." >&2
  exit 1
fi

# 3. RIGHT pane: the Claude sub-agent (yolo by default). The seeded task plus the standing
#    workflow rules become its opening prompt.
RULES="[workflow rules] Build ONLY this feature in this worktree. Before running 'gh pr create',
run:  bash $HERE/healthcheck.sh \"$DIR\"  and get a clean pass (fix any CODE errors; data/env
warnings are fine). Do NOT merge the PR and do NOT edit $BACKLOG_FILE — the auto-merge watcher merges ready PRs (healthcheck + review gate); the coordinator owns the backlog."
if [ -n "$TASK" ]; then TASK="$TASK"$'\n\n'"$RULES"; else TASK="$RULES"; fi
herdr agent start "$SLUG" --cwd "$DIR" --tab "$TAB" --split right --no-focus -- claude --model "$MODEL" $CLAUDE_FLAGS "$TASK"

# 4. LEFT pane (the tab's root): live app preview on a free port — only if a preview command is
#    configured and not suppressed. Each feature gets its own port so multiple previews coexist.
PORT=""
if [ -n "$APP_PREVIEW_CMD" ] && [ "${HERD_NO_APP:-}" != "1" ]; then
  PORT=$(python3 - <<'PY'
import socket
for p in range(8501, 8600):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p)); s.close(); print(p); break
    except OSError:
        pass
PY
)
  if [ -n "$PORT" ]; then
    herdr pane rename "$ROOT" "app·$PORT" >/dev/null 2>&1 || true
    herdr pane run "$ROOT" "bash $HERE/app-monitor.sh $PORT"
  else
    PORT=""
    echo "⚠️  No free port in 8501-8599 — skipping the app-preview pane for '$SLUG'." >&2
  fi
fi

echo "🐑 Sub-agent '$SLUG' running (claude --model $MODEL $CLAUDE_FLAGS) in herdr tab $TAB   dir: $DIR"
[ -n "$TASK" ] && echo "   seeded task: $TASK"
[ -n "$PORT" ] && echo "   🌐 app preview: http://localhost:$PORT   (hot-reloads as the agent edits)"
echo "   jump to it:   herdr agent focus $SLUG"
echo "   when its PR is up: the watcher reviews & merges, then  git worktree remove $DIR"
