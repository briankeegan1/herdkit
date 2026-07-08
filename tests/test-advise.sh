#!/usr/bin/env bash
# test-advise.sh — hermetic, network-free test of `herd advise` (HERD-101): the mid-flight
# strong-model ADVISOR a builder pulls a one-shot second opinion from WITHOUT escalating its lane.
#
# Covers the two surfaces the feature ships (named in the PR body):
#   (A) ARG PARSING     — missing question is a usage error (exit 2); -h/--help exits 0; the first
#                         positional is the question and the rest (plus piped stdin) are context.
#   (B) DEGRADED PATH   — a FAILED or EMPTY model call, and an unconfigured advisor model, degrade
#                         FAIL-SOFT: a clear one-line "unavailable" message on stdout and exit 0
#                         (never a hard error). The model call is STUBBED by a fake `claude` on PATH.
#   (+) HAPPY PATH      — a stubbed advisor prints its advice on stdout; the stub is invoked with
#                         `-p <prompt>` + `--model <resolved-advisor>`; MODEL_ADVISE defaults to the
#                         MODEL_FEATURE tier and ADVISE_MODEL overrides it; inline + stdin context
#                         reach the prompt.
#
# Fully hermetic: local temp only, NO real claude, NO herdr, NO gh, NO network. The fake `claude`
# records its argv + the -p prompt to files and behaves per $FAKE_MODE (ok|fail|empty).
# Run:  bash tests/test-advise.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"
SCRIPT="$ROOT/scripts/herd/herd-advise.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "$HERD" "$SCRIPT"; do [ -f "$f" ] || fail "missing required file: $f"; done

# ── A temp project whose feature tier is a distinctive sentinel so we can prove MODEL_ADVISE
#    defaults to it. No real model id — the stub never dials out. ──────────────────────────────────
P="$T/proj"
mkdir -p "$P/.herd"
cat > "$P/.herd/config" <<EOF
PROJECT_ROOT="$P"
WORKSPACE_NAME="advisetest"
SCRIBE_BACKEND="file"
MODEL_FEATURE="sentinel-feature-model"
EOF

# ── Fake `claude` on PATH: logs argv, captures the -p prompt, behaves per FAKE_MODE. ─────────────
BIN="$T/bin"; mkdir -p "$BIN"
CLOG="$T/claude.args"; PROMPTF="$T/claude.prompt"
cat > "$BIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CLOG"
prev=""; prompt=""
for a in "\$@"; do [ "\$prev" = "-p" ] && prompt="\$a"; prev="\$a"; done
printf '%s' "\$prompt" > "$PROMPTF"
case "\${FAKE_MODE:-ok}" in
  ok)    printf 'RECOMMENDATION: take option A because it is safer.\n' ;;
  fail)  exit 7 ;;
  empty) : ;;                      # print nothing → empty-output degrade
esac
EOF
chmod +x "$BIN/claude"

# advise_via_cli <FAKE_MODE> [extra env=…]… -- <args…>   run `herd advise` with the stub on PATH.
# Splits at the literal `--`: everything before is env assignments, everything after is advise args.
advise_via_cli() {
  local mode="$1"; shift
  local -a envs=() args=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  args=("$@")
  # bash 3.2 (system /bin/bash) treats "${arr[@]}" of an EMPTY array as an unbound-variable
  # error under `set -u` — which fired on the missing-question case (empty args) and killed this
  # subshell with exit 1 before `herd advise` ran, masking its real exit-2 contract. The
  # ${arr[@]+"${arr[@]}"} idiom expands to nothing when empty on every bash, restoring the probe.
  ( cd "$P" && PATH="$BIN:$PATH" HERD_CONFIG_FILE="$P/.herd/config" \
      FAKE_MODE="$mode" env ${envs[@]+"${envs[@]}"} bash "$HERD" advise ${args[@]+"${args[@]}"} )
}

# ── (A) arg parsing ──────────────────────────────────────────────────────────────────────────────
: > "$CLOG"
out="$(advise_via_cli ok -- 2>/dev/null)"; rc=$?
[ "$rc" -eq 2 ] || fail "(A) missing question should exit 2 (got $rc)"
[ ! -s "$CLOG" ] || fail "(A) missing question must NOT invoke the model"
pass

out="$(advise_via_cli ok -- "   " 2>/dev/null)"; rc=$?
[ "$rc" -eq 2 ] || fail "(A) whitespace-only question should exit 2 (got $rc)"
pass

out="$(advise_via_cli ok -- --help 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(A) --help should exit 0 (got $rc)"
printf '%s' "$out" | grep -q 'usage: herd advise' || fail "(A) --help should print usage"
pass

out="$(advise_via_cli ok -- -x 2>/dev/null)"; rc=$?
[ "$rc" -eq 2 ] || fail "(A) unknown flag should exit 2 (got $rc)"
pass

# ── (+) happy path: stubbed advice on stdout, exit 0, correct model + -p prompt ────────────────────
: > "$CLOG"
out="$(advise_via_cli ok -- "which lock strategy is safer?" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || fail "(+) happy path should exit 0 (got $rc)"
printf '%s' "$out" | grep -q 'RECOMMENDATION: take option A' || fail "(+) advice not printed to stdout: $out"
grep -q -- '-p ' "$CLOG" || fail "(+) model not invoked with -p"
# MODEL_ADVISE defaults to the resolved MODEL_FEATURE (the config sentinel).
grep -q -- '--model sentinel-feature-model' "$CLOG" || fail "(+) MODEL_ADVISE did not default to MODEL_FEATURE: $(cat "$CLOG")"
grep -q 'which lock strategy is safer?' "$PROMPTF" || fail "(+) question not in the prompt"
pass

# ADVISE_MODEL env overrides the default advisor tier.
: > "$CLOG"
advise_via_cli ok ADVISE_MODEL=override-model -- "q?" >/dev/null 2>&1
grep -q -- '--model override-model' "$CLOG" || fail "(+) ADVISE_MODEL override did not win: $(cat "$CLOG")"
grep -q -- '--model sentinel-feature-model' "$CLOG" && fail "(+) default model leaked despite override"
pass

# Inline context args AND piped stdin both reach the prompt.
: > "$CLOG"
out="$(printf 'diff line from stdin\n' | advise_via_cli ok -- "hard q?" "inline-context-token" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || fail "(+) context run should exit 0 (got $rc)"
grep -q 'inline-context-token' "$PROMPTF" || fail "(+) inline context arg not in prompt"
grep -q 'diff line from stdin' "$PROMPTF" || fail "(+) piped stdin context not in prompt"
pass

# ── (B) degraded path: model call FAILS → fail-soft (clear message, exit 0) ────────────────────────
out="$(advise_via_cli fail -- "q?" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || fail "(B) a failed model call must degrade to exit 0, not a hard error (got $rc)"
printf '%s' "$out" | grep -q 'herd advise: unavailable' || fail "(B) failed call: no clear unavailable message: $out"
pass

# Model returns EMPTY output → also degrades fail-soft.
out="$(advise_via_cli empty -- "q?" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || fail "(B) an empty model result must degrade to exit 0 (got $rc)"
printf '%s' "$out" | grep -q 'herd advise: unavailable' || fail "(B) empty call: no clear unavailable message: $out"
pass

echo "ALL PASS — test-advise: $PASS checks passed"
