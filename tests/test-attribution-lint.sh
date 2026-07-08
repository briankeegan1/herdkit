#!/usr/bin/env bash
# test-attribution-lint.sh — hermetic tests for ATTRIBUTION_POLICY=no-ai-coauthor (HERD-121).
#
# Covers the three required scenarios:
#   (1) violating trailer  → _herd_attr_scan prints sha+line; healthcheck exits 1
#   (2) clean history      → _herd_attr_scan prints nothing; healthcheck exits 0
#   (3) ATTRIBUTION_POLICY unset → zero output (lint absent, byte-identical path)
#
# Fully hermetic: local temp git repos only. No herdr, no claude, no network.
# Run:  bash tests/test-attribution-lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
COMMIT_LINT="$ROOT/scripts/herd/commit-lint.sh"
HC="$ROOT/scripts/herd/healthcheck.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# Verify required files exist.
[ -f "$COMMIT_LINT" ] || fail "commit-lint.sh not found at $COMMIT_LINT"
[ -f "$HC" ] || fail "healthcheck.sh not found at $HC"

# Isolate git from any ambient user config so commits succeed deterministically.
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --file "$T/gitconfig" user.email "test@herd.local"
git config --file "$T/gitconfig" user.name  "herd test"
git config --file "$T/gitconfig" init.defaultBranch main
git config --file "$T/gitconfig" commit.gpgsign false

# make_repo <dir> — create a bare origin + working clone at <dir>/repo with one base commit on main.
make_repo() {
  local base="$1"
  mkdir -p "$base"
  git init -q --bare "$base/origin.git"
  git clone -q "$base/origin.git" "$base/repo"
  ( cd "$base/repo"
    git checkout -q -b main
    printf 'base\n' > file.txt
    git add file.txt
    git commit -q -m "initial commit"
    git push -q -u origin main )
}

# add_commit <repo_dir> <message> — create a commit with the given multi-line message.
# The message is passed verbatim as the commit body; use a file to avoid shell escaping issues.
add_commit() {
  local dir="$1" msg="$2"
  ( cd "$dir"
    printf '%s' "$msg" > .git/COMMIT_EDITMSG_TMP
    printf 'change\n' >> file.txt
    git add file.txt
    git commit -q -F .git/COMMIT_EDITMSG_TMP )
}

# run_attr_scan <repo_dir> — source commit-lint.sh and call _herd_attr_scan in <repo_dir>.
# Prints the raw violations output.
run_attr_scan() {
  local dir="$1"
  ( cd "$dir"
    # shellcheck source=/dev/null
    . "$COMMIT_LINT"
    _herd_attr_scan "origin/main" )
}

# run_healthcheck <repo_dir> [attribution_policy] — run healthcheck.sh in <repo_dir> in light mode.
# Returns the exit code via a temp file and prints stdout+stderr combined.
run_healthcheck() {
  local dir="$1" policy="${2:-}"
  ( cd "$dir"
    export HERD_CONFIG_FILE="$T/no-such-config"
    export PROJECT_ROOT="$dir" WORKTREES_DIR="$T/trees"
    export DEFAULT_BRANCH="origin/main"
    export ATTRIBUTION_POLICY="$policy"
    bash "$HC" "$dir" --light 2>&1 )
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# 1. Violating trailer → _herd_attr_scan emits sha+line; healthcheck exits 1
# ══════════════════════════════════════════════════════════════════════════════════════════════════
make_repo "$T/vio"
add_commit "$T/vio/repo" "fix: do the thing

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"

# ── 1a. _herd_attr_scan prints a violation line ──────────────────────────────────────────────────
out="$(run_attr_scan "$T/vio/repo")"
[ -n "$out" ] || fail "(1a) scan of violating commit must print violations; got empty output"
echo "$out" | grep -qi "co-authored-by: claude" \
  || fail "(1a) violation line must name the offending trailer; got: $out"
pass

# ── 1b. violation line includes the commit sha (12-char prefix) ──────────────────────────────────
sha="$(cd "$T/vio/repo" && git log --format="%H" origin/main..HEAD | head -1)"
short="$(printf '%.12s' "$sha")"
echo "$out" | grep -qF "$short" \
  || fail "(1b) violation must name the offending sha ($short); got: $out"
pass

# ── 1c. healthcheck exits 1 and output names the sha ────────────────────────────────────────────
hc_out="$(run_healthcheck "$T/vio/repo" "no-ai-coauthor")" ; hc_rc=$?
[ "$hc_rc" -eq 1 ] || fail "(1c) healthcheck must exit 1 on violating trailer; got rc=$hc_rc"
echo "$hc_out" | grep -qi "attribution" \
  || fail "(1c) healthcheck output must mention attribution lint; got: $hc_out"
echo "$hc_out" | grep -qF "$short" \
  || fail "(1c) healthcheck output must name the offending sha ($short); got: $hc_out"
pass

# ── 1d. 'Generated with Claude' footer also triggers the lint ────────────────────────────────────
make_repo "$T/gen"
add_commit "$T/gen/repo" "feat: add thing

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

gen_out="$(run_attr_scan "$T/gen/repo")"
[ -n "$gen_out" ] || fail "(1d) 'Generated with Claude' footer must trigger violation; got empty"
echo "$gen_out" | grep -qi "generated with" \
  || fail "(1d) violation line must include the 'Generated with' trailer; got: $gen_out"
pass

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# 2. Clean history → _herd_attr_scan returns empty; healthcheck exits 0
# ═══════════════════════════════════════════════════════════════════════════════════════════════
make_repo "$T/clean"
add_commit "$T/clean/repo" "fix: a normal commit with no AI attribution"

# ── 2a. _herd_attr_scan returns empty ────────────────────────────────────────────────────────────
clean_out="$(run_attr_scan "$T/clean/repo")"
[ -z "$clean_out" ] || fail "(2a) scan of clean commit must return empty; got: $clean_out"
pass

# ── 2b. healthcheck exits 0 for clean history ────────────────────────────────────────────────────
hc2_out="$(run_healthcheck "$T/clean/repo" "no-ai-coauthor")"; hc2_rc=$?
[ "$hc2_rc" -eq 0 ] || fail "(2b) healthcheck must exit 0 for clean history; got rc=$hc2_rc (output: $hc2_out)"
echo "$hc2_out" | grep -qi "attribution lint clean" \
  || fail "(2b) healthcheck output must confirm attribution lint clean; got: $hc2_out"
pass

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# 3. ATTRIBUTION_POLICY unset → lint absent, output byte-identical (zero behavior change)
# ══════════════════════════════════════════════════════════════════════════════════════════════════

# Reuse the violating repo — policy unset must NOT flag it.
make_repo "$T/off"
add_commit "$T/off/repo" "fix: do the thing

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"

# ── 3a. healthcheck exits 0 (no lint) when ATTRIBUTION_POLICY="" ────────────────────────────────
hc3_out="$(run_healthcheck "$T/off/repo" "")"; hc3_rc=$?
[ "$hc3_rc" -eq 0 ] || fail "(3a) ATTRIBUTION_POLICY='' must not flag the violating repo; got rc=$hc3_rc"
pass

# ── 3b. output contains no attribution mentions when policy is off ───────────────────────────────
echo "$hc3_out" | grep -qi "attribution" \
  && fail "(3b) ATTRIBUTION_POLICY='' output must not mention attribution; got: $hc3_out"
pass

# ── 3c. ATTRIBUTION_POLICY unset is also a no-op ────────────────────────────────────────────────
hc4_out="$(
  cd "$T/off/repo"
  export HERD_CONFIG_FILE="$T/no-such-config"
  export PROJECT_ROOT="$T/off/repo" WORKTREES_DIR="$T/trees"
  export DEFAULT_BRANCH="origin/main"
  unset ATTRIBUTION_POLICY
  bash "$HC" "$T/off/repo" --light 2>&1
)"; hc4_rc=$?
[ "$hc4_rc" -eq 0 ] || fail "(3c) unset ATTRIBUTION_POLICY must not flag violations; got rc=$hc4_rc"
echo "$hc4_out" | grep -qi "attribution" \
  && fail "(3c) unset ATTRIBUTION_POLICY output must not mention attribution; got: $hc4_out"
pass

echo "ALL PASS ($PASS checks)"
