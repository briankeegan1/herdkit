#!/usr/bin/env bash
# test-stale-base-autofix.sh — hermetic proof of STALE_BASE_AUTOFIX (HERD-199).
#
# The stale-dup gate (HERD-188) holds two flavors. This suite proves the STALE-BASE flavor
# self-heals when STALE_BASE_AUTOFIX=on, while DUPLICATE stays human and off-mode is byte-identical.
#
#   (1) OFF (default) + stale-base → needs-you row, no bounce, no ledger write
#   (2) ON + live builder + stale-base → one pane-run bounce, kind=stale, row "rebasing · awaiting push"
#   (3) once-guard: same sha re-enters → no second bounce; still "rebasing · awaiting push"
#   (4) shared budget with review refix; cap → needs-you · refix limit
#   (5) no live builder (foreign/reaped) → conflict resolver dispatched (not needs-you)
#   (6) DUPLICATE flavor always human, even with autofix ON
#   (7) dry-run never bounces
#   (8) kind isolation: a stale bounce does not satisfy the review once-guard
#
# Sources agent-watch.sh in lib mode. Stubs herdr/gh/git (NETWORK-FREE).
# Run:  bash tests/test-stale-base-autofix.sh
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
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done

# herdr stub: agent list returns a configurable agent; pane run logs pane_id + prompt.
# STUB_AGENT_EMPTY=1 → report zero agents (foreign/reaped PR).
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

# HERD-139 notify stub: escalation paths fire real desktop notifications without it (hermeticity belt catch)
. "$(dirname "$0")/../scripts/herd/sim/sim-notify-stub.sh" || { echo "cannot source notify stub"; exit 1; }
sim_notify_install "$T" || { echo "sim_notify_install failed"; exit 1; }

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export DEFAULT_BRANCH="origin/main"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
TREES="$WORKTREES_DIR"

for fn in _stale_base_autofix_enabled _stale_has_live_builder _handle_stale_dup \
          refix_attempted refix_round_count record_refix spawn_resolver; do
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
_resolver_agent_alive() { [ "${STUB_RESOLVER_ALIVE:-0}" = "1" ]; }
_resolver_in_flight() { local _s="$1" _p="$2"; [ "${STUB_RESOLVER_ALIVE:-0}" = "1" ]; }  # arity-2, matches the real helper under set -u
_detect_limit_hit() { return 1; }

# Capture spawn_resolver calls instead of launching real resolvers.
RESOLVE_LOG="$T/resolve.log"; : > "$RESOLVE_LOG"
spawn_resolver() {
  printf '%s %s %s %s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}" >> "$RESOLVE_LOG"
}

export STUB_PANE_RUN_LOG="$T/pane-runs.txt"; : > "$STUB_PANE_RUN_LOG"
runs() { awk 'END{print NR+0}' "$STUB_PANE_RUN_LOG" 2>/dev/null || printf '0'; }
rslv() { awk 'END{print NR+0}' "$RESOLVE_LOG" 2>/dev/null || printf '0'; }
row()  { printf '%s\n' "${DISPLAY[0]:-}"; }
reset_state() {
  : > "$STUB_PANE_RUN_LOG"; : > "$RESOLVE_LOG"; : > "$REFIX_STATE"; : > "$JOURNAL_FILE"
  DISPLAY=(); DRYRUN=""; STUB_AGENT_EMPTY=""; STUB_LIVENESS=alive
  export STUB_AGENT_NAME="slug-a" STUB_AGENT_STATUS="idle" STUB_PANE_ID="pane-a"
}
REASON='stale base: 1 touched file(s) were changed on origin/main after this branch merge-base (e.g. A.txt)'
WT="$T/trees/slug-a"; mkdir -p "$WT"

# ── (1) OFF-mode: stale-base is byte-identical (needs-you, no bounce, no ledger) ───────────────
reset_state
unset STALE_BASE_AUTOFIX
_handle_stale_dup 10 slug-a shaA 0 "$WT" feat/a stale-base "$REASON"
row | grep -q 'needs you' || fail "(1) off-mode must read 'needs you' (got: $(row))"
row | grep -q 'stale/duplicate (stale-base)' || fail "(1) off-mode must name stale-base (got: $(row))"
[ "$(runs)" = "0" ] || fail "(1) off-mode must never pane-run"
[ "$(rslv)" = "0" ] || fail "(1) off-mode must never spawn a resolver"
[ "$(refix_round_count 10)" = "0" ] || fail "(1) off-mode must not consume a refix round"
ok "(1) off-mode stale-base is byte-identical needs-you"

export STALE_BASE_AUTOFIX=false
_handle_stale_dup 11 slug-a shaB 0 "$WT" feat/a stale-base "$REASON"
[ "$(runs)" = "0" ] || fail "(1b) STALE_BASE_AUTOFIX=false must not bounce"
[ "$(refix_round_count 11)" = "0" ] || fail "(1b) false must not consume a round"
ok "(1b) STALE_BASE_AUTOFIX=false is inert"

# ── (2) ON + live builder → bounce once with merge prompt; row "rebasing · awaiting push" ─────
reset_state
export STALE_BASE_AUTOFIX=on
printf '0\n' > "$STUB_WAIT_FILE"
_handle_stale_dup 20 slug-a shaC 0 "$WT" feat/a stale-base "$REASON"
[ "$(runs)" = "1" ] || fail "(2) autofix on must pane-run exactly once (got $(runs))"
grep -q '^pane-a' "$STUB_PANE_RUN_LOG" || fail "(2) bounce must target the AGENT pane"
grep -q 'git merge origin/main' "$STUB_PANE_RUN_LOG" || fail "(2) prompt must ask for git merge origin/main"
grep -q 'STALE BASE' "$STUB_PANE_RUN_LOG" || fail "(2) prompt must name STALE BASE"
refix_attempted 20 shaC stale || fail "(2) bounce must be recorded kind=stale"
[ "$(refix_round_count 20)" = "1" ] || fail "(2) must consume exactly one refix round"
row | grep -q 'rebasing · awaiting push' || fail "(2) row must read 'rebasing · awaiting push' (got: $(row))"
row | grep -q 'needs you' && fail "(2) 'needs you' is BANNED after a successful bounce (got: $(row))"
grep -q '"event":"stale_refix_bounce"' "$JOURNAL_FILE" || fail "(2) bounce must be journaled"
ok "(2) live builder bounces with merge prompt + awaiting-push row"

# ── (3) once-guard: same sha re-enters → no second bounce ─────────────────────────────────────
_handle_stale_dup 20 slug-a shaC 0 "$WT" feat/a stale-base "$REASON"
[ "$(runs)" = "1" ] || fail "(3) second call for same sha must not re-bounce (got $(runs))"
row | grep -q 'rebasing · awaiting push' || fail "(3) once-guard row must still say rebasing · awaiting push"
ok "(3) sha-keyed once-guard holds"

# New sha is eligible.
printf '0\n' > "$STUB_WAIT_FILE"
_handle_stale_dup 20 slug-a shaD 0 "$WT" feat/a stale-base "$REASON"
[ "$(runs)" = "2" ] || fail "(3b) a new sha must be eligible for a fresh bounce (got $(runs))"
ok "(3b) new sha is eligible"

# ── (4) shared budget with review refix; cap escalates ────────────────────────────────────────
reset_state
export STALE_BASE_AUTOFIX=on REFIX_MAX_ROUNDS=3
record_refix 30 shaR1 slug-a review
record_refix 30 shaR2 slug-a review
[ "$(refix_round_count 30)" = "2" ] || fail "(4) budget must count review bounces"
printf '0\n' > "$STUB_WAIT_FILE"
_handle_stale_dup 30 slug-a shaS1 0 "$WT" feat/a stale-base "$REASON"
[ "$(runs)" = "1" ] || fail "(4) third shared round should still bounce (got $(runs))"
[ "$(refix_round_count 30)" = "3" ] || fail "(4) review + stale must share ONE per-PR budget"
_handle_stale_dup 30 slug-a shaS2 0 "$WT" feat/a stale-base "$REASON"
[ "$(runs)" = "1" ] || fail "(4b) bounce past the cap must not be delivered (got $(runs))"
row | grep -q 'needs you · refix limit (3 rounds) reached' \
  || fail "(4b) cap row must read 'needs you · refix limit' (got: $(row))"
grep -q '"event":"stale_refix_escalated"' "$JOURNAL_FILE" || fail "(4b) cap must journal an escalation"
ok "(4) shared budget + cap escalation"

# ── (5) no live builder (foreign/reaped) → conflict resolver, not needs-you ───────────────────
reset_state
export STALE_BASE_AUTOFIX=on
export STUB_AGENT_EMPTY=1
STUB_LIVENESS=missing
_handle_stale_dup 40 slug-a shaE 0 "$WT" feat/a stale-base "$REASON"
[ "$(runs)" = "0" ] || fail "(5) no-builder path must never pane-run"
[ "$(rslv)" = "1" ] || fail "(5) no-builder path must dispatch the resolver exactly once (got $(rslv))"
grep -q '^slug-a 40 feat/a shaE$' "$RESOLVE_LOG" || fail "(5) resolver args must be slug/pr/branch/sha (got: $(cat "$RESOLVE_LOG"))"
refix_attempted 40 shaE stale || fail "(5) resolver dispatch must burn the stale once-guard"
row | grep -q 'rebasing · awaiting push' || fail "(5) resolver path must read 'rebasing · awaiting push' (got: $(row))"
row | grep -q 'needs you' && fail "(5) 'needs you' is BANNED when the resolver was dispatched (got: $(row))"
grep -q '"event":"stale_refix_resolver"' "$JOURNAL_FILE" || fail "(5) resolver dispatch must be journaled"
# Re-entry must not double-dispatch.
_handle_stale_dup 40 slug-a shaE 0 "$WT" feat/a stale-base "$REASON"
[ "$(rslv)" = "1" ] || fail "(5b) once-guard must prevent a second resolver dispatch (got $(rslv))"
ok "(5) foreign/reaped PR dispatches the conflict resolver"

# Dead agent with a pane still reported — liveness=dead is "no live builder".
reset_state
export STALE_BASE_AUTOFIX=on
STUB_LIVENESS=dead
_handle_stale_dup 41 slug-a shaF 0 "$WT" feat/a stale-base "$REASON"
[ "$(rslv)" = "1" ] || fail "(5c) dead agent must dispatch the resolver (got $(rslv))"
[ "$(runs)" = "0" ] || fail "(5c) dead agent must never be typed at"
ok "(5c) dead agent routes to resolver"

# No worktree and no builder → escalate (nothing to heal).
reset_state
export STALE_BASE_AUTOFIX=on
export STUB_AGENT_EMPTY=1
STUB_LIVENESS=missing
_handle_stale_dup 42 slug-a shaG 0 "$T/no-such-wt" feat/a stale-base "$REASON"
[ "$(rslv)" = "0" ] || fail "(5d) missing worktree must not spawn a resolver"
row | grep -q 'needs you' || fail "(5d) missing worktree must escalate to needs-you (got: $(row))"
ok "(5d) no builder + no worktree escalates"

# ── (6) DUPLICATE always human, even with autofix ON ──────────────────────────────────────────
reset_state
export STALE_BASE_AUTOFIX=on
printf '0\n' > "$STUB_WAIT_FILE"
_handle_stale_dup 50 slug-a shaH 0 "$WT" feat/a duplicate \
  "tracked item HERD-49 already shipped by merged PR #185 — this PR re-implements Done work"
[ "$(runs)" = "0" ] || fail "(6) duplicate must never bounce"
[ "$(rslv)" = "0" ] || fail "(6) duplicate must never spawn a resolver"
[ "$(refix_round_count 50)" = "0" ] || fail "(6) duplicate must not consume a refix round"
row | grep -q 'needs you' || fail "(6) duplicate must read 'needs you' (got: $(row))"
row | grep -q 'stale/duplicate (duplicate)' || fail "(6) row must name the duplicate flavor (got: $(row))"
ok "(6) DUPLICATE flavor stays human"

# ── (7) dry-run never bounces ─────────────────────────────────────────────────────────────────
reset_state
export STALE_BASE_AUTOFIX=on
DRYRUN=1 _handle_stale_dup 60 slug-a shaI 0 "$WT" feat/a stale-base "$REASON"
[ "$(runs)" = "0" ] || fail "(7) dry-run must never bounce"
[ "$(rslv)" = "0" ] || fail "(7) dry-run must never spawn a resolver"
[ "$(refix_round_count 60)" = "0" ] || fail "(7) dry-run must not consume a round"
row | grep -q 'needs you' || fail "(7) dry-run must fall through to needs-you (got: $(row))"
ok "(7) dry-run is inert"

# ── (8) kind isolation: stale bounce does not satisfy the review once-guard ───────────────────
reset_state
export STALE_BASE_AUTOFIX=on
printf '0\n' > "$STUB_WAIT_FILE"
_handle_stale_dup 70 slug-a shaJ 0 "$WT" feat/a stale-base "$REASON"
refix_attempted 70 shaJ stale || fail "(8) kind=stale must match"
refix_attempted 70 shaJ review && fail "(8) a stale bounce must NOT satisfy the review once-guard"
ok "(8) kind isolation (stale vs review)"

# ── (9) enabled predicate ─────────────────────────────────────────────────────────────────────
( unset STALE_BASE_AUTOFIX; _stale_base_autofix_enabled ) && fail "(9) default (unset) must be OFF"
( STALE_BASE_AUTOFIX=off  _stale_base_autofix_enabled ) && fail "(9) off must be OFF"
( STALE_BASE_AUTOFIX=on   _stale_base_autofix_enabled ) || fail "(9) on must be ON"
( STALE_BASE_AUTOFIX=true _stale_base_autofix_enabled ) || fail "(9) true must be ON"
ok "(9) _stale_base_autofix_enabled lever"

echo
# ── (10) failed wake → durable needs-you, never a 'rebasing' lie (review round-5 fix) ─────────
reset_state
export STALE_BASE_AUTOFIX=on STUB_AGENT_STATUS=idle
printf '1\n1\n' > "$STUB_WAIT_FILE"   # both wake checks fail: the builder never wakes
_handle_stale_dup 80 slug-a shaK 0 "$WT" feat/a stale-base "$REASON"
row | grep -q 'needs you' || fail "(10) tick1: failed wake must read needs-you (got: $(row))"
_handle_stale_dup 80 slug-a shaK 0 "$WT" feat/a stale-base "$REASON"
row | grep -q 'needs you' || fail "(10) tick2: once-guard must NOT flip to rebasing (got: $(row))"
row | grep -q 'stalled' || fail "(10) tick2 must carry the stalled reason (got: $(row))"
ok "(10) failed wake escalates durably (no rebasing lie)"

# ── (11) agent dies AFTER a good wake → stalled row, never a permanent 'rebasing' lie (round-6) ──
reset_state
export STALE_BASE_AUTOFIX=on STUB_AGENT_STATUS=idle STUB_LIVENESS=alive
printf '0\n' > "$STUB_WAIT_FILE"                       # wake SUCCEEDS: record written, no stuck marker
_handle_stale_dup 90 slug-a shaL 0 "$WT" feat/a stale-base "$REASON"
row | grep -q 'rebasing' || fail "(11) tick1: good wake reads rebasing (got: $(row))"
export STUB_LIVENESS=dead                              # builder session dies before pushing
_handle_stale_dup 90 slug-a shaL 0 "$WT" feat/a stale-base "$REASON"
row | grep -q 'needs you' || fail "(11) tick2: dead-after-wake must escalate, not claim rebasing (got: $(row))"
_handle_stale_dup 90 slug-a shaL 0 "$WT" feat/a stale-base "$REASON"
row | grep -q 'needs you' || fail "(11) tick3: escalation is durable (got: $(row))"
ok "(11) died-after-wake escalates durably (round-6 triple disproof)"

# ── (12) live RESOLVER keeps an honest in-progress row ────────────────────────────────────────
reset_state
export STALE_BASE_AUTOFIX=on STUB_LIVENESS=missing STUB_RESOLVER_ALIVE=1
printf '0\n' > "$STUB_WAIT_FILE"
record_refix 95 shaM slug-a stale                       # heal already dispatched (resolver path)
_handle_stale_dup 95 slug-a shaM 0 "$WT" feat/a stale-base "$REASON"
row | grep -q 'resolver working' || fail "(12) live resolver must read as working (got: $(row))"
export STUB_RESOLVER_ALIVE=0
_handle_stale_dup 95 slug-a shaM 0 "$WT" feat/a stale-base "$REASON"
row | grep -q 'needs you' || fail "(12) dead resolver must escalate (got: $(row))"
ok "(12) resolver liveness consulted before claiming progress"

# ── (13) WORKING builder → heal deferred, never a resolver into the live worktree (round-7) ────
reset_state
export STALE_BASE_AUTOFIX=on STUB_AGENT_STATUS=working STUB_LIVENESS=alive STUB_RESOLVER_ALIVE=0
_handle_stale_dup 100 slug-a shaN 0 "$WT" feat/a stale-base "$REASON"
[ "$(runs)" = "0" ] || fail "(13) working builder must not be bounced"
[ "$(rslv)" = "0" ] || fail "(13) working builder must NEVER get a resolver in its worktree"
refix_attempted 100 shaN stale && fail "(13) once-guard must NOT be burned on defer"
row | grep -q 'builder busy' || fail "(13) row must read deferred (got: $(row))"
ok "(13) working builder defers the heal (no two-agents-one-worktree)"

# ── (14) resolver already in flight → no second dispatch ──────────────────────────────────────
reset_state
export STALE_BASE_AUTOFIX=on STUB_AGENT_STATUS=idle STUB_LIVENESS=missing STUB_RESOLVER_ALIVE=1
export STUB_AGENT_EMPTY=1
_handle_stale_dup 110 slug-a shaP 0 "$WT" feat/a stale-base "$REASON"
[ "$(rslv)" = "0" ] || fail "(14) in-flight resolver must not be doubled (got $(rslv) spawns)"
unset STUB_AGENT_EMPTY
ok "(14) resolver single-flight respected"

# ── (15) TOCTOU: builder flips idle→working mid-tick → defer, never a resolver (round-9) ──────
reset_state
export STALE_BASE_AUTOFIX=on STUB_LIVENESS=alive STUB_RESOLVER_ALIVE=0
STATUS_SEQ="$T/status-seq.txt"; printf 'idle\nworking\nworking\n' > "$STATUS_SEQ"   # guard sees idle; dispatch re-assert sees working
_agent_status_real_15=$(declare -f _agent_status)
_agent_status() {  # pop one status per call: guard sees idle, dispatch-site re-assert sees working
  local _c; _c="$(head -1 "$STATUS_SEQ" 2>/dev/null)"; { tail -n +2 "$STATUS_SEQ" 2>/dev/null; } > "$STATUS_SEQ.t"; mv "$STATUS_SEQ.t" "$STATUS_SEQ"
  printf '%s' "${_c:-working}"
}
export STUB_AGENT_STATUS=working   # herdr-level: pane lookup excludes working → empty pane id
_handle_stale_dup 120 slug-a shaQ 0 "$WT" feat/a stale-base "$REASON"
[ "$(rslv)" = "0" ] || fail "(15) mid-tick flip must NEVER dispatch a resolver into the live worktree"
row | grep -q 'builder busy' || fail "(15) row must read deferred (got: $(row))"
eval "$_agent_status_real_15"
ok "(15) TOCTOU flip defers — no resolver into a live worktree"

echo "ALL PASS ($pass checks) — STALE_BASE_AUTOFIX (HERD-199)"
