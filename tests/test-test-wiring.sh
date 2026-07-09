#!/usr/bin/env bash
# test-test-wiring.sh — hermetic proof for the TEST-WIRING RATCHET (HERD-257):
# scripts/herd/test-wiring-lint.sh, which asserts every tests/test-*.sh is either
# referenced by tests/herd.bats (the merge-gate curated suite) or listed in
# tests/test-wiring-exempt.tsv with a reason.
#
# Covers:
#   (1) the REAL committed tree is clean against the ratchet (every test wired or exempt).
#   (2) a PLANTED unexempted + unwired tests/test-*.sh is CAUGHT (exit 1, UNWIRED line).
#   (3) WIRING the planted file into a fixture herd.bats clears the red.
#   (4) EXEMPTING the planted file (with a reason) clears the red without wiring.
#   (5) an EXEMPT row with an empty reason is a CODE error.
#   (6) a PHANTOM exempt row (name with no matching test file) is a CODE error.
#   (7) FAIL-SOFT: a tree with no tests/herd.bats (consumer project) SKIPS (exit 2), never reds.
#
# Fully hermetic: local temp trees + the committed lint. NO herdr, NO gh, NO network, NO model.
# Run:  bash tests/test-test-wiring.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/scripts/herd/test-wiring-lint.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

[ -f "$LINT" ] || fail "lint script missing: $LINT"
# shellcheck source=/dev/null
. "$LINT"

# ── 1. the REAL tree is clean ────────────────────────────────────────────────────────────────────
real_out="$(herd_test_wiring_lint "$ROOT")"; real_rc=$?
if [ "$real_rc" -ne 0 ]; then
  echo "$real_out" >&2
  fail "(1) real engine tree is NOT clean under the test-wiring ratchet (rc=$real_rc) — wire each UNWIRED test into tests/herd.bats or list it in tests/test-wiring-exempt.tsv with a reason"
fi
printf '%s\n' "$real_out" | grep -qE '^(UNWIRED|EXEMPT)' && fail "(1) violation lines present despite clean exit"
pass
echo "PASS (1) real tree: every tests/test-*.sh is wired in herd.bats or exempted with a reason"

# ── seed a minimal synthetic engine suite tree ───────────────────────────────────────────────────
seed_tree() {
  local d="$1"
  mkdir -p "$d/tests" "$d/scripts/herd"
  # One wired hermetic test + a bats entry that references it.
  cat > "$d/tests/test-already-wired.sh" <<'EOF'
#!/usr/bin/env bash
echo "ALL PASS"
exit 0
EOF
  cat > "$d/tests/herd.bats" <<'EOF'
#!/usr/bin/env bats
@test "hermetic already-wired test passes" {
  run bash "$BATS_TEST_DIRNAME/test-already-wired.sh"
  [ "$status" -eq 0 ]
}
EOF
  # Empty exempt allowlist (header only).
  printf 'name\treason\n' > "$d/tests/test-wiring-exempt.tsv"
}

# ── 2. planted unexempted + unwired test is CAUGHT ───────────────────────────────────────────────
P="$T/plant"; seed_tree "$P"
cat > "$P/tests/test-brand-new.sh" <<'EOF'
#!/usr/bin/env bash
echo "ALL PASS"
exit 0
EOF
out="$(herd_test_wiring_lint "$P")"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) planted unwired test was NOT a code error (rc=$rc out=$out)"
printf '%s\n' "$out" | grep -qE '^UNWIRED: test-brand-new\.sh' \
  || fail "(2) violation did not name the planted file: $out"
pass
echo "PASS (2) a planted unexempted + unwired tests/test-*.sh is caught (UNWIRED)"

# ── 3. wiring it into herd.bats clears the red ───────────────────────────────────────────────────
cat >> "$P/tests/herd.bats" <<'EOF'
@test "hermetic brand-new test passes" {
  run bash "$BATS_TEST_DIRNAME/test-brand-new.sh"
  [ "$status" -eq 0 ]
}
EOF
out="$(herd_test_wiring_lint "$P")"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) wiring into herd.bats did not clear the red (rc=$rc out=$out)"
pass
echo "PASS (3) wiring the planted file into tests/herd.bats clears the ratchet"

# ── 4. exempting (with reason) clears the red without wiring ─────────────────────────────────────
Q="$T/exempt"; seed_tree "$Q"
cat > "$Q/tests/test-manual-only.sh" <<'EOF'
#!/usr/bin/env bash
echo "manual"
exit 0
EOF
# Still unwired → red
out="$(herd_test_wiring_lint "$Q")"; rc=$?
[ "$rc" -eq 1 ] || fail "(4a) pre-exempt state should be red (rc=$rc)"
printf 'name\treason\ntest-manual-only.sh\tmanual live smoke; not a hermetic gate test\n' \
  > "$Q/tests/test-wiring-exempt.tsv"
out="$(herd_test_wiring_lint "$Q")"; rc=$?
[ "$rc" -eq 0 ] || fail "(4b) exempt-with-reason did not clear the red (rc=$rc out=$out)"
pass
echo "PASS (4) exempting a test with a non-empty reason clears the ratchet without wiring"

# ── 5. exempt row with empty reason is a CODE error ──────────────────────────────────────────────
R="$T/empty-reason"; seed_tree "$R"
cat > "$R/tests/test-no-reason.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
printf 'name\treason\ntest-no-reason.sh\t\n' > "$R/tests/test-wiring-exempt.tsv"
out="$(herd_test_wiring_lint "$R")"; rc=$?
[ "$rc" -eq 1 ] || fail "(5) empty-reason exempt should be a code error (rc=$rc out=$out)"
printf '%s\n' "$out" | grep -qE 'EXEMPT missing reason: test-no-reason\.sh' \
  || fail "(5) missing-reason violation not loud: $out"
pass
echo "PASS (5) an exempt row with an empty reason is a code error"

# ── 6. phantom exempt row is a CODE error ────────────────────────────────────────────────────────
S="$T/phantom"; seed_tree "$S"
printf 'name\treason\ntest-does-not-exist.sh\twas deleted but exempt left behind\n' \
  > "$S/tests/test-wiring-exempt.tsv"
out="$(herd_test_wiring_lint "$S")"; rc=$?
[ "$rc" -eq 1 ] || fail "(6) phantom exempt should be a code error (rc=$rc out=$out)"
printf '%s\n' "$out" | grep -qE 'EXEMPT phantom: test-does-not-exist\.sh' \
  || fail "(6) phantom violation not loud: $out"
pass
echo "PASS (6) a phantom exempt row (no matching test file) is a code error"

# ── 7. FAIL-SOFT: no herd.bats → skip (exit 2), never a red ──────────────────────────────────────
U="$T/consumer"; mkdir -p "$U/tests"
# Consumer-shaped tree: may have a stray test script, but NO curated suite (no herd.bats).
printf '#!/usr/bin/env bash\nexit 0\n' > "$U/tests/test-local-smoke.sh"
# Call OUTSIDE a command-substitution so HERD_TEST_WIRING_SKIP_REASON persists in this shell
# (same pattern as caps-sync / doc-drift callers in healthcheck.sh).
HERD_TEST_WIRING_SKIP_REASON=""
herd_test_wiring_lint "$U" >/dev/null; rc=$?
[ "$rc" -eq 2 ] || fail "(7) consumer tree without herd.bats should SKIP rc=2 (got $rc reason=$HERD_TEST_WIRING_SKIP_REASON)"
[ -n "${HERD_TEST_WIRING_SKIP_REASON:-}" ] \
  || fail "(7) skip reason should be set in HERD_TEST_WIRING_SKIP_REASON"
printf '%s' "$HERD_TEST_WIRING_SKIP_REASON" | grep -qi 'herd.bats' \
  || fail "(7) skip reason should mention herd.bats, got: $HERD_TEST_WIRING_SKIP_REASON"
pass
echo "PASS (7) fail-soft: no tests/herd.bats → skip (exit 2), never a false red ($HERD_TEST_WIRING_SKIP_REASON)"

echo "ALL PASS ($PASS checks) — test-test-wiring.sh"
