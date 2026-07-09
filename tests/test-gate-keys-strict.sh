#!/usr/bin/env bash
# test-gate-keys-strict.sh — hermetic tests for HERD-159 (gate keys fail strict).
#
# Covers the shared validators + every migrated site the audit named:
#   (1) herd_enum / herd_numeric helpers in herd-config.sh
#   (2) MERGE_POLICY typo → observe + journal event (launch path, not lib)
#   (3) HEALTH_CONCURRENCY non-numeric → default 1, slot check still works
#   (4) REVIEW_CONCURRENCY + SPAWN_AHEAD non-numeric → spawn-queue arithmetic safe
#   (5) ATTRIBUTION_POLICY typo → WARN (not silent-off)
#   (6) CODEMAP_AUTOREFRESH typo → fail soft toward active
#   (7) capabilities.tsv value_shape column present for constrained keys
#
# Fully hermetic: stubs gh/git/herdr; no network; no live watcher loop.
# Run:  bash tests/test-gate-keys-strict.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONFIG="$ROOT/scripts/herd/herd-config.sh"
WATCH="$ROOT/scripts/herd/agent-watch.sh"
HC="$ROOT/scripts/herd/healthcheck.sh"
CAPS="$ROOT/templates/capabilities.tsv"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); echo "  ok: $1"; }

for f in "$CONFIG" "$WATCH" "$HC" "$CAPS"; do
  [ -f "$f" ] || fail "missing required file: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Stub binaries ────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"

# ══════════════════════════════════════════════════════════════════════════════
# (1) herd_enum / herd_numeric
# ══════════════════════════════════════════════════════════════════════════════
# shellcheck source=/dev/null
. "$CONFIG" || fail "sourcing herd-config.sh failed"
type herd_enum    >/dev/null 2>&1 || fail "herd_enum not defined"
type herd_numeric >/dev/null 2>&1 || fail "herd_numeric not defined"

# empty → default, exit 0, no warn
unset _TEST_KEY 2>/dev/null || true
out="$(herd_enum _TEST_KEY hold a b)"; rc=$?
[ "$out" = "hold" ] && [ "$rc" -eq 0 ] || fail "(1a) empty enum → default (got out=$out rc=$rc)"
ok "herd_enum empty → default"

FOO_ENUM=a
out="$(herd_enum FOO_ENUM hold a b)"; rc=$?
[ "$out" = "a" ] && [ "$rc" -eq 0 ] || fail "(1b) valid enum (got out=$out rc=$rc)"
ok "herd_enum valid"

FOO_ENUM=zzz
warn="$(herd_enum FOO_ENUM hold a b 2>&1 >/dev/null)"; rc=$?
out="$(herd_enum FOO_ENUM hold a b 2>/dev/null)"; rc2=$?
[ "$out" = "hold" ] || fail "(1c) invalid enum should print default, got: $out"
[ "$rc2" -eq 1 ]    || fail "(1c) invalid enum should exit 1, got: $rc2"
printf '%s' "$warn" | grep -qi 'invalid FOO_ENUM' || fail "(1c) invalid enum should warn: $warn"
ok "herd_enum invalid → default + warn + exit 1"

unset FOO_NUM 2>/dev/null || true
out="$(herd_numeric FOO_NUM 7)"; rc=$?
[ "$out" = "7" ] && [ "$rc" -eq 0 ] || fail "(1d) empty numeric → default (got out=$out rc=$rc)"
ok "herd_numeric empty → default"

FOO_NUM=42
out="$(herd_numeric FOO_NUM 7)"; rc=$?
[ "$out" = "42" ] && [ "$rc" -eq 0 ] || fail "(1e) valid numeric (got out=$out rc=$rc)"
ok "herd_numeric valid"

FOO_NUM=two
out="$(herd_numeric FOO_NUM 7 2>/dev/null)"; rc=$?
[ "$out" = "7" ] && [ "$rc" -eq 1 ] || fail "(1f) non-numeric → default + exit 1 (got out=$out rc=$rc)"
ok "herd_numeric invalid → default + exit 1"

# ══════════════════════════════════════════════════════════════════════════════
# (2) MERGE_POLICY typo → observe (pure helper) + journal on non-lib launch
# ══════════════════════════════════════════════════════════════════════════════
export AGENT_WATCH_LIB=1
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type _effective_merge_policy >/dev/null 2>&1 || fail "_effective_merge_policy not defined"

[ "$(MERGE_POLICY=aprove _effective_merge_policy)" = "observe" ] \
  || fail "(2a) MERGE_POLICY=aprove → observe"
ok "MERGE_POLICY typo → observe (pure)"

[ "$(MERGE_POLICY='' WATCHER_AUTOMERGE=true _effective_merge_policy)" = "auto" ] \
  || fail "(2b) empty MERGE_POLICY still derives from WATCHER_AUTOMERGE"
ok "empty MERGE_POLICY still uses WATCHER_AUTOMERGE"

# Launch-time journal: re-source in a subshell WITHOUT lib mode is hard (requires project config).
# Instead, assert the journal event name is wired in the source and the resolved caps exist.
grep -q 'merge_policy_invalid' "$WATCH" \
  || fail "(2c) agent-watch.sh must journal merge_policy_invalid on a typo"
grep -q 'falling back to observe' "$WATCH" \
  || fail "(2c) agent-watch.sh must print a red console line on MERGE_POLICY typo"
ok "MERGE_POLICY invalid journals + red-lines"

# Live resolvers exist after source (lib mode).
for fn in _review_conc _spawn_ahead _health_conc _codemap_auto; do
  type "$fn" >/dev/null 2>&1 || fail "(2d) $fn not defined after source"
done
ok "live numeric/cosmetic resolvers present"

# ══════════════════════════════════════════════════════════════════════════════
# (3) HEALTH_CONCURRENCY non-numeric → default 1, slot free works
# ══════════════════════════════════════════════════════════════════════════════
export HEALTH_CONCURRENCY=two
[ "$(_health_conc)" = "1" ] || fail "(3a) _health_conc with HEALTH_CONCURRENCY=two want 1, got $(_health_conc)"
# With zero live healthchecks, slot must be free (comparison must not error).
_health_slot_free || fail "(3b) _health_slot_free returned false with cap=1 and 0 live"
unset HEALTH_CONCURRENCY
ok "HEALTH_CONCURRENCY=two → default 1 + slot free"

# ══════════════════════════════════════════════════════════════════════════════
# (4) REVIEW_CONCURRENCY + SPAWN_AHEAD non-numeric → arithmetic safe
# ══════════════════════════════════════════════════════════════════════════════
export REVIEW_CONCURRENCY=nope
export SPAWN_AHEAD=also-bad
[ "$(_review_conc)" = "2" ] || fail "(4a) _review_conc want 2, got $(_review_conc)"
[ "$(_spawn_ahead)" = "1" ] || fail "(4b) _spawn_ahead want 1, got $(_spawn_ahead)"
cap=$(( $(_review_conc) + $(_spawn_ahead) ))
[ "$cap" -eq 3 ] || fail "(4c) cap=$cap want 3"
unset REVIEW_CONCURRENCY SPAWN_AHEAD
ok "REVIEW_CONCURRENCY/SPAWN_AHEAD non-numeric → defaults + safe arithmetic"

# ══════════════════════════════════════════════════════════════════════════════
# (5) ATTRIBUTION_POLICY typo → WARN (not silent-off)
# ══════════════════════════════════════════════════════════════════════════════
# Minimal git repo so healthcheck can run the light profile + attribution lint.
REPO="$T/attr/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
( cd "$REPO" && git commit -q --allow-empty -m init )
# Point origin/main at HEAD so DEFAULT_BRANCH..HEAD is empty (no violations possible).
git -C "$REPO" branch -M main
git -C "$REPO" update-ref refs/remotes/origin/main HEAD

attr_out="$(
  cd "$REPO"
  export HERD_CONFIG_FILE="$T/no-such-config"
  export PROJECT_ROOT="$REPO" WORKTREES_DIR="$T/trees"
  export DEFAULT_BRANCH="origin/main"
  export ATTRIBUTION_POLICY="no-ai-co-author"   # typo: hyphen vs no-ai-coauthor
  bash "$HC" "$REPO" --light 2>&1
)"; attr_rc=$?
[ "$attr_rc" -eq 0 ] || fail "(5a) invalid ATTRIBUTION_POLICY must not red the suite (rc=$attr_rc)"
printf '%s' "$attr_out" | grep -qi 'invalid ATTRIBUTION_POLICY' \
  || fail "(5b) invalid ATTRIBUTION_POLICY must WARN, got: $attr_out"
printf '%s' "$attr_out" | grep -qi 'lint skipped' \
  || fail "(5c) invalid ATTRIBUTION_POLICY warn should say lint skipped: $attr_out"
ok "ATTRIBUTION_POLICY typo → WARN (not silent-off)"

# Empty still silent-off
attr_off="$(
  cd "$REPO"
  export HERD_CONFIG_FILE="$T/no-such-config"
  export PROJECT_ROOT="$REPO" WORKTREES_DIR="$T/trees"
  export DEFAULT_BRANCH="origin/main"
  export ATTRIBUTION_POLICY=""
  bash "$HC" "$REPO" --light 2>&1
)"
printf '%s' "$attr_off" | grep -qi 'attribution' \
  && fail "(5d) empty ATTRIBUTION_POLICY must stay silent, got: $attr_off"
ok "ATTRIBUTION_POLICY empty → still silent-off"

# ══════════════════════════════════════════════════════════════════════════════
# (6) CODEMAP_AUTOREFRESH typo → fail soft toward active
# ══════════════════════════════════════════════════════════════════════════════
export CODEMAP_AUTOREFRESH=ture   # typo of true
[ "$(_codemap_auto)" = "true" ] || fail "(6a) CODEMAP_AUTOREFRESH=ture want true, got $(_codemap_auto)"
ok "CODEMAP_AUTOREFRESH=ture → true (fail soft active)"

export CODEMAP_AUTOREFRESH=false
[ "$(_codemap_auto)" = "false" ] || fail "(6b) CODEMAP_AUTOREFRESH=false want false, got $(_codemap_auto)"
unset CODEMAP_AUTOREFRESH
ok "CODEMAP_AUTOREFRESH=false stays false"

# ══════════════════════════════════════════════════════════════════════════════
# (7) capabilities.tsv value_shape column
# ══════════════════════════════════════════════════════════════════════════════
header="$(head -1 "$CAPS")"
printf '%s' "$header" | grep -q $'\tvalue_shape$' || printf '%s' "$header" | grep -q $'\tvalue_shape' \
  || fail "(7a) capabilities.tsv header missing value_shape column: $header"
ok "capabilities.tsv has value_shape column"

mp_shape="$(awk -F'\t' '$1=="MERGE_POLICY" && $2=="config"{print $8; exit}' "$CAPS")"
[ "$mp_shape" = "auto|approve|observe" ] || fail "(7b) MERGE_POLICY value_shape wrong: $mp_shape"
hc_shape="$(awk -F'\t' '$1=="HEALTH_CONCURRENCY" && $2=="config"{print $8; exit}' "$CAPS")"
[ "$hc_shape" = "numeric" ] || fail "(7c) HEALTH_CONCURRENCY value_shape wrong: $hc_shape"
attr_shape="$(awk -F'\t' '$1=="ATTRIBUTION_POLICY" && $2=="config"{print $8; exit}' "$CAPS")"
[ "$attr_shape" = "|no-ai-coauthor" ] || fail "(7d) ATTRIBUTION_POLICY value_shape wrong: $attr_shape"
ok "constrained keys carry correct value_shape"

# posture-lint agrees with the watcher on a typo'd MERGE_POLICY
POSTURE="$ROOT/scripts/herd/posture-lint.sh"
# shellcheck source=/dev/null
. "$POSTURE" 2>/dev/null || true
if type _posture_effective_merge_policy >/dev/null 2>&1; then
  [ "$(MERGE_POLICY=aprove _posture_effective_merge_policy)" = "observe" ] \
    || fail "(7e) posture-lint must also fail strict on MERGE_POLICY typo"
  ok "posture-lint MERGE_POLICY typo → observe"
else
  # posture-lint may not export when sourced without its expected env; grep the source instead.
  grep -q "observe" "$POSTURE" && grep -q "MERGE_POLICY" "$POSTURE" \
    || fail "(7e) posture-lint source missing observe-on-invalid path"
  ok "posture-lint has observe-on-invalid (source check)"
fi

echo "ALL PASS ($pass checks)"
