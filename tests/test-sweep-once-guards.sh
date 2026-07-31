#!/usr/bin/env bash
# test-sweep-once-guards.sh — marker-sweep proof: `herd sweep`'s new leg reaps the
# .live-noted-<kind>-<pr>-<sha> / .live-posted-<kind>-<pr>-<sha> once-guard family
# (pysrc/herd/live_runtime.py's LiveState.once/.posted flat-file fallback) once its PR is PROVABLY
# MERGED or CLOSED — the family sweep.sh's existing leg 3 (.review-inflight-*/.health-inflight-*)
# never touches, since those are liveness/age-conditioned in-flight WORKER markers, a different
# lifecycle entirely from a permanent once-per-(pr,sha,kind) guard.
#
# Fully hermetic: a stubbed `gh` on PATH (no network), sourced via the same AGENT_WATCH_LIB seam
# test-sweep.sh uses.
#
# Asserts:
#   (1) LOADING — every new entry point is defined after sourcing.
#   (2) MERGED PR's markers (multiple <kind>s, both prefixes) are ALL reaped in one pass and the
#       journal carries one sweep_once_guard event with the right count.
#   (3) OPEN PR's markers are NEVER touched.
#   (4) An UNKNOWN/unreachable gh answer leaves markers untouched (fail-soft — never a false reap).
#   (5) DRY-RUN prints the plan but deletes nothing.
#   (6) ONE gh call per distinct PR, however many marker files/kinds it has (memoized per scan).
#   (7) Malformed basenames (non-numeric pr, non-hex/too-short sha) are never touched.
#   (8) CLOSED (not just MERGED) is also swept.
#
# Run:  bash tests/test-sweep-once-guards.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
SWEEPSH="$HERE/../scripts/herd/sweep.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); }
[ -f "$WATCH" ]   || fail "agent-watch.sh not found at $WATCH"
[ -f "$SWEEPSH" ] || fail "sweep.sh not found at $SWEEPSH"

# ── fixture: a real git repo (leg 1 machinery needs MAIN to resolve; unused by this leg directly) ───
export MAINDIR="$T/proj"; export TREESDIR="$T/proj-trees"
mkdir -p "$MAINDIR" "$TREESDIR"
git init -q -b main "$MAINDIR"
git -C "$MAINDIR" config user.email t@t.local; git -C "$MAINDIR" config user.name t
echo base > "$MAINDIR/f.txt"; git -C "$MAINDIR" add -A; git -C "$MAINDIR" commit -qm base
git -C "$MAINDIR" update-ref refs/remotes/origin/main HEAD

# ── stubs on PATH ─────────────────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
GH_CALLS="$T/gh-calls.log"; : > "$GH_CALLS"
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
  echo "\${3:-}" >> "$GH_CALLS"
  case "\${3:-}" in
    501) printf 'MERGED\tdeadbeef00\t501\n' ;;
    502) printf 'OPEN\tcafef00d00\t502\n' ;;
    503) : ;;                                   # unreachable / no answer → UNKNOWN, must stay untouched
    504) printf 'CLOSED\tfeedface00\t504\n' ;;
    *) : ;;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# ── source the engine in lib mode ────────────────────────────────────────────────────────────────
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless
export PROJECT_ROOT="$MAINDIR" WORKTREES_DIR="$TREESDIR" WORKSPACE_NAME=onceguardws
export DEFAULT_BRANCH="origin/main"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# ── (1) loading ───────────────────────────────────────────────────────────────────────────────────
for fn in sweep_leg_once_guards sweep_dead_once_guard_prs sweep_once_guard_files \
          _sweep_once_guard_parse _sweep_once_guard_pr_state _sweep_once_guard_scan_due; do
  type "$fn" >/dev/null 2>&1 || fail "(1) $fn not defined after sourcing"
done
ok; echo "PASS (1) once-guard sweep helpers load"

jcount(){ local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }

# ── plant the mess: 3 kinds for a MERGED pr, 2 for an OPEN pr, 1 for an UNKNOWN pr, 1 malformed ─────
touch "$TREESDIR/.live-noted-health_queued-501-deadbeef00"
touch "$TREESDIR/.live-noted-blessing-501-deadbeef00"
touch "$TREESDIR/.live-posted-gate_status-501-deadbeef00"
touch "$TREESDIR/.live-noted-stale-502-cafef00d00"
touch "$TREESDIR/.live-posted-gate_status-502-cafef00d00"
touch "$TREESDIR/.live-noted-hold-503-000000abcd"
touch "$TREESDIR/.live-noted-blessing-not-a-pr-deadbeef00"     # non-numeric "pr" field → never touched
touch "$TREESDIR/.live-noted-blessing-505-xyz"                 # non-hex sha → never touched

BEFORE_COUNT=$(ls -1 "$TREESDIR"/.live-noted-* "$TREESDIR"/.live-posted-* 2>/dev/null | wc -l | tr -cd '0-9')
[ "$BEFORE_COUNT" = "8" ] || fail "fixture setup: expected 8 planted marker files, got $BEFORE_COUNT"

# ── (2) MERGED pr 501's markers (3 files, 2 kinds x 1 prefix each) all reaped in one pass ───────────
_sweep_reset_counters
sweep_leg_once_guards ""
[ -e "$TREESDIR/.live-noted-health_queued-501-deadbeef00" ] && fail "(2) MERGED pr 501 health_queued marker survived"
[ -e "$TREESDIR/.live-noted-blessing-501-deadbeef00" ]      && fail "(2) MERGED pr 501 blessing marker survived"
[ -e "$TREESDIR/.live-posted-gate_status-501-deadbeef00" ]  && fail "(2) MERGED pr 501 posted marker survived"
[ "$SWEEP_N_ONCEGUARD" -ge 3 ] || fail "(2) SWEEP_N_ONCEGUARD should count at least the 3 reaped pr-501 files, got $SWEEP_N_ONCEGUARD"
grep -q '"event":"sweep_once_guard"' "$JOURNAL_FILE" || fail "(2) no sweep_once_guard journal event"
grep -q '"pr":501.*"result":"merged"' "$JOURNAL_FILE" || fail "(2) journal event missing pr=501/result=merged"
ok; echo "PASS (2) a MERGED PR's once-guard markers (multiple kinds, both prefixes) are all reaped + journaled"

# ── (3) OPEN pr 502's markers are NEVER touched ──────────────────────────────────────────────────────
[ -e "$TREESDIR/.live-noted-stale-502-cafef00d00" ]        || fail "(3) OPEN pr 502 marker was deleted"
[ -e "$TREESDIR/.live-posted-gate_status-502-cafef00d00" ] || fail "(3) OPEN pr 502 posted marker was deleted"
ok; echo "PASS (3) an OPEN PR's once-guard markers are never touched"

# ── (4) UNKNOWN/unreachable gh answer (pr 503) leaves the marker untouched — fail-soft ───────────────
[ -e "$TREESDIR/.live-noted-hold-503-000000abcd" ] || fail "(4) an unreachable gh answer must never cause a reap"
ok; echo "PASS (4) an unreachable/unknown gh answer fails soft — no reap"

# ── (7) malformed basenames were never touched by the same run ──────────────────────────────────────
[ -e "$TREESDIR/.live-noted-blessing-not-a-pr-deadbeef00" ] || fail "(7) a non-numeric pr field must never be touched"
[ -e "$TREESDIR/.live-noted-blessing-505-xyz" ]             || fail "(7) a non-hex sha must never be touched"
ok; echo "PASS (7) malformed once-guard basenames are never touched"

# ── (6) exactly ONE gh call for pr 501 across its 3 marker files (memoized per scan) ─────────────────
n501="$(grep -c '^501$' "$GH_CALLS" 2>/dev/null || true)"
[ "${n501:-0}" = "1" ] || fail "(6) expected exactly 1 gh call for pr 501 (memoized), got ${n501:-0}"
ok; echo "PASS (6) one gh pr view call per distinct PR, however many marker files it has"

# ── (8) CLOSED is swept too, and (5) --dry-run touches nothing ──────────────────────────────────────
touch "$TREESDIR/.live-noted-observe-504-feedface00"
_sweep_reset_counters
sweep_leg_once_guards 1     # dry-run: any non-empty $1 is "dry" per the leg's own convention
[ -e "$TREESDIR/.live-noted-observe-504-feedface00" ] || fail "(5) --dry-run must not delete anything"
[ "$SWEEP_N_ONCEGUARD" -ge 1 ] || fail "(5) dry-run must still COUNT what it would sweep"
ok; echo "PASS (5) dry-run prints/counts the plan but deletes nothing"

_sweep_reset_counters
sweep_leg_once_guards ""
[ -e "$TREESDIR/.live-noted-observe-504-feedface00" ] && fail "(8) CLOSED pr 504's marker survived a live run"
grep -q '"pr":504.*"result":"closed"' "$JOURNAL_FILE" || fail "(8) journal event missing pr=504/result=closed"
ok; echo "PASS (8) a CLOSED PR's once-guard markers are reaped too"

echo "ALL PASS ($PASS checks)"
