#!/usr/bin/env bash
# scripts/herd/sim/archetype-lib.sh — shared reader for the CANONICAL PROJECT ARCHETYPES (HERD-409).
#
# Sourced by `herd init` (bin/herd). Parses the authoritative archetype table
# (templates/archetypes.tsv) — the SINGLE source of truth for the project-kind axis — and exposes
# small, dependency-free helpers so a caller can look up an archetype's seeded healthcheck template
# or its intent. No jq/python, no network. Modeled directly on scripts/herd/sim/posture-lib.sh.
#
# The table path defaults to templates/archetypes.tsv resolved from this file's location (…/scripts/
# herd/sim/ → repo root → templates/archetypes.tsv); override with ARCHETYPES_FILE for a fixture table.
#
# API (all read-only):
#   archetype_file                        → echo the resolved archetypes.tsv path
#   archetype_names                       → echo every archetype name, one per line (file order)
#   archetype_exists <name>                → return 0 iff <name> is a defined archetype
#   archetype_healthcheck_template <name>  → echo the healthcheck_template column ("auto" or a
#                                            templates/healthcheck.*.sh basename)
#   archetype_intent <name>                → echo the one-line intent for <name>
#
# Bash 3.2 clean (no associative arrays). Blank/'#'-prefixed rows and the header row are skipped.

# Resolve the archetypes table once. ARCHETYPES_FILE wins; else derive from this script's location.
_archetype_lib_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
archetype_file() {
  if [ -n "${ARCHETYPES_FILE:-}" ]; then printf '%s' "$ARCHETYPES_FILE"; return 0; fi
  printf '%s' "$_archetype_lib_here/../../../templates/archetypes.tsv"
}

# _archetype_row <name> — echo the raw TAB-separated data row for <name>
# (name<TAB>healthcheck_template<TAB>intent), or nothing (return 1) when not found. Skips comments,
# blanks, and the 'name<TAB>…' header.
_archetype_row() {
  local want="$1" f; f="$(archetype_file)"
  [ -f "$f" ] || return 1
  while IFS=$'\t' read -r nm tmpl intent; do
    case "$nm" in ''|'#'*|name) continue ;; esac
    if [ "$nm" = "$want" ]; then printf '%s\t%s\t%s' "$nm" "$tmpl" "$intent"; return 0; fi
  done < "$f"
  return 1
}

archetype_names() {
  local f; f="$(archetype_file)"
  [ -f "$f" ] || return 0
  while IFS=$'\t' read -r nm _rest; do
    case "$nm" in ''|'#'*|name) continue ;; esac
    printf '%s\n' "$nm"
  done < "$f"
}

archetype_exists() { _archetype_row "$1" >/dev/null 2>&1; }

archetype_healthcheck_template() {
  local row; row="$(_archetype_row "$1")" || return 1
  printf '%s' "$row" | cut -f2
}

archetype_intent() {
  local row; row="$(_archetype_row "$1")" || return 1
  printf '%s' "$row" | cut -f3
}
