#!/usr/bin/env bash
# scripts/herd/sim/sandbox-capacity-agent-lease-scenario.sh — HERD-581 (HERD-557 P2) agent-lease
# scenario. Design doc: docs/spikes/capacity-admission.md (read it first — this scenario proves the
# P2 bullet of §6). Sibling of sandbox-capacity-ledger-scenario.sh (P1, suites); this one drives the
# NEW 'agent' tenant capacity-ledger.sh adds (capacity_agent_lease_reserve / _hold) plus
# herd-spawn-gate.sh's new suite-ledger consult.
#
# HERMETIC: throwaway temp dirs only, no herdr/gh/network/git. The AGENT tenant's liveness backbone
# (capacity-agent-lease-wait.sh -> herd_driver_agent_liveness) is exercised via HERD_DRIVER=headless,
# whose liveness IS `kill -0 <pid>` against a REAL backgrounded `sleep` this scenario controls — so
# "an agent's session ends" is proven with a real SIGKILL, the same ground-truth style
# flock_release_on_kill uses in the P1 scenario, no herdr required.
#
# Asserts, as scorecard checkpoints:
#   spawn_class_in_comparator          — capacity_candidate_slots('spawn', cap) == the SAME slot set
#                                         as capacity_candidate_slots('builder-local', cap) at cap 1/2/4
#                                         ("spawns stay the bottom class in the one comparator").
#   spawn_never_leases_reserved_top    — MUTATION-PROVE, not just a pure-function read: with every
#                                         candidate slot spawn is ALLOWED to touch already held, the
#                                         reserved-top slot stays free yet capacity_agent_lease_reserve
#                                         still refuses to admit — proves the exclusion is load-bearing.
#   gate_defers_while_suite_saturated_admits_when_freed — herd-spawn-gate.sh's herd_spawn_gate_saturated
#                                         defers a spawn purely because the SUITE tenant is fully
#                                         contended (zero review/builder signal), and stops deferring
#                                         once the suite holders release.
#   agent_lease_admitted_then_reclaimed_on_kill — a lease admits for a live (headless) agent pid; a
#                                         second lease attempt at cap=1 is denied while it holds; a
#                                         SIGKILL of the agent pid is liveness-reclaimed (journaled
#                                         capacity_lease_released) and the freed unit re-admits.
#   agent_lease_start_timeout_self_releases — a lease reserved for a slug that never goes alive
#                                         self-releases (journaled reason=start_timeout) rather than
#                                         holding the unit forever.
#   lever_off_byte_identical           — CAPACITY_BUDGET unset -> capacity_agent_lease_reserve returns
#                                         0 with ZERO .capacity-* files, and capacity_suite_queue_saturated
#                                         is false — byte-identical to before this feature existed.
#
# Usage: bash scripts/herd/sim/sandbox-capacity-agent-lease-scenario.sh [--artifacts DIR] [--keep]
# Exit: 0 = every checkpoint passed · 1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
CAPLIB="$ENGINE/capacity-ledger.sh"
WAITSCRIPT="$ENGINE/capacity-agent-lease-wait.sh"
SPAWNGATE="$ENGINE/herd-spawn-gate.sh"
JOURNALLIB="$ENGINE/journal.sh"

c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }

ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) [ $# -ge 2 ] || { echo "missing --artifacts value" >&2; exit 1; }; ART="$2"; KEEP=1; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -z "$ART" ] && ART="$(mktemp -d)"
mkdir -p "$ART"
[ -z "$KEEP" ] && trap 'rm -rf "$ART"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 1; }
[ -f "$CAPLIB" ] || { echo "missing $CAPLIB"; exit 1; }
[ -f "$WAITSCRIPT" ] || { echo "missing $WAITSCRIPT"; exit 1; }
[ -f "$SPAWNGATE" ] || { echo "missing $SPAWNGATE"; exit 1; }

# Stub `gh` (mirrors tests/test-spawn-rate-match.sh's own harness): herd_spawn_gate_saturated's
# _sg_open_prs shells out to `gh pr list` unconditionally — without a stub this scenario would query
# whatever REAL repo the ambient `gh` happens to be authenticated against, defeating hermeticity and
# determinism. Always answers an empty PR list, so the gate leg below reads its saturation ENTIRELY
# from the suite-ledger contention it's proving, never from ambient GitHub state.
BIN="$ART/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ] && { printf '[]'; exit 0; }
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

CP_NAMES=(); CP_STATUS=(); CP_DETAIL=(); _pass=0; _fail=0
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail; detail="$(printf '%s' "$*" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
  esac
}

printf '%s══ Sandbox capacity-agent-lease scenario (HERD-581, HERD-557 P2) ══%s\n' "$c_bold" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# Fast, deterministic polling for every leg below — the reserve/hold poll loops otherwise default to
# real-world-friendly (but test-slow) intervals.
export HERD_CAPACITY_AGENT_RESERVE_POLL_TRIES=20
export HERD_CAPACITY_AGENT_RESERVE_POLL_SECS=0.05
export HERD_CAPACITY_CORES_OVERRIDE=8
export HERD_FAKE_LOADAVG=0.1

# ── lib-mode: source herd-config.sh (herd_numeric — herd-spawn-gate.sh's own contract requires it
# sourced first) + the ledger + spawn-gate directly. HERD_CONFIG_FILE points nowhere so every key
# resolves to its shipped default, exactly like the P1 scenario's own healthcheck.sh invocations.
step lib "source herd-config.sh + capacity-ledger.sh + herd-spawn-gate.sh in lib mode"
export HERD_CONFIG_FILE="$ART/no-such-config"
# shellcheck source=/dev/null
. "$ENGINE/herd-config.sh"
# shellcheck source=/dev/null
. "$CAPLIB"
# shellcheck source=/dev/null
. "$SPAWNGATE"

# ── spawn_class_in_comparator ────────────────────────────────────────────────────────────────────
step comparator "capacity_candidate_slots('spawn', cap) mirrors 'builder-local' exactly"
_mismatch=""
for cap in 1 2 4; do
  sset="$(capacity_candidate_slots spawn "$cap" | tr '\n' ',')"
  bset="$(capacity_candidate_slots builder-local "$cap" | tr '\n' ',')"
  [ "$sset" = "$bset" ] || _mismatch="${_mismatch}cap=$cap spawn=[$sset] builder-local=[$bset]; "
done
if [ -z "$_mismatch" ]; then
  checkpoint spawn_class_in_comparator pass "cap=1/2/4: spawn's candidate slot order equals builder-local's, in every case"
else
  checkpoint spawn_class_in_comparator fail "$_mismatch"
fi

# ── spawn_never_leases_reserved_top (mutation-prove) ─────────────────────────────────────────────
step top-slice "mutation-prove: spawn refuses to admit even while the reserved-top slot sits free"
POOL_T="$ART/pool-top"; mkdir -p "$POOL_T"
export WORKTREES_DIR="$POOL_T" CAPACITY_BUDGET=on REVIEW_CONCURRENCY=1 SPAWN_AHEAD=1  # cap=2: top=1, bottom=1, general=0
# Hold the ONLY slot spawn may ever touch (the bottom slot, index 2) directly via capacity_flock_run.py
# — a raw suite-shaped holder is enough; the point under test is admission, not what holds slot 2.
BOTTOM_LOCK="$(capacity_lockfile "$POOL_T" agent 2)"
python3 "$ENGINE/capacity_flock_run.py" --marker "$(capacity_markerfile "$POOL_T" agent 2)" --class probe "$BOTTOM_LOCK" -- sleep 5 &
HOLDER=$!
_wait_marker=0
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$(capacity_markerfile "$POOL_T" agent 2)" ] && { _wait_marker=1; break; }; sleep 0.2; done
if [ "$_wait_marker" -eq 0 ]; then
  checkpoint spawn_never_leases_reserved_top fail "the slot-2 holder never wrote its marker — cannot prove anything"
  kill -9 "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
else
  # A direct flock probe on slot 1 (the reserved-top lockfile) is the real "was it free" proof —
  # absence of the lockfile alone would only mean "never yet attempted", not "free".
  python3 "$ENGINE/capacity_flock_run.py" "$(capacity_lockfile "$POOL_T" agent 1)" -- true
  _top_acquirable=$?
  if capacity_agent_lease_reserve 2 spawn-probe-slug; then _reserved=0; else _reserved=1; fi
  kill -9 "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
  if [ "$_top_acquirable" -eq 0 ] && [ "$_reserved" -eq 1 ]; then
    checkpoint spawn_never_leases_reserved_top pass "slot 1 (reserved-top) was independently confirmed FREE (rc=0) the whole time, yet capacity_agent_lease_reserve still refused to admit (denied) while only the bottom slot was busy — the exclusion is load-bearing, not vacuous"
  else
    checkpoint spawn_never_leases_reserved_top fail "top-slot-free-probe rc=$_top_acquirable (want 0), lease reserve denied=$_reserved (want 1) — spawn must NEVER fall back to the reserved-top slot"
  fi
fi
unset WORKTREES_DIR CAPACITY_BUDGET REVIEW_CONCURRENCY SPAWN_AHEAD

# ── gate_defers_while_suite_saturated_admits_when_freed ──────────────────────────────────────────
step gate "herd-spawn-gate.sh defers purely on suite-ledger contention, admits once it frees"
POOL_G="$ART/pool-gate"; mkdir -p "$POOL_G"
export WORKTREES_DIR="$POOL_G" CAPACITY_BUDGET=on LOCAL_SUITE_CONCURRENCY=1 REVIEW_CONCURRENCY=2 SPAWN_AHEAD=1
unset PROJECT_ROOT  # no git repo -> _sg_count_inflight_builders reads 0; no gh -> queued reviews read 0
GHOLD_LOCK="$(capacity_lockfile "$POOL_G" suite 1)"
python3 "$ENGINE/capacity_flock_run.py" --marker "$(capacity_markerfile "$POOL_G" suite 1)" --class builder-local "$GHOLD_LOCK" -- sleep 5 &
GHOLDER=$!
_g_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$(capacity_markerfile "$POOL_G" suite 1)" ] && { _g_ready=1; break; }; sleep 0.2; done
if [ "$_g_ready" -eq 0 ]; then
  checkpoint gate_defers_while_suite_saturated_admits_when_freed fail "the suite holder never wrote its marker — cannot prove anything"
  kill -9 "$GHOLDER" 2>/dev/null || true; wait "$GHOLDER" 2>/dev/null || true
else
  if herd_spawn_gate_saturated; then _g_sat_while_busy=0; else _g_sat_while_busy=1; fi
  _g_reason_capacity="${_SG_CAPACITY:-}"
  kill -9 "$GHOLDER" 2>/dev/null || true; wait "$GHOLDER" 2>/dev/null || true
  sleep 0.3
  if herd_spawn_gate_saturated; then _g_sat_after_free=0; else _g_sat_after_free=1; fi
  if [ "$_g_sat_while_busy" -eq 0 ] && [ "$_g_reason_capacity" = "1" ] && [ "$_g_sat_after_free" -eq 1 ]; then
    checkpoint gate_defers_while_suite_saturated_admits_when_freed pass "with zero review/builder signal, herd_spawn_gate_saturated returned SATURATED (_SG_CAPACITY=1) purely from the fully-contended suite ledger, then returned headroom once the sole suite unit freed"
  else
    checkpoint gate_defers_while_suite_saturated_admits_when_freed fail "while-busy saturated=$_g_sat_while_busy (want 0) capacity-flag=$_g_reason_capacity (want 1), after-free saturated=$_g_sat_after_free (want 1, i.e. NOT saturated)"
  fi
fi
unset WORKTREES_DIR CAPACITY_BUDGET LOCAL_SUITE_CONCURRENCY REVIEW_CONCURRENCY SPAWN_AHEAD

# ── agent_lease_admitted_then_reclaimed_on_kill ──────────────────────────────────────────────────
step agent "a headless agent's lease admits, denies a rival at cap=1, and liveness-reclaims on SIGKILL"
POOL_A="$ART/pool-agent"; mkdir -p "$POOL_A/.herd/agents/agent-one"
JOURNAL_A="$ART/journal-a.jsonl"
export WORKTREES_DIR="$POOL_A" CAPACITY_BUDGET=on HERD_DRIVER=headless \
       HERD_CONFIG_FILE="$ART/no-such-config" JOURNAL_FILE="$JOURNAL_A" \
       HERD_CAPACITY_AGENT_HOLD_POLL_SECS=1 HERD_CAPACITY_AGENT_DEATH_CONFIRM_TRIES=2 \
       HERD_CAPACITY_AGENT_START_TIMEOUT_SECS=30
# shellcheck source=/dev/null
[ -f "$JOURNALLIB" ] && . "$JOURNALLIB"
sleep 300 & AGENT_PID=$!
printf '%s\n' "$AGENT_PID" > "$POOL_A/.herd/agents/agent-one/pid"
if capacity_agent_lease_reserve 1 agent-one; then _a1_admit=0; else _a1_admit=1; fi
sleep 0.3
if capacity_agent_lease_reserve 1 agent-two; then _a2_admit=0; else _a2_admit=1; fi   # cap=1 -> the only unit is agent-one's
kill -9 "$AGENT_PID" 2>/dev/null || true
_a_reclaimed=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if [ ! -f "$(capacity_markerfile "$POOL_A" agent 1)" ]; then _a_reclaimed=1; break; fi
  sleep 0.5
done
_a_journaled=0
[ -f "$JOURNAL_A" ] && grep -q '"capacity_lease_released"' "$JOURNAL_A" 2>/dev/null && _a_journaled=1
if capacity_agent_lease_reserve 1 agent-three; then _a3_admit=0; else _a3_admit=1; fi  # freed -> should admit now
if [ "$_a1_admit" -eq 0 ] && [ "$_a2_admit" -eq 1 ] && [ "$_a_reclaimed" -eq 1 ] && [ "$_a_journaled" -eq 1 ] && [ "$_a3_admit" -eq 0 ]; then
  checkpoint agent_lease_admitted_then_reclaimed_on_kill pass "agent-one admitted (rc=0) at a live pid; agent-two denied at cap=1 while it held; SIGKILLing the pid reclaimed the marker (<=7.5s poll) and journaled capacity_lease_released; agent-three then admitted into the freed unit"
else
  checkpoint agent_lease_admitted_then_reclaimed_on_kill fail "agent-one admit=$_a1_admit(want 0) agent-two admit=$_a2_admit(want 1) reclaimed=$_a_reclaimed(want 1) journaled=$_a_journaled(want 1) agent-three admit=$_a3_admit(want 0)"
fi
wait "$AGENT_PID" 2>/dev/null || true

# ── agent_lease_start_timeout_self_releases ──────────────────────────────────────────────────────
step timeout "a lease reserved for a slug that never goes alive self-releases (start_timeout)"
POOL_S="$ART/pool-timeout"; mkdir -p "$POOL_S/.herd/agents"
JOURNAL_S="$ART/journal-s.jsonl"
export WORKTREES_DIR="$POOL_S" HERD_CONFIG_FILE="$ART/no-such-config" JOURNAL_FILE="$JOURNAL_S" \
       HERD_CAPACITY_AGENT_HOLD_POLL_SECS=1 HERD_CAPACITY_AGENT_START_TIMEOUT_SECS=2 \
       HERD_CAPACITY_AGENT_DEATH_CONFIRM_TRIES=2 \
       HERD_CAPACITY_AGENT_RESERVE_POLL_TRIES=4 HERD_CAPACITY_AGENT_RESERVE_POLL_SECS=0.05  # a short RESERVE settle window (0.2s), well UNDER the start-timeout above (2s) — else the two races each other
if capacity_agent_lease_reserve 1 never-alive-slug; then _t_admit=0; else _t_admit=1; fi
_t_released=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ -f "$(capacity_markerfile "$POOL_S" agent 1)" ] || { _t_released=1; break; }
  sleep 0.5
done
_t_journaled=0
[ -f "$JOURNAL_S" ] && grep -q 'reason.*start_timeout' "$JOURNAL_S" 2>/dev/null && _t_journaled=1
if [ "$_t_admit" -eq 0 ] && [ "$_t_released" -eq 1 ] && [ "$_t_journaled" -eq 1 ]; then
  checkpoint agent_lease_start_timeout_self_releases pass "the lease admitted, then self-released within its start timeout (never observed the slug going alive) and journaled reason=start_timeout"
else
  checkpoint agent_lease_start_timeout_self_releases fail "admit=$_t_admit(want 0) released=$_t_released(want 1) journaled=$_t_journaled(want 1)"
fi
unset WORKTREES_DIR CAPACITY_BUDGET HERD_DRIVER HERD_CONFIG_FILE JOURNAL_FILE \
      HERD_CAPACITY_AGENT_HOLD_POLL_SECS HERD_CAPACITY_AGENT_DEATH_CONFIRM_TRIES HERD_CAPACITY_AGENT_START_TIMEOUT_SECS

# ── lever_off_byte_identical ─────────────────────────────────────────────────────────────────────
step off "CAPACITY_BUDGET unset -> zero .capacity-* files, capacity_suite_queue_saturated is false"
POOL_O="$ART/pool-off"; mkdir -p "$POOL_O"
export WORKTREES_DIR="$POOL_O"
unset CAPACITY_BUDGET
if capacity_agent_lease_reserve 2 off-slug; then _o_rc=0; else _o_rc=1; fi
_o_capfiles="$(find "$POOL_O" -maxdepth 1 -name '.capacity-*' 2>/dev/null | wc -l | tr -d ' ')"
if capacity_suite_queue_saturated; then _o_suitesat=0; else _o_suitesat=1; fi
if [ "$_o_rc" -eq 0 ] && [ "$_o_capfiles" -eq 0 ] && [ "$_o_suitesat" -eq 1 ]; then
  checkpoint lever_off_byte_identical pass "rc=0 (proceeds unslotted), zero .capacity-* files, capacity_suite_queue_saturated=false — CAPACITY_BUDGET unset never touches the ledger"
else
  checkpoint lever_off_byte_identical fail "rc=$_o_rc (want 0), .capacity-* count=$_o_capfiles (want 0), suite-saturated=$_o_suitesat (want 1/false)"
fi
unset WORKTREES_DIR

# ── scorecard ─────────────────────────────────────────────────────────────────────────────────────
write_scorecard() {
  local out="$ART/scorecard.json" result="$1" i n; n=${#CP_NAMES[@]}
  {
    printf '{\n  "scenario": "capacity-agent-lease",\n  "artifacts_dir": "%s",\n  "result": "%s",\n  "passed": %d,\n  "failed": %d,\n  "checkpoints": [\n' \
      "$ART" "$result" "$_pass" "$_fail"
    for ((i=0; i<n; i++)); do
      printf '    {"name": "%s", "status": "%s", "detail": "%s"}' "${CP_NAMES[$i]}" "${CP_STATUS[$i]}" "${CP_DETAIL[$i]}"
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
[ "$RESULT" = "pass" ] && exit 0 || exit 1
