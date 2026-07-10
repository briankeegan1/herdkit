#!/usr/bin/env bash
# test-healthcheck-lint-tree-under-test.sh — HERD-309: lint scripts must be sourced from the TREE
# UNDER TEST ($DIR/scripts/herd/) when present, falling back to the engine copy.
#
# Covers:
#   (1) WORKTREE caps-sync-lint: when the tree has its own caps-sync-lint.sh, healthcheck sources
#       it instead of the engine's copy — proven by a unique sentinel in the output.
#   (2) ENGINE fallback for caps-sync-lint: a worktree without scripts/herd/caps-sync-lint.sh
#       falls back to the engine's copy (skip, exit 0 — no sentinel).
#   (3) WORKTREE doc-drift-lint: same pattern, tree-under-test version runs → its sentinel appears.
#   (4) WORKTREE gate-coverage-lint: tree-under-test version runs → its sentinel appears.
#
# Each custom lint file is seeded on the worktree's `main` branch so it is PRESENT ON DISK when
# feat/x is checked out but NOT in the diff (no new lane script) — this isolates each test from
# the caps-sync guard's new-lane-script detection.
#
# Network-free: temp git repos + HERD_CONFIG_FILE. No HEALTHCHECK_CMD → --light profile.
# Run:  bash tests/test-healthcheck-lint-tree-under-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HC="$ROOT/scripts/herd/healthcheck.sh"
[ -f "$HC" ] || { echo "healthcheck.sh not found at $HC" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

WT="$T/wt"
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
cat > "$CFG" <<CFGEOF
PROJECT_ROOT="$WT"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="main"
WORKSPACE_NAME="ctest"
CFGEOF

git_wt() { git -C "$WT" "$@"; }
run_hc()  { bash "$HC" "$WT" --light "$@"; }

# reset_wt: wipe and recreate the worktree with an empty scripts/herd/ on `main`.
reset_wt() {
  rm -rf "$WT"; mkdir -p "$WT/scripts/herd"
  git_wt init -q
  git_wt checkout -q -b main 2>/dev/null || git_wt checkout -q main
  git_wt config user.email t@t.test
  git_wt config user.name  herd-test
}

# seed_then_change: commit whatever is in the worktree as the main seed, check out feat/x, then
# add an innocent file so there is a non-empty diff against main.
seed_then_change() {
  git_wt add -A; git_wt commit -qm seed
  git_wt checkout -q -b feat/x
  printf 'hello\n' > "$WT/hello.txt"
  git_wt add -A; git_wt commit -qm change
}

# ── (1) WORKTREE caps-sync-lint runs when present ────────────────────────────────────────────────
# Custom caps-sync-lint.sh seeded on main (not a new lane script in the diff). The engine's copy
# would skip (return 2: no templates/capabilities.tsv). The worktree's copy returns 1 + sentinel,
# proving the tree-under-test's version was sourced, not the engine's.
CS_SENTINEL="HERD309-CAPS-SYNC-SENTINEL"
reset_wt
cat > "$WT/scripts/herd/caps-sync-lint.sh" <<LINT
#!/usr/bin/env bash
HERD_CAPS_SYNC_SKIP_REASON=""
herd_caps_sync_lint() { printf '%s\n' "$CS_SENTINEL"; return 1; }
LINT
seed_then_change
out="$(run_hc 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "(1) worktree caps-sync-lint must exit 1 (got $rc): $out"
printf '%s\n' "$out" | grep -qF "$CS_SENTINEL" \
  || fail "(1) worktree sentinel must appear in output (got: $out)"
ok

# ── (2) ENGINE fallback when worktree has no caps-sync-lint ──────────────────────────────────────
# No scripts/herd/caps-sync-lint.sh on disk → healthcheck uses the engine's copy, which skips
# (return 2: no capabilities.tsv) → exit 0; sentinel absent.
reset_wt
seed_then_change
out="$(run_hc 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  || fail "(2) engine fallback: no caps-sync-lint in tree, expected exit 0 (got $rc): $out"
printf '%s\n' "$out" | grep -qF "$CS_SENTINEL" \
  && fail "(2) sentinel must NOT appear when falling back to engine (got: $out)"
ok

# ── (3) WORKTREE doc-drift-lint runs when present ────────────────────────────────────────────────
# Engine's doc-drift would skip (return 2: no capabilities.tsv). Worktree's returns 1 + sentinel.
DD_SENTINEL="HERD309-DOC-DRIFT-SENTINEL"
reset_wt
cat > "$WT/scripts/herd/doc-drift-lint.sh" <<LINT
#!/usr/bin/env bash
HERD_DOC_DRIFT_SKIP_REASON=""
herd_doc_drift_lint() { printf '%s\n' "$DD_SENTINEL"; return 1; }
LINT
seed_then_change
out="$(run_hc 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "(3) worktree doc-drift-lint must exit 1 (got $rc): $out"
printf '%s\n' "$out" | grep -qF "$DD_SENTINEL" \
  || fail "(3) doc-drift sentinel must appear in output (got: $out)"
ok

# ── (4) WORKTREE gate-coverage-lint runs when present ────────────────────────────────────────────
# Engine's gate-coverage would skip (return 2: no tests/herd.bats). Worktree's returns 1 + sentinel.
GC_SENTINEL="HERD309-GATE-COVERAGE-SENTINEL"
reset_wt
cat > "$WT/scripts/herd/gate-coverage-lint.sh" <<LINT
#!/usr/bin/env bash
HERD_GATE_COVERAGE_SKIP_REASON=""
herd_gate_coverage_lint() { printf '%s\n' "$GC_SENTINEL"; return 1; }
LINT
seed_then_change
out="$(run_hc 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "(4) worktree gate-coverage-lint must exit 1 (got $rc): $out"
printf '%s\n' "$out" | grep -qF "$GC_SENTINEL" \
  || fail "(4) gate-coverage sentinel must appear in output (got: $out)"
ok

echo
echo "ALL PASS ($pass checks) — lint scripts are sourced from the tree under test when present, engine fallback when absent."
