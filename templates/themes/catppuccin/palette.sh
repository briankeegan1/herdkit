# palette.sh — Catppuccin (Mocha) palette, a herdkit built-in theme.
#
# A theme's palette.sh is SOURCED (never executed) by the herd color surfaces. It defines two
# variable groups (see templates/themes/tokyonight/palette.sh for the full contract):
#   • C_*      — the truecolor console palette used by the status consoles (agent-watch.sh).
#   • C_CLI_*  — the OPTIONAL 16-color palette used by the plain CLI surfaces (bin/herd status /
#                fleet / cost / why, herd-approve.sh); portable on basic terminals.
#
# To make your own theme, copy this file into .herd/themes/<name>/palette.sh and edit the values.

# ── console truecolor palette (status consoles — a pane, not markdown) ─────────
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_BLUE=$'\033[38;2;137;180;250m'   # mocha blue   #89b4fa
C_CYAN=$'\033[38;2;137;220;235m'   # mocha sky    #89dceb
C_GREEN=$'\033[38;2;166;227;161m'  # mocha green  #a6e3a1
C_YELLOW=$'\033[38;2;249;226;175m' # mocha yellow #f9e2af
C_RED=$'\033[38;2;243;139;168m'    # mocha red    #f38ba8
C_DIM=$'\033[38;2;108;112;134m'    # mocha overlay0 #6c7086

# ── CLI 16-color palette (bin/herd / status / fleet — portable, basic-terminal safe) ─
C_CLI_BOLD=$'\033[1m'
C_CLI_DIM=$'\033[2m'
C_CLI_GREEN=$'\033[92m'
C_CLI_YELLOW=$'\033[93m'
C_CLI_RED=$'\033[91m'
C_CLI_RESET=$'\033[0m'
