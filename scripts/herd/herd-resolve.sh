#!/usr/bin/env bash
# herd-resolve.sh <slug> — spin up an isolated, test-gated CONFLICT RESOLVER agent in its own
# herdr tab for an EXISTING feature worktree whose PR has gone CONFLICTING.
#
# Unlike herd-feature.sh this does NOT create a worktree — it operates on the worktree that
# already exists at $WORKTREES_DIR/<slug> (the conflicting PR's branch is already checked out
# there). The tab is laid out as [ live app preview | Claude resolver-agent ] when a preview
# command is configured, else just the resolver pane.
#
# The resolver merges the default branch in, resolves MECHANICAL conflicts, runs the smoke test
# ($SMOKE_CMD) + healthcheck, and on a green pass pushes the feature branch (NEVER force, NEVER
# the default branch) so the PR flips CLEAN and the auto-merge watcher merges it. It ESCALATES
# semantically-ambiguous conflicts to the human instead of guessing — it never blind-merges.
#
# Env overrides:
#   HERD_CLAUDE_FLAGS   flags passed to claude (default: --dangerously-skip-permissions)
#   HERD_NO_APP=1       skip the app-preview pane
#
# Standalone:
#   herd-resolve.sh dividend-history
# Or driven by the /coordinator skill / the watcher when a PR is CONFLICTING.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
SLUG="${1:?usage: herd-resolve.sh <slug>   (slug = the existing worktree under the worktrees dir)}"
DIR="$WORKTREES_DIR/$SLUG"
CLAUDE_FLAGS="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"
_WS_ID="$(herd_resolve_workspace_id)"

# 1. The worktree must already exist — herd-resolve.sh resolves IN PLACE, it never creates one.
#    A herdr tab rooted in a non-existent dir is worse than no tab at all: bail loud.
if [ ! -d "$DIR" ]; then
  echo "❌ no worktree at $DIR — herd-resolve.sh resolves an EXISTING feature worktree; it does not create one." >&2
  echo "   (Is the slug right? 'git worktree list' shows the live worktrees.)" >&2
  exit 1
fi
if [ ! -e "$DIR/.git" ]; then
  echo "❌ $DIR exists but isn't a git worktree (no .git) — refusing to resolve there." >&2
  exit 1
fi

# 2. New herdr tab rooted in the EXISTING worktree; grab tab id + root pane id.
created=$(herdr tab create ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$DIR" --label "resolve·$SLUG" --no-focus)
read -r TAB ROOT < <(printf '%s' "$created" | python3 -c \
  'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' 2>/dev/null || true)
if [ -z "$TAB" ] || [ -z "$ROOT" ]; then
  echo "❌ herdr unavailable (could not create a resolve tab for '$SLUG'); worktree is at $DIR but no panes were launched." >&2
  exit 1
fi

# 3. RIGHT pane: the Claude resolver agent (yolo by default). The STANDARD resolver task is its
#    opening prompt — fixed, not free-form: the coordinator does not hand-tune it. The smoke step
#    is the project's $SMOKE_CMD (omitted from the prompt when unset → resolver relies on the
#    healthcheck alone).
SMOKE_STEP=""
[ -n "$SMOKE_CMD" ] && SMOKE_STEP="the project smoke test ($SMOKE_CMD) AND "
TASK="You are a CONFLICT RESOLVER for one feature worktree. Goal: make this branch cleanly mergeable into the default branch WITHOUT changing either side's intent. Steps: (1) git fetch $HERD_REMOTE; merge $DEFAULT_BRANCH into this branch (git merge $DEFAULT_BRANCH). (2) If there are conflicts, resolve them PRESERVING BOTH sides' intent — mechanical conflicts (imports, adjacent edits, a helper that moved/was extracted, formatting) you resolve directly. (3) After resolving, run ${SMOKE_STEP}bash $HERE/healthcheck.sh on this worktree ($DIR); both must pass. (4) If everything resolves cleanly AND the checks are green AND you are confident the merge preserved both intents: commit the merge and git push (normal push to the feature branch, NEVER force, NEVER push to $HERD_BRANCH_NAME). The PR will then flip to CLEAN and the auto-merge watcher will merge it. (5) ESCALATION — if any conflict is SEMANTICALLY AMBIGUOUS (the same function/logic was changed two different ways and the correct combined result is unclear), DO NOT GUESS: abort the merge (git merge --abort), post a PR comment via gh pr comment summarizing both sides and what needs a human decision, print a clear line starting with 'ESCALATE:' explaining the ambiguity, and STOP. Never edit $BACKLOG_FILE. Never touch $HERD_BRANCH_NAME directly."
herdr agent start "resolve·$SLUG" ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$DIR" --tab "$TAB" --split right --no-focus -- claude $CLAUDE_FLAGS "$TASK"

# 4. LEFT pane (the tab's root): live app preview on a free port — only when configured.
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
    echo "⚠️  No free port in 8501-8599 — skipping the app-preview pane for 'resolve·$SLUG'." >&2
  fi
fi

echo "🔀 Resolver agent 'resolve·$SLUG' running (claude $CLAUDE_FLAGS) in herdr tab $TAB   dir: $DIR"
echo "   task: merge $DEFAULT_BRANCH → resolve mechanical conflicts → smoke + healthcheck → push (never force/default branch)"
[ -n "$PORT" ] && echo "   🌐 app preview: http://localhost:$PORT   (hot-reloads as the agent resolves)"
echo "   jump to it:   herdr agent focus resolve·$SLUG"
echo "   on a green resolve it pushes the branch → PR flips CLEAN → the auto-merge watcher merges it."
echo "   on a SEMANTICALLY-AMBIGUOUS conflict it aborts, comments on the PR, prints 'ESCALATE: …', and stops for a human."
