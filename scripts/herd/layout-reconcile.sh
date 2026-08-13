#!/usr/bin/env bash
# layout-reconcile.sh — the shared EYES-ON-LAYOUT helper for the herd control room.
#
# Every pane-mutating path (`herd reload` / `cmd_reload`, `coordinator.sh`, the `herd pane`
# subcommands) used to act on BELIEFS — the `.herd-panes` registry (stale/poisonable) and one-shot
# geometric neighbor guesses — instead of on reality. The failure mode: a reload built standalone
# tabs and a rerun split a DUPLICATE backlog-view pane beside a still-live one.
#
# The engine already has eyes: `herdr pane list` + `herdr pane process-info` classify every pane in
# a tab by the process it actually runs. This library turns those eyes into a shared primitive so
# every mutating path OBSERVES the live layout, reconciles it against the desired shape, and
# rewrites the registry from the OBSERVED scan — never from what it merely believed.
#
# Desired control-room geometry (see BACKLOG "Geometry mechanics"): the backlog viewer occupies the
# full-height LEFT column; the RIGHT column is the coordinator pane over the watch pane, split at
# ratio 0.72. This file resolves ROLES, not pixels — geometry repair (splits / re-parents) stays in
# the caller, which owns the herdr split/move plumbing; the reconciler tells it WHICH pane serves
# each role, which are duplicates to close, and which roles are missing and must be created.
#
# Source it (functions only, no side effects) AFTER `herdr` is known to be on PATH:
#   . "$SCRIPTS_DIR/layout-reconcile.sh"
# It depends only on `herdr` + `python3`; every call degrades gracefully when herdr is absent or its
# JSON does not parse (a pane resolves to `gone`, a scan to empty), so callers fail loud, not crash.
# It OPTIONALLY consults `driver.sh`'s herd_driver_agent_process_signature (HERD-428, pane-role
# classification) when that has ALSO been sourced — never a hard dependency: absent, it falls back to
# the literal 'claude' unchanged.

# ── the hard-timeout guard (HERD-208) ────────────────────────────────────────
# _reload_timeout <secs> <cmd> [args...] — run <cmd> under a HARD wall-clock timeout, PRESERVING its
# stdout (unlike herd-preflight.sh's doctor runner, which discards it — every eyes/verify helper here
# pipes herdr's JSON to python3, so stdout MUST survive). Prefers coreutils `timeout`/`gtimeout`; else
# a pure-shell watchdog (background, poll to <secs>, SIGTERM→SIGKILL). Returns 124 on timeout
# (coreutils' convention), else the command's own exit code. This is THE guard that stops a WEDGED
# `herdr pane …` subcall — observed live on WSL2, where a pane verify never returned and `herd reload`
# hung INDEFINITELY (had to be killed) instead of degrading — from blocking a caller forever: a
# timeout becomes an empty result the caller already handles (a pane resolves 'gone'/GONE, a scan to
# empty). Every kill/wait/sleep is guarded so this can never abort a caller running under `set -e`.
# The per-call budget is HERD_RELOAD_HERDR_TIMEOUT (seconds; default 8) at every call site.
_reload_timeout() {
  local secs="$1"; shift
  local rc=0
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@" || rc=$?; return "$rc"; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@" || rc=$?; return "$rc"; fi
  # No timeout binary (stock macOS): a pure-shell watchdog. It needs a working `sleep` to enforce the
  # bound; without one, degrade to an un-timed run rather than busy-spin into a FALSE timeout.
  if ! sleep 0 2>/dev/null; then "$@" || rc=$?; return "$rc"; fi
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited+1))
  done
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

# ── classification primitives (the eyes) ─────────────────────────────────────

# _reload_tab_by_label <workspace_id> <label> → tab_id, or empty.
_reload_tab_by_label() {
  _reload_timeout "${HERD_RELOAD_HERDR_TIMEOUT:-8}" herdr tab list --workspace "$1" 2>/dev/null | LABEL="$2" python3 -c '
import sys,json,os
try: tabs=json.load(sys.stdin)["result"]["tabs"]
except Exception: tabs=[]
print(next((t.get("tab_id","") for t in tabs if t.get("label")==os.environ["LABEL"]), ""), end="")
' 2>/dev/null || true
}

# _reload_tab_panes <workspace_id> <tab_id> → pane_ids in that tab, one per line. The LIVE pane
# roster is ground truth; the registry and neighbor queries are only hints that callers validate
# against this list before trusting them.
_reload_tab_panes() {
  _reload_timeout "${HERD_RELOAD_HERDR_TIMEOUT:-8}" herdr pane list --workspace "$1" 2>/dev/null | TAB="$2" python3 -c '
import sys,json,os
try: panes=json.load(sys.stdin)["result"]["panes"]
except Exception: panes=[]
tab=os.environ["TAB"]
for p in panes:
    if p.get("tab_id")==tab and p.get("pane_id"): print(p["pane_id"])
' 2>/dev/null || true
}

# _reload_pane_role <pane_id> → backlog|watch|agents|agent|bare|busy|gone. Classifies a pane by the
# process in its foreground (process-info) — the ground truth the canonical roles map onto: the
# backlog viewer, the watcher (herd-watch execs agent-watch), a live agent of the ACTIVE driver's
# runtime, an idle shell (BARE, safe to reuse), or something else the human is running (BUSY — never
# hijacked).
#
# DRIVER-AWARE (HERD-428): the 'agent' branch used to substring-match the literal 'claude', so a
# codex/grok pane (HERD_DRIVER=codex|grok) matched none of the branches and fell through to 'busy' —
# the coordinator's own pane was then never classified 'agent', so layout_reconcile's agents list
# stayed empty for every non-Claude driver. It now reads the ACTIVE driver's
# DRIVER_AGENT_PROCESS_SIGNATURE (scripts/herd/driver.sh's herd_driver_agent_process_signature) — one
# or more space-separated literal substrings — instead of the hardcoded literal. FAIL-SOFT: when
# driver.sh has not been sourced (the function is absent) or the binding is unset/unreadable, this
# falls back to 'claude' — TODAY'S exact literal — so the default driver's classification and every
# caller's behavior stay byte-identical.
_reload_pane_role() {
  local sig=""
  if command -v herd_driver_agent_process_signature >/dev/null 2>&1; then
    sig="$(herd_driver_agent_process_signature 2>/dev/null || true)"
  fi
  [ -n "$sig" ] || sig='claude'
  _reload_timeout "${HERD_RELOAD_HERDR_TIMEOUT:-8}" herdr pane process-info --pane "$1" 2>/dev/null | SIG="$sig" python3 -c '
import sys,json,os
try: pi=json.load(sys.stdin)["result"]["process_info"]
except Exception: print("gone"); sys.exit(0)
sh=pi.get("shell_pid") or 0
if not sh: print("gone"); sys.exit(0)
fg=[p for p in (pi.get("foreground_processes") or []) if p.get("pid")!=sh]
def has(*subs): return any(any(s in (p.get("cmdline") or "") for s in subs) for p in fg)
agent_sigs=os.environ.get("SIG","claude").split() or ["claude"]
if has("backlog-view.sh"): print("backlog")
elif has("agent-watch.sh","herd-watch.sh"): print("watch")
elif has("agents-pane-view.sh"): print("agents")
elif has(*agent_sigs): print("agent")
elif fg: print("busy")
else: print("bare")
' 2>/dev/null || printf 'gone\n'
}

# ── the shared snapshot / reconcile / registry API ───────────────────────────

# layout_snapshot <workspace_id> <tab_id> — THE shared eyes-on-layout scan. Emits one
# TAB-separated "<role>\t<pane_id>" line per pane in <tab>, classifying each by its live foreground
# process (backlog|watch|agents|agent|bare|busy|gone). Empty when the tab has no panes / herdr is absent.
# The live roster — not the registry — is ground truth; callers reconcile against this output.
layout_snapshot() {
  local ws="$1" tab="$2" p role
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    role="$(_reload_pane_role "$p")"
    printf '%s\t%s\n' "$role" "$p"
  done <<EOF
$(_reload_tab_panes "$ws" "$tab")
EOF
}

# layout_reconcile <workspace_id> <tab_id> [reg_agent] [reg_backlog] [reg_watch] — reconcile the
# live tab against the desired 3-role control room (agent anchor · backlog viewer · watch console).
# The registry pane-ids are HINTS only: a hint is adopted for a role ONLY when that pane is still
# OBSERVED in the tab (this is what neutralises a stale/poisoned registry). Live role panes always
# win over hints. Emits five key=value lines the caller consumes:
#   agent=<pane|>        the coordinator/anchor pane: a live 'agent', else the reg_agent hint if
#                        still present, else a reusable bare/busy pane
#   backlog=<pane|>      the adopted backlog viewer: the first live 'backlog', else the reg_backlog
#                        hint if still present
#   watch=<pane|>        the adopted watch console: the first live 'watch', else the reg_watch hint
#   dup_backlog=<panes>  every backlog viewer BEYOND the first — duplicates the caller must close
#   missing=<roles>      space-separated subset of {agent,backlog,watch} with no resolved pane —
#                        the roles the caller must CREATE
layout_reconcile() {
  local ws="$1" tab="$2"
  layout_snapshot "$ws" "$tab" | RA="${3:-}" RB="${4:-}" RW="${5:-}" python3 -c '
import sys,os
roles={}          # role -> [pane, ...] in scan order
present=set()     # every pane_id observed in the tab
for line in sys.stdin:
    line=line.rstrip("\n")
    if not line: continue
    parts=line.split("\t")
    if len(parts)!=2 or not parts[1]: continue
    role,pane=parts
    present.add(pane)
    roles.setdefault(role,[]).append(pane)
backlogs=roles.get("backlog",[])
watches =roles.get("watch",[])
agents  =roles.get("agent",[])
reusable=roles.get("bare",[])+roles.get("busy",[])
ra=os.environ.get("RA",""); rb=os.environ.get("RB",""); rw=os.environ.get("RW","")
taken=set()
def pick(live, hint, avoid=()):
    for p in live:
        if p not in taken and p not in avoid:
            taken.add(p); return p
    # a registry hint is trusted ONLY when the pane is still observed in the tab
    if hint and hint in present and hint not in taken and hint not in avoid:
        taken.add(hint); return hint
    return ""
agent  = pick(agents, ra) or pick(reusable, ra)
backlog= pick(backlogs, rb, avoid=(agent,))
watch  = pick(watches, rw, avoid=(agent,backlog))
dup    = [p for p in backlogs if p!=backlog]
missing= [r for r,v in (("agent",agent),("backlog",backlog),("watch",watch)) if not v]
print("agent=%s"%agent)
print("backlog=%s"%backlog)
print("watch=%s"%watch)
print("dup_backlog=%s"%" ".join(dup))
print("missing=%s"%" ".join(missing))
' 2>/dev/null || printf 'agent=\nbacklog=\nwatch=\ndup_backlog=\nmissing=agent backlog watch\n'
}

# ── role-label reconciliation (HERD-650) ──────────────────────────────────────────────────────────
# The role LABEL (the cosmetic 'label' field `herdr pane list` displays) used to be set only once, at
# pane CREATE — an invariant living in a single event instead of a reconciled property. Every restart
# path (herd pane watch/backlog/coordinator, herd reload, coordinator.sh) rebuilds or RECREATES panes
# without re-asserting the label, so a pane recreated by a restart (the watch/backlog pane going GONE
# and getting split fresh, e.g.) never receives the label its predecessor had — the erosion observed
# live (wE:p2P3/p2P4 went blank). layout_label_roles ties the label to the SAME observed-state write
# every caller already performs, so it self-heals within one pass instead of needing a human
# `herdr pane rename`.
#
# Reuses coordinator.sh's PRE-EXISTING `backlog·<ws>` / `watch·<ws>` convention (HERD-310 stamp
# coverage — the HERD-134 pane-close identity guard proves a close against this exact family of
# labels) rather than inventing a second, conflicting label scheme: writing a plain unqualified label
# here would silently downgrade/overwrite that stamp on every single coordinator.sh run (it calls
# layout_write_registry immediately after stamping backlog/watch), defeating the identity guard's
# workspace-scoped disambiguation for no reason. `coordinator·<ws>` extends the same family to the
# anchor pane, which previously carried no pane-level label at all (only the herdr AGENT name).

# _layout_label_pane <pane> <label> — set <pane>'s label, fail-soft. Prefers herd_driver_pane_rename
# (driver.sh, HERD-135) when driver.sh has ALSO been sourced — it is headless-aware, so a headless
# driver stays a clean no-op; else falls back to the raw herdr call. A missing herdr, a gone pane, or
# an older herdr without `pane rename` is a silent no-op — NEVER a red row, NEVER aborts a caller
# running under set -euo pipefail.
_layout_label_pane() {
  local target="${1:-}" label="${2:-}"
  [ -n "$target" ] && [ -n "$label" ] || return 0
  if command -v herd_driver_pane_rename >/dev/null 2>&1; then
    herd_driver_pane_rename "$target" "$label"
  else
    command -v herdr >/dev/null 2>&1 || return 0
    herdr pane rename "$target" "$label" >/dev/null 2>&1 || true
  fi
  return 0
}

# layout_label_roles <agent> <backlog> <watch> <ws_name> [agents] — reconcile the control-room panes'
# role labels to coordinator·<ws_name> / backlog·<ws_name> / watch·<ws_name> / agents·<ws_name>
# (empty pane ids are skipped). Without a ws_name (a caller that cannot supply one) falls back to the
# bare role word — still readable/non-empty, just not workspace-disambiguated. Display-only,
# fail-soft, no config key: always runs, never gates anything. The optional 5th arg (HERD-668, the
# AGENTS_PANE control-room pane) is simply skipped by every caller that never resolves one — an empty
# 5th arg is a no-op, so this stays byte-identical for every caller predating it.
layout_label_roles() {
  local agent="${1:-}" backlog="${2:-}" watch="${3:-}" wsn="${4:-}" agents="${5:-}"
  local lc=coordinator lb=backlog lw=watch la=agents
  if [ -n "$wsn" ]; then lc="coordinator·$wsn"; lb="backlog·$wsn"; lw="watch·$wsn"; la="agents·$wsn"; fi
  _layout_label_pane "$agent"   "$lc"
  _layout_label_pane "$backlog" "$lb"
  _layout_label_pane "$watch"   "$lw"
  _layout_label_pane "$agents"  "$la"
  return 0
}

# layout_write_registry <file> <workspace_id> <tab_id> <agent> <backlog> <watch> [ws_name] [agents] —
# rewrite the .herd-panes role registry from the OBSERVED final pane-ids (empty rows omitted). Every
# row carries the tab id and the resolved workspace_id as a 4th column so a later reader can drop a
# hint that names a foreign workspace (issue #60). The single writer shared by cmd_reload, the herd
# pane subcommands, and coordinator.sh — so "rewrite from what we observed" is enforced in one place,
# and (HERD-650) so is the role-label reconcile: every pass that writes the registry also re-asserts
# each resolved pane's label. ws_name (the human-readable WORKSPACE_NAME, distinct from the
# workspace_id 2nd arg) is optional — omitted, layout_label_roles falls back to unqualified labels.
# The optional 8th arg `agents` (HERD-668) is the AGENTS_PANE control-room pane; every caller that
# never resolves one (the overwhelming default, AGENTS_PANE=off) omits it, which writes no `agents`
# row at all — byte-identical to before this arg existed. A registry with no `agents` row loads fine
# (each role row is independently optional; a reader that looks for one simply finds none).
layout_write_registry() {
  local file="$1" ws="$2" tab="$3" agent="$4" backlog="$5" watch="$6" wsn="${7:-}" agents="${8:-}"
  mkdir -p "$(dirname "$file")"
  {
    [ -n "$agent" ]   && printf 'coordinator-agent %s %s %s\n' "$agent" "$tab" "$ws"
    [ -n "$backlog" ] && printf 'backlog %s %s %s\n' "$backlog" "$tab" "$ws"
    [ -n "$watch" ]   && printf 'watch %s %s %s\n' "$watch" "$tab" "$ws"
    [ -n "$agents" ]  && printf 'agents %s %s %s\n' "$agents" "$tab" "$ws"
    :   # never let an omitted trailing row make the group (and the caller, under set -e) fail
  } > "$file"
  layout_label_roles "$agent" "$backlog" "$watch" "$wsn" "$agents"
}

# ── stale single-pane drainer/reviewer tab flagging (HERD-114 crash sweep) ────
# A herdr crash can strand a SINGLE-PANE drainer/reviewer tab whose agent PROCESS was killed while the
# tab + pane persist: the pane falls back to a BARE shell (its `claude` gone). These leftovers slip
# past the reviewer-pane registry sweep (their dispatch row may be gone too) and the orphan-tab sweep
# (their PR/worktree may still exist). This eyes-on-layout flag NAMES them from the live scan so a
# caller can surface/retire them; it is READ-ONLY and never closes anything itself.

# _reload_tabs <workspace_id> → one "tab_id<TAB>label" line per tab (empty when herdr is absent).
_reload_tabs() {
  _reload_timeout "${HERD_RELOAD_HERDR_TIMEOUT:-8}" herdr tab list --workspace "$1" 2>/dev/null | python3 -c '
import sys,json
try: tabs=json.load(sys.stdin)["result"]["tabs"]
except Exception: tabs=[]
for t in tabs:
    tid=t.get("tab_id","") or ""
    if tid: print("%s\t%s"%(tid,(t.get("label","") or "").replace("\t"," ")))
' 2>/dev/null || true
}

# _is_drainer_or_reviewer_label <label> — success iff <label> names an engine DRAINER or REVIEWER
# single-pane agent tab: a reviewer (review·<slug>), conflict resolver (resolve·<slug>), scribe drainer
# (scribe-<ws>), or research drainer (researcher-<ws>). A control-room / coordinator / plain feature-
# builder tab is deliberately NOT matched — a builder tab is recovered by its own dead-agent path, and
# the control room is multi-pane and load-bearing — so those are never flagged as stale leftovers.
_is_drainer_or_reviewer_label() {
  case "$1" in
    review·*|resolve·*|scribe-*|researcher-*) return 0 ;;
    *) return 1 ;;
  esac
}

# layout_stale_agent_tabs <workspace_id> — emit one "tab_id<TAB>label<TAB>role" line per STALE
# single-pane drainer/reviewer tab: EXACTLY one pane, that pane a DEAD agent (role bare|gone — its
# claude process is gone), AND an engine drainer/reviewer label. Read-only; empty when herdr is absent
# or nothing is stale. The caller decides whether to surface or retire — this only supplies the eyes.
layout_stale_agent_tabs() {
  local ws="$1" tid label panes n p role tab
  tab="$(printf '\t')"
  while IFS="$tab" read -r tid label; do
    [ -n "$tid" ] || continue
    _is_drainer_or_reviewer_label "$label" || continue
    # Count panes; a crash-stranded drainer/reviewer is single-pane by construction.
    panes="$(_reload_tab_panes "$ws" "$tid")"
    n=0
    while IFS= read -r p; do [ -n "$p" ] && n=$((n+1)); done <<EOF
$panes
EOF
    [ "$n" -eq 1 ] || continue
    role="$(_reload_pane_role "${panes%%$'\n'*}")"
    case "$role" in
      bare|gone) printf '%s\t%s\t%s\n' "$tid" "$label" "$role" ;;
    esac
  done <<EOF
$(_reload_tabs "$ws")
EOF
}

# layout_fold_stray_tabs <workspace_id> <workspace_name> — close stray STANDALONE control-room tabs
# ("watch-<name>" / "backlog-<name>") that earlier bad reloads left behind; those roles belong
# INSIDE the coordinator tab, re-established there by the caller. The coordinator tab is never
# touched. Best-effort: a missing/uncloseable tab is silently skipped.
layout_fold_stray_tabs() {
  local ws="$1" name="$2" slabel stab
  for slabel in "watch-${name}" "backlog-${name}"; do
    stab="$(_reload_tab_by_label "$ws" "$slabel")"
    [ -n "$stab" ] && herdr tab close "$stab" >/dev/null 2>&1 || true
  done
}
