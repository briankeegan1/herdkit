#!/usr/bin/env bash
# test-startup-reap-sweep.sh — hermetic tests for the STARTUP reap-sweep (HERD-91): resume teardown
# for a worktree whose PR merged but whose reap never ran (the crash-between-merge-and-reap window,
# PR #208). Exercises agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) with gh/git/herdr stubbed on
# PATH so NO network / real worktree / real tab is ever touched.
#
#   (1) _reap_slug + _startup_reap_sweep are defined after sourcing
#   (2) _reap_slug is the idempotent primitive: removes worktree, reaps marker, journals reap, and a
#       SECOND call over the same slug is harmless
#   (3) SIM CONCURRENCY SCENARIO — a worktree whose slug the reap ledger ($STATE) already records as
#       merged (do_merge crashed AFTER the ledger write, BEFORE the reap) is reaped by the startup
#       sweep and journaled reason=startup-sweep
#   (4) NORMAL STARTUP — nothing stranded (worktree has an OPEN PR, not in the ledger) ⇒ ZERO action:
#       no reap event, worktree left intact
#   (5) FALLBACK gh check — a worktree NOT in the ledger but whose branch PR gh reports MERGED is
#       still reaped (ledger miss falls back to one gh state check)
#   (6) REUSED SLUG — a stale ledger row whose slug now names a NEW worktree with an OPEN PR is NOT
#       reaped (authoritative gh OPEN vetoes the ledger match — never reap a live builder)
#   (7) the SELF worktree is never reaped even if it somehow appears merged
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
# git: log every call; answer `worktree list --porcelain` from $GIT_WT_FILE; no-op everything else
# (worktree remove, pull, etc.). Passes `-C <dir>` through untouched.
cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_LOG"
case "$*" in
  *"worktree list"*) cat "$GIT_WT_FILE" 2>/dev/null ;;
esac
exit 0
STUB
# gh: emulate `gh pr view <branch> --json state,number -q '.state+"\t"+(.number|tostring)'`
# from $GH_PR_STATE/$GH_PR_NUMBER. Empty state ⇒ no output (deleted branch / no PR / gh down).
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${GH_PR_STATE:-}" ] && printf '%s\t%s\n' "$GH_PR_STATE" "${GH_PR_NUMBER:-0}"
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

# ── (1) helpers defined ───────────────────────────────────────────────────────
type _reap_slug          >/dev/null 2>&1 || fail "_reap_slug not defined"
type _startup_reap_sweep >/dev/null 2>&1 || fail "_startup_reap_sweep not defined"
[ -n "${STATE:-}" ]  || fail "STATE ledger var not set"
[ "$MAIN" = "$PROJECT_ROOT" ] || fail "MAIN did not resolve to PROJECT_ROOT (got $MAIN)"
ok

reap_events() { grep -c '"event":"reap"' "$JOURNAL_FILE" 2>/dev/null || true; }

# ── (2) _reap_slug is the idempotent primitive ────────────────────────────────
: > "$JOURNAL_FILE"; : > "$GIT_LOG"
D2="$WORKTREES_DIR/prim-slug"; mkdir -p "$D2"
printf 'HERD-1\n' > "$(_slug_ref_file prim-slug)"
_reap_slug prim-slug "$D2" 7 sha7 merged
grep -q "worktree remove --force $D2" "$GIT_LOG" || fail "_reap_slug did not force-remove the worktree"
[ -f "$(_slug_ref_file prim-slug)" ] && fail "_reap_slug did not reap the tracker-ref marker"
grep -q '"event":"reap"' "$JOURNAL_FILE"        || fail "_reap_slug did not journal a reap event"
grep -q '"reason":"merged"' "$JOURNAL_FILE"     || fail "_reap_slug did not journal reason=merged"
# Second call over the same (now-gone) slug must not error and must not crash the primitive.
_reap_slug prim-slug "$D2" 7 sha7 merged || fail "_reap_slug second call returned non-zero (not idempotent)"
ok

# Helper: write a porcelain worktree list ($GIT_WT_FILE) with MAIN + the given feature dirs/branches.
# Args are "dir|branch" pairs.
write_worktrees() {
  : > "$GIT_WT_FILE"
  { printf 'worktree %s\nHEAD aaaa\nbranch refs/heads/main\n\n' "$MAIN"
    local pair dir br
    for pair in "$@"; do
      dir="${pair%%|*}"; br="${pair#*|}"
      printf 'worktree %s\nHEAD bbbb\nbranch refs/heads/%s\n\n' "$dir" "$br"
    done
  } > "$GIT_WT_FILE"
}

# ── (3) SIM CONCURRENCY: ledger-recorded merge, worktree still present → reaped ─
: > "$JOURNAL_FILE"; : > "$STATE"; : > "$GIT_LOG"
DM="$WORKTREES_DIR/merged-slug"; mkdir -p "$DM"
printf 'HERD-91\n' > "$(_slug_ref_file merged-slug)"
# do_merge wrote the ledger row (ts pr slug) then CRASHED before the reap.
printf '%s %s %s\n' 1720000000 208 merged-slug >> "$STATE"
write_worktrees "$DM|feat/merged-slug"
unset GH_PR_STATE GH_PR_NUMBER   # branch deleted at merge / gh silent → ledger must answer
_startup_reap_sweep
[ "$(reap_events)" -ge 1 ]                             || fail "startup sweep did not reap the stranded worktree"
grep -q '"reason":"startup-sweep"' "$JOURNAL_FILE"     || fail "reap not journaled reason=startup-sweep"
grep -q '"slug":"merged-slug"'      "$JOURNAL_FILE"    || fail "reap did not name the stranded slug"
grep -q '"pr":208'                  "$JOURNAL_FILE"    || fail "reap did not carry the ledger PR number"
grep -q "worktree remove --force $DM" "$GIT_LOG"       || fail "startup sweep did not remove the worktree"
[ -f "$(_slug_ref_file merged-slug)" ] && fail "startup sweep did not reap the tracker-ref marker"
ok

# ── (4) NORMAL STARTUP: nothing stranded ⇒ ZERO action ────────────────────────
: > "$JOURNAL_FILE"; : > "$STATE"; : > "$GIT_LOG"
DO="$WORKTREES_DIR/open-slug"; mkdir -p "$DO"
write_worktrees "$DO|feat/open-slug"
export GH_PR_STATE="OPEN" GH_PR_NUMBER=209   # branch has an OPEN PR — not mergeable-away
_startup_reap_sweep
[ "$(reap_events)" -eq 0 ]                       || fail "startup sweep reaped a non-stranded (OPEN) worktree"
grep -q 'startup_reap_sweep' "$JOURNAL_FILE"     && fail "startup sweep journaled a summary with zero reaps"
grep -q "worktree remove" "$GIT_LOG"             && fail "startup sweep removed a worktree it should have left alone"
ok

# ── (5) FALLBACK gh check: ledger miss + gh says MERGED → reaped ──────────────
: > "$JOURNAL_FILE"; : > "$STATE"; : > "$GIT_LOG"
DF="$WORKTREES_DIR/fallback-slug"; mkdir -p "$DF"
write_worktrees "$DF|feat/fallback-slug"   # slug NOT in the (empty) ledger
export GH_PR_STATE="MERGED" GH_PR_NUMBER=210
_startup_reap_sweep
[ "$(reap_events)" -ge 1 ]                          || fail "fallback gh MERGED check did not reap the worktree"
grep -q '"reason":"startup-sweep"' "$JOURNAL_FILE"  || fail "fallback reap not journaled reason=startup-sweep"
grep -q '"pr":210' "$JOURNAL_FILE"                  || fail "fallback reap did not carry the gh PR number"
ok

# ── (6) REUSED SLUG: ledger row lingers but the branch's PR is OPEN → NOT reaped ─
# The reused-slug hazard: a prior merge freed the path + left a stale ledger row; a NEW worktree now
# occupies it with a live OPEN PR. A slug-only ledger match would false-reap the live builder — the
# authoritative gh state (OPEN) must veto the reap.
: > "$JOURNAL_FILE"; : > "$GIT_LOG"; : > "$STATE"
DR="$WORKTREES_DIR/reused-slug"; mkdir -p "$DR"
printf '%s %s %s\n' 1720000002 212 reused-slug >> "$STATE"   # stale row from the PRIOR (merged) PR
write_worktrees "$DR|feat/reused-slug"
export GH_PR_STATE="OPEN" GH_PR_NUMBER=213                    # the NEW, live PR is OPEN
_startup_reap_sweep
[ "$(reap_events)" -eq 0 ]           || fail "startup sweep reaped a reused-slug worktree with an OPEN PR"
grep -q "worktree remove" "$GIT_LOG" && fail "startup sweep removed a live (OPEN-PR) reused-slug worktree"
ok

# ── (7) the SELF worktree is never reaped even if it looks merged ─────────────
: > "$JOURNAL_FILE"; : > "$STATE"; : > "$GIT_LOG"
printf '%s %s %s\n' 1720000003 214 "$(basename "$SELF_WT")" >> "$STATE"
write_worktrees "$SELF_WT|feat/self"
unset GH_PR_STATE GH_PR_NUMBER
_startup_reap_sweep
[ "$(reap_events)" -eq 0 ]           || fail "startup sweep reaped the SELF worktree"
grep -q "worktree remove" "$GIT_LOG" && fail "startup sweep removed the SELF worktree"
ok

echo "PASS: test-startup-reap-sweep.sh ($pass checks)"
