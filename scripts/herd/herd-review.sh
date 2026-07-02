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
#       REVIEW: INFRA-FAIL — <one-line reason>   (transient; watcher retries, never caches)
# The watcher merges ONLY on PASS. On BLOCK (or ANY failure to obtain a parseable verdict) it must
# NOT merge — and this script DEFAULTS TO BLOCK when uncertain: if the reviewer runs but prints no
# verdict, we emit `REVIEW: BLOCK — …` AND post a fallback PR comment. INFRA-FAIL is DISTINCT from
# BLOCK: it means the reviewer COULD NOT RUN (log-alloc failure, claude crash with no output), not
# that it found a defect. The watcher must NOT persist INFRA-FAIL to the review ledger — it surfaces
# "review errored · will retry" and retries next cycle. Exit status: 0 = PASS, 1 = BLOCK (genuine
# finding or default-to-block), 2 = INFRA-FAIL (transient; safe to retry).
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
_WS_ID="$(herd_resolve_workspace_id)"

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

# _mark_review_done <PASS|BLOCK> — write a persistent verdict banner to $LOG and update the
# herdr pane label so the user sees the outcome in the tailing pane. Called before every exit
# so the pane is useful after the review finishes (not just during). Best-effort: any herdr
# failure is suppressed because the gate result has already been decided.
_mark_review_done() {
  local verdict="$1" pane_label emoji
  case "$verdict" in
    PASS)  pane_label="review·$SLUG ✅"; emoji="✅ PASS" ;;
    BLOCK) pane_label="review·$SLUG ⛔"; emoji="⛔ BLOCKED" ;;
    *)     return ;;
  esac
  if [ -n "${LOG:-}" ]; then
    {
      printf '\n\n─── review complete: %s ───\n' "$emoji"
      if [ "$verdict" = "BLOCK" ]; then
        printf 'Next: push a fix commit (auto re-reviews) · or: herd-approve.sh override %s\n' "$PR"
      fi
    } >> "$LOG" 2>/dev/null || true
  fi
  [ -n "${ROOT:-}" ] && herdr pane rename "$ROOT" "$pane_label" >/dev/null 2>&1 || true
}

# emit_block <reason> — DEFAULT-TO-BLOCK exit. Posts a fallback PR comment (best-effort) so the
# watcher can always rely on "a comment was posted", then prints the canonical BLOCK verdict and
# exits 1. Used when the reviewer RAN but we cannot trust a PASS (no verdict, uncertain outcome).
emit_block() {
  local reason="$1"
  gh pr comment "$PR" --body "🔬 **Pre-merge review gate — BLOCKED.** ${reason} Not merged; needs a human look." >/dev/null 2>&1 || true
  _mark_review_done BLOCK
  printf 'REVIEW: BLOCK — %s\n' "$reason"
  exit 1
}

# emit_infra_fail <reason> — TRANSIENT infrastructure failure. The reviewer COULD NOT RUN; this is
# NOT a finding. Prints REVIEW: INFRA-FAIL (exit 2) so the watcher knows NOT to cache the result —
# it will surface "review errored · will retry" and re-attempt next cycle. Does NOT post a PR
# comment (no finding to report; a comment on every retry would be spammy).
emit_infra_fail() {
  printf 'REVIEW: INFRA-FAIL — %s\n' "$1"
  exit 2
}

# Log tracking: each review writes its $LOG path to a slug-keyed tracker so the NEXT
# review of the same slug can clean up the old log (which may still be tailed by the
# old pane). The log itself is NOT deleted on EXIT — it must outlive this process so
# the persistent herdr pane keeps showing the verdict after the review finishes.
if [ -d "${WORKTREES_DIR:-}" ]; then
  _LOG_TRACK="$WORKTREES_DIR/.review-log-$SLUG"
else
  _LOG_TRACK="${TMPDIR:-/tmp}/.herd-review-log-$SLUG"
fi
if [ -f "$_LOG_TRACK" ]; then
  _old_log="$(cat "$_LOG_TRACK" 2>/dev/null || true)"
  [ -n "$_old_log" ] && rm -f "$_old_log" 2>/dev/null || true
fi

# BSD/macOS mktemp requires X's to be the LAST characters; a trailing suffix like
# ".log" after XXXXXX is a GNU-only extension that silently produces a literal filename
# on macOS and collides on any second use.  Drop the suffix — callers don't need it.
LOG="$(mktemp "${TMPDIR:-/tmp}/herd-review-${PR}-XXXXXX")" \
  || emit_infra_fail "could not allocate review log (mktemp failed)"
[ -n "$LOG" ] || emit_infra_fail "could not allocate review log (empty path)"
# Save new log path; cleaned up when the next review of this slug starts.
printf '%s\n' "$LOG" > "$_LOG_TRACK" 2>/dev/null || true
# NOTE: intentionally NO 'trap rm -f "$LOG" EXIT' — the herdr pane must keep tailing
# the log after this process exits. Cleanup happens on the next review of this slug.

# The fixed reviewer task — the coordinator does not hand-tune it (mirrors herd-resolve.sh's
# standard task). Scoped hard to CORRECTNESS; default BLOCK; read-only; one machine verdict.
TASK="You are an ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for PR #${PR} (branch slug '${SLUG}') of the project '${WORKSPACE_NAME}', where a SILENTLY WRONG result is the worst outcome (it doesn't crash, it just produces bad output/data). Your ONLY job: read THIS PR's diff with 'gh pr diff ${PR}' and hunt HARD for a concrete CORRECTNESS or DATA-INTEGRITY bug introduced by the diff. Look especially for: ${CHECKLIST_TEXT}. RULES: (1) SCOPE = CORRECTNESS ONLY. Ignore style, naming, formatting, test coverage, and subjective design — those are NOT grounds to block. (2) You are READ-ONLY: DO NOT edit any file, DO NOT commit, push, or merge. The only write you may do is ONE 'gh pr comment ${PR} --body \"…\"'. (3) DEFAULT TO BLOCK WHEN UNCERTAIN: if you find a real correctness/data-integrity bug, OR you cannot convince yourself the diff is correct, BLOCK. Only PASS when you are confident the diff is correct. (4) Post a brief PR comment summarizing your finding via 'gh pr comment ${PR} --body \"…\"' (one tight paragraph: PASS rationale, or the bug + why it's wrong). (5) FINALLY, as the LAST thing you print, output EXACTLY ONE line and nothing after it — either 'REVIEW: PASS' or 'REVIEW: BLOCK — <one-line reason>'. That line is parsed by a machine; do not add markdown, quotes, or extra text around it."

# --- Live herdr pane (best-effort, PERSISTENT): a tab tailing the live review log.
#     The pane stays OPEN after the verdict — it is only replaced when the next review
#     of this slug starts (replace, don't accumulate). If herdr is missing we skip the
#     pane entirely; the gate MUST still run headless (the watcher depends on it). ---
TAB="" ROOT=""
if [ "${HERD_NO_PANE:-}" != "1" ] && command -v herdr >/dev/null 2>&1; then
  # Close any existing review pane for this slug so we don't accumulate tabs.
  _old_tab="$(SLUG="$SLUG" herdr tab list 2>/dev/null | python3 -c '
import sys, json, os
slug = "review·" + os.environ.get("SLUG", "")
try:
    tabs = json.load(sys.stdin).get("result", {}).get("tabs", [])
    print(next((t["tab_id"] for t in tabs if t.get("label","").startswith(slug)), ""))
except Exception:
    pass
' 2>/dev/null || true)"
  [ -n "${_old_tab:-}" ] && herdr tab close "$_old_tab" >/dev/null 2>&1 || true

  created="$(herdr tab create ${_WS_ID:+--workspace "$_WS_ID"} --cwd "$CWD" --label "review·$SLUG" --no-focus 2>/dev/null || true)"
  read -r TAB ROOT < <(printf '%s' "$created" | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' 2>/dev/null || true)
  if [ -n "${ROOT:-}" ]; then
    herdr pane rename "$ROOT" "review·$SLUG" >/dev/null 2>&1 || true
    herdr pane run "$ROOT" "tail -f '$LOG'" >/dev/null 2>&1 || true
  fi
fi

echo "🔬 Reviewing PR #${PR} ($SLUG) on ${REVIEW_MODEL} — adversarial correctness/data-integrity pass…" >&2

# Stream the reviewer's progress into $LOG as it happens via --output-format stream-json so the
# herdr pane shows live activity instead of a blank screen. A compact python3 formatter emits one
# line per assistant turn / tool call; the full final text (from the stream-json 'result' event)
# is also written so verdict parsing at the end works unchanged. set -o pipefail ensures a non-zero
# exit from claude propagates even though python3 is the last stage of the pipeline.
(set -o pipefail; cd "$CWD" 2>/dev/null && \
  claude -p "$TASK" --model "$REVIEW_MODEL" $CLAUDE_FLAGS \
    --output-format stream-json --verbose 2>&1 | \
  python3 -uc '
import sys, json
for line in sys.stdin:
    line = line.rstrip()
    if not line: continue
    try: obj = json.loads(line)
    except Exception: print(line, flush=True); continue
    t = obj.get("type", "")
    if t == "assistant":
        for b in obj.get("message", {}).get("content", []):
            if b.get("type") == "text":
                txt = b.get("text", "").strip()
                if txt: print("  " + txt.split("\n")[0][:100], flush=True)
            elif b.get("type") == "tool_use":
                print("  [tool] " + b.get("name", "?"), flush=True)
    elif t == "result":
        r = obj.get("result", "")
        if r: print(r, flush=True)
') >>"$LOG" 2>&1
rc=$?

if [ "$rc" -ne 0 ]; then
  # If claude exited non-zero but left a parseable verdict in the log, honour it — fall through to
  # verdict parsing below. If there is NO verdict line, the reviewer crashed before reaching a
  # conclusion; that is a transient infra failure, not a genuine finding (don't cache as BLOCK).
  if ! grep -qE '^[[:space:]]*REVIEW: (PASS|BLOCK)' "$LOG" 2>/dev/null; then
    emit_infra_fail "reviewer agent exited non-zero (rc=$rc) with no verdict — could not complete the review"
  fi
fi

# Parse the LAST canonical verdict line the agent printed. Tolerate leading whitespace; require
# the exact 'REVIEW: PASS' / 'REVIEW: BLOCK' shape so stray prose can't be misread. No verdict
# line at all → default to BLOCK.
verdict_line="$(grep -E '^[[:space:]]*REVIEW: (PASS|BLOCK)' "$LOG" 2>/dev/null | tail -1 | sed -E 's/^[[:space:]]+//')"
case "$verdict_line" in
  "REVIEW: PASS")
    _mark_review_done PASS
    echo "REVIEW: PASS"
    exit 0
    ;;
  "REVIEW: BLOCK"*)
    _mark_review_done BLOCK
    printf '%s\n' "$verdict_line"
    exit 1
    ;;
  *)
    emit_block "reviewer produced no parseable verdict (defaulting to BLOCK)"
    ;;
esac
