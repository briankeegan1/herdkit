#!/usr/bin/env bash
# test-health-worker-progress-log.sh — hermetic proof for HERD-533 leg 1 on the PYTHON dispatch path.
#
# pysrc/herd/live_runtime.py's _HEALTH_WORKER_SH is the ASYNC worker the (sole) Python engine core
# dispatches for every candidate health run — the one that matters live. Before this change it never
# set HEALTHCHECK_PROGRESS_LOG, so even after healthcheck.sh itself learned to tee its suite's output
# through that variable (test-healthcheck-progress-stream.sh), the python path stayed completely dark:
# the var was never passed, so healthcheck.sh's tee target was always /dev/null on a REAL dispatch.
#
# This proves _run() now:
#   (1) exports HEALTHCHECK_PROGRESS_LOG="<log>.progress" to the healthcheck.sh child, truncated fresh
#       for the run — so a genuinely third-party child (not the same process) observably receives it;
#   (2) on a CLEAN first run, the companion carries that run's content and the verdict line is
#       UNCHANGED ("<nonce>\tCLEAN\tclean");
#   (3) on FLAKY (run 1 code-errors, the solo retry passes), the retry's companion + raw retry log are
#       both cleaned up (no orphaned .retry/.retry.progress files) and the verdict line is unchanged;
#   (4) on a REPRODUCED code error, the retry's companion is RENAMED onto "<log>.progress" (so the
#       reader always sees the companion for whichever attempt is now the live "$log") in lockstep
#       with the existing "$log.retry" -> "$log" rename, and the verdict line is unchanged.
#
# Extracts the real _HEALTH_WORKER_SH constant from the shipped module (never a hand-copied string) so
# this test rots the instant the two drift. Fully hermetic: python3 stdlib + bash only, no network.
# Run:  bash tests/test-health-worker-progress-log.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$REPO/pysrc/herd/live_runtime.py" ] || { echo "FAIL: pysrc/herd/live_runtime.py not found" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

WORKER="$T/worker.sh"
PYTHONPATH="$REPO/pysrc" python3 -c "
from herd import live_runtime as LR
import sys
sys.stdout.write(LR._HEALTH_WORKER_SH)
" > "$WORKER" || fail "could not extract _HEALTH_WORKER_SH from live_runtime.py"
[ -s "$WORKER" ] || fail "_HEALTH_WORKER_SH extracted empty"

# A stand-in "healthcheck.sh": records HEALTHCHECK_PROGRESS_LOG (if any) into it, bumps a shared
# attempt counter, and behaves per FAKE_HC_MODE — clean | flaky (fails once, then passes) | red
# (always fails).
FAKE_HC="$T/fake-hc.sh"
cat > "$FAKE_HC" <<'EOF'
#!/usr/bin/env bash
n=0
[ -f "$FAKE_HC_COUNTFILE" ] && n="$(cat "$FAKE_HC_COUNTFILE")"
n=$((n + 1))
printf '%s\n' "$n" > "$FAKE_HC_COUNTFILE"
if [ -n "${HEALTHCHECK_PROGRESS_LOG:-}" ]; then
  printf 'progress-from-attempt-%s\n' "$n" >> "$HEALTHCHECK_PROGRESS_LOG"
fi
case "${FAKE_HC_MODE:-clean}" in
  clean) printf '✅ HEALTHCHECK CLEAN\n'; exit 0 ;;
  flaky) if [ "$n" -eq 1 ]; then printf '❌ CODE ERROR\nnot ok 1 flaky-thing\n'; exit 1; else printf '✅ HEALTHCHECK CLEAN\n'; exit 0; fi ;;
  red)   printf '❌ CODE ERROR\nnot ok 1 attempt-%s\n' "$n"; exit 1 ;;
esac
EOF
chmod +x "$FAKE_HC"

run_worker() {  # run_worker <log-path> <nonce>
  # bash <file> arg1 arg2 … sets $0 to <file> itself — unlike the live `bash -c "$SCRIPT" _ hc dir …`
  # invocation (where "_" is a placeholder $0 for the -c form), so no leading placeholder here.
  bash "$WORKER" "$FAKE_HC" "$T/dummy-dir" "$T/out-$2" "$1" "$T/base" "$T/cache" "$2"
}

# ── (1)+(2) CLEAN: env var forwarded, companion carries the run, verdict unchanged ──────────────────
export FAKE_HC_MODE=clean FAKE_HC_COUNTFILE="$T/count-clean"
LOG1="$T/log-clean"
run_worker "$LOG1" nonce-clean
[ -f "$LOG1.progress" ] || fail "(1) no <log>.progress companion was created — HEALTHCHECK_PROGRESS_LOG was never forwarded"
grep -q 'progress-from-attempt-1' "$LOG1.progress" \
  || fail "(1) the child never actually observed HEALTHCHECK_PROGRESS_LOG: $(cat "$LOG1.progress" 2>/dev/null)"
[ "$(cat "$T/out-nonce-clean")" = "$(printf 'nonce-clean\tCLEAN\tclean')" ] \
  || fail "(2) CLEAN verdict line regressed: $(cat "$T/out-nonce-clean")"
ok

# ── (3) FLAKY: retry succeeds, no orphaned .retry / .retry.progress, verdict unchanged ──────────────
export FAKE_HC_MODE=flaky FAKE_HC_COUNTFILE="$T/count-flaky"
LOG2="$T/log-flaky"
run_worker "$LOG2" nonce-flaky
[ -f "$LOG2.progress" ] || fail "(3) run-1 companion missing for the flaky case"
grep -q 'progress-from-attempt-1' "$LOG2.progress" || fail "(3) run-1 companion missing its content"
[ -e "$LOG2.retry" ] && fail "(3) the raw retry log was not cleaned up on a FLAKY resolution"
[ -e "$LOG2.retry.progress" ] && fail "(3) the retry's progress companion was not cleaned up on a FLAKY resolution (orphaned tmp file)"
[ "$(cat "$T/out-nonce-flaky")" = "$(printf 'nonce-flaky\tFLAKY\tnot ok 1 flaky-thing')" ] \
  || fail "(3) FLAKY verdict line regressed: $(cat "$T/out-nonce-flaky")"
ok

# ── (4) REPRODUCED CODE ERROR: retry's companion is renamed onto <log>.progress, verdict unchanged ──
export FAKE_HC_MODE=red FAKE_HC_COUNTFILE="$T/count-red"
LOG3="$T/log-red"
run_worker "$LOG3" nonce-red
[ -e "$LOG3.retry" ] && fail "(4) \$log.retry must be renamed onto \$log (existing mv), not left behind"
[ -e "$LOG3.retry.progress" ] && fail "(4) \$log.retry.progress must be renamed onto \$log.progress, not left behind"
[ -f "$LOG3.progress" ] || fail "(4) the surviving companion (post-rename) is missing"
grep -q 'progress-from-attempt-2' "$LOG3.progress" \
  || fail "(4) the LIVE companion after a reproduced failure must be the RETRY's (attempt 2), not run 1's: $(cat "$LOG3.progress" 2>/dev/null)"
grep -q 'not ok 1 attempt-2' "$LOG3" || fail "(4) \$log must carry the retry's (reproduced) content: $(cat "$LOG3")"
[ "$(cat "$T/out-nonce-red")" = "$(printf 'nonce-red\tCODEERROR\tnot ok 1 attempt-2')" ] \
  || fail "(4) CODEERROR verdict line regressed: $(cat "$T/out-nonce-red")"
ok

echo "ALL PASS ($pass checks) — the Python dispatch path forwards HEALTHCHECK_PROGRESS_LOG per attempt and the CLEAN/FLAKY/CODEERROR verdict contract is unchanged."
