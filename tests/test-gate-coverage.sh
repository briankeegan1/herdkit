#!/usr/bin/env bash
# test-gate-coverage.sh — hermetic tests for the shared gate-coverage drift guard (HERD-292):
# scripts/herd/gate-coverage-lint.sh checks that every tests/test-*.sh is either wired into
# tests/herd.bats or listed in tests/gate-coverage-exempt.tsv.
#
# Proves:
#   (1) The REAL tree is clean: every test-*.sh in the live repo is wired or exempted.
#   (2) An UNWIRED test → guard reds (exit 1) and prints an UNGATED line.
#   (3) EXEMPTING the unwired test (adding it to the exempt file) → clean (exit 0).
#   (4) WIRING the unwired test (adding it to the bats file) → clean (exit 0).
#   (5) FAIL-SOFT: no tests/herd.bats in the tree → skip (exit 2), never a red.
#   (6) An empty exempt file is treated as "no exemptions" (not a parse error).
#
# Network-free: temp dirs + fixtures only. Run:  bash tests/test-gate-coverage.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/scripts/herd/gate-coverage-lint.sh"

[ -f "$LINT" ] || { echo "FAIL: missing lint: $LINT" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LINT"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# ── 1. Real tree is clean ─────────────────────────────────────────────────────────────────────────
real_out="$(herd_gate_coverage_lint "$ROOT")"; real_rc=$?
if [ "$real_rc" -ne 0 ]; then
  printf '%s\n' "$real_out" | grep '^UNGATED' >&2
  fail "(1) real tree has ungated tests — add them to tests/gate-coverage-exempt.tsv or wire them into tests/herd.bats"
fi
printf '%s\n' "$real_out" | grep -q '^UNGATED' && fail "(1) UNGATED lines present despite clean exit"
printf '%s\n' "$real_out" | grep -q '^ADVISORY:' || fail "(1) advisory summary line missing"
pass
echo "PASS (1) real tree: every tests/test-*.sh is wired in herd.bats or on the exempt list"

# ── helpers for fixture-based tests ──────────────────────────────────────────────────────────────
make_tree() {
  # make_tree <dir> — create a minimal fixture: a tests/ dir with a herd.bats + a wired test.
  local d="$1"
  mkdir -p "$d/tests"
  printf '#!/usr/bin/env bats\n@test "wired" { run echo ok; }\n' > "$d/tests/herd.bats"
  # A test that IS wired (referenced in herd.bats).
  printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$d/tests/test-wired.sh"
  printf 'run bash "$REPO/tests/test-wired.sh"\n' >> "$d/tests/herd.bats"
}

# ── 2. Unwired test → red ─────────────────────────────────────────────────────────────────────────
TR="$T/tree-unwired"; make_tree "$TR"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$TR/tests/test-newfeature.sh"
# No exempt file, no bats reference → must red
out="$(herd_gate_coverage_lint "$TR")"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) an unwired test-newfeature.sh must cause exit 1 (got $rc): $out"
printf '%s\n' "$out" | grep -q 'UNGATED test-newfeature.sh' \
  || fail "(2) should print UNGATED line for test-newfeature.sh (got: $out)"
pass
echo "PASS (2) unwired test → guard reds and emits UNGATED line"

# ── 3. Exempting the unwired test → clean ────────────────────────────────────────────────────────
printf 'test-newfeature.sh\n' > "$TR/tests/gate-coverage-exempt.tsv"
out="$(herd_gate_coverage_lint "$TR")"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) exempted test must be clean (exit 0, got $rc): $out"
printf '%s\n' "$out" | grep -q 'UNGATED' && fail "(3) no UNGATED lines expected after exemption (got: $out)"
pass
echo "PASS (3) exempted test → guard is clean"

# ── 4. Wiring the test (in bats) → clean ─────────────────────────────────────────────────────────
TW="$T/tree-wired"; make_tree "$TW"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$TW/tests/test-newfeature.sh"
printf 'run bash "$REPO/tests/test-newfeature.sh"\n' >> "$TW/tests/herd.bats"
# No exempt file needed — it is referenced in herd.bats
out="$(herd_gate_coverage_lint "$TW")"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) wired test must be clean (exit 0, got $rc): $out"
printf '%s\n' "$out" | grep -q 'UNGATED' && fail "(4) no UNGATED lines expected for wired test (got: $out)"
pass
echo "PASS (4) wired test → guard is clean"

# ── 5. No herd.bats → skip (never a red) ─────────────────────────────────────────────────────────
TN="$T/tree-nobats"
mkdir -p "$TN/tests"
printf '#!/usr/bin/env bash\necho ok\n' > "$TN/tests/test-something.sh"
HERD_GATE_COVERAGE_SKIP_REASON=""
herd_gate_coverage_lint "$TN" >/dev/null 2>&1; skip_rc=$?
[ "$skip_rc" -eq 2 ] || fail "(5) no herd.bats must skip (exit 2, got $skip_rc)"
[ -n "${HERD_GATE_COVERAGE_SKIP_REASON:-}" ] \
  || fail "(5) HERD_GATE_COVERAGE_SKIP_REASON must be set on skip"
pass
echo "PASS (5) no tests/herd.bats → skip (exit 2), never a red, reason set"

# ── 6. Empty exempt file → no exemptions, unwired still reds ─────────────────────────────────────
TE="$T/tree-empty-exempt"; make_tree "$TE"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$TE/tests/test-orphan.sh"
printf '' > "$TE/tests/gate-coverage-exempt.tsv"    # empty file
out="$(herd_gate_coverage_lint "$TE")"; rc=$?
[ "$rc" -eq 1 ] || fail "(6) empty exempt file should not exempt anything (exit 1, got $rc): $out"
printf '%s\n' "$out" | grep -q 'UNGATED test-orphan.sh' \
  || fail "(6) test-orphan.sh should still be UNGATED with an empty exempt file (got: $out)"
pass
echo "PASS (6) empty exempt file: no exemptions, unwired test still reds"

echo
echo "ALL PASS ($PASS checks) — gate-coverage drift guard is live, fail-soft, and catches ungated tests."
