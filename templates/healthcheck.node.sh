#!/usr/bin/env bash
# healthcheck.node.sh (EXAMPLE) — a per-project health command for a Node project.
# Copy to .herd/healthcheck.project.sh and point HEALTHCHECK_CMD at it. Same contract as
# templates/healthcheck.project.sh: exit 0 clean, 1 code error, 2 data/env (tolerated).
set -u
DIR="${1:?usage: healthcheck.node.sh <worktree-dir> [--oneline]}"
ONELINE=""; [ "${2:-}" = "--oneline" ] && ONELINE=1
cd "$DIR" 2>/dev/null || { echo "no such dir: $DIR"; exit 1; }

# 1. Typecheck / lint as the hard code gate (adapt to your toolchain).
if ! out="$(npm run --silent typecheck 2>&1)"; then
  [ -n "$ONELINE" ] && echo "typecheck: $(printf '%s' "$out" | tail -1)" || { echo "TYPECHECK FAILED"; printf '%s\n' "$out"; }
  exit 1
fi

# 2. Test suite; classify infra failures as data/env.
out="$(npm test --silent 2>&1)"; rc=$?
last="$(printf '%s' "$out" | tail -1)"
if [ "$rc" -eq 0 ]; then
  [ -n "$ONELINE" ] && echo "clean — $last" || { echo "CLEAN"; printf '%s\n' "$out"; }
  exit 0
fi
if printf '%s' "$out" | grep -qiE 'econnrefused|timeout|network|auth'; then
  [ -n "$ONELINE" ] && echo "data/env — $last" || { echo "DATA/ENV ISSUE"; printf '%s\n' "$out"; }
  exit 2
fi
[ -n "$ONELINE" ] && echo "code error — $last" || { echo "CODE ERROR"; printf '%s\n' "$out"; }
exit 1
