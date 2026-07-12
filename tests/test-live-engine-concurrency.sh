#!/usr/bin/env bash
# test-live-engine-concurrency.sh — regression test for HEALTH_CONCURRENCY and REVIEW_CONCURRENCY
# semaphores in the Python live engine (HERD-350).
#
# Proves that with HEALTH_CONCURRENCY=1, a second health dispatch waits (returns WAIT and journals
# health_queued) when one candidate is already in-flight — dispatches strictly serialize. Similarly
# proves REVIEW_CONCURRENCY=1 queues a second reviewer when one is in flight.
#
# Hermetic: no gh, git, herdr, network, or model calls — Python stdlib only, test-internal state dir.
# Run:  bash tests/test-live-engine-concurrency.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$REPO/pysrc/herd/live_runtime.py" ] \
  || { echo "FAIL: missing pysrc/herd/live_runtime.py" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
PASS=0
pass() { PASS=$((PASS + 1)); }

# ── (1) HEALTH_CONCURRENCY=1: second dispatch waits and is journaled ────────────────────────────
#
# Lay a live .health-inflight marker for PR1 using the test process's own pid (always alive).
# Drive LiveGates.health(PR2) with HEALTH_CONCURRENCY=1: global in-flight count == 1 == limit, so
# PR2 must return WAIT and journal health_queued WITHOUT shelling out to dispatch a new suite.
PYTHONPATH="$REPO/pysrc" HERD_JOURNAL_NOW="2026-07-11T00:00:00Z" python3 - "$T" <<'PY' \
  || fail "(1) health concurrency serialization test failed"
import json, os, sys
from herd.live_runtime import (
    LiveGates, LiveJournal, LiveState, LiveCandidate, _marker_write, WAIT
)

state_dir = sys.argv[1]
jpath = os.path.join(state_dir, "health-conc.jsonl")

# PR1 is already dispatched: lay a live inflight marker (this process's pid is always alive)
_marker_write(os.path.join(state_dir, ".health-inflight-1-sha1"), os.getpid())

journal = LiveJournal(jpath)
state   = LiveState(state_dir)
gates   = LiveGates(".", state, journal, config={"HEALTH_CONCURRENCY": "1"})

cand2  = LiveCandidate(pr=2, sha="sha2", slug="feat-pr2")
result = gates.health(cand2)

assert result == WAIT, "expected WAIT when limit reached, got %r" % result

evs    = [json.loads(l) for l in open(jpath) if l.strip()]
queued = [e for e in evs if e.get("event") == "health_queued"]
assert len(queued) == 1,              "expected 1 health_queued, got %d: %s" % (len(queued), evs)
assert str(queued[0].get("pr")) == "2", "health_queued pr mismatch: %r" % queued[0]
assert int(queued[0].get("inflight", 0)) >= 1, "inflight field must be >= 1"
assert int(queued[0].get("limit",    0)) == 1, "limit field must be 1"
print("OK: PR2 health_queued; PR1 inflight holds the HEALTH_CONCURRENCY=1 slot")
PY
pass
echo "PASS (1) HEALTH_CONCURRENCY=1: second dispatch waits and journals health_queued"

# ── (2) REVIEW_CONCURRENCY=1: second reviewer waits and is journaled ────────────────────────────
PYTHONPATH="$REPO/pysrc" HERD_JOURNAL_NOW="2026-07-11T00:00:00Z" python3 - "$T" <<'PY' \
  || fail "(2) review concurrency serialization test failed"
import json, os, sys
from herd.live_runtime import (
    LiveGates, LiveJournal, LiveState, LiveCandidate, _marker_write, WAIT
)

state_dir = sys.argv[1]
jpath = os.path.join(state_dir, "review-conc.jsonl")

# PR1 reviewer already in flight: lay a live inflight marker
_marker_write(os.path.join(state_dir, ".review-inflight-1-sha1"), os.getpid())

journal = LiveJournal(jpath)
state   = LiveState(state_dir)
gates   = LiveGates(".", state, journal, config={"REVIEW_CONCURRENCY": "1"})

cand2  = LiveCandidate(pr=2, sha="sha2", slug="feat-pr2")
result = gates.review(cand2)

assert result == WAIT, "expected WAIT when limit reached, got %r" % result

evs    = [json.loads(l) for l in open(jpath) if l.strip()]
queued = [e for e in evs if e.get("event") == "review_queued"]
assert len(queued) == 1,              "expected 1 review_queued, got %d: %s" % (len(queued), evs)
assert str(queued[0].get("pr")) == "2", "review_queued pr mismatch: %r" % queued[0]
assert int(queued[0].get("inflight", 0)) >= 1, "inflight field must be >= 1"
assert int(queued[0].get("limit",    0)) == 1, "limit field must be 1"
print("OK: PR2 review_queued; PR1 inflight holds the REVIEW_CONCURRENCY=1 slot")
PY
pass
echo "PASS (2) REVIEW_CONCURRENCY=1: second reviewer waits and journals review_queued"

# ── (3) DEFAULT limits: HEALTH_CONCURRENCY=1, REVIEW_CONCURRENCY=2 ──────────────────────────────
PYTHONPATH="$REPO/pysrc" python3 - <<'PY' || fail "(3) default concurrency limits test failed"
from herd.live_runtime import LiveGates, LiveJournal, LiveState
g = LiveGates(".", LiveState(None), LiveJournal(None))
assert g._health_max == 1, "default HEALTH_CONCURRENCY must be 1, got %d" % g._health_max
assert g._review_max == 2, "default REVIEW_CONCURRENCY must be 2, got %d" % g._review_max
print("OK: default health_max=%d, review_max=%d" % (g._health_max, g._review_max))
PY
pass
echo "PASS (3) default HEALTH_CONCURRENCY=1, REVIEW_CONCURRENCY=2"

# ── (4) GARBAGE / ZERO config values fall back to safe defaults (never unbounds a rail) ─────────
PYTHONPATH="$REPO/pysrc" python3 - <<'PY' || fail "(4) garbage config fallback test failed"
from herd.live_runtime import LiveGates, LiveJournal, LiveState
g = LiveGates(".", LiveState(None), LiveJournal(None),
              config={"HEALTH_CONCURRENCY": "not-a-number", "REVIEW_CONCURRENCY": "0"})
assert g._health_max == 1, "garbage HEALTH_CONCURRENCY must fall back to 1, got %d" % g._health_max
assert g._review_max == 2, "zero REVIEW_CONCURRENCY must fall back to 2, got %d" % g._review_max
print("OK: garbage/zero values fall back to safe defaults")
PY
pass
echo "PASS (4) garbage/zero config values fall back to safe defaults"

echo "ALL PASS ($PASS/4 live-engine-concurrency: health serialize, review serialize, defaults, garbage coercion)"
