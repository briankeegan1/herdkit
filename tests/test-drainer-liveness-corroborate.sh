#!/usr/bin/env bash
# test-drainer-liveness-corroborate.sh — hermetic proof of the HERD-122 drainer-liveness FALSE-POSITIVE
# fix: a fresh, seconds-old drainer must NEVER be declared HUNG before it writes its first heartbeat.
#
# The 2026-07-08 incident: three scribe.sh enqueues seconds apart — call 1 spawned a fresh drainer;
# calls 2 & 3 found a LEFTOVER heartbeat (ancient mtime, from a PRIOR drainer's lifetime), declared the
# healthy seconds-old drainer HUNG, tried to reclaim, and failed the respawn with `agent_name_taken`
# (the live drainer still held the name). The drainer was status=working throughout and the queue
# drained fine — a pure false-red. This suite locks in, WITHOUT any model/network (a stale heartbeat is
# stubbed on disk; a file-backed herdr stub supplies agent-list status + pane process-info):
#   (1) herd_drainer_live_status — working/idle status ⇒ alive; a headless dead pid ⇒ dead; no data ⇒ unknown.
#   (2) herd_drainer_should_reclaim matrix — the THREE required fixtures:
#         • fresh/absent heartbeat (inside grace)      → KEEP  (no reclaim)
#         • stale heartbeat + LIVE (working) agent      → KEEP  (reclaim refused — the false positive)
#         • stale heartbeat + DEAD process              → RECLAIM (genuine hang — real detection intact)
#       plus edges (disabled timeout, unknown liveness).
#   (3) SPAWN-TIME STAMP — scribe.sh / research.sh stamp the heartbeat at spawn so a leftover ancient
#       heartbeat can never make the next enqueue see a fresh drainer as "hung since epoch".
#   (4) END-TO-END via the REAL scribe.sh against a herdr stub:
#         (a) listed + WORKING + ancient heartbeat → "already running", NO spawn, journals reclaim_refused.
#         (b) listed + DEAD process + ancient heartbeat → reclaims, spawns, journals drainer_reclaimed,
#             and the heartbeat is FRESH afterward (spawn stamp).
#         (c) respawn that fails with agent_name_taken → journals infra_event (respawn_failed), a CLEAN
#             message, exit 0 — never a raw driver error dumped.
#
# Test surface named in the PR: tests/test-drainer-liveness-corroborate.sh (+ scripts/herd/drainer-liveness.sh,
# scripts/herd/scribe.sh, scripts/herd/research.sh).
# Run:  bash tests/test-drainer-liveness-corroborate.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/scripts/herd/drainer-liveness.sh"
DRIVER="$ROOT/scripts/herd/driver.sh"
SCRIBE="$ROOT/scripts/herd/scribe.sh"
RESEARCH="$ROOT/scripts/herd/research.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required" >&2; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "$LIB" "$DRIVER" "$SCRIBE" "$RESEARCH"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

ANCIENT="200001010000"   # POSIX `touch -t CCYYMMDDhhmm`, staler than any positive timeout

# ── source the libs (driver first so herd_drainer_live_status can reach the process probe) ────────────
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
# shellcheck source=/dev/null
. "$DRIVER" || fail "sourcing driver.sh failed"
# shellcheck source=/dev/null
. "$LIB" || fail "sourcing drainer-liveness.sh failed"

json_agent(){ printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s","workspace_id":""}]}}' "$1" "$2" "${3:-}"; }

# ════════════════════════════════════════════════════════════════════════════
# (1) herd_drainer_live_status
# ════════════════════════════════════════════════════════════════════════════
[ "$(herd_drainer_live_status foo "$(json_agent foo working)")" = "alive" ] || fail "(1a) working status ⇒ alive"
pass; echo "PASS (1a) working status ⇒ alive"
[ "$(herd_drainer_live_status foo "$(json_agent foo idle)")" = "alive" ] || fail "(1b) idle status ⇒ alive"
pass; echo "PASS (1b) idle status ⇒ alive"
# an agent NOT in the list + no probe record ⇒ unknown (fail-soft — never fabricate a death)
( export HERD_DRIVER=headless
  [ "$(herd_drainer_live_status ghost '{"result":{"agents":[]}}')" = "unknown" ] || { echo "1c FAIL"; exit 1; }
) || fail "(1c) no data ⇒ unknown"
pass; echo "PASS (1c) unknown status + no record ⇒ unknown (fail-soft)"
# a headless DEAD pid (status word non-live) ⇒ dead via the process probe
( export HERD_DRIVER=headless
  adir="$WORKTREES_DIR/.herd/agents/deadone"; mkdir -p "$adir"; echo 2147480000 > "$adir/pid"  # not-running pid
  [ "$(herd_drainer_live_status deadone "$(json_agent deadone done)")" = "dead" ] || { echo "1d FAIL"; exit 1; }
) || fail "(1d) dead pid ⇒ dead"
pass; echo "PASS (1d) non-live status + dead pid ⇒ dead"
# a headless LIVE pid, even with a non-live status word, ⇒ alive (process truth wins)
( export HERD_DRIVER=headless
  adir="$WORKTREES_DIR/.herd/agents/liveone"; mkdir -p "$adir"; echo $$ > "$adir/pid"
  [ "$(herd_drainer_live_status liveone "$(json_agent liveone done)")" = "alive" ] || { echo "1e FAIL"; exit 1; }
) || fail "(1e) live pid ⇒ alive"
pass; echo "PASS (1e) live pid (even with stale status) ⇒ alive"

# ════════════════════════════════════════════════════════════════════════════
# (2) herd_drainer_should_reclaim — the three required fixtures + edges
# ════════════════════════════════════════════════════════════════════════════
HB="$T/hb"
decide(){ if herd_drainer_should_reclaim "$1" "$2" "$3"; then echo reclaim; else echo keep; fi; }

# fixture 1 — fresh drainer w/o heartbeat → NO reclaim inside grace (absent heartbeat = alive)
[ "$(decide "$T/absent" 900 unknown)" = "keep" ] || fail "(2a) absent heartbeat must NOT reclaim (fresh drainer, no beat yet)"
touch "$HB"
[ "$(decide "$HB" 900 dead)" = "keep" ] || fail "(2a) a FRESH heartbeat must NOT reclaim even if the probe says dead (inside grace)"
pass; echo "PASS (2a) fixture①: fresh/absent heartbeat inside grace → keep (no reclaim)"

# fixture 2 — stale heartbeat + LIVE (working) agent → reclaim REFUSED (the false positive)
touch -t "$ANCIENT" "$HB"
[ "$(decide "$HB" 900 alive)" = "keep" ] || fail "(2b) a LIVE agent must NEVER be reclaimed regardless of heartbeat age"
pass; echo "PASS (2b) fixture②: stale heartbeat + live agent → keep (reclaim refused — no false-red)"

# fixture 3 — dead pid + stale heartbeat → reclaim PROCEEDS (real detection intact)
[ "$(decide "$HB" 900 dead)" = "reclaim" ] || fail "(2c) a genuinely DEAD drainer with a stale heartbeat MUST reclaim"
pass; echo "PASS (2c) fixture③: stale heartbeat + dead process → reclaim (genuine hang recovered)"

# edges: unknown liveness never reclaims (fail-soft); disabled timeout never reclaims (legacy)
[ "$(decide "$HB" 900 unknown)" = "keep" ] || fail "(2d) unknown liveness must NOT reclaim (fail-soft, no false-red)"
[ "$(decide "$HB" 0 dead)" = "keep" ] || fail "(2d) timeout 0 disables reclaim even for a dead agent (pure legacy)"
[ "$(decide "$HB" abc dead)" = "keep" ] || fail "(2d) non-numeric timeout disables reclaim"
pass; echo "PASS (2d) edges: unknown liveness / disabled timeout → keep"

# ════════════════════════════════════════════════════════════════════════════
# herdr stub for the (3)/(4) integration — file/env-backed, network-free
# ════════════════════════════════════════════════════════════════════════════
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
# Env knobs (exported by each test case):
#   STUB_CALLS         append each subcommand here
#   STUB_AGENT_NAME    the drainer agent name to list (empty ⇒ list NO agents)
#   STUB_AGENT_STATUS  agent_status to report for it (default working)
#   STUB_PANE_CLAUDE   1 ⇒ pane process-info shows a live claude foreground; else bare (dead)
#   STUB_START_RC      exit code for `agent start` (default 0); non-zero prints an agent_name_taken error
[ -n "${STUB_CALLS:-}" ] && printf '%s\n' "$*" >> "$STUB_CALLS"
case "${1:-} ${2:-}" in
  "workspace list") printf '{"result":{"workspaces":[]}}\n' ;;   # ⇒ _WS_ID empty (name-only match)
  "agent list")
    if [ -n "${STUB_AGENT_NAME:-}" ]; then
      printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"p1","workspace_id":""}]}}\n' \
        "$STUB_AGENT_NAME" "${STUB_AGENT_STATUS:-working}"
    else
      printf '{"result":{"agents":[]}}\n'
    fi ;;
  "pane process-info")
    if [ "${STUB_PANE_CLAUDE:-0}" = "1" ]; then
      printf '{"result":{"process_info":{"shell_pid":4242,"foreground_processes":[{"pid":5151,"cmdline":"claude --model x"}]}}}\n'
    else
      printf '{"result":{"process_info":{"shell_pid":4242,"foreground_processes":[]}}}\n'
    fi ;;
  "tab create") printf '{"result":{"tab":{"tab_id":"tab-new"},"root_pane":{"pane_id":"rp1"}}}\n' ;;
  "agent start")
    if [ "${STUB_START_RC:-0}" != "0" ]; then
      echo "herdr: error: agent_name_taken: an agent named '${3:-}' already exists" >&2
      exit "${STUB_START_RC}"
    fi ;;
  "tab close") : ;;
  "notification show") : ;;
  *) printf '{"result":{}}\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"

# common test config for scribe.sh
cat > "$T/config" <<EOF
PROJECT_ROOT="$T/repo"
WORKTREES_DIR="$T/trees"
WORKSPACE_NAME="livetest"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
EOF
mkdir -p "$T/repo" "$T/trees"
SB_HB="$T/trees/.scribe.heartbeat"
JQ="$T/journal.jsonl"
CALLS="$T/calls"
AGENT="scribe-livetest"

# run_scribe <label...> — invoke the REAL scribe.sh with the stub on PATH; returns its stdout.
run_scribe(){
  : > "$CALLS"
  PATH="$BIN:$PATH" HERD_CONFIG_FILE="$T/config" JOURNAL_FILE="$JQ" \
    SCRIBE_MODEL="stub-model" STUB_CALLS="$CALLS" \
    STUB_AGENT_NAME="${A_NAME:-}" STUB_AGENT_STATUS="${A_STATUS:-working}" \
    STUB_PANE_CLAUDE="${A_CLAUDE:-0}" STUB_START_RC="${A_START_RC:-0}" \
    bash "$SCRIBE" "$1" 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════
# (3) SPAWN-TIME STAMP — no drainer listed → scribe spawns AND stamps a fresh heartbeat
# ════════════════════════════════════════════════════════════════════════════
: > "$JQ"
touch -t "$ANCIENT" "$SB_HB"                 # a leftover, ancient heartbeat from a prior drainer
A_NAME="" A_STATUS="" A_CLAUDE="0" A_START_RC="0"
out="$(run_scribe "first enqueue")"
printf '%s\n' "$out" | grep -q "drainer dispatched" || fail "(3) with no drainer listed, scribe must spawn one (got: $out)"
grep -q '^tab create' "$CALLS" || fail "(3) scribe must create a tab when spawning"
grep -q '^agent start' "$CALLS" || fail "(3) scribe must start the agent when spawning"
herd_drainer_hung "$SB_HB" 900 && fail "(3) after spawn the heartbeat must be FRESH (stamped at spawn) — a leftover ancient beat must not survive"
pass; echo "PASS (3) spawn stamps a fresh heartbeat (grace measured from spawn, not a leftover file)"

# ════════════════════════════════════════════════════════════════════════════
# (4a) listed + WORKING + ancient heartbeat → reclaim REFUSED, NO spawn, journaled
# ════════════════════════════════════════════════════════════════════════════
: > "$JQ"
touch -t "$ANCIENT" "$SB_HB"
A_NAME="$AGENT" A_STATUS="working" A_CLAUDE="1" A_START_RC="0"
out="$(run_scribe "second enqueue")"
printf '%s\n' "$out" | grep -q "already running" || fail "(4a) a live (working) drainer must be KEPT — 'already running' (got: $out)"
printf '%s\n' "$out" | grep -qi "reclaiming the singleton\|is DEAD" && fail "(4a) a live drainer must NOT be declared dead/reclaimed (got: $out)"
grep -q '^tab create' "$CALLS" && fail "(4a) a refused reclaim must NOT spawn a new drainer (tab create seen)"
grep -q '^agent start' "$CALLS" && fail "(4a) a refused reclaim must NOT start a new agent"
grep -q 'drainer_reclaim_refused' "$JQ" || fail "(4a) a refused reclaim must be JOURNALED (drainer_reclaim_refused)"
pass; echo "PASS (4a) listed+working+ancient → reclaim refused, no spawn, journaled (no false-red)"

# ════════════════════════════════════════════════════════════════════════════
# (4b) listed + DEAD process + ancient heartbeat → reclaim, spawn, journaled, heartbeat re-stamped
# ════════════════════════════════════════════════════════════════════════════
: > "$JQ"
touch -t "$ANCIENT" "$SB_HB"
A_NAME="$AGENT" A_STATUS="done" A_CLAUDE="0" A_START_RC="0"   # listed but process is a bare shell ⇒ dead
out="$(run_scribe "third enqueue")"
printf '%s\n' "$out" | grep -qi "DEAD\|reclaiming" || fail "(4b) a genuinely dead drainer must be reclaimed (got: $out)"
grep -q '^tab create' "$CALLS" || fail "(4b) a genuine reclaim must spawn a fresh drainer (tab create)"
grep -q '^agent start' "$CALLS" || fail "(4b) a genuine reclaim must start the fresh agent"
grep -q 'drainer_reclaimed' "$JQ" || fail "(4b) a genuine reclaim must be JOURNALED (drainer_reclaimed)"
herd_drainer_hung "$SB_HB" 900 && fail "(4b) after a reclaim spawn the heartbeat must be FRESH again"
pass; echo "PASS (4b) listed+dead+ancient → reclaim + spawn + journaled + fresh heartbeat"

# ════════════════════════════════════════════════════════════════════════════
# (4c) respawn that fails with agent_name_taken → infra_event journaled, clean message, exit 0
# ════════════════════════════════════════════════════════════════════════════
: > "$JQ"
touch -t "$ANCIENT" "$SB_HB"
# Reclaim the (dead-looking) drainer, but `agent start` fails (the live drainer still holds the name).
A_NAME="$AGENT" A_STATUS="done" A_CLAUDE="0" A_START_RC="3"
out="$(PATH="$BIN:$PATH" HERD_CONFIG_FILE="$T/config" JOURNAL_FILE="$JQ" SCRIBE_MODEL="stub-model" \
  STUB_CALLS="$CALLS" STUB_AGENT_NAME="$AGENT" STUB_AGENT_STATUS="done" STUB_PANE_CLAUDE="0" STUB_START_RC="3" \
  bash "$SCRIBE" "fourth enqueue" 2>/dev/null)"
rc=$?
[ "$rc" = "0" ] || fail "(4c) a failed respawn must exit CLEANLY (0), not abort — got rc=$rc"
printf '%s\n' "$out" | grep -qi "agent_name_taken\|error:" && fail "(4c) a failed respawn must NOT dump the raw driver error (got: $out)"
printf '%s\n' "$out" | grep -qi "already holds the name\|queued" || fail "(4c) a failed respawn must print a clean, reassuring message (got: $out)"
grep -q 'infra_event' "$JQ" || fail "(4c) a failed respawn must journal an infra_event"
grep -q 'respawn_failed' "$JQ" || fail "(4c) the infra_event must carry reason respawn_failed"
pass; echo "PASS (4c) failed respawn → infra_event journaled, clean message, exit 0 (no raw driver error)"

echo
echo "ALL PASS ($PASS checks) — HERD-122: fresh/live drainer never false-reclaimed; genuine hang still recovers."
