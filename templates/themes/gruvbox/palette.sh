# palette.sh — Gruvbox (dark) palette, a herdkit built-in theme.
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
C_BLUE=$'\033[38;2;131;165;152m'   # gruvbox blue   #83a598
C_CYAN=$'\033[38;2;142;192;124m'   # gruvbox aqua   #8ec07c
C_GREEN=$'\033[38;2;184;187;38m'   # gruvbox green  #b8bb26
C_YELLOW=$'\033[38;2;250;189;47m'  # gruvbox yellow #fabd2f
C_RED=$'\033[38;2;251;73;52m'      # gruvbox red    #fb4934
C_DIM=$'\033[38;2;146;131;116m'    # gruvbox gray   #928374

# ── CLI 16-color palette (bin/herd / status / fleet — portable, basic-terminal safe) ─
C_CLI_BOLD=$'\033[1m'
C_CLI_DIM=$'\033[2m'
C_CLI_GREEN=$'\033[33m'
C_CLI_YELLOW=$'\033[93m'
C_CLI_RED=$'\033[91m'
C_CLI_RESET=$'\033[0m'
