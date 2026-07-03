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
#
# The extra launch args (port + headless) are a CONFIGURABLE TEMPLATE, not hardcoded: force-appending
# one web framework's flags to whatever the consumer set CRASHES any command that doesn't accept them
# (a CLI, a Go/Node/Rust server, `java -jar app.jar`). APP_PREVIEW_SERVER_ARGS is the arg string
# appended to $APP_PREVIEW_CMD, with a literal {port} token substituted by the chosen port; its DEFAULT
# reproduces today's dev-server flags EXACTLY, so an existing web-app project is byte-for-byte
# unchanged. Set it to "" in .herd/config for a command that needs no injected flags (it reads $PORT
# itself or takes the port another way). See docs/external-consumer-audit.md "Leak C".
# Read INLINE with a default here (deliberately NOT declared in herd-config.sh / capabilities.tsv);
# FOLLOW-UP: document APP_PREVIEW_SERVER_ARGS in templates/capabilities.tsv (owned by another PR).
_APP_SERVER_ARGS="${APP_PREVIEW_SERVER_ARGS-"--server.port {port} --server.headless true"}"
_APP_SERVER_ARGS="${_APP_SERVER_ARGS//\{port\}/$PORT}"
# shellcheck disable=SC2086
$APP_PREVIEW_CMD $_APP_SERVER_ARGS >"$LOG" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null' EXIT INT TERM

# newest mtime across tracked files — changes whenever the sub-agent edits the worktree.
# stat mtime flag: GNU/Linux uses -c %Y; BSD/macOS uses -f %m.
if stat --version 2>/dev/null | grep -q GNU; then
  _STAT_MTIME=(-c %Y)
else
  _STAT_MTIME=(-f %m)
fi
newest() { git ls-files -z 2>/dev/null | xargs -0 stat "${_STAT_MTIME[@]}" 2>/dev/null | sort -rn | head -1; }

# ── Health probe (CONFIGURABLE — see docs/external-consumer-audit.md "Leak C") ───────────────────
# "Is it up?" is no longer a hardcoded HTTP GET /. Precedence, highest first:
#   • APP_PREVIEW_HEALTH_CMD  — run it (with PORT exported); exit 0 = 🟢 serving. For a CLI / gRPC /
#                               non-HTTP or non-root-path server that a curl-GET-/ can never verify.
#   • APP_PREVIEW_HEALTH_PATH — curl http://localhost:$PORT<path>; HTTP 200 = 🟢 serving. DEFAULT "/"
#                               reproduces today's probe, so an existing web app is unchanged.
#   • neither (path set to "" AND no cmd) — health UNKNOWN → ⚪, NOT 🔴. "No probe configured" must
#                               not masquerade as "down" and paint a healthy non-HTTP preview red.
# APP_PREVIEW_HEALTH_PATH uses ${x-default} (assign-if-UNSET) so an explicit empty value DISABLES the
# HTTP probe rather than snapping back to "/". Read INLINE with defaults here (NOT in herd-config.sh /
# capabilities.tsv); FOLLOW-UP: document these keys in templates/capabilities.tsv (owned by another PR).
_HEALTH_CMD="${APP_PREVIEW_HEALTH_CMD-}"
_HEALTH_PATH="${APP_PREVIEW_HEALTH_PATH-/}"

last_sig=""
verdict="⏳ first check running…"
while true; do
  sig="$(newest)"
  if [ "$sig" != "$last_sig" ]; then
    verdict="$(bash "$HERE/healthcheck.sh" "$DIR" --oneline 2>/dev/null)"
    last_sig="$sig"
  fi
  if [ -n "$_HEALTH_CMD" ]; then
    if PORT="$PORT" bash -c "$_HEALTH_CMD" >/dev/null 2>&1; then
      srv=$'\033[32m🟢 serving\033[0m'
    else
      srv=$'\033[31m🔴 starting/down\033[0m'
    fi
  elif [ -n "$_HEALTH_PATH" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT$_HEALTH_PATH" 2>/dev/null || echo 000)
    srv=$([ "$code" = "200" ] && echo $'\033[32m🟢 serving\033[0m' || echo $'\033[31m🔴 starting/down\033[0m')
  else
    srv=$'\033[2m⚪ health unknown (no probe configured)\033[0m'
  fi
  clear
  printf '\033[1;36m🩺 app preview · :%s\033[0m   %b\n' "$PORT" "$srv"
  printf '\033[2mhttp://localhost:%s\033[0m\n\n' "$PORT"
  printf '%s\n' "$verdict"
  printf '\n\033[2m(re-checks on every tracked-file save · this panel self-refreshes — no stale errors)\033[0m\n'
  sleep 2
done
