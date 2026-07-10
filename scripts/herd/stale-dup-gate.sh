#!/usr/bin/env bash
# stale-dup-gate.sh — the PRE-MERGE STALE-DUPLICATE gate (HERD-188).
#
# WHY THIS EXISTS
# --------------
# The watcher auto-merges any PR that is CLEAN + healthcheck-green + review-PASS. None of those gates
# ask the one question that sank PR #236: "has this work ALREADY shipped, or does this branch sit on a
# base so stale that merging it would silently clobber newer main?" #236 was a stale duplicate of the
# already-shipped HERD-49 (PR #185); it force-merged onto a newer main and BROKE it (-> revert #280).
# Healthcheck (does it still build?) and the correctness review (is the diff self-consistent?) both said
# PASS — because in isolation the diff WAS fine. The defect was RELATIONAL: right code, wrong-time.
#
# WHAT IT DETECTS (either condition HOLDS the PR — never auto-merges — and surfaces LOUDLY)
# ----------------------------------------------------------------------------------------
#   (1) DUPLICATE  — the PR's tracked item ref (its 'Refs: <ID>' body line) is ALREADY Done via ANOTHER
#                    MERGED PR carrying the same ref. That is the ground-truth "already shipped" signal
#                    and needs NO tracker/secret read — merged-PR bodies are public. (#236 vs #185.)
#   (2) STALE BASE — the files this PR touches were MATERIALLY changed on the base branch by a merge the
#                    branch PREDATES. Even when git can textually auto-merge (so GitHub reports CLEAN and
#                    the watcher would merge), re-applying an old branch's version of a file that main
#                    already moved silently reverts that newer work. Computed deterministically from git:
#                    the intersection of {files the PR changed since its merge-base} and {files the base
#                    branch changed since that same merge-base}, and only when the branch is behind base.
#
# CONVENTIONS (from the item)
# ---------------------------
#   • DEFAULT-ON but PROVABLE-ONLY: it only ever holds on a demonstrable duplicate ref or a demonstrable
#     stale-base file overlap — both deterministic, no heuristics — so default-on cannot false-hold a
#     legitimate PR. Disable entirely with STALE_DUP_DETECT=off.
#   • FAIL-SOFT: no item ref, an offline `gh`, a missing base ref, a bad worktree, or any probe failure
#     yields NO hold — the PR proceeds exactly as before. A gate that can't prove a problem stays quiet.
#
# CONTRACT
# --------
# stale_dup_check <pr#> <slug> <dir> <head-sha> <base-branch>
#   returns 0  → PROCEED (not a provable duplicate/stale; or the gate is off)
#   returns 1  → HOLD, and sets two globals the caller renders/journals:
#                  _STALE_DUP_KIND    "duplicate" | "stale-base"
#                  _STALE_DUP_REASON  one-line human reason
# The pure helpers below (stale_dup_extract_ref, stale_dup_base_overlap, and the seam-driven
# _stale_dup_* readers) are sourced + unit-tested directly by tests/test-stale-dup-detect.sh.
#
# Test seams (all HERD_-namespaced so the config-manifest ghost-key lint exempts them):
#   HERD_STALE_DUP_BODY_FILE     read THIS PR's body from this file instead of `gh pr view`
#   HERD_STALE_DUP_MERGED_FILE   read merged-PR refs ("<pr>\t<ref>" per line) from this file, not `gh`
#
# Sourced AFTER herd-config.sh, exactly like human-verify.sh / journal.sh:
#   . "$HERE/stale-dup-gate.sh"

# The shared regenerable-derived-files list (HERD-214) — the stale-base overlap must never count a
# file the engine regenerates (the rendered coordinator skill, .herd/config.local) as work a merge
# could clobber. Sourced by absolute path off THIS file so the gate stays self-sufficient for the
# tests that source it directly.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/derived-files.sh"

# stale_dup_enabled — the master lever. STALE_DUP_DETECT=off disables the gate entirely; any other
# value (default "on") leaves it active. Kept as a function so callers read one obvious predicate.
stale_dup_enabled() {
  [ "${STALE_DUP_DETECT:-on}" != "off" ]
}

# stale_dup_extract_ref — read a PR body on stdin; print the explicit 'Refs: <ID>' tracker ref, or
# nothing. MIRRORS agent-watch.sh:_reconcile_pr_ref so the duplicate check reads refs identically to
# the reconcile path: HTML comment blocks are stripped FIRST (a PR-template example 'Refs:' lives in a
# `<!-- … -->` block and would otherwise poison the extractor), then the first line-anchored 'Refs:'
# token is taken, and template placeholders ('<...>' / none / n/a) are rejected. Fail-soft: any failure
# prints nothing. python3 is a hard engine dependency; a fallback keeps the anchor+placeholder defense
# even if it is somehow absent.
stale_dup_extract_ref() {
  local body ref
  body="$(cat 2>/dev/null || true)"
  [ -n "$body" ] || return 0
  body="$(printf '%s' "$body" | python3 -c 'import sys,re
sys.stdout.write(re.sub(r"<!--.*?-->", "", sys.stdin.read(), flags=re.DOTALL))' 2>/dev/null || printf '%s' "$body")"
  ref="$(printf '%s\n' "$body" \
    | grep -iE '^[[:space:]]*Refs:[[:space:]]*[^[:space:]]' \
    | head -n1 \
    | sed -E 's/^[[:space:]]*[Rr][Ee][Ff][Ss]:[[:space:]]*//; s/[[:space:]].*$//' 2>/dev/null || true)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
  case "$ref" in
    ''|'<'*|none|None|NONE|n/a|N/A|na|NA) return 0 ;;
  esac
  printf '%s' "$ref"
}

# _stale_dup_this_ref <pr#> — extract the ref THIS PR carries. Honors the HERD_STALE_DUP_BODY_FILE
# test seam; otherwise reads the live PR body via `gh`. Empty on any failure (fail-soft).
_stale_dup_this_ref() {
  local pr="$1"
  if [ -n "${HERD_STALE_DUP_BODY_FILE:-}" ]; then
    stale_dup_extract_ref < "$HERD_STALE_DUP_BODY_FILE"
    return 0
  fi
  gh pr view "$pr" --json body -q '.body' 2>/dev/null | stale_dup_extract_ref
}

# _stale_dup_merged_refs <ref> — emit one "<pr>\t<ref>" line per MERGED PR whose body carries a
# 'Refs:' line. Honors the HERD_STALE_DUP_MERGED_FILE test seam (cats it verbatim); otherwise queries
# `gh pr list --state merged --search "<ref> in:body"` (server-side prefilter for cheapness) and
# re-extracts each body's ref LOCALLY with the exact stale_dup_extract_ref rules so the match is
# precise, not a fuzzy full-text hit. Fail-soft: any failure emits nothing.
_stale_dup_merged_refs() {
  local ref="$1"
  if [ -n "${HERD_STALE_DUP_MERGED_FILE:-}" ]; then
    cat "$HERD_STALE_DUP_MERGED_FILE" 2>/dev/null || true
    return 0
  fi
  [ -n "$ref" ] || return 0
  gh pr list --state merged --search "${ref} in:body" --limit 100 \
    --json number,body 2>/dev/null | python3 -c '
import sys, json, re
try:
    prs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
marker = re.compile(r"^[ \t]*Refs:[ \t]*(\S+)", re.IGNORECASE | re.MULTILINE)
for p in prs or []:
    body = p.get("body") or ""
    body = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL)
    m = marker.search(body)
    if not m:
        continue
    r = m.group(1)
    if r.startswith("<") or r.lower() in ("none", "n/a", "na"):
        continue
    print("%s\t%s" % (p.get("number", ""), r))
' 2>/dev/null || true
}

# _stale_dup_shipped_by <ref> <this-pr#> — if some OTHER merged PR ships the SAME ref, print that PR
# number and return 0; otherwise print nothing and return 1. The self-exclusion is essential: a PR must
# never be judged a duplicate of itself (e.g. a reopened PR appearing in the merged set).
_stale_dup_shipped_by() {
  local ref="$1" this="$2" line pr r
  [ -n "$ref" ] || return 1
  while IFS=$'\t' read -r pr r; do
    [ -n "$pr" ] || continue
    [ "$pr" = "$this" ] && continue
    if [ "$r" = "$ref" ]; then
      printf '%s' "$pr"
      return 0
    fi
  done < <(_stale_dup_merged_refs "$ref")
  return 1
}

# stale_dup_base_overlap <dir> <base-branch> <head-ref> — print the files this branch touches that the
# base branch ALSO changed since their common merge-base (one per line), and return 0 iff that overlap
# is non-empty. Returns 1 (no overlap → not stale) when: the dir is not a worktree, a ref is missing,
# the branch already CONTAINS the base tip (merge-base == base tip → not behind → nothing to be stale
# against), either diff is empty, or the whole overlap is REGENERABLE DERIVED FILES (HERD-214: a branch
# cut before the untracking migration carries the rendered coordinator skill as a tracked file, so both
# sides "change" it on every render — re-applying an old render clobbers nothing, since the next
# init/update/reload/render rewrites it from the template). Pure git; no network. Unit-tested against a
# sandbox repo.
stale_dup_base_overlap() {
  local dir="$1" base="$2" head="$3" mb basetip touched moved overlap
  [ -d "$dir" ] || return 1
  mb="$(git -C "$dir" merge-base "$base" "$head" 2>/dev/null)" || return 1
  [ -n "$mb" ] || return 1
  basetip="$(git -C "$dir" rev-parse "$base" 2>/dev/null)" || return 1
  # Branch is up to date with (or ahead of) base on this line of history → not behind → cannot be stale.
  [ "$basetip" = "$mb" ] && return 1
  touched="$(git -C "$dir" diff --name-only "$mb" "$head" 2>/dev/null)" || return 1
  [ -n "$touched" ] || return 1
  moved="$(git -C "$dir" diff --name-only "$mb" "$base" 2>/dev/null)" || return 1
  [ -n "$moved" ] || return 1
  # Exact path intersection (-Fx: fixed-string, whole-line) — the files BOTH sides changed.
  overlap="$(printf '%s\n' "$touched" | grep -Fxf <(printf '%s\n' "$moved") 2>/dev/null || true)"
  [ -n "$overlap" ] || return 1
  # Drop the regenerable derived files: an overlap made only of those proves nothing.
  overlap="$(printf '%s\n' "$overlap" | herd_strip_derived)"
  [ -n "$overlap" ] || return 1
  printf '%s\n' "$overlap"
}

# stale_dup_check <pr#> <slug> <dir> <head-sha> <base-branch> — the gate. See the contract at the top.
# Order: DUPLICATE first (the cheaper, ground-truth "already shipped" test; skipped fail-soft when the
# PR carries no ref), then STALE BASE. Sets _STALE_DUP_KIND + _STALE_DUP_REASON on a hold (return 1).
stale_dup_check() {
  local pr="$1" slug="$2" dir="$3" head="$4" base="$5"
  _STALE_DUP_KIND=""; _STALE_DUP_REASON=""
  stale_dup_enabled || return 0

  # (1) DUPLICATE — this PR's tracked item ref already shipped via another merged PR.
  local ref shipper
  ref="$(_stale_dup_this_ref "$pr" 2>/dev/null || true)"
  if [ -n "$ref" ]; then
    shipper="$(_stale_dup_shipped_by "$ref" "$pr" 2>/dev/null || true)"
    if [ -n "$shipper" ]; then
      _STALE_DUP_KIND="duplicate"
      _STALE_DUP_REASON="tracked item ${ref} already shipped by merged PR #${shipper} — this PR re-implements Done work"
      return 1
    fi
  fi

  # (2) STALE BASE — touched files the base branch materially changed by a merge this branch predates.
  local overlap count first
  overlap="$(stale_dup_base_overlap "$dir" "$base" "$head" 2>/dev/null || true)"
  if [ -n "$overlap" ]; then
    count="$(printf '%s\n' "$overlap" | grep -c . 2>/dev/null || printf '0')"
    first="$(printf '%s\n' "$overlap" | head -n1)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
    _STALE_DUP_KIND="stale-base"
    _STALE_DUP_REASON="stale base: ${count} touched file(s) were changed on ${base} after this branch's merge-base (e.g. ${first}) — merging would silently clobber newer work"
    return 1
  fi

  return 0
}
