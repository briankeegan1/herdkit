#!/usr/bin/env bash
# test-test-cap-ledger.sh — hermetic tests for the HERD-478 per-test timeout ledger:
# scripts/herd/test-cap-ledger.sh (the shared lookup + lint library), its wiring into
# scripts/ci/run-suite.sh's per-test `timeout` invocation, and its wiring as a gate lint into BOTH
# scripts/herd/healthcheck.sh (light) and .herd/healthcheck.project.sh (heavy).
#
# Proves:
#   (1) UNIT — herd_test_cap_for: a listed test gets its own cap-secs; an unlisted test gets the
#       default; a row with a malformed (non-numeric) cap-secs falls through to the default rather
#       than starving the test of any cap at all.
#   (2) UNIT — herd_test_cap_ledger_check: a well-formed, non-stale row is clean; a bare row
#       (missing reason or measured-baseline) is MALFORMED; a row whose measured-baseline sits at or
#       under half the default is STALE; a missing ledger file is a valid, clean, EMPTY ledger.
#   (3) MUTATION-PROVE CAP ROUTING (real behavior, not string matching) — drive
#       scripts/ci/run-suite.sh end-to-end over a tiny fixture tests/ dir: a test LISTED with a
#       cap-secs LOWER than the shared default must be killed at its own cap (proving the listed
#       row, not the default, gates it), while an UNLISTED test with the same slow body must survive
#       under the (higher) shared default (proving the listed row never leaks onto other tests).
#       Removing the ledger file entirely reproduces the pre-HERD-478 uniform-default behavior.
#   (4) STALE-ROW LINT REDS A FABRICATED ENTRY — scripts/herd/healthcheck.sh --light (the builder's
#       pre-PR gate) reds a fixture tree whose tests/test-caps.tsv carries a fabricated STALE row,
#       and separately a bare/MALFORMED row; a well-formed non-stale row stays clean.
#   (5) ONE IMPLEMENTATION — run-suite.sh, healthcheck.sh (light) and healthcheck.project.sh (heavy)
#       all source scripts/herd/test-cap-ledger.sh; none re-implements the lookup or the lint.
#
# Run:  bash tests/test-test-cap-ledger.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/scripts/herd/test-cap-ledger.sh"
RUN_SUITE="$ROOT/scripts/ci/run-suite.sh"
HC="$ROOT/scripts/herd/healthcheck.sh"

[ -f "$LIB" ]       || { echo "FAIL: missing library: $LIB" >&2; exit 1; }
[ -f "$RUN_SUITE" ] || { echo "FAIL: missing runner: $RUN_SUITE" >&2; exit 1; }
[ -f "$HC" ]        || { echo "FAIL: missing healthcheck: $HC" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git required to run this test" >&2; exit 1; }

# shellcheck source=/dev/null
. "$LIB"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# ══ (1) UNIT — herd_test_cap_for ═══════════════════════════════════════════════════════════════
LEDGER1="$T/caps1.tsv"
cat > "$LEDGER1" <<'EOF'
test	cap-secs	reason	measured-baseline
test-heavy.sh	180	real subprocess spawns, measured 93s locally, little headroom vs the 120s default	93
test-bad-cap.sh	notanumber	malformed cap-secs on purpose (for this fixture)	40
EOF

[ "$(herd_test_cap_for test-heavy.sh "$LEDGER1")" = "180" ] \
  || fail "(1) listed test-heavy.sh should get its own cap-secs (180), got $(herd_test_cap_for test-heavy.sh "$LEDGER1")"
pass
[ "$(herd_test_cap_for test-unlisted.sh "$LEDGER1")" = "120" ] \
  || fail "(1) unlisted test should get the built-in default (120), got $(herd_test_cap_for test-unlisted.sh "$LEDGER1")"
pass
[ "$(herd_test_cap_for test-unlisted.sh "$LEDGER1" 45)" = "45" ] \
  || fail "(1) unlisted test should honor an explicit default override (45), got $(herd_test_cap_for test-unlisted.sh "$LEDGER1" 45)"
pass
[ "$(herd_test_cap_for test-bad-cap.sh "$LEDGER1")" = "120" ] \
  || fail "(1) a malformed cap-secs field must fall through to the default, not starve the test of any cap"
pass
[ "$(herd_test_cap_for test-anything.sh "$T/no-such-file.tsv")" = "120" ] \
  || fail "(1) a missing ledger file must fall through to the default"
pass
echo "PASS (1) herd_test_cap_for: listed → own cap, unlisted → default, malformed cap-secs → default, missing ledger → default"

# ══ (2) UNIT — herd_test_cap_ledger_check ═══════════════════════════════════════════════════════
# clean, well-formed, non-stale row
LEDGER_CLEAN="$T/caps-clean.tsv"
cat > "$LEDGER_CLEAN" <<'EOF'
test	cap-secs	reason	measured-baseline
test-heavy.sh	180	real subprocess spawns, measured 93s locally, little headroom vs the 120s default	93
EOF
out="$(herd_test_cap_ledger_check "$LEDGER_CLEAN" 120)"; rc=$?
[ "$rc" -eq 0 ] || fail "(2) a well-formed non-stale row must be clean (rc=$rc): $out"
grep -q 'MALFORMED\|STALE' <<< "$out" && fail "(2) a clean ledger must print no MALFORMED/STALE lines (got: $out)"
grep -q 'ADVISORY: 1 ledger row(s); 0 malformed; 0 stale' <<< "$out" || fail "(2) advisory summary should count 1/0/0 (got: $out)"
pass
echo "PASS (2a) a well-formed, non-stale row is clean"

# bare / MALFORMED row: reason field empty
LEDGER_BARE="$T/caps-bare.tsv"
printf 'test\tcap-secs\treason\tmeasured-baseline\ntest-bare.sh\t150\t\t80\n' > "$LEDGER_BARE"
out="$(herd_test_cap_ledger_check "$LEDGER_BARE" 120)"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) a bare row (empty reason) must be flagged (rc=$rc): $out"
grep -q '^MALFORMED' <<< "$out" || fail "(2) bare row should emit a MALFORMED line (got: $out)"
grep -q 'test-bare.sh' <<< "$out" || fail "(2) MALFORMED line should name the offending test (got: $out)"
pass
echo "PASS (2b) a bare row (missing reason) is MALFORMED"

# MALFORMED: non-numeric measured-baseline
LEDGER_BADBASE="$T/caps-badbase.tsv"
printf 'test\tcap-secs\treason\tmeasured-baseline\ntest-badbase.sh\t150\tneeds more time\tnot-a-number\n' > "$LEDGER_BADBASE"
out="$(herd_test_cap_ledger_check "$LEDGER_BADBASE" 120)"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) a non-numeric measured-baseline must be flagged (rc=$rc): $out"
grep -q '^MALFORMED.*measured-baseline' <<< "$out" || fail "(2) should name measured-baseline as the bad field (got: $out)"
pass
echo "PASS (2c) a non-numeric measured-baseline is MALFORMED"

# STALE: measured-baseline comfortably under default (<= half of 120 = 60)
LEDGER_STALE="$T/caps-stale.tsv"
printf 'test\tcap-secs\treason\tmeasured-baseline\ntest-nowfast.sh\t150\tused to be heavy pre-split\t10\n' > "$LEDGER_STALE"
out="$(herd_test_cap_ledger_check "$LEDGER_STALE" 120)"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) a measured-baseline of 10s (<=60s half-default) must be STALE (rc=$rc): $out"
grep -q '^STALE' <<< "$out" || fail "(2) should emit a STALE line (got: $out)"
grep -q 'test-nowfast.sh' <<< "$out" || fail "(2) STALE line should name the offending test (got: $out)"
pass
echo "PASS (2d) a row whose measured-baseline sits comfortably under the default is STALE"

# A missing ledger file is a valid, clean, EMPTY ledger
out="$(herd_test_cap_ledger_check "$T/does-not-exist.tsv" 120)"; rc=$?
[ "$rc" -eq 0 ] || fail "(2) a missing ledger file must be a clean empty ledger (rc=$rc): $out"
grep -q 'ADVISORY: 0 ledger row(s); 0 malformed; 0 stale' <<< "$out" || fail "(2) advisory should read 0/0/0 (got: $out)"
pass
echo "PASS (2e) a missing ledger file is a valid, clean, empty ledger (every test uses the default)"

# ══ (3) MUTATION-PROVE CAP ROUTING — drive scripts/ci/run-suite.sh end-to-end ═══════════════════
FIXT="$T/fixture-tests"; mkdir -p "$FIXT"
cat > "$FIXT/test-fast.sh" <<'EOF'
#!/usr/bin/env bash
echo "fast pass"
exit 0
EOF
cat > "$FIXT/test-listed-slow.sh" <<'EOF'
#!/usr/bin/env bash
sleep 3
echo "slow pass (should never print — killed by its 1s ledger cap)"
exit 0
EOF
cat > "$FIXT/test-unlisted-slow.sh" <<'EOF'
#!/usr/bin/env bash
sleep 3
echo "slow pass (unlisted, must survive under the 6s default)"
exit 0
EOF
chmod +x "$FIXT"/test-*.sh
FIXT_LEDGER="$FIXT/test-caps.tsv"
printf 'test\tcap-secs\treason\tmeasured-baseline\ntest-listed-slow.sh\t1\tfixture: prove a listed cap LOWER than the default actually gates this test\t3\n' > "$FIXT_LEDGER"

run_fixture_suite() {
  HERD_CI_TESTS_DIR="$FIXT" HERD_CI_TEST_TIMEOUT=6 HERD_CI_FORCE_DIRECT=1 \
    HERD_CI_TEST_GLOB='test-*.sh' \
    bash "$RUN_SUITE" 2>&1
}
out="$(run_fixture_suite)"; rc=$?
[ "$rc" -eq 1 ] || fail "(3) the fixture run must exit 1 overall (test-listed-slow.sh must genuinely time out): rc=$rc, out:
$out"
pass
grep -q 'TIMEOUT after 1s' <<< "$out" || fail "(3) test-listed-slow.sh should report TIMEOUT after 1s (its own ledger cap, not the 6s default): $out"
grep -qE '✗ test-listed-slow\.sh' <<< "$out" || fail "(3) test-listed-slow.sh should be reported as a real failure: $out"
grep -qE '✗ test-unlisted-slow\.sh' <<< "$out" && fail "(3) test-unlisted-slow.sh must NOT fail — it should survive under the 6s default, unaffected by the other test's 1s ledger row: $out"
grep -q 'passed:.*2' <<< "$out" || fail "(3) exactly 2 tests (fast + unlisted-slow) should have passed: $out"
pass
echo "PASS (3a) a LISTED test with a cap LOWER than the shared default is genuinely killed at its own cap"
echo "PASS (3b) an UNLISTED test with the identical slow body survives under the (higher) shared default — the listed row never leaks onto it"

# Removing the ledger file reproduces the pre-HERD-478 uniform-default behavior: both slow bodies
# now finish inside the 6s default, so the whole fixture run is clean.
rm -f "$FIXT_LEDGER"
out="$(run_fixture_suite)"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) with no ledger file, both slow tests must finish under the shared default and the run must be clean: rc=$rc, out:
$out"
grep -q 'passed:.*3' <<< "$out" || fail "(3) all 3 fixture tests should pass with no ledger file present: $out"
pass
echo "PASS (3c) no ledger file at all is byte-behaviorally the pre-HERD-478 uniform default for every test"

# ══ (4) STALE-ROW LINT REDS A FABRICATED ENTRY — via scripts/herd/healthcheck.sh --light ════════
WT="$T/wt"
git_wt() { git -C "$WT" "$@"; }
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
cat > "$CFG" <<CFGEOF
PROJECT_ROOT="$WT"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="main"
WORKSPACE_NAME="ctest"
CFGEOF

reset_repo() {
  rm -rf "$WT"; mkdir -p "$WT/bin" "$WT/scripts/herd" "$WT/templates" "$WT/docs" "$WT/tests"
  git_wt init -q
  git_wt checkout -q -b main 2>/dev/null || git_wt checkout -q main
  git_wt config user.email t@t.test
  git_wt config user.name  herd-test
  printf '#!/usr/bin/env bash\ncmd_status() { echo hi; }\n' > "$WT/bin/herd"
  printf '#!/usr/bin/env bash\n: "${EXISTING_KEY:=on}"\n'   > "$WT/scripts/herd/herd-config.sh"
  printf 'name\tkind\n'                                     > "$WT/templates/capabilities.tsv"
  git_wt add -A; git_wt commit -qm seed
  git_wt checkout -q -b feat/x
}
run_hc() { bash "$HC" "$WT" --light "$@"; }

# (4a) a fabricated STALE row → red
reset_repo
printf 'test\tcap-secs\treason\tmeasured-baseline\ntest-fabricated.sh\t150\tfabricated for this test — pretend-heavy\t5\n' > "$WT/tests/test-caps.tsv"
git_wt add -A; git_wt commit -qm "add fabricated stale row"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 1 ] || fail "(4a) a fabricated STALE row must red the light gate (rc=$rc): $out"
grep -q 'TEST-CAP-LEDGER' <<< "$out" || fail "(4a) should emit the TEST-CAP-LEDGER headline (got: $out)"
grep -q 'STALE' <<< "$out" || fail "(4a) should name it STALE (got: $out)"
pass
echo "PASS (4a) a fabricated STALE row reds scripts/herd/healthcheck.sh --light"

# (4b) a bare/MALFORMED row (empty reason) → red
reset_repo
printf 'test\tcap-secs\treason\tmeasured-baseline\ntest-bare.sh\t150\t\t80\n' > "$WT/tests/test-caps.tsv"
git_wt add -A; git_wt commit -qm "add bare row"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 1 ] || fail "(4b) a bare row must red the light gate (rc=$rc): $out"
grep -q 'TEST-CAP-LEDGER' <<< "$out" || fail "(4b) should emit the TEST-CAP-LEDGER headline (got: $out)"
grep -q 'MALFORMED' <<< "$out" || fail "(4b) should name it MALFORMED (got: $out)"
pass
echo "PASS (4b) a bare row (no reason) reds scripts/herd/healthcheck.sh --light"

# (4c) a well-formed, non-stale row → clean
reset_repo
printf 'test\tcap-secs\treason\tmeasured-baseline\ntest-genuinely-heavy.sh\t180\tgenuinely heavy, measured just under the default\t93\n' > "$WT/tests/test-caps.tsv"
git_wt add -A; git_wt commit -qm "add a real row"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(4c) a well-formed non-stale row must stay clean (rc=$rc): $out"
grep -q 'TEST-CAP-LEDGER' <<< "$out" && fail "(4c) a clean ledger must print no TEST-CAP-LEDGER line (got: $out)"
grep -q 'LIGHT CHECK CLEAN' <<< "$out" || fail "(4c) should be a confident light clean (got: $out)"
pass
echo "PASS (4c) a well-formed, non-stale row stays clean"

# (4d) no tests/test-caps.tsv at all → clean (valid empty ledger)
reset_repo
git_wt add -A; git_wt commit -qm "no ledger file" --allow-empty
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "(4d) no ledger file at all must stay clean (rc=$rc): $out"
grep -q 'TEST-CAP-LEDGER' <<< "$out" && fail "(4d) must print nothing (got: $out)"
pass
echo "PASS (4d) no tests/test-caps.tsv at all is a valid, clean, empty ledger"

# ══ (5) ONE IMPLEMENTATION — every consumer sources the shared library ══════════════════════════
grep -q 'test-cap-ledger.sh' "$RUN_SUITE" || fail "(5) scripts/ci/run-suite.sh must source scripts/herd/test-cap-ledger.sh"
grep -q 'test-cap-ledger.sh' "$HC"        || fail "(5) scripts/herd/healthcheck.sh must source scripts/herd/test-cap-ledger.sh"
grep -q 'test-cap-ledger.sh' "$ROOT/.herd/healthcheck.project.sh" \
  || fail "(5) .herd/healthcheck.project.sh must source scripts/herd/test-cap-ledger.sh"
pass
echo "PASS (5) run-suite.sh + both healthcheck gates all source the ONE shared test-cap-ledger library"

echo
echo "ALL PASS ($PASS checks) — HERD-478 per-test timeout ledger: cap routing is mutation-proven live, and the stale/bare-row lint is wired into both gate surfaces."
