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
#   (4) HERD-529: an EXPLICIT HEALTHCHECK_SUITE_WORKERS, even one that exceeds the box's own (stubbed)
#       core count, is honored UNCHANGED — no core-count cap. Supersedes the old HERD-499 behavior
#       (where an explicit request was ALSO capped at the core count); leg B's dynamic default is what
#       now avoids oversubscription for the UNSET case, so an explicit override no longer needs a
#       second clamp on top of it.
#   (5)/(6) HERD-529: an EXPLICIT HEALTHCHECK_SUITE_WORKERS also overrides the live-sibling-suite
#       clamp — (5) a solo suite (no $WORKTREES_DIR/.local-suite-slot-* markers) gets the full
#       explicit count; (6) two live fake local-suite-slot markers do NOT shrink it (explicit always
#       wins unchanged; mirrors the old HERD-499 mutation-proof, now inverted for leg B's contract).
#   (7)/(8) HERD-529 leg B: when HEALTHCHECK_SUITE_WORKERS is UNSET, the DEFAULT is derived
#       dynamically instead of a flat 4 — max(2, cores / max(1, live local-suite-slot count)), read
#       from leg A's $WORKTREES_DIR/.local-suite-slot-* markers (_hk_local_suite_slot_count) — (7) no
#       live markers → divisor 1 → default equals the box's own core count; (8) two live markers →
#       divisor 2 → default halves (cores / 2).
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
#
# HERD-472: dropping the WHOLE directory is too blunt — Ubuntu CI ships `parallel` in /usr/bin,
# the SAME directory as env/awk/grep/sed/mktemp/bash. Removing /usr/bin (and its /bin symlink
# twin) from PATH entirely starved the "absent" case of every core utility, not just `parallel`
# (reproduced: `env: command not found` at the very first external command in run_proj — ubuntu
# shard 3/4). Instead, for each directory that resolves `parallel`, build a shadow directory
# symlinking every OTHER entry and splice that in in its place — every tool but `parallel` stays
# reachable, and `command -v parallel` still finds nothing anywhere on the resulting PATH.
_SPD_SHADOW_ROOT="$T/no-parallel-bin"; mkdir -p "$_SPD_SHADOW_ROOT"
strip_parallel_dirs() {
  local _spd_out="" _spd_d _spd_shadow _spd_entry _spd_base _spd_idx=0
  while IFS= read -r _spd_d; do
    [ -n "$_spd_d" ] || continue
    if [ -x "$_spd_d/parallel" ]; then
      _spd_idx=$((_spd_idx + 1))
      _spd_shadow="$_SPD_SHADOW_ROOT/$_spd_idx"
      mkdir -p "$_spd_shadow"
      for _spd_entry in "$_spd_d"/*; do
        [ -e "$_spd_entry" ] || continue
        _spd_base="$(basename "$_spd_entry")"
        [ "$_spd_base" = "parallel" ] && continue
        ln -sf "$_spd_entry" "$_spd_shadow/$_spd_base" 2>/dev/null
      done
      _spd_d="$_spd_shadow"
    fi
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

# ── (4) HERD-529: an over-requested HEALTHCHECK_SUITE_WORKERS is honored UNCHANGED, uncapped ───────
run_proj yes HEALTHCHECK_SUITE_WORKERS=99
[ "$RC" -eq 0 ] || fail "(4) expected clean exit, got $RC — out: $OUT"
grep -qE -- '--jobs 99\b' <<< "$ARGV" || fail "(4) expected explicit --jobs 99 UNCAPPED (HERD-529: explicit always wins unchanged), got: $ARGV"
ok
echo "PASS (4) HERD-529: an explicit HEALTHCHECK_SUITE_WORKERS is never capped by the box's own core count"

# ── (5)/(6)/(7)/(8) HERD-529: leg A/B wiring — $WORKTREES_DIR/.local-suite-slot-* markers ─────────
# $F has no .herd/config through cases (1)-(4) above, so _hk_local_suite_slot_count() was reading 0
# live markers (fail-soft) the whole time — those cases are unaffected by what follows. Only now do we
# point the fixture's own .herd/config at a throwaway $WORKTREES_DIR pool, mirroring how a real
# project resolves it (_hk_regtabs() reads .herd/config the same way, not an inherited env var).
POOL="$T/pool"; mkdir -p "$POOL" "$F/.herd"
printf 'WORKTREES_DIR="%s"\n' "$POOL" > "$F/.herd/config"

# (5) explicit + solo: pool exists but holds no markers → still just honors the explicit request.
run_proj yes HEALTHCHECK_SUITE_WORKERS=8
[ "$RC" -eq 0 ] || fail "(5) expected clean exit, got $RC — out: $OUT"
grep -qE -- '--jobs 8\b' <<< "$ARGV" || fail "(5) expected explicit --jobs 8 with no local-suite-slot markers, got: $ARGV"
ok
echo "PASS (5) HERD-529: explicit HEALTHCHECK_SUITE_WORKERS with no live local-suite-slot markers → honored unchanged"

# (6) two FAKE local-suite-slot markers, each recording THIS test script's own live pid (kill -0 "$$"
# succeeds for as long as this script is running) — an explicit request is NOT shrunk by them (HERD-529
# inverts the old HERD-499 contract: explicit always wins unchanged, even with live siblings present).
printf '%s\n' "$$" > "$POOL/.local-suite-slot-1"
printf '%s\n' "$$" > "$POOL/.local-suite-slot-2"
run_proj yes HEALTHCHECK_SUITE_WORKERS=8
[ "$RC" -eq 0 ] || fail "(6) expected clean exit, got $RC — out: $OUT"
grep -qE -- '--jobs 8\b' <<< "$ARGV" || fail "(6) expected UNCHANGED --jobs 8 despite two live local-suite-slot markers (explicit overrides the clamp), got: $ARGV"
ok
echo "PASS (6) HERD-529: explicit HEALTHCHECK_SUITE_WORKERS overrides the live-sibling clamp"
rm -f "$POOL/.local-suite-slot-1" "$POOL/.local-suite-slot-2"

# (7) UNSET + solo (no live markers) → dynamic default divisor=max(1,0)=1 → default = cores (8).
run_proj yes
[ "$RC" -eq 0 ] || fail "(7) expected clean exit, got $RC — out: $OUT"
grep -qE -- '--jobs 8\b' <<< "$ARGV" || fail "(7) expected UNSET default --jobs 8 (cores/1) with no live markers, got: $ARGV"
ok
echo "PASS (7) HERD-529 leg B: unset HEALTHCHECK_SUITE_WORKERS with no live local-suite-slot markers → dynamic default = box core count"

# (8) UNSET + two live markers (re-planted; (6)/(7) each clean up after themselves) → dynamic default
# divisor=2 → default = cores/2 = 4.
printf '%s\n' "$$" > "$POOL/.local-suite-slot-1"
printf '%s\n' "$$" > "$POOL/.local-suite-slot-2"
run_proj yes
[ "$RC" -eq 0 ] || fail "(8) expected clean exit, got $RC — out: $OUT"
grep -qE -- '--jobs 4\b' <<< "$ARGV" || fail "(8) expected UNSET default --jobs 4 (cores/2) with two live local-suite-slot markers, got: $ARGV"
ok
echo "PASS (8) HERD-529 leg B: unset HEALTHCHECK_SUITE_WORKERS + two live local-suite-slot markers → dynamic default halves (cores / live)"
rm -f "$POOL/.local-suite-slot-1" "$POOL/.local-suite-slot-2"

echo
echo "ALL PASS ($pass checks) — HERD-463 local heavy-gate bats --jobs wiring: present + bounded when GNU parallel is available, byte-identical serial fallback when it is not. HERD-529: an explicit HEALTHCHECK_SUITE_WORKERS always wins unchanged (leg B); an unset one now derives its default dynamically from leg A's live local-suite-slot count instead of a flat 4."
