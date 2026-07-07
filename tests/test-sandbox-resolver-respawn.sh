#!/usr/bin/env bash
# test-sandbox-resolver-respawn.sh — hermetic proof of the HERD-55 resolver-respawn simulation
# (scripts/herd/sim/sandbox-resolver-respawn-scenario.sh), which drives the REAL watcher decision
# code (agent-watch.sh sourced in lib mode: _classify_conflict + spawn_resolver + the sha-keyed
# resolve ledger helpers) through the full dispatch → death → new-sha respawn → cap chain.
#
# Asserts:
#   (a) END-TO-END — the scenario exits 0 and every checkpoint passes; scorecard.json is emitted.
#   (b) THE RESPAWN CHAIN — first_dispatch, dead_respawn, new_commit_respawn and respawn_capped all
#       pass (a resolver is re-spawned on a new sha AND on death, and respawns are bounded).
#   (c) TERMINAL RAILS — escalate_terminal (an ESCALATE never re-dispatches for that sha) and
#       alive_holds (a live resolver is never double-dispatched) pass.
#   (d) JOURNAL TRAIL — the resolver_respawn events were journaled (journal_trail passes; count >= 2).
#   (e) HERMETIC — the run leaves NO new entry in the real repo tree and touches no real gh/panes.
#
# Fully hermetic: local git only, NO herdr, NO network, NO model. Mirrors tests/test-sandbox-concurrency.sh.
# Run:  bash tests/test-sandbox-resolver-respawn.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-resolver-respawn-scenario.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCENARIO" ] || fail "missing $SCENARIO"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
BASELINE_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"

sc() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
cp_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["checkpoints"]:
    if c["name"]==sys.argv[2]: print(c["status"]); break
' "$1" "$2"
}

# ── (a) END-TO-END + SCORECARD SHAPE ────────────────────────────────────────────
ART="$T/run"
bash "$SCENARIO" --artifacts "$ART" >"$T/out" 2>&1 \
  || fail "(a) resolver-respawn scenario exited non-zero"$'\n'"$(cat "$T/out")"
SCARD="$ART/scorecard.json"
[ -f "$SCARD" ] || fail "(a) scorecard.json not emitted at $SCARD"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCARD" || fail "(a) scorecard.json invalid JSON"
[ "$(sc "$SCARD" scenario)" = "resolver-respawn" ] || fail "(a) unexpected scenario name"
[ "$(sc "$SCARD" result)" = "pass" ]               || fail "(a) result should be pass"$'\n'"$(cat "$T/out")"
[ "$(sc "$SCARD" failed)" -eq 0 ]                  || fail "(a) failed should be 0 (got $(sc "$SCARD" failed))"
[ "$(sc "$SCARD" passed)" -ge 7 ]                  || fail "(a) passed should be >= 7"
echo "PASS (a) end-to-end drain + scorecard shape"

# ── (b) THE RESPAWN CHAIN ───────────────────────────────────────────────────────
for c in first_dispatch dead_respawn new_commit_respawn respawn_capped; do
  [ "$(cp_status "$SCARD" "$c")" = "pass" ] || fail "(b) checkpoint $c not pass"
done
echo "PASS (b) dispatch -> death respawn -> new-sha respawn -> cap"

# ── (c) TERMINAL RAILS ──────────────────────────────────────────────────────────
[ "$(cp_status "$SCARD" escalate_terminal)" = "pass" ] || fail "(c) escalate_terminal not pass"
[ "$(cp_status "$SCARD" alive_holds)" = "pass" ]       || fail "(c) alive_holds not pass"
echo "PASS (c) escalate terminal + live-resolver hold"

# ── (d) JOURNAL TRAIL ───────────────────────────────────────────────────────────
[ "$(cp_status "$SCARD" journal_trail)" = "pass" ]        || fail "(d) journal_trail not pass"
[ "$(sc "$SCARD" resolver_respawn_events)" -ge 2 ]        || fail "(d) expected >= 2 resolver_respawn events"
echo "PASS (d) resolver_respawn journal trail"

# ── (e) HERMETIC — nothing leaked into the real repo tree ───────────────────────
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "(e) scenario leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (e) hermetic — no leak into the real repo"

echo "ALL PASS"
