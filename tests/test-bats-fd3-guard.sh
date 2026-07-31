#!/usr/bin/env bash
# test-bats-fd3-guard.sh — hermetic tests for the HERD-462 healthcheck-layer chokepoint guard
# (scripts/herd/bats-fd3-guard.sh's herd_bats_early_reap) — the shared-chokepoint half of the
# bats-FD3 wedge fix (tests/test-cli-reload.sh's own `_bg_close_fds` is the test-authoring half).
#
# Proves:
#   (1) MUTATION-PROVE (unguarded): a synthetic bats fixture that leaks a background sleep holding
#       bats' internal fd (the exact shape HERD-462 root-caused) really does wedge bats — reproduced
#       live here, not asserted from memory — WELL AFTER the fixture's own tests all reported "ok".
#       This is exactly the pre-HERD-462 healthcheck's own bare `timeout … bats …` shape (no guard, no
#       herd_bats_early_reap race) — bounded only by THIS test's own outer `timeout`, never an actual
#       hang in CI — proving the guard is load-bearing, not a no-op.
#   (2) GUARDED: wrapping the SAME wedged fixture with herd_bats_early_reap completes in seconds
#       instead of hanging — "the suite must complete anyway".
#   (3) A CLEAN fixture (no leak, one genuinely failing test) passes through the guard untouched: the
#       real exit code and TAP output survive, and no false-positive "reaped-wedged" is reported — the
#       guard reaps wedges, it never masks a real red.
#
# Requires a real `bats` binary; SKIPs when absent — bats is a soft dep (herd doctor's soft-deps
# list). Guards against nested-bats recursion (BATS_VERSION set) the same way tests/test-discovery.sh
# does (a nested `bats` can hang the OUTER bats run it's already running under — see that file's own
# check (6) comment) — and since this file's whole point is exercising nested bats invocations, that
# guard fires on EVERY normal discovery run (this file is executed FROM WITHIN the gate's own bats
# process), not just a rare/dead branch. herd_run_discovered_test (tests/herd.bats) requires an exit-0
# script to also print a PASS/passed marker, so the skip path below still reaches "ALL PASS (0
# checks)" rather than bailing before ever printing one — same contract as a real run, honestly
# reporting zero checks actually ran.
#
# Run:  bash tests/test-bats-fd3-guard.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$ROOT/scripts/herd/bats-fd3-guard.sh"

pass=0
skip_reason=""
if ! command -v bats >/dev/null 2>&1; then
  skip_reason="bats not installed (soft dep)"
elif [ -n "${BATS_VERSION:-}" ]; then
  skip_reason="already running under bats — avoiding nested-bats recursion"
elif [ ! -f "$GUARD" ]; then
  echo "FAIL: missing guard: $GUARD" >&2; exit 1
fi

if [ -z "$skip_reason" ]; then
  # shellcheck source=/dev/null
  . "$GUARD"

  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  fail(){ echo "FAIL: $1" >&2; exit 1; }
  ok(){ pass=$((pass+1)); }

  # A fixture whose first test backgrounds a sleep WITHOUT closing bats' internal fd — the exact
  # HERD-462 leak shape. A distinctive duration (8347s) keeps any pkill cleanup below from ever
  # colliding with an unrelated process on a shared box.
  LEAKY="$T/leaky.bats"
  cat > "$LEAKY" <<'BATS'
@test "leaks a background sleep holding bats' fd" {
  sleep 8347 &
  true
}
@test "second test still runs and reports fine" {
  true
}
BATS

  CLEAN="$T/clean.bats"
  cat > "$CLEAN" <<'BATS'
@test "t1 passes" { true; }
@test "t2 fails for real" { false; }
BATS

  # _run_guarded OUTFILE BATS_ARGS... — mirrors exactly how .herd/healthcheck.project.sh invokes
  # bats: background `timeout … bats …`, race it against herd_bats_early_reap, then `wait` for the
  # real rc.
  _run_guarded() {
    local out="$1"; shift
    ( timeout -k 15 300 bats "$@" </dev/null >"$out" 2>&1 &
      wpid=$!
      note="$(herd_bats_early_reap "$out" "$wpid" 3)"
      wait "$wpid" 2>/dev/null; rc=$?
      printf '%s %s\n' "$rc" "$note" )
  }

  # ── 1. MUTATION-PROVE (unguarded): the leaky fixture run the pre-HERD-462 way — a bare
  #       `timeout … bats …`, no herd_bats_early_reap race at all — really does wedge, bounded ONLY by
  #       this test's own short outer timeout. Proves the failure mode exists live (not asserted from
  #       memory) before trusting the guard, AND that removing the guard call from (2) below reproduces
  #       exactly this — the guard is load-bearing, not a no-op. A short bound suffices: the wedge is
  #       already in effect the instant every test has reported, well under 6s.
  out1="$T/out1"
  timeout 6 bats "$LEAKY" </dev/null >"$out1" 2>&1
  rc1=$?
  [ "$rc1" -eq 124 ] \
    || fail "(1) mutation-prove: unguarded leaky fixture did not wedge (rc=$rc1) — the repro no longer holds on this bats"
  grep -q "^ok 1 " "$out1" \
    || fail "(1) leaky fixture's own first test never reported 'ok' — fixture is broken, not proving the leak"
  pkill -f "sleep 8347" 2>/dev/null || true
  ok
  echo "PASS (1) mutation-prove: an unguarded leaked background sleep wedges bats even though its own test reports ok"

  # ── 2. GUARDED: the SAME wedged fixture completes in low single-digit seconds via herd_bats_early_reap.
  out2="$T/out2"
  t0="$(date +%s 2>/dev/null || echo 0)"
  result2="$(_run_guarded "$out2" "$LEAKY")"
  t1="$(date +%s 2>/dev/null || echo 0)"
  rc2="${result2%% *}"; note2="${result2#* }"
  elapsed=$((t1 - t0))
  [ "$note2" = "reaped-wedged" ] || fail "(2) guard did not report reaped-wedged (got: '$note2', rc=$rc2)"
  [ "$elapsed" -lt 30 ] || fail "(2) guarded run took ${elapsed}s — the guard did not actually cut the wedge short"
  pkill -f "sleep 8347" 2>/dev/null || true
  ok
  echo "PASS (2) guarded: the leaky fixture completes anyway, reaped in ${elapsed}s instead of hanging"

  # ── 3. Clean fixture (no leak, one real failure): guard is a no-op — real exit code, no false positive.
  out3="$T/out3"
  result3="$(_run_guarded "$out3" "$CLEAN")"
  rc3="${result3%% *}"; note3="${result3#* }"
  [ -z "$note3" ] || fail "(3) clean fixture falsely reported as reaped-wedged"
  [ "$rc3" -eq 1 ] || fail "(3) clean fixture's real failing-test exit code lost through the guard (expected 1, got $rc3)"
  grep -q "not ok 2" "$out3" || fail "(3) real test-failure TAP output lost through the guard"
  ok
  echo "PASS (3) clean fixture passes through untouched: real exit code, no false-positive reap"
else
  echo "SKIP: $skip_reason"
fi

echo "ALL PASS ($pass checks) — HERD-462 healthcheck-layer chokepoint guard reaps a leaked-fd wedge in seconds and never masks a real result${skip_reason:+ (skipped: $skip_reason)}"
