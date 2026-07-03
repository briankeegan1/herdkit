#!/usr/bin/env bash
# scripts/herd/sim/sandbox-fixture.sh — deterministic LOCAL sandbox-consumer fixture generator (P0).
#
# Builds a throwaway LOCAL git repo (in a tmp dir the caller chooses) that looks like a real herd
# consumer: a tiny real app + a seeded BACKLOG.md + a minimal .herd/config. The build is fully
# DETERMINISTIC — fixed file contents plus a pinned git identity/date, so every run produces a repo
# with an IDENTICAL HEAD commit sha. That determinism is the whole point: a scenario runner (or a
# hermetic test) can reset to a byte-identical starting state each run and assert against a known sha.
#
# P0 SCOPE (deliberately local-only — see scripts/herd/sim/README-sandbox-sim.md):
#   • Builds a LOCAL repo only. It does NOT create a hosted GitHub repo.  [TODO(P1): herdkit-sandbox]
#   • It does NOT spin any herdr panes/tabs/workspaces.                    [TODO(P1): real control room]
#   • No model call, no network. Reuses the conventions of the shipped
#     cross-repo loop sim (scripts/herd/sim/cross-repo-loop-sim.sh).
#
# Usage (standalone):   bash scripts/herd/sim/sandbox-fixture.sh <target-dir>
#                       → wipes+rebuilds <target-dir>, prints the deterministic HEAD sha.
# Usage (sourced):      . scripts/herd/sim/sandbox-fixture.sh ; sandbox_fixture_build <target-dir>
#
# Reuse note: mirrors cross-repo-loop-sim.sh's throwaway-git + no-network conventions.
set -uo pipefail

# ── Pinned identity so the fixture's commit sha is reproducible across runs ─────────────────────
# A commit sha is a hash of (tree, parents, author, committer, message). Pin every non-tree input
# and keep file contents fixed → the sha is stable. This is what makes "identical starting state"
# assertable by sha rather than by a fuzzy content walk.
_sf_git_env() {
  export GIT_AUTHOR_NAME="herd-sim"      GIT_AUTHOR_EMAIL="sim@herd.local"
  export GIT_COMMITTER_NAME="herd-sim"   GIT_COMMITTER_EMAIL="sim@herd.local"
  export GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000"
  export GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000"
}

# sandbox_fixture_files <repo> — write the (fixed) fixture tree into <repo>. No git. Idempotent.
# The tiny "real app" is a one-function greeter with its own test; the test IS the gate target the
# scenario runner exercises. BACKLOG.md is seeded in herdkit's status-emoji format.
sandbox_fixture_files() {
  local repo="$1"
  mkdir -p "$repo/app" "$repo/.herd"

  # app/greet.sh — the app's one real function (+ a main guard so it runs standalone).
  cat > "$repo/app/greet.sh" <<'APP'
#!/usr/bin/env bash
# greet.sh — the sandbox app's one real function.
greet() { printf 'hello, %s!\n' "${1:-world}"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then greet "$@"; fi
APP

  # app/greet.test.sh — the health-gate target. Exit 0 = clean, 1 = broken (the scenario's gate).
  cat > "$repo/app/greet.test.sh" <<'TEST'
#!/usr/bin/env bash
# greet.test.sh — the sandbox app's gate. Sources greet.sh and asserts its output.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/greet.sh"
out="$(greet herd)"
[ "$out" = "hello, herd!" ] || { echo "greet.test FAIL: got '$out'"; exit 1; }
echo "greet.test PASS"
TEST

  # BACKLOG.md — seeded in herdkit's 🔜 status-emoji format. The stub builder "implements" item 1.
  cat > "$repo/BACKLOG.md" <<'BACKLOG'
# Sandbox BACKLOG

Seeded backlog for the local workflow-simulation fixture. Deterministic — do not hand-edit.

- 🔜 **Add a farewell command** — the app can greet but cannot say goodbye.
- 🔜 **Reject empty names loudly** — greet("") should be a loud error, not a silent default.
BACKLOG

  # .herd/config — a minimal, zero-secret consumer config so the fixture reads as a real herd repo.
  # SANDBOX_GATE_CMD is the fixture-local gate the scenario runner invokes.
  # [TODO(P1)]: the P1 rig points a real herdr 'sandbox' workspace at this repo.
  cat > "$repo/.herd/config" <<'CFG'
# .herd/config — sandbox-sim fixture (throwaway; zero-secret; deterministically generated).
HERD_VERSION=1
WORKSPACE_NAME="sandbox"
DEFAULT_BRANCH="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
SANDBOX_GATE_CMD="app/greet.test.sh"
CFG

  chmod +x "$repo/app/greet.sh" "$repo/app/greet.test.sh"
}

# sandbox_fixture_build <target-dir> — wipe <target-dir> and rebuild the fixture as a committed git
# repo on 'main'. Prints the deterministic HEAD sha on success. Resettable: safe to call repeatedly;
# each call reproduces a byte-identical repo (same files, same commit sha).
sandbox_fixture_build() {
  local target="$1"
  [ -n "$target" ] || { echo "sandbox_fixture_build: target dir required" >&2; return 1; }
  # Refuse to clobber anything that isn't ours: only ever wipe a path we created (has our marker) or
  # a non-existent/empty path. This keeps a fat-fingered target from nuking a real tree.
  if [ -e "$target" ] && [ ! -e "$target/.herd/.sandbox-sim-fixture" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
    echo "sandbox_fixture_build: refusing to wipe non-fixture dir: $target" >&2
    return 1
  fi
  rm -rf "$target"
  mkdir -p "$target"

  _sf_git_env
  git init -q "$target"
  git -C "$target" symbolic-ref HEAD refs/heads/main
  # Local, hermetic identity/config (does not touch the user's global git config).
  git -C "$target" config user.name  "herd-sim"
  git -C "$target" config user.email "sim@herd.local"
  git -C "$target" config commit.gpgsign false

  sandbox_fixture_files "$target"
  : > "$target/.herd/.sandbox-sim-fixture"   # ownership marker (also proves a stable extra file)

  git -C "$target" add -A
  git -C "$target" commit -q -m "seed: sandbox consumer fixture" \
    || { echo "sandbox_fixture_build: commit failed" >&2; return 1; }

  git -C "$target" rev-parse HEAD
}

# ── standalone entrypoint ───────────────────────────────────────────────────────
# Only runs when executed directly (not when sourced by the scenario runner or a test).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  target="${1:-}"
  [ -n "$target" ] || { echo "usage: sandbox-fixture.sh <target-dir>" >&2; exit 1; }
  sha="$(sandbox_fixture_build "$target")" || exit 1
  printf 'sandbox fixture built: %s\n' "$target"
  printf 'HEAD: %s\n' "$sha"
fi
