#!/usr/bin/env bash
# test-ci-run-suite.sh — hermetic test of scripts/ci/run-suite.sh, the cross-platform
# CI suite runner. Covers the ONE thing it adds over the healthcheck's plain loop: the
# per-platform env-sensitive ALLOWLIST classification.
#
# Fully hermetic: it points the runner at a TEMP tests dir of fake pass/fail scripts and a
# TEMP allowlist via the runner's env knobs, and forces the direct (non-bats) path. No real
# tests, no bats, no network. Run:  bash tests/test-ci-run-suite.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUNNER="$ROOT/scripts/ci/run-suite.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$RUNNER" ] || fail "missing runner: $RUNNER"

# ── a temp suite: one green, one red, one red-but-env-sensitive ──────────────────
TD="$T/tests"; mkdir -p "$TD"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TD/test-green.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TD/test-red.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TD/test-flaky-env.sh"
chmod +x "$TD"/*.sh

AL="$T/allow.tsv"
cat > "$AL" <<'EOF'
# comment ignored
name	platforms	reason
test-flaky-env.sh	windows	needs Git Bash python3 shim
EOF

run() {  # run(platform) -> sets RC + OUT
  OUT="$(HERD_CI_FORCE_DIRECT=1 HERD_CI_PLATFORM="$1" \
         HERD_CI_TESTS_DIR="$TD" HERD_CI_ALLOWLIST="$AL" \
         bash "$RUNNER" 2>&1)"; RC=$?
}

# (1) ubuntu: the env-sensitive test is NOT allowlisted here → counts as a real failure → rc 1.
run ubuntu
[ "$RC" -eq 1 ] || fail "ubuntu: expected rc 1 (real failures), got $RC"
printf '%s\n' "$OUT" | grep -q "real failures:       2" || fail "ubuntu: expected 2 real failures.  Got:\n$OUT"
printf '%s\n' "$OUT" | grep -q "passed:              1" || fail "ubuntu: expected 1 pass.  Got:\n$OUT"
pass

# (2) windows: test-flaky-env.sh is allowlisted → XFAIL, only test-red.sh is a real failure → rc 1.
run windows
[ "$RC" -eq 1 ] || fail "windows: expected rc 1 (one real failure remains), got $RC"
printf '%s\n' "$OUT" | grep -q "XFAIL (env-sensitive) test-flaky-env.sh" || fail "windows: expected XFAIL line.  Got:\n$OUT"
printf '%s\n' "$OUT" | grep -q "real failures:       1" || fail "windows: expected 1 real failure.  Got:\n$OUT"
pass

# (3) an all-green suite exits 0 on every platform.
rm -f "$TD/test-red.sh" "$TD/test-flaky-env.sh"
run ubuntu
[ "$RC" -eq 0 ] || fail "all-green: expected rc 0, got $RC.  Out:\n$OUT"
printf '%s\n' "$OUT" | grep -q "CI SUITE CLEAN" || fail "all-green: expected CLEAN banner.  Got:\n$OUT"
pass

# (4) `all` in the platforms column allows on any platform.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TD/test-any.sh"; chmod +x "$TD/test-any.sh"
printf 'name\tplatforms\treason\ntest-any.sh\tall\talways env-sensitive\n' > "$AL"
run macos
[ "$RC" -eq 0 ] || fail "all-platform allow: expected rc 0 on macos, got $RC.  Out:\n$OUT"
printf '%s\n' "$OUT" | grep -q "XFAIL (env-sensitive) test-any.sh" || fail "all-platform allow: expected XFAIL.  Got:\n$OUT"
pass

# (5) empty test dir → usage/setup error (rc 2), never a silent green.
ED="$T/empty"; mkdir -p "$ED"
OUT="$(HERD_CI_FORCE_DIRECT=1 HERD_CI_PLATFORM=ubuntu HERD_CI_TESTS_DIR="$ED" HERD_CI_ALLOWLIST="$AL" bash "$RUNNER" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] || fail "empty dir: expected rc 2, got $RC.  Out:\n$OUT"
pass

echo "PASS: test-ci-run-suite ($PASS checks)"
