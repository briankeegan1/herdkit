#!/usr/bin/env bash
# test-init-flags.sh — hermetic tests for HERD-410's `herd init --archetype <name>` /
# `herd init --posture <name>` flags.
#
# Grounding: `herd fleet new` (HERD-410) needs a way to hand `herd init` a concrete archetype/
# posture WITHOUT going through the interactive interview, even when the caller is scripted (no
# tty). Before this change, non-interactive init had exactly one shape: silently seeded defaults
# (archetype=code, GitHub-derived MERGE_POLICY) — there was no flag to name a real choice.
#
# Asserts:
#   (1) --archetype <name> is validated up front: an unknown name dies loudly, before ANY file is
#       written (no .herd/config left behind).
#   (2) --posture <name> is validated up front: same contract.
#   (3) --archetype <name> --posture <name> together, NON-interactive: both flags win, no
#       interactive picker runs, PROJECT_ARCHETYPE + the posture's bundle land in .herd/config, and
#       the flag path announces its choice (never silent).
#   (4) --archetype/--posture flags win even when a tty IS present (HERD_*_ASSUME_TTY test seams) —
#       an explicit flag always beats the interview, so scripting never has to fight a live prompt.
#   (5) REGRESSION GUARD: a plain non-interactive `herd init` with NEITHER flag stays byte-identical
#       to before this change — no "Project archetype" / "Operating posture" interview text, and the
#       archetype/posture seeded defaults are unchanged (archetype=code, det_policy-derived
#       MERGE_POLICY). This is the contract tests/test-init-archetypes.sh (3) and
#       tests/test-init-posture-profiles.sh (1) already pin; asserted again here as the flag change's
#       own regression proof, since it is the change most likely to have touched this path.
#
# NO network, NO gh, NO herdr, NO claude: HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
export HERD REPO

command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
REAL_BASH="$(command -v bash)"
[ -f "$REPO/templates/archetypes.tsv" ] || { echo "FAIL: archetypes.tsv missing" >&2; exit 1; }
[ -f "$REPO/templates/postures.tsv" ]   || { echo "FAIL: postures.tsv missing" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }
plain() { printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }

mkproj() {
  local d="$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
  git -C "$d" branch -M main
}

# ── (1) unknown --archetype dies loudly, writes nothing ──────────────────────────────────────────
proj="$T/bad-archetype"; mkproj "$proj"
out="$( cd "$proj" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
        "$REAL_BASH" "$HERD" init --archetype nope-not-real 2>&1 )"
rc=$?
[ "$rc" -ne 0 ] || fail "(1) unknown --archetype should fail: $out"
echo "$out" | grep -qi "unknown --archetype" || fail "(1) should name the bad flag: $out"
[ -e "$proj/.herd/config" ] && fail "(1) no .herd/config should be written on a rejected flag"
ok

# ── (2) unknown --posture dies loudly, writes nothing ─────────────────────────────────────────────
proj="$T/bad-posture"; mkproj "$proj"
out="$( cd "$proj" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
        "$REAL_BASH" "$HERD" init --posture nope-not-real 2>&1 )"
rc=$?
[ "$rc" -ne 0 ] || fail "(2) unknown --posture should fail: $out"
echo "$out" | grep -qi "unknown --posture" || fail "(2) should name the bad flag: $out"
[ -e "$proj/.herd/config" ] && fail "(2) no .herd/config should be written on a rejected flag"
ok

# ── (3) both flags, non-interactive: win over defaults, announce themselves ──────────────────────
proj="$T/flags-noninteractive"; mkproj "$proj"
out="$( cd "$proj" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
        "$REAL_BASH" "$HERD" init --archetype research-lab --posture observe-only 2>&1 )" \
  || fail "(3) init failed: $out"
pout="$(plain "$out")"
echo "$pout" | grep -q "from --archetype flag" || fail "(3) should announce the archetype flag: $out"
echo "$pout" | grep -q "from --posture flag"   || fail "(3) should announce the posture flag: $out"
grep -qE '^PROJECT_ARCHETYPE="research-lab"$' "$proj/.herd/config" \
  || fail "(3) PROJECT_ARCHETYPE not persisted: $(grep PROJECT_ARCHETYPE "$proj/.herd/config")"
grep -qE '^MERGE_POLICY="observe"$' "$proj/.herd/config" \
  || fail "(3) observe-only posture should set MERGE_POLICY=observe: $(grep MERGE_POLICY "$proj/.herd/config")"
cmp -s "$proj/.herd/healthcheck.project.sh" "$REPO/templates/healthcheck.docs.sh" \
  || fail "(3) research-lab should seed healthcheck.docs.sh"
ok

# ── (4) flags win even with a tty present (assume-tty seams) — no interview text, no stdin read ──
proj="$T/flags-with-tty"; mkproj "$proj"
out="$( cd "$proj" && HERD_ARCHETYPE_ASSUME_TTY=1 HERD_POSTURE_ASSUME_TTY=1 \
        HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
        "$REAL_BASH" "$HERD" init --archetype docs --posture team-approve \
          < /dev/null 2>&1 )" \
  || fail "(4) init failed: $out"
pout="$(plain "$out")"
echo "$pout" | grep -q "from --archetype flag" || fail "(4) archetype flag should still win under a tty: $out"
echo "$pout" | grep -q "from --posture flag"   || fail "(4) posture flag should still win under a tty: $out"
echo "$pout" | grep -qE '^\s+[0-9]\) code' && fail "(4) the archetype PICKER must not run when the flag is given: $out"
grep -qE '^PROJECT_ARCHETYPE="docs"$' "$proj/.herd/config" || fail "(4) PROJECT_ARCHETYPE not persisted"
grep -qE '^MERGE_POLICY="approve"$' "$proj/.herd/config" || fail "(4) team-approve posture should set MERGE_POLICY=approve"
ok

# ── (5) REGRESSION GUARD: plain non-interactive init, no flags, stays byte-identical ─────────────
proj="$T/no-flags"; mkproj "$proj"
out="$( cd "$proj" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
        "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(5) init failed: $out"
pout="$(plain "$out")"
echo "$pout" | grep -q "Project archetype" && fail "(5) plain non-interactive must NOT run/announce the archetype interview: $out"
echo "$pout" | grep -q "Operating posture"  && fail "(5) plain non-interactive must NOT run/announce the posture interview: $out"
grep -qE '^PROJECT_ARCHETYPE="code"$' "$proj/.herd/config" || fail "(5) PROJECT_ARCHETYPE should still default to code"
grep -qE '^MERGE_POLICY="auto"$' "$proj/.herd/config" || fail "(5) MERGE_POLICY should still default to auto (no remote, no protection)"
ok

echo "ALL PASS ($pass checks)"
