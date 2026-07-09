#!/usr/bin/env bash
# journal-test-env.sh — HERD-223 shared TEST layer: pin JOURNAL_FILE to a throwaway path so a
# hermetic fixture that journals can never append to the live project journal.
#
# Source this from a hermetic test (or the suite runner) BEFORE any engine script that may call
# journal_append. Idempotent: does not override an already-exported JOURNAL_FILE (tests that assert
# on a specific journal keep their own seam). Also exports HERD_JOURNAL_HERMETIC=1 so the fail-safe
# guard in journal.sh still redirects even if a child unsets JOURNAL_FILE.
#
# INERT in production: never sourced by the live watcher, builders, or CLI on a real project.
# Companion of the HERD-189 daemon-hermeticity sandbox in .herd/healthcheck.project.sh.
#
# Usage (in a test):
#   T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
#   # shellcheck source=scripts/herd/journal-test-env.sh
#   . "$(cd "$(dirname "$0")/.." && pwd)/scripts/herd/journal-test-env.sh" "$T"
#   # JOURNAL_FILE is now $T/journal.jsonl (or whatever you already exported)

_herd_journal_test_env() {
  local dir="${1:-}"
  if [ -z "${JOURNAL_FILE:-}" ]; then
    if [ -z "$dir" ]; then
      dir="$(mktemp -d "${TMPDIR:-/tmp}/herd-jherm.XXXXXX" 2>/dev/null \
        || { d="${TMPDIR:-/tmp}/herd-jherm-$$"; mkdir -p "$d"; printf '%s' "$d"; })"
    else
      mkdir -p "$dir" 2>/dev/null || true
    fi
    export JOURNAL_FILE="${dir%/}/journal.jsonl"
    : >> "$JOURNAL_FILE" 2>/dev/null || true
  fi
  # Signal the journal.sh fail-safe even if a descendant unsets JOURNAL_FILE.
  export HERD_JOURNAL_HERMETIC=1
}

_herd_journal_test_env "$@"
unset -f _herd_journal_test_env
