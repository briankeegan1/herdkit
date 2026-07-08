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
#   • same sha never double-spawns          (resolver_attempted true after an attempt at that sha)
#   • a NEW sha re-spawns                    (resolver_attempted false for a changed head)
#   • an ESCALATE: abort is respected        (sha unchanged ⇒ stays a terminal needs-you, no re-spawn)
#   • the cross-sha retry cap is enforced    (resolve_attempt_count reaches $_RESOLVE_RETRY_MAX)
#   • fresh vs retry is distinguishable      (resolver_ever_attempted for the console reason string)
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
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in resolver_attempted resolver_ever_attempted resolve_attempt_count record_resolve_attempt; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

# Redirect the ledger into the temp dir (overrides whatever the sourced config resolved).
TREES="$T"
RESOLVE_STATE="$T/.agent-watch-resolve-attempts"
rm -f "$RESOLVE_STATE"

BR="feat/thing"
SHA1="aaaaaaaaaaaa"
SHA2="bbbbbbbbbbbb"
SHA3="cccccccccccc"
SHA4="dddddddddddd"

# ── 0. a virgin branch has no attempt at any sha, and reads as "fresh" (never attempted) ─────────────
resolver_attempted "$BR" "$SHA1" && fail "no ledger yet: resolver_attempted must be false"
resolver_ever_attempted "$BR"    && fail "no ledger yet: resolver_ever_attempted must be false (first conflict)"
[ "$(resolve_attempt_count "$BR")" -eq 0 ] || fail "no ledger yet: attempt count must be 0"
ok

# ── 1. SAME sha never double-spawns: after an attempt at SHA1, that exact sha is guarded ─────────────
record_resolve_attempt 10 slug "$BR" "$SHA1"
resolver_attempted "$BR" "$SHA1" || fail "same sha: resolver_attempted must be TRUE after recording SHA1 (anti-loop)"
resolver_ever_attempted "$BR"    || fail "after first attempt: resolver_ever_attempted must be TRUE (retry reason)"
[ "$(resolve_attempt_count "$BR")" -eq 1 ] || fail "one distinct sha recorded → count must be 1"
ok

# ── 2. ESCALATE: abort respected — a re-record of the SAME sha must not inflate the budget, and the
#      same-sha guard still holds (an escalate does `git merge --abort` with no push → head unchanged) ─
record_resolve_attempt 11 slug "$BR" "$SHA1"   # e.g. a defensive double-write on the same head
resolver_attempted "$BR" "$SHA1" || fail "escalate/same sha: still guarded"
[ "$(resolve_attempt_count "$BR")" -eq 1 ] || fail "duplicate SHA1 record must NOT inflate the distinct-sha budget"
ok

# ── 3. a NEW sha re-spawns: SHA2 has no attempt yet even though SHA1 did (new commit unsticks it) ────
resolver_attempted "$BR" "$SHA2" && fail "new sha SHA2: resolver_attempted must be FALSE → re-spawn"
record_resolve_attempt 12 slug "$BR" "$SHA2"
resolver_attempted "$BR" "$SHA2" || fail "after recording SHA2: same-sha guard now holds for SHA2"
resolver_attempted "$BR" "$SHA1" || fail "recording SHA2 must not clear SHA1's guard"
[ "$(resolve_attempt_count "$BR")" -eq 2 ] || fail "two distinct shas → count must be 2"
ok

# ── 4. cross-sha retry cap: a third distinct sha reaches $_RESOLVE_RETRY_MAX (3); a fourth is over ───
[ "${_RESOLVE_RETRY_MAX:-}" = "3" ] || fail "expected _RESOLVE_RETRY_MAX=3 (got '${_RESOLVE_RETRY_MAX:-unset}')"
record_resolve_attempt 13 slug "$BR" "$SHA3"
[ "$(resolve_attempt_count "$BR")" -ge "$_RESOLVE_RETRY_MAX" ] || fail "3 distinct shas must hit the retry cap"
# SHA4 is a brand-new head, but the cap is now reached → the classify pass would show 'resolver failed
# (retry cap)' rather than re-spawn. The predicate the classify pass gates on:
resolver_attempted "$BR" "$SHA4" && fail "SHA4 not yet attempted — the cap (not the same-sha guard) is what holds it"
[ "$(resolve_attempt_count "$BR")" -ge "$_RESOLVE_RETRY_MAX" ] || fail "cap must remain reached for the over-cap sha"
ok

# ── 5. the ledger keys per BRANCH: a different branch is independent ─────────────────────────────────
OTHER="feat/other"
resolver_attempted "$OTHER" "$SHA1" && fail "different branch must not inherit \$BR's attempts"
[ "$(resolve_attempt_count "$OTHER")" -eq 0 ] || fail "different branch attempt count must be 0"
ok

# ── 6. on-disk shape: each line is '<epoch> <pr#> <slug> <branch> <headSha>' (sha in field 5) ────────
last="$(tail -1 "$RESOLVE_STATE")"
set -- $last
[ "$#" -eq 5 ]   || fail "ledger line must have 5 fields (got $#: '$last')"
[ "$4" = "$BR" ] || fail "field 4 must be the branch (got '$4')"
[ "$5" = "$SHA3" ] || fail "field 5 must be the head sha (got '$5')"
ok

echo "ALL PASS ($pass checks)"
