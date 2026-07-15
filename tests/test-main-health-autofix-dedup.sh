#!/usr/bin/env bash
# test-main-health-autofix-dedup.sh — HERD-371: the MAIN RED autofix filing leg's dedup marker is a
# SHARED-POOL invariant (pysrc/herd/store.py main_health_fix_*), atomic across concurrent seats — not a
# bare per-process flat file. Before this fix, HERD-362 and HERD-365 were filed for the SAME failing test
# (test-herd-config.sh MAIN RED) because each seat's dedup only ever consulted its OWN local
# read-then-write flat file: a race window between two seats' cat/printf let both pass the "not already
# filed" check before either wrote.
#
# Asserted here directly against the store CLI both bash legs (scripts/herd/agent-watch.sh
# _main_health_fix_mark) shell into: N CONCURRENT claims for the SAME failing-test identity resolve to
# EXACTLY ONE winner (rc 0, "file it") and N-1 dedups (rc 3, "already filed") — on both backends (flat
# and sqlite) — proving the claim-or-abort is genuinely atomic, not merely usually-fast-enough. A
# DIFFERENT identity is never blocked by another identity's marker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PYSRC="$ROOT/pysrc"

fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ printf 'ok — %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$PYSRC/herd/store.py" ] || fail "pysrc/herd/store.py not found"

# race <backend> <n> — spawn <n> CONCURRENT claims for the SAME identity against a fresh pool, and assert
# exactly one won (rc 0) while every other claim deduped (rc 3).
race() {
  local backend="$1" n="$2" pool rcfile won=0 dedup=0 rc i p
  pool="$(mktemp -d)"; mkdir -p "$pool/.herd"
  rcfile="$(mktemp -d)"
  local pids=()
  for i in $(seq 1 "$n"); do
    (
      PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PYSRC" WORKTREES_DIR="$pool" STORE_BACKEND="$backend" \
        python3 -m herd.store --main-health-fix-mark "test-herd-config.sh MAIN RED" \
          --pr "$((400 + i))" --sha "deadbeef$i" >/dev/null 2>&1
      echo $? > "$rcfile/$i"
    ) &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  for i in $(seq 1 "$n"); do
    rc="$(cat "$rcfile/$i" 2>/dev/null || echo x)"
    case "$rc" in
      0) won=$((won + 1)) ;;
      3) dedup=$((dedup + 1)) ;;
      *) fail "backend=$backend claim #$i returned unexpected rc=$rc (expected 0 or 3)" ;;
    esac
  done
  [ "$won" -eq 1 ] || fail "backend=$backend expected exactly ONE winner, got $won (of $n concurrent claims)"
  [ "$dedup" -eq $((n - 1)) ] || fail "backend=$backend expected $((n - 1)) dedups, got $dedup"
  rm -rf "$pool" "$rcfile"
  ok "backend=$backend: $n concurrent claims for the SAME identity → exactly 1 winner, $((n - 1)) dedups"
}

race flat 12
race sqlite 12

# A DIFFERENT identity is never blocked by another identity's marker.
POOL2="$(mktemp -d)"; mkdir -p "$POOL2/.herd"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PYSRC" WORKTREES_DIR="$POOL2" STORE_BACKEND=flat \
  python3 -m herd.store --main-health-fix-mark "test-a.sh MAIN RED" >/dev/null 2>&1
RC_A=$?
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PYSRC" WORKTREES_DIR="$POOL2" STORE_BACKEND=flat \
  python3 -m herd.store --main-health-fix-mark "test-b.sh MAIN RED" >/dev/null 2>&1
RC_B=$?
[ "$RC_A" -eq 0 ] && [ "$RC_B" -eq 0 ] \
  || fail "two DIFFERENT identities did not both win their own claim (rc_a=$RC_A rc_b=$RC_B)"
rm -rf "$POOL2"
ok "two different identities each win their own claim independently"

# The marker is clearable (main-health goes green for that identity) and re-claimable afterward — a
# LATER regression of the same test must be able to file again.
POOL3="$(mktemp -d)"; mkdir -p "$POOL3/.herd"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PYSRC" WORKTREES_DIR="$POOL3" STORE_BACKEND=flat \
  python3 -m herd.store --main-health-fix-mark "test-herd-config.sh MAIN RED" >/dev/null 2>&1
RC_C=$?
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PYSRC" WORKTREES_DIR="$POOL3" STORE_BACKEND=flat \
  python3 -m herd.store --main-health-fix-clear "test-herd-config.sh MAIN RED" >/dev/null 2>&1
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PYSRC" WORKTREES_DIR="$POOL3" STORE_BACKEND=flat \
  python3 -m herd.store --main-health-fix-mark "test-herd-config.sh MAIN RED" >/dev/null 2>&1
RC_D=$?
rm -rf "$POOL3"
[ "$RC_C" -eq 0 ] && [ "$RC_D" -eq 0 ] \
  || fail "clear did not re-arm the marker for a later regression (rc_c=$RC_C rc_d=$RC_D)"
ok "clearing the marker re-arms it: a later regression of the same test can file again"

echo "ALL PASS"
