#!/usr/bin/env bash
# test-capacity-agent-lease.sh — hermetic proof of HERD-581 (HERD-557 P2, docs/spikes/capacity-admission.md):
# builder spawns lease agent-class capacity as a second tenant of the SAME ledger P1 built for suites.
#
# Asserts:
#   (a) END-TO-END — scripts/herd/sim/sandbox-capacity-agent-lease-scenario.sh exits 0 and every named
#       checkpoint passes (comparator's spawn class, mutation-prove of the never-leasable reserved-top
#       slot, herd-spawn-gate.sh deferring on suite-ledger contention, a real headless agent's lease
#       admitting/denying/liveness-reclaiming on SIGKILL, a never-launched lease self-releasing on its
#       start timeout, and CAPACITY_BUDGET-off byte-identical).
#   (b) SUITE TENANT UNTOUCHED — tests/test-capacity-ledger.sh (HERD-557 P1's own proof, run here
#       UNMODIFIED) still passes in full — the strongest available proof that adding the AGENT tenant
#       never regressed the SUITE tenant it shares a library with.
#   (c) HERMETIC — the run leaves no artifacts in the real repo tree.
#
# Fully hermetic: local processes only, no herdr/gh/network/git (herd_spawn_gate_saturated's `gh` call
# is stubbed by the scenario itself, mirroring tests/test-spawn-rate-match.sh's own harness). Run:
#   bash tests/test-capacity-agent-lease.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-capacity-agent-lease-scenario.sh"
SUITE_TEST="$HERE/test-capacity-ledger.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCENARIO" ] || fail "missing $SCENARIO"
[ -f "$SUITE_TEST" ] || fail "missing $SUITE_TEST"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
BASELINE_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"

sc() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
cp_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["checkpoints"]:
    if c["name"]==sys.argv[2]: print(c["status"]); break
else:
    print("MISSING")
' "$1" "$2"
}
assert_cp() {
  local scard="$1" name="$2" got
  got="$(cp_status "$scard" "$name")"
  [ "$got" = "pass" ] || fail "checkpoint '$name' status=$got (want pass)"
}

# ── (a) END-TO-END ────────────────────────────────────────────────────────────────────────────────
ART="$T/run"
bash "$SCENARIO" --artifacts "$ART" >"$T/run.out" 2>&1 \
  || fail "capacity-agent-lease scenario exited non-zero"$'\n'"$(cat "$T/run.out")"
SCARD="$ART/scorecard.json"
[ -f "$SCARD" ] || fail "scorecard.json not emitted at $SCARD"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCARD" || fail "scorecard.json is not valid JSON"
[ "$(sc "$SCARD" scenario)" = "capacity-agent-lease" ] || fail "unexpected scenario name"
[ "$(sc "$SCARD" result)" = "pass" ] || fail "scenario result should be pass"$'\n'"$(cat "$T/run.out")"
[ "$(sc "$SCARD" failed)" -eq 0 ] || fail "scenario failed count should be 0"
echo "PASS (a) end-to-end scenario + scorecard shape"

for cp in spawn_class_in_comparator spawn_never_leases_reserved_top \
          gate_defers_while_suite_saturated_admits_when_freed \
          agent_lease_admitted_then_reclaimed_on_kill \
          agent_lease_start_timeout_self_releases lever_off_byte_identical; do
  assert_cp "$SCARD" "$cp"
done
echo "PASS (a) every named checkpoint passed: comparator's spawn class, mutation-prove of the never-leasable reserved-top slot, herd-spawn-gate.sh deferring on suite-ledger contention (and admitting once it frees), a headless agent's lease admitting/denying-a-rival/liveness-reclaiming on SIGKILL, a never-launched lease self-releasing on its start timeout, CAPACITY_BUDGET-off byte-identical"

# ── (b) SUITE tenant untouched (P1's own proof, unmodified) ─────────────────────────────────────────
bash "$SUITE_TEST" >"$T/suite.out" 2>&1 \
  || fail "tests/test-capacity-ledger.sh (unmodified) failed — the SUITE tenant must be unaffected by the AGENT tenant sharing its library"$'\n'"$(cat "$T/suite.out")"
grep -q "ALL PASS" "$T/suite.out" || fail "tests/test-capacity-ledger.sh did not report ALL PASS: $(cat "$T/suite.out")"
echo "PASS (b) tests/test-capacity-ledger.sh (HERD-557 P1, unmodified) still passes in full — the SUITE tenant is untouched"

# ── (c) HERMETIC ──────────────────────────────────────────────────────────────────────────────────
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "scenario leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (c) hermetic — no leak into the real repo"

echo "ALL PASS — HERD-581 (HERD-557 P2): builder spawns lease 'agent' tenant capacity through the same ledger/comparator P1 built for suites, released liveness-based on agent exit, with herd-spawn-gate.sh closing the spawning-into-idleness pathology and the SUITE tenant left byte-identical."
