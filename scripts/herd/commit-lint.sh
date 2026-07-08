#!/usr/bin/env bash
# commit-lint.sh — reusable commit-walking helpers for the healthcheck lint gates (HERD-121).
# Sourced by healthcheck.sh; the future COMMIT_CONVENTION lint sources this too.

# _herd_attr_scan <base_ref> — walk commits between <base_ref> and HEAD.
# Prints "SHORT_SHA:LINE" for each commit body line matching an AI attribution marker.
# Empty stdout → clean history. Returns 0 always; caller checks stdout.
#
# Detects (case-insensitive):
#   • Co-Authored-By: Claude*   — the Claude Code standard co-author trailer
#   • Generated with Claude*    — the Claude Code PR-body/commit footer
_herd_attr_scan() {
  local _as_base="${1:-origin/main}"
  local _as_sha _as_body _as_line _as_lower _as_out=""
  while IFS= read -r _as_sha; do
    [ -n "$_as_sha" ] || continue
    _as_body="$(git log -1 --format="%B" "$_as_sha" 2>/dev/null)"
    while IFS= read -r _as_line; do
      _as_lower="$(printf '%s' "$_as_line" | tr '[:upper:]' '[:lower:]')"
      case "$_as_lower" in
        *"co-authored-by: claude"*|*"generated with claude"*|*"generated with [claude"*)
          _as_out="${_as_out}$(printf '%.12s' "$_as_sha"):${_as_line}"$'\n'
          ;;
      esac
    done <<< "$_as_body"
  done < <(git log "$_as_base..HEAD" --format="%H" 2>/dev/null)
  printf '%s' "$_as_out"
}
