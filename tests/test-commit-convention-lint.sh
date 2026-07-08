#!/usr/bin/env bash
# test-commit-convention-lint.sh — hermetic tests for COMMIT_CONVENTION (HERD-124).
#
# Covers the required scenarios:
#   (1) a non-conforming subject → _herd_commit_convention_scan prints sha+subject; healthcheck
#       exits 1 with a code-error naming the sha, the subject, and the pattern
#   (2) a fully conforming history → scan prints nothing; healthcheck exits 0
#   (3) COMMIT_CONVENTION unset/empty → lint absent, output byte-identical (zero behavior change)
#   (4) an INVALID regex fails soft → a ⚠️ warning, lint skipped, NEVER a false red (exit 0)
#
# Fully hermetic: local temp git repos only. No herdr, no claude, no network.
# Run:  bash tests/test-commit-convention-lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
COMMIT_LINT="$ROOT/scripts/herd/commit-lint.sh"
HC="$ROOT/scripts/herd/healthcheck.sh"

# A permissive Conventional-Commits-style pattern used across the conforming/violating fixtures.
CONV='^(feat|fix|docs|chore|refactor|test)(\(.+\))?: .+'

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

[ -f "$COMMIT_LINT" ] || fail "commit-lint.sh not found at $COMMIT_LINT"
[ -f "$HC" ] || fail "healthcheck.sh not found at $HC"

# Isolate git from any ambient user config so commits succeed deterministically.
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --file "$T/gitconfig" user.email "test@herd.local"
git config --file "$T/gitconfig" user.name  "herd test"
git config --file "$T/gitconfig" init.defaultBranch main
git config --file "$T/gitconfig" commit.gpgsign false

# make_repo <dir> — bare origin + working clone at <dir>/repo with one conforming base commit.
make_repo() {
  local base="$1"
  mkdir -p "$base"
  git init -q --bare "$base/origin.git"
  git clone -q "$base/origin.git" "$base/repo"
  ( cd "$base/repo"
    git checkout -q -b main
    printf 'base\n' > file.txt
    git add file.txt
    git commit -q -m "chore: initial commit"
    git push -q -u origin main )
}

# add_commit <repo_dir> <subject> — create a commit with the given (single-line) subject.
add_commit() {
  local dir="$1" subj="$2"
  ( cd "$dir"
    printf 'change\n' >> file.txt
    git add file.txt
    git commit -q -m "$subj" )
}

# run_conv_scan <repo_dir> <pattern> — source commit-lint.sh and call the convention scanner.
run_conv_scan() {
  local dir="$1" pat="$2"
  ( cd "$dir"
    # shellcheck source=/dev/null
    . "$COMMIT_LINT"
    _herd_commit_convention_scan "origin/main" "$pat" )
}

# run_healthcheck <repo_dir> <commit_convention> — run healthcheck.sh in light mode.
# Prints stdout+stderr combined; exit code propagates.
run_healthcheck() {
  local dir="$1" conv="${2:-}"
  ( cd "$dir"
    export HERD_CONFIG_FILE="$T/no-such-config"
    export PROJECT_ROOT="$dir" WORKTREES_DIR="$T/trees"
    export DEFAULT_BRANCH="origin/main"
    export COMMIT_CONVENTION="$conv"
    bash "$HC" "$dir" --light 2>&1 )
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# 1. Non-conforming subject → scan emits sha+subject; healthcheck code-errors naming sha+subj+pattern
# ══════════════════════════════════════════════════════════════════════════════════════════════════
make_repo "$T/vio"
add_commit "$T/vio/repo" "did some stuff without a type prefix"

# ── 1a. scan prints a violation line for the non-conforming subject ────────────────────────────────
out="$(run_conv_scan "$T/vio/repo" "$CONV")"
[ -n "$out" ] || fail "(1a) scan of non-conforming commit must print a violation; got empty"
echo "$out" | grep -qF "did some stuff without a type prefix" \
  || fail "(1a) violation line must name the offending subject; got: $out"
pass

# ── 1b. violation line includes the commit sha (12-char prefix) ────────────────────────────────────
sha="$(cd "$T/vio/repo" && git log --format="%H" origin/main..HEAD | head -1)"
short="$(printf '%.12s' "$sha")"
echo "$out" | grep -qF "$short" \
  || fail "(1b) violation must name the offending sha ($short); got: $out"
pass

# ── 1c. healthcheck exits 1 and names the sha, the subject, and the pattern ────────────────────────
hc_out="$(run_healthcheck "$T/vio/repo" "$CONV")"; hc_rc=$?
[ "$hc_rc" -eq 1 ] || fail "(1c) healthcheck must exit 1 on non-conforming subject; got rc=$hc_rc"
echo "$hc_out" | grep -qi "commit convention" \
  || fail "(1c) healthcheck output must mention the commit convention lint; got: $hc_out"
echo "$hc_out" | grep -qF "$short" \
  || fail "(1c) healthcheck output must name the offending sha ($short); got: $hc_out"
echo "$hc_out" | grep -qF "did some stuff without a type prefix" \
  || fail "(1c) healthcheck output must name the offending subject; got: $hc_out"
echo "$hc_out" | grep -qF "$CONV" \
  || fail "(1c) healthcheck output must name the pattern; got: $hc_out"
pass

# ── 1d. a conforming commit ALONGSIDE the violation is not flagged (only the bad one) ──────────────
add_commit "$T/vio/repo" "feat(core): add a properly formatted subject"
out2="$(run_conv_scan "$T/vio/repo" "$CONV")"
echo "$out2" | grep -qF "add a properly formatted subject" \
  && fail "(1d) a conforming subject must NOT be flagged; got: $out2"
echo "$out2" | grep -qF "did some stuff without a type prefix" \
  || fail "(1d) the non-conforming subject must still be flagged; got: $out2"
pass

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# 2. Fully conforming history → scan returns empty; healthcheck exits 0
# ═══════════════════════════════════════════════════════════════════════════════════════════════
make_repo "$T/clean"
add_commit "$T/clean/repo" "fix: correct an off-by-one"
add_commit "$T/clean/repo" "docs(readme): clarify the setup steps"

# ── 2a. scan returns empty for an all-conforming range ─────────────────────────────────────────────
clean_out="$(run_conv_scan "$T/clean/repo" "$CONV")"
[ -z "$clean_out" ] || fail "(2a) scan of conforming history must return empty; got: $clean_out"
pass

# ── 2b. healthcheck exits 0 and confirms the lint clean ────────────────────────────────────────────
hc2_out="$(run_healthcheck "$T/clean/repo" "$CONV")"; hc2_rc=$?
[ "$hc2_rc" -eq 0 ] || fail "(2b) healthcheck must exit 0 for conforming history; got rc=$hc2_rc (out: $hc2_out)"
echo "$hc2_out" | grep -qi "commit convention lint clean" \
  || fail "(2b) healthcheck output must confirm the commit convention lint clean; got: $hc2_out"
pass

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# 3. COMMIT_CONVENTION unset/empty → lint absent, output byte-identical (zero behavior change)
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# Reuse a repo with a non-conforming subject — the empty policy must NOT flag it, nor mention the lint.
make_repo "$T/off"
add_commit "$T/off/repo" "totally freeform subject line"

# ── 3a. empty COMMIT_CONVENTION does not flag the non-conforming repo ──────────────────────────────
hc3_out="$(run_healthcheck "$T/off/repo" "")"; hc3_rc=$?
[ "$hc3_rc" -eq 0 ] || fail "(3a) COMMIT_CONVENTION='' must not flag a non-conforming repo; got rc=$hc3_rc"
echo "$hc3_out" | grep -qi "commit convention" \
  && fail "(3a) COMMIT_CONVENTION='' output must not mention the lint; got: $hc3_out"
pass

# ── 3b. UNSET COMMIT_CONVENTION is byte-identical to a run with the lint code absent ──────────────
# Compare the empty-policy output against the same healthcheck with the var unset entirely: identical.
hc3b_out="$(
  cd "$T/off/repo"
  export HERD_CONFIG_FILE="$T/no-such-config"
  export PROJECT_ROOT="$T/off/repo" WORKTREES_DIR="$T/trees"
  export DEFAULT_BRANCH="origin/main"
  unset COMMIT_CONVENTION
  bash "$HC" "$T/off/repo" --light 2>&1
)"; hc3b_rc=$?
[ "$hc3b_rc" -eq 0 ] || fail "(3b) unset COMMIT_CONVENTION must not flag violations; got rc=$hc3b_rc"
[ "$hc3_out" = "$hc3b_out" ] \
  || fail "(3b) empty vs unset COMMIT_CONVENTION output must be identical; empty=[$hc3_out] unset=[$hc3b_out]"
pass

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# 4. Invalid regex → fail-soft: a ⚠️ warning, lint skipped, NEVER a false red (exit 0)
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# An unbalanced group '(feat' is not a valid egrep. The lint must warn and skip — not red the PR,
# and not flag every commit as a violation.
make_repo "$T/bad"
add_commit "$T/bad/repo" "anything at all"
hc4_out="$(run_healthcheck "$T/bad/repo" "(feat")"; hc4_rc=$?
[ "$hc4_rc" -eq 0 ] || fail "(4) invalid regex must fail soft (exit 0), never red; got rc=$hc4_rc (out: $hc4_out)"
echo "$hc4_out" | grep -qi "invalid COMMIT_CONVENTION regex" \
  || fail "(4) invalid regex must surface a warning naming it; got: $hc4_out"
echo "$hc4_out" | grep -qi "commit convention lint clean" \
  && fail "(4) invalid regex must NOT report a clean lint (it was skipped); got: $hc4_out"
pass

echo "ALL PASS ($PASS checks)"
