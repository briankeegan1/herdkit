#!/usr/bin/env bash
# test-backend-changelog.sh — hermetic test of the changelog work-tracker backend's 3-op contract
# against a TEMP git repo. No remote (push is skipped when there's nothing ahead of origin), no
# network. Run:  bash tests/test-backend-changelog.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$HERE/../scripts/herd/backends/changelog.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }

git -C "$T" init -q
git -C "$T" config user.email t@t.t; git -C "$T" config user.name t

# The backend expects these in scope (normally from herd-config.sh). DEFAULT_BRANCH points at a
# ref that does not exist, so `git rev-list origin/main..HEAD` yields nothing and push is skipped.
export BACKLOG_FILE="CHANGELOG.md"
export DEFAULT_BRANCH="origin/main"
export HERD_REMOTE="origin"
export HERD_BRANCH_NAME="main"

run() {
  ( cd "$T" && . "$BACKEND"
    _BACKEND_RESULT=""
    "$@"
    printf 'RESULT=%s\n' "${_BACKEND_RESULT:-}" )
}

# 1. add-item appends under [Unreleased] and commits.
out="$(run _backend_add_item REQ1 "first tracked thing")"
echo "$out" | grep -q "RESULT=DONE" || fail "add_item did not report DONE ($out)"
[ -f "$T/CHANGELOG.md" ] || fail "CHANGELOG.md not created"
grep -q "## \[Unreleased\]" "$T/CHANGELOG.md" || fail "no [Unreleased] heading"
grep -q -- "- first tracked thing" "$T/CHANGELOG.md" || fail "item not appended"
( cd "$T" && git log --oneline | grep -q "Changelog: first tracked thing" ) || fail "no changelog commit"

# 2. a second item lands too, directly under the heading (newest first).
run _backend_add_item REQ2 "second tracked thing" >/dev/null
grep -q -- "- second tracked thing" "$T/CHANGELOG.md" || fail "second item not appended"

# 3. list_open prints both unreleased bullets; mark_shipped is a no-op (no error, no change).
open="$( cd "$T" && . "$BACKEND" && _backend_list_open )"
echo "$open" | grep -q "first tracked thing"  || fail "list_open missing first item ($open)"
echo "$open" | grep -q "second tracked thing" || fail "list_open missing second item"
before="$(cat "$T/CHANGELOG.md")"
( cd "$T" && . "$BACKEND" && _backend_mark_shipped some-slug http://pr ) || fail "mark_shipped errored"
[ "$before" = "$(cat "$T/CHANGELOG.md")" ] || fail "mark_shipped mutated the changelog (should be no-op)"

echo "ALL PASS"
