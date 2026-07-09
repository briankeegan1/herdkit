#!/usr/bin/env bash
# test-baseline-gate.sh — hermetic sandbox sim for the BASELINE-AWARE GATE (HERD-190).
#
# Proves the engine gate (scripts/herd/healthcheck.sh, heavy profile) distinguishes an INHERITED base
# failure from an INTRODUCED one, so a fix-PR never deadlocks on a bug that lives in its base:
#   • a PR failing ONLY an inherited base failure PASSES the gate (exit 0, surfaced as ⚠️ INHERITED)
#   • a PR introducing a NEW failure is BLOCKED (exit 1) even when it also inherits a base failure
#   • byte-identical to the classic gate when the base is GREEN (empty base known-failure set)
#   • fail-soft: an unresolvable base blocks exactly as before (no false green)
#   • renumber-robust: matching is by test DESCRIPTION, not the TAP 'not ok N' number (a fix-PR that
#     adds/removes a test shifts the plan; comparing by number would misread an inherited failure)
#   • BASELINE_AWARE_GATE=off restores the classic absolute pass/fail gate
#
# Drives the REAL scripts/herd/healthcheck.sh against throwaway git fixtures with a STUB project health
# command (cats <dir>/.tap, exits <dir>/.rc) — the watcher's HERD_BASELINE_DIR seam ($MAIN) points at
# the base fixture, so no throwaway worktree is created. Fully hermetic: temp dirs, no herdr/gh/network.
# Run:  bash tests/test-baseline-gate.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HC="$ROOT/scripts/herd/healthcheck.sh"
[ -f "$HC" ] || { echo "FAIL: healthcheck.sh not found at $HC" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); echo "PASS $1"; }

# The stub project health command: emit the fixture's canned TAP, exit its canned rc. Ignores flags.
STUB="$T/hc-stub.sh"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
d="$1"
[ -f "$d/.tap" ] && cat "$d/.tap"
exit "$(cat "$d/.rc" 2>/dev/null || echo 0)"
STUB
chmod +x "$STUB"

CACHE="$T/cache"; mkdir -p "$CACHE"

# mk_fixture <name> <tap> <rc> — a throwaway git repo carrying a canned TAP body + exit code. Echoes dir.
mk_fixture(){
  local name="$1" tap="$2" rc="$3" d
  d="$T/$name"
  mkdir -p "$d"
  printf '%s' "$tap" > "$d/.tap"
  printf '%s' "$rc"  > "$d/.rc"
  git -C "$d" init -q
  # A unique file per fixture so distinct fixtures never collide on an identical commit sha.
  printf '%s\n' "$name" > "$d/marker"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm "$name" >/dev/null 2>&1
  echo "$d"
}

# run_gate <pr-dir> <base-dir|-> [BASELINE_AWARE_GATE] — run the engine heavy gate; sets OUT + RC.
# base-dir "-" leaves HERD_BASELINE_DIR unset (exercises the fail-soft / auto-resolve fallback path).
run_gate(){
  local pr="$1" base="$2" toggle="${3:-on}" bdir_env=()
  [ "$base" != "-" ] && bdir_env=(HERD_BASELINE_DIR="$base")
  OUT="$(env \
      HERD_CONFIG_FILE="$T/no-such-config" \
      HEALTHCHECK_CMD="$STUB" \
      DEFAULT_BRANCH="no-such-ref-for-tests" \
      HERD_BASELINE_CACHE="$CACHE" \
      BASELINE_AWARE_GATE="$toggle" \
      "${bdir_env[@]}" \
      bash "$HC" "$pr" --heavy 2>&1)"; RC=$?
}

# ── (1) base GREEN, PR fails → BLOCK (byte-identical classic code error) ────────────────────────────
BASE_GREEN="$(mk_fixture base_green "1..2
ok 1 alpha
ok 2 beta" 0)"
PR_FAIL="$(mk_fixture pr_fail "1..2
ok 1 alpha
not ok 2 beta" 1)"
run_gate "$PR_FAIL" "$BASE_GREEN"
[ "$RC" -eq 1 ] || fail "(1) base-green + PR fail must BLOCK (exit 1), got $RC — $OUT"
printf '%s\n' "$OUT" | grep -q "CODE ERROR" || fail "(1) must print the classic CODE ERROR — $OUT"
printf '%s\n' "$OUT" | grep -qi "INHERITED" && fail "(1) must NOT surface INHERITED when base is green — $OUT"
ok "(1) base green + PR failure → BLOCK, byte-identical classic code error"

# ── (2) base fails {A,B}, PR fails ONLY {B} (inherited) → PASS (surfaced ⚠️ INHERITED) ───────────────
BASE_AB="$(mk_fixture base_ab "1..3
not ok 1 test alpha
not ok 2 test beta
ok 3 test gamma" 1)"
PR_B_ONLY="$(mk_fixture pr_b_only "1..3
ok 1 test alpha
not ok 2 test beta
ok 3 test gamma" 1)"
run_gate "$PR_B_ONLY" "$BASE_AB"
[ "$RC" -eq 0 ] || fail "(2) inherited-only failure must PASS (exit 0), got $RC — $OUT"
printf '%s\n' "$OUT" | grep -q "INHERITED BASE FAILURE" || fail "(2) must surface INHERITED — $OUT"
ok "(2) PR failing only an inherited base failure → PASS the gate"

# ── (3) base fails {A}, PR fails {A (inherited), C (introduced)} → BLOCK ─────────────────────────────
BASE_A="$(mk_fixture base_a "1..3
not ok 1 test alpha
ok 2 test beta
ok 3 test gamma" 1)"
PR_AC="$(mk_fixture pr_ac "1..3
not ok 1 test alpha
ok 2 test beta
not ok 3 test gamma" 1)"
run_gate "$PR_AC" "$BASE_A"
[ "$RC" -eq 1 ] || fail "(3) an INTRODUCED failure must BLOCK (exit 1), got $RC — $OUT"
printf '%s\n' "$OUT" | grep -q "CODE ERROR" || fail "(3) introduced failure must print CODE ERROR — $OUT"
ok "(3) PR introducing a NEW failure (alongside an inherited one) → BLOCK"

# ── (4) renumber-robust: same failing test, different 'not ok N' number → still inherited ────────────
BASE_RENUM="$(mk_fixture base_renum "1..2
ok 1 test alpha
not ok 2 test beta" 1)"
# PR added a test earlier, so 'test beta' is now failure #6 of a larger plan — but it's the SAME test.
PR_RENUM="$(mk_fixture pr_renum "1..6
ok 1 test alpha
ok 2 test new-one
ok 3 test new-two
ok 4 test new-three
ok 5 test new-four
not ok 6 test beta" 1)"
run_gate "$PR_RENUM" "$BASE_RENUM"
[ "$RC" -eq 0 ] || fail "(4) a renumbered-but-same inherited failure must PASS, got $RC — $OUT"
printf '%s\n' "$OUT" | grep -q "INHERITED BASE FAILURE" || fail "(4) must surface INHERITED — $OUT"
ok "(4) inherited failure matched by description, not TAP number → PASS"

# ── (5) fail-soft: no base resolvable (base ref bogus, no HERD_BASELINE_DIR) → BLOCK ─────────────────
PR_FAIL2="$(mk_fixture pr_fail2 "1..1
not ok 1 test beta" 1)"
run_gate "$PR_FAIL2" "-"
[ "$RC" -eq 1 ] || fail "(5) unresolvable base must fail-soft to BLOCK (exit 1), got $RC — $OUT"
printf '%s\n' "$OUT" | grep -qi "INHERITED" && fail "(5) must NOT surface INHERITED with no base — $OUT"
ok "(5) unresolvable base → fail-soft BLOCK (no false green)"

# ── (6) BASELINE_AWARE_GATE=off restores the classic absolute gate (inherited failure BLOCKS) ────────
run_gate "$PR_B_ONLY" "$BASE_AB" off
[ "$RC" -eq 1 ] || fail "(6) with the feature off an inherited failure must BLOCK (exit 1), got $RC — $OUT"
printf '%s\n' "$OUT" | grep -qi "INHERITED" && fail "(6) feature off must NOT surface INHERITED — $OUT"
ok "(6) BASELINE_AWARE_GATE=off → classic absolute gate (byte-identical)"

# ── (7) both green → PASS (sanity: the common path is untouched) ─────────────────────────────────────
PR_GREEN="$(mk_fixture pr_green "1..2
ok 1 alpha
ok 2 beta" 0)"
run_gate "$PR_GREEN" "$BASE_GREEN"
[ "$RC" -eq 0 ] || fail "(7) green PR must PASS (exit 0), got $RC — $OUT"
printf '%s\n' "$OUT" | grep -q "HEALTHCHECK CLEAN" || fail "(7) green PR must print HEALTHCHECK CLEAN — $OUT"
ok "(7) green PR on green base → PASS unchanged"

# ── (8) sha-keyed cache: the base suite is run ONCE per base sha (the two-fix-PR deadlock reuse) ──────
[ -n "$(ls "$CACHE"/.herd-baseline-notok-* 2>/dev/null)" ] \
  || fail "(8) base known-failure set must be cached by base sha under HERD_BASELINE_CACHE"
ok "(8) base known-failure set is cached by base sha"

echo "ALL PASS ($PASS checks)"
