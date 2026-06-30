#!/usr/bin/env bash
# .herd/healthcheck.project.sh — herdkit's OWN health command (the dogfood gate).
# Called by scripts/herd/healthcheck.sh for the heavy profile:
#     .herd/healthcheck.project.sh <worktree-dir> [--oneline]
#
# herdkit has no app — health = the scripts are syntactically sound and the tests pass:
#   1) bash -n over every engine + CLI script               (always available; the hard gate)
#   2) shellcheck over them IF installed                    (best-effort lint)
#   3) the hermetic test suite (tests/*.sh) + bats IF present
#
# CONTRACT: exit 0 = clean · 1 = code error · 2 = data/env (tolerated). herdkit has no data/env
# axis, so it only ever returns 0 or 1.
set -u
DIR="${1:?usage: healthcheck.project.sh <worktree-dir> [--oneline]}"
ONELINE=""; [ "${2:-}" = "--oneline" ] && ONELINE=1
cd "$DIR" 2>/dev/null || { echo "no such dir: $DIR"; exit 1; }

errs=""

# 1. bash -n over all shell scripts (engine + CLI + tests + templates).
while IFS= read -r f; do
  [ -n "$f" ] || continue
  e="$(bash -n "$f" 2>&1)" || errs="${errs}bash -n $f → $(printf '%s' "$e" | tail -1)"$'\n'
done < <(
  { find scripts bin templates tests -type f -name '*.sh' 2>/dev/null
    [ -f bin/herd ] && echo bin/herd; } | sort -u
)

if [ -n "$errs" ]; then
  [ -n "$ONELINE" ] && echo "syntax: $(printf '%s' "$errs" | head -1)" || { echo "SYNTAX ERROR"; printf '%s' "$errs"; }
  exit 1
fi

# 2. shellcheck (best-effort lint — only fail on errors, not style).
sc_note="shellcheck: skipped (not installed)"
if command -v shellcheck >/dev/null 2>&1; then
  if sc="$(shellcheck -S error scripts/herd/*.sh scripts/herd/backends/*.sh bin/herd 2>&1)"; then
    sc_note="shellcheck: clean"
  else
    [ -n "$ONELINE" ] && echo "shellcheck: $(printf '%s' "$sc" | head -1)" || { echo "SHELLCHECK ERRORS"; printf '%s\n' "$sc"; }
    exit 1
  fi
fi

# 3. Tests — bats if present, else run the hermetic *.sh tests directly.
t_note="tests: none"
if command -v bats >/dev/null 2>&1 && ls tests/*.bats >/dev/null 2>&1; then
  if to="$(bats tests/*.bats 2>&1)"; then t_note="tests: bats pass"; else
    [ -n "$ONELINE" ] && echo "bats: $(printf '%s' "$to" | tail -1)" || { echo "BATS FAILED"; printf '%s\n' "$to"; }
    exit 1
  fi
elif ls tests/test-*.sh >/dev/null 2>&1; then
  fails=0
  for t in tests/test-*.sh; do bash "$t" >/dev/null 2>&1 || fails=$((fails+1)); done
  if [ "$fails" -eq 0 ]; then t_note="tests: hermetic suite pass"; else
    [ -n "$ONELINE" ] && echo "tests: $fails failed" || echo "TESTS FAILED: $fails"
    exit 1
  fi
fi

# 4. leak-guard — no single-consumer (Northstar) literal may leak into the generic engine.
# The pattern list lives HERE in .herd/ (outside the scanned surface: scripts/herd + bin/herd +
# templates), so this guard never matches itself. The documented generic placeholder
# "$HOME/source/myproject" in templates/config.example is allowed; everything else under
# $HOME/source/ is a hardcoded leak.
lg_note="leak-guard: clean"
leak_pat='northstar|/Users/macbookpro|\$HOME/source/|streamlit|app/dashboard\.py'
leak_files=()
while IFS= read -r f; do [ -n "$f" ] && leak_files+=("$f"); done < <(
  { find scripts/herd -type f 2>/dev/null
    [ -f bin/herd ] && echo bin/herd
    find templates -type f 2>/dev/null; } | sort -u
)
if [ "${#leak_files[@]}" -gt 0 ]; then
  if hits="$(grep -HinE "$leak_pat" "${leak_files[@]}" 2>/dev/null | grep -vE '\$HOME/source/myproject')"; then
    [ -n "$ONELINE" ] && echo "leak-guard: $(printf '%s' "$hits" | head -1)" \
      || { echo "LEAK-GUARD: single-consumer literal in generic engine"; printf '%s\n' "$hits"; }
    exit 1
  fi
fi

[ -n "$ONELINE" ] && echo "clean — bash -n ok; $sc_note; $t_note; $lg_note" || { echo "HEALTHCHECK CLEAN"; echo "  $sc_note"; echo "  $t_note"; echo "  $lg_note"; }
exit 0
