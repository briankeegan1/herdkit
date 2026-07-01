#!/usr/bin/env bash
# herd-links.sh — cross-repo link registry resolver. Source this to call
# _herd_find_links and _herd_resolve_link.
#
# _herd_find_links
#   Prints the absolute path of the .herd/links file, or empty if none found.
#   Resolution order:
#     1. HERD_LINKS_FILE env (explicit override)
#     2. PROJECT_ROOT/.herd/links (set by herd-config.sh)
#     3. directory of HERD_CONFIG_FILE (set by the CLI before sourcing herd-config.sh)
#     4. walk up from $PWD
#
# _herd_resolve_link <name>
#   Looks up <name> in .herd/links. On success sets:
#     HERD_REPO           — linked repo (owner/repo)
#     HERD_REPORT_BACKEND — adapter name (github, linear, file, changelog)
#     HERD_LINK_TARGET    — optional tracker routing (e.g. Linear team ID); may be empty
#   Returns 0 on match, 1 if the name is not found or no links file exists.

_herd_find_links() {
  [ -n "${HERD_LINKS_FILE:-}" ] && { printf '%s' "$HERD_LINKS_FILE"; return; }
  if [ -n "${PROJECT_ROOT:-}" ] && [ -f "$PROJECT_ROOT/.herd/links" ]; then
    printf '%s' "$PROJECT_ROOT/.herd/links"; return
  fi
  if [ -n "${HERD_CONFIG_FILE:-}" ]; then
    local _hl_dir; _hl_dir="$(dirname "$HERD_CONFIG_FILE")"
    [ -f "$_hl_dir/links" ] && { printf '%s' "$_hl_dir/links"; return; }
  fi
  local _hl_walk="$PWD"
  while [ -n "$_hl_walk" ] && [ "$_hl_walk" != "/" ]; do
    [ -f "$_hl_walk/.herd/links" ] && { printf '%s' "$_hl_walk/.herd/links"; return; }
    _hl_walk="$(dirname "$_hl_walk")"
  done
  printf ''
}

_herd_resolve_link() {
  local _hl_name="$1"
  local _hl_file; _hl_file="$(_herd_find_links)"
  [ -n "$_hl_file" ] && [ -f "$_hl_file" ] || return 1
  local _hl_line _hl_fname _hl_rest _hl_repo _hl_backend _hl_target
  while IFS= read -r _hl_line; do
    case "$_hl_line" in '#'*|'') continue ;; esac
    _hl_fname="${_hl_line%%|*}"; _hl_rest="${_hl_line#*|}"
    _hl_repo="${_hl_rest%%|*}";  _hl_rest="${_hl_rest#*|}"
    _hl_backend="${_hl_rest%%|*}"; _hl_target="${_hl_rest#*|}"
    [ "$_hl_fname" = "$_hl_name" ] || continue
    HERD_REPO="$_hl_repo"
    HERD_REPORT_BACKEND="${_hl_backend:-github}"
    HERD_LINK_TARGET="$_hl_target"
    return 0
  done < "$_hl_file"
  return 1
}
