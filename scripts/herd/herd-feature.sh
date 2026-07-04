#!/usr/bin/env bash
# herd-feature.sh <slug> [task...] — spin up an isolated worktree AND a full per-feature herdr
# tab laid out as:  [ live app preview | Claude sub-agent ]
#
#   - worktree off the latest default branch (+ SHARE_LINKS symlinks)   via new-feature.sh
#   - LEFT pane:  the APP_PREVIEW_CMD on a free port — hot-reloads as the agent edits, so you
#                 can watch the feature take shape. Omitted when APP_PREVIEW_CMD is unset (then
#                 this lane behaves like the quick lane: a single agent pane).
#   - RIGHT pane: a Claude sub-agent, seeded with [task...] as its opening prompt, running with
#                 permissions skipped (yolo) — fine because the worktree is isolated.
#
# Env overrides:
#   HERD_CLAUDE_FLAGS   flags passed to claude (default: --dangerously-skip-permissions)
#   HERD_FEATURE_MODEL  builder model (default: $MODEL_FEATURE — Opus, for the judgment)
#   HERD_NO_APP=1       skip the app-preview pane
#
# Standalone:
#   herd-feature.sh search-filters "Add a search filter panel"
# Or driven by the /coordinator skill.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
. "$HERE/herd-spawn-gate.sh"
# Runtime driver shim: this lane IS the start-agent capability. Under HERD_DRIVER=headless it spawns
# a DETACHED background agent (no herdr tab/pane) via herd_driver_start_agent; the default herdr-claude
# driver keeps the herdr tab + agent-start path below byte-identical.
. "$HERE/driver.sh"
_HERD_DRIVER_NAME="$(herd_driver_name)"
# Force-spawn override: a leading --force/-f (or HERD_FORCE_SPAWN=1) bypasses the advisory
# review-gate saturation check below, for urgent items. Only recognized as the FIRST arg so it can
# never be confused with task text.
FORCE_SPAWN="${HERD_FORCE_SPAWN:-}"
case "${1:-}" in --force|-f) FORCE_SPAWN=1; shift ;; esac
SLUG="${1:?usage: herd-feature.sh [--force] <slug> [task...]   (slug must be kebab-case)}"; shift || true
TASK="${*:-}"

# Advisory pre-spawn review-gate check (BEFORE any worktree/tab is created). If the review pipeline
# is saturated AND builds are already leading past REVIEW_CONCURRENCY + SPAWN_AHEAD, HOLD this spawn
# rather than adding another PR that will just sit in REVIEW_QUEUED. --force / HERD_FORCE_SPAWN=1
# bypasses. Advisory: a deferral is a clean no-op (exit 0), not a failure.
if herd_spawn_gate_saturated; then
  if [ "$FORCE_SPAWN" = "1" ]; then
    echo "⚠️  review gate saturated but --force set — spawning '$SLUG' anyway (urgent)."
  else
    herd_spawn_gate_emit_defer "$SLUG"
    exit 0
  fi
fi
DIR="$WORKTREES_DIR/$SLUG"
CLAUDE_FLAGS="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"
MODEL="${HERD_FEATURE_MODEL:-$MODEL_FEATURE}"
# Deterministic model step-up: if the coordinator-passed task text matches MODEL_ESCALATE_GLOB
# (egrep -i, e.g. judgment-heavy engine surface), force the MODEL_FEATURE tier — REGARDLESS of the
# HERD_FEATURE_MODEL per-spawn override just resolved (a cheaper override cannot survive a matched
# escalation glob). Empty glob → off (zero behavior change). Announce only when it raises the tier.
if [ -n "$MODEL_ESCALATE_GLOB" ] && [ -n "$TASK" ] && printf '%s' "$TASK" | grep -Eiq "$MODEL_ESCALATE_GLOB"; then
  if [ "$MODEL" != "$MODEL_FEATURE" ]; then
    MODEL="$MODEL_FEATURE"
    echo "⬆️  escalated to $MODEL (MODEL_ESCALATE_GLOB matched)"
  fi
fi
_WS_ID="$(herd_resolve_workspace_id)"

# 1. Worktree off the latest default branch + SHARE_LINKS symlinks (fails loudly if the slug
#    already exists — don't clobber in-flight work). Abort here if it can't be created: a herdr
#    tab rooted in a non-existent or half-built dir is worse than no tab at all.
if ! bash "$HERE/new-feature.sh" "$SLUG"; then
  echo "❌ new-feature.sh failed for '$SLUG' — worktree/branch not created; not spawning a herdr tab." >&2
  exit 1
fi

# 2. New herdr tab rooted in the worktree; grab tab id + root pane id. If herdr is unavailable
#    the parse yields empty ids and every later 'herdr pane/agent' call fails cryptically — bail.
#    SKIPPED under the headless driver: there are no tabs/panes (the agent is launched detached below).
TAB=""; ROOT=""
if [ "$_HERD_DRIVER_NAME" != "headless" ]; then
  created=$(herdr tab create ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$DIR" --label "$SLUG" --no-focus)
  read -r TAB ROOT < <(printf '%s' "$created" | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' 2>/dev/null || true)
  if [ -z "$TAB" ] || [ -z "$ROOT" ]; then
    echo "❌ herdr unavailable (could not create a tab for '$SLUG'); worktree is ready at $DIR but no panes were launched." >&2
    exit 1
  fi
  # Register in the sweep allowlist so only engine-created tabs are ever swept.
  printf '%s %s builder\n' "$SLUG" "$TAB" >> "$WORKTREES_DIR/.herd-tabs" 2>/dev/null || true
fi

# PR flow (draft vs direct) threaded into the LANE RULES below. SAFE DEFAULTS preserve today's exact
# behavior: PR_FLOW=direct opens PRs the normal way (`gh pr create`), PR_READY_WHEN=builder means the
# builder owns readiness — together they render the same rules text as before. When PR_FLOW=draft the
# builder opens `gh pr create --draft` (the watcher already HOLDS draft PRs at agent-watch.sh:157), and
# PR_READY_WHEN decides who promotes the draft to ready. Unknown values fall back to the safe default.
# Resolved here (not in herd-config.sh) so the builder prompt is the ONLY surface threaded.
_pr_flow="${PR_FLOW:-direct}";        case "$_pr_flow"  in draft) ;; *) _pr_flow="direct" ;; esac
_pr_ready="${PR_READY_WHEN:-builder}"; case "$_pr_ready" in builder|coordinator|human) ;; *) _pr_ready="builder" ;; esac
if [ "$_pr_flow" = "draft" ]; then
  PR_CREATE_CMD="gh pr create --draft"
  case "$_pr_ready" in
    builder)     PR_READY_RULE=" Open it as a DRAFT; once the healthcheck passes, promote it yourself with 'gh pr ready <pr#>'." ;;
    coordinator) PR_READY_RULE=" Open it as a DRAFT and leave it in draft — the COORDINATOR promotes it to ready for review; do NOT run 'gh pr ready'." ;;
    human)       PR_READY_RULE=" Open it as a DRAFT and leave it in draft — a HUMAN promotes it to ready for review; do NOT run 'gh pr ready'." ;;
  esac
else
  PR_CREATE_CMD="gh pr create"; PR_READY_RULE=""
fi

# LOCAL_REVIEW (pre-PR local correctness review) threaded into the LANE RULES below. SAFE DEFAULT
# preserves today's EXACT behavior: LOCAL_REVIEW=none → LOCAL_REVIEW_RULE is empty, so the rules text
# is byte-for-byte unchanged and the ONLY correctness review is the watcher's post-PR gate. When
# LOCAL_REVIEW=pre-pr the builder must run herd-review.sh --local against its worktree diff and get a
# 'REVIEW: PASS' BEFORE opening the PR (a BLOCK → fix locally + re-review), so a correctness bug is
# caught before the PR is public. Unknown values fall back to none. Resolved here (not in
# herd-config.sh) so the builder prompt is the only surface threaded — same pattern as PR_FLOW above.
_local_review="${LOCAL_REVIEW:-none}"; case "$_local_review" in pre-pr) ;; *) _local_review="none" ;; esac
if [ "$_local_review" = "pre-pr" ]; then
  LOCAL_REVIEW_RULE=" Then, before running '$PR_CREATE_CMD', you MUST pass a LOCAL adversarial correctness review of your worktree diff: run  bash $HERE/herd-review.sh --local \"$SLUG\"  and proceed to open the PR ONLY on a final 'REVIEW: PASS' line. On 'REVIEW: BLOCK — <reason>', FIX the issue in this worktree and re-run the local review until it PASSes — do NOT open the PR while it BLOCKs."
else
  LOCAL_REVIEW_RULE=""
fi

# 3. RIGHT pane: the Claude sub-agent (yolo by default). The seeded task plus the standing
#    workflow rules become its opening prompt.
RULES="[workflow rules] Build ONLY this feature in this worktree. Before running '$PR_CREATE_CMD',
run:  bash $HERE/healthcheck.sh \"$DIR\"  and get a clean pass (fix any CODE errors; data/env
warnings are fine).$LOCAL_REVIEW_RULE$PR_READY_RULE Do NOT merge the PR and do NOT edit $BACKLOG_FILE — the auto-merge watcher merges ready PRs (healthcheck + review gate); the coordinator owns the backlog.
If your feature needs a manual step you cannot perform yourself (a live smoke test, a UI/pane check, anything needing a running app or human eyes), declare each such step in a 'HUMAN-VERIFY:' block in the PR body — one step per line. That switches this PR to a human-verify hold: all gates still run, but the watcher waits for a human to run 'herd-approve.sh approve <pr#>' instead of auto-merging, so the step is never silently skipped."
# Externalize the full task spec (caller task + workflow-rules footer) to a file OUTSIDE the
# worktree's tracked tree, and hand the builder a SHORT pointer prompt instead of a multi-KB argv.
# herd_write_task_spec is FAIL-LOUD: a failed/partial spec write returns non-zero and — under
# 'set -euo pipefail' — this command substitution aborts the lane BEFORE the 'herdr agent start …
# claude' call below, so a builder is never spawned against a missing/truncated spec (the #69 fix).
# Prompt-cache-aware ordering: the STABLE workflow-rules preamble MUST lead so many close-in-time
# builder prompts share the cached prefix (Anthropic's cache keys on the longest shared PREFIX,
# 5-min TTL); the UNIQUE caller task trails. Empty task → rules alone.
if [ -n "$TASK" ]; then SPEC="$RULES"$'\n\n'"$TASK"; else SPEC="$RULES"; fi
TASK_SPEC_FILE="$WORKTREES_DIR/$SLUG.task.md"
POINTER="$(herd_write_task_spec "$TASK_SPEC_FILE" "$SPEC")"
if [ "$_HERD_DRIVER_NAME" = "headless" ]; then
  # Headless: launch a DETACHED background agent (no herdr pane) into the registry. Fail-loud so a
  # spawn that cannot start does not masquerade as success (mirrors the herdr bail above).
  if ! herd_driver_start_agent "$SLUG" "$DIR" "$MODEL" "$CLAUDE_FLAGS" "$POINTER"; then
    echo "❌ headless: could not start a detached agent for '$SLUG'; worktree is ready at $DIR." >&2
    exit 1
  fi
else
  herdr agent start "$SLUG" ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$DIR" --tab "$TAB" --split right --no-focus -- claude --model "$MODEL" $CLAUDE_FLAGS "$POINTER"
fi

# 4. LEFT pane (the tab's root): live app preview on a free port — only if a preview command is
#    configured and not suppressed. Each feature gets its own port so multiple previews coexist.
#    SKIPPED under headless: no root pane to host the preview (panes-as-a-view).
PORT=""
if [ "$_HERD_DRIVER_NAME" != "headless" ] && [ -n "$APP_PREVIEW_CMD" ] && [ "${HERD_NO_APP:-}" != "1" ]; then
  # Free-port search over a CONFIGURABLE range (docs/external-consumer-audit.md "Leak C"): the default
  # base 8501 reproduces today's port block (8501-8599), so an existing web app is unchanged;
  # APP_PREVIEW_PORT_BASE lets an app use its own convention (:8080, :3000). Read INLINE with a default
  # (NOT declared in herd-config.sh / capabilities.tsv); FOLLOW-UP: document APP_PREVIEW_PORT_BASE in
  # templates/capabilities.tsv (owned by another PR).
  _PORT_BASE="${APP_PREVIEW_PORT_BASE:-8501}"
  case "$_PORT_BASE" in ''|*[!0-9]*) _PORT_BASE=8501 ;; esac
  PORT=$(PORT_BASE="$_PORT_BASE" python3 - <<'PY'
import socket, os
try:
    base = int(os.environ.get("PORT_BASE") or "8501")
except ValueError:
    base = 8501
for p in range(base, base + 99):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p)); s.close(); print(p); break
    except OSError:
        pass
PY
)
  if [ -n "$PORT" ]; then
    herdr pane rename "$ROOT" "app·$PORT" >/dev/null 2>&1 || true
    herdr pane run "$ROOT" "bash $HERE/app-monitor.sh $PORT"
  else
    PORT=""
    echo "⚠️  No free port in $_PORT_BASE-$((_PORT_BASE+98)) — skipping the app-preview pane for '$SLUG'." >&2
  fi
fi

# 5. Task-spec viewer in the root pane — ONLY when it is NOT hosting the app preview (never hijack a
# live process). PORT is non-empty EXACTLY when app-monitor.sh was launched into ROOT above; empty
# means the root pane is otherwise unused (no APP_PREVIEW_CMD, HERD_NO_APP=1, or no free port found),
# so the viewer fills it with $TASK_SPEC_FILE live via task-spec-view.sh. TASK_PANE_VIEW default on;
# off restores the bare shell. Sent through the driver's send-text surface (the `herdr pane run`
# equivalent), which fails SOFT if the pane is gone. HEADLESS has no panes → skip cleanly.
if [ "$_HERD_DRIVER_NAME" != "headless" ] && [ -z "$PORT" ] && [ "${TASK_PANE_VIEW:-on}" != "off" ]; then
  herd_driver_send_text "$ROOT" "bash $HERE/task-spec-view.sh \"$TASK_SPEC_FILE\""
fi

if [ "$_HERD_DRIVER_NAME" = "headless" ]; then
  echo "🐑 Sub-agent '$SLUG' running detached (claude --model $MODEL $CLAUDE_FLAGS)   dir: $DIR"
  echo "   task spec: $TASK_SPEC_FILE   (builder got a short pointer to it, not the full spec inline)"
  echo "   tail its log:  bash $HERE/driver.sh read-pane $SLUG   (or: tail -f $WORKTREES_DIR/.herd/agents/$SLUG/log)"
  echo "   when its PR is up: the watcher reviews & merges, then  git worktree remove $DIR"
else
  echo "🐑 Sub-agent '$SLUG' running (claude --model $MODEL $CLAUDE_FLAGS) in herdr tab $TAB   dir: $DIR"
  echo "   task spec: $TASK_SPEC_FILE   (builder got a short pointer to it, not the full spec inline)"
  [ -n "$PORT" ] && echo "   🌐 app preview: http://localhost:$PORT   (hot-reloads as the agent edits)"
  echo "   jump to it:   herdr agent focus $SLUG"
  echo "   when its PR is up: the watcher reviews & merges, then  git worktree remove $DIR"
fi
