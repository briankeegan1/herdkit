#!/usr/bin/env bash
# journal-test-env.sh — HERD-223 shared TEST layer: pin JOURNAL_FILE to a throwaway path so a
# hermetic fixture that journals can never append to the live project journal.
#
# Source this from a hermetic test (or the suite runner) BEFORE any engine script that may call
# journal_append. Idempotent: does not override an already-exported JOURNAL_FILE (tests that assert
# on a specific journal keep their own seam). Also exports HERD_JOURNAL_HERMETIC=1 so the fail-safe
# guard in journal.sh still redirects even if a child unsets JOURNAL_FILE.
#
# HERD-363 PER-RUN KEYING: the idempotency above must NOT keep a value pinned by a DIFFERENT process
# instance. Two suite instances running concurrently in the same environment (a tree run + the
# HERD-361 baseline leg) would otherwise share one journal, so a journal-grepping test counts the
# other run's events. When THIS seam pins, it stamps HERD_JOURNAL_PIN_PID with the pinning pid; a
# later source in the SAME process (pid match) keeps the value — a value inherited from ANOTHER
# process (pid mismatch) is re-pinned to a fresh per-run path. A value with NO pin stamp (an explicit
# user pin, or the healthcheck.project.sh suite pin that leaf fixtures deliberately share) is always
# respected, so a single suite run stays byte-identical apart from the path suffix. Per-PROCESS keying
# ($$), never per-seat — multi-seat safe, and $$ is portable to bash 3.2 (unlike BASHPID).
#
# INERT in production: never sourced by the live watcher, builders, or CLI on a real project.
# Companion of the HERD-189 daemon-hermeticity sandbox in .herd/healthcheck.project.sh.
#
# Usage (in a test):
#   T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
#   # shellcheck source=scripts/herd/journal-test-env.sh
#   . "$(cd "$(dirname "$0")/.." && pwd)/scripts/herd/journal-test-env.sh" "$T"
#   # JOURNAL_FILE is now $T/journal.<pid>.jsonl (or whatever you already exported)

_herd_journal_test_env() {
  local dir="${1:-}"
  # Re-pin when the current JOURNAL_FILE was pinned by THIS seam in a DIFFERENT process (HERD-363).
  local _pinned_by_other=""
  if [ -n "${JOURNAL_FILE:-}" ] && [ -n "${HERD_JOURNAL_PIN_PID:-}" ] \
     && [ "${HERD_JOURNAL_PIN_PID}" != "$$" ]; then
    _pinned_by_other=1
  fi
  if [ -z "${JOURNAL_FILE:-}" ] || [ -n "$_pinned_by_other" ]; then
    if [ -z "$dir" ]; then
      dir="$(mktemp -d "${TMPDIR:-/tmp}/herd-jherm.XXXXXX" 2>/dev/null \
        || { d="${TMPDIR:-/tmp}/herd-jherm-$$"; mkdir -p "$d"; printf '%s' "$d"; })"
    else
      mkdir -p "$dir" 2>/dev/null || true
    fi
    export JOURNAL_FILE="${dir%/}/journal.$$.jsonl"
    export HERD_JOURNAL_PIN_PID="$$"
    : >> "$JOURNAL_FILE" 2>/dev/null || true
  fi
  # Signal the journal.sh fail-safe even if a descendant unsets JOURNAL_FILE.
  export HERD_JOURNAL_HERMETIC=1
}

_herd_journal_test_env "$@"
unset -f _herd_journal_test_env
