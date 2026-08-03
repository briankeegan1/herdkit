#!/usr/bin/env bash
# test-pipe-safety.sh — hermetic tests for the shared pipe-safety guard (HERD-299):
# scripts/herd/pipe-safety-lint.sh reds a NEW '<producer> | grep -q/-m' (or '| head') — the
# EPIPE-under-pipefail anti-pattern that turned macOS CI chronically red (HERD-297, swept in #412).
#
# Proves:
#   (1) The REAL tree is clean: every live '| grep -q/-m/head' either was swept (#412) or carries a
#       '# pipe-ok' annotation — so the guard exits 0 on the shipped engine.
#   (2) The anti-pattern REDS: a fixture with '<producer> | grep -q' exits 1 and prints PIPE-UNSAFE.
#   (3) '# pipe-ok' OPTS OUT: the same fixture line annotated is clean (exit 0).
#   (4) The safe forms are NOT flagged: 'grep -q PAT FILE' and 'grep -q PAT <<< "$v"' (no producer
#       pipe) stay clean.
#   (5) grep -m and head are flagged too (not just grep -q); grep -c / grep -o (no early exit) are NOT.
#   (6) Pure-comment lines that merely document the pattern are never flagged.
#   (7) BLOCK-AWARE opt-out: a '\'-continued multi-line pipeline is opted out by a '# pipe-ok' on ANY
#       physical line of that logical command (the offending line may end in '\', which cannot hold a
#       comment).
#   (8) FAIL-SOFT: a tree with no engine scan surface → skip (exit 2), never a red.
#   (9) DETECTOR IS ITSELF PIPEFAIL-SAFE: run under `set -o pipefail` against a >16KB fixture whose
#       offending line sits AFTER the pipe-buffer boundary — the detector must still report it (it
#       greps the file directly, so it never EPIPEs the way the code it guards would).
#  (10) BYTE-IDENTICAL when clean: a clean fixture produces zero PIPE-UNSAFE lines, only the ADVISORY.
#
# HERD-441 widened the scan surface and tightened the detector; (11)-(16) pin that down:
#  (11) tests/*.sh IS scanned — a violation living only there reds. This is the whole point: the
#       lint printed '0 pipe-unsafe (clean)' while tests/ carried the defect that broke CI 3×.
#  (12) So are backends/, sim/, experiment/, templates/, migrations/, .herd/, herd.sh, install.sh —
#       tests/ was never the only blind spot ('scripts/herd/*.sh' does not recurse).
#  (13) '<test> || grep -q PAT FILE' is NOT flagged: the OR operator is not a pipe and that grep has
#       no producer, so it can never EPIPE.
#  (14) …but a '\'-continued pipeline whose line STARTS with '| grep -q' still reds.
#  (15) A QUOTED '# pipe-ok' grants NO exemption — the annotation must be a real trailing comment.
#  (16) …while a genuine trailing '# pipe-ok' still opts out.
#
# HERD-507 widened the detector past the literal token `grep`; (17)-(20) pin that down:
#  (17) a producer piped into a QUOTED-VARIABLE consumer (holding the consumer's name at runtime,
#       e.g. a portability shim like GREP=/usr/bin/grep) REDS — the EPIPE bug does not care whether
#       the consumer's name is a literal or resolved from a variable.
#  (18) …a BRACED-variable consumer REDS too.
#  (19) ANY short-circuit-shaped consumer REDS regardless of token — not just grep or a variable, a
#       wholly different literal command name ending its first flag in the early-exit shape also reds.
#  (20) The safe forms still hold for a variable-held consumer: reading a FILE directly or a
#       here-string (no producer pipe) stays clean, and '# pipe-ok' still opts out.
#
# Network-free: temp dirs + fixtures only. Run:  bash tests/test-pipe-safety.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/scripts/herd/pipe-safety-lint.sh"

[ -f "$LINT" ] || { echo "FAIL: missing lint: $LINT" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LINT"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# ── 1. Real tree is clean ─────────────────────────────────────────────────────────────────────────
real_out="$(herd_pipe_safety_lint "$ROOT")"; real_rc=$?
if [ "$real_rc" -ne 0 ]; then
  printf '%s\n' "$real_out" | grep '^PIPE-UNSAFE' >&2
  fail "(1) real tree has EPIPE-unsafe pipes — grep files/here-strings directly, or annotate '# pipe-ok: <why>'"
fi
grep -q '^PIPE-UNSAFE' <<< "$real_out" && fail "(1) PIPE-UNSAFE lines present despite clean exit"
grep -q '^ADVISORY:' <<< "$real_out" || fail "(1) advisory summary line missing"
pass
echo "PASS (1) real tree: every live '| grep -q/-m/head' is swept or '# pipe-ok'-annotated"  # pipe-ok: the pattern appears in this line's MESSAGE TEXT, not as a pipeline

# ── helper: a fixture engine tree with one script under scripts/herd/ ─────────────────────────────
make_script() {
  # make_script <dir> <body...> — write scripts/herd/probe.sh with the given trailing lines.
  local d="$1"; shift
  mkdir -p "$d/scripts/herd"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$d/scripts/herd/probe.sh"
}

# ── 2. The anti-pattern reds ──────────────────────────────────────────────────────────────────────
TR="$T/anti"; make_script "$TR" 'if cat "$f" | grep -q needle; then echo hit; fi'  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
out="$(herd_pipe_safety_lint "$TR")"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) '<producer> | grep -q' must red (exit 1, got $rc): $out"  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
grep -q 'PIPE-UNSAFE .*probe.sh:2' <<< "$out" \
  || fail "(2) should print a PIPE-UNSAFE line for probe.sh:2 (got: $out)"
pass
echo "PASS (2) '<producer> | grep -q' → guard reds and emits a PIPE-UNSAFE line"  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect

# ── 3. '# pipe-ok' opts out ───────────────────────────────────────────────────────────────────────
TOK="$T/optout"; make_script "$TOK" 'if cat "$f" | grep -q needle; then echo hit; fi  # pipe-ok: tiny fixed file'
out="$(herd_pipe_safety_lint "$TOK")"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) an annotated line must be clean (exit 0, got $rc): $out"
grep -q 'PIPE-UNSAFE' <<< "$out" && fail "(3) no PIPE-UNSAFE expected after a '# pipe-ok' annotation (got: $out)"
grep -qE 'ADVISORY:.*1 opted-out' <<< "$out" || fail "(3) advisory should count 1 opted-out (got: $out)"
pass
echo "PASS (3) '# pipe-ok' annotation → guard is clean and counts the opt-out"

# ── 4. The safe forms (file / here-string) are NOT flagged ────────────────────────────────────────
TSAFE="$T/safe"; make_script "$TSAFE" \
  'grep -q needle "$f" && echo a' \
  'grep -q needle <<< "$var" && echo b'
out="$(herd_pipe_safety_lint "$TSAFE")"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) 'grep -q PAT FILE' and here-string forms must be clean (exit 0, got $rc): $out"
grep -q 'PIPE-UNSAFE' <<< "$out" && fail "(4) safe forms must not be flagged (got: $out)"
pass
echo "PASS (4) 'grep -q PAT FILE' and 'grep -q PAT <<< \"\$v\"' → not flagged (no producer pipe)"

# ── 5. grep -m and head flagged; grep -c / grep -o (no early exit) not ────────────────────────────
TM="$T/variants"; make_script "$TM" \
  'printf "%s\n" "$x" | grep -m1 needle' \
  'printf "%s\n" "$x" | head -1' \
  'printf "%s\n" "$x" | grep -c needle' \
  'printf "%s\n" "$x" | grep -o needle'  # pipe-ok: fixture TEXT for the case-5 probe, not a live pipeline — these ARE the anti-patterns the lint under test must classify
out="$(herd_pipe_safety_lint "$TM")"; rc=$?
[ "$rc" -eq 1 ] || fail "(5) grep -m / head must red (exit 1, got $rc): $out"
grep -q 'probe.sh:2' <<< "$out" || fail "(5) grep -m1 (line 2) must be flagged (got: $out)"
grep -q 'probe.sh:3' <<< "$out" || fail "(5) head -1 (line 3) must be flagged (got: $out)"
grep -q 'probe.sh:4' <<< "$out" && fail "(5) grep -c (line 4) must NOT be flagged — it reads all input (got: $out)"
grep -q 'probe.sh:5' <<< "$out" && fail "(5) grep -o (line 5) must NOT be flagged — it reads all input (got: $out)"
pass
echo "PASS (5) grep -m/head flagged; grep -c/-o (no early exit) not flagged"

# ── 6. Pure-comment lines are never flagged ──────────────────────────────────────────────────────
TC="$T/comment"; make_script "$TC" '# never do  cat "$f" | grep -q needle  — it EPIPEs under pipefail'  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
out="$(herd_pipe_safety_lint "$TC")"; rc=$?
[ "$rc" -eq 0 ] || fail "(6) a pure-comment line documenting the pattern must be clean (exit 0, got $rc): $out"
grep -q 'PIPE-UNSAFE' <<< "$out" && fail "(6) a comment line must not be flagged (got: $out)"
pass
echo "PASS (6) a '#'-led comment documenting the pattern is never flagged"

# ── 7. Block-aware opt-out on a '\'-continued pipeline ────────────────────────────────────────────
TB="$T/block"; mkdir -p "$TB/scripts/herd"
{
  printf '#!/usr/bin/env bash\n'
  printf 'ref="$(printf "%%s\\n" "$body" \\\n'
  printf '  | grep -iE "^Refs:" \\\n'
  printf '  | head -n1 \\\n'  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
  printf '  | sed -e "s/x//" || true)"  # pipe-ok: head in a command substitution; status not gated\n'
} > "$TB/scripts/herd/probe.sh"
# The offending '| head -n1' line ends in '\' and cannot carry a comment; the annotation sits on the
# last physical line of the same logical command.
out="$(herd_pipe_safety_lint "$TB")"; rc=$?
[ "$rc" -eq 0 ] || fail "(7) a '# pipe-ok' anywhere in a '\\'-continued command must opt out the whole block (exit 0, got $rc): $out"
grep -q 'PIPE-UNSAFE' <<< "$out" && fail "(7) block-annotated pipeline must not be flagged (got: $out)"
# And WITHOUT the annotation the same block reds — prove the opt-out, not a matching miss.
TB2="$T/block-bare"; mkdir -p "$TB2/scripts/herd"
{
  printf '#!/usr/bin/env bash\n'
  printf 'ref="$(printf "%%s\\n" "$body" \\\n'
  printf '  | grep -iE "^Refs:" \\\n'
  printf '  | head -n1 \\\n'  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
  printf '  | sed -e "s/x//" || true)"\n'
} > "$TB2/scripts/herd/probe.sh"
out="$(herd_pipe_safety_lint "$TB2")"; rc=$?
[ "$rc" -eq 1 ] || fail "(7) the same block WITHOUT '# pipe-ok' must red (exit 1, got $rc): $out"
pass
echo "PASS (7) block-aware: a '# pipe-ok' on any line of a '\\'-continued command opts the block out"

# ── 8. Fail-soft: no engine scan surface → skip ──────────────────────────────────────────────────
TN="$T/nosurface"; mkdir -p "$TN/somewhere"
printf 'echo hi\n' > "$TN/somewhere/thing.sh"
HERD_PIPE_SAFETY_SKIP_REASON=""
herd_pipe_safety_lint "$TN" >/dev/null 2>&1; skip_rc=$?
[ "$skip_rc" -eq 2 ] || fail "(8) no scripts/herd, scripts/ci, or bin/herd → skip (exit 2, got $skip_rc)"
[ -n "${HERD_PIPE_SAFETY_SKIP_REASON:-}" ] || fail "(8) HERD_PIPE_SAFETY_SKIP_REASON must be set on skip"
pass
echo "PASS (8) no engine scan surface → skip (exit 2), never a red, reason set"

# ── 9. The detector is itself pipefail-safe on a >16KB fixture ───────────────────────────────────
# The whole file runs under `set -o pipefail` (line 33). Build a probe whose offending line sits
# WELL PAST the macOS 16KB / Linux 64KB pipe-buffer boundary, then classify it via the pure function.
# If the detector piped the file into an early-exit consumer (the very bug it guards) it would EPIPE
# and misreport; grepping the file directly makes it immune.
TP="$T/bigfile"; mkdir -p "$TP/scripts/herd"
{
  printf '#!/usr/bin/env bash\n'
  big_i=0
  while [ "$big_i" -lt 2000 ]; do
    printf '# padding line %04d keeps the file large so a naive pipe-into-grep-q would EPIPE mid-scan\n' "$big_i"
    big_i=$((big_i + 1))
  done
  printf 'if cat "$f" | grep -q needle; then echo late; fi\n'   # the offending line, past the buffer  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
} > "$TP/scripts/herd/probe.sh"
[ "$(wc -c < "$TP/scripts/herd/probe.sh")" -gt 65536 ] \
  || fail "(9) fixture probe.sh must exceed 64KB to exercise the pipe-buffer boundary"
out="$(herd_pipe_safety_check "$TP/scripts/herd/probe.sh")"; rc=$?
[ "$rc" -eq 1 ] || fail "(9) a late offending line in a >64KB file must still be detected under pipefail (exit 1, got $rc): last of out: $(printf '%s\n' "$out" | tail -1)"
grep -q '^PIPE-UNSAFE' <<< "$out" || fail "(9) the late offending line must be reported (got advisory only)"
pass
echo "PASS (9) detector is pipefail-safe: a >64KB fixture's late offending line is still caught"

# ── 10. Byte-identical-clean: a clean fixture emits only the ADVISORY, no PIPE-UNSAFE lines ────────
TCLEAN="$T/clean"; make_script "$TCLEAN" 'grep -q needle "$f" && echo ok'
out="$(herd_pipe_safety_check "$TCLEAN/scripts/herd/probe.sh")"; rc=$?
[ "$rc" -eq 0 ] || fail "(10) a clean fixture must exit 0 (got $rc): $out"
[ "$(printf '%s\n' "$out" | grep -c '^PIPE-UNSAFE')" -eq 0 ] || fail "(10) clean fixture must emit zero PIPE-UNSAFE lines (got: $out)"
grep -qE '^ADVISORY: 0 pipe-unsafe' <<< "$out" || fail "(10) clean advisory must report 0 pipe-unsafe (got: $out)"
pass
echo "PASS (10) clean fixture → only the ADVISORY summary, zero PIPE-UNSAFE lines"

# ── helper: write an arbitrary file under a fixture tree ──────────────────────────────────────────
make_at() {
  # make_at <dir> <relpath> <body...>
  local d="$1" rel="$2"; shift 2
  mkdir -p "$d/$(dirname "$rel")"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$d/$rel"
}

# ── 11. HERD-441: tests/ is IN the scan surface ───────────────────────────────────────────────────
# The whole point of HERD-441: the lint printed '0 pipe-unsafe (clean)' while tests/ carried the
# defect, and it broke CI three times from there (HERD-440's driver-seam pair, then
# test-cli-update.sh). A violation that lives ONLY in tests/ must red.
TT="$T/testsurface"; make_at "$TT" 'tests/test-thing.sh' 'printf "%s" "$out" | grep -q needle'  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
out="$(herd_pipe_safety_lint "$TT")"; rc=$?
[ "$rc" -eq 1 ] || fail "(11) a violation in tests/ must red (exit 1, got $rc): $out"
grep -q 'PIPE-UNSAFE .*tests/test-thing.sh:2' <<< "$out" \
  || fail "(11) the tests/ violation must be reported by path+line (got: $out)"
pass
echo "PASS (11) tests/*.sh is scanned — a violation that lives only there reds (HERD-441)"

# ── 12. HERD-441: every other shell surface is scanned too ────────────────────────────────────────
# tests/ alone was not the blind spot. `scripts/herd/*.sh` does not recurse, so backends/ and sim/
# were missed, and .herd/healthcheck.project.sh — the AUTHORITATIVE heavy merge gate — was unscanned.
for _surf in scripts/herd/backends/be.sh scripts/herd/sim/s.sh scripts/herd/experiment/e.sh \
             templates/t.sh migrations/m.sh .herd/h.sh herd.sh install.sh; do
  TS="$T/surf-$(printf '%s' "$_surf" | tr '/.' '__')"
  make_at "$TS" "$_surf" 'printf "%s" "$out" | grep -q needle'  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
  out="$(herd_pipe_safety_lint "$TS")"; rc=$?
  [ "$rc" -eq 1 ] || fail "(12) a violation in $_surf must red (exit 1, got $rc): $out"
done
pass
echo "PASS (12) backends/ sim/ experiment/ templates/ migrations/ .herd/ herd.sh install.sh all scanned"

# ── 13. HERD-441: `|| grep -q PAT FILE` is NOT a pipe ─────────────────────────────────────────────
# The OR operator's second `|` is followed by ' grep -q', but that grep reads a FILE and has no
# producer process, so it can never EPIPE. Widening the scan to tests/ exposed 13 of these; without
# the `(^|[^|])` guard in the regex they would all false-red.
TOR="$T/oror"; make_at "$TOR" 'tests/test-or.sh' \
  'grep -q needle "$a" || grep -q needle "$b" || fail "neither"' \
  '[ -f "$f" ] && grep -q x "$f" || grep -qF "y" "$g"'
out="$(herd_pipe_safety_lint "$TOR")"; rc=$?
[ "$rc" -eq 0 ] || fail "(13) '|| grep -q PAT FILE' is not a pipeline and must NOT be flagged (exit 0, got $rc): $out"
grep -q 'PIPE-UNSAFE' <<< "$out" && fail "(13) the OR operator must never be read as a pipe (got: $out)"
pass
echo "PASS (13) '|| grep -q PAT FILE' → not flagged (logical OR, not a pipe)"

# ── 14. A REAL pipe still reds when it opens the line (`\`-continued pipeline) ────────────────────
# The `^` alternative in the regex must keep catching a continuation line whose consumer leads it —
# tightening for `||` must not blind the multi-line form.
TCONT="$T/cont"; mkdir -p "$TCONT/tests"
{
  printf '#!/usr/bin/env bash\n'
  printf 'awk "/x/,/y/" "$f" \\\n'
  printf '  | grep -q needle \\\n'  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
  printf '  || fail "nope"\n'
} > "$TCONT/tests/test-cont.sh"
out="$(herd_pipe_safety_lint "$TCONT")"; rc=$?
[ "$rc" -eq 1 ] || fail "(14) a continuation line opening with '| grep -q' must still red (exit 1, got $rc): $out"  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
pass
echo "PASS (14) a '\\'-continued pipeline whose line STARTS with '| grep -q' still reds"  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect

# ── 15. A QUOTED '# pipe-ok' does not grant an exemption ─────────────────────────────────────────
# The opt-out used to be a bare substring match, so a line that merely MENTIONED the token in prose
# opted its own live pipeline out. That is how a real `printf | grep -q` sat unflagged inside THIS
# file until HERD-441 widened the scan to tests/. The annotation must be a trailing comment
# (whitespace before '#'); a quoted mention must still red.
TPH="$T/phantom"; make_at "$TPH" 'tests/test-ph.sh' \
  'printf "%s" "$out" | grep -q needle && fail "no hit expected after a '"'"'# pipe-ok'"'"' annotation"'  # pipe-ok: fixture TEXT for the phantom-opt-out probe — the quoted token is exactly what case 15 proves grants NO exemption
out="$(herd_pipe_safety_lint "$TPH")"; rc=$?
[ "$rc" -eq 1 ] || fail "(15) a QUOTED '# pipe-ok' must NOT opt a live pipeline out (exit 1, got $rc): $out"
pass
echo "PASS (15) a quoted '# pipe-ok' grants no exemption — only a real trailing annotation does"

# ── 16. …and the genuine trailing annotation still works on that same line ───────────────────────
TPH2="$T/phantom-ok"; make_at "$TPH2" 'tests/test-ph2.sh' \
  'printf "%s" "$out" | grep -q needle  # pipe-ok: verified-small fixed producer'
out="$(herd_pipe_safety_lint "$TPH2")"; rc=$?
[ "$rc" -eq 0 ] || fail "(16) a genuine trailing '# pipe-ok' must still opt out (exit 0, got $rc): $out"
pass
echo "PASS (16) a genuine trailing '# pipe-ok' annotation still opts out"

# ── 17. HERD-507: a quoted-variable consumer (producer piped into "$VAR" -q) reds ─────────────────
TVQ="$T/varquoted"; make_script "$TVQ" 'echo "$out" | "$GREP" -q needle || fail "missing"'  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
out="$(herd_pipe_safety_lint "$TVQ")"; rc=$?
[ "$rc" -eq 1 ] || fail "(17) a producer piped into a quoted-variable consumer must red (exit 1, got $rc): $out"
grep -q 'PIPE-UNSAFE .*probe.sh:2' <<< "$out" \
  || fail "(17) should print a PIPE-UNSAFE line for probe.sh:2 (got: $out)"
pass
echo "PASS (17) a producer piped into a quoted-variable consumer (e.g. a GREP= portability shim) reds"

# ── 18. HERD-507: a braced-variable consumer (producer piped into \${VAR} -q) reds ────────────────
TVB="$T/varbraced"; make_script "$TVB" 'echo "$out" | ${GREP} -q needle || fail "missing"'  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
out="$(herd_pipe_safety_lint "$TVB")"; rc=$?
[ "$rc" -eq 1 ] || fail "(18) a producer piped into a braced-variable consumer must red (exit 1, got $rc): $out"
pass
echo "PASS (18) a producer piped into a braced-variable consumer reds too"

# ── 19. HERD-507: ANY short-circuit-shaped consumer reds, regardless of token ────────────────────
TTOK="$T/anytoken"; make_script "$TTOK" 'echo "$out" | some-other-tool -q needle || fail "missing"'  # pipe-ok: fixture/assertion TEXT, not a live pipeline — this is the anti-pattern the lint under test must detect
out="$(herd_pipe_safety_lint "$TTOK")"; rc=$?
[ "$rc" -eq 1 ] || fail "(19) a short-circuit-shaped consumer must red for ANY token, not just grep/head (exit 1, got $rc): $out"
pass
echo "PASS (19) an arbitrary command token in the short-circuit shape reds, not only grep/head"

# ── 20. HERD-507: safe forms + opt-out still hold for a variable-held consumer ────────────────────
TVSAFE="$T/varsafe"; make_script "$TVSAFE" \
  '"$GREP" -q needle "$f" && echo a' \
  '"$GREP" -q needle <<< "$var" && echo b'
out="$(herd_pipe_safety_lint "$TVSAFE")"; rc=$?
[ "$rc" -eq 0 ] || fail "(20) a variable-held consumer reading a file or here-string must be clean (exit 0, got $rc): $out"
grep -q 'PIPE-UNSAFE' <<< "$out" && fail "(20) safe variable-held forms must not be flagged (got: $out)"
TVOK="$T/varoptout"; make_script "$TVOK" 'echo "$out" | "$GREP" -q needle  # pipe-ok: tiny fixed producer'
out="$(herd_pipe_safety_lint "$TVOK")"; rc=$?
[ "$rc" -eq 0 ] || fail "(20) '# pipe-ok' must still opt out a variable-held consumer (exit 0, got $rc): $out"
pass
echo "PASS (20) safe forms and '# pipe-ok' opt-out still hold for a variable-held consumer"

echo
echo "ALL PASS ($PASS checks) — pipe-safety guard is live, fail-soft, block-aware, and itself pipefail-safe."
