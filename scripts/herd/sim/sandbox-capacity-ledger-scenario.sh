#!/usr/bin/env bash
# scripts/herd/sim/sandbox-capacity-ledger-scenario.sh — HERD-557 P1 capacity-ledger scenario. Design
# doc: docs/spikes/capacity-admission.md (read it first — this scenario proves §7's plan).
#
# Drives the REAL scripts/herd/healthcheck.sh (`--heavy`, real background processes, a stub
# $HEALTHCHECK_CMD recording overlap via busy-files — the same harness shape as
# tests/test-local-suite-slot.sh) for the end-to-end legs, plus direct library/backbone calls (lib-mode
# sourcing of capacity-ledger.sh, and standalone capacity_flock_run.py invocations) for the legs that
# don't need a real suite process. HERMETIC: throwaway temp dirs only, no herdr/gh/network/git.
#
# Asserts, as scorecard checkpoints:
#   partition_math                    — reserved-top/bottom sizing at cap=1/2/4 matches the design doc.
#   overload_breaker                  — a faked high loadavg freezes admission; a normal one doesn't.
#   flock_release_on_kill             — SIGKILLing a flock holder frees its unit immediately (the
#                                        backbone's core "auto-release on death" property).
#   possession_watcher_admits_despite_burst — a builder-local burst holds the ledger first; a watcher
#                                        suite arriving after still admits within ~1 poll tick via its
#                                        reserved-top slot.
#   mutation_prove_reserved_top       — forcing HERD_CAPACITY_RESERVED_TOP_OVERRIDE=0 makes THE SAME
#                                        scenario degrade (the watcher suite now waits out the burst) —
#                                        proves the partition is load-bearing, not vacuous.
#   retry_solo_no_overlap             — a retry-solo run never overlaps a concurrently-running suite.
#   retry_solo_env_suspect_giveup     — a retry-solo run that can't drain within its window gives up
#                                        (tolerated ⚠️, not a hang) rather than running contended.
#   lever_off_no_capacity_files       — CAPACITY_BUDGET unset never creates a `.capacity-*` file.
#
# Usage:
#   bash scripts/herd/sim/sandbox-capacity-ledger-scenario.sh [--artifacts DIR] [--keep]
# Exit: 0 = every checkpoint passed · 1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
HC="$ENGINE/healthcheck.sh"
CAPLIB="$ENGINE/capacity-ledger.sh"
FLOCKRUN="$ENGINE/capacity_flock_run.py"

c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
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
[ -f "$HC" ] || { echo "missing $HC"; exit 1; }
[ -f "$CAPLIB" ] || { echo "missing $CAPLIB"; exit 1; }
[ -f "$FLOCKRUN" ] || { echo "missing $FLOCKRUN"; exit 1; }

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

printf '%s══ Sandbox capacity-ledger scenario (HERD-557 P1) ══%s\n' "$c_bold" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# The stub project health command: writes a per-invocation busy-file into the shared busy-dir ($2)
# (a live "N running right now" signal a couple legs read directly), sleeps STUB_SLEEP, removes it —
# AND appends timestamped CREATE/REMOVE lines (python3's time.time(), not `date`'s non-portable %N) to
# a shared timeline log next to it. The overlap legs below reconstruct exact [start,end) intervals
# from that timeline rather than periodically POLLING the busy-dir — periodic sampling has an
# irreducible race against real scheduling jitter (a sample can land squarely between two true,
# non-overlapping events and misread them as concurrent); a recorded interval intersection is exact
# regardless of when anything happened to be sampled.
STUB="$ART/hc-stub.sh"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
busydir="$2"
mkdir -p "$busydir"
timeline="$busydir/../timeline.log"
me="$busydir/$$.busy"
printf 'CREATE %s %s %s\n' "$$" "$(python3 -c 'import time; print(time.time())')" "${STUB_ROLE:-run}" >> "$timeline"
: > "$me"
sleep "${STUB_SLEEP:-1}"
printf 'REMOVE %s %s %s\n' "$$" "$(python3 -c 'import time; print(time.time())')" "${STUB_ROLE:-run}" >> "$timeline"
rm -f "$me"
exit 0
STUB
chmod +x "$STUB"

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
busy_count() { local d="$1"; [ -d "$d" ] || { echo 0; return; }; find "$d" -name '*.busy' 2>/dev/null | grep -c . || true; }

# timeline_role_overlap <timeline-log> <role> — reconstructs every [CREATE,REMOVE) interval the stub
# recorded (each tagged with a STUB_ROLE) and prints how many OTHER-role intervals any <role>-tagged
# interval intersects (0 = the role in question never overlapped anything else). Deliberately NOT a
# global "did any two intervals overlap" check — two builder-local suites (or two watcher suites)
# legitimately running concurrently is fine; only an overlap INVOLVING the role under test (retry-solo)
# is the violation. Exact interval intersection — no sampling race, see the stub's own comment above.
timeline_role_overlap() {
  local f="$1" role="$2"
  [ -f "$f" ] || { echo 0; return; }
  python3 -c '
import sys
role = sys.argv[2]
starts, ends, roles = {}, {}, {}
with open(sys.argv[1]) as fh:
    for line in fh:
        parts = line.split()
        if len(parts) != 4:
            continue
        kind, pid, ts, r = parts
        ts = float(ts)
        roles[pid] = r
        if kind == "CREATE":
            starts[pid] = ts
        elif kind == "REMOVE":
            ends[pid] = ts
ivals = [(p, starts[p], ends[p]) for p in starts if p in ends]
worst = 0
for p1, s1, e1 in ivals:
    if roles.get(p1) != role:
        continue
    n = 0
    for p2, s2, e2 in ivals:
        if p1 == p2:
            continue
        if s1 < e2 and s2 < e1:
            n += 1
    worst = max(worst, n)
print(worst)
' "$f" "$role"
}

# ── lib-mode: partition math + overload breaker (no processes, no pool) ─────────────────────────────
step lib "source capacity-ledger.sh in lib mode for the pure-function legs"
# shellcheck source=/dev/null
. "$CAPLIB"

t1="$(capacity_reserved_top 1)"; b1="$(capacity_reserved_bottom 1)"
t2="$(capacity_reserved_top 2)"; b2="$(capacity_reserved_bottom 2)"
t4="$(capacity_reserved_top 4)"; b4="$(capacity_reserved_bottom 4)"
if [ "$t1" = 0 ] && [ "$b1" = 0 ] && [ "$t2" = 1 ] && [ "$b2" = 1 ] && [ "$t4" = 1 ] && [ "$b4" = 1 ]; then
  checkpoint partition_math pass "cap=1 -> top=$t1/bot=$b1 (single unit stays a fair-race general slot — reserving it would EXCLUDE a class entirely); cap=2 -> top=$t2/bot=$b2; cap=4 -> top=$t4/bot=$b4"
else
  checkpoint partition_math fail "cap=1 top=$t1/bot=$b1, cap=2 top=$t2/bot=$b2, cap=4 top=$t4/bot=$b4 (want 0/0, 1/1, 1/1)"
fi

HERD_FAKE_LOADAVG=""
export HERD_CAPACITY_CORES_OVERRIDE=4
export HERD_FAKE_LOADAVG=1.0
_ob_low=1; capacity_overload_high && _ob_low=0
export HERD_FAKE_LOADAVG=12.0
_ob_high=1; capacity_overload_high && _ob_high=0
unset HERD_FAKE_LOADAVG HERD_CAPACITY_CORES_OVERRIDE
if [ "$_ob_low" -eq 1 ] && [ "$_ob_high" -eq 0 ]; then
  checkpoint overload_breaker pass "loadavg=1.0/cores=4 -> not overloaded; loadavg=12.0/cores=4 -> overloaded"
else
  checkpoint overload_breaker fail "low-load flag=$_ob_low (want 1) high-load flag=$_ob_high (want 0)"
fi

# ── flock backbone: a killed holder's unit frees immediately ────────────────────────────────────────
step flock "SIGKILL a flock holder and confirm the unit is free right away"
LKPOOL="$ART/lkpool"; mkdir -p "$LKPOOL"
LOCK="$LKPOOL/one.lock"
MARKER="$LKPOOL/holder.marker"
python3 "$FLOCKRUN" --marker "$MARKER" --class probe "$LOCK" -- sleep 20 &
HOLDER=$!
# Wait for the MARKER, not a raced flock probe: capacity_flock_run.py writes it strictly AFTER
# acquiring the lock (see the file itself), so its existence is a reliable "the holder definitely has
# it now" signal — a fresh `python3 -c` probe each loop iteration has its own unpredictable startup
# latency and can race the holder's own startup for several hundred ms on a loaded box.
_fk_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -f "$MARKER" ] && { _fk_ready=1; break; }
  sleep 0.2
done
if [ "$_fk_ready" -eq 0 ]; then
  checkpoint flock_release_on_kill fail "the holder never wrote its marker within 3s — it may not have started; cannot prove anything"
  kill -9 "$HOLDER" 2>/dev/null || true
  wait "$HOLDER" 2>/dev/null || true
else
  # NOW the lock is confirmed held — a probe attempt here must be busy, unracily.
  python3 "$FLOCKRUN" "$LOCK" -- true
  _busy_rc=$?
  kill -9 "$HOLDER" 2>/dev/null || true
  wait "$HOLDER" 2>/dev/null || true
  sleep 0.3
  python3 "$FLOCKRUN" "$LOCK" -- true
  _rc=$?
  if [ "$_busy_rc" -eq 75 ] && [ "$_rc" -eq 0 ]; then
    checkpoint flock_release_on_kill pass "confirmed busy (rc=75) while the holder was live; after SIGKILLing it, a fresh acquire of the SAME lock succeeded immediately (rc=0) — the kernel released it, not any cleanup code"
  else
    checkpoint flock_release_on_kill fail "busy-check rc=$_busy_rc (want 75), post-kill acquire rc=$_rc (want 0)"
  fi
fi

# ── e2e legs: real background `healthcheck.sh --heavy` processes ───────────────────────────────────
run_hc() {   # pool busydir cap class(watcher|builder-local|"") retry(1|"") sleep solo_window role
  local pool="$1" busydir="$2" cap="$3" class="$4" retry="$5" slp="$6" window="$7" role="${8:-run}"
  local prdir="$pool/pr-$$-$RANDOM"; mkdir -p "$prdir"
  local provenance="" retrykind=""
  [ "$class" = "watcher" ] && provenance="watcher"
  [ "$retry" = "1" ] && retrykind="flaky-solo"
  # HERD_FAKE_LOADAVG/HERD_CAPACITY_CORES_OVERRIDE pin the overload breaker to "quiet box" for every
  # e2e leg below — the breaker gets its OWN dedicated, direct checkpoint (lib-mode, real fake-loadavg
  # values) a few steps up; without pinning it here, ambient load on the machine actually RUNNING this
  # scenario (a shared dev/CI box, not this feature's concern) would make the possession/solo/mutation
  # legs correctly-but-confusingly freeze admission on load that has nothing to do with what they test.
  env WORKTREES_DIR="$pool" CAPACITY_BUDGET=on LOCAL_SUITE_CONCURRENCY="$cap" \
      HEALTHCHECK_CMD="$STUB -- $busydir" HERD_CONFIG_FILE="$ART/no-such-config" \
      DEFAULT_BRANCH="no-such-ref-for-tests" STUB_SLEEP="$slp" STUB_ROLE="$role" \
      HERD_CAPACITY_POLL_SECS=0.2 HERD_CAPACITY_SOLO_WAIT_SECS="$window" \
      HERD_FAKE_LOADAVG=0.1 HERD_CAPACITY_CORES_OVERRIDE=8 \
      HERD_HEALTH_PROVENANCE="$provenance" HERD_HEALTH_RETRY_KIND="$retrykind" \
      bash "$HC" "$prdir" --heavy
}

step possession "possession leg: builder-local burst holds the ledger first; watcher still admits fast"
POOL_P="$ART/pool-possession"; mkdir -p "$POOL_P"
BUSY_P="$POOL_P/.busy"
( run_hc "$POOL_P" "$BUSY_P" 2 builder-local "" 2 5 >"$ART/p-b1.out" 2>&1 ) & B1=$!
sleep 0.05
( run_hc "$POOL_P" "$BUSY_P" 2 builder-local "" 2 5 >"$ART/p-b2.out" 2>&1 ) & B2=$!
sleep 0.05
_t0="$(now_ms)"
( run_hc "$POOL_P" "$BUSY_P" 2 watcher "" 1 5 >"$ART/p-w1.out" 2>&1 ) & W1=$!
wait "$W1"; _w1rc=$?
_t1="$(now_ms)"
_w1_ms=$(( _t1 - _t0 ))
wait "$B1" "$B2" 2>/dev/null || true
if [ "$_w1rc" -eq 0 ] && [ "$_w1_ms" -lt 2500 ]; then
  checkpoint possession_watcher_admits_despite_burst pass "watcher admitted+ran in ${_w1_ms}ms despite a 2-suite builder-local burst already holding the ledger (reserved-top slot bypassed the burst)"
else
  checkpoint possession_watcher_admits_despite_burst fail "watcher took ${_w1_ms}ms (rc=$_w1rc) — expected < 2500ms; the burst should never have blocked the reserved-top slot"
fi

step mutation "mutation-prove: HERD_CAPACITY_RESERVED_TOP_OVERRIDE=0 removes the guarantee"
POOL_M="$ART/pool-mutation"; mkdir -p "$POOL_M"
BUSY_M="$POOL_M/.busy"
export HERD_CAPACITY_RESERVED_TOP_OVERRIDE=0
( run_hc "$POOL_M" "$BUSY_M" 2 builder-local "" 2 5 >"$ART/m-b1.out" 2>&1 ) & MB1=$!
sleep 0.05
( run_hc "$POOL_M" "$BUSY_M" 2 builder-local "" 2 5 >"$ART/m-b2.out" 2>&1 ) & MB2=$!
sleep 0.05
_mt0="$(now_ms)"
( run_hc "$POOL_M" "$BUSY_M" 2 watcher "" 1 5 >"$ART/m-w1.out" 2>&1 ) & MW1=$!
wait "$MW1"; _mw1rc=$?
_mt1="$(now_ms)"
_mw1_ms=$(( _mt1 - _mt0 ))
wait "$MB1" "$MB2" 2>/dev/null || true
unset HERD_CAPACITY_RESERVED_TOP_OVERRIDE
if [ "$_mw1rc" -eq 0 ] && [ "$_mw1_ms" -ge 2500 ]; then
  checkpoint mutation_prove_reserved_top pass "with the reserved-top slot removed (override=0), the SAME scenario now makes watcher wait ${_mw1_ms}ms (>= the burst's own runtime) — the possession leg is sensitive to the partition, not vacuously true"
else
  checkpoint mutation_prove_reserved_top fail "expected watcher to be forced to wait (>= 2500ms) once reserved-top is overridden to 0, but it took only ${_mw1_ms}ms — the possession proof would not catch a removed partition"
fi

step solo "retry-solo: never overlaps a concurrent suite, drains then runs alone"
POOL_S="$ART/pool-solo"; mkdir -p "$POOL_S"
BUSY_S="$POOL_S/.busy"
( run_hc "$POOL_S" "$BUSY_S" 2 watcher "" 2 30 blocker >"$ART/s-w1.out" 2>&1 ) & SW1=$!
sleep 0.05
( run_hc "$POOL_S" "$BUSY_S" 2 builder-local "" 2 30 blocker >"$ART/s-b1.out" 2>&1 ) & SB1=$!
sleep 0.05
_ss0="$(now_ms)"
run_hc "$POOL_S" "$BUSY_S" 2 "" 1 2 30 solo >"$ART/s-solo.out" 2>&1
_solorc=$?
_ss1="$(now_ms)"
_solo_ms=$(( _ss1 - _ss0 ))
wait "$SW1" "$SB1" 2>/dev/null || true
# Exact interval-intersection check (see timeline_role_overlap above) — no polling, no sampling race.
# Two "blocker" intervals overlapping each other is EXPECTED (both are ordinary concurrent admits);
# only an overlap the "solo" role is a party to is the violation.
_overlap="$(timeline_role_overlap "$POOL_S/timeline.log" solo)"
if [ "$_overlap" -eq 0 ] && [ "$_solorc" -eq 0 ]; then
  checkpoint retry_solo_no_overlap pass "reconstructed run intervals show the retry-solo run never overlapped another suite (overlap=$_overlap); solo completed rc=0 in ${_solo_ms}ms"
else
  checkpoint retry_solo_no_overlap fail "solo overlap=$_overlap (want 0), solo rc=$_solorc, elapsed=${_solo_ms}ms — solo must never overlap a concurrently-running suite: $(cat "$POOL_S/timeline.log" 2>/dev/null)"
fi

step giveup "retry-solo gives up (env-suspect) rather than waiting/running contended past its window"
POOL_G="$ART/pool-giveup"; mkdir -p "$POOL_G"
BUSY_G="$POOL_G/.busy"
( run_hc "$POOL_G" "$BUSY_G" 1 builder-local "" 5 30 >"$ART/g-block.out" 2>&1 ) & GB=$!
sleep 0.1
_gt0="$(now_ms)"
run_hc "$POOL_G" "$BUSY_G" 1 "" 1 5 1 >"$ART/g-solo.out" 2>&1
_gsolorc=$?
_gt1="$(now_ms)"
_g_ms=$(( _gt1 - _gt0 ))
wait "$GB" 2>/dev/null || true
if [ "$_gsolorc" -eq 0 ] && [ "$_g_ms" -lt 3000 ] && grep -qi "env-suspect\|RETRY-SOLO" "$ART/g-solo.out"; then
  checkpoint retry_solo_env_suspect_giveup pass "solo gave up after its 1s window (${_g_ms}ms elapsed, well under the 5s blocker) and classified env-suspect (tolerated, exit 0) instead of hanging or running contended"
else
  checkpoint retry_solo_env_suspect_giveup fail "rc=$_gsolorc elapsed=${_g_ms}ms — expected rc=0 within ~1-3s and an env-suspect message: $(tail -3 "$ART/g-solo.out" 2>/dev/null)"
fi

step off "CAPACITY_BUDGET unset -> zero .capacity-* files, byte-identical to the legacy HERD-529 path"
POOL_O="$ART/pool-off"; mkdir -p "$POOL_O" "$POOL_O/pr-off"
BUSY_O="$POOL_O/.busy"
env WORKTREES_DIR="$POOL_O" LOCAL_SUITE_CONCURRENCY=2 HEALTHCHECK_CMD="$STUB -- $BUSY_O" \
    HERD_CONFIG_FILE="$ART/no-such-config" DEFAULT_BRANCH="no-such-ref-for-tests" STUB_SLEEP=0 \
    bash "$HC" "$POOL_O/pr-off" --heavy >"$ART/off.out" 2>&1
_offrc=$?
_capfiles="$(find "$POOL_O" -maxdepth 1 -name '.capacity-*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$_offrc" -eq 0 ] && [ "$_capfiles" -eq 0 ]; then
  checkpoint lever_off_no_capacity_files pass "rc=0, zero .capacity-* files created under an unset CAPACITY_BUDGET — the legacy _lss_* path owns this run entirely"
else
  checkpoint lever_off_no_capacity_files fail "rc=$_offrc, .capacity-* file count=$_capfiles (want rc=0, count=0)"
fi

# ── scorecard ─────────────────────────────────────────────────────────────────────────────────────
write_scorecard() {
  local out="$ART/scorecard.json" result="$1" i n; n=${#CP_NAMES[@]}
  {
    printf '{\n  "scenario": "capacity-ledger",\n  "artifacts_dir": "%s",\n  "result": "%s",\n  "passed": %d,\n  "failed": %d,\n  "checkpoints": [\n' \
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
