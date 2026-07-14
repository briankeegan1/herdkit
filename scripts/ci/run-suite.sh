#!/usr/bin/env bash
# scripts/ci/run-suite.sh — the cross-platform CI test-suite runner.
#
# Runs the CURATED hermetic suite — the exact tests/test-*.sh files the auto-merge watcher's
# gate (tests/herd.bats) wraps — directly, one process per test, each with a per-test timeout.
#
# WHY DIRECT AND NOT `bats`: a `bats` run over this suite HANGS on a headless CI leg. A hermetic
# test that leaks a background process (a watcher/drainer that outlives the test) inherits bats's
# internal FD 3, and bats blocks on that FD's EOF forever — after the test itself has passed, so
# BATS_TEST_TIMEOUT can't catch it. Running each test as `timeout N bash test.sh >logfile` is
# immune: the shell waits only on its DIRECT child (bash), never on a leaked grandchild, and the
# leaked process writes to a plain file, not a pipe anyone reads. (The watcher still gates on bats
# on the maintainer's box, where herdr is present and nothing leaks — this runner mirrors WHICH
# tests it runs, not the harness.) NOTE: herd.bats's 3 INLINE structural @tests (bash -n clean,
# no-single-consumer-literal, render-no-leftover-tokens) are not wrapped test files and so are not
# run here; they are covered by the healthcheck (bash -n) and the watcher's heavy gate.
#
# HONEST env-sensitive handling: some tests only pass in the maintainer's blessed environment (see
# tests/known-env-sensitive.tsv). A listed test that fails on a matching platform is reported as
# XFAIL and does NOT fail the leg; an UNLISTED failure (incl. a timeout) is a real red. Mark, never
# silently skip, never hack green (the PR #274 convention).
#
# Exit: 0 = no real failures (env-sensitive XFAILs allowed) · 1 = a real failure · 2 = usage/setup.
#
# Env knobs (used by the CI workflow and by tests/test-ci-run-suite.sh):
#   HERD_CI_PLATFORM     ubuntu | macos | windows   (default: derived from uname)
#   HERD_CI_TESTS_DIR    directory holding the tests (default: <repo>/tests)
#   HERD_CI_TEST_GLOB    test filename glob for ALL-mode (default: test-*.sh)
#   HERD_CI_ALLOWLIST    env-sensitive allowlist tsv (default: <tests>/known-env-sensitive.tsv)
#   HERD_CI_TEST_TIMEOUT per-test timeout seconds    (default: 180; needs coreutils timeout/gtimeout)
#   HERD_CI_FORCE_DIRECT 1 = run ALL test-*.sh (the glob), not just the curated herd.bats subset
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

TESTS_DIR="${HERD_CI_TESTS_DIR:-$ROOT/tests}"
TEST_GLOB="${HERD_CI_TEST_GLOB:-test-*.sh}"
ALLOWLIST="${HERD_CI_ALLOWLIST:-$TESTS_DIR/known-env-sensitive.tsv}"
CURATED_SRC="$TESTS_DIR/herd.bats"
PER_TEST_TIMEOUT="${HERD_CI_TEST_TIMEOUT:-120}"

# `herd reload` (exercised by test-cli-backend-switch and others) relaunches a HEADLESS background
# watcher when herdr is absent — which a clean CI runner always is. That daemon lingers, holding the
# test's output pipe open, so the test's own `$(herd reload …)` never returns (hang) or the test runs
# for minutes retrying. HERD_RELOAD_SKIP_LAUNCH=1 is the engine's built-in test/CI knob that skips the
# watcher launch (the reload still re-renders the skill + reports "skipped"); with it the suite runs
# clean in ~70s with no leaked daemons. Harmless where herdr IS present (nothing to leak).
export HERD_RELOAD_SKIP_LAUNCH="${HERD_RELOAD_SKIP_LAUNCH:-1}"

# HERD-223 JOURNAL HERMETICITY (shared TEST layer): pin JOURNAL_FILE to a throwaway path so a
# fixture that journals cannot append to a live project journal (mirrors the dogfood healthcheck
# sandbox + scripts/herd/journal-test-env.sh). HERD_JOURNAL_HERMETIC keeps the journal.sh fail-safe
# armed even if a child unsets JOURNAL_FILE. A test that needs its own journal re-exports JOURNAL_FILE.
#
# HERD-363 PER-RUN KEYING: this is a SUITE runner, so it must not inherit a journal pinned by ANOTHER
# suite instance running concurrently in the same environment (else the two runs share one file and a
# journal-grepping test counts the other's events). Suffix the path with THIS process's pid and stamp
# HERD_JOURNAL_PIN_PID; re-pin an inherited value only when it was pinned by a DIFFERENT process
# (pid mismatch). A value with no pin stamp (an explicit caller pin) is respected — byte-identical for
# a standalone CI run apart from the path suffix. Per-PROCESS keying ($$), never per-seat.
_hk_ci_jh_dir="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/herd-ci-jherm-$$")"
mkdir -p "$_hk_ci_jh_dir" 2>/dev/null || true
if [ -z "${JOURNAL_FILE:-}" ] \
   || { [ -n "${HERD_JOURNAL_PIN_PID:-}" ] && [ "${HERD_JOURNAL_PIN_PID}" != "$$" ]; }; then
  export JOURNAL_FILE="$_hk_ci_jh_dir/journal.$$.jsonl"
  export HERD_JOURNAL_PIN_PID="$$"
fi
: >> "$JOURNAL_FILE" 2>/dev/null || true
export HERD_JOURNAL_HERMETIC=1
trap 'rm -rf "$_hk_ci_jh_dir"' EXIT

# ── platform detection (overridable so tests are deterministic) ──────────────────
detect_platform() {
  if [ -n "${HERD_CI_PLATFORM:-}" ]; then printf '%s\n' "$HERD_CI_PLATFORM"; return; fi
  case "$(uname -s 2>/dev/null)" in
    Linux)                       echo "ubuntu" ;;
    Darwin)                      echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*|Windows*) echo "windows" ;;
    *)                           echo "unknown" ;;
  esac
}
PLATFORM="$(detect_platform)"

# ── a per-test timeout wrapper, if the coreutils binary is present (else run bare) ─
TO=""
for _c in timeout gtimeout; do
  if command -v "$_c" >/dev/null 2>&1; then TO="$_c $PER_TEST_TIMEOUT"; break; fi
done

# ── allowlist lookup ─────────────────────────────────────────────────────────────
# A test is env-sensitive on this platform if a row `name<TAB>platforms<TAB>reason`
# lists it (by test-file basename) with either the current platform or `all` in the CSV
# platforms column. Returns the reason on stdout (rc 0) or nothing (rc 1).
allow_reason() {
  local name="$1"
  [ -f "$ALLOWLIST" ] || return 1
  while IFS=$'\t' read -r a_name a_plats a_reason; do
    case "$a_name" in ''|'#'*) continue ;; esac
    [ "$a_name" = "$name" ] || continue
    case ",${a_plats}," in
      *",${PLATFORM},"*|*",all,"*) printf '%s\n' "${a_reason:-env-sensitive}"; return 0 ;;
    esac
  done < "$ALLOWLIST"
  return 1
}

# ── select the test files: curated (the exact set the bats gate runs) by default, else the glob ──
tests=()
if [ "${HERD_CI_FORCE_DIRECT:-0}" != "1" ] && [ -f "$CURATED_SRC" ]; then
  MODE="curated"
  # PARSE GUARD (HERD-172): curated mode runs the SAME test-*.sh files the bats gate exercises,
  # DIRECTLY — it never parses herd.bats AS bats. So a bats PARSE error (an unclosed / merged @test
  # block) is invisible here and only dies later in the full-suite health gate; that is exactly how a
  # corrupted herd.bats once rode a green CI. Reject it cheaply. A raw .bats file is NOT valid bash
  # (its bare `}` close a `{` that bash never saw in command position), so approximate bats's own
  # transform — rewrite each `@test "…" {` header into a function opener — then `bash -n` the result.
  # A block left unclosed leaves an unbalanced brace, which surfaces as an EOF syntax error: fail CI
  # here instead of silently skipping. Well-formed @tests transform to balanced functions and pass.
  if ! sed -E 's/^[[:space:]]*@test[[:space:]].*\{[[:space:]]*$/__herd_bats_test() {/' "$CURATED_SRC" | bash -n 2>/dev/null; then
    echo "❌ $CURATED_SRC does not parse as bats (unclosed / merged @test block) — the full-suite health gate would die on it." >&2
    echo "   Reproduce:  sed -E 's/^[[:space:]]*@test .*\\{\$/f() {/' \"$CURATED_SRC\" | bash -n" >&2
    exit 2
  fi
  # SELECTION (HERD-295): tests/herd.bats now GLOBS tests/test-*.sh (dynamic discovery) rather than
  # naming each test, so we can no longer grep names out of it. Mirror the gate exactly by globbing
  # test-*.sh and subtracting the SAME exempt list the bats discovery loop and gate-coverage-lint use
  # (tests/gate-coverage-exempt.tsv — flaky/live-env files kept out of the hermetic gate). The bespoke
  # hand-written @test blocks (e.g. test-codemap-project.sh) are NOT on the exempt list, so they are
  # selected here too — this runner runs every file, whether the gate reaches it via discovery or a block.
  EXEMPT_FILE="$TESTS_DIR/gate-coverage-exempt.tsv"
  shopt -s nullglob
  for f in "$TESTS_DIR"/test-*.sh; do
    base="$(basename "$f")"
    if [ -f "$EXEMPT_FILE" ] && grep -qxF -- "$base" "$EXEMPT_FILE" 2>/dev/null; then
      continue
    fi
    tests+=("$f")
  done
  shopt -u nullglob
else
  MODE="all"
  shopt -s nullglob
  tests=( "$TESTS_DIR"/$TEST_GLOB )
  shopt -u nullglob
fi
if [ "${#tests[@]}" -eq 0 ]; then
  echo "❌ no tests selected (mode=$MODE, dir=$TESTS_DIR)" >&2
  exit 2
fi

# ── run each test in its own process, classify the result ────────────────────────
pass=0; real_fail=0; xfail=0
real_names=(); xfail_names=()
LOGDIR="$(mktemp -d 2>/dev/null || echo /tmp/herd-ci-logs.$$)"; mkdir -p "$LOGDIR"
[ -n "$TO" ] || echo "⚠️  no timeout binary found — running tests without a per-test cap"
echo "▶ running ${#tests[@]} hermetic tests (mode=$MODE, timeout=${TO:-none}) on ${PLATFORM}"
for t in "${tests[@]}"; do
  name="$(basename "$t")"
  log="$LOGDIR/$name.log"
  # shellcheck disable=SC2086
  # HERMETIC_TEST names the fixture for journal.sh's fail-safe (and any other test-context guards).
  HERMETIC_TEST="$name" $TO bash "$t" </dev/null >"$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass=$((pass+1)); continue
  fi
  timedout=""; [ "$rc" -eq 124 ] && timedout=" (TIMEOUT after ${PER_TEST_TIMEOUT}s)"
  if reason="$(allow_reason "$name")"; then
    xfail=$((xfail+1)); xfail_names+=("$name — $reason")
    echo "⚠️  XFAIL (env-sensitive) $name$timedout: $reason"
  else
    real_fail=$((real_fail+1)); real_names+=("$name$timedout")
    echo "❌ FAIL $name$timedout — last lines:"
    tail -n 6 "$log" | sed 's/^/      │ /'
  fi
done

echo
echo "── CI suite summary (${PLATFORM}, mode=$MODE) ─────────────────"
echo "   passed:                $pass"
echo "   XFAIL (env-sensitive): $xfail"
echo "   real failures:         $real_fail"
if [ "$xfail" -gt 0 ]; then
  printf '   · %s\n' "${xfail_names[@]}"
fi
if [ "$real_fail" -gt 0 ]; then
  echo "   real-failed tests:"
  printf '     ✗ %s\n' "${real_names[@]}"
  echo "❌ CI SUITE FAILED on ${PLATFORM} ($real_fail real failure(s))"
  exit 1
fi
echo "✅ CI SUITE CLEAN on ${PLATFORM} ($pass passed, $xfail env-sensitive XFAIL)"
exit 0
