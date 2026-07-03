#!/usr/bin/env bash
# test-watcher-health-cache.sh — hermetic test for the healthcheck sha-cache policy in the watcher's
# _healthcheck_gate (issue #78 part 2). The sha-cache (PR #66) records a TERMINAL health verdict keyed
# to the commit sha and replays it every tick. A tab-leak-guard CODEERROR, however, is INFRA/TRANSIENT:
# a concurrent SAME-workspace sibling builder tab flickering non-idle during the healthcheck window can
# trip the guard on both the initial run and the solo retry, yet self-heals once that tab stabilizes.
# Caching it FREEZES the row red until a human deletes the marker. This test asserts:
#   • a tab-leak-guard CODEERROR is NOT written to the sha health-result cache (next tick re-runs) …
#   • … while a NORMAL (non-tab-leak) code-error IS cached (stays red without re-running).
# It sources agent-watch.sh's helpers via the AGENT_WATCH_LIB guard (no live loop), stubs the
# healthcheck binary on disk (NETWORK-FREE, no herdr, no repo), and inspects the on-disk cache marker.
# Run:  bash tests/test-watcher-health-cache.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# Source the watcher's helpers WITHOUT its live loop. Point config discovery at a nonexistent file so
# herd-config.sh falls back to its generic defaults — fully hermetic, no repo/.herd walk-up.
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type _healthcheck_gate >/dev/null 2>&1 || fail "_healthcheck_gate not defined after sourcing"

# Redirect all cache/state I/O into the temp dir and silence the frame renderer (it would clear the
# screen). These override whatever the sourced config resolved.
TREES="$T"
HEALTH_STATE="$T/.agent-watch-healthchecks"
render() { :; }
declare -a DISPLAY=()

# Stub the healthcheck binary: emit $HC_ONELINE and exit $HC_RC. _healthcheck_gate runs it twice (the
# initial run + the solo retry-before-red); returning rc 1 both times reproduces a terminal CODEERROR.
HC_STUB="$T/healthcheck-stub.sh"
cat > "$HC_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${HC_ONELINE:-}"
exit "${HC_RC:-0}"
STUB
chmod +x "$HC_STUB"
export HERD_HEALTHCHECK_BIN="$HC_STUB"

SHA="deadbeefcafe"

# run_gate <pr#> <oneline> <rc> — drive the gate once with a fresh cache slate for this pr+sha.
run_gate() {
  rm -f "$(_health_result_file "$1" "$SHA")" 2>/dev/null || true
  rm -f "$TREES"/.health-inflight-* 2>/dev/null || true
  export HC_ONELINE="$2" HC_RC="$3"
  _HC_RESULT=""
  _healthcheck_gate "$1" "slug$1" "$T/wt" 0 "$SHA"
}

# ── 1. tab-leak-guard CODEERROR → verdict red THIS tick, but NOT cached (self-heals next tick) ──────
run_gate 1 "tab-leak-guard: suite leaked an orphan tab into the live workspace — orphan tabs 3->4" 1
[ "$_HC_RESULT" = "CODEERROR" ] || fail "tab-leak reproduced → _HC_RESULT should be CODEERROR (got '$_HC_RESULT')"
[ -f "$(_health_result_file 1 "$SHA")" ] && \
  fail "tab-leak-guard CODEERROR must NOT be written to the sha cache (it froze red — issue #78)"
ok

# ── 2. a normal (non-tab-leak) code error → CODEERROR AND cached, exactly as today ──────────────────
run_gate 2 "pytest: 3 failed in tests/test_thing.py" 1
[ "$_HC_RESULT" = "CODEERROR" ] || fail "normal code error → _HC_RESULT should be CODEERROR (got '$_HC_RESULT')"
cache2="$(_health_result_file 2 "$SHA")"
[ -f "$cache2" ] || fail "a genuine non-tab-leak code error MUST be cached (regression guard)"
IFS=$'\t' read -r cv cd < "$cache2"
[ "$cv" = "CODEERROR" ] || fail "cached verdict should be CODEERROR (got '$cv')"
case "$cd" in *pytest*) : ;; *) fail "cached detail should carry the code-error oneline (got '$cd')" ;; esac
ok

# ── 3. sanity: a CLEAN run is still cached (the fix touches only the CODEERROR branch) ──────────────
run_gate 3 "" 0
[ "$_HC_RESULT" = "CLEAN" ] || fail "clean run → _HC_RESULT should be CLEAN (got '$_HC_RESULT')"
[ -f "$(_health_result_file 3 "$SHA")" ] || fail "a CLEAN verdict must still be cached"
ok

echo "ALL PASS ($pass checks)"
