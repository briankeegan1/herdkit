#!/usr/bin/env bash
# test-backlog-view-backend.sh — hermetic, network-free test of backlog-view.sh's backend-awareness.
#
# backlog-view.sh renders the coordinator's left pane. Historically it always rendered $BACKLOG_FILE
# with glow. When .herd/config sets SCRIBE_BACKEND to a non-file backend (github/linear) that file is
# a frozen archive, not the live queue — so the viewer must instead poll `herd backlog` and render
# the live open list. This test stubs `herd` with a FAKE bin on PATH (no network, no real backend)
# and drives the script through the BACKLOG_VIEW_MAX_POLLS test hook so each scenario is deterministic.
#
# Coverage:
#   1. file-mode unchanged  — SCRIBE_BACKEND=file still renders $BACKLOG_FILE and NEVER calls `herd`.
#   2. linear-mode renders  — SCRIBE_BACKEND=linear renders the styled header + `herd backlog` list.
#   3. change-detection     — re-renders only when the list content changes (hashed), not every poll.
#   4. unreachable/last-good — a failing or empty `herd backlog` keeps the last good list on screen,
#                              appends the dim warning, never blanks/reds, and leaks no secret/body.
#
# Run:  bash tests/test-backlog-view-backend.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-view.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

BIN="$T/bin"; mkdir -p "$BIN"
LOG="$T/herd.log"

# FAKE `herd` — logs every call; for `backlog` emits scripted output. Two modes:
#   • HERD_FAKE_OUT (static)  — print it and exit 0.
#   • HERD_FAKE_SEQDIR (seq)  — a per-call counter picks $SEQDIR/<n>; its content is printed, unless
#       it is the sentinel __FAIL__ (emit a fake API error to STDERR incl. a secret + exit 1) or
#       __EMPTY__ (exit 0 with no output). Steps past the last defined one clamp to the last file.
cat > "$BIN/herd" <<'FAKE'
#!/usr/bin/env bash
echo "herd $*" >> "$HERD_FAKE_LOG"
[ "${1:-}" = "backlog" ] || exit 0
if [ -n "${HERD_FAKE_SEQDIR:-}" ]; then
  n=$(cat "$HERD_FAKE_COUNTER" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$HERD_FAKE_COUNTER"
  while [ "$n" -gt 1 ] && [ ! -f "$HERD_FAKE_SEQDIR/$n" ]; do n=$((n-1)); done
  content="$(cat "$HERD_FAKE_SEQDIR/$n" 2>/dev/null || true)"
  case "$content" in
    __FAIL__)  echo "API error: Authorization: Bearer sk-LEAKED-SECRET-TOKEN" >&2; exit 1 ;;
    __EMPTY__) exit 0 ;;
    *)         printf '%s\n' "$content" ;;
  esac
else
  printf '%s\n' "${HERD_FAKE_OUT:-}"
fi
FAKE
chmod +x "$BIN/herd"

# make_project <dir> <backend> — a temp project with a .herd/config the loader can source.
make_project() {
  local dir="$1" backend="$2"
  mkdir -p "$dir/.herd"
  cat > "$dir/.herd/config" <<EOF
PROJECT_ROOT="$dir"
WORKSPACE_NAME="testws"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="$backend"
EOF
}

# run_view <project-dir> [extra env KEY=VAL ...] — run backlog-view.sh against <project-dir> with the
# fake `herd` on PATH. HERD_ALLOW_FOREIGN_CWD bypasses the console cwd-guard; TERM lets `clear` work.
# Prints the captured STDOUT (stderr is discarded — the pane's stderr is never asserted on).
run_view() {
  local dir="$1"; shift
  env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm \
    HERD_CONFIG_FILE="$dir/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 \
    HERD_FAKE_LOG="$LOG" BACKLOG_VIEW_TTY=/dev/null "$@" \
    bash "$SCRIPT" 2>/dev/null </dev/null
}

# ── Case 1: file backend — renders $BACKLOG_FILE, NEVER calls `herd backlog` ─────────────────────
P1="$T/proj-file"; make_project "$P1" "file"
git -C "$P1" init -q; git -C "$P1" config user.email t@t.t; git -C "$P1" config user.name t
cat > "$P1/BACKLOG.md" <<'EOF'
# proj — backlog
## Now
- 🔜 file-mode-sentinel-item
EOF
git -C "$P1" add -A; git -C "$P1" commit -q -m init
: > "$LOG"
# The file loop has no MAX_POLLS hook — run it briefly, then stop. BACKLOG_VIEW_TTY=/dev/null keeps it
# hermetic: the backgrounded viewer must NEVER read the pane's real /dev/tty (the suite runs inside a
# live pane, where a backgrounded read wedges the gate) — it falls back to the plain sleep instead.
env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm \
  HERD_CONFIG_FILE="$P1/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 HERD_FAKE_LOG="$LOG" \
  BACKLOG_VIEW_TTY=/dev/null bash "$SCRIPT" </dev/null >"$T/out1" 2>/dev/null & vpid=$!
sleep 1; kill "$vpid" 2>/dev/null; wait "$vpid" 2>/dev/null
grep -q "📋 BACKLOG.md" "$T/out1"          || fail "file-mode header '📋 BACKLOG.md' missing"
grep -q "file-mode-sentinel-item" "$T/out1" || fail "file-mode did not render the backlog file content"
if [ -s "$LOG" ]; then fail "file-mode must NOT invoke 'herd backlog' (log: $(cat "$LOG"))"; fi
pass

# ── Case 2: linear backend — styled header + `herd backlog` open list ────────────────────────────
P2="$T/proj-linear"; make_project "$P2" "linear"
: > "$LOG"
out2="$(run_view "$P2" BACKLOG_VIEW_MAX_POLLS=1 BACKLOG_VIEW_POLL_SECS=0 \
        HERD_FAKE_OUT="#ABC-1 alpha ticket")"
grep -q "testws" <<<"$out2"        || fail "linear-mode header missing workspace name ($out2)"
grep -q "linear" <<<"$out2"        || fail "linear-mode header missing backend name"
grep -q "live"   <<<"$out2"        || fail "linear-mode header missing 'live' marker"
grep -q "alpha ticket" <<<"$out2"  || fail "linear-mode did not render the 'herd backlog' open list"
grep -q "herd backlog" "$LOG"      || fail "linear-mode did not invoke 'herd backlog'"
pass

# ── Case 3: change-detection — re-render only when the list content actually changes ─────────────
# 3 polls: step1=listA, step2=listA (unchanged → no repaint), step3=listB (changed → repaint).
# Each repaint prints exactly one header line (contains 'live ·'); so an unchanged poll must NOT add
# a header. Expect exactly 2 headers across the 3 polls.
P3="$T/proj-cd"; make_project "$P3" "linear"
SEQ="$T/seq"; mkdir -p "$SEQ"
printf '#A-1 alpha-item\n' > "$SEQ/1"
printf '#A-1 alpha-item\n' > "$SEQ/2"   # identical to step 1
printf '#B-2 beta-item\n'  > "$SEQ/3"
: > "$LOG"; : > "$T/cd.counter"
out3="$(run_view "$P3" BACKLOG_VIEW_MAX_POLLS=3 BACKLOG_VIEW_POLL_SECS=0 \
        HERD_FAKE_SEQDIR="$SEQ" HERD_FAKE_COUNTER="$T/cd.counter")"
headers=$(grep -c 'live ·' <<<"$out3")
[ "$headers" -eq 2 ] || fail "expected 2 re-renders (change-detection), got $headers header(s):
$out3"
grep -q "alpha-item" <<<"$out3" || fail "change-detection: first list version missing"
grep -q "beta-item"  <<<"$out3" || fail "change-detection: changed list version missing"
pass

# ── Case 4: unreachable — keep last good, append warning, blank/red never, no secret leak ────────
# step1=good list, step2=__FAIL__ (API error to stderr + exit 1), step3=__FAIL__ (still down).
P4="$T/proj-down"; make_project "$P4" "linear"
SEQ4="$T/seq4"; mkdir -p "$SEQ4"
printf '#G-1 good-queue-item\n' > "$SEQ4/1"
printf '__FAIL__\n'             > "$SEQ4/2"
printf '__FAIL__\n'             > "$SEQ4/3"
: > "$LOG"; : > "$T/down.counter"
out4="$(run_view "$P4" BACKLOG_VIEW_MAX_POLLS=3 BACKLOG_VIEW_POLL_SECS=0 \
        HERD_FAKE_SEQDIR="$SEQ4" HERD_FAKE_COUNTER="$T/down.counter")"
grep -q "good-queue-item" <<<"$out4"            || fail "unreachable: last good list was blanked (never keep!)"
grep -q "backend unreachable since" <<<"$out4"  || fail "unreachable: missing last-good warning line"
grep -q "sk-LEAKED-SECRET-TOKEN" <<<"$out4"     && fail "SECRET LEAK: raw API error body reached the pane"
grep -q "API error" <<<"$out4"                  && fail "unreachable: raw error body must be sanitized, not shown"
# The warning is stamped once (degraded frame is stable) — steps 2 and 3 must not repaint twice.
warns=$(grep -c "backend unreachable since" <<<"$out4")
[ "$warns" -eq 1 ] || fail "expected the unreachable warning exactly once, got $warns"
pass

# ── Case 5: empty result is also treated as degraded (keep last good) ─────────────────────────────
# An API/network hiccup can surface as an empty (exit 0) list; that must NOT blank the pane either.
P5="$T/proj-empty"; make_project "$P5" "linear"
SEQ5="$T/seq5"; mkdir -p "$SEQ5"
printf '#H-1 held-item\n' > "$SEQ5/1"
printf '__EMPTY__\n'      > "$SEQ5/2"
: > "$LOG"; : > "$T/empty.counter"
out5="$(run_view "$P5" BACKLOG_VIEW_MAX_POLLS=2 BACKLOG_VIEW_POLL_SECS=0 \
        HERD_FAKE_SEQDIR="$SEQ5" HERD_FAKE_COUNTER="$T/empty.counter")"
grep -q "held-item" <<<"$out5"                 || fail "empty-result: last good list was blanked"
grep -q "backend unreachable since" <<<"$out5" || fail "empty-result: missing last-good warning line"
pass

echo "ALL PASS ($PASS checks)"
