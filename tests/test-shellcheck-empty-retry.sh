#!/usr/bin/env bash
# test-shellcheck-empty-retry.sh — hermetic test for the shellcheck leg's empty-output retry
# (HERD-421). Live case 2026-07-22: main_health reported SHELLCHECK ERRORS on sha 46f9857 with an
# EMPTY captured output — the run raced the watcher's own symbol-index push rewriting scripts in the
# shared checkout, and the identical invocation passed minutes later. A red row must be VERIFIED-REAL
# (no-false-red doctrine), so a nonzero exit with EMPTY output is no longer trusted on the first try.
#
# Covers, against the REAL .herd/healthcheck.project.sh with a scripted `shellcheck` stub:
#   (1) fails empty once, then succeeds on retry → clean, "retried=yes" recorded.
#   (2) fails empty on BOTH the first run and the retry → red, with the empty-output evidence line
#       and "retried=yes" — never an undiagnosable empty red.
#   (3) fails with real (non-empty) findings on the FIRST run → red immediately, findings printed,
#       NO retry (shellcheck invoked exactly once).
#
# HERD_SHELLCHECK_RETRY_SECS=0 skips the real settle sleep so the test stays fast. Stage 1 (bash -n)
# and stage 3+ (tests/leak-guard/caps-sync/…) are kept inert by an otherwise-empty fixture tree (no
# scripts/bin/templates dirs, no tests/test-*.sh, no capabilities.tsv) and a stubbed `herdr` that
# reports absent — same fail-soft fixture shape as tests/test-healthcheck-env-classify.sh.
# Run:  bash tests/test-shellcheck-empty-retry.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_REPO="$(cd "$HERE/.." && pwd)"
PROJ="$ROOT_REPO/.herd/healthcheck.project.sh"
[ -f "$PROJ" ] || { echo "FAIL: healthcheck.project.sh not found at $PROJ" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

F="$T/fixture"; mkdir -p "$F"
B="$T/bin"; mkdir -p "$B"
printf '#!/usr/bin/env bash\nexit 1\n' > "$B/herdr"; chmod +x "$B/herdr"   # absent-ish: no live workspace

STUB_SC="$B/shellcheck"
cat > "$STUB_SC" <<'STUB'
#!/usr/bin/env bash
n="$(cat "$SC_CALL_COUNT" 2>/dev/null || echo 0)"; n=$((n + 1))
printf '%s' "$n" > "$SC_CALL_COUNT"
line="$(sed -n "${n}p" "$SC_SEQ")"
[ -n "$line" ] || line="$(tail -1 "$SC_SEQ")"
rc="${line%%|*}"; out="${line#*|}"
[ "$out" = "EMPTY" ] || printf '%s\n' "$out"
exit "${rc:-0}"
STUB
chmod +x "$STUB_SC"

run_proj() {
  # $1 = SC_SEQ contents (one "<rc>|<out-or-EMPTY>" line per expected call, extra calls repeat the
  # last line). Sets OUT (combined output), RC (exit code), CALLS (# of shellcheck invocations).
  local seq="$1"
  printf '%s\n' "$seq" > "$T/seq"
  rm -f "$T/callcount"
  OUT="$(PATH="$B:$PATH" HERD_SHELLCHECK_RETRY_SECS=0 SC_SEQ="$T/seq" SC_CALL_COUNT="$T/callcount" \
    bash "$PROJ" "$F" 2>&1)"; RC=$?
  CALLS="$(cat "$T/callcount" 2>/dev/null || echo 0)"
}

# ── (1) empty once, then a clean retry → clean, retried=yes, exactly 2 calls ────────────────────────
run_proj "1|EMPTY
0|"
[ "$RC" -eq 0 ] || fail "(1) empty-then-clean should exit 0, got $RC — out: $OUT"
printf '%s\n' "$OUT" | grep -qF "shellcheck: clean (retried=yes)" \
  || fail "(1) expected a 'shellcheck: clean (retried=yes)' note — got: $OUT"
[ "$CALLS" -eq 2 ] || fail "(1) expected exactly 2 shellcheck invocations (run + one retry), got $CALLS"
ok

# ── (2) empty on BOTH the run and the retry → red, empty-output evidence, retried=yes, 2 calls ──────
run_proj "1|EMPTY
1|EMPTY"
[ "$RC" -eq 1 ] || fail "(2) empty-twice should exit 1, got $RC — out: $OUT"
printf '%s\n' "$OUT" | grep -qF "SHELLCHECK ERRORS" \
  || fail "(2) expected a SHELLCHECK ERRORS header — got: $OUT"
printf '%s\n' "$OUT" | grep -qF "EMPTY output" \
  || fail "(2) expected the empty-output evidence line — got: $OUT"
printf '%s\n' "$OUT" | grep -qF "retried=yes" \
  || fail "(2) expected a retried=yes marker even on a still-empty red — got: $OUT"
[ "$CALLS" -eq 2 ] || fail "(2) expected exactly 2 shellcheck invocations (run + one retry), got $CALLS"
ok

# ── (3) real findings on the FIRST run → immediate red, findings printed, NO retry ──────────────────
run_proj "1|scripts/herd/example.sh:12:3: error: foo is unused [SC2034]"
[ "$RC" -eq 1 ] || fail "(3) real findings should exit 1, got $RC — out: $OUT"
printf '%s\n' "$OUT" | grep -qF "SC2034" \
  || fail "(3) expected the finding text in the log — got: $OUT"
printf '%s\n' "$OUT" | grep -qF "retried=yes" \
  && fail "(3) a first-run finding must NOT retry — got: $OUT"
[ "$CALLS" -eq 1 ] || fail "(3) real findings must red on a SINGLE run, got $CALLS calls"
ok

echo
echo "ALL PASS ($pass checks) — empty-output shellcheck reds retry once before alarming; real findings still red immediately, no retry."
