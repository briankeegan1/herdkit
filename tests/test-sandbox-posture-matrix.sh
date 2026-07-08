#!/usr/bin/env bash
# test-sandbox-posture-matrix.sh — hermetic proof of the POSTURE MATRIX (HERD-153)
# (scripts/herd/sim/sandbox-posture-matrix.sh), which runs the SHIPPED gate loop under every canonical
# config posture (templates/postures.tsv) at zero quota and emits ONE scorecard per posture.
#
# Asserts:
#   (a) POSTURE DATA — templates/postures.tsv defines exactly the five canonical postures with the
#       expected config keys, and posture-lib.sh reads them.
#   (b) MATRIX GREEN — the wrapper exits 0, matrix.json shows 5/5 postures green, and each posture's
#       scorecard is result=pass with its posture-specific INVARIANT checkpoint(s) passing:
#         solo-auto → drain (queue_drained);  team-approve → no merge before a sha-keyed approval;
#         observe-only → never merges;  gated-push → nothing reaches the remote pre-approval;
#         custom-steps → an approve-stage hold releases exactly once per (sha,step).
#   (c) FAULT CAUGHT — the injected PR #249 defect (custom-steps + SANDBOX_FORCE_STEPS_FAULT=1) comes
#       back RED: result=fail, exit≠0, and EXACTLY one checkpoint (posture_invariant) flipped.
#   (d) SOLO-AUTO BYTE-IDENTICAL — --posture solo-auto has the SAME checkpoint (name,status) array as a
#       plain single-posture concurrency run (the default invocation is unchanged).
#   (e) HERMETIC — the whole matrix leaves NO new entry in the real repo tree.
#
# Fully hermetic: local git only, NO herdr, NO network, NO model, NO screenshots (opt-out). Mirrors
# tests/test-sandbox-concurrency.sh + tests/test-sandbox-governance.sh.
# Run:  bash tests/test-sandbox-posture-matrix.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MATRIX="$HERE/../scripts/herd/sim/sandbox-posture-matrix.sh"
GATE="$HERE/../scripts/herd/sim/sandbox-scenario.sh"
POSTURES="$HERE/../templates/postures.tsv"
PLIB="$HERE/../scripts/herd/sim/posture-lib.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
for f in "$MATRIX" "$GATE" "$POSTURES" "$PLIB"; do [ -f "$f" ] || fail "missing $f"; done

REPO_ROOT="$(cd "$HERE/.." && pwd)"
BASELINE_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"

sc()  { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
scg() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }
cp_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["checkpoints"]:
    if c["name"]==sys.argv[2]: print(c["status"]); break
' "$1" "$2"
}

# ── (a) POSTURE DATA + posture-lib ─────────────────────────────────────────────────
# shellcheck source=/dev/null
. "$PLIB"
POSTURES_FILE="$POSTURES"
_names="$(posture_names | tr '\n' ' ')"
for p in solo-auto team-approve gated-push custom-steps observe-only; do
  case " $_names " in *" $p "*) : ;; *) fail "(a) postures.tsv missing posture: $p" ;; esac
done
[ "$(posture_keys team-approve)" = "MERGE_POLICY=approve HUMAN_VERIFY_POLICY=hold" ] \
  || fail "(a) team-approve keys wrong: $(posture_keys team-approve)"
[ "$(posture_keys observe-only)" = "MERGE_POLICY=observe" ] || fail "(a) observe-only keys wrong"
case "$(posture_keys gated-push)" in *PUSH_GATE=human*) : ;; *) fail "(a) gated-push must set PUSH_GATE=human" ;; esac
[ "$(posture_steps_profile custom-steps)" = "approve-stage" ] || fail "(a) custom-steps STEPS_PROFILE wrong"
echo "PASS (a) postures.tsv defines the five canonical postures; posture-lib reads their keys"

# ── (b) MATRIX GREEN + per-posture invariants ──────────────────────────────────────
ART="$T/matrix"
SANDBOX_NO_SCREENSHOT=1 SANDBOX_REVIEW_DELAY=1 POSTURES_FILE="$POSTURES" \
  bash "$MATRIX" --artifacts "$ART" >"$T/matrix.out" 2>&1 \
  || fail "(b) matrix exited non-zero"$'\n'"$(cat "$T/matrix.out")"

MJ="$ART/matrix.json"
[ -f "$MJ" ] || fail "(b) matrix.json not emitted"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MJ" || fail "(b) matrix.json is not valid JSON"
[ "$(sc "$MJ" result)" = "pass" ]           || fail "(b) matrix result should be pass"
[ "$(sc "$MJ" postures_total)" -eq 5 ]      || fail "(b) postures_total should be 5"
[ "$(sc "$MJ" postures_green)" -eq 5 ]      || fail "(b) postures_green should be 5 (got $(sc "$MJ" postures_green))"

# Each posture's own scorecard: result=pass + its invariant checkpoint(s).
for p in solo-auto team-approve gated-push custom-steps observe-only; do
  card="$ART/$p/scorecard.json"
  [ -f "$card" ] || fail "(b) no scorecard for posture $p"
  [ "$(sc "$card" result)" = "pass" ]     || fail "(b) posture $p result should be pass"
  [ "$(scg "$card" posture)" = "$p" ]     || fail "(b) posture $p scorecard not tagged with posture=$p"
done
[ "$(cp_status "$ART/solo-auto/scorecard.json" queue_drained)" = "pass" ] \
  || fail "(b) solo-auto must fully drain (queue_drained pass)"
[ "$(cp_status "$ART/team-approve/scorecard.json" posture_approve_no_merge_preapproval)" = "pass" ] \
  || fail "(b) team-approve must not merge before an approval"
[ "$(cp_status "$ART/team-approve/scorecard.json" posture_approve_merges_only_approved)" = "pass" ] \
  || fail "(b) team-approve must merge only the approved PR"
[ "$(cp_status "$ART/observe-only/scorecard.json" posture_observe_never_merges)" = "pass" ] \
  || fail "(b) observe-only must never merge"
[ "$(sc "$ART/observe-only/scorecard.json" merges)" -eq 0 ] \
  || fail "(b) observe-only merges must be 0"
[ "$(cp_status "$ART/gated-push/scorecard.json" posture_invariant)" = "pass" ] \
  || fail "(b) gated-push posture_invariant must pass (nothing reaches the remote pre-approval)"
[ "$(cp_status "$ART/custom-steps/scorecard.json" posture_invariant)" = "pass" ] \
  || fail "(b) custom-steps posture_invariant must pass (release-once per sha,step)"
echo "PASS (b) matrix green 5/5 — every posture scorecard passes its own invariant"

# ── (c) FAULT CAUGHT — the injected #249 defect must go RED, flipping exactly posture_invariant ────
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fault_injection"]["caught"])' "$MJ")" = "yes" ] \
  || fail "(c) matrix.json must report the fault as caught"
# Re-run the fault leg directly to assert the fault-injection self-check contract precisely.
FART="$T/fault"
rc=0
SANDBOX_NO_SCREENSHOT=1 SANDBOX_REVIEW_DELAY=1 SANDBOX_FORCE_STEPS_FAULT=1 POSTURES_FILE="$POSTURES" \
  bash "$GATE" --posture custom-steps --artifacts "$FART" >"$T/fault.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "(c) forced-fault run must exit non-zero"
FC="$FART/scorecard.json"
[ -f "$FC" ] || fail "(c) fault scorecard not emitted"
[ "$(sc "$FC" result)" = "fail" ] || fail "(c) forced fault must yield result=fail"
[ "$(sc "$FC" failed)" -eq 1 ]    || fail "(c) forced fault must flip exactly 1 checkpoint (got $(sc "$FC" failed))"
_flipped="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(c["name"] for c in d["checkpoints"] if c["status"]=="fail"))' "$FC")"
[ "$_flipped" = "posture_invariant" ] || fail "(c) the flipped checkpoint must be posture_invariant (got: $_flipped)"
echo "PASS (c) injected PR #249 defect caught RED — exactly posture_invariant flipped"

# ── (d) SOLO-AUTO BYTE-IDENTICAL ────────────────────────────────────────────────────
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["solo_auto_byte_identical"])' "$MJ")" = "yes" ] \
  || fail "(d) matrix.json must report solo-auto byte-identical"
echo "PASS (d) solo-auto byte-identical to a plain single-posture concurrency run"

# ── (e) HERMETIC — nothing leaked into the real repo tree ────────────────────────────
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "(e) matrix leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (e) hermetic — no leak into the real repo"

echo "ALL PASS"
