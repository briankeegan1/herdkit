#!/usr/bin/env bash
# test-gate-scale.sh — hermetic proof of the GATE_SCALE (HERD-542) concurrency-derivation simulation
# (scripts/herd/sim/sandbox-gate-scale-scenario.sh), which drives the REAL watcher gate-cap functions
# (agent-watch.sh, sourced in lib mode) against N=8 simultaneous stub-builder worktrees.
#
# Asserts:
#   (a) END-TO-END — the scenario exits 0 and every checkpoint passes; a machine-readable
#       scorecard.json is emitted.
#   (b) BUILDER COUNT — the derivation's fleet-size input sees exactly 8 live builder worktrees, via
#       the SAME source herd-spawn-gate.sh's own spawn advisory reads.
#   (c) FLAG OFF, BYTE-IDENTICAL — GATE_SCALE=off resolves _review_conc/_health_conc to the
#       configured values exactly, with zero gate_scale journal lines and an empty console note.
#   (d) SCALED WITHIN BOUNDS + CEILING HONORED — GATE_SCALE=on derives caps inside [floor, ceiling]
#       matching ceil(builders/2), and a smaller cores-ceiling override actually caps the figure.
#   (e) FLOOR HONORED — an explicit operator REVIEW_CONCURRENCY above the ceiling is never lowered.
#   (f) JOURNAL-ONCE — an unchanged (review,health,builders) triple journals exactly once; a changed
#       triple (builder count moves) journals a second, distinct line.
#   (g) HERMETIC — the run leaves NO artifacts in the real repo tree.
#
# Fully hermetic: local git only, NO herdr, NO network, NO model. Mirrors the conventions of
# tests/test-sandbox-concurrency.sh.
# Run:  bash tests/test-gate-scale.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-gate-scale-scenario.sh"

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

# ── (a) END-TO-END + SCORECARD SHAPE (default N=8 builders) ─────────────────────
ART="$T/run"
bash "$SCENARIO" --artifacts "$ART" >"$T/run.out" 2>&1 \
  || fail "(a) gate-scale scenario exited non-zero"$'\n'"$(cat "$T/run.out")"

SCARD="$ART/scorecard.json"
[ -f "$SCARD" ] || fail "(a) scorecard.json not emitted at $SCARD"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCARD" || fail "(a) scorecard.json is not valid JSON"
[ "$(sc "$SCARD" scenario)" = "gate-scale-derivation" ] || fail "(a) unexpected scenario name"
[ "$(sc "$SCARD" result)" = "pass" ]                     || fail "(a) result should be pass"$'\n'"$(cat "$T/run.out")"
[ "$(sc "$SCARD" failed)" -eq 0 ]                        || fail "(a) failed should be 0 (got $(sc "$SCARD" failed))"
[ "$(sc "$SCARD" builders)" -eq 8 ]                      || fail "(a) default builders should be 8"
[ "$(cp_status "$SCARD" watcher_bound)" = "pass" ]        || fail "(a) watcher_bound not pass — GATE_SCALE functions not sourced"
echo "PASS (a) end-to-end drain + scorecard shape"

# ── (b) builder count ─────────────────────────────────────────────────────────
[ "$(cp_status "$SCARD" worktrees_opened)" = "pass" ]  || fail "(b) worktrees_opened not pass"
[ "$(cp_status "$SCARD" builders_counted)" = "pass" ]  || fail "(b) builders_counted not pass"
echo "PASS (b) builder-count primitive sees exactly 8 live worktrees"

# ── (c) flag off, byte-identical ──────────────────────────────────────────────
[ "$(cp_status "$SCARD" flag_off_values)" = "pass" ]           || fail "(c) flag_off_values not pass"
[ "$(cp_status "$SCARD" flag_off_byte_identical)" = "pass" ]   || fail "(c) flag_off_byte_identical not pass"
echo "PASS (c) GATE_SCALE=off is byte-identical (no derivation, no journal, no console note)"

# ── (d) scaled within bounds + ceiling honored ────────────────────────────────
[ "$(cp_status "$SCARD" scaled_within_bounds)" = "pass" ]  || fail "(d) scaled_within_bounds not pass"
[ "$(cp_status "$SCARD" ceiling_honored)" = "pass" ]       || fail "(d) ceiling_honored not pass"
echo "PASS (d) scaled caps land within [floor, ceiling] and the ceiling actually caps"

# ── (e) floor honored ─────────────────────────────────────────────────────────
[ "$(cp_status "$SCARD" floor_honored)" = "pass" ] || fail "(e) floor_honored not pass"
echo "PASS (e) an explicit operator value above the ceiling is never lowered by scaling"

# ── (f) journal-once ──────────────────────────────────────────────────────────
[ "$(cp_status "$SCARD" journal_once_unchanged)" = "pass" ]  || fail "(f) journal_once_unchanged not pass"
[ "$(cp_status "$SCARD" journal_once_on_change)" = "pass" ]  || fail "(f) journal_once_on_change not pass"
[ "$(cp_status "$SCARD" console_note_scaled)" = "pass" ]     || fail "(f) console_note_scaled not pass"
echo "PASS (f) gate_scale journals once per distinct (review,health,builders) triple"

# ── (g) HERMETIC — nothing leaked into the real repo tree ────────────────────
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "(g) scenario leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (g) hermetic — no leak into the real repo"

echo "ALL PASS (7/7 gate-scale checks: end-to-end, builder count, flag-off byte-identity, scaled+ceiling, floor honored, journal-once, hermetic)"
