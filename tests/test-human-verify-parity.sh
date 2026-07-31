#!/usr/bin/env bash
# test-human-verify-parity.sh — the DRIFT GUARD between the two HUMAN-VERIFY parsers (HERD-442).
#
# `scripts/herd/human-verify.sh` (the bash seam, read by herd-approve.sh + journal-audit.sh) and
# `pysrc/herd/human_verify.py` (the in-process twin the Python merge gate calls) must agree on EVERY
# body, because they gate the SAME decision from two sides: bash decides what an operator is shown as
# "steps awaiting verification", python decides whether the PR is held at all.
#
# Drift here fails OPEN — a body the python half reads as "no block" is a silent auto-merge of a PR
# whose declared manual steps were never run, which is exactly the bypass HERD-442 found in
# production (PR #555, merged 2026-07-30 with a declared block and no hold). So the two are pinned
# against one corpus rather than asserted to be "the same regex".
#
# Proves:
#   (1)  Both parsers return byte-identical step lists for every body in the corpus.
#   (2)  Both agree on the BOOLEAN (has / does not have a hold), which is what the gate branches on.
#   (3)  NON-VACUOUS: the corpus contains at least one body that IS a hold and one that is NOT, so a
#        parser stubbed to a constant cannot pass.
#
# Network-free. Run:  bash tests/test-human-verify-parity.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SH="$ROOT/scripts/herd/human-verify.sh"
PY="$ROOT/pysrc/herd/human_verify.py"

[ -f "$SH" ] || { echo "FAIL: missing $SH" >&2; exit 1; }
[ -f "$PY" ] || { echo "FAIL: missing $PY" >&2; exit 1; }
# shellcheck source=/dev/null
. "$SH"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { PASS=$((PASS+1)); }

# ── the corpus: one file per body, covering every branch of the documented parse contract ─────────
mkdir -p "$T/corpus"
_body() { printf '%s' "$2" > "$T/corpus/$1"; }

_body 01-bulleted        'Intro prose.

HUMAN-VERIFY:
- run the live smoke test
- eyeball the pane layout

Trailing prose.'
_body 02-oneliner        'HUMAN-VERIFY: run the smoke test'
_body 03-bold-bulleted   '- **HUMAN-VERIFY:**
- step a
- step b'
_body 04-bare-marker     'HUMAN-VERIFY:

nothing follows the blank line'
_body 05-absent          'An ordinary PR body with no manual steps at all.'
_body 06-numbered        'HUMAN-VERIFY:
1. first
2) second'
_body 07-lowercase       'human-verify: mixed case marker'
_body 08-heading         '## HUMAN-VERIFY:
   indented step'
_body 09-quoted          '> HUMAN-VERIFY:
> - quoted step'
_body 10-empty           ''
_body 11-second-marker   'HUMAN-VERIFY:
- only the first block counts

HUMAN-VERIFY:
- this one is ignored'
_body 12-oneliner-bullet 'HUMAN-VERIFY: - a bulleted one-liner'
_body 13-marker-only-eof 'HUMAN-VERIFY:'
_body 14-crlf-ish        'HUMAN-VERIFY:
	tab-indented step'
_body 15-empty-steps     'HUMAN-VERIFY:
-
-   '

held=0; unheld=0
for f in "$T/corpus"/*; do
  name="$(basename "$f")"
  sh_steps="$(human_verify_steps < "$f")"
  py_steps="$(PYTHONPATH="$ROOT/pysrc" python3 -c '
import sys
from herd import human_verify
sys.stdout.write("\n".join(human_verify.steps(open(sys.argv[1], encoding="utf-8").read())))
' "$f")"
  [ "$sh_steps" = "$py_steps" ] || fail "(1) parser drift on $name:
  bash: $(printf '%s' "$sh_steps" | tr '\n' '|')
  py  : $(printf '%s' "$py_steps" | tr '\n' '|')"

  sh_has=no; human_verify_has < "$f" && sh_has=yes
  py_has="$(PYTHONPATH="$ROOT/pysrc" python3 -c '
import sys
from herd import human_verify
print("yes" if human_verify.has(open(sys.argv[1], encoding="utf-8").read()) else "no")
' "$f")"
  [ "$sh_has" = "$py_has" ] || fail "(2) hold-boolean drift on $name: bash=$sh_has py=$py_has"
  if [ "$sh_has" = yes ]; then held=$((held+1)); else unheld=$((unheld+1)); fi
done
ok
ok

# ── (3) non-vacuous: a constant-returning parser could not have passed the loop above ─────────────
[ "$held" -ge 1 ]   || fail "(3) corpus has no body that IS a hold — the loop would be vacuous"
[ "$unheld" -ge 1 ] || fail "(3) corpus has no body that is NOT a hold — the loop would be vacuous"
ok

echo "ALL PASS ($PASS checks · $held hold / $unheld no-hold bodies)"
