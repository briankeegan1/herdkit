#!/usr/bin/env bash
# test-suite-parallel-wiring.sh — hermetic test for the HERD-463 local heavy-gate parallelism wiring
# in .herd/healthcheck.project.sh: `bats --jobs N` is added when GNU `parallel` is on PATH (bounded
# by HEALTHCHECK_SUITE_WORKERS and the box's own core count), and omitted — falling back to the exact
# pre-HERD-463 serial bats invocation — when `parallel` is absent. Stubs `bats` itself (records its
# argv, prints a trivial empty-pass TAP stream) so this proves the WIRING, not bats's own --jobs
# behavior (which is a stable upstream feature, not this repo's to test).
#
# Against the REAL .herd/healthcheck.project.sh, same fixture-tree idiom as
# tests/test-shellcheck-empty-retry.sh (an otherwise-empty tree keeps every other stage inert).
#
# Proves:
#   (1) GNU parallel present, workers=4 → bats invoked with "--jobs 4", and the health output notes it.
#   (2) GNU parallel ABSENT → bats invoked with NO --jobs flag at all — byte-identical to before
#       HERD-463 — and the output notes the serial fallback.
#   (3) HEALTHCHECK_SUITE_WORKERS=1 → no --jobs even with parallel present (bound<=1 is a strict
#       serial request, matching scripts/herd/burst.sh's own "bound<=1 is strict serial" contract).
#   (4) an over-requested HEALTHCHECK_SUITE_WORKERS is capped at the box's own (stubbed) core count.
#
# Run:  bash tests/test-suite-parallel-wiring.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_REPO="$(cd "$HERE/.." && pwd)"
PROJ="$ROOT_REPO/.herd/healthcheck.project.sh"
[ -f "$PROJ" ] || { echo "FAIL: healthcheck.project.sh not found at $PROJ" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

F="$T/fixture"; mkdir -p "$F/tests"
printf '#!/usr/bin/env bats\n@test "stub" { run true; }\n' > "$F/tests/dummy.bats"

B="$T/bin"; mkdir -p "$B"
printf '#!/usr/bin/env bash\nexit 1\n' > "$B/herdr"; chmod +x "$B/herdr"          # absent-ish: no live workspace
printf '#!/usr/bin/env bash\nprintf "8\\n"\n' > "$B/nproc"; chmod +x "$B/nproc"   # pin cores=8, deterministic across boxes
printf '#!/usr/bin/env bash\nexit 0\n' > "$B/shellcheck"; chmod +x "$B/shellcheck"  # shadow the real one: fixture has no scripts/herd/* for it to lint

STUB_BATS="$B/bats"
cat > "$STUB_BATS" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$BATS_ARGV_FILE"
printf '1..0\n'
exit 0
STUB
chmod +x "$STUB_BATS"

PB="$T/parbin"; mkdir -p "$PB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$PB/parallel"; chmod +x "$PB/parallel"

# Strip every PATH directory that itself resolves an executable `parallel` — not just the single
# directory `command -v parallel` happens to report first. On Ubuntu's usr-merge layout /bin is a
# symlink to /usr/bin, so a `parallel` installed at /usr/bin/parallel is ALSO reachable via
# /bin/parallel: stripping only the `command -v` hit leaves that symlinked duplicate on PATH, and
# the "absent" cases below silently degrade to "present" on such boxes (reproduced: CI ubuntu
# runners ship GNU parallel this way — confirmed the exact `--jobs 4` leak this guards against).
# A box with no `parallel` at all strips nothing — the absent case is already satisfied.
strip_parallel_dirs() {
  local _spd_out="" _spd_d
  while IFS= read -r _spd_d; do
    [ -n "$_spd_d" ] || continue
    [ -x "$_spd_d/parallel" ] && continue
    _spd_out="${_spd_out:+$_spd_out:}$_spd_d"
  done <<< "$(printf '%s' "$1" | tr ':' '\n')"
  printf '%s' "$_spd_out"
}

run_proj() {
  # run_proj <yes|no: put stub parallel on PATH> [VAR=VAL...] — sets OUT/RC/ARGV.
  local want_parallel="$1"; shift
  local base_path="$PATH"
  [ "$want_parallel" = "yes" ] || base_path="$(strip_parallel_dirs "$PATH")"
  local p="$B:$base_path"
  [ "$want_parallel" = "yes" ] && p="$PB:$p"
  OUT="$(PATH="$p" BATS_ARGV_FILE="$T/argv" env "$@" bash "$PROJ" "$F" 2>&1)"; RC=$?
  ARGV="$(cat "$T/argv" 2>/dev/null || echo "")"
  rm -f "$T/argv"
}

# ── (1) parallel present, workers=4 → --jobs 4 in bats argv ───────────────────────────────────────
run_proj yes HEALTHCHECK_SUITE_WORKERS=4
[ "$RC" -eq 0 ] || fail "(1) expected clean exit, got $RC — out: $OUT"
grep -qE -- '--jobs 4\b' <<< "$ARGV" || fail "(1) expected '--jobs 4' in bats argv, got: $ARGV"
grep -qF "jobs=4" <<< "$OUT" || fail "(1) expected a jobs=4 note in the health output — got: $OUT"
ok
echo "PASS (1) GNU parallel present, workers=4 → bats invoked with --jobs 4"

# ── (2) parallel ABSENT → no --jobs flag, byte-identical to pre-HERD-463 ──────────────────────────
run_proj no HEALTHCHECK_SUITE_WORKERS=4
[ "$RC" -eq 0 ] || fail "(2) expected clean exit, got $RC — out: $OUT"
grep -q -- '--jobs' <<< "$ARGV" && fail "(2) parallel absent must NOT pass --jobs, got: $ARGV"
grep -qF "serial" <<< "$OUT" || fail "(2) expected a serial-fallback note — got: $OUT"
ok
echo "PASS (2) GNU parallel absent → bats invoked with no --jobs flag (serial fallback, byte-identical to before)"

# ── (3) HEALTHCHECK_SUITE_WORKERS=1 → no --jobs even with parallel present ────────────────────────
run_proj yes HEALTHCHECK_SUITE_WORKERS=1
[ "$RC" -eq 0 ] || fail "(3) expected clean exit, got $RC — out: $OUT"
grep -q -- '--jobs' <<< "$ARGV" && fail "(3) workers=1 must NOT pass --jobs even with parallel present, got: $ARGV"
ok
echo "PASS (3) HEALTHCHECK_SUITE_WORKERS=1 stays serial even with GNU parallel present"

# ── (4) worker count is capped at the (stubbed) core count ────────────────────────────────────────
run_proj yes HEALTHCHECK_SUITE_WORKERS=99
[ "$RC" -eq 0 ] || fail "(4) expected clean exit, got $RC — out: $OUT"
grep -qE -- '--jobs 8\b' <<< "$ARGV" || fail "(4) expected --jobs capped at the stubbed core count (8), got: $ARGV"
ok
echo "PASS (4) an over-requested HEALTHCHECK_SUITE_WORKERS is capped at the box's own core count"

echo
echo "ALL PASS ($pass checks) — HERD-463 local heavy-gate bats --jobs wiring: present + bounded when GNU parallel is available, byte-identical serial fallback when it is not."
