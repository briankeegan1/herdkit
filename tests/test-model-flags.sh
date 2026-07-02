#!/usr/bin/env bash
# test-model-flags.sh — hermetic proof that the coordinator and resolver lanes pass an explicit
# `--model` to `claude`, so the MODEL_COORDINATOR / MODEL_RESOLVER config keys are actually WIRED
# (not dead). Regression guard for two token-cost bugs: coordinator.sh started claude with no
# --model at all (config key ignored → ran on the CLI's ambient default), and herd-resolve.sh had
# no model control whatsoever.
#
# Stubs herdr/claude (NETWORK-FREE, no real tabs). Asserts the `herdr agent start … -- claude …`
# invocation each script emits carries `--model <sentinel>` matching the configured key.
# Run:  bash tests/test-model-flags.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COORD="$HERE/../scripts/herd/coordinator.sh"
RESOLVE="$HERE/../scripts/herd/herd-resolve.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stubs ─────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
# herdr stub: log every call ($*) to $HERDR_CALL_LOG, return the fixed JSON each parse expects.
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

# ── Config with SENTINEL model values so the grep is unambiguous ───────────────
CFG="$T/config"
cat > "$CFG" <<EOF
PROJECT_ROOT="$T/repo"
WORKTREES_DIR="$T/trees"
WORKSPACE_NAME="herdkit"
MODEL_COORDINATOR="SENTINEL-COORD-MODEL"
MODEL_RESOLVER="SENTINEL-RESOLVER-MODEL"
APP_PREVIEW_CMD=""
EOF
mkdir -p "$T/repo" "$T/trees"
export HERD_CONFIG_FILE="$CFG"
export WORKSPACE_NAME="herdkit"       # matches the herdr stub's workspace label
export HERD_SKIP_PREFLIGHT=1           # no real herdr contract to probe

# ── (1) coordinator.sh wires MODEL_COORDINATOR ────────────────────────────────
export HERDR_CALL_LOG="$T/coord.log"; : > "$HERDR_CALL_LOG"
HERD_NO_WATCH=1 bash "$COORD" >/dev/null 2>&1 || fail "coordinator.sh exited non-zero under stubs"
grep -qE 'agent start .*-- claude --model SENTINEL-COORD-MODEL' "$HERDR_CALL_LOG" \
  || fail "coordinator.sh did not pass --model MODEL_COORDINATOR to claude (MODEL_COORDINATOR is dead)"$'\n'"$(cat "$HERDR_CALL_LOG")"

# ── (2) herd-resolve.sh wires MODEL_RESOLVER ──────────────────────────────────
export HERDR_CALL_LOG="$T/resolve.log"; : > "$HERDR_CALL_LOG"
SLUG="demo-slug"; mkdir -p "$T/trees/$SLUG"; : > "$T/trees/$SLUG/.git"   # look like a worktree
HERD_NO_APP=1 bash "$RESOLVE" "$SLUG" >/dev/null 2>&1 || fail "herd-resolve.sh exited non-zero under stubs"
grep -qE 'agent start .*-- claude --model SENTINEL-RESOLVER-MODEL' "$HERDR_CALL_LOG" \
  || fail "herd-resolve.sh did not pass --model MODEL_RESOLVER to claude"$'\n'"$(cat "$HERDR_CALL_LOG")"

echo "ALL PASS"
