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
    # Apply the SAME fallbacks the main loader does. Written as explicit `-n` guards (the vars are
    # pre-initialised to "" just above), NOT the colon-equals defaulting idiom: the caps-sync gate
    # greps THIS file for that form as its "new config key" heuristic, so using it here would
    # false-trip it — the same reason the main-loader PROJECT_ROOT fallback below deliberately avoids
    # colon-equals.
    [ -n "$PROJECT_ROOT" ]   || PROJECT_ROOT="$path"
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

: "${DENY_PATHS:=""}"            # never committed; the scribe/local lane is scoped away from these
: "${REVIEW_CHECKLIST:=""}"     # project risk list injected into the review gate

: "${COORDINATOR_CMD:="/coordinator"}"  # the generated coordinator skill the control room runs
: "${HERD_VERSION:="1"}"
: "${HERD_REPO:=""}"            # <owner>/herdkit — where engine bugs escalate (herd report)
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
# GATE_DISPATCH (HERD-73) — serial (default) | parallel. Governs WHEN the watcher's action pass fires
# the pre-merge review relative to the healthcheck for a (pr,sha). serial → today's EXACT behavior,
# byte-identical: the review dispatches only AFTER the healthcheck outcome lands, so gate wall-clock is
# health + review. parallel → dispatch the review at the same action-pass tick the healthcheck starts,
# so the two gates overlap. The MERGE decision is UNCHANGED either way (still requires BOTH gates green);
# only the wall-clock overlaps. Tradeoff: a health-failed sha wastes one review run (cheap under
# REVIEW_ESCALATE_GLOB tiering). Unknown value → serial (fail safe). Consumed by agent-watch.sh.
: "${GATE_DISPATCH:="serial"}"   # serial (default) | parallel — see capabilities.tsv / agent-watch.sh
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
# review-once gate is unchanged. Unknown value → off (fail safe). Consumed by agent-watch.sh.
: "${DELTA_REVIEW:="off"}"       # off (default) | on — see capabilities.tsv / agent-watch.sh
: "${REVIEW_AUTOFIX:="false"}"   # auto-bounce BLOCK reviews to the builder agent (default off; set true to dogfood)
: "${REFIX_MAX_ROUNDS:="3"}"     # max auto-refix rounds per RAIL (review | health | stale); a rail's budget is refunded when its red resolves, and a derived per-PR ceiling of 3x bounds the whole PR; exhausting either escalates to needs-you
: "${HEALTHCHECK_AUTOFIX:="false"}"  # HERD-173: auto-bounce a reproduced healthcheck CODE ERROR to the builder agent, on the same rails as REVIEW_AUTOFIX — true | false (default false). true → the watcher delivers the failing test + the tailable suite log to the builder's agent pane, once per (pr,sha), spending the HEALTH rail's own round budget (REFIX_MAX_ROUNDS per rail, refunded when the suite next goes CLEAN; a per-PR 3x total ceiling still bounds the PR); the same limit-parked / dead-agent preflights apply, and the cap escalates to a needs-you row. A tab-leak-guard trip is infra, never bounced. false (default) → no bounce, no ledger write, no re-task prompt: the gate decision is unchanged and the red row still holds the PR. Consumed by agent-watch.sh
: "${CODEMAP_AUTOREFRESH:="true"}"  # after a PR merges, the watcher regenerates docs/codemap.md and commits it direct to the default branch (deterministic, LLM-free); off → the watcher never touches the codemap
: "${MAIN_HEALTH_TICK:="off"}"   # HERD-129 / HERD-222: main-health as a RECONCILED INVARIANT — every observed default-branch sha ends with a collected health verdict, whoever merged it. on → each tick the watcher runs the healthcheck against the current default-branch HEAD when that sha has no verdict yet (this seat's merge, ANOTHER seat's merge, a gh-UI merge, a deferred no-slot tick, a worker killed mid-suite); a reproduced red raises a loud persistent 'MAIN RED' alarm row + notification, cleared when a later sha goes green. Catches the failure the per-PR gate structurally cannot: two independently-green PRs merging into a broken combination. ALARM only — never gates/reverts/re-merges. off (default) → byte-inert: no suite, no journal, no row
: "${MAIN_HEALTH_RECHECK_MINS:="0"}"  # HERD-222: while MAIN_HEALTH_TICK holds main RED, RE-VERIFY the CURRENT sha every N minutes so a stale red self-heals through the ordinary green→clear path instead of shouting until the next merge (a real red once stood 19h). 0 (default, off) → byte-identical: a sha with a verdict is never re-run. N>0 → at most one re-verify per N minutes, subject to the same HEALTH_CONCURRENCY slot and per-sha dispatch guards; a non-numeric value reads as 0 (a typo can never arm it). Consumed by agent-watch.sh
: "${MAIN_HEALTH_AUTOFIX:="off"}"  # HERD-222: auto-REMEDIATE a reproduced MAIN RED — on | off (default off, ship-dormant). on → when the main-health suite reproduces a red whose failing-test identity is HONEST (a TAP 'not ok' line, or a concrete test/source file — never healthcheck.sh's content-free '❌ CODE ERROR' banner), the watcher enqueues ONE scribe item citing that test and journals `main_health_autofix result=enqueued`, at most once per distinct failure while main is red. It FILES work; it never spawns a builder or touches the branch. off (default) → byte-identical: no scribe item, no journal line. Consumed by agent-watch.sh
: "${AGING_PR_TTL:="3600"}"      # HERD-334: AGING-PR alarm TTL in SECONDS (default 3600 = 60m). An engine-approved PR (herd/gates PASSED) that branch protection keeps blocking on a required CI check is a quiet steady state today — no TTL covers "engine approved it, CI blocks it, nothing is progressing". Past this TTL the watcher render pass paints a loud ADVISORY 'aging · engine-approved but blocked on <check>' row (never a hold) + journals `pr_aging` once per (pr,sha), and journal-audit.sh reports a gates_passed_no_merge finding. 0 DISABLES the alarm (byte-inert on both surfaces, mirrors DEP_STALE_TTL=0); a non-numeric value reads as the default. Consumed by agent-watch.sh + journal-audit.sh via aging-pr.sh
: "${STALE_DUP_DETECT:="on"}"    # HERD-188: pre-merge STALE-DUPLICATE gate — on (default) | off. on → the watcher HOLDS (never auto-merges) a PR whose tracked item ref is already Done via another merged PR, or whose touched files were materially changed on the base branch by a merge the branch predates (a stale base). Provable-only + fail-soft (no ref / offline / bad worktree → no hold), so default-on never false-holds a legit PR. off → byte-inert. Consumed by agent-watch.sh via stale-dup-gate.sh
: "${STALE_BASE_AUTOFIX:="off"}" # HERD-199: auto-heal STALE-BASE holds (not DUPLICATE) — on | off (default off, ship-dormant). on → when the stale-dup gate holds a PR for STALE-BASE (touched files moved on DEFAULT_BRANCH), the watcher auto-bounces the live builder with a `git merge $DEFAULT_BRANCH` re-task (or dispatches the conflict resolver when no live builder remains — foreign/reaped/dead), on the same rails as REVIEW_AUTOFIX: sha-keyed once-guard (kind=stale), the stale rail's own REFIX_MAX_ROUNDS budget, honest `rebasing · awaiting push` row; only bounce-exhaustion escalates to needs-you. DUPLICATE flavor stays a human judgment call. off (default) → byte-identical to the pre-HERD-199 hold (🛑 needs-you, no bounce, no ledger). Consumed by agent-watch.sh
: "${CI_AUTOREPAIR:="off"}"      # HERD-250: CI auto-repair for INHERITED reds — on | off (default off, ship-dormant). on → when a PR is MERGEABLE but UNSTABLE with a FAILING required CI check, herd/gates already PASSED for the head sha, AND the branch is BEHIND DEFAULT_BRANCH, the watcher dispatches a base-refresh (merge $DEFAULT_BRANCH into the branch — same mechanical heal as STALE_BASE_AUTOFIX, but keyed on CI-red+behind-base, not touched-file overlap). Sha-keyed once-guard kind=ci, the CI rail's own REFIX_MAX_ROUNDS budget, honest `ci-repair · awaiting push` row; bounce-exhaustion escalates to needs-you. NEVER silently merges a red PR — a REAL new-code CI failure (failing CI on an up-to-date branch, or without a gates blessing) stays needs-you. off (default) → byte-identical to the pre-HERD-250 UNSTABLE-fail path. Consumed by agent-watch.sh via ci-repair.sh
: "${RESOLVER_PANE:="off"}"      # HERD-280: the conflict resolver as a RETIRING PANE — on | off (default off, ship-dormant). on → herd-resolve.sh spawns the resolver as a bottom SPLIT PANE inside the builder's existing tab (label == slug) instead of a standalone resolve·<slug> tab, falling back to that tab in the control-room workspace when no builder tab exists; it records the pane in a sha-scoped dispatch registry ($TREES/.resolve-registry-<pr>-<sha>) and the watcher RECONCILES that registry against the OBSERVED verdict file each tick — a `RESOLVE: DONE` retires the pane immediately (guarded close + journal `resolver_pane_retired reason=result-consumed`), a `RESOLVE: ESCALATE` KEEPS the pane open for human inspection behind the existing needs-you row. The WORKTREE lifecycle is untouched: the retirement invariant still reaps at merge. off (default) → byte-identical to the pre-HERD-280 lane: a standalone tab, no registry file written, no reconcile, no retire. Consumed by agent-watch.sh + herd-resolve.sh
: "${HEALTH_PANE:="off"}"        # HERD-313: the in-flight HEALTHCHECK as a DISPOSABLE WATCH PANE — on | off (default off, ship-dormant). on → while a suite is in flight for a candidate, the watcher stands up a stamped `health·<slug>` pane (a plain `tail -F` of the sha-scoped health log $TREES/.health-log-<pr>-<sha> — NO model, NO gate authority, a VIEW only) and records it in a sha-scoped registry ($TREES/.health-pane-registry-<pr>-<sha>: one row `pane tab health·<slug>`). Each tick the watcher RECONCILES that registry against the OBSERVED inflight marker: the moment the suite ends (marker gone / worker dead) the pane is retired through the HERD-134 guarded close (a stale/recycled id naming a neighbour is REFUSED, journaling pane_close_refused) + journal `health_pane_retired`, dropping the row and its now-empty tab. Independent of, and additive to, the always-on live progress row (leg b). off (default) → byte-identical: no pane, no registry file, no reconcile side effect. An unrecognized value reads off (a typo can never arm a pane-closing path). Consumed by agent-watch.sh
: "${MERGE_FAIRNESS:="off"}"     # HERD-231: READY-PR PRIORITY in the watcher's action pass — on | off (default off, ship-dormant). on → candidates whose gates are ALREADY green for their head sha (cached CLEAN/FLAKY healthcheck + a review PASS, or a human-overridden BLOCK) are visited BEFORE candidates that still need gate work, so a ready PR merges this tick instead of waiting behind dispatches for its siblings — dispatches whose eventual merge is exactly what re-stales it. A stable partition of the candidate order: nothing merges that has not fully passed (the pre-merge re-verify, the unconditional stale-base re-check and the merge-policy decision all still run on a promoted PR). off (default) → the candidate order, and every event/dispatch/merge that follows from it, is byte-identical to before the feature. INDEPENDENT of the always-on re-stale counter + `starving · N re-stale laps` row, which are display-only. Consumed by agent-watch.sh
: "${GATE_STATUS:="on"}"         # HERD-194: post a `herd/gates` COMMIT STATUS as the watcher clears each (pr,sha) — on (default) | off. on → the watcher posts state=success on both-gates-green (healthcheck + adversarial review), exactly once per (pr,sha) via a sha-keyed ledger. It posts ONLY success — never a non-passing pending/failure status, which would flip a CLEAN sha to mergeStateStatus=UNSTABLE and strand it out of the merge loop in the default unprotected config. A gate FAIL posts NOTHING; the fail-safe rests entirely on the ABSENCE of success. Pair it with `require herd/gates` GitHub branch protection (recipe: docs/governance-gates.md) so the gate is FAIL-SAFE across seats/collaborators: anyone may merge, but nothing UNGATED can — a commit no watcher blessed has no success status and is unmergeable (under protection a fresh PR reports BLOCKED until blessed, which the watcher gates specially so requiring the check never deadlocks). In team mode (WATCHER_SCOPE=all) a sha another seat already blessed is not re-gated (cross-seat dedup). off → byte-inert: no status posted, no read. Consumed by agent-watch.sh
: "${CREATE_SELFHEAL:="on"}"     # HERD-267: tracker-create failure SELF-HEAL — on (default) | off. on → a backend create that the tracker REFUSES is diverted into a durable retry queue ($WORKTREES_DIR/.create-retry) instead of being silently consumed: the request text is written to disk before the claim is dropped, the reason is classified (cap | auth | transient | unknown) and journaled as `scribe_add_failed`, and the scribe drainer re-injects due entries with exponential backoff on its next poll. A PERMANENT reason (the tracker's issue cap, a bad API key) is announced with its own distinct label and is NEVER retried automatically — it surfaces loudly without spinning. `herd sweep` additionally runs an ADVISORY leg that finds merged PRs whose `Refs:` line points at no tracker item (the create never landed) and enqueues a retroactive-linkage request. off → byte-identical to the pre-HERD-267 behavior: a refused create is reported NOCHANGE and the request is dropped. Grounded in the 2026-07-10 incident where Linear's free-tier issue cap ate six coordinator filings over 2h and read as an "API flake". Consumed by scribe-step.sh + sweep.sh via create-retry.sh
: "${CREATE_RETRY_MAX:="5"}"     # HERD-267: how many times a durably-queued tracker create is re-attempted before it is marked PERMANENT (surfaced loudly, no longer re-injected). Only bounds the TRANSIENT/UNKNOWN classes: a cap/auth failure is permanent on its FIRST attempt, because retrying a wall cannot succeed and the spin is what hides the reason. The request text is retained on disk in every case — 'permanent' means stop retrying, never discard. A non-numeric value reads as 5. Consumed by create-retry.sh
: "${SWEEP_AUTO:="advise"}"      # HERD-191: control-room sweep triggers — off | advise (default) | auto. The watcher runs a CHEAP debris scan (stale tabs, dead inflight markers, orphaned ppid=1 bats/healthcheck trees) on its orphan-sweep cadence. advise → render one '🧹 sweep recommended: N stale tabs · M dead markers' console row + journal `sweep_advice` ONCE per distinct condition-set. auto → additionally run the SAFE legs (markers / orphan procs / registry tabs / PROVABLY-disposable worktrees); JUDGMENT legs (a worktree with real dirt or unpushed unique commits) stay advisory in every mode and are NEVER auto-deleted. off → byte-inert: no scan, no row, no journal. Consumed by agent-watch.sh via sweep.sh; `herd sweep` runs every leg on demand
: "${WATCHER_FLAIR:="off"}"      # HERD-147: watcher-console flair pack — on → a post-merge celebration line + a pasture header rendering the in-flight herd by state (🐑 grazing / 💤 idle / ✅ in the pen); off (default) → byte-inert: every console byte identical to before. ADDITIVE cosmetic only — NEVER softens a red/dead/needs-you row, never touches a gate/merge
: "${OPERATOR_INBOX:="off"}"     # HERD-184: cross-seat OPERATOR INBOX — on → the watcher surfaces NEW comments by OTHER authors (PR comments on open PRs this seat authors/gates + tracker comments on items this seat claimed, via the active SCRIBE_BACKEND's optional comment reader) as a 'operator inbox' console section + one notify-once per comment. off (default) → byte-inert: no reader runs, no fetch, no section, every console byte identical to before. ADDITIVE + FAIL-SOFT (missing/api error = empty inbox, never a red row); never touches a gate/merge
: "${ORPHAN_PR_ROWS:="off"}"     # HERD-330: ORPHAN-PR advisory console section — on → the watcher renders an 'orphan PRs' section listing each OPEN PR in the tick's ALREADY-fetched roster (PRS_JSON) that no live builder worktree in this workspace owns (a collaborator/main-checkout PR the worktree-gated watcher never adopts), so an ungated PR is visible instead of silently ignored. DYNAMIC discovery: recomputed every tick from live state, self-correcting the instant a worktree adopts (or the PR closes). Zero extra gh (reads the tick's existing discovery). Renders via the shared bounded-section helper (console-section.sh). off (default) → byte-inert: no scan, no ledger, no section, every console byte identical to before. ADVISORY + FAIL-SOFT — never gates, never merges, never a red row. Consumed by agent-watch.sh
: "${ADOPT_REMOTE_PRS:="off"}"   # HERD-369: auto-ADOPT ungated remote PRs into the worktree pool — on → builds ON TOP of the ORPHAN_PR_ROWS (HERD-330) open-PR-vs-pool diff (same already-fetched roster, zero extra gh): on a throttled ~60s cadence, for each OPEN, NON-DRAFT orphan PR whose branch is not already checked out ANYWHERE (this pool, the main checkout, or a stray manual worktree), `git fetch` + `git worktree add` its branch into WORKTREES_DIR so the worktree-gated watcher discovers and gates it the VERY NEXT tick instead of sitting ungated until a human hand-runs `git worktree add` (grounded: PRs #462/#463 sat ~16-18h on 2026-07-13, #478 ~18h on 2026-07-15). A SUCCESSFUL adopt is sha-keyed once-guarded ($WORKTREES_DIR/.agent-watch-adopted-prs) so a re-tick never re-adopts; a FAILURE (transient network blip, momentary ref lock) is never once-guarded and retries every scan — only the `adopt_failed` journal event is deduped per (pr,sha) ($WORKTREES_DIR/.agent-watch-adopt-failed-seen), never a red row. Never adopts a draft. Multi-seat: keyed off observed GitHub PR state each tick; `git worktree add` is naturally exclusive per branch. off (default) → byte-inert: no scan, no fetch, no worktree add, no ledger, every console byte identical to before. INDEPENDENT of ORPHAN_PR_ROWS — either works without the other. Consumed by agent-watch.sh
: "${OSS_TRIAGE:="off"}"         # HERD-255 / HERD-168 part 1/3: OSS auto-triage — on → `herd triage` lists open issues on HERD_REPO, enqueues a research-lane request per NEW issue (classify bug/feature/question/duplicate + draft reply/labels), and writes a ranked shortlist report for human approval. off (default) → byte-inert: no gh, no research enqueue, no report files. NEVER auto-posts (no issue comment/close/label). FAIL-SOFT (missing HERD_REPO / gh error → empty shortlist, never a hard red). Consumed by scripts/herd/oss-triage.sh
: "${JOURNAL_AUDIT:="off"}"      # HERD-238: journal-driven self-audit (the gap-finder) — on | off (default off, ship-dormant). on → the watcher runs journal-audit.sh on the tracker/housekeeping sweep cadence, replaying a BOUNDED journal window for invariant violations (merge without reap; *_dispatched with no terminal past family TTL; refix_bounce without refix_wake_result; MAIN RED older than TTL; pushed=no never followed by pushed=yes; known-fixture slugs). Findings → operator-inbox rows (source=audit) + journal_audit events (component=audit). ADVISORY ONLY — never gates, never mutates. off (default) → byte-inert: no journal read, no write, no inbox. FAIL-SOFT on empty/short journal. Consumed by agent-watch.sh via journal-audit.sh
: "${LIFECYCLE_CONTRACTS:="off"}" # HERD-193: the SUPERVISED-PROCESS CONTRACT — on | off (default off, ship-dormant). on → every spawned agent population records the four lifecycle properties at spawn (OWNER: which component spawned it · DEADLINE: the max lifetime after which it is presumed hung, REUSED from that population's existing timeout — REVIEW_INFLIGHT_TIMEOUT / HEALTH_INFLIGHT_TIMEOUT / DRAINER_HEARTBEAT_TIMEOUT · LIVENESS: a pid or a heartbeat file · RETIRE: the existing owner an expiry routes to), and a per-tick watcher sweep journals lifecycle_spawn / lifecycle_retire / lifecycle_expired and appends an operator-inbox row for anything past deadline. OBSERVABILITY-ONLY: it never kills, never gates, never merges — teardown stays with each population's existing owner (gate corpse sweep, drainer reclaim, stall detector, resolver escalation). off (default) → byte-inert: no record written, no journal event, no inbox row, no sweep read. FAIL-SOFT throughout. Consumed by agent-watch.sh, scribe.sh, research.sh via lifecycle.sh
export MODEL_REVIEW              # HERD-353: reach the Python engine core the watcher spawns as a child (like WORKTREES_DIR below); set as a plain var above, must be exported so live_runtime's review dispatch resolves the EFFECTIVE reviewer model — otherwise the python child never sees this unexported shell var and journals review_dispatched with model= empty (the reviewer, which sources config itself, still ran the right model; only the journal was wrong)
export WORKTREES_DIR             # HERD-345: reach the Python engine core the watcher spawns as a child; set as a plain var above, must be exported so every child process (live_runtime --tick) sees it
export PROJECT_ROOT              # HERD-345: ditto — the Python live_runtime refuses to tick without WORKTREES_DIR resolved, and PROJECT_ROOT is the co-required sibling
export STORE_BACKEND             # HERD-305: reach the Python engine core the watcher spawns as a child (like PYTHONUTF8 / HERD_THEME above); default 'auto' resolves flat, so the export is a dormant selector
export MAIN_HEALTH_TICK          # HERD-359: reach the Python engine core the watcher spawns as a child — _main_health_pending() (live_runtime --tick) reads it to reserve a health slot for main-health; set as a plain var above, without the export the child sees 'off' and the reservation is inert
: "${STORE_BACKEND:="auto"}"     # HERD-305 (engine-port P4): the MUTABLE-STATE STORE backend the Python runtime (pysrc/herd/store.py, live_runtime/shadow_runtime) reads — auto | flat | sqlite (default auto, ship-dormant). auto → FLAT (the ~45 flat state files agent-watch.sh owns) UNTIL the one-shot migration runner (`python3 -m herd.store --migrate`, operator-triggered, gated by herd_engine_migration_guard) has migrated the pool and written a `.herd/store-backend` marker; only then does auto engage the SQLite (WAL) store. flat → force flat. sqlite → force sqlite (explicit opt-in / tests). With nothing migrated auto == flat, so behavior is BYTE-IDENTICAL to before this key (the store never engages a backend it cannot open). The journal stays append-only JSONL, NEVER in the db. FAIL-SOFT: an unreadable marker / missing db degrades to flat. Consumed by pysrc/herd/store.py (resolve_backend)
: "${WATCHER_SELF_RESTART:="off"}" # HERD-251: watcher SELF-RESTART on stale engine code — on | off (default off, ship-dormant). on → when the freshness reconcile pulls a delta that rewrote agent-watch.sh (the same restart-note trigger HERD-233 already raises), the watcher QUIESCES: it stops dispatching NEW gate work (reviews, healthchecks, resolver spawns, and the stale-base heal that dispatches them) while in-flight workers finish and collect; each hold sits above its call site's ledger write, so a refused dispatch never burns a once-guard, then re-execs itself in place — same pane, same argv0 herd-watch-<ws> tag, same singleton lock (the exec keeps the pid, so the lock it re-acquires is its own) — once zero review/health gate workers remain for 2 consecutive ticks, or a 15-minute max-wait cap expires. Journals watcher_quiesce then watcher_self_restart; the console row becomes 'restarting on new engine code · draining N workers'. FAIL-SOFT: any error (unreadable script, hermetic guard) falls back to the plain 'restart recommended' row. off (default) → byte-identical to the HERD-233 recommendation row: no quiesce, no dispatch hold, no exec. Consumed by agent-watch.sh
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
# Claude exec-hang probe (HERD-108) — some environments WEDGE `claude` on invocation (every exec hangs
# before the process finishes starting, e.g. the macOS com.apple.quarantine _dyld_start hang). A wedged
# claude makes every review/refix dispatch spawn a corpse, so the poll loop burns cycles against a hang
# it cannot see. When armed, the watcher probes `claude --version` under a HARD timeout ONCE per tick
# before dispatching; a timeout HOLDS review/refix for that tick with a loud row + a journal infra_event
# (the doctor's own `claude responds` probe reports the same hang at diagnosis time). 0 = OFF (byte-inert;
# no probe exec, no journal, behavior byte-identical); N>=1 = probe timeout in seconds. Consumed by
# agent-watch.sh. Only a genuine timeout counts as a hang — a broken/absent claude is fail-soft (never
# holds the queue). A small value like 5 is a conservative arm for unattended runs.
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
import json, os, shlex, sys, tempfile

path = os.environ["HERD_RH_SETTINGS"]
sentinel = os.environ["HERD_RH_SENTINEL"]

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
q_sentinel = "'" + sentinel.replace("'", "'\\''") + "'"
cmd = "python3 -c %s > %s 2>/dev/null || : > %s" % (shlex.quote(_extract), q_sentinel, q_sentinel)
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
