#!/usr/bin/env bash
# test-init-gitignore-config-local.sh — hermetic proof of HERD-519 leg (b): EVERY `herd init`
# gitignores the per-user overlay .herd/config.local, not just the conditional/interactive paths.
#
# THE DEFECT. The overlay was covered only when the grounding interview's graphify question was
# answered yes (bin/herd's _init_grounding_interview) — so a plain, non-interactive `herd init` left it
# uncovered. The first machine-scoped `herd config set` (HERD_DRIVER, a MODEL_* tier, GRAPHIFY_BIN …)
# then created an untracked per-machine file the operator could commit by accident, diverging every
# other operator's effective config. `herd fleet new` already patched this AFTER delegating to init
# (scripts/herd/fleet.sh, where the gap was documented); the fix closes it at the source.
#
# What this asserts:
#   (1) A plain non-interactive init gitignores .herd/config.local.
#   (2) It is IDEMPOTENT — a second init (and the conditional site that still calls the same helper)
#       never appends a duplicate line.
#   (3) The guarantee is REAL: a machine-scoped `config set` writes the overlay, and git ignores it —
#       `git status` stays clean and `git add -A` cannot stage it.
#   (4) An existing .gitignore is APPENDED to, never clobbered.
#
# Fully hermetic: temp git repos, no network, no gh, no herdr, no model.
# Run:  bash tests/test-init-gitignore-config-local.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"
[ -f "$HERD" ] || { echo "FAIL: missing $HERD" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }

REL='.herd/config.local'

_mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@t.local; git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m base
}
_herd() { local d="$1"; shift; ( cd "$d" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" "$@" ); }

# ══ (1) a plain non-interactive init covers the overlay ════════════════════════════════════════
P="$T/plain"; _mkrepo "$P"
_herd "$P" init >/dev/null 2>&1 || fail "(1) herd init failed"
[ -f "$P/.gitignore" ] || fail "(1) init wrote no .gitignore at all"
grep -qxF "$REL" "$P/.gitignore" || fail "(1) a plain init did not gitignore $REL: $(cat "$P/.gitignore")"
ok "1 a plain non-interactive init gitignores .herd/config.local"

# ══ (2) idempotent — the line is written exactly once, and never duplicated ════════════════════
# Within one init the helper is reachable twice (this unconditional call and the grounding
# interview's conditional one), and a project may already carry the line from a previous engine or
# from `herd fleet new`. Neither may produce a second copy.
[ "$(grep -cxF "$REL" "$P/.gitignore")" -eq 1 ] \
  || fail "(2) init wrote the ignore line $(grep -cxF "$REL" "$P/.gitignore") times"
I="$T/preignored"; _mkrepo "$I"
printf '%s\n' "$REL" > "$I/.gitignore"        # already covered before init runs
git -C "$I" add -A && git -C "$I" commit -q -m "pre-existing ignore"
_herd "$I" init >/dev/null 2>&1 || fail "(2) herd init failed on a pre-ignored repo"
[ "$(grep -cxF "$REL" "$I/.gitignore")" -eq 1 ] \
  || fail "(2) init duplicated an ignore line the project already had"
ok "2 the ignore line is written exactly once and never duplicated"

# ══ (3) the guarantee is real: a machine-scoped set cannot be committed by accident ═════════════
git -C "$P" add -A && git -C "$P" commit -q -m init
[ -z "$(git -C "$P" status --porcelain)" ] || fail "(3) the fixture was dirty before the overlay write"
_herd "$P" config set --local HERD_DRIVER claude >/dev/null 2>&1 \
  || printf 'HERD_DRIVER="claude"\n' > "$P/$REL"   # the write itself is not what is under test
[ -f "$P/$REL" ] || fail "(3) no overlay file to test the ignore against"
[ -z "$(git -C "$P" status --porcelain)" ] \
  || fail "(3) the per-user overlay dirtied the checkout: $(git -C "$P" status --porcelain)"
git -C "$P" add -A
grep -qxF "$REL" <<< "$(git -C "$P" diff --cached --name-only)" \
  && fail "(3) 'git add -A' staged the per-user overlay — the ignore is not effective"
ok "3 a per-user overlay written after init is ignored and cannot be staged by 'git add -A'"

# ══ (4) an existing .gitignore is appended to, never clobbered ═════════════════════════════════
E="$T/existing"; _mkrepo "$E"
printf '%s\n' 'node_modules/' '*.log' > "$E/.gitignore"
git -C "$E" add -A && git -C "$E" commit -q -m "project gitignore"
_herd "$E" init >/dev/null 2>&1 || fail "(4) herd init failed on a repo with an existing .gitignore"
grep -qxF 'node_modules/' "$E/.gitignore" || fail "(4) init clobbered an existing ignore rule"
grep -qxF '*.log'         "$E/.gitignore" || fail "(4) init clobbered an existing ignore rule"
grep -qxF "$REL"          "$E/.gitignore" || fail "(4) init did not append $REL"
ok "4 an existing .gitignore is preserved and appended to"

echo "ALL PASS ($PASS checks)"
