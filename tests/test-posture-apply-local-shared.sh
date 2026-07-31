#!/usr/bin/env bash
# test-posture-apply-local-shared.sh — mutation-prove HERD-469's LAYER ROUTING for
# `herd posture apply [--local|--shared] <name>`.
#
# Before HERD-469, `herd posture apply` always wrote a project-scoped key straight into the
# COMMITTED .herd/config — fine for a solo operator who commits right after, but observed live to
# raise the operator's CHECKOUT UNCLEAN row within minutes of an unattended ("yolo") apply, because
# nothing committed the write and nothing said it needed to be. This proves the fix:
#
#   (1) DEFAULT (no flag) routes every changed key into the gitignored .herd/config.local overlay
#       whenever writing to the committed baseline would leave it uncommitted — the common case for
#       any project-scoped key on an already-committed .herd/config — and the committed file stays
#       BYTE-IDENTICAL while the overlay carries the exact delta and effective values read correctly.
#   (2) DEFAULT stays on the committed baseline (today's pre-HERD-469 behavior) only when the whole
#       delta is machine-scoped (nothing would ever touch the baseline) AND a single git identity has
#       committed to the repo — flipping EITHER condition (a second commit author, or adding a single
#       project-scoped key to the bundle) flips the default to --local, proven as a true mutation: same
#       fixture, one fact changed, the printed layer flips.
#   (3) --shared forces the committed-baseline write regardless of the default, and always prints
#       explicit commit-or-already-committed messaging — never a silently dirty shared tree.
#   (4) --local forces the overlay regardless of the default, and --local + --shared together refuse
#       with zero writes.
#
# Fully hermetic: local temp git repos only, no network, no gh, no herdr, no model.
# Run:  bash tests/test-posture-apply-local-shared.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"

command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }

# A minimal posture table this file owns, so each bundle's scope mix is exact and controlled:
#   soloproj    — one PROJECT-scoped key only (MERGE_POLICY)
#   machineonly — one MACHINE-scoped key only (MODEL_QUICK) — never touches the committed baseline
#   mixed       — both — the "VERIFY: apply --local" scenario the task spec names directly
POSTURES="$T/postures.tsv"
{
  printf 'name\tkeys\tintent\n'
  printf 'soloproj\tMERGE_POLICY=approve\tone project-scoped lever\n'
  printf 'machineonly\tMODEL_QUICK=opus\tone machine-scoped lever, never baseline-destined\n'
  printf 'mixed\tMERGE_POLICY=approve MODEL_QUICK=opus\tone project key + one machine key\n'
} > "$POSTURES"

# _mkproj <dir> [<email> <name>] — a hermetic project with a COMMITTED .herd/config baseline (the
# realistic, mature-repo state this feature is about: herdkit's own .herd/config is tracked). `herd
# init` itself writes .herd/config but does NOT commit it, so this commits everything init produced.
_mkproj() {
  local d="$1" email="${2:-a@t.local}" name="${3:-operator-a}"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email "$email"; git -C "$d" config user.name "$name"
  git -C "$d" commit -q --allow-empty -m base
  ( cd "$d" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" init ) >/dev/null 2>&1 \
    || fail "herd init failed in $d"
  git -C "$d" add -A
  git -C "$d" commit -q -m "committed baseline"
}

# _second_operator <dir> — adds a SECOND distinct committer identity to the repo's history (a
# no-op file touch), so _posture_second_operator reads true for it.
_second_operator() {
  local d="$1"
  git -C "$d" config user.email b@t.local; git -C "$d" config user.name operator-b
  printf 'noted\n' >> "$d/BACKLOG.md"
  git -C "$d" add -A
  git -C "$d" commit -q -m "operator b touch"
  git -C "$d" config user.email a@t.local; git -C "$d" config user.name operator-a
}

_herd() { local d="$1"; shift; ( cd "$d" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 POSTURES_FILE="$POSTURES" bash "$HERD" "$@" ); }

# ── 1. DEFAULT, single operator, a project-scoped key in the bundle → --local, byte-identical baseline
P1="$T/p1"; _mkproj "$P1"
BASELINE_HEAD="$(git -C "$P1" show HEAD:.herd/config)"
OUT1="$(_herd "$P1" posture apply --yes --no-reload mixed 2>&1)" || fail "1: apply failed"
grep -q 'layer: .herd/config.local (' <<< "$OUT1" \
  || fail "1: default did not choose the overlay layer for a bundle carrying a project-scoped key"
grep -qi 'uncommitted' <<< "$OUT1" || fail "1: the printed reason never named the would-dirty baseline"
[ "$(cat "$P1/.herd/config")" = "$BASELINE_HEAD" ] \
  || fail "1: the committed .herd/config changed even though the layer was .herd/config.local"
[ -f "$P1/.herd/config.local" ] || fail "1: no .herd/config.local overlay was created"
grep -q 'MERGE_POLICY="approve"' "$P1/.herd/config.local" || fail "1: overlay is missing MERGE_POLICY"
grep -q 'MODEL_QUICK="opus"' "$P1/.herd/config.local"     || fail "1: overlay is missing MODEL_QUICK"
[ "$(_herd "$P1" config get MERGE_POLICY 2>/dev/null | tail -1)" = approve ] \
  || fail "1: MERGE_POLICY does not read \"approve\" at load time"
[ "$(_herd "$P1" config get MODEL_QUICK 2>/dev/null | tail -1)" = opus ] \
  || fail "1: MODEL_QUICK does not read \"opus\" at load time"
_herd "$P1" config lint >/dev/null 2>&1 || fail "1: 'herd config lint' is red after a --local-routed apply"
ok "1 DEFAULT routes a project-scoped bundle to .herd/config.local: baseline byte-identical, overlay carries the delta, effective values correct"

# ── 2. DEFAULT, single operator, PURE machine-scoped bundle → stays on the committed baseline layer
P2="$T/p2"; _mkproj "$P2"
BASELINE_HEAD2="$(git -C "$P2" show HEAD:.herd/config)"
OUT2="$(_herd "$P2" posture apply --yes --no-reload machineonly 2>&1)" || fail "2: apply failed"
grep -q 'layer: .herd/config (' <<< "$OUT2" \
  || fail "2: default did not choose the committed-baseline layer for a pure machine-scoped bundle"
grep -qi 'already matches the last commit' <<< "$OUT2" \
  || fail "2: no explicit --shared messaging was printed"
[ "$(cat "$P2/.herd/config")" = "$BASELINE_HEAD2" ] \
  || fail "2: .herd/config changed even though nothing in the bundle is baseline-destined"
grep -q 'MODEL_QUICK="opus"' "$P2/.herd/config.local" || fail "2: MODEL_QUICK did not land in the overlay (machine-scoped is unconditional)"
ok "2 DEFAULT stays on the committed-baseline layer when the whole delta is machine-scoped and the repo has one operator"

# ── 3. MUTATION: the SAME machineonly bundle, but a second git identity has committed → flips to --local
P3="$T/p3"; _mkproj "$P3"
_second_operator "$P3"
OUT3="$(_herd "$P3" posture apply --yes --no-reload machineonly 2>&1)" || fail "3: apply failed"
grep -q 'layer: .herd/config.local (' <<< "$OUT3" \
  || fail "3: a second committer identity did not flip the default to --local"
grep -qi 'second operator' <<< "$OUT3" || fail "3: the printed reason never named the second operator"
ok "3 MUTATION: adding a second committer identity (nothing else changed) flips the same bundle's default from --shared to --local"

# ── 4. --shared forces the committed baseline, with explicit dirty-tree messaging ──────────────────
P4="$T/p4"; _mkproj "$P4"
BASELINE_HEAD4="$(git -C "$P4" show HEAD:.herd/config)"
OUT4="$(_herd "$P4" posture apply --yes --no-reload --shared soloproj 2>&1)" || fail "4: apply failed"
grep -q 'layer: .herd/config (--shared requested' <<< "$OUT4" || fail "4: --shared was not honored as the chosen layer"
grep -qi 'UNCOMMITTED shared-baseline change' <<< "$OUT4" || fail "4: --shared did not print explicit commit messaging"
[ "$(cat "$P4/.herd/config")" != "$BASELINE_HEAD4" ] || fail "4: --shared did not actually write the committed baseline"
[ -n "$(git -C "$P4" status --porcelain -- .herd/config)" ] \
  || fail "4: --shared wrote the baseline but git reports it clean (the dirty-tree claim would be false)"
if [ -f "$P4/.herd/config.local" ] && grep -q 'MERGE_POLICY' "$P4/.herd/config.local" 2>/dev/null; then
  fail "4: --shared routed a project-scoped key into the overlay instead of the baseline"
fi
git -C "$P4" add .herd/config
git -C "$P4" commit -q -m "commit the shared change"
[ -z "$(git -C "$P4" status --porcelain -- .herd/config)" ] || fail "4: committing did not clean the tree"
ok "4 --shared writes the committed baseline directly and names the resulting dirty tree explicitly; committing it clears the claim"

# ── 5. --local forces the overlay even where the default would have stayed --shared ────────────────
P5="$T/p5"; _mkproj "$P5"
BASELINE_HEAD5="$(git -C "$P5" show HEAD:.herd/config)"
OUT5="$(_herd "$P5" posture apply --yes --no-reload --local machineonly 2>&1)" || fail "5: apply failed"
grep -q 'layer: .herd/config.local (--local requested' <<< "$OUT5" || fail "5: --local was not honored as the chosen layer"
[ "$(cat "$P5/.herd/config")" = "$BASELINE_HEAD5" ] || fail "5: --local still wrote the committed baseline"
ok "5 --local is honored explicitly (named as '--local requested'), independent of what the default would have chosen"

# ── 6. --local and --shared together refuse, with zero writes ───────────────────────────────────────
P6="$T/p6"; _mkproj "$P6"
CFG_BEFORE6="$(cat "$P6/.herd/config")"
_herd "$P6" posture apply --yes --no-reload --local --shared soloproj >/dev/null 2>&1 \
  && fail "6: --local and --shared together were accepted"
[ "$(cat "$P6/.herd/config")" = "$CFG_BEFORE6" ] || fail "6: the refused apply still wrote to .herd/config"
if [ -f "$P6/.herd/config.local" ] && grep -q 'MERGE_POLICY' "$P6/.herd/config.local" 2>/dev/null; then
  fail "6: the refused apply still wrote to .herd/config.local"
fi
ok "6 --local and --shared together are refused, with zero writes to either layer"

echo "posture-apply-local-shared: $PASS checks passed"
