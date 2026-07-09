#!/usr/bin/env bash
# test-watcher-sha-join.sh — hermetic fixtures for the watcher's SHA-RESILIENT worktree↔PR join and
# the branch auto-repair that follows it (HERD-226).
#
# GROUNDED INCIDENT: a resolver exited leaving its worktree on the scratch branch `pr328`. The watcher
# joined worktrees to PRs by BRANCH NAME only, so PR #328 matched nothing: it was invisible for ~20 min
# — no gates ran, and the console painted the builder as '💤 awaiting task · assign or retire'. The fix
# adds a fallback join on the HEAD commit (a worktree HEAD equal to exactly ONE unmatched open PR's
# headRefOid IS that PR), then repairs the ref when — and only when — the repair is provably lossless.
#
# It sources agent-watch.sh's helpers via the AGENT_WATCH_LIB guard (no live watch loop) and drives the
# pure helpers against a REAL throwaway git repo and real `git worktree list --porcelain` output.
# Asserts:
#   • scratch branch + matching oid → MATCHED (pr fields populated), matchkind=sha, gates keyed to the
#     PR's real head sha; the ref is REPAIRED (branch switched) and `branch_repaired` is journaled
#   • a DIRTY worktree            → matched, but NO repair; the truthful mismatch text, not a claim
#   • a DIVERGED local PR branch  → matched, but NO repair (a diverged ref is never clobbered)
#   • two PRs sharing one oid     → AMBIG: no pr fields, no repair, mismatch row — never 'awaiting task'
#   • names already match         → byte-identical record (plus matchkind=branch); repair never fires
#   • no PR at the worktree's oid → a genuine spare: no match, no mismatch, no repair
# Run:  bash tests/test-watcher-sha-join.sh
# No `set -e`: some predicates are asserted explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git     >/dev/null 2>&1 || fail "git required to run this test"

# Hermetic: generic config defaults, and every journal_append lands in OUR file (HERD-223 guard).
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export HERMETIC_TEST=1
export JOURNAL_FILE="$T/journal.jsonl"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _discover_feature_worktrees _repair_branch_ref _branch_mismatch_text _row_branch_mismatch; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

# ── A real repo: one worktree per fixture shape, each on its own commit. ────────────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
MAIN="$T/main"
TREES="$T/trees"; mkdir -p "$TREES"
git init -q "$MAIN"
( cd "$MAIN" && git commit -q --allow-empty -m init )

# Each worktree gets a UNIQUE commit so oids never collide by accident; the ambiguity fixture is the
# only place two PRs deliberately share one.
_wt() {  # _wt <dirname> <branch> — a worktree on its own branch with one extra commit
  git -C "$MAIN" worktree add -q -b "$2" "$TREES/$1" >/dev/null 2>&1 || fail "worktree add $1 failed"
  ( cd "$TREES/$1" && echo "$1" > file.txt && git add file.txt && git commit -q -m "$1" ) || fail "commit $1"
}
_head() { git -C "$TREES/$1" rev-parse HEAD; }
_br()   { git -C "$TREES/$1" symbolic-ref --short HEAD 2>/dev/null; }

_wt scratch   pr328      # the grounded case: resolver left it on a scratch branch
_wt beta      feat/beta  # names already match its PR
_wt dirty     scratch2   # sha matches, but the tree has uncommitted work
_wt diverged  scratch3   # sha matches, but the PR's local branch has diverged
_wt ambig     scratch4   # its commit is the head of TWO open PRs
_wt spare     feat/spare # a genuine PR-less spare

echo "unstaged" >> "$TREES/dirty/file.txt"   # → dirty tree

SHA_SCRATCH="$(_head scratch)"; SHA_BETA="$(_head beta)"
SHA_DIRTY="$(_head dirty)";     SHA_DIV="$(_head diverged)"; SHA_AMBIG="$(_head ambig)"

# The DIVERGED fixture: PR #77's local branch sits on a SIBLING commit — not an ancestor of the
# worktree's HEAD, so no fast-forward exists and the repair must refuse rather than clobber it.
git -C "$MAIN" branch feat/div "$SHA_AMBIG"

# The open-PR roster exactly as `gh pr list` renders it for this tick.
PRS_JSON="$(python3 - "$SHA_SCRATCH" "$SHA_BETA" "$SHA_DIRTY" "$SHA_DIV" "$SHA_AMBIG" <<'PY'
import json, sys
s, b, d, v, a = sys.argv[1:6]
def pr(n, ref, oid, ms="CLEAN"):
    return {"number": n, "headRefName": ref, "headRefOid": oid, "mergeable": "MERGEABLE",
            "mergeStateStatus": ms, "author": {"login": "briankeegan1"}}
print(json.dumps([
    pr(328, "feat/real",  s),          # branch name lost → must sha-join + repair
    pr(12,  "feat/beta",  b),          # ordinary branch join
    pr(99,  "feat/dirty", d),          # sha-joins, but the worktree is dirty → no repair
    pr(77,  "feat/div",   v),          # sha-joins, but feat/div diverged locally → no repair
    pr(41,  "feat/x",     a),          # ─┬─ two PRs, one commit → ambiguous
    pr(42,  "feat/y",     a),          # ─┘
]))
PY
)"
export PRS_JSON
export AGENTS_JSON='{"result":{"agents":[]}}'

_discover() {
  WT="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null)" MAIN="$MAIN" TREES="$TREES" \
    _discover_feature_worktrees
}
_rec() { printf '%s\n' "$1" | awk -F'\037' -v s="$2" '$2 == s'; }
_f()   { printf '%s\n' "$1" | cut -d$'\037' -f"$2"; }

OUT="$(_discover)"
[ -n "$OUT" ] || fail "discovery produced no records"

# ── 1. The grounded case: scratch branch, matching oid → matched, sha-keyed, repaired, journaled. ───
R="$(_rec "$OUT" scratch)"
[ -n "$R" ] || fail "the scratch-branch worktree was not discovered at all"
[ "$(_f "$R" 4)"  = "328" ]           || fail "scratch worktree must sha-join PR #328, got pr=[$(_f "$R" 4)]"
[ "$(_f "$R" 10)" = "sha" ]           || fail "matchkind must be 'sha', got [$(_f "$R" 10)]"
[ "$(_f "$R" 11)" = "feat/real" ]     || fail "matchdetail must name the PR's branch, got [$(_f "$R" 11)]"
[ "$(_f "$R" 8)"  = "$SHA_SCRATCH" ]  || fail "gates must key to the PR head sha, got [$(_f "$R" 8)]"
[ "$(_f "$R" 5)"  = "MERGEABLE" ]     || fail "a sha-joined row must carry the PR's mergeable state"
ok

[ "$(_repair_branch_ref "$TREES/scratch" pr328 feat/real "$SHA_SCRATCH" 328 scratch)" = "REPAIRED" ] \
  || fail "a clean worktree whose HEAD is the PR head must be repaired"
[ "$(_br scratch)" = "feat/real" ] || fail "repair must check out the PR's branch, on [$(_br scratch)]"
[ "$(git -C "$TREES/scratch" rev-parse HEAD)" = "$SHA_SCRATCH" ] || fail "repair must not move HEAD"
grep -q '"event":"branch_repaired"' "$JOURNAL_FILE" || fail "repair must journal branch_repaired"
grep -q '"from_branch":"pr328"'     "$JOURNAL_FILE" || fail "branch_repaired must record the stale ref"
grep -q '"to_branch":"feat/real"'   "$JOURNAL_FILE" || fail "branch_repaired must record the repaired ref"
ok

# …and the repair is self-closing: the next tick's CHEAP branch-name join matches it, no fallback.
R2="$(_rec "$(_discover)" scratch)"
[ "$(_f "$R2" 4)"  = "328" ]      || fail "after repair the branch join must find PR #328"
[ "$(_f "$R2" 10)" = "branch" ]   || fail "after repair matchkind must be 'branch', got [$(_f "$R2" 10)]"
ok

# ── 2. Dirty tree: matched (gating proceeds), never repaired, truthful mismatch text. ───────────────
R="$(_rec "$OUT" dirty)"
[ "$(_f "$R" 4)"  = "99" ]  || fail "a dirty worktree must STILL sha-join its PR (gating never blocked)"
[ "$(_f "$R" 10)" = "sha" ] || fail "dirty worktree matchkind must be 'sha'"
[ "$(_repair_branch_ref "$TREES/dirty" scratch2 feat/dirty "$SHA_DIRTY" 99 dirty)" = "SKIP" ] \
  || fail "a dirty worktree must NEVER be repaired"
[ "$(_br dirty)" = "scratch2" ] || fail "a skipped repair must leave the worktree on its branch"
[ "$(_branch_mismatch_text scratch2 feat/dirty)" = "branch mismatch — worktree on scratch2, PR head is feat/dirty" ] \
  || fail "mismatch text must name both refs"
ok

# ── 3. Diverged local PR branch: matched, never clobbered. ──────────────────────────────────────────
R="$(_rec "$OUT" diverged)"
[ "$(_f "$R" 4)"  = "77" ]  || fail "the diverged fixture must still sha-join PR #77"
[ "$(_repair_branch_ref "$TREES/diverged" scratch3 feat/div "$SHA_DIV" 77 diverged)" = "SKIP" ] \
  || fail "a diverged local PR branch must NEVER be fast-forwarded over"
[ "$(git -C "$MAIN" rev-parse feat/div)" != "$SHA_DIV" ] || fail "feat/div must still point where it did"
[ "$(_br diverged)" = "scratch3" ] || fail "a skipped repair must leave the worktree on its branch"
ok

# ── 4. Two PRs on one commit: ambiguous — no PR fields, no repair, and NEVER 'awaiting task'. ───────
R="$(_rec "$OUT" ambig)"
[ -z "$(_f "$R" 4)" ]         || fail "an ambiguous match must NOT claim a PR, got pr=[$(_f "$R" 4)]"
[ "$(_f "$R" 10)" = "ambig" ] || fail "matchkind must be 'ambig', got [$(_f "$R" 10)]"
case "$(_f "$R" 11)" in
  "ambiguous (#41,#42 share this commit)") ;;
  *) fail "ambiguous detail must name the colliding PRs, got [$(_f "$R" 11)]" ;;
esac
ROW="$(_row_branch_mismatch ambig "$(_branch_mismatch_text scratch4 "$(_f "$R" 11)")")"
case "$ROW" in
  *"branch mismatch — worktree on scratch4"*) ;;
  *) fail "the ambiguous row must render the mismatch, got [$ROW]" ;;
esac
case "$ROW" in *"awaiting task"*) fail "an ambiguous row must never claim 'awaiting task'" ;; esac
[ "$(_br ambig)" = "scratch4" ] || fail "ambiguity must never trigger a repair"
ok

# ── 5. Names already match: the record is byte-identical to the pre-HERD-226 join. ──────────────────
R="$(_rec "$OUT" beta)"
BETA_DIR="$(cd "$TREES/beta" && pwd -P)"   # git stores worktree paths symlink-resolved (macOS $TMPDIR)
EXPECT="$(printf '%s\037beta\037feat/beta\03712\037MERGEABLE\037CLEAN\037\037%s\037briankeegan1\037branch\037' \
  "$BETA_DIR" "$SHA_BETA")"
[ "$R" = "$EXPECT" ] || fail "a name-matched record must be unchanged (+matchkind=branch).
  want: $(printf '%s' "$EXPECT" | cat -v)
  got:  $(printf '%s' "$R" | cat -v)"
# The repair helper is a no-op on a worktree already on its PR's branch, even if called.
[ "$(_repair_branch_ref "$TREES/beta" feat/beta feat/beta "$SHA_BETA" 12 beta)" = "SKIP" ] \
  || fail "repair must no-op when the names already match"
ok

# ── 6. A genuine spare: no PR at its oid → no match, no mismatch, still a plain PR-less row. ────────
R="$(_rec "$OUT" spare)"
[ -z "$(_f "$R" 4)"  ] || fail "the spare must have no PR"
[ -z "$(_f "$R" 10)" ] || fail "the spare's matchkind must be empty (no join attempted), got [$(_f "$R" 10)]"
[ -z "$(_f "$R" 11)" ] || fail "the spare must carry no mismatch detail"
ok

# ── 7. Fail-soft: repair refuses on a missing worktree / empty PR branch, and under DRYRUN. ─────────
[ "$(_repair_branch_ref "$T/nope" pr328 feat/real "$SHA_SCRATCH" 328 nope)" = "SKIP" ] \
  || fail "repair must fail-soft on a missing worktree"
[ "$(_repair_branch_ref "$TREES/dirty" scratch2 "" "$SHA_DIRTY" 99 dirty)" = "SKIP" ] \
  || fail "repair must fail-soft when the PR branch is unknown"
[ "$(DRYRUN=1 _repair_branch_ref "$TREES/diverged" scratch3 feat/other "$SHA_DIV" 77 diverged)" = "SKIP" ] \
  || fail "repair must never touch git under DRYRUN"
[ "$(_br diverged)" = "scratch3" ] || fail "DRYRUN repair must not have switched branches"
ok

echo "ALL PASS ($PASS groups)"
