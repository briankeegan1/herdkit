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
#   HERD_CI_TEST_TIMEOUT per-test DEFAULT timeout seconds (default: 120; needs coreutils
#                        timeout/gtimeout) — the uniform floor for any test with no
#                        HERD_CI_TEST_CAP_LEDGER row; see that key below for per-test overrides.
#   HERD_CI_FORCE_DIRECT 1 = run ALL test-*.sh (the glob), not just the curated herd.bats subset
#   HERD_CI_ARTIFACTS_DIR dir for scorecard/per-rep artifacts from tests that support the shared
#                        `--artifacts DIR --keep` convention (default: a fresh mktemp -d). Written
#                        back to $GITHUB_ENV in CI so a failure-upload step can find it (HERD-436:
#                        the scorecard a chaos/sim test names on failure was never uploaded before).
#   HERD_CI_SHARD_INDEX / HERD_CI_SHARD_COUNT (HERD-463): run only the tests assigned to shard
#                        HERD_CI_SHARD_INDEX (1-based) of HERD_CI_SHARD_COUNT total, via a stable
#                        filename hash (scripts/herd/suite-shard.sh) — deterministic and balanced,
#                        so the CI matrix can fan a ~350-test, single-threaded ~20m curated run out
#                        across N machines. Both default to 1 (shard 1 of 1 = every curated test),
#                        so an invocation that never sets these is byte-identical to today's
#                        unsharded run. DOES NOT REDUCE what runs — every shard's union, across a
#                        full matrix row, is the same curated set an unsharded run selects
#                        (mutation-proven by tests/test-suite-shard.sh). "all" mode
#                        (HERD_CI_FORCE_DIRECT=1) ignores sharding — it is a debug/full-glob mode,
#                        not the gate.
#   HERD_CI_SCOPE_BASE_REF / HERD_CI_SCOPE_REPO (HERD-664): DIFF-SCOPED selection. When
#                        HERD_CI_SCOPE_BASE_REF names a base ref (the CI workflow passes
#                        `origin/<pr base branch>` for a pull_request, and NOTHING for a push to
#                        main), the runner diffs HEAD against its merge-base with that ref and runs
#                        only the curated tests that diff can affect — scoping FIRST, then sharding
#                        the SCOPED set, so a shard whose scoped slice is empty exits green fast.
#                        The selection itself (name-pairing + `# suite-deps:` headers + the
#                        always-run core + FAIL-CLOSED on any wide-blast or unmappable path) is
#                        scripts/herd/suite-shard.sh's herd_suite_tests_for_diff — ONE
#                        implementation shared with the local heavy gate, mutation-proven by
#                        tests/test-suite-scope.sh. UNSET (the default, and what a main push gets) is
#                        byte-identical to the pre-HERD-664 full sharded run, and so is every
#                        fail-closed path: a wide-blast/unmappable diff, or a diff that cannot be
#                        obtained at all, runs the ENTIRE curated sharded set. Whatever it selects is
#                        announced loudly ("scoped N of M curated tests (reason)") — never a silent
#                        cap. HERD_CI_SCOPE_REPO is the git repo the diff is computed in (default:
#                        this checkout, $ROOT); tests point it at a fixture.
#   HERD_CI_TEST_CAP_LEDGER (HERD-478): tsv path naming PER-TEST timeout overrides (default:
#                        <tests-dir>/test-caps.tsv). A test named there runs under its own row's
#                        cap-secs instead of HERD_CI_TEST_TIMEOUT; every other test is unaffected —
#                        an absent/empty ledger is byte-identical to the pre-HERD-478 uniform cap.
#                        See scripts/herd/test-cap-ledger.sh for the ledger format + the stale-row
#                        lint that keeps it honest.
#   HERD_CI_SUITE_WORKERS (HERD-665): BOUNDED INTRA-SHARD PARALLELISM. Tests within one shard run
#                        SERIALLY on a multi-core runner by default (1 = today's exact behavior,
#                        byte-identical: launch, wait, classify, repeat — same order, same output).
#                        A value > 1 runs up to that many tests concurrently (a FIFO job queue, not
#                        `wait -n` — macOS's system bash is 3.2 and lacks it), still one process per
#                        test with its own per-test timeout and log file. SHIP-DORMANT: the knob
#                        defaults to 1 because ~4% of the curated suite (test-config-manifest.sh,
#                        test-py-statemachine.sh, the test-sandbox-posture-matrix-*.sh family, …)
#                        never mktemp's its own workspace, and the whole suite shares ONE JOURNAL_FILE
#                        (see the HERD-363 per-run keying below) — an append-heavy test racing another
#                        under concurrency has not been proven safe, only spot-checked. Measure before
#                        raising it in CI; this env var is the only thing that changes when you do.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

TESTS_DIR="${HERD_CI_TESTS_DIR:-$ROOT/tests}"
TEST_GLOB="${HERD_CI_TEST_GLOB:-test-*.sh}"
ALLOWLIST="${HERD_CI_ALLOWLIST:-$TESTS_DIR/known-env-sensitive.tsv}"
CURATED_SRC="$TESTS_DIR/herd.bats"
PER_TEST_TIMEOUT="${HERD_CI_TEST_TIMEOUT:-120}"
CAP_LEDGER="${HERD_CI_TEST_CAP_LEDGER:-$TESTS_DIR/test-caps.tsv}"
SHARD_INDEX="${HERD_CI_SHARD_INDEX:-1}"
SHARD_COUNT="${HERD_CI_SHARD_COUNT:-1}"
SCOPE_BASE_REF="${HERD_CI_SCOPE_BASE_REF:-}"
SCOPE_REPO="${HERD_CI_SCOPE_REPO:-$ROOT}"
case "$SHARD_INDEX" in ''|*[!0-9]*) SHARD_INDEX=1 ;; esac
case "$SHARD_COUNT" in ''|*[!0-9]*) SHARD_COUNT=1 ;; esac
[ "$SHARD_COUNT" -ge 1 ] 2>/dev/null || SHARD_COUNT=1
# HERD-665 bounded intra-shard parallelism — see the header doc above. Garbage/unset falls back to 1
# (serial), never to 0 (which would launch every test at once with no cap).
SUITE_WORKERS="${HERD_CI_SUITE_WORKERS:-1}"
case "$SUITE_WORKERS" in ''|*[!0-9]*) SUITE_WORKERS=1 ;; esac
[ "$SUITE_WORKERS" -ge 1 ] 2>/dev/null || SUITE_WORKERS=1
# shellcheck source=scripts/herd/suite-shard.sh
if [ -f "$ROOT/scripts/herd/suite-shard.sh" ]; then
  . "$ROOT/scripts/herd/suite-shard.sh"
elif [ "$SHARD_COUNT" -gt 1 ]; then
  echo "❌ HERD_CI_SHARD_COUNT=$SHARD_COUNT but scripts/herd/suite-shard.sh is missing — refusing to guess a partial suite" >&2
  exit 2
fi
# HERD-478: per-test timeout ledger. Fail-soft on our own infra — a partially-upgraded tree missing
# the library must fall back to the uniform PER_TEST_TIMEOUT for every test, never break the run.
# shellcheck source=scripts/herd/test-cap-ledger.sh
if [ -f "$ROOT/scripts/herd/test-cap-ledger.sh" ]; then
  . "$ROOT/scripts/herd/test-cap-ledger.sh"
else
  herd_test_cap_for() { printf '%s' "$PER_TEST_TIMEOUT"; }
fi

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

# HERD-458 HERMETIC-ENV SCRUB: this runner is a direct-invocation chokepoint too (a human or a CI leg
# can run it from a shell that already sourced herd-config.sh against a CONFIGURED .herd/config) — the
# HERD-449 export sweep would otherwise leak those live values past every hermetic test's own
# `: "${KEY:=default}"` default assertion below, the same shape the JOURNAL_FILE pin above guards
# against for one key. unset the whole export surface ONCE, derived from herd-config.sh itself so it
# can never drift. A plain GitHub Actions runner never sourced herd-config.sh, so this is a byte-
# identical no-op there. See scripts/herd/hermetic-env-scrub.sh; kept in lockstep with
# tests/test-hermetic-env-scrub.sh.
if [ -f "$ROOT/scripts/herd/hermetic-env-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/scripts/herd/hermetic-env-scrub.sh"
  herd_hermetic_env_scrub "$ROOT/scripts/herd/herd-config.sh"
fi

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
# TO_BIN names the binary only; the actual cap-secs is resolved PER TEST below (HERD-478: a listed
# test in $CAP_LEDGER runs under its own row's cap-secs instead of $PER_TEST_TIMEOUT).
TO_BIN=""
for _c in timeout gtimeout; do
  if command -v "$_c" >/dev/null 2>&1; then TO_BIN="$_c"; break; fi
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

# ── HERD-664 DIFF-SCOPED SELECTION: the changed paths this run is scoped to ──────
# Prints the paths changed between HEAD and its merge-base with <base-ref>, one per line; returns 1
# when the diff CANNOT be obtained (no git, not a repo, an unresolvable base ref, a shallow clone
# with no common ancestor). Every one of those is answered by the caller with the FULL curated set —
# "we could not tell what changed" must never read as "nothing changed".
scope_changed_paths() {
  local _scp_base="$1" _scp_mb _scp_out
  [ -n "$_scp_base" ] || return 1
  command -v git >/dev/null 2>&1 || return 1
  git -C "$SCOPE_REPO" rev-parse --git-dir >/dev/null 2>&1 || return 1
  _scp_mb="$(git -C "$SCOPE_REPO" merge-base "$_scp_base" HEAD 2>/dev/null)" || return 1
  [ -n "$_scp_mb" ] || return 1
  # --no-renames on purpose: with rename detection ON, a moved file is reported ONLY under its NEW
  # path, so the OLD path — whose paired test may be the one that actually covers the move — never
  # reaches the selection rules. Listing both halves keeps the mapping (and its fail-closed fallback)
  # working on a rename.
  _scp_out="$(git -C "$SCOPE_REPO" diff --no-renames --name-only "$_scp_mb" HEAD 2>/dev/null)" || return 1
  printf '%s\n' "$_scp_out"
  return 0
}

# ── select the test files: curated (the exact set the bats gate runs) by default, else the glob ──
SCOPE_MODE="full"     # "diff" only once a NARROWER-than-curated selection has actually been proven
SCOPE_REASON=""
SCOPE_SEL=""
SCOPE_N=0
SCOPE_TOTAL=0
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
  # HERD-463: the selection itself now lives in scripts/herd/suite-shard.sh (herd_suite_tests_for_shard),
  # ONE implementation shared with tests/test-suite-shard.sh's mutation-prove membership check, so the
  # curated glob-minus-exempt logic can never drift between the two. SHARD_COUNT=1 (the default) selects
  # every curated test — byte-identical to the pre-shard unsharded selection.
  EXEMPT_FILE="$TESTS_DIR/gate-coverage-exempt.tsv"
  # HERD-664: SCOPE FIRST, THEN SHARD. Sharding splits the same work across boxes; scoping asks which
  # of the curated tests this diff can actually break. Doing it in this order is what lets a shard
  # whose scoped slice is empty exit green immediately instead of paying for a runner that had
  # nothing to run. The selection is herd_suite_tests_for_diff's (ONE implementation, shared with the
  # local heavy gate and mutation-proven by tests/test-suite-scope.sh); this file only decides
  # WHETHER to scope and then applies the SAME herd_suite_shard_of partition to whatever came back —
  # so the scoped-then-sharded union across a full matrix row is exactly the scoped selection
  # (mutation-proven by tests/test-suite-shard.sh check 9).
  #
  # FAIL-CLOSED, three ways, each announced: no base ref (a push to main, or any caller that never
  # opts in) → full; the diff cannot be obtained → full; the selection comes back AS the whole curated
  # set (a wide-blast or unmappable path) → full, reached by the SAME herd_suite_tests_for_shard call
  # as before so the run is byte-identical to a pre-HERD-664 one.
  if [ -n "$SCOPE_BASE_REF" ] && command -v herd_suite_tests_for_diff >/dev/null 2>&1; then
    scope_curated="$(herd_suite_curated_tests "$TESTS_DIR" "$EXEMPT_FILE")"
    SCOPE_TOTAL="$(printf '%s\n' "$scope_curated" | grep -c .)"
    SCOPE_N="$SCOPE_TOTAL"
    if scope_raw="$(scope_changed_paths "$SCOPE_BASE_REF")"; then
      scope_paths=()
      while IFS= read -r scope_p; do
        [ -n "$scope_p" ] && scope_paths+=("$scope_p")
      done <<EOF
$scope_raw
EOF
      if [ "${#scope_paths[@]}" -eq 0 ]; then
        SCOPE_REASON="fail-closed: the diff vs '$SCOPE_BASE_REF' named no changed path"
      else
        scope_try="$(herd_suite_tests_for_diff "$TESTS_DIR" "${scope_paths[@]}")"
        if [ -z "$scope_try" ] || [ "$scope_try" = "$scope_curated" ]; then
          SCOPE_REASON="fail-closed: a wide-blast or unmappable path among ${#scope_paths[@]} changed path(s) vs '$SCOPE_BASE_REF'"
        else
          SCOPE_MODE="diff"
          SCOPE_SEL="$scope_try"
          SCOPE_N="$(printf '%s\n' "$SCOPE_SEL" | grep -c .)"
          SCOPE_REASON="${#scope_paths[@]} changed path(s) vs merge-base with '$SCOPE_BASE_REF'"
        fi
      fi
    else
      SCOPE_REASON="fail-closed: cannot diff HEAD against '$SCOPE_BASE_REF' in $SCOPE_REPO"
    fi
    echo "🔎 scoped $SCOPE_N of $SCOPE_TOTAL curated tests ($SCOPE_REASON)"
  elif [ -n "$SCOPE_BASE_REF" ]; then
    # A partially-upgraded tree: a base ref was passed, but this checkout's suite-shard.sh predates
    # diff-scoped selection. Fall back to the full curated set — loudly, never silently.
    echo "⚠️  HERD_CI_SCOPE_BASE_REF='$SCOPE_BASE_REF' but this tree's scripts/herd/suite-shard.sh has no diff-scoped selection — running the FULL curated set"
  fi
  if [ "$SCOPE_MODE" = "diff" ]; then
    # The scoped set, partitioned by the SAME stable filename hash the unscoped path uses.
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      [ "$(herd_suite_shard_of "$base" "$SHARD_COUNT")" = "$SHARD_INDEX" ] || continue
      tests+=("$TESTS_DIR/$base")
    done <<EOF
$SCOPE_SEL
EOF
  else
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      tests+=("$TESTS_DIR/$base")
    done < <(herd_suite_tests_for_shard "$TESTS_DIR" "$SHARD_INDEX" "$SHARD_COUNT" "$EXEMPT_FILE")
  fi
else
  MODE="all"
  shopt -s nullglob
  tests=( "$TESTS_DIR"/$TEST_GLOB )
  shopt -u nullglob
fi
if [ "${#tests[@]}" -eq 0 ]; then
  # HERD-664: under a PROVEN diff-scoped selection an empty slice is the point, not a misconfiguration
  # — none of the tests this diff can break hashed into this shard, so this runner is done. Loud and
  # green, never silent. Every other empty selection (a bad shard index, an empty tests dir, a scoped
  # selection that somehow came back empty) is still the setup error it always was.
  if [ "$SCOPE_MODE" = "diff" ] && [ "$SCOPE_N" -gt 0 ]; then
    echo "✅ shard $SHARD_INDEX/$SHARD_COUNT has NO scoped tests — none of the $SCOPE_N scoped (of $SCOPE_TOTAL curated) tests hash to this shard"
    exit 0
  fi
  echo "❌ no tests selected (mode=$MODE, dir=$TESTS_DIR)" >&2
  exit 2
fi

# ── run each test in its own process, classify the result ────────────────────────
pass=0; real_fail=0; xfail=0
real_names=(); xfail_names=()
LOGDIR="$(mktemp -d 2>/dev/null || echo /tmp/herd-ci-logs.$$)"; mkdir -p "$LOGDIR"
# ARTROOT (HERD-436): a per-test scratch dir for the sim/chaos tests that already support the shared
# `--artifacts DIR --keep` convention (test-gate-reconciler-chaos-sim.sh, test-merge-queue-sim.sh,
# test-merge-result-gate-sim.sh). Passing it in — instead of letting each test mktemp+delete its own
# ART on EXIT — is what makes the scorecard.json / per-rep detail a failing test names survive past
# the test's own process, so a CI upload step (or a human) can actually read it.
ARTROOT="${HERD_CI_ARTIFACTS_DIR:-$(mktemp -d 2>/dev/null || echo /tmp/herd-ci-artifacts.$$)}"
mkdir -p "$ARTROOT"
if [ -n "${GITHUB_ENV:-}" ]; then
  { echo "HERD_CI_LOGDIR=$LOGDIR"; echo "HERD_CI_ARTIFACTS_DIR=$ARTROOT"; } >> "$GITHUB_ENV"
fi
[ -n "$TO_BIN" ] || echo "⚠️  no timeout binary found — running tests without a per-test cap"
shard_note=""
[ "$SHARD_COUNT" -gt 1 ] && shard_note=", shard=$SHARD_INDEX/$SHARD_COUNT"
# HERD-664: carried into the run header AND the summary banner, so a log read from either end says
# what this leg actually covered. Empty (byte-identical) whenever the run was not narrowed.
scope_note=""
[ "$SCOPE_MODE" = "diff" ] && scope_note=", scoped=$SCOPE_N/$SCOPE_TOTAL"
cap_note=""
if [ -f "$CAP_LEDGER" ]; then
  cap_rows="$(grep -vE '^[[:space:]]*(#|test[[:space:]])' "$CAP_LEDGER" 2>/dev/null | grep -c .)" || cap_rows=0
  [ "$cap_rows" -gt 0 ] && cap_note=", $cap_rows ledger override(s)"
fi
timeout_note="default-timeout=none"
[ -n "$TO_BIN" ] && timeout_note="default-timeout=${PER_TEST_TIMEOUT}s"
worker_note=""
[ "$SUITE_WORKERS" -gt 1 ] && worker_note=", workers=$SUITE_WORKERS"
echo "▶ running ${#tests[@]} hermetic tests (mode=$MODE, ${timeout_note}${cap_note}${shard_note}${scope_note}${worker_note}) on ${PLATFORM}"

# classify_result <name> <log> <test_artdir> <extra_argc> <cap> <rc> — the HERD-478/HERD-436 pass/
# XFAIL/FAIL bookkeeping, factored out so it runs identically whether the test just ran in the
# foreground (SUITE_WORKERS=1) or was waited on out of the FIFO job queue below (SUITE_WORKERS>1).
classify_result() {
  local c_name="$1" c_log="$2" c_artdir="$3" c_extra_argc="$4" c_cap="$5" c_rc="$6" c_timedout c_reason
  if [ "$c_rc" -eq 0 ]; then
    pass=$((pass+1))
    [ "$c_extra_argc" -eq 0 ] || rm -rf "$c_artdir"  # green: nothing worth keeping
    return
  fi
  c_timedout=""; [ "$c_rc" -eq 124 ] && c_timedout=" (TIMEOUT after ${c_cap}s)"
  if c_reason="$(allow_reason "$c_name")"; then
    xfail=$((xfail+1)); xfail_names+=("$c_name — $c_reason")
    echo "⚠️  XFAIL (env-sensitive) $c_name$c_timedout: $c_reason"
    [ "$c_extra_argc" -eq 0 ] || rm -rf "$c_artdir"
  else
    real_fail=$((real_fail+1)); real_names+=("$c_name$c_timedout")
    echo "❌ FAIL $c_name$c_timedout"
    # HERD-436: a wrapper test that runs many checkpoints (e.g. multiple chaos-sim reps) can scroll
    # its own failing assertion off the top of a plain tail long before the wrapper's final summary
    # line — print every checkpoint the test itself reported as failed, not just the last 6 lines.
    if grep -qE '^FAIL[: ]' "$c_log"; then
      echo "   failing checkpoints:"
      grep -E '^FAIL[: ]' "$c_log" | sed 's/^/      │ /'
    fi
    echo "   last lines:"
    tail -n 10 "$c_log" | sed 's/^/      │ /'
    if [ -d "$c_artdir" ]; then
      echo "   artifacts kept: $c_artdir"
    fi
  fi
}

# HERD-665: a FIFO queue of up to $SUITE_WORKERS in-flight tests. At SUITE_WORKERS=1 this backgrounds
# one test and immediately waits on it before launching the next — same order, same output, same
# process-per-test-with-its-own-timeout shape as the old inline `bash "$t"` foreground call. `wait -n`
# (which would let the FIRST-TO-FINISH job drain, not necessarily the oldest) is unavailable on
# macOS's bash 3.2, so this waits on the oldest queued pid specifically — deterministic draining, just
# not necessarily in completion order once SUITE_WORKERS>1.
q_pids=(); q_names=(); q_logs=(); q_artdirs=(); q_extra_argc=(); q_caps=()
drain_one() {
  local d_pid="${q_pids[0]}" d_rc
  wait "$d_pid"; d_rc=$?
  classify_result "${q_names[0]}" "${q_logs[0]}" "${q_artdirs[0]}" "${q_extra_argc[0]}" "${q_caps[0]}" "$d_rc"
  q_pids=("${q_pids[@]:1}"); q_names=("${q_names[@]:1}"); q_logs=("${q_logs[@]:1}")
  q_artdirs=("${q_artdirs[@]:1}"); q_extra_argc=("${q_extra_argc[@]:1}"); q_caps=("${q_caps[@]:1}")
}
for t in "${tests[@]}"; do
  name="$(basename "$t")"
  log="$LOGDIR/$name.log"
  test_artdir="$ARTROOT/$name"
  extra_args=()
  if grep -q -- '--artifacts) ART=' "$t" 2>/dev/null; then
    extra_args=(--artifacts "$test_artdir" --keep)
  fi
  # HERD-478: this test's own cap-secs (its tests/test-caps.tsv row, else $PER_TEST_TIMEOUT).
  cap="$(herd_test_cap_for "$name" "$CAP_LEDGER" "$PER_TEST_TIMEOUT")"
  TO=""
  [ -n "$TO_BIN" ] && TO="$TO_BIN $cap"
  # shellcheck disable=SC2086
  # HERMETIC_TEST names the fixture for journal.sh's fail-safe (and any other test-context guards).
  # extra_args[@] is expanded via the +"…" guard because macOS's system bash (3.2 — the default on
  # both the maintainer's box and the CI macos runner) treats "${arr[@]}" on an EMPTY array as an
  # unbound-variable error under `set -u`, unlike bash >= 4.4.
  HERMETIC_TEST="$name" $TO bash "$t" "${extra_args[@]+"${extra_args[@]}"}" </dev/null >"$log" 2>&1 &
  q_pids+=("$!"); q_names+=("$name"); q_logs+=("$log")
  q_artdirs+=("$test_artdir"); q_extra_argc+=("${#extra_args[@]}"); q_caps+=("$cap")
  [ "${#q_pids[@]}" -ge "$SUITE_WORKERS" ] && drain_one
done
while [ "${#q_pids[@]}" -gt 0 ]; do
  drain_one
done

echo
echo "── CI suite summary (${PLATFORM}, mode=$MODE${shard_note}${scope_note}) ─────────────────"
echo "   passed:                $pass"
echo "   XFAIL (env-sensitive): $xfail"
echo "   real failures:         $real_fail"
if [ "$xfail" -gt 0 ]; then
  printf '   · %s\n' "${xfail_names[@]}"
fi
if [ "$real_fail" -gt 0 ]; then
  echo "   real-failed tests:"
  printf '     ✗ %s\n' "${real_names[@]}"
  echo "❌ CI SUITE FAILED on ${PLATFORM}${shard_note}${scope_note} ($real_fail real failure(s))"
  exit 1
fi
echo "✅ CI SUITE CLEAN on ${PLATFORM}${shard_note}${scope_note} ($pass passed, $xfail env-sensitive XFAIL)"
exit 0
