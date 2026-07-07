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
# Runtime driver shim: route the scribe drainer launch through herd_driver_launch_agent so
# HERD_DRIVER=headless spawns a detached scribe; herdr-claude emits the identical argv below.
# shellcheck source=/dev/null
. "$HERE/driver.sh"
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

# 4. Otherwise spawn the single drainer. The prompt is BACKEND-AGNOSTIC (issue #139): it is emitted
#    IDENTICALLY regardless of the spawn-time SCRIBE_BACKEND. scribe-step.sh 'next' reports the
#    ACTIVE backend (resolved fresh each drain) on a "BACKEND <name>" line and the drainer branches
#    on THAT per request — so a mid-session SCRIBE_BACKEND flip is honored on the very next drained
#    request instead of being drained in the stale spawn-time mode (the old junk 'no-op:' issues).
PROMPT=$(cat <<EOF
You are the BACKLOG SCRIBE (queue drainer). Drain the backlog queue, one request at a time.
Repeat this loop:

1. Run:  bash $HERE/scribe-step.sh next
   • It prints "CLAIMED <path>", then "BACKEND <name>" (the ACTIVE backend, read NOW), then the
     request text (repo already pulled & current). OR it prints "EMPTY".
   • If EMPTY: run  bash $HERE/scribe-step.sh finish . STOP -> end your turn (done).
     MORE -> go back to step 1.
2. Apply the request via the ACTIVE backend from the "BACKEND <name>" line just printed. The backend
   can change mid-session, so ALWAYS use the one printed for THIS request — never an earlier value:
   • BACKEND is "file": edit ONLY $REPO/$BACKLOG_FILE. This covers BOTH new items AND state changes —
     marking an item done/in-progress/canceled is just editing its 🔜/🚧/✅ emoji (and, when done,
     moving it under "## Recently shipped"). Need to look into the repo first? dispatch an Explore
     subagent (do not read piles of files yourself). Make a TARGETED, privacy-safe edit. Write prose
     paragraphs as ONE physical line (no hard wraps mid-paragraph) so the glow viewer and GitHub both
     reflow them to the pane width — wrapped lines miscount emoji width and break too early. Reserve
     line breaks for between list items and paragraphs. If an Edit fails because lines moved (the user
     edited concurrently), re-read and re-apply — never clobber their change.
     SHIPPED (✅) items: never DELETE a shipped entry to make room. If a request asks you to cap the
     "Recently shipped" list or drop the oldest shipped items, just prepend the new ✅ entry and leave
     the rest in place — the commit step AUTOMATICALLY rotates shipped entries beyond the most recent
     ~10 into $REPO/${BACKLOG_FILE%.md}.archive.md (which the coordinator and builders never read).
     Do not create or edit that archive file yourself; the commit step owns it.
     Then run:  bash $HERE/scribe-step.sh commit <path> "<short summary>"
   • BACKEND is anything else (github/linear/changelog/…): do NOT edit any file. First CLASSIFY the
     request into exactly ONE of these, then run the matching verb — NEVER file a new issue for a
     request that is not actually a new backlog item (that mis-file is the junk-issue bug):
       – ADD / create / file a NEW backlog item →
           The backend takes the FIRST LINE of the text as the tracker title and keeps the WHOLE
           text as the description. So make sure the text STARTS WITH A SHORT ONE-LINE TITLE
           (< 80 chars). If the request is a run-on paragraph with no title line, SYNTHESIZE one:
           write a concise title as the first line, then the full request as the body beneath it —
           never pass a whole paragraph as the first line (that files a giant title duplicated in
           the description). Then run:
           bash $HERE/scribe-step.sh add-item "<claimed_path>" "<text from request>"
       – Mark an EXISTING item done / in-progress / canceled — INCLUDING the watcher
         "Reconcile: PR #N merged — find the backlog item…" and any reap/close request →
           bash $HERE/scribe-step.sh update-state "<claimed_path>" "<ref>" "<state>"
         <ref> = the item identifier when the request names one (e.g. HERD-22, or a bare issue number
         for the github backend), otherwise a distinctive title phrase to match. <state> = one of
         done | in-progress | canceled. For a reconcile request that gives only a PR number, work out
         the matching item identifier/title from the request text; if you cannot confidently pin it to
         ONE item, SKIP (next bullet) — never guess, never file a new issue.
       – ANYTHING you cannot map to an add or a state change →
           bash $HERE/scribe-step.sh skip "<claimed_path>" "<one-line reason>"
         skip records a loud line in the scribe report and files NOTHING. When in doubt between
         update-state and skip, prefer skip over add-item — a wrongly-filed issue is the exact bug.
3. Go to step 1.

Use scribe-step.sh for all git/queue/report mechanics. Never merge, switch branches, or edit any
file other than $BACKLOG_FILE (and only when the active backend is "file").
EOF
)
created=$(herdr tab create ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$REPO" --label "$HERD_AGENT_SCRIBE" --no-focus)
TAB=$(printf '%s' "$created" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["tab"]["tab_id"])')
herd_driver_launch_agent \
  name="$HERD_AGENT_SCRIBE" workspace="$_WS_ID" cwd="$REPO" tab="$TAB" env="SCRIBE_TAB=$TAB" \
  model="$SCRIBE_MODEL" flags="$CLAUDE_FLAGS" pointer="$PROMPT"
echo "✍️  scribe drainer dispatched (tab $TAB). Coordinator is free; watch for the JUST SCRIBED banner."
