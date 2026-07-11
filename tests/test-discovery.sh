#!/usr/bin/env bash
# test-discovery.sh — hermetic tests for HERD-295 dynamic test discovery
# (tests/discover-tests.bash), the mechanism tests/herd.bats uses to register one bats test per
# tests/test-*.sh so adding a test no longer edits herd.bats.
#
# Proves:
#   (1) Normal discovery: globs test-*.sh, MINUS exempt, MINUS bespoke, LC_ALL=C sorted, rc 0.
#   (2) Exempt is a WHOLE-LINE match: a '#' comment / header row never accidentally exempts a file.
#   (3) Bespoke list is honored: a hand-written-block file is skipped (not double-run).
#   (4) ZERO-MATCH GLOB FAILS LOUDLY: a dir with no test-*.sh → rc 2, so the caller can refuse to
#       pass an empty suite (a glob typo must never silently pass).
#   (5) An absent/empty exempt file is treated as "no exemptions" (not an error).
#   (6) END-TO-END (only when bats is installed): a herd.bats-style discovery file over an EMPTY dir
#       registers a single LOUD failing test — the empty suite reds, it does not silently pass.
#
# Network-free: temp dirs + fixtures only. Run:  bash tests/test-discovery.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$HERE/discover-tests.bash"

[ -f "$LIB" ] || { echo "FAIL: missing helper: $LIB" >&2; exit 1; }
# shellcheck source=discover-tests.bash
. "$LIB"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# ── 1. Normal discovery: glob − exempt − bespoke, sorted ─────────────────────────────────────────
D="$T/normal"; mkdir -p "$D"
for n in test-charlie test-alpha test-bravo test-delta test-echo; do
  printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$D/$n.sh"
done
printf '# a comment header\ntest-delta.sh\n' > "$D/exempt.tsv"   # exempt delta
out="$(herd_bats_discover "$D" "$D/exempt.tsv" "test-echo.sh")"; rc=$?   # bespoke: echo
[ "$rc" -eq 0 ] || fail "(1) normal discovery should exit 0 (got $rc)"
# Expect alpha, bravo, charlie (delta exempt, echo bespoke), sorted.
expected="$(printf 'test-alpha.sh\ntest-bravo.sh\ntest-charlie.sh')"
[ "$out" = "$expected" ] || fail "(1) discovered set wrong.\n  want: $expected\n  got:  $out"
pass
echo "PASS (1) discovery = glob − exempt − bespoke, LC_ALL=C sorted"

# ── 2. Exempt is a WHOLE-LINE match (a comment substring must not exempt) ─────────────────────────
D2="$T/wholeline"; mkdir -p "$D2"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$D2/test-alpha.sh"
# A comment line that CONTAINS the basename must NOT exempt it (grep -x, whole line).
printf '# keep test-alpha.sh out later maybe\n' > "$D2/exempt.tsv"
out="$(herd_bats_discover "$D2" "$D2/exempt.tsv" "")"; rc=$?
[ "$rc" -eq 0 ] || fail "(2) exit 0 expected (got $rc)"
[ "$out" = "test-alpha.sh" ] || fail "(2) a comment mentioning the file must NOT exempt it (got: '$out')"
pass
echo "PASS (2) exempt match is whole-line — a '#' comment substring never exempts a file"

# ── 3. Bespoke list honored ──────────────────────────────────────────────────────────────────────
D3="$T/bespoke"; mkdir -p "$D3"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$D3/test-alpha.sh"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$D3/test-bespoke-one.sh"
out="$(herd_bats_discover "$D3" "" "test-bespoke-one.sh")"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) exit 0 expected (got $rc)"
[ "$out" = "test-alpha.sh" ] || fail "(3) bespoke file must be skipped by discovery (got: '$out')"
pass
echo "PASS (3) bespoke (hand-written-block) file is skipped, never double-run"

# ── 4. ZERO-MATCH GLOB FAILS LOUDLY (rc 2) ──────────────────────────────────────────────────────
D4="$T/empty"; mkdir -p "$D4"          # no test-*.sh at all
touch "$D4/not-a-test.sh" "$D4/readme.md"
out="$(herd_bats_discover "$D4" "" "")"; rc=$?
[ "$rc" -eq 2 ] || fail "(4) a zero-match glob MUST return rc 2 (loud), got $rc (out: '$out')"
[ -z "$out" ] || fail "(4) zero-match must print nothing (got: '$out')"
pass
echo "PASS (4) zero-match glob → rc 2 (loud) — an empty suite can never silently pass"

# ── 5. Absent / empty exempt file is a no-op ─────────────────────────────────────────────────────
D5="$T/noexempt"; mkdir -p "$D5"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$D5/test-alpha.sh"
out="$(herd_bats_discover "$D5" "$D5/does-not-exist.tsv" "")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "test-alpha.sh" ] || fail "(5) absent exempt file must be treated as empty (rc=$rc, out='$out')"
: > "$D5/empty.tsv"
out="$(herd_bats_discover "$D5" "$D5/empty.tsv" "")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "test-alpha.sh" ] || fail "(5) empty exempt file must exempt nothing (rc=$rc, out='$out')"
pass
echo "PASS (5) absent / empty exempt file → no exemptions, not an error"

# ── 6. END-TO-END loud empty suite under bats (skipped when bats is absent) ──────────────────────
if command -v bats >/dev/null 2>&1; then
  D6="$T/e2e-empty/tests"; mkdir -p "$D6"
  cp "$LIB" "$D6/discover-tests.bash"
  # A minimal herd.bats-shaped discovery file over a dir with NO test-*.sh files.
  cat > "$D6/herd.bats" <<'BATS'
#!/usr/bin/env bats
source "$BATS_TEST_DIRNAME/discover-tests.bash"
_rc=0
_l="$(herd_bats_discover "$BATS_TEST_DIRNAME" "" "")" || _rc=$?
if [ "$_rc" -eq 2 ]; then
  test_zero() { echo "FATAL: zero tests/test-*.sh"; return 1; }
  bats_test_function --description "discovery matched zero tests/test-*.sh (glob typo / empty suite)" -- test_zero
fi
BATS
  # Never use $(bats …): a surviving /dev/tty grandchild keeps the pipe open and hangs
  # inside the gate's own bats run (the healthcheck.project.sh pattern: write to a file).
  # --formatter tap: avoids the pretty formatter subprocess which opens /dev/tty and can
  # hang the outer bats run when this test is itself running inside the gate's bats suite.
  _e2e_out="$T/e2e-bats.out"
  bats --formatter tap "$D6/herd.bats" </dev/null >"$_e2e_out" 2>&1; e2e_rc=$?
  e2e="$(cat "$_e2e_out")"
  [ "$e2e_rc" -ne 0 ] || fail "(6) an empty-suite discovery file must FAIL under bats (rc=$e2e_rc):\n$e2e"
  printf '%s\n' "$e2e" | grep -q 'not ok .* discovery matched zero' \
    || fail "(6) bats should report the loud zero-match test as failing:\n$e2e"
  pass
  echo "PASS (6) end-to-end: an empty suite registers a single LOUD failing bats test"
else
  echo "SKIP (6) bats not installed — end-to-end loud-empty-suite check skipped (helper rc-2 proven in (4))"
fi

echo
echo "ALL PASS ($PASS checks) — HERD-295 dynamic discovery: correct filtering + loud on a zero-match glob."
