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
#   herd-approve.sh why <pr#>         — print the latest review verdict + block reason for a PR
#                                       (from the review ledger and the PR's review comment)
#   herd-approve.sh override <pr#>    — record a human override of a cached BLOCK for <pr#>'s
#                                       current commit sha; the watcher treats it as PASS and
#                                       proceeds to its normal approval/merge path. A new commit
#                                       pushed after the override invalidates it — the PR will be
#                                       re-reviewed automatically.
#
# The approval and override records are keyed to the PR's head sha at the time the record is
# written. A new commit pushed after that point invalidates both — the watcher re-runs the gate
# cycle and emits a fresh awaiting record before accepting another approval or override.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/herd-config.sh"
# HUMAN-VERIFY parser — so `list`/`why` can print the exact steps a held PR is waiting on.
. "$HERE/human-verify.sh"
# CLI palette for the `list` verdict column — themed via HERD_THEME (default tokyonight). Pre-set to
# "" so the surface degrades to plain (byte-identical to before this coloring) under NO_COLOR, a
# non-TTY stdout, or a missing theme.sh.
c_grn=""; c_red=""; c_dim=""; c_rst=""
# shellcheck source=/dev/null
[ -f "$HERE/theme.sh" ] && { . "$HERE/theme.sh"; herd_theme_load_cli; }

APPROVALS="$WORKTREES_DIR/.agent-watch-approvals"
REVIEW_STATE="$WORKTREES_DIR/.agent-watch-reviewed"
OVERRIDES="$WORKTREES_DIR/.agent-watch-overrides"

cmd="${1:-list}"
shift 2>/dev/null || true

# epoch_to_hhmm <epoch> — HH:MM from a Unix timestamp; BSD/macOS (-r) and GNU/Linux (-d @) safe.
epoch_to_hhmm() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null || echo '--:--'; }

# print_human_verify_steps <pr#> — if the PR declares a HUMAN-VERIFY block, print its steps
# (indented) so the operator knows exactly what to run before approving. Silent if none.
print_human_verify_steps() {
  local _pr="$1" _steps
  _steps="$(gh pr view "$_pr" --json body -q '.body' 2>/dev/null | human_verify_steps)"
  [ -n "$_steps" ] || return 0
  echo "      human-verify — run these, then approve:"
  while IFS= read -r _s; do
    [ -n "$_s" ] && printf '        • %s\n' "$_s"
  done <<EOF
$_steps
EOF
}

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
      # Themed verdict: PASS→green, BLOCK→red, anything else (unknown/held)→dim. The color codes are
      # separate printf args so the %-6s padding still aligns on the verdict TEXT, not the escapes.
      vcol="$c_dim"
      case "$verdict" in PASS) vcol="$c_grn" ;; BLOCK) vcol="$c_red" ;; esac
      printf '  PR #%-4s  sha:%.8s  review:%s%-6s%s  %s\n' "$prnum" "$sha" "$vcol" "$verdict" "$c_rst" "$title"
      print_human_verify_steps "$prnum"
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

  why)
    prnum="${1:-}"
    [ -n "$prnum" ] || { echo "Usage: herd-approve.sh why <pr#>" >&2; exit 1; }
    # Find the most recent review record for this PR (any sha).
    verdict_info=""
    if [ -s "$REVIEW_STATE" ]; then
      verdict_info="$(awk -v p="$prnum" '$2==p{epoch=$1; sha=$3; verdict=$4} END{if(epoch) print epoch" "sha" "verdict}' \
        "$REVIEW_STATE" 2>/dev/null || true)"
    fi
    if [ -z "$verdict_info" ]; then
      printf 'No review verdict recorded for PR #%s.\n' "$prnum" >&2
      exit 1
    fi
    read -r epoch sha verdict <<EOF
$verdict_info
EOF
    hhmm="$(epoch_to_hhmm "$epoch")"
    override_note=""
    if grep -q "^[0-9]* override $prnum $sha$" "$OVERRIDES" 2>/dev/null; then
      override_note=" (override recorded)"
    fi
    printf 'PR #%s  sha:%.8s  verdict:%s%s  at %s\n\n' \
      "$prnum" "$sha" "$verdict" "$override_note" "$hhmm"
    print_human_verify_steps "$prnum"
    echo "Latest PR comment:"
    gh pr view "$prnum" --json comments 2>/dev/null \
      | python3 -c '
import sys, json
try:
    comments = json.load(sys.stdin).get("comments", [])
    last = next((c for c in reversed(comments) if c.get("author")), None)
    if last:
        login = last.get("author", {}).get("login", "?")
        body = last.get("body", "").strip().replace("\n", " ")[:200]
        print(f"  {login}: {body}")
    else:
        print("  (no comments found)")
except Exception:
    print("  (could not parse PR comments)")
' 2>/dev/null || echo "  (could not fetch PR comments)"
    ;;

  override)
    prnum="${1:-}"
    [ -n "$prnum" ] || { echo "Usage: herd-approve.sh override <pr#>" >&2; exit 1; }
    # Get the current head sha for this PR.
    rsha="$(gh pr view "$prnum" --json headRefOid 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("headRefOid",""))' 2>/dev/null || true)"
    [ -n "$rsha" ] || { printf 'Could not get head sha for PR #%s — is the PR number correct?\n' "$prnum" >&2; exit 1; }
    # Idempotent: if already overridden for this sha, report and exit.
    if grep -q "^[0-9]* override $prnum $rsha$" "$OVERRIDES" 2>/dev/null; then
      printf 'Override already recorded for PR #%s (sha %.8s).\n' "$prnum" "$rsha"
      exit 0
    fi
    # Inform if this sha already has a PASS verdict (no override needed).
    existing="$(awk -v p="$prnum" -v s="$rsha" '$2==p && $3==s{v=$4} END{if(v) print v}' \
      "$REVIEW_STATE" 2>/dev/null || true)"
    if [ "$existing" = "PASS" ]; then
      printf 'PR #%s (sha %.8s) already has a PASS verdict — no override needed.\n' "$prnum" "$rsha"
      exit 0
    fi
    printf '%s override %s %s\n' "$(date +%s)" "$prnum" "$rsha" >> "$OVERRIDES"
    printf '⚡ Override recorded for PR #%s (sha %.8s).\n' "$prnum" "$rsha"
    printf '   The watcher will treat this commit'\''s BLOCK as passed on next poll (~4 s).\n'
    printf '   A new commit pushed after this point invalidates the override and triggers re-review.\n'
    ;;

  *)
    echo "Usage: herd-approve.sh [list|approve <pr#>|why <pr#>|override <pr#>]" >&2; exit 1
    ;;
esac
