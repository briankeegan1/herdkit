#!/usr/bin/env bash
# test-health-progress-header.sh — hermetic proof for HERD-570 leg 1/2: .herd/healthcheck.project.sh
# (the suite wrapper) must emit a 'suite: N tests' header line into HEALTHCHECK_PROGRESS_LOG, BEFORE
# bats runs, naming EXACTLY the number of tests/test-*.sh files discovery will register — the curated
# set minus tests/gate-coverage-exempt.tsv minus the bespoke (hand-written @test block) list read
# straight out of tests/herd.bats. That count is what agent-watch.sh's render (proven by
# tests/test-health-live-progress-row.sh) treats as the denominator for its live k/N counter, matched
# against the '[health-progress] <name> ok|FAIL' completion lines tests/herd.bats's
# herd_run_discovered_test appends directly to the same file as each discovered test finishes.
#
# Drives the REAL .herd/healthcheck.project.sh end-to-end with a stub `bats` (never actually running
# discovery/tests — a canned clean TAP pass is enough, since this test is about the header emitted
# BEFORE bats starts, not about bats' own output) plus a small, controlled tests/ fixture: 3 plain
# discoverable tests, 1 bespoke, 1 exempt — so the expected header count (3) is unambiguous and does
# not depend on this repo's own ~350-test suite. No network, no real bats run, no live workspace.
#
# Covers:
#   (1) header count = curated MINUS exempt MINUS bespoke (3), never the raw test-*.sh file count (5)
#   (2) the header line lands BEFORE any other content HEALTHCHECK_PROGRESS_LOG's caller writes to it
#   (3) fail-soft: no HEALTHCHECK_PROGRESS_LOG set → no header line, no error (byte-identical old path)
#   (4) fail-soft: tests/discover-tests.bash missing (an older tree) → no header line, no error
# Run:  bash tests/test-health-progress-header.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_REPO="$(cd "$HERE/.." && pwd)"
PROJ="$ROOT_REPO/.herd/healthcheck.project.sh"
DISCOVER="$ROOT_REPO/tests/discover-tests.bash"
[ -f "$PROJ" ] || { echo "FAIL: healthcheck.project.sh not found at $PROJ" >&2; exit 1; }
[ -f "$DISCOVER" ] || { echo "FAIL: discover-tests.bash not found at $DISCOVER" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

TAP_PASS='1..1
ok 1 hermetic something test passes'

# build_fixture <name> [--no-discover] — a throwaway worktree ($T/<name>) with 3 plain discoverable
# tests (alpha/beta/gamma), 1 bespoke (excluded via tests/herd.bats' HERD_DISCOVERY_BESPOKE), 1 exempt
# (excluded via tests/gate-coverage-exempt.tsv), a real (copied) discover-tests.bash, and a stub `bats`
# + `shellcheck` + `herdr` bindir. --no-discover omits the discover-tests.bash copy (leg 4).
build_fixture() {
  local name="$1" no_discover="${2:-}"
  local F="$T/$name" B="$T/$name.bin"
  mkdir -p "$F/tests" "$B"
  for t in alpha beta gamma bespoke exempt; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$F/tests/test-$t.sh"
  done
  printf 'test-exempt.sh\n' > "$F/tests/gate-coverage-exempt.tsv"
  printf 'HERD_DISCOVERY_BESPOKE="test-bespoke.sh"\n' > "$F/tests/herd.bats"   # matches `ls tests/*.bats`
  [ "$no_discover" = "--no-discover" ] || cp "$DISCOVER" "$F/tests/discover-tests.bash"
  { printf '#!/usr/bin/env bash\n'
    printf 'cat <<'"'"'TAP'"'"'\n%s\nTAP\n' "$TAP_PASS"
    printf 'exit 0\n'
  } > "$B/bats"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$B/shellcheck"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$B/herdr"
  chmod +x "$B/bats" "$B/shellcheck" "$B/herdr" "$F/tests"/*.sh
  echo "$F"
}

# ── (1)+(2) header count is exact + lands first ───────────────────────────────────────────────────
F="$(build_fixture headercount)"
PROGLOG="$T/headercount.progress"
: > "$PROGLOG"
PATH="${F}.bin:$PATH" HEALTHCHECK_PROGRESS_LOG="$PROGLOG" bash "$PROJ" "$F" --heavy --oneline >/dev/null 2>&1
grep -qx 'suite: 3 tests' "$PROGLOG" \
  || fail "(1) expected 'suite: 3 tests' (5 test-*.sh minus 1 exempt minus 1 bespoke) in $PROGLOG, got: $(cat "$PROGLOG")"
ok
[ "$(sed -n '1p' "$PROGLOG")" = "suite: 3 tests" ] \
  || fail "(2) the header must be the FIRST line written to the progress companion, got: $(sed -n '1p' "$PROGLOG")"
ok

# ── (3) fail-soft: no HEALTHCHECK_PROGRESS_LOG at all ─────────────────────────────────────────────
F2="$(build_fixture nolog)"
RC=0
PATH="${F2}.bin:$PATH" bash "$PROJ" "$F2" --heavy --oneline >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "(3) a run with no HEALTHCHECK_PROGRESS_LOG must still pass cleanly, got RC=$RC"
ok

# ── (4) fail-soft: tests/discover-tests.bash absent (an older tree) ───────────────────────────────
F3="$(build_fixture nodiscover --no-discover)"
PROGLOG3="$T/nodiscover.progress"
: > "$PROGLOG3"
PATH="${F3}.bin:$PATH" HEALTHCHECK_PROGRESS_LOG="$PROGLOG3" bash "$PROJ" "$F3" --heavy --oneline >/dev/null 2>&1
grep -q '^suite: ' "$PROGLOG3" \
  && fail "(4) with no tests/discover-tests.bash present, no header line must be emitted, got: $(cat "$PROGLOG3")"
ok

echo "ALL PASS ($pass checks) — .herd/healthcheck.project.sh emits an exact 'suite: N tests' header before bats runs, fail-soft when the pieces it needs are absent."
