#!/usr/bin/env bash
# test-fleet-discover.sh — hermetic tests for `herd fleet discover` (auto-registration for the fleet
# coordinator; P0 registry story). Mirrors test-fleet.sh's design:
#   • Fully hermetic: a temp HERD_FLEET_FILE registry, temp fake projects each with their own
#     .herd/config, and a temp $HOME so the default ~/.herd/fleet is never touched.
#   • Deterministic: no network, no gh/pgrep needed (discover is read-mostly + explicit --register).
#
# What it pins down (the task's acceptance list):
#   • discover LISTS the herd projects under a root (2 of them; a non-herd dir is ignored)
#   • it DEDUPS projects already in the registry (marks them `registered`, only fresh ones are `new`)
#   • --register (and its --yes alias) ADD the new projects to the registry
#   • the DRY-RUN default writes NOTHING
#   • default roots (no <root> arg) resolve via HERD_FLEET_DISCOVER_ROOTS and still find projects
#   • a non-directory root / a root with no projects is handled gracefully, never fatal
#
# Run:  bash tests/test-fleet-discover.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0
ok(){ pass=$((pass+1)); }

# Isolate HOME so the default ~/.herd/fleet path is a temp one even if a subcommand ignores the seam.
export HOME="$T/home"; mkdir -p "$HOME"

# Registry seam — start with a fresh (nonexistent) registry.
export HERD_FLEET_FILE="$T/registry/fleet"

# _make_project <name> — a real git repo + .herd/config (no journal needed for discover).
_make_project() {
  local name="$1"
  local root="$T/roots/$name"
  mkdir -p "$root/.herd"
  git -C "$root" init -q
  git -C "$root" config user.email t@t.t
  git -C "$root" config user.name t
  ( cd "$root" && git commit -q --allow-empty -m init && git branch -M "feat/$name" )
  local root_real; root_real="$(cd "$root" && pwd -P)"
  cat > "$root/.herd/config" <<CFG
PROJECT_ROOT="$root_real"
WORKTREES_DIR="$root_real-trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="$name"
HERD_REPO="me/$name"
CFG
  printf '%s' "$root_real"
}

ALPHA="$(_make_project alpha)"
BETA="$(_make_project beta)"
# A non-herd dir under the same root: a plain dir AND a git repo with no .herd/config. Neither must
# be reported as a project.
mkdir -p "$T/roots/plain-dir"
mkdir -p "$T/roots/gamma-norc"; git -C "$T/roots/gamma-norc" init -q
ROOT="$T/roots"

# ── 1. discover LISTS the two herd projects under the root; ignores the non-herd dirs ─────────────
out="$(bash "$HERD" fleet discover "$ROOT")"
printf '%s' "$out" | grep -q "alpha" || fail "discover missed alpha under root"
printf '%s' "$out" | grep -q "beta"  || fail "discover missed beta under root"
if printf '%s' "$out" | grep -q "gamma-norc"; then fail "discover should NOT list a git repo without .herd/config"; fi
printf '%s' "$out" | grep -q "2 project(s) found" || fail "discover count should be 2"
ok

# ── 2. dry-run default writes NOTHING (registry file must not be created) ──────────────────────────
if [ -f "$HERD_FLEET_FILE" ]; then fail "dry-run discover must not create the registry"; fi
ok

# ── 3. everything is `new` when the registry is empty ─────────────────────────────────────────────
printf '%s' "$out" | grep -q "2 new" || fail "with an empty registry both projects should be 'new'"
# Isolate alpha's row (color codes make a positional regex fragile — match the word plainly).
printf '%s' "$out" | grep '^alpha' | grep -q "new" || fail "alpha should be marked new"
ok

# ── 4. --register ADDS the discovered projects to the registry ────────────────────────────────────
bash "$HERD" fleet discover --register "$ROOT" >/dev/null
[ -f "$HERD_FLEET_FILE" ] || fail "--register should create the registry"
grep -q "^alpha|" "$HERD_FLEET_FILE" || fail "--register did not add alpha"
grep -q "^beta|"  "$HERD_FLEET_FILE" || fail "--register did not add beta"
na="$(grep -c "^alpha|" "$HERD_FLEET_FILE" || true)"
[ "$na" = "1" ] || fail "alpha should appear exactly once ($na rows)"
ok

# ── 5. DEDUP: re-running discover marks the now-registered projects, none are 'new' ───────────────
out="$(bash "$HERD" fleet discover "$ROOT")"
printf '%s' "$out" | grep -q "2 project(s) found" || fail "re-discover should still find 2 projects"
printf '%s' "$out" | grep -q "0 new" || fail "already-registered projects should not be counted as new"
printf '%s' "$out" | grep -q "2 already registered" || fail "both projects should be marked already registered"
printf '%s' "$out" | grep '^alpha' | grep -q "registered" || fail "alpha should show status 'registered'"
ok

# ── 6. DEDUP is per-project: a fresh project mixed with registered ones is the only 'new' one ─────
DELTA="$(_make_project delta)"
out="$(bash "$HERD" fleet discover "$ROOT")"
printf '%s' "$out" | grep -q "3 project(s) found" || fail "discover should now find 3 projects"
printf '%s' "$out" | grep -q "1 new" || fail "only the fresh project (delta) should be new"
printf '%s' "$out" | grep -q "2 already registered" || fail "alpha+beta should stay deduped"
# --register only adds the new one; it must not duplicate the already-registered rows.
bash "$HERD" fleet discover --register "$ROOT" >/dev/null
grep -q "^delta|" "$HERD_FLEET_FILE" || fail "--register did not add the new project delta"
[ "$(grep -c "^alpha|" "$HERD_FLEET_FILE")" = "1" ] || fail "alpha row duplicated by re-register"
ok

# ── 7. the --yes alias behaves like --register ────────────────────────────────────────────────────
EPS="$(_make_project epsilon)"
out2="$(HERD_FLEET_FILE="$T/reg-yes/fleet" bash "$HERD" fleet discover --yes "$ROOT")"
grep -q "^epsilon|" "$T/reg-yes/fleet" || fail "--yes should register discovered projects"
grep -q "^alpha|"   "$T/reg-yes/fleet" || fail "--yes should register alpha into the fresh registry"
ok

# ── 8. DEFAULT ROOTS: a bare `discover` (no <root>) uses HERD_FLEET_DISCOVER_ROOTS ────────────────
out="$(HERD_FLEET_FILE="$T/reg-default/fleet" HERD_FLEET_DISCOVER_ROOTS="$ROOT" \
        bash "$HERD" fleet discover)"
printf '%s' "$out" | grep -q "alpha" || fail "default-roots discover missed alpha"
printf '%s' "$out" | grep -q "beta"  || fail "default-roots discover missed beta"
ok

# ── 9. a non-directory root is handled gracefully (warn, not fatal) ───────────────────────────────
set +e
out="$(bash "$HERD" fleet discover "$T/does-not-exist" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "a missing root should not be fatal (rc=$rc)"
printf '%s' "$out" | grep -qi "not a directory\|skipping" || fail "a missing root should warn"
ok

# ── 10. a root with NO herd projects reports a friendly note, not a crash ─────────────────────────
mkdir -p "$T/empty-root"
out="$(bash "$HERD" fleet discover "$T/empty-root")"
printf '%s' "$out" | grep -qi "no herd projects found" || fail "an empty root should report none found"
ok

echo "ALL PASS ($pass checks)"
