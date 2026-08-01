#!/usr/bin/env bash
# test-draft-rail-production-repro.sh — HERD-470: the HERD-432 draft-stall rail (PR #552) went silent
# on its FIRST production exercise (PR #590, 2026-07-31): a builder's PR sat DRAFT with its agent idle
# for 50+ minutes past FINISH_STALL_MIN=30, and finish_stall_scan journaled result=empty on EVERY tick,
# forever — no finish_stall_detected, no draft_pr_promoted, ever, for any slug, in the entire history of
# this repo's own coordinator journal (`grep -c '"reason":"draft_pr"' .herd/journal.jsonl` → 0).
#
# ROOT CAUSE: the leg's call site keyed detection on `mergeStateStatus == "DRAFT"` — a value GitHub's
# MergeStateStatus enum DOES NOT HAVE (confirmed against the live GraphQL schema: DIRTY | UNKNOWN |
# BLOCKED | BEHIND | UNSTABLE | HAS_HOOKS | CLEAN). A real draft PR reports mergeStateStatus=UNKNOWN
# (GitHub never computes branch-protection state against a PR that cannot be merged yet) and isDraft=
# true. The comparison could never match a real `gh pr list` response, so _reconcile_draft_stall was
# NEVER called — not for PR #590, not once, ever. tests/test-draft-pr-stall.sh's own fixture fabricated
# "mergeStateStatus":"DRAFT" and so passed while this branch was structurally unreachable: the vacuous-
# test shape (guards-blind class — see tests/test-draft-pr-stall.sh's LIVE LOOP fixture for the fix).
#
# This file reproduces the PRODUCTION condition set HERD-470 asked for, all four leads at once, so a
# future regression has to defeat every one of them simultaneously to slip through again:
#   (a) light-profile-only healthcheck: no `.health-inflight-*` / `.health-log-*` marker is EVER written
#       for this PR — the leg must detect + escalate without any watcher-observed healthcheck record.
#   (b) a re-drafted DRAFT→READY→DRAFT PR: isDraft flips true→false→true (mergeStateStatus UNKNOWN→
#       CLEAN→UNKNOWN) mid-run, exactly like a builder iterating on review feedback.
#   (c) the watcher restarted inside the grace window: EVERY tick after the re-draft is a genuinely
#       FRESH bash process re-sourcing agent-watch.sh (not a function call in a loop) — the shared-pool
#       anchor must survive real process death, not just a bash loop's implicit continuity.
#   (d) agent_status reads 'idle', never 'done' — the FIRST production exercise's builder was idle.
#
# Conventions mirror tests/test-draft-pr-stall.sh (same hermetic gh/herdr stubs, same AGENT_WATCH_LIB
# sourcing) but each tick is its own `bash "$ONE_TICK"` subprocess instead of a same-process loop, to
# actually exercise condition (c) rather than merely asserting continuity a single process gives for
# free.
# Run:  bash tests/test-draft-rail-production-repro.sh
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
  exit 0
fi
echo SENTINEL-NETWORK-LEAK
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.log"; : > "$JOURNAL_FILE"
export HERDR_NOTIFY_LOG="$T/notify.log"; : > "$HERDR_NOTIFY_LOG"
export GH_PR_READY_LOG="$T/gh-pr-ready.log"; : > "$GH_PR_READY_LOG"
export TREES="$T/pool"; mkdir -p "$TREES"
export FINISH_STALL_MIN=30
export DRAFT_AUTO_PROMOTE=on   # matches the production incident's posture (yolo)

mkgit() {
  local d="$1"; mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" checkout -q -b main 2>/dev/null || git -C "$d" checkout -q main
  git -C "$d" config user.email t@t.test; git -C "$d" config user.name herd-test
  printf 'base\n' > "$d/base.txt"; git -C "$d" add -A; git -C "$d" commit -qm base
}
MAIN="$T/main-repo"; mkgit "$MAIN"
SLUG="sharding-tail-fix-repro"
git -C "$MAIN" worktree add -q -b "feat/$SLUG" "$TREES/$SLUG" main
SHA="$(git -C "$TREES/$SLUG" rev-parse HEAD)"
export MAIN

# ── each tick is a FRESH bash process (a true watcher restart), sourcing agent-watch.sh exactly as a
# live watcher's own exec/restart would, then re-asserting this fixture's own MAIN/TREES the same way a
# real restart re-resolves them from its OWN config (PROJECT_ROOT/WORKTREES_DIR) fresh every time. ─────
ONE_TICK="$T/one-tick.sh"
cat > "$ONE_TICK" << 'INNER'
#!/usr/bin/env bash
set -uo pipefail
. "$WATCH"
TREES="$FIXTURE_TREES"; MAIN="$FIXTURE_MAIN"
DEFAULT_BRANCH=main
_prs_fetch_tick
WT="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null || echo '')"
AGENTS_JSON="$FIXTURE_AGENTS_JSON"
FEATS=()
while IFS= read -r rec; do
  [ -n "$rec" ] && FEATS+=("$rec")
done < <(PRS_JSON="$PRS_JSON" AGENTS_JSON="$AGENTS_JSON" WT="$WT" MAIN="$MAIN" TREES="$TREES" _discover_feature_worktrees)
_FSS_ELIGIBLE=0; _FSS_RETASKED=0; _FSS_ESCALATED=0
for rec in ${FEATS[@]+"${FEATS[@]}"}; do
  IFS=$'\037' read -r dir slug branch prnum mergeable mstate astatus headsha prauthor matchkind matchdetail isdraft <<EOF
$rec
EOF
  # MUTATION-PROVE (b1): gh's REAL value for a draft PR is never the literal string "DRAFT" — if this
  # fixture ever regresses to fabricating that value (or if a future edit reintroduces the old
  # mstate=="DRAFT" comparison this leg shipped with), this line makes the drift loud immediately rather
  # than silently reintroducing the HERD-470 miss.
  if [ -n "$prnum" ] && [ "$mstate" = "DRAFT" ]; then
    echo "MUTATION-PROVE-FAIL: mergeStateStatus read the literal string DRAFT — that enum case does not exist on GitHub" >&2
    exit 3
  fi
  [ -n "$prnum" ] && _finish_stall_note_pr_opened "$slug"
  _dstall=""
  if [ -n "$prnum" ] && [ "$isdraft" = "1" ]; then
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
_FINISH_STALL_SCAN_TICK=999999   # every tick is a fresh process anyway; always emit the scan summary
_finish_stall_scan_summary "$_FSS_ELIGIBLE" "$_FSS_RETASKED" "$_FSS_ESCALATED"
INNER
chmod +x "$ONE_TICK"
export WATCH
export FIXTURE_TREES="$TREES" FIXTURE_MAIN="$MAIN"
export FIXTURE_AGENTS_JSON="{\"result\":{\"agents\":[{\"name\":\"$SLUG\",\"agent_status\":\"idle\"}]}}"   # (d)

mk_prs_json() {
  local mstate="$1" isdraft="$2"
  python3 -c '
import json
print(json.dumps([
  {"number":905,"title":"'"$SLUG"'","headRefName":"feat/'"$SLUG"'","headRefOid":"'"$SHA"'","mergeable":"MERGEABLE","mergeStateStatus":"'"$mstate"'","isDraft":'"$isdraft"'},
]))
'
}

NOW=5000000000
tick() { HERD_NOW_EPOCH="$1" bash "$ONE_TICK" || fail "tick at $1 exited $? (see stderr above)"; }

echo "=== production repro: draft, idle, re-drafted, restart-every-tick, no watcher-observed healthcheck ==="
# (b) opens DRAFT (isDraft=true, mergeStateStatus=UNKNOWN — gh's REAL value, never "DRAFT")
export LIVE_TICK_PRS_JSON="$(mk_prs_json UNKNOWN True)"
tick "$((NOW + 60))"
# (b) briefly READY (isDraft=false) mid-iteration — the anchor correctly clears; this is NOT the bug
export LIVE_TICK_PRS_JSON="$(mk_prs_json CLEAN False)"
tick "$((NOW + 120))"
# (b) re-drafted (isDraft=true again) — a fresh anchor forms HERE; this is the anchor the rail must fire
export LIVE_TICK_PRS_JSON="$(mk_prs_json UNKNOWN True)"
REDRAFT_AT=$((NOW + 180))
tick "$REDRAFT_AT"

# (c) restart on every subsequent tick (a fresh process each time), idle + draft continuously, well past
# FINISH_STALL_MIN=30 (1800s) measured from the re-draft anchor above — (a) no healthcheck marker is
# EVER written anywhere in this fixture, so any pass here proves the leg never depended on one.
for off in 300 900 1500 1900 2200 2600; do
  tick "$((REDRAFT_AT + off))"
done

echo "--- journal ---"
cat "$JOURNAL_FILE"

grep -q '"event":"finish_stall_anchor".*"reason":"draft_pr"' "$JOURNAL_FILE" \
  || fail "no draft_pr anchor was ever journaled for $SLUG — the leg never even started its clock"
grep -q '"event":"finish_stall_detected".*"reason":"draft_pr"' "$JOURNAL_FILE" \
  || fail "no finish_stall_detected(reason=draft_pr) was ever journaled — reproduces the HERD-470 miss (PR #590: result=empty on every tick, forever)"
grep -q '"event":"finish_stall_scan".*"result":"empty".*"count":0' <<< "$(tail -1 "$JOURNAL_FILE")" \
  && fail "the FINAL scan tally must not still read empty/0 — the rail must have fired by now"
grep -q '"event":"draft_pr_promoted"' "$JOURNAL_FILE" \
  || fail "DRAFT_AUTO_PROMOTE=on: expected a draft_pr_promoted event once the re-drafted anchor crossed FINISH_STALL_MIN"
[ "$(cat "$GH_PR_READY_LOG" 2>/dev/null)" = "905" ] || fail "expected exactly one 'gh pr ready 905', got: $(cat "$GH_PR_READY_LOG" 2>/dev/null)"

# (a) confirm this whole run never depended on — or produced — any watcher-observed healthcheck record.
# The production incident's builder ran ONLY its own lane-local `--light` check, which never touches
# $TREES; a healthcheck marker appearing here would mean this fixture accidentally tested a different,
# easier condition than production's.
shopt -s nullglob
_health_markers=("$TREES"/.health-inflight-* "$TREES"/.health-log-*)
shopt -u nullglob
[ "${#_health_markers[@]}" -eq 0 ] || fail "a healthcheck marker exists (${_health_markers[*]}) — this run must prove detection independent of any watcher-observed suite"
ok

echo "ok — $pass production-shaped draft-rail assertions passed"
