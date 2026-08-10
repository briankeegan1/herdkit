#!/usr/bin/env bash
# test-dh-guard-attribution.sh — HERD-614 regression fixture: proves the HERD-189 daemon-hermeticity
# guard's BATS-path leak attribution names the actual offending test, not the whole "suite".
#
# GROUNDED: the DH guard's tripwire stubs (herdr/claude/codex/…, shadowed onto PATH around the whole
# `bats tests/*.bats` invocation in .herd/healthcheck.project.sh) record "${HERMETIC_TEST:-suite}" per
# reach. The bats-absent tests/test-*.sh fallback already set HERMETIC_TEST=<basename> per test — but
# the bats invocation never set it per test, so EVERY bats-run leak fell back to the whole "suite" and
# was undebuggable (the full local suite reproduced exactly 'leak: suite herdr agent list' + 'leak:
# suite herdr pane list', with no way to tell which of ~440 bats tests caused either line). HERD-614
# fixed this by having tests/herd.bats's setup() export HERMETIC_TEST from BATS_TEST_DESCRIPTION before
# every test body runs (tests/test-daemon-hermeticity.sh already proves the guard PRIMITIVE records
# whatever HERMETIC_TEST names it — this file proves the bats HARNESS actually supplies that name).
#
# Builds a throwaway bats fixture whose setup() is EXTRACTED VERBATIM from tests/herd.bats (kept in
# lockstep — the same technique .herd/healthcheck.project.sh uses to read HERD_DISCOVERY_BESPOKE
# straight out of tests/herd.bats — so a future edit to that export line is picked up automatically,
# or this fixture fails loudly, rather than silently testing a stale copy) plus one @test that
# deliberately reaches the tripwire-stubbed herdr surface without its own local mock. Runs it under
# the SAME sandbox shape .herd/healthcheck.project.sh wraps bats in (PATH-prepended tripwire stubs +
# HERD_HERMETIC_GUARD) WITHOUT presetting HERMETIC_TEST at the invocation level — proving the bats
# path alone, via the harness's own setup(), supplies the name.
#
# Requires a real `bats` binary; SKIPs when absent (soft dep — herd doctor's soft-deps list, same
# convention as tests/test-bats-fd3-guard.sh) and guards against nested-bats recursion (this file is
# itself discovered and run FROM WITHIN the real tests/herd.bats bats process during a normal gate run).
#
# Fully hermetic: temp dirs only, no network, never touches the real workspace. Run:
#     bash tests/test-dh-guard-attribution.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD_BATS="$HERE/herd.bats"

pass=0
skip_reason=""
if ! command -v bats >/dev/null 2>&1; then
  skip_reason="bats not installed (soft dep)"
elif [ -n "${BATS_VERSION:-}" ]; then
  skip_reason="already running under bats — avoiding nested-bats recursion"
elif [ ! -f "$HERD_BATS" ]; then
  echo "FAIL: missing $HERD_BATS" >&2; exit 1
fi

if [ -z "$skip_reason" ]; then
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  fail(){ echo "FAIL: $1" >&2; exit 1; }
  ok(){ pass=$((pass+1)); }

  # Extract the exact HERMETIC_TEST export line from tests/herd.bats's setup(). If this line is ever
  # removed or renamed, fail loudly here instead of silently testing a fixture that no longer reflects
  # the real harness.
  export_line="$(sed -n '/^  export HERMETIC_TEST=/{s/^  //;p;q;}' "$HERD_BATS")"
  [ -n "$export_line" ] || fail "tests/herd.bats no longer exports HERMETIC_TEST in setup() — HERD-614 attribution wiring missing"

  # ── the DH tripwire sandbox — mirrors .herd/healthcheck.project.sh / test-daemon-hermeticity.sh's
  # hermetic_sandbox(); kept in lockstep with both.
  SB="$T/sandbox"; mkdir -p "$SB/bin"
  LOG="$T/leaks.log"; : > "$LOG"
  for c in herdr claude codex osascript notify-send; do
    { printf '#!/usr/bin/env bash\n'
      printf 'printf '\''%%s\\t%%s\\t%%s\\n'\'' "${HERMETIC_TEST:-suite}" "%s" "$*" >> "%s"\n' "$c" "$LOG"
      case "$c" in herdr) printf 'echo '\''{}'\''\n' ;; claude) printf 'echo '\''claude 0.0.0'\''\n' ;; esac
      printf 'exit 0\n'; } > "$SB/bin/$c"
    chmod +x "$SB/bin/$c"
  done

  DESC="HERD-614 deliberately leaking fixture probe"
  FIXTURE="$T/leak-fixture.bats"
  cat > "$FIXTURE" <<EOF
#!/usr/bin/env bats
setup() {
  $export_line
}

@test "$DESC" {
  herdr agent list >/dev/null 2>&1
  herdr pane list >/dev/null 2>&1
}
EOF

  # Run the fixture through bats exactly like the real gate does: tripwire PATH + HERD_HERMETIC_GUARD
  # armed, HERMETIC_TEST left UNSET at the invocation level — only the fixture's own setup() (extracted
  # from the real harness above) supplies it per test.
  if command -v timeout >/dev/null 2>&1; then
    PATH="$SB/bin:$PATH" HERD_HERMETIC_GUARD="$LOG" timeout 30 bats "$FIXTURE" </dev/null >"$T/tap.out" 2>&1
  else
    PATH="$SB/bin:$PATH" HERD_HERMETIC_GUARD="$LOG" bats "$FIXTURE" </dev/null >"$T/tap.out" 2>&1
  fi
  grep -q '^ok 1' "$T/tap.out" \
    || fail "the leaking fixture itself should still pass (the guard RECORDS, never breaks): $(cat "$T/tap.out")"
  ok; echo "PASS (1) the deliberately-leaking bats fixture runs and passes (guard is a detector, not a breaker)"

  [ -s "$LOG" ] || fail "the fixture's unstubbed herdr calls never tripped the guard — the sandbox itself is broken"
  ok; echo "PASS (2) the guard recorded the leak"

  grep -qF "$(printf '%s\therdr\t' "$DESC")" "$LOG" \
    || fail "leak not attributed to the actual test description '$DESC' ($(cat "$LOG"))"
  ok; echo "PASS (3) the leak is attributed to the actual leaking test"

  if grep -q "$(printf '^suite\t')" "$LOG"; then
    fail "a leak was attributed to the whole 'suite' instead of a named test — HERD-614 regression ($(cat "$LOG"))"
  fi
  ok; echo "PASS (4) no leak line falls back to the whole 'suite' (HERD-614 fixed)"
fi

echo "ALL PASS ($pass checks)${skip_reason:+ (skipped: $skip_reason)}"
