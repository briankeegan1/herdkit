#!/usr/bin/env bash
# herd-approve.sh — approval entry-point for MERGE_POLICY=approve.
#
# When MERGE_POLICY=approve the watcher holds ready PRs (all gates passed) until a human writes
# an explicit sha-keyed approval record. This script is that entry-point.
#
# Usage:
#   herd-approve.sh list              — list gate-passed PRs awaiting approval (with review verdicts)
#   herd-approve.sh approve <pr#>     — approve the currently-awaiting sha for <pr#>; the watcher
#                                       merges on its next poll (~4 s)
#
# The approval is keyed to the PR's head sha at the time the awaiting record was written. A new
# commit pushed after that point invalidates the prior approval — the watcher re-runs the gate
# cycle and emits a fresh awaiting record before accepting another approval.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/herd-config.sh"

APPROVALS="$WORKTREES_DIR/.agent-watch-approvals"
REVIEW_STATE="$WORKTREES_DIR/.agent-watch-reviewed"

cmd="${1:-list}"
shift 2>/dev/null || true

case "$cmd" in

  list)
    if [ ! -s "$APPROVALS" ]; then
      echo "No PRs awaiting approval."
      exit 0
    fi
    found=0
    while read -r epoch state prnum sha; do
      [ "$state" = "awaiting" ] || continue
      # Skip if already approved for this exact sha.
      grep -q "^[0-9]* approved $prnum $sha$" "$APPROVALS" 2>/dev/null && continue
      # Look up the review verdict recorded for this PR + sha.
      verdict="$(awk -v p="$prnum" -v s="$sha" '$2==p && $3==s{v=$4} END{if(v) print v; else print "unknown"}' \
        "$REVIEW_STATE" 2>/dev/null || echo "unknown")"
      title="$(gh pr view "$prnum" --json title -q '.title' 2>/dev/null || true)"
      [ -z "$title" ] && title="(no title)"
      printf '  PR #%-4s  sha:%.8s  review:%-6s  %s\n' "$prnum" "$sha" "$verdict" "$title"
      found=$((found + 1))
    done < "$APPROVALS"
    if [ "$found" -eq 0 ]; then
      echo "No PRs awaiting approval."
    else
      printf '\nRun:  bash %s/herd-approve.sh approve <pr#>  to approve a PR for merge.\n' "$HERE"
    fi
    ;;

  approve)
    prnum="${1:-}"
    [ -n "$prnum" ] || { echo "Usage: herd-approve.sh approve <pr#>" >&2; exit 1; }
    if [ ! -s "$APPROVALS" ]; then
      echo "No awaiting approval record found for PR #${prnum}." >&2; exit 1
    fi
    # Take the last awaiting record for this PR (most recent sha).
    sha=""
    while read -r _epoch state pn s; do
      [ "$state" = "awaiting" ] && [ "$pn" = "$prnum" ] && sha="$s"
    done < "$APPROVALS"
    if [ -z "$sha" ]; then
      printf 'No awaiting approval record found for PR #%s.\n' "$prnum" >&2; exit 1
    fi
    # Idempotent: don't double-write if already approved for this sha.
    if grep -q "^[0-9]* approved $prnum $sha$" "$APPROVALS" 2>/dev/null; then
      printf 'PR #%s commit %.8s is already approved.\n' "$prnum" "$sha"; exit 0
    fi
    printf '%s approved %s %s\n' "$(date +%s)" "$prnum" "$sha" >> "$APPROVALS"
    printf '✅ Approved PR #%s (%.8s) — the watcher will merge on next poll (~4 s).\n' "$prnum" "$sha"
    ;;

  *)
    echo "Usage: herd-approve.sh [list|approve <pr#>]" >&2; exit 1
    ;;
esac
