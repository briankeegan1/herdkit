#!/usr/bin/env bash
# coordinator.sh — (re)launch the coordinator herdr tab as a 2-pane control room:
#
#     [  live BACKLOG    |   coordinator Claude running the /coordinator skill  ]
#       (left, always on)    (right, prompts you: implement / browse / add)
#
# Idempotent: closes this project's existing coordinator tab first, so you can re-run it anytime to get a
# fresh control room. The left pane stays pinned to the backlog; the right pane is where you drive
# work and spin up feature sub-agents. The 🐑 herd-watch console is pinned below the coordinator
# (auto-merges ready PRs, healthcheck + review gated) unless suppressed.
#
# Env knobs:
#   HERD_NO_WATCH=1        skip the 🐑 herd-watch console pane
#   AGENT_WATCH_DRYRUN=1   watch shows status but never auto-merges
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
REPO="$PROJECT_ROOT"

# 0. Fail fast if herdr is missing or its CLI/JSON contract has skewed — otherwise the very first
#    `herdr tab create` below blows up cryptically.
. "$HERE/herd-preflight.sh"
herd_preflight || exit 1

# 1. Close THIS project's existing coordinator tab (clean relaunch). Matched on the project-scoped
#    label so we never close another project's coordinator sharing this herdr.
existing=$(herdr tab list | LABEL="$HERD_TAB_COORDINATOR" python3 -c \
  'import sys,json,os; d=json.load(sys.stdin); print(next((t["tab_id"] for t in d["result"]["tabs"] if t.get("label")==os.environ["LABEL"]), ""))')
[ -n "$existing" ] && herdr tab close "$existing" >/dev/null 2>&1 || true

# 2. Fresh coordinator tab; grab its tab id + root pane id + workspace id.
created=$(herdr tab create --cwd "$REPO" --label "$HERD_TAB_COORDINATOR" --focus)
read -r TAB ROOT WS < <(printf '%s' "$created" | python3 -c \
  'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"], d["tab"]["workspace_id"])')

# Name the workspace for this project.
herdr workspace rename "$WS" "$WORKSPACE_NAME" >/dev/null 2>&1 || true

# 3. Left (root) pane = pinned live backlog viewer.
herdr pane run "$ROOT" "bash $HERE/backlog-view.sh" >/dev/null

# 4. Right pane = coordinator Claude, auto-running the generated coordinator skill.
started=$(herdr agent start "$HERD_AGENT_COORDINATOR" --cwd "$REPO" --tab "$TAB" --split right -- claude "$COORDINATOR_CMD")
AGENT_PANE=$(printf '%s' "$started" | python3 -c \
  'import sys,json; print(json.load(sys.stdin)["result"]["agent"]["pane_id"])')

# 5. Pin the live herd-watch console BELOW the coordinator (auto-merges ready PRs, gated). Skip
#    with HERD_NO_WATCH=1; status-only with AGENT_WATCH_DRYRUN=1.
if [ "${HERD_NO_WATCH:-}" != "1" ]; then
  split=$(herdr pane split "$AGENT_PANE" --direction down --ratio 0.72 \
            --cwd "$REPO" --env "AGENT_WATCH_DRYRUN=${AGENT_WATCH_DRYRUN:-0}" --no-focus)
  WPANE=$(printf '%s' "$split" | python3 -c \
    'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
  herdr pane run "$WPANE" "bash $HERE/herd-watch.sh" >/dev/null
  echo "🛰  Coordinator up:  [ $BACKLOG_FILE | $COORDINATOR_CMD agent ⟂ 🐑 herd watch ]   tab $TAB"
else
  echo "🛰  Coordinator up:  [ $BACKLOG_FILE | $COORDINATOR_CMD agent ]   tab $TAB"
fi

echo "   jump to it:   herdr agent focus $HERD_AGENT_COORDINATOR"
