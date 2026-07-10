#!/usr/bin/env bash
# discover-tests.bash — shared, sourceable helper for tests/herd.bats DYNAMIC test discovery
# (HERD-295). tests/herd.bats used to carry one hand-written @test block per tests/test-*.sh, which
# made it the #1 stale-base collision point (every new test edited it). Discovery globs the files
# instead, so ADDING a hermetic test no longer touches herd.bats.
#
# herd_bats_discover <tests_dir> <exempt_file> <bespoke_space_separated_list>
#   Prints, one per line (LC_ALL=C sorted), each tests/test-*.sh basename that dynamic discovery
#   should register as its own bats test: every test-*.sh MINUS the exempt list MINUS the bespoke
#   (hand-written @test block) list.
#     • <exempt_file>  — tests/gate-coverage-exempt.tsv; files deliberately NOT run in the gate
#                        (flaky / live-env). Bare-filename rows; '#'/blank lines ignored (whole-line
#                        match, so a comment can never accidentally exempt a file).
#     • <bespoke_list> — space-separated basenames that already have a hand-written @test block and
#                        must NOT be double-run by discovery (kept because they do MORE than a plain
#                        shellout — a SKIP-tolerant assertion, or a description another gate keys on).
#   Exit: 0 = one or more files matched the glob (normal)
#         2 = the glob matched ZERO tests/test-*.sh — a typo / wrong dir / empty suite. The caller
#             MUST fail LOUDLY on 2 so a glob mistake can never silently pass an empty suite.
#
# Grep the exempt FILE directly (never `producer | grep -q`) so a large exempt list cannot EPIPE
# under a caller's `set -o pipefail` (the HERD-297 shape that once misclassified a wired test).
herd_bats_discover() {
  local _d="${1:-}" _exempt="${2:-}" _bespoke="${3:-}" _f _base _matched=0 _out=""
  for _f in "$_d"/test-*.sh; do
    [ -e "$_f" ] || continue            # nullglob-off guard: no match → literal string → skip
    _matched=1
    _base="$(basename "$_f")"
    # bespoke: handled by a hand-written @test block → skip so it is not run twice.
    case " $_bespoke " in *" $_base "*) continue ;; esac
    # exempt: deliberately out of the gate. Whole-line (-x) match ignores '#' comments/header rows.
    if [ -n "$_exempt" ] && [ -f "$_exempt" ] && grep -qxF -- "$_base" "$_exempt" 2>/dev/null; then
      continue
    fi
    _out="${_out}${_base}"$'\n'
  done
  # LOUD zero-match: the glob matched no test-*.sh at all. Signal the caller (rc 2) BEFORE printing.
  [ "$_matched" -eq 1 ] || return 2
  [ -n "$_out" ] && printf '%s' "$_out" | LC_ALL=C sort
  return 0
}
