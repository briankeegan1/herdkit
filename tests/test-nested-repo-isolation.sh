#!/usr/bin/env bash
# test-nested-repo-isolation.sh — the EMPIRICAL half of HERD-435 / GitHub issue #547: what actually
# happens to an UNRELATED git repo placed INSIDE a herdkit tree when the engine does its git work?
#
# The issue asked whether such a repo could be "staged, committed, moved, or worktree'd" by herdkit.
# This test does not reason about it — it puts a real nested repo in a fixture tree, runs the REAL
# engine commit paths over it, and asserts the OBSERVED guarantee:
#
#   A nested git repo inside the herdkit tree is NEVER staged, committed, moved, or deleted by the
#   engine's git operations. It stays untracked (`?? game/` in status), keeps its own HEAD, and never
#   appears in `git ls-files`. It is also absent from every builder worktree, because a worktree is a
#   checkout of a branch that never contained it.
#
# The engine paths exercised are the real ones, not re-implementations:
#   • scripts/herd/backends/file.sh  `_backend_add_item` / `_file_marker_commit` / `_backend_claim_item`
#     — the scribe's named-`git add` + index-scoped commit, the only production code that commits to
#     the operator's live checkout on the CLI side.
#   • the watcher's reconcile-refresh commit SHAPE (`git -C MAIN commit -m msg -- <out>`,
#     agent-watch.sh:5453/5550) — the only AUTOMATIC commit the engine makes.
#   • `git worktree add` into the sibling pool ($WORKTREES_DIR = "${PROJECT_ROOT}-trees").
#   • `git reset --hard`, the engine's rollback shape (agent-watch.sh:5480/5575, file.sh:346/392).
#
# The COUNTERFACTUAL is asserted too: `git add -A` in the same tree DOES swallow the nested repo as a
# gitlink. That is the exact hazard scripts/herd/git-scope-lint.sh now reds in production paths — so
# this test documents both the guarantee and why the guard has to exist.
#
# Network-free: temp dirs + local repos only. Run:  bash tests/test-nested-repo-isolation.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BACKEND="$ROOT/scripts/herd/backends/file.sh"

[ -f "$BACKEND" ] || { echo "FAIL: missing backend: $BACKEND" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

MAIN="$T/project"          # the herdkit tree (stands in for $PROJECT_ROOT)
NESTED="$MAIN/game"        # the unrelated project repo living INSIDE it
TREES="$T/project-trees"   # the sibling worktree pool ($WORKTREES_DIR)

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# ── fixture: a herdkit-ish repo with a foreign repo nested inside it ─────────────────────────────
mkdir -p "$MAIN"
git_q "$MAIN" init || fail "setup: git init"
git_q "$MAIN" config user.email t@t.t
git_q "$MAIN" config user.name t
git_q "$MAIN" config commit.gpgsign false
printf '## Backlog\n\n🔜 open-feature — a queued item\n' > "$MAIN/BACKLOG.md"
git_q "$MAIN" add BACKLOG.md
git_q "$MAIN" commit -m "seed backlog" || fail "setup: seed commit"

mkdir -p "$NESTED"
git_q "$NESTED" init || fail "setup: nested git init"
git_q "$NESTED" config user.email g@g.g
git_q "$NESTED" config user.name g
git_q "$NESTED" config commit.gpgsign false
printf 'level 1\n' > "$NESTED/level.txt"
git_q "$NESTED" add level.txt
git_q "$NESTED" commit -m "game init" || fail "setup: nested seed commit"
NESTED_HEAD="$(git -C "$NESTED" rev-parse HEAD)"

# assert_untouched <label> — the whole guarantee, re-asserted after each engine operation.
assert_untouched() {
  local label="$1" tracked status
  [ -d "$NESTED/.git" ] || fail "$label: the nested repo's .git is gone — it was moved or deleted"
  [ -f "$NESTED/level.txt" ] || fail "$label: the nested repo's content is gone"
  [ "$(git -C "$NESTED" rev-parse HEAD)" = "$NESTED_HEAD" ] \
    || fail "$label: the nested repo's HEAD moved — something committed inside it"
  tracked="$(git -C "$MAIN" ls-files)"
  grep -q '^game' <<< "$tracked" && fail "$label: the nested repo is TRACKED by the outer repo: $tracked"
  status="$(git -C "$MAIN" status --porcelain -- game 2>/dev/null)"
  [ "$status" = "?? game/" ] \
    || fail "$label: expected the nested repo to stay untracked ('?? game/'), got '$status'"
  local hist; hist="$(git -C "$MAIN" log --format=%H --all -- game)"
  [ -n "$hist" ] && fail "$label: the nested repo appears in the outer repo's history"
  return 0
}

assert_untouched "baseline"
pass
echo "PASS (1) baseline: a nested foreign repo reads as one untracked entry ('?? game/') and nothing more"

# ── 2. the scribe file backend's add-item op (named add + index-scoped commit) ────────────────────
run_backend() {
  ( cd "$MAIN" && . "$BACKEND" >/dev/null 2>&1
    BACKLOG_FILE="$MAIN/BACKLOG.md"; DEFAULT_BRANCH="origin/main"
    HERD_REMOTE="origin"; HERD_BRANCH_NAME="main"
    _BACKEND_RESULT=""
    "$@" >/dev/null 2>&1
    printf '%s\n' "${_BACKEND_RESULT:-}" )
}

printf '## Backlog\n\n🔜 open-feature — a queued item\n🔜 new-item — added by the scribe\n' > "$MAIN/BACKLOG.md"
res="$(run_backend _backend_add_item "$MAIN/BACKLOG.md" "add new-item")"
[ "$res" = "DONE" ] || fail "(2) the file backend's add-item should have committed (got '$res')"
assert_untouched "after _backend_add_item"
grep -q 'BACKLOG.md' <<< "$(git -C "$MAIN" show --stat --format= HEAD)" \
  || fail "(2) the scribe commit should touch BACKLOG.md"
[ "$(git -C "$MAIN" show --name-only --format= HEAD | grep -c .)" -eq 1 ] \
  || fail "(2) the scribe commit must touch exactly ONE file: $(git -C "$MAIN" show --name-only --format= HEAD)"
pass
echo "PASS (2) scribe backend add-item: commits ONLY BACKLOG.md — the nested repo is not staged"

# ── 3. the marker-commit op (queue/unqueue), same shape ──────────────────────────────────────────
printf '## Backlog\n\n📌 open-feature — queued\n' > "$MAIN/BACKLOG.md"
run_backend _file_marker_commit "Queue: open-feature" >/dev/null
assert_untouched "after _file_marker_commit"
pass
echo "PASS (3) scribe backend marker-commit: same guarantee — the nested repo stays untracked"

# ── 4. the watcher's AUTOMATIC reconcile-refresh commit shape (pathspec-scoped) ──────────────────
# agent-watch.sh:5453 / :5550 — `git -C "$MAIN" commit -q -m "$msg" -- "$out"`. This is the only
# commit the engine makes with no human in the loop, so it is the one that matters most here.
mkdir -p "$MAIN/docs"
printf '# codemap\n' > "$MAIN/docs/codemap.md"
git_q "$MAIN" add docs/codemap.md
git -C "$MAIN" commit -q -m "chore: refresh codemap (reconcile)" -- docs/codemap.md >/dev/null 2>&1 \
  || fail "(4) the reconcile-shape commit should succeed"
assert_untouched "after the reconcile-shape commit"
[ "$(git -C "$MAIN" show --name-only --format= HEAD | grep -c .)" -eq 1 ] \
  || fail "(4) a pathspec-scoped commit must touch exactly its one output file"
pass
echo "PASS (4) watcher reconcile commit ('commit -m msg -- <out>'): confined to its one output file"

# ── 5. worktree creation into the SIBLING pool ───────────────────────────────────────────────────
mkdir -p "$TREES"
git_q "$MAIN" branch feat-x
git -C "$MAIN" worktree add -q "$TREES/feat-x" feat-x >/dev/null 2>&1 \
  || fail "(5) worktree add should succeed"
[ -d "$TREES/feat-x" ] || fail "(5) the worktree was not created"
assert_untouched "after git worktree add"
[ -e "$TREES/feat-x/game" ] && fail "(5) the nested repo leaked into a builder worktree"
wtlist="$(git -C "$MAIN" worktree list)"
grep -q 'game' <<< "$wtlist" && fail "(5) the nested repo was registered as a worktree: $wtlist"
case "$TREES" in "$MAIN"/*) fail "(5) WORKTREES_DIR must be a SIBLING of PROJECT_ROOT, not inside it" ;; esac
pass
echo "PASS (5) 'git worktree add' into the sibling pool: nested repo untouched and absent from the worktree"

# ── 6. the engine's rollback shape ('git reset --hard') does not delete it ───────────────────────
# reset --hard rewrites TRACKED paths only; an untracked directory is left alone. (`git clean` WOULD
# delete it — which is why no production engine path runs one; see docs/isolation-boundary.md.)
git_q "$MAIN" reset --hard HEAD || fail "(6) reset --hard should succeed"
assert_untouched "after git reset --hard"
pass
echo "PASS (6) 'git reset --hard' (the engine's rollback shape): the untracked nested repo survives intact"

# ── 7. COUNTERFACTUAL — 'git add -A' DOES swallow it (why the lint has to exist) ─────────────────
git -C "$MAIN" add -A >/dev/null 2>&1
staged="$(git -C "$MAIN" diff --cached --name-only)"
grep -q '^game$' <<< "$staged" \
  || fail "(7) expected 'git add -A' to stage the nested repo as a gitlink (got: $staged)"
git_q "$MAIN" reset
assert_untouched "after resetting the counterfactual"
pass
echo "PASS (7) counterfactual: 'git add -A' DOES stage the nested repo as a gitlink — the exact shape git-scope-lint.sh reds"

echo
echo "ALL PASS ($PASS checks) — observed guarantee: a nested foreign repo is never staged, committed, moved or deleted by engine git operations."
