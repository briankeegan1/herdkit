#!/usr/bin/env bash
# test-lifecycle-contracts.sh — hermetic proof of the SUPERVISED-PROCESS CONTRACT (HERD-193).
#
# Drives the REAL scripts/herd/lifecycle.sh through its documented seams (LIFECYCLE_CONTRACTS,
# HERD_LIFECYCLE_DIR, HERD_LIFECYCLE_INBOX, HERD_LIFECYCLE_NOW, JOURNAL_FILE). Asserts:
#
#   (1) SHIP-DORMANT / BYTE-IDENTICAL WHEN OFF — with LIFECYCLE_CONTRACTS=off (the default) a full
#       spawn → sweep → retire cycle writes NOTHING: no record, no journal line, no inbox row.
#   (2) SPAWN/RETIRE ROUND-TRIP — a spawn writes exactly one record carrying all four properties
#       (owner, deadline, probe/liveness, route) and journals lifecycle_spawn; the retire drops the
#       record and journals lifecycle_retire with lived_secs.
#   (3) NO BEHAVIOR CHANGE FOR IN-DEADLINE PROCESSES — a live, in-deadline pid and a fresh-heartbeat
#       drainer sweep to a byte-for-byte unchanged world: no new journal lines, no inbox rows, and
#       the records survive untouched.
#   (4) EXPIRED FIXTURE ROUTES TO ESCALATION — a live pid past its deadline journals exactly one
#       lifecycle_expired carrying route=<the population's existing owner>, appends one operator-inbox
#       row, prints the route line — and does NOT kill the process (it is still alive afterwards).
#   (5) ONCE-ONLY, RE-ARMED ON RECOVERY — a second sweep does not re-journal an already-surfaced
#       expiry; a drainer whose heartbeat resumes re-arms the notice, so a LATER expiry is journaled
#       afresh rather than swallowed.
#   (6) EXITED PID IS RECONCILED — a record whose pid is gone is RETIRED by the sweep (reason=exited),
#       never reported as expired: a worker that died before its teardown is still accounted for.
#   (7) DEADLINES REUSE the existing per-population timeouts (no new tunables) and every population
#       routes to a real, existing owner.
#   (8) FAIL-SOFT — an unreadable probe (missing heartbeat, non-numeric pid) is treated as ALIVE:
#       blindness is never evidence of death.
#
# Fully hermetic: writes only under a mktemp dir; no herdr, no gh, no network, no model, no watcher.
# Run:  bash tests/test-lifecycle-contracts.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/herd/lifecycle.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$LIB" ] || fail "lifecycle.sh not found at $LIB"

# Hermetic surfaces. Nothing below may escape $T.
export HERD_HERMETIC_GUARD=1
export WORKTREES_DIR="$T/trees"
export JOURNAL_FILE="$T/trees/.herd/journal.jsonl"
export HERD_LIFECYCLE_DIR="$T/trees/.lifecycle"
export HERD_LIFECYCLE_INBOX="$T/trees/.agent-watch-inbox"
mkdir -p "$T/trees/.herd"

# The populations' real timeouts (lifecycle.sh must READ these, not invent its own).
export REVIEW_INFLIGHT_TIMEOUT=1800
export HEALTH_INFLIGHT_TIMEOUT=1200
export DRAINER_HEARTBEAT_TIMEOUT=900

# shellcheck source=/dev/null
. "$REPO/scripts/herd/journal.sh"
# shellcheck source=/dev/null
. "$LIB"

reset_surfaces() {
  rm -rf "$HERD_LIFECYCLE_DIR"
  : > "$JOURNAL_FILE"
  : > "$HERD_LIFECYCLE_INBOX"
}
jcount() { grep -c "\"event\":\"$1\"" "$JOURNAL_FILE" 2>/dev/null | tr -cd '0-9' | sed 's/^$/0/'; }
jfield() {  # jfield <event> <key> — the key's value on the LAST matching event line
  python3 - "$JOURNAL_FILE" "$1" "$2" <<'PY'
import json, sys
path, ev, key = sys.argv[1], sys.argv[2], sys.argv[3]
val = ""
for line in open(path, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("event") == ev:
        val = str(o.get(key, ""))
print(val, end="")
PY
}
inbox_rows() { wc -l < "$HERD_LIFECYCLE_INBOX" 2>/dev/null | tr -cd '0-9' | sed 's/^$/0/'; }
records()    { find "$HERD_LIFECYCLE_DIR" -maxdepth 1 -type f -name '*__*' ! -name '*.expired' 2>/dev/null | wc -l | tr -cd '0-9'; }

# A real, long-lived child we can probe and (crucially) must never be killed by the sweep. Its stdio is
# detached: a background child holding the suite's stdout would keep a `… | tail` pipe open forever.
start_sleeper() { sleep 300 >/dev/null 2>&1 & printf '%s' "$!"; }
# Reap every sleeper on exit so no test child outlives the run.
cleanup_children() { pkill -P $$ 2>/dev/null || true; }
trap 'cleanup_children; rm -rf "$T"' EXIT

# ── (1) SHIP-DORMANT: off ⇒ nothing is written, anywhere ─────────────────────────────────────────
reset_surfaces
(
  unset LIFECYCLE_CONTRACTS   # the DEFAULT, not an explicit off
  lifecycle_spawn reviewer "77-abc123" "pid:$$" agent-watch
  lifecycle_sweep
  lifecycle_retire reviewer "77-abc123" verdict-consumed
)
[ ! -d "$HERD_LIFECYCLE_DIR" ] || [ "$(records)" = "0" ] || fail "(1) default-off wrote a record"
[ ! -s "$JOURNAL_FILE" ]            || fail "(1) default-off wrote a journal line"
[ "$(inbox_rows)" = "0" ]           || fail "(1) default-off wrote an inbox row"
lifecycle_enabled                   && fail "(1) lifecycle_enabled must be false by default"
pass; echo "PASS (1) ship-dormant: LIFECYCLE_CONTRACTS unset ⇒ no record, no journal, no inbox"

export LIFECYCLE_CONTRACTS=on
lifecycle_enabled || fail "(1) lifecycle_enabled must be true with LIFECYCLE_CONTRACTS=on"

# ── (2) spawn/retire round-trip journals all four properties ─────────────────────────────────────
reset_surfaces
lifecycle_spawn reviewer "77-abc123" "pid:4242" agent-watch
[ "$(records)" = "1" ]                              || fail "(2) spawn did not write exactly one record"
[ "$(jcount lifecycle_spawn)" = "1" ]               || fail "(2) spawn did not journal lifecycle_spawn"
[ "$(jfield lifecycle_spawn owner)"      = "agent-watch" ]      || fail "(2) OWNER not journaled at spawn"
[ "$(jfield lifecycle_spawn deadline)"   = "1800" ]             || fail "(2) DEADLINE not journaled (REVIEW_INFLIGHT_TIMEOUT)"
[ "$(jfield lifecycle_spawn probe)"      = "pid:4242" ]         || fail "(2) LIVENESS probe not journaled"
[ "$(jfield lifecycle_spawn route)"      = "gate-corpse-sweep" ]|| fail "(2) RETIRE route not journaled"
[ "$(jfield lifecycle_spawn population)" = "reviewer" ]         || fail "(2) population not journaled"

HERD_LIFECYCLE_NOW="$(( $(date +%s) + 30 ))" lifecycle_retire reviewer "77-abc123" verdict-consumed
[ "$(records)" = "0" ]                              || fail "(2) retire did not drop the record"
[ "$(jcount lifecycle_retire)" = "1" ]              || fail "(2) retire did not journal lifecycle_retire"
[ "$(jfield lifecycle_retire reason)" = "verdict-consumed" ] || fail "(2) retire reason not journaled"
[ "$(jfield lifecycle_retire lived_secs)" -ge 30 ] 2>/dev/null || fail "(2) lived_secs not measured from spawn"
# Retiring an unknown record is a silent no-op (idempotent by construction).
lifecycle_retire reviewer "77-abc123" verdict-consumed
[ "$(jcount lifecycle_retire)" = "1" ]              || fail "(2) retire of an absent record must not journal"
pass; echo "PASS (2) spawn/retire round-trip journals owner + deadline + liveness + route; retire is idempotent"

# ── (3) in-deadline processes: the sweep changes NOTHING (byte-identical world) ───────────────────
reset_surfaces
SLEEPER="$(start_sleeper)"
BEAT="$T/trees/.scribe.heartbeat"; touch "$BEAT"
lifecycle_spawn reviewer "88-def456" "pid:$SLEEPER" agent-watch
lifecycle_spawn scribe-drainer "scribe" "heartbeat:$BEAT" scribe.sh
BEFORE_J="$(md5 -q "$JOURNAL_FILE" 2>/dev/null || md5sum "$JOURNAL_FILE" | cut -d' ' -f1)"
BEFORE_R="$(records)"
OUT="$(lifecycle_sweep)"
AFTER_J="$(md5 -q "$JOURNAL_FILE" 2>/dev/null || md5sum "$JOURNAL_FILE" | cut -d' ' -f1)"
[ "$OUT" = "" ]                     || fail "(3) sweep printed a route line for in-deadline processes"
[ "$BEFORE_J" = "$AFTER_J" ]        || fail "(3) sweep journaled something for in-deadline processes"
[ "$(records)" = "$BEFORE_R" ]      || fail "(3) sweep dropped an in-deadline record"
[ "$(inbox_rows)" = "0" ]           || fail "(3) sweep wrote an inbox row for in-deadline processes"
[ "$(jcount lifecycle_expired)" = "0" ] || fail "(3) an in-deadline process must never expire"
pass; echo "PASS (3) in-deadline live pid + fresh heartbeat ⇒ sweep is a byte-for-byte no-op"

# ── (4) expired fixture routes to escalation, and is NOT killed ──────────────────────────────────
# Pin "now" 2h past the reviewer's 1800s deadline. The sleeper is still alive. The drainer keeps
# beating (its heartbeat mtime advances to the pinned now), so exactly ONE record expires here.
FUTURE="$(( $(date +%s) + 7200 ))"
beat_at() { python3 -c 'import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
beat_at "$BEAT" "$FUTURE"
OUT="$(HERD_LIFECYCLE_NOW="$FUTURE" lifecycle_sweep)"
printf '%s' "$OUT" | grep -q "^reviewer	88-def456	gate-corpse-sweep$" || fail "(4) sweep did not print the population's escalation route: [$OUT]"
[ "$(jcount lifecycle_expired)" = "1" ]                        || fail "(4) expired did not journal exactly once"
[ "$(jfield lifecycle_expired route)" = "gate-corpse-sweep" ]  || fail "(4) lifecycle_expired must carry the escalation route"
[ "$(jfield lifecycle_expired owner)" = "agent-watch" ]        || fail "(4) lifecycle_expired must carry the owner"
[ "$(inbox_rows)" = "1" ]                                      || fail "(4) expired did not append exactly one inbox row"
grep -q "lifecycle:reviewer" "$HERD_LIFECYCLE_INBOX"           || fail "(4) inbox row missing the lifecycle:<population> ref"
# NEVER a blind kill: the expired process is still running, and its record is still there for its owner.
kill -0 "$SLEEPER" 2>/dev/null                                 || fail "(4) sweep KILLED an expired process — it must only journal + route"
[ "$(records)" = "2" ]                                         || fail "(4) sweep must not retire an expired-but-live process"
pass; echo "PASS (4) expired ⇒ one lifecycle_expired + one inbox row + route line; the process is left alive for its owner"

# ── (5) once-only, re-armed on recovery ──────────────────────────────────────────────────────────
OUT="$(HERD_LIFECYCLE_NOW="$FUTURE" lifecycle_sweep)"
[ "$OUT" = "" ]                          || fail "(5) a second sweep re-printed an already-surfaced expiry"
[ "$(jcount lifecycle_expired)" = "1" ]  || fail "(5) a second sweep re-journaled an already-surfaced expiry"
[ "$(inbox_rows)" = "1" ]                || fail "(5) a second sweep re-flooded the inbox"

# The drainer goes SILENT past DRAINER_HEARTBEAT_TIMEOUT (900s) → expires, routed to drainer-reclaim.
# (For a heartbeat population the deadline is silence, not absolute lifetime — a drainer legitimately
# runs for hours.) The reviewer's expiry is already surfaced, so only the drainer's route prints.
OUT="$(HERD_LIFECYCLE_NOW="$(( FUTURE + 1000 ))" lifecycle_sweep)"
[ "$OUT" = "$(printf 'scribe-drainer\tscribe\tdrainer-reclaim')" ] || fail "(5) silent drainer did not route to drainer-reclaim: [$OUT]"
[ "$(jcount lifecycle_expired)" = "2" ]  || fail "(5) drainer expiry not journaled"
# Heartbeat resumes ⇒ healthy ⇒ the once-only notice re-arms, and a LATER silence expires afresh.
beat_at "$BEAT" "$(( FUTURE + 1000 ))"
HERD_LIFECYCLE_NOW="$(( FUTURE + 1010 ))" lifecycle_sweep >/dev/null
OUT="$(HERD_LIFECYCLE_NOW="$(( FUTURE + 2100 ))" lifecycle_sweep)"
[ "$OUT" = "$(printf 'scribe-drainer\tscribe\tdrainer-reclaim')" ] || fail "(5) a recovered-then-silent drainer must expire again"
[ "$(jcount lifecycle_expired)" = "3" ]  || fail "(5) recovery did not re-arm the once-only expiry notice"
pass; echo "PASS (5) expiry is once-only per record, and re-arms when the process goes healthy again"

# ── (6) an EXITED pid is reconciled to retired, never reported as expired ────────────────────────
reset_surfaces
SLEEPER2="$(start_sleeper)"
lifecycle_spawn health-worker "91-deadbeef" "pid:$SLEEPER2" agent-watch
[ "$(jfield lifecycle_spawn deadline)" = "1200" ] || fail "(6) health-worker deadline must reuse HEALTH_INFLIGHT_TIMEOUT"
kill "$SLEEPER2" 2>/dev/null; wait "$SLEEPER2" 2>/dev/null
OUT="$(HERD_LIFECYCLE_NOW="$FUTURE" lifecycle_sweep)"     # past deadline AND dead: death wins
[ "$OUT" = "" ]                          || fail "(6) an exited process must not be routed as expired"
[ "$(jcount lifecycle_expired)" = "0" ]  || fail "(6) an exited process must not journal lifecycle_expired"
[ "$(jcount lifecycle_retire)" = "1" ]   || fail "(6) an exited process must be retired by the sweep"
[ "$(jfield lifecycle_retire reason)" = "exited" ] || fail "(6) sweep-retire reason must be 'exited'"
[ "$(records)" = "0" ]                   || fail "(6) sweep did not drop the exited record"
pass; echo "PASS (6) exited pid ⇒ reconciled to lifecycle_retire reason=exited (never an expiry)"

# ── (7) deadlines reuse existing timeouts; every population routes to a real owner ───────────────
[ "$(lifecycle_deadline reviewer)"         = "1800" ] || fail "(7) reviewer deadline ≠ REVIEW_INFLIGHT_TIMEOUT"
[ "$(lifecycle_deadline health-worker)"    = "1200" ] || fail "(7) health-worker deadline ≠ HEALTH_INFLIGHT_TIMEOUT"
[ "$(lifecycle_deadline scribe-drainer)"   = "900"  ] || fail "(7) scribe-drainer deadline ≠ DRAINER_HEARTBEAT_TIMEOUT"
[ "$(lifecycle_deadline research-drainer)" = "900"  ] || fail "(7) research-drainer deadline ≠ DRAINER_HEARTBEAT_TIMEOUT"
[ "$(lifecycle_deadline builder)"          = "1800" ] || fail "(7) unknown population must fall back to 1800"
[ "$(lifecycle_route reviewer)"         = "gate-corpse-sweep"   ] || fail "(7) reviewer route"
[ "$(lifecycle_route health-worker)"    = "gate-corpse-sweep"   ] || fail "(7) health-worker route"
[ "$(lifecycle_route scribe-drainer)"   = "drainer-reclaim"     ] || fail "(7) scribe-drainer route"
[ "$(lifecycle_route research-drainer)" = "drainer-reclaim"     ] || fail "(7) research-drainer route"
[ "$(lifecycle_route builder)"          = "stall-detector"      ] || fail "(7) builder route"
[ "$(lifecycle_route resolver)"         = "resolver-escalation" ] || fail "(7) resolver route"
[ "$(lifecycle_route mystery)"          = "operator"            ] || fail "(7) unknown population must route to the operator"
# A non-numeric timeout falls back to the population's shipped default rather than to zero (which
# would expire every process on its first sweep).
[ "$(REVIEW_INFLIGHT_TIMEOUT=abc lifecycle_deadline reviewer)" = "1800" ] || fail "(7) non-numeric timeout must fall back, not zero"
pass; echo "PASS (7) deadlines reuse the existing per-population timeouts; every route names a real owner"

# ── (8) fail-soft: an unreadable probe is ALIVE, never a fabricated death ────────────────────────
# An ABSENT heartbeat is treated as a fresh beat (the same rule drainer-liveness.sh applies), so a
# drainer whose step script has not yet written its first beat is never surfaced as hung — however far
# past its deadline the clock is pinned.
reset_surfaces
lifecycle_spawn research-drainer "researcher" "heartbeat:$T/trees/.no-such-heartbeat" research.sh
OUT="$(HERD_LIFECYCLE_NOW="$FUTURE" lifecycle_sweep)"
[ "$OUT" = "" ]                          || fail "(8) an absent heartbeat must never expire or route"
[ "$(jcount lifecycle_expired)" = "0" ]  || fail "(8) an absent heartbeat must never journal an expiry"
[ "$(jcount lifecycle_retire)" = "0" ]   || fail "(8) an absent heartbeat must never be declared dead"

# An UNREADABLE pid is likewise never evidence of death: the record is surfaced as past-deadline
# (it is genuinely unaccounted for, which is the finding) and routed to its owner — but it is NEVER
# retired as 'exited', because nothing proved the process is gone.
reset_surfaces
lifecycle_spawn resolver "nosuchpid" "pid:not-a-number" agent-watch
OUT="$(HERD_LIFECYCLE_NOW="$FUTURE" lifecycle_sweep)"
[ "$OUT" = "$(printf 'resolver\tnosuchpid\tresolver-escalation')" ] || fail "(8) unreadable pid past deadline must route, not die: [$OUT]"
[ "$(jcount lifecycle_retire)" = "0" ]   || fail "(8) an unreadable pid must never be declared exited"
[ "$(records)" = "1" ]                   || fail "(8) an unreadable pid must leave its record intact for its owner"
# A read-only record dir cannot abort a caller running under `set -euo pipefail`.
( set -euo pipefail; HERD_LIFECYCLE_DIR="/proc/nonexistent/lifecycle" lifecycle_spawn reviewer x pid:1 o >/dev/null 2>&1 ) \
  || fail "(8) lifecycle_spawn must never fail its caller"
( set -euo pipefail; HERD_LIFECYCLE_DIR="/proc/nonexistent/lifecycle" lifecycle_sweep >/dev/null 2>&1 ) \
  || fail "(8) lifecycle_sweep must never fail its caller"
pass; echo "PASS (8) fail-soft: unreadable probe ⇒ alive; unwritable ledger ⇒ silent, never aborts the caller"

echo
echo "✅ test-lifecycle-contracts.sh — $PASS/8 checks passed"
