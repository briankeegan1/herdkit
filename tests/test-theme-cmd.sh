#!/usr/bin/env bash
# test-theme-cmd.sh — hermetic tests for the `herd theme <list|preview|set>` picker (HERD-145), the
# operator surface over the pluggable-theming seam (scripts/herd/theme.sh). Fully offline: drives
# bin/herd against a temp project + a stub capabilities manifest, no herdr/gh/network/model.
#
# Coverage:
#   1. list      — shows every BUILT-IN theme pack (templates/themes/) and marks the ACTIVE one;
#                  a user theme (.herd/themes/<name>/) appears under "user" and shadows a built-in.
#   2. preview   — renders the six palette swatch rows for a named theme (and for the active default);
#                  an unknown theme is refused (fail-soft, non-zero).
#   3. set       — validates the name resolves to a COMPLETE theme dir, writes HERD_THEME through the
#                  validated `herd config set` path, and the write is then what theme.sh resolves;
#                  an unknown/incomplete theme is refused and the config is left untouched.
#   4. NO_COLOR  — preview emits NO escape sequences under NO_COLOR (plain swatches).
#
# Run:  bash tests/test-theme-cmd.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
THEME_SH="$REPO/scripts/herd/theme.sh"
BUILTINS="$REPO/templates/themes"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# The three built-in packs this feature ships must each be a COMPLETE theme dir.
for t in tokyonight gruvbox catppuccin nord; do
  [ -f "$BUILTINS/$t/palette.sh" ] && [ -f "$BUILTINS/$t/glow.json" ] \
    || fail "built-in theme '$t' is missing palette.sh or glow.json"
done
pass; echo "PASS (0) built-in packs tokyonight/gruvbox/catppuccin/nord are each complete (palette.sh + glow.json)"

# A temp project + a STUB capabilities manifest whose HERD_THEME row REQUIRES nothing, so `set` takes
# the validated config-set path WITHOUT restarting a real watcher (keeps the test hermetic + offline).
PROJ="$T/proj"; mkdir -p "$PROJ/.herd"
cat > "$PROJ/.herd/config" <<'EOF'
HERD_VERSION=1
WORKSPACE_NAME=proj
HERD_THEME=tokyonight
EOF
CAPS="$T/capabilities.tsv"
{
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\n'
  printf 'HERD_THEME\tconfig\tActive color theme\tSet to switch theme\t\n'
} > "$CAPS"
export HERD_CAPABILITIES_FILE="$CAPS"
run(){ ( cd "$PROJ" && bash "$HERD" "$@" ); }

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 1. list — built-ins shown, active marked; a user theme appears + shadows a built-in of the name.
# ════════════════════════════════════════════════════════════════════════════════════════════════
out="$(run theme list 2>&1)"
for t in tokyonight gruvbox catppuccin nord; do
  echo "$out" | grep -qw "$t" || fail "1a: 'herd theme list' omitted built-in '$t'"
done
echo "$out" | grep -q 'active: tokyonight' || fail "1b: 'herd theme list' did not report the active theme"
echo "$out" | grep -qE '●[[:space:]]*tokyonight' || fail "1c: 'herd theme list' did not MARK the active theme"
pass; echo "PASS (1a) list shows all built-ins and marks the active one"

# Add a user theme + a user shadow of a built-in; both surface under "user", shadow noted on built-in.
mkdir -p "$PROJ/.herd/themes/mine" "$PROJ/.herd/themes/gruvbox"
printf 'C_GREEN=""\n' > "$PROJ/.herd/themes/mine/palette.sh";    printf '{"document":{}}\n' > "$PROJ/.herd/themes/mine/glow.json"
printf 'C_GREEN=""\n' > "$PROJ/.herd/themes/gruvbox/palette.sh"; printf '{"document":{}}\n' > "$PROJ/.herd/themes/gruvbox/glow.json"
out="$(run theme list 2>&1)"
echo "$out" | grep -q 'user'                 || fail "1d: list has no user section"
echo "$out" | grep -qw 'mine'                || fail "1e: list omitted the user theme 'mine'"
echo "$out" | grep -q 'overridden by a user' || fail "1f: list did not note the built-in shadowed by a user theme"
rm -rf "$PROJ/.herd/themes"
pass; echo "PASS (1b) list surfaces user themes and notes a user shadow of a built-in"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 2. preview — six swatch rows for a named theme + for the active default; unknown theme refused.
# ════════════════════════════════════════════════════════════════════════════════════════════════
out="$(run theme preview nord 2>&1)"
echo "$out" | grep -q 'nord'   || fail "2a: preview did not name the theme"
for lbl in blue cyan green yellow red dim; do
  echo "$out" | grep -q "$lbl" || fail "2b: preview missing the '$lbl' swatch row"
done
[ "$(echo "$out" | grep -c '██████')" -eq 6 ] || fail "2c: preview did not render exactly six swatch blocks"
pass; echo "PASS (2a) preview <name> renders the six palette swatches"

out="$(run theme preview 2>&1)"    # no arg → the active theme (tokyonight)
echo "$out" | grep -q 'tokyonight' || fail "2d: preview with no arg did not default to the active theme"
pass; echo "PASS (2b) preview with no argument previews the active theme"

if run theme preview does-not-exist >/dev/null 2>&1; then fail "2e: preview of an unknown theme did not fail"; fi
pass; echo "PASS (2c) preview of an unknown theme is refused (non-zero)"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 3. set — validated write of HERD_THEME; theme.sh then resolves it; unknown theme refused + no write.
# ════════════════════════════════════════════════════════════════════════════════════════════════
run theme set gruvbox >/dev/null 2>&1 || fail "3a: 'herd theme set gruvbox' failed"
grep -qE '^[[:space:]]*HERD_THEME="?gruvbox"?[[:space:]]*$' "$PROJ/.herd/config" \
  || fail "3b: 'herd theme set' did not write HERD_THEME=gruvbox into .herd/config ($(grep HERD_THEME "$PROJ/.herd/config"))"
# The write is exactly what theme.sh resolves for that theme (end-to-end pickup).
got="$(HERD_THEME=gruvbox PROJECT_ROOT="$T/empty" bash -c '. "$1"; herd_theme_glow_style' _ "$THEME_SH")"
[ "$got" = "$BUILTINS/gruvbox/glow.json" ] || fail "3c: theme.sh did not resolve the set theme's glow.json: '$got'"
# set is idempotent (config set edits in place) — HERD_THEME stays assigned exactly once.
run theme set catppuccin >/dev/null 2>&1 || fail "3d: second 'herd theme set' failed"
[ "$(grep -cE '^[[:space:]]*HERD_THEME=' "$PROJ/.herd/config")" -eq 1 ] \
  || fail "3e: 'herd theme set' duplicated the HERD_THEME key"
pass; echo "PASS (3a) set writes HERD_THEME via the validated path; theme.sh picks it up; no dup key"

# Unknown / incomplete theme is refused, and the config value is left untouched.
before="$(grep HERD_THEME "$PROJ/.herd/config")"
if run theme set no-such-theme >/dev/null 2>&1; then fail "3f: 'herd theme set' of an unknown theme did not fail"; fi
[ "$(grep HERD_THEME "$PROJ/.herd/config")" = "$before" ] || fail "3g: a refused 'set' still mutated .herd/config"
mkdir -p "$PROJ/.herd/themes/half"; printf 'C_GREEN=""\n' > "$PROJ/.herd/themes/half/palette.sh"   # no glow.json
if run theme set half >/dev/null 2>&1; then fail "3h: 'herd theme set' of an INCOMPLETE theme did not fail"; fi
rm -rf "$PROJ/.herd/themes"
pass; echo "PASS (3b) set refuses an unknown/incomplete theme and leaves the config untouched"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 4. NO_COLOR — preview emits NO ANSI escape sequences (plain swatches).
# ════════════════════════════════════════════════════════════════════════════════════════════════
nc="$( cd "$PROJ" && NO_COLOR=1 bash "$HERD" theme preview nord 2>&1 )"
printf '%s' "$nc" | grep -q $'\033' && fail "4a: preview emitted an ANSI escape under NO_COLOR"
printf '%s' "$nc" | grep -q '██████' || fail "4b: preview lost its swatch blocks under NO_COLOR"
pass; echo "PASS (4a) preview renders plain (no ANSI escapes) under NO_COLOR"

echo
echo "ALL PASS ($PASS checks) — herd theme <list|preview|set> picker + the shipped built-in packs."
