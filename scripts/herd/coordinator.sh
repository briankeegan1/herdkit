#!/usr/bin/env bash
# coordinator.sh — (re)launch the coordinator herdr tab as a 2-pane control room:
#
#     [  live BACKLOG    |   coordinator Claude running the /coordinator skill  ]
#       (left, always on)    (right, prompts you: implement / browse / add)
#
# Idempotent: closes this project's existing coordinator tab first, so you can re-run it anytime to get a
# fresh control room. The left pane stays pinned to the backlog; the right pane is where you drive
# work and spin up feature sub-agents. The 🐑 herd-watch console is pinned below the coordinator
# (auto-merges ready PRs, healthcheck + review gated) unless suppressed.
#
# Env knobs:
#   HERD_NO_WATCH=1        skip the 🐑 herd-watch console pane
#   AGENT_WATCH_DRYRUN=1   watch shows status but never auto-merges
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Launch-binding guard (issue #60): require a real project config (refuse the engine-dogfood
# rule-3 fallback) and refuse a foreign $PWD — set BEFORE sourcing so herd-config.sh enforces it.
HERD_REQUIRE_PROJECT_CONFIG=1
. "$HERE/herd-config.sh"
# Runtime driver shim: route the coordinator agent launch through herd_driver_start_agent's seam so
# HERD_DRIVER=headless spawns a DETACHED coordinator (no herdr pane); the default herdr-claude driver
# emits the identical `herdr agent start … -- claude` below. Functions only — no side effects.
# shellcheck source=/dev/null
. "$HERE/driver.sh"
# Shared eyes-on-layout helper: fold stray tabs + rewrite the .herd-panes registry from OBSERVED
# state through the same primitives cmd_reload uses (functions only, no side effects on source).
# shellcheck source=/dev/null
. "$HERE/layout-reconcile.sh"
REPO="$PROJECT_ROOT"
herd_console_guard "coordinator" || exit 1

# 0. Fail fast if herdr is missing or its CLI/JSON contract has skewed — otherwise the very first
#    `herdr tab create` below blows up cryptically.
. "$HERE/herd-preflight.sh"
herd_preflight || exit 1

# Temp file for capturing stderr from each layout step; enables named failure messages so a
# silent abort under `set -euo pipefail` becomes a clear "ERROR [step]: reason" on stderr.
_CE="$(mktemp)"; trap 'rm -f "$_CE"' EXIT INT TERM
_coord_die() { printf 'ERROR [%s]: %s\n' "$1" "$(cat "$_CE")" >&2; exit 1; }

# 1. Resolve THIS project's OWN herdr workspace (labeled $WORKSPACE_NAME) — reuse if it already
#    exists, otherwise create a dedicated one. This is the multi-tenancy fix: every project gets its
#    own workspace, so launching project B's coordinator never lands in (or renames) project A's
#    ambient/focused workspace. We match on the project-scoped label and only ever touch a workspace
#    we created or that is already ours — never the ambient one.
WS=$(herdr workspace list 2>"$_CE" | LABEL="$WORKSPACE_NAME" python3 -c \
  'import sys,json,os; d=json.load(sys.stdin); print(next((w["workspace_id"] for w in d["result"]["workspaces"] if w.get("label")==os.environ["LABEL"]), ""))' \
  2>>"$_CE") || _coord_die "workspace resolve"

if [ -n "$WS" ]; then
  # 1a. REUSE: our workspace already exists. Focus it (bring it forward), then do a clean relaunch by
  #     closing our existing coordinator tab — scoped to THIS workspace via `--workspace`, so we never
  #     close another project's coordinator tab that happens to share the same project-scoped label.
  herdr workspace focus "$WS" >/dev/null 2>&1 || true
  # OBSERVE before mutating: fold away stray standalone control-room tabs (watch-<ws>/backlog-<ws>)
  # a prior bad reload may have left — their roles belong inside the coordinator tab rebuilt below,
  # and leaving them strands duplicate viewers/watchers off to the side.
  layout_fold_stray_tabs "$WS" "$WORKSPACE_NAME"
  existing=$(herdr tab list --workspace "$WS" 2>"$_CE" | LABEL="$HERD_TAB_COORDINATOR" python3 -c \
    'import sys,json,os; d=json.load(sys.stdin); print(next((t["tab_id"] for t in d["result"]["tabs"] if t.get("label")==os.environ["LABEL"]), ""))' \
    2>>"$_CE") || _coord_die "tab list"
  [ -n "$existing" ] && herdr tab close "$existing" >/dev/null 2>&1 || true
  # Fresh coordinator tab INSIDE our workspace (explicit --workspace, not the ambient one).
  created=$(herdr tab create --workspace "$WS" --cwd "$REPO" --label "$HERD_TAB_COORDINATOR" --focus \
    2>"$_CE") || _coord_die "tab create"
  _parsed=$(printf '%s' "$created" | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' \
    2>"$_CE") || _coord_die "tab create/parse"
  read -r TAB ROOT <<< "$_parsed"
else
  # 1b. CREATE: no workspace for this project yet. Create one with the right label up front (no
  #     post-hoc rename of the ambient workspace). Its root tab becomes the coordinator tab — relabel
  #     it so future relaunches (1a) can find + close it. We reuse the root pane/tab the create
  #     returns rather than spawning an extra tab, so a fresh workspace has no orphan default tab.
  created=$(herdr workspace create --cwd "$REPO" --label "$WORKSPACE_NAME" --focus \
    2>"$_CE") || _coord_die "workspace create"
  _parsed=$(printf '%s' "$created" | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["result"]; print(d["workspace"]["workspace_id"], d["tab"]["tab_id"], d["root_pane"]["pane_id"])' \
    2>"$_CE") || _coord_die "workspace create/parse"
  read -r WS TAB ROOT <<< "$_parsed"
  herdr tab rename "$TAB" "$HERD_TAB_COORDINATOR" >/dev/null 2>&1 || true
fi

# 2. Left (root) pane = pinned live backlog viewer.
herdr pane run "$ROOT" "bash $HERE/backlog-view.sh" >/dev/null 2>"$_CE" \
  || _coord_die "backlog-view pane"

# 2b. Install the rate_limit StopFailure hook on the COORDINATOR's repo, exactly as new-feature.sh
#     does for each builder worktree (herd_write_ratelimit_hook, from the herd-config.sh sourced
#     above). A coordinator turn that ends on the account usage limit then writes
#     $REPO/.herd-limit-sentinel — the same version-robust limit-hit signal the watcher already polls
#     for builders. This closes the coordinator's hook gap: without it, a limit-parked coordinator
#     leaves NO sentinel and the (opt-in) COORDINATOR_WATCHDOG has only the banner-scrape fallback.
#     Harmless + inert on its own (it only ever writes a sentinel file), so it is UNCONDITIONAL — the
#     watchdog that consumes the sentinel is what stays gated behind COORDINATOR_WATCHDOG. Best-effort.
herd_write_ratelimit_hook "$REPO"

# 3. Right pane = coordinator Claude, auto-running the generated coordinator skill.
started=$(herd_driver_launch_agent \
  name="$HERD_AGENT_COORDINATOR" workspace="$WS" cwd="$REPO" tab="$TAB" split=right focus=yes \
  model="$MODEL_COORDINATOR" pointer="$COORDINATOR_CMD" 2>"$_CE") || _coord_die "coordinator agent"
AGENT_PANE=$(printf '%s' "$started" | python3 -c \
  'import sys,json; print(json.load(sys.stdin)["result"]["agent"]["pane_id"])' \
  2>"$_CE") || _coord_die "coordinator agent/parse"

# 4. Pin the live herd-watch console BELOW the coordinator (auto-merges ready PRs, gated). Skip
#    with HERD_NO_WATCH=1; status-only with AGENT_WATCH_DRYRUN=1.
if [ "${HERD_NO_WATCH:-}" != "1" ]; then
  split=$(herdr pane split "$AGENT_PANE" --direction down --ratio 0.72 \
            --cwd "$REPO" --env "AGENT_WATCH_DRYRUN=${AGENT_WATCH_DRYRUN:-0}" \
            --env "HERD_WATCHER_TAB_ID=$TAB" --no-focus \
            2>"$_CE") || _coord_die "watch pane/split"
  WPANE=$(printf '%s' "$split" | python3 -c \
    'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])' \
    2>"$_CE") || _coord_die "watch pane/parse"
  herdr pane run "$WPANE" "bash $HERE/herd-watch.sh" >/dev/null 2>"$_CE" \
    || _coord_die "watch pane"
  echo "🛰  Coordinator up:  [ $BACKLOG_FILE | $COORDINATOR_CMD agent ⟂ 🐑 herd watch ]   tab $TAB"
else
  echo "🛰  Coordinator up:  [ $BACKLOG_FILE | $COORDINATOR_CMD agent ]   tab $TAB"
fi

# Record control-room pane IDs so 'herd reload' can refresh them in-place rather than always
# creating standalone tabs — written from the OBSERVED pane IDs this run just created, through the
# shared writer (each row stamped with this workspace_id as a 4th column so a later reader can drop
# a hint that names a foreign workspace, issue #60). reload re-writes on every run.
layout_write_registry "$WORKTREES_DIR/.herd-panes" "$WS" "$TAB" "$AGENT_PANE" "$ROOT" "${WPANE:-}"

echo "   jump to it:   herdr agent focus $HERD_AGENT_COORDINATOR"

# PROACTIVE soft-dep surfacing (HERD-45) — opt-in via DOCTOR_STARTUP_HINT (loaded from .herd/config
# above); a no-op / byte-identical launch unless it is "on". When on, surface any missing soft dep +
# the `herd doctor` fix now, at control-room startup, rather than waiting for the degradation to bite.
# _herd_soft_dep_startup_notice comes from herd-preflight.sh (already sourced above).
_herd_soft_dep_startup_notice
