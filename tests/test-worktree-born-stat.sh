#!/usr/bin/env bash
# test-worktree-born-stat.sh — unit test for _worktree_born's stat-flavor discipline in
# agent-watch.sh (HERD-207, regression of HERD-198). Mirrors test-stat-uutils-detection.sh.
#
# The bug: _worktree_born used an inline 'stat -f %B || stat -c %W' chain that tries the BSD
# format flag FIRST. On uutils/GNU stat, '-f' means --file-system (NOT a format string), so
# 'stat -f %B <dir>' does the wrong thing / errors instead of cleanly falling through — a crash.
# The fix routes the birth query through the load-time-detected _stat_birth helper, so a
# GNU/uutils box queries '-c %W' and NEVER invokes 'stat -f'.
#
# Asserts (with a fake `stat` that reports uutils and refuses any '-f' arg):
#   • sourcing selects the GNU/uutils branch → _stat_birth uses 'stat -c %W'
#   • _worktree_born returns the birth epoch WITHOUT ever invoking 'stat -f'
#   • when birth is unsupported (0), _worktree_born falls back to the dir mtime (file_mtime)
#
# Run:  bash tests/test-worktree-born-stat.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# ── A fake `stat` that reports uutils and treats '-f' as the poison BSD path ──
# It records every invocation to $STAT_CALL_LOG and hard-fails (logging BSD_F_INVOKED) if the
# GNU/uutils branch ever passes '-f'. GNU-style '-c FMT FILE' returns a canned numeric value;
# %W (birth) is driven by $FAKE_BIRTH so we can exercise both the supported and 0/unsupported path.
FAKEBIN="$T/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/stat" <<'FAKE'
#!/usr/bin/env bash
echo "stat $*" >> "$STAT_CALL_LOG"
if [ "${1:-}" = "--version" ]; then echo "stat (uutils coreutils) 0.0.27"; exit 0; fi
for a in "$@"; do
  if [ "$a" = "-f" ]; then echo "BSD_F_INVOKED $*" >> "$STAT_CALL_LOG"; exit 1; fi
done
if [ "${1:-}" = "-c" ]; then
  case "$2" in
    %W) echo "${FAKE_BIRTH:-0}" ;;
    %Y) echo "${FAKE_MTIME:-1700000001}" ;;
    %s) echo 42 ;;
    *)  echo 0 ;;
  esac
  exit 0
fi
echo 0
FAKE
chmod +x "$FAKEBIN/stat"

WT="$T/worktree"; mkdir -p "$WT"

run_born() {
  # Source agent-watch.sh as a library with the fake stat on PATH, then echo _worktree_born.
  # STAT_CALL_LOG is fresh per run so we can assert on exactly this call's invocations.
  STAT_CALL_LOG="$1" FAKE_BIRTH="$2" \
  AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$T/no-such-config" HERD_TRANSCRIPT_ROOT="$T/transcripts" \
  PATH="$FAKEBIN:$PATH" bash -c '
    set -uo pipefail
    . "'"$WATCH"'" || { echo "SOURCE_FAIL"; exit 3; }
    _worktree_born "'"$WT"'"
  '
}

# ── Test 1: birth supported — returns the birth epoch, no 'stat -f' ever ──
LOG1="$T/log1"; : > "$LOG1"
born1="$(run_born "$LOG1" 1700000000)"
[ "$born1" = "1700000000" ] || fail "expected birth 1700000000, got '$born1'"
ok
grep -q 'BSD_F_INVOKED' "$LOG1" && fail "_worktree_born invoked 'stat -f' on GNU/uutils"
ok
grep -q 'stat -c %W' "$LOG1" || fail "_worktree_born did not query birth with 'stat -c %W'"
ok

# ── Test 2: birth unsupported (0) — falls back to dir mtime via file_mtime, still no 'stat -f' ──
LOG2="$T/log2"; : > "$LOG2"
born2="$(run_born "$LOG2" 0)"
[ "$born2" = "1700000001" ] || fail "expected mtime fallback 1700000001, got '$born2'"
ok
grep -q 'BSD_F_INVOKED' "$LOG2" && fail "birth-0 fallback invoked 'stat -f' on GNU/uutils"
ok
grep -q 'stat -c %Y' "$LOG2" || fail "birth-0 fallback did not use file_mtime ('stat -c %Y')"
ok

echo "PASS test-worktree-born-stat.sh ($pass checks)"
