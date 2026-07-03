#!/usr/bin/env bash
# test-config-key-docs.sh — hermetic proof for the two filed follow-ups:
#   • "capabilities.tsv: document watcher-dep-states config keys"  (PR #107 dep-watcher.sh knobs)
#   • "capabilities.tsv: document app-preview probe/port config keys" (PR #108 app-monitor.sh/lane knobs)
#
# Those keys shipped as INLINE hardcoded defaults with NO capabilities.tsv entry. This test locks in
# that they are now (1) proper documented config keys AND (2) genuinely read from .herd/config with the
# SAME inline value as fallback — so a documented key OVERRIDES its default, and an unset key preserves
# today's behavior byte-for-byte.
#
# Fully hermetic: local temp only, NO herdr, NO gh, NO network, NO model. dep-watcher.sh is sourced in
# its LIB mode (helpers only, no polling loop) inside subshells so config-vs-default cases can't leak
# into each other. The app-preview keys' behavioral override is proven by test-app-preview-config.sh;
# here we lock the DEFAULT VALUES in the docs against the scripts' inline fallbacks so they can't drift.
# Run:  bash tests/test-config-key-docs.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WATCHER="$ROOT/scripts/herd/dep-watcher.sh"
MONITOR="$ROOT/scripts/herd/app-monitor.sh"
FEATURE="$ROOT/scripts/herd/herd-feature.sh"
CAPS="$ROOT/templates/capabilities.tsv"
CFG_EXAMPLE="$ROOT/templates/config.example"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "$WATCHER" "$MONITOR" "$FEATURE" "$CAPS" "$CFG_EXAMPLE"; do
  [ -f "$f" ] || fail "missing required file: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# read_dep_var <config-file> <var> — source dep-watcher.sh in LIB mode against <config-file> in a fresh
# subshell and print the resolved value of <var>. An empty/absent config exercises the inline default.
read_dep_var() {
  local cfg="$1" var="$2"
  (
    export DEP_WATCHER_LIB=1
    export HERD_CONFIG_FILE="$cfg"
    export WORKTREES_DIR="$T/wt"
    export PROJECT_ROOT="$T/project"
    export WORKSPACE_NAME="cfgkeytest"
    mkdir -p "$PROJECT_ROOT/.herd" "$WORKTREES_DIR" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$WATCHER" >/dev/null 2>&1 || { echo "__SOURCE_FAILED__"; exit 0; }
    printf '%s' "${!var}"
  )
}

# ── 1. dep-watcher keys UNSET → inline defaults (current behavior preserved) ─────────────────────────
NOCFG="$T/no-such-config"   # absent file → herd-config.sh falls back to generic defaults
[ "$(read_dep_var "$NOCFG" DEP_POLL_MIN)"  = "30" ]    || fail "(1) DEP_POLL_MIN default must be 30 when unset"
[ "$(read_dep_var "$NOCFG" DEP_POLL_MAX)"  = "300" ]   || fail "(1) DEP_POLL_MAX default must be 300 when unset"
[ "$(read_dep_var "$NOCFG" DEP_STALE_TTL)" = "86400" ] || fail "(1) DEP_STALE_TTL default must be 86400 when unset"
pass
echo "PASS (1) dep-watcher keys unset → inline defaults 30 / 300 / 86400 (behavior unchanged)"

# ── 2. dep-watcher keys SET in .herd/config → override the defaults ──────────────────────────────────
cat > "$T/cfg-dep" <<'EOF'
DEP_POLL_MIN="45"
DEP_POLL_MAX="555"
DEP_STALE_TTL="1234"
EOF
[ "$(read_dep_var "$T/cfg-dep" DEP_POLL_MIN)"  = "45" ]   || fail "(2) DEP_POLL_MIN must read 45 from config"
[ "$(read_dep_var "$T/cfg-dep" DEP_POLL_MAX)"  = "555" ]  || fail "(2) DEP_POLL_MAX must read 555 from config"
[ "$(read_dep_var "$T/cfg-dep" DEP_STALE_TTL)" = "1234" ] || fail "(2) DEP_STALE_TTL must read 1234 from config"
pass
echo "PASS (2) dep-watcher keys set in .herd/config override the inline defaults (45 / 555 / 1234)"

# ── 3. DEP_STALE_TTL=0 flows through (stall surfacing disabled) ──────────────────────────────────────
cat > "$T/cfg-ttl0" <<'EOF'
DEP_STALE_TTL="0"
EOF
[ "$(read_dep_var "$T/cfg-ttl0" DEP_STALE_TTL)" = "0" ] || fail "(3) DEP_STALE_TTL=0 must flow through to disable stalling"
pass
echo "PASS (3) DEP_STALE_TTL=0 flows through from config (stall surfacing can be disabled)"

# ── 4. Every documented key is a `config` row in capabilities.tsv AND appears in config.example ───────
DOC_KEYS=(
  DEP_POLL_MIN DEP_POLL_MAX DEP_STALE_TTL
  APP_PREVIEW_SERVER_ARGS APP_PREVIEW_HEALTH_CMD APP_PREVIEW_HEALTH_PATH APP_PREVIEW_PORT_BASE
)
for k in "${DOC_KEYS[@]}"; do
  awk -F'\t' -v k="$k" '$1==k && $2=="config"{found=1} END{exit found?0:1}' "$CAPS" \
    || fail "(4) $k missing a 'config' row in capabilities.tsv"
  grep -q -- "$k" "$CFG_EXAMPLE" \
    || fail "(4) $k not documented in config.example"
done
pass
echo "PASS (4) all 7 keys are documented config rows in capabilities.tsv and appear in config.example"

# ── 5. Documented defaults MATCH the scripts' inline fallbacks (drift guard) ─────────────────────────
# The single source of truth for behavior is each script's inline fallback; the docs must not diverge.
grep -Eq 'DEP_POLL_MIN="\$\{DEP_POLL_MIN:-30\}"'        "$WATCHER" || fail "(5) dep-watcher inline default for DEP_POLL_MIN changed from 30"
grep -Eq 'DEP_POLL_MAX="\$\{DEP_POLL_MAX:-300\}"'       "$WATCHER" || fail "(5) dep-watcher inline default for DEP_POLL_MAX changed from 300"
grep -Eq 'DEP_STALE_TTL="\$\{DEP_STALE_TTL:-86400\}"'   "$WATCHER" || fail "(5) dep-watcher inline default for DEP_STALE_TTL changed from 86400"
grep -Eq 'APP_PREVIEW_HEALTH_PATH-/'                    "$MONITOR" || fail "(5) app-monitor inline default for APP_PREVIEW_HEALTH_PATH changed from /"
grep -Eq 'APP_PREVIEW_SERVER_ARGS-"--server.port \{port\} --server.headless true"' "$MONITOR" \
  || fail "(5) app-monitor inline default for APP_PREVIEW_SERVER_ARGS changed"
grep -Eq 'APP_PREVIEW_PORT_BASE:-8501'                  "$FEATURE" || fail "(5) lane inline default for APP_PREVIEW_PORT_BASE changed from 8501"
# capabilities.tsv documents the same numeric defaults.
for pair in "DEP_POLL_MIN:30" "DEP_POLL_MAX:300" "DEP_STALE_TTL:86400" "APP_PREVIEW_PORT_BASE:8501"; do
  key="${pair%%:*}"; val="${pair##*:}"
  awk -F'\t' -v k="$key" '$1==k{print $3}' "$CAPS" | grep -q "default: $val" \
    || fail "(5) capabilities.tsv row for $key must document 'default: $val'"
done
pass
echo "PASS (5) documented defaults match the scripts' inline fallbacks (30/300/86400, /, 8501, server-args)"

echo
echo "ALL PASS ($PASS checks) — dep-state + app-preview config keys documented and read from config with inline fallbacks."
