#!/usr/bin/env bash
# test-source-guard-lint.sh — hermetic tests for the shared dot-source-guard drift guard (HERD-632):
# scripts/herd/source-guard-lint.sh reds a NEW fail-soft `. "$VAR/lib.sh"` (a best-effort source whose
# own error handling resolves to success/continue) that lacks a preceding `[ -f ]` test or real
# subshell wrapping, while leaving hard-fail sources, guarded sources, and sim/test fixtures clean.
#
# Proves:
#   (1)  The REAL tree is clean: every fail-soft dot-source of a variable path is guarded, wrapped in a
#        subshell, or carries an explicit '# source-guard-ok' rationale.
#   (2)  An UNGUARDED fail-soft dot-source (the exact HERD-632 shape) REDS.
#   (3)  The SAME source with a preceding same-line '[ -f ]' test is clean.
#   (4)  The SAME source with a preceding GUARD-CLAUSE '[ -f ]' test on an earlier line (spawn-step.sh's
#        shape) is clean.
#   (5)  A source wrapped in a REAL SUBSHELL is clean even with no '[ -f ]' test.
#   (6)  A HARD-FAIL source ('|| exit 1') is OUT OF SCOPE and stays clean even unguarded — the
#        special-builtin bypass and the intended '||' land on the same outcome there.
#   (7)  SIM/FIXTURE PATHS STAY CLEAN: the identical unguarded violation under scripts/herd/sim/,
#        scripts/herd/experiment/ or tests/ is classified, counted, and never flagged.
#   (8)  '# source-guard-ok' opts out — on the offending line or the comment run directly above it.
#   (9)  FAIL-SOFT: a tree with no engine surface → skip (exit 2), never a red.
#  (10)  BYTE-IDENTICAL when clean: a clean fixture emits zero SOURCE-GUARD lines, only the ADVISORY.
#
# Network-free: temp dirs + fixtures only. Run:  bash tests/test-source-guard-lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/scripts/herd/source-guard-lint.sh"

[ -f "$LINT" ] || { echo "FAIL: missing lint: $LINT" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LINT"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# make_file <dir> <relpath> <body...> — write an engine-surface file with the given trailing lines.
make_file() {
  local d="$1" rel="$2"; shift 2
  mkdir -p "$d/$(dirname "$rel")"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$d/$rel"
}

# ── 1. Real tree is clean ─────────────────────────────────────────────────────────────────────────
real_out="$(herd_source_guard_lint "$ROOT")"; real_rc=$?
if [ "$real_rc" -ne 0 ]; then
  grep '^SOURCE-GUARD' <<< "$real_out" >&2
  fail "(1) real tree has an unguarded fail-soft dot-source — add a [ -f ] test, or annotate '# source-guard-ok: <why>'"
fi
grep -q '^SOURCE-GUARD' <<< "$real_out" && fail "(1) SOURCE-GUARD lines present despite a clean exit"
grep -q '^ADVISORY:' <<< "$real_out" || fail "(1) advisory summary line missing"
pass
echo "PASS (1) real tree: every fail-soft dot-source is guarded, subshell-wrapped, or annotated"

# ── 2. Unguarded fail-soft dot-source reds ────────────────────────────────────────────────────────
TU="$T/unguarded"; make_file "$TU" scripts/herd/probe.sh \
  '_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"' \
  'command -v journal_append >/dev/null 2>&1 || . "$_HERE/journal.sh" 2>/dev/null || true'
out="$(herd_source_guard_lint "$TU")"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) the unguarded fail-soft idiom must red (exit 1, got $rc): $out"
grep -q 'SOURCE-GUARD .*probe.sh:3:' <<< "$out" || fail "(2) expected a hit on line 3 (got: $out)"
pass
echo "PASS (2) 'command -v f >/dev/null 2>&1 || . \"\$DIR/lib.sh\" 2>/dev/null || true' (no [ -f ]) → red"

# ── 3. Same-line [ -f ] guard is clean ────────────────────────────────────────────────────────────
TG="$T/guarded-sameline"; make_file "$TG" scripts/herd/probe.sh \
  '_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"' \
  'command -v journal_append >/dev/null 2>&1 || { [ -f "$_HERE/journal.sh" ] && . "$_HERE/journal.sh" 2>/dev/null; } || true'
out="$(herd_source_guard_lint "$TG")"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) a same-line [ -f ]-guarded source must be clean (exit 0, got $rc): $out"
pass
echo "PASS (3) '{ [ -f \"\$DIR/lib.sh\" ] && . \"\$DIR/lib.sh\"; } || true' → clean"

# ── 4. Preceding guard-clause [ -f ] (spawn-step.sh's shape) is clean ────────────────────────────
TG2="$T/guarded-clause"; make_file "$TG2" scripts/herd/probe.sh \
  '_intent_journal() {' \
  '  if ! command -v journal_append >/dev/null 2>&1; then' \
  '    [ -f "$HERE/journal.sh" ] || return 0' \
  '    . "$HERE/journal.sh" 2>/dev/null || return 0' \
  '  fi' \
  '}'
out="$(herd_source_guard_lint "$TG2")"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) a preceding guard-clause [ -f ] must be recognized (exit 0, got $rc): $out"
pass
echo "PASS (4) a guard-clause '[ -f \"\$X\" ] || return 0' two lines above the source → clean"

# ── 5. A real subshell is clean with no [ -f ] test ───────────────────────────────────────────────
TS="$T/subshell"; make_file "$TS" scripts/herd/probe.sh \
  '_fn() {' \
  '  (' \
  '    cd "$path" 2>/dev/null || exit 0' \
  '    . "$_fn_dir/herd-config.sh" 2>/dev/null || exit 0' \
  '  ) 2>/dev/null || true' \
  '}'
out="$(herd_source_guard_lint "$TS")"; rc=$?
[ "$rc" -eq 0 ] || fail "(5) a source wrapped in a real ( … ) subshell must be clean with no [ -f ] test (exit 0, got $rc): $out"
pass
echo "PASS (5) a source wrapped in a real subshell → clean, no [ -f ] test required"

# ── 6. A hard-fail source ('|| exit 1') is out of scope ──────────────────────────────────────────
TH="$T/hardfail"; make_file "$TH" scripts/herd/probe.sh \
  '_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"' \
  '. "$_HERE/required.sh" 2>/dev/null || exit 1'
out="$(herd_source_guard_lint "$TH")"; rc=$?
[ "$rc" -eq 0 ] || fail "(6) a '|| exit 1' hard-fail source must stay clean (out of scope, exit 0, got $rc): $out"
pass
echo "PASS (6) '. \"\$DIR/lib.sh\" 2>/dev/null || exit 1' (hard-fail) → out of scope, not flagged"

# ── 7. Sim / experiment / tests fixtures stay clean ──────────────────────────────────────────────
for rel in scripts/herd/sim/fixture.sh scripts/herd/experiment/fixture.sh tests/test-fixture.sh; do
  TFX="$T/fixture$$"; rm -rf "$TFX"
  make_file "$TFX" scripts/herd/real.sh 'true'                      # a production file, so the scan runs
  make_file "$TFX" "$rel" \
    '_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"' \
    'command -v journal_append >/dev/null 2>&1 || . "$_HERE/journal.sh" 2>/dev/null || true'
  out="$(herd_source_guard_lint "$TFX")"; rc=$?
  [ "$rc" -eq 0 ] || fail "(7) '$rel' is a fixture and must stay clean (exit 0, got $rc): $out"
  grep -q 'SOURCE-GUARD' <<< "$out" && fail "(7) '$rel' must not be flagged (got: $out)"
  grep -qE 'ADVISORY:.*1 fixture file\(s\) skipped' <<< "$out" \
    || fail "(7) '$rel' must be COUNTED as a classified fixture, not silently unscanned (got: $out)"
done
pass
echo "PASS (7) sim/ · experiment/ · tests/ fixtures: same unguarded shape classified FIXTURE, never flagged"

# ── 8. '# source-guard-ok' opts out (inline · comment above) ─────────────────────────────────────
TA1="$T/annot-inline"; make_file "$TA1" scripts/herd/probe.sh \
  '_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"' \
  'command -v journal_append >/dev/null 2>&1 || . "$_HERE/journal.sh" 2>/dev/null || true  # source-guard-ok: verified subshell caller only'
out="$(herd_source_guard_lint "$TA1")"; rc=$?
[ "$rc" -eq 0 ] || fail "(8) an inline-annotated line must be clean (exit 0, got $rc): $out"
grep -qE 'ADVISORY:.*1 opted-out' <<< "$out" || fail "(8) advisory should count 1 opted-out (got: $out)"

TA2="$T/annot-above"; make_file "$TA2" scripts/herd/probe.sh \
  '_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"' \
  '# source-guard-ok: verified subshell caller only' \
  'command -v journal_append >/dev/null 2>&1 || . "$_HERE/journal.sh" 2>/dev/null || true'
out="$(herd_source_guard_lint "$TA2")"; rc=$?
[ "$rc" -eq 0 ] || fail "(8) an annotation on the comment line ABOVE must opt the source out (exit 0, got $rc): $out"

# …and WITHOUT the annotation the very same code reds — prove the opt-out, not a matching miss.
TA3="$T/annot-bare"; make_file "$TA3" scripts/herd/probe.sh \
  '_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"' \
  'command -v journal_append >/dev/null 2>&1 || . "$_HERE/journal.sh" 2>/dev/null || true'
out="$(herd_source_guard_lint "$TA3")"; rc=$?
[ "$rc" -eq 1 ] || fail "(8) the same command WITHOUT '# source-guard-ok' must red (exit 1, got $rc): $out"
pass
echo "PASS (8) '# source-guard-ok' opts out inline and from the comment line above"

# ── 9. Fail-soft: a CONSUMING project skips, never reds ──────────────────────────────────────────
TNS="$T/nosurface"; mkdir -p "$TNS/somewhere"
printf 'command -v f >/dev/null 2>&1 || . "$X" 2>/dev/null || true\n' > "$TNS/somewhere/thing.sh"
HERD_SOURCE_GUARD_SKIP_REASON=""
herd_source_guard_lint "$TNS" >/dev/null 2>&1; skip_rc=$?
[ "$skip_rc" -eq 2 ] || fail "(9) a tree with no engine surface → skip (exit 2, got $skip_rc)"
[ -n "${HERD_SOURCE_GUARD_SKIP_REASON:-}" ] || fail "(9) HERD_SOURCE_GUARD_SKIP_REASON must be set on skip"
pass
echo "PASS (9) a tree with no scripts/herd or bin/herd surface → skip (exit 2), never a red"

# ── 10. Byte-identical-clean: a clean fixture emits only the ADVISORY ────────────────────────────
TC="$T/clean"; make_file "$TC" scripts/herd/probe.sh \
  '_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"' \
  'command -v journal_append >/dev/null 2>&1 || { [ -f "$_HERE/journal.sh" ] && . "$_HERE/journal.sh" 2>/dev/null; } || true'
out="$(herd_source_guard_check "$TC/scripts/herd/probe.sh")"; rc=$?
[ "$rc" -eq 0 ] || fail "(10) a clean fixture must exit 0 (got $rc): $out"
[ "$(grep -c '^SOURCE-GUARD' <<< "$out")" -eq 0 ] || fail "(10) clean fixture must emit zero SOURCE-GUARD lines (got: $out)"
grep -qE '^ADVISORY: 0 unguarded' <<< "$out" || fail "(10) clean advisory must report 0 (got: $out)"
pass
echo "PASS (10) clean fixture → only the ADVISORY summary, zero SOURCE-GUARD lines"

echo
echo "ALL PASS ($PASS checks) — HERD-632: an unguarded fail-soft dot-source is ENFORCED as a red; guarded, subshell-wrapped, hard-fail, and fixture sources all stay clean."
