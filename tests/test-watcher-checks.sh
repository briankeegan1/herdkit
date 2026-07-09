#!/usr/bin/env bash
# test-watcher-checks.sh — hermetic test that the watcher honors branch-protection gates before
# auto-merging (required reviews / CODEOWNERS / required status checks). It stubs `gh` on PATH
# (NETWORK-FREE) to return canned `pr view --json mergeable,mergeStateStatus` payloads, sources
# agent-watch.sh's pure merge-decision helper (_should_automerge) via the AGENT_WATCH_LIB guard
# (which loads the helpers WITHOUT entering the live watch loop), and asserts the decision logic:
#   • MERGES (calls `gh pr merge`) only when mergeStateStatus == CLEAN
#   • HOLDS  (never calls `gh pr merge`) on BLOCKED / BEHIND / UNSTABLE / DIRTY / unknown / empty
# Run:  bash tests/test-watcher-checks.sh
# No `set -e`: some checks deliberately expect a non-zero predicate return; we assert explicitly.
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
# `gh pr view ... --json mergeable,mergeStateStatus` echoes a payload built from $GH_MERGEABLE /
# $GH_MSTATE. `gh pr merge ...` records the call to $GH_MERGE_LOG so we can prove no merge happens
# on a gated PR. The stub shadows any real gh because $BIN is prepended to PATH.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    printf '{"mergeable":"%s","mergeStateStatus":"%s"}\n' "${GH_MERGEABLE-MERGEABLE}" "${GH_MSTATE-CLEAN}"
    ;;
  "pr merge")
    printf 'merge %s\n' "${GH_MSTATE:-?}" >> "${GH_MERGE_LOG:?GH_MERGE_LOG unset}"
    ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# Source the watcher's helpers WITHOUT its live loop. Point config discovery at a nonexistent file
# so herd-config.sh falls back to its generic defaults — fully hermetic, no repo/.herd walk-up.
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type _should_automerge >/dev/null 2>&1 || fail "_should_automerge not defined after sourcing"

# decide <mergeStateStatus> [mergeable] — mirror the watcher's gate end-to-end: fetch the PR's real
# state through the stubbed gh, then merge ONLY when _should_automerge approves. Echoes MERGE/HOLD.
decide() {
  local m
  export GH_MSTATE="$1" GH_MERGEABLE="${2:-MERGEABLE}"
  m="$(gh pr view 1 --json mergeable,mergeStateStatus \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["mergeStateStatus"])')"
  if _should_automerge "$m"; then gh pr merge 1 --merge; echo MERGE; else echo HOLD; fi
}

GH_MERGE_LOG="$T/merge.log"; export GH_MERGE_LOG

# ── CLEAN → merges, and `gh pr merge` IS called ──────────────────────────────
: > "$GH_MERGE_LOG"
[ "$(decide CLEAN)" = "MERGE" ] || fail "CLEAN should MERGE"
grep -q "merge CLEAN" "$GH_MERGE_LOG" || fail "CLEAN should have invoked gh pr merge"
ok

# ── gated / not-ready states → HOLD, and `gh pr merge` is NOT called ──────────
for st in BLOCKED BEHIND UNSTABLE DIRTY DRAFT HAS_HOOKS UNKNOWN WEIRD ""; do
  : > "$GH_MERGE_LOG"
  d="$(decide "$st")"
  [ "$d" = "HOLD" ] || fail "state '${st:-<empty>}' should HOLD (got $d)"
  [ -s "$GH_MERGE_LOG" ] && fail "state '${st:-<empty>}' must NOT invoke gh pr merge"
  ok
done

# ── the pure predicate directly: ONLY CLEAN returns success ──────────────────
_should_automerge CLEAN   || fail "_should_automerge CLEAN should return 0"
! _should_automerge BLOCKED || fail "_should_automerge BLOCKED should return non-zero"
! _should_automerge ""      || fail "_should_automerge '' should return non-zero"
ok

# ════════════════════════════════════════════════════════════════════════════
# HERD-156 (1) + HERD-221: do_merge PINS the merge to the gate-verified sha, and on a non-zero
# `gh pr merge` exit DISTINGUISHES a genuine sha-moved refusal from "merged-but-a-later-step-failed"
# (e.g. --delete-branch failing because the branch is still checked out in its worktree).
# The re-verify → body-fetch → pre-merge-steps window lets a commit land AFTER the gates passed on the
# reviewed sha; --match-head-commit <gated-sha> makes gh REFUSE such a merge so nothing unreviewed can
# slip in. We swap in an arg-capturing `gh` stub, isolate do_merge's post-merge side effects behind
# instrumented stubs, and drive pinned-success, genuine-refusal, and merge-landed-but-rc≠0 paths.
# ════════════════════════════════════════════════════════════════════════════
type do_merge >/dev/null 2>&1 || fail "do_merge not defined after sourcing (lib mode)"

# arg-capturing gh: log every `pr merge` invocation's full argv, and fail with $GH_MERGE_RC to
# simulate either a moved head OR a post-merge local failure (branch-delete). $GH_PR_STATE is what
# `pr view --json state,mergedAt -q .state` returns so HERD-221 can tell MERGED from OPEN after a
# non-zero merge (the stub honours -q so production's jq selector sees a bare state token).
GH_MERGE_ARGS="$T/merge-args.log"; GH_VIEW_RC=0
export GH_MERGE_ARGS GH_MERGE_RC GH_PR_STATE GH_VIEW_RC
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    # GH_VIEW_RC simulates gh itself being unreadable (network blip, rate limit, expired auth): a
    # non-zero exit and NO output, exactly as real gh behaves. HERD-232 / audit G6 needs this to tell a
    # genuine sha-moved refusal apart from "we could not find out".
    [ "${GH_VIEW_RC:-0}" -ne 0 ] && exit "${GH_VIEW_RC}"
    # Honour -q / --jq so callers like `gh pr view N --json state,mergedAt -q '.state'` get a bare
    # token (matches real gh). Without this, HERD-221's MERGED check would compare full JSON ≠ MERGED.
    _q=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -q|--jq) _q="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$_q" in
      .state|state) printf '%s\n' "${GH_PR_STATE:-OPEN}" ;;
      *)
        printf '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"%s","mergedAt":%s}\n' \
          "${GH_PR_STATE:-OPEN}" \
          "$([ "${GH_PR_STATE:-OPEN}" = MERGED ] && printf '"2026-01-01T00:00:00Z"' || printf 'null')"
        ;;
    esac
    ;;
  "pr merge") printf '%s\n' "$*" >> "${GH_MERGE_ARGS:?GH_MERGE_ARGS unset}"; exit "${GH_MERGE_RC:-0}" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"

# Isolate do_merge: point every state file at the sandbox and instrument the post-merge sequence so we
# can prove which hooks ran (HERD-221) without needing a live worktree/tab/main checkout.
export WORKTREES_DIR="$T" TREES="$T" MAIN="$T"
STATE="$T/.agent-watch-merged"; export STATE
REVIEW_STATE="$T/.agent-watch-reviewed"; export REVIEW_STATE
JOURNAL_FILE="$T/journal.jsonl"; export JOURNAL_FILE
DRYRUN=""; export DRYRUN
POST_MERGE_LOG="$T/post-merge-hooks.log"; export POST_MERGE_LOG
_slug_ref(){ printf 'HERD-156'; }              # skip the network _reconcile_pr_ref fallback
_flair_enabled(){ return 1; }                  # flair off → no celebrate marker
steps_run_at(){ return 0; }                    # no operator steps
purge_pr_approvals(){ printf 'purge_pr_approvals\n' >> "$POST_MERGE_LOG"; }
purge_pr_ci_checks(){ printf 'purge_pr_ci_checks\n' >> "$POST_MERGE_LOG"; }
cost_emit_merge(){ printf 'cost_emit_merge\n' >> "$POST_MERGE_LOG"; }
reconcile_backlog(){ printf 'reconcile_backlog\n' >> "$POST_MERGE_LOG"; }
refresh_codemap(){ printf 'refresh_codemap\n' >> "$POST_MERGE_LOG"; }
refresh_symbol_index(){ printf 'refresh_symbol_index\n' >> "$POST_MERGE_LOG"; }
main_health_tick(){ printf 'main_health_tick\n' >> "$POST_MERGE_LOG"; }
_reap_slug(){ printf 'reap_slug\n' >> "$POST_MERGE_LOG"; }

GATED_SHA="abcdef1234567890abcdef1234567890abcdef12"

# post_merge_ran — true when the critical post-merge hooks all fired (never on a real refusal).
post_merge_ran() {
  grep -q 'reconcile_backlog'    "$POST_MERGE_LOG" && \
  grep -q 'refresh_codemap'      "$POST_MERGE_LOG" && \
  grep -q 'refresh_symbol_index' "$POST_MERGE_LOG" && \
  grep -q 'main_health_tick'     "$POST_MERGE_LOG" && \
  grep -q 'reap_slug'            "$POST_MERGE_LOG" && \
  grep -q 'cost_emit_merge'      "$POST_MERGE_LOG"
}

# ── success: head still at the gated sha → gh gets --match-head-commit <gated sha>, PR is recorded ──
: > "$GH_MERGE_ARGS"; : > "$STATE"; : > "$POST_MERGE_LOG"; : > "$JOURNAL_FILE"
GH_MERGE_RC=0 GH_PR_STATE=OPEN
do_merge "my-slug" 4242 "$T/wt" "$GATED_SHA" || fail "do_merge should return 0 when the head matches"
grep -q -- "--match-head-commit $GATED_SHA" "$GH_MERGE_ARGS" \
  || fail "gh pr merge must receive --match-head-commit with the gated sha (got: $(cat "$GH_MERGE_ARGS"))"
grep -q ' 4242 my-slug' "$STATE" || fail "a matched-head merge must write the \$STATE merge row"
post_merge_ran || fail "successful merge must fire post-merge hooks (got: $(cat "$POST_MERGE_LOG"))"
grep -q 'merge_refused_sha_moved' "$JOURNAL_FILE" && fail "success path must never journal merge_refused_sha_moved"
ok

# ── genuine sha moved: gh refuses (rc≠0) AND PR is still OPEN → journal refusal, skip hooks ──────
: > "$GH_MERGE_ARGS"; : > "$STATE"; : > "$JOURNAL_FILE"; : > "$POST_MERGE_LOG"
GH_MERGE_RC=1 GH_PR_STATE=OPEN
if do_merge "my-slug" 4242 "$T/wt" "$GATED_SHA"; then
  fail "do_merge must return non-zero when the gated sha no longer matches the head"
fi
ok
grep -q -- "--match-head-commit $GATED_SHA" "$GH_MERGE_ARGS" \
  || fail "the refused merge must still have ATTEMPTED the pinned merge"
grep -q 'merge_refused_sha_moved' "$JOURNAL_FILE" \
  || fail "a sha-moved refusal must journal merge_refused_sha_moved (got: $(cat "$JOURNAL_FILE"))"
[ -s "$STATE" ] && fail "a refused merge must NOT write the \$STATE merge row (leaves the PR for re-gate)"
post_merge_ran && fail "a genuine sha-moved refusal must NOT fire post-merge hooks (got: $(cat "$POST_MERGE_LOG"))"
[ -s "$POST_MERGE_LOG" ] && fail "a genuine sha-moved refusal must leave post-merge hooks silent (got: $(cat "$POST_MERGE_LOG"))"
ok

# ── HERD-221: merge LANDED but gh exited non-zero (e.g. --delete-branch failed on a checked-out
#    worktree branch). PR state is MERGED → treat as SUCCESS: journal merge, write $STATE, run ALL
#    post-merge hooks, never journal merge_refused_sha_moved.
: > "$GH_MERGE_ARGS"; : > "$STATE"; : > "$JOURNAL_FILE"; : > "$POST_MERGE_LOG"
GH_MERGE_RC=1 GH_PR_STATE=MERGED
do_merge "my-slug" 4242 "$T/wt" "$GATED_SHA" \
  || fail "do_merge must return 0 when gh exits non-zero but the PR is already MERGED"
grep -q -- "--match-head-commit $GATED_SHA" "$GH_MERGE_ARGS" \
  || fail "HERD-221 path must still have ATTEMPTED the pinned merge"
grep -q ' 4242 my-slug' "$STATE" || fail "HERD-221: MERGED-despite-rc must write the \$STATE merge row"
grep -q '"event":"merge"' "$JOURNAL_FILE" || grep -qE '(^|[[:space:]])merge([[:space:]]|$)' "$JOURNAL_FILE" \
  || fail "HERD-221: must journal the merge event (got: $(cat "$JOURNAL_FILE"))"
grep -q 'merge_refused_sha_moved' "$JOURNAL_FILE" \
  && fail "HERD-221: must NEVER journal merge_refused_sha_moved when PR is MERGED (got: $(cat "$JOURNAL_FILE"))"
post_merge_ran || fail "HERD-221: MERGED-despite-rc must fire post-merge hooks (got: $(cat "$POST_MERGE_LOG"))"
ok

# ── HERD-232 (audit G6, honest labels): gh refuses the merge AND the state re-check is ITSELF
#    unreadable (network blip / rate limit / expired auth). Nothing proves the head moved, so the
#    refusal must NOT be labelled merge_refused_sha_moved — that sends a post-mortem hunting a phantom
#    force-push. It is an infra event: merge_gh_unreadable. Still returns 1 and still skips the hooks.
: > "$GH_MERGE_ARGS"; : > "$STATE"; : > "$JOURNAL_FILE"; : > "$POST_MERGE_LOG"
GH_MERGE_RC=1 GH_PR_STATE=OPEN GH_VIEW_RC=1
if do_merge "my-slug" 4242 "$T/wt" "$GATED_SHA"; then
  fail "do_merge must return non-zero when it cannot establish the PR's state"
fi
grep -q 'merge_gh_unreadable' "$JOURNAL_FILE" \
  || fail "an unreadable gh must journal merge_gh_unreadable (got: $(cat "$JOURNAL_FILE"))"
grep -q 'merge_refused_sha_moved' "$JOURNAL_FILE" \
  && fail "G6: an unreadable gh must NEVER be labelled a sha-moved refusal (got: $(cat "$JOURNAL_FILE"))"
[ -s "$STATE" ] && fail "an unreadable gh must NOT write the \$STATE merge row"
[ -s "$POST_MERGE_LOG" ] && fail "an unreadable gh must leave post-merge hooks silent"
GH_VIEW_RC=0
ok

# …and the converse still holds: a READABLE non-MERGED state is a genuine refusal, and it now names the
# state it actually saw, so the label and the evidence agree.
: > "$GH_MERGE_ARGS"; : > "$STATE"; : > "$JOURNAL_FILE"; : > "$POST_MERGE_LOG"
GH_MERGE_RC=1 GH_PR_STATE=OPEN
if do_merge "my-slug" 4242 "$T/wt" "$GATED_SHA"; then
  fail "do_merge must return non-zero on a genuine refusal"
fi
grep -q 'merge_refused_sha_moved' "$JOURNAL_FILE" || fail "a readable OPEN state is a genuine sha-moved refusal"
grep -q '"state":"OPEN"' "$JOURNAL_FILE" || fail "the refusal must carry the state it observed (got: $(cat "$JOURNAL_FILE"))"
grep -q 'merge_gh_unreadable' "$JOURNAL_FILE" && fail "a readable state must not be labelled a gh outage"
ok

# ════════════════════════════════════════════════════════════════════════════
# HERD-156 (2): _review_gate_step RECORDS the verdict to the ledger BEFORE removing the reviewer's
# result/inflight files. A crash in the old rm→record seam lost a collected PASS/BLOCK forever; the
# new record→rm order makes the collect at-least-once. We prove the ORDER by shadowing `rm` to (a)
# assert the ledger already holds the verdict at the instant rm runs and (b) NOT delete (simulating an
# interrupt), then confirming the result file survives for a clean re-collect.
# ════════════════════════════════════════════════════════════════════════════
type _review_gate_step >/dev/null 2>&1 || fail "_review_gate_step not defined after sourcing"

: > "$REVIEW_STATE"; : > "$JOURNAL_FILE"
RG_PR=77; RG_SHA=deadbeefcafe
printf 'REVIEW: PASS\n' > "$(_review_result_file "$RG_PR" "$RG_SHA")"
_retire_reviewer_pane(){ :; }   # no pane in a headless test

RMLOG="$T/rm-order.log"; : > "$RMLOG"
# Shadow the external `rm`: at the moment the cleanup rm runs, the verdict MUST already be in the
# ledger (record ran first). Return WITHOUT deleting to simulate a crash/interrupt at the rm.
rm(){
  if grep -q " $RG_PR $RG_SHA PASS " "$REVIEW_STATE" 2>/dev/null; then
    printf 'ledger-had-row-before-rm\n' >> "$RMLOG"
  fi
  printf 'rm %s\n' "$*" >> "$RMLOG"
  return 0
}

out="$(_review_gate_step "$RG_PR" "my-slug" "$RG_SHA")"
[ "$out" = "PASS" ] || fail "_review_gate_step should echo PASS for a collected PASS verdict (got '$out')"
grep -q " $RG_PR $RG_SHA PASS " "$REVIEW_STATE" || fail "the PASS verdict must be recorded to the ledger"
grep -q 'ledger-had-row-before-rm' "$RMLOG" \
  || fail "record_review must run BEFORE rm — ledger row missing when the cleanup rm executed"
[ -f "$(_review_result_file "$RG_PR" "$RG_SHA")" ] \
  || fail "an interrupted rm must leave the result file for a re-collect (verdict never lost)"
unset -f rm   # restore the real rm for the rest of the run
ok

echo "ALL PASS ($pass checks)"
