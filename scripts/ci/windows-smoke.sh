#!/usr/bin/env bash
# scripts/ci/windows-smoke.sh — the MINIMAL advisory Windows CI smoke.
#
# WSL2-first policy (2026-07-08): native Git Bash is too spotty (bash/locale/python3
# divergences) to gate on, so the supported Windows path is WSL2 — and WSL2 semantics ARE
# Linux semantics, so the `ubuntu` leg already IS the Windows/WSL2 test coverage. This leg
# therefore does NOT run the full hermetic suite chasing Git Bash greens. It runs a fast,
# advisory sanity check of the things that must hold for a Windows checkout regardless of
# how herdkit is ultimately run (WSL2 or, best-effort, Git Bash):
#   1. .gitattributes exists and pins LF on the engine surfaces
#   2. the working tree really is LF (no CRLF snuck into tracked shell/tsv/driver files)
#   3. the Windows docs exist and lead with WSL2
#   4. the core scripts parse under this Git Bash (bash -n)
#
# Advisory: this script prints a clear PASS/WARN summary and always exits 0-on-pass / 1-on-a
# structural problem, but the CI job that calls it is `continue-on-error` so it never blocks a
# merge — it surfaces regressions in the Windows story without gating on Git Bash quirks.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

fails=0
ok(){   printf '  \342\234\205 %s\n' "$1"; }             # ✅
bad(){  printf '  \342\235\214 %s\n' "$1"; fails=$((fails+1)); }  # ❌

echo "▶ Windows advisory smoke (WSL2-first policy — full suite runs on the ubuntu/WSL2 leg)"

# 1. .gitattributes pins LF on the engine surfaces.
if [ -f .gitattributes ] && grep -qE '^\*\.sh[[:space:]].*eol=lf' .gitattributes; then
  ok ".gitattributes pins *.sh to eol=lf"
else
  bad ".gitattributes missing or does not pin *.sh eol=lf"
fi

# 2. The working tree honored .gitattributes eol=lf (proves the LF normalization took on THIS
#    Windows checkout). Ask git itself — `git ls-files --eol` reports the working-tree eol git
#    resolved from the index + attributes (`w/lf` or `w/crlf`) — rather than grepping bytes, which
#    on Git Bash false-positives. Flag any tracked shell/tsv/driver file whose working tree is CRLF.
crlf="$(git ls-files --eol -- '*.sh' '*.tsv' '*.driver' 'bin/herd' 'install.sh' 'herd.sh' 2>/dev/null \
        | awk '$2 == "w/crlf" { print $NF }')"
if [ -z "$crlf" ]; then
  ok "working tree is LF for all tracked shell/tsv/driver files (.gitattributes honored)"
else
  n="$(printf '%s\n' "$crlf" | grep -c .)"
  bad "working tree has CRLF in $n tracked file(s) (.gitattributes eol=lf not applied): $(printf '%s ' $crlf | cut -c1-200)…"
fi

# 3. Windows docs exist and lead with WSL2 (the supported path).
if [ -f docs/windows.md ] && grep -qiE 'WSL2' docs/windows.md; then
  ok "docs/windows.md present and references WSL2"
else
  bad "docs/windows.md missing or does not mention WSL2"
fi

# 4. Core scripts parse under THIS bash (Git Bash on the Windows runner).
parse_fail=0
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || { bad "bash -n failed: $f"; parse_fail=1; }
done < <(git ls-files -- 'scripts/herd/*.sh' 'scripts/ci/*.sh' 'bin/herd' 'install.sh' 'herd.sh')
[ "$parse_fail" -eq 0 ] && ok "core scripts parse under $(bash --version | head -1 | grep -oE 'version [0-9.]+' || echo bash)"

echo
if [ "$fails" -eq 0 ]; then
  echo "✅ Windows advisory smoke clean (WSL2 remains the supported path — docs/windows.md)"
  exit 0
fi
echo "❌ Windows advisory smoke found $fails structural issue(s) above (advisory — does not block merge)"
exit 1
