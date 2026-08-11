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
#   (c) JOURNAL-AUDIT — a gates-passed marker with no later `merge` past the TTL surfaces a
#       `gates_passed_no_merge` finding; a later merge clears it; AGING_PR_TTL=0 disables the leg.
#       BOTH real markers are proven: `gate_status` state=success context=herd/gates (the shape
#       journal_append gets from bash post_gate_status / the python actuator on the successful
#       herd/gates=success API write) and `blessing` state=success (the python engine core's
#       once-per-(pr,sha) BLESSED marker, live_runtime.py).
#   (c2) HELD vs UNOWNED (HERD-634) — a blessing past the TTL with no merge yet is not automatically a
#       gap: a core_surface_hold / merge_queue_hold / hold_applied event for the SAME pr+sha (the
#       engine's own merge-ordering rails journaling why they held this exact candidate) reclassifies
#       the finding as `gates_passed_held` instead — the root instance being PR 742, held 3.5h behind
#       PR 741's core-diff mutex, then merged on its own once 741 landed. A hold event for a DIFFERENT
#       pr, or a stale hold that predates this blessing, must never suppress a real unowned finding.
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
grep -q 'aging' <<< "${DISPLAY[0]}" || fail "(a) a crossed PR must grow an 'aging' line: ${DISPLAY[0]}"
grep -q 'engine-approved' <<< "${DISPLAY[0]}" || fail "(a) the aging line must say engine-approved"
grep -q 'macos-latest' <<< "${DISPLAY[0]}" || fail "(a) the aging line must name the blocking check"
[ "$(jcount '"event":"pr_aging"')" -eq 1 ] || fail "(a) crossing the TTL must journal pr_aging exactly once"

# Next tick, still aged: the row re-paints but pr_aging stays ONCE (sha-keyed once-guard).
export HERD_FAKE_NOW=103700
DISPLAY=("$BASE")
_aging_decorate_row 0 "$PR" "$SHA" console-idle UNSTABLE "$CISUM"
grep -q 'aging' <<< "${DISPLAY[0]}" || fail "(a) the aging line must persist while the PR stays blocked"
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
grep -q 'required-e2e' <<< "${DISPLAY[0]}" || fail "(a) BLOCKED path must probe + name the failing check: ${DISPLAY[0]}"
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
MAIN_HEALTH_CI_GATE=on   # HERD-434: the leg's own lever, decoupled from MAIN_HEALTH_TICK — see (b2) below
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# _main_ci_classify: newest COMPLETED run for the expected sha wins; other-sha / in-progress runs skipped.
RUNS='[{"headSha":"'"$HEAD_SHA"'","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI"},
       {"headSha":"other","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"}]'
CL="$(printf '%s' "$RUNS" | _main_ci_classify "$HEAD_SHA")"
[ "${CL%%$'\t'*}" = fail ] || fail "(b) classify must bucket the current-HEAD FAILURE run as fail (got '$CL')"
grep -q 'CI' <<< "$CL" || fail "(b) classify must name the workflow"
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
grep -q 'MAIN RED' <<< "$ROW" || fail "(b) build_main_health must render the row"
grep -q 'CI' <<< "$ROW" || fail "(b) the MAIN RED row must name the failing CI: $ROW"
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
ok "(b) a green CI run sets no red, and MAIN_HEALTH_TICK=off is byte-inert on the branch-CI leg"

# (b2) HERD-434: MAIN_HEALTH_CI_GATE=off is its OWN independent byte-inert lever — even with
# MAIN_HEALTH_TICK back on and a failing run sitting right there, the leg must not fire.
MAIN_HEALTH_TICK=on
MAIN_HEALTH_CI_GATE=off
_main_health_ci_leg
[ -e "$TREES_DIR/.agent-watch-main-health" ] && fail "(b2) MAIN_HEALTH_CI_GATE=off must be byte-inert" || true
[ "$(jcount '"result":"red"')" -eq 0 ] || fail "(b2) MAIN_HEALTH_CI_GATE=off must journal no red"
unset GH_RUNS
ok "(b2) MAIN_HEALTH_CI_GATE=off is independently byte-inert, decoupled from MAIN_HEALTH_TICK"

# ── (c) JOURNAL-AUDIT: gates_passed_no_merge from a gates-passed marker with no later merge past TTL ──
run_audit() {  # run_audit <journal-file> ; echoes the audit's journal_audit events on the SAME file
  JOURNAL_AUDIT=on JOURNAL_FILE="$1" WORKTREES_DIR="$T" \
    HERD_JOURNAL_AUDIT_NOW="${AUDIT_NOW:-2026-07-13T12:00:00Z}" \
    HERD_JOURNAL_AUDIT_INBOX="$T/.inbox" HERD_JOURNAL_AUDIT_SEEN="$T/.seen-$RANDOM" \
    AGING_PR_TTL="${AGING_PR_TTL:-3600}" \
    HERD_CONFIG_FILE="$T/no-such-config" \
    bash "$AUDIT" >/dev/null 2>&1 || true
}
jf_finding() { local n; n="$(grep -c '"kind":"gates_passed_no_merge"' "$1" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# Fixture lines below are REAL journal shapes, byte-shaped like the writers produce them:
#   gate_status — journal_append gate_status pr <pr> sha <sha> state success context herd/gates
#                 (bash post_gate_status; the python actuator emits the identical shape). Note pr is
#                 a JSON NUMBER: journal_append int-coerces digit-only values (journal.sh).
#   blessing    — the python engine core's BLESSED marker (live_runtime.py: journal.append("blessing",
#                 "pr", …, "sha", …, "context", "herd/gates", "state", "success")).
# NO code journals any other gates-passed event — the audit must key on these, or the finding is dead.

# A gate_status success 2h old with NO later merge → a gates_passed_no_merge finding (TTL 3600 = 1h).
JA="$T/ja1.jsonl"
{
  printf '%s\n' '{"ts":"2026-07-13T10:00:00Z","event":"gate_status","pr":440,"sha":"beef1234","state":"success","context":"herd/gates"}'
} > "$JA"
AGING_PR_TTL=3600 run_audit "$JA"
[ "$(jf_finding "$JA")" -ge 1 ] || fail "(c) a gate_status success older than the TTL with no merge must surface gates_passed_no_merge"
ok "(c) a gates-passed PR (real gate_status shape) unmerged past the TTL surfaces a gates_passed_no_merge finding"

# The SAME marker but WITH a later merge for the pr → cleared, no finding.
JA2="$T/ja2.jsonl"
{
  printf '%s\n' '{"ts":"2026-07-13T10:00:00Z","event":"gate_status","pr":441,"sha":"cafe0001","state":"success","context":"herd/gates"}'
  printf '%s\n' '{"ts":"2026-07-13T10:05:00Z","event":"merge","pr":441,"slug":"feat","sha":"cafe0001","reason":"gates_passed"}'
} > "$JA2"
AGING_PR_TTL=3600 run_audit "$JA2"
[ "$(jf_finding "$JA2")" -eq 0 ] || fail "(c) a gates-passed marker cleared by a later merge must NOT be flagged"
ok "(c) a later merge for the pr clears the finding"

# A gates-passed marker still WITHIN the TTL → no finding.
JA3="$T/ja3.jsonl"
{
  printf '%s\n' '{"ts":"2026-07-13T11:30:00Z","event":"gate_status","pr":442,"sha":"fresh001","state":"success","context":"herd/gates"}'
} > "$JA3"
AGING_PR_TTL=3600 run_audit "$JA3"
[ "$(jf_finding "$JA3")" -eq 0 ] || fail "(c) a gates-passed marker within the TTL must NOT be flagged"
ok "(c) a gates-passed marker still within the TTL is not flagged"

# AGING_PR_TTL=0 disables leg (c) entirely (fresh journal — the first run mutated $JA in place).
JA4="$T/ja4.jsonl"
printf '%s\n' '{"ts":"2026-07-13T10:00:00Z","event":"gate_status","pr":443,"sha":"beef4444","state":"success","context":"herd/gates"}' > "$JA4"
AGING_PR_TTL=0 run_audit "$JA4"
[ "$(jf_finding "$JA4")" -eq 0 ] || fail "(c) AGING_PR_TTL=0 must disable the gates_passed_no_merge finding"
AGING_PR_TTL=3600
ok "(c) AGING_PR_TTL=0 disables the journal-audit leg"

# The python engine core's `blessing` marker (the OTHER real writer) fires the finding too.
JA5="$T/ja5.jsonl"
printf '%s\n' '{"ts":"2026-07-13T10:00:00Z","event":"blessing","pr":444,"sha":"feed0005","context":"herd/gates","state":"success"}' > "$JA5"
AGING_PR_TTL=3600 run_audit "$JA5"
[ "$(jf_finding "$JA5")" -ge 1 ] || fail "(c) the python engine's blessing marker past the TTL must surface gates_passed_no_merge"
ok "(c) the python engine core's blessing marker is accepted too"

# A non-gates commit-status context must NOT count as gates-passed (and a non-success state never did).
JA6="$T/ja6.jsonl"
{
  printf '%s\n' '{"ts":"2026-07-13T10:00:00Z","event":"gate_status","pr":445,"sha":"aaaa0006","state":"success","context":"some/other"}'
} > "$JA6"
AGING_PR_TTL=3600 run_audit "$JA6"
[ "$(jf_finding "$JA6")" -eq 0 ] || fail "(c) a gate_status with a non-herd/gates context must NOT be treated as gates-passed"
ok "(c) a foreign-context gate_status is excluded"

# ── (c2) HELD vs UNOWNED split (HERD-634) ─────────────────────────────────────────────────────────
jf_held() { local n; n="$(grep -c '"kind":"gates_passed_held"' "$1" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# PR 742's exact root-instance sequence: blessed at 10:00, held behind PR 741's core-diff mutex at
# 10:00 (same tick), "now" pinned to 13:00 — 3h into the 3.5h gap, well past the 1h TTL, merge has NOT
# landed yet. This is the live sweep that misfired in production: it must see gates_passed_held, never
# gates_passed_no_merge.
JAH1="$T/jah1.jsonl"
{
  printf '%s\n' '{"ts":"2026-08-10T10:00:00Z","event":"blessing","pr":742,"sha":"aaaa7420","context":"herd/gates","state":"success"}'
  printf '%s\n' '{"ts":"2026-08-10T10:00:00Z","event":"core_surface_hold","pr":742,"sha":"aaaa7420","slug":"held-lane","front_pr":741,"reason":"core diff serialized behind PR #741"}'
} > "$JAH1"
AUDIT_NOW="2026-08-10T13:00:00Z" AGING_PR_TTL=3600 run_audit "$JAH1"
[ "$(jf_finding "$JAH1")" -eq 0 ] || fail "(c2) PR 742's held sequence must NOT surface gates_passed_no_merge"
[ "$(jf_held "$JAH1")" -ge 1 ] || fail "(c2) PR 742's held sequence must surface gates_passed_held"
ok "(c2) PR 742's exact core_surface_hold sequence classifies as held-not-stuck, never unowned"

# The SAME sequence replayed with "now" AFTER the eventual merge → fully cleared, no finding at all
# (mirrors the existing merge-clears-blessing behavior; the hold event does not change that). A FRESH
# fixture file, never the mutated $JAH1 above (run_audit appends its own findings in place, same as
# the AGING_PR_TTL=0 leg below relies on).
JAH1B="$T/jah1b.jsonl"
{
  printf '%s\n' '{"ts":"2026-08-10T10:00:00Z","event":"blessing","pr":742,"sha":"aaaa7420","context":"herd/gates","state":"success"}'
  printf '%s\n' '{"ts":"2026-08-10T10:00:00Z","event":"core_surface_hold","pr":742,"sha":"aaaa7420","slug":"held-lane","front_pr":741,"reason":"core diff serialized behind PR #741"}'
  printf '%s\n' '{"ts":"2026-08-10T23:43:00Z","event":"merge","pr":742,"slug":"held-lane","sha":"aaaa7420","reason":"gates_passed"}'
} > "$JAH1B"
AUDIT_NOW="2026-08-11T00:00:00Z" AGING_PR_TTL=3600 run_audit "$JAH1B"
[ "$(jf_finding "$JAH1B")" -eq 0 ] || fail "(c2) a merged held PR must not surface gates_passed_no_merge"
[ "$(jf_held "$JAH1B")" -eq 0 ] || fail "(c2) a merged held PR must not surface gates_passed_held either — it is simply done"
ok "(c2) once PR 742 actually merges, neither finding fires"

# merge_queue_hold is the same shape of evidence for the queue-ordering rail.
JAH2="$T/jah2.jsonl"
{
  printf '%s\n' '{"ts":"2026-08-10T10:00:00Z","event":"blessing","pr":750,"sha":"bbbb7500","context":"herd/gates","state":"success"}'
  printf '%s\n' '{"ts":"2026-08-10T10:00:00Z","event":"merge_queue_hold","pr":750,"sha":"bbbb7500","slug":"queued-lane","front_pr":749}'
} > "$JAH2"
AUDIT_NOW="2026-08-10T13:00:00Z" AGING_PR_TTL=3600 run_audit "$JAH2"
[ "$(jf_finding "$JAH2")" -eq 0 ] || fail "(c2) merge_queue_hold evidence must NOT surface gates_passed_no_merge"
[ "$(jf_held "$JAH2")" -ge 1 ] || fail "(c2) merge_queue_hold evidence must surface gates_passed_held"
ok "(c2) merge_queue_hold evidence for the same pr+sha is also recognized as held"

# hold_applied (MERGE_POLICY=approve / a declared HUMAN-VERIFY block, the "awaiting approval" hold).
JAH3="$T/jah3.jsonl"
{
  printf '%s\n' '{"ts":"2026-08-10T10:00:00Z","event":"blessing","pr":760,"sha":"cccc7600","context":"herd/gates","state":"success"}'
  printf '%s\n' '{"ts":"2026-08-10T10:00:00Z","event":"hold_applied","pr":760,"sha":"cccc7600","slug":"approve-lane","kind":"approve"}'
} > "$JAH3"
AUDIT_NOW="2026-08-10T13:00:00Z" AGING_PR_TTL=3600 run_audit "$JAH3"
[ "$(jf_finding "$JAH3")" -eq 0 ] || fail "(c2) hold_applied (awaiting-approval) evidence must NOT surface gates_passed_no_merge"
[ "$(jf_held "$JAH3")" -ge 1 ] || fail "(c2) hold_applied (awaiting-approval) evidence must surface gates_passed_held"
ok "(c2) hold_applied (approve-policy awaiting-approval) evidence is also recognized as held"

# A hold event for a DIFFERENT pr must never suppress THIS pr's genuinely unowned finding.
JAH4="$T/jah4.jsonl"
{
  printf '%s\n' '{"ts":"2026-08-10T10:00:00Z","event":"blessing","pr":770,"sha":"dddd7700","context":"herd/gates","state":"success"}'
  printf '%s\n' '{"ts":"2026-08-10T10:00:00Z","event":"core_surface_hold","pr":771,"sha":"eeee7710","slug":"other-lane","front_pr":700,"reason":"core diff serialized behind PR #700"}'
} > "$JAH4"
AUDIT_NOW="2026-08-10T13:00:00Z" AGING_PR_TTL=3600 run_audit "$JAH4"
[ "$(jf_finding "$JAH4")" -ge 1 ] || fail "(c2) a sibling PR's hold event must NOT suppress this pr's unowned finding"
[ "$(jf_held "$JAH4")" -eq 0 ] || fail "(c2) a sibling PR's hold event must not falsely mark this pr held"
ok "(c2) a hold event for a different pr never suppresses this pr's unowned finding"

# A STALE hold for an OLDER sha of the same pr (a superseded push) must not suppress the current
# blessing's unowned finding — the hold evidence must match the blessing's OWN sha.
JAH5="$T/jah5.jsonl"
{
  printf '%s\n' '{"ts":"2026-08-10T09:00:00Z","event":"core_surface_hold","pr":780,"sha":"oldsha01","slug":"resurfaced","front_pr":700,"reason":"core diff serialized behind PR #700"}'
  printf '%s\n' '{"ts":"2026-08-10T10:00:00Z","event":"blessing","pr":780,"sha":"newsha02","context":"herd/gates","state":"success"}'
} > "$JAH5"
AUDIT_NOW="2026-08-10T13:00:00Z" AGING_PR_TTL=3600 run_audit "$JAH5"
[ "$(jf_finding "$JAH5")" -ge 1 ] || fail "(c2) a stale hold event on a superseded sha must NOT suppress the current blessing's unowned finding"
[ "$(jf_held "$JAH5")" -eq 0 ] || fail "(c2) a stale hold event on a superseded sha must not falsely mark this pr held"
ok "(c2) a hold event on a superseded sha never suppresses the current blessing's unowned finding"

printf '\nAll %d aging-PR alarm assertions passed.\n' "$pass"
