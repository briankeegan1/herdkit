#!/usr/bin/env bash
# test-app-preview-port-scan.sh — conformance proof for APP_PREVIEW_PORT_BASE (HERD-383): no prior
# test asserted the free-port BASE-SCAN itself (scripts/herd/herd-feature.sh + herd-resolve.sh each
# carry an inline `python3 -` port scan — templates/conformance.tsv previously noted this as
# `none-yet`). test-app-preview-config.sh only drives app-monitor.sh's launch+probe, never the scan
# that PICKS the port or the config key that seeds it.
#
# Drives the REAL lane scripts (herd-feature.sh + herd-resolve.sh) end to end — same harness shape as
# tests/test-task-spec-pane.sh (a stub herdr that logs every call + returns fixed ids, a throwaway
# git repo, a real `git worktree add`). NO reimplementation of the scan logic under test.
#
# Asserts, for EACH lane (herd-feature.sh and herd-resolve.sh — both carry the scan, HERD-383):
#   (1) HONORS THE CONFIGURED BASE — with the base port free, the app-preview pane is launched on
#       EXACTLY the configured APP_PREVIEW_PORT_BASE (not the shipped 8501 default).
#   (2) SKIPS AN OCCUPIED BASE — with a fixture listener bound to APP_PREVIEW_PORT_BASE, the scan
#       selects the NEXT free port (base+1), never the occupied one, and never falls back to 8501.
#
# Fully hermetic: local temp dirs + a stub herdr on PATH, a throwaway git repo, real TCP sockets on
# 127.0.0.1 (high, scenario-private ports — no real herdr/claude/gh/network/model).
# Run:  bash tests/test-app-preview-port-scan.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FEATURE="$ROOT/scripts/herd/herd-feature.sh"
RESOLVE="$ROOT/scripts/herd/herd-resolve.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"; jobs -p | xargs -r kill -KILL 2>/dev/null || true' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); }

[ -f "$FEATURE" ] || fail "missing $FEATURE"
[ -f "$RESOLVE" ] || fail "missing $RESOLVE"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v git >/dev/null 2>&1 || fail "git required"

# ── stub herdr — logs EVERY call, returns fixed tab/pane/agent ids (mirrors test-task-spec-pane.sh) ──
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "tab list")       printf '{"result":{"tabs":[]}}\n' ;;
  "tab create")     printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start")    printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

# ── throwaway git remote + main checkout (herd-feature.sh's new-feature.sh needs a real origin) ──────
ORIGIN="$T/origin.git"; REPO="$T/repo"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
: > "$REPO/seed.txt"
git -C "$REPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null

export HOME="$T"                 # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit"  # matches the herdr stub's workspace label
export HERD_SKIP_PREFLIGHT=1
TREES="$T/trees"

make_cfg() {   # make_cfg <port-base> — a fresh .herd config for one lane run.
  local base="$1"; local cfg="$T/config.$RANDOM"
  cat > "$cfg" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit"
MODEL_QUICK="test-quick-model"
MODEL_FEATURE="test-feature-model"
MODEL_RESOLVER="test-resolver-model"
APP_PREVIEW_CMD="echo app"
APP_PREVIEW_PORT_BASE="$base"
EOF
  printf '%s' "$cfg"
}

# run_lane <script> <slug> <cfg> [arg...] — run a lane, logging every herdr call to a per-slug file.
run_lane() {
  local script="$1" slug="$2" cfg="$3"; shift 3
  local log="$T/$slug.herdr.log"; : > "$log"
  env HERD_CONFIG_FILE="$cfg" HERDR_CALL_LOG="$log" WORKSPACE_NAME="herdkit" \
      HOME="$T" HERD_SKIP_PREFLIGHT=1 PATH="$PATH" \
      bash "$script" "$slug" "$@" >"$T/$slug.out" 2>&1 || \
      fail "$(basename "$script") exited non-zero for '$slug'"$'\n'"$(cat "$T/$slug.out")"
  printf '%s' "$log"
}

# preview_port <log> — the PORT app-monitor.sh was launched with (the tail token of the logged
# `pane run rTest bash …/app-monitor.sh <PORT>` call), empty if the preview was never launched.
preview_port() {
  grep -E 'pane run rTest bash .*app-monitor\.sh [0-9]+' "$1" 2>/dev/null | head -1 | awk '{print $NF}'
}

# occupy_port <port> — bind + listen on 127.0.0.1:<port> in the background so the scan must skip it.
# Blocks until the socket is actually bound (a ready-file poll, bounded ~5s) so there is no race
# between "listener started" and "lane launched". Sets $OCCUPY_PID (a GLOBAL, not a subshell-captured
# `$(...)` echo — a backgrounded job started inside a command-substitution subshell is orphaned the
# instant that subshell exits, silently dropping the fixture before the lane ever runs).
OCCUPY_PID=""
occupy_port() {
  local port="$1"
  local ready="$T/ready.$port"
  rm -f "$ready"
  python3 - "$port" "$ready" <<'PY' &
import socket, sys, time
port = int(sys.argv[1]); ready = sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(5)
open(ready, "w").write("ready")
time.sleep(60)
PY
  OCCUPY_PID=$!
  local i
  for i in $(seq 1 50); do
    [ -f "$ready" ] && break
    sleep 0.1
  done
  [ -f "$ready" ] || { kill -KILL "$OCCUPY_PID" 2>/dev/null || true; fail "occupy_port $port: fixture listener never bound"; }
}

port_is_free() {   # a quick precondition probe — never a fixture, just a sanity guard on the test's own port picks
  python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(("127.0.0.1", int(sys.argv[1]))); s.close(); sys.exit(0)
except OSError:
    sys.exit(1)
' "$1"
}

# Scenario-private port bases, high enough to avoid ephemeral/collision noise; distinct per scenario
# so the four runs below never interfere with each other.
BASE_FEATURE_HONOR=19301
BASE_FEATURE_SKIP=19401
BASE_RESOLVE_HONOR=19501
BASE_RESOLVE_SKIP=19601

for b in "$BASE_FEATURE_HONOR" "$BASE_FEATURE_SKIP" "$BASE_RESOLVE_HONOR" "$BASE_RESOLVE_SKIP"; do
  port_is_free "$b" || fail "precondition: port $b is not free in this environment — pick a different scenario base"
done

# ════════════════════════════════════════════════════════════════════════════════════════════════
# herd-feature.sh
# ════════════════════════════════════════════════════════════════════════════════════════════════

# (1) HONORS THE CONFIGURED BASE — base port free → preview lands EXACTLY on the configured base.
CFG="$(make_cfg "$BASE_FEATURE_HONOR")"
LOG="$(run_lane "$FEATURE" "portscan-feat-honor" "$CFG" "seed task")"
port="$(preview_port "$LOG")"
[ -n "$port" ] || fail "(feature/1) no app-preview pane was launched at all"$'\n'"$(cat "$LOG")"
[ "$port" = "$BASE_FEATURE_HONOR" ] \
  || fail "(feature/1) expected the preview on the configured base $BASE_FEATURE_HONOR, got $port"
ok; echo "PASS (feature/1) herd-feature.sh honors APP_PREVIEW_PORT_BASE=$BASE_FEATURE_HONOR exactly (not the 8501 default)"

# (2) SKIPS AN OCCUPIED BASE — a fixture listener sits on the base → scan selects base+1.
occupy_port "$BASE_FEATURE_SKIP"; PID="$OCCUPY_PID"
CFG="$(make_cfg "$BASE_FEATURE_SKIP")"
LOG="$(run_lane "$FEATURE" "portscan-feat-skip" "$CFG" "seed task")"
kill -KILL "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true
port="$(preview_port "$LOG")"
[ -n "$port" ] || fail "(feature/2) no app-preview pane was launched at all"$'\n'"$(cat "$LOG")"
[ "$port" != "$BASE_FEATURE_SKIP" ] || fail "(feature/2) scan selected the OCCUPIED base port $BASE_FEATURE_SKIP"
[ "$port" = "$((BASE_FEATURE_SKIP + 1))" ] \
  || fail "(feature/2) expected the next free port $((BASE_FEATURE_SKIP + 1)), got $port"
ok; echo "PASS (feature/2) herd-feature.sh: base $BASE_FEATURE_SKIP occupied → scan selects the next free port $((BASE_FEATURE_SKIP + 1))"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# herd-resolve.sh — resolves an EXISTING worktree in place (no new-feature.sh); create one directly.
# ════════════════════════════════════════════════════════════════════════════════════════════════
mk_resolve_worktree() {   # mk_resolve_worktree <slug> — a real linked worktree the resolver can target
  local slug="$1"
  git -C "$REPO" worktree add -q "$TREES/$slug" -b "resolve-fixture-$slug" origin/main 2>/dev/null \
    || fail "git worktree add failed for '$slug'"
}

# (1) HONORS THE CONFIGURED BASE.
mk_resolve_worktree "portscan-res-honor"
CFG="$(make_cfg "$BASE_RESOLVE_HONOR")"
LOG="$(run_lane "$RESOLVE" "portscan-res-honor" "$CFG")"
port="$(preview_port "$LOG")"
[ -n "$port" ] || fail "(resolve/1) no app-preview pane was launched at all"$'\n'"$(cat "$LOG")"
[ "$port" = "$BASE_RESOLVE_HONOR" ] \
  || fail "(resolve/1) expected the preview on the configured base $BASE_RESOLVE_HONOR, got $port"
ok; echo "PASS (resolve/1) herd-resolve.sh honors APP_PREVIEW_PORT_BASE=$BASE_RESOLVE_HONOR exactly (not the 8501 default)"

# (2) SKIPS AN OCCUPIED BASE.
mk_resolve_worktree "portscan-res-skip"
occupy_port "$BASE_RESOLVE_SKIP"; PID="$OCCUPY_PID"
CFG="$(make_cfg "$BASE_RESOLVE_SKIP")"
LOG="$(run_lane "$RESOLVE" "portscan-res-skip" "$CFG")"
kill -KILL "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true
port="$(preview_port "$LOG")"
[ -n "$port" ] || fail "(resolve/2) no app-preview pane was launched at all"$'\n'"$(cat "$LOG")"
[ "$port" != "$BASE_RESOLVE_SKIP" ] || fail "(resolve/2) scan selected the OCCUPIED base port $BASE_RESOLVE_SKIP"
[ "$port" = "$((BASE_RESOLVE_SKIP + 1))" ] \
  || fail "(resolve/2) expected the next free port $((BASE_RESOLVE_SKIP + 1)), got $port"
ok; echo "PASS (resolve/2) herd-resolve.sh: base $BASE_RESOLVE_SKIP occupied → scan selects the next free port $((BASE_RESOLVE_SKIP + 1))"

echo
echo "ALL PASS ($PASS assertions) — APP_PREVIEW_PORT_BASE's free-port scan is proven: honors the configured base, skips an occupied one, in BOTH herd-feature.sh and herd-resolve.sh."
