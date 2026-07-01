#!/usr/bin/env bash
# test-backend-file.sh — hermetic test of the file backend's _backend_item_state op.
# The existing ops (add/mark/list) are covered by integration with the scribe; this test
# focuses on the new 4th op which can be exercised without a git repo.
# Run:  bash tests/test-backend-file.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$HERE/../scripts/herd/backends/file.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

export BACKLOG_FILE="$T/BACKLOG.md"
export DEFAULT_BRANCH="origin/main"
export HERD_REMOTE="origin"
export HERD_BRANCH_NAME="main"

run_state() {
  ( . "$BACKEND"
    ITEM_STATE=""
    _backend_item_state "$1"
    printf 'ITEM_STATE=%s\n' "${ITEM_STATE:-}" )
}

# Write a fake BACKLOG.md with items in each emoji state.
cat > "$BACKLOG_FILE" <<'BACKLOG'
## Backlog

🔜 open-feature — a queued item
🚧 wip-feature — an in-progress item
✅ done-feature — a shipped item
BACKLOG

# 1. Slug matching a 🔜 line → open.
out="$(run_state "repo#open-feature")"
echo "$out" | grep -q "ITEM_STATE=open" || fail "🔜 item should return open ($out)"
pass

# 2. Slug matching a 🚧 line → in-progress.
out="$(run_state "repo#wip-feature")"
echo "$out" | grep -q "ITEM_STATE=in-progress" || fail "🚧 item should return in-progress ($out)"
pass

# 3. Slug matching a ✅ line → closed.
out="$(run_state "repo#done-feature")"
echo "$out" | grep -q "ITEM_STATE=closed" || fail "✅ item should return closed ($out)"
pass

# 4. Unknown slug (not in file) → open (safe default).
out="$(run_state "repo#no-such-item")"
echo "$out" | grep -q "ITEM_STATE=open" || fail "missing slug should default to open ($out)"
pass

# 5. Ref without link prefix (bare slug) is also handled.
out="$(run_state "done-feature")"
echo "$out" | grep -q "ITEM_STATE=closed" || fail "bare slug without # prefix should still match ($out)"
pass

echo "ALL PASS ($PASS checks)"
