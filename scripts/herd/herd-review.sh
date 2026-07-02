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
#   PLACEMENT (Review pane v2): when the builder's tab for slug S still exists, the reviewer
#   runs as a BOTTOM SPLIT PANE inside that tab (herdr agent start ... --split down) so the
#   human watches the genuine Claude TUI work alongside the feature. Falls back to a standalone
#   review·<slug> tab when the builder tab is gone, or when herdr is unavailable. Whichever
#   pane/tab is created is registered in $WORKTREES_DIR/.herd-tabs so teardown handles it.
#
#   REVIEWER AGENT (agent-pane mode): the agent runs interactively in the TUI — the user sees
#   Opus reasoning live. The agent task instructs it to write the verdict to the result file as
#   its final action. herd-review.sh holds the inflight marker (pid) while polling for that
#   file, so the watcher's dead-pid detection and INFRA retry path work unchanged.
#
#   HEADLESS FALLBACK: when herdr is absent, or the builder tab is gone, or the agent start
#   fails, falls back to claude -p. The formatter now emits tool name + one-line input summary
#   (bash command, file path, etc.) — never bare '[tool] Bash'.
#
# CONTRACT WITH agent-watch.sh (the caller)
# -----------------------------------------
# Prints exactly one verdict line to stdout as its final output:
#       REVIEW: PASS
#       REVIEW: BLOCK — <one-line reason>
#       REVIEW: INFRA-FAIL — <one-line reason>   (transient; watcher retries, never caches)
# The watcher merges ONLY on PASS. On BLOCK (or ANY failure to obtain a parseable verdict) it must
# NOT merge — and this script DEFAULTS TO BLOCK when uncertain: if the reviewer runs but prints no
# verdict, we emit `REVIEW: BLOCK — …` AND post a fallback PR comment. INFRA-FAIL is DISTINCT from
# BLOCK: it means the reviewer COULD NOT RUN (log-alloc failure, claude crash with no output, or
# this process being SEVERED mid-review by SIGTERM/SIGPIPE — a trap converts that death into an
# INFRA-FAIL report), not that it found a defect. The watcher must NOT persist INFRA-FAIL to the
# review ledger — it surfaces "review errored · will retry" and retries next cycle. Exit status:
# 0 = PASS, 1 = BLOCK (genuine finding or default-to-block), 2 = INFRA-FAIL (transient; retry).
#
# RESULT FILE (background dispatch — the verdict-file contract shared with Review pane v2):
# when $HERD_REVIEW_RESULT_FILE is set, the SAME verdict line is also written there ATOMICALLY
# (temp + mv, never partial) as this script's LAST act — after the log banner, PR comment, and
# pane rename. agent-watch.sh dispatches reviews in the background with this env set to
# $WORKTREES_DIR/.review-result-<pr>-<sha> and treats the file's EXISTENCE as review completion;
# a reviewer that dies without writing one is detected by its dead pid and retried. The file is
# authoritative only for the pr+sha its name encodes — the watcher discards it if the PR has moved
# to a newer head.
#
# Env overrides:
#   HERD_CLAUDE_FLAGS              flags passed to claude (default: --dangerously-skip-permissions)
#   HERD_REVIEW_MODEL              review model (default: $MODEL_REVIEW — a STRONG model on purpose)
#   HERD_NO_PANE=1                 skip the live herdr pane (runs headless)
#   HERD_REVIEW_RESULT_FILE        also write the final verdict line here (atomic, last act)
#   HERD_REVIEW_AGENT_TIMEOUT      max seconds to wait for agent-pane verdict (default: 1800)
#   HERD_REVIEW_AGENT_POLL         poll interval seconds for agent-pane result (default: 5)
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

# _emit_verdict <line> — the single exit channel for the verdict. Prints the line to stdout
# (the synchronous contract), then — as the LAST act — atomically writes it to
# $HERD_REVIEW_RESULT_FILE when set (the background contract: temp + mv so the watcher never
# reads a partial file; its existence signals completion). Every exit path funnels through here.
_emit_verdict() {
  printf '%s\n' "$1" 2>/dev/null || true
  if [ -n "${HERD_REVIEW_RESULT_FILE:-}" ]; then
    _rf_tmp="${HERD_REVIEW_RESULT_FILE}.tmp.$$"
    if printf '%s\n' "$1" > "$_rf_tmp" 2>/dev/null; then
      mv -f "$_rf_tmp" "$HERD_REVIEW_RESULT_FILE" 2>/dev/null || rm -f "$_rf_tmp" 2>/dev/null || true
    fi
  fi
}

# A SEVERED review (killed by a stray sweep, or its stdout pipe torn down by a dying watcher) is
# an INFRA failure, NOT a refused verdict: report INFRA-FAIL so the watcher retries instead of
# caching a bogus BLOCK against the sha. With PIPE trapped, writes to a broken stdout return an
# error (handled in _emit_verdict) instead of killing us before we can report.
_severed() {
  _emit_verdict 'REVIEW: INFRA-FAIL — review severed (SIGTERM/SIGPIPE) before a verdict'
  exit 2
}
trap _severed TERM PIPE

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
  _emit_verdict "REVIEW: BLOCK — ${reason}"
  exit 1
}

# emit_infra_fail <reason> — TRANSIENT infrastructure failure. The reviewer COULD NOT RUN; this is
# NOT a finding. Prints REVIEW: INFRA-FAIL (exit 2) so the watcher knows NOT to cache the result —
# it will surface "review errored · will retry" and re-attempt next cycle. Does NOT post a PR
# comment (no finding to report; a comment on every retry would be spammy).
emit_infra_fail() {
  _emit_verdict "REVIEW: INFRA-FAIL — $1"
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

# The fixed reviewer task — headless path. Scoped hard to CORRECTNESS; default BLOCK; read-only;
# one machine verdict printed as the final line (parsed from $LOG).
TASK="You are an ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for PR #${PR} (branch slug '${SLUG}') of the project '${WORKSPACE_NAME}', where a SILENTLY WRONG result is the worst outcome (it doesn't crash, it just produces bad output/data). Your ONLY job: read THIS PR's diff with 'gh pr diff ${PR}' and hunt HARD for a concrete CORRECTNESS or DATA-INTEGRITY bug introduced by the diff. Look especially for: ${CHECKLIST_TEXT}. RULES: (1) SCOPE = CORRECTNESS ONLY. Ignore style, naming, formatting, test coverage, and subjective design — those are NOT grounds to block. (2) You are READ-ONLY: DO NOT edit any file, DO NOT commit, push, or merge. The only write you may do is ONE 'gh pr comment ${PR} --body \"…\"'. (3) DEFAULT TO BLOCK WHEN UNCERTAIN: if you find a real correctness/data-integrity bug, OR you cannot convince yourself the diff is correct, BLOCK. Only PASS when you are confident the diff is correct. (4) Post a brief PR comment summarizing your finding via 'gh pr comment ${PR} --body \"…\"' (one tight paragraph: PASS rationale, or the bug + why it's wrong). (5) FINALLY, as the LAST thing you print, output EXACTLY ONE line and nothing after it — either 'REVIEW: PASS' or 'REVIEW: BLOCK — <one-line reason>'. That line is parsed by a machine; do not add markdown, quotes, or extra text around it."

# Agent-pane result file: the agent writes its verdict here as its final action.
# Use $HERD_REVIEW_RESULT_FILE when set (watcher-dispatch mode); otherwise allocate a
# temp file (standalone use). $AGENT_TASK below has this path baked in.
_agent_result_file="${HERD_REVIEW_RESULT_FILE:-}"
if [ -z "$_agent_result_file" ]; then
  _agent_result_file="$(mktemp "${TMPDIR:-/tmp}/herd-review-agent-verdict-${PR}-XXXXXX" 2>/dev/null || true)"
fi

# Agent-pane task: same correctness rules as TASK, but the final instruction tells the agent to
# WRITE the verdict to $_agent_result_file (not just print it). The agent runs in the TUI so the
# human sees genuine Opus reasoning in the builder's tab; the result file is how herd-review.sh
# (polling in the background) captures the machine verdict.
AGENT_TASK="You are an ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for PR #${PR} (branch slug '${SLUG}') of the project '${WORKSPACE_NAME}', where a SILENTLY WRONG result is the worst outcome (it doesn't crash, it just produces bad output/data). Your ONLY job: read THIS PR's diff with 'gh pr diff ${PR}' and hunt HARD for a concrete CORRECTNESS or DATA-INTEGRITY bug introduced by the diff. Look especially for: ${CHECKLIST_TEXT}. RULES: (1) SCOPE = CORRECTNESS ONLY. Ignore style, naming, formatting, test coverage, and subjective design — those are NOT grounds to block. (2) You are READ-ONLY: DO NOT edit any file, DO NOT commit, push, or merge. The ONLY writes you may do are: ONE 'gh pr comment ${PR} --body \"…\"' and the result-file write described in rule 5. (3) DEFAULT TO BLOCK WHEN UNCERTAIN: if you find a real correctness/data-integrity bug, OR you cannot convince yourself the diff is correct, BLOCK. Only PASS when you are confident the diff is correct. (4) Post a brief PR comment summarizing your finding via 'gh pr comment ${PR} --body \"…\"' (one tight paragraph: PASS rationale, or the bug + why it's wrong). (5) FINALLY, as your absolute LAST action, write the machine verdict the merge gate reads — this step is MANDATORY — by running exactly one of these commands: printf 'REVIEW: PASS\n' > '${_agent_result_file}' OR printf 'REVIEW: BLOCK — <one-line reason>\n' > '${_agent_result_file}'. The file path is: ${_agent_result_file}. Do not skip this step."

# --- Pane placement (Review pane v2) ---
# Preferred: bottom split inside the builder's existing tab so the review appears WITH the work,
# and the human watches the genuine Claude TUI. Fallback: standalone review·<slug> tab when the
# builder tab is gone, when herdr is unavailable, or when the agent start fails.
TAB="" ROOT="" _AGENT_PANE_MODE=0
if [ "${HERD_NO_PANE:-}" != "1" ] && command -v herdr >/dev/null 2>&1 && [ -n "$_agent_result_file" ]; then

  # Find the builder's agent pane_id (agent named $SLUG; any status — it may be idle after PR).
  _builder_pane="$(herdr agent list 2>/dev/null | SLUG="$SLUG" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
    agents = (json.load(sys.stdin).get("result") or {}).get("agents") or []
    for a in agents:
        if a.get("name") == slug:
            print(a.get("pane_id", ""), end="")
            break
except Exception:
    pass
' 2>/dev/null || true)"

  # Find the builder's tab_id (tab labeled exactly $SLUG in this workspace).
  _builder_tab="$(herdr tab list ${_WS_ID:+--workspace "$_WS_ID"} 2>/dev/null | SLUG="$SLUG" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
    tabs = json.load(sys.stdin).get("result", {}).get("tabs", [])
    print(next((t["tab_id"] for t in tabs if t.get("label") == slug), ""))
except Exception:
    pass
' 2>/dev/null || true)"

  if [ -n "${_builder_pane:-}" ] && [ -n "${_builder_tab:-}" ]; then
    # Try to start the review agent as a bottom split inside the builder's tab.
    _agent_start_out="$(herdr agent start "review·$SLUG" \
      ${_WS_ID:+--workspace "$_WS_ID"} \
      --cwd "$CWD" \
      --tab "$_builder_tab" \
      --split down \
      --no-focus \
      2>/dev/null -- claude --model "$REVIEW_MODEL" $CLAUDE_FLAGS "$AGENT_TASK" 2>/dev/null || true)"
    ROOT="$(printf '%s' "${_agent_start_out:-}" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)["result"]
    print(d.get("agent", {}).get("pane_id", ""))
except Exception:
    pass
' 2>/dev/null || true)"

    if [ -n "${ROOT:-}" ]; then
      TAB="$_builder_tab"
      _AGENT_PANE_MODE=1
      # Review pane is inside the builder's tab — no separate registry entry needed; tearing
      # down the builder tab (on merge) will close this split automatically.
    fi
  fi

  if [ "$_AGENT_PANE_MODE" = "0" ]; then
    # Fallback: standalone review·<slug> tab, tailing the headless review log.
    # Close any existing review tab for this slug so we don't accumulate tabs.
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
    # Register in the sweep allowlist so only engine-created tabs are ever swept.
    [ -n "${TAB:-}" ] && printf 'review·%s %s review\n' "$SLUG" "$TAB" >> "$WORKTREES_DIR/.herd-tabs" 2>/dev/null || true
  fi
fi

echo "🔬 Reviewing PR #${PR} ($SLUG) on ${REVIEW_MODEL} — adversarial correctness/data-integrity pass…" >&2

if [ "$_AGENT_PANE_MODE" = "1" ]; then
  # Agent-pane mode: the reviewer runs in the TUI and writes its verdict to $_agent_result_file.
  # Poll for the result file (written atomically by the agent as its final act).
  # Timeout: HERD_REVIEW_AGENT_TIMEOUT seconds (default 1800 = 30 min; override in tests).
  # Poll interval: HERD_REVIEW_AGENT_POLL seconds (default 5; override in tests).
  _poll_deadline=$(( $(date +%s) + ${HERD_REVIEW_AGENT_TIMEOUT:-1800} ))
  _poll_interval="${HERD_REVIEW_AGENT_POLL:-5}"
  while [ ! -f "$_agent_result_file" ]; do
    if [ "$(date +%s)" -ge "$_poll_deadline" ]; then
      emit_infra_fail "agent-pane reviewer timed out (${HERD_REVIEW_AGENT_TIMEOUT:-1800}s) without writing a verdict to '${_agent_result_file}'"
    fi
    sleep "$_poll_interval"
  done
  verdict_line="$(grep -E '^[[:space:]]*REVIEW: (PASS|BLOCK)' "$_agent_result_file" 2>/dev/null | tail -1 | sed -E 's/^[[:space:]]+//')"
else
  # Headless mode: stream claude -p into $LOG with an informative formatter.
  # The formatter emits: tool name + one-line input summary (bash command, file path, etc.)
  # and the reviewer's reasoning text — never the old bare '[tool] Bash'.
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
                name = b.get("name", "?")
                inp  = b.get("input") or {}
                if name == "Bash":
                    cmd  = str(inp.get("command") or inp.get("cmd") or "").strip()
                    hint = cmd.split("\n")[0][:80] if cmd else ""
                elif name in ("Read", "Write", "Edit"):
                    hint = str(inp.get("file_path") or inp.get("path") or "")[:80]
                elif name == "WebFetch":
                    hint = str(inp.get("url") or "")[:80]
                elif name == "WebSearch":
                    hint = str(inp.get("query") or "")[:80]
                else:
                    first_val = next(iter(inp.values()), "") if inp else ""
                    hint = str(first_val)[:80] if first_val else ""
                print(("  [" + name + "] " + hint) if hint else ("  [" + name + "]"), flush=True)
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
  # the exact 'REVIEW: PASS' / 'REVIEW: BLOCK' shape so stray prose can't be misread.
  verdict_line="$(grep -E '^[[:space:]]*REVIEW: (PASS|BLOCK)' "$LOG" 2>/dev/null | tail -1 | sed -E 's/^[[:space:]]+//')"
fi

# Common verdict handling — same exit contract regardless of whether we used agent-pane or headless.
# No verdict at all → default to BLOCK.
case "$verdict_line" in
  "REVIEW: PASS")
    _mark_review_done PASS
    _emit_verdict "REVIEW: PASS"
    exit 0
    ;;
  "REVIEW: BLOCK"*)
    _mark_review_done BLOCK
    _emit_verdict "$verdict_line"
    exit 1
    ;;
  *)
    emit_block "reviewer produced no parseable verdict (defaulting to BLOCK)"
    ;;
esac
