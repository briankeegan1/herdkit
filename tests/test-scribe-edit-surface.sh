#!/usr/bin/env bash
# test-scribe-edit-surface.sh — HERD-514 (GH #627): delta-snapshot staging proof, in BOTH inverse
# directions in one test:
#
#   1. #627 (this fix): a pre-existing unrelated dirty/untracked file — already sitting in the working
#      tree BEFORE the request was even claimed (the incident's shape: a live OAuth token left dirty in
#      money-bets/) — is NEVER staged/committed by the scribe. _backend_snapshot_dirty (called at claim
#      time, before the scribe agent touches anything) records it; _backend_add_item then stages only
#      paths NEW or CHANGED relative to that snapshot, so the pre-existing file is skipped and the
#      existing post-commit dirty-real warn fires loudly for it (never silent).
#   2. #566 (HERD-475's regression guard — must stay true after this change): a SECOND file the request
#      itself edits (not just $BACKLOG_FILE) DOES land in the same commit, because it is NEW/CHANGED
#      relative to the snapshot.
#
# Together these prove the fix's central claim: staging is scoped to the request's OWN edit surface,
# not "everything dirty" (the #627 bug) and not "only the two hardcoded names" (the #566 bug).
#
# Run: bash tests/test-scribe-edit-surface.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$HERE/../scripts/herd/backends/file.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# The queue dir sits OUTSIDE the repo, mirroring production ($WORKTREES_DIR/backlog-queue is a sibling
# of $PROJECT_ROOT, not nested inside it — herd-config.sh: WORKTREES_DIR defaults to
# "${PROJECT_ROOT}-trees") — so the claimed-file snapshot never itself shows up as a repo-dirty path.
REPO="$T/repo"
Q="$T/queue"
mkdir -p "$REPO" "$Q"

export BACKLOG_FILE="$REPO/BACKLOG.md"
export DEFAULT_BRANCH="origin/main"
export HERD_REMOTE="origin"
export HERD_BRANCH_NAME="main"

git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t

# Seed the allowed BACKLOG_FILE and a SECOND file the request will also touch (the #566 regression
# target), then commit so both start clean.
cat > "$BACKLOG_FILE" <<'BACKLOG'
## Backlog

🔜 open-feature — a queued item
BACKLOG
mkdir -p "$REPO/docs"
printf '# bet-screen\n\noriginal\n' > "$REPO/docs/bet-screen.md"
git -C "$REPO" add "$BACKLOG_FILE" "$REPO/docs/bet-screen.md"
git -C "$REPO" commit -q -m seed

# ── #627 fixture: a PRE-EXISTING unrelated dirty/untracked file, already sitting in the tree BEFORE
# the request is claimed — the incident's own shape (a live OAuth token left in money-bets/).
mkdir -p "$REPO/money-bets"
printf 'oauth_token=live-secret-do-not-commit\n' > "$REPO/money-bets/token.bak"

mine="$Q/req-1.mine"
: > "$mine"

# ── Claim-time snapshot — exactly what scribe-step.sh's `next` calls right after the atomic claim,
# BEFORE the scribe agent applies this request's edit.
( cd "$REPO" && . "$BACKEND" && _backend_snapshot_dirty "$mine" )
[ -f "${mine}.snapshot" ] || fail "_backend_snapshot_dirty did not write a snapshot file"
pass
grep -q "money-bets/token.bak" "${mine}.snapshot" || fail "snapshot did not record the pre-existing dirty file"
pass

# ── Simulate the scribe agent's edit: append to BACKLOG_FILE AND edit the SECOND file the request
# named (docs/bet-screen.md — the #566 regression target). The pre-existing money-bets/token.bak is
# left untouched by the request.
printf '🔜 second-feature — a fresh item\n' >> "$BACKLOG_FILE"
printf 'updated by this request\n' >> "$REPO/docs/bet-screen.md"

head0="$(git -C "$REPO" rev-parse HEAD)"

# ── Run the real write op exactly as scribe-step.sh's `commit` invokes it ──────────────────────────
out="$( cd "$REPO" && . "$BACKEND"
        _BACKEND_RESULT=""
        _backend_add_item "$mine" "add second-feature + bet-screen update" 2>"$T/stderr.log"
        printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}" )"

grep -q "RESULT=DONE" <<< "$out" || fail "_backend_add_item did not report DONE ($out)"
pass

head1="$(git -C "$REPO" rev-parse HEAD)"
[ "$head1" != "$head0" ] || fail "no new commit was made"
pass

# 1. #566 regression guard: the SECOND file the request edited IS in the commit.
grep -q "updated by this request" <<< "$(git -C "$REPO" show "$head1:docs/bet-screen.md")" \
  || fail "the request's second-file edit (docs/bet-screen.md) was not committed [#566 regression]"
pass

# 2. #627 fix: the pre-existing unrelated file is NOT in the commit.
grep -q "money-bets/token.bak" <<< "$(git -C "$REPO" show "$head1" --stat --name-only)" \
  && fail "pre-existing unrelated file (money-bets/token.bak) was swept into the scribe commit [#627]"
pass

# 3. …and it is STILL sitting untracked/dirty in the working tree (skipped, not silently discarded).
grep -q '^?? money-bets/token.bak$' <<< "$(git -C "$REPO" status --porcelain -- money-bets/token.bak)" \
  || fail "pre-existing file should remain untracked (skipped), not committed or ignored away"
pass

# 4. Never-silent contract: the post-commit dirty-real warn fired LOUDLY for it on stderr.
grep -q "money-bets/token.bak" "$T/stderr.log" || fail "no loud warn for the still-dirty pre-existing file"
grep -q "WARNING" "$T/stderr.log" || fail "warn line missing its WARNING marker"
pass

# 5. The commit's file list is EXACTLY the two paths this request touched — nothing else rode along.
changed="$(git -C "$REPO" diff --name-only "$head0" "$head1" | sort)"
expected="$(printf 'BACKLOG.md\ndocs/bet-screen.md\n' | sort)"
[ "$changed" = "$expected" ] || fail "commit touched more/less than the request's own edit surface: $changed"
pass

# 6. The snapshot is consumed (removed) once _backend_add_item has read it — no leak across requests.
[ -f "${mine}.snapshot" ] && fail "snapshot file was not cleaned up after use"
pass

# ── Fallback fixture: NO snapshot at all (an older drainer, a disk hiccup) — must fall back to
# TODAY's sweep-everything-non-denied behavior, never a crash, with a loud fallback warn.
mine2="$Q/req-2.mine"
: > "$mine2"
printf 'oauth_token=another-leftover\n' > "$REPO/money-bets/other.bak"
printf '🔜 third-feature — another item\n' >> "$BACKLOG_FILE"
head1b="$(git -C "$REPO" rev-parse HEAD)"
out2="$( cd "$REPO" && . "$BACKEND"
         _BACKEND_RESULT=""
         _backend_add_item "$mine2" "add third-feature" 2>"$T/stderr2.log"
         printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}" )"
grep -q "RESULT=DONE" <<< "$out2" || fail "fallback path did not report DONE ($out2)"
pass
head2="$(git -C "$REPO" rev-parse HEAD)"
[ "$head2" != "$head1b" ] || fail "fallback path made no commit"
pass
grep -q "money-bets/other.bak" <<< "$(git -C "$REPO" show "$head2" --stat --name-only)" \
  || fail "missing-snapshot fallback should sweep the (now indistinguishable) dirty file, same as pre-HERD-514 behavior"
pass
grep -q "no edit-surface snapshot" "$T/stderr2.log" || fail "no loud fallback warn when the snapshot was missing"
pass

echo "ALL PASS ($PASS checks)"
