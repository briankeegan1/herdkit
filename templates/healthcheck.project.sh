#!/usr/bin/env bash
# healthcheck.project.sh (EXAMPLE) — the per-project health command the generic
# scripts/herd/healthcheck.sh delegates to for the HEAVY profile.
#
# Copy this to .herd/healthcheck.project.sh in your project and make it answer ONE question:
# "is the change in this worktree healthy?" Called as:
#
#     .herd/healthcheck.project.sh <worktree-dir> [--heavy] [--oneline]
#
# CONTRACT — exit codes are load-bearing (the watcher reads them):
#   0 = clean (or only a tolerated data/env issue)
#   1 = a real CODE error  → the watcher will NOT merge
#   2 = a data/env issue   → tolerated, treated as clean, surfaced as a ⚠️
#
# PROFILE (HERD-551): the wrapper always forwards --heavy as $2 for a heavy run. If your project
# has its OWN light/heavy split (extra slow probes you only want to pay for here), branch on it —
# and if you skip your heavy probes anyway (missing tool, env cap, …) print a line starting with
# the literal marker "HEAVY-SKIPPED: <why>" so the wrapper hard-fails instead of reporting clean on
# unchecked work. A script that ignores $2 (like this example) runs identically either way.
#
# This example is a Python web/app project that runs the test suite. Swap the body for whatever
# proves health in YOUR project (boot a server + probe /health, `npm test`, `cargo test`, …).
set -u
DIR="${1:?usage: healthcheck.project.sh <worktree-dir> [--heavy] [--oneline]}"
ONELINE=""
for _hk_arg in "$@"; do [ "$_hk_arg" = "--oneline" ] && ONELINE=1; done
cd "$DIR" 2>/dev/null || { echo "no such dir: $DIR"; exit 1; }

PY="./.venv/bin/python"; [ -x "$PY" ] || PY="$(command -v python3)"

# 1. Syntax gate (a hard code error).
if ! errs="$("$PY" -m py_compile app/*.py 2>&1)"; then
  [ -n "$ONELINE" ] && echo "syntax: $(printf '%s' "$errs" | tail -1)" || { echo "SYNTAX ERROR"; printf '%s\n' "$errs"; }
  exit 1
fi

# 2. Test suite. A network/auth/data failure is an env issue (exit 2), not a code bug.
if "$PY" -m pytest --version >/dev/null 2>&1; then
  out="$("$PY" -m pytest -q tests 2>&1)"; rc=$?
  last="$(printf '%s' "$out" | tail -1)"
  if [ "$rc" -eq 0 ]; then
    [ -n "$ONELINE" ] && echo "clean — $last" || { echo "CLEAN"; printf '%s\n' "$out"; }
    exit 0
  fi
  # Heuristic: treat connection/auth/timeout failures as data/env (tolerated).
  if grep -qiE 'connection|timeout|auth|credential|network' <<< "$out"; then
    [ -n "$ONELINE" ] && echo "data/env (not a code bug) — $last" || { echo "DATA/ENV ISSUE"; printf '%s\n' "$out"; }
    exit 2
  fi
  [ -n "$ONELINE" ] && echo "code error — $last" || { echo "CODE ERROR"; printf '%s\n' "$out"; }
  exit 1
fi

[ -n "$ONELINE" ] && echo "clean — compiled, no test runner" || echo "CLEAN (compiled; no pytest)"
exit 0
