#!/usr/bin/env bash
# packaging/herdr/pane.sh — the command of the herdkit plugin's single `run` pane.
#
# Opened by action.sh with cwd = the project (the focused workspace's directory) and the verb in
# HERDKIT_VERB. Puts the plugin's own bin/ FIRST on PATH so `herd` — here and in every child the
# engine spawns from this pane — resolves to the engine that shipped with the plugin
# ($HERDR_PLUGIN_ROOT), never to some other checkout that happens to be on PATH. Then runs the verb:
#
#   init     herd init                       interactive interview + scout → writes .herd/config
#   launch   scripts/herd/coordinator.sh     the control room: coordinator agent + backlog + watcher
#   reload   herd reload                     rebuild the control room around a live coordinator
#   status   herd status                     one-shot read-only snapshot (exit≠0 = needs attention)
#   backlog  herd backlog --rich             open work items with state/assignee
#   doctor   herd doctor                     dependency doctor with per-platform hints
#
# One-shot verbs hold the pane open afterwards ("press Enter to close") so the output can be read;
# without that the split would vanish the instant `herd status` returned. Interactive verbs (init)
# hand the tty straight to herd.
set -uo pipefail

root="${HERDR_PLUGIN_ROOT:-}"
if [ -z "$root" ] || [ ! -x "$root/bin/herd" ]; then
  # Linked/installed by herdr this is always set; fall back to our own location for a bare run.
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
[ -x "$root/bin/herd" ] || { echo "herdkit pane: no executable bin/herd under '$root'" >&2; exit 1; }
export PATH="$root/bin:$PATH"
export HERDKIT_HOME="$root"

verb="${HERDKIT_VERB:-status}"
hold() {
  # $1 = exit status of the verb. Keep the pane readable; Enter (or EOF) closes it.
  printf '\n[herdkit] %s finished (exit %s) — press Enter to close this pane\n' "$verb" "$1"
  read -r _ 2>/dev/null || true
  exit "$1"
}

case "$verb" in
  init)    exec herd init ;;
  launch)  bash "$root/scripts/herd/coordinator.sh"; hold "$?" ;;
  reload)  herd reload; hold "$?" ;;
  status)  herd status; hold "$?" ;;
  backlog) herd backlog --rich; hold "$?" ;;
  doctor)  herd doctor; hold "$?" ;;
  *) echo "herdkit pane: unknown HERDKIT_VERB '$verb' (init|launch|reload|status|backlog|doctor)" >&2; hold 2 ;;
esac
