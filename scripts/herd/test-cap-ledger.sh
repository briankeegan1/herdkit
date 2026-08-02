#!/usr/bin/env bash
# test-cap-ledger.sh — THE shared PER-TEST TIMEOUT LEDGER library (HERD-478): scripts/ci/run-suite.sh
# wraps every hermetic test in `timeout <cap-secs> bash test.sh`, and until now every test shared ONE
# static cap (HERD_CI_TEST_TIMEOUT, default 120s) no matter how heavy it genuinely is. A test that
# needs more heads down two bad paths: it gets silently added to tests/known-env-sensitive.tsv as an
# XFAIL (test-cli-reload.sh's ~82-93s runtime leaves so little headroom against the shared 120s cap
# that it periodically TIMEOUTs on a slower/contended macOS CI runner — see that file's HERD-440 row),
# or the shared cap gets raised for EVERYONE to cover the one outlier, silently hiding a real hang in
# every other test for another 60-100s. tests/test-caps.tsv names the tests that genuinely need more
# time, with a mandatory reason + measured baseline, so raising a cap is a reviewable, accountable row
# instead of either of those.
#
# tests/test-caps.tsv format (TAB-separated, LC_ALL=C order not required):
#   test<TAB>cap-secs<TAB>reason<TAB>measured-baseline
# `test` is the bare test-*.sh basename (matches scripts/ci/run-suite.sh's per-test `name`).
# `cap-secs` is the per-test timeout override (an integer, seconds).
# `reason` is a one-line why this test needs more than the default (mandatory — NO bare rows: a row
#   with an empty reason or empty measured-baseline is a CODE error, the same lesson HERD-437 learned
#   the hard way from tests/gate-coverage-exempt.tsv's 179 reason-less rows).
# `measured-baseline` is the last REAL observed wall-clock runtime in seconds this row was set from
#   (mandatory, for the same reason) — it is what herd_test_cap_ledger_check compares against to
#   catch a STALE row: a listed test whose measured-baseline now sits comfortably under the default
#   cap no longer needs (and never should have kept) an elevated cap-secs — list it only while it is
#   genuinely close to the shared default.
# Comment lines ('#'-led) and the literal header row ("test") are ignored by every reader below; a
# blank tests/test-caps.tsv (or a missing file) is a valid state — every test just gets the default.
#
# HERD_TEST_CAP_DEFAULT_SECS — the uniform default cap (seconds) for any test with no ledger row.
HERD_TEST_CAP_DEFAULT_SECS=120

# herd_test_cap_for <test-name> <tsv-file> [<default-secs>]
#   Prints the cap-secs <test-name> should run under: its tests/test-caps.tsv row's cap-secs if one
#   exists and parses as a non-negative integer, else <default-secs> (or $HERD_TEST_CAP_DEFAULT_SECS).
#   Fail-soft: a missing/unreadable tsv, or a row whose cap-secs field is malformed, both fall through
#   to the default rather than erroring — herd_test_cap_ledger_check (below) is what reds a malformed
#   row; this lookup just never lets a malformed row silently starve a test of ANY timeout.
herd_test_cap_for() {
  local _tcf_name="${1:-}" _tcf_tsv="${2:-}" _tcf_default="${3:-$HERD_TEST_CAP_DEFAULT_SECS}"
  local _tc_name _tc_cap _tc_reason _tc_base
  if [ -n "$_tcf_tsv" ] && [ -f "$_tcf_tsv" ]; then
    while IFS=$'\t' read -r _tc_name _tc_cap _tc_reason _tc_base; do
      case "$_tc_name" in ''|'#'*|test) continue ;; esac
      [ "$_tc_name" = "$_tcf_name" ] || continue
      case "$_tc_cap" in ''|*[!0-9]*) continue ;; esac    # malformed cap-secs: keep scanning (a later
      printf '%s' "$_tc_cap"                              # duplicate row, if any, still gets a chance)
      return 0
    done < "$_tcf_tsv"
  fi
  printf '%s' "$_tcf_default"
}

# herd_test_cap_ledger_check <tsv-file> [<default-secs>]
#   Pure-function form used by hermetic fixtures. Validates every data row of <tsv-file>:
#     MALFORMED — not exactly 4 tab-separated fields, cap-secs not a non-negative integer,
#                 measured-baseline not a non-negative integer, or an empty reason/measured-baseline
#                 (the "no bare rows" rule).
#     STALE     — a well-formed row whose measured-baseline sits comfortably under <default-secs>
#                 (at or below half the default): the test no longer needs a raised cap.
#   Prints one offending line per hit, then an ADVISORY summary. Exit: 0 = clean · 1 = hit(s).
#   A missing/unreadable tsv-file is a valid, clean, empty ledger (every test uses the default) —
#   distinct from herd_test_cap_ledger_lint's tree-level skip below, which is about there being no
#   tests/ directory to have a ledger in at all.
herd_test_cap_ledger_check() {
  local _tcc_tsv="${1:-}" _tcc_default="${2:-$HERD_TEST_CAP_DEFAULT_SECS}"
  local _tcc_out="" _tcc_total=0 _tcc_stale=0 _tcc_bad=0 _tcc_stale_max
  case "$_tcc_default" in ''|*[!0-9]*) _tcc_default="$HERD_TEST_CAP_DEFAULT_SECS" ;; esac
  _tcc_stale_max=$(( _tcc_default / 2 ))

  if [ -n "$_tcc_tsv" ] && [ -f "$_tcc_tsv" ]; then
    local _tcc_line _tcc_n _tcc_name _tcc_cap _tcc_reason _tcc_base
    _tcc_n=0
    while IFS= read -r _tcc_line || [ -n "$_tcc_line" ]; do
      _tcc_n=$((_tcc_n + 1))
      case "$_tcc_line" in ''|'#'*) continue ;; esac
      IFS=$'\t' read -r _tcc_name _tcc_cap _tcc_reason _tcc_base <<< "$_tcc_line"
      [ "$_tcc_name" = "test" ] && continue   # the literal header row (no real test is named "test")
      _tcc_total=$((_tcc_total + 1))
      if [ -z "$_tcc_name" ] || [ -z "$_tcc_reason" ] || [ -z "$_tcc_base" ]; then
        _tcc_out="${_tcc_out}MALFORMED ${_tcc_tsv}:${_tcc_n}: ${_tcc_name:-<empty>} — missing field(s) (test/cap-secs/reason/measured-baseline all mandatory, no bare rows)"$'\n'
        _tcc_bad=$((_tcc_bad + 1)); continue
      fi
      case "$_tcc_cap" in
        ''|*[!0-9]*)
          _tcc_out="${_tcc_out}MALFORMED ${_tcc_tsv}:${_tcc_n}: ${_tcc_name} — cap-secs '${_tcc_cap}' is not a non-negative integer"$'\n'
          _tcc_bad=$((_tcc_bad + 1)); continue ;;
      esac
      case "$_tcc_base" in
        ''|*[!0-9]*)
          _tcc_out="${_tcc_out}MALFORMED ${_tcc_tsv}:${_tcc_n}: ${_tcc_name} — measured-baseline '${_tcc_base}' is not a non-negative integer"$'\n'
          _tcc_bad=$((_tcc_bad + 1)); continue ;;
      esac
      if [ "$_tcc_base" -le "$_tcc_stale_max" ]; then
        _tcc_out="${_tcc_out}STALE ${_tcc_tsv}:${_tcc_n}: ${_tcc_name} — measured-baseline ${_tcc_base}s sits comfortably under the ${_tcc_default}s default (<= ${_tcc_stale_max}s); drop the row, the default already covers it"$'\n'
        _tcc_stale=$((_tcc_stale + 1))
      fi
    done < "$_tcc_tsv"
  fi

  printf '%s' "$_tcc_out"
  printf 'ADVISORY: %d ledger row(s); %d malformed; %d stale (clean when both are 0)\n' \
    "$_tcc_total" "$_tcc_bad" "$_tcc_stale"
  [ "$_tcc_bad" -eq 0 ] && [ "$_tcc_stale" -eq 0 ]
}

# herd_test_cap_ledger_lint [<root>] [<default-secs>]
#   Entrypoint form for the gate surfaces. Looks for <root>/tests/test-caps.tsv.
#   Exit: 0 = clean (incl. no ledger file — a valid empty ledger) · 1 = malformed/stale row(s) ·
#         2 = skipped (no tests/ dir in this tree at all; infra, NEVER a red).
#   On a skip, $HERD_TEST_CAP_LEDGER_SKIP_REASON carries the one-line why.
HERD_TEST_CAP_LEDGER_SKIP_REASON=""
herd_test_cap_ledger_lint() {
  local _tcl_root="${1:-.}" _tcl_default="${2:-$HERD_TEST_CAP_DEFAULT_SECS}"
  HERD_TEST_CAP_LEDGER_SKIP_REASON=""
  if [ ! -d "$_tcl_root/tests" ]; then
    HERD_TEST_CAP_LEDGER_SKIP_REASON="no tests/ directory in this tree"
    return 2
  fi
  herd_test_cap_ledger_check "$_tcl_root/tests/test-caps.tsv" "$_tcl_default"
}
