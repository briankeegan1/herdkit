#!/usr/bin/env bash
# test-suite-shard.sh — hermetic tests for the HERD-463 shard library
# (scripts/herd/suite-shard.sh): the shared curated-test-selection + stable filename-hash
# shard-assignment logic behind the CI matrix (scripts/ci/run-suite.sh, HERD_CI_SHARD_INDEX /
# HERD_CI_SHARD_COUNT). A dropped or double-counted test in a sharded CI matrix would read as GREEN
# (a shard that silently drops a test just finishes faster) — this is the mutation-prove membership
# check the tracker item explicitly asked for: "assert [membership] in the runner so a dropped shard
# can never read as green."
#
# Proves:
#   (1) MEMBERSHIP (real tree): for shard_count in {1,3,4,7}, the UNION of shards 1..shard_count
#       reconstructs herd_suite_curated_tests EXACTLY — no drop, no duplicate — against the REAL
#       tests/ dir this file lives in (so a future test addition/removal stays covered for free).
#   (2) shard_count=1 → the single shard IS the full curated set (byte-identical to unsharded).
#   (3) DETERMINISM: the same (name, count) always yields the same shard — across repeated calls
#       and across a fresh subshell (no hidden process-local state).
#   (4) STABILITY UNDER INSERTION: hash-based sharding (unlike an index/chunk partition) means
#       adding ONE new test file does not reshuffle any EXISTING test's shard assignment — proves
#       the "stable" half of "stable filename-hash → shard".
#   (5) EXEMPT FILTERING composes with sharding: an exempted name never appears in ANY shard, at
#       any shard_count.
#   (6) An out-of-range shard_index (> shard_count) matches nothing (never silently wraps).
#   (7) Non-numeric / garbage shard_count and shard_index fall back safely (count→1, index→1) —
#       a typo'd HERD_CI_SHARD_COUNT can never silently drop the whole suite.
#   (8) herd_suite_curated_tests still honors gate-coverage-exempt.tsv on a fixture tree (the same
#       selection scripts/ci/run-suite.sh has always used), so the shard library and the CI runner
#       can never disagree about what "curated" means.
#
# Run:  bash tests/test-suite-shard.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/scripts/herd/suite-shard.sh"

[ -f "$LIB" ] || { echo "FAIL: missing library: $LIB" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# ── 1. MEMBERSHIP: union of all shards == the full curated set, for several shard counts ──────────
curated="$(herd_suite_curated_tests "$ROOT/tests")"
curated_n="$(printf '%s' "$curated" | grep -c .)"
[ "$curated_n" -gt 0 ] || fail "(1) curated set is empty — glob/exempt-file wiring is broken"
for n in 1 3 4 7; do
  union="$(
    i=1
    while [ "$i" -le "$n" ]; do
      herd_suite_tests_for_shard "$ROOT/tests" "$i" "$n"
      i=$((i + 1))
    done | sort
  )"
  union_count="$(printf '%s\n' "$union" | grep -c .)"
  [ "$union_count" -eq "$curated_n" ] \
    || fail "(1) shard_count=$n: union has $union_count tests, curated has $curated_n (a drop or a duplicate)"
  diff <(printf '%s\n' "$curated") <(printf '%s\n' "$union") >/dev/null \
    || fail "(1) shard_count=$n: union of all shards does not exactly reconstruct the curated set"
  pass
done
echo "PASS (1) membership: union of shards {1,3,4,7} reconstructs the curated set exactly ($curated_n tests) — no drop, no duplicate"

# ── 2. shard_count=1 → the single shard is the full curated set ──────────────────────────────────
one="$(herd_suite_tests_for_shard "$ROOT/tests" 1 1)"
diff <(printf '%s\n' "$curated") <(printf '%s\n' "$one") >/dev/null \
  || fail "(2) shard 1 of 1 must equal the full curated set (byte-identical to unsharded)"
pass
echo "PASS (2) shard_count=1 is byte-identical to the unsharded curated selection"

# ── 3. DETERMINISM: same (name, count) → same shard, repeatedly and in a fresh subshell ──────────
for nm in "test-alpha.sh" "test-zzz-omega.sh" "a name with spaces" ""; do
  s1="$(herd_suite_shard_of "$nm" 4)"
  s2="$(herd_suite_shard_of "$nm" 4)"
  s3="$(bash -c '. "$1"; herd_suite_shard_of "$2" 4' _ "$LIB" "$nm")"
  [ "$s1" = "$s2" ] || fail "(3) repeated calls for '$nm' disagree: $s1 vs $s2"
  [ "$s1" = "$s3" ] || fail "(3) a fresh subshell disagrees with the parent process for '$nm': $s1 vs $s3"
  [ "$s1" -ge 1 ] 2>/dev/null && [ "$s1" -le 4 ] 2>/dev/null \
    || fail "(3) shard '$s1' for '$nm' is out of [1,4] range"
done
pass
echo "PASS (3) deterministic hash: identical (name, count) always yields the same shard, across processes"

# ── 4. STABILITY UNDER INSERTION: adding one test never reshuffles an EXISTING test's shard ───────
mkdir -p "$T/stab/tests"
i=0
while [ "$i" -lt 12 ]; do
  printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$T/stab/tests/test-fixture-$i.sh"
  i=$((i + 1))
done
before="$(herd_suite_curated_tests "$T/stab/tests")"
declare_before=""
while IFS= read -r nm; do
  [ -n "$nm" ] || continue
  declare_before="${declare_before}${nm}=$(herd_suite_shard_of "$nm" 4)"$'\n'
done <<< "$before"
# Insert ONE new test (a name that sorts in the middle, so an index/chunk partition — the naive
# alternative to hashing — would visibly reshuffle neighbors).
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$T/stab/tests/test-fixture-6a-inserted.sh"
after_shift=0
while IFS= read -r nm; do
  [ -n "$nm" ] || continue
  new_shard="$(herd_suite_shard_of "$nm" 4)"
  old_shard="$(grep "^${nm}=" <<< "$declare_before" | cut -d= -f2)"
  [ "$new_shard" = "$old_shard" ] || after_shift=$((after_shift + 1))
done <<< "$before"
[ "$after_shift" -eq 0 ] \
  || fail "(4) inserting one new test reshuffled $after_shift existing tests' shard assignment — not stable"
pass
echo "PASS (4) stability: inserting a new test never changes an EXISTING test's shard (hash, not index/chunk)"

# ── 5. EXEMPT FILTERING composes with sharding: an exempted name is in no shard at any count ──────
mkdir -p "$T/exempt/tests"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$T/exempt/tests/test-kept.sh"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$T/exempt/tests/test-quarantined.sh"
printf 'test-quarantined.sh\n' > "$T/exempt/tests/gate-coverage-exempt.tsv"
for n in 1 2 5; do
  found=0
  i=1
  while [ "$i" -le "$n" ]; do
    shard_out="$(herd_suite_tests_for_shard "$T/exempt/tests" "$i" "$n")"
    grep -qx 'test-quarantined.sh' <<< "$shard_out" && found=1
    i=$((i + 1))
  done
  [ "$found" -eq 0 ] || fail "(5) shard_count=$n: exempted test-quarantined.sh leaked into a shard"
done
pass
echo "PASS (5) an exempted test is absent from every shard, at every shard_count tried"

# ── 6. Out-of-range shard_index matches nothing (never silently wraps to a real shard) ────────────
oob="$(herd_suite_tests_for_shard "$T/exempt/tests" 99 4)"
[ -z "$oob" ] || fail "(6) shard_index=99 of 4 should match nothing (got: $oob)"
pass
echo "PASS (6) an out-of-range shard_index selects nothing rather than silently wrapping"

# ── 7. Garbage shard_count / shard_index fall back safely (never drop the whole suite) ────────────
garbage_count="$(herd_suite_tests_for_shard "$T/exempt/tests" 1 "not-a-number")"
grep -qx 'test-kept.sh' <<< "$garbage_count" \
  || fail "(7) a non-numeric shard_count should fall back to 1 (whole set), got: $garbage_count"
garbage_idx="$(herd_suite_tests_for_shard "$T/exempt/tests" "not-a-number" 1)"
grep -qx 'test-kept.sh' <<< "$garbage_idx" \
  || fail "(7) a non-numeric shard_index should fall back to 1, got: $garbage_idx"
pass
echo "PASS (7) non-numeric shard_count/shard_index fall back to 1 rather than silently emptying a shard"

# ── 8. herd_suite_curated_tests on a fixture honors the exempt file (matches run-suite.sh) ────────
sel="$(herd_suite_curated_tests "$T/exempt/tests")"
grep -qx 'test-kept.sh' <<< "$sel" || fail "(8) test-kept.sh should be curated"
grep -qx 'test-quarantined.sh' <<< "$sel" && fail "(8) test-quarantined.sh must be excluded (on the exempt list)"
pass
echo "PASS (8) curated selection excludes exempt-listed tests, same convention as scripts/ci/run-suite.sh"

echo
echo "ALL PASS ($PASS checks) — HERD-463 shard library: membership is exact, deterministic, stable under insertion, and exempt-aware; a dropped/duplicated shard can never read as green."
