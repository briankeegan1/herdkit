#!/usr/bin/env bash
# test-dep-watcher.sh — hermetic test of dep-watcher.sh utility functions.
# Sources dep-watcher.sh in DEP_WATCHER_LIB=1 mode (helpers only, no polling loop)
# and exercises _dw_remove_dep, _dw_get_since, _dw_record_since, _dw_clear_since.
# Run:  bash tests/test-dep-watcher.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCHER="$HERE/../scripts/herd/dep-watcher.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$WATCHER" ] || fail "dep-watcher.sh not found at $WATCHER"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# Source helpers without entering the loop.
export DEP_WATCHER_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"   # falls back to generic defaults
export WORKTREES_DIR="$T"
export PROJECT_ROOT="$T/project"
export WORKSPACE_NAME="test-proj"
mkdir -p "$PROJECT_ROOT/.herd"
# shellcheck source=/dev/null
. "$WATCHER" || fail "sourcing dep-watcher.sh (lib mode) failed"
type _dw_remove_dep >/dev/null 2>&1 || fail "_dw_remove_dep not defined"
type _dw_get_since  >/dev/null 2>&1 || fail "_dw_get_since not defined"

# Override SINCE_FILE and DEPS_FILE to use temp dir.
SINCE_FILE="$T/.depwatcher.since"
DEPS_FILE="$T/.herd/deps"
mkdir -p "$T/.herd"

# 1. _dw_record_since stores epoch; _dw_get_since retrieves it.
_dw_record_since "provider-lib#42" "1700000000"
result="$(_dw_get_since "provider-lib#42")"
[ "$result" = "1700000000" ] || fail "_dw_get_since should return recorded epoch (got '$result')"
pass

# 2. _dw_record_since is idempotent — a second call does not overwrite the epoch.
_dw_record_since "provider-lib#42" "9999999999"
result="$(_dw_get_since "provider-lib#42")"
[ "$result" = "1700000000" ] || fail "_dw_record_since should be idempotent (got '$result', expected '1700000000')"
pass

# 3. _dw_clear_since removes the entry; _dw_get_since returns empty afterward.
_dw_clear_since "provider-lib#42"
result="$(_dw_get_since "provider-lib#42")"
[ -z "$result" ] || fail "_dw_get_since should be empty after _dw_clear_since (got '$result')"
pass

# 4. _dw_remove_dep strips the blocked-on: line and leaves other lines intact.
cat > "$DEPS_FILE" <<'DEPS'
blocked-on: provider-lib#42
blocked-on: other-repo#7
DEPS
_dw_remove_dep "provider-lib#42"
grep -q "blocked-on: other-repo#7" "$DEPS_FILE" || fail "_dw_remove_dep should preserve unrelated deps"
grep -q "blocked-on: provider-lib#42" "$DEPS_FILE" && fail "_dw_remove_dep should remove the target dep" || true
pass

# 5. _dw_remove_dep on a missing file is a no-op (no error).
rm -f "$DEPS_FILE"
_dw_remove_dep "no-such-ref#1" || fail "_dw_remove_dep with missing file should not error"
pass

echo "ALL PASS ($PASS checks)"
