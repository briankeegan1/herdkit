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
#   (6) EXITED PID IS RECONCILED, AFTER A GRACE — a record whose pid is gone is never reported as
#       expired; the sweep holds it for _LC_EXIT_GRACE so the population's own teardown can retire it
#       with its TRUE reason, and only then claims it with reason=exited.
#   (7) DEADLINES REUSE the existing per-population timeouts (no new tunables) and every population
#       routes to a real, existing owner.
#   (8) FAIL-SOFT — an unreadable probe (missing heartbeat, non-numeric pid) is treated as ALIVE:
#       blindness is never evidence of death.
#   (9) A CLEANLY-COMPLETED DRAINER IS NEVER CALLED HUNG — the regression the pre-merge review caught.
#       A drainer that drains its queue and exits leaves a frozen heartbeat, indistinguishable from a
#       hang on the beat alone. Two independent defenses, both asserted here:
#         (9a) the drainer retires its OWN record on its normal completion path (`*-step.sh finish`),
#              so a clean drain is accounted for the moment it ends; and
#         (9b) a stale beat is CORROBORATED (HERD-122) before it is called a hang — a dead agent is
#              `exited` (retire), only a LIVE-but-silent agent is `expired`, and an unprobeable one is
#              left alone. A frozen beat alone never fabricates a hang.
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
records()    { find "$HERD_LIFECYCLE_DIR" -maxdepth 1 -type f -name '*__*' ! -name '*.expired' ! -name '*.gone' 2>/dev/null | wc -l | tr -cd '0-9'; }

# A real, long-lived child we can probe and (crucially) must never be killed by the sweep. Its stdio is
# detached: a background child holding the suite's stdout would keep a `… | tail` pipe open forever.
start_sleeper() { sleep 300 >/dev/null 2>&1 & printf '%s' "$!"; }

# set_liveness alive|dead|unknown — stub the agent-liveness probe lifecycle.sh corroborates a stale
# heartbeat against. In production this resolves to drainer-liveness.sh's herd_drainer_live_status;
# here it lets us drive each corroboration branch without a control surface. `unknown` UNDEFINES the
# probe, reproducing a runtime that sourced neither driver.sh nor drainer-liveness.sh.
set_liveness() {
  case "$1" in
    unknown) unset -f herd_drainer_live_status 2>/dev/null || true ;;
    *) eval "herd_drainer_live_status() { printf '%s' '$1'; }" ;;
  esac
}
set_liveness unknown
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

# The drainer goes SILENT past DRAINER_HEARTBEAT_TIMEOUT (900s) while its agent is still ALIVE — the
# genuine hang — so it expires, routed to drainer-reclaim. (For a heartbeat population the deadline is
# silence, not absolute lifetime.) The reviewer's expiry is already surfaced, so only the drainer prints.
set_liveness alive
OUT="$(HERD_LIFECYCLE_NOW="$(( FUTURE + 1000 ))" lifecycle_sweep)"
[ "$OUT" = "$(printf 'scribe-drainer\tscribe\tdrainer-reclaim')" ] || fail "(5) silent drainer did not route to drainer-reclaim: [$OUT]"
[ "$(jcount lifecycle_expired)" = "2" ]  || fail "(5) drainer expiry not journaled"
# Heartbeat resumes ⇒ healthy ⇒ the once-only notice re-arms, and a LATER silence expires afresh.
beat_at "$BEAT" "$(( FUTURE + 1000 ))"
HERD_LIFECYCLE_NOW="$(( FUTURE + 1010 ))" lifecycle_sweep >/dev/null
OUT="$(HERD_LIFECYCLE_NOW="$(( FUTURE + 2100 ))" lifecycle_sweep)"
[ "$OUT" = "$(printf 'scribe-drainer\tscribe\tdrainer-reclaim')" ] || fail "(5) a recovered-then-silent drainer must expire again"
[ "$(jcount lifecycle_expired)" = "3" ]  || fail "(5) recovery did not re-arm the once-only expiry notice"
set_liveness unknown
pass; echo "PASS (5) expiry is once-only per record, and re-arms when the process goes healthy again"

# ── (6) an EXITED pid is reconciled to retired — after a grace, never reported as expired ────────
reset_surfaces
SLEEPER2="$(start_sleeper)"
lifecycle_spawn health-worker "91-deadbeef" "pid:$SLEEPER2" agent-watch
[ "$(jfield lifecycle_spawn deadline)" = "1200" ] || fail "(6) health-worker deadline must reuse HEALTH_INFLIGHT_TIMEOUT"
kill "$SLEEPER2" 2>/dev/null; wait "$SLEEPER2" 2>/dev/null

# First observation, well past the deadline: death wins over expiry, but the sweep only NOTES the exit —
# it holds the record so the worker's own collect path can retire it with the true reason.
OUT="$(HERD_LIFECYCLE_NOW="$FUTURE" lifecycle_sweep)"
[ "$OUT" = "" ]                          || fail "(6) an exited process must not be routed as expired"
[ "$(jcount lifecycle_expired)" = "0" ]  || fail "(6) an exited process must not journal lifecycle_expired"
[ "$(jcount lifecycle_retire)" = "0" ]   || fail "(6) the sweep must not claim an exit inside the grace"
[ "$(records)" = "1" ]                   || fail "(6) the record must survive the exit grace"

# Inside the grace, the population's OWN teardown lands the honest reason and the sweep never fires.
HERD_LIFECYCLE_NOW="$(( FUTURE + 10 ))" lifecycle_retire health-worker "91-deadbeef" collected
[ "$(jfield lifecycle_retire reason)" = "collected" ] || fail "(6) the population's true reason must win inside the grace"
[ "$(records)" = "0" ]                   || fail "(6) the true-reason retire must drop the record"
OUT="$(HERD_LIFECYCLE_NOW="$(( FUTURE + 7200 ))" lifecycle_sweep)"
[ "$(jcount lifecycle_retire)" = "1" ]   || fail "(6) a retired record must not be re-claimed by a later sweep"

# And when NO teardown ever comes, the sweep claims it once the grace lapses — nothing lingers.
reset_surfaces
SLEEPER3="$(start_sleeper)"
lifecycle_spawn health-worker "92-orphan" "pid:$SLEEPER3" agent-watch
kill "$SLEEPER3" 2>/dev/null; wait "$SLEEPER3" 2>/dev/null
HERD_LIFECYCLE_NOW="$FUTURE" lifecycle_sweep >/dev/null                       # notes the exit
[ "$(jcount lifecycle_retire)" = "0" ]   || fail "(6) grace not honored on the orphan path"
OUT="$(HERD_LIFECYCLE_NOW="$(( FUTURE + 120 ))" lifecycle_sweep)"             # grace lapsed
[ "$OUT" = "" ]                          || fail "(6) an exited process must never be routed as expired"
[ "$(jcount lifecycle_retire)" = "1" ]   || fail "(6) an abandoned exited process must be retired by the sweep"
[ "$(jfield lifecycle_retire reason)" = "exited" ] || fail "(6) sweep-retire reason must be 'exited'"
[ "$(records)" = "0" ]                   || fail "(6) sweep did not drop the exited record"
pass; echo "PASS (6) exited pid ⇒ held for the grace (true reason wins), then reconciled as reason=exited"

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

# ── (9) a cleanly-completed drainer is NEVER called hung (pre-merge review regression) ───────────
# The exact scenario: scribe drains its queue, prints STOP, exits. Its heartbeat mtime freezes at the
# last beat. Two hours later the sweep runs. It must NOT report a finished process as past deadline.
#
# (9a) DEFENSE ONE — the drainer retires its own record on its normal completion path.
reset_surfaces
set_liveness alive               # even a still-listed agent must not resurrect a retired record
BEAT9="$T/trees/.scribe.heartbeat"; touch "$BEAT9"
lifecycle_spawn scribe-drainer "scribe" "heartbeat:$BEAT9" scribe.sh
lifecycle_retire scribe-drainer "scribe" drained          # what `scribe-step.sh finish` now does
[ "$(jfield lifecycle_retire reason)" = "drained" ] || fail "(9a) clean completion must retire with its true reason"
[ "$(records)" = "0" ]                              || fail "(9a) clean completion must drop the record"
OUT="$(HERD_LIFECYCLE_NOW="$(( $(date +%s) + 7200 ))" lifecycle_sweep)"   # 2h later, beat long frozen
[ "$OUT" = "" ]                                     || fail "(9a) a completed drainer must never be routed as expired"
[ "$(jcount lifecycle_expired)" = "0" ]             || fail "(9a) a completed drainer must never journal an expiry"
[ "$(inbox_rows)" = "0" ]                           || fail "(9a) a completed drainer must never reach the operator inbox"

# The wiring that makes (9a) true in production: both step scripts retire on their `finish` STOP path.
grep -q 'lifecycle_retire scribe-drainer "\$HERD_AGENT_SCRIBE" drained' "$REPO/scripts/herd/scribe-step.sh" \
  || fail "(9a) scribe-step.sh finish must retire the drainer's lifecycle record"
grep -q 'lifecycle_retire research-drainer "\$HERD_AGENT_RESEARCHER" drained' "$REPO/scripts/herd/research-step.sh" \
  || fail "(9a) research-step.sh finish must retire the drainer's lifecycle record"

# (9b) DEFENSE TWO — even with the record left behind (a crash before `finish`), a stale beat is
# corroborated before it is called a hang. This is HERD-122's rule: stale-beat ALONE is not evidence.
FAR="$(( $(date +%s) + 7200 ))"
for case_ in dead alive unknown; do
  reset_surfaces
  set_liveness "$case_"
  touch "$BEAT9"
  lifecycle_spawn scribe-drainer "scribe" "heartbeat:$BEAT9" scribe.sh
  OUT="$(HERD_LIFECYCLE_NOW="$FAR" lifecycle_sweep)"        # beat frozen 2h; only liveness differs
  case "$case_" in
    dead)    # the agent finished/crashed → accounted for, retired. NEVER a fabricated hang.
      [ "$OUT" = "" ]                         || fail "(9b/dead) a gone drainer must not be routed as expired"
      [ "$(jcount lifecycle_expired)" = "0" ] || fail "(9b/dead) a gone drainer must not journal an expiry"
      [ "$(inbox_rows)" = "0" ]               || fail "(9b/dead) a gone drainer must not reach the operator inbox"
      HERD_LIFECYCLE_NOW="$(( FAR + 120 ))" lifecycle_sweep >/dev/null   # past the exit grace
      [ "$(jfield lifecycle_retire reason)" = "exited" ] || fail "(9b/dead) a gone drainer must be retired as exited"
      [ "$(records)" = "0" ]                  || fail "(9b/dead) a gone drainer's record must not linger"
      ;;
    alive)   # silent but running: the genuine hang this contract exists to surface.
      [ "$OUT" = "$(printf 'scribe-drainer\tscribe\tdrainer-reclaim')" ] || fail "(9b/alive) a live-but-silent drainer must expire: [$OUT]"
      [ "$(jcount lifecycle_expired)" = "1" ] || fail "(9b/alive) a live-but-silent drainer must journal an expiry"
      ;;
    unknown) # cannot probe ⇒ no evidence ⇒ no hang, no death. Blindness decides nothing.
      [ "$OUT" = "" ]                         || fail "(9b/unknown) an unprobeable drainer must not be routed"
      [ "$(jcount lifecycle_expired)" = "0" ] || fail "(9b/unknown) an unprobeable drainer must not journal an expiry"
      [ "$(jcount lifecycle_retire)" = "0" ]  || fail "(9b/unknown) an unprobeable drainer must not be declared dead"
      [ "$(records)" = "1" ]                  || fail "(9b/unknown) an unprobeable drainer's record must survive"
      ;;
  esac
done
set_liveness unknown
pass; echo "PASS (9) a cleanly-drained drainer is retired at finish and never called hung; a stale beat is corroborated (dead⇒exited · alive⇒expired · unprobeable⇒left alone)"

echo
echo "✅ test-lifecycle-contracts.sh — $PASS/9 checks passed"
