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
printf '%s\n' "$real_out" | grep -q '^PIPE-UNSAFE' && fail "(1) PIPE-UNSAFE lines present despite clean exit"
printf '%s\n' "$real_out" | grep -q '^ADVISORY:' || fail "(1) advisory summary line missing"
pass
echo "PASS (1) real tree: every live '| grep -q/-m/head' is swept or '# pipe-ok'-annotated"

# ── helper: a fixture engine tree with one script under scripts/herd/ ─────────────────────────────
make_script() {
  # make_script <dir> <body...> — write scripts/herd/probe.sh with the given trailing lines.
  local d="$1"; shift
  mkdir -p "$d/scripts/herd"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$d/scripts/herd/probe.sh"
}

# ── 2. The anti-pattern reds ──────────────────────────────────────────────────────────────────────
TR="$T/anti"; make_script "$TR" 'if cat "$f" | grep -q needle; then echo hit; fi'
out="$(herd_pipe_safety_lint "$TR")"; rc=$?
[ "$rc" -eq 1 ] || fail "(2) '<producer> | grep -q' must red (exit 1, got $rc): $out"
printf '%s\n' "$out" | grep -q 'PIPE-UNSAFE .*probe.sh:2' \
  || fail "(2) should print a PIPE-UNSAFE line for probe.sh:2 (got: $out)"
pass
echo "PASS (2) '<producer> | grep -q' → guard reds and emits a PIPE-UNSAFE line"

# ── 3. '# pipe-ok' opts out ───────────────────────────────────────────────────────────────────────
TOK="$T/optout"; make_script "$TOK" 'if cat "$f" | grep -q needle; then echo hit; fi  # pipe-ok: tiny fixed file'
out="$(herd_pipe_safety_lint "$TOK")"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) an annotated line must be clean (exit 0, got $rc): $out"
printf '%s\n' "$out" | grep -q 'PIPE-UNSAFE' && fail "(3) no PIPE-UNSAFE expected after '# pipe-ok' (got: $out)"
printf '%s\n' "$out" | grep -qE 'ADVISORY:.*1 opted-out' || fail "(3) advisory should count 1 opted-out (got: $out)"
pass
echo "PASS (3) '# pipe-ok' annotation → guard is clean and counts the opt-out"

# ── 4. The safe forms (file / here-string) are NOT flagged ────────────────────────────────────────
TSAFE="$T/safe"; make_script "$TSAFE" \
  'grep -q needle "$f" && echo a' \
  'grep -q needle <<< "$var" && echo b'
out="$(herd_pipe_safety_lint "$TSAFE")"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) 'grep -q PAT FILE' and here-string forms must be clean (exit 0, got $rc): $out"
printf '%s\n' "$out" | grep -q 'PIPE-UNSAFE' && fail "(4) safe forms must not be flagged (got: $out)"
pass
echo "PASS (4) 'grep -q PAT FILE' and 'grep -q PAT <<< \"\$v\"' → not flagged (no producer pipe)"

# ── 5. grep -m and head flagged; grep -c / grep -o (no early exit) not ────────────────────────────
TM="$T/variants"; make_script "$TM" \
  'printf "%s\n" "$x" | grep -m1 needle' \
  'printf "%s\n" "$x" | head -1' \
  'printf "%s\n" "$x" | grep -c needle' \
  'printf "%s\n" "$x" | grep -o needle'
out="$(herd_pipe_safety_lint "$TM")"; rc=$?
[ "$rc" -eq 1 ] || fail "(5) grep -m / head must red (exit 1, got $rc): $out"
printf '%s\n' "$out" | grep -q 'probe.sh:2' || fail "(5) grep -m1 (line 2) must be flagged (got: $out)"
printf '%s\n' "$out" | grep -q 'probe.sh:3' || fail "(5) head -1 (line 3) must be flagged (got: $out)"
printf '%s\n' "$out" | grep -q 'probe.sh:4' && fail "(5) grep -c (line 4) must NOT be flagged — it reads all input (got: $out)"
printf '%s\n' "$out" | grep -q 'probe.sh:5' && fail "(5) grep -o (line 5) must NOT be flagged — it reads all input (got: $out)"
pass
echo "PASS (5) grep -m/head flagged; grep -c/-o (no early exit) not flagged"

# ── 6. Pure-comment lines are never flagged ──────────────────────────────────────────────────────
TC="$T/comment"; make_script "$TC" '# never do  cat "$f" | grep -q needle  — it EPIPEs under pipefail'
out="$(herd_pipe_safety_lint "$TC")"; rc=$?
[ "$rc" -eq 0 ] || fail "(6) a pure-comment line documenting the pattern must be clean (exit 0, got $rc): $out"
printf '%s\n' "$out" | grep -q 'PIPE-UNSAFE' && fail "(6) a comment line must not be flagged (got: $out)"
pass
echo "PASS (6) a '#'-led comment documenting the pattern is never flagged"

# ── 7. Block-aware opt-out on a '\'-continued pipeline ────────────────────────────────────────────
TB="$T/block"; mkdir -p "$TB/scripts/herd"
{
  printf '#!/usr/bin/env bash\n'
  printf 'ref="$(printf "%%s\\n" "$body" \\\n'
  printf '  | grep -iE "^Refs:" \\\n'
  printf '  | head -n1 \\\n'
  printf '  | sed -e "s/x//" || true)"  # pipe-ok: head in a command substitution; status not gated\n'
} > "$TB/scripts/herd/probe.sh"
# The offending '| head -n1' line ends in '\' and cannot carry a comment; the annotation sits on the
# last physical line of the same logical command.
out="$(herd_pipe_safety_lint "$TB")"; rc=$?
[ "$rc" -eq 0 ] || fail "(7) a '# pipe-ok' anywhere in a '\\'-continued command must opt out the whole block (exit 0, got $rc): $out"
printf '%s\n' "$out" | grep -q 'PIPE-UNSAFE' && fail "(7) block-annotated pipeline must not be flagged (got: $out)"
# And WITHOUT the annotation the same block reds — prove the opt-out, not a matching miss.
TB2="$T/block-bare"; mkdir -p "$TB2/scripts/herd"
{
  printf '#!/usr/bin/env bash\n'
  printf 'ref="$(printf "%%s\\n" "$body" \\\n'
  printf '  | grep -iE "^Refs:" \\\n'
  printf '  | head -n1 \\\n'
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
  printf 'if cat "$f" | grep -q needle; then echo late; fi\n'   # the offending line, past the buffer
} > "$TP/scripts/herd/probe.sh"
[ "$(wc -c < "$TP/scripts/herd/probe.sh")" -gt 65536 ] \
  || fail "(9) fixture probe.sh must exceed 64KB to exercise the pipe-buffer boundary"
out="$(herd_pipe_safety_check "$TP/scripts/herd/probe.sh")"; rc=$?
[ "$rc" -eq 1 ] || fail "(9) a late offending line in a >64KB file must still be detected under pipefail (exit 1, got $rc): last of out: $(printf '%s\n' "$out" | tail -1)"
printf '%s\n' "$out" | grep -q '^PIPE-UNSAFE' || fail "(9) the late offending line must be reported (got advisory only)"
pass
echo "PASS (9) detector is pipefail-safe: a >64KB fixture's late offending line is still caught"

# ── 10. Byte-identical-clean: a clean fixture emits only the ADVISORY, no PIPE-UNSAFE lines ────────
TCLEAN="$T/clean"; make_script "$TCLEAN" 'grep -q needle "$f" && echo ok'
out="$(herd_pipe_safety_check "$TCLEAN/scripts/herd/probe.sh")"; rc=$?
[ "$rc" -eq 0 ] || fail "(10) a clean fixture must exit 0 (got $rc): $out"
[ "$(printf '%s\n' "$out" | grep -c '^PIPE-UNSAFE')" -eq 0 ] || fail "(10) clean fixture must emit zero PIPE-UNSAFE lines (got: $out)"
printf '%s\n' "$out" | grep -qE '^ADVISORY: 0 pipe-unsafe' || fail "(10) clean advisory must report 0 pipe-unsafe (got: $out)"
pass
echo "PASS (10) clean fixture → only the ADVISORY summary, zero PIPE-UNSAFE lines"

echo
echo "ALL PASS ($PASS checks) — pipe-safety guard is live, fail-soft, block-aware, and itself pipefail-safe."
