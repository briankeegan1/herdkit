#!/usr/bin/env bash
# test-tracker-heals-ack.sh — HERD-613 LEG 3: `herd tracker-heals [list|ack <n|all>]` — the
# herd-notes-style operator clear path for the "tracker healed" console section.
#
# Before this command, a LOUD row (a `failed`/`escalated` tracker-heal — console-section.sh never ages
# one out on its own) had exactly ONE way off the console: a fresh `healed` row for the SAME ref
# superseding it. A ref that can never resolve (a shape-invalid `Refs:` value — HERD-613 LEG 2) can
# never produce that `healed` row, so pre-LEG-3 an operator had no clear path at all short of hand-
# editing the ledger file.
#
# Asserts:
#   (1) `herd tracker-heals` lists the rows currently on the console, newest first, numbered — the
#       SAME visibility rule (herd_console_visible_lines_tracker) the watcher itself renders through.
#   (2) `herd tracker-heals ack <n>` records the exact ledger line in the ack sidecar and the row
#       leaves the console immediately; the ledger (history) is untouched.
#   (3) `herd tracker-heals ack all` clears every visible row in one call.
#   (4) a bad index / unknown subcommand are hard usage errors.
#   (5) an empty console says so and exits 0.
# Fully hermetic: temp dirs only, no network, no live watcher loop, fake clock.
# Run:  bash tests/test-tracker-heals-ack.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD_BIN="$REPO/bin/herd"
WATCH="$REPO/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$HERD_BIN" ] || fail "bin/herd not found"
[ -f "$WATCH" ]    || fail "agent-watch.sh not found"

MAIN="$T/main"; TREES="$T/trees"
mkdir -p "$MAIN/.herd" "$TREES/.herd"
cat > "$MAIN/.herd/config" <<EOF
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH=main
EOF

BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

NOW=1700000000
LEDGER="$TREES/.agent-watch-tracker-heals"
ACK="$TREES/.agent-watch-tracker-heals-acked"

cat > "$LEDGER" <<EOF
$((NOW - 60)) escalated HERD-999 727 unknown
$NOW escalated some-garbage-ref.sh 800 unknown
EOF

run_herd() { HERD_CONFIG_FILE="$MAIN/.herd/config" HERD_FAKE_NOW="$NOW" HERMETIC_TEST=1 NO_COLOR=1 \
  bash "$HERD_BIN" "$@" 2>&1; }

# ── (1) list ─────────────────────────────────────────────────────────────────────────────────────
out="$(cd "$MAIN" && run_herd tracker-heals)" || fail "herd tracker-heals failed: $out"
grep -q "some-garbage-ref.sh" <<< "$out" || fail "(1) the newest row should list (got: $out)"
grep -q "HERD-999" <<< "$out" || fail "(1) the older row should also list (got: $out)"
ok

# ── (2) ack #1 (newest = some-garbage-ref.sh) ───────────────────────────────────────────────────────
out="$(cd "$MAIN" && run_herd tracker-heals ack 1)" || fail "(2) ack 1 failed: $out"
grep -qi "acked" <<< "$out" || fail "(2) ack should confirm (got: $out)"
grep -q "some-garbage-ref.sh" "$ACK" || fail "(2) ack 1 should record the newest ledger line"
grep -q "HERD-999" "$ACK" && fail "(2) ack 1 must not ack the other row"
ok
out="$(cd "$MAIN" && run_herd tracker-heals)" || fail "herd tracker-heals failed after ack: $out"
grep -q "some-garbage-ref.sh" <<< "$out" && fail "(2) acked row must leave the console listing"
grep -q "HERD-999" <<< "$out" || fail "(2) unacked row must stay listed"
ok
grep -q "some-garbage-ref.sh" "$LEDGER" || fail "(2) ack must never rewrite the ledger (history preserved)"
ok

# ── (4) bad index / unknown subcommand are hard usage errors ────────────────────────────────────────
if (cd "$MAIN" && run_herd tracker-heals ack 99 >/dev/null 2>&1); then fail "(4) ack of a nonexistent index should fail"; fi
ok
if (cd "$MAIN" && run_herd tracker-heals bogus >/dev/null 2>&1); then fail "(4) unknown subcommand should fail"; fi
ok

# ── (3) ack all clears everything still visible ─────────────────────────────────────────────────────
out="$(cd "$MAIN" && run_herd tracker-heals ack all)" || fail "(3) ack all failed: $out"
out="$(cd "$MAIN" && run_herd tracker-heals)" || fail "herd tracker-heals failed after ack all: $out"
grep -qi "no tracker-heal rows" <<< "$out" || fail "(3) ack all should clear the whole section (got: $out)"
ok

# ── (5) an empty console says so and exits 0 ─────────────────────────────────────────────────────────
rc=0; out="$(cd "$MAIN" && run_herd tracker-heals)" || rc=$?
[ "$rc" -eq 0 ] || fail "(5) an empty console should exit 0 (rc=$rc): $out"
ok

# ── watcher-side render agrees: the acked-away row never renders in build_tracker_drift either ──────
cat > "$LEDGER" <<EOF
$NOW escalated fresh-garbage.sh 801 unknown
EOF
: > "$ACK"
(cd "$MAIN" && run_herd tracker-heals ack all >/dev/null) || fail "watcher-agreement setup: ack all failed"
export AGENT_WATCH_LIB=1 NO_COLOR=1
export HERD_CONFIG_FILE="$MAIN/.herd/config" WORKTREES_DIR="$TREES" PROJECT_ROOT="$MAIN"
export WORKSPACE_NAME="heals-ack-test" HERD_FAKE_NOW="$NOW"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
build_tracker_drift
[ -z "${TRACKER_DRIFT:-}" ] || fail "the watcher's own console render still shows the acked row: $TRACKER_DRIFT"
ok

echo "ALL PASS ($pass checks)"
