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
# Runtime driver shim — binds each runtime-specific control-surface capability (list-agents,
# read-pane, send-keys, notifications, start-agent) to the active HERD_DRIVER. Makes the watcher's
# load-bearing core run with NO herdr panes under HERD_DRIVER=headless (panes-as-a-view); the default
# herdr-claude driver delegates to the exact same herdr commands. Defines functions only; lib-safe.
. "$HERE/driver.sh"
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
# Dead-builder ledger for the pre-PR liveness reconciliation: one line per active worktree slug that
# is currently exhibiting the DEAD signature — worktree present, NO live agent in `herdr agent list`,
# NO open PR, no recent transcript growth. Format "<slug> <first-seen-epoch> <state>", state ∈
# pending | notified. <first-seen-epoch> is when the watcher FIRST observed the signature; the slug is
# only surfaced as 💀 DEAD once it has PERSISTED past a grace window (so a just-spawned builder whose
# agent has not registered yet, or a one-tick blip in `herdr agent list`, is never falsely reaped).
# Any liveness signal (agent reappears, PR opens, transcript grows) clears the record. See the
# "Dead-builder detection" helpers below.
DEAD_STATE="$TREES/.agent-watch-dead"
# Dead-builder AUTO-RESPAWN ledger, PARALLEL to $DEAD_STATE and keyed by SLUG (NOT cleared when the
# dead record clears): one line per slug the watcher has auto-respawned — "<slug> <epoch> <state>",
# state ∈ respawned | escalated. This is the AT-MOST-ONCE budget: a slug with a `respawned` line is
# never auto-respawned again, so a builder that dies a SECOND time after its one respawn escalates
# instead of looping. Only written when DEAD_BUILDER_AUTORESPAWN is opted in (byte-inert when off).
# See the "Dead-builder AUTO-RESPAWN" helpers below.
DEAD_RESPAWN_STATE="$TREES/.agent-watch-respawn"
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
# Clean-menu-select ledger, PARALLEL to $LIMIT_STATE and keyed by SLUG: one line per limit-parked
# session the watcher has tried to resume the CLEAN way — by sending the limit menu's "Stop and wait
# for limit to reset" keystrokes via `herdr pane send-keys` so Claude's NATIVE wait-and-auto-resume
# takes over (see _try_clean_limit_menu_select). Format "<slug> <epoch> <state>", state ∈
# cleared | fallback. cleared = the menu was confirmed GONE after the keystrokes (native resume owns
# the wait); fallback = the send-keys select could not clear the menu within a bounded couple of
# attempts, so the EXISTING scheduled `claude --continue` backstop (below) still runs. This is a
# per-park DEDUP so the keystrokes are attempted AT MOST ONCE per park (not re-sent every ~4s tick);
# it NEVER gates the backstop off — the backstop always remains, so worst case is today's behavior.
# Kept SEPARATE from $LIMIT_STATE so that ledger's format/semantics stay untouched.
SENDKEYS_STATE="$TREES/.agent-watch-limit-sendkeys"
# Reconcile ledger, PARALLEL to $STATE and the review/health ledgers: one line per POST-MERGE backlog
# auto-reconcile ENQUEUE ("<epoch> <pr#> <headSha> <slug>"). Keyed by PR *and* head sha (mirroring
# $REVIEW_STATE / $HEALTH_STATE) so the reconcile scribe request fires EXACTLY ONCE per merged PR: a
# watcher tick that re-enters the merge-success path for an already-reconciled PR (a retried merge, an
# autofix bounce that finally lands, a re-detected hand-off merge) reads this ledger and no-ops instead
# of re-enqueuing. Closes the drift where AUTOFIX / direct hand-off merges never reconciled the backlog.
RECONCILE_STATE="$TREES/.agent-watch-reconciled"
# Tracker-state self-heal surfaces (HERD-86). The periodic tracker-state sweep (tracker-state-sweep.sh)
# re-asserts Done for a recently-merged PR whose tracker item drifted (stuck open after merge — the
# HERD-67/HERD-69 incidents). TRACKER_SWEEP_LEDGER records refs already confirmed Done so the sweep
# never re-reads a clean ref (steady-state cost = one `gh pr list`, zero backend reads). The heal
# NOTE surface holds one "<epoch> <status> <ref> <pr> <found-state>" line per heal action (status ∈
# healed|failed); build_tracker_drift renders its tail so a heal — or a stuck failure — is VISIBLE in
# the console, never a silent correction.
TRACKER_SWEEP_LEDGER="$TREES/.agent-watch-tracker-swept"
TRACKER_HEAL_FILE="$TREES/.agent-watch-tracker-heals"
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

# _effective_human_verify_policy — resolve HUMAN_VERIFY_POLICY (HERD-59) to hold | coordinator | auto.
# It shapes ONLY how a PR that declares a HUMAN-VERIFY: block is handled under MERGE_POLICY=auto:
#   hold        default; today's EXACT behavior — a sha-keyed approve-style hold released by
#               herd-approve.sh approve. Byte-identical when the key is unset.
#   coordinator keep the hold but notify loudly and flag it coordinator-actionable, so a coordinator/
#               agent runs the declared steps then approves via herd-approve.sh approve.
#   auto        treat the declared steps as INFORMATIONAL only — journal + PR-comment them and merge
#               on green gates (the standing human-verify authorization codified as an engine switch).
# Unknown/empty → hold (fail safe). Pure; the launch-time resolution below surfaces a bad value once.
_effective_human_verify_policy() {
  case "${HUMAN_VERIFY_POLICY:-}" in
    hold|coordinator|auto) printf '%s' "${HUMAN_VERIFY_POLICY}" ;;
    *)                     printf 'hold' ;;
  esac
}
HV_POLICY="$(_effective_human_verify_policy)"
# An explicitly-set but UNRECOGNIZED value fails safe to hold — journal it once at launch so a typo
# (HUMAN_VERIFY_POLICY=cordinator) never silently rides the default. Skipped in lib mode so sourcing
# for the pure helpers never writes a journal line.
if [ "${AGENT_WATCH_LIB:-}" != "1" ]; then
  case "${HUMAN_VERIFY_POLICY:-}" in
    ''|hold|coordinator|auto) ;;
    *) journal_append human_verify_policy_invalid value "$HUMAN_VERIFY_POLICY" fell_back_to hold 2>/dev/null || true ;;
  esac
fi
# This watcher's own worktree root — never auto-merge/remove the dir we run from.
SELF_WT="$(cd "$HERE/../.." && pwd)"

# Console palette — themed via HERD_THEME (default tokyonight, byte-identical to the old hardcoded
# truecolor block). theme.sh resolves .herd/themes/<name>/palette.sh → templates/themes/<name>/ →
# tokyonight, warns-once-and-falls-back on an unknown/broken theme, and renders plain under NO_COLOR
# or a non-TTY stdout. This is a status console (a pane), not markdown, so it uses the truecolor C_*.
# shellcheck source=/dev/null
. "$HERE/theme.sh"
herd_theme_load_console

SLUGW=28               # slug column width — pads slugs so the state words align.

last_frame=""
HDR_LINE=""
RULE=""
LANDED=""
BLOCKED=""
TRACKER_DRIFT=""
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

# ── Tracker-ref → slug console labelling (HERD-92) ────────────────────────────────────────────────
# Operators saw TWO naming systems on the console: healed rows show the TRACKER ID (HERD-nn) while
# in-flight / recently-landed rows showed only the worktree SLUG — no way to correlate at a glance.
# The fix is DISPLAY-ONLY (branches/slugs are never renamed — the slug keys worktrees, agent names,
# tab labels and PR↔worktree matching): render every row as "<ref> <slug>" wherever a tracker ref is
# known, and the plain slug (byte-identical to before) when it is not.
#
# Ref source, read per tick with NO gh/backend call:
#   • in-flight — a cheap per-worktree marker "$TREES/.herd-ref-<slug>" holding the HERD_ITEM_REF the
#     lane spawned with (written once by herd-feature.sh / herd-quick.sh; absent for an untracked or
#     pre-HERD-92 spawn).
#   • recently-landed — the ref captured into the $STATE row at merge time (do_merge), from the marker
#     or the merged PR's 'Refs:' body line.
_slug_ref_file() { printf '%s' "$TREES/.herd-ref-$1"; }

# _slug_ref <slug> — echo the tracker ref recorded for this slug's worktree marker, or nothing. Reads
# only the FIRST whitespace-delimited token so a malformed marker can never inject spaces/newlines
# into a console row. Empty (fail-soft) whenever the marker is absent/blank — the plain-slug path.
_slug_ref() {
  local f ref; f="$(_slug_ref_file "$1")"
  [ -s "$f" ] || return 0
  read -r ref _ < "$f" 2>/dev/null || return 0
  printf '%s' "${ref:-}"
}

# _slug_cell <slug> [ref] — the padded slug column for a console row. When a tracker ref is known
# (passed explicitly for landed rows, else looked up from the per-worktree marker for in-flight
# rows) the cell renders "<ref> <slug>"; with no ref it is BYTE-IDENTICAL to the pre-HERD-92 plain
# slug column. Padded to SLUGW so the state words still align; a ref+slug wider than the column is
# simply not padded (the same graceful overflow a long slug has today). The caller wraps the cell in
# its own color, so the ref inherits the row's slug styling for a single, consistent label.
_slug_cell() {
  local slug="$1" ref="${2-}"
  [ -n "$ref" ] || ref="$(_slug_ref "$slug")"
  if [ -n "$ref" ]; then
    printf '%-*s' "$SLUGW" "$ref $slug"
  else
    printf '%-*s' "$SLUGW" "$slug"
  fi
}

# build_landed — the pinned "recently landed" rows: the last 3 lines of the state file
# ("<epoch> <pr#> <slug> [ref]"), newest first. Stays visible even when idle. The optional 4th field
# is the tracker ref captured at merge (HERD-92); pre-HERD-92 rows have none and render the plain slug.
build_landed() {
  if [ ! -s "$STATE" ]; then
    LANDED="    ${C_DIM}nothing yet${C_RESET}"$'\n'
    return 0
  fi
  LANDED=""
  while read -r epoch prnum slug ref; do
    [ -z "${epoch:-}" ] && continue
    hhmm="$(epoch_to_hhmm "$epoch")"
    pnum="$(printf '#%-4s' "$prnum")"
    sl="$(_slug_cell "$slug" "$ref")"
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

# build_tracker_drift — the "tracker healed" section: the last 3 heal actions from $TRACKER_HEAL_FILE
# ("<epoch> <status> <ref> <pr> <found-state>", written by tracker-state-sweep.sh), newest first.
# Empty (TRACKER_DRIFT="") when the file is absent/empty so render omits the section. A `healed` row
# is calm green (drift was auto-corrected); a `failed` row is loud red (still stuck, retries next
# sweep) — either way the drift is VISIBLE, never a silent correction (HERD-86).
build_tracker_drift() {
  TRACKER_DRIFT=""
  [ -s "$TRACKER_HEAL_FILE" ] || return 0
  local epoch status ref pr state hhmm glyph color rows=""
  while read -r epoch status ref pr state; do
    [ -n "${ref:-}" ] || continue
    hhmm="$(epoch_to_hhmm "$epoch")"
    case "$status" in
      healed) glyph='🩹'; color="$C_GREEN" ;;
      *)      glyph='⚠️'; color="$C_RED"   ;;
    esac
    rows="${rows}    ${color}${glyph}${C_RESET} ${C_BOLD}${ref}${C_RESET} ${color}${status}${C_RESET} ${C_DIM}#${pr} was ${state} · ${hhmm}${C_RESET}"$'\n'
  done < <(reverse_file "$TRACKER_HEAL_FILE" | head -3)
  [ -n "$rows" ] && TRACKER_DRIFT="$rows"
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
  if [ -n "${TRACKER_DRIFT:-}" ]; then
    frame="${frame}  ${C_DIM}tracker healed${C_RESET}"$'\n'"${TRACKER_DRIFT}"$'\n'
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

# already_merged <pr#> <slug> — idempotency guard against the persistent state file. Matches the
# "<epoch> <pr#> <slug>" prefix followed by end-of-line OR a space (a HERD-92 4th tracker-ref field),
# so appending the ref never regresses this guard.
already_merged() {
  [ -s "$STATE" ] || return 1
  grep -qE "^[0-9]+ $1 $2( |\$)" "$STATE" 2>/dev/null
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

# ── Risk-tiered review classification (REVIEW_ESCALATE_GLOB / DOCS_ONLY_GLOB) ─────────────────────
# _classify_review_tier <pr#> — echo the review tier for a PR's diff: STRONG | CHEAP | DOCS | SKIP.
# Only ever called when REVIEW_ESCALATE_GLOB or DOCS_ONLY_GLOB is set (the opt-in); with BOTH empty the
# caller keeps today's always-$MODEL_REVIEW path and this never runs. Classification is DETERMINISTIC and
# fails SAFE — any uncertainty (unreadable/empty diff) → STRONG, never a downgrade:
#   • only *.md / tests/ paths changed                  → SKIP  (no reviewer; PASS recorded low-risk)
#   • any path matches REVIEW_ESCALATE_GLOB             → STRONG (engine surface; escalation wins)
#   • more than REVIEW_ESCALATE_MAXFILES files changed  → STRONG (large diff; escalation wins)
#   • every path matches DOCS_ONLY_GLOB (opt-in)        → DOCS   ($REVIEW_MODEL_DOCS, cheapest tier)
#   • otherwise (small, low-risk)                        → CHEAP  ($REVIEW_MODEL_CHEAP)
# ESCALATION WINS: the REVIEW_ESCALATE_GLOB / MAXFILES checks run BEFORE the DOCS_ONLY_GLOB check, so a
# docs-only diff that ALSO touches an engine-critical path (or is large) still gets the STRONG tier.
_classify_review_tier() {
  local pr="$1" paths n max
  # Changed-file paths for THIS PR's diff. Any failure/empty list → STRONG (never downgrade blind).
  paths="$(gh pr diff "$pr" --name-only 2>/dev/null | awk 'NF')"
  [ -n "$paths" ] || { printf STRONG; return 0; }
  # DOCS/TEST-ONLY: every changed path is a *.md doc or under tests/ — i.e. NO line fails to match
  # the docs/test pattern → skip the adversarial review entirely.
  if ! printf '%s\n' "$paths" | grep -qvE '(\.md$)|(^tests/)'; then printf SKIP; return 0; fi
  # Engine-surface glob match → full strong review (escalation wins over the docs tier). The -n guard
  # keeps this classifier safe when only DOCS_ONLY_GLOB opted in: an empty REVIEW_ESCALATE_GLOB would
  # make `grep -qE ""` match every path and wrongly force STRONG.
  if [ -n "${REVIEW_ESCALATE_GLOB:-}" ] && printf '%s\n' "$paths" | grep -qE "$REVIEW_ESCALATE_GLOB"; then printf STRONG; return 0; fi
  # Large diff (many files) → strong even without a glob match (escalation wins over the docs tier).
  n="$(printf '%s\n' "$paths" | grep -c .)"
  max="${REVIEW_ESCALATE_MAXFILES:-10}"; case "$max" in ''|*[!0-9]*) max=10 ;; esac
  if [ "$n" -gt "$max" ] 2>/dev/null; then printf STRONG; return 0; fi
  # DOCS-ONLY (opt-in via DOCS_ONLY_GLOB): every changed path matches the operator's docs pattern → the
  # cheapest reviewer tier ($REVIEW_MODEL_DOCS). Distinct from SKIP: a real (cheap) adversarial review
  # still runs — for doc formats the hardcoded *.md/tests SKIP above doesn't cover (e.g. *.txt).
  if [ -n "${DOCS_ONLY_GLOB:-}" ] && ! printf '%s\n' "$paths" | grep -qvE "$DOCS_ONLY_GLOB"; then
    printf DOCS; return 0
  fi
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

  # RISK-TIERED review gate (opt-in via REVIEW_ESCALATE_GLOB and/or DOCS_ONLY_GLOB). Default (BOTH
  # empty) → the STRONG tier with an EMPTY model, i.e. today's unchanged always-$MODEL_REVIEW path; no
  # diff is classified at all. When either glob is set, classify this pr+sha's diff ONCE (cached,
  # sha-keyed) and either skip the reviewer entirely (docs/test-only) or select the docs/cheap/strong
  # model tier.
  local _rt_model=""
  if [ -n "${REVIEW_ESCALATE_GLOB:-}" ] || [ -n "${DOCS_ONLY_GLOB:-}" ]; then
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
    # DOCS-only diff (opt-in via DOCS_ONLY_GLOB): a real adversarial review on the cheapest tier.
    [ "$tier" = "DOCS" ]  && _rt_model="$REVIEW_MODEL_DOCS"
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

# ── Parallel gate dispatch (GATE_DISPATCH, HERD-73) ──────────────────────────────────────────────
# _gate_dispatch_mode — resolve GATE_DISPATCH to "serial" | "parallel". Unknown/empty → serial, so
# the default (and any typo) preserves today's EXACT serial behavior — the review dispatches only
# after the healthcheck outcome lands.
_gate_dispatch_mode() {
  case "${GATE_DISPATCH:-serial}" in
    parallel) printf parallel ;;
    *)        printf serial ;;
  esac
}

# _predispatch_review_if_parallel <pr#> <slug> <headSha> — under GATE_DISPATCH=parallel ONLY, advance
# the background review state machine for (pr,sha) NOW, at the same action-pass tick the healthcheck
# starts, so the pre-merge review runs CONCURRENTLY with the healthcheck instead of only after it
# lands. A strict NO-OP under the default serial mode (and in dry-run, or when the head sha is not yet
# known) so today's behavior is byte-identical.
#
# This ONLY kicks the reviewer off early — it never merges. The merge decision downstream is unchanged
# and still requires BOTH gates green: the merge-path review gate re-reads the SAME sha-keyed ledger /
# inflight marker this shares, so the dispatch is idempotent (a (pr,sha) is still reviewed at most once,
# REVIEW_CONCURRENCY is still honored — an over-cap review reports QUEUED here exactly as in the merge
# path). Because the reviewer is keyed to the head sha, a health CODE-ERROR does NOT touch it: the
# candidate simply `continue`s without reaching the merge-path gate, and this same-sha re-entry on the
# next tick collects/records the verdict rather than killing the in-flight reviewer — the sha is blocked
# by health anyway, so the finished verdict is recorded but never acted on. The echoed token is
# intentionally discarded; the console row for this tick is owned by the healthcheck gate.
#
# LEDGER PRECONDITION (mirrors the merge path's `if [ "$prior" != "PASS" ]` guard): _review_gate_step's
# contract is "called once per tick for a candidate with NO ledger verdict yet". Once a PASS/BLOCK is
# recorded for pr+sha the review is DONE for that commit and its result/inflight/tier markers are gone;
# calling _review_gate_step again would find no markers and DISPATCH A BRAND-NEW review every tick — the
# review-once invariant broken for any candidate that stays a candidate WITHOUT merging (health error,
# approve/observe hold, human-verify hold, branch-protection block, a mergeability regression). So skip
# the kick entirely when a verdict already exists; a new commit changes the sha and gets a fresh review.
_predispatch_review_if_parallel() {
  [ "$(_gate_dispatch_mode)" = "parallel" ] || return 0
  [ -z "$DRYRUN" ] || return 0
  local pr="$1" slug="$2" sha="$3"
  [ -n "$sha" ] || return 0
  review_verdict "$pr" "$sha" >/dev/null 2>&1 && return 0
  _review_gate_step "$pr" "$slug" "$sha" >/dev/null 2>&1 || true
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

# hv_informed_noted <pr#> <headSha> — true if we already journaled+commented a HUMAN_VERIFY_POLICY=auto
# PR's declared steps as informational (dedup guard so the note fires once per sha, not every tick).
# Reuses the $APPROVALS ledger with its own 'hv-informed' state word — herd-approve.sh's `list` only
# reads 'awaiting' lines, so this never appears as a pending approval.
hv_informed_noted() {
  [ -s "$APPROVALS" ] || return 1
  grep -q "^[0-9]* hv-informed $1 $2$" "$APPROVALS" 2>/dev/null
}

# record_hv_informed <pr#> <headSha> — note the informational HUMAN-VERIFY steps were recorded.
record_hv_informed() {
  printf '%s hv-informed %s %s\n' "$(date +%s)" "$1" "$2" >> "$APPROVALS"
}

# purge_pr_approvals <pr#> — on merge/reap, drop EVERY approval-ledger row for this PR number
# (awaiting/approved/observed/hv-informed) regardless of sha. HERD-90: when a HUMAN-VERIFY hold
# re-applies at a NEW sha and the PR is merged at that sha, the OLD sha's 'awaiting' row was never
# cleaned — so `herd-approve.sh list` kept surfacing a phantom hold for a long-merged PR and
# `approve` no-op'd with "already approved", causing false coordinator wakes. A merge is terminal:
# no approval state for this PR is ever needed again, so we purge all of its rows. The row format is
# "<epoch> <state> <pr#> <sha>", so the PR number is field 3; exact string compare avoids clobbering
# a different PR whose number is a substring (e.g. 9 vs 90). Atomic rewrite via a temp file; fully
# fail-soft — an approvals-ledger hiccup must never fail the merge.
purge_pr_approvals() {
  local _pr="$1" _tmp
  [ -s "$APPROVALS" ] || return 0
  _tmp="$(mktemp "$APPROVALS.XXXXXX" 2>/dev/null)" || return 0
  if awk -v p="$_pr" '$3 != p' "$APPROVALS" > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$APPROVALS" 2>/dev/null || rm -f "$_tmp"
  else
    rm -f "$_tmp"
  fi
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

# _hold_decision <mode> <hv_hold> <approved> [hv_policy] — the pure action selector for a PASS-gated PR.
#   mode:      auto | approve | observe   (the effective merge policy)
#   hv_hold:   "1" if the PR declares a human-verify block (only ever set in auto mode), else ""
#   approved:  "1" if a sha-keyed approval record exists for this PR+sha, else ""
#   hv_policy: HUMAN_VERIFY_POLICY (hold | coordinator | auto); default "hold" for legacy 3-arg callers.
# Echoes exactly one token: MERGE | HOLD | OBSERVE. No side effects — the caller owns the ledger
# writes, the journal, and the merge. In approve mode hv_hold is ignored (the policy already holds),
# so a human-verify PR is held exactly ONCE, never doubly. Under hv_policy=auto a human-verify PR is
# treated as informational and NOT held (the caller journals + comments the steps before merging);
# hold and coordinator both HOLD (they differ only in how the caller surfaces the hold).
_hold_decision() {
  local mode="$1" hv="$2" approved="$3" hvpol="${4:-hold}"
  case "$mode" in
    observe) printf 'OBSERVE' ;;
    approve) [ -n "$approved" ] && printf 'MERGE' || printf 'HOLD' ;;
    auto)
      if [ -n "$hv" ] && [ "$hvpol" != "auto" ]; then
        [ -n "$approved" ] && printf 'MERGE' || printf 'HOLD'
      else
        printf 'MERGE'
      fi ;;
    *) printf 'MERGE' ;;
  esac
}

# _hold_ready_label <hv_hold> <pr#> [hv_policy] — the console phrase for a PASS-gated PR being held. A
# human-verify hold tells the operator exactly how to release it (and, via herd-approve.sh list,
# what to run first); a plain approve hold shows the generic wording. Under HUMAN_VERIFY_POLICY=
# coordinator the hold is flagged coordinator-actionable so a coordinator/agent knows to run the steps.
_hold_ready_label() {
  if [ -n "$1" ]; then
    if [ "${3:-hold}" = "coordinator" ]; then
      printf 'ready · human-verify (coordinator-actionable) · run steps then herd-approve.sh approve %s' "$2"
    else
      printf 'ready · human-verify pending · herd-approve.sh approve %s' "$2"
    fi
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

# _reconcile_pr_ref <pr#> — deterministic tracker linkage (HERD-39): read the merged PR body and
# print the explicit 'Refs: <ID>' tracker reference the builder carried (lanes REQUIRE it when the
# coordinator spawned with HERD_ITEM_REF). Empty when the PR carries no ref, the body is unreadable,
# or the value is still the template placeholder ('<...>' / none / n/a). Best-effort + fail-soft: a
# missing 'gh', an offline run, or a body-less PR all yield an empty ref, so the caller cleanly falls
# back to the fuzzy path — never a hard error on the merge tail.
#
# CRITICAL: `gh pr view --json body` returns the raw markdown WITH HTML comments intact — GitHub does
# not strip `<!-- … -->` from a classic PR template. So we FIRST strip every HTML comment block (the
# PULL_REQUEST_TEMPLATE.md carries example/instruction text inside a comment) before grepping; without
# this an example 'Refs:' line buried in the template's own comment would poison the extractor and
# silently mark an unrelated tracker item shipped on every merge of an untracked PR.
_reconcile_pr_ref() {
  local body ref
  body="$(gh pr view "$1" --json body -q .body 2>/dev/null || true)"
  [ -n "$body" ] || return 0
  # Strip HTML comment blocks (possibly multi-line) so template instructions/examples can't be read as
  # a real ref. python3 is already a hard dependency here; if it is somehow unavailable, fall back to
  # the raw body (the line-start anchor + placeholder guard below are still a partial defense).
  body="$(printf '%s' "$body" | python3 -c 'import sys,re
sys.stdout.write(re.sub(r"<!--.*?-->", "", sys.stdin.read(), flags=re.DOTALL))' 2>/dev/null || printf '%s' "$body")"
  # First real 'Refs:' line, case-insensitive, anchored at line start; take the first
  # whitespace-delimited token after the colon.
  ref="$(printf '%s\n' "$body" \
    | grep -iE '^[[:space:]]*Refs:[[:space:]]*[^[:space:]]' \
    | head -n1 \
    | sed -E 's/^[[:space:]]*[Rr][Ee][Ff][Ss]:[[:space:]]*//; s/[[:space:]].*$//' 2>/dev/null || true)"
  case "$ref" in
    ''|'<'*|none|None|NONE|n/a|N/A|na|NA) return 0 ;;  # placeholder / unset → no explicit ref
  esac
  printf '%s' "$ref"
}

# _reconcile_via_ref <ref> — resolve the backlog item for an EXPLICIT tracker ref through the ACTIVE
# backend's update-state op, marking it 'done'. Sources the backend exactly the way scribe-step.sh
# does (SCRIBE_BACKEND + optional SCRIBE_BACKEND_DIR override; secrets from .herd/secrets) but inside
# a SUBSHELL so the _backend_* functions never leak into the watcher's namespace. Returns 0 ONLY when
# the backend reports a real transition (_BACKEND_RESULT=DONE); any of {no update-state op (the default
# 'file' backend records state by editing $BACKLOG_FILE, not via dispatch), unknown backend, or a
# NOCHANGE/no-match} returns non-zero so the caller falls back to the fuzzy scribe path — this is what
# guarantees the ref-less / file-backend behavior never regresses.
_reconcile_via_ref() {
  local ref="$1" pr="${2:-}" _bdir _bfile _secrets result
  _bdir="${SCRIBE_BACKEND_DIR:-$HERE/backends}"
  _bfile="$_bdir/${SCRIBE_BACKEND:-file}.sh"
  [ -f "$_bfile" ] || return 1
  result="$(
    _secrets="$MAIN/.herd/secrets"
    # shellcheck source=/dev/null
    [ -f "$_secrets" ] && . "$_secrets"
    # shellcheck source=/dev/null
    . "$_bfile" 2>/dev/null || exit 1
    command -v _backend_update_state >/dev/null 2>&1 || exit 1
    cd "$MAIN" 2>/dev/null || true
    # HERD-85: attribute this explicit-ref state write to the 'reconcile' component and carry the
    # merged PR into the tracker_write event (journal_append is inherited from agent-watch's top-level
    # source of journal.sh; the backend's _backend_tw_journal reads these two env vars).
    export HERD_COMPONENT="reconcile" HERD_TW_PR="$pr"
    _BACKEND_RESULT=""
    _backend_update_state "$ref" done >/dev/null 2>&1 || true
    printf '%s' "$_BACKEND_RESULT"
  )"
  [ "$result" = "DONE" ]
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
  local rb_pr="$1" rb_slug="$2" rb_sha="${3:-}" rb_ref
  reconcile_enqueued "$rb_pr" "$rb_sha" && return 0
  record_reconcile "$rb_pr" "$rb_sha" "$rb_slug"
  # EXPLICIT-REF path FIRST (HERD-39): if the merged PR carries a 'Refs: <ID>' line, resolve the
  # backlog item by that exact ref via the active backend's update-state — deterministic, no fuzzy
  # slug/title guessing and no scribe LLM. Only when there is no ref line OR it fails to resolve
  # (backend has no update-state op, e.g. the default file backend, or reports no match) do we fall
  # back to today's fuzzy scribe enqueue — so ref-less PRs behave EXACTLY as before. Journal which
  # path resolved so a drift audit can tell explicit-ref links from fuzzy ones.
  rb_ref="$(_reconcile_pr_ref "$rb_pr")"
  if [ -n "$rb_ref" ] && _reconcile_via_ref "$rb_ref" "$rb_pr"; then
    journal_append reconcile pr "$rb_pr" slug "$rb_slug" sha "$rb_sha" ref "$rb_ref" resolution explicit-ref
    return 0
  fi
  if [ -n "$rb_ref" ]; then
    journal_append reconcile pr "$rb_pr" slug "$rb_slug" sha "$rb_sha" ref "$rb_ref" resolution fuzzy
  else
    journal_append reconcile pr "$rb_pr" slug "$rb_slug" sha "$rb_sha" resolution fuzzy
  fi
  bash "$HERE/scribe.sh" "Reconcile: PR #${rb_pr} (worktree ${rb_slug}) merged — find the 🔜/🚧 backlog item matching worktree ${rb_slug} or the PR title and mark it ✅ shipped (PR #${rb_pr}); if none matches, no-op." >/dev/null 2>&1 || true
  return 0
}

# refresh_codemap <pr#> — POST-MERGE codemap freshness hook (best-effort, NEVER blocks/fails the
# merge). After a PR lands on the default branch and $MAIN is fast-forwarded, regenerate the
# committed docs/codemap.md against $MAIN and, ONLY when the deterministic scan actually changed its
# content, commit the refresh STRAIGHT to the default branch — no PR, mirroring the BACKLOG.md
# generated-artifact convention — and push ff-safe. Every failure mode fails SOFT and journals a
# `codemap_refresh` event so a drift audit can see what happened; nothing here can ever return
# non-zero into do_merge.
#
# Gated by CODEMAP_AUTOREFRESH: off → byte-inert (we never run the scan, never touch the tree).
# Race-guarded three ways: (1) only when the project has already ADOPTED the codemap (the committed
# docs/codemap.md exists — never materialize a new one); (2) skip if that path already carries an
# uncommitted change (a concurrent writer owns it this tick — never clobber or bundle their edit);
# (3) codemap.sh rewrites the file ONLY when content changed, so a clean tree after regen = fresh,
# nothing to commit. The commit is scoped to docs/codemap.md alone so nothing else is swept in.
refresh_codemap() {
  local rc_pr="${1:-}" rc_out="docs/codemap.md" rc_script="$HERE/codemap.sh"
  case "$(printf '%s' "${CODEMAP_AUTOREFRESH:-true}" | tr '[:upper:]' '[:lower:]')" in
    0|false|off|no|disable|disabled)
      journal_append codemap_refresh pr "$rc_pr" result skipped reason disabled; return 0 ;;
  esac
  [ -f "$rc_script" ]      || { journal_append codemap_refresh pr "$rc_pr" result skipped reason no-script;  return 0; }
  [ -f "$MAIN/$rc_out" ]   || { journal_append codemap_refresh pr "$rc_pr" result skipped reason no-codemap; return 0; }
  # A pending change already on docs/codemap.md means someone else is mid-edit — leave it alone.
  if [ -n "$(git -C "$MAIN" status --porcelain -- "$rc_out" 2>/dev/null)" ]; then
    journal_append codemap_refresh pr "$rc_pr" result skipped reason dirty-path; return 0
  fi
  # Regenerate in place against the freshly ff'd $MAIN (the seams the hermetic tests also drive).
  if ! HERD_CODEMAP_ROOT="$MAIN" HERD_CODEMAP_OUT="$MAIN/$rc_out" bash "$rc_script" >/dev/null 2>&1; then
    journal_append codemap_refresh pr "$rc_pr" result error reason regen-failed; return 0
  fi
  # Unchanged content → codemap.sh left the file (and its mtime) alone → nothing to commit.
  if [ -z "$(git -C "$MAIN" status --porcelain -- "$rc_out" 2>/dev/null)" ]; then
    journal_append codemap_refresh pr "$rc_pr" result fresh; return 0
  fi
  # Content changed → commit ONLY docs/codemap.md and push ff-safe (never --force). A rejected push
  # (another direct-commit landed first) rebases once and retries; a genuine failure fails soft.
  if ! git -C "$MAIN" commit -q -m "chore: refresh codemap after PR #${rc_pr}" -- "$rc_out" >/dev/null 2>&1; then
    journal_append codemap_refresh pr "$rc_pr" result error reason commit-failed; return 0
  fi
  if git -C "$MAIN" push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" >/dev/null 2>&1; then
    journal_append codemap_refresh pr "$rc_pr" result committed pushed yes; return 0
  fi
  if git -C "$MAIN" pull --rebase --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME" >/dev/null 2>&1 \
     && git -C "$MAIN" push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" >/dev/null 2>&1; then
    journal_append codemap_refresh pr "$rc_pr" result committed pushed yes-after-rebase; return 0
  fi
  git -C "$MAIN" rebase --abort >/dev/null 2>&1 || true
  journal_append codemap_refresh pr "$rc_pr" result committed pushed no
  return 0
}

# refresh_symbol_index <pr#> — POST-MERGE symbol-index freshness hook, the function-level twin of
# refresh_codemap. Regenerates the committed docs/symbol-index.md against the freshly ff'd $MAIN and,
# ONLY when the deterministic scan actually changed its content, commits the refresh STRAIGHT to the
# default branch (no PR, BACKLOG.md-style) and pushes ff-safe. Best-effort and byte-inert on every
# failure mode; journals a `symbol_index_refresh` event; can never return non-zero into do_merge.
#
# Shares the CODEMAP_AUTOREFRESH lever (both are committed engine maps kept fresh at zero token cost)
# and the same three race guards as refresh_codemap: (1) only when the project has ADOPTED the index
# (the committed docs/symbol-index.md exists — never materialize a new one); (2) skip if that path
# already carries an uncommitted change; (3) symbol-index.sh rewrites the file ONLY when content
# changed, so a clean tree after regen = fresh, nothing to commit. Scoped to docs/symbol-index.md.
refresh_symbol_index() {
  local rs_pr="${1:-}" rs_out="docs/symbol-index.md" rs_script="$HERE/symbol-index.sh"
  case "$(printf '%s' "${CODEMAP_AUTOREFRESH:-true}" | tr '[:upper:]' '[:lower:]')" in
    0|false|off|no|disable|disabled)
      journal_append symbol_index_refresh pr "$rs_pr" result skipped reason disabled; return 0 ;;
  esac
  [ -f "$rs_script" ]    || { journal_append symbol_index_refresh pr "$rs_pr" result skipped reason no-script; return 0; }
  [ -f "$MAIN/$rs_out" ] || { journal_append symbol_index_refresh pr "$rs_pr" result skipped reason no-index;  return 0; }
  # A pending change already on docs/symbol-index.md means someone else is mid-edit — leave it alone.
  if [ -n "$(git -C "$MAIN" status --porcelain -- "$rs_out" 2>/dev/null)" ]; then
    journal_append symbol_index_refresh pr "$rs_pr" result skipped reason dirty-path; return 0
  fi
  # Regenerate in place against the freshly ff'd $MAIN (the seams the hermetic tests also drive).
  if ! HERD_SYMBOL_INDEX_ROOT="$MAIN" HERD_SYMBOL_INDEX_OUT="$MAIN/$rs_out" bash "$rs_script" >/dev/null 2>&1; then
    journal_append symbol_index_refresh pr "$rs_pr" result error reason regen-failed; return 0
  fi
  # Unchanged content → symbol-index.sh left the file (and its mtime) alone → nothing to commit.
  if [ -z "$(git -C "$MAIN" status --porcelain -- "$rs_out" 2>/dev/null)" ]; then
    journal_append symbol_index_refresh pr "$rs_pr" result fresh; return 0
  fi
  # Content changed → commit ONLY docs/symbol-index.md and push ff-safe (never --force). A rejected
  # push (another direct-commit landed first) rebases once and retries; a genuine failure fails soft.
  if ! git -C "$MAIN" commit -q -m "chore: refresh symbol-index after PR #${rs_pr}" -- "$rs_out" >/dev/null 2>&1; then
    journal_append symbol_index_refresh pr "$rs_pr" result error reason commit-failed; return 0
  fi
  if git -C "$MAIN" push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" >/dev/null 2>&1; then
    journal_append symbol_index_refresh pr "$rs_pr" result committed pushed yes; return 0
  fi
  if git -C "$MAIN" pull --rebase --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME" >/dev/null 2>&1 \
     && git -C "$MAIN" push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" >/dev/null 2>&1; then
    journal_append symbol_index_refresh pr "$rs_pr" result committed pushed yes-after-rebase; return 0
  fi
  git -C "$MAIN" rebase --abort >/dev/null 2>&1 || true
  journal_append symbol_index_refresh pr "$rs_pr" result committed pushed no
  return 0
}

# _reap_slug <slug> <dir> <pr#> <sha> [reason] — the IDEMPOTENT worktree-teardown primitive shared by
# the merge path (do_merge) and the startup reap-sweep (_startup_reap_sweep). Runs the three reap
# steps in the same order do_merge always has: (1) force-remove the worktree (the SHARE_LINKS
# symlinks make a non-force remove fail); (2) reap the per-worktree tracker-ref marker (HERD-92 — the
# ref lives on in the $STATE row for "recently landed"); (3) journal a `reap` event carrying the
# supplied reason (default 'merged'); (4) close the builder/review/resolver tabs + prune their
# .herd-tabs rows via herd_teardown_slug. Every step is fail-soft and idempotent — a worktree already
# gone, a marker already reaped, a tab already closed all no-op — so a second call (a re-run merge
# tick OR a startup sweep over a worktree do_merge already reaped) is harmless.
_reap_slug() {
  local _rp_slug="$1" _rp_dir="$2" _rp_pr="${3:-}" _rp_sha="${4:-}" _rp_reason="${5:-merged}"
  git -C "$MAIN" worktree remove --force "$_rp_dir" >/dev/null 2>&1 || true
  rm -f "$(_slug_ref_file "$_rp_slug")" 2>/dev/null || true
  journal_append reap pr "$_rp_pr" slug "$_rp_slug" sha "$_rp_sha" reason "$_rp_reason"
  herd_teardown_slug "$_rp_slug"
  return 0
}

# do_merge <slug> <pr#> <worktree> — the safety-railed merge + post-merge sequence.
do_merge() {
  ds="$1"; dp="$2"; dd="$3"; dsha="${4:-}"
  if [ -n "$DRYRUN" ]; then
    return 0
  fi
  gh pr merge "$dp" "$(_merge_method_flag)" >/dev/null 2>&1 || return 1
  # HERD-92: capture the tracker ref so "recently landed" can render "<ref> <slug>" like the healed
  # section. Prefer the cheap per-worktree marker (no network); fall back to the merged PR's 'Refs:'
  # body line. Empty for an untracked PR → the row renders the plain slug, exactly as before.
  _dm_ref="$(_slug_ref "$ds")"
  [ -n "$_dm_ref" ] || _dm_ref="$(_reconcile_pr_ref "$dp" 2>/dev/null || true)"
  # Record FIRST: even if a later cleanup step dies, we never re-merge this PR. Omit the 4th field
  # entirely when there is no ref so a ref-less row stays byte-identical to the pre-HERD-92 format.
  if [ -n "$_dm_ref" ]; then
    printf '%s %s %s %s\n' "$(date +%s)" "$dp" "$ds" "$_dm_ref" >> "$STATE"
  else
    printf '%s %s %s\n' "$(date +%s)" "$dp" "$ds" >> "$STATE"
  fi
  journal_append merge pr "$dp" slug "$ds" sha "$dsha" method "$(_merge_method_flag)" reason gates_passed
  # HERD-90: purge every approval-ledger row for this PR (all shas) now that it is merged. Without
  # this, an OLD-sha 'awaiting' row from a re-applied HUMAN-VERIFY hold lingers as a phantom pending
  # approval in `herd-approve.sh list`. Done right after the merge record so a later cleanup crash
  # can never leave the phantom behind.
  purge_pr_approvals "$dp"
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
  # 2b) POST-MERGE codemap refresh: regenerate the committed docs/codemap.md against the freshly ff'd
  #     $MAIN and, only when it actually changed, commit it direct to the default branch (no PR,
  #     BACKLOG.md-style) and push ff-safe. Gated by CODEMAP_AUTOREFRESH; fully fail-soft — a codemap
  #     problem never blocks or fails the merge (mirrors the reconcile hook's best-effort posture).
  refresh_codemap "$dp"
  # 2c) POST-MERGE symbol-index refresh: same posture as 2b but for the function-level def→caller
  #     index (docs/symbol-index.md). Shares the CODEMAP_AUTOREFRESH lever; fully fail-soft.
  refresh_symbol_index "$dp"
  # 3+4) IDEMPOTENT teardown (the WATCHER's job — sub-agents NEVER self-close): force-remove the
  #      worktree, reap the HERD-92 tracker-ref marker (the ref lives on in the $STATE row), journal
  #      the reap, and close the builder / review·slug / resolver·slug tabs. Shared with the startup
  #      reap-sweep so a merge that crashed BEFORE this point (PR #208) is resumed on restart.
  _reap_slug "$ds" "$dd" "$dp" "$dsha" merged
  return 0
}

# _srs_gh_view <branch-or-pr#> — echo "state<TAB>headRefOid<TAB>number" for a PR resolved by branch
# name OR number, or nothing on any error (no PR, deleted branch, gh down). One network call. The head
# OID is what makes the sweep SAFE (see _startup_reap_sweep) — never reap without it.
_srs_gh_view() {
  gh pr view "$1" --json state,number,headRefOid \
    -q '.state+"\t"+((.headRefOid)//"")+"\t"+(((.number)//0)|tostring)' 2>/dev/null || true
}

# _startup_reap_sweep — RESUME teardown for a merged-but-unreaped worktree (HERD-91). Reaps are
# merge-EVENT-driven: do_merge writes the merge ledger row FIRST, then runs the post-merge sequence
# (reconcile → ff → codemap/symbol-index refresh → worktree remove + tab close). A watcher killed
# mid-sequence (PR #208: a restart 2 s after a merge) lands the merge but never reaps, stranding the
# worktree + its idle builder tab with NO red anywhere — and because the merge is already ledgered,
# the restarted watcher never retries. This one-shot startup sweep closes that gap: it walks the live
# feature worktrees and, for any that is PROVABLY the head of an ALREADY-MERGED PR, runs the SAME
# idempotent reap path do_merge does (worktree remove, marker reap, tab close, .herd-tabs prune) —
# journaling the reap with reason=startup-sweep so a post-mortem can tell a resumed teardown apart.
#
# SAFETY — never reap a live builder (data-integrity): a slug is a coordinator-chosen kebab name that
# gets re-spawned (a follow-up on the same feature), the merge ledger ($STATE) is append-only and
# never pruned, and a builder opens its PR DURING the run (not at spawn). So a fresh, actively-building
# worktree can carry a minutes-old stale ledger row AND have no PR yet — the exact PR #208 restart
# window this targets. A slug/branch-name match alone (or a "gh silent + in ledger" fallback) would
# force-remove that live worktree and silently lose uncommitted work. The invariant that makes the
# reap safe is therefore NOT the slug but the COMMIT: we reap a worktree ONLY when its current HEAD sha
# equals the headRefOid of a MERGED PR — i.e. every committed thing in the worktree is already in a
# merged PR, so there is nothing to lose. Concretely, per worktree:
#   1. resolve the worktree's HEAD sha locally (git rev-parse); no HEAD ⇒ can't verify ⇒ SKIP.
#   2. look up the PR by branch name; if it is MERGED and its headRefOid == HEAD ⇒ reap candidate.
#   3. else, if the slug is in the ledger, look up THAT PR by number; MERGED and headRefOid == HEAD
#      ⇒ reap candidate (covers a stranded worktree whose branch was deleted at merge, without
#      trusting the stale ledger row blindly — the sha still has to match).
#   4. otherwise SKIP. A reused slug with a fresh commit (or none yet), a still-OPEN PR, an
#      unreachable gh, all fail the sha match and are left untouched.
#   5. defense-in-depth: even with a HEAD match, refuse to force-remove a worktree with UNCOMMITTED
#      changes — a merged worktree is clean, so a dirty tree is not the stranded case; journal a skip.
# Idempotent + fully fail-soft (the reap primitive no-ops on an already-gone worktree / closed tab),
# so a re-run is harmless; the SELF worktree is always excluded. Skipped entirely in dry-run. Zero
# stranded worktrees ⇒ zero action (no reap, no journal line) — the common, healthy startup.
_startup_reap_sweep() {
  [ -z "${DRYRUN:-}" ] || return 0
  local _srs_wt; _srs_wt="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null || true)"
  [ -n "$_srs_wt" ] || return 0
  # Slugs the reap ledger already records as merged (col 3 of each $STATE row: 'ts pr slug [ref]').
  local _srs_ledger=""
  [ -f "$STATE" ] && _srs_ledger="$(awk 'NF>=3{print $3}' "$STATE" 2>/dev/null || true)"
  local _srs_dir _srs_slug _srs_branch _srs_n=0
  while IFS=$'\x1f' read -r _srs_dir _srs_slug _srs_branch; do
    [ -n "$_srs_slug" ] || continue
    [ "$_srs_dir" = "$SELF_WT" ] && continue        # never reap the coordinator's own checkout
    [ -d "$_srs_dir" ] || continue
    # (1) The worktree's CURRENT HEAD sha — the anchor the reap decision must match against.
    local _srs_head
    _srs_head="$(git -C "$_srs_dir" rev-parse HEAD 2>/dev/null || true)"
    [ -n "$_srs_head" ] || continue                  # no resolvable HEAD → cannot verify → SKIP
    # (2) Resolve a MERGED PR whose headRefOid == this worktree's HEAD. Try the branch name first…
    local _srs_pr="" _srs_st _srs_oid _srs_num
    if [ -n "$_srs_branch" ]; then
      IFS=$'\t' read -r _srs_st _srs_oid _srs_num <<EOF
$(_srs_gh_view "$_srs_branch")
EOF
      if [ "$_srs_st" = "MERGED" ] && [ -n "$_srs_oid" ] && [ "$_srs_oid" = "$_srs_head" ]; then
        _srs_pr="$_srs_num"
      fi
    fi
    # (3) …else fall back to the ledger's PR NUMBER (covers a branch deleted at merge). The sha match
    #     is STILL required, so a stale ledger row for a re-spawned slug can never reap a live worktree.
    if [ -z "$_srs_pr" ] && [ -n "$_srs_ledger" ] && printf '%s\n' "$_srs_ledger" | grep -qxF "$_srs_slug"; then
      local _srs_ledger_pr
      _srs_ledger_pr="$(awk -v s="$_srs_slug" 'NF>=3 && $3==s{p=$2} END{if(p!="")print p}' "$STATE" 2>/dev/null || true)"
      if [ -n "$_srs_ledger_pr" ]; then
        IFS=$'\t' read -r _srs_st _srs_oid _srs_num <<EOF
$(_srs_gh_view "$_srs_ledger_pr")
EOF
        if [ "$_srs_st" = "MERGED" ] && [ -n "$_srs_oid" ] && [ "$_srs_oid" = "$_srs_head" ]; then
          _srs_pr="$_srs_ledger_pr"
        fi
      fi
    fi
    # (4) No MERGED PR whose head is this worktree's HEAD → not stranded (in-flight / reused / gh down).
    [ -n "$_srs_pr" ] || continue
    # (5) Defense-in-depth: never force-remove a worktree carrying uncommitted work.
    if [ -n "$(git -C "$_srs_dir" status --porcelain 2>/dev/null)" ]; then
      journal_append startup_reap_skip slug "$_srs_slug" pr "$_srs_pr" reason dirty-worktree
      continue
    fi
    _reap_slug "$_srs_slug" "$_srs_dir" "$_srs_pr" "$_srs_head" startup-sweep
    _srs_n=$(( _srs_n + 1 ))
  done < <(WT="$_srs_wt" MAIN="$MAIN" python3 -c '
import os
MAIN = os.environ["MAIN"]
def emit(wt, branch):
    if wt and wt != MAIN:
        print("\x1f".join([wt, os.path.basename(wt), branch or ""]))
wt = None; branch = None
for line in (os.environ.get("WT") or "").splitlines():
    if line.startswith("worktree "):
        emit(wt, branch); wt = line[9:]; branch = None
    elif line.startswith("branch "):
        branch = line[7:].replace("refs/heads/", "")
emit(wt, branch)
' 2>/dev/null)
  [ "$_srs_n" -eq 0 ] || journal_append startup_reap_sweep reaped "$_srs_n"
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

# _sweep_tracker_state — HERD-86 tracker-state self-heal. Runs every _TRACKER_SWEEP_INTERVAL ticks
# (low frequency; the drift it catches is a rare merge-tail failure, not a per-tick condition). Shells
# out to the standalone tracker-state-sweep.sh, pointing its ledger + heal-note surfaces at THIS
# watcher's $TREES files so build_tracker_drift renders any heal. The sweep re-asserts Done for a
# recently-merged PR whose tracker item drifted (the HERD-67/HERD-69 pattern: stuck open after merge),
# journals a tracker_state_healed event (component=sweep, HERD-85 attribution), and appends a console
# note. BEST-EFFORT: it can never fail or slow a tick — inert in dry-run, byte-inert when the backend
# has no update-state op (the file backend), and cheap when clean (one `gh pr list`, no backend read
# for any ref already confirmed Done in the ledger). Never merges, never edits BACKLOG.md.
_sweep_tracker_state() {
  [ -n "$DRYRUN" ] && return 0
  [ -f "$HERE/tracker-state-sweep.sh" ] || return 0
  HERD_TSWEEP_LEDGER="$TRACKER_SWEEP_LEDGER" \
  HERD_TSWEEP_NOTE_FILE="$TRACKER_HEAL_FILE" \
    bash "$HERE/tracker-state-sweep.sh" >/dev/null 2>&1 || true
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
  _hbv_sl="$(_slug_cell "$_hbv_slug")"
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

# ── Clean limit-menu resume via `herdr pane send-keys` (builders + coordinator) ───────────────────
# When a session hits the account usage limit it parks at Claude's interactive arrow-menu
# (option 1 "Upgrade your plan" HIGHLIGHTED / option 2 "Stop and wait for limit to reset"). Selecting
# option 2 triggers Claude's OWN native wait-and-auto-resume, which preserves in-progress work and
# continues with full context — strictly better than the watcher firing `claude --continue` at a
# (possibly-misparsed) reset time INTO a still-menu-parked pane. `herdr pane send-keys <pane> <key…>`
# lets us pick option 2 by sending Down then Enter.
#
# DEFENSIVE / ADDITIVE by construction — the send-keys key vocabulary is UNVERIFIED against a live
# limit-park (no park to test yet):
#   • VERIFY it took — after sending the keys, re-read the pane and confirm the menu text is GONE.
#   • BOUNDED — a couple of attempts, then give up.
#   • FALLBACK — the EXISTING scheduled `claude --continue` backstop (_resume_builder) is NEVER
#     removed; on any send-keys failure the caller simply lets it run, so worst case = today.
# HERD_LIMIT_MENU_SELECT=off is a kill-switch that skips the clean path entirely (straight to backstop).

# sendkeys_state <slug> — recorded clean-select outcome (cleared|fallback), or empty when none.
sendkeys_state() {
  [ -s "$SENDKEYS_STATE" ] || return 0
  awk -v s="$1" '$1==s{st=$3} END{if(st)print st}' "$SENDKEYS_STATE" 2>/dev/null || true
}
# record_sendkeys <slug> <epoch> <state> — upsert (drop any prior line for this slug first).
record_sendkeys() {
  local _sk_tmp="${SENDKEYS_STATE}.$$"
  { [ -f "$SENDKEYS_STATE" ] && grep -v "^$1 " "$SENDKEYS_STATE" 2>/dev/null
    printf '%s %s %s\n' "$1" "$2" "$3"
  } > "$_sk_tmp" 2>/dev/null && mv "$_sk_tmp" "$SENDKEYS_STATE" 2>/dev/null || rm -f "$_sk_tmp" 2>/dev/null
}
# clear_sendkeys <slug> — drop the slug's clean-select record (park fully resolved / session working).
clear_sendkeys() {
  [ -s "$SENDKEYS_STATE" ] || return 0
  local _cs_tmp="${SENDKEYS_STATE}.$$"
  grep -v "^$1 " "$SENDKEYS_STATE" 2>/dev/null > "$_cs_tmp"
  mv "$_cs_tmp" "$SENDKEYS_STATE" 2>/dev/null || rm -f "$_cs_tmp" 2>/dev/null
}

# _limit_menu_keys — the menu-select key tokens (space-separated). Default "Down Enter" selects
# option 2 ("Stop and wait for limit to reset") and confirms it. Kept EASILY ADJUSTABLE: override via
# HERD_LIMIT_MENU_KEYS (e.g. "Down Return") without a code edit, in case a live park reveals the TUI
# wants a different key name — the vocabulary is UNVERIFIED until a real limit-park confirms it.
_limit_menu_keys() { printf '%s' "${HERD_LIMIT_MENU_KEYS:-Down Enter}"; }

# _pane_shows_limit_menu <pane_id> — true iff the pane's visible content STILL shows the usage-limit
# arrow-menu ("Upgrade your plan" / "Stop and wait for limit to reset"). Reads the pane via
# `herdr pane read`. FAILS SAFE: an empty read (herdr absent, no such pane, capture failed) is treated
# as "menu still present" (return 0) so we NEVER falsely declare the clean select a success on no
# evidence — the caller then keeps the backstop.
_pane_shows_limit_menu() {
  local _pm_pane="$1" _pm_txt
  _pm_txt="$(herd_driver_read_pane "$_pm_pane" visible)"
  [ -n "$_pm_txt" ] || return 0   # no evidence → assume still parked (fail safe)
  printf '%s' "$_pm_txt" | grep -qiE 'Upgrade your plan|Stop and wait|(wait for|reset) .*limit|limit to reset'
}

# _try_clean_limit_menu_select <slug> <worktree> [pane_id] — the CLEAN limit-resume path. Sends the
# menu-select keystrokes (Down, Enter) via `herdr pane send-keys` to pick "Stop and wait for limit to
# reset" — handing the wait to Claude's NATIVE auto-resume — then VERIFIES the menu is gone by
# re-reading the pane. Bounded to a couple of attempts. Returns 0 iff the menu is confirmed GONE;
# 1 otherwise (caller keeps / falls back to the existing _resume_builder backstop). Never itself
# schedules or clears the limit ledger — purely the keystroke+verify step.
_try_clean_limit_menu_select() {
  local _cs_slug="$1" _cs_wt="$2" _cs_pane="${3:-}"
  [ "${HERD_LIMIT_MENU_SELECT:-on}" != "off" ] || return 1   # kill-switch → straight to backstop
  # Headless has no pane to drive the arrow-menu — go straight to the _resume_builder backstop
  # (claude --continue), which needs no keystrokes. The clean-select path is a herdr-pane concept.
  if [ "$(herd_driver_name)" = "headless" ]; then return 1; fi
  command -v herdr >/dev/null 2>&1 || return 1
  [ -n "$_cs_pane" ] || _cs_pane="$(_find_builder_pane_id_any "$_cs_slug")"
  [ -n "$_cs_pane" ] || return 1
  local _cs_keys _cs_max _cs_i
  # shellcheck disable=SC2206
  read -r -a _cs_keys <<<"$(_limit_menu_keys)"
  [ "${#_cs_keys[@]}" -gt 0 ] || return 1
  _cs_max="${HERD_LIMIT_MENU_ATTEMPTS:-2}"; case "$_cs_max" in ''|*[!0-9]*) _cs_max=2 ;; esac
  for (( _cs_i=1; _cs_i<=_cs_max; _cs_i++ )); do
    herd_driver_send_keys "$_cs_pane" "${_cs_keys[@]}"
    if ! _pane_shows_limit_menu "$_cs_pane"; then
      journal_append limit_menu_selected slug "$_cs_slug" pane "$_cs_pane" keys "$(_limit_menu_keys)" attempt "$_cs_i"
      return 0
    fi
  done
  journal_append limit_menu_select_failed slug "$_cs_slug" pane "$_cs_pane" keys "$(_limit_menu_keys)" attempts "$_cs_max"
  return 1
}

# _handle_limit_blocked <slug> <worktree> <idx> <reset-epoch> — surface + schedule + (at the reset)
# perform the auto-resume for ONE limit-blocked builder. Sets DISPLAY[idx]. The row is a distinct,
# NON-RED "limit-hit · auto-resume at HH:MM" — a usage-limit pause is an expected account-wide event,
# not a code fault or a stall, so it must never read as a red alarm. Mirrors _handle_block_verdict's
# shape (record-before-act, journal both sides, escalate loudly on failure).
_handle_limit_blocked() {
  local _lb_slug="$1" _lb_wt="$2" _lb_idx="$3" _lb_reset="${4:-0}"
  local _lb_sl _lb_state _lb_now _lb_target
  _lb_sl="$(_slug_cell "$_lb_slug")"
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
    # CLEAN PATH (preferred, additive): the pane is parked at the limit menu right now — try picking
    # "Stop and wait for limit to reset" via send-keys so Claude's NATIVE auto-resume handles the wait.
    # Attempted ONCE per park; the scheduled `claude --continue` backstop above stays in place, so on
    # failure we simply degrade to today's behavior (see the reset-reached branch's working-guard).
    if [ -z "$(sendkeys_state "$_lb_slug")" ]; then
      if _try_clean_limit_menu_select "$_lb_slug" "$_lb_wt"; then
        record_sendkeys "$_lb_slug" "$_lb_now" "cleared"
      else
        record_sendkeys "$_lb_slug" "$_lb_now" "fallback"
      fi
    fi
  fi

  # A prior failed attempt stays escalated — never re-attempt every tick.
  if [ "$_lb_state" = "failed" ]; then
    DISPLAY[_lb_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_RED}needs you · limit-resume failed · check pane${C_RESET}"
    return 0
  fi

  _lb_target="$(limit_target_epoch "$_lb_slug")"
  if [ "$_lb_now" -lt "$_lb_target" ] 2>/dev/null; then
    # Waiting for the reset: distinct cyan hold row (NOT a red/stall row). When the clean menu-select
    # took, say so — Claude's native auto-resume is driving the wait, not our scheduled backstop.
    if [ "$(sendkeys_state "$_lb_slug")" = "cleared" ]; then
      DISPLAY[_lb_idx]="    ${C_CYAN}⏳${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_CYAN}limit-hit · native auto-resume (backstop $(_fmt_hhmm "$_lb_target"))${C_RESET}"
    else
      DISPLAY[_lb_idx]="    ${C_CYAN}⏳${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_CYAN}limit-hit · auto-resume at $(_fmt_hhmm "$_lb_target")${C_RESET}"
    fi
    return 0
  fi

  # Reset reached (+buffer). If the agent is ALREADY working, a resume already took hold — Claude's
  # native auto-resume from the earlier clean menu-select, or a human — so do NOT fire a second
  # `claude --continue` into a live session. Treat it as resolved and clear the ledgers.
  if [ "$(_agent_status "$_lb_slug")" = "working" ]; then
    journal_append limit_resume_result slug "$_lb_slug" woke 1 escalated false reason native_or_manual
    clear_limit "$_lb_slug" "$_lb_wt"; clear_sendkeys "$_lb_slug"
    DISPLAY[_lb_idx]="    ${C_GREEN}↻${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_GREEN}resumed (native auto-resume)${C_RESET}"
    return 0
  fi

  # Otherwise the backstop: resume in place now via `claude --continue`.
  DISPLAY[_lb_idx]="    ${C_CYAN}↻${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_CYAN}limit reset · resuming via --continue…${C_RESET}"
  render
  local _lb_pane
  _lb_pane="$(_find_builder_pane_id_any "$_lb_slug")"
  journal_append limit_resume_attempt slug "$_lb_slug" pane "${_lb_pane:-none}" target "$_lb_target"
  if [ -n "$_lb_pane" ] && _resume_builder "$_lb_slug" "$_lb_wt" "$_lb_pane"; then
    journal_append limit_resume_result slug "$_lb_slug" woke 1 escalated false
    clear_limit "$_lb_slug" "$_lb_wt"; clear_sendkeys "$_lb_slug"
    DISPLAY[_lb_idx]="    ${C_GREEN}↻${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_GREEN}resumed via --continue${C_RESET}"
  else
    record_limit "$_lb_slug" "$_lb_now" "$_lb_target" "failed"
    journal_append limit_resume_result slug "$_lb_slug" woke 0 escalated true
    DISPLAY[_lb_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_RED}needs you · limit-resume failed · check pane${C_RESET}"
  fi
  return 0
}

# ── Coordinator watchdog (OPT-IN: COORDINATOR_WATCHDOG=on; DEFAULT off ⇒ byte-inert) ─────────────
# The builder auto-resume path above revives a limit-parked BUILDER, but the COORDINATOR
# (coordinator.sh → plain `claude --model … /coordinator`, running from $MAIN) gets no such coverage:
# the tick's feature-worktree loop excludes $MAIN, so a limit-parked or dead coordinator is NEVER
# seen or revived — the self-resume paradox (a paused session cannot resume itself; only a detached
# process like this watcher can). coordinator.sh now installs the same rate_limit hook the builders
# get, so a limit-hit coordinator writes $MAIN/.herd-limit-sentinel; this watchdog consumes it.
#
# ACTIVATION IS A DELIBERATE OPERATOR STEP: the entire path below is gated on COORDINATOR_WATCHDOG=on
# AND requires restarting the watcher (config is read at launch). When the flag is off/unset (the
# default), _handle_coordinator_watchdog returns before doing ANYTHING — no herdr call, no ledger
# write, no relaunch — so merging this feature is completely inert until a user opts in.
#
# FAIL-SAFE by construction (mirrors _handle_limit_blocked / _resume_builder):
#   • CONFIRM before acting — relaunch ONLY a coordinator whose agent is NOT 'working' AND that shows
#     a real limit signal (sentinel/banner via _detect_limit_hit). A 'working' coordinator is never
#     touched (and any stale record is dropped); a merely-idle coordinator with no limit signal is
#     left alone (blind-resuming a healthy idle session is exactly the untested auto-recovery we
#     refuse). An existing scheduled record keeps the resume alive across ticks after the signal clears.
#   • NEVER double-launch — the relaunch is guarded by an atomic-mkdir launch lock keyed by the same
#     WORKSPACE_NAME slug as the watcher's own singleton lock, so a concurrent coordinator.sh relaunch
#     (or a stray second watcher) can never fire a second `claude --continue` at the same pane.
#   • BOUND retries then escalate — _resume_builder retries the submit once internally; a resume that
#     still fails flips the record to `failed` (no re-attempt on later ticks) and escalates via a
#     notification. Never loops.
# The limit ledger is keyed by $HERD_AGENT_COORDINATOR (a singleton name that can never collide with a
# feature slug), reusing the tested record_limit/limit_state/limit_target_epoch/clear_limit helpers.

# Launch lock dir — mirrors the watcher's WORKSPACE_NAME-keyed singleton lock path (HERD_WATCHER_LOCK)
# so exactly one coordinator relaunch can be in flight at a time.
COORD_LAUNCH_LOCK="${HERD_WATCHER_LOCK%.pid}.coordinator-launch.d"

# _coordinator_pane_id — pane_id of the coordinator agent when it is NOT 'working' (resuming a live
# session would double-drive it); empty when the agent is absent or working. Reuses the same
# any-status-but-working lookup the limit/refix resume paths use for builders.
_coordinator_pane_id() { _find_builder_pane_id_any "$HERD_AGENT_COORDINATOR"; }

# _coordinator_launch_lock_acquire / _release — atomic-mkdir mutex held ONLY across the relaunch
# instant. acquire returns 0 iff it took the lock. A lock left behind by a watcher that crashed
# mid-relaunch (older than the reap window) is reclaimed once so the watchdog never wedges forever.
_coordinator_launch_lock_acquire() {
  mkdir "$COORD_LAUNCH_LOCK" 2>/dev/null && return 0
  # Stale lock reap: only if the dir has not been touched within the reap window (~2 min).
  if [ -z "$(find "$COORD_LAUNCH_LOCK" -prune -mmin -2 2>/dev/null)" ]; then
    rmdir "$COORD_LAUNCH_LOCK" 2>/dev/null || true
    mkdir "$COORD_LAUNCH_LOCK" 2>/dev/null && return 0
  fi
  return 1
}
_coordinator_launch_lock_release() { rmdir "$COORD_LAUNCH_LOCK" 2>/dev/null || true; }

# _handle_coordinator_watchdog — ONE per-tick coordinator-liveness step. No DISPLAY row (the
# coordinator is not a feature worktree); it works quietly via the journal + a notification on
# resume/escalation. Returns immediately unless COORDINATOR_WATCHDOG=on.
_handle_coordinator_watchdog() {
  [ "${COORDINATOR_WATCHDOG:-off}" = "on" ] || return 0
  local _cw_status _cw_reset _cw_hit _cw_now _cw_state _cw_target _cw_pane
  _cw_status="$(_agent_status "$HERD_AGENT_COORDINATOR")"

  # FAIL-SAFE #1: a 'working' coordinator is healthy — NEVER touch it. Drop any stale record+sentinel
  # (a human intervened, or a prior scheduled resume flipped it back to working). Journal the drop as
  # a self-resolved outcome ONLY when a record actually existed — a bare healthy tick (no ledger row)
  # must stay silent so the journal isn't flooded on every normal poll.
  if [ "$_cw_status" = "working" ]; then
    if [ -n "$(limit_state "$HERD_AGENT_COORDINATOR")" ]; then
      clear_limit "$HERD_AGENT_COORDINATOR" "$MAIN"
      journal_append coordinator_watchdog agent "$HERD_AGENT_COORDINATOR" outcome self-resolved phase pre-schedule
    fi
    # The coordinator name is a SINGLETON reused across parks, so a stale clean-select record must be
    # dropped the moment it is back to working — otherwise it would gate a future park's clean attempt.
    clear_sendkeys "$HERD_AGENT_COORDINATOR"
    return 0
  fi

  # FAIL-SAFE #2: CONFIRM the limit park before acting. Require a real limit signal on the
  # coordinator's repo ($MAIN) — sentinel (primary) or banner scrape (fallback). With no signal AND
  # no existing scheduled record, do nothing: a non-working coordinator with no limit signal is just
  # idle-waiting for the user, not a fault. An existing record keeps the scheduled resume alive.
  if _cw_reset="$(_detect_limit_hit "$HERD_AGENT_COORDINATOR" "$MAIN")"; then _cw_hit=1; else _cw_hit=0; fi
  _cw_state="$(limit_state "$HERD_AGENT_COORDINATOR")"
  { [ "$_cw_hit" = "1" ] || [ -n "$_cw_state" ]; } || return 0

  _cw_now="$(_now)"
  # First sighting → record + journal the hold and compute the resume target once (mirrors builders).
  if [ -z "$_cw_state" ]; then
    if [ "${_cw_reset:-0}" -gt 0 ] 2>/dev/null; then
      _cw_target=$(( _cw_reset + $(_limit_buffer_secs) ))
    else
      _cw_target=$(( _cw_now + $(_limit_unknown_wait) ))
    fi
    record_limit "$HERD_AGENT_COORDINATOR" "$_cw_now" "$_cw_target" "scheduled"
    journal_append coordinator_limit_detected agent "$HERD_AGENT_COORDINATOR" reset_at "${_cw_reset:-0}" resume_at "$_cw_target"
    journal_append coordinator_resume_scheduled agent "$HERD_AGENT_COORDINATOR" resume_at "$_cw_target"
    _cw_state="scheduled"
    # CLEAN PATH (preferred, additive): the coordinator pane is parked at the limit menu right now —
    # try picking "Stop and wait for limit to reset" via send-keys so Claude's NATIVE auto-resume
    # handles the wait. Attempted ONCE per park; the scheduled `claude --continue` backstop stays in
    # place (the working-check at the top of this function short-circuits it if native resume wins).
    if [ -z "$(sendkeys_state "$HERD_AGENT_COORDINATOR")" ]; then
      if _try_clean_limit_menu_select "$HERD_AGENT_COORDINATOR" "$MAIN" "$(_coordinator_pane_id)"; then
        record_sendkeys "$HERD_AGENT_COORDINATOR" "$_cw_now" "cleared"
        journal_append coordinator_limit_menu_selected agent "$HERD_AGENT_COORDINATOR" keys "$(_limit_menu_keys)"
      else
        record_sendkeys "$HERD_AGENT_COORDINATOR" "$_cw_now" "fallback"
      fi
    fi
  fi

  # A prior failed attempt stays escalated — never re-attempt every tick (bounded-retry-then-escalate).
  [ "$_cw_state" = "failed" ] && return 0

  _cw_target="$(limit_target_epoch "$HERD_AGENT_COORDINATOR")"
  # Still before the reset (+buffer) → hold; nothing to do this tick.
  [ "$_cw_now" -lt "$_cw_target" ] 2>/dev/null && return 0

  # TARGET REACHED — re-check the coordinator's LIVE status BEFORE touching anything. A scheduled
  # resume can be reached long after the sentinel was written; in the meantime the coordinator may
  # already be back (Claude's native auto-resume via the clean-menu path, a human `claude --continue`,
  # or a stale/transient sentinel that never reflected a real park). FAIL-SAFE #3: a coordinator that
  # is WORKING at target is HEALTHY and SELF-RESOLVED — the relaunch invariant already forbids driving
  # it (_coordinator_pane_id is empty for a working agent), so the old code fell straight through the
  # `-n "$_cw_pane"` guard into the `failed` branch: it recorded 'failed' and fired a spurious
  # "resume by hand" alarm on a healthy session (LIVE 2026-07-04, issue #135). Instead clear the
  # ledger record + sentinel SILENTLY, journal the self-resolved outcome, and send NO notification.
  _cw_status="$(_agent_status "$HERD_AGENT_COORDINATOR")"
  journal_append coordinator_watchdog_target_check agent "$HERD_AGENT_COORDINATOR" status "${_cw_status:-unknown}" target "$_cw_target"
  if [ "$_cw_status" = "working" ]; then
    clear_limit "$HERD_AGENT_COORDINATOR" "$MAIN"; clear_sendkeys "$HERD_AGENT_COORDINATOR"
    journal_append coordinator_watchdog agent "$HERD_AGENT_COORDINATOR" outcome self-resolved target "$_cw_target"
    return 0
  fi

  # Genuinely not working at target → resume in place now, under the launch lock so we NEVER double-launch.
  _coordinator_launch_lock_acquire || return 0   # another relaunch already in flight → skip this tick
  _cw_pane="$(_coordinator_pane_id)"
  journal_append coordinator_resume_attempt agent "$HERD_AGENT_COORDINATOR" pane "${_cw_pane:-none}" target "$_cw_target"
  if [ -n "$_cw_pane" ] && _resume_builder "$HERD_AGENT_COORDINATOR" "$MAIN" "$_cw_pane"; then
    journal_append coordinator_resume_result agent "$HERD_AGENT_COORDINATOR" woke 1 escalated false
    clear_limit "$HERD_AGENT_COORDINATOR" "$MAIN"; clear_sendkeys "$HERD_AGENT_COORDINATOR"
    herd_driver_notify "🛰 coordinator resumed" \
      "coordinator limit reset — resumed in place via claude --continue" default
  else
    record_limit "$HERD_AGENT_COORDINATOR" "$_cw_now" "$_cw_target" "failed"
    journal_append coordinator_resume_result agent "$HERD_AGENT_COORDINATOR" woke 0 escalated true
    herd_driver_notify "🛰 coordinator resume FAILED" \
      "coordinator did not wake after the limit reset — resume by hand (claude --continue in the coordinator pane)" default
  fi
  _coordinator_launch_lock_release
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

# ── Dead-builder detection (pre-PR liveness reconciliation) ──────────────────────────────────────
# The stall ladder above only classifies a builder that is WORKING-but-not-progressing, and
# _sweep_orphan_tabs only reaps a tab whose worktree is GONE. Neither catches a builder whose agent
# has VANISHED from `herdr agent list` while its worktree STILL EXISTS and it opened NO PR — a
# silently-DEAD pre-PR builder (REAL INCIDENT 2026-07-03: a spawned builder's agent exited, its pane
# was destroyed, it made no commits and opened no PR, and nothing surfaced it until a human noticed
# the empty tab).
#
# This reconciliation cross-checks, per active feature worktree slug: {is there a live agent record?
# is there an open PR? recent transcript growth?} and classifies DEAD only when the FULL signature
# holds (worktree present + NO live agent + NO open PR + no transcript growth) AND has PERSISTED past
# a grace window. Detection + LOUD surfacing ONLY — it never auto-respawns (uncommitted-work and
# respawn-loop edge cases are a noted follow-up); it paints a distinct 💀 row + fires one notification.
#
# FALSE-POSITIVE GUARDS: a present agent record (ANY status — the agent is still listed) is a
# liveness signal, so a builder that finished and went 'done' is ALIVE, not dead; an open PR is a
# liveness signal (a builder that legitimately opened its PR is ALIVE); a growing transcript vetoes
# death; and the grace window + cross-tick persistence keep a just-spawned builder (agent not yet
# registered) or a one-tick blip in `herdr agent list` from ever being falsely reaped.

# _dead_grace_secs — how long the DEAD signature must persist before a slug is surfaced as dead.
# Configurable via DEAD_GRACE_MIN (minutes); non-numeric/unset falls back to 2 minutes — long enough
# to cover a slow spawn-to-agent-register gap, short enough that a real death surfaces promptly.
_dead_grace_secs() {
  case "${DEAD_GRACE_MIN:-}" in
    ''|*[!0-9]*) printf '%s' 120 ;;
    *)           printf '%s' $(( DEAD_GRACE_MIN * 60 )) ;;
  esac
}

# dead_first_seen <slug> — echo the recorded first-seen epoch for this slug's DEAD signature, or
# nothing when there is no active record.
dead_first_seen() {
  [ -s "$DEAD_STATE" ] || return 0
  awk -v s="$1" '$1==s{f=$2} END{if(f!="")print f}' "$DEAD_STATE" 2>/dev/null || true
}
# dead_notified <slug> — true iff a 💀 notification has already fired for this slug's current record
# (dedup guard, so a persistently-dead builder notifies exactly once, not every tick).
dead_notified() {
  [ -s "$DEAD_STATE" ] || return 1
  local st; st="$(awk -v s="$1" '$1==s{st=$3} END{print st}' "$DEAD_STATE" 2>/dev/null)"
  [ "$st" = "notified" ]
}
# _dead_upsert <slug> <first-seen> <state> — drop any prior line for this slug, append the fresh one
# (temp+mv), mirroring record_limit's upsert.
_dead_upsert() {
  local _du_tmp="${DEAD_STATE}.$$"
  { [ -f "$DEAD_STATE" ] && grep -v "^$1 " "$DEAD_STATE" 2>/dev/null
    printf '%s %s %s\n' "$1" "$2" "$3"
  } > "$_du_tmp" 2>/dev/null && mv "$_du_tmp" "$DEAD_STATE" 2>/dev/null || rm -f "$_du_tmp" 2>/dev/null
}
# record_dead_seen <slug> <epoch> — first sighting of the signature: record the anchor epoch, pending.
record_dead_seen() { _dead_upsert "$1" "$2" pending; }
# record_dead_notified <slug> — flip the record to notified, PRESERVING its original first-seen epoch.
record_dead_notified() { local _rn_f; _rn_f="$(dead_first_seen "$1")"; _dead_upsert "$1" "${_rn_f:-$(_now)}" notified; }
# clear_dead <slug> — drop the slug's record (a liveness signal returned; it is no longer dead).
clear_dead() {
  [ -s "$DEAD_STATE" ] || return 0
  local _cd_tmp="${DEAD_STATE}.$$"
  grep -v "^$1 " "$DEAD_STATE" 2>/dev/null > "$_cd_tmp"
  mv "$_cd_tmp" "$DEAD_STATE" 2>/dev/null || rm -f "$_cd_tmp" 2>/dev/null
}

# _classify_dead_builder <has-agent> <has-pr> <transcript-growing> <first-seen> <now> <grace> — the
# pure verdict for a PR-less builder. Echoes exactly one token:
#   ALIVE   — a liveness signal is present (live agent record, open PR, OR growing transcript) ⇒
#             not dead; the caller clears any record
#   PENDING — the full DEAD signature holds but has NOT yet persisted past <grace> (no prior
#             first-seen, or now - first-seen < grace) ⇒ hold, do not surface yet
#   DEAD    — the DEAD signature has held continuously past the grace window ⇒ surface 💀 + notify
# <has-agent>/<has-pr> are "1"/"0"; <transcript-growing> is yes|no|unknown (only "yes" is a signal);
# <first-seen> is the recorded anchor epoch (empty when the signature is being seen for the first time).
_classify_dead_builder() {
  local has_agent="${1:-0}" has_pr="${2:-0}" tgrow="$3" first_seen="$4" now="${5:-0}" grace="${6:-0}"
  # Any positive liveness signal ⇒ NOT a dead builder.
  if [ "$has_agent" = "1" ] || [ "$has_pr" = "1" ] || [ "$tgrow" = "yes" ]; then
    printf 'ALIVE'; return 0
  fi
  # Full dead signature. Require it to persist past the grace window before surfacing, so a just-
  # spawned builder whose agent has not registered yet — or a one-tick blip — is held as PENDING.
  if [ -z "$first_seen" ] || [ "$(( now - first_seen ))" -lt "$grace" ]; then
    printf 'PENDING'; return 0
  fi
  printf 'DEAD'
}

# _reconcile_dead_builder <slug> <worktree> <agent-status> — drive the ledger + notification for ONE
# PR-less, non-working builder and echo the verdict (ALIVE | PENDING | DEAD). Called from the tick's
# no-PR/non-working branch: an EMPTY agent-status means the slug has NO agent record at all (the dead
# signature); a non-empty status means the agent is still listed (idle/done) and therefore alive.
# has_pr is 0 here by construction (the caller only reaches this on a PR-less slug). Records the
# first-seen anchor on the first sighting, clears it the instant any liveness signal returns, and
# fires exactly one 💀 notification (+ journal event) when a slug crosses into DEAD.
_reconcile_dead_builder() {
  local _rd_slug="$1" _rd_wt="$2" _rd_astatus="$3"
  local _rd_now _rd_grace _rd_has_agent _rd_tgrow _rd_first _rd_verdict
  _rd_now="$(_now)"
  _rd_grace="$(_dead_grace_secs)"
  # A present agent record (any status) means the agent is still listed ⇒ alive.
  [ -n "$_rd_astatus" ] && _rd_has_agent=1 || _rd_has_agent=0
  # Transcript growth is a one-way liveness veto (mirrors the stall ladder); a dead agent's
  # transcript is flat. Reuses the shared cache; "yes" only ever rescues, never fabricates a death.
  _rd_tgrow="$(_transcript_growing "$_rd_slug" "$(_transcript_obs "$_rd_wt")" "$_rd_now" "$_rd_grace")"
  _rd_first="$(dead_first_seen "$_rd_slug")"
  _rd_verdict="$(_classify_dead_builder "$_rd_has_agent" 0 "$_rd_tgrow" "${_rd_first:-}" "$_rd_now" "$_rd_grace")"
  case "$_rd_verdict" in
    ALIVE)
      [ -n "$_rd_first" ] && clear_dead "$_rd_slug" ;;
    PENDING)
      [ -n "$_rd_first" ] || record_dead_seen "$_rd_slug" "$_rd_now" ;;
    DEAD)
      if ! dead_notified "$_rd_slug"; then
        record_dead_notified "$_rd_slug"
        journal_append builder_dead slug "$_rd_slug" first_seen "${_rd_first:-$_rd_now}"
        herd_driver_notify "💀 builder died: ${_rd_slug}" \
          "${_rd_slug}: agent vanished (no agent, no PR) — re-spawn" default
        # Bounded, opt-in AUTO-RESPAWN fires exactly here — once per DEAD crossing (guarded by the
        # dead_notified dedup), AFTER the unconditional 💀 surface. Byte-inert when the flag is off.
        _maybe_autorespawn_dead_builder "$_rd_slug" "$_rd_wt" >/dev/null
      fi ;;
  esac
  printf '%s' "$_rd_verdict"
}

# ── Dead-builder AUTO-RESPAWN (bounded, opt-in) ──────────────────────────────────────────────────
# Follow-up to the dead-builder DETECT+SURFACE above (PR #117 shipped detection only). When a slug
# crosses into DEAD and DEAD_BUILDER_AUTORESPAWN is opted in, surgically restart a FRESH agent in the
# EXISTING worktree pointed at the SAME $WORKTREES_DIR/<slug>.task.md — but only when it is SAFE and
# BOUNDED. Three invariants, each independently guarded so the feature can never destroy work or loop:
#   • DEFAULT OFF — byte-inert until opted in. _maybe_autorespawn_dead_builder early-returns when the
#     flag is off (no ledger, no git probe, no extra notification), so the off-path is exactly today's
#     detect+surface behavior.
#   • NEVER blow away work — respawn ONLY when the worktree has NO commits ahead of base AND no
#     staged/unstaged/untracked changes. A dead builder that produced ANYTHING escalates (surfaced,
#     never restarted-over) so a human can recover it.
#   • AT MOST ONCE per slug — the $DEAD_RESPAWN_STATE ledger records each respawn keyed by slug; a
#     slug that dies AGAIN after its one respawn escalates and is never respawned a second time.
# The respawn is SURGICAL — it reuses the herd-feature spawn pattern (a fresh herdr tab rooted in the
# worktree + `herdr agent start … claude "<pointer>"`) but does NOT re-run the lane: no new
# worktree/branch (new-feature.sh), no app-preview pane. The pointer mirrors herd_write_task_spec's
# (the spec file already exists on disk; we only re-point a fresh agent at it, never rewrite it).

# _dead_autorespawn_on — true iff DEAD_BUILDER_AUTORESPAWN opts in. DEFAULT OFF: only on|true|yes|1
# enable it; unset, "off", or any other value stays off (the byte-inert default).
_dead_autorespawn_on() {
  case "${DEAD_BUILDER_AUTORESPAWN:-off}" in
    on|true|yes|1) return 0 ;;
    *)             return 1 ;;
  esac
}

# respawn_recorded <slug> — true iff this slug has already been auto-respawned once (its at-most-once
# budget is spent). Reads the $DEAD_RESPAWN_STATE ledger.
respawn_recorded() {
  [ -s "$DEAD_RESPAWN_STATE" ] || return 1
  awk -v s="$1" '$1==s{f=1} END{exit f?0:1}' "$DEAD_RESPAWN_STATE" 2>/dev/null
}
# record_respawn <slug> <epoch> <state> — append a ledger line (state ∈ respawned | escalated).
# Append-only; a slug is looked up by presence, so the FIRST respawned line is the budget marker.
record_respawn() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$DEAD_RESPAWN_STATE" 2>/dev/null || true; }

# _worktree_has_work <worktree> — true iff the worktree holds work we must NEVER blow away: either
# commits ahead of the base branch OR a dirty tree (staged/unstaged/untracked). A git failure is
# treated as "has work" (fail SAFE — never respawn over a tree we could not inspect).
_worktree_has_work() {
  local _hw_wt="$1" _hw_commits
  _hw_commits="$(git -C "$_hw_wt" rev-list HEAD --count --not "$DEFAULT_BRANCH" 2>/dev/null)" || return 0
  case "$_hw_commits" in ''|*[!0-9]*) _hw_commits=0 ;; esac
  [ "$_hw_commits" -gt 0 ] && return 0
  [ -n "$(git -C "$_hw_wt" status --porcelain 2>/dev/null)" ] && return 0
  return 1
}

# _classify_respawn <autorespawn-on:0|1> <has-work:0|1> <already-respawned:0|1> — the PURE verdict for
# a slug that has just crossed into DEAD. Echoes exactly one token:
#   OFF          — the flag is off ⇒ do nothing (never respawn; byte-inert)
#   SKIP_ALREADY — the slug already spent its one respawn ⇒ it died AGAIN ⇒ escalate, never re-respawn
#   SKIP_WORK    — the worktree has commits/dirty changes ⇒ escalate, never blow away work
#   RESPAWN      — on + clean worktree + budget unspent ⇒ respawn a fresh agent once
# Order matters: OFF first (nothing else can override the opt-out); then the die-AGAIN check BEFORE
# the work check, so a second death always escalates as "died again" regardless of tree state.
_classify_respawn() {
  local on="${1:-0}" has_work="${2:-0}" already="${3:-0}"
  [ "$on" = "1" ] || { printf 'OFF'; return 0; }
  [ "$already" = "1" ] && { printf 'SKIP_ALREADY'; return 0; }
  [ "$has_work" = "1" ] && { printf 'SKIP_WORK'; return 0; }
  printf 'RESPAWN'
}

# _respawn_builder_in_worktree <slug> <worktree> — surgically restart a FRESH builder agent in the
# EXISTING worktree, pointed at the EXISTING $WORKTREES_DIR/<slug>.task.md. Returns 0 iff a tab AND
# agent were started. Mirrors the herd-feature spawn WITHOUT re-running the lane (no new-feature.sh,
# no app-preview pane). Never invoked under DRYRUN — the caller guards.
_respawn_builder_in_worktree() {
  local _rw_slug="$1" _rw_wt="$2"
  local _rw_spec="$TREES/$_rw_slug.task.md"
  # The builder was spawned against this externalized spec; if it has vanished we cannot re-point a
  # fresh agent at it — bail (the caller escalates rather than respawning against nothing).
  [ -s "$_rw_spec" ] || { printf '⚠️  herdkit: task spec %s missing — cannot auto-respawn %s\n' "$_rw_spec" "$_rw_slug" >&2; return 1; }
  local _rw_model="${HERD_FEATURE_MODEL:-$MODEL_FEATURE}"
  local _rw_flags="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"
  # SHORT pointer prompt — byte-identical to herd_write_task_spec's (the spec is already on disk).
  local _rw_ptr
  _rw_ptr="$(printf 'Read your task spec at %s and build exactly what it specifies. Do not commit that file. Follow AGENTS.md, run the healthcheck, then gh pr create.' "$_rw_spec")"
  # Headless: no tabs/panes — restart a DETACHED agent in the registry via the driver shim. FAILS
  # SOFT (returns non-zero if it cannot start), so the caller's escalation notification still fires.
  if [ "$(herd_driver_name)" = "headless" ]; then
    herd_driver_start_agent "$_rw_slug" "$_rw_wt" "$_rw_model" "$_rw_flags" "$_rw_ptr"
    return $?
  fi
  local _rw_wsid; _rw_wsid="$(herd_resolve_workspace_id 2>/dev/null || true)"
  local _rw_created _rw_tab _rw_root
  _rw_created="$(herdr tab create ${_rw_wsid:+--workspace "$_rw_wsid"} --cwd "$_rw_wt" --label "$_rw_slug" --no-focus 2>/dev/null || true)"
  read -r _rw_tab _rw_root < <(printf '%s' "$_rw_created" | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' 2>/dev/null || true)
  [ -n "$_rw_tab" ] || { printf '⚠️  herdkit: could not create a tab to auto-respawn %s\n' "$_rw_slug" >&2; return 1; }
  # Register in the sweep allowlist so only engine-created tabs are ever swept (mirrors the lane).
  printf '%s %s builder\n' "$_rw_slug" "$_rw_tab" >> "$TREES/.herd-tabs" 2>/dev/null || true
  # shellcheck disable=SC2086  # $_rw_flags intentionally word-splits (mirrors the lane's $CLAUDE_FLAGS).
  herdr agent start "$_rw_slug" ${_rw_wsid:+--workspace "$_rw_wsid"} --cwd "$_rw_wt" --tab "$_rw_tab" --split right --no-focus -- claude --model "$_rw_model" $_rw_flags "$_rw_ptr" >/dev/null 2>&1
}

# _maybe_autorespawn_dead_builder <slug> <worktree> — drive the bounded auto-respawn for ONE slug that
# has just crossed into DEAD. Echoes the verdict (OFF | SKIP_ALREADY | SKIP_WORK | RESPAWN) for tests
# and callers; fires at most one notification (+ journal event) per invocation. Called ONCE per DEAD
# crossing from _reconcile_dead_builder (guarded by the dead_notified dedup).
_maybe_autorespawn_dead_builder() {
  local _ar_slug="$1" _ar_wt="$2" _ar_on=0 _ar_work=0 _ar_done=0 _ar_verdict
  _dead_autorespawn_on && _ar_on=1
  # OFF ⇒ byte-inert: no git probe, no ledger, no extra notification. The 💀 surface already fired.
  [ "$_ar_on" = "1" ] || { printf 'OFF'; return 0; }
  _worktree_has_work "$_ar_wt" && _ar_work=1
  respawn_recorded "$_ar_slug" && _ar_done=1
  _ar_verdict="$(_classify_respawn "$_ar_on" "$_ar_work" "$_ar_done")"
  case "$_ar_verdict" in
    RESPAWN)
      # DRYRUN: log intent, but never spawn or spend the budget (mirrors the watcher's mutation guards).
      if [ -n "${DRYRUN:-}" ]; then
        printf '🐑 (dry-run) would auto-respawn dead builder %s in %s\n' "$_ar_slug" "$_ar_wt" >&2
      elif _respawn_builder_in_worktree "$_ar_slug" "$_ar_wt"; then
        record_respawn "$_ar_slug" "$(_now)" respawned
        journal_append builder_respawned slug "$_ar_slug"
        herd_driver_notify "♻️ builder auto-respawned: ${_ar_slug}" \
          "${_ar_slug}: dead + clean worktree — a fresh agent was restarted in place (once)" default
      else
        journal_append builder_respawn_failed slug "$_ar_slug"
        herd_driver_notify "💀 auto-respawn failed: ${_ar_slug}" \
          "${_ar_slug}: could not start a fresh agent — restart by hand" default
      fi ;;
    SKIP_WORK)
      journal_append builder_dead_has_work slug "$_ar_slug"
      herd_driver_notify "💀 builder died (has work): ${_ar_slug}" \
        "${_ar_slug}: dead but the worktree has commits/uncommitted changes — NOT auto-respawned; recover by hand" default ;;
    SKIP_ALREADY)
      journal_append builder_dead_again slug "$_ar_slug"
      herd_driver_notify "💀 builder died again: ${_ar_slug}" \
        "${_ar_slug}: died again after its one auto-respawn — escalating, will NOT respawn again" default ;;
  esac
  printf '%s' "$_ar_verdict"
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

# ── Cache-hit journal de-dup (HERD-72) ──────────────────────────────────────────────────────────────
# A held/awaiting-verify PR sits on the candidate list every ~6s poll tick with an UNCHANGED head sha,
# so _healthcheck_gate replays the SAME terminal cache hit each tick (20-60 identical
# healthcheck_cache_hit lines per PR measured 2026-07-07). That drowns 'herd why <pr>'. The verdict for
# a fixed sha is terminal and cannot change, so all those repeats carry zero new information.
# Fix: journal the cache hit only on a TRANSITION — the FIRST hit for a (pr,sha) or any change in the
# outcome/detail — and suppress identical repeats. A per-PR marker records the last hit we journaled as
# "<sha>\t<outcome>\t<detail>"; a new commit (different sha) or a changed verdict differs from it and
# re-journals, an identical replay matches and is skipped. Keyed by PR alone, so it self-overwrites (no
# stale-marker sweep needed). The emitted event's shape/fields are IDENTICAL to the pre-dedup call, so
# 'herd why' / 'herd log' parsing is unaffected — this only removes duplicate lines.
_health_cachehit_file() { printf '%s' "$TREES/.health-cachehit-$1"; }

# _journal_cache_hit <pr#> <slug> <sha> <outcome> [detail] — emit healthcheck_cache_hit ONCE per
# transition (see above). Best-effort like journal_append itself; a marker it cannot write just means
# the next identical hit re-journals (fail toward MORE logging, never toward a broken gate).
_journal_cache_hit() {
  local _jc_pr="$1" _jc_slug="$2" _jc_sha="$3" _jc_outcome="$4" _jc_detail="${5:-}"
  local _jc_marker _jc_cur _jc_prev
  _jc_marker="$(_health_cachehit_file "$_jc_pr")"
  _jc_cur="$_jc_sha"$'\t'"$_jc_outcome"$'\t'"$_jc_detail"
  if [ -f "$_jc_marker" ]; then
    IFS= read -r _jc_prev < "$_jc_marker" 2>/dev/null || _jc_prev=""
    [ "$_jc_prev" = "$_jc_cur" ] && return 0
  fi
  if [ -n "$_jc_detail" ]; then
    journal_append healthcheck_cache_hit pr "$_jc_pr" slug "$_jc_slug" sha "$_jc_sha" outcome "$_jc_outcome" detail "$_jc_detail"
  else
    journal_append healthcheck_cache_hit pr "$_jc_pr" slug "$_jc_slug" sha "$_jc_sha" outcome "$_jc_outcome"
  fi
  printf '%s\n' "$_jc_cur" > "$_jc_marker" 2>/dev/null || true
}

# _health_fail_identity <healthcheck-oneline> — distil WHICH test/step failed from a healthcheck
# --oneline CODE-ERROR line, so a FLAKY run (fail-then-pass) still records its offender before the
# passing retry's output would otherwise be all that survives (HERD-76). The runner only ever
# captures the single --oneline row, so that row IS the failing run's output — this just extracts
# the salient identity from it (no extra suite work, zero gate behavior change):
#   • strip the leading glyph + classifier prefix ("❌ code error — ", "light syntax — ", …) to the
#     failing REASON after the first em-dash;
#   • prefer concrete test/source file token(s) named in that reason (deduped, comma-joined) — the
#     "failed=<file>" the deflake investigation needs;
#   • fall back to the reason text itself (the failing STEP) for a non-test error that names no file.
# Bounded to 200 chars so a pathological reason can never bloat a journal line past PIPE_BUF.
_health_fail_identity() {
  local _hf_line="$1" _hf_reason _hf_files
  _hf_reason="${_hf_line#*— }"                       # everything after the first "— " separator …
  [ "$_hf_reason" = "$_hf_line" ] && _hf_reason="$_hf_line"   # … or the whole line if there is none
  _hf_files="$(printf '%s\n' "$_hf_reason" \
    | grep -oE '[A-Za-z0-9_./-]+\.(sh|bats|py|go|ts|js|jsx|tsx|rs|java|rb)' 2>/dev/null \
    | awk '!seen[$0]++' | paste -sd, - 2>/dev/null)"
  local _hf_id="${_hf_files:-$_hf_reason}"
  # Collapse any stray newlines and trim surrounding whitespace, then cap the length.
  _hf_id="$(printf '%s' "$_hf_id" | tr '\n' ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf '%s' "${_hf_id:0:200}"
}

# record_healthcheck <pr#> <slug> <attempt> <outcome> [failed-identity] — append one attempt to the
# ledger. When the outcome is a code error, [failed-identity] carries WHICH test/step failed (from
# _health_fail_identity) and is journaled as failed=<id> so a later FLAKY-collapsed offender is still
# identifiable. The ledger line is unchanged (5 fields) — identity lives in the journal only.
record_healthcheck() {
  printf '%s %s %s %s %s\n' "$(date +%s)" "$1" "$2" "$3" "$4" >> "$HEALTH_STATE"
  # Journal each attempt: attempt 1 is the initial run, attempt ≥2 is a solo retry-before-red.
  local _rh_event=healthcheck_attempted
  [ "${3:-1}" -le 1 ] 2>/dev/null || _rh_event=healthcheck_retried
  if [ -n "${5:-}" ]; then
    journal_append "$_rh_event" pr "$1" slug "$2" attempt "$3" result "$4" failed "$5"
  else
    journal_append "$_rh_event" pr "$1" slug "$2" attempt "$3" result "$4"
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
  _hg_sl="$(_slug_cell "$_hg_slug")"
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
          _journal_cache_hit "$_hg_pr" "$_hg_slug" "$_hg_sha" CLEAN
          return 0 ;;
        FLAKY)
          DISPLAY[_hg_idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_YELLOW}flaky · infra (passed on retry)${C_RESET}"
          _HC_RESULT="FLAKY"
          _journal_cache_hit "$_hg_pr" "$_hg_slug" "$_hg_sha" FLAKY
          return 0 ;;
        CODEERROR)
          DISPLAY[_hg_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_RED}needs you · ${_hg_cd}${C_RESET}"
          _HC_RESULT="CODEERROR"
          _journal_cache_hit "$_hg_pr" "$_hg_slug" "$_hg_sha" CODEERROR "$_hg_cd"
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
  # Capture WHICH test/step failed NOW, from this attempt's output, BEFORE the retry overwrites it —
  # else a FLAKY collapse (pass on retry) leaves only 'result=code-error' and the offender is lost
  # (HERD-76: this blocked the deflake investigation for #185/#188).
  local _hg_failed; _hg_failed="$(_health_fail_identity "$_hg_hc")"
  record_healthcheck "$_hg_pr" "$_hg_slug" 1 "code-error" "$_hg_failed"
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
    # Carry the offender captured from the FAILING attempt onto the FLAKY outcome — the whole point
    # of HERD-76: a passing retry must not erase which test flaked.
    if [ -n "$_hg_failed" ]; then
      journal_append healthcheck_outcome pr "$_hg_pr" slug "$_hg_slug" outcome FLAKY failed "$_hg_failed"
    else
      journal_append healthcheck_outcome pr "$_hg_pr" slug "$_hg_slug" outcome FLAKY
    fi
    return 0
  fi
  # Reproduced on the solo retry → VERIFIED-REAL code error. Paint red.
  record_healthcheck "$_hg_pr" "$_hg_slug" 2 "code-error" "$(_health_fail_identity "$_hg_hc2")"
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

# ── Spawn-queue drain ────────────────────────────────────────────────────────────────────────────
# _drain_spawn_queue — called once per tick to pop pending spawn intents from the durable queue
# ($WORKTREES_DIR/spawn-queue/) and launch the matching builder lane. Concurrency cap mirrors the
# lane advisory gate: REVIEW_CONCURRENCY + SPAWN_AHEAD total active builders. FEATS (the live
# worktree roster) is computed earlier this tick, so active count is its length.
#
# DURABILITY CONTRACT (review gate, PR #151): an intent is consumed (`done`, rm) ONLY after its
# lane observably spawned. The lane runs in the FOREGROUND with output captured, because the lanes
# have TWO no-builder exits the old backgrounded launch could never see:
#   • the lane's own advisory saturation gate defers with EXIT 0 and the stable marker line
#     'review-gate saturated' (herd_spawn_gate_emit_defer) — a HELD spawn, not a failure: the
#     intent is RELEASED back to .req (spawn-step.sh release) for a later tick, and the drain
#     stops for this tick (siblings would also defer against the same gate);
#   • a hard failure (bad slug, existing worktree, git/network error) exits non-zero — the intent
#     is dropped LOUDLY (skip + journal), never silently.
# Every outcome journals (spawn_launched / spawn_deferred / spawn_skipped) so the next overnight
# post-mortem can answer "why did nothing spawn?" from `herd log` alone.
#
# The task payload is read as the REMAINDER of the claim stream (not one line): task text may be
# multi-line and `read -r` would silently truncate it to its first line before the builder saw it.
#
# Fail-soft: a malformed intent is skipped with a logged warning — never crashes the watcher loop.
# Skipped entirely in dry-run mode (intents remain pending; no lane is spawned).
_drain_spawn_queue() {
  [ -z "${DRYRUN:-}" ] || return 0
  local _dsq_q="$TREES/spawn-queue"
  [ -d "$_dsq_q" ] || return 0
  ls "$_dsq_q"/*.req >/dev/null 2>&1 || return 0   # fast exit when queue is empty

  # Budget = pipeline cap minus currently active worktrees (FEATS already computed this tick).
  local _dsq_cap _dsq_budget
  _dsq_cap=$(( ${REVIEW_CONCURRENCY:-2} + ${SPAWN_AHEAD:-1} ))
  _dsq_budget=$(( _dsq_cap - ${#FEATS[@]} ))
  [ "$_dsq_budget" -le 0 ] && return 0

  local _dsq_n=0
  while [ "$_dsq_n" -lt "$_dsq_budget" ]; do
    # Claim one intent via spawn-step.sh (atomic rename, stale-reclaim, immediate return).
    # Payload lines: slug, lane, tracker ref (HERD-64; empty for an untracked/older intent), then the
    # task as EVERYTHING after them. The ref line is ALWAYS present so this positional read stays fixed.
    local _dsq_line1="" _dsq_slug="" _dsq_lane="" _dsq_ref="" _dsq_task=""
    {
      IFS= read -r _dsq_line1
      IFS= read -r _dsq_slug
      IFS= read -r _dsq_lane
      IFS= read -r _dsq_ref
      _dsq_task="$(cat)"
    } < <(bash "$HERE/spawn-step.sh" next 2>/dev/null || true)

    case "${_dsq_line1:-}" in
      EMPTY|'') break ;;
      CLAIMED*)
        local _dsq_claimed="${_dsq_line1#CLAIMED }"
        # Fail-soft: validate slug and lane before launching.
        if [ -z "$_dsq_slug" ] || [ -z "$_dsq_lane" ]; then
          bash "$HERE/spawn-step.sh" skip "$_dsq_claimed" "empty slug or lane" >/dev/null 2>&1 || true
          journal_append spawn_skipped slug "$_dsq_slug" lane "$_dsq_lane" reason "empty slug or lane"
          _dsq_n=$(( _dsq_n + 1 )); continue
        fi
        case "$_dsq_lane" in
          quick|feature) ;;
          *)
            bash "$HERE/spawn-step.sh" skip "$_dsq_claimed" "unknown lane '$_dsq_lane'" >/dev/null 2>&1 || true
            journal_append spawn_skipped slug "$_dsq_slug" lane "$_dsq_lane" reason "unknown lane"
            _dsq_n=$(( _dsq_n + 1 )); continue ;;
        esac
        # Launch the lane in the FOREGROUND and observe the outcome before consuming the intent.
        # Re-export the threaded tracker ref (HERD-64) as HERD_ITEM_REF so the lane carries it into the
        # PR's 'Refs:' line, the atomic claim (CLAIM_REQUIRED), and its own TRACKED_SPAWNS gate — an
        # intent that spawn.sh accepted as tracked is never re-refused at drain time. Empty ref =
        # unset-equivalent (every consumer tests for non-empty), so untracked intents are unaffected.
        local _dsq_out="" _dsq_rc=0
        if [ "$_dsq_lane" = "feature" ]; then
          _dsq_out="$(HERD_ITEM_REF="$_dsq_ref" bash "$HERE/herd-feature.sh" "$_dsq_slug" "$_dsq_task" 2>&1)" || _dsq_rc=$?
        else
          _dsq_out="$(HERD_ITEM_REF="$_dsq_ref" bash "$HERE/herd-quick.sh" "$_dsq_slug" "$_dsq_task" 2>&1)" || _dsq_rc=$?
        fi
        if [ "$_dsq_rc" -eq 0 ] && printf '%s' "$_dsq_out" | grep -q 'review-gate saturated'; then
          # HELD, not spawned: the lane's advisory gate deferred (exit 0 + marker). Put the intent
          # back for a later tick and stop draining — siblings would defer against the same gate.
          bash "$HERE/spawn-step.sh" release "$_dsq_claimed" >/dev/null 2>&1 || true
          journal_append spawn_deferred slug "$_dsq_slug" lane "$_dsq_lane"
          break
        elif [ "$_dsq_rc" -ne 0 ]; then
          # Hard failure: no builder exists. Drop the intent LOUDLY — skip logs a warning and the
          # journal records why, so a lost spawn is always visible in `herd log`.
          bash "$HERE/spawn-step.sh" skip "$_dsq_claimed" "lane exited $_dsq_rc" >/dev/null 2>&1 || true
          journal_append spawn_skipped slug "$_dsq_slug" lane "$_dsq_lane" reason "lane exited $_dsq_rc"
        else
          # Spawned: only now is the intent consumed.
          bash "$HERE/spawn-step.sh" done "$_dsq_claimed" >/dev/null 2>&1 || true
          journal_append spawn_launched slug "$_dsq_slug" lane "$_dsq_lane"
        fi
        _dsq_n=$(( _dsq_n + 1 ))
        ;;
    esac
  done
}

_ORPHAN_SWEEP_TICK=0
_ORPHAN_SWEEP_INTERVAL=15   # sweep every ~60 s (15 × 4 s sleep)
_TRACKER_SWEEP_TICK=0
_TRACKER_SWEEP_INTERVAL=45  # tracker-state self-heal every ~3 min (45 × 4 s sleep) — cheap + advisory

# One-shot at STARTUP: resume teardown for any worktree whose PR merged but whose reap never ran
# (HERD-91 — the crash-between-merge-and-reap window). Runs once here, BEFORE the live loop, so a
# stranded worktree + idle builder tab is cleaned up on restart rather than lingering forever.
_startup_reap_sweep

while true; do
  build_header
  build_landed
  build_blocked
  build_tracker_drift

  # Fetch open PRs, then apply the configured watcher view (lens + filters). The view is a
  # read-time SELECTION filter only — it narrows which PRs this tick displays/considers and never
  # relaxes any merge gate. Default (all lens, no filters) requests the base fields and passes the
  # JSON through unchanged, preserving today's exact behavior.
  PRS_JSON="$(gh pr list --json "$(_watcher_tick_fields)" 2>/dev/null || echo '[]')"
  PRS_JSON="$(printf '%s' "$PRS_JSON" | _watcher_view_filter)"
  # Builder liveness roster via the active driver: herdr-claude → `herdr agent list`; headless →
  # the detached-agent registry rendered in the same JSON shape. This is what dead-builder
  # reconciliation keys off, so it must reflect real liveness with OR without panes.
  AGENTS_JSON="$(herd_driver_agent_list_json)"
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
    sl="$(_slug_cell "$slug")"
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
          # Not limit-blocked. Distinguish a benign idle agent (still listed in `herdr agent list`,
          # just waiting for a task) from a DEAD builder whose agent has VANISHED from the list while
          # its worktree lives on with no PR. astatus is EMPTY only when the slug has NO agent record
          # at all — the dead signature; a present-but-idle agent keeps a non-empty status. Surface a
          # persistently-dead builder LOUDLY (💀 + notification) so it is never silently lost.
          case "$(_reconcile_dead_builder "$slug" "$dir" "$astatus")" in
            DEAD)
              DISPLAY[i]="    ${C_RED}💀${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_RED}builder died (no agent, no PR) · re-spawn${C_RESET}" ;;
            *)
              DISPLAY[i]="    ${C_BLUE}🔨${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_BLUE}idle · no PR${C_RESET}" ;;
          esac
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
    sl="$(_slug_cell "$slug")"
    pn=" ${C_DIM}#${prnum}${C_RESET} ·"

    # PARALLEL GATE DISPATCH (GATE_DISPATCH=parallel, HERD-73 — opt-in, dormant by default). Kick the
    # pre-merge review off NOW, at the same tick the healthcheck below starts, so the two gates overlap
    # instead of running serially (review only after health lands). Byte-inert under the default serial
    # mode. The merge decision downstream is UNCHANGED — it still requires BOTH the healthcheck AND a
    # review PASS; this only overlaps their wall-clock. See _predispatch_review_if_parallel.
    _predispatch_review_if_parallel "$prnum" "$slug" "$candsha"

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
    # A hold is in effect when the policy holds (approve) OR this PR is human-verify-held AND
    # HUMAN_VERIFY_POLICY still HOLDS (hold|coordinator). Under HUMAN_VERIFY_POLICY=auto (HERD-59) a
    # human-verify PR is NOT held — its declared steps are recorded as informational, then it merges.
    held=""
    if [ "$mode" = "approve" ]; then
      held=1
    elif [ -n "$hv_hold" ] && [ "$HV_POLICY" != "auto" ]; then
      held=1
    fi
    approved=""; approval_is_approved "$prnum" "$rsha" && approved=1

    case "$(_hold_decision "$mode" "$hv_hold" "$approved" "$HV_POLICY")" in
      OBSERVE)
        # observe: run all gates, report + notify once per sha, NEVER merge.
        if ! observe_noted "$prnum" "$rsha"; then
          record_observe_noted "$prnum" "$rsha"
          herd_driver_notify "🐑 PR #${prnum} ready (observe)" "${slug}: review passed — observe mode, not merging" default
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
          if [ "$HV_POLICY" = "coordinator" ] && [ -n "$hv_hold" ]; then
            # HUMAN_VERIFY_POLICY=coordinator: still a hold, but journaled with the policy + surfaced
            # loudly as coordinator-actionable so a coordinator/agent runs the steps then approves.
            journal_append hold_applied pr "$prnum" sha "$rsha" slug "$slug" kind "$hold_kind" human_verify_policy coordinator
            hv_steps="$(pr_human_verify_steps "$prnum")"
            gh pr comment "$prnum" --body "🐑 **herd watch** · all gates passed (healthcheck ✅ · review ✅) — this PR declares manual steps and \`HUMAN_VERIFY_POLICY=coordinator\`, so it is held as **coordinator-actionable**: a coordinator/agent should execute these steps, then approve:

${hv_steps}

Once executed, run \`herd approve ${prnum}\` (or \`bash scripts/herd/herd-approve.sh approve ${prnum}\`) to approve commit \`${rsha:0:8}\` for merge. A new commit re-holds until re-verified." >/dev/null 2>&1 || true
            herd_driver_notify "🐑 PR #${prnum} human-verify — coordinator action needed" "${slug}: gates passed — a coordinator/agent should run the steps then herd approve ${prnum}" default
          elif [ -n "$hv_hold" ]; then
            # HUMAN_VERIFY_POLICY=hold (default): byte-identical to today's per-PR human-verify hold.
            journal_append hold_applied pr "$prnum" sha "$rsha" slug "$slug" kind "$hold_kind"
            hv_steps="$(pr_human_verify_steps "$prnum")"
            gh pr comment "$prnum" --body "🐑 **herd watch** · all gates passed (healthcheck ✅ · review ✅) — but this PR declares manual steps that must be **human-verified** before merge:

${hv_steps}

Once verified, run \`herd approve ${prnum}\` (or \`bash scripts/herd/herd-approve.sh approve ${prnum}\`) to approve commit \`${rsha:0:8}\` for merge. A new commit re-holds until re-verified." >/dev/null 2>&1 || true
            herd_driver_notify "🐑 PR #${prnum} human-verify pending" "${slug}: gates passed — verify manual steps, then herd approve ${prnum}" default
          else
            journal_append hold_applied pr "$prnum" sha "$rsha" slug "$slug" kind "$hold_kind"
            gh pr comment "$prnum" --body "🐑 **herd watch** · all gates passed (healthcheck ✅ · review ✅) · awaiting approval before merge.

Run \`herd approve ${prnum}\` (or \`bash scripts/herd/herd-approve.sh approve ${prnum}\`) to approve commit \`${rsha:0:8}\` for merge." >/dev/null 2>&1 || true
            herd_driver_notify "🐑 PR #${prnum} awaiting approval" "${slug}: gates passed — herd approve ${prnum}" default
          fi
        fi
        DISPLAY[idx]="    ${C_GREEN}✅${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_GREEN}$(_hold_ready_label "$hv_hold" "$prnum" "$HV_POLICY")${C_RESET}"
        render
        continue ;;

      MERGE)
        # HUMAN_VERIFY_POLICY=auto (HERD-59): a PR that declared HUMAN-VERIFY steps merges on green,
        # with the declared steps recorded as INFORMATIONAL — journaled + PR-commented exactly once per
        # sha. The journal line makes it explicit + auditable that the steps were NOT human-executed.
        if [ -n "$hv_hold" ] && [ "$HV_POLICY" = "auto" ] && ! hv_informed_noted "$prnum" "$rsha"; then
          record_hv_informed "$prnum" "$rsha"
          hv_steps="$(pr_human_verify_steps "$prnum")"
          journal_append human_verify_policy pr "$prnum" sha "$rsha" slug "$slug" policy auto action merged-with-declared-steps
          gh pr comment "$prnum" --body "🐑 **herd watch** · \`HUMAN_VERIFY_POLICY=auto\` — this PR declared manual verify steps, treated as **informational** and merged on green gates (healthcheck ✅ · review ✅). These steps were NOT executed before merge:

${hv_steps}

Recorded in the engine journal as \`human_verify_policy=auto merged-with-declared-steps\`." >/dev/null 2>&1 || true
        fi
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
    sl="$(_slug_cell "$slug")"
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

  # Spawn-queue drain: pop pending intents up to the pipeline concurrency cap and launch lanes.
  _drain_spawn_queue

  # Coordinator watchdog: ONE per-tick liveness check of the coordinator itself (which the feature
  # loop above never sees — it runs from $MAIN, not a worktree). Byte-inert unless COORDINATOR_WATCHDOG=on.
  _handle_coordinator_watchdog

  # Orphan sweep: every _ORPHAN_SWEEP_INTERVAL ticks close tabs whose slug is no longer live.
  _ORPHAN_SWEEP_TICK=$((_ORPHAN_SWEEP_TICK + 1))
  if [ "$_ORPHAN_SWEEP_TICK" -ge "$_ORPHAN_SWEEP_INTERVAL" ]; then
    _ORPHAN_SWEEP_TICK=0
    _sweep_orphan_tabs
  fi

  # Tracker-state self-heal (HERD-86): every _TRACKER_SWEEP_INTERVAL ticks re-assert Done for any
  # recently-merged PR whose tracker item drifted (stuck open after merge). Cheap + advisory.
  _TRACKER_SWEEP_TICK=$((_TRACKER_SWEEP_TICK + 1))
  if [ "$_TRACKER_SWEEP_TICK" -ge "$_TRACKER_SWEEP_INTERVAL" ]; then
    _TRACKER_SWEEP_TICK=0
    _sweep_tracker_state
  fi

  sleep 4
done
