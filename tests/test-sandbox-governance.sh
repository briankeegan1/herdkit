#!/usr/bin/env bash
# test-sandbox-governance.sh — hermetic proof of the HERD-127 end-to-end GOVERNANCE simulation
# (scripts/herd/sim/sandbox-governance-scenario.sh). That scenario proves the whole
# import→enforcement chain at zero quota: a fixture consumer's CLAUDE.md carries an operator ruleset,
# the REAL HERD-119 adoption table maps each sentence to a KEY=VALUE, and — with those keys applied —
# the shipped gates (PUSH_GATE HERD-123, ATTRIBUTION_POLICY HERD-121, BRANCH_TEMPLATE HERD-120,
# COMMIT_CONVENTION HERD-124) actually bind. Zero model calls, deterministic, no network/herdr.
#
# Asserts:
#   (a) END-TO-END — the scenario exits 0, emits a valid scorecard.json, every checkpoint passes, and
#       each consumed-feature checkpoint (adopt_*, push_gate_*, attribution_red_names_sha,
#       branch_template_refuses_nonconforming, commit_convention_refuses_nonconforming,
#       reset_byte_identical, zero_model_calls) is `pass`.
#   (b) FIELD ACCOUNTING — mapped_keys == 4, model_calls == 0, and the enforcement flags are all true.
#   (c) NEGATIVE LEG — SANDBOX_FORCE_GOVERNANCE_FAIL=1 flips exactly one assertion: the scenario exits
#       non-zero, result == "fail", failed == 1, attribution_red == false (fails LOUDLY, not silently).
#   (d) DETERMINISM — two happy runs agree on the fixture_sha and the offending_sha (reset contract).
#   (e) HERMETIC — the run leaves NO new entry in the real repo tree and makes no real model call.
#
# Fully hermetic: local git only, NO herdr, NO network, NO model. Mirrors tests/test-sandbox-shared-config.sh.
# Run:  bash tests/test-sandbox-governance.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-governance-scenario.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCENARIO" ] || fail "missing $SCENARIO"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
BASELINE_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"

sc() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
cp_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["checkpoints"]:
    if c["name"]==sys.argv[2]: print(c["status"]); break
' "$1" "$2"
}

# ── (a) END-TO-END + SCORECARD SHAPE + consumed-feature checkpoints ───────────────
ART="$T/run"
bash "$SCENARIO" --artifacts "$ART" >"$T/out" 2>&1 \
  || fail "(a) scenario exited non-zero"$'\n'"$(cat "$T/out")"

SCARD="$ART/scorecard.json"
[ -f "$SCARD" ] || fail "(a) scorecard.json not emitted at $SCARD"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCARD" || fail "(a) scorecard.json is not valid JSON"
[ "$(sc "$SCARD" scenario)" = "stub-governance-e2e" ] || fail "(a) unexpected scenario name"
[ "$(sc "$SCARD" result)" = "pass" ]                  || fail "(a) result should be pass"
[ "$(sc "$SCARD" failed)" -eq 0 ]                     || fail "(a) failed should be 0 (got $(sc "$SCARD" failed))"
[ "$(sc "$SCARD" passed)" -ge 1 ]                     || fail "(a) passed should be >= 1"
for c in fixture_built adopt_statements_extracted adopt_push_gate adopt_attribution \
         adopt_branch_template adopt_commit_convention push_gate_held_no_push push_gate_resumed \
         attribution_clean_baseline attribution_red_names_sha \
         branch_template_refuses_nonconforming commit_convention_refuses_nonconforming \
         reset_byte_identical zero_model_calls; do
  [ "$(cp_status "$SCARD" "$c")" = "pass" ] || fail "(a) checkpoint '$c' not pass ($(cp_status "$SCARD" "$c"))"
done
echo "PASS (a) end-to-end chain: adopt → push-gate → attribution → convention → reset, all pass"

# ── (b) FIELD ACCOUNTING — mapped keys, zero model calls, enforcement flags ───────
[ "$(sc "$SCARD" mapped_keys)" -eq 4 ]        || fail "(b) mapped_keys must be 4 (got $(sc "$SCARD" mapped_keys))"
[ "$(sc "$SCARD" model_calls)" -eq 0 ]        || fail "(b) model_calls must be 0 (got $(sc "$SCARD" model_calls))"
[ "$(sc "$SCARD" push_held)"       = "True" ] || fail "(b) push_held must be true"
[ "$(sc "$SCARD" push_resumed)"    = "True" ] || fail "(b) push_resumed must be true"
[ "$(sc "$SCARD" attribution_red)" = "True" ] || fail "(b) attribution_red must be true"
[ "$(sc "$SCARD" branch_refused)"  = "True" ] || fail "(b) branch_refused must be true"
[ "$(sc "$SCARD" commit_refused)"  = "True" ] || fail "(b) commit_refused must be true"
[ "$(sc "$SCARD" reset_identical)" = "True" ] || fail "(b) reset_identical must be true"
[ -n "$(sc "$SCARD" offending_sha)" ]         || fail "(b) offending_sha must be recorded"
echo "PASS (b) field accounting: 4 keys mapped, 0 model calls, every gate bound"

# ── (c) NEGATIVE LEG — the force flag flips exactly one assertion, fails LOUDLY ────
ARTF="$T/fault"
rc=0
SANDBOX_FORCE_GOVERNANCE_FAIL=1 bash "$SCENARIO" --artifacts "$ARTF" >"$T/fout" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "(c) forced-fault run must exit non-zero"
SCF="$ARTF/scorecard.json"
[ -f "$SCF" ] || fail "(c) fault scorecard.json not emitted"
[ "$(sc "$SCF" scenario)" = "stub-governance-fault" ] || fail "(c) fault scenario name wrong"
[ "$(sc "$SCF" result)" = "fail" ]                    || fail "(c) forced fault must yield result=fail"
[ "$(sc "$SCF" failed)" -eq 1 ]                       || fail "(c) forced fault must flip exactly 1 checkpoint (got $(sc "$SCF" failed))"
[ "$(sc "$SCF" attribution_red)" = "False" ]          || fail "(c) forced fault must leave attribution_red false"
[ "$(cp_status "$SCF" attribution_red_names_sha)" = "fail" ] || fail "(c) the flipped checkpoint must be attribution_red_names_sha"
echo "PASS (c) negative leg: force flag fails loudly (exit≠0, result=fail, exactly 1 flipped)"

# ── (d) DETERMINISM — a second happy run agrees on fixture + offending sha ─────────
ART2="$T/run2"
bash "$SCENARIO" --artifacts "$ART2" >/dev/null 2>&1 || fail "(d) second run exited non-zero"
[ "$(sc "$SCARD" fixture_sha)"   = "$(sc "$ART2/scorecard.json" fixture_sha)" ]   || fail "(d) fixture_sha not deterministic"
[ "$(sc "$SCARD" offending_sha)" = "$(sc "$ART2/scorecard.json" offending_sha)" ] || fail "(d) offending_sha not deterministic"
echo "PASS (d) deterministic — fixture_sha and offending_sha stable across runs"

# ── (e) HERMETIC — nothing leaked into the real repo tree ─────────────────────────
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "(e) scenario leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (e) hermetic — no leak into the real repo"

echo "ALL PASS"
