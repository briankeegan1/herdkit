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

# ── select the test files: curated (herd.bats subset) by default, else the glob ──
tests=()
if [ "${HERD_CI_FORCE_DIRECT:-0}" != "1" ] && [ -f "$CURATED_SRC" ]; then
  MODE="curated"
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$TESTS_DIR/$f" ] && tests+=("$TESTS_DIR/$f")
  done < <(grep -oE 'test-[a-z0-9-]+\.sh' "$CURATED_SRC" | sort -u)
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
  $TO bash "$t" </dev/null >"$log" 2>&1
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
