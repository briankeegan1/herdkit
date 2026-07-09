#!/usr/bin/env bash
# test-derived-skill.sh — hermetic proof that the rendered coordinator skill is a PER-MACHINE,
# REGENERABLE DERIVED FILE and never a tracked one (HERD-214).
#
# The render (`.claude/commands/<COORDINATOR_CMD>.md`) is rewritten from templates/coordinator.md.tmpl
# + .herd/config by init / update / reload / render / a render-affecting `config set`. While it was
# tracked, each of those dirtied whatever checkout it ran in — and the dirt then made the sweep flag
# worktrees it should have reaped, the watcher's startup reap skip stranded trees as "dirty", the
# stale-base gate hold PRs on a bogus overlap, and the ff-only `herd update` pull refuse.
#
# What this asserts:
#   (A) EVERY render path renders when the file is ABSENT, and leaves the git tree CLEAN:
#       herd init → clean; delete + herd render → regenerated, clean; delete + herd upgrade →
#       regenerated, clean. The ignore line is written once and is idempotent.
#   (B) MIGRATION — a project that still TRACKS the render is untracked by `herd upgrade`: no tracked
#       copy survives, the file on disk is untouched, and the deletion is staged for the operator.
#   (C) The shared derived-files list (scripts/herd/derived-files.sh) follows COORDINATOR_CMD, and its
#       strip filter drops derived paths while preserving real ones.
#   (D) SWEEP EXEMPTION — a worktree whose ONLY dirt is the derived render (tracked + modified, the
#       pre-migration shape) classifies as `regenerable`, so a merged worktree still reaps.
#   (E) STALE-BASE EXEMPTION — an overlap made only of derived paths is NOT a stale base.
#
# Fully hermetic: temp git repos, no network, no gh, no herdr, no model.
# Run:  bash tests/test-derived-skill.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"
LIB="$ROOT/scripts/herd/derived-files.sh"
GATE="$ROOT/scripts/herd/stale-dup-gate.sh"

for f in "$HERD" "$LIB" "$GATE"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done
command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }

SKILL_REL=".claude/commands/coordinator.md"

# _mkrepo <dir> — a committed, hermetic git repo.
_mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@t.local; git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m base
}

# _herd <dir> <args...> — run the CLI in <dir>, non-interactive, no doctor.
_herd() { local d="$1"; shift; ( cd "$d" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" "$@" ); }

# ── A. every render path renders when the file is absent, and leaves the tree clean ────────────────
P="$T/proj"; _mkrepo "$P"
_herd "$P" init >/dev/null 2>&1 || fail "A: herd init failed"
[ -f "$P/$SKILL_REL" ] || fail "A1: init did not render the skill"
ok "A1 init renders the skill"

grep -qxF "$SKILL_REL" "$P/.gitignore" || fail "A2: init did not gitignore the render"
ok "A2 init gitignores the render"

# Commit init's own output so the ONLY thing that could dirty the tree is the render.
git -C "$P" add -A && git -C "$P" commit -q -m init
[ -z "$(git -C "$P" status --porcelain)" ] || fail "A3: tree dirty after init: $(git -C "$P" status --porcelain)"
git -C "$P" ls-files --error-unmatch -- "$SKILL_REL" >/dev/null 2>&1 \
  && fail "A3: the render was committed — it must be gitignored, never tracked"
ok "A3 the render is untracked and the tree is clean after init"

# Render path 2: `herd render` with the file ABSENT regenerates it, tree stays clean.
rm -f "$P/$SKILL_REL"
_herd "$P" render >/dev/null 2>&1 || fail "A4: herd render failed with the skill absent"
[ -f "$P/$SKILL_REL" ] || fail "A4: herd render did not regenerate the absent skill"
[ -z "$(git -C "$P" status --porcelain)" ] || fail "A4: herd render dirtied the tree: $(git -C "$P" status --porcelain)"
ok "A4 herd render regenerates an absent skill, tree stays clean"

# Render path 3: `herd upgrade` (which `herd update` delegates to), likewise. Upgrade legitimately
# rewrites .herd/config (version stamps, additive keys), so assert on the RENDER, not the whole tree.
rm -f "$P/$SKILL_REL"
_herd "$P" upgrade >/dev/null 2>&1 || fail "A5: herd upgrade failed with the skill absent"
[ -f "$P/$SKILL_REL" ] || fail "A5: herd upgrade did not regenerate the absent skill"
git -C "$P" status --porcelain | grep -q "$SKILL_REL" \
  && fail "A5: the regenerated render showed up in git status"
ok "A5 herd upgrade regenerates an absent skill without dirtying the tree with it"

# The ignore line is written ONCE, however many renders run (idempotent).
[ "$(grep -cxF "$SKILL_REL" "$P/.gitignore")" -eq 1 ] || fail "A6: the ignore line was appended more than once"
ok "A6 the gitignore entry is idempotent across renders"

# ── B. migration: a project still TRACKING the render is untracked by `herd upgrade` ───────────────
M="$T/legacy"; _mkrepo "$M"
_herd "$M" init >/dev/null 2>&1 || fail "B: herd init failed"
# Recreate the pre-migration world: force the render into the index and drop the ignore line.
grep -vxF "$SKILL_REL" "$M/.gitignore" > "$M/.gitignore.new" && mv "$M/.gitignore.new" "$M/.gitignore"
git -C "$M" add -A -f && git -C "$M" commit -q -m "legacy: tracked render"
git -C "$M" ls-files --error-unmatch -- "$SKILL_REL" >/dev/null 2>&1 || fail "B: fixture did not track the render"

_herd "$M" upgrade >/dev/null 2>&1 || fail "B1: herd upgrade failed on a legacy project"
git -C "$M" ls-files --error-unmatch -- "$SKILL_REL" >/dev/null 2>&1 \
  && fail "B1: upgrade left the render tracked"
ok "B1 upgrade untracks a tracked render"

[ -f "$M/$SKILL_REL" ] || fail "B2: upgrade deleted the render from disk (it must survive as the local artifact)"
ok "B2 the on-disk render survives the migration"

grep -qxF "$SKILL_REL" "$M/.gitignore" || fail "B3: upgrade did not restore the ignore line"
ok "B3 upgrade re-adds the gitignore entry"

# The deletion is STAGED (D in the index), so the operator commits one migration commit.
git -C "$M" status --porcelain | grep -q "^D  $SKILL_REL" || fail "B4: the index deletion was not staged"
ok "B4 the untracking is staged as a deletion"

# Idempotent: once the migration commit lands, a second upgrade leaves the tree clean — the exact
# property the six interference incidents were missing.
git -C "$M" add -A && git -C "$M" commit -q -m "chore: untrack rendered coordinator skill"
_herd "$M" upgrade >/dev/null 2>&1 || fail "B5: second herd upgrade failed"
[ -z "$(git -C "$M" status --porcelain)" ] || fail "B5: second upgrade dirtied the migrated tree: $(git -C "$M" status --porcelain)"
ok "B5 a migrated project stays clean on re-upgrade"

# ── C. the shared list + strip filter ──────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "$LIB"

herd_is_derived_path ".claude/commands/coordinator.md" || fail "C1: default render path must be derived"
herd_is_derived_path ".herd/config.local"              || fail "C1: config.local must be derived"
herd_is_derived_path "bin/herd"                        && fail "C1: engine source must NOT be derived"
herd_is_derived_path ""                                && fail "C1: the empty path must NOT be derived"
ok "C1 herd_is_derived_path covers the derived set and nothing else"

# The rendered basename follows COORDINATOR_CMD (a consumer may rename the slash command).
( COORDINATOR_CMD="/ops" herd_is_derived_path ".claude/commands/ops.md" ) \
  || fail "C2: the derived path must follow COORDINATOR_CMD"
( COORDINATOR_CMD="/ops" herd_is_derived_path ".claude/commands/coordinator.md" ) \
  && fail "C2: a renamed command must not excuse the default path"
ok "C2 the derived render path follows COORDINATOR_CMD"

_stripped="$(printf '%s\n' "$SKILL_REL" "src/app.py" ".herd/config.local" | herd_strip_derived)"
[ "$_stripped" = "src/app.py" ] || fail "C3: strip kept the wrong paths: '$_stripped'"
[ -z "$(printf '%s\n' "$SKILL_REL" | herd_strip_derived)" ] || fail "C3: a derived-only list must strip to empty"
ok "C3 herd_strip_derived drops derived paths and keeps real work"

# ── D. sweep exemption: a tracked+modified render is regenerable dirt, not real work ───────────────
# _sweep_classify_dirt is the sweep's dirt oracle. Source sweep.sh the way tests/test-sweep.sh does,
# with the minimum env its lib-mode load of agent-watch.sh needs.
S="$T/sweepproj"; _mkrepo "$S"
mkdir -p "$S/.claude/commands"
printf 'rendered v1\n' > "$S/$SKILL_REL"
printf 'x\n' > "$S/real.txt"
git -C "$S" add -A -f && git -C "$S" commit -q -m "tracked render (pre-migration shape)"
printf 'rendered v2\n' > "$S/$SKILL_REL"   # a `herd reload` in this worktree: tracked file, modified

_classify="$(
  cd "$S" || exit 1
  export MAIN="$S" TREES="$T/sweepproj-trees" WORKSPACE_NAME=sweepproj HERD_DRIVER=headless
  # shellcheck source=/dev/null
  . "$ROOT/scripts/herd/sweep.sh" >/dev/null 2>&1
  _sweep_classify_dirt "$S"
)"
[ "$_classify" = "regenerable" ] || fail "D1: a modified tracked render must classify regenerable, got '$_classify'"
ok "D1 sweep classifies a modified tracked render as regenerable"

printf 'y\n' > "$S/real.txt"               # now REAL work sits alongside the derived dirt
_classify2="$(
  cd "$S" || exit 1
  export MAIN="$S" TREES="$T/sweepproj-trees" WORKSPACE_NAME=sweepproj HERD_DRIVER=headless
  # shellcheck source=/dev/null
  . "$ROOT/scripts/herd/sweep.sh" >/dev/null 2>&1
  _sweep_classify_dirt "$S"
)"
case "$_classify2" in
  dirty*) : ;;
  *) fail "D2: real work alongside a derived file must classify dirty, got '$_classify2'" ;;
esac
printf '%s' "$_classify2" | grep -q "$SKILL_REL" && fail "D2: the derived render must not be named as evidence"
printf '%s' "$_classify2" | grep -q 'real.txt'   || fail "D2: the real modified file must be named as evidence"
ok "D2 real work alongside the derived render still classifies dirty (evidence names only the real file)"

# ── E. stale-base exemption: an overlap of derived paths only is not a stale base ──────────────────
# shellcheck source=/dev/null
. "$GATE"
REPO="$T/stale"; _mkrepo "$REPO"
g() { git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
mkdir -p "$REPO/.claude/commands"
printf 'render base\n' > "$REPO/$SKILL_REL"
printf 'code base\n'   > "$REPO/src.txt"
g add -A -f; g commit -qm base
g checkout -q -b feat
printf 'render feat\n' > "$REPO/$SKILL_REL"     # the branch re-rendered the skill
g add -A; g commit -qm "feat re-render"
g checkout -q main
printf 'render main\n' > "$REPO/$SKILL_REL"     # main re-rendered it too — the only overlap
g add -A; g commit -qm "main re-render"

stale_dup_base_overlap "$REPO" main feat >/dev/null 2>&1 \
  && fail "E1: a derived-only overlap must NOT count as a stale base"
ok "E1 a derived-only overlap is not a stale base"

# A real overlapping file still holds — the exemption is narrow, not a blanket off-switch.
g checkout -q feat
printf 'code feat\n' > "$REPO/src.txt"; g add -A; g commit -qm "feat edits src"
g checkout -q main
printf 'code main\n' > "$REPO/src.txt"; g add -A; g commit -qm "main edits src"
_overlap="$(stale_dup_base_overlap "$REPO" main feat)" || fail "E2: a real overlap must be reported"
[ "$_overlap" = "src.txt" ] || fail "E2: overlap should be exactly src.txt, got '$_overlap'"
ok "E2 a real overlapping file is still a stale base (and the render is filtered out of the evidence)"

echo "ALL PASS ($PASS checks)"
