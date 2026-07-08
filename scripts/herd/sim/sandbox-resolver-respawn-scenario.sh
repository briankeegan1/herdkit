#!/usr/bin/env bash
# scripts/herd/sim/sandbox-resolver-respawn-scenario.sh — HERD-55 RESOLVER-RESPAWN scenario.
#
# Proves the watcher re-spawns a stale/failed conflict resolver when a CONFLICTING PR's head sha
# changes or the dispatched resolver dies — instead of stranding the PR CONFLICTING until a human
# notices. It drives the REAL watcher decision code (agent-watch.sh sourced in lib mode) — the
# SHIPPED functions `_classify_conflict`, `spawn_resolver`, and the sha-keyed resolve ledger helpers
# (resolver_dispatch_count / resolver_dispatched_sha / resolver_escalated_sha / resolver_last_sha) —
# not a re-implementation. Each tick calls `_classify_conflict` exactly as the classification pass
# does, then mirrors the resolve pass (journal resolver_respawn + spawn_resolver) exactly as
# agent-watch.sh does, so the accounting under test is production code and this breaks if it regresses.
#
# It fakes the two external inputs deterministically (the stub-gh seam conventions of
# sandbox-concurrency-scenario.sh):
#   • the PR's CONFLICTING mergeStateStatus and its HEAD SHA — a plain shell variable the tick reads,
#     bumped to fake a new commit;
#   • the resolver agent liveness ($AGENTS_JSON, the driver roster the watcher parses) and the
#     resolver's terminal verdict (the sha-scoped $HERD_RESOLVE_RESULT_FILE the resolver writes) — via
#     a stub resolver on the HERD_RESOLVE_BIN seam (mirrors HERD_REVIEW_BIN).
#
# Scorecard checkpoints (the required chain dispatch → death → new-sha respawn → cap, plus the
# terminal-escalate and live-hold rails):
#   (1) first_dispatch     — first CONFLICTING tick dispatches ONE resolver, sha-keyed.
#   (2) alive_holds        — while the resolver agent is alive + no verdict, NO second dispatch (hold).
#   (3) dead_respawn       — resolver dies (agent gone, no verdict) → RE-dispatch for the same sha.
#   (4) new_commit_respawn — a NEW head sha → RE-dispatch for the new sha (journaled resolver_respawn).
#   (5) respawn_capped     — after REFIX_MAX_ROUNDS dispatches, NO further dispatch; row = "gave up".
#   (5b) new_commit_holds_while_alive — a NEW sha while the prior resolver is STILL alive HOLDS (never
#        double-dispatches onto the same worktree); re-dispatches only after that resolver has exited.
#   (6) escalate_terminal  — an ESCALATE verdict is terminal for its sha: recorded + never re-dispatched.
#   (7) journal_trail      — every respawn emitted a resolver_respawn journal event with old/new sha.
#
# HERMETIC: fixture repo only, no gh/panes/network/model. Mirrors sandbox-concurrency-scenario.sh.
# Usage:  bash scripts/herd/sim/sandbox-resolver-respawn-scenario.sh [--artifacts DIR] [--keep]
# Exit: 0 = every checkpoint passed · 1 = at least one failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"

c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s\xe2\x9c\x93%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s\xe2\x9c\x97%s %s\n' "$c_red" "$c_rst" "$*"; }
info() { printf '  %s\xe2\x86\x92%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────
ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-resolver-respawn-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [ -z "$ART" ]; then ART="$(mktemp -d)"; fi
mkdir -p "$ART"
if [ -z "$KEEP" ]; then trap 'rm -rf "$ART"' EXIT; fi

SCENARIO="resolver-respawn"
REPO="$ART/repo"
TREES="$ART/trees"
mkdir -p "$TREES"

# ── checkpoint recording (bash 3.2: parallel indexed arrays) ────────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail="$*"
  detail="$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
  esac
}

printf '%s\xe2\x95\x90\xe2\x95\x90 Sandbox RESOLVER-RESPAWN scenario: %s \xe2\x95\x90\xe2\x95\x90%s\n' "$c_bold" "$SCENARIO" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# ── init: deterministic fixture + one feature worktree whose PR is CONFLICTING ──
step init "build fixture + one CONFLICTING feature worktree"
FIXTURE_SHA="$(sandbox_fixture_build "$REPO")" || { bad "fixture build failed"; exit 1; }
_sf_git_env
SLUG="feat-conflict"; BRANCH="sim/$SLUG"; DIR="$TREES/$SLUG"; PR=101
git -C "$REPO" worktree add -q -b "$BRANCH" "$DIR" main 2>/dev/null || { bad "worktree add failed"; exit 1; }
printf 'diverge\n' > "$DIR/app/$SLUG.sh"
git -C "$DIR" add -A && git -C "$DIR" commit -q -m "stub: $SLUG"
info "worktree $DIR on branch $BRANCH (PR #$PR)"
checkpoint fixture_built pass "fixture + conflicting worktree ready (HEAD ${FIXTURE_SHA:0:12})"

# ── source the REAL watcher in lib mode ─────────────────────────────────────────
step source "source the REAL agent-watch.sh (lib mode) with the resolver seams"
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$ART/no-such-config"
export HERD_DRIVER=headless
export WORKSPACE_NAME="sandbox-resolver-sim"
export PROJECT_ROOT="$REPO"
export WORKTREES_DIR="$TREES"
export DEFAULT_BRANCH="main"
export MERGE_POLICY="auto"
export REFIX_MAX_ROUNDS=3            # respawn budget under test
export _RESOLVER_DEAD_GRACE=0        # zero the startup grace so a gone agent is instantly "dead"
export JOURNAL_FILE="$ART/journal.jsonl"; : > "$JOURNAL_FILE"

# Stub resolver on the HERD_RESOLVE_BIN seam. It records each dispatch (slug + result-file + sha) and,
# per $STUB_RESOLVE_VERDICT, either writes the sha-scoped verdict file (ESCALATE / DONE) or writes
# NOTHING (default) — the "resolver that will die" (we then keep it out of $AGENTS_JSON so it is gone).
STUB_RESOLVE="$ART/stub-resolve.sh"
cat > "$STUB_RESOLVE" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "${HERD_RESOLVE_RESULT_FILE:-}" >> "${STUB_RESOLVE_LOG:-/dev/null}"
case "${STUB_RESOLVE_VERDICT:-}" in
  ESCALATE) [ -n "${HERD_RESOLVE_RESULT_FILE:-}" ] && printf 'RESOLVE: ESCALATE\n' > "$HERD_RESOLVE_RESULT_FILE" ;;
  DONE)     [ -n "${HERD_RESOLVE_RESULT_FILE:-}" ] && printf 'RESOLVE: DONE\n'     > "$HERD_RESOLVE_RESULT_FILE" ;;
  *)        : ;;   # write no verdict — simulates a resolver that dies mid-flight
esac
exit 0
STUB
chmod +x "$STUB_RESOLVE"
export HERD_RESOLVE_BIN="$STUB_RESOLVE"
export STUB_RESOLVE_LOG="$ART/resolve-dispatches.log"; : > "$STUB_RESOLVE_LOG"

WATCH="$HERE/../agent-watch.sh"
[ -f "$WATCH" ] || { bad "agent-watch.sh not found at $WATCH"; exit 1; }
# shellcheck source=/dev/null
. "$WATCH" || { bad "sourcing agent-watch.sh (lib mode) failed"; exit 1; }
render() { :; }   # silence the console painter like the unit tests do

_missing=""
for fn in _classify_conflict spawn_resolver resolver_dispatch_count resolver_dispatched_sha \
          resolver_escalated_sha resolver_last_sha record_resolve_escalated _resolve_result_file; do
  type "$fn" >/dev/null 2>&1 || _missing="$_missing $fn"
done
if [ -z "$_missing" ]; then
  checkpoint watcher_bound pass "real resolver-respawn functions sourced (lib mode)"
else
  checkpoint watcher_bound fail "missing functions:$_missing"
fi

# ── tick harness ────────────────────────────────────────────────────────────────
# ROSTER_ALIVE=1 → $AGENTS_JSON lists a live resolve·<slug> agent; 0 → empty roster (resolver gone).
# HEAD_SHA is the PR's current head sha (bump to fake a new commit). One tick == the CONFLICTING
# classification decision (shipped _classify_conflict) + the resolve pass (shipped spawn_resolver).
DISPLAY=()
CONF_IDX=(); CONF_SLUG=(); CONF_PR=(); CONF_BRANCH=(); CONF_SHA=(); CONF_REASON=()
set_roster() {
  if [ "$1" = "1" ]; then
    AGENTS_JSON='{"result":{"agents":[{"name":"resolve·'"$SLUG"'","agent_status":"working"}]}}'
  else
    AGENTS_JSON='{"result":{"agents":[]}}'
  fi
  export AGENTS_JSON
}
run_conflict_tick() {
  local sha="$1"
  DISPLAY=()
  CONF_IDX=(); CONF_SLUG=(); CONF_PR=(); CONF_BRANCH=(); CONF_SHA=(); CONF_REASON=()
  _classify_conflict 0 "$PR" "$SLUG" "$BRANCH" "$sha"
  # Mirror the shipped resolve pass (agent-watch.sh): journal a respawn, then (re)dispatch.
  local k=0 idx reason csha
  for idx in ${CONF_IDX[@]+"${CONF_IDX[@]}"}; do
    reason="${CONF_REASON[k]}"; csha="${CONF_SHA[k]}"; k=$((k+1))
    if [ "$reason" != "first" ]; then
      journal_append resolver_respawn pr "$PR" slug "$SLUG" \
        old_sha "$(resolver_last_sha "$PR")" new_sha "$csha" reason "$reason" \
        round "$(( $(resolver_dispatch_count "$PR") + 1 ))"
    fi
    spawn_resolver "$SLUG" "$PR" "$BRANCH" "$csha"
  done
}
dispatch_count() { resolver_dispatch_count "$PR"; }
last_row() { printf '%s' "${DISPLAY[0]:-}"; }

# ═══════════════════════════════════════════════════════════════════════════════
step drive "drive the resolver-respawn decision tick by tick"
S1="aaaaaaa1"; S2="bbbbbbb2"; S3="ccccccc3"; S4="ddddddd4"

# (1) FIRST DISPATCH — a fresh conflict spawns exactly one resolver, keyed to S1.
export STUB_RESOLVE_VERDICT=""       # resolver writes no verdict (will "die")
set_roster 0
run_conflict_tick "$S1"
_d1="$(dispatch_count)"
if [ "$_d1" -eq 1 ] && resolver_dispatched_sha "$PR" "$S1"; then
  checkpoint first_dispatch pass "first conflict dispatched 1 resolver, sha-keyed to $S1"
else
  checkpoint first_dispatch fail "expected 1 dispatch for $S1, got count=$_d1"
fi

# (2) ALIVE HOLDS — resolver agent alive, no verdict yet: NO new dispatch, row shows 'resolving'.
set_roster 1
run_conflict_tick "$S1"
_d2="$(dispatch_count)"
if [ "$_d2" -eq 1 ] && printf '%s' "$(last_row)" | grep -q 'resolving conflict'; then
  checkpoint alive_holds pass "live resolver held (still 1 dispatch; row=resolving conflict…)"
else
  checkpoint alive_holds fail "expected hold at 1 dispatch, got count=$_d2 row='$(last_row)'"
fi

# (3) DEAD RESPAWN — resolver agent GONE, still no verdict, same sha S1 → re-dispatch (round 2).
set_roster 0
run_conflict_tick "$S1"
_d3="$(dispatch_count)"
if [ "$_d3" -eq 2 ]; then
  checkpoint dead_respawn pass "dead resolver re-dispatched for same sha (round 2, reason=dead-resolver)"
else
  checkpoint dead_respawn fail "expected re-dispatch to 2 on dead resolver, got count=$_d3"
fi

# (4) NEW-COMMIT RESPAWN — a NEW head sha S2 reshapes the conflict → re-dispatch for S2 (round 3).
set_roster 0
run_conflict_tick "$S2"
_d4="$(dispatch_count)"
if [ "$_d4" -eq 3 ] && resolver_dispatched_sha "$PR" "$S2"; then
  checkpoint new_commit_respawn pass "new commit ($S2) re-dispatched resolver (round 3, reason=new-commit)"
else
  checkpoint new_commit_respawn fail "expected re-dispatch to 3 for $S2, got count=$_d4"
fi

# (5) RESPAWN CAPPED — budget (REFIX_MAX_ROUNDS=3) spent; a further new sha S3 does NOT dispatch.
set_roster 0
run_conflict_tick "$S3"
_d5="$(dispatch_count)"
if [ "$_d5" -eq 3 ] && printf '%s' "$(last_row)" | grep -q 'gave up'; then
  checkpoint respawn_capped pass "cap reached: no 4th dispatch; row=resolver gave up (3 rounds)"
else
  checkpoint respawn_capped fail "expected cap at 3 dispatches, got count=$_d5 row='$(last_row)'"
fi

# (5b) NEW COMMIT WHILE ALIVE HOLDS — the reviewer's race: a NEW head sha lands while the prior
#      resolver is STILL alive. The watcher must HOLD (never a second resolver on the same worktree),
#      and only re-dispatch once that resolver has exited. Fresh PR so the cap sequence is untouched.
PR=103; SLUG="feat-race"; BRANCH="sim/$SLUG"
export STUB_RESOLVE_VERDICT=""
RA1="fffffff1"; RA2="ggggggg2"
set_roster 0
run_conflict_tick "$RA1"                 # first dispatch for RA1 (count 1)
_rc1="$(dispatch_count)"
set_roster 1
run_conflict_tick "$RA2"                 # NEW sha RA2 while resolver ALIVE → must HOLD, no dispatch
_rc2="$(dispatch_count)"
_race_row="$(last_row)"
set_roster 0
run_conflict_tick "$RA2"                 # resolver now GONE → re-dispatch for RA2
_rc3="$(dispatch_count)"
if [ "$_rc1" -eq 1 ] && [ "$_rc2" -eq 1 ] && [ "$_rc3" -eq 2 ] \
   && printf '%s' "$_race_row" | grep -q 'resolving conflict'; then
  checkpoint new_commit_holds_while_alive pass "new commit while resolver alive HELD (no double-dispatch), re-dispatched only after it exited"
else
  checkpoint new_commit_holds_while_alive fail "expected hold-then-respawn (counts $_rc1/$_rc2/$_rc3, row='$_race_row')"
fi

# (6) ESCALATE TERMINAL — a FRESH PR whose resolver ESCALATES: recorded terminal + never re-dispatched.
PR=102; SLUG="feat-escalate"; BRANCH="sim/$SLUG"
export STUB_RESOLVE_VERDICT=ESCALATE
ES1="eeeeeee1"
set_roster 0
run_conflict_tick "$ES1"                 # first dispatch; stub writes RESOLVE: ESCALATE for ES1
_ce1="$(dispatch_count)"
set_roster 0
run_conflict_tick "$ES1"                 # next tick reads the verdict → records escalated, terminal
_ce2="$(dispatch_count)"
if [ "$_ce1" -eq 1 ] && [ "$_ce2" -eq 1 ] && resolver_escalated_sha "$PR" "$ES1" \
   && printf '%s' "$(last_row)" | grep -q 'resolver escalated'; then
  checkpoint escalate_terminal pass "ESCALATE is terminal for the sha (1 dispatch, no respawn; row=escalated)"
else
  checkpoint escalate_terminal fail "expected terminal escalate (d1=$_ce1 d2=$_ce2 esc=$(resolver_escalated_sha "$PR" "$ES1"; echo $?) row='$(last_row)')"
fi

# (7) JOURNAL TRAIL — every respawn (rounds 2 & 3 on PR 101) emitted a resolver_respawn event.
_rr_events="$(grep -c '"event":"resolver_respawn"' "$JOURNAL_FILE" 2>/dev/null || echo 0)"
_esc_events="$(grep -c '"event":"resolver_escalated"' "$JOURNAL_FILE" 2>/dev/null || echo 0)"
if [ "$_rr_events" -ge 2 ] && grep -q '"reason":"dead-resolver"' "$JOURNAL_FILE" \
   && grep -q '"reason":"new-commit"' "$JOURNAL_FILE" && [ "$_esc_events" -ge 1 ]; then
  checkpoint journal_trail pass "$_rr_events resolver_respawn + $_esc_events resolver_escalated journal events (old/new sha, reasons)"
else
  checkpoint journal_trail fail "expected >=2 resolver_respawn (dead+new-commit) + escalate; got respawn=$_rr_events esc=$_esc_events"
fi

# ── scorecard ───────────────────────────────────────────────────────────────────
write_scorecard() {
  local out="$ART/scorecard.json" result="$1" i n; n=${#CP_NAMES[@]}
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
    printf '  "artifacts_dir": "%s",\n' "$ART"
    printf '  "fixture_sha": "%s",\n' "$FIXTURE_SHA"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "refix_max_rounds": %d,\n' "$REFIX_MAX_ROUNDS"
    printf '  "resolver_respawn_events": %d,\n' "${_rr_events:-0}"
    printf '  "checkpoints": [\n'
    for ((i=0; i<n; i++)); do
      printf '    {"name": "%s", "status": "%s", "detail": "%s"}' \
        "${CP_NAMES[$i]}" "${CP_STATUS[$i]}" "${CP_DETAIL[$i]}"
      [ "$i" -lt "$((n-1))" ] && printf ',\n' || printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
  } > "$out"
  printf '%s' "$out"
}

RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$(write_scorecard "$RESULT")"
printf '\n%s\xe2\x95\x90\xe2\x95\x90 scorecard \xe2\x95\x90\xe2\x95\x90%s\n' "$c_bold" "$c_rst"
printf '  result:        %s\n' "$RESULT"
printf '  passed/failed: %d / %d\n' "$_pass" "$_fail"
printf '  scorecard:     %s\n' "$SCARD"
printf '  artifacts:     %s\n' "$ART"

[ "$RESULT" = "pass" ] && exit 0 || exit 1
