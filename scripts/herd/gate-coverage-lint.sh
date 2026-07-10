#!/usr/bin/env bash
# gate-coverage-lint.sh — THE shared gate-coverage drift guard (HERD-292): every tests/test-*.sh
# must be referenced by tests/herd.bats (i.e. wired into the authoritative merge gate) OR listed
# in an explicit exempt file (tests/gate-coverage-exempt.tsv). A test file that sits ungated for
# months is an accountability gap — the guard catches new additions before they drift.
#
# ONE implementation, sourced (never executed) by BOTH gate surfaces so they can never disagree:
#     • scripts/herd/healthcheck.sh      — the builder's LIGHT pre-PR gate (so an ungated test is
#                                          caught before `gh pr create` instead of silently landing)
#     • .herd/healthcheck.project.sh     — the heavy/merge gate (authoritative)
#
# Two functions:
#
# herd_gate_coverage_check <bats> <tests-dir> [<exempt-file>]
#   Pure-function form used by hermetic test fixtures. Reads the given files directly.
#   Prints one UNGATED line per offending test on stdout, then an ADVISORY summary.
#   Exit: 0 = clean · 1 = ungated (lines on stdout)
#   <exempt-file> is optional; when absent or empty, no exemptions are applied.
#
# herd_gate_coverage_lint [<root>]
#   Entrypoint form for the gate surfaces. Uses default paths under <root> (or cwd).
#   Exit: 0 = clean · 1 = ungated · 2 = skipped (infra; NEVER a red).
#   On a skip, $HERD_GATE_COVERAGE_SKIP_REASON carries the one-line why.
#
# Fail-soft by construction: no tests/herd.bats in the tree (a consuming project) → skip,
# never a false red. An exempt file that doesn't exist is silently treated as empty.

HERD_GATE_COVERAGE_SKIP_REASON=""

# herd_gate_coverage_check <bats> <tests-dir> [<exempt-file>]
# Pure function: prints UNGATED lines then an ADVISORY summary. Exit 0 clean / 1 ungated.
herd_gate_coverage_check() {
  local _gc_bats="${1:-}" _gc_dir="${2:-}" _gc_exempt="${3:-}"
  local _gc_ungated="" _gc_total=0 _gc_exempted=0 _gc_wired=0 _gc_f _gc_base

  while IFS= read -r _gc_f; do
    [ -n "$_gc_f" ] || continue
    _gc_base="$(basename "$_gc_f")"
    _gc_total=$((_gc_total + 1))

    # Is it referenced in herd.bats? Grep the bats FILE directly — NOT `printf … | grep -q`
    # (HERD-297): grep -q exits at the first match and closes the pipe, the producer takes EPIPE,
    # and under a caller's `set -o pipefail` the pipeline goes nonzero — misclassifying a wired
    # test as UNGATED once herd.bats grows past a 16KB (macOS) pipe buffer. No pipe, no EPIPE, and
    # grep's early exit is now a pure win.
    if grep -qF -- "$_gc_base" "$_gc_bats" 2>/dev/null; then
      _gc_wired=$((_gc_wired + 1))
      continue
    fi

    # Is it on the exempt list?
    if [ -n "$_gc_exempt" ] && [ -f "$_gc_exempt" ]; then
      if grep -qxF "$_gc_base" "$_gc_exempt" 2>/dev/null; then
        _gc_exempted=$((_gc_exempted + 1))
        continue
      fi
    fi

    _gc_ungated="${_gc_ungated}UNGATED ${_gc_base} — not referenced in tests/herd.bats and not on the exempt list"$'\n'
  done < <(find "$_gc_dir" -maxdepth 1 -name 'test-*.sh' 2>/dev/null | sort)

  local _gc_n=0
  [ -n "$_gc_ungated" ] && _gc_n="$(printf '%s\n' "$_gc_ungated" | grep -c '^UNGATED')"
  printf '%s' "$_gc_ungated"
  printf 'ADVISORY: %d total test-*.sh; %d wired in herd.bats; %d exempted; %d ungated (clean when 0)\n' \
    "$_gc_total" "$_gc_wired" "$_gc_exempted" "$_gc_n"

  [ -z "$_gc_ungated" ]
}

# herd_gate_coverage_lint [<root>] — scan the default surface under <root> (or cwd).
# Exit 0 clean / 1 ungated / 2 skipped.
herd_gate_coverage_lint() {
  local _gc_root="${1:-.}"
  local _gc_bats _gc_tests _gc_exempt _gc_out _gc_rc

  HERD_GATE_COVERAGE_SKIP_REASON=""

  _gc_bats="$_gc_root/tests/herd.bats"
  _gc_tests="$_gc_root/tests"
  _gc_exempt="$_gc_root/tests/gate-coverage-exempt.tsv"

  if [ ! -f "$_gc_bats" ]; then
    HERD_GATE_COVERAGE_SKIP_REASON="no tests/herd.bats in this tree"
    return 2
  fi
  if [ ! -d "$_gc_tests" ]; then
    HERD_GATE_COVERAGE_SKIP_REASON="no tests/ directory in this tree"
    return 2
  fi

  _gc_out="$(herd_gate_coverage_check "$_gc_bats" "$_gc_tests" "$_gc_exempt")"; _gc_rc=$?
  printf '%s\n' "$_gc_out"
  return "$_gc_rc"
}
