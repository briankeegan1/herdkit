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
# HERD-641 (Phase 4 of HERD-625, docs/spikes/coordinator-work-queue.md §5.5) adds the DRAIN's own
# admission to this tenant's proofs — the watcher's spawn-queue drain now leases a machine-wide unit
# instead of sizing its budget from its own FEATS roster. Driven in LIB MODE (the drain functions
# extracted from agent-watch.sh, as tests/test-spawn-queue-drain.sh drives them) over the REAL
# spawn-step.sh queue and the REAL ledger:
#   drain_two_seats_one_admission      — two independent drains, ONE pool queue, a 1-unit ledger, both
#                                         seeing an empty FEATS roster: exactly ONE lane launches, the
#                                         rival journals spawn_deferred and hands its intent back as a
#                                         live .req, and the admitted lane carries the
#                                         HERD_AGENT_LEASE_HELD handoff (one unit per agent session).
#   drain_crashed_holder_lease_frees   — SIGKILL the holder (a crashed seat): the kernel drops the
#                                         flock, the next drain reconciles the stale marker away and
#                                         admits the intent that was queued behind it. Reconciled
#                                         against observed state — never an event side-effect.
#   drain_ledger_absent_legacy_identical — CAPACITY_BUDGET unset: the drain keeps the legacy
#                                         cap-minus-FEATS budget (a full roster drains nothing, claims
#                                         nothing, writes zero .capacity-* files), MUTATION-PROVED by a
#                                         control run where flipping only that key makes the identical
#                                         roster admit.
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
# journal_append's write lands a beat AFTER the marker disappears (capacity_agent_lease_hold journals
# only once capacity_flock_run.py has fully returned) — poll briefly rather than a single racy read.
for _ in 1 2 3 4 5 6 7 8; do
  [ -f "$JOURNAL_A" ] && grep -q '"capacity_lease_released"' "$JOURNAL_A" 2>/dev/null && { _a_journaled=1; break; }
  sleep 0.25
done
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
for _ in 1 2 3 4 5 6 7 8; do
  [ -f "$JOURNAL_S" ] && grep -q 'reason.*start_timeout' "$JOURNAL_S" 2>/dev/null && { _t_journaled=1; break; }
  sleep 0.25
done
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

# ══ HERD-641 (Phase 4 of HERD-625) — the spawn-queue DRAIN admits through this same tenant ═════════
# docs/spikes/coordinator-work-queue.md §5.5 measured the gap these three checkpoints close: each
# watcher sized its spawn budget from its OWN `FEATS` roster, so two seats draining ONE pool queue each
# admitted up to their own cap and the fleet jointly exceeded the machine's real budget. The drain now
# leases through the AGENT tenant above instead — same ledger, same comparator, same flock backbone, no
# second counter and no new config key.
#
# The drain is driven in LIB MODE (the functions extracted from agent-watch.sh, exactly as
# tests/test-spawn-queue-drain.sh drives them) against the REAL spawn-step.sh queue mechanics and the
# REAL capacity-ledger.sh — the admission accounting under test is production code's, not a re-model.
step drain "HERD-641: two lib-mode drains over ONE pool queue, admitting through a 1-unit agent ledger"

WATCHSH="$ENGINE/agent-watch.sh"
STEPSH="$ENGINE/spawn-step.sh"
SPAWNSH="$ENGINE/spawn.sh"
_drain_prereq=""
for _f in "$WATCHSH" "$STEPSH" "$SPAWNSH"; do [ -f "$_f" ] || _drain_prereq="${_drain_prereq}missing $_f; "; done

# Extract the drain + the helpers it calls (the SAME set tests/test-spawn-queue-drain.sh extracts).
DRAIN_SRC="$ART/drain-lib.sh"; : > "$DRAIN_SRC"
if [ -z "$_drain_prereq" ]; then
  for _fn in _spawn_slug_key _spawn_inflight_file _lane_lifecycle_key _lane_lifecycle_spawn \
             _lane_lifecycle_retire _spawn_inflight_bg _spawn_inflight_sweep _lane_spawn_inflight \
             _drain_lane_worker _drain_spawn_queue; do
    sed -n "/^$_fn()/,/^}/p" "$WATCHSH" >> "$DRAIN_SRC"
    grep -q "^$_fn()" "$DRAIN_SRC" || _drain_prereq="${_drain_prereq}could not extract $_fn; "
  done
fi

# _drain_env <name> — a fresh, isolated drain world: a pool (which is ALSO the capacity ledger's pool
# and the headless agent registry root), a fake engine dir holding the REAL spawn-step.sh plus scriptable
# fake lanes, and a pinned project config so an enqueue can never reach a real project's queue.
D_POOL=""; D_ENG=""; D_LANELOG=""; D_PROJ=""
_drain_env() {
  local root="$ART/drain-$1"
  D_POOL="$root/trees"; D_ENG="$root/eng"; D_LANELOG="$root/lane.log"; D_PROJ="$root/proj"
  mkdir -p "$D_POOL/spawn-queue" "$D_POOL/.herd/agents" "$D_ENG" "$D_PROJ/.herd"
  : > "$D_LANELOG"
  cp "$STEPSH" "$D_ENG/spawn-step.sh"
  printf 'WORKTREES_DIR="%s"\nexport WORKTREES_DIR\n' "$D_POOL" > "$D_ENG/herd-config.sh"
  cat > "$D_PROJ/.herd/config" <<EOF
PROJECT_ROOT="$D_PROJ"
WORKSPACE_NAME="capleasesim"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$D_POOL"
EOF
  # Fake lanes: record the launch AND the HERD_AGENT_LEASE_HELD handoff the drain passes when it
  # already holds this slug's unit (an unrecorded '1' here would mean the lane leases a SECOND unit for
  # one agent session — the double-spend this phase must not introduce).
  local lane
  for lane in herd-feature.sh herd-quick.sh; do
    cat > "$D_ENG/$lane" <<'FAKELANE'
#!/usr/bin/env bash
printf '%s %s lease_held=%s\n' "$(basename "$0")" "$1" "${HERD_AGENT_LEASE_HELD:-}" >> "$LANELOG"
exit 0
FAKELANE
    chmod +x "$D_ENG/$lane"
  done
}

# _drain_agent_alive <slug> — register a LIVE headless agent session for <slug> in this pool, so the
# lease holder capacity_agent_lease_reserve detaches observes it going alive and then HOLDS the unit
# (herd_driver_agent_liveness under HERD_DRIVER=headless is `kill -0` on this pid).
D_AGENT_PIDS=""
_drain_agent_alive() {
  mkdir -p "$D_POOL/.herd/agents/$1"
  sleep 300 & local p=$!
  disown "$p" 2>/dev/null || true   # keep the end-of-scenario reaping out of the job-control chatter
  printf '%s\n' "$p" > "$D_POOL/.herd/agents/$1/pid"
  D_AGENT_PIDS="$D_AGENT_PIDS $p"
}

_drain_enqueue() { ( cd "$D_PROJ" && HERD_CONFIG_FILE="$D_PROJ/.herd/config" bash "$SPAWNSH" "$@" >/dev/null 2>&1 ); }
_drain_reqs()    { local n; n="$(ls "$D_POOL/spawn-queue"/*.req 2>/dev/null | wc -l | tr -d ' ')"; printf '%s' "${n:-0}"; }  # pipe-ok: one short scalar
# _drain_count <pattern> <file> — `grep -c` prints 0 AND exits 1 on no-match, so a `|| echo 0` fallback
# would emit TWO lines and break every numeric compare below. Normalize once, here.
_drain_count() {
  local n; n="$(grep -c "$1" "$2" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# _drain_tick <jlog> <feats-count> — ONE watcher tick's drain, in a subshell carrying the tick globals
# the drain reads. REVIEW_CONCURRENCY+SPAWN_AHEAD = 1 makes both the legacy budget AND the agent ledger
# exactly ONE unit, so "over-admission" is a single observable event rather than a statistical one.
_drain_tick() {
  local jlog="$1" feats="${2:-0}"
  ( export LANELOG="$D_LANELOG" JLOG="$jlog" WORKTREES_DIR="$D_POOL"
    HERE="$D_ENG"; TREES="$D_POOL"
    FEATS=(); local _i=0; while [ "$_i" -lt "$feats" ]; do FEATS+=("busy-$_i"); _i=$((_i + 1)); done
    SPAWN_INFLIGHT_PREFIX="$D_POOL/.spawn-inflight-"
    _marker_write(){ printf '%s\n' "$2" > "$1" 2>/dev/null || true; }
    _marker_live(){ local p; p="$(sed -n 1p "$1" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
    REVIEW_CONCURRENCY=1; SPAWN_AHEAD=0; DRYRUN=""
    _BUDGET_DRAIN_PAUSED=""
    budget_daily_exceeded(){ return 1; }
    journal_append(){ printf '%s\n' "$*" >> "$JLOG"; }
    # shellcheck source=/dev/null
    . "$DRAIN_SRC"
    _drain_spawn_queue
    wait )
}

export HERD_DRIVER=headless HERD_CONFIG_FILE="$ART/no-such-config" \
       HERD_CAPACITY_AGENT_HOLD_POLL_SECS=1 HERD_CAPACITY_AGENT_DEATH_CONFIRM_TRIES=2 \
       HERD_CAPACITY_AGENT_START_TIMEOUT_SECS=60

# ── drain_two_seats_one_admission ────────────────────────────────────────────────────────────────
if [ -n "$_drain_prereq" ]; then
  checkpoint drain_two_seats_one_admission fail "$_drain_prereq"
else
  _drain_env twoseat
  _drain_agent_alive seat-a-slug; _drain_agent_alive seat-b-slug
  _drain_enqueue seat-a-slug quick "first intent in the shared pool queue"
  _drain_enqueue seat-b-slug quick "second intent, behind it"   # FIFO by the INTENT_ID sequence field, not by wall clock
  J_A="$ART/drain-twoseat-a.log"; J_B="$ART/drain-twoseat-b.log"; : > "$J_A"; : > "$J_B"
  export CAPACITY_BUDGET=on
  _drain_tick "$J_A" 0          # SEAT A: an empty FEATS roster, as a second seat always sees
  _drain_tick "$J_B" 0          # SEAT B: same — this is exactly the §5.5 over-admission setup
  _t_launches="$(_drain_count 'lease_held=' "$D_LANELOG")"
  _t_handoff="$(_drain_count 'lease_held=1' "$D_LANELOG")"
  _t_left="$(_drain_reqs)"
  _t_deferred=0; grep -q 'spawn_deferred .*agent capacity lease unavailable' "$J_B" 2>/dev/null && _t_deferred=1
  if [ "$_t_launches" -eq 1 ] && [ "$_t_handoff" -eq 1 ] && [ "$_t_left" -eq 1 ] && [ "$_t_deferred" -eq 1 ]; then
    checkpoint drain_two_seats_one_admission pass "two independent drains over one queue, each seeing an EMPTY FEATS roster: exactly 1 lane launched, the rival was denied the machine-wide unit and journaled spawn_deferred (agent capacity lease unavailable) with its intent handed back as a live .req — and the admitted lane carried HERD_AGENT_LEASE_HELD=1, so ONE unit covered ONE session"
  else
    checkpoint drain_two_seats_one_admission fail "launches=$_t_launches (want 1) handoff=$_t_handoff (want 1) queued-behind .req=$_t_left (want 1) lease-deferred-journal=$_t_deferred (want 1)"
  fi
fi

# ── drain_crashed_holder_lease_frees ─────────────────────────────────────────────────────────────
# The RETIREMENT-INVARIANT half: a seat that dies holding leases must not wedge the machine's budget.
# Nothing releases the unit as an EVENT — the flock belongs to the holder PROCESS, so the kernel drops
# it the instant that process is killed, and the next drain's own reconciliation (capacity_reclaim_dead
# sweeps the dead-pid marker, the flock attempt decides) admits. Reuses the twoseat world above: its
# queued-behind intent is still a live .req and slot 1 is still held by seat A's holder.
step crashed "a crashed seat's lease frees by reconciliation, and the queued-behind intent then admits"
if [ -n "$_drain_prereq" ]; then
  checkpoint drain_crashed_holder_lease_frees fail "$_drain_prereq"
else
  _c_marker="$(capacity_markerfile "$D_POOL" agent 1)"
  _c_holder="$(sed -n 1p "$_c_marker" 2>/dev/null || true)"
  case "$_c_holder" in ''|*[!0-9]*) _c_holder="" ;; esac
  if [ -z "$_c_holder" ]; then
    checkpoint drain_crashed_holder_lease_frees fail "no live agent-slot-1 holder to crash (marker $_c_marker unreadable) — the two-seat leg did not actually lease"
  else
    pkill -9 -P "$_c_holder" 2>/dev/null || true      # the wait-script child, orphaned by the 'crash'
    kill -9 "$_c_holder" 2>/dev/null || true
    _c_gone=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$_c_holder" 2>/dev/null || { _c_gone=1; break; }; sleep 0.2; done
    _c_marker_stale=0; [ -f "$_c_marker" ] && _c_marker_stale=1   # SIGKILL skipped its own cleanup
    J_C="$ART/drain-twoseat-c.log"; : > "$J_C"; : > "$D_LANELOG"
    _drain_tick "$J_C" 0
    _c_launches="$(_drain_count 'lease_held=1' "$D_LANELOG")"
    _c_left="$(_drain_reqs)"
    if [ "$_c_gone" -eq 1 ] && [ "$_c_marker_stale" -eq 1 ] && [ "$_c_launches" -eq 1 ] && [ "$_c_left" -eq 0 ]; then
      checkpoint drain_crashed_holder_lease_frees pass "SIGKILLing the holder (a crashed seat) left its marker behind as a stale record, yet the very next drain reconciled — swept the dead-pid marker, re-attempted the flock, admitted — and launched the intent that had been queued behind it; the queue is now empty"
    else
      checkpoint drain_crashed_holder_lease_frees fail "holder-killed=$_c_gone (want 1) stale-marker-observed=$_c_marker_stale (want 1) launches-after=$_c_launches (want 1) .req left=$_c_left (want 0)"
    fi
  fi
fi
unset CAPACITY_BUDGET

# ── drain_ledger_absent_legacy_identical ─────────────────────────────────────────────────────────
# The fail-soft fallback, proven BOTH ways so it cannot be vacuous: with the ledger unavailable the
# drain must behave byte-identically to before this phase — budget = cap - ${#FEATS[@]}, so a seat whose
# own roster already fills the cap drains NOTHING and touches no ledger file. The control run flips ONLY
# CAPACITY_BUDGET and the SAME full roster now admits, which is the whole point of the phase: the
# per-seat count stopped being the admission rule.
step fallback "ledger absent -> legacy FEATS budget, byte-identical (and mutation-proved)"
if [ -n "$_drain_prereq" ]; then
  checkpoint drain_ledger_absent_legacy_identical fail "$_drain_prereq"
else
  _drain_env fallback
  _drain_agent_alive fallback-slug
  _drain_enqueue fallback-slug quick "one intent, one seat whose FEATS roster already fills the cap"
  J_OFF="$ART/drain-fallback-off.log"; : > "$J_OFF"
  unset CAPACITY_BUDGET
  _drain_tick "$J_OFF" 1        # cap=1, FEATS=1 -> legacy budget 0 -> return before claiming anything
  _f_launches_off="$(_drain_count 'lease_held=' "$D_LANELOG")"
  _f_left_off="$(_drain_reqs)"
  _f_journal_off="$(_drain_count . "$J_OFF")"
  _f_capfiles="$(find "$D_POOL" -maxdepth 1 -name '.capacity-*' 2>/dev/null | wc -l | tr -d ' ')"
  J_ON="$ART/drain-fallback-on.log"; : > "$J_ON"
  export CAPACITY_BUDGET=on
  _drain_tick "$J_ON" 1         # SAME full roster, ledger armed -> the machine has room -> admits
  _f_launches_on="$(_drain_count 'lease_held=1' "$D_LANELOG")"
  unset CAPACITY_BUDGET
  if [ "$_f_launches_off" -eq 0 ] && [ "$_f_left_off" -eq 1 ] && [ "$_f_journal_off" -eq 0 ] \
     && [ "$_f_capfiles" -eq 0 ] && [ "$_f_launches_on" -eq 1 ]; then
    checkpoint drain_ledger_absent_legacy_identical pass "CAPACITY_BUDGET unset: the drain kept the legacy cap-minus-FEATS budget — a full roster drained nothing, claimed nothing, journaled nothing and created ZERO .capacity-* files; flipping ONLY that key made the identical roster admit, so the fallback is a real branch and the lease is what now decides"
  else
    checkpoint drain_ledger_absent_legacy_identical fail "off: launches=$_f_launches_off (want 0) .req left=$_f_left_off (want 1) journal lines=$_f_journal_off (want 0) .capacity-* files=$_f_capfiles (want 0); on: launches=$_f_launches_on (want 1)"
  fi
fi

for _p in $D_AGENT_PIDS; do kill -9 "$_p" 2>/dev/null || true; done
unset WORKTREES_DIR HERD_DRIVER HERD_CONFIG_FILE \
      HERD_CAPACITY_AGENT_HOLD_POLL_SECS HERD_CAPACITY_AGENT_DEATH_CONFIRM_TRIES HERD_CAPACITY_AGENT_START_TIMEOUT_SECS

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
