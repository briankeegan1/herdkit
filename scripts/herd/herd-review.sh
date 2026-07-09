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
#       REVIEW: PASS — advisory: <note> | advisory: <note>
#       REVIEW: BLOCK — rule: <rule> | why: <reasoning> | location: <file:line or function>
#       REVIEW: INFRA-FAIL — <one-line reason>   (transient; watcher retries, never caches)
# STRUCTURED BLOCK (HERD-104): a BLOCK carries three ' | '-separated fields after the em-dash —
# rule (which correctness rule was violated), why (the reasoning), and location (file:line or
# function) — so an auto-refix bounce is ACTIONABLE. This is BACKWARD-COMPATIBLE + FAIL-SOFT: a
# legacy/unstructured 'REVIEW: BLOCK — <freeform reason>' still parses (the whole tail becomes
# 'why'; rule/location stay empty).
# CORRECTNESS-ONLY BLOCK (HERD-105): the reviewer classifies every finding as CORRECTNESS (blocking)
# or ADVISORY (style/hardening/nitpick — non-blocking) and BLOCKs only when there is >=1 correctness
# finding; otherwise it PASSes, carrying any advisory findings as ' | '-separated 'advisory:' notes
# after the em-dash so they surface in the PR comment + journal WITHOUT gating the merge. A finding-
# free PASS is still the byte-identical bare 'REVIEW: PASS' — the advisory tail is appended ONLY when
# there is at least one non-blocking note, so the default (no advisories) is unchanged from before.
# The watcher merges ONLY on PASS. A BLOCK is a REVIEWER-BACKED refusal — a genuine finding the
# reviewer both printed AND (best-effort) posted as a PR comment; only these are cached against the
# sha and only these may auto-refix a builder. INFRA-FAIL is DISTINCT from BLOCK: the reviewer COULD
# NOT reach a verdict — log-alloc failure, claude crash/EMPTY output, exit rc=0 WITHOUT a verdict
# line, or this process being SEVERED mid-review by SIGTERM/SIGPIPE (a trap converts that death into
# an INFRA-FAIL report). Crucially we NO LONGER default a no-verdict run to BLOCK: an infrastructural
# death must never masquerade as a refused verdict. The watcher must NOT persist INFRA-FAIL to the
# review ledger — it surfaces "review infra failed (no verdict) · retrying (k/N)" and re-dispatches
# next cycle (bounded). Exit status: 0 = PASS, 1 = BLOCK (genuine reviewer finding), 2 = INFRA-FAIL.
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
#
# LOCAL (pre-PR) MODE:
#   herd-review.sh --local <slug>
# Reviews the worktree's LOCAL diff ('git diff DEFAULT_BRANCH...HEAD') BEFORE any PR exists — used by
# the builder lanes when LOCAL_REVIEW=pre-pr so a correctness BLOCK is caught + fixed locally before
# the PR is made public. It reuses the EXACT same adversarial correctness prompt + PASS/BLOCK/INFRA-FAIL
# contract and exit codes (0=PASS, 1=BLOCK, 2=INFRA-FAIL) as PR mode; the only differences are it reads
# the local diff instead of 'gh pr diff <pr>', posts NO PR comment (there is no PR yet), and runs
# headless with no herdr pane. The default PR mode is byte-for-byte unchanged.
set -u

# ── Distinctive argv0 so kill-by-pattern sweeps can EXCLUDE the reviewer chain ─────────────────
# A stray `pkill -f agent-watch.sh` (or a builder testing kill logic) must never sever an in-flight
# review — a severed review used to cache a bogus BLOCK against the sha. We re-exec ourselves ONCE
# under a `herd-review-gate-<pr>` argv0 so the reviewer process (and its whole chain) is unmistakably
# NOT the watcher, and so sweeps can filter it out by name. The guard var makes the re-exec idempotent.
# Best-effort: if `exec -a` is unavailable we simply continue under the original name.
if [ "${_HERD_REVIEW_ARGV0:-}" != "1" ] && command -v bash >/dev/null 2>&1; then
  export _HERD_REVIEW_ARGV0=1
  exec -a "herd-review-gate-${1:-?}" bash "$0" "$@" || true
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
# Runtime driver shim: route the review agent launch through herd_driver_launch_agent so
# HERD_DRIVER=headless spawns a detached reviewer; herdr-claude emits the identical argv below.
# shellcheck source=/dev/null
. "$HERE/driver.sh"
# Engine journal — record log retention + infra deaths (best-effort, never breaks the gate).
. "$HERE/journal.sh"
# Native-burst seam (HERD-107): the bounded read-only FAN-OUT helper. Sourced so the pre-merge review
# can optionally run a bounded REVIEW PANEL — several concurrent read-only reviewer passes over the same
# diff — when NATIVE_BURST=on. Off (or REVIEW_PANEL<=1) → a single reviewer, byte-identical to before.
# shellcheck source=/dev/null
. "$HERE/burst.sh"
MAIN="$PROJECT_ROOT"
# Mode: default PR review (<pr> <slug>); --local reviews the worktree's LOCAL diff (<slug>) BEFORE any
# PR exists. Local mode reuses the SAME adversarial prompt + PASS/BLOCK/INFRA-FAIL contract below, but
# reads 'git diff DEFAULT_BRANCH...HEAD' instead of 'gh pr diff <pr>', posts no PR comment, and skips
# all the herdr-pane / result-file / ledger machinery (that is watcher-only). PR is empty in this mode.
REVIEW_MODE="pr"
if [ "${1:-}" = "--local" ]; then REVIEW_MODE="local"; shift; fi
if [ "$REVIEW_MODE" = "local" ]; then
  PR=""
  SLUG="${1:?usage: herd-review.sh --local <slug>}"
else
  PR="${1:?usage: herd-review.sh <pr> <slug>}"
  SLUG="${2:?usage: herd-review.sh <pr> <slug>}"
fi
DIR="$WORKTREES_DIR/$SLUG"
CLAUDE_FLAGS="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"
REVIEW_MODEL="${HERD_REVIEW_MODEL:-$MODEL_REVIEW}"
_WS_ID="$(herd_resolve_workspace_id)"

# REVIEW PANEL size (HERD-107, native-burst): number of CONCURRENT read-only reviewer passes over this
# diff. herd_burst_bound returns 1 when NATIVE_BURST is off (or REVIEW_PANEL<=1), so the DEFAULT is a
# single reviewer — byte-identical to before. When >1, the panel runs on the HEADLESS reviewer path
# (agent-pane placement is skipped) and its verdicts are combined fail-safe (any BLOCK ⇒ BLOCK).
_PANEL_N="$(herd_burst_bound "${REVIEW_PANEL:-1}")"
case "$_PANEL_N" in ''|*[!0-9]*) _PANEL_N=1 ;; esac

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

# _teardown_reviewer — called on every non-success exit path when in agent-pane mode.
# Closes the detached reviewer pane so it cannot outlive the gate and later overwrite the
# watcher's result file (e.g. a timed-out agent writing REVIEW: PASS after INFRA-FAIL
# was already written would appear to the watcher as a fresh verdict, potentially driving
# a merge from a dead cycle). Also removes the private agent temp.
_teardown_reviewer() {
  if [ "${_AGENT_PANE_MODE:-0}" = "1" ] && [ -n "${ROOT:-}" ]; then
    # GUARDED CLOSE (HERD-134): ROOT is our own review split inside the builder's SHARED tab. Verify it
    # is still a reviewer pane before closing so a stale/recycled id cannot vaporise the builder pane on
    # our way out; a mismatch REFUSES + journals pane_close_refused rather than killing a neighbour.
    herd_close_pane_verified "$ROOT" "review·" || true
  fi
  # We closed our own pane here, so drop the dispatch-registry row too (HERD-113) — nothing survives
  # this exit path for the watcher to retire. Best-effort; a missing file is fine.
  [ -n "${HERD_REVIEW_REGISTRY_FILE:-}" ] && rm -f "$HERD_REVIEW_REGISTRY_FILE" 2>/dev/null || true
  [ -n "${_agent_result_file:-}" ] && rm -f "$_agent_result_file" 2>/dev/null || true
}

# A SEVERED review (killed by a stray sweep, or its stdout pipe torn down by a dying watcher) is
# an INFRA failure, NOT a refused verdict: report INFRA-FAIL so the watcher retries instead of
# caching a bogus BLOCK against the sha. With PIPE trapped, writes to a broken stdout return an
# error (handled in _emit_verdict) instead of killing us before we can report.
_severed() {
  _teardown_reviewer
  journal_append infra_event component herd-review pr "${PR:-}" slug "${SLUG:-}" exit_code 2 \
    stderr_tail 'review severed (SIGTERM/SIGPIPE) before a verdict'
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

# Shared headless-stream formatter — emits tool name + one-line input summary (bash command, file
# path, etc.) and the reviewer's reasoning text, never a bare '[tool] Bash'. Used by BOTH the headless
# PR path and the local (pre-PR) path so their output rendering stays identical. Single-quoted so no
# shell expansion touches the python; contains no single quotes.
REVIEW_STREAM_FORMATTER='
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
'

# ── Review panel (HERD-107, native-burst) ────────────────────────────────────────────────────────
# _combine_verdicts <file>… — fold the per-member verdict files of a review PANEL into ONE verdict,
# FAIL-SAFE for a merge gate: read each file's LAST 'REVIEW: PASS|BLOCK' line and
#   • ANY member BLOCK  → echo that BLOCK (a single reviewer finding a real bug must block the merge);
#   • else ANY PASS     → echo that PASS (one clean review is the same bar as today's single reviewer);
#   • else (no verdict) → echo nothing + return 1 → the caller reports INFRA-FAIL (every member died).
# This can only ever be STRICTER than a single reviewer: extra panel members add chances to BLOCK, never
# a way to turn a BLOCK into a PASS. Pure (reads files, no side effects) so it is unit-tested directly.
_combine_verdicts() {
  local f line block="" pass=""
  for f in "$@"; do
    [ -f "$f" ] || continue
    line="$(grep -E '^[[:space:]]*REVIEW: (PASS|BLOCK)' "$f" 2>/dev/null | tail -1 | sed -E 's/^[[:space:]]+//')"
    [ -n "$line" ] || continue
    case "$line" in
      "REVIEW: BLOCK"*) [ -z "$block" ] && block="$line" ;;
      "REVIEW: PASS"|"REVIEW: PASS "*) [ -z "$pass" ] && pass="$line" ;;
    esac
  done
  if [ -n "$block" ]; then printf '%s' "$block"; return 0; fi
  if [ -n "$pass" ];  then printf '%s' "$pass";  return 0; fi
  return 1
}

# _panel_member <index> — one read-only reviewer pass, run in a background subshell by herd_burst.
# It streams `claude -p "$_PANEL_TASK"` (a NO-COMMENT, print-one-verdict task; the panel posts a single
# combined PR comment itself) through the shared formatter and captures the output — including the final
# 'REVIEW:' line — into this member's private file $_PANEL_DIR/m.<index>. Any failure is swallowed: a
# dead member simply leaves no verdict, and _combine_verdicts treats it as absent (fail-safe).
_panel_member() {
  local i="$1"
  local mfile="$_PANEL_DIR/m.$i"
  ( cd "$CWD" 2>/dev/null && \
    herd_driver_oneshot_exec "$_PANEL_TASK" "$REVIEW_MODEL" $CLAUDE_FLAGS \
      --output-format stream-json --verbose 2>/dev/null \
    | python3 -uc "$REVIEW_STREAM_FORMATTER" ) > "$mfile" 2>/dev/null || true
}

# _panel_indices <n> — echo "0 1 … n-1" (space-separated) for the herd_burst worklist.
_panel_indices() {
  local n="$1" i=0 out=""
  while [ "$i" -lt "$n" ]; do out="$out $i"; i=$((i+1)); done
  printf '%s' "$out"
}

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

# emit_infra_fail <reason> — TRANSIENT infrastructure failure. The reviewer COULD NOT RUN; this is
# NOT a finding. Prints REVIEW: INFRA-FAIL (exit 2) so the watcher knows NOT to cache the result —
# it will surface "review infra failed (no verdict) · retrying (k/N)" and re-attempt next cycle
# (bounded by the retry cap). Does NOT post a PR
# comment (no finding to report; a comment on every retry would be spammy). Kills any detached
# agent pane first so it cannot outlive the gate and overwrite the INFRA-FAIL verdict.
emit_infra_fail() {
  _teardown_reviewer
  journal_append infra_event component herd-review pr "${PR:-}" slug "${SLUG:-}" exit_code 2 \
    stderr_tail "$1"
  _emit_verdict "REVIEW: INFRA-FAIL — $1"
  exit 2
}

# ── LOCAL (pre-PR) MODE ──────────────────────────────────────────────────────────────────────────
# When invoked as `herd-review.sh --local <slug>`, review the worktree's LOCAL diff BEFORE any PR
# exists (the LOCAL_REVIEW=pre-pr path). Same adversarial correctness prompt + PASS/BLOCK/INFRA-FAIL
# contract + exit codes as PR mode, but: reads 'git diff DEFAULT_BRANCH...HEAD' instead of a PR diff,
# posts NO PR comment, runs headless (no herdr pane), and uses a transient log (no persistent pane
# tails it, so it is removed on exit). This block RETURNS via exit — the PR-only machinery below never
# runs in local mode.
if [ "$REVIEW_MODE" = "local" ]; then
  _local_diff_cmd="git diff ${DEFAULT_BRANCH}...HEAD"
  # Same STABLE adversarial preamble + checklist + RULES as TASK, retargeted at the local diff. The
  # only rule differences: there is NO PR, so no 'gh' command and no PR comment — just print the verdict.
  LOCAL_TASK="You are an ADVERSARIAL PRE-PR CORRECTNESS REVIEWER for the project '${WORKSPACE_NAME}', where a SILENTLY WRONG result is the worst outcome (it doesn't crash, it just produces bad output/data). Your ONLY job: read the LOCAL diff of this worktree (with '${_local_diff_cmd}') and hunt HARD for a concrete CORRECTNESS or DATA-INTEGRITY bug introduced by the diff. Look especially for: ${CHECKLIST_TEXT}. RULES: (1) BLOCK ON CORRECTNESS ONLY. Classify EVERY finding as either CORRECTNESS (a real bug that makes the code produce wrong output/data, crash, corrupt state, or violate an invariant — BLOCKING) or ADVISORY (style, naming, formatting, test coverage, hardening, defensiveness, or subjective design — NON-BLOCKING). ONLY a correctness finding may block; advisory findings are surfaced as non-blocking notes and must NEVER gate the merge. (2) You are READ-ONLY: DO NOT edit any file, DO NOT commit, push, or merge. There is NO pull request yet, so DO NOT run any 'gh' command and do NOT post a comment anywhere. (3) DEFAULT TO BLOCK WHEN UNCERTAIN: if you find a real correctness/data-integrity bug, OR you cannot convince yourself the diff is correct, BLOCK. Only PASS when you are confident the diff is correct — a purely advisory finding is NOT a reason to block. (4) FINALLY, as the LAST thing you print, output EXACTLY ONE verdict line and nothing after it. BLOCK if and only if you have at least one CORRECTNESS finding — a STRUCTURED verdict of exactly this shape: 'REVIEW: BLOCK — rule: <which correctness rule was violated> | why: <the reasoning> | location: <file:line or function>' (those three ' | '-separated fields, rule/why/location). Otherwise PASS: print exactly 'REVIEW: PASS' when you found NO issues at all, or, when you found ONLY advisory (non-correctness) issues, 'REVIEW: PASS — advisory: <one-line note> | advisory: <one-line note>' with one ' advisory:' segment per advisory finding. Keep it to that single line; it is parsed by a machine; do not add markdown, quotes, or extra text around it. THIS REVIEW: review the LOCAL diff of branch slug '${SLUG}' by running '${_local_diff_cmd}'."

  LLOG="$(mktemp "${TMPDIR:-/tmp}/herd-review-local-${SLUG}-XXXXXX")" \
    || emit_infra_fail "could not allocate local review log (mktemp failed)"
  # Local log is transient — unlike PR mode there is no persistent herdr pane tailing it, so drop it
  # on exit. (emit_infra_fail / the verdict handlers below all exit, firing this trap.)
  trap 'rm -f "$LLOG" 2>/dev/null || true' EXIT

  if [ "$_PANEL_N" -gt 1 ] 2>/dev/null; then
    # NATIVE-BURST review PANEL: fan out $_PANEL_N concurrent read-only reviewer passes over the SAME
    # local diff (bounded by herd_burst), each writing its verdict to a private per-member file; then
    # combine fail-safe (any BLOCK ⇒ BLOCK). LOCAL_TASK is already the no-comment print-one-verdict task,
    # so it doubles as the panel-member task verbatim. A total infra wipeout (no member left a verdict)
    # → INFRA-FAIL, exactly as a single dead reviewer would.
    echo "🔬 Local pre-PR review of '${SLUG}' — bounded PANEL (${_PANEL_N}× ${REVIEW_MODEL}) adversarial correctness pass (${_local_diff_cmd})…" >&2
    _PANEL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/herd-review-panel-${SLUG}-XXXXXX")" \
      || emit_infra_fail "could not allocate local panel dir (mktemp -d failed)"
    trap 'rm -f "$LLOG" 2>/dev/null || true; rm -rf "$_PANEL_DIR" 2>/dev/null || true' EXIT
    _PANEL_TASK="$LOCAL_TASK"
    # shellcheck disable=SC2086  # $(_panel_indices) is an intentional space-separated worklist
    herd_burst "$_PANEL_N" _panel_member $(_panel_indices "$_PANEL_N")
    verdict_line="$(_combine_verdicts "$_PANEL_DIR"/m.* 2>/dev/null || true)"
    [ -n "$verdict_line" ] \
      || emit_infra_fail "local panel review produced no verdict from any of ${_PANEL_N} members — infrastructure failure, not a block"
  else
    echo "🔬 Local pre-PR review of '${SLUG}' on ${REVIEW_MODEL} — adversarial correctness/data-integrity pass (${_local_diff_cmd})…" >&2

    # Stream claude -p into $LLOG with the shared formatter, mirroring the headless PR path. Tee to
    # stderr so the builder watches the reasoning live while $LLOG captures it for verdict parsing.
    (set -o pipefail; cd "$CWD" 2>/dev/null && \
      herd_driver_oneshot_exec "$LOCAL_TASK" "$REVIEW_MODEL" $CLAUDE_FLAGS \
        --output-format stream-json --verbose 2>&1 | \
      python3 -uc "$REVIEW_STREAM_FORMATTER") 2>&1 | tee "$LLOG" >&2
    rc=${PIPESTATUS[0]}

    if [ "$rc" -ne 0 ]; then
      # Non-zero WITH a parseable verdict in the log is honoured below; non-zero with NO verdict is a
      # transient infra death (reviewer crashed before concluding), NOT a genuine BLOCK.
      if ! grep -qE '^[[:space:]]*REVIEW: (PASS|BLOCK)' "$LLOG" 2>/dev/null; then
        emit_infra_fail "local reviewer exited non-zero (rc=$rc) with no verdict — could not complete the review"
      fi
    fi

    verdict_line="$(grep -E '^[[:space:]]*REVIEW: (PASS|BLOCK)' "$LLOG" 2>/dev/null | tail -1 | sed -E 's/^[[:space:]]+//')"
  fi
  case "$verdict_line" in
    # PASS, with or without a HERD-105 'advisory:' tail (' — advisory: …'). A bare 'REVIEW: PASS'
    # is emitted verbatim (byte-identical to before); a PASS carrying advisory notes is passed
    # through unchanged so the non-blocking findings survive to the builder.
    "REVIEW: PASS"|"REVIEW: PASS "*) _emit_verdict "$verdict_line"; exit 0 ;;
    "REVIEW: BLOCK"*) _emit_verdict "$verdict_line"; exit 1 ;;
    *) emit_infra_fail "local reviewer produced no parseable verdict (no REVIEW line) — infrastructure failure, not a block" ;;
  esac
fi

# Log RETENTION: each review writes its $LOG path to a slug-keyed tracker. Historically the tracker
# held a single path and the NEXT review of the slug DELETED it — but that deleted log is exactly the
# forensic evidence needed to post-mortem a failed gate (a mid-review Claude death, a bogus verdict).
# So the tracker is now a rolling LIST (newest last) and we KEEP the last $REVIEW_LOG_KEEP logs per
# slug, deleting only those that roll off the window. The log itself is still NOT deleted on EXIT — it
# must outlive this process so the persistent herdr pane keeps tailing the verdict.
if [ -d "${WORKTREES_DIR:-}" ]; then
  _LOG_TRACK="$WORKTREES_DIR/.review-log-$SLUG"
else
  _LOG_TRACK="${TMPDIR:-/tmp}/.herd-review-log-$SLUG"
fi
REVIEW_LOG_KEEP="${REVIEW_LOG_KEEP:-5}"
case "$REVIEW_LOG_KEEP" in ''|*[!0-9]*) REVIEW_LOG_KEEP=5 ;; esac

# BSD/macOS mktemp requires X's to be the LAST characters; a trailing suffix like
# ".log" after XXXXXX is a GNU-only extension that silently produces a literal filename
# on macOS and collides on any second use.  Drop the suffix — callers don't need it.
LOG="$(mktemp "${TMPDIR:-/tmp}/herd-review-${PR}-XXXXXX")" \
  || emit_infra_fail "could not allocate review log (mktemp failed)"
[ -n "$LOG" ] || emit_infra_fail "could not allocate review log (empty path)"

# Roll the tracker: append this log, keep the newest $REVIEW_LOG_KEEP, delete the ones that fall off.
# Best-effort throughout — a tracker/FS hiccup must never abort the gate.
_rlt_tmp="${_LOG_TRACK}.tmp.$$"
{ [ -f "$_LOG_TRACK" ] && cat "$_LOG_TRACK" 2>/dev/null; printf '%s\n' "$LOG"; } 2>/dev/null \
  | awk 'NF' > "$_rlt_tmp" 2>/dev/null || : > "$_rlt_tmp" 2>/dev/null || true
if [ -f "$_rlt_tmp" ]; then
  _rlt_total="$(wc -l < "$_rlt_tmp" 2>/dev/null | tr -cd '0-9')"; _rlt_total="${_rlt_total:-0}"
  if [ "$_rlt_total" -gt "$REVIEW_LOG_KEEP" ] 2>/dev/null; then
    _rlt_drop="$(( _rlt_total - REVIEW_LOG_KEEP ))"
    # Delete the oldest ($_rlt_drop) logs — but never the one we just created.
    head -n "$_rlt_drop" "$_rlt_tmp" 2>/dev/null | while IFS= read -r _rlt_old; do
      [ -n "$_rlt_old" ] && [ "$_rlt_old" != "$LOG" ] && rm -f "$_rlt_old" 2>/dev/null || true
    done
    tail -n "$REVIEW_LOG_KEEP" "$_rlt_tmp" > "${_rlt_tmp}.2" 2>/dev/null \
      && mv -f "${_rlt_tmp}.2" "$_rlt_tmp" 2>/dev/null || true
  fi
  mv -f "$_rlt_tmp" "$_LOG_TRACK" 2>/dev/null || rm -f "$_rlt_tmp" 2>/dev/null || true
fi
journal_append review_log_retained pr "$PR" slug "$SLUG" path "$LOG" keep "$REVIEW_LOG_KEEP"
# NOTE: intentionally NO 'trap rm -f "$LOG" EXIT' — the herdr pane must keep tailing
# the log after this process exits. Old logs are reaped by the rolling window above.

# The fixed reviewer task — headless path. Scoped hard to CORRECTNESS; default BLOCK; read-only;
# one machine verdict printed as the final line (parsed from $LOG).
# Prompt-cache-aware ordering: the STABLE reviewer preamble + risk checklist + RULES lead so many
# close-in-time PR reviews share the cached prefix (Anthropic's cache keys on the longest shared
# PREFIX, 5-min TTL); the UNIQUE per-PR content (PR number, branch slug, diff instruction) TRAILS.
TASK="You are an ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for the project '${WORKSPACE_NAME}', where a SILENTLY WRONG result is the worst outcome (it doesn't crash, it just produces bad output/data). Your ONLY job: read the diff of the pull request under review (with 'gh pr diff <PR>') and hunt HARD for a concrete CORRECTNESS or DATA-INTEGRITY bug introduced by the diff. Look especially for: ${CHECKLIST_TEXT}. RULES: (1) BLOCK ON CORRECTNESS ONLY. Classify EVERY finding as either CORRECTNESS (a real bug that makes the code produce wrong output/data, crash, corrupt state, or violate an invariant — BLOCKING) or ADVISORY (style, naming, formatting, test coverage, hardening, defensiveness, or subjective design — NON-BLOCKING). ONLY a correctness finding may block the merge; advisory findings are surfaced as non-blocking notes and must NEVER gate the merge. (2) You are READ-ONLY: DO NOT edit any file, DO NOT commit, push, or merge. The only write you may do is ONE 'gh pr comment <PR> --body \"…\"'. (3) DEFAULT TO BLOCK WHEN UNCERTAIN: if you find a real correctness/data-integrity bug, OR you cannot convince yourself the diff is correct, BLOCK. Only PASS when you are confident the diff is correct — a purely advisory finding is NOT a reason to block. (4) Post a brief PR comment summarizing your findings via 'gh pr comment <PR> --body \"…\"' (one tight paragraph: the blocking bug + why it's wrong, or the PASS rationale; then list any ADVISORY style/hardening findings separately as clearly-labelled NON-BLOCKING notes). (5) FINALLY, as the LAST thing you print, output EXACTLY ONE verdict line and nothing after it. BLOCK if and only if you have at least one CORRECTNESS finding — a STRUCTURED verdict of exactly this shape: 'REVIEW: BLOCK — rule: <which correctness rule was violated> | why: <the reasoning> | location: <file:line or function>' (those three ' | '-separated fields, rule/why/location). Otherwise PASS: print exactly 'REVIEW: PASS' when you found NO issues at all, or, when you found ONLY advisory (non-correctness) issues, 'REVIEW: PASS — advisory: <one-line note> | advisory: <one-line note>' with one ' advisory:' segment per advisory finding. Keep it to that single line; it is parsed by a machine; do not add markdown, quotes, or extra text around it. THIS REVIEW: the pull request under review is PR #${PR} (branch slug '${SLUG}'); read its diff with 'gh pr diff ${PR}' and post your one comment with 'gh pr comment ${PR} --body \"…\"'."

# PANEL-member task (HERD-107, native-burst): a NO-COMMENT variant of the reviewer task used only when
# $_PANEL_N>1. Each of the $_PANEL_N concurrent members reads the SAME PR diff and PRINTS one verdict
# line — but does NOT post a PR comment (the panel posts a single combined comment once, so N members
# never spam N comments). Same STABLE preamble/checklist/RULES as TASK for cache-sharing; only the
# comment rule differs and the diff instruction trails. Byte-inert unless the panel actually engages.
PR_PANEL_TASK="You are an ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for the project '${WORKSPACE_NAME}', where a SILENTLY WRONG result is the worst outcome (it doesn't crash, it just produces bad output/data). Your ONLY job: read the diff of the pull request under review (with 'gh pr diff <PR>') and hunt HARD for a concrete CORRECTNESS or DATA-INTEGRITY bug introduced by the diff. Look especially for: ${CHECKLIST_TEXT}. RULES: (1) BLOCK ON CORRECTNESS ONLY. Classify EVERY finding as either CORRECTNESS (a real bug that makes the code produce wrong output/data, crash, corrupt state, or violate an invariant — BLOCKING) or ADVISORY (style, naming, formatting, test coverage, hardening, defensiveness, or subjective design — NON-BLOCKING). ONLY a correctness finding may block the merge; advisory findings are surfaced as non-blocking notes and must NEVER gate the merge. (2) You are READ-ONLY: DO NOT edit any file, DO NOT commit, push, or merge, and DO NOT run any 'gh' command that writes — in particular DO NOT post a PR comment (the review harness posts one combined comment for the whole panel). (3) DEFAULT TO BLOCK WHEN UNCERTAIN: if you find a real correctness/data-integrity bug, OR you cannot convince yourself the diff is correct, BLOCK. Only PASS when you are confident the diff is correct — a purely advisory finding is NOT a reason to block. (4) FINALLY, as the LAST thing you print, output EXACTLY ONE verdict line and nothing after it. BLOCK if and only if you have at least one CORRECTNESS finding — a STRUCTURED verdict of exactly this shape: 'REVIEW: BLOCK — rule: <which correctness rule was violated> | why: <the reasoning> | location: <file:line or function>' (those three ' | '-separated fields, rule/why/location). Otherwise PASS: print exactly 'REVIEW: PASS' when you found NO issues at all, or, when you found ONLY advisory (non-correctness) issues, 'REVIEW: PASS — advisory: <one-line note> | advisory: <one-line note>' with one ' advisory:' segment per advisory finding. Keep it to that single line; it is parsed by a machine; do not add markdown, quotes, or extra text around it. THIS REVIEW: the pull request under review is PR #${PR} (branch slug '${SLUG}'); read its diff with 'gh pr diff ${PR}'."

# Private agent temp: the agent writes its verdict here; herd-review.sh (this script) is the
# SOLE atomic writer of $HERD_REVIEW_RESULT_FILE. The agent NEVER touches the watcher's
# authoritative file — it only writes to this private temp. herd-review.sh reads the temp,
# validates the verdict, then emits it atomically via _emit_verdict (temp+mv).
# HERD_REVIEW_AGENT_TEMP overrides the auto-generated path (used in tests to control the path).
_agent_result_file="${HERD_REVIEW_AGENT_TEMP:-}"
if [ -z "$_agent_result_file" ]; then
  _agent_result_file="$(mktemp "${TMPDIR:-/tmp}/herd-review-agent-${PR}-XXXXXX" 2>/dev/null || true)"
fi
[ -n "$_agent_result_file" ] || emit_infra_fail "could not allocate agent temp file (mktemp failed)"

# _consume_nearmiss_verdict — belt-and-braces for HERD-133 (PR #249's reviewer wrote its verdict to
# 'herd-review-agent-249-Iw1smh.' — the expected path plus the trailing sentence period — so the
# wrapper polled the dotless path for the full 1800s, declared an infra timeout, and double-dispatched
# a second review). Before the poll loop gives up, look for a result file that is a NEAR-MISS of the
# expected path: the exact path with a suffix made up ENTIRELY of trailing dots and/or whitespace (the
# ways a model folds following punctuation into an unquoted filename). If exactly such a file holds a
# parseable verdict, adopt it. Sets _nearmiss_verdict + _nearmiss_path and returns 0 on a hit; returns
# 1 (leaving both empty) when there is no near-miss. Fail-soft: a glob that matches nothing, or a
# candidate with no verdict, simply yields no hit. The exact-path flow never calls this (the poll loop
# returns first on the exact file), so the normal path stays byte-identical.
_nearmiss_verdict="" _nearmiss_path=""
_consume_nearmiss_verdict() {
  _nearmiss_verdict="" _nearmiss_path=""
  [ -n "${_agent_result_file:-}" ] || return 1
  local _cand _suffix _v
  for _cand in "${_agent_result_file}"*; do
    # nullglob is off: an unmatched glob yields the literal pattern, which is not a real file.
    [ -f "$_cand" ] || continue
    # Skip the exact path itself (empty, still being polled) — only true near-misses qualify.
    [ "$_cand" = "$_agent_result_file" ] && continue
    _suffix="${_cand#"$_agent_result_file"}"
    # The extra suffix must be ONLY trailing dots/spaces/tabs — never a different file that merely
    # shares this prefix. Strip those chars; a non-empty remainder means it is a distinct file.
    [ -z "${_suffix//[$' \t.']/}" ] || continue
    _v="$(grep -E '^[[:space:]]*REVIEW: (PASS|BLOCK)' "$_cand" 2>/dev/null | tail -1 | sed -E 's/^[[:space:]]+//')"
    if [ -n "$_v" ]; then
      _nearmiss_verdict="$_v"; _nearmiss_path="$_cand"
      return 0
    fi
  done
  return 1
}

# Agent-pane task: same correctness rules as TASK, but the final instruction tells the agent to
# WRITE the verdict to $_agent_result_file (not just print it). The agent runs in the TUI so the
# human sees genuine Opus reasoning in the builder's tab; the result file is how herd-review.sh
# (polling in the background) captures the machine verdict.
# Prompt-cache-aware ordering (see the TASK note above): STABLE preamble + checklist + RULES lead;
# the UNIQUE per-PR content (PR number, slug, and the private result-file path) TRAILS.
AGENT_TASK="You are an ADVERSARIAL PRE-MERGE CORRECTNESS REVIEWER for the project '${WORKSPACE_NAME}', where a SILENTLY WRONG result is the worst outcome (it doesn't crash, it just produces bad output/data). Your ONLY job: read the diff of the pull request under review (with 'gh pr diff <PR>') and hunt HARD for a concrete CORRECTNESS or DATA-INTEGRITY bug introduced by the diff. Look especially for: ${CHECKLIST_TEXT}. RULES: (1) BLOCK ON CORRECTNESS ONLY. Classify EVERY finding as either CORRECTNESS (a real bug that makes the code produce wrong output/data, crash, corrupt state, or violate an invariant — BLOCKING) or ADVISORY (style, naming, formatting, test coverage, hardening, defensiveness, or subjective design — NON-BLOCKING). ONLY a correctness finding may block the merge; advisory findings are surfaced as non-blocking notes and must NEVER gate the merge. (2) You are READ-ONLY: DO NOT edit any file, DO NOT commit, push, or merge. The ONLY writes you may do are: ONE 'gh pr comment <PR> --body \"…\"' and the result-file write described in rule 5. (3) DEFAULT TO BLOCK WHEN UNCERTAIN: if you find a real correctness/data-integrity bug, OR you cannot convince yourself the diff is correct, BLOCK. Only PASS when you are confident the diff is correct — a purely advisory finding is NOT a reason to block. (4) Post a brief PR comment summarizing your findings via 'gh pr comment <PR> --body \"…\"' (one tight paragraph: the blocking bug + why it's wrong, or the PASS rationale; then list any ADVISORY style/hardening findings separately as clearly-labelled NON-BLOCKING notes). (5) FINALLY, as your absolute LAST action, write the machine verdict the merge gate reads — this step is MANDATORY — by running exactly one of these commands. To BLOCK (only when you have at least one CORRECTNESS finding), a STRUCTURED verdict of exactly this shape: printf 'REVIEW: BLOCK — rule: <which correctness rule was violated> | why: <the reasoning> | location: <file:line or function>\n' > '<RESULT_FILE>' (three ' | '-separated fields — rule, why, location — parsed by a machine). Otherwise PASS: printf 'REVIEW: PASS\n' > '<RESULT_FILE>' when you found NO issues, or printf 'REVIEW: PASS — advisory: <one-line note> | advisory: <one-line note>\n' > '<RESULT_FILE>' when you found ONLY advisory (non-correctness) issues (one ' advisory:' segment per finding), where <RESULT_FILE> is the path given below. Do not skip this step. THIS REVIEW: the pull request under review is PR #${PR} (branch slug '${SLUG}'); read its diff with 'gh pr diff ${PR}' and post your one comment with 'gh pr comment ${PR} --body \"…\"'. The <RESULT_FILE> path for rule 5 is: '${_agent_result_file}' (use it exactly, quotes included — do not append the trailing period of this sentence to the filename)."

# _purge_stale_review_tab — close any STANDALONE review·<slug> tab left by a prior dispatch (the
# fallback path) and drop its sweep-allowlist registry line. Idempotent + best-effort: called on
# every dispatch so repeated re-reviews never accumulate tabs OR stale registry rows, and so
# alternating placement modes (builder-tab split ↔ standalone tab) never orphans a tab in the
# .herd-tabs allowlist. (The stale in-tab review SPLIT is a different beast — an agent named
# review·<slug>, closed by pane_id before the re-split below; this handles the standalone TAB.)
_purge_stale_review_tab() {
  local _old
  _old="$(SLUG="$SLUG" herdr tab list ${_WS_ID:+--workspace "$_WS_ID"} 2>/dev/null | python3 -c '
import sys, json, os
slug = "review·" + os.environ.get("SLUG", "")
try:
    tabs = json.load(sys.stdin).get("result", {}).get("tabs", [])
    print(next((t["tab_id"] for t in tabs if t.get("label","").startswith(slug)), ""))
except Exception:
    pass
' 2>/dev/null || true)"
  [ -n "${_old:-}" ] && herdr tab close "$_old" >/dev/null 2>&1 || true
  # Drop any prior registry line(s) for this slug so a later append stays idempotent. grep -v may
  # exit non-zero when it filters out ALL lines (an allowlist that held only this slug) — that is
  # success (an empty result), so don't gate the mv on grep's status.
  local _reg="$WORKTREES_DIR/.herd-tabs"
  if [ -f "$_reg" ]; then
    grep -vF "review·$SLUG " "$_reg" > "${_reg}.tmp.$$" 2>/dev/null || true
    mv -f "${_reg}.tmp.$$" "$_reg" 2>/dev/null || rm -f "${_reg}.tmp.$$" 2>/dev/null || true
  fi
}

# --- Pane placement (Review pane v2) ---
# Preferred: bottom split inside the builder's existing tab so the review appears WITH the work,
# and the human watches the genuine Claude TUI. On a RE-REVIEW (e.g. the round-2 pass after an
# auto-refix bounce) we REUSE that tab: the stale round-1 review split is closed first so the new
# split lands back inside the builder's tab instead of falling through to a fresh tail tab.
# Fallback: standalone review·<slug> tab when the builder tab is genuinely gone, when herdr is
# unavailable, or when the agent start fails.
TAB="" ROOT="" _AGENT_PANE_MODE=0
# NATIVE-BURST (HERD-107): when a review PANEL is requested ($_PANEL_N>1) the review runs on the HEADLESS
# fan-out path (N concurrent claude -p passes), so skip the single-agent-pane placement entirely. The
# default ($_PANEL_N==1) keeps today's exact pane behavior — this guard is inert unless the panel engages.
if [ "$_PANEL_N" -le 1 ] 2>/dev/null && [ "${HERD_NO_PANE:-}" != "1" ] && command -v herdr >/dev/null 2>&1 && [ -n "$_agent_result_file" ]; then

  # One agent-list read, parsed twice: the builder's own pane (agent named $SLUG) and any STALE
  # review pane (agent named review·$SLUG) still occupying the builder's tab from a prior round.
  # `herdr agent start "review·$SLUG"` cannot re-split while that same-named agent still holds the
  # tab — the failure that dropped PR #195's round-2 review into a brand-new tab (HERD-81) — so we
  # find the stale pane here and close it before re-splitting.
  _agents_json="$(herdr agent list 2>/dev/null || true)"
  _pane_by_agent_name() {
    printf '%s' "$_agents_json" | NAME="$1" python3 -c '
import sys, json, os
name = os.environ["NAME"]
try:
    agents = (json.load(sys.stdin).get("result") or {}).get("agents") or []
    for a in agents:
        if a.get("name") == name:
            print(a.get("pane_id", ""), end="")
            break
except Exception:
    pass
' 2>/dev/null || true
  }
  _builder_pane="$(_pane_by_agent_name "$SLUG")"
  _stale_review_pane="$(_pane_by_agent_name "review·$SLUG")"

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
    # REUSE-NOT-RECREATE: a stale review·<slug> split from a prior round still holds this tab and
    # blocks `herdr agent start` (duplicate agent name / no room). Close it FIRST so the re-review
    # reuses the builder's tab — pane count stays stable (close one, open one) instead of leaking a
    # fresh tail tab per round. Best-effort: a close hiccup just falls through to the standalone
    # fallback below, which is the pre-HERD-81 behaviour.
    # GUARDED CLOSE (HERD-134): _stale_review_pane was resolved by agent name earlier in this tick, but
    # the id can go stale/recycled before we close it — and it lives INSIDE the builder's shared tab,
    # so a wrong id vaporises the live builder pane. Verify it is still a reviewer before closing; on a
    # mismatch the guard REFUSES + journals pane_close_refused instead of killing a neighbour.
    [ -n "${_stale_review_pane:-}" ] && herd_close_pane_verified "$_stale_review_pane" "review·" || true
    # Also retire any standalone review·<slug> fallback tab (+ its registry line) from an earlier
    # round, so flipping from standalone back to builder-tab placement never orphans a tab.
    _purge_stale_review_tab

    # Try to start the review agent as a bottom split inside the builder's tab. Routed through the
    # driver seam so HERD_DRIVER=headless spawns a detached reviewer; herdr-claude emits the identical
    # `herdr agent start … --split down --no-focus -- claude …` argv.
    _agent_start_out="$(herd_driver_launch_agent \
      name="review·$SLUG" workspace="$_WS_ID" cwd="$CWD" tab="$_builder_tab" split=down \
      model="$REVIEW_MODEL" flags="$CLAUDE_FLAGS" pointer="$AGENT_TASK" 2>/dev/null || true)"
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
      # DISPATCH REGISTRY (HERD-113): record this reviewer's (pid, pane id) for the watcher, so on
      # verdict CONSUMPTION it can retire this pane, and a dispatch after a watcher/herdr restart can
      # ADOPT the still-live pane instead of spawning a duplicate reviewer. $$ is the poller pid the
      # watcher recorded in the inflight marker (exec -a preserves it across the argv0 re-exec). Written
      # here — after the pane is confirmed up — so the pane id is real. Best-effort; a failed write only
      # costs the retire-on-consume convenience (the pid guard + startup sweep still prevent duplicates).
      if [ -n "${HERD_REVIEW_REGISTRY_FILE:-}" ]; then
        _reg_tmp="${HERD_REVIEW_REGISTRY_FILE}.tmp.$$"
        if printf '%s %s\n' "$$" "$ROOT" > "$_reg_tmp" 2>/dev/null; then
          mv -f "$_reg_tmp" "$HERD_REVIEW_REGISTRY_FILE" 2>/dev/null || rm -f "$_reg_tmp" 2>/dev/null || true
        fi
      fi
    fi
  fi

  if [ "$_AGENT_PANE_MODE" = "0" ]; then
    # Fallback: standalone review·<slug> tab, tailing the headless review log.
    # Retire any existing review·<slug> tab (+ its stale registry line) for this slug so repeated
    # dispatches reuse one standalone tab's worth of screen instead of accumulating tabs/rows.
    _purge_stale_review_tab

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
  # Agent-pane mode: the reviewer runs in the TUI and writes its verdict to the private
  # $_agent_result_file temp. Poll until a parseable verdict line appears — checking for
  # the verdict (not just file existence) avoids the race where > truncates the file before
  # writing, which would make us read an empty result on the very next poll tick.
  # Timeout: HERD_REVIEW_AGENT_TIMEOUT seconds (default 1800 = 30 min; override in tests).
  # Poll interval: HERD_REVIEW_AGENT_POLL seconds (default 5; override in tests).
  _poll_deadline=$(( $(date +%s) + ${HERD_REVIEW_AGENT_TIMEOUT:-1800} ))
  _poll_interval="${HERD_REVIEW_AGENT_POLL:-5}"
  verdict_line=""
  while ! grep -qE '^[[:space:]]*REVIEW: (PASS|BLOCK)' "$_agent_result_file" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$_poll_deadline" ]; then
      # Belt-and-braces (HERD-133): before declaring an infra timeout and burning a re-dispatch,
      # glob for a NEAR-MISS result file. A reviewer that absorbs trailing prompt punctuation (the
      # sentence period) or whitespace into an unquoted path writes its verdict one character off —
      # to e.g. "${_agent_result_file}." — leaving the exact path empty forever. If such a variant
      # holds a parseable verdict, CONSUME it as the verdict and journal a warning instead of
      # timing out. When there is NO near-miss, this is a no-op and the timeout proceeds unchanged.
      if _consume_nearmiss_verdict; then
        journal_append verdict_path_nearmiss pr "${PR:-}" slug "${SLUG:-}" \
          expected "$_agent_result_file" actual "$_nearmiss_path" verdict "$_nearmiss_verdict"
        verdict_line="$_nearmiss_verdict"
        break
      fi
      emit_infra_fail "agent-pane reviewer timed out (${HERD_REVIEW_AGENT_TIMEOUT:-1800}s) without writing a verdict to '${_agent_result_file}'"
    fi
    sleep "$_poll_interval"
  done
  # Normal exact-path exit re-reads the verdict here (byte-identical to before); a near-miss
  # consumed above has already populated verdict_line, so leave it untouched in that case.
  [ -n "$verdict_line" ] || verdict_line="$(grep -E '^[[:space:]]*REVIEW: (PASS|BLOCK)' "$_agent_result_file" 2>/dev/null | tail -1 | sed -E 's/^[[:space:]]+//')"
elif [ "$_PANEL_N" -gt 1 ] 2>/dev/null; then
  # NATIVE-BURST review PANEL (headless): fan out $_PANEL_N concurrent read-only reviewer passes over the
  # SAME PR diff (bounded by herd_burst), each PRINTING its verdict (no PR comment) into a private member
  # file; then combine fail-safe (any member BLOCK ⇒ BLOCK, else any PASS ⇒ PASS, else INFRA-FAIL). ONE
  # combined PR comment is posted by the harness (best-effort), so N members never spam N comments.
  _PANEL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/herd-review-panel-${PR}-XXXXXX")" \
    || emit_infra_fail "could not allocate panel dir (mktemp -d failed)"
  # $LOG is still the persistent forensic log; note the panel there. $_PANEL_DIR is cleaned on exit.
  trap 'rm -rf "$_PANEL_DIR" 2>/dev/null || true' EXIT
  _PANEL_TASK="$PR_PANEL_TASK"
  printf '─── native-burst review panel: %s× %s ───\n' "$_PANEL_N" "$REVIEW_MODEL" >> "$LOG" 2>/dev/null || true
  # shellcheck disable=SC2086  # $(_panel_indices) is an intentional space-separated worklist
  herd_burst "$_PANEL_N" _panel_member $(_panel_indices "$_PANEL_N")
  # Fold the members into the log for forensics, then combine.
  cat "$_PANEL_DIR"/m.* >> "$LOG" 2>/dev/null || true
  verdict_line="$(_combine_verdicts "$_PANEL_DIR"/m.* 2>/dev/null || true)"
  [ -n "$verdict_line" ] \
    || emit_infra_fail "review panel produced no verdict from any of ${_PANEL_N} members — infrastructure failure, not a block"
  # ONE combined, non-authoritative PR comment (best-effort; the verdict line is the authority). Skipped
  # silently when gh is unavailable/unauthenticated — the merge gate never depends on the comment landing.
  if command -v gh >/dev/null 2>&1; then
    gh pr comment "$PR" --body "🔬 Native-burst review panel (${_PANEL_N}× ${REVIEW_MODEL}) — combined verdict: ${verdict_line}" >/dev/null 2>&1 || true
  fi
else
  # Headless mode: stream claude -p into $LOG with an informative formatter.
  # The formatter emits: tool name + one-line input summary (bash command, file path, etc.)
  # and the reviewer's reasoning text — never the old bare '[tool] Bash'.
  (set -o pipefail; cd "$CWD" 2>/dev/null && \
    herd_driver_oneshot_exec "$TASK" "$REVIEW_MODEL" $CLAUDE_FLAGS \
      --output-format stream-json --verbose 2>&1 | \
    python3 -uc "$REVIEW_STREAM_FORMATTER") >>"$LOG" 2>&1
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
# A parseable PASS/BLOCK is the reviewer's genuine, finding-backed verdict. NO verdict at all is an
# INFRASTRUCTURE failure (the reviewer ran but never reached a conclusion — killed mid-run, buffered
# output lost, or exited rc=0 without printing the line), NOT a refused verdict: it must be RETRIED,
# never cached as a sticky BLOCK. (This was the 2026-07-02 rc0-no-verdict bug: a default BLOCK got
# cached against the sha and even bounced the builder on a "fix" prompt with nothing actionable.)
case "$verdict_line" in
  # PASS, with or without a HERD-105 'advisory:' tail. Bare 'REVIEW: PASS' is emitted verbatim
  # (byte-identical); a PASS carrying advisory notes is passed through unchanged so the watcher
  # can surface the non-blocking findings to the journal without gating the merge.
  "REVIEW: PASS"|"REVIEW: PASS "*)
    _mark_review_done PASS
    _emit_verdict "$verdict_line"
    exit 0
    ;;
  "REVIEW: BLOCK"*)
    _mark_review_done BLOCK
    _emit_verdict "$verdict_line"
    exit 1
    ;;
  *)
    emit_infra_fail "reviewer produced no parseable verdict (rc=0, no REVIEW line) — infrastructure failure, not a block; retrying"
    ;;
esac
