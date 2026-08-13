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

# _herd_config_file_keys <file> — print, once each in file order, EVERY key a shell-sourced config
# file assigns (blank/comment lines skipped, an `export KEY=` prefix tolerated) — the same extraction
# grammar _herd_config_dup_keys uses for its duplicate scan, but returning every key rather than only
# the duplicated ones. Used by the cross-worktree main-checkout overlay (HERD-558) to discover which
# keys a foreign config.local sets, WITHOUT sourcing it into the current shell wholesale (that overlay
# only wants to adopt POLICY-class keys from it, never machine-scoped ones). Pure/read-only.
_herd_config_file_keys() {
  local _fk_file="${1:-}"
  [ -n "$_fk_file" ] && [ -f "$_fk_file" ] || return 0
  awk '
    {
      s = $0
      sub(/^[ \t]+/, "", s)
      if (s == "" || s ~ /^#/) next
      sub(/^export[ \t]+/, "", s)
      if (s !~ /^[A-Za-z_][A-Za-z0-9_]*=/) next
      k = s; sub(/=.*/, "", k)
      if (!seen[k]++) print k
    }
  ' "$_fk_file"
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

# _herd_read_project_config <project-path> — source a project's .herd/config in an ISOLATED subshell
# (so its vars never leak into the caller or bleed between projects) and print one TAB-delimited row:
#   workspace<TAB>project_root<TAB>worktrees_dir<TAB>default_branch<TAB>repo
# Applies the SAME fallbacks the main loader below does. This is the ONE seam that reads a FOREIGN
# project's config from OUTSIDE the current-project load path (the `herd fleet` fan-out) — so the direct
# `. .herd/config` lives HERE in the config module, never scattered across engine scripts (the
# seam-conformance config-source rule). Returns non-zero when there is no config to read.
_herd_read_project_config() {
  local path="$1" cfg="$1/.herd/config"
  [ -f "$cfg" ] || return 1
  (
    set +eu 2>/dev/null || true
    PROJECT_ROOT=""; WORKTREES_DIR=""; WORKSPACE_NAME=""; DEFAULT_BRANCH=""; HERD_REPO=""
    # shellcheck source=/dev/null
    . "$cfg" 2>/dev/null || exit 1
    # HERD-518: overlay the per-user/per-machine config.local on top of the baseline we just sourced —
    # same baseline-first/overlay-second order as the main loader's config.local block above. On a
    # CLONED project, this is where a collaborator overrides the original author's committed
    # PROJECT_ROOT for THIS machine, without touching the committed baseline.
    local overlay="$path/.herd/config.local"
    if [ -f "$overlay" ]; then
      # shellcheck source=/dev/null
      . "$overlay" 2>/dev/null || true
    fi
    # Apply the SAME fallbacks the main loader does. Written as explicit `-n` guards (the vars are
    # pre-initialised to "" just above), NOT the colon-equals defaulting idiom: the caps-sync gate
    # greps THIS file for that form as its "new config key" heuristic, so using it here would
    # false-trip it — the same reason the main-loader PROJECT_ROOT fallback below deliberately avoids
    # colon-equals.
    [ -n "$PROJECT_ROOT" ]   || PROJECT_ROOT="$path"
    # HERD-518: a config cloned from another machine still carries the ORIGINAL author's absolute
    # PROJECT_ROOT, which never exists here. When neither the baseline nor the overlay resolved a
    # PROJECT_ROOT that exists on THIS machine but the argument path does, localize to it — and carry
    # a WORKTREES_DIR that was itself derived from that foreign root along with it, so it doesn't keep
    # pointing at a path that can never exist here either. Fail-soft: a foreign-but-real path (e.g. a
    # shared mount) is left alone, and this never fires when the overlay already resolved a real path.
    if [ ! -d "$PROJECT_ROOT" ] && [ -d "$path" ]; then
      printf 'herdkit: localizing PROJECT_ROOT for %s (committed %s does not exist here)\n' \
        "$path" "$PROJECT_ROOT" >&2
      case "$WORKTREES_DIR" in
        "$PROJECT_ROOT"*) WORKTREES_DIR="$path${WORKTREES_DIR#"$PROJECT_ROOT"}" ;;
      esac
      PROJECT_ROOT="$path"
    fi
    [ -n "$WORKTREES_DIR" ]  || WORKTREES_DIR="${PROJECT_ROOT}-trees"
    [ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="origin/main"
    [ -n "$WORKSPACE_NAME" ] || WORKSPACE_NAME="$(basename "$PROJECT_ROOT")"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$WORKSPACE_NAME" "$PROJECT_ROOT" "$WORKTREES_DIR" "$DEFAULT_BRANCH" "$HERD_REPO"
  )
}

_HERD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HERD_REPO_DEFAULT="$(cd "$_HERD_SCRIPT_DIR/../.." && pwd)"
# The shared INVOCATION-CONTEXT check (HERD-269 / HERD-310). bin/herd sources it directly for the CLI
# actuator guard; herd-config.sh is sourced by EVERY engine surface (agent-watch, the lanes, the
# hermetic tests), so sourcing it here makes herd_context_pane_guard reachable wherever a pane/tab
# close primitive lives (herd_teardown_slug below, herd_driver_close_pane) without each caller having
# to source it. Defines functions only; reads cwd/WORKSPACE_NAME lazily at call time — no side effect
# on source. Fail-soft if somehow absent (an older engine tree): the primitives guard on command -v.
# shellcheck source=/dev/null
[ -f "$_HERD_SCRIPT_DIR/context-guard.sh" ] && . "$_HERD_SCRIPT_DIR/context-guard.sh"
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

# _HERD_ENGINE_CORE_KEYS (HERD-465) — THE single list of config knobs the Python engine core reads
# from os.environ (pysrc/herd/live_runtime.py's _CORE_ENV_KEYS, HERD-449). Consumed at BOTH ends of
# this file: the RESET below, immediately BEFORE baseline+overlay are sourced, and the matching
# `export` loop far below once every key is resolved. One list for both so they can never drift apart
# the way the three one-off HERD-353/345/359 exports (and the ad-hoc HERD-449 sweep before this fix)
# did.
_HERD_ENGINE_CORE_KEYS="MERGE_POLICY WATCHER_AUTOMERGE HUMAN_VERIFY_POLICY MERGE_METHOD \
DELETE_BRANCH_ON_MERGE REFIX_MAX_ROUNDS REFIX_COMPLETE_MIN HERD_REFIX_WAIT_TIMEOUT WORK_UNIT_KIND \
MERGE_RESULT_GATE MERGE_QUEUE HEALTH_CONCURRENCY REVIEW_CONCURRENCY WATCHER_SCOPE WATCHER_VIEW \
WATCHER_VIEW_AUTHOR WATCHER_VIEW_ASSIGNEE WATCHER_VIEW_LABEL WATCHER_VIEW_STATUS \
WATCHER_VIEW_DEPS_LABEL WATCHER_OWNER GATE_STATUS GATE_STATUS_PENDING MERGE_FAIRNESS \
MERGE_FAIRNESS_STARVE_THRESHOLD INFRA_BREAKER_MAX INFRA_BREAKER_COOLDOWN HEALTH_TRUST_BUILDER \
STALE_BASE_AUTOFIX HEALTH_SOURCE CORE_SURFACE_GLOB AUTOFIX_SCOPE"

# ── Engine-core key RESET (HERD-465): the FILE is authoritative, never inherited/stale env ─────────
# WATCHER_SELF_RESTART (HERD-251) re-execs this very process in place, inheriting every var it had
# already exported — including every key above, exported for the Python child per HERD-449. A config
# change made AFTER first launch was therefore silently invisible down the whole re-exec chain: each
# key below is resolved with the set-if-unset idiom `: "${KEY:=default}"`, which only fires when the
# key is UNSET — and an inherited exported value already counts as set, so it wins over whatever the
# file now says. GROUNDED 2026-07-31: an operator flipped HUMAN_VERIFY_POLICY=auto at 14:45; a
# re-exec-chain watcher still resolved coordinator at 15:12 and applied a hold that policy made
# impossible (journal: hold_applied ... human_verify_policy=coordinator while herd config get said
# auto).
#
# Fix: when there is an actual project config to be authoritative over — the resolved
# HERD_CONFIG_FILE, or its config.local sibling (HERD-47), exists on disk — unset every engine-core
# key BEFORE sourcing either, so the file's own assignment (or, if the file stays silent on a key,
# this loader's own `:=` engine default further down) is what wins. An inherited value never shadows
# it again, no matter how many re-execs it has survived.
#
# When NEITHER file exists there is nothing to be authoritative over, so the reset is skipped — this
# is exactly the hermetic test/sim seam (scripts/herd/sim/sandbox-*-scenario.sh, many tests/test-*.sh)
# that points HERD_CONFIG_FILE at a deliberately absent path (e.g. "$ART/no-such-config") and
# pre-exports these very keys — MERGE_POLICY, HEALTH_CONCURRENCY, INFRA_BREAKER_MAX, etc. — directly
# into env to drive a scenario with no config file on disk at all. Resetting there would null every
# knob back to its built-in default and break that seam; skipping keeps every such caller
# byte-identical. HERD_CONFIG_ENV_OK=1 is an explicit escape hatch (same shape as the
# HERD_ALLOW_FOREIGN_CWD override below) for a caller that needs its pre-exported value to win even
# against a REAL file — no such caller exists today, but the lever costs nothing to keep open.
case "${HERD_CONFIG_ENV_OK:-}" in
  1|true|yes|on) : ;;
  *)
    if [ -f "$_HERD_CONFIG_FILE" ] || [ -f "$(dirname "$_HERD_CONFIG_FILE")/config.local" ]; then
      for _hcr_key in $_HERD_ENGINE_CORE_KEYS; do
        unset -v "$_hcr_key"
      done
      unset _hcr_key
    fi
    ;;
esac

if [ -f "$_HERD_CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  . "$_HERD_CONFIG_FILE"
  # Issue #115: surface a duplicate KEY= (silent shell last-wins can disable a gate) — at most once
  # per process. Runs AFTER the source so a broken source still fails as before; value resolution is
  # unchanged (the config was already sourced with normal last-wins semantics above).
  _herd_config_warn_dupes "$_HERD_CONFIG_FILE"
fi

# ── Per-user overlay: .herd/config.local (HERD-47) ───────────────────────────
# Split the single tracked .herd/config into a COMMITTED project baseline (sourced just above) plus
# an OPTIONAL, gitignored per-user/per-machine overlay sourced HERE, AFTER it — mirroring the
# settings.json / settings.local.json (and .env / .env.local) convention Claude Code itself uses.
# Both files are plain shell-sourced KEY=value, so a LATER assignment wins: any key set in
# config.local OVERRIDES the baseline, keys it leaves unset keep the baseline value, and the engine
# fallbacks below still fill anything neither file set. This is the whole precedence rule — baseline
# first, overlay second. When config.local is ABSENT this block is inert and the effective config is
# BYTE-IDENTICAL to a single-file setup (backward-compatible). The overlay is the SIBLING of the
# resolved baseline (.herd/config.local next to .herd/config), and it is ZERO-SECRET exactly like the
# baseline: credentials still live only in .herd/secrets, which is never sourced here. It intentionally
# does NOT participate in the console launch-binding guard (_HERD_CONFIG_SOURCE tracks the BASELINE
# resolution only) — the overlay tunes values, it never re-binds which project's config was found.
_HERD_CONFIG_LOCAL_FILE="$(dirname "$_HERD_CONFIG_FILE")/config.local"
if [ -f "$_HERD_CONFIG_LOCAL_FILE" ]; then
  # shellcheck source=/dev/null
  . "$_HERD_CONFIG_LOCAL_FILE"
  _herd_config_warn_dupes "$_HERD_CONFIG_LOCAL_FILE"
fi

# ── Cross-worktree overlay: the MAIN checkout's config.local (HERD-558) ──────
# Live failure this closes: `herd config set --local HEALTHCHECK_CMD=true` run in the MAIN checkout
# only muted MAIN-checkout-context runs. `healthcheck.sh` resolves config from the TARGET WORKTREE's
# .herd/ — and a linked worktree is a SEPARATE checkout that `git worktree add` never populates with
# the main checkout's gitignored config.local (it copies only tracked files) — so the overlay block
# just above finds no sibling config.local in the worktree and the operator's mute never reaches it.
# 137 suite processes kept running post-"release" because the override took effect nowhere but the
# main checkout's own shell.
#
# PRECEDENCE (mirrored in the config.local template header, bin/herd's _config_ensure_local):
#     committed config  <  worktree's own config.local  <  MAIN checkout's config.local
# — for POLICY-class keys only. A policy key is any config key NOT marked scope=machine in
# templates/capabilities.tsv (HEALTHCHECK_CMD, MERGE_POLICY, HUMAN_VERIFY_POLICY, concurrency caps,
# …): it governs how the gate/suite BEHAVES, so an operator flipping one from the main checkout means
# it for every worktree that pool spawns, and it must reach them even though they never inherit the
# gitignored file directly.
#
# MACHINE-scoped keys (MODEL_*, HERD_DRIVER, WATCHER_VIEW*, …) are deliberately EXCLUDED from this
# outer layer — worktree-local (or the committed baseline, when the worktree sets nothing of its own)
# keeps winning for them exactly as before this fix. Those keys hold per-seat/per-process state (a
# builder pane's own model tier, its own driver); an operator's MAIN-checkout preference for "what I
# run" is not a more correct answer than the worktree's own for "what THIS seat runs", so pulling them
# from the main checkout would be an unjustified new override, not a bug fix.
#
# Only fires when resolving for a WORKTREE distinct from the main checkout — a run already IN the main
# checkout sourced its own config.local in the block above, so this would be a no-op re-read of the
# same file. The main checkout is resolved from the ALREADY-SOURCED, committed PROJECT_ROOT (the
# canonical pointer to it) when that names a real directory; only when PROJECT_ROOT is unset does this
# fall back to git's own notion of the main working tree (first entry of `git worktree list`, via
# _herd_main_worktree, defined above) from the worktree's own checkout dir. NEVER guessed by
# string-manipulating the worktree's path (e.g. stripping a "-trees/<slug>" suffix) — that breaks the
# moment WORKTREES_DIR is renamed or a project nests its pool differently.
_herd_wt_project_dir="$(dirname "$(dirname "$_HERD_CONFIG_FILE")")"
_herd_main_checkout=""
if [ -n "${PROJECT_ROOT:-}" ] && [ -d "$PROJECT_ROOT" ]; then
  _herd_main_checkout="$PROJECT_ROOT"
elif command -v git >/dev/null 2>&1; then
  _herd_main_checkout="$(_herd_main_worktree "$_herd_wt_project_dir")"
fi
if [ -n "$_herd_main_checkout" ]; then
  _herd_main_checkout_real="$(cd "$_herd_main_checkout" 2>/dev/null && pwd -P || printf '%s' "$_herd_main_checkout")"
  _herd_wt_project_dir_real="$(cd "$_herd_wt_project_dir" 2>/dev/null && pwd -P || printf '%s' "$_herd_wt_project_dir")"
  _herd_main_local="$_herd_main_checkout/.herd/config.local"
  if [ "$_herd_main_checkout_real" != "$_herd_wt_project_dir_real" ] && [ -f "$_herd_main_local" ]; then
    _herd_caps_file="${HERD_CAPABILITIES_FILE:-${HERDKIT_HOME:-$_HERD_REPO_DEFAULT}/templates/capabilities.tsv}"
    while IFS= read -r _herd_mco_key; do
      [ -n "$_herd_mco_key" ] || continue
      _herd_mco_scope="project"
      if [ -f "$_herd_caps_file" ]; then
        _herd_mco_scope="$(awk -F'\t' -v k="$_herd_mco_key" \
          '$2=="config" && $1==k { s=$6; gsub(/[[:space:]]+$/,"",s); print s; exit }' "$_herd_caps_file")"
        [ "$_herd_mco_scope" = "machine" ] || _herd_mco_scope="project"
      fi
      # Machine-scoped: leave whatever the baseline/worktree-local overlay already resolved standing.
      [ "$_herd_mco_scope" = "machine" ] && continue
      _herd_mco_val="$(
        set +eu 2>/dev/null || true
        # shellcheck source=/dev/null
        . "$_herd_main_local" 2>/dev/null || true
        eval "printf '%s' \"\${${_herd_mco_key}-}\""
      )"
      eval "$_herd_mco_key=\"\$_herd_mco_val\""
    done < <(_herd_config_file_keys "$_herd_main_local")
    unset _herd_mco_key _herd_mco_scope _herd_mco_val
  fi
  unset _herd_main_checkout_real _herd_wt_project_dir_real _herd_main_local _herd_caps_file
fi
unset _herd_wt_project_dir _herd_main_checkout

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
# PROJECT_ARCHETYPE (HERD-409) — what kind of project this is: code (default) | research-lab | docs.
# See templates/archetypes.tsv. Default "code" is byte-identical to pre-HERD-409 behavior (stack-aware
# healthcheck seeding from scout's detected language, unaffected by this key).
: "${PROJECT_ARCHETYPE:="code"}"
# Project-defined branch naming for the builder lanes (HERD-120). The DEFAULT 'feat/{slug}' renders
# byte-identical to the historically-hardcoded feat/<slug>, so an unset key is zero behavior change.
# Tokens: {slug} (required — the coordinator-chosen kebab name) and optional {ref} (the tracker id).
# ONE shared render+parse helper (herd_branch_render / herd_branch_parse, below) routes every branch
# construction AND parse site through this so naming stays consistent end-to-end.
: "${BRANCH_TEMPLATE:="feat/{slug}"}"

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

# SCRIBE_LINGER_SECS — drainer linger window (HERD-88). After the backlog drainer empties the queue
# and `scribe-step.sh next` would return EMPTY, the drainer keeps polling for this many extra seconds
# before it finishes and its session exits, so a burst of requests arriving with idle gaps between
# them is drained by ONE scribe session instead of paying a fresh MODEL_SCRIBE cold-start per gap.
# Default 0 → today's behavior byte-identical (next's total wait stays == SCRIBE_POLL). Suggest 90.
# Defaulted here so scribe.sh (which expands it into the drainer prompt under `set -u`) and
# scribe-step.sh both see it.
: "${SCRIBE_LINGER_SECS:=0}"

# DRAINER_HEARTBEAT_TIMEOUT — drainer singleton liveness window in seconds (HERD-109). The scribe and
# researcher drainers are per-project singletons: an enqueue that finds a drainer of that name already
# in `herdr agent list` short-circuits with "already running" and spawns nothing. That is a liveness
# blind spot — a LISTED but HUNG drainer (wedged claude session / stuck step) never drains, blocking the
# queue forever. When set, the *-step.sh drainers heartbeat on every drain step; if the enqueue path
# then finds a "running" drainer whose heartbeat is older than this many seconds, it treats it as HUNG,
# RECLAIMS the singleton, and spawns a FRESH drainer. The queue's atomic per-request claim keeps this
# from double-draining. Conservative default 900 (15 min) — far above any single legitimate drain step,
# so a healthy drainer is never falsely reclaimed and behavior is byte-identical to before. Set 0 to
# DISABLE (never reclaim on liveness — pure legacy behavior). Non-numeric → treated as 0 (off). Shared
# by scribe/research; defaulted here so scribe.sh / research.sh (which read it under `set -u`) both see it.
: "${DRAINER_HEARTBEAT_TIMEOUT:=900}"

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

# DOCTOR_STARTUP_HINT — proactive soft-dependency surfacing on control-room startup (herd reload /
# coordinator launch). Default "off": startup prints NOTHING extra, so every startup path stays
# byte-identical unless the operator opts in. Set "on" and startup emits ONE dim line per MISSING
# soft dep (glow, shellcheck, bats), each naming the single feature it degrades, then a dim pointer
# to `herd doctor` for the install command — never red, never blocking (soft deps only degrade; the
# no-false-red rule). Any value other than "on" is treated as off. Defaulted here so the startup
# paths see it under `set -u`.
: "${DOCTOR_STARTUP_HINT:="off"}"

# AGENT_UPDATE — opt-in safe self-update of the AGENT RUNTIME (HERD-149). Default "off": nothing runs,
# byte-identical to today — operators keep updating claude (or, via the driver seam, codex/grok) by
# hand or a personal OS job, outside the engine. Set "on" and `herd agent-update` (scripts/herd/
# agent-update.sh) DETECTS the installer (brew/npm/native) of the runtime HERD_DRIVER points at, runs
# the update, and — the whole point — HANDLES the macOS footgun where a `brew upgrade --cask` leaves
# the new binary com.apple.quarantine'd so every new exec hangs in _dyld_start (issue #137): it
# xattr-de-quarantines the resolved binary after the update. DRIVER-AWARE (updates whichever runtime
# the active driver binds via DRIVER_AGENT_BINARY/_NPM_PKG/_BREW_PKG/_NATIVE_UPDATE) and FAIL-SOFT (a
# missing runtime / failed installer command warns, never hard-aborts). Any value other than "on" is
# off. Defaulted here so the mechanism + CLI see it under `set -u`.
: "${AGENT_UPDATE:="off"}"

# ENGINE_MIN — the ENGINE VERSION HANDSHAKE floor (HERD-179): the minimum herdkit ENGINE LEVEL this
# project requires. Committed in .herd/config and stamped MONOTONICALLY by `herd upgrade` to the level
# of the engine that ran it. An engine BELOW this floor is STALE: every write path (lane spawn
# preflight, herd-claim, scribe-step apply, `herd backend switch`) refuses with the remedy `run herd
# update`, reads warn only, and HERD_ENGINE_SKIP_HANDSHAKE=1 is a journaled escape hatch. Default 0 ⇒
# no floor ⇒ the handshake is inert and behavior is byte-identical to before it existed. The mechanism
# lives in scripts/herd/engine-version.sh (which also carries the engine's own level constant).
: "${ENGINE_MIN:="0"}"

# ENGINE_AUTOUPDATE — what the engine DOES about a stale local checkout (HERD-179): off (default) |
# check | auto. off runs nothing beyond the always-advisory `herd doctor` row. check paints one quiet
# "engine outdated" note on the watcher console and calls it out in the doctor. auto additionally has
# the watcher dispatch `herd update` in a QUIESCENT window — reusing that command's own refusal when
# builders are mid-flight or the engine checkout is dirty, rate-limited by a cooldown so a persistent
# refusal never hammers the remote. Any other value is off. Defaulted here so every path sees it
# under `set -u`.
: "${ENGINE_AUTOUPDATE:="off"}"

# ENGINE_SEAT_RECONCILE — CROSS-SEAT DUAL-ENGINE SAFETY (HERD-308, engine-port P3.5): off (default) |
# on. The complement to the ENGINE_MIN handshake — a POOL-LEVEL invariant that needs no committed
# floor. With it on, the watcher STAMPS the engine level it writes at into a shared pool registry
# ($WORKTREES_DIR/.herd/engine-seats.tsv) and RECONCILES it every tick: two DISTINCT engine levels
# writing the same pool (the dual-engine window between the bash and Python engines, or two operators
# on different checkouts) is never allowed to coexist silently — the STALE seat (the lower level) HALTS
# loudly (a red console row, a journaled engine_seat_mismatch) and its merge/blessing writes are HELD,
# so there are ZERO cross-mismatch writes; the leading seat proceeds but says so. off is a HARD no-op:
# nothing is stamped, no registry is written, and the console/merge path is byte-identical to before.
# Single-seat is always coherent, so even ON it is inert for a solo operator. The mechanism lives in
# scripts/herd/engine-seat.sh (which also carries the P4 migration-quiesce gate). Defaulted here so the
# watcher sees it under `set -u`.
: "${ENGINE_SEAT_RECONCILE:="off"}"

# ENGINE_IMPL — the ENGINE-CORE IMPLEMENTATION the watcher runs (EPIC HERD-300, the Python port).
# After the P5 CUTOVER (HERD-306) there is exactly ONE engine core: python. The bash action pass was
# DELETED, so the supervisor hands every tick to the Python live engine (pysrc/herd/live_runtime.py)
# with a fault WATCHDOG instead of a bash fallback. The historical values `bash` and `shadow` are
# RETIRED — they WARN loudly (once) and are treated as `python`; there is no bash engine to select and
# no live bash pipeline for a shadow run to parallel (the parity shadow oracle still exists, invoked
# out-of-band by scripts/herd/sim/parity-run.sh). New default: python. Leave it unset — the key exists
# only so a stale `bash`/`shadow` value is caught and warned. Resolved in
# scripts/herd/engine-version.sh (herd_engine_impl); config lint flags a retired value.
: "${ENGINE_IMPL:="python"}"

# ENGINE_PAUSE — the OPERATOR EMERGENCY-OFF switch (HERD-347): off (default) | on. The first-class
# replacement for the pre-P5b `ENGINE_IMPL=bash` no-op pause that config validation now refuses. With
# it on, the watcher's supervisor SKIPS the Python live tick every cycle — zero gate/merge/refix
# dispatch — WITHOUT counting the skipped tick as a fault (the engine-down watchdog is untouched), and
# paints a loud "⏸ engine paused by operator" console banner. Render, reconcile, sweeps and every
# alarm keep running, so the control room stays live; only the action engine is held. Machine-scoped
# so it routes to .herd/config.local, and the watcher reads it FRESH from the config file each tick
# (NOT from this env default — that is why the key carries no requires=watcher restart), so any seat's
# `herd config set ENGINE_PAUSE on|off` takes effect on the shared watcher's very next tick with no
# restart. off is a HARD no-op: byte-identical console + engine behavior to before this key existed.
# The guard lives in scripts/herd/agent-watch.sh (_engine_tick_watchdog / _engine_paused). Defaulted
# here so every path sees it under `set -u`.
: "${ENGINE_PAUSE:="off"}"

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

# Eco-leaning STARTER defaults (HERD-161): Opus is now an ESCALATION tier reached via
# MODEL_ESCALATE_GLOB (feature lane) / REVIEW_ESCALATE_GLOB (review gate), NOT a bare default — so the
# unset-fallbacks below match the manifest, config.example, and the `herd init` seed (feature→sonnet,
# quick→haiku, review→sonnet). The persistent coordinator stays Opus. An explicit MODEL_* in
# .herd/config always wins (':=' can't clobber it), and TOKEN_MODE=eco (above) further lowers the
# support lanes. This finishes the eco-defaults migration that had left this fallback on Opus.
: "${MODEL_COORDINATOR:="claude-opus-4-8"}"
: "${MODEL_FEATURE:="claude-sonnet-4-6"}"
: "${MODEL_QUICK:="claude-haiku-4-5"}"
: "${MODEL_SCRIBE:="claude-sonnet-4-6"}"
: "${MODEL_RESEARCH:="claude-sonnet-4-6"}"
: "${MODEL_REVIEW:="claude-sonnet-4-6"}"
: "${MODEL_RESOLVER:="claude-sonnet-4-6"}"  # conflict resolver — mechanical merge work, not creative

# MODEL_ADVISE — the STRONG advisor model behind `herd advise` (HERD-101): a builder pulls a one-shot
# second opinion on a hard decision from this tier WITHOUT escalating its whole lane. Defaults to
# whatever MODEL_FEATURE resolved to just above (the Opus tier under standard TOKEN_MODE, sonnet under
# eco) — so the advisor tracks the feature tier by default and eco lowers it in lockstep. Set it
# explicitly to pin the advisor to a specific strong model regardless of the feature tier. Assigned
# AFTER MODEL_FEATURE so its default sees the fully-resolved value; ':=' means an explicit key wins.
: "${MODEL_ADVISE:="$MODEL_FEATURE"}"

# MODEL_ESCALATE_GLOB — deterministic model step-up (analogous to HEALTHCHECK_HEAVY_GLOB): when a
# lane's task text matches this egrep -i pattern, the lane forces the MODEL_FEATURE tier regardless
# of MODEL_QUICK or any per-spawn HERD_QUICK_MODEL/HERD_FEATURE_MODEL override. Empty (default) → off,
# zero behavior change. See herd-quick.sh / herd-feature.sh for the resolution point.
: "${MODEL_ESCALATE_GLOB:=""}"

# MODEL_ESCALATE (HERD-376) — the model a matched MODEL_ESCALATE_GLOB forces. EMPTY (default) → the
# glob forces MODEL_FEATURE exactly as before (ship-dormant, byte-identical). Set it to force a
# DIFFERENT model on match instead — the backstop this exists for: MODEL_FEATURE itself now defaults
# to a sonnet tier (HERD-102), so the glob alone no longer guarantees a STRONGER model on judgment-
# heavy surfaces unless the operator names one here. Accepts a bare model id or a runtime-qualified
# '<driver>:<model>' ref (HERD-151), resolved through the same herd_model_for_spawn/_driver_for shim
# as every other MODEL_* key. See herd_model_escalate_target() in driver.sh for the resolution point.
: "${MODEL_ESCALATE:=""}"

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
#   • every path matches DOCS_ONLY_GLOB (opt-in, below)       → DOCS tier ($REVIEW_MODEL_DOCS, cheapest)
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
# ── Docs-only review tier (DOCS_ONLY_GLOB, HERD-89) ──────────────────────────
# A pure-docs diff carries near-zero correctness risk for the adversarial gate, yet under
# REVIEW_ESCALATE_GLOB tiering a docs diff the hardcoded *.md/tests SKIP doesn't cover (e.g. *.txt, or
# a mixed *.md + *.txt diff) still falls through to the CHEAP ($REVIEW_MODEL_CHEAP) tier. Set
# DOCS_ONLY_GLOB (an egrep pattern) to route diffs where EVERY changed path matches it to the cheapest
# reviewer model ($REVIEW_MODEL_DOCS). This activates the tiering on its own — REVIEW_ESCALATE_GLOB
# need not be set. ESCALATION STILL WINS: a docs diff that also matches REVIEW_ESCALATE_GLOB, or that
# exceeds REVIEW_ESCALATE_MAXFILES files, is classified STRONG regardless. Suggested value:
# '\.(md|txt)$' — and pin any docs living under an engine dir (e.g. templates/) into REVIEW_ESCALATE_GLOB
# so those escalate rather than downgrade. SAFE DEFAULT: EMPTY → dormant, behavior byte-identical.
: "${DOCS_ONLY_GLOB:=""}"
# Cheapest reviewer model tier for pure-docs diffs (default: claude-haiku-4-5); ignored when
# DOCS_ONLY_GLOB is blank.
: "${REVIEW_MODEL_DOCS:="claude-haiku-4-5"}"

# ── Review fast path (HERD-559): pre-gate · mechanical floor · latency telemetry ──────────────────
# Once the healthcheck gate is fast, the ~5 minutes of serial LLM review is what binds every PR.
# Three composable levers cut it; all three are implemented ONCE in scripts/herd/review-pregate.sh
# and consumed by the bash review dispatch leg, the live Python engine core, and herd-review.sh.
#
# REVIEW_PREGATE — off (default) | on. off → byte-inert: no lint runs before a review dispatch and
# every (pr,sha) reaches the reviewer exactly as today. on → the cheap DETERMINISTIC lint set
# (caps-sync, the config-manifest ghost/dead-key scan, journal-emission, pipe-safety, git-scope,
# doc-drift — the SAME shared implementations both healthcheck profiles already run, never a new
# rule) runs against the diff FIRST; a red bounces to the builder with the lint output, journals
# review_pregate_red, and burns NO reviewer slot, so the adversarial reviewer only ever sees a
# mechanically-clean diff. BASELINE-SUBTRACTED: a finding also present at the merge base is NOT this
# diff's and never bounces anyone (the merge gate's suite is diff-scoped, so a lint red demonstrably
# CAN sit unnoticed on the default branch). Any inability to compute that baseline SKIPS the pre-gate
# entirely — a false pre-gate red would wedge a PR its builder cannot fix. Consumed by
# agent-watch.sh, herd-review.sh and pysrc/herd/live_runtime.py.
: "${REVIEW_PREGATE:="off"}"
# REVIEW_MECH_FLOOR — off (default) | on. The small-mechanical-diff FLOOR on the review tiering: a
# diff whose every changed file is a TSV row edit, a pure (100%-similarity) rename, or a version bump
# — and which is small and matches no REVIEW_ESCALATE_GLOB path — has no correctness surface for an
# adversarial reviewer, so it routes to $REVIEW_MODEL_CHEAP even when no tiering glob is configured.
# Fails safe in ONE direction: any shape it cannot positively recognize keeps today's tier, and an
# operator's REVIEW_ESCALATE_GLOB match is an absolute veto. off → no classification, byte-inert.
: "${REVIEW_MECH_FLOOR:="off"}"
# Floor ceilings: a diff bigger than either is never "small and mechanical" whatever its shape.
: "${REVIEW_MECH_FLOOR_MAXFILES:="5"}"
: "${REVIEW_MECH_FLOOR_MAXLINES:="40"}"
# REVIEW_TIERING — off (default) | on. Activates the RISK-TIER classification (the
# REVIEW_ESCALATE_GLOB / DOCS_ONLY_GLOB / REVIEW_MECH_FLOOR rules) inside the LIVE Python engine core.
# The bash reference path in agent-watch.sh has always tiered on the globs alone and is unchanged by
# this key; the engine port (HERD-306) never carried the tiering across, so on the live core every PR
# dispatches $MODEL_REVIEW regardless of those globs. This key is the opt-in that turns the ported
# classification on, deliberately ship-dormant: flipping it CHANGES which model reviews a PR (and,
# for a docs/test-only diff, whether a reviewer runs at all), so it is the operator's call, not a
# silent consequence of upgrading. off → the live core's dispatch is byte-identical to today's.
: "${REVIEW_TIERING:="off"}"
# REVIEW_LATENCY — on (default) | off. Journal a review_latency event (dispatch→verdict wall-clock,
# with the tier and model that produced it) as each verdict is collected. Pure TELEMETRY: no gate, no
# dispatch and no merge decision reads it — it exists so the review ceiling this whole fast path
# attacks is MEASURED rather than estimated, which is why it ships ON rather than dormant. off is a
# hard no-op: no event, byte-identical journals.
: "${REVIEW_LATENCY:="on"}"
# The live Python engine core resolves these from os.environ (a CHILD process sees only EXPORTED
# vars — HERD-449), so every one of them must be exported here as well as set.
export REVIEW_PREGATE REVIEW_MECH_FLOOR REVIEW_MECH_FLOOR_MAXFILES REVIEW_MECH_FLOOR_MAXLINES
export REVIEW_TIERING REVIEW_LATENCY
# The tier classification the live core now runs reads the operator's tiering keys directly, so they
# must cross the same process boundary.
export REVIEW_ESCALATE_GLOB REVIEW_ESCALATE_MAXFILES DOCS_ONLY_GLOB
export REVIEW_MODEL_CHEAP REVIEW_MODEL_DOCS

# ── Risk-scoped pre-PR local review (LOCAL_REVIEW=risk-scoped + LOCAL_REVIEW_GLOB, HERD-100) ──────
# LOCAL_REVIEW=pre-pr makes EVERY builder run the cheap local adversarial correctness review before
# it opens its PR. Journal analysis shows round-1 review BLOCKs cluster on the high-churn engine
# files, so a BLANKET pre-PR review wastes quota reviewing low-risk diffs that never block. The
# risk-scoped mode fixes that: LOCAL_REVIEW=risk-scoped runs the local review ONLY when the builder's
# OWN diff surface (git diff DEFAULT_BRANCH...HEAD --name-only) matches this egrep pattern; a diff
# that touches no matching path skips straight to the PR (the watcher's post-PR review gate is
# UNCHANGED and remains the authoritative correctness check, so a skipped low-risk pre-PR review is a
# cost saving, never a safety hole — same fail-open-is-safe rationale as skipping is backstopped
# post-PR). A DEDICATED key (not a reuse of REVIEW_ESCALATE_GLOB) on purpose: the PRE-PR risk surface
# — where builder-side round-1 BLOCKs cluster — is chosen independently of the POST-PR review-tiering
# surface, so operators can scope the two separately; leave it equal to REVIEW_ESCALATE_GLOB if the
# same pattern fits both. Reuses REVIEW_ESCALATE_GLOB / HEALTHCHECK_HEAVY_GLOB egrep semantics.
# SAFE DEFAULT: EMPTY (default) → dormant. Only LOCAL_REVIEW=risk-scoped consults it; with pre-pr or
# none the key is inert. FAIL-SOFT (mirrors the HEALTHCHECK_HEAVY_GLOB hardening): risk-scoped with an
# EMPTY or INVALID glob falls back — LOUDLY — to unconditional pre-pr (review everything), never to a
# silent skip, so a misconfigured glob can only OVER-review, never UNDER-review. Consumed inline by
# herd-quick.sh / herd-feature.sh (the builder prompt is the only surface threaded), same as LOCAL_REVIEW.
: "${LOCAL_REVIEW_GLOB:=""}"

: "${APP_PREVIEW_CMD:=""}"        # empty → no preview pane (quick-only project, e.g. herdkit)
: "${HEALTHCHECK_CMD:=""}"        # project health command; exit 0 clean/data-env, 1 code error
: "${HEALTHCHECK_HEAVY_GLOB:=""}" # diff paths that force the heavy profile (egrep, e.g. '^app/')
: "${APP_SURFACE_GLOB:=""}"       # diff paths that constitute the app surface (egrep, e.g. '^app/'); empty → interaction gate off
: "${INTERACTION_TEST_CMD:=""}"   # command that drives widgets and asserts dependent output changes; exit 0 clean, 1 code error, 2 data/env
: "${SMOKE_CMD:=""}"              # optional resolver smoke gate

# BASELINE_AWARE_GATE — baseline-aware healthcheck gate (HERD-190). on (default) → a heavy code error
# whose failing tests ALL already fail on the base (origin/main) is treated as INHERITED (a tolerated
# ⚠️), not a merge-blocking code error, so a fix-PR never deadlocks on a base failure it did not
# introduce. Only ever DOWNGRADES a red to a tolerated ⚠️; byte-identical when the base is green (an
# empty base known-failure set = every PR failure is introduced) and fully fail-soft (an unresolvable
# or unparseable base blocks exactly as before). off → the classic absolute pass/fail gate, byte-
# identical to pre-HERD-190. Consumed by healthcheck.sh (the watcher passes HERD_BASELINE_DIR=$MAIN).
: "${BASELINE_AWARE_GATE:="on"}"

# ATTRIBUTION_POLICY — commit-attribution lint gate (HERD-121). Ships dormant: default ''
# (empty) → lint absent, byte-identical to before. Set to no-ai-coauthor to scan the PR's
# commits (git log <DEFAULT_BRANCH>..HEAD) for AI co-author markers (Co-Authored-By: Claude*,
# 'Generated with Claude' lines) and fail as a healthcheck code-error naming the offending
# sha+line. The 'Never co-author Claude' rule in AGENTS.md is advisory prose without this;
# with it set the healthcheck enforces it deterministically and cannot be silently violated.
: "${ATTRIBUTION_POLICY:=""}"     # '' (default, off) | no-ai-coauthor

# COMMIT_CONVENTION — commit-message convention lint gate (HERD-124). Ships dormant: default ''
# (empty) → lint absent, byte-identical to before. Set to an egrep pattern that every commit
# subject on <DEFAULT_BRANCH>..HEAD must match; a non-conforming subject fails the healthcheck as a
# code-error naming the offending sha + subject + pattern. Fail-soft: an invalid regex warns and
# skips the lint (never a false red). E.g. Conventional Commits:
#   '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\(.+\))?!?: .+'
: "${COMMIT_CONVENTION:=""}"      # '' (default, off) | egrep pattern every commit subject must match

# WORK_UNIT_KIND — the delivery-vehicle adapter (HERD-398, Phase 3 of docs/spikes/work-unit-
# abstraction.md). On the BASH side this key ships with exactly ONE implemented kind, forever: git-pr
# (default), whose reference-model body lives at scripts/herd/work-units/git-pr.sh behind the
# scripts/herd/work-unit.sh facade — today's exact open/gate/apply/reconcile/teardown pipeline (gh pr
# create/list/view/diff/merge), unchanged. Any other value here is NOT SUPPORTED by bash — the resolver
# in work-unit.sh (wunit_resolve_adapter) REFUSES it, a loud hard failure, not a silent downgrade to
# git-pr — while the watcher itself still only ever runs the git-pr pipeline (nothing branches on this
# key yet), so a typo here can never silently change engine behavior. A second kind, doc-apply, DOES
# exist (HERD-399) but only on the PYTHON engine (herd.work_unit.resolve_adapter) — see spike §9.4 for
# why bash intentionally never grows a second adapter.
: "${WORK_UNIT_KIND:="git-pr"}"
: "${DENY_PATHS:=""}"            # never committed; the scribe/local lane is scoped away from these
: "${REVIEW_CHECKLIST:=""}"     # project risk list injected into the review gate
# RUBRIC_FILE — structured per-unit review rubric (HERD-400, docs/rubric-primitive.md). '' (default,
# off) → byte-identical to today: no rubric block in the reviewer prompt, no rubric_verdicts journal
# event. When set AND the named repo-relative file exists (same worktree-then-main resolution order
# as REVIEW_CHECKLIST), the review gate renders its criteria as an explicit checklist and asks the
# reviewer for one 'RUBRIC: <id> | PASS|FAIL | <reason>' line per criterion ahead of the final
# REVIEW: verdict line — which still alone decides PASS/BLOCK/INFRA-FAIL, unchanged.
: "${RUBRIC_FILE:=""}"

: "${COORDINATOR_CMD:="/coordinator"}"  # the generated coordinator skill the control room runs
: "${HERD_VERSION:="1"}"
: "${HERD_REPO:=""}"            # <owner>/herdkit — where engine bugs escalate (herd report)
# TRACKER_REPO (HERD-534 / GH #651) — the <owner>/<repo> the WORK-TRACKER backend
# (scripts/herd/backends/github.sh) files/lists/updates/closes items in. LEG A of the bug this key
# fixes: the github backend used to inject -R $HERD_REPO on every gh issue verb, so any project with
# HERD_REPO set (report/triage escalation target) had its OWN backlog silently file onto that OTHER
# repo instead of its own — a `backend switch github --migrate` in one project filed 8 work items onto
# the herdkit ENGINE repo (#640-647), and the backlog pane listed that other project's
# engine-escalation issues as local work. TRACKER_REPO is a SEPARATE key the github backend reads
# EXCLUSIVELY for its own repo selection; it NEVER falls back to HERD_REPO (herd report / herd triage /
# oss-triage.sh keep using HERD_REPO alone, unaffected). Default '' (unset) → the backend passes no -R
# flag at all, so `gh` resolves the repo itself from the CWD's `origin` remote — byte-identical to a
# project whose origin IS its own tracker. Set only when the tracker repo differs from origin (a
# tracker-only repo separate from the code repo).
: "${TRACKER_REPO:=""}"
: "${WATCHER_AUTOMERGE:="true"}"  # legacy lever; MERGE_POLICY takes precedence when set
: "${MERGE_POLICY:=""}"           # auto | approve | observe (empty → derive from WATCHER_AUTOMERGE)
: "${HUMAN_VERIFY_POLICY:="hold"}"  # HERD-59: how a PR's HUMAN-VERIFY: block is handled under MERGE_POLICY=auto — hold (default, today's exact per-PR hold) | coordinator (loud, coordinator-actionable hold) | auto (informational: journal + comment the steps, merge on green). Unknown → hold. Consumed by agent-watch.sh + herd-approve.sh
# PUSH_GATE (HERD-123) — hold a FINISHED builder for human review BEFORE anything reaches GitHub. The
# missing gate-then-upload seam: PR_FLOW=draft gates AFTER the push (PR already public), MERGE_POLICY=
# approve gates AFTER review (PR exists); PUSH_GATE=human gates BEFORE the push, while the diff is only
# local. With =human, the builder lane completes work + healthcheck but STOPS before git push / gh pr
# create, recording a sha-keyed awaiting-push hold (push-gate.sh) the watcher surfaces as 'ready ·
# awaiting push approval'; herd-approve.sh approve resumes push + PR creation. A new commit invalidates
# a prior approval (sha-keyed, same semantics as merge approval). Default '' (off) → lanes byte-
# identical, byte-inert. Unknown value → off (fail safe). Consumed by herd-quick.sh / herd-feature.sh
# (lane rules), herd-approve.sh (list/approve/resume), agent-watch.sh (console row), via push-gate.sh.
: "${PUSH_GATE:=""}"              # '' (default, off) | human
: "${MERGE_METHOD:="merge"}"      # merge | squash | rebase — the gh pr merge strategy
: "${REVIEW_CONCURRENCY:="2"}"    # max pre-merge reviews the watcher runs in parallel
# NATIVE_BURST (HERD-107) — off (default) | on. The master switch for the bounded read-only FAN-OUT
# seam (scripts/herd/burst.sh). OFF → today's EXACT serial behavior, byte-identical: the research
# drainer's Explore fan-out is un-hinted and the review runs as a single reviewer. ON → read-only work
# (repo research, the review PANEL) may BURST — fan out several CONCURRENT calls bounded by
# REVIEW_CONCURRENCY (the ceiling) — while WRITE lanes (scribe/backlog/merge) stay strictly serial.
# Purely additive + config-gated; unknown/blank → off (fail safe). Consumed by research.sh + herd-review.sh.
: "${NATIVE_BURST:="off"}"       # off (default) | on — see capabilities.tsv / burst.sh
# REVIEW_PANEL (HERD-107) — how many CONCURRENT read-only reviewer passes the pre-merge review runs
# over the SAME diff when NATIVE_BURST=on (a bounded "review panel": more eyes catch more bugs). The
# effective panel size is min(REVIEW_PANEL, REVIEW_CONCURRENCY). Default 1 → a single reviewer, i.e.
# today's byte-identical behavior (the panel only engages at >1 AND with NATIVE_BURST=on). Combination
# is fail-safe: ANY member's BLOCK blocks the merge; a merge needs at least one PASS and zero BLOCKs.
: "${REVIEW_PANEL:="1"}"         # concurrent reviewer passes when NATIVE_BURST=on (default 1 = single reviewer)
# REVIEW_PANEL_MODELS (HERD-276) — the MIXED-VENDOR review panel. A space-separated list of model refs,
# each optionally runtime-qualified as '<driver>:<model>' (HERD-151); ONE PANELIST PER REF, each
# dispatched through its OWN runtime. Unset (default) → dormant: the panel stays single-model on
# $REVIEW_MODEL and behavior is byte-identical. Set → the panel size is the REF COUNT (it no longer
# reads REVIEW_PANEL) and it engages even at one ref; NATIVE_BURST only decides whether the panelists
# run CONCURRENTLY (bounded by REVIEW_CONCURRENCY) or serially. A panelist whose driver binary is
# absent at dispatch reports INFRA, never a false BLOCK. `herd config set` validates every ref eagerly.
: "${REVIEW_PANEL_MODELS:=""}"   # e.g. "opus codex:gpt-5 grok:grok-4" — unset = single-model panel
# REVIEW_PANEL_POLICY (HERD-276) — how the panel's per-panelist verdicts fold into ONE gate verdict.
# any-block (default, today's fail-safe: any BLOCK blocks) | all-pass (every dispatched panelist must
# PASS; a silent panelist is a coverage gap → INFRA, not a pass) | majority (blocks >= passes → BLOCK,
# so a lone dissenting vendor no longer blocks; ties fail safe toward BLOCK). Resolved in exactly one
# place (scripts/herd/review-panel.sh) so every enforcement surface folds identically. An unrecognized
# value is a typo and fails STRICT to any-block — never to the laxest policy.
: "${REVIEW_PANEL_POLICY:="any-block"}"  # any-block (default) | all-pass | majority
# SPAWN_AHEAD — advisory spawn-rate lead over the review gate (herd-spawn-gate.sh, sourced by the
# lanes). When the review pipeline is saturated (live+queued reviews ≥ REVIEW_CONCURRENCY), a lane
# HOLDS a new spawn once in-flight builders already exceed REVIEW_CONCURRENCY + SPAWN_AHEAD — so the
# coordinator never builds faster than the gate can review, burning builder-session tokens on PRs
# that just sit in REVIEW_QUEUED. Default 1 keeps ONE build ahead of the gate so the pipeline stays
# fed; 0 → strict no-surplus. Advisory only: --force / HERD_FORCE_SPAWN=1 bypasses it. Non-numeric → 1.
: "${SPAWN_AHEAD:="1"}"
: "${HEALTH_CONCURRENCY:="1"}"   # max healthcheck suites the watcher runs at once (default 1: serialize — all feature worktrees share one git object store, so overlapping suites race on shared .git locks and paint false-red)
# LOCAL_SUITE_CONCURRENCY (HERD-529) — max HEAVY healthcheck suites this BOX runs at once, across ALL
# worktrees and ALL callers (builder-local `scripts/herd/healthcheck.sh --heavy` runs AND the
# watcher's own dispatch) — a distinct, wider ceiling than HEALTH_CONCURRENCY, which only serializes
# the watcher's OWN dispatch loop and has no visibility into a builder running the heavy suite locally
# ahead of its own PR. GROUNDED 2026-08-05: an 8-builder fleet ran up to 8 simultaneous builder-local
# heavy suites (box saturation, a tolerated-as-DATA/ENV 1800s bats timeout that actually meant the
# suite asserted nothing that run). Enforced in scripts/herd/healthcheck.sh's run_heavy() via a
# cross-worktree slot pool under $WORKTREES_DIR, namespaced `.local-suite-slot-*` (distinct from the
# watcher's own `.health-inflight-*` markers, so the two accounting systems never collide). Default 2.
# Non-numeric → 2 (resolved via herd_numeric, warns once, fails toward the safe default).
: "${LOCAL_SUITE_CONCURRENCY:="2"}"
# GATE_SCALE (HERD-542) — auto-scale REVIEW_CONCURRENCY / HEALTH_CONCURRENCY with the LIVE fleet
# size so an operator never hand-tunes concurrency as builders come and go: off (default, ship-
# dormant) | on (yolo posture adopts on — templates/postures.tsv). off → _review_conc / _health_conc
# (agent-watch.sh) resolve exactly the configured values, byte-identical to before this key existed —
# no derivation, no journal line, no console row, and herd_engine_live_tick (engine-version.sh) passes
# the Python engine core those SAME unscaled values it always has. on → each watcher tick derives an
# EFFECTIVE cap per gate: clamp(configured_floor, ceil(live_builder_count / 2), cores_ceiling), where
# configured_floor is the value this key would resolve to with GATE_SCALE off (an explicit operator
# value is a FLOOR scaling never lowers), live_builder_count reuses the EXACT source
# herd-spawn-gate.sh's own spawn advisory reads (_sg_count_inflight_builders — git worktrees under
# WORKTREES_DIR), and cores_ceiling is the box's logical core count (nproc / sysctl -n hw.ncpu;
# unreadable → a built-in fallback of 4). This is not console-only: herd_engine_live_tick passes the
# derived values as an explicit env override for that one Python tick, so GATE_SCALE actually moves
# the LIVE gate, not just its display. FAIL-SOFT throughout: an unreadable builder/core count falls
# back toward the configured floor, never a fabricated ceiling. Unknown value → off (fail safe).
# Consumed by agent-watch.sh / engine-version.sh.
: "${GATE_SCALE:="off"}"           # off (default) | on — see capabilities.tsv / agent-watch.sh
# CAPACITY_BUDGET (HERD-557 P1) — evolve the HERD-529 LOCAL_SUITE_CONCURRENCY slot pool into a
# PRIORITY-AWARE ledger (scripts/herd/capacity-ledger.sh — the design doc is
# docs/spikes/capacity-admission.md): off (default, ship-dormant) | on (yolo posture adopts on —
# templates/postures.tsv). off -> scripts/herd/healthcheck.sh's run_heavy() calls the ORIGINAL,
# UNTOUCHED `_lss_acquire` flat-cap machinery — byte-identical to before this key existed. on -> the
# SAME LOCAL_SUITE_CONCURRENCY unit count is instead admitted through a reserved-slice partition (a
# watcher-only unit and a builder-local-only unit so neither class can starve the other by possession —
# see the design doc for why time-based aging was rejected in favor of this) plus a RETRY-SOLO drain
# barrier for the flaky-retry re-run (holds the whole ledger alone, or gives up as env-suspect within
# its window) and an overload breaker (loadavg far past cores freezes admission regardless of ledger
# room). The acquire itself is a real, atomic, non-blocking flock (scripts/herd/capacity_flock_run.py,
# portable macOS/Linux) tied to the holding process's own fd — a crashed/killed holder's unit is
# released BY THE KERNEL, not by any reconciler this engine has to run. FAIL-SOFT: no worktree pool, no
# python3, or this key simply off — all fall back to the same untouched flat-cap path. Unknown value ->
# off (fail safe). Consumed by healthcheck.sh / capacity-ledger.sh.
: "${CAPACITY_BUDGET:="off"}"      # off (default) | on — see capabilities.tsv / capacity-ledger.sh
# RESTART-SAFE INFLIGHT TIMEOUTS (HERD-185) — an in-flight review/health worker that outlives this many
# seconds (age read from its on-disk dispatch marker, so ANY watcher instance — even one that restarted
# mid-run — can enforce it) is SIGTERMed + reaped by the every-tick corpse sweep, freeing its slot. Well
# above any legitimate run so a healthy worker is never killed. Non-numeric → the built-in 1800 default.
: "${REVIEW_INFLIGHT_TIMEOUT:="1800"}"   # HERD-185: seconds before an in-flight reviewer is timed out + reaped (default 1800 = 30m)
: "${HEALTH_INFLIGHT_TIMEOUT:="1800"}"   # HERD-185: seconds before an in-flight healthcheck suite is timed out + reaped (default 1800 = 30m)
# HEALTH_TIMEOUT_HEADROOM (HERD-281) — headroom margin in seconds between the observed max suite
# duration and HEALTH_INFLIGHT_TIMEOUT. When > 0 and a live suite enters the window
# [HEALTH_INFLIGHT_TIMEOUT - HEALTH_TIMEOUT_HEADROOM, HEALTH_INFLIGHT_TIMEOUT + HEALTH_TIMEOUT_HEADROOM),
# the corpse sweep (a) surfaces a loud console + journal advisory to raise HEALTH_INFLIGHT_TIMEOUT, and
# (b) does NOT tear down the dispatch within that window — giving the suite the full margin to complete.
# SHIP-DORMANT: 0 (default) → corpse sweep is byte-identical (kills at HEALTH_INFLIGHT_TIMEOUT exactly);
# the advisory and deferred-kill paths are unreachable. Non-numeric → 0 (never activate on a typo).
# Set to ~20% of HEALTH_INFLIGHT_TIMEOUT as a starting point (e.g. 360 for the default 1800s timeout).
: "${HEALTH_TIMEOUT_HEADROOM:="0"}"   # HERD-281: advisory + deferred-kill margin (seconds); 0 = off
# HEALTH_EARLY_REAP_SECS (HERD-494) — an in-flight health suite whose tailable log is STILL 0 bytes
# after this many seconds AND has no live bats/suite descendant left in its process group is
# dead-at-spawn or wedged BEFORE ever producing output — waiting out the full HEALTH_INFLIGHT_TIMEOUT
# (many minutes) on a run that will never produce a verdict just stalls the gate. When > 0, the
# every-tick corpse sweep reaps such a worker immediately (same group-kill seam the timeout branch
# uses) and journals health_early_reap, instead of waiting for HEALTH_INFLIGHT_TIMEOUT. A suite that
# has written ANY bytes, or still has a live descendant, is NEVER touched by this — only a truly
# silent, childless worker qualifies, so a legitimately slow-to-start suite is never falsely reaped.
# SHIP-DORMANT: 0 (default) → corpse sweep is byte-identical to before (kills at
# HEALTH_INFLIGHT_TIMEOUT exactly); the early-reap path is unreachable. Non-numeric → 0 (never
# activate on a typo). Consumed by agent-watch.sh.
: "${HEALTH_EARLY_REAP_SECS:="0"}"   # HERD-494: early-reap a dead-at-spawn/wedged worker (seconds); 0 = off
# HEALTH_TRUST_BUILDER (HERD-531) — SHA-MATCHED TRUST of a builder's own pre-PR heavy suite: on | off
# (default off, ship-dormant). The health gate is the pipeline's dominant cost (~350 hermetic tests,
# 20-60 min per suite), and a builder that runs the heavy profile before opening its PR makes the
# watcher pay for the IDENTICAL suite on the IDENTICAL commit a second time. on → the shared
# healthcheck entry writes an engine-authored PROVENANCE record (sha, worktree, profile, outcome,
# duration) into the shared worktree pool, and the watcher's health dispatch, when a candidate's EXACT
# head sha has a CLEAN heavy record from a CLEAN tree at that same worktree, runs the LIGHT profile as
# a smoke instead of the full re-run and journals health_trusted provenance=builder-local. EVERY other
# case — no record, stale sha, non-clean outcome, dirty tree, a record older than the commit, or a
# record the watcher itself wrote — is a FULL re-run exactly as today (fail-closed). off (default) →
# byte-identical: no record is written and none is read. An unrecognized value reads as off (a typo can
# never arm a path that skips the authoritative suite). The WRITE side is scripts/herd/health-trust.sh
# (sourced by healthcheck.sh, bash-only). HERD-555: the READ side lives in the Python engine core's
# health dispatch (pysrc/herd/live_runtime.py, LiveGates.health) — the old bash reader
# (agent-watch.sh:_healthcheck_gate) was dead code since the P5b port, its only caller never wired
# into the live pipeline. A Python-core knob means this key is now in _HERD_ENGINE_CORE_KEYS below and
# must stay `export`ed (HERD-449/465) — see env-export-lint.sh.
: "${HEALTH_TRUST_BUILDER:="off"}"   # HERD-531/555: trust a sha-matched builder-local heavy run — on | off
# HEALTH_SOURCE (HERD-578) — WHERE the PR health verdict COMES FROM: local | ci (default local,
# ship-dormant). local → unchanged: the watcher dispatches the local healthcheck suite per (pr, sha),
# serialized behind HEALTH_CONCURRENCY, and that run is the verdict. ci → the watcher stops dispatching
# local PR suites entirely and READS the PR's own GitHub Actions conclusion for its exact head sha as
# the verdict instead (the same suite, already run in parallel by CI, at no local slot cost): a green
# checks-run maps to CLEAN, a red naming a real test maps to CODEERROR carrying that test as the
# bounce evidence, and pending or cancelled maps to WAIT — never a red. TWO HARD RULES, both from live
# incidents: (1) HERD-609 — a failure whose failed jobs carry PLATFORM-INFRA signatures (Failed to
# resolve action download info / Service Unavailable / job not acquired by runner / concurrency
# cancel) and name no test classifies WAIT-infra-transient with ONE bounded, journaled
# `gh run rerun --failed` per run id, NEVER CODEERROR (grounded: the 2026-08-06 Actions outage held
# main red overnight); (2) HERD-612 — the verdict is a per-tick RECONCILED READ of live CI state, never
# a dispatched worker chain that can die holding it (grounded 2026-08-07/10: a dead collector chain
# stranded a MAIN RED for three days). FAIL-SOFT, NEVER SILENT: an unreachable/unauthenticated gh, or a
# branch with no Actions runs at all, falls back to the local suite and journals `ci_health_fallback`
# saying so. HEALTHCHECK_AUTOFIX bounces a CI red on the SAME kind=health rail (same once-guard, same
# REFIX_MAX_ROUNDS budget) a local red uses — one rail, not two. Builder-local scoped runs stay an
# opt-in dev tool via healthcheck.sh, unchanged. An unrecognized value reads as local (fail toward the
# authoritative local suite). Consumed by pysrc/herd/live_runtime.py (LiveGates.health) — a Python-core
# knob, so this key is in _HERD_ENGINE_CORE_KEYS below and must stay `export`ed (HERD-449/465).
: "${HEALTH_SOURCE:="local"}"        # HERD-578: where the PR health verdict comes from — local | ci
# CORE_SURFACE_GLOB (HERD-577) — the LOAD-BEARING CORE: an egrep of changed diff paths (repo-root
# relative) whose diffs must carry a GREEN sandbox-sim scorecard before they may merge, and which
# merge ONE AT A TIME. EMPTY (the default) = feature OFF, byte-identical: no diff is read, no sim is
# dispatched, no marker is written and no core_surface_* event is journaled. GROUNDING (the
# blast-radius insight): every compound failure this engine has had lives in ~6 load-bearing files —
# the gate loop / dispatch / verdict-cache regions of scripts/herd/agent-watch.sh, the decide + health
# paths of pysrc/herd/live_runtime.py, pysrc/herd/ci_verdict.py, scripts/herd/healthcheck.sh,
# .herd/healthcheck.project.sh and scripts/herd/herd-review.sh's dispatch — while 40+ other merges
# flow through the same gate harmlessly, so a uniform gate spends the same proof budget on a TSV row
# edit and on a rewrite of the merge decision. ARMED (a non-empty egrep) → TWO things, both scoped to
# matching diffs only: (1) a THIRD gate leg in the decide path requires a green scorecard from the
# sandbox-sim scenario(s) that cover the touched seam (gate / concurrency / limit / panes —
# scripts/herd/sim/sandbox-*.sh, mapped by scripts/herd/core-surface.sh). It is its OWN leg, sequenced
# after the health verdict rather than riding the local suite dispatch, so it composes IDENTICALLY
# with HEALTH_SOURCE=local and HEALTH_SOURCE=ci (under ci no local suite is dispatched at all, and a
# requirement bolted onto that dispatch would silently vanish). A red scorecard bounces on its own
# `coresim` refix rail (same REFIX_MAX_ROUNDS budget shape, never sharing the health rail's). (2) core
# diffs SERIALIZE: among core-matching candidates that would merge, only the deterministic front
# (lowest PR number — the same total order MERGE_QUEUE uses, so the two never disagree) lands per
# window; the rest HOLD with a visible calm console row naming what they wait on. Non-core diffs are
# never consulted and never held. FAIL-SOFT, NEVER SILENT: an absent scenario script SKIPS with a
# loud journaled note and a SKIP (never a PASS) verdict; STRICT the other way — a diff whose paths
# cannot be read at all is gated AS core (the sims are hermetic and cheap, so being wrong that way
# costs one ~30s run). Same egrep semantics as HEALTHCHECK_HEAVY_GLOB / REVIEW_ESCALATE_GLOB.
# Consumed by pysrc/herd/live_runtime.py (LiveGates.core_surface / LiveTick._core_prepass) and
# scripts/herd/core-surface.sh — a Python-core knob, so this key is in _HERD_ENGINE_CORE_KEYS above
# and must stay `export`ed (HERD-449/465).
: "${CORE_SURFACE_GLOB:=""}"         # HERD-577: '' (default, feature off) | egrep of the load-bearing core paths
# HEALTH_SUITE_SCOPE (HERD-532) — DIFF-SCOPED test selection for the heavy suite: diff | full (default
# full, ship-dormant). full → the healthcheck wrapper runs the whole curated set, byte-identical to
# before. diff → it maps the worktree's changed paths to the tests that can actually cover them, via
# the gate-coverage pairing convention (tests/test-<name>.sh ↔ scripts/herd/<name>.sh), an optional
# per-test `# suite-deps:` header, and an always-run core of cross-cutting manifest/lint/hermeticity
# proofs. FAIL-CLOSED: any changed path that is unmappable or wide-blast (bin/herd, herd-config.sh,
# agent-watch.sh, either healthcheck wrapper, templates/capabilities.tsv, the selection library, the
# bats discovery surface) selects the FULL curated set — an unprovable diff runs everything, never
# nothing. An unrecognized value reads as full. Consumed by suite-shard.sh (herd_suite_scope_mode),
# read by the project healthcheck wrapper.
: "${HEALTH_SUITE_SCOPE:="full"}"    # HERD-532: heavy-suite test selection — diff | full
# INTENT_QUEUE (HERD-630, Phase 1 of HERD-625; design doc docs/spikes/coordinator-work-queue.md) — the
# durable spawn queue's INTENT POLICY: off (default, ship-dormant) | on. GROUNDING (the doc's §1.1,
# read back from the 2026-08-10 journal): the spawn queue already externalizes spawn EXECUTION but not
# spawn SELECTION, so a slot freed while the coordinator is between turns is repaired by nobody —
# 4 h 36 m of idle review slot inside a 7 h 45 m drain, bimodally ~30-60 s when a turn happened to be
# live and 24-144 min when one was not. The latency is seat presence, not engine throughput.
#
# off → `spawn-step.sh next` serves intents by the untouched `ls -1 <q>/*.req | sort` FIFO, no .prio
#   sidecar is ever read, no re-ground read is issued, no intent can expire and no escalation ledger is
#   ever written — byte-for-byte the pre-HERD-630 drain, including its argv, its journal lines and its
#   queue file layout (tests/test-spawn-queue-drain.sh passes unmodified as the proof).
# on → FOUR behaviors engage, all of them over the SAME queue directory and the same claim primitives:
#   (1) PRIORITY ORDER — an intent's optional .prio sidecar (spawn.sh's HERD_SPAWN_PRIO) names a band;
#       lowest drains first, FIFO by INTENT_ID within a band (the HERD-443 invariant). An intent with
#       no sidecar lands in the default band, so a queue where nobody published a priority is STILL
#       today's FIFO — arming the lever alone re-orders nothing.
#   (2) DRAIN-TIME RE-GROUNDING (§4.2) — an intent authored hours ago is re-checked against the item's
#       CURRENT tracker state before it launches. A Done/Canceled item is a TERMINAL SKIP-AND-CONTINUE:
#       journal `spawn_skipped reason=re-ground`, drop that candidate, move to the next in priority
#       order — no worktree, branch or agent is created. Fail-soft: an unreadable state launches as
#       today (tracker flakiness must never stall the queue).
#   (3) INTENT_TTL AGING (§4.3) — an intent that sat undrained past the TTL does NOT launch; it
#       escalates to a terminal state with a LOUD needs-you row. Launching a builder against a
#       day-stale plan costs a full run plus a bounced PR, and fails silently.
#   (4) The `cancel` op (§4.4 level 1) — `spawn-step.sh cancel <intent-id>` countermands a still-
#       unclaimed intent atomically, racing the drain's own claim safely.
# Every escalated row ships WITH its clearing path in the same slice — `herd intents ack <n|all>` plus
# an automatic age-to-retired sweep — because HERD-613 leg 3 proved an escalation surface with no
# clearing surface is a permanent-red generator, not a safety feature.
#
# NOT MULTI-SEAT SAFE, and deliberately not described as such: each watcher still computes its spawn
# budget from its OWN FEATS roster, so two seats draining one pool can each admit up to their own cap.
# Phase 4 closes that by leasing through the HERD-581 `agent` capacity tenant. A single-seat drain
# behaves exactly as today. An unrecognized value reads as off (fail toward the byte-identical FIFO).
# Consumed by scripts/herd/spawn-step.sh (ordering + terminal ops) and agent-watch.sh
# (_drain_spawn_queue's re-ground / TTL legs, and the escalation console section).
: "${INTENT_QUEUE:="off"}"           # HERD-630: durable spawn-queue intent policy — off (FIFO) | on
# (HERD-580) GATE_DISPATCH (HERD-73) was RETIRED: it governed WHEN the watcher's action pass fired the
# pre-merge review relative to the healthcheck, but its only consumers lived in the bash action pass
# (_tick_act) the P5b engine port deleted — the Python core never implemented a parallel pre-dispatch
# step (pysrc/herd/live_runtime.py's INFRA breaker docstring has the full audit). Removed rather than
# ported: with no reachable caller left in either engine, keeping the key would document a lever that
# does nothing.
# DELTA_REVIEW (HERD-204) — off (default) | on. Skip a full pre-merge re-review when a PR's NEW head
# sha differs from its last review-PASSED sha ONLY by a merge of DEFAULT_BRANCH (a pure INTEGRATION
# push: the newly-merged main commits are already-reviewed main, and the merge itself carries no
# authored conflict-resolution content). on → before dispatching a full review for a new sha, the
# watcher tries to PROVE the delta is integration-only (new sha is a 2-parent merge whose branch-side
# parent IS the last-passed sha, whose other parent is already contained in DEFAULT_BRANCH, and whose
# tree equals a clean 3-way auto-merge of those parents with zero manual edits); if proven, it CARRIES
# FORWARD the prior PASS onto the new sha (records a sha-keyed PASS with source=carried-forward and
# journals review_carried_forward) instead of re-reviewing. CONSERVATIVE + FAIL-CLOSED: any authored
# change beyond the merge, a non-trivial/conflicted merge, a missing sha/worktree, or any inability to
# prove integration-only → a normal full review. off (default) → byte-inert: no probe, no carry, the
# review-once gate is unchanged. Unknown value → off (fail safe). Consumed by pysrc/herd/live_runtime.py
# (the shipped live review dispatch, HERD-580 port); the bash body (agent-watch.sh) is unreachable since
# the P5b engine port and is kept only for its own unit test.
: "${DELTA_REVIEW:="off"}"       # off (default) | on — see capabilities.tsv / pysrc/herd/live_runtime.py
: "${REVIEW_AUTOFIX:="false"}"   # auto-bounce BLOCK reviews to the builder agent (default off; set true to dogfood)
: "${REFIX_MAX_ROUNDS:="3"}"     # max auto-refix rounds per RAIL (review | health | stale); a rail's budget is refunded when its red resolves, and a derived per-PR ceiling of 3x bounds the whole PR; exhausting either escalates to needs-you
: "${REFIX_COMPLETE_MIN:="10"}"  # HERD-420: minutes after a refix wake (refix_wake_result woke=1) before the watcher checks the SAME (pr,sha) actually SHIPPED — a woke=1 only proves the agent's pane came back to "working", not that it committed+pushed (PR #531: bounced, edited a file, declared done, never pushed; the PR sat blocked indefinitely with nobody watching). Past this window, if the agent reads done/idle again with no new sha on the PR, the watcher journals refix_incomplete and re-bounces ONCE through the SAME rail's REFIX_MAX_ROUNDS budget (no parallel path) with a "finish your uncommitted work" prompt; budget exhaustion escalates to the standard needs-you row. Default 10 (ships ON — this closes a proven silent-failure class); 0 is a real opt-out (byte-identical to pre-HERD-420: the once-guard just holds silently). Consumed by pysrc/herd/live_runtime.py (review + health rails; the only rails whose bounce dispatch is live post-P5-cutover)
: "${HEALTHCHECK_AUTOFIX:="false"}"  # HERD-173: auto-bounce a reproduced healthcheck CODE ERROR to the builder agent, on the same rails as REVIEW_AUTOFIX — true | false (default false). true → the watcher delivers the failing test + the tailable suite log to the builder's agent pane, once per (pr,sha), spending the HEALTH rail's own round budget (REFIX_MAX_ROUNDS per rail, refunded when the suite next goes CLEAN; a per-PR 3x total ceiling still bounds the PR); the same limit-parked / dead-agent preflights apply, and the cap escalates to a needs-you row. A tab-leak-guard trip is infra, never bounced. false (default) → no bounce, no ledger write, no re-task prompt: the gate decision is unchanged and the red row still holds the PR. Consumed by agent-watch.sh
: "${CODEMAP_AUTOREFRESH:="true"}"  # after a PR merges, the watcher regenerates docs/codemap.md and commits it direct to the default branch (deterministic, LLM-free); off → the watcher never touches the codemap
: "${MAIN_HEALTH_TICK:="off"}"   # HERD-129 / HERD-222: main-health as a RECONCILED INVARIANT — every observed default-branch sha ends with a collected health verdict, whoever merged it. on → each tick the watcher runs the healthcheck against the current default-branch HEAD when that sha has no verdict yet (this seat's merge, ANOTHER seat's merge, a gh-UI merge, a deferred no-slot tick, a worker killed mid-suite); a reproduced red raises a loud persistent 'MAIN RED' alarm row + notification, cleared when a later sha goes green. Catches the failure the per-PR gate structurally cannot: two independently-green PRs merging into a broken combination. ALARM only — never gates/reverts/re-merges. off (default) → byte-inert: no suite, no journal, no row
: "${MAIN_HEALTH_RECHECK_MINS:="0"}"  # HERD-222: while MAIN_HEALTH_TICK holds main RED, RE-VERIFY the CURRENT sha every N minutes so a stale red self-heals through the ordinary green→clear path instead of shouting until the next merge (a real red once stood 19h). 0 (default, off) → byte-identical: a sha with a verdict is never re-run. N>0 → at most one re-verify per N minutes, subject to the same HEALTH_CONCURRENCY slot and per-sha dispatch guards; a non-numeric value reads as 0 (a typo can never arm it). Consumed by agent-watch.sh
: "${MAIN_HEALTH_RECHECK_ONESHOT:="off"}"  # HERD-612 leg 5: guarantee a standing MAIN RED always has at least ONE armed clearing trigger — on | off (default off, ship-dormant). GROUNDED 2026-08-10: with MAIN_HEALTH_RECHECK_MINS at its default 0, a red pinned to a sha that already carries a run-once verdict marker, on a QUIESCENT main (no newer sha whose green could supersede it), has literally no path left by which the engine could ever ask again — the Aug-6 outage red stood for hours with branch CI green at head the whole time. on (REQUIRES MAIN_HEALTH_TICK=on) → whenever a LOCAL-suite identity stands red and no cadence is armed, the watcher fires EXACTLY ONE re-verify of the CURRENT main sha (the same sha MAIN_HEALTH_RECHECK_MINS would re-verify — the two differ in CADENCE only), once per sha (a shared $TREES marker, so a restart loop cannot re-spend it) and only on a REAL dispatch (a busy HEALTH_CONCURRENCY slot defers rather than consuming the one-shot); the verdict then clears or re-confirms the red through the ordinary green→clear path. Scoped to the LOCAL identity: a CI-scoped red always has the MAIN_HEALTH_CI_GATE leg itself as a trigger, and a local green cannot clear a CI identity anyway (HERD-372). Prefer MAIN_HEALTH_RECHECK_MINS when you want a repeating cadence; this is the floor beneath it, not a replacement. off (default) → byte-identical: no marker, no dispatch, no journal line. Consumed by agent-watch.sh
: "${MAIN_HEALTH_AUTOFIX:="off"}"  # HERD-222/HERD-476: auto-REMEDIATE a reproduced MAIN RED — on | off (default off, ship-dormant) | spawn. on/spawn → when the main-health suite reproduces a red whose failing-test identity is HONEST (a TAP 'not ok' line, or a concrete test/source file — never healthcheck.sh's content-free '❌ CODE ERROR' banner), the watcher enqueues ONE scribe item citing that test and journals `main_health_autofix result=enqueued`, at most once per distinct failure while main is red. A kind=ci red re-derives its identity from the failing run's own `gh run view --log-failed` output first (HERD-476), so a bare 'CI <workflow>: <conclusion>' never blocks it; an unreadable log skips with reason=ci-log-unreadable instead. spawn additionally dispatches ONE tracked+claimed quick-lane builder (via spawn.sh) against that same identity — RISK: the one path here that writes code unattended, though the ordinary healthcheck+review gate still stands before any merge. on stays file-only: no spawn, no revert, no branch touch. off (default) → byte-identical: no scribe item, no journal line, no spawn. Consumed by agent-watch.sh
: "${MAIN_HEALTH_CI_GATE:="off"}"  # HERD-434: make the DEFAULT BRANCH's own GitHub Actions CI conclusion an input to the MAIN RED alarm — on | off (default off, ship-dormant). MAIN_HEALTH_TICK's local re-suite runs on the WATCHER'S OWN host, so it can be green while CI (a differently-provisioned runner) is red on the identical sha — GROUNDED 2026-07-28: main merged 5 PRs while GitHub Actions CI stayed red on every one and MAIN_HEALTH_TICK reported green throughout, because nothing ever asked GitHub. on (REQUIRES MAIN_HEALTH_TICK=on — reuses its state file, console row and notify-once path) → each tick (throttled, ~every 10 ticks) probes `gh run list` for the default branch's latest COMPLETED run against the current main HEAD; a FAILURE conclusion raises the SAME 'MAIN RED' row/alarm the local suite does (merging its own CI identity field, never clobbering a standing local-suite identity), a later PASS clears it. FAIL-SOFT throughout: offline/unauthenticated gh, no matching run yet, or a run still IN PROGRESS all read as "nothing to report" — NEVER a red row, NEVER a false clear. off (default) → byte-inert: no `gh run list` call, no state, no row. Consumed by agent-watch.sh
: "${RED_LEDGER:="off"}"          # HERD-539: the shared RED-ROW LEDGER — on | off (default off, ship-dormant). on → every red row this file wires (today: MAIN RED, the 'unlinked merges' alarm) records its diagnosing text into a durable keyed ledger (scripts/herd/red-ledger.sh) the moment it is diagnosed or reverified, and the row renders an extra ' · verified Xm ago' suffix read back from that same ledger — so the text on screen is provably the SAME text that was journaled, with an honest freshness clock next to it. A red going green through the ordinary reverify path additionally journals `red_cleared key <k> reason reverified`, once, so a clear is as visible in the journal as the red was. off (default) → byte-inert: no ledger file, no extra journal line, every red row's text BYTE-IDENTICAL to before this key existed. Consumed by agent-watch.sh + work-units/git-pr.sh via red-ledger.sh
: "${RED_ROW_RECHECK_MINS:="0"}"  # HERD-539: extends the MAIN_HEALTH_RECHECK_MINS pattern (HERD-222) past main-health — while RED_LEDGER holds a red for a class this file wires a reverify for (today: the 'unlinked merges' alarm, HERD-522), RE-PROBE it every N minutes so a red whose cause was already fixed out-of-band (a PR body edited after merge to add the `Refs:` line it was missing) self-heals through the ordinary red_cleared path instead of standing forever — REF_UNPARSED_FILE never had a clear mechanism before this. 0 (default, off) → byte-identical: a standing alarm is never re-probed. N>0 → at most one re-probe per N minutes per row (measured from that row's own last-verified stamp in the ledger), REQUIRES RED_LEDGER=on (the ledger is where the cadence clock and the clear both live); a non-numeric value reads as 0. Consumed by agent-watch.sh
: "${RED_AUTOESCALATE:="off"}"    # HERD-547 (HERD-539 leg 4): engine-shaped red auto-escalation — on | off (default off, ship-dormant), REQUIRES RED_LEDGER=on (this reads the SAME diagnosing text red-ledger.sh already caches). on → the moment MAIN RED notes a sha's why-text into the shared ledger, that text is classified against the routing rule templates/coordinator.md.tmpl documents at 'Routing: APP bug vs HERD-ENGINE bug' — a project's own code vs the workflow machinery itself (bin/herd, scripts/herd/**, pysrc/herd/**): an ENGINE-shaped why files automatically via the EXISTING `herd report` path (composes with its own title-dedup rather than reimplementing it), attaching the red-ledger why-text as the issue's diagnosis, and journals `red_escalated`. A shared-pool once-guard (mirrors HERD-371's main-health-fix marker) claims the filing per dedup key across every seat, so a repeat observation of the SAME key no-ops; a project-shaped why is NEVER escalated. Fail-soft throughout: no HERDKIT_HOME/bin/herd, no gh, or `herd report` itself declining (no HERD_REPO, a likely duplicate) all skip WITHOUT filing and journal the reason — never a crash, never a double-file. off (default) → byte-inert: no shellout, no journal line, no filing. Consumed by agent-watch.sh
: "${ENV_SUSPECT_TIMEOUT:="off"}"  # HERD-546 (HERD-539 leg 3), re-hung onto the live path by HERD-567: classify a per-test health-suite TIMEOUT observed while this box is under load as env-suspect, not a bare code red — on | off (default off, ship-dormant). on → when the LIVE health worker's run-1 failure is a per-test TIMEOUT (bats' "# timeout after Ns" TAP suffix, or run-suite.sh's HERD-478 per-test-cap-ledger "(TIMEOUT after Ns)" suffix) AND this box looks contended (loadavg1m >= HEALTH_LOAD_THRESHOLD, or another HERD-529 local-suite slot is live), the SAME tailable log the running row already reads gets a '[env-suspect] env-suspect · timeout under load · solo re-run queued' marker line (_health_inflight_note/_health_env_suspect_marker, agent-watch.sh, render either engine paints) and a health_env_suspect journal event lands once the terminal verdict is collected — the SAME existing retry-before-red solo re-run plays out unchanged either way: a solo pass still clears to FLAKY, a solo fail still reds CODEERROR. off (default) → byte-identical: no marker, no journal event, the running row is unchanged. HERD-449 class: this crosses the watcher(shell)->python->bash-worker subprocess chain (pysrc/herd/live_runtime.py's _HEALTH_WORKER_SH, the shipped path since the P5b port), so it MUST be exported below — a plain shell var here never reaches the worker. Also consumed by agent-watch.sh's own _health_worker (bash-only, unreachable since P5b; kept for its unit test).
: "${HEALTH_LOAD_THRESHOLD:="4"}"  # HERD-546: the loadavg1m reading (whole number) at/above which ENV_SUSPECT_TIMEOUT considers this box "under load" (default 4). Consulted only while ENV_SUSPECT_TIMEOUT=on; a non-numeric value falls back to the default. Same HERD-449 export requirement as ENV_SUSPECT_TIMEOUT above — read by the live worker across the same subprocess chain. Also consumed by agent-watch.sh's own _health_worker (bash-only, unreachable since P5b).
export ENV_SUSPECT_TIMEOUT HEALTH_LOAD_THRESHOLD  # HERD-567: reach the live Python-dispatched health worker (pysrc/herd/live_runtime.py's _HEALTH_WORKER_SH) as a grandchild process — without this export the child sees these levers' built-in defaults no matter what a project configured, the exact HERD-449 bug class scripts/herd/env-export-lint.sh guards for _CORE_ENV_KEYS (these two are read directly off the inherited shell env by the worker's own bash, never through that dict, so they are exported here standalone rather than added to _HERD_ENGINE_CORE_KEYS).
: "${CHECKOUT_GUARD:="off"}"     # HERD-452: shared-checkout CONTAMINATION GUARD — on | off (default off for consumers, ship-dormant; ON in herdkit's own dogfood .herd/config). GROUNDED 2026-07-31: $MAIN was found detached at a PR branch's head (#563), and the main-health suite — which ran the heavy suite directly against $MAIN, unlike the sandboxed baseline-vs-candidate gate (HERD-361) — reproduced a red off the FEATURE branch's own code and painted it 'MAIN RED', training the operator to ignore a standing alarm that named nothing true about the default branch. Two effects, both gated on this key's PART unconditionally except the third: (1) ROOT CAUSE — _main_health_worker (agent-watch.sh) now ALWAYS runs the heavy suite in a DISPOSABLE detached worktree pinned to the dispatched sha (mirroring HERD-361's sandboxed baseline leg), never live inside $MAIN, so nothing the suite does can mutate the shared checkout — this half is unconditional, not lever-gated. (2) THE ALARM MUST NOT LIE — _main_health_dispatch asserts $MAIN is ATTACHED to the default branch (_main_head_attached) with no foreign contamination (_checkout_offenders, HERD-361) BEFORE every dispatch; unsound → the attempt is WITHHELD (no worker runs, no verdict is ever recorded for it) and a `main_health result=contaminated reason=detached|dirty` line is journaled once per signature — also unconditional, since a lying alarm is never acceptable regardless of this lever. (3) AUTO-HEAL, gated on THIS key — on → when reconcile_checkout_cleanliness (HERD-361) finds $MAIN detached AND otherwise CLEAN (no offenders — nothing tracked would be discarded), it runs a plain `git checkout <default-branch>` (never --force, never reset --hard: clean means neither is needed), journals `checkout_guard result=restored`, and clears the standing CHECKOUT UNCLEAN row the same tick. A DIRTY checkout (offenders present, detached or not) is NEVER auto-touched no matter this lever — that evidence stays for a human. off (default) → this part is byte-identical: no checkout, no journal line, the existing HERD-361 advisory row is the only signal. Consumed by agent-watch.sh
: "${AGING_PR_TTL:="3600"}"      # HERD-334: AGING-PR alarm TTL in SECONDS (default 3600 = 60m). An engine-approved PR (herd/gates PASSED) that branch protection keeps blocking on a required CI check is a quiet steady state today — no TTL covers "engine approved it, CI blocks it, nothing is progressing". Past this TTL the watcher render pass paints a loud ADVISORY 'aging · engine-approved but blocked on <check>' row (never a hold) + journals `pr_aging` once per (pr,sha), and journal-audit.sh reports a gates_passed_no_merge finding. 0 DISABLES the alarm (byte-inert on both surfaces, mirrors DEP_STALE_TTL=0); a non-numeric value reads as the default. Consumed by agent-watch.sh + journal-audit.sh via aging-pr.sh
: "${STALE_DUP_DETECT:="on"}"    # HERD-188: pre-merge STALE-DUPLICATE gate — on (default) | off. on → the watcher HOLDS (never auto-merges) a PR whose tracked item ref is already Done via another merged PR, or whose touched files were materially changed on the base branch by a merge the branch predates (a stale base). Provable-only + fail-soft (no ref / offline / bad worktree → no hold), so default-on never false-holds a legit PR. off → byte-inert. Consumed by agent-watch.sh via stale-dup-gate.sh
# HERD-601 GROUNDED: this key was set "on" in production (.herd/config) yet the ported healer
# (HERD-584/PR #716) fired ZERO live stale_base_autofix_bounce events across two real holds (#714,
# #718) — STALE_BASE_AUTOFIX was missing from _CORE_ENV_KEYS/the export sweep below, the exact
# HERD-449 bug class, so pysrc/herd/live_runtime.py's `_stale_base_autofix_enabled` never saw the
# `--tick` child's os.environ value at all and always read off. Now a member of
# _HERD_ENGINE_CORE_KEYS above and the export statement below, closing the gap.
: "${STALE_BASE_AUTOFIX:="off"}" # HERD-199: auto-heal STALE-BASE holds (not DUPLICATE) — on | off (default off, ship-dormant). on → when the stale-dup gate holds a PR for STALE-BASE (touched files moved on DEFAULT_BRANCH), the watcher auto-bounces the live builder with a `git merge $DEFAULT_BRANCH` re-task (or dispatches the conflict resolver when no live builder remains — foreign/reaped/dead), on the same rails as REVIEW_AUTOFIX: sha-keyed once-guard (kind=stale), the stale rail's own REFIX_MAX_ROUNDS budget, honest `rebasing · awaiting push` row; only bounce-exhaustion escalates to needs-you. DUPLICATE flavor stays a human judgment call. off (default) → byte-identical to the pre-HERD-199 hold (🛑 needs-you, no bounce, no ledger). Consumed by agent-watch.sh
: "${CI_AUTOREPAIR:="off"}"      # HERD-250: CI auto-repair for INHERITED reds — on | off (default off, ship-dormant). on → when a PR is MERGEABLE but UNSTABLE with a FAILING required CI check, herd/gates already PASSED for the head sha, AND the branch is BEHIND DEFAULT_BRANCH, the watcher dispatches a base-refresh (merge $DEFAULT_BRANCH into the branch — same mechanical heal as STALE_BASE_AUTOFIX, but keyed on CI-red+behind-base, not touched-file overlap). Sha-keyed once-guard kind=ci, the CI rail's own REFIX_MAX_ROUNDS budget, honest `ci-repair · awaiting push` row; bounce-exhaustion escalates to needs-you. NEVER silently merges a red PR — a REAL new-code CI failure (failing CI on an up-to-date branch, or without a gates blessing) stays needs-you. off (default) → byte-identical to the pre-HERD-250 UNSTABLE-fail path. Consumed by agent-watch.sh via ci-repair.sh
: "${CI_FAST_BOUNCE:="off"}"     # HERD-495: fast-bounce on the PR's OWN CI failure conclusion, ahead of the local suite — on | off (default off, ship-dormant; yolo posture adopts on). on → when a PR's CI concludes FAILURE naming a real test (the SAME honest-identity log extraction HERD-476/#600 built, `gh run view --log-failed` read for "✗ <test>" lines) and `_handle_ci_repair` did NOT already heal it as an inherited red, the watcher bounces the builder IMMEDIATELY with that evidence marked PROVISIONAL — the local healthcheck suite is still the authoritative verdict and may disagree. SHARES the HEALTH rail (kind=health, not a new rail): sha-keyed once-guard, the SAME REFIX_MAX_ROUNDS budget a local CODE ERROR bounce also spends, and a later local CLEAN/FLAKY retracts this red via the existing kind=health reset — zero new state. Grounded cost this removes: PR #610 sat red ~50 minutes (full local suite + full-suite retry) for a failure CI had already named in ~4 minutes. off (default) → byte-identical to the pre-HERD-495 needs-you path: no extra gh calls, no bounce, no ledger write. Consumed by agent-watch.sh
: "${RESOLVE_AUTOFIX:="off"}"    # HERD-541: auto-dispatch the conflict resolver on a genuine git CONFLICTING PR — on | off (default off, ship-dormant; yolo posture adopts on). on → when the classifier's CONF_* dispatch queue holds a conflicting PR (_classify_conflict already decided a resolver is due — a first conflict, a new commit that reshaped it, or a dead resolver, each already past its own sha-keyed once-guard and REFIX_MAX_ROUNDS cap) AND the PR's own builder agent is NOT working (done/idle/absent — a live builder is NEVER yanked out from under its own WIP), the resolve pass dispatches herd-resolve.sh for that slug through the SAME spawn_resolver every other healer rail uses: RESOLVE_CLAIM (if armed) is consulted exactly as for every other caller, an ESCALATE stays the existing needs-you + PR comment (terminal for that sha), and a live builder still working the conflict itself is left alone — the row stays the honest needs-you. Journals `resolve_autodispatch`; the console row while the resolver runs reads `resolving · auto`. off (default) → byte-identical to before: CONF_* is computed and dropped every tick, and a true git conflict is always the pre-HERD-541 needs-you row. Consumed by agent-watch.sh
: "${ANOMALY_BASELINES:="off"}"  # HERD-496: self-observation — PER-PHASE DURATION BASELINES + anomaly self-filing — on | off (default off, ship-dormant; yolo posture adopts on). on → the watcher records every completed phase's wall-clock duration (healthcheck start→verdict, review dispatch→verdict, the post-merge main-health suite, a refix bounce→wake, and its own tick cadence) into a rolling per-phase median/p95 baseline in the shared pool (pysrc/herd/store.py); once a phase has LEARNED enough samples, an instance that runs past 2x its own p95 journals a `phase_anomaly` event, paints a calm advisory row ('health-check 28m — p95 19m'), and FILES ONCE via the SAME shared-pool dedup marker MAIN_HEALTH_AUTOFIX's filing leg uses (HERD-371), keyed by phase+measurement+baseline so a re-observed identical reading dedups and a worse reading files fresh. GROUNDED: a 5h dead watcher (2026-08-02) was a tick-silence anomaly a learned baseline would have caught within minutes; a genuinely slow-but-typical suite never false-files because the threshold is LEARNED, not guessed. off (default) → byte-inert: no store write, no journal line, no row, no filing. Consumed by agent-watch.sh
: "${ANOMALY_FILE_COOLDOWN_SECS:="1800"}"  # HERD-512: seconds a phase must wait after ACTUALLY FILING an anomaly item before that SAME phase may file another — default 1800 (30 min); 0 = off, i.e. the pre-HERD-512 behavior where every above-threshold reading may file. Only consulted while ANOMALY_BASELINES is on (off stays byte-inert). ANOMALY_BASELINES' honest-identity dedup only collapses an IDENTICAL re-reading (same phase+seconds+p95), so a phase that stays degraded files a FRESH item every tick it reads differently — GROUNDED 2026-08-04: one overnight window produced 4 separate tracker items telling the same tick-cadence story. Inside the window the anomaly is STILL journaled and STILL painted on the console ledger — the operator loses no visibility — only the tracker filing is withheld, journaled `phase_anomaly_filed result=cooldown`. A non-numeric value reads as the DEFAULT (not 0): a typo must not silently restore the filing storm this key exists to stop. Consumed by agent-watch.sh
: "${RESOLVER_PANE:="off"}"      # HERD-280: the conflict resolver as a RETIRING PANE — on | off (default off, ship-dormant). on → herd-resolve.sh spawns the resolver as a bottom SPLIT PANE inside the builder's existing tab (label == slug) instead of a standalone resolve·<slug> tab, falling back to that tab in the control-room workspace when no builder tab exists; it records the pane in a sha-scoped dispatch registry ($TREES/.resolve-registry-<pr>-<sha>) and the watcher RECONCILES that registry against the OBSERVED verdict file each tick — a `RESOLVE: DONE` retires the pane immediately (guarded close + journal `resolver_pane_retired reason=result-consumed`), a `RESOLVE: ESCALATE` KEEPS the pane open for human inspection behind the existing needs-you row. The WORKTREE lifecycle is untouched: the retirement invariant still reaps at merge. off (default) → byte-identical to the pre-HERD-280 lane: a standalone tab, no registry file written, no reconcile, no retire. Consumed by agent-watch.sh + herd-resolve.sh
: "${WATCHER_IDLE_CADENCE:="off"}"  # HERD-671 leg 2: IDLE-CADENCE — on | off (default off, ship-dormant). GROUNDED 2026-08-13: three of four watchers on one machine sit idle (zero open PRs, zero local builder worktrees) most of the night yet still pay a REMOTE gh round-trip every ~4s tick — the render leg's `gh pr list` and the Python engine core's own pooled `gh api graphql` discovery both run unconditionally regardless of whether there is anything to look at. on → each tick RECONCILES idleness fresh from two LOCAL, no-gh signals — any builder worktree currently checked out under $WORKTREES_DIR (a fresh `git worktree list`, always free) OR last tick's OWN successfully-fetched open-PR count being nonzero — and while BOTH read zero, widens the remote leg's cadence to WATCHER_IDLE_REMOTE_SECS instead of paying it every tick; the 4s LOCAL render/reconcile loop itself is untouched (it keeps repainting from whatever state the last remote fetch left behind, exactly like the existing TEAM_PRESENCE/adopt/inbox throttles). The countdown resets to zero — remote polling snaps back to full 4s cadence the very next tick — the instant either signal goes non-idle, so a freshly spawned builder or a newly opened PR is never left waiting out a stale window. off (default) → byte-identical: both remote legs run every tick exactly as before this key existed. Consumed by agent-watch.sh
: "${WATCHER_IDLE_REMOTE_SECS:="60"}"  # HERD-671 leg 2: the widened remote-leg poll interval (seconds) WATCHER_IDLE_CADENCE steps up to while idle; only consulted while that lever is on. A non-numeric or sub-4s value falls back to the built-in 60. Consumed by agent-watch.sh
: "${WATCHER_SCOPE:="mine"}"     # HERD-653 (GH #769, review follow-up): mine (default) | all — see the
# team-mode block far below (§ Watcher lens + team mode / docs/capabilities-overview.md) for the full
# on-behavior. Until this line, WATCHER_SCOPE carried NO `: "${KEY:=default}"` of its own (unlike its
# WATCHER_* siblings, which genuinely stay unset when unconfigured) — each bash call site inlined its
# own `${WATCHER_SCOPE:-mine}` fallback instead, so a solo project's os.environ never carried the key
# at all. That was SAFE for the bash reference (`_watcher_scope`'s own inline default reads identically
# whether the shell var is merely unset or genuinely absent) but became a live safety gap for the
# Python engine core once it started distinguishing "explicitly mine" from "never resolved" (HERD-653:
# a WATCHER_SCOPE that silently fails to cross the shell→python export boundary must WITHHOLD
# auto-merge, not default permissive — the emberglen incident, a teammate's PR auto-merged while the
# console read "not mine - manual"). Giving it a REAL resolved value here — exported below like every
# other _HERD_ENGINE_CORE_KEYS member — means "absent from the python child's environment" can now only
# ever mean a genuine wiring gap (a broken export chain, a caller that never sourced this file), never
# the ordinary, fully-supported solo default: the python core's own fail-closed path stays armed for
# real gaps without adding a per-tick `gh api user` probe (or any other behavior change) to every
# solo install's happy path. byte-identical for every project already setting WATCHER_SCOPE explicitly.
: "${RESOLVE_CLAIM:="off"}"      # HERD-423: the cross-seat resolver-dispatch CLAIM — on | off (default off, ship-dormant), armed ONLY when ALSO WATCHER_SCOPE=all (team mode); WATCHER_SCOPE=mine (default) or this lever off both read "off" with ZERO gh calls, byte-identical to pre-HERD-423. on (in team mode) → before `spawn_resolver` dispatches a conflict resolver, the watcher reads a repo-visible v1 claim (a single HTML-hidden `<!-- herd:resolve-claim v1 -->` PR comment carrying pr/sha/seat/slug/epoch/state, upserted in place — never a Statuses/Check-Run write, which risks stranding mergeability): a live foreign claim for the EXACT (pr, head sha) HOLDS without burning local respawn budget; a foreign done/escalated terminal for that sha also holds (never redo already-finished work); a claim for a DIFFERENT sha is stale and ignored (a new commit re-arms); a foreign claim past RESOLVE_CLAIM_TTL is a bounded steal (journaled resolve_claim_steal). Local $RESOLVE_STATE remains the source of truth for same-seat budget/rows — the shared claim is an ADDITIONAL guard, never a rewrite. A `gh` read/write outage fails SOFT to the local-only path (never a fabricated foreign claim, never a held gate). Consumed by resolver-claim.sh, sourced by agent-watch.sh
: "${RESOLVE_CLAIM_TTL:="2700"}" # HERD-423: seconds a foreign "claimed" cross-seat resolver-claim row (RESOLVE_CLAIM) stays binding before it is a bounded steal target — default 2700 (45 min), comfortably above resolver startup grace + a typical resolve round. A non-numeric value reads as the default. Only consulted when RESOLVE_CLAIM is armed. Consumed by resolver-claim.sh, sourced by agent-watch.sh
: "${HEALTH_PANE:="off"}"        # HERD-313: the in-flight HEALTHCHECK as a DISPOSABLE WATCH PANE — on | off (default off, ship-dormant). on → each render tick the watcher RECONCILES the observed in-flight suites (the sha-scoped `.health-inflight-<pr>-<sha>` markers, whichever engine wrote them) against the panes that exist, BOTH ways (HERD-554). A live suite with no pane gets a stamped `health·<slug>` pane (a plain `tail -F` of the sha-scoped health log $TREES/.health-log-<pr>-<sha> — NO model, NO gate authority, a VIEW only), recorded in a sha-scoped registry ($TREES/.health-pane-registry-<pr>-<sha>: one row `pane tab health·<slug>`); the moment the suite ends (marker gone / worker dead) the pane is retired through the HERD-134 guarded close (a stale/recycled id naming a neighbour is REFUSED, journaling pane_close_refused) + journal `health_pane_retired`, dropping the row and its now-empty tab. Independent of, and additive to, the always-on live progress row (leg b). off (default) → byte-identical: no pane, no registry file, no reconcile side effect. An unrecognized value reads off (a typo can never arm a pane-closing path). Consumed by agent-watch.sh
: "${AGENTS_PANE:="off"}"        # HERD-668 (epic HERD-666, child 2 of the agent-roster CLI HERD-667/PR #784): the specialist AGENT ROSTER as a compact READ-ONLY control-room pane — on | off (default off, ship-dormant). on → coordinator.sh (fresh control room) and `herd reload`/`herd pane agents` (in-place) split the WATCH pane RIGHT (ratio 0.72 — the watcher keeps ~72% of the width, this pane the remainder), launch scripts/herd/agents-pane-view.sh in the new pane, label it `agents·<WORKSPACE_NAME>` (herd_driver_pane_rename, same convention as watch·/backlog·), and register it as a 4th ROLE ROW (`agents <pane> <tab> <ws>`) in the $WORKTREES_DIR/.herd-panes registry via the shared layout_write_registry writer — an older registry with no such row still loads fine (each role row is independently optional). The pane RENDERS on a slow tick, RECONCILED from OBSERVED state each pass (never a live probe on the render path): every scripts/herd/agents.sh roster definition with its CACHED resolve verdict (herd_roster_cache_get — the same cache `herd agents verify` writes, never re-probed here), and which specialist agent (if any) each in-flight builder was spawned under, read from the per-worktree `$WORKTREES_DIR/.herd-agent-<slug>` marker herd-feature.sh/herd-quick.sh write only when HERD_AGENT was set (blank/absent marker → rendered as "general", mirroring the HERD_ITEM_REF/.herd-ref-<slug> marker convention) — an empty roster or an uninstalled roster dir renders one hint line, never blank. STRICTLY read-only: the pane never spawns, mutates, gates, or merges, and it never blocks a merge (no gate consumes it). off (default) → byte-identical: no split, no registry row, no renderer, no marker file is ever consulted. An unrecognized value reads off. Consumed by coordinator.sh, bin/herd (cmd_reload, herd pane agents), scripts/herd/agents-pane-view.sh
: "${TAB_DISCIPLINE:="off"}"     # HERD-569: the TAB DISCIPLINE invariant as a RECONCILED SWEEP — on | report | off (default off, ship-dormant). Operator directive 2026-08-05, verbatim: "there shouldn't be ANY other tabs spawned other than builders, or the scribe" — the workspace tab bar is the operator's situational-awareness surface, so a tab that is neither a builder, the scribe, nor the control room is a defect. on → on the orphan-sweep cadence (~60 s) the watcher enumerates THIS workspace's tabs and retires every one that is not (a) a $TREES/.herd-tabs row of kind `builder`, (b) the tab of a live worktree in $WORKTREES_DIR (belt to (a)'s braces — a builder whose registry write failed must not be vaporised for the engine's own bookkeeping slip), (c) the scribe drainer's tab, (d) the control room's tab or this watcher's own $HERD_WATCHER_TAB_ID, or (e) a `label` row in templates/tab-discipline-exempt.tsv (the committed record of the lanes that still deliberately own a tab, each paired with the `callsite` row that lets scripts/herd/tab-create-lint.sh pass). Each retirement journals `tab_discipline_retired` with the label + why — loud, never silent — and prunes any registry row the tab left behind. report → detect + journal `tab_discipline_stray`, closing NOTHING (the safe way to watch what a real control room would lose). REFUSES rather than guesses on every missing input: an unresolvable workspace id (never sweep unscoped — the cross-project-kill lesson, issue #60), an absent .herd-tabs (no way to tell a builder from a stray), an unreachable mux, dry-run and headless all sweep nothing, byte-quiet; more than $HERD_TAB_DISCIPLINE_MAX (5) strays in one pass retires the cap's worth and journals `tab_discipline_capped`. off (default) → a HARD no-op: no herdr call, no journal line, no file read. An unrecognized value reads off (a typo can never arm a tab-closing path). Consumed by agent-watch.sh via tab-discipline.sh
: "${MERGE_FAIRNESS:="off"}"     # HERD-231: READY-PR PRIORITY in the watcher's action pass — on | off (default off, ship-dormant). on → candidates whose gates are ALREADY green for their head sha (cached CLEAN/FLAKY healthcheck + a review PASS, or a human-overridden BLOCK) are visited BEFORE candidates that still need gate work, so a ready PR merges this tick instead of waiting behind dispatches for its siblings — dispatches whose eventual merge is exactly what re-stales it. A stable partition of the candidate order: nothing merges that has not fully passed (the pre-merge re-verify, the unconditional stale-base re-check and the merge-policy decision all still run on a promoted PR). off (default) → the candidate order, and every event/dispatch/merge that follows from it, is byte-identical to before the feature. INDEPENDENT of the always-on re-stale counter + `starving · N re-stale laps` row, which are display-only. Consumed by agent-watch.sh
: "${MERGE_RESULT_GATE:="off"}"  # HERD-296/§6.4: the MERGE-RESULT GATE — on | off (default off, ship-dormant), a STRICT validated key (an unrecognized value reads off, never accidentally on). Today the pre-merge healthcheck runs the branch worktree AS-IS: two PRs can each test green on their own stale base, merge textually clean, and interact only through behavior (one changes a function's contract, the other consumes the old one in a file it never touched) — every gate passes and the default branch breaks (docs/spikes/merge-result-gate.md). on -> before gating, materialize a THROWAWAY detached worktree at the PR's exact head sha merged with the CURRENT default-branch tip, and run the healthcheck suite against THAT tree instead of the branch as-is (ONE suite run, never doubled gate latency); a real merge conflict is resolver-owned and fails soft into the same honest hold as the stale-dup gate (never a red, never a bounce). The tested (head, base) pair is cached so a base move re-arms the gate, and journals a `merge_result_gate` event carrying the tested base sha. off (default) -> byte-identical: the classic per-branch healthcheck dispatch is untouched, no `.merge-result-*` file is ever written. FOLDED INTO THE PYTHON PORT ONLY (EPIC HERD-300 P3, docs/engine-contract.md §6.4) — never built into the retired bash action pass; consumed by pysrc/herd/live_runtime.py, NOT agent-watch.sh.
: "${MERGE_QUEUE:="off"}"        # HERD-273/§6.3: the ORDERED INTEGRATION QUEUE (merge train) — on | off (default off, ship-dormant), a STRICT validated key (an unrecognized value reads off, never accidentally on). Today candidates merge independently, each verified only against its own base — nothing stops two blessed siblings from landing in the same window in whichever order they happened to turn green, and nothing stops a later one from "lapping" an earlier one still finishing its final gate. on -> a deterministic queue (ascending PR NUMBER — the one stable, collision-free order every seat derives with no shared ledger) forms over every open, non-stale candidate whose merge policy would land it once green; ONLY the queue FRONT may actually apply a merge THIS window — every OTHER candidate that reaches gates-green now HOLDS instead (`queue_wait`), even one whose own gates are green, so two siblings never land out of order. Implies the SAME per-slot verification MERGE_RESULT_GATE=on provides, UNCONDITIONALLY — the queue's correctness requirement is not a second, independently-toggleable key a project could leave mismatched; setting MERGE_RESULT_GATE explicitly (on OR off) alongside this key changes nothing. Because a real merge (not a synthetic chain) advances the base each time the front lands, "verified against the virtual tip" (contract §6.3) needs no speculative chaining: by the time a later position becomes front, every already-ordered candidate ahead of it has ALREADY really merged, so the plain current base tip already IS the virtual tip. Documented posture (mirrors HERD-296's resolver-owned CONFLICT, which carries no refix budget of its own): a front stuck needs-you or in a standing conflict blocks the WHOLE queue until a human/resolver clears it (a new sha, or closing the PR) — row-truth (§5.1) makes that stall loud, never silent; batch/speculative slots are deliberately out of scope for this primitive (docs/spikes/merge-result-gate.md §3). off (default) -> byte-identical: candidate order, dispatches, events, argv and merge behavior are untouched, no `queue_wait`/`merge_queue_*` event is ever journaled. FOLDED INTO THE PYTHON PORT ONLY (EPIC HERD-300 P3, docs/engine-contract.md §6.3) — never built into the retired bash action pass; consumed by pysrc/herd/live_runtime.py, NOT agent-watch.sh.
: "${GATE_STATUS:="on"}"         # HERD-194: post a `herd/gates` COMMIT STATUS as the watcher clears each (pr,sha) — on (default) | off. on → the watcher posts state=success on both-gates-green (healthcheck + adversarial review), exactly once per (pr,sha) via a sha-keyed ledger. It posts ONLY success — never a non-passing pending/failure status, which would flip a CLEAN sha to mergeStateStatus=UNSTABLE and strand it out of the merge loop in the default unprotected config. A gate FAIL posts NOTHING; the fail-safe rests entirely on the ABSENCE of success. Pair it with `require herd/gates` GitHub branch protection (recipe: docs/governance-gates.md) so the gate is FAIL-SAFE across seats/collaborators: anyone may merge, but nothing UNGATED can — a commit no watcher blessed has no success status and is unmergeable (under protection a fresh PR reports BLOCKED until blessed, which the watcher gates specially so requiring the check never deadlocks). In team mode (WATCHER_SCOPE=all) a sha another seat already blessed is not re-gated (cross-seat dedup). off → byte-inert: no status posted, no read. Consumed by agent-watch.sh
: "${GATE_STATUS_PENDING:="off"}" # HERD-453: post `herd/gates` state=PENDING at gate-cycle start — on | off (default off, ship-dormant), STRICT (an unrecognized value reads off). Requires GATE_STATUS=on. off (default) → byte-identical to the pre-HERD-453 SUCCESS-ONLY contract: no pending status is ever posted, the fail-safe rests entirely on the ABSENCE of success, and a `require herd/gates` PR page shows GitHub's own bare "Expected — Waiting for status to be reported". on → the moment a candidate ENTERS the gate DAG (once per (pr,sha)) the engine posts state=pending description="review in progress", so the PR page explains itself instead of showing an unattributed Expected row; the terminal success post is unchanged and overwrites it. READ THE HAZARD BEFORE ENABLING: a non-passing commit status flips a CLEAN sha to mergeStateStatus=UNSTABLE in the DEFAULT UNPROTECTED config — neither CLEAN (drops out of the merge path) nor BLOCKED (not gate-eligible) — which silently strands every PR. That is why the key exists and why it is off: enable it ONLY where `herd/gates` is a REQUIRED check under branch protection (recipe: docs/governance-gates.md), where such a PR already reports BLOCKED on the missing required check and a pending status changes nothing but the words the operator reads. A gate FAIL still posts NOTHING. Consumed by pysrc/herd/live_runtime.py
: "${CREATE_SELFHEAL:="on"}"     # HERD-267: tracker-create failure SELF-HEAL — on (default) | off. on → a backend create that the tracker REFUSES is diverted into a durable retry queue ($WORKTREES_DIR/.create-retry) instead of being silently consumed: the request text is written to disk before the claim is dropped, the reason is classified (cap | auth | transient | unknown) and journaled as `scribe_add_failed`, and the scribe drainer re-injects due entries with exponential backoff on its next poll. A PERMANENT reason (the tracker's issue cap, a bad API key) is announced with its own distinct label and is NEVER retried automatically — it surfaces loudly without spinning. `herd sweep` additionally runs an ADVISORY leg that finds merged PRs whose `Refs:` line points at no tracker item (the create never landed) and enqueues a retroactive-linkage request. off → byte-identical to the pre-HERD-267 behavior: a refused create is reported NOCHANGE and the request is dropped. Grounded in the 2026-07-10 incident where Linear's free-tier issue cap ate six coordinator filings over 2h and read as an "API flake". Consumed by scribe-step.sh + sweep.sh via create-retry.sh
: "${CREATE_RETRY_MAX:="5"}"     # HERD-267: how many times a durably-queued tracker create is re-attempted before it is marked PERMANENT (surfaced loudly, no longer re-injected). Only bounds the TRANSIENT/UNKNOWN classes: a cap/auth failure is permanent on its FIRST attempt, because retrying a wall cannot succeed and the spin is what hides the reason. The request text is retained on disk in every case — 'permanent' means stop retrying, never discard. A non-numeric value reads as 5. Consumed by create-retry.sh
: "${SWEEP_AUTO:="advise"}"      # HERD-191: control-room sweep triggers — off | advise (default) | auto. The watcher runs a CHEAP debris scan (stale tabs, dead inflight markers, orphaned ppid=1 bats/healthcheck trees) on its orphan-sweep cadence. advise → render one '🧹 sweep recommended: N stale tabs · M dead markers' console row + journal `sweep_advice` ONCE per distinct condition-set. auto → additionally run the SAFE legs (markers / orphan procs / registry tabs / PROVABLY-disposable worktrees); JUDGMENT legs (a worktree with real dirt or unpushed unique commits) stay advisory in every mode and are NEVER auto-deleted. off → byte-inert: no scan, no row, no journal. Consumed by agent-watch.sh via sweep.sh; `herd sweep` runs every leg on demand
: "${WATCHER_FLAIR:="off"}"      # HERD-147: watcher-console flair pack — on → a post-merge celebration line + a pasture header rendering the in-flight herd by state (🐑 grazing / 💤 idle / ✅ in the pen); off (default) → byte-inert: every console byte identical to before. ADDITIVE cosmetic only — NEVER softens a red/dead/needs-you row, never touches a gate/merge
: "${OPERATOR_INBOX:="off"}"     # HERD-184: cross-seat OPERATOR INBOX — on → the watcher surfaces NEW comments by OTHER authors (PR comments on open PRs this seat authors/gates + tracker comments on items this seat claimed, via the active SCRIBE_BACKEND's optional comment reader) as a 'operator inbox' console section + one notify-once per comment. off (default) → byte-inert: no reader runs, no fetch, no section, every console byte identical to before. ADDITIVE + FAIL-SOFT (missing/api error = empty inbox, never a red row); never touches a gate/merge
: "${ORPHAN_PR_ROWS:="off"}"     # HERD-330: ORPHAN-PR advisory console section — on → the watcher renders an 'orphan PRs' section listing each OPEN PR in the tick's ALREADY-fetched roster (PRS_JSON) that no live builder worktree in this workspace owns (a collaborator/main-checkout PR the worktree-gated watcher never adopts), so an ungated PR is visible instead of silently ignored. DYNAMIC discovery: recomputed every tick from live state, self-correcting the instant a worktree adopts (or the PR closes). Zero extra gh (reads the tick's existing discovery). Renders via the shared bounded-section helper (console-section.sh). off (default) → byte-inert: no scan, no ledger, no section, every console byte identical to before. ADVISORY + FAIL-SOFT — never gates, never merges, never a red row. Consumed by agent-watch.sh
: "${ADOPT_REMOTE_PRS:="off"}"   # HERD-369: auto-ADOPT ungated remote PRs into the worktree pool — on → builds ON TOP of the ORPHAN_PR_ROWS (HERD-330) open-PR-vs-pool diff (same already-fetched roster, zero extra gh): on a throttled ~60s cadence, for each OPEN, NON-DRAFT orphan PR whose branch is not already checked out ANYWHERE (this pool, the main checkout, or a stray manual worktree), `git fetch` + `git worktree add` its branch into WORKTREES_DIR so the worktree-gated watcher discovers and gates it the VERY NEXT tick instead of sitting ungated until a human hand-runs `git worktree add` (grounded: PRs #462/#463 sat ~16-18h on 2026-07-13, #478 ~18h on 2026-07-15). A SUCCESSFUL adopt is sha-keyed once-guarded ($WORKTREES_DIR/.agent-watch-adopted-prs) so a re-tick never re-adopts; a FAILURE (transient network blip, momentary ref lock) is never once-guarded and retries every scan — only the `adopt_failed` journal event is deduped per (pr,sha) ($WORKTREES_DIR/.agent-watch-adopt-failed-seen), never a red row. Never adopts a draft. Multi-seat: keyed off observed GitHub PR state each tick; `git worktree add` is naturally exclusive per branch. off (default) → byte-inert: no scan, no fetch, no worktree add, no ledger, every console byte identical to before. INDEPENDENT of ORPHAN_PR_ROWS — either works without the other. Consumed by agent-watch.sh
: "${TEAM_PRESENCE:="off"}"      # HERD-527 (GH #639 phase 1) + HERD-663 (compact row) + HERD-661 (GH #639 phase 2): TEAMMATE BUILDER VISIBILITY on the ungated-PR rows — off (default, ship-dormant) | on | live. The watcher discovers work via LOCAL git worktrees, so a teammate's actively-being-built PR renders in the unconditional 'ungated PRs' section as 'ungated · no builder record · enable ADOPT_REMOTE_PRS or git worktree add to adopt' — an adopt nudge that is exactly WRONG when another operator is mid-build on their own machine (grounded: emberglen-godot, two operators, WATCHER_SCOPE=all). on → on a throttled ~60 s cadence the watcher resolves each UNGATED PR to its tracker item (the shared `Refs:` parser, HERD-522, with a token-exact branch-name fallback), reads that item's live state + assignee through the active SCRIBE_BACKEND's OPTIONAL rich roster op (_backend_list_open_rich — ONE call per scan, cached in a ledger and reused by every 4 s repaint), and for an item that is IN PROGRESS *and* ASSIGNED renders the compact person-emoji row '👤 #<pr> <title> · <name> — building <id>' instead, SUPPRESSING the adopt nudge on that row (HERD-663: replaces the older wordier 'ungated here · <handle> building <id> on their machine'; <name> honors TEAM_ALIASES when configured). REUSES the existing claim machinery (a claim sets assignee + in-progress, HERD-50/HERD-244) — no new presence channel, no new write, no tracker mutation. live → EVERYTHING on does, PLUS a real live channel (team-presence-live.sh): on the SAME throttled tick, this seat upserts a versioned, epoch-stamped, HTML-hidden marker comment (resolver-claim.sh's proven substrate — never a Statuses/Check-Run write) on each of ITS OWN open PRs (no PR = nothing published; an ADOPTED PR authored by someone else is never published to), and the consume leg reads that marker back for each ALREADY-attributed PR to append a freshness clause to the compact row — '👤 #<pr> <title> · <name> — building <id> · active 2m ago' inside _TEAM_PRESENCE_LIVE_STALE_SECS (300s), else '· last active 3h ago (stale?)'. Seat-symmetric: every seat publishes its own and consumes everyone else's. off (default) → byte-inert: no gh, no backend call, no ledger, every console byte identical to before. ADVISORY + FAIL-SOFT — an unreachable tracker, a backend with no rich op, an unparseable body, or (under live) an absent/unreachable live marker leaves TODAY's (or on's) row; it never gates, never merges, never a red row. Consumed by agent-watch.sh via team-presence-live.sh
: "${TEAM_ALIASES:=""}"          # HERD-663: machine-scoped display-name overrides for the ungated-PR person-emoji rows (TEAM_PRESENCE's attributed row + the author-fallback row below) — empty (default, ship-dormant) → byte-inert passthrough, every row shows whatever the tracker/gh already gave it. Format: comma-separated handle=Name pairs, e.g. 'nouvertnec84=Chase,anotherhandle=Other Name' — <handle> matched case-insensitively against the tracker assignee / PR author login; a hit renders <Name> in its place, a miss (or an unset key) falls back to whatever was already resolved (tracker display name when the backend provides one, else the raw handle). FAIL-SOFT: a malformed pair (no '=', empty name) is skipped, never a crash, never a red row. Consumed by agent-watch.sh
: "${OSS_TRIAGE:="off"}"         # HERD-255 / HERD-168 part 1/3: OSS auto-triage — on → `herd triage` lists open issues on HERD_REPO, enqueues a research-lane request per NEW issue (classify bug/feature/question/duplicate + draft reply/labels), and writes a ranked shortlist report for human approval. off (default) → byte-inert: no gh, no research enqueue, no report files. NEVER auto-posts (no issue comment/close/label). FAIL-SOFT (missing HERD_REPO / gh error → empty shortlist, never a hard red). Consumed by scripts/herd/oss-triage.sh
: "${JOURNAL_AUDIT:="off"}"      # HERD-238: journal-driven self-audit (the gap-finder) — on | off (default off, ship-dormant). on → the watcher runs journal-audit.sh on the tracker/housekeeping sweep cadence, replaying a BOUNDED journal window for invariant violations (merge without reap; *_dispatched with no terminal past family TTL; refix_bounce without refix_wake_result; MAIN RED older than TTL; pushed=no never followed by pushed=yes; known-fixture slugs). Findings → operator-inbox rows (source=audit) + journal_audit events (component=audit). ADVISORY ONLY — never gates, never mutates. off (default) → byte-inert: no journal read, no write, no inbox. FAIL-SOFT on empty/short journal. Consumed by agent-watch.sh via journal-audit.sh
: "${JOURNAL_AUDIT_ACT:="off"}"  # HERD-544: journal-audit findings become ACTIONS (the universal never-stuck invariant) — on | off (default off, ship-dormant). Requires JOURNAL_AUDIT=on (it acts on that auditor's findings; with the auditor off there are no findings and this key is inert). on → each finding class is mapped to ONE bounded action instead of an advisory row: a *_dispatched with no terminal past TTL frees its held gate slot (the HERD-185 corpse hygiene) so the next tick re-dispatches; a refix_bounce with no wake is re-delivered ONCE to the builder's agent pane (a wake that lands journals the missing refix_wake_result and closes the finding; one that does not leaves it standing to escalate); a MAIN RED past TTL arms the main-health re-verify rail for the current HEAD; a merge with no reap runs the retirement invariant (HERD-164) now; ANY class with NO mapped action auto-files ONE dedup-keyed tracker item via the scribe so the gap becomes work. Every action fires AT MOST ONCE per finding key across every seat (shared-pool once-guard) and is journaled `audit_acted class=… result=…`; a finding still standing after its action escalates loudly exactly once (journal + inbox row + filed item). NEVER a merge gate. off (default) → byte-inert: findings stay advisory-only, byte-identically. FAIL-SOFT throughout (an unavailable rail/store/scribe degrades to an honest result token). Consumed by scripts/herd/journal-audit.sh via scripts/herd/journal-act.sh
: "${LIFECYCLE_CONTRACTS:="off"}" # HERD-193: the SUPERVISED-PROCESS CONTRACT — on | off (default off, ship-dormant). on → every spawned agent population records the four lifecycle properties at spawn (OWNER: which component spawned it · DEADLINE: the max lifetime after which it is presumed hung, REUSED from that population's existing timeout — REVIEW_INFLIGHT_TIMEOUT / HEALTH_INFLIGHT_TIMEOUT / DRAINER_HEARTBEAT_TIMEOUT · LIVENESS: a pid or a heartbeat file · RETIRE: the existing owner an expiry routes to), and a per-tick watcher sweep journals lifecycle_spawn / lifecycle_retire / lifecycle_expired and appends an operator-inbox row for anything past deadline. OBSERVABILITY-ONLY: it never kills, never gates, never merges — teardown stays with each population's existing owner (gate corpse sweep, drainer reclaim, stall detector, resolver escalation). off (default) → byte-inert: no record written, no journal event, no inbox row, no sweep read. FAIL-SOFT throughout. Consumed by agent-watch.sh, scribe.sh, research.sh via lifecycle.sh
export MODEL_REVIEW              # HERD-353: reach the Python engine core the watcher spawns as a child (like WORKTREES_DIR below); set as a plain var above, must be exported so live_runtime's review dispatch resolves the EFFECTIVE reviewer model — otherwise the python child never sees this unexported shell var and journals review_dispatched with model= empty (the reviewer, which sources config itself, still ran the right model; only the journal was wrong)
export WORKTREES_DIR             # HERD-345: reach the Python engine core the watcher spawns as a child; set as a plain var above, must be exported so every child process (live_runtime --tick) sees it
export PROJECT_ROOT              # HERD-345: ditto — the Python live_runtime refuses to tick without WORKTREES_DIR resolved, and PROJECT_ROOT is the co-required sibling
export STORE_BACKEND             # HERD-305: reach the Python engine core the watcher spawns as a child (like PYTHONUTF8 / HERD_THEME above); default 'auto' resolves flat, so the export is a dormant selector
export MAIN_HEALTH_TICK          # HERD-359: reach the Python engine core the watcher spawns as a child — _main_health_pending() (live_runtime --tick) reads it to reserve a health slot for main-health; set as a plain var above, without the export the child sees 'off' and the reservation is inert

# HERD-449 FULL SWEEP — every remaining knob pysrc/herd/live_runtime.py's _CORE_ENV_KEYS reads from
# os.environ, exported for the SAME reason as MODEL_REVIEW / WORKTREES_DIR / PROJECT_ROOT /
# STORE_BACKEND / MAIN_HEALTH_TICK just above: `python3 -m herd.live_runtime --tick` runs as a CHILD
# process of the watcher (engine-version.sh:herd_engine_live_tick) and inherits ONLY the EXPORTED
# shell env — a plain `: "${KEY:=default}"` var (or a project override in .herd/config with no
# `export`) never crosses that boundary, so the child silently falls back to its own built-in default
# no matter what the project configured. Three prior items (HERD-353/345/359, the exports above) each
# closed this gap for ONE key; this is the full sweep, plus the guard that makes it unrepeatable
# (scripts/herd/env-export-lint.sh, wired into both healthcheck profiles) so a fourth one-off fix is
# never needed again. GROUNDED 2026-07-31: HEALTH_CONCURRENCY=3 was configured but read as 1 by the
# engine core, zeroing the HERD-359 main-health slot reservation (_health_max - 1 == 0) whenever
# main-health was pending, so NO PR healthcheck could dispatch at all — two PRs sat un-gated over an
# hour. Byte-identical for every seat already at the default: exporting only changes what a CHILD
# process sees, never the value itself.
#
# HERD-465: the actual `export` for every key in this sweep (HEALTH_CONCURRENCY / REVIEW_CONCURRENCY /
# MERGE_POLICY / WATCHER_AUTOMERGE / HUMAN_VERIFY_POLICY / MERGE_METHOD / REFIX_MAX_ROUNDS /
# REFIX_COMPLETE_MIN / WORK_UNIT_KIND / MERGE_RESULT_GATE / MERGE_QUEUE / GATE_STATUS /
# GATE_STATUS_PENDING / MERGE_FAIRNESS / DELETE_BRANCH_ON_MERGE / HERD_REFIX_WAIT_TIMEOUT /
# MERGE_FAIRNESS_STARVE_THRESHOLD / the WATCHER_* view+scope knobs / INFRA_BREAKER_MAX /
# INFRA_BREAKER_COOLDOWN) now happens ONCE, off the single _HERD_ENGINE_CORE_KEYS list defined above
# the RESET at the top of this file, in one loop below INFRA_BREAKER_COOLDOWN's own
# `: "${KEY:=default}"` line — the last of these keys to resolve a value — so every one of them is
# exported with its FINAL value and the reset/export halves can never drift apart again.
# DELETE_BRANCH_ON_MERGE / HERD_REFIX_WAIT_TIMEOUT / MERGE_FAIRNESS_STARVE_THRESHOLD and the
# WATCHER_* knobs carry no `: "${KEY:=default}"` line of their own (each call site inlines its own
# `${KEY:-default}` fallback instead) — a bare `export KEY` on an unset var is a no-op (verified:
# `unset FOO; export FOO` never even creates FOO), so exporting them here only matters the moment a
# project actually sets one in .herd/config.
: "${STORE_BACKEND:="auto"}"     # HERD-305 (engine-port P4): the MUTABLE-STATE STORE backend the Python runtime (pysrc/herd/store.py, live_runtime/shadow_runtime) reads — auto | flat | sqlite (default auto, ship-dormant). auto → FLAT (the ~45 flat state files agent-watch.sh owns) UNTIL the one-shot migration runner (`python3 -m herd.store --migrate`, operator-triggered, gated by herd_engine_migration_guard) has migrated the pool and written a `.herd/store-backend` marker; only then does auto engage the SQLite (WAL) store. flat → force flat. sqlite → force sqlite (explicit opt-in / tests). With nothing migrated auto == flat, so behavior is BYTE-IDENTICAL to before this key (the store never engages a backend it cannot open). The journal stays append-only JSONL, NEVER in the db. FAIL-SOFT: an unreadable marker / missing db degrades to flat. Consumed by pysrc/herd/store.py (resolve_backend)
: "${WATCHER_SELF_RESTART:="off"}" # HERD-251: watcher SELF-RESTART on stale engine code — on | off (default off, ship-dormant). on → when the freshness leg observes that $MAIN now holds engine code this process is not running (the same restart-note trigger HERD-233 already raises; HERD-651 widened it from "the pulled delta rewrote agent-watch.sh" to "$MAIN's HEAD moved off the sha this image loaded AND the delta touched a path the watcher loads — scripts/herd/, pysrc/herd/, bin/herd — with docs/ and templates/ excluded, since a render input is not running code"), the watcher QUIESCES: it stops dispatching NEW gate work (reviews, healthchecks, resolver spawns, and the stale-base heal that dispatches them) while in-flight workers finish and collect; each hold sits above its call site's ledger write, so a refused dispatch never burns a once-guard, then re-execs itself in place — same pane, same argv0 herd-watch-<ws> tag, same singleton lock (the exec keeps the pid, so the lock it re-acquires is its own) — once zero review/health gate workers remain for 2 consecutive ticks, or a 15-minute max-wait cap expires. Journals watcher_quiesce then watcher_self_restart; the console row becomes 'restarting on new engine code · draining N workers'. FAIL-SOFT: any error (unreadable script, hermetic guard) falls back to the plain 'restart recommended' row. off (default) → byte-identical to the HERD-233 recommendation row: no quiesce, no dispatch hold, no exec. Consumed by agent-watch.sh
: "${WATCHER_SINGLETON_RECONCILE:="off"}" # HERD-450: the watcher SINGLETON as a RECONCILED INVARIANT — on | off (default off, ship-dormant). The invariant: EXACTLY ONE live process carries this workspace's argv0 AND the lockfile NAMES it. GROUNDED 2026-07-31: a watcher SURVIVED a `herd reload`, ran 41 minutes re-parented to init alongside its replacement (both gating the same PRs, wrecking slot accounting) while the lockfile stayed EMPTY throughout — and an empty lockfile blinds every seat at once, because `herd status`, the sweep, the launch paths' adopt-or-refuse read and the fork exemption ALL key off the recorded pid. on → each tick the watcher classifies the invariant through the shared watcher-exempt.sh seam (watcher_singleton_verdict): a DUPLICATE journals `watcher_singleton_violation` (once per signature) and paints a loud persistent console row naming the pids and the remedy; a drifted/empty/stale lockfile is REPAIRED in place by the sole live main recording itself (journals `watcher_lock_repaired`) so the guard holds something again. It NEVER kills: telling a genuine orphan (ppid 1) from a legitimate review-tick FORK (ppid == the live watcher) is the exemption seam's job, and reaping a fork caches a bogus BLOCK verdict. off (default) → byte-inert: no ps sample, no journal event, no row, no lockfile write. Consumed by agent-watch.sh
: "${WATCHER_STOP_REAP_MAIN_HEALTH:="off"}" # HERD-450: on `herd reload` / `herd pane watch` / sweep leg 5, also stop the MAIN-HEALTH chains the watcher being stopped was running — on | off (default off, ship-dormant). A watcher restart ORPHANS its gate chains (they re-parent to init) rather than stopping them, so an orphaned main-health worker keeps holding its `.health-inflight-main-<sha>` marker — and a HEALTH_CONCURRENCY slot — for the rest of a ~9-minute heavy suite whose verdict the departed watcher will never collect; the marker is ABANDONED and only ages out on HEALTH_INFLIGHT_TIMEOUT (HERD-451) while PR healthchecks queue behind a corpse. on → the stop leg SIGTERM→poll→SIGKILLs each live main-health worker that descends from a watcher it just stopped (its parent is one of them, or it is already re-parented to init), removes the marker on CONFIRMED death, and journals `main_health_chain_reaped` per pid. Safe by construction: MAIN_HEALTH_TICK is itself a reconciled invariant, so a killed chain costs exactly one re-run on a later tick. The PR-gate families are NEVER touched — a review / per-PR health worker's result file IS collected by the next watcher, so killing one would destroy real work. off (default) → byte-identical: no glob, no signal, no journal line. Consumed by bin/herd
: "${WATCHER_RESURRECT:="off"}"  # HERD-489: external-cadence WATCHER RESURRECTION — on | off (default off, ship-dormant). GROUNDED 2026-08-02: a dead watcher stayed dead for 5 HOURS — every existing revival lever (WATCHER_SELF_RESTART, WATCHER_SINGLETON_RECONCILE, COORDINATOR_WATCHDOG) is code the watcher's OWN tick loop runs, so all three are inert against the one failure that actually happened: the process is not running AT ALL, and nothing is ticking to notice. This key gates `scripts/herd/watcher-resurrect.sh` (exposed as `herd watcher-resurrect`), a SEPARATE short-lived probe meant to be driven by an operator cron/launchd job on an external cadence (see docs/COORDINATOR-SOP.md) — the one place code CAN run when the watcher itself cannot. on → each invocation classifies THIS project's watcher through the shared watcher-exempt.sh seam (watcher_singleton_verdict — the identical argv0 + lockfile/flock reconciled check `herd status` and WATCHER_SINGLETON_RECONCILE use, HERD-450); it acts ONLY on a CONFIRMED zero-mains verdict (state NONE) — OK / LOCK_DRIFT / DUPLICATE / HANDOFF all mean at least one main is alive and are left STRICTLY alone, so a live watcher (however its lockfile bookkeeping looks) is NEVER doubled. On NONE it journals `watcher_resurrect_detected` (loud, before acting) and relaunches through the VERIFIED stop/start seam (`herd reload`, issue #579) — never its own kill/spawn logic — then journals `watcher_resurrected` with the new pid on a confirmed live relaunch, or `watcher_resurrect_failed` otherwise. off (default) → byte-inert: no verdict call, no journal write, no relaunch, exit 0, even when the probe is invoked. Consumed by scripts/herd/watcher-resurrect.sh
: "${WATCHER_CRASHLOOP_GUARD:="off"}" # HERD-548: the pane wrapper's CRASH-LOOP hard stop — on | off (default off, ship-dormant). GROUNDED 2026-08-05: post-reload the watcher crash-looped silently for ~2 minutes (repeated fast child deaths, zero journal, zero console beyond the header) then self-resolved with nobody the wiser. on → herd-watch.sh (the pane wrapper every launch path — cmd_pane_watch, cmd_reload, herd watcher-resurrect — ultimately runs) stops using a bare `exec` and instead runs agent-watch.sh in a supervising loop: a death that is NOT a deliberate stop signal (SIGTERM/SIGINT/SIGHUP — those simply end the wrapper, never fought) and survived less than HERD_WATCH_CRASHLOOP_FAST_SECS (default 5) counts as a FAST death; after HERD_WATCH_CRASHLOOP_N (default 3) CONSECUTIVE fast deaths the wrapper STOPS respawning, prints the last captured child stderr LOUDLY to the pane, journals `watcher_crashloop`, and trips the shared watcher-exempt.sh marker (watcher_crashloop_trip) — cleared automatically the moment a later watcher PROVES it survives past the same settle window (agent-watch.sh, just before its tick loop). Child stderr is captured to a bounded per-attempt file (last HERD_WATCH_CRASH_TAIL_LINES lines, default 80) so the loud print never scrolls the real fault out of the pane's backing scrollback. watcher-resurrect.sh checks the SAME marker before ever calling `herd reload`, so the external cron cadence never fights a standing loop by relaunching the identical broken build on a timer — a plain operator-run `herd pane watch` is NOT gated by the marker; only the unattended probe treats it as a hard stop. off (default) → byte-identical to before this key: a bare `exec`, no loop, no capture file, no marker, no journal from the wrapper. Consumed by scripts/herd/herd-watch.sh, scripts/herd/watcher-resurrect.sh
# BUDGET_DAILY (HERD-95) — daily SPEND CEILING in USD that ENFORCES, not just measures. herd cost
# already prices every builder/review/agent session and journals a `cost` event at merge; this key
# turns that ledger into a rail. When today's (UTC) recorded cost total exceeds BUDGET_DAILY the
# watcher PAUSES spawn-queue draining (agent-watch.sh _drain_spawn_queue) and each lane (herd-quick.sh
# / herd-feature.sh) REFUSES a new spawn with one loud line — so a runaway day stops spending instead
# of only surfacing when a human reads the ledger. The daily total REUSES herd cost's summer
# (cost.sh cost_day_total) — no cost math is reimplemented. FAIL-SOFT + overridable: HERD_FORCE_SPAWN=1
# (or a lane's --force) spawns anyway (journaled); a missing journal / no python3 never blocks. EMPTY
# (default) = DORMANT: the gate returns immediately and behavior is byte-identical to no budget. A
# non-numeric value is treated as dormant (never enforce on a typo). Consumed by agent-watch.sh + the lanes.
: "${BUDGET_DAILY:=""}"          # '' (default, dormant) | a USD number, e.g. 25 — daily spend ceiling; see capabilities.tsv / cost.sh
# INFRA-timeout circuit breaker (HERD-110) — stop the watcher re-dispatching gates into a dead/hung
# environment. INFRA_BREAKER_MAX consecutive INFRA failures (non-verdict reviewer deaths — a claude
# exec-hang / env failure, NOT a real PASS/BLOCK verdict) OPEN a GLOBAL breaker: new review/health
# dispatch stops, a loud 'infra circuit open' row + journal event surface, and after
# INFRA_BREAKER_COOLDOWN seconds the breaker goes HALF-OPEN for a single probe retry (a real verdict
# closes it, another death re-opens it). Default 0 = OFF → every breaker path is a no-op and behavior
# is byte-identical to before. A real BLOCK verdict NEVER trips it. Consumed by agent-watch.sh.
: "${INFRA_BREAKER_MAX:="0"}"         # 0/unset = off (byte-inert); N>=1 = open after N consecutive INFRA (non-verdict) failures
: "${INFRA_BREAKER_COOLDOWN:="300"}"  # seconds the breaker stays OPEN before a single half-open probe retry (non-numeric → 300)
# HERD-447: the Python engine core (pysrc/herd/live_runtime.py) now ALSO consults/records the breaker
# (the gate read was restored — see docs/engine-contract.md §3.3) and reads these two the SAME way
# HEALTH_CONCURRENCY etc. do (`_CORE_ENV_KEYS`, HERD-449) — as a CHILD process's os.environ, which only
# sees an EXPORTED var. Without this export a project's configured INFRA_BREAKER_MAX/COOLDOWN would
# reach the bash breaker helpers (same-shell vars, no export needed) but silently fall back to the
# python engine's built-in 0/300 defaults — the exact HERD-449 bug class, caught here before it shipped
# by scripts/herd/env-export-lint.sh rather than discovered live a fourth time.
#
# This is also the LAST of _HERD_ENGINE_CORE_KEYS to resolve a `: "${KEY:=default}"` value (the two
# lines directly above), so the export for the WHOLE list — the HERD-465 counterpart to the RESET at
# the top of this file — happens HERE, once every member has its final value. Written as a literal
# `export NAME NAME ...` statement, NOT a loop over the variable: scripts/herd/hermetic-env-scrub.sh
# (HERD-458) TEXT-SCANS this file for literal `export` statements to seal hermetic tests off from a
# configured project's live values, and a `export "$var"` loop is invisible to that scanner — every
# name below MUST stay byte-identical to _HERD_ENGINE_CORE_KEYS above (tests/test-config-env-precedence.sh
# cross-checks the two so this can't silently drift).
export MERGE_POLICY WATCHER_AUTOMERGE HUMAN_VERIFY_POLICY MERGE_METHOD \
       DELETE_BRANCH_ON_MERGE REFIX_MAX_ROUNDS REFIX_COMPLETE_MIN HERD_REFIX_WAIT_TIMEOUT \
       WORK_UNIT_KIND MERGE_RESULT_GATE MERGE_QUEUE HEALTH_CONCURRENCY REVIEW_CONCURRENCY \
       WATCHER_SCOPE WATCHER_VIEW WATCHER_VIEW_AUTHOR WATCHER_VIEW_ASSIGNEE WATCHER_VIEW_LABEL \
       WATCHER_VIEW_STATUS WATCHER_VIEW_DEPS_LABEL WATCHER_OWNER GATE_STATUS GATE_STATUS_PENDING \
       MERGE_FAIRNESS MERGE_FAIRNESS_STARVE_THRESHOLD INFRA_BREAKER_MAX INFRA_BREAKER_COOLDOWN \
       HEALTH_TRUST_BUILDER STALE_BASE_AUTOFIX HEALTH_SOURCE CORE_SURFACE_GLOB AUTOFIX_SCOPE
# Claude exec-hang probe (HERD-108) — some environments WEDGE `claude` on invocation (every exec hangs
# before the process finishes starting, e.g. the macOS com.apple.quarantine _dyld_start hang). A wedged
# claude makes every review/refix dispatch spawn a corpse, so the poll loop burns cycles against a hang
# it cannot see. When armed, the watcher probes `claude --version` under a HARD timeout ONCE per tick
# before dispatching; a timeout HOLDS review dispatch for that tick with a loud row + a journal
# infra_event (the doctor's own `claude responds` probe reports the same hang at diagnosis time). 0 =
# OFF (byte-inert; no probe exec, no journal, behavior byte-identical); N>=1 = probe timeout in seconds.
# Consumed by pysrc/herd/live_runtime.py (the shipped live review dispatch, HERD-580 port); the bash
# body (agent-watch.sh) is unreachable since the P5b engine port and is kept only for its own unit test.
# Only a genuine timeout counts as a hang — a broken/absent claude is fail-soft (never holds the queue).
# A small value like 5 is a conservative arm for unattended runs.
: "${WATCH_CLAUDE_PROBE_TIMEOUT:="0"}"  # 0/unset = off (byte-inert); N>=1 = `claude --version` probe timeout (seconds)

# ── Claude Code custom endpoint (HERD-171) ───────────────────────────────────
# ANTHROPIC_BASE_URL relocates the endpoint the claude runtime talks to (enterprise/BAA gateway or
# a local model server). Empty/unset => Claude Code default Anthropic endpoint (byte-identical). The
# key is MACHINE-scoped + secrets-adjacent: herd config set routes it to the gitignored
# .herd/config.local, never the committed baseline, because a tenant/gateway URL is not project
# policy. Companion credentials (ANTHROPIC_API_KEY) live in .herd/secrets or the control-room process
# env, never here (this file stays ZERO-SECRET). When non-empty we EXPORT so oneshot/headless children
# inherit it; scripts/herd/driver.sh also injects it as --env on herdr agent start so interactive
# spawns hit the same endpoint. Composes with the model matrix (HERD-151): MODEL_* still pick the
# model id; this only moves the wire. See docs/sensitive-data.md.
: "${ANTHROPIC_BASE_URL:=}"
[ -n "${ANTHROPIC_BASE_URL}" ] && export ANTHROPIC_BASE_URL

# ── Per-project GH_TOKEN passthrough (HERD-671 leg 3) ─────────────────────────
# GitHub rate limits are PER USER, not per token: several projects/watchers on one machine sharing
# the operator's plain `gh auth login` identity all draw from the SAME 5000/hr GraphQL bucket, so a
# heavy evening on one project can starve every other watcher's gate/merge reads (GROUNDED 2026-08-13,
# HERD-671: four watchers here exhausted it together). An optional GH_TOKEN in THIS project's
# .herd/secrets partitions a project onto its OWN bucket — but only when it names a DIFFERENTLY-OWNED
# identity (a machine account or a GitHub App installation token); a second personal PAT for the same
# human account still shares that human's one bucket and partitions nothing. `gh` (and `gh api
# graphql`) already prefers GH_TOKEN/GITHUB_TOKEN over stored `gh auth login` credentials the moment
# it is present in the process environment, so exporting it here IS the whole integration — no other
# seam needs to change to use it.
#
# Read directly (grep one line, never sourced) so this file stays ZERO-SECRET: no other line of
# .herd/secrets, nor its execution, ever reaches this process — only the single value the caller
# already opted into. FAIL-SOFT + byte-identical when absent: an already-exported GH_TOKEN (the
# operator's own shell, or a CI runner) wins over the file so this is layered under any existing
# call-site convention rather than fighting it; no file / unreadable / no GH_TOKEN line => nothing is
# exported and `gh` falls back to its already-authenticated identity exactly as before this key
# existed. See docs/sensitive-data.md (Part 3) for the machine-account requirement.
if [ -z "${GH_TOKEN:-}" ] && [ -n "${PROJECT_ROOT:-}" ] && [ -r "${PROJECT_ROOT}/.herd/secrets" ]; then
  # `|| true` is load-bearing under a caller's `set -e -o pipefail` (e.g. new-feature.sh): with
  # pipefail on, grep's exit 1 on "no GH_TOKEN line" (the common case) propagates as the WHOLE
  # pipeline's status even though tail/sed both succeed on empty input — without this guard, sourcing
  # this file from any set -e caller aborted the caller entirely the moment a project's .herd/secrets
  # had no GH_TOKEN line (GROUNDED: broke new-feature.sh for every worktree spawn, caught by CI on
  # test-builder-secrets-isolation.sh / test-cli-backend-switch.sh / test-adopt-worktree-prep.sh).
  _herd_gh_token_raw="$(grep -E '^[[:space:]]*(export[[:space:]]+)?GH_TOKEN[[:space:]]*=' \
    "${PROJECT_ROOT}/.herd/secrets" 2>/dev/null | tail -n1 \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?GH_TOKEN[[:space:]]*=[[:space:]]*//; s/[[:space:]]*#.*$//')" || true
  case "$_herd_gh_token_raw" in
    \"*\") _herd_gh_token_raw="${_herd_gh_token_raw#\"}"; _herd_gh_token_raw="${_herd_gh_token_raw%\"}" ;;
    \'*\') _herd_gh_token_raw="${_herd_gh_token_raw#\'}"; _herd_gh_token_raw="${_herd_gh_token_raw%\'}" ;;
  esac
  [ -n "$_herd_gh_token_raw" ] && export GH_TOKEN="$_herd_gh_token_raw"
  unset _herd_gh_token_raw
fi

# ── Atomic work-item claiming (HERD-50) ──────────────────────────────────────
# CLAIM_REQUIRED gates the synchronous pre-spawn CLAIM step the lanes (herd-quick.sh /
# herd-feature.sh) run BEFORE creating a worktree, via scripts/herd/herd-claim.sh. It exists to
# stop two operators working the same repo from double-building one backlog item: today picking is
# check-then-act (a coordinator reads `herd backlog`, spawns a builder, THEN enqueues an async
# `mark in-progress` the scribe drains minutes later — a second coordinator can pick the same item
# inside that window and the idempotent scribe never rejects the duplicate).
#
# OFF by default → today's behavior EXACTLY (no claim; the async scribe mark-in-progress path is the
# only state write). When ON, and ONLY when a tracker id is present (HERD_CLAIM_ID, else the
# HERD_ITEM_REF the coordinator already threads for tracked items), the lane reads the item's CURRENT
# state+assignee synchronously through the active SCRIBE_BACKEND's _backend_claim_item op, sets it
# In Progress + assigned to the operator identity (WATCHER_OWNER, else `gh api user`), and RE-READS to
# verify the claim stuck. An item already claimed by ANOTHER identity aborts the spawn loudly (no
# worktree, no agent). No-id / unclaimed spawns still pass through to the async scribe unchanged, and a
# backend that is unreachable FAILS SOFT (warn + proceed) so a solo operator is never hard-blocked.
# Linear/GitHub have no compare-and-swap, so claim-verify NARROWS the race from minutes to seconds
# rather than eliminating it; the file backend's claim is a git-committed state flip made atomic by
# push serialization (the loser's push is rejected, a re-pull shows the item claimed, and it aborts).
: "${CLAIM_REQUIRED:="off"}"     # off (default) → no claim, today's async-scribe behavior; on → claim id-bearing spawns

# ── Claim RELEASE on an abandoned builder (HERD-162 F12) ─────────────────────
# A claim is taken before the worktree and, until now, released by nothing. When the builder that
# claimed an item DIES before it ever opens a PR, the item stays In Progress + assigned forever: the
# other operator's `herd-claim.sh` reads it as ALREADY and aborts, so a wedged item can never be
# re-picked by anyone but the original claimant, by hand. CLAIM_RELEASE closes that loop from the
# watcher's dead-builder reconcile.
#
# off (DEFAULT) → byte-inert: no read, no tracker write, no journal event, and the 💀 notification is
#                 the pre-HERD-162 string verbatim.
# flag          → OBSERVE ONLY: journal a claim_release_flagged event naming the wedged ref and say so
#                 on the 💀 notification. NO tracker write — a human (or the coordinator) re-queues it.
# release       → also RELEASE the claim through the active SCRIBE_BACKEND's _backend_release_item op:
#                 clear the assignee that marks the claim, so the item is re-pickable. The item's
#                 workflow STATE is left alone — reopening/re-queuing stays a coordinator act.
#
# HARD RAILS, in both non-off modes. A claim is released ONLY for a builder that is genuinely
# abandoned: dead, with a CLEAN worktree (no commits, no dirt), and NOT being auto-respawned. A dead
# builder that left work is a human-recovery hold — releasing it would invite a second operator to
# build a duplicate on top of unrecovered work — and a respawned builder still owns its item. A
# backend with no release op FAILS SOFT to `flag` (never a red, never a hard error).
: "${CLAIM_RELEASE:="off"}"      # off (default) → today's behavior; flag → journal+surface only; release → clear the claim

# ── Tracker-routed spawn enforcement (HERD-64) ───────────────────────────────
# TRACKED_SPAWNS makes "every builder is traceable to a tracked work item" a PROJECT POLICY the
# committed baseline binds on all operators, instead of a convention the coordinator is merely asked
# to follow. It gates the lanes (herd-quick.sh / herd-feature.sh) and the durable spawn queue
# (spawn.sh) on the presence of a tracker ref, via herd_tracked_spawn_or_abort below.
#
# off (DEFAULT) → today's behavior EXACTLY: no gate, spawns proceed with or without a ref.
# required      → a spawn carrying NO tracker ref (HERD_CLAIM_ID, else the HERD_ITEM_REF the
#                 coordinator threads for tracked items) is REFUSED with a loud one-line reason and
#                 creates nothing. HERD_FORCE_SPAWN=1 (or the lanes' --force) is the explicit escape
#                 hatch: it lets an unref'd spawn through and JOURNALS the bypass (tracked_spawn_bypassed).
# Any value other than "required" is treated as off (safe default).
#
# INTERPLAY with CLAIM_REQUIRED (HERD-50): the ref set is IDENTICAL (HERD_CLAIM_ID:-HERD_ITEM_REF), so
# with BOTH on the same id both satisfies this gate AND is atomically CLAIMED before the worktree —
# every spawn is then visible in the tracker AND raced-safe. The two are orthogonal: TRACKED_SPAWNS
# enforces VISIBILITY (a ref exists), CLAIM_REQUIRED enforces EXCLUSIVITY (no double-build).
: "${TRACKED_SPAWNS:="off"}"     # off (default) → today's behavior; required → refuse a ref-less spawn

unset _HERD_SCRIPT_DIR _HERD_REPO_DEFAULT _HERD_CONFIG_FILE _HERD_CONFIG_SOURCE _HERD_CONFIG_LOCAL_FILE

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
  # HERD-310: the ONE test-safety seam for the tab-close path. Closing the {slug, review·slug,
  # resolve·slug} tabs here severs an in-flight review and kills the builder agent — catastrophic when
  # a test drives this against the operator's LIVE socket from a builder worktree. From the control
  # room (main checkout) the guard is a no-op, so a real merge/retirement teardown is byte-identical.
  if command -v herd_context_pane_guard >/dev/null 2>&1 \
     && ! herd_context_pane_guard "herd_teardown_slug $_td_slug (tab close)"; then
    return 0
  fi
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

# ── SHARE_LINKS worktree preparation — ONE implementation, every surface (HERD-535, GH #660) ──────
#
# SHARE_LINKS (from .herd/config) are the GITIGNORED shared dirs that live only in the main checkout —
# a project's build/import caches (`node_modules`, `.venv`, `target`, `.godot`, …). `git worktree add`
# checks out TRACKED files only, so a fresh worktree has none of them and its suite cannot import,
# build, or run anything.
#
# EXTRACTED here from new-feature.sh, where this pass was lane-inline. The builder lanes ran it; the
# ADOPT_REMOTE_PRS leg of agent-watch.sh — which creates worktrees with a bare `git worktree add` —
# did not. Every adopted PR then red its healthcheck on missing caches (measured in emberglen-godot:
# lane worktrees carry the 34-45MB `.godot/` cache, adopted ones carried none; 12/12 probes red,
# `health_codeerror`) in a way indistinguishable from the branch breaking everything, so the autofix
# rails bounced builders at phantom bugs. One implementation, both surfaces — never a second,
# independently-invented preparation pass that can drift.
#
# herd_share_link_exposes_secrets <share> — the HERD-87 guard: true when <share> IS, CONTAINS, or SITS
# UNDER `.herd/secrets`, the work tracker's API credentials. Builders run with tool permissions skipped,
# so a symlink to `.herd` (which holds the secrets file) or to `.herd/secrets` itself would let a builder
# read the key and mutate tracker state, violating "the coordinator owns all backlog/tracker updates".
# Main-checkout filesystem permissions are out of scope; this closes only the provisioned-link vector.
herd_share_link_exposes_secrets() {
  local _sle_s="${1#./}"; _sle_s="${_sle_s%/}"     # normalize ./x and a trailing slash
  case "$_sle_s" in
    .herd/secrets|.herd/secrets/*) return 0 ;;     # the secrets file, or anything under it
    ""|.|.herd) return 0 ;;                        # the repo root or the whole .herd dir contains it
  esac
  return 1
}

# herd_share_links_prepare <worktree-dir> [<repo-root>] — symlink every SHARE_LINKS dir from the main
# checkout into <worktree-dir>. <repo-root> defaults to $PROJECT_ROOT.
#
# Sets HERD_SHARE_LINKS_COUNT to the number of links this pass actually CREATED — 0 when SHARE_LINKS is
# empty, when every share was refused, or when none of them exist in the main checkout. That count is
# the `links=N` an adoption journals, and the signal a caller uses to tell "prepared" from "there was
# nothing to prepare". Because it sets a caller-visible variable, NEVER call this in a `$(…)` subshell.
#
# Returns 0 when every requested share was HANDLED — linked, skipped because it does not exist in the
# main checkout, skipped because it is already present in the worktree, or refused by the secrets guard
# — and 1 when a link could not be created (or the worktree/repo path is unusable). Refusing a dangerous
# share is FAIL-SOFT and never fails the pass: the safe shares are still provisioned.
#
# CALLERS DECIDE what a failure means, which is why this function itself is neither fatal nor silent:
# a lane treats it as fatal (never report success on a half-built worktree), the ADOPT_REMOTE_PRS leg
# treats it as an unprepared-worktree marker so a cache-red is never painted as a plain code error.
herd_share_links_prepare() {
  local _slp_dir="${1:-}" _slp_repo="${2:-${PROJECT_ROOT:-}}" _slp_share _slp_target _slp_link _slp_rc=0
  HERD_SHARE_LINKS_COUNT=0
  [ -n "$_slp_dir" ] && [ -d "$_slp_dir" ] || return 1
  [ -n "$_slp_repo" ] && [ -d "$_slp_repo" ] || return 1
  # Unquoted on purpose: SHARE_LINKS is a SPACE-SEPARATED list of dirs.
  # shellcheck disable=SC2086
  for _slp_share in ${SHARE_LINKS:-}; do
    if herd_share_link_exposes_secrets "$_slp_share"; then
      printf '%s\n' "🚫 refusing SHARE_LINK '$_slp_share': it would expose .herd/secrets into the builder worktree (HERD-87)." >&2
      printf '%s\n' "   Builders must never reach tracker credentials; the coordinator owns all tracker state. Skipping this link." >&2
      continue
    fi
    _slp_target="$_slp_repo/$_slp_share"
    _slp_link="$_slp_dir/$_slp_share"
    if [ ! -e "$_slp_target" ]; then
      printf '%s\n' "⚠️  skip symlink: $_slp_target does not exist in the main checkout." >&2
      continue
    fi
    # Already provisioned (a re-run over an existing worktree, or the tree carries its own copy of the
    # path) — never clobber what is already there, and never count it as work this pass did.
    if [ -e "$_slp_link" ] || [ -L "$_slp_link" ]; then
      continue
    fi
    if ! ln -s "$_slp_target" "$_slp_link" || [ ! -e "$_slp_link" ]; then
      printf '%s\n' "❌ Failed to symlink $_slp_link -> $_slp_target" >&2
      _slp_rc=1
      continue
    fi
    HERD_SHARE_LINKS_COUNT=$((HERD_SHARE_LINKS_COUNT + 1))
  done
  return "$_slp_rc"
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
# HERD-525 / GH #638: the SENTINEL PATH embedded in the generated hook command is resolved AT HOOK
# RUNTIME, never baked in at generate time. A prior version embedded this worktree's `pwd -P` (an
# absolute, machine-specific path) directly into the hook command string written into
# .claude/settings.json; in a two-operator repo (e.g. macOS vs WSL checkouts of the SAME commit) that
# committed file then ping-pongs between each operator's absolute path forever, and on whichever
# machine the OTHER operator's path is checked out, the hook writes to a path that doesn't exist on
# that box — auto-resume silently degrades to the banner-scrape fallback. The generated command
# instead computes the sentinel path from `$CLAUDE_PROJECT_DIR` (the project root Claude Code exports
# into every hook's environment) with a `$PWD` fallback for harnesses that don't set it — ONE portable
# form for both the main checkout and any worktree, so the generated file is byte-identical no matter
# which machine or checkout produced it. Regenerating over an old-style absolute hook converges it to
# this portable form once (the merge below replaces a mismatched `rate_limit` entry's command) and is
# then byte-stable on every subsequent call.
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
  mkdir -p "$_rh_abs/.claude" 2>/dev/null || return 0
  if ! HERD_RH_SETTINGS="$_rh_settings" python3 - <<'PY'
import json, os, shlex, sys, tempfile

path = os.environ["HERD_RH_SETTINGS"]

# The hook command. HERD-155 F3: a StopFailure/rate_limit hook's stdin is the harness EVENT — a JSON
# blob (session_id, transcript_path, a reason/message, …), NOT the bare reset banner. The old `cat >`
# wrote that whole blob, so a stray numeric field (a token count, an id fragment) could be misparsed
# downstream as a reset clock time. Instead EXTRACT just the usage-limit banner text — the anchored
# "reset at/in <time>" phrase, else any "usage/session limit" line — from whatever arrives (JSON or
# raw) and write only that. An empty write still marks "limit hit" (→ HERD_LIMIT_UNKNOWN_WAIT). If
# python3 is unavailable at hook time, the `|| : >` fallback writes an empty sentinel — never lost.
_extract = r'''import sys, re
raw = sys.stdin.read()
m = re.search(r'[^\n"]*reset[s]? (?:at|in)[^\n"]*', raw, re.I)
out = (m.group(0) if m else "").strip()
if not out:
    m = re.search(r'[^\n"]*(?:usage|session) limit[^\n"]*', raw, re.I)
    out = (m.group(0) if m else "").strip()
sys.stdout.write(out)
'''
# HERD-525: the sentinel's DIRECTORY is resolved by the shell AT HOOK RUNTIME — never baked in here —
# so the same generated command is byte-identical whichever worktree/machine/checkout produced it.
# CLAUDE_PROJECT_DIR is the project root Claude Code exports into every hook's environment; $PWD is
# the fallback for a harness that doesn't set it (hook commands run with cwd == the project root).
q_sentinel = '"$_herd_rl_dir/.herd-limit-sentinel"'
cmd = "_herd_rl_dir=\"${CLAUDE_PROJECT_DIR:-$PWD}\"; python3 -c %s > %s 2>/dev/null || : > %s" % (
    shlex.quote(_extract), q_sentinel, q_sentinel,
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

# ── Builder context-provisioning surface (HERD-40) ───────────────────────────────────────────────
# herd_context_provision_preamble — emit the grounding block injected into the STABLE region of a
# builder's task-spec preamble, so spawned builders start GROUNDED instead of re-exploring the repo
# every session. Driven by the CONTEXT_PROVISION config key: a SPACE-SEPARATED list of grounding
# sources to inject. Empty/unset (the DEFAULT) → this prints NOTHING and the task spec stays
# byte-identical to today (zero behavior change).
#
# Contract the lanes rely on (herd-quick.sh / herd-feature.sh):
#   • The output is a run of ' '-prefixed sentences the lane appends to the STABLE workflow-rules
#     preamble — NEVER interleaved with the per-task text, so the prompt-cache prefix that many
#     close-in-time spawns share stays intact. The block is project-config-constant (same for every
#     spawn of a project), so it lives entirely inside the cached region.
#   • It is placed BEFORE the per-item-unique trailer ($REFS_RULE) so the shared cache prefix stays
#     maximal — same cache-aware discipline as the SPEC ordering in the lanes.
#
# EXTENSIBLE by design: each token maps to ONE case below that appends its pointer, so future
# grounding sources (project context notes, MCP tool hints) plug in as new cases without reworking the
# lanes. An UNKNOWN token is IGNORED (forward-compatible: an operator whose engine predates a source
# they configured just gets no injection for it, never an error).
#
# FIRST supported source — 'codemap': the deterministic engine-tree map produced by `herd codemap`
# (scripts/herd/codemap.sh) and committed at docs/codemap.md. The pointer tells the builder to read it
# FIRST to orient (module roles, source edges, config-key → consumer wiring) instead of re-scanning.
#
# 'agents-md' (HERD grok-context-injection): unlike the pointer sources above, this INLINES the actual
# content of the repo-root AGENTS.md (and CLAUDE.md if present) into the STABLE preamble — so a runtime
# that does NOT auto-load CLAUDE.md (grok, codex) still carries the project conventions in its task
# spec, not just a pointer it might skip. Fail-soft: no AGENTS.md/CLAUDE.md at the root → this source
# emits NOTHING (byte-identical to leaving it off). Driver-agnostic: the same inlined block lands in
# every driver's task spec, so a claude spec and a grok spec stay byte-identical.
herd_context_provision_preamble() {
  local _cp="${CONTEXT_PROVISION:-}"
  [ -n "$_cp" ] || return 0     # off (default) → emit nothing; task specs are byte-identical to today
  local _out="" _src
  for _src in $_cp; do
    case "$_src" in
      codemap)
        _out="$_out A deterministic map of this repo's engine tree is committed at docs/codemap.md (module roles, who-sources-whom, and config-key→consumer wiring; regenerate with 'herd codemap'). READ IT FIRST to orient — it lets you skip re-exploring the tree." ;;
      symbol-index)
        _out="$_out A function-level symbol index (definition sites + cross-file callers for functions under bin/ and scripts/herd/) is committed at docs/symbol-index.md; use it to jump to a function's def or its likely callers instead of grepping, and regenerate with 'herd symbol-index'. HONEST SCOPE: a heuristic token scan, not ground truth — same-name defs and dynamic dispatch are ambiguous." ;;
      agents-md)
        local _conv; _conv="$(herd_agents_conventions)"
        [ -n "$_conv" ] && _out="$_out"$'\n\n--- PROJECT CONVENTIONS (repo-root AGENTS.md / CLAUDE.md — read + follow these) ---\n'"$_conv" ;;
      *) : ;;   # unknown grounding source — ignore (forward-compatible)
    esac
  done
  printf '%s' "$_out"
}

# herd_agents_conventions [root] — print the repo-root project conventions (AGENTS.md, then CLAUDE.md
# if present) as ONE block, or NOTHING when neither exists. The single source of truth for two
# consumers: the 'agents-md' grounding source above (inlines it into every builder's task spec) and
# the grok driver spawn (grounds grok's system prompt from it, since grok — unlike Claude Code — does
# not auto-load CLAUDE.md). <root> defaults to $PROJECT_ROOT (the main worktree the engine resolved),
# so the canonical committed conventions are read regardless of the caller's cwd. PURE + FAIL-SOFT: an
# absent/unreadable file contributes nothing; neither file → empty output, never an error.
herd_agents_conventions() {
  local _root="${1:-${PROJECT_ROOT:-.}}" _out="" _f
  for _f in AGENTS.md CLAUDE.md; do
    if [ -f "$_root/$_f" ] && [ -r "$_root/$_f" ]; then
      [ -n "$_out" ] && _out="$_out"$'\n\n'
      _out="$_out$(cat "$_root/$_f" 2>/dev/null)"
    fi
  done
  printf '%s' "$_out"
}

# ── Tracker-routed spawn enforcement (HERD-64) ───────────────────────────────────────────────────
# herd_tracked_spawn_or_abort <slug> [forced] — the shared gate the spawn surfaces (herd-quick.sh /
# herd-feature.sh / spawn.sh) call BEFORE creating anything, to make tracker-routed spawns a project
# POLICY rather than an operator convention. Driven by the TRACKED_SPAWNS config key.
#
# CONTRACT (returns 0 to PROCEED, non-zero to ABORT):
#   • TRACKED_SPAWNS anything but 'required' (default 'off') → return 0 immediately. Byte-for-byte
#     today's behavior — no gate, nothing printed.
#   • required + a tracker ref present (HERD_CLAIM_ID, else the HERD_ITEM_REF the coordinator threads)
#     → return 0. The SAME ref set herd-claim.sh uses, so one id satisfies both gates.
#   • required + NO ref + NOT forced → print ONE loud reason to stderr and return NON-ZERO. The caller
#     exits before creating a worktree/agent/queue-intent.
#   • required + NO ref + forced (arg2 truthy OR HERD_FORCE_SPAWN=1) → JOURNAL the bypass
#     (tracked_spawn_bypassed) if journal_append is available, print a loud one-line notice, return 0.
#
# forced (arg2) lets a lane pass its already-resolved --force/-f state; HERD_FORCE_SPAWN=1 in the
# environment is honored regardless (the escape hatch spawn.sh, which parses no flags, relies on).
herd_tracked_spawn_or_abort() {
  local _tk_slug="${1:-?}" _tk_forced="${2:-}"
  case "${TRACKED_SPAWNS:-off}" in
    required) ;;
    *) return 0 ;;
  esac
  local _tk_id="${HERD_CLAIM_ID:-${HERD_ITEM_REF:-}}"
  [ -n "$_tk_id" ] && return 0
  # No tracker ref under an active policy. Forced by the lane arg OR the env escape hatch?
  case "$_tk_forced"          in 1|true|yes|on) _tk_forced=1 ;; *) _tk_forced="" ;; esac
  case "${HERD_FORCE_SPAWN:-}" in 1|true|yes|on) _tk_forced=1 ;; esac
  if [ "$_tk_forced" = "1" ]; then
    command -v journal_append >/dev/null 2>&1 \
      && journal_append tracked_spawn_bypassed slug "$_tk_slug" reason "no tracker ref; HERD_FORCE_SPAWN bypass"
    echo "⚠️  TRACKED_SPAWNS=required but '$_tk_slug' carries no tracker ref — HERD_FORCE_SPAWN set, spawning anyway (bypass journaled)." >&2
    return 0
  fi
  echo "🛑 TRACKED_SPAWNS=required: refusing to spawn '$_tk_slug' with no tracker ref — thread HERD_ITEM_REF=<id> (or HERD_CLAIM_ID) on the spawn, or set HERD_FORCE_SPAWN=1 to bypass (bypass is journaled)." >&2
  return 1
}

# ── Builder MCP tool provisioning (HERD-41) ──────────────────────────────────────────────────────
# herd_write_mcp_servers <worktree> — wire the project-configured MCP servers into THIS worktree's
# project-level Claude Code settings (<worktree>/.claude/settings.json → the `mcpServers` block), so a
# spawned builder can reach them as needed without any per-session setup. The SIBLING of
# herd_context_provision_preamble (HERD-40): that surface grounds a builder with repo CONTEXT; this
# one provisions its TOOLS. Driven by the MCP_PROVISION config key: a SPACE-SEPARATED list of MCP
# server names to wire. Empty/unset (the DEFAULT) → this touches NOTHING and settings.json stays
# byte-identical to today (zero behavior change). Disable regardless of config with HERD_MCP_PROVISION=off.
#
# The write reuses the EXACT discipline of herd_write_ratelimit_hook — ADDITIVE + SAFE:
#   • Merges into an existing .claude/settings.json (never clobbers the rate-limit hook, unrelated
#     keys, or any OTHER mcpServers entry). NON-CLOBBER is per-ENTRY: a server already present in the
#     file (a user/hand-authored one, same name) is LEFT UNTOUCHED — we only ADD servers not there yet.
#   • Idempotent: re-running once a server is wired changes nothing (byte-identical, no rewrite).
#   • Atomic: round-trips through a temp file + os.replace; tolerates a missing/corrupt settings file.
#   • Best-effort: any failure warns but returns 0, so it never aborts worktree creation.
#
# EACH server name resolves to a {command, args, env} entry from a BUILT-IN default (below) that a
# per-server config override can replace: MCP_<NAME>_COMMAND / MCP_<NAME>_ARGS / MCP_<NAME>_ENV, where
# <NAME> is the server name upper-cased with '-'/'.' → '_' (context7 → MCP_CONTEXT7_*, graphify-mcp →
# MCP_GRAPHIFY_MCP_*). A name with NO built-in AND no _COMMAND override is IGNORED (forward-compatible:
# an operator naming a server this engine predates gets no wiring for it, never an error).
#
# PRIVACY — credentials are NEVER written into the generated settings.json. MCP_<NAME>_ENV (and the
# built-in env list) is a SPACE-SEPARATED list of env-var NAMES to pass through; we write only the
# reference string "${VAR}" into the server's env block, which Claude Code expands from the runtime
# environment at launch (populated from .herd/secrets via passthrough). No secret value ever lands in
# a committed or generated file, and DENY_PATHS stays honored (we only ever write under .claude/).
#
# BUILT-IN examples:
#   • context7 — up-to-date library docs (npx -y @upstash/context7-mcp; passes CONTEXT7_API_KEY through
#     from the environment). VALUABLE for CONSUMER projects herdkit runs on (a real code app querying
#     live library docs); herdkit itself is bash, so it is LOW-VALUE here — the MECHANISM is the point.
#   • graphify-mcp — a LOCAL example server (the `graphify` codemap tool's MCP surface, if installed).
herd_write_mcp_servers() {
  local _mp_dir="${1:-}"
  [ -n "$_mp_dir" ] || return 0
  [ "${HERD_MCP_PROVISION:-on}" != "off" ] || return 0
  local _mp_list="${MCP_PROVISION:-}"
  [ -n "$_mp_list" ] || return 0     # off (default) → touch nothing; settings.json byte-identical to today
  if ! command -v python3 >/dev/null 2>&1; then return 0; fi
  local _mp_abs
  _mp_abs="$(cd "$_mp_dir" 2>/dev/null && pwd -P)" || _mp_abs="$_mp_dir"
  local _mp_settings="$_mp_abs/.claude/settings.json"
  mkdir -p "$_mp_abs/.claude" 2>/dev/null || return 0

  # Resolve each name → a TAB-separated  name<TAB>command<TAB>args<TAB>env  row (built-in default,
  # then per-server config override). Python parses this spec and builds the JSON safely. Args/env are
  # space-separated; the `-__UNSET__` default distinguishes an explicit empty override ("") from unset.
  local _mp_spec="" _mp_name _mp_up _mp_cmd _mp_args _mp_env _mp_ov
  for _mp_name in $_mp_list; do
    _mp_up="$(printf '%s' "$_mp_name" | tr '[:lower:].-' '[:upper:]__')"
    _mp_cmd=""; _mp_args=""; _mp_env=""
    case "$_mp_name" in
      context7)     _mp_cmd="npx"; _mp_args="-y @upstash/context7-mcp"; _mp_env="CONTEXT7_API_KEY" ;;
      graphify-mcp) _mp_cmd="graphify-mcp"; _mp_args="";                _mp_env="" ;;
      *) : ;;   # no built-in — only a _COMMAND override can wire it (else ignored below)
    esac
    eval "_mp_ov=\"\${MCP_${_mp_up}_COMMAND:-}\"";        [ -n "$_mp_ov" ]            && _mp_cmd="$_mp_ov"
    eval "_mp_ov=\"\${MCP_${_mp_up}_ARGS-__UNSET__}\"";   [ "$_mp_ov" != "__UNSET__" ] && _mp_args="$_mp_ov"
    eval "_mp_ov=\"\${MCP_${_mp_up}_ENV-__UNSET__}\"";    [ "$_mp_ov" != "__UNSET__" ] && _mp_env="$_mp_ov"
    [ -n "$_mp_cmd" ] || continue   # unknown server, no override → skip (forward-compatible)
    _mp_spec="${_mp_spec}${_mp_name}	${_mp_cmd}	${_mp_args}	${_mp_env}
"
  done
  [ -n "$_mp_spec" ] || return 0    # nothing resolvable → no write (settings.json stays byte-identical)

  if ! HERD_MCP_SETTINGS="$_mp_settings" HERD_MCP_SPEC="$_mp_spec" python3 - <<'PY'
import json, os, shlex, sys, tempfile

path = os.environ["HERD_MCP_SETTINGS"]
spec = os.environ.get("HERD_MCP_SPEC", "")

# Parse the bash-built spec: one  name<TAB>command<TAB>args<TAB>env  row per line.
want = {}
for line in spec.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    while len(parts) < 4:
        parts.append("")
    name, cmd, args, env = parts[0], parts[1], parts[2], parts[3]
    if not name or not cmd:
        continue
    entry = {"command": cmd}
    arglist = shlex.split(args) if args.strip() else []
    if arglist:
        entry["args"] = arglist
    envnames = env.split()
    if envnames:
        # PRIVACY: never embed a secret VALUE. Write only "${VAR}" reference strings; Claude Code
        # expands them from the runtime env (populated from .herd/secrets via passthrough) at launch.
        entry["env"] = {v: "${%s}" % v for v in envnames}
    want[name] = entry

if not want:
    sys.exit(0)

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

block = data.get("mcpServers")
if not isinstance(block, dict):
    block = {}

# NON-CLOBBER, per entry: a server already present (a user/hand-authored one, same name) is LEFT
# UNTOUCHED — we only ADD servers not already there. Idempotent: nothing new → no rewrite.
changed = False
for name, entry in want.items():
    if name in block:
        continue
    block[name] = entry
    changed = True

if not changed:
    sys.exit(0)

data["mcpServers"] = block

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
    printf '⚠️  herdkit: could not write MCP server wiring for %s (builder proceeds without it)\n' "$_mp_abs" >&2
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

# ── Project-defined branch naming (BRANCH_TEMPLATE, HERD-120) ─────────────────────────────────────
# feat/<slug> was hardcoded across the lanes (new-feature.sh), the resolver, and the watcher's
# dep-check fallback. These two helpers are the SINGLE seam every branch construction AND parse site
# routes through, so a project can rename its lanes' branches without the pieces drifting out of sync.
#
# The template lives in BRANCH_TEMPLATE (default 'feat/{slug}', byte-identical to the old hardcoded
# name when unset). Tokens: {slug} (required) and optional {ref} (the tracker id, e.g. HERD-120).
# FAIL-SOFT: a malformed template (missing {slug}) warns once and falls back to the default rather
# than producing an unusable branch — the no-false-red / never-strand-work discipline.
#
# render and parse are exact inverses for any template whose {slug} is delimited from its {ref}/prefix
# by a literal separator (e.g. 'feat/{slug}', '{ref}/{slug}', 'wip/{slug}', 'feat/{slug}-exp'), which
# covers every realistic naming scheme. The round-trip is locked by tests/test-branch-template.sh.

# _herd_branch_template — the effective template, with the malformed-template fallback applied ONCE.
# Warns to stderr (not stdout, so a render's captured output is never polluted) when it falls back.
_herd_branch_template() {
  # NB: never use ${BRANCH_TEMPLATE:-feat/{slug}} — the '}' inside the default word closes the
  # expansion early and appends a stray '}'. Resolve the default on its own line instead.
  local _bt="${BRANCH_TEMPLATE:-}"
  [ -n "$_bt" ] || _bt='feat/{slug}'
  case "$_bt" in
    *'{slug}'*) printf '%s' "$_bt" ;;
    *) echo "⚠️  BRANCH_TEMPLATE='$_bt' has no {slug} token — falling back to 'feat/{slug}'." >&2
       printf '%s' 'feat/{slug}' ;;
  esac
}

# ── Shared config-value validators (HERD-159) ─────────────────────────────────
# RULE: **gate keys fail strict; cosmetic keys fail soft.**
#   • Gate keys (MERGE_POLICY, HUMAN_VERIFY_POLICY, HEALTH_CONCURRENCY, REVIEW_CONCURRENCY,
#     SPAWN_AHEAD, …) control merge/hold/dispatch. An invalid value must NEVER silently take a
#     permissive path — fall back to the STRICTEST / safest default and warn loudly.
#   • Cosmetic keys (CODEMAP_AUTOREFRESH, WATCHER_FLAIR, …) are non-gating. An invalid value falls
#     back to the documented default and soft-warns (no silent no-op, no crash).
# The helpers themselves are posture-neutral: the CALLER chooses which default to pass (strictest for
# gates, documented default for cosmetic). Empty/unset always yields the default WITHOUT a warning
# (an unset key is intentional "use default", not a typo); a NON-EMPTY invalid value warns on stderr
# and returns exit 1 so the caller can journal / escalate.

# _herd_val_warn_once <KEY> <message> — print <message> to stderr at most once per KEY per process
# so a tick loop that re-resolves a bad value never spams the console. Side-channel is a per-pid
# marker file (not a shell var) because callers typically resolve via `$(herd_numeric …)` command
# substitution — a subshell cannot mutate the parent's `_HERD_VAL_WARNED`. The file lives under
# ${TMPDIR:-/tmp} and is keyed by pid so concurrent herd processes never share marks.
_herd_val_warn_once() {
  local _hw_key="${1:-}" _hw_msg="${2:-}"
  local _hw_f="${HERD_VAL_WARN_FILE:-${TMPDIR:-/tmp}/.herd-val-warned.$$}"
  if [ -n "$_hw_key" ] && [ -f "$_hw_f" ] && grep -qxF "$_hw_key" "$_hw_f" 2>/dev/null; then
    return 0
  fi
  [ -n "$_hw_key" ] && printf '%s\n' "$_hw_key" >> "$_hw_f" 2>/dev/null || true
  printf '%s\n' "$_hw_msg" >&2
}

# herd_enum <KEY> <default> <v1> [v2…] — resolve the env var named KEY against an allowed set.
# Prints the resolved value (the live value when it matches one of v1…, else <default>). Exit 0 when
# the live value is empty/unset OR one of the allowed values; exit 1 when a NON-EMPTY value was
# rejected (and a single stderr warning was printed, once per KEY). Safe under `set -e` when the
# caller captures the exit:  val="$(herd_enum KEY def a b || true)".
# Reads the LIVE env var on every call so a hermetic test (or a mid-process export) is honored.
herd_enum() {
  local _he_key="${1:-}" _he_def="${2:-}"
  [ -n "$_he_key" ] || { printf '%s' "$_he_def"; return 0; }
  shift 2 || true
  local _he_val
  # bash indirect expansion — KEY is the config key name, not a shell variable to pass by value.
  eval "_he_val=\"\${${_he_key}-}\""
  if [ -z "$_he_val" ]; then
    printf '%s' "$_he_def"
    return 0
  fi
  local _he_v
  for _he_v in "$@"; do
    if [ "$_he_val" = "$_he_v" ]; then
      printf '%s' "$_he_val"
      return 0
    fi
  done
  _herd_val_warn_once "$_he_key" \
    "⚠️  herdkit: invalid ${_he_key}=${_he_val} — falling back to ${_he_def}"
  printf '%s' "$_he_def"
  return 1
}

# herd_numeric <KEY> <default> — resolve the env var named KEY as a non-negative integer.
# Prints the live value when it is all digits (0-9, no sign/decimal); else prints <default>. Exit 0
# when empty/unset OR valid; exit 1 when a NON-EMPTY non-numeric value was rejected (warned once).
# An empty value is "use default" (no warn) so a config that never sets the key is silent.
# Reads the LIVE env var on every call so mid-process overrides (tests, `export KEY=N`) are honored.
herd_numeric() {
  local _hn_key="${1:-}" _hn_def="${2:-0}"
  [ -n "$_hn_key" ] || { printf '%s' "$_hn_def"; return 0; }
  local _hn_val
  eval "_hn_val=\"\${${_hn_key}-}\""
  if [ -z "$_hn_val" ]; then
    printf '%s' "$_hn_def"
    return 0
  fi
  case "$_hn_val" in
    ''|*[!0-9]*)
      _herd_val_warn_once "$_hn_key" \
        "⚠️  herdkit: invalid ${_hn_key}=${_hn_val} (not a non-negative integer) — falling back to ${_hn_def}"
      printf '%s' "$_hn_def"
      return 1
      ;;
    *)
      printf '%s' "$_hn_val"
      return 0
      ;;
  esac
}

# herd_intent_queue_on — THE resolver for the INTENT_QUEUE lever (HERD-630): 0 when armed, 1 when off.
# Lives here, in the file BOTH consumers already source (scripts/herd/spawn-step.sh's queue mechanics
# and agent-watch.sh's drain), so the two can never disagree about whether the priority policy is in
# effect — a per-surface copy of one rule is what docs/multi-seat-doctrine.md Rule 2 calls a
# correctness defect. Any unrecognized value reads as OFF: fail toward the byte-identical FIFO drain.
# Reads the LIVE env var on every call, so a test (or a mid-process override) is honored, exactly as
# herd_numeric/herd_enum do.
herd_intent_queue_on() {
  case "$(printf '%s' "${INTENT_QUEUE:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# herd_branch_render <slug> [ref] — echo the branch name for this slug (and optional tracker ref).
# {slug}/{ref} are substituted; an empty {ref} collapses the doubled/edge separator it would leave
# (so '{ref}/{slug}' with no ref → '<slug>', a valid branch) — the default 'feat/{slug}' path never
# hits that and stays byte-identical to feat/<slug>.
herd_branch_render() {
  local _br_slug="${1:-}" _br_ref="${2:-}" _br_out
  _br_out="$(_herd_branch_template)"
  _br_out="${_br_out//\{slug\}/$_br_slug}"
  _br_out="${_br_out//\{ref\}/$_br_ref}"
  # Collapse runs of '/' (an empty {ref} can leave '//' or a leading '/') and trim edge slashes.
  while case "$_br_out" in *//*) true ;; *) false ;; esac; do _br_out="${_br_out//\/\//\/}"; done
  _br_out="${_br_out#/}"; _br_out="${_br_out%/}"
  printf '%s' "$_br_out"
}

# herd_branch_parse <branch> — echo the slug encoded in <branch> under the active BRANCH_TEMPLATE
# (the inverse of herd_branch_render). Strips the template's literal prefix (everything up to {slug},
# with any {ref} treated as a wildcard) and its literal suffix (everything after {slug}). Empty when
# the branch does not fit the template. Mirrored inline by the watcher's orphan-tab sweep (python).
herd_branch_parse() {
  local _bp_tmpl _bp_pre _bp_post _bp_out="${1:-}"
  _bp_tmpl="$(_herd_branch_template)"
  _bp_pre="${_bp_tmpl%%\{slug\}*}"   # literal (+ maybe {ref}) BEFORE {slug}
  _bp_post="${_bp_tmpl#*\{slug\}}"    # literal (+ maybe {ref}) AFTER  {slug}
  # Strip the prefix. With a {ref} in it, drop up to the last occurrence of the separator that
  # trails the ref (e.g. '/'); otherwise drop the fixed literal prefix from the front.
  case "$_bp_pre" in
    *'{ref}'*) local _bp_sep="${_bp_pre##*\{ref\}}"; [ -n "$_bp_sep" ] && _bp_out="${_bp_out##*$_bp_sep}" ;;
    '')        : ;;
    *)         _bp_out="${_bp_out#"$_bp_pre"}" ;;
  esac
  # Strip the suffix. With a {ref} in it, cut from the first occurrence of the separator that
  # leads the ref; otherwise drop the fixed literal suffix from the end.
  case "$_bp_post" in
    *'{ref}'*) local _bp_sep2="${_bp_post%%\{ref\}*}"; [ -n "$_bp_sep2" ] && _bp_out="${_bp_out%%$_bp_sep2*}" ;;
    '')        : ;;
    *)         _bp_out="${_bp_out%"$_bp_post"}" ;;
  esac
  printf '%s' "$_bp_out"
}

# herd_branch_slug <branch> — the WORKTREE-SAFE slug for <branch>: herd_branch_parse's result, unless
# it is empty or still contains a literal '/' (the branch does not fit BRANCH_TEMPLATE), in which case
# it falls back to flattening every '/' in <branch> to '-'. A raw '/' left in a slug would nest a stray
# subdirectory under $TREES/<slug> instead of naming one worktree.
#
# ONE shared fallback used by BOTH candidate discovery (pysrc/herd/live_runtime.py:_branch_worktree_slug)
# and the ADOPT_REMOTE_PRS leg (agent-watch.sh:_adopt_remote_pr) — never a second, independently-invented
# slugifier (HERD-377). Their prior divergence — discovery derived the slug via herd_branch_parse's port
# while the adopt leg unconditionally flattened the RAW branch — is exactly what shipped the regression:
# the adopt leg checked PR #484 out at TREES/feat-python-draft-pr-hold while discovery resolved
# TREES/python-draft-pr-hold for the same branch, so the adopted PR sat dropped from candidates for an
# hour while pr_adopted had already claimed success.
herd_branch_slug() {
  local _bs_branch="${1:-}" _bs_slug
  _bs_slug="$(herd_branch_parse "$_bs_branch")"
  case "$_bs_slug" in
    ''|*/*) printf '%s' "$_bs_branch" | tr '/' '-' ;;
    *)      printf '%s' "$_bs_slug" ;;
  esac
}
