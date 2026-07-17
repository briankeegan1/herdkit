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

# ── 7. --write onto a PRE-EXISTING, UNTERMINATED .herd/links never glues onto the last row ────────
# .herd/links predates this command as a writer — a hand-authored (or templates/links.example-
# copied) file with no trailing newline on its last line is ordinary operator state, not exotic.
ZETA="$(_make_project zeta)"
GAMMA="$(_make_project gamma)"
bash "$HERD" fleet register "$ZETA"  >/dev/null
bash "$HERD" fleet register "$GAMMA" >/dev/null
printf 'upstream|vendor/sdk|linear|ENG-7' > "$ZETA/.herd/links"   # deliberately NO trailing newline
out7="$(run_from "$ZETA" link --scan --write 2>&1)" || fail "link --scan --write onto unterminated file exited non-zero: $out7"
grep -qxF 'upstream|vendor/sdk|linear|ENG-7' "$ZETA/.herd/links" \
  || fail "the pre-existing unterminated row was corrupted — file: $(cat "$ZETA/.herd/links")"
grep -qxF 'gamma|acme/gamma|github|' "$ZETA/.herd/links" \
  || fail "the new row was glued onto the pre-existing line instead of appended cleanly — file: $(cat "$ZETA/.herd/links")"
n7="$(wc -l < "$ZETA/.herd/links" | tr -d ' ')"
[ "$n7" -ge 2 ] || fail "expected at least 2 distinct lines after --write, got $n7 — file: $(cat "$ZETA/.herd/links")"
outlist7="$(run_from "$ZETA" link list 2>&1)" || fail "link list after unterminated-file --write exited non-zero: $outlist7"
echo "$outlist7" | grep -q "vendor/sdk" || fail "link list lost the pre-existing 'upstream' row — got: $outlist7"
echo "$outlist7" | grep -q "acme/gamma" || fail "link list lost the newly-scanned 'gamma' row — got: $outlist7"
pass

# ── 8. cross-proposal collision: two registry rows proposing the SAME name dedup against each ─────
#    other within one scan (only the first is written; the second never silently shadows it).
DUP1="$(_make_project dup1)"; sed -i.bak 's/WORKSPACE_NAME="dup1"/WORKSPACE_NAME="dup"/' "$DUP1/.herd/config"
DUP2="$(_make_project dup2)"; sed -i.bak 's/WORKSPACE_NAME="dup2"/WORKSPACE_NAME="dup"/' "$DUP2/.herd/config"
rm -f "$DUP1/.herd/config.bak" "$DUP2/.herd/config.bak"
git -C "$DUP1" remote set-url origin "git@github.com:acme/dup1.git"
git -C "$DUP2" remote set-url origin "git@github.com:acme/dup2.git"
REG8="$T/registry8/fleet"
HERD_FLEET_FILE="$REG8" bash "$HERD" fleet register "$DUP1" >/dev/null
HERD_FLEET_FILE="$REG8" bash "$HERD" fleet register "$DUP2" >/dev/null
ETA="$(_make_project eta)"
out8="$( cd "$ETA" && HERD_CONFIG_FILE="$ETA/.herd/config" HERD_NONINTERACTIVE=1 \
           HERD_FLEET_FILE="$REG8" bash "$HERD" link --scan --write 2>&1 )" \
  || fail "link --scan --write (collision case) exited non-zero: $out8"
n8="$(grep -c '^dup|' "$ETA/.herd/links" || true)"
[ "$n8" = "1" ] || fail "colliding 'dup' entries both got written ($n8 rows) — file: $(cat "$ETA/.herd/links")"
pass

# ── 9. self-link guard must survive a LOGICAL (symlinked) PROJECT_ROOT ────────────────────────────
# `herd init` writes PROJECT_ROOT verbatim from a plain `pwd` prompt (logical, not `pwd -P`), so a
# project reached through a symlink is the ORDINARY case, not exotic. Force a real symlink layer
# (independent of whether the test's own tmpdir happens to be symlinked) so this reproduces anywhere.
T_REAL="$(cd "$T" && pwd -P)"
mkdir -p "$T_REAL/reallinkproj/.herd" "$T_REAL/alias"
git -C "$T_REAL/reallinkproj" init -q
git -C "$T_REAL/reallinkproj" config user.email t@t.t
git -C "$T_REAL/reallinkproj" config user.name t
( cd "$T_REAL/reallinkproj" && git commit -q --allow-empty -m init )
git -C "$T_REAL/reallinkproj" remote add origin "git@github.com:acme/linkproj.git"
ln -s "$T_REAL/reallinkproj" "$T_REAL/alias/linkproj"
LINKPROJ="$T_REAL/alias/linkproj"                          # the LOGICAL (symlinked) spelling
cat > "$T_REAL/reallinkproj/.herd/config" <<CFG
PROJECT_ROOT="$LINKPROJ"
WORKSPACE_NAME="linkproj"
HERD_REPO="me/linkproj"
CFG
REG9="$T/registry9/fleet"
HERD_FLEET_FILE="$REG9" bash "$HERD" fleet register "$LINKPROJ" >/dev/null
grep -q "^linkproj|$LINKPROJ|acme/linkproj$" "$REG9" \
  || fail "registry did not record the logical PROJECT_ROOT spelling verbatim — file: $(cat "$REG9")"
out9="$( cd "$LINKPROJ" && HERD_CONFIG_FILE="$LINKPROJ/.herd/config" HERD_NONINTERACTIVE=1 \
           HERD_FLEET_FILE="$REG9" bash "$HERD" link --scan 2>&1 )" \
  || fail "link --scan (logical-root self case) exited non-zero: $out9"
echo "$out9" | grep -qi "no new" \
  || fail "logical PROJECT_ROOT defeated the self-link guard — scan proposed a self-link: $out9"
pass

# ── 10. peer backend: .herd/config.local overlay wins over the base config, and a blank ──────────
#     linear/jira tracker_target is flagged in the dry-run output.
IOTA="$(_make_project iota)"
printf 'SCRIBE_BACKEND="file"\n' >> "$IOTA/.herd/config"        # base config: file
printf 'SCRIBE_BACKEND="linear"\n' > "$IOTA/.herd/config.local"  # overlay: linear (must win)
REG10="$T/registry10/fleet"
HERD_FLEET_FILE="$REG10" bash "$HERD" fleet register "$IOTA" >/dev/null
KAPPA="$(_make_project kappa)"
out10="$( cd "$KAPPA" && HERD_CONFIG_FILE="$KAPPA/.herd/config" HERD_NONINTERACTIVE=1 \
            HERD_FLEET_FILE="$REG10" bash "$HERD" link --scan 2>&1 )" \
  || fail "link --scan (config.local overlay case) exited non-zero: $out10"
echo "$out10" | grep -qE '\+\s+iota\s+acme/iota\s+\[linear\]' \
  || fail "config.local's SCRIBE_BACKEND=linear did not win over the base config's 'file' — got: $out10"
echo "$out10" | grep -qi "no tracker_target" || fail "dry-run did not flag the blank linear tracker_target — got: $out10"
echo "$out10" | grep -q "iota" || fail "tracker_target warning did not name 'iota' — got: $out10"
pass

echo "ALL PASS ($PASS checks)"
