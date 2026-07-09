#!/usr/bin/env bash
# test-merge-fairness.sh — MERGE FAIRNESS: ready-PR priority + starvation surfacing (HERD-231).
#
# Two independent mechanisms, proven independently:
#
#   (A) READY-PR PRIORITY (MERGE_FAIRNESS=on, ship-dormant). A candidate whose gates are already green
#       for its head sha is visited — and therefore merged — BEFORE the action pass dispatches new gate
#       work for any sibling. With the knob OFF the candidate order is byte-identical to discovery
#       order. Grounded: PR #328 took four conflict/stale laps on 2026-07-09 and PR #347 three, each
#       re-staled by a merge that landed while its own review was still running.
#         (1) knob off → arrays untouched, zero journal events (byte-identical)
#         (2) knob on  → a gates-green PR is promoted ahead of the ungated ones, once
#         (3) knob on, replayed through the real per-candidate call order → the ready PR MERGES before
#             any sibling's review/healthcheck is dispatched (the actual claim, observed via the journal)
#         (4) stable partition — relative order preserved inside BOTH partitions
#         (5) already ready-first → identity, and byte-quiet (no journal noise)
#         (6) readiness is the GATE ledger, not a guess: a cached CODEERROR, a review BLOCK, a missing
#             review, or a missing health result all fail the predicate; a human-overridden BLOCK passes
#         (7) never merges the unpassed: a promoted candidate still runs every downstream gate
#
#   (B) RE-STALE COUNTER + STARVATION ROW (always on, display-only).
#         (8)  a stale-base hold on a sha that carried INVESTED gate work counts one lap + journals it
#         (9)  a hold on a sha with NO invested work counts NOTHING (a hold is not a lost lap)
#         (10) the same hold lingering across ticks counts ONCE (dedup by pr+sha+kind)
#         (11) at _RESTALE_STARVE_THRESHOLD laps the loud row appears and pr_starvation is journaled
#         (12) a re-CONFLICT counts a lap too, through the same shared helper
#         (13) the counter is display-only: it never holds, merges, or bounces anything
#
# Hermetic: no network, no git, no panes. The gate ledgers ARE the input, so they are written directly.
# Run:  bash tests/test-merge-fairness.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Sourcing agent-watch.sh in lib mode REASSIGNS $HERE (to scripts/herd, from its own BASH_SOURCE), so
# pin the repo root now — check (13) greps the tree long after the source.
ROOT="$(cd "$HERE/.." && pwd)"
WATCH="$ROOT/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); echo "PASS: $1"; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── STRUCTURAL: the reorder runs BEFORE the action pass, never inside it ────────────────────────
# Match CODE only — a prose mention of the call in a comment must never satisfy the assertion.
code_lines() { grep -F -n -- "$1" "$WATCH" | awk '{ rest = substr($0, index($0,":")+1); if (rest !~ /^[[:space:]]*#/) print }'; }
line_of()  { code_lines "$1" | head -n1 | cut -d: -f1; }
count_of() { code_lines "$1" | awk 'END{print NR+0}'; }

# CALLSITES only: drop the `_merge_fairness_reorder() {` definition line, so this pins where the
# reorder RUNS — not merely that it exists somewhere above the action pass.
callsites() { code_lines '_merge_fairness_reorder' | grep -vF '_merge_fairness_reorder()'; }
L_REORDER="$(callsites | head -n1 | cut -d: -f1)"
L_LOOP="$(line_of 'for idx in ${CAND_IDX[@]+"${CAND_IDX[@]}"}')"
L_HEALTH="$(line_of '_healthcheck_gate "$prnum"')"
[ -n "$L_REORDER" ] || fail "(0) no _merge_fairness_reorder call in the main loop"
[ -n "$L_LOOP" ]    || fail "(0) could not locate the action-pass candidate loop"
[ "$L_REORDER" -lt "$L_LOOP" ]   || fail "(0) the reorder (line $L_REORDER) must precede the action pass (line $L_LOOP)"
[ "$L_REORDER" -lt "$L_HEALTH" ] || fail "(0) the reorder must precede any healthcheck dispatch"
[ "$(callsites | awk 'END{print NR+0}')" = "1" ] || fail "(0) expected exactly one reorder callsite"
ok "(0) the candidate order is fixed once, before the action pass dispatches anything"

# ── Stubs + lib-mode source ─────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"
chmod +x "$BIN/gh" "$BIN/herdr"
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1 HERD_DRIVER=headless
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export DEFAULT_BRANCH="main"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _merge_fairness_reorder _merge_fairness_enabled _cand_gates_ready _health_cached_verdict \
          _gate_work_invested _restale_note restale_count restale_counted _starvation_row \
          _restale_decorate_row; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok "(0b) every fairness/starvation helper is lib-visible"

TREES="$WORKTREES_DIR"
render() { :; }

events() { python3 - "$JOURNAL_FILE" "$1" <<'PY'
import sys, json
want = sys.argv[2]; n = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line: continue
    try: e = json.loads(line)
    except Exception: continue
    if e.get("event") == want: n += 1
print(n)
PY
}
event_field() { python3 - "$JOURNAL_FILE" "$1" "$2" <<'PY'
import sys, json
want, field = sys.argv[2], sys.argv[3]
out = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line: continue
    try: e = json.loads(line)
    except Exception: continue
    if e.get("event") == want: out.append(str(e.get(field, "")))
print(" ".join(out))
PY
}

# Gate-ledger fixtures — the ONLY inputs the fairness predicate reads.
mark_health()  { printf '%s\t%s\n' "$2" "" > "$(_health_result_file "$1" "$3")"; }   # <pr> <verdict> <sha>
mark_review()  { printf '%s %s %s %s reviewer\n' "$(date +%s)" "$1" "$3" "$2" >> "$REVIEW_STATE"; }
mark_override(){ printf '%s override %s %s\n' "$(date +%s)" "$1" "$2" >> "$OVERRIDES"; }
ready_pr()     { mark_health "$1" CLEAN "$2"; mark_review "$1" PASS "$2"; }

reset_state() {
  : > "$JOURNAL_FILE"
  rm -f "$TREES"/.health-* "$TREES"/.review-* 2>/dev/null || true
  : > "$REVIEW_STATE"; : > "$OVERRIDES"; : > "$RESTALE_STATE"; : > "$STALE_DUP_STATE"
  DISPLAY=(); unset MERGE_FAIRNESS 2>/dev/null || true
}

# set_cands <n> — three candidates, PRs 101/102/103, shas sha1/sha2/sha3, discovery order preserved.
set_cands() {
  CAND_IDX=(0 1 2); CAND_DIR=(/d/a /d/b /d/c); CAND_SLUG=(alpha bravo charlie)
  CAND_PR=(101 102 103); CAND_BRANCH=(feat/a feat/b feat/c); CAND_SHA=(sha1 sha2 sha3)
}
order() { printf '%s' "${CAND_PR[*]}"; }
# Every parallel array must be permuted together, or a candidate would be gated with another's worktree.
arrays_aligned() {
  local k
  for k in 0 1 2; do
    case "${CAND_PR[k]}:${CAND_SLUG[k]}:${CAND_SHA[k]}:${CAND_DIR[k]}:${CAND_BRANCH[k]}:${CAND_IDX[k]}" in
      101:alpha:sha1:/d/a:feat/a:0|102:bravo:sha2:/d/b:feat/b:1|103:charlie:sha3:/d/c:feat/c:2) : ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# ── (1) knob OFF → byte-identical: arrays untouched, journal silent ─────────────────────────────
reset_state; set_cands
ready_pr 103 sha3                       # the LAST candidate is the ready one — maximal temptation
_merge_fairness_reorder
[ "$(order)" = "101 102 103" ]           || fail "(1) knob off must not reorder (got: $(order))"
[ "$(events merge_fairness_priority)" = "0" ] || fail "(1) knob off must journal nothing"
ok "(1) MERGE_FAIRNESS=off leaves the candidate order byte-identical"

# Any unrecognized value is off, too — a typo must never silently enable a reorder.
reset_state; set_cands; ready_pr 103 sha3
MERGE_FAIRNESS=yes-please _merge_fairness_reorder
[ "$(order)" = "101 102 103" ] || fail "(1b) an unrecognized MERGE_FAIRNESS value must be off"
ok "(1b) an unrecognized MERGE_FAIRNESS value falls back to off"

# ── (2) knob ON → the gates-green PR is promoted to the front, exactly once ─────────────────────
reset_state; set_cands
ready_pr 103 sha3
MERGE_FAIRNESS=on _merge_fairness_reorder
[ "$(order)" = "103 101 102" ]                || fail "(2) ready PR must be promoted (got: $(order))"
[ "$(events merge_fairness_priority)" = "1" ] || fail "(2) expected exactly one merge_fairness_priority event"
[ "$(event_field merge_fairness_priority promoted)" = "1" ] || fail "(2) promoted count wrong"
[ "$(event_field merge_fairness_priority deferred)" = "2" ] || fail "(2) deferred count wrong"
[ "$(event_field merge_fairness_priority prs)" = "103" ]    || fail "(2) journal must name the promoted PR"
arrays_aligned || fail "(2) the parallel candidate arrays fell out of alignment after the reorder"
ok "(2) a gates-green candidate is promoted ahead of the ungated ones (arrays stay aligned)"

# ── (3) THE CLAIM: the ready PR merges before any sibling's gate work is dispatched ─────────────
# A faithful replay of agent-watch.sh's per-candidate call order over the REORDERED arrays. The
# assertion is on the journal: `pr_merged` for the ready PR must precede every dispatch event.
reset_state; set_cands
ready_pr 103 sha3
_predispatch_review_if_parallel() { journal_append review_dispatched pr "$1" sha "$3"; }
_healthcheck_gate() { journal_append healthcheck_started pr "$1" sha "${5:-}"; _HC_RESULT=CLEAN; }
replay_action_pass() {
  local j=0 idx pr sha
  for idx in "${CAND_IDX[@]}"; do
    pr="${CAND_PR[j]}"; sha="${CAND_SHA[j]}"; j=$((j+1))
    if _cand_gates_ready "$pr" "$sha"; then          # cached PASS → straight to the merge path
      journal_append pr_merged pr "$pr" sha "$sha"
      continue
    fi
    _predispatch_review_if_parallel "$pr" "alpha" "$sha"
    _HC_RESULT=""; _healthcheck_gate "$pr" "alpha" "/d" 0 "$sha"
  done
}
MERGE_FAIRNESS=on _merge_fairness_reorder
replay_action_pass
SEQ="$(python3 - "$JOURNAL_FILE" <<'PY'
import sys, json
out = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line: continue
    try: e = json.loads(line)
    except Exception: continue
    ev = e.get("event")
    if ev in ("pr_merged", "review_dispatched", "healthcheck_started"):
        out.append("%s:%s" % (ev, e.get("pr")))
print(" ".join(out))
PY
)"
case "$SEQ" in
  "pr_merged:103 "*) : ;;
  *) fail "(3) the ready PR did not merge before any dispatch — sequence: $SEQ" ;;
esac
case "$SEQ" in
  *"review_dispatched:103"*|*"healthcheck_started:103"*) fail "(3) the ready PR must dispatch NO new gate work" ;;
esac
ok "(3) the gates-green PR merges before any sibling review/healthcheck is dispatched"

# Same replay, knob OFF: the ready PR merges LAST, behind both siblings' dispatches — the starvation
# window this feature closes. Proves check (3) is non-vacuous.
reset_state; set_cands; ready_pr 103 sha3
_merge_fairness_reorder
replay_action_pass
SEQ_OFF="$(python3 - "$JOURNAL_FILE" <<'PY'
import sys, json
out = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line: continue
    try: e = json.loads(line)
    except Exception: continue
    if e.get("event") in ("pr_merged", "review_dispatched", "healthcheck_started"):
        out.append("%s:%s" % (e.get("event"), e.get("pr")))
print(" ".join(out))
PY
)"
case "$SEQ_OFF" in
  *"pr_merged:103") : ;;
  *) fail "(3b) knob off should have merged the ready PR LAST — sequence: $SEQ_OFF" ;;
esac
ok "(3b) with the knob off the same ready PR merges last (the check is non-vacuous)"
unset -f _predispatch_review_if_parallel _healthcheck_gate

# ── (4) STABLE partition: relative order preserved inside both partitions ───────────────────────
reset_state; set_cands
ready_pr 102 sha2; ready_pr 103 sha3     # two ready (discovery order 102 then 103), one not
MERGE_FAIRNESS=on _merge_fairness_reorder
[ "$(order)" = "102 103 101" ] || fail "(4) partition must be stable (got: $(order))"
[ "$(event_field merge_fairness_priority prs)" = "102,103" ] || fail "(4) journal must name both promoted PRs in order"
ok "(4) the partition is stable — discovery order preserved within each side"

# ── (5) already ready-first → identity, and byte-quiet ──────────────────────────────────────────
reset_state; set_cands
ready_pr 101 sha1
MERGE_FAIRNESS=on _merge_fairness_reorder
[ "$(order)" = "101 102 103" ]                || fail "(5) an already-ordered set must not be permuted"
[ "$(events merge_fairness_priority)" = "0" ] || fail "(5) an identity reorder must be byte-quiet"
ok "(5) a candidate set already in ready-first order is an identity no-op (no journal noise)"

# All-ready and none-ready are both identity, and both silent.
reset_state; set_cands; ready_pr 101 sha1; ready_pr 102 sha2; ready_pr 103 sha3
MERGE_FAIRNESS=on _merge_fairness_reorder
[ "$(order)" = "101 102 103" ] && [ "$(events merge_fairness_priority)" = "0" ] || fail "(5b) all-ready must be identity + silent"
reset_state; set_cands
MERGE_FAIRNESS=on _merge_fairness_reorder
[ "$(order)" = "101 102 103" ] && [ "$(events merge_fairness_priority)" = "0" ] || fail "(5b) none-ready must be identity + silent"
ok "(5b) all-ready and none-ready are identity no-ops"

# ── (6) readiness is READ FROM THE GATE LEDGERS — never inferred ────────────────────────────────
reset_state
_cand_gates_ready 200 shaX && fail "(6) no ledger rows at all must not be ready"
mark_health 201 CLEAN shaX
_cand_gates_ready 201 shaX && fail "(6) a CLEAN health with NO review verdict must not be ready"
mark_review 202 PASS shaX
_cand_gates_ready 202 shaX && fail "(6) a review PASS with NO health result must not be ready"
mark_health 203 CODEERROR shaX; mark_review 203 PASS shaX
_cand_gates_ready 203 shaX && fail "(6) a cached CODEERROR must never be ready"
mark_health 204 CLEAN shaX; mark_review 204 BLOCK shaX
_cand_gates_ready 204 shaX && fail "(6) an un-overridden BLOCK must never be ready"
mark_health 205 CLEAN shaX; mark_review 205 BLOCK shaX; mark_override 205 shaX
_cand_gates_ready 205 shaX || fail "(6) a human-overridden BLOCK on THIS sha must be ready (the pass treats it as PASS)"
mark_health 206 FLAKY shaX; mark_review 206 PASS shaX
_cand_gates_ready 206 shaX || fail "(6) a FLAKY (passed-on-retry) health must be ready"
mark_health 207 CLEAN shaOLD; mark_review 207 PASS shaOLD
_cand_gates_ready 207 shaNEW && fail "(6) a verdict for a DIFFERENT sha must never make the new sha ready"
_cand_gates_ready 207 "" && fail "(6) an empty sha must never be ready"
ok "(6) readiness = cached CLEAN/FLAKY health + review PASS (or an overridden BLOCK), for THIS sha only"

# ── (7) the reorder never blesses: promotion is visit order, not a merge decision ───────────────
# The promoted candidate's own ledger rows are exactly what they were; nothing was recorded, posted or
# approved by the reorder. The action pass's gates are the only thing that can merge it.
reset_state; set_cands; ready_pr 103 sha3
_gs_before="$(cat "$GATE_STATUS_STATE" 2>/dev/null | wc -l | tr -d ' ')"
_ap_before="$(cat "$APPROVALS" 2>/dev/null | wc -l | tr -d ' ')"
MERGE_FAIRNESS=on _merge_fairness_reorder
[ "$(cat "$GATE_STATUS_STATE" 2>/dev/null | wc -l | tr -d ' ')" = "$_gs_before" ] || fail "(7) the reorder posted a gate status"
[ "$(cat "$APPROVALS" 2>/dev/null | wc -l | tr -d ' ')" = "$_ap_before" ]         || fail "(7) the reorder wrote an approval"
[ "$(events pr_merged)" = "0" ] || fail "(7) the reorder must never merge anything itself"
ok "(7) the reorder permutes visit order only — it blesses, approves and merges nothing"

# ══ (B) RE-STALE COUNTER + STARVATION SURFACING (always on) ════════════════════════════════════

# ── (8) a hold on an INVESTED sha counts one lap and journals it ────────────────────────────────
reset_state
mark_health 301 CLEAN shaA                       # gate work invested in shaA: a suite ran to CLEAN
_gate_work_invested 301 shaA || fail "(8) a cached health result is invested gate work"
_restale_note 301 shaA slug-a stale-base
[ "$(restale_count 301)" = "1" ]        || fail "(8) expected 1 lap, got $(restale_count 301)"
[ "$(events pr_restale)" = "1" ]        || fail "(8) expected one pr_restale event"
[ "$(event_field pr_restale kind)" = "stale-base" ] || fail "(8) the lap must name its kind"
[ "$(event_field pr_restale laps)" = "1" ]          || fail "(8) the lap must carry the running count"
[ "$(events pr_starvation)" = "0" ]     || fail "(8) one lap is not starvation"
ok "(8) a stale-base hold on an invested sha counts one lap and journals pr_restale"

# Every flavor of investment counts — in flight, awaiting collection, or a verdict already in.
reset_state
: > "$(_health_inflight_file "302-shaB")";  _gate_work_invested 302 shaB || fail "(8b) a health worker in flight is invested"
: > "$(_health_dispatch_file "303-shaC")";  _gate_work_invested 303 shaC || fail "(8b) an uncollected health verdict is invested"
: > "$(_review_inflight_file 304 shaD)";    _gate_work_invested 304 shaD || fail "(8b) a reviewer in flight is invested"
mark_review 305 BLOCK shaE;                 _gate_work_invested 305 shaE || fail "(8b) a recorded review verdict is invested"
ok "(8b) invested = health cached | health in flight | health uncollected | reviewer in flight | verdict recorded"

# ── (9) a hold with NO invested work is not a lap ───────────────────────────────────────────────
reset_state
_gate_work_invested 306 shaF && fail "(9) an untouched sha must not read as invested"
_restale_note 306 shaF slug-f stale-base
[ "$(restale_count 306)" = "0" ] || fail "(9) a hold before any gate ran must count no lap"
[ "$(events pr_restale)" = "0" ] || fail "(9) a hold before any gate ran must journal nothing"
[ "$(_starvation_row 306)" = "" ] || fail "(9) a PR with no laps must render no starvation row"
ok "(9) a hold on a sha that never carried gate work costs nothing and counts nothing"

# ── (10) the SAME hold across many ticks counts once ────────────────────────────────────────────
reset_state
mark_health 307 CLEAN shaG
for _ in 1 2 3 4 5 6 7 8 9 10; do _restale_note 307 shaG slug-g stale-base; done
[ "$(restale_count 307)" = "1" ] || fail "(10) a lingering hold must count ONE lap, got $(restale_count 307)"
[ "$(events pr_restale)" = "1" ] || fail "(10) a lingering hold must journal once"
# ...but a DIFFERENT sha (the builder bounced, pushed, lost the race again) is a new lap.
mark_health 307 CLEAN shaH
_restale_note 307 shaH slug-g stale-base
[ "$(restale_count 307)" = "2" ] || fail "(10) a new sha losing the race again must count a second lap"
# ...and a different KIND on the same sha is its own lap (re-staled, then re-conflicted).
mark_health 307 CLEAN shaI; _restale_note 307 shaI slug-g stale-base; _restale_note 307 shaI slug-g conflict
[ "$(restale_count 307)" = "4" ] || fail "(10) stale-base and conflict on one sha are distinct laps"
ok "(10) laps dedup by (pr, sha, kind) — a lingering hold counts once, a fresh loss counts again"

# ── (11) at the threshold: the loud row appears and pr_starvation is journaled ──────────────────
reset_state
[ "${_RESTALE_STARVE_THRESHOLD:-0}" -ge 1 ] || fail "(11) _RESTALE_STARVE_THRESHOLD must be a positive constant"
_lap=1
while [ "$_lap" -lt "$_RESTALE_STARVE_THRESHOLD" ]; do
  mark_health 308 CLEAN "sha$_lap"; _restale_note 308 "sha$_lap" slug-h stale-base
  [ "$(_starvation_row 308)" = "" ] || fail "(11) starvation must not fire below the threshold (lap $_lap)"
  _lap=$((_lap+1))
done
[ "$(events pr_starvation)" = "0" ] || fail "(11) pr_starvation must not fire below the threshold"
mark_health 308 CLEAN "sha$_RESTALE_STARVE_THRESHOLD"
_restale_note 308 "sha$_RESTALE_STARVE_THRESHOLD" slug-h stale-base
[ "$(restale_count 308)" = "$_RESTALE_STARVE_THRESHOLD" ] || fail "(11) lap accounting drifted"
[ "$(events pr_starvation)" = "1" ] || fail "(11) crossing the threshold must journal pr_starvation"
[ "$(event_field pr_starvation laps)" = "$_RESTALE_STARVE_THRESHOLD" ] || fail "(11) pr_starvation must carry the lap count"
ROW="$(_starvation_row 308)"
printf '%s' "$ROW" | grep -q "starving · ${_RESTALE_STARVE_THRESHOLD} re-stale laps" \
  || fail "(11) expected the loud 'starving · N re-stale laps' row, got: $ROW"
# The row rides UNDER the existing hold row — it decorates, never replaces.
DISPLAY=("    original hold row")
_restale_decorate_row 0 308
printf '%s' "${DISPLAY[0]}" | grep -q "original hold row" || fail "(11) decoration must preserve the hold row"
printf '%s' "${DISPLAY[0]}" | grep -q "starving"          || fail "(11) decoration must append the starvation line"
[ "$(printf '%s' "${DISPLAY[0]}" | wc -l | tr -d ' ')" = "1" ] || fail "(11) decoration must add exactly one line"
# A PR under the threshold is never decorated — the console stays byte-identical for it.
DISPLAY=("    untouched row"); _restale_decorate_row 0 999
[ "${DISPLAY[0]}" = "    untouched row" ] || fail "(11) a non-starving PR's row must be byte-identical"
ok "(11) at the threshold: pr_starvation journaled + the loud row decorates (never replaces) the hold row"

# ── (12) a re-CONFLICT is a lap too, through the SAME shared helper ─────────────────────────────
reset_state
mark_review 309 PASS shaJ                        # a review completed; then a merge landed → CONFLICTING
_restale_note 309 shaJ slug-j conflict
[ "$(restale_count 309)" = "1" ]                  || fail "(12) a re-conflict on an invested sha is a lap"
[ "$(event_field pr_restale kind)" = "conflict" ] || fail "(12) the conflict lap must name kind=conflict"
# The conflict classifier calls it for real (and normalizes an absent sha to '-', which is never a lap).
_gate_work_invested 310 "-" && fail "(12) the '-' sha sentinel must never read as invested"
# DRY-RUN records nothing: the conflict classifier DOES run under --dry-run (the stale-dup gate does
# not), so a lap written there would inflate the next real tick's count.
reset_state
mark_health 311 CLEAN shaK
DRYRUN=1 _restale_note 311 shaK slug-k conflict
[ "$(restale_count 311)" = "0" ] || fail "(12) --dry-run must never write a lap"
[ "$(events pr_restale)" = "0" ] || fail "(12) --dry-run must never journal a lap"
ok "(12) a re-conflicted sha counts a lap via the same _restale_note used by the stale-dup hold; dry-run writes nothing"

# ── (13) display-only: the counter gates NOTHING ────────────────────────────────────────────────
# No ENGINE file outside agent-watch.sh reads $RESTALE_STATE, and no merge, hold or bounce branches on
# restale_count. A ratchet: the moment someone gates on it, this check fails. scripts/herd/sim/ is
# excluded on purpose — the sim rig is a PROOF harness that drives the counter, never a consumer of it.
READERS="$(grep -rlF 'RESTALE_STATE' "$ROOT/scripts" "$ROOT/bin" 2>/dev/null \
  | grep -v '/sim/' | sed 's#.*/##' | sort -u | paste -sd' ' -)"
[ "$READERS" = "agent-watch.sh" ] || fail "(13) \$RESTALE_STATE must be read only by agent-watch.sh (readers: $READERS)"
USES="$(grep -nE 'restale_count|_starvation_row' "$WATCH" | grep -vE '^\s*[0-9]+:\s*#' | grep -vE 'restale_count\(\)|_starvation_row\(\)' | wc -l | tr -d ' ')"
[ "$USES" -ge 1 ] || fail "(13) the counter is never read — the row would never render"
# Every call sits inside the two display helpers; nothing in a gate/merge decision.
grep -nE 'if .*restale_count|\[ .*restale_count.* \] (&&|\|\|) (do_merge|record_|post_gate)' "$WATCH" \
  | grep -vE '_starvation_row\(\)' | grep -q . && fail "(13) restale_count appears in a gate/merge decision"
ok "(13) the re-stale counter is display + journal only — nothing gates on it"

echo "ALL PASS ($pass checks) — merge fairness: ready-PR priority + starvation surfacing (HERD-231)"
