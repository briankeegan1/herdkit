#!/usr/bin/env bash
# test-cli-link-scan.sh — hermetic tests for `herd link --scan` (HERD-384): proposing candidate
# peer links from the fleet registry into .herd/links, dry-run by default, --write to apply.
#
# Design mirrors test-fleet.sh: a temp HERD_FLEET_FILE registry + two real-git fixture projects,
# each with their own origin remote (repo identity is resolved fresh from the remote, not a stale
# registry field — same discipline `herd fleet register` already proves).
#
# Run:  bash tests/test-cli-link-scan.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

export HOME="$T/home"; mkdir -p "$HOME"
export HERD_FLEET_FILE="$T/registry/fleet"

# _make_project <name> — real git repo + .herd/config with WORKSPACE_NAME + its own origin remote.
_make_project() {
  local name="$1"
  local root="$T/proj/$name"
  mkdir -p "$root/.herd"
  git -C "$root" init -q
  git -C "$root" config user.email t@t.t
  git -C "$root" config user.name t
  ( cd "$root" && git commit -q --allow-empty -m init )
  git -C "$root" remote add origin "git@github.com:acme/$name.git"
  local root_real; root_real="$(cd "$root" && pwd -P)"
  cat > "$root/.herd/config" <<CFG
PROJECT_ROOT="$root_real"
WORKSPACE_NAME="$name"
HERD_REPO="me/$name"
CFG
  printf '%s' "$root_real"
}

ALPHA="$(_make_project alpha)"
BETA="$(_make_project beta)"

bash "$HERD" fleet register "$ALPHA" >/dev/null
bash "$HERD" fleet register "$BETA"  >/dev/null

run_from() {
  local dir="$1"; shift
  ( cd "$dir" && HERD_CONFIG_FILE="$dir/.herd/config" HERD_NONINTERACTIVE=1 bash "$HERD" "$@" )
}

# ── 1. from alpha, dry-run scan proposes beta (not itself) ───────────────────────────────────────
out1="$(run_from "$ALPHA" link --scan 2>&1)" || fail "link --scan (alpha) exited non-zero: $out1"
echo "$out1" | grep -q "beta" || fail "alpha's scan did not propose beta — got: $out1"
echo "$out1" | grep -q "acme/beta" || fail "alpha's scan did not resolve beta's repo — got: $out1"
echo "$out1" | grep -qE '^\s*\+\s+alpha\s' && fail "alpha's scan proposed itself — got: $out1"
[ ! -f "$ALPHA/.herd/links" ] || fail "dry-run scan wrote $ALPHA/.herd/links"
pass

# ── 2. from beta, dry-run scan proposes alpha (both directions) ──────────────────────────────────
out2="$(run_from "$BETA" link --scan 2>&1)" || fail "link --scan (beta) exited non-zero: $out2"
echo "$out2" | grep -q "alpha" || fail "beta's scan did not propose alpha — got: $out2"
echo "$out2" | grep -q "acme/alpha" || fail "beta's scan did not resolve alpha's repo — got: $out2"
pass

# ── 3. --write applies the proposal to .herd/links ───────────────────────────────────────────────
out3="$(run_from "$ALPHA" link --scan --write 2>&1)" || fail "link --scan --write (alpha) exited non-zero: $out3"
[ -f "$ALPHA/.herd/links" ] || fail "--write did not create $ALPHA/.herd/links"
grep -q "^beta|acme/beta|github|$" "$ALPHA/.herd/links" \
  || fail "--write did not add a beta|acme/beta|github| row — got: $(cat "$ALPHA/.herd/links")"
pass

# ── 4. herd link list now shows the newly-written peer ───────────────────────────────────────────
out4="$(run_from "$ALPHA" link list 2>&1)" || fail "link list (alpha) exited non-zero: $out4"
echo "$out4" | grep -q "acme/beta" || fail "link list did not show the scanned-in beta link — got: $out4"
pass

# ── 5. --write is idempotent: a second run adds nothing new ──────────────────────────────────────
out5="$(run_from "$ALPHA" link --scan --write 2>&1)" || fail "second link --scan --write exited non-zero: $out5"
n="$(grep -c "^beta|" "$ALPHA/.herd/links" || true)"
[ "$n" = "1" ] || fail "second --write duplicated the beta row ($n rows) — file: $(cat "$ALPHA/.herd/links")"
echo "$out5" | grep -qi "no new" || fail "second --write did not report a no-op — got: $out5"
pass

# ── 6. fail-soft: no fleet registry at all → soft note, exit 0 ───────────────────────────────────
NOREG="$T/noreg/fleet"
out6="$( ( cd "$ALPHA" && HERD_CONFIG_FILE="$ALPHA/.herd/config" HERD_NONINTERACTIVE=1 \
             HERD_FLEET_FILE="$NOREG" bash "$HERD" link --scan 2>&1 ) )" \
  || fail "link --scan with no registry should exit 0 — got: $out6"
echo "$out6" | grep -qi "no fleet registry" || fail "missing-registry case did not soft-note — got: $out6"
pass

echo "ALL PASS ($PASS checks)"
