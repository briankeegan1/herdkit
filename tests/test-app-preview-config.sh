#!/usr/bin/env bash
# test-app-preview-config.sh — hermetic proof that the app-preview launch + health probe are
# CONFIGURABLE, no longer hardcoding one web framework's launch flags / probe (docs/external-
# consumer-audit.md "Leak C", ranked follow-up #4 [P1] "App-preview: de-Streamlit").
#
# Asserts, driving the REAL scripts/herd/app-monitor.sh with a recording fake preview command:
#   (1) DEFAULTS UNCHANGED — with no config, the preview command is launched with the existing
#       dev-server flags (--server.port <PORT> --server.headless true), and the default health probe
#       stays active (HTTP GET, so the panel is NOT rendered "health unknown").
#   (2) NO FORCE-APPEND — with APP_PREVIEW_SERVER_ARGS="" the command receives ZERO extra args, so a
#       non-web-framework command (a CLI, a Go/Rust/Node server) is no longer crashed by injected flags.
#   (3) NO-PROBE = UNKNOWN, NOT RED — with the HTTP path emptied and no health command, the panel
#       renders "health unknown" (⚪) and never "🔴 starting/down".
#   (4) COMMAND PROBE — APP_PREVIEW_HEALTH_CMD drives the verdict (exit 0 → 🟢 serving) without any
#       HTTP assumption, proving a non-HTTP preview can report healthy.
#
# Fully hermetic: local temp only, NO herdr, NO network, NO model. The fake preview command records
# its argv and then idles, so the monitor's self-refresh panel renders at least once before we kill it.
# Run:  bash tests/test-app-preview-config.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MONITOR="$HERE/../scripts/herd/app-monitor.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v bash >/dev/null 2>&1 || fail "bash required"
[ -f "$MONITOR" ] || fail "missing $MONITOR"

# A fake preview command: record the argv it was launched with, then idle so the monitor keeps the
# server "alive" and its self-refresh panel renders. Killed when the monitor is killed (trap).
FAKE="$T/fake-preview.sh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
{ printf 'ARGC=%s\n' "$#"; printf 'ARGV=%s\n' "$*"; } > "$ARGS_OUT"
exec sleep 3
EOF
chmod +x "$FAKE"

WORK="$T/work"; mkdir -p "$WORK"   # a NON-git cwd so the healthcheck sub-probe is skipped (fast)
PORT=8577                          # never actually bound — the fake preview doesn't open a socket

# run_case <config-file> <args-out> <panel-out> — launch the real monitor against a config file,
# wait until it renders its status line at least once (or times out), then kill it. Sets MON_PID.
run_case() {
  local cfg="$1" args_out="$2" panel_out="$3"
  : > "$panel_out"
  ( cd "$WORK"; exec env TERM=xterm ARGS_OUT="$args_out" HERD_CONFIG_FILE="$cfg" \
      bash "$MONITOR" "$PORT" ) > "$panel_out" 2>/dev/null &
  MON_PID=$!
  # Poll for the first render (the panel prints the ":<PORT>" header). Bounded ~5s.
  local i
  for i in $(seq 1 50); do
    grep -q ":$PORT" "$panel_out" 2>/dev/null && break
    sleep 0.1
  done
  # HARD teardown: app-monitor.sh traps TERM WITHOUT exiting (it only reaps its server child), so a
  # plain `kill` leaves the render loop running and `wait` hangs. Reap the preview child first (still
  # parented to the monitor here), then SIGKILL the monitor itself.
  pkill -P "$MON_PID" 2>/dev/null || true
  kill -KILL "$MON_PID" 2>/dev/null || true
  wait "$MON_PID" 2>/dev/null || true
}

# ── (1) DEFAULTS UNCHANGED ───────────────────────────────────────────────────────
cat > "$T/cfg-default" <<EOF
APP_PREVIEW_CMD="bash $FAKE"
EOF
run_case "$T/cfg-default" "$T/args-default" "$T/panel-default"
[ -f "$T/args-default" ] || fail "(1) default: fake preview command was never launched"
grep -qx "ARGC=4" "$T/args-default" \
  || fail "(1) default must append exactly the 4 dev-server tokens: $(cat "$T/args-default")"
grep -qx "ARGV=--server.port $PORT --server.headless true" "$T/args-default" \
  || fail "(1) default launch flags changed (must reproduce existing behavior): $(cat "$T/args-default")"
grep -q 'health unknown' "$T/panel-default" \
  && fail "(1) default health probe must stay ACTIVE (HTTP), not 'unknown'"
echo "PASS (1) defaults unchanged — command launched with '--server.port $PORT --server.headless true', HTTP probe active"

# ── (2) NO FORCE-APPEND for a non-framework command ──────────────────────────────
cat > "$T/cfg-noargs" <<EOF
APP_PREVIEW_CMD="bash $FAKE"
APP_PREVIEW_SERVER_ARGS=""
EOF
run_case "$T/cfg-noargs" "$T/args-noargs" "$T/panel-noargs"
[ -f "$T/args-noargs" ] || fail "(2) no-args: fake preview command was never launched"
grep -qx "ARGC=0" "$T/args-noargs" \
  || fail "(2) APP_PREVIEW_SERVER_ARGS='' must pass ZERO extra args (no force-append): $(cat "$T/args-noargs")"
echo "PASS (2) APP_PREVIEW_SERVER_ARGS='' — non-framework command launched with NO injected flags"

# ── (3) NO PROBE CONFIGURED → health UNKNOWN, never RED ──────────────────────────
cat > "$T/cfg-noprobe" <<EOF
APP_PREVIEW_CMD="bash $FAKE"
APP_PREVIEW_HEALTH_PATH=""
EOF
run_case "$T/cfg-noprobe" "$T/args-noprobe" "$T/panel-noprobe"
grep -q 'health unknown' "$T/panel-noprobe" \
  || fail "(3) no probe configured must render 'health unknown': $(cat "$T/panel-noprobe")"
grep -q 'starting/down' "$T/panel-noprobe" \
  && fail "(3) no probe configured must NOT render a red 'starting/down' verdict"
echo "PASS (3) no probe configured → 'health unknown' (⚪), never red"

# ── (4) COMMAND PROBE drives the verdict without any HTTP assumption ──────────────
cat > "$T/cfg-cmd" <<EOF
APP_PREVIEW_CMD="bash $FAKE"
APP_PREVIEW_HEALTH_CMD="true"
EOF
run_case "$T/cfg-cmd" "$T/args-cmd" "$T/panel-cmd"
grep -q 'serving' "$T/panel-cmd" \
  || fail "(4) APP_PREVIEW_HEALTH_CMD='true' must report 🟢 serving: $(cat "$T/panel-cmd")"
grep -q 'health unknown' "$T/panel-cmd" \
  && fail "(4) with a health command configured the verdict must not be 'unknown'"
echo "PASS (4) APP_PREVIEW_HEALTH_CMD drives the verdict (exit 0 → serving), no HTTP required"

echo
echo "ALL PASS — app-preview launch flags, port range, and health probe are configurable; web-app defaults preserved."
