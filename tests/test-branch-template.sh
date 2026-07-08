#!/usr/bin/env bash
# test-branch-template.sh — hermetic proof for project-defined branch naming (BRANCH_TEMPLATE, HERD-120).
#
# feat/<slug> was hardcoded across the lanes and the watcher's dep-check. BRANCH_TEMPLATE (default
# 'feat/{slug}') moves that behind ONE shared render+parse helper (herd_branch_render /
# herd_branch_parse in herd-config.sh) so a project can rename its branches without the pieces drifting.
#
# Asserts:
#   (a) DEFAULT (unset) renders BYTE-IDENTICAL to the old feat/<slug>, and round-trips through parse.
#   (b) render+parse are EXACT INVERSES for default, custom-prefix, {ref}, empty-{ref}, suffix and
#       nested templates: parse(render(slug,ref)) == slug for every case.
#   (c) MALFORMED template (no {slug}) → render WARNS to stderr and falls back to feat/<slug> (no
#       stray characters), never producing an unusable branch (fail-soft).
#   (d) LANE INTEGRATION: new-feature.sh actually creates the worktree on the TEMPLATED branch — the
#       construction site is genuinely routed through the helper, not just the helper in isolation.
#   (e) The watcher's orphan-tab sweep parses branches with an INLINE python MIRROR of herd_branch_parse;
#       this locks the mirror to the shell helper so a custom scheme resolves the same slug in both.
#
# Fully hermetic: local temp only, NO herdr / gh / network / model. Run:  bash tests/test-branch-template.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONFIG_SH="$ROOT/scripts/herd/herd-config.sh"
NEWFEAT="$ROOT/scripts/herd/new-feature.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Source the helper under a hermetic env (an absent config → generic defaults) ────────────────────
export HERD_CONFIG_FILE="$T/no-such-config"
export PROJECT_ROOT="$T/project"; mkdir -p "$PROJECT_ROOT"
export WORKTREES_DIR="$T/trees";  mkdir -p "$WORKTREES_DIR"
export WORKSPACE_NAME="branchtmpl-test"
# shellcheck source=/dev/null
. "$CONFIG_SH" >/dev/null 2>&1 || fail "sourcing herd-config.sh failed"
type herd_branch_render >/dev/null 2>&1 || fail "herd_branch_render not defined after sourcing herd-config.sh"
type herd_branch_parse  >/dev/null 2>&1 || fail "herd_branch_parse not defined after sourcing herd-config.sh"

# set_tmpl <template|__UNSET__>
set_tmpl() { if [ "$1" = "__UNSET__" ]; then unset BRANCH_TEMPLATE; else export BRANCH_TEMPLATE="$1"; fi; }

# ── (a) DEFAULT unset → byte-identical feat/<slug>, round-trips ─────────────────────────────────────
set_tmpl __UNSET__
[ "$(herd_branch_render my-feature)"       = "feat/my-feature" ] || fail "(a) default render != feat/my-feature"
[ "$(herd_branch_render my-feature HERD-1)" = "feat/my-feature" ] || fail "(a) default render must ignore ref when template has no {ref}"
[ "$(herd_branch_parse feat/my-feature)"    = "my-feature" ]      || fail "(a) default parse(feat/my-feature) != my-feature"
pass; echo "PASS (a) BRANCH_TEMPLATE unset → feat/<slug> byte-identical, round-trips"

# ── (b) render/parse are exact inverses across template shapes ──────────────────────────────────────
# rows: "<template>|<slug>|<ref>|<expected-branch>"
ROWS=(
  "feat/{slug}|my-feature||feat/my-feature"
  "wip/{slug}|foo-bar||wip/foo-bar"
  "{ref}/{slug}|login|HERD-42|HERD-42/login"
  "{ref}/{slug}|login||login"               # empty ref collapses the leading separator
  "feat/{slug}-exp|abc||feat/abc-exp"
  "team/{ref}/{slug}|x-y|HERD-9|team/HERD-9/x-y"
)
for row in "${ROWS[@]}"; do
  IFS='|' read -r tmpl slug ref exp <<EOF2
$row
EOF2
  set_tmpl "$tmpl"
  got="$(herd_branch_render "$slug" "$ref")"
  [ "$got" = "$exp" ]                  || fail "(b) render($tmpl,$slug,${ref:-<none>}) = '$got' != '$exp'"
  back="$(herd_branch_parse "$got")"
  [ "$back" = "$slug" ]                || fail "(b) parse('$got') = '$back' != slug '$slug' (not an inverse of render)"
done
pass; echo "PASS (b) render+parse are exact inverses (default + custom + {ref} + empty-ref + suffix + nested)"

# ── (c) malformed template (no {slug}) → warn + feat/<slug> fallback, no stray chars ────────────────
set_tmpl "branches-noslug"
warn="$T/warn.txt"
got="$(herd_branch_render zzz "" 2>"$warn")"
[ "$got" = "feat/zzz" ]                       || fail "(c) malformed template did not fall back to feat/zzz (got '$got')"
grep -q "no {slug} token" "$warn"             || fail "(c) malformed template must WARN to stderr"
# The warning goes to stderr ONLY — captured stdout is the clean branch (a caller's \$(...) is unpolluted).
case "$got" in *'⚠'*|*'}'*|*'{'*) fail "(c) render stdout leaked a warning / stray brace: '$got'" ;; esac
pass; echo "PASS (c) malformed template → stderr warning + feat/<slug> fallback (fail-soft, clean stdout)"

# ── (d) lane integration: new-feature.sh creates the worktree on the TEMPLATED branch ───────────────
# A throwaway origin+clone so new-feature.sh's `git worktree add … origin/main` succeeds, with herdr
# preflight bypassed and $HOME sandboxed (pretrust writes $HOME/.claude.json).
REPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
: > "$REPO/seed.txt"
git -C "$REPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null

lane_branch() {  # lane_branch <template|__UNSET__> <slug> <item-ref>  → echoes the created branch
  local tmpl="$1" slug="$2" iref="$3" ltrees="$T/lane-trees-$slug"
  mkdir -p "$ltrees"
  (
    export HOME="$T"
    export HERD_SKIP_PREFLIGHT=1
    export HERD_CONFIG_FILE="$T/lane-cfg-$slug"
    export WORKSPACE_NAME="branchtmpl-test"
    {
      printf 'PROJECT_ROOT="%s"\n'  "$REPO"
      printf 'WORKTREES_DIR="%s"\n' "$ltrees"
      printf 'DEFAULT_BRANCH="origin/main"\n'
      printf 'WORKSPACE_NAME="branchtmpl-test"\n'
      printf 'SHARE_LINKS=""\n'
      [ "$tmpl" = "__UNSET__" ] || printf 'BRANCH_TEMPLATE="%s"\n' "$tmpl"
    } > "$HERD_CONFIG_FILE"
    [ -n "$iref" ] && export HERD_ITEM_REF="$iref"
    bash "$NEWFEAT" "$slug" >/dev/null 2>&1 || exit 3
    git -C "$ltrees/$slug" rev-parse --abbrev-ref HEAD
  )
}

b_default="$(lane_branch __UNSET__ alpha-feat "")"        || fail "(d) new-feature.sh failed (default template)"
[ "$b_default" = "feat/alpha-feat" ]                       || fail "(d) default lane branch = '$b_default' != feat/alpha-feat"
b_custom="$(lane_branch "wip/{slug}" beta-feat "")"        || fail "(d) new-feature.sh failed (custom template)"
[ "$b_custom" = "wip/beta-feat" ]                          || fail "(d) custom lane branch = '$b_custom' != wip/beta-feat"
b_ref="$(lane_branch "{ref}/{slug}" gamma-feat HERD-777)"  || fail "(d) new-feature.sh failed ({ref} template)"
[ "$b_ref" = "HERD-777/gamma-feat" ]                       || fail "(d) {ref} lane branch = '$b_ref' != HERD-777/gamma-feat (HERD_ITEM_REF not threaded?)"
pass; echo "PASS (d) new-feature.sh creates the worktree on the templated branch (default / custom / {ref})"

# ── (e) the watcher orphan-sweep python mirror agrees with the shell helper on every branch ─────────
# The inline mirror lives in agent-watch.sh's _sweep_orphan_tabs; re-express it here verbatim and prove
# it yields the SAME slug as herd_branch_parse across the templates, so the two can never drift.
py_parse() {  # py_parse <template> <branch>
  BRANCH_TEMPLATE="$1" python3 -c '
import sys, os
tmpl = os.environ.get("BRANCH_TEMPLATE") or "feat/{slug}"
if "{slug}" not in tmpl: tmpl = "feat/{slug}"
pre, _, post = tmpl.partition("{slug}")
def parse(b):
  s = b
  if "{ref}" in pre:
    sep = pre.rsplit("{ref}", 1)[1]
    if sep:
      i = s.rfind(sep)
      if i >= 0: s = s[i + len(sep):]
  elif pre and s.startswith(pre):
    s = s[len(pre):]
  if "{ref}" in post:
    sep2 = post.split("{ref}", 1)[0]
    if sep2:
      i = s.find(sep2)
      if i >= 0: s = s[:i]
  elif post and s.endswith(post):
    s = s[:len(s) - len(post)]
  return s
print(parse(sys.argv[1]))
' "$2"
}
for row in "${ROWS[@]}"; do
  IFS='|' read -r tmpl slug ref exp <<EOF3
$row
EOF3
  set_tmpl "$tmpl"
  branch="$(herd_branch_render "$slug" "$ref")"
  sh_slug="$(herd_branch_parse "$branch")"
  py_slug="$(py_parse "$tmpl" "$branch")"
  [ "$sh_slug" = "$py_slug" ] || fail "(e) shell parse ('$sh_slug') != python mirror ('$py_slug') for branch '$branch' (template $tmpl)"
done
pass; echo "PASS (e) watcher orphan-sweep python mirror agrees with herd_branch_parse on every template"

echo
echo "ALL PASS ($PASS groups) — BRANCH_TEMPLATE render/parse round-trip, fail-soft, lane wiring, mirror parity."
