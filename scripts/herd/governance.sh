#!/usr/bin/env bash
# governance.sh — the SHARED, read-only governance EXTRACTION + MAPPING helpers (HERD-119 / HERD-125).
#
# The `herd init` adoption pass (HERD-119, bin/herd) and the advisory drift sweep (HERD-125,
# governance-drift-sweep.sh) both need the SAME pipeline: read an OPTIONAL CLAUDE.md / AGENTS.md,
# split its prose into candidate statements, and map each — deterministically, via
# templates/governance-map.tsv — to a herd enforcement surface. Housing that pipeline here means the
# sweep re-extracts a change EXACTLY as init imported it (same statements, same first-match-wins
# table), so a rule init would have adopted is the same rule the sweep later flags as drifted. Sourced
# (never executed) AFTER herd-config.sh where the consumer needs config, or standalone where it does
# not — it defines functions only, with zero side effects at source time.
#
# The functions here are PURE + FAIL-SOFT + LLM-FREE: a missing/unreadable source contributes nothing,
# an unmatched statement is not an error, and the deterministic table is the only classifier. The
# init-only pieces that MUTATE state (apply-config / append-checklist / the interactive proposal loop)
# and the optional, default-off LLM fallback stay in bin/herd — this module is the part two surfaces
# share.

# The default pattern table, resolved from THIS file's location (scripts/herd → ../../templates), so
# the module is self-sufficient when a consumer has not defined TEMPLATES_DIR. Computed once at source
# time; _gov_map_file prefers the HERD_GOVERNANCE_MAP test seam, then a caller-set TEMPLATES_DIR, then
# this — which keeps bin/herd's behavior (TEMPLATES_DIR is always set there) byte-identical.
_GOV_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GOV_DEFAULT_MAP="$_GOV_SH_DIR/../../templates/governance-map.tsv"

# _gov_map_file — the deterministic pattern table (test seam: HERD_GOVERNANCE_MAP; then TEMPLATES_DIR
# for the bin/herd consumer; then the module-relative default).
_gov_map_file() {
  if [ -n "${HERD_GOVERNANCE_MAP:-}" ]; then printf '%s' "$HERD_GOVERNANCE_MAP"; return 0; fi
  if [ -n "${TEMPLATES_DIR:-}" ]; then printf '%s' "$TEMPLATES_DIR/governance-map.tsv"; return 0; fi
  printf '%s' "$_GOV_DEFAULT_MAP"
}

# _gov_statements <file...> — emit candidate governance statements, one per line, from the given
# markdown sources. Deterministic + fail-soft: strips fenced code, headings and bullet/number markers,
# splits prose on sentence boundaries, trims, and drops trivially short fragments. A missing/unreadable
# file contributes nothing.
_gov_statements() {
  local f
  for f in "$@"; do
    { [ -f "$f" ] && [ -r "$f" ]; } || continue
    awk '
      /^[[:space:]]*```/ { infence = !infence; next }
      infence { next }
      {
        line = $0
        sub(/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/, "", line)   # drop a leading bullet/number
      }
      line ~ /^[[:space:]]*#/ { next }                                 # skip headings
      {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      }
      line == "" { next }
      {
        n = split(line, parts, /\.[[:space:]]+/)                       # split prose into sentences
        for (i = 1; i <= n; i++) {
          s = parts[i]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
          sub(/[.;:]+$/, "", s)
          if (length(s) >= 10) print s
        }
      }
    ' "$f" 2>/dev/null || true
  done
}

# _gov_match <statement> — against the pattern table, echo "surface<TAB>target<TAB>label" for the
# FIRST matching row (case-insensitive), or nothing. Comment/header rows are skipped. Fail-soft.
_gov_match() {
  local stmt="$1" map pattern surface target label
  map="$(_gov_map_file)"
  [ -f "$map" ] || return 0
  while IFS=$'\t' read -r pattern surface target label; do
    case "$pattern" in ''|'#'*|'pattern') continue ;; esac
    [ -n "$surface" ] || continue
    if printf '%s' "$stmt" | grep -qiE "$pattern" 2>/dev/null; then  # pipe-ok: single short scalar (one line), far under a pipe buffer
      printf '%s\t%s\t%s' "$surface" "$target" "$label"
      return 0
    fi
  done < "$map"
  return 0
}
