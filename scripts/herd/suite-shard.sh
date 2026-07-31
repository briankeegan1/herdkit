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

herd_suite_curated_tests() {
  local _hsc_dir="${1:-}" _hsc_exempt="${2:-}"
  [ -n "$_hsc_dir" ] && [ -d "$_hsc_dir" ] || return 0
  [ -n "$_hsc_exempt" ] || _hsc_exempt="$_hsc_dir/gate-coverage-exempt.tsv"
  (
    shopt -s nullglob
    local _hsc_f _hsc_base
    for _hsc_f in "$_hsc_dir"/test-*.sh; do
      _hsc_base="$(basename "$_hsc_f")"
      if [ -f "$_hsc_exempt" ] && grep -qxF -- "$_hsc_base" "$_hsc_exempt" 2>/dev/null; then
        continue
      fi
      printf '%s\n' "$_hsc_base"
    done
  ) | LC_ALL=C sort
}

herd_suite_shard_hash() {
  printf '%s' "$1" | cksum | awk '{print $1}'
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
