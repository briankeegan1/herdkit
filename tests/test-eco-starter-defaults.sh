#!/usr/bin/env bash
# test-eco-starter-defaults.sh — hermetic tests for the eco-leaning STARTER model defaults that a
# fresh `herd init` seeds into a NEW consumer's .herd/config (part (a) of "Evidence-based model
# escalation"). The starter defaults now lean eco and treat Opus as an ESCALATION tier reached via
# MODEL_ESCALATE_GLOB / REVIEW_ESCALATE_GLOB, not a default. Asserts:
#   (1) a fresh, non-interactive `herd init` writes the eco starter tiers to .herd/config
#       (MODEL_QUICK=haiku, MODEL_FEATURE=sonnet, MODEL_REVIEW=sonnet; MODEL_COORDINATOR stays Opus)
#       and herd-config.sh RESOLVES those written values unchanged.
#   (2) the hard invariant holds: an explicit MODEL_* key in a consumer's .herd/config ALWAYS beats
#       the starter default, and TOKEN_MODE / MODEL_ESCALATE_GLOB compose on top.
#   (3) this dogfood repo's OWN .herd/config is untouched by the starter-default change — its explicit
#       Opus overrides (MODEL_QUICK/MODEL_FEATURE/MODEL_REVIEW=Opus) are still present verbatim.
#   (4) the shipped starter surfaces (bin/herd cmd_init + templates/config.example) agree on the eco
#       tiers, so a fresh install and its documented example never drift.
# No $HOME mutation, no network (a fake gh is never needed — init degrades gracefully without gh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
LOADER="$REPO/scripts/herd/herd-config.sh"
CFG_EXAMPLE="$REPO/templates/config.example"
DOGFOOD_CFG="$REPO/.herd/config"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

command -v git >/dev/null 2>&1 || fail "git required to run this test"

# Source the loader against a given config file, from a cwd with no .herd/config above it (so the
# walk-up discovery can't pick up a stray config), and dump the resolved model keys.
load_models() {
  local cfg="$1"
  ( cd "$T" && HERD_CONFIG_FILE="$cfg" bash -c ". '$LOADER'
echo MODEL_COORDINATOR=\$MODEL_COORDINATOR
echo MODEL_FEATURE=\$MODEL_FEATURE
echo MODEL_QUICK=\$MODEL_QUICK
echo MODEL_SCRIBE=\$MODEL_SCRIBE
echo MODEL_RESEARCH=\$MODEL_RESEARCH
echo MODEL_REVIEW=\$MODEL_REVIEW
echo MODEL_ESCALATE_GLOB=\$MODEL_ESCALATE_GLOB" )
}
kv() { echo "$1" | grep -qx "$2" || fail "$3 (wanted $2)"$'\n'"--- dump ---"$'\n'"$1"; }

# ── (1) a fresh non-interactive `herd init` seeds the eco starter tiers; the loader resolves them ──
proj="$T/fresh"; mkdir -p "$proj"
git -C "$proj" init -q
git -C "$proj" config user.email t@t.t; git -C "$proj" config user.name t
git -C "$proj" commit -q --allow-empty -m init
git -C "$proj" branch -M main
git -C "$proj" remote add origin git@github.com:acme/widgets.git
( cd "$proj" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" init >/dev/null 2>&1 ) \
  || fail "(1) fresh herd init should succeed"
cfg="$proj/.herd/config"
[ -f "$cfg" ] || fail "(1) init did not write .herd/config"
# the eco starter tiers, as WRITTEN into the fresh config:
grep -qE '^MODEL_QUICK="claude-haiku-4-5"$'      "$cfg" || fail "(1) starter MODEL_QUICK not haiku: $(grep MODEL_QUICK "$cfg")"
grep -qE '^MODEL_FEATURE="claude-sonnet-4-6"$'   "$cfg" || fail "(1) starter MODEL_FEATURE not sonnet: $(grep MODEL_FEATURE "$cfg")"
grep -qE '^MODEL_REVIEW="claude-sonnet-4-6"$'    "$cfg" || fail "(1) starter MODEL_REVIEW not sonnet: $(grep MODEL_REVIEW "$cfg")"
# Opus is retained ONLY where it is not an escalation-reachable tier (the persistent coordinator):
grep -qE '^MODEL_COORDINATOR="claude-opus-4-8"$' "$cfg" || fail "(1) MODEL_COORDINATOR should stay Opus: $(grep MODEL_COORDINATOR "$cfg")"
# and the loader RESOLVES those written values unchanged (no fallback clobbers them):
out="$(load_models "$cfg")"
kv "$out" "MODEL_QUICK=claude-haiku-4-5"    "(1) loader resolved MODEL_QUICK"
kv "$out" "MODEL_FEATURE=claude-sonnet-4-6" "(1) loader resolved MODEL_FEATURE"
kv "$out" "MODEL_REVIEW=claude-sonnet-4-6"  "(1) loader resolved MODEL_REVIEW"
ok

# ── (2) hard invariant: an explicit MODEL_* consumer override ALWAYS beats the starter default,
#        and TOKEN_MODE / MODEL_ESCALATE_GLOB compose on top ─────────────────────────────────────
cat > "$T/override" <<'EOF'
MODEL_QUICK="claude-opus-4-8"
MODEL_REVIEW="claude-opus-4-8"
TOKEN_MODE="eco"
MODEL_ESCALATE_GLOB="bin/herd|agent-watch"
EOF
out="$(load_models "$T/override")"
# explicit keys win over BOTH the starter default and the eco tier:
kv "$out" "MODEL_QUICK=claude-opus-4-8"  "(2) explicit MODEL_QUICK override did not win"
kv "$out" "MODEL_REVIEW=claude-opus-4-8" "(2) explicit MODEL_REVIEW override did not win"
# a non-overridden key still takes the composed eco tier (TOKEN_MODE composes on top of the starter):
kv "$out" "MODEL_FEATURE=claude-sonnet-4-6" "(2) non-overridden MODEL_FEATURE lost its composed tier"
# MODEL_ESCALATE_GLOB is carried through, ready to step a matching lane up to the feature tier:
kv "$out" "MODEL_ESCALATE_GLOB=bin/herd|agent-watch" "(2) MODEL_ESCALATE_GLOB did not compose through"
ok

# ── (3) the change does NOT edit THIS dogfood repo's own .herd/config — its Opus overrides remain ──
[ -f "$DOGFOOD_CFG" ] || fail "(3) dogfood .herd/config missing"
grep -qE '^MODEL_QUICK="claude-opus-4-8"$'   "$DOGFOOD_CFG" || fail "(3) dogfood MODEL_QUICK override was altered"
grep -qE '^MODEL_FEATURE="claude-opus-4-8"$' "$DOGFOOD_CFG" || fail "(3) dogfood MODEL_FEATURE override was altered"
grep -qE '^MODEL_REVIEW="claude-opus-4-8"$'  "$DOGFOOD_CFG" || fail "(3) dogfood MODEL_REVIEW override was altered"
# git agrees the tracked dogfood config is unmodified by this change:
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO" diff --quiet -- .herd/config || fail "(3) dogfood .herd/config has an uncommitted diff"
fi
ok

# ── (4) shipped starter surfaces agree: cmd_init defaults == documented config.example tiers ──────
for f in "$HERD" "$CFG_EXAMPLE"; do
  grep -qE '^MODEL_QUICK="claude-haiku-4-5"'    "$f" || fail "(4) $f: MODEL_QUICK not eco haiku"
  grep -qE '^MODEL_FEATURE="claude-sonnet-4-6"' "$f" || fail "(4) $f: MODEL_FEATURE not eco sonnet"
  grep -qE '^MODEL_REVIEW="claude-sonnet-4-6"'  "$f" || fail "(4) $f: MODEL_REVIEW not eco sonnet"
  # the starter surfaces must NOT default the escalation-reachable lanes to Opus anymore:
  grep -qE '^MODEL_FEATURE="claude-opus-4-8"' "$f" && fail "(4) $f: MODEL_FEATURE still defaults to Opus"
  grep -qE '^MODEL_REVIEW="claude-opus-4-8"'  "$f" && fail "(4) $f: MODEL_REVIEW still defaults to Opus"
done
ok

echo "ALL PASS ($pass checks)"
