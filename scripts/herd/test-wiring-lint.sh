#!/usr/bin/env bash
# test-wiring-lint.sh — THE shared test-wiring ratchet (HERD-257): every tests/test-*.sh file must
# be either (a) referenced/run by the gate suite (tests/herd.bats, which scripts/ci/run-suite.sh
# and the dogfood heavy healthcheck both use as the curated suite) or (b) listed in the explicit
# EXEMPT allowlist (tests/test-wiring-exempt.tsv) with a reason.
#
# Motivation: tests/test-review-sever-protect.sh (PR #353) landed with an env-fragile setsid(1)
# assertion because the merge gate never ran it — zero refs outside the file. Broader: only a
# minority of tests/test-*.sh files were enumerated in tests/herd.bats, so the gate silently
# skipped the rest. This ratchet is the conformance/caps-sync analog for hermetic tests: a new
# unexempted + unwired test file is a CODE error.
#
# ONE implementation, sourced (never executed) by BOTH gate surfaces so they can never disagree:
#     • scripts/herd/healthcheck.sh light profile — builder pre-PR gate
#     • tests/test-test-wiring.sh — hermetic unit proof the heavy suite wraps via herd.bats
# Sourced-library precedent: caps-sync-lint.sh, doc-drift-lint.sh.
#
# herd_test_wiring_lint [<root>]
#   Run against <root> (default: cwd). Prints one line per violation on stdout; the caller owns
#   the ❌ headline, the note text and the exit presentation.
#   Exit: 0 = clean · 1 = violation (lines on stdout) · 2 = skipped (infra; NEVER a red).
#   On a skip, $HERD_TEST_WIRING_SKIP_REASON carries the one-line why (for the caller's note).
#
# Fail-soft by construction: no tests/ dir, no test-*.sh files, or a tree that is not an engine
# checkout (no tests/herd.bats and no exempt file expected) yields the skip, never a false red
# in a consuming project that ships no hermetic suite.

HERD_TEST_WIRING_SKIP_REASON=""

# Internal: emit basenames of tests/test-*.sh under $1 (one per line, sorted).
_herd_tw_list_tests() {
  local root="$1" f base
  [ -d "$root/tests" ] || return 0
  # Portable (no GNU find -printf; no nullglob dependency in a sourced context).
  for f in "$root"/tests/test-*.sh; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf '%s\n' "$base"
  done | sort -u
}

# Internal: emit basenames referenced by the curated suite sources under $1.
# Wired = named in tests/herd.bats (the bats gate + run-suite curated mode parse the same file).
_herd_tw_list_wired() {
  local root="$1" bats="$root/tests/herd.bats"
  [ -f "$bats" ] || return 0
  # Same extraction as scripts/ci/run-suite.sh curated mode so the two never disagree.
  grep -oE 'test-[a-z0-9-]+\.sh' "$bats" 2>/dev/null | sort -u
}

# Internal: emit "name<TAB>reason" rows from the exempt allowlist (comments/blank skipped).
_herd_tw_list_exempt() {
  local root="$1" f="$root/tests/test-wiring-exempt.tsv"
  [ -f "$f" ] || return 0
  # Columns: name<TAB>reason (reason required, non-empty). Header row "name\treason" ignored.
  while IFS=$'\t' read -r name reason || [ -n "$name" ]; do
    case "$name" in ''|'#'*) continue ;; esac
    [ "$name" = "name" ] && continue
    printf '%s\t%s\n' "$name" "${reason:-}"
  done < "$f"
}

herd_test_wiring_lint() {
  local root="${1:-.}"
  local errs="" name reason
  # Portable: temp lists + grep -qxF (no associative arrays required).

  HERD_TEST_WIRING_SKIP_REASON=""
  root="$(cd "$root" 2>/dev/null && pwd)" || {
    HERD_TEST_WIRING_SKIP_REASON="root not resolvable"
    return 2
  }

  if [ ! -d "$root/tests" ]; then
    HERD_TEST_WIRING_SKIP_REASON="no tests/ directory (not an engine suite tree)"
    return 2
  fi

  local tests_list wired_list exempt_list
  tests_list="$(_herd_tw_list_tests "$root")"
  if [ -z "$tests_list" ]; then
    HERD_TEST_WIRING_SKIP_REASON="no tests/test-*.sh files"
    return 2
  fi

  # Consuming projects without a curated bats gate are not subject to this ratchet.
  if [ ! -f "$root/tests/herd.bats" ]; then
    HERD_TEST_WIRING_SKIP_REASON="no tests/herd.bats (not the herdkit engine suite)"
    return 2
  fi

  wired_list="$(_herd_tw_list_wired "$root")"
  exempt_list="$(_herd_tw_list_exempt "$root")"

  # ── phantom exempt rows (name not a real test-*.sh) ──────────────────────────────────────────
  while IFS=$'\t' read -r name reason || [ -n "${name:-}" ]; do
    [ -n "$name" ] || continue
    if ! printf '%s\n' "$tests_list" | grep -qxF "$name"; then
      errs="${errs}EXEMPT phantom: $name (no tests/$name — drop the exempt row or restore the file)"$'\n'
      continue
    fi
    if [ -z "${reason// /}" ]; then
      errs="${errs}EXEMPT missing reason: $name (every exempt row needs a non-empty reason)"$'\n'
    fi
  done <<EOF
$exempt_list
EOF

  # ── each test-*.sh must be wired OR exempt ───────────────────────────────────────────────────
  while IFS= read -r name || [ -n "${name:-}" ]; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$wired_list" | grep -qxF "$name"; then
      continue
    fi
    if printf '%s\n' "$exempt_list" | cut -f1 | grep -qxF "$name"; then
      continue
    fi
    errs="${errs}UNWIRED: $name (add a @test in tests/herd.bats that runs it, or list it in tests/test-wiring-exempt.tsv with a reason)"$'\n'
  done <<EOF
$tests_list
EOF

  [ -n "$errs" ] || return 0
  printf '%s' "$errs"
  return 1
}
