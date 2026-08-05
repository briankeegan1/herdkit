#!/usr/bin/env bash
# test-capacity-ledger.sh — hermetic proof of HERD-557 P1 (docs/spikes/capacity-admission.md): the
# suite-capacity LEDGER that evolves HERD-529's flat LOCAL_SUITE_CONCURRENCY slot cap into a
# reserved-slice, priority-aware admission scheme behind CAPACITY_BUDGET.
#
# Asserts:
#   (a) END-TO-END — scripts/herd/sim/sandbox-capacity-ledger-scenario.sh exits 0 and every
#       checkpoint passes (partition math, overload breaker, flock auto-release-on-kill, possession,
#       mutation-prove, retry-solo drain barrier + env-suspect giveup, lever-off byte-identical).
#   (b) LEGACY PATH UNTOUCHED — tests/test-local-suite-slot.sh (HERD-529's own proof, run here
#       UNMODIFIED) still passes in full, with CAPACITY_BUDGET never set — the strongest available
#       proof that the ledger's off/unavailable path is byte-identical to before this feature existed.
#   (c) HERMETIC — the run leaves no artifacts in the real repo tree.
#
# Fully hermetic: local processes only, no herdr/gh/network/git. Run:  bash tests/test-capacity-ledger.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-capacity-ledger-scenario.sh"
LEGACY_TEST="$HERE/test-local-suite-slot.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCENARIO" ] || fail "missing $SCENARIO"
[ -f "$LEGACY_TEST" ] || fail "missing $LEGACY_TEST"

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
  || fail "capacity-ledger scenario exited non-zero"$'\n'"$(cat "$T/run.out")"
SCARD="$ART/scorecard.json"
[ -f "$SCARD" ] || fail "scorecard.json not emitted at $SCARD"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCARD" || fail "scorecard.json is not valid JSON"
[ "$(sc "$SCARD" scenario)" = "capacity-ledger" ] || fail "unexpected scenario name"
[ "$(sc "$SCARD" result)" = "pass" ] || fail "scenario result should be pass"$'\n'"$(cat "$T/run.out")"
[ "$(sc "$SCARD" failed)" -eq 0 ] || fail "scenario failed count should be 0"
echo "PASS (a) end-to-end scenario drain + scorecard shape"

for cp in partition_math overload_breaker flock_release_on_kill \
          possession_watcher_admits_despite_burst mutation_prove_reserved_top \
          retry_solo_no_overlap retry_solo_env_suspect_giveup lever_off_no_capacity_files; do
  assert_cp "$SCARD" "$cp"
done
echo "PASS (a) every named checkpoint passed: partition math, overload breaker, flock auto-release-on-kill, possession (watcher admits despite a builder-local burst), mutation-prove (reserved-top override degrades the same leg), retry-solo drain barrier + no-overlap, retry-solo env-suspect giveup, lever-off zero capacity-files"

# ── (b) legacy HERD-529 path untouched ───────────────────────────────────────────────────────────
unset CAPACITY_BUDGET
bash "$LEGACY_TEST" >"$T/legacy.out" 2>&1 \
  || fail "tests/test-local-suite-slot.sh (unmodified, CAPACITY_BUDGET unset) failed — the legacy flat-cap path must be byte-identical"$'\n'"$(cat "$T/legacy.out")"
grep -q "ALL PASS" "$T/legacy.out" || fail "tests/test-local-suite-slot.sh did not report ALL PASS: $(cat "$T/legacy.out")"
echo "PASS (b) tests/test-local-suite-slot.sh (HERD-529, unmodified) still passes in full — the legacy path is untouched"

# ── (c) HERMETIC ──────────────────────────────────────────────────────────────────────────────────
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "scenario leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (c) hermetic — no leak into the real repo"

echo "ALL PASS — HERD-557 P1: the capacity ledger admits watcher/builder-local/retry-solo suites through a reserved-slice partition with a real flock backbone, and the CAPACITY_BUDGET=off path stays byte-identical to HERD-529's original flat-cap machinery."
