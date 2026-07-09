#!/usr/bin/env bash
# test-auto-refix.sh — hermetic tests for REVIEW_AUTOFIX / auto-refix bounce logic:
#   (1) refix ledger helpers: refix_attempted, refix_round_count, record_refix
#   (2) _find_builder_pane_id targets the AGENT pane (name==slug, status==idle), not root pane
#   (3) REVIEW_AUTOFIX=false → no bounce, standard "review blocked" display
#   (4) AUTOFIX=true, agent wakes on first try → herdr pane run called once, display=refixing
#   (5) AUTOFIX=true, agent never wakes → herdr pane run called twice (initial+retry), display=failed
#   (6) refix-once per sha: second call with same sha → no pane run, display="awaiting push"
#   (7) round cap: after REFIX_MAX_ROUNDS bounces (different shas), next → "refix limit reached"
#   (8) AGENT_WATCH_DRYRUN=1 → no bounce even when REVIEW_AUTOFIX=true
#
# Sources agent-watch.sh in lib mode. Stubs herdr/gh/git (NETWORK-FREE).
# Run:  bash tests/test-auto-refix.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done

# herdr stub: agent list returns a configurable agent; pane run logs the target pane_id.
# STUB_AGENT_NAME / STUB_AGENT_STATUS / STUB_AGENT_PANE_ID control the agent list response.
# STUB_PANE_RUN_LOG: each "herdr pane run <pane_id> <text>" appends "<pane_id>\n" to this file.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
      "${STUB_AGENT_NAME:-}" \
      "${STUB_AGENT_STATUS:-idle}" \
      "${STUB_AGENT_PANE_ID:-pane-test-000}"
    ;;
  "pane run")
    [ -n "${STUB_PANE_RUN_LOG:-}" ] && printf '%s\n' "$3" >> "$STUB_PANE_RUN_LOG"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# Verify new helpers are defined.
for fn in refix_attempted refix_round_count record_refix \
          _find_builder_pane_id _agent_status _wait_agent_working _handle_block_verdict; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# Override render() to a no-op — tests don't need terminal output and the clear + printf '%b'
# would pollute the test console without adding verification value.
render() { :; }

# Override _wait_agent_working to avoid real sleeps.
# STUB_WAIT_FILE: each line is a return code (0=working, 1=not) consumed in call order.
STUB_WAIT_FILE="$T/wait-codes.txt"
_wait_agent_working() {
  local _waw_code
  _waw_code="$(head -1 "$STUB_WAIT_FILE" 2>/dev/null || true)"
  { tail -n +2 "$STUB_WAIT_FILE" 2>/dev/null || true; } > "${STUB_WAIT_FILE}.tmp"
  mv "${STUB_WAIT_FILE}.tmp" "$STUB_WAIT_FILE" 2>/dev/null || true
  return "${_waw_code:-0}"
}

# Shared log for herdr pane run calls.
PANE_LOG="$T/pane-run.log"
export STUB_PANE_RUN_LOG="$PANE_LOG"

# ── (1) ledger helpers: refix_attempted / refix_round_count / record_refix ───
rm -f "$REFIX_STATE"
! refix_attempted "1" "sha-a" || fail "refix_attempted: empty ledger should return false"
ok
[ "$(refix_round_count "1")" -eq 0 ] || fail "refix_round_count: empty ledger should return 0"
ok

record_refix "1" "sha-a" "slug-one"
refix_attempted "1" "sha-a" || fail "refix_attempted: should detect recorded entry"
ok
! refix_attempted "1" "sha-b" || fail "refix_attempted: different sha should not match"
ok
! refix_attempted "2" "sha-a" || fail "refix_attempted: different PR should not match"
ok
[ "$(refix_round_count "1")" -eq 1 ] || fail "refix_round_count: should count 1 after one record"
ok

record_refix "1" "sha-b" "slug-one"
record_refix "1" "sha-c" "slug-one"
[ "$(refix_round_count "1")" -eq 3 ] || fail "refix_round_count: should count 3 after three records"
ok
# Different PR's rounds are independent.
record_refix "2" "sha-a" "slug-two"
[ "$(refix_round_count "2")" -eq 1 ] \
  || fail "refix_round_count PR2: should be 1 (got $(refix_round_count 2))"
ok
[ "$(refix_round_count "1")" -eq 3 ] || fail "refix_round_count PR1: still 3 after adding PR2"
ok

# ── (2) _find_builder_pane_id targets the AGENT pane (idle only), not root pane ─
# Agent with matching name, status idle → returns pane_id.
export STUB_AGENT_NAME="builder-x" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-AGENT-123"
pid="$(_find_builder_pane_id "builder-x")"
[ "$pid" = "pane-AGENT-123" ] \
  || fail "_find_builder_pane_id: should return pane_id for idle agent (got '$pid')"
ok

# Agent with matching name but status "working" → no match (don't bounce an already-busy agent).
export STUB_AGENT_STATUS="working"
pid="$(_find_builder_pane_id "builder-x")"
[ -z "$pid" ] \
  || fail "_find_builder_pane_id: working agent should not be returned (got '$pid')"
ok

# Agent with non-matching name → no match.
export STUB_AGENT_STATUS="idle"
pid="$(_find_builder_pane_id "different-slug")"
[ -z "$pid" ] \
  || fail "_find_builder_pane_id: name mismatch should return nothing (got '$pid')"
ok

# ── (3) REVIEW_AUTOFIX=false → no bounce, standard "review blocked" message ──
rm -f "$REFIX_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="slug-fa" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-fa-001"
DISPLAY=(); REVIEW_AUTOFIX=false; DRYRUN=""
_handle_block_verdict "10" "slug-fa" "sha-fa1" "0"
[ ! -s "$PANE_LOG" ] \
  || fail "AUTOFIX=false: herdr pane run must not be called (log has $(wc -l < "$PANE_LOG") lines)"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "review blocked" \
  || fail "AUTOFIX=false: display should contain 'review blocked' (got: $d)"
ok
# Standard message should contain the herd-approve hints.
printf '%s\n' "$d" | grep -q "herd-approve.sh" \
  || fail "AUTOFIX=false: display should show herd-approve.sh override hint"
ok
! refix_attempted "10" "sha-fa1" || fail "AUTOFIX=false: no refix should be recorded"
ok

# ── (4) AUTOFIX=true, agent wakes on first try → pane run once, display=refixing ──
rm -f "$REFIX_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="slug-b" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-B-456"
printf '0\n' > "$STUB_WAIT_FILE"   # first _wait_agent_working → 0 (working)
DISPLAY=(); REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
_handle_block_verdict "20" "slug-b" "sha-b1" "0"
pane_called="${DISPLAY[0]:-}"; pane_called="$(head -1 "$PANE_LOG" || true)"
[ "$pane_called" = "pane-B-456" ] \
  || fail "AUTOFIX=true: herdr pane run must target the AGENT pane (got '$pane_called')"
ok
[ "$(wc -l < "$PANE_LOG")" -eq 1 ] \
  || fail "AUTOFIX=true wake-on-first: pane run should be called exactly once (got $(wc -l < "$PANE_LOG"))"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "refixing" \
  || fail "AUTOFIX=true wake-on-first: display should show 'refixing' (got: $d)"
ok
printf '%s\n' "$d" | grep -q "round 1/3" \
  || fail "AUTOFIX=true: display should show 'round 1/3' (got: $d)"
ok
refix_attempted "20" "sha-b1" || fail "AUTOFIX=true: refix should be recorded after bounce"
ok

# ── (5) AUTOFIX=true, agent never wakes → pane run twice, display=failed ─────
rm -f "$REFIX_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="slug-c" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-C-789"
printf '1\n1\n' > "$STUB_WAIT_FILE"   # both wait calls → 1 (not working)
DISPLAY=(); REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
_handle_block_verdict "30" "slug-c" "sha-c1" "0"
call_count="$(wc -l < "$PANE_LOG")"
[ "$call_count" -eq 2 ] \
  || fail "AUTOFIX=true never-wakes: pane run should be called twice (initial+retry), got $call_count"
ok
# Both pane run calls must target the AGENT pane, not the root pane.
while IFS= read -r logged_pane; do
  [ "$logged_pane" = "pane-C-789" ] \
    || fail "AUTOFIX=true never-wakes: pane run targeted wrong pane (got '$logged_pane')"
done < "$PANE_LOG"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "auto-refix failed" \
  || fail "AUTOFIX=true never-wakes: display should show 'auto-refix failed' (got: $d)"
ok

# ── (6) refix-once per sha: second call with same sha → no pane run ──────────
rm -f "$REFIX_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="slug-d" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-D-000"
printf '0\n' > "$STUB_WAIT_FILE"
DISPLAY=(); REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
_handle_block_verdict "40" "slug-d" "sha-d1" "0"    # first call → bounce
: > "$PANE_LOG"                                       # clear log
printf '0\n' > "$STUB_WAIT_FILE"                      # reset wait stub
DISPLAY=()
_handle_block_verdict "40" "slug-d" "sha-d1" "0"    # second call, SAME sha → no bounce
[ ! -s "$PANE_LOG" ] \
  || fail "refix-once: second call with same sha should NOT call herdr pane run (log: $(wc -l < "$PANE_LOG") lines)"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "awaiting push" \
  || fail "refix-once: second call should show 'awaiting push' (got: $d)"
ok

# New sha for same PR → eligible for a fresh bounce.
: > "$PANE_LOG"
printf '0\n' > "$STUB_WAIT_FILE"
DISPLAY=()
_handle_block_verdict "40" "slug-d" "sha-d2" "0"    # new sha → should bounce
[ -s "$PANE_LOG" ] \
  || fail "refix-once: new sha for same PR should trigger a fresh bounce"
ok

# ── (6b) LOST ESCALATION on the REVIEW row (HERD-173): a bounce that never woke the builder must keep
# escalating. The refix record is written BEFORE delivery, so the record alone is not proof anyone is
# fixing: tick 1 said "auto-refix failed", and tick 2 used to overwrite it with "awaiting push" forever.
rm -f "$REFIX_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="slug-stuck" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-S-1"
printf '1\n1\n' > "$STUB_WAIT_FILE"      # neither wake attempt succeeds
DISPLAY=(); REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
_handle_block_verdict "60" "slug-stuck" "sha-s1" "0"
printf '%s\n' "${DISPLAY[0]:-}" | grep -q "auto-refix failed" \
  || fail "(6b) tick 1 must escalate a failed wake (got: ${DISPLAY[0]:-})"
runs_before="$(wc -l < "$PANE_LOG")"
DISPLAY=(); _handle_block_verdict "60" "slug-stuck" "sha-s1" "0"     # tick 2 — the sha has not changed
printf '%s\n' "${DISPLAY[0]:-}" | grep -q "fix in progress" \
  && fail "(6b) tick 2 must NOT claim a fix is in flight (got: ${DISPLAY[0]:-})"
printf '%s\n' "${DISPLAY[0]:-}" | grep -q "needs you" \
  || fail "(6b) tick 2 must keep saying 'needs you' (got: ${DISPLAY[0]:-})"
[ "$(wc -l < "$PANE_LOG")" -eq "$runs_before" ] \
  || fail "(6b) the once-guard must still block a re-bounce on tick 2"
ok

# ── (7) round cap: after REFIX_MAX_ROUNDS bounces, next → "refix limit reached" ─
rm -f "$REFIX_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="slug-e" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-E-111"
# Pre-fill 3 rounds (different shas) to hit the cap.
record_refix "50" "sha-e1" "slug-e"
record_refix "50" "sha-e2" "slug-e"
record_refix "50" "sha-e3" "slug-e"
[ "$(refix_round_count "50")" -eq 3 ] || fail "round cap setup: expected 3 recorded rounds"
# Attempt a 4th bounce (new sha — refix_attempted is false for this sha).
DISPLAY=(); REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
_handle_block_verdict "50" "slug-e" "sha-e4" "0"
[ ! -s "$PANE_LOG" ] \
  || fail "round cap: 4th bounce should be suppressed (got $(wc -l < "$PANE_LOG") pane run calls)"
ok
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "refix limit" \
  || fail "round cap: display should show 'refix limit' (got: $d)"
ok
printf '%s\n' "$d" | grep -q "needs you" \
  || fail "round cap: display should show 'needs you' (got: $d)"
ok

# ── (8) DRYRUN=1 → no bounce even when REVIEW_AUTOFIX=true ──────────────────
rm -f "$REFIX_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="slug-f" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-F-222"
DISPLAY=(); REVIEW_AUTOFIX=true; DRYRUN=1; REFIX_MAX_ROUNDS=3
_handle_block_verdict "60" "slug-f" "sha-f1" "0"
[ ! -s "$PANE_LOG" ] \
  || fail "DRYRUN: herdr pane run must not be called in dry-run mode (log has $(wc -l < "$PANE_LOG") lines)"
ok
d="${DISPLAY[0]:-}"
# Dry-run falls through to the REVIEW_AUTOFIX=false path: shows standard "review blocked" message.
printf '%s\n' "$d" | grep -q "review blocked" \
  || fail "DRYRUN: display should show 'review blocked' (got: $d)"
ok
! refix_attempted "60" "sha-f1" \
  || fail "DRYRUN: no refix should be recorded in dry-run mode"
ok

echo "ALL PASS ($pass checks)"
