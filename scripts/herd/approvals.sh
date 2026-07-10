#!/usr/bin/env bash
# approvals.sh — ONE seam for where the sha-keyed approval ledger lives and what it says.
#
# Under MERGE_POLICY=approve — and under the per-PR HUMAN-VERIFY hold, which deliberately REUSES the
# same ledger rather than opening a parallel one — a merge waits on an explicit, sha-keyed approval
# row written by herd-approve.sh. The ledger is a flat, append-only file of rows:
#
#   <epoch> <state> <pr#> <sha>        state ∈ awaiting | approved | hv-informed
#
# Three surfaces care about it: herd-approve.sh writes it, agent-watch.sh reads it before merging, and
# journal-audit.sh audits merged PRs against it after the fact. Each one spelling the path itself is
# how a ledger quietly forks into two; this file is the single place the path is spelled and the single
# place a row is interpreted. Same doctrine as merge-policy.sh: one seam, one answer.
#
# Sourcing only DEFINES functions — no side effects, no writes, no journal lines — so any caller may
# source it at any point, before or after herd-config.sh. Bash 3.2 clean.
#
# Seams:
#   HERD_APPROVALS_FILE   absolute ledger-path override (tests); else $WORKTREES_DIR/.agent-watch-approvals.

# _approvals_file — echo the resolved approval-ledger path. Non-zero with NO output when there is no
# destination (WORKTREES_DIR unset and no override), so a caller degrades instead of reading "/…".
_approvals_file() {
  if [ -n "${HERD_APPROVALS_FILE:-}" ]; then printf '%s' "$HERD_APPROVALS_FILE"; return 0; fi
  [ -n "${WORKTREES_DIR:-}" ] || return 1
  printf '%s' "$WORKTREES_DIR/.agent-watch-approvals"
}

# approval_state <pr#> [sha] — echo the STRONGEST record this PR+sha carries:
#   approved     a human (or, under HUMAN_VERIFY_POLICY=coordinator, a coordinator) signed this exact
#                sha off via `herd-approve.sh approve`
#   hv-informed  the sha merged under HUMAN_VERIFY_POLICY=auto: its steps were journaled and commented
#                but never signed off. A record, NOT an approval.
#   none         no record at all — also the answer for a missing, empty or unreadable ledger, so a
#                caller never has to distinguish "no ledger" from "no row" (fail-soft by construction).
# A sha PREFIX matches in either direction: `herd-approve.sh list` prints the short 8-char sha an
# operator copies, while the watcher records the full oid. Matching is anchored (index(...) == 1), so a
# prefix can never match some other sha's tail. An OMITTED (empty) sha matches any row for the PR — for
# callers holding a merge record that never carried one.
approval_state() {
  local _af _pr="${1:-}" _sha="${2:-}"
  _af="$(_approvals_file 2>/dev/null || true)"
  if [ -z "$_af" ] || [ ! -f "$_af" ] || [ -z "$_pr" ]; then
    printf 'none'; return 0
  fi
  awk -v pr="$_pr" -v sha="$_sha" '
    $3 != pr { next }
    {
      s = $4
      if (sha != "" && s != sha && index(s, sha) != 1 && index(sha, s) != 1) next
      if      ($2 == "approved")    approved = 1
      else if ($2 == "hv-informed") informed = 1
    }
    END {
      if (approved)      print "approved"
      else if (informed) print "hv-informed"
      else               print "none"
    }
  ' "$_af" 2>/dev/null || printf 'none'
}

# approval_recorded <pr#> <sha> — 0 iff a sha-keyed APPROVED record exists for this PR + commit.
# An `hv-informed` row is deliberately NOT an approval: nobody ran the declared steps.
approval_recorded() {
  [ "$(approval_state "${1:-}" "${2:-}")" = "approved" ]
}
