#!/usr/bin/env bash
# test-scribe-deny-paths.sh — HERD-381: conformance proof that the scribe/lane write surface is
# actually SCOPED AWAY from DENY_PATHS, not just that `herd config set DENY_PATHS` is refused
# (that refusal is covered separately by tests/test-cli-config.sh).
#
# THE REAL ENFORCEMENT POINT (found by grepping DENY_PATHS across scripts/herd/): DENY_PATHS carries
# NO dedicated runtime gate of its own. herd-config.sh just declares its default and comments "the
# scribe/local lane is scoped away from these"; bin/herd's `config set`/adopt paths refuse to touch
# the KEY itself (already tested). The actual scoping the comment promises is STRUCTURAL: every
# file-backend write op (scripts/herd/backends/file.sh) stages exactly `git add "$BACKLOG_FILE"` (+ its
# .archive.md companion when present) — never a wildcard `git add -A`/`git add .` — so no matter what a
# denied path holds in the working tree (untracked leftovers, or a dirty tracked file), the scribe's
# commit can never sweep it in. This test proves that invariant directly: a write targeting a path
# under DENY_PATHS is never staged/committed by the backend (refused/skipped), while a write to the
# allowed path (BACKLOG_FILE, which lives outside DENY_PATHS) proceeds and lands in the commit.
#
# A future "simplification" that swaps `git add "$BACKLOG_FILE"` for `git add -A`/`git add .` would
# silently sweep DENY_PATHS content into a committed backlog commit — this test would catch it.
#
# Run:  bash tests/test-scribe-deny-paths.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$HERE/../scripts/herd/backends/file.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# ── Fixture: DENY_PATHS set (space-separated, per templates/capabilities.tsv), BACKLOG_FILE is the
# one allowed write target and deliberately sits OUTSIDE every DENY_PATHS entry.
export DENY_PATHS="secret-dir .env"
export BACKLOG_FILE="$T/BACKLOG.md"
export DEFAULT_BRANCH="origin/main"
export HERD_REMOTE="origin"
export HERD_BRANCH_NAME="main"

git -C "$T" init -q
git -C "$T" config user.email t@t.t
git -C "$T" config user.name t

# Seed the allowed path.
cat > "$BACKLOG_FILE" <<'BACKLOG'
## Backlog

🔜 open-feature — a queued item
BACKLOG

# Seed a TRACKED file under the first DENY_PATHS entry (simulating something already in the repo
# before DENY_PATHS was set) — its later local edit must never ride along in a scribe commit either.
mkdir -p "$T/secret-dir"
printf 'token=seed\n' > "$T/secret-dir/config.secret"
git -C "$T" add "$BACKLOG_FILE" "$T/secret-dir/config.secret"
git -C "$T" commit -q -m "seed"

# Dirty the tracked denied-path file locally (unstaged) — a leftover edit that must be skipped.
printf 'token=leaked-would-be-bad\n' >> "$T/secret-dir/config.secret"

# Drop an UNTRACKED file under the second DENY_PATHS entry (".env") — a fresh secret dropped into the
# working tree that must also never be staged/committed by the scribe.
printf 'API_KEY=super-secret\n' > "$T/.env"

# Simulate the scribe agent's actual edit: append a new item to the allowed BACKLOG_FILE.
printf '🔜 second-feature — a fresh item\n' >> "$BACKLOG_FILE"

head0="$(git -C "$T" rev-parse HEAD)"

# ── Run the real write op (_backend_add_item) exactly as scribe-step.sh invokes it ─────────────────
out="$( cd "$T" && . "$BACKEND"
        _BACKEND_RESULT=""
        _backend_add_item "req-1" "add second-feature"
        printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}" )"

echo "$out" | grep -q "RESULT=DONE" || fail "_backend_add_item did not report DONE ($out)"
pass

head1="$(git -C "$T" rev-parse HEAD)"
[ "$head1" != "$head0" ] || fail "no new commit was made — allowed-path write did not proceed"
pass

# 1. The ALLOWED path proceeds: BACKLOG_FILE's new content is in the new commit.
git -C "$T" show "$head1:$(basename "$BACKLOG_FILE")" | grep -q "second-feature" \
  || fail "the allowed BACKLOG_FILE edit was not committed"
pass

# 2. A path under DENY_PATHS ("secret-dir") is REFUSED/SKIPPED: its dirty tracked edit never landed
#    in the new commit — the committed blob is byte-identical to the seeded one.
committed_secret="$(git -C "$T" show "$head1:secret-dir/config.secret" 2>/dev/null || true)"
[ "$committed_secret" = "token=seed" ] || fail "denied-path tracked file's local edit was swept into the scribe commit ($committed_secret)"
pass

# 3. The dirty edit is STILL sitting unstaged in the working tree (skipped, not silently discarded).
git -C "$T" status --porcelain -- secret-dir/config.secret | grep -q '^ M' \
  || fail "denied-path tracked file should remain locally modified but unstaged"
pass

# 4. A brand-new file under a DENY_PATHS entry (".env") is likewise never staged/committed.
git -C "$T" show "$head1" --stat --name-only | grep -q '^\.env$' \
  && fail "denied-path untracked file (.env) was committed by the scribe write"
git -C "$T" status --porcelain -- .env | grep -q '^?? \.env$' \
  || fail ".env should remain untracked (skipped), not committed or ignored away"
pass

# 5. The commit's file list is EXACTLY the allowed path — nothing from either DENY_PATHS entry rode
#    along (belt-and-suspenders on the whole diff, not just the two paths checked above).
changed="$(git -C "$T" diff --name-only "$head0" "$head1" | sort)"
[ "$changed" = "$(basename "$BACKLOG_FILE")" ] || fail "commit touched more than the allowed path: $changed"
pass

echo "ALL PASS ($PASS checks)"
