#!/usr/bin/env bash
# test-scribe-multi-file-commit.sh — hermetic proof for HERD-475 / GH #566: the file-backend scribe
# commit ('scribe-step.sh commit' → _backend_add_item in scripts/herd/backends/file.sh) must stage
# and commit EVERY file a scribe request edited, not just $BACKLOG_FILE.
#
# THE BUG (field report, money-bets, 2026-07-30, reproduced 3/3): a multi-file request — "move item
# from BACKLOG.md to GRAVEYARD.md", "add a gate to docs/bet-screen.md" — was fulfilled by the scribe
# agent editing BOTH BACKLOG.md and the second file, then calling 'scribe-step.sh commit <claimed>
# "<summary>"'. _backend_add_item staged ONLY $BACKLOG_FILE (+ its archive), so the commit landed with
# just the backlog half while the second file sat modified-and-uncommitted in the shared checkout —
# and the commit MESSAGE still named the whole request as done, misleading the post-mortem. The
# natural operator remedy for a resulting "checkout unclean" row — discard — would have silently lost
# real curated work.
#
# THE FIX: _backend_add_item now stages every path 'git status --porcelain' reports as changed
# (each added by NAME, never a repo-wide '-A'/'.'/':/' selector — scripts/herd/git-scope-lint.sh stays
# clean) before diffing/committing, and warns loudly (+ journals scribe_commit_incomplete) if the tree
# is still dirty right after the commit.
#
# Fully hermetic: a local temp git repo, no remote (DEFAULT_BRANCH points at a non-existent ref so
# the push leg is skipped), herdr stubbed. Run:  bash tests/test-scribe-multi-file-commit.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STEP="$HERE/../scripts/herd/scribe-step.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── Stub herdr on PATH so no real notification/tab is ever touched ────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── A temp git repo + a .herd/config the step script sources ──────────────────
REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
printf '# Backlog\n\n## Backlog\n' > "$REPO/BACKLOG.md"
printf '# Graveyard\n\n' > "$REPO/GRAVEYARD.md"
git -C "$REPO" add BACKLOG.md GRAVEYARD.md
git -C "$REPO" commit -q -m init
TREES="$T/trees"; Q="$TREES/backlog-queue"; mkdir -p "$Q"

CFG="$T/config"
cat > "$CFG" <<CFGEOF
HERD_VERSION=1
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="mftest"
HERD_REMOTE="origin"
HERD_BRANCH_NAME="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
CFGEOF

# step <args...> — run scribe-step.sh from inside $REPO with the temp config; capture combined
# output in $OUT and the exit code in $RC (never aborts the harness).
step() {
  set +e
  OUT="$( cd "$REPO" && HERD_CONFIG_FILE="$CFG" SCRIBE_POLL=0 bash "$STEP" "$@" 2>&1 )"
  RC=$?
  set -e
}

# ══ 1. a request that edits BACKLOG.md AND GRAVEYARD.md lands in ONE commit — both files ═════
printf -- '- moved to graveyard\n' >> "$REPO/BACKLOG.md"
printf -- '- 💀 MB-29 killed by red-team — falsified\n' >> "$REPO/GRAVEYARD.md"
printf 'move MB-29 to graveyard\n' > "$Q/100-a.req.mine"
step commit "$Q/100-a.req.mine" "MB-29 killed by red-team → GRAVEYARD"
[ "$RC" -eq 0 ] || fail "1: commit exited $RC ($OUT)"

head_files="$(git -C "$REPO" show --stat --format= HEAD)"
grep -q 'BACKLOG.md' <<< "$head_files" || fail "1: HEAD commit does not touch BACKLOG.md ($head_files)"
grep -q 'GRAVEYARD.md' <<< "$head_files" || fail "1: HEAD commit does not touch GRAVEYARD.md — the #566 bug (only BACKLOG.md staged) ($head_files)"
grep -q 'MB-29' <<< "$(git -C "$REPO" show HEAD:GRAVEYARD.md)" || fail "1: GRAVEYARD.md's edit did not land in HEAD"
[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "1: working tree not clean after commit ($(git -C "$REPO" status --porcelain))"
[ ! -f "$Q/100-a.req.mine" ] || fail "1: claimed file not cleaned up"
ok

# ══ 2. three files in one request (mirrors the field report's 3rd repro: BACKLOG + GRAVEYARD + a
#       third doctrine file) — all three land, none left behind ══════════════════════════════
printf '# Bet screen\n' > "$REPO/bet-screen.md"
git -C "$REPO" add bet-screen.md
git -C "$REPO" commit -q -m "seed bet-screen"
printf -- '- another moved item\n' >> "$REPO/BACKLOG.md"
printf -- '- 💀 MB-54 falsified vein candidate\n' >> "$REPO/GRAVEYARD.md"
printf -- '\n## §3.6 zero-cost gate\n- new screening rule\n' >> "$REPO/bet-screen.md"
printf 'add MB-54 + gate\n' > "$Q/200-b.req.mine"
step commit "$Q/200-b.req.mine" "add 4 GRAVEYARD rows for MB-54 + zero-cost gate to bet-screen.md"
[ "$RC" -eq 0 ] || fail "2: commit exited $RC ($OUT)"
head_files="$(git -C "$REPO" show --stat --format= HEAD)"
for f in BACKLOG.md GRAVEYARD.md bet-screen.md; do
  grep -q "$f" <<< "$head_files" || fail "2: HEAD commit does not touch $f ($head_files)"
done
[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "2: working tree not clean after 3-file commit"
ok

# ══ 3. a NEW (untracked) file the request created is picked up too, not just tracked edits ═══
printf -- '- another item\n' >> "$REPO/BACKLOG.md"
printf 'a brand-new doc created by this request\n' > "$REPO/NEW-DOC.md"
printf 'add a new doc\n' > "$Q/300-c.req.mine"
step commit "$Q/300-c.req.mine" "add NEW-DOC.md"
[ "$RC" -eq 0 ] || fail "3: commit exited $RC ($OUT)"
grep -q 'NEW-DOC.md' <<< "$(git -C "$REPO" show --stat --format= HEAD)" || fail "3: a newly-created untracked file was not staged/committed"
[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "3: working tree not clean after new-file commit"
ok

# ══ 4. plain single-file (BACKLOG.md only) commit still behaves exactly as before ═════════════
printf -- '- 🔜 shiny-thing — a queued item\n' >> "$REPO/BACKLOG.md"
printf 'add shiny-thing\n' > "$Q/400-d.req.mine"
step commit "$Q/400-d.req.mine" "add shiny-thing"
[ "$RC" -eq 0 ] || fail "4: commit exited $RC ($OUT)"
grep -q 'Backlog: add shiny-thing' <<< "$(git -C "$REPO" log --oneline -1)" || fail "4: commit message not as expected"
grep -q 'shiny-thing' <<< "$(git -C "$REPO" show HEAD:BACKLOG.md)" || fail "4: BACKLOG.md edit not committed"
ok

# ══ 5. git-scope-lint stays CLEAN on the fix — every stage in _backend_add_item is a NAMED add ═
if [ -f "$HERE/../scripts/herd/git-scope-lint.sh" ]; then
  # shellcheck source=/dev/null
  . "$HERE/../scripts/herd/git-scope-lint.sh"
  hits="$(herd_git_scope_check "$HERE/../scripts/herd/backends/file.sh" | grep -c 'GIT-SCOPE' || true)"
  [ "$hits" -eq 0 ] || fail "5: git-scope-lint flags scripts/herd/backends/file.sh after the fix (repo-wide staging leaked in): $hits hit(s)"
  ok
fi

echo "ALL PASS ($pass checks)"
