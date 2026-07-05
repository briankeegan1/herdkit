#!/usr/bin/env bash
# test-backlog-view-render.sh — hermetic guard that the backend-mode backlog pane renders its list
# through GLAMOUR (markdown), not chroma (source highlighting).
#
# The backend viewer shapes each `herd backlog` item into markdown ("- `#ID` **title**") and hands
# it to glow to paint the pane. glow picks its renderer from the file EXTENSION: a no-suffix temp
# file (the old mktemp) is guessed to be source code and chroma-highlights the RAW markdown — so the
# pane showed literal backticks and '**' asterisks in flat 256-color instead of the tokyonight chip
# + bold title. The fix gives the temp file a .md suffix (glamour renders it) and pins glow's color
# profile. This test asserts the shaped markdown markers do NOT survive into the rendered frame.
#
# Determinism / portability: the source-vs-markdown decision is driven by the file extension, NOT by
# whether stdout is a real terminal, so the regression reproduces in a plain piped capture. That
# matters because the project healthcheck runs each test with stdout redirected to /dev/null (no
# controlling tty), where `script` cannot allocate a pty. So the primary capture is piped (always
# runs); when a pty IS available we ALSO run one poll under `script` (closest to the live pane) and
# assert the same. Skips cleanly (pass) when glow is not installed — nothing to guard without it.
#
# Run:  bash tests/test-backlog-view-render.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-view.sh"

if ! command -v glow >/dev/null 2>&1; then
  echo "SKIP: glow not installed (nothing to guard — the pane falls back to plain text)"; exit 0
fi
GLOW_DIR="$(dirname "$(command -v glow)")"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

BIN="$T/bin"; mkdir -p "$BIN"
# Stub `herd backlog` — emits a fixed two-item open list. The titles carry NO backticks or asterisks
# of their own, so any '`' or '**' in the rendered frame can ONLY be an un-rendered shaping marker.
cat > "$BIN/herd" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "backlog" ] || exit 0
printf '%s\n' "#ABC-1 alpha render item" "#ABC-2 beta render item"
FAKE
chmod +x "$BIN/herd"

# Temp project with a linear-backend config the loader can source.
P="$T/proj"; mkdir -p "$P/.herd"
cat > "$P/.herd/config" <<EOF
PROJECT_ROOT="$P"
WORKSPACE_NAME="testws"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="linear"
EOF

# assert_glamour <capture-file> <label> — the frame must have rendered the item text (glow ran) but
# NONE of the shaped markdown markers ('**' or a literal backtick) — i.e. glamour, not chroma/raw.
assert_glamour() {
  local cap="$1" label="$2"
  grep -q "alpha render item" "$cap" || fail "$label: item text missing — did glow render at all? ($cap)"
  if grep -q '\*\*' "$cap"; then
    fail "$label: literal '**' in the frame — list rendered as raw/chroma source, not glamour"
  fi
  if grep -q '`' "$cap"; then
    fail "$label: literal backtick in the frame — the '#ID' chip was chroma-highlighted, not rendered"
  fi
}

# Shared env for one capped poll. glow's dir is on PATH so the styled branch runs (without it the
# viewer would fall back to plain `cat` and vacuously pass). HERD_ALLOW_FOREIGN_CWD bypasses the
# console cwd-guard; TERM lets `clear` work.
COMMON_ENV=(HOME="$HOME" PATH="$BIN:$GLOW_DIR:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm-256color
            HERD_CONFIG_FILE="$P/.herd/config" HERD_ALLOW_FOREIGN_CWD=1
            BACKLOG_VIEW_MAX_POLLS=1 BACKLOG_VIEW_POLL_SECS=0)

# ── Case 1: piped capture (always runs; the deterministic, tty-free regression guard) ─────────────
cap1="$T/piped.out"
env -i "${COMMON_ENV[@]}" bash "$SCRIPT" >"$cap1" 2>/dev/null </dev/null
assert_glamour "$cap1" "piped"
pass

# ── Case 2: real pty via `script`, best-effort (closest to the live pane) ─────────────────────────
# Only attempt when `script` can actually allocate a pty in this environment — under the healthcheck
# (stdout → /dev/null, no controlling tty) it cannot, so we skip rather than false-fail. macOS/BSD
# `script` is `script -q <file> <cmd...>`; GNU is `script -q -c "<cmd>" <file>`. Probe both.
run_script_pty() {  # $1=outfile ; returns 0 and writes the capture if a pty run succeeded
  local out="$1"
  if script -q "$out" true >/dev/null 2>&1; then           # BSD/macOS form
    env -i "${COMMON_ENV[@]}" script -q "$out" bash "$SCRIPT" >/dev/null 2>&1; return 0
  elif script -q -c true "$out" >/dev/null 2>&1; then        # GNU form
    env -i "${COMMON_ENV[@]}" script -q -c "bash '$SCRIPT'" "$out" >/dev/null 2>&1; return 0
  fi
  return 1
}
cap2="$T/pty.out"
if command -v script >/dev/null 2>&1 && run_script_pty "$cap2" && [ -s "$cap2" ]; then
  assert_glamour "$cap2" "pty(script)"
  pass
else
  echo "note: no pty available (or script absent) — pty sub-case skipped; piped guard still ran"
fi

echo "ALL PASS ($PASS checks)"
