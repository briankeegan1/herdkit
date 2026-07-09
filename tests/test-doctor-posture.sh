#!/usr/bin/env bash
# test-doctor-posture.sh — hermetic tests for the CONFIG-POSTURE doctor (HERD-154): `herd doctor
# --posture`, the deterministic, no-LLM, report-only lint in scripts/herd/posture-lint.sh. Drives the
# real `bin/herd doctor --posture` against synthetic .herd/config fixtures (HERD_SKIP_PREFLIGHT=1 so no
# real herdr is needed) and asserts:
#   (1) a planted INCOHERENT combo (WATCHER_AUTOMERGE contradicting MERGE_POLICY) is flagged with a fix
#   (2) the coherence lint's OTHER derived rules fire (WATCHER_OWNER under scope=mine; LOCAL_REVIEW_GLOB
#       without risk-scoped; REVIEW_MODEL_CHEAP without REVIEW_ESCALATE_GLOB)
#   (3) a CLEAN config matching a canonical posture reports ✓ no-incoherence AND names the exercised
#       posture (solo-auto) + its posture-matrix sim proof
#   (4) an UNEXERCISED effective posture is named as matching NO canonical posture, with the closest one
#   (5) a custom .herd/steps.tsv maps to the custom-steps posture (exercised)
#   (6) report-only: `herd doctor --posture` ALWAYS exits 0, even with incoherent config (never a gate)
#   (7) `herd doctor` (no flag) still runs the DEPENDENCY doctor, unaffected by this change
#
# No `set -e`: assertions check output + exit codes explicitly. Run:  bash tests/test-doctor-posture.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$REPO/scripts/herd/posture-lint.sh" ] || { echo "FAIL: posture-lint.sh missing" >&2; exit 1; }
[ -f "$REPO/templates/postures.tsv" ]        || { echo "FAIL: postures.tsv missing" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# mkproj <name> — fresh project dir with a .herd/; echoes its path. Config is written by the caller.
mkproj() { local d="$T/$1"; rm -rf "$d"; mkdir -p "$d/.herd"; printf '%s' "$d"; }
# write_cfg <projdir> <lines...> — write a .herd/config with PROJECT_ROOT pinned + the given KEY=VALUEs.
write_cfg() {
  local d="$1"; shift
  { printf 'PROJECT_ROOT="%s"\n' "$d"; local kv; for kv in "$@"; do printf '%s\n' "$kv"; done; } > "$d/.herd/config"
}
# run_posture <projdir> — run `herd doctor --posture` from the project dir; echo output, RETURN exit.
run_posture() {
  ( cd "$1" && HERD_SKIP_PREFLIGHT=1 HERD_SKIP_DOCTOR=0 bash "$HERD" doctor --posture 2>&1 )
}

# ── (1) planted incoherent combo: WATCHER_AUTOMERGE contradicts MERGE_POLICY ──────────────────────
p="$(mkproj p1)"; write_cfg "$p" 'MERGE_POLICY="approve"' 'WATCHER_AUTOMERGE="true"'
out="$(run_posture "$p")"; RC=$?
[ "$RC" -eq 0 ] || fail "(1) --posture must exit 0 (got $RC): $out"
grep -qi "WATCHER_AUTOMERGE.*CONTRADICTS MERGE_POLICY" <<<"$out" || fail "(1) contradiction not flagged: $out"
grep -qi "fix:.*delete WATCHER_AUTOMERGE" <<<"$out"             || fail "(1) no fix hint for the contradiction: $out"
ok

# ── (2) the other derived coherence rules fire on a config that trips each ─────────────────────────
p="$(mkproj p2)"; write_cfg "$p" \
  'WATCHER_OWNER="alice"' \
  'LOCAL_REVIEW_GLOB="src/.*"' \
  'REVIEW_MODEL_CHEAP="claude-haiku-4-5"'
out="$(run_posture "$p")"; RC=$?
[ "$RC" -eq 0 ] || fail "(2) --posture must exit 0 (got $RC): $out"
grep -qi "WATCHER_OWNER is set but WATCHER_SCOPE=mine"          <<<"$out" || fail "(2) WATCHER_OWNER rule missing: $out"
grep -qi "LOCAL_REVIEW_GLOB is set but LOCAL_REVIEW=none"       <<<"$out" || fail "(2) LOCAL_REVIEW_GLOB rule missing: $out"
grep -qi "REVIEW_MODEL_CHEAP is set but REVIEW_ESCALATE_GLOB is blank" <<<"$out" || fail "(2) REVIEW tiering rule missing: $out"
ok

# ── (3) clean config on a canonical posture: no incoherence + names the exercised posture ─────────
# solo-auto = MERGE_POLICY=auto → the fixture default. A bare config (defaults) lands on solo-auto.
p="$(mkproj p3)"; write_cfg "$p" 'MERGE_POLICY="auto"'
out="$(run_posture "$p")"; RC=$?
[ "$RC" -eq 0 ] || fail "(3) --posture must exit 0 (got $RC): $out"
grep -qi "no incoherent knob combinations detected" <<<"$out" || fail "(3) clean config not reported clean: $out"
grep -qi "matches the 'solo-auto' posture"          <<<"$out" || fail "(3) exercised posture not named: $out"
grep -qi "sandbox-posture-matrix"                   <<<"$out" || fail "(3) posture-matrix sim proof not cited: $out"
ok

# ── (4) unexercised effective posture: matches NO canonical posture, names the closest ────────────
# approve + push-gate=human is a mix of team-approve and gated-push — no single canonical posture.
p="$(mkproj p4)"; write_cfg "$p" 'MERGE_POLICY="approve"' 'PUSH_GATE="human"'
out="$(run_posture "$p")"; RC=$?
[ "$RC" -eq 0 ] || fail "(4) --posture must exit 0 (got $RC): $out"
grep -qi "matches NO canonical posture"     <<<"$out" || fail "(4) unexercised posture not named: $out"
grep -qi "NOT exercised by the posture-matrix sim" <<<"$out" || fail "(4) honesty line missing: $out"
grep -qi "closest canonical posture"        <<<"$out" || fail "(4) closest posture not named: $out"
ok

# ── (5) a custom .herd/steps.tsv maps to the custom-steps posture (exercised) ──────────────────────
p="$(mkproj p5)"; write_cfg "$p" 'MERGE_POLICY="auto"'
# a non-empty steps.tsv (one real row) — the custom-steps dimension is "steps present", not its content.
printf '# a comment\napprove-stage\tpre_merge\ttrue\tapprove\n' > "$p/.herd/steps.tsv"
out="$(run_posture "$p")"; RC=$?
[ "$RC" -eq 0 ] || fail "(5) --posture must exit 0 (got $RC): $out"
grep -qi "custom-steps=yes"                 <<<"$out" || fail "(5) steps.tsv not detected in tuple: $out"
grep -qi "matches the 'custom-steps' posture" <<<"$out" || fail "(5) custom-steps posture not matched: $out"
ok

# ── (6) report-only: even a maximally incoherent config exits 0 (never a gate) ─────────────────────
p="$(mkproj p6)"; write_cfg "$p" \
  'MERGE_POLICY="observe"' 'WATCHER_AUTOMERGE="false"' 'WATCHER_OWNER="bob"' \
  'LOCAL_REVIEW_GLOB="x"' 'REVIEW_MODEL_DOCS="claude-haiku-4-5"'
out="$(run_posture "$p")"; RC=$?
[ "$RC" -eq 0 ] || fail "(6) --posture must exit 0 even when incoherent (got $RC): $out"
grep -qi "report-only" <<<"$out" || fail "(6) report-only footer missing: $out"
ok

# ── (7) `herd doctor` (no flag) still runs the dependency doctor, unaffected ───────────────────────
# HERD_SKIP_DOCTOR=1 makes the dependency doctor a silent pass — proving the no-flag path still routes
# to herd_doctor (not the posture path, which ignores HERD_SKIP_DOCTOR and always prints).
p="$(mkproj p7)"; write_cfg "$p" 'MERGE_POLICY="auto"'
out="$( cd "$p" && HERD_SKIP_PREFLIGHT=1 HERD_SKIP_DOCTOR=1 bash "$HERD" doctor 2>&1 )"; RC=$?
[ "$RC" -eq 0 ] || fail "(7) plain 'herd doctor' with HERD_SKIP_DOCTOR=1 should pass (got $RC): $out"
grep -qi "config coherence" <<<"$out" && fail "(7) plain 'herd doctor' wrongly ran the posture lint: $out"
# and an unknown flag is a clear usage error
out="$( cd "$p" && HERD_SKIP_PREFLIGHT=1 bash "$HERD" doctor --bogus 2>&1 )"; RC=$?
[ "$RC" -ne 0 ] || fail "(7) unknown doctor flag should error (got 0): $out"
grep -qi "usage: herd doctor" <<<"$out" || fail "(7) no usage message for a bad flag: $out"
ok

echo "ALL PASS ($pass checks)"
