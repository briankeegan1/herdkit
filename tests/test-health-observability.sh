#!/usr/bin/env bash
# test-health-observability.sh — hermetic proof of the health-run OBSERVABILITY seam (HERD-185 second
# addendum): the async health gate is no longer a black box. Drives the SHIPPED agent-watch.sh functions
# (sourced in AGENT_WATCH_LIB mode) with a stub healthcheck that emits a bats/TAP stream.
#
# Asserts:
#   (1) TEE — every health run streams its FULL output to a tailable $TREES/.health-log-<pr>-<sha>, and
#       the logs are rotated to the newest 5.
#   (2) PROGRESS — a running row shows elapsed AND, when the log is a TAP stream, live 'test X/Y' parsed
#       from the '1..N' plan + ok/not-ok count.
#   (3) HONEST FAILURE LABEL — the healthcheck_outcome detail quotes the FIRST 'not ok' TAP line (fixes
#       HERD-173's misleading 'ok NN' labels), and the ledger offender is the failing test file.
#   (4) STARTED EVENT — dispatch journals healthcheck_started (with log_path) so a run that never finishes
#       is visible in the record, not only a post-hoc outcome.
#
# Fully hermetic: temp dir, stubbed gh/git/herdr, headless driver, journal pinned into the sandbox.
# Run:  bash tests/test-health-observability.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# Stub healthcheck: cat the body file to stdout, exit $HC_RC. Emits a TAP stream so progress + the
# first-not-ok label are exercised end-to-end. Ignores flags (the worker runs it in full mode).
HC_STUB="$T/hc.sh"
cat > "$HC_STUB" <<'STUB'
#!/usr/bin/env bash
[ -n "${HC_BODY_FILE:-}" ] && [ -f "$HC_BODY_FILE" ] && cat "$HC_BODY_FILE"
exit "${HC_RC:-0}"
STUB
chmod +x "$HC_STUB"

export AGENT_WATCH_LIB=1 HERD_DRIVER=headless
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_HEALTHCHECK_BIN="$HC_STUB"
export HEALTH_CONCURRENCY=1
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render(){ :; }
# Hermetic seal (issue #144): journal writes must land in the sandbox.
case "$(_journal_file)" in "$T"/*) : ;; *) fail "journal escapes the sandbox: '$(_journal_file)' (issue #144)" ;; esac
TREES="$WORKTREES_DIR"

# drive <pr> <slug> <sha> — dispatch the async gate, await the worker's dispatch result, collect it.
drive(){
  local _p="$1" _s="$2" _sha="$3" _disp _n=0
  _HC_RESULT=""; DISPLAY=()
  _healthcheck_gate "$_p" "$_s" "$T/wt" 0 "$_sha"
  case "$_HC_RESULT" in CLEAN|FLAKY|CODEERROR|QUEUED) return 0 ;; esac
  _disp="$(_health_dispatch_file "${_p}-${_sha}")"
  while [ "$_n" -lt 500 ]; do [ -f "$_disp" ] && break; sleep 0.02; _n=$((_n + 1)); done
  _HC_RESULT=""; DISPLAY=()
  _healthcheck_gate "$_p" "$_s" "$T/wt" 0 "$_sha"
}
jhas(){ grep -q "$1" "$JOURNAL_FILE" 2>/dev/null; }

# ── (4) STARTED EVENT + (1) TEE — a clean TAP run journals healthcheck_started and leaves a log ──────
BODY_CLEAN="$T/body-clean.txt"; printf '1..2\nok 1 alpha\nok 2 beta\n' > "$BODY_CLEAN"
export HC_BODY_FILE="$BODY_CLEAN" HC_RC=0
drive 501 slug-clean shaCLEAN
[ "$_HC_RESULT" = "CLEAN" ] || fail "(4) clean TAP run should collect CLEAN (got '$_HC_RESULT')"
jhas '"event":"healthcheck_started"' || fail "(4) dispatch must journal healthcheck_started"
python3 - "$JOURNAL_FILE" <<'PY' || fail "(4) healthcheck_started must carry a log_path"
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
s=[r for r in rows if r.get("event")=="healthcheck_started"]
assert s and s[-1].get("log_path"), s
PY
LOG="$(_health_log_file "501-shaCLEAN")"
[ -f "$LOG" ] || fail "(1) the health run must leave a tailable log at $LOG"
grep -q 'ok 2 beta' "$LOG" || fail "(1) the log must carry the full suite output (TAP stream)"
ok

# ── (1b) ROTATION — only the newest 5 .health-log-* survive ──────────────────────────────────────
i=1; while [ "$i" -le 7 ]; do : > "$TREES/.health-log-rot-$i"; sleep 0.01; i=$((i + 1)); done
_rotate_health_logs
_nlogs="$(ls "$TREES"/.health-log-rot-* 2>/dev/null | grep -c .)"
[ "$_nlogs" -le 5 ] || fail "(1b) health logs must be rotated to the newest 5 (found $_nlogs)"
rm -f "$TREES"/.health-log-rot-* 2>/dev/null || true
ok

# ── (2) PROGRESS — a running row shows elapsed + 'test X/Y' parsed from the live TAP log ─────────────
# _health_progress parses a partial TAP log directly.
PLOG="$T/plog"; printf '1..168\nok 1 a\nok 2 b\nnot ok 3 c\n' > "$PLOG"
[ "$(_health_progress "$PLOG")" = "test 3/168" ] || fail "(2) progress should read 'test 3/168' (got '$(_health_progress "$PLOG")')"
# … and the gate's running row surfaces it. Plant a LIVE worker marker + a partial log for this pr+sha,
# then hit the gate's in-flight branch (no dispatch result yet) and read the row.
sleep 300 & PP=$!; disown "$PP" 2>/dev/null || true
INF="$(_health_inflight_file "601-shaPROG")"
_marker_write "$INF" "$PP"
printf '1..168\nok 1 a\nok 2 b\nok 3 c\nnot ok 4 d\n' > "$(_health_log_file "601-shaPROG")"
_HC_RESULT=""; DISPLAY=()
_healthcheck_gate 601 slug-prog "$T/wt" 0 shaPROG
[ "$_HC_RESULT" = "RUNNING" ] || fail "(2) an in-flight suite should read RUNNING (got '$_HC_RESULT')"
printf '%s\n' "${DISPLAY[0]:-}" | grep -q 'running' || fail "(2) the running row must say 'running'"
printf '%s\n' "${DISPLAY[0]:-}" | grep -q 'test 4/168' || fail "(2) the running row must show live progress 'test 4/168' (got: ${DISPLAY[0]:-})"
kill "$PP" 2>/dev/null || true
rm -f "$INF" "$(_health_log_file "601-shaPROG")" 2>/dev/null || true
ok

# ── (3) HONEST FAILURE LABEL — outcome detail quotes the FIRST 'not ok', never a passing 'ok NN' ────
# The failing TAP stream ends with a passing 'ok' summary-ish line AFTER the real 'not ok' — the exact
# shape that made the old --oneline tail mislabel the failure. The detail must be the not-ok line.
BODY_FAIL="$T/body-fail.txt"
printf '1..3\nok 1 setup\nnot ok 2 tests/test-broken.sh: assertion failed\nok 3 teardown\n' > "$BODY_FAIL"
export HC_BODY_FILE="$BODY_FAIL" HC_RC=1
: > "$JOURNAL_FILE"
drive 502 slug-fail shaFAIL
[ "$_HC_RESULT" = "CODEERROR" ] || fail "(3) reproduced fail should collect CODEERROR (got '$_HC_RESULT')"
python3 - "$JOURNAL_FILE" <<'PY' || fail "(3) healthcheck_outcome detail must quote the FIRST not-ok line (not a passing 'ok')"
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
o=[r for r in rows if r.get("event")=="healthcheck_outcome" and r.get("outcome")=="CODEERROR"]
assert o, "no CODEERROR outcome journaled"
d=o[-1].get("detail","")
assert "not ok 2 tests/test-broken.sh" in d, f"detail must quote the not-ok line, got: {d!r}"
assert not d.strip().startswith("ok "), f"detail must not be a passing 'ok' line, got: {d!r}"
PY
# The ledger offender is the failing test FILE (extracted from the not-ok line), not a summary token.
python3 - "$JOURNAL_FILE" <<'PY' || fail "(3) the retried code-error must record failed=tests/test-broken.sh"
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r=[x for x in rows if x.get("event")=="healthcheck_retried" and x.get("result")=="code-error"]
assert r and r[-1].get("failed")=="tests/test-broken.sh", r
PY
# The failing run's full log is tailable too.
grep -q 'not ok 2 tests/test-broken.sh' "$(_health_log_file "502-shaFAIL")" || fail "(3) the failing run's log must be tailable"
ok

echo "ALL PASS ($pass checks)"
