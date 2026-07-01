#!/usr/bin/env bash
# test-merge-policy.sh — hermetic tests for MERGE_POLICY / MERGE_METHOD / approval gate.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1) with stubbed gh/git/herdr binaries
# to test:
#   • _effective_merge_policy: MERGE_POLICY key, back-compat with WATCHER_AUTOMERGE, precedence
#   • _merge_method_flag: merge | squash | rebase, default
#   • approval helpers: approval_awaiting_noted, approval_is_approved, observe_noted
# Run:  bash tests/test-merge-policy.sh
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

# Stub binaries on PATH — no network, no filesystem side-effects beyond $T.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" << 'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr merge")  printf 'merge %s\n' "$3" >> "${GH_MERGE_LOG:?GH_MERGE_LOG unset}"; exit 0 ;;
  "pr comment") exit 0 ;;
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
export HERD_CONFIG_FILE="$T/no-such-config"
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
# $APPROVALS and $REVIEW_STATE are now set from the sourced file.

# ── _effective_merge_policy ──────────────────────────────────────────────────

type _effective_merge_policy >/dev/null 2>&1 || fail "_effective_merge_policy not defined"

[ "$(MERGE_POLICY=auto    _effective_merge_policy)" = "auto"    ] || fail "MERGE_POLICY=auto → auto"
ok
[ "$(MERGE_POLICY=approve _effective_merge_policy)" = "approve" ] || fail "MERGE_POLICY=approve → approve"
ok
[ "$(MERGE_POLICY=observe _effective_merge_policy)" = "observe" ] || fail "MERGE_POLICY=observe → observe"
ok

# Back-compat: no MERGE_POLICY set, WATCHER_AUTOMERGE drives resolution.
[ "$(MERGE_POLICY='' WATCHER_AUTOMERGE=true  _effective_merge_policy)" = "auto"    ] || fail "WATCHER_AUTOMERGE=true  → auto"
ok
[ "$(MERGE_POLICY='' WATCHER_AUTOMERGE=false _effective_merge_policy)" = "approve" ] || fail "WATCHER_AUTOMERGE=false → approve"
ok
[ "$(MERGE_POLICY='' WATCHER_AUTOMERGE=no    _effective_merge_policy)" = "approve" ] || fail "WATCHER_AUTOMERGE=no    → approve"
ok
[ "$(MERGE_POLICY='' WATCHER_AUTOMERGE=off   _effective_merge_policy)" = "approve" ] || fail "WATCHER_AUTOMERGE=off   → approve"
ok
[ "$(MERGE_POLICY='' WATCHER_AUTOMERGE=0     _effective_merge_policy)" = "approve" ] || fail "WATCHER_AUTOMERGE=0     → approve"
ok

# MERGE_POLICY always wins over WATCHER_AUTOMERGE.
[ "$(MERGE_POLICY=auto WATCHER_AUTOMERGE=false _effective_merge_policy)" = "auto"    ] || fail "MERGE_POLICY overrides WATCHER_AUTOMERGE (auto wins)"
ok
[ "$(MERGE_POLICY=observe WATCHER_AUTOMERGE=true _effective_merge_policy)" = "observe" ] || fail "MERGE_POLICY overrides WATCHER_AUTOMERGE (observe wins)"
ok

# ── _merge_method_flag ───────────────────────────────────────────────────────

type _merge_method_flag >/dev/null 2>&1 || fail "_merge_method_flag not defined"

[ "$(MERGE_METHOD=merge  _merge_method_flag)" = "--merge"  ] || fail "merge  → --merge"
ok
[ "$(MERGE_METHOD=squash _merge_method_flag)" = "--squash" ] || fail "squash → --squash"
ok
[ "$(MERGE_METHOD=rebase _merge_method_flag)" = "--rebase" ] || fail "rebase → --rebase"
ok
[ "$(MERGE_METHOD=''     _merge_method_flag)" = "--merge"  ] || fail "empty  → --merge (default)"
ok
# Unknown value falls through to default.
[ "$(MERGE_METHOD=weird  _merge_method_flag)" = "--merge"  ] || fail "unknown → --merge (default)"
ok

# ── Approval helpers ─────────────────────────────────────────────────────────

type approval_is_approved    >/dev/null 2>&1 || fail "approval_is_approved not defined"
type approval_awaiting_noted >/dev/null 2>&1 || fail "approval_awaiting_noted not defined"
type record_approval_awaiting >/dev/null 2>&1 || fail "record_approval_awaiting not defined"
type observe_noted           >/dev/null 2>&1 || fail "observe_noted not defined"
type record_observe_noted    >/dev/null 2>&1 || fail "record_observe_noted not defined"

# Empty / absent ledger → nothing is noted or approved.
rm -f "$APPROVALS"
! approval_is_approved    "1" "aaa" || fail "is_approved: empty ledger should return false"
ok
! approval_awaiting_noted "1" "aaa" || fail "awaiting_noted: empty ledger should return false"
ok
! observe_noted           "1" "aaa" || fail "observe_noted: empty ledger should return false"
ok

# After an 'awaiting' record: noted but not approved.
printf '1000 awaiting 1 aaa\n' > "$APPROVALS"
  approval_awaiting_noted "1" "aaa" || fail "awaiting record should be detected"
ok
! approval_is_approved    "1" "aaa" || fail "awaiting ≠ approved"
ok
! observe_noted           "1" "aaa" || fail "awaiting record is not an observed record"
ok

# After an 'approved' record: approved; wrong sha / wrong PR are not approved.
printf '1001 approved 1 aaa\n' >> "$APPROVALS"
  approval_is_approved "1" "aaa"    || fail "approved record should be detected"
ok
! approval_is_approved "1" "bbb"    || fail "wrong sha should not match approved"
ok
! approval_is_approved "2" "aaa"    || fail "wrong PR should not match approved"
ok

# An 'observed' record is visible only to observe_noted.
printf '1002 observed 2 bbb\n' >> "$APPROVALS"
  observe_noted "2" "bbb"           || fail "observed record should be detected"
ok
! observe_noted "2" "aaa"           || fail "observed: wrong sha should not match"
ok
! observe_noted "1" "bbb"           || fail "observed: wrong PR should not match"
ok
! approval_is_approved    "2" "bbb" || fail "observed record should not satisfy is_approved"
ok
! approval_awaiting_noted "2" "bbb" || fail "observed record should not satisfy awaiting_noted"
ok

# record_approval_awaiting and record_observe_noted write to $APPROVALS.
rm -f "$APPROVALS"
record_approval_awaiting "5" "sha5"
  approval_awaiting_noted "5" "sha5" || fail "record_approval_awaiting did not write correctly"
ok
! approval_is_approved    "5" "sha5" || fail "awaiting record written by record_approval_awaiting should not satisfy is_approved"
ok

record_observe_noted "6" "sha6"
  observe_noted "6" "sha6"           || fail "record_observe_noted did not write correctly"
ok

echo "ALL PASS ($pass checks)"
