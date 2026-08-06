#!/usr/bin/env bash
# test-health-pane-view.sh — hermetic behavioral tests for scripts/herd/health-pane-view.sh (HERD-568
# addendum): the sidecar-aware view command execed directly as the disposable health·<slug> pane.
#   (1) SIDECAR-LIVE: while the inflight marker exists, per-test lines written to "<log>.progress"
#       appear in the pane's output AS THEY ARE WRITTEN — the addendum's core requirement (the operator
#       observed a live suite whose pane showed nothing because it tailed a log that stays 0 bytes
#       until the very end).
#   (2) FINAL VERDICT: once the marker is gone, the script stops following the sidecar, prints a
#       separator, and shows the final <log> content — then keeps the pane open on it (never exits to a
#       bare prompt).
#   (3) NO-SIDECAR FALLBACK: an engine that never writes a "<log>.progress" companion (the bash worker's
#       own convention, where <log> itself grows live) is followed directly — byte-identical live view.
#   (4) NO-MARKER-ARG FALLBACK: an older caller that never hands a 2nd arg still settles once <log>
#       becomes non-empty (best-effort, no marker to key off).
#   (5) CLEARS ON START: the very first bytes written are a clear-screen escape, so a stale shell
#       greeting never lingers visibly under the live view.
#
# Run:  bash tests/test-health-pane-view.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/health-pane-view.sh"

pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$SCRIPT" ] || fail "health-pane-view.sh not found at $SCRIPT"
[ -x "$SCRIPT" ] || fail "health-pane-view.sh is not executable"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# run_view <log> [marker] — launch the script detached (never inside a captured command substitution:
# an unredirected backgrounded child would hold the substitution's pipe open forever), poll for its
# output file to gain the expected content, then leave it running for the caller to drive further.
run_view() {
  local log="$1" mark="${2:-}" out="$3"
  : > "$out"
  if [ -n "$mark" ]; then
    nohup bash "$SCRIPT" "$log" "$mark" > "$out" 2>&1 < /dev/null &
  else
    nohup bash "$SCRIPT" "$log" > "$out" 2>&1 < /dev/null &
  fi
  echo $!
}
wait_for() {   # wait_for <file> <needle> <timeout-ticks>
  local f="$1" needle="$2" n="${3:-30}" i=0
  while [ "$i" -lt "$n" ]; do
    grep -qF "$needle" "$f" 2>/dev/null && return 0
    i=$((i+1)); sleep 0.2
  done
  return 1
}

# ── (1) + (2) + (5): sidecar-live, then final verdict, with the clear-screen prefix ────────────────
LOG="$T/log"; MARK="$T/mark"; OUT="$T/out"
: > "$MARK"
VPID="$(run_view "$LOG" "$MARK" "$OUT")"
wait_for "$OUT" $'\033' 15 || fail "(5) no clear-screen escape at the very start of the pane's output"
printf 'test 1/3 ok\n' >> "$LOG.progress"
wait_for "$OUT" "test 1/3 ok" 15 || fail "(1) a sidecar line written mid-run never appeared live"
printf 'test 2/3 ok\n' >> "$LOG.progress"
wait_for "$OUT" "test 2/3 ok" 15 || fail "(1) a second sidecar line never appeared live"
grep -q "suite ended" "$OUT" && fail "(1) the verdict separator appeared BEFORE the suite ended"
rm -f "$MARK"
printf '1..3\nFINAL VERDICT: CLEAN\n' > "$LOG"
wait_for "$OUT" "suite ended" 20 || fail "(2) the final-result separator never appeared once the marker was gone"
wait_for "$OUT" "FINAL VERDICT: CLEAN" 20 || fail "(2) the final <log> verdict was never shown"
kill "$VPID" 2>/dev/null || true
ok; ok; ok

# ── (3) NO-SIDECAR FALLBACK: the bash-worker convention (<log> itself grows live) ──────────────────
LOG2="$T/log2"; MARK2="$T/mark2"; OUT2="$T/out2"
: > "$MARK2"
VPID2="$(run_view "$LOG2" "$MARK2" "$OUT2")"
printf 'growing line A\n' >> "$LOG2"
wait_for "$OUT2" "growing line A" 15 || fail "(3) a line appended directly to <log> (no sidecar ever) never appeared live"
rm -f "$MARK2"
printf 'growing line A\ngrowing line B (verdict)\n' > "$LOG2"
wait_for "$OUT2" "growing line B (verdict)" 20 || fail "(3) the final content on the no-sidecar path never appeared"
kill "$VPID2" 2>/dev/null || true
ok

# ── (4) NO-MARKER-ARG FALLBACK: settles once <log> is non-empty, no 2nd arg given ───────────────────
LOG3="$T/log3"; OUT3="$T/out3"
VPID3="$(run_view "$LOG3" "" "$OUT3")"
printf 'VERDICT ONLY\n' > "$LOG3"
wait_for "$OUT3" "VERDICT ONLY" 20 || fail "(4) no-marker-arg fallback never showed the log once it became non-empty"
kill "$VPID3" 2>/dev/null || true
ok

echo "ALL PASS ($pass checks)"
