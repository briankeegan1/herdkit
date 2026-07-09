#!/usr/bin/env bash
# scripts/herd/sim/tick-availability-sim.sh — the adversary for HERD-237 (audit G4).
#
# The claim the tick loop makes is that it is a LOOP: every ~4 s it re-reads the world, re-gates its
# candidates, drains its queue, and parks anything that hit a limit. The whole control room — merges,
# collections, resolver dispatch, limit-parks — rides that single loop. G4's finding is that the claim
# was false under two conditions the loop could not survive: an unbounded `gh` call, and a lane
# invocation that blocked in the foreground. Either one wedged EVERY PR's gating, not just its own.
#
# This sim is the adversary for exactly that claim. It does not check that a hung `gh` is detected; it
# checks that the LOOP SURVIVES one, which is a different and stronger property. Both fault classes are
# injected against the REAL watcher (agent-watch.sh sourced in lib mode) with a real spawn queue and
# real inflight markers — no mocks of the code under test.
#
#   A. HUNG GH — a `gh` that never returns is planted on PATH. The gate reads the tick makes against it
#      (`_prs_fetch_tick`, `_pr_body`, `_gate_status_blessed`) must each return within the budget, take
#      their EXISTING gh-failure branch, and journal a labelled gh_timeout. Unbounded, these three calls
#      alone would have cost 90 s — more than twenty ticks.
#
#   B. SLOW LANE — a builder lane that takes 10 s is enqueued. `_drain_spawn_queue` must return in well
#      under a tick, leaving the intent CLAIMED (never consumed before its lane is observed: the PR #151
#      durability contract). A second tick fired while that lane is in flight must launch NOTHING. When
#      the lane finally lands, its worker consumes the intent and journals spawn_launched — the same
#      event the foreground drain wrote, on a later tick.
#
#   C. SLOW RESOLVER — spawn_resolver must return before its lane does, with the respawn-budget ledger
#      row already down (record-first), and the resolver_spawn ACK event must still be journaled once
#      the lane lands. A SECOND dispatch while one is in flight must still be ACCEPTED — refusing it
#      would strand a caller that has already burned its record-first once-guard — and must SERIALIZE
#      behind the lane lock, so backgrounding never turns the resolve pass into N concurrent
#      `git worktree add`s against one $MAIN.
#
#   D. HEALTHY = BYTE-IDENTICAL — the same drain against a fast lane and a healthy gh must produce the
#      same journal event stream as before this feature: no gh_timeout events, spawn_launched exactly
#      once. This is the guard against "made it available by making it lie".
#
# Hermetic: stub `gh`, stub `herdr` and stub lanes on PATH/in a stub engine dir, a real spawn queue,
# real markers. NO network, NO model, NO live control room, NO tab.
# Run:  bash scripts/herd/sim/tick-availability-sim.sh [--artifacts DIR] [--keep]
# Exit: 0 = every checkpoint passed · 1 = at least one failed.
set -uo pipefail

HERE_SIM="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$(cd "$HERE_SIM/.." && pwd)"
WATCH="$ENGINE/agent-watch.sh"

c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; FAIL=$((FAIL+1)); }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }
PASS=0; FAIL=0

ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
[ -n "$KEEP" ] || trap 'rm -rf "$ART"' EXIT

[ -f "$WATCH" ] || { echo "missing agent-watch.sh at $WATCH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required (journal.sh)" >&2; exit 1; }

now(){ date +%s; }

# ── fixture ───────────────────────────────────────────────────────────────────────────────────────
# A stub engine dir the drain's $HERE points at: the REAL spawn-step.sh (queue mechanics under test)
# plus scriptable fake lanes. A stub gh on PATH, whose behavior each phase re-scripts.
ENG="$ART/eng";   mkdir -p "$ENG"
BIN="$ART/bin";   mkdir -p "$BIN"
TREESD="$ART/trees"; mkdir -p "$TREESD/spawn-queue"
PROJ="$ART/proj"; mkdir -p "$PROJ/.herd"
LANELOG="$ART/lane.log"; : > "$LANELOG"
GH_MODE="$ART/gh.mode"; LANE_SLEEP="$ART/lane.sleep"

cp "$ENGINE/spawn-step.sh" "$ENG/spawn-step.sh"
printf 'WORKTREES_DIR="%s"\nexport WORKTREES_DIR\n' "$TREESD" > "$ENG/herd-config.sh"

cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKSPACE_NAME="simws"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$TREESD"
EOF

# Stub gh: 'hung' never returns; 'ok' answers instantly. Re-scripted per phase via $GH_MODE.
cat > "$BIN/gh" <<GHSTUB
#!/usr/bin/env bash
case "\$(cat "$GH_MODE" 2>/dev/null)" in
  hung) exec sleep 30 ;;
  *)    printf '%s' '[]' ; exit 0 ;;
esac
GHSTUB
chmod +x "$BIN/gh"

# Stub herdr (HERD-189 daemon-hermeticity): spawn_resolver's ACK probe re-reads the driver's roster
# (`herdr agent list`) and falls back to a pane probe (`herdr pane list`). Unstubbed, this sim would
# reach the operator's LIVE control room. An empty roster is the honest answer here — the stub lane
# starts no agent — so the ACK lands on `acked=no`, which is exactly what the sim asserts on: that the
# event is journaled AFTER the lane returns, not that a real agent came up.
cat > "$BIN/herdr" <<'HSTUB'
#!/usr/bin/env bash
printf '%s\n' '{}'
exit 0
HSTUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# Stub lanes: log the invocation, sleep $LANE_SLEEP seconds, exit 0 (a clean spawn).
for lane in herd-feature.sh herd-quick.sh; do
  cat > "$ENG/$lane" <<LANESTUB
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$1" >> "$LANELOG"
sleep "\$(cat "$LANE_SLEEP" 2>/dev/null || echo 0)"
exit 0
LANESTUB
  chmod +x "$ENG/$lane"
done

# Stub resolver lane, same shape.
RESOLVE_STUB="$ENG/herd-resolve.sh"
cat > "$RESOLVE_STUB" <<RSTUB
#!/usr/bin/env bash
printf 'herd-resolve.sh %s\n' "\$1" >> "$LANELOG"
sleep "\$(cat "$LANE_SLEEP" 2>/dev/null || echo 0)"
exit 0
RSTUB
chmod +x "$RESOLVE_STUB"

enqueue(){ ( cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$ENGINE/spawn.sh" "$@" >/dev/null ); }

# Source the REAL watcher in lib mode: helpers only, no loop, no re-exec. This gives us the shipped
# _gh_timeout, _prs_fetch_tick, _pr_body, _gate_status_blessed, spawn_resolver and the real inflight
# markers — the code under test, unmocked.
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$ART/no-such-config"
export WORKTREES_DIR="$TREESD"
export JOURNAL_FILE="$TREESD/journal.jsonl"
export HERD_GH_TIMEOUT_SECS=2      # test seam: the shipped default is 15s
# shellcheck source=/dev/null
. "$WATCH" || { echo "could not source agent-watch.sh in lib mode" >&2; exit 1; }

# The spawn-queue drain is defined BELOW agent-watch.sh's lib-mode return (it belongs to the loop's
# own section), so lib mode does not carry it. Extract it from the shipped source — the same seam
# tests/test-spawn-queue-drain.sh uses — rather than reimplementing it here.
DRAIN_SRC="$ART/drain.sh"; : > "$DRAIN_SRC"
for fn in _spawn_dep_merged _spawn_held_epoch _spawn_mark_held _spawn_clear_held \
          _drain_lane_worker _drain_spawn_queue; do
  sed -n "/^$fn()/,/^}/p" "$WATCH" >> "$DRAIN_SRC"
  grep -q "^$fn()" "$DRAIN_SRC" || { echo "could not extract $fn from agent-watch.sh" >&2; exit 1; }
done
# shellcheck source=/dev/null
. "$DRAIN_SRC"

# Tick globals the drain reads (the real tick computes these earlier in the loop).
HERE="$ENG"; TREES="$TREESD"; FEATS=()
REVIEW_CONCURRENCY=2; SPAWN_AHEAD=1; DRYRUN=""
_BUDGET_DRAIN_PAUSED=""
budget_daily_exceeded(){ return 1; }   # no budget governance in this scenario

# `grep -c` prints 0 AND exits 1 on no match — a bare `|| echo 0` would print "0\n0".
jgrep(){ local c; c="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null || true)"; printf '%s' "${c:-0}"; }

# ── A. a hung gh must not wedge the tick ──────────────────────────────────────────────────────────
step A "hung gh — the gate reads bound, fail soft, and journal"
echo hung > "$GH_MODE"; : > "$JOURNAL_FILE"
a_start="$(now)"

PRS_LOOKUP_OK=1; PRS_JSON='stale'
_prs_fetch_tick
[ "$PRS_LOOKUP_OK" = "0" ] && [ "$PRS_JSON" = "[]" ] \
  && ok "tick PR fetch failed soft (PRS_LOOKUP_OK=0) — never 'zero open PRs'" \
  || bad "tick PR fetch fabricated a result on a hang (ok=$PRS_LOOKUP_OK json=$PRS_JSON)"

body="$(_pr_body 12)"
[ -z "$body" ] && ok "_pr_body → empty on a hang (the human-verify read degrades, never invents)" \
               || bad "_pr_body fabricated a body: '$body'"

if _gate_status_blessed deadbeefcafe; then
  bad "a hung gh BLESSED a sha — both gates would be skipped"
else
  ok "_gate_status_blessed → false on a hang (no fabricated cross-seat blessing)"
fi

a_elapsed=$(( $(now) - a_start ))
info "three hung gh calls cost ${a_elapsed}s at a 2s budget (unbounded: 90s — twenty-plus ticks)"
[ "$a_elapsed" -lt 25 ] && ok "the tick PROCEEDED past a wedged gh (${a_elapsed}s < 25s bound)" \
                        || bad "a hung gh stalled the tick for ${a_elapsed}s"

for site in tick_pr_list pr_body gate_status_blessed; do
  [ "$(jgrep "\"site\":\"$site\"")" -ge 1 ] \
    && ok "journal: gh_timeout site=$site" \
    || bad "no gh_timeout journaled for site=$site (the outage is invisible to \`herd why\`)"
done

# ── B. a slow lane must not wedge the drain ───────────────────────────────────────────────────────
step B "slow builder lane — the drain fires it and returns"
echo ok > "$GH_MODE"; echo 10 > "$LANE_SLEEP"
: > "$JOURNAL_FILE"; : > "$LANELOG"
rm -f "$TREESD/spawn-queue"/* 2>/dev/null || true
enqueue slow-slug feature "a lane that takes ten seconds to make a worktree"

b_start="$(now)"
_drain_spawn_queue
b_elapsed=$(( $(now) - b_start ))
[ "$b_elapsed" -lt 4 ] && ok "_drain_spawn_queue returned in ${b_elapsed}s while its lane still runs (foreground: 10s)" \
                       || bad "the drain BLOCKED ${b_elapsed}s on its lane — G4 is not fixed"

ls "$TREESD/spawn-queue"/*.mine >/dev/null 2>&1 \
  && ok "the intent is still CLAIMED mid-lane (consumed only once the lane is observed — PR #151)" \
  || bad "the intent was consumed before its lane was observed (durability contract broken)"
[ "$(jgrep '"event":"spawn_launched"')" = "0" ] \
  && ok "spawn_launched NOT yet journaled — the outcome is not asserted before it is known" \
  || bad "spawn_launched journaled before the lane returned (a fabricated success)"

# A second tick while that lane is in flight must launch nothing (the one-lane-at-a-time invariant the
# foreground drain enforced implicitly, now enforced by the inflight marker).
enqueue second-slug feature "a sibling intent behind the running lane"
_drain_spawn_queue
[ "$(grep -c '^herd-feature.sh' "$LANELOG")" = "1" ] \
  && ok "a second tick launched NO second lane while one is in flight" \
  || bad "a second lane launched concurrently ($(grep -c '^herd-feature.sh' "$LANELOG") invocations)"

# Let the lane land. Its worker — not the tick — consumes the intent and journals the outcome.
wait
[ "$(jgrep '"event":"spawn_launched"')" -ge 1 ] \
  && ok "the lane landed: its worker journaled spawn_launched (same event, later tick)" \
  || bad "the lane landed but never journaled spawn_launched"
ls "$TREESD/spawn-queue"/*.mine >/dev/null 2>&1 \
  && bad "the landed lane's intent is still claimed (never consumed)" \
  || ok "the landed lane's intent was consumed by its worker"

# ── C. a slow resolver lane must not wedge the tick ───────────────────────────────────────────────
step C "slow resolver lane — spawn_resolver returns before its lane does"
: > "$JOURNAL_FILE"; : > "$LANELOG"
HERD_RESOLVE_BIN="$RESOLVE_STUB"
c_start="$(now)"
spawn_resolver conflict-slug 41 feat/conflict-slug abc1234
c_elapsed=$(( $(now) - c_start ))
[ "$c_elapsed" -lt 4 ] && ok "spawn_resolver returned in ${c_elapsed}s while its lane still runs (foreground: 10s)" \
                       || bad "spawn_resolver BLOCKED ${c_elapsed}s on its lane"
[ -s "$RESOLVE_STATE" ] && grep -q 'conflict-slug' "$RESOLVE_STATE" \
  && ok "the respawn-budget ledger row is down BEFORE the fork (record-first survives a watcher death)" \
  || bad "no resolve-attempt ledger row was recorded"
[ "$(jgrep '"event":"resolver_spawn"')" = "0" ] \
  && ok "resolver_spawn ACK not asserted before the lane returned" \
  || bad "resolver_spawn journaled before the lane could ACK"

# A SECOND conflict dispatched while the first lane is still running must NEVER be REFUSED. Callers
# (_handle_stale_dup, _handle_ci_repair) reach spawn_resolver with a record-first once-guard already
# burned — two of their sites burn it several branches upstream and cannot pre-check anything — so a
# refusal here strands the sha behind a spent guard that no later tick can retry. It must DISPATCH,
# record its ledger row, and let its LANE queue behind the lock.
if spawn_resolver other-slug 42 feat/other-slug def5678; then
  ok "a second dispatch during a live lane is ACCEPTED (never refused behind a caller's spent guard)"
else
  bad "spawn_resolver REFUSED a dispatch — a caller that already burned record_refix strands its sha"
fi
grep -q 'other-slug' "$RESOLVE_STATE" 2>/dev/null \
  && ok "the second dispatch recorded its resolve-attempt row (respawn budget stays sound)" \
  || bad "the second dispatch recorded no ledger row — _resolver_in_flight would read it as dead"

# …and its LANE serializes: the lock means one `git worktree add` against $MAIN at a time.
[ -d "$RESOLVE_LANE_LOCK" ] \
  && ok "the running lane holds the resolver lane lock (the second lane is queued, not concurrent)" \
  || bad "no lane lock is held while a resolver lane runs"
# The lock names its HOLDER (that lane's inflight marker), so a break is liveness-aware and a release
# can verify ownership instead of rm -rf'ing whatever lock happens to be there.
_sim_holder="$(cat "$RESOLVE_LANE_LOCK/holder" 2>/dev/null || true)"
[ -n "$_sim_holder" ] && _marker_live "$_sim_holder" 2>/dev/null \
  && ok "the lock names a LIVE holder marker (breaks are liveness-aware, releases ownership-checked)" \
  || bad "the lane lock has no live holder attribution"
# A queued lane is DISPATCHED, not dead: its slug must read STARTING however long it waits.
[ "$(_resolver_liveness_verdict other-slug 42)" = "STARTING" ] \
  && ok "a queued resolver lane reads STARTING (never DEAD → no re-dispatch, no burned round)" \
  || bad "a queued resolver lane reads $(_resolver_liveness_verdict other-slug 42) — it would be re-dispatched"
_resolver_in_flight other-slug 42 def5678 \
  && ok "the double-dispatch guard holds for a resolver whose lane is merely waiting its turn" \
  || bad "_resolver_in_flight reads false for a dispatched-but-queued resolver"

# THE CALLER'S LEDGER ORDER (the review's failure scenario, exactly). _handle_stale_dup burns a
# record-first once-guard (record_refix) and journals the heal BEFORE calling spawn_resolver. Replay
# that order while a lane is in flight: the dispatch must land, so a later tick reads the resolver as
# in-flight rather than painting the durable "needs you · the bounce was delivered to nobody" row.
record_refix 43 sha43 stale-slug stale
if _resolver_in_flight stale-slug 43 sha43; then
  bad "a resolver read as in-flight for stale-slug before it was dispatched"
else
  spawn_resolver stale-slug 43 feat/stale-slug sha43
  if _resolver_in_flight stale-slug 43 sha43; then
    ok "a caller that already burned record_refix still gets a dispatch (no stranded once-guard)"
  else
    bad "record_refix burned but NO resolver dispatched — this sha's heal is permanently lost"
  fi
fi
refix_attempted 43 sha43 stale \
  && ok "the once-guard is spent AND a dispatch exists to justify it (ledger and reality agree)" \
  || bad "record_refix did not register the once-guard"

_spawn_resolver_wait
[ "$(jgrep '"event":"resolver_spawn"')" -ge 3 ] \
  && ok "ALL THREE resolver lanes landed and journaled their ACK — no dispatch was lost" \
  || bad "only $(jgrep '"event":"resolver_spawn"') of 3 resolver lanes journaled an ACK"
[ "$(grep -c '^herd-resolve.sh' "$LANELOG")" = "3" ] \
  && ok "all three lanes actually ran herd-resolve.sh (serialized, never dropped)" \
  || bad "$(grep -c '^herd-resolve.sh' "$LANELOG") lane invocations (want 3)"
[ "$(jgrep '"event":"resolver_lane_lock_timeout"')" = "0" ] \
  && ok "neither lane had to fall back to unserialized execution" \
  || bad "a lane timed out on the lane lock"

# The lock and the markers are released once the lanes land — nothing wedges the next conflict.
_spawn_inflight_sweep
# The MARKER's hold ends with the lane (the 90s dispatch grace legitimately still holds the verdict at
# STARTING here — that is _resolver_grace_active's job, and it expires on its own).
if _resolver_lane_starting other-slug; then
  bad "a landed lane still reads as lane-STARTING — its marker would hold off every future respawn"
else
  ok "once its lane lands the marker's hold ends (it is liveness, not immortality)"
fi
[ -d "$RESOLVE_LANE_LOCK" ] && bad "the landed lanes left the lane lock held — resolver dispatch wedges" \
                           || ok "the landed lanes released the lane lock"
if _resolver_lane_inflight; then
  bad "a landed resolver lane left its marker behind"
else
  ok "the landed lanes released their inflight markers"
fi

# ── D. the healthy path is byte-identical ────────────────────────────────────────────────────────
step D "healthy gh + fast lane — the event stream is unchanged"
echo ok > "$GH_MODE"; echo 0 > "$LANE_SLEEP"
: > "$JOURNAL_FILE"; : > "$LANELOG"
rm -f "$TREESD/spawn-queue"/* "$TREESD"/.spawn-inflight-* 2>/dev/null || true
enqueue fast-slug quick "a lane that spawns immediately"

PRS_LOOKUP_OK=0; PRS_JSON=''
_prs_fetch_tick
[ "$PRS_LOOKUP_OK" = "1" ] && ok "healthy tick PR fetch: PRS_LOOKUP_OK=1, payload passed through" \
                           || bad "healthy tick PR fetch degraded (ok=$PRS_LOOKUP_OK)"

_drain_spawn_queue
wait
[ "$(jgrep '"event":"gh_timeout"')" = "0" ] \
  && ok "no gh_timeout event on a healthy seat (the guard is invisible when nothing is wedged)" \
  || bad "a healthy seat journaled $(jgrep '"event":"gh_timeout"') gh_timeout event(s)"
[ "$(jgrep '"event":"spawn_launched"')" = "1" ] \
  && ok "spawn_launched exactly once — the drain's event stream is unchanged" \
  || bad "spawn_launched journaled $(jgrep '"event":"spawn_launched"')× (want 1)"
ls "$TREESD/spawn-queue" 2>/dev/null | grep -q . \
  && bad "the healthy drain left the queue non-empty" \
  || ok "the healthy drain consumed its intent"

# No marker may outlive its worker: a leaked lane marker would hold the queue shut forever.
_spawn_inflight_sweep
ls "$TREESD"/.spawn-inflight-* >/dev/null 2>&1 \
  && bad "a spawn-inflight marker leaked past its worker (the queue would wedge)" \
  || ok "no spawn-inflight marker outlived its worker"

# ── scorecard ─────────────────────────────────────────────────────────────────────────────────────
step done "scorecard"
RESULT="pass"; [ "$FAIL" -eq 0 ] || RESULT="fail"
cat > "$ART/scorecard.json" <<EOF
{"scenario":"tick-availability","item":"HERD-237","checkpoints_passed":$PASS,"checkpoints_failed":$FAIL,"result":"$RESULT","artifacts":"$ART"}
EOF
info "scorecard: $ART/scorecard.json"
[ "$FAIL" -eq 0 ] && { echo "ALL PASS ($PASS checkpoints)"; exit 0; }
echo "FAILED ($FAIL checkpoint(s) failed, $PASS passed)"; exit 1
