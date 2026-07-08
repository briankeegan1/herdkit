#!/usr/bin/env bash
# scripts/ci/run-suite.sh — the cross-platform CI test-suite runner.
#
# Mirrors the fallback in .herd/healthcheck.project.sh (the authoritative merge gate):
# run `bats tests/*.bats` when bats is installed and *.bats exist, otherwise run the
# hermetic `tests/test-*.sh` suite directly. The CI matrix (ubuntu/macos/windows) calls
# THIS so all three legs share one runner and one notion of "green".
#
# The one thing this adds over the healthcheck runner: honest handling of KNOWN
# ENV-SENSITIVE tests. Some hermetic tests assume a Unix layout that Git Bash on Windows
# does not provide — e.g. they rebuild a minimal PATH as `env -i ... PATH=/usr/bin:/bin`,
# where python3 lives on real Linux/macOS but NOT under Git-for-Windows (docs/windows.md).
# Those are listed, per-platform, in an allowlist. A listed test that fails is reported as
# XFAIL (env-sensitive) and does NOT fail the leg; an UNLISTED failure is a real red. This
# is the pass-with-skips convention (PR #274): mark, never silently skip, never hack green.
#
# Exit: 0 = no real failures (env-sensitive XFAILs allowed) · 1 = a real failure · 2 = usage/setup.
#
# Env knobs (used by the CI workflow and by tests/test-ci-run-suite.sh):
#   HERD_CI_PLATFORM     ubuntu | macos | windows   (default: derived from uname)
#   HERD_CI_TESTS_DIR    directory holding the tests (default: <repo>/tests)
#   HERD_CI_TEST_GLOB    test filename glob          (default: test-*.sh)
#   HERD_CI_ALLOWLIST    env-sensitive allowlist tsv (default: <tests>/known-env-sensitive.tsv)
#   HERD_CI_FORCE_DIRECT 1 = never use bats, always run *.sh directly (deterministic in tests)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

TESTS_DIR="${HERD_CI_TESTS_DIR:-$ROOT/tests}"
TEST_GLOB="${HERD_CI_TEST_GLOB:-test-*.sh}"
ALLOWLIST="${HERD_CI_ALLOWLIST:-$TESTS_DIR/known-env-sensitive.tsv}"

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

# ── allowlist lookup ─────────────────────────────────────────────────────────────
# A test is env-sensitive on this platform if a row `name<TAB>platforms<TAB>reason`
# lists it with either the current platform or the literal `all` in the CSV platforms
# column. Returns the reason on stdout (rc 0) or nothing (rc 1).
allow_reason() {
  local name="$1"
  [ -f "$ALLOWLIST" ] || return 1
  # Read tab-separated rows, skip blanks and comments.
  while IFS=$'\t' read -r a_name a_plats a_reason; do
    case "$a_name" in ''|'#'*) continue ;; esac
    [ "$a_name" = "$name" ] || continue
    case ",${a_plats}," in
      *",${PLATFORM},"*|*",all,"*) printf '%s\n' "${a_reason:-env-sensitive}"; return 0 ;;
    esac
  done < "$ALLOWLIST"
  return 1
}

# ── bats path (mirror the healthcheck) ───────────────────────────────────────────
if [ "${HERD_CI_FORCE_DIRECT:-0}" != "1" ] \
   && command -v bats >/dev/null 2>&1 \
   && ls "$TESTS_DIR"/*.bats >/dev/null 2>&1; then
  echo "▶ bats: running $TESTS_DIR/*.bats on ${PLATFORM}"
  # --print-output-on-failure surfaces the wrapped test's own stderr (bats otherwise shows only the
  # failed assertion line). Older bats-core lacks the flag → fall back to a plain run.
  bats_flags="--tap"
  bats --print-output-on-failure --version >/dev/null 2>&1 && bats_flags="--tap --print-output-on-failure"
  # shellcheck disable=SC2086
  bats_out="$(bats $bats_flags "$TESTS_DIR"/*.bats 2>&1)"; bats_rc=$?
  printf '%s\n' "$bats_out"
  if [ "$bats_rc" -eq 0 ]; then
    echo "✅ CI SUITE CLEAN (bats) on ${PLATFORM}"
    exit 0
  fi
  # A failure: classify each TAP `not ok <n> <description>` against the allowlist (keyed by the bats
  # DESCRIPTION for the bats path). An allowlisted failure on this platform is an XFAIL; any other is
  # a real red. Same honest convention as the direct path — mark, never silently pass.
  real=0; xf=0
  while IFS= read -r line; do
    case "$line" in
      "not ok "*) : ;;
      *) continue ;;
    esac
    desc="$(printf '%s' "$line" | sed -E 's/^not ok [0-9]+ //')"
    if reason="$(allow_reason "$desc")"; then
      xf=$((xf+1)); echo "⚠️  XFAIL (env-sensitive) bats: $desc — $reason"
    else
      real=$((real+1)); echo "❌ real bats failure: $desc"
    fi
  done <<EOF
$bats_out
EOF
  if [ "$real" -eq 0 ] && [ "$xf" -gt 0 ]; then
    echo "✅ CI SUITE CLEAN (bats) on ${PLATFORM} ($xf env-sensitive XFAIL, 0 real)"
    exit 0
  fi
  echo "❌ CI SUITE FAILED (bats) on ${PLATFORM} ($real real failure(s), $xf XFAIL)"
  exit 1
fi

# ── direct path: run every hermetic tests/test-*.sh, classify each result ─────────
shopt -s nullglob
tests=( "$TESTS_DIR"/$TEST_GLOB )
shopt -u nullglob
if [ "${#tests[@]}" -eq 0 ]; then
  echo "❌ no tests matched $TESTS_DIR/$TEST_GLOB" >&2
  exit 2
fi

pass=0; real_fail=0; xfail=0
real_names=(); xfail_names=()
LOGDIR="$(mktemp -d 2>/dev/null || echo /tmp/herd-ci-logs.$$)"; mkdir -p "$LOGDIR"
echo "▶ direct: running ${#tests[@]} hermetic tests on ${PLATFORM}"
for t in "${tests[@]}"; do
  name="$(basename "$t")"
  log="$LOGDIR/$name.log"
  if bash "$t" >"$log" 2>&1; then
    pass=$((pass+1))
  else
    if reason="$(allow_reason "$name")"; then
      xfail=$((xfail+1)); xfail_names+=("$name — $reason")
      echo "⚠️  XFAIL (env-sensitive) $name: $reason"
    else
      real_fail=$((real_fail+1)); real_names+=("$name")
      echo "❌ FAIL $name — last lines:"
      tail -n 6 "$log" | sed 's/^/      │ /'
    fi
  fi
done

echo
echo "── CI suite summary (${PLATFORM}) ─────────────────────────────"
echo "   passed:              $pass"
echo "   XFAIL (env-sensitive): $xfail"
echo "   real failures:       $real_fail"
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
