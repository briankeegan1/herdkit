#!/usr/bin/env bash
# test-fleet-room.sh — hermetic tests for `herd fleet room` (P3 NL master-coordinator launcher).
#
# Design (mirrors test-fleet.sh):
#   • Fully hermetic: a temp HERD_FLEET_FILE registry, a temp HERD_FLEET_ROOM_DIR, a temp $HOME,
#     and a STUB `herdr` on PATH that logs its argv and emits deterministic JSON — so the launcher
#     invocation shape is asserted without ever creating a real herdr workspace/tab/agent.
#   • `claude` is never executed: it only appears inside the `herdr agent start … -- claude …`
#     argv, which the stubbed herdr records but does not run.
#
# Run:  bash tests/test-fleet-room.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0
ok(){ pass=$((pass+1)); }

# ── Stub herdr on PATH: log argv (one line per call) + emit deterministic JSON ───────────────
BIN="$T/bin"; mkdir -p "$BIN"
export HERDR_LOG="$T/herdr.log"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
# Record the full argv (space-joined) so the test can assert the launcher's invocation shape.
printf '%s\n' "$*" >> "${HERDR_LOG:?}"
case "$1 $2" in
  "workspace list")   echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"ws-fleet"},"tab":{"tab_id":"tab-1"},"root_pane":{"pane_id":"pane-1"}}}' ;;
  "workspace focus")  echo '{"result":{}}' ;;
  "tab list")         echo '{"result":{"tabs":[]}}' ;;
  "tab create")       echo '{"result":{"tab":{"tab_id":"tab-1"},"root_pane":{"pane_id":"pane-1"}}}' ;;
  "tab rename")       echo '{"result":{}}' ;;
  "tab close")        echo '{"result":{}}' ;;
  "agent start")      echo '{"result":{"agent":{"pane_id":"apane-1"}}}' ;;
  *)                  echo '{"result":{}}' ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# Isolate HOME + the fleet seams into temp locations.
export HOME="$T/home"; mkdir -p "$HOME"
export HERD_FLEET_FILE="$T/registry/fleet"
export HERD_FLEET_ROOM_DIR="$T/room"
export MODEL_COORDINATOR="test-model-x"   # assert this flows through to the launch argv

SKILL="$HERD_FLEET_ROOM_DIR/.claude/commands/fleet-coordinator.md"

# _make_project <name> — a dir with a .herd/config the registry can read (no git needed to register).
_make_project() {
  local name="$1"; local root="$T/proj/$name"
  mkdir -p "$root/.herd"
  local root_real; root_real="$(cd "$root" && pwd -P)"
  cat > "$root/.herd/config" <<CFG
PROJECT_ROOT="$root_real"
WORKTREES_DIR="$root_real-trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="$name"
HERD_REPO="me/$name"
CFG
  printf '%s' "$root_real"
}

# ── 1. empty registry → clean refusal (non-zero) + no herdr launch ────────────
set +e
out="$(HERD_FLEET_FILE="$T/none/fleet" bash "$HERD" fleet room 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "empty-registry fleet room should exit non-zero"
printf '%s' "$out" | grep -qi "register" || fail "empty refusal should point at 'herd fleet register'"
printf '%s' "$out" | grep -qi "discover" || fail "empty refusal should point at 'herd fleet discover'"
[ ! -s "$HERDR_LOG" ] || fail "empty-registry refusal must NOT invoke herdr (no launch on empty fleet)"
ok

# ── 2. register two projects, then launch the room ───────────────────────────
ALPHA="$(_make_project alpha)"
BETA="$(_make_project beta)"
bash "$HERD" fleet register "$ALPHA" >/dev/null
bash "$HERD" fleet register "$BETA"  >/dev/null

: > "$HERDR_LOG"   # fresh log for the launch assertions
out="$(bash "$HERD" fleet room 2>&1)" || fail "fleet room should succeed with a non-empty registry"
printf '%s' "$out" | grep -qi "fleet room up" || fail "launch should report the room is up"
printf '%s' "$out" | grep -q "fleet-coordinator" || fail "launch should name the fleet-coordinator agent"
ok

# ── 3. the skill renders with registry projects substituted, no raw tokens ────
[ -f "$SKILL" ] || fail "render should write the fleet skill to $SKILL"
grep -q "alpha" "$SKILL" || fail "rendered skill missing registered project alpha"
grep -q "beta"  "$SKILL" || fail "rendered skill missing registered project beta"
grep -q "$ALPHA" "$SKILL" || fail "rendered skill missing alpha's path"
grep -q "test-model-x" "$SKILL" || fail "rendered skill missing MODEL_COORDINATOR substitution"
grep -q "2" "$SKILL" || fail "rendered skill missing the project count"
if grep -q '{{' "$SKILL"; then fail "rendered skill still contains an unsubstituted {{TOKEN}}"; fi
grep -qi "fleet inbox" "$SKILL" || fail "rendered skill should tell the master to surface the inbox first"
grep -qi "never" "$SKILL" || fail "rendered skill should state the never-edit/never-merge rules"
ok

# ── 4. the launcher invocation shape (stubbed herdr) ─────────────────────────
# Fresh workspace path: workspace create (labeled 'fleet') → agent start … -- claude --model … /cmd.
grep -q "workspace create" "$HERDR_LOG" || fail "launcher should create a fleet workspace"
grep "workspace create" "$HERDR_LOG" | grep -q -- "--label fleet" \
  || fail "the fleet workspace must be created with --label fleet"
grep "workspace create" "$HERDR_LOG" | grep -q -- "--cwd $HERD_FLEET_ROOM_DIR" \
  || fail "the workspace cwd should be the fleet room dir"
grep -q "agent start fleet-coordinator" "$HERDR_LOG" \
  || fail "launcher should start the fleet-coordinator agent"
astart="$(grep 'agent start fleet-coordinator' "$HERDR_LOG")"
printf '%s' "$astart" | grep -q -- "--workspace ws-fleet" || fail "agent should start in the created workspace"
printf '%s' "$astart" | grep -q -- "claude --model test-model-x" || fail "agent should run claude on MODEL_COORDINATOR"
printf '%s' "$astart" | grep -q -- "/fleet-coordinator" || fail "agent should run the /fleet-coordinator skill"
ok

# ── 5. NO watcher/backlog panes (minimal: one tab only) ──────────────────────
# The per-project control room splits panes for the watcher + backlog viewer; the fleet room must not.
if grep -q "pane split" "$HERDR_LOG"; then fail "fleet room must be minimal — no pane split (no watcher/backlog panes)"; fi
if grep -qi "herd-watch\|backlog-view" "$HERDR_LOG"; then fail "fleet room must not launch watcher/backlog panes"; fi
ok

# ── 6. reuse: a second launch with an existing 'fleet' workspace reuses it ───
# Point workspace-list at a stub that reports our labeled workspace already exists.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_LOG:?}"
case "$1 $2" in
  "workspace list")   echo '{"result":{"workspaces":[{"workspace_id":"ws-fleet","label":"fleet"}]}}' ;;
  "workspace focus")  echo '{"result":{}}' ;;
  "tab list")         echo '{"result":{"tabs":[{"tab_id":"old-room","label":"fleet-room"}]}}' ;;
  "tab close")        echo '{"result":{}}' ;;
  "tab create")       echo '{"result":{"tab":{"tab_id":"tab-2"},"root_pane":{"pane_id":"pane-2"}}}' ;;
  "tab rename")       echo '{"result":{}}' ;;
  "agent start")      echo '{"result":{"agent":{"pane_id":"apane-2"}}}' ;;
  *)                  echo '{"result":{}}' ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"

: > "$HERDR_LOG"
bash "$HERD" fleet room >/dev/null 2>&1 || fail "reuse launch should succeed"
if grep -q "workspace create" "$HERDR_LOG"; then fail "reuse path must NOT create a second fleet workspace"; fi
grep -q "workspace focus ws-fleet" "$HERDR_LOG" || fail "reuse path should focus the existing fleet workspace"
grep -q "tab close old-room" "$HERDR_LOG" || fail "reuse path should close the stale fleet-room tab first"
grep -q "tab create" "$HERDR_LOG" || fail "reuse path should open a fresh fleet-room tab"
grep -q "agent start fleet-coordinator" "$HERDR_LOG" || fail "reuse path should still start the agent"
ok

# ── 7. unknown argument fails loudly ─────────────────────────────────────────
if bash "$HERD" fleet room bogus >/dev/null 2>&1; then
  fail "fleet room should reject unexpected arguments"
fi
ok

# ── 8. --help prints usage without launching herdr ───────────────────────────
: > "$HERDR_LOG"
out="$(bash "$HERD" fleet room --help 2>&1)" || fail "fleet room --help should exit 0"
printf '%s' "$out" | grep -qi "master-coordinator" || fail "help should describe the master-coordinator"
[ ! -s "$HERDR_LOG" ] || fail "--help must not invoke herdr"
ok

echo "ALL PASS ($pass checks)"
