#!/usr/bin/env bash
# test-adopt-remote-prs.sh — hermetic unit tests for auto-ADOPT of ungated remote PRs (HERD-369):
# the ADOPT_REMOTE_PRS=on|off lever, built ON TOP of the HERD-330 orphan diff, and the invariants the
# feature MUST hold:
#   • OFF (default) is byte-inert: no ledger, no journal event, no git fetch/worktree-add call.
#   • ON: an open, NON-DRAFT orphan PR whose branch is checked out nowhere is adopted within one scan
#     (git fetch + git worktree add) and journals exactly one pr_adopted event.
#   • A DRAFT PR is never adopted, even when it is otherwise an orphan.
#   • A branch already checked out ANYWHERE (main checkout or another worktree) is never touched.
#   • Sha-keyed once-guard: a second scan of the same (pr,sha) never re-runs fetch/worktree-add.
#   • Fail-soft: a fetch failure or a worktree-add failure journals adopt_failed and records the
#     outcome — never a red row, never a crash.
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1 — helpers only, no polling loop, no console,
# no real network), pointing config discovery at a nonexistent file so herd-config.sh falls back to its
# generic defaults (ADOPT_REMOTE_PRS defaults off). A scripted `git` stub on PATH stands in for fetch/
# worktree-add so the test never touches the real network or filesystem outside $T.
# Run:  bash tests/test-adopt-remote-prs.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Stub binaries on PATH ────────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
export GIT_CALL_LOG="$T/git-calls.log"; : > "$GIT_CALL_LOG"
# git: log every invocation; emulate `fetch` and `worktree add` deterministically off the branch name
# (a branch containing "fail-fetch"/"fail-worktree" fails that step), everything else succeeds so
# sourcing never breaks. A successful `worktree add` mkdir's the target dir, mirroring the real command.
cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_CALL_LOG" 2>/dev/null || true
if [ "$1" = "-C" ] && [ "$3" = "fetch" ]; then
  branch="$6"
  case "$branch" in *fail-fetch*) exit 1 ;; esac
  exit 0
fi
if [ "$1" = "-C" ] && [ "$3" = "worktree" ] && [ "$4" = "add" ]; then
  dir="$5"; branch="$6"
  case "$branch" in *fail-worktree*) exit 1 ;; esac
  mkdir -p "$dir" 2>/dev/null
  exit 0
fi
if [ "$1" = "-C" ] && [ "$3" = "worktree" ] && [ "$4" = "move" ]; then
  from="$5"; to="$6"
  case "$from" in *fail-move*) exit 1 ;; esac
  mv "$from" "$to" 2>/dev/null
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/git"
printf '#!/usr/bin/env bash\necho SENTINEL-NETWORK-LEAK\nexit 0\n' > "$BIN/gh";  chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source the watcher's helpers WITHOUT its live loop (lib mode), colors blanked (NO_COLOR) ────────
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT/.herd"
export WORKSPACE_NAME="adopttest"
export WATCHER_OWNER="me-operator"
export NO_COLOR=1
export JOURNAL_FILE="$T/journal.jsonl"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _adopt_remote_prs_enabled _adopt_pr_recorded _adopt_pr_mark_adopted _adopt_branch_checked_out \
          _adopt_failed_journaled _adopt_journal_failed _adopt_remote_pr _adopt_remote_prs_scan \
          _adopt_branch_worktree_dir _adopt_self_heal_mismatch herd_branch_slug \
          _watcher_tick_fields; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
pass

reset_state() {
  : > "$GIT_CALL_LOG"
  : > "$JOURNAL_FILE"
  rm -f "$ADOPT_PR_LEDGER" "$ADOPT_FAILED_SEEN_LEDGER"
  rm -rf "${WORKTREES_DIR:?}"/* 2>/dev/null || true
}

# ── 1. _adopt_remote_prs_enabled: default OFF; on|true|1|yes|enable enable it; anything else is OFF ─
unset ADOPT_REMOTE_PRS
_adopt_remote_prs_enabled && fail "must be OFF by default (unset)"; pass
for v in on ON true 1 yes enable enabled; do
  ADOPT_REMOTE_PRS="$v" _adopt_remote_prs_enabled || fail "should be ON for '$v'"
done; pass
for v in off "" 0 no garbage; do
  ADOPT_REMOTE_PRS="$v" _adopt_remote_prs_enabled && fail "should be OFF for '$v'"
done; pass

# A two-PR open roster: 201 adoptable, 202 already claimed by a discovered worktree.
PRS='[
  {"number":201,"title":"add gizmo","headRefName":"feat/gizmo","headRefOid":"sha201","isDraft":false},
  {"number":202,"title":"fix leak","headRefName":"feat/leak","headRefOid":"sha202","isDraft":false}
]'

# ── 2. OFF is byte-inert: no ledger, no journal event, no git fetch/worktree-add call ───────────────
reset_state
ADOPT_REMOTE_PRS=off PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "202" ""
[ ! -e "$ADOPT_PR_LEDGER" ] || fail "OFF must not write the adopt ledger"
[ ! -s "$JOURNAL_FILE" ] || fail "OFF must not journal anything"
[ ! -s "$GIT_CALL_LOG" ] || fail "OFF must never invoke git fetch/worktree add: $(cat "$GIT_CALL_LOG")"
pass

# _watcher_tick_fields must stay byte-identical (no isDraft) when the feature is off.
case ",$(ADOPT_REMOTE_PRS=off _watcher_tick_fields)," in
  *,isDraft,*) fail "OFF must not add isDraft to the gh --json field list" ;;
esac
case ",$(ADOPT_REMOTE_PRS=on _watcher_tick_fields)," in
  *,isDraft,*) : ;;
  *) fail "ON must add isDraft to the gh --json field list" ;;
esac
pass

# ── 3. ON: PR 201 (unclaimed, non-draft, branch free) is adopted; PR 202 (claimed) is left alone ────
# The adopted worktree dir must be "gizmo", NOT "feat-gizmo" — herd_branch_slug strips the default
# BRANCH_TEMPLATE prefix ('feat/{slug}') exactly like branch_to_slug does for candidate discovery
# (pysrc/herd/live_runtime.py:branch_to_slug), the parity HERD-377 fixes. A naive `tr '/' '-'` of the
# raw branch — the pre-fix behavior — would produce "feat-gizmo", a path discovery never resolves to.
reset_state
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "202" ""
grep -q -- "-C $PROJECT_ROOT fetch -q origin feat/gizmo" "$GIT_CALL_LOG" || fail "expected a fetch of feat/gizmo: $(cat "$GIT_CALL_LOG")"
grep -q -- "-C $PROJECT_ROOT worktree add $WORKTREES_DIR/gizmo feat/gizmo" "$GIT_CALL_LOG" \
  || fail "expected a worktree add of feat/gizmo at the SLUG-PARITY path (gizmo, not feat-gizmo): $(cat "$GIT_CALL_LOG")"
grep -q "leak" "$GIT_CALL_LOG" && fail "claimed PR 202 must never be touched: $(cat "$GIT_CALL_LOG")"
[ -d "$WORKTREES_DIR/gizmo" ] || fail "adopted worktree dir was not created at the slug-parity path"
[ ! -e "$WORKTREES_DIR/feat-gizmo" ] || fail "adopted worktree must not use the old mismatched-slug path"
grep -q '"event":"pr_adopted"' "$JOURNAL_FILE" || fail "pr_adopted not journaled: $(cat "$JOURNAL_FILE")"
grep -q '"pr":201' "$JOURNAL_FILE" || fail "pr_adopted missing pr:201: $(cat "$JOURNAL_FILE")"
grep -q -- "$(printf '201\tsha201\tadopted')" "$ADOPT_PR_LEDGER" || fail "ledger missing adopted row: $(cat "$ADOPT_PR_LEDGER" 2>/dev/null)"
# HERD-388: the throttled per-scan summary reports the successful adopt too, count=1 (only PR 201 was
# eligible — 202 was already claimed and never entered the attempt tally).
grep -q '"event":"adopt_scan"' "$JOURNAL_FILE" || fail "expected the throttled adopt_scan summary: $(cat "$JOURNAL_FILE")"
grep -q '"result":"adopted"' "$JOURNAL_FILE" || fail "a successful adopt must summarize as result=adopted"
grep -q '"count":1' "$JOURNAL_FILE" || fail "expected count=1 (one PR adopted this scan)"
pass

# ── 3b. herd_branch_slug matches branch_to_slug's convention directly (unit-level parity check) ────
[ "$(herd_branch_slug "feat/gizmo")" = "gizmo" ] || fail "herd_branch_slug should strip the feat/ prefix"
[ "$(herd_branch_slug "feat/python-draft-pr-hold")" = "python-draft-pr-hold" ] \
  || fail "herd_branch_slug regression: must match branch_to_slug for the real HERD-377 branch"
[ "$(herd_branch_slug "someuser:feature/x")" = "someuser:feature-x" ] \
  || fail "herd_branch_slug must fall back to flattening '/' when the branch does not fit BRANCH_TEMPLATE"
pass

# ── 4. A DRAFT orphan PR is never adopted, even though it is otherwise eligible ──────────────────────
# (it DOES still produce the throttled `adopt_scan result=empty` summary — HERD-388: the scan RAN and
# found nothing to do, which is the whole point of the summary event, and is distinct from never having
# run at all.)
reset_state
DRAFT_PRS='[{"number":301,"title":"wip thing","headRefName":"feat/wip","headRefOid":"sha301","isDraft":true}]'
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$DRAFT_PRS" "" ""
[ ! -s "$GIT_CALL_LOG" ] || fail "a draft PR must never trigger fetch/worktree add: $(cat "$GIT_CALL_LOG")"
grep -q '"pr":301' "$JOURNAL_FILE" 2>/dev/null && fail "a draft PR must never journal a pr_adopted/adopt_failed row: $(cat "$JOURNAL_FILE")"
grep -q '"event":"adopt_scan"' "$JOURNAL_FILE" || fail "expected the throttled adopt_scan summary even for a draft-only roster: $(cat "$JOURNAL_FILE")"
grep -q '"result":"empty"' "$JOURNAL_FILE" || fail "a draft-only roster must summarize as result=empty (nothing eligible), not adopted/failed"
[ ! -e "$WORKTREES_DIR/wip" ] || fail "a draft PR must never get a worktree"
pass

# ── 5. A branch already checked out ANYWHERE (main checkout or a stray worktree) is never touched ──
reset_state
WT_TEXT="worktree $PROJECT_ROOT
HEAD deadbeef
branch refs/heads/feat/gizmo

"
_adopt_branch_checked_out "feat/gizmo" "$WT_TEXT" || fail "_adopt_branch_checked_out must detect a checked-out branch"
_adopt_branch_checked_out "feat/nowhere" "$WT_TEXT" && fail "_adopt_branch_checked_out false-positived on an unrelated branch"
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "202" "$WT_TEXT"
[ ! -s "$GIT_CALL_LOG" ] || fail "a branch checked out elsewhere must never be fetched/added: $(cat "$GIT_CALL_LOG")"
pass

# ── 6. Sha-keyed once-guard: a second scan of the SAME (pr,sha) never re-runs fetch/worktree-add ────
reset_state
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "202" ""
first_calls="$(wc -l < "$GIT_CALL_LOG" | tr -cd '0-9')"
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "202" ""
second_calls="$(wc -l < "$GIT_CALL_LOG" | tr -cd '0-9')"
[ "$first_calls" = "$second_calls" ] || fail "once-guard failed: git was invoked again on re-tick ($first_calls -> $second_calls)"
adopted_rows="$(grep -c "^$(printf '201\tsha201\tadopted')\$" "$ADOPT_PR_LEDGER" 2>/dev/null || true)"
[ "${adopted_rows:-0}" = "1" ] || fail "ledger must record PR 201 exactly once, got ${adopted_rows:-0}"
pass

# ── 7. Fail-soft: a fetch failure journals adopt_failed, never a crash, and is NEVER once-guarded —
#      a still-broken branch RETRIES the attempt every scan, but the journal EVENT is deduped so a
#      permanently-broken branch does not spam adopt_failed once per tick forever. Each scan ALSO
#      emits exactly one throttled adopt_scan summary (HERD-388) — that one is NOT deduped, since it is
#      the per-scan "did this leg run, and what happened" signal, not a per-(pr,sha) once-guard ──────
reset_state
FAIL_FETCH_PRS='[{"number":401,"title":"x","headRefName":"feat/fail-fetch","headRefOid":"sha401","isDraft":false}]'
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$FAIL_FETCH_PRS" "" || fail "a fetch failure must not abort the scan"
grep -q '"event":"adopt_failed"' "$JOURNAL_FILE" || fail "adopt_failed not journaled on fetch failure: $(cat "$JOURNAL_FILE")"
grep -q '"pr":401' "$JOURNAL_FILE" || fail "adopt_failed missing pr:401"
grep -q '"event":"adopt_scan"' "$JOURNAL_FILE" || fail "expected a throttled adopt_scan summary: $(cat "$JOURNAL_FILE")"
grep -q '"result":"failed"' "$JOURNAL_FILE" || fail "a scan with a failed attempt must summarize as result=failed"
[ ! -e "$ADOPT_PR_LEDGER" ] || fail "a failure must never write the SUCCESS once-guard ledger: $(cat "$ADOPT_PR_LEDGER")"
[ ! -d "$WORKTREES_DIR/fail-fetch" ] || fail "a failed fetch must never leave a worktree dir"
first_fetch_calls="$(wc -l < "$GIT_CALL_LOG" | tr -cd '0-9')"
first_adopt_failed_lines="$(grep -c '"event":"adopt_failed"' "$JOURNAL_FILE")"
first_adopt_scan_lines="$(grep -c '"event":"adopt_scan"' "$JOURNAL_FILE")"
# A SECOND scan of the SAME still-failing (pr,sha): the attempt retries (git called again)...
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$FAIL_FETCH_PRS" ""
second_fetch_calls="$(wc -l < "$GIT_CALL_LOG" | tr -cd '0-9')"
[ "$second_fetch_calls" -gt "$first_fetch_calls" ] || fail "a failed (pr,sha) must be RETRIED on the next scan, not once-guarded"
# ...the adopt_failed EVENT for this exact (pr,sha) is deduped, not doubled...
second_adopt_failed_lines="$(grep -c '"event":"adopt_failed"' "$JOURNAL_FILE")"
[ "$second_adopt_failed_lines" = "$first_adopt_failed_lines" ] || fail "adopt_failed must be deduped per (pr,sha), not re-journaled every scan"
# ...but the per-scan adopt_scan summary is NOT deduped — a second scan is a second throttled tick.
second_adopt_scan_lines="$(grep -c '"event":"adopt_scan"' "$JOURNAL_FILE")"
[ "$second_adopt_scan_lines" -gt "$first_adopt_scan_lines" ] || fail "adopt_scan must summarize EVERY scan, not just the first"
pass

# ── 8. Fail-soft: a worktree-add failure journals adopt_failed too (fetch succeeded, add did not) ──
reset_state
FAIL_ADD_PRS='[{"number":402,"title":"x","headRefName":"feat/fail-worktree","headRefOid":"sha402","isDraft":false}]'
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$FAIL_ADD_PRS" "" || fail "a worktree-add failure must not abort the scan"
grep -q '"event":"adopt_failed"' "$JOURNAL_FILE" || fail "adopt_failed not journaled on worktree-add failure"
grep -q '"pr":402' "$JOURNAL_FILE" || fail "adopt_failed missing pr:402"
pass

# ── 9. A FAILED open-PR fetch (PRS_LOOKUP_OK=0) never fabricates an adopt attempt — but IS visible ──
# HERD-388 GROUNDED INCIDENT: this is exactly the leg that went silent for 30+ minutes with no
# pr_adopted, no adopt_failed, and no orphan rows — indistinguishable from "nothing to adopt". The scan
# must now say so explicitly (result=failed, reason=lookup_failed) instead of silently no-opping.
reset_state
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=0 _adopt_remote_prs_scan "$PRS" ""
[ ! -s "$GIT_CALL_LOG" ] || fail "PRS_LOOKUP_OK=0 must never attempt an adopt: $(cat "$GIT_CALL_LOG")"
grep -q '"event":"adopt_scan"' "$JOURNAL_FILE" || fail "a failed PR lookup must still emit the throttled adopt_scan summary: $(cat "$JOURNAL_FILE")"
grep -q '"result":"failed"' "$JOURNAL_FILE" || fail "a failed PR lookup must summarize as result=failed, not empty"
grep -q '"reason":"lookup_failed"' "$JOURNAL_FILE" || fail "expected reason=lookup_failed so this is distinguishable from an adopt/worktree failure"
pass

# ── 10. Malformed roster is fail-soft: no ledger write, never a crash ────────────────────────────────
reset_state
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan 'not json' "" || fail "malformed roster must not error"
[ ! -s "$GIT_CALL_LOG" ] || fail "malformed roster must never attempt an adopt"
pass

# ── 11. HERD-377 leftover self-heal: a PRE-FIX adopt checked a branch out at the OLD mismatched-slug
#        path (mirrors the real PR #484: TREES/feat-python-draft-pr-hold instead of the slug-parity
#        TREES/python-draft-pr-hold). A scan detects the mismatch from the SAME worktree porcelain text
#        the checked-out-anywhere guard reads and `git worktree move`s it onto the correct path — a
#        re-adopt at the right path with the stale dir swept — instead of re-fetching/re-adding ──────
reset_state
mkdir -p "$WORKTREES_DIR/feat-python-draft-pr-hold"
STALE_WT="worktree $WORKTREES_DIR/feat-python-draft-pr-hold
HEAD deadbeef
branch refs/heads/feat/python-draft-pr-hold

"
REGRESSION_PRS='[{"number":484,"title":"python draft pr hold","headRefName":"feat/python-draft-pr-hold","headRefOid":"sha484","isDraft":false}]'
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$REGRESSION_PRS" "" "$STALE_WT"
grep -q -- "-C $PROJECT_ROOT worktree move $WORKTREES_DIR/feat-python-draft-pr-hold $WORKTREES_DIR/python-draft-pr-hold" "$GIT_CALL_LOG" \
  || fail "expected a self-heal worktree move onto the slug-parity path: $(cat "$GIT_CALL_LOG")"
[ -d "$WORKTREES_DIR/python-draft-pr-hold" ] || fail "self-heal must leave the worktree at the slug-parity path"
[ ! -e "$WORKTREES_DIR/feat-python-draft-pr-hold" ] || fail "self-heal must sweep the stale mismatched-slug dir"
grep -q '"event":"adopt_selfheal"' "$JOURNAL_FILE" || fail "adopt_selfheal not journaled: $(cat "$JOURNAL_FILE")"
grep -q "worktree add" "$GIT_CALL_LOG" && fail "a self-healed branch must never ALSO be re-fetched/re-added: $(cat "$GIT_CALL_LOG")"
pass

# ── 12. Self-heal move failure is fail-soft: retried every scan, but the journal event is deduped ───
reset_state
mkdir -p "$WORKTREES_DIR/feat-fail-move-thing"
FAILMOVE_WT="worktree $WORKTREES_DIR/feat-fail-move-thing
HEAD deadbeef
branch refs/heads/feat/fail-move-thing

"
FAILMOVE_PRS='[{"number":403,"title":"x","headRefName":"feat/fail-move-thing","headRefOid":"sha403","isDraft":false}]'
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$FAILMOVE_PRS" "" "$FAILMOVE_WT" \
  || fail "a self-heal move failure must not abort the scan"
grep -q '"event":"adopt_selfheal_failed"' "$JOURNAL_FILE" || fail "adopt_selfheal_failed not journaled on move failure"
[ -d "$WORKTREES_DIR/feat-fail-move-thing" ] || fail "a failed move must leave the stale dir in place, not lose it"
first_move_calls="$(grep -c 'worktree move' "$GIT_CALL_LOG" || true)"
first_selfheal_failed_lines="$(grep -c '"event":"adopt_selfheal_failed"' "$JOURNAL_FILE")"
ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$FAILMOVE_PRS" "" "$FAILMOVE_WT"
second_move_calls="$(grep -c 'worktree move' "$GIT_CALL_LOG" || true)"
[ "$second_move_calls" -gt "$first_move_calls" ] || fail "a failed self-heal must be RETRIED on the next scan"
# The branch stays checked out at the (unmoved) stale path both scans, so nothing was ELIGIBLE to
# adopt either time — the per-scan adopt_scan summary correctly reads result=empty on both, same as
# any tick where the scan ran and found nothing new to do.
second_selfheal_failed_lines="$(grep -c '"event":"adopt_selfheal_failed"' "$JOURNAL_FILE")"
[ "$second_selfheal_failed_lines" = "$first_selfheal_failed_lines" ] || fail "adopt_selfheal_failed must be deduped per (branch,dir), not re-journaled every scan"
adopt_scan_lines="$(grep -c '"event":"adopt_scan"' "$JOURNAL_FILE")"
[ "$adopt_scan_lines" = "2" ] || fail "expected exactly one adopt_scan summary per scan (2 scans, 2 summaries), got $adopt_scan_lines"
pass

# ── 13. LIVE LOOP SHAPE regression (HERD-388): the SAME wiring the real tick loop uses — including
#        _prs_fetch_tick's live `gh pr list` field-list construction, worktree discovery producing the
#        claimed-set, and the _ADOPT_SCAN_TICK/_ADOPT_SCAN_INTERVAL cadence gate — drives a fixture
#        worktree-less orphan PR to pr_adopted within two scan intervals. Every test above calls
#        _adopt_remote_prs_scan DIRECTLY with hand-fed PRS_JSON/claimed/wt arguments — that is the
#        HERD-377 test's shape too: it asserts POST-adoption classification, never the scan's
#        DISCOVERY. This is the first test that exercises the actual glue a live tick runs: a broken
#        _prs_fetch_tick field list, a claimed-set miscomputation, or a tick counter that never reaches
#        its threshold would all pass every test above yet reproduce the grounded incident — three real
#        orphan PRs sitting silent for 30+ minutes despite the scan logic being provably correct in
#        isolation.
reset_state
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  printf '%s' "${LIVE_TICK_PRS_JSON:-[]}"
  exit 0
fi
echo SENTINEL-NETWORK-LEAK
exit 0
STUB
chmod +x "$BIN/gh"
export LIVE_TICK_PRS_JSON='[{"number":501,"title":"live orphan","headRefName":"feat/live-orphan","headRefOid":"sha501","isDraft":false}]'

# Mirror the EXACT per-tick sequence agent-watch.sh's live loop runs (fetch PRs, snapshot worktrees,
# discover claimed PRs, gate on the scan cadence) — see the "HERD-369 adopt remote PRs" block in
# _tick_render_reconcile. AGENT_WATCH_LIB mode returns before the bottom-of-file cadence-state init and
# the live `while true` loop, so this primes _ADOPT_SCAN_TICK/_ADOPT_SCAN_INTERVAL exactly as
# production does and drives the real functions through the real call sequence.
_ADOPT_SCAN_INTERVAL=15
_ADOPT_SCAN_TICK=$_ADOPT_SCAN_INTERVAL
_live_tick() {
  _prs_fetch_tick
  WT="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null || echo '')"
  AGENTS_JSON='{"result":{"agents":[]}}'
  FEATS=()
  while IFS= read -r rec; do
    [ -n "$rec" ] && FEATS+=("$rec")
  done < <(PRS_JSON="$PRS_JSON" AGENTS_JSON="$AGENTS_JSON" WT="$WT" MAIN="$MAIN" TREES="$TREES" _discover_feature_worktrees)
  _orphan_claimed=""
  for _orphan_rec in ${FEATS[@]+"${FEATS[@]}"}; do
    IFS=$'\037' read -r _ _ _ _orphan_prnum _ <<EOF
$_orphan_rec
EOF
    [ -n "${_orphan_prnum:-}" ] && _orphan_claimed="${_orphan_claimed}${_orphan_prnum} "
  done
  _ADOPT_SCAN_TICK=$((_ADOPT_SCAN_TICK + 1))
  if [ "$_ADOPT_SCAN_TICK" -ge "$_ADOPT_SCAN_INTERVAL" ]; then
    _ADOPT_SCAN_TICK=0
    _adopt_remote_prs_scan "$PRS_JSON" "$_orphan_claimed" "$WT"
  fi
}

ADOPT_REMOTE_PRS=on
_tick_n=0
_adopted_by_tick=""
while [ "$_tick_n" -lt "$((2 * _ADOPT_SCAN_INTERVAL))" ]; do
  _tick_n=$((_tick_n + 1))
  _live_tick
  if [ -z "$_adopted_by_tick" ] && grep -q '"pr":501' "$JOURNAL_FILE" 2>/dev/null; then
    _adopted_by_tick="$_tick_n"
  fi
done

[ -n "$_adopted_by_tick" ] || fail "live-loop-shape: PR 501 was never adopted within $((2 * _ADOPT_SCAN_INTERVAL)) ticks (two scan intervals): $(cat "$JOURNAL_FILE")"
grep -q '"event":"pr_adopted"' "$JOURNAL_FILE" || fail "live-loop-shape: pr_adopted not journaled: $(cat "$JOURNAL_FILE")"
grep -q '"event":"adopt_scan"' "$JOURNAL_FILE" || fail "live-loop-shape: expected throttled adopt_scan summaries too"
[ -d "$WORKTREES_DIR/live-orphan" ] || fail "live-loop-shape: expected the adopted worktree at the slug-parity path"
unset ADOPT_REMOTE_PRS
pass

echo "ok — $PASS adopt-remote-PRs assertions passed"
