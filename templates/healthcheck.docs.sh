#!/usr/bin/env bash
# healthcheck.docs.sh (EXAMPLE) — the per-project health command for a docs / research-lab
# ARCHETYPE project (HERD-409): one with no test suite to run, only markdown to keep honest.
# Copy to .herd/healthcheck.project.sh and point HEALTHCHECK_CMD at it. Same contract as
# templates/healthcheck.project.sh: exit 0 clean, 1 code error, 2 data/env (tolerated).
#
# Three checks over every tracked *.md file (git ls-files when available, so gitignored/vendored
# markdown is never scanned; falls back to find):
#   1. markdown lint    — fenced code blocks (```) must close in pairs; an odd count is a real
#                          authoring bug (a stray/missing fence breaks rendering).
#   2. link lint        — every relative markdown link `(path)` (http(s)/mailto/anchor-only links
#                          skipped — no network calls, so this stays fast and deterministic) must
#                          resolve to a real file, relative to the linking file's own directory.
#   3. template lint    — every doc must open with a level-1 heading (`# Title`) within its first
#                          few lines — the minimal "every doc looks like a doc" convention.
# Swap/extend this for your own docs conventions (a stricter template, markdownlint/vale if you
# install them, a link checker that also verifies internal anchors).
set -u
DIR="${1:?usage: healthcheck.docs.sh <worktree-dir> [--oneline]}"
ONELINE=""; [ "${2:-}" = "--oneline" ] && ONELINE=1
cd "$DIR" 2>/dev/null || { echo "no such dir: $DIR"; exit 1; }

if git rev-parse --git-dir >/dev/null 2>&1; then
  files="$(git ls-files '*.md' 2>/dev/null)"
else
  files="$(find . -name '*.md' -not -path './.git/*' 2>/dev/null | sed 's#^\./##')"
fi

if [ -z "$files" ]; then
  [ -n "$ONELINE" ] && echo "clean — no markdown files" || echo "CLEAN (no markdown files)"
  exit 0
fi

errs=""
add_err() { errs="${errs}${errs:+$'\n'}$1"; }

for f in $files; do
  [ -f "$f" ] || continue

  # 1. markdown lint — fenced code blocks must close in pairs.
  fences="$(grep -c '^[[:space:]]*```' "$f" 2>/dev/null)"; fences="${fences:-0}"
  if [ $(( fences % 2 )) -ne 0 ]; then
    add_err "$f: unclosed fenced code block (odd \`\`\` count: $fences)"
  fi

  # 2. link lint — relative markdown links must resolve to a real file.
  dir="$(dirname "$f")"
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    case "$link" in
      http://*|https://*|mailto:*|\#*) continue ;;
    esac
    target="${link%%#*}"      # drop a trailing #anchor
    [ -n "$target" ] || continue
    case "$target" in
      /*) resolved=".$target" ;;
      *)  resolved="$dir/$target" ;;
    esac
    [ -e "$resolved" ] || add_err "$f: broken link → $link"
  done <<EOF
$(grep -oE '\]\([^) ]+\)' "$f" 2>/dev/null | sed -E 's/^\]\((.*)\)$/\1/')
EOF

  # 3. template-conformance lint — the doc must open with a level-1 heading.
  if ! head -n 5 "$f" | grep -qE '^# '; then
    add_err "$f: no level-1 heading ('# Title') in the first 5 lines"
  fi
done

if [ -z "$errs" ]; then
  [ -n "$ONELINE" ] && echo "clean — $(printf '%s\n' "$files" | wc -l | tr -d ' ') markdown files" || echo "CLEAN"
  exit 0
fi

n="$(printf '%s\n' "$errs" | wc -l | tr -d ' ')"
if [ -n "$ONELINE" ]; then
  echo "code error — $n markdown issue(s): $(printf '%s' "$errs" | head -1)"
else
  echo "CODE ERROR"
  printf '%s\n' "$errs"
fi
exit 1
