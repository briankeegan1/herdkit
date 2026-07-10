#!/usr/bin/env bash
# test-gate-coverage.sh — hermetic tests for the shared gate-coverage drift guard
# (HERD-292, flipped for HERD-295 dynamic discovery): scripts/herd/gate-coverage-lint.sh checks that
# every tests/test-*.sh is exercised by the merge gate — auto-discovered by the herd.bats test-*.sh
# glob, OR referenced by name in herd.bats (a bespoke @test block), OR on tests/gate-coverage-exempt.tsv.
#
# Proves:
#   (1) The REAL tree is clean: every test-*.sh in the live repo is discovered, referenced, or exempt.
#   (2) DISCOVERY ABSENT + an unreferenced test → guard reds (exit 1) and prints an UNGATED line.
#   (3) EXEMPTING that test (adding it to the exempt file) → clean (exit 0).
#   (4) REFERENCING that test by name in the bats file → clean (exit 0).
#   (5) FAIL-SOFT: no tests/herd.bats in the tree → skip (exit 2), never a red.
#   (6) An empty exempt file is treated as "no exemptions" (not a parse error).
#   (7) EPIPE regression (HERD-297): a name-referenced test in a >64KB herd.bats stays covered.
#   (8) DISCOVERY PRESENT (herd.bats has the test-*.sh glob) → an unreferenced, non-exempt test is
#       AUTO-DISCOVERED and clean (exit 0) — the core HERD-295 behavior: adding a test needs no edit.
#   (9) DISCOVERY PRESENT + exempt still honored: an exempt file stays clean alongside the glob.
#  (10) DISCOVERY REMOVED is caught: the same test that (8) auto-covered reds UNGATED once the glob
#       is gone — proving the guard still fails loudly if the discovery mechanism is deleted.
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

# ── 7. EPIPE regression (HERD-297): a wired test referenced EARLY in a large herd.bats must be ────
#       classified WIRED even under `set -o pipefail`. The pre-fix code piped the bats text into
#       `grep -qF "$base"`; grep's early exit closed the pipe, the producer (printf) took EPIPE, and
#       pipefail turned that wired test into a false UNGATED once herd.bats grew past a pipe buffer
#       (16KB macOS / 64KB Linux). This whole file already runs under `set -o pipefail` (line 15), so
#       it exercises the exact failure shape. Grepping the bats FILE directly removes the pipe.
TP="$T/tree-epipe"; mkdir -p "$TP/tests"
# herd.bats: reference the target test on the FIRST line (early match), then pad well past 64KB so
# the producer is still mid-write when grep exits — reproducing the EPIPE on both pipe-buffer sizes.
{
  printf 'run bash "$REPO/tests/test-early.sh"\n'
  epipe_i=0
  while [ "$epipe_i" -lt 1500 ]; do
    printf '# padding line %04d keeps the bats text large so the pre-fix pipe would EPIPE mid-write\n' "$epipe_i"
    epipe_i=$((epipe_i + 1))
  done
} > "$TP/tests/herd.bats"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$TP/tests/test-early.sh"
[ "$(wc -c < "$TP/tests/herd.bats")" -gt 65536 ] \
  || fail "(7) fixture herd.bats must exceed 64KB to exercise the EPIPE shape"
# Pure function, called directly under the file's active `set -o pipefail`.
out="$(herd_gate_coverage_check "$TP/tests/herd.bats" "$TP/tests")"; rc=$?
[ "$rc" -eq 0 ] \
  || fail "(7) early-referenced test in a >64KB herd.bats must classify clean (exit 0, got $rc) — EPIPE regression: $out"
printf '%s\n' "$out" | grep -q 'UNGATED' \
  && fail "(7) test-early.sh is wired — must NOT be UNGATED (EPIPE misclassification): $out"
printf '%s\n' "$out" | grep -q '^ADVISORY:' || fail "(7) advisory summary line missing"
pass
echo "PASS (7) EPIPE regression: early-referenced test in a >64KB herd.bats stays WIRED under pipefail"

# ── helper: a fixture tree whose herd.bats uses the HERD-295 dynamic-discovery glob ───────────────
make_tree_discovery() {
  # make_tree_discovery <dir> — a herd.bats that GLOBS tests/test-*.sh (dynamic discovery), naming
  # no concrete test file. The literal `test-*.sh` wildcard is what the guard greps for as proof that
  # discovery is present.
  local d="$1"
  mkdir -p "$d/tests"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'source "$BATS_TEST_DIRNAME/discover-tests.bash"\n'
    printf '# HERD-295 dynamic discovery over "$BATS_TEST_DIRNAME"/test-*.sh\n'
  } > "$d/tests/herd.bats"
}

# ── 8. Discovery PRESENT → an unreferenced, non-exempt test is auto-discovered (clean) ───────────
TDsc="$T/tree-discovery"; make_tree_discovery "$TDsc"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$TDsc/tests/test-brandnew.sh"
# No exempt file, NOT named in herd.bats — but the discovery glob covers it.
out="$(herd_gate_coverage_lint "$TDsc")"; rc=$?
[ "$rc" -eq 0 ] || fail "(8) discovery-present: an auto-discovered test must be clean (exit 0, got $rc): $out"
printf '%s\n' "$out" | grep -q 'UNGATED' && fail "(8) no UNGATED lines expected under dynamic discovery (got: $out)"
printf '%s\n' "$out" | grep -q 'discovery-glob-present=1' || fail "(8) advisory should report discovery-glob-present=1 (got: $out)"
printf '%s\n' "$out" | grep -qE 'ADVISORY:.*1 auto-discovered' || fail "(8) advisory should count 1 auto-discovered (got: $out)"
pass
echo "PASS (8) discovery present → an unreferenced, non-exempt test is auto-discovered and clean"

# ── 9. Discovery PRESENT + exempt still honored ──────────────────────────────────────────────────
printf '#!/usr/bin/env bash\necho ok\n' > "$TDsc/tests/test-quarantined.sh"
printf 'test-quarantined.sh\n' > "$TDsc/tests/gate-coverage-exempt.tsv"
out="$(herd_gate_coverage_lint "$TDsc")"; rc=$?
[ "$rc" -eq 0 ] || fail "(9) discovery + exempt must stay clean (exit 0, got $rc): $out"
printf '%s\n' "$out" | grep -q 'UNGATED' && fail "(9) exempt file must not red under discovery (got: $out)"
printf '%s\n' "$out" | grep -qE 'ADVISORY:.*1 exempted' || fail "(9) advisory should count 1 exempted (got: $out)"
pass
echo "PASS (9) discovery present + exempt list still honored (exempt file not double-counted / not red)"

# ── 10. Discovery REMOVED is caught: the same tree without the glob reds UNGATED ─────────────────
TDrm="$T/tree-discovery-removed"; mkdir -p "$TDrm/tests"
# A herd.bats with NO discovery glob and NO reference to the test → the mechanism is gone.
printf '#!/usr/bin/env bats\n@test "structural only" { run true; }\n' > "$TDrm/tests/herd.bats"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$TDrm/tests/test-brandnew.sh"
out="$(herd_gate_coverage_lint "$TDrm")"; rc=$?
[ "$rc" -eq 1 ] || fail "(10) removing the discovery glob must red an unreferenced test (exit 1, got $rc): $out"
printf '%s\n' "$out" | grep -q 'UNGATED test-brandnew.sh' \
  || fail "(10) should print UNGATED for test-brandnew.sh when discovery is gone (got: $out)"
printf '%s\n' "$out" | grep -q 'discovery-glob-present=0' || fail "(10) advisory should report discovery-glob-present=0 (got: $out)"
pass
echo "PASS (10) discovery removed → the guard fails loudly (UNGATED), proving it still catches a deleted mechanism"

echo
echo "ALL PASS ($PASS checks) — gate-coverage drift guard is live, fail-soft, honors dynamic discovery, and catches a removed discovery glob."
