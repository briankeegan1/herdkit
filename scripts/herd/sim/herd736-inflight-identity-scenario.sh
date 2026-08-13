#!/usr/bin/env bash
# scripts/herd/sim/herd736-inflight-identity-scenario.sh — HEALTH-INFLIGHT IDENTITY scenario
# (HERD-736, GH #806; covers HERD-734's orphan half too).
#
# REAL-PROCESS TIER. Drives the SHIPPED watcher functions (agent-watch.sh sourced in lib mode,
# AGENT_WATCH_LIB=1) against REAL background processes and REAL signals — no fabricated liveness. The
# grounded incident this proves the fix for: health_died declared on a LIVE suite, a re-dispatch loop
# piling up multiple concurrent healthcheck trees on one .health-log until no verdict is ever recorded
# (a permanent gate stall on a green branch), and orphaned suite processes surviving a watcher restart
# with nothing tracking them (HERD-734).
#
# Modeled failure mode: "the wrapper forks; the tracked pid exiting is normal" — a dispatch's tracked
# pid can legitimately go away while the real suite subtree it started keeps running under an identity
# the marker never named. This scenario enacts that literally: it kills the TRACKED worker pid outright,
# then keeps an INDEPENDENT process appending to the exact same progress-log heartbeat the real suite
# would — standing in for "real work, unlinked from the tracked identity, still provably in progress".
#
# Checkpoints:
#   suite_inflight        — a REAL background worker is dispatched; its inflight marker is live
#   wrapper_pid_lost       — the tracked pid is killed outright (simulating the wrapper's own exit)
#   adopted_not_reaped     — the corpse sweep, seeing a fresh heartbeat, ADOPTS the marker: it survives,
#                            gains a .health-adopted-<key> sidecar, and journals health_inflight_adopted
#                            (never health_died)
#   adopted_sidecar_outside_glob — a SECOND sweep tick never phantom-reaps the sidecar itself (it lives
#                            outside the .health-inflight- prefix its own glob walks — PR #808 round-1)
#   never_double_dispatch  — re-entering the gate while adopted dispatches NO second worker (dispatch
#                            count stays 1, no second healthcheck_started)
#   adoption_not_forever   — once the heartbeat itself goes stale (the surrogate "real work" stops), the
#                            VERY NEXT sweep reclaims it as a genuine corpse: health_died, marker gone
#   redispatch_loop_visible— a genuine crash (dead pid, no heartbeat at all) is reaped, and the following
#                            real re-dispatch for the SAME key journals health_redispatch_loop
#   boot_adopts_live       — _health_inflight_boot_reconcile adopts a live marker on sight, journaled
#   boot_reaps_orphan       — and verified-kills + reaps a genuinely dead one — never an unaccounted
#                            hc-wrapper process surviving a restart (HERD-734)
#
# HERMETIC: temp dir only. `gh`/`herdr`/`git` are PATH stubs; HERD_DRIVER=headless; an isolated
# WORKTREES_DIR + JOURNAL_FILE. Zero model calls, zero quota, zero network, zero real git.
#
# Usage:
#   bash scripts/herd/sim/herd736-inflight-identity-scenario.sh [--artifacts DIR] [--keep]
# Exit: 0 = every checkpoint passed · 1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../agent-watch.sh"

c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) [ $# -ge 2 ] || { echo "herd736-inflight-identity-scenario: --artifacts requires a value" >&2; exit 1; }; ART="$2"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "herd736-inflight-identity-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
[ -n "$KEEP" ] || trap 'rm -rf "$ART"; kill "${SURROGATE_PID:-}" 2>/dev/null || true' EXIT

SCENARIO="health-inflight-identity"
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail; detail="$(printf '%s' "$*" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
  esac
}
assert() { if [ "$2" -eq 0 ]; then checkpoint "$1" pass "$3"; else checkpoint "$1" fail "$3"; fi; }

printf '%s══ HERD-736 health-inflight-identity scenario ══%s\n' "$c_bold" "$c_rst"
printf '  artifacts: %s\n' "$ART"

step wire "source the shipped agent-watch.sh in lib mode against an isolated workspace"
[ -f "$WATCH" ] || { bad "agent-watch.sh not found at $WATCH"; exit 1; }
BIN="$ART/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export HERD_DRIVER=headless
export WORKSPACE_NAME="sim-herd736-$$"
export WORKTREES_DIR="$ART/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$ART/no-such-config"
export JOURNAL_FILE="$ART/journal.jsonl"
export HEALTH_CONCURRENCY=1

# A stub suite that hangs around long enough to observe mid-flight, then would finish on its own — but
# every checkpoint below intervenes before it does, since the scenario is about IDENTITY, not the suite.
HEALTH_BIN="$ART/stub-healthcheck.sh"
cat > "$HEALTH_BIN" <<'EOF'
#!/usr/bin/env bash
sleep 5
echo "✅ clean"
exit 0
EOF
chmod +x "$HEALTH_BIN"
export HERD_HEALTHCHECK_BIN="$HEALTH_BIN"

# shellcheck source=/dev/null
. "$WATCH" || { bad "sourcing agent-watch.sh (lib mode) failed"; exit 1; }
TREES="$WORKTREES_DIR"; MAIN="$ART"
JLOG="$ART/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
jhas() { grep -q -- "$1" "$JLOG"; }
jcount() { grep -c -- "$1" "$JLOG" 2>/dev/null || echo 0; }

WT="$ART/wt-feat-one"; mkdir -p "$WT"
PR=501; SLUG="feat-one"; SHA="restartsha"
KEY="${PR}-${SHA}"
INF="$(_health_inflight_file "$KEY")"
HB="$(_health_heartbeat_file "$KEY")"

info "workspace $WORKSPACE_NAME · key=$KEY"

# ═══ dispatch a REAL background worker ═══════════════════════════════════════════════════════════
step dispatch "the gate dispatches a REAL background health worker"
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate "$PR" "$SLUG" "$WT" 0 "$SHA"
sleep 0.3   # let the forked worker actually start and write its first log bytes
assert suite_inflight $([ "$_HC_RESULT" = "RUNNING" ] && [ -f "$INF" ] && _health_pid_live "$INF" \
  && echo 0 || echo 1) "result=${_HC_RESULT:-none} inflight=$([ -f "$INF" ] && echo yes || echo no)"

TRACKED_PID="$(_marker_pid "$INF")"

# ═══ "the wrapper forks; the tracked pid exiting is normal" ══════════════════════════════════════
step restart-mid-suite "kill the TRACKED pid outright — the real suite work keeps going, untracked"
kill -KILL "$TRACKED_PID" 2>/dev/null || true
for _i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$TRACKED_PID" 2>/dev/null || break; sleep 0.1; done
assert wrapper_pid_lost $(kill -0 "$TRACKED_PID" 2>/dev/null && echo 1 || echo 0) \
  "tracked worker pid $TRACKED_PID is gone (the marker's OWN identity can no longer prove liveness)"

# Stand in for the real, now-untracked suite subtree: an INDEPENDENT process keeps appending to the
# SAME progress-log heartbeat the real worker would — the only channel that can still prove real work
# is happening under an identity this marker never named.
mkdir -p "$(dirname "$HB")"
( while :; do printf 'still testing…\n' >> "$HB" 2>/dev/null; sleep 0.2; done ) &
SURROGATE_PID=$!
sleep 0.3   # let at least one heartbeat land before the sweep runs

# ═══ adopt, never reap, never double-dispatch ════════════════════════════════════════════════════
step adopt "the corpse sweep must ADOPT the heartbeat-corroborated marker, not reap it"
ADOPTED_SIDECAR="$(_health_adopted_file "$KEY")"
_sweep_gate_corpses
assert adopted_not_reaped \
  $([ -f "$INF" ] && [ -f "$ADOPTED_SIDECAR" ] && jhas 'health_inflight_adopted' && ! jhas 'health_died' && echo 0 || echo 1) \
  "marker survives · .health-adopted-<key> sidecar present · health_inflight_adopted journaled · no health_died"

# PR #808 round-1 review regression: a SECOND sweep must not phantom-reap the sidecar itself (it must
# never share the .health-inflight- prefix its own glob walks).
_sweep_gate_corpses
assert adopted_sidecar_outside_glob \
  $([ -f "$INF" ] && ! jhas 'health_died' && echo 0 || echo 1) \
  "a second sweep tick left the real marker standing and journaled no phantom health_died"

DISPLAY=(); _HC_RESULT=""
_healthcheck_gate "$PR" "$SLUG" "$WT" 0 "$SHA"
DISPATCH_COUNT="$(cat "$(_health_dispatch_count_file "$KEY")" 2>/dev/null | tr -cd '0-9')"
MARKER_PID_NOW="$(_marker_pid "$INF")"
# RUNNING is the CORRECT answer here (adopted work is still pending) — the invariant under test is that
# NO second worker was launched: the dispatch counter stays at 1 and the marker's recorded pid (still
# the ORIGINAL, now-dead tracked pid — this marker is adopted, never rewritten) is unchanged.
_ndd_rc=1
if [ "${DISPATCH_COUNT:-0}" = "1" ] && [ "$_HC_RESULT" = "RUNNING" ] && [ "$MARKER_PID_NOW" = "$TRACKED_PID" ]; then
  _ndd_rc=0
fi
assert never_double_dispatch "$_ndd_rc" \
  "re-entering the gate while adopted spawned NO second worker (dispatch_count=${DISPATCH_COUNT:-?}, result=${_HC_RESULT:-none}, marker_pid=${MARKER_PID_NOW:-?})"

# ═══ the adoption is not forever: once the heartbeat itself stops, reclaim it for real ═══════════
step reclaim "once the surrogate 'real work' stops, the NEXT sweep must reclaim the marker as a genuine corpse"
kill "$SURROGATE_PID" 2>/dev/null || true; wait "$SURROGATE_PID" 2>/dev/null || true; SURROGATE_PID=""
HERD_FAKE_NOW=$(( $(date +%s) + _HEALTH_HEARTBEAT_GRACE + 30 )) _sweep_gate_corpses
assert adoption_not_forever $([ ! -f "$INF" ] && jhas 'health_died' && echo 0 || echo 1) \
  "marker reaped · health_died journaled once the heartbeat itself went stale — never wedged forever"

# ═══ redispatch visibility on a genuine crash-and-recover cycle ══════════════════════════════════
step redispatch "a genuine crash (dead pid, no heartbeat) is reaped, then a real re-dispatch is LOUD"
PR2=502; SLUG2="feat-two"; SHA2="crashsha"
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate "$PR2" "$SLUG2" "$WT" 0 "$SHA2"
sleep 0.3
INF2="$(_health_inflight_file "${PR2}-${SHA2}")"
kill -KILL "$(_marker_pid "$INF2")" 2>/dev/null || true
for _i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$(_marker_pid "$INF2")" 2>/dev/null || break; sleep 0.1; done
_sweep_gate_corpses     # no heartbeat at all for this key → genuine corpse, reaped + health_died
DISPLAY=(); _HC_RESULT=""
_healthcheck_gate "$PR2" "$SLUG2" "$WT" 0 "$SHA2"     # the real re-dispatch
sleep 0.2
kill -KILL "$(_marker_pid "$INF2")" 2>/dev/null || true   # tidy up the second real worker
assert redispatch_loop_visible $(jhas 'health_redispatch_loop' && echo 0 || echo 1) \
  "the second real dispatch for ${PR2}-${SHA2} journaled health_redispatch_loop"

# ═══ boot reconcile: adopt what's live, reap+kill what's genuinely gone ══════════════════════════
step boot "a fresh process's FIRST look at inherited markers must be loud, not silent"
: > "$JLOG"
LIVE_KEY="503-bootlive"; LIVE_INF="$(_health_inflight_file "$LIVE_KEY")"
_marker_write "$LIVE_INF" "$$"
DEAD_KEY="504-bootdead"; DEAD_INF="$(_health_inflight_file "$DEAD_KEY")"
( : ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null
printf '%s\n%s\n%s\n' "$DEADPID" "gone" "$(date +%s)" > "$DEAD_INF"
_health_inflight_boot_reconcile
assert boot_adopts_live $([ -f "$LIVE_INF" ] && jhas 'health_inflight_boot_adopted' && echo 0 || echo 1) \
  "a genuinely live marker survives boot reconcile and is journaled, not silently inherited"
assert boot_reaps_orphan $([ ! -f "$DEAD_INF" ] && jhas 'health_inflight_boot_orphan_reaped' && echo 0 || echo 1) \
  "a genuinely dead marker is verified-killed + reaped at boot — never an unaccounted orphan (HERD-734)"

# ═══ scorecard ═══════════════════════════════════════════════════════════════════════════════════
write_scorecard() {
  local out="$ART/scorecard.json" result="$1" i n; n=${#CP_NAMES[@]}
  {
    printf '{\n  "scenario": "%s",\n  "artifacts_dir": "%s",\n  "result": "%s",\n' "$SCENARIO" "$ART" "$result"
    printf '  "passed": %d,\n  "failed": %d,\n  "checkpoints": [\n' "$_pass" "$_fail"
    for ((i=0; i<n; i++)); do
      printf '    {"name": "%s", "status": "%s", "detail": "%s"}' \
        "${CP_NAMES[$i]}" "${CP_STATUS[$i]}" "${CP_DETAIL[$i]}"
      [ "$i" -lt "$((n-1))" ] && printf ',\n' || printf '\n'
    done
    printf '  ]\n}\n'
  } > "$out"
  printf '%s' "$out"
}
RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$(write_scorecard "$RESULT")"
printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  result:        %s\n' "$RESULT"
printf '  passed/failed: %d / %d\n' "$_pass" "$_fail"
printf '  scorecard:     %s\n' "$SCARD"
printf '  artifacts:     %s\n' "$ART"

[ "$RESULT" = "pass" ] && exit 0 || exit 1
