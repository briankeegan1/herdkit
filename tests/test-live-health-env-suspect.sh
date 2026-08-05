#!/usr/bin/env bash
# test-live-health-env-suspect.sh — HERD-567 runtime-proof fixture: ENV_SUSPECT_TIMEOUT /
# HEALTH_LOAD_THRESHOLD, re-hung onto the LIVE health worker after HERD-556's lever-reachability
# lint found their only pre-existing consumers (agent-watch.sh's _health_worker) dead since the P5b
# engine port (nothing calls _healthcheck_gate anymore — see tests/lever-reachability-exempt.tsv's
# now-removed baseline rows for the finding this closes).
#
# Unlike tests/test-health-env-suspect.sh (which still proves the ORIGINAL, unreachable bash
# _health_worker's own unit behavior — that function still exists and is still directly testable,
# it just never runs in production), this file drives the ACTUAL production worker:
# pysrc/herd/live_runtime.py's _HEALTH_WORKER_SH, the exact bash string LiveGates._dispatch_health /
# _dispatch_merge_result subprocess.Popen's for every real PR health gate under the shipped python
# engine. Extracted verbatim (no re-typing, so this can never drift from what ships) and run for
# real — a genuine two-process bash execution, not a sourced-function unit test.
#
# Covers:
#   (1) HIGH LOAD, solo pass: a run-1 timeout under contention appends the '[env-suspect] …' marker
#       to the live log (BEFORE the retry — the render half's window), drops the `.envsuspect`
#       side-channel detail file, invokes the stub healthcheck EXACTLY twice (queues ONE solo
#       re-run — never zero, never more), and settles on <nonce>\tFLAKY\t… once the retry passes.
#   (2) HIGH LOAD, solo fail: the identical fixture, but the retry reproduces the timeout — verdict
#       is CODEERROR, the log is the retry's own output (the marker is transient — this proves it),
#       and the `.envsuspect` side-channel SURVIVES (diagnostic history for the python collector to
#       journal even though the run still reds).
#   (3) LOW LOAD: ENV_SUSPECT_TIMEOUT=on but loadavg under threshold and no live sibling — no
#       marker, no side-channel file; verdict resolves via the ordinary retry-before-red exactly as
#       before this lever existed.
#   (4) LEVER OFF: ENV_SUSPECT_TIMEOUT unset, loadavg pinned high (99) — byte-identical to (3): no
#       marker, no side-channel file, even though load alone would have qualified.
#
# Run:  bash tests/test-live-health-env-suspect.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PYSRC="$REPO/pysrc"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf 'ok — %s\n' "$1"; }

# ── Extract the EXACT live worker script — never re-typed, so this can't drift from what ships ─────
WORKER="$T/health-worker.sh"
PYTHONPATH="$PYSRC" python3 -c '
import sys
from herd.live_runtime import _HEALTH_WORKER_SH
sys.stdout.write(_HEALTH_WORKER_SH)
' > "$WORKER" || fail "could not import _HEALTH_WORKER_SH from pysrc/herd/live_runtime.py"
[ -s "$WORKER" ] || fail "_HEALTH_WORKER_SH extracted empty"

# ── Scripted stub standing in for healthcheck.sh (the worker's $1) ─────────────────────────────────
# Counts its own invocations to a state file so a scenario can assert EXACTLY how many suite runs
# fired (never zero, never more than the ONE solo retry this lever must not change).
STUB_HC="$T/stub-healthcheck.sh"
cat > "$STUB_HC" <<'STUB'
#!/usr/bin/env bash
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
export STUB_HC_N="$T/hc-n"
export STUB_HC_OUT1="$T/hc-out1" STUB_HC_RC1="$T/hc-rc1"
export STUB_HC_OUT2="$T/hc-out2" STUB_HC_RC2="$T/hc-rc2"

TIMEOUT_TAP='❌ CODE ERROR
BATS FAILED
1..3
ok 1 hermetic test-alpha.sh (dynamic)
not ok 2 hermetic test-cli-reload.sh (dynamic) # timeout after 120s
ok 3 hermetic test-gamma.sh (dynamic)'
PASS_TAP='1..3
ok 1 hermetic test-alpha.sh (dynamic)
ok 2 hermetic test-cli-reload.sh (dynamic)
ok 3 hermetic test-gamma.sh (dynamic)'

reset_stub() {
  rm -f "$STUB_HC_N"
  printf '%s\n' "$TIMEOUT_TAP" > "$STUB_HC_OUT1"; printf '1\n' > "$STUB_HC_RC1"
}

WORKTREE="$T/tree-envsuspect-verify"; mkdir -p "$WORKTREE"
BASE="$T/main"; mkdir -p "$BASE"
CACHE="$T/trees"; mkdir -p "$CACHE"
NONCE="1700000000.4242"

run_worker() {
  local out="$1" log="$2"
  # Positional contract mirrors _dispatch_health's real invocation minus the leading "_" $0
  # placeholder (only needed for `bash -c SCRIPT "_" …`; running the extracted file directly, $1
  # IS healthcheck.sh — see _HEALTH_WORKER_SH's own docstring for the full arg list).
  bash "$WORKER" "$STUB_HC" "$WORKTREE" "$out" "$log" "$BASE" "$CACHE" "$NONCE"
}

# ── (1) HIGH LOAD, solo pass ────────────────────────────────────────────────────────────────────
reset_stub
printf '%s\n' "$PASS_TAP" > "$STUB_HC_OUT2"; printf '0\n' > "$STUB_HC_RC2"
OUT="$T/out1"; LOG="$T/log1"
ENV_SUSPECT_TIMEOUT=on HEALTH_LOAD_THRESHOLD=4 HERD_FAKE_LOADAVG=9 run_worker "$OUT" "$LOG"

grep -qF "[env-suspect] env-suspect · timeout under load · solo re-run queued" "$LOG" \
  || fail "(1) live log must carry the env-suspect marker"
ok "(1a) high-load timeout renders the env-suspect marker on the live log"

[ -f "$LOG.envsuspect" ] || fail "(1) the .envsuspect side-channel file must exist"
grep -qF "timeout after 120s" "$LOG.envsuspect" || fail "(1) side-channel detail missing the timeout text"
ok "(1b) the .envsuspect side-channel carries the timeout detail for the python collector"

[ "$(cat "$STUB_HC_N")" = "2" ] || fail "(1) expected EXACTLY 2 healthcheck invocations (1 + ONE solo retry), got $(cat "$STUB_HC_N")"
ok "(1c) exactly ONE solo re-run was queued (2 total suite invocations, never 1, never 3+)"

grep -qF "$(printf '%s\tFLAKY\t' "$NONCE")" "$OUT" || fail "(1) expected a FLAKY verdict, got: $(cat "$OUT")"
ok "(1d) a passing solo retry still resolves FLAKY — the retry-before-red verdict logic is untouched"

# ── (2) HIGH LOAD, solo fail — marker is transient, side-channel survives ─────────────────────────
reset_stub
printf '%s\n' "$TIMEOUT_TAP" > "$STUB_HC_OUT2"; printf '1\n' > "$STUB_HC_RC2"
OUT="$T/out2"; LOG="$T/log2"
ENV_SUSPECT_TIMEOUT=on HEALTH_LOAD_THRESHOLD=4 HERD_FAKE_LOADAVG=9 run_worker "$OUT" "$LOG"

grep -qF "[env-suspect]" "$LOG" && fail "(2) a reproduced failure's own retry output must overwrite the transient marker"
ok "(2a) the env-suspect marker is transient — a reproduced failure's log is the retry's own output"

[ -f "$LOG.envsuspect" ] || fail "(2) the .envsuspect side-channel must SURVIVE a reproduced failure (diagnostic history)"
ok "(2b) the .envsuspect side-channel survives a reproduced failure, for the collector to journal"

[ "$(cat "$STUB_HC_N")" = "2" ] || fail "(2) expected EXACTLY 2 healthcheck invocations, got $(cat "$STUB_HC_N")"
ok "(2c) still exactly ONE solo re-run even when it reproduces"

grep -qF "$(printf '%s\tCODEERROR\t' "$NONCE")" "$OUT" || fail "(2) expected a CODEERROR verdict, got: $(cat "$OUT")"
ok "(2d) a reproducing solo retry still reds CODEERROR — unchanged"

# ── (3) LOW LOAD — no marker, no side-channel, ordinary retry-before-red ──────────────────────────
reset_stub
printf '%s\n' "$PASS_TAP" > "$STUB_HC_OUT2"; printf '0\n' > "$STUB_HC_RC2"
OUT="$T/out3"; LOG="$T/log3"
ENV_SUSPECT_TIMEOUT=on HEALTH_LOAD_THRESHOLD=4 HERD_FAKE_LOADAVG=0.5 run_worker "$OUT" "$LOG"

grep -qF "[env-suspect]" "$LOG" && fail "(3) a quiet box must never render the env-suspect marker"
[ -f "$LOG.envsuspect" ] && fail "(3) a quiet box must never drop the .envsuspect side-channel"
grep -qF "$(printf '%s\tFLAKY\t' "$NONCE")" "$OUT" || fail "(3) expected FLAKY (the ordinary retry-before-red path)"
ok "(3) a timeout under a quiet box (no load signal) is byte-identical to the pre-HERD-546 path"

# ── (4) LEVER OFF — byte-identical even though load alone would have qualified ────────────────────
reset_stub
printf '%s\n' "$PASS_TAP" > "$STUB_HC_OUT2"; printf '0\n' > "$STUB_HC_RC2"
OUT="$T/out4"; LOG="$T/log4"
unset ENV_SUSPECT_TIMEOUT
HEALTH_LOAD_THRESHOLD=4 HERD_FAKE_LOADAVG=99 run_worker "$OUT" "$LOG"

grep -qF "[env-suspect]" "$LOG" && fail "(4) ENV_SUSPECT_TIMEOUT unset must never render the marker, even at loadavg 99"
[ -f "$LOG.envsuspect" ] && fail "(4) ENV_SUSPECT_TIMEOUT unset must never drop the .envsuspect side-channel"
ok "(4) the lever off is byte-identical no matter how contended the box looks"

echo "ALL PASS ($pass checks) — HERD-567: ENV_SUSPECT_TIMEOUT/HEALTH_LOAD_THRESHOLD re-hung onto the LIVE python-dispatched health worker (pysrc/herd/live_runtime.py's _HEALTH_WORKER_SH) — a real load-timeout under the live path renders the env-suspect marker and queues exactly ONE solo re-run, on both outcomes; a quiet box or the lever off stay byte-identical to the pre-HERD-546 retry-before-red path."
