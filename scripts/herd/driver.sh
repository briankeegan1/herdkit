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
# herd_driver_close_pane <pane-id> — RETIRE a pane (the reviewer-pane lifecycle, HERD-113). herdr-claude:
# `herdr pane close`. headless: NO-OP (panes-as-a-view — a detached reviewer has no pane to close; its
# process lifecycle is the registry pid, not a pane). FAIL-SOFT: a missing herdr / already-gone pane is
# a clean no-op that never aborts a caller — retiring a reviewer pane must never block the merge gate.
herd_driver_close_pane() {
  local target="${1:-}"
  [ -n "$target" ] || return 0
  if _herd_driver_is_headless; then
    : # no-op: view-only — headless has no pane to close
  else
    herdr pane close "$target" >/dev/null 2>&1 || true
  fi
  return 0
}

# ── guarded pane close (HERD-134) ──────────────────────────────────────────────────────────────────
# The reviewer-pane lifecycle, the review re-dispatch split-close, and the sweeps all close panes by a
# CAPTURED pane id or agent name. A stale/recycled/wrong id kills an innocent NEIGHBOUR — the
# 2026-07-08 incident where a reviewer retire (registry pane id) plus a re-dispatch's purge-old-split
# close vaporised PR #249's live BUILDER pane sharing that tab ("agent session dead" → failed refix
# wakes → hand re-tasking). Same hazard class as cross-project watcher kills (argv0 tagging) and reap
# safety. The fix: verify a pane's LIVE identity at close time and REFUSE when it is not what the
# caller believes it is — loud (a journaled pane_close_refused), never silent.

# herd_driver_pane_identity <pane-id> — read a pane's LIVE identity as a single token, the ground truth
# the guarded close proves a pane against before closing it. Three sources, in priority order — the
# same eyes layout-reconcile / agent-liveness use:
#   agent:<name>  a registered agent (herdr carries the identity in `name` OR `agent`, matched by
#                 pane_id) — e.g. agent:review·<slug>, agent:<builder-slug>. The agent-pane reviewer.
#   pane:<label>  a pane's own LABEL (herdr pane rename / --label), matched by pane_id — the identity
#                 of a NON-agent named pane, e.g. the standalone review·<slug> tail pane.
#   argv:<cmd>    an unlabelled non-agent pane, classified by its FOREGROUND process cmdline (the
#                 scribe drainer, the task-spec viewer, a tail, …)
# Echoes NOTHING when the identity cannot be read (headless — no panes; herdr absent; a gone/opaque
# pane). FAIL-SOFT: a probe that cannot see the truth returns empty so the guard REFUSES rather than
# closing blind — it never fabricates an identity.
herd_driver_pane_identity() {
  local pane="${1:-}"
  [ -n "$pane" ] || return 0
  _herd_driver_is_headless && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  # 1) An agent pane: match this pane_id in the roster. Tolerate BOTH identity keys (`name` for an
  #    `herdr agent start` agent, `agent` for a `herdr pane report-agent` one) — the same breadth
  #    herd_driver_agent_liveness uses so the probe finds the identity however it was registered.
  local name
  name="$(herdr agent list 2>/dev/null | PANE="$pane" python3 -c '
import sys, json, os
pane = os.environ["PANE"]
try:
  for a in (json.load(sys.stdin).get("result") or {}).get("agents") or []:
    if str(a.get("pane_id","")) == pane:
      print("agent:" + (a.get("name") or a.get("agent") or ""), end=""); break
except Exception:
  pass
' 2>/dev/null || true)"
  if [ -n "$name" ]; then printf '%s' "$name"; return 0; fi
  # 2) A named non-agent pane: match this pane_id in the pane roster and read its label (what
  #    `herdr pane rename` / `--label` set) — the identity of the standalone-fallback review pane.
  local label
  label="$(herdr pane list 2>/dev/null | PANE="$pane" python3 -c '
import sys, json, os
pane = os.environ["PANE"]
try:
  for p in (json.load(sys.stdin).get("result") or {}).get("panes") or []:
    if str(p.get("pane_id","")) == pane:
      lbl = p.get("label") or ""
      if lbl: print("pane:" + lbl, end="")
      break
except Exception:
  pass
' 2>/dev/null || true)"
  if [ -n "$label" ]; then printf '%s' "$label"; return 0; fi
  # 3) An unlabelled non-agent pane: classify by the foreground cmdline (excluding the pane's own shell).
  herdr pane process-info --pane "$pane" 2>/dev/null | python3 -c '
import sys, json
try:
  pi = (json.load(sys.stdin).get("result") or {}).get("process_info")
except Exception:
  sys.exit(0)
if not pi:
  sys.exit(0)
sh = pi.get("shell_pid") or 0
fg = [p for p in (pi.get("foreground_processes") or []) if p.get("pid") != sh]
cmd = " ".join((p.get("cmdline") or "") for p in fg).strip()
if cmd:
  sys.stdout.write("argv:" + cmd)
' 2>/dev/null || true
}

# _herd_pane_close_refused_journal <pane> <expected> <actual> <reason> — record a REFUSED close. The
# pane_close_refused event is the forensic ALARM (herd why / herd log) that a close was withheld
# because the pane was NOT what the caller expected — carrying BOTH the expected and actual identities.
# journal.sh is sourced by both engine surfaces that call the guard (agent-watch.sh + herd-review.sh);
# when it is NOT in scope (driver.sh sourced standalone / the CLI) this degrades to a silent no-op so
# driver.sh keeps its zero-dependency, no-side-effect sourcing contract.
_herd_pane_close_refused_journal() {
  command -v journal_append >/dev/null 2>&1 || return 0
  journal_append pane_close_refused pane "${1:-}" expected "${2:-}" actual "${3:-}" reason "${4:-}"
}

# herd_close_pane_verified <pane-id> <expected-kind> — the ONE guarded pane-close every engine actor
# routes through (HERD-134). Reads the pane's LIVE identity (herd_driver_pane_identity) and closes it
# ONLY when that identity CONTAINS <expected-kind> (e.g. "review·" for a reviewer split/pane). On a
# mismatch — the pane id is stale/recycled and now names an innocent neighbour (the builder kill) — it
# REFUSES the close and journals pane_close_refused with BOTH identities. On an unreadable identity it
# also refuses (fail-soft: never close blind, journal and move on). Returns 0 IFF the pane was closed.
# BYTE-IDENTICAL when identities match: a normal retire closes exactly as before.
herd_close_pane_verified() {
  local pane="${1:-}" kind="${2:-}"
  [ -n "$pane" ] || return 1
  # Headless has no panes to verify OR close: defer to the (no-op) driver close so behaviour is
  # byte-identical to the pre-guard path (which never reached a close under headless anyway).
  if _herd_driver_is_headless; then herd_driver_close_pane "$pane"; return 0; fi
  # A missing expected-kind would substring-match anything — refuse rather than close indiscriminately.
  [ -n "$kind" ] || { _herd_pane_close_refused_journal "$pane" "$kind" "" no-expected-kind; return 1; }
  local ident; ident="$(herd_driver_pane_identity "$pane" 2>/dev/null || true)"
  if [ -z "$ident" ]; then
    _herd_pane_close_refused_journal "$pane" "$kind" "" identity-unreadable
    return 1
  fi
  case "$ident" in
    *"$kind"*)
      herd_driver_close_pane "$pane"
      return 0 ;;
    *)
      _herd_pane_close_refused_journal "$pane" "$kind" "$ident" identity-mismatch
      return 1 ;;
  esac
}

# herd_driver_pane_alive <pane-id> — success iff the pane still EXISTS in the live control surface.
# The reviewer-adoption / orphan-sweep liveness probe (HERD-113): after a herdr server death + reload a
# reviewer PANE can outlive its poller pid, so "is the pane still there?" is the signal that must gate a
# re-dispatch (never duplicate into a live reviewer). herdr-claude: `herdr pane read` succeeds only for
# a live pane. headless: always FALSE (no panes; liveness there is the registry pid, checked separately).
# FAIL-SOFT: a missing herdr / unreadable pane → not-alive, so the caller degrades to the pid guard.
herd_driver_pane_alive() {
  local target="${1:-}"
  [ -n "$target" ] || return 1
  if _herd_driver_is_headless; then
    return 1
  fi
  command -v herdr >/dev/null 2>&1 || return 1
  herdr pane read "$target" >/dev/null 2>&1
}

# herd_driver_agent_liveness <slug> [pane_id] — THREE-VALUED liveness of a builder's agent SESSION:
# whether its underlying agent PROCESS is actually running, as opposed to a stale agent_status word
# herdr keeps reporting after a crash killed it (HERD-114). This is DISTINCT from mere pane EXISTENCE
# (herd_driver_pane_alive) and from the status word: the 2026-07-08 incident had a herdr server stop
# KILL both builders' claude processes while their tabs/panes/worktrees persisted and `herdr agent
# list` still reported a stale 'done' — so neither pane-alive nor the status word could tell the
# session was dead. Echoes exactly one token:
#   alive   — POSITIVE evidence the session process runs (headless: a live registry pid; herdr-claude:
#             the agent's pane still has a foreground `claude` process)
#   dead    — POSITIVE evidence it is GONE but a pane REMAINS (headless: a pid recorded but not running;
#             herdr-claude: the pane EXISTS but runs NO claude — a bare shell left behind after the
#             process was killed). "agent dead" = pane present, session unresponsive.
#   missing — POSITIVE evidence the tab has NO agent pane AT ALL (herdr-claude only): herdr answered but
#             the agent is neither in the roster NOR does any pane carry its '<slug>' label — the
#             pane vanished entirely (HERD-135). Distinct from 'dead' (pane present) so a caller can
#             surface 'agent missing' and never bounce a refix into nobody. Only ever returned when
#             herdr responded, so it is never a fabricated absence. Headless never returns this (its
#             liveness is registry-pid based, not pane based — a gone record reads 'unknown').
#   unknown — cannot tell (herdr/process-info absent or unparseable, pane gone, no registry record).
#             FAIL-SOFT: a probe that cannot see the truth NEVER fabricates a death/absence, so a
#             caller degrades to its prior behavior and never false-reds (no-false-red).
herd_driver_agent_liveness() {
  local slug="${1:-}" pane="${2:-}"
  [ -n "$slug" ] || { printf 'unknown'; return 0; }
  if _herd_driver_is_headless; then
    local pidf pid
    pidf="$(_herd_agent_dir "$slug")/pid"
    [ -f "$pidf" ] || { printf 'unknown'; return 0; }
    pid="$(cat "$pidf" 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
    if kill -0 "$pid" 2>/dev/null; then printf 'alive'; else printf 'dead'; fi
    return 0
  fi
  command -v herdr >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  # Resolve the agent's pane when the caller didn't pass one. herdr carries the identity in EITHER
  # `name` (a builder started via `herdr agent start <slug>`) or `agent` (one reported via
  # `herdr pane report-agent --agent <slug>`), so match both — the same tolerance herdr's own consumers
  # use — so the probe finds the pane however the agent was registered.
  if [ -z "$pane" ]; then
    pane="$(herdr agent list 2>/dev/null | SLUG="$slug" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
  for a in (json.load(sys.stdin).get("result") or {}).get("agents") or []:
    if a.get("name") == slug or a.get("agent") == slug:
      print(a.get("pane_id", "") or "", end=""); break
except Exception:
  pass
' 2>/dev/null || true)"
  fi
  # HERD-135: an agent DELISTED from the roster (its process died and herdr dropped the registration)
  # may still own its pane — LABELLED '<slug>' by the lane at spawn. Consult that label so a
  # delisted-but-present pane is still classified (dead/alive) rather than mis-read as gone. Best-effort;
  # a driver/pane with no label just yields no match and we fall through to the 'missing' verdict below.
  if [ -z "$pane" ]; then
    pane="$(herdr pane list 2>/dev/null | SLUG="$slug" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
  for p in (json.load(sys.stdin).get("result") or {}).get("panes") or []:
    if str(p.get("label", "")) == slug:
      print(p.get("pane_id", "") or "", end=""); break
except Exception:
  pass
' 2>/dev/null || true)"
  fi
  # No agent in the roster AND no pane carries its label: herdr answered (checked above) yet the agent
  # pane is positively ABSENT — the tab has NO agent pane at all. Return 'missing' (distinct from the
  # probe-blind 'unknown') so a caller surfaces 'agent missing' and never bounces a refix into nobody.
  [ -n "$pane" ] || { printf 'missing'; return 0; }
  # Classify the pane by the process in its FOREGROUND — the same ground-truth eyes layout-reconcile
  # uses: a live `claude` ⇒ alive; a shell with no claude foreground ⇒ dead (the process was killed
  # but the pane persists as a bare shell); missing/opaque process-info or a gone pane ⇒ unknown.
  herdr pane process-info --pane "$pane" 2>/dev/null | python3 -c '
import sys, json
try:
  pi = (json.load(sys.stdin).get("result") or {}).get("process_info")
except Exception:
  print("unknown"); sys.exit(0)
if not pi:
  print("unknown"); sys.exit(0)
sh = pi.get("shell_pid") or 0
if not sh:
  print("unknown"); sys.exit(0)
fg = [p for p in (pi.get("foreground_processes") or []) if p.get("pid") != sh]
print("alive" if any("claude" in (p.get("cmdline") or "") for p in fg) else "dead")
' 2>/dev/null || printf 'unknown'
}

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

# ── pane rename / role labelling (HERD-135) ─────────────────────────────────────────────────────────
# herd_driver_pane_rename <pane> <label> — set a pane's role LABEL. The builder lanes call this at
# spawn to name each pane by role ('<slug>' for the agent pane, 'task-spec·<slug>' for the viewer,
# 'shell·<slug>' for the bare root shell) so the dead-agent-eyes probe (herd_driver_agent_liveness)
# and the coordinator READ a pane's role instead of guessing from position/cmdline — the fix for the
# 2026-07-08 incident where a `claude --continue` was typed into the task-spec viewer pane. herdr-claude:
# `herdr pane rename`. headless: NO-OP (panes-as-a-view — nothing to label). FAIL-SOFT: a missing
# herdr / gone pane / driver that does not support rename is a clean no-op, so the probe simply falls
# back to today's heuristic (no red row). NEVER fails.
herd_driver_pane_rename() {
  local target="${1:-}" label="${2:-}"
  [ -n "$target" ] && [ -n "$label" ] || return 0
  if _herd_driver_is_headless; then
    : # no-op: view-only — headless has no pane to label
  else
    herdr pane rename "$target" "$label" >/dev/null 2>&1 || true
  fi
  return 0
}

# herd_driver_agent_pane_id <slug> — echo the pane_id herdr currently associates with this agent
# (matched on the `name` OR `agent` identity key, the same breadth the liveness probe uses), so the
# lane can LABEL the freshly-created agent pane. Empty (no output) when headless / herdr absent / the
# agent is not yet listed. FAIL-SOFT: never aborts a caller under set -euo pipefail.
herd_driver_agent_pane_id() {
  local slug="${1:-}"
  [ -n "$slug" ] || return 0
  _herd_driver_is_headless && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  herdr agent list 2>/dev/null | SLUG="$slug" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
  for a in (json.load(sys.stdin).get("result") or {}).get("agents") or []:
    if a.get("name") == slug or a.get("agent") == slug:
      print(a.get("pane_id", "") or "", end=""); break
except Exception:
  pass
' 2>/dev/null || true
}

# herd_driver_pane_id_from_agent_start <json> — best-effort extract of the agent pane id from an
# `herdr agent start` result. Tolerates the shapes herdr uses (result.agent.pane_id /
# result.pane.pane_id / result.pane_id) so a lane can label the pane WITHOUT a second `agent list`
# round-trip. PURE (no herdr call — safe on captured stdout); empty on any parse failure.
herd_driver_pane_id_from_agent_start() {
  local json="${1:-}"
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c '
import sys, json
try:
  r = (json.load(sys.stdin).get("result") or {})
  pid = ""
  for k in ("agent", "pane"):
    v = r.get(k)
    if isinstance(v, dict) and v.get("pane_id"):
      pid = v["pane_id"]; break
  if not pid and r.get("pane_id"):
    pid = r["pane_id"]
  sys.stdout.write(str(pid or ""))
except Exception:
  pass
' 2>/dev/null || true
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

# ── start-agent (generalized) ──────────────────────────────────────────────────────────────────────
# herd_driver_launch_agent key=value … — the GENERALIZED start-agent entry the NON-builder lanes use
# (coordinator, fleet room, resolver, reviewer, researcher, scribe). The positional
# herd_driver_start_agent above is builder-shaped (slug/worktree/model/flags/pointer/split) and cannot
# express the launch shapes these lanes need: a CUSTOM agent name, an ARBITRARY cwd (usually $REPO, not
# a worktree), an EXPLICIT pre-created tab (each lane owns the surrounding panes), a split DIRECTION,
# a FOCUS flag, per-launch ENV vars, and an explicit (possibly EMPTY) flags set for the human seats.
#
# Options are passed as `key=value` positional args (bash-3.2 safe — NO assoc arrays / namerefs, which
# the codebase deliberately avoids for macOS's bash 3.2; see codemap.sh). Split on the FIRST `=` so a
# value may itself contain `=` (prompts do). Recognized keys (all optional unless noted):
#   name       agent name (REQUIRED)
#   cwd        working directory the agent starts in (REQUIRED)
#   pointer    opening prompt / skill command, passed after `-- claude … "<pointer>"`
#   model      model id; empty/omitted → no --model (e.g. the coordinator relaunch)
#   flags      claude flags, word-split; empty/omitted → NONE passed (the human seats). The headless
#              backend ALWAYS forces --dangerously-skip-permissions — a detached agent has no tty and
#              cannot answer a permission prompt.
#   workspace  herdr workspace id; provided-but-empty → omit --workspace (mirrors ${_WS_ID:+…});
#              omitted entirely → resolve via herd_resolve_workspace_id (the builder default)
#   tab        explicit herdr tab id; every routed lane pre-creates its tab. headless ignores it.
#   split      herdr split direction (right|down|''); empty → no --split
#   focus      'yes' → focus the new agent (omit --no-focus); anything else → --no-focus
#   env        one K=V; may be repeated (env=A=1 env=B=2) → each becomes a --env "K=V"
#
# herdr-claude: emits the SAME `herdr agent start … -- claude …` argv the lane hardcoded (byte-identical
# flag order), so its stdout (the JSON) flows to the caller for pane_id parsing and its exit status
# propagates so a fail-loud lane's `|| die` still fires. headless: a DETACHED background `claude`
# (nohup) into the registry, exactly like the builder headless path. Returns the launch exit status.
herd_driver_launch_agent() {
  local sa_name="" sa_cwd="" sa_pointer="" sa_model="" sa_flags="" sa_split="" sa_tab="" sa_focus="" sa_env=""
  local sa_ws="" sa_ws_set=0 kv key val
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    case "$key" in
      name)      sa_name="$val" ;;
      cwd)       sa_cwd="$val" ;;
      pointer)   sa_pointer="$val" ;;
      model)     sa_model="$val" ;;
      flags)     sa_flags="$val" ;;
      split)     sa_split="$val" ;;
      tab)       sa_tab="$val" ;;
      focus)     sa_focus="$val" ;;
      workspace) sa_ws="$val"; sa_ws_set=1 ;;
      env)       sa_env="${sa_env}${sa_env:+$'\n'}$val" ;;
      *)         : ;;  # ignore unknown keys (forward-compat)
    esac
  done
  [ -n "$sa_name" ] || { printf '⚠️  driver: launch-agent called with no name\n' >&2; return 1; }

  if _herd_driver_is_headless; then
    [ -d "$sa_cwd" ] || { printf '⚠️  headless: bad cwd for launch-agent %s (%s)\n' "$sa_name" "$sa_cwd" >&2; return 1; }
    command -v claude >/dev/null 2>&1 || { printf '⚠️  headless: claude not on PATH — cannot start detached agent %s\n' "$sa_name" >&2; return 1; }
    local adir; adir="$(_herd_agent_dir "$sa_name")"
    mkdir -p "$adir" 2>/dev/null || { printf '⚠️  headless: cannot create agent registry dir %s\n' "$adir" >&2; return 1; }
    : "${sa_flags:=--dangerously-skip-permissions}"
    # Detached, no tty, no pane: stdout+stderr → the registry log; env vars exported into the child.
    ( cd "$sa_cwd" || exit 1
      # shellcheck disable=SC2163  # $_l is a literal "K=V" pair — `export "K=V"` sets+exports it.
      if [ -n "$sa_env" ]; then while IFS= read -r _l; do [ -n "$_l" ] && export "$_l"; done <<< "$sa_env"; fi
      # shellcheck disable=SC2086  # $sa_flags intentionally word-splits (mirrors the lane's flags)
      if [ -n "$sa_model" ]; then
        nohup claude --model "$sa_model" $sa_flags "$sa_pointer" >"$adir/log" 2>&1 </dev/null & echo $! > "$adir/pid"
      else
        nohup claude $sa_flags "$sa_pointer" >"$adir/log" 2>&1 </dev/null & echo $! > "$adir/pid"
      fi )
    printf 'working\n' > "$adir/status" 2>/dev/null || true
    [ -s "$adir/pid" ]
    return
  fi

  # herdr-claude: build the exact argv the lane hardcoded (indexed array — bash-3.2 safe).
  local ws
  if [ "$sa_ws_set" = 1 ]; then ws="$sa_ws"; else ws="$(herd_resolve_workspace_id 2>/dev/null || true)"; fi
  local -a argv
  argv=(herdr agent start "$sa_name")
  [ -n "$ws" ] && argv+=(--workspace "$ws")
  argv+=(--cwd "$sa_cwd")
  [ -n "$sa_tab" ] && argv+=(--tab "$sa_tab")
  [ -n "$sa_split" ] && argv+=(--split "$sa_split")
  [ "$sa_focus" != "yes" ] && argv+=(--no-focus)
  if [ -n "$sa_env" ]; then while IFS= read -r _l; do [ -n "$_l" ] && argv+=(--env "$_l"); done <<< "$sa_env"; fi
  argv+=(-- claude)
  [ -n "$sa_model" ] && argv+=(--model "$sa_model")
  # shellcheck disable=SC2206  # $sa_flags intentionally word-splits (mirrors the lane's $CLAUDE_FLAGS)
  [ -n "$sa_flags" ] && argv+=($sa_flags)
  argv+=("$sa_pointer")
  "${argv[@]}"
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
    close-pane)  herd_driver_close_pane "$@" ;;
    close-verified) herd_close_pane_verified "$@" ;;
    pane-identity)  herd_driver_pane_identity "$@"; echo ;;
    pane-rename)    herd_driver_pane_rename "$@" ;;
    agent-pane)     herd_driver_agent_pane_id "$@"; echo ;;
    pane-alive)  herd_driver_pane_alive "$@" ;;
    agent-liveness) herd_driver_agent_liveness "$@"; echo ;;
    create-tab)  herd_driver_create_tab "$@" ;;
    focus)       herd_driver_focus_agent "$@" ;;
    notify)      herd_driver_notify "$@" ;;
    name)        herd_driver_name; echo ;;
    *) printf 'usage: driver.sh {list-agents|read-pane <slug>|send-text <slug> <text>|send-keys <slug> <keys…>|close-pane <pane>|close-verified <pane> <expected-kind>|pane-identity <pane>|pane-rename <pane> <label>|agent-pane <slug>|pane-alive <pane>|agent-liveness <slug> [pane]|create-tab <slug>|focus <slug>|notify <title> <body> [sound]|name}\n' >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _HERD_DRIVER_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  . "$_HERD_DRIVER_HERE/herd-config.sh"
  _herd_driver_cli "$@"
fi
