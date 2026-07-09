#!/usr/bin/env bash
# test-resolver-limit-park.sh — hermetic regression for the LIMIT-PARK guard on resolver idle-reap
# (HERD-246).
#
# THE BUG (shipped on main by HERD-225 / PR #343): _resolver_in_flight frees the dispatch slot when an
# ALIVE resolver reports agent_status idle|done past the startup grace, and spawn_resolver then calls
# _reap_idle_resolver_for_redispatch, which closes the tab and kills the pid. But a Claude session
# PARKED on the account usage limit reports exactly idle/done — and a park legitimately outlasts any
# grace. So a parked resolver awaiting auto-resume got reaped: session destroyed, limit-park
# auto-resume (the engine's core capability) defeated.
#
# THE FIX under test: before treating idle-past-grace as reapable, _resolver_in_flight consults the
# SAME park state the builder refix paths read — the .herd-limit-sentinel written by the rate_limit
# hook (via _detect_limit_hit) and the park handler's ledger (limit_state = scheduled):
#   • parked, no terminal verdict  ⇒ HOLD the slot (pre-HERD-225 behavior; the resume scheduler owns it)
#   • no park state                ⇒ free + reap (HERD-225 unchanged — byte-identical)
#   • verdict file written         ⇒ free + reap (the resolver's own last act; its round is over)
#   • park-state read error        ⇒ HOLD (fail-soft to the conservative side)
#
# Cases:
#   (1)  helpers exist after sourcing
#   (2)  RED: idle + alive + park sentinel, past grace ⇒ HELD (no slot, no reap)
#   (3)  RED: done + alive + park sentinel             ⇒ HELD
#   (4)  sentinel cleared (park resolved)              ⇒ FREED, and spawn_resolver reaps the tab
#   (5)  park ledger `scheduled`, no sentinel          ⇒ HELD (the handler's ledger is park state too)
#   (6)  ledger row for a DIFFERENT slug              ⇒ FREED (the guard is slug-scoped)
#   (7)  verdict file written + sentinel present       ⇒ FREED (a finished round beats a stale park)
#   (8)  fail-soft: unreadable/garbled sentinel        ⇒ HELD
#   (9)  no park state at all                          ⇒ FREED (HERD-225 regression guard)
#   (10) working + sentinel                            ⇒ HELD (unchanged; the merge/push race guard)
#   (11) HERD_LIMIT_DETECT=off + no ledger row         ⇒ FREED (the documented kill-switch)
#   (12) end-to-end: _classify_conflict on a parked resolver queues NO re-dispatch and shows a busy row
#
# Liveness is driven through HERD_DRIVER=headless + a stub roster; no real herdr tabs, no network.
#
# Run:  bash tests/test-resolver-limit-park.sh
# No `set -e`: several checks deliberately assert a non-zero predicate return.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"
_fake_agent_pid=""
cleanup() {
  [ -n "$_fake_agent_pid" ] && kill "$_fake_agent_pid" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH (NETWORK-FREE, no real tabs) ────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
export GH_PRLIST="$T/prlist.json"; printf '[]\n' > "$GH_PRLIST"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then cat "$GH_PRLIST" 2>/dev/null; fi
exit 0
STUB
export CLOSED="$T/closed.log"; : > "$CLOSED"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "tab close")      printf '%s\n' "${3:-}" >> "$CLOSED" ;;
  "workspace list") printf '{"result":{"workspaces":[]}}\n' ;;
  "tab list")       printf '{"result":{"tabs":[]}}\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/gh" "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode, headless driver ────────────────────────
export AGENT_WATCH_LIB=1
export HERD_DRIVER=headless
export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export REFIX_MAX_ROUNDS=3
export DRYRUN=""
# Hermetic transcript root: _detect_limit_hit's banner-scrape fallback must never read the real
# ~/.claude/projects of whoever runs this suite.
export HERD_TRANSCRIPT_ROOT="$T/transcripts"; mkdir -p "$HERD_TRANSCRIPT_ROOT"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }
TREES="$WORKTREES_DIR"
RESOLVE_STATE="$T/.agent-watch-resolve-attempts"
LIMIT_STATE="$T/.agent-watch-limits"; : > "$LIMIT_STATE"
REG="$WORKTREES_DIR/.herd-tabs"

SLUG="fixit"; PR="328"; BRANCH="feat/fixit"
SHA1="aaaaaaa1"; SHA2="bbbbbbb2"
GRACE_DEFAULT=90
WT="$WORKTREES_DIR/$SLUG"; mkdir -p "$WT"
SENTINEL="$WT/.herd-limit-sentinel"

# ── fixtures ──────────────────────────────────────────────────────────────────
roster_status() {
  printf '{"result":{"agents":[{"name":"resolve·%s","agent_status":"%s","pane_id":"pane-r1"}]}}' \
    "$SLUG" "$1"
}
roster_empty() { printf '{"result":{"agents":[]}}'; }

_agent_pid_dir="$WORKTREES_DIR/.herd/agents/resolve·$SLUG"
# Disposable live pid (NEVER $$): _reap_idle_resolver_for_redispatch kill(1)s the recorded pid, and
# using the test's own pid would SIGTERM the suite (exit 143).
probe_alive() {
  mkdir -p "$_agent_pid_dir"
  [ -n "$_fake_agent_pid" ] && kill "$_fake_agent_pid" 2>/dev/null || true
  sleep 3600 &
  _fake_agent_pid=$!
  printf '%s\n' "$_fake_agent_pid" > "$_agent_pid_dir/pid"
  printf 'idle\n' > "$_agent_pid_dir/status"
}
probe_blind() {
  [ -n "$_fake_agent_pid" ] && kill "$_fake_agent_pid" 2>/dev/null || true
  _fake_agent_pid=""
  rm -rf "$WORKTREES_DIR/.herd/agents"
}

dispatched_at() {
  : > "$RESOLVE_STATE"
  printf '%s %s %s %s %s dispatched\n' "$(( $(date +%s) - $1 ))" "$PR" "$SLUG" "$BRANCH" "$SHA1" >> "$RESOLVE_STATE"
}
# park <reset-epoch-text> — what the rate_limit StopFailure hook writes into the worktree.
park()   { printf '%s\n' "$1" > "$SENTINEL"; }
unpark() { rm -f "$SENTINEL"; }

reset() {
  : > "$JOURNAL_FILE"; : > "$CLOSED"; : > "$REG"; : > "$RESOLVE_STATE"; : > "$LIMIT_STATE"
  rm -f "$TREES"/.resolve-result-*
  unpark
  probe_blind
  unset HERD_LIMIT_DETECT
  _RESOLVER_DEAD_GRACE="$GRACE_DEFAULT"
  AGENTS_JSON="$(roster_empty)"
}

# idle_alive_past_grace — the exact shape a parked resolver presents to the watcher.
idle_alive_past_grace() {
  dispatched_at $(( GRACE_DEFAULT + 60 ))
  AGENTS_JSON="$(roster_status "${1:-idle}")"
  probe_alive
}

classify() {
  DISPLAY=(); FLAIR_STATE=()
  CONF_IDX=(); CONF_SLUG=(); CONF_PR=(); CONF_BRANCH=(); CONF_SHA=(); CONF_REASON=()
  _classify_conflict 0 "$PR" "$SLUG" "$BRANCH" "$1"
  CLASSIFY_N="${#CONF_IDX[@]}"
}

# ── (1) helpers exist ─────────────────────────────────────────────────────────
for fn in _resolver_in_flight _resolver_limit_parked _resolve_verdict_recorded \
          _detect_limit_hit _limit_sentinel_file limit_state _reap_idle_resolver_for_redispatch; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing (HERD-246 limit-park guard seam)"
done
# The guard must read the SAME sentinel path the hook writes — not a private one.
[ "$(_limit_sentinel_file "$WT")" = "$SENTINEL" ] || fail "(1) sentinel path drifted from the hook's"
ok

# ── (2) idle + alive + park sentinel, past grace ⇒ HELD ───────────────────────
# Headline regression: the parked session looks idle, but auto-resume owns it. Hands off.
reset
idle_alive_past_grace idle
park "$(( $(date +%s) + 3600 ))"
[ "$(_resolver_liveness_verdict "$SLUG" "$PR")" = "ALIVE" ] || fail "(2) parked resolver must read ALIVE"
_resolver_limit_parked "$SLUG" || fail "(2) the sentinel must be seen as park state"
_resolver_in_flight "$SLUG" "$PR" || fail "(2) a LIMIT-PARKED idle resolver must HOLD the dispatch slot"
# …and the pane survives: nothing reaped it.
[ -d "$_agent_pid_dir" ] || fail "(2) the parked resolver's agent dir must be untouched"
kill -0 "$_fake_agent_pid" 2>/dev/null || fail "(2) the parked resolver's session must still be alive"
ok

# ── (3) done + alive + park sentinel ⇒ HELD ──────────────────────────────────
reset
idle_alive_past_grace done
park "resets 7:30pm"
_resolver_in_flight "$SLUG" "$PR" || fail "(3) a LIMIT-PARKED done resolver must HOLD the dispatch slot"
ok

# ── (4) sentinel cleared (park resolved) ⇒ FREED, and the spawn path reaps ────
reset
idle_alive_past_grace idle
park "$(( $(date +%s) + 3600 ))"
_resolver_in_flight "$SLUG" "$PR" || fail "(4) precondition: parked must hold"
unpark                                   # auto-resume ran; clear_limit removed the sentinel
_resolver_in_flight "$SLUG" "$PR" && fail "(4) an unparked idle resolver must FREE the dispatch slot"
printf 'resolve·%s tab-idle resolve\n' "$SLUG" > "$REG"
STUB_RESOLVE="$T/stub-resolve.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_RESOLVE"; chmod +x "$STUB_RESOLVE"
HERD_RESOLVE_BIN="$STUB_RESOLVE" spawn_resolver "$SLUG" "$PR" "$BRANCH" "$SHA2"
grep -qxF "tab-idle" "$CLOSED" || fail "(4) an unparked idle resolver must be reaped for re-dispatch"
ok

# ── (5) park ledger `scheduled`, no sentinel ⇒ HELD ──────────────────────────
# The handler consumed the sentinel and scheduled the resume; the ledger is now the park state.
reset
idle_alive_past_grace idle
record_limit "$SLUG" "$(date +%s)" "$(( $(date +%s) + 3600 ))" scheduled
[ "$(limit_state "$SLUG")" = "scheduled" ] || fail "(5) precondition: ledger row must read scheduled"
_resolver_in_flight "$SLUG" "$PR" || fail "(5) a scheduled-resume ledger row must HOLD the dispatch slot"
ok

# ── (6) ledger row for a DIFFERENT slug ⇒ FREED ──────────────────────────────
reset
idle_alive_past_grace idle
record_limit "some-other-builder" "$(date +%s)" "$(( $(date +%s) + 3600 ))" scheduled
_resolver_in_flight "$SLUG" "$PR" && fail "(6) another slug's park must not hold THIS resolver"
ok

# ── (7) verdict file written + sentinel present ⇒ FREED ──────────────────────
# The resolver's LAST act is the verdict line. Having written it, its round is over — a sentinel
# lingering in the shared worktree (e.g. the builder's, never cleared) must not strand the slot.
reset
idle_alive_past_grace idle
park "$(( $(date +%s) + 3600 ))"
printf 'RESOLVE: DONE\n' > "$(_resolve_result_file "$PR" "$SHA1")"
_resolve_verdict_recorded "$PR" || fail "(7) a written verdict must be detected for the PR"
_resolver_in_flight "$SLUG" "$PR" && fail "(7) a written verdict must FREE the slot even under a sentinel"
ok

# ── (8) fail-soft: unreadable / garbled sentinel ⇒ HELD ──────────────────────
# A sentinel we cannot parse still says "a limit was hit". Holding is recoverable; reaping is not.
reset
idle_alive_past_grace idle
printf '\x00\xff not-an-epoch \x00\n' > "$SENTINEL"
_resolver_in_flight "$SLUG" "$PR" || fail "(8) an unparseable sentinel must fail soft to HOLD"
reset
idle_alive_past_grace idle
: > "$SENTINEL"                         # empty sentinel still counts as "limit hit"
_resolver_in_flight "$SLUG" "$PR" || fail "(8) an EMPTY sentinel must fail soft to HOLD"
ok

# ── (9) no park state at all ⇒ FREED (HERD-225 preserved, byte-identical) ────
reset
idle_alive_past_grace idle
_resolver_limit_parked "$SLUG" && fail "(9) an unparked worktree must not read as parked"
_resolver_in_flight "$SLUG" "$PR" && fail "(9) idle-but-alive with NO park state must FREE the slot"
reset
idle_alive_past_grace done
_resolver_in_flight "$SLUG" "$PR" && fail "(9) done-but-alive with NO park state must FREE the slot"
ok

# ── (10) working + sentinel ⇒ HELD (unchanged) ───────────────────────────────
reset
idle_alive_past_grace working
park "$(( $(date +%s) + 3600 ))"
_resolver_in_flight "$SLUG" "$PR" || fail "(10) a working resolver must HOLD (merge/push race guard)"
ok

# ── (11) HERD_LIMIT_DETECT=off ⇒ FREED (documented kill-switch) ──────────────
reset
idle_alive_past_grace idle
park "$(( $(date +%s) + 3600 ))"
HERD_LIMIT_DETECT=off _resolver_in_flight "$SLUG" "$PR" \
  && fail "(11) the detection kill-switch must restore the pre-HERD-246 free+reap path"
ok

# ── (12) end-to-end: a parked resolver queues NO re-dispatch ─────────────────
# Same sha as the dispatch, no verdict → the classifier's in-flight guard must hold the row busy.
reset
idle_alive_past_grace idle
park "$(( $(date +%s) + 3600 ))"
classify "$SHA1"
[ "$CLASSIFY_N" = "0" ] || fail "(12) a parked resolver queued $CLASSIFY_N re-dispatch(es) — park would be reaped"
case "${DISPLAY[0]}" in *"resolving conflict"*) : ;; *) fail "(12) parked hold row must read 'resolving conflict…', got: ${DISPLAY[0]}" ;; esac
[ "${FLAIR_STATE[0]}" = "busy" ] || fail "(12) a parked resolver must not flag the fleet red"
ok

echo "ALL PASS ($pass checks) — a usage-limit-parked resolver survives idle-reap (HERD-246)"
