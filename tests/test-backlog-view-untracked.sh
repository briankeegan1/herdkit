#!/usr/bin/env bash
# test-backlog-view-untracked.sh — hermetic test for issue #35:
# backlog-view.sh crashes with '[: : integer expression expected' when BACKLOG.md
# has never been committed. Root cause: git log succeeds with empty output for
# untracked files, so the || echo 0 fallback never fires and ts="" breaks
# arithmetic and [ ... -gt 0 ] tests. Fix: ts=${ts:-0} / sub=${sub:-} guards.
# Run:  bash tests/test-backlog-view-untracked.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok()  { pass=$((pass+1)); }

# Build a minimal git repo with an UNTRACKED BACKLOG.md (never committed).
R="$T/repo"
mkdir -p "$R"
git -C "$R" init -q
git -C "$R" config user.email t@t.t
git -C "$R" config user.name t
printf '# sentinel\n' > "$R/README.md"
git -C "$R" add README.md
git -C "$R" commit -q -m init
# Create BACKLOG.md but do NOT git add / commit it.
printf '# Backlog\n## Now\n- 🔜 something to do\n' > "$R/BACKLOG.md"

BACKLOG_FILE="BACKLOG.md"

# ── Case 1: confirm git log returns empty (not "0") for an untracked file ───
# This is the root cause: || echo 0 only fires on non-zero exit, not empty output.
ts_raw=$(git -C "$R" log -1 --format=%ct -- "$BACKLOG_FILE" 2>/dev/null || echo 0)
[ -z "$ts_raw" ] \
  || fail "expected empty ts_raw for untracked file — root-cause precondition not met (got: '$ts_raw')"
ok

# ── Case 2: the fixed loop-body logic runs without error and picks UNCOMMITTED ─
# Reproduces the exact arithmetic + [ ... -gt 0 ] sequence from backlog-view.sh
# with the ts=${ts:-0} and sub=${sub:-} guards applied.
result=$(bash -c '
  set -u
  REPO="$1"; BACKLOG_FILE="$2"
  ts=$(git -C "$REPO" log -1 --format=%ct -- "$BACKLOG_FILE" 2>/dev/null || echo 0)
  ts=${ts:-0}
  sub=$(git -C "$REPO" log -1 --format=%s -- "$BACKLOG_FILE" 2>/dev/null)
  sub=${sub:-}
  now=$(date +%s); age=$(( now - ts ))
  if [ "$ts" -gt 0 ] && [ "$age" -lt 90 ]; then
    printf "JUST_SCRIBED"
  elif [ "$ts" -gt 0 ]; then
    printf "SCRIBED"
  else
    printf "UNCOMMITTED"
  fi
' _ "$R" "$BACKLOG_FILE" 2>&1); rc=$?
[ "$rc" -eq 0 ] \
  || fail "loop body exited non-zero (rc=$rc) for untracked backlog: $result"
[ "$result" = "UNCOMMITTED" ] \
  || fail "expected UNCOMMITTED banner for untracked backlog, got: '$result'"
ok

echo "ALL PASS ($pass checks)"
