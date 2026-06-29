#!/usr/bin/env bash
# app-monitor.sh <port> — the left-pane app preview for a feature worktree.
#
# Runs $APP_PREVIEW_CMD (a server, on :<port>) AND shows a SELF-CLEARING status panel that
# reflects the CURRENT code — not a scrollback pile of old tracebacks. It re-runs the healthcheck
# only when a tracked file changes, so it's quiet/cheap when idle and gives a true "is it clean
# right now?" verdict after each save. Run from the worktree root (cwd = the worktree).
#
# Requires APP_PREVIEW_CMD in .herd/config; herd-feature.sh only launches this when one is set.
set -u
PORT="${1:?usage: app-monitor.sh <port>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
DIR="$(pwd)"
LOG="$DIR/.app-server.log"

[ -n "$APP_PREVIEW_CMD" ] || { echo "app-monitor: no APP_PREVIEW_CMD configured"; exit 1; }

# The preview server in the background — this is what the browser renders. Dies with the pane.
# The "--server.port / --server.headless" flags follow a common dev-server convention; a project
# whose preview command takes the port differently can wrap it inside its own APP_PREVIEW_CMD.
# shellcheck disable=SC2086
$APP_PREVIEW_CMD --server.port "$PORT" --server.headless true >"$LOG" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null' EXIT INT TERM

# newest mtime across tracked files — changes whenever the sub-agent edits the worktree.
newest() { git ls-files -z 2>/dev/null | xargs -0 stat -f '%m' 2>/dev/null | sort -rn | head -1; }

last_sig=""
verdict="⏳ first check running…"
while true; do
  sig="$(newest)"
  if [ "$sig" != "$last_sig" ]; then
    verdict="$(bash "$HERE/healthcheck.sh" "$DIR" --oneline 2>/dev/null)"
    last_sig="$sig"
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/" 2>/dev/null || echo 000)
  srv=$([ "$code" = "200" ] && echo $'\033[32m🟢 serving\033[0m' || echo $'\033[31m🔴 starting/down\033[0m')
  clear
  printf '\033[1;36m🩺 app preview · :%s\033[0m   %b\n' "$PORT" "$srv"
  printf '\033[2mhttp://localhost:%s\033[0m\n\n' "$PORT"
  printf '%s\n' "$verdict"
  printf '\n\033[2m(re-checks on every tracked-file save · this panel self-refreshes — no stale errors)\033[0m\n'
  sleep 2
done
