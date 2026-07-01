#!/usr/bin/env bash
# herd-review.sh <pr> <slug> — the PRE-MERGE ADVERSARIAL REVIEW GATE.
#
# WHY THIS EXISTS
# --------------
# agent-watch.sh auto-merges any PR that is CLEAN + healthcheck-green. Healthcheck only proves the
# code still BUILDS/boots and the smoke test passes — it says NOTHING about whether the diff is
# CORRECT. So until this gate, every sub-agent's diff merged un-reviewed. A silently-wrong diff
# (it doesn't crash, it just does the wrong thing) is the worst failure mode. This gate puts a
# STRONG model (Opus) in front of the merge to adversarially hunt for a correctness bug in THAT
# PR's diff before it can land. The project's specific risk list is injected from
# $REVIEW_CHECKLIST (.herd/config) when present, so the gate knows what "silently wrong" looks
# like for THIS project.
#
# WHAT IT DOES (mirrors the isolated-agent pattern in herd-resolve.sh)
# -------------------------------------------------------------------
#   - Optionally opens a herdr pane (tab `review·<slug>`) tailing the live review log.
#   - Runs a READ-ONLY reviewer agent on a strong model over the PR's diff (`gh pr diff <pr>`),
#     prompted to: hunt ADVERSARIALLY for ONE concrete correctness/data-integrity bug, stay scoped
#     to CORRECTNESS (not style/nits), DEFAULT TO BLOCK when uncertain, NOT edit/push/merge
#     (read-only), post a brief PR comment, and print EXACTLY one machine-parseable verdict line.
#
# CONTRACT WITH agent-watch.sh (the caller)
# -----------------------------------------
# Synchronous; prints exactly one verdict line to stdout, which the watcher captures:
#       REVIEW: PASS
#       REVIEW: BLOCK — <one-line reason>
# The watcher merges ONLY on PASS. On BLOCK (or ANY failure to obtain a parseable verdict) it must
# NOT merge — and this script DEFAULTS TO BLOCK when uncertain: if the reviewer dies, times out, or
# prints no verdict, we emit `REVIEW: BLOCK — …` AND post a fallback PR comment. Exit status
# mirrors the verdict (0 = PASS, non-zero = BLOCK).
#
# Env overrides:
#   HERD_CLAUDE_FLAGS   flags passed to claude (default: --dangerously-skip-permissions — the
#                       reviewer needs gh tool access to read the diff + post a comment; it is
#                       sandboxed to READ-ONLY by its prompt, never editing/pushing).
#   HERD_REVIEW_MODEL   review model (default: $MODEL_REVIEW — a STRONG model on purpose).
#   HERD_NO_PANE=1      skip the live herdr pane (the review still runs headless).
#
# Standalone:
#   herd-review.sh 57 dividend-history
# Or driven by agent-watch.sh as the pre-merge gate.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
MAIN="$PROJECT_ROOT"
PR="${1:?usage: herd-review.sh <pr> <slug>}"
SLUG="${2:?usage: herd-review.sh <pr> <slug>}"
DIR="$WORKTREES_DIR/$SLUG"
CLAUDE_FLAGS="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"
REVIEW_MODEL="${HERD_REVIEW_MODEL:-$MODEL_REVIEW}"

# Review FROM the feature worktree if it still exists (gives the reviewer the diff's repo context
# + any AGENTS.md/CLAUDE.md); otherwise fall back to the main checkout. `gh pr diff` works from
# either, so a missing worktree degrades gracefully rather than aborting the gate.
CWD="$DIR"; [ -d "$DIR/.git" ] || [ -e "$DIR/.git" ] || CWD="$MAIN"

# Project risk list: inject $REVIEW_CHECKLIST (committed, repo-relative) when present so the
# reviewer hunts for THIS project's silently-wrong patterns. Absent → a generic correctness list.
CHECKLIST_TEXT="wrong values/math (sign errors, off-by-one, rounding, unit/type mix-ups), mishandled None/empty/NaN, mutated-while-iterating, broken dedup/idempotency keys, swapped inputs, a partial-failure that silently writes bad data, and incorrect aggregation"
_cl_path=""
[ -n "$REVIEW_CHECKLIST" ] && { [ -f "$CWD/$REVIEW_CHECKLIST" ] && _cl_path="$CWD/$REVIEW_CHECKLIST"; [ -f "$MAIN/$REVIEW_CHECKLIST" ] && _cl_path="$MAIN/$REVIEW_CHECKLIST"; }
if [ -n "$_cl_path" ]; then
  CHECKLIST_TEXT="the project's risk checklist:
$(cat "$_cl_path" 2>/dev/null)"
fi

# emit_block <reason> — DEFAULT-TO-BLOCK exit. Posts a fallback PR comment (best-effort) so the
# watcher can always rely on "a comment was posted", then prints the canonical BLOCK verdict and
# exits non-zero. Used whenever we cannot trust a PASS.
emit_block() {
  local reason="$1"
  gh pr comment "$PR" --body "🔬 **Pre-merge review gate — BLOCKED.** ${reason} Not merged; needs a human look." >/dev/null 2>&1 || true
  printf 'REVIEW: BLOCK — %s\n' "$reason"
  exit 1
}

# BSD/macOS mktemp requires X's to be the LAST characters; a trailing suffix like
# ".log" after XXXXXX is a GNU-only extension that silently produces a literal filename
# on macOS and collides on any second use.  Drop the suffix — callers don't need it.
LOG="$(mktemp "${TMPDIR:-/tmp}/herd-review-${PR}-XXXXXX")" \
  || emit_block "could not allocate review log (mktemp failed)"
[ -n "$LOG" ] || emit_block "could not allocate review log (empty path)"
trap 'rm -f "$LOG"' EXIT

# The fixed reviewer task — the coordinator does not hand-tune it (mirrors herd-resolve.sh's
# standard task). Scoped hard to CORRECTNESS; default BLOCK; read-only; one machine verdict.
TASK="You are an ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for PR #${PR} (branch slug '${SLUG}') of the project '${WORKSPACE_NAME}', where a SILENTLY WRONG result is the worst outcome (it doesn't crash, it just produces bad output/data). Your ONLY job: read THIS PR's diff with 'gh pr diff ${PR}' and hunt HARD for a concrete CORRECTNESS or DATA-INTEGRITY bug introduced by the diff. Look especially for: ${CHECKLIST_TEXT}. RULES: (1) SCOPE = CORRECTNESS ONLY. Ignore style, naming, formatting, test coverage, and subjective design — those are NOT grounds to block. (2) You are READ-ONLY: DO NOT edit any file, DO NOT commit, push, or merge. The only write you may do is ONE 'gh pr comment ${PR} --body \"…\"'. (3) DEFAULT TO BLOCK WHEN UNCERTAIN: if you find a real correctness/data-integrity bug, OR you cannot convince yourself the diff is correct, BLOCK. Only PASS when you are confident the diff is correct. (4) Post a brief PR comment summarizing your finding via 'gh pr comment ${PR} --body \"…\"' (one tight paragraph: PASS rationale, or the bug + why it's wrong). (5) FINALLY, as the LAST thing you print, output EXACTLY ONE line and nothing after it — either 'REVIEW: PASS' or 'REVIEW: BLOCK — <one-line reason>'. That line is parsed by a machine; do not add markdown, quotes, or extra text around it."

# --- Live herdr pane (best-effort): a tab whose root pane tails the review log so the human can
#     watch the reviewer work. If herdr is missing we simply skip the pane — the gate MUST still
#     run headless (the watcher depends on it). ---
TAB=""
if [ "${HERD_NO_PANE:-}" != "1" ]; then
  created="$(herdr tab create --cwd "$CWD" --label "review·$SLUG" --no-focus 2>/dev/null || true)"
  read -r TAB ROOT < <(printf '%s' "$created" | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' 2>/dev/null || true)
  if [ -n "${ROOT:-}" ]; then
    herdr pane rename "$ROOT" "review·$SLUG" >/dev/null 2>&1 || true
    herdr pane run "$ROOT" "tail -f '$LOG'" >/dev/null 2>&1 || true
  fi
fi

echo "🔬 Reviewing PR #${PR} ($SLUG) on ${REVIEW_MODEL} — adversarial correctness/data-integrity pass…" >&2

# Run the reviewer in the FOREGROUND (the watcher needs the verdict synchronously) and capture
# everything to $LOG (the herdr pane tails it). If claude itself fails to run, that's a
# default-to-BLOCK: a gate that can't review must not wave a diff through.
( cd "$CWD" 2>/dev/null && claude -p "$TASK" --model "$REVIEW_MODEL" $CLAUDE_FLAGS ) >>"$LOG" 2>&1
rc=$?

# Close the review pane now that the synchronous review is done. Best-effort; the finding lives on
# in the PR comment regardless.
[ -n "$TAB" ] && herdr tab close "$TAB" >/dev/null 2>&1 || true

if [ "$rc" -ne 0 ]; then
  emit_block "reviewer agent exited non-zero (rc=$rc) — could not complete the review"
fi

# Parse the LAST canonical verdict line the agent printed. Tolerate leading whitespace; require
# the exact 'REVIEW: PASS' / 'REVIEW: BLOCK' shape so stray prose can't be misread. No verdict
# line at all → default to BLOCK.
verdict_line="$(grep -E '^[[:space:]]*REVIEW: (PASS|BLOCK)' "$LOG" 2>/dev/null | tail -1 | sed -E 's/^[[:space:]]+//')"
case "$verdict_line" in
  "REVIEW: PASS")
    echo "REVIEW: PASS"
    exit 0
    ;;
  "REVIEW: BLOCK"*)
    printf '%s\n' "$verdict_line"
    exit 1
    ;;
  *)
    emit_block "reviewer produced no parseable verdict (defaulting to BLOCK)"
    ;;
esac
