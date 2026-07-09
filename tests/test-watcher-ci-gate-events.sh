#!/usr/bin/env bash
# test-watcher-ci-gate-events.sh — hermetic test for HERD-197: the watcher journals GH CI check-run
# results as FIRST-CLASS gate events and surfaces WHICH check failed in the console row instead of the
# opaque mergeStateStatus==UNSTABLE. It stubs `gh` on PATH (NETWORK-FREE) so `gh pr view --json
# statusCheckRollup` returns a canned rollup, sources agent-watch.sh's helpers via the AGENT_WATCH_LIB
# guard (no live watch loop), runs the HEADLESS notify driver (a durable log sink, no herdr), and asserts:
#   • _ci_checks_normalize classifies CheckRun + StatusContext nodes into pass/fail/pending, and NEVER
#     paints a not-yet-terminal / ambiguous state (IN_PROGRESS / PENDING / CANCELLED) as a failure.
#   • _ci_gate_eval on a failing required check → echoes "fail\t<summary naming the check>", journals a
#     `ci_check` event for every terminal result, and NOTIFIES exactly once on the failure.
#   • Re-evaluating the SAME pr+sha fires NO duplicate journal/notify (once-only side effects).
#   • A NEW sha re-journals + re-notifies (a new commit re-evaluates the CI leg from scratch).
#   • FAIL-SOFT: a PR with NO checks, and an offline/empty gh, yield NO output and NO side effects
#     (byte-identical to before the feature).
#   • purge_pr_ci_checks drops only the named PR's ledger rows.
# Run:  bash tests/test-watcher-ci-gate-events.sh
# No `set -e`: some predicates deliberately return non-zero; we assert explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── stub `gh` on PATH (no network) ───────────────────────────────────────────
# `gh pr view <pr> --json statusCheckRollup` echoes the canned payload in $GH_ROLLUP; every other gh
# call is a silent no-op. Prepending $BIN shadows any real gh.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "pr view" ] && { printf '%s\n' "${GH_ROLLUP:-}"; exit 0; }
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# Source the watcher helpers WITHOUT its live loop, fully hermetic: config discovery points at a
# nonexistent file (herd-config falls back to defaults), the journal + state ledgers live under $T, and
# the HEADLESS driver routes notifications to a durable log (no herdr, no desktop).
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T"
export HERD_DRIVER=headless
export HERD_HEADLESS_NATIVE_NOTIFY=off
export JOURNAL_FILE="$T/journal.jsonl"
NOTIFY_LOG="$T/.herd/notifications.log"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _ci_checks_normalize _ci_gate_eval _ci_names_summary purge_pr_ci_checks; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

# ── 1) normalize: bucket classification across node kinds, never-false-red ────
ROLLUP_MIX='{"statusCheckRollup":[
  {"__typename":"CheckRun","name":"macos-latest","status":"COMPLETED","conclusion":"FAILURE"},
  {"__typename":"CheckRun","name":"ubuntu-latest","status":"COMPLETED","conclusion":"SUCCESS"},
  {"__typename":"CheckRun","name":"windows","status":"IN_PROGRESS","conclusion":""},
  {"__typename":"CheckRun","name":"superseded","status":"COMPLETED","conclusion":"CANCELLED"},
  {"__typename":"StatusContext","context":"ci/legacy","state":"PENDING"},
  {"__typename":"StatusContext","context":"license/cla","state":"SUCCESS"},
  {"__typename":"StatusContext","context":"deploy/preview","state":"ERROR"}
]}'
norm="$(printf '%s' "$ROLLUP_MIX" | _ci_checks_normalize)"
grep -qxF "fail	FAILURE	macos-latest"      <<<"$norm" || fail "CheckRun FAILURE should classify as fail"
grep -qxF "pass	SUCCESS	ubuntu-latest"     <<<"$norm" || fail "CheckRun SUCCESS should classify as pass"
grep -qxF "pending	IN_PROGRESS	windows"    <<<"$norm" || fail "an IN_PROGRESS CheckRun must be pending, never fail"
grep -qxF "pending	CANCELLED	superseded" <<<"$norm" || fail "a CANCELLED check must be pending (never a false red)"
grep -qxF "pending	PENDING	ci/legacy"      <<<"$norm" || fail "a PENDING StatusContext must be pending"
grep -qxF "pass	SUCCESS	license/cla"       <<<"$norm" || fail "a SUCCESS StatusContext should be pass"
grep -qxF "fail	ERROR	deploy/preview"      <<<"$norm" || fail "an ERROR StatusContext should classify as fail"
ok

# malformed / non-list rollups emit nothing (fail-soft)
[ -z "$(printf '%s' 'not json'                | _ci_checks_normalize)" ] || fail "bad JSON must normalize to nothing"
[ -z "$(printf '%s' '{"statusCheckRollup":{}}' | _ci_checks_normalize)" ] || fail "non-list rollup must normalize to nothing"
[ -z "$(printf '%s' '{"statusCheckRollup":[]}' | _ci_checks_normalize)" ] || fail "no checks must normalize to nothing"
ok

# ── 2) eval on a failing check: summary + journal + single notify ─────────────
export GH_ROLLUP='{"statusCheckRollup":[
  {"__typename":"CheckRun","name":"macos-latest","status":"COMPLETED","conclusion":"FAILURE"},
  {"__typename":"CheckRun","name":"ubuntu-latest","status":"COMPLETED","conclusion":"SUCCESS"}
]}'
row="$(_ci_gate_eval 293 sha-A console-idle)"
[ "${row%%$'\t'*}" = "fail" ]                    || fail "eval bucket should be 'fail' when a required check failed (got '$row')"
[[ "${row#*$'\t'}" == *"macos-latest"* ]]        || fail "eval summary must NAME the failing check (got '$row')"
[[ "${row#*$'\t'}" == "CI failed:"* ]]           || fail "eval failure summary should be labeled 'CI failed:' (got '$row')"
grep -q '"event":"ci_check"' "$JOURNAL_FILE"     || fail "a ci_check gate event must be journaled"
grep -q '"check":"macos-latest".*"result":"fail"' "$JOURNAL_FILE" || fail "the failing check must be journaled with result=fail + its name + conclusion"
grep -q '"check":"ubuntu-latest".*"result":"pass"' "$JOURNAL_FILE" || fail "the passing check must be journaled too (each result is a gate event)"
grep -q '"sha":"sha-A"' "$JOURNAL_FILE"          || fail "the journaled event must carry the PR head sha"
[ -s "$NOTIFY_LOG" ]                             || fail "a failing required check must NOTIFY (the grounded #293 gap)"
[ "$(grep -c 'CI failed' "$NOTIFY_LOG")" -eq 1 ] || fail "exactly one failure notification expected, got $(grep -c 'CI failed' "$NOTIFY_LOG")"
ok

# ── 3) dedup: re-eval same pr+sha fires no duplicate journal/notify ───────────
j_before="$(wc -l < "$JOURNAL_FILE")"; n_before="$(wc -l < "$NOTIFY_LOG")"
_ci_gate_eval 293 sha-A console-idle >/dev/null
[ "$(wc -l < "$JOURNAL_FILE")" -eq "$j_before" ] || fail "re-eval of the same pr+sha must NOT re-journal"
[ "$(wc -l < "$NOTIFY_LOG")" -eq "$n_before" ]   || fail "re-eval of the same pr+sha must NOT re-notify"
ok

# ── 4) a new sha re-evaluates from scratch (re-journals + re-notifies) ────────
_ci_gate_eval 293 sha-B console-idle >/dev/null
grep -q '"sha":"sha-B"' "$JOURNAL_FILE"          || fail "a new head sha must re-journal the check result"
[ "$(grep -c 'CI failed' "$NOTIFY_LOG")" -eq 2 ] || fail "a new head sha's failure must notify again"
ok

# ── 5) pending-only checks → pending bucket, named, NO notify ─────────────────
export GH_ROLLUP='{"statusCheckRollup":[
  {"__typename":"CheckRun","name":"e2e","status":"IN_PROGRESS","conclusion":""}
]}'
n_before="$(wc -l < "$NOTIFY_LOG")"
prow="$(_ci_gate_eval 400 sha-P slug-p)"
[ "${prow%%$'\t'*}" = "pending" ]                || fail "eval bucket should be 'pending' when checks are still running (got '$prow')"
[[ "${prow#*$'\t'}" == *"e2e"* ]]                || fail "a pending summary should name the in-flight check (got '$prow')"
[ "$(wc -l < "$NOTIFY_LOG")" -eq "$n_before" ]   || fail "a pending (non-failing) check must NOT notify"
ok

# ── 6) FAIL-SOFT: no checks / offline gh → no output, no side effects ─────────
export GH_ROLLUP='{"statusCheckRollup":[]}'
j_before="$(wc -l < "$JOURNAL_FILE")"
[ -z "$(_ci_gate_eval 900 sha-Z slug-z)" ]       || fail "a PR with NO checks must yield an EMPTY row (byte-identical fail-soft)"
export GH_ROLLUP=""
[ -z "$(_ci_gate_eval 901 sha-Z slug-z)" ]       || fail "an offline/empty gh must yield an EMPTY row (fail-soft)"
[ "$(wc -l < "$JOURNAL_FILE")" -eq "$j_before" ] || fail "the no-checks / offline path must journal NOTHING"
ok

# ── 7) names summary caps at 3 with a '+N more' overflow ──────────────────────
sum="$(_ci_names_summary "CI failed" a b c d e)"
[ "$sum" = "CI failed: a, b, c, +2 more" ] || fail "names summary should cap at 3 and note overflow (got '$sum')"
sum1="$(_ci_names_summary "CI failed" only)"
[ "$sum1" = "CI failed: only" ]            || fail "a single-name summary should have no overflow (got '$sum1')"
ok

# ── 8) purge drops only the named PR's rows ───────────────────────────────────
# Record a terminal (failing) check for a SECOND PR so the ledger holds rows for both 293 and 555
# (a pending-only check never records a row, so only terminal results populate the ledger).
export GH_ROLLUP='{"statusCheckRollup":[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]}'
_ci_gate_eval 555 sha-C slug-c >/dev/null
grep -q '^293 ' "$T/.agent-watch-ci-checks" 2>/dev/null || fail "precondition: PR 293 should have ledger rows before purge"
grep -q '^555 ' "$T/.agent-watch-ci-checks" 2>/dev/null || fail "precondition: PR 555 should have a ledger row before purge"
purge_pr_ci_checks 293
grep -q '^293 ' "$T/.agent-watch-ci-checks" 2>/dev/null && fail "purge_pr_ci_checks 293 must drop PR 293's rows"
grep -q '^555 ' "$T/.agent-watch-ci-checks" 2>/dev/null || fail "purge_pr_ci_checks 293 must NOT touch a different PR (555)"
ok

echo "ALL PASS ($pass checks)"
