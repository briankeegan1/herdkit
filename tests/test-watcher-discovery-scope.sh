#!/usr/bin/env bash
# test-watcher-discovery-scope.sh — hermetic sim for the watcher's SCOPED feature-worktree discovery
# (HERD-182). GROUNDED INCIDENT: a builder ran `git worktree add --detach HEAD /tmp/hk-base`; the old
# discovery parse collected EVERY worktree except $MAIN, so that detached-HEAD checkout — with no
# agent and no PR — rendered as a phantom 💀 dead-builder row in the watch console and confused the
# operator. The fix scopes discovery to $WORKTREES_DIR ($TREES) AND filters detached-HEAD / non-builder
# worktrees, so a phantom never reaches the dead-builder reconciliation at all.
#
# It sources agent-watch.sh's helpers via the AGENT_WATCH_LIB guard (no live watch loop), builds a REAL
# throwaway git repo with a legitimate builder worktree plus several phantom worktrees, and drives the
# pure discovery helper against real `git worktree list --porcelain` output. Asserts:
#   • a legitimate builder worktree UNDER $TREES with a branch IS discovered (byte-identical record)
#   • a detached-HEAD worktree OUTSIDE $TREES (the grounded /tmp/hk-base case) is NOT discovered
#   • a detached-HEAD worktree UNDER   $TREES is NOT discovered (detached filter)
#   • a BRANCH worktree OUTSIDE $TREES is NOT discovered (scope filter)
#   • the $MAIN checkout is never discovered
#   • fail-soft: with $TREES empty, the scope test is skipped but detached HEADs are still filtered
#   • a phantom is never handed to _reconcile_dead_builder, so it can never surface as 💀 dead
# Run:  bash tests/test-watcher-discovery-scope.sh
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

# ── Source the watcher helpers WITHOUT its live loop; point config at a nonexistent file so
#    herd-config.sh falls back to generic defaults (fully hermetic, no repo/.herd walk-up). ──────────
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type _discover_feature_worktrees >/dev/null 2>&1 || fail "_discover_feature_worktrees not defined"

# ── Build a REAL git repo: one legit builder worktree + assorted phantoms. ──────────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
MAIN="$T/main"
TREES="$T/trees"; mkdir -p "$TREES"
git init -q "$MAIN"
( cd "$MAIN" && git commit -q --allow-empty -m init )

# (1) legitimate builder worktree: UNDER $TREES, on a branch.
git -C "$MAIN" worktree add -q -b feat/alpha "$TREES/feat-alpha" >/dev/null 2>&1 \
  || fail "could not create legit builder worktree"
# (2) the GROUNDED phantom: detached HEAD OUTSIDE $TREES (mirrors /tmp/hk-base).
git -C "$MAIN" worktree add -q --detach "$T/hk-base" HEAD >/dev/null 2>&1 \
  || fail "could not create detached phantom outside trees"
# (3) detached HEAD UNDER $TREES — the scope test would keep it; the detached filter must drop it.
git -C "$MAIN" worktree add -q --detach "$TREES/detached-inside" HEAD >/dev/null 2>&1 \
  || fail "could not create detached phantom inside trees"
# (4) a BRANCH worktree OUTSIDE $TREES — has a branch, but out of scope.
git -C "$MAIN" worktree add -q -b feat/outside "$T/outside-branch" >/dev/null 2>&1 \
  || fail "could not create out-of-scope branch worktree"

WT="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null)"
[ -n "$WT" ] || fail "git worktree list produced no output"

# No PRs, no agents: every worktree is PR-less and agent-less — exactly the state in which a phantom
# would be mis-flagged as a dead builder. A legit builder here reads as a benign idle row, never dead.
export PRS_JSON='[]'
export AGENTS_JSON='{"result":{"agents":[]}}'

_discover() { WT="$WT" MAIN="$MAIN" TREES="$1" _discover_feature_worktrees; }
_slugs()    { while IFS=$'\037' read -r _d slug _rest; do [ -n "$slug" ] && printf '%s\n' "$slug"; done; }

# ── Scoped discovery: only the legit builder survives. ──────────────────────────────────────────────
OUT="$(_discover "$TREES")"
SLUGS="$(printf '%s\n' "$OUT" | _slugs | sort | tr '\n' ',' )"
[ "$SLUGS" = "feat-alpha," ] || fail "scoped discovery should yield ONLY feat-alpha, got: [$SLUGS]"
ok

printf '%s\n' "$OUT" | _slugs | grep -qx hk-base          && fail "detached /tmp-style phantom must NOT be discovered"
printf '%s\n' "$OUT" | _slugs | grep -qx detached-inside  && fail "detached-HEAD under \$TREES must NOT be discovered"
printf '%s\n' "$OUT" | _slugs | grep -qx outside-branch   && fail "out-of-scope branch worktree must NOT be discovered"
printf '%s\n' "$OUT" | _slugs | grep -qx main             && fail "\$MAIN must never be discovered"
ok

# ── The legit builder's record is byte-identical to the pre-fix format, plus HERD-226's two trailing
#    join-provenance fields (matchkind, matchdetail) — both EMPTY here: no PRs, so no join at all. ───
# The emitted dir is git's CANONICAL worktree path (`git worktree list --porcelain`), which git stores
# symlink-RESOLVED — on macOS the $TMPDIR symlink /var/folders/… becomes /private/var/folders/…. $TREES
# is the UNRESOLVED symlink, so build the expected dir through the SAME physical-path resolution git
# applied (`cd … && pwd -P`), else the byte-compare splits on /var vs /private/var. That split is exactly
# how this test (inherited from #290) first failed on macOS CI though it passes where $TMPDIR is unresolved;
# normalizing the one machine-specific field keeps the record byte-exact AND env-robust.
REC="$(printf '%s\n' "$OUT" | grep -F "$(printf 'feat-alpha')")"
ALPHA_DIR="$(cd "$TREES/feat-alpha" && pwd -P)"
EXPECT="$(printf '%s\037%s\037%s\037\037\037\037\037\037\037\037' "$ALPHA_DIR" "feat-alpha" "feat/alpha")"
[ "$REC" = "$EXPECT" ] || fail "legit builder record not byte-identical.
  want: $(printf '%s' "$EXPECT" | cat -v)
  got:  $(printf '%s' "$REC" | cat -v)"
ok

# ── Fail-soft: with $TREES empty the scope test is skipped, but detached HEADs are STILL filtered ──
#    (the branch worktree outside trees is now in-scope; both detached phantoms remain excluded).  ──
OUT_NS="$(_discover "")"
NS_SLUGS="$(printf '%s\n' "$OUT_NS" | _slugs | sort | tr '\n' ',')"
[ "$NS_SLUGS" = "feat-alpha,outside-branch," ] \
  || fail "fail-soft (empty TREES) should keep both branch worktrees, drop detached, got: [$NS_SLUGS]"
printf '%s\n' "$OUT_NS" | _slugs | grep -qx hk-base         && fail "fail-soft must still drop detached /tmp phantom"
printf '%s\n' "$OUT_NS" | _slugs | grep -qx detached-inside && fail "fail-soft must still drop detached-under-trees phantom"
ok

# ── End-to-end intent: because the phantom never enters the roster, the dead-builder reconciliation
#    is never invoked for it — so it can never render as 💀 dead. Prove the classifier WOULD have
#    called it dead had discovery leaked it (i.e. the fix is what protects us, not the classifier). ──
DEAD_STATE="$T/.agent-watch-dead"; : > "$DEAD_STATE"
GRACE="$(_dead_grace_secs)"
NOW=1000000000
# has-agent=0 has-pr=0 transcript=none first-seen=past-grace → the phantom's exact signature is DEAD.
[ "$(_classify_dead_builder 0 0 no "$((NOW-GRACE-1))" "$NOW" "$GRACE")" = "DEAD" ] \
  || fail "sanity: the phantom's signature must classify as DEAD when leaked — proving the scope fix is load-bearing"
# …yet no discovered slug carries that signature, so the reconciliation is never reached for a phantom.
printf '%s\n' "$OUT" | _slugs | grep -qxvE 'feat-alpha' && fail "no non-builder slug may reach dead-builder classification"
ok

echo "ALL PASS ($PASS groups)"
