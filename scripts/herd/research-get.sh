#!/usr/bin/env bash
# research-get.sh <id> — coordinator helper to fetch a research finding by its REQ_ID (the id
# research.sh printed when the question was enqueued). Prints the report if the drainer has filed
# it, else "PENDING" (still in the queue or being researched — poll again shortly).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
TREES="${RESEARCH_TREES:-$WORKTREES_DIR}"
REPORTS="${RESEARCH_REPORTS:-$TREES/research-reports}"
ID="${1:?usage: research-get.sh <id>}"
f="$REPORTS/$ID.md"
if [ -f "$f" ]; then cat "$f"; else echo "PENDING"; fi
