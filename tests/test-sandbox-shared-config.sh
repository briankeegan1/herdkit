#!/usr/bin/env bash
# test-sandbox-shared-config.sh — hermetic proof of the HERD-74 SHARED-CONFIG ADOPTION simulation
# (scripts/herd/sim/sandbox-shared-config-scenario.sh). That scenario runs the REAL
# `herd config set --shared` and then drives the REAL watcher gate loop (agent-watch.sh, sourced in
# lib mode) over the worktree it leaves in the pool — proving a `config/<key>` branch with NO
# pre-existing worktree gets ADOPTED, GATED, MERGED, and REAPED (the gap that left PRs #190/#191
# ungated). agent-watch.sh discovers work via `git worktree list`, not open PRs.
#
# Asserts:
#   (a) END-TO-END — the scenario exits 0, emits a valid scorecard.json, every checkpoint passes,
#       and the fix's key checkpoints (worktree_persisted, discovered_by_watcher, gated_and_merged,
#       reaped) are all `pass`.
#   (b) MERGE ACCOUNTING — merged == true, merges == 1 (no double-merge), healthcheck_runs >= 1
#       (the adopted worktree really went through the gate, not skipped).
#   (c) HERMETIC — the run leaves NO new entry in the real repo tree and touches no real gh/panes.
#
# Fully hermetic: local git only (fixture repo + its own bare origin), NO herdr, NO network, NO model.
# Mirrors tests/test-sandbox-concurrency.sh.
# Run:  bash tests/test-sandbox-shared-config.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-shared-config-scenario.sh"

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

# ── (a) END-TO-END + SCORECARD SHAPE + fix checkpoints ──────────────────────────
ART="$T/run"
SANDBOX_REVIEW_DELAY=1 bash "$SCENARIO" --artifacts "$ART" >"$T/out" 2>&1 \
  || fail "(a) scenario exited non-zero"$'\n'"$(cat "$T/out")"

SCARD="$ART/scorecard.json"
[ -f "$SCARD" ] || fail "(a) scorecard.json not emitted at $SCARD"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCARD" || fail "(a) scorecard.json is not valid JSON"
[ "$(sc "$SCARD" scenario)" = "stub-shared-config-adoption" ] || fail "(a) unexpected scenario name"
[ "$(sc "$SCARD" result)" = "pass" ]                          || fail "(a) result should be pass"
[ "$(sc "$SCARD" failed)" -eq 0 ]                             || fail "(a) failed should be 0 (got $(sc "$SCARD" failed))"
[ "$(sc "$SCARD" passed)" -ge 1 ]                             || fail "(a) passed should be >= 1"
for c in fixture_built shared_pr_opened worktree_persisted watcher_bound \
         discovered_by_watcher gated_and_merged reaped; do
  [ "$(cp_status "$SCARD" "$c")" = "pass" ] || fail "(a) checkpoint '$c' not pass ($(cp_status "$SCARD" "$c"))"
done
echo "PASS (a) end-to-end adoption: worktree_persisted → discovered → gated_and_merged → reaped"

# ── (b) MERGE ACCOUNTING — merged once, gate really ran ──────────────────────────
[ "$(sc "$SCARD" merged)" = "True" ]           || fail "(b) merged must be true (got $(sc "$SCARD" merged))"
[ "$(sc "$SCARD" merges)" -eq 1 ]              || fail "(b) merges must be exactly 1 (got $(sc "$SCARD" merges))"
[ "$(sc "$SCARD" healthcheck_runs)" -ge 1 ]    || fail "(b) the adopted worktree's healthcheck must have run"
[ "$(sc "$SCARD" branch)" = "config/CLAIM_REQUIRED" ] || fail "(b) unexpected branch under test"
echo "PASS (b) adopted config PR merged exactly once through the real gate"

# ── (c) HERMETIC — nothing leaked into the real repo tree ────────────────────────
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "(c) scenario leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (c) hermetic — no leak into the real repo"

echo "ALL PASS"
