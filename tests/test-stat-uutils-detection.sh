#!/usr/bin/env bash
# test-stat-uutils-detection.sh — unit test for the stat helper detection in agent-watch.sh,
# covering both GNU and uutils implementations. Tests that the regex correctly identifies
# both GNU and uutils stat, and that the selected functions return numeric values.
#
# Asserts:
#   • GNU stat detection (original behavior)
#   • uutils stat detection (new, HERD-198)
#   • file_mtime returns a numeric epoch (not a BSD date string or error)
#   • _file_size returns a numeric byte count (not a BSD inode string or error)
#   • HERD-416/GH-222: with a FAKE uutils `stat` on PATH (refusing any '-f' arg), both file_mtime
#     and _file_size pick the '-c' branch and parse the stubbed numeric output — proven against a
#     stubbed binary, not just the regex string or this host's own (BSD, on macOS) stat.
#
# Run:  bash tests/test-stat-uutils-detection.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v stat >/dev/null 2>&1 || fail "stat required"

# Test file
TEST_FILE="$T/testfile.txt"
echo "test content here" > "$TEST_FILE"

# ── Test 1: GNU stat detection regex ──
# Verify the regex matches GNU
gnu_version="stat (GNU coreutils) 9.1"
if echo "$gnu_version" | grep -qE "GNU|uutils"; then
  ok
else
  fail "GNU regex should match 'GNU coreutils'"
fi

# ── Test 2: uutils stat detection regex ──
# Verify the regex matches uutils
uutils_version="stat (uutils) 0.0.18"
if echo "$uutils_version" | grep -qE "GNU|uutils"; then
  ok
else
  fail "uutils regex should match 'uutils'"
fi

# ── Test 3: file_mtime and _file_size work with current system stat ──
# Source the helpers WITHOUT the live loop
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export HERD_TRANSCRIPT_ROOT="$T/transcripts"

# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh failed"

# Verify file_mtime returns numeric
mtime_result="$(file_mtime "$TEST_FILE")"
[ -z "$mtime_result" ] && fail "file_mtime returned empty"
[[ "$mtime_result" =~ ^[0-9]+$ ]] || fail "file_mtime not numeric: $mtime_result"
ok

# Verify _file_size returns numeric
size_result="$(_file_size "$TEST_FILE")"
[ -z "$size_result" ] && fail "_file_size returned empty"
[[ "$size_result" =~ ^[0-9]+$ ]] || fail "_file_size not numeric: $size_result"
ok

# ── Test 4: Verify that the detection uses the new regex ──
# Extract the detection logic from agent-watch.sh and verify it uses the updated regex
grep -q 'grep -qE "GNU|uutils"' "$WATCH" || fail "agent-watch.sh should use the updated regex 'grep -qE \"GNU|uutils\"'"
ok

# ── Test 5: Tree-wide regression — no bare 'grep -q GNU' stat detection ──
# Fail if any file in scripts/ or bin/ still uses the old bare-GNU idiom instead
# of the uutils-aware 'grep -qE "GNU|uutils"' form.
REPO_ROOT="$HERE/.."
offenders="$(grep -rl 'stat --version' "$REPO_ROOT/scripts" "$REPO_ROOT/bin" 2>/dev/null \
  | xargs grep -l 'grep -q GNU' 2>/dev/null || true)"
if [ -n "$offenders" ]; then
  echo "FAIL: tree-wide stat-flavor check — found bare 'grep -q GNU' in:" >&2
  echo "$offenders" >&2
  exit 1
fi
ok

# ── Test 6: file_mtime / _file_size against a FAKE uutils stat on PATH ──
# Test 3 only proves the helpers work against THIS host's own stat (BSD, on macOS) — it can't catch
# a uutils system taking the wrong branch. Stub a `stat` that reports uutils and hard-fails (logging
# BSD_F_INVOKED) on any '-f' arg, mirroring test-worktree-born-stat.sh's harness, and source
# agent-watch.sh fresh in a subshell so the top-level detection re-runs against the fake binary.
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
    %Y) echo 1700000042 ;;
    %s) echo 777 ;;
    *)  echo 0 ;;
  esac
  exit 0
fi
echo 0
FAKE
chmod +x "$FAKEBIN/stat"

LOG6="$T/log6"; : > "$LOG6"
fake_result="$(
  STAT_CALL_LOG="$LOG6" AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$T/no-such-config" \
  HERD_TRANSCRIPT_ROOT="$T/transcripts" PATH="$FAKEBIN:$PATH" bash -c '
    set -uo pipefail
    . "'"$WATCH"'" || { echo SOURCE_FAIL; exit 3; }
    printf "%s %s\n" "$(file_mtime "'"$TEST_FILE"'")" "$(_file_size "'"$TEST_FILE"'")"
  '
)"
[ "$fake_result" = "1700000042 777" ] || fail "expected '1700000042 777' from the uutils stub, got '$fake_result'"
ok

grep -q 'BSD_F_INVOKED' "$LOG6" && fail "file_mtime/_file_size invoked 'stat -f' against a uutils stat"
ok

grep -q 'stat -c %Y' "$LOG6" || fail "file_mtime did not query the uutils stub with 'stat -c %Y'"
grep -q 'stat -c %s' "$LOG6" || fail "_file_size did not query the uutils stub with 'stat -c %s'"
ok

echo "PASS test-stat-uutils-detection.sh ($pass checks)"
