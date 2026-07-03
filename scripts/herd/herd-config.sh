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
# _herd_find_config records HOW the config resolved into _HERD_CONFIG_SOURCE (env | walkup |
# fallback) alongside the path in _HERD_CONFIG_FILE. The source is load-bearing for the console
# launch-binding guard (issue #60): a long-running console that resolved its config ONLY by the
# rule-3 engine-dogfood FALLBACK is silently binding to the engine's own repo, which the guard
# refuses. Assign directly (no command substitution) so the source survives — a `$(…)` capture
# runs in a subshell and would lose it.
_HERD_CONFIG_SOURCE=""
_herd_find_config() {
  if [ -n "${HERD_CONFIG_FILE:-}" ]; then
    _HERD_CONFIG_SOURCE="env"; _HERD_CONFIG_FILE="$HERD_CONFIG_FILE"; return
  fi
  local d="$PWD"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/.herd/config" ]; then
      _HERD_CONFIG_SOURCE="walkup"; _HERD_CONFIG_FILE="$d/.herd/config"; return
    fi
    d="$(dirname "$d")"
  done
  _HERD_CONFIG_SOURCE="fallback"; _HERD_CONFIG_FILE="$_HERD_REPO_DEFAULT/.herd/config"
}
_herd_find_config
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

# ── Console-strict config binding (issue #60 launch-binding guard) ───────────
# A long-running CONSOLE (agent-watch / herd-watch / backlog-view / coordinator) sets
# HERD_REQUIRE_PROJECT_CONFIG=1 BEFORE sourcing this file. When set, refuse to SILENTLY inherit the
# engine's OWN dogfood config via the rule-3 fallback: a console whose config resolved ONLY by that
# fallback (no HERD_CONFIG_FILE, and no .herd/config found walking up from $PWD) would bind to
# herdkit's config and then impersonate another repo's watcher on the same lockfile — the exact
# 2026-07-02 misbinding. Normal `herd <cmd>` CLI usage NEVER sets this flag, so its intentional
# rule-3 dogfood fallback is unchanged. Escape hatch: HERD_ALLOW_FOREIGN_CWD=1 (the same override
# that relaxes the cwd guard) for deliberate foreign launches. This file is always SOURCED, so a
# hard `exit 1` here terminates the offending console before it can act on the wrong config.
case "${HERD_REQUIRE_PROJECT_CONFIG:-}" in
  1|true|yes|on)
    case "${HERD_ALLOW_FOREIGN_CWD:-}" in
      1|true|yes|on) : ;;   # operator opted into a foreign launch — allow the dogfood fallback
      *)
        if [ "$_HERD_CONFIG_SOURCE" = "fallback" ]; then
          printf '\n🛑 herdkit: REFUSING to bind this console to the engine'"'"'s own dogfood config.\n' >&2
          printf '   No .herd/config was found via $HERD_CONFIG_FILE or by walking up from your $PWD,\n' >&2
          printf '   so config resolution fell back to the ENGINE repo (issue #60 launch-binding hazard):\n' >&2
          printf '   workspace : %s\n' "$WORKSPACE_NAME" >&2
          printf '   project   : %s\n' "$PROJECT_ROOT" >&2
          printf '   your $PWD : %s\n' "$PWD" >&2
          printf '   Re-launch from inside your project, set HERD_CONFIG_FILE to its .herd/config,\n' >&2
          printf '   or set HERD_ALLOW_FOREIGN_CWD=1 if this foreign-cwd launch is intentional.\n' >&2
          exit 1
        fi ;;
    esac ;;
esac

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

# MODEL_ESCALATE_GLOB — deterministic model step-up (analogous to HEALTHCHECK_HEAVY_GLOB): when a
# lane's task text matches this egrep -i pattern, the lane forces the MODEL_FEATURE tier regardless
# of MODEL_QUICK or any per-spawn HERD_QUICK_MODEL/HERD_FEATURE_MODEL override. Empty (default) → off,
# zero behavior change. See herd-quick.sh / herd-feature.sh for the resolution point.
: "${MODEL_ESCALATE_GLOB:=""}"

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

unset _HERD_SCRIPT_DIR _HERD_REPO_DEFAULT _HERD_CONFIG_FILE _HERD_CONFIG_SOURCE

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
# argv0 marker for THIS project's watcher process (issue #60 attribution). agent-watch.sh re-execs
# itself under this distinctive per-workspace argv0 at startup, so its process is attributable to
# exactly one workspace in ps/pgrep. Two projects running the same engine are otherwise byte-identical
# in the process table (`bash .../agent-watch.sh` with no project in argv), so a good-faith stray-reap
# in one project could SIGTERM the other's live watcher. argv0 is visible via ps/pgrep on EVERY
# platform, whereas an env-var marker is NOT reliably readable via ps on modern macOS — which is why
# the marker is argv0, not an env var. The re-exec (agent-watch.sh) and the enumerator
# (_list_project_watchers in bin/herd) both key off this exact string. This SUBSUMES the separate
# 'per-workspace argv0' backlog goal. Uses the sanitized slug so the marker stays a safe pgrep literal.
HERD_WATCH_ARGV0="herd-watch-${_HERD_WS_SLUG}"
unset _HERD_WS_SLUG

# herd_console_guard <label> — startup BANNER + foreign-cwd REFUSAL for the long-running CONSOLES
# (agent-watch.sh / herd-watch.sh / backlog-view.sh / coordinator.sh). See issue #60: a console
# launched from a non-project dir silently binds to the engine's own dogfood config and then
# impersonates another repo's watcher (same lockfile) — killing "that repo's" watcher actually kills
# herdkit's. Two defenses live here (the config-source refusal above is the third):
#   • BANNER    — ALWAYS print the RESOLVED WORKSPACE_NAME + PROJECT_ROOT so the binding is never a
#                 mystery, even on a clean launch.
#   • CWD GUARD — REFUSE (return 1) when $PWD is not inside PROJECT_ROOT, naming WORKSPACE_NAME,
#                 PROJECT_ROOT and the offending $PWD so the misbinding is obvious. Bypassed by
#                 HERD_ALLOW_FOREIGN_CWD=1, the documented escape hatch for intentional cases.
# Normal launches PASS: coordinator.sh / cmd_reload start these consoles with --cwd $PROJECT_ROOT,
# so $PWD == PROJECT_ROOT. Callers invoke as:  herd_console_guard "<name>" || exit 1
herd_console_guard() {
  local _cg_label="${1:-herd console}"
  # Binding banner — one line, always printed (to stderr so it never corrupts a captured render).
  printf '🐑 %s · workspace=%s · project=%s\n' "$_cg_label" "$WORKSPACE_NAME" "$PROJECT_ROOT" >&2

  case "${HERD_ALLOW_FOREIGN_CWD:-}" in
    1|true|yes|on)
      printf '   (HERD_ALLOW_FOREIGN_CWD set — foreign-cwd guard bypassed)\n' >&2
      return 0 ;;
  esac

  # Resolve both paths physically (symlink-collapsed) so the containment test is robust to symlinks.
  local _cg_pwd _cg_root
  _cg_pwd="$(cd "$PWD" 2>/dev/null && pwd -P)" || _cg_pwd="$PWD"
  _cg_root="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || _cg_root="$PROJECT_ROOT"

  # $PWD must be PROJECT_ROOT itself or a descendant of it. The trailing slash + literal-root glob
  # makes "$root" match "$root/*" (the `*` also matches empty) but never a sibling like "$root-trees".
  case "$_cg_pwd/" in
    "$_cg_root"/*) return 0 ;;
  esac

  printf '\n🛑 herdkit: REFUSING to start %s — $PWD is not inside the resolved PROJECT_ROOT.\n' "$_cg_label" >&2
  printf '   workspace : %s\n' "$WORKSPACE_NAME" >&2
  printf '   project   : %s\n' "$_cg_root" >&2
  printf '   your $PWD : %s\n' "$_cg_pwd" >&2
  printf '   A console launched from outside its project silently binds to the wrong config and can\n' >&2
  printf '   impersonate another repo'"'"'s watcher (issue #60). Re-launch from inside the project,\n' >&2
  printf '   or set HERD_ALLOW_FOREIGN_CWD=1 if this foreign-cwd launch is intentional.\n' >&2
  return 1
}

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
