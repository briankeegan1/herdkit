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
printf '%s\n' "$OUT" | grep -qE "real failures: +2" || fail "ubuntu: expected 2 real failures.  Got:\n$OUT"
printf '%s\n' "$OUT" | grep -qE "passed: +1" || fail "ubuntu: expected 1 pass.  Got:\n$OUT"
pass

# (2) windows: test-flaky-env.sh is allowlisted → XFAIL, only test-red.sh is a real failure → rc 1.
run windows
[ "$RC" -eq 1 ] || fail "windows: expected rc 1 (one real failure remains), got $RC"
printf '%s\n' "$OUT" | grep -q "XFAIL (env-sensitive) test-flaky-env.sh" || fail "windows: expected XFAIL line.  Got:\n$OUT"
printf '%s\n' "$OUT" | grep -qE "real failures: +1" || fail "windows: expected 1 real failure.  Got:\n$OUT"
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

# ── HERD-436 legibility: a test that supports the shared `--artifacts DIR --keep` convention (the
# sim/chaos family: test-gate-reconciler-chaos-sim.sh, test-merge-queue-sim.sh, test-merge-result-gate-
# sim.sh) must (a) have its failing checkpoint line(s) surfaced even when they scroll off a plain
# tail, and (b) have its scorecard.json survive past its own process into a caller-controlled dir —
# previously the test's own EXIT trap deleted its mktemp ART dir the instant it failed, discarding the
# one artifact that names which assertion actually failed.
TD2="$T/tests2"; mkdir -p "$TD2"
cat > "$TD2/test-artifact-red-sim.sh" <<'EOF'
#!/usr/bin/env bash
ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    *) shift ;;
  esac
done
[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
echo "FAIL checkpoint_one: something specific broke"
for i in $(seq 1 20); do echo "noise line $i (padding past a 6/10-line tail)"; done
echo '{"result":"fail"}' > "$ART/scorecard.json"
exit 1
EOF
chmod +x "$TD2/test-artifact-red-sim.sh"
cat > "$TD2/test-artifact-green-sim.sh" <<'EOF'
#!/usr/bin/env bash
ART=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; shift 2 ;;
    --keep)      shift ;;
    *) shift ;;
  esac
done
[ -n "$ART" ] || exit 1
mkdir -p "$ART"
echo '{"result":"pass"}' > "$ART/scorecard.json"
exit 0
EOF
chmod +x "$TD2/test-artifact-green-sim.sh"

ARTDIR="$T/artroot"
OUT="$(HERD_CI_FORCE_DIRECT=1 HERD_CI_PLATFORM=ubuntu HERD_CI_TESTS_DIR="$TD2" \
       HERD_CI_ARTIFACTS_DIR="$ARTDIR" bash "$RUNNER" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] || fail "artifacts: expected rc 1 (the red sim fails), got $RC.  Out:\n$OUT"
printf '%s\n' "$OUT" | grep -q "FAIL checkpoint_one: something specific broke" \
  || fail "artifacts: expected the failing checkpoint line surfaced (not just a tail).  Got:\n$OUT"
[ -f "$ARTDIR/test-artifact-red-sim.sh/scorecard.json" ] \
  || fail "artifacts: expected scorecard.json to survive under $ARTDIR/test-artifact-red-sim.sh"
[ ! -e "$ARTDIR/test-artifact-green-sim.sh" ] \
  || fail "artifacts: a passing test's artifacts should be pruned, found $ARTDIR/test-artifact-green-sim.sh"
pass

echo "PASS: test-ci-run-suite ($PASS checks)"
