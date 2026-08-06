#!/usr/bin/env bash
# test-gh-rate-limit-backoff.sh — gate proof for HERD-582: a GitHub rate-limit response on the engine
# tick's gh discovery call must classify as BACKOFF, never as a genuine engine fault.
#
# Live incident (2026-08-06 02:06): a GraphQL bucket exhausted after a 50-merge day made
# live_runtime.py's discover_via_graphql exit non-zero. Before this fix that CalledProcessError
# propagated straight through LiveTick.run() -> main() -> exit 1, which the bash watchdog
# (_engine_tick_watchdog, agent-watch.sh) counts identically to a genuine engine death — three in a
# row rang the loud 'ENGINE DOWN · manual intervention' banner + an operator page for what was a
# wait-with-a-known-reset.
#
# Proves, with a STUBBED `gh` on PATH (real python3, no network):
#   (1) a rate-limited GraphQL call makes herd_engine_live_tick return 0 (not a fault) and the real
#       python tick journals engine_rate_limited with the reset stamp it read from ONE cheap
#       `gh api rate_limit` follow-up call.
#   (2) driven through the FULL watchdog (_engine_tick_watchdog, agent-watch.sh sourced in lib mode):
#       the fault streak stays untouched, ENGINE_DOWN_ROW never arms, and the calm
#       'gh rate-limited ... until HH:MM' row is painted.
#   (3) a SECOND tick inside the same backoff window never re-invokes the graphql leg at all — the
#       marker LiveState wrote makes the next tick skip the gh round-trip outright.
#   (4) a genuine gh failure (auth/network-shaped, no rate-limit signature) is UNCHANGED: it still
#       returns non-zero, still grows the fault streak, and still arms ENGINE_DOWN_ROW past
#       _ENGINE_FAULT_MAX — this fix narrows the reclassification to rate limits only.
#
# Run:  bash tests/test-gh-rate-limit-backoff.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$WATCH" ] || { echo "FAIL: missing $WATCH" >&2; exit 1; }
[ -f "$REPO/pysrc/herd/live_runtime.py" ] || { echo "FAIL: missing pysrc/herd/live_runtime.py" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); }

# ── the stubbed `gh` (HERD-582): branches on a mode file so a single fake binary can play every role
# a real gh's tick-path calls need (repo view, the graphql discovery query, the rate_limit probe) and
# every failure shape this test drives (rate-limited / genuine-failure / clean). Every call is logged
# so a test can assert whether the graphql leg was invoked AT ALL on a given tick. ─────────────────
mkdir -p "$T/bin"
GH_STUB="$T/bin/gh"
cat > "$GH_STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_CALLS"
mode="$(cat "$GH_STUB_MODE_FILE" 2>/dev/null || printf 'clean')"
case "$*" in
  *"repo view"*)
    printf 'acme\trepo\n'
    exit 0
    ;;
  *"rate_limit"*)
    printf '%s\n' "$GH_STUB_RESET_EPOCH"
    exit 0
    ;;
  *"graphql"*)
    case "$mode" in
      rate_limited)
        printf "gh: GraphQL: API rate limit already exceeded for user ID 123. (repository)\n" >&2
        exit 1
        ;;
      genuine_failure)
        printf "gh: authentication failed, run 'gh auth login'\n" >&2
        exit 1
        ;;
      *)
        printf '{"data":{"repository":{"pullRequests":{"nodes":[]}}}}\n'
        exit 0
        ;;
    esac
    ;;
  *)
    printf '{}\n'
    exit 0
    ;;
esac
SH
chmod +x "$GH_STUB"

export PATH="$T/bin:$PATH"
export GH_STUB_MODE_FILE="$T/gh-mode"
export GH_STUB_CALLS="$T/gh-calls.log"
export DRYRUN=1 AGENT_WATCH_DRYRUN=1
export HERDKIT_HOME="$REPO"

set_mode() { printf '%s' "$1" > "$GH_STUB_MODE_FILE"; }
graphql_calls() { grep -c 'graphql' "$GH_STUB_CALLS" 2>/dev/null || true; }

# ── (1) herd_engine_live_tick directly: a rate-limited tick returns 0 (not a fault) and the real
#        python journals engine_rate_limited with the reset stamp ────────────────────────────────
LIVE1="$T/live1"; mkdir -p "$LIVE1"
NOW="$(date +%s)"
RESET_EPOCH=$(( NOW + 120 ))
export GH_STUB_RESET_EPOCH="$RESET_EPOCH"
: > "$GH_STUB_CALLS"
set_mode rate_limited
set +e
# HERD-440/HERD-596: re-export JOURNAL_FILE to THIS fixture — journal.sh's JOURNAL_FILE test seam
# outranks WORKTREES_DIR resolution by design (a forgetful test must never pollute a live journal),
# so under scripts/ci/run-suite.sh (which pins JOURNAL_FILE suite-wide for that same reason) leaving
# it unset here silently redirects the tick's journal to the suite-wide pin instead of $LIVE1's own
# — the write below then finds an empty $JPATH. Convention documented in run-suite.sh: "a test that
# needs its own journal re-exports JOURNAL_FILE."
JOURNAL_FILE="$LIVE1/.herd/journal.jsonl" WORKTREES_DIR="$LIVE1" \
  bash -c '. "'"$REPO"'/scripts/herd/engine-version.sh"; herd_engine_live_tick'
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "a rate-limited tick must return 0 (backoff, not a fault) — got rc=$rc"
JPATH="$LIVE1/.herd/journal.jsonl"
[ -f "$JPATH" ] || fail "the live tick must still journal (path: $JPATH missing)"
grep -q '"event":"engine_rate_limited"' "$JPATH" || fail "engine_rate_limited must be journaled: $(cat "$JPATH")"
line="$(grep '"event":"engine_rate_limited"' "$JPATH" | tail -1)"
case "$line" in *'"reset":'"$RESET_EPOCH"*) : ;; *) fail "engine_rate_limited must carry the reset stamp $RESET_EPOCH: $line" ;; esac
case "$line" in *'"until":'*) : ;; *) fail "engine_rate_limited must carry an until stamp: $line" ;; esac
grep -q '"event":"live_tick_start"' "$JPATH" && fail "a rate-limited tick must skip the ordinary candidate walk (no live_tick_start)"
pass

# ── (2)+(3): driven through the FULL watchdog — fault streak untouched, calm row painted, ENGINE_DOWN
#        never arms, and a SECOND tick within the window never re-invokes the graphql leg ──────────
LIVE2="$T/live2"; mkdir -p "$LIVE2"
RESET_EPOCH2=$(( $(date +%s) + 120 ))
export GH_STUB_RESET_EPOCH="$RESET_EPOCH2"
: > "$GH_STUB_CALLS"
set_mode rate_limited

EVENTS="$T/events"; : > "$EVENTS"
(
  export AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$T/.herd-config-missing" WORKTREES_DIR="$LIVE2" NO_COLOR=1
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "resource-fail" >&2; exit 1; }
  journal_append() { printf 'journal:%s\n' "$1" >> "$EVENTS"; }
  herd_driver_notify() { printf 'notify:%s\n' "$1" >> "$EVENTS"; }
  render() { printf 'render\n' >> "$EVENTS"; }
  DRYRUN=1
  _ENGINE_FAULT_STREAK=0; _ENGINE_FAULT_MAX=3; _ENGINE_TICK_RETRIES=1; _ENGINE_BACKOFF_BASE=1
  _ENGINE_DOWN_DECLARED=""; ENGINE_DOWN_ROW=""; ENGINE_RATE_LIMIT_ROW=""
  _ENGINE_PAUSE_DECLARED=""; ENGINE_PAUSE_ROW=""

  _engine_tick_watchdog || { echo "watchdog rc nonzero" >&2; exit 1; }
  printf 'STREAK1=%s\n' "$_ENGINE_FAULT_STREAK" >> "$EVENTS"
  printf 'DOWNROW1=%s\n' "$ENGINE_DOWN_ROW" >> "$EVENTS"
  printf 'RLROW1=%s\n' "$ENGINE_RATE_LIMIT_ROW" >> "$EVENTS"

  _engine_tick_watchdog || { echo "watchdog rc nonzero (tick 2)" >&2; exit 1; }
  printf 'STREAK2=%s\n' "$_ENGINE_FAULT_STREAK" >> "$EVENTS"
  printf 'DOWNROW2=%s\n' "$ENGINE_DOWN_ROW" >> "$EVENTS"
  printf 'RLROW2=%s\n' "$ENGINE_RATE_LIMIT_ROW" >> "$EVENTS"
) || fail "watchdog run under rate-limited gh failed (see stderr above)"

streak1="$(grep '^STREAK1=' "$EVENTS" | cut -d= -f2)"
streak2="$(grep '^STREAK2=' "$EVENTS" | cut -d= -f2)"
downrow1="$(grep '^DOWNROW1=' "$EVENTS" | cut -d= -f2-)"
downrow2="$(grep '^DOWNROW2=' "$EVENTS" | cut -d= -f2-)"
rlrow1="$(grep '^RLROW1=' "$EVENTS" | cut -d= -f2-)"
rlrow2="$(grep '^RLROW2=' "$EVENTS" | cut -d= -f2-)"

[ "$streak1" = 0 ] || fail "a rate-limited tick must NOT grow the fault streak (got $streak1)"
[ "$streak2" = 0 ] || fail "a second rate-limited tick must NOT grow the fault streak (got $streak2)"
[ -z "$downrow1" ] || fail "ENGINE_DOWN_ROW must never arm from a rate limit (tick 1: '$downrow1')"
[ -z "$downrow2" ] || fail "ENGINE_DOWN_ROW must never arm from a rate limit (tick 2: '$downrow2')"
case "$rlrow1" in *"rate-limited"*"until"*) : ;; *) fail "the calm rate-limit row must be painted (tick 1, got: '$rlrow1')" ;; esac
case "$rlrow2" in *"rate-limited"*"until"*) : ;; *) fail "the calm rate-limit row must be painted (tick 2, got: '$rlrow2')" ;; esac
calls="$(graphql_calls)"
[ "$calls" -le 1 ] || fail "the SECOND tick inside the backoff window must not re-invoke the graphql leg (saw $calls graphql calls, want <=1)"
pass

# ── (4) a genuine gh failure (no rate-limit signature) still faults exactly as before this fix ─────
LIVE3="$T/live3"; mkdir -p "$LIVE3"
set_mode genuine_failure
EVENTS3="$T/events3"; : > "$EVENTS3"
(
  export AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$T/.herd-config-missing" WORKTREES_DIR="$LIVE3" NO_COLOR=1
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "resource-fail" >&2; exit 1; }
  journal_append() { printf 'journal:%s\n' "$1" >> "$EVENTS3"; }
  herd_driver_notify() { printf 'notify:%s\n' "$1" >> "$EVENTS3"; }
  render() { printf 'render\n' >> "$EVENTS3"; }
  DRYRUN=1
  _ENGINE_FAULT_STREAK=0; _ENGINE_FAULT_MAX=2; _ENGINE_TICK_RETRIES=1; _ENGINE_BACKOFF_BASE=1
  _ENGINE_DOWN_DECLARED=""; ENGINE_DOWN_ROW=""; ENGINE_RATE_LIMIT_ROW=""
  _ENGINE_PAUSE_DECLARED=""; ENGINE_PAUSE_ROW=""

  _engine_tick_watchdog
  printf 'RC1=%s\n' "$?" >> "$EVENTS3"
  printf 'STREAK1=%s\n' "$_ENGINE_FAULT_STREAK" >> "$EVENTS3"

  _engine_tick_watchdog
  printf 'RC2=%s\n' "$?" >> "$EVENTS3"
  printf 'STREAK2=%s\n' "$_ENGINE_FAULT_STREAK" >> "$EVENTS3"
  printf 'DOWNROW2=%s\n' "$ENGINE_DOWN_ROW" >> "$EVENTS3"
  printf 'RLROW2=%s\n' "$ENGINE_RATE_LIMIT_ROW" >> "$EVENTS3"
) || true

rc1="$(grep '^RC1=' "$EVENTS3" | cut -d= -f2)"
rc2="$(grep '^RC2=' "$EVENTS3" | cut -d= -f2)"
gstreak1="$(grep '^STREAK1=' "$EVENTS3" | cut -d= -f2)"
gstreak2="$(grep '^STREAK2=' "$EVENTS3" | cut -d= -f2)"
gdownrow2="$(grep '^DOWNROW2=' "$EVENTS3" | cut -d= -f2-)"
grlrow2="$(grep '^RLROW2=' "$EVENTS3" | cut -d= -f2-)"

[ "$rc1" = 1 ] || fail "a genuine gh failure must still return non-zero from the watchdog (tick 1, got rc=$rc1)"
[ "$rc2" = 1 ] || fail "a genuine gh failure must still return non-zero from the watchdog (tick 2, got rc=$rc2)"
[ "$gstreak1" = 1 ] || fail "a genuine failure must still grow the fault streak (tick 1, got $gstreak1)"
[ "$gstreak2" = 2 ] || fail "a genuine failure must still grow the fault streak (tick 2, got $gstreak2)"
case "$gdownrow2" in *"ENGINE DOWN"*) : ;; *) fail "past _ENGINE_FAULT_MAX a genuine failure must still arm ENGINE_DOWN_ROW (got: '$gdownrow2')" ;; esac
[ -z "$grlrow2" ] || fail "a genuine failure must never paint the calm rate-limit row (got: '$grlrow2')"
if [ -f "$LIVE3/.herd/journal.jsonl" ]; then
  grep -q '"event":"engine_rate_limited"' "$LIVE3/.herd/journal.jsonl" \
    && fail "a genuine failure must never journal engine_rate_limited"
fi
pass

echo "ok — $PASS gh-rate-limit-backoff checks passed"
