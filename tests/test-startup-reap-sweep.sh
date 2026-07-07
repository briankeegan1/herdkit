#!/usr/bin/env bash
# test-startup-reap-sweep.sh — hermetic tests for the STARTUP reap-sweep (HERD-91): resume teardown
# for a worktree whose PR merged but whose reap never ran (the crash-between-merge-and-reap window,
# PR #208). Exercises agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) with gh/git/herdr stubbed on
# PATH so NO network / real worktree / real tab is ever touched.
#
# SAFETY INVARIANT under test: the sweep reaps a worktree ONLY when its current HEAD sha equals the
# headRefOid of a MERGED PR — so it can NEVER force-remove a live in-flight builder (a re-spawned
# slug carrying a stale ledger row, an in-flight build with no PR yet, or a reused branch name whose
# stale MERGED PR does not match the new HEAD).
#
#   (1) helpers defined after sourcing
#   (2) _reap_slug idempotent primitive: removes worktree, reaps marker, journals reap; re-run harmless
#   (3) STRANDED, branch present — gh MERGED with headRefOid == worktree HEAD → reaped, reason=startup-sweep
#   (4) STRANDED, branch deleted at merge — gh silent on branch but the ledger PR is MERGED with a
#       matching headRefOid → reaped via the ledger fallback (sha still enforced)
#   (5) NORMAL startup — an OPEN-PR worktree → zero action
#   (6) REUSED SLUG, no PR yet (the reviewer's data-loss case) — stale ledger row, gh silent on the
#       new branch, ledger PR MERGED but headRefOid != new HEAD → NOT reaped
#   (7) REUSED BRANCH name — gh returns the OLD merged PR whose headRefOid != new HEAD → NOT reaped
#   (8) DIRTY worktree — even with a MERGED+matching-HEAD PR, an uncommitted tree is NOT force-removed
#   (9) SELF worktree is never reaped
#
# Run:  bash tests/test-startup-reap-sweep.sh
# No `set -e`: several checks assert conditions explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH (NETWORK-FREE) ──────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
export GIT_LOG="$T/git.log"; : > "$GIT_LOG"
export GIT_WT_FILE="$T/worktrees.porcelain"; : > "$GIT_WT_FILE"
export GH_DIR="$T/gh"; mkdir -p "$GH_DIR"
# git: log every call; parse `-C <dir>`; answer `worktree list --porcelain` from $GIT_WT_FILE,
# `rev-parse HEAD` from <dir>/.fakehead, `status --porcelain` from <dir>/.fakedirty; no-op the rest.
cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_LOG"
dir=""; prev=""
for a in "$@"; do [ "$prev" = "-C" ] && dir="$a"; prev="$a"; done
case "$*" in
  *"worktree list"*)     cat "$GIT_WT_FILE" 2>/dev/null ;;
  *"rev-parse HEAD"*)    [ -f "$dir/.fakehead" ]  && cat "$dir/.fakehead" ;;
  *"status --porcelain"*)[ -f "$dir/.fakedirty" ] && cat "$dir/.fakedirty" ;;
esac
exit 0
STUB
# gh: `gh pr view <arg> --json ... -q ...` → emit the stored "state<TAB>oid<TAB>number" for <arg>
# ($GH_DIR/<arg>), or nothing (no PR / deleted branch / gh down). Ignores the -q template (the stored
# line already has the shape the real -q produces).
export GH_LOG="$T/gh.log"; : > "$GH_LOG"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  [ -f "$GH_DIR/${3:-}" ] && cat "$GH_DIR/${3:-}"
fi
exit 0
STUB
# herdr: log calls; return empty-but-valid JSON for the list subcommands so herd_teardown_slug /
# herd_resolve_workspace_id run their parse paths and no-op cleanly.
export HERDR_LOG="$T/herdr.log"; : > "$HERDR_LOG"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_LOG"
case "$*" in
  "workspace list") printf '{"result":{"workspaces":[]}}\n' ;;
  "tab list")       printf '{"result":{"tabs":[]}}\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/git" "$BIN/gh" "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ─────────────────────────────────────────
export AGENT_WATCH_LIB=1
export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT"      # MAIN=$PROJECT_ROOT
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"    # TREES + STATE + markers live here
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"   # journal test seam
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

reap_events() { grep -c '"event":"reap"' "$JOURNAL_FILE" 2>/dev/null || true; }

# Test fixtures --------------------------------------------------------------
# set_head <dir> <sha>          — the worktree's local HEAD (git rev-parse HEAD)
set_head()  { printf '%s' "$2" > "$1/.fakehead"; }
# make_dirty <dir>              — mark the worktree tree as carrying uncommitted changes
make_dirty(){ printf ' M some/file\n' > "$1/.fakedirty"; }
# gh_pr <key> <state> <oid> <n> — register a gh pr view response keyed by branch name OR pr number
# (branch keys carry a '/', so materialize the parent dir; the gh stub reads the same path).
gh_pr()     { mkdir -p "$(dirname "$GH_DIR/$1")"; printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$GH_DIR/$1"; }
# write_worktrees "dir|branch" ... — porcelain output for MAIN + the given feature worktrees
write_worktrees() {
  { printf 'worktree %s\nHEAD aaaa\nbranch refs/heads/main\n\n' "$MAIN"
    local pair dir br
    for pair in "$@"; do dir="${pair%%|*}"; br="${pair#*|}"
      printf 'worktree %s\nHEAD bbbb\nbranch refs/heads/%s\n\n' "$dir" "$br"
    done
  } > "$GIT_WT_FILE"
}
# reset per-scenario transient state (journal / logs / ledger / gh responses)
reset() { : > "$JOURNAL_FILE"; : > "$GIT_LOG"; : > "$GH_LOG"; : > "$STATE"; rm -rf "${GH_DIR:?}"/* 2>/dev/null || true; }

# ── (1) helpers defined ───────────────────────────────────────────────────────
type _reap_slug          >/dev/null 2>&1 || fail "_reap_slug not defined"
type _srs_gh_view        >/dev/null 2>&1 || fail "_srs_gh_view not defined"
type _startup_reap_sweep >/dev/null 2>&1 || fail "_startup_reap_sweep not defined"
[ -n "${STATE:-}" ]           || fail "STATE ledger var not set"
[ "$MAIN" = "$PROJECT_ROOT" ] || fail "MAIN did not resolve to PROJECT_ROOT (got $MAIN)"
ok

# ── (2) _reap_slug is the idempotent primitive ────────────────────────────────
reset
D2="$WORKTREES_DIR/prim-slug"; mkdir -p "$D2"
printf 'HERD-1\n' > "$(_slug_ref_file prim-slug)"
_reap_slug prim-slug "$D2" 7 sha7 merged
grep -q "worktree remove --force $D2" "$GIT_LOG" || fail "_reap_slug did not force-remove the worktree"
[ -f "$(_slug_ref_file prim-slug)" ] && fail "_reap_slug did not reap the tracker-ref marker"
grep -q '"event":"reap"' "$JOURNAL_FILE"        || fail "_reap_slug did not journal a reap event"
grep -q '"reason":"merged"' "$JOURNAL_FILE"     || fail "_reap_slug did not journal reason=merged"
_reap_slug prim-slug "$D2" 7 sha7 merged || fail "_reap_slug second call returned non-zero (not idempotent)"
ok

# ── (3) STRANDED, branch present: MERGED PR, headRefOid == HEAD → reaped ───────
reset
DM="$WORKTREES_DIR/merged-slug"; mkdir -p "$DM"; set_head "$DM" SHA_MERGED
printf 'HERD-91\n' > "$(_slug_ref_file merged-slug)"
gh_pr feat/merged-slug MERGED SHA_MERGED 208
write_worktrees "$DM|feat/merged-slug"
_startup_reap_sweep
[ "$(reap_events)" -ge 1 ]                          || fail "startup sweep did not reap the stranded worktree"
grep -q '"reason":"startup-sweep"' "$JOURNAL_FILE"  || fail "reap not journaled reason=startup-sweep"
grep -q '"slug":"merged-slug"'      "$JOURNAL_FILE" || fail "reap did not name the stranded slug"
grep -q '"pr":208'                  "$JOURNAL_FILE" || fail "reap did not carry the gh PR number"
grep -q "worktree remove --force $DM" "$GIT_LOG"    || fail "startup sweep did not remove the worktree"
[ -f "$(_slug_ref_file merged-slug)" ] && fail "startup sweep did not reap the tracker-ref marker"
ok

# ── (4) STRANDED, branch deleted at merge: ledger PR MERGED + matching HEAD ────
reset
DD="$WORKTREES_DIR/deleted-branch"; mkdir -p "$DD"; set_head "$DD" SHA_DEL
printf '%s %s %s\n' 1720000000 300 deleted-branch >> "$STATE"   # ledger row from do_merge (pre-crash)
# gh pr view feat/deleted-branch → nothing (branch was deleted); gh pr view 300 → MERGED + matching sha
gh_pr 300 MERGED SHA_DEL 300
write_worktrees "$DD|feat/deleted-branch"
_startup_reap_sweep
[ "$(reap_events)" -ge 1 ]                          || fail "ledger fallback did not reap the deleted-branch strand"
grep -q '"pr":300' "$JOURNAL_FILE"                  || fail "ledger-fallback reap did not carry the ledger PR number"
grep -q "worktree remove --force $DD" "$GIT_LOG"    || fail "ledger fallback did not remove the worktree"
ok

# ── (5) NORMAL startup: an OPEN-PR worktree → zero action ──────────────────────
reset
DO="$WORKTREES_DIR/open-slug"; mkdir -p "$DO"; set_head "$DO" SHA_OPEN
gh_pr feat/open-slug OPEN SHA_OPEN 209
write_worktrees "$DO|feat/open-slug"
_startup_reap_sweep
[ "$(reap_events)" -eq 0 ]           || fail "startup sweep reaped a non-stranded (OPEN) worktree"
grep -q 'startup_reap_sweep' "$JOURNAL_FILE" && fail "startup sweep journaled a summary with zero reaps"
grep -q "worktree remove" "$GIT_LOG" && fail "startup sweep removed a worktree it should have left alone"
ok

# ── (6) REUSED SLUG, no PR yet (reviewer's data-loss case): stale ledger row,
#        new HEAD ≠ old merged head → NOT reaped ────────────────────────────────
reset
DU="$WORKTREES_DIR/reused-slug"; mkdir -p "$DU"; set_head "$DU" SHA_NEW_WORK   # live builder, new commits
printf '%s %s %s\n' 1720000001 212 reused-slug >> "$STATE"     # stale row from the PRIOR merged PR
gh_pr 212 MERGED SHA_OLD_MERGED 212        # ledger PR: merged, but its head is the OLD sha
# feat/reused-slug has NO PR yet (nothing registered) → gh silent on the branch
write_worktrees "$DU|feat/reused-slug"
_startup_reap_sweep
[ "$(reap_events)" -eq 0 ]           || fail "REGRESSION: reaped a re-spawned live builder via a stale ledger row"
grep -q "worktree remove" "$GIT_LOG" && fail "REGRESSION: force-removed a live in-flight worktree (data loss)"
ok

# ── (7) REUSED BRANCH name: gh returns the OLD merged PR, head ≠ new HEAD → skip ─
reset
DB="$WORKTREES_DIR/reused-branch"; mkdir -p "$DB"; set_head "$DB" SHA_FRESH
gh_pr feat/reused-branch MERGED SHA_STALE_MERGED 220   # branch name reused; gh resolves the OLD PR
write_worktrees "$DB|feat/reused-branch"
_startup_reap_sweep
[ "$(reap_events)" -eq 0 ]           || fail "REGRESSION: MERGED-arm reaped a reused-branch live worktree"
grep -q "worktree remove" "$GIT_LOG" && fail "REGRESSION: force-removed a reused-branch live worktree"
ok

# ── (8) DIRTY worktree: MERGED + matching HEAD but uncommitted changes → skip ──
reset
DT="$WORKTREES_DIR/dirty-slug"; mkdir -p "$DT"; set_head "$DT" SHA_DIRTY; make_dirty "$DT"
gh_pr feat/dirty-slug MERGED SHA_DIRTY 230
write_worktrees "$DT|feat/dirty-slug"
_startup_reap_sweep
[ "$(reap_events)" -eq 0 ]                             || fail "startup sweep force-removed a DIRTY worktree"
grep -q "worktree remove" "$GIT_LOG"                   && fail "startup sweep force-removed a DIRTY worktree (data loss)"
grep -q '"reason":"dirty-worktree"' "$JOURNAL_FILE"    || fail "dirty skip not journaled"
ok

# ── (9) the SELF worktree is never reaped even if it looks merged ─────────────
# The SELF guard short-circuits BEFORE any HEAD/gh work, so no .fakehead is written into the real
# repo root — the gh_pr registration below is never consulted.
reset
gh_pr feat/self MERGED SHA_SELF 214
write_worktrees "$SELF_WT|feat/self"
_startup_reap_sweep
[ "$(reap_events)" -eq 0 ]           || fail "startup sweep reaped the SELF worktree"
grep -q "worktree remove" "$GIT_LOG" && fail "startup sweep removed the SELF worktree"
ok

echo "PASS: test-startup-reap-sweep.sh ($pass checks)"
