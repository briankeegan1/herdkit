#!/usr/bin/env bash
# test-health-autofix.sh — hermetic proof of HEALTHCHECK_AUTOFIX + the HERD-173 row-truth rule.
#
# Two halves, both driven against the SHIPPED agent-watch.sh functions (sourced in AGENT_WATCH_LIB
# mode) with stubbed herdr/gh/git and a stub healthcheck that forces a reproduced CODE ERROR.
#
# ROW TRUTH — "needs you" means NOBODY is on it:
#   (1) nobody working  → "needs you" carrying the blocker AND a remedy
#   (2) agent working the same red (manual re-task, autofix OFF) → "fix in progress", never "needs you"
#   (3) after an autofix bounce → "fix in progress · awaiting push (round k/3)"
#
# HEALTHCHECK_AUTOFIX:
#   (4) OFF (default) → no bounce, no ledger write, gate still returns CODEERROR (PR held red)
#   (5) ON  → the failing test + suite log are delivered to the builder's AGENT pane, once per (pr,sha)
#   (6) SHARED round budget with the review refix — one budget per PR, capped at REFIX_MAX_ROUNDS
#   (7) cap reached → "needs you · refix limit … " (blocker + remedy), no further bounce
#   (8) a tab-leak-guard CODE ERROR is infra: never bounced, legacy row preserved
#   (9) dry-run → never bounces even with autofix ON
#
# FAILURE-DETAIL EXTRACTION (_health_fail_detail):
#  (10) TAP log → the first 'not ok' line; non-TAP log → the error line BELOW healthcheck.sh's
#       "❌ CODE ERROR" banner, never the content-free banner itself.
#
# END-TO-END: (11) drives the real _healthcheck_gate with a forced CODEERROR — bounce delivered on the
#       collect tick, and the NEXT tick (shaCache replay) reads "fix in progress", not "needs you".
#
# Run:  bash tests/test-health-autofix.sh
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

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done

# herdr stub: `agent list` reports one configurable agent; `pane run` logs "<pane_id>\t<text>".
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
      "${STUB_AGENT_NAME:-}" "${STUB_AGENT_STATUS:-idle}" "${STUB_AGENT_PANE_ID:-pane-test-000}" ;;
  "pane run")
    [ -n "${STUB_PANE_RUN_LOG:-}" ] && printf '%s\t%s\n' "$3" "$(printf '%s' "${4:-}" | tr '\n' ' ')" >> "$STUB_PANE_RUN_LOG" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# Stub healthcheck: cat a body file, exit $HC_RC. Used by the end-to-end gate drive.
HC_STUB="$T/hc.sh"
cat > "$HC_STUB" <<'STUB'
#!/usr/bin/env bash
[ -n "${HC_BODY_FILE:-}" ] && [ -f "$HC_BODY_FILE" ] && cat "$HC_BODY_FILE"
exit "${HC_RC:-0}"
STUB
chmod +x "$HC_STUB"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_HEALTHCHECK_BIN="$HC_STUB"
export HEALTH_CONCURRENCY=1
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
TREES="$WORKTREES_DIR"

for fn in _health_autofix_enabled _handle_health_codeerror _active_fix_note _health_fail_detail \
          refix_attempted refix_round_count record_refix; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# Hermetic seal (issue #144): journal writes must land in the sandbox.
case "$(_journal_file)" in "$T"/*) : ;; *) fail "journal escapes the sandbox: '$(_journal_file)'" ;; esac

render() { :; }
# No real sleeps: the wake verifier consumes return codes from a queue file (0=woke, 1=never woke).
STUB_WAIT_FILE="$T/wait-codes.txt"; : > "$STUB_WAIT_FILE"
_wait_agent_working() {
  local _c; _c="$(head -1 "$STUB_WAIT_FILE" 2>/dev/null || true)"
  { tail -n +2 "$STUB_WAIT_FILE" 2>/dev/null || true; } > "${STUB_WAIT_FILE}.tmp"
  mv "${STUB_WAIT_FILE}.tmp" "$STUB_WAIT_FILE" 2>/dev/null || true
  return "${_c:-0}"
}
# Liveness: alive unless a test says otherwise (the real probe would shell out to the driver).
_agent_liveness() { printf '%s' "${STUB_LIVENESS:-alive}"; }
# The limit preflight is exercised by test-sandbox-limit-resume.sh; here it never fires.
_detect_limit_hit() { return 1; }

export STUB_PANE_RUN_LOG="$T/pane-runs.txt"; : > "$STUB_PANE_RUN_LOG"
runs() { awk 'END{print NR+0}' "$STUB_PANE_RUN_LOG" 2>/dev/null || printf '0'; }
row()  { printf '%s\n' "${DISPLAY[0]:-}"; }
reset_state() { : > "$STUB_PANE_RUN_LOG"; : > "$REFIX_STATE"; DISPLAY=(); }

NOTOK='not ok 7 tests/test-widget.sh: expected 3 got 4'

export MAIN="$T/main"; mkdir -p "$T/main" "$T/wt"
# drive <pr> <slug> <sha> — dispatch the async gate, await the worker, collect.
drive() {
  local _p="$1" _s="$2" _sha="$3" _disp _n=0
  _HC_RESULT=""; DISPLAY=()
  _healthcheck_gate "$_p" "$_s" "$T/wt" 0 "$_sha"
  case "$_HC_RESULT" in CLEAN|FLAKY|CODEERROR|QUEUED) return 0 ;; esac
  _disp="$(_health_dispatch_file "${_p}-${_sha}")"
  while [ "$_n" -lt 500 ]; do [ -f "$_disp" ] && break; sleep 0.02; _n=$((_n + 1)); done
  _HC_RESULT=""; DISPLAY=()
  _healthcheck_gate "$_p" "$_s" "$T/wt" 0 "$_sha"
}

# ── (1) ROW TRUTH: nobody working → "needs you" with blocker AND remedy ─────────────────────────
reset_state
export STUB_AGENT_NAME="slug-a" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-a"
unset HEALTHCHECK_AUTOFIX
_handle_health_codeerror 10 slug-a shaA 0 "$T/wt" "$NOTOK"
row | grep -q 'needs you' || fail "(1) idle agent + autofix off must read 'needs you' (got: $(row))"
row | grep -q "$NOTOK"    || fail "(1) the needs-you row must carry the BLOCKER (failing test)"
row | grep -q 'fix in the worktree + push' || fail "(1) the needs-you row must carry a REMEDY (got: $(row))"
row | grep -q '.health-log-10-shaA'       || fail "(1) the remedy must point at the tailable suite log"
[ "$(runs)" = "0" ] || fail "(1) autofix off must never pane-run"
ok

# ── (2) ROW TRUTH: agent WORKING the same red (manual re-task, autofix off) → never "needs you" ──
reset_state
export STUB_AGENT_STATUS="working"
_handle_health_codeerror 10 slug-a shaA 0 "$T/wt" "$NOTOK"
row | grep -q 'needs you' && fail "(2) 'needs you' is BANNED while the agent is working (got: $(row))"
row | grep -q 'fix in progress' || fail "(2) a working agent must read 'fix in progress' (got: $(row))"
row | grep -q 'awaiting push'   || fail "(2) the in-progress row must say 'awaiting push'"
[ "$(runs)" = "0" ] || fail "(2) autofix off must never pane-run"
[ -s "$REFIX_STATE" ] && fail "(2) autofix off must never write the refix ledger"
ok
export STUB_AGENT_STATUS="idle"

# ── (4)+(5) OFF is inert; ON bounces once and delivers the failing test + the log path ───────────
reset_state
export HEALTHCHECK_AUTOFIX=false
_handle_health_codeerror 20 slug-a shaB 0 "$T/wt" "$NOTOK"
[ "$(runs)" = "0" ] || fail "(4) HEALTHCHECK_AUTOFIX=false must not bounce"
[ "$(refix_round_count 20)" = "0" ] || fail "(4) off-mode must not consume a refix round"
ok

reset_state
export HEALTHCHECK_AUTOFIX=true
printf '0\n' > "$STUB_WAIT_FILE"          # the agent wakes on the first try
_handle_health_codeerror 20 slug-a shaB 0 "$T/wt" "$NOTOK"
[ "$(runs)" = "1" ] || fail "(5) autofix on must pane-run the bounce exactly once (got $(runs))"
grep -q '^pane-a	' "$STUB_PANE_RUN_LOG" || fail "(5) the bounce must target the AGENT pane"
grep -q "$NOTOK" "$STUB_PANE_RUN_LOG"     || fail "(5) the prompt must name the failing test"
grep -q '.health-log-20-shaB' "$STUB_PANE_RUN_LOG" || fail "(5) the prompt must carry the suite log path"
row | grep -q 'refixing health-check (round 1/3)' || fail "(5) the bouncing row should read 'refixing health-check (round 1/3)' (got: $(row))"
refix_attempted 20 shaB health || fail "(5) the bounce must be recorded kind=health"
refix_attempted 20 shaB review && fail "(5) a health bounce must NOT satisfy the review once-guard"
grep -q '"event":"health_refix_bounce"' "$JOURNAL_FILE" || fail "(5) the bounce must be journaled"
ok

# ── (3) refix-once per sha: the SAME red re-enters every tick → no second bounce, honest row ─────
_handle_health_codeerror 20 slug-a shaB 0 "$T/wt" "$NOTOK"
[ "$(runs)" = "1" ] || fail "(3) a second call for the same sha must not re-bounce (got $(runs) runs)"
row | grep -q 'needs you' && fail "(3) 'needs you' is BANNED after a bounce (got: $(row))"
row | grep -q 'fix in progress · awaiting push (round 1/3)' \
  || fail "(3) the bounced row must read 'fix in progress · awaiting push (round 1/3)' (got: $(row))"
ok
# A NEW commit (new sha) is eligible for a fresh bounce.
printf '0\n' > "$STUB_WAIT_FILE"
_handle_health_codeerror 20 slug-a shaC 0 "$T/wt" "$NOTOK"
[ "$(runs)" = "2" ] || fail "(3) a new sha must be eligible for a fresh bounce (got $(runs))"
ok

# ── (6)+(7) SHARED budget with the review refix, then the cap escalates ─────────────────────────
reset_state
export REFIX_MAX_ROUNDS=3
record_refix 30 shaR1 slug-a review      # two REVIEW bounces already spent on this PR …
record_refix 30 shaR2 slug-a review
[ "$(refix_round_count 30)" = "2" ] || fail "(6) the budget must count review bounces"
printf '0\n' > "$STUB_WAIT_FILE"
_handle_health_codeerror 30 slug-a shaH1 0 "$T/wt" "$NOTOK"   # … the health bounce spends the 3rd
[ "$(runs)" = "1" ] || fail "(6) the third round should still bounce (got $(runs))"
[ "$(refix_round_count 30)" = "3" ] || fail "(6) review + health bounces must share ONE per-PR budget"
_handle_health_codeerror 30 slug-a shaH2 0 "$T/wt" "$NOTOK"   # 4th → over cap
[ "$(runs)" = "1" ] || fail "(7) a bounce past the cap must not be delivered (got $(runs))"
row | grep -q 'needs you · refix limit (3 rounds) reached' || fail "(7) the cap row must read 'needs you · refix limit' (got: $(row))"
row | grep -q "$NOTOK" || fail "(7) the cap row must still carry the blocker"
grep -q '"event":"health_refix_escalated"' "$JOURNAL_FILE" || fail "(7) the cap must journal an escalation"
ok

# ── (8) a tab-leak-guard CODE ERROR is INFRA: never bounced ─────────────────────────────────────
reset_state
printf '0\n' > "$STUB_WAIT_FILE"
_handle_health_codeerror 40 slug-a shaLEAK 0 "$T/wt" "❌ tab-leak-guard: 1 unexpected tab"
[ "$(runs)" = "0" ] || fail "(8) a tab-leak-guard transient must never bounce a builder"
[ "$(refix_round_count 40)" = "0" ] || fail "(8) a tab-leak-guard transient must not consume a round"
row | grep -q 'tab-leak-guard' || fail "(8) the leak-guard row must be preserved verbatim"
ok

# ── (9) dry-run never bounces ───────────────────────────────────────────────────────────────────
reset_state
DRYRUN=1 _handle_health_codeerror 50 slug-a shaD 0 "$T/wt" "$NOTOK"
[ "$(runs)" = "0" ] || fail "(9) dry-run must never bounce"
[ "$(refix_round_count 50)" = "0" ] || fail "(9) dry-run must not consume a round"
ok

# ── (9b) a DEAD agent escalates WITHOUT burning a round ─────────────────────────────────────────
reset_state
STUB_LIVENESS=dead _handle_health_codeerror 55 slug-a shaDEAD 0 "$T/wt" "$NOTOK"
[ "$(runs)" = "0" ] || fail "(9b) a dead agent must never be typed at"
[ "$(refix_round_count 55)" = "0" ] || fail "(9b) a dead-agent escalation must not burn a refix round"
row | grep -q 'agent dead' || fail "(9b) the dead row must say so (got: $(row))"
ok

# ── (9c) the agent never wakes → the bounce ESCALATES (loudly, once) instead of silently claiming a fix
reset_state
printf '1\n1\n' > "$STUB_WAIT_FILE"          # neither the initial submit nor the re-send wakes it
_handle_health_codeerror 56 slug-a shaNOWAKE 0 "$T/wt" "$NOTOK"
[ "$(runs)" = "2" ] || fail "(9c) a non-waking agent must be re-sent exactly once (got $(runs))"
row | grep -q 'needs you · health autofix failed' || fail "(9c) a failed wake must escalate (got: $(row))"
python3 - "$JOURNAL_FILE" <<'PY2' || fail "(9c) the failed wake must be journaled escalated=true"
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
w=[r for r in rows if r.get("event")=="health_refix_wake_result" and str(r.get("pr"))=="56"]
assert w and str(w[-1].get("woke"))=="0" and str(w[-1].get("escalated"))=="true", w
PY2
ok

# ── (9d) an ENV-TOLERATED outcome (a data/env warning, exit 0) NEVER bounces — only CODEERROR does ──
reset_state
DATAENV="$T/body-dataenv.txt"; printf '⚠️  DATA/ENV ISSUE (tolerated, not a code bug)\nshellcheck not installed\n' > "$DATAENV"
HC_BODY_FILE="$DATAENV" HC_RC=0
export HC_BODY_FILE HC_RC
drive 60 slug-a shaDATAENV
[ "$_HC_RESULT" = "CLEAN" ] || fail "(9d) a tolerated data/env outcome must collect CLEAN (got '$_HC_RESULT')"
[ "$(runs)" = "0" ] || fail "(9d) a data/env outcome must NEVER bounce a builder"
[ "$(refix_round_count 60)" = "0" ] || fail "(9d) a data/env outcome must not consume a refix round"
ok

# ── (10) _health_fail_detail: TAP → first not-ok; non-TAP → the error UNDER the banner ──────────
TAP="$T/tap.log"; printf '1..3\nok 1 setup\n%s\nok 3 teardown\n' "$NOTOK" > "$TAP"
[ "$(_health_fail_detail "$TAP")" = "$NOTOK" ] || fail "(10) TAP log must yield the first not-ok line (got: $(_health_fail_detail "$TAP"))"
# An INDENTED not-ok (a nested bats stream) is still found.
ITAP="$T/itap.log"; printf '1..1\n   %s\n' "$NOTOK" > "$ITAP"
[ "$(_health_fail_detail "$ITAP")" = "$NOTOK" ] || fail "(10) an indented not-ok must still be found"
# Non-TAP: healthcheck.sh prints its classifier banner first, then the real error. The banner is
# content-free — the detail must be the error line, not the banner (the last #289 leftover).
NT="$T/nontap.log"; printf '❌ CODE ERROR\nscripts/herd/foo.sh: line 12: syntax error near unexpected token\n' > "$NT"
d="$(_health_fail_detail "$NT")"
case "$d" in "❌ CODE ERROR"*) fail "(10) the detail must not be the content-free banner (got: $d)" ;; esac
printf '%s' "$d" | grep -q 'syntax error' || fail "(10) the non-TAP detail must name the error (got: $d)"
# Nothing quotable at all → the banner is better than an empty row.
ONLY="$T/only.log"; printf '❌ CODE ERROR\n' > "$ONLY"
[ -n "$(_health_fail_detail "$ONLY")" ] || fail "(10) a bannerless fallback must never be empty"
ok

# ── (11) END-TO-END through the real gate: forced CODEERROR + autofix on ────────────────────────
BODY="$T/body-fail.txt"; printf '1..3\nok 1 setup\n%s\nok 3 teardown\n' "$NOTOK" > "$BODY"
export HC_BODY_FILE="$BODY" HC_RC=1

# OFF-MODE: the gate still holds the PR red, nothing is bounced, no round is consumed.
reset_state
export HEALTHCHECK_AUTOFIX=false
printf '0\n0\n' > "$STUB_WAIT_FILE"
drive 70 slug-a shae2eoff
[ "$_HC_RESULT" = "CODEERROR" ] || fail "(11) off-mode: the gate must still return CODEERROR (got '$_HC_RESULT')"
[ "$(runs)" = "0" ] || fail "(11) off-mode: no bounce may be delivered"
[ "$(refix_round_count 70)" = "0" ] || fail "(11) off-mode: no round may be consumed"
row | grep -q 'needs you' || fail "(11) off-mode: an unattended red reads 'needs you' (got: $(row))"
ok

# ON: the collect tick bounces; the NEXT tick replays the shaCache and reads fix-in-progress.
reset_state
export HEALTHCHECK_AUTOFIX=true
printf '0\n0\n' > "$STUB_WAIT_FILE"
drive 71 slug-a shae2eon
[ "$_HC_RESULT" = "CODEERROR" ] || fail "(11) on-mode: the gate still returns CODEERROR (never merges a red)"
[ "$(runs)" = "1" ] || fail "(11) on-mode: the collect tick must deliver exactly one bounce (got $(runs))"
grep -q "$NOTOK" "$STUB_PANE_RUN_LOG" || fail "(11) the bounce prompt must quote the FIRST not-ok line"
_HC_RESULT=""; DISPLAY=()
_healthcheck_gate 71 slug-a "$T/wt" 0 shae2eon              # next tick: shaCache replay
[ "$_HC_RESULT" = "CODEERROR" ] || fail "(11) the cached red must stay red (got '$_HC_RESULT')"
[ "$(runs)" = "1" ] || fail "(11) the cache replay must not re-bounce"
row | grep -q 'needs you' && fail "(11) the cached row must not lie with 'needs you' (got: $(row))"
row | grep -q 'fix in progress · awaiting push (round 1/3)' \
  || fail "(11) the cached row must read fix-in-progress (got: $(row))"
ok

echo "ALL PASS ($pass checks)"
