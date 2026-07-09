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
# Drainer singleton liveness (HERD-109 / HERD-122): herd_drainer_* let the singleton check below tell a
# HUNG-but-listed researcher drainer from a live one, and CORROBORATE liveness before reclaiming so a
# fresh/live drainer is never falsely declared hung.
# shellcheck source=/dev/null
. "$HERE/drainer-liveness.sh"
# Native-burst seam (HERD-107): the bounded read-only FAN-OUT helper. Sourced so this READ-ONLY lane
# can hint the drainer a BOUNDED concurrent-Explore width when NATIVE_BURST=on. Off → no hint, the
# drainer prompt is byte-identical to before.
# shellcheck source=/dev/null
. "$HERE/burst.sh"
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
#    Capture the roster ONCE so the liveness corroboration below reads the SAME snapshot (no second
#    call / TOCTOU).
HEARTBEAT="${RESEARCH_HEARTBEAT:-$TREES/.research.heartbeat}"
AGENTS_JSON="$(herd_driver_agent_list_json 2>/dev/null || echo '{}')"
if printf '%s' "$AGENTS_JSON" | NAME="$HERD_AGENT_RESEARCHER" WS="$_WS_ID" python3 -c '
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
  # A researcher of this name is LISTED. Normally we short-circuit (it will drain this). But a listed
  # drainer can be HUNG: its heartbeat ($HEARTBEAT, written by research-step.sh on every drain step)
  # goes stale. HERD-109 reclaimed on stale-heartbeat alone — but that FALSE-POSITIVED a fresh,
  # seconds-old drainer whose leftover heartbeat (from a prior drainer's lifetime) was ancient, and
  # then failed the respawn with agent_name_taken (HERD-122). So a stale heartbeat now only reclaims
  # once CORROBORATED: a working/idle live agent is never hung regardless of heartbeat age. Reclaim
  # ONLY on positive death (dead pid / bare pane + stale heartbeat); otherwise keep the legacy path.
  LIVE="$(herd_drainer_live_status "$HERD_AGENT_RESEARCHER" "$AGENTS_JSON")"
  if herd_drainer_should_reclaim "$HEARTBEAT" "$DRAINER_HEARTBEAT_TIMEOUT" "$LIVE"; then
    echo "⚠️  researcher drainer is DEAD (no heartbeat for >${DRAINER_HEARTBEAT_TIMEOUT}s and its process is gone) — reclaiming the singleton and spawning a fresh drainer (per-request atomic claim prevents double-draining)."
    journal_append drainer_reclaimed component researcher agent "$HERD_AGENT_RESEARCHER" live_status "$LIVE" timeout "$DRAINER_HEARTBEAT_TIMEOUT"
    lifecycle_retire research-drainer "$HERD_AGENT_RESEARCHER" reclaimed
  elif herd_drainer_hung "$HEARTBEAT" "$DRAINER_HEARTBEAT_TIMEOUT"; then
    # Heartbeat is stale but the agent is LIVE (working/idle) or its death can't be confirmed — refuse
    # the reclaim and journal it (no-false-red). The live drainer will drain this request.
    echo "🔎 researcher already running (heartbeat stale but the agent is live/${LIVE} — not hung); it will drain this."
    journal_append drainer_reclaim_refused component researcher agent "$HERD_AGENT_RESEARCHER" live_status "$LIVE" timeout "$DRAINER_HEARTBEAT_TIMEOUT"
    exit 0
  else
    echo "🔎 researcher already running — it will drain this."; exit 0
  fi
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
# Stamp the heartbeat NOW, at spawn, so the grace period is measured from SPAWN rather than from a
# leftover heartbeat left by a prior drainer's lifetime (HERD-122 fix 1). Without this, a fresh
# drainer that has not yet run its first research-step could be seen as "hung since epoch" by a
# concurrent enqueue seconds later. Best-effort; the step scripts keep it fresh from here on.
herd_drainer_heartbeat "$HEARTBEAT"
# NATIVE-BURST (HERD-107): when the bounded read-only fan-out seam is ON, hint the drainer a CONCRETE
# concurrent-Explore cap (bounded by REVIEW_CONCURRENCY via herd_burst_bound) so a request's reading
# fans out to cut wall-clock — while staying BOUNDED. This is read-only fan-out: the per-request
# report WRITE stays serial (one report per request). OFF → this block is skipped and the prompt is
# byte-identical to before (default preserves today's un-hinted serial behavior).
if herd_burst_enabled; then
  _BURST_N="$(herd_burst_bound)"
  if [ "${_BURST_N:-1}" -gt 1 ] 2>/dev/null; then
    PROMPT="$PROMPT

NATIVE-BURST (bounded read-only fan-out): to cut wall-clock you MAY dispatch up to ${_BURST_N} Explore
subagents CONCURRENTLY while researching a request — but keep it BOUNDED: never exceed ${_BURST_N} in
flight at once. This concurrency is for READING only; you still write exactly ONE findings report per
request (that write stays serial), and you remain strictly read-only against the repo."
  fi
fi
created=$(herdr tab create ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$REPO" --label "$HERD_AGENT_RESEARCHER" --no-focus 2>/dev/null || true)
TAB=$(printf '%s' "$created" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["tab"]["tab_id"])' 2>/dev/null || true)
if [ -z "$TAB" ]; then
  # The control surface refused a tab (busy / herdr down). Journal an infra_event and exit cleanly —
  # the request stays safely queued; the next enqueue retries. Never dump a raw driver error.
  journal_append infra_event component researcher agent "$HERD_AGENT_RESEARCHER" reason spawn_tab_failed
  echo "🔎 researcher: could not create a drainer tab (control surface busy?) — your request is queued (fetch with research-get.sh $REQ_ID once drained)."
  exit 0
fi
# Guard the launch: even after the corroboration above, a residual race (an existing drainer still
# holds the name in herdr) makes `agent start` fail with agent_name_taken. Journal that as an
# infra_event and exit cleanly instead of dumping the raw driver error (HERD-122 fix 3).
if _launch_out="$(herd_driver_launch_agent \
      name="$HERD_AGENT_RESEARCHER" workspace="$_WS_ID" cwd="$REPO" tab="$TAB" env="RESEARCH_TAB=$TAB" \
      model="$RESEARCH_MODEL" flags="$CLAUDE_FLAGS" pointer="$PROMPT" 2>&1)"; then
  # HERD-193 SPAWN: owner=research.sh, liveness=the heartbeat the step script keeps fresh, deadline=the
  # reclaim gate's DRAINER_HEARTBEAT_TIMEOUT, retire=drainer-reclaim. A drainer legitimately runs for
  # hours, so SILENCE past the heartbeat window — not absolute lifetime — is what "past deadline" means
  # for this population. Lever-gated; byte-inert with LIFECYCLE_CONTRACTS=off.
  lifecycle_spawn research-drainer "$HERD_AGENT_RESEARCHER" "heartbeat:$HEARTBEAT" research.sh
  echo "🔎 researcher drainer dispatched (tab $TAB). Coordinator is free; fetch the report with research-get.sh $REQ_ID."
else
  herdr tab close "$TAB" >/dev/null 2>&1 || true
  journal_append infra_event component researcher agent "$HERD_AGENT_RESEARCHER" reason respawn_failed \
    detail "$(printf '%s' "$_launch_out" | head -n1)"
  echo "🔎 researcher: a drainer already holds the name — leaving the existing one in place; your request is queued and will be drained."
  exit 0
fi
