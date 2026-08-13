#!/usr/bin/env bash
# test-suite-scope.sh — MUTATION-PROVE tests for DIFF-SCOPED suite selection (HERD-532), the
# selection half of scripts/herd/suite-shard.sh (herd_suite_scope_mode / herd_suite_tests_for_diff)
# and its wiring into bats discovery (tests/discover-tests.bash).
#
# suite-deps: scripts/herd/suite-shard.sh tests/discover-tests.bash .herd/healthcheck.project.sh tests/scope-core.tsv
#
# WHY THIS SHAPE. A scoped suite that silently DROPS a test reads as GREEN — it just finishes faster.
# That is the same defect class tests/test-suite-shard.sh exists to make impossible for sharding, so
# this proof is built the same way: not "does it look right on one example", but "does the selection
# still contain everything the rules map, for the WHOLE real tree, and does everything it cannot
# prove fall back to the entire curated set".
#
#   (1)  MODE: default full (ship-dormant); only an exact case-insensitive "diff" reads diff; a typo,
#        an empty value and an unset key all read FULL — a scope typo can never narrow the gate.
#   (2)  MUTATION-PROVE (real tree): for EVERY curated test that the pairing convention maps from a
#        real scripts/herd/<name>.sh, a diff touching that script SELECTS its paired test. This is
#        the "never drops a test the pairing maps" assertion, over the whole tree rather than a
#        sample, so a future pairing regression cannot hide behind an unlucky example.
#   (3)  A single scripts/herd/foo.sh diff selects EXACTLY its paired test plus the always-run core —
#        nothing else. (Narrowness is the point; without this the selection could pass (2) by simply
#        returning everything.)
#   (4)  ALWAYS-RUN CORE: present in every scoped selection, AND every core name resolves in the real
#        curated set — so a rename/retirement is caught here rather than silently shrinking the core.
#   (4b) HERD-585: the committed tests/scope-core.tsv contains an INDEPENDENTLY hardcoded required
#        set of cross-cutting guards (config-manifest, caps-sync, gate-coverage, journal-emission,
#        pipe-safety, git-scope, doc-drift, lever-reachability) — hardcoded HERE, not read back from
#        the file under test, so an edit that drops one of these rows reds this proof instead of
#        silently shrinking the core (the PR #708 escape shape: a paired-test-only selection let a
#        ghost config key merge because test-config-manifest.sh never ran).
#   (4c) HERD-585 MUTATION-PROVE: dropping a row from a COPY of tests/scope-core.tsv actually drops
#        that guard from a live scoped selection — proving the union really reads the committed file
#        rather than a value that merely happens to agree with it right now.
#   (5)  FAIL-CLOSED, wide-blast: EACH documented wide-blast path selects the curated set EXACTLY.
#   (6)  FAIL-CLOSED, unmappable: a path no rule maps (a nested backend, a template, a Python module)
#        selects the curated set EXACTLY — and it does so even when it is mixed in with a perfectly
#        mappable path, so one unprovable file in a diff re-arms the whole suite.
#   (6b) HERD-733 DOCS MAPPING: README.md / docs/** / any other *.md (any depth, outside tests/)
#        select the enumerated doc-drift/caps-sync/conformance lint tests + the always-run core — NOT
#        the full curated set (the PR #800 regression this ships to fix: a docs-only diff used to fail
#        closed to the whole ~350-test suite). A test that asserts on one specific doc's real content
#        (test-driver-abstraction.sh, test-map.sh) instead declares its own `# suite-deps:` header, so
#        it is unioned in on top of the enumerated lints rather than being covered by them.
#   (6c) HERD-733 MIXED: a docs path beside a mapped code path selects the UNION — doc-lint + core +
#        the paired test — never a fail-closed full run.
#   (6d) HERD-733 DOC-CONTENT COVERAGE: a curated test that asserts on one SPECIFIC doc's real
#        content (test-driver-abstraction.sh on docs/driver-abstraction.md, test-map.sh on
#        docs/control-room-map.md) is not one of the enumerated doc-lint tests, so it must declare its
#        own `# suite-deps:` header — a diff to the doc it asserts on still selects it.
#   (7)  NO CHANGED PATHS AT ALL → the curated set (the same thorough-side default healthcheck.sh
#        uses when it cannot tell what changed).
#   (8)  A changed tests/test-<name>.sh selects ITSELF.
#   (9)  `# suite-deps:` headers: an exact path token and a GLOB token both select the declaring
#        test; a non-matching path does not; and a dep token is never glob-expanded against cwd.
#   (10) SUBSET + SHAPE: a scoped selection is always a subset of the curated set (it can never
#        invent a name), sorted-unique.
#   (11) DISCOVERY WIRING: tests/discover-tests.bash honors HERD_SUITE_SCOPE_TESTS as an ALLOW-LIST
#        that INTERSECTS with (never widens) the exempt/bespoke rules, and is byte-identical to the
#        unscoped discovery when the variable is unset.
#   (12) WRAPPER DORMANCY: .herd/healthcheck.project.sh only sets the allow-list under
#        HEALTH_SUITE_SCOPE=diff — the default leaves discovery untouched.
#
# Fully hermetic: fixture dirs under a temp root plus READ-ONLY use of the repo's own tests/ tree.
# NO herdr, gh, network or model. Run:  bash tests/test-suite-scope.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/scripts/herd/suite-shard.sh"
DISC="$ROOT/tests/discover-tests.bash"
WRAPPER="$ROOT/.herd/healthcheck.project.sh"
CORE_TSV="$ROOT/tests/scope-core.tsv"

for f in "$LIB" "$DISC" "$CORE_TSV"; do
  [ -f "$f" ] || { echo "FAIL: missing required file: $f" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); echo "PASS $1"; }

# shellcheck source=/dev/null
. "$LIB"

CURATED="$(herd_suite_curated_tests "$ROOT/tests")"
CURATED_N="$(printf '%s\n' "$CURATED" | grep -c .)"
[ "$CURATED_N" -gt 0 ] || fail "curated set is empty — the glob/exempt wiring is broken"

has(){ grep -qxF -- "$2" <<< "$1"; }

# ── (1) MODE: default full; only an exact "diff" narrows ───────────────────────────────────────────
unset HEALTH_SUITE_SCOPE
[ "$(herd_suite_scope_mode)" = "full" ] || fail "(1) HEALTH_SUITE_SCOPE must default to full (ship-dormant)"
for v in diff DIFF Diff; do
  [ "$(HEALTH_SUITE_SCOPE="$v" herd_suite_scope_mode)" = "diff" ] || fail "(1) '$v' must read diff"
done
for v in "" full FULL scoped partial yes 1 on; do
  [ "$(HEALTH_SUITE_SCOPE="$v" herd_suite_scope_mode)" = "full" ] \
    || fail "(1) '$v' must read FULL (a typo can never narrow the authoritative gate)"
done
ok "(1) scope mode: default full; only an exact case-insensitive 'diff' narrows, every other value reads full"

# ── (2) MUTATION-PROVE: the pairing convention never drops a test, across the WHOLE real tree ──────
paired=0
while IFS= read -r script; do
  [ -n "$script" ] || continue
  base="${script##*/}"
  want="test-$base"
  [ -f "$ROOT/tests/$want" ] || continue        # no paired test → rule (1) does not apply
  has "$CURATED" "$want" || continue            # exempt/retired → not part of the gate set anyway
  # A wide-blast script is DELIBERATELY not narrowed — it is covered by check (5) instead.
  wide=0
  for w in $HERD_SUITE_WIDE_BLAST; do [ "scripts/herd/$base" = "$w" ] && wide=1; done
  [ "$wide" -eq 1 ] && continue
  sel="$(herd_suite_tests_for_diff "$ROOT/tests" "scripts/herd/$base")"
  has "$sel" "$want" \
    || fail "(2) a diff to scripts/herd/$base did NOT select its paired $want — the selection drops a mapped test"
  paired=$((paired + 1))
done < <(find "$ROOT/scripts/herd" -maxdepth 1 -name '*.sh' 2>/dev/null | sort)
[ "$paired" -ge 10 ] || fail "(2) only $paired paired scripts were exercised — the scan is not biting"
ok "(2) mutation-prove: every one of $paired name-paired scripts/herd/*.sh selects its paired test"

# ── (3) NARROWNESS: one script diff = its paired test + the core, and nothing else ─────────────────
# journal.sh is name-paired (tests/test-journal.sh), is not wide-blast, and declares no exotic deps.
SEL1="$(herd_suite_tests_for_diff "$ROOT/tests" scripts/herd/journal.sh)"
has "$SEL1" "test-journal.sh" || fail "(3) the paired test-journal.sh must be selected"
CORE="$(herd_suite_core_tests "$ROOT/tests")"
core_present=""
for c in $CORE; do has "$CURATED" "$c" && core_present="${core_present}${c}"$'\n'; done
expected="$(printf '%s\ntest-journal.sh\n' "$core_present" | sed '/^$/d' | LC_ALL=C sort -u)"
[ "$SEL1" = "$expected" ] || fail "(3) a single-script diff must select EXACTLY its pair + the core.
--- got ---
$SEL1
--- want ---
$expected"
sel1_n="$(printf '%s\n' "$SEL1" | grep -c .)"
[ "$sel1_n" -lt "$CURATED_N" ] || fail "(3) a scoped selection ($sel1_n) must be smaller than the curated set ($CURATED_N)"
ok "(3) a single scripts/herd/foo.sh diff selects exactly its paired test + the core ($sel1_n of $CURATED_N)"

# ── (4) ALWAYS-RUN CORE: in every scoped selection, and every core name really exists ──────────────
missing=""
for c in $CORE; do
  has "$CURATED" "$c" || missing="${missing}${c} "
done
[ -z "$missing" ] \
  || fail "(4) core test(s) absent from the curated set (renamed/retired/exempted?): $missing
Fix tests/scope-core.tsv — a stale core name silently shrinks the always-run set that every scoped
run depends on."
for c in $CORE; do
  has "$SEL1" "$c" || fail "(4) core test $c missing from a scoped selection"
done
ok "(4) every always-run core test resolves in the real tree and appears in every scoped selection"

# ── (4b) HERD-585: the committed core file must carry this REQUIRED set, hardcoded HERE rather than
# read back from tests/scope-core.tsv — so an edit that drops one of these rows reds this proof
# instead of silently shrinking the core (the PR #708 escape: a paired-test-only selection let a
# ghost config key merge because test-config-manifest.sh never ran).
REQUIRED_CORE="test-config-manifest.sh test-caps-sync-light.sh test-gate-coverage.sh test-journal-emission-lint.sh test-pipe-safety.sh test-git-scope-lint.sh test-doc-drift.sh test-lever-reachability-lint.sh"
req_missing=""
for c in $REQUIRED_CORE; do
  grep -qxF -- "$c" "$CORE_TSV" || req_missing="${req_missing}${c} "
done
[ -z "$req_missing" ] \
  || fail "(4b) tests/scope-core.tsv is missing required cross-cutting guard(s): $req_missing
These are the guards HERD-585 exists to protect (the PR #708 ghost-key escape shape); restore the
row(s) in tests/scope-core.tsv."
ok "(4b) tests/scope-core.tsv carries every guard the HERD-585 required set names"

# ── (4c) HERD-585 MUTATION-PROVE: dropping a row from a COPY of the committed core file actually
# drops that guard from a live scoped selection — proving the union really reads the file rather than
# a value that merely happens to agree with it right now.
MUT="$T/mut/tests"; mkdir -p "$MUT"
cp "$ROOT"/tests/test-*.sh "$MUT"/ 2>/dev/null
[ -f "$ROOT/tests/gate-coverage-exempt.tsv" ] && cp "$ROOT/tests/gate-coverage-exempt.tsv" "$MUT"/
DROP="test-config-manifest.sh"
grep -Fxv "$DROP" "$CORE_TSV" > "$MUT/scope-core.tsv"
unset HERD_SUITE_CORE_TESTS
MUT_SEL="$(herd_suite_tests_for_diff "$MUT" scripts/herd/journal.sh)"
! has "$MUT_SEL" "$DROP" \
  || fail "(4c) removing $DROP from a copy of tests/scope-core.tsv did not drop it from the selection — the core union is not actually reading the file"
cp "$CORE_TSV" "$MUT/scope-core.tsv"
INTACT_SEL="$(herd_suite_tests_for_diff "$MUT" scripts/herd/journal.sh)"
has "$INTACT_SEL" "$DROP" \
  || fail "(4c) restoring $DROP to the fixture core file did not re-select it — sanity check on the fixture itself failed"
ok "(4c) dropping a row from the committed core file drops that guard from a live scoped selection"

# ── (5) FAIL-CLOSED: each wide-blast path selects the curated set EXACTLY ──────────────────────────
for w in $HERD_SUITE_WIDE_BLAST; do
  got="$(herd_suite_tests_for_diff "$ROOT/tests" "$w")"
  [ "$got" = "$CURATED" ] || fail "(5) wide-blast path '$w' did not select the FULL curated set"
done
ok "(5) every documented wide-blast path selects the entire curated set"

# ── (6) FAIL-CLOSED: an unmappable path selects everything — even alongside a mappable one ─────────
# NOTE: README.md / docs/*.md are NOT unmappable any more — rule (2) DOCS MAPPING (HERD-733) below
# claims them; this list is deliberately the paths that stay outside every rule.
for p in templates/postures.tsv pysrc/herd/live_runtime.py \
         scripts/herd/backends/github.sh scripts/ci/run-suite.sh .github/workflows/ci.yml; do
  got="$(herd_suite_tests_for_diff "$ROOT/tests" "$p")"
  [ "$got" = "$CURATED" ] || fail "(6) unmappable path '$p' must select the FULL curated set"
done
mixed="$(herd_suite_tests_for_diff "$ROOT/tests" scripts/herd/journal.sh pysrc/herd/live_runtime.py)"
[ "$mixed" = "$CURATED" ] \
  || fail "(6) ONE unmappable path in a diff must re-arm the whole suite, even beside a mapped path"
ok "(6) an unmappable path selects everything, and re-arms the whole suite when mixed with a mapped one"

# ── (6b) DOCS MAPPING (HERD-733): README.md / docs/** / any other *.md (any depth) select the doc-drift/
# caps-sync/conformance lint tests + the always-run core — NOT the full curated set. This is the fix
# for the PR #800 regression: a docs-only PR ran the full ~350-test suite because README.md/docs/*.md
# paths matched no PAIRING/DECLARED-DEPS rule and fell through to FAIL-CLOSED.
DOCS_LINT="${HERD_SUITE_DOCS_LINT_TESTS:-test-doc-drift.sh test-caps-sync-light.sh test-conformance.sh}"
docs_expected_raw=""
for c in $DOCS_LINT $CORE; do
  has "$CURATED" "$c" && docs_expected_raw="${docs_expected_raw}${c}"$'\n'
done
docs_expected="$(printf '%s\n' "$docs_expected_raw" | sed '/^$/d' | LC_ALL=C sort -u)"
for p in README.md docs/codemap.md docs/spikes/work-unit-abstraction.md AGENTS.md; do
  got="$(herd_suite_tests_for_diff "$ROOT/tests" "$p")"
  [ "$got" = "$docs_expected" ] || fail "(6b) docs path '$p' must select exactly the doc-lint tests + core.
--- got ---
$got
--- want ---
$docs_expected"
  [ "$got" != "$CURATED" ] \
    || fail "(6b) docs path '$p' must NOT fail closed to the entire curated set (the HERD-733 regression)"
done
ok "(6b) a docs-only diff (README.md / docs/**/*.md / any other *.md at any depth) selects exactly the doc-lint tests + core, never the full suite"

# ── (6c) MIXED docs + a mapped code path → UNION, never fail-closed ────────────────────────────────
mixed_docs="$(herd_suite_tests_for_diff "$ROOT/tests" scripts/herd/journal.sh README.md)"
mixed_expected="$(printf '%s\ntest-journal.sh\n' "$docs_expected" | sed '/^$/d' | LC_ALL=C sort -u)"
[ "$mixed_docs" = "$mixed_expected" ] || fail "(6c) a docs path mixed with a mapped code path must UNION.
--- got ---
$mixed_docs
--- want ---
$mixed_expected"
[ "$mixed_docs" != "$CURATED" ] \
  || fail "(6c) a mixed docs+code diff must not fail closed to the entire curated set"
ok "(6c) a docs path mixed with a mapped code path selects the UNION (doc-lint + core + the paired test), not the full suite"

# ── (6d) DOC-CONTENT COVERAGE (HERD-733 review fix): a curated test that asserts on one SPECIFIC
# doc's real content must NOT be dropped by the docs-mapping narrowing. test-driver-abstraction.sh
# greps the real docs/driver-abstraction.md and test-map.sh greps the real docs/control-room-map.md;
# neither is one of the three enumerated doc-lint tests nor in the always-run core, so each declares
# its own `# suite-deps:` header (rule (3)) — proving the union actually restores them, not just that
# the header exists in the source.
for pair in "docs/driver-abstraction.md:test-driver-abstraction.sh" "docs/control-room-map.md:test-map.sh"; do
  doc="${pair%%:*}"; want_test="${pair##*:}"
  has "$CURATED" "$want_test" || fail "(6d) fixture assumption broken: $want_test is not in the curated set"
  got="$(herd_suite_tests_for_diff "$ROOT/tests" "$doc")"
  has "$got" "$want_test" \
    || fail "(6d) a diff to $doc did NOT select $want_test — a docs-scoped diff would let its real-content assertions silently stop running.
--- got ---
$got"
  [ "$got" != "$CURATED" ] \
    || fail "(6d) $doc must not fail closed to the entire curated set — it is docs-mapped + suite-deps-covered, not unmappable"
done
ok "(6d) a diff to a doc a curated test asserts on by real content still selects that test, via its own suite-deps header"

# ── (7) no changed paths at all → the curated set ──────────────────────────────────────────────────
[ "$(herd_suite_tests_for_diff "$ROOT/tests")" = "$CURATED" ] \
  || fail "(7) an empty changed-path list must select the FULL curated set"
ok "(7) an empty changed-path list falls back to the entire curated set"

# ── (8) a changed test selects itself ──────────────────────────────────────────────────────────────
SELF="$(herd_suite_tests_for_diff "$ROOT/tests" tests/test-journal.sh)"
has "$SELF" "test-journal.sh" || fail "(8) a changed test must select itself"
[ "$SELF" != "$CURATED" ] || fail "(8) a changed test must NOT fail closed to the whole suite"
ok "(8) a changed tests/test-<name>.sh selects itself"

# ── (9) `# suite-deps:` headers — exact tokens, glob tokens, and no cwd glob expansion ─────────────
FIX="$T/deps/tests"; mkdir -p "$FIX"
printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$FIX/test-plain.sh"
printf '#!/usr/bin/env bash\n# suite-deps: templates/models.tsv scripts/herd/backends/*.sh\necho "ALL PASS"\n' \
  > "$FIX/test-declared.sh"
printf '#!/usr/bin/env bash\n# suite-deps: templates/models.tsv\n' > "$FIX/test-second.sh"
# A decoy file in the FIXTURE dir named like a glob expansion target: if a dep token were ever
# glob-expanded against cwd instead of matched as a pattern, this is what would silently appear.
: > "$FIX/backends-decoy.sh"
# shellcheck disable=SC2034  # read by herd_suite_core_tests via ${HERD_SUITE_CORE_TESTS+set}, not by name here
HERD_SUITE_CORE_TESTS=""                                    # isolate the dep rule from the core union
d_exact="$(herd_suite_tests_for_diff "$FIX" templates/models.tsv)"
[ "$d_exact" = "$(printf 'test-declared.sh\ntest-second.sh')" ] \
  || fail "(9) an exact dep token must select every declaring test and nothing else, got: $d_exact"
d_glob="$(cd "$FIX" && herd_suite_tests_for_diff "$FIX" scripts/herd/backends/github.sh)"
[ "$d_glob" = "test-declared.sh" ] \
  || fail "(9) a GLOB dep token must match a changed path under it, got: $d_glob"
d_none="$(herd_suite_tests_for_diff "$FIX" templates/other.tsv)"
[ "$d_none" = "$(herd_suite_curated_tests "$FIX")" ] \
  || fail "(9) a path no dep declares is unmappable and must fail closed to the fixture's full set"
unset HERD_SUITE_CORE_TESTS                                 # restore file-backed core for later checks
ok "(9) suite-deps headers select their declaring tests by exact path and by glob, and never glob-expand cwd"

# ── (10) SUBSET + SHAPE: a selection never invents a name and is sorted-unique ─────────────────────
for probe in scripts/herd/journal.sh tests/test-journal.sh scripts/herd/theme.sh; do
  s="$(herd_suite_tests_for_diff "$ROOT/tests" "$probe")"
  [ -n "$s" ] || fail "(10) '$probe' selected NOTHING — the selection must never be empty"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    has "$CURATED" "$n" || fail "(10) '$probe' selected '$n', which is not in the curated set"
  done <<< "$s"
  [ "$s" = "$(printf '%s\n' "$s" | LC_ALL=C sort -u)" ] \
    || fail "(10) '$probe' produced an unsorted or duplicated selection"
done
ok "(10) every selection is a sorted-unique SUBSET of the curated set — never an invented name"

# ── (11) DISCOVERY WIRING: the allow-list intersects, never widens ─────────────────────────────────
# shellcheck source=/dev/null
. "$DISC"
DFIX="$T/disc/tests"; mkdir -p "$DFIX"
for n in alpha beta gamma delta; do
  printf '#!/usr/bin/env bash\necho "ALL PASS"\n' > "$DFIX/test-$n.sh"
done
printf 'test-delta.sh\n' > "$DFIX/exempt.tsv"
BESPOKE="test-gamma.sh"
unset HERD_SUITE_SCOPE_TESTS
BASE="$(herd_bats_discover "$DFIX" "$DFIX/exempt.tsv" "$BESPOKE")"
[ "$BASE" = "$(printf 'test-alpha.sh\ntest-beta.sh')" ] \
  || fail "(11) unscoped discovery baseline is wrong: $BASE"
# An allow-list narrows within that baseline …
SCOPED="$(HERD_SUITE_SCOPE_TESTS="test-alpha.sh" herd_bats_discover "$DFIX" "$DFIX/exempt.tsv" "$BESPOKE")"
[ "$SCOPED" = "test-alpha.sh" ] || fail "(11) the allow-list must narrow discovery, got: $SCOPED"
# … and can never WIDEN it past the exempt/bespoke rules.
WIDEN="$(HERD_SUITE_SCOPE_TESTS="test-alpha.sh test-gamma.sh test-delta.sh" \
         herd_bats_discover "$DFIX" "$DFIX/exempt.tsv" "$BESPOKE")"
[ "$WIDEN" = "test-alpha.sh" ] \
  || fail "(11) an allow-list must never re-admit an exempt or bespoke test, got: $WIDEN"
# Unset → byte-identical to the pre-change discovery.
AGAIN="$(herd_bats_discover "$DFIX" "$DFIX/exempt.tsv" "$BESPOKE")"
[ "$AGAIN" = "$BASE" ] || fail "(11) discovery must be byte-identical when HERD_SUITE_SCOPE_TESTS is unset"
# The LOUD zero-match contract is untouched by scoping.
herd_bats_discover "$T/no-such-dir" "" "" >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "(11) a zero-match glob must still return rc 2 (never a silent empty suite)"
ok "(11) discovery honors the allow-list as an intersection, stays byte-identical when unset, and keeps its zero-match guard"

# ── (12) WRAPPER DORMANCY: the default scope leaves discovery untouched ────────────────────────────
if [ -f "$WRAPPER" ]; then
  grep -q 'HERD_SUITE_SCOPE_TESTS' "$WRAPPER" \
    || fail "(12) the healthcheck wrapper does not wire HERD_SUITE_SCOPE_TESTS at all"
  grep -q '_hk_scope_mode' "$WRAPPER" \
    || fail "(12) the healthcheck wrapper does not resolve HEALTH_SUITE_SCOPE"
  # The export must sit INSIDE the diff branch: an unconditional export would pin every run to a
  # selection, which is exactly the byte-identical-when-off guarantee this lever promises.
  awk '/_hk_scope_mode\)" = "diff"/{inbranch=1} inbranch && /export HERD_SUITE_SCOPE_TESTS/{found=1} END{exit !found}' \
    "$WRAPPER" || fail "(12) HERD_SUITE_SCOPE_TESTS is exported outside the HEALTH_SUITE_SCOPE=diff branch"
  ok "(12) the wrapper exports the allow-list only under HEALTH_SUITE_SCOPE=diff (dormant by default)"
else
  ok "(12) skipped — no .herd/healthcheck.project.sh in this tree (a consuming project)"
fi

echo
echo "ALL PASS ($PASS checks) — HERD-532 diff-scoped selection: the pairing convention never drops a"
echo "mapped test across the whole tree, the always-run core is always present, and every wide-blast or"
echo "unmappable path selects the ENTIRE curated set, so a narrowed suite can never read as a false green."
