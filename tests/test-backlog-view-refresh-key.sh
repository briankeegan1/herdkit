#!/usr/bin/env bash
# test-backlog-view-refresh-key.sh — hermetic, network-free test of the manual-refresh key (HERD-48).
#
# The coordinator's backlog pane lets the user press r/R to force an immediate refetch+repaint instead
# of waiting out the poll interval. Driving that for real needs a controlling tty and a keystroke — but
# the suite runs INSIDE a live pane, and reading its /dev/tty wedges the gate. So this test never
# touches the real terminal: it points the viewer's tty at /dev/null (BACKLOG_VIEW_TTY, which is not a
# tty → the no-tty code path) and injects keypresses through the BACKLOG_VIEW_KEY_CMD hook — the one
# seam where poll_wait reads a key. Everything runs FOREGROUND with a fixed poll; no pty, no
# backgrounding, no timing races.
#
# The FAKE `herd` emits a FIXED list, so backlog content never changes between polls — which makes the
# assertions unambiguous: a repaint of unchanged content can happen ONLY when a keypress cleared the
# render latch (content is otherwise hashed and NOT repainted). Each repaint prints exactly one header
# line (contains 'live ·'), so counting headers counts repaints.
#
# Coverage:
#   1. refresh    — 'r' forces a SECOND repaint of unchanged content (2 headers).
#   2. other key  — 'x' is ignored: unchanged content is NOT repainted (1 header), cadence unchanged.
#   3. no-tty     — no key source (no hook, tty=/dev/null): plain-sleep fallback renders, terminates,
#                   and OMITS the 'r = refresh' footer — byte-identical to the pre-HERD-48 frame.
#
# Run:  bash tests/test-backlog-view-refresh-key.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-view.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

BIN="$T/bin"; mkdir -p "$BIN"; LOG="$T/herd.log"

# FAKE `herd` — logs calls; for `backlog` prints a FIXED list (content is constant across polls).
cat > "$BIN/herd" <<'FAKE'
#!/usr/bin/env bash
echo "herd $*" >> "$HERD_FAKE_LOG"
[ "${1:-}" = "backlog" ] || exit 0
printf '%s\n' "${HERD_FAKE_OUT:-}"
FAKE
chmod +x "$BIN/herd"

# Key hooks (the BACKLOG_VIEW_KEY_CMD contract: print the pressed key + exit 0, or exit >128 for a
# timeout). key-r presses 'r' once. key-x presses a non-refresh key 'x' once, then behaves like the
# real read after a keystroke — it waits out the remaining interval and times out (so poll_wait can
# never busy-spin on it).
cat > "$BIN/key-r" <<'EOF'
#!/usr/bin/env bash
printf 'r'
EOF
cat > "$BIN/key-x" <<'EOF'
#!/usr/bin/env bash
c="${KEYCMD_COUNTER:?}"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
if [ "$n" -eq 1 ]; then printf 'x'; exit 0; fi
sleep "${1:-0}"; exit 142
EOF
chmod +x "$BIN/key-r" "$BIN/key-x"

# Project with a non-file (linear) backend so the backend-poll loop runs.
P="$T/proj"; mkdir -p "$P/.herd"
cat > "$P/.herd/config" <<EOF
PROJECT_ROOT="$P"
WORKSPACE_NAME="testws"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="linear"
EOF

# run_view [extra env KEY=VAL ...] — run the viewer against $P with the fake herd on PATH, the tty
# pointed at /dev/null (never the real terminal), and the console cwd-guard bypassed. Prints stdout.
run_view() {
  env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm \
    HERD_CONFIG_FILE="$P/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 HERD_FAKE_LOG="$LOG" \
    BACKLOG_VIEW_TTY=/dev/null "$@" \
    bash "$SCRIPT" 2>/dev/null </dev/null
}
headers(){ grep -c 'live ·' <<<"$1" || true; }

# ── Case 1: 'r' forces a repaint of UNCHANGED content ────────────────────────────────────────────
: > "$LOG"
out1="$(run_view BACKLOG_VIEW_KEY_CMD="$BIN/key-r" BACKLOG_VIEW_MAX_POLLS=2 BACKLOG_VIEW_POLL_SECS=1 \
        HERD_FAKE_OUT="#R-1 refresh-item")"
grep -q "refresh-item" <<<"$out1"      || fail "refresh: backlog list never rendered"
h1="$(headers "$out1")"
[ "$h1" -eq 2 ] || fail "refresh: 'r' did not repaint unchanged content (expected 2 headers, got $h1):
$out1"
pass

# ── Case 2: a non-refresh key is IGNORED — unchanged content is NOT repainted ─────────────────────
: > "$LOG"; : > "$T/kc"
out2="$(run_view BACKLOG_VIEW_KEY_CMD="$BIN/key-x" KEYCMD_COUNTER="$T/kc" BACKLOG_VIEW_MAX_POLLS=2 \
        BACKLOG_VIEW_POLL_SECS=1 HERD_FAKE_OUT="#R-1 refresh-item")"
grep -q "refresh-item" <<<"$out2"      || fail "other-key: backlog list never rendered"
h2="$(headers "$out2")"
[ "$h2" -eq 1 ] || fail "other-key: 'x' should be ignored (expected 1 header, got $h2):
$out2"
pass

# ── Case 3: no key source → plain-sleep fallback, footer omitted, byte-identical frame ────────────
: > "$LOG"
out3="$(run_view BACKLOG_VIEW_MAX_POLLS=2 BACKLOG_VIEW_POLL_SECS=1 HERD_FAKE_OUT="#R-1 refresh-item")"
grep -q "refresh-item" <<<"$out3"          || fail "no-tty: fallback did not render the list"
grep -q "r = refresh" <<<"$out3"           && fail "no-tty: footer hint shown though there is no tty (not byte-identical)"
h3="$(headers "$out3")"
[ "$h3" -eq 1 ] || fail "no-tty: unchanged content must not repaint in the fallback (expected 1 header, got $h3)"
pass

echo "ALL PASS ($PASS checks)"
