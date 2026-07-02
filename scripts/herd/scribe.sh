#!/usr/bin/env bash
# scribe.sh "<backlog change>" — ENQUEUE a backlog change and make sure exactly ONE async
# scribe drainer is running. The coordinator calls this and returns to you instantly.
#
# Model: every request is a file in $WORKTREES_DIR/backlog-queue/. A single drainer (a Claude
# named "scribe-<WORKSPACE_NAME>") edits $BACKLOG_FILE, commits straight to the default branch, and reports back
# peripherally — live "✍️ JUST SCRIBED" banner + a herdr notification + the .scribe-reports
# inbox. Fire several requests in a row; the one drainer batches through them. Concurrency-safe:
# atomic per-file claim, git push serializes writes, the user's manual edits survive via
# pull + fresh-read + the Edit tool's exact-match.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
REPO="$PROJECT_ROOT"
TREES="$WORKTREES_DIR"
Q="$TREES/backlog-queue"
REQ="${1:?usage: scribe.sh \"<backlog change>\"}"
CLAUDE_FLAGS="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"
# The scribe only edits one markdown file + commits — a light, mechanical job. Default to the
# configured scribe model (Sonnet); override with SCRIBE_MODEL=… for a specific run.
SCRIBE_MODEL="${SCRIBE_MODEL:-$MODEL_SCRIBE}"
_WS_ID="$(herd_resolve_workspace_id)"

# 1. Enqueue atomically (temp then mv); name sorts FIFO.
mkdir -p "$Q"
tmp=$(mktemp "$Q/.tmp.XXXXXX"); printf '%s\n' "$REQ" > "$tmp"
mv "$tmp" "$Q/$(date +%s)-$$-$RANDOM.req"
echo "📥 queued: $REQ"

# 2. Serialize the check-then-spawn below. Without this, two concurrent scribe.sh calls can
#    both observe "no scribe running" and each start a drainer. Prefer flock(1); fall back to an
#    atomic mkdir mutex on systems without it (stock macOS has no flock). The lock is held only
#    across the cheap check+spawn and released when this script exits.
LOCK="$TREES/.scribe-spawn.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock 9   # auto-released when fd 9 closes at script exit
else
  lockdir="$LOCK.d"
  tries=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    # Break an abandoned lock: a prior run that died without releasing leaves a dir untouched
    # for a while. Spawn is sub-second, so >1 min old is certainly stale.
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

# 3. Is THIS project's scribe drainer already running? Match by name AND workspace_id (when known)
#    so a scribe in a different workspace is not reused. herdr agent list has no --workspace flag;
#    filter client-side via the workspace_id field each agent record already carries.
if herdr agent list 2>/dev/null | NAME="$HERD_AGENT_SCRIBE" WS="$_WS_ID" python3 -c '
import sys,json,os
ws=os.environ.get("WS","")
sys.exit(0 if any(
  x.get("name")==os.environ["NAME"] and (not ws or x.get("workspace_id","")==ws)
  for x in json.load(sys.stdin)["result"]["agents"]
) else 1)'; then
  echo "✍️  scribe already running — it will drain this."; exit 0
fi

# 4. Otherwise spawn the single drainer. The prompt is backend-conditional: the file backend
#    edits $BACKLOG_FILE directly; an API/changelog backend instead calls scribe-step.sh
#    add-item so the step script dispatches to the backend without any file editing.
if [ "$SCRIBE_BACKEND" = "file" ]; then
PROMPT=$(cat <<EOF
You are the BACKLOG SCRIBE (queue drainer). Drain the backlog queue, one request at a time.
Repeat this loop:

1. Run:  bash $HERE/scribe-step.sh next
   • It prints "CLAIMED <path>" then the request text (repo already pulled & current), OR "EMPTY".
   • If EMPTY: run  bash $HERE/scribe-step.sh finish . STOP -> end your turn (done).
     MORE -> go back to step 1.
2. Apply the request, editing ONLY $REPO/$BACKLOG_FILE. Need to look into the repo first? dispatch
   an Explore subagent (do not read piles of files yourself). Make a TARGETED, privacy-safe edit.
   Write prose paragraphs as ONE physical line (no hard wraps mid-paragraph) so the glow viewer
   and GitHub both reflow them to the pane width — wrapped lines miscount emoji width and break
   too early. Reserve line breaks for between list items and paragraphs.
   If an Edit fails because lines moved (the user edited concurrently), re-read and re-apply —
   never clobber their change.
   SHIPPED (✅) items: never DELETE a shipped entry to make room. If a request asks you to cap the
   "Recently shipped" list or drop the oldest shipped items, just prepend the new ✅ entry and leave
   the rest in place — the commit step (step 3) AUTOMATICALLY rotates shipped entries beyond the most
   recent ~10 into $REPO/${BACKLOG_FILE%.md}.archive.md (which the coordinator and builders never
   read). Do not create or edit that archive file yourself; the commit step owns it.
3. Run:  bash $HERE/scribe-step.sh commit <path> "<short summary>"
4. Go to step 1.

Only touch $BACKLOG_FILE; use scribe-step.sh for all git/queue/report mechanics. Never merge,
switch branches, or edit any other file.
EOF
)
else
PROMPT=$(cat <<EOF
You are the BACKLOG SCRIBE (queue drainer). Drain the backlog queue, one request at a time.
Repeat this loop:

1. Run:  bash $HERE/scribe-step.sh next
   • It prints "CLAIMED <path>" then the request text (repo already pulled & current), OR "EMPTY".
   • If EMPTY: run  bash $HERE/scribe-step.sh finish . STOP -> end your turn (done).
     MORE -> go back to step 1.
2. Call:  bash $HERE/scribe-step.sh add-item "<claimed_path>" "<text from request>"
   Do NOT edit any files — the step script dispatches to the $SCRIBE_BACKEND backend.
3. Go to step 1.

Use scribe-step.sh for all mechanics. Never edit files or switch branches.
EOF
)
fi
created=$(herdr tab create ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$REPO" --label "$HERD_AGENT_SCRIBE" --no-focus)
TAB=$(printf '%s' "$created" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["tab"]["tab_id"])')
herdr agent start "$HERD_AGENT_SCRIBE" ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$REPO" --tab "$TAB" --no-focus --env "SCRIBE_TAB=$TAB" -- claude --model "$SCRIBE_MODEL" $CLAUDE_FLAGS "$PROMPT"
echo "✍️  scribe drainer dispatched (tab $TAB). Coordinator is free; watch for the JUST SCRIBED banner."
