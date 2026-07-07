#!/usr/bin/env bash
# test-scribe-linger.sh — hermetic tests for the scribe DRAINER LINGER window (HERD-88). Before this
# work, `scribe-step.sh next` waited only $SCRIBE_POLL seconds for a request and then returned EMPTY,
# so the drainer's session exited the moment the queue drained — a burst of requests arriving with
# idle gaps between them each paid a fresh MODEL_SCRIBE cold-start. The fix adds SCRIBE_LINGER_SECS
# (config, project scope, default 0): after the base poll empties the queue, `next` keeps polling for
# that many extra seconds before returning EMPTY, so one session drains the whole burst.
#
# These are QUEUE-MECHANICS tests — no model, no network, no real backend. They drive scribe-step.sh
# `next` directly against a temp queue and assert the claim/EMPTY decision, proving:
#   1. default (linger 0) is byte-identical: empty queue → EMPTY at the base poll deadline;
#   2. a request enqueued DURING the linger window is CLAIMED by the same `next` call (not EMPTY);
#   3. a burst across an idle gap is drained by ONE session — sequential `next` calls claim BOTH
#      requests with NO intervening EMPTY (an EMPTY is what would have ended the session).
# Run:  bash tests/test-scribe-linger.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STEP="$HERE/../scripts/herd/scribe-step.sh"
BACKENDS="$HERE/../scripts/herd/backends"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── Stub herdr on PATH so no real notification/tab is ever touched ────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── A temp git repo + a .herd/config the step script sources ──────────────────
REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
TREES="$T/trees"; Q="$TREES/backlog-queue"; mkdir -p "$Q"

CFG="$T/config"
cat > "$CFG" <<CFGEOF
HERD_VERSION=1
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="lingertest"
HERD_REMOTE="origin"
HERD_BRANCH_NAME="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
CFGEOF

# next <args...> — run `scribe-step.sh next` from inside $REPO with a given env. SCRIBE_POLL=0 makes
# the base wait a single tick so the linger window is the ONLY thing keeping `next` alive. Captures
# combined output in $OUT and exit code in $RC.
next() {
  local poll="$1" linger="$2"; shift 2
  set +e
  OUT="$( cd "$REPO" && HERD_CONFIG_FILE="$CFG" SCRIBE_BACKEND_DIR="$BACKENDS" \
            SCRIBE_POLL="$poll" SCRIBE_LINGER_SECS="$linger" \
            bash "$STEP" next "$@" 2>&1 )"
  RC=$?
  set -e
}

# enqueue <name> <text> — drop a FIFO .req the drainer can claim.
enqueue() { printf '%s\n' "$2" > "$Q/$1.req"; }
# enqueue_after <secs> <name> <text> — background a delayed enqueue (a request that arrives mid-linger).
enqueue_after() { ( sleep "$1"; printf '%s\n' "$3" > "$Q/$2.req" ) & }

# ══ 1. DEFAULT (linger 0) is byte-identical: an empty queue returns EMPTY at the base poll ═════════
next 0 0
[ "$RC" -eq 0 ]                                  || fail "1: next exited $RC ($OUT)"
printf '%s\n' "$OUT" | grep -qx 'EMPTY'          || fail "1: empty queue with linger 0 did not print EMPTY ($OUT)"
ok

# ══ 2. A request already waiting is claimed immediately, regardless of linger ══════════════════════
enqueue 100 "first burst request"
next 0 8
[ "$RC" -eq 0 ]                                  || fail "2: next exited $RC ($OUT)"
printf '%s\n' "$OUT" | grep -q '^CLAIMED '       || fail "2: a queued request was not CLAIMED ($OUT)"
printf '%s\n' "$OUT" | grep -q 'first burst request' || fail "2: claimed the wrong request text ($OUT)"
printf '%s\n' "$OUT" | grep -qx 'EMPTY'          && fail "2: printed EMPTY despite a waiting request"
# clean up the claim so the queue is empty again for the next case
rm -f "$Q"/*.mine
ok

# ══ 3. WITHOUT linger, a request that arrives after the base poll is MISSED (→ EMPTY) — this is the
#      cold-start-per-gap regime the fix removes. Enqueue ~2s out; poll=0/linger=0 gives up at once. ═
enqueue_after 2 200 "late request (no linger)"
next 0 0
wait   # reap the backgrounded enqueue
printf '%s\n' "$OUT" | grep -qx 'EMPTY'          || fail "3: linger 0 did not return EMPTY on the empty-then-late queue ($OUT)"
rm -f "$Q"/*.req "$Q"/*.mine   # the late request landed after EMPTY; discard it
ok

# ══ 4. WITH a linger window, a request enqueued DURING the linger is CLAIMED by the SAME `next` call
#      — this is the mechanic that lets one session span an idle gap between bursts. ════════════════
enqueue_after 2 300 "request enqueued mid-linger"
next 0 10
wait
[ "$RC" -eq 0 ]                                  || fail "4: lingering next exited $RC ($OUT)"
printf '%s\n' "$OUT" | grep -q '^CLAIMED '       || fail "4: mid-linger request was not CLAIMED ($OUT)"
printf '%s\n' "$OUT" | grep -q 'request enqueued mid-linger' || fail "4: claimed the wrong request ($OUT)"
printf '%s\n' "$OUT" | grep -qx 'EMPTY'          && fail "4: printed EMPTY instead of lingering for the late request"
rm -f "$Q"/*.mine
ok

# ══ 5. ONE drainer handles a BURST across a gap: enqueue A → next claims A; then (queue empty) B is
#      enqueued mid-linger → the NEXT `next` claims B too. No intervening EMPTY == the session that
#      drained A is the same session that drains B (HERD-88's whole point). ════════════════════════
enqueue 400 "burst A"
next 0 10                                        # session's 1st drain
printf '%s\n' "$OUT" | grep -q 'burst A'         || fail "5: first drain did not claim burst A ($OUT)"
printf '%s\n' "$OUT" | grep -qx 'EMPTY'          && fail "5: session ended (EMPTY) before the gap"
rm -f "$Q"/*.mine                                # (drainer would commit+unclaim A here)
enqueue_after 2 401 "burst B"                    # arrives during the linger, after an idle gap
next 0 10                                        # SAME session's 2nd drain
wait
printf '%s\n' "$OUT" | grep -q 'burst B'         || fail "5: same session did not pick up burst B across the gap ($OUT)"
printf '%s\n' "$OUT" | grep -qx 'EMPTY'          && fail "5: printed EMPTY instead of draining burst B"
rm -f "$Q"/*.mine
ok

echo "ALL PASS ($pass checks)"
