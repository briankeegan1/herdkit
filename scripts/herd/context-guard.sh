#!/usr/bin/env bash
# context-guard.sh — THE ONE shared INVOCATION-CONTEXT check (HERD-269): a builder's worktree may
# never actuate the operator's control room.
#
# THE INCIDENT
# ------------
# A builder followed a task-spec VERIFY step ("check that `herd config set` accepts the new key"),
# ran `herd config set` + `herd reload` FROM ITS WORKTREE, and rebuilt the operator's control room:
# `herd config set` restarts the watcher for a watcher-affecting key, and `herd reload` stops the
# watcher, relaunches the panes and re-renders the coordinator skill. The live watcher died mid-run,
# taking the gate loop with it. Nothing in the CLI noticed that the invocation came from a builder
# worktree rather than the main checkout — every `.herd/config` in a worktree names the SAME
# PROJECT_ROOT / WORKSPACE_NAME / HERD_WATCHER_LOCK as the control room, because the worktree is a
# checkout of the very repo the config is committed in. A builder pointing at its own tree is,
# transitively, pointing at the operator's panes.
#
# THE INVARIANT (invariance-first, one check at one surface)
# ---------------------------------------------------------
# An actuating `herd` subcommand is legal only from the MAIN CHECKOUT. This file is the single
# reconciled check: `herd_context_guard "$@"` is called ONCE from bin/herd's dispatch, before any
# subcommand runs, so no actuator can grow its own private copy (or forget one). Adding an actuator
# means adding a case to _herd_context_is_actuator here — not a guard call to a command body.
#
# WHAT IS GUARDED (the actuator set, enumerated deliberately)
#   herd config set        edits .herd/config, then restarts the watcher / re-renders the skill
#   herd theme set         delegates to `herd config set HERD_THEME` — restarts the watcher
#   herd governance apply  proposes each key through the same validated `herd config set`
#   herd backend switch    flips SCRIBE_BACKEND via config set + restarts the backlog pane
#   herd reload            stops the watcher, rebuilds every control-room pane, re-renders the skill
#   herd pane              restarts a named control-room pane in place (coordinator = kills the agent)
#   herd sweep             reaps worktrees + tabs + processes, then restarts the watcher
#   herd update            git-pulls the ENGINE checkout, upgrades the skill, reloads the workspace
#   herd upgrade           runs migrations + rewrites .herd/config, re-renders the skill
#   herd agent-update      replaces the AGENT RUNTIME binary shared by every live agent
#
# WHAT IS NOT GUARDED — builders legitimately READ control-room state, and every read stays fully
# allowed: status, log, why, backlog, notes/note, config get|list|lint|sync|models, doctor, codemap,
# symbol-index, conformance, cost, stats, advise, deps, help — plus `render` (writes only the
# cwd's own rendered skill) and `init` (stands a project up; there is no control room yet).
# The rule is per-SUBCOMMAND, never per-flag: `config` is only an actuator at `config set`.
#
# WHAT COUNTS AS "NOT THE MAIN CHECKOUT"
#   (A) a git LINKED worktree — `git rev-parse --git-dir` differs from `--git-common-dir`. This is
#       the canonical, dependency-free test, and it is exactly "any git worktree that is not
#       PROJECT_ROOT's main checkout" (a main checkout always has git-dir == common-dir).
#   (B) cwd lies inside $WORKTREES_DIR (when that is set in the environment — the lanes export it).
#       Clause (A) already covers every `git worktree add` tree; (B) additionally catches a builder
#       tree that is a plain COPY, and gives the guard a seam independent of git.
# Neither clause can fire from the control room: PROJECT_ROOT is the main checkout and is never
# inside its own WORKTREES_DIR. Output from the control room is therefore BYTE-IDENTICAL to before.
#
# THE ESCAPE HATCH
#   HERD_ALLOW_CONTROL_MUTATION=1 permits the actuator and journals a `control_mutation_bypass`
#   event (component, argv, cwd) so the bypass is never silent. A refusal journals
#   `control_mutation_refused` for the same reason: the coordinator sees both in the watch stream.
#
# RELATED SEAM, NOT FIXED HERE: `herd config set` IGNORES HERD_CONFIG_FILE (HERD-264 builder
# finding) — it always resolves `$(pwd)/.herd/config`. The refusal message below still points a
# builder at HERD_CONFIG_FILE for the READ path (`herd config get|list`), which honors it; the
# recommended way to prove a key is accepted is a scratch-file assertion, not a live `config set`.

# _herd_context_abs <path> — absolute, symlink-resolved form of an existing dir; echoes the input
# unchanged when it cannot be resolved (never fails, never aborts a `set -e` caller).
_herd_context_abs() {
  ( cd "${1:-.}" 2>/dev/null && pwd -P ) || printf '%s' "${1:-}"
}

# _herd_context_is_worktree — success when the CURRENT WORKING DIRECTORY is a builder-side tree
# (clause A or clause B above) rather than PROJECT_ROOT's main checkout. Read-only; no git writes.
_herd_context_is_worktree() {
  local gitdir commondir trees cwd

  # (A) git linked worktree.
  if gitdir="$(git rev-parse --git-dir 2>/dev/null)" && [ -n "$gitdir" ]; then
    commondir="$(git rev-parse --git-common-dir 2>/dev/null)" || commondir="$gitdir"
    [ -n "$commondir" ] || commondir="$gitdir"
    if [ "$(_herd_context_abs "$gitdir")" != "$(_herd_context_abs "$commondir")" ]; then
      return 0
    fi
  fi

  # (B) cwd inside an exported WORKTREES_DIR.
  trees="${WORKTREES_DIR:-}"
  if [ -n "$trees" ] && [ -d "$trees" ]; then
    trees="$(_herd_context_abs "$trees")"
    cwd="$(_herd_context_abs ".")"
    case "$cwd" in
      "$trees"/*) return 0 ;;
    esac
  fi

  return 1
}

# _herd_context_is_actuator <argv...> — success when argv names a CONTROL-ROOM MUTATION. Echoes the
# canonical actuator name (e.g. "config set") on stdout so the refusal can quote it back. Keep this
# case list as the single enumeration of the actuator set; the header documents each entry.
_herd_context_is_actuator() {
  local cmd="${1:-}" sub="${2:-}"
  case "$cmd" in
    reload|sweep|pane|update|upgrade|agent-update) printf '%s' "$cmd"; return 0 ;;
    config)     [ "$sub" = "set" ]    && { printf 'config set';       return 0; } ;;
    theme)      [ "$sub" = "set" ]    && { printf 'theme set';        return 0; } ;;
    governance) [ "$sub" = "apply" ]  && { printf 'governance apply'; return 0; } ;;
    backend)    [ "$sub" = "switch" ] && { printf 'backend switch';   return 0; } ;;
  esac
  return 1
}

# _herd_context_journal <event> <actuator> — best-effort journal of a refusal/bypass. journal.sh is
# sourced by bin/herd before this file; if it is somehow absent this degrades to a silent no-op
# (fail-soft: a missing journal must never turn a guard decision into a crash).
_herd_context_journal() {
  command -v journal_append >/dev/null 2>&1 || return 0
  journal_append "$1" component context-guard actuator "$2" cwd "$(_herd_context_abs .)"
}

# herd_context_guard <argv...> — THE guard. Called once from bin/herd's dispatch with the raw argv.
# Returns 0 (silently, no output, no journal) for a read-only subcommand or from the main checkout.
# From a builder worktree an actuator either bypasses loudly (HERD_ALLOW_CONTROL_MUTATION=1, with a
# journaled bypass) or REFUSES loudly with exit 3 — never silently, and never a partial mutation.
herd_context_guard() {
  local actuator
  actuator="$(_herd_context_is_actuator "$@")" || return 0
  _herd_context_is_worktree || return 0

  if [ "${HERD_ALLOW_CONTROL_MUTATION:-}" = "1" ]; then
    _herd_context_journal control_mutation_bypass "$actuator"
    printf '%s⚠️  HERD_ALLOW_CONTROL_MUTATION=1 — running '"'"'herd %s'"'"' from a builder worktree. This ACTUATES the operator'"'"'s control room (journaled).%s\n' \
      "${c_yel:-}" "$actuator" "${c_rst:-}" >&2
    return 0
  fi

  _herd_context_journal control_mutation_refused "$actuator"
  {
    printf '%s❌ herd %s: REFUSED — this is a builder worktree, not the control room.%s\n' \
      "${c_red:-}" "$actuator" "${c_rst:-}"
    printf '\n'
    printf '   cwd: %s\n' "$(_herd_context_abs .)"
    printf '\n'
    printf '   Every .herd/config in a worktree names the OPERATOR'"'"'s PROJECT_ROOT, watcher lock and panes\n'
    printf '   (the worktree is a checkout of the repo that config is committed in). So `herd %s`\n' "$actuator"
    printf '   from here would restart or tear down the LIVE control room and kill the watcher mid-run.\n'
    printf '   That has happened (HERD-269). Read-only commands are unaffected.\n'
    printf '\n'
    printf '   What to do instead:\n'
    printf '     • verify a config key is ACCEPTED without touching the live config — assert against a\n'
    printf '       scratch file, e.g.  HERD_CONFIG_FILE=/tmp/cfg.scratch herd config get <KEY>\n'
    printf '       (note: `config set` itself still ignores HERD_CONFIG_FILE — HERD-264)\n'
    printf '     • READ live state freely:  herd status · herd log · herd why <pr#> · herd config get|list\n'
    printf '     • need a real control-room change? say so in your PR body — the coordinator owns it.\n'
    printf '\n'
    printf '   Deliberate, and you accept the blast radius? Re-run with HERD_ALLOW_CONTROL_MUTATION=1\n'
    printf '   (journaled as a bypass).\n'
  } >&2
  exit 3
}

# ── test-safety pane/tab guard (HERD-310) ───────────────────────────────────────────────────────
# A SECOND surface on the SAME invariance axis as herd_context_guard: a builder worktree may never
# actuate the operator's control room. herd_context_guard covers the `herd` CLI ACTUATORS; this
# covers LIVE-HERDR PANE/TAB MUTATIONS reached from SOURCED engine code — herd_teardown_slug's tab
# close (herd-config.sh) and herd_driver_close_pane (driver.sh) — which no CLI dispatch passes
# through, so herd_context_guard can never see them.
#
# THE INCIDENT (2026-07-10T20:45:17). A direct (non-bats) run of the watcher-* tests from INSIDE a
# live builder tab drove the teardown path against the LIVE herdr socket and closed the operator's
# REAL tabs: it severed an in-flight review (SIGTERM before a verdict) by closing the review·<slug>
# TAB, and killed the builder's own agent by closing the builder <slug> tab. The pane-close IDENTITY
# guard (HERD-134, herd_close_pane_verified) refused the PANE close (journaled pane_close_refused …
# reason=identity-unreadable — it saved that one pane) but the TAB close bypasses it entirely. This
# guard closes that gap at the one shared seam every test reaches by SOURCING the engine.
#
# THE RULE (mirrors herd_context_guard's control-room-is-byte-identical invariant). Refuse a
# pane/tab mutation IFF all three hold:
#   (1) a live herdr socket is present (a real, responding control surface exists to harm), AND
#   (2) cwd is a builder worktree (_herd_context_is_worktree — clause A or B above), AND
#   (3) the target workspace is NOT a disposable sim workspace (the sandbox-real-panes convention).
# From the CONTROL ROOM (main checkout) clause (2) is false → the guard NEVER fires → the real
# watcher/reconciler close their real panes exactly as before, BYTE-IDENTICAL. With NO herdr
# (headless CI, the hermetic test suite) clause (1) is false → NEVER fires → byte-identical. A
# disposable `sandbox-*` sim workspace stands up and tears down its OWN throwaway panes → allowed.
# ESCAPE HATCH: HERD_ALLOW_REAL_PANE_MUTATION=1 permits the mutation and journals a bypass — env
# only, never a config key, so it adds no gate/manifest surface.

# _herd_context_socket_live — success iff a REAL, responding herdr control surface with REAL panes is
# reachable: a live server answers `herdr workspace list`. Returns FAILURE (so the guard is inert and
# BYTE-IDENTICAL) when:
#   • the driver is HEADLESS (panes-as-a-view) — the engine creates NO herdr panes under headless, so
#     there is nothing real to protect. The DEFAULT driver is herdr-claude, where real panes exist and
#     the incident happened; headless is only ever an explicit opt-in (env HERD_DRIVER / config), so
#     this never disarms the guard in a real control room, and
#   • herdr is not on PATH, or no server answers (headless CI / the hermetic suite's no-herdr path).
_herd_context_socket_live() {
  if { command -v _herd_driver_is_headless >/dev/null 2>&1 && _herd_driver_is_headless; } \
     || [ "${HERD_DRIVER:-}" = "headless" ]; then
    return 1
  fi
  command -v herdr >/dev/null 2>&1 || return 1
  herdr workspace list >/dev/null 2>&1
}

# _herd_context_workspace_disposable — success iff the caller's workspace is a DISPOSABLE SIM
# workspace whose panes are throwaway (the sandbox-real-panes convention: the sim scenarios create a
# fresh `sandbox-…` workspace, drive only panes they created there, and close the whole workspace on
# teardown; no real project's WORKSPACE_NAME is ever `sandbox-*`). Keys on WORKSPACE_NAME — the
# config the caller operates under, exactly what herd_teardown_slug scopes its closes to — plus an
# explicit HERD_DISPOSABLE_WORKSPACE=1 override for a sim that uses a non-sandbox label. Fail-soft:
# an unset/unknown workspace is NOT disposable, so the guard stays ARMED (protect by default).
_herd_context_workspace_disposable() {
  [ "${HERD_DISPOSABLE_WORKSPACE:-}" = "1" ] && return 0
  case "${WORKSPACE_NAME:-}" in
    sandbox-*) return 0 ;;
  esac
  return 1
}

# herd_context_pane_guard [description] — THE shared pane/tab-mutation safety check. Returns 0 (ALLOW)
# for every safe context (no live socket, the control room, or a disposable sim workspace); returns 1
# (REFUSE — loud on stderr + journaled control_pane_mutation_refused) only from a builder worktree
# against a live, REAL control room. Callers SKIP the mutation on a non-zero return and NEVER abort
# (best-effort — a refusal must never crash a `set -euo pipefail` reconciler). journal.sh may not be
# in scope (driver.sh's zero-dependency sourcing) — _herd_context_journal degrades to a silent no-op.
herd_context_pane_guard() {
  local what="${1:-pane/tab mutation}"
  _herd_context_socket_live          || return 0
  _herd_context_is_worktree          || return 0
  _herd_context_workspace_disposable && return 0

  if [ "${HERD_ALLOW_REAL_PANE_MUTATION:-}" = "1" ]; then
    _herd_context_journal control_pane_mutation_bypass "$what"
    printf '%s⚠️  HERD_ALLOW_REAL_PANE_MUTATION=1 — %s from a builder worktree ACTUATES the operator'"'"'s LIVE herdr panes (journaled).%s\n' \
      "${c_yel:-}" "$what" "${c_rst:-}" >&2
    return 0
  fi

  _herd_context_journal control_pane_mutation_refused "$what"
  {
    printf '%s❌ REFUSED (%s): a builder worktree may not close the operator'"'"'s LIVE herdr panes/tabs.%s\n' \
      "${c_red:-}" "$what" "${c_rst:-}"
    printf '   A live herdr socket is present and this workspace (%s) is not a disposable sim workspace.\n' "${WORKSPACE_NAME:-?}"
    printf '   Closing here would tear down the real control room and sever in-flight review/builder\n'
    printf '   work (HERD-310). Drive real panes only from a disposable sandbox-* sim workspace, or set\n'
    printf '   HERD_ALLOW_REAL_PANE_MUTATION=1 to bypass (journaled).\n'
  } >&2
  return 1
}
