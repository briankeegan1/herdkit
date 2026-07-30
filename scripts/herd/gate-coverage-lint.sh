#!/usr/bin/env bash
# gate-coverage-lint.sh — THE shared gate-coverage drift guard (HERD-292, flipped for HERD-295
# dynamic discovery): every tests/test-*.sh must be exercised by the authoritative merge gate.
#
# Under HERD-295, tests/herd.bats no longer names each test — it GLOBS tests/test-*.sh and registers
# each as its own bats test. So this guard now asserts:
#   (a) DISCOVERY IS PRESENT — tests/herd.bats still contains the dynamic-discovery glob (the literal
#       wildcard `test-*.sh`). If it were removed, the whole suite would silently run nothing; every
#       non-exempt test file is then reported UNGATED (loud red), exactly as before discovery existed.
#   (b) NOTHING IS SILENTLY EXCLUDED — with discovery present, a test file is covered when it is
#       auto-discovered, OR referenced by name in herd.bats (a hand-written bespoke @test block), OR
#       on the exempt list (tests/gate-coverage-exempt.tsv, still honored). Anything else is UNGATED.
#
# ONE implementation, sourced (never executed) by BOTH gate surfaces so they can never disagree:
#     • scripts/herd/healthcheck.sh      — the builder's LIGHT pre-PR gate (so a broken discovery is
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
# herd_gate_coverage_advisory_note <lint-output>
#   HERD-437: exemption counts as covered, so a clean exit (0 ungated) reads identically whether the
#   exempt list has 5 rows or 179 — the growing blind spot was silently absorbed into a bare "clean".
#   Pure string helper: parses the ADVISORY summary's own counts (never re-derives them) and prints a
#   one-line "N/M exempt (P%)" (or "0 exempt") for a caller to fold into its ALWAYS-printed verdict —
#   see .herd/healthcheck.project.sh's gcov_note — so the exempt count is visible on every run, not
#   just when something is UNGATED.
#
# Fail-soft by construction: no tests/herd.bats in the tree (a consuming project) → skip,
# never a false red. An exempt file that doesn't exist is silently treated as empty.

HERD_GATE_COVERAGE_SKIP_REASON=""

# herd_gate_coverage_check <bats> <tests-dir> [<exempt-file>]
# Pure function: prints UNGATED lines then an ADVISORY summary. Exit 0 clean / 1 ungated.
herd_gate_coverage_check() {
  local _gc_bats="${1:-}" _gc_dir="${2:-}" _gc_exempt="${3:-}"
  local _gc_ungated="" _gc_total=0 _gc_exempted=0 _gc_wired=0 _gc_discovered=0 _gc_f _gc_base
  local _gc_has_discovery=0

  # (a) Is dynamic discovery present? The discovery loop globs tests/test-*.sh — grep the bats FILE
  # directly for the literal wildcard glob (a `test-*.sh` with a real `*`, which no concrete filename
  # can match). Grep the file directly — NOT `printf … | grep -q` (HERD-297): a producer piped into
  # `grep -q` takes EPIPE at grep's early exit and, under a caller's `set -o pipefail`, goes nonzero,
  # misclassifying once herd.bats grows past a pipe buffer. No pipe, no EPIPE.
  if grep -qE 'test-\*\.sh' "$_gc_bats" 2>/dev/null; then
    _gc_has_discovery=1
  fi

  while IFS= read -r _gc_f; do
    [ -n "$_gc_f" ] || continue
    _gc_base="$(basename "$_gc_f")"
    _gc_total=$((_gc_total + 1))

    # Referenced by name in herd.bats? A hand-written bespoke @test block (or the HERD_DISCOVERY_BESPOKE
    # skip-list). Grep the bats FILE directly (see the EPIPE note above).
    if grep -qF -- "$_gc_base" "$_gc_bats" 2>/dev/null; then
      _gc_wired=$((_gc_wired + 1))
      continue
    fi

    # On the exempt list? (whole-line match, so '#' comments/header never accidentally exempt).
    if [ -n "$_gc_exempt" ] && [ -f "$_gc_exempt" ]; then
      if grep -qxF -- "$_gc_base" "$_gc_exempt" 2>/dev/null; then
        _gc_exempted=$((_gc_exempted + 1))
        continue
      fi
    fi

    # Covered by dynamic discovery? (b) With the glob present, every not-bespoke, not-exempt test-*.sh
    # is auto-registered. Without it, the file is genuinely UNGATED — the suite would skip it.
    if [ "$_gc_has_discovery" -eq 1 ]; then
      _gc_discovered=$((_gc_discovered + 1))
      continue
    fi

    _gc_ungated="${_gc_ungated}UNGATED ${_gc_base} — not auto-discovered (tests/herd.bats lacks the test-*.sh discovery glob), not referenced in tests/herd.bats, and not on the exempt list"$'\n'
  done < <(find "$_gc_dir" -maxdepth 1 -name 'test-*.sh' 2>/dev/null | sort)

  local _gc_n=0
  [ -n "$_gc_ungated" ] && _gc_n="$(printf '%s\n' "$_gc_ungated" | grep -c '^UNGATED')"
  printf '%s' "$_gc_ungated"
  printf 'ADVISORY: %d total test-*.sh; %d auto-discovered; %d referenced in herd.bats; %d exempted; %d ungated (clean when 0; discovery-glob-present=%d)\n' \
    "$_gc_total" "$_gc_discovered" "$_gc_wired" "$_gc_exempted" "$_gc_n" "$_gc_has_discovery"

  [ -z "$_gc_ungated" ]
}

# herd_gate_coverage_advisory_note <lint-output> — HERD-437: a clean lint (0 ungated) still hides a
# growing exempt list — "exemption counts as covered" reads identically whether 5 or 179 files never
# run. Extract the "N exempted" / "M total" counts straight out of the shared ADVISORY summary line
# (never re-derive them independently — ONE source of truth, so a caller's note can never disagree
# with the lint that produced it) and render a one-line, ALWAYS-printable advisory so the exempt
# count is visible on every clean run, not silently absorbed into a bare "clean". Pure string
# function: no filesystem access, so it is safe to call on any captured lint output.
herd_gate_coverage_advisory_note() {
  local _gcn_out="$1" _gcn_total=0 _gcn_exempt=0 _gcn_pct
  _gcn_total="$(printf '%s\n' "$_gcn_out" | grep -oE '^ADVISORY: [0-9]+' | grep -oE '[0-9]+$')"
  _gcn_exempt="$(printf '%s\n' "$_gcn_out" | grep -oE '[0-9]+ exempted' | grep -oE '^[0-9]+')"
  [ -n "$_gcn_total" ] || _gcn_total=0
  [ -n "$_gcn_exempt" ] || _gcn_exempt=0
  if [ "$_gcn_exempt" -eq 0 ]; then
    printf '0 exempt'
    return 0
  fi
  if [ "$_gcn_total" -gt 0 ]; then
    _gcn_pct=$((_gcn_exempt * 100 / _gcn_total))
    printf '%d/%d exempt (%d%%) — see tests/gate-coverage-exempt.tsv' "$_gcn_exempt" "$_gcn_total" "$_gcn_pct"
  else
    printf '%d exempt' "$_gcn_exempt"
  fi
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
