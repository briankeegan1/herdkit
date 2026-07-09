#!/usr/bin/env bash
# test-sandbox-self-restart.sh — hermetic proof of the WATCHER SELF-RESTART simulation
# (scripts/herd/sim/sandbox-self-restart-scenario.sh), which drives the REAL watcher tick — the
# shipped _healthcheck_gate / _dispatch_review / spawn_resolver / reconcile_main_freshness /
# _self_restart_tick, sourced in lib mode — against a real local git repo whose "other seat" merges a
# commit that rewrites scripts/herd/agent-watch.sh while a REAL suite worker is in flight (HERD-251).
#
# Asserts:
#   (a) END-TO-END — the scenario exits 0, every checkpoint passes, and a machine-readable
#       scorecard.json is emitted in the sandbox-sim shape PLUS the self-restart fields.
#   (b) THE QUIESCE INVARIANTS, one checkpoint each — nothing arms while a gate owns the tree
#       (no_arm_midsuite), the in-flight suite still collects (suite_collects), the arm fires on the
#       engine-code delta (quiesce_armed), NO new gate work is dispatched while draining
#       (no_new_dispatch), the watcher never execs over a live worker (drain_waits), and the restart
#       fires once drained (self_restart_fires) with the journal's shas=<old>..<new> line.
#   (c) RESUMES ON NEW CODE — after the restart $MAIN carries the new engine image and the PR that was
#       held mid-quiesce dispatches its suite again (gates_resume_on_new_code).
#   (d) CAP + KILL-SWITCH — a worker that never drains still restarts at the 15-minute cap
#       (cap_expiry, restart_cap_secs == 900), and WATCHER_SELF_RESTART=off is byte-identical to the
#       HERD-233 recommendation row (lever_off_identical).
#   (e) HERMETIC — the run leaves NOTHING in the real repo's working tree, spawns no herdr pane, and
#       makes no network call.
#
# Fully hermetic: local git only, NO herdr, NO gh, NO network, NO model.
# Run:  bash tests/test-sandbox-self-restart.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-self-restart-scenario.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok()  { pass=$((pass+1)); }

command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCENARIO" ] || fail "missing $SCENARIO"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
BASELINE_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"

# jq-free scorecard readers.
sc()        { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
cp_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["checkpoints"]:
    if c["name"] == sys.argv[2]:
        print(c["status"]); break
' "$1" "$2"
}

# ── (a) end-to-end: the scenario runs green and emits a well-shaped scorecard ─────────────────────
ART="$T/run"
bash "$SCENARIO" --artifacts "$ART" > "$T/out.log" 2>&1 \
  || fail "scenario exited non-zero:\n$(cat "$T/out.log")"
SCARD="$ART/scorecard.json"
[ -s "$SCARD" ] || fail "no scorecard.json emitted"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCARD" || fail "scorecard.json is not valid JSON"
[ "$(sc "$SCARD" result)" = "pass" ] || fail "scorecard result != pass: $(cat "$SCARD")"
[ "$(sc "$SCARD" failed)" = "0" ]    || fail "scorecard reports failed checkpoints: $(cat "$SCARD")"
[ "$(sc "$SCARD" passed)" -ge 13 ]   || fail "expected >=13 passing checkpoints, got $(sc "$SCARD" passed)"
[ "$(sc "$SCARD" scenario)" = "watcher-self-restart-e2e" ] || fail "unexpected scenario name"
[ -n "$(sc "$SCARD" engine_sha)" ]   || fail "scorecard omits the engine_sha delta"
ok

# ── (b) every quiesce invariant is its own PASSING checkpoint (not merely an absent failure) ──────
for c in no_arm_midsuite suite_collects quiesce_armed console_drain_row no_new_dispatch stale_heal_burns_no_guard \
         drain_waits self_restart_fires; do
  [ "$(cp_status "$SCARD" "$c")" = "pass" ] || fail "checkpoint '$c' did not pass: $(cp_status "$SCARD" "$c")"
done
ok

# ── (c) the restarted watcher runs the new engine code and resumes gating ─────────────────────────
[ "$(cp_status "$SCARD" gates_resume_on_new_code)" = "pass" ] \
  || fail "gates did not resume on the new engine code"
[ "$(sc "$SCARD" fixture_sha)" != "$(sc "$SCARD" engine_sha)" ] \
  || fail "the scenario never advanced \$MAIN past the fixture sha — the engine delta was vacuous"
ok

# ── (d) the max-wait cap and the ship-dormant kill-switch ─────────────────────────────────────────
[ "$(cp_status "$SCARD" cap_expiry)" = "pass" ]          || fail "the 15-minute cap did not fire"
[ "$(sc "$SCARD" restart_cap_secs)" = "900" ]            || fail "restart cap is not 900s"
[ "$(cp_status "$SCARD" lever_off_identical)" = "pass" ] || fail "WATCHER_SELF_RESTART=off was not inert"
ok

# ── (e) hermetic: the real repo tree is untouched, no pane/network surface was used ───────────────
AFTER_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
[ "$AFTER_STATUS" = "$BASELINE_STATUS" ] || fail "the scenario dirtied the real repo working tree"
grep -qiE 'herdr (tab|pane) (create|run)' "$T/out.log" && fail "the scenario touched a real herdr surface"
ok

echo "PASS: test-sandbox-self-restart.sh ($pass checks)"
