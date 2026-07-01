#!/usr/bin/env bash
# install.sh — symlink bin/herd into a writable PATH directory.
#
# Usage:
#   bash install.sh              # auto-detect: first writable directory in $PATH
#   bash install.sh --dir <dir>  # symlink into a specific directory
#
# If no writable PATH directory is found, prints a fallback export for your shell profile.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERD_BIN="$HERE/bin/herd"

c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
ok()   { printf '%s✅ %s%s\n' "$c_grn" "$*" "$c_rst"; }
warn() { printf '%s⚠️  %s%s\n' "$c_yel" "$*" "$c_rst" >&2; }

TARGET_DIR=""
if [ "${1:-}" = "--dir" ]; then
  TARGET_DIR="${2:?--dir requires a directory argument}"
fi

if [ -z "$TARGET_DIR" ]; then
  # Walk PATH entries; pick the first directory that exists and is writable.
  IFS=: read -ra _path_dirs <<< "$PATH"
  for d in "${_path_dirs[@]}"; do
    if [ -d "$d" ] && [ -w "$d" ]; then
      TARGET_DIR="$d"
      break
    fi
  done
fi

if [ -z "$TARGET_DIR" ]; then
  warn "No writable directory found in PATH."
  printf 'Add herdkit/bin to your PATH instead — append to your shell profile:\n'
  printf '  export PATH="%s/bin:$PATH"\n' "$HERE"
  exit 1
fi

ln -sf "$HERD_BIN" "$TARGET_DIR/herd"
ok "Installed: $TARGET_DIR/herd -> $HERD_BIN"
printf 'Run: herd help\n'
