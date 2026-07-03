#!/usr/bin/env bash
# test-watcher-views.sh — hermetic tests for the configurable watcher views (lenses + filters).
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) with a stubbed gh binary and a canned
# `gh pr list` JSON fixture (fed on stdin), then exercises the pure selection helpers:
#   • _watcher_view_active / _watcher_view_fields — default requests the UNCHANGED base fields
#   • _watcher_view_filter — lens (all|mine|deps|review-queue) + author/assignee/label/status filters
# Asserts the critical backward-compat contract (default lens = today's all-PRs behavior, unchanged),
# the `mine` and `review-queue` lenses, filter composition, and the unknown-lens → all + loud warning.
# Run:  bash tests/test-watcher-views.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# Stub binaries on PATH — no network. gh is only reached if a `mine` lens has to resolve the user;
# here every `mine` test supplies WATCHER_VIEW_AUTHOR, so gh must NOT be consulted for identity.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" << 'STUB'
#!/usr/bin/env bash
# If anything asks gh for the login, hand back a sentinel so a leak is visible in assertions.
case "$*" in
  "api user -q .login") printf 'sentinel-gh-user\n'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"
for cmd in git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"   # falls back to generic defaults
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

type _watcher_view_filter >/dev/null 2>&1 || fail "_watcher_view_filter not defined"
type _watcher_view_active >/dev/null 2>&1 || fail "_watcher_view_active not defined"
type _watcher_view_fields >/dev/null 2>&1 || fail "_watcher_view_fields not defined"

# Canned `gh pr list --json ...` output: three open PRs across two authors, mixed review/gate state.
FIXTURE='[
 {"number":1,"title":"a","headRefName":"f1","headRefOid":"s1","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","author":{"login":"alice"},"assignees":[{"login":"bob"}],"labels":[{"name":"dependencies"}],"reviewDecision":"REVIEW_REQUIRED"},
 {"number":2,"title":"b","headRefName":"f2","headRefOid":"s2","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","author":{"login":"bob"},"assignees":[],"labels":[{"name":"bug"}],"reviewDecision":"APPROVED"},
 {"number":3,"title":"c","headRefName":"f3","headRefOid":"s3","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","author":{"login":"alice"},"assignees":[{"login":"carol"}],"labels":[],"reviewDecision":"REVIEW_REQUIRED"}
]'

# Extract the selected PR numbers (comma-joined, input order) from a filter's JSON output.
nums() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(",".join(str(p["number"]) for p in d))'; }

# Clear every view key so each case starts from a pristine (default) config.
clear_view() { unset WATCHER_VIEW WATCHER_VIEW_AUTHOR WATCHER_VIEW_ASSIGNEE WATCHER_VIEW_LABEL WATCHER_VIEW_STATUS WATCHER_VIEW_DEPS_LABEL; }

# ── 1. Default (unset) = today's exact behavior: view inactive, base fields, every PR passes ──────
clear_view
_watcher_view_active && fail "unset WATCHER_VIEW must be INACTIVE (default path)"
ok
[ "$(_watcher_view_fields)" = "number,title,headRefName,headRefOid,mergeable,mergeStateStatus" ] \
  || fail "default fields must be the UNCHANGED base set (got: $(_watcher_view_fields))"
ok
got="$(printf '%s' "$FIXTURE" | _watcher_view_filter | nums)"
[ "$got" = "1,2,3" ] || fail "default must pass ALL PRs through unchanged (got: $got)"
ok
# Explicit all lens behaves identically to unset.
WATCHER_VIEW=all _watcher_view_active && fail "lens=all with no filters must be INACTIVE"
ok
got="$(WATCHER_VIEW=all; printf '%s' "$FIXTURE" | _watcher_view_filter | nums)"
[ "$got" = "1,2,3" ] || fail "lens=all must pass all PRs (got: $got)"
ok

# ── 2. Default passthrough is BYTE-IDENTICAL to the input (no reserialization surprises) ──────────
clear_view
[ "$(printf '%s' "$FIXTURE" | _watcher_view_filter)" = "$FIXTURE" ] \
  || fail "inactive view must be a byte-identical passthrough"
ok

# ── 3. `mine` lens → only the configured author's PRs; activates extended fields ──────────────────
clear_view
export WATCHER_VIEW=mine WATCHER_VIEW_AUTHOR=alice
_watcher_view_active || fail "lens=mine must be ACTIVE"
ok
case "$(_watcher_view_fields)" in *,author,assignees,labels,reviewDecision) : ;; *) fail "active view must request extended fields (got: $(_watcher_view_fields))" ;; esac
ok
got="$(printf '%s' "$FIXTURE" | _watcher_view_filter | nums)"
[ "$got" = "1,3" ] || fail "mine (alice) must select alice's PRs 1,3 (got: $got)"
ok
# gh identity must NOT be consulted when the author is configured.
[ "$(printf '%s' "$FIXTURE" | _watcher_view_filter | grep -c sentinel-gh-user)" = "0" ] \
  || fail "mine with WATCHER_VIEW_AUTHOR set must not fall back to gh user"
ok
clear_view

# ── 4. `review-queue` lens → only PRs awaiting review (reviewDecision == REVIEW_REQUIRED) ─────────
clear_view
export WATCHER_VIEW=review-queue
got="$(printf '%s' "$FIXTURE" | _watcher_view_filter | nums)"
[ "$got" = "1,3" ] || fail "review-queue must select REVIEW_REQUIRED PRs 1,3 (got: $got)"
ok
clear_view

# ── 5. `deps` lens → only PRs carrying the deps label (default: dependencies) ─────────────────────
clear_view
export WATCHER_VIEW=deps
got="$(printf '%s' "$FIXTURE" | _watcher_view_filter | nums)"
[ "$got" = "1" ] || fail "deps must select the dependency-labelled PR 1 (got: $got)"
ok
# Overridable deps label.
export WATCHER_VIEW_DEPS_LABEL=bug
got="$(printf '%s' "$FIXTURE" | _watcher_view_filter | nums)"
[ "$got" = "2" ] || fail "deps with WATCHER_VIEW_DEPS_LABEL=bug must select PR 2 (got: $got)"
ok
clear_view

# ── 6. Standalone filters compose over the default all lens (AND semantics) ───────────────────────
clear_view
got="$(WATCHER_VIEW_LABEL=bug; printf '%s' "$FIXTURE" | _watcher_view_filter | nums)"
[ "$got" = "2" ] || fail "label filter bug → PR 2 (got: $got)"
ok
got="$(WATCHER_VIEW_STATUS=CLEAN; printf '%s' "$FIXTURE" | _watcher_view_filter | nums)"
[ "$got" = "1" ] || fail "status filter CLEAN → PR 1 (got: $got)"
ok
got="$(WATCHER_VIEW_ASSIGNEE=carol; printf '%s' "$FIXTURE" | _watcher_view_filter | nums)"
[ "$got" = "3" ] || fail "assignee filter carol → PR 3 (got: $got)"
ok
# Lens + filter AND: mine (alice) ∩ status DIRTY → only PR 3.
got="$(WATCHER_VIEW=mine; WATCHER_VIEW_AUTHOR=alice; WATCHER_VIEW_STATUS=DIRTY; printf '%s' "$FIXTURE" | _watcher_view_filter | nums)"
[ "$got" = "3" ] || fail "mine(alice) ∩ status=DIRTY → PR 3 (got: $got)"
ok
clear_view

# ── 7. Unknown lens → falls back to `all` (every PR shown) + a LOUD warning to stderr ─────────────
clear_view
export WATCHER_VIEW=bogus
err="$(printf '%s' "$FIXTURE" | _watcher_view_filter 2>"$T/warn.err" | nums)"
[ "$err" = "1,2,3" ] || fail "unknown lens must fall back to all PRs 1,2,3 (got: $err)"
ok
grep -qi "unknown lens" "$T/warn.err" || fail "unknown lens must emit a loud warning to stderr"
grep -q "bogus" "$T/warn.err" || fail "warning must name the offending lens value"
ok
clear_view

# ── 8. Malformed / empty input degrades to an empty list, never crashes the tick ─────────────────
clear_view
export WATCHER_VIEW=mine WATCHER_VIEW_AUTHOR=alice
[ "$(printf 'not json' | _watcher_view_filter)" = "[]" ] || fail "malformed input must degrade to []"
ok
[ "$(printf '[]' | _watcher_view_filter | nums)" = "" ] || fail "empty list must stay empty"
ok
clear_view

echo "ALL PASS ($pass checks)"
