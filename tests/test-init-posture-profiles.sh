#!/usr/bin/env bash
# test-init-posture-profiles.sh — hermetic tests for HERD-141: `herd init` INTENT-FIRST posture
# profiles. cmd_init offers named postures from templates/postures.tsv and renders the chosen
# KEY=VALUE bundle into .herd/config; an advanced per-key path keeps power-user overrides.
#
# Asserts:
#   (1) NON-INTERACTIVE init stays BYTE-IDENTICAL to the seeded default key set (MERGE_POLICY from
#       detection/default, PR_FLOW=direct, no posture-only extras like HUMAN_VERIFY_POLICY).
#   (2) Selecting a NAMED posture (team-approve) via HERD_POSTURE_ASSUME_TTY writes that posture's
#       exact key bundle (MERGE_POLICY=approve + HUMAN_VERIFY_POLICY=hold).
#   (3) Selecting observe-only writes MERGE_POLICY=observe (and no spurious extras).
#   (4) Selecting gated-push writes PUSH_GATE=human + PR_FLOW=draft.
#   (5) Selecting custom-steps seeds .herd/steps.tsv (STEPS_PROFILE=approve-stage).
#   (6) Selecting full-auto writes the full-auto engine-autonomy key bundle.
#   (7) ADVANCED path still allows per-key override (MERGE_POLICY=observe, PR_FLOW=draft).
#   (8) solo-auto (equivalent to today's default) keeps the same base key set — no posture extras.
#
# NO network, NO gh, NO herdr, NO claude: init runs with HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1
# (or a safe PATH without gh). Driven via HERD_POSTURE_ASSUME_TTY + scripted stdin.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
export HERD

command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
REAL_BASH="$(command -v bash)"
[ -f "$REPO/templates/postures.tsv" ] || { echo "FAIL: postures.tsv missing" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }
plain() { printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }

# Source posture-lib for expected-key assertions (same reader init uses).
# shellcheck source=/dev/null
. "$REPO/scripts/herd/sim/posture-lib.sh"

mkproj() {
  local d="$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
  git -C "$d" branch -M main
}

# cfg_has <proj> <KEY> <VALUE> — assert KEY="VALUE" is present in .herd/config.
cfg_has() {
  local p="$1" k="$2" v="$3"
  grep -qE "^${k}=\"${v}\"\$" "$p/.herd/config" \
    || fail "expected ${k}=\"${v}\" in $p/.herd/config: $(grep -E "^(MERGE_|PR_|PUSH_|HUMAN_|REVIEW_|HEALTH|COORD|DEAD|STALE|SWEEP)" "$p/.herd/config" 2>/dev/null || cat "$p/.herd/config")"
}

# cfg_lacks <proj> <KEY> — assert KEY is NOT present.
cfg_lacks() {
  local p="$1" k="$2"
  grep -qE "^${k}=" "$p/.herd/config" \
    && fail "did not expect ${k}= in $p/.herd/config: $(grep -E "^${k}=" "$p/.herd/config")"
  return 0
}

# assert_bundle <proj> <posture-name> — every real KEY=VALUE in the posture lands in config;
# STEPS_PROFILE is not a config key (asserted separately when present).
assert_bundle() {
  local p="$1" name="$2" kv k v
  for kv in $(posture_keys "$name"); do
    case "$kv" in
      STEPS_PROFILE=*) continue ;;
      *=*) k="${kv%%=*}"; v="${kv#*=}"; cfg_has "$p" "$k" "$v" ;;
    esac
  done
}

# ── (1) NON-INTERACTIVE: byte-identical seeded defaults, no posture interview, no extras ─────────
proj="$T/noninteractive"; mkproj "$proj"
out="$( cd "$proj" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
        "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(1) init failed: $out"
pout="$(plain "$out")"
echo "$pout" | grep -q "Operating posture" && fail "(1) non-interactive must NOT run the posture interview: $out"
echo "$pout" | grep -qi "MERGE_POLICY defaulted to 'auto'" || fail "(1) HERD-140 loud auto notice missing: $out"
cfg_has "$proj" MERGE_POLICY auto
cfg_has "$proj" PR_FLOW direct
cfg_has "$proj" PR_READY_WHEN builder
cfg_has "$proj" DELETE_BRANCH_ON_MERGE false
cfg_has "$proj" LOCAL_REVIEW none
cfg_lacks "$proj" HUMAN_VERIFY_POLICY
cfg_lacks "$proj" PUSH_GATE
cfg_lacks "$proj" REVIEW_AUTOFIX
[ -e "$proj/.herd/steps.tsv" ] && fail "(1) non-interactive must not seed steps.tsv"
ok

# ── (2) NAMED posture team-approve → exact key bundle ────────────────────────────────────────────
proj="$T/team-approve"; mkproj "$proj"
out="$( cd "$proj" && printf 'team-approve\n' \
        | HERD_POSTURE_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(2) init failed: $out"
pout="$(plain "$out")"
echo "$pout" | grep -q "Operating posture" || fail "(2) posture interview should run: $out"
echo "$pout" | grep -q "posture=team-approve" || fail "(2) should announce selected posture: $out"
assert_bundle "$proj" team-approve
# Base keys still present (same key set + posture extras).
cfg_has "$proj" PR_FLOW direct
cfg_has "$proj" MERGE_METHOD merge
ok

# ── (3) observe-only → MERGE_POLICY=observe ──────────────────────────────────────────────────────
proj="$T/observe"; mkproj "$proj"
out="$( cd "$proj" && printf 'observe-only\n' \
        | HERD_POSTURE_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(3) init failed: $out"
assert_bundle "$proj" observe-only
cfg_lacks "$proj" HUMAN_VERIFY_POLICY
ok

# ── (4) gated-push → PUSH_GATE=human + PR_FLOW=draft ─────────────────────────────────────────────
proj="$T/gated"; mkproj "$proj"
out="$( cd "$proj" && printf 'gated-push\n' \
        | HERD_POSTURE_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(4) init failed: $out"
assert_bundle "$proj" gated-push
ok

# ── (5) custom-steps → seeds .herd/steps.tsv (approve-stage) ─────────────────────────────────────
proj="$T/custom"; mkproj "$proj"
out="$( cd "$proj" && printf 'custom-steps\n' \
        | HERD_POSTURE_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(5) init failed: $out"
[ -f "$proj/.herd/steps.tsv" ] || fail "(5) custom-steps must seed .herd/steps.tsv"
grep -q $'approve-stage\tpre-merge' "$proj/.herd/steps.tsv" \
  || fail "(5) steps.tsv missing approve-stage row: $(cat "$proj/.herd/steps.tsv")"
grep -q $'\tapprove$' "$proj/.herd/steps.tsv" || grep -q $'\tapprove\t' "$proj/.herd/steps.tsv" \
  || grep -q 'approve' "$proj/.herd/steps.tsv" \
  || fail "(5) steps.tsv should hold=approve: $(cat "$proj/.herd/steps.tsv")"
# STEPS_PROFILE is not a config key.
cfg_lacks "$proj" STEPS_PROFILE
ok

# ── (6) full-auto → full engine-autonomy key bundle ──────────────────────────────────────────────
proj="$T/full-auto"; mkproj "$proj"
out="$( cd "$proj" && printf 'full-auto\n' \
        | HERD_POSTURE_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(6) init failed: $out"
assert_bundle "$proj" full-auto
ok

# ── (7) ADVANCED path — per-key override still works ─────────────────────────────────────────────
proj="$T/advanced"; mkproj "$proj"
# advanced → MERGE_POLICY=observe → MERGE_METHOD=merge → PR_FLOW=draft → PR_READY_WHEN=human
# → DELETE_BRANCH_ON_MERGE=true → LOCAL_REVIEW=none
out="$( cd "$proj" && printf 'advanced\nobserve\nmerge\ndraft\nhuman\ntrue\nnone\n' \
        | HERD_POSTURE_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(7) init failed: $out"
pout="$(plain "$out")"
echo "$pout" | grep -qi "Advanced" || fail "(7) advanced path should be announced: $out"
cfg_has "$proj" MERGE_POLICY observe
cfg_has "$proj" MERGE_METHOD merge
cfg_has "$proj" PR_FLOW draft
cfg_has "$proj" PR_READY_WHEN human
cfg_has "$proj" DELETE_BRANCH_ON_MERGE true
cfg_has "$proj" LOCAL_REVIEW none
cfg_lacks "$proj" HUMAN_VERIFY_POLICY
ok

# ── (8) solo-auto — equivalent to today's default: base keys only, no posture extras ─────────────
proj="$T/solo"; mkproj "$proj"
out="$( cd "$proj" && printf 'solo-auto\n' \
        | HERD_POSTURE_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init 2>&1 )" || fail "(8) init failed: $out"
assert_bundle "$proj" solo-auto
cfg_has "$proj" PR_FLOW direct
cfg_lacks "$proj" HUMAN_VERIFY_POLICY
cfg_lacks "$proj" PUSH_GATE
cfg_lacks "$proj" REVIEW_AUTOFIX
# Model map still hardcoded (never asked) — presence check.
cfg_has "$proj" MODEL_FEATURE claude-sonnet-4-6
ok

echo "ALL PASS ($pass checks)"
