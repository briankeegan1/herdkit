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
#   herd-approve.sh why <pr#>         — print the latest review verdict AND the reviewer's own stated
#                                       reason for it, as recorded with the verdict (HERD-473). When
#                                       no reason was recorded it says exactly that — it never
#                                       substitutes other PR text for the gate's objection (#576).
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
# Approval-ledger seam (HERD-272): the ledger's path and row grammar live in ONE place, so the
# auditor that later checks a merged PR against this ledger reads exactly the file this script wrote.
. "$HERE/approvals.sh"
# PUSH_GATE=human (HERD-123) — push-hold helpers so list/approve gain PRE-push hold coverage: a
# finished builder that stopped before push/PR create is listed here, and `approve <slug>` resumes
# its push + PR creation. Sourcing only defines functions (CLI dispatch is $0-guarded).
. "$HERE/push-gate.sh"
# Pipeline steps (HERD-132) — the step-hold helper. Sourced so `list` surfaces a step waiting at an
# approve-HOLD and `approve <slug>` releases it (resuming the pipeline past the held step). Sourcing
# only DEFINES functions (its CLI dispatch is $0-guarded); inert until a step recorded a hold.
. "$HERE/steps.sh"
# Journal (best-effort) so the push-hold approve/resume path can emit events like the watcher does.
# shellcheck source=scripts/herd/journal.sh
[ -f "$HERE/journal.sh" ] && . "$HERE/journal.sh"
# CLI palette for the `list` verdict column — themed via HERD_THEME (default tokyonight). Pre-set to
# "" so the surface degrades to plain (byte-identical to before this coloring) under NO_COLOR, a
# non-TTY stdout, or a missing theme.sh.
c_grn=""; c_red=""; c_dim=""; c_rst=""
# shellcheck source=/dev/null
[ -f "$HERE/theme.sh" ] && { . "$HERE/theme.sh"; herd_theme_load_cli; }

APPROVALS="$(_approvals_file || true)"
REVIEW_STATE="$WORKTREES_DIR/.agent-watch-reviewed"
OVERRIDES="$WORKTREES_DIR/.agent-watch-overrides"
# Merge/reap ledger the watcher appends to in do_merge ("<epoch> <pr#> <slug>"). Used as the
# offline, authoritative source for the HERD-90 display backstop below.
MERGED_STATE="$WORKTREES_DIR/.agent-watch-merged"

cmd="${1:-list}"
shift 2>/dev/null || true

# epoch_to_hhmm <epoch> — HH:MM from a Unix timestamp; BSD/macOS (-r) and GNU/Linux (-d @) safe.
epoch_to_hhmm() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null || echo '--:--'; }

# pr_merged <pr#> — HERD-90 display-level backstop: is this PR already merged? A merged PR's stale
# 'awaiting' rows are phantom holds and must never surface in `list`. Checks the watcher's
# merge/reap ledger first (offline, authoritative for engine merges — the exact case that leaks the
# old-sha row), then falls back to a cheap `gh` state probe (catches PRs merged out-of-band, e.g. a
# human merging on GitHub). Fail-soft: no ledger + no gh ⇒ not-merged, so the row still shows.
pr_merged() {
  grep -q "^[0-9][0-9]* $1 " "$MERGED_STATE" 2>/dev/null && return 0
  [ "$(gh pr view "$1" --json state -q '.state' 2>/dev/null)" = "MERGED" ]
}

# print_human_verify_steps <pr#> — if the PR declares a HUMAN-VERIFY block, print its steps
# (indented) so the operator knows exactly what to run before approving. Silent if none. Reflects the
# effective HUMAN_VERIFY_POLICY (HERD-59): under =coordinator the hold is flagged coordinator-actionable
# so a coordinator/agent knows it may run the steps and sign off itself. (=auto never reaches the
# approve ledger — those PRs are merged as informational, so this surfaces the hold/coordinator cases.)
print_human_verify_steps() {
  local _pr="$1" _steps
  _steps="$(gh pr view "$_pr" --json body -q '.body' 2>/dev/null | human_verify_steps)"
  [ -n "$_steps" ] || return 0
  case "${HUMAN_VERIFY_POLICY:-hold}" in
    coordinator) echo "      human-verify (coordinator-actionable) — a coordinator/agent runs these, then approves:" ;;
    *)           echo "      human-verify — run these, then approve:" ;;
  esac
  while IFS= read -r _s; do
    [ -n "$_s" ] && printf '        • %s\n' "$_s"
  done <<EOF
$_steps
EOF
}

# review_block_reason <pr#> <sha> — echo the reviewer's STRUCTURED reason for this exact verdict, or
# nothing (HERD-473). TWO sources, in this order, because the reason has two homes with different
# lifetimes and neither alone answers every case:
#
#   1. the review LEDGER row's trailing field ($REVIEW_STATE, "<epoch> <pr> <sha> <verdict> <source>
#      [reason…]") — the pre-merge fast path, written in the same append that records the verdict;
#   2. the append-only JOURNAL's `verdict_recorded` for the same pr+sha — the DURABLE record, and the
#      only one that still answers when the pool has migrated to the SQLite store (the flat ledger is
#      then no longer the substrate) or when a reader comes back to a PR after the ledger was purged.
#
# The two carry the same string by construction (live_runtime.py reads the ledger back to build the
# journal event), so consulting the second can never contradict the first. FAIL-SOFT throughout: a
# LEGACY reason-less row, a missing ledger, a missing journal and an absent python3 all yield the same
# empty answer — "no reason recorded" is a sayable answer, never an error and never a guess.
review_block_reason() {
  local _rb_pr="$1" _rb_sha="$2" _rb_out=""
  [ -n "$_rb_pr" ] && [ -n "$_rb_sha" ] || return 0
  if [ -s "$REVIEW_STATE" ]; then
    _rb_out="$(awk -v p="$_rb_pr" -v s="$_rb_sha" '
      $2==p && $3==s { r=""; for (i=6; i<=NF; i++) r = (r=="" ? $i : r" "$i) ; found=r }
      END { if (found != "") print found }' "$REVIEW_STATE" 2>/dev/null || true)"
  fi
  [ -z "$_rb_out" ] || { printf '%s' "$_rb_out"; return 0; }
  # Resolve the journal through journal.sh's OWN seam (_journal_file) rather than re-deriving the
  # path here: JOURNAL_FILE overrides, and a test context redirects to a throwaway file, so a
  # re-derivation would read a DIFFERENT file than journal_append wrote — a reader/writer split that
  # reports "no reason recorded" for a reason that was in fact recorded. One seam, one answer.
  local _rb_journal=""
  if command -v _journal_file >/dev/null 2>&1; then
    _rb_journal="$(_journal_file 2>/dev/null || true)"
  elif [ -n "${JOURNAL_FILE:-}" ]; then
    _rb_journal="$JOURNAL_FILE"
  elif [ -n "${WORKTREES_DIR:-}" ]; then
    _rb_journal="$WORKTREES_DIR/.herd/journal.jsonl"
  fi
  [ -n "$_rb_journal" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  # Rotated archives too (journal-<stamp>.jsonl beside the live file, oldest first — the same set and
  # order `herd why` aggregates over), so a verdict recorded before a rotation is not silently lost.
  # Last matching row wins, mirroring the ledger's own rule.
  _rb_out="$(HERD_RBR_PR="$_rb_pr" HERD_RBR_SHA="$_rb_sha" python3 -c '
import glob, json, os, sys
pr, sha, out = os.environ["HERD_RBR_PR"], os.environ["HERD_RBR_SHA"], ""
live = sys.argv[1]
paths = sorted(glob.glob(os.path.join(os.path.dirname(live) or ".", "journal-*.jsonl"))) + [live]
for path in paths:
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        continue
    with fh:
        for raw in fh:
            try:
                o = json.loads(raw)
            except Exception:
                continue
            if o.get("event") != "verdict_recorded":
                continue
            if str(o.get("pr", "")) == pr and str(o.get("sha", "")) == sha:
                out = str(o.get("reason", "") or "")
sys.stdout.write(" ".join(out.split()))
' "$_rb_journal" 2>/dev/null || true)"
  printf '%s' "$_rb_out"
}

case "$cmd" in

  list)
    # PUSH_GATE=human (HERD-123): finished builders holding for human review BEFORE push — no PR yet,
    # so they live in the push-hold ledger, not $APPROVALS. Surface them FIRST (a human reviews the
    # LOCAL diff at the printed worktree path, then approves to resume push + PR creation). Presence-
    # driven: nothing is printed when the feature is unused. Rendered before the PR-approval list.
    push_found=0
    while read -r ph_slug ph_sha ph_dir; do
      [ -n "$ph_slug" ] || continue
      if [ "$push_found" -eq 0 ]; then echo "Builders awaiting PUSH approval (pre-PR, review the LOCAL diff):"; fi
      printf '  %s  sha:%.8s  %s\n' "$ph_slug" "$ph_sha" "${ph_dir:-(worktree path unknown)}"
      [ -n "$ph_dir" ] && printf '      review:  git -C %s diff origin/HEAD...HEAD    approve:  bash %s/herd-approve.sh approve %s\n' "$ph_dir" "$HERE" "$ph_slug"
      push_found=$((push_found + 1))
    done <<EOF
$(push_gate_list 2>/dev/null || true)
EOF
    [ "$push_found" -gt 0 ] && echo

    # PIPELINE STEPS (HERD-132): steps stopped at an approve-HOLD — no PR gate involved, so they live in
    # the step-hold ledger. Surface them next (a human reviews at the printed worktree, then approves to
    # resume the pipeline past the held step). Presence-driven: nothing prints when unused.
    step_found=0
    while read -r sh_slug sh_sha sh_step sh_dir; do
      [ -n "$sh_slug" ] || continue
      if [ "$step_found" -eq 0 ]; then echo "Builders awaiting STEP approval (a hold=approve pipeline step):"; fi
      printf '  %s  step:%s  sha:%.8s  %s\n' "$sh_slug" "$sh_step" "$sh_sha" "${sh_dir:-(worktree path unknown)}"
      printf '      approve:  bash %s/herd-approve.sh approve %s\n' "$HERE" "$sh_slug"
      step_found=$((step_found + 1))
    done <<EOF
$(steps_hold_list 2>/dev/null || true)
EOF
    [ "$step_found" -gt 0 ] && echo

    if [ ! -s "$APPROVALS" ]; then
      [ "$push_found" -eq 0 ] && [ "$step_found" -eq 0 ] && echo "No PRs awaiting approval."
      exit 0
    fi
    found=0
    while read -r epoch state prnum sha; do
      [ "$state" = "awaiting" ] || continue
      # Skip if already approved for this exact sha.
      grep -q "^[0-9]* approved $prnum $sha$" "$APPROVALS" 2>/dev/null && continue
      # HERD-90 backstop: skip a merged PR's stale awaiting rows (phantom hold). Guards the window
      # before do_merge's purge runs, and PRs merged out-of-band that the purge never saw.
      pr_merged "$prnum" && continue
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
      [ "$push_found" -eq 0 ] && [ "$step_found" -eq 0 ] && echo "No PRs awaiting approval."
    else
      printf '\nRun:  bash %s/herd-approve.sh approve <pr#>  to approve a PR for merge.\n' "$HERE"
    fi
    ;;

  approve)
    # Optional --sha <sha> PINS the approval to a specific commit: a human who saw a commit in `list`
    # can assert "approve THIS sha" so a hold that was superseded by a new push (the sha moved) is
    # refused instead of silently approving a different commit than the operator reviewed (HERD-157).
    prnum=""; pin_sha=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --sha) pin_sha="${2:-}"; shift 2 ;;
        --sha=*) pin_sha="${1#--sha=}"; shift ;;
        -*) echo "herd-approve.sh approve: unknown flag: $1 (usage: approve <pr#|slug> [--sha <sha>])" >&2; exit 1 ;;
        *) [ -z "$prnum" ] && prnum="$1"; shift ;;
      esac
    done
    [ -n "$prnum" ] || { echo "Usage: herd-approve.sh approve <pr#|slug> [--sha <sha>]" >&2; exit 1; }
    # pin_matches <live-sha> — 0 unless --sha was given and disagrees with the live hold's sha. A
    # PREFIX match counts (list shows the short 8-char sha a human copies; git-style prefixes against
    # the single known live sha are unambiguous). On a real mismatch it prints a LOUD refusal (the
    # operator asked to approve a commit that is no longer what is held) and returns 1 so the caller
    # bails before recording anything.
    pin_matches() {
      local live="$1"
      [ -z "$pin_sha" ] && return 0
      [ "$pin_sha" = "$live" ] && return 0
      case "$live" in "$pin_sha"*) return 0 ;; esac
      printf '🛑 Refusing: you asked to approve sha %s, but %s is currently holding %s.\n' "$pin_sha" "$prnum" "$live" >&2
      printf '   A newer commit may have superseded the one you reviewed. Re-check `herd-approve.sh list` and retry.\n' >&2
      return 1
    }
    # PUSH_GATE=human (HERD-123): if the argument names a builder with a LIVE push-hold (pre-PR), this
    # is a PUSH approval, not a merge approval — record it and RESUME (push + PR creation). A PR number
    # is numeric and a builder slug is kebab-case, so a live push-hold for "$prnum" unambiguously
    # selects this path; otherwise fall through to the existing PR-merge approval below. push_gate_resume
    # is fail-soft: a stale (new-commit) or corrupt hold refuses LOUDLY and pushes nothing.
    if [ -n "$(push_gate_awaiting_sha "$prnum" 2>/dev/null || true)" ]; then
      pin_matches "$(push_gate_awaiting_sha "$prnum")" || exit 1
      _pg_approved_sha="$(push_gate_approve "$prnum")" || { echo "❌ Could not record push approval for '$prnum'." >&2; exit 1; }
      printf '✅ Push approval recorded for %s — approved commit %s.\n' "$prnum" "$_pg_approved_sha"
      printf '   Resuming push + PR creation…\n'
      push_gate_resume "$prnum"; exit $?
    fi
    # PIPELINE STEPS (HERD-132): if the argument names a builder/slug with a LIVE step-hold (a
    # hold=approve step stopped the pipeline), this is a STEP approval — record it and RELEASE, which
    # resumes the pipeline past the held step. Keyed by slug (kebab) like the push-hold, so a numeric PR
    # number never selects this path; checked after the push-hold (a builder hits a push-hold only once,
    # after its step holds). steps_hold_release is fail-soft: a stale/corrupt hold refuses LOUDLY.
    if [ -n "$(steps_hold_awaiting_sha "$prnum" 2>/dev/null || true)" ]; then
      pin_matches "$(steps_hold_awaiting_sha "$prnum")" || exit 1
      _st_approved_sha="$(steps_hold_approve "$prnum")" || { echo "❌ Could not record step approval for '$prnum'." >&2; exit 1; }
      printf '✅ Step approval recorded for %s — approved commit %s.\n' "$prnum" "$_st_approved_sha"
      printf '   Resuming the pipeline past the held step…\n'
      steps_hold_release "$prnum"; exit $?
    fi
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
    pin_matches "$sha" || exit 1
    # Idempotent: don't double-write if already approved for this sha.
    if grep -q "^[0-9]* approved $prnum $sha$" "$APPROVALS" 2>/dev/null; then
      printf 'PR #%s commit %s is already approved.\n' "$prnum" "$sha"; exit 0
    fi
    printf '%s approved %s %s\n' "$(date +%s)" "$prnum" "$sha" >> "$APPROVALS"
    # The ledger row above is EPHEMERAL: do_merge calls purge_pr_approvals as soon as this PR merges,
    # dropping every row for it. So the fact that a human signed this sha off is ALSO written to the
    # append-only journal, which nothing purges. That journal event is the only evidence a post-merge
    # auditor (journal-audit.sh check (g), HERD-272) can still see; without it, an approved
    # HUMAN-VERIFY merge is indistinguishable from one that fail-open merged with its steps unrun.
    command -v journal_append >/dev/null 2>&1 \
      && journal_append approval_recorded pr "$prnum" sha "$sha" state approved source herd-approve || true
    printf '✅ Approved PR #%s — approved commit %s. The watcher will merge on next poll (~4 s).\n' "$prnum" "$sha"
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
    # THE REASON (HERD-473) — the whole point of this verb, and what it printed nothing of before: the
    # reviewer's own stated objection. Always printed, and when there is none it SAYS so, because the
    # failure this fixes (#576) was a BLOCK immediately followed by an unrelated approving comment,
    # which reads as the gate's reasoning and is the exact opposite of it.
    reason="$(review_block_reason "$prnum" "$sha")"
    if [ -n "$reason" ]; then
      printf 'Reason (recorded with the verdict):\n  %s\n\n' "$reason"
    else
      printf 'Reason: none recorded with this verdict.\n'
      printf "  Nothing below is the gate's objection — read the reviewer's own comment on the PR.\n\n"
    fi
    print_human_verify_steps "$prnum"
    echo "Latest PR comment (context only — NOT the review verdict):"
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
