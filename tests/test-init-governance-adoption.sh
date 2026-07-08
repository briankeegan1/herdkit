#!/usr/bin/env bash
# test-init-governance-adoption.sh — hermetic tests for the HERD-119 `herd init` GOVERNANCE ADOPTION
# pass: an OPT-IN import of gates/conventions from an OPTIONAL CLAUDE.md / AGENTS.md.
#
# BINDING CONSTRAINT under test: CLAUDE.md is ONE source among many, never required or load-bearing.
# Deterministic-first extraction via templates/governance-map.tsv (LLM fallback default-OFF, so these
# assertions are model-free and stable). Every accepted proposal applies ONLY through the validated
# `herd config set` (config-key surface) or a REVIEW_CHECKLIST append (provisioning surface); hook-
# surface rows are RECOGNIZED but not applied (a sequenced follow-up renders them).
#
# NO network, NO gh, NO herdr, NO claude, NO model: init runs with HERD_SKIP_DOCTOR=1
# HERD_SKIP_GH_DETECT=1 against throwaway git repos on a restricted PATH (so graphify is absent and
# the grounding interview is a fixed 2 reads). The interview is driven hermetically via the
# HERD_GROUND_ASSUME_TTY seam (which makes _ground_ask read scripted stdin without a real TTY).
# Asserts:
#   (1) KNOWN CLAUDE.md, accept-all → EXACT proposed surface+key/value mapping:
#         config-key   PUSH_GATE=human · MERGE_POLICY=approve · MERGE_METHOD=squash (in .herd/config)
#         provisioning the style convention appended to the REVIEW_CHECKLIST file
#         hook         the pre-commit-check rule RECOGNIZED but NOT applied (deferred surface)
#         gap          the non-governance sentence printed in the gap report
#   (2) NO CLAUDE.md/AGENTS.md → init is byte-identical: zero governance output, zero governance writes.
#   (3) DECLINE-ALL → config untouched: no governance key written, no REVIEW_CHECKLIST file created.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
export HERD

command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
REAL_BASH="$(command -v bash)"
# Restricted PATH: keeps graphify (usually ~/.local/bin) and claude off PATH so the grounding interview
# is a deterministic 2 reads (codemap, mcp) and the optional Claude scout never fires. Includes the
# dirs where git/python3/awk/grep/sed live on macOS + Linux.
SAFE="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# mkproj <dir> [claude-content] — a throwaway git repo; when a 2nd arg is given, seed CLAUDE.md with it.
mkproj() {
  local d="$1" claude="${2:-}"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  : > "$d/package.json"
  printf 'export const x = 1\n' > "$d/index.js"
  [ -n "$claude" ] && printf '%s' "$claude" > "$d/CLAUDE.md"
  git -C "$d" add -A 2>/dev/null || true
  git -C "$d" commit -q --allow-empty -m init
}

CLAUDE_MD='# Project conventions

- All changes must be reviewed by a human before they are pushed to GitHub.
- Never auto-merge pull requests without approval.
- Use squash merges to keep the history clean.
- Always run the test suite before committing.
- Prefer descriptive variable names over abbreviations.
- This project targets Python 3.11 and ships weekly.
'

# ── (1) KNOWN CLAUDE.md, accept-all → exact surface+key/value mapping ──────────────────────────────
proj="$T/accept"; mkproj "$proj" "$CLAUDE_MD"
# stdin: offer=y ; 4 proposals accepted (PUSH_GATE, MERGE_POLICY, MERGE_METHOD, provisioning) — the
# hook rule consumes NO read ; then grounding: codemap=n, mcp=blank (EOF → default).
out="$( cd "$proj" && printf 'y\na\na\na\na\nn\n' \
        | PATH="$SAFE" HERD_GROUND_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(1) init failed: $out"
cfg="$proj/.herd/config"
echo "$out" | grep -q "Governance adoption"                       || fail "(1) governance adoption should run when CLAUDE.md is present"
# config-key surface — applied through the validated setter into the committed baseline.
grep -qE '^PUSH_GATE="human"$'        "$cfg" || fail "(1) PUSH_GATE=human expected in .herd/config: $(grep PUSH_GATE "$cfg" 2>/dev/null)"
grep -qE '^MERGE_POLICY="approve"$'   "$cfg" || fail "(1) MERGE_POLICY=approve expected: $(grep MERGE_POLICY "$cfg" 2>/dev/null)"
grep -qE '^MERGE_METHOD="squash"$'    "$cfg" || fail "(1) MERGE_METHOD=squash expected: $(grep MERGE_METHOD "$cfg" 2>/dev/null)"
# evidence QUOTED from the source sentence.
echo "$out" | grep -q 'evidence: "Never auto-merge pull requests without approval"' || fail "(1) proposal must quote its source sentence as evidence"
# provisioning surface — the unmappable style convention appended to the REVIEW_CHECKLIST file.
ck="$proj/.herd/review-checklist.md"
[ -f "$ck" ]                                                       || fail "(1) provisioning → REVIEW_CHECKLIST file must be created"
grep -qF 'Prefer descriptive variable names over abbreviations' "$ck" || fail "(1) style convention must be appended to the checklist"
# hook surface — RECOGNIZED but NOT applied (no config key, deferred to the follow-up).
echo "$out" | grep -q "Recognized hook rules"                     || fail "(1) hook rule must be surfaced as recognized/deferred"
echo "$out" | grep -q "hook: pre-action:run-checks"               || fail "(1) hook surface target must be shown"
grep -qE '^ATTRIBUTION_POLICY=|^COMMIT_CONVENTION=' "$cfg"         && fail "(1) hook/unmatched rules must NOT write config keys"
# gap report — the non-governance sentence mapped to nothing.
echo "$out" | grep -q "Gap report"                                || fail "(1) gap report must be printed"
echo "$out" | grep -qF "This project targets Python 3.11"         || fail "(1) unmapped sentence must appear in the gap report"
ok

# ── (2) NO CLAUDE.md/AGENTS.md → init is byte-identical (governance pass fully inert) ──────────────
proj="$T/none"; mkproj "$proj" ""
out="$( cd "$proj" && printf 'n\n' \
        | PATH="$SAFE" HERD_GROUND_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(2) init failed: $out"
cfg="$proj/.herd/config"
echo "$out" | grep -q "Governance adoption"        && fail "(2) no CLAUDE.md → the governance pass must print nothing"
grep -qE '^PUSH_GATE="human"$'        "$cfg"       && fail "(2) no CLAUDE.md → no PUSH_GATE mutation"
grep -qE '^MERGE_METHOD="squash"$'    "$cfg"       && fail "(2) no CLAUDE.md → no MERGE_METHOD mutation"
grep -qE '^MERGE_POLICY="auto"$'      "$cfg"       || fail "(2) no CLAUDE.md → MERGE_POLICY stays the default (auto): $(grep MERGE_POLICY "$cfg" 2>/dev/null)"
[ -e "$proj/.herd/review-checklist.md" ]           && fail "(2) no CLAUDE.md → no REVIEW_CHECKLIST file created"
ok

# ── (3) DECLINE-ALL → config untouched (offer accepted, every proposal declined) ──────────────────
proj="$T/decline"; mkproj "$proj" "$CLAUDE_MD"
# stdin: offer=y ; every proposal declined (n) ; grounding codemap=n (EOF → mcp default).
out="$( cd "$proj" && printf 'y\nn\nn\nn\nn\nn\n' \
        | PATH="$SAFE" HERD_GROUND_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(3) init failed: $out"
cfg="$proj/.herd/config"
echo "$out" | grep -q "Governance adoption"        || fail "(3) governance adoption should still run (offer accepted)"
grep -qE '^PUSH_GATE="human"$'        "$cfg"       && fail "(3) decline-all → PUSH_GATE must NOT be written"
grep -qE '^MERGE_POLICY="approve"$'   "$cfg"       && fail "(3) decline-all → MERGE_POLICY must stay default (not approve)"
grep -qE '^MERGE_METHOD="squash"$'    "$cfg"       && fail "(3) decline-all → MERGE_METHOD must stay default (not squash)"
[ -e "$proj/.herd/review-checklist.md" ]           && fail "(3) decline-all → REVIEW_CHECKLIST file must NOT be created"
echo "$out" | grep -q "governance adoption: nothing applied" || fail "(3) decline-all → summary must report nothing applied"
ok

echo "ALL PASS ($pass checks)"
