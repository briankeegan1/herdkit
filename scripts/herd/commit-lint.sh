#!/usr/bin/env bash
# commit-lint.sh — reusable commit-walking helpers for the healthcheck lint gates (HERD-121).
# Sourced by healthcheck.sh; the COMMIT_CONVENTION lint (HERD-124) sources it too.

# _herd_commit_shas <base_ref> — emit the full SHA of every commit on <base_ref>..HEAD, one per
# line (topo/reverse-chronological — git's default). The single commit-walking primitive shared by
# every lint gate below: the attribution scan and the commit-convention scan both range over it, so
# the "which commits does this PR add?" definition lives in exactly one place. Empty stdout → the
# branch is not ahead of <base_ref> (or the ref does not resolve). Returns 0 always.
_herd_commit_shas() {
  git log "${1:-origin/main}..HEAD" --format="%H" 2>/dev/null
}

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
  done < <(_herd_commit_shas "$_as_base")
  printf '%s' "$_as_out"
}

# _herd_commit_convention_scan <base_ref> <egrep_pattern> — walk commits between <base_ref> and
# HEAD (via the shared _herd_commit_shas primitive). Prints "SHORT_SHA:SUBJECT" for each commit
# whose SUBJECT line (git %s) does NOT match <egrep_pattern>. Empty stdout → every subject conforms.
# Returns 0 always; caller checks stdout.
#
# The pattern MUST already be a valid egrep (the caller fail-soft-validates it before calling —
# an invalid regex makes grep exit 2, which would spuriously flag every commit). An empty pattern
# is a no-op (nothing to enforce → clean).
_herd_commit_convention_scan() {
  local _cc_base="${1:-origin/main}" _cc_pat="${2:-}"
  local _cc_sha _cc_subj _cc_out=""
  [ -n "$_cc_pat" ] || { printf ''; return 0; }
  while IFS= read -r _cc_sha; do
    [ -n "$_cc_sha" ] || continue
    _cc_subj="$(git log -1 --format="%s" "$_cc_sha" 2>/dev/null)"
    if ! printf '%s' "$_cc_subj" | grep -qE "$_cc_pat" 2>/dev/null; then  # pipe-ok: single short scalar (one line), far under a pipe buffer
      _cc_out="${_cc_out}$(printf '%.12s' "$_cc_sha"):${_cc_subj}"$'\n'
    fi
  done < <(_herd_commit_shas "$_cc_base")
  printf '%s' "$_cc_out"
}
