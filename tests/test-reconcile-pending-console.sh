#!/usr/bin/env bash
# test-reconcile-pending-console.sh — hermetic tests for HERD-438's "reconcile pending" console
# section: build_reconcile_pending / _reconcile_pending_row in scripts/herd/agent-watch.sh.
#
# HERD-438 investigated a report that HERD-418 sat In Progress 8 days after its PR merged. The
# journal + Linear issue history showed the async reconcile actually converged correctly 4 minutes
# after merge and stayed Done for 8 days — the "still in progress" observation that triggered the
# item came from an UNRELATED, unjournaled write minutes before the coordinator looked, not from a
# missed reconcile. The scope query (every unclosed tracker item whose PR merged over an hour ago)
# found no other instance either, so no change to the reconcile mechanism itself was warranted.
# What WAS missing, and is cheap regardless of root cause: an operator-visible signal that a merged
# PR's tracker item is normally-still-converging rather than stuck, so a coordinator does not
# re-derive HERD-429/HERD-438's mistake by checking too early. This test covers that addition:
#   (1) a merged $STATE row with a ref, not yet confirmed by any evidence path, renders as "pending"
#   (2) a ref confirmed via the tracker-state-sweep ledger (TRACKER_SWEEP_LEDGER) is NOT rendered
#   (3) a ref confirmed via this seat's own fast-path `reconcile` journal event is NOT rendered
#   (4) a $STATE row with NO ref (pre-HERD-92 shape) is never rendered — nothing to confirm
#   (5) a still-unconfirmed row past _RECONCILE_PENDING_OVERDUE_SECS renders as the loud "still
#       pending" variant instead of the calm one
#   (6) an `unresolvable`-marked ledger row (4 columns) does NOT count as confirmed — HERD-411's
#       ledger shape is honored, not misread as "done"
#   (7) SCRIBE_BACKEND=file is byte-inert (no update-state op to confirm against; same carve-out
#       _tsweep_backend_supported uses) — RECONCILE_PENDING stays empty even with a stale ref
#   (8) no $STATE file at all → empty, no crash
# Fully hermetic: temp dirs only, no network, AGENT_WATCH_LIB=1, fake clock via HERD_FAKE_NOW.
# Run:  bash tests/test-reconcile-pending-console.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

MAIN="$T/main"; TREES="$T/trees"
mkdir -p "$MAIN/.herd" "$TREES"

BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

NOW=1700000000
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$TREES"
export PROJECT_ROOT="$MAIN"
export WORKSPACE_NAME="reconcile-pending-test"
export NO_COLOR=1
export HERD_FAKE_NOW="$NOW"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export SCRIBE_BACKEND="linear"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in build_reconcile_pending _reconcile_pending_row; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# ── (8) no $STATE file at all ────────────────────────────────────────────────────────────────────
rm -f "$STATE"
build_reconcile_pending
[ -z "${RECONCILE_PENDING:-}" ] || fail "(8) no \$STATE file must render nothing (got: $RECONCILE_PENDING)"
ok

# ── (1) unconfirmed ref within the normal window → calm "pending" ──────────────────────────────────
RECENT=$(( NOW - 300 ))   # 5m ago
printf '%s 601 pending-slug HERD-601\n' "$RECENT" > "$STATE"
: > "$TRACKER_SWEEP_LEDGER"
build_reconcile_pending
[ -n "${RECONCILE_PENDING:-}" ] || fail "(1) an unconfirmed recent merge must render a pending row"
printf '%s' "$RECONCILE_PENDING" | grep -q "HERD-601" || fail "(1) the row must name HERD-601"
printf '%s' "$RECONCILE_PENDING" | grep -q "pending" || fail "(1) a recent row must say 'pending'"
printf '%s' "$RECONCILE_PENDING" | grep -q "still pending" && fail "(1) a recent row must NOT say 'still pending' yet"
ok

# ── (2) confirmed via TRACKER_SWEEP_LEDGER → omitted ────────────────────────────────────────────────
printf '%s HERD-601 601\n' "$NOW" > "$TRACKER_SWEEP_LEDGER"
build_reconcile_pending
[ -z "${RECONCILE_PENDING:-}" ] \
  || fail "(2) a tracker-sweep-confirmed ref must be omitted (got: $RECONCILE_PENDING)"
ok

# ── (3) confirmed via this seat's own fast-path reconcile journal event → omitted ───────────────────
: > "$TRACKER_SWEEP_LEDGER"
: > "$JOURNAL_FILE"
RECENT2=$(( NOW - 120 ))
printf '%s 602 fastpath-slug HERD-602\n' "$RECENT2" > "$STATE"
journal_append reconcile pr 602 slug fastpath-slug sha bbb222 resolution explicit-ref
build_reconcile_pending
[ -z "${RECONCILE_PENDING:-}" ] \
  || fail "(3) a fast-path-journaled reconcile must be omitted (got: $RECONCILE_PENDING)"
ok

# ── (4) a $STATE row with no ref is never rendered ───────────────────────────────────────────────
: > "$JOURNAL_FILE"
printf '%s 603 noref-slug\n' "$RECENT2" > "$STATE"
build_reconcile_pending
[ -z "${RECONCILE_PENDING:-}" ] || fail "(4) a ref-less row must never render (got: $RECONCILE_PENDING)"
ok

# ── (5) overdue → loud "still pending" ───────────────────────────────────────────────────────────
OLD=$(( NOW - 3000 ))   # 50m ago, past _RECONCILE_PENDING_OVERDUE_SECS (40m)
printf '%s 604 overdue-slug HERD-604\n' "$OLD" > "$STATE"
: > "$TRACKER_SWEEP_LEDGER"
build_reconcile_pending
[ -n "${RECONCILE_PENDING:-}" ] || fail "(5) an overdue unconfirmed row must still render"
printf '%s' "$RECONCILE_PENDING" | grep -q "HERD-604" || fail "(5) the row must name HERD-604"
printf '%s' "$RECONCILE_PENDING" | grep -q "still pending" || fail "(5) an overdue row must say 'still pending'"
ok

# ── (6) an unresolvable-marked ledger row does NOT count as confirmed ───────────────────────────────
printf '%s 605 unresolvable-slug HERD-605\n' "$RECENT" > "$STATE"
printf '%s HERD-605 605 unresolvable\n' "$NOW" > "$TRACKER_SWEEP_LEDGER"
build_reconcile_pending
[ -n "${RECONCILE_PENDING:-}" ] || fail "(6) an unresolvable-marked ref must still render as pending"
printf '%s' "$RECONCILE_PENDING" | grep -q "HERD-605" || fail "(6) the row must name HERD-605"
ok

# ── (7) SCRIBE_BACKEND=file is byte-inert ────────────────────────────────────────────────────────
SCRIBE_BACKEND="file"
printf '%s 606 file-backend-slug HERD-606\n' "$RECENT" > "$STATE"
: > "$TRACKER_SWEEP_LEDGER"
build_reconcile_pending
[ -z "${RECONCILE_PENDING:-}" ] \
  || fail "(7) SCRIBE_BACKEND=file must render nothing (got: $RECONCILE_PENDING)"
ok
SCRIBE_BACKEND="linear"

echo "PASS: test-reconcile-pending-console.sh ($pass checks)"
