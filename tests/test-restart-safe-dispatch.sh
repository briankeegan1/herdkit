#!/usr/bin/env bash
# test-restart-safe-dispatch.sh — hermetic proof of the RESTART-SAFE gate dispatch (HERD-185): no marker
# corpse may ever hold a concurrency slot again, and the tick never blocks on a suite. Drives the SHIPPED
# functions in agent-watch.sh (sourced in AGENT_WATCH_LIB mode) — the corpse sweep, the restart-safe
# marker substrate, and the now-ASYNC health gate — against planted marker fixtures.
#
# Asserts:
#   (1) DEAD-PID CORPSE — a .review-inflight-*/.health-inflight-* marker whose pid is dead with NO result
#       waiting is reaped the SAME sweep tick: slot freed, infra_event <family>_died journaled, and (review)
#       the existing retry budget counted — so a re-dispatch can proceed immediately.
#   (2) PAST-DEADLINE LIVE PID — a marker whose recorded pid is alive but whose age (from the marker's OWN
#       dispatch ts) exceeds the family timeout is SIGTERMed + reaped + infra_event <family>_timeout.
#   (3) RESTART-SAFE TIMEOUT — a FRESH agent-watch instance (a separate process that never saw the
#       dispatch) still times a past-deadline marker out, because the age is read from the marker on disk,
#       not an in-process timer a restart would orphan.
#   (4) PID-RECYCLING GUARD — a marker whose pid is alive but whose recorded start-time does NOT match the
#       process's current start-time (the pid number was recycled by an unrelated process) reads as DEAD
#       and is reaped — never mistaken for a live slot holder.
#   (5) SELF-HOLDER GUARD — a past-deadline marker whose pid is THIS watcher process ($$) is never SIGTERMed
#       (a legacy in-process synchronous holder is us; killing it would kill the watcher).
#   (6) ASYNC NON-BLOCKING — a SLOW health suite dispatched for one PR does NOT delay collecting an
#       already-finished verdict for a DIFFERENT PR in the same window (the tick never blocks on a suite).
#
# Fully hermetic: temp dir only, stubbed gh/git/herdr, headless driver, NO network/model/panes.
# Run:  bash tests/test-restart-safe-dispatch.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"; kill "${LIVEPID:-}" "${SLOWPID:-}" 2>/dev/null || true' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# ── stub binaries on PATH (network-free) ─────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# ── source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export HERD_DRIVER=headless
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }
# Hermetic seal (issue #144): every journal write this test triggers MUST land inside the sandbox —
# journal.sh resolves its path from WORKTREES_DIR/JOURNAL_FILE, both pinned into $T above. Assert it
# before any gate/sweep runs, so a future edit that drops the overrides fails loudly instead of
# silently polluting the real .herd/journal.jsonl.
case "$(_journal_file)" in "$T"/*) : ;; *) fail "journal path escapes the sandbox: '$(_journal_file)' (issue #144)" ;; esac

for fn in _sweep_gate_corpses _marker_write _marker_live _marker_age _pid_starttime \
          _review_inflight_file _health_inflight_file _health_dispatch_file _review_retry_count \
          _healthcheck_gate; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

TREES="$WORKTREES_DIR"
# mk_marker <file> <pid> <starttime> <dispatch_ts> — plant a marker with explicit 3-line body.
mk_marker(){ printf '%s\n%s\n%s\n' "$2" "$3" "$4" > "$1"; }
# a genuinely DEAD pid (spawn + reap).
dead_pid(){ bash -c 'exit 0' & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
# grep -c prints "0" AND exits 1 on no match, so a naive `|| printf 0` would emit "0\n0" and break -eq;
# capture the single count (or 0 when the file is absent) and print exactly that.
jgrep(){ local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }

NOW="$(date +%s)"

# ── (1) DEAD-PID CORPSE — review + health both reaped the same sweep tick ────────────────────────
: > "$JOURNAL_FILE"
DP="$(dead_pid)"
RINF="$(_review_inflight_file 278 shaAAA)"
mk_marker "$RINF" "$DP" "irrelevant start" "$NOW"          # dead pid → recycling guard N/A, reaped as corpse
HINF="$(_health_inflight_file "279-shaBBB")"
mk_marker "$HINF" "$DP" "irrelevant start" "$NOW"
_r0="$(_review_retry_count 278 shaAAA)"
_sweep_gate_corpses
[ ! -e "$RINF" ] || fail "(1) dead review corpse must be reaped (marker still present)"
[ ! -e "$HINF" ] || fail "(1) dead health corpse must be reaped (marker still present)"
[ "$(jgrep '"reason":"review_died"')" -ge 1 ] || fail "(1) review corpse must journal infra_event review_died"
[ "$(jgrep '"reason":"health_died"')" -ge 1 ] || fail "(1) health corpse must journal infra_event health_died"
_r1="$(_review_retry_count 278 shaAAA)"
[ "$_r1" -gt "$_r0" ] || fail "(1) a reaped review corpse must count the retry budget ($_r0 -> $_r1)"
ok

# A dead corpse with a RESULT already waiting is LEFT for the gate step to collect (not reaped here).
: > "$JOURNAL_FILE"
RINF2="$(_review_inflight_file 300 shaRES)"; mk_marker "$RINF2" "$(dead_pid)" "s" "$NOW"
: > "$(_review_result_file 300 shaRES)"                    # a verdict is waiting
_sweep_gate_corpses
[ -e "$RINF2" ] || fail "(1b) a corpse WITH a pending result must be left for the gate step to collect"
rm -f "$RINF2" "$(_review_result_file 300 shaRES)" 2>/dev/null || true
ok

# ── (2) PAST-DEADLINE LIVE PID — SIGTERM + timeout journal + retry ───────────────────────────────
: > "$JOURNAL_FILE"
export REVIEW_INFLIGHT_TIMEOUT=3 HEALTH_INFLIGHT_TIMEOUT=3
sleep 300 & LIVEPID=$!; disown "$LIVEPID" 2>/dev/null || true
LST="$(_pid_starttime "$LIVEPID")"
RINF3="$(_review_inflight_file 281 shaLIVE)"
mk_marker "$RINF3" "$LIVEPID" "$LST" "$((NOW - 9999))"     # live pid, age far past the 3s deadline
_marker_live "$RINF3" || fail "(2) precondition: the live-pid marker must read live before the sweep"
_sweep_gate_corpses
[ ! -e "$RINF3" ] || fail "(2) a past-deadline live reviewer must be reaped"
[ "$(jgrep '"reason":"review_timeout"')" -ge 1 ] || fail "(2) a past-deadline reviewer must journal review_timeout"
# The SIGTERM landed: the sleeper is now gone.
sleep 0.3
kill -0 "$LIVEPID" 2>/dev/null && fail "(2) the past-deadline reviewer pid must have been SIGTERMed"
{ wait "$LIVEPID"; } 2>/dev/null || true; LIVEPID=""
ok

# ── (3) RESTART-SAFE TIMEOUT — a FRESH watcher instance still times the marker out from disk ──────
# Model a watcher RESTART: plant a past-deadline live marker, then run the sweep in a SEPARATE process
# that sources agent-watch.sh anew and never saw the dispatch. The age comes from the marker on disk,
# so the fresh instance still fires — proving there is no in-process timer a restart could orphan.
: > "$JOURNAL_FILE"
sleep 300 & LIVEPID=$!; disown "$LIVEPID" 2>/dev/null || true
LST2="$(_pid_starttime "$LIVEPID")"
RINF4="$(_review_inflight_file 282 shaRSTRT)"
mk_marker "$RINF4" "$LIVEPID" "$LST2" "$((NOW - 9999))"
env AGENT_WATCH_LIB=1 HERD_DRIVER=headless WORKTREES_DIR="$TREES" HERD_CONFIG_FILE="$T/no-such-config" \
    JOURNAL_FILE="$JOURNAL_FILE" REVIEW_INFLIGHT_TIMEOUT=3 PATH="$PATH" \
    bash -c '. "$0"; render(){ :; }; _sweep_gate_corpses' "$WATCH" >/dev/null 2>&1
[ ! -e "$RINF4" ] || fail "(3) a restarted watcher must time out a past-deadline marker it never dispatched"
[ "$(jgrep '"reason":"review_timeout"')" -ge 1 ] || fail "(3) restart timeout must still journal review_timeout"
sleep 0.3
kill -0 "$LIVEPID" 2>/dev/null && fail "(3) the restarted sweep must SIGTERM the orphaned reviewer"
{ wait "$LIVEPID"; } 2>/dev/null || true; LIVEPID=""
ok

# ── (4) PID-RECYCLING GUARD — live pid, MISMATCHED start-time → reaped as a corpse ───────────────
: > "$JOURNAL_FILE"
sleep 300 & LIVEPID=$!; disown "$LIVEPID" 2>/dev/null || true
RINF5="$(_review_inflight_file 283 shaRECY)"
mk_marker "$RINF5" "$LIVEPID" "SOME OTHER START TIME" "$NOW"   # pid alive, recorded start-time wrong
_marker_live "$RINF5" && fail "(4) a start-time MISMATCH must read NOT live (recycling guard)"
_sweep_gate_corpses
[ ! -e "$RINF5" ] || fail "(4) a recycled-pid marker must be reaped as a corpse"
[ "$(jgrep '"reason":"review_died"')" -ge 1 ] || fail "(4) a recycled-pid corpse journals review_died"
# The real (unrelated) process must NOT have been killed — the guard reaps the MARKER, never the pid.
kill -0 "$LIVEPID" 2>/dev/null || fail "(4) the recycling guard must never kill the recycled pid's live process"
kill "$LIVEPID" 2>/dev/null || true; LIVEPID=""
ok

# ── (5) SELF-HOLDER GUARD — a past-deadline marker held by THIS process ($$) is never SIGTERMed ──
: > "$JOURNAL_FILE"
RINF6="$(_review_inflight_file 284 shaSELF)"
mk_marker "$RINF6" "$$" "$(_pid_starttime "$$")" "$((NOW - 9999))"
_sweep_gate_corpses                                       # must NOT kill us — we are still running after this
[ -e "$RINF6" ] || fail "(5) the self-held ($$) marker must be LEFT (never TERM the watcher itself)"
[ "$(jgrep '"reason":"review_timeout"')" -eq 0 ] || fail "(5) a self-held marker must not fire a timeout"
rm -f "$RINF6" 2>/dev/null || true
unset REVIEW_INFLIGHT_TIMEOUT HEALTH_INFLIGHT_TIMEOUT
ok

# ── (6) ASYNC NON-BLOCKING — a slow suite for one PR never delays collecting another PR's verdict ─
# Stub healthcheck that sleeps SLOW seconds then passes; dispatch it for PR 401 (holds the slot, in
# flight), then collect PR 402's ALREADY-written verdict. The collect must return CLEAN near-instantly —
# far under the slow suite's runtime — proving the tick does not block on the in-flight suite.
SLOW_HC="$T/slow-hc.sh"
cat > "$SLOW_HC" <<'STUB'
#!/usr/bin/env bash
sleep "${SLOW_SECS:-4}"
printf '✅ clean — slow stub\n'; exit 0
STUB
chmod +x "$SLOW_HC"
export HERD_HEALTHCHECK_BIN="$SLOW_HC" SLOW_SECS=4 HEALTH_CONCURRENCY=1
rm -f "$TREES"/.health-inflight-* "$TREES"/.health-dispatch-* "$TREES"/.health-result-* 2>/dev/null || true
DISPLAY=(); _HC_RESULT=""
t_start="$(date +%s)"
_healthcheck_gate 401 slug-slow "$T/wt" 0 shaSLOW      # dispatch the slow suite (returns immediately)
[ "$_HC_RESULT" = "RUNNING" ] || fail "(6) the slow suite dispatch should return RUNNING (got '$_HC_RESULT')"
SLOWPID="$(_marker_pid "$(_health_inflight_file "401-shaSLOW")")"
disown "$SLOWPID" 2>/dev/null || true
# PR 402 already has a finished verdict on disk — collecting it must not wait on 401's suite.
printf 'CLEAN\tclean\n' > "$(_health_dispatch_file "402-shaFAST")"
_HC_RESULT=""
_healthcheck_gate 402 slug-fast "$T/wt" 1 shaFAST
t_elapsed=$(( $(date +%s) - t_start ))
[ "$_HC_RESULT" = "CLEAN" ] || fail "(6) the finished PR's verdict must collect (got '$_HC_RESULT')"
[ "$t_elapsed" -lt 3 ] || fail "(6) collecting a finished verdict must NOT block on the in-flight slow suite (${t_elapsed}s elapsed, slow=${SLOW_SECS}s)"
# 401's suite is still in flight (we never blocked on it).
_marker_live "$(_health_inflight_file "401-shaSLOW")" || fail "(6) the slow suite should still be in flight after the fast collect"
{ kill "$SLOWPID" 2>/dev/null; wait "$SLOWPID"; } 2>/dev/null || true; SLOWPID=""
ok

echo "ALL PASS ($pass checks)"
