#!/usr/bin/env bash
# suite-shard.sh — THE shared curated-test-selection + stable shard-assignment library for the
# hermetic suite (HERD-463: CI 24m/13m + local heavy gate ~20m, ~350 hermetic tests run SERIALLY).
# ONE implementation of "which tests/test-*.sh make up the CURATED gate set" and "which shard does
# test X belong to", sourced by scripts/ci/run-suite.sh (the CI matrix) and
# tests/test-suite-shard.sh (the mutation-prove membership test), so a shard partition can never
# silently drop or double-count a test — the exact defect class this file exists to make impossible.
#
# herd_suite_curated_tests <tests_dir> [<exempt_file>]
#   Prints, one per line (LC_ALL=C sorted), every tests/test-*.sh basename in the CURATED hermetic
#   gate set — the same selection scripts/ci/run-suite.sh has always used: every test-*.sh file
#   MINUS tests/gate-coverage-exempt.tsv (flaky/live-env files deliberately kept OUT of the gate;
#   the same exempt list tests/herd.bats' dynamic discovery and gate-coverage-lint.sh honor).
#   <exempt_file> defaults to "<tests_dir>/gate-coverage-exempt.tsv". A missing tests_dir prints
#   nothing (fail-soft — the caller's own "0 tests selected" guard is what should be loud).
#
# herd_suite_shard_hash <name>
#   Prints a stable non-negative integer hash of <name>, derived from `cksum` (POSIX 1003.2 — a
#   spec'd CRC, present on every platform this suite runs on, unlike md5sum/shasum's macOS/Linux
#   naming split). Deterministic across processes, machines and bash versions.
#
# herd_suite_shard_of <name> <shard_count>
#   Prints the 1-based shard index <name> belongs to: (hash(name) % shard_count) + 1.
#   shard_count < 1 (or non-numeric) is treated as 1 — every name lands in shard 1 of 1.
#
# herd_suite_tests_for_shard <tests_dir> <shard_index> <shard_count> [<exempt_file>]
#   Prints the curated tests belonging to <shard_index> (of <shard_count> total), one per line,
#   LC_ALL=C sorted. shard_count<=1 → the full curated set (shard 1 of 1), so a caller that never
#   sets a shard count is byte-identical to the unsharded selection. An <shard_index> outside
#   [1, shard_count] matches nothing (no test's hash can land there) — the caller's own "0 tests
#   selected" guard catches a misconfigured index instead of this library silently no-op'ing.
#
# MUTATION-PROVEN by tests/test-suite-shard.sh: for every shard_count tried, the UNION of shards
# 1..shard_count reconstructs herd_suite_curated_tests exactly (no drop, no duplicate).
#
# ── DIFF-SCOPED SELECTION (HERD-532) ──────────────────────────────────────────────────────────────
# Sharding splits the SAME work across boxes; scoping asks a different question — which of the ~350
# curated tests can this diff actually break? A one-file change to scripts/herd/foo.sh cannot break
# the 340 tests that never touch it, yet the gate runs all of them, every time, on every re-push.
#
# herd_suite_scope_mode
#   The effective HEALTH_SUITE_SCOPE: "diff" or "full" (default full — ship-dormant). Any
#   unrecognized value reads as FULL: a typo must never silently narrow the authoritative gate.
#
# herd_suite_tests_for_diff <tests_dir> <changed-path>...
#   Prints the curated tests this diff can affect, one per line, LC_ALL=C sorted. FOUR rules, in
#   order — and the last is the one that makes the other three safe:
#     (1) PAIRING (the gate-coverage convention, HERD-292): a changed scripts/herd/<name>.sh selects
#         its paired tests/test-<name>.sh. A changed tests/test-<name>.sh selects itself.
#     (2) DOCS MAPPING (HERD-733): README.md, any docs/** path, and any other top-level *.md file
#         (never one under tests/, which rule (1) already governs) selects the enumerated
#         doc-drift/caps-sync/conformance lint tests (HERD_SUITE_DOCS_LINT_TESTS below) instead of
#         falling through to FAIL-CLOSED. A documentation-only diff cannot break engine logic, but it
#         CAN drift out of sync with the manifest those lints check docs against — this is the fix for
#         the regression PR #800 exposed: a docs-only PR ran the full ~350-test suite (12.3m) because
#         README.md/docs/*.md paths matched no PAIRING/DECLARED-DEPS rule and fell through to (4).
#     (3) DECLARED DEPS: a test may declare cross-file coverage with a
#             # suite-deps: <path-or-glob> [<path-or-glob>…]
#         header line. Any changed path matching a token selects that test. This is how a test that
#         covers a file it is not NAME-paired with (a template, a backend, a sibling script) stays
#         selected — the escape hatch that keeps rules (1)/(2)'s narrowness honest.
#     (4) FAIL-CLOSED: any changed path that rules (1)-(3) cannot map, and any path on the
#         WIDE-BLAST list (bin/herd, herd-config.sh, agent-watch.sh, either healthcheck wrapper,
#         templates/capabilities.tsv, this library, and the bats discovery surface), selects the
#         ENTIRE curated set. Unmappable never means "select nothing"; it means "select everything".
#         A non-docs unmappable path stays unmappable — rule (2) narrows ONLY docs-shaped paths.
#   MIXED diffs union every rule that fires: a docs path beside a paired scripts/herd/<name>.sh diff
#   selects the doc-lint tests + the paired test + the core, never the full set — only a path NONE of
#   rules (1)-(3) can map re-arms FAIL-CLOSED, even when it sits beside an otherwise-mappable path.
#   Plus an ALWAYS-RUN CORE (herd_suite_core_tests, HERD-585: sourced from the committed
#   tests/scope-core.tsv): the cross-cutting manifest/lint/hermeticity proofs that ANY diff can trip
#   regardless of which file it touched. The core is unioned into every scoped selection, so scoping
#   can never drop them.
#
#   The invariant this must never break: a scoped selection is a SUBSET of the curated set that
#   still contains every test the rules above map from the diff, and the fail-closed paths return
#   the curated set EXACTLY. tests/test-suite-scope.sh mutation-proves both halves (same discipline
#   as the shard membership proof above): a dropped test can never read as green.

# herd_suite_core_tests <tests_dir>
#   Prints the ALWAYS-RUN CORE as a space-separated list of test basenames: proofs that guard
#   cross-cutting invariants a diff to ANY file can violate — the capability/config manifests, the
#   shared gate lints, the conformance ledger, the suite's own hermeticity guards, and this selection
#   library itself.
#
#   An explicit HERD_SUITE_CORE_TESTS env var — even an empty string — overrides the committed file
#   outright; that is the escape hatch a caller uses to isolate another rule from the core union
#   (tests/test-suite-scope.sh's suite-deps checks do this). Otherwise the core is read from the
#   committed tests/scope-core.tsv sitting alongside <tests_dir> (HERD-585): one bare test-*.sh
#   basename per line, '#'-comments and blank lines ignored — never a hardcoded default in this
#   library, so the core can never silently diverge from what is actually committed and reviewed
#   (the incident this exists to prevent: PR #708 shipped a ghost config key because the diff-scoped
#   selection paired a changed script only with its own paired test — tests/test-config-manifest.sh,
#   the manifest's own ghost/dead-key scan, never ran). A name that is not in the curated set
#   (retired/renamed/exempted) is dropped silently by the intersection in herd_suite_tests_for_diff —
#   and asserted present by tests/test-suite-scope.sh, so a rename is caught by the proof rather than
#   silently shrinking the core. Fail-soft: a missing <tests_dir> or missing tests/scope-core.tsv
#   prints nothing — the caller's mutation-prove test is what should be loud about a deleted
#   committed file, not this library silently reinventing a fallback nobody can review.
herd_suite_core_tests() {
  local _hct_dir="${1:-}"
  if [ -n "${HERD_SUITE_CORE_TESTS+set}" ]; then
    printf '%s' "$HERD_SUITE_CORE_TESTS"
    return 0
  fi
  [ -n "$_hct_dir" ] && [ -f "$_hct_dir/scope-core.tsv" ] || return 0
  grep -v '^[[:space:]]*#' "$_hct_dir/scope-core.tsv" 2>/dev/null \
    | grep -v '^[[:space:]]*$' \
    | tr '\n' ' '
}

# WIDE-BLAST paths: a change here can plausibly affect ANY test, so it selects the full curated set.
# Space-separated repo-root-relative paths (matched exactly, after a leading './' is stripped):
#   • bin/herd, herd-config.sh, agent-watch.sh — the CLI, the config loader every script sources,
#     and the watcher: effectively global blast radius.
#   • scripts/herd/healthcheck.sh + .herd/healthcheck.project.sh — the gate wrappers themselves. A
#     change to how the suite RUNS must be proven by running the whole suite.
#   • templates/capabilities.tsv — the manifest half of a dozen lints.
#   • scripts/herd/suite-shard.sh — THIS file. The selector must never scope its own change.
#   • tests/herd.bats, tests/discover-tests.bash, tests/gate-coverage-exempt.tsv — the discovery
#     surface that decides what "the suite" even is.
HERD_SUITE_WIDE_BLAST="${HERD_SUITE_WIDE_BLAST:-bin/herd scripts/herd/herd-config.sh scripts/herd/agent-watch.sh scripts/herd/healthcheck.sh .herd/healthcheck.project.sh templates/capabilities.tsv scripts/herd/suite-shard.sh tests/herd.bats tests/discover-tests.bash tests/gate-coverage-exempt.tsv}"

# DOCS-LINT tests (HERD-733): the enumerated doc-drift/caps-sync/conformance lint tests a docs-only
# diff selects instead of falling through to FAIL-CLOSED (see herd_suite_tests_for_diff's rule (2)
# above). An explicit constant — not a re-derivation from tests/scope-core.tsv — so this mapping
# stays correct even if a future core trim ever moved one of these names out of the always-run set;
# today all three already ride in the committed core, so a docs-only selection is exactly the core.
HERD_SUITE_DOCS_LINT_TESTS="${HERD_SUITE_DOCS_LINT_TESTS:-test-doc-drift.sh test-caps-sync-light.sh test-conformance.sh}"

herd_suite_curated_tests() {
  local _hsc_dir="${1:-}" _hsc_exempt="${2:-}"
  [ -n "$_hsc_dir" ] && [ -d "$_hsc_dir" ] || return 0
  [ -n "$_hsc_exempt" ] || _hsc_exempt="$_hsc_dir/gate-coverage-exempt.tsv"
  # tests/test-suite-shard.sh calls this (via herd_suite_tests_for_shard) 15x for one run, once per
  # (shard_index, shard_count) pair — a per-file basename+grep fork here used to mean 700+ forks per
  # call and a >120s test timeout. One bulk grep against the exempt file keeps this O(1) forks.
  local _hsc_raw
  _hsc_raw="$(
    shopt -s nullglob
    local _hsc_f
    for _hsc_f in "$_hsc_dir"/test-*.sh; do
      printf '%s\n' "${_hsc_f##*/}"
    done
  )"
  [ -n "$_hsc_raw" ] || return 0
  if [ -f "$_hsc_exempt" ]; then
    printf '%s\n' "$_hsc_raw" | grep -vFxf "$_hsc_exempt" | LC_ALL=C sort
  else
    printf '%s\n' "$_hsc_raw" | LC_ALL=C sort
  fi
}

herd_suite_shard_hash() {
  local _hsh_out
  _hsh_out="$(cksum <<< "$1")"
  printf '%s' "${_hsh_out%% *}"
}

herd_suite_shard_of() {
  local _hso_name="$1" _hso_count="${2:-1}" _hso_hash
  case "$_hso_count" in ''|*[!0-9]*) _hso_count=1 ;; esac
  [ "$_hso_count" -ge 1 ] 2>/dev/null || _hso_count=1
  _hso_hash="$(herd_suite_shard_hash "$_hso_name")"
  case "$_hso_hash" in ''|*[!0-9]*) _hso_hash=0 ;; esac
  printf '%s' "$(( _hso_hash % _hso_count + 1 ))"
}

herd_suite_tests_for_shard() {
  local _hst_dir="${1:-}" _hst_idx="${2:-1}" _hst_count="${3:-1}" _hst_exempt="${4:-}"
  case "$_hst_idx" in ''|*[!0-9]*) _hst_idx=1 ;; esac
  local _hst_name _hst_shard
  herd_suite_curated_tests "$_hst_dir" "$_hst_exempt" | while IFS= read -r _hst_name; do
    [ -n "$_hst_name" ] || continue
    _hst_shard="$(herd_suite_shard_of "$_hst_name" "$_hst_count")"
    [ "$_hst_shard" = "$_hst_idx" ] && printf '%s\n' "$_hst_name"
  done
}

# ── DIFF-SCOPED SELECTION (HERD-532) ──────────────────────────────────────────────────────────────

# herd_suite_scope_mode — the effective HEALTH_SUITE_SCOPE. Prints "diff" only for an exact,
# case-insensitive "diff"; EVERYTHING else (unset, empty, a typo, a value from a newer engine)
# prints "full". Fail toward the authoritative full suite: a scope typo must never quietly gate a
# merge on a subset.
herd_suite_scope_mode() {
  case "$(printf '%s' "${HEALTH_SUITE_SCOPE:-full}" | tr '[:upper:]' '[:lower:]')" in
    diff) printf 'diff' ;;
    *)    printf 'full' ;;
  esac
}

# _herd_suite_deps_table <tests_dir> — emit one "<test-basename>\t<dep-token>" row per token of every
# test's optional `# suite-deps: <path-or-glob> …` header. Built ONCE per selection call (not once per
# changed path). Only the FIRST such header line in a file is read, so a doc example further down a
# test cannot silently widen its own coverage claim. Pathname expansion is disabled around the token
# split: a dep token like `scripts/herd/backends/*.sh` is a PATTERN to match changed paths against,
# and must never be glob-expanded against the caller's cwd.
_herd_suite_deps_table() {
  local _hdt_dir="${1:-}" _hdt_hits _hdt_row _hdt_base _hdt_line _hdt_tok _hdt_restore=0
  [ -n "$_hdt_dir" ] && [ -d "$_hdt_dir" ] || return 0
  # ONE grep across every test file (`-m1` stops after the first match PER FILE, `-H` names it), not a
  # grep fork per file: the ~400-file tree made the per-file shape a 400-fork, multi-second scan — the
  # exact cost herd_suite_curated_tests' own bulk-grep note above was written about. Files are named
  # directly (no `producer | grep`), so there is no EPIPE under a caller's pipefail (HERD-297).
  _hdt_hits="$(grep -H -m1 -E '^#[[:space:]]*suite-deps:' "$_hdt_dir"/test-*.sh 2>/dev/null)" || return 0
  [ -n "$_hdt_hits" ] || return 0
  # Split the declared tokens with pathname expansion DISABLED: a dep token like
  # `scripts/herd/backends/*.sh` is a PATTERN to match changed paths against, never a glob to expand
  # against the caller's cwd.
  case "$-" in *f*) : ;; *) _hdt_restore=1; set -f ;; esac
  while IFS= read -r _hdt_row; do
    [ -n "$_hdt_row" ] || continue
    _hdt_base="${_hdt_row%%:*}"; _hdt_base="${_hdt_base##*/}"
    _hdt_line="${_hdt_row#*suite-deps:}"
    for _hdt_tok in $_hdt_line; do
      [ -n "$_hdt_tok" ] || continue
      printf '%s\t%s\n' "$_hdt_base" "$_hdt_tok"
    done
  done <<EOF
$_hdt_hits
EOF
  [ "$_hdt_restore" -eq 1 ] && set +f
  return 0
}

# herd_suite_tests_for_diff <tests_dir> <changed-path>… — the curated tests this diff can affect,
# one per line, LC_ALL=C sorted-unique. See the header block for the four rules and the always-run
# core. Returns the FULL curated set (never nothing) whenever it cannot prove a narrower answer:
# no changed paths given, a wide-blast path, or a path no rule maps.
herd_suite_tests_for_diff() {
  local _hsd_dir="${1:-}"
  [ "$#" -ge 1 ] && shift
  local _hsd_curated _hsd_sel="" _hsd_deps="" _hsd_p _hsd_base _hsd_name _hsd_out
  local _hsd_mapped _hsd_t _hsd_tok _hsd_restore=0

  _hsd_curated="$(herd_suite_curated_tests "$_hsd_dir")"
  [ -n "$_hsd_curated" ] || return 0          # no tests at all → nothing to select (fail-soft)
  if [ "$#" -eq 0 ]; then printf '%s\n' "$_hsd_curated"; return 0; fi

  # Build the dep table FIRST — it globs "$_hsd_dir"/test-*.sh, so it must run while pathname
  # expansion is still enabled (it disables expansion only around its own token split).
  _hsd_deps="$(_herd_suite_deps_table "$_hsd_dir")"
  # Now disable pathname expansion for the unquoted `for … in $LIST` splits below (the core /
  # wide-blast lists and the dep tokens are PATTERNS and NAMES, never globs to expand against cwd).
  case "$-" in *f*) : ;; *) _hsd_restore=1; set -f ;; esac

  for _hsd_p in "$@"; do
    [ -n "$_hsd_p" ] || continue
    _hsd_p="${_hsd_p#./}"

    # (4a) WIDE-BLAST: a change here can affect anything → the entire curated set, immediately.
    for _hsd_t in ${HERD_SUITE_WIDE_BLAST:-}; do
      if [ "$_hsd_p" = "$_hsd_t" ]; then
        [ "$_hsd_restore" -eq 1 ] && set +f
        printf '%s\n' "$_hsd_curated"
        return 0
      fi
    done

    _hsd_mapped=0
    _hsd_base="${_hsd_p##*/}"

    # (1) PAIRING (the gate-coverage convention, HERD-292).
    case "$_hsd_p" in
      tests/test-*.sh)
        # A changed test selects ITSELF — mapped even when it is exempt or brand-new (the union with
        # the curated set below drops what the gate would not have run anyway).
        _hsd_sel="${_hsd_sel}${_hsd_base}"$'\n'; _hsd_mapped=1 ;;
      scripts/herd/*.sh)
        case "${_hsd_p#scripts/herd/}" in
          */*) : ;;                       # backends/ + work-units/ carry no test-<name>.sh convention
          *)
            _hsd_name="test-${_hsd_base}"
            if [ -f "$_hsd_dir/$_hsd_name" ]; then
              _hsd_sel="${_hsd_sel}${_hsd_name}"$'\n'; _hsd_mapped=1
            fi ;;
        esac ;;
    esac

    # (2) DOCS MAPPING (HERD-733): README.md, any docs/** path, and any other top-level *.md file
    # select the enumerated doc-lint tests. A path under tests/ is excluded here — a *.md fixture or
    # helper living in tests/ is governed by rule (1)/(3), never reclassified as a doc.
    case "$_hsd_p" in
      tests/*) : ;;
      README.md|docs/*|*.md)
        for _hsd_t in $HERD_SUITE_DOCS_LINT_TESTS; do
          [ -n "$_hsd_t" ] || continue
          _hsd_sel="${_hsd_sel}${_hsd_t}"$'\n'
        done
        _hsd_mapped=1 ;;
    esac

    # (3) DECLARED DEPS: any test whose `# suite-deps:` header covers this path.
    while IFS=$'\t' read -r _hsd_t _hsd_tok; do
      [ -n "$_hsd_t" ] && [ -n "$_hsd_tok" ] || continue
      # shellcheck disable=SC2254  # $_hsd_tok is deliberately a PATTERN, not a literal
      case "$_hsd_p" in
        $_hsd_tok) _hsd_sel="${_hsd_sel}${_hsd_t}"$'\n'; _hsd_mapped=1 ;;
      esac
    done <<EOF
$_hsd_deps
EOF

    # (4b) UNMAPPABLE: no pairing, no docs mapping, no declared dep → fail CLOSED to the entire
    # curated set. This is what makes a narrow selection safe: "we could not prove which tests cover
    # this" is answered with everything, never with nothing.
    if [ "$_hsd_mapped" -eq 0 ]; then
      [ "$_hsd_restore" -eq 1 ] && set +f
      printf '%s\n' "$_hsd_curated"
      return 0
    fi
  done

  # ALWAYS-RUN CORE (HERD-585): unioned into every scoped selection, so the cross-cutting manifest/
  # lint/hermeticity proofs run no matter which file the diff touched. Sourced from the committed
  # tests/scope-core.tsv via herd_suite_core_tests — see its header comment above.
  for _hsd_t in $(herd_suite_core_tests "$_hsd_dir"); do
    [ -n "$_hsd_t" ] || continue
    _hsd_sel="${_hsd_sel}${_hsd_t}"$'\n'
  done
  [ "$_hsd_restore" -eq 1 ] && set +f

  # Intersect with the curated set — a selected name that is exempt, retired or not yet committed is
  # not part of the gate and must not be emitted — then dedupe + sort for a stable, comparable list.
  _hsd_out="$(printf '%s\n' "$_hsd_sel" \
    | grep -Fxf <(printf '%s\n' "$_hsd_curated") 2>/dev/null \
    | LC_ALL=C sort -u)" || _hsd_out=""
  [ -n "$_hsd_out" ] && printf '%s\n' "$_hsd_out"
  return 0
}
