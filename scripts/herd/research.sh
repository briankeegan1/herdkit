#!/usr/bin/env bash
# research.sh "<question>" — ENQUEUE a READ-ONLY repo research question and make sure exactly
# ONE async research drainer is running. The coordinator calls this and returns to you instantly,
# capturing the printed REQ_ID so it can fetch the report later with research-get.sh.
#
# Model: every request is a file in $WORKTREES_DIR/research-queue/. A single drainer (a Claude
# named "researcher-<WORKSPACE_NAME>") fans out Explore subagents over the repo, writes a per-request findings
# report, and reports back peripherally — a herdr notification + the .research-reports inbox.
# Fire several questions in a row; the one drainer batches through them.
#
# UNLIKE the scribe, research is READ-ONLY: there is NO git pull/commit/branch/push and the main
# checkout is never mutated. Each request gets its OWN id + its OWN report file
# (research-reports/<id>.md) that the coordinator reads back — nothing is shared or committed.
# Concurrency-safe: atomic per-file claim + a spawn lock so only one drainer ever starts.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
# Runtime driver shim: route the researcher drainer launch through herd_driver_launch_agent so
# HERD_DRIVER=headless spawns a detached researcher; herdr-claude emits the identical argv below.
# shellcheck source=/dev/null
. "$HERE/driver.sh"
REPO="$PROJECT_ROOT"
TREES="${RESEARCH_TREES:-$WORKTREES_DIR}"
Q="${RESEARCH_QUEUE:-$TREES/research-queue}"
REPORTS="${RESEARCH_REPORTS:-$TREES/research-reports}"
REQ="${1:?usage: research.sh \"<question>\"}"
CLAUDE_FLAGS="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"
# Read-only repo research — fan-out Explore + concise synthesis. Default to the configured
# research model (Sonnet); override with RESEARCH_MODEL=… for a specific run.
RESEARCH_MODEL="${RESEARCH_MODEL:-$MODEL_RESEARCH}"
_WS_ID="$(herd_resolve_workspace_id)"

# 1. Generate a short request id. Same stem as the queue filename so the drainer can derive the
#    id straight from the claimed file, and the coordinator can fetch research-reports/<id>.md.
REQ_ID="$(date +%s)-$$-$RANDOM"

# 2. Enqueue atomically (temp then mv); name sorts FIFO.
mkdir -p "$Q"
tmp=$(mktemp "$Q/.tmp.XXXXXX"); printf '%s\n' "$REQ" > "$tmp"
mv "$tmp" "$Q/$REQ_ID.req"

# 3. Serialize the check-then-spawn below. Without this, two concurrent research.sh calls can
#    both observe "no researcher running" and each start a drainer. Prefer flock(1); fall back to
#    an atomic mkdir mutex on systems without it. The lock is held only across check+spawn.
LOCK="$TREES/.research-spawn.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock 9   # auto-released when fd 9 closes at script exit
else
  lockdir="$LOCK.d"
  tries=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    if [ -z "$(find "$lockdir" -prune -mmin -1 2>/dev/null)" ]; then
      rmdir "$lockdir" 2>/dev/null || true
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -ge 100 ] && break   # ~10s waited; proceed rather than hang forever
    sleep 0.1
  done
  trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT
fi

# 4. Always tell the caller where the answer lands + the id to fetch it (printed BEFORE the spawn
#    so the coordinator has it even if step 5 short-circuits on an already-running drainer).
echo "🔎 queued: $REQ"
echo "REQ_ID $REQ_ID"
echo "report → $REPORTS/$REQ_ID.md  (fetch with: research-get.sh $REQ_ID)"

# 5. Is THIS project's researcher drainer already running? Match by name AND workspace_id (when
#    known) so a researcher in a different workspace is not reused. herdr agent list has no
#    --workspace flag; filter client-side via the workspace_id field each agent record carries.
if herdr agent list 2>/dev/null | NAME="$HERD_AGENT_RESEARCHER" WS="$_WS_ID" python3 -c '
import sys,json,os
ws=os.environ.get("WS","")
sys.exit(0 if any(
  x.get("name")==os.environ["NAME"] and (not ws or x.get("workspace_id","")==ws)
  for x in json.load(sys.stdin)["result"]["agents"]
) else 1)'; then
  echo "🔎 researcher already running — it will drain this."; exit 0
fi

# 6. Otherwise spawn the single drainer.
PROMPT=$(cat <<EOF
You are the RESEARCH DRAINER (queue drainer) for READ-ONLY repo research. Drain the research
queue, one request at a time. You NEVER edit, commit, branch, or push anything — your only
output is a findings report per request. Repeat this loop:

1. Run:  bash $HERE/research-step.sh next
   • It prints "CLAIMED <path>" then the REQ_ID then the question text, OR "EMPTY".
   • If EMPTY: run  bash $HERE/research-step.sh finish . STOP -> end your turn (you're done).
     MORE -> go back to step 1.
2. Research the question READ-ONLY against $REPO. Dispatch your OWN Explore subagent(s) to do the
   reading and fan out (don't read piles of files yourself). Do NOT modify the repo or its working
   dir in any way.
3. Write a CONCISE, structured markdown findings report to a temp file (e.g. mktemp): lead with a
   direct ANSWER, then supporting points with file:line references. Cite locations, do NOT dump
   file contents. Keep it tight — the coordinator reads this back, it is not a code review.
4. Run:  bash $HERE/research-step.sh report <claimed_path> <tempfile>
   (this files the report at $REPORTS/<id>.md, notifies, and clears the claim).
5. Go to step 1.

Use research-step.sh for all queue/report mechanics. Read-only always: never write to $REPO,
never git, never switch branches.
EOF
)
created=$(herdr tab create ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$REPO" --label "$HERD_AGENT_RESEARCHER" --no-focus)
TAB=$(printf '%s' "$created" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["tab"]["tab_id"])')
herd_driver_launch_agent \
  name="$HERD_AGENT_RESEARCHER" workspace="$_WS_ID" cwd="$REPO" tab="$TAB" env="RESEARCH_TAB=$TAB" \
  model="$RESEARCH_MODEL" flags="$CLAUDE_FLAGS" pointer="$PROMPT"
echo "🔎 researcher drainer dispatched (tab $TAB). Coordinator is free; fetch the report with research-get.sh $REQ_ID."
