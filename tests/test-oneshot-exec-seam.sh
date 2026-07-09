#!/usr/bin/env bash
# test-oneshot-exec-seam.sh — the DRAINER one-shot exec routes through the driver seam (HERD-175,
# HERD-150 P3). The mid-flight advisor (herd-advise.sh) and the pre-merge reviewer (herd-review.sh)
# used to shell out to a RAW `claude -p …`; they now call herd_driver_oneshot_exec, the ONE seam that
# composes the DRIVER_AGENT_ONESHOT_EXEC incantation so a non-Claude runtime rebinds it in one place.
#
# WHY: with the incantation inlined at every drainer site, a runtime swap (HERD-150 P5) meant editing
# each call site; and a headless run had no single seam to intercept. Routing through the shim makes
# the one-shot exec driver-aware and keeps the composed argv BYTE-IDENTICAL for the default driver.
#
# PART A drives herd_driver_oneshot_exec against a FAKE claude that echoes its argv, and asserts the
# composed command is EXACTLY what the herdr-claude.driver DRIVER_AGENT_ONESHOT_EXEC binding declares
# (binding-composed-command proof) + that a multi-word prompt stays ONE arg and trailing runtime args
# are forwarded verbatim. PART B drives herd-advise.sh end-to-end through the fake and asserts it
# routed through the seam. PART C asserts the wiring in both drainer files (sourced + no raw claude -p).
#
# Fully hermetic: a fake `claude` on PATH + temp dirs. No real claude/herdr/gh/network/model.
# Run:  bash tests/test-oneshot-exec-seam.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPTS="$ROOT/scripts/herd"
HC="$ROOT/templates/drivers/herdr-claude.driver"
GREP=/usr/bin/grep; command -v "$GREP" >/dev/null 2>&1 || GREP=grep

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# _code_has <file> <ere> — true iff a NON-comment line of <file> matches <ere>. grep reads the
# comment-stripped stream via process substitution (NOT a pipe) so `grep -q` exiting early on a match
# never leaves awk's SIGPIPE status to trip `set -o pipefail` — a false miss on large files.
_code_has() { "$GREP" -qE "$2" < <(awk '{ s=$0; sub(/^[ \t]+/,"",s); if (s !~ /^#/) print }' "$1"); }

# A fake `claude` that records its argv, one arg per line prefixed ARG:, into $CLAUDE_ARGV_LOG. It
# prints the same to stdout so a caller capturing stdout (herd-advise) still sees a non-empty "advice".
FAKEBIN="$T/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
: "${CLAUDE_ARGV_LOG:=/dev/null}"
for a in "$@"; do printf 'ARG:%s\n' "$a"; done | tee -a "$CLAUDE_ARGV_LOG"
EOF
chmod +x "$FAKEBIN/claude"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART A — herd_driver_oneshot_exec composes EXACTLY the binding-declared command.
# ══════════════════════════════════════════════════════════════════════════════════════════════════

# Derive the expected argv tokens from the SHIPPED binding (not hardcoded here) — the compose proof.
# DRIVER_AGENT_ONESHOT_EXEC = 'claude -p "<prompt>" --model <model> --dangerously-skip-permissions'.
binding="$( . "$HC"; printf '%s' "$DRIVER_AGENT_ONESHOT_EXEC" )"
[ -n "$binding" ] || fail "(A) herdr-claude.driver has no DRIVER_AGENT_ONESHOT_EXEC binding"
exp="${binding#claude }"                 # strip the runtime token → the arg template
exp="${exp//<prompt>/hi}"                # substitute a no-space prompt so tokens split cleanly
exp="${exp//<model>/m1}"
exp="${exp//\"/}"                        # drop the shape-quotes around <prompt>
read -ra EXP_TOKENS <<< "$exp"           # -p hi --model m1 --dangerously-skip-permissions

LOG="$T/a.log"; : > "$LOG"
PATH="$FAKEBIN:$PATH" CLAUDE_ARGV_LOG="$LOG" bash -c \
  '. "'"$SCRIPTS"'/driver.sh"; herd_driver_oneshot_exec "hi" "m1" --dangerously-skip-permissions' >/dev/null \
  || fail "(A) herd_driver_oneshot_exec exited non-zero"
# Read back the recorded argv into an array (strip the ARG: prefix).
GOT_TOKENS=(); while IFS= read -r l; do GOT_TOKENS+=("${l#ARG:}"); done < "$LOG"
[ "${#GOT_TOKENS[@]}" = "${#EXP_TOKENS[@]}" ] \
  || fail "(A) seam argv length ${#GOT_TOKENS[@]} != binding-declared ${#EXP_TOKENS[@]} (got: ${GOT_TOKENS[*]})"
i=0
while [ "$i" -lt "${#EXP_TOKENS[@]}" ]; do
  [ "${GOT_TOKENS[$i]}" = "${EXP_TOKENS[$i]}" ] \
    || fail "(A) argv token $i is '${GOT_TOKENS[$i]}', binding declares '${EXP_TOKENS[$i]}'"
  i=$((i+1))
done
pass

# A multi-word prompt stays ONE arg, and trailing runtime args (the reviewer's stream flags) forward
# verbatim in order after the permission flag — the byte-identical guarantee for herd-review.sh.
LOG="$T/a2.log"; : > "$LOG"
PATH="$FAKEBIN:$PATH" CLAUDE_ARGV_LOG="$LOG" bash -c \
  '. "'"$SCRIPTS"'/driver.sh"; herd_driver_oneshot_exec "two words" "m1" --dangerously-skip-permissions --output-format stream-json --verbose' >/dev/null \
  || fail "(A2) seam with trailing args exited non-zero"
[ "$("$GREP" -c '^ARG:two words$' "$LOG")" = 1 ] \
  || fail "(A2) multi-word prompt did not stay a single arg: $(cat "$LOG")"
expected_a2=$'ARG:-p\nARG:two words\nARG:--model\nARG:m1\nARG:--dangerously-skip-permissions\nARG:--output-format\nARG:stream-json\nARG:--verbose'
[ "$(cat "$LOG")" = "$expected_a2" ] || fail "(A2) forwarded argv not byte-identical:
--- got ---
$(cat "$LOG")
--- want ---
$expected_a2"
pass

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART B — herd-advise.sh drives its query THROUGH the seam (end-to-end, fake claude).
# ══════════════════════════════════════════════════════════════════════════════════════════════════
LOG="$T/b.log"; : > "$LOG"
out="$(PATH="$FAKEBIN:$PATH" CLAUDE_ARGV_LOG="$LOG" ADVISE_MODEL="advisor-x" \
        bash "$SCRIPTS/herd-advise.sh" "should I use a mutex here?" </dev/null 2>/dev/null)" \
  || fail "(B) herd-advise.sh exited non-zero"
# The advisor call reached the fake with the seam-composed argv: -p <prompt> --model advisor-x --dangerously-skip-permissions
"$GREP" -q '^ARG:-p$' "$LOG"                          || fail "(B) advisor query did not pass -p through the seam"
"$GREP" -q '^ARG:--model$' "$LOG"                     || fail "(B) advisor query did not pass --model through the seam"
"$GREP" -q '^ARG:advisor-x$' "$LOG"                   || fail "(B) advisor query did not carry the resolved ADVISE_MODEL"
"$GREP" -q '^ARG:--dangerously-skip-permissions$' "$LOG" || fail "(B) advisor query dropped the permission flag"
# --model is immediately followed by the model value (order preserved).
"$GREP" -A1 '^ARG:--model$' "$LOG" | "$GREP" -q '^ARG:advisor-x$' \
  || fail "(B) --model is not immediately followed by the model value"
# The advice (fake stdout) surfaced back to the builder — the seam did not swallow output.
echo "$out" | "$GREP" -q 'ARG:advisor-x' || fail "(B) advisor stdout did not reach the builder"
pass

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART C — wiring: both drainer files source the seam, call it, and carry NO raw `claude -p`.
# ══════════════════════════════════════════════════════════════════════════════════════════════════
for f in herd-advise herd-review; do
  _code_has "$SCRIPTS/$f.sh" '\. "\$HERE/driver\.sh"' \
    || fail "(C) $f.sh does not source driver.sh"
  _code_has "$SCRIPTS/$f.sh" 'herd_driver_oneshot_exec' \
    || fail "(C) $f.sh does not call herd_driver_oneshot_exec"
  ! _code_has "$SCRIPTS/$f.sh" 'claude -p "\$' \
    || fail "(C) $f.sh still contains a raw 'claude -p \"\$…' call — route it through herd_driver_oneshot_exec"
done
# The seam itself is the ONE place the claude -p incantation now lives.
_code_has "$SCRIPTS/driver.sh" 'claude -p "\$prompt" --model "\$model"' \
  || fail "(C) driver.sh seam no longer carries the claude -p one-shot incantation"
pass

echo "ALL PASS ($PASS checks)"
