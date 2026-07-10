#!/usr/bin/env bash
# test-backlog-view-resize.sh — hermetic, network-free test of the resize/zoom repaint (HERD-288).
#
# The coordinator's backlog pane rendered through glow at a width read ONCE per repaint, but NEITHER
# frame-latch key carried that width. glamour hard-wraps AND right-pads its lines to the exact width
# it rendered at, so after a zoom/resize the pane kept a stale-width frame on screen and every padded
# line re-wrapped into a double-spaced stray-char mess — the repaint that would have fixed it never
# fired, because the content hash had not changed.
#
# Driving a real resize needs a controlling tty and a SIGWINCH — but the suite runs INSIDE a live pane
# where reading its /dev/tty wedges the gate. So this test never touches the real terminal: it points
# the viewer's tty at /dev/null (BACKLOG_VIEW_TTY, which is not a tty → the no-tty code path), injects
# keypresses through the BACKLOG_VIEW_KEY_CMD hook, and drives the WIDTH through the
# BACKLOG_VIEW_COLS_CMD hook (the one seam where the viewer reads `tput cols`). Everything runs
# FOREGROUND with a fixed poll; no pty, no backgrounding, no SIGWINCH, no timing races.
#
# The FAKE `herd` emits a FIXED list, so backlog content never changes between polls — which makes the
# assertions unambiguous: a repaint of unchanged content can happen ONLY because the width changed.
# A STUB `glow` logs the args it was handed, so the width actually passed to the renderer is asserted
# directly rather than inferred from the paint.
#
# Coverage:
#   1. resize      — a width change ALONE repaints unchanged content (2 headers), and the second
#                    render is handed the NEW width.
#   2. steady      — a constant width does NOT repaint unchanged content (1 header) — the latch still
#                    suppresses idle repaints, i.e. no scroll-yank regression while reading.
#   3. width math  — the renderer gets `cols - 2` (the viewer's historical margin).
#   4. clamp       — an absurdly narrow pane clamps to a floor instead of handing glow a 0/negative
#                    width (which fails outright, blanking the pane rather than narrowing it).
#
# Run:  bash tests/test-backlog-view-resize.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-view.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

BIN="$T/bin"; mkdir -p "$BIN"
GLOW_LOG="$T/glow.log"

# Resolve python3 pre-`env -i` and shim it (HERD-53 portability: on Git Bash python3 lives off the
# fixed PATH, and backlog-view.sh's rich_to_md calls a bare `python3`). No-op on Linux/macOS.
PY="$(command -v python3 || true)"
[ -n "$PY" ] && { printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$PY" > "$BIN/python3"; chmod +x "$BIN/python3"; }

# FAKE `herd` — for `backlog` prints a FIXED list (content is constant across polls).
cat > "$BIN/herd" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "backlog" ] || exit 0
printf '%s\n' "#RS-1 resize item"
FAKE
chmod +x "$BIN/herd"

# STUB `glow` — records the args of every invocation (one line per render) and prints the file, so the
# render succeeds and latches. Shadows any real glow on PATH: this test asserts the WIDTH ARGUMENT,
# not glow's own wrapping (that is test-backlog-view-width.sh's job), so it must not depend on glow
# being installed at all.
cat > "$BIN/glow" <<'GLOW'
#!/usr/bin/env bash
echo "glow $*" >> "$GLOW_STUB_LOG"
# The document to render is glow's LAST argument (the style file is an argument too — don't cat it).
for last in "$@"; do :; done
[ -n "${last:-}" ] && [ -f "$last" ] && cat "$last"
exit 0
GLOW
chmod +x "$BIN/glow"

# cols hook — prints the width for tick N from a counter file, taking values off $COLS_SEQ (a
# space-separated list); the LAST value repeats once the sequence is exhausted. The viewer reads the
# width once per tick, so the sequence indexes ticks directly.
cat > "$BIN/cols-seq" <<'EOF'
#!/usr/bin/env bash
c="${COLS_COUNTER:?}"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
set -- $COLS_SEQ
[ "$n" -gt "$#" ] && n="$#"
eval "printf '%s' \"\${$n}\""
EOF

# key hook — never presses a key; waits out the interval and times out (rc>128), exactly as the real
# tty read does when the user is idle. This keeps the resize path the ONLY repaint trigger.
cat > "$BIN/key-idle" <<'EOF'
#!/usr/bin/env bash
sleep "${1:-0}"; exit 142
EOF
chmod +x "$BIN/cols-seq" "$BIN/key-idle"

# Project with a non-file (linear) backend so the backend-poll loop runs.
P="$T/proj"; mkdir -p "$P/.herd"
cat > "$P/.herd/config" <<EOF
PROJECT_ROOT="$P"
WORKSPACE_NAME="testws"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="linear"
EOF

# run_view <cols-sequence> [extra env ...] — run the viewer against $P with the fakes on PATH, the tty
# pointed at /dev/null (never the real terminal), and the console cwd-guard bypassed. Prints stdout.
run_view() {
  local seq="$1"; shift
  : > "$GLOW_LOG"; : > "$T/cc"
  env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm \
    HERD_CONFIG_FILE="$P/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 \
    GLOW_STUB_LOG="$GLOW_LOG" COLS_SEQ="$seq" COLS_COUNTER="$T/cc" \
    BACKLOG_VIEW_TTY=/dev/null BACKLOG_VIEW_COLS_CMD="$BIN/cols-seq" \
    BACKLOG_VIEW_KEY_CMD="$BIN/key-idle" BACKLOG_VIEW_MAX_POLLS=2 BACKLOG_VIEW_POLL_SECS=1 \
    "$@" bash "$SCRIPT" 2>/dev/null </dev/null
}
headers(){ grep -c 'live ·' <<<"$1" || true; }
# widths — the -w value glow was handed, one per render, in order.
widths(){ sed -n 's/.* -w \([0-9-]*\).*/\1/p' "$GLOW_LOG" | tr '\n' ' '; }

# ── Case 1: a width change ALONE repaints unchanged content ──────────────────────────────────────
out1="$(run_view "100 60")"
grep -q "resize item" <<<"$out1" || fail "resize: backlog list never rendered"
h1="$(headers "$out1")"
[ "$h1" -eq 2 ] || fail "resize: a width change did not repaint unchanged content (expected 2 headers, got $h1):
$out1"
w1="$(widths)"
[ "$w1" = "98 58 " ] || fail "resize: renders must use each tick's own width (expected '98 58 ', got '$w1')"
pass

# ── Case 2: a CONSTANT width does not repaint unchanged content (idle latch intact) ───────────────
out2="$(run_view "100 100")"
grep -q "resize item" <<<"$out2" || fail "steady: backlog list never rendered"
h2="$(headers "$out2")"
[ "$h2" -eq 1 ] || fail "steady: unchanged content at a constant width must not repaint (expected 1 header, got $h2):
$out2"
pass

# ── Case 3: the render width is cols - 2 (the viewer's historical margin) ─────────────────────────
run_view "80 80" >/dev/null
w3="$(widths)"
[ "$w3" = "78 " ] || fail "width-math: expected a single render at 78 (80 cols - 2 margin), got '$w3'"
pass

# ── Case 4: an absurdly narrow pane clamps instead of handing glow a 0/negative width ─────────────
# cols=1 would compute w=-1; `glow -w -1` fails, so the pane would go BLANK rather than narrow.
run_view "1 1" >/dev/null
w4="$(widths)"
[ -n "$w4" ] || fail "clamp: no render happened at cols=1"
for got in $w4; do
  [ "$got" -ge 20 ] || fail "clamp: cols=1 handed glow -w $got (must clamp to a sane floor, >= 20)"
done
pass

# ── Case 5: the width actually comes from the PANE, not from terminfo's default ───────────────────
# Cases 1-4 drive the width through BACKLOG_VIEW_COLS_CMD, so they cannot see how the width is read
# when that seam is OFF — and that read is the deeper half of HERD-288. The historical
# `w=$(( $(tput cols 2>/dev/null || echo 100) - 2 ))` runs tput inside a command substitution, where
# stdout is a pipe; ncurses then falls back to STDERR to find a terminal, which `2>/dev/null` had
# also closed off, so it silently answered terminfo's default 80. The pane rendered at a FIXED 78
# columns at every zoom level. A unit with a stubbed width source can never catch that — it needs a
# real terminal of a KNOWN width.
#
# So: fork a private pty of a known size and run ONE poll (BACKLOG_VIEW_MAX_POLLS=1) inside it. The
# viewer never touches the SUITE's terminal — pty.fork gives the child its own session and its own
# controlling tty — and MAX_POLLS=1 means it renders once and exits, so nothing is backgrounded and
# no key is ever read. The driver additionally holds a hard deadline and reaps the child either way.
# SKIP-SOFT when python3 is unavailable: this is a deepening guard, never a false red.
if [ -z "$PY" ]; then
  echo "SKIP: python3 not installed — pane-width (pty) guard not run"
else
  : > "$GLOW_LOG"; : > "$T/cc"
  pty_w="$(
    PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    HERD_CONFIG_FILE="$P/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 \
    GLOW_STUB_LOG="$GLOW_LOG" VIEW_SCRIPT="$SCRIPT" \
    "$PY" -c '
import os, pty, select, struct, time, sys, fcntl, termios
COLS = 133          # a width that is neither terminfo default 80 nor any clamp floor
env = dict(os.environ); env["TERM"] = "xterm"; env["BACKLOG_VIEW_MAX_POLLS"] = "1"
env["BACKLOG_VIEW_POLL_SECS"] = "1"
pid, fd = pty.fork()
if pid == 0:
    os.execve("/bin/sh", ["/bin/sh", "-c", "exec bash \"$VIEW_SCRIPT\""], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, COLS, 0, 0))
deadline = time.time() + 20
while time.time() < deadline:
    if os.waitpid(pid, os.WNOHANG)[0]:
        break
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            if not os.read(fd, 8192): break
        except OSError: break
else:
    os.kill(pid, 9); os.waitpid(pid, 0); sys.exit("timeout")
try: os.close(fd)
except OSError: pass
print(COLS)
' 2>/dev/null
  )" || pty_w=""
  if [ -z "$pty_w" ]; then
    echo "SKIP: could not allocate a pty — pane-width guard not run"
  else
    w5="$(widths)"
    [ -n "$w5" ] || fail "pane-width: the viewer never rendered inside the pty"
    want=$(( pty_w - 2 ))
    for got in $w5; do
      [ "$got" = "$want" ] || fail "pane-width: in a ${pty_w}-column pane the renderer was handed -w $got (want $want).
The width is not being read from the pane — \`tput cols\` inside \$( ) with stderr closed answers
terminfo's default 80, giving a fixed w=78 at every zoom level (HERD-288)."
    done
    pass
  fi
fi

echo "ALL PASS ($PASS checks)"
