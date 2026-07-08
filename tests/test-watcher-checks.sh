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
# HERD-156 (1): do_merge PINS the merge to the gate-verified sha.
# The re-verify → body-fetch → pre-merge-steps window lets a commit land AFTER the gates passed on the
# reviewed sha; --match-head-commit <gated-sha> makes gh REFUSE such a merge so nothing unreviewed can
# slip in. We swap in an arg-capturing `gh` stub, isolate do_merge's post-merge side effects behind
# no-op stubs, and drive both the pinned-success and the sha-moved-refusal paths.
# ════════════════════════════════════════════════════════════════════════════
type do_merge >/dev/null 2>&1 || fail "do_merge not defined after sourcing (lib mode)"

# arg-capturing gh: log every `pr merge` invocation's full argv, and fail with $GH_MERGE_RC to
# simulate a moved head (gh exits non-zero when --match-head-commit no longer matches the remote head).
GH_MERGE_ARGS="$T/merge-args.log"; export GH_MERGE_ARGS GH_MERGE_RC
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") printf '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n' ;;
  "pr merge") printf '%s\n' "$*" >> "${GH_MERGE_ARGS:?GH_MERGE_ARGS unset}"; exit "${GH_MERGE_RC:-0}" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"

# Isolate do_merge: point every state file at the sandbox and neutralize the post-merge sequence so the
# test exercises ONLY the gh-invocation + merge-row logic (the reap/refresh/reconcile steps have their
# own coverage and need a live worktree/tab/main checkout we deliberately don't build here).
export WORKTREES_DIR="$T" TREES="$T" MAIN="$T"
STATE="$T/.agent-watch-merged"; export STATE
REVIEW_STATE="$T/.agent-watch-reviewed"; export REVIEW_STATE
JOURNAL_FILE="$T/journal.jsonl"; export JOURNAL_FILE
DRYRUN=""; export DRYRUN
_slug_ref(){ printf 'HERD-156'; }              # skip the network _reconcile_pr_ref fallback
_flair_enabled(){ return 1; }                  # flair off → no celebrate marker
steps_run_at(){ return 0; }                    # no operator steps
purge_pr_approvals(){ :; }
cost_emit_merge(){ :; }
reconcile_backlog(){ :; }
refresh_codemap(){ :; }
refresh_symbol_index(){ :; }
main_health_tick(){ :; }
_reap_slug(){ :; }

GATED_SHA="abcdef1234567890abcdef1234567890abcdef12"

# ── success: head still at the gated sha → gh gets --match-head-commit <gated sha>, PR is recorded ──
: > "$GH_MERGE_ARGS"; : > "$STATE"; GH_MERGE_RC=0
do_merge "my-slug" 4242 "$T/wt" "$GATED_SHA" || fail "do_merge should return 0 when the head matches"
grep -q -- "--match-head-commit $GATED_SHA" "$GH_MERGE_ARGS" \
  || fail "gh pr merge must receive --match-head-commit with the gated sha (got: $(cat "$GH_MERGE_ARGS"))"
grep -q ' 4242 my-slug' "$STATE" || fail "a matched-head merge must write the \$STATE merge row"
ok

# ── sha moved: gh refuses (rc≠0) → journal merge_refused_sha_moved, and NO merge row is written ──────
: > "$GH_MERGE_ARGS"; : > "$STATE"; : > "$JOURNAL_FILE"; GH_MERGE_RC=1
if do_merge "my-slug" 4242 "$T/wt" "$GATED_SHA"; then
  fail "do_merge must return non-zero when the gated sha no longer matches the head"
fi
ok
grep -q -- "--match-head-commit $GATED_SHA" "$GH_MERGE_ARGS" \
  || fail "the refused merge must still have ATTEMPTED the pinned merge"
grep -q 'merge_refused_sha_moved' "$JOURNAL_FILE" \
  || fail "a sha-moved refusal must journal merge_refused_sha_moved (got: $(cat "$JOURNAL_FILE"))"
[ -s "$STATE" ] && fail "a refused merge must NOT write the \$STATE merge row (leaves the PR for re-gate)"
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
