#!/usr/bin/env bash
# test-token-mode.sh — hermetic test of TOKEN_MODE=eco in herd-config.sh. Verifies the three
# invariants of the opt-in economy mode:
#   1. TOKEN_MODE=eco flips every BUILT-IN model default to the eco tier (research report Bucket B):
#      coordinator/feature→claude-sonnet-4-6, quick/scribe/research/resolver→claude-haiku-4-5,
#      review→claude-sonnet-4-6.
#   2. An explicit MODEL_* key in .herd/config ALWAYS beats the eco tier — eco replaces built-in
#      defaults only, never a user override. Non-overridden keys still take the eco tier.
#   3. TOKEN_MODE=standard OR unset changes nothing — every default stays at its standard value
#      (zero behavior change for existing projects).
# No $HOME mutation, no network. Run:  bash tests/test-token-mode.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOADER="$HERE/../scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }

# Source the loader with a given config file, from a cwd with no .herd/config above it (so the
# walk-up discovery can't pick up a stray config), and dump TOKEN_MODE + the seven model keys.
load_models() {
  local cfg="$1"
  ( cd "$T" && HERD_CONFIG_FILE="$cfg" bash -c ". '$LOADER'
echo TOKEN_MODE=\$TOKEN_MODE
echo MODEL_COORDINATOR=\$MODEL_COORDINATOR
echo MODEL_FEATURE=\$MODEL_FEATURE
echo MODEL_QUICK=\$MODEL_QUICK
echo MODEL_SCRIBE=\$MODEL_SCRIBE
echo MODEL_RESEARCH=\$MODEL_RESEARCH
echo MODEL_REVIEW=\$MODEL_REVIEW
echo MODEL_RESOLVER=\$MODEL_RESOLVER" )
}

kv(){ echo "$1" | grep -qx "$2" || fail "$3 (wanted $2)"$'\n'"--- dump ---"$'\n'"$1"; }

# ── 1. TOKEN_MODE=eco → every built-in default flips to the eco tier ──────────────────────────
cat > "$T/eco" <<'EOF'
TOKEN_MODE="eco"
EOF
out="$(load_models "$T/eco")"
kv "$out" "TOKEN_MODE=eco"                       "eco: TOKEN_MODE not read"
kv "$out" "MODEL_COORDINATOR=claude-sonnet-4-6"  "eco: MODEL_COORDINATOR not flipped"
kv "$out" "MODEL_FEATURE=claude-sonnet-4-6"      "eco: MODEL_FEATURE not flipped"
kv "$out" "MODEL_QUICK=claude-haiku-4-5"         "eco: MODEL_QUICK not flipped"
kv "$out" "MODEL_SCRIBE=claude-haiku-4-5"        "eco: MODEL_SCRIBE not flipped"
kv "$out" "MODEL_RESEARCH=claude-haiku-4-5"      "eco: MODEL_RESEARCH not flipped"
kv "$out" "MODEL_REVIEW=claude-sonnet-4-6"       "eco: MODEL_REVIEW not flipped"
kv "$out" "MODEL_RESOLVER=claude-haiku-4-5"      "eco: MODEL_RESOLVER not flipped"

# ── 2. Explicit MODEL_* keys ALWAYS beat eco; non-overridden keys keep the eco tier ───────────
cat > "$T/eco-override" <<'EOF'
TOKEN_MODE="eco"
MODEL_REVIEW="claude-opus-4-8"
MODEL_FEATURE="claude-opus-4-8"
MODEL_QUICK="claude-sonnet-4-6"
EOF
out="$(load_models "$T/eco-override")"
kv "$out" "MODEL_REVIEW=claude-opus-4-8"         "override: explicit MODEL_REVIEW did not beat eco"
kv "$out" "MODEL_FEATURE=claude-opus-4-8"        "override: explicit MODEL_FEATURE did not beat eco"
kv "$out" "MODEL_QUICK=claude-sonnet-4-6"        "override: explicit MODEL_QUICK did not beat eco"
kv "$out" "MODEL_COORDINATOR=claude-sonnet-4-6"  "override: non-overridden key lost its eco tier"
kv "$out" "MODEL_SCRIBE=claude-haiku-4-5"        "override: non-overridden scribe lost its eco tier"
kv "$out" "MODEL_RESOLVER=claude-haiku-4-5"      "override: non-overridden resolver lost its eco tier"

# ── 3a. TOKEN_MODE=standard → standard defaults, unchanged ────────────────────────────────────
cat > "$T/std" <<'EOF'
TOKEN_MODE="standard"
EOF
out="$(load_models "$T/std")"
kv "$out" "TOKEN_MODE=standard"                  "standard: TOKEN_MODE not read"
kv "$out" "MODEL_COORDINATOR=claude-opus-4-8"    "standard: MODEL_COORDINATOR changed"
kv "$out" "MODEL_FEATURE=claude-sonnet-4-6"      "standard: MODEL_FEATURE changed"
kv "$out" "MODEL_QUICK=claude-haiku-4-5"         "standard: MODEL_QUICK changed"
kv "$out" "MODEL_SCRIBE=claude-sonnet-4-6"       "standard: MODEL_SCRIBE changed"
kv "$out" "MODEL_RESEARCH=claude-sonnet-4-6"     "standard: MODEL_RESEARCH changed"
kv "$out" "MODEL_REVIEW=claude-sonnet-4-6"       "standard: MODEL_REVIEW changed"
kv "$out" "MODEL_RESOLVER=claude-sonnet-4-6"     "standard: MODEL_RESOLVER changed"

# ── 3b. TOKEN_MODE UNSET (key absent entirely) → identical to standard; defaults to 'standard' ─
cat > "$T/unset" <<'EOF'
BACKLOG_FILE="BACKLOG.md"
EOF
out="$(load_models "$T/unset")"
kv "$out" "TOKEN_MODE=standard"                  "unset: TOKEN_MODE did not default to standard"
kv "$out" "MODEL_COORDINATOR=claude-opus-4-8"    "unset: MODEL_COORDINATOR changed"
kv "$out" "MODEL_FEATURE=claude-sonnet-4-6"      "unset: MODEL_FEATURE changed"
kv "$out" "MODEL_QUICK=claude-haiku-4-5"         "unset: MODEL_QUICK changed"
kv "$out" "MODEL_SCRIBE=claude-sonnet-4-6"       "unset: MODEL_SCRIBE changed"
kv "$out" "MODEL_RESEARCH=claude-sonnet-4-6"     "unset: MODEL_RESEARCH changed"
kv "$out" "MODEL_REVIEW=claude-sonnet-4-6"       "unset: MODEL_REVIEW changed"
kv "$out" "MODEL_RESOLVER=claude-sonnet-4-6"     "unset: MODEL_RESOLVER changed"

echo "ALL PASS"
