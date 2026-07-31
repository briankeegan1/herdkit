#!/usr/bin/env bash
# test-draft-pr-stall.sh — hermetic test for the DRAFT-PR leg of the watcher's finish-line watchdog
# (HERD-432): an idle builder over an UNPROMOTED DRAFT PR is a livelock no rail caught. Two independent
# builders (PR #549, #550, 2026-07-29/30) finished real work, pushed it, opened the PR as a draft, then
# went idle believing the watcher's gate would take it from there — it never gates a draft PR, so
# finish_stall_scan kept reporting result=empty for 4-6+ hours while the item sat In Progress.
#
# Conventions mirror tests/test-finish-stall-watchdog.sh (same AGENT_WATCH_LIB sourcing, HERD_NOW_EPOCH
# clock seam, real shared-pool store) and tests/test-adopt-remote-prs.sh's "LIVE LOOP SHAPE" test (a
# small hand-assembled _live_tick that drives the REAL functions — _prs_fetch_tick,
# _discover_feature_worktrees, _reconcile_draft_stall, _finish_stall_scan_summary — through the exact
# call sequence agent-watch.sh's real tick loop runs, without the ~300-line render/retirement/orphan
# machinery around it).
#
# Asserts:
#   • DRAFT_AUTO_PROMOTE ship-dormant: off (default) is detection-and-surface only, never a gh mutation
#   • the classifier's negative seam: has-pr=1 is-draft=0 (a REAL, promoted PR) is NEVER stalled,
#     whatever the state/age — the fix must not turn every completed builder into a false stall
#   • _reconcile_draft_stall's ladder: PENDING → FIRST_STALL (auto-promote off) → escalate → terminal
#   • FIRST_STALL with DRAFT_AUTO_PROMOTE=on: `gh pr ready <pr#>` runs, verdict PROMOTED, anchor clears
#   • a failed promotion attempt (gh error) falls back to the SAME needs-you escalation
#   • the anti-loop guard: once a PR number has been engine-promoted, a LATER re-draft (fresh anchor)
#     never re-triggers `gh pr ready` for that PR again, even with DRAFT_AUTO_PROMOTE still on
#   • DRYRUN never mutates a live PR or notifies
#   • the console row names the remedy, never leaks 'idle', never renders as a false success
#   • end-to-end via the real tick sequence: finish_stall_scan reports eligible/escalated (never
#     'empty') once a draft-PR stall crosses FINISH_STALL_MIN, and reports nothing for a NON-draft PR
# Run:  bash tests/test-draft-pr-stall.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
PYSRC="$HERE/../pysrc"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
[ -f "$PYSRC/herd/store.py" ] || fail "pysrc/herd/store.py not found"
command -v git >/dev/null 2>&1 || fail "git required to run this test"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
# herd_driver_notify calls `herdr notification show <title> --body <body> --sound <sound>` — log
# BOTH title ($3) and body ($5) so a test can grep either.
if [ "${1:-}" = "notification" ] && [ "${2:-}" = "show" ]; then
  printf '%s\t%s\n' "${3:-}" "${5:-}" >> "${HERDR_NOTIFY_LOG:?HERDR_NOTIFY_LOG unset}"
fi
exit 0
STUB
chmod +x "$BIN/herdr"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  printf '%s' "${LIVE_TICK_PRS_JSON:-[]}"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "ready" ]; then
  printf '%s\n' "$3" >> "${GH_PR_READY_LOG:?GH_PR_READY_LOG unset}"
  [ -n "${GH_PR_READY_FAIL:-}" ] && exit 1
  exit 0
fi
echo SENTINEL-NETWORK-LEAK
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _classify_finish_stall _draft_auto_promote_enabled _draft_promote_once _draft_promote_pr \
          _reconcile_draft_stall _row_draft_stall _finish_stall_scan_summary _prs_fetch_tick \
          _discover_feature_worktrees _finish_stall_note_pr_opened; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

export JOURNAL_FILE="$T/journal.log"
export HERDR_NOTIFY_LOG="$T/notify.log"; : > "$HERDR_NOTIFY_LOG"
export GH_PR_READY_LOG="$T/gh-pr-ready.log"; : > "$GH_PR_READY_LOG"
export TREES="$T/pool"; mkdir -p "$TREES"
DEFAULT_BRANCH=main

NOW=1000000000

# ── DRAFT_AUTO_PROMOTE ship-dormant ─────────────────────────────────────────────────────────────────
( unset DRAFT_AUTO_PROMOTE; _draft_auto_promote_enabled ) && fail "unset DRAFT_AUTO_PROMOTE must be OFF"
DRAFT_AUTO_PROMOTE=""    _draft_auto_promote_enabled && fail "empty must be OFF"
DRAFT_AUTO_PROMOTE=off   _draft_auto_promote_enabled && fail "off must be OFF"
DRAFT_AUTO_PROMOTE=junk  _draft_auto_promote_enabled && fail "garbage must be OFF"
DRAFT_AUTO_PROMOTE=on    _draft_auto_promote_enabled || fail "on must be ON"
DRAFT_AUTO_PROMOTE=1     _draft_auto_promote_enabled || fail "1 must be ON"
DRAFT_AUTO_PROMOTE=true  _draft_auto_promote_enabled || fail "true must be ON"
ok

GRACE=1800   # 30m, the suggested default
PAST="$((NOW - GRACE - 1))"

# ── the classifier's negative seam: a REAL (non-draft) PR is NEVER stalled ─────────────────────────
# args: agent-status has-pr has-work limit-parked state first-seen now grace is-draft
[ "$(_classify_finish_stall done 1 1 0 pending "$PAST" "$NOW" "$GRACE" 0)" = "NOT_STALLED" ] \
  || fail "a real (non-draft) PR must always escape, whatever the state/age — this is the negative seam"
[ "$(_classify_finish_stall done 1 1 0 escalated "$PAST" "$NOW" "$GRACE" 0)" = "NOT_STALLED" ] \
  || fail "even an already-escalated no-PR record must read NOT_STALLED once has-pr=1 is-draft=0"
[ "$(_classify_finish_stall done 1 1 0 "" "" "$NOW" "$GRACE")" = "NOT_STALLED" ] \
  || fail "the 9th arg (is-draft) must default to 0 — every pre-HERD-432 8-arg call site is unaffected"
ok

# ── the classifier's draft leg reuses the SAME PENDING/FIRST_STALL/SECOND_STALL/ESCALATED ladder ────
[ "$(_classify_finish_stall done 1 1 0 pending "$((NOW-1))" "$NOW" "$GRACE" 1)" = "PENDING" ] \
  || fail "has-pr=1 is-draft=1 within grace must be PENDING, not NOT_STALLED"
[ "$(_classify_finish_stall done 1 1 0 pending "$PAST" "$NOW" "$GRACE" 1)" = "FIRST_STALL" ] \
  || fail "has-pr=1 is-draft=1 past grace + no prior action must be FIRST_STALL"
[ "$(_classify_finish_stall done 1 1 0 retasked "$PAST" "$NOW" "$GRACE" 1)" = "SECOND_STALL" ] \
  || fail "has-pr=1 is-draft=1 past grace + retasked state must be SECOND_STALL"
[ "$(_classify_finish_stall done 1 1 0 escalated "$PAST" "$NOW" "$GRACE" 1)" = "ESCALATED" ] \
  || fail "has-pr=1 is-draft=1 past grace + escalated state must stay ESCALATED"
[ "$(_classify_finish_stall working 1 1 0 pending "$PAST" "$NOW" "$GRACE" 1)" = "NOT_STALLED" ] \
  || fail "a working agent must never stall even over a draft PR"
ok

# ── _draft_promote_once: permanent, per-PR-NUMBER, never anchor-scoped ──────────────────────────────
_draft_promote_once 701 || fail "the first call for a fresh PR number must win"
_draft_promote_once 701 && fail "a second call for the SAME PR number must lose — permanent guard"
_draft_promote_once 702 || fail "a DIFFERENT PR number must get its own fresh guard"
ok

# ── console row ──────────────────────────────────────────────────────────────────────────────────
row="$(NO_COLOR=1 _row_draft_stall "slugcell" " #77 ·" "12m")"
case "$row" in *"needs-you"*"gh pr ready"*) : ;; *) fail "the needs-you row must name the remedy, got: $row" ;; esac
case "$row" in *"12m"*) : ;; *) fail "the row must carry its age, got: $row" ;; esac
case "$row" in *"#77"*) : ;; *) fail "the row must carry the PR suffix, got: $row" ;; esac
case "$row" in *"✅"*) fail "must NEVER render as a success" ;; esac
grep -qw 'idle' <<< "$row" && fail "the row leaked the banned 'idle' word: $row"
ok

# ── _reconcile_draft_stall: ship-dormant when FINISH_STALL_MIN is unset ────────────────────────────
( unset FINISH_STALL_MIN
  v="$(HERD_NOW_EPOCH="$NOW" _reconcile_draft_stall off-e2e done 900)"
  [ "$v" = "OFF" ] || fail "off: should verdict OFF, got $v"
)
[ -s "$HERDR_NOTIFY_LOG" ] && fail "off: must never notify"
[ -s "$GH_PR_READY_LOG" ]  && fail "off: must never call gh pr ready"
[ -z "$(_finish_stall_record draftpr:off-e2e)" ] || fail "off: must never write a record"
ok

export FINISH_STALL_MIN=30
GRACE="$(_finish_stall_grace_secs)"

# ── E2E: DRAFT_AUTO_PROMOTE off (default) — PENDING → FIRST_STALL escalates → stays ESCALATED ───────
unset DRAFT_AUTO_PROMOTE
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_draft_stall e2e-off done 801)"
[ "$v" = "PENDING" ] || fail "tick1: first sighting should be PENDING, got $v"
[ -s "$HERDR_NOTIFY_LOG" ] && fail "tick1: PENDING must never notify"
rec="$(_finish_stall_record draftpr:e2e-off)"
[ "$rec" = "$(printf '%s\tpending' "$NOW")" ] || fail "tick1: should anchor at NOW/pending, got: $rec"

v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_draft_stall e2e-off done 801)"
[ "$v" = "FIRST_STALL" ] || fail "tick2: past grace should be FIRST_STALL, got $v"
[ -s "$GH_PR_READY_LOG" ] && fail "tick2: DRAFT_AUTO_PROMOTE=off must never call gh pr ready"
grep -q '"reason":"draft PR unpromoted"' "$JOURNAL_FILE" || fail "tick2: expected finish_stall_escalated reason=draft PR unpromoted"
grep -q 'gh pr ready 801' "$HERDR_NOTIFY_LOG" || fail "tick2: needs-you notification must name the remedy, got: $(cat "$HERDR_NOTIFY_LOG")"
rec="$(_finish_stall_record draftpr:e2e-off)"
case "$rec" in *escalated) : ;; *) fail "tick2: state must flip to escalated, got: $rec" ;; esac

: > "$HERDR_NOTIFY_LOG"
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 2))" _reconcile_draft_stall e2e-off done 801)"
[ "$v" = "ESCALATED" ] || fail "tick3: already escalated must stay ESCALATED, got $v"
[ -s "$HERDR_NOTIFY_LOG" ] && fail "tick3: ESCALATED must never re-notify (terminal, no runaway loop)"
ok

# ── E2E: DRAFT_AUTO_PROMOTE=on — FIRST_STALL promotes, `gh pr ready` runs exactly once ──────────────
: > "$GH_PR_READY_LOG"; : > "$HERDR_NOTIFY_LOG"
export DRAFT_AUTO_PROMOTE=on
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_draft_stall e2e-on done 802)"
[ "$v" = "PENDING" ] || fail "auto-promote tick1: should be PENDING, got $v"
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_draft_stall e2e-on done 802)"
[ "$v" = "PROMOTED" ] || fail "auto-promote tick2: past grace should be PROMOTED, got $v"
[ "$(cat "$GH_PR_READY_LOG")" = "802" ] || fail "expected exactly one 'gh pr ready 802', got: $(cat "$GH_PR_READY_LOG")"
grep -q '"event":"draft_pr_promoted"' "$JOURNAL_FILE" || fail "expected draft_pr_promoted journaled"
grep -q 'promoted automatically' "$HERDR_NOTIFY_LOG" || fail "expected a success notification, got: $(cat "$HERDR_NOTIFY_LOG")"
[ -z "$(_finish_stall_record draftpr:e2e-on)" ] || fail "a successful promotion must clear its own anchor"
ok

# ── a FAILED promotion attempt falls back to the SAME needs-you escalation ─────────────────────────
: > "$GH_PR_READY_LOG"; : > "$HERDR_NOTIFY_LOG"
export GH_PR_READY_FAIL=1
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_draft_stall e2e-fail done 803)"
[ "$v" = "PENDING" ] || fail "fail-path tick1: should be PENDING, got $v"
v="$(HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_draft_stall e2e-fail done 803)"
[ "$v" = "FIRST_STALL" ] || fail "fail-path tick2: a failed gh call must fall back to FIRST_STALL (escalated), got $v"
[ "$(cat "$GH_PR_READY_LOG")" = "803" ] || fail "the attempt must still have called gh pr ready once"
grep -q 'gh pr ready 803' "$HERDR_NOTIFY_LOG" || fail "a failed attempt must still notify the manual remedy"
grep -q 'promoted automatically' "$HERDR_NOTIFY_LOG" && fail "a failed attempt must never claim success"
unset GH_PR_READY_FAIL
ok

# ── ANTI-LOOP: a re-draft after an engine promotion never re-triggers gh pr ready for that PR ───────
# Simulate the tick loop's own transition-clear (mstate leaves DRAFT ⇒ the draftpr anchor drops) and
# then a LATER re-draft (a fresh anchor, first_seen resets) — exactly what a human re-drafting the
# SAME PR #802 looks like from this function's point of view. DRAFT_AUTO_PROMOTE is still ON.
_finish_stall_clear "draftpr:e2e-on"   # PR #802 already promoted once above (still spent forever)
: > "$GH_PR_READY_LOG"; : > "$HERDR_NOTIFY_LOG"
REDRAFT_NOW=$((NOW + GRACE + 100))
v="$(HERD_NOW_EPOCH="$REDRAFT_NOW" _reconcile_draft_stall e2e-on done 802)"
[ "$v" = "PENDING" ] || fail "re-draft tick1: fresh anchor should be PENDING, got $v"
v="$(HERD_NOW_EPOCH="$((REDRAFT_NOW + GRACE + 1))" _reconcile_draft_stall e2e-on done 802)"
[ "$v" = "FIRST_STALL" ] || fail "re-draft tick2: must NOT re-promote — expected the escalate fallback (FIRST_STALL), got $v"
[ -s "$GH_PR_READY_LOG" ] && fail "anti-loop: gh pr ready must NEVER fire again for an already-promoted PR number, got: $(cat "$GH_PR_READY_LOG")"
grep -q 'gh pr ready 802' "$HERDR_NOTIFY_LOG" || fail "re-draft must still escalate (detection stays visible) even though it never re-acts"
ok

# ── DRYRUN never mutates a live PR or notifies ──────────────────────────────────────────────────────
: > "$GH_PR_READY_LOG"; : > "$HERDR_NOTIFY_LOG"
v="$(HERD_NOW_EPOCH="$NOW" _reconcile_draft_stall dryrun-slug done 804)"
[ "$v" = "PENDING" ] || fail "dryrun tick1: should be PENDING, got $v"
v="$(DRYRUN=1 HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_draft_stall dryrun-slug done 804 2>/dev/null)"
[ "$v" = "FIRST_STALL" ] || fail "dryrun: past grace should still classify FIRST_STALL, got $v"
[ -s "$GH_PR_READY_LOG" ] && fail "dryrun: MUST NEVER call gh pr ready"
[ -s "$HERDR_NOTIFY_LOG" ] && fail "dryrun: must never notify"
rec="$(_finish_stall_record draftpr:dryrun-slug)"
[ "$rec" = "$(printf '%s\tpending' "$NOW")" ] \
  || fail "dryrun: must NOT flip state — the record must be untouched, got: $rec"
DRYVERDICT="$(DRYRUN=1 _draft_promote_pr 804 2>/dev/null)"
[ $? -ne 0 ] || fail "_draft_promote_pr must fail (never mutate) under DRYRUN"
ok

unset DRAFT_AUTO_PROMOTE
_finish_stall_clear "draftpr:e2e-off"; _finish_stall_clear "draftpr:e2e-on"
_finish_stall_clear "draftpr:e2e-fail"; _finish_stall_clear "draftpr:dryrun-slug"

# ── LIVE LOOP SHAPE (mirrors tests/test-adopt-remote-prs.sh's precedent): drive the REAL tick
# sequence — _prs_fetch_tick, _discover_feature_worktrees, _finish_stall_note_pr_opened,
# _reconcile_draft_stall, _finish_stall_scan_summary — through the exact call order agent-watch.sh's
# live loop runs, over a real worktree/branch. Proves the WIRING, not just the pure functions in
# isolation: a broken field list, a mis-set condition guard, or a tally that never reaches the summary
# would all pass every test above yet reproduce the grounded incident (finish_stall_scan reporting
# result=empty for 4-6+ hours over a real idle-builder-with-a-draft-PR).
mkgit() {
  local d="$1"; mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" checkout -q -b main 2>/dev/null || git -C "$d" checkout -q main
  git -C "$d" config user.email t@t.test; git -C "$d" config user.name herd-test
  printf 'base\n' > "$d/base.txt"; git -C "$d" add -A; git -C "$d" commit -qm base
}
MAIN="$T/main-repo"; mkgit "$MAIN"
git -C "$MAIN" worktree add -q -b feat/draft-slug "$TREES/draft-slug" main
SHA_DRAFT="$(git -C "$TREES/draft-slug" rev-parse HEAD)"
git -C "$MAIN" worktree add -q -b feat/promoted-slug "$TREES/promoted-slug" main
SHA_PROMOTED="$(git -C "$TREES/promoted-slug" rev-parse HEAD)"
export MAIN

_FINISH_STALL_SCAN_INTERVAL=5
_FINISH_STALL_SCAN_TICK=$_FINISH_STALL_SCAN_INTERVAL
_live_tick() {
  _prs_fetch_tick
  WT="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null || echo '')"
  AGENTS_JSON='{"result":{"agents":[{"name":"draft-slug","agent_status":"idle"},{"name":"promoted-slug","agent_status":"idle"}]}}'
  FEATS=()
  while IFS= read -r rec; do
    [ -n "$rec" ] && FEATS+=("$rec")
  done < <(PRS_JSON="$PRS_JSON" AGENTS_JSON="$AGENTS_JSON" WT="$WT" MAIN="$MAIN" TREES="$TREES" _discover_feature_worktrees)
  _FSS_ELIGIBLE=0; _FSS_RETASKED=0; _FSS_ESCALATED=0
  for rec in ${FEATS[@]+"${FEATS[@]}"}; do
    IFS=$'\037' read -r dir slug branch prnum mergeable mstate astatus headsha prauthor matchkind matchdetail <<EOF
$rec
EOF
    [ -n "$prnum" ] && _finish_stall_note_pr_opened "$slug"
    _dstall=""
    if [ -n "$prnum" ] && [ "$mstate" = "DRAFT" ]; then
      case "$astatus" in
        done|idle) _dstall="$(_reconcile_draft_stall "$slug" "$astatus" "$prnum")" ;;
      esac
      case "$_dstall" in
        PENDING)     _FSS_ELIGIBLE=$((_FSS_ELIGIBLE + 1)) ;;
        PROMOTED)    _FSS_RETASKED=$((_FSS_RETASKED + 1)) ;;
        FIRST_STALL|SECOND_STALL|ESCALATED) _FSS_ESCALATED=$((_FSS_ESCALATED + 1)) ;;
      esac
    elif [ -n "$prnum" ] && _finish_stall_enabled; then
      _finish_stall_clear "draftpr:${slug}"
    fi
  done
  _FINISH_STALL_SCAN_TICK=$((_FINISH_STALL_SCAN_TICK + 1))
  if [ "$_FINISH_STALL_SCAN_TICK" -ge "$_FINISH_STALL_SCAN_INTERVAL" ]; then
    _FINISH_STALL_SCAN_TICK=0
    _finish_stall_scan_summary "$_FSS_ELIGIBLE" "$_FSS_RETASKED" "$_FSS_ESCALATED"
  fi
}

: > "$JOURNAL_FILE"
export LIVE_TICK_PRS_JSON="$(python3 -c '
import json
print(json.dumps([
  {"number":901,"title":"draft builder","headRefName":"feat/draft-slug","headRefOid":"'"$SHA_DRAFT"'","mergeable":"MERGEABLE","mergeStateStatus":"DRAFT"},
  {"number":902,"title":"promoted builder","headRefName":"feat/promoted-slug","headRefOid":"'"$SHA_PROMOTED"'","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"},
]))
')"

_t=0
while [ "$_t" -lt "$((3 * _FINISH_STALL_SCAN_INTERVAL))" ]; do
  _t=$((_t + 1))
  HERD_NOW_EPOCH="$((NOW + _t * (GRACE + 1)))" _live_tick
done
grep -q '"event":"finish_stall_scan"' "$JOURNAL_FILE" || fail "live loop: finish_stall_scan was never journaled at all: $(cat "$JOURNAL_FILE")"
grep -q '"result":"eligible"\|"result":"escalated"' <<< "$(grep '"event":"finish_stall_scan"' "$JOURNAL_FILE")" \
  || fail "live loop: finish_stall_scan must report eligible/escalated for the idle draft-PR builder, never only 'empty': $(grep '"event":"finish_stall_scan"' "$JOURNAL_FILE")"
grep -q '"event":"finish_stall_detected".*"reason":"draft_pr"' "$JOURNAL_FILE" \
  || fail "live loop: expected a finish_stall_detected(reason=draft_pr) event for feat/draft-slug"

# NEGATIVE SEAM: the promoted-slug builder (a REAL, non-draft — BLOCKED, not DRAFT — PR) must NEVER
# surface a draft-PR stall, however long it sits idle.
! grep -q 'promoted-slug' "$JOURNAL_FILE" || fail "live loop: promoted-slug (a non-draft PR) must never appear in a draft-stall journal event: $(grep promoted-slug "$JOURNAL_FILE")"
ok

echo "ok — $pass draft-PR-stall assertions passed"
