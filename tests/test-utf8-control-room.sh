#!/usr/bin/env bash
# test-utf8-control-room.sh — hermetic tests for issue #31 (Windows cp1252 UnicodeEncodeError).
#
# Verifies:
#   (a) herd-config.sh exports PYTHONUTF8=1 and PYTHONIOENCODING=utf-8 for all python3 subcalls.
#   (b) Even when PYTHONIOENCODING=ascii is pre-set, sourcing herd-config.sh overrides it so
#       python3 -c "print('═')" works without a UnicodeEncodeError.
#   (c) coordinator.sh with a failing `herdr workspace list` prints a named "ERROR [workspace
#       resolve]:" message to stderr (no more silent truncation).
#
# Run:  bash tests/test-utf8-control-room.sh
# No `set -e`: some checks invoke coordinator.sh expecting a non-zero exit; assert RC explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOADER="$HERE/../scripts/herd/herd-config.sh"
COORD="$HERE/../scripts/herd/coordinator.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$LOADER" ] || fail "herd-config.sh not found at $LOADER"
[ -f "$COORD"  ] || fail "coordinator.sh not found at $COORD"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# Standard system dirs to shadow brew/local tools — keeps the test hermetic by not pulling in
# an accidentally installed real herdr.
SYS="/usr/bin:/bin:/usr/sbin:/sbin"
case ":$SYS:" in *":$(dirname "$(command -v python3)"):"*) ;; *) SYS="$(dirname "$(command -v python3)"):$SYS";; esac

# Source loader in a subshell from a temp dir with no .herd/config on the walk-up path.
source_config() {
  ( cd "$T" && HERD_CONFIG_FILE="$T/.nonexistent" bash -c ". '$LOADER'; $1" )
}

# ── (a) PYTHONUTF8 and PYTHONIOENCODING exported by herd-config.sh ───────────
out=$(source_config 'printf "PYTHONUTF8=%s\n" "${PYTHONUTF8:-UNSET}"
printf "PYTHONIOENCODING=%s\n" "${PYTHONIOENCODING:-UNSET}"')

printf '%s' "$out" | grep -qx "PYTHONUTF8=1" \
  || fail "(a) PYTHONUTF8=1 not exported by herd-config.sh (got: $out)"
ok

printf '%s' "$out" | grep -qx "PYTHONIOENCODING=utf-8" \
  || fail "(a) PYTHONIOENCODING=utf-8 not exported by herd-config.sh (got: $out)"
ok

# ── (b) python3 can print non-ASCII after herd-config.sh even if caller set ascii ───────────
# Simulate a Windows-like environment where PYTHONIOENCODING=ascii is inherited from the shell.
# herd-config.sh must override it to utf-8 before any python3 -c runs.
result=$(cd "$T" && HERD_CONFIG_FILE="$T/.nonexistent" PYTHONIOENCODING=ascii bash -c \
  ". '$LOADER'; python3 -c \"print(chr(0x2550))\"" 2>&1)
# chr(0x2550) = '═' (U+2550, BOX DRAWINGS DOUBLE HORIZONTAL) — the exact char from issue #31.
printf '%s' "$result" | grep -qF "═" \
  || fail "(b) python3 cannot print non-ASCII (═) after sourcing config with pre-set ascii encoding (got: $result)"
ok

# ── (c) coordinator.sh prints a named error when a layout step fails ──────────
# Stub herdr: returns valid JSON for `tab list` (passes preflight if run) but exits non-zero on
# `workspace list`, printing "connection refused" to stderr — the cp1252 failure shape.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" << 'STUB'
#!/usr/bin/env bash
# Minimal stub for coordinator.sh loud-error test.
case "$1 $2" in
  "tab list")
    printf '{"result":{"tabs":[]}}\n'
    exit 0
    ;;
  "workspace list")
    printf 'herdr: connection refused\n' >&2
    exit 1
    ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"

# Run coordinator.sh under controlled PATH (stub herdr only). Skip the preflight to focus the test
# on the layout-step error handling (preflight already has its own test in test-preflight.sh).
# Capture combined stdout+stderr so we can assert on the ERROR message.
# HERD_ALLOW_FOREIGN_CWD=1: focus this test on the workspace-resolve error path, bypassing the
# issue #60 launch-binding cwd guard (this test runs from a $T cwd with a nonexistent config).
coord_out=$(HERD_ALLOW_FOREIGN_CWD=1 HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$T/.nonexistent" \
  PATH="$BIN:$SYS" bash "$COORD" 2>&1); coord_rc=$?

[ "$coord_rc" -ne 0 ] \
  || fail "(c) coordinator.sh should exit non-zero when workspace list fails (got exit 0)"
ok

printf '%s' "$coord_out" | grep -q "ERROR \[workspace resolve\]" \
  || fail "(c) coordinator.sh did not print 'ERROR [workspace resolve]' (got: $coord_out)"
ok

printf '%s' "$coord_out" | grep -q "connection refused" \
  || fail "(c) coordinator.sh did not surface the underlying error (got: $coord_out)"
ok

echo "ALL PASS ($pass)"
