#!/usr/bin/env bash
# scripts/herd/sim/posture-lib.sh — shared reader for the CANONICAL CONFIG POSTURES (HERD-153).
#
# Sourced by the posture-aware sandbox scenarios and the posture-matrix wrapper. It parses the
# authoritative posture table (templates/postures.tsv) — the SINGLE source of truth for the named
# config bundles — and exposes small, dependency-free helpers so a caller can look up a posture's
# KEY=VALUE bundle, its intent, or apply the bundle to the environment. No jq/python, no network.
#
# The table path defaults to templates/postures.tsv resolved from this file's location (…/scripts/herd/
# sim/ → repo root → templates/postures.tsv); override with POSTURES_FILE for a fixture table.
#
# API (all read-only except posture_apply):
#   posture_file                 → echo the resolved postures.tsv path
#   posture_names                → echo every posture name, one per line (file order)
#   posture_exists <name>        → return 0 iff <name> is a defined posture
#   posture_keys <name>          → echo the SPACE-separated KEY=VALUE bundle for <name>
#   posture_intent <name>        → echo the one-line intent for <name>
#   posture_apply <name>         → export every real KEY=VALUE in the bundle (STEPS_PROFILE=… is NOT a
#                                  config key, so it is skipped here — a caller reads it via
#                                  posture_steps_profile and materialises the fixture itself)
#   posture_steps_profile <name> → echo the STEPS_PROFILE=<id> value in the bundle, or empty
#
# Bash 3.2 clean (no associative arrays). Blank/'#'-prefixed rows and the header row are skipped.

# Resolve the postures table once. POSTURES_FILE wins; else derive from this script's location.
_posture_lib_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
posture_file() {
  if [ -n "${POSTURES_FILE:-}" ]; then printf '%s' "$POSTURES_FILE"; return 0; fi
  printf '%s' "$_posture_lib_here/../../../templates/postures.tsv"
}

# _posture_row <name> — echo the raw TAB-separated data row for <name> (name<TAB>keys<TAB>intent), or
# nothing (return 1) when the name is not found. Skips comments, blanks, and the 'name<TAB>…' header.
_posture_row() {
  local want="$1" f; f="$(posture_file)"
  [ -f "$f" ] || return 1
  # IFS=tab; read three fields. A leading '#' or the literal header 'name' in col 1 is skipped.
  while IFS=$'\t' read -r nm keys intent; do
    case "$nm" in ''|'#'*|name) continue ;; esac
    if [ "$nm" = "$want" ]; then printf '%s\t%s\t%s' "$nm" "$keys" "$intent"; return 0; fi
  done < "$f"
  return 1
}

posture_names() {
  local f; f="$(posture_file)"
  [ -f "$f" ] || return 0
  while IFS=$'\t' read -r nm _rest; do
    case "$nm" in ''|'#'*|name) continue ;; esac
    printf '%s\n' "$nm"
  done < "$f"
}

posture_exists() { _posture_row "$1" >/dev/null 2>&1; }

posture_keys() {
  local row; row="$(_posture_row "$1")" || return 1
  printf '%s' "$row" | cut -f2
}

posture_intent() {
  local row; row="$(_posture_row "$1")" || return 1
  printf '%s' "$row" | cut -f3
}

posture_steps_profile() {
  local kv
  for kv in $(posture_keys "$1" 2>/dev/null); do
    case "$kv" in STEPS_PROFILE=*) printf '%s' "${kv#STEPS_PROFILE=}"; return 0 ;; esac
  done
  return 0
}

# posture_apply <name> — export the posture's REAL config keys. STEPS_PROFILE=<id> is a sim/installer
# directive, not a .herd/config key, so it is NOT exported (a caller reads it via posture_steps_profile).
posture_apply() {
  local kv
  for kv in $(posture_keys "$1" 2>/dev/null); do
    case "$kv" in
      STEPS_PROFILE=*) : ;;                 # not a config key — skip
      *=*) export "$kv" ;;
    esac
  done
}
