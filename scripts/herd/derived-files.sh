#!/usr/bin/env bash
# derived-files.sh — the ONE list of REGENERABLE DERIVED FILES the engine writes into a project
# checkout, plus the predicates every reaper/gate uses to excuse them (HERD-214).
#
# WHY THIS EXISTS
# --------------
# `render_skill` regenerates `.claude/commands/<COORDINATOR_CMD>.md` from templates/coordinator.md.tmpl
# on init / update / reload / render / a render-affecting `config set`. While that render was TRACKED,
# every one of those commands dirtied whatever checkout it ran in, and the dirt then interfered with
# machinery that reads `git status` as a proxy for "does this tree hold real work":
#   • the sweep's worktree leg FLAGGED a merged worktree instead of reaping it,
#   • the watcher's startup reap SKIPPED a stranded worktree as "dirty",
#   • the stale-base gate saw the same path changed on both sides of the merge-base and HELD the PR,
#   • `git pull` / the ff-only `herd update` refused with a local-modification conflict.
# Six such interference incidents in two days. The render is now a PER-MACHINE ARTIFACT (gitignored,
# never tracked — same doctrine as `.herd/config.local`): consumers share the TEMPLATE, each machine
# renders its own copy. A gitignored file never appears in `git status --porcelain`, so the new-world
# case is fixed by construction.
#
# This file covers the OLD world that still exists in flight: a branch cut BEFORE the untracking
# migration still carries the render as a tracked file, so it can still show up modified in a status
# or in a merge-base diff. Every such path is, by definition, reproducible from the template plus the
# config — nothing a human wrote, nothing a merge can lose. The reapers and the stale-base gate
# therefore EXCUSE these paths, and they do it from ONE list so the three exemptions can never drift.
#
# CONTRACT
#   herd_derived_paths            print each derived repo-relative path, one per line
#   herd_is_derived_path <path>   success iff <path> is derived (exact, repo-relative match)
#   herd_strip_derived            filter: read paths on stdin, print only the NON-derived ones
#
# The rendered skill's basename follows COORDINATOR_CMD when the config is loaded; it falls back to
# the shipped default (`coordinator`) so this library is safe to source with no config in scope.
#
# Sourced by sweep.sh, agent-watch.sh, and stale-dup-gate.sh — each of which may source it more than
# once through their own source graph, hence the idempotence guard.

if [ -z "${HERD_DERIVED_FILES_LIB:-}" ]; then
HERD_DERIVED_FILES_LIB=1

# herd_derived_paths — the shared regenerable-derived-files constant, emitted one path per line.
# Repo-relative, exact paths (never globs): an exemption that matched loosely could excuse a file a
# human actually wrote. Members must satisfy BOTH: (a) the engine regenerates them deterministically
# from committed inputs, and (b) losing the working-tree copy costs nothing.
herd_derived_paths() {
  local _dp_name="${COORDINATOR_CMD:-/coordinator}"
  _dp_name="${_dp_name#/}"; _dp_name="${_dp_name:-coordinator}"
  printf '%s\n' \
    ".claude/commands/${_dp_name}.md" \
    ".herd/config.local"
}

# herd_is_derived_path <path> — success iff <path> is one of the derived files. Leading "./" and a
# trailing "/" are tolerated so a caller can pass a raw `git status --porcelain` path through.
herd_is_derived_path() {
  local _idp="${1:-}"
  _idp="${_idp#./}"; _idp="${_idp%/}"
  [ -n "$_idp" ] || return 1
  herd_derived_paths | grep -qxF -- "$_idp"
}

# herd_strip_derived — read repo-relative paths on stdin, print only the ones that are NOT derived.
# Empty output ⇒ every path was a derived artifact ⇒ the caller may proceed as if the tree were clean.
herd_strip_derived() {
  local _sd_line
  while IFS= read -r _sd_line || [ -n "$_sd_line" ]; do
    [ -n "$_sd_line" ] || continue
    herd_is_derived_path "$_sd_line" && continue
    printf '%s\n' "$_sd_line"
  done
}

fi
