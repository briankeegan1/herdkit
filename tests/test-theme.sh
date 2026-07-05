#!/usr/bin/env bash
# test-theme.sh — hermetic tests for HERD_THEME pluggable theming (scripts/herd/theme.sh + the
# built-in tokyonight theme under templates/themes/). Fully offline: sources theme.sh and reads
# files, no herdr/gh/network/model.
#
# Coverage:
#   1. BYTE-IDENTICAL EXTRACTION — the shipped tokyonight theme reproduces the pre-theme hardcoded
#      palettes EXACTLY: glow.json matches the historical bundled scripts/herd/tokyonight.json, and
#      palette.sh's C_* truecolor + C_CLI_* 16-color values match the historical console / CLI blocks.
#   2. RESOLUTION ORDER — .herd/themes/<name>/ (user) beats templates/themes/<name>/ (built-in), which
#      beats the tokyonight fallback; evaluated per file.
#   3. FAIL SOFT — an unknown or broken (incomplete) theme warns LOUDLY ONCE to stderr and falls back
#      to the tokyonight built-in per file; a hostile HERD_THEME can never traverse out of the dirs.
#   4. PALETTE LOAD + NO-COLOR — the palette sources into the right variables; NO_COLOR or a non-TTY
#      stdout blanks every color var (plain output).
#
# Run:  bash tests/test-theme.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
THEME_SH="$ROOT/scripts/herd/theme.sh"
BUILTIN="$ROOT/templates/themes/tokyonight"
LEGACY="$ROOT/scripts/herd/tokyonight.json"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "$THEME_SH" "$BUILTIN/palette.sh" "$BUILTIN/glow.json" "$LEGACY"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 1. BYTE-IDENTICAL EXTRACTION — the tokyonight built-in reproduces today's values exactly
# ════════════════════════════════════════════════════════════════════════════════════════════════
# glow.json is byte-for-byte the historical bundled style (so glow-rendered surfaces are unchanged).
diff "$BUILTIN/glow.json" "$LEGACY" >/dev/null 2>&1 \
  || fail "(1) templates/themes/tokyonight/glow.json is NOT byte-identical to scripts/herd/tokyonight.json"
pass; echo "PASS (1a) tokyonight glow.json is byte-identical to the historical bundled style"

# palette.sh sources cleanly and defines EXACTLY the historical console + CLI escape values.
check_palette() {
  # shellcheck source=/dev/null
  . "$BUILTIN/palette.sh"
  local ok=1
  [ "$C_RESET"  = $'\033[0m' ]                 || { echo "C_RESET mismatch"  >&2; ok=0; }
  [ "$C_BOLD"   = $'\033[1m' ]                 || { echo "C_BOLD mismatch"   >&2; ok=0; }
  [ "$C_BLUE"   = $'\033[38;2;122;162;247m' ]  || { echo "C_BLUE mismatch"   >&2; ok=0; }
  [ "$C_CYAN"   = $'\033[38;2;125;207;255m' ]  || { echo "C_CYAN mismatch"   >&2; ok=0; }
  [ "$C_GREEN"  = $'\033[38;2;158;206;106m' ]  || { echo "C_GREEN mismatch"  >&2; ok=0; }
  [ "$C_YELLOW" = $'\033[38;2;224;175;104m' ]  || { echo "C_YELLOW mismatch" >&2; ok=0; }
  [ "$C_RED"    = $'\033[38;2;247;118;142m' ]  || { echo "C_RED mismatch"    >&2; ok=0; }
  [ "$C_DIM"    = $'\033[38;2;86;95;137m' ]    || { echo "C_DIM mismatch"    >&2; ok=0; }
  [ "$C_CLI_BOLD"   = $'\033[1m' ]  || { echo "C_CLI_BOLD mismatch"   >&2; ok=0; }
  [ "$C_CLI_DIM"    = $'\033[2m' ]  || { echo "C_CLI_DIM mismatch"    >&2; ok=0; }
  [ "$C_CLI_GREEN"  = $'\033[32m' ] || { echo "C_CLI_GREEN mismatch"  >&2; ok=0; }
  [ "$C_CLI_YELLOW" = $'\033[33m' ] || { echo "C_CLI_YELLOW mismatch" >&2; ok=0; }
  [ "$C_CLI_RED"    = $'\033[31m' ] || { echo "C_CLI_RED mismatch"    >&2; ok=0; }
  [ "$C_CLI_RESET"  = $'\033[0m' ]  || { echo "C_CLI_RESET mismatch"  >&2; ok=0; }
  [ "$ok" = 1 ]
}
( check_palette ) || fail "(1) tokyonight palette.sh values are NOT byte-identical to the historical console/CLI palettes"
pass; echo "PASS (1b) tokyonight palette.sh C_* + C_CLI_* match the historical hardcoded values"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 2. RESOLUTION ORDER — user theme > built-in theme > tokyonight fallback (per file)
# ════════════════════════════════════════════════════════════════════════════════════════════════
# A project with a user theme "mytheme" and a user OVERRIDE of the built-in "tokyonight" name.
P="$T/proj"; mkdir -p "$P/.herd/themes/mytheme" "$P/.herd/themes/tokyonight"
printf 'C_GREEN=$'"'"'\\033[38;2;1;2;3m'"'"'\n'         > "$P/.herd/themes/mytheme/palette.sh"
printf '{"document":{}}\n'                              > "$P/.herd/themes/mytheme/glow.json"
printf '{"document":{"user-tokyonight":true}}\n'        > "$P/.herd/themes/tokyonight/glow.json"

# shellcheck source=/dev/null
. "$THEME_SH"

# user "mytheme" glow.json resolves to the project-local file.
got="$(HERD_THEME=mytheme PROJECT_ROOT="$P" herd_theme_glow_style)"
[ "$got" = "$P/.herd/themes/mytheme/glow.json" ] \
  || fail "(2) user theme glow.json did not win: got '$got'"
pass; echo "PASS (2a) .herd/themes/<name>/ (user) resolves first"

# HERD_THEME=tokyonight WITH a user override present → the USER tokyonight file wins over the built-in.
got="$(HERD_THEME=tokyonight PROJECT_ROOT="$P" herd_theme_glow_style)"
[ "$got" = "$P/.herd/themes/tokyonight/glow.json" ] \
  || fail "(2) user override of the built-in tokyonight name did not win: got '$got'"
pass; echo "PASS (2b) a user theme overrides the engine built-in of the same name"

# No user dir → the engine built-in tokyonight resolves.
got="$(HERD_THEME=tokyonight PROJECT_ROOT="$T/empty" herd_theme_glow_style)"
[ "$got" = "$BUILTIN/glow.json" ] \
  || fail "(2) built-in tokyonight did not resolve when no user theme: got '$got'"
pass; echo "PASS (2c) templates/themes/<name>/ (built-in) resolves when no user theme"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 3. FAIL SOFT — unknown / broken / hostile themes never break; warn once; fall back to tokyonight
# ════════════════════════════════════════════════════════════════════════════════════════════════
# Unknown theme → glow.json falls back to the tokyonight built-in, and a LOUD warning fires ONCE.
(
  export HERD_THEME=does-not-exist PROJECT_ROOT="$T/empty" _HERD_THEME_WARNED=""
  # First resolve runs in THIS shell (not a $()-subshell), so its once-per-process guard persists.
  herd_theme_glow_style >/dev/null 2>"$T/warn.err"     # warns, sets _HERD_THEME_WARNED=1
  g1="$(herd_theme_glow_style 2>>"$T/warn.err")"       # $() inherits the guard → no second warn
  herd_theme_glow_style >/dev/null 2>>"$T/warn.err"    # guard set → no warn
  [ "$g1" = "$BUILTIN/glow.json" ] || { echo "unknown theme did not fall back to tokyonight: '$g1'" >&2; exit 1; }
  n="$(grep -c 'not found or incomplete' "$T/warn.err" || true)"
  [ "$n" = "1" ] || { echo "expected exactly ONE fallback warning, got $n" >&2; cat "$T/warn.err" >&2; exit 1; }
) || fail "(3) unknown theme fail-soft/warn-once contract violated"
pass; echo "PASS (3a) unknown theme → tokyonight fallback + exactly one loud warning"

# Broken theme: a dir with palette.sh but NO glow.json → glow.json falls back per file; still warns.
mkdir -p "$P/.herd/themes/broken"
printf 'C_GREEN=""\n' > "$P/.herd/themes/broken/palette.sh"   # no glow.json → incomplete
(
  export HERD_THEME=broken PROJECT_ROOT="$P" _HERD_THEME_WARNED=""
  g="$(herd_theme_glow_style 2>"$T/broken.err")"
  p="$(_herd_theme_resolve palette.sh 2>/dev/null)"
  [ "$g" = "$BUILTIN/glow.json" ] || { echo "broken theme glow.json did not fall back: '$g'" >&2; exit 1; }
  [ "$p" = "$P/.herd/themes/broken/palette.sh" ] || { echo "broken theme palette.sh not used per-file: '$p'" >&2; exit 1; }
  grep -q 'not found or incomplete' "$T/broken.err" || { echo "broken theme did not warn" >&2; exit 1; }
) || fail "(3) broken/incomplete theme fail-soft (per-file fallback + warn) violated"
pass; echo "PASS (3b) broken theme → per-file fallback (glow.json→tokyonight, palette.sh kept) + warn"

# Hostile HERD_THEME (path traversal) is sanitized to tokyonight — never escapes the theme dirs.
got="$(HERD_THEME='../../../etc' PROJECT_ROOT="$T/empty" herd_theme_glow_style 2>/dev/null)"
[ "$got" = "$BUILTIN/glow.json" ] \
  || fail "(3) hostile HERD_THEME was not sanitized to the tokyonight built-in: got '$got'"
pass; echo "PASS (3c) a path-traversal HERD_THEME is sanitized to the tokyonight fallback"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 4. PALETTE LOAD + NO-COLOR / non-TTY plain
# ════════════════════════════════════════════════════════════════════════════════════════════════
# The palette sources into the console C_* set (theme override wins for the vars it defines).
(
  export HERD_THEME=mytheme PROJECT_ROOT="$P"
  _herd_theme_source_palettes
  # mytheme sets only C_GREEN; every other var keeps the tokyonight base default (partial-theme safety).
  [ "$C_GREEN" = $'\033[38;2;1;2;3m' ] || { echo "theme override C_GREEN not applied: '$C_GREEN'" >&2; exit 1; }
  [ "$C_RED"   = $'\033[38;2;247;118;142m' ] || { echo "base C_RED default not kept for a partial theme: '$C_RED'" >&2; exit 1; }
) || fail "(4) palette sourcing/override/partial-fallback violated"
pass; echo "PASS (4a) palette sources into C_*; a partial theme keeps tokyonight defaults for the rest"

# A non-TTY stdout → load_console/load_cli render PLAIN (all color vars empty). Force a non-tty fd 1
# (>/dev/null) so the check is deterministic whether or not the test's own stdout is a terminal.
(
  export HERD_THEME=tokyonight PROJECT_ROOT="$T/empty"
  herd_theme_load_console
  herd_theme_load_cli
  [ -z "$C_GREEN" ] && [ -z "$C_RED" ] && [ -z "$C_BOLD" ] || { echo "console palette not blanked on non-TTY" >&2; exit 1; }
  [ -z "$c_grn" ] && [ -z "$c_red" ] && [ -z "$c_rst" ]     || { echo "CLI palette not blanked on non-TTY" >&2; exit 1; }
) >/dev/null || fail "(4) non-TTY stdout did not render plain"
pass; echo "PASS (4b) a non-TTY stdout blanks both palettes (plain output)"

# NO_COLOR forces plain even were stdout a tty (assert the loader honors it explicitly).
(
  export HERD_THEME=tokyonight PROJECT_ROOT="$T/empty" NO_COLOR=1
  _herd_theme_no_color || { echo "_herd_theme_no_color false under NO_COLOR" >&2; exit 1; }
  herd_theme_load_cli
  [ -z "$c_grn" ] && [ -z "$c_bold" ] || { echo "CLI palette not blanked under NO_COLOR" >&2; exit 1; }
) || fail "(4) NO_COLOR was not honored"
pass; echo "PASS (4c) NO_COLOR forces plain output"

echo
echo "ALL PASS ($PASS checks) — HERD_THEME pluggable theming (resolver + tokyonight built-in)."
