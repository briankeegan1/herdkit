#!/usr/bin/env bash
# theme.sh — pluggable theming (HERD_THEME) for every herd color surface.
#
# A THEME is a DIRECTORY holding two files:
#   palette.sh — the console C_* truecolor variable definitions (sourced by the status consoles),
#                plus the optional C_CLI_* 16-color CLI overrides (bin/herd / status / fleet).
#   glow.json  — the glamour style handed to `glow -s` by the markdown viewers.
#
# Resolution order for the active theme ($HERD_THEME, default tokyonight), evaluated PER FILE so a
# theme that supplies only one of the two files still works:
#   1. $PROJECT_ROOT/.herd/themes/<name>/<file>     — user-defined, project-local (never committed
#                                                     is fine; it is read at render time, not tracked)
#   2. <engine>/templates/themes/<name>/<file>      — engine built-ins
#   3. <engine>/templates/themes/tokyonight/<file>  — the shipped fallback (ALWAYS present)
#
# FAIL SOFT (never break a console): an unknown or broken theme (its dir missing, or missing one of
# the two files) warns LOUDLY once to stderr and falls back to the built-in tokyonight — resolution
# never errors and a missing file resolves to the tokyonight default. NO_COLOR set, or a non-TTY
# stdout, renders plain (the C_*/c_* vars are blanked).
#
# Source this AFTER herd-config.sh where possible (so HERD_THEME + PROJECT_ROOT are resolved); it
# also works standalone, reading HERD_THEME/PROJECT_ROOT from the environment. All resolution is
# LAZY (inside the functions), so a caller may set/override HERD_THEME after sourcing.

_HERD_THEME_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HERD_THEME_BUILTINS="$(cd "$_HERD_THEME_SELF/../.." && pwd)/templates/themes"

# _herd_theme_name — the active theme, sanitized to a safe slug so a hostile/typo'd HERD_THEME can
# never traverse out of the themes dirs (e.g. "../../etc"). Empty/invalid → tokyonight.
_herd_theme_name() {
  local n="${HERD_THEME:-tokyonight}"
  case "$n" in
    ''|*[!A-Za-z0-9._-]*|.|..|*/*) printf 'tokyonight' ;;
    *)                             printf '%s' "$n" ;;
  esac
}

# _herd_theme_dir_ok <dir> — true when <dir> is a COMPLETE theme (both files present).
_herd_theme_dir_ok() {
  local d="${1:-}"
  [ -n "$d" ] && [ -f "$d/palette.sh" ] && [ -f "$d/glow.json" ]
}

# _herd_theme_warn — warn LOUDLY, at most once per process, when the requested (non-tokyonight)
# theme cannot be resolved to a complete dir from either the user or the built-in location, so the
# operator learns their theme silently fell back instead of quietly getting the default.
_herd_theme_warn() {
  case "${_HERD_THEME_WARNED:-}" in ''|0) ;; *) return 0 ;; esac
  local name; name="$(_herd_theme_name)"
  [ "$name" = "tokyonight" ] && return 0
  local udir="" bdir="$_HERD_THEME_BUILTINS/$name"
  [ -n "${PROJECT_ROOT:-}" ] && udir="$PROJECT_ROOT/.herd/themes/$name"
  _herd_theme_dir_ok "$udir" && return 0
  _herd_theme_dir_ok "$bdir" && return 0
  export _HERD_THEME_WARNED=1
  printf '⚠️  herdkit: theme "%s" not found or incomplete — falling back to the built-in tokyonight theme.\n' "$name" >&2
  printf '   looked in: %s and %s (each needs palette.sh + glow.json)\n' \
    "${udir:-<no PROJECT_ROOT — user themes skipped>}" "$bdir" >&2
  return 0
}

# _herd_theme_resolve <file> — echo the absolute path to <file> for the active theme, honoring the
# search order with a per-file tokyonight fallback. Always prints an existing path (the built-in
# tokyonight file is guaranteed to exist); prints nothing only if even that is somehow missing.
_herd_theme_resolve() {
  local file="${1:?_herd_theme_resolve: file required}"
  _herd_theme_warn
  local name; name="$(_herd_theme_name)"
  local c
  if [ -n "${PROJECT_ROOT:-}" ]; then
    c="$PROJECT_ROOT/.herd/themes/$name/$file"; [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  fi
  c="$_HERD_THEME_BUILTINS/$name/$file";        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  c="$_HERD_THEME_BUILTINS/tokyonight/$file";   [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  return 0
}

# _herd_theme_no_color — true when color must be suppressed: NO_COLOR set (any value, per the
# no-color.org convention) OR stdout is not a terminal. Then every surface renders plain.
_herd_theme_no_color() {
  [ -n "${NO_COLOR:-}" ] && return 0
  [ -t 1 ] || return 0
  return 1
}

# _herd_theme_source_palettes — source the tokyonight built-in palette FIRST (sane defaults for
# every variable), then overlay the active theme's palette.sh (which may set all, some, or none of
# them). This makes a partial custom palette.sh safe: any variable it omits keeps the tokyonight
# default rather than becoming empty. For the default theme both sources are the same file.
_herd_theme_source_palettes() {
  local base pfile
  base="$_HERD_THEME_BUILTINS/tokyonight/palette.sh"
  pfile="$(_herd_theme_resolve palette.sh)"
  # shellcheck source=/dev/null
  [ -f "$base" ] && . "$base"
  # shellcheck source=/dev/null
  [ -n "$pfile" ] && [ "$pfile" != "$base" ] && . "$pfile"
  return 0   # never let the trailing && chain (false for the default theme) fail a `set -e` caller
}

# herd_theme_glow_style — echo the path to the active theme's glow.json (for `glow -s "$STYLE"`).
herd_theme_glow_style() { _herd_theme_resolve glow.json; }

# herd_theme_load_console — set the console truecolor palette (C_RESET C_BOLD C_BLUE C_CYAN C_GREEN
# C_YELLOW C_RED C_DIM) from the active theme. Blanked to "" under NO_COLOR / non-TTY (plain output).
herd_theme_load_console() {
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
  _herd_theme_source_palettes
  if _herd_theme_no_color; then
    C_RESET=""; C_BOLD=""; C_BLUE=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
  fi
  return 0
}

# herd_theme_load_cli — set the plain-CLI palette (c_bold c_dim c_grn c_yel c_red c_rst) used by
# bin/herd + status.sh + fleet.sh. Prefers the theme's C_CLI_* 16-color values, falling back to its
# C_* truecolor values so a theme that defines only C_* still recolors the CLI. Blanked under
# NO_COLOR / non-TTY.
herd_theme_load_cli() {
  _herd_theme_source_palettes
  c_bold="${C_CLI_BOLD:-${C_BOLD:-}}"
  c_dim="${C_CLI_DIM:-${C_DIM:-}}"
  c_grn="${C_CLI_GREEN:-${C_GREEN:-}}"
  c_yel="${C_CLI_YELLOW:-${C_YELLOW:-}}"
  c_red="${C_CLI_RED:-${C_RED:-}}"
  c_rst="${C_CLI_RESET:-${C_RESET:-}}"
  if _herd_theme_no_color; then
    c_bold=""; c_dim=""; c_grn=""; c_yel=""; c_red=""; c_rst=""
    # _herd_theme_source_palettes also (re)populated the console C_* as a side effect; blank them too
    # so that under no-color EVERY palette var is plain regardless of which loader ran, or in what order.
    C_RESET=""; C_BOLD=""; C_BLUE=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
  fi
  return 0
}
