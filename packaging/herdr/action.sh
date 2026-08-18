#!/usr/bin/env bash
# packaging/herdr/action.sh <verb> — the ONE command behind every herdkit herdr-plugin action.
#
# herdr runs plugin actions with cwd = the PLUGIN root (this checkout), not the project you invoked
# the action from. So this script (1) reads the focused workspace's cwd from the context JSON herdr
# injects, (2) opens the plugin's single `run` pane in THAT directory, and (3) hands the verb over in
# the HERDKIT_VERB env var. pane.sh (the pane's command) does the actual `herd <verb>` — see it for
# the verb table. Nothing here touches the project; it only opens a pane.
#
# Env (all injected by herdr, https://herdr.dev/docs/plugins/):
#   HERDR_BIN_PATH             the herdr binary to call back into
#   HERDR_PLUGIN_ID            our id ("herdkit"), needed to address our own pane entrypoint
#   HERDR_PLUGIN_CONTEXT_JSON  {workspace_cwd, focused_pane_cwd, focused_pane_id, workspace_id, ...}
#                              — where the user is (verified against herdr 0.8.0)
#   HERDR_WORKSPACE_ID         the focused workspace (so the pane opens beside the caller)
#   HERDKIT_PANE_PLACEMENT     optional override: split (default) | tab | zoomed | overlay
#   HERDKIT_PANE_DIRECTION     optional override for split: down (default) | right
# A split/zoomed pane must target an existing pane (herdr: "use target_pane_id"), so the focused
# pane id is passed as --target-pane; when the context carries none, placement degrades to tab.
set -euo pipefail

verb="${1:-}"
case "$verb" in
  init|launch|reload|status|backlog|doctor) ;;
  "") echo "action.sh: missing verb (init|launch|reload|status|backlog|doctor)" >&2; exit 2 ;;
  *)  echo "action.sh: unknown verb '$verb' (init|launch|reload|status|backlog|doctor)" >&2; exit 2 ;;
esac

herdr_bin="${HERDR_BIN_PATH:-herdr}"
plugin_id="${HERDR_PLUGIN_ID:-herdkit}"

# ── Resolve the project directory: workspace cwd, else the focused pane's cwd. ─────────────────
# python3 is a hard herdkit dependency already (herd doctor checks it); jq is the fallback so the
# pane still opens on a box where python3 is the missing dep the doctor is about to report.
ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"
cwd=""; target_pane=""
if [ -n "$ctx" ]; then
  if command -v python3 >/dev/null 2>&1; then
    # Two lines: cwd, then the focused pane id (either may be empty).
    _parsed="$(printf '%s' "$ctx" | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: d = {}
if not isinstance(d, dict): d = {}
def pick(*ks):
    for k in ks:
        v = d.get(k)
        if isinstance(v, str) and v: return v
    return ""
print(pick("workspace_cwd", "focused_pane_cwd", "pane_cwd", "cwd"))
print(pick("focused_pane_id", "pane_id"))' 2>/dev/null || true)"
    cwd="${_parsed%%$'\n'*}"; target_pane="${_parsed#*$'\n'}"
    [ "$target_pane" = "$_parsed" ] && target_pane=""
  elif command -v jq >/dev/null 2>&1; then
    cwd="$(printf '%s' "$ctx" | jq -r '.workspace_cwd // .focused_pane_cwd // .pane_cwd // .cwd // empty' 2>/dev/null || true)"
    target_pane="$(printf '%s' "$ctx" | jq -r '.focused_pane_id // .pane_id // empty' 2>/dev/null || true)"
  fi
fi
[ -z "$target_pane" ] && target_pane="${HERDR_PANE_ID:-}"
if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
  echo "action.sh: could not resolve the workspace directory from HERDR_PLUGIN_CONTEXT_JSON (got '${cwd:-}') — invoke the action from a workspace whose cwd is the project to herd" >&2
  exit 1
fi

placement="${HERDKIT_PANE_PLACEMENT:-split}"
direction="${HERDKIT_PANE_DIRECTION:-down}"
case "$placement" in
  split|zoomed) [ -n "$target_pane" ] || placement=tab ;;   # nothing to split beside → a tab
esac
set -- --plugin "$plugin_id" --entrypoint run --placement "$placement" --cwd "$cwd" \
       --env "HERDKIT_VERB=$verb" --focus
case "$placement" in
  split)  set -- "$@" --target-pane "$target_pane" --direction "$direction" ;;
  zoomed) set -- "$@" --target-pane "$target_pane" ;;
esac
# --workspace only when NOT targeting a pane: on herdr 0.8.0 passing both makes the server ignore
# the target and reject the split ("target an existing pane"); a target pane already implies its
# workspace.
case "$placement" in
  split|zoomed) ;;
  *) [ -n "${HERDR_WORKSPACE_ID:-}" ] && set -- "$@" --workspace "$HERDR_WORKSPACE_ID" ;;
esac
exec "$herdr_bin" plugin pane open "$@"
