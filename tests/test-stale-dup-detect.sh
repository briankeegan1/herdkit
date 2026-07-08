#!/usr/bin/env bash
# test-stale-dup-detect.sh — hermetic proof for the pre-merge STALE-DUPLICATE gate (HERD-188).
#
# The gate (scripts/herd/stale-dup-gate.sh) HOLDS a PR that re-implements already-shipped work:
#   (1) DUPLICATE  — its tracked 'Refs: <ID>' item already shipped via ANOTHER merged PR, or
#   (2) STALE BASE — its touched files were materially changed on the base branch by a merge the
#                    branch predates (a clean-but-behind merge would silently clobber newer work).
#
# This test drives BOTH the pure helpers (ref extraction, duplicate-ref match, git set-intersection)
# AND the stale_dup_check orchestrator through its HERD_-namespaced test seams — NO gh, NO herdr, NO
# network, NO model. The STALE-BASE cases build a throwaway git repo with two branches. The headline
# item verification ("two PRs implementing the same item; the second is held") is scenario D1.
# Run:  bash tests/test-stale-dup-detect.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GATE="$ROOT/scripts/herd/stale-dup-gate.sh"

[ -f "$GATE" ] || { echo "FAIL: missing $GATE" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

# shellcheck source=/dev/null
. "$GATE"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }

# git wrapper — hermetic identity, no global config, no hooks, no signing.
g() { git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# ── A. ref extraction (stale_dup_extract_ref) ──────────────────────────────────────────────────────
[ "$(printf 'Refs: HERD-49\n'                       | stale_dup_extract_ref)" = "HERD-49" ] \
  || fail "A1: plain 'Refs: HERD-49' should extract HERD-49"
ok "A1 extracts a plain Refs: line"

[ "$(printf 'Some PR\n\nRefs: HERD-188  trailing\n'  | stale_dup_extract_ref)" = "HERD-188" ] \
  || fail "A2: first whitespace-delimited token after Refs: is the ref"
ok "A2 takes the first token after Refs:"

# An HTML-comment example ref must NOT poison the extractor; the real line wins.
_body="$(printf '<!--\nRefs: HERD-000 (example)\n-->\nRefs: HERD-77\n')"
[ "$(printf '%s' "$_body" | stale_dup_extract_ref)" = "HERD-77" ] \
  || fail "A3: HTML-comment Refs must be stripped; real Refs HERD-77 taken"
ok "A3 strips an HTML-comment Refs: before extracting"

[ -z "$(printf 'Refs: <ID>\n'   | stale_dup_extract_ref)" ] || fail "A4: placeholder <ID> must extract empty"
[ -z "$(printf 'Refs: none\n'   | stale_dup_extract_ref)" ] || fail "A4: 'none' placeholder must extract empty"
[ -z "$(printf 'no ref here\n'  | stale_dup_extract_ref)" ] || fail "A4: body with no Refs must extract empty"
ok "A4 rejects placeholders / no-ref bodies (fail-soft)"

# ── B. enabled lever (stale_dup_enabled) ───────────────────────────────────────────────────────────
( unset STALE_DUP_DETECT; stale_dup_enabled ) || fail "B1: default (unset) must be enabled"
( STALE_DUP_DETECT=on   stale_dup_enabled ) || fail "B1: on must be enabled"
( STALE_DUP_DETECT=off  stale_dup_enabled ) && fail "B1: off must be DISABLED"
ok "B1 lever: default/on enabled, off disabled"

# ── C. duplicate-ref match (_stale_dup_shipped_by, via the merged-file seam) ────────────────────────
MERGED="$T/merged.tsv"
printf '185\tHERD-49\n201\tHERD-90\n' > "$MERGED"

# HERD-49 shipped by merged PR #185; the open PR is #236 → duplicate, shipper=185.
_sh="$(HERD_STALE_DUP_MERGED_FILE="$MERGED" _stale_dup_shipped_by "HERD-49" "236" || true)"
[ "$_sh" = "185" ] || fail "C1: HERD-49 should be reported shipped by #185 (got '$_sh')"
ok "C1 reports the merged PR that already shipped the ref"

# Self-exclusion: a PR must never be its own duplicate.
printf '236\tHERD-49\n' > "$T/merged-self.tsv"
HERD_STALE_DUP_MERGED_FILE="$T/merged-self.tsv" _stale_dup_shipped_by "HERD-49" "236" >/dev/null \
  && fail "C2: a PR must not be flagged a duplicate of itself"
ok "C2 excludes the PR itself from the merged set"

# A ref no merged PR carries → no shipper.
HERD_STALE_DUP_MERGED_FILE="$MERGED" _stale_dup_shipped_by "HERD-999" "236" >/dev/null \
  && fail "C3: an unshipped ref must have no shipper"
ok "C3 no false match for an unshipped ref"

# ── D. duplicate ORCHESTRATION (stale_dup_check) — the headline two-PRs-one-item verification ───────
BODY49="$T/body49.md"; printf 'Implements the thing.\n\nRefs: HERD-49\n' > "$BODY49"

# D1: PR #236 carries Refs: HERD-49; HERD-49 already merged via #185 → HOLD, kind=duplicate.
(
  export HERD_STALE_DUP_BODY_FILE="$BODY49" HERD_STALE_DUP_MERGED_FILE="$MERGED"
  if stale_dup_check "236" "dup-slug" "$T/nonexistent-dir" "deadbeef" "main"; then
    echo "D1: second PR implementing HERD-49 should be HELD (returned proceed)" >&2; exit 1
  fi
  [ "$_STALE_DUP_KIND" = "duplicate" ] || { echo "D1: kind must be 'duplicate' (got '$_STALE_DUP_KIND')" >&2; exit 1; }
  case "$_STALE_DUP_REASON" in *HERD-49*"#185"*) : ;; *) echo "D1: reason must name HERD-49 + #185 (got '$_STALE_DUP_REASON')" >&2; exit 1 ;; esac
) || exit 1
ok "D1 HOLDS the second PR implementing an already-shipped item (duplicate)"

# D2: same ref but NOT present in the merged set, and no git overlap → PROCEED (no false hold).
BODY999="$T/body999.md"; printf 'Refs: HERD-999\n' > "$BODY999"
(
  export HERD_STALE_DUP_BODY_FILE="$BODY999" HERD_STALE_DUP_MERGED_FILE="$MERGED"
  stale_dup_check "300" "fresh" "$T/nonexistent-dir" "deadbeef" "main" \
    || { echo "D2: a non-duplicate, no-overlap PR must PROCEED" >&2; exit 1; }
) || exit 1
ok "D2 proceeds for a non-duplicate ref with no overlap"

# D3: fail-soft — a body with NO ref must never hold on the duplicate path.
(
  export HERD_STALE_DUP_BODY_FILE="$T/body999.md" HERD_STALE_DUP_MERGED_FILE="$MERGED"
  printf 'no tracker ref at all\n' > "$T/body999.md"
  stale_dup_check "301" "noref" "$T/nonexistent-dir" "deadbeef" "main" \
    || { echo "D3: a ref-less PR must PROCEED (fail-soft)" >&2; exit 1; }
) || exit 1
ok "D3 fail-soft: a PR with no item ref proceeds"

# D4: the gate is a no-op when STALE_DUP_DETECT=off, even for a provable duplicate.
(
  export HERD_STALE_DUP_BODY_FILE="$BODY49" HERD_STALE_DUP_MERGED_FILE="$MERGED" STALE_DUP_DETECT=off
  stale_dup_check "236" "dup-slug" "$T/nonexistent-dir" "deadbeef" "main" \
    || { echo "D4: STALE_DUP_DETECT=off must PROCEED even for a duplicate" >&2; exit 1; }
) || exit 1
ok "D4 disabled (STALE_DUP_DETECT=off) proceeds even for a duplicate"

# ── E. STALE-BASE detection (stale_dup_base_overlap) — real git sandbox ─────────────────────────────
REPO="$T/repo"; mkdir -p "$REPO"
g init -q -b main
printf 'A0\n' > "$REPO/A.txt"; printf 'B0\n' > "$REPO/B.txt"
g add -A; g commit -q -m "c0: A + B"          # C0 = the common merge-base
g branch feat-a; g branch feat-b; g branch uptodate main
# feat-a touches A; feat-b touches B (each off C0).
g checkout -q feat-a; printf 'A-feat\n' > "$REPO/A.txt"; g add -A; g commit -q -m "feat-a: edit A"
g checkout -q feat-b; printf 'B-feat\n' > "$REPO/B.txt"; g add -A; g commit -q -m "feat-b: edit B"
# main advances AFTER the branch point and materially changes A.
g checkout -q main;   printf 'A-main2\n' > "$REPO/A.txt"; g add -A; g commit -q -m "main: change A after branch point"

# E1: feat-a re-touches A, which main changed since the merge-base → STALE overlap on A.
_ov="$(stale_dup_base_overlap "$REPO" "main" "feat-a" || true)"
[ "$_ov" = "A.txt" ] || fail "E1: feat-a should overlap main on A.txt (got '$_ov')"
ok "E1 detects a touched file the base branch changed after the merge-base"

# E2: feat-b touches B; main changed only A → NO overlap.
stale_dup_base_overlap "$REPO" "main" "feat-b" >/dev/null \
  && fail "E2: feat-b touches B only; must NOT overlap main's A change"
ok "E2 no overlap when touched files differ from base's changes"

# E3: an up-to-date branch (merge-base == base tip → not behind) is never stale.
stale_dup_base_overlap "$REPO" "main" "uptodate" >/dev/null \
  && fail "E3: a branch already containing base's tip must not be flagged stale"
ok "E3 a not-behind branch is never stale"

# E4: a non-existent worktree fails soft (no hold).
stale_dup_base_overlap "$T/nope" "main" "feat-a" >/dev/null \
  && fail "E4: a missing worktree must fail soft (no overlap)"
ok "E4 fail-soft on a missing worktree"

# ── F. stale-base ORCHESTRATION (stale_dup_check on the git sandbox, no ref) ────────────────────────
printf 'no tracker ref\n' > "$T/noref.md"
(
  export HERD_STALE_DUP_BODY_FILE="$T/noref.md"   # no ref → duplicate path skipped
  unset HERD_STALE_DUP_MERGED_FILE
  if stale_dup_check "400" "stale-slug" "$REPO" "feat-a" "main"; then
    echo "F1: feat-a on a stale base should be HELD" >&2; exit 1
  fi
  [ "$_STALE_DUP_KIND" = "stale-base" ] || { echo "F1: kind must be 'stale-base' (got '$_STALE_DUP_KIND')" >&2; exit 1; }
  case "$_STALE_DUP_REASON" in *A.txt*) : ;; *) echo "F1: reason should name the overlapping file (got '$_STALE_DUP_REASON')" >&2; exit 1 ;; esac
) || exit 1
ok "F1 HOLDS a PR on a stale base (stale-base) via stale_dup_check"

# F2: feat-b (no overlap, no ref) → PROCEED end-to-end.
(
  export HERD_STALE_DUP_BODY_FILE="$T/noref.md"
  unset HERD_STALE_DUP_MERGED_FILE
  stale_dup_check "401" "clean-slug" "$REPO" "feat-b" "main" \
    || { echo "F2: feat-b has no overlap and no ref → must PROCEED" >&2; exit 1; }
) || exit 1
ok "F2 proceeds for a fresh, non-overlapping PR"

echo
echo "ALL PASS ($PASS checks) — stale-duplicate gate (HERD-188)"
