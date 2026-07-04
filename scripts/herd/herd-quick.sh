#!/usr/bin/env bash
# herd-quick.sh <slug> [task...] — the *lightweight* sibling of herd-feature.sh, for TRIVIAL,
# non-render changes: one-liners, config/string tweaks, script edits.
#
# Same sacred invariant as herd-feature.sh — the coordinator NEVER edits code in the main
# checkout — so this STILL spins up an isolated worktree off the latest default branch, and the
# spawned agent STILL branches, builds, and opens a PR. What it drops is the *ceremony* a trivial
# non-app change doesn't need:
#
#   - NO live app-preview pane (no free-port app server, no [app│agent] split).
#   - just ONE pane: the Claude sub-agent, in the worktree, yolo by default.
#
# The pre-PR healthcheck is SHARED with herd-feature.sh and auto-adapts: if the diff matches
# HEALTHCHECK_HEAVY_GLOB it runs the full heavy profile; otherwise the LIGHT profile (per-changed
# -file syntax + the project test command). See healthcheck.sh.
#
# Pick the lane:
#   herd-feature.sh  — app-facing features; you want the live preview.
#   herd-quick.sh    — non-app / trivial changes (scripts, docs, config).
#
# Env overrides:
#   HERD_CLAUDE_FLAGS   flags passed to claude (default: --dangerously-skip-permissions)
#   HERD_QUICK_MODEL    builder model (default: $MODEL_QUICK — Sonnet, the trivial lane)
#
# Standalone:
#   herd-quick.sh fix-readme-typo "Fix the typo in README.md"
# Or driven by the /coordinator skill.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
. "$HERE/herd-spawn-gate.sh"
# Runtime driver shim: under HERD_DRIVER=headless this lane spawns a DETACHED agent (no herdr tab)
# via herd_driver_start_agent; the default herdr-claude driver keeps the herdr path below unchanged.
. "$HERE/driver.sh"
_HERD_DRIVER_NAME="$(herd_driver_name)"
# Force-spawn override: a leading --force/-f (or HERD_FORCE_SPAWN=1) bypasses the advisory
# review-gate saturation check below, for urgent items. Only recognized as the FIRST arg so it can
# never be confused with task text.
FORCE_SPAWN="${HERD_FORCE_SPAWN:-}"
case "${1:-}" in --force|-f) FORCE_SPAWN=1; shift ;; esac
SLUG="${1:?usage: herd-quick.sh [--force] <slug> [task...]   (slug must be kebab-case)}"; shift || true
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
MODEL="${HERD_QUICK_MODEL:-$MODEL_QUICK}"
# Deterministic model step-up: if the coordinator-passed task text matches MODEL_ESCALATE_GLOB
# (egrep -i, e.g. judgment-heavy engine surface), force the MODEL_FEATURE tier — REGARDLESS of
# MODEL_QUICK or the HERD_QUICK_MODEL per-spawn override just resolved. This is the deterministic
# backstop for the misjudgment case where an engine PR gets routed through the cheap quick lane.
# Empty glob → off (zero behavior change). Announce only when it actually raises the tier.
if [ -n "$MODEL_ESCALATE_GLOB" ] && [ -n "$TASK" ] && printf '%s' "$TASK" | grep -Eiq "$MODEL_ESCALATE_GLOB"; then
  if [ "$MODEL" != "$MODEL_FEATURE" ]; then
    MODEL="$MODEL_FEATURE"
    echo "⬆️  escalated to $MODEL (MODEL_ESCALATE_GLOB matched)"
  fi
fi
_WS_ID="$(herd_resolve_workspace_id)"

# 1. Worktree off the latest default branch + SHARE_LINKS symlinks (same isolation as the full
#    lane — fails loudly if the slug already exists). Abort if it can't be created.
if ! bash "$HERE/new-feature.sh" "$SLUG"; then
  echo "❌ new-feature.sh failed for '$SLUG' — worktree/branch not created; not spawning a herdr tab." >&2
  exit 1
fi

# 2. New herdr tab rooted in the worktree; grab tab id + root pane id. If herdr is unavailable
#    the parse yields empty ids — bail loudly instead of failing cryptically.
#    SKIPPED under the headless driver: no tabs/panes (the agent is launched detached below).
TAB=""; ROOT=""
if [ "$_HERD_DRIVER_NAME" != "headless" ]; then
  created=$(herdr tab create ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$DIR" --label "$SLUG" --no-focus)
  read -r TAB ROOT < <(printf '%s' "$created" | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' 2>/dev/null || true)
  if [ -z "$TAB" ] || [ -z "$ROOT" ]; then
    echo "❌ herdr unavailable (could not create a tab for '$SLUG'); worktree is ready at $DIR but no panes were launched." >&2
    exit 1
  fi
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

# 3. The Claude sub-agent — the ONLY pane (no app-preview split). It runs in the tab's root pane
#    (no --split right). Yolo by default is fine: the worktree is isolated. Seeded task + the
#    standing workflow rules become its opening prompt.
RULES="[workflow rules] Build ONLY this change in this worktree. Before running '$PR_CREATE_CMD',
run:  bash $HERE/healthcheck.sh \"$DIR\"  and get a clean pass (fix any CODE errors; data/env
warnings are fine).$LOCAL_REVIEW_RULE$PR_READY_RULE Do NOT merge the PR and do NOT edit $BACKLOG_FILE — the auto-merge watcher merges ready PRs (healthcheck + review gate); the coordinator owns the backlog.
If your change needs a manual step you cannot perform yourself (a live smoke test, a UI/pane check, anything needing a running app or human eyes), declare each such step in a 'HUMAN-VERIFY:' block in the PR body — one step per line. That switches this PR to a human-verify hold: all gates still run, but the watcher waits for a human to run 'herd-approve.sh approve <pr#>' instead of auto-merging, so the step is never silently skipped."
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
  # Headless: launch a DETACHED background agent (no herdr pane) into the registry. Fail-loud.
  if ! herd_driver_start_agent "$SLUG" "$DIR" "$MODEL" "$CLAUDE_FLAGS" "$POINTER"; then
    echo "❌ headless: could not start a detached agent for '$SLUG'; worktree is ready at $DIR." >&2
    exit 1
  fi
else
  herdr agent start "$SLUG" ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$DIR" --tab "$TAB" --no-focus -- claude --model "$MODEL" $CLAUDE_FLAGS "$POINTER"
fi

if [ "$_HERD_DRIVER_NAME" = "headless" ]; then
  echo "🐑 Quick sub-agent '$SLUG' running detached (claude --model $MODEL $CLAUDE_FLAGS)   dir: $DIR"
  echo "   task spec: $TASK_SPEC_FILE   (builder got a short pointer to it, not the full spec inline)"
  echo "   ⚡ light lane — no app preview; healthcheck auto-runs the light profile unless the diff matches the heavy glob."
  echo "   tail its log:  bash $HERE/driver.sh read-pane $SLUG   (or: tail -f $WORKTREES_DIR/.herd/agents/$SLUG/log)"
  echo "   when its PR is up: the watcher reviews & merges, then  git worktree remove $DIR"
else
  echo "🐑 Quick sub-agent '$SLUG' running (claude --model $MODEL $CLAUDE_FLAGS) in herdr tab $TAB   dir: $DIR"
  echo "   task spec: $TASK_SPEC_FILE   (builder got a short pointer to it, not the full spec inline)"
  echo "   ⚡ light lane — no app preview; healthcheck auto-runs the light profile unless the diff matches the heavy glob."
  echo "   jump to it:   herdr agent focus $SLUG"
  echo "   when its PR is up: the watcher reviews & merges, then  git worktree remove $DIR"
fi
