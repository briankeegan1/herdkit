# palette.sh — Nord palette, a herdkit built-in theme.
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
C_BLUE=$'\033[38;2;129;161;193m'   # nord9  frost blue  #81a1c1
C_CYAN=$'\033[38;2;136;192;208m'   # nord8  frost cyan  #88c0d0
C_GREEN=$'\033[38;2;163;190;140m'  # nord14 green       #a3be8c
C_YELLOW=$'\033[38;2;235;203;139m' # nord13 yellow      #ebcb8b
C_RED=$'\033[38;2;191;97;106m'     # nord11 red         #bf616a
C_DIM=$'\033[38;2;76;86;106m'      # nord3  polar night #4c566a

# ── CLI 16-color palette (bin/herd / status / fleet — portable, basic-terminal safe) ─
C_CLI_BOLD=$'\033[1m'
C_CLI_DIM=$'\033[2m'
C_CLI_GREEN=$'\033[36m'
C_CLI_YELLOW=$'\033[33m'
C_CLI_RED=$'\033[31m'
C_CLI_RESET=$'\033[0m'
