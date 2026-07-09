#!/usr/bin/env bash
# test-resolver-idle-redispatch.sh — hermetic regression for IDLE-BUT-ALIVE resolver re-dispatch
# (HERD-225).
#
# THE BUG (grounded 2026-07-09, twice on PR #328): _resolver_in_flight treated every non-DEAD
# liveness verdict as "hold re-dispatch". A resolver that FINISHED its round (pushed or escalated)
# goes idle yet stays ALIVE, so when a NEW conflict arrived the watcher could neither spawn a fresh
# resolver (guard held) nor rely on the idle one (it is not working). Re-spawning by hand also
# failed with "agent name already used" because the idle agent still held the name.
#
# THE FIX under test:
#   • _resolver_in_flight frees the slot when liveness is ALIVE AND agent_status is idle|done
#     (past the startup grace) — ACTIVELY-RESOLVING (working) still holds; STARTING/UNKNOWN still
#     hold (HERD-206).
#   • spawn_resolver reaps an idle/done resolve·<slug> tab before launching so the agent name is
#     free for the fresh dispatch.
#
# Cases:
#   (1) helpers exist after sourcing
#   (2) RED: idle-but-alive past grace  ⇒ NOT in-flight (slot free for re-dispatch)
#   (3) RED: done-but-alive past grace  ⇒ NOT in-flight
#   (4) working-but-alive past grace    ⇒ still in-flight (protect the merge/push race)
#   (5) idle INSIDE the startup grace   ⇒ still in-flight (fresh agent may blip idle)
#   (6) STARTING / UNKNOWN still hold   (HERD-206 invariants preserved)
#   (7) _classify_conflict: NEW sha + idle prior resolver queues new-commit re-dispatch
#   (8) _classify_conflict: NEW sha + working prior resolver HOLDS (no re-dispatch)
#   (9) spawn_resolver reaps the idle resolve tab before launching (name reclaim)
#
# Liveness is driven through HERD_DRIVER=headless + a stub roster; no real herdr tabs.
#
# Run:  bash tests/test-resolver-idle-redispatch.sh
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
export GH_RC="$T/gh.rc"; printf '0\n' > "$GH_RC"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
_rc="$(cat "$GH_RC" 2>/dev/null || echo 0)"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  [ "$_rc" = "0" ] || exit "$_rc"
  cat "$GH_PRLIST" 2>/dev/null
fi
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
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }
TREES="$WORKTREES_DIR"
RESOLVE_STATE="$T/.agent-watch-resolve-attempts"
REG="$WORKTREES_DIR/.herd-tabs"

SLUG="fixit"; PR="328"; BRANCH="feat/fixit"
SHA1="aaaaaaa1"; SHA2="bbbbbbb2"
GRACE_DEFAULT=90

# ── fixtures ──────────────────────────────────────────────────────────────────
# roster_status STATUS — roster listing resolve·$SLUG under `name` with the given agent_status.
roster_status() {
  printf '{"result":{"agents":[{"name":"resolve·%s","agent_status":"%s","pane_id":"pane-r1"}]}}' \
    "$SLUG" "$1"
}
roster_empty()      { printf '{"result":{"agents":[]}}'; }
roster_unreadable() { printf '{}'; }

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
reset() {
  : > "$JOURNAL_FILE"; : > "$CLOSED"; : > "$REG"; : > "$RESOLVE_STATE"
  printf '[]\n' > "$GH_PRLIST"; printf '0\n' > "$GH_RC"
  probe_blind
  _RESOLVER_DEAD_GRACE="$GRACE_DEFAULT"
  AGENTS_JSON="$(roster_empty)"
}
verdict() { _resolver_liveness_verdict "$SLUG" "${1-$PR}"; }

classify() {
  DISPLAY=(); FLAIR_STATE=()
  CONF_IDX=(); CONF_SLUG=(); CONF_PR=(); CONF_BRANCH=(); CONF_SHA=(); CONF_REASON=()
  _classify_conflict 0 "$PR" "$SLUG" "$BRANCH" "$1"
  CLASSIFY_N="${#CONF_IDX[@]}"
  CLASSIFY_REASON="${CONF_REASON[0]:--}"
}

# ── (1) helpers exist ─────────────────────────────────────────────────────────
for fn in _resolver_in_flight _resolver_agent_status _reap_idle_resolver_for_redispatch \
          _resolver_liveness_verdict _classify_conflict spawn_resolver; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing (HERD-225 idle-redispatch seam)"
done
ok

# ── (2) idle-but-alive past grace ⇒ NOT in-flight ─────────────────────────────
# Headline regression: finished resolver stays alive as idle; NEW conflict must re-dispatch.
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
AGENTS_JSON="$(roster_status idle)"
probe_alive
[ "$(verdict)" = "ALIVE" ] || fail "(2) idle resolver must read ALIVE, got '$(verdict)'"
[ "$(_resolver_agent_status "$SLUG")" = "idle" ] || fail "(2) agent_status must read idle"
_resolver_in_flight "$SLUG" "$PR" && fail "(2) idle-but-alive past grace must FREE the dispatch slot"
ok

# ── (3) done-but-alive past grace ⇒ NOT in-flight ─────────────────────────────
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
AGENTS_JSON="$(roster_status done)"
_resolver_in_flight "$SLUG" "$PR" && fail "(3) done-but-alive past grace must FREE the dispatch slot"
ok

# ── (4) working-but-alive past grace ⇒ still in-flight ────────────────────────
# ACTIVELY-RESOLVING must still hold — protect the git merge/push race.
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
AGENTS_JSON="$(roster_status working)"
_resolver_in_flight "$SLUG" "$PR" || fail "(4) a working resolver must HOLD re-dispatch"
ok

# ── (5) idle INSIDE the startup grace ⇒ still in-flight ───────────────────────
# A fresh agent can blip idle before picking up its task; never double-dispatch inside grace.
reset
dispatched_at 5
AGENTS_JSON="$(roster_status idle)"
_resolver_in_flight "$SLUG" "$PR" || fail "(5) idle inside startup grace must still HOLD"
ok

# ── (6) STARTING / UNKNOWN still hold (HERD-206 preserved) ────────────────────
reset
dispatched_at 5
# No roster, blind probe, inside grace → STARTING
[ "$(verdict)" = "STARTING" ] || fail "(6a) fresh spawn inside grace must read STARTING, got '$(verdict)'"
_resolver_in_flight "$SLUG" "$PR" || fail "(6a) STARTING must HOLD"
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
AGENTS_JSON="$(roster_unreadable)"
[ "$(verdict)" = "UNKNOWN" ] || fail "(6b) unreadable roster must read UNKNOWN, got '$(verdict)'"
_resolver_in_flight "$SLUG" "$PR" || fail "(6b) UNKNOWN must HOLD"
ok

# ── (7) _classify_conflict: NEW sha + idle prior ⇒ queues new-commit ──────────
# Prior dispatch was for SHA1; agent finished and is idle; SHA2 is a reshaped conflict.
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
AGENTS_JSON="$(roster_status idle)"
# Prior round wrote DONE for the old sha (finished its work).
printf 'RESOLVE: DONE\n' > "$(_resolve_result_file "$PR" "$SHA1")"
classify "$SHA2"
[ "$CLASSIFY_N $CLASSIFY_REASON" = "1 new-commit" ] \
  || fail "(7) idle prior + NEW sha must queue new-commit re-dispatch, got '$CLASSIFY_N $CLASSIFY_REASON'"
ok

# ── (8) _classify_conflict: NEW sha + working prior ⇒ HOLDS ───────────────────
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
AGENTS_JSON="$(roster_status working)"
classify "$SHA2"
[ "$CLASSIFY_N" = "0" ] || fail "(8) working prior + NEW sha queued $CLASSIFY_N respawn(s) — race risk"
case "${DISPLAY[0]}" in *"resolving conflict"*) : ;; *) fail "(8) working hold row must read 'resolving conflict…', got: ${DISPLAY[0]}" ;; esac
ok

# ── (9) spawn_resolver reaps the idle resolve tab before launching ────────────
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
AGENTS_JSON="$(roster_status idle)"
printf 'resolve·%s tab-idle resolve\n' "$SLUG" > "$REG"
probe_alive
STUB="$T/stub-resolve.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB"; chmod +x "$STUB"
HERD_RESOLVE_BIN="$STUB" spawn_resolver "$SLUG" "$PR" "$BRANCH" "$SHA2"
_spawn_resolver_wait   # HERD-237: the resolver lane is dispatched in the background
# The idle tab must have been closed (name reclaim) and the registry row pruned.
grep -qxF "tab-idle" "$CLOSED" || fail "(9) spawn_resolver must close the idle resolve tab (got: $(cat "$CLOSED"))"
grep -q 'tab-idle' "$REG" && fail "(9) the reaped tab's registry row must be pruned"
grep -q '"event":"reap_resolve_tab"' "$JOURNAL_FILE" || fail "(9) reap must be journaled"
grep -q '"reason":"idle-redispatch"' "$JOURNAL_FILE" || fail "(9) reap reason must be idle-redispatch"
# Headless agent dir freed so the next launch owns a clean slot.
[ ! -d "$_agent_pid_dir" ] || fail "(9) headless agent registry dir must be cleared after idle reap"
ok

echo "ALL PASS ($pass checks) — resolver idle re-dispatch frees the slot for NEW conflicts (HERD-225)"
