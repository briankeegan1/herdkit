#!/usr/bin/env bash
# test-cross-seat-block.sh — hermetic tests for CROSS-SEAT BLOCK PRECEDENCE (HERD-247).
#
# GROUNDING (PR #343, 2026-07-09): two seats gated the same PR concurrently. The briankeegan1 seat's
# reviewer posted a correctness BLOCK at 16:19Z; the Chase84000 seat's reviewer posted a PASS at
# 16:23Z, its watcher blessed the head sha and merged — over a standing BLOCK it could not see, because
# the review ledger is per-seat local state. One seat's failure must never be overwritten by another
# seat's success. Two deterministic guards, reading only artifacts every seat already writes (the
# herd/gates commit status + the PR's comments):
#
#   (a) SETTER GUARD, foreign failure status — a herd/gates=failure written by ANOTHER seat is KEPT:
#       our PASS posts NO success over it, and the honored event is journaled.
#   (b) SETTER + MERGE GUARD, foreign BLOCK comment on the same sha, unresolved — no blessing is
#       posted and the merge is held behind the loud 'cross-seat BLOCK · needs reconcile' row.
#   (c) RESOLUTION, human override — a sha-keyed `herd-approve.sh override` record clears the hold.
#   (d) RESOLUTION, blocking seat re-reviews — a NEWER verdict comment from the SAME seat reading PASS
#       clears the hold (a THIRD seat's PASS does not: only the blocker resolves its own block).
#   (e) SINGLE-SEAT — with no foreign comment and no foreign status the surface is byte-identical to
#       today: success is posted once, exactly as before the guard existed.
#   (f) FAIL-SOFT — an unreadable comment scan (or an unresolvable seat identity) journals
#       `cross_seat_block_scan state=degraded` and behaves as today: the blessing lands.
#   (g) SHA-KEYED — a BLOCK comment posted BEFORE the head sha landed is a verdict on the OLD commit
#       and never holds the new one (a new commit starts clean).
#
# Fully hermetic: local temp only; stubs gh (PATH). No network, no model, no real PRs.
# Run:  bash tests/test-cross-seat-block.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── gh stub ───────────────────────────────────────────────────────────────────
# Emulates the four shapes the guard + the status surface use:
#   READ  gh api repos/{owner}/{repo}/commits/<sha>/statuses  → "$GH_STATUS" ("<state> <creator>")
#   READ  gh api repos/{owner}/{repo}/commits/<sha>           → "$GH_SHA_DATE" (the commit's ISO date)
#   READ  gh pr view <pr> --json comments                     → contents of "$GH_COMMENTS_FILE"
#   WRITE gh api repos/{owner}/{repo}/statuses/<sha> -f …     → exit 0 (logged to $GH_LOG)
# GH_SHA_DATE="" / GH_COMMENTS_FILE=missing simulate an unreadable read (the degraded path).
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  [ -f "${GH_COMMENTS_FILE:-}" ] || exit 1
  cat "$GH_COMMENTS_FILE"; exit 0
fi
url=""; prev=""
for a in "$@"; do
  [ "$prev" = "api" ] && { url="$a"; break; }
  prev="$a"
done
case "$url" in
  */commits/*/statuses) printf '%s' "${GH_STATUS:-}" ;;
  */commits/*)          [ -n "${GH_SHA_DATE:-}" ] || exit 1; printf '%s' "$GH_SHA_DATE" ;;
  */statuses/*)         exit 0 ;;
  *)                    exit 0 ;;
esac
EOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export GH_LOG="$T/gh.log"; : > "$GH_LOG"
export GH_STATUS="" GH_SHA_DATE="" GH_COMMENTS_FILE=""

# ── source agent-watch.sh in lib mode ───────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"
# This seat's identity, without a `gh api user` probe (the documented test seam).
export WATCHER_OWNER="mySeat"
# Disable the per-(pr,sha) network memo: every check below must scan the CURRENT fixture, not a
# 60s-stale answer from the previous check (which reuses pr/sha numbers).
export _XSEAT_MEMO_TTL=0
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

GL="$GATE_STATUS_STATE"
JF="$JOURNAL_FILE"

# comments <<'JSON' … — write the PR-comments fixture the gh stub serves.
comments() { GH_COMMENTS_FILE="$T/comments.json"; cat > "$GH_COMMENTS_FILE"; }

# A verdict comment as GitHub actually renders it: markdown emphasis around the verdict word.
FOREIGN_BLOCK='REVIEW: **BLOCK** — rule: safety-rail bypass | why: a limit-parked resolver reads idle | location: agent-watch.sh'
FOREIGN_PASS='**Pre-merge correctness review — PASS (no blocking findings).**'
WATCHER_ROW='🐑 **herd watch** · all gates passed (healthcheck ✅ · review ✅) · awaiting approval before merge.'

reset() {
  rm -f "$GL" "$OVERRIDES" "$JF" "$T/comments.json"
  : > "$GH_LOG"
  GH_STATUS=""; GH_SHA_DATE="2026-07-09T16:00:00Z"; GH_COMMENTS_FILE=""
  DRYRUN=""
  _XSEAT_MEMO_KEY=""; _XSEAT_SEAT=""; _XSEAT_NOTED=""
  unset GATE_STATUS 2>/dev/null || true
}
blessed()    { grep -q "statuses/$1" "$GH_LOG"; }
ledger_rows() { [ -s "$GL" ] && grep -c . "$GL" || echo 0; }
journaled()  { grep -q "$1" "$JF" 2>/dev/null; }

# ── (a) foreign herd/gates=failure + our PASS → no success posted, event journaled ──────────────
# We NEVER post `failure` ourselves (it would flip CLEAN→UNSTABLE and strand the PR), so any failure
# on the sha was written by another seat and must be KEPT, not overwritten by our blessing.
reset
GH_STATUS="failure otherSeat"
comments <<'JSON'
{"comments": []}
JSON
post_gate_status 41 shaA success
blessed shaA          && fail "(a) our success overwrote a foreign herd/gates=failure"
[ "$(ledger_rows)" = "0" ] || fail "(a) a withheld blessing must not be recorded in the ledger"
journaled cross_seat_block_honored || fail "(a) no cross_seat_block_honored event journaled"
journaled otherSeat   || fail "(a) journal did not name the blocking seat"
ok

# ── (b) foreign BLOCK comment on the same sha, unresolved → standing; nothing blessed; loud row ──
reset
GH_SHA_DATE="2026-07-09T16:10:00Z"
comments <<JSON
{"comments": [
  {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z", "body": "$FOREIGN_BLOCK"},
  {"author": {"login": "mySeat"},    "createdAt": "2026-07-09T16:23:00Z", "body": "$FOREIGN_PASS"},
  {"author": {"login": "mySeat"},    "createdAt": "2026-07-09T16:24:00Z", "body": "$WATCHER_ROW"}
]}
JSON
_cross_seat_block_standing 42 shaB || fail "(b) a standing foreign BLOCK was not detected"
[ "$_XSEAT_SEAT" = "otherSeat" ]   || fail "(b) wrong blocking seat: '$_XSEAT_SEAT'"
# The MERGE GUARD's row names the conflict AND the seat to reconcile with.
row="$(NO_COLOR=1 _cross_seat_block_row "slugcell" " #42 ·" "$_XSEAT_SEAT")"
printf '%s' "$row" | grep -q 'cross-seat BLOCK · needs reconcile' || fail "(b) row wording drifted: $row"
printf '%s' "$row" | grep -q 'otherSeat'                          || fail "(b) row does not name the seat: $row"
# …and the SETTER GUARD withholds the blessing for the very same sha.
post_gate_status 42 shaB success
blessed shaB && fail "(b) a blessing was posted over a standing foreign BLOCK"
journaled cross_seat_block_honored || fail "(b) no honored event journaled"
ok

# Our OWN seat's BLOCK is not a CROSS-seat block (the local review ledger already holds it) — the guard
# must stay silent, or a solo watcher would hold every one of its own blocked PRs behind a reconcile row.
reset
GH_SHA_DATE="2026-07-09T16:10:00Z"
comments <<JSON
{"comments": [{"author": {"login": "mySeat"}, "createdAt": "2026-07-09T16:19:00Z", "body": "$FOREIGN_BLOCK"}]}
JSON
_cross_seat_block_standing 43 shaC && fail "(b) our own BLOCK must not read as a cross-seat block"
ok

# ── (c) RESOLUTION: a sha-keyed human override clears the hold → proceeds ───────────────────────
reset
GH_SHA_DATE="2026-07-09T16:10:00Z"
comments <<JSON
{"comments": [{"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z", "body": "$FOREIGN_BLOCK"}]}
JSON
printf '%s override 44 shaD\n' "$(date +%s)" >> "$OVERRIDES"
_cross_seat_block_standing 44 shaD && fail "(c) a sha-keyed override must clear the standing block"
post_gate_status 44 shaD success
blessed shaD || fail "(c) an overridden sha must still be blessed"
[ "$(ledger_rows)" = "1" ] || fail "(c) the blessing was not recorded"
# The override is keyed to the SHA: a new commit does not inherit it.
_cross_seat_block_standing 44 shaOther || fail "(c) the override must not carry to another sha"
ok

# ── (d) RESOLUTION: the BLOCKING seat posts a later PASS for the same sha → proceeds ────────────
reset
GH_SHA_DATE="2026-07-09T16:10:00Z"
comments <<JSON
{"comments": [
  {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z", "body": "$FOREIGN_BLOCK"},
  {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:40:00Z", "body": "$FOREIGN_PASS"}
]}
JSON
_cross_seat_block_standing 45 shaE && fail "(d) the blocking seat's later PASS must resolve its BLOCK"
post_gate_status 45 shaE success
blessed shaE || fail "(d) a resolved sha must be blessed"
ok

# A DIFFERENT seat's PASS is NOT a resolution — that is exactly the #343 bug. Only the blocker resolves.
reset
GH_SHA_DATE="2026-07-09T16:10:00Z"
comments <<JSON
{"comments": [
  {"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z", "body": "$FOREIGN_BLOCK"},
  {"author": {"login": "thirdSeat"}, "createdAt": "2026-07-09T16:40:00Z", "body": "$FOREIGN_PASS"}
]}
JSON
_cross_seat_block_standing 46 shaF || fail "(d) a THIRD seat's PASS must not resolve another seat's BLOCK"
[ "$_XSEAT_SEAT" = "otherSeat" ]   || fail "(d) wrong blocking seat: '$_XSEAT_SEAT'"
ok

# ── (e) SINGLE-SEAT: no foreign status, no foreign verdict → byte-identical to today ────────────
reset
GH_SHA_DATE="2026-07-09T16:10:00Z"
comments <<JSON
{"comments": [
  {"author": {"login": "mySeat"}, "createdAt": "2026-07-09T16:19:00Z", "body": "$FOREIGN_PASS"},
  {"author": {"login": "mySeat"}, "createdAt": "2026-07-09T16:20:00Z", "body": "$WATCHER_ROW"}
]}
JSON
post_gate_status 47 shaG success
blessed shaG                            || fail "(e) single-seat: the blessing must still be posted"
grep -q "state=success" "$GH_LOG"       || fail "(e) single-seat: state=success not in POST"
grep -q "context=herd/gates" "$GH_LOG"  || fail "(e) single-seat: context=herd/gates not in POST"
[ "$(ledger_rows)" = "1" ]              || fail "(e) single-seat: expected exactly 1 ledger row"
journaled cross_seat_block_honored && fail "(e) single-seat: an honored event leaked"
journaled cross_seat_block_scan    && fail "(e) single-seat: a degraded event leaked"
# The bot's own '🐑 herd watch · all gates passed' row is prose, not a verdict — it must never be
# mistaken for a PASS/BLOCK comment (it is authored by whichever seat runs the watcher).
ok

# ── (f) FAIL-SOFT: an unreadable scan journals `degraded` and behaves exactly as today ──────────
reset
GH_SHA_DATE=""                     # commit read fails → the sha's landing time is unknown
comments <<'JSON'
{"comments": []}
JSON
post_gate_status 48 shaH success
blessed shaH || fail "(f) a degraded scan must not withhold the blessing (fail-soft)"
journaled '"state":"degraded"' || journaled degraded || fail "(f) no degraded event journaled"
ok
# An unresolvable seat identity is equally degraded — never a hold on our own comments.
reset
_WATCHER_OWNER_RESOLVED=""; _WATCHER_OWNER_CACHE=""
WATCHER_OWNER="" WATCHER_VIEW_AUTHOR="" GH_SHA_DATE="2026-07-09T16:10:00Z"
comments <<JSON
{"comments": [{"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z", "body": "$FOREIGN_BLOCK"}]}
JSON
_cross_seat_block_standing 49 shaI && fail "(f) an unresolvable seat identity must not hold (fail-soft)"
journaled degraded || fail "(f) unresolvable identity did not journal degraded"
# restore the seam for the remaining checks
_WATCHER_OWNER_RESOLVED=""; _WATCHER_OWNER_CACHE=""; WATCHER_OWNER="mySeat"
ok

# ── (g) SHA-KEYED: a BLOCK on the PREVIOUS commit never holds the new one ───────────────────────
# GitHub comments carry no sha, so a verdict is keyed to a sha by "posted at or after that commit
# landed". A builder that pushes a fix creates a new sha whose landing time is AFTER the old BLOCK.
reset
GH_SHA_DATE="2026-07-09T17:00:00Z"
comments <<JSON
{"comments": [{"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z", "body": "$FOREIGN_BLOCK"}]}
JSON
_cross_seat_block_standing 50 shaJ && fail "(g) a BLOCK predating the head sha must not hold it"
post_gate_status 50 shaJ success
blessed shaJ || fail "(g) the new sha must be blessed"
ok

# ── inert levers: GATE_STATUS=off and --dry-run never reach the guard (no network, no journal) ──
reset
GH_SHA_DATE="2026-07-09T16:10:00Z"
comments <<JSON
{"comments": [{"author": {"login": "otherSeat"}, "createdAt": "2026-07-09T16:19:00Z", "body": "$FOREIGN_BLOCK"}]}
JSON
: > "$GH_LOG"
GATE_STATUS=off post_gate_status 51 shaK success
[ -s "$GH_LOG" ] && fail "(inert) GATE_STATUS=off must not read the shared artifacts"
DRYRUN=1 post_gate_status 51 shaK success
[ -s "$GH_LOG" ] && fail "(inert) --dry-run must not read the shared artifacts"
[ "$(ledger_rows)" = "0" ] || fail "(inert) off/dry-run wrote the ledger"
ok

echo "PASS test-cross-seat-block.sh ($pass checks)"
