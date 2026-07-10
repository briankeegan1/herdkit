#!/usr/bin/env bash
# approvals.sh — ONE seam for where the sha-keyed approval ledger lives and what it says.
#
# Under MERGE_POLICY=approve — and under the per-PR HUMAN-VERIFY hold, which deliberately REUSES the
# same ledger rather than opening a parallel one — a merge waits on an explicit, sha-keyed approval
# row written by herd-approve.sh. The ledger is a flat, append-only file of rows:
#
#   <epoch> <state> <pr#> <sha>        state ∈ awaiting | approved | hv-informed
#
# herd-approve.sh writes it and agent-watch.sh reads it before merging; both resolve the PATH here, so
# a ledger cannot quietly fork into two (e.g. under HERD_APPROVALS_FILE). Same doctrine as
# merge-policy.sh: one seam, one answer. Both callers still parse rows with their own literal patterns
# for the states they own; approval_state below is the shared reader for callers that just want the
# verdict.
#
# ⚠ THE LEDGER IS EPHEMERAL — IT DOES NOT SURVIVE THE MERGE. agent-watch.sh's do_merge calls
# purge_pr_approvals the instant a PR merges, dropping EVERY row for that PR number: awaiting,
# approved and hv-informed alike, across all shas (HERD-90 — a stale 'awaiting' row is a phantom hold).
# `_reap_slug` and retirement.sh purge it again. So approval_state on a MERGED pr is always `none`, and
# a post-merge auditor that trusts it would accuse every properly-approved merge of merging unverified.
# The durable evidence lives in the append-only journal instead: `approval_recorded` (written by
# herd-approve.sh) and `human_verify_policy … policy=auto` (written by agent-watch.sh). journal-audit.sh
# check (g) reads those; it consults this ledger only for the PRE-merge window, where a row still exists.
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
