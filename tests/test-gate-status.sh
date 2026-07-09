#!/usr/bin/env bash
# test-gate-status.sh — hermetic tests for the herd/gates COMMIT STATUS surface (HERD-194).
#
# The watcher is the ONLY thing that runs the gates (healthcheck + adversarial review). As it clears a
# (pr,sha) it posts a `herd/gates` commit status; paired with `require herd/gates` GitHub branch
# protection (docs/governance-gates.md) that makes the gate FAIL-SAFE across seats/collaborators —
# anyone may merge, but a commit no watcher blessed has no success status and is unmergeable.
#
# The surface is SUCCESS-ONLY: the watcher posts `herd/gates=success` when both gates are green and
# NOTHING otherwise — a non-passing (pending/failure) status would flip a CLEAN sha to UNSTABLE and
# strand it. The fail-safe rests entirely on the ABSENCE of success. These tests source agent-watch.sh
# in lib mode (the same seam test-gate-dispatch.sh uses) with `gh` stubbed on PATH, and assert:
#   (1) post_gate_status posts `success` via the Statuses API with the right state + context=herd/gates,
#       EXACTLY ONCE per (pr,sha) — a repeat call is a no-op (no second write, one ledger row) — and
#       every non-passing conclusion (pending/failure/anything) is REJECTED as a no-op.
#   (2) A FAILED API write is NOT recorded, so the next tick re-tries (the blessing MUST land).
#   (3) GATE_STATUS=off and --dry-run are pure no-ops (no post, no ledger).
#   (4) An empty sha or an unrecognized conclusion never posts.
#   (5) A review BLOCK posts NOTHING: _handle_block_verdict (the single BLOCK choke point) must not
#       write a status — posting `failure` there would flip CLEAN→UNSTABLE and break the override loop.
#   (6) skip-on-existing-blessing: _gate_status_blessed is true ONLY for an existing herd/gates=success
#       status (another seat's blessing) and fail-soft false otherwise.
#   (7) deadlock fix: a BLOCKED-but-unblessed PR is gate-eligible (BLOCKED only; never re-gated once
#       blessed; off/dry-run inert) so `require herd/gates` never bricks a fresh PR.
#
# Fully hermetic: local temp only; stubs gh (PATH). No network, no model, no real PRs.
# Run:  bash tests/test-gate-status.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── gh stub ───────────────────────────────────────────────────────────────────
# Logs every invocation ($*) to $GH_LOG and emulates the two api shapes the surface uses:
#   • READ   gh api repos/{owner}/{repo}/commits/<sha>/statuses --jq '…[0].state'
#            → prints $GH_BLESSED_STATE verbatim (stands in for the jq-extracted state; empty = none).
#   • WRITE  gh api repos/{owner}/{repo}/statuses/<sha> -f state=… -f context=… -f description=…
#            → exit 0, unless GH_FAIL_WRITE=1 (simulate a transient API failure → non-zero).
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
url=""
# find the api path argument (the token after 'api')
prev=""
for a in "$@"; do
  [ "$prev" = "api" ] && { url="$a"; break; }
  prev="$a"
done
case "$url" in
  */commits/*/statuses) printf '%s' "${GH_BLESSED_STATE:-}" ;;   # read path (blessing check)
  */statuses/*)         [ "${GH_FAIL_WRITE:-}" = "1" ] && exit 1; exit 0 ;;  # write path
  *)                    exit 0 ;;
esac
EOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export GH_LOG="$T/gh.log"; : > "$GH_LOG"
export GH_BLESSED_STATE=""
export GH_FAIL_WRITE=""

# ── source agent-watch.sh in lib mode ───────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# The ledger the surface writes; reset before each test so rows are counted cleanly.
GL="$GATE_STATUS_STATE"
reset() { rm -f "$GL"; : > "$GH_LOG"; GH_BLESSED_STATE=""; GH_FAIL_WRITE=""; DRYRUN=""; unset GATE_STATUS 2>/dev/null || true; }
gh_calls() { [ -s "$GH_LOG" ] && grep -c . "$GH_LOG" || echo 0; }
ledger_rows() { [ -s "$GL" ] && grep -c . "$GL" || echo 0; }

# ── (1) success posts once, with the right state + context ─────────────────────
# SUCCESS-ONLY: the watcher blesses a green (pr,sha) and posts NOTHING else. A non-passing status
# (pending/failure) would flip a CLEAN sha to UNSTABLE and strand it, so both are rejected below.
reset
post_gate_status 7 shaOk success
grep -q "statuses/shaOk" "$GH_LOG"        || fail "(1) success: no statuses POST logged"
grep -q "state=success" "$GH_LOG"         || fail "(1) success: state=success not in POST"
grep -q "context=herd/gates" "$GH_LOG"    || fail "(1) success: context=herd/gates not in POST"
[ "$(ledger_rows)" = "1" ]                || fail "(1) success: expected exactly 1 ledger row"
# repeat → no second network write, still one ledger row (exactly-once per (pr,sha))
: > "$GH_LOG"
post_gate_status 7 shaOk success
[ "$(gh_calls)" = "0" ]                   || fail "(1) success: repeat call posted again (not once)"
[ "$(ledger_rows)" = "1" ]                || fail "(1) success: repeat call grew the ledger"
ok

# pending AND failure are rejected outright — no network write, no ledger row (both are NON-passing and
# would flip a CLEAN sha to UNSTABLE). Only `success` is ever posted.
for bad in pending failure bogus; do
  reset
  post_gate_status 7 "sha-$bad" "$bad"
  [ "$(gh_calls)" = "0" ] && [ "$(ledger_rows)" = "0" ] || fail "(1x) non-success '$bad' must never be posted"
done
ok

# ── (2) a FAILED API write is not recorded → retries next tick ─────────────────
reset
GH_FAIL_WRITE=1
post_gate_status 9 shaFail success
[ "$(ledger_rows)" = "0" ] || fail "(2) failed write must NOT be recorded"
# next tick: API recovers → the post lands and records exactly once
GH_FAIL_WRITE=""; : > "$GH_LOG"
post_gate_status 9 shaFail success
grep -q "statuses/shaFail" "$GH_LOG" || fail "(2) retry did not re-POST after recovery"
[ "$(ledger_rows)" = "1" ]           || fail "(2) retry did not record after success"
ok

# ── (3) GATE_STATUS=off and dry-run are pure no-ops ────────────────────────────
reset
GATE_STATUS=off post_gate_status 10 shaOff success
[ "$(gh_calls)" = "0" ] && [ "$(ledger_rows)" = "0" ] || fail "(3) GATE_STATUS=off still posted"
ok
reset
DRYRUN=1
post_gate_status 10 shaDry success
[ "$(gh_calls)" = "0" ] && [ "$(ledger_rows)" = "0" ] || fail "(3) dry-run still posted"
ok

# ── (4) empty sha / unrecognized conclusion never post ─────────────────────────
reset
post_gate_status 11 "" success
post_gate_status 11 shaBad bogus-state
[ "$(gh_calls)" = "0" ] && [ "$(ledger_rows)" = "0" ] || fail "(4) empty sha or bad state posted"
ok

# ── (5) BLOCK posts NOTHING — a failing status would flip CLEAN→UNSTABLE and strand the PR ─────
# _handle_block_verdict must never post a herd/gates status: the fail-safe is the ABSENCE of success,
# and posting `failure` here would break the very block/override/refix loop this function drives.
reset
export REVIEW_AUTOFIX=false
DISPLAY=()
_handle_block_verdict 42 someslug blockSha 0 || true
grep -q "statuses/blockSha" "$GH_LOG" && fail "(5) BLOCK must NOT post a herd/gates status"
[ "$(ledger_rows)" = "0" ]            || fail "(5) BLOCK must not write the gate-status ledger"
ok

# ── (6) skip-on-existing-blessing: _gate_status_blessed ────────────────────────
reset
GH_BLESSED_STATE=success
_gate_status_blessed anySha || fail "(6) success status should read as blessed"
GH_BLESSED_STATE=pending
_gate_status_blessed anySha && fail "(6) a pending status must NOT read as blessed"
GH_BLESSED_STATE=""
_gate_status_blessed anySha && fail "(6) no status must NOT read as blessed"
_gate_status_blessed "" && fail "(6) empty sha must NOT read as blessed"
ok

# ── (7) deadlock fix: a BLOCKED-but-unblessed PR is gate-eligible ───────────────
# Under `require herd/gates` protection an unblessed PR reports mergeStateStatus=BLOCKED, never CLEAN.
# _gate_bless_eligible must make it gate-eligible so the watcher can run gates + post the blessing;
# once success is recorded it must STOP re-gating (else a PR blocked by something else re-gates forever).
reset
_gate_bless_eligible 5 shaBlk BLOCKED || fail "(7) BLOCKED+unblessed must be gate-eligible"
# other non-CLEAN states are NOT force-gated (only the missing-required-check state qualifies)
_gate_bless_eligible 5 shaBlk UNSTABLE && fail "(7) UNSTABLE must not be force-gated"
_gate_bless_eligible 5 shaBlk BEHIND   && fail "(7) BEHIND must not be force-gated"
_gate_bless_eligible 5 shaBlk CLEAN    && fail "(7) CLEAN takes the normal path, not force-gated"
_gate_bless_eligible 5 ""     BLOCKED  && fail "(7) empty sha must not be gate-eligible"
# after we post success for the sha, it is no longer gate-eligible (no per-tick re-gate)
post_gate_status 5 shaBlk success
_gate_bless_eligible 5 shaBlk BLOCKED && fail "(7) an already-blessed sha must NOT re-gate"
# GATE_STATUS=off → no deadlock machinery → never force-gates
GATE_STATUS=off _gate_bless_eligible 5 shaOther BLOCKED && fail "(7) GATE_STATUS=off must not force-gate"
# dry-run inert — a bless-only candidate never merges, so --dry-run must not force it into the gate set
reset
DRYRUN=1
_gate_bless_eligible 6 shaDryBlk BLOCKED && fail "(7) dry-run must not force-gate a BLOCKED PR"
ok

echo "PASS test-gate-status.sh ($pass checks)"
