#!/usr/bin/env bash
# test-local-suite-slot.sh — hermetic test for HERD-529 leg A: the cross-worktree LOCAL SUITE SLOT
# scripts/herd/healthcheck.sh's run_heavy() takes before invoking $HEALTHCHECK_CMD.
#
# HEALTH_CONCURRENCY (agent-watch.sh) only serializes the WATCHER's own dispatch loop — it is blind to
# a builder running `healthcheck.sh --heavy` locally, ahead of its own PR. Leg A closes that gap with a
# separate cross-worktree slot pool ($WORKTREES_DIR/.local-suite-slot-*), capped by
# LOCAL_SUITE_CONCURRENCY (herd-config.sh, default 2).
#
# Drives the REAL scripts/herd/healthcheck.sh (no git needed — MODE is forced --heavy, which skips the
# git-diff based auto-detection and, with HEALTHCHECK_CMD returning rc=0, never triggers the baseline-
# aware gate's own git calls) against a STUB $HEALTHCHECK_CMD that records overlap. Fully hermetic:
# throwaway temp dirs, no herdr/gh/network. HERD_CONFIG_FILE points at a deliberately absent path (the
# same seam herd-config.sh documents for hermetic tests/sims — see tests/test-baseline-gate.sh), so
# every config key is driven directly through the exported env.
#
# Proves:
#   (1) two concurrent heavy runs with LOCAL_SUITE_CONCURRENCY=1 SERIALIZE — the stub never observes
#       overlap — and the SECOND run prints 'waiting for a local suite slot' (to stderr, live, not
#       buffered inside the captured suite output) while it waits.
#   (2) a stale marker recording a DEAD pid is reclaimed on acquire — a run behind it still completes
#       promptly (bounded by `timeout`) instead of waiting out a slot that will never free itself, and
#       every dead-pid marker in the pool (not just the one occupying the acquired slot number) is
#       swept away.
#   (3) with WORKTREES_DIR unresolved/missing, the suite runs UNSLOTTED — no marker, no wait line,
#       exactly as before this feature existed (fail-soft).
#
# Run:  bash tests/test-local-suite-slot.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HC="$ROOT/scripts/herd/healthcheck.sh"
[ -f "$HC" ] || { echo "FAIL: healthcheck.sh not found at $HC" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); echo "PASS $1"; }

NOCFG="$T/no-such-config"

# The stub project health command: records OVERLAP if another invocation is already mid-run (a shared
# ".busy" file under the pool dir, the stub's own $2 arg), sleeps $STUB_SLEEP, then clears it. A clean
# serialize means no invocation ever observes the OTHER one's busy marker still present.
STUB="$T/hc-stub.sh"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
busy="$2"
[ -f "$busy" ] && { echo overlap >> "${busy}.violations"; }
printf '%s\n' "$$" > "$busy"
sleep "${STUB_SLEEP:-1}"
rm -f "$busy"
exit 0
STUB
chmod +x "$STUB"

mk_pr(){ local d="$T/$1"; mkdir -p "$d"; printf '%s' "$d"; }

# run_hc <pr-dir> <extra env NAME=VAL...> -- background-agnostic helper: sets OUT/ERR/RC file paths via
# globals the caller names, invoked directly (never through this function) so foreground/background
# control stays with the caller.

# ── (1) LOCAL_SUITE_CONCURRENCY=1: two concurrent heavy runs never overlap; the second waits ──────
POOL1="$T/pool1"; mkdir -p "$POOL1"
BUSY="$POOL1/.busy"
PR1="$(mk_pr pr1)"; PR2="$(mk_pr pr2)"

env WORKTREES_DIR="$POOL1" LOCAL_SUITE_CONCURRENCY=1 HEALTHCHECK_CMD="$STUB -- $BUSY" \
    HERD_CONFIG_FILE="$NOCFG" DEFAULT_BRANCH="no-such-ref-for-tests" STUB_SLEEP=1 \
    bash "$HC" "$PR1" --heavy >"$T/out1" 2>"$T/err1" &
BG1=$!
# Give run1 a head start well inside its own slot-acquire so it is holding the slot (and, shortly
# after, mid-sleep in the stub) by the time run2 attempts to acquire.
sleep 0.3
env WORKTREES_DIR="$POOL1" LOCAL_SUITE_CONCURRENCY=1 HEALTHCHECK_CMD="$STUB -- $BUSY" \
    HERD_CONFIG_FILE="$NOCFG" DEFAULT_BRANCH="no-such-ref-for-tests" STUB_SLEEP=1 \
    HERD_LOCAL_SUITE_SLOT_POLL_SECS=0.2 \
    bash "$HC" "$PR2" --heavy >"$T/out2" 2>"$T/err2"
RC2=$?
wait "$BG1"; RC1=$?

[ "$RC1" -eq 0 ] || fail "(1) run1 expected clean exit, got $RC1 — $(cat "$T/out1")"
[ "$RC2" -eq 0 ] || fail "(1) run2 expected clean exit, got $RC2 — $(cat "$T/out2")"
[ -f "${BUSY}.violations" ] && fail "(1) the stub observed OVERLAP — the two heavy runs were NOT serialized"
grep -qF "waiting for a local suite slot" "$T/err2" || fail "(1) run2 (the one that had to wait) never printed the visible waiting line — err2: $(cat "$T/err2")"
grep -qF "waiting for a local suite slot" "$T/err1" && fail "(1) run1 (which should have acquired immediately) unexpectedly printed a waiting line — err1: $(cat "$T/err1")"
ok "(1) LOCAL_SUITE_CONCURRENCY=1 serializes two concurrent heavy runs; the waiter prints the visible line, neither overlaps"

# ── (2) a stale marker from a DEAD pid is reclaimed on acquire ─────────────────────────────────────
POOL2="$T/pool2"; mkdir -p "$POOL2"
# A guaranteed-dead pid: spawn a trivial child, wait for it to exit, then reuse its now-dead pid.
sleep 0.01 & DEADPID=$!
wait "$DEADPID" 2>/dev/null
printf '%s\n%s\n%s\n' "$DEADPID" "" "0" > "$POOL2/.local-suite-slot-1"
printf '%s\n%s\n%s\n' "$DEADPID" "" "0" > "$POOL2/.local-suite-slot-2"

PR3="$(mk_pr pr3)"
env WORKTREES_DIR="$POOL2" LOCAL_SUITE_CONCURRENCY=1 HEALTHCHECK_CMD="$STUB -- $POOL2/.busy3" \
    HERD_CONFIG_FILE="$NOCFG" DEFAULT_BRANCH="no-such-ref-for-tests" STUB_SLEEP=0 \
    timeout 10 bash "$HC" "$PR3" --heavy >"$T/out3" 2>"$T/err3"
RC3=$?
[ "$RC3" -eq 0 ] || fail "(2) expected a prompt clean completion despite the stale slot-1 marker (dead pid), got $RC3 (124=timed out waiting) — out: $(cat "$T/out3") err: $(cat "$T/err3")"
[ -e "$POOL2/.local-suite-slot-2" ] && fail "(2) the OTHER dead-pid marker (slot-2, never even acquired) should have been swept by the reclaim-on-acquire sweep too"
ok "(2) a stale marker from a dead pid is reclaimed on acquire (both the acquired slot and every other dead marker in the pool)"

# ── (3) no resolvable pool dir → runs UNSLOTTED, fail-soft, no wait line ───────────────────────────
PR4="$(mk_pr pr4)"
env WORKTREES_DIR="$T/no-such-pool-dir" LOCAL_SUITE_CONCURRENCY=1 HEALTHCHECK_CMD="$STUB -- $T/busy4" \
    HERD_CONFIG_FILE="$NOCFG" DEFAULT_BRANCH="no-such-ref-for-tests" STUB_SLEEP=0 \
    bash "$HC" "$PR4" --heavy >"$T/out4" 2>"$T/err4"
RC4=$?
[ "$RC4" -eq 0 ] || fail "(3) expected clean exit with an unresolvable pool dir, got $RC4 — $(cat "$T/out4")"
[ -s "$T/err4" ] && grep -qF "waiting for a local suite slot" "$T/err4" && fail "(3) must never print a waiting line when the pool dir is unresolvable — err4: $(cat "$T/err4")"
ok "(3) an unresolvable WORKTREES_DIR runs the heavy suite unslotted (fail-soft, byte-identical to before this feature)"

echo
echo "ALL PASS ($PASS checks) — HERD-529 leg A: the cross-worktree local-suite slot serializes concurrent builder-local heavy runs under LOCAL_SUITE_CONCURRENCY, prints a visible waiting line, self-heals a stale dead-pid marker, and fails soft to unslotted when the pool dir is unresolvable."
