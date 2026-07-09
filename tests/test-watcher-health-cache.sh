#!/usr/bin/env bash
# test-watcher-health-cache.sh — hermetic test for the healthcheck sha-cache policy in the watcher's
# _healthcheck_gate (issue #78 part 2). The sha-cache (PR #66) records a TERMINAL health verdict keyed
# to the commit sha and replays it every tick. A tab-leak-guard CODEERROR, however, is INFRA/TRANSIENT:
# a concurrent SAME-workspace sibling builder tab flickering non-idle during the healthcheck window can
# trip the guard on both the initial run and the solo retry, yet self-heals once that tab stabilizes.
# Caching it FREEZES the row red until a human deletes the marker. This test asserts:
#   • a tab-leak-guard CODEERROR is NOT written to the sha health-result cache (next tick re-runs) …
#   • … while a NORMAL (non-tab-leak) code-error IS cached (stays red without re-running).
# It also covers HERD-72: the cache hit is journaled only on a TRANSITION (first hit per (pr,sha), or an
# outcome change), so identical replays every ~6s poll tick no longer drown 'herd why <pr>'.
# It sources agent-watch.sh's helpers via the AGENT_WATCH_LIB guard (no live loop), stubs the
# healthcheck binary on disk (NETWORK-FREE, no herdr, no repo), and inspects the on-disk cache marker.
# Run:  bash tests/test-watcher-health-cache.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# HERMETIC STUB (HERD-173 / HERD-189): a red row now consults the builder's agent_status, so that a red
# somebody is ALREADY fixing never lies "needs you" (_active_fix_note). That is a `herdr agent list`
# call, and a hermetic test must never reach the LIVE control room — stub herdr on PATH. It reports no
# agents, which is the "nobody is on it" case this test's CODEERROR row asserts.
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\necho '"'"'{"result":{"agents":[]}}'"'"'\nexit 0\n' > "$BIN/herdr"
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# Source the watcher's helpers WITHOUT its live loop. Point config discovery at a nonexistent file so
# herd-config.sh falls back to its generic defaults — fully hermetic, no repo/.herd walk-up.
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type _healthcheck_gate >/dev/null 2>&1 || fail "_healthcheck_gate not defined after sourcing"

# Redirect all cache/state I/O into the temp dir and silence the frame renderer (it would clear the
# screen). These override whatever the sourced config resolved.
#
# Issue #144: the gate calls journal_append, which resolves its path from WORKTREES_DIR (via
# journal.sh's _journal_file), NOT from TREES. Overriding only TREES (as this test used to) left the
# journal bound to the FALLBACK ${PROJECT_ROOT}-trees — a REAL path outside the sandbox — so every run
# of this hermetic test wrote healthcheck events into <pool>/<slug>-trees/.herd/journal.jsonl. Pin
# BOTH WORKTREES_DIR (the derived-path source) and JOURNAL_FILE (journal.sh's explicit seam) into $T
# so no journal write can escape the sandbox by EITHER route.
TREES="$T"
WORKTREES_DIR="$T"
export JOURNAL_FILE="$T/journal.jsonl"
HEALTH_STATE="$T/.agent-watch-healthchecks"
render() { :; }
declare -a DISPLAY=()

# Hermetic-seal guard (issue #144): assert the journal writer is bound INSIDE the sandbox before any
# gate runs. If a future edit drops the WORKTREES_DIR/JOURNAL_FILE overrides above, _journal_file
# resolves back to the real derived path and this fails loudly instead of silently leaking again.
_jf_seal="$(_journal_file)"
case "$_jf_seal" in
  "$T"/*) : ;;
  *) fail "journal path escapes the sandbox: '$_jf_seal' (issue #144 — WORKTREES_DIR/JOURNAL_FILE not pinned into \$T)" ;;
esac

# Stub the healthcheck binary: emit $HC_ONELINE and exit $HC_RC. _healthcheck_gate runs it twice (the
# initial run + the solo retry-before-red); returning rc 1 both times reproduces a terminal CODEERROR.
HC_STUB="$T/healthcheck-stub.sh"
cat > "$HC_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${HC_ONELINE:-}"
exit "${HC_RC:-0}"
STUB
chmod +x "$HC_STUB"
export HERD_HEALTHCHECK_BIN="$HC_STUB"

SHA="deadbeefcafe"

# drive_gate <pr#> <slug> <dir> <idx> <sha> — drive the now-ASYNC gate (HERD-185) to a TERMINAL verdict:
# dispatch, await the background worker's dispatch result, then re-enter the gate to COLLECT it (a cache
# hit / QUEUED returns immediately). Mirrors the watcher tick re-entering the gate across ticks.
drive_gate() {
  local _p="$1" _s="$2" _d="$3" _i="$4" _sha="$5" _disp _n=0
  _HC_RESULT=""
  _healthcheck_gate "$_p" "$_s" "$_d" "$_i" "$_sha"
  case "$_HC_RESULT" in CLEAN|FLAKY|CODEERROR|QUEUED) return 0 ;; esac
  _disp="$(_health_dispatch_file "${_p}-${_sha}")"
  while [ "$_n" -lt 500 ]; do [ -f "$_disp" ] && break; sleep 0.02; _n=$((_n + 1)); done
  _HC_RESULT=""
  _healthcheck_gate "$_p" "$_s" "$_d" "$_i" "$_sha"
}

# run_gate <pr#> <oneline> <rc> — drive the gate once with a fresh cache slate for this pr+sha.
run_gate() {
  rm -f "$(_health_result_file "$1" "$SHA")" 2>/dev/null || true
  rm -f "$TREES"/.health-inflight-* "$TREES"/.health-dispatch-* 2>/dev/null || true
  export HC_ONELINE="$2" HC_RC="$3"
  drive_gate "$1" "slug$1" "$T/wt" 0 "$SHA"
}

# ── 1. tab-leak-guard CODEERROR → verdict red THIS tick, but NOT cached (self-heals next tick) ──────
run_gate 1 "tab-leak-guard: suite leaked an orphan tab into the live workspace — orphan tabs 3->4" 1
[ "$_HC_RESULT" = "CODEERROR" ] || fail "tab-leak reproduced → _HC_RESULT should be CODEERROR (got '$_HC_RESULT')"
[ -f "$(_health_result_file 1 "$SHA")" ] && \
  fail "tab-leak-guard CODEERROR must NOT be written to the sha cache (it froze red — issue #78)"
ok

# ── 2. a normal (non-tab-leak) code error → CODEERROR AND cached, exactly as today ──────────────────
run_gate 2 "pytest: 3 failed in tests/test_thing.py" 1
[ "$_HC_RESULT" = "CODEERROR" ] || fail "normal code error → _HC_RESULT should be CODEERROR (got '$_HC_RESULT')"
cache2="$(_health_result_file 2 "$SHA")"
[ -f "$cache2" ] || fail "a genuine non-tab-leak code error MUST be cached (regression guard)"
IFS=$'\t' read -r cv cd < "$cache2"
[ "$cv" = "CODEERROR" ] || fail "cached verdict should be CODEERROR (got '$cv')"
case "$cd" in *pytest*) : ;; *) fail "cached detail should carry the code-error oneline (got '$cd')" ;; esac
ok

# ── 3. sanity: a CLEAN run is still cached (the fix touches only the CODEERROR branch) ──────────────
run_gate 3 "" 0
[ "$_HC_RESULT" = "CLEAN" ] || fail "clean run → _HC_RESULT should be CLEAN (got '$_HC_RESULT')"
[ -f "$(_health_result_file 3 "$SHA")" ] || fail "a CLEAN verdict must still be cached"
ok

# ── 4. issue #144: the gates above DID journal — and every event landed in the sandbox, not a real
#      derived path. Positive proof the seam captured the writes rather than merely suppressing them. ─
[ -s "$JOURNAL_FILE" ] || fail "gate journaling produced no sandbox journal at $JOURNAL_FILE (issue #144)"
grep -q '"event":"healthcheck_' "$JOURNAL_FILE" || fail "sandbox journal missing healthcheck gate events (issue #144)"
ok

# ── 5. HERD-72: an unchanged (pr,sha) replayed every poll tick journals healthcheck_cache_hit ONCE ────
# The sha-cache replays the SAME terminal verdict each ~6s tick while a PR waits on review; before the
# fix that emitted 20-60 identical healthcheck_cache_hit lines per PR, drowning 'herd why'. Prove the
# de-dup: prime a terminal CLEAN cache, then hit it repeatedly and assert exactly one event is journaled.
CH_PR=42
CH_SHA="cafed00dface"
rm -f "$(_health_result_file "$CH_PR" "$CH_SHA")" "$(_health_cachehit_file "$CH_PR")" 2>/dev/null || true
: > "$JOURNAL_FILE"

# Prime: the FIRST full run for this (pr,sha) misses the cache — it runs the suite, writes the sha
# result, and journals healthcheck_outcome (NOT a cache hit yet).
rm -f "$TREES"/.health-inflight-* "$TREES"/.health-dispatch-* 2>/dev/null || true
export HC_ONELINE="" HC_RC=0
drive_gate "$CH_PR" "slug$CH_PR" "$T/wt" 0 "$CH_SHA"
[ "$_HC_RESULT" = "CLEAN" ] || fail "prime run should be CLEAN (got '$_HC_RESULT')"
[ "$(grep -c '"event":"healthcheck_cache_hit"' "$JOURNAL_FILE")" -eq 0 ] || \
  fail "the priming full run must NOT journal a cache hit (it ran the suite)"

# Replay the SAME (pr,sha) five times: each takes the cache-hit path. Only the FIRST transition journals.
for _ in 1 2 3 4 5; do
  rm -f "$TREES"/.health-inflight-* 2>/dev/null || true
  _HC_RESULT=""
  _healthcheck_gate "$CH_PR" "slug$CH_PR" "$T/wt" 0 "$CH_SHA"
  [ "$_HC_RESULT" = "CLEAN" ] || fail "cache replay should stay CLEAN (got '$_HC_RESULT')"
done
n_hits="$(grep -c '"event":"healthcheck_cache_hit"' "$JOURNAL_FILE")"
[ "$n_hits" -eq 1 ] || \
  fail "five identical cache replays over an unchanged (pr,sha) must journal EXACTLY ONE healthcheck_cache_hit (got $n_hits)"
ok

# ── 6. HERD-72: a CHANGED outcome for the same PR re-journals (a transition, not a repeat) ────────────
# Flip the cached terminal verdict to CODEERROR (as a re-evaluation / new head would), hit the cache,
# and assert a NEW event is emitted carrying the changed outcome — 'herd why' must still see transitions.
record_health_result "$CH_PR" "$CH_SHA" CODEERROR "pytest: 1 failed in tests/test_thing.py"
rm -f "$TREES"/.health-inflight-* 2>/dev/null || true
_HC_RESULT=""
_healthcheck_gate "$CH_PR" "slug$CH_PR" "$T/wt" 0 "$CH_SHA"
[ "$_HC_RESULT" = "CODEERROR" ] || fail "changed cache verdict should surface CODEERROR (got '$_HC_RESULT')"
n_hits2="$(grep -c '"event":"healthcheck_cache_hit"' "$JOURNAL_FILE")"
[ "$n_hits2" -eq 2 ] || fail "an outcome change must emit a NEW healthcheck_cache_hit (expected 2 total, got $n_hits2)"
grep -q '"event":"healthcheck_cache_hit".*"outcome":"CODEERROR"' "$JOURNAL_FILE" || \
  fail "the changed-outcome cache hit must carry outcome CODEERROR (event shape unchanged for 'herd why')"
ok

# ── 7. HERD-72: repeating the CHANGED outcome is again suppressed (dedup tracks the CURRENT state) ─────
rm -f "$TREES"/.health-inflight-* 2>/dev/null || true
_HC_RESULT=""
_healthcheck_gate "$CH_PR" "slug$CH_PR" "$T/wt" 0 "$CH_SHA"
n_hits3="$(grep -c '"event":"healthcheck_cache_hit"' "$JOURNAL_FILE")"
[ "$n_hits3" -eq 2 ] || fail "repeating the CHANGED outcome must stay suppressed (expected 2, got $n_hits3)"
ok

echo "ALL PASS ($pass checks)"
