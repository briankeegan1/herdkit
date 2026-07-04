#!/usr/bin/env bash
# test-dead-builder.sh — hermetic test for the watcher's DEAD-builder detection: a spawned builder
# whose agent has VANISHED from `herdr agent list` while its worktree still exists and it opened NO
# PR (REAL INCIDENT 2026-07-03: a spawned builder died silently and nothing surfaced it). It sources
# agent-watch.sh's pure helpers via the AGENT_WATCH_LIB guard (loads the helpers WITHOUT entering the
# live watch loop), points every ledger/transcript path at a temp dir, drives the clock with the
# HERD_NOW_EPOCH seam, and asserts the classification + reconciliation logic:
#   • existing worktree + no agent + no PR + PAST grace  → DEAD  (+ ledger flips to notified)
#   • a working / present agent                          → ALIVE (never dead)
#   • an open PR                                         → ALIVE (a builder that opened its PR)
#   • a growing transcript                              → ALIVE (one-way liveness veto)
#   • a just-spawned slug still WITHIN grace            → PENDING (not yet dead; first-seen recorded)
#   • a liveness signal returning after a pending record → clears the record
# Run:  bash tests/test-dead-builder.sh
# No `set -e`: some checks deliberately expect a non-zero predicate return; we assert explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── stub `herdr` on PATH so a fired notification is captured, never a real popup ──────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
# only `herdr notification show ...` is exercised here — record the title to $HERDR_NOTIFY_LOG.
if [ "${1:-}" = "notification" ] && [ "${2:-}" = "show" ]; then
  printf '%s\n' "${3:-}" >> "${HERDR_NOTIFY_LOG:?HERDR_NOTIFY_LOG unset}"
fi
exit 0
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# Source the watcher's helpers WITHOUT its live loop. Point config discovery at a nonexistent file so
# herd-config.sh falls back to its generic defaults — fully hermetic, no repo/.herd walk-up.
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type _classify_dead_builder    >/dev/null 2>&1 || fail "_classify_dead_builder not defined"
type _reconcile_dead_builder   >/dev/null 2>&1 || fail "_reconcile_dead_builder not defined"

# Redirect every stateful path at the temp dir (plain globals; safe to reassign post-source).
DEAD_STATE="$T/.agent-watch-dead"
TRANSCRIPT_STATE="$T/.agent-watch-transcript"
export HERD_TRANSCRIPT_ROOT="$T/transcripts"
export HERDR_NOTIFY_LOG="$T/notify.log"; : > "$HERDR_NOTIFY_LOG"
export JOURNAL_FILE="$T/journal.log"   # keep journal_append writes inside the temp dir if honored

NOW=1000000000
GRACE="$(_dead_grace_secs)"

# ── the pure classifier ──────────────────────────────────────────────────────────────────────────
# has-agent has-pr transcript first-seen now grace
[ "$(_classify_dead_builder 1 0 unknown ""              "$NOW" "$GRACE")" = "ALIVE" ]   || fail "present agent → ALIVE"
[ "$(_classify_dead_builder 0 1 unknown ""              "$NOW" "$GRACE")" = "ALIVE" ]   || fail "open PR → ALIVE"
[ "$(_classify_dead_builder 0 0 yes     "$((NOW-9999))" "$NOW" "$GRACE")" = "ALIVE" ]   || fail "growing transcript → ALIVE (veto)"
[ "$(_classify_dead_builder 0 0 unknown ""              "$NOW" "$GRACE")" = "PENDING" ] || fail "first sighting → PENDING"
[ "$(_classify_dead_builder 0 0 no      "$((NOW-1))"    "$NOW" "$GRACE")" = "PENDING" ] || fail "within grace → PENDING"
[ "$(_classify_dead_builder 0 0 no  "$((NOW-GRACE-1))"  "$NOW" "$GRACE")" = "DEAD" ]    || fail "past grace → DEAD"
ok

# ── reconciliation: a builder within grace is PENDING and records its first-seen anchor ────────────
: > "$DEAD_STATE"
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_dead_builder just-spawned "$T/wt-js" "")"
[ "$v" = "PENDING" ] || fail "just-spawned (empty agent, no transcript) should be PENDING, got $v"
[ "$(dead_first_seen just-spawned)" = "$NOW" ] || fail "PENDING should record first-seen anchor"
! dead_notified just-spawned || fail "PENDING must not be marked notified"
[ -s "$HERDR_NOTIFY_LOG" ] && fail "PENDING must NOT fire a notification"
ok

# ── the same slug, still within grace on a later tick, stays PENDING (anchor preserved) ────────────
v="$(HERD_NOW_EPOCH="$((NOW + GRACE - 1))" _reconcile_dead_builder just-spawned "$T/wt-js" "")"
[ "$v" = "PENDING" ] || fail "still within grace should stay PENDING, got $v"
[ "$(dead_first_seen just-spawned)" = "$NOW" ] || fail "first-seen anchor must be preserved across ticks"
ok

# ── once the anchor is older than grace, the slug crosses into DEAD + surfaces once ────────────────
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_dead_builder just-spawned "$T/wt-js" "")"
[ "$v" = "DEAD" ] || fail "past grace should be DEAD, got $v"
dead_notified just-spawned || fail "DEAD should flip the record to notified"
[ "$(dead_first_seen just-spawned)" = "$NOW" ] || fail "DEAD must preserve the original first-seen anchor"
grep -q "just-spawned" "$HERDR_NOTIFY_LOG" || fail "DEAD should fire a 💀 notification"
ok

# ── notification is deduped: a second DEAD tick does NOT fire again ────────────────────────────────
: > "$HERDR_NOTIFY_LOG"
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 5))" _reconcile_dead_builder just-spawned "$T/wt-js" "")"
[ "$v" = "DEAD" ] || fail "still-dead should remain DEAD, got $v"
[ -s "$HERDR_NOTIFY_LOG" ] && fail "DEAD notification must fire at most once per record"
ok

# ── a live agent (any status) is ALIVE and clears a prior dead record ──────────────────────────────
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 9))" _reconcile_dead_builder just-spawned "$T/wt-js" "idle")"
[ "$v" = "ALIVE" ] || fail "present idle agent should be ALIVE, got $v"
[ -z "$(dead_first_seen just-spawned)" ] || fail "ALIVE should clear the dead record"
ok

# ── a working agent is ALIVE, and no record is ever created ────────────────────────────────────────
: > "$DEAD_STATE"
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_dead_builder working-builder "$T/wt-wb" "working")"
[ "$v" = "ALIVE" ] || fail "working agent should be ALIVE, got $v"
[ -z "$(dead_first_seen working-builder)" ] || fail "an ALIVE builder must never get a dead record"
ok

# ── a growing transcript vetoes death even with NO agent record ────────────────────────────────────
# Build a real transcript dir for the worktree (path munged as the watcher expects: '/'+'.' → '-'),
# seed the transcript-state cache with a SMALLER prior byte count + a recent last-grew epoch, then
# reconcile: _transcript_growing sees growth-within-window → "yes" → ALIVE, regardless of grace.
WT_TG="$T/wt-tg"
munged="$(printf '%s' "$WT_TG" | tr '/.' '-')"
mkdir -p "$HERD_TRANSCRIPT_ROOT/$munged"
printf 'x%.0s' $(seq 1 500) > "$HERD_TRANSCRIPT_ROOT/$munged/session.jsonl"   # 500 bytes now
printf '%s %s %s %s\n' alive-via-transcript 100 "$((NOW-1))" "$NOW" > "$TRANSCRIPT_STATE"  # prior 100 bytes, grew at NOW
v="$(HERD_NOW_EPOCH="$((NOW + 1))" _reconcile_dead_builder alive-via-transcript "$WT_TG" "")"
[ "$v" = "ALIVE" ] || fail "growing transcript should keep a no-agent builder ALIVE, got $v"
ok

# ── DEAD_GRACE_MIN override is honored (minutes → seconds) ─────────────────────────────────────────
[ "$(DEAD_GRACE_MIN=5 _dead_grace_secs)" = "300" ] || fail "DEAD_GRACE_MIN=5 should be 300s"
[ "$(DEAD_GRACE_MIN=  _dead_grace_secs)" = "120" ] || fail "unset DEAD_GRACE_MIN should default to 120s"
[ "$(DEAD_GRACE_MIN=xx _dead_grace_secs)" = "120" ] || fail "non-numeric DEAD_GRACE_MIN should default to 120s"
ok

echo "ALL PASS ($pass checks)"
