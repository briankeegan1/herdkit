#!/usr/bin/env bash
# .herd/claude-hardcode-lint.sh — the NO-NEW-HARDCODED-CLAUDE dogfood lint (HERD-177, driver
# portability P5). It FAILS if an engine script grows a NEW hardcoded `claude`/claude-specific
# invocation OUTSIDE the driver seam, so the portability epic's routing work (HERD-150 P2–P6) can
# only ratchet FORWARD: once a call site is routed through the seam it can never silently reappear,
# and a fresh `claude …` typed into a lane is caught at gate time instead of at runtime on a
# non-Claude runtime.
#
# WHAT THE DRIVER SEAM IS (where hardcoded `claude` is LEGITIMATE and therefore NOT scanned):
#   • templates/drivers/*.driver — the .driver binding files. `claude` there is DATA: the command
#     shape a driver binds each capability to (a non-Claude driver rebinds it). Not engine code.
#   • scripts/herd/driver.sh    — the RUNTIME shim. It is the ONE place that legitimately names the
#     default runtime (`claude`) so every other engine script routes THROUGH it. Excluded wholesale.
#   • the P1 agent-exec binding table (docs/driver-abstraction.md § agent-runtime portability) —
#     the audited catalogue of the EXISTING un-routed sites, one per capability class. Those sites
#     are grandfathered in the baseline below until the routing phases retire them.
#
# HOW THE RATCHET WORKS: the SCANNED surface is the engine tree — scripts/herd/*.sh (top level only,
# so the driver seam driver.sh, the sim/ sandbox scripts, and backends/ are out) plus bin/herd. Every
# NON-comment line that INVOKES `claude` (or carries a claude-specific incantation) is fingerprinted as
# `<relpath>\t<whitespace-collapsed line>`. The committed baseline (.herd/claude-hardcode-baseline.tsv)
# is the grandfather set of sites that exist TODAY (the P1 audit, still awaiting routing). A current
# fingerprint ABSENT from the baseline is a NEW hardcoded `claude` → the lint fails, naming file:line.
# A baseline entry no longer present (a site routed through the seam and removed) is advisory only —
# tighten the baseline to keep the ratchet honest, but it never reds. Line NUMBERS are deliberately
# NOT part of the fingerprint, so moving an existing invocation up/down a file is not a false new-site.
#
# WHY A BASELINE, not zero: the routing phases (P2–P6) are incremental. Many claude-specific sites are
# still un-routed by design (the P1 audit map). A hard "zero `claude` in the engine" lint would red the
# whole tree today; the ratchet lets the count only ever go DOWN as sites are routed, while blocking
# any NEW one — the actual invariant HERD-177 protects.
#
# USAGE:
#   bash .herd/claude-hardcode-lint.sh [<root>] [--oneline]   scan (default root: cwd). exit:
#                                                               0 clean · 1 NEW hardcoded claude · 2 infra
#   bash .herd/claude-hardcode-lint.sh --emit-baseline [<root>]   print the current fingerprint set
#                                                               (regenerates .herd/claude-hardcode-baseline.tsv)
#
# CONTRACT: the SCAN exit codes mirror the healthcheck's — 0 clean · 1 a real code error (a new
# hardcoded claude) · 2 a tolerated infra/data issue (missing baseline, no engine tree at <root>) so a
# caller treats a broken invocation of the lint itself as a ⚠️, never a false red. Zero side effects.
set -u

# ── the invocation detector ──────────────────────────────────────────────────────────────────────
# A line "invokes claude" when the token `claude` appears in command position — preceded by a
# non-identifier char (start-of-field, a space, `(`, `--`, `nohup`, `$(`, `|`, `&&`, …; a leading TAB
# in the fingerprint stream also qualifies) and FOLLOWED by a flag (`-x`/`--x`) or an argument
# (`"`, `'`, `$`). This is intentionally broad: it also captures status echoes and doctor-probe prose
# that merely mention `claude --…`. Those are STABLE and already grandfathered in the baseline, so the
# breadth costs nothing while guaranteeing a real spawn/exec/resume invocation is never missed. Kept in
# lockstep with tests/test-claude-hardcode-lint.sh.
_CHL_PAT='(^|[^[:alnum:]_./-])claude[[:space:]]+(--?[a-z]|["'\''$])'

# _chl_matches <root> — emit one TAB-separated `<relpath>\t<lineno>\t<collapsed-snippet>` row per
# matching NON-comment line across the scanned engine surface. Whitespace inside each snippet is
# collapsed to single spaces (so the TAB field separator is unambiguous and the fingerprint is stable
# against reformatting). Deterministic order: file list sorted, lines in file order.
_chl_matches() {
  local root="$1" abs rel files
  files="$( { find "$root/scripts/herd" -maxdepth 1 -type f -name '*.sh' ! -name 'driver.sh' 2>/dev/null
              [ -f "$root/bin/herd" ] && printf '%s\n' "$root/bin/herd"; } | sort -u )"
  [ -n "$files" ] || return 0
  while IFS= read -r abs; do
    [ -n "$abs" ] || continue
    rel="${abs#"$root"/}"
    awk -v F="$rel" '
      { s=$0; sub(/^[ \t]+/,"",s); if (s ~ /^#/) next
        gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s)
        if (s == "") next
        print F "\t" NR "\t" s }
    ' "$abs"
  done <<< "$files" | grep -E "$_CHL_PAT" || true
}

# _chl_current_keys <root> — the current fingerprint set (`<relpath>\t<snippet>`), sorted-unique.
_chl_current_keys() { _chl_matches "$1" | cut -f1,3 | sort -u; }

# _chl_baseline_keys <baseline-file> — the grandfathered fingerprint set, sorted-unique, ignoring
# comment (#) and blank lines so the committed baseline can carry a header.
_chl_baseline_keys() {
  [ -f "$1" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$1" | sort -u
}

ROOT="."
ONELINE=""
MODE="scan"
for a in "$@"; do
  case "$a" in
    --oneline)       ONELINE=1 ;;
    --emit-baseline) MODE="emit" ;;
    -*) printf 'usage: claude-hardcode-lint.sh [<root>] [--oneline] | --emit-baseline [<root>]\n' >&2; exit 2 ;;
    *)  ROOT="$a" ;;
  esac
done
ROOT="${ROOT%/}"; [ -n "$ROOT" ] || ROOT="."
BASELINE="$ROOT/.herd/claude-hardcode-baseline.tsv"

if [ "$MODE" = "emit" ]; then
  _chl_current_keys "$ROOT"
  exit 0
fi

# INFRA fail-soft: no engine tree at <root>, or no committed baseline → a ⚠️ (exit 2), never a red.
if [ -z "$(_chl_matches "$ROOT")" ] && [ ! -f "$ROOT/bin/herd" ]; then
  [ -n "$ONELINE" ] && echo "claude-hardcode: skipped (no engine tree at $ROOT)" \
    || echo "⚠️  CLAUDE-HARDCODE LINT: no engine tree at $ROOT (skipped, not a code bug)"
  exit 2
fi
if [ ! -f "$BASELINE" ]; then
  [ -n "$ONELINE" ] && echo "claude-hardcode: skipped (no baseline at $BASELINE)" \
    || echo "⚠️  CLAUDE-HARDCODE LINT: no baseline at $BASELINE (skipped, not a code bug)"
  exit 2
fi

# NEW = current − baseline. A non-empty NEW set is a hardcoded `claude` outside the driver seam.
NEW="$(comm -23 <(_chl_current_keys "$ROOT") <(_chl_baseline_keys "$BASELINE") || true)"
if [ -n "$NEW" ]; then
  # Re-attach line numbers for an actionable message (first matching line per fingerprint).
  ALL="$(_chl_matches "$ROOT")"
  report="$(while IFS=$'\t' read -r rel snip; do
              [ -n "$rel" ] || continue
              ln="$(printf '%s\n' "$ALL" | awk -F'\t' -v f="$rel" -v s="$snip" '$1==f && $3==s {print $2; exit}')"
              printf '  %s:%s\t%s\n' "$rel" "${ln:-?}" "$snip"
            done <<< "$NEW")"
  n="$(printf '%s\n' "$NEW" | grep -c .)"
  if [ -n "$ONELINE" ]; then
    echo "claude-hardcode: $n NEW hardcoded claude invocation(s) outside the driver seam — $(printf '%s' "$report" | head -1 | sed 's/^[[:space:]]*//')"
  else
    echo "❌ CLAUDE-HARDCODE LINT: NEW hardcoded claude invocation(s) outside the driver seam"
    echo "   Route the call through scripts/herd/driver.sh (the runtime seam) or a {{DRIVER_*}}"
    echo "   token, OR — if this is a genuinely new grandfathered site — add it to"
    echo "   .herd/claude-hardcode-baseline.tsv (regen: bash .herd/claude-hardcode-lint.sh --emit-baseline > .herd/claude-hardcode-baseline.tsv)"
    printf '%s\n' "$report"
  fi
  exit 1
fi

# Advisory: baseline entries no longer present (a site was routed + removed) — tighten the baseline.
STALE="$(comm -13 <(_chl_current_keys "$ROOT") <(_chl_baseline_keys "$BASELINE") || true)"
if [ -n "$ONELINE" ]; then
  if [ -n "$STALE" ]; then
    echo "claude-hardcode: clean ($(printf '%s\n' "$STALE" | grep -c .) baseline entr(y/ies) now routed — regen to tighten)"
  else
    echo "claude-hardcode: clean"
  fi
else
  echo "✅ CLAUDE-HARDCODE LINT CLEAN (no new hardcoded claude outside the driver seam)"
  if [ -n "$STALE" ]; then
    echo "   note: $(printf '%s\n' "$STALE" | grep -c .) baseline entr(y/ies) no longer present (routed through the seam);"
    echo "   regen to tighten: bash .herd/claude-hardcode-lint.sh --emit-baseline > .herd/claude-hardcode-baseline.tsv"
  fi
fi
exit 0
