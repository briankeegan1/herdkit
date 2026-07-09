#!/usr/bin/env bash
# test-healthcheck-env-classify.sh — hermetic test for the ENV-vs-CODE bats classification in
# .herd/healthcheck.project.sh (HERD-187).
#
# The dogfood health command runs the bats suite. One KNOWN failure is env-only and MUST be tolerated
# (exit 2, a data/env ⚠️) instead of blocking merges: the "hermetic project-mode codemap test passes"
# test failing because the real repo can't be resolved as the herdkit ENGINE tree (a mis-pointed
# .herd/config PROJECT_ROOT). Everything else stays a code error (exit 1) — a genuine code error is
# NEVER downgraded, and the detail line must quote the ACTUAL failing 'not ok' test (not an adjacent
# 'ok' / diagnostic comment that a bare `tail -1` grabbed).
#
# This test drives the REAL .herd/healthcheck.project.sh against a throwaway fixture worktree with a
# STUB `bats` (cats a canned TAP file, exits a canned code), stub `shellcheck`/`herdr` (so the pre-bats
# sections pass fast and offline), and a stub `tests/test-codemap-project.sh` (the env-vs-genuine
# confirmation re-run). TAP text is written to a file VERBATIM so backticks/`$` in realistic diagnostic
# lines are never shell-interpreted. No network, no real herdr, no touching the live workspace.
# Run:  bash tests/test-healthcheck-env-classify.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_REPO="$(cd "$HERE/.." && pwd)"
PROJ="$ROOT_REPO/.herd/healthcheck.project.sh"
[ -f "$PROJ" ] || { echo "FAIL: healthcheck.project.sh not found at $PROJ" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }

ENV_TEST="hermetic project-mode codemap test passes"

# build_fixture <name> <tap> <bats-rc> <codemap-signal> — materialize a fixture worktree ($T/<name>)
# plus a paired stub bindir ($T/<name>.bin); echoes the fixture dir path.
#   <tap>            TAP text the stub `bats` prints (written to a file verbatim — no shell expansion).
#   <bats-rc>        exit code the stub `bats` returns.
#   <codemap-signal> body for the stub tests/test-codemap-project.sh (the env-confirmation re-run):
#                      env   → fails with a real-repo/ENGINE message (env-dependent, tolerable)
#                      code  → fails on a hermetic-fixture assertion (a genuine codemap.sh regression)
#                      none  → do not create the stub
build_fixture(){
  local name="$1" tap="$2" bats_rc="$3" codemap_signal="$4"
  local F="$T/$name" B="$T/$name.bin"
  mkdir -p "$F/tests" "$B"
  : > "$F/tests/dummy.bats"                              # so `ls tests/*.bats` succeeds

  printf '%s\n' "$tap" > "$B/bats.tap"                   # verbatim TAP; no expansion
  { printf '#!/usr/bin/env bash\n'
    printf 'cat "%s/bats.tap"\n' "$B"
    printf 'exit %s\n' "$bats_rc"; } > "$B/bats"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$B/shellcheck"   # pre-bats lint: no-op clean
  printf '#!/usr/bin/env bash\nexit 1\n' > "$B/herdr"        # absent-ish: no live workspace
  chmod +x "$B/bats" "$B/shellcheck" "$B/herdr"

  case "$codemap_signal" in
    env)  printf '#!/usr/bin/env bash\necho "FAIL: real repo lost its engine section" >&2\nexit 1\n' \
            > "$F/tests/test-codemap-project.sh"; chmod +x "$F/tests/test-codemap-project.sh" ;;
    code) printf '#!/usr/bin/env bash\necho "FAIL: node: wrong title" >&2\nexit 1\n' \
            > "$F/tests/test-codemap-project.sh"; chmod +x "$F/tests/test-codemap-project.sh" ;;
  esac
  echo "$F"
}

# run_proj <fixture> [--oneline] — run the real project healthcheck with the fixture's paired stub
# bindir ("<fixture>.bin") first on PATH. Sets globals OUT (combined output) and RC (exit code).
run_proj(){
  local dir="$1"; shift
  OUT="$(PATH="${dir}.bin:$PATH" bash "$PROJ" "$dir" "$@" 2>&1)"; RC=$?
}

# ── (a) ENV-ONLY failure → exit 2 + the detail quotes the REAL 'not ok' line ────────────────────────
# The codemap test is the SOLE failure and its NOT-OK line is NOT the last line (an 'ok' follows), so a
# bare `tail -1` would quote the wrong line. The confirmation re-run reports the real-repo/ENGINE signal.
TAP_ENV_ONLY="1..3
ok 1 hermetic something-else test passes
not ok 2 $ENV_TEST
# (in test file tests/herd.bats, line 204)
#   assertion failed
ok 3 hermetic another-thing test passes"

F="$(build_fixture env_only "$TAP_ENV_ONLY" 1 env)"
run_proj "$F" --oneline
[ "$RC" -eq 2 ] || fail "(a) env-only should exit 2, got $RC — out: $OUT"
printf '%s\n' "$OUT" | grep -qF "not ok 2 $ENV_TEST" \
  || fail "(a) oneline detail must quote the real 'not ok' codemap line — got: $OUT"
printf '%s\n' "$OUT" | grep -q "another-thing" \
  && fail "(a) detail wrongly quoted the adjacent 'ok' line instead of the failing 'not ok' — got: $OUT"
run_proj "$F"            # full (non-oneline) mode: same verdict, still exit 2
[ "$RC" -eq 2 ] || fail "(a) env-only full-mode should exit 2, got $RC — out: $OUT"
printf '%s\n' "$OUT" | grep -qF "not ok 2 $ENV_TEST" \
  || fail "(a) full-mode detail must quote the real 'not ok' codemap line — got: $OUT"
echo "PASS (a) env-only codemap failure → exit 2 with correct 'not ok' detail"

# ── (b) genuine code failure (a DIFFERENT test fails) → exit 1 ───────────────────────────────────────
TAP_GENUINE="1..2
not ok 1 hermetic backlog-view rich-render test passes
#   assertion failed
ok 2 $ENV_TEST"
F="$(build_fixture genuine "$TAP_GENUINE" 1 none)"
run_proj "$F" --oneline
[ "$RC" -eq 1 ] || fail "(b) genuine code failure should exit 1, got $RC — out: $OUT"
# HERD-173 (live incident, PR #273): the genuine-code-error --oneline detail used to be
# `bats: $(tail -1)`, which grabbed the LAST line bats printed — here the PASSING 'ok 2 …' — and sent
# both the coordinator and the builder to the WRONG test. The detail is load-bearing: the auto-refix
# re-task prompt quotes it verbatim. It must name the FAILING test.
case "$OUT" in
  *"bats: ok "*) fail "(b) the code-error detail must never quote a PASSING 'ok' line — got: $OUT" ;;
esac
printf '%s' "$OUT" | grep -q "not ok 1 hermetic backlog-view rich-render test passes" \
  || fail "(b) the code-error detail must quote the FIRST 'not ok' line — got: $OUT"
echo "PASS (b) genuine non-env test failure → exit 1, detail quotes the failing test"

# ── (b3) MULTIPLE genuine failures → the detail names the FIRST + how many failed ────────────────────
TAP_MULTI="1..4
ok 1 setup
not ok 2 cross-driver conformance audit
#   (in test file tests/test-driver-agent-exec.sh, line 88)
not ok 3 another failing test
ok 4 $ENV_TEST"
F="$(build_fixture multi "$TAP_MULTI" 1 none)"
run_proj "$F" --oneline
[ "$RC" -eq 1 ] || fail "(b3) multiple genuine failures should exit 1, got $RC — out: $OUT"
printf '%s' "$OUT" | grep -q "not ok 2 cross-driver conformance audit" \
  || fail "(b3) the detail must quote the FIRST failing test — got: $OUT"
printf '%s' "$OUT" | grep -q "(2 failing)" \
  || fail "(b3) the detail must report how many tests failed — got: $OUT"
echo "PASS (b3) multiple failures → detail names the first + the failing count"

# ── (b2) env test AND a genuine test both fail → exit 1 (never downgrade; the real worktree state) ──
TAP_BOTH="1..2
not ok 1 hermetic backlog-view rich-render test passes
not ok 2 $ENV_TEST"
F="$(build_fixture both "$TAP_BOTH" 1 env)"
run_proj "$F" --oneline
[ "$RC" -eq 1 ] || fail "(b2) env + genuine failure should exit 1, got $RC — out: $OUT"
echo "PASS (b2) env-only + genuine failure together → exit 1 (not downgraded)"

# ── (c) codemap test is SOLE failure but the cause is a HERMETIC regression → exit 1 (genuine bug) ──
# Same 'not ok' test name, but the confirmation re-run fails on a fixture assertion (no real-repo
# signal) → a genuine codemap.sh code error, which must NOT be downgraded to a tolerated data/env exit.
TAP_CODEMAP_ONLY="1..1
not ok 1 $ENV_TEST
#   assertion failed"
F="$(build_fixture codebug "$TAP_CODEMAP_ONLY" 1 code)"
run_proj "$F" --oneline
[ "$RC" -eq 1 ] || fail "(c) codemap hermetic regression should exit 1, got $RC — out: $OUT"
echo "PASS (c) codemap failure on a hermetic assertion → exit 1 (genuine, not downgraded)"

# ── (d) bats passes → exit 0 (byte-identical clean; no env-only failure) ─────────────────────────────
TAP_PASS="1..2
ok 1 $ENV_TEST
ok 2 hermetic another test passes"
F="$(build_fixture allpass "$TAP_PASS" 0 none)"
run_proj "$F" --oneline
[ "$RC" -eq 0 ] || fail "(d) all-pass should exit 0, got $RC — out: $OUT"
echo "PASS (d) bats pass → exit 0"

echo "ALL PASS"
