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

# ── classification primitives (the eyes) ─────────────────────────────────────

# _reload_tab_by_label <workspace_id> <label> → tab_id, or empty.
_reload_tab_by_label() {
  herdr tab list --workspace "$1" 2>/dev/null | LABEL="$2" python3 -c '
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
  herdr pane list --workspace "$1" 2>/dev/null | TAB="$2" python3 -c '
import sys,json,os
try: panes=json.load(sys.stdin)["result"]["panes"]
except Exception: panes=[]
tab=os.environ["TAB"]
for p in panes:
    if p.get("tab_id")==tab and p.get("pane_id"): print(p["pane_id"])
' 2>/dev/null || true
}

# _reload_pane_role <pane_id> → backlog|watch|agent|bare|busy|gone. Classifies a pane by the
# process in its foreground (process-info) — the ground truth the canonical roles map onto: the
# backlog viewer, the watcher (herd-watch execs agent-watch), a claude agent, an idle shell
# (BARE, safe to reuse), or something else the human is running (BUSY — never hijacked).
_reload_pane_role() {
  herdr pane process-info --pane "$1" 2>/dev/null | python3 -c '
import sys,json
try: pi=json.load(sys.stdin)["result"]["process_info"]
except Exception: print("gone"); sys.exit(0)
sh=pi.get("shell_pid") or 0
if not sh: print("gone"); sys.exit(0)
fg=[p for p in (pi.get("foreground_processes") or []) if p.get("pid")!=sh]
def has(*subs): return any(any(s in (p.get("cmdline") or "") for s in subs) for p in fg)
if has("backlog-view.sh"): print("backlog")
elif has("agent-watch.sh","herd-watch.sh"): print("watch")
elif has("claude"): print("agent")
elif fg: print("busy")
else: print("bare")
' 2>/dev/null || printf 'gone\n'
}

# ── the shared snapshot / reconcile / registry API ───────────────────────────

# layout_snapshot <workspace_id> <tab_id> — THE shared eyes-on-layout scan. Emits one
# TAB-separated "<role>\t<pane_id>" line per pane in <tab>, classifying each by its live foreground
# process (backlog|watch|agent|bare|busy|gone). Empty when the tab has no panes / herdr is absent.
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

# layout_write_registry <file> <workspace_id> <tab_id> <agent> <backlog> <watch> — rewrite the
# .herd-panes role registry from the OBSERVED final pane-ids (empty rows omitted). Every row carries
# the tab id and the resolved workspace_id as a 4th column so a later reader can drop a hint that
# names a foreign workspace (issue #60). The single writer shared by cmd_reload, the herd pane
# subcommands, and coordinator.sh — so "rewrite from what we observed" is enforced in one place.
layout_write_registry() {
  local file="$1" ws="$2" tab="$3" agent="$4" backlog="$5" watch="$6"
  mkdir -p "$(dirname "$file")"
  {
    [ -n "$agent" ]   && printf 'coordinator-agent %s %s %s\n' "$agent" "$tab" "$ws"
    [ -n "$backlog" ] && printf 'backlog %s %s %s\n' "$backlog" "$tab" "$ws"
    [ -n "$watch" ]   && printf 'watch %s %s %s\n' "$watch" "$tab" "$ws"
    :   # never let an omitted trailing row make the group (and the caller, under set -e) fail
  } > "$file"
}

# ── stale single-pane drainer/reviewer tab flagging (HERD-114 crash sweep) ────
# A herdr crash can strand a SINGLE-PANE drainer/reviewer tab whose agent PROCESS was killed while the
# tab + pane persist: the pane falls back to a BARE shell (its `claude` gone). These leftovers slip
# past the reviewer-pane registry sweep (their dispatch row may be gone too) and the orphan-tab sweep
# (their PR/worktree may still exist). This eyes-on-layout flag NAMES them from the live scan so a
# caller can surface/retire them; it is READ-ONLY and never closes anything itself.

# _reload_tabs <workspace_id> → one "tab_id<TAB>label" line per tab (empty when herdr is absent).
_reload_tabs() {
  herdr tab list --workspace "$1" 2>/dev/null | python3 -c '
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
