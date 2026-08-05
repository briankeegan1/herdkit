#!/usr/bin/env bash
# test-health-env-suspect.sh — hermetic tests for HERD-546 (HERD-539 leg 3): a per-test health-suite
# TIMEOUT observed while the box is under load must classify as env-suspect, never a bare code red.
#
# Covers:
#   (1) unit: _health_timeout_detail recognizes both TIMEOUT conventions (bats TAP "# timeout after
#       Ns" and run-suite.sh's "(TIMEOUT after Ns)"), and rejects an ordinary failure line
#   (2) unit: _health_load_high — ENV_SUSPECT_TIMEOUT=off is always false regardless of load;
#       on + loadavg >= HEALTH_LOAD_THRESHOLD is true; on + a live sibling .local-suite-slot-* marker
#       is true even at loadavg 0; on + quiet box + no siblings is false
#   (3) unit: _health_env_suspect_marker reads back the exact render fragment from a log line
#   (4) integration (high load, solo pass): _health_worker on a timeout fixture under high load
#       still invokes the stub exactly twice (queues ONE solo re-run), the live log carries the
#       env-suspect marker, the shared red-ledger records + then CLEARS the note, and the verdict is
#       FLAKY — "solo pass clears"
#   (5) integration (high load, solo fail): the SAME fixture, but the solo retry reproduces the
#       timeout — verdict is CODEERROR (a plain code red, "solo fail reds"), and the red-ledger note
#       survives, updated to say the solo re-run also failed; health_env_suspect is journaled
#   (6) integration (low load): the identical timeout fixture with ENV_SUSPECT_TIMEOUT=off (no load
#       signal armed) — no marker, no ledger row, no journal event; verdict resolves via the ORDINARY
#       retry-before-red exactly as before this file existed — "low-load timeout stays code-red"
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1), the same harness test-health-retry-
# targeted.sh and test-red-ledger.sh already use. Network-free (gh/git/herdr stubbed); HERD_FAKE_NOW
# and HERD_FAKE_LOADAVG pin the clock and the load signal so nothing here depends on the real box.
# Run:  bash tests/test-health-env-suspect.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"

[ -f "$WATCH" ] || { echo "FAIL: agent-watch.sh not found at $WATCH" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf 'ok — %s\n' "$1"; }

# ── Stub binaries on PATH (network-free) ─────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
export PATH="$BIN:$PATH"

if [ -f "$REPO/scripts/herd/hermetic-env-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$REPO/scripts/herd/hermetic-env-scrub.sh"
  herd_hermetic_env_scrub "$REPO/scripts/herd/herd-config.sh"
fi

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
NOW=1700000000
export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=headless
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_FAKE_NOW="$NOW"
unset HERD_FAKE_LOADAVG ENV_SUSPECT_TIMEOUT HEALTH_LOAD_THRESHOLD
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }
TREES="$WORKTREES_DIR"
MAIN="$T/main"; mkdir -p "$MAIN"

for fn in _health_timeout_detail _health_load_high _health_loadavg_1m _health_sibling_suites_live \
          _health_env_suspect_marker _env_suspect_enabled _health_worker; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
reset_journal() { : > "$JOURNAL_FILE"; }

# ── (1) unit: _health_timeout_detail ─────────────────────────────────────────────────────────────
d="$(_health_timeout_detail 'not ok 2 hermetic test-cli-reload.sh (dynamic) # timeout after 120s')"
[[ "$d" == *"# timeout after 120s"* ]] || fail "(1) bats TAP timeout suffix not recognized: $d"
ok "(1a) bats TAP '# timeout after Ns' recognized"

d="$(_health_timeout_detail '❌ FAIL test-cli-reload.sh (TIMEOUT after 180s)')"
[[ "$d" == *"(TIMEOUT after 180s)"* ]] || fail "(1) run-suite.sh timeout suffix not recognized: $d"
ok "(1b) run-suite.sh '(TIMEOUT after Ns)' recognized"

d="$(_health_timeout_detail 'not ok 3 hermetic test-foo.sh (dynamic)')"
[ -z "$d" ] || fail "(1) an ordinary (non-timeout) failure must not match: $d"
ok "(1c) an ordinary failure line does not match"

# ── (2) unit: _health_load_high ──────────────────────────────────────────────────────────────────
ENV_SUSPECT_TIMEOUT=off HERD_FAKE_LOADAVG=99 _health_load_high && fail "(2a) off must be false regardless of load"
ok "(2a) ENV_SUSPECT_TIMEOUT=off is always false, even at loadavg 99"

ENV_SUSPECT_TIMEOUT=on HEALTH_LOAD_THRESHOLD=4 HERD_FAKE_LOADAVG=5.2 _health_load_high \
  || fail "(2b) loadavg 5.2 >= threshold 4 should read high"
ok "(2b) loadavg at/over HEALTH_LOAD_THRESHOLD reads high"

ENV_SUSPECT_TIMEOUT=on HEALTH_LOAD_THRESHOLD=4 HERD_FAKE_LOADAVG=0.5 _health_load_high \
  && fail "(2c) loadavg 0.5 with no sibling slot should read quiet"
ok "(2c) a quiet loadavg with no sibling slot reads NOT high"

: > "$TREES/.local-suite-slot-1"
{ printf '%s\n' "$$"; printf '%s\n' "sometime"; printf '%s\n' "$NOW"; } > "$TREES/.local-suite-slot-1"
ENV_SUSPECT_TIMEOUT=on HEALTH_LOAD_THRESHOLD=4 HERD_FAKE_LOADAVG=0.5 _health_load_high \
  || fail "(2d) a live sibling local-suite slot should read high even at loadavg 0.5"
ok "(2d) a live HERD-529 sibling local-suite slot reads high regardless of loadavg"
rm -f "$TREES/.local-suite-slot-1"

# ── (3) unit: _health_env_suspect_marker ─────────────────────────────────────────────────────────
MLOG="$T/marker.log"
printf 'not ok 2 hermetic test-x.sh (dynamic)\n' > "$MLOG"
[ -z "$(_health_env_suspect_marker "$MLOG")" ] || fail "(3) a log with no marker line must read empty"
printf '[env-suspect] %s\n' "$_HEALTH_ENV_SUSPECT_TEXT" >> "$MLOG"
[ "$(_health_env_suspect_marker "$MLOG")" = "$_HEALTH_ENV_SUSPECT_TEXT" ] \
  || fail "(3) marker text did not round-trip"
[[ "$(_health_inflight_note "$MLOG")" == *"env-suspect · timeout under load · solo re-run queued"* ]] \
  || fail "(3) _health_inflight_note did not surface the marker text"
ok "(3) the env-suspect marker round-trips through _health_inflight_note"

# ── Scripted stub healthcheck (stands in for healthcheck.sh via HERD_HEALTHCHECK_BIN) ────────────────
STUB_HC="$T/stub-healthcheck.sh"
cat > "$STUB_HC" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB_HC_LOG"
n="$(cat "$STUB_HC_N" 2>/dev/null || echo 0)"; n=$((n+1)); printf '%s\n' "$n" > "$STUB_HC_N"
if [ "$n" -le 1 ]; then
  cat "$STUB_HC_OUT1" 2>/dev/null
  exit "$(cat "$STUB_HC_RC1" 2>/dev/null || echo 1)"
else
  cat "$STUB_HC_OUT2" 2>/dev/null
  exit "$(cat "$STUB_HC_RC2" 2>/dev/null || echo 0)"
fi
STUB
chmod +x "$STUB_HC"
export HERD_HEALTHCHECK_BIN="$STUB_HC"
export STUB_HC_LOG="$T/hc-invocations.log"
export STUB_HC_N="$T/hc-n"
export STUB_HC_OUT1="$T/hc-out1"
export STUB_HC_RC1="$T/hc-rc1"
export STUB_HC_OUT2="$T/hc-out2"
export STUB_HC_RC2="$T/hc-rc2"

TIMEOUT_TAP='❌ CODE ERROR
BATS FAILED
1..3
ok 1 hermetic test-alpha.sh (dynamic)
not ok 2 hermetic test-cli-reload.sh (dynamic) # timeout after 120s
ok 3 hermetic test-gamma.sh (dynamic)'

reset_stub() {
  rm -f "$STUB_HC_LOG" "$STUB_HC_N"; : > "$STUB_HC_LOG"
  printf '%s\n' "$TIMEOUT_TAP" > "$STUB_HC_OUT1"; printf '1\n' > "$STUB_HC_RC1"
}

LEDGER="$T/red-ledger"

# ── (4) HIGH LOAD, solo pass → env-suspect renders + queues ONE solo re-run + FLAKY + ledger clears ──
rm -f "$LEDGER"; reset_journal
export ENV_SUSPECT_TIMEOUT=on HEALTH_LOAD_THRESHOLD=4 HERD_FAKE_LOADAVG=9 RED_LEDGER=on
export RED_LEDGER_FILE="$LEDGER"
reset_stub
printf '✅ HEALTHCHECK CLEAN\n' > "$STUB_HC_OUT2"; printf '0\n' > "$STUB_HC_RC2"   # solo retry PASSES
DISP="$T/disp-pass"; LOG="$T/log-pass"; rm -f "$DISP" "$LOG"
_health_worker "$T/wt-pass" "$DISP" "$LOG"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "(4) should invoke the stub exactly twice (initial + ONE queued solo re-run)"
ok "(4a) exactly ONE automatic solo re-run is queued"
grep -qF "[env-suspect] $_HEALTH_ENV_SUSPECT_TEXT" "$LOG" \
  || fail "(4) the live log must carry the env-suspect marker while the solo retry is queued"
ok "(4b) the running row's marker ('env-suspect · timeout under load · solo re-run queued') was written"
IFS=$'\t' read -r verdict detail < "$DISP"
[ "$verdict" = "FLAKY" ] || fail "(4) a passing solo retry must still yield FLAKY (got '$verdict')"
ok "(4c) solo pass clears — verdict is FLAKY"
KEY="env_suspect:wt-pass"
[ -z "$(herd_red_ledger_get "$LEDGER" "$KEY")" ] \
  || fail "(4) the env-suspect ledger row should be CLEARED once the solo retry passed"
ok "(4d) the shared red-ledger note is cleared on a passing solo retry"
[ "$(jcount health_env_suspect)" -ge 1 ] || fail "(4) health_env_suspect must be journaled"
ok "(4e) health_env_suspect is journaled"

# ── (5) HIGH LOAD, solo fail → still ONE solo re-run, CODEERROR (plain code red), ledger survives ────
rm -f "$LEDGER"; reset_journal
reset_stub
printf '%s\n' "$TIMEOUT_TAP" > "$STUB_HC_OUT2"; printf '1\n' > "$STUB_HC_RC2"     # solo retry FAILS (reproduced)
DISP="$T/disp-fail"; LOG="$T/log-fail"; rm -f "$DISP" "$LOG"
_health_worker "$T/wt-fail" "$DISP" "$LOG"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "(5) a reproduced timeout must still invoke the stub exactly twice — never a third retry"
ok "(5a) exactly ONE automatic solo re-run is queued even when it will fail"
IFS=$'\t' read -r verdict detail < "$DISP"
[ "$verdict" = "CODEERROR" ] || fail "(5) a reproduced solo-retry failure must yield CODEERROR (got '$verdict')"
ok "(5b) solo fail reds — verdict is a plain CODEERROR"
KEY="env_suspect:wt-fail"
ROW="$(herd_red_ledger_get "$LEDGER" "$KEY")"
[ -n "$ROW" ] || fail "(5) the env-suspect ledger note should survive a reproduced failure (as diagnostic history)"
case "$ROW" in *"also failed"*) ;; *) fail "(5) the surviving note should say the solo re-run also failed: $ROW" ;; esac
ok "(5c) the red-ledger note survives, updated to record the solo re-run also failed"
[ "$(jcount health_env_suspect)" -ge 1 ] || fail "(5) health_env_suspect must be journaled"
ok "(5d) health_env_suspect is journaled"

# ── (6) LOW LOAD (ENV_SUSPECT_TIMEOUT off) → byte-identical to the ordinary retry-before-red path ────
rm -f "$LEDGER"; reset_journal
export ENV_SUSPECT_TIMEOUT=off
unset HERD_FAKE_LOADAVG
reset_stub
printf '%s\n' "$TIMEOUT_TAP" > "$STUB_HC_OUT2"; printf '1\n' > "$STUB_HC_RC2"     # solo retry FAILS (reproduced)
DISP="$T/disp-low"; LOG="$T/log-low"; rm -f "$DISP" "$LOG"
_health_worker "$T/wt-low" "$DISP" "$LOG"
[ "$(wc -l < "$STUB_HC_LOG")" -eq 2 ] || fail "(6) the ordinary retry-before-red invariant (exactly 2 invocations) must still hold"
ok "(6a) the ordinary retry-before-red invariant is unchanged"
IFS=$'\t' read -r verdict detail < "$DISP"
[ "$verdict" = "CODEERROR" ] || fail "(6) low-load timeout must still resolve to a plain CODEERROR (got '$verdict')"
ok "(6b) low-load timeout stays code-red"
grep -qF '[env-suspect]' "$LOG" && fail "(6) no env-suspect marker may appear while the lever is off"
ok "(6c) no env-suspect marker is written while ENV_SUSPECT_TIMEOUT is off"
[ -z "$(herd_red_ledger_get "$LEDGER" "env_suspect:wt-low")" ] \
  || fail "(6) no red-ledger row may be written while the lever is off"
ok "(6d) no red-ledger row is written while ENV_SUSPECT_TIMEOUT is off"
[ "$(jcount health_env_suspect)" -eq 0 ] || fail "(6) health_env_suspect must NOT be journaled while the lever is off"
ok "(6e) health_env_suspect is not journaled while ENV_SUSPECT_TIMEOUT is off"

echo "ALL PASS ($pass checks) — HERD-546 (HERD-539 leg 3): a per-test TIMEOUT under load renders env-suspect and queues exactly ONE solo re-run (a pass clears the note, a fail still reds); a low-load timeout is byte-identical to the pre-existing retry-before-red path."
