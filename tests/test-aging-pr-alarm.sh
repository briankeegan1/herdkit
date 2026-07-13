#!/usr/bin/env bash
# test-aging-pr-alarm.sh — hermetic test for the AGING-PR alarm (HERD-334): an engine-approved PR
# (herd/gates PASSED) that branch protection keeps blocking on a required CI check is a quiet steady
# state today — no TTL covers "engine approved it, branch protection blocks it, nothing is progressing"
# (PRs #440/#441 sat 7h like that; main CI itself sat red 6h after #439). Three legs, all proven here
# by driving the REAL functions from scripts/herd/agent-watch.sh + scripts/herd/journal-audit.sh, with
# `gh` stubbed on PATH (network-free) and the notify edge routed to a headless log:
#
#   (S) SHARED TTL (aging-pr.sh) — _aging_pr_ttl_secs sanitizes (default 3600, non-numeric→default,
#       0=disabled); _aging_pr_over_ttl is the ONE over-TTL predicate both surfaces read.
#   (a) RENDER PASS — _aging_decorate_row ages a MERGEABLE-but-blocked PR off OBSERVED state each tick:
#       a first-seen marker starts the clock, and once the PR is engine-approved-but-required-check-red
#       PAST AGING_PR_TTL the row grows a loud advisory line + journals `pr_aging` EXACTLY ONCE per
#       (pr,sha). Under the TTL, not blessed, or AGING_PR_TTL=0 → byte-identical (no row, no event).
#   (b) BRANCH-CI MAIN-RED — _main_health_ci_leg fires the EXISTING MAIN RED row when the latest CI run
#       for the current main HEAD is FAILING, deduped once per (sha,conclusion); a SUCCESS run is inert.
#   (c) JOURNAL-AUDIT — a `blessing` (gates passed) with no later `merge` past the TTL surfaces a
#       `gates_passed_no_merge` finding; a later merge clears it; AGING_PR_TTL=0 disables the leg.
#
# Run:  bash tests/test-aging-pr-alarm.sh
# No `set -e`: several predicates deliberately return non-zero; every assertion is explicit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
AUDIT="$HERE/../scripts/herd/journal-audit.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); printf 'ok — %s\n' "$1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
[ -f "$AUDIT" ] || fail "journal-audit.sh not found at $AUDIT"
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── stub `gh` on PATH (no network) ───────────────────────────────────────────
# _gate_status_blessed → `gh api .../commits/<sha>/statuses --jq …`; gh applies the jq, so the stub just
#   echoes the extracted state (GH_GATE_STATE, default "success"; set "" to simulate NOT blessed).
# _ci_gate_eval       → `gh pr view <pr> --json statusCheckRollup`  → GH_ROLLUP.
# _main_health_ci_leg → `gh run list --branch … --json …`           → GH_RUNS.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "api "*)   case "$2" in *commits*/statuses) printf '%s' "${GH_GATE_STATE-success}"; exit 0 ;; esac; exit 0 ;;
  "pr view") printf '%s\n' "${GH_ROLLUP:-}"; exit 0 ;;
  "run list") printf '%s\n' "${GH_RUNS:-}"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# ── fixture: a throwaway repo that plays $MAIN (leg b needs a real HEAD) ──────
REPO="$T/main"; TREES_DIR="$T/trees"; mkdir -p "$REPO" "$TREES_DIR"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  tester
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "Merge pull request #77 from someone/branch"

# ── source the real engine in lib mode, state pinned into the sandbox ─────────
export AGENT_WATCH_LIB=1 NO_COLOR=1 HERD_DRIVER=headless HERD_HEADLESS_NATIVE_NOTIFY=off
export HERD_CONFIG_FILE="$T/no-such-config"
export PROJECT_ROOT="$REPO" WORKTREES_DIR="$TREES_DIR"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export DEFAULT_BRANCH=main
export AGING_PR_TTL=3600
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _aging_pr_ttl_secs _aging_pr_armed _aging_pr_over_ttl _aging_decorate_row purge_pr_aging \
          _main_ci_classify _main_health_ci_leg _main_health_set_red build_main_health; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

# Spy on the notify edge (a real seam; replacing it keeps the test off the desktop).
NOTIFY_LOG="$T/notify.log"; : > "$NOTIFY_LOG"
herd_driver_notify() { printf '%s\n' "$1" >> "$NOTIFY_LOG"; }

jcount() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
ncount() { local n; n="$(grep -c "$1" "$NOTIFY_LOG"   2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
reset_state() { rm -f "$TREES_DIR"/.aging-* "$TREES_DIR"/.agent-watch-main-health* 2>/dev/null; : > "$JOURNAL_FILE"; : > "$NOTIFY_LOG"; }

# ── (S) shared TTL helper: sanitize + the ONE over-TTL predicate ─────────────────────────────────────
AGING_PR_TTL=3600; [ "$(_aging_pr_ttl_secs)" = 3600 ] || fail "(S) default TTL should be 3600"
AGING_PR_TTL=0;    [ "$(_aging_pr_ttl_secs)" = 0 ] || fail "(S) explicit 0 must pass through"
_aging_pr_armed && fail "(S) TTL=0 must NOT arm the alarm"
AGING_PR_TTL=abc;  [ "$(_aging_pr_ttl_secs)" = 3600 ] || fail "(S) non-numeric TTL must read as the default"
AGING_PR_TTL=;     [ "$(_aging_pr_ttl_secs)" = 3600 ] || fail "(S) empty TTL must read as the default"
AGING_PR_TTL=120;  _aging_pr_armed || fail "(S) TTL>0 must arm the alarm"
out="$(_aging_pr_over_ttl 1000 1100)"; rc=$?    # age 100 < TTL 120: echoes the age, returns non-zero
[ "$out" = 100 ] || fail "(S) predicate must echo the age even when under TTL (got '$out')"
[ "$rc" -ne 0 ]  || fail "(S) age 100 < TTL 120 must return non-zero"
out="$(_aging_pr_over_ttl 1000 1120)"; rc=$?    # age 120 ≥ TTL 120: echoes the age, returns 0
[ "$out" = 120 ] || fail "(S) predicate must echo the age when over TTL (got '$out')"
[ "$rc" -eq 0 ]  || fail "(S) age 120 ≥ TTL 120 must return 0"
_aging_pr_over_ttl 1000 900 2>/dev/null && fail "(S) a backwards clock must return non-zero" || true
_aging_pr_over_ttl abc 1120 2>/dev/null && fail "(S) a non-numeric since must return non-zero" || true
ok "(S) AGING_PR_TTL sanitizes (default 3600, 0=off, non-numeric→default); _aging_pr_over_ttl is the shared predicate"

# ── (a) RENDER PASS: age off observed state, loud row + one pr_aging past the TTL ────────────────────
AGING_PR_TTL=3600
reset_state
export GH_GATE_STATE=success                       # herd/gates=success (engine-approved)
SHA=deadbeef; PR=440; BASE="    row-baseline"
CISUM=$'fail\tCI failed: macos-latest'             # the UNSTABLE-path summary _ci_gate_eval already produced

# T0: first observation — the clock STARTS, no row, no event, byte-identical.
export HERD_FAKE_NOW=100000
DISPLAY=("$BASE")
_aging_decorate_row 0 "$PR" "$SHA" console-idle UNSTABLE "$CISUM"
[ "${DISPLAY[0]}" = "$BASE" ] || fail "(a) first observation must not decorate the row: ${DISPLAY[0]}"
[ "$(jcount '"event":"pr_aging"')" -eq 0 ] || fail "(a) first observation must not journal pr_aging"
[ -f "$TREES_DIR/.aging-seen-$PR-$SHA" ] || fail "(a) first observation must lay the first-seen marker"

# Still UNDER the TTL (T0 + 3599): no row, no event.
export HERD_FAKE_NOW=103599
DISPLAY=("$BASE")
_aging_decorate_row 0 "$PR" "$SHA" console-idle UNSTABLE "$CISUM"
[ "${DISPLAY[0]}" = "$BASE" ] || fail "(a) under the TTL the row must stay byte-identical"
[ "$(jcount '"event":"pr_aging"')" -eq 0 ] || fail "(a) under the TTL must not journal pr_aging"

# Crossed the TTL (T0 + 3600): loud aging line appears + pr_aging journaled ONCE.
export HERD_FAKE_NOW=103600
DISPLAY=("$BASE")
_aging_decorate_row 0 "$PR" "$SHA" console-idle UNSTABLE "$CISUM"
printf '%s' "${DISPLAY[0]}" | grep -q 'aging' || fail "(a) a crossed PR must grow an 'aging' line: ${DISPLAY[0]}"
printf '%s' "${DISPLAY[0]}" | grep -q 'engine-approved' || fail "(a) the aging line must say engine-approved"
printf '%s' "${DISPLAY[0]}" | grep -q 'macos-latest' || fail "(a) the aging line must name the blocking check"
[ "$(jcount '"event":"pr_aging"')" -eq 1 ] || fail "(a) crossing the TTL must journal pr_aging exactly once"

# Next tick, still aged: the row re-paints but pr_aging stays ONCE (sha-keyed once-guard).
export HERD_FAKE_NOW=103700
DISPLAY=("$BASE")
_aging_decorate_row 0 "$PR" "$SHA" console-idle UNSTABLE "$CISUM"
printf '%s' "${DISPLAY[0]}" | grep -q 'aging' || fail "(a) the aging line must persist while the PR stays blocked"
[ "$(jcount '"event":"pr_aging"')" -eq 1 ] || fail "(a) pr_aging must fire ONCE per (pr,sha), not per tick"
ok "(a) an engine-approved PR blocked past the TTL grows a loud aging row + journals pr_aging exactly once"

# BLOCKED path (no _acisum passed): the check name is probed from the rollup, bounded to an aged PR.
reset_state
export HERD_FAKE_NOW=200000
DISPLAY=("$BASE")
_aging_decorate_row 0 501 blockedsha console-idle BLOCKED ""     # first obs — clock starts
export HERD_FAKE_NOW=204000                                      # +4000 ≥ TTL
export GH_ROLLUP='{"statusCheckRollup":[{"__typename":"CheckRun","name":"required-e2e","status":"COMPLETED","conclusion":"FAILURE"}]}'
DISPLAY=("$BASE")
_aging_decorate_row 0 501 blockedsha console-idle BLOCKED ""
printf '%s' "${DISPLAY[0]}" | grep -q 'required-e2e' || fail "(a) BLOCKED path must probe + name the failing check: ${DISPLAY[0]}"
[ "$(jcount '"event":"pr_aging"')" -eq 1 ] || fail "(a) BLOCKED path must journal pr_aging once"
unset GH_ROLLUP
ok "(a) the BLOCKED path probes the rollup for the check name only once the PR has aged"

# NOT engine-approved: aged, but herd/gates is not success → no row, no event (fail-CLOSED on the claim).
reset_state
export GH_GATE_STATE=""                              # blessing absent
export HERD_FAKE_NOW=300000
DISPLAY=("$BASE")
_aging_decorate_row 0 600 unblessedsha console-idle UNSTABLE "$CISUM"
export HERD_FAKE_NOW=304000
DISPLAY=("$BASE")
_aging_decorate_row 0 600 unblessedsha console-idle UNSTABLE "$CISUM"
[ "${DISPLAY[0]}" = "$BASE" ] || fail "(a) a non-engine-approved PR must never paint the aging row"
[ "$(jcount '"event":"pr_aging"')" -eq 0 ] || fail "(a) a non-engine-approved PR must never journal pr_aging"
export GH_GATE_STATE=success
ok "(a) an aged PR whose gates did NOT pass never paints the alarm (engine-approved is required, fail-closed)"

# AGING_PR_TTL=0 → byte-inert: no marker, no row, no event however old the PR.
reset_state
AGING_PR_TTL=0
export HERD_FAKE_NOW=400000
DISPLAY=("$BASE")
_aging_decorate_row 0 700 offsha console-idle UNSTABLE "$CISUM"
export HERD_FAKE_NOW=999999
DISPLAY=("$BASE")
_aging_decorate_row 0 700 offsha console-idle UNSTABLE "$CISUM"
[ "${DISPLAY[0]}" = "$BASE" ] || fail "(a) AGING_PR_TTL=0 must leave the row byte-identical"
[ -e "$TREES_DIR/.aging-seen-700-offsha" ] && fail "(a) AGING_PR_TTL=0 must lay NO first-seen marker" || true
[ "$(jcount '"event":"pr_aging"')" -eq 0 ] || fail "(a) AGING_PR_TTL=0 must journal nothing"
AGING_PR_TTL=3600
ok "(a) AGING_PR_TTL=0 is byte-inert on the render pass (no marker, no row, no event)"

# BEHIND is a self-resolving rebase, never the aging state.
reset_state
export HERD_FAKE_NOW=500000
DISPLAY=("$BASE")
_aging_decorate_row 0 800 behindsha console-idle BEHIND "$CISUM"
[ -e "$TREES_DIR/.aging-seen-800-behindsha" ] && fail "(a) a BEHIND PR must not start the aging clock" || true
[ "${DISPLAY[0]}" = "$BASE" ] || fail "(a) a BEHIND PR must not be decorated"
ok "(a) a BEHIND (out-of-date) PR is never aged — only BLOCKED/UNSTABLE are the stuck state"

# purge_pr_aging drops only the named PR's markers (the trailing '-' guards 9 vs 90).
reset_state
: > "$TREES_DIR/.aging-seen-9-x"; : > "$TREES_DIR/.aging-noted-9-x"; : > "$TREES_DIR/.aging-seen-90-y"
purge_pr_aging 9
[ -e "$TREES_DIR/.aging-seen-9-x" ]  && fail "(a) purge_pr_aging 9 must drop PR 9's markers" || true
[ -e "$TREES_DIR/.aging-noted-9-x" ] && fail "(a) purge_pr_aging 9 must drop PR 9's noted marker" || true
[ -e "$TREES_DIR/.aging-seen-90-y" ] || fail "(a) purge_pr_aging 9 must NOT touch PR 90's markers"
ok "(a) purge_pr_aging drops only the named PR's markers (no 9-vs-90 collision)"

# ── (b) BRANCH-CI MAIN-RED: fire the existing row when the current HEAD's CI run is failing ───────────
reset_state
unset HERD_FAKE_NOW 2>/dev/null || true
MAIN_HEALTH_TICK=on
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# _main_ci_classify: newest COMPLETED run for the expected sha wins; other-sha / in-progress runs skipped.
RUNS='[{"headSha":"'"$HEAD_SHA"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI"},
       {"headSha":"other","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"}]'
CL="$(printf '%s' "$RUNS" | _main_ci_classify "$HEAD_SHA")"
[ "${CL%%$'\t'*}" = fail ] || fail "(b) classify must bucket the current-HEAD FAILURE run as fail (got '$CL')"
printf '%s' "$CL" | grep -q 'CI' || fail "(b) classify must name the workflow"
INPROG='[{"headSha":"'"$HEAD_SHA"'","status":"IN_PROGRESS","conclusion":"","workflowName":"CI"}]'
[ -z "$(printf '%s' "$INPROG" | _main_ci_classify "$HEAD_SHA")" ] || fail "(b) an in-progress run must yield no verdict"
OTHER='[{"headSha":"stale","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI"}]'
[ -z "$(printf '%s' "$OTHER" | _main_ci_classify "$HEAD_SHA")" ] || fail "(b) a run for a DIFFERENT sha must be skipped"

# _main_health_ci_leg: a failing run fires MAIN RED once; a repeat tick (same sha+conclusion) is inert.
export GH_RUNS="$RUNS"
_main_health_ci_leg
[ -s "$TREES_DIR/.agent-watch-main-health" ] || fail "(b) a failing branch-CI run must set the MAIN RED state"
[ "$(ncount 'MAIN RED')" -eq 1 ] || fail "(b) MAIN RED must notify exactly once"
ROW="$(build_main_health; printf '%s' "${MAIN_HEALTH:-}")"
printf '%s' "$ROW" | grep -q 'MAIN RED' || fail "(b) build_main_health must render the row"
printf '%s' "$ROW" | grep -q 'CI'       || fail "(b) the MAIN RED row must name the failing CI: $ROW"
_main_health_ci_leg                                   # second tick, unchanged CI verdict
[ "$(jcount '"result":"red"')" -eq 1 ] || fail "(b) an unchanged CI red must NOT re-journal (dedupe per sha+conclusion)"
[ "$(ncount 'MAIN RED')" -eq 1 ] || fail "(b) an unchanged CI red must NOT re-notify"
ok "(b) a failing branch-CI run for the current HEAD fires the MAIN RED row once (deduped per sha+conclusion)"

# A SUCCESS run is byte-inert (no red set), and MAIN_HEALTH_TICK=off is fully inert.
reset_state
export GH_RUNS='[{"headSha":"'"$HEAD_SHA"'","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"}]'
_main_health_ci_leg
[ -e "$TREES_DIR/.agent-watch-main-health" ] && fail "(b) a green branch-CI run must never set MAIN RED" || true
MAIN_HEALTH_TICK=off
export GH_RUNS="$RUNS"                                 # failing again, but the lever is off
_main_health_ci_leg
[ -e "$TREES_DIR/.agent-watch-main-health" ] && fail "(b) MAIN_HEALTH_TICK=off must be byte-inert" || true
[ "$(jcount '"result":"red"')" -eq 0 ] || fail "(b) MAIN_HEALTH_TICK=off must journal no red"
unset GH_RUNS
ok "(b) a green CI run sets no red, and MAIN_HEALTH_TICK=off is byte-inert on the branch-CI leg"

# ── (c) JOURNAL-AUDIT: gates_passed_no_merge from a blessing with no later merge past the TTL ─────────
run_audit() {  # run_audit <journal-file> ; echoes the audit's journal_audit events on the SAME file
  JOURNAL_AUDIT=on JOURNAL_FILE="$1" WORKTREES_DIR="$T" \
    HERD_JOURNAL_AUDIT_NOW="${AUDIT_NOW:-2026-07-13T12:00:00Z}" \
    HERD_JOURNAL_AUDIT_INBOX="$T/.inbox" HERD_JOURNAL_AUDIT_SEEN="$T/.seen-$RANDOM" \
    AGING_PR_TTL="${AGING_PR_TTL:-3600}" \
    HERD_CONFIG_FILE="$T/no-such-config" \
    bash "$AUDIT" >/dev/null 2>&1 || true
}
jf_finding() { local n; n="$(grep -c '"kind":"gates_passed_no_merge"' "$1" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# A blessing 2h old with NO later merge → a gates_passed_no_merge finding (TTL default 3600 = 1h).
JA="$T/ja1.jsonl"
{
  printf '%s\n' '{"ts":"2026-07-13T10:00:00Z","event":"blessing","pr":"440","sha":"beef1234","context":"herd/gates","state":"success"}'
} > "$JA"
AGING_PR_TTL=3600 run_audit "$JA"
[ "$(jf_finding "$JA")" -ge 1 ] || fail "(c) a blessing older than the TTL with no merge must surface gates_passed_no_merge"
ok "(c) a gates-passed PR unmerged past the TTL surfaces a gates_passed_no_merge finding"

# The SAME blessing but WITH a later merge for the pr → cleared, no finding.
JA2="$T/ja2.jsonl"
{
  printf '%s\n' '{"ts":"2026-07-13T10:00:00Z","event":"blessing","pr":"441","sha":"cafe0001","context":"herd/gates","state":"success"}'
  printf '%s\n' '{"ts":"2026-07-13T10:05:00Z","event":"merge","pr":"441","slug":"feat","sha":"cafe0001","reason":"gates_passed"}'
} > "$JA2"
AGING_PR_TTL=3600 run_audit "$JA2"
[ "$(jf_finding "$JA2")" -eq 0 ] || fail "(c) a blessing cleared by a later merge must NOT be flagged"
ok "(c) a later merge for the pr clears the finding"

# A blessing still WITHIN the TTL → no finding.
JA3="$T/ja3.jsonl"
{
  printf '%s\n' '{"ts":"2026-07-13T11:30:00Z","event":"blessing","pr":"442","sha":"fresh001","context":"herd/gates","state":"success"}'
} > "$JA3"
AGING_PR_TTL=3600 run_audit "$JA3"
[ "$(jf_finding "$JA3")" -eq 0 ] || fail "(c) a blessing within the TTL must NOT be flagged"
ok "(c) a blessing still within the TTL is not flagged"

# AGING_PR_TTL=0 disables leg (c) entirely (fresh journal — the first run mutated $JA in place).
JA4="$T/ja4.jsonl"
printf '%s\n' '{"ts":"2026-07-13T10:00:00Z","event":"blessing","pr":"443","sha":"beef4444","context":"herd/gates","state":"success"}' > "$JA4"
AGING_PR_TTL=0 run_audit "$JA4"
[ "$(jf_finding "$JA4")" -eq 0 ] || fail "(c) AGING_PR_TTL=0 must disable the gates_passed_no_merge finding"
AGING_PR_TTL=3600
ok "(c) AGING_PR_TTL=0 disables the journal-audit leg"

printf '\nAll %d aging-PR alarm assertions passed.\n' "$pass"
