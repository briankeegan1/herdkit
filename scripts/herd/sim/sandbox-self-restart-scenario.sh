#!/usr/bin/env bash
# scripts/herd/sim/sandbox-self-restart-scenario.sh — WATCHER SELF-RESTART scenario (HERD-251).
#
# REAL-WATCHER TIER. Like sandbox-concurrency-scenario.sh, this drives the SHIPPED watcher functions
# (agent-watch.sh sourced in lib mode, AGENT_WATCH_LIB=1) in the exact order the live tick runs them —
# action pass (_healthcheck_gate / _dispatch_review / spawn_resolver) → reconcile_main_freshness →
# _self_restart_tick — against a REAL local git repo wired to a bare "origin", with a second clone
# standing in for the seat that merges. The healthcheck worker is a REAL background process writing a
# REAL restart-safe inflight marker. So the quiesce accounting under test IS production's.
#
# The scenario is the incident HERD-251 fixes: another seat merges a commit that rewrites
# scripts/herd/agent-watch.sh while this watcher is mid-suite. Today the watcher keeps grading PRs with
# an engine image its own repo has replaced, and an operator restarts it by hand (six times on
# 2026-07-09). With WATCHER_SELF_RESTART=on it quiesces and re-execs itself.
#
# Checkpoints:
#   fixture_built        — bare origin + $MAIN checkout + a second seat, all real git
#   suite_inflight       — tick 1 dispatches a REAL suite worker; its inflight marker is live
#   no_arm_midsuite      — the seat's engine merge lands mid-suite: reconcile DEFERS (a live gate owns
#                          the tree), so nothing arms and nothing is pulled out from under the suite
#   suite_collects       — the in-flight suite finishes and its verdict is COLLECTED + sha-cached
#   quiesce_armed        — the next tick fast-forwards $MAIN, the pulled delta rewrote agent-watch.sh,
#                          the quiesce arms and journals watcher_quiesce
#   console_drain_row    — the console note flips to 'restarting on new engine code · draining N workers'
#   no_new_dispatch      — while quiescing, a SECOND PR's healthcheck is HELD (no suite, no marker), a
#                          review dispatch spawns no reviewer, and a resolver spawn burns no round
#   stale_heal_burns_no_guard — the stale-base heal holds ABOVE record_refix: the refix once-guard and
#                          the rail budget are untouched, so the restarted watcher can still heal the sha
#   drain_waits          — a live gate worker keeps the watcher waiting (it never execs over live work)
#   self_restart_fires   — once drained, watcher_self_restart reason=engine-update shas=<old>..<new>
#   gates_resume_on_new  — after the restart, $MAIN carries the NEW engine code and the held PR's
#                          healthcheck dispatches again on the very next tick
#   cap_expiry           — a worker that never finishes: the inline 15-minute cap restarts anyway
#   lever_off_identical  — the SAME merge with WATCHER_SELF_RESTART=off: no arm, no hold, no journal,
#                          and the console renders the unchanged 'restart recommended' row
#
# THE ONE THING NOT PERFORMED is the process replacement itself: a lib-mode scenario cannot exec into a
# live watcher (HERD_HERMETIC_GUARD exists precisely to forbid that), so `_self_restart_exec` is
# recorded rather than run, and the restarted watcher is modeled by re-applying agent-watch.sh's OWN
# startup steps (a fresh process has no quiesce state, and startup removes the restart note). The real
# function's journal line and its fail-soft refusal are proven in tests/test-watcher-self-restart.sh.
#
# HERMETIC: temp dirs only. `git` is REAL (real commits, real fast-forward, real rebase); `gh` + `herdr`
# are PATH stubs; HERD_DRIVER=headless (no panes/tabs ever created); an ISOLATED WORKSPACE_NAME + temp
# WORKTREES_DIR + JOURNAL_FILE, so it never touches the real herdkit repo's PRs, panes, or journal, and
# the tab-leak-guard cannot miscount it. Zero model calls, zero quota, zero network.
#
# Usage:
#   bash scripts/herd/sim/sandbox-self-restart-scenario.sh [--artifacts DIR] [--keep]
#     --artifacts DIR   put the repo + scorecard here (default: a fresh mktemp dir; --keep implied)
#     --keep            do not delete the artifacts dir on exit
#   Env:
#     SIM_SUITE_SECS    how long the stub suite stays in flight (default 2) — long enough that the
#                       engine merge provably lands WHILE a gate worker holds the tree
#
# Exit: 0 = every checkpoint passed · 1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../agent-watch.sh"

c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
skip() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-self-restart-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
[ -n "$KEEP" ] || trap 'rm -rf "$ART"' EXIT

SCENARIO="watcher-self-restart-e2e"
SUITE_SECS="${SIM_SUITE_SECS:-2}"

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
    skip) skip "$name — $detail" ;;
  esac
}
# assert <name> <condition-rc> <detail> — record a pass/fail checkpoint from a plain shell test.
assert() { if [ "$2" -eq 0 ]; then checkpoint "$1" pass "$3"; else checkpoint "$1" fail "$3"; fi; }

printf '%s══ Sandbox WATCHER SELF-RESTART scenario: %s ══%s\n' "$c_bold" "$SCENARIO" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# ═══ init: a real bare origin, a $MAIN checkout, and a second seat that merges ════════════════════
step init "build a real local git fixture (bare origin + \$MAIN + a second seat)"
command -v git >/dev/null 2>&1 || { bad "git required"; exit 1; }
[ -f "$WATCH" ] || { bad "agent-watch.sh not found at $WATCH"; exit 1; }

BIN="$ART/bin"; mkdir -p "$BIN"
for cmd in gh herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

ORIGIN="$ART/origin.git"; git init -q --bare "$ORIGIN"
gitcfg() { git -C "$1" config user.email sim@herdkit.test; git -C "$1" config user.name herdkit-sim; }

REPO="$ART/main"; git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -B main; gitcfg "$REPO"
mkdir -p "$REPO/scripts/herd" "$REPO/app"
printf 'engine v1\n' > "$REPO/scripts/herd/agent-watch.sh"
printf 'hello\n'     > "$REPO/app/greet.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -q -m "init"; git -C "$REPO" push -q origin main
FIXTURE_SHA="$(git -C "$REPO" rev-parse HEAD)"

SEAT="$ART/seat2"; git clone -q "$ORIGIN" "$SEAT" 2>/dev/null; gitcfg "$SEAT"

assert fixture_built $([ -f "$REPO/scripts/herd/agent-watch.sh" ] && echo 0 || echo 1) \
  "bare origin + \$MAIN (HEAD ${FIXTURE_SHA:0:12}) + a second seat clone"

# ═══ wire the REAL watcher (lib mode) ════════════════════════════════════════════════════════════
step wire "source the shipped agent-watch.sh in lib mode against an isolated workspace"
export AGENT_WATCH_LIB=1
export HERD_DRIVER=headless
export WORKSPACE_NAME="sim-self-restart-$$"
export WORKTREES_DIR="$ART/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$ART/no-such-config"
export JOURNAL_FILE="$ART/journal.jsonl"
export WATCHER_SELF_RESTART=on
export HEALTH_CONCURRENCY=1
# The guard the engine already honors to refuse a live watcher inside a harness. It ALSO makes the real
# _self_restart_exec refuse, so a regression can never replace THIS process (which would exit 0 silently
# and score a vacuous pass). Every restart below is therefore an observed DECISION, never an exec.
export HERD_HERMETIC_GUARD="$ART/hermetic-guard.log"

# A stub suite: stays in flight $SUITE_SECS (so the engine merge provably lands mid-gate), then passes.
HEALTH_BIN="$ART/stub-healthcheck.sh"
cat > "$HEALTH_BIN" <<EOF
#!/usr/bin/env bash
sleep ${SUITE_SECS}
echo "✅ clean"
exit 0
EOF
chmod +x "$HEALTH_BIN"
export HERD_HEALTHCHECK_BIN="$HEALTH_BIN"

# shellcheck source=/dev/null
. "$WATCH" || { bad "sourcing agent-watch.sh (lib mode) failed"; exit 1; }

MAIN="$REPO"; TREES="$WORKTREES_DIR"
HERD_REMOTE=origin; HERD_BRANCH_NAME=main; DEFAULT_BRANCH=origin/main
MAIN_FRESH_STATE="$TREES/.agent-watch-main-freshness"
MAIN_FRESH_RESTART="$TREES/.agent-watch-main-restart"

JLOG="$ART/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
jhas() { grep -q "$1" "$JLOG"; }

# The restart is RECORDED, not performed (see the header). $EXECED carries its trigger.
EXECED=""
_self_restart_exec() {
  EXECED="$1"
  journal_append watcher_self_restart reason engine-update \
    shas "${_SELF_RESTART_FROM:-unknown}..${_SELF_RESTART_TO:-unknown}" trigger "$1" workers "$2" waited "$3"
  return 0
}

# model_watcher_restart — what a FRESH agent-watch.sh process does at startup, and nothing more: it has
# no quiesce state, and it drops the restart note (agent-watch.sh's own one-shot `rm -f
# $MAIN_FRESH_RESTART`, "satisfied by the very restart that got us here").
model_watcher_restart() {
  _SELF_RESTART_ARMED=""; _SELF_RESTART_IDLE_TICKS=0; _SELF_RESTART_GAVE_UP=""
  rm -f "$MAIN_FRESH_RESTART" 2>/dev/null || true
  EXECED=""
}

# sim_tick <pr> <slug> <sha> — ONE watcher tick in the shipped order: the action pass's healthcheck
# gate, then the freshness reconcile, then the self-restart tick. Leaves $_HC_RESULT + $DISPLAY set.
sim_tick() {
  DISPLAY=(); _HC_RESULT=""
  _healthcheck_gate "$1" "$2" "$MAIN" 0 "$3"
  reconcile_main_freshness
  _self_restart_tick || true
}
live_markers() { _count_gate_workers; }
# seat_push <path> <content> <msg> — the OTHER seat lands a commit on origin/main (no do_merge here).
seat_push() {
  git -C "$SEAT" pull -q --ff-only origin main >/dev/null 2>&1
  mkdir -p "$SEAT/$(dirname "$1")"
  printf '%s\n' "$2" > "$SEAT/$1"
  git -C "$SEAT" add -A; git -C "$SEAT" commit -q -m "$3"; git -C "$SEAT" push -q origin main
}

info "workspace $WORKSPACE_NAME · suite dwell ${SUITE_SECS}s · WATCHER_SELF_RESTART=on"

# ═══ tick 1: a real suite goes in flight ═════════════════════════════════════════════════════════
step suite "tick 1 — the action pass dispatches a REAL healthcheck worker"
PR1=101; SLUG1="feat-one"; SHA1="sha1111"
sim_tick "$PR1" "$SLUG1" "$SHA1"
assert suite_inflight $([ "$_HC_RESULT" = "RUNNING" ] && [ "$(live_markers)" -eq 1 ] && echo 0 || echo 1) \
  "suite RUNNING with 1 live inflight marker (result=${_HC_RESULT:-none})"

# ═══ the other seat merges NEW ENGINE CODE while that suite holds the tree ════════════════════════
step merge "the other seat merges a commit that rewrites scripts/herd/agent-watch.sh — mid-suite"
seat_push scripts/herd/agent-watch.sh "engine v2" "feat: rewrite the watcher"
NEW_SHA="$(git -C "$SEAT" rev-parse HEAD)"
sim_tick "$PR1" "$SLUG1" "$SHA1"                       # tick 2: the suite is still in flight
_mid_ok=1
if [ "$(live_markers)" -eq 1 ] && ! _self_restart_quiescing && [ ! -s "$MAIN_FRESH_RESTART" ] \
   && [ "$(git -C "$MAIN" rev-parse HEAD)" = "$FIXTURE_SHA" ]; then _mid_ok=0; fi
assert no_arm_midsuite "$_mid_ok" \
  "a live gate owns the tree: no ff, no restart note, no quiesce (the suite is never pulled out from under)"

# ═══ the suite collects — nothing in flight is discarded ══════════════════════════════════════════
step collect "wait for the in-flight suite to finish, then collect its verdict"
_deadline=$(( $(date +%s) + SUITE_SECS + 20 ))
while [ "$(live_markers)" -gt 0 ] && [ "$(date +%s)" -lt "$_deadline" ]; do sleep 0.5; done
sim_tick "$PR1" "$SLUG1" "$SHA1"                       # collects, then ff's $MAIN, then arms
assert suite_collects $([ "$_HC_RESULT" = "CLEAN" ] && echo 0 || echo 1) \
  "the in-flight suite landed its verdict (result=${_HC_RESULT:-none}) — quiescing never discards paid work"

# ═══ the quiesce arms on the engine-code delta ════════════════════════════════════════════════════
step quiesce "the freshness reconcile fast-forwards \$MAIN; the pulled delta rewrote the watcher"
_arm_ok=1
if _self_restart_quiescing && jhas 'watcher_quiesce reason engine-update' \
   && [ "$(git -C "$MAIN" rev-parse HEAD)" = "$NEW_SHA" ]; then _arm_ok=0; fi
assert quiesce_armed "$_arm_ok" \
  "\$MAIN ff'd to ${NEW_SHA:0:12}, quiesce armed, watcher_quiesce journaled"

build_main_freshness
_row_ok=1
case "${MAIN_FRESHNESS:-}" in
  *"restarting on new engine code"*"draining"*) case "${MAIN_FRESHNESS}" in *"restart recommended"*) ;; *) _row_ok=0 ;; esac ;;
esac
assert console_drain_row "$_row_ok" \
  "console note reads 'restarting on new engine code · draining N workers' (never the operator-restart row)"

# ═══ while quiescing, NO new gate work is dispatched ══════════════════════════════════════════════
step hold "a second PR arrives mid-quiesce: every gate dispatch must refuse"
PR2=102; SLUG2="feat-two"; SHA2="sha2222"
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate "$PR2" "$SLUG2" "$MAIN" 0 "$SHA2"
_held_health=$([ "$_HC_RESULT" = "QUEUED" ] && [ "$(live_markers)" -eq 0 ] && echo 0 || echo 1)

_dispatch_review "$PR2" "$SLUG2" "$SHA2"
_held_review=$([ -z "$(ls "$TREES"/.review-inflight-$PR2-* 2>/dev/null)" ] && ! jhas 'review_dispatched' && echo 0 || echo 1)

_RESOLVE_RECORDED=""
record_resolve_attempt() { _RESOLVE_RECORDED=1; }
spawn_resolver "$SLUG2" "$PR2" "feat/$SLUG2" "$SHA2"
_held_resolver=$([ -z "$_RESOLVE_RECORDED" ] && echo 0 || echo 1)

assert no_new_dispatch \
  $([ "$_held_health" -eq 0 ] && [ "$_held_review" -eq 0 ] && [ "$_held_resolver" -eq 0 ] && echo 0 || echo 1) \
  "healthcheck held (no suite), review dispatched no reviewer, resolver burned no respawn round"

# ═══ the stale-base heal holds ABOVE its own ledger write ═════════════════════════════════════════
# _handle_stale_dup burns the refix once-guard and journals stale_refix_resolver BEFORE it calls
# spawn_resolver. A hold placed further down would drop the dispatch behind a spent guard: the sha
# could never be re-healed (no builder exists to advance it) and every later tick — including after the
# re-exec, since $REFIX_STATE is on disk — would paint a durable needs-you for a heal the watcher itself
# declined. So the hold sits with its sibling deferrals, above record_refix. (PR #376 review.)
step stale "a base-stale PR with no live builder arrives mid-quiesce: the heal must burn no once-guard"
PR3=104; SLUG3="feat-stale"; SHA3="sha4444"
STALE_WT="$ART/stale-wt"; mkdir -p "$STALE_WT"     # a worktree that EXISTS: the reviewed dispatch path
export STALE_BASE_AUTOFIX=on
render() { :; }                                    # the heal repaints mid-dispatch; not under test here
DISPLAY=()
_handle_stale_dup "$PR3" "$SLUG3" "$SHA3" 0 "$STALE_WT" "feat/$SLUG3" stale-base "base moved under it"
_guard_clean=$(refix_attempted "$PR3" "$SHA3" stale && echo 1 || echo 0)
_rail_clean=$([ "$(refix_rail_count "$PR3" stale)" = "0" ] && echo 0 || echo 1)
_row_honest=1
case "${DISPLAY[0]:-}" in
  *"restarting on new engine code"*) case "${DISPLAY[0]}" in *"awaiting push"*) ;; *) _row_honest=0 ;; esac ;;
esac
assert stale_heal_burns_no_guard \
  $([ "$_guard_clean" -eq 0 ] && [ "$_rail_clean" -eq 0 ] && [ "$_row_honest" -eq 0 ] && echo 0 || echo 1) \
  "refix once-guard unburned, 0 rail rounds spent, row reads 'held' not 'awaiting push' — the sha stays healable"
unset STALE_BASE_AUTOFIX

# ═══ the drain never execs over live work ═════════════════════════════════════════════════════════
step drain "a gate worker is still live: the watcher waits, then restarts once it clears"
_marker_write "$TREES/.health-inflight-$PR1-shaLIVE" "$$"     # a worker that outlived the arm
_self_restart_tick || true
_waited_ok=$([ -z "$EXECED" ] && [ "$_SELF_RESTART_IDLE_TICKS" -eq 0 ] && echo 0 || echo 1)
assert drain_waits "$_waited_ok" "a live worker blocks the exec and resets the idle streak"

rm -f "$TREES/.health-inflight-$PR1-shaLIVE"                  # it collects
_self_restart_tick || true                                    # one quiet tick is not enough…
_one_tick_held=$([ -z "$EXECED" ] && echo 0 || echo 1)
_self_restart_tick || true                                    # …two consecutive quiet ticks are
_restart_ok=$([ "$EXECED" = "drained" ] && [ "$_one_tick_held" -eq 0 ] \
  && jhas "watcher_self_restart reason engine-update shas ${FIXTURE_SHA}..${NEW_SHA}" && echo 0 || echo 1)
assert self_restart_fires "$_restart_ok" \
  "restarted on trigger=${EXECED:-none} after 2 consecutive zero-worker ticks; journaled shas=<old>..<new>"

# ═══ the restarted watcher runs the NEW code and resumes gating ═══════════════════════════════════
step resume "model the restart (fresh process: no quiesce state, note dropped) and gate again"
model_watcher_restart
_new_code=$([ "$(cat "$MAIN/scripts/herd/agent-watch.sh")" = "engine v2" ] && echo 0 || echo 1)
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate "$PR2" "$SLUG2" "$MAIN" 0 "$SHA2"           # the held PR dispatches on the next tick
_resumed=$([ "$_HC_RESULT" = "RUNNING" ] && [ "$(live_markers)" -eq 1 ] && echo 0 || echo 1)
assert gates_resume_on_new_code \
  $([ "$_new_code" -eq 0 ] && [ "$_resumed" -eq 0 ] && echo 0 || echo 1) \
  "\$MAIN holds the new engine code and the held PR's suite dispatched (result=${_HC_RESULT:-none})"

_deadline=$(( $(date +%s) + SUITE_SECS + 20 ))
while [ "$(live_markers)" -gt 0 ] && [ "$(date +%s)" -lt "$_deadline" ]; do sleep 0.5; done
DISPLAY=(); _HC_RESULT=""; _healthcheck_gate "$PR2" "$SLUG2" "$MAIN" 0 "$SHA2"   # collect + free the slot

# ═══ cap expiry: a worker that never finishes must not park the watcher forever ═══════════════════
step cap "a gate worker that never drains — the inline 15-minute cap restarts anyway"
model_watcher_restart
printf '%s\n' "$NEW_SHA" > "$MAIN_FRESH_RESTART"              # re-raise the note the reconcile writes
_SELF_RESTART_FROM="$FIXTURE_SHA"
_self_restart_tick || true                                    # arm
_marker_write "$TREES/.review-inflight-$PR2-shaSTUCK" "$$"    # a reviewer that never finishes
_SELF_RESTART_ARMED=$(( $(date +%s) - 901 ))                  # armed 15 min + 1 s ago
_self_restart_tick || true
assert cap_expiry $([ "$EXECED" = "cap-expiry" ] && echo 0 || echo 1) \
  "the max-wait cap fired with a worker still live (trigger=${EXECED:-none}); a cap kill is attributed"
rm -f "$TREES/.review-inflight-$PR2-shaSTUCK"

# ═══ lever off: the SAME merge is byte-identical to the HERD-233 recommendation row ═══════════════
step off "WATCHER_SELF_RESTART=off — the same engine merge only RECOMMENDS a restart"
model_watcher_restart
: > "$JLOG"
export WATCHER_SELF_RESTART=off
printf '%s\n' "$NEW_SHA" > "$MAIN_FRESH_RESTART"
_self_restart_tick || true
_off_quiet=$([ -z "$EXECED" ] && ! _self_restart_quiescing && [ ! -s "$JLOG" ] && echo 0 || echo 1)
_self_restart_hold_dispatch && _off_quiet=1                   # …and no gate dispatch is held
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate 103 feat-three "$MAIN" 0 "sha3333"
[ "$_HC_RESULT" = "RUNNING" ] || _off_quiet=1                 # the suite dispatches exactly as before
build_main_freshness
case "${MAIN_FRESHNESS:-}" in *"restart recommended"*) ;; *) _off_quiet=1 ;; esac
case "${MAIN_FRESHNESS:-}" in *"restarting on new engine code"*) _off_quiet=1 ;; esac
assert lever_off_identical "$_off_quiet" \
  "no arm, no hold, no journal; the suite dispatched and the row still reads 'restart recommended'"

_deadline=$(( $(date +%s) + SUITE_SECS + 20 ))
while [ "$(live_markers)" -gt 0 ] && [ "$(date +%s)" -lt "$_deadline" ]; do sleep 0.5; done

# ═══ scorecard ═══════════════════════════════════════════════════════════════════════════════════
write_scorecard() {
  local out="$ART/scorecard.json" result="$1"
  local skipped=0 i n; n=${#CP_NAMES[@]}
  for ((i=0; i<n; i++)); do [ "${CP_STATUS[$i]}" = "skip" ] && skipped=$((skipped+1)); done
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
    printf '  "artifacts_dir": "%s",\n' "$ART"
    printf '  "repo_dir": "%s",\n' "$REPO"
    printf '  "fixture_sha": "%s",\n' "$FIXTURE_SHA"
    printf '  "engine_sha": "%s",\n' "$NEW_SHA"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "skipped": %d,\n' "$skipped"
    printf '  "restart_cap_secs": %d,\n' "$SELF_RESTART_CAP_SECS"
    printf '  "suite_dwell_secs": %d,\n' "$SUITE_SECS"
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
printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:      %s\n' "$SCENARIO"
printf '  result:        %s\n' "$RESULT"
printf '  passed/failed: %d / %d\n' "$_pass" "$_fail"
printf '  engine delta:  %s → %s\n' "${FIXTURE_SHA:0:12}" "${NEW_SHA:0:12}"
printf '  restart cap:   %ds\n' "$SELF_RESTART_CAP_SECS"
printf '  scorecard:     %s\n' "$SCARD"
printf '  artifacts:     %s\n' "$ART"

[ "$RESULT" = "pass" ] && exit 0 || exit 1
