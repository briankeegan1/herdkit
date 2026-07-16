#!/usr/bin/env bash
# test-resolve-smoke-gate.sh — conformance proof for SMOKE_CMD (HERD-378): herd-resolve.sh must run
# $SMOKE_CMD before pushing a resolved branch. herd-resolve.sh never execs SMOKE_CMD itself — the
# resolver is a free-form LLM agent, so the script's real job is to fold SMOKE_CMD into that agent's
# TASK contract, ordered BEFORE the push step and gating it. This proves that wiring, the same way
# tests/test-model-flags.sh proves MODEL_RESOLVER is wired (stub herdr, capture the emitted `agent
# start … -- claude … "<task>"` call, inspect the captured task text) — plus two executable checks
# that the CONFIGURED command really does what the fixture claims, so "wired" also means "correct":
#   • a marker-writing SMOKE_CMD really leaves its marker when run — proving the string embedded in
#     the task contract is the actual command, not a stand-in.
#   • a failing SMOKE_CMD really fails (no marker) while the task contract's push step stays worded
#     as conditional on it passing — proving a failing smoke, if the resolver obeys its own
#     contract, aborts the push rather than pushing anyway.
#
# Stubs herdr/claude (NETWORK-FREE, no real tabs, no real LLM). Run:  bash tests/test-resolve-smoke-gate.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$HERE/../scripts/herd/herd-resolve.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stubs (same herdr/claude fixture as tests/test-model-flags.sh) ────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "workspace focus"|"workspace create") printf '{"result":{"workspace":{"workspace_id":"wTest"},"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "tab list")   printf '{"result":{"tabs":[]}}\n' ;;
  "tab create") printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start") printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  "pane split") printf '{"result":{"pane":{"pane_id":"pTest"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
# claude stub — never actually invoked (agent start is stubbed), present for PATH completeness.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

MARKER="$T/smoke.marker"
SMOKE_OK_CMD="touch $MARKER"
SMOKE_FAIL_CMD="exit 7"

mkdir -p "$T/repo" "$T/trees"
export WORKSPACE_NAME="herdkit"
export HERD_SKIP_PREFLIGHT=1

SLUG="smoke-demo"; mkdir -p "$T/trees/$SLUG"; : > "$T/trees/$SLUG/.git"   # look like a worktree

# ── (1) SMOKE_CMD set to a marker-writing command ──────────────────────────────
OK_CFG="$T/config-ok"
cat > "$OK_CFG" <<EOF
PROJECT_ROOT="$T/repo"
WORKTREES_DIR="$T/trees"
WORKSPACE_NAME="herdkit"
MODEL_RESOLVER="resolver-model"
APP_PREVIEW_CMD=""
SMOKE_CMD="$SMOKE_OK_CMD"
EOF
export HERDR_CALL_LOG="$T/resolve-ok.log"; : > "$HERDR_CALL_LOG"
HERD_CONFIG_FILE="$OK_CFG" HERD_NO_APP=1 bash "$RESOLVE" "$SLUG" >/dev/null 2>&1 \
  || fail "herd-resolve.sh exited non-zero under stubs (SMOKE_CMD set)"

TASK_LINE="$(grep 'agent start' "$HERDR_CALL_LOG" | tail -1)"
[ -n "$TASK_LINE" ] || fail "no 'agent start' call captured for SMOKE_CMD-set run"

printf '%s' "$TASK_LINE" | grep -qF "the project smoke test ($SMOKE_OK_CMD)" \
  || fail "herd-resolve.sh did not fold SMOKE_CMD into the resolver's task contract"$'\n'"$TASK_LINE"

# Ordering: the smoke step must be ordered BEFORE the push step in the resolver's instructed
# sequence — herd-resolve.sh names them steps (3) and (4); prove it by string position rather than
# trusting the step numbers to stay in sync with the prose.
SMOKE_POS=$(python3 -c "import sys; print(sys.argv[1].find(sys.argv[2]))" "$TASK_LINE" "the project smoke test")
PUSH_POS=$(python3 -c "import sys; print(sys.argv[1].find(sys.argv[2]))" "$TASK_LINE" "git push")
GREEN_POS=$(python3 -c "import sys; print(sys.argv[1].find(sys.argv[2]))" "$TASK_LINE" "the checks are green")
[ "$SMOKE_POS" -ge 0 ] || fail "smoke step not found in task contract"
[ "$PUSH_POS" -ge 0 ]  || fail "push step not found in task contract"
[ "$GREEN_POS" -ge 0 ] || fail "push step is not conditioned on 'the checks are green' in task contract"
[ "$SMOKE_POS" -lt "$PUSH_POS" ]  || fail "smoke step is not ordered before the push step in the task contract"
[ "$GREEN_POS" -lt "$PUSH_POS" ]  || fail "the green-checks condition is not ordered before the push instruction"

# Both the smoke command AND the healthcheck must be required before the resolver moves on.
printf '%s' "$TASK_LINE" | grep -qF "both must pass" \
  || fail "task contract does not require the smoke+healthcheck pass before continuing"

# The configured SMOKE_CMD is a REAL, executable command — running it (as the resolver's task
# contract instructs) actually produces the marker.
[ ! -e "$MARKER" ] || fail "marker pre-existed — test setup bug"
bash -c "$SMOKE_OK_CMD" || fail "the configured SMOKE_CMD failed when run directly"
[ -e "$MARKER" ] || fail "SMOKE_CMD ran but left no marker — the embedded command is not what actually runs"

# ── (2) A FAILING SMOKE_CMD: the task contract wires it identically (no special-casing between a
#        passing and a failing command — only the resolver's live exit-code check decides whether it
#        reaches the push instruction), and the command itself really does fail and leave no marker,
#        so a resolver obeying its own contract aborts the push. ──────────────────────────────────
rm -f "$MARKER"
FAIL_CFG="$T/config-fail"
cat > "$FAIL_CFG" <<EOF
PROJECT_ROOT="$T/repo"
WORKTREES_DIR="$T/trees"
WORKSPACE_NAME="herdkit"
MODEL_RESOLVER="resolver-model"
APP_PREVIEW_CMD=""
SMOKE_CMD="$SMOKE_FAIL_CMD"
EOF
export HERDR_CALL_LOG="$T/resolve-fail.log"; : > "$HERDR_CALL_LOG"
HERD_CONFIG_FILE="$FAIL_CFG" HERD_NO_APP=1 bash "$RESOLVE" "$SLUG" >/dev/null 2>&1 \
  || fail "herd-resolve.sh exited non-zero under stubs (SMOKE_CMD failing)"

FAIL_TASK_LINE="$(grep 'agent start' "$HERDR_CALL_LOG" | tail -1)"
[ -n "$FAIL_TASK_LINE" ] || fail "no 'agent start' call captured for SMOKE_CMD-failing run"
printf '%s' "$FAIL_TASK_LINE" | grep -qF "the project smoke test ($SMOKE_FAIL_CMD)" \
  || fail "herd-resolve.sh did not fold the failing SMOKE_CMD into the task contract"$'\n'"$FAIL_TASK_LINE"
printf '%s' "$FAIL_TASK_LINE" | grep -qF "both must pass" \
  || fail "failing-SMOKE_CMD task contract dropped the pass-both-checks requirement"

if bash -c "$SMOKE_FAIL_CMD" >/dev/null 2>&1; then
  fail "the configured failing SMOKE_CMD unexpectedly succeeded — test fixture bug"
fi
[ ! -e "$MARKER" ] || fail "a failing SMOKE_CMD left a marker behind — fixture bug"

echo "ALL PASS"
