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
# Launch-binding guard (issue #60): as a long-running console, require a REAL project config —
# refuse to silently inherit the engine's dogfood config via the rule-3 fallback (enforced inside
# herd-config.sh). Skipped in lib mode, where the hermetic tests source this file with their own
# stubbed HERD_CONFIG_FILE and must not be refused. Set BEFORE sourcing so the check sees it; a
# plain (unexported) var so it never leaks to spawned children, and re-set on each re-exec pass.
[ "${AGENT_WATCH_LIB:-}" = "1" ] || HERD_REQUIRE_PROJECT_CONFIG=1
. "$HERE/herd-config.sh"
# Engine journal — append-only forensic record of every gate event (best-effort, never breaks us).
. "$HERE/journal.sh"
# Token/cost accounting (additive + read-only): sums a merged builder's transcript and journals a
# `cost` event so `herd cost` can surface cost-per-merged-PR. Sourced after journal.sh (it calls
# journal_append). Defines functions only; safe to source in lib mode.
[ -f "$HERE/cost.sh" ] && . "$HERE/cost.sh"
# HUMAN-VERIFY parser — the shared convention for the per-PR human-verify hold (sourced, not run).
. "$HERE/human-verify.sh"
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
# Limit-resume ledger: one line per builder blocked on the ACCOUNT usage limit
# ("<slug> <detected-epoch> <resume-target-epoch> <state>", state ∈ scheduled | failed). The watcher
# surfaces a distinct "limit-hit · auto-resume at HH:MM" row (NOT a red/stall row) and, at the reset
# time + a small buffer, relaunches the builder IN PLACE via `claude --continue` (see _resume_builder
# / _handle_limit_blocked). The record is REMOVED (and its hook sentinel cleared) the instant a
# resume succeeds; a failed-after-retry attempt flips to `failed` and escalates without retrying.
LIMIT_STATE="$TREES/.agent-watch-limit"
# Reconcile ledger, PARALLEL to $STATE and the review/health ledgers: one line per POST-MERGE backlog
# auto-reconcile ENQUEUE ("<epoch> <pr#> <headSha> <slug>"). Keyed by PR *and* head sha (mirroring
# $REVIEW_STATE / $HEALTH_STATE) so the reconcile scribe request fires EXACTLY ONCE per merged PR: a
# watcher tick that re-enters the merge-success path for an already-reconciled PR (a retried merge, an
# autofix bounce that finally lands, a re-detected hand-off merge) reads this ledger and no-ops instead
# of re-enqueuing. Closes the drift where AUTOFIX / direct hand-off merges never reconciled the backlog.
RECONCILE_STATE="$TREES/.agent-watch-reconciled"
# Dep-state console surface: dep-watcher.sh rewrites this file each tick with one
# "<ref> <state> <age-seconds>" line per live blocked-on dep (state ∈ open|in-progress|in-review|
# stalled). Read-only here and purely informational — a blocked-on is a STATUS LINE, never a freeze,
# so a missing/stale file just means "no deps to show". Path mirrors dep-watcher's <lock-stem>.states.
DEP_STATES_FILE="${DEP_STATES_FILE:-${HERD_DEPWATCHER_LOCK%.pid}.states}"
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
BLOCKED=""
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

# _dep_state_style <state> — echo "<glyph>\t<color>" for a dep state. Keeps the palette mapping in
# one place so build_blocked stays a plain formatter. A stalled dep is the only loud (red) one — the
# rest are calm status colors, because a blocked-on is a status line, not an error.
_dep_state_style() {
  case "$1" in
    stalled)     printf '⏳\t%s' "$C_RED"    ;;
    in-review)   printf '👀\t%s' "$C_CYAN"   ;;
    in-progress) printf '🚧\t%s' "$C_YELLOW" ;;
    open|*)      printf '⛓\t%s'  "$C_DIM"    ;;
  esac
}

# build_blocked — the "blocked on" section: one row per live dep from $DEP_STATES_FILE
# ("<ref> <state> <age-seconds>", written by dep-watcher.sh). Empty (BLOCKED="") when there are no
# deps or the file is absent, so render omits the section entirely. Purely informational.
build_blocked() {
  BLOCKED=""
  [ -s "$DEP_STATES_FILE" ] || return 0
  local ref state age glyph color human rows=""
  while read -r ref state age; do
    [ -n "${ref:-}" ] || continue
    IFS=$'\t' read -r glyph color < <(_dep_state_style "$state")
    human="$(_fmt_age "${age:-0}")"
    rows="${rows}    ${color}${glyph}${C_RESET} ${C_BOLD}${ref}${C_RESET} ${color}${state}${C_RESET} ${C_DIM}${human}${C_RESET}"$'\n'
  done < "$DEP_STATES_FILE"
  [ -n "$rows" ] && BLOCKED="$rows"
}

# _fmt_age <seconds> — compact human age (e.g. 45s, 12m, 3h, 2d) for the blocked-on rows.
_fmt_age() {
  local s="${1:-0}"
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if   [ "$s" -lt 60 ];    then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ];  then printf '%sm' "$(( s / 60 ))"
  elif [ "$s" -lt 86400 ]; then printf '%sh' "$(( s / 3600 ))"
  else                          printf '%sd' "$(( s / 86400 ))"
  fi
}

# render — paint the whole rollup card, but ONLY when the computed frame changed.
render() {
  frame="${HDR_LINE}"$'\n'"${RULE}"$'\n\n'
  frame="${frame}  ${C_DIM}recently landed${C_RESET}"$'\n'"${LANDED}"$'\n'
  if [ -n "${BLOCKED:-}" ]; then
    frame="${frame}  ${C_DIM}blocked on${C_RESET}"$'\n'"${BLOCKED}"$'\n'
  fi
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
#
# LOCAL_REVIEW=pre-pr AND THIS POST-PR GATE (belt-and-suspenders — DELIBERATELY NOT SKIPPED):
# When LOCAL_REVIEW=pre-pr, the builder lanes (herd-quick.sh / herd-feature.sh) already ran
# `herd-review.sh --local <slug>` in the worktree and required a 'REVIEW: PASS' BEFORE opening the
# PR. It is TEMPTING to let a builder-stamped "locally-reviewed PASS @ <sha>" marker make this
# watcher-side gate TRUST/SKIP the review for that sha and save the second Opus pass. We intentionally
# do NOT do that: the local pre-PR review is best-effort and UNTRUSTED at the merge boundary — the
# PR head can differ from what was reviewed locally (a rebase/force-push/amend after the local pass,
# or an added commit), and a marker is builder-written so a buggy or confused builder could stamp a
# PASS that never really happened. Skipping a needed review to save tokens is exactly the
# silently-wrong failure mode this gate exists to prevent, so the post-PR review ALWAYS runs against
# the ACTUAL PR head sha regardless of any local pre-PR pass. The local review's value is catching a
# BLOCK earlier + cheaper (in the worktree, before the PR is public), NOT replacing this gate. If a
# trusted-skip optimization is ever wanted, it must first tie the marker to the exact PR head sha and
# authenticate it — correctness (never skip a needed review) beats the token saving.
: "${HERD_REVIEW_BIN:="$HERE/herd-review.sh"}"

_review_inflight_file() { printf '%s' "$TREES/.review-inflight-$1-$2"; }
_review_result_file()   { printf '%s' "$TREES/.review-result-$1-$2"; }
_review_tier_file()     { printf '%s' "$TREES/.review-tier-$1-$2"; }
# Evidence-triggered escalation arm marker, keyed per-PR (NOT per-sha): armed by _handle_block_verdict
# when a builder's refix rounds prove the cheap reviewer missed the issue, consumed once by the next
# review dispatch on that PR (see _maybe_arm_review_escalation / _review_gate_step).
_review_escalate_file() { printf '%s' "$TREES/.review-escalate-$1"; }

# ── Risk-tiered review classification (REVIEW_ESCALATE_GLOB) ─────────────────────────────────────
# _classify_review_tier <pr#> — echo the review tier for a PR's diff: STRONG | CHEAP | SKIP.
# Only ever called when REVIEW_ESCALATE_GLOB is set (the opt-in); with it empty the caller keeps
# today's always-$MODEL_REVIEW path and this never runs. Classification is DETERMINISTIC and fails
# SAFE — any uncertainty (unreadable/empty diff) → STRONG, never a downgrade:
#   • only *.md / tests/ paths changed                  → SKIP  (no reviewer; PASS recorded low-risk)
#   • any path matches REVIEW_ESCALATE_GLOB             → STRONG (engine surface)
#   • more than REVIEW_ESCALATE_MAXFILES files changed  → STRONG (large diff)
#   • otherwise (small, low-risk)                        → CHEAP  ($REVIEW_MODEL_CHEAP)
_classify_review_tier() {
  local pr="$1" paths n max
  # Changed-file paths for THIS PR's diff. Any failure/empty list → STRONG (never downgrade blind).
  paths="$(gh pr diff "$pr" --name-only 2>/dev/null | awk 'NF')"
  [ -n "$paths" ] || { printf STRONG; return 0; }
  # DOCS/TEST-ONLY: every changed path is a *.md doc or under tests/ — i.e. NO line fails to match
  # the docs/test pattern → skip the adversarial review entirely.
  if ! printf '%s\n' "$paths" | grep -qvE '(\.md$)|(^tests/)'; then printf SKIP; return 0; fi
  # Engine-surface glob match → full strong review.
  if printf '%s\n' "$paths" | grep -qE "$REVIEW_ESCALATE_GLOB"; then printf STRONG; return 0; fi
  # Large diff (many files) → strong even without a glob match.
  n="$(printf '%s\n' "$paths" | grep -c .)"
  max="${REVIEW_ESCALATE_MAXFILES:-10}"; case "$max" in ''|*[!0-9]*) max=10 ;; esac
  if [ "$n" -gt "$max" ] 2>/dev/null; then printf STRONG; return 0; fi
  # Small + low-risk → cheap reviewer tier.
  printf CHEAP
}

# _review_tier <pr#> <headSha> — the tier for this exact pr+sha, CACHED sha-keyed (mirroring the
# review-once ledger) so the `gh pr diff` classification runs at most ONCE per commit even while the
# review sits QUEUED behind the concurrency cap. The cache is cleaned on verdict collection and on
# stale-sha discard, exactly like the inflight/result markers.
_review_tier() {
  local pr="$1" sha="$2" cache tier
  cache="$(_review_tier_file "$pr" "$sha")"
  if [ -s "$cache" ]; then cat "$cache"; return 0; fi
  tier="$(_classify_review_tier "$pr")"
  printf '%s' "$tier" > "$cache" 2>/dev/null || true
  printf '%s' "$tier"
}

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
  for f in "$TREES/.review-result-$pr-"* "$TREES/.review-inflight-$pr-"* "$TREES/.review-tier-$pr-"*; do
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
  local pr="$1" slug="$2" sha="$3" model="${4:-}" result inflight
  result="$(_review_result_file "$pr" "$sha")"
  inflight="$(_review_inflight_file "$pr" "$sha")"
  [ -f "$result" ] && return 0
  [ -f "$inflight" ] && _review_pid_live "$inflight" && return 0
  # <model> is the risk-tier's chosen reviewer model. EMPTY means "use the default path" — do NOT
  # set HERD_REVIEW_MODEL, so herd-review.sh resolves $MODEL_REVIEW (and any operator-exported
  # HERD_REVIEW_MODEL override still wins) exactly as before tiering existed. A non-empty model
  # (the cheap tier) is passed through so the reviewer runs on that tier.
  if [ -n "$model" ]; then
    HERD_REVIEW_RESULT_FILE="$result" HERD_REVIEW_MODEL="$model" bash "$HERD_REVIEW_BIN" "$pr" "$slug" >/dev/null 2>&1 &
  else
    HERD_REVIEW_RESULT_FILE="$result" bash "$HERD_REVIEW_BIN" "$pr" "$slug" >/dev/null 2>&1 &
  fi
  local _dr_pid="$!"
  printf '%s\n' "$_dr_pid" > "$inflight"
  journal_append review_dispatched pr "$pr" sha "$sha" pid "$_dr_pid" \
    model "${model:-${HERD_REVIEW_MODEL:-${MODEL_REVIEW:-}}}" log_path "$result"
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
    rm -f "$result" "$inflight" "$(_review_tier_file "$pr" "$sha")" 2>/dev/null || true
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

  # RISK-TIERED review gate (opt-in via REVIEW_ESCALATE_GLOB). Default (glob empty) → the STRONG
  # tier with an EMPTY model, i.e. today's unchanged always-$MODEL_REVIEW path; no diff is classified
  # at all. When the glob is set, classify this pr+sha's diff ONCE (cached, sha-keyed) and either skip
  # the reviewer entirely (docs/test-only) or select the cheap vs strong model tier.
  local _rt_model=""
  if [ -n "${REVIEW_ESCALATE_GLOB:-}" ]; then
    local tier; tier="$(_review_tier "$pr" "$sha")"
    if [ "$tier" = "SKIP" ]; then
      # Docs/test-only diff: no reviewer is spawned. Record a sha-keyed PASS so it is never re-run,
      # with a clear provenance note (source=skipped-low-risk) distinct from a real reviewer PASS.
      # Decided BEFORE the concurrency gate — a skipped review consumes no reviewer slot, so it must
      # never queue behind in-flight reviews.
      record_review "$pr" "$sha" "PASS" "skipped-low-risk"
      rm -f "$(_review_tier_file "$pr" "$sha")" 2>/dev/null || true
      journal_append review_skipped pr "$pr" sha "$sha" reason "docs/test-only low-risk diff"
      echo PASS; return 0
    fi
    [ "$tier" = "CHEAP" ] && _rt_model="$REVIEW_MODEL_CHEAP"
  fi

  # EVIDENCE-TRIGGERED ESCALATION: if a builder's second refix round still arrived BLOCKed on this PR
  # (armed per-PR by _handle_block_verdict), the cheap reviewer has demonstrably missed the real issue
  # across two rounds. Force this NEXT dispatch up to the Opus tier ($REVIEW_MODEL_ESCALATED), overriding
  # whatever tier the risk classification chose — even the default/STRONG empty-model path. The arm is a
  # one-shot: it is CONSUMED here (reset), so a later clean commit's review is not needlessly escalated.
  local _esc_file _esc_armed=""
  _esc_file="$(_review_escalate_file "$pr")"
  if [ -f "$_esc_file" ]; then _esc_armed=1; _rt_model="${REVIEW_MODEL_ESCALATED:-claude-opus-4-8}"; fi

  # Consume the arm ONLY when actually dispatching (below) — a QUEUED tick must leave it armed so the
  # escalation still lands when a concurrency slot frees on a later tick.
  if [ "$(_count_live_reviews)" -ge "${REVIEW_CONCURRENCY:-2}" ]; then echo QUEUED; return 0; fi
  if [ -n "$_esc_armed" ]; then
    rm -f "$_esc_file" 2>/dev/null || true
    # (d) durable record of the review-lane step-up; the caller paints the '⬆️  escalated to …' row.
    journal_append review_escalated pr "$pr" sha "$sha" model "$_rt_model" \
      rounds "$(refix_round_count "$pr")" reason "cheap reviewer missed the issue across refix rounds"
    _dispatch_review "$pr" "$slug" "$sha" "$_rt_model"
    echo ESCALATED; return 0   # distinct from RUNNING so the console shows the Opus upgrade
  fi
  _dispatch_review "$pr" "$slug" "$sha" "$_rt_model"
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

# ── Per-PR human-verify hold ──────────────────────────────────────────────────────────────────
# A PR whose body declares a `HUMAN-VERIFY:` block (see human-verify.sh) names manual steps the
# builder could not run itself. Under MERGE_POLICY=auto such a PR is individually switched to an
# approve-style hold: every gate still runs, but the merge WAITS on a sha-keyed approval, REUSING
# the MERGE_POLICY=approve ledger ($APPROVALS) — no parallel ledger. Sibling PRs without the marker
# keep auto-merging. Under approve/observe the hold is redundant (those policies already gate every
# PR), so it is never applied there — avoiding any double-hold.

# _pr_body <pr#> — the PR's body text, or empty on any failure. Isolated so the hermetic tests can
# stub `gh pr view` and so the (potentially large) body is only fetched when the hold is relevant.
_pr_body() {
  gh pr view "$1" --json body -q '.body' 2>/dev/null || true
}

# pr_human_verify_held <pr#> — true iff the PR body declares a NON-EMPTY HUMAN-VERIFY block.
pr_human_verify_held() {
  _pr_body "$1" | human_verify_has
}

# pr_human_verify_steps <pr#> — print the PR's declared HUMAN-VERIFY steps, one per line.
pr_human_verify_steps() {
  _pr_body "$1" | human_verify_steps
}

# _hold_decision <mode> <hv_hold> <approved> — the pure action selector for a PASS-gated PR.
#   mode:     auto | approve | observe   (the effective merge policy)
#   hv_hold:  "1" if the PR declares a human-verify block (only ever set in auto mode), else ""
#   approved: "1" if a sha-keyed approval record exists for this PR+sha, else ""
# Echoes exactly one token: MERGE | HOLD | OBSERVE. No side effects — the caller owns the ledger
# writes, the journal, and the merge. In approve mode hv_hold is ignored (the policy already holds),
# so a human-verify PR is held exactly ONCE, never doubly.
_hold_decision() {
  local mode="$1" hv="$2" approved="$3"
  case "$mode" in
    observe) printf 'OBSERVE' ;;
    approve) [ -n "$approved" ] && printf 'MERGE' || printf 'HOLD' ;;
    auto)
      if [ -n "$hv" ]; then
        [ -n "$approved" ] && printf 'MERGE' || printf 'HOLD'
      else
        printf 'MERGE'
      fi ;;
    *) printf 'MERGE' ;;
  esac
}

# _hold_ready_label <hv_hold> <pr#> — the console phrase for a PASS-gated PR being held. A
# human-verify hold tells the operator exactly how to release it (and, via herd-approve.sh list,
# what to run first); a plain approve hold shows the generic wording.
_hold_ready_label() {
  if [ -n "$1" ]; then
    printf 'ready · human-verify pending · herd-approve.sh approve %s' "$2"
  else
    printf 'ready · awaiting approval'
  fi
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

# reconcile_enqueued <pr#> <headSha> — true if a POST-MERGE reconcile was already enqueued for this
# exact pr+sha. The idempotency guard for reconcile_backlog; mirrors refix_attempted / review_verdict.
reconcile_enqueued() {
  [ -s "$RECONCILE_STATE" ] || return 1
  awk -v p="$1" -v s="$2" '$2==p && $3==s{f=1} END{exit !f}' "$RECONCILE_STATE" 2>/dev/null
}

# record_reconcile <pr#> <headSha> <slug> — append one reconcile-enqueue record.
record_reconcile() {
  printf '%s %s %s %s\n' "$(date +%s)" "$1" "$2" "$3" >> "$RECONCILE_STATE"
}

# reconcile_backlog <pr#> <slug> <headSha> — the POST-MERGE auto-reconcile HOOK. Fires on EVERY
# successful merge (the normal auto-merge path, an autofix bounce that finally lands, and direct
# hand-off merges — all converge here in do_merge), enqueuing ONE scribe reconcile request keyed by
# the merged PR number + its branch slug. The scribe matches the 🔜/🚧 backlog item by 'worktree
# <slug>' OR the PR title (so items the coordinator never slug-tagged still reconcile — the drift the
# old slug-only reap missed) and marks it ✅ shipped; if none matches it no-ops. IDEMPOTENT: record
# FIRST against $RECONCILE_STATE (keyed by pr+sha, mirroring the review/health ledgers) so a re-run
# tick for the same merged PR reads the ledger and never re-enqueues, even if scribe.sh later dies.
# Best-effort — a failed enqueue never blocks the merge (the advisory sweep is the backstop).
reconcile_backlog() {
  local rb_pr="$1" rb_slug="$2" rb_sha="${3:-}"
  reconcile_enqueued "$rb_pr" "$rb_sha" && return 0
  record_reconcile "$rb_pr" "$rb_sha" "$rb_slug"
  bash "$HERE/scribe.sh" "Reconcile: PR #${rb_pr} (worktree ${rb_slug}) merged — find the 🔜/🚧 backlog item matching worktree ${rb_slug} or the PR title and mark it ✅ shipped (PR #${rb_pr}); if none matches, no-op." >/dev/null 2>&1 || true
  return 0
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
  # 0) COST ACCOUNTING (best-effort, read-only): sum this builder's worktree transcript and journal
  #    a `cost` event (builder — and the in-worktree review, if captured) BEFORE the worktree is
  #    reaped. Never affects the merge; a missing transcript / python3 just drops the event.
  type cost_emit_merge >/dev/null 2>&1 && cost_emit_merge "$dp" "$ds" "$dd"
  # 1) POST-MERGE auto-reconcile hook: enqueue exactly ONE idempotent scribe reconcile request keyed
  #    by PR# + slug (matches by 'worktree <slug>' OR PR title, so autofix / hand-off items that were
  #    never slug-tagged still reconcile — the drift the old slug-only reap missed).
  reconcile_backlog "$dp" "$ds" "$dsha"
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
# text sent there vanishes and the agent never wakes) REGARDLESS of whether the agent reads idle
# or 'done', and submits the re-task prompt via `herdr pane run` — command text + Enter, the one
# mechanism that actually SUBMITS the prompt (cf. the 'herdr agent send doesn't press Enter' gotcha).
# A 'done' builder's Claude TUI is still up and waiting, so this raw submit wakes it instantly, the
# same way a manual `herdr pane run <pane> <text>` does (issue #86). It then verifies agent_status
# flips to "working" over a BACKED-OFF poll window (several checks across ~HERD_REFIX_WAIT_TIMEOUT
# seconds, default 15, per attempt), re-sending once before giving up. On persistent failure it
# surfaces "needs you · auto-refix failed" on the row.
#
# HISTORY (issue #86): the bounce used to reserve 'done' builders for a `claude --continue` relaunch
# (_resume_builder), on the theory their session had ENDED. But a 'done' agent's TUI is still in the
# pane foreground, so the `cd … && claude --continue …` command line was typed into that TUI as
# literal prompt text and never re-tasked the agent — the bounce escalated woke=0 (journal:
# 'auto-refix wake woke=0 escalated=true (done → done)') even though a raw `herdr pane run` nudge
# wakes the exact same agent. The raw-prompt submit below is now the single wake path for idle AND
# done builders; _resume_builder remains for the limit-auto-resume scheduler (a truly-frozen session).
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

# _maybe_arm_review_escalation <pr#> — called right AFTER record_refix. If this PR has now accumulated
# at least REVIEW_EVIDENCE_ESCALATE_ROUNDS (default 2) failed refix rounds, the cheap reviewer's PASS
# has been proven wrong across two rounds — arm a one-shot Opus escalation for the PR's NEXT review
# dispatch. Reuses the shared refix-round accounting (refix_round_count) — no parallel counter.
_maybe_arm_review_escalation() {
  local _mare_pr="$1" _mare_rounds
  _mare_rounds="$(refix_round_count "$_mare_pr")"
  [ "${_mare_rounds:-0}" -ge "${REVIEW_EVIDENCE_ESCALATE_ROUNDS:-2}" ] 2>/dev/null || return 0
  : > "$(_review_escalate_file "$_mare_pr")" 2>/dev/null || true
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

# _wait_agent_working <slug> <window-s> — poll `herdr agent list` until the agent's status is
# "working" or the window expires, on a BACKED-OFF cadence: an immediate check, then 1s, 2s, 3s…
# capped at 5s between checks. Several spread-out checks across the window catch a builder that
# takes a few seconds to pick up a freshly-submitted prompt (issue #86 — the wake is not always
# instant) without hammering herdr every second for the full window. Returns 0 if it woke, 1 if not.
_wait_agent_working() {
  local _waw_slug="$1" _waw_window="$2" _waw_deadline _waw_int=1
  _waw_deadline=$(( $(date +%s) + _waw_window ))
  [ "$(_agent_status "$_waw_slug")" = "working" ] && return 0
  while [ "$(date +%s)" -lt "$_waw_deadline" ]; do
    sleep "$_waw_int"
    [ "$(_agent_status "$_waw_slug")" = "working" ] && return 0
    [ "$_waw_int" -lt 5 ] && _waw_int=$(( _waw_int + 1 ))
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
      # A 2nd+ failed refix round on this PR is evidence the cheap reviewer missed the real issue —
      # arm an Opus escalation for the PR's next review dispatch (consumed once, in _review_gate_step).
      _maybe_arm_review_escalation "$_hbv_pr"
      local _hbv_status_before
      _hbv_status_before="$(_agent_status "$_hbv_slug")"
      journal_append refix_bounce pr "$_hbv_pr" sha "$_hbv_sha" slug "$_hbv_slug" \
        round "$_hbv_round_num" agent_status_before "${_hbv_status_before:-unknown}"
      local _hbv_pane_id _hbv_woke=0 _hbv_escalated=false
      local _hbv_prompt
      _hbv_prompt="PR #${_hbv_pr} was review-blocked. Read the full review: gh pr view ${_hbv_pr}
Fix every issue the reviewer raised, run the healthcheck, push your fix, and reply to the review comment once done."
      # Target the builder's AGENT pane whether it reads idle OR 'done' (never a 'working' one) —
      # a 'done' builder's Claude TUI is still up and waiting, so submitting the raw re-task prompt
      # via `herdr pane run` (command text + Enter) wakes it exactly as a manual nudge does (issue
      # #86). This is the SINGLE wake path for both states; the old idle-only lookup + `--continue`
      # resume for 'done' builders never actually re-tasked them (woke=0 → escalated on every BLOCK).
      _hbv_pane_id="$(_find_builder_pane_id_any "$_hbv_slug")"
      if [ -n "$_hbv_pane_id" ]; then
        local _hbv_wait="${HERD_REFIX_WAIT_TIMEOUT:-15}"
        # Submit the prompt via the run/Enter path, then verify wake over a backed-off window; if the
        # first window expires, re-send once (in case pane run dropped the line) and verify again.
        herdr pane run "$_hbv_pane_id" "$_hbv_prompt" >/dev/null 2>&1 || true
        if _wait_agent_working "$_hbv_slug" "$_hbv_wait"; then
          _hbv_woke=1
        else
          herdr pane run "$_hbv_pane_id" "$_hbv_prompt" >/dev/null 2>&1 || true
          if _wait_agent_working "$_hbv_slug" "$_hbv_wait"; then
            _hbv_woke=1
          else
            DISPLAY[_hbv_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_RED}needs you · auto-refix failed · check pane${C_RESET}"
            _hbv_escalated=true
          fi
        fi
      else
        DISPLAY[_hbv_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_RED}needs you · auto-refix failed · agent pane not found${C_RESET}"
        _hbv_escalated=true
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

# ── Auto-resume a limit-blocked builder + shared resume-in-place helper ─────────────────────────
# Real incident (2026-07-02): a builder's Claude session froze on the ACCOUNT usage limit, ended
# ('done'), and typed `herdr pane run` nudges could NOT revive it — only a `claude --continue`
# relaunch IN THE WORKTREE preserves context and wakes it. The SAME dead-session gap breaks the
# auto-refix bounce when the target builder is already 'done'. One shared helper fixes both.

# _now — current epoch, overridable via HERD_NOW_EPOCH (a hermetic-test clock seam). New code uses
# this; the legacy `date +%s` call sites are intentionally left untouched to minimize churn.
_now() {
  if [ -n "${HERD_NOW_EPOCH:-}" ]; then printf '%s' "$HERD_NOW_EPOCH"; else date +%s; fi
}

# _shq <str> — single-quote a string for safe embedding in a shell command line (POSIX-safe: any
# embedded single quote becomes the '\'' escape). Used to build the `claude --continue` command.
_shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# _find_builder_pane_id_any <slug> — pane_id for the agent named <slug> REGARDLESS of idle/done/ended
# status, but NEVER a "working" one (resuming a live session would double-drive it). The resume path
# targets a builder whose session has ENDED, which the idle-only _find_builder_pane_id deliberately
# misses — and that idle-only miss is exactly why the 2026-07-02 refix bounce to a 'done' builder
# escalated woke=0. Prints the pane_id; prints nothing if absent or already working.
_find_builder_pane_id_any() {
  local _fpa_slug="$1"
  herdr agent list 2>/dev/null | SLUG="$_fpa_slug" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
  agents = (json.load(sys.stdin).get("result") or {}).get("agents") or []
  for a in agents:
    if a.get("name") == slug and a.get("agent_status") != "working":
      print(a.get("pane_id", ""), end="")
      break
except Exception:
  pass
' 2>/dev/null || true
}

# _resume_builder <slug> <worktree> <pane_id> [prompt] — relaunch a builder whose Claude session
# ENDED, IN PLACE, via `claude --continue` in its worktree (full context preserved), then VERIFY the
# agent flips to "working" within a bounded poll; retry ONCE. Returns 0 if it woke, 1 otherwise.
# The CALLER owns journaling, the console row, and the loud escalation on failure — this helper only
# performs + verifies the relaunch. [prompt] is the compose-turn text (default "continue"); the
# refix path passes its "fix the review" instructions so the resumed builder wakes straight onto the
# fix. SHARED by the auto-refix bounce (done builder) and the limit-auto-resume scheduler.
_resume_builder() {
  local _rb_slug="$1" _rb_wt="$2" _rb_pane="$3" _rb_prompt="${4:-continue}"
  [ -n "$_rb_pane" ] || return 1
  local _rb_flags="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"
  # cd into the worktree so `claude --continue` resumes THAT worktree's session even if the pane's
  # shell drifted; the explicit path also makes the invocation shape assertable in the hermetic tests.
  local _rb_cmd
  _rb_cmd="cd $(_shq "$_rb_wt") && claude $_rb_flags --continue $(_shq "$_rb_prompt")"
  local _rb_wait="${HERD_RESUME_WAIT_TIMEOUT:-${HERD_REFIX_WAIT_TIMEOUT:-15}}"
  herdr pane run "$_rb_pane" "$_rb_cmd" >/dev/null 2>&1 || true
  _wait_agent_working "$_rb_slug" "$_rb_wait" && return 0
  # Bounded retry once (re-send in case pane run dropped the line).
  herdr pane run "$_rb_pane" "$_rb_cmd" >/dev/null 2>&1 || true
  _wait_agent_working "$_rb_slug" "$_rb_wait"
}

# ── Limit-hit detection (hook sentinel — primary; banner scrape — fallback) ─────────────────────
# _limit_sentinel_file <worktree> — the rate_limit StopFailure hook writes here (see
# herd_write_ratelimit_hook in herd-config.sh). Its contents, when present, are the reset time from
# the banner (an epoch or raw "resets 7:30pm" text); an empty sentinel still counts as "limit hit".
_limit_sentinel_file() { printf '%s' "$1/.herd-limit-sentinel"; }

# _transcript_last_assistant_text <worktree> — text of the LAST assistant message across this
# worktree's Claude session transcript(s), or nothing. The banner-scrape fallback for environments
# without the hook. Reads the newest .jsonl (Claude appends one JSON object per line); tolerant of
# both the nested {"type":"assistant","message":{"content":[…]}} and flat {"role":…,"content":…}.
_transcript_last_assistant_text() {
  local wt="$1" root munged d newest=0 f m pick=""
  root="${HERD_TRANSCRIPT_ROOT:-$HOME/.claude/projects}"
  munged="$(printf '%s' "$wt" | tr '/.' '-')"
  d="$root/$munged"
  [ -d "$d" ] || return 0
  for f in "$d"/*.jsonl; do
    [ -f "$f" ] || continue
    m="$(file_mtime "$f")"; [ "${m:-0}" -gt "$newest" ] && { newest="$m"; pick="$f"; }
  done
  [ -n "$pick" ] || return 0
  python3 - "$pick" <<'PY' 2>/dev/null || true
import sys, json
last = ""
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if (o.get("role") or o.get("type")) != "assistant":
                continue
            msg = o.get("message", o)
            content = msg.get("content", "")
            if isinstance(content, list):
                txt = " ".join(c.get("text", "") for c in content if isinstance(c, dict))
            else:
                txt = str(content)
            if txt.strip():
                last = txt
except OSError:
    pass
sys.stdout.write(last)
PY
}

# _parse_reset_epoch <text> — extract a reset time from banner/sentinel text and return the NEXT
# occurrence as an epoch. Understands an already-numeric epoch, "resets 7:30pm", "7pm", "19:30".
# Echoes the epoch, or nothing when no time is found. Uses _now so the hermetic clock seam controls
# "which day"; timezone is local (matching how the banner time is displayed to the user).
_parse_reset_epoch() {
  local text="$1" now; now="$(_now)"
  HERD_RESET_TEXT="$text" HERD_RESET_NOW="$now" python3 - <<'PY' 2>/dev/null || true
import os, re, sys, datetime
text = os.environ.get("HERD_RESET_TEXT", "")
now = int(os.environ.get("HERD_RESET_NOW", "0") or 0)
m = re.fullmatch(r"\s*(\d{9,})\s*", text)      # an already-numeric epoch (hook may write one)
if m:
    sys.stdout.write(m.group(1)); sys.exit(0)
m = re.search(r"(\d{1,2})(?::(\d{2}))?\s*([ap]m)?", text, re.I)   # 7:30pm / 7pm / 19:30
if not m:
    sys.exit(0)
hh = int(m.group(1)); mm = int(m.group(2) or 0); ap = (m.group(3) or "").lower()
if ap == "pm" and hh != 12: hh += 12
if ap == "am" and hh == 12: hh = 0
if hh > 23 or mm > 59:
    sys.exit(0)
base = datetime.datetime.fromtimestamp(now)
cand = base.replace(hour=hh, minute=mm, second=0, microsecond=0)
if cand.timestamp() <= now:            # already passed today → the next day's occurrence
    cand += datetime.timedelta(days=1)
sys.stdout.write(str(int(cand.timestamp())))
PY
}

# _detect_limit_hit <slug> <worktree> — is this builder blocked on the account usage limit?
# Echoes the reset epoch (0 when the reset time is unknown) and returns 0 when a limit is detected;
# echoes nothing and returns 1 otherwise. Signal order:
#   1. HOOK SENTINEL (primary, robust): the rate_limit StopFailure hook wrote _limit_sentinel_file.
#   2. BANNER SCRAPE (fallback): the last assistant transcript line matches the usage-limit banner.
# HERD_LIMIT_DETECT=off disables detection entirely (feature kill-switch).
_detect_limit_hit() {
  local _dl_slug="$1" _dl_wt="$2" _dl_sent _dl_text _dl_reset=""
  [ "${HERD_LIMIT_DETECT:-on}" != "off" ] || return 1
  _dl_sent="$(_limit_sentinel_file "$_dl_wt")"
  if [ -f "$_dl_sent" ]; then
    _dl_text="$(cat "$_dl_sent" 2>/dev/null || true)"
    _dl_reset="$(_parse_reset_epoch "$_dl_text")"
    printf '%s' "${_dl_reset:-0}"; return 0
  fi
  _dl_text="$(_transcript_last_assistant_text "$_dl_wt")"
  if [ -n "$_dl_text" ] && printf '%s' "$_dl_text" | grep -qiE 'usage limit|session limit|hit your (usage|session) limit'; then
    _dl_reset="$(_parse_reset_epoch "$_dl_text")"
    printf '%s' "${_dl_reset:-0}"; return 0
  fi
  return 1
}

# ── Limit-resume ledger + scheduler ─────────────────────────────────────────────────────────────
# limit_state <slug> — recorded state (scheduled|failed), or empty when no active record.
limit_state() {
  [ -s "$LIMIT_STATE" ] || return 0
  awk -v s="$1" '$1==s{st=$4} END{if(st)print st}' "$LIMIT_STATE" 2>/dev/null || true
}
# limit_target_epoch <slug> — recorded resume-target epoch (0 if none).
limit_target_epoch() {
  [ -s "$LIMIT_STATE" ] || { printf '0'; return 0; }
  awk -v s="$1" '$1==s{r=$3} END{print (r==""?0:r)}' "$LIMIT_STATE" 2>/dev/null || printf '0'
}
# record_limit <slug> <detected> <target> <state> — upsert (drop any prior line for this slug first).
record_limit() {
  local _rl_tmp="${LIMIT_STATE}.$$"
  { [ -f "$LIMIT_STATE" ] && grep -v "^$1 " "$LIMIT_STATE" 2>/dev/null
    printf '%s %s %s %s\n' "$1" "$2" "$3" "$4"
  } > "$_rl_tmp" 2>/dev/null && mv "$_rl_tmp" "$LIMIT_STATE" 2>/dev/null || rm -f "$_rl_tmp" 2>/dev/null
}
# clear_limit <slug> [worktree] — drop the slug's record and (when a worktree is given) its sentinel.
clear_limit() {
  if [ -s "$LIMIT_STATE" ]; then
    local _cl_tmp="${LIMIT_STATE}.$$"
    grep -v "^$1 " "$LIMIT_STATE" 2>/dev/null > "$_cl_tmp"
    mv "$_cl_tmp" "$LIMIT_STATE" 2>/dev/null || rm -f "$_cl_tmp" 2>/dev/null
  fi
  [ -n "${2:-}" ] && rm -f "$(_limit_sentinel_file "$2")" 2>/dev/null || true
}
# _limit_buffer_secs — grace after the reset before relaunching (default 60s; HERD_LIMIT_RESUME_BUFFER).
_limit_buffer_secs() {
  case "${HERD_LIMIT_RESUME_BUFFER:-}" in
    ''|*[!0-9]*) printf '%s' 60 ;;
    *)           printf '%s' "$HERD_LIMIT_RESUME_BUFFER" ;;
  esac
}
# _limit_unknown_wait — how long to hold when the reset time can't be parsed (~5h rolling window;
# HERD_LIMIT_UNKNOWN_WAIT). Better to wait out one window than to hammer a still-blocked account.
_limit_unknown_wait() {
  case "${HERD_LIMIT_UNKNOWN_WAIT:-}" in
    ''|*[!0-9]*) printf '%s' 18000 ;;
    *)           printf '%s' "$HERD_LIMIT_UNKNOWN_WAIT" ;;
  esac
}
# _fmt_hhmm <epoch> — local "HH:MM" for a scheduled-resume epoch (best-effort; GNU/BSD date).
_fmt_hhmm() {
  local e="${1:-0}"
  [ "$e" -gt 0 ] 2>/dev/null || { printf '??:??'; return 0; }
  date -r "$e" +%H:%M 2>/dev/null || date -d "@$e" +%H:%M 2>/dev/null || printf '??:??'
}

# _handle_limit_blocked <slug> <worktree> <idx> <reset-epoch> — surface + schedule + (at the reset)
# perform the auto-resume for ONE limit-blocked builder. Sets DISPLAY[idx]. The row is a distinct,
# NON-RED "limit-hit · auto-resume at HH:MM" — a usage-limit pause is an expected account-wide event,
# not a code fault or a stall, so it must never read as a red alarm. Mirrors _handle_block_verdict's
# shape (record-before-act, journal both sides, escalate loudly on failure).
_handle_limit_blocked() {
  local _lb_slug="$1" _lb_wt="$2" _lb_idx="$3" _lb_reset="${4:-0}"
  local _lb_sl _lb_state _lb_now _lb_target
  _lb_sl="$(printf '%-*s' "$SLUGW" "$_lb_slug")"
  _lb_now="$(_now)"
  _lb_state="$(limit_state "$_lb_slug")"

  # First sighting → record + journal the hold and compute the resume target once.
  if [ -z "$_lb_state" ]; then
    if [ "$_lb_reset" -gt 0 ] 2>/dev/null; then
      _lb_target=$(( _lb_reset + $(_limit_buffer_secs) ))
    else
      _lb_target=$(( _lb_now + $(_limit_unknown_wait) ))
    fi
    record_limit "$_lb_slug" "$_lb_now" "$_lb_target" "scheduled"
    journal_append limit_detected slug "$_lb_slug" reset_at "$_lb_reset" resume_at "$_lb_target"
    journal_append limit_resume_scheduled slug "$_lb_slug" resume_at "$_lb_target"
    _lb_state="scheduled"
  fi

  # A prior failed attempt stays escalated — never re-attempt every tick.
  if [ "$_lb_state" = "failed" ]; then
    DISPLAY[_lb_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_RED}needs you · limit-resume failed · check pane${C_RESET}"
    return 0
  fi

  _lb_target="$(limit_target_epoch "$_lb_slug")"
  if [ "$_lb_now" -lt "$_lb_target" ] 2>/dev/null; then
    # Waiting for the reset: distinct cyan hold row (NOT a red/stall row).
    DISPLAY[_lb_idx]="    ${C_CYAN}⏳${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_CYAN}limit-hit · auto-resume at $(_fmt_hhmm "$_lb_target")${C_RESET}"
    return 0
  fi

  # Reset reached (+buffer) → resume in place now.
  DISPLAY[_lb_idx]="    ${C_CYAN}↻${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_CYAN}limit reset · resuming via --continue…${C_RESET}"
  render
  local _lb_pane
  _lb_pane="$(_find_builder_pane_id_any "$_lb_slug")"
  journal_append limit_resume_attempt slug "$_lb_slug" pane "${_lb_pane:-none}" target "$_lb_target"
  if [ -n "$_lb_pane" ] && _resume_builder "$_lb_slug" "$_lb_wt" "$_lb_pane"; then
    journal_append limit_resume_result slug "$_lb_slug" woke 1 escalated false
    clear_limit "$_lb_slug" "$_lb_wt"
    DISPLAY[_lb_idx]="    ${C_GREEN}↻${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_GREEN}resumed via --continue${C_RESET}"
  else
    record_limit "$_lb_slug" "$_lb_now" "$_lb_target" "failed"
    journal_append limit_resume_result slug "$_lb_slug" woke 0 escalated true
    DISPLAY[_lb_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_RED}needs you · limit-resume failed · check pane${C_RESET}"
  fi
  return 0
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

# _worktree_born <worktree> — echo the worktree's creation epoch: birth time where the platform's
# stat exposes it (macOS `stat -f %B`, GNU `stat -c %W`), else the directory mtime as a floor.
# This is the quiet-floor for a builder that has produced no dirty files yet — nothing can be
# "stalled" before its own tree even existed, so a young worktree reads as building, not stalled.
_worktree_born() {
  local wt="$1" b
  b="$(stat -f '%B' "$wt" 2>/dev/null || stat -c '%W' "$wt" 2>/dev/null || echo 0)"
  [ "${b:-0}" -gt 0 ] || b="$(file_mtime "$wt")"
  printf '%s' "${b:-0}"
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

# _transcript_growing <slug> <obs> <now> <quiet> — decide whether this builder's Claude transcript
# has grown recently enough to count as alive. <obs> is this poll's "<bytes> <mtime>" (from
# _transcript_obs); <now> is the current epoch and <quiet> the stall window (seconds). Echoes:
#   "yes"     — the transcript grew within the last <quiet> seconds (this poll OR a recent earlier
#               one) ⇒ alive, rescues a would-be stall
#   "no"      — a prior observation exists but the transcript has not grown inside the window
#   "unknown" — no transcript at all, or no prior observation to compare against
# WINDOW, NOT ADJACENT-POLL: Claude flushes the session transcript in bursts, so two consecutive
# polls that land in a pause read byte-identical. Comparing only the immediately-adjacent poll made
# such a pause momentarily look flat ("no") → a one-tick false STALL → the next poll grew again →
# BUILDING (the flap). We instead track a per-slug last-grew epoch in $TRANSCRIPT_STATE, updated
# whenever bytes/mtime increase and carried forward across flat polls, and treat the builder as
# alive if that epoch is within <quiet>. The one-way-veto property is preserved: this only ever
# returns "yes" (rescue) or "no"; it never fabricates a stall — that stays the caller's job.
# Cache line format is "<slug> <bytes> <mtime> <last-grew-epoch>"; a legacy 3-field line (no epoch)
# is read tolerantly (missing epoch ⇒ treated as "not recently grown" until the next real growth).
_transcript_growing() {
  local slug="$1" obs="$2" now="${3:-0}" quiet="${4:-0}"
  local prev cur_size cur_mt prev_size prev_mt prev_grew lastgrew tmp
  [ -n "$obs" ] || { printf 'unknown'; return 0; }
  cur_size="${obs%% *}"; cur_mt="${obs##* }"
  prev=""
  [ -f "$TRANSCRIPT_STATE" ] && prev="$(awk -v s="$slug" '$1==s{print $2, $3, $4}' "$TRANSCRIPT_STATE" 2>/dev/null | tail -1)"
  prev_size=""; prev_mt=""; prev_grew=""
  if [ -n "$prev" ]; then
    read -r prev_size prev_mt prev_grew <<EOF
$prev
EOF
  fi
  # Update the last-grew epoch: stamp <now> when this poll grew, else carry the prior epoch forward.
  if [ -n "$prev" ] && { [ "${cur_size:-0}" -gt "${prev_size:-0}" ] || [ "${cur_mt:-0}" -gt "${prev_mt:-0}" ]; }; then
    lastgrew="$now"
  else
    lastgrew="${prev_grew:-}"
  fi
  # Rewrite the cache: drop any prior line for this slug, append fresh obs + last-grew epoch (temp+mv).
  tmp="${TRANSCRIPT_STATE}.$$"
  { [ -f "$TRANSCRIPT_STATE" ] && grep -v "^${slug} " "$TRANSCRIPT_STATE" 2>/dev/null
    printf '%s %s %s %s\n' "$slug" "$cur_size" "$cur_mt" "${lastgrew:-}"
  } > "$tmp" 2>/dev/null && mv "$tmp" "$TRANSCRIPT_STATE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  [ -n "$prev" ] || { printf 'unknown'; return 0; }
  # Alive iff it grew inside the window. Guard the arithmetic against a missing/legacy epoch.
  if [ -n "$lastgrew" ] && [ "$(( now - lastgrew ))" -le "$quiet" ]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# _classify_builder <edit-age> <has-changes> <commits> <agent-status> <transcript-growing> <quiet>
#   <quiet-elapsed> — the pure verdict for a working, PR-less builder. Echoes exactly one token:
#   BUILD_UNCOMMITTED — fresh uncommitted edits (actively coding right now)
#   BUILDING          — heads-down (working + edits, transcript growing, has commits, or still
#                       inside its quiet floor — e.g. a just-born tree that hasn't produced yet)
#   STALL             — clean/quiet tree, zero commits, flat transcript, AND quiet for the full
#                       window ⇒ show the "no activity" warning
# <edit-age> is seconds since the newest dirty-file edit, or -1 when the tree has no dirty files.
# <quiet-elapsed> is how long the tree has ACTUALLY been observably quiet: seconds since the newest
# dirty edit when there are changes, else the worktree AGE (seconds since it was born) when nothing
# has been produced yet. A commitless builder is NOT called STALL until <quiet-elapsed> ≥ <quiet>;
# this is what keeps a brand-new, dirty-file-free worktree (agent still reading) from being flagged
# "no activity 0m" at cold start.
_classify_builder() {
  local age="$1" changes="$2" commits="$3" status="$4" tgrow="$5" quiet="$6" qelapsed="${7:-0}"
  # 1. fresh uncommitted edits ⇒ actively coding right now.
  if [ "$changes" -eq 1 ] && [ "$age" -ge 0 ] && [ "$age" -lt "$quiet" ]; then
    printf 'BUILD_UNCOMMITTED'; return 0
  fi
  # 2. a *working* agent with ANY worktree edits (even stale) is heads-down, never stalled.
  if [ "$status" = "working" ] && [ "$changes" -eq 1 ]; then
    printf 'BUILDING'; return 0
  fi
  # 3. transcript still growing (within the quiet window) ⇒ alive (one-way veto — only rescues).
  if [ "$tgrow" = "yes" ]; then
    printf 'BUILDING'; return 0
  fi
  # 4. quiet tree: a commitless build earns the warning ONLY once it has actually been quiet for the
  #    full window. A tree still inside its quiet floor (young worktree with nothing produced, or an
  #    edit within the window) is just starting up — building, not stalled.
  if [ "${commits:-0}" -eq 0 ]; then
    if [ "${qelapsed:-0}" -ge "$quiet" ]; then
      printf 'STALL'; return 0
    fi
    printf 'BUILDING'; return 0
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

# ── Sha-keyed healthcheck result cache (mirrors the review gate's .review-result-<pr>-<sha>) ──────
# WHY: a held/awaiting-verify/awaiting-approval PR sits on the candidate list every ~90s tick with an
# UNCHANGED head sha, yet the gate re-ran the FULL suite each tick (PR #65, 2026-07-02: ~8 full runs
# in 12 min for one commit — one tick even MANUFACTURED its own transient code-error→flaky-pass). The
# sha did not change, so the verdict cannot change. Cache the TERMINAL verdict keyed by pr+headSha,
# exactly as the review gate caches its PASS/BLOCK, and REUSE it while the sha is unchanged.
#   .health-result-<pr>-<sha>  — one line "<verdict>\t<detail>", verdict ∈ CLEAN | FLAKY | CODEERROR,
#                                written when _healthcheck_gate reaches a terminal outcome for this
#                                exact commit sha. A cached CLEAN/FLAKY proceeds as passing; a cached
#                                CODEERROR keeps surfacing the red row — both WITHOUT re-running.
# A new commit (new sha) invalidates the cache and forces a fresh full run (see _discard_stale_health,
# mirroring _discard_stale_reviews). A non-terminal/in-flight state is NEVER cached.
_health_result_file() { printf '%s' "$TREES/.health-result-$1-$2"; }

# record_health_result <pr#> <sha> <verdict> [detail] — cache a TERMINAL health verdict for this exact
# commit sha. No-op when sha is empty (cache disabled; e.g. head sha not yet known).
record_health_result() {
  [ -n "$2" ] || return 0
  printf '%s\t%s\n' "$3" "${4:-}" > "$(_health_result_file "$1" "$2")"
}

# _discard_stale_health <pr#> <currentSha> — a cached result for this PR keyed to ANY OTHER sha is
# stale (the PR has a newer head; that verdict must never be reused). Discard it so the new commit
# re-runs the full suite. Mirrors _discard_stale_reviews (result markers only — the health mutex
# marker is keyed by pr alone and released synchronously within the gate, so it is never stale).
_discard_stale_health() {
  local pr="$1" sha="$2" f base
  for f in "$TREES/.health-result-$pr-"*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "${base##*-}" = "$sha" ] && continue
    rm -f "$f" 2>/dev/null || true
  done
}

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

# _healthcheck_gate <pr#> <slug> <worktree-dir> <display-idx> [headSha] — the serialized,
# retry-before-red healthcheck. Sets DISPLAY[<idx>] and the global _HC_RESULT to one token; returns
# 0 always:
#   QUEUED    — no slot free (another suite holds the mutex); re-evaluate next tick, do NOT merge
#   CLEAN     — healthcheck passed (clean or tolerated data/env); proceed to the review/merge path
#   FLAKY     — first run was a CODE ERROR but the solo retry PASSED; proceed as passing
#   CODEERROR — CODE ERROR reproduced on the solo retry; red "needs you", do NOT merge
# When [headSha] is given, the TERMINAL verdict is sha-cached: a later tick with the SAME sha REUSES
# it (skipping the suite entirely), and a new commit invalidates it. An empty/absent sha disables the
# cache (every call runs the suite — the pre-cache behavior).
# Uses render() for the intermediate "health-check" / "retrying" frames, matching _handle_block_verdict.
_healthcheck_gate() {
  local _hg_pr="$1" _hg_slug="$2" _hg_dir="$3" _hg_idx="$4" _hg_sha="${5:-}"
  local _hg_sl _hg_pn
  _hg_sl="$(printf '%-*s' "$SLUGW" "$_hg_slug")"
  _hg_pn=" ${C_DIM}#${_hg_pr}${C_RESET} ·"

  # SHA-CACHE CHECK (before any suite work): an UNCHANGED commit cannot yield a different verdict.
  # Purge any result for a stale sha (a new commit → full re-run), then REUSE a terminal result
  # cached for this exact head sha — no mutex, no suite, no fresh ledger attempt; just a journal
  # 'cache hit' so 'herd why' shows a reused result. Mirrors the review gate's sha-keyed reuse.
  if [ -n "$_hg_sha" ]; then
    _discard_stale_health "$_hg_pr" "$_hg_sha"
    local _hg_cache _hg_cv _hg_cd
    _hg_cache="$(_health_result_file "$_hg_pr" "$_hg_sha")"
    if [ -f "$_hg_cache" ]; then
      IFS=$'\t' read -r _hg_cv _hg_cd < "$_hg_cache"
      case "$_hg_cv" in
        CLEAN)
          _HC_RESULT="CLEAN"
          journal_append healthcheck_cache_hit pr "$_hg_pr" slug "$_hg_slug" sha "$_hg_sha" outcome CLEAN
          return 0 ;;
        FLAKY)
          DISPLAY[_hg_idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_YELLOW}flaky · infra (passed on retry)${C_RESET}"
          _HC_RESULT="FLAKY"
          journal_append healthcheck_cache_hit pr "$_hg_pr" slug "$_hg_slug" sha "$_hg_sha" outcome FLAKY
          return 0 ;;
        CODEERROR)
          DISPLAY[_hg_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_RED}needs you · ${_hg_cd}${C_RESET}"
          _HC_RESULT="CODEERROR"
          journal_append healthcheck_cache_hit pr "$_hg_pr" slug "$_hg_slug" sha "$_hg_sha" outcome CODEERROR detail "$_hg_cd"
          return 0 ;;
      esac
    fi
  fi

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
    record_health_result "$_hg_pr" "$_hg_sha" "CLEAN"
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
    record_health_result "$_hg_pr" "$_hg_sha" "FLAKY"
    DISPLAY[_hg_idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_YELLOW}flaky · infra (passed on retry)${C_RESET}"
    _HC_RESULT="FLAKY"
    journal_append healthcheck_outcome pr "$_hg_pr" slug "$_hg_slug" outcome FLAKY
    return 0
  fi
  # Reproduced on the solo retry → VERIFIED-REAL code error. Paint red.
  record_healthcheck "$_hg_pr" "$_hg_slug" 2 "code-error"
  _health_release "$_hg_pr"
  # A tab-leak-guard CODEERROR is INFRA/TRANSIENT, not a code bug (issue #78 part 2): a concurrent
  # SAME-workspace sibling builder tab flickering non-idle during the healthcheck window can trip the
  # guard on BOTH the initial run and the solo retry, yet self-heals the moment that tab stabilizes
  # (its own comment promises 'self-heals on re-run'). Like INFRA-FAIL / exit-2 results, it must NEVER
  # be sha-cached — else the sha-cache (PR #66) replays the transient every tick and FREEZES red until
  # a human deletes the marker. Skip the cache write so the next tick re-runs the suite fresh and
  # self-heals; a genuine non-tab-leak code error still gets cached and stays red without re-running.
  case "$_hg_hc2" in
    *tab-leak-guard*) : ;;   # transient — do NOT persist to the sha cache (re-runs next tick)
    *)                record_health_result "$_hg_pr" "$_hg_sha" "CODEERROR" "$_hg_hc2" ;;
  esac
  DISPLAY[_hg_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_RED}needs you · ${_hg_hc2}${C_RESET}"
  _HC_RESULT="CODEERROR"
  journal_append healthcheck_outcome pr "$_hg_pr" slug "$_hg_slug" outcome CODEERROR detail "$_hg_hc2"
  return 0
}

# ── Watcher views: lenses + filters ─────────────────────────────────────────────────────────────
# A "view" narrows WHICH open PRs the watcher SELECTS to display and act on each tick. It is a
# read-time SELECTION filter only: it NEVER changes the auto-merge safety semantics. A PR the lens
# hides is simply not considered this tick; a PR the lens shows still passes every existing gate
# (healthcheck + pre-merge review + re-verify) before anything merges. Narrowing the set can never
# cause a blind-merge — that team/multi-user concern is a separate backlog item this only plumbs for.
#
# DEFAULT = today's exact behavior: WATCHER_VIEW unset (or "all") AND no filters set is a
# byte-identical passthrough — the base `gh pr list` fields are requested and every open PR flows
# through untouched, so an existing install with no new config key behaves identically.
#
# Config keys (.herd/config):
#   WATCHER_VIEW            lens: all (default) | mine | deps | review-queue
#   WATCHER_VIEW_AUTHOR     filter: only PRs authored by this login (also the identity for `mine`)
#   WATCHER_VIEW_ASSIGNEE   filter: only PRs assigned to this login
#   WATCHER_VIEW_LABEL      filter: only PRs carrying this label
#   WATCHER_VIEW_STATUS     filter: only PRs whose mergeStateStatus equals this (e.g. CLEAN, BLOCKED)
#   WATCHER_VIEW_DEPS_LABEL label marking a dependency PR for the `deps` lens (default: dependencies)
# Filters AND together and compose with the lens. An unknown lens falls back to `all` + a loud warn.

# Base fields the classifier consumes — UNCHANGED, so the default gh call is identical to before.
_WATCHER_VIEW_BASE_FIELDS="number,title,headRefName,headRefOid,mergeable,mergeStateStatus"
# Extra fields needed ONLY to evaluate a lens/filter; requested only when a view is active.
_WATCHER_VIEW_EXTRA_FIELDS="author,assignees,labels,reviewDecision"

_watcher_view_lens() { printf '%s' "${WATCHER_VIEW:-all}"; }

# Active = anything other than the default (all lens, no filters). Drives whether we fetch the extra
# gh fields and run the filter at all, keeping the default path byte-for-byte the same as before.
_watcher_view_active() {
  case "$(_watcher_view_lens)" in
    all|"") ;;
    *) return 0 ;;
  esac
  [ -n "${WATCHER_VIEW_AUTHOR:-}" ]   && return 0
  [ -n "${WATCHER_VIEW_ASSIGNEE:-}" ] && return 0
  [ -n "${WATCHER_VIEW_LABEL:-}" ]    && return 0
  [ -n "${WATCHER_VIEW_STATUS:-}" ]   && return 0
  return 1
}

# The --json field list for `gh pr list`: the unchanged base set by default; the extended set only
# when a view is active (so a lens/filter has the data it needs to evaluate).
_watcher_view_fields() {
  if _watcher_view_active; then
    printf '%s,%s' "$_WATCHER_VIEW_BASE_FIELDS" "$_WATCHER_VIEW_EXTRA_FIELDS"
  else
    printf '%s' "$_WATCHER_VIEW_BASE_FIELDS"
  fi
}

# Loud but deduped warning for a misconfiguration (once per distinct value per process lifetime, so
# the 4s poll loop never spams the pane). Deduped via a marker file under $TREES.
_watcher_view_warn_once() {
  _wvw_msg="$1"; _wvw_key="$2"
  _wvw_f="${TREES:-${TMPDIR:-/tmp}}/.agent-watch-view-warned"
  [ "$(cat "$_wvw_f" 2>/dev/null)" = "$_wvw_key" ] && return 0
  printf '%s\n' "$_wvw_key" >"$_wvw_f" 2>/dev/null || true
  printf '⚠️  %s\n' "$_wvw_msg" >&2
}

# Read the PRS JSON on stdin, emit the SELECTED subset as JSON on stdout. Passthrough (exact bytes)
# when no view is active. Never breaks the pipeline: malformed input degrades to an empty list.
_watcher_view_filter() {
  if ! _watcher_view_active; then cat; return 0; fi
  _wvf_lens="$(_watcher_view_lens)"
  _wvf_author="${WATCHER_VIEW_AUTHOR:-}"
  # Validate the lens from shell so the warning fires deterministically (testable) and independently
  # of python. An unknown lens degrades to `all` — it still shows every PR, never fewer-by-accident.
  case "$_wvf_lens" in
    all|mine|deps|review-queue) ;;
    *)
      _watcher_view_warn_once "WATCHER_VIEW: unknown lens '$_wvf_lens' — falling back to 'all'" "lens:$_wvf_lens"
      _wvf_lens="all" ;;
  esac
  # `mine` needs an identity: prefer the configured author, else resolve the gh user; if neither is
  # available, fall back to `all` (loud) rather than silently hiding every PR.
  if [ "$_wvf_lens" = "mine" ] && [ -z "$_wvf_author" ]; then
    _wvf_author="$(gh api user -q .login 2>/dev/null || true)"
    if [ -z "$_wvf_author" ]; then
      _watcher_view_warn_once "WATCHER_VIEW=mine but no WATCHER_VIEW_AUTHOR set and gh user unresolved — falling back to 'all'" "mine:noauthor"
      _wvf_lens="all"
    fi
  fi
  WV_LENS="$_wvf_lens" \
  WV_AUTHOR="$_wvf_author" \
  WV_ASSIGNEE="${WATCHER_VIEW_ASSIGNEE:-}" \
  WV_LABEL="${WATCHER_VIEW_LABEL:-}" \
  WV_STATUS="${WATCHER_VIEW_STATUS:-}" \
  WV_DEPS_LABEL="${WATCHER_VIEW_DEPS_LABEL:-dependencies}" \
  python3 -c '
import os, sys, json
try:
    prs = json.loads(sys.stdin.read() or "[]")
    if not isinstance(prs, list): raise ValueError
except Exception:
    # Malformed input: emit an empty list rather than crash the tick.
    print("[]"); sys.exit(0)
lens       = os.environ.get("WV_LENS", "all")
author     = os.environ.get("WV_AUTHOR", "")
assignee   = os.environ.get("WV_ASSIGNEE", "")
label      = os.environ.get("WV_LABEL", "")
status     = os.environ.get("WV_STATUS", "")
deps_label = os.environ.get("WV_DEPS_LABEL", "dependencies")

def login(d):
    return d.get("login", "") if isinstance(d, dict) else ""
def has_label(pr, name):
    return any((l or {}).get("name") == name for l in (pr.get("labels") or []))
def assignee_logins(pr):
    return [login(a) for a in (pr.get("assignees") or [])]

def keep(pr):
    # Lens narrowing.
    if lens == "mine":
        if not author or login(pr.get("author")) != author: return False
    elif lens == "review-queue":
        # GitHub'"'"'s canonical "awaiting review" state.
        if (pr.get("reviewDecision") or "") != "REVIEW_REQUIRED": return False
    elif lens == "deps":
        if not has_label(pr, deps_label): return False
    # Explicit filters (AND). `mine` already applied the author, so skip the duplicate here.
    if author and lens != "mine" and login(pr.get("author")) != author: return False
    if assignee and assignee not in assignee_logins(pr): return False
    if label and not has_label(pr, label): return False
    if status and (pr.get("mergeStateStatus") or "") != status: return False
    return True

print(json.dumps([p for p in prs if keep(p)]))
'
}

# ── Multi-user / team mode: STRICT ownership gate for auto-merge (SAFETY-CRITICAL) ───────────────
# WATCHER_SCOPE selects WHICH PRs the watcher may AUTO-MERGE. It is a NARROWING gate layered on top
# of the watcher-view lens above: like the lens it can only ever WITHHOLD a merge, never authorize
# one the existing gates (healthcheck + pre-merge review + re-verify) would otherwise deny.
#   mine  (DEFAULT) — today's exact SOLO behavior: auto-merge the operator's own PRs. A solo install
#                     only ever sees its own local-worktree PRs, so the ownership probe stays DORMANT
#                     and behavior is byte-identical to before this change.
#   all             — team mode: teammates' PRs are DISPLAYED, but auto-merge is STRICTLY scoped to
#                     PRs OWNED by the configured operator. A teammate's PR is surfaced as
#                     "not mine — manual" and is NEVER auto-merged, even when MERGEABLE+CLEAN+approved.
# NB: WATCHER_SCOPE is intentionally NOT yet documented in capabilities.tsv — that doc entry is a
# deliberate follow-up (another builder owns capabilities.tsv this wave); read here with an inline
# default so a config without the key behaves exactly as the solo default.
_watcher_scope() {
  case "${WATCHER_SCOPE:-mine}" in
    mine|all) printf '%s' "${WATCHER_SCOPE:-mine}" ;;
    *)
      _watcher_view_warn_once "WATCHER_SCOPE: unknown value '${WATCHER_SCOPE:-}' — falling back to safe default 'mine'" "scope:${WATCHER_SCOPE:-}"
      printf 'mine' ;;
  esac
}

# team mode = scope 'all'. In team mode the ownership gate is armed; in the default 'mine' scope it
# is dormant (byte-identical to today's solo watcher).
_watcher_team_mode() { [ "$(_watcher_scope)" = "all" ]; }

# The configured OPERATOR IDENTITY that owns auto-merge. Resolution order:
#   WATCHER_OWNER (explicit) → WATCHER_VIEW_AUTHOR (reuse the lens identity) → `gh api user`.
# Resolved AT MOST ONCE per process and memoized in a GLOBAL — the 4s poll loop must never spawn a gh
# probe every tick. _resolve_watcher_owner MUST be called directly (never via `$()`), or a subshell
# would discard the memo; _watcher_owner_login is the read-only accessor. Test seam: setting
# WATCHER_OWNER (or WATCHER_VIEW_AUTHOR) resolves the identity with no gh call at all.
_WATCHER_OWNER_CACHE=""
_WATCHER_OWNER_RESOLVED=""
_resolve_watcher_owner() {
  [ -n "$_WATCHER_OWNER_RESOLVED" ] && return 0
  if   [ -n "${WATCHER_OWNER:-}" ];       then _WATCHER_OWNER_CACHE="$WATCHER_OWNER"
  elif [ -n "${WATCHER_VIEW_AUTHOR:-}" ]; then _WATCHER_OWNER_CACHE="$WATCHER_VIEW_AUTHOR"
  else _WATCHER_OWNER_CACHE="$(gh api user -q .login 2>/dev/null || true)"; fi
  _WATCHER_OWNER_RESOLVED=1
}
_watcher_owner_login() { _resolve_watcher_owner; printf '%s' "$_WATCHER_OWNER_CACHE"; }

# _scope_permits_automerge <pr_author_login> — the SAFETY-CRITICAL scope gate. Returns 0 (scope
# PERMITS auto-merge) / non-zero (scope FORBIDS it — display only, a human merges it). Called DIRECTLY
# (never in a subshell) so its owner resolution memoizes into the parent shell across ticks.
#   • scope=mine (default): ALWAYS permits — preserves today's exact solo behavior. No ownership
#     probe runs; every local-worktree candidate is by construction the operator's own PR.
#   • scope=all (team mode): permits ONLY when <pr_author_login> equals the resolved operator
#     identity. FAIL-CLOSED — an empty/unknown author, or an unresolvable operator identity, FORBIDS
#     the merge: a teammate's PR must never be blind-merged just because we couldn't confirm ownership.
_scope_permits_automerge() {
  _spa_author="${1:-}"
  _watcher_team_mode || return 0            # solo default → unchanged behavior, no ownership probe
  _resolve_watcher_owner
  if [ -z "$_WATCHER_OWNER_CACHE" ]; then
    _watcher_view_warn_once "WATCHER_SCOPE=all but the operator identity is unresolved (set WATCHER_OWNER) — auto-merge WITHHELD for safety" "scope:noowner"
    return 1                               # fail-closed: cannot confirm ownership → never merge
  fi
  [ -n "$_spa_author" ] && [ "$_spa_author" = "$_WATCHER_OWNER_CACHE" ]
}

# The --json fields for the tick's `gh pr list`. In team mode we additionally need each PR's `author`
# to enforce the ownership gate even when NO view lens is active; fold it in (deduped). In the default
# solo scope this is exactly _watcher_view_fields — the base set — so the default gh call is unchanged.
_watcher_tick_fields() {
  _wtf="$(_watcher_view_fields)"
  if _watcher_team_mode; then
    case ",$_wtf," in *,author,*) ;; *) _wtf="${_wtf},author" ;; esac
  fi
  printf '%s' "$_wtf"
}

# Sourcing this file (e.g. from the hermetic test) loads the helper functions — including the pure
# merge-decision predicate _should_automerge and the watcher-view selectors above — WITHOUT entering
# the live watch loop. Direct execution runs the loop normally.
if [ "${AGENT_WATCH_LIB:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

# ── Per-workspace argv0 marker: make this watcher ATTRIBUTABLE in ps/pgrep (issue #60) ──────────
# Re-exec ONCE under a distinctive per-workspace argv0 ($HERD_WATCH_ARGV0, e.g. herd-watch-<slug>)
# so the process table shows which workspace this watcher serves. Without it, two projects' watchers
# are indistinguishable in ps (`bash .../agent-watch.sh`) and a good-faith "kill the duplicate
# watcher" in project A can SIGTERM project B's live watcher. argv0 is visible via ps/pgrep on every
# platform; an env-var marker is NOT reliably readable via ps on modern macOS — which is why the
# marker is argv0. _list_project_watchers (bin/herd) reaps ONLY processes whose argv0 equals this
# exact string. Every launch site (coordinator.sh, cmd_reload's pane-run + background fallback,
# herd pane watch, herd-watch.sh) ultimately runs agent-watch.sh, so this single re-exec tags them
# all. The guard env var makes it a one-shot (no infinite re-exec loop); $0/BASH_SOURCE stay the
# script path so HERE still resolves after the re-exec.
if [ "${HERD_WATCH_REEXEC:-}" != "1" ]; then
  export HERD_WATCH_REEXEC=1
  exec -a "$HERD_WATCH_ARGV0" bash "$HERE/agent-watch.sh" "$@"
fi

# ── Launch-binding banner + foreign-cwd guard (issue #60) ───────────────────────────────────────
# Print the resolved WORKSPACE_NAME/PROJECT_ROOT and refuse to run from outside PROJECT_ROOT (unless
# HERD_ALLOW_FOREIGN_CWD=1). Placed AFTER the argv0 re-exec so it prints exactly once, in the final
# tagged process. The config-source refusal (herd-config.sh) already fired on the first pass if the
# config was engine-dogfood-only; this catches the complementary case — a real config but a $PWD
# that is not inside the project it resolves to.
herd_console_guard "herd watch" || exit 1

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
  build_blocked

  # Fetch open PRs, then apply the configured watcher view (lens + filters). The view is a
  # read-time SELECTION filter only — it narrows which PRs this tick displays/considers and never
  # relaxes any merge gate. Default (all lens, no filters) requests the base fields and passes the
  # JSON through unchanged, preserving today's exact behavior.
  PRS_JSON="$(gh pr list --json "$(_watcher_tick_fields)" 2>/dev/null || echo '[]')"
  PRS_JSON="$(printf '%s' "$PRS_JSON" | _watcher_view_filter)"
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
        ag_status.get(slug, ""), pr.get("headRefOid", ""),
        (pr.get("author") or {}).get("login", "")]))
')

  # Classify each feature into a display line; collect merge candidates separately.
  DISPLAY=()
  CAND_IDX=(); CAND_DIR=(); CAND_SLUG=(); CAND_PR=(); CAND_BRANCH=(); CAND_SHA=()
  CONF_IDX=(); CONF_SLUG=(); CONF_PR=(); CONF_BRANCH=()
  i=0
  for rec in ${FEATS[@]+"${FEATS[@]}"}; do
    IFS=$'\037' read -r dir slug branch prnum mergeable mstate astatus headsha prauthor <<EOF
$rec
EOF
    sl="$(printf '%-*s' "$SLUGW" "$slug")"
    pn=""; [ -n "$prnum" ] && pn=" ${C_DIM}#${prnum}${C_RESET} ·"
    if [ -z "$prnum" ]; then
      if [ "$astatus" != "working" ]; then
        # A non-working, PR-less builder is USUALLY just idle waiting for a task. But it may instead
        # be frozen on the ACCOUNT usage limit — its session ended and no typed nudge can revive it
        # (2026-07-02 incident). Detect that (hook sentinel → banner-scrape fallback) and, if so,
        # surface a distinct hold row + schedule an in-place `claude --continue` resume at the reset;
        # otherwise it is the benign "idle · no PR". An existing record keeps the row (and the
        # scheduled resume) alive across ticks even after the transient signal clears.
        if _lim_reset="$(_detect_limit_hit "$slug" "$dir")"; then _lim_hit=1; else _lim_hit=0; fi
        if [ "$_lim_hit" = "1" ] || [ -n "$(limit_state "$slug")" ]; then
          _handle_limit_blocked "$slug" "$dir" "$i" "${_lim_reset:-0}"
        else
          DISPLAY[i]="    ${C_BLUE}🔨${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_BLUE}idle · no PR${C_RESET}"
        fi
      else
        # A working agent means any earlier limit hold has cleared (a human intervened, or the
        # scheduled resume flipped it working) — drop a stale limit record + sentinel, then classify.
        [ -n "$(limit_state "$slug")" ] && clear_limit "$slug" "$dir"
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
        _tgrow="$(_transcript_growing "$slug" "$(_transcript_obs "$dir")" "$_now" "$_quiet")"
        # How long the tree has ACTUALLY been quiet: since the newest dirty edit if any, else since
        # the worktree was born (nothing produced yet). This is both the STALL floor and, if it does
        # stall, the honest "no activity" age.
        _born="$(_worktree_born "$dir")"
        if [ "$_changes" -eq 1 ]; then _qelapsed="$_edit_age"; else _qelapsed=$(( _now - _born )); fi
        case "$(_classify_builder "$_edit_age" "$_changes" "${_commits:-0}" "$astatus" "$_tgrow" "$_quiet" "$_qelapsed")" in
          BUILD_UNCOMMITTED)
            DISPLAY[i]="    ${C_BLUE}🔨${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_BLUE}building (uncommitted changes)${C_RESET}" ;;
          STALL)
            # Reached only when _qelapsed ≥ _quiet, so this age is a real, ≥-window duration.
            _qmins=$(( _qelapsed / 60 ))
            DISPLAY[i]="    ${C_YELLOW}⚠️${C_RESET}  ${C_BOLD}${sl}${C_RESET} ${C_YELLOW}no activity ${_qmins}m · check pane${C_RESET}" ;;
          *)
            DISPLAY[i]="    ${C_BLUE}🔨${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_BLUE}building${C_RESET}" ;;
        esac
      fi
    elif [ "$dir" = "$SELF_WT" ]; then
      DISPLAY[i]="    ${C_DIM}🐑 ${sl} self · won't auto-merge${C_RESET}"
    elif [ "$mergeable" = "MERGEABLE" ] && _should_automerge "$mstate"; then
      if _scope_permits_automerge "$prauthor"; then
        DISPLAY[i]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}health-check${C_RESET}"
        CAND_IDX+=("$i"); CAND_DIR+=("$dir"); CAND_SLUG+=("$slug"); CAND_PR+=("$prnum"); CAND_BRANCH+=("$branch"); CAND_SHA+=("$headsha")
      else
        # Team mode (WATCHER_SCOPE=all): this PR is MERGEABLE+CLEAN and would auto-merge in solo mode,
        # but it is NOT owned by the configured operator. DISPLAY it so a teammate's progress is
        # visible, but NEVER add it to the merge-candidate set — a human merges a teammate's PR.
        DISPLAY[i]="    ${C_DIM}👥${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_DIM}not mine — manual (@${prauthor:-unknown})${C_RESET}"
      fi
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
    dir="${CAND_DIR[j]}"; slug="${CAND_SLUG[j]}"; prnum="${CAND_PR[j]}"; branch="${CAND_BRANCH[j]}"; candsha="${CAND_SHA[j]}"; j=$((j + 1))
    already_merged "$prnum" "$slug" && continue
    sl="$(printf '%-*s' "$SLUGW" "$slug")"
    pn=" ${C_DIM}#${prnum}${C_RESET} ·"

    # SERIALIZED, retry-before-red healthcheck: never runs a suite that overlaps another (they
    # share one git object store and race on shared .git locks), and only paints red on a CODE
    # error that REPRODUCES on an immediate solo retry — a transient self-heals as "flaky · infra".
    # sha-keyed: an UNCHANGED commit reuses the cached terminal verdict (no re-run); a new commit
    # invalidates the cache and re-runs the full suite. This ends the every-tick re-run of a held PR.
    _HC_RESULT=""
    _healthcheck_gate "$prnum" "$slug" "$dir" "$idx" "$candsha"
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
    IFS=$'\t' read -r rmergeable rmstate rbranch rsha rauthor < <(
      gh pr view "$prnum" --json mergeable,mergeStateStatus,headRefName,headRefOid,author 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("\t".join([str(d.get("mergeable","")), str(d.get("mergeStateStatus","")), str(d.get("headRefName","")), str(d.get("headRefOid","")), str((d.get("author") or {}).get("login",""))]))
')
    if [ "$rbranch" != "$branch" ]; then
      DISPLAY[idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · PR #${prnum} no longer maps to ${branch}${C_RESET}"
      render
      continue
    fi
    # SAFETY-CRITICAL defense-in-depth: re-confirm ownership on FRESH author data in the instant
    # before merging. Even if a teammate's PR reached this candidate path (a classification race, or
    # an author that resolved only just now), the scope gate blocks the auto-merge here — never
    # blind-merge a PR the operator does not own.
    if ! _scope_permits_automerge "$rauthor"; then
      DISPLAY[idx]="    ${C_DIM}👥${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_DIM}not mine — manual (@${rauthor:-unknown})${C_RESET}"
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
        ESCALATED)
          # (d) The review gate just stepped up to Opus on evidence (a failed refix round proved the
          # cheap reviewer wrong). Mirror the builder lanes' '⬆️  escalated to $MODEL' step-up on the
          # REVIEW lane so the console shows the upgrade — reviewing continues as normal underneath.
          DISPLAY[idx]="    ${C_YELLOW}🔬${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}reviewing… ⬆️  escalated to ${REVIEW_MODEL_ESCALATED:-claude-opus-4-8} ($(refix_round_count "$prnum") failed refix rounds)${C_RESET}"
          render
          continue ;;
        *)
          DISPLAY[idx]="    ${C_YELLOW}🔬${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}reviewing…${C_RESET}"
          render
          continue ;;
      esac
    fi
    # PASS (just now, or recorded for this sha) → proceed based on the effective merge policy AND,
    # in auto mode, whether this specific PR declares a HUMAN-VERIFY block (which converts it to an
    # approve-style hold on top of auto). The parse only runs in auto mode (a body fetch per PASS
    # candidate) — approve/observe already hold every PR, so the marker is moot there.
    mode="auto"; [ -z "$AUTOMERGE" ] && mode="approve"; [ -n "$MERGE_OBSERVE" ] && mode="observe"
    hv_hold=""
    if [ "$mode" = "auto" ] && pr_human_verify_held "$prnum"; then hv_hold=1; fi
    hold_kind="approve"; [ -n "$hv_hold" ] && hold_kind="human-verify"
    # A hold is in effect when the policy holds (approve) OR this PR is human-verify-held.
    held=""; { [ "$mode" = "approve" ] || [ -n "$hv_hold" ]; } && held=1
    approved=""; approval_is_approved "$prnum" "$rsha" && approved=1

    case "$(_hold_decision "$mode" "$hv_hold" "$approved")" in
      OBSERVE)
        # observe: run all gates, report + notify once per sha, NEVER merge.
        if ! observe_noted "$prnum" "$rsha"; then
          record_observe_noted "$prnum" "$rsha"
          herdr notification show "🐑 PR #${prnum} ready (observe)" --body "${slug}: review passed — observe mode, not merging" --sound default >/dev/null 2>&1 || true
        fi
        DISPLAY[idx]="    ${C_GREEN}✅${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_GREEN}ready · observe mode${C_RESET}"
        render
        continue ;;

      HOLD)
        # First time gates pass for this sha: record the awaiting entry (reusing the approve
        # ledger), journal the hold, and post a comment + notification. Sha-keyed, so a new commit
        # (new sha) records a fresh awaiting entry — re-holding the PR until the new sha is approved.
        if ! approval_awaiting_noted "$prnum" "$rsha"; then
          record_approval_awaiting "$prnum" "$rsha"
          journal_append hold_applied pr "$prnum" sha "$rsha" slug "$slug" kind "$hold_kind"
          if [ -n "$hv_hold" ]; then
            hv_steps="$(pr_human_verify_steps "$prnum")"
            gh pr comment "$prnum" --body "🐑 **herd watch** · all gates passed (healthcheck ✅ · review ✅) — but this PR declares manual steps that must be **human-verified** before merge:

${hv_steps}

Once verified, run \`herd approve ${prnum}\` (or \`bash scripts/herd/herd-approve.sh approve ${prnum}\`) to approve commit \`${rsha:0:8}\` for merge. A new commit re-holds until re-verified." >/dev/null 2>&1 || true
            herdr notification show "🐑 PR #${prnum} human-verify pending" --body "${slug}: gates passed — verify manual steps, then herd approve ${prnum}" --sound default >/dev/null 2>&1 || true
          else
            gh pr comment "$prnum" --body "🐑 **herd watch** · all gates passed (healthcheck ✅ · review ✅) · awaiting approval before merge.

Run \`herd approve ${prnum}\` (or \`bash scripts/herd/herd-approve.sh approve ${prnum}\`) to approve commit \`${rsha:0:8}\` for merge." >/dev/null 2>&1 || true
            herdr notification show "🐑 PR #${prnum} awaiting approval" --body "${slug}: gates passed — herd approve ${prnum}" --sound default >/dev/null 2>&1 || true
          fi
        fi
        DISPLAY[idx]="    ${C_GREEN}✅${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_GREEN}$(_hold_ready_label "$hv_hold" "$prnum")${C_RESET}"
        render
        continue ;;

      MERGE)
        if [ -n "$held" ]; then
          # A held PR (approve policy, or a human-verify hold) that now has a sha-keyed approval.
          journal_append hold_released pr "$prnum" sha "$rsha" slug "$slug" kind "$hold_kind" reason approved
          if [ -n "$hv_hold" ]; then
            DISPLAY[idx]="    ${C_YELLOW}⏳${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}merging (human-verified)${C_RESET}"
          else
            DISPLAY[idx]="    ${C_YELLOW}⏳${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}merging (approved)${C_RESET}"
          fi
        else
          DISPLAY[idx]="    ${C_YELLOW}⏳${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}merging${C_RESET}"
        fi
        render
        do_merge "$slug" "$prnum" "$dir" "$rsha"
        continue ;;
    esac
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
