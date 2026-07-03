#!/usr/bin/env bash
# herd-watch.sh — launcher for the live "herd watch" status console (agent-watch.sh).
#
# Runs the watcher in the foreground of the current pane. It discovers active feature worktrees,
# renders one compact line per feature, and AUTO-MERGES PRs that pass the healthcheck + review
# gate (full-auto, safety-railed — see agent-watch.sh), unless WATCHER_AUTOMERGE=false.
#
# Pane placement is intentionally OUT OF SCOPE here: the coordinator wires the actual herdr pane
# (e.g. splitting this BELOW the coordinator pane) when it launches the control room. To run it in
# a dedicated pane yourself:
#
#     herdr pane run <pane_id> "bash scripts/herd/herd-watch.sh"
#
# Dry-run (renders + gates but performs NO merge/remove/scribe/ff):
#
#     AGENT_WATCH_DRYRUN=1 bash scripts/herd/herd-watch.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# The launch-binding banner + foreign-cwd guard (issue #60) runs inside agent-watch.sh, which this
# execs into (same process): it sets HERD_REQUIRE_PROJECT_CONFIG, prints the resolved
# WORKSPACE_NAME/PROJECT_ROOT banner, and refuses a foreign $PWD unless HERD_ALLOW_FOREIGN_CWD=1.
exec bash "$HERE/agent-watch.sh"
