#!/usr/bin/env bash
# test-watcher-leakguard-exemption.sh — hermetic test of the tab-leak-guard exemption (HERD-228).
#
# The watcher exempts a tab-leak-guard trip from the sha-cache, from the builder bounce, and from
# MAIN RED, because it is transient control-room churn (issue #78), not a code bug. The exemption used
# to be a bare `grep -q tab-leak-guard <log>`, and tests/herd.bats contains tests NAMED
# "hermetic tab-leak-guard …" — so their PASSING TAP lines ("ok 29 hermetic tab-leak-guard …") made
# EVERY reproduced bats red look like the transient: the red row quoted a passing test, the verdict was
# never cached, and the gate re-dispatched the suite every tick forever (PR #333). On the main-health
# side the same string match routed a genuine bats red to infra_event, so MAIN RED could never paint.
#
# Asserted here, against the ONE shared classifier both surfaces now consult:
#   (1) a log with passing 'ok N …tab-leak-guard…' lines + a later 'not ok X' is NOT a leak-guard trip;
#       the gate quotes the not-ok line, sha-caches it, and _handle_health_codeerror bounces the builder
#   (2) a REAL leak-guard trip log (both the full-mode and the --oneline shapes) still classifies infra:
#       not cached, no bounce, legacy row preserved
#   (3) a bats red on main paints MAIN RED, while a real trip on main stays an infra_event
#   (4) the exempted red's re-dispatch loop is BOUNDED: at the cap it caches an escalation tag and the
#       row becomes needs-you (still no bounce)
#   (5) _HFD_PASS_RE drops RUNNER-PREFIXED pass lines ('bats: ok 29 …') from the fail-detail fallback
#
# Hermetic: sources agent-watch.sh via the AGENT_WATCH_LIB guard (no live loop), stubs herdr + the
# healthcheck binary on disk, and pins every state/journal path into a temp dir. No network, no repo,
# no herdr control room.  Run:  bash tests/test-watcher-leakguard-exemption.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# Stub herdr: the red row consults builder liveness (_active_fix_note) and a hermetic test must never
# reach the live control room. "no agents" is the nobody-is-on-it case the needs-you rows assert.
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\necho '"'"'{"result":{"agents":[]}}'"'"'\nexit 0\n' > "$BIN/herdr"
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type _health_leak_guard_red >/dev/null 2>&1 || fail "_health_leak_guard_red not defined after sourcing"
type _health_is_leak_guard_detail >/dev/null 2>&1 || fail "_health_is_leak_guard_detail not defined"

# Pin every state/journal path into the sandbox (see issue #144: journal_append resolves its path from
# WORKTREES_DIR, not TREES — bind BOTH, plus the explicit JOURNAL_FILE seam).
TREES="$T"
WORKTREES_DIR="$T"
export JOURNAL_FILE="$T/journal.jsonl"
HEALTH_STATE="$T/.agent-watch-healthchecks"
MAIN_HEALTH_STATE="$T/.agent-watch-main-health"
REFIX_STATE="$T/.agent-watch-refixed"
render() { :; }
declare -a DISPLAY=()
mkdir -p "$T/wt"

case "$(_journal_file)" in
  "$T"/*) : ;;
  *) fail "journal path escapes the sandbox (issue #144)" ;;
esac

# ── fixture logs ────────────────────────────────────────────────────────────────────────────────────
# The live incident: bats prints its plan, PASSES the leak-guard-NAMED tests, then fails a real one.
BATS_RED="$T/bats-red.log"
cat > "$BATS_RED" <<'LOG'
❌ CODE ERROR
1..76
ok 29 hermetic tab-leak-guard engine-whitelist test passes
ok 30 hermetic tab-leak-guard deflake (HERD-93) test passes
not ok 41 hermetic watcher health-cache test passes
# (in test file tests/herd.bats, line 300)
LOG

# A real trip, full (non --oneline) mode: the guard prints ANCHORED at column 0, and the suite that
# leaked the tab may well have PASSED every one of its TAP assertions.
TRIP_FULL="$T/trip-full.log"
cat > "$TRIP_FULL" <<'LOG'
❌ CODE ERROR
1..76
ok 29 hermetic tab-leak-guard engine-whitelist test passes
TAB-LEAK-GUARD: the test suite left an orphan tab/pane in the live workspace
  (a hermetic test escaped its stubs and created a real, agent-less herdr tab)
  orphan tabs 3 -> 4
LOG

# A real trip, --oneline mode: healthcheck.sh prefixes its own "❌ code error — " classifier.
TRIP_ONELINE="$T/trip-oneline.log"
printf '%s\n' "❌ code error — tab-leak-guard: suite leaked an orphan tab into the live workspace — orphan tabs 3 -> 4" > "$TRIP_ONELINE"

# A clean suite whose leak-guard NOTE names the guard: never a trip.
CLEAN_NOTE="$T/clean-note.log"
cat > "$CLEAN_NOTE" <<'LOG'
HEALTHCHECK CLEAN
  tests: hermetic suite pass
  tab-leak-guard: clean
LOG

# ── 1. the classifier itself ────────────────────────────────────────────────────────────────────────
_health_leak_guard_red "$BATS_RED" && fail "(1) a bats red with PASSING tab-leak-guard-named tests must not be a trip"
_health_leak_guard_red "$TRIP_FULL" || fail "(1) the full-mode guard failure line must be a trip"
_health_leak_guard_red "$TRIP_ONELINE" || fail "(1) the --oneline guard failure line must be a trip"
_health_leak_guard_red "$CLEAN_NOTE" && fail "(1) 'tab-leak-guard: clean' is a note, not a trip"
_health_leak_guard_red "$T/no-such.log" && fail "(1) a missing log must fail soft (not a trip)"
[ "$(_health_leak_guard_line "$TRIP_FULL")" = "TAB-LEAK-GUARD: the test suite left an orphan tab/pane in the live workspace" ] \
  || fail "(1) the trip detail must be the guard's own failure line"
# the detail-string form, as the gate seams see it
_health_is_leak_guard_detail "ok 29 hermetic tab-leak-guard engine-whitelist test passes" \
  && fail "(1) a PASSING TAP line naming the guard must never classify as a trip"
_health_is_leak_guard_detail "not ok 41 hermetic tab-leak-guard deflake test passes" \
  && fail "(1) a FAILING TAP line naming the guard is a code error, not a trip"
_health_is_leak_guard_detail "❌ tab-leak-guard: 1 unexpected tab" \
  || fail "(1) the legacy oneline trip detail must still classify as a trip"
_health_is_leak_guard_detail "" && fail "(1) an empty detail is not a trip"
ok

# ── 2. the CODE-ERROR detail the worker publishes ───────────────────────────────────────────────────
# _health_fail_detail must win on the bats red (the not-ok line, not the passing 'ok 29 …' line).
[ "$(_health_fail_detail "$BATS_RED")" = "not ok 41 hermetic watcher health-cache test passes" ] \
  || fail "(2) the bats red must be labelled by its 'not ok' line (got '$(_health_fail_detail "$BATS_RED")')"
ok

# ── 3. gate: sha-cache + bounce routing across both classes ─────────────────────────────────────────
HC_STUB="$T/healthcheck-stub.sh"
cat > "$HC_STUB" <<'STUB'
#!/usr/bin/env bash
cat "${HC_LOG:?}"
exit "${HC_RC:-0}"
STUB
chmod +x "$HC_STUB"
export HERD_HEALTHCHECK_BIN="$HC_STUB"

SHA="deadbeefcafe"
drive_gate() {  # <pr#> <sha> — dispatch, await the background worker, re-enter to COLLECT
  local _p="$1" _sha="$2" _disp _n=0
  _HC_RESULT=""
  _healthcheck_gate "$_p" "slug$_p" "$T/wt" 0 "$_sha"
  case "$_HC_RESULT" in CLEAN|FLAKY|CODEERROR|QUEUED) return 0 ;; esac
  _disp="$(_health_dispatch_file "${_p}-${_sha}")"
  while [ "$_n" -lt 500 ]; do [ -f "$_disp" ] && break; sleep 0.02; _n=$((_n + 1)); done
  _HC_RESULT=""
  _healthcheck_gate "$_p" "slug$_p" "$T/wt" 0 "$_sha"
}
run_gate() {   # <pr#> <log> — one fresh gate cycle for (pr,SHA)
  rm -f "$TREES"/.health-inflight-* "$TREES"/.health-dispatch-* 2>/dev/null || true
  export HC_LOG="$2" HC_RC=1
  drive_gate "$1" "$SHA"
}
row() { printf '%s' "${DISPLAY[0]:-}"; }

# (3a) the bats red is a CODE ERROR: cached, quoted honestly, and NOT exempted.
run_gate 1 "$BATS_RED"
[ "$_HC_RESULT" = "CODEERROR" ] || fail "(3a) a reproduced bats red must be CODEERROR (got '$_HC_RESULT')"
cache1="$(_health_result_file 1 "$SHA")"
[ -f "$cache1" ] || fail "(3a) a bats red MUST be sha-cached — the missing cache is what looped PR #333"
IFS=$'\t' read -r cv cd < "$cache1"
[ "$cv" = "CODEERROR" ] || fail "(3a) cached verdict should be CODEERROR (got '$cv')"
case "$cd" in
  "not ok 41 "*) : ;;
  *) fail "(3a) the cached detail must be the 'not ok' line, not a passing one (got '$cd')" ;;
esac
ok

# (3b) a real trip is exempted: never cached, so the next tick re-runs and it self-heals.
run_gate 2 "$TRIP_FULL"
[ "$_HC_RESULT" = "CODEERROR" ] || fail "(3b) a trip is still a red THIS tick (got '$_HC_RESULT')"
[ -f "$(_health_result_file 2 "$SHA")" ] && fail "(3b) a tab-leak-guard trip must NOT be sha-cached (issue #78)"
row | grep -q 'TAB-LEAK-GUARD' || fail "(3b) the trip row must quote the guard's line (got '$(row)')"
ok

# ── 4. bounded infra re-dispatch: the exempted red cannot loop forever ──────────────────────────────
rm -f "$(_health_infra_file 2 "$SHA")" 2>/dev/null || true
n=0
while [ "$n" -lt "$_HEALTH_INFRA_REDISPATCH_MAX" ]; do
  run_gate 2 "$TRIP_FULL"
  n=$((n + 1))
done
cap_cache="$(_health_result_file 2 "$SHA")"
[ -f "$cap_cache" ] || fail "(4) at the cap the infra red MUST be cached — else it re-dispatches forever"
IFS=$'\t' read -r cv cd < "$cap_cache"
[ "$cv" = "CODEERROR" ] || fail "(4) the capped verdict should be CODEERROR (got '$cv')"
case "$cd" in
  "$_HEALTH_INFRA_CAP_TAG"*) : ;;
  *) fail "(4) the capped detail must carry the escalation tag (got '$cd')" ;;
esac
grep -q '"reason":"health_infra_cap"' "$JOURNAL_FILE" || fail "(4) hitting the cap must journal health_infra_cap"
ok

# ── 4b. the bounce split, with HEALTHCHECK_AUTOFIX forced ON ────────────────────────────────────────
# A bounce is proven by the shared refix ledger (record_refix runs BEFORE pane delivery, so this holds
# without stubbing the control room); an infra red must never write to it.
_health_autofix_enabled() { return 0; }
_detect_limit_hit() { return 1; }
_agent_liveness() { printf 'alive'; }
herd_driver_notify() { :; }
: > "$REFIX_STATE"

DISPLAY=()
_handle_health_codeerror 2 slug2 "$SHA" 0 "$T/wt" "$cd"      # the CAPPED infra red
[ "$(refix_round_count 2)" = "0" ] || fail "(4b) a capped infra red must never bounce a builder"
row | grep -q 'needs you' || fail "(4b) the capped row must be a needs-you row (got '$(row)')"
row | grep -q 'did not self-heal' || fail "(4b) the capped row must say the infra red did not self-heal"

DISPLAY=()
_handle_health_codeerror 9 slug9 shaLEAK 0 "$T/wt" "❌ tab-leak-guard: 1 unexpected tab"
[ "$(refix_round_count 9)" = "0" ] || fail "(4b) a tab-leak-guard transient must never bounce a builder"
row | grep -q 'tab-leak-guard' || fail "(4b) the leak-guard row must be preserved verbatim"

# … while a genuine bats red NAMING the guard does bounce — the case the old substring grep swallowed.
DISPLAY=()
_handle_health_codeerror 10 slug10 shaBATS 0 "$T/wt" "not ok 41 hermetic tab-leak-guard deflake test passes"
[ "$(refix_round_count 10)" = "1" ] || fail "(4b) a bats red naming the guard MUST bounce (got $(refix_round_count 10))"
ok

# ── 5. main-health routing: a bats red paints MAIN RED; a real trip stays an infra_event ────────────
_collect_one() {  # <sha> <rc> <detail> — seed a finished main-health dispatch and collect it
  printf '%s\t%s\n' "$2" "$3" > "$(_health_dispatch_file "main-$1")"
  printf '%s\n' 77 > "$(_main_health_pr_file "$1")"
  rm -f "$(_main_health_marker "$1")" 2>/dev/null || true
  _collect_main_health
}
herd_driver_notify() { :; }

rm -f "$MAIN_HEALTH_STATE" 2>/dev/null || true
_collect_one shaTRIP 1 "TAB-LEAK-GUARD: the test suite left an orphan tab/pane in the live workspace"
[ -s "$MAIN_HEALTH_STATE" ] && fail "(5) a real trip on main must stay an infra_event, never MAIN RED"
grep -q '"reason":"tab-leak-guard"' "$JOURNAL_FILE" || fail "(5) a real trip on main must journal the infra_event"

_collect_one shaBATS 1 "not ok 41 hermetic tab-leak-guard deflake (HERD-93) test passes"
[ -s "$MAIN_HEALTH_STATE" ] || fail "(5) a genuine bats red on main MUST paint MAIN RED (it structurally could not)"
grep -q 'not ok 41' "$MAIN_HEALTH_STATE" || fail "(5) the MAIN RED state must name the failing test"
ok

# ── 6. _HFD_PASS_RE drops runner-PREFIXED pass lines from the fallback ──────────────────────────────
PREFIXED="$T/prefixed.log"
cat > "$PREFIXED" <<'LOG'
❌ CODE ERROR
bats: ok 29 hermetic tab-leak-guard engine-whitelist test passes
docker: build exited with fatal error
LOG
[ "$(_health_fail_detail "$PREFIXED")" = "docker: build exited with fatal error" ] \
  || fail "(6) a prefixed pass line must not be quoted as the failure (got '$(_health_fail_detail "$PREFIXED")')"
# … and prose that merely CONTAINS a pass word is still eligible (the anchor must stay anchored).
PROSE="$T/prose.log"
printf '%s\n' "❌ CODE ERROR" "look at the ok path: it raised an exception" > "$PROSE"
[ "$(_health_fail_detail "$PROSE")" = "look at the ok path: it raised an exception" ] \
  || fail "(6) prose containing 'ok' must not be swallowed as a pass line"
ok

echo "ALL PASS ($pass checks)"
