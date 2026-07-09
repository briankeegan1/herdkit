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
# Drainer singleton liveness (HERD-109 / HERD-122): herd_drainer_* let the singleton check below tell a
# HUNG-but-listed drainer from a live one, and CORROBORATE liveness before reclaiming so a fresh/live
# drainer is never falsely declared hung.
# shellcheck source=/dev/null
. "$HERE/drainer-liveness.sh"
# journal.sh gives the liveness path its forensic record (HERD-122): a refused reclaim, a genuine
# reclaim, and a failed respawn each journal instead of dumping a raw driver error. Best-effort.
# shellcheck source=/dev/null
. "$HERE/journal.sh"
# Supervised-process contract (HERD-193): record this drainer singleton's OWNER / DEADLINE / LIVENESS
# / RETIRE at spawn so the watcher's per-tick sweep can surface a drainer that has gone silent past
# DRAINER_HEARTBEAT_TIMEOUT — the SAME window the reclaim gate above already uses, integrated rather
# than duplicated. Pure library; inert while LIFECYCLE_CONTRACTS=off (default).
# shellcheck source=/dev/null
. "$HERE/lifecycle.sh"
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
#    filter client-side via the workspace_id field each agent record already carries. Capture the
#    roster ONCE so the liveness corroboration below reads the SAME snapshot (no second call / TOCTOU).
HEARTBEAT="$TREES/.scribe.heartbeat"
AGENTS_JSON="$(herd_driver_agent_list_json 2>/dev/null || echo '{}')"
if printf '%s' "$AGENTS_JSON" | NAME="$HERD_AGENT_SCRIBE" WS="$_WS_ID" python3 -c '
import sys,json,os
ws=os.environ.get("WS","")
try:
  agents=json.load(sys.stdin)["result"]["agents"]
except Exception:
  agents=[]
sys.exit(0 if any(
  x.get("name")==os.environ["NAME"] and (not ws or x.get("workspace_id","")==ws)
  for x in agents
) else 1)'; then
  # A drainer of this name is LISTED. Normally we short-circuit (it will drain this). But a listed
  # drainer can be HUNG: its heartbeat ($HEARTBEAT, written by scribe-step.sh on every drain step)
  # goes stale. HERD-109 reclaimed on stale-heartbeat alone — but that FALSE-POSITIVED a fresh,
  # seconds-old drainer whose leftover heartbeat (from a prior drainer's lifetime) was ancient, and
  # then failed the respawn with agent_name_taken (HERD-122). So a stale heartbeat now only reclaims
  # once CORROBORATED: a working/idle live agent is never hung regardless of heartbeat age. Reclaim
  # ONLY on positive death (dead pid / bare pane + stale heartbeat); otherwise keep the legacy path.
  LIVE="$(herd_drainer_live_status "$HERD_AGENT_SCRIBE" "$AGENTS_JSON")"
  if herd_drainer_should_reclaim "$HEARTBEAT" "$DRAINER_HEARTBEAT_TIMEOUT" "$LIVE"; then
    echo "⚠️  scribe drainer is DEAD (no heartbeat for >${DRAINER_HEARTBEAT_TIMEOUT}s and its process is gone) — reclaiming the singleton and spawning a fresh drainer (per-request atomic claim prevents double-draining)."
    journal_append drainer_reclaimed component scribe agent "$HERD_AGENT_SCRIBE" live_status "$LIVE" timeout "$DRAINER_HEARTBEAT_TIMEOUT"
    lifecycle_retire scribe-drainer "$HERD_AGENT_SCRIBE" reclaimed
  elif herd_drainer_hung "$HEARTBEAT" "$DRAINER_HEARTBEAT_TIMEOUT"; then
    # Heartbeat is stale but the agent is LIVE (working/idle) or its death can't be confirmed — refuse
    # the reclaim and journal it (no-false-red). The live drainer will drain this request.
    echo "✍️  scribe already running (heartbeat stale but the agent is live/${LIVE} — not hung); it will drain this."
    journal_append drainer_reclaim_refused component scribe agent "$HERD_AGENT_SCRIBE" live_status "$LIVE" timeout "$DRAINER_HEARTBEAT_TIMEOUT"
    exit 0
  else
    echo "✍️  scribe already running — it will drain this."; exit 0
  fi
fi

# 4. Otherwise spawn the single drainer. The prompt is BACKEND-AGNOSTIC (issue #139): it is emitted
#    IDENTICALLY regardless of the spawn-time SCRIBE_BACKEND. scribe-step.sh 'next' reports the
#    ACTIVE backend (resolved fresh each drain) on a "BACKEND <name>" line and the drainer branches
#    on THAT per request — so a mid-session SCRIBE_BACKEND flip is honored on the very next drained
#    request instead of being drained in the stale spawn-time mode (the old junk 'no-op:' issues).
PROMPT=$(cat <<EOF
You are the BACKLOG SCRIBE (queue drainer). Drain the backlog queue, one request at a time.
Repeat this loop:

1. Run:  bash $HERE/scribe-step.sh next --linger $SCRIBE_LINGER_SECS
   • It prints "CLAIMED <path>", then "BACKEND <name>" (the ACTIVE backend, read NOW), then the
     request text (repo already pulled & current). OR it prints "EMPTY".
   • The --linger window makes 'next' keep polling for $SCRIBE_LINGER_SECS extra seconds once the
     queue empties before it returns EMPTY, so a burst of requests arriving with idle gaps between
     them is drained by THIS one session — the mechanic does the waiting; you never sleep yourself.
   • If EMPTY: run  bash $HERE/scribe-step.sh finish . STOP -> end your turn (done).
     MORE -> go back to step 1.
2. Apply the request via the ACTIVE backend from the "BACKEND <name>" line just printed. The backend
   can change mid-session, so ALWAYS use the one printed for THIS request — never an earlier value:
   • AMEND (any backend): if the request only APPENDS a clarification/comment/note to an EXISTING item
     — not a new item, not a state change, not a title/description rewrite — do NOT hand-edit the file.
     Run:  bash $HERE/scribe-step.sh amend "<claimed_path>" "<ref>" "<note>"
     It attaches the note first-class (file backend: a dated "↳ note" line under the item entry;
     github/linear: an issue comment) and NEVER changes state or title. <ref> = the item identifier
     when the request names one (HERD-22, or a bare issue number for github), otherwise a distinctive
     title phrase to match. If you cannot pin the request to exactly ONE existing item, SKIP (next
     verb) — never guess which item to amend.
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
           the description).
           If the request carries NO verification plan (how the change will be proven — a named
           sandbox sim scenario for a gate/merge/concurrency/limit-park/pane seam, or the test
           surface otherwise), file it AS-IS — never block or synthesize one — but append a
           "⚠️ no verification plan" marker line to the body so the flag rides into the item AND
           its scribe report line, and the coordinator sees which items shipped unplanned. Then run:
           bash $HERE/scribe-step.sh add-item "<claimed_path>" "<text from request>"
       – Mark an EXISTING item done / in-progress / canceled — INCLUDING the watcher
         "Reconcile: PR #N merged — find the backlog item…" and any reap/close request →
           bash $HERE/scribe-step.sh update-state "<claimed_path>" "<ref>" "<state>"
         <ref> = the item identifier when the request names one (e.g. HERD-22, or a bare issue number
         for the github backend), otherwise a distinctive title phrase to match. <state> = one of
         done | in-progress | canceled. For a reconcile request that gives only a PR number, work out
         the matching item identifier/title from the request text; if you cannot confidently pin it to
         ONE item, SKIP (next bullet) — never guess, never file a new issue.
       – APPEND a clarification/comment/note to an EXISTING item (NOT a new item, NOT a state change) →
           bash $HERE/scribe-step.sh amend "<claimed_path>" "<ref>" "<note>"
         Posts an issue comment; never changes state or title. If you cannot pin it to ONE existing
         item, SKIP (next bullet) — never guess, never file a new issue.
       – ANYTHING you cannot map to an add, a state change, or an amend →
           bash $HERE/scribe-step.sh skip "<claimed_path>" "<one-line reason>"
         skip records a loud line in the scribe report and files NOTHING. When in doubt between
         update-state and skip, prefer skip over add-item — a wrongly-filed issue is the exact bug.
3. Go to step 1.

Use scribe-step.sh for all git/queue/report mechanics. Never merge, switch branches, or edit any
file other than $BACKLOG_FILE (and only when the active backend is "file").
EOF
)
# Stamp the heartbeat NOW, at spawn, so the grace period is measured from SPAWN rather than from a
# leftover heartbeat left by a prior drainer's lifetime (HERD-122 fix 1). Without this, a fresh
# drainer that has not yet run its first scribe-step could be seen as "hung since epoch" by a
# concurrent enqueue seconds later. Best-effort; the step scripts keep it fresh from here on.
herd_drainer_heartbeat "$HEARTBEAT"
created=$(herdr tab create ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$REPO" --label "$HERD_AGENT_SCRIBE" --no-focus 2>/dev/null || true)
TAB=$(printf '%s' "$created" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["tab"]["tab_id"])' 2>/dev/null || true)
if [ -z "$TAB" ]; then
  # The control surface refused a tab (busy / herdr down). Journal an infra_event and exit cleanly —
  # the request stays safely queued; the next enqueue retries. Never dump a raw driver error.
  journal_append infra_event component scribe agent "$HERD_AGENT_SCRIBE" reason spawn_tab_failed
  echo "✍️  scribe: could not create a drainer tab (control surface busy?) — your request is queued and the next enqueue will retry."
  exit 0
fi
# Guard the launch: even after the corroboration above, a residual race (an existing drainer still
# holds the name in herdr) makes `agent start` fail with agent_name_taken. Journal that as an
# infra_event and exit cleanly instead of dumping the raw driver error (HERD-122 fix 3).
if _launch_out="$(herd_driver_launch_agent \
      name="$HERD_AGENT_SCRIBE" workspace="$_WS_ID" cwd="$REPO" tab="$TAB" env="SCRIBE_TAB=$TAB" \
      model="$SCRIBE_MODEL" flags="$CLAUDE_FLAGS" pointer="$PROMPT" 2>&1)"; then
  # HERD-193 SPAWN: owner=scribe.sh, liveness=the heartbeat the step script keeps fresh, deadline=the
  # reclaim gate's DRAINER_HEARTBEAT_TIMEOUT, retire=drainer-reclaim. A drainer legitimately runs for
  # hours, so SILENCE past the heartbeat window — not absolute lifetime — is what "past deadline" means
  # for this population. Lever-gated; byte-inert with LIFECYCLE_CONTRACTS=off.
  lifecycle_spawn scribe-drainer "$HERD_AGENT_SCRIBE" "heartbeat:$HEARTBEAT" scribe.sh
  echo "✍️  scribe drainer dispatched (tab $TAB). Coordinator is free; watch for the JUST SCRIBED banner."
else
  herdr tab close "$TAB" >/dev/null 2>&1 || true
  journal_append infra_event component scribe agent "$HERD_AGENT_SCRIBE" reason respawn_failed \
    detail "$(printf '%s' "$_launch_out" | head -n1)"
  echo "✍️  scribe: a drainer already holds the name — leaving the existing one in place; your request is queued and will be drained."
  exit 0
fi
