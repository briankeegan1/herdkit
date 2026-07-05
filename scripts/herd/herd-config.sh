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

# ── Duplicate-key lint for .herd/config (issue #115) ─────────────────────────
# .herd/config is SHELL-SOURCED (the `. "$_HERD_CONFIG_FILE"` below), so a KEY assigned more than
# once silently LAST-WINS with no warning — a stale/empty duplicate landing AFTER a good value
# silently flips engine behavior. Real incident: a stale `INTERACTION_TEST_CMD=""`
# placeholder left in the file after a merged PR also added the real
# `INTERACTION_TEST_CMD=.herd/_interaction.sh` → on source the empty one won → the widget-interaction
# gate was SILENTLY DISABLED. The fix below only SURFACES duplicates loudly; it does NOT change value
# resolution (shell last-wins is kept — auto-dedup is out of scope), it just makes last-wins non-silent.
#
# _herd_config_dup_keys <file> — print each key assigned more than once in <file>, one per line, in
# the order each first became a duplicate. Pure/read-only: skips blank lines + comments, handles both
# `KEY=...` and `export KEY=...`, and prints nothing (returns 0) for a clean or missing file. Shared
# by the source-time warning (below), `herd config lint`, and `herd doctor`.
_herd_config_dup_keys() {
  local _dk_file="${1:-}"
  [ -n "$_dk_file" ] && [ -f "$_dk_file" ] || return 0
  awk '
    {
      s = $0
      sub(/^[ \t]+/, "", s)                       # strip leading whitespace
      if (s == "" || s ~ /^#/) next               # skip blank lines and comments
      sub(/^export[ \t]+/, "", s)                 # tolerate an `export ` prefix
      if (s !~ /^[A-Za-z_][A-Za-z0-9_]*=/) next   # only KEY=... assignment lines
      k = s; sub(/=.*/, "", k)
      if (++count[k] == 2) order[++n] = k
    }
    END { for (i = 1; i <= n; i++) print order[i] }
  ' "$_dk_file"
}

# _herd_config_warn_dupes <file> — emit ONE loud stderr WARNING when <file> has duplicate keys. Guarded
# by an exported once-per-process marker so it fires at most once (and is spared in spawned children),
# so it is never spammy across every command. A clean config re-checks cheaply and stays silent; the
# authoritative reports (`herd config lint`, `herd doctor`) re-scan unconditionally.
_herd_config_warn_dupes() {
  case "${_HERD_CONFIG_DUP_WARNED:-}" in ""|0) ;; *) return 0 ;; esac
  local _wd_dupes; _wd_dupes="$(_herd_config_dup_keys "${1:-}")"
  [ -n "$_wd_dupes" ] || return 0
  export _HERD_CONFIG_DUP_WARNED=1
  {
    printf '\n⚠️  herdkit: duplicate key(s) in %s — shell last-wins SILENTLY overrides the earlier\n' "${1:-}"
    printf '   assignment(s), which can disable a gate (issue #115). Duplicated key(s):\n'
    local _wd_k
    while IFS= read -r _wd_k; do
      [ -n "$_wd_k" ] && printf '     • %s  (last assignment wins)\n' "$_wd_k"
    done <<< "$_wd_dupes"
    printf '   Fix: delete the stale duplicate line(s). Diagnose with `herd config lint`.\n\n'
  } >&2
  return 0
}

# _herd_main_worktree <dir> — print the MAIN working tree for <dir>. When an engine component runs
# from INSIDE a builder worktree (a linked git worktree living at <pool>/<slug>), <dir> is that
# worktree; git's common dir still points back at the owning repo, whose MAIN working tree git lists
# FIRST in `worktree list`. Binding the fallback PROJECT_ROOT to that main tree keeps the derived
# ${PROJECT_ROOT}-trees journal/state default anchored to the REAL project, instead of fabricating a
# phantom <pool>/<slug>-trees/ from the worktree path and stranding builder-side gate events there,
# lost from `herd why`/`herd log` post-mortems (issue #144). Read-only, best-effort: echoes <dir>
# unchanged when git is absent, <dir> is not a repo, or <dir> already IS the main working tree.
_herd_main_worktree() {
  local _mw_dir="${1:-}"
  [ -n "$_mw_dir" ] || return 0
  command -v git >/dev/null 2>&1 || { printf '%s' "$_mw_dir"; return 0; }
  local _mw_main
  _mw_main="$(git -C "$_mw_dir" worktree list --porcelain 2>/dev/null \
             | awk '/^worktree /{print substr($0, 10); exit}')"
  if [ -n "$_mw_main" ] && [ -d "$_mw_main" ]; then
    printf '%s' "$_mw_main"
  else
    printf '%s' "$_mw_dir"
  fi
}

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
  # Issue #115: surface a duplicate KEY= (silent shell last-wins can disable a gate) — at most once
  # per process. Runs AFTER the source so a broken source still fails as before; value resolution is
  # unchanged (the config was already sourced with normal last-wins semantics above).
  _herd_config_warn_dupes "$_HERD_CONFIG_FILE"
fi

# ── Fallback defaults (generic; no project literals) ─────────────────────────
# PROJECT_ROOT defaults to the repo that owns the .herd/config we just read (or, if none, the repo
# the engine lives in). Everything else derives from it. Computed with an explicit unset-guard rather
# than the `: "${PROJECT_ROOT:=…}"` idiom for two reasons: (a) the git resolve stays LAZY — it fires
# ONLY on the fallback (no config set PROJECT_ROOT), so the normal `herd <cmd>` path pays no git call;
# (b) this tweaks how an EXISTING key's fallback is computed, so keeping it off the `:=` line avoids
# the caps-sync heuristic misreading it as a NEW config key. On the fallback it re-anchors a
# builder-worktree path to the MAIN working tree so WORKTREES_DIR below never derives the phantom
# <pool>/<slug>-trees/ (issue #144).
if [ -z "${PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$(_herd_main_worktree "$_HERD_REPO_DEFAULT")"
fi
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

# BACKLOG_VIEW_EXTRAS — view-only backlog-pane extra section. Default "" (off) → the pane output is
# byte-identical to before. Set "github-issues" and the backlog viewer renders a SECOND, clearly
# labeled '📥 incoming (github issues)' section BENEATH the primary work queue, listing this repo's
# open GitHub issues (the herd-report inbox). Strictly ADDITIVE display: it never merges into the
# primary list and never feeds `herd backlog` or work-selection — SCRIBE_BACKEND stays the single
# source of truth. Defaulted here so every path that sources viewer config (render/reload, the
# viewer itself under `set -u`) sees it. Applied on the backlog pane's next launch (herd pane
# backlog / herd reload).
: "${BACKLOG_VIEW_EXTRAS:=""}"

# TASK_PANE_VIEW — builder-tab task-spec viewer. Default "on": the builder lanes (herd-quick.sh /
# herd-feature.sh) render $WORKTREES_DIR/<slug>.task.md live in the tab's OTHERWISE-IDLE root pane via
# task-spec-view.sh, so a human sees WHAT the agent was told to build instead of a bare shell. The
# pane is unused today, so this is strictly additive UX — "off" restores the bare shell exactly. The
# lanes launch it ONLY when the root pane is not hosting the app preview (never over a live process)
# and NEVER under the headless driver (no panes). Defaulted here so the lanes see it under `set -u`.
: "${TASK_PANE_VIEW:="on"}"

# HERD_THEME — pluggable theming across all herd color surfaces. Default "tokyonight" (the shipped
# built-in), which renders byte-identically to the pre-theme hardcoded palettes. A theme is a
# directory holding palette.sh (the console C_* truecolor + optional C_CLI_* 16-color CLI overrides)
# and glow.json (the glamour style for glow-rendered surfaces). Resolution order (per file, so a
# theme may supply only one): .herd/themes/<name>/ (user, project-local) → templates/themes/<name>/
# (engine built-ins) → tokyonight fallback. An unknown/broken theme warns loudly once and falls back —
# it never breaks a console. Consumed via scripts/herd/theme.sh by agent-watch.sh (console palette),
# backlog-view.sh + task-spec-view.sh (glow.json), and bin/herd/status/fleet/cost/why +
# herd-approve.sh (CLI palette). Exported so child processes (e.g. the task-spec viewer) inherit it.
: "${HERD_THEME:="tokyonight"}"
export HERD_THEME

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

# ── Risk-tiered pre-merge review (REVIEW_ESCALATE_GLOB) ───────────────────────
# By DEFAULT the adversarial review gate runs EVERY PR through the full $MODEL_REVIEW (Opus) — the
# single biggest recurring engine cost. Setting REVIEW_ESCALATE_GLOB opts into RISK-PROPORTIONAL
# review: the reviewer tier is chosen deterministically from the PR's changed-file paths (via
# `gh pr diff <pr> --name-only`), analogous to HEALTHCHECK_HEAVY_GLOB / MODEL_ESCALATE_GLOB:
#   • paths matching this egrep pattern (engine surface)      → STRONG tier ($MODEL_REVIEW, Opus)
#   • a large diff (> $REVIEW_ESCALATE_MAXFILES files changed) → STRONG tier, even without a match
#   • a docs/test-only diff (only *.md and tests/ paths)      → review SKIPPED entirely: a PASS is
#       recorded with provenance source=skipped-low-risk (no reviewer spawned), still sha-keyed so
#       it is never re-run
#   • any other small, low-risk diff                          → CHEAP tier ($REVIEW_MODEL_CHEAP)
# SAFE DEFAULT: leave REVIEW_ESCALATE_GLOB EMPTY (the default) and behavior is UNCHANGED — every PR
# gets the full $MODEL_REVIEW review, no diff is classified at all. The tiering only activates when
# the operator opts in by setting the glob.
# TRADEOFF (must be explicit): a cheaper reviewer can MISS subtle correctness bugs, and glob/size
# risk-classification can MISJUDGE a risky diff as low-risk. Classification therefore fails SAFE —
# any uncertainty (unreadable or empty diff) escalates to the STRONG tier, never a downgrade — but
# a mis-scoped glob is still an operator risk. Reserve the glob for genuinely engine-critical paths.
: "${REVIEW_ESCALATE_GLOB:=""}"
# Cheaper reviewer model tier for low-risk diffs when tiering is active (default: claude-sonnet-4-6).
: "${REVIEW_MODEL_CHEAP:="claude-sonnet-4-6"}"
# A tiered diff touching MORE than this many files escalates to the STRONG tier regardless of the
# glob (a large diff is risky even when no single path matches). Default 10. Non-numeric → 10.
: "${REVIEW_ESCALATE_MAXFILES:="10"}"

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
# SPAWN_AHEAD — advisory spawn-rate lead over the review gate (herd-spawn-gate.sh, sourced by the
# lanes). When the review pipeline is saturated (live+queued reviews ≥ REVIEW_CONCURRENCY), a lane
# HOLDS a new spawn once in-flight builders already exceed REVIEW_CONCURRENCY + SPAWN_AHEAD — so the
# coordinator never builds faster than the gate can review, burning builder-session tokens on PRs
# that just sit in REVIEW_QUEUED. Default 1 keeps ONE build ahead of the gate so the pipeline stays
# fed; 0 → strict no-surplus. Advisory only: --force / HERD_FORCE_SPAWN=1 bypasses it. Non-numeric → 1.
: "${SPAWN_AHEAD:="1"}"
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

# herd_write_ratelimit_hook <worktree> — configure this worktree's project-level Claude Code hook so
# a turn that ENDS on an account rate-limit writes a sentinel file the watcher polls. This is the
# PRIMARY, version-robust limit-hit signal (agent-watch.sh _detect_limit_hit) — far better than
# regex-scraping the banner, which stays as the fallback. The hook writes the reset time (raw banner
# text) into <worktree>/.herd-limit-sentinel; the watcher parses it to schedule an in-place
# `claude --continue` resume at the reset.
#
# The write is ADDITIVE + SAFE: it merges into an existing .claude/settings.json (never clobbers
# unrelated keys or other hooks), is idempotent (re-running changes nothing once present), round-
# trips through a temp file + atomic os.replace, and tolerates a missing/corrupt settings file
# (starting fresh from {}). Best-effort: any failure warns but returns 0 so it never aborts worktree
# creation — the fallback banner-scrape still catches the limit hit if the hook is absent.
#
# NOTE: the exact hook event name / rate-limit matcher is Claude-Code-version-dependent; the watcher
# does NOT rely on it firing (the banner-scrape fallback covers hookless environments). Disable with
# HERD_LIMIT_HOOK=off.
herd_write_ratelimit_hook() {
  local _rh_dir="${1:-}"
  [ -n "$_rh_dir" ] || return 0
  [ "${HERD_LIMIT_HOOK:-on}" != "off" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then return 0; fi
  local _rh_abs
  _rh_abs="$(cd "$_rh_dir" 2>/dev/null && pwd -P)" || _rh_abs="$_rh_dir"
  local _rh_settings="$_rh_abs/.claude/settings.json"
  local _rh_sentinel="$_rh_abs/.herd-limit-sentinel"
  mkdir -p "$_rh_abs/.claude" 2>/dev/null || return 0
  if ! HERD_RH_SETTINGS="$_rh_settings" HERD_RH_SENTINEL="$_rh_sentinel" python3 - <<'PY'
import json, os, sys, tempfile

path = os.environ["HERD_RH_SETTINGS"]
sentinel = os.environ["HERD_RH_SENTINEL"]

# The hook command: write the stop reason (reset banner text, if the harness passes it on stdin) to
# the sentinel; an empty write still marks "limit hit". Kept dependency-free (sh + cat).
cmd = "cat > %s 2>/dev/null || : > %s" % (
    "'" + sentinel.replace("'", "'\\''") + "'",
    "'" + sentinel.replace("'", "'\\''") + "'",
)
entry = {"matcher": "rate_limit", "hooks": [{"type": "command", "command": cmd}]}

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

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
arr = hooks.get("StopFailure")
if not isinstance(arr, list):
    arr = []

# Idempotent: our rate_limit matcher already present with the same sentinel command → no write.
for e in arr:
    if isinstance(e, dict) and e.get("matcher") == "rate_limit":
        cur = e.get("hooks")
        if isinstance(cur, list) and any(
            isinstance(h, dict) and h.get("command") == cmd for h in cur
        ):
            sys.exit(0)
        e["matcher"] = "rate_limit"
        e["hooks"] = entry["hooks"]
        break
else:
    arr.append(entry)

hooks["StopFailure"] = arr
data["hooks"] = hooks

d = os.path.dirname(path) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.json.", suffix=".tmp")
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
    printf '⚠️  herdkit: could not write the rate-limit hook for %s (limit auto-resume falls back to banner-scrape)\n' "$_rh_abs" >&2
  fi
  return 0
}

# herd_write_task_spec <spec_file> <spec_content> — externalize a builder's full task spec.
#
# Writes <spec_content> (the caller task + the workflow-rules footer) to <spec_file> and, on
# success, prints a SHORT pointer prompt to stdout for the caller to hand the agent as argv — so a
# multi-kilobyte spec no longer rides in the `claude … "<TASK>"` command line. <spec_file> lives at
# $WORKTREES_DIR/<slug>.task.md, a SIBLING of the worktree dir (outside its tracked tree), so the
# builder never commits it.
#
# FAIL-LOUD contract (this is the #69 BLOCK fix — do NOT regress it): a failed OR partial spec write
# must ABORT before any pointer is emitted, so the caller cannot spawn a builder against a missing or
# truncated spec. Concretely, the write is checked (`printf … || return 1`) AND the file is asserted
# non-empty (`[ -s … ] || return 1`) BEFORE the pointer printf. The pointer printf always succeeds,
# so emitting it first would mask a failed write and return rc=0 — exactly the bug the reviewer hit.
# Callers invoke as  POINTER="$(herd_write_task_spec "$FILE" "$SPEC")"  under `set -euo pipefail`, so
# a non-zero return aborts the lane at the assignment, before the `herdr agent start … claude` call.
herd_write_task_spec() {
  local _ts_file="${1:?herd_write_task_spec: spec file path required}"
  local _ts_spec="${2:?herd_write_task_spec: spec content required}"
  # Write the full spec, fail loud. A failed write (unwritable dir, target is a directory, disk
  # full, …) returns non-zero HERE — the trailing pointer printf must never paper over it.
  if ! printf '%s\n' "$_ts_spec" > "$_ts_file"; then
    printf '❌ herdkit: could not write task spec to %s — aborting before spawning a builder.\n' "$_ts_file" >&2
    return 1
  fi
  # Assert the spec actually landed with content. Guards the partial/truncated-write case where the
  # printf reported success but the file is empty — abort rather than pointing a builder at nothing.
  if [ ! -s "$_ts_file" ]; then
    printf '❌ herdkit: task spec at %s is empty after write — aborting before spawning a builder.\n' "$_ts_file" >&2
    return 1
  fi
  # Spec is safely on disk — only now emit the SHORT pointer the agent receives in place of the spec.
  printf 'Read your task spec at %s and build exactly what it specifies. Do not commit that file. Follow AGENTS.md, run the healthcheck, then gh pr create.' "$_ts_file"
}
