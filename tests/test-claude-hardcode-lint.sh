#!/usr/bin/env bash
# test-claude-hardcode-lint.sh — hermetic proof for the NO-NEW-HARDCODED-CLAUDE lint (HERD-177, driver
# portability P5): the ratchet that FAILS if an engine script grows a NEW hardcoded `claude` invocation
# OUTSIDE the driver seam (templates/drivers/*.driver + scripts/herd/driver.sh + the P1 audit baseline).
#
# Covers:
#   (1) the REAL committed tree scans CLEAN against the committed baseline (the ratchet holds today —
#       every existing claude invocation is grandfathered).
#   (2) a PLANTED new hardcoded claude in a lane is CAUGHT (exit 1, named file:line) — the VERIFY case.
#   (3) the SAME invocation, once added to the baseline, scans clean (the grandfather mechanism).
#   (4) a comment-only `claude --…` mention is NOT flagged (invocations, not prose about them).
#   (5) a claude invocation inside the driver SEAM (driver.sh) is NOT flagged (the seam is exempt).
#   (6) infra FAIL-SOFT: a missing baseline is a tolerated ⚠️ (exit 2), never a false red.
#   (7) --oneline emits exactly one status line.
#
# Fully hermetic: local temp trees + the committed lint. NO herdr, NO claude, NO gh, NO network.
# Run:  bash tests/test-claude-hardcode-lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/.herd/claude-hardcode-lint.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

[ -f "$LINT" ] || fail "lint script missing: $LINT"
[ -f "$ROOT/.herd/claude-hardcode-baseline.tsv" ] || fail "committed baseline missing"

# ── 1. the REAL tree is clean against its committed baseline ──────────────────────────────────────
if out="$(bash "$LINT" "$ROOT" 2>&1)"; then pass; else
  fail "(1) the real engine tree is NOT clean against the committed baseline:
$out
   → a claude invocation exists outside the seam that the baseline does not cover; regen with
     bash .herd/claude-hardcode-lint.sh --emit-baseline > .herd/claude-hardcode-baseline.tsv"
fi
echo "PASS (1) real tree scans clean against the committed baseline"

# ── seed a minimal synthetic engine tree the lint can scan ────────────────────────────────────────
seed_tree() {
  local d="$1"
  mkdir -p "$d/scripts/herd" "$d/bin" "$d/.herd"
  cat > "$d/scripts/herd/herd-feature.sh" <<'EOF'
#!/usr/bin/env bash
echo "spawning a builder"
# NOTE: historically this ran `claude --model $MODEL "$PROMPT"` inline; now routed. (comment only)
EOF
  # The driver seam itself legitimately hardcodes claude — it must NEVER be flagged.
  cat > "$d/scripts/herd/driver.sh" <<'EOF'
#!/usr/bin/env bash
herd_driver_oneshot_exec() { claude -p "$prompt" --model "$model" "$@"; }
EOF
  cat > "$d/bin/herd" <<'EOF'
#!/usr/bin/env bash
echo herd
EOF
  : > "$d/.herd/claude-hardcode-baseline.tsv"
}

# ── 2. a planted new hardcoded claude is CAUGHT ───────────────────────────────────────────────────
P="$T/plant"; seed_tree "$P"
printf '  claude --model "$MODEL" --dangerously-skip-permissions "$PROMPT"\n' >> "$P/scripts/herd/herd-feature.sh"
if out="$(bash "$LINT" "$P" 2>&1)"; then
  fail "(2) planted hardcoded claude was NOT caught: $out"
fi
echo "$out" | grep -qF 'herd-feature.sh' || fail "(2) violation did not name the offending file: $out"
echo "$out" | grep -q 'NEW hardcoded claude'  || fail "(2) violation message not loud: $out"
pass; echo "PASS (2) a planted hardcoded claude invocation is caught, named file:line"

# ── 3. the same invocation, grandfathered into the baseline, scans clean ──────────────────────────
bash "$LINT" --emit-baseline "$P" > "$P/.herd/claude-hardcode-baseline.tsv"
bash "$LINT" "$P" >/dev/null 2>&1 || fail "(3) baselined invocation still reds — the grandfather set is not honored"
pass; echo "PASS (3) a baselined invocation scans clean (grandfather mechanism)"

# ── 4. a comment-only mention is not flagged; 5. the driver seam is exempt ────────────────────────
C="$T/comment"; seed_tree "$C"   # seed already carries a comment mention + a driver.sh claude call
bash "$LINT" "$C" >/dev/null 2>&1 || fail "(4/5) a comment mention or the driver-seam claude was flagged as a violation"
# Prove the seam-exemption is real: a claude invocation ONLY in driver.sh must still be clean.
printf '\nfoo() { claude --continue "$x"; }\n' >> "$C/scripts/herd/driver.sh"
bash "$LINT" "$C" >/dev/null 2>&1 || fail "(5) a claude invocation inside driver.sh (the seam) was flagged"
pass; echo "PASS (4/5) comment-only mentions and driver-seam claude are exempt"

# Negative control: the SAME invocation in a NON-seam lane IS caught (proves 4/5 aren't false-clean).
printf '\nbar() { claude --continue "$x"; }\n' >> "$C/scripts/herd/herd-feature.sh"
if bash "$LINT" "$C" >/dev/null 2>&1; then fail "(5-control) a lane claude invocation was NOT caught — exemption is over-broad"; fi
pass; echo "PASS (5-control) the same invocation in a lane (non-seam) IS caught"

# ── 6. infra fail-soft: missing baseline → exit 2 (tolerated), not a red ──────────────────────────
M="$T/nobaseline"; seed_tree "$M"; rm -f "$M/.herd/claude-hardcode-baseline.tsv"
bash "$LINT" "$M" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "(6) missing baseline should be a tolerated infra exit 2, got $rc"
pass; echo "PASS (6) missing baseline → infra fail-soft (exit 2), never a false red"

# ── 7. --oneline emits exactly one line, on both a clean and a violating scan ─────────────────────
lines="$(bash "$LINT" "$C" --oneline 2>&1 | grep -c . || true)"   # $C now has a lane violation
[ "$lines" -eq 1 ] || fail "(7) --oneline on a violation emitted $lines lines, want 1"
Cclean="$T/clean"; seed_tree "$Cclean"
lines="$(bash "$LINT" "$Cclean" --oneline 2>&1 | grep -c . || true)"
[ "$lines" -eq 1 ] || fail "(7) --oneline on a clean scan emitted $lines lines, want 1"
pass; echo "PASS (7) --oneline emits exactly one status line"

echo "ALL PASS ($PASS checks)"
