#!/usr/bin/env bash
# test-watcher-respawn-resolver.sh — hermetic test for the SHA-KEYED resolve-attempt ledger (HERD-55):
# the watcher must RE-SPAWN the isolated conflict resolver when a NEW COMMIT lands on a still-CONFLICTING
# PR, while KEEPING the anti-loop guarantee for an UNCHANGED head sha. Before HERD-55 the ledger was keyed
# by branch alone, so a resolver ran exactly once per branch forever — a resolver that pushed a partial fix
# (moving the head to a new sha) or died/parked left the PR stuck on a stale "resolver failed" verdict with
# no retry. The fix mirrors the EXISTING review-once / healthcheck sha-cache shape already in agent-watch.sh.
#
# It sources agent-watch.sh's helpers via the AGENT_WATCH_LIB guard (no live loop, no herdr, no network),
# points state I/O at a temp dir, and asserts the pure ledger predicates:
#   • same sha never double-spawns          (resolver_dispatched_sha true after a dispatch for that sha)
#   • a NEW sha re-spawns                    (resolver_dispatched_sha false for a changed head)
#   • an ESCALATE: abort is respected        (sha unchanged ⇒ stays terminal, no re-spawn)
#   • the cross-sha retry cap is enforced    (resolver_dispatch_count reaches REFIX_MAX_ROUNDS)
#   • fresh vs retry is distinguishable      (resolver_ever_attempted for the console reason string)
#   • escalated records are terminal+free    (not counted as dispatches)
#   • 6-field ledger shape is correct        (epoch pr slug branch sha outcome)
# Run:  bash tests/test-watcher-respawn-resolver.sh
# No `set -e`: several checks deliberately expect a non-zero predicate return; we assert explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# Source the watcher's helpers WITHOUT its live loop. Point config discovery at a nonexistent file so
# herd-config.sh falls back to its generic defaults — fully hermetic, no repo/.herd walk-up.
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# Issue #144: record_resolve_escalated journals via journal.sh's _journal_file, which resolves from
# WORKTREES_DIR (NOT the TREES override below). Pin BOTH WORKTREES_DIR and JOURNAL_FILE into $T so the
# resolver-ledger journal writes can never escape the sandbox into the REAL derived journal (a live
# .herd/journal.jsonl got polluted with fixture 'resolver_escalated' rows exactly this way).
export WORKTREES_DIR="$T"
export JOURNAL_FILE="$T/journal.jsonl"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
# Hermetic seal: the journal writer must resolve INSIDE the sandbox before any ledger call runs.
case "$(_journal_file)" in "$T"/*) : ;; *) fail "journal path escapes the sandbox: '$(_journal_file)' (issue #144)" ;; esac
for fn in resolver_dispatched_sha resolver_escalated_sha resolver_dispatch_count \
           record_resolve_attempt record_resolve_escalated resolver_ever_attempted \
           resolver_last_sha; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

# Redirect the ledger into the temp dir (overrides whatever the sourced config resolved).
TREES="$T"
RESOLVE_STATE="$T/.agent-watch-resolve-attempts"
rm -f "$RESOLVE_STATE"

PR="42"
BR="feat/thing"
SHA1="aaaaaaaaaaaa"
SHA2="bbbbbbbbbbbb"
SHA3="cccccccccccc"
SHA4="dddddddddddd"

# ── 0. a virgin branch has no attempt at any sha, and reads as "fresh" (never attempted) ─────────────
resolver_dispatched_sha "$PR" "$SHA1" && fail "no ledger yet: resolver_dispatched_sha must be false"
resolver_escalated_sha  "$PR" "$SHA1" && fail "no ledger yet: resolver_escalated_sha must be false"
resolver_ever_attempted "$BR"          && fail "no ledger yet: resolver_ever_attempted must be false (first conflict)"
[ "$(resolver_dispatch_count "$PR")" -eq 0 ] || fail "no ledger yet: dispatch count must be 0"
ok

# ── 1. SAME sha never double-spawns: after a dispatch for SHA1, that exact sha is guarded ────────────
record_resolve_attempt "$PR" slug "$BR" "$SHA1"
resolver_dispatched_sha "$PR" "$SHA1" || fail "same sha: resolver_dispatched_sha must be TRUE after dispatch (anti-loop)"
resolver_ever_attempted "$BR"          || fail "after first dispatch: resolver_ever_attempted must be TRUE (retry reason)"
[ "$(resolver_dispatch_count "$PR")" -eq 1 ] || fail "one dispatch → count must be 1"
ok

# ── 2. a NEW sha re-spawns: SHA2 has no dispatch yet even though SHA1 did (new commit unsticks it) ───
resolver_dispatched_sha "$PR" "$SHA2" && fail "new sha SHA2: resolver_dispatched_sha must be FALSE → re-spawn"
record_resolve_attempt "$PR" slug "$BR" "$SHA2"
resolver_dispatched_sha "$PR" "$SHA2" || fail "after dispatch for SHA2: same-sha guard now holds for SHA2"
resolver_dispatched_sha "$PR" "$SHA1" || fail "dispatching SHA2 must not clear SHA1's guard"
[ "$(resolver_dispatch_count "$PR")" -eq 2 ] || fail "two dispatches → count must be 2"
ok

# ── 3. ESCALATE: abort is terminal for the sha — escalated records are NOT counted as dispatches ─────
record_resolve_escalated "$PR" slug "$BR" "$SHA2"
resolver_escalated_sha "$PR" "$SHA2" || fail "escalated sha: resolver_escalated_sha must be TRUE"
# escalated record must NOT inflate the dispatch budget (it's terminal metadata, not a dispatch)
[ "$(resolver_dispatch_count "$PR")" -eq 2 ] || fail "escalated record must NOT inflate dispatch count (got $(resolver_dispatch_count "$PR"))"
# escalated sha is still NOT dispatched again (the escalated path gates on resolver_escalated_sha first)
resolver_dispatched_sha "$PR" "$SHA3" && fail "SHA3 not dispatched — escalate on SHA2 must not block SHA3"
ok

# ── 4. cross-sha retry cap: a third dispatch reaches REFIX_MAX_ROUNDS (default 3) ───────────────────
record_resolve_attempt "$PR" slug "$BR" "$SHA3"
[ "$(resolver_dispatch_count "$PR")" -eq 3 ] || fail "three dispatches → count must be 3"
cap="${REFIX_MAX_ROUNDS:-3}"
[ "$(resolver_dispatch_count "$PR")" -ge "$cap" ] || fail "3 dispatches must hit the retry cap (cap=$cap)"
# SHA4 is a brand-new head, but the cap is now reached → classify_conflict shows 'resolver gave up'.
# The dispatch-count gate (not the per-sha guard) is what blocks it.
resolver_dispatched_sha "$PR" "$SHA4" && fail "SHA4 not yet dispatched — cap holds it via dispatch count, not sha guard"
[ "$(resolver_dispatch_count "$PR")" -ge "$cap" ] || fail "cap must remain reached after checking SHA4"
ok

# ── 5. last dispatched sha is tracked: resolver_last_sha echoes the most-recent dispatched head ──────
last_sha="$(resolver_last_sha "$PR")"
[ "$last_sha" = "$SHA3" ] || fail "resolver_last_sha must return most-recently dispatched sha (expected $SHA3, got '$last_sha')"
ok

# ── 6. the ledger keys per PR: a different PR is independent ─────────────────────────────────────────
OTHER_PR="99"
resolver_dispatched_sha "$OTHER_PR" "$SHA1" && fail "different PR must not inherit PR $PR's dispatches"
[ "$(resolver_dispatch_count "$OTHER_PR")" -eq 0 ] || fail "different PR dispatch count must be 0"
ok

# ── 7. on-disk shape: dispatched lines have 6 fields ('<epoch> <pr#> <slug> <branch> <sha> dispatched') ─
last="$(grep 'dispatched' "$RESOLVE_STATE" | tail -1)"
set -- $last
[ "$#" -eq 6 ]           || fail "dispatch ledger line must have 6 fields (got $#: '$last')"
[ "$2" = "$PR" ]         || fail "field 2 must be the PR# (got '$2')"
[ "$4" = "$BR" ]         || fail "field 4 must be the branch (got '$4')"
[ "$5" = "$SHA3" ]       || fail "field 5 must be the head sha of the last dispatch (got '$5')"
[ "$6" = "dispatched" ]  || fail "field 6 must be 'dispatched' (got '$6')"
ok

# ── 8. escalated lines have 6 fields with 'escalated' in field 6 ─────────────────────────────────────
esc_line="$(grep 'escalated' "$RESOLVE_STATE" | tail -1)"
set -- $esc_line
[ "$#" -eq 6 ]          || fail "escalated ledger line must have 6 fields (got $#: '$esc_line')"
[ "$6" = "escalated" ]  || fail "field 6 of escalated record must be 'escalated' (got '$6')"
ok

echo "ALL PASS ($pass checks)"
