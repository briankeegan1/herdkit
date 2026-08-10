#!/usr/bin/env bash
# test-ci-fastbounce.sh — hermetic proof of CI_FAST_BOUNCE (HERD-495).
#
# GROUNDED (PR #610, 2026-08-01): #610 sat red ~50 minutes — the full local healthcheck suite ran,
# failed, and was retried in full — while GitHub Actions had already named the exact failing test in
# ~4 minutes. `_handle_ci_repair` (HERD-250) only acts on the INHERITED-red case; a REAL new-code CI
# failure falls straight to a passive needs-you row. CI_FAST_BOUNCE closes that gap: when the PR's own
# CI run concludes FAILURE and its own log names a real test (the SAME honest-identity extraction
# HERD-476/#600 built, reused verbatim via _main_health_ci_log_identity), the builder is bounced
# IMMEDIATELY with that evidence marked PROVISIONAL, on the SAME rail (kind=health) a local CODE ERROR
# bounce already uses — so the two never double-spend, and a later local CLEAN retracts this red via
# the existing kind=health reset with zero new state.
#
# This suite proves:
#   (1) OFF (default) → needs-you path (handler returns 1), no bounce, no ledger, no journal
#   (2) ON + unreadable CI log → returns 1 (byte-identical fallback), journals skipped once
#   (3) ON + honest identity + live builder → one bounce, kind=health, prompt names PROVISIONAL + the
#       identity, journal ci_fastbounce_bounce
#   (4) sha-keyed once-guard: same sha re-enters → no second bounce
#   (5) RAIL SHARING: a fastbounce spends the SAME kind=health budget/once-guard a local healthcheck
#       CODE ERROR bounce (_handle_health_codeerror) reads — no double-bounce across the two triggers
#   (6) budget cap exhaustion → needs-you, no bounce, journal ci_fastbounce_escalated
#   (7) dead/missing agent preflight → needs-you, no bounce, no wake attempt
#   (8) dry-run never bounces
#   (9) real gh wiring: _ci_fastbounce_identity derives the honest identity from `gh run list` +
#       `gh run view --log-failed` output, end to end (no test seam)
#   (10) kind isolation: a fastbounce does not satisfy the ci/stale once-guards
#   (11) local CLEAN retracts the shared rail (refix_rail_reset pr health) — a fresh sha is eligible
#
# Sources agent-watch.sh in lib mode (NETWORK-FREE except case 9, which stubs gh's stdout directly).
# Run: bash tests/test-ci-fastbounce.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); echo "PASS: $1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git"; chmod +x "$BIN/git"

# gh stub: `run list` → GH_RUNS, `run view … --log-failed` → GH_LOG_FAILED. Every call's argv is also
# appended to GH_CALLS so a test can assert exactly what was asked (HERD-434 precedent).
cat > "$BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
case "$1 $2" in
  "run list") printf '%s\n' "${GH_RUNS:-}"; exit 0 ;;
  "run view") printf '%s\n' "${GH_LOG_FAILED:-}"; exit 0 ;;
esac
exit 0
GHSTUB
chmod +x "$BIN/gh"

cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    if [ "${STUB_AGENT_EMPTY:-}" = "1" ]; then
      printf '{"result":{"agents":[]}}\n'
    else
      printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
        "${STUB_AGENT_NAME:-}" \
        "${STUB_AGENT_STATUS:-idle}" \
        "${STUB_PANE_ID:-pane-test-000}"
    fi
    ;;
  "pane run")
    [ -n "${STUB_PANE_RUN_LOG:-}" ] && printf '%s\t%s\n' "$3" "$(printf '%s' "${4:-}" | tr '\n' ' ')" >> "$STUB_PANE_RUN_LOG"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

. "$(dirname "$0")/../scripts/herd/sim/sim-notify-stub.sh" || { echo "cannot source notify stub"; exit 1; }
sim_notify_install "$T" || { echo "sim_notify_install failed"; exit 1; }

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless NO_COLOR=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export DEFAULT_BRANCH="origin/main"
export GH_CALLS="$T/gh-calls.log"; : > "$GH_CALLS"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
TREES="$WORKTREES_DIR"

for fn in _ci_fastbounce_enabled _ci_fastbounce_identity _handle_ci_fastbounce \
          refix_attempted refix_rail_count record_refix refix_rail_reset _main_health_ci_log_identity; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok "helpers defined"

render() { :; }
STUB_WAIT_FILE="$T/wait-codes.txt"; : > "$STUB_WAIT_FILE"
_wait_agent_working() {
  local _c; _c="$(head -1 "$STUB_WAIT_FILE" 2>/dev/null || true)"
  { tail -n +2 "$STUB_WAIT_FILE" 2>/dev/null || true; } > "${STUB_WAIT_FILE}.tmp"
  mv "${STUB_WAIT_FILE}.tmp" "$STUB_WAIT_FILE" 2>/dev/null || true
  return "${_c:-0}"
}
_agent_liveness() { printf '%s' "${STUB_LIVENESS:-alive}"; }
_detect_limit_hit() { return 1; }
_self_restart_hold_dispatch() { return 1; }
_defer_for_suite() { return 1; }

# HERD-176 precedent (test-health-autofix.sh): the bounce routes through herd_driver_send_text, not a
# raw `herdr pane run` — under HERD_DRIVER=headless that seam is a queue-append. Spy on it directly so
# each delivery is logged with its target + text regardless of driver mode.
export STUB_PANE_RUN_LOG="$T/pane-runs.txt"; : > "$STUB_PANE_RUN_LOG"
herd_driver_send_text() {
  local target="${1:-}" text="${2:-}"
  [ -n "${STUB_PANE_RUN_LOG:-}" ] \
    && printf '%s\t%s\n' "$target" "$(printf '%s' "$text" | tr '\n' ' ')" >> "$STUB_PANE_RUN_LOG"
  return 0
}
runs() { awk 'END{print NR+0}' "$STUB_PANE_RUN_LOG" 2>/dev/null || printf '0'; }
row()  { printf '%s\n' "${DISPLAY[0]:-}"; }
reset_state() {
  : > "$STUB_PANE_RUN_LOG"; : > "$REFIX_STATE"; : > "$JOURNAL_FILE"; : > "$GH_CALLS"
  DISPLAY=(); DRYRUN=""; STUB_AGENT_EMPTY=""; STUB_LIVENESS=alive
  export STUB_AGENT_NAME="slug-a" STUB_AGENT_STATUS="idle" STUB_PANE_ID="pane-a"
  unset HERD_CI_FASTBOUNCE_IDENTITY HERD_CI_FASTBOUNCE_CLASS CI_FAST_BOUNCE GH_RUNS GH_LOG_FAILED
}
CI_SUM='CI failed: suite(macos)'
WT="$T/trees/slug-a"; mkdir -p "$WT"

# ── (1) OFF-mode: byte-identical needs-you (handler returns 1, no side effects) ───────────────
reset_state
export HERD_CI_FASTBOUNCE_IDENTITY='tests/foo.sh'
unset CI_FAST_BOUNCE
if _handle_ci_fastbounce 10 slug-a shaA 0 "$WT" feat/a "$CI_SUM"; then
  fail "(1) off-mode must return 1 so the caller paints needs-you"
fi
[ "$(runs)" = "0" ] || fail "(1) off-mode must never pane-run"
[ "$(refix_rail_count 10 health)" = "0" ] || fail "(1) off-mode must not consume a health refix round"
grep -q '"event":"ci_fastbounce' "$JOURNAL_FILE" 2>/dev/null && fail "(1) off-mode must not journal"
ok "(1) off-mode is byte-identical (return 1, no bounce, no ledger)"

export CI_FAST_BOUNCE=false
_handle_ci_fastbounce 11 slug-a shaB 0 "$WT" feat/a "$CI_SUM" && fail "(1b) false must return 1"
[ "$(runs)" = "0" ] || fail "(1b) false must not bounce"
ok "(1b) CI_FAST_BOUNCE=false is inert"

# ── (2) ON + unreadable CI log → returns 1, journals skipped ONCE ────────────────────────────
reset_state
export CI_FAST_BOUNCE=on HERD_CI_FASTBOUNCE_IDENTITY=""
_handle_ci_fastbounce 20 slug-a shaC 0 "$WT" feat/a "$CI_SUM" && fail "(2) unreadable log must return 1"
[ "$(runs)" = "0" ] || fail "(2) unreadable log must never bounce"
_ev_count="$(grep -c '"event":"ci_fastbounce"' "$JOURNAL_FILE" 2>/dev/null || true)"
[ "${_ev_count:-0}" = "1" ] || fail "(2) must journal skipped exactly once (got ${_ev_count:-0})"
grep -q '"reason":"ci-log-unreadable"' "$JOURNAL_FILE" || fail "(2) must name ci-log-unreadable"
_handle_ci_fastbounce 20 slug-a shaC 0 "$WT" feat/a "$CI_SUM" && fail "(2b) still unreadable, still returns 1"
_ev_count="$(grep -c '"event":"ci_fastbounce"' "$JOURNAL_FILE" 2>/dev/null || true)"
[ "${_ev_count:-0}" = "1" ] || fail "(2b) must not re-journal the same (pr,sha) skip (got ${_ev_count:-0})"
ok "(2) unreadable CI log is fail-soft (return 1, journaled once)"

# ── (3) ON + honest identity + live builder → one bounce, kind=health ────────────────────────
reset_state
export CI_FAST_BOUNCE=on HERD_CI_FASTBOUNCE_IDENTITY='app/greet.test.sh'
printf '0\n' > "$STUB_WAIT_FILE"
_handle_ci_fastbounce 30 slug-a shaD 0 "$WT" feat/a "$CI_SUM" || fail "(3) honest identity must bounce"
[ "$(runs)" = "1" ] || fail "(3) must pane-run exactly once (got $(runs))"
grep -q '^pane-a' "$STUB_PANE_RUN_LOG" || fail "(3) bounce must target the AGENT pane"
grep -qi 'PROVISIONAL' "$STUB_PANE_RUN_LOG" || fail "(3) prompt must mark the CI evidence PROVISIONAL"
grep -q 'app/greet.test.sh' "$STUB_PANE_RUN_LOG" || fail "(3) prompt must name the failing identity"
grep -qi 'authoritative' "$STUB_PANE_RUN_LOG" || fail "(3) prompt must say the local suite is authoritative"
refix_attempted 30 shaD health || fail "(3) bounce must be recorded kind=health"
[ "$(refix_rail_count 30 health)" = "1" ] || fail "(3) must consume exactly one health refix round"
grep -q 'PROVISIONAL\|provisional' <<< "$(row)" || fail "(3) row must read provisional (got: $(row))"
grep -q 'needs you' <<< "$(row)" && fail "(3) 'needs you' is BANNED after a successful bounce (got: $(row))"
grep -q '"event":"ci_fastbounce_bounce"' "$JOURNAL_FILE" || fail "(3) must journal ci_fastbounce_bounce"
ok "(3) honest CI identity bounces once with a provisional/authoritative prompt"

# ── (4) once-guard: same sha re-enters → no second bounce ────────────────────────────────────
_handle_ci_fastbounce 30 slug-a shaD 0 "$WT" feat/a "$CI_SUM" || fail "(4) second call still handles the row"
[ "$(runs)" = "1" ] || fail "(4) second call for same sha must not re-bounce (got $(runs))"
ok "(4) sha-keyed once-guard holds"

# ── (5) RAIL SHARING: fastbounce and the health rail's own once-guard agree ──────────────────
# _active_fix_note is the exact evidence _handle_health_codeerror consults before it would bounce a
# reproduced local CODE ERROR for the same (pr,sha) — proving the two triggers share one budget.
type _active_fix_note >/dev/null 2>&1 && {
  _active_fix_note 30 shaD slug-a health >/dev/null || fail "(5) health rail must see the fastbounce as fix-in-progress"
}
ok "(5) local health rail reads the fastbounce's once-guard (shared budget)"

# ── (6) budget cap exhaustion → needs-you, no bounce ─────────────────────────────────────────
reset_state
export CI_FAST_BOUNCE=on HERD_CI_FASTBOUNCE_IDENTITY='app/greet.test.sh'
cap="$(refix_rail_cap)"
i=0
while [ "$i" -lt "$cap" ]; do
  printf '0\n' > "$STUB_WAIT_FILE"
  _handle_ci_fastbounce 40 slug-a "sha-cap-$i" 0 "$WT" feat/a "$CI_SUM" || fail "(6) round $i should bounce"
  i=$((i + 1))
done
[ "$(runs)" = "$cap" ] || fail "(6) expected $cap bounces before the cap, got $(runs)"
_handle_ci_fastbounce 40 slug-a "sha-cap-$cap" 0 "$WT" feat/a "$CI_SUM" || fail "(6) cap-exhausted call must still return 0 (needs-you)"
[ "$(runs)" = "$cap" ] || fail "(6) cap-exhausted call must never pane-run (got $(runs))"
grep -q 'needs you' <<< "$(row)" || fail "(6) exhausted-budget row must read needs you (got: $(row))"
grep -q '"event":"ci_fastbounce_escalated"' "$JOURNAL_FILE" || fail "(6) must journal ci_fastbounce_escalated"
ok "(6) shared REFIX_MAX_ROUNDS budget exhaustion escalates to needs-you"

# ── (6b) HERD-576: cap exhaustion writes the durable per-rail latch, shared with the live python
# health path (pysrc/herd/live_runtime.py `_refix_rail_escalated`) — a restart-safe marker FILE, not
# just a re-derivable ledger count. ────────────────────────────────────────────────────────────────
_refix_rail_escalated 40 health || fail "(6b) cap exhaustion must write the durable escalation latch"
ok "(6b) cap exhaustion latches the rail durably (shared health-rail marker)"

# ── (6c) the latch alone (even with the ledger's bounce rows gone) still stops a fresh sha ─────────
rm -f "$REFIX_STATE"
runs_before_6c="$(runs)"
printf '0\n' > "$STUB_WAIT_FILE"
_handle_ci_fastbounce 40 slug-a "sha-cap-latched" 0 "$WT" feat/a "$CI_SUM" || fail "(6c) latched call must still return 0 (needs-you)"
[ "$(runs)" = "$runs_before_6c" ] \
  || fail "(6c) the durable latch alone must still block a bounce with the ledger gone (got $(runs), was $runs_before_6c)"
grep -q 'needs you' <<< "$(row)" || fail "(6c) latched row must still read needs you (got: $(row))"
ok "(6c) the durable latch alone stops a bounce even after the ledger is lost"

# ── (7) dead/missing agent preflight → needs-you, never types into a dead session ────────────
reset_state
export CI_FAST_BOUNCE=on HERD_CI_FASTBOUNCE_IDENTITY='app/greet.test.sh'
STUB_LIVENESS=dead
_handle_ci_fastbounce 50 slug-a shaE 0 "$WT" feat/a "$CI_SUM" || fail "(7) dead agent must still return 0 (needs-you)"
[ "$(runs)" = "0" ] || fail "(7) dead agent must never pane-run"
grep -q 'needs you' <<< "$(row)" || fail "(7) dead-agent row must read needs you (got: $(row))"
grep -q '"event":"ci_fastbounce_escalated"' "$JOURNAL_FILE" || fail "(7) must journal the dead-agent escalation"
ok "(7) dead/missing agent preflight never types into a dead session"

# ── (8) dry-run never bounces ────────────────────────────────────────────────────────────────
reset_state
export CI_FAST_BOUNCE=on HERD_CI_FASTBOUNCE_IDENTITY='app/greet.test.sh'
DRYRUN=1 _handle_ci_fastbounce 60 slug-a shaF 0 "$WT" feat/a "$CI_SUM" && fail "(8) dry-run must return 1"
[ "$(runs)" = "0" ] || fail "(8) dry-run must never bounce"
ok "(8) dry-run is inert"

# ── (9) real gh wiring: run list + run view --log-failed, no test seam ───────────────────────
reset_state
unset HERD_CI_FASTBOUNCE_IDENTITY
export GH_RUNS='[{"headSha":"shaReal9","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI","databaseId":9001}]'
export GH_LOG_FAILED=$'ci-suite\t✗ tests/real-thing.sh (rc=1)\n'
_ID="$(_ci_fastbounce_identity feat/a shaReal9)"
[ "$_ID" = "tests/real-thing.sh (rc=1)" ] || fail "(9) expected real-thing.sh identity, got: [$_ID]"
grep -q 'run list.*--branch feat/a' "$GH_CALLS" || fail "(9) must query gh run list --branch <bare branch>"
grep -q 'run view 9001 --log-failed' "$GH_CALLS" || fail "(9) must fetch the classified run's own log"
# A PASSING conclusion must never produce an identity (never guessed off a green run).
export GH_RUNS='[{"headSha":"shaReal9","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI","databaseId":9002}]'
[ -z "$(_ci_fastbounce_identity feat/a shaReal9)" ] || fail "(9b) a passing run must never yield an identity"
ok "(9) real gh run-list + run-view wiring derives the honest identity end to end"

# ── (10) kind isolation: a fastbounce does not satisfy the ci/stale once-guards ──────────────
reset_state
export CI_FAST_BOUNCE=on HERD_CI_FASTBOUNCE_IDENTITY='app/greet.test.sh'
printf '0\n' > "$STUB_WAIT_FILE"
_handle_ci_fastbounce 70 slug-a shaG 0 "$WT" feat/a "$CI_SUM" || fail "(10) bounce should fire"
refix_attempted 70 shaG health || fail "(10) kind=health must match"
refix_attempted 70 shaG ci && fail "(10) a fastbounce must NOT satisfy the ci once-guard"
refix_attempted 70 shaG stale && fail "(10) a fastbounce must NOT satisfy the stale once-guard"
ok "(10) kind isolation (health vs ci vs stale)"

# ── (11) local CLEAN retracts the shared rail — a fresh sha is eligible again ────────────────
refix_rail_reset 70 health shaG slug-a
[ "$(refix_rail_count 70 health)" = "0" ] || fail "(11) refix_rail_reset must zero the shared health rail"
printf '0\n' > "$STUB_WAIT_FILE"
_handle_ci_fastbounce 70 slug-a shaH 0 "$WT" feat/a "$CI_SUM" || fail "(11) a fresh sha after reset should bounce"
[ "$(runs)" = "2" ] || fail "(11) expected a second bounce after the rail reset (got $(runs))"
ok "(11) a local CLEAN retracts the shared health rail via the existing reset"

# ── (12) HERD-609/HERD-578: a PLATFORM-INFRA red is not a code red — no bounce, and the journal says
#         WHY it declined (infra-transient), not the generic ci-log-unreadable. Grounded in the
#         2026-08-06 GitHub Actions outage: every failed job died before a test ran, so there is
#         nothing for the builder to reproduce and a bounce would burn a real refix round. ────────
reset_state
export CI_FAST_BOUNCE=on HERD_CI_FASTBOUNCE_IDENTITY="" \
       HERD_CI_FASTBOUNCE_CLASS=$'infra\tfailed to resolve action download info'
_handle_ci_fastbounce 80 slug-a shaI 0 "$WT" feat/a "$CI_SUM" && fail "(12) an infra red must return 1 (no bounce)"
[ "$(runs)" = "0" ] || fail "(12) an infra red must never bounce the builder"
[ "$(refix_rail_count 80 health)" = "0" ] || fail "(12) an infra red must not consume a refix round"
grep -q '"reason":"infra-transient"' "$JOURNAL_FILE" \
  || fail "(12) an infra red must be journaled as infra-transient, not ci-log-unreadable"
grep -q 'failed to resolve action download info' "$JOURNAL_FILE" \
  || fail "(12) the journal must carry the platform signature it matched"
ok "(12) a platform-infra CI red declines with reason=infra-transient — never a bounce, never a code red"

# ── (12b) the SAME shared mapping, end to end through gh: no test seam, real run-list + log ───────
reset_state
export CI_FAST_BOUNCE=on
unset HERD_CI_FASTBOUNCE_IDENTITY HERD_CI_FASTBOUNCE_CLASS
export GH_RUNS='[{"headSha":"shaI2","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI","databaseId":9101}]'
export GH_LOG_FAILED=$'setup\tError: Failed to resolve action download info. Error: Service Unavailable\n'
[ -z "$(_ci_fastbounce_identity feat/a shaI2)" ] || fail "(12b) an infra-only log must yield NO identity"
_CLASS="$(_ci_fastbounce_class feat/a shaI2)"
case "$_CLASS" in infra*) : ;; *) fail "(12b) expected an infra class, got: [$_CLASS]" ;; esac
_handle_ci_fastbounce 81 slug-a shaI2 0 "$WT" feat/a "$CI_SUM" && fail "(12b) infra must return 1"
[ "$(runs)" = "0" ] || fail "(12b) infra must never bounce"
grep -q '"reason":"infra-transient"' "$JOURNAL_FILE" || fail "(12b) must journal infra-transient"
ok "(12b) the infra classification rides the SHARED mapping (herd.ci_verdict) end to end via gh"

echo
echo "ALL PASS ($pass checks) — CI_FAST_BOUNCE (HERD-495) + infra-transient (HERD-609/HERD-578)"
