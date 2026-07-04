#!/usr/bin/env bash
# driver.sh — the RUNTIME driver shim: the ONE seam binding each runtime-specific control-surface
# capability (the multiplexer + the agent runtime) to a concrete implementation, dispatched on the
# HERD_DRIVER config key (default herdr-claude). This is the runtime counterpart to the render-time
# {{DRIVER_*}} tokenization in bin/herd (docs/driver-abstraction.md phase 2).
#
# WHY THIS EXISTS (HERD-7): the coordinator SKILL is already driver-tokenized at render time. But the
# WATCHER (agent-watch.sh) and the LANE SCRIPTS exercise the SAME capabilities — list-agents,
# read-pane, send-text/keys, start-agent, notifications — at RUNTIME, hard-wired to herdr. This file
# makes those runtime uses driver-aware too, so HERD_DRIVER=headless makes panes a VIEW, not a
# dependency: the load-bearing core (merge gating, journal writes, notifications, limit detection)
# runs correctly with NO herdr panes at all. Unlocks Windows / CI / headless Linux.
#
# CONTRACT:
#   • SOURCED, not executed, by engine components AFTER herd-config.sh (which provides WORKTREES_DIR).
#     Defines functions ONLY; sourcing has NO side effects — safe in lib mode / hermetic tests.
#   • Also RUNNABLE as a CLI (`bash driver.sh <cap> …`) so the rendered HEADLESS coordinator skill
#     drives the same surface (list-agents / read-pane / send-text / focus / …). The CLI entrypoint —
#     and ONLY the CLI entrypoint — sources herd-config.sh to resolve WORKTREES_DIR.
#   • FAIL SOFT: every capability returns 0 (or a safe empty result) on any failure. A missing pane,
#     a missing herdr, a missing registry — NONE may abort a caller running under `set -euo pipefail`.
#   • BYTE-IDENTICAL DEFAULT: for HERD_DRIVER=herdr-claude every capability runs the EXACT herdr
#     command it replaces, so the default driver's behavior is unchanged.

# herd_driver_name — the active driver (env HERD_DRIVER wins; else the sourced config value; default).
herd_driver_name() { printf '%s' "${HERD_DRIVER:-herdr-claude}"; }

# _herd_driver_is_headless — success iff the active driver is the headless driver.
_herd_driver_is_headless() { [ "$(herd_driver_name)" = "headless" ]; }

# ── Headless detached-agent registry ─────────────────────────────────────────────────────────────
# Panes-as-a-view means the headless driver needs its own liveness surface. Each builder slug gets a
# directory under $WORKTREES_DIR/.herd/agents/<slug>/ holding:
#   pid     — the detached `claude` PID (liveness is `kill -0 <pid>`)
#   status  — a status word (working|idle|done); best-effort, defaults to "working" while alive
#   log     — captured stdout+stderr (the "pane" a human or the coordinator reads via read-pane)
#   input   — an append-only queue that send-text writes (a headless runtime may drain it)
_herd_agents_dir() {
  local base="${WORKTREES_DIR:-${TREES:-.}}"
  printf '%s' "$base/.herd/agents"
}
_herd_agent_dir() { printf '%s/%s' "$(_herd_agents_dir)" "$1"; }

# ── notify ───────────────────────────────────────────────────────────────────────────────────────
# herd_driver_notify <title> <body> [sound] — surface a desktop-style notification. Load-bearing:
# the watcher notifies on ready/held PRs, dead/respawned builders, and limit resumes. herdr-claude:
# the exact `herdr notification show` call. headless: a durable notifications.log sink (always) plus
# a best-effort native desktop notification. NEVER fails.
herd_driver_notify() {
  local title="${1:-}" body="${2:-}" sound="${3:-default}"
  if _herd_driver_is_headless; then
    _herd_headless_notify "$title" "$body" "$sound"
  else
    herdr notification show "$title" --body "$body" --sound "$sound" >/dev/null 2>&1 || true
  fi
  return 0
}
_herd_headless_notify() {
  local title="${1:-}" body="${2:-}" log ts
  log="${WORKTREES_DIR:-${TREES:-.}}/.herd/notifications.log"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  mkdir -p "${log%/*}" 2>/dev/null || true
  # Tab-separated one-liner: timestamp, title, body. The durable sink — always written.
  printf '%s\t%s\t%s\n' "$ts" "$title" "$body" >> "$log" 2>/dev/null || true
  # Best-effort native desktop notification (bonus, never required). Kill-switch: NATIVE_NOTIFY=off.
  if [ "${HERD_HEADLESS_NATIVE_NOTIFY:-}" != "off" ]; then
    if command -v osascript >/dev/null 2>&1; then
      osascript -e "display notification \"${body//\"/}\" with title \"${title//\"/}\"" >/dev/null 2>&1 || true
    elif command -v notify-send >/dev/null 2>&1; then
      notify-send "$title" "$body" >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

# ── list-agents ──────────────────────────────────────────────────────────────────────────────────
# herd_driver_agent_list_json — emit the agent roster as JSON in herdr's shape
# ({"result":{"agents":[{"name":<slug>,"agent_status":<word>},…]}}), which the watcher parses for
# builder liveness (dead-builder reconciliation). herdr-claude: `herdr agent list`. headless:
# synthesized from the detached-agent registry, so DEAD detection works with no panes.
herd_driver_agent_list_json() {
  if _herd_driver_is_headless; then
    _herd_headless_agent_list_json
  else
    herdr agent list 2>/dev/null || echo '{}'
  fi
}
_herd_headless_agent_list_json() {
  local dir; dir="$(_herd_agents_dir)"
  HERD_AG_DIR="$dir" python3 - <<'PY' 2>/dev/null || echo '{"result":{"agents":[]}}'
import os, json
d = os.environ.get("HERD_AG_DIR", "")
agents = []
if d and os.path.isdir(d):
    for slug in sorted(os.listdir(d)):
        adir = os.path.join(d, slug)
        if not os.path.isdir(adir):
            continue
        try:
            with open(os.path.join(adir, "pid")) as f:
                pid = f.read().strip()
        except OSError:
            pid = ""
        # A recorded-but-dead pid is NOT a listed agent — it mirrors a pane that was destroyed, which
        # is exactly the signal dead-builder reconciliation keys off. Only live pids appear.
        if not pid.isdigit():
            continue
        try:
            os.kill(int(pid), 0)
        except OSError:
            continue
        status = "working"
        try:
            with open(os.path.join(adir, "status")) as f:
                s = f.read().strip()
                if s:
                    status = s
        except OSError:
            pass
        agents.append({"name": slug, "agent_status": status})
print(json.dumps({"result": {"agents": agents}}, separators=(",", ":")))
PY
}

# ── read-pane ────────────────────────────────────────────────────────────────────────────────────
# herd_driver_read_pane <pane-or-slug> [source] — capture the current pane contents. herdr-claude:
# `herdr pane read`. headless: tail the detached agent's captured log (its on-disk stdout+stderr).
# FAILS SAFE to empty output.
herd_driver_read_pane() {
  local target="${1:-}" source="${2:-}"
  if _herd_driver_is_headless; then
    local f; f="$(_herd_agent_dir "$target")/log"
    [ -f "$f" ] && tail -c "${HERD_READ_PANE_BYTES:-16384}" "$f" 2>/dev/null || true
  elif [ -n "$source" ]; then
    herdr pane read "$target" --source "$source" 2>/dev/null || true
  else
    herdr pane read "$target" 2>/dev/null || true
  fi
}

# ── send-text ────────────────────────────────────────────────────────────────────────────────────
# herd_driver_send_text <pane-or-slug> <text> — send an auto-submitted prompt/command to a builder.
# herdr-claude: `herdr pane run`. headless: append to the agent's input queue (best-effort; a bare
# `claude` process does not drain it, so for the default runtime this is a documented no-op seam an
# SDK/headless runtime can consume). NEVER fails.
herd_driver_send_text() {
  local target="${1:-}" text="${2:-}"
  if _herd_driver_is_headless; then
    local q; q="$(_herd_agent_dir "$target")/input"
    mkdir -p "${q%/*}" 2>/dev/null || true
    printf '%s\n' "$text" >> "$q" 2>/dev/null || true
  else
    herdr pane run "$target" "$text" >/dev/null 2>&1 || true
  fi
  return 0
}

# ── send-keys ────────────────────────────────────────────────────────────────────────────────────
# herd_driver_send_keys <pane> <keys…> — send raw control keystrokes. herdr-claude:
# `herdr pane send-keys`. headless: NO-OP (raw keystrokes are a pane concept; nothing receives them).
# NEVER fails.
herd_driver_send_keys() {
  local target="${1:-}"; shift || true
  if _herd_driver_is_headless; then
    : # no-op: view-only — headless has no pane to receive raw keystrokes
  else
    herdr pane send-keys "$target" "$@" >/dev/null 2>&1 || true
  fi
  return 0
}

# ── create-tab ───────────────────────────────────────────────────────────────────────────────────
# herd_driver_create_tab [args…] — create a tab/pane. herdr-claude: `herdr tab create`. headless:
# NO-OP (headless has no tabs; the lane spawns a detached process instead). NEVER fails.
herd_driver_create_tab() {
  if _herd_driver_is_headless; then
    : # no-op: view-only — headless has no tabs
  else
    herdr tab create "$@" 2>/dev/null || true
  fi
  return 0
}

# ── focus-agent ──────────────────────────────────────────────────────────────────────────────────
# herd_driver_focus_agent <slug> — jump to a builder's agent. herdr-claude: `herdr agent focus`.
# headless: VIEW — no pane to focus; print how to tail the agent's log. NEVER fails.
herd_driver_focus_agent() {
  local slug="${1:-}"
  if _herd_driver_is_headless; then
    printf 'headless: no pane to focus for %s. Tail its log:\n  tail -f %s\n' "$slug" "$(_herd_agent_dir "$slug")/log"
  else
    herdr agent focus "$slug" 2>/dev/null || true
  fi
  return 0
}

# ── start-agent ──────────────────────────────────────────────────────────────────────────────────
# herd_driver_start_agent <slug> <worktree> <model> <flags> <pointer> [split] — spawn a builder agent
# on a task. herdr-claude: a fresh herdr tab + `herdr agent start … claude`. headless: a DETACHED
# background `claude` (nohup) whose stdout+stderr land in the registry log, with a pid/status file so
# list-agents can report its liveness. Returns 0 iff an agent was started.
herd_driver_start_agent() {
  local slug="${1:-}" wt="${2:-}" model="${3:-}" flags="${4:-}" pointer="${5:-}" split="${6:-}"
  if _herd_driver_is_headless; then
    _herd_headless_start_agent "$slug" "$wt" "$model" "$flags" "$pointer"
  else
    _herd_herdr_start_agent "$slug" "$wt" "$model" "$flags" "$pointer" "$split"
  fi
}
_herd_headless_start_agent() {
  local slug="$1" wt="$2" model="$3" flags="$4" pointer="$5"
  [ -n "$slug" ] && [ -d "$wt" ] || { printf '⚠️  headless: bad slug/worktree for start-agent (%s / %s)\n' "$slug" "$wt" >&2; return 1; }
  command -v claude >/dev/null 2>&1 || { printf '⚠️  headless: claude not on PATH — cannot start detached agent %s\n' "$slug" >&2; return 1; }
  local adir; adir="$(_herd_agent_dir "$slug")"
  mkdir -p "$adir" 2>/dev/null || { printf '⚠️  headless: cannot create agent registry dir %s\n' "$adir" >&2; return 1; }
  : "${flags:=--dangerously-skip-permissions}"
  # Detached, no controlling terminal, no pane: stdout+stderr → the registry log (the "pane").
  # shellcheck disable=SC2086  # $flags intentionally word-splits (mirrors the lane's $CLAUDE_FLAGS).
  ( cd "$wt" || exit 1; nohup claude --model "$model" $flags "$pointer" >"$adir/log" 2>&1 </dev/null & echo $! > "$adir/pid" )
  printf 'working\n' > "$adir/status" 2>/dev/null || true
  [ -s "$adir/pid" ]
}
_herd_herdr_start_agent() {
  local slug="$1" wt="$2" model="$3" flags="$4" pointer="$5" split="$6"
  local wsid; wsid="$(herd_resolve_workspace_id 2>/dev/null || true)"
  local created tab root
  # shellcheck disable=SC2086  # ${wsid:+…} deliberately word-splits into two argv when set
  created="$(herdr tab create ${wsid:+--workspace "$wsid"} --cwd "$wt" --label "$slug" --no-focus 2>/dev/null || true)"
  read -r tab root < <(printf '%s' "$created" | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' 2>/dev/null || true)
  [ -n "${tab:-}" ] || return 1
  printf '%s %s builder\n' "$slug" "$tab" >> "${WORKTREES_DIR:-.}/.herd-tabs" 2>/dev/null || true
  : "${flags:=--dangerously-skip-permissions}"
  # shellcheck disable=SC2086  # $wsid/$flags intentionally word-split (mirror the lane's args)
  herdr agent start "$slug" ${wsid:+--workspace "$wsid"} --cwd "$wt" --tab "$tab" ${split:+--split "$split"} --no-focus -- claude --model "$model" $flags "$pointer" >/dev/null 2>&1
}

# ── CLI entrypoint ───────────────────────────────────────────────────────────────────────────────
# Only runs when EXECUTED (not sourced): `bash driver.sh <cap> …`. Sources herd-config.sh for
# WORKTREES_DIR, then dispatches to the capability. This is what the rendered headless coordinator
# skill calls (list-agents / read-pane / send-text / focus / …).
_herd_driver_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    list-agents) herd_driver_agent_list_json ;;
    read-pane)   herd_driver_read_pane "$@" ;;
    send-text)   herd_driver_send_text "$@" ;;
    send-keys)   herd_driver_send_keys "$@" ;;
    create-tab)  herd_driver_create_tab "$@" ;;
    focus)       herd_driver_focus_agent "$@" ;;
    notify)      herd_driver_notify "$@" ;;
    name)        herd_driver_name; echo ;;
    *) printf 'usage: driver.sh {list-agents|read-pane <slug>|send-text <slug> <text>|send-keys <slug> <keys…>|create-tab <slug>|focus <slug>|notify <title> <body> [sound]|name}\n' >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _HERD_DRIVER_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  . "$_HERD_DRIVER_HERE/herd-config.sh"
  _herd_driver_cli "$@"
fi
