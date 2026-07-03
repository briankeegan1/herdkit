#!/usr/bin/env bash
# test-upgrade-config-adoption.sh — hermetic test of `herd upgrade`'s additive config-key adoption
# (bin/herd: _config_adopt_additive + cmd_upgrade, issue #74). No network, no claude, no herdr.
# A custom template is pointed at via HERD_CONFIG_TEMPLATE so the test is stable regardless of future
# edits to the real templates/config.example. Verifies:
#   1. a config MISSING a new template key gets it APPENDED with the template's default AND comment;
#   2. an existing custom value is PRESERVED verbatim (never overwritten, never duplicated);
#   3. DENY_PATHS and secret-shaped keys are NEVER adopted (they belong in .herd/secrets);
#   4. the summary line 'herd upgrade: adopted N new config keys: <names>' is printed;
#   5. idempotent: a second upgrade adopts nothing and leaves the config byte-identical.
# Run:  bash tests/test-upgrade-config-adoption.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }

# sourced <cfg> <KEY> — the value KEY resolves to when the config is SOURCED as shell (inline # comments
# dropped by the shell, exactly as herd-config.sh / render_skill read it). This is the semantics that
# matters: an adopted line like  KEY="on"   # comment  must source to  on.
sourced() { ( set +u; . "$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" ); }
# count_key <cfg> <KEY> — how many assignment lines exist for KEY (stays 1 across idempotent runs).
count_key() { grep -cE "^[[:space:]]*$2=" "$1" || true; }

# Canonical template this "engine version" ships. It has: keys the consumer already has, a brand-new
# additive feature knob with an inline comment, a model key sitting under a shared SECTION HEADER
# comment, plus DENY_PATHS and a secret-shaped key that must NEVER be adopted.
TPL="$T/config.example"
cat > "$TPL" <<'EOF'
# test template header
HERD_VERSION=1                       # engine contract version
PROJECT_ROOT="$HOME/src/myproj"      # the main checkout
WORKSPACE_NAME="myproj"              # herdr workspace label

# a brand-new feature knob added by this engine version
NEW_FEATURE_FLAG="on"                # enables the shiny new feature

# model map — role → model (shared section header)
MODEL_REVIEW="claude-sonnet-4-6"     # pre-merge gate

DENY_PATHS="data/"                   # path scoping — never auto-adopted
DEPLOY_TOKEN="tpl-should-not-adopt"  # secret-shaped — never auto-adopted
EOF

# Consumer config: an OLDER project. It set a CUSTOM MODEL_REVIEW (must be preserved) and is missing
# NEW_FEATURE_FLAG (must be adopted), DENY_PATHS + DEPLOY_TOKEN (must NOT be adopted).
P="$T/proj"
mkdir -p "$P/.herd"
cat > "$P/.herd/config" <<EOF
PROJECT_ROOT="$P"
WORKSPACE_NAME="consumer"
MODEL_REVIEW="claude-opus-4-8"       # my custom override — must be preserved
HERD_VERSION=1
EOF

# ── run 1: upgrade (target=1 → migrations are a clean no-op; only adoption should act) ────────────
out1="$( cd "$P" && HERD_TARGET_VERSION=1 HERD_CONFIG_TEMPLATE="$TPL" bash "$HERD" upgrade 2>&1 )" \
  || fail "upgrade run 1 failed:\n$out1"
CFG="$P/.herd/config"

# 1. the new key was appended with the template's default value AND its explanatory comment.
[ "$(sourced "$CFG" NEW_FEATURE_FLAG)" = "on" ] || fail "NEW_FEATURE_FLAG not adopted with template default (got '$(sourced "$CFG" NEW_FEATURE_FLAG)')"
grep -qE '^NEW_FEATURE_FLAG="on" .*# enables the shiny new feature' "$CFG" || fail "adopted key did not land verbatim with its default + explanatory comment"
[ "$(count_key "$CFG" NEW_FEATURE_FLAG)" -eq 1 ] || fail "NEW_FEATURE_FLAG appended more than once"

# 2. the existing custom value is preserved verbatim (not overwritten to the template default, not duped).
[ "$(sourced "$CFG" MODEL_REVIEW)" = "claude-opus-4-8" ] || fail "custom MODEL_REVIEW overwritten (got '$(sourced "$CFG" MODEL_REVIEW)')"
[ "$(count_key "$CFG" MODEL_REVIEW)" -eq 1 ]             || fail "MODEL_REVIEW duplicated by adoption"

# 3. secrets / path-scoping keys are NEVER adopted.
[ "$(count_key "$CFG" DENY_PATHS)"   -eq 0 ] || fail "DENY_PATHS was adopted (must never be)"
[ "$(count_key "$CFG" DEPLOY_TOKEN)" -eq 0 ] || fail "secret-shaped DEPLOY_TOKEN was adopted (must never be)"

# 4. the summary line names the adopted key(s) and the count.
echo "$out1" | grep -qE "herd upgrade: adopted 1 new config keys: .*NEW_FEATURE_FLAG" \
  || fail "missing/incorrect adoption summary line:\n$out1"

# ── run 2: idempotent — adopts nothing, config unchanged ─────────────────────────────────────────
snapshot="$(cat "$CFG")"
out2="$( cd "$P" && HERD_TARGET_VERSION=1 HERD_CONFIG_TEMPLATE="$TPL" bash "$HERD" upgrade 2>&1 )" \
  || fail "upgrade run 2 failed:\n$out2"
echo "$out2" | grep -q "adopted" && fail "second run adopted keys (should be a no-op):\n$out2"
[ "$(cat "$CFG")" = "$snapshot" ]                || fail "second run mutated .herd/config"
[ "$(count_key "$CFG" NEW_FEATURE_FLAG)" -eq 1 ] || fail "second run duplicated NEW_FEATURE_FLAG"

echo "ALL PASS"
