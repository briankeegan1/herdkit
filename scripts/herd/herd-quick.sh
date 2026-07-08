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
# The pre-PR verification instruction is SHARED with herd-feature.sh and SCOPED (HERD-99): the builder
# is told to verify its OWN surface — the LIGHT profile (per-changed-file syntax) plus its own new/
# changed tests — NOT the whole heavy suite. The watcher's gate-time full run stays the authoritative
# pass, so a blanket local heavy run just duplicates it; the scoped text says so and leaves --heavy
# available for a builder that wants extra confidence. See healthcheck.sh for the profiles.
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
# Atomic pre-spawn claim (HERD-50): herd_claim_or_abort runs BEFORE worktree creation and, only when
# CLAIM_REQUIRED is on AND a tracker id is present, claims the item synchronously so two operators
# can't double-build it. Off/no-id → returns 0 immediately (today's behavior).
. "$HERE/herd-claim.sh"
# Journal (HERD-64): sourced so herd_tracked_spawn_or_abort can record a TRACKED_SPAWNS bypass.
# Best-effort + always-0; a no-op when TRACKED_SPAWNS is off (the default).
. "$HERE/journal.sh"
# Runtime driver shim: under HERD_DRIVER=headless this lane spawns a DETACHED agent (no herdr tab)
# via herd_driver_start_agent; the default herdr-claude driver keeps the herdr path below unchanged.
. "$HERE/driver.sh"
# Pipeline steps (HERD-132) — the shared step-runner. Sourced for steps_has_seam so the BUILDER-seam
# rule (post-build / post-healthcheck) is threaded into the prompt below only when the project defines
# such steps; the watcher owns the pre/post-merge seams. Sourcing DEFINES functions only (CLI dispatch
# is $0-guarded), so this is byte-inert when .herd/steps.tsv is absent/empty.
. "$HERE/steps.sh"
_HERD_DRIVER_NAME="$(herd_driver_name)"
# Force-spawn override: a leading --force/-f (or HERD_FORCE_SPAWN=1) bypasses the advisory
# review-gate saturation check below, for urgent items. Only recognized as the FIRST arg so it can
# never be confused with task text.
FORCE_SPAWN="${HERD_FORCE_SPAWN:-}"
case "${1:-}" in --force|-f) FORCE_SPAWN=1; shift ;; esac
SLUG="${1:?usage: herd-quick.sh [--force] <slug> [task...]   (slug must be kebab-case)}"; shift || true
TASK="${*:-}"

# Tracked-spawn policy gate (HERD-64) — BEFORE anything else. When TRACKED_SPAWNS=required a spawn
# carrying no tracker ref (HERD_CLAIM_ID / HERD_ITEM_REF) is REFUSED here, creating nothing; --force /
# HERD_FORCE_SPAWN=1 bypasses and journals it. Off (default) → returns 0, byte-identical to today.
if ! herd_tracked_spawn_or_abort "$SLUG" "$FORCE_SPAWN"; then
  exit 1
fi

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

# 0. Atomic claim (HERD-50) — BEFORE any worktree/tab/agent. Aborts the spawn (creating NOTHING) if
#    the tracked item is already claimed by another operator; proceeds otherwise (including the
#    off/no-id/backend-unreachable fail-soft paths). Must come before new-feature.sh below.
if ! herd_claim_or_abort "$SLUG"; then
  exit 1
fi

# 1. Worktree off the latest default branch + SHARE_LINKS symlinks (same isolation as the full
#    lane — fails loudly if the slug already exists). Abort if it can't be created.
if ! bash "$HERE/new-feature.sh" "$SLUG"; then
  echo "❌ new-feature.sh failed for '$SLUG' — worktree/branch not created; not spawning a herdr tab." >&2
  exit 1
fi

# HERD-92: persist the tracker ref → slug pairing as a cheap per-worktree marker so the watcher can
# render this builder's console row as '<ref> <slug>' every tick with NO gh/backend call — matching
# the tracker id shown in the "tracker healed" section. Written only when spawned from a TRACKED item
# (HERD_ITEM_REF set); an untracked spawn leaves no marker and renders the plain slug, unchanged.
# Fail-soft: a write error never blocks the spawn (the console falls back to the slug).
if [ -n "${HERD_ITEM_REF:-}" ]; then
  printf '%s\n' "$HERD_ITEM_REF" > "$WORKTREES_DIR/.herd-ref-$SLUG" 2>/dev/null || true
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

# PUSH_GATE=human (HERD-123) — hold this FINISHED builder for human review BEFORE anything reaches
# GitHub (gate-then-upload). SAFE DEFAULT: PUSH_GATE unset/'' → PUSH_GATE_RULE empty, rules text
# byte-for-byte unchanged and the builder pushes + opens its PR normally. When =human the builder does
# ALL its work + healthcheck but must NOT run '$PR_CREATE_CMD' / 'git push' — instead it records a
# sha-keyed push-hold via push-gate.sh; a human reviews the LOCAL diff and approves, which resumes the
# push + PR creation. Unknown value → off (fail safe). Normalized inline, same pattern as PR_FLOW.
_push_gate="${PUSH_GATE:-}"; case "$_push_gate" in human) ;; *) _push_gate="" ;; esac
if [ "$_push_gate" = "human" ]; then
  PUSH_GATE_RULE=" PUSH GATE (human review BEFORE upload): this project holds finished builders for human review before ANYTHING reaches GitHub. Do NOT run '$PR_CREATE_CMD' and do NOT 'git push' yourself. Instead, once your work is committed and the healthcheck passes, write your intended PR body (including any 'Refs:' line) to a file and run:  bash $HERE/push-gate.sh hold $SLUG --title \"<your PR title>\" --body-file <that-file>  — this records a sha-keyed hold and STOPS. A human then reviews your LOCAL diff and runs 'herd-approve.sh approve $SLUG', which resumes the push + PR creation for you. Nothing you build reaches GitHub until a human approves; a new commit after the hold invalidates a prior approval, so re-run the hold if you change anything."
else
  PUSH_GATE_RULE=""
fi

# Pipeline steps (HERD-132) — the BUILDER-seam rule (post-build / post-healthcheck), threaded ONLY
# when the project defines such steps in .herd/steps.tsv (else EMPTY → prompt byte-identical). The
# watcher runs the pre/post-merge seams itself, so they are never mentioned to the builder. Built by
# the shared steps_builder_rule helper so both lanes inject identical text — same opt-in pattern as
# PUSH_GATE_RULE above.
STEPS_RULE="$(steps_builder_rule "$SLUG" "$DIR" "$HERE" "$PR_CREATE_CMD")"

# Tracker linkage (HERD-39): when the coordinator spawns from a TRACKED item it prefixes the lane
# command with HERD_ITEM_REF=<id>. When set, the LANE RULES below REQUIRE the builder to carry an
# explicit 'Refs: <id>' line in its PR body, so merge-time reconcile (agent-watch.sh) resolves the
# backlog item by that EXACT ref instead of fuzzy slug/title matching. Unset → REFS_RULE is empty and
# the prompt is byte-for-byte unchanged (zero behavior change). Appended at the END of the rules text
# (it is per-item unique) so the STABLE cached prefix stays maximal — same cache-aware discipline as
# the SPEC ordering below. Resolved here (not in herd-config.sh) so the builder prompt is the only
# surface threaded — same pattern as PR_FLOW / LOCAL_REVIEW above.
_item_ref="${HERD_ITEM_REF:-}"
if [ -n "$_item_ref" ]; then
  REFS_RULE=" This item is tracked as $_item_ref — you MUST include a line 'Refs: $_item_ref' in the PR body so the merge-time reconcile links it back to the tracker by that exact ref."
else
  REFS_RULE=""
fi

# Context-provisioning grounding (HERD-40): CONTEXT_PROVISION lists grounding sources to inject into
# the STABLE task-spec preamble so builders start grounded instead of re-exploring the repo each
# session (first source: 'codemap' → a pointer to the committed docs/codemap.md). Empty/unset (the
# default) → GROUNDING_RULE is empty and the rules text is byte-for-byte unchanged. Built by the shared
# herd_context_provision_preamble helper (herd-config.sh) so both lanes inject identically and the
# surface is extensible. Threaded into the STABLE region BELOW, BEFORE $REFS_RULE (the per-item unique
# trailer) so the shared prompt-cache prefix stays maximal — same discipline as the SPEC ordering.
GROUNDING_RULE="$(herd_context_provision_preamble)"

# 3. The Claude sub-agent — the ONLY pane (no app-preview split). It runs in the tab's root pane
#    (no --split right). Yolo by default is fine: the worktree is isolated. Seeded task + the
#    standing workflow rules become its opening prompt.
RULES="[workflow rules] Build ONLY this change in this worktree. Before running '$PR_CREATE_CMD',
verify YOUR change's OWN surface — you do NOT run the full heavy suite yourself. Run
 bash $HERE/healthcheck.sh \"$DIR\" --light  (per-changed-file syntax) PLUS any test you added or
changed, and get a clean pass (fix any CODE errors; data/env warnings are fine). DESCOPED, on purpose:
the whole-project heavy profile (healthcheck.sh --heavy / the full test suite) is NOT required of you
here — the auto-merge watcher re-runs that FULL profile as the AUTHORITATIVE merge gate, so a blanket
local heavy run only duplicates it and burns turns. If your change is broad or risky you MAY still run
it yourself with  bash $HERE/healthcheck.sh \"$DIR\" --heavy  (descoped = optional, not forbidden).$LOCAL_REVIEW_RULE$PR_READY_RULE$PUSH_GATE_RULE$STEPS_RULE Do NOT merge the PR and do NOT edit $BACKLOG_FILE — the auto-merge watcher merges ready PRs (healthcheck + review gate); the coordinator owns the backlog. Never read .herd/secrets and never write the work tracker (a Linear/GitHub issue's state, labels, or assignee) — the coordinator owns ALL item states; a builder that mutates tracker state corrupts the queue.
If your change needs a manual step you cannot perform yourself (a live smoke test, a UI/pane check, anything needing a running app or human eyes), declare each such step in a 'HUMAN-VERIFY:' block in the PR body — one step per line. That switches this PR to a human-verify hold: all gates still run, but the watcher waits for a human to run 'herd-approve.sh approve <pr#>' instead of auto-merging, so the step is never silently skipped.$GROUNDING_RULE$REFS_RULE"
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
  # HERD-136: guard the launch so a failed 'agent start' (e.g. a residual agent_name_taken race) never
  # aborts the lane leaving the tab we just created above as an empty corpse tab that nothing reaps.
  # Close the just-created tab on the failure path and journal the reap before bailing (fail-soft; the
  # success path is byte-identical — the same argv is captured whether or not it is wrapped in `if`).
  if ! _agent_start_out="$(herdr agent start "$SLUG" ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$DIR" --tab "$TAB" --no-focus -- claude --model "$MODEL" $CLAUDE_FLAGS "$POINTER")"; then
    herdr tab close "$TAB" >/dev/null 2>&1 || true
    journal_append infra_event component builder agent "$SLUG" reason spawn_agent_failed tab "$TAB"
    echo "❌ herdr: could not start the builder agent for '$SLUG' — closed the empty tab; worktree is ready at $DIR." >&2
    exit 1
  fi
  # HERD-135: LABEL the freshly-created agent pane with the slug so the dead-agent-eyes probe reads its
  # role by label (and can still find it if the agent is later delisted) instead of positional/cmdline
  # guessing. Best-effort: parse the pane id from the start result, else resolve via the roster; a
  # rename the driver can't do just leaves the probe on its fallback heuristic (fail-soft, no red row).
  _AGENT_PANE="$(herd_driver_pane_id_from_agent_start "$_agent_start_out")"
  [ -z "$_AGENT_PANE" ] && _AGENT_PANE="$(herd_driver_agent_pane_id "$SLUG")"
  [ -n "$_AGENT_PANE" ] && herd_driver_pane_rename "$_AGENT_PANE" "$SLUG"
fi

# 3b. Task-spec viewer in the tab's OTHERWISE-IDLE root pane (TASK_PANE_VIEW, default on). The quick
# lane's agent runs in its own pane, leaving ROOT sitting at a bare shell — so this is strictly
# additive UX: it renders $TASK_SPEC_FILE live via task-spec-view.sh; TASK_PANE_VIEW=off restores the
# bare shell exactly. Sent through the driver's send-text surface (the `herdr pane run` equivalent),
# which fails SOFT if the pane is gone. HEADLESS has no panes → skip cleanly (panes are a view, not a
# dependency), so the whole block is gated on the non-headless driver.
# HERD-135: name the root pane's ROLE via the driver so the coordinator (human AND agent) never
# mistakes the viewer pane for the agent pane again (the #249 incident): the viewer is 'task-spec·$SLUG'
# and a bare shell (TASK_PANE_VIEW=off) is 'shell·$SLUG'. Fail-soft — a rename the driver can't do is a
# clean no-op and the probe simply falls back to its heuristic.
if [ "$_HERD_DRIVER_NAME" != "headless" ]; then
  if [ "${TASK_PANE_VIEW:-on}" != "off" ]; then
    herd_driver_pane_rename "$ROOT" "task-spec·$SLUG"
    herd_driver_send_text "$ROOT" "bash $HERE/task-spec-view.sh \"$TASK_SPEC_FILE\""
  else
    herd_driver_pane_rename "$ROOT" "shell·$SLUG"
  fi
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
