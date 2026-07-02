#!/usr/bin/env bash
# herd-config.sh — source this from any scripts/herd/* script to load the consuming
# project's .herd/config, with sane generic fallbacks. The engine scripts stay thin:
# they source this, then run the generic mechanism with the project's values.
#
# Usage (at the top of any herd script, after HERE is set):
#   . "$HERE/herd-config.sh"
#
# Config discovery, in order:
#   1. HERD_CONFIG_FILE (env) — explicit path; tests + the `herd` CLI set this.
#   2. walk up from $PWD for a .herd/config — makes the GLOBAL-INSTALL model work: a lane
#      script lives in the herdkit install but is invoked with cwd inside the consuming project,
#      so it finds that project's committed .herd/config.
#   3. <repo>/.herd/config, two dirs up from scripts/herd/ — the DOGFOOD/vendored layout.
#
# This file is ZERO-SECRET. API-backend credentials live in .herd/secrets (gitignored),
# sourced separately by scribe-step.sh — never here, never in .herd/config.
# Force UTF-8 for all python3 subcalls throughout the engine — fixes Windows cp1252
# UnicodeEncodeError (issue #31). On Windows, piped python3 defaults stdout/stdin to the
# system codepage (cp1252), which cannot encode non-ASCII characters present in herdr JSON
# (workspace/tab labels with emoji 🐑) and in watch-console output (box-drawing ═).
# PYTHONUTF8 is the PEP 540 / Python 3.7+ knob; PYTHONIOENCODING is the pre-3.7 fallback.
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

_HERD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HERD_REPO_DEFAULT="$(cd "$_HERD_SCRIPT_DIR/../.." && pwd)"
_herd_find_config() {
  [ -n "${HERD_CONFIG_FILE:-}" ] && { printf '%s' "$HERD_CONFIG_FILE"; return; }
  local d="$PWD"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/.herd/config" ] && { printf '%s' "$d/.herd/config"; return; }
    d="$(dirname "$d")"
  done
  printf '%s' "$_HERD_REPO_DEFAULT/.herd/config"
}
_HERD_CONFIG_FILE="$(_herd_find_config)"
unset -f _herd_find_config
if [ -f "$_HERD_CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  . "$_HERD_CONFIG_FILE"
fi

# ── Fallback defaults (generic; no project literals) ─────────────────────────
# PROJECT_ROOT defaults to the repo that owns the .herd/config we just read (or, if
# none, the repo the engine lives in). Everything else derives from it.
: "${PROJECT_ROOT:="$_HERD_REPO_DEFAULT"}"
: "${WORKTREES_DIR:="${PROJECT_ROOT}-trees"}"
: "${DEFAULT_BRANCH:="origin/main"}"
: "${WORKSPACE_NAME:="$(basename "$PROJECT_ROOT")"}"

: "${BACKLOG_FILE:="BACKLOG.md"}"
: "${SCRIBE_BACKEND:="file"}"
: "${SHARE_LINKS:=""}"            # dirs symlinked into each worktree (e.g. "data .venv")

# ── Model tier defaults — TOKEN_MODE-aware ───────────────────────────────────
# TOKEN_MODE (standard [default] | eco) flips the BUILT-IN model defaults to cheaper tiers.
#
# Ordering here is load-bearing and encodes one hard rule: an explicit MODEL_* key set in
# .herd/config ALWAYS beats the eco tier — eco replaces built-in defaults only, never a user
# override. That holds because the config file was already sourced above, so any explicit
# MODEL_* is already set; every assignment below is ':=' (assign-only-if-unset) and therefore
# cannot clobber it. The eco block runs FIRST so, for keys the user did NOT set, its values win
# over the standard defaults that follow (those then no-op for anything eco already assigned).
# When TOKEN_MODE is unset or 'standard' the eco block is skipped and the standard tiers apply
# unchanged — zero behavior change for existing projects.
#
# Composition: the model step-up item escalates FROM whatever tier is resolved here — eco lowers
# the floor, step-up raises specific lanes off that floor, so the two are orthogonal.
#
# eco tiers (research report "Bucket B"): coordinator/feature→sonnet, quick/scribe/research/
# resolver→haiku, review→sonnet. Quality tradeoffs are documented in the TOKEN_MODE row of
# templates/capabilities.tsv (and the rendered coordinator skill's Config-keys section).
: "${TOKEN_MODE:="standard"}"
if [ "$TOKEN_MODE" = "eco" ]; then
  : "${MODEL_COORDINATOR:="claude-sonnet-4-6"}"
  : "${MODEL_FEATURE:="claude-sonnet-4-6"}"
  : "${MODEL_QUICK:="claude-haiku-4-5"}"
  : "${MODEL_SCRIBE:="claude-haiku-4-5"}"
  : "${MODEL_RESEARCH:="claude-haiku-4-5"}"
  : "${MODEL_REVIEW:="claude-sonnet-4-6"}"
  : "${MODEL_RESOLVER:="claude-haiku-4-5"}"
fi

: "${MODEL_COORDINATOR:="claude-opus-4-8"}"
: "${MODEL_FEATURE:="claude-opus-4-8"}"
: "${MODEL_QUICK:="claude-sonnet-4-6"}"
: "${MODEL_SCRIBE:="claude-sonnet-4-6"}"
: "${MODEL_RESEARCH:="claude-sonnet-4-6"}"
: "${MODEL_REVIEW:="claude-opus-4-8"}"
: "${MODEL_RESOLVER:="claude-sonnet-4-6"}"  # conflict resolver — mechanical merge work, not creative

: "${APP_PREVIEW_CMD:=""}"        # empty → no preview pane (quick-only project, e.g. herdkit)
: "${HEALTHCHECK_CMD:=""}"        # project health command; exit 0 clean/data-env, 1 code error
: "${HEALTHCHECK_HEAVY_GLOB:=""}" # diff paths that force the heavy profile (egrep, e.g. '^app/')
: "${APP_SURFACE_GLOB:=""}"       # diff paths that constitute the app surface (egrep, e.g. '^app/'); empty → interaction gate off
: "${INTERACTION_TEST_CMD:=""}"   # command that drives widgets and asserts dependent output changes; exit 0 clean, 1 code error, 2 data/env
: "${SMOKE_CMD:=""}"              # optional resolver smoke gate

: "${DENY_PATHS:=""}"            # never committed; the scribe/local lane is scoped away from these
: "${REVIEW_CHECKLIST:=""}"     # project risk list injected into the review gate

: "${COORDINATOR_CMD:="/coordinator"}"  # the generated coordinator skill the control room runs
: "${HERD_VERSION:="1"}"
: "${HERD_REPO:=""}"            # <owner>/herdkit — where engine bugs escalate (herd report)
: "${WATCHER_AUTOMERGE:="true"}"  # legacy lever; MERGE_POLICY takes precedence when set
: "${MERGE_POLICY:=""}"           # auto | approve | observe (empty → derive from WATCHER_AUTOMERGE)
: "${MERGE_METHOD:="merge"}"      # merge | squash | rebase — the gh pr merge strategy
: "${REVIEW_CONCURRENCY:="2"}"    # max pre-merge reviews the watcher runs in parallel
: "${HEALTH_CONCURRENCY:="1"}"   # max healthcheck suites the watcher runs at once (default 1: serialize — all feature worktrees share one git object store, so overlapping suites race on shared .git locks and paint false-red)
: "${REVIEW_AUTOFIX:="false"}"   # auto-bounce BLOCK reviews to the builder agent (default off; set true to dogfood)
: "${REFIX_MAX_ROUNDS:="3"}"     # max auto-refix rounds per PR; further BLOCKs escalate to needs-you

unset _HERD_SCRIPT_DIR _HERD_REPO_DEFAULT _HERD_CONFIG_FILE

# Derived helpers — split DEFAULT_BRANCH (e.g. "origin/main") for push/pull commands.
HERD_REMOTE="${DEFAULT_BRANCH%%/*}"
HERD_BRANCH_NAME="${DEFAULT_BRANCH#*/}"

# ── Project-scoped singleton identifiers ─────────────────────────────────────
# The coordinator/scribe/researcher/watcher are PER-PROJECT singletons. Two projects sharing
# one herdr must NOT collide on a global name: relaunching project B's coordinator would close
# A's tab, and B's scribe/research spawn-lock (a global `herdr agent list` name match) would
# see A's drainer and never start its own → B's queue never drains. So suffix every singleton
# name with the project's WORKSPACE_NAME. The "is my singleton already running?" checks then
# match only THIS project's agent. Sanitize WORKSPACE_NAME to a safe slug ([A-Za-z0-9_-]) for
# use as an agent/tab identifier.
_HERD_WS_SLUG="$(printf '%s' "$WORKSPACE_NAME" | tr -c 'A-Za-z0-9_-' '-')"
[ -n "$_HERD_WS_SLUG" ] || _HERD_WS_SLUG="project"
HERD_AGENT_COORDINATOR="coordinator-$_HERD_WS_SLUG"
HERD_AGENT_SCRIBE="scribe-$_HERD_WS_SLUG"
HERD_AGENT_RESEARCHER="researcher-$_HERD_WS_SLUG"
HERD_TAB_COORDINATOR="coordinator-$_HERD_WS_SLUG"
# PID-file path for the per-project watcher singleton (agent-watch.sh spawn-lock).
HERD_WATCHER_LOCK="$WORKTREES_DIR/.watcher-${_HERD_WS_SLUG}.pid"
# PID-file path for the per-project dep-watcher singleton (dep-watcher.sh spawn-lock).
HERD_DEPWATCHER_LOCK="$WORKTREES_DIR/.depwatcher-${_HERD_WS_SLUG}.pid"
unset _HERD_WS_SLUG

# herd_resolve_workspace_id — resolve this project's herdr workspace id by matching WORKSPACE_NAME
# against 'herdr workspace list' labels. Prints the id to stdout (no trailing newline) on success;
# prints nothing and warns to stderr when herdr is missing, the list call fails, or the label is
# absent (e.g. coordinator.sh has not yet created the workspace). Call at each spawn site; proceed
# unpinned (without --workspace) when the return value is empty.
herd_resolve_workspace_id() {
  if ! command -v herdr >/dev/null 2>&1; then
    printf '⚠️  herdkit: herdr not on PATH — spawning without --workspace (tab may land in wrong workspace)\n' >&2
    return 0
  fi
  local _wslist _wsid
  if ! _wslist="$(herdr workspace list 2>/dev/null)"; then
    printf '⚠️  herdkit: herdr workspace list failed — spawning without --workspace\n' >&2
    return 0
  fi
  _wsid="$(printf '%s' "$_wslist" | LABEL="$WORKSPACE_NAME" python3 -c '
import sys,json,os
try:
  ws=next((w["workspace_id"] for w in json.load(sys.stdin)["result"]["workspaces"] if w.get("label")==os.environ["LABEL"]),"")
  print(ws,end="")
except Exception:
  pass
' 2>/dev/null || true)"
  if [ -z "$_wsid" ]; then
    printf '⚠️  herdkit: workspace "%s" not found in herdr — spawning without --workspace (run coordinator.sh first)\n' "$WORKSPACE_NAME" >&2
    return 0
  fi
  printf '%s' "$_wsid"
}

# herd_teardown_slug <slug> — close ALL tabs for a feature slug on merge/close-out: the builder
# tab (label==slug), the review tab (label==review·slug), and the resolver tab
# (label==resolve·slug). Scoped to this project's workspace when the workspace ID is resolvable,
# to avoid closing identically-named tabs that belong to another project. Verifies each close
# with a follow-up herdr tab list; retries once on failure, then warns loudly to stderr.
# Best-effort — never exits non-zero.
herd_teardown_slug() {
  local _td_slug="${1:-}"; [ -n "$_td_slug" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  local _td_wsid; _td_wsid="$(herd_resolve_workspace_id 2>/dev/null || true)"
  local _td_list; _td_list="$(herdr tab list 2>/dev/null || true)"
  [ -n "$_td_list" ] || return 0

  # Collect tab IDs for all three label variants, filtered to this project's workspace.
  local _td_ids
  _td_ids="$(printf '%s' "$_td_list" | SLUG="$_td_slug" WS="$_td_wsid" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
ws   = os.environ.get("WS", "")
MID  = "·"
labels = {slug, "review" + MID + slug, "resolve" + MID + slug}
try:
  tabs = json.load(sys.stdin).get("result", {}).get("tabs", [])
  for t in tabs:
    if t.get("label") in labels:
      if not ws or t.get("workspace_id", "") == ws:
        print(t["tab_id"])
except Exception:
  pass
' 2>/dev/null || true)"
  [ -n "$_td_ids" ] || return 0

  # Close each tab, verify with a follow-up list, retry once, warn loudly on second failure.
  local _td_id
  while IFS= read -r _td_id; do
    [ -n "$_td_id" ] || continue
    herdr tab close "$_td_id" >/dev/null 2>&1 || true
    local _td_still
    _td_still="$(herdr tab list 2>/dev/null | TAB_ID="$_td_id" python3 -c '
import sys, json, os
tid = os.environ["TAB_ID"]
try:
  tabs = json.load(sys.stdin).get("result", {}).get("tabs", [])
  print(next((t["tab_id"] for t in tabs if t.get("tab_id") == tid), ""))
except Exception:
  pass
' 2>/dev/null || true)"
    if [ -n "$_td_still" ]; then
      herdr tab close "$_td_id" >/dev/null 2>&1 || true
      _td_still="$(herdr tab list 2>/dev/null | TAB_ID="$_td_id" python3 -c '
import sys, json, os
tid = os.environ["TAB_ID"]
try:
  tabs = json.load(sys.stdin).get("result", {}).get("tabs", [])
  print(next((t["tab_id"] for t in tabs if t.get("tab_id") == tid), ""))
except Exception:
  pass
' 2>/dev/null || true)"
      [ -n "$_td_still" ] && printf '⚠️  herdkit: tab %s (slug: %s) could not be closed after retry — close it manually.\n' "$_td_id" "$_td_slug" >&2
    fi
  done <<< "$_td_ids"
  # Remove all registry entries for this slug (builder, review·, resolve· variants).
  local _td_reg="$WORKTREES_DIR/.herd-tabs"
  if [ -f "$_td_reg" ]; then
    SLUG="$_td_slug" python3 -c '
import os, sys
slug = os.environ["SLUG"]
mid  = "·"
to_remove = {slug, "review" + mid + slug, "resolve" + mid + slug}
path = sys.argv[1]
try:
    with open(path) as f: lines = f.readlines()
    with open(path, "w") as f:
        for line in lines:
            parts = line.strip().split(" ", 2)
            if not (parts and parts[0] in to_remove):
                f.write(line)
except Exception: pass
' "$_td_reg" 2>/dev/null || true
  fi
  return 0
}

# herd_pretrust_worktree <dir> — mark a worktree as trusted for Claude Code so a builder agent
# launched in it never stalls on the interactive "Do you trust the files in this folder?" gate and
# dies with zero commits.
#
# Claude Code records folder trust in ~/.claude.json under projects["<abs-path>"].hasTrustDialogAccepted
# (verified empirically) — NOT in any project-level .claude/settings.json, which is why PR #22's
# settings-file seeding was ineffective. It cannot be skipped via a launch flag either:
# --dangerously-skip-permissions bypasses tool-permission prompts but NOT the trust dialog in an
# interactive/pane session (only fully non-interactive `-p` runs skip it), so we must seed the entry
# on disk before launch.
#
# The write is ADDITIVE and SAFE: it sets only that one boolean on the worktree's own project entry,
# never touching other projects or any top-level key; it round-trips through a temp file + atomic
# os.replace so an interrupted write can't truncate ~/.claude.json; it tolerates a missing or
# malformed file (starting fresh from {}); and it makes a one-time ~/.claude.json.bak before its
# first modification. Best-effort: any failure warns but returns 0 so it never aborts worktree
# creation — worst case the agent hits the prompt, which the stalled-builder detector already flags.
herd_pretrust_worktree() {
  local _pt_dir="${1:-}"
  [ -n "$_pt_dir" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    printf '⚠️  herdkit: python3 not found — cannot pre-trust %s for Claude Code (agent may stall on the folder-trust prompt)\n' "$_pt_dir" >&2
    return 0
  fi
  # Key by the PHYSICAL, symlink-resolved absolute path: that is what Claude Code's process.cwd()
  # records, so keying by a logical path with unresolved symlinks would seed the wrong entry.
  local _pt_abs
  _pt_abs="$(cd "$_pt_dir" 2>/dev/null && pwd -P)" || _pt_abs="$_pt_dir"
  if ! HERD_PRETRUST_DIR="$_pt_abs" python3 - "$HOME/.claude.json" <<'PY'
import json, os, sys, tempfile

path = sys.argv[1]                        # ~/.claude.json — Claude Code's per-user state file
proj = os.environ["HERD_PRETRUST_DIR"]    # absolute worktree path to mark trusted

# Read-modify-write, tolerant of a missing OR corrupt file (start fresh from {} in both cases).
data = {}
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except FileNotFoundError:
    data = {}
except (ValueError, OSError):
    data = {}

projects = data.get("projects")
if not isinstance(projects, dict):
    projects = {}
entry = projects.get(proj)
if not isinstance(entry, dict):
    entry = {}

# Idempotent: already trusted → touch nothing (no write, no backup churn).
if entry.get("hasTrustDialogAccepted") is True:
    sys.exit(0)

# One-time backup before the FIRST modification, so a bad write stays recoverable. Only when an
# original exists and no backup has been taken yet.
bak = path + ".bak"
if os.path.exists(path) and not os.path.exists(bak):
    try:
        with open(path, "rb") as src, open(bak, "wb") as dst:
            dst.write(src.read())
    except OSError:
        pass

entry["hasTrustDialogAccepted"] = True
projects[proj] = entry
data["projects"] = projects

# Atomic write: temp file in the same dir + os.replace so ~/.claude.json is never seen truncated.
d = os.path.dirname(path) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".claude.json.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
except OSError:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
  then
    printf '⚠️  herdkit: could not pre-trust %s for Claude Code (agent may hit the folder-trust prompt)\n' "$_pt_abs" >&2
  fi
  return 0
}
