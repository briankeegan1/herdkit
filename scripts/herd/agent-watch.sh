#!/usr/bin/env bash
# agent-watch.sh — live "herd watch" status console for the coordinator.
#
# A compact, pretty "rollup card" pane that continuously watches the feature sub-agents and
# AUTO-MERGES their PRs when ready (full-auto, safety-railed), so the coordinator (and the user)
# can walk away and still see what is happening and what recently landed. This is HERD TOOLING (a
# herdr pane) — NOT part of the app. Launch it via herd-watch.sh.
#
# Layout: a header (`🐑 herd watch` · live · HH:MM) over a "recently landed" pin (last 3 merges)
# and an "in flight" list — one row per active feature worktree, slug-padded so the state words
# align:
#   🔨 building       — agent working, no PR yet
#   🩺 health-check    — running healthcheck.sh on its worktree. SERIALIZED by a per-repo mutex
#                       (HEALTH_CONCURRENCY, default 1): feature worktrees share one git object
#                       store, so overlapping suites race on shared .git locks and can paint a
#                       false-red — a PR waiting on the slot shows "health-check · queued". A CODE
#                       error is re-run once (solo) before it can go red: a transient self-heals as
#                       "flaky · infra (passed on retry)"; only a reproducing failure paints red.
#   🔬 reviewing      — health passed: a STRONG model is adversarially correctness-reviewing the
#                       diff BEFORE merge (herd-review.sh). Merges only on PASS. Reviews run in
#                       the BACKGROUND (up to REVIEW_CONCURRENCY at once, each with its own
#                       streaming pane), so one slow review never head-of-line-blocks other PRs'
#                       reviews or merges; verdicts are collected from per-PR result files on
#                       later ticks. "review queued" = waiting for a concurrency slot.
#   ⏳ merging         — health passed AND review PASSed, merging now
#   🔀 resolving …     — PR CONFLICTING for the FIRST time: auto-spawned the isolated, test-gated
#                       conflict resolver (herd-resolve.sh). Hands-off.
#   ⚠️ needs you · …   — PR CONFLICTING OR healthcheck returned a CODE error (❌), OR the review
#                       gate returned BLOCK, OR the auto-resolver already ran and it's STILL
#                       conflicting ("resolver failed"). NEVER auto-merged; one-line reason.
#
# AUTO-MERGE rule (full auto, safety-railed): for a PR that is mergeable==MERGEABLE AND
# mergeStateStatus==CLEAN, run  healthcheck.sh <worktree>  (serialized; retried once solo on a CODE
# error before it can go red).  Only if it passes (a ⚠️ data/env warning is OK, and a code error
# that PASSES on the solo retry is treated as flaky/passing; a code error that REPRODUCES is NOT),
# then RE-VERIFY the PR is STILL MERGEABLE/CLEAN and still
# maps to the expected branch in the instant before merging — guarding the window between
# classification and merge — THEN pass the PRE-MERGE REVIEW GATE, and only on a PASS do
# gh pr merge <n> --merge.
#
# On a successful merge the WATCHER owns teardown (sub-agents never self-close): (1) enqueue
# scribe.sh to mark the backlog item shipped, (2) git -C <main> pull --ff-only (fetch-and-move-on
# if it can't ff — never force), (3) git worktree remove --force <wt>, (4) close its herdr tab,
# and record the merge in a persistent state file so "recently landed" survives re-renders.
#
# AUTO-RESOLVE rule (full auto, safety-railed): when a PR FIRST goes CONFLICTING, the watcher
# auto-spawns the EXISTING isolated resolver (herd-resolve.sh <slug>). Two hard rails: (1)
# resolve-loop guard — a branch that already has a recorded attempt is NEVER re-spawned; (2)
# escalation preserved — the resolver aborts + escalates semantically-ambiguous conflicts; the
# watcher NEVER blind-merges a conflict.
#
# MERGE_POLICY (.herd/config): three-way human-in-the-loop lever.
#   auto    — current behavior: merge automatically after all gates pass.
#   approve — run gates, then hold: record an awaiting-approval entry keyed by <pr#>+<headSha>
#             in .agent-watch-approvals, post a PR comment + notification, and merge ONLY once
#             an explicit approval record for that exact sha is written by herd-approve.sh.
#             A new commit (new headSha) invalidates prior approval and restarts the gate cycle.
#   observe — run gates and report/notify, but NEVER merge under any circumstances.
# Back-compat: WATCHER_AUTOMERGE is still read when MERGE_POLICY is not set (true→auto, false→approve).
#
# DRY-RUN: AGENT_WATCH_DRYRUN=1 does everything EXCEPT the real merge / worktree remove / scribe /
# ff-pull, and never spawns the reviewer/resolver or writes their state files.
#
# Renders ONLY when the computed frame changes — an idle pane never repaints. Polls every ~4s.
set -u

# BASH_SOURCE (not $0) so HERE resolves correctly whether this file is executed or sourced
# (the hermetic test sources it to exercise the pure merge-decision helper).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/herd-config.sh"
# Engine journal — append-only forensic record of every gate event (best-effort, never breaks us).
. "$HERE/journal.sh"
MAIN="$PROJECT_ROOT"
TREES="$WORKTREES_DIR"
STATE="$TREES/.agent-watch-merged"
# Resolve-attempt ledger, PARALLEL to $STATE: one line per conflict-resolver SPAWN
# ("<epoch> <pr#> <slug> <branch>"). A branch that already has a recorded attempt is NEVER given a
# second resolver (a failed/escalated resolve leaves the PR CONFLICTING; re-spawning would loop).
RESOLVE_STATE="$TREES/.agent-watch-resolve-attempts"
# Review ledger, PARALLEL to $STATE/$RESOLVE_STATE: one line per PRE-MERGE REVIEW
# ("<epoch> <pr#> <headSha> <verdict>"). Keyed by PR *and* head sha so a PR is reviewed at most
# ONCE PER COMMIT — a recorded BLOCK is read back instead of re-spawning the reviewer; a recorded
# PASS lets a retried merge skip straight to merging. A new commit changes the sha → fresh review.
REVIEW_STATE="$TREES/.agent-watch-reviewed"
# Review-retry ledger: one line per TRANSIENT review failure ("<epoch> <pr#> <headSha>") — an
# INFRA-FAIL verdict, an unparseable result, or a dispatched reviewer that died without writing
# its result file. Counted per pr+sha to bound re-dispatches (a new commit resets the count);
# NEVER records a verdict — INFRA failures must not stick to a sha the way BLOCK does.
REVIEW_RETRIES="$TREES/.agent-watch-review-retries"
# Max transient failures per pr+sha before the watcher stops re-dispatching and asks for a human.
_REVIEW_RETRY_MAX=3
# Refix ledger: one line per auto-refix bounce ("<epoch> <pr#> <headSha> <slug>"). Sha-keyed
# (one bounce per BLOCK per sha; new commit → fresh budget). Total per PR capped at REFIX_MAX_ROUNDS;
# further BLOCKs after the cap escalate to "needs you".
REFIX_STATE="$TREES/.agent-watch-refixed"
# Override ledger: one line per human override of a cached BLOCK.
# Format: "<epoch> override <pr#> <headSha>"
# Written by herd-approve.sh override <pr#>; keyed by sha so a new commit invalidates the override.
OVERRIDES="$TREES/.agent-watch-overrides"
# Approval ledger (MERGE_POLICY=approve|observe): one line per record, append-only.
# Format: "<epoch> awaiting <pr#> <headSha>"  — watcher noted gates passed, awaiting human approval
#         "<epoch> approved <pr#> <headSha>"  — herd-approve.sh wrote explicit approval for this sha
#         "<epoch> observed <pr#> <headSha>"  — watcher notified in observe mode (dedup guard)
APPROVALS="$TREES/.agent-watch-approvals"
# Transcript-growth ledger for the builder stall detector: one line per active worktree slug
# ("<slug> <transcript-bytes> <newest-mtime>") caching the last poll's Claude session-transcript
# observation. A grown transcript between polls is a liveness signal that vetoes a would-be stall
# warning; see the "Builder liveness" helpers below.
TRANSCRIPT_STATE="$TREES/.agent-watch-transcript"
# Healthcheck ledger, PARALLEL to the review ledgers: one line per healthcheck ATTEMPT
# ("<epoch> <pr#> <slug> <attempt> <outcome>"), outcome ∈ clean | dataenv | code-error | flaky-pass.
# This is the healthcheck analogue of $REVIEW_STATE — an append-only provenance record so a red row
# is always backed by an auditable "code-error reproduced on the solo retry" pair, and a flaky one
# by a "code-error then flaky-pass" pair. PR #49 gave the review gate provenance via ledger fields;
# there is no unified engine journal yet, so this mirrors that mechanism and leaves a clean seam for
# the upcoming journal item to fold these rows in. Never gates behavior — purely a record.
HEALTH_STATE="$TREES/.agent-watch-healthchecks"
# Only truthy values enable dry-run. Treat "0"/""/"false"/"no" as live.
case "${AGENT_WATCH_DRYRUN:-}" in 1|true|yes|on) DRYRUN=1 ;; *) DRYRUN="" ;; esac

# _effective_merge_policy — resolve "auto" | "approve" | "observe".
# MERGE_POLICY takes precedence; falls back to legacy WATCHER_AUTOMERGE when unset/empty.
_effective_merge_policy() {
  case "${MERGE_POLICY:-}" in
    auto|approve|observe) printf '%s' "${MERGE_POLICY}" ;;
    *)
      case "${WATCHER_AUTOMERGE:-true}" in
        false|no|off|0) printf 'approve' ;;
        *)              printf 'auto' ;;
      esac ;;
  esac
}
_pol="$(_effective_merge_policy)"
AUTOMERGE=""; MERGE_OBSERVE=""
case "$_pol" in
  auto)    AUTOMERGE=1 ;;
  observe) MERGE_OBSERVE=1 ;;
esac
unset _pol
# This watcher's own worktree root — never auto-merge/remove the dir we run from.
SELF_WT="$(cd "$HERE/../.." && pwd)"

# Tokyo Night palette (truecolor — this is a status console, not markdown).
C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
C_BLUE=$'\033[38;2;122;162;247m'
C_CYAN=$'\033[38;2;125;207;255m'
C_GREEN=$'\033[38;2;158;206;106m'
C_YELLOW=$'\033[38;2;224;175;104m'
C_RED=$'\033[38;2;247;118;142m'
C_DIM=$'\033[38;2;86;95;137m'

SLUGW=28               # slug column width — pads slugs so the state words align.

last_frame=""
HDR_LINE=""
RULE=""
LANDED=""
DISPLAY=()

# build_header — the title row + a full-width rule.
build_header() {
  hhmm="$(date +%H:%M)"
  rlabel="live"; [ -n "$DRYRUN" ] && rlabel="dry-run"
  cols="$(tput cols 2>/dev/null || echo 56)"
  [ "$cols" -lt 40 ] && cols=40
  [ "$cols" -gt 64 ] && cols=64
  rcells=$(( ${#rlabel} + 3 + 5 ))
  pad=$(( cols - 13 - rcells )); [ "$pad" -lt 1 ] && pad=1
  spaces="$(printf '%*s' "$pad" '')"
  HDR_LINE=" ${C_BOLD}${C_CYAN}🐑 herd watch${C_RESET}${spaces}${C_DIM}${rlabel} · ${hhmm}${C_RESET}"
  RULE=" ${C_DIM}$(python3 -c "print('═'*$cols)")${C_RESET}"
}

# epoch_to_hhmm <epoch> — HH:MM from a Unix timestamp; BSD/macOS (-r) and GNU/Linux (-d @) safe.
epoch_to_hhmm() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null || echo '--:--'; }
# reverse_file <path> — print lines in reverse order; tac (GNU/Linux) or tail -r (BSD/macOS).
reverse_file() { tac "$1" 2>/dev/null || tail -r "$1" 2>/dev/null; }

# build_landed — the pinned "recently landed" rows: the last 3 lines of the state file
# ("<epoch> <pr#> <slug>"), newest first. Stays visible even when idle.
build_landed() {
  if [ ! -s "$STATE" ]; then
    LANDED="    ${C_DIM}nothing yet${C_RESET}"$'\n'
    return 0
  fi
  LANDED=""
  while read -r epoch prnum slug; do
    [ -z "${epoch:-}" ] && continue
    hhmm="$(epoch_to_hhmm "$epoch")"
    pnum="$(printf '#%-4s' "$prnum")"
    sl="$(printf '%-*s' "$SLUGW" "$slug")"
    LANDED="${LANDED}    ${C_GREEN}✅${C_RESET} ${C_DIM}${pnum}${C_RESET} ${C_GREEN}${sl}${C_RESET} ${C_DIM}${hhmm}${C_RESET}"$'\n'
  done < <(reverse_file "$STATE" | head -3)
}

# render — paint the whole rollup card, but ONLY when the computed frame changed.
render() {
  frame="${HDR_LINE}"$'\n'"${RULE}"$'\n\n'
  frame="${frame}  ${C_DIM}recently landed${C_RESET}"$'\n'"${LANDED}"$'\n'
  frame="${frame}  ${C_DIM}in flight${C_RESET}"$'\n'
  if [ "${#DISPLAY[@]}" -eq 0 ]; then
    frame="${frame}    ${C_DIM}— idle —${C_RESET}"$'\n'
  else
    for line in "${DISPLAY[@]}"; do frame="${frame}${line}"$'\n'; done
  fi
  if [ "$frame" != "$last_frame" ]; then
    clear
    if printf '%b' "$frame"; then last_frame="$frame"; fi
  fi
}

# already_merged <pr#> <slug> — idempotency guard against the persistent state file.
already_merged() {
  [ -s "$STATE" ] || return 1
  grep -q "^[0-9][0-9]* $1 $2\$" "$STATE" 2>/dev/null
}

# _should_automerge <mergeStateStatus> — the pure merge-readiness predicate. GitHub computes
# mergeStateStatus by folding in ALL branch-protection gates, so the watcher auto-merges ONLY when
# it reports CLEAN (every required review/CODEOWNERS approval present, branch up to date, every
# required status check green). Any other state is a HOLD, never a human-action error:
#   BLOCKED  — required reviews / CODEOWNERS not yet satisfied
#   BEHIND   — branch out of date with base
#   UNSTABLE — a required status check is pending or failing
#   plus DIRTY/DRAFT/HAS_HOOKS/UNKNOWN/empty/anything else.
# Returns 0 (merge) ONLY for CLEAN; non-zero (hold, re-evaluate next tick) otherwise.
_should_automerge() {
  [ "${1:-}" = "CLEAN" ]
}

# resolver_attempted <branch> — the resolve-loop guard.
resolver_attempted() {
  [ -s "$RESOLVE_STATE" ] || return 1
  awk -v b="$1" '$4==b{f=1} END{exit !f}' "$RESOLVE_STATE" 2>/dev/null
}

# record_resolve_attempt <pr#> <slug> <branch> — append one spawn record (BEFORE the spawn).
record_resolve_attempt() {
  printf '%s %s %s %s\n' "$(date +%s)" "$1" "$2" "$3" >> "$RESOLVE_STATE"
}

# review_verdict <pr#> <headSha> — the review-once-per-commit guard. Echoes the recorded verdict
# for this exact PR+sha, or nothing if none recorded.
review_verdict() {
  [ -s "$REVIEW_STATE" ] || return 1
  awk -v p="$1" -v s="$2" '$2==p && $3==s{v=$4} END{if(v){print v} else exit 1}' "$REVIEW_STATE" 2>/dev/null
}

# review_verdict_source <pr#> <headSha> — echoes the PROVENANCE of the recorded verdict for this
# exact PR+sha: "reviewer" (a real 'REVIEW: BLOCK/PASS' line from the reviewer, backed by a PR
# comment/finding), "gate_default" (a gate-generated default verdict with no reviewer finding), or
# "infra" (an infrastructure death). Legacy rows without a source field, or no row at all, default
# to "reviewer" so pre-provenance ledgers keep their existing auto-refix behavior. This is the
# hinge for the auto-refix SAFETY GATE: only "reviewer" verdicts may bounce a builder.
review_verdict_source() {
  [ -s "$REVIEW_STATE" ] || { printf 'reviewer'; return 0; }
  awk -v p="$1" -v s="$2" '$2==p && $3==s{src=$5} END{ if(src==""){src="reviewer"} print src }' "$REVIEW_STATE" 2>/dev/null || printf 'reviewer'
}

# record_review <pr#> <headSha> <verdict> [source] — append one review record (the instant a verdict
# is known). <source> is the verdict PROVENANCE (reviewer | gate_default | infra); defaults to
# "reviewer" when omitted. Only "reviewer" verdicts are ever cached as a sticky BLOCK AND are the
# only ones eligible to auto-refix a builder — a purely infrastructural death must never stick.
record_review() {
  printf '%s %s %s %s %s\n' "$(date +%s)" "$1" "$2" "$3" "${4:-reviewer}" >> "$REVIEW_STATE"
  journal_append verdict_recorded pr "$1" sha "$2" value "$3" source "${4:-reviewer}"
}

# ── Background review dispatch ──────────────────────────────────────────────────────────────────
# The review gate used to run herd-review.sh SYNCHRONOUSLY in the poll loop, so one slow review
# (~7 min on Opus) head-of-line-blocked every other PR's review AND all merges for that cycle.
# Reviews now run in the BACKGROUND, bounded by $REVIEW_CONCURRENCY:
#   .review-inflight-<pr>-<sha>  — dispatch marker holding the reviewer's pid; its existence (with
#                                  a live pid) is the never-double-dispatch guard, sha-keyed to
#                                  mirror the review-once ledger semantics.
#   .review-result-<pr>-<sha>    — the verdict line, written ATOMICALLY by herd-review.sh as its
#                                  LAST act (via $HERD_REVIEW_RESULT_FILE). The watcher collects
#                                  these on subsequent ticks, records the ledger exactly as the
#                                  synchronous gate did, and merges on PASS.
# Crash-safety: a marker whose pid is dead with no result file = a severed reviewer → reaped and
# re-dispatched (bounded by $_REVIEW_RETRY_MAX per sha). A result file for a STALE sha (the PR has
# a newer head) is discarded unread. INFRA-FAIL results are retried, never cached.
# HERD_REVIEW_BIN is a test seam: the hermetic suite points it at a stub reviewer.
: "${HERD_REVIEW_BIN:="$HERE/herd-review.sh"}"

_review_inflight_file() { printf '%s' "$TREES/.review-inflight-$1-$2"; }
_review_result_file()   { printf '%s' "$TREES/.review-result-$1-$2"; }

# _review_pid_live <inflight-file> — true if the marker records a still-running reviewer pid.
_review_pid_live() {
  local pid; pid="$(head -1 "$1" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# _count_live_reviews — number of inflight markers (across ALL PRs) whose reviewer pid is alive.
# Dead markers are not counted (they are reaped by _review_gate_step), so a crashed reviewer
# never wedges a concurrency slot.
_count_live_reviews() {
  local n=0 f
  for f in "$TREES"/.review-inflight-*; do
    [ -e "$f" ] || continue
    _review_pid_live "$f" && n=$((n+1))
  done
  printf '%s' "$n"
}

# _review_retry_count <pr#> <headSha> — transient-failure count for this exact pr+sha.
_review_retry_count() {
  [ -s "$REVIEW_RETRIES" ] || { printf '0'; return 0; }
  awk -v p="$1" -v s="$2" '$2==p && $3==s{n++} END{print n+0}' "$REVIEW_RETRIES" 2>/dev/null || printf '0'
}

# record_review_retry <pr#> <headSha> — note one transient failure (never a verdict).
record_review_retry() {
  printf '%s %s %s\n' "$(date +%s)" "$1" "$2" >> "$REVIEW_RETRIES"
}

# _discard_stale_reviews <pr#> <currentSha> — a result or inflight marker for this PR keyed to
# ANY OTHER sha is stale (the PR has a newer head; that verdict must never be read). Discard
# stale results unread; TERM a stale in-flight reviewer (best-effort — herd-review.sh traps TERM
# and reports INFRA-FAIL to its own stale result file, which lands here next tick) and drop its
# marker so the concurrency slot frees up.
_discard_stale_reviews() {
  local pr="$1" sha="$2" f base
  for f in "$TREES/.review-result-$pr-"* "$TREES/.review-inflight-$pr-"*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "${base##*-}" = "$sha" ] && continue
    case "$base" in
      .review-inflight-*)
        local pid; pid="$(head -1 "$f" 2>/dev/null || true)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true ;;
    esac
    rm -f "$f" 2>/dev/null || true
  done
}

# _dispatch_review <pr#> <slug> <headSha> — launch herd-review.sh in the background, result file
# wired via $HERD_REVIEW_RESULT_FILE, and write the inflight marker (pid) for this exact pr+sha.
# Idempotent: an existing result file or live marker means this pr+sha is already handled — never
# double-dispatch. Callers gate on concurrency/retries; this only guards identity.
_dispatch_review() {
  local pr="$1" slug="$2" sha="$3" result inflight
  result="$(_review_result_file "$pr" "$sha")"
  inflight="$(_review_inflight_file "$pr" "$sha")"
  [ -f "$result" ] && return 0
  [ -f "$inflight" ] && _review_pid_live "$inflight" && return 0
  HERD_REVIEW_RESULT_FILE="$result" bash "$HERD_REVIEW_BIN" "$pr" "$slug" >/dev/null 2>&1 &
  local _dr_pid="$!"
  printf '%s\n' "$_dr_pid" > "$inflight"
  journal_append review_dispatched pr "$pr" sha "$sha" pid "$_dr_pid" \
    model "${HERD_REVIEW_MODEL:-${MODEL_REVIEW:-}}" log_path "$result"
}

# _review_gate_step <pr#> <slug> <headSha> — one NON-BLOCKING step of the background review state
# machine, called once per tick for a candidate with no ledger verdict yet. Echoes one token:
#   PASS | BLOCK — a result file was just collected; the verdict is now in the ledger
#   RUNNING      — reviewer in flight (just dispatched or still working)
#   QUEUED       — all $REVIEW_CONCURRENCY slots busy; will dispatch on a later tick
#   RETRY        — transient failure (INFRA-FAIL / dead reviewer); re-dispatches next tick
#   FAILED       — $_REVIEW_RETRY_MAX transient failures for this sha; needs a human
_review_gate_step() {
  local pr="$1" slug="$2" sha="$3" result inflight verdict_line
  _discard_stale_reviews "$pr" "$sha"
  result="$(_review_result_file "$pr" "$sha")"
  inflight="$(_review_inflight_file "$pr" "$sha")"

  # Collect a finished verdict: record to the ledger exactly as the synchronous gate did.
  if [ -f "$result" ]; then
    verdict_line="$(grep -E '^REVIEW: (PASS|BLOCK|INFRA-FAIL)' "$result" 2>/dev/null | tail -1)"
    rm -f "$result" "$inflight" 2>/dev/null || true
    case "$verdict_line" in
      # A parseable PASS/BLOCK is reviewer-backed (herd-review.sh only emits these from a real
      # verdict line + PR comment; a no-verdict run now reports INFRA-FAIL, not a default BLOCK).
      "REVIEW: PASS")   record_review "$pr" "$sha" "PASS"  "reviewer"; echo PASS;  return 0 ;;
      "REVIEW: BLOCK"*) record_review "$pr" "$sha" "BLOCK" "reviewer"; echo BLOCK; return 0 ;;
      *)
        # INFRA-FAIL, EMPTY capture, or rc0-no-verdict: an infrastructural death, NOT a refused
        # verdict — never cached to the ledger, retried next poll with a cap.
        record_review_retry "$pr" "$sha"
        if [ "$(_review_retry_count "$pr" "$sha")" -ge "$_REVIEW_RETRY_MAX" ]; then echo FAILED; else echo RETRY; fi
        return 0 ;;
    esac
  fi

  # In flight and alive → wait. Dead with no result = severed reviewer → reap, count, re-dispatch.
  if [ -f "$inflight" ]; then
    if _review_pid_live "$inflight"; then echo RUNNING; return 0; fi
    rm -f "$inflight" 2>/dev/null || true
    record_review_retry "$pr" "$sha"
  fi

  if [ "$(_review_retry_count "$pr" "$sha")" -ge "$_REVIEW_RETRY_MAX" ]; then echo FAILED; return 0; fi
  if [ "$(_count_live_reviews)" -ge "${REVIEW_CONCURRENCY:-2}" ]; then echo QUEUED; return 0; fi
  _dispatch_review "$pr" "$slug" "$sha"
  echo RUNNING
}

# override_exists <pr#> <headSha> — true if a human override was recorded for this exact pr+sha.
# A new commit changes the sha → override does not carry over.
override_exists() {
  [ -s "$OVERRIDES" ] || return 1
  grep -q "^[0-9]* override $1 $2$" "$OVERRIDES" 2>/dev/null
}

# approval_awaiting_noted <pr#> <headSha> — true if we already recorded an awaiting-approval notice.
approval_awaiting_noted() {
  [ -s "$APPROVALS" ] || return 1
  grep -q "^[0-9]* awaiting $1 $2$" "$APPROVALS" 2>/dev/null
}

# approval_is_approved <pr#> <headSha> — true if herd-approve.sh wrote an explicit approval.
approval_is_approved() {
  [ -s "$APPROVALS" ] || return 1
  grep -q "^[0-9]* approved $1 $2$" "$APPROVALS" 2>/dev/null
}

# record_approval_awaiting <pr#> <headSha> — note gates passed; awaiting human approval.
record_approval_awaiting() {
  printf '%s awaiting %s %s\n' "$(date +%s)" "$1" "$2" >> "$APPROVALS"
}

# observe_noted <pr#> <headSha> — true if we already sent an observe-mode notification.
observe_noted() {
  [ -s "$APPROVALS" ] || return 1
  grep -q "^[0-9]* observed $1 $2$" "$APPROVALS" 2>/dev/null
}

# record_observe_noted <pr#> <headSha> — note that we notified in observe mode.
record_observe_noted() {
  printf '%s observed %s %s\n' "$(date +%s)" "$1" "$2" >> "$APPROVALS"
}

# _merge_method_flag — return the gh pr merge flag for the configured MERGE_METHOD.
_merge_method_flag() {
  case "${MERGE_METHOD:-merge}" in
    squash) printf '%s' '--squash' ;;
    rebase) printf '%s' '--rebase' ;;
    *)      printf '%s' '--merge' ;;
  esac
}

# spawn_resolver <slug> <pr#> <branch> — hand a newly-CONFLICTING PR to the isolated resolver.
# Record-first keeps the loop guard sound; the spawn is best-effort.
spawn_resolver() {
  rs="$1"; rp="$2"; rb="$3"
  record_resolve_attempt "$rp" "$rs" "$rb"
  bash "$HERE/herd-resolve.sh" "$rs" >/dev/null 2>&1 || true
}

# do_merge <slug> <pr#> <worktree> — the safety-railed merge + post-merge sequence.
do_merge() {
  ds="$1"; dp="$2"; dd="$3"; dsha="${4:-}"
  if [ -n "$DRYRUN" ]; then
    return 0
  fi
  gh pr merge "$dp" "$(_merge_method_flag)" >/dev/null 2>&1 || return 1
  # Record FIRST: even if a later cleanup step dies, we never re-merge this PR.
  printf '%s %s %s\n' "$(date +%s)" "$dp" "$ds" >> "$STATE"
  journal_append merge pr "$dp" slug "$ds" sha "$dsha" method "$(_merge_method_flag)" reason gates_passed
  # 1) enqueue the scribe to reap the backlog item for this slug (slug-match + reap-not-stamp).
  bash "$HERE/scribe.sh" "Reap the backlog item for worktree slug '${ds}' (PR #${dp}): (1) grep ${BACKLOG_FILE} for the line containing '(worktree ${ds})' to locate the exact item; (2) if found, REMOVE that item from its active/thematic section entirely; (3) prepend '- ✅ **<title>** *(PR #${dp})*' (substituting the actual item title) immediately after the '## Recently shipped' heading, then drop any trailing entry beyond the 10th to keep the window capped at ~10; (4) if NO line matches that slug, make NO change and report that there is no backlog item for slug '${ds}'." >/dev/null 2>&1 || true
  # 2) fast-forward the MAIN checkout so coordinator + backlog viewer reflect it. Never force.
  git -C "$MAIN" pull --ff-only >/dev/null 2>&1 || git -C "$MAIN" fetch --all >/dev/null 2>&1 || true
  # 3) remove the worktree (force: the SHARE_LINKS symlinks make a non-force remove fail).
  git -C "$MAIN" worktree remove --force "$dd" >/dev/null 2>&1 || true
  journal_append reap pr "$dp" slug "$ds" sha "$dsha" reason merged
  # 4) TEARDOWN is the WATCHER's job — sub-agents NEVER self-close. Close the builder tab,
  #    review tab (review·slug), and resolver tab (resolve·slug) in one shot. Verifies each
  #    close and retries once; warns loudly if a tab cannot be closed.
  herd_teardown_slug "$ds"
  return 0
}

# _sweep_orphan_tabs — close engine-created tabs whose slug no longer has a live worktree or
# an open PR. Runs every _ORPHAN_SWEEP_INTERVAL ticks (~60 s). Scoped to this project's
# workspace to avoid touching another project's tabs. Skipped in dry-run mode.
#
# ALLOWLIST model: the sweep ONLY ever considers tabs listed in $TREES/.herd-tabs — a registry
# written by the lane scripts (herd-feature, herd-resolve, herd-review) when they create a
# reapable tab. Tabs the engine never created (user tabs like playground-*, watch-*) are simply
# not in the registry and therefore can never be swept, regardless of their label.
#
# MIGRATION mode (registry file absent): on first run before any engine tab has been recorded,
# fall back to sweeping review·<slug> / resolve·<slug> labels for dead slugs only — NEVER bare
# labels. This prevents sweeping user tabs during the transition to the registry model.
#
# Self-exclusion: HERD_WATCHER_TAB_ID (set by coordinator.sh via --env) is always excluded even
# if it somehow appeared in the registry, so the watcher can never sweep its own host tab.
_sweep_orphan_tabs() {
  [ -n "$DRYRUN" ] && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  local _sw_wsid; _sw_wsid="$(herd_resolve_workspace_id 2>/dev/null || true)"
  local _sw_tabs; _sw_tabs="$(herdr tab list 2>/dev/null || true)"
  [ -n "$_sw_tabs" ] || return 0

  # Collect live slugs from worktrees (excluding the main checkout).
  local _sw_wt_json; _sw_wt_json="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null || true)"
  local _sw_wt_slugs
  _sw_wt_slugs="$(WT="$_sw_wt_json" MAIN="$MAIN" python3 -c '
import os
main = os.environ["MAIN"]
for line in os.environ.get("WT","").splitlines():
  if line.startswith("worktree "):
    p = line[9:]
    if p != main:
      print(os.path.basename(p))
' 2>/dev/null || true)"

  # Collect live slugs from open PRs (headRefName last component).
  local _sw_pr_slugs
  _sw_pr_slugs="$(gh pr list --json headRefName 2>/dev/null | python3 -c '
import sys, json
try:
  for p in json.load(sys.stdin):
    b = p.get("headRefName","")
    if b: print(b.split("/")[-1])
except Exception:
  pass
' 2>/dev/null || true)"

  local _sw_live
  _sw_live="$(printf '%s\n%s\n' "$_sw_wt_slugs" "$_sw_pr_slugs" | sort -u | grep -v '^$' || true)"

  local _sw_registry="$TREES/.herd-tabs"
  local _sw_self_tab="${HERD_WATCHER_TAB_ID:-}"

  # Find orphaned tab IDs.
  # Allowlist mode (registry file present): only tabs listed in the registry.
  # Migration mode (no registry): only review·<slug>/resolve·<slug> labels; NEVER bare labels.
  local _sw_orphans
  _sw_orphans="$(printf '%s' "$_sw_tabs" \
    | WS="$_sw_wsid" LIVE="$_sw_live" SELF_TAB="$_sw_self_tab" \
      REGISTRY_PATH="$_sw_registry" \
      python3 -c '
import sys, json, os

ws        = os.environ.get("WS", "")
live      = set(os.environ.get("LIVE","").split("\n")) - {""}
self_tab  = os.environ.get("SELF_TAB", "")
reg_path  = os.environ.get("REGISTRY_PATH", "")
MID       = "·"

# Load registry (tab_id -> slug).  Absent file → migration mode.
reg_exists = False
registry   = {}
try:
    with open(reg_path) as rf:
        reg_exists = True
        for line in rf:
            parts = line.strip().split(" ", 2)
            if len(parts) >= 2:
                label, tab_id = parts[0], parts[1]
                if label.startswith("review" + MID):
                    slug = label[len("review" + MID):]
                elif label.startswith("resolve" + MID):
                    slug = label[len("resolve" + MID):]
                else:
                    slug = label
                if tab_id:
                    registry[tab_id] = slug
except Exception:
    pass

try:
  tabs = json.load(sys.stdin).get("result",{}).get("tabs",[])
  for t in tabs:
    tab_id = t.get("tab_id","") or ""
    label  = t.get("label","") or ""
    if not tab_id or not label: continue
    if self_tab and tab_id == self_tab: continue
    if ws and t.get("workspace_id","") != ws: continue
    if reg_exists:
      # Allowlist mode: only registered tabs are candidates.
      if tab_id not in registry: continue
      slug = registry[tab_id]
    else:
      # Migration mode: only review·/resolve· labels; never bare labels.
      if label.startswith("review" + MID):
        slug = label[len("review" + MID):]
      elif label.startswith("resolve" + MID):
        slug = label[len("resolve" + MID):]
      else:
        continue
    if slug and slug not in live:
      print(tab_id)
except Exception:
  pass
' 2>/dev/null || true)"

  [ -n "$_sw_orphans" ] || return 0
  local _sw_id
  while IFS= read -r _sw_id; do
    [ -n "$_sw_id" ] || continue
    herdr tab close "$_sw_id" >/dev/null 2>&1 || true
    journal_append sweep_closed tab_id "$_sw_id" reason orphan
    # Remove the swept tab from the registry so it doesn't accumulate stale entries.
    if [ -f "$_sw_registry" ]; then
      TAB_ID="$_sw_id" REGISTRY_PATH="$_sw_registry" python3 -c '
import os
path = os.environ.get("REGISTRY_PATH", "")
tid  = os.environ.get("TAB_ID", "")
if not path or not tid: exit(0)
try:
    with open(path) as f: lines = f.readlines()
    with open(path, "w") as f:
        for line in lines:
            parts = line.strip().split(" ", 2)
            if not (len(parts) >= 2 and parts[1] == tid):
                f.write(line)
except Exception: pass
' 2>/dev/null || true
    fi
  done <<< "$_sw_orphans"
}

# ── Auto-refix: bounce BLOCK-reviewed PRs straight to the builder agent ────────────────────────
# Enabled by REVIEW_AUTOFIX=true in .herd/config (default false). When the watcher records a
# BLOCK verdict for PR <n> (slug S), it finds S's AGENT pane (NOT the tab's root shell pane —
# text sent there vanishes and the agent never wakes), sends a re-task prompt via herdr pane run,
# and verifies agent_status flips to "working" within HERD_REFIX_WAIT_TIMEOUT seconds (default 15),
# retrying once. On persistent failure it surfaces "needs you · auto-refix failed" on the row.
#
# Sha-keyed refix-once semantics mirror review-once: one bounce per BLOCK per sha. A new commit
# changes the sha → a fresh bounce is eligible for the new sha's BLOCK (if any). Total bounces
# per PR are capped at REFIX_MAX_ROUNDS (default 3); further BLOCKs escalate to "needs you".

# refix_attempted <pr#> <headSha> — true if a bounce was already recorded for this exact pr+sha.
refix_attempted() {
  [ -s "$REFIX_STATE" ] || return 1
  awk -v p="$1" -v s="$2" '$2==p && $3==s{f=1} END{exit !f}' "$REFIX_STATE" 2>/dev/null
}

# refix_round_count <pr#> — total bounces recorded for this PR (across all shas).
refix_round_count() {
  [ -s "$REFIX_STATE" ] || { printf '0'; return 0; }
  awk -v p="$1" '$2==p{n++} END{print n+0}' "$REFIX_STATE" 2>/dev/null || printf '0'
}

# record_refix <pr#> <headSha> <slug> — append one bounce record.
record_refix() {
  printf '%s %s %s %s\n' "$(date +%s)" "$1" "$2" "$3" >> "$REFIX_STATE"
}

# _find_builder_pane_id <slug> — find the herdr agent pane_id for the builder whose name==slug
# and whose agent_status is "idle" (idle means it's waiting for a task, not already working).
# Prints the pane_id to stdout; prints nothing if the agent is absent or already working.
_find_builder_pane_id() {
  local _fpid_slug="$1"
  herdr agent list 2>/dev/null | SLUG="$_fpid_slug" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
  agents = (json.load(sys.stdin).get("result") or {}).get("agents") or []
  for a in agents:
    if a.get("name") == slug and a.get("agent_status") == "idle":
      print(a.get("pane_id", ""), end="")
      break
except Exception:
  pass
' 2>/dev/null || true
}

# _agent_status <slug> — current agent_status string for this agent (empty if not found).
_agent_status() {
  local _as_slug="$1"
  herdr agent list 2>/dev/null | SLUG="$_as_slug" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
  agents = (json.load(sys.stdin).get("result") or {}).get("agents") or []
  for a in agents:
    if a.get("name") == slug:
      print(a.get("agent_status", ""), end="")
      break
except Exception:
  pass
' 2>/dev/null || true
}

# _wait_agent_working <slug> <timeout-s> — poll herdr agent list until agent_status is "working"
# or the timeout expires. Returns 0 if the agent woke; 1 if timeout expired.
_wait_agent_working() {
  local _waw_slug="$1" _waw_timeout="$2" _waw_deadline
  _waw_deadline=$(( $(date +%s) + _waw_timeout ))
  while [ "$(date +%s)" -lt "$_waw_deadline" ]; do
    [ "$(_agent_status "$_waw_slug")" = "working" ] && return 0
    sleep 1
  done
  return 1
}

# _handle_block_verdict <pr#> <slug> <headSha> <display-idx>
# Called when the review verdict for a PR is BLOCK (from the ledger or a fresh gate step). If
# REVIEW_AUTOFIX=true, attempts to bounce the builder agent; otherwise shows the standard message.
# Always updates DISPLAY[<idx>]; calls render internally before the blocking wait so the user sees
# "refixing" while the bounce is in progress.
_handle_block_verdict() {
  local _hbv_pr="$1" _hbv_slug="$2" _hbv_sha="$3" _hbv_idx="$4"
  local _hbv_sl _hbv_pn
  _hbv_sl="$(printf '%-*s' "$SLUGW" "$_hbv_slug")"
  _hbv_pn=" ${C_DIM}#${_hbv_pr}${C_RESET} ·"

  if [ "${REVIEW_AUTOFIX:-false}" = "true" ] && [ -z "${DRYRUN:-}" ]; then
    # SAFETY GATE: only a REVIEWER-BACKED block may bounce a builder. A gate-generated default
    # verdict (or any non-reviewer provenance) carries no actionable finding — bouncing on it
    # sends the builder a "fix" prompt with nothing to fix (2026-07-02 incident: a no-verdict
    # default-BLOCK woke a builder that then worked on noise and had to be stood down by hand).
    # Provenance lives in the review ledger row's source field; legacy/absent → "reviewer".
    local _hbv_src
    _hbv_src="$(review_verdict_source "$_hbv_pr" "$_hbv_sha")"
    if [ "$_hbv_src" != "reviewer" ]; then
      DISPLAY[_hbv_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_RED}needs you · review blocked without a reviewer finding (${_hbv_src}) · not auto-refixed · see PR #${_hbv_pr}${C_RESET}"
      return 0
    fi
    local _hbv_rounds
    _hbv_rounds="$(refix_round_count "$_hbv_pr")"
    if refix_attempted "$_hbv_pr" "$_hbv_sha"; then
      # Already bounced for this sha; the agent should be working on a fix — wait for a new push.
      DISPLAY[_hbv_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_YELLOW}review blocked · fix requested · awaiting push${C_RESET}"
    elif [ "$_hbv_rounds" -ge "${REFIX_MAX_ROUNDS:-3}" ]; then
      DISPLAY[_hbv_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_RED}needs you · refix limit (${REFIX_MAX_ROUNDS:-3} rounds) reached · see PR #${_hbv_pr}${C_RESET}"
    else
      local _hbv_round_num
      _hbv_round_num="$((_hbv_rounds + 1))"
      DISPLAY[_hbv_idx]="    ${C_CYAN}🔁${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_CYAN}refixing (round ${_hbv_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
      render
      # Record BEFORE sending so refix-once holds even if pane lookup or delivery fails.
      record_refix "$_hbv_pr" "$_hbv_sha" "$_hbv_slug"
      local _hbv_status_before
      _hbv_status_before="$(_agent_status "$_hbv_slug")"
      journal_append refix_bounce pr "$_hbv_pr" sha "$_hbv_sha" slug "$_hbv_slug" \
        round "$_hbv_round_num" agent_status_before "${_hbv_status_before:-unknown}"
      local _hbv_pane_id _hbv_woke=0 _hbv_escalated=false
      _hbv_pane_id="$(_find_builder_pane_id "$_hbv_slug")"
      if [ -z "$_hbv_pane_id" ]; then
        DISPLAY[_hbv_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_RED}needs you · auto-refix failed · agent pane not found${C_RESET}"
        _hbv_escalated=true
      else
        local _hbv_prompt
        _hbv_prompt="PR #${_hbv_pr} was review-blocked. Read the full review: gh pr view ${_hbv_pr}
Fix every issue the reviewer raised, run the healthcheck, push your fix, and reply to the review comment once done."
        herdr pane run "$_hbv_pane_id" "$_hbv_prompt" >/dev/null 2>&1 || true
        local _hbv_wait="${HERD_REFIX_WAIT_TIMEOUT:-15}"
        if _wait_agent_working "$_hbv_slug" "$_hbv_wait"; then
          _hbv_woke=1
        else
          # First wait expired → retry once (re-send the prompt in case pane run dropped it).
          herdr pane run "$_hbv_pane_id" "$_hbv_prompt" >/dev/null 2>&1 || true
          if _wait_agent_working "$_hbv_slug" "$_hbv_wait"; then
            _hbv_woke=1
          else
            DISPLAY[_hbv_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_RED}needs you · auto-refix failed · check pane${C_RESET}"
            _hbv_escalated=true
          fi
        fi
      fi
      local _hbv_status_after
      _hbv_status_after="$(_agent_status "$_hbv_slug")"
      journal_append refix_wake_result pr "$_hbv_pr" sha "$_hbv_sha" slug "$_hbv_slug" \
        round "$_hbv_round_num" agent_status_before "${_hbv_status_before:-unknown}" \
        agent_status_after "${_hbv_status_after:-unknown}" \
        woke "$_hbv_woke" escalated "$_hbv_escalated"
    fi
  else
    # REVIEW_AUTOFIX disabled or dry-run: show the standard "review blocked" message.
    DISPLAY[_hbv_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_RED}review blocked · see PR #${_hbv_pr} comment · herd-approve.sh why ${_hbv_pr}${C_RESET}"$'\n'"       ${C_DIM}└─ new commit auto-re-reviews · override: herd-approve.sh override ${_hbv_pr}${C_RESET}"
  fi
}

# ── Builder liveness (pre-PR stall detection) ────────────────────────────────────────────────────
# A builder with no PR yet used to be flagged "stalled? · check pane" the moment it hit 5 minutes
# with zero branch commits. But builders normally commit exactly ONCE, at the very end, right
# before `gh pr create` — so a plain commit-count heuristic falsely alarms on EVERY normal >5-min
# build while the agent is heads-down editing uncommitted files. Replace it with a liveness ladder,
# checked in order, that treats an actively-coding builder as building and only warns on a tree
# that is genuinely quiet:
#   1. WORKTREE ACTIVITY  — fresh mtime among the worktree's dirty/untracked paths ⇒ building
#   2. AGENT STATUS       — agent_status=="working" WITH any worktree edits (even stale) ⇒ building
#   3. TRANSCRIPT GROWTH  — the Claude session transcript grew since the last poll ⇒ building
#      (a one-way veto: it can only ever RESCUE a builder from a stall, never cause one)
#   4. otherwise (clean/quiet tree, zero commits, flat transcript) ⇒ the "no activity" warning
# The genuinely-dead case (agent_status != "working") is handled by the caller as "idle · no PR".

# file_mtime / _file_size — portable stat helpers (GNU stat -c vs BSD/macOS stat -f), detected once
# at load, mirroring backlog-view.sh's pattern.
if stat --version 2>/dev/null | grep -q GNU; then
  file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
  _file_size() { stat -c %s "$1" 2>/dev/null || echo 0; }
else
  file_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
  _file_size() { stat -f %z "$1" 2>/dev/null || echo 0; }
fi

# _stall_quiet_secs — how long (seconds) a working builder's tree may go quiet before the warning.
# Configurable via STALL_QUIET_MIN (minutes); non-numeric/unset falls back to a sane 5 minutes.
_stall_quiet_secs() {
  case "${STALL_QUIET_MIN:-}" in
    ''|*[!0-9]*) printf '%s' 300 ;;
    *)           printf '%s' $(( STALL_QUIET_MIN * 60 )) ;;
  esac
}

# _worktree_newest_edit <worktree> — echo the newest mtime (epoch secs) among the worktree's dirty
# and untracked paths (per `git status --porcelain`); echo nothing if the tree is clean or the path
# is not a git repo. This is the primary liveness signal: an actively-coding builder is constantly
# rewriting uncommitted files even though it won't `git commit` until the very end of the build.
_worktree_newest_edit() {
  local wt="$1" newest=0 line rel p m
  git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # porcelain v1: 2 status columns + a space, then the path ("<old> -> <new>" for renames).
    rel="${line:3}"
    case "$rel" in *" -> "*) rel="${rel##* -> }" ;; esac
    case "$rel" in \"*\") rel="${rel#\"}"; rel="${rel%\"}" ;; esac  # de-quote C-quoted odd names
    p="$wt/$rel"
    [ -e "$p" ] || continue                                        # a deletion has no path to stat
    m="$(file_mtime "$p")"
    [ "${m:-0}" -gt "$newest" ] && newest="$m"
  done < <(git -C "$wt" status --porcelain 2>/dev/null)
  [ "$newest" -gt 0 ] && printf '%s' "$newest"
}

# _transcript_obs <worktree> — echo "<total-bytes> <newest-mtime>" over the Claude session
# transcript(s) for this worktree, or nothing if none exist. Claude stores them at
# $HERD_TRANSCRIPT_ROOT/<munged>/*.jsonl where <munged> is the worktree's absolute path with '/'
# and '.' rewritten to '-'; the transcript grows as the agent works. Root is overridable for tests.
_transcript_obs() {
  local wt="$1" root munged d total=0 newest=0 f sz m
  root="${HERD_TRANSCRIPT_ROOT:-$HOME/.claude/projects}"
  munged="$(printf '%s' "$wt" | tr '/.' '-')"
  d="$root/$munged"
  [ -d "$d" ] || return 0
  for f in "$d"/*.jsonl; do
    [ -f "$f" ] || continue
    sz="$(_file_size "$f")"; total=$(( total + ${sz:-0} ))
    m="$(file_mtime "$f")"; [ "${m:-0}" -gt "$newest" ] && newest="$m"
  done
  [ "$total" -gt 0 ] && printf '%s %s' "$total" "$newest"
}

# _transcript_growing <slug> <obs> — compare this poll's observation ("<bytes> <mtime>") against the
# last one cached for this slug in $TRANSCRIPT_STATE; echo "yes" if it grew (more bytes or a newer
# mtime), "no" if flat (two identical observations), "unknown" if there is no prior observation or
# no transcript at all. Updates the cache. Only "yes" ever affects the verdict (a one-way veto), so
# a missing/mismatched transcript can never CAUSE a false stall — it just fails to rescue.
_transcript_growing() {
  local slug="$1" obs="$2" prev cur_size cur_mt prev_size prev_mt tmp
  [ -n "$obs" ] || { printf 'unknown'; return 0; }
  cur_size="${obs%% *}"; cur_mt="${obs##* }"
  prev=""
  [ -f "$TRANSCRIPT_STATE" ] && prev="$(awk -v s="$slug" '$1==s{print $2, $3}' "$TRANSCRIPT_STATE" 2>/dev/null | tail -1)"
  # Rewrite the cache: drop any prior line for this slug, append the fresh observation (temp+mv).
  tmp="${TRANSCRIPT_STATE}.$$"
  { [ -f "$TRANSCRIPT_STATE" ] && grep -v "^${slug} " "$TRANSCRIPT_STATE" 2>/dev/null
    printf '%s %s %s\n' "$slug" "$cur_size" "$cur_mt"
  } > "$tmp" 2>/dev/null && mv "$tmp" "$TRANSCRIPT_STATE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  [ -n "$prev" ] || { printf 'unknown'; return 0; }
  prev_size="${prev%% *}"; prev_mt="${prev##* }"
  if [ "${cur_size:-0}" -gt "${prev_size:-0}" ] || [ "${cur_mt:-0}" -gt "${prev_mt:-0}" ]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# _classify_builder <edit-age> <has-changes> <commits> <agent-status> <transcript-growing> <quiet> —
# the pure verdict for a working, PR-less builder. Echoes exactly one token:
#   BUILD_UNCOMMITTED — fresh uncommitted edits (actively coding right now)
#   BUILDING          — heads-down (working + edits, or transcript growing, or already has commits)
#   STALL             — clean/quiet tree, zero commits, flat transcript ⇒ show the warning
# <edit-age> is seconds since the newest dirty-file edit, or -1 when the tree has no dirty files.
_classify_builder() {
  local age="$1" changes="$2" commits="$3" status="$4" tgrow="$5" quiet="$6"
  # 1. fresh uncommitted edits ⇒ actively coding right now.
  if [ "$changes" -eq 1 ] && [ "$age" -ge 0 ] && [ "$age" -lt "$quiet" ]; then
    printf 'BUILD_UNCOMMITTED'; return 0
  fi
  # 2. a *working* agent with ANY worktree edits (even stale) is heads-down, never stalled.
  if [ "$status" = "working" ] && [ "$changes" -eq 1 ]; then
    printf 'BUILDING'; return 0
  fi
  # 3. transcript still growing ⇒ alive (one-way veto — only ever rescues from a stall).
  if [ "$tgrow" = "yes" ]; then
    printf 'BUILDING'; return 0
  fi
  # 4. quiet tree: only a commitless build with no other liveness signal earns the warning.
  if [ "${commits:-0}" -eq 0 ]; then
    printf 'STALL'; return 0
  fi
  printf 'BUILDING'
}

# ── Serialized healthcheck gate ────────────────────────────────────────────────────────────────
# WHY: every feature worktree shares ONE git object store and one .git/worktrees lock namespace, so
# two full healthcheck suites running at once race on shared git locks (empirically: concurrent
# suites trip `Unable to create '.../.git/gc.pid.lock': File exists — Another git process seems to
# be running`, which a solo run never hits). That race surfaced as a transient "❌ code error" for a
# clean PR (2026-07-02 ~12:14). Two independent guards make a red row mean VERIFIED-REAL:
#   (1) SERIALIZE — a per-repo mutex (HEALTH_CONCURRENCY, default 1, mirroring REVIEW_CONCURRENCY)
#       so the watcher never runs overlapping suites; a PR waiting on the slot shows
#       "health-check · queued" (visible, never mistaken for a hang).
#   (2) RETRY-BEFORE-RED — a healthcheck CODE ERROR (rc 1) is re-run ONCE immediately, solo, still
#       holding the mutex. Passes on retry → "flaky · infra (passed on retry)", proceed as passing.
#       Only a failure that REPRODUCES on the solo retry paints red. exit-code-2 data/env semantics
#       are unchanged (healthcheck.sh already collapses 2→rc 0, tolerated).
# The mutex uses live-pid inflight markers exactly like the review gate's concurrency accounting, so
# a crashed holder never wedges a slot.
# HERD_HEALTHCHECK_BIN is a test seam (mirrors HERD_REVIEW_BIN): the hermetic suite points it at a
# stub healthcheck with a scripted fail-then-pass / fail-then-fail sequence.
: "${HERD_HEALTHCHECK_BIN:="$HERE/healthcheck.sh"}"
_health_inflight_file() { printf '%s' "$TREES/.health-inflight-$1"; }

# _health_pid_live <inflight-file> — true if the marker records a still-running holder pid.
_health_pid_live() {
  local pid; pid="$(head -1 "$1" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# _count_live_healthchecks — number of inflight markers (across ALL PRs) whose holder pid is alive.
# Dead markers are not counted (a crashed holder never wedges a slot); mirrors _count_live_reviews.
_count_live_healthchecks() {
  local n=0 f
  for f in "$TREES"/.health-inflight-*; do
    [ -e "$f" ] || continue
    _health_pid_live "$f" && n=$((n+1))
  done
  printf '%s' "$n"
}

# _health_slot_free — true if a healthcheck slot is available under HEALTH_CONCURRENCY (default 1).
_health_slot_free() {
  [ "$(_count_live_healthchecks)" -lt "${HEALTH_CONCURRENCY:-1}" ]
}

# _health_acquire <pr#> — claim a slot by writing this process's live pid to the pr's marker.
_health_acquire() { printf '%s\n' "$$" > "$(_health_inflight_file "$1")"; }
# _health_release <pr#> — drop the pr's marker, freeing its slot.
_health_release() { rm -f "$(_health_inflight_file "$1")" 2>/dev/null || true; }

# record_healthcheck <pr#> <slug> <attempt> <outcome> — append one attempt to the ledger.
record_healthcheck() {
  printf '%s %s %s %s %s\n' "$(date +%s)" "$1" "$2" "$3" "$4" >> "$HEALTH_STATE"
  # Journal each attempt: attempt 1 is the initial run, attempt ≥2 is a solo retry-before-red.
  if [ "${3:-1}" -le 1 ] 2>/dev/null; then
    journal_append healthcheck_attempted pr "$1" slug "$2" attempt "$3" result "$4"
  else
    journal_append healthcheck_retried pr "$1" slug "$2" attempt "$3" result "$4"
  fi
}

# _healthcheck_gate <pr#> <slug> <worktree-dir> <display-idx> — the serialized, retry-before-red
# healthcheck. Sets DISPLAY[<idx>] and the global _HC_RESULT to one token; returns 0 always:
#   QUEUED    — no slot free (another suite holds the mutex); re-evaluate next tick, do NOT merge
#   CLEAN     — healthcheck passed (clean or tolerated data/env); proceed to the review/merge path
#   FLAKY     — first run was a CODE ERROR but the solo retry PASSED; proceed as passing
#   CODEERROR — CODE ERROR reproduced on the solo retry; red "needs you", do NOT merge
# Uses render() for the intermediate "health-check" / "retrying" frames, matching _handle_block_verdict.
_healthcheck_gate() {
  local _hg_pr="$1" _hg_slug="$2" _hg_dir="$3" _hg_idx="$4"
  local _hg_sl _hg_pn
  _hg_sl="$(printf '%-*s' "$SLUGW" "$_hg_slug")"
  _hg_pn=" ${C_DIM}#${_hg_pr}${C_RESET} ·"

  # SERIALIZE: no slot free → queue this PR and defer. Never runs a suite that would overlap.
  if ! _health_slot_free; then
    DISPLAY[_hg_idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_YELLOW}health-check · queued${C_RESET}"
    _HC_RESULT="QUEUED"
    return 0
  fi
  _health_acquire "$_hg_pr"

  DISPLAY[_hg_idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_YELLOW}health-check${C_RESET}"
  render
  local _hg_hc _hg_rc
  _hg_hc="$(bash "$HERD_HEALTHCHECK_BIN" "$_hg_dir" --oneline 2>/dev/null)"; _hg_rc=$?
  if [ "$_hg_rc" -eq 0 ]; then
    # Clean, or a tolerated data/env warning (healthcheck.sh already collapsed exit 2 → rc 0).
    case "$_hg_hc" in
      "⚠️"*) record_healthcheck "$_hg_pr" "$_hg_slug" 1 "dataenv" ;;
      *)     record_healthcheck "$_hg_pr" "$_hg_slug" 1 "clean" ;;
    esac
    _health_release "$_hg_pr"
    _HC_RESULT="CLEAN"
    journal_append healthcheck_outcome pr "$_hg_pr" slug "$_hg_slug" outcome CLEAN
    return 0
  fi

  # rc 1: a CODE ERROR. RETRY-BEFORE-RED: re-run ONCE, solo, still holding the mutex. A transient
  # from cross-worktree lock contention self-heals; only a reproducing failure is real.
  record_healthcheck "$_hg_pr" "$_hg_slug" 1 "code-error"
  DISPLAY[_hg_idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_YELLOW}health-check · code error — retrying once (solo)${C_RESET}"
  render
  local _hg_hc2 _hg_rc2
  _hg_hc2="$(bash "$HERD_HEALTHCHECK_BIN" "$_hg_dir" --oneline 2>/dev/null)"; _hg_rc2=$?
  if [ "$_hg_rc2" -eq 0 ]; then
    # Passed on the solo retry → the first failure was infra/contention, NOT a code bug. Never red.
    record_healthcheck "$_hg_pr" "$_hg_slug" 2 "flaky-pass"
    _health_release "$_hg_pr"
    DISPLAY[_hg_idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_YELLOW}flaky · infra (passed on retry)${C_RESET}"
    _HC_RESULT="FLAKY"
    journal_append healthcheck_outcome pr "$_hg_pr" slug "$_hg_slug" outcome FLAKY
    return 0
  fi
  # Reproduced on the solo retry → VERIFIED-REAL code error. Paint red.
  record_healthcheck "$_hg_pr" "$_hg_slug" 2 "code-error"
  _health_release "$_hg_pr"
  DISPLAY[_hg_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_RED}needs you · ${_hg_hc2}${C_RESET}"
  _HC_RESULT="CODEERROR"
  journal_append healthcheck_outcome pr "$_hg_pr" slug "$_hg_slug" outcome CODEERROR detail "$_hg_hc2"
  return 0
}

# Sourcing this file (e.g. from the hermetic test) loads the helper functions — including the pure
# merge-decision predicate _should_automerge — WITHOUT entering the live watch loop. Direct
# execution runs the loop normally.
if [ "${AGENT_WATCH_LIB:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

# ── Singleton spawn-lock: exactly one watcher per project ──────────────────────────────────────
# Keyed by WORKSPACE_NAME (matching the coordinator/scribe/researcher pattern). Prevents duplicate
# launchers from racing on 'gh pr merge' when the coordinator is relaunched. Stale locks (PID dead
# from a crashed/ended session) are reaped automatically so the next launch can take over.
#
# Two mechanisms, one per environment:
#   • flock(1) available  — non-blocking exclusive lock (fd 9) held for our lifetime; auto-released
#                           on any exit (fd close). A second watcher's flock -n fails immediately.
#   • no flock (macOS)    — atomic-mkdir mutex guards the check+write, then a PID file is held for
#                           our lifetime and removed on EXIT/INT/TERM.
mkdir -p "$(dirname "$HERD_WATCHER_LOCK")" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  exec 9>"$HERD_WATCHER_LOCK"
  if ! flock -n 9; then
    printf '🐑 watcher already running for %s — exiting.\n' "$WORKSPACE_NAME" >&2; exit 0
  fi
  printf '%s\n' "$$" >"$HERD_WATCHER_LOCK"   # informational PID for diagnostics
else
  # Atomic-mkdir mutex (serializes the check+write window; held only for that instant).
  _wl_mtx="${HERD_WATCHER_LOCK}.d"
  _wl_tries=0
  while ! mkdir "$_wl_mtx" 2>/dev/null; do
    [ -z "$(find "$_wl_mtx" -prune -mmin -1 2>/dev/null)" ] && { rmdir "$_wl_mtx" 2>/dev/null || true; continue; }
    _wl_tries=$((_wl_tries + 1)); [ "$_wl_tries" -ge 30 ] && break; sleep 0.1
  done
  _wl_pid="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
  if [ -n "$_wl_pid" ] && kill -0 "$_wl_pid" 2>/dev/null; then
    rmdir "$_wl_mtx" 2>/dev/null || true
    printf '🐑 watcher already running for %s (PID %s) — exiting.\n' "$WORKSPACE_NAME" "$_wl_pid" >&2; exit 0
  fi
  # Stale or absent lock: write our PID (temp+mv for atomicity so readers never see a partial write).
  _wl_tmp="${HERD_WATCHER_LOCK}.$$"
  printf '%s\n' "$$" >"$_wl_tmp"; mv "$_wl_tmp" "$HERD_WATCHER_LOCK"
  rmdir "$_wl_mtx" 2>/dev/null || true
  unset _wl_mtx _wl_tries _wl_pid _wl_tmp
  # Clean up the PID file on exit — but ONLY if it still contains our own PID.
  # If cmd_reload confirms us dead, removes our lock, and relaunches a new watcher,
  # the new watcher writes its PID before we exit; our EXIT trap must not clobber it.
  _watcher_lock_cleanup() {
    [ "$(cat "$HERD_WATCHER_LOCK" 2>/dev/null)" = "$$" ] \
      && rm -f "$HERD_WATCHER_LOCK" 2>/dev/null || true
  }
  trap '_watcher_lock_cleanup' EXIT
  trap '_watcher_lock_cleanup; exit 1' INT TERM
fi
# ───────────────────────────────────────────────────────────────────────────────────────────────

_ORPHAN_SWEEP_TICK=0
_ORPHAN_SWEEP_INTERVAL=15   # sweep every ~60 s (15 × 4 s sleep)

while true; do
  build_header
  build_landed

  PRS_JSON="$(gh pr list --json number,title,headRefName,mergeable,mergeStateStatus 2>/dev/null || echo '[]')"
  AGENTS_JSON="$(herdr agent list 2>/dev/null || echo '{}')"
  WT="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null || echo '')"

  # Parse worktrees + match each to its open PR and its agent, emitting one tab-separated record
  # per active feature worktree (the main checkout excluded).
  FEATS=()
  while IFS= read -r rec; do
    [ -n "$rec" ] && FEATS+=("$rec")
  done < <(PRS_JSON="$PRS_JSON" AGENTS_JSON="$AGENTS_JSON" WT="$WT" MAIN="$MAIN" python3 -c '
import os, json
MAIN = os.environ["MAIN"]
try: prs = json.loads(os.environ.get("PRS_JSON") or "[]")
except Exception: prs = []
try: agents = (json.loads(os.environ.get("AGENTS_JSON") or "{}").get("result") or {}).get("agents") or []
except Exception: agents = []
pr_by_branch = {p.get("headRefName"): p for p in prs}
ag_status = {a.get("name"): a.get("agent_status") for a in agents if a.get("name")}
feats = []; wt = None; branch = None
for line in (os.environ.get("WT") or "").splitlines():
    if line.startswith("worktree "): wt = line[9:]; branch = None
    elif line.startswith("branch "): branch = line[7:].replace("refs/heads/", "")
    elif line == "":
        if wt and wt != MAIN: feats.append((wt, branch))
        wt = None; branch = None
if wt and wt != MAIN: feats.append((wt, branch))
for wt, branch in feats:
    slug = os.path.basename(wt)
    pr = pr_by_branch.get(branch or "", {})
    print("\x1f".join(str(x) for x in [
        wt, slug, branch or "", pr.get("number", ""),
        pr.get("mergeable", ""), pr.get("mergeStateStatus", ""),
        ag_status.get(slug, "")]))
')

  # Classify each feature into a display line; collect merge candidates separately.
  DISPLAY=()
  CAND_IDX=(); CAND_DIR=(); CAND_SLUG=(); CAND_PR=(); CAND_BRANCH=()
  CONF_IDX=(); CONF_SLUG=(); CONF_PR=(); CONF_BRANCH=()
  i=0
  for rec in ${FEATS[@]+"${FEATS[@]}"}; do
    IFS=$'\037' read -r dir slug branch prnum mergeable mstate astatus <<EOF
$rec
EOF
    sl="$(printf '%-*s' "$SLUGW" "$slug")"
    pn=""; [ -n "$prnum" ] && pn=" ${C_DIM}#${prnum}${C_RESET} ·"
    if [ -z "$prnum" ]; then
      if [ "$astatus" != "working" ]; then
        DISPLAY[i]="    ${C_BLUE}🔨${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_BLUE}idle · no PR${C_RESET}"
      else
        # Agent is "working" with no PR yet. Walk the liveness ladder (see the "Builder liveness"
        # helpers) instead of the old commit-count heuristic, which false-flagged every normal
        # >5-min build because builders commit exactly ONCE at the very end. A fresh/edited or
        # transcript-growing worktree reads as building; only a clean, commitless, quiet tree
        # earns the warning.
        _quiet="$(_stall_quiet_secs)"
        _now="$(date +%s)"
        _newest_edit="$(_worktree_newest_edit "$dir")"
        if [ -n "$_newest_edit" ]; then _changes=1; _edit_age=$(( _now - _newest_edit )); else _changes=0; _edit_age=-1; fi
        _commits="$(git -C "$dir" rev-list HEAD --count --not "$DEFAULT_BRANCH" 2>/dev/null || echo 0)"
        _tgrow="$(_transcript_growing "$slug" "$(_transcript_obs "$dir")")"
        case "$(_classify_builder "$_edit_age" "$_changes" "${_commits:-0}" "$astatus" "$_tgrow" "$_quiet")" in
          BUILD_UNCOMMITTED)
            DISPLAY[i]="    ${C_BLUE}🔨${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_BLUE}building (uncommitted changes)${C_RESET}" ;;
          STALL)
            # "No activity" duration: nothing has been produced (zero commits) and the tree is
            # quiet, so the worktree's own age is the honest floor for how long it's been silent.
            _born="$(stat -f '%B' "$dir" 2>/dev/null || stat -c '%W' "$dir" 2>/dev/null || echo 0)"
            [ "${_born:-0}" -gt 0 ] || _born="$(file_mtime "$dir")"
            _qmins=$(( ( _now - _born ) / 60 ))
            DISPLAY[i]="    ${C_YELLOW}⚠️${C_RESET}  ${C_BOLD}${sl}${C_RESET} ${C_YELLOW}no activity ${_qmins}m · check pane${C_RESET}" ;;
          *)
            DISPLAY[i]="    ${C_BLUE}🔨${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_BLUE}building${C_RESET}" ;;
        esac
      fi
    elif [ "$dir" = "$SELF_WT" ]; then
      DISPLAY[i]="    ${C_DIM}🐑 ${sl} self · won't auto-merge${C_RESET}"
    elif [ "$mergeable" = "MERGEABLE" ] && _should_automerge "$mstate"; then
      DISPLAY[i]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}health-check${C_RESET}"
      CAND_IDX+=("$i"); CAND_DIR+=("$dir"); CAND_SLUG+=("$slug"); CAND_PR+=("$prnum"); CAND_BRANCH+=("$branch")
    elif [ "$mergeable" = "UNKNOWN" ] || [ "$mstate" = "UNKNOWN" ] || [ -z "$mergeable" ]; then
      DISPLAY[i]="    ${C_DIM}🔍${C_RESET} ${C_DIM}${sl}${C_RESET}${pn} ${C_DIM}verifying mergeability…${C_RESET}"
    elif [ "$mergeable" = "CONFLICTING" ]; then
      if resolver_attempted "$branch"; then
        DISPLAY[i]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · resolver failed${C_RESET}"
      else
        DISPLAY[i]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · conflict${C_RESET}"
        CONF_IDX+=("$i"); CONF_SLUG+=("$slug"); CONF_PR+=("$prnum"); CONF_BRANCH+=("$branch")
      fi
    elif [ "$mergeable" = "MERGEABLE" ]; then
      # MERGEABLE (no conflict) but mergeStateStatus != CLEAN: branch-protection gates aren't
      # satisfied yet — BLOCKED (required reviews/CODEOWNERS), BEHIND (out of date), or UNSTABLE
      # (pending/failing required checks). Do NOT merge; soft-hold and re-evaluate next tick. This
      # is transient, NOT a human-action error, so no ⚠️ "needs you".
      DISPLAY[i]="    ${C_YELLOW}⏸${C_RESET}  ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}blocked · awaiting required checks/reviews (${mstate:-?})${C_RESET}"
    else
      reason="not mergeable (${mstate})"
      DISPLAY[i]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · ${reason}${C_RESET}"
    fi
    i=$((i + 1))
  done

  render

  # Action pass: gate + auto-merge each CLEAN/MERGEABLE candidate.
  j=0
  for idx in ${CAND_IDX[@]+"${CAND_IDX[@]}"}; do
    dir="${CAND_DIR[j]}"; slug="${CAND_SLUG[j]}"; prnum="${CAND_PR[j]}"; branch="${CAND_BRANCH[j]}"; j=$((j + 1))
    already_merged "$prnum" "$slug" && continue
    sl="$(printf '%-*s' "$SLUGW" "$slug")"
    pn=" ${C_DIM}#${prnum}${C_RESET} ·"

    # SERIALIZED, retry-before-red healthcheck: never runs a suite that overlaps another (they
    # share one git object store and race on shared .git locks), and only paints red on a CODE
    # error that REPRODUCES on an immediate solo retry — a transient self-heals as "flaky · infra".
    _HC_RESULT=""
    _healthcheck_gate "$prnum" "$slug" "$dir" "$idx"
    render
    case "$_HC_RESULT" in
      CLEAN|FLAKY) : ;;            # passed (clean, tolerated data/env, or flaky-then-passed) → gate on
      QUEUED)      continue ;;     # slot busy — re-evaluate next tick, do NOT merge
      CODEERROR|*) continue ;;     # reproduced code error (red) — held for a human, do NOT merge
    esac

    if [ -n "$DRYRUN" ]; then
      DISPLAY[idx]="    ${C_DIM}🔬${C_RESET} ${C_DIM}${sl}${C_RESET}${pn} ${C_DIM}[dry-run] would review PR #${prnum} (then merge on PASS)${C_RESET}"
      render
      continue
    fi

    # Re-verify in the instant before merging — guard the window between classification and merge.
    IFS=$'\t' read -r rmergeable rmstate rbranch rsha < <(
      gh pr view "$prnum" --json mergeable,mergeStateStatus,headRefName,headRefOid 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("\t".join([str(d.get("mergeable","")), str(d.get("mergeStateStatus","")), str(d.get("headRefName","")), str(d.get("headRefOid",""))]))
')
    if [ "$rbranch" != "$branch" ]; then
      DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · PR #${prnum} no longer maps to ${branch}${C_RESET}"
      render
      continue
    fi
    if [ "$rmergeable" != "MERGEABLE" ] || ! _should_automerge "$rmstate"; then
      if [ "$rmergeable" = "MERGEABLE" ]; then
        # Still conflict-free but a gate regressed since classification (e.g. a required check went
        # pending, or the branch fell BEHIND): soft-hold, re-evaluate next tick — not a ⚠️.
        DISPLAY[idx]="    ${C_YELLOW}⏸${C_RESET}  ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}blocked · awaiting required checks/reviews (${rmstate:-?})${C_RESET}"
      else
        if [ "$rmergeable" = "CONFLICTING" ]; then rreason="conflict"; else rreason="${rmstate:-unknown}"; fi
        DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · changed under us · ${rreason}${C_RESET}"
      fi
      render
      continue
    fi

    # PRE-MERGE ADVERSARIAL REVIEW GATE. Keyed by PR + head sha so each commit is reviewed once.
    if [ -z "$rsha" ]; then
      DISPLAY[idx]="    ${C_DIM}🔬${C_RESET} ${C_DIM}${sl}${C_RESET}${pn} ${C_DIM}awaiting head sha for review…${C_RESET}"
      render
      continue
    fi
    prior="$(review_verdict "$prnum" "$rsha" || true)"
    if [ "$prior" = "BLOCK" ]; then
      if override_exists "$prnum" "$rsha"; then
        # Human override recorded for this sha — treat as PASS and proceed to merge path.
        prior="PASS"
      else
        _handle_block_verdict "$prnum" "$slug" "$rsha" "$idx"
        render
        continue
      fi
    fi
    if [ "$prior" != "PASS" ]; then
      # BACKGROUND review: advance the non-blocking state machine one step. Reviews for other
      # PRs run concurrently (bounded by REVIEW_CONCURRENCY) and merges keep flowing — a PR with
      # a cached PASS never waits behind someone else's in-flight review.
      step="$(_review_gate_step "$prnum" "$slug" "$rsha")"
      case "$step" in
        PASS) : ;;  # verdict just collected + recorded — fall through to the merge path
        BLOCK)
          _handle_block_verdict "$prnum" "$slug" "$rsha" "$idx"
          render
          continue ;;
        QUEUED)
          DISPLAY[idx]="    ${C_YELLOW}🔬${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}review queued · ${REVIEW_CONCURRENCY} in flight${C_RESET}"
          render
          continue ;;
        RETRY)
          # An INFRA death (EMPTY capture / rc0-no-verdict / severed reviewer) — NOT a refused
          # verdict. Say so plainly and show the bounded retry budget; never "reviewer blocked".
          _rv_k="$(_review_retry_count "$prnum" "$rsha")"
          DISPLAY[idx]="    ${C_YELLOW}🔬${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}review infra failed (no verdict) · retrying (${_rv_k}/${_REVIEW_RETRY_MAX})${C_RESET}"
          render
          continue ;;
        FAILED)
          DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · review infra failed ${_REVIEW_RETRY_MAX}× for this commit${C_RESET}"
          render
          continue ;;
        *)
          DISPLAY[idx]="    ${C_YELLOW}🔬${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}reviewing…${C_RESET}"
          render
          continue ;;
      esac
    fi
    # PASS (just now, or recorded for this sha) → proceed based on effective merge policy.

    if [ -n "$MERGE_OBSERVE" ]; then
      # observe: run all gates, report + notify once per sha, NEVER merge.
      if ! observe_noted "$prnum" "$rsha"; then
        record_observe_noted "$prnum" "$rsha"
        herdr notification show "🐑 PR #${prnum} ready (observe)" --body "${slug}: review passed — observe mode, not merging" --sound default >/dev/null 2>&1 || true
      fi
      DISPLAY[idx]="    ${C_GREEN}✅${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_GREEN}ready · observe mode${C_RESET}"
      render
      continue
    fi

    if [ -z "$AUTOMERGE" ]; then
      # approve: require explicit sha-keyed human approval before merging.
      if approval_is_approved "$prnum" "$rsha"; then
        DISPLAY[idx]="    ${C_YELLOW}⏳${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}merging (approved)${C_RESET}"
        render
        do_merge "$slug" "$prnum" "$dir" "$rsha"
        continue
      fi
      # First time gates pass for this sha: record + notify, then hold until approved.
      if ! approval_awaiting_noted "$prnum" "$rsha"; then
        record_approval_awaiting "$prnum" "$rsha"
        gh pr comment "$prnum" --body "🐑 **herd watch** · all gates passed (healthcheck ✅ · review ✅) · awaiting approval before merge.

Run \`herd approve ${prnum}\` (or \`bash scripts/herd/herd-approve.sh approve ${prnum}\`) to approve commit \`${rsha:0:8}\` for merge." >/dev/null 2>&1 || true
        herdr notification show "🐑 PR #${prnum} awaiting approval" --body "${slug}: gates passed — herd approve ${prnum}" --sound default >/dev/null 2>&1 || true
      fi
      DISPLAY[idx]="    ${C_GREEN}✅${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_GREEN}ready · awaiting approval${C_RESET}"
      render
      continue
    fi

    DISPLAY[idx]="    ${C_YELLOW}⏳${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}merging${C_RESET}"
    render
    do_merge "$slug" "$prnum" "$dir" "$rsha"
  done

  # Resolve pass: auto-spawn the isolated conflict resolver for each NEWLY-conflicting PR.
  k=0
  for idx in ${CONF_IDX[@]+"${CONF_IDX[@]}"}; do
    slug="${CONF_SLUG[k]}"; prnum="${CONF_PR[k]}"; branch="${CONF_BRANCH[k]}"; k=$((k + 1))
    sl="$(printf '%-*s' "$SLUGW" "$slug")"
    pn=" ${C_DIM}#${prnum}${C_RESET} ·"
    if [ -n "$DRYRUN" ]; then
      DISPLAY[idx]="    ${C_DIM}🔀${C_RESET} ${C_DIM}${sl}${C_RESET}${pn} ${C_DIM}[dry-run] would spawn resolver for PR #${prnum}${C_RESET}"
      render
      continue
    fi
    DISPLAY[idx]="    ${C_YELLOW}🔀${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}resolving conflict…${C_RESET}"
    render
    spawn_resolver "$slug" "$prnum" "$branch"
  done

  # Orphan sweep: every _ORPHAN_SWEEP_INTERVAL ticks close tabs whose slug is no longer live.
  _ORPHAN_SWEEP_TICK=$((_ORPHAN_SWEEP_TICK + 1))
  if [ "$_ORPHAN_SWEEP_TICK" -ge "$_ORPHAN_SWEEP_INTERVAL" ]; then
    _ORPHAN_SWEEP_TICK=0
    _sweep_orphan_tabs
  fi

  sleep 4
done
