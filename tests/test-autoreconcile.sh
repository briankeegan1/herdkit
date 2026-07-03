#!/usr/bin/env bash
# test-autoreconcile.sh — hermetic tests for the POST-MERGE backlog auto-reconcile hook in
# agent-watch.sh (option (a) of 'Auto-refix / direct hand-offs bypass backlog reconciliation').
#
#   (1) reconcile ledger helpers: reconcile_enqueued / record_reconcile (pr+sha keyed)
#   (2) reconcile_backlog enqueues EXACTLY ONE scribe reconcile request naming PR# + slug
#   (3) the enqueued text is a "Reconcile:" request and names the worktree slug
#   (4) idempotent: a SECOND call for the same merged PR (a re-run tick) does NOT re-enqueue
#   (5) a NEW commit (new sha) on the same PR is eligible for its own reconcile
#   (6) do_merge (the merge-success path) drives the hook: one merge → exactly one reconcile
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1). Stubs gh/git/herdr on PATH and redirects
# $HERE at scribe.sh (via a stub dir) so NO real scribe drainer / network is ever touched.
# Run:  bash tests/test-autoreconcile.sh
# No `set -e`: some checks assert non-zero returns explicitly.
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
# gh / git succeed silently (merge, pull, worktree remove are all no-ops here).
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
# herdr succeeds silently (teardown / agent list are no-ops here).
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ─────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# Redirect $HERE (used as "$HERE/scribe.sh") at a stub dir that LOGS every enqueue: one line per
# scribe.sh invocation, holding the full request text. reconcile_backlog + do_merge both read $HERE
# at call time, so overriding it after sourcing cleanly captures every enqueue without a real scribe.
STUBHERD="$T/herd-stub"; mkdir -p "$STUBHERD"
SCRIBE_LOG="$T/scribe-calls.log"; : > "$SCRIBE_LOG"
cat > "$STUBHERD/scribe.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$SCRIBE_LOG"
STUB
chmod +x "$STUBHERD/scribe.sh"
HERE="$STUBHERD"

scribe_calls() { [ -s "$SCRIBE_LOG" ] && grep -c . "$SCRIBE_LOG" || echo 0; }

# The ledger + hook must exist after sourcing.
type reconcile_backlog  >/dev/null 2>&1 || fail "reconcile_backlog not defined"
type reconcile_enqueued >/dev/null 2>&1 || fail "reconcile_enqueued not defined"
type record_reconcile   >/dev/null 2>&1 || fail "record_reconcile not defined"
[ -n "${RECONCILE_STATE:-}" ] || fail "RECONCILE_STATE ledger var not set"
ok

# ── (1) ledger helpers ────────────────────────────────────────────────────────
: > "$RECONCILE_STATE"
reconcile_enqueued 111 deadbeef && fail "reconcile_enqueued true on empty ledger"
record_reconcile 111 deadbeef my-slug
reconcile_enqueued 111 deadbeef   || fail "reconcile_enqueued false after record"
reconcile_enqueued 111 cafef00d   && fail "reconcile_enqueued must be sha-keyed (other sha)"
reconcile_enqueued 222 deadbeef   && fail "reconcile_enqueued must be pr-keyed (other pr)"
ok

# ── (2)+(3) reconcile_backlog enqueues exactly one, naming PR# + slug ─────────
: > "$RECONCILE_STATE"; : > "$SCRIBE_LOG"
reconcile_backlog 91 backlog-autoreconcile abc123
[ "$(scribe_calls)" -eq 1 ] || fail "expected exactly 1 scribe enqueue, got $(scribe_calls)"
grep -q '^Reconcile:'                       "$SCRIBE_LOG" || fail "enqueued text is not a 'Reconcile:' request"
grep -q 'worktree backlog-autoreconcile'    "$SCRIBE_LOG" || fail "enqueued text does not name the slug"
grep -q 'PR #91'                            "$SCRIBE_LOG" || fail "enqueued text does not name the PR number"
ok

# ── (4) idempotent: a second tick for the SAME merged PR does not re-enqueue ──
reconcile_backlog 91 backlog-autoreconcile abc123
[ "$(scribe_calls)" -eq 1 ] || fail "second call re-enqueued (got $(scribe_calls), want 1)"
ok

# ── (5) a new commit (new sha) on the same PR is eligible for its own reconcile ─
reconcile_backlog 91 backlog-autoreconcile def456
[ "$(scribe_calls)" -eq 2 ] || fail "new sha should enqueue a fresh reconcile (got $(scribe_calls), want 2)"
ok

# ── (6) do_merge (the merge-success path) fires the hook exactly once ─────────
: > "$RECONCILE_STATE"; : > "$SCRIBE_LOG"
export STATE="$T/trees/.agent-watch-merged"; : > "$STATE"
type do_merge >/dev/null 2>&1 || fail "do_merge not defined"
do_merge handoff-slug 42 "$T/trees/handoff-slug" facef00d >/dev/null 2>&1
[ "$(scribe_calls)" -eq 1 ] || fail "do_merge should enqueue exactly 1 reconcile, got $(scribe_calls)"
grep -q 'worktree handoff-slug' "$SCRIBE_LOG" || fail "do_merge enqueue does not name the slug"
grep -q 'PR #42'                "$SCRIBE_LOG" || fail "do_merge enqueue does not name the PR number"
# A second do_merge tick for the same PR+sha (idempotency ledger already recorded) must NOT re-enqueue.
do_merge handoff-slug 42 "$T/trees/handoff-slug" facef00d >/dev/null 2>&1
[ "$(scribe_calls)" -eq 1 ] || fail "a re-run do_merge tick re-enqueued (got $(scribe_calls), want 1)"
ok

echo "PASS: test-autoreconcile.sh ($pass checks)"
