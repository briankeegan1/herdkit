#!/usr/bin/env bash
# healthcheck.rust.sh (EXAMPLE) — a per-project health command for a Rust (Cargo) project.
# `herd init` seeds this into .herd/healthcheck.project.sh when scout detects lang=rust; you can also
# copy it by hand and point HEALTHCHECK_CMD at it. Same contract as templates/healthcheck.project.sh:
# exit 0 clean, 1 code error, 2 data/env (tolerated).
set -u
DIR="${1:?usage: healthcheck.rust.sh <worktree-dir> [--oneline]}"
ONELINE=""; [ "${2:-}" = "--oneline" ] && ONELINE=1
cd "$DIR" 2>/dev/null || { echo "no such dir: $DIR"; exit 1; }

# 1. cargo check as the hard code gate (type-checks + compiles without producing binaries).
if ! out="$(cargo check --quiet 2>&1)"; then
  [ -n "$ONELINE" ] && echo "check: $(printf '%s' "$out" | tail -1)" || { echo "CHECK FAILED"; printf '%s\n' "$out"; }
  exit 1
fi

# 2. Test suite; classify infra failures as data/env (tolerated), everything else as a code error.
out="$(cargo test --quiet 2>&1)"; rc=$?
last="$(printf '%s' "$out" | tail -1)"
if [ "$rc" -eq 0 ]; then
  [ -n "$ONELINE" ] && echo "clean — $last" || { echo "CLEAN"; printf '%s\n' "$out"; }
  exit 0
fi
if printf '%s' "$out" | grep -qiE 'connection refused|timeout|could not resolve|network|dns|auth|credential'; then
  [ -n "$ONELINE" ] && echo "data/env — $last" || { echo "DATA/ENV ISSUE"; printf '%s\n' "$out"; }
  exit 2
fi
[ -n "$ONELINE" ] && echo "code error — $last" || { echo "CODE ERROR"; printf '%s\n' "$out"; }
exit 1
