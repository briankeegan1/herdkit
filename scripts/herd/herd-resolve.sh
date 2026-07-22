#!/usr/bin/env bash
# herd-resolve.sh <slug> — spin up an isolated, test-gated CONFLICT RESOLVER agent in its own
# herdr tab for an EXISTING feature worktree whose PR has gone CONFLICTING.
#
# Unlike herd-feature.sh this does NOT create a worktree — it operates on the worktree that
# already exists at $WORKTREES_DIR/<slug> (the conflicting PR's branch is already checked out
# there). The tab is laid out as [ live app preview | Claude resolver-agent ] when a preview
# command is configured, else just the resolver pane.
#
# PLACEMENT (HERD-280, RESOLVER_PANE=on): the resolver is a PANE that retires on result-consumed,
# exactly like a reviewer pane. When the builder's tab for <slug> still exists the resolver runs as a
# bottom SPLIT PANE inside it (the placement herd-review.sh already uses) so the conflict is resolved
# alongside the work; otherwise it falls back to a standalone resolve·<slug> tab in the control-room
# workspace — which is also the whole behavior when RESOLVER_PANE=off (the default). Whichever pane we
# create is recorded, with its placement mode, in the sha-scoped dispatch registry the watcher passes
# via $HERD_RESOLVE_REGISTRY_FILE; the watcher reconciles that registry against the OBSERVED verdict
# file (never a dispatch-seat event) and retires the pane when the verdict is DONE. An ESCALATE keeps
# the pane open for the human the escalation is addressed to.
#
# The resolver merges the default branch in, resolves MECHANICAL conflicts, runs the smoke test
# ($SMOKE_CMD) + healthcheck, and on a green pass pushes the feature branch (NEVER force, NEVER
# the default branch) so the PR flips CLEAN and the auto-merge watcher merges it. It ESCALATES
# semantically-ambiguous conflicts to the human instead of guessing — it never blind-merges.
#
# Env overrides:
#   HERD_CLAUDE_FLAGS   flags passed to claude (default: --dangerously-skip-permissions)
#   HERD_NO_APP=1       skip the app-preview pane
#
# Standalone:
#   herd-resolve.sh dividend-history
# Or driven by the /coordinator skill / the watcher when a PR is CONFLICTING.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
# Runtime driver shim: route the resolver agent launch through herd_driver_launch_agent so
# HERD_DRIVER=headless spawns a detached resolver; herdr-claude emits the identical argv below.
# HERD-150 P2: the shim resolves RESOLVER_MODEL's runtime driver from the (possibly qualified) ref and
# composes the `-- <runtime>` tail from that driver's DRIVER_AGENT_INTERACTIVE_SPAWN binding — so a
# runtime-qualified RESOLVER_MODEL launches the right runtime, byte-identical for a bare model id.
# shellcheck source=/dev/null
. "$HERE/driver.sh"
SLUG="${1:?usage: herd-resolve.sh <slug>   (slug = the existing worktree under the worktrees dir)}"
DIR="$WORKTREES_DIR/$SLUG"
CLAUDE_FLAGS="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"
# Resolver work is mechanical merge-conflict fixing, not creative — default to the configured
# resolver model (Sonnet); override with RESOLVER_MODEL=… for a specific run.
RESOLVER_MODEL="${RESOLVER_MODEL:-$MODEL_RESOLVER}"
_WS_ID="$(herd_resolve_workspace_id)"

# 1. The worktree must already exist — herd-resolve.sh resolves IN PLACE, it never creates one.
#    A herdr tab rooted in a non-existent dir is worse than no tab at all: bail loud.
if [ ! -d "$DIR" ]; then
  echo "❌ no worktree at $DIR — herd-resolve.sh resolves an EXISTING feature worktree; it does not create one." >&2
  echo "   (Is the slug right? 'git worktree list' shows the live worktrees.)" >&2
  exit 1
fi
if [ ! -e "$DIR/.git" ]; then
  echo "❌ $DIR exists but isn't a git worktree (no .git) — refusing to resolve there." >&2
  exit 1
fi

# 2. The resolver agent's opening prompt. The STANDARD resolver task — fixed, not free-form: the
#    coordinator does not hand-tune it. The smoke step is the project's $SMOKE_CMD (omitted from the
#    prompt when unset → resolver relies on the healthcheck alone).
SMOKE_STEP=""
[ -n "$SMOKE_CMD" ] && SMOKE_STEP="the project smoke test ($SMOKE_CMD) AND "
# The watcher (HERD-55) hands the resolver a sha-scoped result file via $HERD_RESOLVE_RESULT_FILE so
# it can tell a resolver that ESCALATED (terminal for this sha) from one that DIED mid-flight (a
# respawn candidate). The verdict line is the resolver's LAST act — mirrors herd-review.sh's contract.
RESULT_STEP=""
[ -n "${HERD_RESOLVE_RESULT_FILE:-}" ] && RESULT_STEP=" (6) RESULT FILE — as your VERY LAST act, record your outcome for the watcher: on a clean green push write the single line 'RESOLVE: DONE' to $HERD_RESOLVE_RESULT_FILE; on an escalation write 'RESOLVE: ESCALATE' to $HERD_RESOLVE_RESULT_FILE instead. Write it exactly once, at the end."
TASK="You are a CONFLICT RESOLVER for one feature worktree. Goal: make this branch cleanly mergeable into the default branch WITHOUT changing either side's intent. Steps: (1) git fetch $HERD_REMOTE; merge $DEFAULT_BRANCH into this branch (git merge $DEFAULT_BRANCH). (2) If there are conflicts, resolve them PRESERVING BOTH sides' intent — mechanical conflicts (imports, adjacent edits, a helper that moved/was extracted, formatting) you resolve directly. (3) After resolving, run ${SMOKE_STEP}bash $HERE/healthcheck.sh on this worktree ($DIR); both must pass. (4) If everything resolves cleanly AND the checks are green AND you are confident the merge preserved both intents: commit the merge and git push (normal push to the feature branch, NEVER force, NEVER push to $HERD_BRANCH_NAME). The PR will then flip to CLEAN and the auto-merge watcher will merge it. (5) ESCALATION — if any conflict is SEMANTICALLY AMBIGUOUS (the same function/logic was changed two different ways and the correct combined result is unclear), DO NOT GUESS: abort the merge (git merge --abort), post a PR comment via gh pr comment summarizing both sides and what needs a human decision, print a clear line starting with 'ESCALATE:' explaining the ambiguity, and STOP.${RESULT_STEP} BRANCH CONTRACT — this worktree ($DIR) must be left checked out on the SAME branch you found it on, the PR's own head branch. You may create scratch branches while you work, but restoring the PR's branch is part of being DONE: the watcher joins worktrees to PRs by branch name, and a worktree abandoned on a scratch branch makes its PR invisible to gating. Never edit $BACKLOG_FILE. Never touch $HERD_BRANCH_NAME directly."
# 3. PLACEMENT. Two modes, one launch. `split` (HERD-280, RESOLVER_PANE=on) puts the resolver in the
#    builder's own tab as a bottom split; `tab` is the shipped standalone resolve·<slug> tab in the
#    control-room workspace — the fallback, and the ONLY mode when RESOLVER_PANE=off.
TAB=""; ROOT=""; PLACEMENT=""
# HERD-286: parse the lever through the ONE shared resolver so the placement decision and any
# consumer that sources this file cannot silently disagree about which values arm the pane path.
# shellcheck source=/dev/null
. "$HERE/resolver-pane.sh"
case "$(_effective_resolver_pane)" in on) _WANT_PANE=1 ;; *) _WANT_PANE=0 ;; esac

# The builder's tab is the tab labelled EXACTLY $SLUG in this workspace (herd-feature.sh's label).
# Only consulted in pane mode, so the default lane makes no extra herdr call.
_BUILDER_TAB=""
if [ "$_WANT_PANE" = 1 ] && command -v herdr >/dev/null 2>&1; then
  _BUILDER_TAB="$(herdr tab list ${_WS_ID:+--workspace "$_WS_ID"} 2>/dev/null | SLUG="$SLUG" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
    tabs = json.load(sys.stdin).get("result", {}).get("tabs", [])
    print(next((t["tab_id"] for t in tabs if t.get("label") == slug), ""))
except Exception:
    pass
' 2>/dev/null || true)"
fi

if [ -n "$_BUILDER_TAB" ]; then
  # SPLIT MODE: a guest pane inside the builder's tab. A failed start closes NOTHING (the tab is the
  # builder's, not ours) — we fall through to the standalone-tab path below, which is the pre-HERD-280
  # behavior. Routed through the same driver seam the reviewer pane uses.
  if herd_driver_launch_agent \
    name="resolve·$SLUG" workspace="$_WS_ID" cwd="$DIR" tab="$_BUILDER_TAB" split=down \
    model="$RESOLVER_MODEL" flags="$CLAUDE_FLAGS" pointer="$TASK" >/dev/null 2>&1; then
    TAB="$_BUILDER_TAB"; PLACEMENT="split"
  else
    command -v journal_append >/dev/null 2>&1 && journal_append infra_event component resolver agent "resolve·$SLUG" reason split_start_failed tab "$_BUILDER_TAB" dispatch_id "${HERD_RESOLVE_DISPATCH_ID:--}"
  fi
fi

if [ -z "$PLACEMENT" ]; then
  # TAB MODE: new herdr tab rooted in the EXISTING worktree; grab tab id + root pane id.
  created=$(herdr tab create ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$DIR" --label "resolve·$SLUG" --no-focus)
  read -r TAB ROOT < <(printf '%s' "$created" | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' 2>/dev/null || true)
  if [ -z "$TAB" ] || [ -z "$ROOT" ]; then
    echo "❌ herdr unavailable (could not create a resolve tab for '$SLUG'); worktree is at $DIR but no panes were launched." >&2
    exit 1
  fi
  # Register in the sweep allowlist so only engine-created tabs are ever swept.
  printf 'resolve·%s %s resolve\n' "$SLUG" "$TAB" >> "$WORKTREES_DIR/.herd-tabs" 2>/dev/null || true

  # RIGHT pane: the Claude resolver agent (yolo by default).
  # HERD-136: guard the launch so a failed agent start never aborts the lane leaving the tab created
  # just above as an empty corpse tab that nothing reaps. Close it on the failure path before bailing.
  if ! herd_driver_launch_agent \
    name="resolve·$SLUG" workspace="$_WS_ID" cwd="$DIR" tab="$TAB" split=right \
    model="$RESOLVER_MODEL" flags="$CLAUDE_FLAGS" pointer="$TASK"; then
    herdr tab close "$TAB" >/dev/null 2>&1 || true
    command -v journal_append >/dev/null 2>&1 && journal_append infra_event component resolver agent "resolve·$SLUG" reason spawn_agent_failed tab "$TAB" dispatch_id "${HERD_RESOLVE_DISPATCH_ID:--}"
    echo "❌ herdr: could not start the resolver agent for '$SLUG' — closed the empty tab; worktree is at $DIR." >&2
    exit 1
  fi
  PLACEMENT="tab"
fi

# HERD-206: LABEL the freshly-created agent pane 'resolve·<slug>' — exactly what herd-feature.sh does
# for a builder (HERD-135). The watcher's resolver liveness probe (herd_driver_agent_liveness) resolves
# an agent's pane through the roster FIRST and falls back to a pane carrying its label; the TAB was
# already labelled, but the PANE was not, so a resolver DELISTED from the roster (a herdr blip, a
# report-agent registration) had no pane the probe could find and read as positively gone — the
# false-dead that drove the respawn loop. Best-effort + fail-soft: a rename the driver can't do just
# leaves the probe on its roster/heuristic path (no red row, no death verdict).
# In split mode the label is load-bearing twice over: it is also the identity the watcher's GUARDED
# close verifies before retiring this pane inside the builder's SHARED tab (herd_close_pane_verified).
_RESOLVE_PANE="$(herd_driver_agent_pane_id "resolve·$SLUG" 2>/dev/null || true)"
[ -n "$_RESOLVE_PANE" ] && herd_driver_pane_rename "$_RESOLVE_PANE" "resolve·$SLUG" || true

# DISPATCH REGISTRY (HERD-280): record (pane, tab, placement, pr, sha) for the watcher so it can retire
# this pane when it OBSERVES the resolver's DONE verdict. Written AFTER the pane is confirmed up, so the
# id is real. The watcher hands us the path only when RESOLVER_PANE=on, so the default lane writes
# nothing. Best-effort: a failed write only costs the retire-on-consume convenience — the stale-tab
# reaper and the merge-time retirement invariant still clean up as they always have.
# pr + sha are carried IN the row rather than parsed back out of the filename: a sha normalized to "-"
# would make `<pr>-<sha>` ambiguous to split.
if [ -n "${HERD_RESOLVE_REGISTRY_FILE:-}" ] && [ -n "${_RESOLVE_PANE:-}" ]; then
  _reg_tmp="${HERD_RESOLVE_REGISTRY_FILE}.tmp.$$"
  if printf '%s %s %s %s %s\n' "$_RESOLVE_PANE" "${TAB:--}" "$PLACEMENT" \
       "${HERD_RESOLVE_PR:--}" "${HERD_RESOLVE_SHA:--}" > "$_reg_tmp" 2>/dev/null; then
    mv -f "$_reg_tmp" "$HERD_RESOLVE_REGISTRY_FILE" 2>/dev/null || rm -f "$_reg_tmp" 2>/dev/null || true
  fi
fi

# 4. LEFT pane (the tab's root): live app preview on a free port — only when configured. Split mode has
#    no root pane of its own (it is a guest in the builder's tab), so the preview belongs to tab mode.
PORT=""
if [ -n "$ROOT" ] && [ -n "$APP_PREVIEW_CMD" ] && [ "${HERD_NO_APP:-}" != "1" ]; then
  # Free-port search over a CONFIGURABLE range (docs/external-consumer-audit.md "Leak C"): the default
  # base 8501 reproduces today's port block (8501-8599), so an existing web app is unchanged;
  # APP_PREVIEW_PORT_BASE lets an app use its own convention (:8080, :3000). A declared config key
  # (templates/capabilities.tsv), read INLINE here with the shipped 8501 default as its fallback.
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
    echo "⚠️  No free port in $_PORT_BASE-$((_PORT_BASE+98)) — skipping the app-preview pane for 'resolve·$SLUG'." >&2
  fi
fi

echo "🔀 Resolver agent 'resolve·$SLUG' running (claude $CLAUDE_FLAGS) in herdr tab $TAB   dir: $DIR"
[ "$PLACEMENT" = "split" ] && echo "   placement: split pane inside the builder's tab — retired as soon as its DONE verdict is consumed"
echo "   task: merge $DEFAULT_BRANCH → resolve mechanical conflicts → smoke + healthcheck → push (never force/default branch)"
[ -n "$PORT" ] && echo "   🌐 app preview: http://localhost:$PORT   (hot-reloads as the agent resolves)"
# HERD-418: print the REGISTERED (sanitized) name — 'herdr agent focus' rejects the pretty dotted form.
echo "   jump to it:   herdr agent focus $(herd_agent_name_sanitize "resolve·$SLUG")"
echo "   on a green resolve it pushes the branch → PR flips CLEAN → the auto-merge watcher merges it."
echo "   on a SEMANTICALLY-AMBIGUOUS conflict it aborts, comments on the PR, prints 'ESCALATE: …', and stops for a human."
