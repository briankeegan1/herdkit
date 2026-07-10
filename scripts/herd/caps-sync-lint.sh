#!/usr/bin/env bash
# caps-sync-lint.sh — THE shared caps-sync guard (HERD-220): the capabilities manifest
# (templates/capabilities.tsv) must be updated by the very change that grows the engine's
# capability surface. A change that adds
#     • a `cmd_*` subcommand to bin/herd,
#     • a config key to scripts/herd/herd-config.sh, or
#     • ANY new script under scripts/herd/
# without also touching templates/capabilities.tsv is a CODE error.
#
# ONE implementation, sourced (never executed) by BOTH gate surfaces so they can never disagree:
#     • .herd/healthcheck.project.sh — the heavy/merge gate (authoritative, runs the full suite)
#     • scripts/herd/healthcheck.sh  — the builder's LIGHT pre-PR gate, so a manifest miss is caught
#                                      before `gh pr create` instead of bouncing at the merge gate
# (incident: PR #328). Sourced-library precedent: merge-policy.sh.
#
# herd_caps_sync_lint [<base-ref>]
#   Run with the worktree root as cwd. Prints one line per offending surface on stdout; the caller
#   owns the ❌ headline, the note text and the exit.
#   Exit: 0 = clean · 1 = violation (lines on stdout) · 2 = skipped (infra; NEVER a red).
#   On a skip, $HERD_CAPS_SYNC_SKIP_REASON carries the one-line why (for the caller's note).
#
# Fail-soft by construction: no resolvable diff against the base, or no capabilities manifest at all
# (every consuming project — the manifest is herdkit's own), yields the skip, never a false red.

HERD_CAPS_SYNC_SKIP_REASON=""

herd_caps_sync_lint() {
  local _cs_base="${1:-origin/main}"
  local _cs_changed _cs_manifest_touched=0 _cs_errs="" _cs_new_cmds _cs_new_keys _cs_added_lanes

  HERD_CAPS_SYNC_SKIP_REASON=""

  if [ ! -f templates/capabilities.tsv ]; then
    HERD_CAPS_SYNC_SKIP_REASON="no templates/capabilities.tsv in this tree"
    return 2
  fi
  if ! _cs_changed="$(git diff --name-only "$_cs_base" 2>/dev/null)"; then
    HERD_CAPS_SYNC_SKIP_REASON="no diff against $_cs_base"
    return 2
  fi

  case "$_cs_changed" in *"templates/capabilities.tsv"*) _cs_manifest_touched=1 ;; esac
  [ "$_cs_manifest_touched" -eq 1 ] && return 0    # manifest moved with the change → nothing to flag

  # Grep a here-string, NOT `printf … | grep -qx` (HERD-297): grep -q closes the pipe at the first
  # match, the producer takes EPIPE, and under a caller's `set -o pipefail` (e.g.
  # tests/test-caps-sync-light.sh) the pipeline goes nonzero once the changed-file list exceeds a
  # 16KB pipe buffer. A here-string is a temp file — no producer process, no EPIPE.
  if grep -qxE 'bin/herd' <<< "$_cs_changed"; then
    _cs_new_cmds="$(git diff "$_cs_base" -- bin/herd 2>/dev/null \
      | grep -E '^\+[[:space:]]*cmd_[a-z_]+\(\)' || true)"
    [ -n "$_cs_new_cmds" ] \
      && _cs_errs="${_cs_errs}bin/herd adds cmd_*: also update templates/capabilities.tsv"$'\n'
  fi

  if grep -qxE 'scripts/herd/herd-config\.sh' <<< "$_cs_changed"; then   # here-string, not a pipe (HERD-297)
    _cs_new_keys="$(git diff "$_cs_base" -- scripts/herd/herd-config.sh 2>/dev/null \
      | grep -E '^\+[[:space:]]*:[[:space:]]+"?\$\{[A-Z_]+:=' || true)"
    [ -n "$_cs_new_keys" ] \
      && _cs_errs="${_cs_errs}herd-config.sh adds config keys: also update templates/capabilities.tsv"$'\n'
  fi

  _cs_added_lanes="$(git diff --diff-filter=A --name-only "$_cs_base" 2>/dev/null \
    | grep -Ex 'scripts/herd/[^/]+\.sh' | grep -vxE 'scripts/herd/herd-config\.sh' || true)"
  [ -n "$_cs_added_lanes" ] \
    && _cs_errs="${_cs_errs}new lane script added: also update templates/capabilities.tsv"$'\n'

  [ -n "$_cs_errs" ] || return 0
  printf '%s' "$_cs_errs"
  return 1
}
