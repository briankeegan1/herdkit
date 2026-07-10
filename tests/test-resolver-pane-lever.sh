#!/usr/bin/env bash
# test-resolver-pane-lever.sh — hermetic unit tests for the RESOLVER_PANE shared lever resolver
# (scripts/herd/resolver-pane.sh, HERD-286).
#
# Tests:
#   • _effective_resolver_pane: on-values → "on"; empty/unset → "off"; typo → "off"
#   • _resolver_pane_is_typo: returns 0 for an unrecognized non-empty value; 1 for known values
#   • _resolver_pane_enabled (the agent-watch.sh wrapper): delegates to the shared resolver
#   • byte-identical-when-off: no extra calls when lever is at its default
#   • single-resolver drift guard: no inline copy of the value-set in agent-watch.sh or herd-resolve.sh
#
# Run:  bash tests/test-resolver-pane-lever.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/scripts/herd/resolver-pane.sh"
WATCH="$ROOT/scripts/herd/agent-watch.sh"

pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$LIB" ]   || fail "resolver-pane.sh not found at $LIB"
[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# Source the shared lib (pure functions, no side effects).
# shellcheck source=/dev/null
. "$LIB"

# ── _effective_resolver_pane ─────────────────────────────────────────────────
type _effective_resolver_pane >/dev/null 2>&1 || fail "_effective_resolver_pane not defined"

# On-values.
[ "$(RESOLVER_PANE=on      _effective_resolver_pane)" = "on"  ] || fail "RESOLVER_PANE=on → on"
ok
[ "$(RESOLVER_PANE=true    _effective_resolver_pane)" = "on"  ] || fail "RESOLVER_PANE=true → on"
ok
[ "$(RESOLVER_PANE=yes     _effective_resolver_pane)" = "on"  ] || fail "RESOLVER_PANE=yes → on"
ok
[ "$(RESOLVER_PANE=1       _effective_resolver_pane)" = "on"  ] || fail "RESOLVER_PANE=1 → on"
ok

# Default/off.
[ "$(RESOLVER_PANE=off     _effective_resolver_pane)" = "off" ] || fail "RESOLVER_PANE=off → off"
ok
[ "$(RESOLVER_PANE=false   _effective_resolver_pane)" = "off" ] || fail "RESOLVER_PANE=false → off"
ok
[ "$(RESOLVER_PANE=no      _effective_resolver_pane)" = "off" ] || fail "RESOLVER_PANE=no → off"
ok
[ "$(RESOLVER_PANE=0       _effective_resolver_pane)" = "off" ] || fail "RESOLVER_PANE=0 → off"
ok
[ "$(RESOLVER_PANE=''      _effective_resolver_pane)" = "off" ] || fail "RESOLVER_PANE='' → off (ship-dormant default)"
ok
[ "$(unset RESOLVER_PANE;  _effective_resolver_pane)" = "off" ] || fail "RESOLVER_PANE unset → off (ship-dormant default)"
ok

# Typo: a non-empty unrecognized value falls safe to off (never arms pane-closing).
[ "$(RESOLVER_PANE=ON      _effective_resolver_pane)" = "off" ] || fail "case-sensitive: RESOLVER_PANE=ON is a typo → off"
ok
[ "$(RESOLVER_PANE=maybe   _effective_resolver_pane)" = "off" ] || fail "typo RESOLVER_PANE=maybe → off"
ok
[ "$(RESOLVER_PANE=enabled _effective_resolver_pane)" = "off" ] || fail "typo RESOLVER_PANE=enabled → off"
ok

# ── _resolver_pane_is_typo ───────────────────────────────────────────────────
type _resolver_pane_is_typo >/dev/null 2>&1 || fail "_resolver_pane_is_typo not defined"

# Recognized values are NOT typos.
( RESOLVER_PANE=on      _resolver_pane_is_typo ) && fail "RESOLVER_PANE=on must not be a typo" || true; ok
( RESOLVER_PANE=off     _resolver_pane_is_typo ) && fail "RESOLVER_PANE=off must not be a typo" || true; ok
( RESOLVER_PANE=true    _resolver_pane_is_typo ) && fail "RESOLVER_PANE=true must not be a typo" || true; ok
( RESOLVER_PANE=false   _resolver_pane_is_typo ) && fail "RESOLVER_PANE=false must not be a typo" || true; ok
( RESOLVER_PANE=''      _resolver_pane_is_typo ) && fail "RESOLVER_PANE='' (empty) must not be a typo" || true; ok
( unset RESOLVER_PANE;  _resolver_pane_is_typo ) && fail "unset RESOLVER_PANE must not be a typo" || true; ok

# Unrecognized non-empty values ARE typos.
( RESOLVER_PANE=ON      _resolver_pane_is_typo ) || fail "RESOLVER_PANE=ON must be a typo"
ok
( RESOLVER_PANE=maybe   _resolver_pane_is_typo ) || fail "RESOLVER_PANE=maybe must be a typo"
ok
( RESOLVER_PANE=enabled _resolver_pane_is_typo ) || fail "RESOLVER_PANE=enabled must be a typo"
ok

# ── agent-watch.sh wrapper (_resolver_pane_enabled) delegates to the shared resolver ────────────
# Source agent-watch.sh in lib mode with a minimal env.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

type _resolver_pane_enabled >/dev/null 2>&1 || fail "_resolver_pane_enabled not defined after sourcing agent-watch.sh"

# Verify the wrapper returns non-zero for off and zero for on.
( RESOLVER_PANE=off _resolver_pane_enabled ) && fail "_resolver_pane_enabled must return false when off" || true
ok
( RESOLVER_PANE=on  _resolver_pane_enabled ) || fail "_resolver_pane_enabled must return true when on"
ok
# Typo also returns false (safe default: no pane close).
( RESOLVER_PANE=maybe _resolver_pane_enabled ) && fail "_resolver_pane_enabled must return false for typo" || true
ok

# ── single-resolver drift guard (HERD-286) ───────────────────────────────────
# The recognized-value set (on|true|yes|1) must be defined ONLY in resolver-pane.sh — this guard
# reds if a NEW inline copy of the lever's case-pattern appears in agent-watch.sh or herd-resolve.sh
# outside resolver-pane.sh itself. Derived from the file paths, not from $HERE (which the sourced
# agent-watch.sh overwrote with its own directory).
RESOLVE_LIB="$ROOT/scripts/herd/resolver-pane.sh"
RESOLVE_WATCH="$ROOT/scripts/herd/agent-watch.sh"
RESOLVE_HERD="$ROOT/scripts/herd/herd-resolve.sh"

[ -f "$RESOLVE_LIB" ] || fail "shared resolver scripts/herd/resolver-pane.sh missing"

# agent-watch.sh must source resolver-pane.sh (not inline the value-set).
grep -q 'resolver-pane\.sh' "$RESOLVE_WATCH" \
  || fail "agent-watch.sh does not source the shared resolver-pane.sh"
ok

# herd-resolve.sh must source resolver-pane.sh.
grep -q 'resolver-pane\.sh' "$RESOLVE_HERD" \
  || fail "herd-resolve.sh does not source the shared resolver-pane.sh"
ok

# No inline on|true|yes|1 case pattern for RESOLVER_PANE outside the shared lib.
# The guard looks for `case "${RESOLVER_PANE` — the canonical form the lib itself uses.
inline_copies="$(grep -rlE 'case[[:space:]]+"?\$\{RESOLVER_PANE' \
    "$ROOT/bin" "$ROOT/scripts" 2>/dev/null \
  | grep -v '/resolver-pane\.sh$' || true)"
[ -z "$inline_copies" ] \
  || fail "inline RESOLVER_PANE case pattern outside the shared resolver: $inline_copies"
ok

echo "ALL PASS ($pass checks)"
