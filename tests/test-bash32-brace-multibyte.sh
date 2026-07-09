#!/usr/bin/env bash
# test-bash32-brace-multibyte.sh — HERD-260: unbraced $var before a multibyte UTF-8 char is a
# latent crash class on macOS bash 3.2 under set -u (the multibyte byte is swallowed into the
# identifier, so the name is unbound). Engine strings that interpolate $before→$after must use
# ${before}→${after} so the identifier is unambiguous on every bash.
#
# Verifies:
#   (1) a braced "$before→$after"-shaped interpolation under set -u + a UTF-8 locale PRINTS
#       (does not unbound-variable crash).
#   (2) no engine script (scripts/herd/**/*.sh, bin/herd) still has an unbraced $word immediately
#       followed by a multibyte UTF-8 char.
#
# Fully hermetic: no herdr, no network, no git. Run: bash tests/test-bash32-brace-multibyte.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); echo "PASS ($PASS) $1"; }

# Prefer a UTF-8 locale so the multibyte path is real. Fall back to C.UTF-8 / en_US.UTF-8.
_utf8_locale=""
for _cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if LC_ALL="$_cand" locale charmap 2>/dev/null | grep -qi 'utf-8'; then
    _utf8_locale="$_cand"
    break
  fi
done
[ -n "$_utf8_locale" ] || fail "no UTF-8 locale available (need C.UTF-8 or en_US.UTF-8 for this test)"

# ── (1) braced form prints under set -u + UTF-8 ───────────────────────────────────────────────────
# Reproduces the journal/console shape "($before→$after)" with braces so bash-3.2 cannot glue the
# leading UTF-8 byte of → into the identifier. On macOS bash 3.2 the unbraced form dies with
# "unbound variable"; the braced form must print on every bash we ship against.
out="$(
  LC_ALL="$_utf8_locale" bash -c '
    set -u
    before=1
    after=2
    printf "%s" "(${before}→${after})"
  ' 2>&1
)" || fail "(1) braced multibyte interpolation exited non-zero under set -u: $out"
# Expected: literal open-paren, 1, U+2192 RIGHTWARDS ARROW, 2, close-paren.
printf '%s' "$out" | grep -qF '(1→2)' \
  || fail "(1) expected '(1→2)' from braced interpolation under set -u (got: $out)"
pass "braced \${before}→\${after} prints under set -u + UTF-8 locale ($_utf8_locale)"

# ── (2) lint: no unbraced \$word immediately before a multibyte char in engine scripts ────────────
# Same class the fix grepped for: \$[A-Za-z_][A-Za-z0-9_]* followed by a non-ASCII byte.
# Scans scripts/herd/**/*.sh and bin/herd only (engine surface named by HERD-260).
hits="$(
  python3 - "$ROOT" <<'PY'
import re, sys
from pathlib import Path

root = Path(sys.argv[1])
pat = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7F])")
hits = []
paths = list((root / "scripts" / "herd").rglob("*.sh"))
herd_cli = root / "bin" / "herd"
if herd_cli.is_file():
    paths.append(herd_cli)
for path in sorted(paths):
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        continue
    for i, line in enumerate(text.splitlines(), 1):
        for m in pat.finditer(line):
            rel = path.relative_to(root)
            hits.append(f"{rel}:{i}: ${m.group(1)}…  {line.strip()[:120]}")
if hits:
    print("\n".join(hits))
    sys.exit(1)
sys.exit(0)
PY
)" && lint_rc=0 || lint_rc=$?

if [ "$lint_rc" -ne 0 ]; then
  fail "(2) unbraced \$word before multibyte UTF-8 still present in engine scripts:
$hits
   → rewrite each to \${word} so bash 3.2 under set -u does not treat the multibyte as part of the name"
fi
pass "no unbraced \$word<multibyte> remains in scripts/herd/**/*.sh or bin/herd"

echo "OK: $PASS checks passed (HERD-260 bash-3.2 brace-before-multibyte)"
