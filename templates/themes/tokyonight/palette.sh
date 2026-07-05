# palette.sh — Tokyo Night palette (herdkit's built-in DEFAULT theme).
#
# A theme's palette.sh is SOURCED (never executed) by the herd color surfaces. It defines two
# variable groups:
#   • C_*      — the truecolor console palette used by the status consoles (agent-watch.sh). These
#                paint a live pane (not markdown), so they are 24-bit truecolor SGR sequences.
#   • C_CLI_*  — an OPTIONAL 16-color palette used by the plain CLI surfaces (bin/herd status / fleet
#                / cost / why, herd-approve.sh). 16-color keeps the CLI readable on basic terminals.
#                A theme may omit these; the loader (theme.sh) then falls back to the C_* truecolor
#                values, so a custom theme still recolors the CLI without duplicating every value.
#
# These values are byte-identical to the palettes herdkit hardcoded before HERD_THEME existed — the
# theme test (tests/test-theme.sh) asserts the match, so the default rendering never changed. To make
# your own theme, copy this file into .herd/themes/<name>/palette.sh and edit the values.

# ── console truecolor palette (status consoles — a pane, not markdown) ─────────
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_BLUE=$'\033[38;2;122;162;247m'
C_CYAN=$'\033[38;2;125;207;255m'
C_GREEN=$'\033[38;2;158;206;106m'
C_YELLOW=$'\033[38;2;224;175;104m'
C_RED=$'\033[38;2;247;118;142m'
C_DIM=$'\033[38;2;86;95;137m'

# ── CLI 16-color palette (bin/herd / status / fleet — portable, basic-terminal safe) ─
C_CLI_BOLD=$'\033[1m'
C_CLI_DIM=$'\033[2m'
C_CLI_GREEN=$'\033[32m'
C_CLI_YELLOW=$'\033[33m'
C_CLI_RED=$'\033[31m'
C_CLI_RESET=$'\033[0m'
