#!/usr/bin/env bash
# test-capacity-agent-lease.sh — hermetic proof of HERD-581 (HERD-557 P2, docs/spikes/capacity-admission.md):
# builder spawns lease agent-class capacity as a second tenant of the SAME ledger P1 built for suites.
#
# Asserts:
#   (a) END-TO-END — scripts/herd/sim/sandbox-capacity-agent-lease-scenario.sh exits 0 and every named
#       checkpoint passes (comparator's spawn class, mutation-prove of the never-leasable reserved-top
#       slot, herd-spawn-gate.sh deferring on suite-ledger contention, a real headless agent's lease
#       admitting/denying/liveness-reclaiming on SIGKILL, a never-launched lease self-releasing on its
#       start timeout, and CAPACITY_BUDGET-off byte-identical) — plus, since HERD-641 (Phase 4 of
#       HERD-625), the WATCHER DRAIN's own admission through this same tenant: two lib-mode drains over
#       one pool queue admitting exactly once, a crashed holder's lease freeing by reconciliation, and
#       the ledger-absent fallback to the legacy per-seat FEATS budget.
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
          agent_lease_start_timeout_self_releases lever_off_byte_identical \
          agent_lease_holder_isolates_caller_fds \
          drain_two_seats_one_admission drain_crashed_holder_lease_frees \
          drain_ledger_absent_legacy_identical; do
  assert_cp "$SCARD" "$cp"
done
echo "PASS (a) every named checkpoint passed: comparator's spawn class, mutation-prove of the never-leasable reserved-top slot, herd-spawn-gate.sh deferring on suite-ledger contention (and admitting once it frees), a headless agent's lease admitting/denying-a-rival/liveness-reclaiming on SIGKILL, a never-launched lease self-releasing on its start timeout, CAPACITY_BUDGET-off byte-identical, the detached holder inheriting none of its caller's descriptors (no fd-9 lock pin), and (HERD-641) the watcher drain admitting once across two seats, freeing a crashed holder's lease by reconciliation, and falling back to the legacy FEATS budget when the ledger is absent"

# ── (b) SUITE tenant untouched (P1's own proof, referenced — never re-run here) ─────────────────────
# This check used to `bash "$SUITE_TEST"` — a FULL nested run of tests/test-capacity-ledger.sh (~22s
# local) inside this test. That bought no signal and cost real gate time three ways: the suite runs
# test-capacity-ledger.sh as its OWN entry anyway (both are tests/test-*.sh, both are bound in
# templates/conformance.tsv as sim proofs of CAPACITY_BUDGET / capacity-ledger.sh), so P1 breaking
# already reds CI under its own name; the nested copy hid that failure under THIS test's name instead;
# and scripts/ci/run-suite.sh caps each test at HERD_CI_TEST_TIMEOUT (120s), so the wrapper was paying
# for two tests' worth of subprocess spawns against ONE cap — which is exactly how it started timing
# out on the CI runner while passing in 29s locally (2026-08-10, PR #734).
#
# What the check was really asserting is a DEPENDENCY: "P1's proof still exists and still runs". That
# is what is asserted now — the file guard at the top of this test — while the RUN belongs to the suite
# entry that owns it. A rename or deletion of P1's proof still fails here loudly; it just no longer
# costs a second execution of it.
[ -s "$SUITE_TEST" ] || fail "tests/test-capacity-ledger.sh (the SUITE tenant's own proof, HERD-557 P1) is missing or empty — the AGENT tenant's claim that P1 is untouched has nothing standing behind it"
echo "PASS (b) the SUITE tenant's proof (tests/test-capacity-ledger.sh, HERD-557 P1) is present and runs as its own suite entry — not re-run here"

# ── (c) HERMETIC ──────────────────────────────────────────────────────────────────────────────────
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "scenario leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (c) hermetic — no leak into the real repo"

echo "ALL PASS — HERD-581 (HERD-557 P2): builder spawns lease 'agent' tenant capacity through the same ledger/comparator P1 built for suites, released liveness-based on agent exit, with herd-spawn-gate.sh closing the spawning-into-idleness pathology and the SUITE tenant left byte-identical. HERD-641 (HERD-625 Phase 4): the watcher's spawn-queue drain admits through that SAME tenant instead of its own FEATS roster, so two seats draining one queue can no longer jointly exceed the machine's budget."
