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
#   🔀 resolving …     — PR CONFLICTING: auto-spawned the isolated, test-gated conflict resolver
#                       (herd-resolve.sh). Hands-off. "re-resolving (round N)" = a RESPAWN (HERD-55)
#                       after a new commit reshaped the conflict or the prior resolver died.
#   ⚠️ needs you · …   — PR CONFLICTING OR healthcheck returned a CODE error (❌), OR the review
#                       gate returned BLOCK, OR the resolver ran and it's STILL conflicting
#                       ("resolver failed"), OR the resolver ESCALATED a semantically-ambiguous
#                       conflict, OR respawns hit the cap ("resolver gave up"). NEVER auto-merged.
#                       ROW TRUTH (HERD-173): "needs you" means NOBODY is on it — it is never painted
#                       while an agent is actively fixing that red (bounced by the watcher, or manually
#                       re-tasked and reading agent_status=working against the same red sha; those show
#                       "fix in progress · awaiting push (round k/N)"). A needs-you row therefore always
#                       carries both the BLOCKER and the REMEDY: it is real, unclaimed work.
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
# auto-spawns the EXISTING isolated resolver (herd-resolve.sh <slug>), keyed to the head sha. HERD-55
# adds sha-keyed RESPAWN: if a CONFLICTING PR gets a NEW commit (its sha changes → the conflict
# surface changed) OR the dispatched resolver is POSITIVELY DEAD without clearing it, the watcher
# re-dispatches a fresh resolver for the new sha (journaling resolver_respawn). Hard rails:
# (1) respawn budget — dispatches per PR are capped at REFIX_MAX_ROUNDS, then the PR surfaces
# "resolver gave up · needs you" (never an infinite resolver loop); (2) escalation preserved +
# terminal — the resolver aborts + escalates semantically-ambiguous conflicts, and an ESCALATE is
# TERMINAL for that sha (no respawn until a new commit); the watcher NEVER blind-merges;
# (3) HERD-206 POSITIVE-EVIDENCE-ONLY DEATH — "no resolver agent in the roster" is NOT a death
# verdict. A resolver is dead only when the pane process probe says so, or when a roster we could
# actually READ omits it; a fresh resolver is STARTING for its whole grace window, and a blind
# watcher holds. Nothing respawns over, or reaps, a resolver that has not been proven gone.
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
# Supervised-process contract (HERD-193) — owner/deadline/liveness/retire bookkeeping for every
# population this watcher spawns. Pure library; wholly inert while LIFECYCLE_CONTRACTS=off (default).
. "$HERE/lifecycle.sh"
# Engine version handshake (HERD-179) — the staleness predicate behind the quiet 'engine outdated'
# console note (ENGINE_AUTOUPDATE=check|auto) and the quiescent-window auto-update (auto). Sourced
# after journal.sh so its events are journaled; defines functions only, and is wholly inert while
# ENGINE_AUTOUPDATE=off (the ship default) or the project pins no ENGINE_MIN floor.
. "$HERE/engine-version.sh"
# Cross-seat dual-engine safety (HERD-308) — the per-tick pool-level invariant that halts a STALE seat
# writing the same worktree pool as a newer engine (the dual-engine window), plus the P4 migration
# quiesce gate. Sourced after engine-version.sh (it stamps that file's level) and journal.sh (it
# journals mismatches); defines functions only, wholly inert while ENGINE_SEAT_RECONCILE=off (default).
. "$HERE/engine-seat.sh"
# Token/cost accounting (additive + read-only): sums a merged builder's transcript and journals a
# `cost` event so `herd cost` can surface cost-per-merged-PR. Sourced after journal.sh (it calls
# journal_append). Defines functions only; safe to source in lib mode.
[ -f "$HERE/cost.sh" ] && . "$HERE/cost.sh"
# HUMAN-VERIFY parser — the shared convention for the per-PR human-verify hold (sourced, not run).
. "$HERE/human-verify.sh"
# REGENERABLE DERIVED FILES (HERD-214) — the shared list of engine-rendered artifacts (the rendered
# coordinator skill, .herd/config.local) that the reaps and the stale-base gate must never mistake for
# real work. Defines functions + one constant; idempotent when a later source pulls it in again.
. "$HERE/derived-files.sh"
# SHARED WATCHER-IDENTITY CHECK (HERD-266) — watcher_list_mains + the exemption clauses that tell a
# duplicate watcher apart from this watcher's own argv0-inherited forks, plus the self-restart handoff
# marker this file writes (watcher_handoff_begin/_clear). Defines functions + one constant; idempotent.
# shellcheck source=/dev/null
. "$HERE/watcher-exempt.sh"
# STALE-DUPLICATE gate (HERD-188) — the pre-merge check that HOLDS a PR re-implementing already-shipped
# work (duplicate item ref) or sitting on a stale base. Sourcing DEFINES functions only (no CLI); the
# gate is default-on but provable-only + fail-soft, so it never false-holds. Disabled by STALE_DUP_DETECT=off.
. "$HERE/stale-dup-gate.sh"
# GIT-PR work-unit adapter (HERD-398, Phase 3 of docs/spikes/work-unit-abstraction.md) — the
# PR-specific implementations (discovery `gh pr list`, review-dispatch `gh pr diff`, merge actuation
# `gh pr merge` + state-file row, reconcile) MOVED out of this file and behind the WORK_UNIT_KIND
# facade (scripts/herd/work-unit.sh). Sourcing DEFINES functions only (do_merge, reconcile_backlog,
# already_merged, _classify_review_tier, _merge_method_flag, _delete_branch_flag, _reconcile_pr_ref,
# _watcher_tick_fields, _prs_fetch_tick) under the SAME names they always had, so every existing call
# site below is unchanged — this is a pure relocation, not a behavior change.
. "$HERE/work-units/git-pr.sh"
# work-unit FACADE (HERD-401, Phase 3b) — the wunit_* wrappers named by the spike's 2.2 interface.
# Sourced HERE, right after the git-pr adapter body above, so its own "borrow do_merge from
# agent-watch.sh if not yet in scope" guard (work-unit.sh top) sees do_merge ALREADY defined and
# skips re-sourcing this file — no recursion. Defines wunit_open/list_open/inspect/gate/apply/
# reconcile/teardown/ref, each a one-line delegation to the function immediately above (or a bare
# `gh pr …`); this file's own reconcile/teardown call sites below use wunit_reconcile/wunit_teardown
# instead of reconcile_backlog/_reap_slug directly (HERD-401's rewiring), so behavior is unchanged —
# same functions run, just resolved through the facade's name.
#
# WHY wunit_apply (→ do_merge) has no call site to rewire here: HERD-306 (the Python engine-port
# finale) deleted the bash ACTION PASS that used to walk merge candidates and call do_merge — see
# _engine_tick_watchdog below. pysrc/herd/live_runtime.py's LiveActuator is the SOLE merge/reap
# actuator in production now (its own gh pr merge / gh pr view calls, independently ported — it does
# NOT shell out to this file's do_merge). do_merge/wunit_apply survive as the git-pr adapter body
# exercised directly by the sim scenario suite and the hermetic tests (their own reference-model
# dispatch), and remain available for any future bash-mode caller, but there is no "apply" leg left
# in the watcher's own tick to route through the facade — noted via herd note, not silently assumed.
. "$HERE/work-unit.sh"
# CI auto-repair (HERD-250) — pure predicate for the inherited-red healer: a MERGEABLE+UNSTABLE PR whose
# required CI is FAILING, herd/gates already PASSED, and the branch is BEHIND main is base-refreshed
# (not silently merged). Sourcing DEFINES functions only; ship-dormant under CI_AUTOREPAIR=off.
. "$HERE/ci-repair.sh"
# AGING-PR alarm (HERD-334) — THE shared TTL helper (_aging_pr_ttl_secs / _aging_pr_armed /
# _aging_pr_over_ttl) both this render pass and journal-audit.sh read AGING_PR_TTL through, so the two
# surfaces can never disagree on the threshold. Sourcing DEFINES functions only; byte-inert when
# AGING_PR_TTL=0 (the alarm disabled).
. "$HERE/aging-pr.sh"
# PUSH_GATE=human (HERD-123) — the push-hold helper. Sourced for push_gate_awaiting_sha, which drives
# the 'ready · awaiting push approval' console row below. Sourcing only DEFINES functions (its CLI
# dispatch is $0-guarded), so this is inert until a builder has recorded a push-hold.
. "$HERE/push-gate.sh"
# Pipeline steps (HERD-132) — the step-runner. Sourced for steps_run_at, which the merge sequence
# (do_merge) calls at the pre-merge and post-merge seams. Sourcing DEFINES functions only (CLI dispatch
# is $0-guarded); byte-inert until a project ships a non-empty .herd/steps.tsv, so a project with no
# step list runs a byte-identical merge sequence.
. "$HERE/steps.sh"
# Runtime driver shim — binds each runtime-specific control-surface capability (list-agents,
# read-pane, send-keys, notifications, start-agent) to the active HERD_DRIVER. Makes the watcher's
# load-bearing core run with NO herdr panes under HERD_DRIVER=headless (panes-as-a-view); the default
# herdr-claude driver delegates to the exact same herdr commands. Defines functions only; lib-safe.
. "$HERE/driver.sh"
# Bounded console sections (HERD-243) — the shared age-out / ack / ledger-trim helpers behind the
# tracker-heal and builder-note surfaces, so both age out by one rule. Defines functions + two
# constants (CONSOLE_ROW_RETENTION, CONSOLE_LEDGER_MAX); display-only, lib-safe.
. "$HERE/console-section.sh"
# Pre-spawn CLAIM (HERD-50) — sourced for its RELEASE half (herd_claim_release, HERD-162 F12), which
# the dead-builder reconcile calls to un-wedge a tracker item whose builder died before opening a PR.
# Sourcing DEFINES functions only (its lane entry point herd_claim_or_abort is never called from here);
# byte-inert until CLAIM_RELEASE is opted in.
# shellcheck source=/dev/null
. "$HERE/herd-claim.sh"

# ── The gh availability guard (HERD-237) ──────────────────────────────────────────────────────────
# EVERY `gh` call on the tick path runs through _gh_timeout. Grounding (audit 2026-07-09, G4): the
# whole control room rides ONE loop. A single `gh` that never returns — a wedged TLS handshake, a
# black-holed proxy, a captive-portal DNS answer that hangs the connect — froze merges, gate-status
# posts, collections and limit-parks INDEFINITELY. Nothing guarded it: WATCH_CLAUDE_PROBE_TIMEOUT
# covers `claude` execs only. A per-call wall-clock bound converts "the console is dead" into "this
# one call failed", which every call site already knows how to handle.
#
# CONTRACT
#   • Signature: _gh_timeout <site> <gh-args…>  — <site> is a stable label for the JOURNAL, never
#     passed to gh. stdout/stderr/exit status of gh are passed through UNTOUCHED, so a healthy call
#     is byte-identical to the bare `gh …` it replaced (that is what the unit test asserts).
#   • On expiry: journal ONE `gh_timeout` event carrying the site + budget, then return 124 (the
#     coreutils convention). NOTHING is printed to stdout. A timed-out call therefore lands in the
#     EXISTING gh-failure branch of its site — an empty inbox, a `return 0`, a `|| true`, an aborted
#     sweep, PRS_LOOKUP_OK=0 — and never in a fabricated success. `journal_append` writes only to the
#     journal file (its impl runs in an output-suppressed subshell), so a wrapper inside `$(…)` can
#     never pollute the captured stdout.
#   • gh's own non-zero exits (rate-limit, 404, auth) pass straight through and are NOT journaled —
#     they are not availability faults and the sites already report them.
#
# The budget is INLINE, deliberately not a config key: a hung network call is never a policy choice.
# HERD_GH_TIMEOUT_SECS is a TEST SEAM (so a unit need not wait 15 s), mirroring layout-reconcile.sh's
# HERD_RELOAD_HERDR_TIMEOUT. A non-numeric/empty value falls back to the default rather than aborting.
_GH_TIMEOUT_DEFAULT_SECS=15

# _gh_timeout_secs — the effective per-call budget in seconds (fail-safe parse: garbage → default).
_gh_timeout_secs() {
  case "${HERD_GH_TIMEOUT_SECS:-}" in
    ''|*[!0-9]*|0) printf '%s' "$_GH_TIMEOUT_DEFAULT_SECS" ;;
    *)             printf '%s' "$HERD_GH_TIMEOUT_SECS" ;;
  esac
}

# _gh_timeout_run <secs> <cmd> [args…] — run <cmd> under a HARD wall-clock bound, PRESERVING its
# stdout (unlike _claude_probe_run_timeout, which discards it — most gh call sites capture JSON).
# Returns 124 on expiry, else the command's own exit code. Portable, in preference order:
#   1. coreutils `timeout` / `gtimeout` — exact, no added latency.
#   2. perl — on every stock macOS and Linux. fork + SIGALRM in the parent: exact, and (unlike a
#      poll loop) it adds ZERO latency to a fast call. This is the path that matters: the pure-shell
#      watchdog below cannot sleep for less than a second, so on a stock macOS it would tax EVERY one
#      of the tick's ~30 gh calls a full second — a fix for a hang that manufactures a stall.
#   3. a pure-shell watchdog — last resort (no timeout binary AND no perl).
# Every kill/wait/sleep is guarded so this can never abort a caller running under `set -e`.
# _gh_timeout_kill_flag <bin> — SET $_GH_TIMEOUT_KFLAG to `-k <grace>` when <bin> supports coreutils'
# kill-after flag, else to nothing. Without it `timeout` sends only SIGTERM, and a `gh` that ignores
# TERM keeps the tick wedged — re-introducing the exact hang, on the coreutils path Linux always takes.
#
# It ASSIGNS rather than echoes, and the caller invokes it as a plain command rather than inside `$(…)`:
# a command substitution runs in a subshell, so an echoing version's cache would be discarded and the
# `timeout -k 1 1 true` probe would re-fork on EVERY gh call of every tick. Probed once per process.
_GH_TIMEOUT_KFLAG=""
_GH_TIMEOUT_KFLAG_PROBED=""
# ${VAR-} (no colon) throughout: the ghost scan reads `${UPPER:-…}` as a config knob, and a hermetic
# test that extracts this function alone must not trip `set -u` on the un-sourced globals.
_gh_timeout_kill_flag() {
  [ -n "${_GH_TIMEOUT_KFLAG_PROBED-}" ] && return 0
  _GH_TIMEOUT_KFLAG_PROBED=1
  _GH_TIMEOUT_KFLAG=""
  "$1" -k 1 1 true >/dev/null 2>&1 && _GH_TIMEOUT_KFLAG="-k 5"
  return 0
}

_gh_timeout_run() {
  local secs="$1"; shift
  local rc=0
  # $_GH_TIMEOUT_KFLAG unquoted ON PURPOSE: it is either empty or the two words `-k 5`.
  # NORMALIZE THE ESCALATED EXIT: coreutils `timeout` returns 124 when its TERM ended the command, but
  # 137 (128+KILL) / 143 (128+TERM) when the -k grace had to finish the job. All three mean the same
  # thing here — the deadline killed it — and only 124 is the convention the wrapper's callers read.
  if command -v timeout >/dev/null 2>&1; then
    _gh_timeout_kill_flag timeout
    timeout ${_GH_TIMEOUT_KFLAG-} "$secs" "$@" || rc=$?
    case "$rc" in 137|143) rc=124 ;; esac
    return "$rc"
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    _gh_timeout_kill_flag gtimeout
    gtimeout ${_GH_TIMEOUT_KFLAG-} "$secs" "$@" || rc=$?
    case "$rc" in 137|143) rc=124 ;; esac
    return "$rc"
  fi
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      my $secs = shift;
      my $pid = fork();
      die "fork failed\n" unless defined $pid;
      if ($pid == 0) { exec @ARGV or exit 127; }
      $SIG{ALRM} = sub {
        kill "TERM", $pid; sleep 1; kill "KILL", $pid; waitpid($pid, 0); exit 124;
      };
      alarm $secs;
      waitpid($pid, 0);
      alarm 0;
      my $st = $?;
      exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$secs" "$@" || rc=$?
    return "$rc"
  fi
  # No timeout binary and no perl. The watchdog needs a working `sleep` to enforce the bound; without
  # one, degrade to an un-timed run rather than busy-spin into a FALSE timeout.
  if ! sleep 0 2>/dev/null; then "$@" || rc=$?; return "$rc"; fi
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null || true; sleep 1; kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true; return 124
    fi
    sleep 1; waited=$((waited+1))
  done
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

# _gh_timeout <site> <gh-args…> — THE seam. See the contract above.
_gh_timeout() {
  local _ght_site="$1"; shift
  local _ght_secs _ght_rc=0
  _ght_secs="$(_gh_timeout_secs)"
  _gh_timeout_run "$_ght_secs" gh "$@" || _ght_rc=$?
  if [ "$_ght_rc" -eq 124 ]; then
    journal_append gh_timeout component agent-watch site "$_ght_site" timeout_secs "$_ght_secs"
  fi
  return "$_ght_rc"
}

MAIN="$PROJECT_ROOT"
TREES="$WORKTREES_DIR"
STATE="$TREES/.agent-watch-merged"
# Resolve-attempt ledger, PARALLEL to $STATE: one line per conflict-resolver DISPATCH or terminal
# OUTCOME. Format "<epoch> <pr#> <slug> <branch> <sha> <outcome>", outcome ∈ dispatched | escalated.
# Sha-keyed like the review-once ledger (HERD-55): a resolver is dispatched at most ONCE per head
# sha, but a NEW commit (sha change) that reshapes the conflict — or a resolver that DIED without
# clearing it — re-spawns a fresh resolver for the new sha. dispatched records are the per-PR RESPAWN
# BUDGET (capped at REFIX_MAX_ROUNDS); an `escalated` marker is TERMINAL for that sha (the resolver
# judged the conflict semantically ambiguous) and is NOT a dispatch, so it never consumes the budget.
# Legacy 4-field rows (pre-HERD-55, no sha/outcome) read as a dispatch with an empty sha.
RESOLVE_STATE="$TREES/.agent-watch-resolve-attempts"
# Max DISTINCT head shas a resolver may be spawned for on one branch before the watcher stops
# re-spawning across new commits and escalates to "needs you" (the cross-sha anti-churn cap).
_RESOLVE_RETRY_MAX=3
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
# Refix ledger: one line per auto-refix bounce ("<epoch> <pr#> <headSha> <slug> <kind>"), plus a
# "… <kind> reset" row whenever a rail's red resolves. Sha-keyed (one bounce per BLOCK per sha; new
# commit → fresh budget). Each RAIL (review | health | stale) carries its own round budget, capped at
# REFIX_MAX_ROUNDS and zeroed when that rail passes; a per-PR total ceiling (3× REFIX_MAX_ROUNDS)
# bounds the whole thing. Exhausting either escalates to "needs you". See the HERD-229 block below.
REFIX_STATE="$TREES/.agent-watch-refixed"
# Override ledger: one line per human override of a cached BLOCK.
# Format: "<epoch> override <pr#> <headSha>"
# Written by herd-approve.sh override <pr#>; keyed by sha so a new commit invalidates the override.
OVERRIDES="$TREES/.agent-watch-overrides"
# Approval ledger (MERGE_POLICY=approve|observe): one line per record, append-only.
# Format: "<epoch> awaiting <pr#> <headSha>"  — watcher noted gates passed, awaiting human approval
#         "<epoch> approved <pr#> <headSha>"  — herd-approve.sh wrote explicit approval for this sha
#         "<epoch> observed <pr#> <headSha>"  — watcher notified in observe mode (dedup guard)
# The path is resolved through approvals.sh so this reader and herd-approve.sh (the writer) can never
# name two different files. Sourcing it only defines functions.
# shellcheck source=/dev/null
. "$HERE/approvals.sh"
APPROVALS="$(_approvals_file || true)"
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
# Wedged-builder ledger (HERD-278), PARALLEL to $DEAD_STATE: one line per active worktree slug whose
# agent is ALIVE and reads 'done' while its branch has NO open PR and its tree carries nothing that
# could become one (no commits ahead of base, or uncommitted changes). Format
# "<slug> <first-seen-epoch> <state>", state ∈ pending | notified | woken. A builder mid-`gh pr create`
# transiently looks exactly like this, so the slug is surfaced only once the signature has PERSISTED
# past a grace window (WEDGE_GRACE_MIN). Any escape (a PR appears, the agent goes back to working)
# clears the record. See the "Wedged-builder detection" helpers below.
WEDGE_STATE="$TREES/.agent-watch-wedged"
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
# Cross-seat dual-engine state (HERD-308): one line "<verdict> <self_level> <max_level> <peer>" written
# by the per-tick reconcile whenever this pool has two DISTINCT engine levels writing it, read by
# build_engine_seat_note to paint the loud halt/coexistence row. Absent on the coherent single-seat
# path, so the console is byte-identical while ENGINE_SEAT_RECONCILE is off or only one engine writes.
ENGINE_SEAT_STATE="$TREES/.agent-watch-engine-seat"
# Stale-duplicate hold ledger (HERD-188): one line "<epoch> <pr#> <sha> <kind>" per PR+sha the
# pre-merge stale-dup gate HELD, so the loud PR comment + notification + journal event fire EXACTLY
# ONCE per sha instead of every tick (the console row itself is re-rendered every tick from the live
# re-check). Keyed by pr+sha like the review/health ledgers, so a new commit re-evaluates fresh.
STALE_DUP_STATE="$TREES/.agent-watch-stale-dup"
# Re-stale ledger (HERD-231): one line "<epoch> <pr#> <sha> <kind>" per LAP a PR lost — a sha this
# watcher had already INVESTED gate work in (a review or healthcheck in flight, or a verdict already
# recorded) that another merge then re-staled (kind=stale-base|duplicate) or re-conflicted
# (kind=conflict). Keyed by pr+sha+kind so a hold that lingers across ticks counts ONCE, and a bounce
# to a fresh sha that loses the race AGAIN counts a second lap. Purely OBSERVABILITY: the per-PR lap
# count drives the loud `starving · N re-stale laps` row and the pr_starvation journal event at
# _RESTALE_STARVE_THRESHOLD. Nothing gates on it — no merge, hold, or bounce reads this file.
RESTALE_STATE="$TREES/.agent-watch-restale"
# Laps a PR may lose before the console calls it STARVING. Inline (not a config key): it names a
# reporting threshold, not a policy — no behavior branches on it.
_RESTALE_STARVE_THRESHOLD=3
# herd/gates commit-status ledger (HERD-194): one line "<epoch> <pr#> <sha> success" per SUCCESS commit
# STATUS this watcher successfully POSTED. The watcher posts ONLY `success` (a green blessing) — never a
# non-passing pending/failure status, which would flip a CLEAN sha to UNSTABLE and strand it (see the
# gate-status helpers). Keyed by pr+sha so the blessing posts EXACTLY ONCE — the GitHub Statuses API is
# itself idempotent per (sha,context), but this ledger stops us re-POSTing (a network write) on every
# 4 s tick. A row is written ONLY after the API write succeeds, so a transient failure re-tries next
# tick (fail-safe: the blessing MUST land, since its ABSENCE is exactly what keeps a PR unmergeable
# under `require herd/gates` branch protection).
GATE_STATUS_STATE="$TREES/.agent-watch-gate-status"
# The commit-status context the watcher posts + the operator requires in branch protection. Kept as a
# constant (not a config key) so the protection recipe in docs/governance-gates.md and the watcher can
# never drift apart — the whole fail-safe rests on both naming the SAME context.
GATE_STATUS_CONTEXT="herd/gates"
# GH CI check-run gate-event ledger (HERD-197): one line "<pr> <sha> <conclusion> <check-name>" per
# TERMINAL check-run result the watcher has already journaled (and, for a failure, notified). Keyed by
# pr+sha+conclusion+name so each landed result fires its once-only side effects EXACTLY ONCE while the
# console row is re-derived live every tick; a new commit (new sha) re-evaluates the CI leg from scratch.
# See the "GH CI check-run gate events" helpers below. Purged per-PR on merge/reap (purge_pr_ci_checks).
CI_CHECKS_STATE="$TREES/.agent-watch-ci-checks"
# Tracker-state self-heal surfaces (HERD-86). The periodic tracker-state sweep (tracker-state-sweep.sh)
# re-asserts Done for a recently-merged PR whose tracker item drifted (stuck open after merge — the
# HERD-67/HERD-69 incidents). TRACKER_SWEEP_LEDGER records refs already confirmed Done so the sweep
# never re-reads a clean ref (steady-state cost = one `gh pr list`, zero backend reads). The heal
# NOTE surface holds one "<epoch> <status> <ref> <pr> <found-state>" line per heal action (status ∈
# healed|failed); build_tracker_drift renders its tail so a heal — or a stuck failure — is VISIBLE in
# the console, never a silent correction.
TRACKER_SWEEP_LEDGER="$TREES/.agent-watch-tracker-swept"
TRACKER_HEAL_FILE="$TREES/.agent-watch-tracker-heals"
# Post-merge reconcile ledger (HERD-232). The post-merge hook chain used to be merge-EVENT-driven: only
# the seat whose own do_merge landed a PR ever ran it. _sweep_merged_prs re-derives those obligations
# from the world (recently-MERGED PRs) instead, so a foreign-seat merge, a gh-UI merge, or a watcher
# killed mid-do_merge all converge. One "<epoch> <pr> <sha>" row per merged PR whose obligations this
# seat has FULLY discharged — the pr+sha run-once key that keeps a reconciled PR from being re-probed.
POSTMERGE_SWEPT_LEDGER="$TREES/.agent-watch-postmerge-swept"
# Note-once ledger for a merged PR whose reap is DEFERRED (dirty tree / re-spawned slug). Such a PR
# never earns a run-once row — the reap must keep retrying — so without this its `postmerge_reap_skip`
# / `postmerge_deferred` lines would re-appear every cadence pass, forever. Rows: "<pr> <sha> <kind>".
POSTMERGE_NOTED_LEDGER="$TREES/.agent-watch-postmerge-noted"
# Dep-state console surface: dep-watcher.sh rewrites this file each tick with one
# "<ref> <state> <age-seconds>" line per live blocked-on dep (state ∈ open|in-progress|in-review|
# stalled). Read-only here and purely informational — a blocked-on is a STATUS LINE, never a freeze,
# so a missing/stale file just means "no deps to show". Path mirrors dep-watcher's <lock-stem>.states.
DEP_STATES_FILE="${DEP_STATES_FILE:-${HERD_DEPWATCHER_LOCK%.pid}.states}"
# Spawn-hold surface (HERD-94): the durable spawn queue supports an OPTIONAL per-intent after=<slug|pr#>
# dependency. The drainer (_drain_spawn_queue) HOLDS such an intent until the dependency shows MERGED
# (reap ledger $STATE, one gh fallback), then releases it FIFO. One line per currently-held intent —
# "<intent_id> <first_held_epoch> <slug> <lane> <after>" — persists across ticks so spawn_held journals
# ONCE (not per tick) and the stall TTL accrues from the FIRST hold. A held intent whose dependency
# hasn't moved after DEP_STALE_TTL surfaces as a LOUD stalled console row (build_spawn_holds) — never a
# silent forever-hold. Rows for vanished intents (spawned / skipped / operator-cleared) are pruned by
# build_spawn_holds so the ledger cannot grow unbounded.
SPAWN_HELD_STATE="$TREES/.agent-watch-spawn-held"
# Daily-budget drain-pause state (HERD-95): 1 while the spawn-queue drain is PAUSED because today's
# recorded spend has exceeded BUDGET_DAILY, else empty. In-process only (the watch loop is one long
# process), so the pause is journaled ONCE per continuous over-budget stretch — not every 4s tick —
# and cleared when spend falls back under the ceiling. Untouched (stays empty) when BUDGET_DAILY is
# dormant, so a no-budget watcher is byte-identical to before.
_BUDGET_DRAIN_PAUSED=""
# Stall TTL for a held spawn intent (seconds; 0 disables stall surfacing). REUSES dep-watcher's
# DEP_STALE_TTL so operators tune one knob; default mirrors dep-watcher.sh (86400 = 1 day).
DEP_STALE_TTL="${DEP_STALE_TTL:-86400}"
# Operator-inbox surfaces (HERD-184). Two files, both under $TREES, both untouched when OPERATOR_INBOX
# is off (byte-inert):
#   • INBOX_LEDGER — one TAB-separated entry per surfaced cross-seat comment
#     ("<epoch>\t<source>\t<ref>\t<author>\t<snippet>", source ∈ pr|tracker), appended by _inbox_scan
#     and rendered newest-first by build_operator_inbox. Capped to the most recent entries so it can
#     never grow unbounded.
#   • INBOX_SEEN_STATE — the DEDUP ledger of comment ids already surfaced ("pr:<id>" / "tr:<id>", one
#     per line) so each comment lands in the inbox AND notifies exactly ONCE, not every scan tick.
#   • INBOX_SEEN_LIVE — the per-tick set of comment ids OBSERVED this scan (whether newly surfaced or
#     already seen). Reset each _inbox_scan; consumed by the retention-aware seen-ledger trim so a
#     still-live id is never evicted at the cap and re-notified (HERD-213). Off → never created.
INBOX_LEDGER="$TREES/.agent-watch-inbox"
INBOX_SEEN_STATE="$TREES/.agent-watch-inbox-seen"
INBOX_SEEN_LIVE="$TREES/.agent-watch-inbox-seen-live"
INBOX_LEDGER_MAX=50    # most-recent entries kept in the ledger
INBOX_SEEN_MAX=1000    # most-recent seen comment ids kept (dedup memory, bounded)
# Builder-notes surface (HERD-202). Builders file mid-build findings via `herd note "<finding>"`,
# which journals a builder_note event. The watcher scans the journal each tick for NEW builder_note
# rows past a byte cursor, notifies once per event, and renders a needs-you-adjacent console section.
# Ship-dormant: with zero new builder_note events the ledger stays empty and render() adds nothing
# (byte-identical console). Always-on (no config gate) — dormancy is "nobody called herd note".
#   • BUILDER_NOTES_LEDGER — one TAB-separated entry per surfaced note
#     ("<epoch>\t<slug>\t<text>\t<ts>"), newest appended; rendered newest-first by build_builder_notes.
#   • BUILDER_NOTES_CURSOR — byte offset into the live journal already consumed (first scan pins to
#     EOF so a restart never re-floods historical notes).
#   • BUILDER_NOTES_ACK — the ACK ledger (HERD-243): one verbatim ledger line per note the operator
#     has handled via `herd notes ack <all|n>`. An acked note leaves the console IMMEDIATELY; the
#     journal (the history) is never touched. Notes also age out of display after CONSOLE_ROW_RETENTION.
BUILDER_NOTES_LEDGER="$TREES/.agent-watch-builder-notes"
BUILDER_NOTES_CURSOR="$TREES/.agent-watch-builder-notes-cursor"
BUILDER_NOTES_ACK="$TREES/.agent-watch-builder-notes-acked"
BUILDER_NOTES_LEDGER_MAX="$CONSOLE_LEDGER_MAX"
# Orphan-PR advisory surface (HERD-330). The watcher gates work it DISCOVERS via git worktrees; an
# open PR with no live builder worktree in this workspace (a collaborator PR, a main-checkout PR, a
# PR whose worktree was reaped) is therefore never adopted — it sits ungated and, today, invisible.
# Under ORPHAN_PR_ROWS=on the render/reconcile tick REWRITES this ledger each cycle with one
# "<epoch>\t<pr>\t<title>\t<branch>" row per such PR, computed from the tick's ALREADY-fetched open-PR
# roster (PRS_JSON) minus the PRs the discovered worktrees claim — DYNAMIC discovery, zero extra gh.
# Rewritten-each-tick means it self-corrects the instant a worktree adopts the PR or the PR closes
# (the row simply stops being written). build_orphan_prs renders its tail through the shared
# bounded-section helper (console-section.sh). Off (default) → never written, so a no-orphan/off
# watcher is byte-identical to before this feature.
ORPHAN_PR_LEDGER="$TREES/.agent-watch-orphan-prs"
ORPHAN_PR_ROWS_LIMIT=5    # most-recent orphan rows rendered (display bound; the ledger is rewritten whole each tick)
# Adopt-remote-PRs ledgers (HERD-369), sibling of the orphan-PR ledger above. Under ADOPT_REMOTE_PRS=on
# the tick's ADOPT leg (built on top of the SAME orphan diff) attempts `git fetch` + `git worktree add`
# per orphan PR. TWO separate ledgers, ADVISED (herd-advise.sh) against conflating "succeeded" with
# "gave up": a fetch/worktree-add failure is not a completed operation — it is usually transient (a
# network blip, a momentary ref lock) and self-heals on the next ~60s scan, so it is NEVER once-
# guarded; only a SUCCESSFUL adopt is terminal for that (pr,sha) — a re-tick must never re-adopt an
# already-adopted branch, even before the next worktree-rediscovery pass has folded it into the
# claimed set.
#   • ADOPT_PR_LEDGER            — one "<pr>\t<sha>\tadopted" row per SUCCESSFUL adopt (the once-guard).
#   • ADOPT_FAILED_SEEN_LEDGER   — one "<pr>\t<sha>" row per (pr,sha) whose FAILURE has already been
#     journaled, so a permanently-broken branch retried every scan does not spam `adopt_failed` once
#     per tick forever — the ATTEMPT still retries every scan; only the journal EVENT is deduped, and
#     a new sha (a fresh push) always re-journals.
ADOPT_PR_LEDGER="$TREES/.agent-watch-adopted-prs"
ADOPT_FAILED_SEEN_LEDGER="$TREES/.agent-watch-adopt-failed-seen"
# ADOPT_SELFHEAL_SEEN_LEDGER (HERD-377) — dedupes the `adopt_selfheal_failed` journal event per
# (branch,stale-dir), mirroring ADOPT_FAILED_SEEN_LEDGER: a still-broken `git worktree move` RETRIES
# every scan, but the journal EVENT for that exact pair fires once. A SUCCESSFUL move needs no ledger
# at all — the next scan finds the branch already checked out at the expected path and self-terminates.
ADOPT_SELFHEAL_SEEN_LEDGER="$TREES/.agent-watch-adopt-selfheal-seen"
# Only truthy values enable dry-run. Treat "0"/""/"false"/"no" as live.
case "${AGENT_WATCH_DRYRUN:-}" in 1|true|yes|on) DRYRUN=1 ;; *) DRYRUN="" ;; esac

# Console palette — themed via HERD_THEME (default tokyonight, byte-identical to the old hardcoded
# truecolor block). theme.sh resolves .herd/themes/<name>/palette.sh → templates/themes/<name>/ →
# tokyonight, warns-once-and-falls-back on an unknown/broken theme, and renders plain under NO_COLOR
# or a non-TTY stdout. This is a status console (a pane), not markdown, so it uses the truecolor C_*.
# Loaded HERE, ahead of the policy resolvers below, because their launch-time warnings colour through
# the same C_* palette.
# shellcheck source=/dev/null
. "$HERE/theme.sh"
herd_theme_load_console

# _effective_merge_policy — resolve "auto" | "approve" | "observe" (HERD-159). THE shared resolver,
# sourced by the watcher, `herd reload` and `herd doctor --posture` alike so all three agree on what
# the watcher will actually do (HERD-210). MERGE_POLICY wins when recognized; empty/unset derives
# from the legacy WATCHER_AUTOMERGE boolean; an unrecognized non-empty value is a TYPO that fails
# STRICT to `observe`. The launch-time journal below surfaces the bad value once; the resolver is a
# pure helper and only resolves.
# shellcheck source=/dev/null
. "$HERE/merge-policy.sh"
# shellcheck source=/dev/null
. "$HERE/resolver-pane.sh"
_pol="$(_effective_merge_policy)"
AUTOMERGE=""; MERGE_OBSERVE=""
case "$_pol" in
  auto)    AUTOMERGE=1 ;;
  observe) MERGE_OBSERVE=1 ;;
esac
# An explicitly-set but UNRECOGNIZED MERGE_POLICY fails strict to observe — journal it once at
# launch and print a red console line so a typo (MERGE_POLICY=aprove) never silently rides the
# legacy auto-merge default. Skipped in lib mode so sourcing for pure helpers never writes a
# journal line (mirrors HUMAN_VERIFY_POLICY below).
if [ "${AGENT_WATCH_LIB:-}" != "1" ] && _merge_policy_is_typo; then
  journal_append merge_policy_invalid value "$MERGE_POLICY" fell_back_to observe 2>/dev/null || true
  printf '%s⚠️  herdkit: invalid MERGE_POLICY=%s — falling back to observe (never merge)%s\n' \
    "$C_RED" "$MERGE_POLICY" "$C_RESET" >&2
fi
unset _pol

# WORK_UNIT_KIND (HERD-398) — the BASH watcher only ever runs git-pr (doc-apply is a PYTHON-only
# adapter, HERD-399; see spike §9.4 for why bash never gets a second kind). An explicitly-set but
# UNSUPPORTED kind fails STRICT to git-pr (the only adapter this engine has) — journal it once at
# launch and print a red console line, mirroring the MERGE_POLICY typo handling above, so a typo here
# never silently changes engine behavior: the watcher unconditionally runs the git-pr pipeline either
# way (nothing branches on this key yet), so the fallback here is cosmetic-honest, not a real behavior
# switch. Skipped in lib mode, same as its neighbors. The STRICTER hard refusal for an actual
# adapter-resolution caller lives in wunit_resolve_adapter (work-unit.sh) — this block is the boot-time
# advisory, not the enforcement.
if [ "${AGENT_WATCH_LIB:-}" != "1" ]; then
  case "${WORK_UNIT_KIND:-git-pr}" in
    git-pr) ;;
    *)
      journal_append work_unit_kind_invalid value "$WORK_UNIT_KIND" fell_back_to git-pr 2>/dev/null || true
      printf '%s⚠️  herdkit: WORK_UNIT_KIND=%s is not supported by the bash watcher — only "git-pr" ships here (doc-apply is python-engine-only, HERD-399); running the git-pr pipeline%s\n' \
        "$C_RED" "$WORK_UNIT_KIND" "$C_RESET" >&2
      ;;
  esac
fi

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

# ── HERD-159: live numeric / cosmetic resolvers (gate keys fail strict; cosmetic fail soft) ─────
# herd_numeric / herd_enum live in herd-config.sh. These thin wrappers keep every call site on a
# SAFE integer (or a known on/off token) while still honoring a mid-process export — hermetic tests
# set HEALTH_CONCURRENCY / CODEMAP_AUTOREFRESH AFTER sourcing this file. Warnings fire once per key
# via _herd_val_warn_once so a tick loop never spams stderr.
_review_conc()  { herd_numeric REVIEW_CONCURRENCY 2 || true; }
_spawn_ahead()  { herd_numeric SPAWN_AHEAD 1 || true; }
_health_conc()  { herd_numeric HEALTH_CONCURRENCY 1 || true; }
# CODEMAP_AUTOREFRESH is cosmetic (post-merge map refresh, never a gate). Unrecognized values fail
# soft toward ACTIVE (default true) so a typo never freezes the maps.
_codemap_auto() {
  local _ca
  _ca="$(printf '%s' "${CODEMAP_AUTOREFRESH:-true}" | tr '[:upper:]' '[:lower:]')"
  case "$_ca" in
    ''|1|true|on|yes|enable|enabled) printf 'true' ;;
    0|false|off|no|disable|disabled) printf 'false' ;;
    *)
      _herd_val_warn_once CODEMAP_AUTOREFRESH \
        "⚠️  herdkit: invalid CODEMAP_AUTOREFRESH=${CODEMAP_AUTOREFRESH} — falling back to true (active)"
      printf 'true'
      ;;
  esac
}

# This watcher's own worktree root — never auto-merge/remove the dir we run from.
SELF_WT="$(cd "$HERE/../.." && pwd)"

SLUGW=28               # slug column width — pads slugs so the state words align.

last_frame=""
HDR_LINE=""
RULE=""
LANDED=""
BLOCKED=""
TRACKER_DRIFT=""
SPAWN_HOLDS=""
OPERATOR_INBOX_ROWS=""  # HERD-184: the "operator inbox" section rows (empty when off/none → render omits it)
ORPHAN_PR_SECTION_ROWS=""  # HERD-330: the "orphan PRs" advisory section rows (empty when off/none → render omits it)
ENGINE_DOWN_ROW=""     # HERD-306: the "engine down · manual intervention" alarm row set by the engine watchdog past a fault streak (empty while the Python engine is ticking)
ENGINE_PAUSE_ROW=""    # HERD-347: the "⏸ engine paused by operator" banner set by _engine_tick_watchdog while ENGINE_PAUSE=on (empty — byte-identical console — while the lever is off/unset)
CELEBRATE=""            # HERD-147 flair: post-merge celebration line(s) for the current tick (empty when off/none)
PASTURE=""             # HERD-147 flair: the pasture-header line rendering the in-flight herd by state (empty when off/none)
DISPLAY=()
FLAIR_STATE=()         # HERD-147 flair: one state-token per DISPLAY row (parallel index), read by build_pasture

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
  done < <(reverse_file "$STATE" | head -3)  # pipe-ok: head in a command or process substitution; pipeline status not gated
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

# _tracker_heal_row — render ONE heal ledger line ("<epoch> <status> <ref> <pr> <found-state>").
# A `healed` row is calm green (drift was auto-corrected); a `failed` row is loud red (still stuck,
# retries next sweep) — either way the drift is VISIBLE, never a silent correction (HERD-86).
_tracker_heal_row() {
  local epoch status ref pr state hhmm glyph color
  local IFS=$' \t\n'
  read -r epoch status ref pr state <<EOF
$1
EOF
  [ -n "${ref:-}" ] || return 1
  hhmm="$(epoch_to_hhmm "$epoch")"
  case "$status" in
    healed) glyph='🩹'; color="$C_GREEN" ;;
    *)      glyph='⚠️'; color="$C_RED"   ;;
  esac
  printf '    %s%s%s %s%s%s %s%s%s %s#%s was %s · %s%s' \
    "$color" "$glyph" "$C_RESET" "$C_BOLD" "$ref" "$C_RESET" \
    "$color" "$status" "$C_RESET" "$C_DIM" "$pr" "$state" "$hhmm" "$C_RESET"
}

# build_tracker_drift — the "tracker healed" section: the newest 3 STILL-RELEVANT heal actions from
# $TRACKER_HEAL_FILE (written by tracker-state-sweep.sh), newest first. Empty (TRACKER_DRIFT="") when
# the file is absent/empty — or when every row has aged out — so render omits the section.
# Age-out (HERD-243, via the shared bounded-section helper): a calm `healed` row leaves the DISPLAY
# after CONSOLE_ROW_RETENTION (the correction landed; it is history now, and the journal keeps it),
# while a LOUD `failed` row never ages out — a stuck drift stays on screen until the sweep heals it.
build_tracker_drift() {
  TRACKER_DRIFT=""
  local rows
  rows="$(herd_console_section_tracker "$TRACKER_HEAL_FILE" 3 _tracker_heal_row)"
  [ -n "$rows" ] && TRACKER_DRIFT="${rows}"$'\n'
  return 0
}

# build_spawn_holds — the "spawn holds" section (HERD-94): one row per intent the durable-queue
# drainer is HOLDING on an unmet after=<dep> dependency, read from $SPAWN_HELD_STATE
# ("<intent_id> <first_held_epoch> <slug> <lane> <after>", written by _drain_spawn_queue). Empty
# (SPAWN_HOLDS="") when nothing is held so render omits the section — BYTE-IDENTICAL console when the
# after= feature is unused.
#
# A hold OLDER than DEP_STALE_TTL is LOUD (red ⏳ stalled) — the never-silent-forever-hold surface an
# operator must act on (clear = remove the intent's .req; force = drop its .after sidecar). A fresh
# hold is a calm yellow ⏳ waiting line. DEP_STALE_TTL=0 disables the stalled escalation (all holds
# stay calm) exactly as it disables dep-watcher's stall surfacing.
#
# GC: this is the once-per-tick garbage-collector for $SPAWN_HELD_STATE — a row whose intent no longer
# exists in the queue (spawned, skipped, or operator-cleared between ticks) is dropped, so the ledger
# never accumulates stale holds. Runs each tick alongside the other build_* surfaces.
build_spawn_holds() {
  SPAWN_HOLDS=""
  [ -s "$SPAWN_HELD_STATE" ] || return 0
  local _bsh_q="$TREES/spawn-queue" now rows="" kept id epoch slug lane after age human color glyph label sl
  now="$(date +%s)"
  kept="$(mktemp "${SPAWN_HELD_STATE}.XXXXXX" 2>/dev/null || true)"
  while read -r id epoch slug lane after; do
    [ -n "${id:-}" ] || continue
    # Prune a hold whose intent is gone (spawned / skipped / operator-cleared its .req).
    if [ ! -e "$_bsh_q/$id.req" ] && [ ! -e "$_bsh_q/$id.req.mine" ]; then
      continue
    fi
    [ -n "$kept" ] && printf '%s %s %s %s %s\n' "$id" "$epoch" "$slug" "$lane" "$after" >> "$kept"
    case "${epoch:-}" in ''|*[!0-9]*) epoch="$now" ;; esac
    age=$(( now - epoch )); [ "$age" -lt 0 ] && age=0
    human="$(_fmt_age "$age")"
    if [ "${DEP_STALE_TTL:-0}" -gt 0 ] && [ "$age" -gt "$DEP_STALE_TTL" ]; then
      color="$C_RED"; glyph='⏳'; label="stalled"
    else
      color="$C_YELLOW"; glyph='⏳'; label="waiting"
    fi
    sl="$(_slug_cell "$slug")"
    rows="${rows}    ${color}${glyph}${C_RESET} ${color}${sl}${C_RESET} ${color}${label}${C_RESET} ${C_DIM}after ${after} · ${human}${C_RESET}"$'\n'
  done < "$SPAWN_HELD_STATE"
  # Swap in the pruned ledger (drops rows for vanished intents) so it can't grow unbounded.
  if [ -n "$kept" ]; then mv -f "$kept" "$SPAWN_HELD_STATE" 2>/dev/null || rm -f "$kept" 2>/dev/null; fi
  [ -n "$rows" ] && SPAWN_HOLDS="$rows"
}

# build_engine_note — the QUIET 'engine outdated' console note (HERD-179). One dim line, and only when
# ENGINE_AUTOUPDATE is check|auto AND the local engine is genuinely below the project's committed
# ENGINE_MIN. Deliberately not an alarm row: a stale engine is a routine "pull the engine" nudge, not a
# red gate (the write paths themselves already refuse, loudly, at the point of use). Empty — hence a
# byte-identical console — while ENGINE_AUTOUPDATE=off (the ship default), when no floor is pinned, or
# when the engine is current. Pure: reads two integers, no I/O, no network.
build_engine_note() {
  HERD_ENGINE_NOTE=""
  local mode; mode="$(herd_engine_autoupdate_mode)"
  [ "$mode" = off ] && return 0
  herd_engine_stale || return 0
  local lvl min remedy
  lvl="$(herd_engine_level)"; min="$(herd_engine_min)"
  if [ "$mode" = auto ]; then remedy="auto-updating in the next quiescent window"; else remedy="run herd update"; fi
  HERD_ENGINE_NOTE="    ${C_YELLOW}⬆${C_RESET}  ${C_DIM}engine outdated${C_RESET} (level ${lvl} < ENGINE_MIN ${min}) ${C_DIM}— ${remedy}${C_RESET}"$'\n'
  return 0
}

# build_engine_seat_note — the CROSS-SEAT DUAL-ENGINE row (HERD-308), read from $ENGINE_SEAT_STATE which
# _engine_seat_reconcile_tick writes only when two DISTINCT engine levels are writing this pool. A STALE
# verdict is a LOUD red HALT row (this seat's writes are held); a LEAD verdict is a loud coexistence
# warning (a stale seat shares the pool and is itself halted). Empty — hence a byte-identical console —
# while ENGINE_SEAT_RECONCILE is off, when only one engine writes, or when the mismatch has cleared.
build_engine_seat_note() {
  HERD_ENGINE_SEAT_NOTE=""
  [ "${ENGINE_SEAT_RECONCILE:-off}" = on ] || return 0
  [ -s "${ENGINE_SEAT_STATE:-}" ] || return 0
  local _es_verdict _es_self _es_max _es_peer
  read -r _es_verdict _es_self _es_max _es_peer < "$ENGINE_SEAT_STATE" 2>/dev/null || return 0
  case "${_es_verdict:-}" in
    stale)
      HERD_ENGINE_SEAT_NOTE="    ${C_RED}🛑 ${C_BOLD}DUAL-ENGINE HALT${C_RESET}${C_RED} — this seat's engine level ${_es_self} < level ${_es_max} on seat ${_es_peer:-?} sharing this pool · writes HELD ${C_DIM}— run herd update${C_RESET}"$'\n' ;;
    lead)
      HERD_ENGINE_SEAT_NOTE="    ${C_YELLOW}⚠️${C_RESET}  ${C_BOLD}dual-engine coexistence${C_RESET}${C_YELLOW} — a stale seat (${_es_peer:-?}, below level ${_es_self}) shares this pool ${C_DIM}— it is halted until updated${C_RESET}"$'\n' ;;
    *) return 0 ;;
  esac
  return 0
}

# _engine_seat_reconcile_tick — the per-tick call (HERD-308). Under ENGINE_SEAT_RECONCILE=on it stamps
# this seat's engine level into the pool registry and reconciles it against the other active seats. On a
# STALE verdict it arms $_ENGINE_SEAT_HALT so do_merge / post_gate_status refuse the cross-mismatch
# write; on any mismatch it records the verdict to $ENGINE_SEAT_STATE for build_engine_seat_note; a
# coherent pool clears the note. A HARD no-op (no stamp, no read, no file) when the lever is off or in
# dry-run, so the console + merge path stay byte-identical. Guarded so no failure can end the tick.
_engine_seat_reconcile_tick() {
  _ENGINE_SEAT_HALT=""
  [ "${ENGINE_SEAT_RECONCILE:-off}" = on ] || return 0
  [ -n "$DRYRUN" ] && return 0
  command -v herd_engine_seat_reconcile >/dev/null 2>&1 || return 0
  if herd_engine_seat_reconcile; then
    rm -f "$ENGINE_SEAT_STATE" 2>/dev/null || true
    return 0
  fi
  printf '%s %s %s %s\n' "${_HERD_SEAT_VERDICT:-}" "${_HERD_SEAT_SELF_LEVEL:-}" \
    "${_HERD_SEAT_MAX_LEVEL:-}" "${_HERD_SEAT_PEER:-}" > "$ENGINE_SEAT_STATE" 2>/dev/null || true
  [ "${_HERD_SEAT_VERDICT:-}" = stale ] && _ENGINE_SEAT_HALT=1
  return 0
}

# build_main_health — the post-merge main-health ALARM row (HERD-129). One LOUD persistent red line
# while the default branch is red, read from $MAIN_HEALTH_STATE (US-joined "<sha>US<since_pr>US<local
# identity>US<CI identity>", written by _main_health_set_red and cleared by _main_health_clear). Empty
# (MAIN_HEALTH="") when the file is absent — so a green main renders NOTHING. Also GATED on the lever:
# if an operator flips MAIN_HEALTH_TICK=off while main is red, the row stops rendering immediately (no
# tick is left to clear a stale state file) — so the console is BYTE-IDENTICAL to before this feature
# whenever the feature is off, red state file or not.
#
# HERD-372: the row renders the MOST SPECIFIC identity available — a local-suite failing test/TAP line
# names exactly what to fix, while a branch-CI conclusion ("CI <workflow>: FAILURE") is comparatively
# generic — so the local identity wins whenever both are standing. Byte-identical to the pre-HERD-372
# single-field row whenever only one identity exists (the other field is simply empty).
#
# HONEST 'since' (HERD-222): an OBSERVED-SHA tick — a main sha this seat never merged — often has no PR
# number to attribute the break to (the sha is recorded as "?"). Printing "(since #?)" would name a PR
# that does not exist, so a non-numeric since renders "(observed)" instead: the row says WHAT is red and
# admits it does not know WHO broke it, rather than pointing at a fictional PR.
build_main_health() {
  MAIN_HEALTH=""
  _main_health_enabled || return 0
  [ -s "$MAIN_HEALTH_STATE" ] || return 0
  local _bm_sha _bm_since _bm_local _bm_ci _bm_fail _bm_attr
  IFS=$'\x1f' read -r _bm_sha _bm_since _bm_local _bm_ci < "$MAIN_HEALTH_STATE" 2>/dev/null || return 0
  _bm_fail="$_bm_local"; [ -n "$_bm_fail" ] || _bm_fail="$_bm_ci"
  [ -n "${_bm_fail:-}" ] || _bm_fail="unknown"
  case "${_bm_since:-}" in
    ''|*[!0-9]*) _bm_attr="observed" ;;
    *)           _bm_attr="since #${_bm_since}" ;;
  esac
  MAIN_HEALTH="    ${C_RED}🚨 ${C_BOLD}MAIN RED${C_RESET}${C_RED} — ${_bm_fail} ${C_DIM}(${_bm_attr})${C_RESET}"$'\n'
}

# build_main_freshness — the MAIN-checkout freshness rows (HERD-233), both read from state files the
# tick reconcile writes: (1) a LOUD row while $MAIN diverged in a way only a human can resolve, and
# (2) a "restart recommended" note when a fast-forward pulled engine code this watcher process is no
# longer running. Both files are absent on the happy path, so a fresh $MAIN renders NOTHING and the
# console stays byte-identical to before this feature.
build_main_freshness() {
  MAIN_FRESHNESS=""
  local _bf_reason _bf_b _bf_a _bf_up _bf_why _bf_delta
  [ -s "${MAIN_FRESH_STATE:-}" ] || [ -s "${MAIN_FRESH_RESTART:-}" ] || return 0
  _bf_up="${HERD_REMOTE:-origin}/${HERD_BRANCH_NAME:-main}"
  if [ -s "${MAIN_FRESH_STATE:-}" ]; then
    read -r _bf_reason _bf_b _bf_a < "$MAIN_FRESH_STATE" 2>/dev/null || return 0
    case "${_bf_reason:-}" in
      dirty-tree)    _bf_why="uncommitted changes in the checkout · commit or stash them" ;;
      local-commits) _bf_why="local commits nobody generated · rebase or push them by hand" ;;
      ff-failed)     _bf_why="fast-forward refused · resolve in ${MAIN}" ;;
      rebase-failed) _bf_why="rebase of the generated-map commits refused · resolve in ${MAIN}" ;;
      push-failed)   _bf_why="push of the generated-map commits refused · retrying each tick" ;;
      *)             _bf_why="${_bf_reason:-unknown}" ;;
    esac
    _bf_delta="behind ${_bf_up} by ${_bf_b:-?}"
    [ "${_bf_a:-0}" = 0 ] || _bf_delta="${_bf_delta}, ahead by ${_bf_a}"
    MAIN_FRESHNESS="    ${C_RED}⚠️${C_RESET}  ${C_BOLD}MAIN STALE${C_RESET}${C_RED} — ${_bf_delta} · ${_bf_why}${C_RESET}"$'\n'
  fi
  if [ -s "${MAIN_FRESH_RESTART:-}" ]; then
    # HERD-251: with WATCHER_SELF_RESTART=on the note is no longer a request for the operator — the
    # watcher is already draining toward its own in-place re-exec, so say so (and name the workers it
    # is still waiting on). With the lever off (or before the quiesce arms) the row is unchanged.
    if _self_restart_quiescing; then
      MAIN_FRESHNESS="${MAIN_FRESHNESS}    ${C_YELLOW}⟳${C_RESET}  ${C_DIM}restarting on new engine code · draining $(_count_gate_workers) gate workers${C_RESET}"$'\n'
    else
      MAIN_FRESHNESS="${MAIN_FRESHNESS}    ${C_YELLOW}⬆${C_RESET}  ${C_DIM}main pulled new engine code — this watcher still runs the old one · restart recommended (\`herd reload\`)${C_RESET}"$'\n'
    fi
  fi
}

# build_checkout_cleanliness — the HERD-361 shared-checkout cleanliness row, read from the state file
# reconcile_checkout_cleanliness writes (absent on the happy path → renders NOTHING, console stays
# byte-identical). A LOUD row when $MAIN carries staged/tracked contamination (the fingerprint of a
# suite test that staged in $PWD) or sits detached: it names the count + the offending paths so an
# operator can root-cause, and says the evidence is preserved (nothing was discarded).
build_checkout_cleanliness() {
  CHECKOUT_CLEAN=""
  [ -s "${CHECKOUT_CLEAN_STATE:-}" ] || return 0
  local _bc_i=0 _bc_head="" _bc_det="" _bc_line _bc_n=0 _bc_paths="" _bc_why=""
  while IFS= read -r _bc_line; do
    _bc_i=$((_bc_i + 1))
    case "$_bc_i" in
      1) continue ;;                     # line 1 = dedup signature (not for display)
      2) _bc_head="$_bc_line"; continue ;;
      3) _bc_det="$_bc_line"; continue ;;
    esac
    [ -n "$_bc_line" ] || continue
    _bc_n=$((_bc_n + 1))
    if [ "$_bc_n" -le 4 ]; then
      if [ -z "$_bc_paths" ]; then _bc_paths="$_bc_line"; else _bc_paths="$_bc_paths, $_bc_line"; fi
    fi
  done < "$CHECKOUT_CLEAN_STATE"
  [ "$_bc_det" = "detached" ] && _bc_why="DETACHED HEAD"
  if [ "$_bc_n" -gt 0 ]; then
    local _bc_more=""
    [ "$_bc_n" -gt 4 ] && _bc_more=" (+$((_bc_n - 4)) more)"
    local _bc_pathpart="${_bc_n} contaminated path(s): ${_bc_paths}${_bc_more}"
    if [ -n "$_bc_why" ]; then _bc_why="${_bc_why} + ${_bc_pathpart}"; else _bc_why="$_bc_pathpart"; fi
  fi
  CHECKOUT_CLEAN="    ${C_RED}🚨 ${C_BOLD}CHECKOUT UNCLEAN${C_RESET}${C_RED} — ${_bc_why} · a tool wrote the shared checkout; investigate in ${MAIN} before discarding (evidence preserved, never auto-cleaned)${C_RESET}"$'\n'
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

# ── Closed operator-facing console vocabulary (HERD-172) ──────────────────────────────────────────
# An operator scans this console for the ONE row that needs THEM. A row that just says "idle" defeats
# that scan: it has no OWNER (whose move is it?) and no AGE (fresh-and-fine, or forgotten-and-stuck?),
# so it reads identically whether the herd is healthy-and-waiting or quietly wedged. The word is BANNED
# from operator-facing rows. Every non-working row instead names its owner and carries an age, drawn
# from this closed set (the states #289's async dispatch/collect machinery already tracks — this layer
# only gives them a consistent, honest vocabulary):
#   • working                            — the HERD's move; a builder/gate is making progress
#                                          (building… · health-check · running 3m · review · running …).
#   • awaiting task · assign or retire   — YOUR move; a live spare builder finished/never-tasked, and a
#                                          SUCCESSFUL open-PR list positively has no PR for its branch
#                                          (HERD-224). Carries the idle age so a just-freed spare (0s)
#                                          reads apart from a forgotten one (2h, reap it). Calm — benign.
#                                          RESERVED (HERD-164) for a genuinely UNASSIGNED, pre-PR builder:
#                                          a merged/closed slug is 'retiring…', never a spare.
#   • finished without PR · wake or …    — YOUR move; the agent reads 'done' but its branch has no PR
#                                          and nothing that could become one (HERD-278). A WEDGE, never
#                                          a ✅ and never an 'awaiting task' spare. Red, with the age.
#   • PR match pending · retrying        — the HERD's move; open-PR roster fetch failed this tick
#                                          (HERD-224). Neutral/degraded — never the definitive
#                                          "awaiting task" claim from a lookup FAILURE.
#   • retiring… · <leftovers> · <age>    — the HERD's move; a merged/closed slug whose teardown is
#                                          converging this tick (see retirement.sh). Calm — it clears
#                                          itself, usually within one tick.
#   • parked · <cause> · retry <eta>     — the HERD's move; auto-recovering on its own (a limit-hit
#                                          auto-resume names its reset ETA; see _handle_limit_blocked).
#   • needs-you · <blocker> · <remedy>   — YOUR move; a red hold that will NOT clear itself (dead
#                                          builder, not-mergeable, stale/duplicate, review-infra failed).
# A closed-vocabulary guard test greps this file's DISPLAY[…] assignments and fails on any 'idle' word,
# so the ban is a ratchet, not a convention. FLAIR_STATE tokens are INTERNAL enums (they map to pasture
# glyphs, never to operator text), so 'idle' survives there unchanged — the flair frame stays byte-exact.

# _row_awaiting_task <slug-cell> <worktree> — the closed-vocabulary console row for a live, non-working
# builder that has no PR: a spare awaiting a task. Renders (calm/dim — benign, never a red alarm) the
# owner (yours: assign work or retire the worktree) and the age since the worktree was born, so the row
# answers whose-move-is-it AND how long it has waited. Replaces the banned, ownerless, ageless
# "idle · no PR". Age uses _now_epoch (HERD_FAKE_NOW-overridable) so it is deterministic under test.
# ONLY call this when a SUCCESSFUL open-PR list positively contains no PR for the branch (HERD-224);
# a failed/empty-from-error `gh pr list` must use _row_pr_match_pending instead.
_row_awaiting_task() {
  local _sl="$1" _wt="$2" _age _born
  _born="$(_worktree_born "$_wt")"
  _age="$(_fmt_age "$(( $(_now_epoch) - _born ))")"
  printf '    %s💤%s %s%s%s %sawaiting task · assign or retire · %s%s' \
    "$C_DIM" "$C_RESET" "$C_BOLD" "$_sl" "$C_RESET" "$C_DIM" "$_age" "$C_RESET"
}

# _row_wedged <slug-cell> <age> [woken] — the console row for a WEDGED builder (HERD-278): an agent
# that reads 'done' over a branch with no PR and nothing that could become one. It is NOT a spare
# ("awaiting task" would invite you to retire a builder that never delivered its work) and it is NOT
# a success — three live incidents on 2026-07-09 were coordinator-woken by hand. RED (⚠️): the herd
# will not clear this on its own, so it is YOUR move, and the remedy is named. Carries the age it has
# been wedged so a 10m-old one reads apart from an all-night one.
# With [woken] non-empty the auto-wake nudge (WEDGE_AUTOWAKE, default off) has just been delivered —
# the herd's move again, so the row is calm 🔁 and says so rather than asking you to do it twice.
_row_wedged() {
  local _sl="$1" _age="$2" _woken="${3:-}"
  if [ -n "$_woken" ]; then
    printf '    %s🔁%s %s%s%s %sfinished without PR · auto-wake sent · %s%s' \
      "$C_CYAN" "$C_RESET" "$C_BOLD" "$_sl" "$C_RESET" "$C_CYAN" "$_age" "$C_RESET"
  else
    printf '    %s⚠️%s  %s%s%s %sfinished without PR · wake or inspect · %s%s' \
      "$C_RED" "$C_RESET" "$C_BOLD" "$_sl" "$C_RESET" "$C_RED" "$_age" "$C_RESET"
  fi
}

# _row_retirement <slug-cell> <slug> <state> <detail> — the console row for a slug the retirement
# invariant (HERD-164, retirement.sh) is reconciling. Three states, three owners:
#
#   retiring  the HERD's move — teardown is converging; <detail> is the comma-joined leftover kinds
#             (worktree,tab,agent,branch,ledger). CALM (dim ♻️): it clears itself, and a single
#             non-converged tick is normal (a herdr tab close is a round-trip). Carries the age it has
#             been converging so a wedged one is legible before it even turns red.
#   stuck     YOUR move — teardown has failed _RETIRE_STUCK_TICKS ticks running. RED, and it NAMES the
#             blocker (the first leftover kind that would not die) plus the remedy.
#   deferred  the HERD's move — terminal + disposable, but a builder is still WORKING in the tree
#             (HERD-356). CALM-but-visible (⏸️ yellow, never red — nothing is wrong, we are waiting): the
#             reap runs itself the moment the agent goes idle. <detail> names why.
#   held      YOUR move — the slug is terminal but carries REAL WORK (uncommitted tracked files, or
#             commits that exist nowhere else). RED, with the evidence verbatim. Retirement will not
#             touch it, this tick or ever, until a human commits or discards.
#
# Never renders the banned 'idle' word, and never renders 'awaiting task' — a merged builder is not a
# spare. Pure formatter (age is read from the escalation state), so the unit test can pin its bytes.
_row_retirement() {
  local _sl="$1" _slug="$2" _state="$3" _detail="$4" _age
  _age="$(_retire_age "$_slug")"
  case "$_state" in
    stuck)
      printf '    %s⚠️%s  %s%s%s %sneeds-you · retirement stuck: %s · run `herd sweep` or close it by hand · %s%s' \
        "$C_RED" "$C_RESET" "$C_BOLD" "$_sl" "$C_RESET" "$C_RED" "$_detail" "$_age" "$C_RESET" ;;
    deferred)
      printf '    %s⏸️%s  %s%s%s %sreap deferred · %s · %s%s' \
        "$C_YELLOW" "$C_RESET" "$C_BOLD" "$_sl" "$C_RESET" "$C_YELLOW" "$_detail" "$_age" "$C_RESET" ;;
    held)
      printf '    %s⚠️%s  %s%s%s %sneeds-you · %s%s' \
        "$C_RED" "$C_RESET" "$C_BOLD" "$_sl" "$C_RESET" "$C_RED" "$_detail" "$C_RESET" ;;
    *)
      printf '    %s♻️%s  %s%s%s %sretiring… · %s · %s%s' \
        "$C_DIM" "$C_RESET" "$C_BOLD" "$_sl" "$C_RESET" "$C_DIM" "$_detail" "$_age" "$C_RESET" ;;
  esac
}

# build_retiring — the "retiring" console block: one row per retirement candidate whose WORKTREE IS
# ALREADY GONE, so it can never appear among the in-flight (worktree-derived) rows — the merged builder
# whose tab, agent, or ledger row outlived its tree. Slugs that still HAVE a worktree are rendered
# inline by the tick loop's classifier instead, so nothing is listed twice. Empty (byte-identical
# console) whenever every slug has converged — the healthy steady state.
build_retiring() {
  RETIRING=""
  local i
  for i in "${!RETIRE_SLUG[@]}"; do
    local _slug="${RETIRE_SLUG[i]}" _dir="${RETIRE_DIR[i]}"
    [ -n "$_dir" ] && [ -d "$_dir" ] && continue
    RETIRING="${RETIRING}$(_row_retirement "$(_slug_cell "$_slug")" "$_slug" "${RETIRE_STATE[i]}" "${RETIRE_DETAIL[i]}")"$'\n'
  done
}

# _row_pr_match_pending <slug-cell> — NEUTRAL/degraded console row when the open-PR roster could not
# be fetched this tick (HERD-224). GROUNDED: a `gh pr list` blip (or the old `|| echo '[]'` collapse)
# used to paint "awaiting task · assign or retire" for builders that HAD an open PR — a definitive
# "this builder has no work" claim from a lookup FAILURE. This row is calm (not needs-you/💀), names
# the transient, and never says "awaiting task". Next tick retries the fetch.
_row_pr_match_pending() {
  local _sl="$1"
  printf '    %s⏳%s %s%s%s %sPR match pending · retrying%s' \
    "$C_DIM" "$C_RESET" "$C_BOLD" "$_sl" "$C_RESET" "$C_DIM" "$C_RESET"
}

# ── Watcher-console FLAIR pack (HERD-147) ─────────────────────────────────────────────────────────
# An ADDITIVE cosmetic layer, gated by WATCHER_FLAIR (default off). Two surfaces, both assembled from
# state the watcher already computes, both colored ONLY via theme.sh's C_* vars (so NO_COLOR / non-tty
# renders plain):
#   • merge CELEBRATION — the status tick after a merge prints one line '🐑 #<pr> joins the flock ·
#     <n> grazing' (n = builders still building this tick). do_merge drops a self-clearing marker;
#     build_celebrate turns it into the line and consumes it, so it shows exactly once.
#   • PASTURE HEADER — one line rendering the in-flight herd by state, one glyph per builder in the
#     same order as the "in flight" rows below it (🐑 grazing = building, 💤 idle, ✅ in the pen = done).
# HARD RULE (proven by the sim + units): flair NEVER softens a red/dead/needs-you state. A dead builder
# is 💀 red and a needs-you builder is ⚠️ red in the header — exactly as loud as their rows — and OFF is
# byte-inert: build_celebrate/build_pasture leave CELEBRATE/PASTURE empty so render() emits nothing new.
FLAIR_CELEBRATE_STATE="$TREES/.agent-watch-flair-celebrate"   # pending merged-PR numbers, one per line

# _flair_enabled — true iff WATCHER_FLAIR opts in. Default OFF (mirrors _main_health_enabled); any
# unrecognized value reads as off (fail toward the byte-identical console).
_flair_enabled() {
  case "$(printf '%s' "${WATCHER_FLAIR:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _flair_glyph <state-token> — echo the theme-colored glyph for one builder state. The calm states get
# the cozy flair glyphs; every attention/dead state keeps its LOUD color+glyph (never softened). An
# unknown token falls back to a dim 🐑 (a benign herd member), never a colored alarm.
_flair_glyph() {
  case "$1" in
    grazing)   printf '%s🐑%s' "$C_GREEN"  "$C_RESET" ;;   # building
    idle)      printf '%s💤%s' "$C_DIM"    "$C_RESET" ;;   # awaiting task (spare builder, no PR)
    pen)       printf '%s✅%s' "$C_GREEN"  "$C_RESET" ;;   # done / ready
    dead)      printf '%s💀%s' "$C_RED"    "$C_RESET" ;;   # dead builder — LOUD, byte-as-today
    attention) printf '%s⚠️%s'  "$C_RED"    "$C_RESET" ;;   # needs-you / not-mergeable / failed — LOUD
    warn)      printf '%s⚠️%s'  "$C_YELLOW" "$C_RESET" ;;   # stalled "no activity · check pane"
    busy)      printf '%s🩺%s' "$C_YELLOW" "$C_RESET" ;;   # in-progress gate (health-check / resolving / limit-resume / waiting)
    verify)    printf '%s🔍%s' "$C_DIM"    "$C_RESET" ;;   # verifying mergeability
    other)     printf '%s👥%s' "$C_DIM"    "$C_RESET" ;;   # not mine — manual (team mode)
    self)      printf '%s🐑%s' "$C_DIM"    "$C_RESET" ;;   # the watcher's own worktree
    *)         printf '%s🐑%s' "$C_DIM"    "$C_RESET" ;;
  esac
}

# _flair_celebration_line <pr#> <n-grazing> — the pure formatter for ONE merge-celebration line
# (no trailing newline). Themed: a green 🐑 headline + a dim tail. NO_COLOR/non-tty → the C_* are blank
# so it degrades to plain text. Kept pure (no I/O, no globals) so the unit test can pin its exact bytes.
_flair_celebration_line() {
  printf '  %s🐑 #%s joins the flock%s %s· %s grazing%s' \
    "$C_GREEN" "$1" "$C_RESET" "$C_DIM" "$2" "$C_RESET"
}

# build_celebrate <n-grazing> — set CELEBRATE from the pending-merge marker (one celebration line per
# just-merged PR), then CONSUME the marker so each merge is celebrated exactly once. Empty (byte-inert)
# when flair is off or nothing merged since the last tick — so render() adds nothing.
build_celebrate() {
  CELEBRATE=""
  _flair_enabled || return 0
  [ -s "$FLAIR_CELEBRATE_STATE" ] || return 0
  local _bc_n="${1:-0}" pr rows=""
  case "$_bc_n" in ''|*[!0-9]*) _bc_n=0 ;; esac
  while read -r pr _; do
    case "$pr" in ''|*[!0-9]*) continue ;; esac
    rows="${rows}$(_flair_celebration_line "$pr" "$_bc_n")"$'\n'
  done < "$FLAIR_CELEBRATE_STATE"
  rm -f "$FLAIR_CELEBRATE_STATE" 2>/dev/null || true
  CELEBRATE="$rows"
}

# build_pasture — set PASTURE to a single header line rendering each in-flight builder by state, one
# glyph per FLAIR_STATE[] entry (parallel-indexed to DISPLAY[], populated in the classification loop),
# in row order. Empty (byte-inert) when flair is off OR there are no builders — so a byte-identical
# console when the feature is unused and no "empty pasture" line when the herd is idle.
build_pasture() {
  PASTURE=""
  _flair_enabled || return 0
  [ "${#FLAIR_STATE[@]}" -gt 0 ] || return 0
  local st glyphs=""
  for st in "${FLAIR_STATE[@]}"; do
    [ -n "$st" ] || st=grazing
    glyphs="${glyphs}$(_flair_glyph "$st") "
  done
  [ -n "$glyphs" ] || return 0
  PASTURE="  ${C_DIM}pasture${C_RESET}  ${glyphs% }"$'\n'
}

# ── Operator inbox (HERD-184) ─────────────────────────────────────────────────────────────────────
# Cross-seat coordination messages were being left as PR/tracker comments, but NO engine feature read
# incoming comments — so an autonomous coordinator never saw a "don't self-merge, main broke" reply.
# This ADDITIVE reader surfaces NEW comments by OTHER authors as a needs-you-adjacent console section
# plus one notify-once per comment. TWO feeds, one surface:
#   (1) PR-COMMENT feed — new comments by non-self authors on the open PRs this seat authors/gates
#       (the tick's ALREADY-FETCHED PR set — the core tick's `gh pr list --json` fields are unchanged;
#       comments are pulled by a SEPARATE, gated `gh pr view --json comments`, only when enabled).
#   (2) TRACKER feed — new comments by other operators on items this seat claimed, via the active
#       backend's OPTIONAL _backend_list_inbox_comments op (linear only; absent elsewhere → feed empty).
# CONTRACT: default-off / ship-dormant, fail-soft (a missing reader / api error / no creds = empty
# inbox, never a red row), byte-identical when off. It is DISPLAY + NOTIFY only — it never touches the
# gate loop or a merge decision. _inbox_scan does the (gated, interval-throttled) fetch + dedup +
# notify + ledger append; build_operator_inbox is a pure renderer of the ledger tail.

# _operator_inbox_enabled — true iff OPERATOR_INBOX opts in. Default OFF (mirrors _flair_enabled); any
# unrecognized value reads as off (fail toward the byte-identical console).
_operator_inbox_enabled() {
  case "$(printf '%s' "${OPERATOR_INBOX:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _inbox_flatten <text> — whitespace-flatten + cap a comment snippet so it can never inject a TAB /
# newline into the ledger's TSV shape or blow up a console row. Prints at most 120 chars.
_inbox_flatten() {
  TEXT="${1:-}" python3 -c 'import os
s = " ".join((os.environ.get("TEXT") or "").split())
print(s if len(s) <= 120 else s[:119].rstrip() + "…")' 2>/dev/null || true
}

# _inbox_seen <key> — 0 if this comment key ("pr:<id>" / "tr:<id>") was already surfaced. Fail-soft
# (no ledger → not seen).
_inbox_seen() {
  [ -s "$INBOX_SEEN_STATE" ] || return 1
  grep -qxF -- "$1" "$INBOX_SEEN_STATE" 2>/dev/null
}

# _inbox_mark_seen <key> — record a comment key as surfaced (append-only). The dedup ledger is bounded
# by _inbox_trim_seen, called ONCE at the end of a scan so the trim can see the full live set for the
# tick (a per-append tail-trim can't — it would evict a still-live id and re-notify it, HERD-213).
_inbox_mark_seen() {
  printf '%s\n' "$1" >> "$INBOX_SEEN_STATE" 2>/dev/null || return 0
}

# _inbox_note_live <key> — record a comment key as OBSERVED this tick (its PR/tracker item is still
# open and the comment still present), so the retention-aware trim keeps it. Appended for EVERY comment
# the scan sees, whether or not it was already surfaced.
_inbox_note_live() {
  printf '%s\n' "$1" >> "$INBOX_SEEN_LIVE" 2>/dev/null || return 0
}

# _inbox_trim_seen — retention-aware trim of the dedup ledger ($INBOX_SEEN_STATE) to INBOX_SEEN_MAX.
# A naive `tail -n MAX` evicts the OLDEST ids, but an old id can still be LIVE — its comment is still
# on an open PR / open tracker item this tick — and dropping it makes the NEXT scan see it as unseen and
# re-notify it (HERD-213). So this keeps EVERY live id (the ids observed this tick in $INBOX_SEEN_LIVE)
# and evicts only SETTLED ids (no longer observed — their PR/item closed), dropping the oldest settled
# first to fill the cap budget. No-op when under the cap; with an empty/absent live set it degrades to
# the old oldest-first eviction (nothing is live → everything is settled). Called once per _inbox_scan.
_inbox_trim_seen() {
  [ -s "$INBOX_SEEN_STATE" ] || return 0
  local n; n="$(wc -l < "$INBOX_SEEN_STATE" 2>/dev/null || echo 0)"
  [ "${n:-0}" -gt "$INBOX_SEEN_MAX" ] || return 0
  local keep; keep="$(mktemp "${INBOX_SEEN_STATE}.XXXXXX" 2>/dev/null || true)"
  [ -n "$keep" ] || return 0
  if SEEN_MAX="$INBOX_SEEN_MAX" LIVE_FILE="$INBOX_SEEN_LIVE" \
     python3 -c 'import os, sys
cap = int(os.environ.get("SEEN_MAX") or 0)
live_path = os.environ.get("LIVE_FILE") or ""
live = set()
if live_path:
    try:
        with open(live_path) as f:
            live = {ln.strip() for ln in f if ln.strip()}
    except OSError:
        live = set()
seen = [ln.rstrip("\n") for ln in sys.stdin]
# Drop the OLDEST settled ids first (iterate oldest→newest, appended order) until size <= cap; never
# drop a live id. If live ids alone exceed the cap they are ALL kept (bounded by real open activity).
drop = max(0, len(seen) - cap)
out = []
for s in seen:
    if drop > 0 and s not in live:
        drop -= 1
        continue
    out.append(s)
sys.stdout.write("".join(s + "\n" for s in out))' < "$INBOX_SEEN_STATE" > "$keep" 2>/dev/null; then
    mv -f "$keep" "$INBOX_SEEN_STATE" 2>/dev/null || rm -f "$keep" 2>/dev/null
  else
    rm -f "$keep" 2>/dev/null
  fi
}

# _inbox_record <source> <ref> <author> <snippet> — append ONE ledger entry (epoch-stamped) and trim
# the ledger to its most recent INBOX_LEDGER_MAX rows. TAB-separated so a snippet with spaces is safe.
_inbox_record() {
  local src="$1" ref="$2" author="$3" snip="$4" now
  now="$(date +%s 2>/dev/null || echo 0)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$src" "$ref" "${author:-operator}" "$snip" >> "$INBOX_LEDGER" 2>/dev/null || return 0
  local n; n="$(wc -l < "$INBOX_LEDGER" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt "$INBOX_LEDGER_MAX" ]; then
    local keep; keep="$(mktemp "${INBOX_LEDGER}.XXXXXX" 2>/dev/null || true)"
    [ -n "$keep" ] || return 0
    tail -n "$INBOX_LEDGER_MAX" "$INBOX_LEDGER" > "$keep" 2>/dev/null && mv -f "$keep" "$INBOX_LEDGER" 2>/dev/null || rm -f "$keep" 2>/dev/null
  fi
}

# _inbox_fetch_pr_comments <pr#> — the ONE network call of the PR feed, isolated so a test can stub it
# (or the `gh` it calls). Prints the PR's comments as JSON ({"comments":[…]}); empty JSON on any error
# (fail-soft — a gh hiccup yields an empty inbox, never a red row).
_inbox_fetch_pr_comments() {
  _gh_timeout inbox_comments pr view "$1" --json comments 2>/dev/null || printf '{"comments":[]}'
}

# _inbox_extract_pr_comments — pure filter: read a `gh pr view --json comments` JSON on stdin and,
# for every comment whose author is present AND is NOT $OWNER, print "<id>\t<login>\t<snippet>". The
# self-exclusion is what makes it "comments by OTHER authors"; an empty OWNER excludes nothing (still
# fail-soft). Kept a pure stdin→stdout filter so the unit test can pin its behavior with a fixture.
_inbox_extract_pr_comments() {
  OWNER="${1:-}" python3 -c 'import sys, json, os
owner = os.environ.get("OWNER") or ""
def flat(s):
    s = " ".join((s or "").split())
    return s if len(s) <= 120 else s[:119].rstrip() + "…"
try: d = json.load(sys.stdin)
except Exception: d = {}
for c in (d.get("comments") or []):
    login = ((c.get("author") or {}).get("login") or "").strip()
    if not login or (owner and login == owner):
        continue
    cid = str(c.get("id") or c.get("url") or "").strip()
    if not cid:
        continue
    print("%s\t%s\t%s" % (cid, login, flat(c.get("body"))))' 2>/dev/null || true
}

# _inbox_pr_numbers — pure filter: read the tick's `gh pr list` JSON on stdin, print one open PR
# number per line. (The "open PRs this seat authors or is gating" set is exactly the tick's viewed
# PRs; surfacing comments by OTHERS on them covers both "a PR I opened" and "a PR I'm gating".)
_inbox_pr_numbers() {
  python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = []
for p in (d or []):
    n = p.get("number")
    if n not in (None, ""):
        print(n)' 2>/dev/null || true
}

# _inbox_scan <prs_json> — refresh both feeds. GATED (no-op unless enabled) and only invoked on the
# throttled inbox interval, so the 4s repaint never triggers a network fetch. For each NEW (unseen)
# comment by another author it appends a ledger entry and fires ONE notification. Every step is
# fail-soft: a gh error, a missing backend op, or absent creds simply yields fewer/zero entries.
_inbox_scan() {
  _operator_inbox_enabled || return 0
  local prs_json="${1:-[]}" owner prnum cid author snip line
  _resolve_watcher_owner
  owner="$(_watcher_owner_login)"

  # Reset the per-tick live set: every comment observed below is noted live so the end-of-scan
  # retention-aware trim (HERD-213) keeps still-live ids and evicts only settled ones.
  : > "$INBOX_SEEN_LIVE" 2>/dev/null || true

  # (1) PR-COMMENT feed — comments by OTHERS on the tick's open PRs. Self-exclusion is by owner login
  # (_inbox_extract_pr_comments drops comments whose author == $owner). When the seat's identity is
  # UNRESOLVED ($owner empty), that match is a no-op, so the feed would surface the seat's OWN comments
  # as inbox noise (HERD-212). Rather than flood with self-authored comments, skip the PR feed entirely
  # until an identity resolves — an unresolved owner yields ZERO self-authored comments, not all of them.
  # (The tracker feed self-excludes at the backend, so it is unaffected by an empty owner login.)
  if [ -n "$owner" ]; then
    while IFS= read -r prnum; do
      [ -n "$prnum" ] || continue
      while IFS=$'\t' read -r cid author snip; do
        [ -n "$cid" ] || continue
        _inbox_note_live "pr:$cid"
        _inbox_seen "pr:$cid" && continue
        _inbox_mark_seen "pr:$cid"
        _inbox_record pr "#$prnum" "$author" "$snip"
        herd_driver_notify "📬 inbox · PR #${prnum}" "${author}: ${snip}" default
      done < <(_inbox_fetch_pr_comments "$prnum" | _inbox_extract_pr_comments "$owner")
    done < <(printf '%s' "$prs_json" | _inbox_pr_numbers)
  fi

  # (2) TRACKER feed — comments by OTHER operators on items this seat claimed, via the backend's
  # OPTIONAL comment reader (linear only). Sourced in a SUBSHELL (secrets + backend, exactly the
  # _reconcile_via_ref pattern) so the _backend_* helpers never leak into the watcher namespace; a
  # backend with no such op prints nothing. Output: "#<ref>\t<author>\t<comment-id>\t<snippet>".
  local _bdir _bfile ref
  _bdir="${SCRIBE_BACKEND_DIR:-$HERE/backends}"
  _bfile="$_bdir/${SCRIBE_BACKEND:-file}.sh"
  if [ -f "$_bfile" ]; then
    while IFS=$'\t' read -r ref author cid snip; do
      [ -n "$cid" ] || continue
      _inbox_note_live "tr:$cid"
      _inbox_seen "tr:$cid" && continue
      _inbox_mark_seen "tr:$cid"
      _inbox_record tracker "$ref" "$author" "$(_inbox_flatten "$snip")"
      herd_driver_notify "📬 inbox · ${ref}" "${author}: ${snip}" default
    done < <(
      _secrets="$MAIN/.herd/secrets"
      # shellcheck source=/dev/null
      [ -f "$_secrets" ] && . "$_secrets"
      # shellcheck source=/dev/null
      . "$_bfile" 2>/dev/null || exit 0
      command -v _backend_list_inbox_comments >/dev/null 2>&1 || exit 0
      cd "$MAIN" 2>/dev/null || exit 0
      _backend_list_inbox_comments 2>/dev/null || true
    )
  fi

  # Bound the dedup ledger ONCE, now that the full live set for this tick is known — retention-aware, so
  # a still-live id is never evicted at the cap and re-notified (HERD-213).
  _inbox_trim_seen
}

# build_operator_inbox — the "operator inbox" section: the most recent INBOX ledger entries, newest
# first, one row each. Empty (OPERATOR_INBOX_ROWS="") when the feature is off OR the ledger is
# absent/empty, so render() omits the section and the console is byte-identical when unused. A pure
# renderer — no fetch, no network (that is _inbox_scan's job). Themed via C_* (plain under NO_COLOR).
build_operator_inbox() {
  OPERATOR_INBOX_ROWS=""
  _operator_inbox_enabled || return 0
  [ -s "$INBOX_LEDGER" ] || return 0
  local epoch source ref author snip hhmm glyph rows=""
  while IFS=$'\t' read -r epoch source ref author snip; do
    [ -n "${ref:-}" ] || continue
    hhmm="$(epoch_to_hhmm "$epoch")"
    case "$source" in tracker) glyph='🗂' ;; audit) glyph='🔎' ;; *) glyph='📬' ;; esac
    rows="${rows}    ${C_CYAN}${glyph}${C_RESET} ${C_BOLD}${ref}${C_RESET} ${C_DIM}@${author}${C_RESET} ${snip} ${C_DIM}${hhmm}${C_RESET}"$'\n'
  done < <(reverse_file "$INBOX_LEDGER" | head -5)  # pipe-ok: head in a command or process substitution; pipeline status not gated
  [ -n "$rows" ] && OPERATOR_INBOX_ROWS="$rows"
}

# ── Builder notes (HERD-202) ──────────────────────────────────────────────────────────────────────
# `_builder_notes_scan` drains NEW builder_note journal events past the cursor into the ledger + one
# notify each; `build_builder_notes` is the pure console renderer. Both are fail-soft (missing
# journal / unreadable path / python fail = no-op). First scan with no cursor pins the cursor at EOF
# so a watcher restart never re-notifies historical notes.

# _builder_notes_journal — resolve the live journal path (JOURNAL_FILE test seam wins; else the
# standard $TREES/.herd/journal.jsonl the engine writers use). Empty → no destination.
_builder_notes_journal() {
  if [ -n "${JOURNAL_FILE:-}" ]; then printf '%s' "$JOURNAL_FILE"; return 0; fi
  [ -n "${TREES:-}" ] || return 1
  printf '%s' "$TREES/.herd/journal.jsonl"
}

# _builder_notes_scan — consume builder_note events past BUILDER_NOTES_CURSOR. For each new event:
# append a ledger row + fire herd_driver_notify once. Advances the cursor to the end of the journal
# (or to the last complete line consumed). Fail-soft: never breaks the watch loop.
_builder_notes_scan() {
  local jf; jf="$(_builder_notes_journal 2>/dev/null)" || return 0
  [ -n "$jf" ] && [ -f "$jf" ] || return 0

  local sz; sz="$(wc -c < "$jf" 2>/dev/null | tr -cd '0-9')"; sz="${sz:-0}"
  [ "$sz" -gt 0 ] 2>/dev/null || return 0

  # First scan: pin cursor at EOF so historical noise never floods the console/notify stream.
  if [ ! -f "$BUILDER_NOTES_CURSOR" ]; then
    printf '%s' "$sz" > "$BUILDER_NOTES_CURSOR" 2>/dev/null || true
    return 0
  fi

  local off; off="$(tr -cd '0-9' < "$BUILDER_NOTES_CURSOR" 2>/dev/null)"; off="${off:-0}"
  # Journal rotated/truncated (new file smaller than cursor) → reset to 0 and re-scan the live file.
  [ "$off" -gt "$sz" ] 2>/dev/null && off=0
  [ "$sz" -le "$off" ] 2>/dev/null && return 0

  # Extract builder_note rows after the cursor; print new cursor offset on the last line as
  # "__CURSOR__ <n>". One python pass keeps UTF-8 + partial-line handling correct.
  local out
  out="$(JF="$jf" OFF="$off" python3 -c '
import os, json, sys
path = os.environ["JF"]
off = int(os.environ.get("OFF") or "0")
try:
    f = open(path, "rb")
except OSError:
    sys.exit(0)
with f:
    size = f.seek(0, 2)
    if off > size:
        off = 0
    f.seek(off)
    if off > 0:
        # Ensure we start at a line boundary (skip a partial first line after a mid-line seek).
        f.seek(off - 1)
        if f.read(1) != b"\n":
            f.readline()
    pos = f.tell()
    rows = []
    while True:
        line = f.readline()
        if not line:
            break
        pos = f.tell()
        try:
            raw = line.decode("utf-8", errors="replace").strip()
        except Exception:
            continue
        if not raw:
            continue
        try:
            o = json.loads(raw)
        except Exception:
            continue
        if o.get("event") != "builder_note":
            continue
        ts = str(o.get("ts") or "")
        slug = str(o.get("slug") or "?")
        text = str(o.get("text") or o.get("note") or "")
        text = " ".join(text.split())
        if len(text) > 300:
            text = text[:299].rstrip() + "…"
        # TAB-safe (ledger is TSV).
        text = text.replace("\t", " ")
        rows.append("%s\t%s\t%s" % (ts, slug, text))
    for r in rows:
        print(r)
    print("__CURSOR__ %d" % pos)
' 2>/dev/null)" || true

  local new_off="$off" line ts slug text epoch
  while IFS= read -r line; do
    case "$line" in
      "__CURSOR__ "*) new_off="${line#__CURSOR__ }"; new_off="$(printf '%s' "$new_off" | tr -cd '0-9')" ;;
      *)
        [ -n "$line" ] || continue
        IFS=$'\t' read -r ts slug text <<EOF
$line
EOF
        [ -n "${slug:-}" ] || continue
        epoch="$(_now_epoch)"
        printf '%s\t%s\t%s\t%s\n' "$epoch" "$slug" "$text" "$ts" >> "$BUILDER_NOTES_LEDGER" 2>/dev/null || true
        herd_driver_notify "📝 builder note · ${slug}" "${text}" default
        ;;
    esac
  done <<< "$out"

  [ -n "$new_off" ] && printf '%s' "$new_off" > "$BUILDER_NOTES_CURSOR" 2>/dev/null || true

  # Bound BOTH ledger files on write (tail-keep, shared helper): the notes ledger and its ack
  # sidecar, so neither surface can grow unbounded.
  herd_console_trim "$BUILDER_NOTES_LEDGER" "$BUILDER_NOTES_LEDGER_MAX"
  herd_console_trim "$BUILDER_NOTES_ACK" "$BUILDER_NOTES_LEDGER_MAX"
}

# _builder_note_row — render ONE note ledger line ("<epoch>\t<slug>\t<text>\t<ts>").
_builder_note_row() {
  local epoch slug text ts hhmm
  IFS=$'\t' read -r epoch slug text ts <<EOF
$1
EOF
  [ -n "${slug:-}" ] || return 1
  hhmm="$(epoch_to_hhmm "$epoch")"
  printf '    %s📝%s %s%s%s %s %s%s%s' \
    "$C_CYAN" "$C_RESET" "$C_BOLD" "$slug" "$C_RESET" "${text:-}" "$C_DIM" "$hhmm" "$C_RESET"
}

# build_builder_notes — the "builder notes" console section: the newest 5 STILL-RELEVANT ledger
# entries, newest first. Empty (BUILDER_NOTES_ROWS="") when the ledger is absent/empty — or when every
# note has been acked or aged out — so render() omits the section and the console is byte-identical
# when unused. Pure renderer — no journal I/O.
# Notes are CALM by definition, so (HERD-243, shared bounded-section helper) each one leaves the
# DISPLAY after CONSOLE_ROW_RETENTION, and `herd notes ack <all|n>` clears one immediately. Neither
# touches the journal: the history of every note survives both.
build_builder_notes() {
  BUILDER_NOTES_ROWS=""
  local rows
  rows="$(herd_console_section "$BUILDER_NOTES_LEDGER" 5 \
    herd_console_classify_builder_note _builder_note_row "$BUILDER_NOTES_ACK")"
  [ -n "$rows" ] && BUILDER_NOTES_ROWS="${rows}"$'\n'
  return 0
}

# ── Orphan PRs (HERD-330) ─────────────────────────────────────────────────────────────────────────
# `_orphan_prs_scan` rewrites the orphan-PR ledger each tick from the world it OBSERVED (PRS_JSON minus
# the PRs the discovered worktrees claim); `build_orphan_prs` is the pure console renderer of its tail.
# Both self-gate on ORPHAN_PR_ROWS so an off (or no-orphan) watcher is byte-identical to before.

# _orphan_pr_rows_enabled — true iff ORPHAN_PR_ROWS opts in. Default OFF (mirrors _operator_inbox_enabled);
# any unrecognized value reads as off (fail toward the byte-identical console).
_orphan_pr_rows_enabled() {
  case "$(printf '%s' "${ORPHAN_PR_ROWS:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _orphan_pr_classify <line>  ("<epoch>\t<pr>\t<title>\t<branch>")
#   Prints "<epoch>\tcalm" for the shared bounded-section renderer. Every orphan row is advisory: the
#   ledger is rewritten whole each tick with a fresh epoch, so a still-orphan PR is always visible and
#   an adopted/closed one simply stops being written (no stale row lingers).
_orphan_pr_classify() {
  local _op_epoch
  IFS=$'\t' read -r _op_epoch _ <<EOF
$1
EOF
  printf '%s\tcalm' "${_op_epoch:-}"
}

# _orphan_pr_row <line>  ("<epoch>\t<pr>\t<title>\t<branch>") → one themed console row (advisory, never
#   red). Fail-soft: a row missing its PR number renders nothing (drops out of the section).
_orphan_pr_row() {
  local _op_epoch _op_pr _op_title _op_branch
  IFS=$'\t' read -r _op_epoch _op_pr _op_title _op_branch <<EOF
$1
EOF
  [ -n "${_op_pr:-}" ] || return 0
  printf '    %s🪹%s %s#%s%s %s %s%s · no worktree here — adopt or handle manually%s' \
    "$C_YELLOW" "$C_RESET" "$C_BOLD" "$_op_pr" "$C_RESET" "${_op_title:-}" \
    "$C_DIM" "${_op_branch:-}" "$C_RESET"
}

# _orphan_prs_scan <prs-json> <claimed-pr-numbers-newline-list>
#   REWRITE the orphan-PR ledger from live state: one row per OPEN PR in $1 whose number is not in the
#   claimed set $2 (the PRs the discovered worktrees own this tick). No-op — and no ledger write —
#   when ORPHAN_PR_ROWS is off OR the open-PR lookup FAILED this tick (a failed fetch is not positive
#   evidence of "no PR"; HERD-224), so the previous tick's rows are never fabricated away by a blip.
#   Rewritten whole (never appended) so the ledger cannot grow unbounded and self-corrects each tick.
#   Zero network: it reads the tick's already-fetched roster. Fail-soft: malformed JSON → empty ledger.
_orphan_prs_scan() {
  _orphan_pr_rows_enabled || return 0
  [ "${PRS_LOOKUP_OK:-1}" = "1" ] || return 0
  local _op_json="${1:-[]}" _op_claimed="${2:-}" _op_epoch _op_out
  _op_epoch="$(_console_now_epoch)"
  _op_out="$(PRS_JSON="$_op_json" CLAIMED="$_op_claimed" EPOCH="$_op_epoch" python3 -c '
import os, sys, json
try:
    prs = json.loads(os.environ.get("PRS_JSON") or "[]")
    if not isinstance(prs, list): raise ValueError
except Exception:
    sys.exit(0)   # malformed roster → empty ledger (fail-soft), never a crash
claimed = set(n for n in (os.environ.get("CLAIMED") or "").split() if n)
epoch = os.environ.get("EPOCH", "")
def flat(s):
    return " ".join(str(s or "").split())
for pr in prs:
    if not isinstance(pr, dict):
        continue
    num = pr.get("number")
    if num is None:
        continue
    if str(num) in claimed:
        continue
    title = flat(pr.get("title"))
    if len(title) > 80:
        title = title[:79].rstrip() + "…"
    branch = flat(pr.get("headRefName"))
    # TAB-separated, matching _orphan_pr_classify/_orphan_pr_row; whitespace already flattened so a
    # title/branch can never inject a TAB or newline into the ledger shape.
    print("%s\t%s\t%s\t%s" % (epoch, num, title, branch))
' 2>/dev/null)" || _op_out=""
  # Rewrite the ledger atomically-ish: a truncate to empty when there are no orphans clears the section.
  if [ -n "$_op_out" ]; then
    printf '%s\n' "$_op_out" > "$ORPHAN_PR_LEDGER" 2>/dev/null || true
  else
    : > "$ORPHAN_PR_LEDGER" 2>/dev/null || true
  fi
  return 0
}

# build_orphan_prs — the "orphan PRs" advisory section: the orphan-PR ledger tail, newest-first, one
# row each, bounded to ORPHAN_PR_ROWS_LIMIT via the shared helper. Empty (ORPHAN_PR_SECTION_ROWS="")
# when the feature is off OR no PR is orphaned, so render() omits the section and the console is
# byte-identical when unused. A pure renderer — the discovery (and its only write) is _orphan_prs_scan.
build_orphan_prs() {
  ORPHAN_PR_SECTION_ROWS=""
  _orphan_pr_rows_enabled || return 0
  [ -s "$ORPHAN_PR_LEDGER" ] || return 0
  local rows
  rows="$(herd_console_section "$ORPHAN_PR_LEDGER" "$ORPHAN_PR_ROWS_LIMIT" \
    _orphan_pr_classify _orphan_pr_row)"
  [ -n "$rows" ] && ORPHAN_PR_SECTION_ROWS="${rows}"$'\n'
  return 0
}

# ── Adopt remote PRs (HERD-369) ──────────────────────────────────────────────────────────────────
# Builds ON TOP of the HERD-330 orphan diff above (the same open-PR-vs-pool computation, zero extra
# `gh pr list`): for every OPEN, NON-DRAFT PR that diff finds no discovered worktree owns, `git fetch`
# + `git worktree add` its branch into WORKTREES_DIR so the worktree-gated watcher discovers and gates
# it on the VERY NEXT tick — closing the gap that left #462/#463/#478 sitting ungated 16-18h until a
# human hand-ran `git worktree add`. Both legs self-gate independently (ADOPT_REMOTE_PRS vs
# ORPHAN_PR_ROWS) so either works without the other.

# _adopt_remote_prs_enabled — true iff ADOPT_REMOTE_PRS opts in. Default OFF (mirrors
# _orphan_pr_rows_enabled); any unrecognized value reads as off (fail toward the byte-identical pool).
_adopt_remote_prs_enabled() {
  case "$(printf '%s' "${ADOPT_REMOTE_PRS:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _adopt_pr_recorded <pr> <sha> — true iff this (pr,sha) was ALREADY SUCCESSFULLY adopted, so a
# re-tick never re-attempts `git fetch`/`worktree add` on a branch already in the pool — including
# BEFORE the next worktree-rediscovery pass has had a chance to fold it into the claimed set. A prior
# FAILURE never satisfies this (see the ledger-split rationale above) — a failed (pr,sha) keeps retrying.
_adopt_pr_recorded() {
  [ -s "$ADOPT_PR_LEDGER" ] || return 1
  awk -F'\t' -v p="$1" -v s="$2" '$1==p && $2==s{f=1} END{exit !f}' "$ADOPT_PR_LEDGER" 2>/dev/null
}

# _adopt_pr_mark_adopted <pr> <sha> — append-only; the once-guard for a SUCCESSFUL adopt.
_adopt_pr_mark_adopted() {
  printf '%s\t%s\tadopted\n' "$1" "$2" >> "$ADOPT_PR_LEDGER" 2>/dev/null || true
}

# _adopt_failed_journaled <pr> <sha> — true iff a FAILURE for this exact (pr,sha) was already
# journaled, so the journal event is emitted at most once per commit even while the underlying attempt
# keeps retrying every scan.
_adopt_failed_journaled() {
  [ -s "$ADOPT_FAILED_SEEN_LEDGER" ] || return 1
  awk -F'\t' -v p="$1" -v s="$2" '$1==p && $2==s{f=1} END{exit !f}' "$ADOPT_FAILED_SEEN_LEDGER" 2>/dev/null
}

# _adopt_journal_failed <pr> <sha> <branch> <reason> — journal `adopt_failed` ONCE per (pr,sha),
# deduping repeat scans of a still-broken branch; a new sha (a fresh push) always re-journals.
_adopt_journal_failed() {
  local _ajf_pr="$1" _ajf_sha="$2" _ajf_branch="$3" _ajf_reason="$4"
  _adopt_failed_journaled "$_ajf_pr" "$_ajf_sha" && return 0
  journal_append adopt_failed pr "$_ajf_pr" sha "$_ajf_sha" branch "$_ajf_branch" reason "$_ajf_reason"
  printf '%s\t%s\n' "$_ajf_pr" "$_ajf_sha" >> "$ADOPT_FAILED_SEEN_LEDGER" 2>/dev/null || true
}

# _adopt_branch_checked_out <branch> <wt-porcelain> — true when ANY worktree in this tick's already-
# fetched `git worktree list --porcelain` text ($WT) has this branch checked out — the main checkout,
# a builder worktree, or a stray manual worktree a human already added. Reads the raw porcelain text
# verbatim (not the $TREES-scoped $FEATS subset), matching the spec's "anywhere", not just the pool.
_adopt_branch_checked_out() {
  local _abc_branch="$1" _abc_wt="$2"
  grep -qxF "branch refs/heads/$_abc_branch" <<EOF
$_abc_wt
EOF
}

# _adopt_branch_worktree_dir <branch> <wt-porcelain> — echo the worktree PATH currently checked out
# for <branch> in $2 (the same porcelain text _adopt_branch_checked_out reads), or nothing when the
# branch is not checked out anywhere. Backs the self-heal below: it needs the ACTUAL path, not just
# the yes/no _adopt_branch_checked_out already answers.
_adopt_branch_worktree_dir() {
  local _abwd_branch="$1" _abwd_wt="$2"
  printf '%s\n' "$_abwd_wt" | awk -v want="branch refs/heads/$_abwd_branch" '
    /^worktree /{dir=substr($0,10)}
    $0==want{print dir; exit}
  '
}

# _adopt_selfheal_failed_journaled <branch> <dir> — true iff an `adopt_selfheal_failed` for this exact
# (branch,dir) was already journaled, so a still-broken move does not spam the journal every scan.
_adopt_selfheal_failed_journaled() {
  [ -s "$ADOPT_SELFHEAL_SEEN_LEDGER" ] || return 1
  awk -F'\t' -v b="$1" -v d="$2" '$1==b && $2==d{f=1} END{exit !f}' "$ADOPT_SELFHEAL_SEEN_LEDGER" 2>/dev/null
}

# _adopt_self_heal_mismatch <branch> <expected-dir> <wt-porcelain> — HERD-377 leftover: an adopt from
# BEFORE the slug-parity fix may have checked <branch> out at the WRONG path (the old unconditional
# `tr '/' '-'` slug, e.g. TREES/feat-python-draft-pr-hold, instead of herd_branch_slug's
# TREES/python-draft-pr-hold). Detect that mismatch from the SAME worktree porcelain text the
# checked-out-anywhere guard already has, and `git worktree move` it onto the CORRECT path so
# discovery (branch_to_slug/_worktree_for_slug) finds it on the very next tick — a re-adopt at the
# right path with the stale dir swept. Fail-soft throughout: never returns non-zero, a move failure is
# journaled ONCE per (branch,dir) (_adopt_selfheal_failed_journaled) and simply retried next scan, and
# an occupied target is left untouched for a human rather than clobbered.
#
# SAFETY: only ever moves a dir that is ALREADY a direct child of the pool ($TREES/<something>) — an
# adopt leftover is, by construction, always exactly that. This is NOT the same predicate as "checked
# out anywhere": a branch checked out at the MAIN checkout (or any human-managed worktree outside the
# pool) is never mistaken for a stale adopt and never moved.
_adopt_self_heal_mismatch() {
  local _ash_branch="$1" _ash_expected="$2" _ash_wt="$3"
  local _ash_actual; _ash_actual="$(_adopt_branch_worktree_dir "$_ash_branch" "$_ash_wt")"
  [ -n "$_ash_actual" ] || return 0                    # not checked out anywhere — nothing to heal
  [ "$_ash_actual" != "$_ash_expected" ] || return 0    # already at the right path
  [ "$(dirname "$_ash_actual")" = "$TREES" ] || return 0  # not a pool worktree (e.g. the main checkout) — never touch it
  [ -e "$_ash_expected" ] && return 0                   # target occupied — never clobber, leave for a human
  if git -C "$MAIN" worktree move "$_ash_actual" "$_ash_expected" >/dev/null 2>&1; then
    journal_append adopt_selfheal branch "$_ash_branch" from "$_ash_actual" to "$_ash_expected"
    return 0
  fi
  _adopt_selfheal_failed_journaled "$_ash_branch" "$_ash_actual" && return 0
  journal_append adopt_selfheal_failed branch "$_ash_branch" from "$_ash_actual" to "$_ash_expected"
  printf '%s\t%s\n' "$_ash_branch" "$_ash_actual" >> "$ADOPT_SELFHEAL_SEEN_LEDGER" 2>/dev/null || true
  return 0
}

# _adopt_remote_pr <pr> <branch> <sha> — the mutating half: fetch the branch, then `git worktree add`
# it into WORKTREES_DIR/<slug>, where <slug> is resolved by herd_branch_slug — the SAME slugifier
# candidate discovery uses (branch_to_slug/_worktree_for_slug, pysrc/herd/live_runtime.py), so the
# worktree this leg creates is the EXACT path discovery will look for on the very next tick (HERD-377:
# a second, independently-invented slugifier here — the old unconditional `tr '/' '-'` — put PR #484 at
# TREES/feat-python-draft-pr-hold while discovery resolved TREES/python-draft-pr-hold, dropping it from
# candidates for an hour despite pr_adopted having already claimed success). FAIL-SOFT throughout: any
# step's failure journals `adopt_failed` (deduped per (pr,sha) via _adopt_journal_failed) and returns
# WITHOUT once-guarding — a transient failure (network blip, momentary ref lock) is retried on the next
# scan; only a SUCCESSFUL adopt is terminal (_adopt_pr_mark_adopted) and journals `pr_adopted` once.
# Returns 0 on a successful adopt, 1 on any failure — the caller (_adopt_remote_prs_scan) uses this to
# tally the scan's outcome for the throttled `adopt_scan` summary event (HERD-388); it does not change
# the fail-soft contract above (a nonzero return is never treated as fatal by the caller).
_adopt_remote_pr() {
  local _arp_pr="$1" _arp_branch="$2" _arp_sha="$3"
  local _arp_slug _arp_dir
  _arp_slug="$(herd_branch_slug "$_arp_branch")"
  _arp_dir="$TREES/$_arp_slug"
  if [ -e "$_arp_dir" ]; then
    _adopt_journal_failed "$_arp_pr" "$_arp_sha" "$_arp_branch" "worktree path already exists: $_arp_dir"
    return 1
  fi
  if ! git -C "$MAIN" fetch -q origin "$_arp_branch" >/dev/null 2>&1; then
    _adopt_journal_failed "$_arp_pr" "$_arp_sha" "$_arp_branch" "git fetch failed"
    return 1
  fi
  if ! git -C "$MAIN" worktree add "$_arp_dir" "$_arp_branch" >/dev/null 2>&1; then
    _adopt_journal_failed "$_arp_pr" "$_arp_sha" "$_arp_branch" "git worktree add failed"
    return 1
  fi
  journal_append pr_adopted pr "$_arp_pr" sha "$_arp_sha" branch "$_arp_branch" slug "$_arp_slug" dir "$_arp_dir"
  _adopt_pr_mark_adopted "$_arp_pr" "$_arp_sha"
  return 0
}

# _adopt_remote_prs_scan <prs-json> <claimed-pr-numbers-newline-list> <wt-porcelain>
#   For each OPEN PR in $1 not in the claimed set $2 (the SAME diff _orphan_prs_scan computes — no
#   second gh call): skip a draft, skip a branch already checked out anywhere ($3), skip a (pr,sha)
#   already recorded, else adopt. Self-gates on ADOPT_REMOTE_PRS and PRS_LOOKUP_OK exactly like the
#   orphan scan (a failed open-PR fetch is not positive evidence of "no PR" — never fabricated into a
#   spurious adopt attempt). Zero network beyond the per-PR fetch+worktree-add themselves.
#
# OBSERVABILITY (HERD-388): GROUNDED INCIDENT — three eligible, non-draft, worktree-less PRs sat for
# 30+ minutes under ADOPT_REMOTE_PRS=on with NO pr_adopted, NO adopt_failed, and NO orphan rows: total
# silence, indistinguishable from "nothing to adopt". The root cause is that BOTH this scan and the
# orphan-PR scan self-gate on PRS_LOOKUP_OK — so a `gh pr list` failure that is NOT a hard timeout (the
# only case _gh_timeout itself journals, via `gh_timeout`) degrades PRS_LOOKUP_OK to 0 with no journal
# record anywhere. From the operator's console/journal there is no way to tell "the scan ran and found
# nothing" apart from "the scan has not been able to run for N ticks". Every invocation of this
# function (already throttled to the ~60s scan cadence by its caller) now emits exactly ONE `adopt_scan`
# summary event — result ∈ {empty, adopted, failed} + count — so a silently-dead leg is visible in the
# journal the very next scan, not just in retrospect.
_adopt_remote_prs_scan() {
  _adopt_remote_prs_enabled || return 0
  if [ "${PRS_LOOKUP_OK:-1}" != "1" ]; then
    journal_append adopt_scan result failed count 0 reason lookup_failed
    return 0
  fi
  local _ars_json="${1:-[]}" _ars_claimed="${2:-}" _ars_wt="${3:-}" _ars_out
  _ars_out="$(PRS_JSON="$_ars_json" CLAIMED="$_ars_claimed" python3 -c '
import os, sys, json
try:
    prs = json.loads(os.environ.get("PRS_JSON") or "[]")
    if not isinstance(prs, list): raise ValueError
except Exception:
    sys.exit(0)   # malformed roster → nothing to adopt this tick (fail-soft), never a crash
claimed = set(n for n in (os.environ.get("CLAIMED") or "").split() if n)
for pr in prs:
    if not isinstance(pr, dict):
        continue
    num = pr.get("number")
    if num is None:
        continue
    if str(num) in claimed:
        continue
    if pr.get("isDraft"):
        continue   # never adopt a draft
    branch = pr.get("headRefName") or ""
    sha = pr.get("headRefOid") or ""
    if not branch or not sha:
        continue
    print("%s\t%s\t%s" % (num, branch, sha))
' 2>/dev/null)" || _ars_out=""
  if [ -z "$_ars_out" ]; then
    journal_append adopt_scan result empty count 0
    return 0
  fi
  local _ars_pr _ars_branch _ars_sha _ars_attempted=0 _ars_adopted=0 _ars_failed=0
  while IFS=$'\t' read -r _ars_pr _ars_branch _ars_sha; do
    [ -n "${_ars_pr:-}" ] || continue
    # A prior (pre-fix) adopt may have this branch checked out at the WRONG (mismatched-slug) path —
    # heal it onto the correct one BEFORE the recorded/checked-out-anywhere skips below, since a
    # once-guarded successful adopt is exactly the case that needs healing (HERD-377).
    _adopt_self_heal_mismatch "$_ars_branch" "$TREES/$(herd_branch_slug "$_ars_branch")" "$_ars_wt"
    _adopt_pr_recorded "$_ars_pr" "$_ars_sha" && continue
    _adopt_branch_checked_out "$_ars_branch" "$_ars_wt" && continue
    _ars_attempted=$((_ars_attempted + 1))
    if _adopt_remote_pr "$_ars_pr" "$_ars_branch" "$_ars_sha"; then
      _ars_adopted=$((_ars_adopted + 1))
    else
      _ars_failed=$((_ars_failed + 1))
    fi
  done <<EOF
$_ars_out
EOF
  if [ "$_ars_attempted" -eq 0 ]; then
    journal_append adopt_scan result empty count 0
  elif [ "$_ars_failed" -gt 0 ]; then
    journal_append adopt_scan result failed count "$_ars_failed" adopted "$_ars_adopted"
  else
    journal_append adopt_scan result adopted count "$_ars_adopted"
  fi
  return 0
}

# render — paint the whole rollup card, but ONLY when the computed frame changed.
render() {
  frame="${HDR_LINE}"$'\n'"${RULE}"$'\n\n'
  # ENGINE PAUSED banner (HERD-347) — the operator emergency-off switch, pinned ABOVE even the
  # engine-down alarm: a deliberate operator pause is the single most important fact on the console.
  # Set by _engine_tick_watchdog while ENGINE_PAUSE=on; empty (byte-identical console) whenever the
  # lever is off/unset — the ship default — so this adds NO always-on row.
  if [ -n "${ENGINE_PAUSE_ROW:-}" ]; then
    frame="${frame}  ${C_YELLOW}engine${C_RESET}"$'\n'"${ENGINE_PAUSE_ROW}"$'\n'
  fi
  # ENGINE DOWN alarm (HERD-306) — the LOUDEST row, pinned above even the default-branch alarm. Set by
  # _engine_tick_watchdog when the SOLE (Python) engine core has faulted past its tolerance: no gates or
  # merges are running until a human intervenes. Empty (byte-identical console) whenever the engine ticks.
  if [ -n "${ENGINE_DOWN_ROW:-}" ]; then
    frame="${frame}  ${C_RED}engine${C_RESET}"$'\n'"${ENGINE_DOWN_ROW}"$'\n'
  fi
  # Post-merge main-health ALARM (HERD-129) — pinned at the TOP so a red default branch is the first
  # thing seen. Empty unless main is currently red, so byte-identical when the feature is unused.
  # MAIN-freshness (HERD-233) shares that section: a diverged/held checkout, and the restart note
  # after a pull carried new engine code. Both empty on the happy path.
  if [ -n "${MAIN_HEALTH:-}" ] || [ -n "${MAIN_FRESHNESS:-}" ] || [ -n "${CHECKOUT_CLEAN:-}" ]; then
    frame="${frame}  ${C_RED}default branch${C_RESET}"$'\n'"${MAIN_HEALTH:-}${MAIN_FRESHNESS:-}${CHECKOUT_CLEAN:-}"$'\n'
  fi
  # Merge CELEBRATION (HERD-147 flair) — below any MAIN RED alarm (a red state always leads), above the
  # rollup. Empty unless a merge landed since the last tick AND flair is on, so byte-identical otherwise.
  if [ -n "${CELEBRATE:-}" ]; then
    frame="${frame}${CELEBRATE}"$'\n'
  fi
  frame="${frame}  ${C_DIM}recently landed${C_RESET}"$'\n'"${LANDED}"$'\n'
  if [ -n "${BLOCKED:-}" ]; then
    frame="${frame}  ${C_DIM}blocked on${C_RESET}"$'\n'"${BLOCKED}"$'\n'
  fi
  if [ -n "${TRACKER_DRIFT:-}" ]; then
    frame="${frame}  ${C_DIM}tracker healed${C_RESET}"$'\n'"${TRACKER_DRIFT}"$'\n'
  fi
  if [ -n "${SPAWN_HOLDS:-}" ]; then
    frame="${frame}  ${C_DIM}spawn holds${C_RESET}"$'\n'"${SPAWN_HOLDS}"$'\n'
  fi
  # ENGINE OUTDATED note (HERD-179) — one quiet line under ENGINE_AUTOUPDATE=check|auto when the local
  # engine is below the project's ENGINE_MIN. Empty (byte-identical console) otherwise.
  if [ -n "${HERD_ENGINE_NOTE:-}" ]; then
    frame="${frame}  ${C_DIM}engine${C_RESET}"$'\n'"${HERD_ENGINE_NOTE}"$'\n'
  fi
  # DUAL-ENGINE row (HERD-308) — a loud HALT (stale seat) or coexistence warning (leading seat) when two
  # engine levels write this pool. Empty (byte-identical console) while ENGINE_SEAT_RECONCILE is off or
  # only one engine writes.
  if [ -n "${HERD_ENGINE_SEAT_NOTE:-}" ]; then
    frame="${frame}  ${C_DIM}engine seats${C_RESET}"$'\n'"${HERD_ENGINE_SEAT_NOTE}"$'\n'
  fi
  # CONTROL-ROOM SWEEP advisory (HERD-191) — one quiet line when debris has accumulated. Empty when
  # the control room is clean or SWEEP_AUTO=off, so the console is byte-identical when unused.
  if [ -n "${SWEEP_NOTE:-}" ]; then
    frame="${frame}  ${C_DIM}housekeeping${C_RESET}"$'\n'"${SWEEP_NOTE}"$'\n'
  fi
  # HEALTH HEADROOM advisory (HERD-281) — fires when the observed suite duration is within
  # HEALTH_TIMEOUT_HEADROOM of HEALTH_INFLIGHT_TIMEOUT. Empty when HEALTH_TIMEOUT_HEADROOM=0 (default),
  # so the console is byte-identical to before when the margin is not crossed or the lever is dormant.
  if [ -n "${HEALTH_HEADROOM_NOTE:-}" ]; then
    frame="${frame}  ${C_DIM}health headroom${C_RESET}"$'\n'"${HEALTH_HEADROOM_NOTE}"$'\n'
  fi
  # OPERATOR INBOX (HERD-184) — cross-seat comments needing the coordinator, just above the in-flight
  # rows (needs-you-adjacent). Empty unless OPERATOR_INBOX is on AND a comment has been surfaced, so
  # byte-identical when the feature is unused.
  if [ -n "${OPERATOR_INBOX_ROWS:-}" ]; then
    frame="${frame}  ${C_DIM}operator inbox${C_RESET}"$'\n'"${OPERATOR_INBOX_ROWS}"$'\n'
  fi
  # BUILDER NOTES (HERD-202) — mid-build findings filed via `herd note`, needs-you-adjacent. Empty
  # unless a builder has filed a note since the cursor advanced, so byte-identical when unused.
  if [ -n "${BUILDER_NOTES_ROWS:-}" ]; then
    frame="${frame}  ${C_DIM}builder notes${C_RESET}"$'\n'"${BUILDER_NOTES_ROWS}"$'\n'
  fi
  # ORPHAN PRs (HERD-330) — open PRs no live builder worktree owns, needs-you-adjacent. Empty unless
  # ORPHAN_PR_ROWS is on AND at least one open PR is orphaned this tick, so byte-identical when unused.
  if [ -n "${ORPHAN_PR_SECTION_ROWS:-}" ]; then
    frame="${frame}  ${C_DIM}orphan PRs${C_RESET}"$'\n'"${ORPHAN_PR_SECTION_ROWS}"$'\n'
  fi
  # RETIRING (HERD-164) — slugs whose worktree is already gone but whose tab/agent/ledger has not
  # converged yet (the ones that can't appear among the worktree-derived in-flight rows). Empty when
  # every terminal slug has converged, which is the steady state, so the console is byte-identical.
  if [ -n "${RETIRING:-}" ]; then
    frame="${frame}  ${C_DIM}retiring${C_RESET}"$'\n'"${RETIRING}"$'\n'
  fi
  # PASTURE HEADER (HERD-147 flair) — one glyph-per-builder line just above the in-flight rows it
  # summarizes. Empty when flair is off or the herd is idle, so byte-identical when the feature is unused.
  if [ -n "${PASTURE:-}" ]; then
    frame="${frame}${PASTURE}"
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

# already_merged — moved to work-units/git-pr.sh (HERD-398, Phase 3 work-unit extraction).

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

# resolver_attempted <branch> — legacy branch-keyed guard (kept for back-compat; the sha-keyed
# helpers below drive the HERD-55 respawn logic). True if ANY dispatch exists for this branch.
resolver_attempted() {
  [ -s "$RESOLVE_STATE" ] || return 1
  awk -v b="$1" -v s="$2" '$4==b && $5==s{f=1} END{exit !f}' "$RESOLVE_STATE" 2>/dev/null
}

# resolver_ever_attempted <branch> — true iff ANY resolver was spawned for this branch at ANY sha.
# Distinguishes a FIRST-ever conflict (fresh spawn) from a cross-sha RE-spawn on a new commit so the
# console can read 'resolving (retry · new commit)' vs the initial 'resolving conflict…'.
resolver_ever_attempted() {
  [ -s "$RESOLVE_STATE" ] || return 1
  awk -v b="$1" '$4==b{f=1} END{exit !f}' "$RESOLVE_STATE" 2>/dev/null
}

# resolver_dispatch_count <pr#> — total resolver DISPATCHES for this PR across all shas. This is the
# per-PR respawn budget (capped at REFIX_MAX_ROUNDS); `escalated` markers are not dispatches.
resolver_dispatch_count() {
  [ -s "$RESOLVE_STATE" ] || { printf '0'; return 0; }
  awk -v p="$1" '$2==p && $6!="escalated"{n++} END{print n+0}' "$RESOLVE_STATE" 2>/dev/null || printf '0'
}

# resolver_dispatched_sha <pr#> <sha> — true if a resolver was already DISPATCHED for this exact pr+sha.
resolver_dispatched_sha() {
  [ -s "$RESOLVE_STATE" ] || return 1
  awk -v p="$1" -v s="$2" '$2==p && $5==s && $6!="escalated"{f=1} END{exit !f}' "$RESOLVE_STATE" 2>/dev/null
}

# resolver_escalated_sha <pr#> <sha> — true if the resolver ESCALATED this exact pr+sha. TERMINAL:
# an ambiguous conflict is never re-dispatched until a NEW commit changes the sha.
resolver_escalated_sha() {
  [ -s "$RESOLVE_STATE" ] || return 1
  awk -v p="$1" -v s="$2" '$2==p && $5==s && $6=="escalated"{f=1} END{exit !f}' "$RESOLVE_STATE" 2>/dev/null
}

# resolver_last_dispatch_epoch <pr#> — epoch of the most-recent DISPATCH for this PR across ALL shas
# (empty if none). Used to give a just-spawned resolver a startup grace before it's declared dead —
# regardless of which sha it was dispatched for (so a new commit can't reap a still-registering resolver).
resolver_last_dispatch_epoch() {
  [ -s "$RESOLVE_STATE" ] || return 0
  awk -v p="$1" '$2==p && $6!="escalated"{e=$1} END{if(e)print e}' "$RESOLVE_STATE" 2>/dev/null
}

# resolver_last_dispatch_epoch_slug <slug> — epoch of the most-recent DISPATCH for this SLUG across
# every PR + sha (empty if none). The SLUG-keyed twin of the helper above, for the callers that hold a
# resolve·<slug> tab but no PR number (the stale-resolve-tab reaper): a just-spawned resolver whose
# agent has not registered yet must be inside the startup grace THERE too, or the reaper closes the
# tab out from under it (HERD-206).
resolver_last_dispatch_epoch_slug() {
  [ -s "$RESOLVE_STATE" ] || return 0
  awk -v s="$1" '$3==s && $6!="escalated"{e=$1} END{if(e)print e}' "$RESOLVE_STATE" 2>/dev/null
}

# resolver_last_sha <pr#> — the most-recently DISPATCHED sha for this PR (empty if none / legacy row).
resolver_last_sha() {
  [ -s "$RESOLVE_STATE" ] || return 0
  awk -v p="$1" '$2==p && $6!="escalated" && $5!=""{s=$5} END{if(s)print s}' "$RESOLVE_STATE" 2>/dev/null
}

# record_resolve_attempt <pr#> <slug> <branch> <sha> — append one DISPATCH record (BEFORE the spawn).
# An empty sha is normalized to "-" so the 6 whitespace-separated columns never collapse (awk-safe).
record_resolve_attempt() {
  printf '%s %s %s %s %s dispatched\n' "$(date +%s)" "$1" "$2" "$3" "${4:--}" >> "$RESOLVE_STATE"
}

# record_resolve_escalated <pr#> <slug> <branch> <sha> — mark a resolver ESCALATE terminal for this sha.
record_resolve_escalated() {
  printf '%s %s %s %s %s escalated\n' "$(date +%s)" "$1" "$2" "$3" "${4:--}" >> "$RESOLVE_STATE"
  journal_append resolver_escalated pr "$1" slug "$2" sha "${4:--}"
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

# ── DELTA-SCOPED REVIEW carry-forward (HERD-204) ─────────────────────────────────────────────────
# When a builder pushes a PURE INTEGRATION commit — it merged DEFAULT_BRANCH into the branch with NO
# authored change beyond the merge — re-running the full adversarial review for that new sha burns
# tokens/time for zero correctness gain: the newly-merged main commits are already-reviewed main, and
# the merge itself introduced no new authored content. With DELTA_REVIEW=on, the review gate PROVES
# the delta between the new head sha and this PR's LAST review-PASSED sha is integration-only and, if
# so, CARRIES FORWARD the prior PASS onto the new sha instead of dispatching a reviewer.
#
# The proof is CONSERVATIVE + FAIL-CLOSED — every one of these must hold, else a normal full review:
#   1. DELTA_REVIEW=on (opt-in; default/unknown → off → byte-inert).
#   2. the PR has a recorded PASS for an OLDER sha (the carry source).
#   3. the new sha is a 2-parent MERGE commit.
#   4. one parent IS the last-passed sha (the branch side — already reviewed & PASSED).
#   5. the OTHER parent is already contained in DEFAULT_BRANCH (already-reviewed main).
#   6. the new commit's tree EQUALS a clean 3-way auto-merge of those two parents — i.e. the merge
#      carries ZERO manual edits (no authored conflict resolution). A conflicted or hand-edited merge
#      fails this and gets a full review.
# Any authored change beyond the merge diverges the tree (6) or breaks the parent identity (4), and a
# missing sha / worktree / main ref simply returns "not provable" → full review. So a real code change
# NEVER carries forward.

# _delta_review_enabled — true iff DELTA_REVIEW opts in (on). Default/unknown → off (fail safe).
_delta_review_enabled() {
  case "${DELTA_REVIEW:-off}" in
    on|On|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# _review_last_passed_sha <pr#> — echo the most-recently recorded PASS sha for this PR (any PASS
# provenance: a real reviewer PASS, a low-risk skip, or an earlier carry-forward — each traces back to
# a real cleared commit). Empty + rc1 when the PR has no recorded PASS yet.
_review_last_passed_sha() {
  [ -s "$REVIEW_STATE" ] || return 1
  awk -v p="$1" '$2==p && $4=="PASS"{s=$3} END{if(s){print s} else exit 1}' "$REVIEW_STATE" 2>/dev/null
}

# _delta_main_ref <dir> — echo the first resolvable ref naming DEFAULT_BRANCH in <dir> (the bare name,
# then origin/<name>, then refs/remotes/origin/<name>), used for the "parent already in main" ancestry
# check. rc1 (no output) when none resolves → the caller treats that as "not provable" → full review.
_delta_main_ref() {
  local dir="$1" b="${DEFAULT_BRANCH:-main}" c
  b="${b#origin/}"
  for c in "$DEFAULT_BRANCH" "$b" "origin/$b" "refs/remotes/origin/$b"; do
    [ -n "$c" ] || continue
    if git -C "$dir" rev-parse --verify --quiet "${c}^{commit}" >/dev/null 2>&1; then
      printf '%s' "$c"; return 0
    fi
  done
  return 1
}

# _delta_is_integration_only <dir> <old-sha> <new-sha> — return 0 iff the delta from <old-sha> (the
# last-passed commit) to <new-sha> (the new head) is PROVABLY a pure merge of DEFAULT_BRANCH with no
# authored content. Fail-closed: any missing precondition, unresolved ref, or content divergence → 1.
_delta_is_integration_only() {
  local dir="$1" old="$2" new="$3"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ] || return 1
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 1
  # Both commits must be present in this worktree's object store.
  local oldfull newfull
  oldfull="$(git -C "$dir" rev-parse --verify --quiet "${old}^{commit}" 2>/dev/null)" || return 1
  newfull="$(git -C "$dir" rev-parse --verify --quiet "${new}^{commit}" 2>/dev/null)" || return 1
  # The new head must be a MERGE with EXACTLY two parents (a simple integration merge).
  local pline p1 p2
  pline="$(git -C "$dir" rev-list --parents -n1 "$newfull" 2>/dev/null)" || return 1
  # shellcheck disable=SC2086
  set -- $pline
  shift                       # drop the commit's own oid; the rest are its parents
  [ "$#" -eq 2 ] || return 1
  p1="$1"; p2="$2"
  # One parent must BE the last-passed sha (the already-reviewed branch side); the other is the
  # main-side parent. Neither → an authored commit sits between old and the merge → full review.
  local branchp mainp
  if   [ "$p1" = "$oldfull" ]; then branchp="$p1"; mainp="$p2"
  elif [ "$p2" = "$oldfull" ]; then branchp="$p2"; mainp="$p1"
  else return 1
  fi
  # The main-side parent must already be contained in DEFAULT_BRANCH (already-reviewed main).
  local mainref
  mainref="$(_delta_main_ref "$dir")" || return 1
  git -C "$dir" merge-base --is-ancestor "$mainp" "$mainref" 2>/dev/null || return 1
  # CONTENT-TRIVIAL merge: the new commit's tree must equal a clean 3-way auto-merge of the two
  # parents. A non-zero merge-tree (conflict) or any manual edit diverges the tree → full review.
  local auto rc newtree
  auto="$(git -C "$dir" merge-tree --write-tree "$branchp" "$mainp" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  auto="$(printf '%s\n' "$auto" | head -1)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
  [ -n "$auto" ] || return 1
  newtree="$(git -C "$dir" rev-parse --verify --quiet "${newfull}^{tree}" 2>/dev/null)" || return 1
  [ "$auto" = "$newtree" ] || return 1
  return 0
}

# _maybe_carry_forward_review <pr#> <slug> <sha> — if DELTA_REVIEW=on and the delta from this PR's
# last-passed sha to <sha> is provably integration-only, RECORD a carried-forward PASS for <sha> (with
# a distinct source=carried-forward provenance) + journal review_carried_forward, and return 0 so the
# caller skips the reviewer dispatch. Return 1 (carry nothing) in every other case → normal review.
_maybe_carry_forward_review() {
  _delta_review_enabled || return 1
  local pr="$1" slug="$2" sha="$3" old dir
  [ -n "$sha" ] || return 1
  old="$(_review_last_passed_sha "$pr")" || return 1
  [ -n "$old" ] && [ "$old" != "$sha" ] || return 1
  dir="$TREES/$slug"
  _delta_is_integration_only "$dir" "$old" "$sha" || return 1
  record_review "$pr" "$sha" "PASS" "carried-forward"
  journal_append review_carried_forward pr "$pr" sha "$sha" from_sha "$old" slug "$slug" \
    reason "integration-only delta (merge of ${DEFAULT_BRANCH:-main}) — prior review PASS carried forward"
  return 0
}

# record_review <pr#> <headSha> <verdict> [source] — append one review record (the instant a verdict
# is known). <source> is the verdict PROVENANCE (reviewer | gate_default | infra); defaults to
# "reviewer" when omitted. Only "reviewer" verdicts are ever cached as a sticky BLOCK AND are the
# only ones eligible to auto-refix a builder — a purely infrastructural death must never stick.
record_review() {
  printf '%s %s %s %s %s\n' "$(date +%s)" "$1" "$2" "$3" "${4:-reviewer}" >> "$REVIEW_STATE"
  journal_append verdict_recorded pr "$1" sha "$2" value "$3" source "${4:-reviewer}"
  # RESET-ON-PROGRESS (HERD-229): a PASS is the review rail's red resolving — whatever its provenance
  # (reviewer, carried-forward, skipped-low-risk), the review loop converged. Refund that rail's refix
  # budget here, at the one seam every PASS passes through. No-op unless the rail has rounds to zero.
  if [ "$3" = "PASS" ]; then refix_rail_reset "$1" review "$2"; fi
}

# ── Structured BLOCK verdicts (HERD-104) ────────────────────────────────────────────────────────
# herd-review.sh now emits a BLOCK as 'REVIEW: BLOCK — rule: <rule> | why: <why> | location: <loc>'.
# These helpers PARSE that line into its three fields and CACHE them sha-keyed so the auto-refix
# bounce can hand the builder an actionable finding. Both are FAIL-SOFT + BACKWARD-COMPATIBLE: a
# legacy/unstructured 'REVIEW: BLOCK — <freeform reason>' yields why=<freeform>, rule/location empty.

# _blk_trim <text> — echo <text> with leading/trailing whitespace stripped (no trailing newline).
_blk_trim() { printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

# _parse_block_fields <verdict-line> — parse a 'REVIEW: BLOCK — …' line, setting three globals:
#   _BLK_RULE _BLK_WHY _BLK_LOCATION  (any absent field is left empty).
# The payload is everything after the em-dash separator, split on ' | ' into segments; each segment
# is classified by an explicit 'rule:'/'why:'/'location:' key (case-insensitive). The FIRST unkeyed
# segment falls back to 'why' so a legacy freeform reason still populates why. Values are capped so a
# pathological line can never bloat a downstream prompt/journal.
_parse_block_fields() {
  local line="$1" payload seg
  _BLK_RULE=""; _BLK_WHY=""; _BLK_LOCATION=""
  case "$line" in
    *"—"*) payload="${line#*—}" ;;     # text after the em-dash separator
    *)     payload="${line#*REVIEW: BLOCK}" ;;  # no separator → tail after the tag (fail-soft)
  esac
  payload="$(_blk_trim "$payload")"
  while [ -n "$payload" ]; do
    if [ "$payload" = "${payload#* | }" ]; then seg="$payload"; payload=""      # last (or only) segment
    else seg="${payload%% | *}"; payload="${payload#* | }"; fi
    case "$seg" in
      [Rr]ule:*)     _BLK_RULE="$(_blk_trim "${seg#*:}")" ;;
      [Ww]hy:*)      _BLK_WHY="$(_blk_trim "${seg#*:}")" ;;
      [Ll]ocation:*) _BLK_LOCATION="$(_blk_trim "${seg#*:}")" ;;
      *) [ -z "$_BLK_WHY" ] && _BLK_WHY="$(_blk_trim "$seg")" ;;  # legacy freeform → why
    esac
  done
  # Cap each field (mirrors the 200-char cap used elsewhere) so one bad line can't bloat a prompt.
  _BLK_RULE="${_BLK_RULE:0:200}"; _BLK_WHY="${_BLK_WHY:0:200}"; _BLK_LOCATION="${_BLK_LOCATION:0:200}"
}

# _persist_block_fields <pr#> <sha> <verdict-line> — parse the BLOCK line and cache its three fields
# (rule / why / location, one per line, fixed order) for this exact pr+sha. Best-effort: a write
# hiccup just means the bounce falls back to the legacy "read the PR" prompt.
_persist_block_fields() {
  local pr="$1" sha="$2"
  _parse_block_fields "$3"
  { printf '%s\n%s\n%s\n' "$_BLK_RULE" "$_BLK_WHY" "$_BLK_LOCATION"; } \
    > "$(_review_block_file "$pr" "$sha")" 2>/dev/null || true
}

# ── Advisory (non-blocking) notes on a PASS (HERD-105) ────────────────────────────────────────────
# The correctness-only gate BLOCKs only on a correctness finding; style/hardening/nitpick findings
# ride a PASS verdict as ' | '-separated 'advisory:' notes after the em-dash:
#   REVIEW: PASS — advisory: <note> | advisory: <note>
# This helper surfaces each such note to the JOURNAL (the reviewer already posted them on the PR
# comment) so an advisory finding is recorded but NEVER gates the merge. FAIL-SOFT + BYTE-IDENTICAL
# when unused: a bare 'REVIEW: PASS' has no em-dash tail, so this returns immediately with zero
# journal writes — the pre-HERD-105 behaviour is unchanged.
#
# _record_advisory_notes <pr#> <sha> <pass-verdict-line> — journal one review_advisory event per
# advisory note carried on the PASS line. Best-effort; a malformed tail simply yields no notes.
_record_advisory_notes() {
  local pr="$1" sha="$2" line="$3" payload seg note
  case "$line" in
    *"—"*) payload="${line#*—}" ;;   # text after the em-dash tail
    *) return 0 ;;                    # bare 'REVIEW: PASS' → no advisory notes (byte-identical)
  esac
  payload="$(_blk_trim "$payload")"
  while [ -n "$payload" ]; do
    if [ "$payload" = "${payload#* | }" ]; then seg="$payload"; payload=""      # last (or only) segment
    else seg="${payload%% | *}"; payload="${payload#* | }"; fi
    case "$seg" in
      [Aa]dvisory:*)
        note="$(_blk_trim "${seg#*:}")"; note="${note:0:200}"
        [ -n "$note" ] && journal_append review_advisory pr "$pr" sha "$sha" note "$note" ;;
    esac
  done
  return 0
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
# PROCESS-GROUP ISOLATION (HERD-245): reviewers are launched in a NEW session (setsid) so a
# process-group kill of the watcher — herdr pane recycle on `herd reload`, sweep leg 5, or any
# `kill -- -<watcher_pgid>` — never SIGTERMs an actively-running review mid-flight. Observed live:
# reviews shared the watcher's pgid (plain `cmd &`), so pane restarts severed Opus reviews before a
# verdict (INFRA-FAIL + silent re-dispatch burn). The every-tick corpse sweep still TERMs a worker by
# its recorded marker pid once past REVIEW_INFLIGHT_TIMEOUT — only ACTIVE non-timeout reviews are
# protected. Mirrors HERD-217's "never kill live gate work" spirit for the stop/reload path.
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
# Structured-BLOCK detail cache (HERD-104): the reviewer's rule/why/location for THIS exact pr+sha,
# written when a BLOCK verdict is collected (see _persist_block_fields) so the auto-refix bounce can
# surface an ACTIONABLE finding instead of "read the PR". Sha-keyed like the markers above; a newer
# head sha discards it via _discard_stale_reviews. Three lines, fixed order: rule, why, location.
_review_block_file()    { printf '%s' "$TREES/.review-block-$1-$2"; }
# Evidence-triggered escalation arm marker, keyed per-PR (NOT per-sha): armed by _handle_block_verdict
# when a builder's refix rounds prove the cheap reviewer missed the issue, consumed once by the next
# review dispatch on that PR (see _maybe_arm_review_escalation / _review_gate_step).
_review_escalate_file() { printf '%s' "$TREES/.review-escalate-$1"; }
# Reviewer dispatch registry (HERD-113): one row per (pr,sha) recording the reviewer's POLLER PID and
# its PANE ID — "<pid> <pane_id>" (pane_id is "-" until the reviewer's agent pane is up, and stays "-"
# for the headless / no-pane path). Persisted BESIDE the review ledger so it survives a watcher/herdr
# restart. Two jobs: (a) on VERDICT CONSUMPTION the watcher retires the pane via the driver so a reviewer
# session can't sit idle for 30+ min after its verdict was read; (b) DISPATCH consults it to ADOPT/skip a
# still-live reviewer for the same (pr,sha) instead of spawning a duplicate (the 2026-07-08 double-Opus
# incident: a herdr death+reload re-dispatched PR #221's review while the prior reviewer was still live).
# Written cooperatively: _dispatch_review lays down "<pid> -" at spawn; herd-review.sh overwrites it with
# the real pane id once the agent pane exists. Sha-keyed like the markers above; discarded on a newer head.
_review_registry_file() { printf '%s' "$TREES/.review-registry-$1-$2"; }

# ── Restart-safe gate-dispatch substrate (HERD-185) ──────────────────────────────────────────────
# BOTH gate families (review + health) hold a concurrency slot with an on-disk INFLIGHT MARKER while a
# dispatched worker runs. A marker that outlives its worker — the worker died mid-run, or the whole
# watcher was killed/restarted mid-suite — used to hold that slot until a human deleted it (the
# 2026-07-08 corpse incidents: a dead reviewer's .review-inflight-278 held a review slot ~1h; a dead
# main-health run's .health-inflight-main-<sha> held the single health slot ~1h, six PRs queued behind
# two corpses). The fix is three RESTART-SAFE properties, SHARED by both families so there is ONE
# dispatch/collect/sweep pattern, not two divergent copies:
#   • the marker records pid + pid-START-TIME + dispatch-TIMESTAMP (a 3-line body; LINE 1 stays the
#     bare pid so every legacy `head -1` reader — including the sim's marker-count probe — keeps working);
#   • liveness = the pid is alive AND its CURRENT start-time still matches the recorded one
#     (PID-RECYCLING GUARD — a dead pid whose number a new, unrelated process reused is NOT the same
#     worker and must not be mistaken for a live slot holder);
#   • age is computed FROM THE MARKER'S OWN TIMESTAMP, so ANY watcher instance — even one that just
#     started and never saw the dispatch — can time a run out; never an in-process timer a restart drops.
# The every-tick corpse sweep (_sweep_gate_corpses) uses these to free a slot the SAME tick a worker
# dies or blows its deadline, so no marker corpse can ever hold a slot again.

# _now_epoch — seconds since the epoch (a seam: HERD_FAKE_NOW lets a unit test pin time deterministically).
_now_epoch() { printf '%s' "${HERD_FAKE_NOW:-$(date +%s)}"; }

# _pid_starttime <pid> — a STABLE per-process start-time token: constant for a process's whole life,
# different for a pid a later process recycled. `ps -o lstart=` is portable across macOS/BSD + Linux;
# whitespace is squeezed so the token compares byte-for-byte. Empty when the pid is gone or ps cannot
# answer — callers then fall back to a bare liveness check rather than over-reaping a live worker.
# HERD_PID_STARTTIME_CMD is a test seam (a stub can force a controlled/mismatched token).
_pid_starttime() {
  local p="${1:-}"; [ -n "$p" ] || return 0
  if [ -n "${HERD_PID_STARTTIME_CMD:-}" ]; then "$HERD_PID_STARTTIME_CMD" "$p" 2>/dev/null; return 0; fi
  ps -o lstart= -p "$p" 2>/dev/null | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# _pid_pgid <pid> — the process GROUP id of <pid>, empty when the pid is gone or ps cannot answer. Used
# to record a health worker's own process group at dispatch (HERD-283) so the whole suite subtree can be
# reaped as one group. HERD_PID_PGID_CMD is a test seam (mirrors _pid_starttime's stub).
_pid_pgid() {
  local p="${1:-}"; [ -n "$p" ] || return 0
  if [ -n "${HERD_PID_PGID_CMD:-}" ]; then "$HERD_PID_PGID_CMD" "$p" 2>/dev/null; return 0; fi
  ps -o pgid= -p "$p" 2>/dev/null | tr -d '[:space:]'
}

# _marker_write <file> <pid> [pgid] — lay down a restart-safe inflight marker: pid, its start-time,
# dispatch ts. An OPTIONAL 4th line records the pid's process GROUP (health workers only, HERD-283); when
# absent the marker is byte-identical to the legacy 3-line body, so every existing reader is unaffected.
_marker_write() {
  local f="$1" p="$2" pgid="${3:-}"
  { printf '%s\n' "$p"; printf '%s\n' "$(_pid_starttime "$p")"; printf '%s\n' "$(_now_epoch)"
    [ -n "$pgid" ] && printf '%s\n' "$pgid"; } \
    > "$f" 2>/dev/null || true
}

# _marker_pid / _marker_starttime / _marker_dispatch_ts / _marker_pgid <file> — read one field
# (line 1/2/3/4); empty if absent. Line 4 (pgid) is present only on markers written with a pgid.
_marker_pid()         { sed -n '1p' "$1" 2>/dev/null; }
_marker_starttime()   { sed -n '2p' "$1" 2>/dev/null; }
_marker_dispatch_ts() { sed -n '3p' "$1" 2>/dev/null; }
_marker_pgid()        { sed -n '4p' "$1" 2>/dev/null; }

# _marker_live <file> — true iff the marker's pid is alive AND (recycling guard) its current start-time
# still matches the recorded one. A marker with NO recorded start-time (a legacy pid-only marker, or a
# hand-planted holder) falls back to a bare kill -0; an unreadable CURRENT start-time also trusts kill -0
# so a transient ps hiccup never over-reaps a genuinely live worker (fail toward NOT reaping).
_marker_live() {
  local f="$1" pid st cur
  pid="$(_marker_pid "$f")"; [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  st="$(_marker_starttime "$f")"; [ -n "$st" ] || return 0
  cur="$(_pid_starttime "$pid")"; [ -n "$cur" ] || return 0
  [ "$cur" = "$st" ]
}

# _marker_age <file> — seconds since the marker's dispatch ts, or -1 when no ts is recorded (a legacy
# pid-only marker has no deadline — the corpse sweep still reaps it the moment its pid dies/recycles).
_marker_age() {
  local ts now; ts="$(_marker_dispatch_ts "$1")"
  case "$ts" in ''|*[!0-9]*) printf -- '-1'; return 0 ;; esac
  now="$(_now_epoch)"; printf '%s' "$(( now - ts ))"
}

# ── Backgrounded lane dispatch (HERD-237) ─────────────────────────────────────────────────────────
# Grounding (audit 2026-07-09, G4): the two lane invocations on the tick path ran in the FOREGROUND —
# `_drain_spawn_queue` waited on herd-feature.sh/herd-quick.sh, `spawn_resolver` waited on
# herd-resolve.sh. A lane creates a worktree, renders a task spec and starts an agent; a slow git
# fetch or a wedged driver call inside one froze merges, collections and limit-parks for every OTHER
# PR. The lane now runs in a background subshell and the tick moves on.
#
# WHAT IS PRESERVED, AND HOW: each lane's OUTCOME HANDLING moves into the background subshell with
# it, unsplit — the queue's durability contract (PR #151: an intent is consumed only after its lane
# observably spawned) and the resolver's spawn-ACK (HERD-206) still read the lane's real exit status
# and output, just off the tick. Every journal event is the same event with the same fields; only the
# tick it lands on can differ.
#
# WHY A MARKER, NOT JUST `&`: a `( … ) &` subshell of the watcher INHERITS the watcher's argv0
# ($HERD_WATCH_ARGV0). `_list_project_watchers` (bin/herd) attributes watchers by exact argv0 match,
# so an unmarked background lane would be counted as a second watcher by `herd status` and SIGTERM'd
# mid-spawn by `herd reload`'s stray reaper. The gate workers solved this with inflight markers; these
# reuse the mechanism, under a `.spawn-inflight-*` prefix that bin/herd exempts alongside the review
# and health ones. The parent writes the marker the instant `&` returns — but `&` forks FIRST, so a
# `herd reload` landing in that micro-window still sees an unexempted argv0 match and can SIGTERM the
# lane. That is survivable, not silent: the lane's claim (`.owner`, spawn-step.sh) names a now-dead pid,
# so the next `next` reclaims the intent and a later tick re-launches it. The marker narrows the
# window; the claim's liveness is what makes losing the race harmless.
#
# The lane marker doubles as the drain's CROSS-TICK MUTEX: the foreground drain implicitly ran one
# lane at a time and observed it finish before starting the next. `_lane_spawn_inflight` restores
# exactly that serialization without blocking — a tick that finds a live lane marker simply drains
# nothing and returns. Dead markers are garbage-collected by `_spawn_inflight_sweep` on EVERY tick
# (before the drain's queue-empty fast exits, so a project with no spawn queue still reaps resolver
# corpses), meaning a watcher killed mid-spawn cannot wedge the queue or leave a stale pid exempted
# in `_list_project_watchers`.
SPAWN_INFLIGHT_PREFIX="$TREES/.spawn-inflight-"
# Monotonic per-watcher dispatch counter — the uniquifier for a marker whose natural identity could
# repeat. Bumped in the TICK (never inside a `$(…)`, which would discard it), so two dispatches can
# never share a marker name however fast they follow one another. A restarted watcher restarts the
# count, which is harmless: its predecessor's markers are corpses and get swept.
_SPAWN_DISPATCH_SEQ=0

# _spawn_inflight_file <kind> <slug> <uniq> — a UNIQUE marker path for one in-flight lane.
# <kind> ∈ lane|resolve. <uniq> is supplied by the caller from something already unique to the
# dispatch (the intent id; the pr+sha+epoch), NOT from $RANDOM: the manifest ghost-key scan reads
# `${RANDOM:-…}` as an undeclared config key, and a dispatch already carries a better identity than a
# coin flip. Uniqueness matters: a same-slug re-dispatch (a resolver respawned for a new sha) would otherwise alias
# the previous worker's marker, and the FIRST worker's cleanup would then delete the SECOND's — silently
# un-exempting a live lane. The slug stays in the name so the marker is legible in `ls $TREES`.
# _spawn_slug_key <slug> — the filename-safe form of a slug. ONE definition, so the writer
# (_spawn_inflight_file) and every reader (the per-slug marker globs) can never drift apart.
#
# '-' is deliberately NOT in the safe set: it is the marker name's FIELD SEPARATOR. Leave it in the key
# and the per-slug glob `…resolve-<key>-*` also matches every slug that merely has <key> as a
# dash-prefix — a live lane for `fix-more` would make `fix` read STARTING and suppress its legitimate
# respawn. Mapping '-' to '_' makes the field boundary unambiguous. Two slugs differing only by '-' vs
# '_' still collide, as they already did for every other punctuation character.
_spawn_slug_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._' '_'; }

_spawn_inflight_file() {
  printf '%s%s-%s-%s' "$SPAWN_INFLIGHT_PREFIX" "$1" "$(_spawn_slug_key "$2")" "$(_spawn_slug_key "$3")"
}

# ── Lane workers are supervised processes too (HERD-268) ─────────────────────────────────────────
# The two populations below are exactly the shape lifecycle.sh (HERD-193) supervises: agent-watch is
# their OWNER, their marker already carries a pid + start-time (LIVENESS), and they have a natural
# DEADLINE. What they lacked was the bookkeeping — so a lane worker orphaned by a watcher killed
# mid-dispatch left a marker and a process nobody could attribute. They are now registered at dispatch
# and RETIRED at every teardown point they already had:
#
#   completed  the worker's body returned (the fast path, inside its own subshell)
#   swept      `_spawn_inflight_sweep` reaped its marker: the pid is dead, or recycled into another
#              process. This is the population's existing corpse sweep — no new actuator, no new kill.
#
# `lifecycle_sweep` (the per-tick supervision leg) is only the BACKSTOP: a record whose marker sweep
# never ran is reconciled there as `exited`, and one still ALIVE past its deadline is journaled +
# inboxed as `lifecycle_expired`. Nothing here kills anything.
#
# THE THREE REASONS ARE A JOURNAL PREFERENCE, NOT A STATE MACHINE. Every one of them converges on the
# same end state (record gone, worker accounted for), and the races between them are benign by
# construction: a worker whose own `rm` lands between the sweep's `[ -e ]` and its `_marker_live` is
# retired `swept` rather than `completed`; a worker that finishes before the parent registers it is
# retired `exited` by the backstop. `lifecycle_retire`'s file guard and its `rm` are not atomic, so a
# double-retire is VANISHINGLY narrow rather than impossible — and its only cost is a second journal
# line for a worker that is, either way, correctly accounted for.
#
# PID RECYCLING is handled where the marker is: `_marker_live` compares the recorded start-time before
# trusting `kill -0`, so a recycled lane pid is reaped + retired by `_spawn_inflight_sweep` on the next
# tick, well inside `_LC_LANE_DEADLINE`. (lifecycle.sh's own `_lc_pid_live` has no such guard, so a
# record that lost its marker AND had its pid recycled could reach `lifecycle_expired` — one
# observability row, never a gate, and the same exposure `reviewer`/`health-worker` already carry.)
#
# The MARKER NAME is the record key: `<prefix><kind>-<slug>-<uniq>` is already unique per dispatch
# (_SPAWN_DISPATCH_SEQ), so the lifecycle id needs no second identity to invent — and a corpse marker
# found by a sweep that never saw its dispatch still resolves to the record that dispatch wrote.

# _lane_lifecycle_key <marker> — print '<population>\t<id>' for a lane/resolve marker; return 1 for any
# other path (a marker kind this leg does not supervise). Pure; no side effects.
_lane_lifecycle_key() {
  local _llk_rest="${1##*/}"
  _llk_rest="${_llk_rest#"${SPAWN_INFLIGHT_PREFIX##*/}"}"
  case "$_llk_rest" in
    lane-*)    printf 'lane-worker\t%s'   "${_llk_rest#lane-}" ;;
    resolve-*) printf 'resolver-lane\t%s' "${_llk_rest#resolve-}" ;;
    *)         return 1 ;;
  esac
}

# _lane_lifecycle_spawn <marker> <pid> — register the contract for a just-forked lane worker.
# _lane_lifecycle_retire <marker> <reason> — close it at one of the teardown points above.
#
# Both return IMMEDIATELY unless lifecycle.sh is sourced AND LIFECYCLE_CONTRACTS is on — the dispatch
# path stays byte-inert by default, and the hermetic drain tests may extract these functions ALONE, with
# no library behind them. lifecycle_retire refuses to journal a retirement it cannot evidence, so the
# ordinary worker-vs-sweep race resolves to ONE journal line. Always 0.
_lane_lifecycle_spawn() {
  command -v lifecycle_enabled >/dev/null 2>&1 && lifecycle_enabled || return 0
  local _lls_k; _lls_k="$(_lane_lifecycle_key "$1")" || return 0
  [ -n "$_lls_k" ] || return 0
  lifecycle_spawn "${_lls_k%%$'\t'*}" "${_lls_k#*$'\t'}" "pid:$2" agent-watch
  return 0
}

_lane_lifecycle_retire() {
  command -v lifecycle_enabled >/dev/null 2>&1 && lifecycle_enabled || return 0
  local _llr_k; _llr_k="$(_lane_lifecycle_key "$1")" || return 0
  [ -n "$_llr_k" ] || return 0
  lifecycle_retire "${_llr_k%%$'\t'*}" "${_llr_k#*$'\t'}" "${2:-done}"
  return 0
}

# _spawn_inflight_bg <marker> <fn> [args…] — run <fn> in a background subshell, recording its pid in
# <marker> BEFORE returning, and clearing the marker when it finishes. Never blocks; always returns 0.
# The worker's own `rm` is the fast path; _spawn_inflight_sweep is the correctness one (it collects
# markers left by a watcher killed mid-spawn, and the marker a worker that exited BEFORE the parent
# got to write it — a race whose only cost is one skipped drain tick).
#
# The worker closes its own lifecycle contract (HERD-268) right where it clears its marker, so a clean
# lane is accounted for the moment it lands rather than waiting on the sweep's exit grace.
#
# `_marker_write` STAYS THE PARENT'S FIRST ACT AFTER THE FORK, ahead of the lifecycle bookkeeping. The
# marker is not only a corpse-sweep token: it is the RESOLVER LANE LOCK'S HOLDER IDENTITY, and
# `_resolve_lane_lock_acquire` breaks a held lock iff `! _marker_live <holder>` — for which a marker
# that does not exist YET reads exactly like a dead one. `_lane_lifecycle_spawn` costs a dozen forks
# (mktemp, mv, date, journal_append), each of which hands the CPU to the freshly-forked lane, whose very
# first act is to take that lock. Registering before writing the marker therefore let a queued sibling
# lane observe a live holder as dead, journal `resolver_lane_lock_broken reason=holder-dead` about it,
# and run a second `git worktree add` against the shared $MAIN — the exact overlap HERD-237's
# serialization exists to prevent. Marker first, always: bookkeeping never precedes a safety rail.
#
# What that costs is only a JOURNAL REASON, never state. A `true`-fast worker can remove the marker and
# run its own retire before the parent has written the record; that retire is then a silent no-op
# (lifecycle_retire never journals a retirement it cannot evidence) and the record it could not find is
# left behind with no marker to collect it. `lifecycle_sweep`'s exited-after-grace reconcile is built
# for precisely that: the worker is still accounted for, as `exited` rather than `completed`. Trading a
# lock-safety window for a nicer retire reason would be the wrong way round.
#
# With LIFECYCLE_CONTRACTS off both helpers return before touching anything, so the dispatch path is the
# pre-HERD-268 sequence, fork-for-fork.
_spawn_inflight_bg() {
  local _sib_marker="$1"; shift
  ( "$@"; rm -f "$_sib_marker" 2>/dev/null || true; _lane_lifecycle_retire "$_sib_marker" completed ) 9>&- &
  _SPAWN_INFLIGHT_BG_PID="$!"
  _marker_write "$_sib_marker" "$_SPAWN_INFLIGHT_BG_PID"
  _lane_lifecycle_spawn "$_sib_marker" "$_SPAWN_INFLIGHT_BG_PID"
  return 0
}

# _spawn_inflight_sweep — drop every spawn marker whose pid is dead (or recycled into another process),
# and retire that worker's lifecycle contract with it: this sweep IS the lane populations' corpse sweep
# (HERD-268), so a worker orphaned by a watcher killed mid-dispatch is accounted for on the next tick.
_spawn_inflight_sweep() {
  local _sis_f
  for _sis_f in "$SPAWN_INFLIGHT_PREFIX"*; do
    [ -e "$_sis_f" ] || continue
    if _marker_live "$_sis_f" 2>/dev/null; then continue; fi
    rm -f "$_sis_f" 2>/dev/null || true
    _lane_lifecycle_retire "$_sis_f" swept
  done
}

# _lane_spawn_inflight — true iff a builder lane spawned by a previous tick is STILL running. Tests the
# marker's LIVENESS, not its existence: a corpse marker (worker dead, or its pid recycled) can never
# hold the queue shut, whether or not the caller swept first. _spawn_inflight_sweep still GCs the files
# — this predicate merely refuses to depend on it having run.
_lane_spawn_inflight() {
  local _lsi_f
  for _lsi_f in "$SPAWN_INFLIGHT_PREFIX"lane-*; do
    [ -e "$_lsi_f" ] || continue
    _marker_live "$_lsi_f" 2>/dev/null && return 0
  done
  return 1
}

# _resolver_lane_inflight — true iff any resolver lane dispatch is STILL running. A pure liveness
# predicate: it drives `_spawn_resolver_wait` (the test/sim synchronization seam) and NOTHING gates a
# dispatch on it. See _resolve_lane_lock_acquire for why serialization lives in the lane, not here.
# Sweeps corpses first, so a watcher killed mid-dispatch cannot make this read "busy" forever.
_resolver_lane_inflight() {
  _spawn_inflight_sweep
  local _rli_f
  for _rli_f in "$SPAWN_INFLIGHT_PREFIX"resolve-*; do
    [ -e "$_rli_f" ] || continue
    _marker_live "$_rli_f" 2>/dev/null && return 0
  done
  return 1
}

# _resolver_lane_starting <slug> — true while THIS slug's resolver lane has been dispatched but has not
# yet produced an agent: the lane worker is alive (queued behind the lane lock, cloning the worktree,
# rendering the spec, starting the agent). It is the missing third source of "not dead" evidence.
#
# WHY (HERD-237): `record_resolve_attempt` runs on the tick and starts the 90 s _RESOLVER_DEAD_GRACE
# clock. That was a sound proxy for "the lane is starting" while the lane ran inline. It is not once
# lanes serialize: with K conflicting PRs the k-th lane starts at roughly (k-1) x lane-duration, and
# this whole change exists to tolerate lanes that take minutes. A queued lane has no roster row and no
# pane, so the instant its grace lapsed `_resolver_liveness_verdict` called it DEAD — and
# `_resolver_in_flight`, the SINGLE guard against double-dispatch, read false for a resolver that was
# dispatched and merely waiting its turn. Each tick then re-dispatched it, burned a respawn round, and
# after REFIX_MAX_ROUNDS painted the terminal false red "resolver gave up (3 rounds)" over a conflict
# nothing had yet attempted. The marker is the honest signal: it lives exactly as long as the lane.
_resolver_lane_starting() {
  local _rls_f
  for _rls_f in "$SPAWN_INFLIGHT_PREFIX"resolve-"$(_spawn_slug_key "$1")"-*; do
    [ -e "$_rls_f" ] || continue
    _marker_live "$_rls_f" 2>/dev/null && return 0
  done
  return 1
}

# ── Risk-tiered review classification (REVIEW_ESCALATE_GLOB / DOCS_ONLY_GLOB) ─────────────────────
# _classify_review_tier — moved to work-units/git-pr.sh (HERD-398, Phase 3 work-unit extraction).

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

# _review_pid_live <inflight-file> — true if the marker records a still-running reviewer (its recorded
# pid is alive AND, via the recycling guard, is still the SAME process the marker was written for).
_review_pid_live() { _marker_live "$1"; }

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

# _reviewer_registry_live <pr#> <headSha> — success iff the dispatch registry records a still-LIVE
# reviewer for this exact pr+sha: its poller pid is alive, OR (across a poller death) its pane still
# exists in the control surface. This is the never-duplicate-into-a-live-reviewer guard (HERD-113);
# a dead poller with no surviving pane is NOT live (returns false) so a clean re-dispatch can proceed.
_reviewer_registry_live() {
  local reg pid pane
  reg="$(_review_registry_file "$1" "$2")"
  [ -f "$reg" ] || return 1
  read -r pid pane < "$reg" 2>/dev/null || true
  if [ -n "${pid:-}" ] && [ "$pid" != "-" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  [ -n "${pane:-}" ] && [ "$pane" != "-" ] && herd_driver_pane_alive "$pane"
}

# _retire_reviewer_pane <pr#> <headSha> [reason] — the reviewer-pane lifecycle teardown (HERD-113).
# Reads the dispatch-registry row and, if it still names a LIVE pane, closes it via the driver and
# journals a reviewer_pane_retired event; then drops the registry row unconditionally. Called when a
# verdict is CONSUMED (the pane has done its job) and by the startup sweep (orphaned/completed panes).
# FAIL-SOFT + byte-quiet: no registry row, no pane, or an already-gone pane ⇒ no console output and no
# journal line — a workspace with no orphaned reviewer panes sees zero change.
_retire_reviewer_pane() {
  local pr="$1" sha="$2" reason="${3:-verdict-consumed}" reg pid pane
  # HERD-193 RETIRE: this is the reviewer population's real teardown point, so account for the
  # supervised process here — ABOVE the registry-row guard, since a reviewer whose row is already
  # gone (adopted, swept) is still a process this seat spawned. Byte-inert with the lever off.
  lifecycle_retire reviewer "${pr}-${sha}" "$reason"
  reg="$(_review_registry_file "$pr" "$sha")"
  [ -f "$reg" ] || return 0
  read -r pid pane < "$reg" 2>/dev/null || true
  if [ -n "${pane:-}" ] && [ "$pane" != "-" ] && herd_driver_pane_alive "$pane"; then
    # GUARDED CLOSE (HERD-134): the registry pane id can be stale/recycled and now name the BUILDER (or
    # another neighbour) sharing this tab. Verify the pane is still a reviewer BEFORE closing; on a
    # mismatch the guard REFUSES and journals pane_close_refused, so we journal reviewer_pane_retired
    # ONLY on a real close. The registry row is dropped unconditionally below either way — a row that
    # pointed at the wrong pane must not linger to be retried.
    # HERD-418 (review fix): ":review" — colon-anchored, not a bare word — matches BOTH the pretty
    # label ("pane:review·<slug>") and the sanitized registered agent name ("agent:review-<slug>"),
    # because herd_driver_pane_identity's tag:value shape carries exactly ONE colon (right after
    # "agent"/"pane"), so ":review" can only match immediately after it — never a co-tab pane whose
    # SLUG merely contains "review" (e.g. a builder on "fix-review-race", identity "agent:fix-review-
    # race", has no colon before "review" and is correctly excluded).
    if herd_close_pane_verified "$pane" ":review"; then
      journal_append reviewer_pane_retired pr "$pr" sha "$sha" pane "$pane" reason "$reason"
    fi
  fi
  rm -f "$reg" 2>/dev/null || true
}

# _sweep_reviewer_registry — one-shot STARTUP reconcile of the dispatch registry against live
# pids/panes (HERD-113 requirement 3). For each (pr,sha) row: a still-alive poller is a genuinely live
# reviewer → left untouched (a later dispatch ADOPTS it). A dead poller whose PANE still exists is an
# ORPHAN (nobody will collect its verdict) → the pane is retired and its inflight marker dropped so a
# clean re-dispatch can happen. A row with a pending result file is left for the normal gate step to
# collect + retire. Idempotent, dry-run-inert, and byte-quiet when there are no orphans.
_sweep_reviewer_registry() {
  [ -z "${DRYRUN:-}" ] || return 0
  local f base rest pr sha pid pane
  for f in "$TREES"/.review-registry-*; do
    [ -e "$f" ] || continue
    base="${f##*/}"; rest="${base#.review-registry-}"
    pr="${rest%-*}"; sha="${rest##*-}"
    [ -n "$pr" ] && [ -n "$sha" ] || continue
    # A finished reviewer's verdict is still waiting — let the normal gate step collect it and retire
    # the pane through the verdict-consumption path (which also records the ledger). Don't pre-empt it.
    [ -f "$(_review_result_file "$pr" "$sha")" ] && continue
    read -r pid pane < "$f" 2>/dev/null || true
    # Poller still alive → a live reviewer; adopt (leave the row + inflight marker as-is).
    if [ -n "${pid:-}" ] && [ "$pid" != "-" ] && kill -0 "$pid" 2>/dev/null; then continue; fi
    # Poller dead: retire any surviving (orphaned) pane, then drop the row + inflight marker so the
    # (pr,sha) can be cleanly re-dispatched — never left running alongside a fresh reviewer.
    _retire_reviewer_pane "$pr" "$sha" startup-sweep-orphan
    rm -f "$(_review_inflight_file "$pr" "$sha")" 2>/dev/null || true
  done
}

# _discard_stale_reviews <pr#> <currentSha> — a result or inflight marker for this PR keyed to
# ANY OTHER sha is stale (the PR has a newer head; that verdict must never be read). Discard
# stale results unread; TERM a stale in-flight reviewer (best-effort — herd-review.sh traps TERM
# and reports INFRA-FAIL to its own stale result file, which lands here next tick), retire its pane
# (HERD-113 — a stale reviewer's pane must not linger), and drop its markers so the slot frees up.
_discard_stale_reviews() {
  local pr="$1" sha="$2" f base
  for f in "$TREES/.review-result-$pr-"* "$TREES/.review-inflight-$pr-"* "$TREES/.review-tier-$pr-"* "$TREES/.review-block-$pr-"* "$TREES/.review-registry-$pr-"*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "${base##*-}" = "$sha" ] && continue
    case "$base" in
      .review-inflight-*)
        local pid; pid="$(head -1 "$f" 2>/dev/null || true)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true ;;
      .review-registry-*)
        # Retire the stale reviewer's pane before dropping the row (the trailing sha in the filename
        # is this marker's other-sha key). _retire_reviewer_pane rm's the row itself, so skip the rm below.
        local _sreg_stale_sha="${base##*-}"
        _retire_reviewer_pane "$pr" "$_sreg_stale_sha" stale-sha
        continue ;;
    esac
    rm -f "$f" 2>/dev/null || true
  done
}

# _bg_new_session <cmd> [args...] — launch <cmd> in a NEW session; set _BG_NEW_SESSION_PID to its pid.
# HERD-245: isolates gate workers from the caller's process group so a `kill -- -<pgid>` aimed at the
# watcher (herdr pane recycle on reload, sweep leg 5) never severs mid-flight review/health work.
# Preferred: util-linux `setsid` (no -f: $! IS the worker). Fallback: python os.setsid + exec (macOS
# has no setsid(1)). Last resort: plain background (no isolation). MUST NOT run inside $() — a command
# substitution subshell would reap/SIGHUP the child when it exits. stdin/stdout/stderr → /dev/null
# (gate workers communicate via result files, never the watcher's tty). fd 9 is CLOSED for the same
# reason _bg_health_worker closes it (HERD-339): a long-lived reviewer must not pin the watcher's
# singleton flock via the shared open-file description, or a HERD-266 self-restart cannot re-acquire it.
# `9>&-` is a hard no-op when fd 9 was never opened (mkdir-mutex path / lib-mode test), so always safe.
_bg_new_session() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" </dev/null >/dev/null 2>&1 9>&- &
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" </dev/null >/dev/null 2>&1 9>&- &
  else
    "$@" </dev/null >/dev/null 2>&1 9>&- &
  fi
  _BG_NEW_SESSION_PID=$!
}

# _bg_health_worker <fn> [args...] — background an IN-PROCESS health-suite worker in its OWN process
# group, so the whole suite subtree (a full `bash healthcheck.sh` + its many children) is later killable
# as ONE group without touching the watcher (HERD-283). Sets _BG_HEALTH_PID and _BG_HEALTH_PGID.
#
# This is _bg_new_session's isolation goal for a case setsid cannot serve: the worker is an in-process
# bash function (it needs every helper + global in scope), so it CANNOT be exec'd as an external argv.
# Instead, enabling monitor mode (`set -m`) for the single fork places the backgrounded subshell in its
# own process group (leader pid == pgid); `disown %+` then drops that job from the shell's table so a
# later `kill -<pgid>` from this same watcher prints no async job-control notice and leaves no tracked
# job. Monitor mode is restored to its prior state immediately — only the one fork runs under it.
#
# FD ISOLATION (HERD-339, live incident): the worker subtree must inherit NONE of the watcher's OWN
# descriptors. A bare `( "$@" ) &` kept the watcher's fd 0/1/2 AND its singleton-lock fd 9 open for the
# suite's whole ~9-min life, and two regressions followed:
#   • UNDRAINED PIPE — when the watcher runs under a pipe-stdout parent (`herd-watch | reader`, the
#     control-room render seam the last day's healthcheck-visibility merges lean on), the worker holds
#     the inherited write-end open, so the reader never sees EOF and blocks on an undrained pipe until
#     the suite ends. The suite itself streams to its own log at full speed, which is exactly why the
#     freeze looked like an "invisible" healthcheck rather than a dead one.
#   • LOCK PIN — the worker holds the flock singleton lock (fd 9) via the SHARED open-file description,
#     so a HERD-266 self-restart that deliberately outlives its in-flight workers cannot re-`flock -n 9`
#     (the old description is never dropped while a child still holds it).
# Detach at the subshell boundary EXACTLY as live_runtime's _HEALTH_WORKER_SH is launched
# (stdout/stderr=DEVNULL + start_new_session) and as _bg_new_session isolates reviewers: stdin/stdout/
# stderr → /dev/null and CLOSE fd 9. The worker's OWN inner `bash healthcheck > "$log" 2>&1` still
# streams the suite into its log — the boundary redirect only stops the subtree from pinning the parent
# pipe or the lock, so /dev/null (not the log) is correct and caller-agnostic (a caller that passes no
# log, e.g. a lib-mode test, never has its stdout guessed at). `9>&-` is a hard no-op when fd 9 was
# never opened (the mkdir-mutex singleton path, or a test), so it is always safe.
_bg_health_worker() {
  local _bhw_had_m; case "$-" in *m*) _bhw_had_m=1 ;; *) _bhw_had_m=0 ;; esac
  set -m
  ( "$@" ) </dev/null >/dev/null 2>&1 9>&- &
  _BG_HEALTH_PID=$!
  [ "$_bhw_had_m" = 1 ] || set +m
  disown %+ 2>/dev/null || true
  # A monitor-mode background subshell is ALWAYS its own process-group leader, so pgid == pid by
  # construction — recorded WITHOUT a `ps` call, both because it is exact and because a `ps` here would
  # sit between the fork and the caller's marker write, widening the slot-accounting race (the marker
  # must stay the parent's first act after the fork). _health_terminate_worker independently re-checks
  # pgid == pid AND pgid != the watcher's own group before it ever signals a group, so a mis-recorded
  # pgid can only ever DOWNGRADE to a single-pid kill — never endanger the watcher.
  _BG_HEALTH_PGID="$_BG_HEALTH_PID"
}

# _pin_review_sha <pr#> <headSha> — HERD-230 pin helper for review dispatch.
# Fetches the live PR head into a private tmp ref under $MAIN and verifies it still equals the
# dispatch sha (the sha the verdict will be keyed to). Echoes one token + exit status:
#   pinned     (0) — fetch succeeded and rev-parse matches $sha; objects are in $MAIN
#   unpinned   (0) — pin could not be verified (offline / hermetic / no MAIN); FAIL-SOFT: caller
#                    still dispatches with HERD_REVIEW_SHA set; herd-review.sh falls back to live
#                    `gh pr diff` when the pin objects are missing (journaled there too)
#   superseded (1) — fetch succeeded but the live head is a DIFFERENT commit; the dispatch sha is
#                    already obsolete, so the caller aborts cheaply (no reviewer spawn)
# The force-update refspec keeps the pin ref current; sha is embedded in the ref name so concurrent
# pins for different shas never clobber each other.
_pin_review_sha() {
  local pr="$1" sha="$2"
  local main="${MAIN:-${PROJECT_ROOT:-}}"
  local remote="${HERD_REMOTE:-origin}"
  local ref got want
  if [ -z "$main" ] || [ -z "$pr" ] || [ -z "$sha" ]; then
    printf 'unpinned'
    return 0
  fi
  # Need a real git dir (worktree or checkout). Hermetic tests often stub `git` or point MAIN at a
  # non-repo — soft-fail rather than block every dispatch.
  if [ ! -d "$main/.git" ] && [ ! -e "$main/.git" ]; then
    printf 'unpinned'
    return 0
  fi
  ref="refs/herd-review/pin-${pr}-${sha}"
  if ! git -C "$main" fetch -q "$remote" "+pull/${pr}/head:${ref}" 2>/dev/null; then
    journal_append review_pin_soft pr "$pr" sha "$sha" reason "fetch failed; live-diff fallback"
    printf 'unpinned'
    return 0
  fi
  got="$(git -C "$main" rev-parse --verify "${ref}^{commit}" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$got" ]; then
    journal_append review_pin_soft pr "$pr" sha "$sha" reason "rev-parse empty after fetch; live-diff fallback"
    printf 'unpinned'
    return 0
  fi
  # Match full or abbreviated dispatch sha against the fetched tip.
  case "$got" in
    "$sha"|"$sha"*) printf 'pinned'; return 0 ;;
  esac
  want="$(git -C "$main" rev-parse --verify "${sha}^{commit}" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$want" ] && [ "$got" = "$want" ]; then
    printf 'pinned'
    return 0
  fi
  journal_append review_pin_aborted pr "$pr" sha "$sha" head "$got" \
    reason "pr head moved; dispatch sha superseded"
  printf 'superseded'
  return 1
}

# _dispatch_review <pr#> <slug> <headSha> — launch herd-review.sh in the background, result file
# wired via $HERD_REVIEW_RESULT_FILE, and write the inflight marker (pid) for this exact pr+sha.
# Idempotent: an existing result file or live marker means this pr+sha is already handled — never
# double-dispatch. Callers gate on concurrency/retries; this only guards identity.
# HERD-230: pins the review INPUT to $sha before launch (fetch PR head into a tmp ref; abort if the
# head already moved). Passes HERD_REVIEW_SHA + HERD_REVIEW_PIN_MODE so herd-review.sh instructs the
# reviewer to read `git diff <merge-base>..<sha>` from $MAIN instead of live `gh pr diff` (a mid-review
# push must not desync reviewed content from the verdict-sha).
_dispatch_review() {
  local pr="$1" slug="$2" sha="$3" model="${4:-}" result inflight registry
  # SELF-RESTART QUIESCE (HERD-251): defence in depth. Every caller reaches here through
  # _review_gate_step, which holds earlier and cheaper (before the escalation arm is consumed), so this
  # is unreachable today. It returns NON-ZERO — never 0 — so a future caller cannot read the refusal as
  # a launched reviewer and report RUNNING/ESCALATED over nothing. Byte-inert with the lever off.
  _self_restart_hold_dispatch && return 1
  result="$(_review_result_file "$pr" "$sha")"
  inflight="$(_review_inflight_file "$pr" "$sha")"
  registry="$(_review_registry_file "$pr" "$sha")"
  [ -f "$result" ] && return 0
  [ -f "$inflight" ] && _review_pid_live "$inflight" && return 0
  # ADOPT, never duplicate (HERD-113): a live reviewer for this exact pr+sha — poller pid alive OR its
  # pane still present after a poller death — means one is already on it. Skip rather than spawn a second
  # (the 2026-07-08 double-Opus incident). The startup sweep retires a genuinely orphaned pane (dead
  # poller, no verdict) so a later tick re-dispatches cleanly; here we only refuse to double up on a LIVE one.
  if _reviewer_registry_live "$pr" "$sha"; then
    journal_append reviewer_adopted pr "$pr" sha "$sha" reason "live reviewer already dispatched for pr+sha"
    return 0
  fi
  # HERD-230: pin the review input to this exact dispatch sha. Superseded (head moved) → abort cheaply
  # (no spawn); a later tick will dispatch for the new head. Soft pin failure → still dispatch with
  # HERD_REVIEW_SHA set (herd-review falls back to live diff when objects are missing).
  local _pin_mode
  _pin_mode="$(_pin_review_sha "$pr" "$sha")" || {
    # superseded — head already moved past $sha; do not burn a reviewer on obsolete content
    return 0
  }
  # <model> is the risk-tier's chosen reviewer model. EMPTY means "use the default path" — do NOT
  # set HERD_REVIEW_MODEL, so herd-review.sh resolves $MODEL_REVIEW (and any operator-exported
  # HERD_REVIEW_MODEL override still wins) exactly as before tiering existed. A non-empty model
  # (the cheap tier) is passed through so the reviewer runs on that tier. HERD_REVIEW_REGISTRY_FILE is
  # the seam herd-review.sh writes its pane id back through (see the registry helpers above).
  # HERD_REVIEW_SHA + HERD_REVIEW_PIN_MODE (HERD-230): pin the reviewer's DIFF INPUT to this sha.
  # HERD-245: launch in a new session so a watcher process-group kill never severs this review.
  local _dr_pid
  if [ -n "$model" ]; then
    _bg_new_session env \
      HERD_REVIEW_RESULT_FILE="$result" HERD_REVIEW_REGISTRY_FILE="$registry" \
      HERD_REVIEW_SHA="$sha" HERD_REVIEW_PIN_MODE="$_pin_mode" HERD_REVIEW_MODEL="$model" \
      bash "$HERD_REVIEW_BIN" "$pr" "$slug"
  else
    _bg_new_session env \
      HERD_REVIEW_RESULT_FILE="$result" HERD_REVIEW_REGISTRY_FILE="$registry" \
      HERD_REVIEW_SHA="$sha" HERD_REVIEW_PIN_MODE="$_pin_mode" \
      bash "$HERD_REVIEW_BIN" "$pr" "$slug"
  fi
  _dr_pid="$_BG_NEW_SESSION_PID"
  # Lay down the registry row FIRST (pane id unknown yet → "-"), before the slower restart-safe marker
  # write below, so this placeholder lands in the narrowest possible window after launch — herd-review.sh
  # (or the stub) overwrites it with the real pane id once its agent pane is up, and must not race the
  # placeholder in behind it. The pid alone already lets a post-restart dispatch adopt this reviewer.
  printf '%s -\n' "$_dr_pid" > "$registry" 2>/dev/null || true
  # Restart-safe marker: pid + start-time (recycling guard) + dispatch ts (deadline any watcher can time).
  _marker_write "$inflight" "$_dr_pid"
  journal_append review_dispatched pr "$pr" sha "$sha" pid "$_dr_pid" \
    model "${model:-${HERD_REVIEW_MODEL:-${MODEL_REVIEW:-}}}" log_path "$result" pin "$_pin_mode"
  # Supervised-process contract (HERD-193): owner=agent-watch, liveness=the worker pid, deadline=the
  # corpse sweep's own REVIEW_INFLIGHT_TIMEOUT, retire=verdict-consumed (below) or the corpse sweep.
  # The pid is this POLLER, not the reviewer's agent pane — the pane outlives it and remains HERD-113's
  # `_retire_reviewer_pane` / startup-sweep problem. Byte-inert while LIFECYCLE_CONTRACTS=off.
  lifecycle_spawn reviewer "${pr}-${sha}" "pid:$_dr_pid" agent-watch
}

# ── INFRA-timeout circuit breaker (HERD-110) ─────────────────────────────────────────────────────
# The watcher re-dispatches a review for a candidate every tick until a verdict lands. When the
# ENVIRONMENT itself is dead (a claude exec-hang, an env failure, a reviewer that dies WITHOUT writing
# a verdict), that re-dispatch burns cycles forever against a corpse — and across N PRs it multiplies.
# This breaker tracks CONSECUTIVE INFRA failures (non-verdict reviewer deaths — the RETRY/FAILED path,
# NEVER a real PASS/BLOCK verdict) GLOBALLY across all PRs; after INFRA_BREAKER_MAX in a row it OPENS:
# new review/health dispatch stops, a loud 'infra circuit open' row + journal event surface, and after
# INFRA_BREAKER_COOLDOWN seconds it goes HALF-OPEN for a SINGLE probe. A probe that yields ANY real
# outcome CLOSES it (env recovered); another non-verdict death RE-OPENS it (fresh cooldown).
#
# CRITICAL — an INFRA failure (dead env) is NOT a code BLOCK verdict. A BLOCK proves the reviewer RAN
# and produced a verdict, i.e. the env is ALIVE — so a BLOCK (exactly like a PASS) RESETS the
# consecutive counter and never trips the breaker. Only a non-verdict death counts against it.
#
# BYTE-INERT BY DEFAULT: INFRA_BREAKER_MAX defaults to 0 (off). With it 0/empty/non-numeric every
# function below is an immediate no-op — no ledger writes, no journal, no gating — so behavior is
# byte-identical to before this feature whenever the key is unset.
INFRA_BREAKER_STATE="$TREES/.agent-watch-infra-breaker"   # one line: "<state> <fails> <opened_epoch> <probe_pr>"

# _breaker_enabled — true iff INFRA_BREAKER_MAX is a positive integer (opt-in). Default/0/garbage → off.
_breaker_enabled() {
  case "${INFRA_BREAKER_MAX:-0}" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

# _breaker_cooldown — INFRA_BREAKER_COOLDOWN seconds (empty/non-numeric → 300).
_breaker_cooldown() {
  case "${INFRA_BREAKER_COOLDOWN:-300}" in
    ''|*[!0-9]*) printf '300' ;;
    *) printf '%s' "$INFRA_BREAKER_COOLDOWN" ;;
  esac
}

# _breaker_read — echo "<state> <fails> <opened> <probe_pr>" (state ∈ closed|open|probing). A missing
# or legacy (short) ledger reads as "closed 0 0 -". This is the single source of truth read on every
# gate/record call, so the state survives across ticks AND across the command-substitution subshells
# the action pass calls _breaker_gate from (a file write persists; a shell variable would not).
_breaker_read() {
  local st="" fa="" op="" pb=""
  if [ -s "$INFRA_BREAKER_STATE" ]; then
    read -r st fa op pb < "$INFRA_BREAKER_STATE" 2>/dev/null || true
  fi
  printf '%s %s %s %s' "${st:-closed}" "${fa:-0}" "${op:-0}" "${pb:--}"
}

# _breaker_write <state> <fails> <opened> <probe_pr> — persist the one-line state (small truncating write).
_breaker_write() {
  printf '%s %s %s %s\n' "$1" "$2" "$3" "${4:--}" > "$INFRA_BREAKER_STATE" 2>/dev/null || true
}

# _breaker_record_infra — one non-verdict INFRA death was just observed. Increment the consecutive
# counter; on reaching INFRA_BREAKER_MAX (from CLOSED) OPEN with a fresh cooldown; any death while
# already OPEN/probing re-arms the cooldown (a probe that died again). The trip/re-open is journaled
# LOUDLY once per transition.
_breaker_record_infra() {
  _breaker_enabled || return 0
  local st fa op pb now max
  read -r st fa op pb <<EOF
$(_breaker_read)
EOF
  now="$(date +%s)"; max="$INFRA_BREAKER_MAX"
  fa=$(( ${fa:-0} + 1 ))
  if [ "$st" = "closed" ]; then
    if [ "$fa" -ge "$max" ]; then
      _breaker_write open "$fa" "$now" -
      journal_append infra_breaker_open scope global fails "$fa" threshold "$max" cooldown "$(_breaker_cooldown)"
    else
      _breaker_write closed "$fa" "${op:-0}" -
    fi
  else
    # Already open or mid-probe and it died again → re-arm the cooldown, drop any probe claim.
    _breaker_write open "$fa" "$now" -
    journal_append infra_breaker_reopen scope global fails "$fa" threshold "$max" cooldown "$(_breaker_cooldown)"
  fi
}

# _breaker_record_ok — a REAL verdict landed (a PASS or a BLOCK): the env is provably alive. Reset the
# consecutive counter; if the breaker was open/probing, CLOSE it and journal the recovery. Cheap no-op
# (no ledger churn) when already closed with a zero counter.
_breaker_record_ok() {
  _breaker_enabled || return 0
  local st fa op pb
  read -r st fa op pb <<EOF
$(_breaker_read)
EOF
  if [ "$st" != "closed" ]; then
    _breaker_write closed 0 0 -
    journal_append infra_breaker_close scope global recovered_via verdict
  elif [ "${fa:-0}" != "0" ]; then
    _breaker_write closed 0 0 -
  fi
}

# _breaker_gate <pr#> — per-candidate dispatch decision, called at the TOP of the action-pass loop
# body (before any health/review dispatch). Echoes one token:
#   PASS    — breaker closed → dispatch normally
#   PROBE   — breaker half-open and THIS candidate is the single recovery probe → dispatch normally
#   BLOCKED — breaker open (cooling down), or another candidate is already the in-flight probe
# Half-open is entered by transitioning OPEN→probing once the cooldown elapses: the FIRST candidate to
# reach the gate CLAIMS itself as the probe (its PR persisted in the ledger) and gets PROBE; every
# other candidate reads state=probing and, not being the claimed PR, gets BLOCKED — so exactly ONE
# probe runs. The claimed probe keeps getting PROBE across ticks (so it can dispatch on one tick and
# COLLECT its verdict on the next) until the probe resolves: a real verdict CLOSEs the breaker, another
# death RE-OPENs it. A probe that never resolves within a second cooldown window is re-claimed (self-heal
# against a wedged probe). Byte-inert (always PASS) when disabled.
_breaker_gate() {
  _breaker_enabled || { printf PASS; return 0; }
  local pr="${1:-}" st fa op pb now cd
  read -r st fa op pb <<EOF
$(_breaker_read)
EOF
  if [ "$st" = "open" ] || [ "$st" = "probing" ]; then
    now="$(date +%s)"; cd="$(_breaker_cooldown)"
    if [ $(( now - ${op:-0} )) -ge "$cd" ]; then
      # Cooldown elapsed (or a wedged probe aged out) → (re)claim THIS candidate as the single probe.
      _breaker_write probing "$fa" "$now" "$pr"
      printf PROBE; return 0
    fi
    # Still cooling down: only the already-claimed probe PR may dispatch; everyone else waits.
    if [ "$st" = "probing" ] && [ -n "$pr" ] && [ "$pr" = "$pb" ]; then printf PROBE; return 0; fi
    printf BLOCKED; return 0
  fi
  printf PASS
}

# (HERD-306) _breaker_cooldown_remaining was DELETED with the bash action pass: it existed only to
# render the OPEN-breaker cooldown seconds in _tick_act's status row and had no other consumer. The
# breaker gate itself (_breaker_gate + the _breaker_* state helpers) stays — the sim/test suite and the
# Python engine's dispatch both rely on it.

# ── Claude exec-hang probe (HERD-108) ─────────────────────────────────────────────────────────────
# On some environments `claude` WEDGES on invocation — every exec hangs before the process finishes
# starting (e.g. the macOS com.apple.quarantine _dyld_start hang, issue #137). A wedged claude makes
# every review/refix dispatch spawn a corpse: the reviewer never writes a verdict and an auto-refix
# bounce lands on a dead session, so the poll loop burns cycles forever against an exec-hang it cannot
# see. This probe DETECTS the wedge DIRECTLY — a trivial `claude --version` under a HARD timeout, run
# ONCE per tick before dispatch — so the watcher can HOLD review/refix and surface the hang LOUDLY (+ a
# journal infra_event) instead of feeding a dead binary. It COMPLEMENTS the HERD-110 breaker (which
# only reacts AFTER reviewers die without a verdict): the probe catches the wedge up front, before a
# single reviewer is spawned. `herd doctor`'s own `claude responds` check reports the same hang at
# diagnosis time (scripts/herd/herd-preflight.sh).
#
# BYTE-INERT BY DEFAULT: WATCH_CLAUDE_PROBE_TIMEOUT defaults to 0 (off). With it 0/empty/non-numeric
# the probe is a no-op — no claude exec, no journal, no gating — so behavior is byte-identical to before
# this feature. Set it to a small positive integer (seconds; 5 is a conservative arm) to enable.
CLAUDE_HANG_STATE="$TREES/.agent-watch-claude-hang"   # one line: "<epoch-of-current-hang-episode>" (absent when healthy)

# _claude_probe_secs — the armed timeout in seconds (echoed), or return 1 when the probe is disabled
# (0/unset/non-numeric → OFF, fail-safe parse). Mirrors _breaker_enabled's opt-in shape.
_claude_probe_secs() {
  case "${WATCH_CLAUDE_PROBE_TIMEOUT:-0}" in
    ''|*[!0-9]*|0) return 1 ;;
    *) printf '%s' "$WATCH_CLAUDE_PROBE_TIMEOUT"; return 0 ;;
  esac
}

# _claude_probe_run_timeout <secs> <cmd> [args...] — run <cmd> under a HARD wall-clock timeout, portable
# across macOS/Linux: prefers coreutils `timeout` / `gtimeout`, else a pure-shell watchdog (background,
# poll, SIGTERM→SIGKILL). stdout/stderr suppressed. Returns 124 on timeout (coreutils convention), else
# the command's own rc. Every kill/wait/sleep is guarded so it can never abort a caller under `set -e`.
# Mirrors herd-preflight.sh's doctor timeout runner (not sourced here — the watcher stays self-contained).
_claude_probe_run_timeout() {
  local secs="$1"; shift
  local rc=0
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@" >/dev/null 2>&1 || rc=$?; return "$rc"; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@" >/dev/null 2>&1 || rc=$?; return "$rc"; fi
  # Pure-shell fallback (stock macOS has neither). Needs a working `sleep`; if absent, degrade to an
  # un-timed direct run rather than busy-spin into a FALSE timeout (only bites an artificially stripped PATH).
  if ! sleep 0 2>/dev/null; then "$@" >/dev/null 2>&1 || rc=$?; return "$rc"; fi
  "$@" >/dev/null 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null || true; sleep 1; kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true; return 124
    fi
    sleep 1; waited=$((waited+1))
  done
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

# _claude_exec_hung — probe claude ONCE and echo this tick's verdict:
#   HUNG  — `claude --version` did not return within the armed timeout (a real exec-wedge)
#   OK    — probe disabled, OR claude responded in time / exited non-zero (broken-but-not-wedged) /
#           is absent — every NON-hang outcome: the queue is NOT held on them (fail-soft)
# On the FIRST HUNG of a hang episode it journals ONE loud infra_event (deduped via CLAUDE_HANG_STATE so
# a persistent wedge does not spam the journal every tick); any non-hang outcome CLEARS the marker (and
# journals a one-line recovery when a hang had been on record) so a later relapse journals afresh. A
# broken/absent claude is deliberately NOT a hang: claude may simply not be installed (the doctor reports
# that) and a non-zero `--version` is a different fault — neither should stall an otherwise-live queue.
_claude_exec_hung() {
  local secs rc
  secs="$(_claude_probe_secs)" || { printf OK; return 0; }
  if ! command -v claude >/dev/null 2>&1; then
    _claude_hang_clear
    printf OK; return 0
  fi
  rc=0
  _claude_probe_run_timeout "$secs" claude --version || rc=$?
  if [ "$rc" -eq 124 ]; then
    if [ ! -s "$CLAUDE_HANG_STATE" ]; then
      journal_append infra_event component agent-watch reason claude-exec-hang \
        detail "claude --version did not return within ${secs}s (exec-hang) — holding review/refix dispatch" \
        timeout_secs "$secs"
      printf '%s\n' "$(date +%s)" > "$CLAUDE_HANG_STATE" 2>/dev/null || true
    fi
    printf HUNG; return 0
  fi
  _claude_hang_clear
  printf OK; return 0
}

# _claude_hang_clear — drop the hang-episode marker; if a hang HAD been on record, journal one recovery
# line so the episode's open/close is visible. Cheap no-op when no hang was recorded.
_claude_hang_clear() {
  [ -s "$CLAUDE_HANG_STATE" ] || return 0
  rm -f "$CLAUDE_HANG_STATE" 2>/dev/null || true
  journal_append infra_event component agent-watch reason claude-exec-hang-cleared \
    detail "claude --version responded again — resuming review/refix dispatch"
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
    # HERD-156 (record-before-rm): DURABLY record the verdict to the ledger FIRST, and only THEN remove
    # the reviewer's scratch files. The old order (rm → record) had a fatal seam: a crash BETWEEN the rm
    # and the record deleted the result file with NO ledger row to show for it, permanently losing a
    # collected PASS/BLOCK — the next tick, finding neither result nor verdict, would dispatch a
    # brand-new review from scratch. Recording first makes the collect at-least-once: a crash after the
    # record simply re-reads the still-present result file next tick and re-records it (duplicate ledger
    # rows are last-wins = safe). The rm + pane-retire below are pure cleanup that a re-run repeats
    # harmlessly.
    local _rgs_echo=""
    case "$verdict_line" in
      # A parseable PASS/BLOCK is reviewer-backed (herd-review.sh only emits these from a real
      # verdict line + PR comment; a no-verdict run now reports INFRA-FAIL, not a default BLOCK).
      # A real PASS verdict proves the env is ALIVE → reset the infra breaker's counter (HERD-110).
      # PASS may carry a HERD-105 'advisory:' tail (' — advisory: …'); a bare 'REVIEW: PASS' has
      # none. Either way the merge proceeds on PASS — the advisory notes are journalled (never
      # gate). Match both shapes; the record + echo are identical for a finding-free PASS.
      "REVIEW: PASS"|"REVIEW: PASS "*)
        _breaker_record_ok
        record_review "$pr" "$sha" "PASS" "reviewer"
        _record_advisory_notes "$pr" "$sha" "$verdict_line"
        _rgs_echo=PASS ;;
      "REVIEW: BLOCK"*)
        _breaker_record_ok
        record_review "$pr" "$sha" "BLOCK" "reviewer"
        # Cache the structured rule/why/location so the auto-refix bounce is actionable (HERD-104).
        _persist_block_fields "$pr" "$sha" "$verdict_line"
        _rgs_echo=BLOCK ;;
      *)
        # INFRA-FAIL, EMPTY capture, or rc0-no-verdict: an infrastructural death, NOT a refused
        # verdict — never cached to the ledger, retried next poll with a cap. Counts against the
        # global INFRA circuit breaker (HERD-110): a run of these across PRs means the env is dead.
        record_review_retry "$pr" "$sha"
        _breaker_record_infra
        if [ "$(_review_retry_count "$pr" "$sha")" -ge "$_REVIEW_RETRY_MAX" ]; then _rgs_echo=FAILED; else _rgs_echo=RETRY; fi
        ;;
    esac
    # Verdict is now durably in the ledger → drop the reviewer's scratch files. VERDICT CONSUMED →
    # retire the reviewer's pane (HERD-113): a PASS/BLOCK reviewer leaves its pane OPEN with an idle
    # session showing the verdict banner; now that the watcher has read the verdict that pane has done
    # its job, so close it (and drop the registry row). No-op when there is no live pane (headless, or
    # an INFRA-FAIL reviewer that already tore down its own pane).
    rm -f "$result" "$inflight" "$(_review_tier_file "$pr" "$sha")" 2>/dev/null || true
    _retire_reviewer_pane "$pr" "$sha" verdict-consumed
    echo "$_rgs_echo"; return 0
  fi

  # In flight and alive → wait. Dead with no result = severed reviewer → reap, count, re-dispatch.
  if [ -f "$inflight" ]; then
    if _review_pid_live "$inflight"; then echo RUNNING; return 0; fi
    rm -f "$inflight" 2>/dev/null || true
    # A reviewer that died WITHOUT writing a verdict is another non-verdict INFRA death (HERD-110).
    # If its pane somehow survived (a herdr reload orphaned it), retire it now so the re-dispatch
    # below never runs alongside a still-live reviewer (HERD-113). No-op if the pane is already
    # gone; drops the registry row either way so the fresh dispatch starts clean.
    _retire_reviewer_pane "$pr" "$sha" orphaned-poller-dead
    record_review_retry "$pr" "$sha"
    _breaker_record_infra
  fi

  if [ "$(_review_retry_count "$pr" "$sha")" -ge "$_REVIEW_RETRY_MAX" ]; then echo FAILED; return 0; fi

  # SELF-RESTART QUIESCE (HERD-251): the watcher is draining toward an in-place re-exec on new engine
  # code — start no new reviewer. Placed BELOW the collect/in-flight branches (a running review still
  # finishes and its verdict is still recorded) and ABOVE every step with a side effect: no tier
  # classification, no carry-forward, no escalation-arm consumption. QUEUED is the existing
  # "will dispatch on a later tick" token, so the candidate holds without merging — and the restarted
  # watcher dispatches it on new code. Byte-inert with the lever off.
  if _self_restart_hold_dispatch; then echo QUEUED; return 0; fi

  # DELTA-SCOPED REVIEW carry-forward (HERD-204): before spending a reviewer on this new sha, try to
  # PROVE it differs from this PR's last-passed sha ONLY by a merge of DEFAULT_BRANCH (a pure
  # integration push). If proven, the prior PASS is carried forward onto this sha (recorded +
  # journalled) and no reviewer is dispatched. Fail-closed (see _delta_is_integration_only): any
  # authored change or unprovable case falls straight through to the normal review below. Byte-inert
  # when DELTA_REVIEW is off. Decided BEFORE the risk-tier classification + escalation-arm consumption
  # so a carry consumes neither a reviewer slot nor a pending Opus escalation.
  if _maybe_carry_forward_review "$pr" "$slug" "$sha"; then echo PASS; return 0; fi

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
  if [ "$(_count_live_reviews)" -ge "$(_review_conc)" ]; then echo QUEUED; return 0; fi
  if [ -n "$_esc_armed" ]; then
    rm -f "$_esc_file" 2>/dev/null || true
    # (d) durable record of the review-lane step-up; the caller paints the '⬆️  escalated to …' row.
    journal_append review_escalated pr "$pr" sha "$sha" model "$_rt_model" \
      rounds "$(refix_round_count_kind "$pr" review)" reason "cheap reviewer missed the issue across refix rounds"
    _dispatch_review "$pr" "$slug" "$sha" "$_rt_model"
    echo ESCALATED; return 0   # distinct from RUNNING so the console shows the Opus upgrade
  fi
  _dispatch_review "$pr" "$slug" "$sha" "$_rt_model"
  echo RUNNING
}

# ── herd/gates commit status (HERD-194) ──────────────────────────────────────────────────────────
# The watcher is the ONLY thing that runs the gates (healthcheck + adversarial review). When it clears
# a (pr,sha) it posts a `herd/gates` commit status; the operator wires `require herd/gates` into
# GitHub branch protection (recipe: docs/governance-gates.md). That makes the gate FAIL-SAFE across
# seats and collaborators: anyone MAY merge, but nothing UNGATED can — the status is posted ONLY by a
# watcher that actually ran the gates, so its ABSENCE (no watcher blessed this commit) leaves the PR
# unmergeable under protection. --match-head-commit in do_merge stays as the belt-and-suspenders guard.
#
# SUCCESS-ONLY: the watcher posts EXACTLY ONE terminal state — `success`, when both gates are green.
# It NEVER posts a non-passing status (`pending` or `failure`). This is deliberate and load-bearing: a
# non-passing commit status flips a CLEAN sha to mergeStateStatus=UNSTABLE in the DEFAULT unprotected
# config (where herd/gates is not a required check), and UNSTABLE is neither CLEAN (drops out of the
# merge path) nor BLOCKED (not gate-eligible) — a self-inflicted deadlock that would silently strand
# every PR and break the block/override/auto-refix paths. The fail-safe does not need a failing status:
# it rests entirely on the ABSENCE of `success` (a PR the watcher did not bless has no success status,
# so it is unmergeable under `require herd/gates` protection — GitHub renders the missing REQUIRED check
# as "Expected" on its own). A gate FAIL therefore posts NOTHING; only a green (pr,sha) is blessed.
# The success post is idempotent + at-most-once (sha-keyed $GATE_STATUS_STATE ledger), and the whole
# surface is best-effort + fail-soft — every helper returns 0 and never breaks the gate loop.

# _gate_status_enabled — master lever. GATE_STATUS=off disables posting entirely (byte-inert: no read,
# no post, no ledger); any other value (default) → on. Mirrors STALE_DUP_DETECT's on|off shape.
_gate_status_enabled() { [ "${GATE_STATUS:-on}" != "off" ]; }

# _gate_status_posted <pr#> <sha> <conclusion> — true if THIS watcher already recorded a successful
# post of this exact (pr,sha,conclusion). The at-most-once guard for the network write.
_gate_status_posted() {
  [ -s "$GATE_STATUS_STATE" ] || return 1
  awk -v p="$1" -v s="$2" -v c="$3" '$2==p && $3==s && $4==c{f=1} END{exit f?0:1}' "$GATE_STATUS_STATE" 2>/dev/null
}

# _record_gate_status <pr#> <sha> <conclusion> — append one ledger row (only after a successful post).
_record_gate_status() {
  printf '%s %s %s %s\n' "$(date +%s)" "$1" "$2" "$3" >> "$GATE_STATUS_STATE"
}

# _gate_status_desc <conclusion> — the default human-facing description shown on the GitHub check row.
_gate_status_desc() {
  case "$1" in
    success) printf 'healthcheck + adversarial review passed' ;;
    *)       printf 'herd/gates' ;;
  esac
}

# post_gate_status <pr#> <sha> <conclusion> [description] — post the herd/gates commit status for this
# (pr,sha) via the GitHub Statuses API, at most ONCE per (pr,sha). ONLY `success` is accepted (it maps
# to the API `state`); every non-passing conclusion (`pending`/`failure`/anything) is intentionally
# rejected as a no-op — a non-passing status mutates mergeStateStatus and would strand the PR (see the
# state-machine note above). No-op when GATE_STATUS=off, the sha is empty, or success was already
# posted. Under --dry-run it is a pure no-op (no network, no ledger). The ledger row is written ONLY on
# a successful API write, so a failed post re-tries next tick — the blessing MUST land for the fail-safe
# to hold. Always returns 0.
post_gate_status() {
  local pr="$1" sha="$2" state="$3" desc="${4:-}"
  _gate_status_enabled || return 0
  [ -n "$sha" ] || return 0
  case "$state" in success) ;; *) return 0 ;; esac
  _gate_status_posted "$pr" "$sha" "$state" && return 0
  [ -n "$DRYRUN" ] && return 0
  # CROSS-SEAT DUAL-ENGINE HALT (HERD-308): posting the herd/gates blessing is a cross-seat write. If
  # this seat is STALE under a live dual-engine mismatch, HOLD it — a newer engine owns the pool's write
  # format; our blessing must not land. Gated on the lever ⇒ byte-identical when ENGINE_SEAT_RECONCILE=off.
  if [ "${ENGINE_SEAT_RECONCILE:-off}" = on ] && [ -n "${_ENGINE_SEAT_HALT:-}" ]; then
    journal_append engine_seat_write_held surface post_gate_status pr "$pr" sha "$sha"
    return 0
  fi
  # SETTER GUARD (HERD-247): never bless a sha another seat is still blocking, and never overwrite a
  # foreign herd/gates=failure with our success. Runs AFTER the ledger/dry-run short-circuits, so it
  # costs its (memoized) reads only on the one tick that would actually write the blessing. Called
  # directly — a subshell would discard the memo. See _cross_seat_block_standing.
  if _cross_seat_block_standing "$pr" "$sha"; then
    _xseat_journal_honored "$pr" "$sha" "$_XSEAT_SEAT" setter
    return 0
  fi
  [ -n "$desc" ] || desc="$(_gate_status_desc "$state")"
  if _gh_timeout gate_status_post api "repos/{owner}/{repo}/statuses/$sha" -f state="$state" -f context="$GATE_STATUS_CONTEXT" -f description="$desc" >/dev/null 2>&1; then
    _record_gate_status "$pr" "$sha" "$state"
    journal_append gate_status pr "$pr" sha "$sha" state "$state" context "$GATE_STATUS_CONTEXT"
  fi
  return 0
}

# _gate_status_blessed <sha> — true if the head sha ALREADY carries a herd/gates=success commit status
# (posted by THIS seat or another operator's watcher). Reads the live GitHub statuses for the sha; the
# /statuses list is newest-first, so the [0] of the herd/gates-context entries is the current state.
# Fail-soft: empty sha, offline gh, or no such status → false (not blessed) so the gates run normally.
_gate_status_blessed() {
  local sha="$1" state
  [ -n "$sha" ] || return 1
  state="$(_gh_timeout gate_status_blessed api "repos/{owner}/{repo}/commits/$sha/statuses" \
             --jq "[.[] | select(.context==\"$GATE_STATUS_CONTEXT\")][0].state" 2>/dev/null || true)"
  [ "$state" = "success" ]
}

# ── cross-seat BLOCK precedence (HERD-247) ───────────────────────────────────────────────────────
# INCIDENT (PR #343, 2026-07-09 16:19-16:25Z): two seats gated the same PR concurrently. One seat's
# reviewer posted a correctness BLOCK; minutes later the OTHER seat's reviewer posted a PASS, that
# seat's watcher blessed the sha and merged over the standing BLOCK. A BLOCK from ANY seat must be
# TERMINAL for that sha until it is RESOLVED — a second seat's PASS is a second opinion, not a
# resolution. The review ledger cannot see this: it is per-seat local state, so each watcher only ever
# knows its OWN verdict. Both guards below therefore read only artifacts EVERY seat already writes —
# the herd/gates commit status and the PR's comments. No new substrate, no new config key.
#
#   SETTER GUARD  post_gate_status refuses to bless a sha carrying a standing foreign BLOCK.
#   MERGE GUARD   the merge-eligibility path holds the PR before `gh pr merge`, with a loud row.
#
# WHY NO `failure` STATUS IS POSTED. Posting herd/gates=failure on the standing-BLOCK sha would break
# the SUCCESS-ONLY invariant documented above, and it would strand the PR PERMANENTLY: a non-passing
# status flips a CLEAN sha to mergeStateStatus=UNSTABLE in the default unprotected config, and UNSTABLE
# is neither CLEAN (drops out of the candidate loop) nor BLOCKED (not gate-eligible via
# _gate_bless_eligible) — so after the blocking seat reconciles, NO seat can re-enter the loop to
# overwrite the status back to success. The fail-safe never needed it: WITHHOLDING success already
# leaves the PR unmergeable under `require herd/gates` protection, and the MERGE GUARD holds it in the
# unprotected config. The other half IS honored — an existing herd/gates=failure written by another
# seat is KEPT, never overwritten with our success.
#
# RESOLUTION flows through existing surfaces only: the blocking seat posts a NEWER verdict comment for
# the same sha reading PASS, or a human records the sha-keyed override (`herd-approve.sh override`). A
# new commit is a new sha and carries no verdict at all, so it starts clean.
#
# FAIL-SOFT: an unreadable commit/status/comment list, or an unresolvable seat identity, journals
# `cross_seat_block_scan state=degraded` and reports NO standing block — today's behavior, never a
# false hold. With no foreign status and no foreign verdict comment the surface is byte-identical.

# The verdict classifier. Reads `gh pr view --json comments` JSON on stdin; argv = <since-iso> <me>.
# A comment is a VERDICT comment when its first non-empty line — stripped of markdown emphasis, because
# real reviewers post `REVIEW: **BLOCK** — …` and `**PASS — no correctness bug found.**` — contains the
# whole word BLOCK or PASS (BLOCK wins; a BLOCK's prose may mention passing). Everything else (the
# watcher's own 🐑/🔁 rows, a human's prose) is not a verdict and is ignored. Only comments created at or
# after the head sha landed count, which is what keys a verdict to a sha: GitHub comments carry no sha.
# Per foreign seat we keep only its LATEST verdict, so a blocking seat's newer PASS resolves its BLOCK.
# Exit 0 + prints the (lexically first) blocking seat's login · 1 = no standing block · 2 = degraded.
_XSEAT_PY='import json,sys,re
since, me = sys.argv[1], sys.argv[2]
try: d = json.load(sys.stdin)
except Exception: sys.exit(2)
if not isinstance(d, dict): sys.exit(2)
latest = {}
for c in (d.get("comments") or []):
    login = ((c.get("author") or {}).get("login") or "")
    when = c.get("createdAt") or ""
    if not login or not when or login == me or when < since: continue
    first = ""
    for ln in (c.get("body") or "").splitlines():
        s = re.sub("[*`_#>]", "", ln).strip()
        if s:
            first = s
            break
    if re.search(r"\bBLOCK\b", first): v = "BLOCK"
    elif re.search(r"\bPASS\b", first): v = "PASS"
    else: continue
    prev = latest.get(login)
    if prev is None or when >= prev[0]: latest[login] = (when, v)
blockers = sorted(l for l, (w, v) in latest.items() if v == "BLOCK")
if blockers:
    sys.stdout.write(blockers[0])
    sys.exit(0)
sys.exit(1)'

# _gate_status_current <sha> — the CURRENT herd/gates status for the sha as "<state> <creator-login>"
# (either field may be empty). Same newest-first read as _gate_status_blessed, one extra field: WHO
# wrote it, so a failure posted by another seat is distinguishable from one of ours. Fail-soft: empty.
_gate_status_current() {
  [ -n "${1:-}" ] || return 0
  _gh_timeout gate_status_current api "repos/{owner}/{repo}/commits/$1/statuses" \
    --jq "[.[] | select(.context==\"$GATE_STATUS_CONTEXT\")][0] | \"\(.state // \"\") \(.creator.login // \"\")\"" 2>/dev/null || true
}

# _xseat_foreign_block <pr#> <sha> <me> — scan the PR's comments for a standing BLOCK from another seat
# on THIS sha. Prints the blocking seat's login. rc: 0 standing · 1 none · 2 degraded (unreadable).
_xseat_foreign_block() {
  local pr="$1" sha="$2" me="$3" since json out rc
  since="$(_gh_timeout xseat_commit_date api "repos/{owner}/{repo}/commits/$sha" --jq '.commit.committer.date' 2>/dev/null || true)"
  case "$since" in ''|null) return 2 ;; esac
  json="$(_gh_timeout xseat_comments pr view "$pr" --json comments 2>/dev/null || true)"
  [ -n "$json" ] || return 2
  out="$(printf '%s' "$json" | python3 -c "$_XSEAT_PY" "$since" "$me" 2>/dev/null)"; rc=$?
  case "$rc" in 0) printf '%s' "$out" ;; 1|2) ;; *) rc=2 ;; esac
  return "$rc"
}

# _xseat_note_once <key> — true the FIRST time this process sees <key>. Keeps the per-tick guard from
# re-journaling the same (pr,sha) event every 4s while a PR sits held; the console row still renders.
_XSEAT_NOTED=""
_xseat_note_once() {
  case " $_XSEAT_NOTED " in *" $1 "*) return 1 ;; esac
  _XSEAT_NOTED="$_XSEAT_NOTED $1"
  return 0
}

# _cross_seat_block_standing <pr#> <sha> — THE shared check both guards run. Returns 0 when a standing
# foreign BLOCK exists for (pr,sha) and sets $_XSEAT_SEAT to the blocking seat's login; non-zero (and
# an empty $_XSEAT_SEAT) otherwise. MUST be called DIRECTLY, never in a `$()` subshell — the memo and
# $_XSEAT_SEAT would be discarded. Checks, cheapest first:
#   1. sha-keyed human override recorded → resolved, no hold (the documented human out).
#   2. herd/gates=failure written by ANOTHER seat → standing (we never post failure, so it is foreign).
#   3. a foreign seat whose LATEST verdict comment for this sha is BLOCK → standing.
# The network reads are memoized per (pr,sha) for $_XSEAT_MEMO_TTL seconds so a held PR costs at most
# one scan per minute, not one per 4s tick — a resolution is honored within that window.
: "${_XSEAT_MEMO_TTL:=60}"
_XSEAT_MEMO_KEY=""; _XSEAT_MEMO_TS=0; _XSEAT_MEMO_SEAT=""; _XSEAT_MEMO_RC=1
_XSEAT_SEAT=""
_cross_seat_block_standing() {
  local pr="$1" sha="$2" me now rc cur st creator seat frc
  _XSEAT_SEAT=""
  [ -n "$pr" ] && [ -n "$sha" ] || return 1
  now="$(date +%s)"
  if [ "$_XSEAT_MEMO_KEY" = "$pr $sha" ] && [ "$(( now - _XSEAT_MEMO_TS ))" -lt "$_XSEAT_MEMO_TTL" ]; then
    _XSEAT_SEAT="$_XSEAT_MEMO_SEAT"
    return "$_XSEAT_MEMO_RC"
  fi
  rc=1
  if override_exists "$pr" "$sha"; then
    rc=1
  else
    # Identify "another seat" by comment author != this seat's gh auth login. Unresolvable identity →
    # degraded: EVERY author would read as foreign, which would hold on our OWN seat's block.
    _resolve_watcher_owner
    me="$_WATCHER_OWNER_CACHE"
    if [ -z "$me" ]; then
      _xseat_journal_degraded "$pr" "$sha" "seat identity unresolved"
      rc=1
    else
      cur="$(_gate_status_current "$sha")"
      st="${cur%% *}"; creator="${cur#* }"
      [ "$creator" = "$cur" ] && creator=""
      if [ "$st" = "failure" ] && [ "$creator" != "$me" ]; then
        _XSEAT_SEAT="${creator:-unknown}"
        rc=0
      else
        seat="$(_xseat_foreign_block "$pr" "$sha" "$me")"; frc=$?
        case "$frc" in
          0) _XSEAT_SEAT="$seat"; rc=0 ;;
          2) _xseat_journal_degraded "$pr" "$sha" "commit status / comment scan unreadable"; rc=1 ;;
          *) rc=1 ;;
        esac
      fi
    fi
  fi
  _XSEAT_MEMO_KEY="$pr $sha"; _XSEAT_MEMO_TS="$now"; _XSEAT_MEMO_SEAT="$_XSEAT_SEAT"; _XSEAT_MEMO_RC="$rc"
  return "$rc"
}

# _xseat_journal_degraded <pr#> <sha> <reason> — one durable line per (pr,sha) when the scan could not
# read the shared artifacts. The gate then behaves exactly as it did before this feature.
_xseat_journal_degraded() {
  _xseat_note_once "degraded:$1:$2" || return 0
  journal_append cross_seat_block_scan pr "$1" sha "$2" state degraded reason "$3"
}

# _xseat_journal_honored <pr#> <sha> <seat> <stage> — one durable line per (pr,sha,stage) recording that
# a foreign BLOCK took precedence over this seat's PASS: `setter` = a blessing withheld, `merge` = a
# merge held. This is the audit trail the #343 incident had no way to leave.
_xseat_journal_honored() {
  _xseat_note_once "honored:$4:$1:$2" || return 0
  journal_append cross_seat_block_honored pr "$1" sha "$2" seat "$3" stage "$4" \
    reason "cross-seat BLOCK standing (seat $3)"
}

# _cross_seat_block_row <slug-cell> <pr-cell> <seat> — the loud console row for a held PR. Factored out
# so the wording is asserted by a test rather than by a human reading the render loop.
_cross_seat_block_row() {
  printf '    %s🛑%s %s%s%s%s %scross-seat BLOCK · needs reconcile (seat %s)%s' \
    "$C_RED" "$C_RESET" "$C_BOLD" "$1" "$C_RESET" "$2" "$C_RED" "$3" "$C_RESET"
}

# _gate_bless_eligible <pr#> <sha> <mergeStateStatus> — true when a MERGEABLE-but-not-CLEAN PR must
# STILL be gated so the watcher can post its herd/gates blessing. This is the fix for the deadlock that
# `require herd/gates` branch protection otherwise creates (HERD-194): a PR whose head sha has no
# herd/gates=success reports mergeStateStatus=BLOCKED — a missing REQUIRED check is NOT CLEAN — so it
# would never become a merge candidate, and the watcher that must post the blessing never runs. We
# therefore treat a BLOCKED PR we have NOT yet blessed for this sha as gate-eligible: run the gates,
# post success, and let GitHub recompute to CLEAN on a later tick — the ACTUAL merge still requires
# CLEAN (re-verified below), so this only unblocks the blessing, never the merge decision. Guards:
#   • GATE_STATUS on (off → no gate-status machinery, so no deadlock to break → return false).
#   • ONLY BLOCKED qualifies — the state a missing/pending required check produces. UNSTABLE (a
#     non-required check failing) and BEHIND (out of date) soft-hold UNCHANGED.
#   • Once we have posted success for this sha the local ledger stops re-gating it, so a PR that stays
#     BLOCKED for SOME OTHER reason (a required human review) is gated AT MOST ONCE per sha, then
#     soft-holds like before — no per-tick re-gate, no wasted review loop.
#   • DRY-RUN inert: a bless-only candidate never merges, so under --dry-run it is not force-added to the
#     candidate set (no real, expensive healthcheck for a row that could never merge anyway).
_gate_bless_eligible() {
  _gate_status_enabled || return 1
  [ -z "${DRYRUN:-}" ] || return 1
  [ "${3:-}" = "BLOCKED" ] || return 1
  [ -n "${2:-}" ] || return 1
  ! _gate_status_posted "$1" "$2" success
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

# stale_dup_held_noted <pr#> <headSha> — true if the stale-dup gate already fired its once-per-sha
# side effects (PR comment + notification + journal) for this exact commit. Guards against re-spamming
# the PR every tick while a held stale/duplicate PR lingers; the console row is still re-rendered live.
stale_dup_held_noted() {
  [ -s "$STALE_DUP_STATE" ] || return 1
  grep -qE "^[0-9]+ $1 $2( |\$)" "$STALE_DUP_STATE" 2>/dev/null
}

# record_stale_dup_held <pr#> <headSha> <kind> — record that the stale-dup hold fired for this pr+sha.
record_stale_dup_held() {
  printf '%s %s %s %s\n' "$(date +%s)" "$1" "$2" "${3:-}" >> "$STALE_DUP_STATE"
}

# ── RE-STALE COUNTER + STARVATION SURFACING (HERD-231) ──────────────────────────────────────────
# A PR starves when merges keep landing faster than its own gates can finish: each landing re-stales
# (or re-conflicts) the very sha a review/suite was grading, the autofix bounces the builder, and the
# next sha races the next merge. PR #328 lost four such laps on 2026-07-09 and PR #347 three; nothing
# in the console or the journal ever said so — each lap looked like a fresh, unrelated hold.
#
# This is DISPLAY + JOURNAL only, and it is ALWAYS ON. It counts laps, it never decides anything: no
# merge, hold, bounce or dispatch reads $RESTALE_STATE. The reorder that actually *fixes* starvation
# ships separately, dormant, behind MERGE_FAIRNESS (see _merge_fairness_reorder).
#
# A lap is counted only when the lost sha carried REAL investment — the whole point is to measure work
# thrown away, not holds. A PR held on its first tick (stale before any gate ran) has lost nothing.

# _gate_work_invested <pr#> <sha> — true iff this watcher has already spent (or is spending) gate work
# on this exact commit: a health verdict cached, a health worker in flight or waiting to be collected,
# a reviewer in flight, or a review verdict on the ledger. All local reads; no network, no git.
_gate_work_invested() {
  local _gwi_pr="$1" _gwi_sha="$2"
  [ -n "$_gwi_pr" ] && [ -n "$_gwi_sha" ] && [ "$_gwi_sha" != "-" ] || return 1
  [ -f "$(_health_result_file "$_gwi_pr" "$_gwi_sha")" ]      && return 0
  [ -f "$(_health_inflight_file "${_gwi_pr}-${_gwi_sha}")" ]  && return 0
  [ -f "$(_health_dispatch_file "${_gwi_pr}-${_gwi_sha}")" ]  && return 0
  [ -f "$(_review_inflight_file "$_gwi_pr" "$_gwi_sha")" ]    && return 0
  review_verdict "$_gwi_pr" "$_gwi_sha" >/dev/null 2>&1       && return 0
  return 1
}

# restale_counted <pr#> <sha> <kind> — true if this exact lap is already on the ledger. The dedup that
# keeps a hold lingering across 20 ticks from inflating the count to 20.
restale_counted() {
  [ -s "$RESTALE_STATE" ] || return 1
  awk -v p="$1" -v s="$2" -v k="$3" '$2==p && $3==s && $4==k{f=1; exit} END{exit !f}' "$RESTALE_STATE" 2>/dev/null
}

# restale_count <pr#> — how many laps this PR has lost, across every sha and kind. Echoes an integer
# (0 when the ledger is absent), so callers can compare it without guarding.
restale_count() {
  [ -s "$RESTALE_STATE" ] || { printf '0'; return 0; }
  awk -v p="$1" '$2==p{n++} END{print n+0}' "$RESTALE_STATE" 2>/dev/null || printf '0'
}

# _restale_note <pr#> <sha> <slug> <kind> — record ONE lost lap, if this sha really lost one. Returns 0
# always (observability must never fail a gate). Journals pr_restale per lap, and pr_starvation on
# every lap at or past the threshold — so the operator, and the future journal-driven self-auditor,
# both see the starvation while it is happening rather than in a post-mortem.
_restale_note() {
  local _rsn_pr="$1" _rsn_sha="$2" _rsn_slug="$3" _rsn_kind="$4" _rsn_n
  [ -n "$_rsn_pr" ] && [ -n "$_rsn_sha" ] || return 0
  # DRY-RUN writes nothing. The conflict classifier runs under --dry-run (the stale-dup gate does not),
  # and a lap recorded there would persist into the next real tick's count.
  [ -z "${DRYRUN:-}" ] || return 0
  _gate_work_invested "$_rsn_pr" "$_rsn_sha" || return 0
  restale_counted "$_rsn_pr" "$_rsn_sha" "$_rsn_kind" && return 0
  printf '%s %s %s %s\n' "$(date +%s)" "$_rsn_pr" "$_rsn_sha" "$_rsn_kind" >> "$RESTALE_STATE"
  _rsn_n="$(restale_count "$_rsn_pr")"
  journal_append pr_restale pr "$_rsn_pr" sha "$_rsn_sha" slug "$_rsn_slug" kind "$_rsn_kind" laps "$_rsn_n"
  if [ "$_rsn_n" -ge "$_RESTALE_STARVE_THRESHOLD" ]; then
    journal_append pr_starvation pr "$_rsn_pr" sha "$_rsn_sha" slug "$_rsn_slug" \
      laps "$_rsn_n" threshold "$_RESTALE_STARVE_THRESHOLD"
  fi
  return 0
}

# _starvation_row <pr#> — the loud continuation line for a starving PR, or NOTHING (empty, rc 0) for a
# PR under the threshold. Rendered under the hold/conflict row the way _health_needs_you_row renders
# its remedy line. Read live from the ledger, so it survives a watcher restart and re-paints each tick.
_starvation_row() {
  local _srw_n; _srw_n="$(restale_count "$1")"
  [ "$_srw_n" -ge "$_RESTALE_STARVE_THRESHOLD" ] || return 0
  printf '%s' "       ${C_RED}└─ starving · ${_srw_n} re-stale laps — merges keep landing before this PR's gates finish${C_RESET}"
}

# _restale_decorate_row <display-idx> <pr#> — append the starvation line to an already-painted row.
# ONE helper at BOTH surfaces that can lose a lap (the stale/duplicate hold and the conflict
# classifier), so the two can never drift into differently-wrong copies (multi-seat doctrine R2).
_restale_decorate_row() {
  local _rdr_line; _rdr_line="$(_starvation_row "$2")"
  [ -n "$_rdr_line" ] || return 0
  DISPLAY[$1]="${DISPLAY[$1]:-}"$'\n'"$_rdr_line"
}

# ── MERGE FAIRNESS: ready-PR priority (HERD-231) ────────────────────────────────────────────────
# The action pass walks candidates in worktree-DISCOVERY order. A PR whose gates are already green for
# its head sha therefore waits behind whatever dispatching the loop does for the PRs ahead of it — and
# the merge that lands from one of those is exactly what re-stales it. Merging the ready one FIRST
# costs nothing and removes it from the race.
#
# SHIP-DORMANT. MERGE_FAIRNESS=off (default) returns before touching the arrays, so the candidate order
# — and every event, dispatch and merge that follows from it — is byte-identical to today.
#
# It NEVER merges anything that has not fully passed: the reorder only permutes the visit order. Every
# gate, the pre-merge re-verify, the unconditional stale-base re-check and the merge-policy decision run
# on a promoted candidate exactly as they do on a demoted one. A wrongly-promoted PR simply gates and
# holds where it stands.

# _merge_fairness_enabled — true iff MERGE_FAIRNESS opts in. Any unrecognized value → off.
_merge_fairness_enabled() {
  case "$(printf '%s' "${MERGE_FAIRNESS:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _health_cached_verdict <pr#> <sha> — echo the TERMINAL health verdict cached for this exact commit
# (CLEAN | FLAKY | CODEERROR), or return 1 when nothing is cached. The read-only companion to
# record_health_result: it must never dispatch, collect, or journal a cache hit.
_health_cached_verdict() {
  local _hcv_f _hcv_v; _hcv_f="$(_health_result_file "$1" "$2")"
  [ -f "$_hcv_f" ] || return 1
  IFS=$'\t' read -r _hcv_v _ < "$_hcv_f" || return 1
  [ -n "$_hcv_v" ] || return 1
  printf '%s' "$_hcv_v"
}

# _cand_gates_ready <pr#> <sha> — true iff BOTH gates are already green for this exact commit, read
# from the ledgers alone (no dispatch, no gh, no git). This is the same pair of facts the action pass
# itself requires before it will merge: a cached CLEAN/FLAKY healthcheck, and a review PASS — or a
# BLOCK a human has overridden for this very sha, which the pass also treats as PASS.
_cand_gates_ready() {
  local _cgr_pr="$1" _cgr_sha="$2" _cgr_v
  [ -n "$_cgr_pr" ] && [ -n "$_cgr_sha" ] || return 1
  case "$(_health_cached_verdict "$_cgr_pr" "$_cgr_sha" 2>/dev/null || true)" in
    CLEAN|FLAKY) : ;;
    *) return 1 ;;
  esac
  _cgr_v="$(review_verdict "$_cgr_pr" "$_cgr_sha" 2>/dev/null || true)"
  [ "$_cgr_v" = "PASS" ] && return 0
  [ "$_cgr_v" = "BLOCK" ] && override_exists "$_cgr_pr" "$_cgr_sha" && return 0
  return 1
}

# _merge_fairness_reorder — stable-partition this tick's candidate arrays so every gates-ready PR is
# visited before every PR that still needs gate work. Mutates CAND_IDX/CAND_DIR/CAND_SLUG/CAND_PR/
# CAND_BRANCH/CAND_SHA in place (they stay index-parallel), and returns 0 always.
#
# STABLE within each partition: ready PRs keep their relative discovery order, and so do the rest. So
# the reorder is a deterministic function of (candidate set, ledger state) — two watchers reading the
# same ledgers produce the same order, and a tick with nothing to promote is a no-op.
#
# Journals merge_fairness_priority ONLY when the order actually changes: a tick where the ready PRs
# already sit first is byte-quiet, exactly as if the knob were off.
_merge_fairness_reorder() {
  _merge_fairness_enabled || return 0
  local _mfr_n=${#CAND_IDX[@]} _mfr_k
  [ "$_mfr_n" -gt 1 ] || return 0

  # HERD-401: deliberately NOT routed through wunit_gate. wunit_gate's contract (work-unit.sh) prints
  # "pass"/"wait" on STDOUT as its status signal — fine for a caller that captures it, but this is a
  # tight per-candidate boolean check inside the tick's own render pass, whose stdout IS the console
  # output stream. Swapping in wunit_gate here would leak a "pass"/"wait" line per candidate into the
  # rendered frame every tick MERGE_FAIRNESS is on — a real behavior change, not a rename. Left calling
  # _cand_gates_ready directly (per the P3 precedent of leaving already-kind-agnostic gate composition
  # in place); noted via herd note rather than silently skipped.
  local _mfr_ready=() _mfr_rest=()
  for ((_mfr_k = 0; _mfr_k < _mfr_n; _mfr_k++)); do
    if _cand_gates_ready "${CAND_PR[_mfr_k]}" "${CAND_SHA[_mfr_k]}"; then
      _mfr_ready+=("$_mfr_k")
    else
      _mfr_rest+=("$_mfr_k")
    fi
  done
  # Nothing to promote, or nothing to promote PAST — the identity permutation either way.
  [ "${#_mfr_ready[@]}" -gt 0 ] && [ "${#_mfr_rest[@]}" -gt 0 ] || return 0
  # Already ready-first (every ready index precedes every other): no reorder, no journal, no noise.
  [ "${_mfr_ready[${#_mfr_ready[@]}-1]}" -gt "${_mfr_rest[0]}" ] || return 0

  local _mfr_i=() _mfr_d=() _mfr_s=() _mfr_p=() _mfr_b=() _mfr_h=() _mfr_prs=""
  for _mfr_k in "${_mfr_ready[@]}" "${_mfr_rest[@]}"; do
    _mfr_i+=("${CAND_IDX[_mfr_k]}"); _mfr_d+=("${CAND_DIR[_mfr_k]}"); _mfr_s+=("${CAND_SLUG[_mfr_k]}")
    _mfr_p+=("${CAND_PR[_mfr_k]}");  _mfr_b+=("${CAND_BRANCH[_mfr_k]}"); _mfr_h+=("${CAND_SHA[_mfr_k]}")
  done
  CAND_IDX=("${_mfr_i[@]}"); CAND_DIR=("${_mfr_d[@]}"); CAND_SLUG=("${_mfr_s[@]}")
  CAND_PR=("${_mfr_p[@]}");  CAND_BRANCH=("${_mfr_b[@]}"); CAND_SHA=("${_mfr_h[@]}")

  # The promoted PRs are, by construction, the first ${#_mfr_ready[@]} entries of the new order.
  for ((_mfr_k = 0; _mfr_k < ${#_mfr_ready[@]}; _mfr_k++)); do
    _mfr_prs="${_mfr_prs:+$_mfr_prs,}${CAND_PR[_mfr_k]}"
  done
  journal_append merge_fairness_priority promoted "${#_mfr_ready[@]}" deferred "${#_mfr_rest[@]}" prs "$_mfr_prs"
  return 0
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

# ── GH CI check-run gate events (HERD-197) ──────────────────────────────────────────────────────
# GROUNDED: PR #293's macOS CI leg failed and NOBODY was notified — the watcher rendered only
# 'blocked · awaiting required checks/reviews (UNSTABLE)' with no which/why, so the operator found the
# failing leg by reading GitHub by hand. mergeStateStatus==UNSTABLE means a REQUIRED status check is
# pending or failing, but it is opaque: it never names the check. These helpers fetch the PR's GH
# check-run results, journal each TERMINAL result as a first-class gate event (`ci_check`) the moment
# it lands, NOTIFY once on a newly-landed failure, and hand the classifier a one-line summary so the
# console row names WHICH check failed instead of the bare UNSTABLE.
#
# CONVENTIONS (match the surrounding gate helpers):
#   • FAIL-SOFT: an offline/old gh, a malformed payload, or a PR with NO checks configured yields NO
#     output and NO side effects, so the row is BYTE-IDENTICAL to before this feature (the grounded
#     no-CI project sees exactly today's behavior).
#   • NEVER A FALSE RED: a check is called `fail` ONLY on a genuine failing conclusion
#     (FAILURE/ERROR/TIMED_OUT/ACTION_REQUIRED/STARTUP_FAILURE). Anything not-yet-terminal — QUEUED,
#     IN_PROGRESS, PENDING, EXPECTED — is `pending` (yellow hold, never red); an UNKNOWN/ambiguous
#     conclusion (incl. CANCELLED/STALE, which block merge but are not a code failure) is treated as
#     `pending` too, so it never paints red.
#   • ONCE-ONLY side effects: journal (pass AND fail) + notify (fail only) fire at most ONCE per
#     pr+sha+conclusion+check via $CI_CHECKS_STATE; the console row is re-derived live every tick.

# _ci_checks_noted <pr> <sha> <conclusion> <check> — true iff this exact terminal check event has
# already fired its once-only journal/notify. The check NAME may contain spaces, so the ledger stores
# one whole line per event and we match it whole (grep -x -F), never a prefix/regex.
_ci_checks_noted() {
  [ -s "$CI_CHECKS_STATE" ] || return 1
  grep -qxF "$1 $2 $3 $4" "$CI_CHECKS_STATE" 2>/dev/null
}

# _ci_record_checked <pr> <sha> <conclusion> <check> — record that this terminal check event's
# once-only side effects have fired. Fail-soft: an unwritable ledger just re-notifies next tick.
_ci_record_checked() {
  printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$CI_CHECKS_STATE" 2>/dev/null || true
}

# purge_pr_ci_checks <pr#> — on merge/reap, drop every CI-check ledger row for this PR (all shas), so
# the ledger cannot grow unbounded as PRs come and go (mirrors purge_pr_approvals). The PR number is
# field 1; an exact whole-field awk compare avoids clobbering a different PR whose number is a
# substring (9 vs 90). Fail-soft — a ledger hiccup must never touch the merge.
purge_pr_ci_checks() {
  local _pr="$1" _tmp
  [ -s "$CI_CHECKS_STATE" ] || return 0
  _tmp="$(mktemp "$CI_CHECKS_STATE.XXXXXX" 2>/dev/null)" || return 0
  if awk -v p="$_pr" '$1 != p' "$CI_CHECKS_STATE" > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$CI_CHECKS_STATE" 2>/dev/null || rm -f "$_tmp"
  else
    rm -f "$_tmp"
  fi
}

# _ci_checks_normalize — read a `gh pr view --json statusCheckRollup` payload on stdin, emit one
# TAB-separated "<bucket>\t<conclusion>\t<check-name>" line per check (bucket ∈ pass|fail|pending).
# Handles BOTH rollup node kinds: CheckRun (GitHub Actions / apps — status+conclusion) and
# StatusContext (classic commit statuses — state). Fail-soft: bad JSON or a non-list rollup emits
# nothing. Uses only python3 stdlib. This is the ONE place the "what counts as a failure" policy lives.
_ci_checks_normalize() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rollup = d.get("statusCheckRollup") if isinstance(d, dict) else None
if not isinstance(rollup, list):
    sys.exit(0)
PASS = {"SUCCESS", "NEUTRAL", "SKIPPED"}
FAIL = {"FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"}
def clean(s):
    return str(s or "").replace("\t", " ").replace("\n", " ").strip()
for c in rollup:
    if not isinstance(c, dict):
        continue
    typ = c.get("__typename", "")
    if typ == "StatusContext" or (not c.get("name") and c.get("context")):
        name = clean(c.get("context"))
        state = str(c.get("state") or "").upper()
        if state in PASS:   bucket, concl = "pass", state
        elif state in FAIL: bucket, concl = "fail", state
        else:               bucket, concl = "pending", (state or "PENDING")
    else:
        name = clean(c.get("name") or c.get("workflowName"))
        status = str(c.get("status") or "").upper()
        concl  = str(c.get("conclusion") or "").upper()
        if status and status != "COMPLETED":
            bucket, concl = "pending", status          # QUEUED / IN_PROGRESS / WAITING / REQUESTED / PENDING
        elif concl in PASS: bucket = "pass"
        elif concl in FAIL: bucket = "fail"
        else:               bucket, concl = "pending", (concl or "PENDING")  # unknown/CANCELLED/STALE → never red
    if not name:
        continue
    sys.stdout.write("%s\t%s\t%s\n" % (bucket, concl, name))
'
}

# _ci_names_summary <label> <name>... — render a compact, length-bounded row fragment naming the
# offending checks: "<label>: a, b" (first 3), appending " +N more" past three. Keeps the console row
# a single tidy line no matter how many legs a big matrix has.
_ci_names_summary() {
  local _label="$1"; shift
  local _n=$# _i=0 _shown="" _nm
  for _nm in "$@"; do
    _i=$((_i + 1)); [ "$_i" -le 3 ] || break
    _shown="${_shown:+$_shown, }$_nm"
  done
  [ "$_n" -gt 3 ] && _shown="$_shown, +$((_n - 3)) more"
  printf '%s: %s' "$_label" "$_shown"
}

# _ci_gate_eval <pr> <sha> <slug> — the entry point the classifier calls for a PR whose
# mergeStateStatus is UNSTABLE (a required check pending or failing). Fetches the PR's check-run
# rollup, JOURNALS every terminal result once (event=ci_check), NOTIFIES once on each newly-landed
# failure, and echoes a single "<bucket>\t<summary>" line for the row (bucket ∈ fail|pending) — or
# NOTHING when there are no checks / gh is unavailable (fail-soft: the caller then keeps the exact
# pre-feature row). Failures dominate the summary (red-worthy); otherwise pending checks are named.
_ci_gate_eval() {
  local _cg_pr="$1" _cg_sha="$2" _cg_slug="$3" _cg_json _cg_norm
  [ -n "$_cg_pr" ] || return 0
  _cg_json="$(_gh_timeout ci_checks pr view "$_cg_pr" --json statusCheckRollup 2>/dev/null)" || return 0
  [ -n "$_cg_json" ] || return 0
  _cg_norm="$(printf '%s' "$_cg_json" | _ci_checks_normalize)"
  [ -n "$_cg_norm" ] || return 0   # no checks configured → byte-identical, no side effects
  local _cg_bucket _cg_concl _cg_name
  local -a _cg_fails=() _cg_pends=()
  while IFS=$'\t' read -r _cg_bucket _cg_concl _cg_name; do
    [ -n "$_cg_bucket" ] || continue
    case "$_cg_bucket" in
      fail)
        _cg_fails+=("$_cg_name")
        if ! _ci_checks_noted "$_cg_pr" "$_cg_sha" "$_cg_concl" "$_cg_name"; then
          _ci_record_checked "$_cg_pr" "$_cg_sha" "$_cg_concl" "$_cg_name"
          journal_append ci_check pr "$_cg_pr" sha "$_cg_sha" slug "$_cg_slug" check "$_cg_name" conclusion "$_cg_concl" result fail
          herd_driver_notify "🚨 CI failed · #${_cg_pr}" "${_cg_name}: ${_cg_concl} — required check failed (${_cg_slug})" default
        fi ;;
      pass)
        if ! _ci_checks_noted "$_cg_pr" "$_cg_sha" "$_cg_concl" "$_cg_name"; then
          _ci_record_checked "$_cg_pr" "$_cg_sha" "$_cg_concl" "$_cg_name"
          journal_append ci_check pr "$_cg_pr" sha "$_cg_sha" slug "$_cg_slug" check "$_cg_name" conclusion "$_cg_concl" result pass
        fi ;;
      pending) _cg_pends+=("$_cg_name") ;;
    esac
  done <<EOF
$_cg_norm
EOF
  if [ "${#_cg_fails[@]}" -gt 0 ]; then
    printf 'fail\t%s' "$(_ci_names_summary "CI failed" "${_cg_fails[@]}")"
  elif [ "${#_cg_pends[@]}" -gt 0 ]; then
    printf 'pending\t%s' "$(_ci_names_summary "awaiting checks" "${_cg_pends[@]}")"
  fi
}

# ── AGING-PR alarm render leg (HERD-334) ─────────────────────────────────────────────────────────
# GROUNDED (2026-07-11: PRs #440/#441 sat 7h with herd/gates PASSED but a required CI suite red — zero
# alarms): the console shows a PR blocked on a required check as a quiet steady state. No TTL covers
# "engine approved it, branch protection blocks it, nothing is progressing". This leg AGES every open PR
# that is MERGEABLE-but-not-CLEAN off OBSERVED state each tick (not off an event a single seat saw): a
# first-seen marker is laid the tick the block is first observed, and once that age crosses AGING_PR_TTL
# AND the sha still carries a herd/gates=success blessing AND a required check is still red/pending, the
# row grows a loud ADVISORY continuation line and a `pr_aging` event is journaled ONCE per (pr,sha). The
# TTL comparison is the ONE shared implementation in aging-pr.sh, so render + journal-audit never drift.
#
# ADVISORY only (never a hold), config-gated (AGING_PR_TTL=0 → byte-inert), fail-soft: if gh cannot read
# the blessing or the check rollup, the leg skips SILENTLY — it never paints a red row on an API hiccup.

# _aging_seen_file <pr> <sha> — the shared FIRST-SEEN marker: the epoch (from _now_epoch, HERD_FAKE_NOW-
# overridable) at which ANY seat first observed this (pr,sha) blocked on a required check. Keyed by
# (pr,sha) and living in $TREES, so a second seat coming online later reads the SAME clock, not its own.
_aging_seen_file()  { printf '%s' "$TREES/.aging-seen-$1-$2"; }
# _aging_noted_file <pr> <sha> — the once-per-threshold-crossing guard for the `pr_aging` journal event
# (mirrors _ci_checks_noted): its presence means this (pr,sha) already journaled its crossing.
_aging_noted_file() { printf '%s' "$TREES/.aging-noted-$1-$2"; }

# purge_pr_aging <pr#> — drop every aging marker for this PR (all shas) on merge/reap, so the markers
# cannot accumulate as PRs come and go (mirrors purge_pr_ci_checks). The trailing '-' in the glob keeps
# PR 9's markers from matching PR 90's. Fail-soft — a marker hiccup must never touch the merge.
purge_pr_aging() { rm -f "$TREES"/.aging-seen-"$1"-* "$TREES"/.aging-noted-"$1"-* 2>/dev/null || true; }

# _aging_decorate_row <display-idx> <pr#> <sha> <slug> <mergeStateStatus> <ci-summary> — the render hook,
# called from the MERGEABLE-but-not-CLEAN branch. Lays/advances the first-seen clock, and once the PR has
# been engine-approved-but-required-check-blocked past AGING_PR_TTL, appends the loud aging line and
# journals `pr_aging` once. <ci-summary> is the UNSTABLE-path "<bucket>\t<text>" already computed by
# _ci_gate_eval (empty on the BLOCKED path); we only spend the extra rollup fetch on a PR that has
# actually AGED, never on every blocked PR every tick. Fully fail-soft; never fails the caller.
_aging_decorate_row() {
  local _ai="$1" _apr="$2" _asha="$3" _aslug="$4" _amstate="$5" _acisum="${6:-}"
  _aging_pr_armed || return 0                              # AGING_PR_TTL=0 → byte-inert
  [ -n "${DRYRUN:-}" ] && return 0
  [ -n "$_apr" ] && [ -n "$_asha" ] || return 0
  # Only BLOCKED / UNSTABLE are the "engine did its part, a required check holds it" states. BEHIND (out
  # of date) is a self-resolving rebase, not a stuck alarm — never age it.
  case "$_amstate" in BLOCKED|UNSTABLE) ;; *) return 0 ;; esac
  local _seen _now _first _age
  _seen="$(_aging_seen_file "$_apr" "$_asha")"
  _now="$(_now_epoch)"
  if [ ! -f "$_seen" ]; then
    printf '%s\n' "$_now" > "$_seen" 2>/dev/null || true    # clock starts on first observation — no row yet
    return 0
  fi
  _first="$(cat "$_seen" 2>/dev/null || printf '%s' "$_now")"
  case "$_first" in ''|*[!0-9]*) _first="$_now" ;; esac
  _age="$(_aging_pr_over_ttl "$_first" "$_now")" || return 0   # still under the TTL → nothing
  # AGED. Confirm the two facts the alarm asserts, from OBSERVED GitHub state, fail-soft (any gh miss →
  # skip silently, never a red row): (1) the sha carries herd/gates=success (engine-approved);
  _gate_status_blessed "$_asha" || return 0
  # (2) a required check is still red/pending, and NAME it. Reuse the UNSTABLE summary if present; else
  # probe the rollup now — bounded to already-aged PRs, so the BLOCKED path costs one fetch only when it
  # matters. _ci_gate_eval is idempotent (its journal/notify are once-guarded), so this never double-fires.
  local _bucket _text
  if [ -n "$_acisum" ]; then
    _bucket="${_acisum%%$'\t'*}"; _text="${_acisum#*$'\t'}"
  else
    _acisum="$(_ci_gate_eval "$_apr" "$_asha" "$_aslug")"
    [ -n "$_acisum" ] || return 0                          # no required check red/pending → not our case
    _bucket="${_acisum%%$'\t'*}"; _text="${_acisum#*$'\t'}"
  fi
  DISPLAY[$_ai]="${DISPLAY[$_ai]:-}"$'\n'"       ${C_RED}└─ aging ${C_BOLD}$(_fmt_age "$_age")${C_RESET}${C_RED} · engine-approved but ${_text} — nothing is merging${C_RESET}"
  # Journal ONCE per (pr,sha) threshold crossing (sha-keyed, no per-tick spam).
  local _noted; _noted="$(_aging_noted_file "$_apr" "$_asha")"
  if [ ! -e "$_noted" ]; then
    : > "$_noted" 2>/dev/null || true
    journal_append pr_aging pr "$_apr" sha "$_asha" slug "$_aslug" check "$_text" \
      age_secs "$_age" threshold "$(_aging_pr_ttl_secs)" result aging
  fi
  return 0
}

# ── Per-PR human-verify hold ──────────────────────────────────────────────────────────────────
# A PR whose body declares a `HUMAN-VERIFY:` block (see human-verify.sh) names manual steps the
# builder could not run itself. Under MERGE_POLICY=auto such a PR is individually switched to an
# approve-style hold: every gate still runs, but the merge WAITS on a sha-keyed approval, REUSING
# the MERGE_POLICY=approve ledger ($APPROVALS) — no parallel ledger. Sibling PRs without the marker
# keep auto-merging. Under approve/observe the hold is redundant (those policies already gate every
# PR), so it is never applied there — avoiding any double-hold.

# _pr_body <pr#> — the PR's body text on stdout, and gh's EXIT STATUS. Isolated so the hermetic tests
# can stub `gh pr view` and so the (potentially large) body is only fetched when the hold is relevant.
#
# THE STATUS IS THE POINT (HERD-237). This used to swallow every failure with `|| true`, so an
# unreadable body was indistinguishable from a PR that simply declares no HUMAN-VERIFY block — and an
# absent block means MERGE. That was survivable while `gh` was unbounded (a slow fetch eventually
# returned the body); the 15 s deadline turns a slow network into a silent auto-merge of a PR whose
# declared manual steps were never run. `human-verify.sh` names this exact bypass. Callers MUST branch
# on the rc: an EMPTY body with rc 0 is "no hold declared"; ANY non-zero rc is "we cannot see", and the
# only safe reading of "we cannot see" in front of a merge is HOLD.
_pr_body() {
  _gh_timeout pr_body pr view "$1" --json body -q '.body' 2>/dev/null
}

# pr_human_verify_held <pr#> — THREE-VALUED, because the honest answer has three cases:
#   0  a NON-EMPTY HUMAN-VERIFY block is declared        → hold
#   1  the body was read and declares no block           → no hold
#   2  the body could NOT be read (gh timeout/failure)   → UNKNOWN; callers must fail CLOSED
# A caller that treats this as a plain boolean gets "no hold" for case 2 — the bypass. The merge gate
# branches on 2 explicitly; the hermetic tests assert both the boolean cases and the tri-state.
pr_human_verify_held() {
  local _phv_body _phv_rc=0
  _phv_body="$(_pr_body "$1")" || _phv_rc=$?
  [ "$_phv_rc" -eq 0 ] || return 2
  printf '%s' "$_phv_body" | human_verify_has
}

# pr_human_verify_steps <pr#> — print the PR's declared HUMAN-VERIFY steps, one per line. Only ever
# reached once pr_human_verify_held has already proven the body readable.
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

# _merge_method_flag / _delete_branch_flag — moved to work-units/git-pr.sh (HERD-398, Phase 3 work-unit
# extraction).

# HERD_RESOLVE_BIN is a test seam mirroring HERD_REVIEW_BIN: the hermetic suite points it at a stub
# resolver so the dispatch → death → respawn → cap loop is driven WITHOUT a real Claude agent.
: "${HERD_RESOLVE_BIN:="$HERE/herd-resolve.sh"}"
# _resolve_result_file <pr#> <sha> — the sha-scoped file the resolver writes its verdict to as its
# LAST act (mirroring $HERD_REVIEW_RESULT_FILE): a line containing ESCALATE (ambiguous → terminal) or
# DONE. Its ABSENCE while the resolver agent is gone is the DEAD-resolver signal that drives a respawn.
_resolve_result_file() { printf '%s' "$TREES/.resolve-result-$1-$2"; }

# _resolve_result <pr#> <sha> — echo the recorded resolver verdict token for this pr+sha (ESCALATE |
# DONE), read from the sha-scoped result file. Returns non-zero (echoes nothing) when no file exists.
_resolve_result() {
  local f; f="$(_resolve_result_file "$1" "$2")"
  [ -f "$f" ] || return 1
  if grep -qi 'ESCALATE' "$f" 2>/dev/null; then printf 'ESCALATE'; else printf 'DONE'; fi
}

# ── Resolver-pane lifecycle (HERD-280) ────────────────────────────────────────────────────────────
# The resolver is a PANE that retires on result-consumed, exactly like a reviewer pane. herd-resolve.sh
# (under RESOLVER_PANE=on) writes ONE row per dispatch naming the pane it created:
#
#     .resolve-registry-<pr>-<sha>       "<pane> <tab> <placement> <pr> <sha>"
#
# placement is `split` (a guest pane in the builder's tab) or `tab` (the standalone resolve·<slug> tab).
# pr + sha are carried IN the row, not parsed back out of the filename: an absent head sha is normalized
# to "-", which would make `<pr>-<sha>` ambiguous to split on the last dash.
_resolve_registry_file() { printf '%s' "$TREES/.resolve-registry-$1-$2"; }

# _resolver_pane_enabled — the RESOLVER_PANE lever (default off, ship-dormant). Delegates to the
# ONE shared resolver in scripts/herd/resolver-pane.sh (_effective_resolver_pane), so this file
# and herd-resolve.sh can never disagree about which values arm the pane-closing path (HERD-286).
_resolver_pane_enabled() {
  [ "$(_effective_resolver_pane)" = "on" ]
}

# _retire_resolver_pane <pr#> <sha> [reason] — close this dispatch's resolver pane and drop its row.
# Mirrors _retire_reviewer_pane: the close is GUARDED (HERD-134) — a stale/recycled pane id that now
# names the BUILDER sharing the tab is REFUSED and journals pane_close_refused, so resolver_pane_retired
# is journaled ONLY on a real close. The row is dropped unconditionally: a row pointing at the wrong pane
# must not linger to be retried. In `tab` placement the (now empty) standalone tab is closed too and its
# sweep-allowlist row pruned, so the retire leaves no corpse for _sweep_stale_resolve_tabs to find.
#
# The WORKTREE is untouched. Retiring the resolver's pane is not retiring the feature: the tree stays
# checked out on the PR's branch and the retirement invariant still reaps it at merge.
#
# FAIL-SOFT + byte-quiet: no registry row (the RESOLVER_PANE=off default writes none), no pane, or an
# already-gone pane ⇒ no console output, no journal line, no herdr call.
_retire_resolver_pane() {
  local pr="$1" sha="$2" reason="${3:-result-consumed}" reg pane tab placement
  # DRY-RUN INERT: _classify_conflict renders under --dry-run, and a render must never close a pane.
  [ -z "${DRYRUN:-}" ] || return 0
  reg="$(_resolve_registry_file "$pr" "$sha")"
  [ -f "$reg" ] || return 0
  read -r pane tab placement _ < "$reg" 2>/dev/null || true
  if [ -n "${pane:-}" ] && [ "$pane" != "-" ] && herd_driver_pane_alive "$pane"; then
    # HERD-418 (review fix): ":resolve" — colon-anchored — matches BOTH the pretty label
    # ("pane:resolve·<slug>") and the sanitized agent name ("agent:resolve-<slug>") without matching
    # an unrelated co-tab slug that merely CONTAINS "resolve" (e.g. "agent:fix-resolve-race").
    if herd_close_pane_verified "$pane" ":resolve"; then
      journal_append resolver_pane_retired pr "$pr" sha "$sha" pane "$pane" \
        placement "${placement:--}" reason "$reason"
      if [ "${placement:-}" = "tab" ] && [ -n "${tab:-}" ] && [ "$tab" != "-" ]; then
        herdr tab close "$tab" >/dev/null 2>&1 || true
        _herd_tabs_drop_row "$TREES/.herd-tabs" "$tab"
      fi
    fi
  fi
  rm -f "$reg" 2>/dev/null || true
}

# _reconcile_resolver_panes — the per-tick RECONCILE that retires finished resolver panes. Multi-seat by
# construction: it decides from the OBSERVED verdict file, never from a dispatch-seat event, so a seat
# that did not spawn the resolver still retires its pane once the verdict lands.
#
#   RESOLVE: DONE      the resolver's job is over → retire the pane immediately.
#   RESOLVE: ESCALATE  the resolver stopped for a HUMAN. KEEP the pane open: its transcript is the
#                      evidence the escalation's needs-you row points at. The row survives too, so no
#                      later tick can retire it out from under the human.
#   (no verdict yet)   in flight → hands off.
#
# This is a SEPARATE observer from the conflict classifier because a SUCCESSFUL resolve is exactly the
# case the classifier never sees: a DONE resolver pushes, the PR flips CLEAN, and _classify_conflict is
# never called for it again. Reconciling the registry against the result file catches both outcomes.
# Idempotent, dry-run-inert, and byte-quiet on a seat with no resolver rows.
_reconcile_resolver_panes() {
  [ -z "${DRYRUN:-}" ] || return 0
  local f pane tab placement pr sha
  for f in "$TREES"/.resolve-registry-*; do
    [ -e "$f" ] || continue
    read -r pane tab placement pr sha < "$f" 2>/dev/null || true
    [ -n "${pr:-}" ] && [ -n "${sha:-}" ] || continue
    case "$(_resolve_result "$pr" "$sha" || true)" in
      DONE) _retire_resolver_pane "$pr" "$sha" result-consumed ;;
      *)    : ;;   # ESCALATE keeps the pane; no verdict keeps the resolver
    esac
  done
}

# ── HEALTHCHECK-AS-A-DISPOSABLE-PANE (HERD-313 leg a, HEALTH_PANE) ─────────────────────────────────
# Leg (b) makes the in-flight suite VISIBLE in the console row. Leg (a) — ship-dormant behind
# HEALTH_PANE — additionally stands up a stamped, disposable `health·<slug>` pane that STREAMS the live
# suite log, so the operator can watch the actual suite output, and RETIRES it the moment the suite
# ends. Modelled exactly on the resolver-pane lifecycle above: the lane-equivalent (the render pass)
# spawns + registers; every tick the watcher reconciles the registry against the OBSERVED inflight
# marker and retires through the SAME HERD-134 guarded close. The pane is a VIEW only — a plain
# `tail -F`, no model, no gate authority — so a bug in this seam can never affect a merge decision.

# _effective_health_pane — echo "on" | "off". Mirrors _effective_resolver_pane's fail-soft contract:
# a recognized on-value arms it; empty/unset/typo reads off, so a bad value can never arm a
# pane-closing path. Ship-dormant default off ⇒ byte-identical when unset.
_effective_health_pane() {
  case "${HEALTH_PANE:-off}" in on|true|yes|1) printf 'on' ;; *) printf 'off' ;; esac
}

# _health_pane_registry_file <pr#> <sha> — the sha-scoped record of the disposable pane this seat stood
# up for a given (pr,sha). One row: "<pane> <tab> health·<slug>". Keyed like the health markers so the
# reconcile stays in lock-step with the inflight marker.
_health_pane_registry_file() { printf '%s' "$TREES/.health-pane-registry-$1-$2"; }

# _spawn_health_pane <pr#> <slug> <sha> <worktree-dir> — stand up the disposable `health·<slug>` view
# pane for an in-flight suite, ONCE. Called from the render pass while a suite is genuinely in flight
# (a live inflight marker), so it rides the same signal leg (b)'s row does — and works identically
# whether the bash gate or the Python engine is running the suite. Self-gating + idempotent + fail-soft:
#   • HEALTH_PANE off / dry-run / headless (no panes) / herdr absent → returns 0 having done NOTHING.
#   • a registry row already present for this (pr,sha) → returns 0 (one pane per suite).
# The pane runs `tail -F` of the sha-scoped health log the worker streams into (leg b's TEE), stamped
# with a `health·<slug>` label so the guarded close recognizes it and a neighbour is never mistaken.
_spawn_health_pane() {
  local _shp_pr="$1" _shp_slug="$2" _shp_sha="$3" _shp_dir="$4"
  [ "$(_effective_health_pane)" = on ] || return 0
  [ -z "${DRYRUN:-}" ] || return 0
  _herd_driver_is_headless && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  local _shp_reg; _shp_reg="$(_health_pane_registry_file "$_shp_pr" "$_shp_sha")"
  [ -f "$_shp_reg" ] && return 0
  local _shp_log _shp_ws _shp_created _shp_tab _shp_root
  _shp_log="$(_health_log_file "${_shp_pr}-${_shp_sha}")"
  _shp_ws="$(herd_resolve_workspace_id 2>/dev/null || true)"
  # shellcheck disable=SC2086  # ${_shp_ws:+…} deliberately word-splits into two argv when set
  _shp_created="$(herdr tab create ${_shp_ws:+--workspace "$_shp_ws"} --cwd "$_shp_dir" --label "health·$_shp_slug" --no-focus 2>/dev/null || true)"
  read -r _shp_tab _shp_root < <(printf '%s' "$_shp_created" | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' 2>/dev/null || true)
  [ -n "${_shp_tab:-}" ] && [ -n "${_shp_root:-}" ] || return 0
  herdr pane rename "$_shp_root" "health·$_shp_slug" >/dev/null 2>&1 || true
  # `tail -F` (retry+follow) tolerates the log not existing yet or being rotated under it.
  herdr pane run "$_shp_root" "tail -n +1 -F $_shp_log" >/dev/null 2>&1 || true
  printf '%s %s health·%s\n' "$_shp_root" "$_shp_tab" "$_shp_slug" > "$_shp_reg" 2>/dev/null || true
  printf '%s %s health\n' "$_shp_slug" "$_shp_tab" >> "$TREES/.herd-tabs" 2>/dev/null || true
  journal_append health_pane_spawned pr "$_shp_pr" slug "$_shp_slug" sha "$_shp_sha" pane "$_shp_root" tab "$_shp_tab" log_path "$_shp_log"
}

# _retire_health_pane <pr#> <sha> [reason] — close the disposable pane once its suite has ended. Mirrors
# _retire_resolver_pane: read the registry row and, if it still names a LIVE pane, close it via the
# HERD-134 guarded close (which REFUSES + journals pane_close_refused if the id was recycled onto a
# neighbour), journal `health_pane_retired` on a real close, close the now-empty tab, then drop the row
# unconditionally. FAIL-SOFT + byte-quiet: no row / no pane / already-gone ⇒ no output, no journal.
_retire_health_pane() {
  local _rhp_pr="$1" _rhp_sha="$2" _rhp_reason="${3:-outcome-landed}" _rhp_reg _rhp_pane _rhp_tab
  [ -z "${DRYRUN:-}" ] || return 0
  _rhp_reg="$(_health_pane_registry_file "$_rhp_pr" "$_rhp_sha")"
  [ -f "$_rhp_reg" ] || return 0
  read -r _rhp_pane _rhp_tab _ < "$_rhp_reg" 2>/dev/null || true
  if [ -n "${_rhp_pane:-}" ] && [ "$_rhp_pane" != "-" ] && herd_driver_pane_alive "$_rhp_pane"; then
    if herd_close_pane_verified "$_rhp_pane" "health·"; then
      journal_append health_pane_retired pr "$_rhp_pr" sha "$_rhp_sha" pane "$_rhp_pane" reason "$_rhp_reason"
      if [ -n "${_rhp_tab:-}" ] && [ "$_rhp_tab" != "-" ]; then
        herdr tab close "$_rhp_tab" >/dev/null 2>&1 || true
        _herd_tabs_drop_row "$TREES/.herd-tabs" "$_rhp_tab"
      fi
    fi
  fi
  rm -f "$_rhp_reg" 2>/dev/null || true
}

# _reconcile_health_panes — retire every disposable health pane whose suite has ENDED, EVERY tick,
# whoever ran (or killed) the suite. Byte-quiet on a seat with no health-pane rows — the overwhelming
# common case, and the whole of the HEALTH_PANE=off default (spawn never wrote a row). A pane is kept
# ONLY while its (pr,sha) inflight marker is still pid-live; the instant the suite finishes, is
# collected, or its worker dies, the marker stops being live and the pane is retired. Dry-run-inert.
_reconcile_health_panes() {
  [ -z "${DRYRUN:-}" ] || return 0
  local _rcp_f _rcp_base _rcp_rest _rcp_pr _rcp_sha _rcp_inf
  for _rcp_f in "$TREES"/.health-pane-registry-*; do
    [ -e "$_rcp_f" ] || continue
    _rcp_base="${_rcp_f##*/}"; _rcp_rest="${_rcp_base#.health-pane-registry-}"
    _rcp_pr="${_rcp_rest%-*}"; _rcp_sha="${_rcp_rest##*-}"
    [ -n "$_rcp_pr" ] && [ -n "$_rcp_sha" ] || continue
    _rcp_inf="$(_health_inflight_file "${_rcp_pr}-${_rcp_sha}")"
    # Still genuinely in flight → keep the pane (the operator is watching the live suite).
    { [ -f "$_rcp_inf" ] && _health_pid_live "$_rcp_inf"; } && continue
    _retire_health_pane "$_rcp_pr" "$_rcp_sha" outcome-landed
  done
}

# ── Resolver liveness: POSITIVE-EVIDENCE-ONLY death (HERD-206) ────────────────────────────────────
# Resolver rows now carry the SAME liveness discipline builders got in PR #260. The pre-HERD-206 rule
# was "absent from $AGENTS_JSON ⇒ dead", which is NEGATIVE evidence and produced a false-dead respawn
# loop: the tick's roster comes from `herd_driver_agent_list_json`, which falls back to `{}` whenever
# `herdr agent list` blips — so one unreadable roster read every resolver as dead, the watcher reaped
# the (live) resolve tab, re-dispatched onto the same worktree, and looped to REFIX_MAX_ROUNDS while
# the real resolver was still merging. A manually-spawned resolver survived because nothing was
# watching it. Three defects, three fixes:
#   • roster identity was matched on `name` ONLY — herdr carries it in EITHER `name` or `agent`
#     (see herd_driver_agent_liveness), so a resolver registered via `pane report-agent` read dead;
#   • an UNREADABLE roster (absent / '{}' / garbage) was indistinguishable from an EMPTY one;
#   • there was no pane-process probe, so a DELISTED-but-running resolver had no way to prove itself.
# Death is now a POSITIVE verdict only: the pane process probe says the session is gone, or a roster
# we could actually READ does not list it. Blindness never kills.

# _roster_readable — true iff $AGENTS_JSON is a PARSEABLE driver roster: a JSON object carrying
# result.agents as a LIST. An EMPTY list is readable (there genuinely are no agents). An absent /
# '{}' / unparseable roster is NOT readable — the watcher is BLIND, and blindness is never evidence
# of death (no-false-red). This is the single guard that turns a `herdr agent list` blip from a
# fleet-wide "every resolver died" into a no-op hold.
_roster_readable() {
  [ -n "${AGENTS_JSON:-}" ] || return 1
  printf '%s' "$AGENTS_JSON" | python3 -c '
import sys, json
try:
  d = json.load(sys.stdin)
except Exception:
  sys.exit(1)
if not isinstance(d, dict): sys.exit(1)
r = d.get("result")
if not isinstance(r, dict): sys.exit(1)
sys.exit(0 if isinstance(r.get("agents"), list) else 1)
' 2>/dev/null
}

# _resolver_roster_listed <slug> — true iff the tick's roster lists a resolve·<slug> agent under
# EITHER identity key. herdr registers an agent's identity as `name` (started via `herdr agent start`)
# or `agent` (reported via `herdr pane report-agent --agent`); the pre-HERD-206 check read only `name`,
# so a resolver registered the second way was invisible and read dead. Matches the exact breadth
# herd_driver_agent_liveness already uses to find a pane. Roster presence at ANY status is a liveness
# signal (mirrors the builder rule): a resolver that finished and went 'done' is listed, not dead.
_resolver_roster_listed() {
  [ -n "${AGENTS_JSON:-}" ] || return 1
  # HERD-418: match the REGISTERED (sanitized) name — herdr never carries the dotted role form.
  printf '%s' "$AGENTS_JSON" | NAME="$(herd_agent_name_sanitize "resolve·$1")" python3 -c '
import sys, json, os
name = os.environ["NAME"]
try:
  agents = (json.load(sys.stdin).get("result") or {}).get("agents") or []
except Exception:
  agents = []
for a in agents:
  if a.get("name") == name or a.get("agent") == name:
    sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

# _resolver_probe <slug> — three-valued pane-process liveness of the resolve·<slug> agent SESSION,
# via the SAME probe the dead-builder reconciliation uses (herd_driver_agent_liveness): alive | dead |
# missing | unknown. It is claude-as-pane-root aware (the lane launches claude AS the pane root, so
# shell_pid == the claude pid; naively excluding the pane shell fabricates a death — PR #260), and it
# fails soft to 'unknown' whenever it cannot see the truth. Never errors under `set -euo pipefail`.
_resolver_probe() {
  command -v herd_driver_agent_liveness >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  herd_driver_agent_liveness "resolve·$1" 2>/dev/null || printf 'unknown'
}

# _resolver_agent_alive <slug> — POSITIVE alive evidence for a resolve·<slug> agent: it is listed in a
# roster we could read, OR its pane is running a live claude process. Returning false NEVER means
# "dead" (it may just mean "we cannot see") — callers that need a death verdict must use
# _resolver_liveness_verdict. Shared by the respawn path (HERD-55) and the stale-tab reaper (HERD-54):
# a resolver that is alive by EITHER signal is never re-dispatched over and never reaped.
_resolver_agent_alive() {
  _resolver_roster_listed "$1" && return 0
  [ "$(_resolver_probe "$1")" = "alive" ]
}

# _resolver_grace_active <slug> <pr#> — true while the most-recent dispatch for this resolver is
# younger than the startup grace. A fresh resolver spends its first seconds unregistered (no roster
# row, no pane process yet), which reads exactly like a corpse; inside this window NO death verdict is
# ever returned. Keyed by PR when the caller has one, else by SLUG (the reaper holds a tab, not a PR).
_resolver_grace_active() {
  local _rga_slug="$1" _rga_pr="${2:-}" _rga_last _rga_age
  if [ -n "$_rga_pr" ]; then _rga_last="$(resolver_last_dispatch_epoch "$_rga_pr")"
  else                       _rga_last="$(resolver_last_dispatch_epoch_slug "$_rga_slug")"
  fi
  [ -n "$_rga_last" ] || return 1
  _rga_age=$(( $(date +%s) - _rga_last ))
  [ "$_rga_age" -lt "${_RESOLVER_DEAD_GRACE:-90}" ]
}

# _resolver_liveness_verdict <slug> [pr#] — the ONE death oracle for a resolve·<slug> agent. Echoes
# exactly one token, in strict evidence order:
#   ALIVE    — POSITIVE liveness: roster-listed (any status), or the pane runs a live claude
#   STARTING — inside the startup grace since the last dispatch; a resolver that has not registered
#              yet is NEVER dead. Checked BEFORE any death evidence, so a not-yet-spawned pane can
#              not be read as 'missing' and reaped inside the grace.
#   DEAD     — POSITIVE death: the probe says the pane exists but runs no claude ('dead'), or the
#              agent pane is positively GONE ('missing'); OR the probe is blind but a READABLE roster
#              does not list the resolver (the headless / no-pane driver's positive absence).
#   UNKNOWN  — probe blind AND roster unreadable ⇒ we cannot see. HOLD. Never a respawn, never a reap.
# Only DEAD authorizes a respawn or a tab close. Callers must treat every other token as "hands off".
_resolver_liveness_verdict() {
  local _rlv_slug="$1" _rlv_pr="${2:-}" _rlv_probe
  _resolver_roster_listed "$_rlv_slug" && { printf 'ALIVE'; return 0; }
  _rlv_probe="$(_resolver_probe "$_rlv_slug")"
  [ "$_rlv_probe" = "alive" ] && { printf 'ALIVE'; return 0; }
  # A live lane worker for this slug is STARTING evidence that does not expire (HERD-237). It must be
  # checked with the grace, above every death branch: a lane queued behind the lane lock outlives the
  # 90 s dispatch grace by design, and calling that DEAD re-dispatches a resolver that never started.
  _resolver_lane_starting "$_rlv_slug" && { printf 'STARTING'; return 0; }
  _resolver_grace_active "$_rlv_slug" "$_rlv_pr" && { printf 'STARTING'; return 0; }
  case "$_rlv_probe" in
    dead|missing) printf 'DEAD'; return 0 ;;
  esac
  _roster_readable && { printf 'DEAD'; return 0; }
  printf 'UNKNOWN'
}

# _resolver_agent_status <slug> — agent_status word for resolve·<slug> from the tick's $AGENTS_JSON
# roster (empty when absent/unreadable). Identity match tolerates either `name` or `agent` (same
# breadth as _resolver_roster_listed). Reads the tick snapshot, never a live herdr call — hermetic
# under test and consistent with every other resolver oracle on this path.
_resolver_agent_status() {
  [ -n "${AGENTS_JSON:-}" ] || { printf ''; return 0; }
  # HERD-418: match the REGISTERED (sanitized) name — herdr never carries the dotted role form.
  printf '%s' "$AGENTS_JSON" | NAME="$(herd_agent_name_sanitize "resolve·$1")" python3 -c '
import sys, json, os
name = os.environ["NAME"]
try:
  agents = (json.load(sys.stdin).get("result") or {}).get("agents") or []
except Exception:
  agents = []
for a in agents:
  if a.get("name") == name or a.get("agent") == name:
    print(a.get("agent_status", "") or "", end="")
    raise SystemExit(0)
' 2>/dev/null || true
}

# _resolver_round_finished <pr#> [sha] — true iff the resolver wrote its terminal verdict (DONE |
# ESCALATE) for the sha ACTUALLY IN FLIGHT. A resolver round is identified by pr+sha, never by pr
# alone: verdict files are sha-scoped (_resolve_result_file) and are cleaned only at PR RETIREMENT,
# so a PR-wide glob would match round 1's leftover verdict forever and report every later round as
# "finished" — silently disabling the caller's park guard from the second conflict round onward.
#
# When the caller has no sha, fall back to the most-recently DISPATCHED sha for this PR; with no sha
# at all the answer is "not finished" (the conservative side — the caller then consults park state).
_resolver_round_finished() {
  local _rrf_pr="${1:-}" _rrf_sha="${2:-}"
  [ -n "$_rrf_pr" ] || return 1
  [ -n "$_rrf_sha" ] || _rrf_sha="$(resolver_last_sha "$_rrf_pr" 2>/dev/null || true)"
  [ -n "$_rrf_sha" ] || return 1
  _resolve_result "$_rrf_pr" "$_rrf_sha" >/dev/null 2>&1
}

# _resolver_limit_parked <slug> — true iff the resolve·<slug> session is parked on the ACCOUNT USAGE
# LIMIT, awaiting auto-resume. Reads the SAME park state the builder refix paths read — the
# .herd-limit-sentinel the rate_limit hook writes into the worktree (via _detect_limit_hit, which also
# carries the banner-scrape fallback), plus the park handler's own ledger (limit_state = scheduled).
# The resolver runs IN the feature worktree (herd-resolve.sh resolves in place), so its sentinel and
# ledger row live exactly where the builder's do. No new state, no new config key.
#
# THE SENTINEL IS SHARED with the builder that owns this worktree, so a sentinel that PREDATES this
# resolver's dispatch is someone else's park — most often a builder park whose clear_limit ran without
# the worktree arg and left the file behind. Treating that as a resolver park would hold the dispatch
# slot forever, stranding re-dispatch rather than deferring it. So sentinel evidence must POSTDATE the
# last dispatch for this slug. A sentinel written after we dispatched can only be this resolver's.
#
# Fail-soft to PARKED whenever the read itself is doubtful: an unreadable mtime, or an empty/garbled
# sentinel, still means a limit hit was recorded. A held slot re-dispatches on a later tick; a reaped
# session is gone for good. HERD_LIMIT_DETECT=off disables the guard with the rest of limit detection.
_resolver_limit_parked() {
  local _rlp_slug="$1" _rlp_wt _rlp_sent _rlp_since=0 _rlp_mt
  [ "${HERD_LIMIT_DETECT:-on}" != "off" ] || return 1
  # The park handler's ledger: slug-scoped, and clear_limit always drops the row on resume.
  if [ -n "${LIMIT_STATE:-}" ] && [ "$(limit_state "$_rlp_slug" 2>/dev/null || printf '')" = "scheduled" ]; then
    return 0
  fi
  _rlp_wt="${WORKTREES_DIR:-${TREES:-.}}/$_rlp_slug"
  _rlp_sent="$(_limit_sentinel_file "$_rlp_wt")"
  if [ -f "$_rlp_sent" ]; then
    [ -n "${RESOLVE_STATE:-}" ] && _rlp_since="$(resolver_last_dispatch_epoch_slug "$_rlp_slug" 2>/dev/null || printf 0)"
    [ -n "$_rlp_since" ] || _rlp_since=0
    _rlp_mt="$(file_mtime "$_rlp_sent" 2>/dev/null || printf '')"
    case "$_rlp_mt" in
      ''|*[!0-9]*) return 0 ;;                       # unreadable mtime → fail soft to PARKED
    esac
    [ "$_rlp_mt" -ge "$_rlp_since" ] && return 0     # written since we dispatched → OUR park
    return 1                                         # predates the dispatch → a stale foreign sentinel
  fi
  # No sentinel: the hookless banner-scrape fallback (already banner-shape guarded). It reads the
  # NEWEST transcript under the worktree, and this guard only runs while the resolver is ALIVE — so
  # the newest session is the resolver's own, not the builder's.
  _detect_limit_hit "$_rlp_slug" "$_rlp_wt" >/dev/null 2>&1
}

# _resolver_in_flight <slug> <pr#> [sha] — true if a resolver for this slug is ACTIVELY RESOLVING (or may
# still be starting / invisible), so a (re)dispatch must HOLD: a second resolver on the same worktree
# would race the first on `git merge`/`git push`. This is the SINGLE guard that prevents a
# double-dispatch.
#
# HERD-206: ALIVE / STARTING / UNKNOWN all hold; only DEAD frees the slot — never spawn over something
# we cannot positively prove is free (a blipped roster is not death).
#
# HERD-225: an IDLE/DONE-but-ALIVE resolver has FINISHED its round (pushed or escalated) yet the
# agent pane stays up. Holding forever on mere ALIVE left NEW conflicts stranded — the watcher could
# neither re-dispatch (guard held) nor rely on the idle agent (it is not working). So ALIVE +
# agent_status idle|done frees the slot (past the startup grace — a fresh agent can blip idle before
# picking up its task). The spawn path reaps the idle agent so the name can be reclaimed. WORKING
# still holds; STARTING / UNKNOWN still hold.
#
# HERD-246: a USAGE-LIMIT-PARKED Claude session reports agent_status idle|done — indistinguishable
# from a finished round, and a park legitimately outlasts any startup grace. Freeing the slot there
# hands the pane to _reap_idle_resolver_for_redispatch, which kills the session and defeats
# limit-park auto-resume (the engine's core capability). So idle|done past the grace ALSO consults
# the park state: PARKED with no terminal verdict for the sha IN FLIGHT ⇒ HOLD, exactly as pre-HERD-225
# (the resume scheduler owns that session). No park state, or a verdict already written for THIS sha
# ⇒ free + reap, as HERD-225 intends. When nothing is parked this is byte-identical to HERD-225.
#
# <sha> is the sha whose resolver round is in question. Pass it: a resolver round is pr+sha, and the
# PR-wide question ("has ANY round of this PR ever finished?") is true forever after round 1, which
# would short-circuit the park guard away on every later conflict round. Callers all hold it.
_resolver_in_flight() {
  local _rif_slug="$1" _rif_pr="${2:-}" _rif_sha="${3:-}" _rif_v _rif_st
  _rif_v="$(_resolver_liveness_verdict "$_rif_slug" "$_rif_pr")"
  [ "$_rif_v" = "DEAD" ] && return 1
  if [ "$_rif_v" = "ALIVE" ]; then
    _rif_st="$(_resolver_agent_status "$_rif_slug")"
    case "$_rif_st" in
      idle|done)
        # Finished its round — free for re-dispatch. Still hold inside the startup grace so a
        # just-spawned agent that blips idle cannot be double-dispatched over — and while THIS slug's
        # lane worker is still running (HERD-237: a re-dispatch would race the lane that is about to
        # (re)start this very agent, and `herd-resolve.sh` would fail with 'agent name already used').
        _resolver_lane_starting "$_rif_slug" && return 0
        _resolver_grace_active "$_rif_slug" "$_rif_pr" && return 0
        # …unless this "idle" is a usage-limit park awaiting auto-resume (HERD-246).
        if ! _resolver_round_finished "$_rif_pr" "$_rif_sha" && _resolver_limit_parked "$_rif_slug"; then
          return 0
        fi
        return 1
        ;;
    esac
  fi
  return 0
}

# _reap_idle_resolver_for_redispatch <slug> — HERD-225: before a (re)spawn, close any IDLE/DONE-but-
# alive resolve·<slug> tab so herd-resolve.sh can claim the agent name. Without this, re-dispatch
# fails with "agent name already used" (confirmed live on PR #328). WORKING resolvers are never
# touched (the in-flight guard holds them). Fail-soft: missing tab / missing herdr / dry-run → no-op.
_reap_idle_resolver_for_redispatch() {
  local _rir_slug="$1" _rir_status _rir_reg _rir_tab _rir_adir _rir_pid
  _rir_status="$(_resolver_agent_status "$_rir_slug")"
  case "$_rir_status" in
    idle|done) ;;
    *) return 0 ;;
  esac
  [ -z "${DRYRUN:-}" ] || return 0
  _rir_reg="${TREES:-${WORKTREES_DIR:-.}}/.herd-tabs"
  if [ -f "$_rir_reg" ]; then
    _rir_tab="$(awk -v s="resolve·${_rir_slug}" '$1==s {print $2; exit}' "$_rir_reg" 2>/dev/null || true)"
    if [ -n "$_rir_tab" ]; then
      herdr tab close "$_rir_tab" >/dev/null 2>&1 || true
      journal_append reap_resolve_tab tab_id "$_rir_tab" slug "$_rir_slug" reason idle-redispatch
      _herd_tabs_drop_row "$_rir_reg" "$_rir_tab"
    fi
  fi
  # HERD-280: a SPLIT-placed resolver owns no tab row — the tab is the builder's. Its idle pane still
  # holds the resolve·<slug> agent name, so free it the same way, by a GUARDED close that refuses any
  # pane no longer carrying the resolver's identity (never the builder sharing the tab). Only reached
  # under RESOLVER_PANE=on, so the pre-HERD-280 lane makes no extra driver call.
  if _resolver_pane_enabled && [ -z "${_rir_tab:-}" ]; then
    local _rir_pane; _rir_pane="$(herd_driver_agent_pane_id "resolve·${_rir_slug}" 2>/dev/null || true)"
    # HERD-418 (review fix): ":resolve" — colon-anchored — matches both the pretty label and the
    # sanitized agent name without matching an unrelated co-tab slug that merely contains "resolve".
    if [ -n "$_rir_pane" ] && herd_close_pane_verified "$_rir_pane" ":resolve"; then
      journal_append resolver_pane_retired slug "$_rir_slug" pane "$_rir_pane" \
        placement split reason idle-redispatch
    fi
  fi
  # Headless registry: free the slot so the next launch owns a clean pid/status file (herdr tab
  # close is a no-op under HERD_DRIVER=headless). Best-effort kill of a still-live detached pid.
  _rir_adir="${WORKTREES_DIR:-${TREES:-.}}/.herd/agents/resolve·${_rir_slug}"
  if [ -d "$_rir_adir" ]; then
    _rir_pid="$(cat "$_rir_adir/pid" 2>/dev/null || true)"
    if [ -n "$_rir_pid" ] && kill -0 "$_rir_pid" 2>/dev/null; then
      kill "$_rir_pid" 2>/dev/null || true
    fi
    rm -rf "$_rir_adir" 2>/dev/null || true
  fi
  return 0
}

# spawn_resolver <slug> <pr#> <branch> <sha> — hand a CONFLICTING PR to the isolated resolver, keyed
# to <sha>. Record-first keeps the respawn budget sound; the spawn is best-effort. The resolver is
# told (via $HERD_RESOLVE_RESULT_FILE) to write its terminal verdict to the sha-scoped result file.
#
# SPAWN-ACK (HERD-206): the lane's exit status is the resolver's spawn acknowledgement — herd-resolve.sh
# exits non-zero when the worktree is gone, when herdr cannot create the tab, or when the agent fails to
# start (it closes the empty tab itself). Before HERD-206 that rc was discarded, so a dispatch that never
# produced an agent still burned a respawn round and looked identical to a live resolver for the whole
# grace window. Now every dispatch journals a `resolver_spawn` event carrying rc + whether the agent was
# actually observed alive afterwards, so a spawn that never ACKed is auditable rather than inferred from
# a silence. Behavior is unchanged (still best-effort, still never fails a tick): the record already
# landed, the grace still runs, and the next tick's POSITIVE-death verdict re-dispatches within budget.
#
# IDLE-REDISPATCH (HERD-225): when the prior resolve·<slug> agent is still ALIVE but idle/done, reap
# it first so the lane can reclaim the agent name (otherwise herdr refuses with "agent name already
# used" and the new conflict sits forever).
#
# BACKGROUNDED (HERD-237): the lane + its ACK probe + its journal run in a background subshell — the
# whole tail, unsplit, so the ACK is still OBSERVED from the lane's real exit status and the driver's
# post-spawn roster. Only the tick that carries those events can differ. The two things that MUST be
# on the tick are: the self-restart refusal (its non-zero rc is the caller's "no resolver is running"
# signal) and record_resolve_attempt (record-first keeps the respawn budget sound even if the watcher
# dies mid-spawn) — both stay foreground, in order, above the fork. A same-slug re-dispatch on the
# NEXT tick is prevented exactly as before: the ledger row is already written, so _resolver_in_flight
# reads STARTING for the whole _RESOLVER_DEAD_GRACE window that this very race motivated.
spawn_resolver() {
  rs="$1"; rp="$2"; rb="$3"; rsha="${4:-}"
  # SELF-RESTART QUIESCE (HERD-251): defence in depth. Both callers hold ABOVE their own ledger writes
  # (the resolve pass at its row, _handle_stale_dup above record_refix), so this is unreachable
  # today. It returns NON-ZERO — never 0 — because `_resolver_in_flight … || spawn_resolver …` reads a
  # zero rc as "a resolver is now running": a refusal that returned 0 would paint `rebasing · awaiting
  # push` over nothing. Refused before record_resolve_attempt, so no respawn round is burned either.
  # Byte-inert with the lever off.
  _self_restart_hold_dispatch && return 1
  record_resolve_attempt "$rp" "$rs" "$rb" "$rsha"
  # pr + sha keep the marker legible; the monotonic sequence makes it UNIQUE. An epoch alone would
  # alias two dispatches of the same pr+sha inside one second — unreachable today (the
  # _resolver_in_flight guard closes it) but exactly the aliasing hazard this name exists to avoid.
  # HERD-286: the same key forms the DISPATCH-ID — a stable, unique token for journal correlation
  # that ties resolver_spawn events and herd-resolve.sh's own journal events to the same dispatch.
  _SPAWN_DISPATCH_SEQ=$(( ${_SPAWN_DISPATCH_SEQ-0} + 1 ))
  local _sr_dispatch_id="${rp}-${rsha:--}-${_SPAWN_DISPATCH_SEQ}"
  local _sr_marker; _sr_marker="$(_spawn_inflight_file resolve "$rs" "$_sr_dispatch_id")"
  _spawn_inflight_bg "$_sr_marker" _spawn_resolver_lane "$rs" "$rp" "$rsha" "$_sr_marker" "$_sr_dispatch_id"
  return 0
}

# _spawn_resolver_wait — block until no resolver lane is in flight, then return. The TICK never calls
# this (not waiting is the entire point); it is the synchronization seam the hermetic tests and sims
# use to assert on a dispatch they just made, instead of sleeping and hoping.
#
# Keyed on the MARKER, not on a remembered pid. A pid handle is wrong in two directions: a REFUSED
# dispatch (quiesce hold, serialization hold) would either strand the handle of a still-running lane or
# leave a caller waiting on a lane this call never started. The marker is the truth — and because
# _spawn_inflight_bg removes it only AFTER the worker's body returns, a cleared marker also means the
# lane's journal lines are already on disk. Bounded (60 s) so a wedged lane can never hang a suite.
_spawn_resolver_wait() {
  local _srw_n=0
  while _resolver_lane_inflight && [ "$_srw_n" -lt 600 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    _srw_n=$(( _srw_n + 1 ))
  done
  return 0
}

# ── Resolver lane serialization (HERD-237) ───────────────────────────────────────────────────────
# Every resolver lane runs `git worktree add` against the SAME $MAIN. The foreground spawn_resolver
# serialized them implicitly: the resolve pass dispatched all of a tick's conflicts, one after another.
# Backgrounding the lane keeps every dispatch — the ledger rows, the ACK events, the respawn budget are
# all unchanged — but the lanes would now overlap. So the serialization moves INTO the lane: a dispatch
# is never refused, it just queues behind whichever lane is already running. The tick waits for none of
# it.
#
# It must be a LOCK, not a dispatch-time guard. A guard that refuses `spawn_resolver` is a safety-rail
# bypass: `_handle_stale_dup` and `_handle_ci_repair` call it AFTER burning `record_refix` (a
# record-first once-guard) and journaling the heal — so a refusal there strands the sha behind a spent
# guard that no later tick can retry, leaving a durable "needs you" row for a heal the watcher itself
# declined. Two of their call sites (pane vanished mid-bounce) burn that guard several branches
# upstream and CANNOT hoist a check above it. Refusing a dispatch is therefore never safe here, at any
# depth. Queuing one always is.
#
# Fail-soft in the strongest sense: if the lock cannot be taken within the budget, the lane runs ANYWAY
# (journaled). Losing serialization degrades to the concurrency we would have had with no lock at all;
# dropping the dispatch would lose the heal.
RESOLVE_LANE_LOCK="$TREES/.spawn-resolve-lane.lock"   # a lock DIRECTORY (mkdir is atomic everywhere)
_RESOLVE_LANE_LOCK_STALE=600     # seconds before an UNATTRIBUTABLE held lock is presumed abandoned

# The lock records its HOLDER: the path of that lane's own inflight marker, which carries the worker's
# pid + start-time. That makes both dangerous operations decidable rather than guessed:
#   • BREAKING a held lock asks "is the holder still alive?" (_marker_live), not "is it old?". An age
#     rule alone breaks the lock out from under a lane that is legitimately slow.
#   • RELEASING asks "is the lock still MINE?". An unconditional `rm -rf` lets a lane whose lock was
#     broken delete its SUCCESSOR's lock on the way out, so one overlap cascades into many.
# Both mutate the lock by ATOMIC RENAME (only one racer can win a rename), never by a bare rm -rf.
# The age rule survives only as the last-resort escape for a lock whose holder we cannot attribute at
# all (a torn write, an older engine's lock dir): a wedge is worse than an overlap.

# _resolve_lane_lock_scrap <token> — atomically take the lock dir out of the way and delete it.
# Returns 0 only for the racer that actually won the rename, so no two lanes can both "break" it.
# <token> only has to make the temp path private to this racer; each lane passes its own marker path,
# which is unique per dispatch ($$ is not: a `( … ) &` subshell inherits the watcher's pid).
_resolve_lane_lock_scrap() {
  local _rls_tmp="$RESOLVE_LANE_LOCK.scrap.$(_spawn_slug_key "$(basename -- "${1:-x}")")"
  rm -rf "$_rls_tmp" 2>/dev/null || true
  mv "$RESOLVE_LANE_LOCK" "$_rls_tmp" 2>/dev/null || return 1
  rm -rf "$_rls_tmp" 2>/dev/null || true
  return 0
}

# _resolve_lane_lock_acquire <holder-marker> — take the lane lock, or return 1 after the wait budget.
# HERD_RESOLVE_LANE_LOCK_WAIT is a test seam, not a config key.
_resolve_lane_lock_acquire() {
  local _rll_holder="$1" _rll_waited=0 _rll_max="${HERD_RESOLVE_LANE_LOCK_WAIT:-900}"
  local _rll_cur _rll_ts _rll_now
  case "$_rll_max" in ''|*[!0-9]*) _rll_max=900 ;; esac
  while :; do
    if mkdir "$RESOLVE_LANE_LOCK" 2>/dev/null; then
      printf '%s\n' "$_rll_holder"    > "$RESOLVE_LANE_LOCK/holder" 2>/dev/null || true
      printf '%s\n' "$(_now_epoch)"   > "$RESOLVE_LANE_LOCK/ts"     2>/dev/null || true
      return 0
    fi
    _rll_cur="$(cat "$RESOLVE_LANE_LOCK/holder" 2>/dev/null || true)"
    if [ -n "$_rll_cur" ]; then
      # Attributable holder: break iff it is provably gone (dead pid, or a recycled one).
      if ! _marker_live "$_rll_cur" 2>/dev/null; then
        if _resolve_lane_lock_scrap "$_rll_holder"; then
          journal_append resolver_lane_lock_broken reason holder-dead holder "$_rll_cur"
        fi
        continue
      fi
    else
      # Unattributable holder — fall back to the age rule so a torn lock cannot wedge dispatch forever.
      _rll_ts="$(cat "$RESOLVE_LANE_LOCK/ts" 2>/dev/null || true)"
      _rll_now="$(_now_epoch)"
      case "$_rll_ts" in ''|*[!0-9]*) _rll_ts=0 ;; esac
      if [ "$_rll_ts" -gt 0 ] && [ "$(( _rll_now - _rll_ts ))" -gt "$_RESOLVE_LANE_LOCK_STALE" ]; then
        if _resolve_lane_lock_scrap "$_rll_holder"; then
          journal_append resolver_lane_lock_broken reason stale-unattributed age "$(( _rll_now - _rll_ts ))"
        fi
        continue
      fi
    fi
    [ "$_rll_waited" -ge "$_rll_max" ] && return 1
    sleep 1 2>/dev/null || return 1
    _rll_waited=$(( _rll_waited + 1 ))
  done
}

# _resolve_lane_lock_release <holder-marker> — drop the lock ONLY if this lane still holds it. A lane
# whose lock was broken (it overran the stale window) must not delete its SUCCESSOR's lock. Reading the
# holder and then deleting would race, so we take the dir out of the way by atomic rename FIRST, read
# the holder from the now-private copy, and put it back untouched if it was never ours.
_resolve_lane_lock_release() {
  local _rlr_want="$1" _rlr_got
  local _rlr_tmp="$RESOLVE_LANE_LOCK.rel.$(_spawn_slug_key "$(basename -- "$1")")"
  [ -d "$RESOLVE_LANE_LOCK" ] || return 0
  rm -rf "$_rlr_tmp" 2>/dev/null || true
  mv "$RESOLVE_LANE_LOCK" "$_rlr_tmp" 2>/dev/null || return 0   # lost the rename ⇒ not ours to drop
  _rlr_got="$(cat "$_rlr_tmp/holder" 2>/dev/null || true)"
  if [ "$_rlr_got" = "$_rlr_want" ]; then
    rm -rf "$_rlr_tmp" 2>/dev/null || true
    return 0
  fi
  # Our lock was broken and re-taken while we ran. Restore the current holder's lock verbatim; if a
  # third lane has already mkdir'd one in the gap, drop our copy rather than clobber theirs.
  mv "$_rlr_tmp" "$RESOLVE_LANE_LOCK" 2>/dev/null || rm -rf "$_rlr_tmp" 2>/dev/null || true
  return 0
}

# _spawn_resolver_lane <slug> <pr#> <sha> <marker> — the backgrounded body of spawn_resolver: launch
# the lane, observe the ACK, journal. The pre-HERD-237 foreground tail verbatim, wrapped in the lane
# lock. <marker> is this worker's own inflight marker: it identifies the lock's holder, and while it is
# live `_resolver_lane_starting` keeps this slug out of every death verdict.
_spawn_resolver_lane() {
  local rs="$1" rp="$2" rsha="$3" _sr_marker="$4"
  # HERD-286: dispatch-id for attribution/journal correlation. Passed by spawn_resolver from the
  # same key that names the inflight marker; defaults so a direct call (tests/sims) works without it.
  local _sr_dispatch_id="${5:-${rp}-${rsha:--}}"
  local _sr_rc=0 _sr_ack _sr_roster _sr_locked=""
  if _resolve_lane_lock_acquire "$_sr_marker"; then
    _sr_locked=1
  else
    journal_append resolver_lane_lock_timeout pr "$rp" slug "$rs" \
      detail "proceeding unserialized — a dropped dispatch would strand the conflict"
  fi
  _reap_idle_resolver_for_redispatch "$rs"
  # HERD-280: the registry seam is handed over ONLY when the resolver-pane lever is on, so the default
  # lane writes no row and the whole retire path stays byte-inert. pr + sha ride along so herd-resolve.sh
  # can stamp them into the row it writes (the watcher's reconcile reads them back from there).
  # A dispatch with no sha at all keys no registry row (its verdict file is unaddressable too) — it
  # falls through to the plain lane rather than writing a row the reconcile could never join back.
  # HERD-286: HERD_RESOLVE_DISPATCH_ID is passed in BOTH branches so herd-resolve.sh can stamp the
  # dispatch-id into its own journal events regardless of the pane-lever state.
  if _resolver_pane_enabled && [ -n "$rsha" ]; then
    HERD_RESOLVE_RESULT_FILE="$(_resolve_result_file "$rp" "$rsha")" \
    HERD_RESOLVE_REGISTRY_FILE="$(_resolve_registry_file "$rp" "$rsha")" \
    HERD_RESOLVE_PR="$rp" HERD_RESOLVE_SHA="$rsha" \
    HERD_RESOLVE_DISPATCH_ID="$_sr_dispatch_id" \
      bash "$HERD_RESOLVE_BIN" "$rs" >/dev/null 2>&1 || _sr_rc=$?
  else
    HERD_RESOLVE_RESULT_FILE="$(_resolve_result_file "$rp" "$rsha")" \
    HERD_RESOLVE_DISPATCH_ID="$_sr_dispatch_id" \
      bash "$HERD_RESOLVE_BIN" "$rs" >/dev/null 2>&1 || _sr_rc=$?
  fi
  [ -n "$_sr_locked" ] && _resolve_lane_lock_release "$_sr_marker"
  # ACK probe: re-read the roster from the DRIVER (the tick's $AGENTS_JSON snapshot predates this
  # spawn and can never show it) and fall back to the pane probe, so 'acked' is observed, not assumed.
  _sr_roster="$(herd_driver_agent_list_json 2>/dev/null || printf '{}')"
  _sr_ack="no"
  if ( AGENTS_JSON="$_sr_roster"; _resolver_roster_listed "$rs" ) || [ "$(_resolver_probe "$rs")" = "alive" ]; then
    _sr_ack="yes"
  fi
  # HERD-286: include dispatch_id in the ACK journal event for attribution/correlation.
  journal_append resolver_spawn pr "$rp" slug "$rs" sha "${rsha:--}" rc "$_sr_rc" acked "$_sr_ack" \
    dispatch_id "$_sr_dispatch_id"
  [ "$_sr_rc" -eq 0 ] || journal_append resolver_spawn_failed pr "$rp" slug "$rs" sha "${rsha:--}" \
    rc "$_sr_rc" dispatch_id "$_sr_dispatch_id"
  return 0
}

# Grace window (seconds) before a resolver whose agent is not yet visible is even ELIGIBLE for a death
# verdict (it reads STARTING instead). Prevents a double-dispatch race — and a reap — when a freshly
# spawned resolver has not yet registered its pid. Overridable so the sim can zero it out.
: "${_RESOLVER_DEAD_GRACE:=90}"

# _classify_conflict <idx> <pr#> <slug> <branch> <headsha> — decide what to do with a CONFLICTING PR
# (HERD-55). Sha-keyed like the review-once gate: first conflict → auto-spawn the resolver; a NEW
# commit that reshapes the conflict, or a resolver that DIED without clearing it, → RE-spawn for the
# new sha; an ESCALATE verdict is TERMINAL for that sha; respawns are capped at REFIX_MAX_ROUNDS then
# surface needs-you. Sets DISPLAY[idx]; queues a (re)spawn by appending to the CONF_* arrays with the
# sha + reason. Never spawns here — the resolve pass does that so it stays render-ordered + dry-runnable.
_classify_conflict() {
  local ci="$1" cpr="$2" cslug="$3" cbranch="$4" csha="$5"
  local sl pn cap count
  # Normalize an absent head sha to "-" so it keys consistently across the ledger + result file.
  [ -n "$csha" ] || csha="-"
  sl="$(_slug_cell "$cslug")"; pn=" ${C_DIM}#${cpr}${C_RESET} ·"
  cap="${REFIX_MAX_ROUNDS:-3}"
  count="$(resolver_dispatch_count "$cpr")"
  # HERD-147 flair default: a conflict is a needs-you/red state → 'attention' in the pasture header
  # (never softened). The in-progress "resolving conflict…" outcomes below downgrade it to 'busy'.
  FLAIR_STATE[ci]="attention"

  # RE-STALE LAP (HERD-231): a PR that was a gate CANDIDATE and is now CONFLICTING lost this sha to a
  # merge that landed under it, exactly as a stale-base hold does. Counted once per sha (and only when
  # gate work was actually invested), before the early returns below — every branch here is a lost lap.
  # The decoration of the row it paints happens at the caller, which knows the branch it took.
  _restale_note "$cpr" "$csha" "$cslug" conflict

  # ESCALATE already recorded for THIS sha → terminal; hold for a human, never re-dispatch.
  if resolver_escalated_sha "$cpr" "$csha"; then
    DISPLAY[ci]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · resolver escalated (ambiguous conflict)${C_RESET}"
    return
  fi

  if resolver_dispatched_sha "$cpr" "$csha"; then
    # A resolver already ran (or is running) against THIS exact commit.
    case "$(_resolve_result "$cpr" "$csha" || true)" in
      ESCALATE)
        # Promote the resolver's ESCALATE verdict to a terminal marker for this sha.
        record_resolve_escalated "$cpr" "$cslug" "$cbranch" "$csha"
        DISPLAY[ci]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · resolver escalated (ambiguous conflict)${C_RESET}"
        return ;;
      DONE)
        # Resolver reported done yet the PR is STILL conflicting — it could not clear it. Do NOT
        # re-spawn on the same sha (that would loop); wait for a new commit or a human.
        # HERD-280: DONE is DONE — the resolver has written its terminal verdict and will do nothing
        # more, so its pane retires here too. (The per-tick reconcile retires the far commoner DONE:
        # the one that CLEARED the conflict and so never reaches this classifier again.)
        _retire_resolver_pane "$cpr" "$csha" result-consumed
        DISPLAY[ci]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · resolver failed${C_RESET}"
        return ;;
    esac
    # Dispatched for this sha, no verdict yet. If the resolver is still in flight (agent alive, or a
    # just-spawned resolver still inside the startup grace) HOLD — never double-dispatch onto its tree.
    if _resolver_in_flight "$cslug" "$cpr" "$csha"; then
      DISPLAY[ci]="    ${C_YELLOW}🔀${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}resolving conflict…${C_RESET}"
      FLAIR_STATE[ci]="busy"
      return
    fi
    # DEAD resolver — re-spawn for the same sha if budget remains, else surface needs-you.
    if [ "$count" -ge "$cap" ]; then
      DISPLAY[ci]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · resolver gave up (${cap} rounds)${C_RESET}"
      return
    fi
    DISPLAY[ci]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · conflict${C_RESET}"
    CONF_IDX+=("$ci"); CONF_SLUG+=("$cslug"); CONF_PR+=("$cpr"); CONF_BRANCH+=("$cbranch"); CONF_SHA+=("$csha"); CONF_REASON+=("dead-resolver")
    return
  fi

  # No resolver dispatched for THIS sha.
  if [ "$count" -eq 0 ]; then
    # First-ever conflict on this PR — today's hands-off auto-resolve path.
    DISPLAY[ci]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · conflict${C_RESET}"
    CONF_IDX+=("$ci"); CONF_SLUG+=("$cslug"); CONF_PR+=("$cpr"); CONF_BRANCH+=("$cbranch"); CONF_SHA+=("$csha"); CONF_REASON+=("first")
    return
  fi
  # A resolver ran on an OLDER sha and this PR got a NEW commit that reshaped the conflict surface.
  # CRITICAL: the prior resolver (dispatched for the old sha) may STILL be running — a resolver runs
  # for minutes while ticks are seconds. Re-dispatching now would put a second resolver on the SAME
  # worktree, racing the first on `git merge`/`git push`. So HOLD while it is in flight; the respawn
  # fires on a later tick once it has exited (agent gone + past grace) — same guard as the dead path.
  if _resolver_in_flight "$cslug" "$cpr" "$csha"; then
    DISPLAY[ci]="    ${C_YELLOW}🔀${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}resolving conflict…${C_RESET}"
    FLAIR_STATE[ci]="busy"
    return
  fi
  if [ "$count" -ge "$cap" ]; then
    DISPLAY[ci]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · resolver gave up (${cap} rounds)${C_RESET}"
    return
  fi
  DISPLAY[ci]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · conflict${C_RESET}"
  CONF_IDX+=("$ci"); CONF_SLUG+=("$cslug"); CONF_PR+=("$cpr"); CONF_BRANCH+=("$cbranch"); CONF_SHA+=("$csha"); CONF_REASON+=("new-commit")
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

# HERD_PR_REF_PY — THE ONE implementation of "given a PR body, print its explicit `Refs:` value".
# Every surface that reads a PR's tracker ref reuses this snippet rather than re-deriving the rules,
# per the invariance-first doctrine (docs/multi-seat-doctrine.md): merge-time reconcile
# (_reconcile_pr_ref, below) and the sweep's retroactive-linkage leg (sweep.sh) both parse the same
# bytes, and a faithful copy in the second place is a copy that drifts. Same shape as
# backends/linear.sh's _LINEAR_PICK_STATE_PY: a python function definition, prepended to whichever
# driver the caller needs (one body on stdin, or a whole `gh pr list` array).
#
# The rules, in one place:
#   • STRIP HTML COMMENT BLOCKS FIRST. `gh pr view --json body` returns raw markdown with `<!-- … -->`
#     intact — GitHub does not strip them from a classic PULL_REQUEST_TEMPLATE.md. An example `Refs:`
#     buried in the template's own comment would otherwise poison every untracked PR.
#   • The FIRST `Refs:` line, case-insensitive, anchored at line start; first whitespace-delimited
#     token after the colon.
#   • STRIP TRAILING PUNCTUATION. `Refs: HERD-267,` and `Refs: HERD-267.` are the same ref as
#     `Refs: HERD-267`. Without this the sweep's shape test reads `267,` as "not an identifier" and
#     declares — with no lookup at all — that the item was never minted.
#   • A template PLACEHOLDER (`<…>`, none, n/a, na) is NOT a ref.
HERD_PR_REF_PY='
import re
_PR_REF_PLACEHOLDER = {"", "none", "n/a", "na"}
def pr_ref_from_body(body):
    body = re.sub(r"<!--.*?-->", "", body or "", flags=re.DOTALL)
    for line in body.splitlines():
        m = re.match(r"^\s*refs:\s*(\S+)", line, re.IGNORECASE)
        if not m:
            continue
        ref = m.group(1).rstrip(".,;:!)]}")
        if ref.startswith("<") or ref.lower() in _PR_REF_PLACEHOLDER:
            return ""
        return ref
    return ""
'

# herd_pr_ref_from_body — read a PR body on stdin, print its `Refs:` value (empty when there is none).
# The shell-side entry point to HERD_PR_REF_PY.
#
# NO-PYTHON3 FALLBACK. python3 is a hard engine dep, but this function sits on the merge tail, and the
# pre-HERD-267 code degraded to a grep/sed pass rather than silently dropping every explicit ref onto
# the fuzzy path. That degradation is preserved: the comment strip is what needs python (a multi-line
# regex), so without it we grep the RAW body — the line-start anchor and the placeholder guard are
# still a partial defense, exactly as before.
herd_pr_ref_from_body() {
  local body ref
  body="$(cat)"
  if command -v python3 >/dev/null 2>&1; then
    ref="$(printf '%s' "$body" | python3 -c "$HERD_PR_REF_PY"'
import sys
sys.stdout.write(pr_ref_from_body(sys.stdin.read()))' 2>/dev/null)" && { printf '%s' "$ref"; return 0; }
  fi
  # Degraded path: same rules, minus the HTML-comment strip.
  ref="$(printf '%s\n' "$body" \
    | grep -iE '^[[:space:]]*Refs:[[:space:]]*[^[:space:]]' \
    | head -n1 \
    | sed -E 's/^[[:space:]]*[Rr][Ee][Ff][Ss]:[[:space:]]*//; s/[[:space:]].*$//; s/[.,;:!)}]+$//' 2>/dev/null || true)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
  case "$ref" in
    ''|'<'*|none|None|NONE|n/a|N/A|na|NA) return 0 ;;
  esac
  printf '%s' "$ref"
}

# _reconcile_pr_ref — moved to work-units/git-pr.sh (HERD-398, Phase 3 work-unit extraction).

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

# reconcile_backlog — moved to work-units/git-pr.sh (HERD-398, Phase 3 work-unit extraction).

# ── Post-merge refresh SERIALIZATION + detached-HEAD guard (HERD-336) ─────────────────────────────
# The codemap/symbol-index refresh legs (refresh_codemap / refresh_symbol_index) each run a
# pull→regenerate→commit→push sequence against the SHARED coordinator checkout ($MAIN). Two legs ~30s
# apart (two merges) once ran concurrently: the second started mid-rebase of the first, committed two
# refresh commits onto a DETACHED HEAD, and left $MAIN detached until a later human `git pull` failed
# with `not on a branch`. These helpers make the leg SERIAL per-checkout and REFUSE to commit on a
# detached HEAD (reconciling the invariant "shared checkout always attached, derived docs committed or
# untouched" on every refresh run, not just the happy path). Fully fail-soft: a lock that cannot be
# acquired = skip + journal, never a red row or a hung watcher.

# _refresh_lock_file — the per-checkout refresh lock path. Lives inside $MAIN's own git dir so it is
# (a) per-checkout ON DISK — any seat's watcher/merge that refreshes the SAME shared checkout contends
# for the SAME file, even across seats whose $TREES differ — and (b) never committed (git ignores its
# own dir). Fail-soft derivation: `--absolute-git-dir` else a plain $MAIN/.git fallback.
_refresh_lock_file() {
  local _gd
  _gd="$(git -C "$MAIN" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [ -n "$_gd" ] || _gd="$MAIN/.git"
  printf '%s/herd-refresh.lock' "$_gd"
}

# _refresh_run_locked <body-fn> — run <body-fn> holding the per-checkout refresh lock so concurrent
# refresh legs SERIALIZE against the shared checkout. NON-BLOCKING: if a live leg already holds the
# lock, <body-fn> is NOT run and this returns 1 — the caller journals a skip, which is correct because
# the winning leg's regeneration is fresh (a second regen would be redundant). Returns 0 when the body
# ran. Fail-soft: a lock left by a CRASHED leg (mutex older than the 10-minute stale cap) is stolen
# once. A plain atomic-mkdir mutex (works with no flock(1) — the macOS default), released explicitly
# on return; the body only has file/git side effects, so running it inline needs no subshell.
_refresh_run_locked() {
  local _rl_body="$1" _rl_dir _rl_took=""
  _rl_dir="$(_refresh_lock_file).d"
  mkdir -p "$(dirname "$_rl_dir")" 2>/dev/null || true
  if mkdir "$_rl_dir" 2>/dev/null; then
    _rl_took=1
  elif [ -z "$(find "$_rl_dir" -prune -mmin -10 2>/dev/null)" ]; then
    # Holder mutex older than 10 min → a crashed leg. Steal it once (the mutex, not a live process).
    rm -rf "$_rl_dir" 2>/dev/null || true
    mkdir "$_rl_dir" 2>/dev/null && _rl_took=1
  fi
  [ -n "$_rl_took" ] || return 1        # a live leg holds it — skip (the winner's regen is fresh)
  printf '%s\n' "$$" > "$_rl_dir/pid" 2>/dev/null || true   # diagnostic only; never load-bearing
  "$_rl_body"
  # HERD-364: the checkout-attached EXIT INVARIANT. The body reaches its many exits — success, refusal,
  # regen/commit error, the push-rejected `reset --hard HEAD~1` rollback, a rebase abort — and any one of
  # them (or a concurrent seat's rebase-pull racing our reset, the #471/#462-seconds-apart window) can
  # leave $MAIN on a DETACHED HEAD, the corpse HERD-336's happy-path guards missed. Reattaching HERE,
  # once, past EVERY body path but still UNDER the lock (no concurrent leg can be mid-write), makes
  # "attached to the default branch" the leg's guaranteed post-condition rather than a best-effort call
  # scattered through the body. Byte-inert when already attached (_refresh_guard_attached returns 0
  # silently on the happy path); on a real detachment it journals main_detached detected+reattached and
  # heals. Fail-soft — never aborts the tick.
  _refresh_guard_attached || true
  rm -rf "$_rl_dir" 2>/dev/null || true
  return 0
}

# _main_head_attached — success iff $MAIN's HEAD is the default branch (attached, not detached). The
# read-only predicate every refresh commit consults before it writes.
_main_head_attached() {
  [ "$(git -C "$MAIN" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "${HERD_BRANCH_NAME:-main}" ]
}

# _journal_main_detached <result> [head] — one `main_detached` audit breadcrumb (result=detected on
# discovery, result=reattached after a successful reattach). journal-audit.sh surfaces a `detected`
# that no later `reattached` clears (a shared checkout that sat detached — the HERD-336 corpse).
_journal_main_detached() {
  journal_append main_detached head "${2:-}" branch "${HERD_BRANCH_NAME:-main}" result "${1:-detected}"
}

# _reattach_default_branch — best-effort: abort any in-progress rebase and reattach $MAIN to the
# default branch, aligning to origin. The only thing that can be lost is a regenerable derived map
# committed on the detached HEAD — cheap to redo. Fail-soft; returns the resulting attach status.
_reattach_default_branch() {
  local _rb="${HERD_BRANCH_NAME:-main}" _ru="${HERD_REMOTE:-origin}/${HERD_BRANCH_NAME:-main}"
  git -C "$MAIN" rebase --abort >/dev/null 2>&1 || true
  git -C "$MAIN" checkout --quiet --force "$_rb" >/dev/null 2>&1 \
    || git -C "$MAIN" symbolic-ref HEAD "refs/heads/$_rb" >/dev/null 2>&1 || true
  if git -C "$MAIN" rev-parse --verify --quiet "$_ru" >/dev/null 2>&1; then
    git -C "$MAIN" reset --hard "$_ru" >/dev/null 2>&1 || true
  fi
  _main_head_attached
}

# _refresh_guard_attached — the refresh legs' commit gate. Success (0) when HEAD is safely on the
# default branch (silent on the happy path). On a DETACHED HEAD it journals main_detached, reattaches
# loudly, and returns 1 so the caller REFUSES to commit its refresh (the regen is cheap to redo).
_refresh_guard_attached() {
  _main_head_attached && return 0
  local _h; _h="$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
  _journal_main_detached detected "$_h"
  if _reattach_default_branch; then
    _journal_main_detached reattached "$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
  fi
  return 1
}

# refresh_codemap <pr#> [provenance] — POST-MERGE codemap freshness hook (best-effort, NEVER
# blocks/fails the merge). After a PR lands on the default branch and $MAIN is fast-forwarded,
# regenerate the committed docs/codemap.md against $MAIN and, ONLY when the deterministic scan
# actually changed its content, commit the refresh STRAIGHT to the default branch — no PR,
# mirroring the BACKLOG.md generated-artifact convention — and push ff-safe. Every failure mode
# fails SOFT and journals a `codemap_refresh` event so a drift audit can see what happened; nothing
# here can ever return non-zero into do_merge.
#
# Optional <provenance> tags the journal (and shapes the commit message when <pr#> is empty): the
# do_merge fast path leaves it empty (byte-identical journal lines for existing tests); the
# tick-level reconcile (HERD-218) passes `reconcile` so out-of-band merges are auditable.
#
# Gated by CODEMAP_AUTOREFRESH: off → byte-inert (we never run the scan, never touch the tree).
# Race-guarded four ways: (1) only when the project has already ADOPTED the codemap (the committed
# docs/codemap.md exists — never materialize a new one); (2) HERD-336: the whole regenerate→commit→push
# leg SERIALIZES per-checkout (_refresh_run_locked) so two concurrent legs can never race the shared
# checkout's rebase; a lock held by a live leg → skip; (3) a PRE-EXISTING dirty docs/codemap.md is a
# stranded regeneration (the map is engine-generated, so under the lock it is never a concurrent human
# edit) → ABSORB it into this regen commit rather than skip forever; (4) codemap.sh rewrites the file
# ONLY when content changed, so a clean tree after regen = fresh, nothing to commit. The commit is
# scoped to docs/codemap.md alone, and NEVER lands on a detached HEAD (_refresh_guard_attached).
# HERD-159: unrecognized values fail soft toward ACTIVE via _codemap_auto (cosmetic key).
refresh_codemap() {
  local rc_pr="${1:-}" rc_prov="${2:-}" rc_out="docs/codemap.md" rc_script="$HERE/codemap.sh" rc_msg
  # _rc_j <k v ...> — journal codemap_refresh with optional provenance tag (empty → omit, keeps the
  # pre-HERD-218 journal lines byte-identical for the do_merge path / existing hermetic tests).
  _rc_j() {
    if [ -n "$rc_prov" ]; then
      journal_append codemap_refresh pr "$rc_pr" "$@" provenance "$rc_prov"
    else
      journal_append codemap_refresh pr "$rc_pr" "$@"
    fi
  }
  case "$(_codemap_auto)" in
    false)
      _rc_j result skipped reason disabled; return 0 ;;
  esac
  [ -f "$rc_script" ]      || { _rc_j result skipped reason no-script;  return 0; }
  [ -f "$MAIN/$rc_out" ]   || { _rc_j result skipped reason no-codemap; return 0; }
  # HERD-336 (a): SERIALIZE the whole regenerate→commit→push leg per checkout. The cheap guards above
  # stay OUTSIDE the lock so OFF and an unadopted repo remain byte-inert and take on no lock churn.
  _rc_body() {
    # HERD-336 (b): a PRE-EXISTING dirty docs/codemap.md is NOT a concurrent human edit — the map is
    # engine-generated, and under the serialization lock no other refresh leg can own it. It is a
    # stranded regeneration from a crashed/detached leg; ABSORB it into this regeneration commit
    # rather than skipping forever (the old dirty-path skip stranded it — the live symbol-index corpse).
    if [ -n "$(git -C "$MAIN" status --porcelain -- "$rc_out" 2>/dev/null)" ]; then
      _rc_j result absorbing reason dirty-derived
    fi
    # Regenerate in place against the freshly ff'd $MAIN (the seams the hermetic tests also drive).
    if ! HERD_CODEMAP_ROOT="$MAIN" HERD_CODEMAP_OUT="$MAIN/$rc_out" bash "$rc_script" >/dev/null 2>&1; then
      _rc_j result error reason regen-failed; return 0
    fi
    # Unchanged content → codemap.sh left the file (and its mtime) alone → nothing to commit.
    if [ -z "$(git -C "$MAIN" status --porcelain -- "$rc_out" 2>/dev/null)" ]; then
      _rc_j result fresh; return 0
    fi
    # Content changed → commit ONLY docs/codemap.md and push ff-safe (never --force). A rejected push
    # (another direct-commit landed first) rebases once and retries; a genuine failure fails soft.
    if [ -n "$rc_pr" ]; then
      rc_msg="chore: refresh codemap after PR #${rc_pr}"
    elif [ "$rc_prov" = "reconcile" ]; then
      rc_msg="chore: refresh codemap (reconcile)"
    else
      rc_msg="chore: refresh codemap"
    fi
    # HERD-336 (b): NEVER commit onto a detached HEAD (the refresh-race corpse). Journal it, reattach
    # the default branch, and skip — the regeneration is cheap to redo on a later tick.
    if ! _refresh_guard_attached; then
      _rc_j result skipped reason detached-head pushed no; return 0
    fi
    if ! git -C "$MAIN" commit -q -m "$rc_msg" -- "$rc_out" >/dev/null 2>&1; then
      _rc_j result error reason commit-failed; return 0
    fi
    if git -C "$MAIN" push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" >/dev/null 2>&1; then
      _rc_j result committed pushed yes; return 0
    fi
    # Push rejected → rebase once and retry. HERD-336: a rebase-pull can leave HEAD detached — verify
    # attachment BEFORE the retry push, and reattach (never HEAD~1-reset a detached HEAD, which would
    # strand the branch) if it did.
    if git -C "$MAIN" pull --rebase --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME" >/dev/null 2>&1; then
      if _main_head_attached; then
        if git -C "$MAIN" push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" >/dev/null 2>&1; then
          _rc_j result committed pushed yes-after-rebase; return 0
        fi
      else
        _refresh_guard_attached || true
        _rc_j result error reason detached-head pushed no; return 0
      fi
    fi
    if ! _main_head_attached; then
      _refresh_guard_attached || true
      _rc_j result error reason detached-head pushed no; return 0
    fi
    git -C "$MAIN" rebase --abort >/dev/null 2>&1 || true
    # Push rejected (protected branch hook or a permanent race): roll back the commit so local main
    # never drifts ahead of origin. The map is regenerable — not committing is byte-safe. A stranded
    # commit here would permanently diverge the seat and make herd update die on ff-only forever.
    git -C "$MAIN" reset --hard HEAD~1 >/dev/null 2>&1 || true
    _rc_j result error reason push-rejected pushed no
    return 0
  }
  if ! _refresh_run_locked _rc_body; then
    _rc_j result skipped reason locked
  fi
  return 0
}

# refresh_symbol_index <pr#> [provenance] — POST-MERGE symbol-index freshness hook, the function-level
# twin of refresh_codemap. Regenerates the committed docs/symbol-index.md against the freshly ff'd
# $MAIN and, ONLY when the deterministic scan actually changed its content, commits the refresh
# STRAIGHT to the default branch (no PR, BACKLOG.md-style) and pushes ff-safe. Best-effort and
# byte-inert on every failure mode; journals a `symbol_index_refresh` event; can never return
# non-zero into do_merge. Optional <provenance> mirrors refresh_codemap (HERD-218 reconcile path).
#
# Shares the CODEMAP_AUTOREFRESH lever (both are committed engine maps kept fresh at zero token cost)
# and the same guards as refresh_codemap: (1) only when the project has ADOPTED the index (the committed
# docs/symbol-index.md exists — never materialize a new one); (2) HERD-336: the whole regenerate→commit→
# push leg SERIALIZES per-checkout so concurrent legs never race the shared rebase (lock held → skip);
# (3) a PRE-EXISTING dirty docs/symbol-index.md is a stranded regeneration → ABSORB it into this regen
# commit rather than skip forever; (4) symbol-index.sh rewrites the file ONLY when content changed, so a
# clean tree after regen = fresh, nothing to commit. Scoped to docs/symbol-index.md; never commits onto
# a detached HEAD (_refresh_guard_attached).
refresh_symbol_index() {
  local rs_pr="${1:-}" rs_prov="${2:-}" rs_out="docs/symbol-index.md" rs_script="$HERE/symbol-index.sh" rs_msg
  _rs_j() {
    if [ -n "$rs_prov" ]; then
      journal_append symbol_index_refresh pr "$rs_pr" "$@" provenance "$rs_prov"
    else
      journal_append symbol_index_refresh pr "$rs_pr" "$@"
    fi
  }
  case "$(_codemap_auto)" in
    false)
      _rs_j result skipped reason disabled; return 0 ;;
  esac
  [ -f "$rs_script" ]    || { _rs_j result skipped reason no-script; return 0; }
  [ -f "$MAIN/$rs_out" ] || { _rs_j result skipped reason no-index;  return 0; }
  # HERD-336 (a): SERIALIZE the whole regenerate→commit→push leg per checkout (cheap guards above stay
  # outside the lock so OFF / an unadopted repo remain byte-inert).
  _rs_body() {
    # HERD-336 (b): ABSORB a PRE-EXISTING dirty docs/symbol-index.md (a stranded regeneration from a
    # crashed/detached leg — the map is engine-generated, so under the lock it is never a human edit)
    # into this regeneration commit rather than skipping forever.
    if [ -n "$(git -C "$MAIN" status --porcelain -- "$rs_out" 2>/dev/null)" ]; then
      _rs_j result absorbing reason dirty-derived
    fi
    # Regenerate in place against the freshly ff'd $MAIN (the seams the hermetic tests also drive).
    if ! HERD_SYMBOL_INDEX_ROOT="$MAIN" HERD_SYMBOL_INDEX_OUT="$MAIN/$rs_out" bash "$rs_script" >/dev/null 2>&1; then
      _rs_j result error reason regen-failed; return 0
    fi
    # Unchanged content → symbol-index.sh left the file (and its mtime) alone → nothing to commit.
    if [ -z "$(git -C "$MAIN" status --porcelain -- "$rs_out" 2>/dev/null)" ]; then
      _rs_j result fresh; return 0
    fi
    # Content changed → commit ONLY docs/symbol-index.md and push ff-safe (never --force). A rejected
    # push (another direct-commit landed first) rebases once and retries; a genuine failure fails soft.
    if [ -n "$rs_pr" ]; then
      rs_msg="chore: refresh symbol-index after PR #${rs_pr}"
    elif [ "$rs_prov" = "reconcile" ]; then
      rs_msg="chore: refresh symbol-index (reconcile)"
    else
      rs_msg="chore: refresh symbol-index"
    fi
    # HERD-336 (b): NEVER commit onto a detached HEAD; journal, reattach, skip (regen is cheap to redo).
    if ! _refresh_guard_attached; then
      _rs_j result skipped reason detached-head pushed no; return 0
    fi
    if ! git -C "$MAIN" commit -q -m "$rs_msg" -- "$rs_out" >/dev/null 2>&1; then
      _rs_j result error reason commit-failed; return 0
    fi
    if git -C "$MAIN" push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" >/dev/null 2>&1; then
      _rs_j result committed pushed yes; return 0
    fi
    # Push rejected → rebase once and retry; verify HEAD attachment before the retry push (HERD-336).
    if git -C "$MAIN" pull --rebase --quiet "$HERD_REMOTE" "$HERD_BRANCH_NAME" >/dev/null 2>&1; then
      if _main_head_attached; then
        if git -C "$MAIN" push -q "$HERD_REMOTE" "$HERD_BRANCH_NAME" >/dev/null 2>&1; then
          _rs_j result committed pushed yes-after-rebase; return 0
        fi
      else
        _refresh_guard_attached || true
        _rs_j result error reason detached-head pushed no; return 0
      fi
    fi
    if ! _main_head_attached; then
      _refresh_guard_attached || true
      _rs_j result error reason detached-head pushed no; return 0
    fi
    git -C "$MAIN" rebase --abort >/dev/null 2>&1 || true
    # Push rejected (protected branch hook or a permanent race): roll back the commit so local main
    # never drifts ahead of origin. The index is regenerable — not committing is byte-safe. A
    # stranded commit here would permanently diverge the seat and make herd update die forever.
    git -C "$MAIN" reset --hard HEAD~1 >/dev/null 2>&1 || true
    _rs_j result error reason push-rejected pushed no
    return 0
  }
  if ! _refresh_run_locked _rs_body; then
    _rs_j result skipped reason locked
  fi
  return 0
}

# ── Tick-level MAIN-checkout freshness reconcile (HERD-233) ───────────────────────────────────────
# Multi-seat doctrine Rule 1: the freshness of the $MAIN checkout is a RECONCILED INVARIANT, not a
# do_merge side-effect. do_merge fast-forwards $MAIN after THIS seat's merge; nothing did so when
# another seat (or the gh UI) merged — $MAIN drifted 22 commits behind while this watcher went on
# running the stale engine code it loads from there. Worse, a generated-map refresh whose push was
# rejected (`pushed no`) left $MAIN DIVERGED with no retry path, and a human had to rebase by hand.
#
# This reconcile owns both, once per tick, INDEPENDENT of the CODEMAP_AUTOREFRESH lever (the HERD-218
# map reconcile's ff-pull rode that lever, so maps-off meant no freshness reconcile at all):
#   • strictly BEHIND + clean tree            → fast-forward, journal `main_ff`
#   • DIVERGED/AHEAD, and every local-only commit touches ONLY the generated maps (docs/codemap.md,
#     docs/symbol-index.md — the `pushed=no` corpse) → rebase onto origin + push, journal `main_heal`
#   • anything else (dirty tree, a local commit a human wrote, a failed ff/rebase/push) → a LOUD
#     console row + one `main_freshness result held` journal line. NEVER guess, never force, never
#     reset a commit we did not generate.
#
# HARD INVARIANTS:
#   • Already fresh (0 ahead, 0 behind) → byte-inert: no journal, no state file, no console row.
#   • A fetch failure never blocks the tick (offline / gh outage → silent, retried next tick).
#   • Held reasons journal ONCE per transition (the row persists; the journal does not spam).
#   • The watcher executes the engine code it loaded at startup, so a pull that carries a new
#     agent-watch.sh leaves a "restart recommended" note — cleared at the next watcher startup.

MAIN_FRESH_STATE="$TREES/.agent-watch-main-freshness"   # one line while UNHEALABLE: "<reason> <behind> <ahead>"
MAIN_FRESH_RESTART="$TREES/.agent-watch-main-restart"   # one line: the sha whose pull carried new engine code
MAIN_DETACHED_STATE="$TREES/.agent-watch-main-detached" # HERD-336: the detached-HEAD sha, deduped so a persisting detachment journals once
CHECKOUT_CLEAN_STATE="$TREES/.agent-watch-checkout-clean" # HERD-361: the shared-checkout cleanliness violation signature (absent = clean); drives the row + dedups the journal

# _watch_gate_inflight — true when a review/health worker is live. The shared mid-op probe: both the
# MAIN-freshness and the map reconcile must keep their hands off the tree while a gate runs.
_watch_gate_inflight() {
  local f
  for f in "$TREES"/.review-inflight-* "$TREES"/.health-inflight-*; do
    [ -e "$f" ] || continue
    _marker_live "$f" 2>/dev/null && return 0
  done
  return 1
}

# _count_gate_workers — how many review/health workers are LIVE right now. The counted form of
# _watch_gate_inflight (same two marker families, same liveness probe), used by the self-restart
# quiesce to decide when the drain is complete and to render 'draining N gate workers'.
#
# SCOPE, precisely: the two INFLIGHT-MARKER families this watcher owns in-process — reviewers and
# healthcheck suites. Conflict resolvers and builders are NOT counted: they are agents in their own
# panes with no inflight marker, they are never killed by the exec (they outlive it, like the review
# and health workers do), and blocking a restart on a resolver — which can run for many minutes —
# would strand the watcher on stale code for exactly as long. The quiesce still refuses to DISPATCH a
# new resolver, so no fresh one starts mid-drain.
_count_gate_workers() {
  local f n=0
  for f in "$TREES"/.review-inflight-* "$TREES"/.health-inflight-*; do
    [ -e "$f" ] || continue
    _marker_live "$f" 2>/dev/null && n=$((n + 1))
  done
  printf '%s' "$n"
}

# ── Watcher SELF-RESTART on stale engine code (HERD-251) ─────────────────────────────────────────
# The watcher executes the engine code it loaded at startup. HERD-233 detects the case where a pulled
# delta rewrote agent-watch.sh and leaves a "restart recommended" note ($MAIN_FRESH_RESTART) for the
# operator — who then restarts by hand (six times on 2026-07-09 alone). This closes that loop.
#
# WATCHER_SELF_RESTART=on → the note ARMS a QUIESCE-THEN-EXEC:
#   (a) QUIESCE — stop dispatching NEW gate work (reviews, healthchecks, resolver spawns, and the
#       stale-base heal that dispatches them). Every hold sits ABOVE its call site's ledger write, so a
#       refused dispatch never leaves a spent once-guard behind it (see _handle_stale_dup). In-flight
#       workers are never killed: they run to completion and their verdicts are COLLECTED normally,
#       because the collect paths sit upstream of every dispatch hold. Merges of already-green PRs
#       still land; nothing expensive is started.
#   (b) EXEC — once zero live REVIEW/HEALTH workers remain for 2 CONSECUTIVE ticks (a single quiet tick
#       can be the instant between one worker's exit and its sibling's dispatch), or the inline
#       15-minute max-wait cap expires, re-exec this script IN PLACE. See _count_gate_workers for why
#       resolvers and builders are deliberately outside that count.
#   (c) journal watcher_self_restart reason=engine-update shas=<old>..<new>.
#
# WHY exec IS SAFE HERE — all three identities survive because exec keeps the PID and the pane:
#   • pane    — exec replaces the process image inside the same pane/tty; nothing is respawned.
#   • argv0   — we pass `exec -a "$HERD_WATCH_ARGV0"` ourselves. HERD_WATCH_REEXEC is already exported
#               in this process, so the new image skips the one-shot argv0 re-exec and keeps the tag.
#   • lock    — the singleton is re-acquired by the new image at the SAME pid. _acquire_watcher_singleton
#               refuses only a LIVE recorded pid that is NOT $$; ours IS $$, so it adopts. Under flock
#               the `exec 9>>` reopen drops the old open-file description (releasing the lock) and
#               flock -n immediately re-takes it; under the mkdir fallback the EXIT trap never fires on
#               exec, so the pid file is simply rewritten with the same pid. Neither path can hand the
#               workspace to a duplicate: no window exists in which the lock is free AND we are gone.
# In-flight workers are NOT killed even at cap expiry: reviews are setsid'd and health workers are
# ordinary children, so both outlive the exec. The new image's startup sweeps + the every-tick corpse
# sweep reap their markers and time them out from the marker's own dispatch ts.
#
# HARD INVARIANTS:
#   • WATCHER_SELF_RESTART=off (default) → byte-identical to HERD-233: no arm, no dispatch hold, no
#     exec, no journal. The recommendation row renders exactly as before.
#   • DRYRUN → never arms (an observation run must not restart anything).
#   • FAIL-SOFT: an unreadable script path, or a hermetic-test guard, disarms and leaves the note in
#     place, so the console falls back to the plain 'restart recommended' row. The refusal LATCHES for
#     the life of the process: the note that armed us is still there, so without the latch the next
#     tick would re-arm, hold dispatch, refuse again, and spin — an every-other-tick gate stall.
SELF_RESTART_CAP_SECS=900          # inline 15-minute max-wait cap on the drain (HERD-251)
_SELF_RESTART_ARMED=""             # epoch the quiesce began; empty ⇒ not quiescing
_SELF_RESTART_FROM=""              # $MAIN HEAD sha before the pull that carried new engine code
_SELF_RESTART_TO=""                # …and after it (the sha recorded in $MAIN_FRESH_RESTART)
_SELF_RESTART_IDLE_TICKS=0         # consecutive ticks observed with zero live review/health workers
_SELF_RESTART_GAVE_UP=""           # 1 once an exec was refused: never arm again in this process

# _self_restart_enabled — the master lever. Anything but `on` is off (ship-dormant default).
_self_restart_enabled() { [ "${WATCHER_SELF_RESTART:-off}" = "on" ]; }

# _self_restart_quiescing — true once armed: the watcher is draining toward an in-place re-exec.
_self_restart_quiescing() { [ -n "${_SELF_RESTART_ARMED:-}" ]; }

# _self_restart_hold_dispatch — the ONE predicate every gate-dispatch site consults. True ⇒ this tick
# must NOT start new gate work. Byte-inert with the lever off (the first test short-circuits).
_self_restart_hold_dispatch() { _self_restart_enabled && _self_restart_quiescing; }

# _self_restart_arm — enter the quiesce. Records the sha delta (from the reconcile's own note file,
# whose single line is the NEW sha) and journals ONCE. Idempotent: a second call while armed no-ops.
_self_restart_arm() {
  _self_restart_quiescing && return 0
  _SELF_RESTART_ARMED="$(date +%s)"
  _SELF_RESTART_IDLE_TICKS=0
  _SELF_RESTART_TO="$(cat "$MAIN_FRESH_RESTART" 2>/dev/null || true)"
  _SELF_RESTART_TO="${_SELF_RESTART_TO%%[$'\t\r\n ']*}"
  journal_append watcher_quiesce reason engine-update \
    shas "${_SELF_RESTART_FROM:-unknown}..${_SELF_RESTART_TO:-unknown}" cap "$SELF_RESTART_CAP_SECS"
  return 0
}

# _self_restart_should_exec <live-workers> <waited-secs> — the pure decision. Echoes the trigger
# reason ('drained' | 'cap-expiry') when it is time to re-exec, else nothing. Two consecutive
# zero-worker ticks (not one) so we never exec in the gap between a collect and its sibling dispatch.
_self_restart_should_exec() {
  local _sr_n="${1:-0}" _sr_waited="${2:-0}"
  case "$_sr_n" in ''|*[!0-9]*) _sr_n=0 ;; esac
  case "$_sr_waited" in ''|*[!0-9]*) _sr_waited=0 ;; esac
  [ "$_sr_n" -eq 0 ] && [ "$_SELF_RESTART_IDLE_TICKS" -ge 2 ] && { printf 'drained'; return 0; }
  [ "$_sr_waited" -ge "$SELF_RESTART_CAP_SECS" ] && { printf 'cap-expiry'; return 0; }
  return 0
}

# _self_restart_journal <trigger> <live-workers> <waited-secs> — the ONE watcher_self_restart event.
# Emitted only once the exec is certain to be attempted (see below), so a consumer counting these
# events counts restarts that actually happened, not ones the guards refused.
_self_restart_journal() {
  journal_append watcher_self_restart reason engine-update \
    shas "${_SELF_RESTART_FROM:-unknown}..${_SELF_RESTART_TO:-unknown}" \
    trigger "$1" workers "$2" waited "$3"
}

# _self_restart_exec <trigger> <live-workers> <waited-secs> — replace this process image with a fresh
# load of the engine code now on disk. Returns 1 (fail-soft, still armed → the caller disarms and the
# recommendation row returns) when the exec must not happen.
#
# The refusal guards run BEFORE the journal, and nothing but the exec follows it: a `watcher_self_restart`
# event therefore means a restart that happened. (Journaling AFTER the exec is impossible — exec never
# returns — so "immediately before, past every guard" is the closest honest point.)
_self_restart_exec() {
  local _se_trigger="$1" _se_workers="$2" _se_waited="$3"
  # A hermetic test never replaces its own image (the guard above already refuses the live loop).
  [ -n "${HERD_HERMETIC_GUARD:-}" ] && return 1
  [ -r "$HERE/agent-watch.sh" ] || return 1
  _self_restart_journal "$_se_trigger" "$_se_workers" "$_se_waited"
  # GENERATION HANDOFF (HERD-266). exec keeps our pid, but the outgoing image's still-running forks
  # are momentarily neither marker-owned nor children of a settled lock, so a `herd status` sampling
  # inside this window can see more than one tagged main. Record the window (TTL-bounded, cleared by
  # the incoming image once it owns the singleton) so the duplicate ALARM stays silent through it —
  # the pids are still LISTED, so `herd reload` can still stop us. Written last: nothing but the exec
  # follows, so a marker on disk means a handoff that actually started.
  watcher_handoff_begin "$$"
  # HERD_WATCH_REEXEC is already exported in this process, so the new image keeps the argv0 we pass
  # here rather than re-execing a second time. Same pid ⇒ same pane, same singleton lock. $_WATCH_ARGV
  # replays this watcher's own positional args, exactly as the startup argv0 re-exec passes "$@" — the
  # launch path this is imitating (empty today; agent-watch.sh takes none).
  exec -a "${HERD_WATCH_ARGV0:-herd-watch}" bash "$HERE/agent-watch.sh" \
    ${_WATCH_ARGV[@]+"${_WATCH_ARGV[@]}"}
}

# _self_restart_tick — call once per tick, AFTER reconcile_main_freshness (which writes the note this
# arms on). Never returns non-zero; the caller still guards with `|| true` so a self-restart bug can
# never take the watch loop down with it.
_self_restart_tick() {
  _self_restart_enabled || return 0
  [ -n "${DRYRUN:-}" ] && return 0
  [ -n "${_SELF_RESTART_GAVE_UP:-}" ] && return 0    # a refused exec is terminal for this process
  if ! _self_restart_quiescing; then
    [ -s "${MAIN_FRESH_RESTART:-}" ] || return 0
    _self_restart_arm
  fi
  local _st_n _st_waited _st_trigger
  _st_n="$(_count_gate_workers)"
  _st_waited=$(( $(date +%s) - _SELF_RESTART_ARMED ))
  [ "$_st_waited" -ge 0 ] || _st_waited=0    # a clock step backwards must not skip the cap
  if [ "$_st_n" -eq 0 ]; then
    _SELF_RESTART_IDLE_TICKS=$((_SELF_RESTART_IDLE_TICKS + 1))
  else
    _SELF_RESTART_IDLE_TICKS=0
  fi
  _st_trigger="$(_self_restart_should_exec "$_st_n" "$_st_waited")"
  [ -n "$_st_trigger" ] || return 0
  _self_restart_exec "$_st_trigger" "$_st_n" "$_st_waited" && return 0
  # Fail-soft: the exec did not happen. Disarm so gate dispatch resumes on the OLD (running) code, and
  # GIVE UP for the life of this process — the note that armed us is still on disk, so re-arming next
  # tick would only refuse again. The note reverts to its HERD-233 meaning: a restart recommendation
  # the operator acts on. Journaled ONCE, for the same reason.
  _SELF_RESTART_ARMED=""; _SELF_RESTART_IDLE_TICKS=0; _SELF_RESTART_GAVE_UP=1
  watcher_handoff_clear    # no handoff happened — never let a marker mask a real duplicate
  journal_append watcher_self_restart result skipped reason exec-unavailable trigger "$_st_trigger"
  return 0
}

# _main_fresh_clear — back to fresh: drop the held row (the journal already recorded the transition).
_main_fresh_clear() { rm -f "$MAIN_FRESH_STATE" 2>/dev/null || true; }

# _main_fresh_recovered — the held row's condition is GONE. Drop the state file and journal the
# transition ONCE (mirrors _main_health_clear: the file's presence IS the "was held" flag, so reading
# it before the rm is what makes the event fire exactly once). Never called on a happy-path tick —
# _main_fresh_recheck's first guard is the state file's existence.
_main_fresh_recovered() {
  local _mv_reason _mv_b _mv_a
  read -r _mv_reason _mv_b _mv_a < "$MAIN_FRESH_STATE" 2>/dev/null || true
  _main_fresh_clear
  journal_append main_fresh_recovered reason "${_mv_reason:-unknown}" \
    was_behind "${_mv_b:-0}" was_ahead "${_mv_a:-0}"
  return 0
}

# _main_fresh_recheck — the OBSERVED-state recovery probe (HERD-259). The held row is a STATE FILE, and
# before this every path that could delete it sat BELOW a defer in reconcile_main_freshness: a live gate
# marker, a failed fetch, or a $MAIN parked off-branch all returned early, so a row whose condition had
# already healed kept painting. It also outlived a watcher restart — startup drops $MAIN_FRESH_RESTART
# (see the one-shot sweep below the tick loop) but never re-validated $MAIN_FRESH_STATE, and the render
# pass runs ABOVE the reconcile in the tick, so the first paint of the new process trusted the stale
# file. Live incident 2026-07-09: 'dirty-tree 4 0' held for 20+ minutes across a restart on a checkout
# that was clean and current, until a human deleted the file.
#
# So the row is re-derived from OBSERVED git state every tick, ABOVE every defer, on both the render and
# reconcile paths. It is READ-ONLY on the repo (status + rev-list, no fetch, no network, no tree
# mutation), which is exactly why it is safe to run while a gate owns the tree — the reason the reconcile
# proper cannot.
#
# CLEARS ONLY ON PROVABLE FRESHNESS — clean tree AND zero behind AND zero ahead. "Not behind" alone would
# wipe a real `local-commits` hold (clean tree, 0 behind, N ahead is precisely that red), the same way a
# vacuous rc-0 would wipe a real MAIN RED (see _main_health_clear's warning).
#
# When it CANNOT clear it does NOT just leave the file frozen: it RE-DERIVES the row from observed state
# (HERD-293). The live incident 2026-07-10: a `dirty-tree 3 0` hold kept painting "behind by 3" after the
# operator pulled ($MAIN went 0-behind) — the old recheck returned early on the still-dirty tree, so the
# stored counts froze, and reconcile_main_freshness (which would re-hold with fresh counts) starves below
# the _watch_gate_inflight defer while gates run. So the row is a reconciled invariant over observed git
# state every tick (docs/multi-seat-doctrine.md rule 1), never an event-time snapshot: the reason and the
# behind/ahead counts are recomputed and re-held whenever they differ from the stored line.
#
# Only the two reasons a read-only, no-fetch probe can classify UNAMBIGUOUSLY are re-held here: `dirty-tree`
# (a dirty checkout) and `local-commits` (clean, ahead, and NOT generated-only). Every other hold —
# a clean ff-able behind, a generated-only divergence still auto-healing, a prior ff/rebase/push failure —
# depends on a fetch or a heal attempt the recheck deliberately does not make, so its file is left exactly
# as it was for the reconcile below the defer to re-decide once it can fetch and heal. _main_fresh_hold
# dedups the journal on an identical line, so a re-derive that matches the stored row is byte-inert.
#
# The behind/ahead counts come from the LOCAL remote-tracking ref (no fetch of our own). A row cleared or
# re-derived against a ref that has since moved is not a lie: the hold's condition (a dirty tree, a
# divergence this checkout no longer has) is observed as it stands now, and the reconcile below fetches
# and re-decides on the same tick if $MAIN is genuinely stale again.
#
# Byte-inert on the happy path: with no state file the first test returns, so a fresh $MAIN costs one
# `[ -s ]` and touches no git.
_main_fresh_recheck() {
  [ -s "${MAIN_FRESH_STATE:-}" ] || return 0
  [ -n "${DRYRUN:-}" ] && return 0            # an observation run mutates no state (as the reconcile does not)
  [ -n "${MAIN:-}" ] || return 0
  { [ -d "$MAIN/.git" ] || [ -f "$MAIN/.git" ]; } || return 0
  [ "$(git -C "$MAIN" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "${HERD_BRANCH_NAME:-}" ] \
    || return 0
  local _mk_up _mk_dirty _mk_counts _mk_ahead _mk_behind
  _mk_up="${HERD_REMOTE:-origin}/${HERD_BRANCH_NAME:-main}"
  git -C "$MAIN" rev-parse --verify --quiet "$_mk_up" >/dev/null 2>&1 || return 0
  _mk_dirty="$(git -C "$MAIN" status --porcelain 2>/dev/null | cut -c4- | herd_strip_derived)"
  _mk_counts="$(git -C "$MAIN" rev-list --left-right --count "HEAD...$_mk_up" 2>/dev/null || true)"
  _mk_ahead="$(printf '%s' "$_mk_counts" | awk '{print $1}')"
  _mk_behind="$(printf '%s' "$_mk_counts" | awk '{print $2}')"
  case "${_mk_ahead:-x}${_mk_behind:-x}" in ''|*[!0-9]*) return 0 ;; esac

  # PROVABLE FRESHNESS — clean AND 0-behind AND 0-ahead: the hold's condition is observably gone.
  if [ -z "$_mk_dirty" ] && [ "$_mk_ahead" -eq 0 ] && [ "$_mk_behind" -eq 0 ]; then
    _main_fresh_recovered
    return 0
  fi

  # Cannot clear → re-derive the line so its counts never freeze. Dirty tree wins (it is why the reconcile
  # would refuse to pull), else a clean, ahead, non-generated-only divergence is the `local-commits` hold.
  if [ -n "$_mk_dirty" ]; then
    _main_fresh_hold dirty-tree "$_mk_behind" "$_mk_ahead"
    return 0
  fi
  if [ "$_mk_ahead" -gt 0 ] && ! _main_fresh_generated_only "$_mk_up"; then
    _main_fresh_hold local-commits "$_mk_behind" "$_mk_ahead"
    return 0
  fi
  # Anything else (clean ff-able behind, generated-only divergence, a prior heal failure) is left for the
  # reconcile below the defer to re-decide once it can fetch and heal.
  return 0
}

# _main_fresh_hold <reason> <behind> <ahead> — surface an unhealable divergence: persist the row and
# journal it ONCE (a reason that has not changed since the last tick paints, but does not re-journal).
_main_fresh_hold() {
  local _mh_reason="$1" _mh_b="$2" _mh_a="$3" _mh_line _mh_prev
  _mh_line="$_mh_reason $_mh_b $_mh_a"
  _mh_prev="$(cat "$MAIN_FRESH_STATE" 2>/dev/null || true)"
  mkdir -p "$TREES" 2>/dev/null || true
  printf '%s\n' "$_mh_line" > "$MAIN_FRESH_STATE" 2>/dev/null || true
  [ "$_mh_prev" = "$_mh_line" ] && return 0
  journal_append main_freshness result held reason "$_mh_reason" behind "$_mh_b" ahead "$_mh_a"
  return 0
}

# _main_fresh_generated_only <upstream-ref> — success iff the local-only commits (merge-base..HEAD)
# touch NOTHING but the engine's own regenerable maps. A git failure returns 1 (never guess); an
# empty delta returns 0 (a rebase can lose nothing). This is the ONLY gate on the auto-heal path.
_main_fresh_generated_only() {
  local _mg_out
  _mg_out="$(git -C "$MAIN" diff --name-only "${1}...HEAD" 2>/dev/null)" || return 1
  [ -n "$_mg_out" ] || return 0
  printf '%s\n' "$_mg_out" | grep -qvxE 'docs/(codemap|symbol-index)\.md' && return 1  # pipe-ok: bounded membership list, under a pipe buffer
  return 0
}

# _main_fresh_note_restart <old-sha> <new-sha> — success (and leave a note) iff the pulled delta
# rewrote agent-watch.sh: the running watcher is now executing code $MAIN no longer holds. The note is
# also the ARM signal for the HERD-251 self-restart quiesce (see _self_restart_tick); $_SELF_RESTART_FROM
# carries the pre-pull sha the note file itself cannot hold, for the journal's shas=<old>..<new> field.
_main_fresh_note_restart() {
  git -C "$MAIN" diff --name-only "$1" "$2" 2>/dev/null \
    | grep -qx 'scripts/herd/agent-watch.sh' || return 1  # pipe-ok: bounded membership list, under a pipe buffer
  mkdir -p "$TREES" 2>/dev/null || true
  printf '%s\n' "$2" > "$MAIN_FRESH_RESTART" 2>/dev/null || true
  _SELF_RESTART_FROM="$1"
  return 0
}

# _main_reattach_if_detached — HERD-336 shared-checkout invariant. Returns 0 when $MAIN's HEAD is
# ATTACHED (the caller proceeds); returns 1 when it was DETACHED and handled this tick (the caller must
# stop — the next tick reconciles on the reattached branch). A detached HEAD in the shared checkout is
# never a human's deliberate state (a human parks on a NAMED branch); it is the refresh-race corpse that
# once sat detached until a human `git pull` failed. Journals main_detached ONCE per detached sha
# (deduped via $MAIN_DETACHED_STATE so a persisting detachment does not spam), then reattaches to the
# default branch IFF every commit the detached HEAD holds beyond origin is one of our own regenerable
# maps (or there are none) — a detached HEAD carrying a human's real commit is journaled but LEFT for a
# human, never silently discarded. Fully fail-soft.
_main_reattach_if_detached() {
  local _rd_sref _rd_head _rd_up _rd_prev
  _rd_sref="$(git -C "$MAIN" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -n "$_rd_sref" ]; then
    rm -f "$MAIN_DETACHED_STATE" 2>/dev/null || true    # attached → clear any prior detached row
    return 0
  fi
  _rd_head="$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
  _rd_up="${HERD_REMOTE:-origin}/${HERD_BRANCH_NAME:-main}"
  _rd_prev="$(cat "$MAIN_DETACHED_STATE" 2>/dev/null || true)"
  if [ "$_rd_prev" != "$_rd_head" ]; then
    mkdir -p "$TREES" 2>/dev/null || true
    printf '%s\n' "$_rd_head" > "$MAIN_DETACHED_STATE" 2>/dev/null || true
    _journal_main_detached detected "$_rd_head"
  fi
  # Reattach only when the detached commits beyond origin are our own regenerable maps (or none).
  if git -C "$MAIN" rev-parse --verify --quiet "$_rd_up" >/dev/null 2>&1 \
     && _main_fresh_generated_only "$_rd_up"; then
    if _reattach_default_branch; then
      _journal_main_detached reattached "$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
      rm -f "$MAIN_DETACHED_STATE" 2>/dev/null || true
    fi
  fi
  return 1
}

# reconcile_main_freshness — the HERD-233 tick-level invariant. Call once per watcher tick, before
# the map reconcile (so the maps are probed against a fresh HEAD). Safe to call repeatedly.
reconcile_main_freshness() {
  local _mf_up _mf_head _mf_new _mf_counts _mf_ahead _mf_behind _mf_dirty _mf_restart=no _mf_sref
  [ -n "${DRYRUN:-}" ] && return 0
  [ -n "${MAIN:-}" ] || return 0
  { [ -d "$MAIN/.git" ] || [ -f "$MAIN/.git" ]; } || return 0
  # A $MAIN parked on some other NAMED branch is a human's deliberate state — out of scope, not an
  # alarm. A DETACHED HEAD (symbolic-ref empty) is different: HERD-336's refresh-race corpse, handled
  # below the read-only recheck and the gate defer.
  _mf_sref="$(git -C "$MAIN" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -n "$_mf_sref" ] && [ "$_mf_sref" != "${HERD_BRANCH_NAME:-}" ]; then
    return 0
  fi
  # HERD-259: a standing held row is re-derived from observed git state BEFORE any defer below it —
  # a recovered $MAIN must clear its row on the very next tick even while a gate owns the tree or the
  # fetch is failing. Read-only, and a no-op when no row is held.
  _main_fresh_recheck
  # A live gate owns the tree this tick — defer silently; the next tick reconciles.
  _watch_gate_inflight && return 0
  # HERD-336: a detached shared checkout — journal + reattach (when the detached commits are only our
  # regenerable maps), then defer the rest of the reconcile to the next tick on the reattached branch.
  if [ -z "$_mf_sref" ]; then
    _main_reattach_if_detached || return 0
  fi

  _mf_up="${HERD_REMOTE:-origin}/${HERD_BRANCH_NAME:-main}"
  # Fail-soft: a fetch failure NEVER blocks the tick and never alarms (offline, or a gh/network blip
  # the gates already surface). The comparison below is only honest against a fetched ref, so bail.
  git -C "$MAIN" fetch --quiet "${HERD_REMOTE:-origin}" "${HERD_BRANCH_NAME:-main}" >/dev/null 2>&1 \
    || return 0
  git -C "$MAIN" rev-parse --verify --quiet "$_mf_up" >/dev/null 2>&1 || return 0
  _mf_head="$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$_mf_head" ] || return 0

  # "<ahead>\t<behind>" — commits only on HEAD, commits only on the remote branch.
  _mf_counts="$(git -C "$MAIN" rev-list --left-right --count "HEAD...$_mf_up" 2>/dev/null || true)"
  _mf_ahead="$(printf '%s' "$_mf_counts" | awk '{print $1}')"
  _mf_behind="$(printf '%s' "$_mf_counts" | awk '{print $2}')"
  case "${_mf_ahead:-x}${_mf_behind:-x}" in ''|*[!0-9]*) return 0 ;; esac

  # FRESH → byte-inert.
  if [ "$_mf_ahead" -eq 0 ] && [ "$_mf_behind" -eq 0 ]; then
    _main_fresh_clear; return 0
  fi

  # A dirty tree means a human (or a concurrent writer) owns $MAIN: never pull over their work.
  # Regenerable derived files are excused from the same ONE list every reaper/gate uses.
  _mf_dirty="$(git -C "$MAIN" status --porcelain 2>/dev/null | cut -c4- | herd_strip_derived)"
  if [ -n "$_mf_dirty" ]; then
    _main_fresh_hold dirty-tree "$_mf_behind" "$_mf_ahead"; return 0
  fi

  # Strictly BEHIND + clean → fast-forward. The one healing path the watcher takes unprompted.
  if [ "$_mf_ahead" -eq 0 ]; then
    if git -C "$MAIN" merge --ff-only --quiet "$_mf_up" >/dev/null 2>&1; then
      _mf_new="$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
      _main_fresh_note_restart "$_mf_head" "$_mf_new" && _mf_restart=yes
      journal_append main_ff behind "$_mf_behind" from "$_mf_head" to "$_mf_new" restart "$_mf_restart"
      _main_fresh_clear
    else
      _main_fresh_hold ff-failed "$_mf_behind" 0
    fi
    return 0
  fi

  # AHEAD (diverged, or the unpushed `pushed=no` corpse): heal ONLY when every local commit is one
  # of our own regenerable map refreshes. Anything a human wrote is held, never rebased behind their back.
  if ! _main_fresh_generated_only "$_mf_up"; then
    _main_fresh_hold local-commits "$_mf_behind" "$_mf_ahead"; return 0
  fi
  if [ "$_mf_behind" -gt 0 ]; then
    if ! git -C "$MAIN" rebase --quiet "$_mf_up" >/dev/null 2>&1; then
      git -C "$MAIN" rebase --abort >/dev/null 2>&1 || true
      _main_fresh_hold rebase-failed "$_mf_behind" "$_mf_ahead"; return 0
    fi
  fi
  if git -C "$MAIN" push --quiet "${HERD_REMOTE:-origin}" "${HERD_BRANCH_NAME:-main}" >/dev/null 2>&1; then
    _mf_new="$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
    _main_fresh_note_restart "$_mf_head" "$_mf_new" && _mf_restart=yes
    journal_append main_heal ahead "$_mf_ahead" behind "$_mf_behind" result pushed restart "$_mf_restart"
    _main_fresh_clear
  else
    # Push refused (protected branch or an unresolvable race). The local commits are only
    # regenerable maps — stranding them breaks herd update forever (ff-only dies). Drop them with a
    # hard reset to the remote ref. The maps are deterministic and regenerable; losing them costs
    # nothing and makes the seat clean again on this tick.
    git -C "$MAIN" reset --hard "${_mf_up}" >/dev/null 2>&1 || true
    journal_append main_freshness result error reason push-rejected-reset \
      ahead "$_mf_ahead" behind "$_mf_behind"
    _main_fresh_clear
  fi
  return 0
}

# ── Shared-checkout cleanliness invariant (HERD-361) ──────────────────────────────────────────────
# Multi-seat doctrine Rule 1: the shared checkout ($MAIN) must be ATTACHED to the default branch with
# NO staged changes and no tracked modifications other than the derived docs a refresh commit absorbs.
# A violation is the fingerprint of a suite test (or any tool) that staged/stashed in $PWD while running
# FROM the shared checkout — exactly the HERD-361 contamination (PR #466's whole diff found staged in
# $MAIN, byte-identical to the builder's commit). reconcile_main_freshness returns clean the instant
# $MAIN is at origin (ahead=0 behind=0) BEFORE it looks at the tree, so a staged-but-otherwise-fresh
# checkout slips past it — this check closes that hole by keying off observed git state EVERY tick,
# independent of any merge event, so it fires no matter which seat caused it.
#
# ADVISORY + EVIDENCE-PRESERVING: a loud console row (build_checkout_cleanliness) + one journal event
# naming the offending paths. It NEVER discards (no git reset/checkout/clean) — the staged diff is the
# evidence a human needs to root-cause. Deduped per (head + detached + path-set) so a standing violation
# journals once; the console row paints every tick it stands. Fully fail-soft; never blocks a tick.

# _checkout_offenders — emit, one repo-relative path per line, every $MAIN path that is STAGED (index
# differs from HEAD) or tracked-MODIFIED in the worktree, EXCLUDING untracked scratch (?? — not a
# tracked modification) and the regenerable derived files a refresh commit legitimately owns (the
# render/config-local set via herd_strip_derived, plus docs/codemap.md + docs/symbol-index.md).
_checkout_offenders() {
  git -C "$MAIN" status --porcelain 2>/dev/null | while IFS= read -r _co_line; do
    [ -n "$_co_line" ] || continue
    local _co_xy="${_co_line:0:2}" _co_x="${_co_line:0:1}" _co_y="${_co_line:1:1}" _co_path="${_co_line:3}"
    case "$_co_xy" in '??'*) continue ;; esac      # untracked — neither staged nor a tracked modification
    # Staged iff the index column is not blank; tracked-worktree-modified iff the worktree column is not blank.
    if [ "$_co_x" != ' ' ] || [ "$_co_y" != ' ' ]; then
      case "$_co_path" in *' -> '*) _co_path="${_co_path##* -> }" ;; esac   # rename "orig -> new" → report new
      printf '%s\n' "$_co_path"
    fi
  done | herd_strip_derived | grep -vxE 'docs/(codemap|symbol-index)\.md' || true
}

# reconcile_checkout_cleanliness — call once per watcher tick (after the freshness reconciles so it
# reads the ff'd HEAD). Safe to call repeatedly; byte-inert on a clean checkout (no state file, no
# journal, no row). A $MAIN parked on some OTHER named branch is a human's deliberate state → out of
# scope. A DETACHED HEAD is itself a violation of "attached to the default branch" (reconcile_main_
# freshness owns the reattach; here it is only recorded as part of the cleanliness signal — never
# discarded). Records the violation signature to $CHECKOUT_CLEAN_STATE for the row and dedups the journal.
reconcile_checkout_cleanliness() {
  [ -n "${DRYRUN:-}" ] && return 0
  [ -n "${MAIN:-}" ] || return 0
  { [ -d "$MAIN/.git" ] || [ -f "$MAIN/.git" ]; } || return 0
  local _cc_sref _cc_head _cc_detached="" _cc_offenders _cc_key _cc_prev _cc_paths
  _cc_sref="$(git -C "$MAIN" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -n "$_cc_sref" ] && [ "$_cc_sref" != "${HERD_BRANCH_NAME:-main}" ]; then
    rm -f "$CHECKOUT_CLEAN_STATE" 2>/dev/null || true        # parked on another branch → out of scope, clear
    return 0
  fi
  [ -z "$_cc_sref" ] && _cc_detached="detached"
  _cc_head="$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$_cc_head" ] || return 0
  _cc_offenders="$(_checkout_offenders)"
  # Clean AND attached → drop any standing row (byte-inert happy path).
  if [ -z "$_cc_offenders" ] && [ -z "$_cc_detached" ]; then
    rm -f "$CHECKOUT_CLEAN_STATE" 2>/dev/null || true
    return 0
  fi
  # Dedup the journal per (head + detached + offender-set); the console row is re-derived each tick.
  _cc_key="$_cc_head|${_cc_detached:-attached}|$(printf '%s' "$_cc_offenders" | tr '\n' ',')"
  _cc_prev="$(sed -n '1p' "$CHECKOUT_CLEAN_STATE" 2>/dev/null || true)"
  mkdir -p "$TREES" 2>/dev/null || true
  # State file: line 1 = dedup signature; line 2 = head; line 3 = detached flag; lines 4+ = offenders.
  {
    printf '%s\n' "$_cc_key"
    printf '%s\n' "$_cc_head"
    printf '%s\n' "${_cc_detached:-attached}"
    [ -n "$_cc_offenders" ] && printf '%s\n' "$_cc_offenders"
  } > "$CHECKOUT_CLEAN_STATE" 2>/dev/null || true
  [ "$_cc_prev" = "$_cc_key" ] && return 0                   # unchanged since last tick → paint, don't re-journal
  _cc_paths="$(printf '%s' "$_cc_offenders" | tr '\n' ' ')"
  journal_append checkout_unclean head "$_cc_head" \
    detached "${_cc_detached:-no}" \
    paths "${_cc_paths:-none}" \
    result violation component audit
  return 0
}

# ── Tick-level map-freshness reconcile (HERD-218) ─────────────────────────────────────────────────
# Multi-seat doctrine Rule 1: map freshness is a RECONCILED INVARIANT, not a do_merge side-effect.
# refresh_codemap / refresh_symbol_index still fire on THIS seat's merges (fast path). When another
# seat (or the gh UI) merges without this watcher's do_merge, the committed maps can drift until a
# human runs `herd codemap`. This tick-level reconcile heals that: probe with the read-only
# --check seams, and only when STALE regenerate+commit ONCE with provenance=reconcile.
#
# HARD INVARIANTS:
#   • CODEMAP_AUTOREFRESH=off → byte-inert (no pull, no probe, no commit, no journal).
#   • Maps already fresh at this $MAIN HEAD → zero commits (and, after the first probe of a sha,
#     zero re-scans — memoized on $TREES/.codemap-reconcile-sha).
#   • Race-guarded: skip quietly when a review/health gate is mid-op (live inflight marker) OR $MAIN
#     is dirty (a concurrent writer owns the tree). Never double-commits with do_merge: after a local
#     merge the maps are fresh, so the probe no-ops; the sha memo prevents re-probe until HEAD moves.
# Fully fail-soft; never blocks a tick.

# _map_reconcile_mid_op — true when a builder/gate is mid-flight OR $MAIN has any uncommitted NON-map
# change, so the tick-level map reconcile must defer (no double-commit; never step on an in-flight op).
# HERD-336: a dirty docs/codemap.md / docs/symbol-index.md is EXCUSED — those are the maps this reconcile
# itself owns, and a stranded dirty one (the live symbol-index corpse) must NOT block the reconcile that
# would ABSORB it forever; refresh_codemap / refresh_symbol_index fold it into their next regen commit.
_map_reconcile_mid_op() {
  _watch_gate_inflight && return 0
  # Any dirty NON-derived-map path on $MAIN → a concurrent writer (or a partial write) owns the tree.
  [ -n "$(git -C "$MAIN" status --porcelain 2>/dev/null | grep -vE ' docs/(codemap|symbol-index)\.md$')" ] && return 0
  return 1
}

# _map_reconcile_memo_file — per-watcher memo of the last $MAIN HEAD we probed for map freshness.
_map_reconcile_memo_file() { printf '%s' "$TREES/.codemap-reconcile-sha"; }

# _map_reconcile_memo_write <sha> — record that this main sha has been reconciled (fresh or repaired).
_map_reconcile_memo_write() {
  local _mw="$1"
  [ -n "$_mw" ] || return 0
  mkdir -p "$TREES" 2>/dev/null || true
  printf '%s\n' "$_mw" > "$(_map_reconcile_memo_file)" 2>/dev/null || true
}

# reconcile_map_freshness — the HERD-218 tick-level invariant. Call once per watcher tick (or on a
# cadence); safe to call repeatedly. Picks up out-of-band merges via ff-only pull, probes both
# adopted maps with their --check seams, and repairs only when stale.
reconcile_map_freshness() {
  local _rm_head _rm_memo _rm_prev _rm_stale=0
  [ -n "${DRYRUN:-}" ] && return 0
  case "$(_codemap_auto)" in
    false) return 0 ;;   # HARD: off → byte-inert (no journal spam either)
  esac
  [ -n "${MAIN:-}" ] || return 0
  { [ -d "$MAIN/.git" ] || [ -f "$MAIN/.git" ]; } || return 0

  # Race: a live gate or a dirty $MAIN means someone else owns the tree this tick — defer.
  _map_reconcile_mid_op && return 0

  # Pick up out-of-band merges into $MAIN (another seat's do_merge / gh UI). Never force.
  git -C "$MAIN" pull --ff-only >/dev/null 2>&1 \
    || git -C "$MAIN" fetch --all >/dev/null 2>&1 || true

  # Re-check mid-op after the pull (a concurrent writer may have dirtied $MAIN mid-fetch).
  _map_reconcile_mid_op && return 0

  _rm_head="$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$_rm_head" ] || return 0
  _rm_memo="$(_map_reconcile_memo_file)"
  _rm_prev="$(cat "$_rm_memo" 2>/dev/null || true)"
  # Already probed/repaired this exact main sha → zero work (no scan, no commit).
  [ "$_rm_prev" = "$_rm_head" ] && return 0

  # ── codemap probe (read-only --check) ──────────────────────────────────────────────────────────
  if [ -f "$HERE/codemap.sh" ] && [ -f "$MAIN/docs/codemap.md" ]; then
    if ! HERD_CODEMAP_ROOT="$MAIN" HERD_CODEMAP_OUT="$MAIN/docs/codemap.md" \
         bash "$HERE/codemap.sh" --check >/dev/null 2>&1; then
      _rm_stale=1
      # Stale → regenerate+commit ONCE via the shared refresh primitive, tagged provenance=reconcile.
      # Empty pr# (no single PR caused this; an out-of-band merge did).
      refresh_codemap "" "reconcile"
    fi
  fi

  # ── symbol-index probe (read-only --check) ─────────────────────────────────────────────────────
  if [ -f "$HERE/symbol-index.sh" ] && [ -f "$MAIN/docs/symbol-index.md" ]; then
    if ! HERD_SYMBOL_INDEX_ROOT="$MAIN" HERD_SYMBOL_INDEX_OUT="$MAIN/docs/symbol-index.md" \
         bash "$HERE/symbol-index.sh" --check >/dev/null 2>&1; then
      _rm_stale=1
      refresh_symbol_index "" "reconcile"
    fi
  fi

  # Memoize the post-repair HEAD (a successful commit advances it). Only memoize when $MAIN is clean
  # — a failed/deferred refresh that left the tree dirty must NOT suppress the next tick's retry.
  if [ -z "$(git -C "$MAIN" status --porcelain 2>/dev/null)" ]; then
    _rm_head="$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
    _map_reconcile_memo_write "$_rm_head"
  fi
  # _rm_stale is load-bearing for tests that inspect the function's side effects only; silence SC2034.
  : "$_rm_stale"
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
  # HERD-157 F9 backstop: purge any step-hold rows + detail files for this reaped slug. A reaped
  # worktree is terminal, so a lingering 'awaiting' step-hold row would haunt `herd-approve.sh list`
  # forever (the step-hold analogue of purge_pr_approvals). Fail-soft + idempotent; no-op when steps
  # are unused. Done before teardown so a teardown hiccup can't strand the phantom hold.
  command -v steps_hold_purge >/dev/null 2>&1 && steps_hold_purge "$_rp_slug" || true
  # HERD-162 F7: the slug is terminal — close every slug-keyed ledger row it opened (dead anchor,
  # respawn budget, limit target, sendkeys dedup). Slugs are reused by design, so a row that outlives
  # its builder is inherited by the reincarnation: a stale limit target injects `claude --continue`
  # into a healthy fresh builder, a stale dead anchor 💀s it on tick one, a spent respawn budget denies
  # it the one restart it is owed. Idempotent + fail-soft; runs BEFORE the tabs close, so a teardown
  # hiccup can never strand the rows (same reasoning as the step-hold purge above).
  _purge_slug_ledgers "$_rp_slug" "$_rp_dir"
  journal_append reap pr "$_rp_pr" slug "$_rp_slug" sha "$_rp_sha" reason "$_rp_reason"
  herd_teardown_slug "$_rp_slug"
  return 0
}

# ── Post-merge main-health tick (HERD-129) ─────────────────────────────────────────────────────────
# Catch a RED default branch AT MERGE TIME. The pre-merge health gate proves each PR green in
# ISOLATION, but two independently-green PRs can merge into a broken COMBINATION — the #226 advise
# exit-code collision (2026-07-08) left main red ~2h, found only when later unrelated PRs #238/#239
# inherited the failure. So after every merge we run the healthcheck suite against the freshly ff'd
# default-branch HEAD and, on a reproduced red, raise a LOUD persistent 'MAIN RED' console row +
# notification — cleared the moment a later sha goes green.
#
# This is an ALARM, never a gate: it runs AFTER the merge has landed and never blocks, reverts, or
# re-merges anything (mirrors the 2b/2c codemap/symbol-index hooks' best-effort posture). Gated by
# MAIN_HEALTH_TICK (default off) → byte-inert when unset: no suite, no journal, no state file, so
# build_main_health finds nothing and the console renders byte-identically. Fully fail-soft: a suite
# that cannot even run (no HEAD, no slot, no bin) journals an infra_event and never paints a red row,
# and a tab-leak-guard trip is treated as the same transient the pre-merge gate already tolerates.
# ── MAIN-HEALTH AS A RECONCILED INVARIANT (HERD-222) ──────────────────────────────────────────────
# Multi-seat doctrine Rule 1, applied to main-health exactly as HERD-233 applied it to $MAIN freshness:
# "every observed main sha has a collected health verdict" is an INVARIANT reconciled once per tick, not
# a do_merge side-effect. The event-only tick had three holes, all observed on main:
#   • a merge by ANOTHER seat (or the gh UI) never ran main_health_tick at all — main could sit red, or
#     stay falsely red after a fix landed, until THIS watcher happened to merge something;
#   • a no-slot deferral was retried only on the NEXT MERGE, so the day's last merge went un-ticked;
#   • a worker KILLED mid-suite (restart, corpse sweep) left its sha with no verdict and no re-dispatch —
#     it never wrote the run-once marker, but nothing ever looked at the sha again.
# reconcile_main_health closes all three by dispatching whenever the CURRENT $MAIN HEAD has no marker,
# whoever merged it. do_merge's main_health_tick call survives as the fast path: it is now
# redundant-but-harmless, since the per-sha marker + the inflight/dispatch idempotency guards make the
# reconciler a no-op for a sha the merge tick already dispatched.
#
# Two new levers, both SHIP-DORMANT (default off → byte-identical to the pre-HERD-222 engine):
#   • MAIN_HEALTH_RECHECK_MINS — while the red state file stands, RE-VERIFY the CURRENT sha on this
#     rate-limited cadence, so a red that was already fixed (or was never real) self-heals through the
#     existing green→clear path instead of shouting for 19 hours.
#   • MAIN_HEALTH_AUTOFIX — on a REPRODUCED red with an HONEST failing-test identity, enqueue ONE scribe
#     item naming that test. It files work; it does NOT spawn a builder in this increment.
MAIN_HEALTH_STATE="$TREES/.agent-watch-main-health"        # one line while RED, fields joined by US (0x1f):
                                                            # "<sha>US<since_pr>US<local identity>US<CI identity>"
                                                            # (HERD-372: two SEPARATE identity fields, so a
                                                            # branch-CI red merges into, never replaces, a
                                                            # standing local-suite identity, and vice versa).
                                                            # US, NOT a tab: the local/CI field is EMPTY
                                                            # whenever only one identity is standing, and tab
                                                            # is IFS-whitespace — `read` would collapse the
                                                            # empty field and shift every later column (mirrors
                                                            # governance-drift-sweep.sh's SEP). Failing-test
                                                            # identities are plain text and never contain US.
MAIN_HEALTH_DEFER="$TREES/.agent-watch-main-health-defer"  # "<sha> <reason>" — the last journaled defer
# The AUTOFIX filed-identity marker is no longer a bare seat-local flat file (HERD-371): it lives in the
# SHARED POOL through pysrc/herd/store.py's main_health_fix_* accessors (see _main_health_fix_mark /
# _main_health_fix_clear below) so every seat sees the same "already filed" state, not just this process.
MAIN_HEALTH_CI_STATE="$TREES/.agent-watch-main-health-ci"  # "<sha> <conclusion>" — the last branch-CI red we fired (HERD-334)

# Throttle the branch-CI probe (HERD-334 leg b): one `gh run list` every ~40 s (10 × 4 s sleep) instead
# of every tick, so the steady-state network profile barely moves. Inline constant — no config key
# (mirrors _MAIN_HEALTH_DIED_MAX / _ENGINE_INTERVAL). Byte-inert when MAIN_HEALTH_TICK=off.
_MAIN_CI_SCAN_INTERVAL=10

# A worker that keeps DYING before it can collect must not be re-dispatched forever: after this many
# consecutive deaths the sha is marked (run-once) and the deaths surface as an infra_event instead of a
# per-tick suite. Inline constant on purpose — no new config key (mirrors _HEALTH_INFRA_REDISPATCH_MAX).
_MAIN_HEALTH_DIED_MAX=2

# _main_health_enabled — true iff MAIN_HEALTH_TICK opts in. Default OFF (the inverse of the
# CODEMAP_AUTOREFRESH default-on lever); any unrecognized value reads as off (fail toward dormant).
_main_health_enabled() {
  case "$(printf '%s' "${MAIN_HEALTH_TICK:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _main_health_recheck_mins — the RED re-verify cadence in whole minutes, or 0 (the default) for OFF.
# A non-numeric value reads as 0: a typo can never turn a dormant lever on.
_main_health_recheck_mins() {
  case "${MAIN_HEALTH_RECHECK_MINS:-0}" in
    ''|*[!0-9]*) printf '0' ;;
    *)           printf '%s' "$MAIN_HEALTH_RECHECK_MINS" ;;
  esac
}

# _main_health_autofix_enabled — true iff MAIN_HEALTH_AUTOFIX opts in. Default OFF (ship-dormant).
_main_health_autofix_enabled() {
  case "$(printf '%s' "${MAIN_HEALTH_AUTOFIX:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _main_health_marker <sha> — the per-sha run-once marker (mirrors the sha-keyed .health-result cache):
# a main sha whose marker exists has ALREADY been ticked, so a re-entrant merge tick / watcher restart
# never re-runs the suite for the same commit.
_main_health_marker() { printf '%s' "$TREES/.main-health-$1"; }
# _main_health_pr_file <sha> — sidecar recording the MERGING pr# for an in-flight main-health run, so
# the collector (a later, possibly RESTARTED tick) can attribute the 'since #N' / recovery correctly
# even though the pr# is not in the sha-keyed marker/dispatch filenames.
_main_health_pr_file() { printf '%s' "$TREES/.main-health-pr-$1"; }
# _main_health_retry_file <sha> — how many times a worker for this sha DIED before collecting.
_main_health_retry_file() { printf '%s' "$TREES/.main-health-died-$1"; }

# _main_health_observed_pr <sha> — the PR number this sha landed as, read from its own commit subject.
# This is the ONLY attribution available for a merge THIS seat never performed. Empty when the commit
# names no PR — the caller then records "?" and the console row says "(observed)", never a made-up number.
#
# A TRAILING "(#N)" wins over any earlier "#N". GitHub's squash subject is "<title> (#456)", and a title
# may itself cite an issue — "Fix #123 widget handling (#456)" — where the first match names the ISSUE,
# not the PR. Merge-commit subjects ("Merge pull request #456 from …") carry no trailing form, so they
# fall through to the first-match rule unchanged.
_main_health_observed_pr() {
  local _op_subj _op_n
  _op_subj="$(git -C "$MAIN" log -1 --format='%s' "$1" 2>/dev/null)"
  _op_n="$(printf '%s\n' "$_op_subj" | grep -oE '\(#[0-9]+\)[[:space:]]*$' | grep -oE '[0-9]+')"
  [ -n "$_op_n" ] || _op_n="$(printf '%s\n' "$_op_subj" | grep -oE '#[0-9]+' | sed -n '1p' | tr -d '#')"
  printf '%s' "$_op_n"
}

# _main_health_worker <sha> <dispatch-file> <log-file> — the ASYNC main-health suite, run in the
# BACKGROUND by main_health_tick so a post-merge heavy suite (the LONGEST the watcher runs) never blocks
# the tick. Runs the FULL (heavy) suite against $MAIN STREAMING to the tailable log, with the same
# retry-before-red the pre-merge gate uses, then writes "<rc>\t<detail>" atomically for the collector to
# route. On a reproduced red, <detail> is the FIRST 'not ok' TAP line (HERD-173 honest label; the
# tab-leak-guard line is preserved when present so the collector's transient exemption still fires).
# (see the always-heavy note below)
_main_health_worker() {
  local _mw_sha="$1" _mw_out="$2" _mw_log="$3" _mw_rc _mw_detail
  bash "$HERD_HEALTHCHECK_BIN" "$MAIN" --heavy > "$_mw_log" 2>&1; _mw_rc=$?
  if [ "$_mw_rc" -eq 1 ]; then
    bash "$HERD_HEALTHCHECK_BIN" "$MAIN" --heavy > "$_mw_log.retry" 2>&1; _mw_rc=$?
    mv "$_mw_log.retry" "$_mw_log" 2>/dev/null || true
  fi
  if [ "$_mw_rc" -eq 1 ]; then
    _mw_detail="$(_health_leak_guard_line "$_mw_log")"
    [ -n "$_mw_detail" ] || _mw_detail="$(_health_fail_detail "$_mw_log")"
  else
    _mw_detail="$(sed -n '1p' "$_mw_log" 2>/dev/null)"
  fi
  _mw_detail="$(printf '%s' "$_mw_detail" | tr '\t\n' '  ')"; _mw_detail="${_mw_detail:0:200}"
  printf '%s\t%s\n' "$_mw_rc" "$_mw_detail" > "$_mw_out.tmp.$$" 2>/dev/null && mv "$_mw_out.tmp.$$" "$_mw_out" 2>/dev/null || true
}

# WHY the tick is ALWAYS heavy (never light) — a review-caught correctness trap. The 'light' profile
# derives its file set from healthcheck.sh's `git diff --name-only $DEFAULT_BRANCH` run INSIDE the dir
# it checks; against $MAIN — which IS the default-branch checkout — that diff is EMPTY, so light checks
# ZERO files and returns a vacuous rc-0 ("✅ light clean — 0 sh, 0 py ok") no matter what state main is
# actually in. Routing that vacuous rc-0 to _main_health_clear would WIPE a real MAIN RED and fire a
# false 'recovered' the next time a docs/BACKLOG/config merge (any diff not matching
# HEALTHCHECK_HEAVY_GLOB) landed. A light subset is categorically meaningless on a zero-diff tree, so a
# main-health tick must run the FULL suite every time: we pass --heavy unconditionally. (For a project
# with no HEALTHCHECK_CMD, healthcheck.sh's --heavy falls back to light anyway — but such a project
# also never paints red, so there is nothing to falsely clear.)

# _main_health_clear <pr#> <sha> [kind=local|ci] — a main sha went GREEN in the given SCOPE (HERD-372:
# "local" for the healthcheck suite, "ci" for the branch-CI leg; local is the default so the existing
# single caller — the local-suite collector — needs no change). SCOPE-AWARE: clears only the identity
# field owned by <kind>, and CLEARS the shared-pool autofix marker for THAT identity only (HERD-371: so
# a LATER regression of the SAME test files fresh). If the OTHER identity is still standing red, the
# row stays up unchanged and NOTHING re-fires for it — a local-suite green must never mask (or churn) a
# live branch-CI red, and a CI recovery must never mask a live local red. Only when BOTH identities are
# now clear does the state file drop, the green result journal, and (on a RED→green TRANSITION) recovery
# notify once. Byte-identical to the pre-HERD-372 behavior whenever only one identity ever existed.
_main_health_clear() {
  local _mc_pr="$1" _mc_sha="$2" _mc_kind="${3:-local}"
  local _mc_pv_sha="" _mc_pv_since="" _mc_pv_local="" _mc_pv_ci="" _mc_own="" _mc_other=""
  if [ -s "$MAIN_HEALTH_STATE" ]; then
    IFS=$'\x1f' read -r _mc_pv_sha _mc_pv_since _mc_pv_local _mc_pv_ci < "$MAIN_HEALTH_STATE" 2>/dev/null || true
  fi
  case "$_mc_kind" in
    ci) _mc_own="$_mc_pv_ci"; _mc_other="$_mc_pv_local" ;;
    *)  _mc_own="$_mc_pv_local"; _mc_other="$_mc_pv_ci" ;;
  esac
  [ -n "$_mc_own" ] && _main_health_fix_clear "$_mc_own"
  if [ -n "$_mc_other" ]; then
    case "$_mc_kind" in
      ci) printf '%s\x1f%s\x1f%s\x1f%s\n' "$_mc_pv_sha" "$_mc_pv_since" "$_mc_other" ""           > "$MAIN_HEALTH_STATE" 2>/dev/null || true ;;
      *)  printf '%s\x1f%s\x1f%s\x1f%s\n' "$_mc_pv_sha" "$_mc_pv_since" ""           "$_mc_other" > "$MAIN_HEALTH_STATE" 2>/dev/null || true ;;
    esac
    [ -n "$_mc_own" ] && journal_append main_health pr "$_mc_pr" sha "$_mc_sha" result partial_clear kind "$_mc_kind"
    return 0
  fi
  rm -f "$MAIN_HEALTH_STATE" 2>/dev/null || true
  journal_append main_health pr "$_mc_pr" sha "$_mc_sha" result green
  if [ -n "$_mc_own" ]; then
    herd_driver_notify "✅ main green" "default branch health recovered at #${_mc_pr}" default
  fi
}

# _main_health_honest_identity <detail> <identity> — true iff this red names something a human (or a
# scribe item) can act on. The floor the AUTOFIX path must clear before it files work:
#   • a TAP 'not ok' line, or an identity that resolved to concrete test/source FILE tokens → honest;
#   • healthcheck.sh's content-free classifier banner ("❌ CODE ERROR"), a PASS-marked line that slipped
#     through, or an empty identity → NOT honest: filing "fix ❌ CODE ERROR" is the exact cry-wolf this
#     item exists to remove, so we stay silent and leave the loud console row to a human.
#
# The leak-guard test below is REDUNDANT with _collect_main_health, which already routes a genuine trip to
# an infra_event and so never reaches _main_health_set_red. It stays on purpose: this predicate is what
# stands between an infra transient and a tracker write, and _main_health_set_red is a seam any future
# caller may reach from a path that has not classified the detail. The check is a string match on one
# line — the cost of keeping the guarantee local is nil, and the cost of it being someone else's job is a
# spurious item filed against a control-room hiccup.
_main_health_honest_identity() {
  local _hi_detail="${1:-}" _hi_id="${2:-}"
  [ -n "$_hi_id" ] || return 1
  printf '%s\n' "$_hi_id" | grep -qiE "$_HFD_PASS_RE" 2>/dev/null && return 1  # pipe-ok: single short scalar (one line), far under a pipe buffer
  _health_is_leak_guard_detail "$_hi_detail" && return 1
  printf '%s\n' "$_hi_detail" | grep -qE '^[[:space:]]*not ok( |$)' 2>/dev/null && return 0  # pipe-ok: single short scalar (one line), far under a pipe buffer
  printf '%s\n' "$_hi_id" | grep -qE '[A-Za-z0-9_./-]+\.(sh|bats|py|go|ts|js|jsx|tsx|rs|java|rb)' 2>/dev/null  # pipe-ok: single short scalar (one line), far under a pipe buffer
}

# _main_health_scribe <text> — the ENQUEUE edge of the autofix path, isolated in one function so a test
# can spy on it without spawning a real drainer. Best-effort by construction: an alarm never fails a tick.
_main_health_scribe() { bash "$HERE/scribe.sh" "$1" >/dev/null 2>&1 || true; }

# _main_health_fix_pysrc — locate pysrc/ for the store-accessor shellout below (mirrors
# herd_engine_live_tick's HERDKIT_HOME resolution in engine-version.sh), or empty when the module cannot
# be found — every caller then fails soft (dedup treated as "skip filing", never a crash).
_main_health_fix_pysrc() {
  local _fp_home _fp_pyp
  _fp_home="${HERDKIT_HOME:-$(cd "$HERE/../.." 2>/dev/null && pwd)}"
  _fp_pyp="$_fp_home/pysrc"
  [ -f "$_fp_pyp/herd/store.py" ] && printf '%s' "$_fp_pyp"
}

# _main_health_fix_mark <identity> <pr> <sha> — ATOMIC claim-or-abort against the SHARED-POOL marker
# (pysrc/herd/store.py main_health_fix_*, HERD-371). Returns the store CLI's own rc so the caller can
# tell a genuine dedup from an infra failure:
#   0 ⇒ THIS call is the first across every seat to see this failing-test identity — file it.
#   3 ⇒ another seat (or an earlier tick on this seat) already filed for the SAME identity — dedup.
#   2 ⇒ no python3 / no store module / a store error — unknown, so the caller must NOT file (skip).
_main_health_fix_mark() {
  local _fm_id="$1" _fm_pr="$2" _fm_sha="$3" _fm_pyp
  _fm_pyp="$(_main_health_fix_pysrc)"
  [ -n "$_fm_pyp" ] || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$_fm_pyp" WORKTREES_DIR="${TREES:-}" \
    python3 -m herd.store --main-health-fix-mark "$_fm_id" --pr "$_fm_pr" --sha "$_fm_sha" >/dev/null 2>&1
  return $?
}

# _main_health_fix_clear <identity> — drop the shared-pool marker once main is GREEN for that identity, so
# a LATER regression of the same test files fresh. Best-effort; a failure here never blocks the green
# transition — worst case a stale marker suppresses one future re-file, which is the safe direction to
# fail (never a crash, never a double-file).
_main_health_fix_clear() {
  local _fc_id="$1" _fc_pyp
  [ -n "$_fc_id" ] || return 0
  _fc_pyp="$(_main_health_fix_pysrc)"
  [ -n "$_fc_pyp" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$_fc_pyp" WORKTREES_DIR="${TREES:-}" \
    python3 -m herd.store --main-health-fix-clear "$_fc_id" >/dev/null 2>&1 || true
  return 0
}

# _main_health_autofix <pr#> <sha> <identity> <detail> — MAIN_HEALTH_AUTOFIX (default off, ship-dormant).
# On a REPRODUCED red whose identity is honest, enqueue ONE scribe item citing the failing test and
# journal that we did. Scoped DELIBERATELY narrow for this increment: it FILES work, it never spawns a
# builder — an agent that fixes main unattended is a separate, riskier decision.
#
# DEDUP is now a SHARED-POOL invariant, not seat memory (HERD-371 — HERD-362/HERD-365 duplicated the same
# failing test because each seat's dedup only ever consulted its OWN local flat file). _main_health_fix_mark
# atomically claims the marker across the whole pool: the first seat to see this failing identity files it
# and every OTHER seat (or a later tick on this seat) that reproduces the SAME identity sees the marker
# already claimed and journals result=dedup instead of re-filing. The marker is dropped by
# _main_health_clear once main goes green for that identity, so a LATER regression files fresh. Fully
# fail-soft; always returns 0.
_main_health_autofix() {
  local _af_pr="$1" _af_sha="$2" _af_id="$3" _af_detail="$4" _af_mark_rc
  _main_health_autofix_enabled || return 0
  if ! _main_health_honest_identity "$_af_detail" "$_af_id"; then
    journal_append main_health_autofix pr "$_af_pr" sha "$_af_sha" result skipped reason dishonest-identity
    return 0
  fi
  _main_health_fix_mark "$_af_id" "$_af_pr" "$_af_sha"; _af_mark_rc=$?
  case "$_af_mark_rc" in
    0) : ;;                                                  # we won the claim — file it below
    3) journal_append main_health_autofix pr "$_af_pr" sha "$_af_sha" failed "$_af_id" result dedup
       return 0 ;;
    *) journal_append main_health_autofix pr "$_af_pr" sha "$_af_sha" failed "$_af_id" result skipped reason store-unavailable
       return 0 ;;
  esac
  # First line is the tracker TITLE (the backend takes it verbatim) — keep it short; body carries context.
  _main_health_scribe "MAIN RED: fix ${_af_id}
The default branch is RED at sha ${_af_sha} (landed as PR #${_af_pr}).
Failing test: ${_af_detail}
Add a 🔜 item to fix it. Do not close it until main-health goes green."
  journal_append main_health_autofix pr "$_af_pr" sha "$_af_sha" failed "$_af_id" result enqueued
  return 0
}

# _main_health_set_red <pr#> <sha> <healthcheck-oneline> [kind=local|ci] — a main sha REPRODUCED a red
# in the given SCOPE (HERD-372: "local" for the healthcheck suite, "ci" for the branch-CI leg; local is
# the default so the existing local-suite caller needs no change). MERGES into the state — it writes
# ONLY the <kind> identity field, leaving whichever OTHER identity already stood untouched, so a
# branch-CI red can never OVERWRITE (and thereby degrade) a standing local-suite failing-test identity,
# and vice versa. The rendered/journaled/notified/autofixed identity is the MOST SPECIFIC one standing
# (local wins over CI — mirrors build_main_health). The 'since #N' PR is STICKY: if main was already
# red, keep the FIRST offending PR so a run of red merges all point back to where main broke.
_main_health_set_red() {
  local _sr_pr="$1" _sr_sha="$2" _sr_out="$3" _sr_kind="${4:-local}"
  local _sr_fail _sr_since _sr_wasred=0 _sr_pv_sha="" _sr_pv_since="" _sr_pv_local="" _sr_pv_ci="" _sr_local _sr_ci _sr_render
  _sr_fail="$(_health_fail_identity "$_sr_out")"
  [ -n "$_sr_fail" ] || _sr_fail="$_sr_out"
  _sr_since="$_sr_pr"
  if [ -s "$MAIN_HEALTH_STATE" ]; then
    _sr_wasred=1
    IFS=$'\x1f' read -r _sr_pv_sha _sr_pv_since _sr_pv_local _sr_pv_ci < "$MAIN_HEALTH_STATE" 2>/dev/null || true
    [ -n "${_sr_pv_since:-}" ] && _sr_since="$_sr_pv_since"
  fi
  _sr_local="$_sr_pv_local"; _sr_ci="$_sr_pv_ci"
  case "$_sr_kind" in
    ci) _sr_ci="$_sr_fail" ;;
    *)  _sr_local="$_sr_fail" ;;
  esac
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$_sr_sha" "$_sr_since" "$_sr_local" "$_sr_ci" > "$MAIN_HEALTH_STATE" 2>/dev/null || true
  _sr_render="$_sr_local"; [ -n "$_sr_render" ] || _sr_render="$_sr_ci"
  journal_append main_health pr "$_sr_pr" sha "$_sr_sha" result red failed "$_sr_render" since "$_sr_since"
  if [ "$_sr_wasred" -eq 0 ]; then
    herd_driver_notify "🚨 MAIN RED" "default branch health FAILED after #${_sr_pr}: ${_sr_render} (since #${_sr_since})" default
  fi
  _main_health_autofix "$_sr_pr" "$_sr_sha" "$_sr_render" "$_sr_out"
}

# _main_health_defer <pr#> <sha> <reason> — journal a DEFERRAL (no slot, no bin) at most once per
# (sha, reason). The reconciler re-attempts a deferred sha EVERY tick, so an unguarded journal_append
# here would write the same "no-slot" line every ~90s for as long as a long gate holds the slot. The memo
# collapses that run into one honest line, and re-arms the moment the sha or the reason changes.
_main_health_defer() {
  local _md_pr="$1" _md_sha="$2" _md_reason="$3" _md_line _md_prev
  _md_line="$_md_sha $_md_reason"
  _md_prev="$(cat "$MAIN_HEALTH_DEFER" 2>/dev/null || true)"
  printf '%s\n' "$_md_line" > "$MAIN_HEALTH_DEFER" 2>/dev/null || true
  [ "$_md_prev" = "$_md_line" ] && return 0
  journal_append main_health pr "$_md_pr" sha "$_md_sha" result infra_event reason "$_md_reason"
  return 0
}

# _main_health_dispatch <pr#> <sha> <provenance> — the SHARED dispatch seam behind both the do_merge fast
# path (provenance=merge) and the tick-level reconciler (observed-sha | recheck | died). Backgrounds the
# heavy suite (_main_health_worker) holding a HEALTH_CONCURRENCY slot and returns immediately, so a tick
# NEVER blocks on a ~9-min suite (the .health-inflight-main-<sha> marker carries the WORKER's pid, so a
# corpse sweep can free the slot if it dies). The outcome is COLLECTED on a later tick by
# _collect_main_health, which routes it to _main_health_clear / _main_health_set_red.
#
# Assumes the caller already decided this sha WANTS a run; the idempotency guards below make a redundant
# call a silent no-op.
#
# RETURN CODE IS LOAD-BEARING (review BLOCK, round 1): 0 iff a worker was ACTUALLY BACKGROUNDED for this
# sha; 1 for every no-op — already in flight, result pending collection, no free HEALTH_CONCURRENCY slot,
# no healthcheck bin. A caller that spends a BUDGET (the died-worker retry counter) or DROPS STATE (the
# recheck path's run-once marker) must key that on a real dispatch, never on having called this. Charging
# a tick that merely DEFERRED would let slot contention — HEALTH_CONCURRENCY defaults to 1 and is shared
# with every per-PR gate suite, so "no slot" is the ROUTINE case — burn the death budget and mark a sha
# whose suite never ran even once, silently abandoning the very invariant this file asserts. Never fails
# a caller: no caller propagates this rc (an alarm can never fail a merge, nor a tick).
_main_health_dispatch() {
  local _mh_pr="${1:-}" _mh_sha="$2" _mh_prov="${3:-merge}" _mh_key _mh_inflight _mh_disp _mh_wpid _mh_log
  _mh_key="main-$_mh_sha"
  _mh_inflight="$(_health_inflight_file "$_mh_key")"
  _mh_disp="$(_health_dispatch_file "$_mh_key")"
  # Idempotent dispatch: a live worker for this sha, or a result already pending collection, means this
  # sha is handled — never double-dispatch (a re-entrant merge tick / restart / the reconciler landing on
  # the very sha do_merge just dispatched all re-enter here).
  { [ -f "$_mh_inflight" ] && _health_pid_live "$_mh_inflight"; } && return 1
  [ -f "$_mh_disp" ] && return 1
  # Respect HEALTH_CONCURRENCY: serialize against any candidate suite via the shared slot cap (all
  # worktrees + $MAIN share one git object store, so overlapping suites race on .git locks and paint
  # false-red). No slot free → journal an infra_event and defer WITHOUT marking the sha, so the NEXT TICK
  # re-attempts it (pre-HERD-222 this waited for the next MERGE); never run an overlapping suite.
  _health_slot_free || { _main_health_defer "$_mh_pr" "$_mh_sha" no-slot; return 1; }
  [ -f "$HERD_HEALTHCHECK_BIN" ] || { _main_health_defer "$_mh_pr" "$_mh_sha" no-bin; return 1; }
  rm -f "$MAIN_HEALTH_DEFER" 2>/dev/null || true            # dispatched — re-arm the deferral journal
  # Background the heavy suite STREAMING to the tailable log; record the pr# for the collector. Its own
  # process group (HERD-283) makes the suite subtree killable as one group if the corpse sweep times it
  # out — the main-health worker shares the exact fork-bomb exposure the per-PR gate worker has.
  _mh_log="$(_health_log_file "$_mh_key")"
  _bg_health_worker _main_health_worker "$_mh_sha" "$_mh_disp" "$_mh_log"
  _mh_wpid="$_BG_HEALTH_PID"
  _marker_write "$_mh_inflight" "$_mh_wpid" "$_BG_HEALTH_PGID"
  _rotate_health_logs
  printf '%s\n' "$_mh_pr" > "$(_main_health_pr_file "$_mh_sha")" 2>/dev/null || true
  journal_append main_health pr "$_mh_pr" sha "$_mh_sha" result dispatched pid "$_mh_wpid" \
    log_path "$_mh_log" provenance "$_mh_prov"
  # HERD-193 SPAWN: the main-health suite is a health worker like any other — same key space
  # (main-<sha>), same slot cap, same corpse-sweep deadline. Lever-gated; retired by _collect_main_health.
  lifecycle_spawn health-worker "$_mh_key" "pid:$_mh_wpid" agent-watch
  return 0
}

# main_health_tick <pr#> — the post-merge FAST PATH (called from do_merge): dispatch the suite for the
# sha this seat just fast-forwarded to, so the verdict lands a tick earlier than the reconciler would
# find it. Sha-keyed run-once; byte-inert when disabled; ALWAYS returns 0.
#
# Since HERD-222 this call is redundant-but-harmless: reconcile_main_health would dispatch the very same
# sha on the next tick, and the marker + inflight guards make whichever runs second a no-op. It stays
# because latency on the seat that DID merge is free, and it is the one path with a real pr# in hand.
main_health_tick() {
  _main_health_enabled || return 0
  local _mt_pr="${1:-}" _mt_sha
  _mt_sha="$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$_mt_sha" ] || { journal_append main_health pr "$_mt_pr" result infra_event reason no-head; return 0; }
  [ -e "$(_main_health_marker "$_mt_sha")" ] && return 0    # this main sha already ticked — run ONCE
  _main_health_dispatch "$_mt_pr" "$_mt_sha" merge
  return 0
}

# _main_health_died <sha> — true iff a worker was dispatched for this sha and is GONE without a verdict:
# the pr# sidecar (written only at dispatch) survives, but there is no live worker, no pending result,
# and no run-once marker. That is precisely the state _sweep_gate_corpses leaves behind when it reaps a
# killed worker (`health_died`) — pre-HERD-222 the sha was then stranded forever.
_main_health_died() {
  [ -f "$(_main_health_pr_file "$1")" ] || return 1
  [ -e "$(_main_health_marker "$1")" ] && return 1
  [ -f "$(_health_dispatch_file "main-$1")" ] && return 1
  local _mdd_inflight; _mdd_inflight="$(_health_inflight_file "main-$1")"
  { [ -f "$_mdd_inflight" ] && _health_pid_live "$_mdd_inflight"; } && return 1
  return 0
}

# _main_health_file_age_mins <file> — whole minutes since <file> was last written; -1 when its mtime is
# unreadable (file_mtime echoes 0), so an unstattable marker can never read as "infinitely old" and
# re-dispatch every tick. file_mtime is defined further down the file; this only ever runs from the tick.
_main_health_file_age_mins() {
  local _fa_mt _fa_now
  _fa_mt="$(file_mtime "$1" 2>/dev/null || printf 0)"
  case "${_fa_mt:-0}" in ''|0|*[!0-9]*) printf -- '-1'; return 0 ;; esac
  _fa_now="$(_now_epoch)"
  [ "$_fa_now" -ge "$_fa_mt" ] 2>/dev/null || { printf -- '-1'; return 0; }
  printf '%s' "$(( (_fa_now - _fa_mt) / 60 ))"
}

# ── Branch-CI main-red leg (HERD-334) ────────────────────────────────────────────────────────────
# GROUNDED (2026-07-11): main CI was red 6h after PR #439 with ZERO alarm — the MAIN RED machinery only
# ever reflected the LOCAL healthcheck suite, which can be green while the DEFAULT branch's required CI
# is red. This leg fires the EXISTING main-red row when the latest CI run FOR THE CURRENT main HEAD has a
# failing conclusion, reusing _main_health_set_red (same state file, same row, same notify-once) — passing
# kind=ci (HERD-372) so it MERGES its own identity field rather than clobbering a standing local-suite
# failing-test identity (or being clobbered by one).
#
# Rides the MAIN_HEALTH_TICK lever (byte-inert when off) and is fully fail-soft: an offline/old gh, no
# runs, or a run that is not yet COMPLETED yields NOTHING and never paints a red row. Deduped by
# (sha, conclusion) via $MAIN_HEALTH_CI_STATE so a standing CI red fires the row + journal exactly ONCE,
# never per tick. The local-suite green→clear path (kind=local) only ever drops the LOCAL identity field
# now (HERD-372) — a live CI red keeps standing, with zero re-set churn, until CI ITSELF recovers, which
# THIS leg — not the local-suite collector — is responsible for: a PASS bucket clears the CI identity
# (kind=ci) and resets $MAIN_HEALTH_CI_STATE, but ONLY when a red was actually standing (a non-empty
# dedup memo), so a routinely-green branch never journals a green/clear on every ~40s scan (the memo IS
# the guard: no prior fire ⇒ nothing to clear ⇒ byte-quiet, same as before this leg ever fired once).

# _main_ci_classify <expected-sha> — read a `gh run list --json headSha,status,conclusion,workflowName`
# array on stdin and emit "<bucket>\t<workflow>\t<conclusion>" for the most-recent COMPLETED run whose
# headSha matches <expected-sha> (bucket ∈ pass|fail|pending), or NOTHING (a run still in progress, a run
# for an older sha, bad JSON, no runs). Uses the SAME PASS/FAIL conclusion vocabulary as
# _ci_checks_normalize — CANCELLED/STALE/unknown are deliberately never red. python3 stdlib only.
_main_ci_classify() {
  python3 -c '
import sys, json
expected = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    runs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(runs, list):
    sys.exit(0)
PASS = {"SUCCESS", "NEUTRAL", "SKIPPED"}
FAIL = {"FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"}
def clean(s):
    return str(s or "").replace("\t", " ").replace("\n", " ").strip()
for r in runs:                       # gh returns newest-first
    if not isinstance(r, dict):
        continue
    if expected and r.get("headSha") != expected:
        continue
    if str(r.get("status") or "").upper() != "COMPLETED":
        continue                     # not terminal for this sha yet → no verdict
    concl = str(r.get("conclusion") or "").upper()
    if concl in FAIL:   bucket = "fail"
    elif concl in PASS: bucket = "pass"
    else:               bucket = "pending"   # CANCELLED / STALE / unknown → never red
    sys.stdout.write("%s\t%s\t%s\n" % (bucket, clean(r.get("workflowName")), concl or "?"))
    break
' "$1"
}

# _main_health_ci_leg — the per-tick branch-CI probe. Fetches the DEFAULT branch's recent CI runs. On a
# FAILING conclusion for the CURRENT main HEAD, fires _main_health_set_red once per (sha, conclusion). On
# a PASSING conclusion, clears the CI identity (HERD-372) — but only when $MAIN_HEALTH_CI_STATE shows a
# red was actually standing, so a normally-green branch never journals on every scan. Lever-gated +
# fail-soft; always returns 0.
_main_health_ci_leg() {
  _main_health_enabled || return 0
  [ -n "${DRYRUN:-}" ] && return 0
  local _sha _json _res _bucket _wf _concl _line _prev
  _sha="$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$_sha" ] || return 0
  _json="$(_gh_timeout main_health_ci run list --branch "$DEFAULT_BRANCH" --limit 20 \
             --json headSha,status,conclusion,workflowName 2>/dev/null)" || return 0
  [ -n "$_json" ] || return 0                              # offline gh / no Actions → byte-identical
  _res="$(printf '%s' "$_json" | _main_ci_classify "$_sha")"
  [ -n "$_res" ] || return 0
  IFS=$'\t' read -r _bucket _wf _concl <<EOF
$_res
EOF
  if [ "$_bucket" = "pass" ]; then
    _prev="$(cat "$MAIN_HEALTH_CI_STATE" 2>/dev/null || true)"
    [ -n "$_prev" ] || return 0                            # no standing CI red to clear — byte-quiet
    rm -f "$MAIN_HEALTH_CI_STATE" 2>/dev/null || true       # re-arm: a later regression fires fresh
    _main_health_clear "?" "$_sha" ci
    return 0
  fi
  [ "$_bucket" = "fail" ] || return 0                      # pending / stale → never a red row, never a clear
  _line="$_sha $_concl"
  _prev="$(cat "$MAIN_HEALTH_CI_STATE" 2>/dev/null || true)"
  [ "$_prev" = "$_line" ] && return 0                      # already fired for this sha+conclusion — no spam
  printf '%s\n' "$_line" > "$MAIN_HEALTH_CI_STATE" 2>/dev/null || true
  _main_health_set_red "?" "$_sha" "CI ${_wf:-run}: ${_concl}" ci
  return 0
}

# reconcile_main_health — the HERD-222 tick-level invariant: EVERY observed main sha ends with a
# collected health verdict, no matter who merged it. Call once per tick, AFTER reconcile_main_freshness
# (so $MAIN's HEAD is the real default-branch HEAD, not a stale checkout). Safe to call repeatedly.
#
#   • no marker for HEAD  → dispatch (provenance observed-sha). This is the cross-seat merge, the
#     no-slot deferral, and the watcher restart, all healed by the same rule.
#   • no marker, and the sha's worker DIED before collect → dispatch (provenance died), bounded by
#     _MAIN_HEALTH_DIED_MAX so a worker that dies every time surfaces as an infra_event, not a suite loop.
#   • marker present + main RED + MAIN_HEALTH_RECHECK_MINS elapsed → drop the marker and RE-VERIFY the
#     current sha. A red that is stale (already fixed, or never real) then clears itself through the
#     ordinary green path; a red that is real is simply re-confirmed.
#
# HARD INVARIANTS: byte-inert when MAIN_HEALTH_TICK is off; byte-identical to the pre-HERD-222 engine
# when MAIN_HEALTH_RECHECK_MINS is 0 (a marked, non-red-rechecking sha does nothing); fail-soft
# throughout — a tick is never failed by an alarm.
reconcile_main_health() {
  _main_health_enabled || return 0
  [ -n "${DRYRUN:-}" ] && return 0
  local _rm_sha _rm_marker _rm_pr _rm_mins _rm_age _rm_n
  _rm_sha="$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$_rm_sha" ] || return 0                             # no HEAD to observe — silent, retried next tick
  _rm_marker="$(_main_health_marker "$_rm_sha")"

  if [ ! -e "$_rm_marker" ]; then
    if _main_health_died "$_rm_sha"; then
      _rm_pr="$(cat "$(_main_health_pr_file "$_rm_sha")" 2>/dev/null || true)"; [ -n "$_rm_pr" ] || _rm_pr="?"
      _rm_n="$(cat "$(_main_health_retry_file "$_rm_sha")" 2>/dev/null || printf 0)"
      case "$_rm_n" in ''|*[!0-9]*) _rm_n=0 ;; esac
      if [ "$_rm_n" -ge "$_MAIN_HEALTH_DIED_MAX" ]; then
        : > "$_rm_marker" 2>/dev/null || true               # stop the loop: this sha gets no verdict
        journal_append main_health pr "$_rm_pr" sha "$_rm_sha" result infra_event reason died-cap deaths "$_rm_n"
        rm -f "$(_main_health_pr_file "$_rm_sha")" "$(_main_health_retry_file "$_rm_sha")" 2>/dev/null || true
        return 0
      fi
      # CHARGE THE BUDGET ONLY ON A REAL DISPATCH. The counter counts DEATHS, not ticks: a tick that
      # merely deferred (the shared health slot was busy — the routine case at HEALTH_CONCURRENCY=1) ran
      # no suite, so it must not spend a death. Charging it would let three slot-contended ticks reach
      # the cap, mark the sha run-once, and permanently strand a sha whose suite never ran once.
      if _main_health_dispatch "$_rm_pr" "$_rm_sha" died; then
        printf '%s\n' "$(( _rm_n + 1 ))" > "$(_main_health_retry_file "$_rm_sha")" 2>/dev/null || true
      fi
      return 0
    fi
    _rm_pr="$(_main_health_observed_pr "$_rm_sha")"; [ -n "$_rm_pr" ] || _rm_pr="?"
    _main_health_dispatch "$_rm_pr" "$_rm_sha" observed-sha    # a deferral simply retries next tick
    return 0
  fi

  # This sha already has a verdict. The ONLY reason to run it again is a standing RED we are asked to
  # re-verify on a cadence — everything else is a no-op (and, with the lever off, byte-identical).
  [ -s "$MAIN_HEALTH_STATE" ] || return 0
  _rm_mins="$(_main_health_recheck_mins)"
  [ "$_rm_mins" -gt 0 ] 2>/dev/null || return 0
  _rm_age="$(_main_health_file_age_mins "$_rm_marker")"     # marker mtime = when this sha was last collected
  case "$_rm_age" in ''|-*|*[!0-9]*) return 0 ;; esac
  [ "$_rm_age" -ge "$_rm_mins" ] || return 0
  _rm_pr="$(_main_health_observed_pr "$_rm_sha")"; [ -n "$_rm_pr" ] || _rm_pr="?"
  # DISPATCH FIRST, THEN drop the run-once marker — never the reverse. The marker is this sha's ONLY
  # record that it has a verdict; dropping it ahead of a dispatch that then defers (busy slot) would
  # leave the sha unmarked while $MAIN_HEALTH_STATE still renders its old verdict. It self-heals next
  # tick via the observed-sha branch, but the honest ordering is to spend nothing until the suite is
  # actually running. The collector rewrites the marker (and its mtime, which IS the cadence clock).
  if _main_health_dispatch "$_rm_pr" "$_rm_sha" recheck; then
    rm -f "$_rm_marker" 2>/dev/null || true
    journal_append main_health pr "$_rm_pr" sha "$_rm_sha" result recheck age_mins "$_rm_age"
  fi
  return 0
}

# _collect_main_health — per-tick collector for finished ASYNC main-health suites (mirrors the review
# gate's verdict collect). For each pending .health-dispatch-main-<sha>: record run-once FIRST (so a
# crash mid-collect never re-runs the sha), then route "<rc>\t<oneline>" to green/red/infra exactly as
# the old synchronous tick did, then free the slot. Called at the top of every tick; byte-quiet when
# nothing finished. A tab-leak-guard rc-1 is the same INFRA transient the pre-merge gate tolerates.
_collect_main_health() {
  local _cm_f _cm_base _cm_sha _cm_rc _cm_out _cm_pr
  for _cm_f in "$TREES"/.health-dispatch-main-*; do
    [ -e "$_cm_f" ] || continue
    _cm_base="${_cm_f##*/}"; _cm_sha="${_cm_base#.health-dispatch-main-}"
    [ -n "$_cm_sha" ] || continue
    IFS=$'\t' read -r _cm_rc _cm_out < "$_cm_f"
    _cm_pr="$(cat "$(_main_health_pr_file "$_cm_sha")" 2>/dev/null || true)"; [ -n "$_cm_pr" ] || _cm_pr="?"
    : > "$(_main_health_marker "$_cm_sha")" 2>/dev/null || true   # run-once BEFORE routing (crash-safe)
    case "$_cm_rc" in
      0) _main_health_clear "$_cm_pr" "$_cm_sha" ;;               # clean (or tolerated data/env) → green
      1) if _health_is_leak_guard_detail "$_cm_out"; then        # transient control-room churn (issue #78)
           journal_append main_health pr "$_cm_pr" sha "$_cm_sha" result infra_event reason tab-leak-guard
         else
           _main_health_set_red "$_cm_pr" "$_cm_sha" "$_cm_out"
         fi ;;
      *) journal_append main_health pr "$_cm_pr" sha "$_cm_sha" result infra_event reason "rc-${_cm_rc:-?}" ;;
    esac
    rm -f "$_cm_f" "$(_health_inflight_file "main-$_cm_sha")" "$(_main_health_pr_file "$_cm_sha")" \
          "$(_main_health_retry_file "$_cm_sha")" 2>/dev/null || true
    lifecycle_retire health-worker "main-$_cm_sha" collected   # HERD-193 RETIRE: verdict routed
  done
}

# do_merge — moved to work-units/git-pr.sh (HERD-398, Phase 3 work-unit extraction).

# _srs_gh_view <branch-or-pr#> — echo "state<TAB>headRefOid<TAB>number" for a PR resolved by branch
# name OR number, or nothing on any error (no PR, deleted branch, gh down). One network call. The head
# OID is what makes the sweep SAFE (see _startup_reap_sweep) — never reap without it.
_srs_gh_view() {
  _gh_timeout startup_reap_view pr view "$1" --json state,number,headRefOid \
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
    if [ -z "$_srs_pr" ] && [ -n "$_srs_ledger" ] && printf '%s\n' "$_srs_ledger" | grep -qxF "$_srs_slug"; then  # pipe-ok: bounded membership list, under a pipe buffer
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
    # (5) Defense-in-depth: never force-remove a worktree carrying uncommitted work. A regenerable
    #     derived file (HERD-214) is not work: a `herd reload` run in a merged worktree used to leave
    #     the rendered skill modified there, which stranded the tree forever as "dirty".
    if [ -n "$(git -C "$_srs_dir" status --porcelain 2>/dev/null | cut -c4- | herd_strip_derived)" ]; then
      journal_append startup_reap_skip slug "$_srs_slug" pr "$_srs_pr" reason dirty-worktree
      continue
    fi
    # HERD-401: wunit_teardown (facade) → _reap_slug (same function, resolved by the work-unit name).
    wunit_teardown "$_srs_slug" "$_srs_dir" "$_srs_pr" "$_srs_head" startup-sweep
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
#
# DETECTION vs ACTION: the candidate computation lives in _orphan_tab_ids (below), which PRINTS the
# orphaned tab ids and touches nothing. _sweep_orphan_tabs is the action wrapper. `herd sweep`
# (HERD-191) reuses the detector for its dry-run plan, so the plan and the live sweep can never
# disagree about which tabs are stale.
_orphan_tab_ids() {
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

  # Collect live slugs from open PRs by parsing each headRefName under the active BRANCH_TEMPLATE
  # (HERD-120) — mirrors herd_branch_parse so a custom / non-feat branch scheme still resolves the
  # slug that keys the tab, instead of assuming the slug is the last '/'-segment.
  local _sw_pr_slugs
  local _sw_tmpl="${BRANCH_TEMPLATE:-}"; [ -n "$_sw_tmpl" ] || _sw_tmpl='feat/{slug}'
  # HERD-206 shape (HERD-237): a pipeline hides the fetch's exit status, so a `gh pr list` that fails
  # or times out looks exactly like "zero open PRs". Capture the RAW output + its rc first, and abort
  # the sweep on a bad read rather than reasoning from a fabricated empty PR set. (_sw_live also unions
  # live worktree slugs, so the blast radius was bounded — but this is the same bug _srt_rc fixed in
  # _sweep_resolver_tabs, and it should not survive twice.)
  local _sw_raw _sw_rc=0
  _sw_raw="$(_gh_timeout worktree_sweep_prs pr list --json headRefName 2>/dev/null)" || _sw_rc=$?
  [ "$_sw_rc" -eq 0 ] || return 0
  _sw_pr_slugs="$(printf '%s' "$_sw_raw" | BRANCH_TEMPLATE="$_sw_tmpl" python3 -c '
import sys, json, os
tmpl = os.environ.get("BRANCH_TEMPLATE") or "feat/{slug}"
if "{slug}" not in tmpl: tmpl = "feat/{slug}"
pre, _, post = tmpl.partition("{slug}")
def parse(b):
  s = b
  if "{ref}" in pre:
    sep = pre.rsplit("{ref}", 1)[1]
    if sep:
      i = s.rfind(sep)
      if i >= 0: s = s[i + len(sep):]
  elif pre and s.startswith(pre):
    s = s[len(pre):]
  if "{ref}" in post:
    sep2 = post.split("{ref}", 1)[0]
    if sep2:
      i = s.find(sep2)
      if i >= 0: s = s[:i]
  elif post and s.endswith(post):
    s = s[:len(s) - len(post)]
  return s
try:
  for p in json.load(sys.stdin):
    b = p.get("headRefName","")
    if b: print(parse(b))
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
  printf '%s\n' "$_sw_orphans"
}

# _sweep_orphan_tabs — the ACTION wrapper around _orphan_tab_ids: close each orphaned tab, journal
# it, and prune its registry row. Dry-run-inert; byte-quiet when there are no orphans.
# Optional arg: a PRE-COMPUTED newline-separated id list from an earlier _orphan_tab_ids call. `herd
# sweep` narrates the plan from that list, so passing it back avoids a second `herdr tab list` +
# `gh pr list` round-trip per sweep. Absent ⇒ compute it here (the watcher's own every-15-tick path).
_sweep_orphan_tabs() {
  [ -n "$DRYRUN" ] && return 0
  # HERD-310: this migration-mode sweep enumerates the LIVE `herdr tab list` and closes every orphan
  # review·/resolve· tab — the exact path that severed the operator's in-flight review when a test
  # drove it from a builder worktree against the live socket. The guard is a no-op from the control
  # room (the watcher runs from the main checkout, not a worktree), so a real sweep is byte-identical.
  if command -v herd_context_pane_guard >/dev/null 2>&1 \
     && ! herd_context_pane_guard "_sweep_orphan_tabs (orphan tab close)"; then
    return 0
  fi
  local _sw_registry="$TREES/.herd-tabs" _sw_orphans="${1:-}" _sw_id
  # HERD-215: make the registry SELF-CONSISTENT before counting or closing anything — drop rows for
  # tabs that no longer exist at all (closed by a crash / reload / foreign path), so they stop
  # inflating the stale-tab tally. Runs regardless of whether there are orphan-tab candidates below.
  _herd_tabs_prune_orphans "$_sw_registry"
  [ -n "$_sw_orphans" ] || _sw_orphans="$(_orphan_tab_ids)"
  [ -n "$_sw_orphans" ] || return 0
  while IFS= read -r _sw_id; do
    [ -n "$_sw_id" ] || continue
    herdr tab close "$_sw_id" >/dev/null 2>&1 || true
    journal_append sweep_closed tab_id "$_sw_id" reason orphan
    # Remove the swept tab from the registry so it doesn't accumulate stale entries.
    _herd_tabs_drop_row "$_sw_registry" "$_sw_id"
  done <<< "$_sw_orphans"
}

# _herd_tabs_drop_row <registry-file> <tab_id> — remove the single row for <tab_id> (field 2) from the
# $TREES/.herd-tabs registry, leaving every other row byte-identical. Shared by _sweep_orphan_tabs and
# the stale-resolve-tab sweep so a swept tab never lingers as a stale registry entry. Fail-soft: a
# missing file / absent python3 / unwritable path just no-ops.
_herd_tabs_drop_row() {
  local _dr_reg="$1" _dr_tab="$2"
  [ -n "$_dr_reg" ] && [ -n "$_dr_tab" ] || return 0
  [ -f "$_dr_reg" ] || return 0
  TAB_ID="$_dr_tab" REGISTRY_PATH="$_dr_reg" python3 -c '
import os
path = os.environ.get("REGISTRY_PATH", "")
tid  = os.environ.get("TAB_ID", "")
if not path or not tid: raise SystemExit(0)
try:
    with open(path, encoding="utf-8") as f: lines = f.readlines()
    with open(path, "w", encoding="utf-8") as f:
        for line in lines:
            parts = line.strip().split(" ", 2)
            if not (len(parts) >= 2 and parts[1] == tid):
                f.write(line)
except Exception: pass
' 2>/dev/null || true
}

# _herd_tabs_prune_orphans <registry-file> — drop every registry row whose tab_id (field 2) names a
# tab that no longer EXISTS in the live `herdr tab list`, regardless of who closed it (a crash, a
# herdr reload, a manual `herdr tab close`, or a lane that closed the tab without owning the row).
# HERD-215: without this, a tab closed OUTSIDE the sweep's own close+drop path leaves its row behind
# forever, and the cheap stale-tab tally (sweep_cheap_tab_count — worktree-absence only, no herdr RPC)
# counts that dead row as a live mess across restarts (observed: 13 rows, 6 live tabs) — cry-wolf the
# operator can never clear, because _orphan_tab_ids only ever considers tabs that ARE in the live list
# and so never reaps a row whose tab is already gone. The prune makes the registry SELF-CONSISTENT: a
# row exists only while its tab does.
#
# SAFETY (the whole point — a wrong read WIPES the allowlist, de-registering LIVE tabs): prune ONLY
# against a live list that was BOTH positively fetched AND positively parsed AND non-empty. Three
# distinct failure shapes must every one degrade to NO-OP, never to "every tab is gone → wipe":
#   • `herdr tab list` FAILS           (rc != 0 — offline / rate-limited)        → no prune
#   • rc 0 but BLANK / UNPARSEABLE     (empty stdout, truncated or garbage JSON) → no prune
#   • rc 0, valid JSON, but ZERO tabs  (ambiguous: empty room vs a herdr blip)   → no prune
# Only the last case is a JUDGMENT call, and we resolve it conservatively: a lingering stale row is a
# benign over-count the cadence will catch once real tabs reappear, whereas a false wipe destroys the
# registry. This mirrors HERD-206 (a failed `gh pr list` is never "every PR merged"). The live-id
# parser therefore EXITS NON-ZERO on empty/garbage/wrong-shape input (rather than swallowing to an
# empty set), and the bash side refuses to prune unless it read at least one live tab_id. A registry
# row we cannot parse (< 2 fields) is preserved byte-for-byte. Fail-soft + idempotent throughout.
_herd_tabs_prune_orphans() {
  local _pr_reg="$1"
  [ -n "$_pr_reg" ] || return 0
  [ -f "$_pr_reg" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  local _pr_raw _pr_rc=0
  _pr_raw="$(herdr tab list 2>/dev/null)" || _pr_rc=$?
  [ "$_pr_rc" -eq 0 ] || return 0
  # Extract the live tab_ids. The parser raises (→ non-zero exit) on empty/garbage input or a response
  # whose result.tabs is not a list, so a degenerate rc-0 read is a hard STOP, not an empty live set.
  local _pr_live _pr_prc=0
  _pr_live="$(printf '%s' "$_pr_raw" | python3 -c '
import sys, json
data = json.loads(sys.stdin.read())          # raises on empty / truncated / non-JSON → SystemExit != 0
tabs = data["result"]["tabs"]                # raises (KeyError/TypeError) on the wrong shape
if not isinstance(tabs, list):
    raise SystemExit(1)
sys.stdout.write("\n".join(t.get("tab_id","") for t in tabs if isinstance(t, dict) and t.get("tab_id")))
' 2>/dev/null)" || _pr_prc=$?
  [ "$_pr_prc" -eq 0 ] || return 0
  # A positively-parsed but EMPTY live set is the ambiguous case above → refuse to prune against it.
  [ -n "$_pr_live" ] || return 0
  # Rewrite the registry keeping only rows whose tab_id is live (or unparseable). Print each pruned
  # tab_id so the caller can journal it. The file is only rewritten when something is actually dropped,
  # so a clean registry keeps its exact bytes (and mtime). Belt-and-braces: the rewrite ALSO refuses an
  # empty live set, so it can never wipe the registry even if a future caller forgets the guard above.
  local _pr_dropped
  _pr_dropped="$(REG="$_pr_reg" LIVE="$_pr_live" python3 -c '
import os
reg  = os.environ["REG"]
live = set(l for l in os.environ.get("LIVE","").split("\n") if l)
if not live:
    raise SystemExit(0)                       # never prune against an empty live set (would wipe rows)
try:
    with open(reg, encoding="utf-8") as f: lines = f.readlines()
except Exception:
    raise SystemExit(0)
kept, dropped = [], []
for line in lines:
    parts = line.strip().split(" ", 2)
    if len(parts) >= 2 and parts[1] and parts[1] not in live:
        dropped.append(parts[1]); continue
    kept.append(line)
if dropped:
    try:
        with open(reg, "w", encoding="utf-8") as f: f.writelines(kept)
    except Exception:
        raise SystemExit(0)
    for d in dropped: print(d)
' 2>/dev/null || true)"
  local _pr_id
  while IFS= read -r _pr_id; do
    [ -n "$_pr_id" ] || continue
    command -v journal_append >/dev/null 2>&1 && \
      journal_append sweep_tab_prune tab_id "$_pr_id" reason orphan-row
  done <<< "$_pr_dropped"
  return 0
}

# _sweep_stale_resolve_tabs — proactively close STALE resolve·<slug> conflict-resolver tabs (HERD-54).
# herd-resolve.sh opens a resolve·<slug> tab (registered in $TREES/.herd-tabs) when a PR goes
# CONFLICTING. Once the resolver DIES/FINISHES and the conflict is gone (the PR merged, closed, or its
# mergeable state went clean), that tab just lingers — clutter that can also catch the tab-leak-guard's
# before/after snapshot mid-flap and false-red an innocent PR. This sweep closes such tabs.
#
# A resolve tab is STALE only when BOTH hold:
#   (1) its resolver is POSITIVELY DEAD — _resolver_liveness_verdict, the SAME death oracle the
#       resolver-respawn path (HERD-55) uses, returns DEAD. ALIVE (roster-listed or a pane running
#       claude), STARTING (inside the spawn grace) and UNKNOWN (we cannot see) all spare the tab; AND
#   (2) the slug's PR is no longer CONFLICTING — it is merged/closed (absent from the open-PR list) or
#       its mergeable state is clean (MERGEABLE). A CONFLICTING PR still needs the resolver, and an
#       UNKNOWN state (GitHub still computing) is treated conservatively as "still relevant" — neither
#       is swept.
# SAFETY MIRRORS HERD-91's OID-guard philosophy: never tear down a live worker. HERD-206: the pre-fix
# guard read only the roster, so a `herdr agent list` blip (or a resolver registered under the `agent`
# identity key) let this sweep CLOSE the tab of a live, mid-merge resolver — which the respawn path
# then re-dispatched, round after round, to the cap. Both defects are gone: the reaper now demands
# POSITIVE death evidence, and a failed `gh pr list` (rc != 0) aborts the sweep rather than reading an
# empty result as "every PR merged, close everything".
#
# Runs at startup and before each leak-guard-relevant healthcheck snapshot. Requires AGENTS_JSON to be
# populated (the tick sets it; the startup call primes it). Idempotent + fully fail-soft: no registry,
# no herdr, or dry-run ⇒ zero action. One `gh pr list` per invocation; cheap when there are no resolve
# rows (the common case) — it returns before any network call.
# DETECTION vs ACTION: _stale_resolve_tab_ids PRINTS "slug<TAB>tab_id" for each stale resolve tab and
# touches nothing; _sweep_stale_resolve_tabs (below) is the action wrapper.
_stale_resolve_tab_ids() {
  command -v herdr >/dev/null 2>&1 || return 0
  local _srt_reg="$TREES/.herd-tabs"
  [ -f "$_srt_reg" ] || return 0

  # (1) resolve·<slug> rows from the tab registry → "slug<TAB>tab_id" lines. No rows ⇒ nothing to do
  #     (return BEFORE the gh call — the sweep is byte-inert on a workspace with no resolve tabs).
  local _srt_rows
  _srt_rows="$(REG="$_srt_reg" python3 -c '
import os
prefix = "resolve·"   # the resolve-tab label prefix (middot separator)
try:
    with open(os.environ["REG"], encoding="utf-8") as f:
        for line in f:
            parts = line.strip().split(" ")
            if len(parts) < 2: continue
            label, tab_id = parts[0], parts[1]
            if label.startswith(prefix) and tab_id:
                slug = label[len(prefix):]
                if slug:
                    print(slug + "\t" + tab_id)
except Exception:
    pass
' 2>/dev/null || true)"
  [ -n "$_srt_rows" ] || return 0

  # (2) One gh call: map each OPEN PR's slug → its mergeable state. A slug ABSENT from this map has no
  #     open PR (merged/closed/never-existed) → its conflict is definitively gone.
  #     HERD-206: `gh pr list` failing (offline, rate-limited, auth blip) yields the SAME empty output as
  #     "zero open PRs", and the pre-fix sweep read that as "no slug has a PR → close every resolve tab".
  #     Capture the raw output + its EXIT STATUS first; a non-zero rc aborts the sweep untouched.
  local _srt_raw _srt_rc=0
  _srt_raw="$(_gh_timeout resolver_tab_sweep_prs pr list --json headRefName,mergeable 2>/dev/null)" || _srt_rc=$?
  [ "$_srt_rc" -eq 0 ] || return 0
  local _srt_prs _srt_tmpl="${BRANCH_TEMPLATE:-}"; [ -n "$_srt_tmpl" ] || _srt_tmpl='feat/{slug}'
  _srt_prs="$(printf '%s' "$_srt_raw" | BRANCH_TEMPLATE="$_srt_tmpl" python3 -c '
import sys, json, os
# Parse each headRefName to its slug under the active BRANCH_TEMPLATE (HERD-120), mirroring
# herd_branch_parse — so a custom / non-feat branch scheme resolves the slug that keys the resolve tab.
tmpl = os.environ.get("BRANCH_TEMPLATE") or "feat/{slug}"
if "{slug}" not in tmpl: tmpl = "feat/{slug}"
pre, _, post = tmpl.partition("{slug}")
def parse(b):
    s = b
    if "{ref}" in pre:
        sep = pre.rsplit("{ref}", 1)[1]
        if sep:
            i = s.rfind(sep)
            if i >= 0: s = s[i + len(sep):]
    elif pre and s.startswith(pre):
        s = s[len(pre):]
    if "{ref}" in post:
        sep2 = post.split("{ref}", 1)[0]
        if sep2:
            i = s.find(sep2)
            if i >= 0: s = s[:i]
    elif post and s.endswith(post):
        s = s[:len(s) - len(post)]
    return s
try:
    for p in json.load(sys.stdin):
        b = p.get("headRefName","")
        if b:
            print(parse(b) + "\t" + (p.get("mergeable","") or ""))
except Exception:
    pass
' 2>/dev/null || true)"

  local _srt_slug _srt_tab _srt_merge
  while IFS=$'\t' read -r _srt_slug _srt_tab; do
    [ -n "$_srt_slug" ] && [ -n "$_srt_tab" ] || continue
    # SAFETY (HERD-206): only a POSITIVELY-dead resolver is ever closed. ALIVE (roster row OR a pane
    # running claude — the reaper must never kill a resolver whose pane process is alive), STARTING
    # (inside the spawn grace, slug-keyed since we hold no PR number) and UNKNOWN (blind) all spare it.
    [ "$(_resolver_liveness_verdict "$_srt_slug")" = "DEAD" ] || continue
    # PR still CONFLICTING (or UNKNOWN — GitHub still computing) → the resolve tab is still relevant.
    _srt_merge="$(printf '%s\n' "$_srt_prs" | awk -F'\t' -v s="$_srt_slug" '$1==s{print $2; exit}')"
    case "$_srt_merge" in
      CONFLICTING|UNKNOWN) continue ;;
    esac
    printf '%s\t%s\n' "$_srt_slug" "$_srt_tab"
  done <<< "$_srt_rows"
  return 0
}

# _sweep_stale_resolve_tabs — the ACTION wrapper around _stale_resolve_tab_ids: close each stale
# resolve tab, journal it, prune its registry row. Dry-run-inert. Split for the same reason as
# _orphan_tab_ids: `herd sweep` (HERD-191) narrates + counts from the detector, so a resolve tab it
# closes can never be invisible in the plan or in SWEEP_N_TAB.
_sweep_stale_resolve_tabs() {
  [ -n "$DRYRUN" ] && return 0
  # HERD-310: same live-tab-close severing class as _sweep_orphan_tabs. No-op from the control room.
  if command -v herd_context_pane_guard >/dev/null 2>&1 \
     && ! herd_context_pane_guard "_sweep_stale_resolve_tabs (stale resolve tab close)"; then
    return 0
  fi
  local _srt_reg="$TREES/.herd-tabs" _srt_slug _srt_tab
  while IFS=$'\t' read -r _srt_slug _srt_tab; do
    [ -n "$_srt_slug" ] && [ -n "$_srt_tab" ] || continue
    herdr tab close "$_srt_tab" >/dev/null 2>&1 || true
    journal_append reap_resolve_tab tab_id "$_srt_tab" slug "$_srt_slug" reason stale-sweep
    _herd_tabs_drop_row "$_srt_reg" "$_srt_tab"
  done <<< "$(_stale_resolve_tab_ids)"
  return 0
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

# ── Post-merge hooks as a RECONCILED SWEEP (HERD-232) ─────────────────────────────────────────────
# GROUNDED (docs/audits/2026-07-09-gating-hardening.md, incidents 1 + 12 → N6): every post-merge hook
# was merge-EVENT-driven — it ran only inside the do_merge of the seat that landed the PR. Two ways
# that loses:
#   • CRASH: 17 MERGED PRs skipped every hook when do_merge misread gh's exit (HERD-221 fixed the
#     trigger, not the residue), and a watcher killed between the merge and the reap never retries —
#     the merge row is already written, so the next tick sees "handled".
#   • FOREIGN MERGE: another seat's watcher, or a human clicking Merge in the gh UI, runs ITS hooks
#     (or none). OUR seat's $STATE row, approval/CI ledger purges, cost capture and worktree teardown
#     simply never happen. Only worktree teardown had any resume path at all (_startup_reap_sweep),
#     and only at startup.
#
# THE FIX IS THE DOCTRINE (docs/multi-seat-doctrine.md R1, the seam HERD-218/HERD-233 established for
# codemap + $MAIN freshness): stop treating a hook as a side-effect of OUR merge event and start
# treating "this merged PR's obligations are discharged" as an INVARIANT re-derived from the world.
# Each cadence pass enumerates recently-MERGED PRs, asks of each which obligations are OUTSTANDING,
# and runs exactly those, idempotently.
#
# OBLIGATIONS PROBED (each is a cheap local-ledger read; each runner is the SAME idempotent primitive
# do_merge calls, so a reconciled PR is indistinguishable from a locally-merged one):
#   state_row  — the $STATE merge row (drives already_merged + the "recently landed" console row)
#   reconcile  — the backlog/tracker link (reconcile_backlog; itself pr+sha-ledgered)
#   approvals  — phantom "awaiting approval" rows for a terminal PR (purge_pr_approvals)
#   ci_checks  — the PR's terminal CI gate-event rows (purge_pr_ci_checks)
#   cost       — builder token/cost accounting, ONLY where a transcript ledger still exists
#   reap       — worktree + tabs teardown (_reap_slug), under the same sha anchor _startup_reap_sweep
#                uses: reap ONLY when the worktree's HEAD is exactly the merged PR's headRefOid
#
# DELIBERATELY NOT REPLAYED — four of do_merge's hooks are someone else's invariant, or unsafe to
# replay for a merge we did not perform:
#   tracker mark-done      — _sweep_tracker_state already re-asserts Done for every recently-merged PR
#                            carrying a `Refs:` line, on this same cadence, seat-agnostically. Running
#                            it here would double-write the tracker; instead we DEFER to its ledger as
#                            evidence (see _pms_reconcile_handled).
#   codemap / symbol-index — reconcile_map_freshness (HERD-218) already re-derives both per tick,
#                            independent of any merge event. That is the same fix, one layer up.
#   main-health tick       — its own tick-level invariant (audit A1 → HERD-222), keyed on $MAIN's HEAD,
#                            not on a PR.
#   post-merge steps.tsv   — operator-defined side effects (deploy, notify, publish). A foreign seat
#                            that merged the PR has ALREADY run its own copy of them; re-running them
#                            here would fire an external, possibly irreversible action twice. Replaying
#                            an operator's side effects needs the cross-seat evidence substrate (audit
#                            N8) before it can be safe, so this sweep never touches them.
#
# MULTI-SEAT SAFETY — a foreign-seat merge gets OUR seat's obligations ONLY. Every obligation above
# except `reconcile` writes a $TREES-local ledger or tears down a worktree this seat owns, so it is
# unobservable to another seat and safe to run unconditionally. `reconcile` is the one hook with a
# SHARED side effect (a tracker state write, or a scribe enqueue that edits BACKLOG.md), so it is
# gated on evidence that it is already handled.
#
# BE PRECISE ABOUT WHAT THAT BUYS (review note): every evidence source _pms_reconcile_handled consults
# — $RECONCILE_STATE, this seat's journal, $TRACKER_SWEEP_LEDGER — lives under THIS seat's $TREES. So
# the defer reliably suppresses OUR OWN re-work (a restart, a rotated ledger, a second pass), and it
# suppresses cross-seat re-work only insofar as our tracker sweep has already observed the item Done.
# Against a genuinely separate seat with its own $TREES the defer may simply not fire, and
# reconcile_backlog runs a second time. That is SAFE, not correct-by-construction: _reconcile_via_ref
# reports NOCHANGE on an already-Done item, and the fuzzy scribe request only ever matches a 🔜/🚧
# item, so it no-ops on one already marked ✅. Both paths converge; neither corrupts. A real
# cross-seat guarantee needs the shared per-PR comment/status substrate (audit item N8's spike);
# when it lands, _pms_reconcile_handled is the ONE place to teach it a new evidence source.
#
# CONVENTIONS: fail-soft (a gh error skips the pass entirely and quietly — never a false red, never a
# partial reconcile off a truncated PR list); idempotent (record-first, run-once keyed by pr+sha);
# bounded lookback; NO new config key — the cadence and window are engine constants.
_PMS_LOOKBACK=30            # recently-MERGED PRs probed per pass (bounded window, one gh call)
_PMS_LEDGER_KEEP=400        # run-once rows retained (review: the ledger only ever grew). Far above the
                            # lookback, so trimming can never drop a row for a PR still in the window —
                            # and a dropped row costs at most one idempotent re-probe, never an action.

# _pms_swept <pr#> <sha> — true iff this exact merged (pr,sha) had every obligation discharged by a
# previous pass. The run-once key. Sha-keyed as well as pr-keyed so a (pathological) force-push onto a
# merged PR's head re-opens the probe rather than being silently skipped forever.
_pms_swept() {
  [ -s "$POSTMERGE_SWEPT_LEDGER" ] || return 1
  awk -v p="$1" -v s="$2" '$2==p && $3==s{f=1} END{exit !f}' "$POSTMERGE_SWEPT_LEDGER" 2>/dev/null
}

# _pms_record <pr#> <sha> — mark this merged PR fully reconciled. Called ONLY when nothing was left
# outstanding; a pass that deliberately deferred a reap (live/dirty worktree) does NOT record, so the
# next pass retries. Fail-soft: an unwritable ledger just re-probes next pass (all runners are no-ops).
# Trimmed on write to the last _PMS_LEDGER_KEEP rows — the sibling PR-keyed ledgers are purged at merge,
# but this one is keyed by a PR that is already gone, so nothing else would ever bound it.
_pms_record() {
  printf '%s %s %s\n' "$(date +%s)" "$1" "$2" >> "$POSTMERGE_SWEPT_LEDGER" 2>/dev/null || true
  _pms_trim_ledger "$POSTMERGE_SWEPT_LEDGER"
}

# _pms_trim_ledger <file> — keep only the last _PMS_LEDGER_KEEP lines. Atomic rewrite, fully fail-soft:
# a failed trim leaves the ledger correct (just longer), never truncated.
_pms_trim_ledger() {
  local _pmt_f="$1" _pmt_n _pmt_tmp
  [ -s "$_pmt_f" ] || return 0
  _pmt_n="$(wc -l < "$_pmt_f" 2>/dev/null | tr -cd '0-9')"; _pmt_n="${_pmt_n:-0}"
  [ "$_pmt_n" -gt "$_PMS_LEDGER_KEEP" ] 2>/dev/null || return 0
  _pmt_tmp="$(mktemp "$_pmt_f.XXXXXX" 2>/dev/null)" || return 0
  if tail -n "$_PMS_LEDGER_KEEP" "$_pmt_f" > "$_pmt_tmp" 2>/dev/null; then
    mv -f "$_pmt_tmp" "$_pmt_f" 2>/dev/null || rm -f "$_pmt_tmp"
  else
    rm -f "$_pmt_tmp"
  fi
}

# _pms_noted / _pms_note <pr#> <sha> <kind> — a NOTE-ONCE ledger for the journal lines a DEFERRED PR
# would otherwise re-emit forever. A permanently dirty worktree (or a stray non-repo $TREES/<slug>
# directory) never earns its run-once row by design — the reap must keep retrying — but the operator
# does not need `postmerge_reap_skip` every ~3 min until someone cleans it up. _startup_reap_sweep
# journals its skip once per run; this gives the cadence sweep the same manners: the CONDITION is
# re-evaluated every pass, only the NOTIFICATION is once per (pr,sha,kind).
_pms_noted() {
  [ -s "$POSTMERGE_NOTED_LEDGER" ] || return 1
  grep -qxF "$1 $2 $3" "$POSTMERGE_NOTED_LEDGER" 2>/dev/null
}
_pms_note() {
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$POSTMERGE_NOTED_LEDGER" 2>/dev/null || true
  _pms_trim_ledger "$POSTMERGE_NOTED_LEDGER"
}

# _pms_state_row <pr#> — true iff the merge ledger already carries a row for this PR. Deliberately
# PR-keyed only (unlike already_merged, which also matches the slug): a foreign PR's branch may not
# fit BRANCH_TEMPLATE at all, and the question here is "did this seat record the merge", not "for
# which slug". Row format: "<epoch> <pr#> <slug> [ref]".
_pms_state_row() {
  [ -s "$STATE" ] || return 1
  awk -v p="$1" 'NF>=3 && $2==p{f=1} END{exit !f}' "$STATE" 2>/dev/null
}

# _pms_approvals_rows <pr#> / _pms_ci_rows <pr#> — true iff the PR still has ledger residue to purge.
# Field positions mirror purge_pr_approvals ("<epoch> <state> <pr#> <sha>") and purge_pr_ci_checks
# ("<pr#> <sha> <conclusion> <check…>"), so the probe and the purge can never disagree about the key.
_pms_approvals_rows() {
  [ -s "$APPROVALS" ] || return 1
  awk -v p="$1" '$3==p{f=1} END{exit !f}' "$APPROVALS" 2>/dev/null
}
_pms_ci_rows() {
  [ -s "$CI_CHECKS_STATE" ] || return 1
  awk -v p="$1" '$1==p{f=1} END{exit !f}' "$CI_CHECKS_STATE" 2>/dev/null
}

# _pms_journal_has <event> <pr#> — true iff the engine journal already carries <event> for this PR.
# journal.sh emits compact JSON with the keys in CALL order, so `pr` is NOT always the first key: the
# reconcile hook journals `reconcile pr <n> …` but cost.sh journals `cost component <c> pr <n> …`. So
# match the event and the pr INDEPENDENTLY on the same line rather than as an adjacent pair — an
# anchored `"event":"X","pr":N` silently never matches `cost`, which is exactly the guard that must
# not fail open (a false negative re-emits a cost event and inflates the day's spend).
# Fail-soft: no journal destination (the HERD-223 test guard) or an unreadable file reads as "no
# evidence" — the caller then does the work, which is always idempotent except for `cost`, whose own
# transcript-dir probe bounds it.
_pms_journal_has() {
  type _journal_file >/dev/null 2>&1 || return 1
  local _pmj_f; _pmj_f="$(_journal_file 2>/dev/null || true)"
  [ -n "$_pmj_f" ] && [ -s "$_pmj_f" ] || return 1
  grep -F "\"event\":\"$1\"" "$_pmj_f" 2>/dev/null | grep -qE "\"pr\":$2[,}]"  # pipe-ok: bounded command output, under a pipe buffer
}

# _pms_tracker_ledgered <ref> — true iff the tracker-state sweep has already CONFIRMED this ref Done
# (ledger row "<epoch> <ref> <pr#>"). That sweep scans every recently-merged PR regardless of which
# seat merged it, so a hit here means the tracker obligation is discharged no matter who discharged it.
_pms_tracker_ledgered() {
  [ -n "${1:-}" ] || return 1
  [ -s "$TRACKER_SWEEP_LEDGER" ] || return 1
  awk -v r="$1" '$2==r{f=1} END{exit !f}' "$TRACKER_SWEEP_LEDGER" 2>/dev/null
}

# _pms_reconcile_handled <pr#> <sha> — the DEFER predicate for the one hook with a shared side effect.
# Prints the evidence kind on stdout and returns 0 when the backlog/tracker link is already handled:
#   ledger        — this seat enqueued/resolved it (reconcile_backlog's own pr+sha guard)
#   journal       — this seat journaled a `reconcile` for the PR (a ledger lost to rotation/repair)
#   tracker-swept — the tracker sweep confirmed the PR's `Refs:` item Done (whoever marked it)
# Returns 1 (with no output) when nothing has handled it, i.e. WE must. The `Refs:` read is the only
# per-PR network call this sweep makes, and it happens at most once per merged PR: the moment we run
# reconcile_backlog it ledgers pr+sha and this predicate short-circuits on the cheap local read.
_pms_reconcile_handled() {
  local _pmr_pr="$1" _pmr_sha="$2" _pmr_ref
  reconcile_enqueued "$_pmr_pr" "$_pmr_sha" && { printf 'ledger'; return 0; }
  _pms_journal_has reconcile "$_pmr_pr"     && { printf 'journal'; return 0; }
  _pmr_ref="$(_reconcile_pr_ref "$_pmr_pr" 2>/dev/null || true)"
  _pms_tracker_ledgered "$_pmr_ref"         && { printf 'tracker-swept'; return 0; }
  return 1
}

# _pms_merged_prs — "<pr#>\t<headRefOid>\t<headRefName>\t<mergedAt-epoch>" per recently-merged PR,
# OLDEST FIRST. ONE gh call per pass. A non-zero gh (offline, rate-limited, auth blip) prints NOTHING
# and returns non-zero so the caller aborts the whole pass: an empty PR list is indistinguishable from
# "gh is down", and reconciling off a truncated list is how a sweep silently skips obligations (the
# HERD-206 lesson from _sweep_stale_resolve_tabs). Hermetic seam: HERD_PMS_PRS_JSON_FILE supplies raw
# `gh pr list --json` output, bypassing the network exactly like tracker-state-sweep.sh's seam.
#
# ORDER + TIMESTAMP MATTER (review note). gh returns merged PRs newest-first, and `build_landed` renders
# the LAST THREE $STATE rows in file order. A first catch-up pass on a seat whose $STATE predates this
# feature appends up to _PMS_LOOKBACK rows at once — newest-first would therefore leave the OLDEST PRs
# of the batch at the tail and render them as the three most recent landings. Sorting ascending by
# mergedAt makes the appended run read in true merge order. And each row is stamped with the PR's REAL
# mergedAt, not `date +%s`: a reconciled row must not claim a PR landed the moment we noticed it.
_pms_merged_prs() {
  local _pmp_json
  if [ -n "${HERD_PMS_PRS_JSON_FILE:-}" ]; then
    _pmp_json="$(cat "$HERD_PMS_PRS_JSON_FILE" 2>/dev/null)" || return 1
  else
    command -v gh >/dev/null 2>&1 || return 1
    _pmp_json="$(_gh_timeout postmerge_sweep_prs pr list --state merged --limit "$_PMS_LOOKBACK" \
      --json number,headRefOid,headRefName,mergedAt 2>/dev/null)" || return 1
  fi
  [ -n "$_pmp_json" ] || return 0
  printf '%s' "$_pmp_json" | python3 -c '
import sys, json, calendar, time
try:
    prs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def epoch(s):
    # gh emits RFC3339 UTC ("2026-07-09T18:46:53Z"). An unparseable/absent mergedAt falls back to
    # "now" — the row is still honest about the merge having happened, just not about when.
    try:
        return calendar.timegm(time.strptime(str(s), "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return int(time.time())
rows = []
for pr in prs if isinstance(prs, list) else []:
    num = pr.get("number"); oid = pr.get("headRefOid") or ""
    if num is None or not oid:
        continue
    rows.append((epoch(pr.get("mergedAt")), num, oid, pr.get("headRefName") or ""))
rows.sort(key=lambda r: r[0])          # OLDEST first — see the ORDER note above
for ts, num, oid, branch in rows:
    print("%s\t%s\t%s\t%s" % (num, oid, branch, ts))
' 2>/dev/null || return 0
}

# _pms_reconcile_one <pr#> <sha> <branch> [merged-epoch] — probe ONE merged PR and discharge whatever
# is outstanding. Returns 0 when the PR is fully reconciled (caller records the run-once row), 1 when an
# obligation was deliberately left for a later pass (a worktree that is not provably disposable yet).
_pms_reconcile_one() {
  local _pm_pr="$1" _pm_sha="$2" _pm_branch="${3:-}" _pm_mts="${4:-}"
  local _pm_slug="" _pm_dir="" _pm_missing="" _pm_defer="" _pm_retry=0
  case "$_pm_mts" in ''|*[!0-9]*) _pm_mts="$(date +%s)" ;; esac

  # SLUG, and whether the branch fits BRANCH_TEMPLATE at all. herd_branch_parse strips the template's
  # literal prefix with `${var#prefix}`, which is a NO-OP when the prefix does not match — so a foreign
  # branch like `chore/bump-deps` under `feat/{slug}` comes back verbatim, not empty (review note). A
  # real slug is a single kebab path segment (it names a directory directly under $TREES), so a parse
  # result that still carries a '/' provably did not fit the template: treat it as "no slug of ours",
  # which keeps $TREES/<slug> from ever being probed for a branch we do not own.
  [ -n "$_pm_branch" ] && _pm_slug="$(herd_branch_parse "$_pm_branch" 2>/dev/null || true)"
  case "$_pm_slug" in ''|*/*) _pm_slug='-' ;; esac
  [ "$_pm_slug" = '-' ] || _pm_dir="$TREES/$_pm_slug"

  _pms_state_row "$_pm_pr" || _pm_missing="$_pm_missing state_row"

  local _pm_ev=""
  if _pm_ev="$(_pms_reconcile_handled "$_pm_pr" "$_pm_sha")"; then
    # `ledger` is this seat's own guard doing its job — not a cross-seat deferral, and not worth a line.
    [ "$_pm_ev" = ledger ] || _pm_defer="$_pm_ev"
  else
    _pm_missing="$_pm_missing reconcile"
  fi

  _pms_approvals_rows "$_pm_pr" && _pm_missing="$_pm_missing approvals"
  _pms_ci_rows "$_pm_pr"        && _pm_missing="$_pm_missing ci_checks"

  # Worktree obligations. The reap anchor is _startup_reap_sweep's: a worktree is disposable ONLY when
  # its HEAD sha is exactly the merged PR's headRefOid, so every committed thing in it is already
  # merged. A re-spawned slug (fresh commits, or none yet) and a dirty tree both fail that test and are
  # left alone — and because we then skip the run-once row, the next pass re-probes rather than
  # stranding the worktree forever.
  #
  # COST is probed by RESIDUE, like every other obligation — a transcript ledger that exists AND no
  # `cost` event already journaled for this PR (review note). The transcript dir is NOT inside the
  # worktree (_cost_transcript_dir munges the worktree PATH into $HOME/.claude/projects/<munged>), so
  # it survives the reap: without the journal guard, a do_merge that emitted `cost` and then died
  # before teardown would have its cost re-emitted here, and cost_day_total sums `cost` events
  # unconditionally into budget_daily_exceeded. Cost still RUNS before the reap, matching do_merge.
  if [ -n "$_pm_dir" ] && [ -d "$_pm_dir" ] && [ "$_pm_dir" != "${SELF_WT:-}" ] && [ "$_pm_dir" != "$MAIN" ]; then
    local _pm_head; _pm_head="$(git -C "$_pm_dir" rev-parse HEAD 2>/dev/null || true)"
    if [ -z "$_pm_head" ] || [ "$_pm_head" != "$_pm_sha" ]; then
      _pm_retry=1                                   # live / re-spawned slug — not this PR's worktree
    elif [ -n "$(git -C "$_pm_dir" status --porcelain 2>/dev/null | cut -c4- | herd_strip_derived)" ]; then
      # Journal the hold ONCE per (pr,sha): the condition is re-checked every pass, but a permanently
      # dirty tree must not re-notify every ~3 min (it never earns a run-once row, by design).
      if ! _pms_noted "$_pm_pr" "$_pm_sha" reap_skip; then
        journal_append postmerge_reap_skip pr "$_pm_pr" slug "$_pm_slug" reason dirty-worktree
        _pms_note "$_pm_pr" "$_pm_sha" reap_skip
      fi
      _pm_retry=1                                   # never force-remove uncommitted work
    else
      local _pm_costdir=""
      type _cost_transcript_dir >/dev/null 2>&1 && _pm_costdir="$(_cost_transcript_dir "$_pm_dir" 2>/dev/null || true)"
      if [ -n "$_pm_costdir" ] && [ -d "$_pm_costdir" ] && ! _pms_journal_has cost "$_pm_pr"; then
        _pm_missing="$_pm_missing cost"
      fi
      _pm_missing="$_pm_missing reap"
    fi
  fi

  if [ -z "$_pm_missing" ]; then
    _pms_defer_note "$_pm_pr" "$_pm_sha" "$_pm_slug" "$_pm_defer"
    [ "$_pm_retry" -eq 0 ] && return 0 || return 1
  fi

  # ── RUN the outstanding hooks, in do_merge's order. Record-first: the $STATE row goes down before
  #    anything that can die, so a crash here can never re-merge or double-reconcile this PR.
  case " $_pm_missing " in
    *' state_row '*)
      # TRACKER REF: prefer the PR's OWN `Refs:` line over the per-worktree marker (review note). This
      # inverts do_merge's order deliberately. do_merge runs inside the lane that owns the marker, so
      # the two always agree; the sweep can be looking at an OLD merged PR whose slug has since been
      # re-spawned, and `.herd-ref-<slug>` then holds the NEW lane's ref — attaching it to the old PR's
      # landed row would credit the wrong tracker item. The PR body is the only source keyed to the PR.
      local _pm_ref; _pm_ref="$(_reconcile_pr_ref "$_pm_pr" 2>/dev/null || true)"
      [ -n "$_pm_ref" ] || _pm_ref="$(_slug_ref "$_pm_slug" 2>/dev/null || true)"
      # Stamp the row with the PR's REAL mergedAt, not "now" — see _pms_merged_prs.
      if [ -n "$_pm_ref" ]; then
        printf '%s %s %s %s\n' "$_pm_mts" "$_pm_pr" "$_pm_slug" "$_pm_ref" >> "$STATE"
      else
        printf '%s %s %s\n' "$_pm_mts" "$_pm_pr" "$_pm_slug" >> "$STATE"
      fi
      # NOT a `merge` event (review BLOCK). In this engine `merge` is a CLAIM: journal-audit.sh rule (a)
      # reads every `merge` as "this seat merged a PR and therefore owes a later `reap`". A reconciled
      # merge frequently owes no reap at all — a gh-UI or collaborator merge has no worktree here, which
      # is the very case this sweep exists to serve — so emitting `merge` would manufacture a permanent,
      # unfixable `merge_without_reap` finding for exactly those PRs. `merge_observed` says the true
      # thing: we OBSERVED a merge we did not perform, and `reap_owed` records whether a teardown is
      # actually outstanding, so a future audit rule can assert the honest invariant
      # (merge_observed[reap_owed=yes] ⇒ reap) without inventing an obligation we cannot discharge.
      local _pm_owed=no
      case " $_pm_missing " in *' reap '*) _pm_owed=yes ;; esac
      journal_append merge_observed pr "$_pm_pr" slug "$_pm_slug" sha "$_pm_sha" \
        reason reconcile reap_owed "$_pm_owed" ;;
  esac
  # Same order do_merge runs them in, so a reconciled tail is indistinguishable from a merged one.
  case " $_pm_missing " in *' approvals '*) purge_pr_approvals "$_pm_pr" ;; esac
  case " $_pm_missing " in *' ci_checks '*) purge_pr_ci_checks "$_pm_pr" ;; esac
  case " $_pm_missing " in
    *' cost '*) type cost_emit_merge >/dev/null 2>&1 && cost_emit_merge "$_pm_pr" "$_pm_slug" "$_pm_dir" ;;
  esac
  # HERD-401: routed through the wunit_* facade (wunit_reconcile/wunit_teardown) rather than calling
  # reconcile_backlog/_reap_slug by name — one-line delegations, so this is the SAME function call,
  # just resolved through the work-unit interface's names.
  case " $_pm_missing " in *' reconcile '*) wunit_reconcile "$_pm_pr" "$_pm_slug" "$_pm_sha" ;; esac
  case " $_pm_missing " in
    *' reap '*) wunit_teardown "$_pm_slug" "$_pm_dir" "$_pm_pr" "$_pm_sha" postmerge-sweep ;;   # last: it deletes $_pm_dir
  esac

  journal_append postmerge_reconciled pr "$_pm_pr" slug "$_pm_slug" sha "$_pm_sha" \
    missing "$(printf '%s' "${_pm_missing# }" | tr ' ' ',')"
  _pms_defer_note "$_pm_pr" "$_pm_sha" "$_pm_slug" "$_pm_defer"
  [ "$_pm_retry" -eq 0 ] && return 0 || return 1
}

# _pms_defer_note <pr#> <sha> <slug> <evidence> — journal a cross-seat deferral of the shared reconcile
# hook, ONCE per (pr,sha). A PR whose reap is deferred forever (dirty tree) is re-probed every pass, so
# without the note-once ledger this line would repeat every ~3 min alongside postmerge_reap_skip.
# No-op when there was nothing to defer.
_pms_defer_note() {
  local _pd_pr="$1" _pd_sha="$2" _pd_slug="$3" _pd_ev="${4:-}"
  [ -n "$_pd_ev" ] || return 0
  _pms_noted "$_pd_pr" "$_pd_sha" deferred && return 0
  journal_append postmerge_deferred pr "$_pd_pr" slug "$_pd_slug" \
    sha "$_pd_sha" obligations reconcile evidence "$_pd_ev"
  _pms_note "$_pd_pr" "$_pd_sha" deferred
}

# _sweep_merged_prs — the HERD-232 cadence entry point. Called every _PMS_SWEEP_INTERVAL ticks from the
# main loop. Steady state on a healthy seat: ONE `gh pr list`, then a run-once ledger hit per PR — zero
# journal lines, zero writes, byte-inert. Inert in dry-run. Never merges, never touches another seat's
# ledgers, never fails a tick.
_sweep_merged_prs() {
  [ -n "$DRYRUN" ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local _pms_rows _pms_rc=0
  _pms_rows="$(_pms_merged_prs)" || _pms_rc=$?
  [ "$_pms_rc" -eq 0 ] || return 0          # gh unreadable → skip the pass quietly (never a partial sweep)
  [ -n "$_pms_rows" ] || return 0
  # Read on FD 3, not stdin (review note): the loop body invokes gh, git, scribe.sh and
  # herd_teardown_slug, and any child that reads stdin would swallow the rest of the PR list and
  # silently truncate the sweep. The heredoc stays bound to 3, so the body's children inherit the
  # watcher's own stdin and can never consume it. The loop runs in the CURRENT shell (no pipe), so
  # ledger appends and reaps performed in the body persist.
  local _pms_pr _pms_sha _pms_branch _pms_mts
  while IFS=$'\t' read -r _pms_pr _pms_sha _pms_branch _pms_mts <&3; do
    [ -n "$_pms_pr" ] && [ -n "$_pms_sha" ] || continue
    _pms_swept "$_pms_pr" "$_pms_sha" && continue
    _pms_reconcile_one "$_pms_pr" "$_pms_sha" "$_pms_branch" "$_pms_mts" \
      && _pms_record "$_pms_pr" "$_pms_sha"
  done 3<<EOF
$_pms_rows
EOF
  return 0
}

# _sweep_journal_audit — HERD-238 journal-driven self-audit (the gap-finder). Runs on the same
# low-frequency housekeeping cadence as the tracker-state sweep. Shells out to the standalone
# journal-audit.sh which replays a BOUNDED journal window for invariant violations (merge without
# reap; *_dispatched with no terminal past family TTL; refix_bounce without wake_result; stale MAIN
# RED; pushed=no never followed by yes; known-fixture slugs), journals `journal_audit` events
# (component=audit), and appends operator-inbox rows. ADVISORY ONLY — never gates, never mutates.
# BEST-EFFORT + ship-dormant: byte-inert when JOURNAL_AUDIT=off (default); fail-soft on empty/short
# journal; can never fail or slow a tick. Points the inbox ledger at THIS watcher's $INBOX_LEDGER so
# build_operator_inbox surfaces findings when OPERATOR_INBOX is on.
_sweep_journal_audit() {
  [ -n "$DRYRUN" ] && return 0
  case "$(printf '%s' "${JOURNAL_AUDIT:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) ;;
    *) return 0 ;;
  esac
  [ -f "$HERE/journal-audit.sh" ] || return 0
  HERD_JOURNAL_AUDIT_INBOX="$INBOX_LEDGER" \
  HERD_JOURNAL_AUDIT_SEEN="$TREES/.agent-watch-journal-audit-seen" \
    bash "$HERE/journal-audit.sh" >/dev/null 2>&1 || true
}

# _sweep_lifecycle — HERD-193 supervised-process sweep, run on EVERY tick (it is a handful of stats
# over a handful of records — cheaper than the corpse sweep that already runs beside it).
#
# For each supervised process this seat spawned: a pid that has exited is RETIRED (the reconcile
# layer — a worker that died before its teardown is still accounted for), and anything past its
# deadline is journaled `lifecycle_expired` ONCE with the ROUTE naming the owner that tears that
# population down. It NEVER kills: the corpse sweep still TERMs a timed-out gate worker, the drainer
# reclaim gate still respawns a dead drainer, the stall detector still rows a quiet builder. This leg
# only makes the expiry visible and attributable, which is the whole of HERD-193's first increment.
#
# Byte-inert when LIFECYCLE_CONTRACTS=off (default) or in dry-run; can never fail or slow a tick.
_sweep_lifecycle() {
  [ -n "$DRYRUN" ] && return 0
  # Subshell so the inbox pin cannot leak into the rest of the tick (a prefix assignment on a shell
  # FUNCTION is not scoped the way it is on an external command).
  ( HERD_LIFECYCLE_INBOX="$INBOX_LEDGER"; lifecycle_sweep ) >/dev/null 2>&1 || true
  return 0
}

# ── Auto-refix: bounce BLOCK-reviewed PRs straight to the builder agent ────────────────────────
# Enabled by REVIEW_AUTOFIX=true in .herd/config (default false). When the watcher records a
# BLOCK verdict for PR <n> (slug S), it finds S's AGENT pane (NOT the tab's root shell pane —
# text sent there vanishes and the agent never wakes) REGARDLESS of whether the agent reads idle
# or 'done', and submits the re-task prompt via the DRIVER send-text surface: type the text
# (`herdr pane run`) then an explicit submit keystroke (`herdr pane send-keys Enter`) — HERD-186.
# Live 2026-07-08: `pane run` alone typed REVIEW_AUTOFIX / coordinator re-tasks into the agent
# prompt buffer and did NOT auto-submit (text sat until a manual Enter); bounces silently no-op'd
# (PR #284 journal: BLOCK with no refix_wake follow-through). After submit it verifies agent_status
# flips to "working" over a BACKED-OFF poll window (several checks across ~HERD_REFIX_WAIT_TIMEOUT
# seconds, default 15, per attempt), re-sending once before giving up. On persistent failure it
# surfaces "needs you · auto-refix failed" on the row.
#
# HISTORY (issue #86): the bounce used to reserve 'done' builders for a `claude --continue` relaunch
# (_resume_builder), on the theory their session had ENDED. But a 'done' agent's TUI is still in the
# pane foreground, so the `cd … && claude --continue …` command line was typed into that TUI as
# literal prompt text and never re-tasked the agent — the bounce escalated woke=0 (journal:
# 'auto-refix wake woke=0 escalated=true (done → done)') even though a raw submit nudge wakes the
# exact same agent. The raw-prompt submit below is now the single wake path for idle AND done
# builders; _resume_builder remains for the limit-auto-resume scheduler (a truly-frozen session).
#
# Sha-keyed refix-once semantics mirror review-once: one bounce per BLOCK per sha. A new commit
# changes the sha → a fresh bounce is eligible for the new sha's BLOCK (if any).
#
# KINDS (HERD-199 / HERD-173 pair): the same ledger records every autofix bounce as a 5th `kind`
# field (review | health | stale) — the RAIL it belongs to. The once-guard is per (pr,sha,kind), so
# different findings each bounce once. Legacy 4-field lines read as kind=review.
#
# BUDGET (HERD-229). The budget used to be ONE shared per-PR counter across every rail, and that
# conflated two very different stories. PR #328 spent round 1 on a healthcheck red, round 2 on a
# review BLOCK, round 3 on a stale base — three DIFFERENT first-time failures, each fixed on the
# first bounce — and then a genuinely new review BLOCK arrived with no bounce left and sat needs-you
# until a human relayed it by hand. A loop is the SAME check failing again; three checks each failing
# once is a pipeline converging. So the budget is per rail, and progress refunds it:
#
#   • PER-RAIL ROUNDS  — each rail carries its own counter, capped at `refix_rail_cap`
#     (= REFIX_MAX_ROUNDS, today's number). One rail's bounces never eat another's budget.
#   • RESET-ON-PROGRESS — when a rail's red RESOLVES (review PASS after a BLOCK, health CLEAN after a
#     red, base freshened), that rail's counter is zeroed: the loop demonstrably converges, so only
#     repeated failure of the SAME kind should exhaust. `refix_rail_reset` appends a `reset` row —
#     the ledger stays append-only, and a reset row is bookkeeping, never a bounce.
#   • TOTAL SAFETY CAP — a per-PR absolute ceiling (`refix_total_cap`, derived: 3× REFIX_MAX_ROUNDS,
#     no new config key) counts every bounce ever recorded for the PR, ignoring resets. A PR that
#     fails across all rails, over and over, still escalates rather than bouncing forever.
#
# A single-rail PR is byte-identical to the old behavior: with no resets and no other rail spending,
# rail count == total count, and the rail cap (REFIX_MAX_ROUNDS) is reached long before 3×.

# Ledger row shapes (positional, space-separated):
#   bounce: "<epoch> <pr#> <sha> <slug> <kind>"
#   reset:  "<epoch> <pr#> <sha> <slug> <kind> reset"
# Every reader below discriminates on the 6th field, so a reset row is never mistaken for a bounce
# (it must not satisfy the once-guard, and it must not spend the total ceiling).

# _refix_cap_num — REFIX_MAX_ROUNDS as a sane integer. A garbage value must not turn arithmetic into a
# crash inside the tick loop, and must not silently read as 0 (which would cap every rail at zero and
# escalate every PR on its first red). Fail-soft to the documented default.
_refix_cap_num() {
  local _rcn="${REFIX_MAX_ROUNDS:-3}"
  case "$_rcn" in ''|*[!0-9]*|0) _rcn=3 ;; esac
  printf '%s' "$_rcn"
}

# refix_rail_cap — the per-rail round cap. Each rail gets a budget of this size.
refix_rail_cap() { _refix_cap_num; }

# refix_total_cap — the per-PR ceiling across all rails, DERIVED from the rail cap (no new config key).
refix_total_cap() { printf '%s' "$(( $(_refix_cap_num) * 3 ))"; }

# refix_attempted <pr#> <headSha> [kind] — true if a bounce was already recorded for this exact
# pr+sha. With [kind], only a bounce of THAT kind counts (a legacy line with no kind is "review").
# Without [kind], any kind for that pr+sha matches (backward-compatible with pre-kind callers).
# A `reset` row carries the sha it progressed past, so it must be excluded here or it would satisfy
# the once-guard for that (pr,sha,kind) and silently suppress a later real bounce.
refix_attempted() {
  [ -s "$REFIX_STATE" ] || return 1
  awk -v p="$1" -v s="$2" -v k="${3:-}" \
    '$2==p && $3==s && $6!="reset" && (k=="" || ($5==k) || (k=="review" && $5=="")){f=1} END{exit !f}' \
    "$REFIX_STATE" 2>/dev/null
}

# refix_total_count <pr#> — every bounce ever recorded for this PR, across all shas and all rails.
# This is what the TOTAL safety cap reads; resets never refund it.
refix_total_count() {
  [ -s "$REFIX_STATE" ] || { printf '0'; return 0; }
  awk -v p="$1" '$2==p && $6!="reset"{n++} END{print n+0}' "$REFIX_STATE" 2>/dev/null || printf '0'
}

# refix_round_count <pr#> — the PR's lifetime bounce total. Retained under its original name for the
# callers that want the whole story (the escalated-reviewer row's "N failed refix rounds").
refix_round_count() { refix_total_count "$1"; }

# refix_rail_count <pr#> <kind> — bounces on ONE rail SINCE THAT RAIL LAST MADE PROGRESS. This is the
# rail's live budget: the ledger is chronological and append-only, so a `reset` row simply zeroes the
# running count as the scan passes it. This is what the per-rail cap reads.
refix_rail_count() {
  [ -s "$REFIX_STATE" ] || { printf '0'; return 0; }
  awk -v p="$1" -v k="$2" '
    $2==p && (($5==k) || (k=="review" && $5=="")) {
      if ($6=="reset") n=0; else n++
    }
    END{print n+0}' "$REFIX_STATE" 2>/dev/null || printf '0'
}

# refix_round_count_kind <pr#> <kind> — LIFETIME bounces of one kind (resets do not refund it). Not a
# budget: it is EVIDENCE about a particular gate's history — a health bounce proves nothing about
# whether the cheap REVIEWER missed an issue (review note #2). `_maybe_arm_review_escalation` reads it
# to decide the reviewer needs a smarter model, a question a rail reset must not erase.
refix_round_count_kind() {
  [ -s "$REFIX_STATE" ] || { printf '0'; return 0; }
  awk -v p="$1" -v k="$2" \
    '$2==p && $6!="reset" && (($5==k) || (k=="review" && $5=="")){n++} END{print n+0}' "$REFIX_STATE" 2>/dev/null || printf '0'
}

# _refix_budget_reason <pr#> <kind> — when this rail may NOT bounce again, print the honest cap phrase
# and return 0; print nothing and return 1 while budget remains. The two ceilings are named apart on
# the row because the remedy differs: a spent RAIL means one check keeps failing (read the finding); a
# spent TOTAL means the PR is thrashing across rails (read the PR).
_refix_budget_reason() {
  local _rbr_pr="$1" _rbr_kind="$2" _rbr_rail _rbr_total _rbr_rcap _rbr_tcap
  _rbr_rcap="$(refix_rail_cap)"; _rbr_tcap="$(refix_total_cap)"
  _rbr_rail="$(refix_rail_count "$_rbr_pr" "$_rbr_kind")"
  _rbr_total="$(refix_total_count "$_rbr_pr")"
  if [ "${_rbr_rail:-0}" -ge "$_rbr_rcap" ] 2>/dev/null; then
    printf 'refix limit (%s rounds) reached' "$_rbr_rcap"; return 0
  fi
  if [ "${_rbr_total:-0}" -ge "$_rbr_tcap" ] 2>/dev/null; then
    printf 'refix limit (%s total rounds across rails) reached' "$_rbr_tcap"; return 0
  fi
  return 1
}

# record_refix <pr#> <headSha> <slug> [kind=review] — append one bounce record.
# The ledger is POSITIONAL and space-separated, so an EMPTY <slug> would collapse the line to four
# fields: awk then reads the KIND out of $4 and sees $5="" — i.e. a legacy "review" line — so
# `refix_attempted <pr> <sha> health` returns false and the once-guard OPENS (re-bounce every tick).
# Not reachable today (the slug comes from a worktree name), but the failure is silent and unbounded,
# so substitute a '-' placeholder rather than rely on a caller invariant (review note #2).
record_refix() {
  local _rr_slug="${3:-}"; [ -n "$_rr_slug" ] || _rr_slug='-'
  printf '%s %s %s %s %s\n' "$(date +%s)" "$1" "$2" "$_rr_slug" "${4:-review}" >> "$REFIX_STATE"
}

# refix_rail_reset <pr#> <kind> [sha] [slug] — this rail's red RESOLVED; zero its budget by appending a
# `reset` row. NO-OP when the rail has nothing to zero, which is what makes it safe on a hot path (the
# health gate calls it on every CLEAN verdict) and keeps the ledger from growing without bound.
# Fail-soft: an unwritable ledger loses a refund, never a tick.
refix_rail_reset() {
  local _rrr_pr="$1" _rrr_kind="$2" _rrr_sha="${3:-}" _rrr_slug="${4:-}" _rrr_n
  [ -n "$_rrr_pr" ] && [ -n "$_rrr_kind" ] || return 0
  _rrr_n="$(refix_rail_count "$_rrr_pr" "$_rrr_kind")"
  [ "${_rrr_n:-0}" -gt 0 ] 2>/dev/null || return 0
  [ -n "$_rrr_sha" ] || _rrr_sha='-'
  [ -n "$_rrr_slug" ] || _rrr_slug='-'
  printf '%s %s %s %s %s reset\n' "$(date +%s)" "$_rrr_pr" "$_rrr_sha" "$_rrr_slug" "$_rrr_kind" \
    >> "$REFIX_STATE" || return 0
  journal_append refix_rail_reset pr "$_rrr_pr" sha "$_rrr_sha" slug "$_rrr_slug" kind "$_rrr_kind" \
    rounds "$_rrr_n" reason "rail resolved its red — per-rail refix budget restored"
}

# ── ROW TRUTH: "needs you" means NOBODY is on it (HERD-173) ────────────────────────────────────────
# A red row that says "needs you" while a builder is ACTIVELY fixing that very red is a lie, and it is
# the expensive kind: the operator context-switches into work already in flight. Two ways an agent can
# be on a slug's red:
#   (a) the watcher BOUNCED it — a refix record exists for this exact (pr,sha,kind); the agent has the
#       re-task prompt and we are waiting for its push. We know the round, so we show k/cap.
#   (b) an agent is BUSY — agent_status reads "working". This path is live in the DEFAULT config
#       (HEALTHCHECK_AUTOFIX=false), so its blast radius is EVERY project, not just autofix adopters.
#       NOTE (review, non-blocking #1): `herdr agent
#       list` reports one GLOBAL status per agent; it carries no sha and no evidence of WHAT the agent
#       is working on. So (b) is a heuristic: a builder busy with anything at all reads "fix in
#       progress" and is not bounced until it goes idle. That is deliberately the SAFE direction — we
#       never type a re-task prompt into a working agent, and the next idle tick corrects the row — but
#       it is weaker than "is on THIS red", and the invariant it upholds is one-way: a `needs you` row
#       is trustworthy; a `fix in progress` row can be a busy agent doing something else.
#
# THE CONVERSE MATTERS TOO (HERD-173 review BLOCK): a refix RECORD is not proof anyone is fixing. The
# bounce writes its record BEFORE delivery, so the once-guard survives a failed send — which means a
# record also exists when the wake PROVABLY failed, and when the agent died right after being woken. If
# (a) trusted the record alone, that one-tick "auto-refix failed" escalation would be overwritten by
# "fix in progress · awaiting push" on the very next tick and never recover: the once-guard blocks a
# re-bounce, the sha never changes (nobody is fixing it), and the cap is never reached. So (a) is
# gated on two DURABLE disproofs — a stuck marker (the wake failed) and a positive dead/missing
# liveness probe (the agent is gone) — either of which drops the row back to the honest "needs you".
#
# Only a POSITIVE signal suppresses "needs you" — an absent/blind `herdr agent list` yields no note and
# the row falls through to the honest needs-you (fail toward asking the human, never toward silence).

# Stuck-bounce marker: a DURABLE record that a bounce for this exact (pr,sha,kind) was delivered to
# nobody — both `herdr pane run` + wake-verify attempts failed, or the agent pane was gone. Mirrors
# _record_refix_dead's notify-once shape. Keyed by sha, so a new commit clears the way for a fresh
# bounce. Its presence is what stops _active_fix_note claiming a fix is in flight.
_refix_stuck_file()   { printf '%s' "$TREES/.agent-watch-refix-stuck-$3-$1-$2"; }
_refix_stuck_seen()   { [ -f "$(_refix_stuck_file "$1" "$2" "$3")" ]; }
_record_refix_stuck() { printf '%s\n' "${4:-unknown}" > "$(_refix_stuck_file "$1" "$2" "$3")" 2>/dev/null || true; }
_refix_stuck_reason() { sed -n 1p "$(_refix_stuck_file "$1" "$2" "$3")" 2>/dev/null; }

# _escalate_refix_stuck <pr#> <sha> <slug> <kind> <reason> — the SINGLE escalation point for "we bounced
# this red and nobody is fixing it". Records the durable marker, journals, and notifies EXACTLY ONCE per
# (pr,sha,kind) — the dead/missing and cap paths both notify, and the failed-wake path used to do
# neither (it painted a row that the next tick overwrote). Idempotent: later ticks re-paint the row from
# the marker without re-journaling or re-notifying.
_escalate_refix_stuck() {
  local _ers_pr="$1" _ers_sha="$2" _ers_slug="$3" _ers_kind="$4" _ers_reason="$5"
  _refix_stuck_seen "$_ers_pr" "$_ers_sha" "$_ers_kind" && return 0
  _record_refix_stuck "$_ers_pr" "$_ers_sha" "$_ers_kind" "$_ers_reason"
  journal_append refix_stalled pr "$_ers_pr" sha "$_ers_sha" slug "$_ers_slug" kind "$_ers_kind" \
    reason "$_ers_reason"
  herd_driver_notify "⚠️ refix stalled: ${_ers_slug}" \
    "PR #${_ers_pr} was bounced but nobody is fixing it — ${_ers_reason}" default
}

# _active_fix_note <pr#> <headSha> <slug> <kind> — print the in-progress phrase and return 0 when an
# agent is on this red; print nothing and return 1 when nobody is.
_active_fix_note() {
  local _afn_pr="$1" _afn_sha="$2" _afn_slug="$3" _afn_kind="$4" _afn_rounds _afn_live
  if refix_attempted "$_afn_pr" "$_afn_sha" "$_afn_kind" \
     && ! _refix_stuck_seen "$_afn_pr" "$_afn_sha" "$_afn_kind"; then
    # A bounce was delivered and not disproved by a stuck marker. One more disproof: the agent may have
    # DIED after the wake. Only a POSITIVE dead/missing overturns the record ('unknown' keeps the row).
    _afn_live="$(_agent_liveness "$_afn_slug")"
    case "$_afn_live" in
      dead|missing) : ;;
      *)
        # k/cap is THIS RAIL's budget (HERD-229) — the row names the rail's red, so the number beside
        # it must be that rail's rounds, not the PR's lifetime total across every rail.
        _afn_rounds="$(refix_rail_count "$_afn_pr" "$_afn_kind")"
        printf 'fix in progress · awaiting push (round %s/%s)' "${_afn_rounds:-1}" "$(refix_rail_cap)"
        return 0 ;;
    esac
  fi
  # (b) — also the RESCUE path: a human who re-tasks a builder whose bounce got stuck flips it back to
  # "working", and the row must stop shouting "needs you" again.
  if [ "$(_agent_status "$_afn_slug")" = "working" ]; then
    printf 'fix in progress · awaiting push (agent working)'
    return 0
  fi
  return 1
}

# _refix_stalled_row <pr#> <headSha> <slug> <kind> <slug-cell> <pr-cell> — the row for a red that WAS
# bounced but that nobody is on: the wake failed, or the agent died right after. Records the durable
# stuck marker + journals + notifies EXACTLY ONCE per (pr,sha,kind), then prints the needs-you row every
# tick thereafter (idempotent). This is the escalation that used to live for a single tick.
_refix_stalled_row() {
  local _rsr_pr="$1" _rsr_sha="$2" _rsr_slug="$3" _rsr_kind="$4" _rsr_sl="$5" _rsr_pn="$6"
  local _rsr_reason _rsr_live _rsr_what
  if _refix_stuck_seen "$_rsr_pr" "$_rsr_sha" "$_rsr_kind"; then
    _rsr_reason="$(_refix_stuck_reason "$_rsr_pr" "$_rsr_sha" "$_rsr_kind")"
  else
    _rsr_live="$(_agent_liveness "$_rsr_slug")"
    case "$_rsr_live" in
      dead)    _rsr_reason="agent died after the bounce (session unwakeable)" ;;
      missing) _rsr_reason="agent pane vanished after the bounce" ;;
      *)       _rsr_reason="the bounce was delivered to nobody" ;;
    esac
    _escalate_refix_stuck "$_rsr_pr" "$_rsr_sha" "$_rsr_slug" "$_rsr_kind" "$_rsr_reason"
  fi
  case "$_rsr_kind" in health) _rsr_what="health-check red" ;; stale) _rsr_what="stale base" ;; ci) _rsr_what="CI red" ;; *) _rsr_what="review blocked" ;; esac
  printf '%s' "    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_rsr_sl}${C_RESET}${_rsr_pn} ${C_RED}needs you · ${_rsr_what} · ${_rsr_kind} autofix stalled: ${_rsr_reason} · re-task by hand${C_RESET}"
}

# Dead-agent refix escalation dedup (HERD-114): the review-block path re-enters every tick while a PR
# stays blocked, so a builder whose agent SESSION died would re-journal + re-notify each tick. This
# tiny per-(pr,sha) marker fires the journal event + notification EXACTLY ONCE per dead escalation
# (mirroring the dead-builder ledger's notify-once), while the red console row is (idempotently) re-set
# every tick. A new commit changes the sha → a fresh escalation is eligible if the new agent is dead too.
_refix_dead_marker()  { printf '%s' "$TREES/.agent-watch-refix-dead-$1-$2"; }
_refix_dead_seen()    { [ -f "$(_refix_dead_marker "$1" "$2")" ]; }
_record_refix_dead()  { : > "$(_refix_dead_marker "$1" "$2")" 2>/dev/null || true; }

# _maybe_arm_review_escalation <pr#> — called right AFTER record_refix. If this PR has now accumulated
# at least REVIEW_EVIDENCE_ESCALATE_ROUNDS (default 2) failed REVIEW refix rounds, the cheap reviewer's
# PASS has been proven wrong across two rounds — arm a one-shot Opus escalation for the PR's NEXT review
# dispatch. Counts REVIEW rounds ONLY (refix_round_count_kind): a healthcheck bounce is evidence about
# the SUITE, not about the reviewer, and must never arm an Opus re-review it says nothing about.
_maybe_arm_review_escalation() {
  local _mare_pr="$1" _mare_rounds
  _mare_rounds="$(refix_round_count_kind "$_mare_pr" review)"
  [ "${_mare_rounds:-0}" -ge "${REVIEW_EVIDENCE_ESCALATE_ROUNDS:-2}" ] 2>/dev/null || return 0
  : > "$(_review_escalate_file "$_mare_pr")" 2>/dev/null || true
}

# _find_builder_pane_id <slug> — find the herdr agent pane_id for the builder whose identity==slug
# and whose agent_status is "idle" (idle means it's waiting for a task, not already working).
# Identity is `name` when set (lane-started builders), else `agent` (report-agent-only registrations).
# Prints the pane_id to stdout; prints nothing if the agent is absent or already working.
_find_builder_pane_id() {
  local _fpid_slug="$1"
  herdr agent list 2>/dev/null | SLUG="$_fpid_slug" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
  agents = (json.load(sys.stdin).get("result") or {}).get("agents") or []
  for a in agents:
    ident = a.get("name") or a.get("agent") or ""
    if ident == slug and a.get("agent_status") == "idle":
      print(a.get("pane_id", ""), end="")
      break
except Exception:
  pass
' 2>/dev/null || true
}

# _agent_status <slug> — current agent_status string for this agent (empty if not found).
# Identity match: `name` when set, else `agent` (same rule as _find_builder_pane_id).
_agent_status() {
  local _as_slug="$1"
  herdr agent list 2>/dev/null | SLUG="$_as_slug" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
  agents = (json.load(sys.stdin).get("result") or {}).get("agents") or []
  for a in agents:
    ident = a.get("name") or a.get("agent") or ""
    if ident == slug:
      print(a.get("agent_status", ""), end="")
      break
except Exception:
  pass
' 2>/dev/null || true
}

# _agent_liveness <slug> — three-valued liveness (alive|dead|unknown) of this builder's agent SESSION
# via the driver seam (herd_driver_agent_liveness): is its underlying PROCESS actually running, as
# opposed to a stale agent_status word herdr keeps reporting after a crash killed it (HERD-114)? Only a
# POSITIVE 'dead' ever changes a caller's behavior; 'unknown' (probe blind) preserves prior behavior so
# the console stays byte-identical whenever every agent is live OR the probe cannot see the truth.
_agent_liveness() {
  herd_driver_agent_liveness "$1" 2>/dev/null || printf 'unknown'
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

# ── SUITE/WORKTREE WRITE INTERLOCK (HERD-227) ─────────────────────────────────────────────────────
# `_health_worker` runs the ~9-min healthcheck suite INSIDE the PR's worktree. Every refix rail MUTATES
# that same worktree: the stale-base bounce types `git merge <base>` into the builder's pane, its
# resolver fallback spawns an agent that merges in the tree, and the review/health bounces re-task the
# builder to edit files and re-run. Two writers, one worktree.
#
# Until HERD-227 nothing collided, but only by ACCIDENT: the stale-dup gate sat AFTER `_healthcheck_gate`,
# and a RUNNING suite short-circuits the whole action pass (`_HC_RESULT=RUNNING` → `continue`), so no rail
# was reachable while a suite was live. Hoisting the gate ahead of the healthcheck removed that interlock
# for the stale-base rail: a hold arriving mid-suite would re-task the builder to merge the base UNDER the
# running suite. The head sha does not move until the builder pushes, so `record_health_result` then
# sha-caches a POISONED verdict — a false CODEERROR red from a half-merged tree, or (worse) a false CLEAN
# blessing a tree that sha never had.
#
# So the interlock is now EXPLICIT, and shared by every rail rather than re-derived per rail (R2: one
# deterministic check at every enforcement surface). Note what does NOT defer: the gate's DECISION still
# runs first, so a held sha still dispatches no review and no suite. Only the MUTATION waits.
#
# _suite_inflight_key <pr#> — print the key of a LIVE health suite for this PR, else nothing (rc 1).
# ANY sha counts: a suite dispatched for an earlier sha is still writing in the same worktree, and the
# live marker is what proves a worker holds it. Fail-soft — an absent/dead marker reads as "no suite".
_suite_inflight_key() {
  local _sik_pr="$1" _sik_f
  [ -n "$_sik_pr" ] || return 1
  # The glob is anchored on "<pr>-" so PR 9 never matches PR 90's marker; a no-match glob stays literal
  # and fails the -f test.
  for _sik_f in "$TREES"/.health-inflight-"$_sik_pr"-*; do
    { [ -f "$_sik_f" ] && _health_pid_live "$_sik_f"; } || continue
    printf '%s' "${_sik_f##*/.health-inflight-}"
    return 0
  done
  return 1
}

# _defer_for_suite <pr#> <slug> <sha> <display-idx> <kind> <row-label>
# Returns 0 → a live suite holds this PR's worktree: the honest deferred row is set and the defer is
# journaled; THE CALLER MUST NOT MUTATE (and must not burn its once-guard or a refix round — the heal
# fires normally on the first tick after the suite collects). Returns 1 → no suite in flight, proceed.
_defer_for_suite() {
  local _dfs_pr="$1" _dfs_slug="$2" _dfs_sha="$3" _dfs_idx="$4" _dfs_kind="$5" _dfs_label="$6"
  local _dfs_key _dfs_sl _dfs_pn _dfs_age
  _dfs_key="$(_suite_inflight_key "$_dfs_pr")" || return 1
  _dfs_sl="$(_slug_cell "$_dfs_slug")"
  _dfs_pn=" ${C_DIM}#${_dfs_pr}${C_RESET} ·"
  _dfs_age="$(_fmt_age "$(_marker_age "$(_health_inflight_file "$_dfs_key")")" 2>/dev/null || printf '?')"
  DISPLAY[_dfs_idx]="    ${C_YELLOW}⏳${C_RESET} ${C_BOLD}${_dfs_sl}${C_RESET}${_dfs_pn} ${C_YELLOW}${_dfs_label} · waiting for suite (health-check running ${_dfs_age})${C_RESET}"
  journal_append refix_deferred_suite pr "$_dfs_pr" sha "$_dfs_sha" slug "$_dfs_slug" \
    kind "$_dfs_kind" suite_key "$_dfs_key"
  return 0
}

# _handle_block_verdict <pr#> <slug> <headSha> <display-idx>
# Called when the review verdict for a PR is BLOCK (from the ledger or a fresh gate step). If
# REVIEW_AUTOFIX=true, attempts to bounce the builder agent; otherwise shows the standard message.
# Always updates DISPLAY[<idx>]; calls render internally before the blocking wait so the user sees
# "refixing" while the bounce is in progress.
_handle_block_verdict() {
  local _hbv_pr="$1" _hbv_slug="$2" _hbv_sha="$3" _hbv_idx="$4" _hbv_wt="${5:-}"
  local _hbv_sl _hbv_pn _hbv_live
  _hbv_sl="$(_slug_cell "$_hbv_slug")"
  _hbv_pn=" ${C_DIM}#${_hbv_pr}${C_RESET} ·"

  # herd/gates (HERD-194): a BLOCK is a gate FAIL, but we deliberately post NOTHING here. The fail-safe
  # rests only on the ABSENCE of a herd/gates=success — a BLOCK simply means success is never posted, so
  # the PR stays unmergeable under `require herd/gates` protection. We must NOT post a `failure` status:
  # a non-passing status flips a CLEAN sha to mergeStateStatus=UNSTABLE (in the DEFAULT unprotected
  # config, where herd/gates is not required), which would strand the PR out of the candidate loop and
  # silently break the block/override/auto-refix paths this very function drives. See post_gate_status.

  if [ "${REVIEW_AUTOFIX:-false}" = "true" ] && [ -z "${DRYRUN:-}" ]; then
    # HARDENING (HERD-155 F5): NEVER pane-run a re-task prompt into a LIMIT-PARKED builder. A builder
    # that hit the account usage limit AFTER opening its PR is parked at the limit arrow-menu (or a
    # frozen session); the bounce below types the fix prompt via `herdr pane run`, which would land in
    # the menu — exactly the keystroke-into-a-menu hazard this change closes. Consult the SAME limit
    # detector the idle path uses and, on a hit, route to the park/resume handler (surface the hold +
    # schedule the resume) instead of typing. refix-once is NOT burned, so the bounce fires normally
    # once the builder is back. Inert when the worktree is unknown or there is no limit signal.
    if [ -n "$_hbv_wt" ]; then
      local _hbv_lreset
      if _hbv_lreset="$(_detect_limit_hit "$_hbv_slug" "$_hbv_wt")"; then
        journal_append refix_deferred_limit pr "$_hbv_pr" sha "$_hbv_sha" slug "$_hbv_slug" reset_at "${_hbv_lreset:-0}"
        _handle_limit_blocked "$_hbv_slug" "$_hbv_wt" "$_hbv_idx" "${_hbv_lreset:-0}"
        return 0
      fi
    fi
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
    local _hbv_rounds _hbv_note _hbv_capmsg
    _hbv_rounds="$(refix_rail_count "$_hbv_pr" review)"
    if _hbv_note="$(_active_fix_note "$_hbv_pr" "$_hbv_sha" "$_hbv_slug" review)"; then
      # An agent is ON this red — either we bounced it for this sha (and neither a stuck marker nor a
      # dead probe disproves that), or it reads "working". Never "needs you", and never a second bounce
      # into a builder that is already fixing: wait for its push (HERD-173 row truth).
      DISPLAY[_hbv_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_YELLOW}review blocked · ${_hbv_note}${C_RESET}"
    elif refix_attempted "$_hbv_pr" "$_hbv_sha" review; then
      # Bounced, but NOBODY is on it: the wake failed, or the agent died right after. Escalate durably —
      # this row used to be overwritten by a false "awaiting push" on the very next tick.
      DISPLAY[_hbv_idx]="$(_refix_stalled_row "$_hbv_pr" "$_hbv_sha" "$_hbv_slug" review "$_hbv_sl" "$_hbv_pn")"
    elif _hbv_capmsg="$(_refix_budget_reason "$_hbv_pr" review)"; then
      DISPLAY[_hbv_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_RED}needs you · ${_hbv_capmsg} · see PR #${_hbv_pr}${C_RESET}"
    elif _hbv_live="$(_agent_liveness "$_hbv_slug")"; [ "$_hbv_live" = "dead" ] || [ "$_hbv_live" = "missing" ]; then
      # HERD-114/HERD-135 PREFLIGHT — the auto-refix bounce wakes the builder by typing the re-task
      # prompt into its agent pane. If that agent SESSION is DEAD (process killed — e.g. a herdr server
      # stop — while the pane/worktree persist and herdr still reports a stale 'done') OR the agent pane
      # is MISSING entirely (the pane vanished and cleanup closed the leftover shell — the 2026-07-08
      # PR #249 incident), typing a wake can only hit nobody. Detect it up front and escalate LOUDLY
      # WITHOUT burning a refix round on a guaranteed-failed wake. Only a POSITIVE 'dead'/'missing'
      # escalates here; 'unknown'/'alive' fell through to the normal bounce below, so the path is
      # byte-identical whenever the agent is live OR the probe cannot see the truth (no false-red).
      if [ "$_hbv_live" = "missing" ]; then
        DISPLAY[_hbv_idx]="    ${C_RED}🫥${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_RED}needs you · agent missing (no agent pane) — re-task by hand · see PR #${_hbv_pr}${C_RESET}"
      else
        DISPLAY[_hbv_idx]="    ${C_RED}💀${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_RED}needs you · agent dead · session unwakeable — re-task by hand · see PR #${_hbv_pr}${C_RESET}"
      fi
      # Journal + notify ONCE per (pr,sha) — this path re-enters every tick while the PR stays blocked.
      if ! _refix_dead_seen "$_hbv_pr" "$_hbv_sha"; then
        _record_refix_dead "$_hbv_pr" "$_hbv_sha"
        if [ "$_hbv_live" = "missing" ]; then
          journal_append refix_escalated_missing pr "$_hbv_pr" sha "$_hbv_sha" slug "$_hbv_slug" \
            reason "agent pane missing — no agent to wake; escalated for human"
          herd_driver_notify "🫥 agent missing: ${_hbv_slug}" \
            "PR #${_hbv_pr} review-blocked but the builder has no agent pane (vanished) — re-task by hand" default
        else
          journal_append refix_escalated_dead pr "$_hbv_pr" sha "$_hbv_sha" slug "$_hbv_slug" \
            reason "agent session dead — wake would fail; escalated for human"
          herd_driver_notify "💀 agent dead: ${_hbv_slug}" \
            "PR #${_hbv_pr} review-blocked but the builder's session is dead (unwakeable) — re-task by hand" default
        fi
      fi
    elif _defer_for_suite "$_hbv_pr" "$_hbv_slug" "$_hbv_sha" "$_hbv_idx" review "review blocked"; then
      # SUITE WRITE INTERLOCK (HERD-227). Reachable under GATE_DISPATCH=parallel, where a review verdict
      # can land while this PR's suite is still running in the worktree; the serial default cannot get
      # here (a RUNNING suite short-circuits the pass first). Row + journal handled by _defer_for_suite;
      # once-guard NOT burned, no refix round spent.
      :
    else
      local _hbv_round_num
      _hbv_round_num="$((_hbv_rounds + 1))"
      DISPLAY[_hbv_idx]="    ${C_CYAN}🔁${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_CYAN}refixing (round ${_hbv_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
      render
      # Record BEFORE sending so refix-once holds even if pane lookup or delivery fails.
      record_refix "$_hbv_pr" "$_hbv_sha" "$_hbv_slug" review
      # A 2nd+ failed refix round on this PR is evidence the cheap reviewer missed the real issue —
      # arm an Opus escalation for the PR's next review dispatch (consumed once, in _review_gate_step).
      _maybe_arm_review_escalation "$_hbv_pr"
      local _hbv_status_before
      _hbv_status_before="$(_agent_status "$_hbv_slug")"
      # Structured finding (HERD-104): surface the reviewer's rule/why/location so the bounce is
      # ACTIONABLE — the builder sees WHAT rule broke, WHY, and WHERE, not just "read the PR". Read
      # the sha-keyed cache written when the BLOCK was collected; fail-soft when it is absent
      # (legacy ledger row, or an unstructured verdict) — the prompt then omits the finding line.
      local _hbv_finding="" _hbv_blk _hbv_rule="" _hbv_why="" _hbv_loc=""
      _hbv_blk="$(_review_block_file "$_hbv_pr" "$_hbv_sha")"
      if [ -s "$_hbv_blk" ]; then
        _hbv_rule="$(sed -n 1p "$_hbv_blk" 2>/dev/null)"
        _hbv_why="$(sed -n 2p "$_hbv_blk" 2>/dev/null)"
        _hbv_loc="$(sed -n 3p "$_hbv_blk" 2>/dev/null)"
        [ -n "$_hbv_rule" ] && _hbv_finding="${_hbv_finding}Rule violated: ${_hbv_rule}"$'\n'
        [ -n "$_hbv_why" ]  && _hbv_finding="${_hbv_finding}Why: ${_hbv_why}"$'\n'
        [ -n "$_hbv_loc" ]  && _hbv_finding="${_hbv_finding}Location: ${_hbv_loc}"$'\n'
      fi
      journal_append refix_bounce pr "$_hbv_pr" sha "$_hbv_sha" slug "$_hbv_slug" \
        round "$_hbv_round_num" agent_status_before "${_hbv_status_before:-unknown}" \
        rule "${_hbv_rule:-}" location "${_hbv_loc:-}"
      local _hbv_pane_id _hbv_woke=0 _hbv_escalated=false
      local _hbv_prompt
      _hbv_prompt="PR #${_hbv_pr} was review-blocked.
${_hbv_finding}Read the full review: gh pr view ${_hbv_pr}
Fix every issue the reviewer raised, run the healthcheck, push your fix, and reply to the review comment once done."
      # Target the builder's AGENT pane whether it reads idle OR 'done' (never a 'working' one) —
      # a 'done' builder's agent TUI is still up and waiting, so submitting the raw re-task prompt
      # (type + explicit Enter — HERD-186 / issue #86) wakes it. This is the SINGLE wake path for
      # both states; the old idle-only lookup + `--continue` resume for 'done' builders never
      # actually re-tasked them (woke=0 → escalated on every BLOCK).
      _hbv_pane_id="$(_find_builder_pane_id_any "$_hbv_slug")"
      if [ -n "$_hbv_pane_id" ]; then
        local _hbv_wait="${HERD_REFIX_WAIT_TIMEOUT:-15}"
        # Submit via the driver send-text seam (pane run + send-keys Enter), then verify wake over a
        # backed-off window; if the first window expires, re-send once and verify again.
        herd_driver_send_text "$_hbv_pane_id" "$_hbv_prompt"
        if _wait_agent_working "$_hbv_slug" "$_hbv_wait"; then
          _hbv_woke=1
        else
          herd_driver_send_text "$_hbv_pane_id" "$_hbv_prompt"
          if _wait_agent_working "$_hbv_slug" "$_hbv_wait"; then
            _hbv_woke=1
          else
            DISPLAY[_hbv_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_RED}needs you · auto-refix failed · check pane${C_RESET}"
            _hbv_escalated=true
            _escalate_refix_stuck "$_hbv_pr" "$_hbv_sha" "$_hbv_slug" review "the builder never woke (prompt delivered twice)"
          fi
        fi
      else
        DISPLAY[_hbv_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hbv_sl}${C_RESET}${_hbv_pn} ${C_RED}needs you · auto-refix failed · agent pane not found${C_RESET}"
        _hbv_escalated=true
        _escalate_refix_stuck "$_hbv_pr" "$_hbv_sha" "$_hbv_slug" review "no agent pane to deliver the bounce to"
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

# ── Auto-heal STALE-BASE holds (HERD-199) ─────────────────────────────────────────────────────────
# STALE_BASE_AUTOFIX=on|off (default off, ship-dormant). The stale-dup gate (HERD-188) correctly holds
# two flavors: DUPLICATE (re-implements shipped work — a judgment call, always human) and STALE-BASE
# (touched files moved on origin/main — purely MECHANICAL). When enabled, a STALE-BASE hold self-heals
# on the same rails as the review/health autofixes:
#   • sha-keyed once-guard, kind=stale — one heal attempt per commit;
#   • the STALE rail's OWN round budget (REFIX_MAX_ROUNDS), zeroed whenever the base comes back fresh
#     and bounded by the per-PR total ceiling (HERD-229);
#   • LIVE builder → re-task with `git merge $DEFAULT_BRANCH` + push; row reads
#     `rebasing · awaiting push`;
#   • NO live builder (foreign / reaped / dead / missing pane) → dispatch the EXISTING conflict
#     resolver (herd-resolve.sh), which already merges $DEFAULT_BRANCH and heals mechanical conflicts;
#   • bounce-exhaustion alone escalates to needs-you.
# DUPLICATE always stays a human hold. OFF (default) is byte-identical to the pre-HERD-199 hold path:
# same 🛑 row, same PR comment, no ledger write, no bounce, no resolver spawn.

# _stale_base_autofix_enabled — true iff STALE_BASE_AUTOFIX opts in. Any unrecognized value → off.
_stale_base_autofix_enabled() {
  case "$(printf '%s' "${STALE_BASE_AUTOFIX:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# ── CI auto-repair for INHERITED reds (HERD-250) ──────────────────────────────────────────────────
# CI_AUTOREPAIR=on|off (default off, ship-dormant). When a PR is MERGEABLE but UNSTABLE with a FAILING
# required CI check, herd/gates already PASSED for the head sha, AND the branch is BEHIND main, the
# failure is almost certainly main's already-fixed bugs riding the branch (PR #353). A base-refresh
# (merge $DEFAULT_BRANCH) picks them up — the SAME mechanical heal as STALE_BASE_AUTOFIX, but keyed
# on CI-red+behind-base rather than touched-file overlap (which #353's diff never hit).
#
# NEVER silently merges a red PR. A REAL new-code CI failure (failing CI on an up-to-date branch, or
# without a gates blessing) falls through to the existing needs-you row. OFF is byte-identical to the
# pre-HERD-250 UNSTABLE-fail path. Journals `ci_repair` events. Kind=ci on the shared refix rails so
# the CI rail budgets independently of review/health/stale.
#
# Decision predicates live in scripts/herd/ci-repair.sh (ci_autorepair_enabled / ci_repair_eligible);
# this handler owns the bounce / resolver / row truth, mirroring _handle_stale_dup.

# _handle_ci_repair <pr#> <slug> <headSha> <display-idx> <worktree-dir> <branch> <ci-summary>
# Called when the classifier has a FAILING required CI check. Returns 0 if THIS handler set DISPLAY
# (heal in progress, deferred, or needs-you after a spent budget); returns 1 if the caller should
# paint the classic needs-you · CI-failed row (off / ineligible / dry-run).
_handle_ci_repair() {
  local _hcr_pr="$1" _hcr_slug="$2" _hcr_sha="$3" _hcr_idx="$4" _hcr_wt="${5:-}" \
        _hcr_branch="${6:-}" _hcr_ci="${7:-}"
  local _hcr_sl _hcr_pn _hcr_rounds _hcr_round_num _hcr_base _hcr_capmsg

  # OFF / dry-run: byte-identical to pre-HERD-250 — caller paints needs-you, no ledger, no bounce.
  if ! ci_autorepair_enabled || [ -n "${DRYRUN:-}" ]; then
    return 1
  fi

  _hcr_base="${DEFAULT_BRANCH:-origin/main}"
  # Not the inherited-red case (up-to-date / gates not green / probe fail) → real failure, needs-you.
  if ! ci_repair_eligible "${_hcr_wt:-/}" "$_hcr_base" "$_hcr_sha"; then
    return 1
  fi

  _hcr_sl="$(_slug_cell "$_hcr_slug")"
  _hcr_pn=" ${C_DIM}#${_hcr_pr}${C_RESET} ·"

  # LIMIT PREFLIGHT: never type into a usage-limit arrow-menu. Once-guard not burned.
  if [ -n "$_hcr_wt" ]; then
    local _hcr_lreset
    if _hcr_lreset="$(_detect_limit_hit "$_hcr_slug" "$_hcr_wt")"; then
      journal_append ci_repair pr "$_hcr_pr" sha "$_hcr_sha" slug "$_hcr_slug" \
        result deferred reason limit reset_at "${_hcr_lreset:-0}"
      _handle_limit_blocked "$_hcr_slug" "$_hcr_wt" "$_hcr_idx" "${_hcr_lreset:-0}"
      return 0
    fi
  fi

  _hcr_rounds="$(refix_rail_count "$_hcr_pr" ci)"
  # Once-guard: already healed this sha → wait for the push / resolver finish.
  if refix_attempted "$_hcr_pr" "$_hcr_sha" ci; then
    local _hcr_note
    if _hcr_note="$(_active_fix_note "$_hcr_pr" "$_hcr_sha" "$_hcr_slug" ci)"; then
      DISPLAY[_hcr_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_YELLOW}${_hcr_note/fix in progress/ci-repair rebasing}${C_RESET}"
    elif _resolver_agent_alive "$_hcr_slug" 2>/dev/null; then
      DISPLAY[_hcr_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_YELLOW}ci-repair · resolver working${C_RESET}"
    else
      DISPLAY[_hcr_idx]="$(_refix_stalled_row "$_hcr_pr" "$_hcr_sha" "$_hcr_slug" ci "$_hcr_sl" "$_hcr_pn")"
    fi
    return 0
  fi

  # SELF-RESTART QUIESCE (HERD-251): drain toward re-exec — do not burn the once-guard.
  if _self_restart_hold_dispatch; then
    DISPLAY[_hcr_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_YELLOW}ci-repair · held (watcher restarting on new engine code)${C_RESET}"
    return 0
  fi

  # SUITE WRITE INTERLOCK: a live health suite owns this worktree — defer without burning the guard.
  _defer_for_suite "$_hcr_pr" "$_hcr_slug" "$_hcr_sha" "$_hcr_idx" ci "ci-repair" && return 0

  # WORKING-AGENT GUARD: never spawn a resolver into a live builder's worktree.
  if [ "$(_agent_status "$_hcr_slug")" = "working" ]; then
    DISPLAY[_hcr_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_YELLOW}ci-repair · builder busy — heal deferred until it finishes${C_RESET}"
    return 0
  fi

  # Budget exhausted → needs-you (still handled here so the row names the CI rail).
  if _hcr_capmsg="$(_refix_budget_reason "$_hcr_pr" ci)"; then
    DISPLAY[_hcr_idx]="    ${C_RED}🛑${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_RED}needs you · ${_hcr_capmsg} · CI still red · ${_hcr_ci}${C_RESET}"
    if ! _refix_dead_seen "$_hcr_pr" "ci-cap-$_hcr_sha"; then
      _record_refix_dead "$_hcr_pr" "ci-cap-$_hcr_sha"
      journal_append ci_repair pr "$_hcr_pr" sha "$_hcr_sha" slug "$_hcr_slug" \
        result escalated rounds "$_hcr_rounds" reason "${_hcr_capmsg} — CI still red after base-refresh attempts"
      herd_driver_notify "⚠️ CI repair budget spent: ${_hcr_slug}" \
        "PR #${_hcr_pr} CI still red after ${_hcr_rounds} base-refresh rounds — needs you" default
    fi
    return 0
  fi

  _hcr_round_num="$((_hcr_rounds + 1))"

  # NO LIVE BUILDER → conflict resolver (same mechanical merge-base tool as stale-base heal).
  if ! _stale_has_live_builder "$_hcr_slug"; then
    if [ -z "$_hcr_wt" ] || [ ! -d "$_hcr_wt" ]; then
      DISPLAY[_hcr_idx]="    ${C_RED}🛑${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_RED}needs you · CI red (inherited?) + no builder/worktree — merge \`${_hcr_base}\` by hand · ${_hcr_ci}${C_RESET}"
      if ! _refix_dead_seen "$_hcr_pr" "ci-nowt-$_hcr_sha"; then
        _record_refix_dead "$_hcr_pr" "ci-nowt-$_hcr_sha"
        journal_append ci_repair pr "$_hcr_pr" sha "$_hcr_sha" slug "$_hcr_slug" \
          result escalated reason "no live builder and no worktree — cannot auto-heal"
        herd_driver_notify "🛑 CI red, no healer: ${_hcr_slug}" \
          "PR #${_hcr_pr} has inherited-looking CI red but no builder/worktree — merge base by hand" default
      fi
      return 0
    fi
    if [ "$(_agent_status "$_hcr_slug")" = "working" ]; then
      DISPLAY[_hcr_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_YELLOW}ci-repair · builder busy — heal deferred until it finishes${C_RESET}"
      return 0
    fi
    record_refix "$_hcr_pr" "$_hcr_sha" "$_hcr_slug" ci
    DISPLAY[_hcr_idx]="    ${C_CYAN}🔁${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_CYAN}ci-repair · resolver (round ${_hcr_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
    render
    journal_append ci_repair pr "$_hcr_pr" sha "$_hcr_sha" slug "$_hcr_slug" \
      result resolver round "$_hcr_round_num" reason "no live builder — dispatching conflict resolver to merge ${_hcr_base}" \
      ci "${_hcr_ci}" detail "${_CI_REPAIR_REASON:-}"
    _resolver_in_flight "$_hcr_slug" "$_hcr_pr" "$_hcr_sha" || spawn_resolver "$_hcr_slug" "$_hcr_pr" "${_hcr_branch:-$_hcr_slug}" "$_hcr_sha"
    DISPLAY[_hcr_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_YELLOW}ci-repair · awaiting push (round ${_hcr_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
    return 0
  fi

  # LIVE BUILDER → bounce with a mechanical merge-base re-task (inherited-red framing).
  DISPLAY[_hcr_idx]="    ${C_CYAN}🔁${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_CYAN}ci-repair (round ${_hcr_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
  render
  record_refix "$_hcr_pr" "$_hcr_sha" "$_hcr_slug" ci
  local _hcr_before; _hcr_before="$(_agent_status "$_hcr_slug")"
  journal_append ci_repair pr "$_hcr_pr" sha "$_hcr_sha" slug "$_hcr_slug" \
    result bounce round "$_hcr_round_num" agent_status_before "${_hcr_before:-unknown}" \
    ci "${_hcr_ci}" detail "${_CI_REPAIR_REASON:-}"

  local _hcr_pane_id _hcr_woke=0 _hcr_escalated=false _hcr_prompt
  _hcr_prompt="PR #${_hcr_pr} is red on GitHub CI (${_hcr_ci:-required check failed}) but herd/gates PASSED and this branch is BEHIND ${_hcr_base}.
This is almost certainly an INHERITED red — main already carries fixes for hermetic/suite failures that this branch still has because it predates those merges. Do NOT silently treat it as a defect in YOUR code first; refresh the base.
MECHANICAL fix (not a judgment call). From your worktree:
  git fetch ${HERD_REMOTE:-origin}
  git merge ${_hcr_base}
Resolve any conflicts PRESERVING both sides' intent, run the healthcheck, then push (normal push, NEVER force, NEVER push to the default branch).
If CI is still red AFTER the base-refresh lands, that is a REAL new-code failure — fix the failing check, do not keep re-merging main.
Why: ${_CI_REPAIR_REASON:-CI red + gates green + behind base}"
  _hcr_pane_id="$(_find_builder_pane_id_any "$_hcr_slug")"
  if [ -n "$_hcr_pane_id" ]; then
    local _hcr_wait="${HERD_REFIX_WAIT_TIMEOUT:-15}"
    herdr pane run "$_hcr_pane_id" "$_hcr_prompt" >/dev/null 2>&1 || true
    if _wait_agent_working "$_hcr_slug" "$_hcr_wait"; then
      _hcr_woke=1
    else
      herdr pane run "$_hcr_pane_id" "$_hcr_prompt" >/dev/null 2>&1 || true
      if _wait_agent_working "$_hcr_slug" "$_hcr_wait"; then
        _hcr_woke=1
      else
        _escalate_refix_stuck "$_hcr_pr" "$_hcr_sha" "$_hcr_slug" ci "the builder never woke (prompt delivered twice)"
        DISPLAY[_hcr_idx]="$(_refix_stalled_row "$_hcr_pr" "$_hcr_sha" "$_hcr_slug" ci "$_hcr_sl" "$_hcr_pn")"
        _hcr_escalated=true
      fi
    fi
  else
    if [ -n "$_hcr_wt" ] && [ -d "$_hcr_wt" ]; then
      if [ "$(_agent_status "$_hcr_slug")" = "working" ]; then
        DISPLAY[_hcr_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_YELLOW}ci-repair · builder busy — heal deferred until it finishes${C_RESET}"
        return 0
      fi
      journal_append ci_repair pr "$_hcr_pr" sha "$_hcr_sha" slug "$_hcr_slug" \
        result resolver round "$_hcr_round_num" reason "pane vanished mid-bounce — dispatching conflict resolver"
      _resolver_in_flight "$_hcr_slug" "$_hcr_pr" "$_hcr_sha" || spawn_resolver "$_hcr_slug" "$_hcr_pr" "${_hcr_branch:-$_hcr_slug}" "$_hcr_sha"
      DISPLAY[_hcr_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_YELLOW}ci-repair · awaiting push (round ${_hcr_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
    else
      _escalate_refix_stuck "$_hcr_pr" "$_hcr_sha" "$_hcr_slug" ci "agent pane not found"
      DISPLAY[_hcr_idx]="$(_refix_stalled_row "$_hcr_pr" "$_hcr_sha" "$_hcr_slug" ci "$_hcr_sl" "$_hcr_pn")"
      _hcr_escalated=true
    fi
  fi
  if [ "$_hcr_woke" = "1" ] && [ "$_hcr_escalated" = "false" ]; then
    DISPLAY[_hcr_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hcr_sl}${C_RESET}${_hcr_pn} ${C_YELLOW}ci-repair · awaiting push (round ${_hcr_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
  fi
  local _hcr_after; _hcr_after="$(_agent_status "$_hcr_slug")"
  journal_append ci_repair pr "$_hcr_pr" sha "$_hcr_sha" slug "$_hcr_slug" \
    result wake_result round "$_hcr_round_num" agent_status_before "${_hcr_before:-unknown}" \
    agent_status_after "${_hcr_after:-unknown}" woke "$_hcr_woke" escalated "$_hcr_escalated"
  return 0
}

# ── Auto-refix (healthcheck): bounce a reproduced CODE ERROR straight to the builder ───────────────
# HEALTHCHECK_AUTOFIX=true|false (default false). The review gate already bounces a BLOCK verdict to the
# builder (_handle_block_verdict); a reproduced healthcheck CODE ERROR is the same shape of finding —
# a machine-checkable defect in the builder's own diff, with an exact failing test — yet it used to sit
# red waiting for a human to re-task by hand. When enabled, the watcher delivers the failing test + the
# tailable log path to the builder's agent pane on exactly the same rails as the review bounce:
#   • sha-keyed once-guard, kind=health, so one CODE ERROR bounces once per commit (a new push re-runs
#     the suite and is eligible for a fresh bounce);
#   • the HEALTH rail's OWN round budget (REFIX_MAX_ROUNDS), zeroed whenever the suite next goes CLEAN
#     and bounded by the per-PR total ceiling — a red suite never eats the rounds a later review BLOCK
#     will need (HERD-229);
#   • the SAME preflights: a LIMIT-PARKED builder routes to the park/resume handler instead of having
#     the prompt typed into its limit menu, and a DEAD/MISSING agent escalates loudly WITHOUT burning a
#     round on a wake that can only hit nobody;
#   • on cap, escalate to a "needs you" row carrying the blocker AND the remedy.
# OFF (the default) nothing is ever bounced: no re-task prompt, no ledger write, no round consumed, and
# the gate decision is untouched (a CODE ERROR still holds the PR red). The row-truth check still runs —
# that half of HERD-173 is unconditional — but it yields "needs you" whenever nobody is working the red,
# which is every case in an off-mode fleet where no builder was hand-re-tasked.
#
# A tab-leak-guard CODE ERROR is INFRA, not a code bug (issue #78 part 2) — it never bounces a builder;
# the caller keeps the transient red row and the next tick re-dispatches fresh.

# _health_autofix_enabled — true iff HEALTHCHECK_AUTOFIX opts in. Any unrecognized value reads as off.
_health_autofix_enabled() {
  case "$(printf '%s' "${HEALTHCHECK_AUTOFIX:-false}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _stale_has_live_builder <slug> — true when a builder agent for <slug> can receive a re-task prompt:
# liveness is not positively dead/missing AND a non-working agent pane exists. Foreign/reaped PRs
# and dead sessions fail this and fall through to the resolver-dispatch path.
_stale_has_live_builder() {
  local _shb_slug="$1" _shb_live _shb_pane
  _shb_live="$(_agent_liveness "$_shb_slug" 2>/dev/null || printf 'unknown')"
  case "$_shb_live" in
    dead|missing) return 1 ;;
  esac
  _shb_pane="$(_find_builder_pane_id_any "$_shb_slug")"
  [ -n "$_shb_pane" ]
}

# _stale_needs_you_row <slug-cell> <pr-cell> <kind> <reason> — the classic human-hold row (off-mode
# and DUPLICATE flavor and bounce-exhaustion).
_stale_needs_you_row() {
  local _snr_sl="$1" _snr_pn="$2" _snr_kind="$3" _snr_reason="$4"
  printf '%s' "    ${C_RED}🛑${C_RESET} ${C_BOLD}${_snr_sl}${C_RESET}${_snr_pn} ${C_RED}needs you · stale/duplicate (${_snr_kind}) — held · ${_snr_reason}${C_RESET}"
}

# _handle_stale_dup <pr#> <slug> <headSha> <display-idx> <worktree-dir> <branch> <kind> <reason>
# Called every tick the stale-dup gate HOLDS. Always sets DISPLAY[<idx>]; never merges. Side effects
# (PR comment / notify / journal of the hold) are once-per-sha via the caller's stale_dup_held_noted
# guard; this helper owns the autofix bounce / resolver dispatch / row truth.
_handle_stale_dup() {
  local _hsd_pr="$1" _hsd_slug="$2" _hsd_sha="$3" _hsd_idx="$4" _hsd_wt="${5:-}" \
        _hsd_branch="${6:-}" _hsd_kind="${7:-}" _hsd_reason="${8:-}"
  local _hsd_sl _hsd_pn _hsd_rounds _hsd_round_num _hsd_base _hsd_capmsg
  _hsd_sl="$(_slug_cell "$_hsd_slug")"
  _hsd_pn=" ${C_DIM}#${_hsd_pr}${C_RESET} ·"
  _hsd_base="${DEFAULT_BRANCH:-origin/main}"

  # DUPLICATE is a judgment call — always human. Never autofix, never consume a refix round.
  if [ "$_hsd_kind" != "stale-base" ]; then
    DISPLAY[_hsd_idx]="$(_stale_needs_you_row "$_hsd_sl" "$_hsd_pn" "$_hsd_kind" "$_hsd_reason")"
    return 0
  fi

  # OFF / dry-run: no bounce, no ledger, no resolver — the rebase is somebody's to do by hand.
  #
  # ROW TRUTH (HERD-259): "somebody" is often the builder itself, and this row lied about it. Every
  # sibling stale-base row consults agent activity before shouting for a human (_active_fix_note's
  # clause (b), the working-agent guards on the heal paths) — but the OFF path, which is the SHIP
  # DEFAULT and therefore the row most operators actually see, escalated unconditionally. An operator
  # who context-switches into a rebase a live builder is already running is exactly the expensive lie
  # HERD-173 set out to remove. Mirror the same POSITIVE-signal-only check: an agent reading `working`
  # renders fix-in-progress; a blind/absent `herdr agent list` yields no positive signal and falls
  # through to the honest needs-you. Same one-way strength as clause (b) — a needs-you row is
  # trustworthy, a fix-in-progress row can be a busy agent doing something else, and the next idle tick
  # corrects it. DUPLICATE never reaches here (it returned above): it is a judgment call, always human.
  # Nothing but the rendered string changes — no dispatch, no ledger write, no refix round, on either
  # branch — so an idle builder's row stays byte-identical to before.
  if ! _stale_base_autofix_enabled || [ -n "${DRYRUN:-}" ]; then
    if [ "$(_agent_status "$_hsd_slug")" = "working" ]; then
      DISPLAY[_hsd_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_YELLOW}fix in progress · builder working · stale base held${C_RESET}"
    else
      DISPLAY[_hsd_idx]="$(_stale_needs_you_row "$_hsd_sl" "$_hsd_pn" "$_hsd_kind" "$_hsd_reason")"
    fi
    return 0
  fi

  # LIMIT PREFLIGHT (shared with review/health): never type into a usage-limit arrow-menu. Route to
  # the park/resume handler; once-guard is NOT burned so the heal fires once the builder is back.
  if [ -n "$_hsd_wt" ]; then
    local _hsd_lreset
    if _hsd_lreset="$(_detect_limit_hit "$_hsd_slug" "$_hsd_wt")"; then
      journal_append stale_refix_deferred_limit pr "$_hsd_pr" sha "$_hsd_sha" slug "$_hsd_slug" \
        reset_at "${_hsd_lreset:-0}"
      _handle_limit_blocked "$_hsd_slug" "$_hsd_wt" "$_hsd_idx" "${_hsd_lreset:-0}"
      return 0
    fi
  fi

  _hsd_rounds="$(refix_rail_count "$_hsd_pr" stale)"
  # Once-guard: already healed this sha → wait for the push / resolver finish. Honest in-progress row.
  if refix_attempted "$_hsd_pr" "$_hsd_sha" stale; then
    local _hsd_note
    if _hsd_note="$(_active_fix_note "$_hsd_pr" "$_hsd_sha" "$_hsd_slug" stale)"; then
      # Someone is genuinely ON this rebase (record + no stuck marker + liveness not positively
      # dead/missing — the sibling paths' triple disproof, review round-6). Honest in-progress row.
      DISPLAY[_hsd_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_YELLOW}${_hsd_note/fix in progress/rebasing}${C_RESET}"
    elif _resolver_agent_alive "$_hsd_slug" 2>/dev/null; then
      # No live BUILDER on it, but the dispatched conflict RESOLVER is alive and working (review
      # round-6: the resolver path needs its own liveness consult, not the builder probe).
      DISPLAY[_hsd_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_YELLOW}rebasing · resolver working${C_RESET}"
    else
      # Bounced but NOBODY is on it (wake failed, agent died after a good wake, or the resolver
      # died/escalated). Durable needs-you via the shared stalled row.
      DISPLAY[_hsd_idx]="$(_refix_stalled_row "$_hsd_pr" "$_hsd_sha" "$_hsd_slug" stale "$_hsd_sl" "$_hsd_pn")"
    fi
    return 0
  fi

  # SELF-RESTART QUIESCE (HERD-251): the watcher is draining toward an in-place re-exec on new engine
  # code — dispatch no heal. Placed HERE, among its sibling deferrals and ABOVE every `record_refix`,
  # for the reason they all state: the once-guard is NOT burned and no refix round is spent, so the
  # restarted watcher heals this sha on new code. Refusing further down (inside spawn_resolver) would
  # refuse AFTER the caller had burned refix_attempted(pr,sha,stale) and journaled stale_refix_resolver
  # — a dropped dispatch behind a spent guard, which no later tick could ever retry, leaving a durable
  # needs-you row for a heal the watcher itself declined. This covers BOTH heals below (the resolver
  # dispatch and the live-builder bounce), which is why it sits above the fork. The read-only once-guard
  # branch above still runs first, so a heal already in flight keeps its honest in-progress row.
  if _self_restart_hold_dispatch; then
    DISPLAY[_hsd_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_YELLOW}stale base · held (watcher restarting on new engine code)${C_RESET}"
    return 0
  fi

  # SUITE WRITE INTERLOCK (HERD-227): a live healthcheck suite is running INSIDE this worktree. Both
  # heals below mutate it — the bounce types `git merge` into the builder's pane, the resolver fallback
  # merges in the tree directly. Either one under a running suite gives two writers one worktree, and
  # since the head sha cannot move until the builder pushes, the suite's verdict gets sha-cached against
  # a tree that sha never had. Defer: honest row, once-guard NOT burned, no refix round spent; the heal
  # fires on the first tick after the suite collects. Guards BOTH mutation paths at once (they are the
  # only code below this point) — see _defer_for_suite.
  _defer_for_suite "$_hsd_pr" "$_hsd_slug" "$_hsd_sha" "$_hsd_idx" stale "stale base" && return 0

  # WORKING-AGENT GUARD (review round-7): an actively-working builder is invisible to the pane lookup
  # BY DESIGN (never double-drive a live session) — without this check it reads as "no builder" and a
  # resolver gets spawned INTO the live worktree (two agents, one directory, merge over WIP). If the
  # agent is working, defer: honest row, once-guard NOT burned, heal retries when it goes idle.
  if [ "$(_agent_status "$_hsd_slug")" = "working" ]; then
    DISPLAY[_hsd_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_YELLOW}stale base · builder busy — heal deferred until it finishes${C_RESET}"
    return 0
  fi

  # Budget exhausted → needs-you: this rail's own rounds, or the PR's total ceiling across rails. Only
  # exhaustion escalates (not a missing builder — that routes to the resolver below).
  if _hsd_capmsg="$(_refix_budget_reason "$_hsd_pr" stale)"; then
    DISPLAY[_hsd_idx]="    ${C_RED}🛑${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_RED}needs you · ${_hsd_capmsg} · stale base still held · ${_hsd_reason}${C_RESET}"
    if ! _refix_dead_seen "$_hsd_pr" "stale-cap-$_hsd_sha"; then
      _record_refix_dead "$_hsd_pr" "stale-cap-$_hsd_sha"
      # HERD-261: report TOTAL rounds when the total ceiling closed the PR. The rail counter can
      # honestly read 0 after reset-on-progress while the PR burned N across rails — a needs-you
      # must never mislead with "after 0 refix rounds".
      local _hsd_report_rounds="$_hsd_rounds"
      case "$_hsd_capmsg" in
        *'total rounds across rails'*) _hsd_report_rounds="$(refix_total_count "$_hsd_pr")" ;;
      esac
      journal_append stale_refix_escalated pr "$_hsd_pr" sha "$_hsd_sha" slug "$_hsd_slug" \
        rounds "$_hsd_report_rounds" reason "${_hsd_capmsg} — stale base still held"
      herd_driver_notify "⚠️ refix budget spent: ${_hsd_slug}" \
        "PR #${_hsd_pr} stale base still held after ${_hsd_report_rounds} refix rounds — needs you" default
    fi
    return 0
  fi

  _hsd_round_num="$((_hsd_rounds + 1))"

  # NO LIVE BUILDER (foreign / reaped / dead / missing pane) → conflict resolver. The resolver's
  # standard task already merges $DEFAULT_BRANCH and heals mechanical conflicts — the right tool when
  # there is nobody to re-task. Requires an existing worktree; without one, escalate (nothing to heal).
  if ! _stale_has_live_builder "$_hsd_slug"; then
    if [ -z "$_hsd_wt" ] || [ ! -d "$_hsd_wt" ]; then
      DISPLAY[_hsd_idx]="    ${C_RED}🛑${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_RED}needs you · stale base + no builder/worktree — rebase \`${_hsd_base}\` by hand · ${_hsd_reason}${C_RESET}"
      if ! _refix_dead_seen "$_hsd_pr" "stale-nowt-$_hsd_sha"; then
        _record_refix_dead "$_hsd_pr" "stale-nowt-$_hsd_sha"
        journal_append stale_refix_escalated pr "$_hsd_pr" sha "$_hsd_sha" slug "$_hsd_slug" \
          reason "no live builder and no worktree — cannot auto-heal"
        herd_driver_notify "🛑 stale base, no healer: ${_hsd_slug}" \
          "PR #${_hsd_pr} is base-stale but has no builder/worktree — rebase by hand" default
      fi
      return 0
    fi
    # TOCTOU RE-ASSERT (round-9, both dispatch sites): a builder that flipped idle→working since the
    # top guard is EXCLUDED from the pane lookup by design and so reads as "no live builder" here.
    # A working builder must never reach spawn_resolver — defer without burning the once-guard.
    if [ "$(_agent_status "$_hsd_slug")" = "working" ]; then
      DISPLAY[_hsd_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_YELLOW}stale base · builder busy — heal deferred until it finishes${C_RESET}"
      return 0
    fi
    # Record-first once-guard so a later tick never double-dispatches.
    record_refix "$_hsd_pr" "$_hsd_sha" "$_hsd_slug" stale
    DISPLAY[_hsd_idx]="    ${C_CYAN}🔁${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_CYAN}rebasing · resolver (round ${_hsd_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
    render
    journal_append stale_refix_resolver pr "$_hsd_pr" sha "$_hsd_sha" slug "$_hsd_slug" \
      round "$_hsd_round_num" reason "no live builder — dispatching conflict resolver to merge ${_hsd_base}"
    _resolver_in_flight "$_hsd_slug" "$_hsd_pr" "$_hsd_sha" || spawn_resolver "$_hsd_slug" "$_hsd_pr" "${_hsd_branch:-$_hsd_slug}" "$_hsd_sha"
    DISPLAY[_hsd_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_YELLOW}rebasing · awaiting push (round ${_hsd_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
    return 0
  fi

  # LIVE BUILDER → bounce with a mechanical merge-base re-task.
  DISPLAY[_hsd_idx]="    ${C_CYAN}🔁${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_CYAN}rebasing (round ${_hsd_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
  render
  record_refix "$_hsd_pr" "$_hsd_sha" "$_hsd_slug" stale
  local _hsd_before; _hsd_before="$(_agent_status "$_hsd_slug")"
  journal_append stale_refix_bounce pr "$_hsd_pr" sha "$_hsd_sha" slug "$_hsd_slug" \
    round "$_hsd_round_num" agent_status_before "${_hsd_before:-unknown}" reason "$_hsd_reason"

  local _hsd_pane_id _hsd_woke=0 _hsd_escalated=false _hsd_prompt
  _hsd_prompt="PR #${_hsd_pr} is held: STALE BASE — files this branch touches were changed on ${_hsd_base} after the branch's merge-base, so a clean merge would silently clobber newer work.
This is a MECHANICAL fix (not a judgment call). From your worktree:
  git fetch ${HERD_REMOTE:-origin}
  git merge ${_hsd_base}
Resolve any conflicts PRESERVING both sides' intent, run the healthcheck, then push (normal push, NEVER force, NEVER push to the default branch).
Why: ${_hsd_reason}"
  _hsd_pane_id="$(_find_builder_pane_id_any "$_hsd_slug")"
  if [ -n "$_hsd_pane_id" ]; then
    local _hsd_wait="${HERD_REFIX_WAIT_TIMEOUT:-15}"
    # Submit via the driver send-text seam (DRIVER_SEND_TEXT: pane run + Enter for herdr) — same
    # wake path as the review refix (HERD-176 / HERD-186); never a raw herdr pane run alone.
    herd_driver_send_text "$_hsd_pane_id" "$_hsd_prompt"
    if _wait_agent_working "$_hsd_slug" "$_hsd_wait"; then
      _hsd_woke=1
    else
      herd_driver_send_text "$_hsd_pane_id" "$_hsd_prompt"
      if _wait_agent_working "$_hsd_slug" "$_hsd_wait"; then
        _hsd_woke=1
      else
        _escalate_refix_stuck "$_hsd_pr" "$_hsd_sha" "$_hsd_slug" stale "the builder never woke (prompt delivered twice)"
      DISPLAY[_hsd_idx]="$(_refix_stalled_row "$_hsd_pr" "$_hsd_sha" "$_hsd_slug" stale "$_hsd_sl" "$_hsd_pn")"
        _hsd_escalated=true
      fi
    fi
  else
    # Race: liveness said live but pane vanished between the preflight and the send. Fall through to
    # the resolver if the worktree is still there; otherwise escalate.
    if [ -n "$_hsd_wt" ] && [ -d "$_hsd_wt" ]; then
      # TOCTOU RE-ASSERT (round-9): an empty pane id has TWO causes — vanished, or the builder flipped
      # idle→working since the guard (a working agent is excluded from the lookup BY DESIGN). A working
      # builder must never reach spawn_resolver: defer instead, once-guard already burned is acceptable
      # (the next sha or idle tick heals).
      if [ "$(_agent_status "$_hsd_slug")" = "working" ]; then
        DISPLAY[_hsd_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_YELLOW}stale base · builder busy — heal deferred until it finishes${C_RESET}"
        return 0
      fi
      journal_append stale_refix_resolver pr "$_hsd_pr" sha "$_hsd_sha" slug "$_hsd_slug" \
        round "$_hsd_round_num" reason "pane vanished mid-bounce — dispatching conflict resolver"
      _resolver_in_flight "$_hsd_slug" "$_hsd_pr" "$_hsd_sha" || spawn_resolver "$_hsd_slug" "$_hsd_pr" "${_hsd_branch:-$_hsd_slug}" "$_hsd_sha"
      DISPLAY[_hsd_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_YELLOW}rebasing · awaiting push (round ${_hsd_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
    else
      _escalate_refix_stuck "$_hsd_pr" "$_hsd_sha" "$_hsd_slug" stale "agent pane not found"
      DISPLAY[_hsd_idx]="$(_refix_stalled_row "$_hsd_pr" "$_hsd_sha" "$_hsd_slug" stale "$_hsd_sl" "$_hsd_pn")"
      _hsd_escalated=true
    fi
  fi
  if [ "$_hsd_woke" = "1" ] && [ "$_hsd_escalated" = "false" ]; then
    DISPLAY[_hsd_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hsd_sl}${C_RESET}${_hsd_pn} ${C_YELLOW}rebasing · awaiting push (round ${_hsd_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
  fi
  local _hsd_after; _hsd_after="$(_agent_status "$_hsd_slug")"
  journal_append stale_refix_wake_result pr "$_hsd_pr" sha "$_hsd_sha" slug "$_hsd_slug" \
    round "$_hsd_round_num" agent_status_before "${_hsd_before:-unknown}" \
    agent_status_after "${_hsd_after:-unknown}" woke "$_hsd_woke" escalated "$_hsd_escalated"
}

# _stale_dup_gate_step <pr#> <slug> <worktree-dir> <headSha> <branch> <display-idx>
# The whole PRE-MERGE STALE / DUPLICATE gate (HERD-188 + HERD-199) as ONE callable step: evaluate,
# and on a proven hold fire the once-per-sha comment/notify/journal, run the autofix/needs-you row,
# and re-render. Returns 0 → PROCEED, 1 → HOLD (caller `continue`s; it must dispatch NOTHING).
#
# WHY IT IS A FUNCTION (HERD-227 — gate ORDER). This gate used to sit inline at the very END of the
# action pass: after the parallel review pre-dispatch and after the heavy healthcheck had to run to
# completion. Both are expensive (an Opus review; a ~9-min suite) and both are DOOMED the instant the
# gate holds, because a stale-base hold bounces the builder and supersedes the sha. Journal proof, PR
# #328 on 2026-07-09: healthcheck_started 14:23:57 → CLEAN 14:26:22 → stale_dup_hold 14:26:24 →
# bounce → the in-flight review BLOCKed at 14:29:57 on a sha nothing would ever merge. The decision
# is deterministic (a duplicate ref, or a pure-git merge-base file overlap), so it belongs FIRST.
# Extracting it here lets the action pass call it before any dispatch, and again (only) if the
# pre-merge re-verify turns up a newer head sha.
#
# This is an ORDERING change only: the gate, its holds, its autofix and its sha-keying are unchanged.
# It does NOT cancel work already in flight for a superseded sha (that is HERD-235's structural scope).
#
# FAIL-SOFT, twice over: stale_dup_check itself never holds without proof, and a nonzero return that
# somehow carries no _STALE_DUP_KIND is treated as an evaluation error → PROCEED (today's order).
# DRY-RUN is a strict no-op here — the pre-HERD-227 pass `continue`d before ever reaching the gate,
# so evaluating it under dry-run would newly post PR comments. An EMPTY sha also PROCEEDs (nothing to
# prove against), mirroring the old inline `[ -n "$rsha" ]` predicate; the pre-merge caller keeps that
# same guard, so an empty head sha still lands on the `awaiting head sha for review…` row below.
#
# CALLED TWICE per candidate, on purpose. The top-of-pass call is a CHEAPENING pass: it skips the
# review + suite for an already-doomed sha. The pre-merge call is the SAFETY RAIL: a stale-base
# clearance is keyed on (head sha, base tip), and another seat's merge can advance the base tip while
# our suite runs — so the merge decision must be re-established from current state, unconditionally.
_stale_dup_gate_step() {
  local _sdg_pr="$1" _sdg_slug="$2" _sdg_dir="$3" _sdg_sha="$4" _sdg_branch="$5" _sdg_idx="$6"
  [ -n "$_sdg_sha" ] || return 0
  [ -z "${DRYRUN:-}" ] || return 0
  if stale_dup_check "$_sdg_pr" "$_sdg_slug" "$_sdg_dir" "$_sdg_sha" "$DEFAULT_BRANCH"; then
    # RESET-ON-PROGRESS (HERD-229): the base is fresh again — the stale rail's red resolved (the heal
    # landed, or another seat's merge stopped conflicting). Refund the stale rail's refix budget.
    refix_rail_reset "$_sdg_pr" stale "$_sdg_sha" "$_sdg_slug"
    return 0
  fi
  [ -n "${_STALE_DUP_KIND:-}" ] || return 0

  # The console row re-renders every tick from this live re-check; the PR comment / notify / journal
  # of the HOLD fire once per sha (stale_dup_held_noted). NEVER auto-merges.
  if ! stale_dup_held_noted "$_sdg_pr" "$_sdg_sha"; then
    record_stale_dup_held "$_sdg_pr" "$_sdg_sha" "$_STALE_DUP_KIND"
    journal_append stale_dup_hold pr "$_sdg_pr" sha "$_sdg_sha" slug "$_sdg_slug" \
      kind "$_STALE_DUP_KIND" reason "$_STALE_DUP_REASON"
    if [ "$_STALE_DUP_KIND" = "stale-base" ] && _stale_base_autofix_enabled; then
      _gh_timeout stale_base_comment pr comment "$_sdg_pr" --body "🔁 **herd watch** · **stale-base auto-heal** — this PR will **NOT** auto-merge until it absorbs \`${DEFAULT_BRANCH}\`.

**Why:** ${_STALE_DUP_REASON}

This is a mechanical base-stale hold (touched files moved on \`${DEFAULT_BRANCH}\`). The watcher is auto-bouncing the builder to \`git merge ${DEFAULT_BRANCH}\` (or dispatching the conflict resolver if no live builder remains). Only bounce-budget exhaustion escalates to a human. (Disable the heal with \`STALE_BASE_AUTOFIX=off\`; disable the gate with \`STALE_DUP_DETECT=off\`.)" >/dev/null 2>&1 || true
      herd_driver_notify "🔁 PR #${_sdg_pr} stale-base — auto-healing" "${_sdg_slug}: ${_STALE_DUP_REASON}" default
    else
      _gh_timeout stale_dup_comment pr comment "$_sdg_pr" --body "🛑 **herd watch** · **stale-duplicate hold** (\`${_STALE_DUP_KIND}\`) — this PR will **NOT** auto-merge.

**Why:** ${_STALE_DUP_REASON}

This PR appears to re-implement already-shipped work, or sits on a base stale enough that merging it would silently clobber newer \`${DEFAULT_BRANCH}\`. A human must resolve it: rebase onto \`${DEFAULT_BRANCH}\` and confirm the change is still needed, or close it as a duplicate. (Disable this gate with \`STALE_DUP_DETECT=off\`.)" >/dev/null 2>&1 || true
      herd_driver_notify "🛑 PR #${_sdg_pr} held — stale/duplicate" "${_sdg_slug}: ${_STALE_DUP_REASON}" default
    fi
  fi
  # RE-STALE LAP (HERD-231). Count this hold as a lost lap IF the sha it holds already carried gate
  # work — a suite that ran, a reviewer in flight, a verdict recorded. Held-before-any-gate is not a
  # lap: nothing was thrown away. Observability only; nothing below reads the count.
  _restale_note "$_sdg_pr" "$_sdg_sha" "$_sdg_slug" "$_STALE_DUP_KIND"
  _handle_stale_dup "$_sdg_pr" "$_sdg_slug" "$_sdg_sha" "$_sdg_idx" "$_sdg_dir" "$_sdg_branch" \
    "$_STALE_DUP_KIND" "$_STALE_DUP_REASON"
  _restale_decorate_row "$_sdg_idx" "$_sdg_pr"
  render
  return 1
}

# _health_needs_you_row <slug-cell> <pr-cell> <pr#> <sha> <detail> — the honest red row for a health
# CODE ERROR that NOBODY is working: the BLOCKER (which test failed) plus the REMEDY (what to do, and
# where to read the whole suite). Two lines, mirroring the review-blocked row's continuation line.
_health_needs_you_row() {
  local _hnr_sl="$1" _hnr_pn="$2" _hnr_pr="$3" _hnr_sha="$4" _hnr_detail="$5" _hnr_log
  _hnr_log="$(_health_log_file "${_hnr_pr}-${_hnr_sha}")"
  printf '%s' "    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hnr_sl}${C_RESET}${_hnr_pn} ${C_RED}needs you · health-check failed · ${_hnr_detail}${C_RESET}"$'\n'"       ${C_DIM}└─ fix in the worktree + push (auto-re-runs) · full suite: ${_hnr_log}${C_RESET}"
}

# _handle_health_codeerror <pr#> <slug> <headSha> <display-idx> <worktree-dir> <detail>
# Called for EVERY reproduced healthcheck CODE ERROR — fresh from the collector or replayed from the
# sha-cache — so the row stays truthful on every tick. Always sets DISPLAY[<idx>]; returns 0.
_handle_health_codeerror() {
  local _hhc_pr="$1" _hhc_slug="$2" _hhc_sha="$3" _hhc_idx="$4" _hhc_wt="${5:-}" _hhc_detail="${6:-}"
  local _hhc_sl _hhc_pn _hhc_note _hhc_rounds _hhc_live _hhc_capmsg
  _hhc_sl="$(_slug_cell "$_hhc_slug")"
  _hhc_pn=" ${C_DIM}#${_hhc_pr}${C_RESET} ·"

  # An infra red that outlived its re-dispatch budget (HERD-228) stopped being transient: it is a human's
  # problem, not a builder's. Loud needs-you row, still no bounce — a builder cannot fix the control room.
  case "$_hhc_detail" in
    "$_HEALTH_INFRA_CAP_TAG"*)
      DISPLAY[_hhc_idx]="    ${C_RED}🛑${C_RESET} ${C_BOLD}${_hhc_sl}${C_RESET}${_hhc_pn} ${C_RED}needs you · infra red did not self-heal · ${_hhc_detail}${C_RESET}"
      return 0 ;;
  esac

  # A tab-leak-guard trip is a transient infra red (never sha-cached, never a builder's fault): keep the
  # legacy row verbatim and never bounce. Checked before ANY agent probe so the off-path stays cheap.
  if _health_is_leak_guard_detail "$_hhc_detail"; then
    DISPLAY[_hhc_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hhc_sl}${C_RESET}${_hhc_pn} ${C_RED}needs you · ${_hhc_detail}${C_RESET}"
    return 0
  fi

  if ! _health_autofix_enabled || [ -n "${DRYRUN:-}" ]; then
    # OFF / dry-run: no bounce, no ledger write. Row truth still applies — a builder a HUMAN re-tasked
    # against this same red must not be reported as "needs you" (the (b) case of _active_fix_note; the
    # (a) case cannot exist here because nothing ever recorded a health bounce).
    if _hhc_note="$(_active_fix_note "$_hhc_pr" "$_hhc_sha" "$_hhc_slug" health)"; then
      DISPLAY[_hhc_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hhc_sl}${C_RESET}${_hhc_pn} ${C_YELLOW}health-check failed · ${_hhc_note}${C_RESET}"
    else
      DISPLAY[_hhc_idx]="$(_health_needs_you_row "$_hhc_sl" "$_hhc_pn" "$_hhc_pr" "$_hhc_sha" "$_hhc_detail")"
    fi
    return 0
  fi

  # LIMIT PREFLIGHT (HERD-155 F5, shared with the review bounce): never type a re-task prompt into a
  # builder parked at the usage-limit arrow-menu. Route to the park/resume handler; the once-guard is
  # NOT burned, so the bounce fires normally once the builder is back.
  if [ -n "$_hhc_wt" ]; then
    local _hhc_lreset
    if _hhc_lreset="$(_detect_limit_hit "$_hhc_slug" "$_hhc_wt")"; then
      journal_append health_refix_deferred_limit pr "$_hhc_pr" sha "$_hhc_sha" slug "$_hhc_slug" reset_at "${_hhc_lreset:-0}"
      _handle_limit_blocked "$_hhc_slug" "$_hhc_wt" "$_hhc_idx" "${_hhc_lreset:-0}"
      return 0
    fi
  fi

  _hhc_rounds="$(refix_rail_count "$_hhc_pr" health)"
  if _hhc_note="$(_active_fix_note "$_hhc_pr" "$_hhc_sha" "$_hhc_slug" health)"; then
    # Already bounced for this sha, or an agent is working this red — wait for the push. (Checked BEFORE
    # the cap: a row is never "needs you" while somebody is on it, even at the budget's end.)
    DISPLAY[_hhc_idx]="    ${C_YELLOW}🔁${C_RESET} ${C_BOLD}${_hhc_sl}${C_RESET}${_hhc_pn} ${C_YELLOW}health-check failed · ${_hhc_note}${C_RESET}"
    return 0
  fi
  if refix_attempted "$_hhc_pr" "$_hhc_sha" health; then
    # Bounced, but NOBODY is on it (the wake failed, or the agent died right after). The once-guard
    # blocks a re-bounce and the sha will never change on its own — so this escalation must PERSIST.
    DISPLAY[_hhc_idx]="$(_refix_stalled_row "$_hhc_pr" "$_hhc_sha" "$_hhc_slug" health "$_hhc_sl" "$_hhc_pn")"
    return 0
  fi
  if _hhc_capmsg="$(_refix_budget_reason "$_hhc_pr" health)"; then
    DISPLAY[_hhc_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hhc_sl}${C_RESET}${_hhc_pn} ${C_RED}needs you · ${_hhc_capmsg} · health-check still red: ${_hhc_detail}${C_RESET}"
    if ! _refix_dead_seen "$_hhc_pr" "health-cap-$_hhc_sha"; then
      _record_refix_dead "$_hhc_pr" "health-cap-$_hhc_sha"
      # HERD-261: report TOTAL rounds when the total ceiling closed the PR. The rail counter can
      # honestly read 0 after reset-on-progress while the PR burned N across rails — a needs-you
      # must never mislead with "after 0 refix rounds".
      local _hhc_report_rounds="$_hhc_rounds"
      case "$_hhc_capmsg" in
        *'total rounds across rails'*) _hhc_report_rounds="$(refix_total_count "$_hhc_pr")" ;;
      esac
      journal_append health_refix_escalated pr "$_hhc_pr" sha "$_hhc_sha" slug "$_hhc_slug" \
        rounds "$_hhc_report_rounds" reason "${_hhc_capmsg} — health-check still red"
      herd_driver_notify "⚠️ refix budget spent: ${_hhc_slug}" \
        "PR #${_hhc_pr} health-check still red after ${_hhc_report_rounds} refix rounds — needs you" default
    fi
    return 0
  fi
  # DEAD/MISSING PREFLIGHT (HERD-114/HERD-135): a wake typed at a dead session or a vanished pane can
  # only hit nobody — escalate without burning a round. Only a POSITIVE dead/missing diverts.
  if _hhc_live="$(_agent_liveness "$_hhc_slug")"; [ "$_hhc_live" = "dead" ] || [ "$_hhc_live" = "missing" ]; then
    if [ "$_hhc_live" = "missing" ]; then
      DISPLAY[_hhc_idx]="    ${C_RED}🫥${C_RESET} ${C_BOLD}${_hhc_sl}${C_RESET}${_hhc_pn} ${C_RED}needs you · health-check red + agent missing (no agent pane) — fix + push by hand${C_RESET}"
    else
      DISPLAY[_hhc_idx]="    ${C_RED}💀${C_RESET} ${C_BOLD}${_hhc_sl}${C_RESET}${_hhc_pn} ${C_RED}needs you · health-check red + agent dead (unwakeable) — fix + push by hand${C_RESET}"
    fi
    if ! _refix_dead_seen "$_hhc_pr" "health-$_hhc_sha"; then
      _record_refix_dead "$_hhc_pr" "health-$_hhc_sha"
      journal_append health_refix_escalated pr "$_hhc_pr" sha "$_hhc_sha" slug "$_hhc_slug" \
        reason "agent ${_hhc_live} — wake would fail; escalated for human"
      herd_driver_notify "💀 agent ${_hhc_live}: ${_hhc_slug}" \
        "PR #${_hhc_pr} health-check red but the builder is ${_hhc_live} — fix by hand" default
    fi
    return 0
  fi

  # SUITE WRITE INTERLOCK (HERD-227). This PR's OWN suite has necessarily collected (that is what produced
  # the CODEERROR), but a suite dispatched for an EARLIER sha can still be running in the same worktree,
  # and the corpse sweep only reaps it on timeout. Consult the same shared check every rail uses rather
  # than reason locally about which shas can overlap. Once-guard NOT burned; the bounce fires next tick.
  _defer_for_suite "$_hhc_pr" "$_hhc_slug" "$_hhc_sha" "$_hhc_idx" health "health-check failed" && return 0

  # BOUNCE. Record BEFORE sending so the once-guard holds even if pane lookup or delivery fails.
  local _hhc_round_num; _hhc_round_num="$((_hhc_rounds + 1))"
  DISPLAY[_hhc_idx]="    ${C_CYAN}🔁${C_RESET} ${C_BOLD}${_hhc_sl}${C_RESET}${_hhc_pn} ${C_CYAN}refixing health-check (round ${_hhc_round_num}/${REFIX_MAX_ROUNDS:-3})${C_RESET}"
  render
  record_refix "$_hhc_pr" "$_hhc_sha" "$_hhc_slug" health
  local _hhc_before; _hhc_before="$(_agent_status "$_hhc_slug")"
  journal_append health_refix_bounce pr "$_hhc_pr" sha "$_hhc_sha" slug "$_hhc_slug" \
    round "$_hhc_round_num" agent_status_before "${_hhc_before:-unknown}" detail "$_hhc_detail"

  local _hhc_pane_id _hhc_woke=0 _hhc_escalated=false _hhc_prompt
  # REPRODUCE-FIRST guidance. The command below is EXACTLY what _health_worker ran: the auto profile
  # (never --heavy, which the worker does not pass) with the BASELINE-AWARE env (HERD-190). Getting this
  # wrong is worse than omitting it (review note #5): under a bare `--heavy` an INHERITED base failure
  # that the gate TOLERATES (rc 0) reproduces red, which flatly contradicts the "your sha, your diff"
  # line that follows. The watcher also runs in a pane with a LOGIN PATH and a tty that a bare sandbox
  # shell lacks, so some env-sensitive tests differ either way — reproduce as the gate ran it.
  _hhc_prompt="PR #${_hhc_pr} FAILED the pre-merge healthcheck (this is the gate that merges your PR).
Failing test: ${_hhc_detail}
Full suite output (the gate's own log, already on disk): $(_health_log_file "${_hhc_pr}-${_hhc_sha}")
REPRODUCE FIRST, from your worktree, exactly as the gate ran it (same profile, same baseline env):
  HERD_BASELINE_DIR='${MAIN}' HERD_BASELINE_CACHE='${TREES}' bash ${HERD_HEALTHCHECK_BIN:-scripts/herd/healthcheck.sh} ${_hhc_wt:-.}
A red on YOUR sha is YOUR diff — the baseline env above already forgives failures inherited from the
base branch, so what remains is yours.
Fix the failure, re-run until the healthcheck is green, then push."
  _hhc_pane_id="$(_find_builder_pane_id_any "$_hhc_slug")"
  if [ -n "$_hhc_pane_id" ]; then
    local _hhc_wait="${HERD_REFIX_WAIT_TIMEOUT:-15}"
    # Submit via the driver send-text seam (DRIVER_SEND_TEXT) — same wake path as review/stale refix
    # (HERD-176 / HERD-186); never a raw herdr pane run alone.
    herd_driver_send_text "$_hhc_pane_id" "$_hhc_prompt"
    if _wait_agent_working "$_hhc_slug" "$_hhc_wait"; then
      _hhc_woke=1
    else
      herd_driver_send_text "$_hhc_pane_id" "$_hhc_prompt"
      if _wait_agent_working "$_hhc_slug" "$_hhc_wait"; then
        _hhc_woke=1
      else
        DISPLAY[_hhc_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hhc_sl}${C_RESET}${_hhc_pn} ${C_RED}needs you · health autofix failed · check pane${C_RESET}"
        _hhc_escalated=true
        _escalate_refix_stuck "$_hhc_pr" "$_hhc_sha" "$_hhc_slug" health "the builder never woke (prompt delivered twice)"
      fi
    fi
  else
    DISPLAY[_hhc_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_hhc_sl}${C_RESET}${_hhc_pn} ${C_RED}needs you · health autofix failed · agent pane not found${C_RESET}"
    _hhc_escalated=true
    _escalate_refix_stuck "$_hhc_pr" "$_hhc_sha" "$_hhc_slug" health "no agent pane to deliver the bounce to"
  fi
  local _hhc_after; _hhc_after="$(_agent_status "$_hhc_slug")"
  journal_append health_refix_wake_result pr "$_hhc_pr" sha "$_hhc_sha" slug "$_hhc_slug" \
    round "$_hhc_round_num" agent_status_before "${_hhc_before:-unknown}" \
    agent_status_after "${_hhc_after:-unknown}" woke "$_hhc_woke" escalated "$_hhc_escalated"
  return 0
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

# _find_builder_pane_id_any <slug> — pane_id for the agent identified by <slug> REGARDLESS of
# idle/done/ended status, but NEVER a "working" one (resuming a live session would double-drive it).
# Identity is `name` when set, else `agent` (report-agent-only registrations have no name). The resume
# path targets a builder whose session has ENDED, which the idle-only _find_builder_pane_id deliberately
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
    ident = a.get("name") or a.get("agent") or ""
    if ident == slug and a.get("agent_status") != "working":
      print(a.get("pane_id", ""), end="")
      break
except Exception:
  pass
' 2>/dev/null || true
}

# _resume_builder <slug> <worktree> <pane_id> [prompt] — relaunch a builder whose agent session
# ENDED, IN PLACE, via the driver's DRIVER_AGENT_RESUME binding (herdr-claude: `claude --continue`)
# in its worktree (full context preserved), then VERIFY the agent flips to "working" within a
# bounded poll; retry ONCE. Returns 0 if it woke, 1 otherwise. The CALLER owns journaling, the
# console row, and the loud escalation on failure — this helper only performs + verifies the
# relaunch. [prompt] is the compose-turn text (default "continue"). HERD-176: the resume argv is
# composed by herd_driver_agent_resume_cmd so a non-Claude runtime rebinds in one place; default
# path is BYTE-IDENTICAL to the pre-P4 hardcoded `claude <flags> --continue <prompt>`.
_resume_builder() {
  local _rb_slug="$1" _rb_wt="$2" _rb_pane="$3" _rb_prompt="${4:-continue}"
  [ -n "$_rb_pane" ] || return 1
  # HARDENING (HERD-155 F1): NEVER type `cd … && <resume>` into a pane still parked at the
  # limit ARROW-MENU — the command line would be captured as MENU input (worst case: it lands on
  # "Upgrade your plan" and strands the session at a login screen). The resume backstop is only
  # valid for a session that has actually ENDED (a normal REPL). Fire ONLY when a menu is NOT CONFIRMED
  # present; a confirmed menu means the clean-select degraded, so REFUSE and let the CALLER escalate
  # (record 'failed' + loud row / notification) rather than type blind. Empty/blind read → not a menu
  # → proceed (headless & pane-less environments keep working, backstop unchanged).
  if _pane_menu_confirmed "$_rb_pane"; then
    journal_append limit_resume_refused slug "$_rb_slug" pane "$_rb_pane" reason menu_parked
    return 1
  fi
  # Compose the resume command from the active driver's DRIVER_AGENT_RESUME binding (HERD-176).
  # Permission flags: HERD_CLAUDE_FLAGS override when set, else the driver's own
  # DRIVER_AGENT_PERMISSION_FLAG — byte-identical for herdr-claude (--dangerously-skip-permissions).
  local _rb_flags _rb_resume _rb_cmd
  _rb_flags="$(herd_driver_lane_permission_flags)"
  _rb_resume="$(herd_driver_agent_resume_cmd "$_rb_prompt" "$_rb_flags")"
  # cd into the worktree so the resume targets THAT worktree's session even if the pane's shell
  # drifted; the explicit path also makes the invocation shape assertable in the hermetic tests.
  _rb_cmd="cd $(_shq "$_rb_wt") && $_rb_resume"
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
m = re.fullmatch(r"\s*(\d{9,})\s*", text)      # a WHOLE-string numeric epoch (hook may write one)
if m:
    sys.stdout.write(m.group(1)); sys.exit(0)
# HERD-155 F3: require an ANCHORED "reset at/in" context before trusting any clock time. A stray 1-2
# digit number floating anywhere in the text — a JSON stdin blob, a token count, a session-id fragment,
# a "2 files changed" from a builder discussing limits — must NEVER be misread as a reset clock, which
# would schedule a bogus resume. Only parse a time that FOLLOWS the anchor.
am = re.search(r"reset[s]?\s+(?:at|in)\b(.*)", text, re.I | re.S)
if not am:
    sys.exit(0)
m = re.search(r"(\d{1,2})(?::(\d{2}))?\s*([ap]m)?", am.group(1), re.I)   # reset at 7:30pm / 7pm / 19:30
if not m:
    sys.exit(0)
# Demand a REAL clock token: an am/pm marker OR an explicit :MM. A bare integer after the anchor
# ("reset in 5 hours") is a DURATION, not a wall-clock time — don't guess it; fall to unknown-wait.
if not (m.group(3) or m.group(2)):
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

# _text_is_limit_banner <text> — 0 iff <text> looks like the runtime's actual usage-limit BANNER, not a
# builder merely DISCUSSING usage limits. HERD-155 F4: this repo's builders BUILD limit features, so
# the bare phrase "usage limit" shows up in perfectly normal assistant output (task specs, PR bodies,
# code comments — this very sentence). Detection now requires BOTH:
#   1. the canonical usage-limit PHRASE — resolved from the driver's DRIVER_AGENT_LIMIT_PATTERN
#      (HERD-176; herdr-claude carries today's exact string; codex/grok bind a @degrade: sentinel that
#      never matches, so an un-verified runtime never false-parks), AND
#   2. the banner SHAPE — a "limit reached" / "limit will reset" / "reset at|in <time>" STATUS line.
# Discussion carries the phrase but not the shape, so the transcript-scrape fallback no longer
# self-triggers a phantom park on a limit-feature builder's own words. The hook sentinel (primary
# signal) is unaffected — this only tightens the fallback.
_text_is_limit_banner() {
  local _tb="$1" _pat
  _pat="$(herd_driver_agent_limit_pattern 2>/dev/null || true)"
  [ -n "$_pat" ] || _pat='usage limit|session limit|hit your (usage|session) limit'
  # Fail-safe: a @degrade:… sentinel (codex/grok) must NEVER match a real banner line.
  case "$_pat" in @degrade:*) return 1 ;; esac
  printf '%s' "$_tb" | grep -qiE "$_pat" || return 1  # pipe-ok: single short scalar (one line), far under a pipe buffer
  printf '%s' "$_tb" | grep -qiE 'limit reached|will reset|reset[s]? (at|in) |reached your (usage|session) limit'  # pipe-ok: single short scalar (one line), far under a pipe buffer
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
  if [ -n "$_dl_text" ] && _text_is_limit_banner "$_dl_text"; then
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
  printf '%s' "$_pm_txt" | grep -qiE 'Upgrade your plan|Stop and wait|(wait for|reset) .*limit|limit to reset'  # pipe-ok: single short scalar (one line), far under a pipe buffer
}

# ── Shared actuator surface-guards (HERD-155): never a keystroke without VERIFIED pane content ──────
# The two guards below read the pane and confirm the EXPECTED surface before/after acting. They fail
# in OPPOSITE directions on purpose, because the two actuators they protect need opposite safe defaults.
#
# _pane_menu_confirmed <pane_id> — 0 ONLY on POSITIVE evidence: a NON-EMPTY pane read whose content
# matches the usage-limit arrow-menu. Unlike _pane_shows_limit_menu (which fails SAFE toward "still
# parked" so a blind read never declares the clean-select a false SUCCESS), this REQUIRES evidence and
# returns 1 on an empty/blind read. Used by the two guards that must only act on a CONFIRMED menu:
#   • BEFORE a menu-select keystroke — send "Down Enter" ONLY when the menu is confirmed present, so a
#     stray keystroke is never typed into a normal REPL / unknown surface.
#   • BEFORE a `claude --continue` prompt — REFUSE only when a menu is confirmed present, so the
#     backstop still fires where the pane can't be read (empty read → not-a-menu → proceed).
_pane_menu_confirmed() {
  local _pmc_pane="$1" _pmc_txt
  [ -n "$_pmc_pane" ] || return 1
  _pmc_txt="$(herd_driver_read_pane "$_pmc_pane" visible)"
  [ -n "$_pmc_txt" ] || return 1   # no evidence → NOT confirmed a menu
  printf '%s' "$_pmc_txt" | grep -qiE 'Upgrade your plan|Stop and wait|(wait for|reset) .*limit|limit to reset'  # pipe-ok: single short scalar (one line), far under a pipe buffer
}

# _pane_confirms_limit_wait <pane_id> [slug] — the DISTINCT post-select outcome check. "Menu gone" is
# NOT success: selecting option 1 ("Upgrade your plan") ALSO clears the menu but strands the session at
# a login/upgrade screen — a disaster we must never misreport as a clean resume. Success requires
# POSITIVE evidence the WAIT/RESUME path was taken:
#   • the agent flipped to "working" (native auto-resume kicked straight in), OR
#   • the pane shows Claude's native limit-wait / working surface (a parked "waiting for reset" banner
#     or the working spinner) AND shows neither the menu options nor an upgrade/login surface.
# Fails SAFE: an empty/blind read, a residual menu, or an upgrade/login surface → 1 (outcome
# UNVERIFIED → caller journals limit_menu_outcome_unverified and keeps the scheduled backstop).
_pane_confirms_limit_wait() {
  local _pw_pane="$1" _pw_slug="${2:-}" _pw_txt
  [ -n "$_pw_slug" ] && [ "$(_agent_status "$_pw_slug")" = "working" ] && return 0
  _pw_txt="$(herd_driver_read_pane "$_pw_pane" visible)"
  [ -n "$_pw_txt" ] || return 1                                            # no evidence → unverified
  # Wrong selection (option 1) or a still-present menu OPTION line → never a success.
  printf '%s' "$_pw_txt" | grep -qiE 'Upgrade your plan|Stop and wait|/login|Sign ?in|Choose .*plan' && return 1  # pipe-ok: single short scalar (one line), far under a pipe buffer
  # Positive wait/working evidence that the "stop and wait" path took.
  printf '%s' "$_pw_txt" | grep -qiE 'waiting.*(reset|limit)|limit.*will reset|resuming|auto-resume|esc to interrupt|Claude is working|working[.…]'  # pipe-ok: single short scalar (one line), far under a pipe buffer
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
    # HARDENING (HERD-155 F2, before): confirm the EXPECTED surface — the limit menu — is actually
    # present BEFORE sending any keystroke, so a stray "Down Enter" is never typed into a normal REPL
    # or an unknown/blind surface. On unexpected content, journal + bail (never type on no evidence).
    if ! _pane_menu_confirmed "$_cs_pane"; then
      journal_append limit_menu_absent slug "$_cs_slug" pane "$_cs_pane" attempt "$_cs_i"
      return 1
    fi
    herd_driver_send_keys "$_cs_pane" "${_cs_keys[@]}"
    # HARDENING (HERD-155 F2, after): verify the SPECIFIC expected OUTCOME — positive evidence the
    # wait/resume path was selected (agent working, or a native limit-wait banner) — NOT merely
    # "the menu text is gone" (option 1 clears the menu too, straight into an upgrade/login screen).
    if _pane_confirms_limit_wait "$_cs_pane" "$_cs_slug"; then
      journal_append limit_menu_selected slug "$_cs_slug" pane "$_cs_pane" keys "$(_limit_menu_keys)" attempt "$_cs_i"
      return 0
    fi
  done
  # Keys were sent but the wait/resume outcome could not be confirmed — do NOT claim a clean select.
  # The caller keeps the scheduled `claude --continue` backstop (which itself refuses a still-menu pane).
  journal_append limit_menu_outcome_unverified slug "$_cs_slug" pane "$_cs_pane" keys "$(_limit_menu_keys)" attempts "$_cs_max"
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
  # HERD-147 flair default: a limit-hit auto-resume is an in-progress ('busy') state in the pasture
  # header. The failed outcomes below escalate it to 'attention' (red, never softened); a confirmed
  # resume flips it to 'grazing' (building again).
  FLAIR_STATE[_lb_idx]="busy"

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
    FLAIR_STATE[_lb_idx]="attention"
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
    FLAIR_STATE[_lb_idx]="grazing"
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
    FLAIR_STATE[_lb_idx]="grazing"
  else
    record_limit "$_lb_slug" "$_lb_now" "$_lb_target" "failed"
    journal_append limit_resume_result slug "$_lb_slug" woke 0 escalated true
    DISPLAY[_lb_idx]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${_lb_sl}${C_RESET} ${C_RED}needs you · limit-resume failed · check pane${C_RESET}"
    FLAIR_STATE[_lb_idx]="attention"
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
# The genuinely-dead case (agent_status != "working") is handled by the caller as "awaiting task".

# file_mtime / _file_size / _stat_birth — portable stat helpers (GNU stat -c vs BSD/macOS stat -f),
# detected ONCE at load, mirroring backlog-view.sh's pattern. Selecting the flavor here (not per-call)
# guarantees GNU/uutils never sees a BSD '-f <fmt>' arg — on uutils '-f' means --file-system, so an
# inline 'stat -f %B || stat -c %W' chain queries the WRONG thing instead of cleanly falling through
# (HERD-207, regression of HERD-198). _stat_birth echoes the inode birth epoch, or 0 when the stat
# flavor / filesystem does not expose one (GNU '%W' yields 0 when unknown).
if stat --version 2>/dev/null | grep -qE "GNU|uutils"; then  # pipe-ok: fixed short version banner, far under a pipe buffer
  file_mtime()  { stat -c %Y "$1" 2>/dev/null || echo 0; }
  _file_size()  { stat -c %s "$1" 2>/dev/null || echo 0; }
  _stat_birth() { stat -c %W "$1" 2>/dev/null || echo 0; }
else
  file_mtime()  { stat -f %m "$1" 2>/dev/null || echo 0; }
  _file_size()  { stat -f %z "$1" 2>/dev/null || echo 0; }
  _stat_birth() { stat -f %B "$1" 2>/dev/null || echo 0; }
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
  b="$(_stat_birth "$wt")"
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

# ── SLUG-LEDGER LIFECYCLE (HERD-162 F7) ───────────────────────────────────────────────────────────
# The four line-oriented, SLUG-KEYED ledgers ($DEAD_STATE, $DEAD_RESPAWN_STATE, $LIMIT_STATE,
# $SENDKEYS_STATE) are opened at spawn-time and, until now, closed by nothing: _reap_slug tore down the
# worktree, the tabs and the ref marker, but left every slug-keyed ROW behind. Slugs are reused BY
# DESIGN (a re-spawn of the same item rebuilds `<slug>`), so those rows outlive the builder that earned
# them and are inherited by its reincarnation:
#   • a stale $LIMIT_STATE row → the resume scheduler fires `claude --continue` INTO a healthy fresh
#     builder at the old reset time (an injected --continue in the middle of a real build);
#   • a stale $SENDKEYS_STATE row → the clean-menu-select dedup thinks the park is already handled;
#   • a stale $DEAD_STATE `notified` row → the fresh builder is 💀 on its first tick, before any grace;
#   • a stale $DEAD_RESPAWN_STATE row → the reincarnation is born with its at-most-once respawn budget
#     already spent, so a genuine death escalates as "died again" instead of respawning.
# A reaped slug is TERMINAL, so its rows are closed with it. Everything here is idempotent + fail-soft:
# an absent ledger, an absent row, and a second call over an already-purged slug all no-op.

# clear_respawn <slug> — drop the slug's auto-respawn budget rows. Called ONLY from the reap path: the
# budget's whole purpose is to survive a clearing $DEAD_STATE record within one builder's life (that is
# what makes "died AGAIN" detectable), so nothing short of the slug's death may clear it.
clear_respawn() {
  [ -s "$DEAD_RESPAWN_STATE" ] || return 0
  local _cr_tmp="${DEAD_RESPAWN_STATE}.$$"
  grep -v "^$1 " "$DEAD_RESPAWN_STATE" 2>/dev/null > "$_cr_tmp"
  mv "$_cr_tmp" "$DEAD_RESPAWN_STATE" 2>/dev/null || rm -f "$_cr_tmp" 2>/dev/null
}

# _purge_slug_ledgers <slug> [worktree] — close EVERY slug-keyed ledger row this slug owns. The one
# call site is _reap_slug, the shared teardown primitive every exit path funnels through (merge,
# startup sweep, post-merge sweep, and retirement's abandon/dead convergence) — so "opened at spawn,
# closed on every exit path" holds without each path remembering to do it. Journals ONE purge event
# naming which ledgers actually carried a row, so a reap that cleaned nothing stays silent.
_purge_slug_ledgers() {
  local _ps_slug="$1" _ps_dir="${2:-}" _ps_had=""
  [ -n "$_ps_slug" ] || return 0
  [ -n "$(dead_first_seen "$_ps_slug")" ]        && _ps_had="${_ps_had}dead,"
  respawn_recorded "$_ps_slug"                   && _ps_had="${_ps_had}respawn,"
  [ -n "$(limit_state "$_ps_slug")" ]            && _ps_had="${_ps_had}limit,"
  [ -n "$(sendkeys_state "$_ps_slug")" ]         && _ps_had="${_ps_had}sendkeys,"
  clear_dead     "$_ps_slug"
  clear_respawn  "$_ps_slug"
  clear_limit    "$_ps_slug" "$_ps_dir"
  clear_sendkeys "$_ps_slug"
  [ -n "$_ps_had" ] && journal_append slug_ledgers_purged slug "$_ps_slug" ledgers "${_ps_had%,}"
  return 0
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

# ── Claim release for an abandoned builder (HERD-162 F12) ────────────────────────────────────────
# A claim was taken before the worktree existed and released by NOTHING. When the builder that took it
# dies before opening a PR, the tracker item stays In Progress + assigned forever, and the other
# operator's pre-spawn claim reads it as ALREADY and aborts — the item is wedged against everyone but
# the original claimant, who is a dead process. The dead-builder reconcile is the one place that knows
# the builder is gone, so it is where the claim is given back.
#
# WHEN a claim is released — all three must hold, and the rails are deliberately conservative:
#   • CLAIM_RELEASE is opted in (off by default ⇒ this whole path is byte-inert);
#   • the slug carries a tracker ref (the `.herd-ref-<slug>` marker the lane wrote at spawn) — an
#     untracked spawn claimed nothing and has nothing to release;
#   • the builder is genuinely ABANDONED: it will not be auto-respawned, and its worktree is clean.
# The two refusals are the important half. A dead builder with COMMITS OR DIRT is a human-recovery
# hold: releasing it invites a second operator to build a duplicate on top of work nobody has salvaged
# yet. And a builder about to be RESPAWNED still owns its item — the fresh agent continues the claim.
# Both refusals are journaled with their reason, and both say so on the 💀 notification, so a hold is
# never a silence.
#
# Deliberately ASYMMETRIC with the respawn: we classify the respawn verdict here with the same PURE
# classifier _maybe_autorespawn_dead_builder uses, but we do not wait to see whether the respawn
# SUCCEEDS. A respawn that then fails escalates loudly ("restart by hand") with the claim still held —
# holding a claim too long is recoverable by one command; releasing one out from under an agent that
# did start is a double-build. We fail toward the hold.

# _maybe_release_claim <slug> <worktree> — echo a SHORT clause to append to the 💀 notification body
# (leading " · "), or NOTHING at all when CLAIM_RELEASE is off / the slug is untracked. Never fails.
_maybe_release_claim() {
  local _mr_slug="$1" _mr_wt="$2" _mr_mode _mr_ref _mr_on=0 _mr_done=0 _mr_who _mr_out
  _mr_mode="$(herd_claim_release_mode)"
  [ "$_mr_mode" = off ] && return 0
  _mr_ref="$(_slug_ref "$_mr_slug")"
  [ -n "$_mr_ref" ] || return 0        # untracked spawn — no claim was ever taken

  # RAIL 1 — work in the tree, checked FIRST and INDEPENDENTLY of the respawn flag. Deliberately NOT
  # read off _classify_respawn: that classifier answers "should we respawn?", so it short-circuits to
  # OFF before it ever looks at has-work. Reusing its verdict here would release the claim of every
  # dead builder that left work whenever DEAD_BUILDER_AUTORESPAWN happens to be off — precisely the
  # duplicate-build-on-unrecovered-work hazard this rail exists to prevent.
  if _worktree_has_work "$_mr_wt"; then
    journal_append claim_release_held ref "$_mr_ref" slug "$_mr_slug" reason has-work
    printf ' · claim %s HELD (worktree has work — recover it, then re-queue)' "$_mr_ref"; return 0
  fi
  # RAIL 2 — a builder about to be respawned still owns its item. The tree is provably clean by now,
  # so the shared classifier is asked exactly the question it answers, with has-work pinned to 0.
  _dead_autorespawn_on         && _mr_on=1
  respawn_recorded "$_mr_slug" && _mr_done=1
  if [ "$(_classify_respawn "$_mr_on" 0 "$_mr_done")" = RESPAWN ]; then
    journal_append claim_release_skipped ref "$_mr_ref" slug "$_mr_slug" reason respawning
    printf ' · claim %s held (respawning)' "$_mr_ref"; return 0
  fi

  # DRYRUN: name the intent, write nothing (mirrors every other mutation guard in the watcher).
  if [ -n "${DRYRUN:-}" ]; then
    printf ' · claim %s would be released (dry-run)' "$_mr_ref"; return 0
  fi
  _mr_who="$(_herd_claim_identity)"; [ -n "$_mr_who" ] || _mr_who="unknown-operator"
  _mr_out="$(herd_claim_release "$_mr_ref" "$_mr_who" "$_mr_slug" dead-builder)"
  case "$_mr_out" in
    # The dead builder's WORKTREE still stands (this reconcile never reaps it — retirement owns that on
    # its own cadence). Say so: whoever re-picks the item hits `git worktree add` on an existing path
    # otherwise, and reads the collision as a herdkit bug rather than as leftover from a death.
    released)    printf ' · claim %s released — re-pickable (sweep its worktree first)' "$_mr_ref" ;;
    flagged)     printf ' · claim %s still held — re-queue it' "$_mr_ref" ;;
    unsupported) printf ' · claim %s still held (backend cannot release) — re-queue it' "$_mr_ref" ;;
    notours)     printf ' · claim %s belongs to another operator — left alone' "$_mr_ref" ;;
    *)           : ;;
  esac
  return 0
}

# _reconcile_dead_builder <slug> <worktree> <agent-status> — drive the ledger + notification for ONE
# PR-less, non-working builder and echo the verdict (ALIVE | PENDING | DEAD). Called from the tick's
# no-PR/non-working branch: an EMPTY agent-status means the slug has NO agent record at all (the dead
# signature); a non-empty status means the agent is still listed (idle/done) and therefore alive.
# has_pr is 0 here by construction (the caller only reaches this on a PR-less slug). Records the
# first-seen anchor on the first sighting, clears it the instant any liveness signal returns, and
# fires exactly one 💀 notification (+ journal event) when a slug crosses into DEAD.
_reconcile_dead_builder() {
  local _rd_slug="$1" _rd_wt="$2" _rd_astatus="$3" _rd_liveness="${4:-}"
  local _rd_now _rd_grace _rd_has_agent _rd_tgrow _rd_first _rd_verdict
  _rd_now="$(_now)"
  _rd_grace="$(_dead_grace_secs)"
  # A present agent record (any status) means the agent is still listed ⇒ normally alive. But a herdr
  # crash can leave the agent LISTED with a stale status while its PROCESS is dead (HERD-114); a
  # POSITIVE liveness='dead' probe (pane exists but runs no claude) overrides the listing and counts as
  # NO live agent, so a listed-but-unwakeable builder crosses into DEAD just like a vanished one. Only
  # a positive 'dead' overrides; 'unknown'/'alive'/empty preserve the prior listing-based signal.
  if [ "$_rd_liveness" = "dead" ]; then
    _rd_has_agent=0
  else
    [ -n "$_rd_astatus" ] && _rd_has_agent=1 || _rd_has_agent=0
  fi
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
        journal_append builder_dead slug "$_rd_slug" first_seen "${_rd_first:-$_rd_now}" \
          cause "$([ "$_rd_liveness" = "dead" ] && printf 'session-dead' || printf 'vanished')"
        # CLAIM RELEASE (HERD-162 F12) runs BEFORE the 💀 surface so the notification can state what
        # actually happened to the tracker item, rather than leaving the operator to discover the wedge
        # later. Empty (and byte-inert) when CLAIM_RELEASE is off — the default.
        local _rd_claim; _rd_claim="$(_maybe_release_claim "$_rd_slug" "$_rd_wt")"
        # Wording reflects the actual cause: a listed-but-unwakeable session vs a fully vanished agent.
        if [ "$_rd_liveness" = "dead" ]; then
          herd_driver_notify "💀 builder died: ${_rd_slug}" \
            "${_rd_slug}: agent session dead (unwakeable, no PR) — re-spawn${_rd_claim}" default
        else
          herd_driver_notify "💀 builder died: ${_rd_slug}" \
            "${_rd_slug}: agent vanished (no agent, no PR) — re-spawn${_rd_claim}" default
        fi
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

# ── Corpse cleanup: STEP 0 of every respawn (HERD-162 F6) ────────────────────────────────────────
# A respawn used to create the NEW tab first and only then call `herdr agent start <slug>` — which
# fails `agent_name_taken`, because the DEAD builder's agent registry row (and the tab whose pane holds
# it) is still there. That is not an edge case: it is the HERD-114 crash the feature exists FOR, where
# herdr keeps a listed agent whose process is dead. So the respawn structurally failed exactly when it
# was needed, leaving the freshly-created tab as shrapnel. Reaping the corpse is therefore not cleanup
# after the fact — it is the FIRST step, and the respawn is attempted only once the name is free.
#
# WORKTREE ORDERING (the claude-pane-root doctrine): a respawn restarts a builder IN PLACE, so unlike
# the retire path it NEVER removes the worktree — the "remove the worktree before killing the panes"
# rule has nothing to order here. What it does tell us still holds: `claude` is the pane's ROOT
# process, so closing the corpse's tab is what actually frees its agent name.

# _reap_builder_corpse <slug> [worktree] — drop the slug-keyed markers a reincarnated agent must not
# inherit, then retire the dead builder's registry row + its tab. Returns 0 iff the agent NAME is free
# afterwards (nothing left holding it), which is the only postcondition the respawn depends on.
# Everything is fail-soft + idempotent: no corpse, no herdr, or a headless driver all no-op to success.
# The MARKER purge runs under every driver; only the pane/tab half is herdr-specific.
_reap_builder_corpse() {
  local _rc_slug="$1" _rc_wt="${2:-}" _rc_pane _rc_tab _rc_reaped=""

  # 0. The slug-keyed markers a FRESH agent in this same worktree must not inherit. FIRST, and above the
  #    headless return, because these are plain files with nothing to do with panes: a stale limit target
  #    would schedule a `claude --continue` into the new builder, and a stale sendkeys row would suppress
  #    the clean menu-select on its first real park — and both hazards exist under EVERY driver. (The
  #    dead anchor and the respawn budget deliberately survive: the caller is mid-decision on both.)
  if [ -n "$(limit_state "$_rc_slug")" ]; then
    clear_limit "$_rc_slug" "$_rc_wt"
    _rc_reaped="${_rc_reaped}limit,"
  fi
  if [ -n "$(sendkeys_state "$_rc_slug")" ]; then
    clear_sendkeys "$_rc_slug"
    _rc_reaped="${_rc_reaped}sendkeys,"
  fi

  # headless has no tabs/panes and its `start_agent` overwrites the registry entry outright — there is
  # no name to free, so the pane/tab half of the reap is a no-op there.
  if [ "$(herd_driver_name)" = "headless" ] || ! command -v herdr >/dev/null 2>&1; then
    [ -n "$_rc_reaped" ] && journal_append builder_corpse_reaped slug "$_rc_slug" reaped "${_rc_reaped%,}"
    return 0
  fi

  # 1. The corpse's own agent pane, if the registry still names one. `claude` is the pane's ROOT
  #    process, so closing the pane is what retires the agent row and frees the name. Routed through
  #    the ONE guarded close (HERD-134) like every other engine actor: it re-reads the pane's LIVE
  #    identity and REFUSES (loudly, via pane_close_refused) when the id has been recycled onto a
  #    neighbour. A refusal is not fatal here — the name probe below decides.
  _rc_pane="$(herd_driver_agent_pane_id "$_rc_slug" 2>/dev/null || true)"
  if [ -n "$_rc_pane" ] && herd_close_pane_verified "$_rc_pane" "agent:$_rc_slug"; then
    _rc_reaped="${_rc_reaped}pane,"
  fi

  # 2. The corpse's BUILDER tab(s). A tab whose agent pane already died still holds the tab-registry row
  #    and, under a herdr crash, can still hold the name. Only the builder label (== slug) is ours here:
  #    a dead PR-less builder has no review·/resolve· tab, and closing one on a respawn would be a bug.
  while IFS= read -r _rc_tab; do
    [ -n "$_rc_tab" ] || continue
    herdr tab close "$_rc_tab" >/dev/null 2>&1 || true
    _herd_tabs_drop_row "$TREES/.herd-tabs" "$_rc_tab"
    _rc_reaped="${_rc_reaped}tab,"
  done < <(_slug_builder_tab_ids "$_rc_slug")

  [ -n "$_rc_reaped" ] && journal_append builder_corpse_reaped slug "$_rc_slug" reaped "${_rc_reaped%,}"

  # The postcondition, PROBED not assumed: is the name free? An agent still listed under this slug means
  # `agent start` will fail agent_name_taken, and the caller must escalate rather than create a tab it
  # will have to close again.
  [ -z "$(_agent_status "$_rc_slug")" ]
}

# _slug_builder_tab_ids <slug> — the herdr tab ids labelled EXACTLY <slug> (the builder tab), scoped to
# this project's workspace when it resolves. Deliberately NOT the review·/resolve· labels that
# herd_teardown_slug also collects: those belong to a PR's gate, not to a pre-PR builder's corpse.
# Empty (and silent) without herdr, on a parse failure, or when no such tab exists.
_slug_builder_tab_ids() {
  local _bt_slug="$1" _bt_wsid
  command -v herdr >/dev/null 2>&1 || return 0
  _bt_wsid="$(herd_resolve_workspace_id 2>/dev/null || true)"
  herdr tab list 2>/dev/null | SLUG="$_bt_slug" WS="$_bt_wsid" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]; ws = os.environ.get("WS", "")
try:
  for t in (json.load(sys.stdin).get("result") or {}).get("tabs") or []:
    if t.get("label") == slug and (not ws or t.get("workspace_id", "") == ws):
      print(t["tab_id"])
except Exception:
  pass
' 2>/dev/null || true
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
  # STEP 0 — never stack a respawn on a corpse (HERD-162 F6). Retire the dead agent's pane/tab and its
  # poisonous slug-keyed markers FIRST; only then is the agent name free for `agent start`. A corpse we
  # could not clear means the name is still held, so bail BEFORE creating a tab we would have to close.
  if ! _reap_builder_corpse "$_rw_slug" "$_rw_wt"; then
    printf '⚠️  herdkit: agent name %s is still held by a corpse we could not retire — not respawning\n' "$_rw_slug" >&2
    journal_append builder_respawn_blocked slug "$_rw_slug" reason agent-name-held
    return 1
  fi
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
  # Resolve the (possibly runtime-qualified) model ref and compose the runtime tail through the
  # driver seam (HERD-150 P2) — the same composition the lanes use, no hardcoded claude outside the
  # seam. Byte-identical to the old inline `claude --model … <flags> "<ptr>"` for a bare model.
  local _rw_res _rw_driver
  _rw_res="$(herd_model_resolve "$_rw_model")" || return 1
  _rw_driver="${_rw_res%%$'\t'*}"; _rw_model="${_rw_res#*$'\t'}"
  local -a _rw_rt=(); local _rw_t
  while IFS= read -r -d '' _rw_t; do _rw_rt+=("$_rw_t"); done < <(herd_driver_agent_spawn_argv "$_rw_driver" "$_rw_model" "$_rw_flags" "$_rw_ptr")
  # Launch through the shared herdr CLI bridge (issue #514): the attach CLI splits the fresh tab's
  # root and attaches (same one-pane-right layout); pre-0.7.5 keeps the byte-identical argv.
  # shellcheck disable=SC2086  # $_rw_wsid intentionally word-splits (mirrors the lane's args).
  if _herd_herdr_attach_cli; then
    if herd_driver_herdr_attach_agent "$_rw_slug" "$_rw_driver" "$_rw_root" "$_rw_wt" right "" -- "${_rw_rt[@]}" >/dev/null 2>&1; then
      return 0
    fi
  elif herdr agent start "$_rw_slug" ${_rw_wsid:+--workspace "$_rw_wsid"} --cwd "$_rw_wt" --tab "$_rw_tab" --split right --no-focus -- "${_rw_rt[@]}" >/dev/null 2>&1; then
    return 0
  fi
  # agent start FAILED after the tab was already created — the exact HERD-136 corpse-tab shape: a
  # residual 'agent_name_taken' race (the dead builder's agent name still held in herdr) leaves the
  # just-created tab as empty shrapnel that nothing reaps (the observed wE:tMP/tMQ corpses). Close it
  # on the failure path and journal the reap; the caller escalates via its 💀 notification and does NOT
  # spend the at-most-once budget (mirrors the drainers' agent_name_taken cleanup in research/scribe.sh).
  herdr tab close "$_rw_tab" >/dev/null 2>&1 || true
  journal_append builder_respawn_tab_reaped slug "$_rw_slug" tab "$_rw_tab"
  return 1
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

# ── Wedged-builder detection (HERD-278) ───────────────────────────────────────────────────────────
# GROUNDED in three live incidents on 2026-07-09: a builder's agent read 'done', its worktree still
# existed, and it had opened NO PR. The console called each one a benign spare — "awaiting task ·
# assign or retire" — which reads as "this builder has no work", exactly backwards: it HAD work, it
# just never delivered it. The coordinator woke all three by hand and each finished the job. Nothing
# in the console said to.
#
# A wedge is neither of the two states the watcher already knows. It is not DEAD (the agent is alive
# and listed — the dead reconciliation correctly rules death out), and it is not a SPARE (a spare was
# never tasked; a wedge was, and abandoned the task mid-delivery). So it gets its own row and its own
# ledger, sitting between them in the PR-less/non-working branch of the tick.
#
# THE SIGNATURE — all four, simultaneously:
#   • agent_status reads exactly 'done'      (an 'idle' agent is a genuine spare; 'working' is building)
#   • the open-PR roster positively has NO PR (never inferred from a `gh pr list` FAILURE — the caller
#                                              only reaches here when PRS_LOOKUP_OK=1)
#   • no commits ahead of base OR a dirty tree (i.e. the tree holds nothing that is already a pushable,
#                                              finished commit series)
#   • it has PERSISTED past WEDGE_GRACE_MIN   (a builder mid-`gh pr create` shows this exact signature
#                                              for a few seconds — no-false-red, so it must age in)
#
# WHY the third clause looks inverted: a done builder with commits ahead AND a clean tree has already
# produced the thing a PR is made of. Its PR is a push and an API call away — the honest reading is
# "in flight", not "wedged" — and PUSH_GATE=human parks precisely there on purpose (that branch is
# handled earlier in the tick). A done builder with NOTHING committed never started delivering; a done
# builder with uncommitted changes stopped halfway. Those two are the wedge, and they are exactly the
# three incidents. (See _classify_wedged_builder for the token-by-token contract.)
#
# DISPLAY + JOURNAL ONLY by default. The remedy the coordinator applied by hand — one nudge to the
# agent pane — ships DORMANT behind WEDGE_AUTOWAKE (below), because a wake types into a live agent.

# _wedge_grace_secs — how long the WEDGE signature must persist before the row surfaces. Configurable
# via WEDGE_GRACE_MIN (minutes); non-numeric/unset falls back to 10 minutes — comfortably longer than
# a `gh pr create` round-trip (the false-red this grace exists to prevent), short enough that a wedged
# overnight builder is found on the next glance at the console. A literal 0 is honored (tests).
_wedge_grace_secs() {
  case "${WEDGE_GRACE_MIN:-}" in
    ''|*[!0-9]*) printf '%s' 600 ;;
    *)           printf '%s' $(( WEDGE_GRACE_MIN * 60 )) ;;
  esac
}

# wedge_first_seen <slug> — the recorded first-seen epoch for this slug's WEDGE signature, or nothing.
wedge_first_seen() {
  [ -s "$WEDGE_STATE" ] || return 0
  awk -v s="$1" '$1==s{f=$2} END{if(f!="")print f}' "$WEDGE_STATE" 2>/dev/null || true
}
# wedge_state_of <slug> — the recorded state word (pending | notified | woken), or nothing.
wedge_state_of() {
  [ -s "$WEDGE_STATE" ] || return 0
  awk -v s="$1" '$1==s{st=$3} END{print st}' "$WEDGE_STATE" 2>/dev/null || true
}
# wedge_notified <slug> — true iff the ⚠️ notification already fired for this slug's current record
# (dedup guard, so a wedged builder notifies exactly once, not every tick). 'woken' implies notified.
wedge_notified() {
  case "$(wedge_state_of "$1")" in notified|woken) return 0 ;; *) return 1 ;; esac
}
# wedge_woken <slug> — true iff the auto-wake nudge was already delivered for this record (at-most-once
# per wedge; a slug that wedges AGAIN after escaping gets a fresh record and so a fresh nudge).
wedge_woken() { [ "$(wedge_state_of "$1")" = "woken" ]; }

# _wedge_upsert <slug> <first-seen> <state> — drop any prior line for this slug, append the fresh one
# (temp+mv), mirroring _dead_upsert.
_wedge_upsert() {
  local _wu_tmp="${WEDGE_STATE}.$$"
  { [ -f "$WEDGE_STATE" ] && grep -v "^$1 " "$WEDGE_STATE" 2>/dev/null
    printf '%s %s %s\n' "$1" "$2" "$3"
  } > "$_wu_tmp" 2>/dev/null && mv "$_wu_tmp" "$WEDGE_STATE" 2>/dev/null || rm -f "$_wu_tmp" 2>/dev/null
}
# record_wedge_seen <slug> <epoch> — first sighting of the signature: record the anchor epoch, pending.
record_wedge_seen() { _wedge_upsert "$1" "$2" pending; }
# record_wedge_state <slug> <state> — flip the record's state word, PRESERVING its first-seen anchor.
record_wedge_state() { local _rws_f; _rws_f="$(wedge_first_seen "$1")"; _wedge_upsert "$1" "${_rws_f:-$(_now)}" "$2"; }
# clear_wedge <slug> — drop the slug's record (it escaped: a PR opened, or it went back to working).
clear_wedge() {
  [ -s "$WEDGE_STATE" ] || return 0
  local _cw_tmp="${WEDGE_STATE}.$$"
  grep -v "^$1 " "$WEDGE_STATE" 2>/dev/null > "$_cw_tmp"
  mv "$_cw_tmp" "$WEDGE_STATE" 2>/dev/null || rm -f "$_cw_tmp" 2>/dev/null
}

# _classify_wedged_builder <agent-status> <has-pr> <commits-ahead> <dirty> <first-seen> <now> <grace>
# — the PURE verdict for a live, non-working builder. Echoes exactly one token:
#   NOT_WEDGED — an escape hatch holds (an open PR; an agent that is not 'done'; or a finished,
#                committed, clean tree whose PR is merely in flight) ⇒ the caller clears any record
#   PENDING    — the full WEDGE signature holds but has NOT yet persisted past <grace> (no prior
#                first-seen, or now - first-seen < grace) ⇒ hold; the row stays whatever it was
#   WEDGED     — the signature has held continuously past the grace window ⇒ surface ⚠️ + notify
# <has-pr>/<dirty> are "1"/"0"; <commits-ahead> is an integer (a non-numeric probe reads as 0);
# <first-seen> is the recorded anchor epoch (empty on the first sighting of the signature).
_classify_wedged_builder() {
  local astatus="$1" has_pr="${2:-0}" commits="${3:-0}" dirty="${4:-0}" first_seen="$5" now="${6:-0}" grace="${7:-0}"
  case "$commits" in ''|*[!0-9]*) commits=0 ;; esac
  # An open PR is the whole point of a builder: it delivered. Never a wedge.
  [ "$has_pr" = "1" ] && { printf 'NOT_WEDGED'; return 0; }
  # Only a 'done' agent can be wedged. 'working' is building; 'idle' is a genuine unassigned spare;
  # an EMPTY status means no agent record at all — that is the dead reconciliation's business.
  [ "$astatus" = "done" ] || { printf 'NOT_WEDGED'; return 0; }
  # Committed AND clean: the work exists as a pushable commit series, so its PR is in flight (or held
  # by PUSH_GATE). Nothing to wake. Only an empty tree or a half-finished dirty one is a wedge.
  [ "$commits" -gt 0 ] && [ "$dirty" != "1" ] && { printf 'NOT_WEDGED'; return 0; }
  # Full wedge signature. Age it in past the grace window so a builder inside `gh pr create` — which
  # shows this exact signature for a few seconds — is never flagged (no-false-red).
  if [ -z "$first_seen" ] || [ "$(( now - first_seen ))" -lt "$grace" ]; then
    printf 'PENDING'; return 0
  fi
  printf 'WEDGED'
}

# _wedge_commits_ahead <worktree> — commits this branch carries that the base does not. A git failure
# reads as 0 (an uninspectable tree has produced nothing we can prove), which only ever makes the
# signature MORE wedge-like; the grace window, not this probe, is what prevents a false red.
_wedge_commits_ahead() {
  local _wc; _wc="$(git -C "$1" rev-list HEAD --count --not "$DEFAULT_BRANCH" 2>/dev/null || printf 0)"
  case "$_wc" in ''|*[!0-9]*) _wc=0 ;; esac
  printf '%s' "$_wc"
}
# _wedge_dirty <worktree> — 1 iff the tree has staged/unstaged/untracked changes, else 0.
_wedge_dirty() {
  [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ] && printf 1 || printf 0
}

# ── Wedge AUTO-WAKE (bounded, opt-in, DEFAULT OFF) ────────────────────────────────────────────────
# The remedy is not clever: the coordinator sent the wedged agent one nudge and it finished the job,
# three times out of three. WEDGE_AUTOWAKE=on lets the watcher send that same nudge itself, through
# the SAME driver seam the auto-refix bounce uses (`herd_driver_send_text` = pane run + explicit Enter
# — HERD-186; typing without the Enter leaves the prompt sitting in the buffer and the agent never
# wakes), then verifies agent_status flips to "working". Journaled exactly like a refix wake.
# Bounded by two rails: it fires AT MOST ONCE per wedge record (a nudge that did not take escalates to
# the red row rather than typing into the same pane every tick), and only ever at the WEDGED crossing
# — never at PENDING, so the grace window still governs. SHIPS DORMANT: with the key off the function
# is a hard no-op that touches no pane, writes no journal event, and leaves the row byte-identical.

# _wedge_autowake_on — true iff WEDGE_AUTOWAKE opts in. DEFAULT OFF: only on|true|yes|1 enable it.
_wedge_autowake_on() {
  case "${WEDGE_AUTOWAKE:-off}" in
    on|true|yes|1) return 0 ;;
    *)             return 1 ;;
  esac
}

# _wedge_wake_prompt <slug> — the nudge text. Names the observation, not a diagnosis: the agent may
# have finished and forgotten the PR, or stopped halfway. Both remedies are one line apart.
_wedge_wake_prompt() {
  printf 'Your worktree for %s has no open PR and your agent has stopped.\nIf the work is finished: run the healthcheck, commit, push, and open the PR with `gh pr create`.\nIf it is not finished: resume where you left off, then do the same.\nDo not merge the PR and do not edit BACKLOG.md.' "$1"
}

# _maybe_autowake_wedged_builder <slug> — drive the bounded auto-wake for ONE slug that has just
# crossed into WEDGED. Echoes the verdict (OFF | DRYRUN | ALREADY | NO_PANE | WOKE | NO_WAKE) for tests
# and for the caller's row choice; spends the at-most-once budget only on a delivered nudge. Never runs
# under DRYRUN (logs intent instead), mirroring _maybe_autorespawn_dead_builder.
_maybe_autowake_wedged_builder() {
  local _aw_slug="$1" _aw_pane _aw_before _aw_after _aw_woke=0
  # OFF ⇒ hard no-op: no pane lookup, no journal, no ledger write. The ⚠️ row already fired.
  _wedge_autowake_on || { printf 'OFF'; return 0; }
  wedge_woken "$_aw_slug" && { printf 'ALREADY'; return 0; }
  if [ -n "${DRYRUN:-}" ]; then
    printf '🐑 (dry-run) would auto-wake wedged builder %s\n' "$_aw_slug" >&2
    printf 'DRYRUN'; return 0
  fi
  # The agent reads 'done', not 'working' — its TUI is still up, so the raw prompt submit is the wake
  # path (the same one REVIEW_AUTOFIX uses for done builders; `claude --continue` would be typed into
  # that TUI as literal text). _find_builder_pane_id_any matches idle AND done panes.
  _aw_pane="$(_find_builder_pane_id_any "$_aw_slug")"
  if [ -z "$_aw_pane" ]; then
    journal_append wedge_wake_result slug "$_aw_slug" woke 0 reason "no agent pane to deliver the nudge to"
    printf 'NO_PANE'; return 0
  fi
  _aw_before="$(_agent_status "$_aw_slug")"
  journal_append wedge_wake slug "$_aw_slug" agent_status_before "${_aw_before:-unknown}"
  herd_driver_send_text "$_aw_pane" "$(_wedge_wake_prompt "$_aw_slug")"
  _wait_agent_working "$_aw_slug" "${HERD_REFIX_WAIT_TIMEOUT:-15}" && _aw_woke=1
  _aw_after="$(_agent_status "$_aw_slug")"
  journal_append wedge_wake_result slug "$_aw_slug" agent_status_before "${_aw_before:-unknown}" \
    agent_status_after "${_aw_after:-unknown}" woke "$_aw_woke"
  # Spend the budget on DELIVERY, not on success: the prompt is in that pane either way, and re-typing
  # it every tick is exactly the runaway this rail exists to avoid. A nudge that did not wake the agent
  # leaves the record 'notified', so the next tick paints the honest red row again.
  if [ "$_aw_woke" = "1" ]; then
    record_wedge_state "$_aw_slug" woken
    herd_driver_notify "🔁 wedged builder woken: ${_aw_slug}" \
      "${_aw_slug}: finished without a PR — auto-wake nudge delivered, agent is working again" default
    printf 'WOKE'
  else
    printf 'NO_WAKE'
  fi
}

# _reconcile_wedged_builder <slug> <worktree> <agent-status> — drive the ledger + notification + the
# (dormant) auto-wake for ONE PR-less, non-working builder, and echo the verdict
# (NOT_WEDGED | PENDING | WEDGED). Called from the tick's no-PR/non-working branch, AFTER the dead
# reconciliation has ruled death out — so the agent here is alive and listed. has_pr is 0 by
# construction (the caller only reaches this on a PR-less slug, and only when PRS_LOOKUP_OK=1).
# Records the first-seen anchor on the first sighting, clears it the instant the slug escapes, and
# journals + notifies exactly once when a slug crosses into WEDGED. The ⚠️ notification is suppressed
# only when the (dormant) auto-wake actually WOKE the agent — that path fires its own 🔁 notification,
# and shouting "wake or inspect it" at an operator whose builder is already working again is the same
# false-red this item exists to delete.
_reconcile_wedged_builder() {
  local _rw_slug="$1" _rw_wt="$2" _rw_astatus="$3"
  local _rw_now _rw_grace _rw_first _rw_verdict
  _rw_now="$(_now)"
  _rw_grace="$(_wedge_grace_secs)"
  _rw_first="$(wedge_first_seen "$_rw_slug")"
  # The git probes only run for a 'done' agent — the one status that can be wedged. Every other status
  # short-circuits to NOT_WEDGED without touching git, so the common idle/spare tick is unchanged.
  local _rw_commits=0 _rw_dirty=0
  if [ "$_rw_astatus" = "done" ]; then
    _rw_commits="$(_wedge_commits_ahead "$_rw_wt")"
    _rw_dirty="$(_wedge_dirty "$_rw_wt")"
  fi
  _rw_verdict="$(_classify_wedged_builder "$_rw_astatus" 0 "$_rw_commits" "$_rw_dirty" \
    "${_rw_first:-}" "$_rw_now" "$_rw_grace")"
  case "$_rw_verdict" in
    NOT_WEDGED)
      [ -n "$_rw_first" ] && clear_wedge "$_rw_slug" ;;
    PENDING)
      [ -n "$_rw_first" ] || record_wedge_seen "$_rw_slug" "$_rw_now" ;;
    WEDGED)
      if ! wedge_notified "$_rw_slug"; then
        record_wedge_state "$_rw_slug" notified
        journal_append builder_wedged slug "$_rw_slug" first_seen "${_rw_first:-$_rw_now}" \
          commits "$_rw_commits" dirty "$_rw_dirty"
        # Ship-dormant remedy: a hard no-op (verdict OFF) unless WEDGE_AUTOWAKE opted in. Fires ONCE
        # per crossing, guarded by the wedge_notified dedup above, exactly like the dead-builder
        # auto-respawn. The JOURNAL event above is unconditional — a wedge is always recorded, whether
        # or not anything was done about it.
        if [ "$(_maybe_autowake_wedged_builder "$_rw_slug")" != "WOKE" ]; then
          # Nobody is on it: the default detect-and-surface path, or a nudge that failed to land.
          herd_driver_notify "⚠️ builder finished without a PR: ${_rw_slug}" \
            "${_rw_slug}: agent done, no PR, nothing pushable — wake or inspect it" default
        fi
      fi ;;
  esac
  printf '%s' "$_rw_verdict"
}

# ── Finish-line watchdog (HERD-392) ───────────────────────────────────────────────────────────────
# GROUNDED in six live instances 2026-07-16..18: a builder produced real work — a committed-but-
# unpushed series, or an uncommitted diff — then its agent went quiet with NO PR ever opened, and
# nobody noticed until a human happened to look. WEDGE (above, HERD-278) deliberately treats a clean,
# committed-ahead tree as NOT wedged ("its PR is a push away, in flight") — exactly the gap these six
# incidents sat in. This leg closes it, and goes one step further than wedge's detect-and-surface
# stance: it actively RE-TASKS the builder once, because "push it yourself" is a one-line ask.
#
# SHIP-DORMANT, and more strictly than WEDGE_GRACE_MIN (which always defaults to a live 10m grace):
# this ENTIRE leg — detection, re-task, escalation, every store shellout — does not exist until an
# operator sets FINISH_STALL_MIN to a positive integer. Unset/non-numeric/<=0 is a hard no-op: zero
# git probes beyond what the tick already ran, zero python3 shellouts, byte-identical console.
#
# THE SIGNATURE — all hold, simultaneously:
#   • agent_status reads 'done' OR 'idle' continuously (an idle agent counts here, unlike wedge —
#     the discriminator is the WORK itself, not the pane status: an agent that produced a commit or a
#     diff was plainly tasked, whatever its pane now reads)
#   • the tree carries genuine work: uncommitted tracked changes, OR commits ahead of its OWN remote
#     branch (origin/<branch> — never "ahead of base branch", which is what wedge measures and would
#     re-flag the exact in-flight case wedge exists to exempt)
#   • the open-PR roster positively has NO PR (the caller only reaches here when PRS_LOOKUP_OK=1)
#   • the agent is not currently limit-parked (a parked agent cannot act on a nudge; its own hold row
#     owns the tick)
#   • it has PERSISTED past FINISH_STALL_MIN, continuously
#
# MULTI-SEAT: the clock is a SHARED-POOL anchor (pysrc/herd/store.py finish_stall_* accessors, sqlite
# or flat backend), not seat memory — every seat ticking the same slug converges on the same first-seen
# epoch and the same state word, so a restart or a seat handoff never resets (or double-fires) the
# clock. On a store failure every accessor fails toward "never seen" / "no-op", which only ever DELAYS
# a flag, never fabricates one.
#
# THE REMEDY LADDER (bounded to two rungs, mirroring the refix budget doctrine — never open-ended):
#   1. FIRST crossing (state 'pending') ⇒ deliver ONE re-task nudge through the SAME driver seam /
#      verified-wake discipline the refix bounce uses (pane run + explicit Enter, then poll
#      agent_status). Delivered + accepted ⇒ record 'retasked' and RESET the anchor to the observed
#      wake moment — the SECOND-STALL clock starts fresh from that real transition, never from the
#      original sighting. Undelivered / not accepted ⇒ record 'escalated' immediately (a nudge that
#      cannot land gets no second chance) and journal finish_stall_escalated.
#   2. A SECOND full grace window elapses while still signatured (state 'retasked') ⇒ record
#      'escalated' and journal finish_stall_escalated — the re-task did not finish the job.
#   3. 'escalated' is terminal: the needs-you row keeps rendering, nothing fires again, until the slug
#      escapes (a PR opens, the agent starts working, or the signature clears).

# _finish_stall_min — FINISH_STALL_MIN in whole minutes on stdout + rc 0, or rc 1 (nothing printed)
# when the leg is OFF: unset, empty, non-numeric, or <= 0. A typo can never turn this on.
_finish_stall_min() {
  case "${FINISH_STALL_MIN:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$FINISH_STALL_MIN" -gt 0 ] 2>/dev/null || return 1
  printf '%s' "$FINISH_STALL_MIN"
}
# _finish_stall_enabled — true iff FINISH_STALL_MIN opts this whole leg in.
_finish_stall_enabled() { _finish_stall_min >/dev/null; }
# _finish_stall_grace_secs — FINISH_STALL_MIN in seconds, or 0 when the leg is off (a pure unit
# conversion; callers gate on _finish_stall_enabled, not on a nonzero grace).
_finish_stall_grace_secs() {
  local _fg_m
  _fg_m="$(_finish_stall_min)" || { printf '0'; return 0; }
  printf '%s' $(( _fg_m * 60 ))
}

# _finish_stall_commits_ahead <worktree> <branch> — commits this branch carries that its OWN remote
# ref does NOT (origin/<branch>) — genuinely unpushed work. Deliberately NOT "ahead of base"
# (_wedge_commits_ahead): a clean, committed, base-ahead tree is exactly the case wedge exempts as
# "in flight", and this leg exists to catch precisely that when it sits unpushed/un-PR'd too long.
# When origin/<branch> does not exist (never pushed at all), every commit not on DEFAULT_BRANCH counts
# — there is nothing on origin to be ahead of. A git failure or a non-numeric result reads as 0.
_finish_stall_commits_ahead() {
  local _fca_wt="$1" _fca_branch="$2" _fca_n
  if git -C "$_fca_wt" rev-parse --verify -q "refs/remotes/origin/${_fca_branch}" >/dev/null 2>&1; then
    _fca_n="$(git -C "$_fca_wt" rev-list --count "origin/${_fca_branch}..HEAD" 2>/dev/null || printf 0)"
  else
    _fca_n="$(git -C "$_fca_wt" rev-list HEAD --count --not "$DEFAULT_BRANCH" 2>/dev/null || printf 0)"
  fi
  case "$_fca_n" in ''|*[!0-9]*) _fca_n=0 ;; esac
  printf '%s' "$_fca_n"
}

# _finish_stall_dirty <worktree> — 1 iff the tree has UNCOMMITTED TRACKED changes (staged or
# unstaged), else 0. Deliberately narrower than _wedge_dirty (git status --porcelain non-empty, which
# ALSO counts untracked files): capabilities.tsv, config.example, and this leg's own header comment
# all say "uncommitted TRACKED changes" — a spare/never-tasked builder with one stray untracked
# scratch file must never be nudged to "commit it, push, and open a PR" (PR #502 review). A herestring,
# not a pipe, into grep -v — no producer process, no EPIPE under set -o pipefail (HERD-297 doctrine).
_finish_stall_dirty() {
  local _fsd_out
  _fsd_out="$(git -C "$1" status --porcelain 2>/dev/null)"
  [ -n "$_fsd_out" ] || { printf 0; return 0; }
  grep -qv '^?? ' <<< "$_fsd_out" && printf 1 || printf 0
}

# _classify_finish_stall <agent-status> <has-pr> <has-work> <limit-parked> <state> <first-seen> <now>
# <grace> — the PURE verdict for a live, non-working, PR-less builder once FINISH_STALL_MIN is enabled.
# Echoes exactly one token:
#   NOT_STALLED  — an escape hatch holds (a PR; the agent is working; nothing pushable/uncommitted; or
#                  the account usage limit is parking it) ⇒ the caller clears any record
#   PENDING      — the signature holds but has not yet persisted past <grace> ⇒ hold
#   FIRST_STALL  — past grace, no re-task has fired yet for this anchor (<state> pending/empty) ⇒ the
#                  caller should attempt the ONE re-task
#   SECOND_STALL — past grace AGAIN after a successful re-task (<state> retasked) ⇒ escalate
#   ESCALATED    — already escalated (<state> escalated), OR <state> is anything else UNRECOGNIZED ⇒
#                  keep rendering the needs-you row, never re-fire an action. A corrupt/garbage state
#                  word fails toward INACTION, not toward "fresh, first crossing" (PR #502 review
#                  advisory #4): the ladder considers a nudge already spent whenever it cannot PROVE
#                  otherwise, mirroring the once-guard doctrine's "fail closed" default elsewhere.
# <has-pr>/<has-work>/<limit-parked> are "1"/"0"; a non-numeric elapsed comparison never crashes because
# <first-seen> empty is checked FIRST, short-circuiting the arithmetic.
_classify_finish_stall() {
  local astatus="$1" has_pr="${2:-0}" haswork="${3:-0}" limitp="${4:-0}" state="${5:-}" \
        first_seen="$6" now="${7:-0}" grace="${8:-0}"
  [ "$has_pr" = "1" ] && { printf 'NOT_STALLED'; return 0; }
  case "$astatus" in done|idle) : ;; *) printf 'NOT_STALLED'; return 0 ;; esac
  [ "$haswork" = "1" ] || { printf 'NOT_STALLED'; return 0; }
  [ "$limitp" = "1" ] && { printf 'NOT_STALLED'; return 0; }
  if [ -z "$first_seen" ] || [ "$(( now - first_seen ))" -lt "$grace" ]; then
    printf 'PENDING'; return 0
  fi
  case "$state" in
    retasked)    printf 'SECOND_STALL' ;;
    ''|pending)  printf 'FIRST_STALL' ;;
    *)           printf 'ESCALATED' ;;   # 'escalated', or any unrecognized/corrupt word
  esac
}

# ── shared-pool clock accessors (pysrc/herd/store.py finish_stall_*, HERD-392) ─────────────────────
# Multi-seat doctrine: the anchor + state word live in the shared pool, not a seat-local flat file, so
# two coordinator seats ticking the same PR-less worktree never free-run their own clocks. Every
# wrapper fails SOFT toward "never seen" — a missing python3/store degrades the leg to "always PENDING
# from this seat's point of view", which only ever DELAYS a flag, never fabricates one.

# _finish_stall_record <slug> — the shared-pool "<epoch>\t<state>" for <slug> on stdout (rc 0), or
# nothing (rc 1, or a store/python3 failure) when unseen.
_finish_stall_record() {
  local _fr_pyp; _fr_pyp="$(_main_health_fix_pysrc)"
  [ -n "$_fr_pyp" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$_fr_pyp" WORKTREES_DIR="${TREES:-}" \
    python3 -m herd.store --finish-stall-record "$1" 2>/dev/null
}

# _finish_stall_mark <slug> <epoch> — atomically anchor <slug>'s clock at <epoch> iff no record exists
# yet; echoes the WINNING "<epoch>\t<state>" (ours, or another seat's earlier record) either way, so
# every seat converges on the same clock. Falls back to "<epoch>\tpending" on a store/python3 failure
# (fail-soft: the clock simply restarts on THIS seat until the pool is reachable again).
_finish_stall_mark() {
  local _fm_pyp _fm_out
  _fm_pyp="$(_main_health_fix_pysrc)"
  if [ -n "$_fm_pyp" ] && command -v python3 >/dev/null 2>&1; then
    _fm_out="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$_fm_pyp" WORKTREES_DIR="${TREES:-}" \
      python3 -m herd.store --finish-stall-mark "$1" --epoch "$2" 2>/dev/null)"
    [ -n "$_fm_out" ] && { printf '%s' "$_fm_out"; return 0; }
  fi
  printf '%s\tpending' "$2"
}

# _finish_stall_state <slug> <state> — flip the record's state word, PRESERVING its anchor. Best-effort
# (a failure here only means the ⚠️/🔁 dedup re-evaluates next tick — never a crash, never a lost
# escalation: the classifier recomputes FIRST_STALL/SECOND_STALL fresh from the still-standing anchor).
_finish_stall_state() {
  local _fs_pyp; _fs_pyp="$(_main_health_fix_pysrc)"
  [ -n "$_fs_pyp" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$_fs_pyp" WORKTREES_DIR="${TREES:-}" \
    python3 -m herd.store --finish-stall-state "$1" --state "$2" >/dev/null 2>&1 || true
}

# _finish_stall_reset <slug> <epoch> <state> — unconditionally overwrite BOTH fields. Used exactly
# once, right after a successful re-task nudge, to start the SECOND-STALL clock from the OBSERVED wake
# transition rather than the original sighting ("the stall clock derives from observed transitions").
_finish_stall_reset() {
  local _fx_pyp; _fx_pyp="$(_main_health_fix_pysrc)"
  [ -n "$_fx_pyp" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$_fx_pyp" WORKTREES_DIR="${TREES:-}" \
    python3 -m herd.store --finish-stall-reset "$1" --epoch "$2" --state "$3" >/dev/null 2>&1 || true
}

# _finish_stall_clear <slug> — drop the shared-pool record (the slug escaped: a PR opened, the agent
# is working, or the signature otherwise cleared).
_finish_stall_clear() {
  local _fc_pyp; _fc_pyp="$(_main_health_fix_pysrc)"
  [ -n "$_fc_pyp" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$_fc_pyp" WORKTREES_DIR="${TREES:-}" \
    python3 -m herd.store --finish-stall-clear "$1" >/dev/null 2>&1 || true
}

# _finish_stall_note_escape <slug> — called from a tick branch where the STALL SIGNATURE itself does
# not apply this tick (the agent is working, or it is limit-parked) — NOT a call site that already
# knows the slug truly escaped (a PR opened; that path clears unconditionally via _finish_stall_clear
# directly, e.g. the DEAD branch). PRESERVES a 'retasked'/'escalated' record — it must survive the very
# working period the re-task nudge ITSELF causes (and any limit-park mid-task), or the classifier can
# never reach SECOND_STALL: a delivered nudge would be silently wiped the moment the agent starts
# working, and the very next stall would re-fire ANOTHER nudge forever instead of escalating (PR #502
# review — the "at most ONE re-task, then terminal escalation" rail is the whole point of this leg).
# An un-actioned 'pending' anchor (or no record at all) IS cleared, so a builder that goes back to
# work on its own (no re-task fired) — or resumes from an account-usage-limit park — serves a FRESH
# grace window rather than inheriting a stale, already-aging anchor.
_finish_stall_note_escape() {
  _finish_stall_enabled || return 0
  local _ne_rec _ne_state="" _ne_anchor=""
  _ne_rec="$(_finish_stall_record "$1")"
  [ -n "$_ne_rec" ] && IFS=$'\t' read -r _ne_anchor _ne_state <<< "$_ne_rec"
  case "$_ne_state" in
    retasked|escalated) : ;;
    *) _finish_stall_clear "$1" ;;
  esac
}

# _finish_stall_note_pr_opened <slug> — called from the SINGLE choke point in the tick loop the
# instant a PR is observed for <slug>, whichever downstream branch (mergeable, blocked, push-gate,
# …) ends up handling it. A PR existing is unconditionally a real escape — never merely a
# working/limit-park transient — so this is a FULL, unconditional clear (unlike
# _finish_stall_note_escape, which preserves retasked/escalated). Without this, a LATER slug reusing
# the same name (a fresh worktree/agent, no PR yet) would inherit a days-old 'escalated' anchor and
# render needs-you on tick ONE, skipping the PENDING/FIRST_STALL rungs entirely (PR #502 review
# advisory #2). Self-gates on the leg being enabled, so this stays a hard no-op when off.
_finish_stall_note_pr_opened() {
  _finish_stall_enabled && _finish_stall_clear "$1"
}

# _finish_stall_note_still_working <slug> <worktree> <branch> — called from the tick branch where the
# agent reads 'working' THIS tick (HERD-402). Unlike a limit-park (_finish_stall_note_escape, which
# deliberately serves a FRESH grace window on resume — downtime the builder could not act on should
# never count against it), a 'working' pane reading is NOT reliable evidence the builder actually
# escaped the stall.
#
# GROUNDED INCIDENT (2026-07-20, HERD-404 builder, ~45-min eligible window, zero finish_stall* events):
# a builder's OWN backgrounded healthcheck run — exactly the step AGENTS.md requires before every PR —
# makes the pane read 'working' for stretches while the git tree, the actual signature this leg cares
# about, never changes. The OLD unconditional clear() here (the same code _finish_stall_note_escape
# still runs for the limit-park caller) wiped the anchor on every such blip, so the clock never
# accrued past a few seconds and FINISH_STALL_MIN was never reached — outcome indistinguishable from
# a genuine self-recovery, which is exactly what made the incident hard to diagnose after the fact.
#
# Keys the decision on the SAME git signature _reconcile_finish_stall itself uses (uncommitted tracked
# changes, or commits ahead of origin) instead of the pane status alone: unresolved ⇒ PRESERVE the
# anchor through the blip (the clock keeps accruing from the ORIGINAL first-seen, exactly as if the
# pane had stayed done/idle the whole time); resolved ⇒ the builder genuinely finished (everything
# committed and pushed with still no PR — a real PR clears unconditionally via
# _finish_stall_note_pr_opened before this is ever reached), so a merely-'pending' record is forgiven
# exactly like note-escape. PRESERVES 'retasked'/'escalated' unconditionally, same as note-escape — the
# ladder is bounded to two rungs and is never re-examined once actioned, whatever the tree looks like.
_finish_stall_note_still_working() {
  _finish_stall_enabled || return 0
  local _nw_slug="$1" _nw_wt="$2" _nw_branch="$3" _nw_rec _nw_state="" _nw_anchor=""
  _nw_rec="$(_finish_stall_record "$_nw_slug")"
  [ -n "$_nw_rec" ] || return 0
  IFS=$'\t' read -r _nw_anchor _nw_state <<< "$_nw_rec"
  case "$_nw_state" in
    retasked|escalated) return 0 ;;
  esac
  if [ "$(_finish_stall_commits_ahead "$_nw_wt" "$_nw_branch")" -gt 0 ] \
     || [ "$(_finish_stall_dirty "$_nw_wt")" = "1" ]; then
    return 0   # the signature still holds — a busy pane this tick is not proof of escape
  fi
  _finish_stall_clear "$_nw_slug"
}

# _finish_stall_scan_summary <eligible> <retasked> <escalated> — the throttled per-scan journal
# heartbeat (HERD-402), exactly the shape adopt_scan got in HERD-388: journals exactly ONE
# finish_stall_scan event per call, result ∈ {empty, eligible, retasked, escalated} chosen by priority
# (escalated > retasked > eligible > empty) with count = the tally in that bucket — so a silently-dead
# leg (zero of everything, every scan) is visible in the journal the very next scan, not just in
# retrospect, and a genuine fire (retasked/escalated) is provable without grepping for the granular
# finish_stall_detected/wake/escalated events individually. The caller tallies this tick's
# _reconcile_finish_stall verdicts (PENDING → eligible, FIRST_STALL → retasked, SECOND_STALL/ESCALATED
# → escalated) and throttles the CALL to the ~60s scan cadence; this function itself does no throttling
# and no gating — it is a pure "given these counts, journal the summary" step, callable in isolation.
_finish_stall_scan_summary() {
  local _fss_eligible="${1:-0}" _fss_retasked="${2:-0}" _fss_escalated="${3:-0}"
  if [ "$_fss_escalated" -gt 0 ]; then
    journal_append finish_stall_scan result escalated count "$_fss_escalated"
  elif [ "$_fss_retasked" -gt 0 ]; then
    journal_append finish_stall_scan result retasked count "$_fss_retasked"
  elif [ "$_fss_eligible" -gt 0 ]; then
    journal_append finish_stall_scan result eligible count "$_fss_eligible"
  else
    journal_append finish_stall_scan result empty count 0
  fi
}

# _finish_stall_wake_prompt <slug> — the finish-line nudge: explicit steps, not just "you stopped".
_finish_stall_wake_prompt() {
  printf 'Your worktree for %s has unfinished work (uncommitted changes or unpushed commits) and no open PR, and your agent has stopped.\nValidate your work, run the healthcheck, then commit it (include the Refs line from your task spec), push, and open a NON-DRAFT PR with `gh pr create` (no --draft).\nDo not merge the PR and do not edit BACKLOG.md.' "$1"
}

# _finish_stall_retask <slug> — deliver the ONE re-task nudge through the SAME driver seam / verified-
# wake discipline the refix bounce uses (herd_driver_send_text, then poll agent_status). Journals
# finish_stall_wake / finish_stall_wake_result exactly like a refix wake. Echoes exactly one token
# (mirrors _maybe_autowake_wedged_builder's verdict style): DRYRUN | NO_PANE | NO_WAKE | WOKE.
# NEVER runs the real nudge under DRYRUN — checked FIRST, before any pane lookup, exactly like
# _maybe_autowake_wedged_builder (PR #502 review: this is the ONE seam in this leg that mutates a
# LIVE builder — types into its pane and can cause it to actually push/open a PR — so it is the one
# seam the watcher's stated dry-run contract ("does everything EXCEPT ... never spawns the
# reviewer/resolver or writes their state files") requires gating; detection/journal/notify bookkeeping
# is unaffected, matching wedge's own precedent).
_finish_stall_retask() {
  local _ft_slug="$1" _ft_pane _ft_before _ft_after _ft_woke=0
  if [ -n "${DRYRUN:-}" ]; then
    printf '🐑 (dry-run) would re-task stalled builder %s\n' "$_ft_slug" >&2
    printf 'DRYRUN'; return 0
  fi
  _ft_pane="$(_find_builder_pane_id_any "$_ft_slug")"
  if [ -z "$_ft_pane" ]; then
    journal_append finish_stall_wake_result slug "$_ft_slug" woke 0 reason "no agent pane to deliver the nudge to"
    printf 'NO_PANE'; return 0
  fi
  _ft_before="$(_agent_status "$_ft_slug")"
  journal_append finish_stall_wake slug "$_ft_slug" agent_status_before "${_ft_before:-unknown}"
  herd_driver_send_text "$_ft_pane" "$(_finish_stall_wake_prompt "$_ft_slug")"
  _wait_agent_working "$_ft_slug" "${HERD_REFIX_WAIT_TIMEOUT:-15}" && _ft_woke=1
  _ft_after="$(_agent_status "$_ft_slug")"
  journal_append finish_stall_wake_result slug "$_ft_slug" agent_status_before "${_ft_before:-unknown}" \
    agent_status_after "${_ft_after:-unknown}" woke "$_ft_woke"
  if [ "$_ft_woke" = "1" ]; then printf 'WOKE'; else printf 'NO_WAKE'; fi
}

# _finish_stall_action_once <slug> <anchor> — atomic, shared-pool "AT MOST ONCE" guard for the
# FIRST_STALL/SECOND_STALL action itself (PR #502 review advisory #3): the anchor is already atomic
# across seats, but two seats can both classify the SAME (slug, anchor) as FIRST_STALL in the same
# window and both call _finish_stall_retask — a benign duplicate pane nudge, but it breaks the stated
# "AT MOST ONCE" guarantee. Keyed by <slug>::<anchor> so a FRESH anchor (a new stall incident) always
# gets a fresh guard. True iff THIS call is the first across the whole pool to win this exact
# (slug, anchor, phase); fails OPEN (proceeds as the actor) when the store/python3 is unavailable —
# the safe direction here is "this leg already fails toward inaction elsewhere" is NOT available for a
# missing python3, so a duplicate nudge in that narrow failure mode is preferred over the leg going
# silently inert; the shared-pool anchor's OWN fail-soft (never fabricates a flag) is what actually
# protects against a false positive.
_finish_stall_action_once() {
  local _fao_pyp _fao_key="finish_stall_action::$1::$2"
  _fao_pyp="$(_main_health_fix_pysrc)"
  [ -n "$_fao_pyp" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$_fao_pyp" WORKTREES_DIR="${TREES:-}" \
    python3 -m herd.store --once "$_fao_key" >/dev/null 2>&1
  [ $? -ne 3 ]
}

# _row_finish_stall <slug-cell> <age> [retasked] — the console row for the finish-line watchdog
# (HERD-392). Calm 🔁 the instant the ONE re-task nudge lands (the herd's move again — an operator
# whose builder is working again must not be told to go push it by hand). RED ⚠️ needs-you the moment
# that nudge fails to land OR the builder stalls a SECOND time after it: the herd will not clear this
# on its own. Never renders 'idle' or 'awaiting task' — this builder was tasked and produced real work.
_row_finish_stall() {
  local _sl="$1" _age="$2" _retasked="${3:-}"
  if [ -n "$_retasked" ]; then
    printf '    %s🔁%s %s%s%s %sunfinished work · re-task sent · %s%s' \
      "$C_CYAN" "$C_RESET" "$C_BOLD" "$_sl" "$C_RESET" "$C_CYAN" "$_age" "$C_RESET"
  else
    printf '    %s⚠️%s  %s%s%s %sneeds-you · stalled with unfinished work (no PR) · push + open the PR by hand · %s%s' \
      "$C_RED" "$C_RESET" "$C_BOLD" "$_sl" "$C_RESET" "$C_RED" "$_age" "$C_RESET"
  fi
}

# _reconcile_finish_stall <slug> <worktree> <agent-status> <branch> — drive the ledger + re-task +
# escalation for ONE PR-less, non-working builder, and echo the verdict (OFF | NOT_STALLED | PENDING |
# FIRST_STALL | SECOND_STALL | ESCALATED). Called from the tick's no-PR/non-working branch, alongside
# _reconcile_wedged_builder — has_pr is 0 by construction (the caller only reaches this on a PR-less
# slug, and only when PRS_LOOKUP_OK=1), and a limit-parked agent is routed to _handle_limit_blocked
# BEFORE this is ever reached, so "not currently limit-parked" already holds structurally; the explicit
# _detect_limit_hit probe below is belt-and-suspenders against a future caller that reaches this
# differently.
_reconcile_finish_stall() {
  local _rfs_slug="$1" _rfs_wt="$2" _rfs_astatus="$3" _rfs_branch="$4"
  _finish_stall_enabled || { printf 'OFF'; return 0; }
  local _rfs_now _rfs_grace _rfs_rec _rfs_first="" _rfs_state="" _rfs_commits=0 _rfs_dirty=0 \
        _rfs_haswork=0 _rfs_limit=0 _rfs_verdict _rfs_mark_out _rfs_mark_epoch _rfs_mark_state
  _rfs_now="$(_now)"
  _rfs_grace="$(_finish_stall_grace_secs)"
  case "$_rfs_astatus" in
    done|idle)
      _rfs_commits="$(_finish_stall_commits_ahead "$_rfs_wt" "$_rfs_branch")"
      _rfs_dirty="$(_finish_stall_dirty "$_rfs_wt")"
      if [ "$_rfs_commits" -gt 0 ] || [ "$_rfs_dirty" = "1" ]; then
        _rfs_haswork=1
        _detect_limit_hit "$_rfs_slug" "$_rfs_wt" >/dev/null 2>&1 && _rfs_limit=1
      fi
      ;;
  esac
  _rfs_rec="$(_finish_stall_record "$_rfs_slug")"
  if [ -n "$_rfs_rec" ]; then
    IFS=$'\t' read -r _rfs_first _rfs_state <<< "$_rfs_rec"
  fi
  _rfs_verdict="$(_classify_finish_stall "$_rfs_astatus" 0 "$_rfs_haswork" "$_rfs_limit" \
    "$_rfs_state" "$_rfs_first" "$_rfs_now" "$_rfs_grace")"
  case "$_rfs_verdict" in
    NOT_STALLED)
      [ -n "$_rfs_first" ] && _finish_stall_clear "$_rfs_slug" ;;
    PENDING)
      if [ -z "$_rfs_first" ]; then
        # HERD-402: journal the anchor write itself (first-seen), not just the eventual FIRST_STALL —
        # so the timeline is reconstructable even for a slug that never crosses the grace window (e.g.
        # it escapes mid-way). Journal ONLY when THIS call actually won the shared-pool race: a losing
        # seat's mark echoes back another seat's already-anchored epoch, and journaling that here would
        # fabricate a second first-seen event for an anchor this seat did not create.
        _rfs_mark_out="$(_finish_stall_mark "$_rfs_slug" "$_rfs_now")"
        IFS=$'\t' read -r _rfs_mark_epoch _rfs_mark_state <<< "$_rfs_mark_out"
        [ "$_rfs_mark_epoch" = "$_rfs_now" ] && \
          journal_append finish_stall_anchor slug "$_rfs_slug" first_seen "$_rfs_now"
      fi ;;
    FIRST_STALL)
      journal_append finish_stall_detected slug "$_rfs_slug" first_seen "${_rfs_first:-$_rfs_now}" \
        commits "$_rfs_commits" dirty "$_rfs_dirty"
      # DRYRUN is checked BEFORE the once-guard, never after: the guard marks the action SPENT, and a
      # dry run must never spend it — an operator who explores with AGENT_WATCH_DRYRUN=1 and then
      # disables it must still get the real nudge on the next tick, not find it silently pre-consumed
      # by the observation run. _finish_stall_retask itself re-checks DRYRUN first and never touches a
      # pane; this call exists only so its stderr "(dry-run) would re-task" line still fires.
      if [ -n "${DRYRUN:-}" ]; then
        _finish_stall_retask "$_rfs_slug" >/dev/null
      elif _finish_stall_action_once "$_rfs_slug" "${_rfs_first:-$_rfs_now}"; then
        # "AT MOST ONCE" across every seat (PR #502 review advisory #3): the anchor is atomic, but the
        # ACTION was not — two seats classifying the SAME (slug, anchor) as FIRST_STALL in the same
        # window could otherwise both deliver a nudge. Only the winner acts; a loser does nothing this
        # tick (the winner's outcome lands in the shared record for everyone on the next tick).
        case "$(_finish_stall_retask "$_rfs_slug")" in
          WOKE)
            _finish_stall_reset "$_rfs_slug" "$_rfs_now" retasked
            herd_driver_notify "🔁 stalled builder re-tasked: ${_rfs_slug}" \
              "${_rfs_slug}: unfinished work with no PR — finish-line nudge delivered, agent is working again" default ;;
          *)
            _finish_stall_state "$_rfs_slug" escalated
            journal_append finish_stall_escalated slug "$_rfs_slug" reason "wake failed"
            herd_driver_notify "⚠️ builder stalled before opening a PR: ${_rfs_slug}" \
              "${_rfs_slug}: work exists (uncommitted or unpushed) but the agent stopped and the auto re-task did not land — push + open the PR by hand" default ;;
        esac
      fi ;;
    SECOND_STALL)
      if _finish_stall_action_once "$_rfs_slug" "escalate:${_rfs_first:-$_rfs_now}"; then
        _finish_stall_state "$_rfs_slug" escalated
        journal_append finish_stall_escalated slug "$_rfs_slug" reason "stalled again after re-task"
        herd_driver_notify "⚠️ builder stalled again before opening a PR: ${_rfs_slug}" \
          "${_rfs_slug}: re-tasked once already but stopped again with work still unshipped — push + open the PR by hand" default
      fi ;;
    ESCALATED) : ;;   # already surfaced (or an unrecognized state); keep rendering, never re-fire
  esac
  printf '%s' "$_rfs_verdict"
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
# _health_inflight_file <key> — the slot-holder marker for a health run. <key> is <pr>-<sha> for the
# async per-PR gate, main-<sha> for the async main-health tick, or a bare token for a hand-planted
# probe holder. Globbed as .health-inflight-* by the slot accounting + corpse sweep (both families).
_health_inflight_file() { printf '%s' "$TREES/.health-inflight-$1"; }
# _health_dispatch_file <key> — the ASYNC suite's result, written by the backgrounded health worker as
# its LAST act (atomic temp+mv) and collected on a later tick — the health analogue of the reviewer's
# .review-result file. Keyed to match its inflight marker so collect/sweep stay in lock-step.
_health_dispatch_file() { printf '%s' "$TREES/.health-dispatch-$1"; }
# _health_log_file <key> — the LIVE, TAILABLE full-output log a health worker streams its suite into, so
# an operator can `tail -f` a running suite instead of staring at a black box (HERD-185 observability).
# Kept after collection (rotated, newest 5) as post-hoc forensics. Keyed like the marker/dispatch files.
_health_log_file() { printf '%s' "$TREES/.health-log-$1"; }

# _rotate_health_logs — keep only the 5 newest .health-log-* files (mirrors how review logs are capped),
# so an operator always has the last handful of suites to read without the dir growing unbounded.
_rotate_health_logs() {
  local _rl_f _rl_n=0
  for _rl_f in $(ls -t "$TREES"/.health-log-* 2>/dev/null); do
    _rl_n=$((_rl_n + 1))
    [ "$_rl_n" -gt 5 ] && rm -f "$_rl_f" 2>/dev/null || true
  done
}

# _health_first_notok <log> — the FIRST 'not ok' TAP line from a suite log, whitespace-collapsed. This is
# the HONEST failure label (HERD-173: the old --oneline tail often quoted a passing 'ok NN' summary line
# instead of the failing test). A bats stream may INDENT its TAP lines when the suite is nested, so the
# match tolerates leading whitespace. Empty when the log has no TAP 'not ok' (a non-bats failure).
_health_first_notok() {
  [ -f "$1" ] || return 0
  grep -m1 -E '^[[:space:]]*not ok( |$)' "$1" 2>/dev/null | tr '\t' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# ── tab-leak-guard exemption (HERD-228) ─────────────────────────────────────────────────────────────
# The healthcheck's tab-leak-guard trips when the suite leaks an orphan herdr tab into the LIVE
# workspace: transient control-room churn (issue #78), never a code bug. Three seams therefore EXEMPT
# it — the candidate gate never sha-caches it (so the next tick re-runs and it self-heals), never
# bounces a builder, and the main-health collector routes it to an infra_event instead of MAIN RED.
#
# That exemption used to be a bare `grep -q tab-leak-guard <log>` over the WHOLE suite log, which is
# wrong in the one case that matters: tests/herd.bats contains tests NAMED "hermetic tab-leak-guard …",
# so their PASSING TAP lines ("ok 29 hermetic tab-leak-guard engine-whitelist test passes") carry the
# literal. EVERY reproduced bats red therefore read as the leak-guard transient: the red row quoted a
# passing test, the verdict was never cached, and the PR re-dispatched a ~9-minute suite every tick with
# no cap and no bounce (PR #333 looped 40+ minutes while "not ok 41 …" sat in the log). On main the same
# bug meant a genuine bats red could not paint MAIN RED at all.
#
# The exemption now matches only the guard's OWN failure line, which it prints ANCHORED at column 0:
#     TAB-LEAK-GUARD: the test suite left an orphan tab/pane in the live workspace   (full mode)
#     tab-leak-guard: suite leaked an orphan tab into the live workspace — 3 -> 4    (--oneline)
# optionally behind healthcheck.sh's own "❌ code error — " oneline prefix. A TAP result line ("ok …",
# "not ok …") can never satisfy that anchor, and the guard's non-failing notes ("tab-leak-guard: clean",
# "… skipped") are excluded explicitly. On top of that, a TAP "not ok" ANYWHERE in the log OUTRANKS the
# exemption outright: a suite that reports a failing test has a code error to answer for, whatever else
# the log happens to say. One helper decides this for all three seams (HERD-222 builds on it too).
_HLG_PREFIX_RE='^[[:space:]]*(❌[[:space:]]*)?(code error[[:space:]]*—[[:space:]]*)?'
_HLG_LINE_RE="${_HLG_PREFIX_RE}tab-leak-guard[[:space:]]*:"
_HLG_NOTE_RE="${_HLG_PREFIX_RE}tab-leak-guard[[:space:]]*:[[:space:]]*(clean|skipped)"

# _health_is_leak_guard_detail <line> — true iff ONE line is the guard's failure line. The gate seams
# carry only the collected <detail> string (never the log), so they classify with this.
_health_is_leak_guard_detail() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$1" | grep -qiE "$_HLG_LINE_RE" 2>/dev/null || return 1  # pipe-ok: single short scalar (one line), far under a pipe buffer
  printf '%s\n' "$1" | grep -qiE "$_HLG_NOTE_RE" 2>/dev/null && return 1  # pipe-ok: single short scalar (one line), far under a pipe buffer
  return 0
}

# _health_leak_guard_line <log> — the guard's failure line from a suite log, or EMPTY when this log is
# not a genuine trip (no such line, or the suite reported a TAP failure that outranks it). Fail-soft:
# a missing log is not a trip.
_health_leak_guard_line() {
  [ -f "$1" ] || return 0
  [ -n "$(_health_first_notok "$1")" ] && return 0
  grep -iE "$_HLG_LINE_RE" "$1" 2>/dev/null | grep -viE "$_HLG_NOTE_RE" 2>/dev/null \
    | sed -n '1p' | tr '\t' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# _health_leak_guard_red <log> — true iff <log> is a genuine tab-leak-guard trip.
_health_leak_guard_red() { [ -n "$(_health_leak_guard_line "$1")" ]; }

# BOUNDED INFRA RE-DISPATCH (HERD-228). An exempted red is never cached, so the gate re-runs the suite
# for that same (pr,sha) every tick — that re-run IS the self-heal. Bound it: after this many
# consecutive infra re-dispatches the "transient" plainly is not transient, so cache the red under an
# ESCALATION tag, which both stops the loop and surfaces a needs-you row instead of bouncing a builder
# for infra. Inline constant on purpose — no new config key.
_HEALTH_INFRA_REDISPATCH_MAX=3
_HEALTH_INFRA_CAP_TAG='infra re-dispatch cap reached'

# _health_infra_file <pr#> <sha> — the per-(pr,sha) infra re-dispatch counter (swept with the sha-cache).
_health_infra_file() { printf '%s' "$TREES/.health-infra-$1-$2"; }

# _health_infra_bump <pr#> <sha> — count one infra re-dispatch for this (pr,sha); prints the new total.
_health_infra_bump() {
  local _hib_f _hib_n
  _hib_f="$(_health_infra_file "$1" "$2")"
  _hib_n="$(cat "$_hib_f" 2>/dev/null || printf 0)"
  case "$_hib_n" in ''|*[!0-9]*) _hib_n=0 ;; esac
  _hib_n=$((_hib_n + 1))
  printf '%s\n' "$_hib_n" > "$_hib_f" 2>/dev/null || true
  printf '%s' "$_hib_n"
}

# ── HERD-281: suite-duration vs inflight-timeout headroom tracking ──────────────────────────────────
# Track the max observed completed-suite wall-clock duration so the headroom check can compare it
# against HEALTH_INFLIGHT_TIMEOUT and surface an advisory before the timeout fires prematurely.

# _health_duration_file — path to the rolling max-observed suite duration record.
_health_duration_file() { printf '%s' "$TREES/.health-observed-duration"; }

# _health_duration_record <seconds> — update the max observed suite duration (best-effort, fail-soft).
# Called at collection time so the recorded value is the actual suite wall-clock time.
_health_duration_record() {
  local _hdr_secs="${1:-}" _hdr_prev _hdr_f
  case "$_hdr_secs" in ''|*[!0-9]*) return 0 ;; esac
  _hdr_f="$(_health_duration_file)"
  _hdr_prev="$(cat "$_hdr_f" 2>/dev/null || printf 0)"
  case "$_hdr_prev" in ''|*[!0-9]*) _hdr_prev=0 ;; esac
  [ "$_hdr_secs" -gt "$_hdr_prev" ] && printf '%s\n' "$_hdr_secs" > "$_hdr_f" 2>/dev/null || true
}

# _health_duration_observed — the max observed completed suite duration in seconds, or 0 if none.
_health_duration_observed() {
  local _hdo_v; _hdo_v="$(cat "$(_health_duration_file)" 2>/dev/null || printf 0)"
  case "$_hdo_v" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$_hdo_v" ;; esac
}

# _health_timeout_headroom — the configured HEALTH_TIMEOUT_HEADROOM margin in seconds, or 0 (off).
# Non-numeric or unset → 0 so a typo can never activate the check (fail safe = off).
_health_timeout_headroom() {
  local _hth_v="${HEALTH_TIMEOUT_HEADROOM:-0}"
  case "$_hth_v" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$_hth_v" ;; esac
}

# _health_headroom_advisory_file — throttle-marker path for the headroom journal advisory.
_health_headroom_advisory_file() { printf '%s' "$TREES/.health-headroom-advisory"; }

# _health_headroom_journal_once <key> <age> <timeout> <margin> — journal a headroom advisory at most
# once per 600 s (throttled). Fail-soft; never blocks the corpse sweep.
_health_headroom_journal_once() {
  local _hhj_f _hhj_now _hhj_last
  _hhj_f="$(_health_headroom_advisory_file)"
  _hhj_now="$(_now_epoch)"
  _hhj_last="$(cat "$_hhj_f" 2>/dev/null || printf 0)"
  case "$_hhj_last" in ''|*[!0-9]*) _hhj_last=0 ;; esac
  [ "$(( _hhj_now - _hhj_last ))" -lt 600 ] 2>/dev/null && return 0
  printf '%s\n' "$_hhj_now" > "$_hhj_f" 2>/dev/null || true
  journal_append health_timeout_headroom_advisory key "${1:-}" age "${2:-}" timeout "${3:-}" margin "${4:-}"
}

# build_health_headroom_note — the 'suite headroom' advisory console row (HERD-281). Fires when:
# (a) the max observed suite duration is within HEALTH_TIMEOUT_HEADROOM of HEALTH_INFLIGHT_TIMEOUT, or
# (b) a live suite is currently in the approach window (set by _sweep_gate_corpses this tick via
#     _HEALTH_HEADROOM_APPROACHING). Empty when HEALTH_TIMEOUT_HEADROOM=0 (default off) or the
# margin is not crossed — so the console is byte-identical to before when dormant.
build_health_headroom_note() {
  HEALTH_HEADROOM_NOTE=""
  local _bhn_margin; _bhn_margin="$(_health_timeout_headroom)"
  [ "$_bhn_margin" -gt 0 ] 2>/dev/null || return 0
  local _bhn_timeout="${HEALTH_INFLIGHT_TIMEOUT:-1800}"
  case "$_bhn_timeout" in ''|*[!0-9]*) _bhn_timeout=1800 ;; esac
  local _bhn_obs _bhn_headroom
  # Case A: observed max duration is close to the timeout (recorded from completed suites).
  _bhn_obs="$(_health_duration_observed)"
  if [ "$_bhn_obs" -gt 0 ] 2>/dev/null; then
    _bhn_headroom=$(( _bhn_timeout - _bhn_obs ))
    if [ "$_bhn_headroom" -lt "$_bhn_margin" ] 2>/dev/null; then
      HEALTH_HEADROOM_NOTE="    ${C_YELLOW}⚠️  suite headroom${C_RESET}: observed ${_bhn_obs}s · timeout ${_bhn_timeout}s · headroom ${_bhn_headroom}s < margin ${_bhn_margin}s — raise HEALTH_INFLIGHT_TIMEOUT${C_RESET}"$'\n'
      return 0
    fi
  fi
  # Case B: a live suite is approaching/past timeout this tick (set by corpse sweep).
  if [ -n "${_HEALTH_HEADROOM_APPROACHING:-}" ]; then
    HEALTH_HEADROOM_NOTE="    ${C_YELLOW}⚠️  suite headroom${C_RESET}: running ${_HEALTH_HEADROOM_APPROACHING}s · timeout ${_bhn_timeout}s · margin ${_bhn_margin}s — raise HEALTH_INFLIGHT_TIMEOUT${C_RESET}"$'\n'
  fi
}

# _health_fail_detail <log> — the ONE line that best names why this suite failed. Every caller used to
# fall back to `sed -n 1p` when the log carried no TAP 'not ok', which quotes healthcheck.sh's own
# CLASSIFIER BANNER ("❌ CODE ERROR") — true, but content-free: it names no test, no file, no reason
# (HERD-173: the last path #289 left quoting a non-'not ok' line). Resolution order:
#   1. the first TAP 'not ok' line — a bats/TAP suite names the failing test exactly;
#   2. else the first FAILURE-MARKED line among the surviving CANDIDATES below the banner;
#   3. else the first surviving candidate — the checker said something that is not a pass; quote it;
#   4. else the banner itself — better a bare classifier than an empty red row.
#
# "SURVIVING CANDIDATES" is the load-bearing part (review BLOCK, round 2). A non-TAP log — i.e. EVERY
# non-bats consumer project, which is the generic-engine case — interleaves passes and failures, and a
# GREEN line routinely contains a failure WORD:
#     PASS  src/error.test.js                     ← jest: a passing FILE named "error"
#       ✓ throws an error on bad input (3 ms)     ← jest: a passing TEST named "throws an error"
#     --- PASS: TestParse/returns an error        ← go:   a passing test named "returns an error"
# Token-matching without first excluding pass lines selects one of those. This string is quoted VERBATIM
# into the auto-refix re-task prompt ("Failing test: PASS src/error.test.js") and into the needs-you row,
# so it would send the builder to fix a GREEN test and burn a round of the shared, capped
# REFIX_MAX_ROUNDS budget — the exact class of lie this PR exists to remove, re-introduced one layer
# down. Pass-marked lines are therefore dropped from the candidate set FIRST: before the token match AND
# before the step-3 fallback, which would otherwise re-select that very same green line.
#
# The pre-diff behaviour (`sed -n 1p` → the "❌ CODE ERROR" banner) was uninformative but never WRONG.
# That is the floor: this function may return something uninformative, never something misleading.
# A pass marker may sit behind a short RUNNER PREFIX — `bats: ok 29 …`, `tests: ✓ widget` — because the
# project healthcheck relabels the streams it wraps. The anchor therefore tolerates ONE such prefix
# (a bare word + colon) so those lines are dropped from the candidate set too (HERD-228); it stays
# anchored, so prose like "look at the ok path" or "PASS is spelled out here" can never be mistaken for
# a pass marker and silently swallow a real failure line.
_HFD_PASS_RE='^[[:space:]]*([[:alnum:]_.-]+:[[:space:]]+)?(ok([[:space:]]|$)|✓|✔|--- PASS:|PASS([[:space:]]|:)|\[[[:space:]]*OK[[:space:]]*\]|SKIP)'
_HFD_ZERO_RE='(^|[^0-9])0 (errors?|failures?|failed)'
# Anchored failure MARKERS — a line that BEGINS with FAIL/✗/● is a failure whatever words follow. This
# is how a bare 'FAIL  src/widget.test.js' is caught without putting bare 'fail' in the token list
# (where it would also match 'failsafe').
_HFD_MARK_RE='^[[:space:]]*(--- FAIL:|FAIL(ED)?([[:space:]]|:)|✗|✘|●|❌|E[[:space:]])'
# … plus whole-word failure TOKENS anywhere in the line, for checkers that print prose.
_HFD_TOKEN_RE='(^|[^[:alnum:]_])(error|errors|failed|failure|failures|fatal|exception|traceback|panic|assert|assertion)([^[:alnum:]_]|$)'
_health_fail_detail() {
  [ -f "$1" ] || return 0
  local _hfd_d _hfd_cand
  _hfd_d="$(_health_first_notok "$1")"
  if [ -z "$_hfd_d" ]; then
    _hfd_cand="$(sed -n '2,$p' "$1" 2>/dev/null \
      | grep -v '^[[:space:]]*$' 2>/dev/null \
      | grep -viE "$_HFD_PASS_RE" 2>/dev/null \
      | grep -viE "$_HFD_ZERO_RE" 2>/dev/null)"
    if [ -n "$_hfd_cand" ]; then
      _hfd_d="$(printf '%s\n' "$_hfd_cand" | grep -m1 -iE "$_HFD_MARK_RE" 2>/dev/null)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
      [ -n "$_hfd_d" ] || _hfd_d="$(printf '%s\n' "$_hfd_cand" | grep -m1 -iE "$_HFD_TOKEN_RE" 2>/dev/null)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
      [ -n "$_hfd_d" ] || _hfd_d="$(printf '%s\n' "$_hfd_cand" | sed -n '1p')"
    fi
    _hfd_d="$(printf '%s' "$_hfd_d" | tr '\t' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')"
  fi
  [ -n "$_hfd_d" ] || _hfd_d="$(sed -n '1p' "$1" 2>/dev/null)"
  printf '%s' "$_hfd_d"
}

# _health_progress <log> — cheap live progress from a bats/TAP stream: "<done>/<plan>" parsed from the
# '1..N' plan line + the count of ok/not-ok result lines so far. Empty when the log has no TAP plan (the
# suite isn't TAP, or hasn't emitted its plan yet) — the running row then shows just elapsed time.
_health_progress() {
  [ -f "$1" ] || return 0
  local _hp_plan _hp_done
  _hp_plan="$(grep -m1 -oE '^1\.\.[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+$')"
  [ -n "$_hp_plan" ] || return 0
  _hp_done="$(grep -cE '^(ok|not ok) ' "$1" 2>/dev/null || printf 0)"
  [ "${_hp_done:-0}" -gt 0 ] 2>/dev/null && printf 'test %s/%s' "$_hp_done" "$_hp_plan"
}

# _health_inflight_note <log> — the liveness clause the running row appends after the elapsed time
# (HERD-313), so an in-flight suite is never a bare stopwatch the operator can't read. Three-valued,
# in precedence order, so an EMPTY-LOG CRASH is distinguishable from a SLOW SUITE within a single tick:
#   • TAP stream     → the live 'test X/Y' from _health_progress (the suite is emitting a plan).
#   • bytes, no plan → '<n> lines' — a non-TAP suite that IS producing output (alive, just slow).
#   • empty / absent → 'no output yet' — the worker has written NOTHING; if this persists next to a
#                      climbing elapsed time it is a crashed/wedged suite, not a slow one.
# Pure read of the tailable log the health worker (bash or the Python engine) streams into; no state
# mutation, so the render half can call it every tick.
_health_inflight_note() {
  local _hin_log="$1" _hin_prog
  _hin_prog="$(_health_progress "$_hin_log")"
  if [ -n "$_hin_prog" ]; then printf '%s' "$_hin_prog"; return 0; fi
  if [ -s "$_hin_log" ]; then
    printf '%s lines' "$(grep -c '' "$_hin_log" 2>/dev/null || printf 0)"
  else
    printf 'no output yet'
  fi
}

# _health_running_row <slug-cell> <pn> <inflight-file> <log-file> — THE one in-flight health row string
# (HERD-313). Both the render half (the classification pass, so the row paints even when the Python
# engine owns the action pass and the bash gate step never runs) and the bash gate step below emit this
# EXACT line, so the row never flickers between the two renders in a single tick. Reads only the marker
# + log the engine writes; side-effect-free.
_health_running_row() {
  local _hrr_sl="$1" _hrr_pn="$2" _hrr_inf="$3" _hrr_log="$4"
  printf '%s' "    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${_hrr_sl}${C_RESET}${_hrr_pn} ${C_YELLOW}health-check · running $(_fmt_age "$(_marker_age "$_hrr_inf")") · $(_health_inflight_note "$_hrr_log")${C_RESET}"
}

# _health_pid_live <inflight-file> — true if the marker records a still-running holder (pid alive AND,
# via the recycling guard, still the SAME process). Shares the restart-safe substrate with the review side.
_health_pid_live() { _marker_live "$1"; }

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
# HERD-159: non-numeric HEALTH_CONCURRENCY falls back to 1 via _health_conc so a typo never breaks
# the comparison into a silent "never dispatch" stall.
_health_slot_free() {
  [ "$(_count_live_healthchecks)" -lt "$(_health_conc)" ]
}

# _health_acquire <pr#> — claim a slot by writing this process's live pid to the pr's marker.
_health_acquire() { printf '%s\n' "$$" > "$(_health_inflight_file "$1")"; }
# _health_release <pr#> — drop the pr's marker, freeing its slot.
_health_release() { rm -f "$(_health_inflight_file "$1")" 2>/dev/null || true; }

# _health_term_sleep — one short (~0.1s) grace tick between a health worker's SIGTERM and SIGKILL. A
# constant, not a config key: it is an upper bound on how long a doomed worker gets to unwind, never an
# operator preference. HERD_HEALTH_TERM_SLEEP is a test seam so a unit test can drive the loop with no
# real wall-clock. Fail-soft: an absent fractional `sleep` degrades to a whole second, never an error.
_health_term_sleep() {
  local s="${HERD_HEALTH_TERM_SLEEP:-0.1}"
  sleep "$s" 2>/dev/null || sleep 1 2>/dev/null || true
}

# _health_terminate_worker <inflight-marker> — THE ONE shared seam that STOPS a running health worker and
# its whole suite subtree before a slot is freed or a replacement is dispatched (HERD-283). Both the
# inflight-TIMEOUT re-dispatch (_sweep_gate_corpses) and the STALE-SHA discard (_discard_stale_health)
# call it — one implementation, never two divergent kills (multi-seat doctrine rule 2).
#
# WHY A GROUP KILL. The worker runs a full `bash healthcheck.sh` suite that forks many children. The old
# `kill <worker-pid>` reaped only the worker SUBSHELL, leaving the suite's children running while the
# marker was removed and a fresh suite dispatched — concurrent duplicate suites piled up on one worktree
# (the 2026-07-10 fork-bomb; the operator's HEALTH_INFLIGHT_TIMEOUT=3600 was a mitigation, this is the
# guard). The worker is dispatched into its OWN process group (see _bg_health_worker), so the RECORDED
# pgid names exactly the suite subtree; SIGTERM → short grace → SIGKILL to that group reaps all of it,
# and only it.
#
# SAFETY — never sever the watcher. Signals ONLY the group RECORDED in the marker, never a pid discovered
# by pattern-match. Guards, any of which vetoes the group signal:
#   • the recorded pid is dead/recycled (_marker_live false) — nothing to signal;
#   • the recorded pid is THIS process ($$) — a legacy in-process synchronous holder is the watcher;
#   • the recorded pid is the watcher's own recorded identity (watcher_canonical_pid, from the shared
#     watcher-exempt.sh check) — never signal the watcher, even if a marker names it;
#   • the recorded PGID is not the worker's OWN group (pgid != pid) or equals the watcher's own group —
#     the isolation did not take, so a group-kill could hit the watcher; fall back to a single-pid kill.
# Returns 0 when the worker (and its group) is gone, 1 when a live member survived — the caller then
# KEEPS the marker so the slot stays held and the next tick retries, never re-dispatching over a live
# suite.
_health_terminate_worker() {
  local f="${1:-}" pid pgid selfpg canon use_group=0 i
  [ -e "$f" ] || return 0
  pid="$(_marker_pid "$f")"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  # Already gone (dead or its pid recycled to another process) — the recycling guard prevents signaling
  # a reused pid. Nothing to terminate; the caller may free the slot.
  _marker_live "$f" || return 0
  # Never the watcher itself.
  [ "$pid" = "$$" ] && return 1
  # Never the watcher's recorded identity (the shared watcher-exempt.sh check). A health worker is a
  # fork, never the canonical watcher, so this refuses only a genuine watcher pid.
  if declare -f watcher_canonical_pid >/dev/null 2>&1; then
    canon="$(watcher_canonical_pid 2>/dev/null || true)"
    if [ -n "$canon" ] && [ "$pid" = "$canon" ]; then
      journal_append infra_event component agent-watch reason health_term_refused key "${f##*/.health-inflight-}" pid "$pid"
      return 1
    fi
  fi
  # Group-kill ONLY when the worker leads its own group and that group is not the watcher's.
  pgid="$(_marker_pgid "$f")"; case "$pgid" in ''|*[!0-9]*) pgid="" ;; esac
  selfpg="$(_pid_pgid "$$")"
  if [ -n "$pgid" ] && [ "$pgid" = "$pid" ] && [ "$pgid" != "$selfpg" ]; then
    use_group=1
  fi
  # SIGTERM.
  if [ "$use_group" = 1 ]; then kill -TERM "-$pgid" 2>/dev/null || true
  else kill -TERM "$pid" 2>/dev/null || true; fi
  # Bounded grace (~0.6s worst case) so the tick is never stalled long; most suites die on TERM.
  for i in 1 2 3 4 5 6; do _marker_live "$f" || break; _health_term_sleep; done
  # SIGKILL any survivor, then a final short grace.
  if _marker_live "$f"; then
    if [ "$use_group" = 1 ]; then kill -KILL "-$pgid" 2>/dev/null || true
    else kill -KILL "$pid" 2>/dev/null || true; fi
    for i in 1 2 3; do _marker_live "$f" || break; _health_term_sleep; done
  fi
  # Verify gone: the leader must be dead AND (for a group kill) no group member may survive.
  _marker_live "$f" && return 1
  if [ "$use_group" = 1 ] && kill -0 "-$pgid" 2>/dev/null; then return 1; fi
  return 0
}

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
#   .health-infra-<pr>-<sha>   — how many times an EXEMPTED infra red (tab-leak-guard) has re-dispatched
#                                the suite for this sha; at _HEALTH_INFRA_REDISPATCH_MAX the red is
#                                cached under the escalation tag instead of looping (HERD-228).
# A new commit (new sha) invalidates the cache and forces a fresh full run (see _discard_stale_health,
# mirroring _discard_stale_reviews). A non-terminal/in-flight state is NEVER cached.
_health_result_file() { printf '%s' "$TREES/.health-result-$1-$2"; }

# record_health_result <pr#> <sha> <verdict> [detail] — cache a TERMINAL health verdict for this exact
# commit sha. No-op when sha is empty (cache disabled; e.g. head sha not yet known).
record_health_result() {
  [ -n "$2" ] || return 0
  printf '%s\t%s\n' "$3" "${4:-}" > "$(_health_result_file "$1" "$2")"
  # RESET-ON-PROGRESS (HERD-229): the suite went green (CLEAN, or FLAKY = passed on retry) — the health
  # rail's red resolved, so refund its refix budget. CODEERROR is the failure that must keep spending.
  case "$3" in CLEAN|FLAKY) refix_rail_reset "$1" health "$2" ;; esac
}

# _discard_stale_health <pr#> <currentSha> — a cached result for this PR keyed to ANY OTHER sha is
# stale (the PR has a newer head; that verdict must never be reused). Discard it so the new commit
# re-runs the full suite. Mirrors _discard_stale_reviews.
#
# The inflight marker is now keyed by pr+sha too (HERD-185), so a still-RUNNING worker for a superseded
# sha is stale as well — its suite tests a commit nobody will merge, and it holds the single health slot
# against the current sha. TERMINATE it (and its whole process group) through the ONE shared seam the
# timeout re-dispatch path uses (_health_terminate_worker, HERD-283), then free its slot; a worker that
# refuses to die is left for the next tick's corpse sweep. A marker for the CURRENT sha is never touched.
_discard_stale_health() {
  local pr="$1" sha="$2" f base msha key
  for f in "$TREES/.health-inflight-$pr-"*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"; msha="${base##*-}"
    [ "$msha" = "$sha" ] && continue
    # A finished stale-sha suite's dispatch result is worthless (wrong commit); reap marker + result.
    key="${base#.health-inflight-}"
    if _health_terminate_worker "$f"; then
      rm -f "$f" "$(_health_dispatch_file "$key")" 2>/dev/null || true
      journal_append infra_event component agent-watch reason health_stale_sha_term pr "$pr" sha "$msha"
    fi
  done
  for f in "$TREES/.health-result-$pr-"* "$TREES/.health-infra-$pr-"*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "${base##*-}" = "$sha" ] && continue
    rm -f "$f" 2>/dev/null || true
  done
  # Sweep this PR's stuck-bounce markers for any OTHER sha (review note #5): they are keyed by
  # (kind,pr,sha) and were otherwise never reaped, growing one file per bounce forever. A marker for the
  # CURRENT sha must survive — it is the durable proof that nobody is on this red.
  for f in "$TREES/.agent-watch-refix-stuck-"*"-$pr-"*; do
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

# _health_worker <worktree-dir> <dispatch-file> <log-file> — the ASYNC healthcheck suite, run in the
# BACKGROUND by _healthcheck_gate so the watcher tick NEVER blocks on a ~9-min suite (the root cause of
# tonight's global freezes: a synchronous suite inside the tick starved verdict collection / merges for
# every other PR). Two observability wins over the old black-box gate (HERD-185):
#   • it runs the suite in FULL (non --oneline) mode STREAMING to <log-file>, so an operator can
#     `tail -f` a live run and read the whole TAP stream after — no more staring at a frozen row;
#   • the CODE-ERROR detail is the FIRST 'not ok' TAP line from that log (HERD-173: the old --oneline
#     tail routinely quoted a passing 'ok NN' summary line, mislabelling which test actually failed).
# It keeps the SAME retry-before-red (a rc-1 code error is re-run ONCE, solo) and writes its TERMINAL
# verdict atomically (temp+mv, mirroring herd-review.sh) as one line "<verdict>\t<detail>":
#   CLEAN\t{clean|dataenv}      — passed (clean, or a tolerated data/env ⚠️ first line)
#   FLAKY\t<fail-identity>      — first run code-errored but the solo retry PASSED (HERD-76 offender)
#   CODEERROR\t<first-not-ok>   — code error reproduced (or the tab-leak-guard line, preserved so the
#                                 collector's transient-exemption still fires); drives the red row.
# The collector (_healthcheck_gate) records the ledger + journal + sha-cache from this line — keeping
# every ledger write in the tick process, ordered. Runs in a subshell fork so all helpers are in scope.
_health_worker() {
  local _hw_dir="$1" _hw_out="$2" _hw_log="$3" _hw_rc _hw_first _hw_notok _hw_id _hw_rc2 _hw_notok2 _hw_detail _hw_line
  # BASELINE-AWARE GATE (HERD-190): hand healthcheck.sh the base checkout ($MAIN, the default-branch
  # tree) + a sha-keyed cache dir so a candidate whose failures ALL already fail on the base is
  # surfaced as an inherited ⚠️ (rc 0 → CLEAN) instead of a merge-blocking code error — no fix-PR
  # deadlocks on an inherited base failure. Scoped to THIS candidate gate only; the main-health worker
  # deliberately does NOT set it (comparing main against itself would mask a genuine MAIN RED).
  # FULL run streamed to the live log (redirect = tailable as it runs); rc drives the verdict class.
  HERD_BASELINE_DIR="$MAIN" HERD_BASELINE_CACHE="$TREES" \
    bash "$HERD_HEALTHCHECK_BIN" "$_hw_dir" > "$_hw_log" 2>&1; _hw_rc=$?
  _hw_first="$(sed -n '1p' "$_hw_log" 2>/dev/null)"
  if [ "$_hw_rc" -eq 0 ]; then
    case "$_hw_first" in "⚠️"*) _hw_line=$'CLEAN\tdataenv' ;; *) _hw_line=$'CLEAN\tclean' ;; esac
  else
    _hw_notok="$(_health_fail_detail "$_hw_log")"; [ -n "$_hw_notok" ] || _hw_notok="$_hw_first"
    _hw_id="$(_health_fail_identity "$_hw_notok")"
    # RETRY-BEFORE-RED (solo): re-run once into a sibling log, keeping the LATEST run as the live log.
    # Baseline-aware on the retry too (HERD-190), so an inherited-only failure still collapses to rc 0.
    HERD_BASELINE_DIR="$MAIN" HERD_BASELINE_CACHE="$TREES" \
      bash "$HERD_HEALTHCHECK_BIN" "$_hw_dir" > "$_hw_log.retry" 2>&1; _hw_rc2=$?
    if [ "$_hw_rc2" -eq 0 ]; then
      rm -f "$_hw_log.retry" 2>/dev/null || true                 # transient — the passing retry is the truth
      _hw_line="FLAKY"$'\t'"$_hw_id"
    else
      mv "$_hw_log.retry" "$_hw_log" 2>/dev/null || true         # the reproduced failure is the live log
      _hw_detail="$(_health_leak_guard_line "$_hw_log")"
      if [ -z "$_hw_detail" ]; then
        _hw_notok2="$(_health_fail_detail "$_hw_log")"
        _hw_detail="$_hw_notok2"
      fi
      # keep the detail single-line + bounded so the "<verdict>\t<detail>" contract can't be broken.
      _hw_detail="$(printf '%s' "$_hw_detail" | tr '\t\n' '  ')"; _hw_detail="${_hw_detail:0:200}"
      _hw_line="CODEERROR"$'\t'"$_hw_detail"
    fi
  fi
  printf '%s\n' "$_hw_line" > "$_hw_out.tmp.$$" 2>/dev/null && mv "$_hw_out.tmp.$$" "$_hw_out" 2>/dev/null || true
}

# _healthcheck_gate <pr#> <slug> <worktree-dir> <display-idx> [headSha] — the serialized, ASYNC,
# retry-before-red healthcheck as a NON-BLOCKING dispatch/collect state machine (unified with the review
# gate — see _review_gate_step). Sets DISPLAY[<idx>] and the global _HC_RESULT to one token; returns 0
# always. The suite runs in a BACKGROUND worker (_health_worker) holding a slot via its inflight marker;
# the tick never blocks on it. Tokens:
#   RUNNING   — a suite was just dispatched, or one is in flight for this pr+sha; re-evaluate next tick
#   QUEUED    — no slot free (HEALTH_CONCURRENCY reached); re-evaluate next tick, do NOT merge
#   CLEAN     — a finished suite verdict was collected: passed (clean or tolerated data/env)
#   FLAKY     — collected: first run was a CODE ERROR but the solo retry PASSED; proceed as passing
#   CODEERROR — collected: CODE ERROR reproduced on the solo retry; red "needs you", do NOT merge
# When [headSha] is given the TERMINAL verdict is sha-cached (a later tick with the SAME sha REUSES it
# with no suite; a new commit invalidates it). The marker/dispatch files are keyed by pr+sha so the
# collect + corpse sweep stay in lock-step; an empty sha disables the cache (a re-dispatch each call).
_healthcheck_gate() {
  local _hg_pr="$1" _hg_slug="$2" _hg_dir="$3" _hg_idx="$4" _hg_sha="${5:-}"
  local _hg_sl _hg_pn _hg_key _hg_inflight _hg_disp _hg_log
  _hg_sl="$(_slug_cell "$_hg_slug")"
  _hg_pn=" ${C_DIM}#${_hg_pr}${C_RESET} ·"
  _hg_key="${_hg_pr}-${_hg_sha}"
  _hg_inflight="$(_health_inflight_file "$_hg_key")"
  _hg_disp="$(_health_dispatch_file "$_hg_key")"
  _hg_log="$(_health_log_file "$_hg_key")"

  # SHA-CACHE CHECK (before any dispatch/collect): an UNCHANGED commit cannot yield a different verdict.
  # Purge any result for a stale sha (a new commit → full re-run), then REUSE a terminal result cached
  # for this exact head sha — no slot, no suite; just a journal 'cache hit'. Mirrors the review gate.
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
          # HERD-173: re-evaluate the ROW every tick (an agent may have started fixing since), and drive
          # the HEALTHCHECK_AUTOFIX bounce from here too — the collector only sees the verdict once, but a
          # deferred bounce (limit-parked builder) must still fire on a later tick from the cached red.
          _handle_health_codeerror "$_hg_pr" "$_hg_slug" "$_hg_sha" "$_hg_idx" "$_hg_dir" "$_hg_cd"
          _HC_RESULT="CODEERROR"
          _journal_cache_hit "$_hg_pr" "$_hg_slug" "$_hg_sha" CODEERROR "$_hg_cd"
          return 0 ;;
      esac
    fi
  fi

  # COLLECT: a finished background worker left its terminal verdict — record it exactly as the old
  # synchronous gate did (ledger + journal + sha-cache), then free the slot. This is the at-least-once
  # collect: the dispatch file + inflight marker are removed AFTER the durable records, so a crash
  # mid-collect simply re-reads the still-present dispatch file next tick.
  if [ -f "$_hg_disp" ]; then
    local _hg_v _hg_d
    IFS=$'\t' read -r _hg_v _hg_d < "$_hg_disp"
    case "$_hg_v" in
      CLEAN)
        case "$_hg_d" in dataenv) record_healthcheck "$_hg_pr" "$_hg_slug" 1 "dataenv" ;; *) record_healthcheck "$_hg_pr" "$_hg_slug" 1 "clean" ;; esac
        record_health_result "$_hg_pr" "$_hg_sha" "CLEAN"
        _HC_RESULT="CLEAN"
        journal_append healthcheck_outcome pr "$_hg_pr" slug "$_hg_slug" outcome CLEAN ;;
      FLAKY)
        # Reconstruct the two-attempt ledger + journal the old synchronous gate wrote: attempt 1
        # code-error CARRYING the HERD-76 offender the worker captured in <detail>, then attempt 2
        # flaky-pass. The worker's <detail> is already the _health_fail_identity of the failing attempt.
        record_healthcheck "$_hg_pr" "$_hg_slug" 1 "code-error" "$_hg_d"
        record_healthcheck "$_hg_pr" "$_hg_slug" 2 "flaky-pass"
        record_health_result "$_hg_pr" "$_hg_sha" "FLAKY"
        DISPLAY[_hg_idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_YELLOW}flaky · infra (passed on retry)${C_RESET}"
        _HC_RESULT="FLAKY"
        # HERD-76: a passing retry must not erase which test flaked — carry the offender onto FLAKY.
        if [ -n "$_hg_d" ]; then
          journal_append healthcheck_outcome pr "$_hg_pr" slug "$_hg_slug" outcome FLAKY failed "$_hg_d"
        else
          journal_append healthcheck_outcome pr "$_hg_pr" slug "$_hg_slug" outcome FLAKY
        fi ;;
      CODEERROR)
        # Reconstruct the two-attempt code-error ledger + journal (the offender extracted from the
        # reproduced oneline lands on BOTH the initial healthcheck_attempted and the healthcheck_retried).
        local _hg_id; _hg_id="$(_health_fail_identity "$_hg_d")"
        record_healthcheck "$_hg_pr" "$_hg_slug" 1 "code-error" "$_hg_id"
        record_healthcheck "$_hg_pr" "$_hg_slug" 2 "code-error" "$_hg_id"
        # A tab-leak-guard CODE ERROR is INFRA/TRANSIENT (issue #78 part 2), never a code bug: it must
        # NEVER be sha-cached, else the cache replays the transient every tick and FREEZES red. Skip the
        # cache so the next tick re-dispatches fresh + self-heals; a genuine code error caches + stays red.
        # The skip is BOUNDED (HERD-228): count the re-dispatches for this (pr,sha) and, once the cap is
        # reached, cache the red under the escalation tag so the loop ends in a needs-you row rather than
        # re-running a ~9-minute suite forever. An empty sha means the cache (and so the cap) is disabled.
        if _health_is_leak_guard_detail "$_hg_d"; then
          local _hg_n=0
          [ -n "$_hg_sha" ] && _hg_n="$(_health_infra_bump "$_hg_pr" "$_hg_sha")"
          if [ "${_hg_n:-0}" -ge "$_HEALTH_INFRA_REDISPATCH_MAX" ]; then
            _hg_d="${_HEALTH_INFRA_CAP_TAG} (${_hg_n}× infra) · ${_hg_d}"
            record_health_result "$_hg_pr" "$_hg_sha" "CODEERROR" "$_hg_d"
            journal_append infra_event component agent-watch reason health_infra_cap pr "$_hg_pr" sha "$_hg_sha" count "$_hg_n"
          fi
        else
          record_health_result "$_hg_pr" "$_hg_sha" "CODEERROR" "$_hg_d"
        fi
        _handle_health_codeerror "$_hg_pr" "$_hg_slug" "$_hg_sha" "$_hg_idx" "$_hg_dir" "$_hg_d"
        _HC_RESULT="CODEERROR"
        journal_append healthcheck_outcome pr "$_hg_pr" slug "$_hg_slug" outcome CODEERROR detail "$_hg_d" ;;
      *)
        # Unparseable / truncated worker output → an infra death, NOT a verdict. Never cache; free the
        # slot and re-dispatch on the next tick (bounded implicitly by the sha-cache once it succeeds).
        _HC_RESULT="RUNNING"
        journal_append infra_event component agent-watch reason health_bad_result key "$_hg_key" ;;
    esac
    # HERD-281: record observed suite wall-clock duration for headroom tracking.
    local _hg_elapsed; _hg_elapsed="$(_marker_age "$_hg_inflight")"
    case "$_hg_elapsed" in ''|-1|*[!0-9]*) : ;; *) _health_duration_record "$_hg_elapsed" ;; esac
    rm -f "$_hg_disp" "$_hg_inflight" 2>/dev/null || true
    lifecycle_retire health-worker "$_hg_key" collected     # HERD-193 RETIRE: result consumed
    return 0
  fi

  # IN FLIGHT: a worker is still running for this pr+sha. Show WHICH stage + how long (console honesty —
  # never a bare 'health-check' that a review-stage wait could be confused with). A dead marker with no
  # dispatch result is a severed worker → drop it (the corpse sweep also reaps it) and fall through to
  # re-dispatch below.
  if [ -f "$_hg_inflight" ]; then
    if _health_pid_live "$_hg_inflight"; then
      # Elapsed + a liveness clause (live TAP progress, a byte-count, or 'no output yet') via the ONE
      # shared row the render half also paints — 'running 3m · test 41/168' / '… · no output yet'.
      DISPLAY[_hg_idx]="$(_health_running_row "$_hg_sl" "$_hg_pn" "$_hg_inflight" "$_hg_log")"
      _HC_RESULT="RUNNING"
      return 0
    fi
    rm -f "$_hg_inflight" 2>/dev/null || true
    lifecycle_retire health-worker "$_hg_key" severed        # HERD-193 RETIRE: worker died verdictless
    journal_append infra_event component agent-watch reason health_died key "$_hg_key"
  fi

  # SELF-RESTART QUIESCE (HERD-251): draining toward an in-place re-exec — start no new suite. Reached
  # only after the collect + in-flight branches above, so a running suite still finishes and its verdict
  # is still cached. QUEUED holds the candidate (no merge) exactly as a busy slot does; the restarted
  # watcher dispatches it on new code. Byte-inert with the lever off.
  if _self_restart_hold_dispatch; then
    DISPLAY[_hg_idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_YELLOW}health-check · held (watcher restarting on new engine code)${C_RESET}"
    _HC_RESULT="QUEUED"
    return 0
  fi

  # DISPATCH: needs a free slot (HEALTH_CONCURRENCY). No slot → queue this PR, honestly naming how many
  # suites are ahead of it. Never runs a suite that would overlap another (shared git object store).
  if ! _health_slot_free; then
    DISPLAY[_hg_idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_YELLOW}health-check · queued ($(_count_live_healthchecks) ahead)${C_RESET}"
    _HC_RESULT="QUEUED"
    return 0
  fi

  # LEAK-GUARD SNAPSHOT POINT (HERD-54): the suite's tab-leak-guard snapshots the workspace BEFORE it
  # runs, so proactively close any stale resolve·<slug> tab first. Fail-soft; a live resolver is spared.
  _sweep_stale_resolve_tabs

  # Background the suite, STREAMING its full output to the live log (tailable) for this pr+sha. Write the
  # restart-safe inflight marker with the WORKER'S pid (so a corpse sweep can detect it dying) + start-time
  # + dispatch ts SYNCHRONOUSLY here, so a same-tick sibling sees the slot taken and QUEUEs (never a second
  # overlapping suite). Mirrors _dispatch_review.
  # Note (HERD-245/283): review workers use _bg_new_session (setsid) because they are an external argv;
  # health workers are an in-process bash function, so _bg_health_worker isolates them the equivalent way
  # (monitor mode → own process group) instead. That own group is what lets the inflight-timeout /
  # stale-sha kill reap the WHOLE suite subtree as one group (HERD-283), and it also keeps a reload's
  # `kill -- -<watcher-pgid>` from ever reaching a live suite. Live health pids stay exempted from
  # _list_project_watchers (HERD-217/245) so reload never SIGTERMs them as "stray watchers" either.
  _bg_health_worker _health_worker "$_hg_dir" "$_hg_disp" "$_hg_log"
  local _hg_wpid="$_BG_HEALTH_PID"
  _marker_write "$_hg_inflight" "$_hg_wpid" "$_BG_HEALTH_PGID"
  _rotate_health_logs
  DISPLAY[_hg_idx]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${_hg_sl}${C_RESET}${_hg_pn} ${C_YELLOW}health-check · running (0s)${C_RESET}"
  _HC_RESULT="RUNNING"
  # healthcheck_started (not just a later 'outcome'): the record shows runs IN FLIGHT — so a suite that
  # never finishes (killed, restart) is visible in the journal, and log_path points at the tailable log.
  journal_append healthcheck_started pr "$_hg_pr" slug "$_hg_slug" sha "$_hg_sha" pid "$_hg_wpid" log_path "$_hg_log"
  # HERD-193 SPAWN: owner=agent-watch, liveness=worker pid, deadline=HEALTH_INFLIGHT_TIMEOUT (the very
  # timeout the corpse sweep already enforces), retire=the collect/severed paths above. Lever-gated.
  lifecycle_spawn health-worker "$_hg_key" "pid:$_hg_wpid" agent-watch
  return 0
}

# ── Every-tick gate corpse sweep (HERD-185) ──────────────────────────────────────────────────────
# The AUTHORITATIVE reaper for BOTH inflight-marker families, run at the TOP of every tick BEFORE the
# action pass. For each marker it frees the slot the SAME tick when the worker is:
#   • a CORPSE — pid dead or recycled (see _marker_live) with NO result/dispatch file waiting: journal
#     an infra_event <family>_died, drop the marker (+ registry / dispatch scratch), and — for reviews —
#     count the existing retry budget + feed the INFRA breaker, exactly as the gate step's dead-marker
#     branch does (so a severed reviewer's accounting is unchanged; whichever runs first wins, once);
#   • PAST ITS RESTART-SAFE DEADLINE — pid still live but the marker's age exceeds the family timeout:
#     SIGTERM the run, journal <family>_timeout, reap, and (reviews) count the retry + breaker. The age
#     comes from the marker's OWN dispatch ts, so a watcher that RESTARTED mid-run still times it out —
#     no in-process timer to orphan. A holder pid equal to THIS process ($$) is never TERMed (a legacy
#     in-process synchronous holder is us; killing it would kill the watcher).
# Crucially independent of the candidate list: a marker whose PR merged/closed/changed-sha — the exact
# corpse that held a slot for ~1h on 2026-07-08 — is swept too, because nothing else would ever revisit
# it. Idempotent, dry-run-inert, and byte-quiet when there are no corpses.
# ── Corpse-sweep MUTUAL EXCLUSION (HERD-191) ─────────────────────────────────────────────────────
# _sweep_gate_corpses used to have exactly ONE caller (the watcher tick). `herd sweep`'s leg 3 makes it
# a SECOND, CONCURRENT caller: cmd_sweep runs legs 1-4 while the old watcher is still alive (leg 5
# restarts it only afterwards). The function has no claim on a marker — it reads it, does a driver RPC
# (_retire_reviewer_pane), and only THEN rm -f's — so two processes can both win the same corpse and
# both run record_review_retry (a bare `>>` append) and _breaker_record_infra (a read-modify-write
# counter). That silently double-charges a PR's review-retry budget (it exhausts its retries and stops
# being reviewed) and can trip the global INFRA breaker early, while the RMW loses an increment.
#
# So the whole sweep runs under an atomic-mkdir mutex — the same primitive the watcher singleton lock
# uses. `mkdir` is atomic on every POSIX filesystem: exactly one process creates the directory. The
# loser SKIPS (returns 0) rather than blocking: the sweep is periodic and idempotent, so whoever holds
# the lock is already freeing those slots, and the loser's next tick will find them gone. A lock dir
# older than the staleness window is a crashed holder's leftover and is reclaimed.
_GATE_CORPSE_MTX="${TREES}/.gate-corpse-sweep.lock.d"

# _gate_corpse_claim — success iff we now hold the sweep mutex (caller MUST _gate_corpse_release).
_gate_corpse_claim() {
  if mkdir "$_GATE_CORPSE_MTX" 2>/dev/null; then return 0; fi
  # Held. Reclaim only a STALE lock (no mtime inside the last minute ⇒ the holder died mid-sweep).
  if [ -z "$(find "$_GATE_CORPSE_MTX" -prune -mmin -1 2>/dev/null)" ]; then
    rmdir "$_GATE_CORPSE_MTX" 2>/dev/null || true
    mkdir "$_GATE_CORPSE_MTX" 2>/dev/null && return 0
  fi
  return 1
}
_gate_corpse_release() { rmdir "$_GATE_CORPSE_MTX" 2>/dev/null || true; }

_sweep_gate_corpses() {
  [ -z "${DRYRUN:-}" ] || return 0
  # Serialize against a concurrent `herd sweep` / watcher tick. A skipped sweep is harmless (periodic
  # + idempotent); a CONCURRENT one corrupts the retry ledger and the infra breaker.
  _gate_corpse_claim || return 0
  trap '_gate_corpse_release' RETURN
  local f base rest pr sha age pid _sw_margin _sw_timeout
  # ── review family: .review-inflight-<pr>-<sha> ──
  for f in "$TREES"/.review-inflight-*; do
    [ -e "$f" ] || continue
    base="${f##*/}"; rest="${base#.review-inflight-}"
    pr="${rest%-*}"; sha="${rest##*-}"
    [ -n "$pr" ] && [ -n "$sha" ] || continue
    # A finished reviewer's verdict is waiting — leave it for the gate step to collect + record.
    [ -f "$(_review_result_file "$pr" "$sha")" ] && continue
    if _marker_live "$f"; then
      age="$(_marker_age "$f")"
      case "$age" in ''|-1|*[!0-9]*) continue ;; esac         # no deadline recorded → let it run
      [ "$age" -lt "${REVIEW_INFLIGHT_TIMEOUT:-1800}" ] 2>/dev/null && continue
      pid="$(_marker_pid "$f")"
      [ "$pid" = "$$" ] && continue                            # never TERM the watcher itself
      [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
      _retire_reviewer_pane "$pr" "$sha" timeout-term
      rm -f "$f" "$(_review_registry_file "$pr" "$sha")" 2>/dev/null || true
      journal_append infra_event component agent-watch reason review_timeout pr "$pr" sha "$sha" age "$age"
      record_review_retry "$pr" "$sha"; _breaker_record_infra
    else
      _retire_reviewer_pane "$pr" "$sha" corpse-swept
      rm -f "$f" "$(_review_registry_file "$pr" "$sha")" 2>/dev/null || true
      journal_append infra_event component agent-watch reason review_died pr "$pr" sha "$sha"
      record_review_retry "$pr" "$sha"; _breaker_record_infra
    fi
  done
  # ── health family: .health-inflight-<key>  (key = <pr>-<sha> | main-<sha> | a planted probe token) ──
  for f in "$TREES"/.health-inflight-*; do
    [ -e "$f" ] || continue
    base="${f##*/}"; rest="${base#.health-inflight-}"
    [ -n "$rest" ] || continue
    # A finished suite's dispatch result is waiting — leave it for the collector.
    [ -f "$(_health_dispatch_file "$rest")" ] && continue
    if _marker_live "$f"; then
      age="$(_marker_age "$f")"
      case "$age" in ''|-1|*[!0-9]*) continue ;; esac
      # HERD-281: headroom check — before the kill, honour HEALTH_TIMEOUT_HEADROOM.
      _sw_margin="$(_health_timeout_headroom)"
      _sw_timeout="${HEALTH_INFLIGHT_TIMEOUT:-1800}"
      case "$_sw_timeout" in ''|*[!0-9]*) _sw_timeout=1800 ;; esac
      if [ "$_sw_margin" -gt 0 ] 2>/dev/null; then
        # Approaching or within the grace window: surface advisory.
        if [ "$age" -ge "$(( _sw_timeout - _sw_margin ))" ] 2>/dev/null; then
          _HEALTH_HEADROOM_APPROACHING="$age"
          _health_headroom_journal_once "$rest" "$age" "$_sw_timeout" "$_sw_margin"
        fi
        # Within [0, timeout + margin): defer the kill — do NOT tear down within the margin.
        [ "$age" -lt "$(( _sw_timeout + _sw_margin ))" ] 2>/dev/null && continue
        # age >= timeout + margin: fall through to kill.
      else
        # HEALTH_TIMEOUT_HEADROOM=0 (default): byte-identical — kill at HEALTH_INFLIGHT_TIMEOUT.
        [ "$age" -lt "$_sw_timeout" ] 2>/dev/null && continue
      fi
      pid="$(_marker_pid "$f")"
      [ "$pid" = "$$" ] && continue
      # HERD-283: terminate the worker's WHOLE process group (TERM → grace → KILL) through the shared
      # seam and only free the slot once it is verifiably gone — a bare `kill <pid>` reaped just the
      # worker subshell, orphaning the suite subtree so the next tick re-dispatched a DUPLICATE over it.
      # A worker that will not die keeps its marker (slot stays held); the next sweep escalates to KILL.
      if _health_terminate_worker "$f"; then
        rm -f "$f" "$(_health_dispatch_file "$rest")" 2>/dev/null || true
        journal_append infra_event component agent-watch reason health_timeout key "$rest" age "$age"
      fi
    else
      rm -f "$f" "$(_health_dispatch_file "$rest")" 2>/dev/null || true
      journal_append infra_event component agent-watch reason health_died key "$rest"
    fi
  done
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
    _wvf_author="$(_gh_timeout view_filter_user api user -q .login 2>/dev/null || true)"
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
# WATCHER_SCOPE is a declared config key (templates/capabilities.tsv, governance-classified); read
# here with an inline default so a config without the key behaves exactly as the solo default.
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
  else _WATCHER_OWNER_CACHE="$(_gh_timeout watcher_owner_user api user -q .login 2>/dev/null || true)"; fi
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

# _watcher_tick_fields / _prs_fetch_tick — moved to work-units/git-pr.sh (HERD-398, Phase 3 work-unit
# extraction).

# ── Branch-ref repair (HERD-226) ─────────────────────────────────────────────────────────────────
# A worktree that the sha-fallback join matched (its HEAD is exactly one open PR's head commit) is on
# the WRONG branch name — a resolver or builder left it on a scratch ref. Point the PR's own branch at
# that commit and check it out, so the next tick's cheap branch-name join matches on its own.
#
# The repair is deliberately timid. It runs ONLY when the repair is provably lossless:
#   • the worktree is CLEAN (no dirty or untracked files — nothing to strand);
#   • HEAD is exactly the PR's head commit (never move a diverged branch onto a stranger's work);
#   • the PR's local branch is absent, or its tip is an ANCESTOR of HEAD (a fast-forward, never a
#     clobber of a diverged ref) — and `checkout -B` itself refuses a branch checked out elsewhere.
# Any other shape (dirty tree, diverged ref, ambiguous match, DRYRUN) is a SKIP: the sha-join match is
# already recorded, so gating proceeds untouched and the console renders the truthful mismatch row.
# FAIL-SOFT by construction: every git call's failure is a SKIP, never a gate block.
# Echoes REPAIRED (branch now matches the PR) or SKIP. Journals `branch_repaired` on success only —
# the row carries the un-repaired case, so a stuck worktree never spams the journal every 4 s tick.
_repair_branch_ref() {
  local _d="$1" _b="$2" _pb="$3" _sha="$4" _pr="$5" _slug="$6"
  _repair_branch_ref_try "$@" || { printf 'SKIP'; return 0; }
  journal_append branch_repaired pr "$_pr" slug "$_slug" sha "$_sha" \
    from_branch "$_b" to_branch "$_pb" 2>/dev/null || true
  printf 'REPAIRED'
}

# _repair_branch_ref_try — the guarded repair itself. Success (rc 0) iff the ref was moved and checked
# out; every refusal and every git failure is a plain nonzero rc, so the caller's SKIP is the default.
_repair_branch_ref_try() {
  local _d="$1" _b="$2" _pb="$3" _sha="$4" _head _tip
  [ -z "${DRYRUN:-}" ] || return 1
  [ -n "$_d" ] && [ -n "$_pb" ] && [ -n "$_sha" ] || return 1
  [ "$_b" != "$_pb" ] || return 1                                      # already on the PR's branch
  _head="$(git -C "$_d" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$_head" ] && [ "$_head" = "$_sha" ] || return 1                # diverged from the PR head
  [ -z "$(git -C "$_d" status --porcelain 2>/dev/null)" ] || return 1  # dirty tree — never touch it
  _tip="$(git -C "$_d" rev-parse --verify --quiet "refs/heads/$_pb" 2>/dev/null || true)"
  if [ -n "$_tip" ] && ! git -C "$_d" merge-base --is-ancestor "$_tip" "$_head" 2>/dev/null; then
    return 1                                                           # local PR branch diverged
  fi
  git -C "$_d" checkout -q -B "$_pb" "$_head" 2>/dev/null || return 1
}

# _branch_mismatch_text <worktree-branch> <pr-head-description> — the one sentence both the standalone
# mismatch row and the appended gate-row note render. Naming the two refs is the whole point: an
# operator seeing it knows the PR was found (gates ARE running) and knows exactly which ref to fix.
_branch_mismatch_text() {
  printf 'branch mismatch — worktree on %s, PR head is %s' "$1" "$2"
}

# _row_branch_mismatch <slug-cell> <text> — the console row for a worktree whose PR could not be
# joined unambiguously (two open PRs share its HEAD commit). It is NOT an 'awaiting task' spare: a
# spare has no PR, this one has too many. Yours to disambiguate.
_row_branch_mismatch() {
  printf '    %s⚠️%s  %s%s%s %s%s%s' \
    "$C_YELLOW" "$C_RESET" "$C_BOLD" "$1" "$C_RESET" "$C_YELLOW" "$2" "$C_RESET"
}

# ── Feature-worktree discovery (HERD-182, HERD-226) ──────────────────────────────────────────────
# _discover_feature_worktrees — parse `git worktree list --porcelain` (in $WT) into one \x1f-joined
# record per LEGITIMATE builder worktree, matching each to its open PR (by branch, then by HEAD commit)
# and its agent (by slug). Reads PRS_JSON, AGENTS_JSON, WT, MAIN, TREES from the environment; emits
# records on stdout, one per line, in the exact field order the tick loop consumes:
#   dir slug branch pr mergeable mergeStateStatus agent_status headRefOid author matchkind matchdetail
# The last two are HERD-226's join provenance — matchkind ∈ {branch, sha, ambig, ""} and, for the two
# non-trivial kinds, the detail the console names (the PR's own branch, or which PRs collide).
#
# SHA-RESILIENT JOIN (HERD-226). GROUNDED INCIDENT: a resolver exited leaving its worktree on the
# scratch branch `pr328`; the branch-name-only join found no PR, so PR #328 was INVISIBLE to the
# watcher for ~20 min — no gates ran and the console claimed 'awaiting task'. So after the branch-name
# join, still-unmatched worktrees get a FALLBACK pass: when a worktree's HEAD commit equals exactly
# ONE still-unmatched open PR's headRefOid (already fetched this tick), that is the PR. The identity is
# a cryptographic one, and every downstream gate/verdict/ledger is (pr,sha)-keyed — not branch-keyed —
# so a sha-joined row gates exactly like a branch-joined one.
#
# AMBIGUITY IS NEVER RESOLVED, only reported: two open PRs on one commit (or two worktrees on one PR's
# commit) yields matchkind=ambig with NO pr fields — the tick paints the truthful mismatch row instead
# of guessing, and never the 'awaiting task' claim that hid #328.
#
# DISCOVERY SCOPE (HERD-182): a worktree is a builder candidate ONLY when BOTH hold —
#   1. it lives UNDER $WORKTREES_DIR ($TREES) — every builder worktree is $WORKTREES_DIR/<slug>,
#      including this watcher's own SELF_WT; and
#   2. it is on a BRANCH, not a detached HEAD — builders are always spawned onto a branch, so a
#      detached-HEAD worktree is never a builder.
# A worktree failing EITHER test (a stray `git worktree add --detach HEAD /tmp/hk-base`, or any
# worktree outside the herd tree) is a PHANTOM: it has no agent and no PR, so the old parse rendered
# it as a spurious 💀 dead-builder row and confused the operator (GROUNDED: a detached HEAD at
# /tmp/hk-base surfaced as a phantom dead-builder row). Filtering it here keeps it out of the roster
# entirely, so it never reaches the dead-builder reconciliation. FAIL-SOFT: when $TREES is empty
# (unconfigured), the scope test is skipped and behavior falls back to today's (MAIN-excluded, plus
# the detached filter which alone catches the grounded incident). Paths are realpath-normalized before
# comparison so a symlinked $WORKTREES_DIR still matches git's canonicalized worktree paths — a
# legitimate builder row is NEVER dropped, and its emitted record is byte-identical to before.
_discover_feature_worktrees() {
  PRS_JSON="${PRS_JSON:-}" AGENTS_JSON="${AGENTS_JSON:-}" WT="${WT:-}" MAIN="${MAIN:-}" TREES="${TREES:-}" python3 -c '
import os, json
MAIN = os.environ.get("MAIN", "")
TREES = os.environ.get("TREES", "")
def _real(p):
    try: return os.path.realpath(p)
    except Exception: return p
main_real = _real(MAIN) if MAIN else ""
trees_real = _real(TREES) if TREES else ""
def _under_trees(p):
    # Fail-soft: no $WORKTREES_DIR configured → do not scope (detached filter still applies).
    if not trees_real: return True
    pr = _real(p)
    return pr == trees_real or pr.startswith(trees_real + os.sep)
try: prs = json.loads(os.environ.get("PRS_JSON") or "[]")
except Exception: prs = []
try: agents = (json.loads(os.environ.get("AGENTS_JSON") or "{}").get("result") or {}).get("agents") or []
except Exception: agents = []
pr_by_branch = {p.get("headRefName"): p for p in prs}
ag_status = {a.get("name"): a.get("agent_status") for a in agents if a.get("name")}
feats = []; wt = None; branch = None; head = None; detached = False
def _emit(wt, branch, head, detached):
    # A builder candidate is UNDER $WORKTREES_DIR, on a BRANCH (not detached), and not $MAIN.
    if not wt: return
    if MAIN and _real(wt) == main_real: return
    if detached or not branch: return
    if not _under_trees(wt): return
    feats.append((wt, branch, head or ""))
for line in (os.environ.get("WT") or "").splitlines():
    if line.startswith("worktree "): wt = line[9:]; branch = None; head = None; detached = False
    elif line.startswith("HEAD "): head = line[5:]
    elif line.startswith("branch "): branch = line[7:].replace("refs/heads/", "")
    elif line == "detached": detached = True
    elif line == "":
        _emit(wt, branch, head, detached); wt = None; branch = None; head = None; detached = False
_emit(wt, branch, head, detached)

# SHA-FALLBACK JOIN (HERD-226). A PR is claimable only when NO discovered worktree already sits on its
# head branch, and a worktree is a claimant only when the branch join left it PR-less: the cheap name
# join always wins, so a repo whose names all match takes this pass with nothing to do.
wt_branches = set(b for _, b, _ in feats)
free_by_oid = {}   # oid -> [pr, ...]   open PRs no worktree claimed by name
for p in prs:
    if p.get("headRefName") in wt_branches: continue
    oid = p.get("headRefOid")
    if oid: free_by_oid.setdefault(oid, []).append(p)
claim_by_oid = {}  # oid -> [wt, ...]   worktrees the name join left unmatched
for w, b, h in feats:
    if b in pr_by_branch or not h: continue
    claim_by_oid.setdefault(h, []).append(w)

fallback = {}      # wt -> (pr_or_None, matchkind, detail)
for w, b, h in feats:
    if b in pr_by_branch or not h: continue
    cands = free_by_oid.get(h) or []
    peers = claim_by_oid.get(h) or []
    if not cands: continue                                     # no PR at this commit — a real spare
    if len(cands) == 1 and len(peers) == 1:
        # Exactly one PR head at exactly one worktree HEAD: a cryptographic identity, not a guess.
        fallback[w] = (cands[0], "sha", cands[0].get("headRefName") or "")
    else:
        # Two PRs on one commit, or two worktrees on one PR head. Never guess which; say so.
        nums = ",".join("#%s" % p.get("number") for p in sorted(cands, key=lambda p: p.get("number") or 0))
        fallback[w] = (None, "ambig", "ambiguous (%s share this commit)" % nums)

for wt, branch, head in feats:
    slug = os.path.basename(wt)
    pr = pr_by_branch.get(branch or "", {})
    kind = "branch" if pr else ""
    detail = ""
    if not pr and wt in fallback:
        fb, kind, detail = fallback[wt]
        pr = fb or {}
    print("\x1f".join(str(x) for x in [
        wt, slug, branch or "", pr.get("number", ""),
        pr.get("mergeable", ""), pr.get("mergeStateStatus", ""),
        ag_status.get(slug, ""), pr.get("headRefOid", ""),
        (pr.get("author") or {}).get("login", ""),
        kind, detail]))
'
}

# ── Control-room sweep (HERD-191) ────────────────────────────────────────────────────────────────
# sweep.sh composes the reapers defined ABOVE (_marker_live, _sweep_gate_corpses, _orphan_tab_ids,
# _sweep_orphan_tabs, _sweep_stale_resolve_tabs, _reap_slug), so it must be sourced AFTER them. It in
# turn skips re-sourcing this file because those helpers are already in scope — no recursion.
# SWEEP_LIB=1 loads functions only; the CLI entry point (sweep_main) never runs from inside a watcher.
SWEEP_LIB=1
# shellcheck source=/dev/null
. "$HERE/sweep.sh"
unset SWEEP_LIB

# ── Retirement invariant (HERD-164) ──────────────────────────────────────────────────────────────
# retirement.sh reconciles "a merged/closed slug owns nothing" on EVERY tick, composing _reap_slug
# (above) with sweep.sh's dirt/unique-commit proof helpers — so it must be sourced after BOTH. It
# detects they are already in scope and does not re-source this file.
# shellcheck source=/dev/null
. "$HERE/retirement.sh"

# The trigger pass's cached counts. Recomputed on the ORPHAN-sweep cadence (not every 4 s tick): the
# scan costs one `ps -e` plus a filesystem walk, which has no business riding the repaint. Rendering
# reads the CACHE every tick, so the frame stays stable between scans instead of flickering.
_SWEEP_SCAN_INTERVAL=15                  # ~60 s (15 × 4 s sleep) — matches _ORPHAN_SWEEP_INTERVAL,
                                         # which is declared further down, next to the live loop
_SWEEP_SCAN_TICK=$_SWEEP_SCAN_INTERVAL   # primed so the FIRST tick scans, then every interval
_SWEEP_C_TABS=0; _SWEEP_C_MARKERS=0; _SWEEP_C_PROCS=0
# Epoch of the last cache refresh (0 = never scanned yet). Drives BOTH halves of the HERD-215 tally-
# honesty fix: the '(as of …)' staleness note build_sweep_note renders between scans, and the
# after-sweep immediate recompute (_sweep_tally_invalidated compares this against the sweep's stamp).
_SWEEP_LAST_SCAN=0
_SWEEP_TALLY_STAMP="$TREES/.sweep-tally-stamp"   # written by sweep_main / sweep_run_safe_legs on finish

# _sweep_tally_invalidated — success iff a sweep finished (stamped $_SWEEP_TALLY_STAMP) more recently
# than our last cache refresh. A MANUAL `herd sweep` runs in a SEPARATE process from this watcher, so
# it cannot poke our in-memory cache directly — it drops a timestamp file, and we poll it here. When it
# fires we recompute the tally THIS tick instead of waiting out the ~60 s scan cadence, so the
# housekeeping line clears the instant a manual sweep cleaned the room rather than crying wolf for up to
# a minute (HERD-215). Fail-soft: no stamp, or an unreadable/garbage stamp, reads as "not invalidated".
_sweep_tally_invalidated() {
  local _ti_ts
  [ -f "$_SWEEP_TALLY_STAMP" ] || return 1
  _ti_ts="$(cat "$_SWEEP_TALLY_STAMP" 2>/dev/null || true)"
  case "$_ti_ts" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_ti_ts" -gt "${_SWEEP_LAST_SCAN:-0}" ] 2>/dev/null
}

# _sweep_trigger_tick — the per-tick trigger. On the scan cadence (or immediately when a finished sweep
# invalidated the cache) it refreshes the cached counts, journals `sweep_advice` once per distinct
# condition-set, and (SWEEP_AUTO=auto) runs the SAFE legs. Byte-inert under SWEEP_AUTO=off.
_sweep_trigger_tick() {
  [ -n "$DRYRUN" ] && return 0
  local _st_mode; _st_mode="$(sweep_auto_mode)"
  [ "$_st_mode" = off ] && return 0
  # A finished sweep (manual, in another process) forces an immediate recompute; otherwise scan on the
  # throttled cadence. Either path refreshes the cache and stamps _SWEEP_LAST_SCAN (drives the age note).
  local _st_force=1; _sweep_tally_invalidated || _st_force=0
  _SWEEP_SCAN_TICK=$(( _SWEEP_SCAN_TICK + 1 ))
  if [ "$_st_force" = 0 ] && [ "$_SWEEP_SCAN_TICK" -lt "$_SWEEP_SCAN_INTERVAL" ]; then
    return 0
  fi
  _SWEEP_SCAN_TICK=0
  _SWEEP_LAST_SCAN="$(_now_epoch)"
  read -r _SWEEP_C_TABS _SWEEP_C_MARKERS _SWEEP_C_PROCS <<< "$(sweep_scan_counts)"
  sweep_journal_advice_once "$_SWEEP_C_TABS" "$_SWEEP_C_MARKERS" "$_SWEEP_C_PROCS"
  if [ "$_st_mode" = auto ] \
     && { [ "$_SWEEP_C_TABS" -gt 0 ] || [ "$_SWEEP_C_MARKERS" -gt 0 ] || [ "$_SWEEP_C_PROCS" -gt 0 ]; } \
     && _sweep_auto_should_act "$_SWEEP_C_TABS" "$_SWEEP_C_MARKERS" "$_SWEEP_C_PROCS"; then
    # SAFE legs only. Judgment findings (dirty / unique-commit worktrees) are flagged + journaled by
    # sweep_leg_worktrees and never acted on, so `auto` can never destroy unrecovered work. Narration
    # is swallowed: the console is the watcher's, not the sweep's — the journal carries the record.
    sweep_run_safe_legs >/dev/null 2>&1 || true
    # Remember whether this condition-set was actually ACTIONABLE. sweep_cheap_tab_count knowingly
    # over-counts (a slug whose worktree was reaped but whose PR is still open reads as a stale tab
    # forever). Without this memo that single false positive would re-run every safe leg — a
    # `gh pr view` per worktree plus a `gh pr list` — on every cadence tick, indefinitely. The
    # sweep_advice memo suppressed the journal spam but not the work.
    _sweep_auto_record "$_SWEEP_C_TABS" "$_SWEEP_C_MARKERS" "$_SWEEP_C_PROCS" "$(sweep_swept_total)"
    # The mess is gone; re-scan so the console row clears this same tick instead of lingering a cycle.
    # Re-stamp _SWEEP_LAST_SCAN AFTER sweep_run_safe_legs (which wrote its own tally stamp) so the fresh
    # stamp does not read as "invalidated" and force a redundant re-scan on the very next tick.
    _SWEEP_LAST_SCAN="$(_now_epoch)"
    read -r _SWEEP_C_TABS _SWEEP_C_MARKERS _SWEEP_C_PROCS <<< "$(sweep_scan_counts)"
  fi
  return 0
}

# _sweep_auto_should_act <tabs> <markers> <procs> — skip a repeat auto-sweep of a condition-set we
# already swept and which yielded NOTHING. Any change in the signature (new debris, or debris cleared)
# re-arms it, and a signature whose last run DID sweep something is retried (it was making progress).
_SWEEP_AUTO_MEMO="$TREES/.sweep-auto-acted"
_sweep_auto_should_act() {
  local sig="t=$1 m=$2 p=$3" prev="" psig pswept
  [ -f "$_SWEEP_AUTO_MEMO" ] || return 0
  prev="$(cat "$_SWEEP_AUTO_MEMO" 2>/dev/null || true)"
  psig="${prev%%|*}"; pswept="${prev##*|}"
  [ "$psig" = "$sig" ] || return 0            # different condition-set → act
  [ "${pswept:-0}" -gt 0 ] 2>/dev/null && return 0   # same set, but last run made progress → retry
  return 1                                    # same set, swept nothing → a false positive; stand down
}
_sweep_auto_record() {
  printf '%s|%s\n' "t=$1 m=$2 p=$3" "$4" > "$_SWEEP_AUTO_MEMO" 2>/dev/null || true
}

# _sweep_fmt_age <secs> — compact human age: "Ns" under a minute, "Nm" under an hour, else "Nh". Used
# by the housekeeping staleness note; empty for a non-numeric / negative input.
_sweep_fmt_age() {
  local s="${1:-}"
  case "$s" in ''|*[!0-9]*) return 0 ;; esac
  if   [ "$s" -ge 3600 ]; then printf '%dh' "$(( s / 3600 ))"
  elif [ "$s" -ge 60 ];   then printf '%dm' "$(( s / 60 ))"
  else                         printf '%ds' "$s"
  fi
}

# build_sweep_note — the '🧹 sweep recommended: N stale tabs · M dead markers' console row, rendered
# from the CACHED counts. Empty when the control room is clean or SWEEP_AUTO=off, so the console is
# byte-identical to before this feature whenever there is nothing to sweep.
#
# HERD-215 (tally honesty): the counts refresh only on the ~60 s scan cadence, so between scans this
# row shows a CACHED reading. Rather than silently pass off a stale count as current, annotate it with
# its age ('as of 4m ago') whenever the reading is not this-tick-fresh — the operator sees at a glance
# that the figure may already be out of date (the recompute-after-sweep path clears it entirely once a
# sweep actually runs).
build_sweep_note() {
  SWEEP_NOTE=""
  local _bs_mode _bs_line
  _bs_mode="$(sweep_auto_mode)"
  [ "$_bs_mode" = off ] && return 0
  _bs_line="$(sweep_advice_line "$_SWEEP_C_TABS" "$_SWEEP_C_MARKERS" "$_SWEEP_C_PROCS")"
  [ -n "$_bs_line" ] || return 0
  local _bs_hint="run 'herd sweep'"
  [ "$_bs_mode" = auto ] && _bs_hint="auto-sweeping safe legs; 'herd sweep' for the rest"
  # Staleness caveat: only when we have a real prior scan AND the reading is at least a second old (a
  # this-tick scan reads age 0 and needs no caveat).
  local _bs_age _bs_note=""
  if [ "${_SWEEP_LAST_SCAN:-0}" -gt 0 ] 2>/dev/null; then
    _bs_age=$(( $(_now_epoch) - _SWEEP_LAST_SCAN ))
    [ "$_bs_age" -ge 1 ] 2>/dev/null && _bs_note=" ${C_DIM}(as of $(_sweep_fmt_age "$_bs_age") ago)${C_RESET}"
  fi
  SWEEP_NOTE="    ${C_YELLOW}${_bs_line}${C_RESET}${_bs_note} ${C_DIM}— ${_bs_hint}${C_RESET}"$'\n'
  return 0
}

# ── Singleton acquisition (HERD-209 / HERD-252) — the ONE race-safe watcher spawn-lock ──────────
# _acquire_watcher_singleton — REFUSE-or-ADOPT gate enforcing "exactly one agent-watch main per
# workspace". Returns 0 when this process may run (it acquired the lock — a stale/absent lock is
# adopted); returns 1 when a LIVE watcher already holds the lock and this one must NOT run.
#
# The HERD-209 incident: control-room recovery (herd pane watch / herd reload / manual herd-watch.sh)
# spawned a SECOND watcher WITHOUT killing the first, so two mains polled the same PRs and raced the
# shared .git object store — healthchecks restarted endlessly. The defense is a REAL singleton at every
# launch: atomically check HERD_WATCHER_LOCK (kill -0 on the recorded pid) and refuse the duplicate.
#
# HERD-252: a LIVE-lock collision must REFUSE LOUDLY and IMMEDIATELY — print the holder pid on stderr
# and return non-zero so the caller exits non-zero. Never BLOCK/hang waiting for the lock (operator
# must be able to tell a working launch from a blocked one). A free/stale (dead-pid) lock still
# acquires and starts normally (unchanged).
#
# Two acquisition primitives, one per environment — both ATOMIC and NON-BLOCKING:
#   • flock(1) available  — `flock -n` on fd 9 held for our lifetime; a second watcher's flock -n
#                           fails instantly (auto-released on any exit via fd close). Open with >> so
#                           a failed acquire does not truncate the holder pid out of the lockfile.
#   • no flock (macOS)    — an atomic-mkdir mutex serializes the check+write window, then a PID file
#                           is held for our lifetime and removed on EXIT/INT/TERM. While contending
#                           for the mutex, a LIVE recorded pid refuses immediately (no sleep loop).
# In BOTH primitives we FIRST read the RECORDED pid and refuse a live, non-self one. That kill -0
# check is what catches the exact race the flock alone cannot: a lockfile inode swapped out from
# under an alive holder (rm+recreate) — the recorded pid still proves a watcher is up. Lib-visible
# (defined above the AGENT_WATCH_LIB return) so the unit test can drive it directly; called once at
# main startup below.
_watcher_holder_argv() {
  # _watcher_holder_argv <pid> — command line of <pid>, ≤100 chars. Diagnostic only; fail-soft.
  local p="${1:-}"
  [ -n "$p" ] || return 0
  local a
  a="$(tr '\0' ' ' </proc/"$p"/cmdline 2>/dev/null \
      || ps -o command= -p "$p" 2>/dev/null || true)"
  printf '%s' "${a:0:100}"
}

_watcher_lock_flock_holder() {
  # _watcher_lock_flock_holder — print the pid holding the flock on HERD_WATCHER_LOCK, or empty.
  local lock="${HERD_WATCHER_LOCK:-}"
  [ -n "$lock" ] && [ -f "$lock" ] || return 0
  if command -v lsof >/dev/null 2>&1; then
    local _wlfh_all; _wlfh_all="$(lsof -t -- "$lock" 2>/dev/null || true)"
    printf '%s\n' "${_wlfh_all%%$'\n'*}"
    return 0
  fi
  if [ -f /proc/locks ]; then
    local inode
    inode="$(stat -c '%i' "$lock" 2>/dev/null || true)"
    [ -n "$inode" ] || return 0
    awk -v ino="$inode" '
      /FLOCK/ { n=split($6,a,":"); if (n>=3 && a[3]+0==ino+0) { print $5+0; exit } }
    ' /proc/locks 2>/dev/null || true
  fi
}

_watcher_singleton_refuse_msg() {
  # _watcher_singleton_refuse_msg <pid-or-empty> — one-line LOUD refuse on stderr (HERD-252).
  local _wl_holder="${1:-}"
  if [ -n "$_wl_holder" ]; then
    printf 'herd-watch: already running (pid %s) — refusing duplicate\n' "$_wl_holder" >&2
  else
    printf 'herd-watch: already running — refusing duplicate\n' >&2
  fi
}

_watcher_singleton_refuse() {
  # _watcher_singleton_refuse <pid-or-empty> — refuse loudly + journal watcher_restart_blocked.
  # (c) HERD-342: every refused startup journals the holder identity so JOURNAL_AUDIT can surface it.
  local _wlr_pid="${1:-}"
  _watcher_singleton_refuse_msg "$_wlr_pid"
  local _wlr_argv; _wlr_argv="$(_watcher_holder_argv "$_wlr_pid")"
  journal_append watcher_restart_blocked \
    holder_pid "${_wlr_pid:-unknown}" \
    holder_argv "$_wlr_argv" \
    workspace "${WORKSPACE_NAME:-}"
}

_acquire_watcher_singleton() {
  mkdir -p "$(dirname "$HERD_WATCHER_LOCK")" 2>/dev/null || true
  # Recorded-pid refuse — read the pid BEFORE any open. A LIVE, non-self recorded pid means a
  # watcher already owns this workspace: refuse LOUDLY rather than duplicate or wait.
  local _wl_rec
  _wl_rec="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
  # Trim trailing whitespace/newlines so a pid line is a clean integer for kill -0 + messaging.
  _wl_rec="${_wl_rec%%[$'\t\r\n ']*}"
  if [ -n "$_wl_rec" ] && [ "$_wl_rec" != "$$" ] && kill -0 "$_wl_rec" 2>/dev/null; then
    # (d) HERD-342: if the live holder is marker-owned (an inflight gate worker, not a watcher main),
    # reap it and retry once. Route through watcher-exempt.sh's predicate (HERD-266 seam).
    local _wl_pp; _wl_pp="$(ps -o ppid= -p "$_wl_rec" 2>/dev/null | tr -d '[:space:]')" || _wl_pp="0"
    if watcher_pid_exempt "$_wl_rec" "${_wl_pp:-0}"; then
      kill "$_wl_rec" 2>/dev/null || true
      local _wl_ki=0
      while [ "$_wl_ki" -lt 5 ] && kill -0 "$_wl_rec" 2>/dev/null; do
        sleep 0.1; _wl_ki=$((_wl_ki + 1))
      done
      if ! kill -0 "$_wl_rec" 2>/dev/null; then
        rm -f "$HERD_WATCHER_LOCK" 2>/dev/null || true
        _acquire_watcher_singleton; return $?  # holder gone — re-enter to take the lock
      fi
    fi
    _watcher_singleton_refuse "$_wl_rec"
    return 1
  fi
  if command -v flock >/dev/null 2>&1; then
    # Append-open: do NOT truncate. A contested flock -n must still be able to name the holder pid
    # from the lockfile (truncating open was the silent-manners footgun for the flock-fail path).
    exec 9>>"$HERD_WATCHER_LOCK"
    if ! flock -n 9; then
      _wl_rec="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
      _wl_rec="${_wl_rec%%[$'\t\r\n ']*}"
      if [ -n "$_wl_rec" ] && [ "$_wl_rec" != "$$" ] && kill -0 "$_wl_rec" 2>/dev/null; then
        _watcher_singleton_refuse "$_wl_rec"
        return 1
      fi
      # HERD-344: recorded pid is dead but flock is held by an orphaned gate worker that inherited
      # fd 9 before it was marked close-on-exec. Adopt by re-keying to a fresh inode: close our
      # handle on the old inode, unlink it so a new open creates an independent inode whose lock
      # state is clean, then re-acquire. The orphan retains its flock on the now-unlinked inode
      # and eventually releases it on exit — harmless once we hold the canonical path's lock.
      # (b) HERD-342: capture the orphaned flock holder before unlinking — its identity lands in
      # the bypass journal event so the operator can trace what was running.
      local _wl_bh _wl_ba
      _wl_bh="$(_watcher_lock_flock_holder 2>/dev/null || true)"
      _wl_ba="$(_watcher_holder_argv "$_wl_bh" 2>/dev/null || true)"
      journal_append watcher_singleton_bypass \
        holder_pid "${_wl_bh:-unknown}" \
        holder_argv "$_wl_ba" \
        workspace "${WORKSPACE_NAME:-}"
      exec 9>&-
      rm -f "$HERD_WATCHER_LOCK" 2>/dev/null || true
      exec 9>>"$HERD_WATCHER_LOCK"
      if ! flock -n 9; then
        _wl_rec="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
        _wl_rec="${_wl_rec%%[$'\t\r\n ']*}"
        if [ -n "$_wl_rec" ] && kill -0 "$_wl_rec" 2>/dev/null; then
          _watcher_singleton_refuse "$_wl_rec"
        else
          _watcher_singleton_refuse ""
        fi
        return 1
      fi
    fi
    # HERD-344: mark close-on-exec so no child gate worker can inherit the singleton lock fd.
    { python3 -c 'import fcntl,os; fcntl.fcntl(9, fcntl.F_SETFD, fcntl.FD_CLOEXEC)'; } 2>/dev/null || true
    printf '%s\n' "$$" >"$HERD_WATCHER_LOCK"   # informational PID for diagnostics
    return 0
  fi
  # Atomic-mkdir mutex (serializes the check+write window; held only for that instant).
  # LIVE-lock invariant (HERD-252): never sleep/wait on a live holder — re-check the pid every
  # contention tick and refuse immediately. Only a free mutex / stale (dead) lock may wait briefly.
  local _wl_mtx="${HERD_WATCHER_LOCK}.d" _wl_tries=0 _wl_pid _wl_tmp
  while ! mkdir "$_wl_mtx" 2>/dev/null; do
    _wl_pid="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
    _wl_pid="${_wl_pid%%[$'\t\r\n ']*}"
    if [ -n "$_wl_pid" ] && [ "$_wl_pid" != "$$" ] && kill -0 "$_wl_pid" 2>/dev/null; then
      _watcher_singleton_refuse "$_wl_pid"
      return 1
    fi
    [ -z "$(find "$_wl_mtx" -prune -mmin -1 2>/dev/null)" ] && { rmdir "$_wl_mtx" 2>/dev/null || true; continue; }
    _wl_tries=$((_wl_tries + 1)); [ "$_wl_tries" -ge 30 ] && break; sleep 0.1
  done
  _wl_pid="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
  _wl_pid="${_wl_pid%%[$'\t\r\n ']*}"
  if [ -n "$_wl_pid" ] && [ "$_wl_pid" != "$$" ] && kill -0 "$_wl_pid" 2>/dev/null; then
    rmdir "$_wl_mtx" 2>/dev/null || true
    _watcher_singleton_refuse "$_wl_pid"
    return 1
  fi
  # Stale or absent lock: write our PID (temp+mv for atomicity so readers never see a partial write).
  _wl_tmp="${HERD_WATCHER_LOCK}.$$"
  printf '%s\n' "$$" >"$_wl_tmp"; mv "$_wl_tmp" "$HERD_WATCHER_LOCK"
  rmdir "$_wl_mtx" 2>/dev/null || true
  # Clean up the PID file on exit — but ONLY if it still contains our own PID. If cmd_reload confirms
  # us dead, removes our lock, and relaunches a new watcher, the new watcher writes its PID before we
  # exit; our EXIT trap must not clobber it.
  _watcher_lock_cleanup() {
    [ "$(cat "$HERD_WATCHER_LOCK" 2>/dev/null)" = "$$" ] \
      && rm -f "$HERD_WATCHER_LOCK" 2>/dev/null || true
  }
  trap '_watcher_lock_cleanup' EXIT
  trap '_watcher_lock_cleanup; exit 1' INT TERM
  return 0
}

# ── The watcher tick after the P5 CUTOVER (HERD-306, EPIC HERD-300 FINALE) ───────────────────────
# The bash ACTION PASS (_tick_act — gate dispatch, the auto-merge candidate loop, the block-verdict
# refix bounces, the conflict-resolver (re)spawns) was DELETED here. pysrc/herd/live_runtime.py is now
# the SOLE engine core, and the supervisor hands it EVERY tick via herd_engine_live_tick. There is no
# bash fallback anymore, so the failure story is a WATCHDOG, not a half-run:
#
#   _engine_tick_watchdog  — runs the Python live tick; a FAULT (non-zero exit / missing module) is
#                          retried in-tick with backoff, a fault streak past _ENGINE_FAULT_MAX paints a
#                          LOUD 'engine down · manual intervention' banner + journals engine_down + fires
#                          ONE notification, and it keeps retrying so a transient self-recovers. CRITICAL:
#                          no gate/merge/refix EVER runs in bash now, so a fault is simply "no engine
#                          actions this tick" — the safe hold, never a partial merge.
#   _tick_render_reconcile — runs EVERY cycle regardless of the tick's outcome: it observes the world and
#                          paints the console (Phase A), hands the action pass to the Python engine via
#                          the watchdog, then drains the spawn queue and runs the reconcile/sweep legs
#                          (Phase C) over the same state files + journal the Python engine writes. This
#                          half stays bash per the port spike (console, sweeps, notes, retirement).
# ── OPERATOR EMERGENCY PAUSE (HERD-347) ──────────────────────────────────────────────────────────
# _engine_pause_config_value — read ENGINE_PAUSE FRESH from the config files THIS tick. Deliberately
# reads the FILE, never $ENGINE_PAUSE — the loader UNSETS its internal path vars and a sourced env
# value would only change on a watcher restart, but a pause lever must take effect on the next tick
# with NO restart and no seat-local cache. The path is the config the watcher was launched bound to
# ($HERD_CONFIG_FILE, exported into its env at launch), else the standard per-project path under
# $PROJECT_ROOT — the SAME pair `herd config set` writes from the project root, so any seat's set is
# what we read here. Machine-scope: the .herd/config.local overlay WINS over the committed baseline
# (mirrors the load order in herd-config.sh). Fail-soft: an absent/unreadable file contributes
# nothing; garbage is treated as off by _engine_paused. Byte-quiet — a pure read, no output/mutation.
_engine_pause_config_value() {
  local _ep_base _ep_dir _ep_f _ep_line _ep_val=""
  _ep_base="${HERD_CONFIG_FILE:-}"
  [ -n "$_ep_base" ] || { [ -n "${PROJECT_ROOT:-}" ] && _ep_base="${PROJECT_ROOT}/.herd/config"; }
  [ -n "$_ep_base" ] || return 0
  _ep_dir="$(dirname "$_ep_base" 2>/dev/null)" || return 0
  for _ep_f in "$_ep_dir/config.local" "$_ep_base"; do
    [ -n "$_ep_f" ] && [ -r "$_ep_f" ] || continue
    _ep_line="$(grep -E '^[[:space:]]*ENGINE_PAUSE[[:space:]]*=' "$_ep_f" 2>/dev/null | tail -n1)" || _ep_line=""
    [ -n "$_ep_line" ] || continue
    # Strip `KEY =`, any trailing comment, and surrounding quotes/whitespace.
    _ep_val="$(printf '%s\n' "$_ep_line" \
      | sed -E 's/^[[:space:]]*ENGINE_PAUSE[[:space:]]*=[[:space:]]*//; s/[[:space:]]*#.*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//; s/[[:space:]]*$//')"
    break
  done
  printf '%s' "$_ep_val"
}

# _engine_paused — true iff ENGINE_PAUSE opts in (on). Default/unset/garbage → off (fail toward the
# engine RUNNING, never a silent pause). Mirrors the truthy-token leniency of _flair_enabled so a
# hand-edited ON/true/1 still holds, but `herd config set` only ever writes off|on (value_shape).
_engine_paused() {
  case "$(_engine_pause_config_value)" in
    on|ON|On|true|TRUE|1|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

_engine_tick_watchdog() {
  # OPERATOR EMERGENCY PAUSE (HERD-347) — checked FRESH each tick, BEFORE the engine core runs. With
  # ENGINE_PAUSE=on the Python live tick is SKIPPED entirely (zero gate/merge/refix dispatch), and the
  # skipped tick is NOT counted as a fault: the fault streak, the engine-down banner, and its one-shot
  # notification are all left untouched, so a deliberate pause never trips the 'engine down' alarm. The
  # supervisor loop continues past this early return, so render, reconcile, sweeps and every alarm keep
  # running — only the action engine is held. A LOUD '⏸ engine paused by operator' banner is painted;
  # resume is one `herd config set ENGINE_PAUSE off`, effective on the very next tick with no restart.
  if _engine_paused; then
    ENGINE_PAUSE_ROW="    ${C_YELLOW}⏸ ${C_BOLD}engine paused by operator${C_RESET}${C_YELLOW} · ENGINE_PAUSE=on — NO gates/merges/refix are dispatching (render, reconcile & sweeps continue) · resume: ${C_DIM}herd config set ENGINE_PAUSE off${C_RESET}"$'\n'
    if [ -z "${_ENGINE_PAUSE_DECLARED:-}" ]; then
      _ENGINE_PAUSE_DECLARED=1
      journal_append engine_paused by operator
      herd_driver_notify "⏸ herd engine paused" "ENGINE_PAUSE=on — the engine core is not dispatching gates/merges; render/reconcile/sweeps continue. Resume with herd config set ENGINE_PAUSE off." default
    fi
    render   # repaint THIS tick so the paused banner shows immediately (mirrors the engine-down path)
    return 0
  fi
  # NOT paused. If we WERE paused, announce the resume ONCE and clear the banner before the engine core
  # runs again, so a resumed engine picks up cleanly this very tick.
  if [ -n "${_ENGINE_PAUSE_DECLARED:-}" ]; then
    _ENGINE_PAUSE_DECLARED=""
    ENGINE_PAUSE_ROW=""
    journal_append engine_resumed by operator
    herd_driver_notify "🐑 herd engine resumed" "ENGINE_PAUSE=off — the engine core is dispatching gates and merges again." default
  fi
  # Run the sole engine core (the Python live tick) with an in-tick backoff RETRY, then translate a
  # persistent fault into the loud engine-down HOLD. State is carried in the long-lived watcher process
  # via the module globals initialised near the other tick counters (_ENGINE_FAULT_STREAK etc.).
  local attempt=1 ok=""
  while : ; do
    if herd_engine_live_tick; then ok=1; break; fi
    [ "$attempt" -ge "$_ENGINE_TICK_RETRIES" ] && break
    # Backoff between in-tick attempts (skipped in dry-run so a hermetic/sim run never sleeps).
    [ -n "${DRYRUN:-}" ] || sleep "$(( attempt * _ENGINE_BACKOFF_BASE ))"
    attempt=$(( attempt + 1 ))
  done
  if [ -n "$ok" ]; then
    # Clean tick. If we had been declared down, announce the recovery once and clear the alarm.
    if [ -n "$_ENGINE_DOWN_DECLARED" ]; then
      journal_append engine_recovered after_fault_streak "$_ENGINE_FAULT_STREAK"
      herd_driver_notify "🐑 herd engine recovered" "The Python engine core is ticking again after ${_ENGINE_FAULT_STREAK} faulty tick(s)." default
    fi
    _ENGINE_FAULT_STREAK=0
    _ENGINE_DOWN_DECLARED=""
    _HERD_ENGINE_TICK_LAST_ERR=""
    ENGINE_DOWN_ROW=""
    return 0
  fi
  # The tick faulted through every retry. Grow the consecutive-fault streak and journal it.
  _ENGINE_FAULT_STREAK=$(( _ENGINE_FAULT_STREAK + 1 ))
  journal_append engine_tick_fault streak "$_ENGINE_FAULT_STREAK" attempts "$_ENGINE_TICK_RETRIES" reason "${_HERD_ENGINE_TICK_LAST_ERR:-}"
  if [ "$_ENGINE_FAULT_STREAK" -ge "$_ENGINE_FAULT_MAX" ]; then
    # Past tolerance: paint the loud banner EVERY down-tick (so a restarted render always shows it) and,
    # once per episode, journal engine_down + fire the notification path. No bash action runs — holds are
    # the failure posture.
    local _edr_reason=""
    [ -n "${_HERD_ENGINE_TICK_LAST_ERR:-}" ] && _edr_reason=" · last error: ${_HERD_ENGINE_TICK_LAST_ERR}"
    ENGINE_DOWN_ROW="    ${C_RED}🛑 ${C_BOLD}ENGINE DOWN${C_RESET}${C_RED} · manual intervention — the Python engine core faulted ${_ENGINE_FAULT_STREAK}×${_edr_reason} · NO gates/merges are running · check: ${C_DIM}python3 -m herd.live_runtime --tick${C_RESET}"$'\n'
    if [ -z "$_ENGINE_DOWN_DECLARED" ]; then
      _ENGINE_DOWN_DECLARED=1
      journal_append engine_down streak "$_ENGINE_FAULT_STREAK" attempts "$_ENGINE_TICK_RETRIES" reason "${_HERD_ENGINE_TICK_LAST_ERR:-}"
      herd_driver_notify "🛑 herd engine down — manual intervention" "The Python engine core faulted ${_ENGINE_FAULT_STREAK}× consecutively; no merges or gates are running. Check python3 -m herd.live_runtime." default
    fi
    render   # repaint THIS tick so the engine-down banner shows immediately (render already ran once above)
  fi
  return 1
}

_tick_render_reconcile() {
  # HERD-281: reset the per-tick headroom-approaching signal before the corpse sweep sets it.
  _HEALTH_HEADROOM_APPROACHING=""
  # RESTART-SAFE GATE HYGIENE (HERD-185), FIRST thing each tick: free any slot held by a dead/timed-out
  # review or health worker (corpse sweep), then collect any finished ASYNC main-health suite. Both run
  # BEFORE the candidate pass so a freed slot is available to dispatch this same tick and a landed
  # main-health verdict paints/clears its row immediately. Byte-quiet when there is nothing to do.
  _sweep_gate_corpses
  _collect_main_health
  # SUPERVISED-PROCESS sweep (HERD-193): immediately after the corpse sweep has had its say, account
  # for every population's spawns — retire the ones that exited, journal + inbox the ones past their
  # deadline (routed to the owner that tears that population down). Observability only; never kills.
  _sweep_lifecycle
  # CONTROL-ROOM SWEEP trigger (HERD-191): refresh the cheap debris counts on the orphan-sweep
  # cadence and, under SWEEP_AUTO=auto, run the SAFE legs. Inert under SWEEP_AUTO=off.
  _sweep_trigger_tick

  # Cross-seat dual-engine reconcile (HERD-308), BEFORE the build + action passes so a detected halt
  # both paints this tick and holds this tick's writes. Under ENGINE_SEAT_RECONCILE=on it stamps this
  # seat's engine level into the pool registry and, if a second engine at a different level is writing
  # the same pool, arms $_ENGINE_SEAT_HALT (the stale seat) so do_merge/post_gate_status refuse. A hard
  # no-op when the lever is off or in dry-run; guarded so nothing inside it can end the loop.
  _engine_seat_reconcile_tick || true

  build_header
  build_landed
  build_blocked
  build_tracker_drift
  build_spawn_holds
  build_engine_note
  build_engine_seat_note   # HERD-308: the dual-engine HALT/coexistence row (empty unless a mismatch)
  build_main_health
  # HERD-259: the render pass runs ABOVE reconcile_main_freshness in this tick, and the reconcile is the
  # only other place a held MAIN-STALE row is dropped. Re-derive it from observed git state first, or a
  # row whose condition healed while this watcher was down paints for a whole tick after every restart —
  # and forever if the reconcile keeps deferring. Byte-inert (one `[ -s ]`) with no row held.
  _main_fresh_recheck
  build_main_freshness
  build_checkout_cleanliness   # HERD-361: the shared-checkout cleanliness row (empty unless contaminated)
  build_sweep_note
  build_health_headroom_note  # HERD-281: advisory when suite duration approaches HEALTH_INFLIGHT_TIMEOUT

  # Fetch open PRs (HERD-224: capture success vs failure — never collapse a blip into '[]' and then
  # claim "awaiting task"). On success, apply the configured watcher view (lens + filters). The view
  # is a read-time SELECTION filter only — it narrows which PRs this tick displays/considers and
  # never relaxes any merge gate. Default (all lens, no filters) requests the base fields and
  # passes the JSON through unchanged, preserving today's exact behavior on a successful fetch.
  #
  # HERD-401: this is the tick's "list_open" leg, but it is deliberately NOT called via wunit_list_open.
  # The facade's wunit_list_open (work-unit.sh) is a raw `gh pr list "$@"` passthrough — argv straight
  # to gh, stdout straight back, no defaults. _prs_fetch_tick is a different shape entirely: it takes NO
  # argv, resolves the field set itself (_watcher_tick_fields), timeout-wraps the gh call, distinguishes
  # a genuine empty roster from a failed fetch (PRS_LOOKUP_OK), and applies the watcher's view filter —
  # then sets PRS_JSON/PRS_LOOKUP_OK as globals rather than returning a value. Routing this call through
  # wunit_list_open would either drop all of that (a real behavior change) or require wunit_list_open to
  # grow tick-specific side effects the spike's interface never gave it. Left calling _prs_fetch_tick
  # directly; noted via herd note rather than silently forced through a facade op that doesn't fit it.
  _prs_fetch_tick
  # Builder liveness roster via the active driver: herdr-claude → `herdr agent list`; headless →
  # the detached-agent registry rendered in the same JSON shape. This is what dead-builder
  # reconciliation keys off, so it must reflect real liveness with OR without panes.
  AGENTS_JSON="$(herd_driver_agent_list_json)"
  WT="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null || echo '')"

  # RETIREMENT INVARIANT (HERD-164), reconciled EVERY tick against the world we just observed: a slug
  # whose PR is MERGED or CLOSED (or whose worktree is gone) owns no agent, tab, worktree, branch, or
  # ledger row. Drives the idempotent teardown one step further and records what it could not finish;
  # a slug carrying real work is HELD (loud, never deleted). Runs BEFORE row classification so a
  # retiring slug can never be mistaken for an 'awaiting task' spare — and after $PRS_JSON/$AGENTS_JSON
  # are fetched, because those ARE the observation. Restart-proof: nothing here is event-driven.
  retirement_tick
  # A reap this tick invalidated the worktree snapshot — re-read it so the reaped tree does not render
  # one last phantom in-flight row. Zero reaps (the steady state) costs zero git calls.
  [ "$RETIRE_REAPED" -gt 0 ] && WT="$(git -C "$MAIN" worktree list --porcelain 2>/dev/null || echo '')"
  build_retiring

  # Parse worktrees + match each to its open PR and its agent, emitting one tab-separated record per
  # LEGITIMATE builder worktree. Discovery is SCOPED to $WORKTREES_DIR and filters detached-HEAD /
  # non-builder worktrees (HERD-182) so a stray checkout never renders as a phantom dead-builder row;
  # the main checkout is excluded as before. See _discover_feature_worktrees.
  # Each record also carries HERD-226's join provenance: matchkind (branch | sha | ambig | "") and a
  # matchdetail (the PR's own branch name for a sha join; which PRs collide for an ambiguous one).
  FEATS=()
  while IFS= read -r rec; do
    [ -n "$rec" ] && FEATS+=("$rec")
  done < <(PRS_JSON="$PRS_JSON" AGENTS_JSON="$AGENTS_JSON" WT="$WT" MAIN="$MAIN" TREES="$TREES" _discover_feature_worktrees)

  # Classify each feature into a display line; collect merge candidates separately.
  DISPLAY=()
  FLAIR_STATE=()   # HERD-147: parallel to DISPLAY — one state-token per row for the pasture header
  CAND_IDX=(); CAND_DIR=(); CAND_SLUG=(); CAND_PR=(); CAND_BRANCH=(); CAND_SHA=()
  CONF_IDX=(); CONF_SLUG=(); CONF_PR=(); CONF_BRANCH=(); CONF_SHA=(); CONF_REASON=()
  # HERD-402: this tick's finish-stall verdict tally, fed into the throttled finish_stall_scan summary
  # once the FEATS loop below finishes classifying every builder.
  _FSS_ELIGIBLE=0; _FSS_RETASKED=0; _FSS_ESCALATED=0
  i=0
  for rec in ${FEATS[@]+"${FEATS[@]}"}; do
    IFS=$'\037' read -r dir slug branch prnum mergeable mstate astatus headsha prauthor matchkind matchdetail <<EOF
$rec
EOF
    sl="$(_slug_cell "$slug")"
    pn=""; [ -n "$prnum" ] && pn=" ${C_DIM}#${prnum}${C_RESET} ·"
    # HERD-226: this row's PR was found by HEAD commit, not by branch name — the worktree sits on some
    # other ref (a resolver's scratch branch). Try the lossless repair; if it takes, the row is an
    # ordinary branch-matched one from here down (and stays so next tick, via the cheap name join).
    # If it cannot (dirty tree, diverged ref), the sha-join match STILL stands — gates are (pr,sha)-
    # keyed — and we hang the truthful mismatch note on whatever row the classification produces.
    # $SELF_WT is exempt: never swap the branch out from under the checkout this watcher is running.
    _bmismatch=""
    if [ "$matchkind" = "sha" ]; then
      if [ "$dir" != "$SELF_WT" ] \
         && [ "$(_repair_branch_ref "$dir" "$branch" "$matchdetail" "$headsha" "$prnum" "$slug")" = "REPAIRED" ]; then
        branch="$matchdetail"
      else
        _bmismatch="$(_branch_mismatch_text "$branch" "$matchdetail")"
      fi
    fi
    # HERD-392 review fix (advisory #2): _reconcile_finish_stall is reached ONLY on the PR-less branch
    # below, so nothing ever cleared a slug's finish-stall record once a PR actually opened for it —
    # see _finish_stall_note_pr_opened. ONE choke point covers every downstream has-PR branch
    # (mergeable, blocked, push-gate-awaiting, …).
    [ -n "$prnum" ] && _finish_stall_note_pr_opened "$slug"
    if [ -z "$prnum" ] && [ -n "$(push_gate_awaiting_sha "$slug" 2>/dev/null || true)" ]; then
      # PUSH_GATE=human (HERD-123): a FINISHED builder that stopped BEFORE push has NO PR yet but has
      # recorded a sha-keyed push-hold. Surface it as a 'ready · awaiting push approval' row with the
      # worktree PATH so a human reviews the LOCAL diff, and short-circuit the idle/dead/building
      # classification below — a push-held builder's agent has exited CLEANLY, which the dead-builder
      # path would otherwise mis-flag as died. Presence-driven: no hold record → this branch is skipped
      # and the console is byte-identical to before the feature.
      DISPLAY[i]="    ${C_GREEN}✅${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_GREEN}ready · awaiting push approval${C_RESET} ${C_DIM}${dir}${C_RESET}"
      FLAIR_STATE[i]="pen"
    elif [ -z "$prnum" ] && _rt_state="$(_retire_state_of "$slug")" && [ "$_rt_state" != "active" ]; then
      # RETIREMENT (HERD-164): this tick's invariant pass proved the slug terminal — its PR is merged
      # or closed. It is NOT an 'awaiting task' spare, whatever its agent status says, and it is not a
      # dead builder either: its work landed. Render whose move it is (the herd's while teardown
      # converges; yours once it is stuck or holding real work) and skip the limit/dead/idle
      # classification entirely — those all key off "PR-less", which a merged builder trivially is.
      DISPLAY[i]="$(_row_retirement "$sl" "$slug" "$_rt_state" "$(_retire_detail_of "$slug")")"
      case "$_rt_state" in
        retiring|deferred) FLAIR_STATE[i]="busy" ;;   # HERD-356: deferred is the herd waiting, not your move
        *)                 FLAIR_STATE[i]="attention" ;;
      esac
    elif [ -z "$prnum" ]; then
      if [ "$matchkind" = "ambig" ]; then
        # HERD-226: this worktree's HEAD is the head commit of MORE THAN ONE open PR (or it shares that
        # commit with a sibling worktree). A PR-less row would read 'awaiting task · assign or retire'
        # — the exact lie that hid PR #328. The commit is claimed; which PR is yours to say.
        DISPLAY[i]="$(_row_branch_mismatch "$sl" "$(_branch_mismatch_text "$branch" "$matchdetail")")"
        FLAIR_STATE[i]="attention"
      elif [ "${PRS_LOOKUP_OK:-1}" != "1" ]; then
        # HERD-224: the open-PR roster could not be fetched this tick. An empty match is NOT positive
        # evidence of "no PR" — never paint the definitive "awaiting task · assign or retire" or
        # "died (no PR)" claims from a lookup FAILURE. Neutral degraded row; next tick retries.
        DISPLAY[i]="$(_row_pr_match_pending "$sl")"
        FLAIR_STATE[i]="busy"
      elif [ "$astatus" != "working" ]; then
        # A non-working, PR-less builder is USUALLY just idle waiting for a task. But it may instead
        # be frozen on the ACCOUNT usage limit — its session ended and no typed nudge can revive it
        # (2026-07-02 incident). Detect that (hook sentinel → banner-scrape fallback) and, if so,
        # surface a distinct hold row + schedule an in-place `claude --continue` resume at the reset;
        # otherwise it is the benign "awaiting task" spare row. An existing record keeps the row (and the
        # scheduled resume) alive across ticks even after the transient signal clears.
        # Reached only when PRS_LOOKUP_OK=1: a successful list positively has no PR for this branch.
        if _lim_reset="$(_detect_limit_hit "$slug" "$dir")"; then _lim_hit=1; else _lim_hit=0; fi
        if [ "$_lim_hit" = "1" ] || [ -n "$(limit_state "$slug")" ]; then
          # HERD-392 review fix: a limit-parked builder never reaches _reconcile_finish_stall (this
          # branch owns the tick instead), so an un-actioned anchor would otherwise keep aging through
          # the ENTIRE park and read as already-past-grace the instant it resumes. Preserve a
          # 'retasked'/'escalated' record (the re-task itself may be what put it mid-task when the
          # limit hit); clear a merely-'pending' one so resuming serves a fresh grace window.
          _finish_stall_note_escape "$slug"
          _handle_limit_blocked "$slug" "$dir" "$i" "${_lim_reset:-0}"
        else
          # Not limit-blocked. Distinguish a benign idle agent (still listed in `herdr agent list`,
          # just waiting for a task) from a DEAD builder whose agent has VANISHED from the list — OR is
          # still LISTED but whose PROCESS is dead (HERD-114: a herdr crash leaves a stale 'idle'/'done'
          # over a killed session) — while its worktree lives on with no PR. astatus is EMPTY only when
          # the slug has NO agent record; the liveness probe additionally catches a listed-but-dead
          # session. Surface a persistently-dead builder LOUDLY (💀 + notification) so it is never lost.
          _live="$(_agent_liveness "$slug")"
          case "$(_reconcile_dead_builder "$slug" "$dir" "$astatus" "$_live")" in
            DEAD)
              # A dead builder is not a wedge — 💀 is the louder, truer row, and a corpse cannot be
              # woken. Drop any wedge/finish-stall record so no ledger keeps claiming this slug.
              clear_wedge "$slug"
              _finish_stall_enabled && _finish_stall_clear "$slug"
              if [ "$_live" = "dead" ] && [ -n "$astatus" ]; then
                DISPLAY[i]="    ${C_RED}💀${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_RED}agent dead · session unwakeable (no PR) · re-spawn${C_RESET}"
              else
                DISPLAY[i]="    ${C_RED}💀${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_RED}builder died (no agent, no PR) · re-spawn${C_RESET}"
              fi
              FLAIR_STATE[i]="dead" ;;
            *)
              # ALIVE (or still PENDING death): the agent is listed. HERD-392: check the finish-line
              # watchdog FIRST — ship-dormant (OFF unless FINISH_STALL_MIN is set), so with it unset
              # this always reads NOT_STALLED/OFF and falls straight through to the wedge/spare
              # classification below, byte-identical to before this leg existed.
              _fstall="$(_reconcile_finish_stall "$slug" "$dir" "$astatus" "$branch")"
              # HERD-402: tally this tick's verdict for the throttled finish_stall_scan summary below.
              # Pure counting, no side effect — a hard no-op (all verdicts read OFF/NOT_STALLED, never
              # matching a case here) when FINISH_STALL_MIN is unset, so this stays byte-inert off.
              case "$_fstall" in
                PENDING)                _FSS_ELIGIBLE=$((_FSS_ELIGIBLE + 1)) ;;
                FIRST_STALL)            _FSS_RETASKED=$((_FSS_RETASKED + 1)) ;;
                SECOND_STALL|ESCALATED) _FSS_ESCALATED=$((_FSS_ESCALATED + 1)) ;;
              esac
              case "$_fstall" in
                FIRST_STALL|SECOND_STALL|ESCALATED)
                  _fsrec="$(_finish_stall_record "$slug")"; _fsfirst=""; _fsstate=""
                  [ -n "$_fsrec" ] && IFS=$'\t' read -r _fsfirst _fsstate <<< "$_fsrec"
                  _fsretasked=""; [ "$_fsstate" = "retasked" ] && _fsretasked="retasked"
                  DISPLAY[i]="$(_row_finish_stall "$sl" "$(_fmt_age "$(( $(_now) - ${_fsfirst:-$(_now)} ))")" "$_fsretasked")"
                  # A delivered re-task is calm/in-progress (🩺 'busy', matching the resolving/limit-
                  # resume glyph family), never the LOUD ⚠️ 'attention' glyph the row text itself is
                  # careful NOT to be (PR #502 review) — only the needs-you variants earn 'attention'.
                  if [ -n "$_fsretasked" ]; then FLAIR_STATE[i]="busy"; else FLAIR_STATE[i]="attention"; fi ;;
                *)
                  # Two very different builders land here. HERD-278: one whose agent reads 'done' over
                  # a branch with no PR and nothing pushable is a WEDGE — it was tasked and abandoned
                  # the task mid-delivery — and calling it a spare ("assign or retire") is the lie that
                  # hid three of them on 2026-07-09. Everything else is a genuine spare. A wedge must
                  # age past the grace window first, so a builder inside `gh pr create` keeps its row.
                  _wedge="$(_reconcile_wedged_builder "$slug" "$dir" "$astatus")"
                  if [ "$_wedge" = "WEDGED" ]; then
                    _wfirst="$(wedge_first_seen "$slug")"; _wwoke=""
                    if wedge_woken "$slug"; then _wwoke="woken"; fi
                    DISPLAY[i]="$(_row_wedged "$sl" "$(_fmt_age "$(( $(_now) - ${_wfirst:-$(_now)} ))")" "$_wwoke")"
                    FLAIR_STATE[i]="attention"
                  else
                    # Closed vocabulary (HERD-172): a live spare builder is not "idle" — it is awaiting
                    # a task (YOUR move: assign work or retire it), rendered with the idle age.
                    # FLAIR_STATE keeps its internal "idle" enum → the pasture glyph (💤) is byte-identical.
                    DISPLAY[i]="$(_row_awaiting_task "$sl" "$dir")"
                    FLAIR_STATE[i]="idle"
                  fi ;;
              esac ;;
          esac
        fi
      else
        # A working agent means any earlier limit hold has cleared (a human intervened, or the
        # scheduled resume flipped it working). HERD-155 F4: a working agent is DEFINITIVELY not
        # limit-parked, so clear the ledger record AND any stale hook sentinel UNCONDITIONALLY (both
        # clears no-op when absent) — a leftover sentinel must never survive to re-trigger a false park
        # on a later idle tick. Also drop any stale clean-select record (the same singleton could re-park).
        clear_limit "$slug" "$dir"; clear_sendkeys "$slug"
        # A working agent is DEFINITIVELY not wedged (HERD-278) — it is delivering. Drop any wedge
        # record so a builder that was woken (by the auto-wake, or by a human) and later stops again
        # must serve the FULL grace window before it re-surfaces. No-ops when absent.
        clear_wedge "$slug"
        # Same for the finish-line watchdog (HERD-392): the signature (done/idle) does not hold while
        # working. BUT unlike wedge, a 'retasked'/'escalated' record must SURVIVE this branch — a
        # delivered re-task nudge is exactly what puts the agent into "working" on the very next tick,
        # so an unconditional clear here would wipe the record the instant the nudge succeeds and make
        # SECOND_STALL/escalation unreachable (PR #502 review). HERD-402: a plain 'pending' anchor does
        # NOT unconditionally clear here (unlike the limit-park branch's _finish_stall_note_escape) —
        # a 'working' pane reading alone is not proof of escape (the grounding incident: a builder's own
        # backgrounded healthcheck run reads as 'working' for stretches with the git tree unchanged, so
        # the old unconditional clear() here perpetually reset the clock and it never reached
        # FINISH_STALL_MIN). _finish_stall_note_still_working keys the decision on the SAME git
        # signature the reconcile itself uses instead of the pane status alone; it self-gates on the
        # leg being enabled, so this stays a hard no-op (no shellout) when FINISH_STALL_MIN is unset.
        _finish_stall_note_still_working "$slug" "$dir" "$branch"
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
            DISPLAY[i]="    ${C_BLUE}🔨${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_BLUE}building (uncommitted changes)${C_RESET}"
            FLAIR_STATE[i]="grazing" ;;
          STALL)
            # Reached only when _qelapsed ≥ _quiet, so this age is a real, ≥-window duration.
            _qmins=$(( _qelapsed / 60 ))
            DISPLAY[i]="    ${C_YELLOW}⚠️${C_RESET}  ${C_BOLD}${sl}${C_RESET} ${C_YELLOW}no activity ${_qmins}m · check pane${C_RESET}"
            FLAIR_STATE[i]="warn" ;;
          *)
            DISPLAY[i]="    ${C_BLUE}🔨${C_RESET} ${C_BOLD}${sl}${C_RESET} ${C_BLUE}building${C_RESET}"
            FLAIR_STATE[i]="grazing" ;;
        esac
      fi
    elif [ "$dir" = "$SELF_WT" ]; then
      DISPLAY[i]="    ${C_DIM}🐑 ${sl} self · won't auto-merge${C_RESET}"
      FLAIR_STATE[i]="self"
    elif [ "$mergeable" = "MERGEABLE" ] && { _should_automerge "$mstate" || _gate_bless_eligible "$prnum" "$headsha" "$mstate"; }; then
      # CLEAN → a normal merge candidate (run gates, then merge). BLOCKED-but-unblessed (HERD-194) → a
      # GATE-ONLY candidate: run the gates + post herd/gates so branch protection can clear, but the
      # merge itself still waits for CLEAN (re-verified in the action pass). Without this a PR under
      # `require herd/gates` would sit BLOCKED forever — never a candidate, so never blessed.
      if _scope_permits_automerge "$prauthor"; then
        if _should_automerge "$mstate"; then
          # HERD-313: when a suite is ALREADY in flight for this exact (pr,sha), paint the live running
          # row here in the RENDER pass — reading the same .health-inflight / .health-log state files the
          # health worker (bash gate OR the Python engine's action pass) writes. Under ENGINE_IMPL=python
          # the bash gate step (_healthcheck_gate, which used to be the ONLY place this row was drawn) is
          # skipped, so without this the console showed a frozen bare 'health-check' for the whole ~9-min
          # suite — the invisible-healthcheck the operator hit twice. No live marker yet (pre-dispatch,
          # or between ticks) ⇒ the bare placeholder, exactly as before. Side-effect-free.
          _hc_inf="$(_health_inflight_file "${prnum}-${headsha}")"
          if [ -n "$headsha" ] && _health_pid_live "$_hc_inf"; then
            DISPLAY[i]="$(_health_running_row "$sl" "$pn" "$_hc_inf" "$(_health_log_file "${prnum}-${headsha}")")"
            # HERD-313 leg (a): stand up the disposable health·<slug> WATCH pane (once). Self-gating on
            # HEALTH_PANE (off default ⇒ no-op), idempotent, fail-soft — never touches the row above.
            _spawn_health_pane "$prnum" "$slug" "$headsha" "$dir"
          else
            DISPLAY[i]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}health-check${C_RESET}"
          fi
        else
          DISPLAY[i]="    ${C_YELLOW}🩺${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}gating · herd/gates (${mstate:-?})${C_RESET}"
        fi
        FLAIR_STATE[i]="busy"
        CAND_IDX+=("$i"); CAND_DIR+=("$dir"); CAND_SLUG+=("$slug"); CAND_PR+=("$prnum"); CAND_BRANCH+=("$branch"); CAND_SHA+=("$headsha")
      else
        # Team mode (WATCHER_SCOPE=all): this PR is MERGEABLE+CLEAN and would auto-merge in solo mode,
        # but it is NOT owned by the configured operator. DISPLAY it so a teammate's progress is
        # visible, but NEVER add it to the merge-candidate set — a human merges a teammate's PR.
        DISPLAY[i]="    ${C_DIM}👥${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_DIM}not mine — manual (@${prauthor:-unknown})${C_RESET}"
        FLAIR_STATE[i]="other"
      fi
    elif [ "$mergeable" = "UNKNOWN" ] || [ "$mstate" = "UNKNOWN" ] || [ -z "$mergeable" ]; then
      DISPLAY[i]="    ${C_DIM}🔍${C_RESET} ${C_DIM}${sl}${C_RESET}${pn} ${C_DIM}verifying mergeability…${C_RESET}"
      FLAIR_STATE[i]="verify"
    elif [ "$mergeable" = "CONFLICTING" ]; then
      # HERD-55: sha-keyed resolver dispatch — first conflict spawns; a new commit or a dead resolver
      # RE-spawns (bounded); an ESCALATE is terminal for the sha. Decides + queues via CONF_* arrays.
      _classify_conflict "$i" "$prnum" "$slug" "$branch" "$headsha"
      # HERD-231: whichever row that painted, a starving PR says so underneath it.
      _restale_decorate_row "$i" "$prnum"
    elif [ "$mergeable" = "MERGEABLE" ]; then
      # MERGEABLE (no conflict) but mergeStateStatus != CLEAN: branch-protection gates aren't
      # satisfied yet — BLOCKED (required reviews/CODEOWNERS), BEHIND (out of date), or UNSTABLE
      # (pending/failing required checks). Do NOT merge; soft-hold and re-evaluate next tick. This
      # is transient, NOT a human-action error, so no ⚠️ "needs you".
      #
      # HERD-197: UNSTABLE is opaque — it never names the check. When the hold is UNSTABLE, fetch the
      # GH check-run rollup, journal each landed result as a `ci_check` gate event + notify once on a
      # newly-landed failure, and surface WHICH check is failing/pending in the row instead of the bare
      # (UNSTABLE). A genuine FAILING required check is a human-action stop — it will NEVER merge until
      # fixed — so it graduates to a LOUD red 'needs you · <check>' row (the grounded #293 macOS leg);
      # pending-only checks stay a yellow hold, just named. Fail-soft: a PR with no checks / an offline
      # gh yields no summary and the row is BYTE-IDENTICAL to before.
      #
      # HERD-250: when the fail is the INHERITED-red case (CI red + herd/gates green + branch behind
      # main) and CI_AUTOREPAIR=on, _handle_ci_repair dispatches a base-refresh instead of needs-you.
      # NEVER silent-merges a red PR; a real new-code failure (not behind / no gates) still needs-you.
      _ci_sum=""
      if [ "$mstate" = "UNSTABLE" ]; then _ci_sum="$(_ci_gate_eval "$prnum" "$headsha" "$slug")"; fi
      if [ -n "$_ci_sum" ]; then
        _ci_bucket="${_ci_sum%%$'\t'*}"; _ci_text="${_ci_sum#*$'\t'}"
        if [ "$_ci_bucket" = "fail" ]; then
          if _handle_ci_repair "$prnum" "$slug" "$headsha" "$i" "$dir" "$branch" "$_ci_text"; then
            FLAIR_STATE[i]="busy"
          else
            DISPLAY[i]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · ${_ci_text}${C_RESET}"
            FLAIR_STATE[i]="attention"
          fi
        else
          DISPLAY[i]="    ${C_YELLOW}⏸${C_RESET}  ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}blocked · ${_ci_text}${C_RESET}"
          FLAIR_STATE[i]="busy"
        fi
      else
        DISPLAY[i]="    ${C_YELLOW}⏸${C_RESET}  ${C_BOLD}${sl}${C_RESET}${pn} ${C_YELLOW}blocked · awaiting required checks/reviews (${mstate:-?})${C_RESET}"
        FLAIR_STATE[i]="busy"
      fi
      # AGING-PR alarm (HERD-334): a PR that has sat engine-approved (herd/gates PASSED) but blocked on a
      # required check past AGING_PR_TTL grows a loud advisory line + journals `pr_aging` once. Byte-inert
      # when AGING_PR_TTL=0 and until a PR actually ages; never a hold. Reuses the _ci_sum already fetched.
      _aging_decorate_row "$i" "$prnum" "$headsha" "$slug" "$mstate" "$_ci_sum"
    else
      reason="not mergeable (${mstate})"
      DISPLAY[i]="    ${C_RED}⚠️${C_RESET} ${C_BOLD}${sl}${C_RESET}${pn} ${C_RED}needs you · ${reason}${C_RESET}"
      FLAIR_STATE[i]="attention"
    fi
    # A sha-joined worktree we could not repair keeps its real row — health-check, blocked, conflict,
    # whatever the PR's state is — with the mismatch named after it. The gate outcome is the headline;
    # the stale ref is the footnote. Empty (the overwhelmingly common case) leaves the row untouched.
    [ -n "$_bmismatch" ] && DISPLAY[i]="${DISPLAY[i]} ${C_YELLOW}· ${_bmismatch}${C_RESET}"
    i=$((i + 1))
  done

  # HERD-147 flair — assemble the pasture header + any queued merge celebration from THIS tick's herd
  # snapshot, BEFORE render. Both no-op (leave PASTURE/CELEBRATE empty) when WATCHER_FLAIR is off, so
  # the frame is byte-identical to before the feature. The celebration's "<n> grazing" count is the
  # number of builders classified as building this tick.
  _flair_grazing=0
  for _fs in ${FLAIR_STATE[@]+"${FLAIR_STATE[@]}"}; do
    [ "$_fs" = "grazing" ] && _flair_grazing=$((_flair_grazing + 1))
  done
  build_celebrate "$_flair_grazing"
  build_pasture

  # HERD-184 operator inbox — refresh the cross-seat inbox on the throttled interval (network reads
  # never ride the 4 s repaint), then render the section from its ledger. _inbox_scan self-gates on
  # OPERATOR_INBOX (no-op when off), and build_operator_inbox leaves OPERATOR_INBOX_ROWS empty when
  # off/none, so the frame is byte-identical to before the feature. PRS_JSON is the tick's already-
  # fetched open-PR set — no extra `gh pr list`.
  if _operator_inbox_enabled; then
    _INBOX_SCAN_TICK=$((_INBOX_SCAN_TICK + 1))
    if [ "$_INBOX_SCAN_TICK" -ge "$_INBOX_SCAN_INTERVAL" ]; then
      _INBOX_SCAN_TICK=0
      _inbox_scan "$PRS_JSON"
    fi
  fi
  build_operator_inbox

  # HERD-202 builder notes — drain NEW builder_note journal events into the ledger + notify stream,
  # then render the section. Cheap (local journal tail via byte cursor); every tick is fine. Empty
  # ledger ⇒ build_builder_notes leaves BUILDER_NOTES_ROWS empty ⇒ byte-identical console when unused.
  _builder_notes_scan
  build_builder_notes

  # HERD-330 orphan PRs — rewrite + render the advisory section listing each open PR (in the tick's
  # already-fetched PRS_JSON) that NO discovered builder worktree owns. The claimed set is derived from
  # this tick's FEATS records (field 4 = PR number); an orphan is any open PR not in it. _orphan_prs_scan
  # self-gates on ORPHAN_PR_ROWS (no scan, no ledger write when off) and on PRS_LOOKUP_OK (never
  # fabricates on a failed fetch); build_orphan_prs leaves ORPHAN_PR_SECTION_ROWS empty when off/none, so
  # the frame is byte-identical to before the feature. Zero extra gh — no new `gh pr list`.
  # HERD-369 reuses this SAME claimed-set diff for the adopt leg below, so the computation now also
  # runs under ADOPT_REMOTE_PRS alone — when BOTH levers are off (the ship default) this is byte-
  # identical to before either feature: the condition is false||false, same as false.
  _orphan_claimed=""
  if _orphan_pr_rows_enabled || _adopt_remote_prs_enabled; then
    for _orphan_rec in ${FEATS[@]+"${FEATS[@]}"}; do
      IFS=$'\037' read -r _ _ _ _orphan_prnum _ <<EOF
$_orphan_rec
EOF
      [ -n "${_orphan_prnum:-}" ] && _orphan_claimed="${_orphan_claimed}${_orphan_prnum} "
    done
  fi
  if _orphan_pr_rows_enabled; then
    _orphan_prs_scan "$PRS_JSON" "$_orphan_claimed"
  fi
  build_orphan_prs

  # HERD-369 adopt remote PRs — throttled to the ~60 s scan cadence (network + git mutation, unlike
  # the zero-network orphan render above): `git fetch` + `git worktree add` each orphan PR's branch
  # into the pool. Self-gates on ADOPT_REMOTE_PRS; off (default) is byte-inert — no scan, no fetch, no
  # worktree add, no ledger write.
  if _adopt_remote_prs_enabled; then
    _ADOPT_SCAN_TICK=$((_ADOPT_SCAN_TICK + 1))
    if [ "$_ADOPT_SCAN_TICK" -ge "$_ADOPT_SCAN_INTERVAL" ]; then
      _ADOPT_SCAN_TICK=0
      _adopt_remote_prs_scan "$PRS_JSON" "$_orphan_claimed" "$WT"
    fi
  fi

  # HERD-402 finish-stall scan observability — throttled to the ~60 s scan cadence, exactly like
  # adopt_scan above (HERD-388): the leg's own detection/action runs every tick inside the FEATS loop
  # (it cannot be throttled without breaking the grace-window clock), but the journal HEARTBEAT is,
  # so a silent leg (zero eligible, zero fired, every scan) is distinguishable in the journal from a
  # dead one. Self-gates on FINISH_STALL_MIN; off (default) is byte-inert — no scan, no journal write.
  if _finish_stall_enabled; then
    _FINISH_STALL_SCAN_TICK=$((_FINISH_STALL_SCAN_TICK + 1))
    if [ "$_FINISH_STALL_SCAN_TICK" -ge "$_FINISH_STALL_SCAN_INTERVAL" ]; then
      _FINISH_STALL_SCAN_TICK=0
      _finish_stall_scan_summary "$_FSS_ELIGIBLE" "$_FSS_RETASKED" "$_FSS_ESCALATED"
    fi
  fi

  render
  # ENGINE (HERD-306, EPIC HERD-300 FINALE): hand the action pass to the SOLE engine core — the LIVE
  # Python engine (pysrc/herd/live_runtime.py) — through the watchdog. There is NO bash action pass to
  # fall back to anymore (_tick_act was deleted): the watchdog runs the Python tick, RETRIES a fault
  # with backoff, and past a fault streak HOLDS loudly (engine-down banner + journal + notification)
  # while it keeps retrying. A fault means "no engine actions this tick" — never a half-run. The render
  # above and the reconcile/sweep legs below run every cycle regardless, against the state Python wrote.
  _engine_tick_watchdog
  # Resolver-pane reconcile (HERD-280): retire the pane of every resolver whose DONE verdict has landed.
  # Runs OUTSIDE the conflict pass on purpose — a resolver that CLEARED its conflict leaves the pass's
  # scope entirely (the PR is CLEAN now), so only a registry-vs-verdict reconcile ever sees it finish.
  # Byte-inert unless RESOLVER_PANE=on (no rows exist to reconcile).
  _reconcile_resolver_panes

  # Health-pane reconcile (HERD-313 leg a): retire the disposable `health·<slug>` view pane of every
  # suite that has ENDED, whoever ran it (mirrors the resolver-pane reconcile above). Byte-inert unless
  # HEALTH_PANE=on left rows to reconcile — under the ship default there are none, so this does nothing.
  _reconcile_health_panes

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
  # Journal self-audit (HERD-238) rides the same cadence: a bounded journal replay for invariant
  # violations (merge-without-reap, stranded dispatches, bounce-without-wake, stale MAIN RED,
  # pushed=no, fixture slugs) → operator-inbox rows + journal_audit events. Ship-dormant unless
  # JOURNAL_AUDIT=on; advisory only.
  _TRACKER_SWEEP_TICK=$((_TRACKER_SWEEP_TICK + 1))
  if [ "$_TRACKER_SWEEP_TICK" -ge "$_TRACKER_SWEEP_INTERVAL" ]; then
    _TRACKER_SWEEP_TICK=0
    _sweep_tracker_state
    _sweep_journal_audit
  fi

  # Post-merge hook reconcile (HERD-232): every _PMS_SWEEP_INTERVAL ticks, re-derive the post-merge
  # obligations of recently-MERGED PRs from the world and run whatever is outstanding. This is what
  # makes the hooks hold for a merge THIS seat did not perform (another watcher, the gh UI) or did not
  # finish (killed mid-do_merge). Idempotent + run-once-keyed; byte-inert once a PR is reconciled.
  _PMS_SWEEP_TICK=$((_PMS_SWEEP_TICK + 1))
  if [ "$_PMS_SWEEP_TICK" -ge "$_PMS_SWEEP_INTERVAL" ]; then
    _PMS_SWEEP_TICK=0
    _sweep_merged_prs
  fi

  # Codemap / symbol-index freshness reconcile (HERD-218): multi-seat invariant — when another seat
  # (or the gh UI) merges without THIS watcher's do_merge, the committed maps can go stale. Probe the
  # read-only --check seams and repair ONCE with provenance=reconcile. Byte-inert when
  # CODEMAP_AUTOREFRESH=off; zero commits when maps already fresh; skips mid-op (live gate / dirty
  # MAIN). The do_merge refresh_* path remains the local-merge fast path.
  #
  # MAIN-checkout freshness (HERD-233) runs FIRST so the map probe sees a fresh HEAD: ff when behind,
  # heal an unpushed/diverged generated-map commit, hold loudly on anything else. Rides the tick (no
  # config key), independent of CODEMAP_AUTOREFRESH, byte-inert when $MAIN is already current.
  reconcile_main_freshness
  reconcile_map_freshness

  # Shared-checkout cleanliness invariant (HERD-361): the shared checkout must be attached to the default
  # branch with no staged changes / tracked modifications other than derived docs awaiting a refresh
  # commit. A violation (the fingerprint of a tool that staged/stashed in $PWD from $MAIN) is surfaced as
  # a loud console row + one journal event naming the offending paths, and NEVER auto-discarded (evidence
  # preservation). Keyed off observed git state each tick, so it holds no matter which seat caused it.
  reconcile_checkout_cleanliness

  # Watcher SELF-RESTART (HERD-251): the reconcile above may have left a "new engine code" note. With
  # WATCHER_SELF_RESTART=on that note arms a QUIESCE (no new gate dispatch) and, once the in-flight
  # workers have drained for 2 consecutive ticks — or the 15-minute cap expires — this call re-execs
  # the watcher in place and never returns. Byte-inert with the lever off (and in dry-run); guarded so
  # no failure inside it can end the watch loop.
  _self_restart_tick || true

  # Main-health (HERD-222): the SAME multi-seat rule for the default branch's health. Every observed
  # main sha must end with a collected verdict, whoever merged it — so this runs AFTER the freshness
  # reconcile above, against the HEAD it just fast-forwarded to. Dispatches an un-ticked sha (a cross-seat
  # merge, a no-slot deferral, a killed worker), and re-verifies a standing red on the
  # MAIN_HEALTH_RECHECK_MINS cadence. Byte-inert when MAIN_HEALTH_TICK=off.
  reconcile_main_health

  # Branch-CI main-red leg (HERD-334): the MAIN RED machinery reflected only the LOCAL suite, which can be
  # green while the DEFAULT branch's required CI is red (main sat CI-red 6h after #439 with no alarm). On a
  # throttled cadence, probe the branch's latest CI run and fire the SAME main-red row on a failing
  # conclusion. Byte-inert when MAIN_HEALTH_TICK=off; fail-soft (no gh / no runs → no row).
  _MAIN_CI_SCAN_TICK=$((_MAIN_CI_SCAN_TICK + 1))
  if [ "$_MAIN_CI_SCAN_TICK" -ge "$_MAIN_CI_SCAN_INTERVAL" ]; then
    _MAIN_CI_SCAN_TICK=0
    _main_health_ci_leg
  fi

  # Engine auto-update (HERD-179): every _ENGINE_INTERVAL ticks, and only under ENGINE_AUTOUPDATE=auto
  # with a genuinely stale engine, dispatch `herd update` DETACHED — it ends in a reload that restarts
  # this watcher, so it must not run inside the tick. `herd update`'s own preflight is the quiescent
  # window: under HERD_NONINTERACTIVE it refuses outright while builders are mid-flight (their lanes
  # reference engine scripts live) or the engine checkout is dirty. Never runs in dry-run.
  _ENGINE_TICK=$((_ENGINE_TICK + 1))
  if [ "$_ENGINE_TICK" -ge "$_ENGINE_INTERVAL" ]; then
    _ENGINE_TICK=0
    [ -n "$DRYRUN" ] || herd_engine_autoupdate_tick
    # (HERD-306) The live per-tick shadow dispatch is RETIRED: with the bash action pass deleted there
    # is no live pipeline for a shadow run to parallel. The parity SHADOW oracle still exists, invoked
    # out-of-band by scripts/herd/sim/parity-run.sh — never from this watch-time seam.
  fi
}

# Sourcing this file (e.g. from the hermetic test) loads the helper functions — including the pure
# merge-decision predicate _should_automerge and the watcher-view selectors above — WITHOUT entering
# the live watch loop. Direct execution runs the loop normally.
if [ "${AGENT_WATCH_LIB:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

# ── HERD-189 TEST-HERMETICITY GUARD: refuse to run the REAL watch loop under a hermetic test ─────
# The test suite must NEVER launch a live watcher/daemon against the real control room. A hermetic
# run (the dogfood healthcheck, or any test) may set HERD_HERMETIC_GUARD to a log-file path; any
# watcher that reaches this point — spawned via cmd_reload's pane-run/background fallback, `herd pane
# watch`, herd-watch.sh, coordinator.sh, or direct execution — records the leak and EXITS BEFORE the
# argv0 re-exec and the loop. So a test that forgot to stub a watcher spawn is caught LOUDLY (the
# healthcheck fails on a non-empty log) instead of silently leaving a real daemon behind. This is the
# single choke point every launch path funnels through. INERT in production: with the var unset this
# is byte-identical to before (the real console-room watcher never sets it).
if [ -n "${HERD_HERMETIC_GUARD:-}" ]; then
  printf '%s\t%s\t%s\n' "agent-watch.sh" "${WORKSPACE_NAME:-?}" "$(pwd 2>/dev/null || echo '?')" \
    >> "$HERD_HERMETIC_GUARD" 2>/dev/null || true
  exit 0
fi

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
# This watcher's own positional args, so the HERD-251 self-restart's exec replays exactly what the
# re-exec above passes through ("$@" is not visible inside a function). Empty today — agent-watch.sh
# parses no positional args — and expanded with the `+` guard so `set -u` tolerates the empty array.
_WATCH_ARGV=("$@")

# ── Launch-binding banner + foreign-cwd guard (issue #60) ───────────────────────────────────────
# Print the resolved WORKSPACE_NAME/PROJECT_ROOT and refuse to run from outside PROJECT_ROOT (unless
# HERD_ALLOW_FOREIGN_CWD=1). Placed AFTER the argv0 re-exec so it prints exactly once, in the final
# tagged process. The config-source refusal (herd-config.sh) already fired on the first pass if the
# config was engine-dogfood-only; this catches the complementary case — a real config but a $PWD
# that is not inside the project it resolves to.
herd_console_guard "herd watch" || exit 1

# ── Singleton spawn-lock: exactly one watcher per project (HERD-209 / HERD-252) ─────────────────
# The race-safe acquisition lives in _acquire_watcher_singleton (defined above the AGENT_WATCH_LIB
# return so the unit test can drive it): it REFUSES when a LIVE watcher is already recorded in
# HERD_WATCHER_LOCK (kill -0 on the recorded pid, then non-blocking flock/mkdir), and ADOPTS a
# stale/absent lock. A LIVE-lock refusal is LOUD and NON-ZERO (HERD-252): stderr names the holder
# pid (`herd-watch: already running (pid <N>) — refusing duplicate`) and we exit 1 immediately —
# never hang, never soft-exit 0 that looks like a successful launch. Keyed by WORKSPACE_NAME
# (matching the coordinator/scribe/researcher/dep-watcher pattern). bin/herd's launch paths
# (cmd_pane_watch / cmd_reload) mirror this check before spawning so a duplicate is caught at the
# launcher too.
_acquire_watcher_singleton || exit 1
# The incoming generation owns the lock: any self-restart handoff window is over (HERD-266). Clearing
# it HERE — after the acquire, in both the exec'd image and a cold launch — means the duplicate alarm
# is suppressed for exactly the exec, never a tick longer. A crashed exec that never reached this line
# leaves a marker that ages out on its own (WATCHER_HANDOFF_TTL).
watcher_handoff_clear
# ───────────────────────────────────────────────────────────────────────────────────────────────

# ── Spawn-queue dependency ordering (HERD-94) ────────────────────────────────────────────────────
# _spawn_dep_merged <after> — is a spawn intent's after=<slug|pr#> dependency MERGED? Returns 0 (met)
# for an EMPTY dependency (an intent with no after= is trivially releasable — the byte-identical path).
# Otherwise consult the SAME source _startup_reap_sweep trusts: the reap ledger $STATE, whose rows are
# "<epoch> <pr#> <slug> [ref]". A numeric dependency matches the PR column ($2); a slug matches the
# slug column ($3). If the ledger has no record (e.g. a collaborator/main-checkout merge this watcher
# never ledgered), FALL BACK to exactly one gh check: a PR number by itself, a slug by its feat/<slug>
# branch. Any non-MERGED / gh-unreachable result => not met (0/return 1) so the intent stays held —
# a held intent is loud (the stalled row), never a silently-dropped one.
_spawn_dep_merged() {
  local _sdm_after="${1:-}"
  [ -n "$_sdm_after" ] || return 0
  if [ -s "$STATE" ]; then
    if printf '%s' "$_sdm_after" | grep -qE '^[0-9]+$'; then  # pipe-ok: single short scalar (one line), far under a pipe buffer
      awk -v p="$_sdm_after" 'NF>=2 && $2==p{f=1} END{exit !f}' "$STATE" 2>/dev/null && return 0
    else
      awk -v s="$_sdm_after" 'NF>=3 && $3==s{f=1} END{exit !f}' "$STATE" 2>/dev/null && return 0
    fi
  fi
  # Fallback: one gh state read (the ledger is authoritative for THIS watcher's merges but blind to a
  # merge performed elsewhere). Skipped in dry-run so a hermetic/observation run never hits the network.
  [ -z "${DRYRUN:-}" ] || return 1
  local _sdm_target
  # A slug dependency resolves to its branch via the shared BRANCH_TEMPLATE helper (HERD-120), not a
  # hardcoded feat/ prefix, so a project with custom branch naming still resolves the gh fallback. The
  # ref is unknown here (we hold only the dep's slug); a {ref}-bearing template renders without it and
  # a mismatch simply keeps the intent HELD (loud), never silently released — see the header note.
  if printf '%s' "$_sdm_after" | grep -qE '^[0-9]+$'; then _sdm_target="$_sdm_after"; else _sdm_target="$(herd_branch_render "$_sdm_after")"; fi  # pipe-ok: single short scalar (one line), far under a pipe buffer
  [ "$(_gh_timeout spawn_dep_state pr view "$_sdm_target" --json state -q .state 2>/dev/null)" = "MERGED" ] && return 0
  return 1
}

# _spawn_held_epoch <intent_id> — echo the first-held epoch recorded for this intent (empty if none).
_spawn_held_epoch() {
  [ -s "$SPAWN_HELD_STATE" ] || return 0
  awk -v id="$1" '$1==id{e=$2} END{if(e)print e}' "$SPAWN_HELD_STATE" 2>/dev/null
}

# _spawn_mark_held <intent_id> <slug> <lane> <after> — record a hold the FIRST time only, journaling
# spawn_held ONCE with the dependency named. Idempotent across ticks: a row already present (the intent
# was held on a prior tick and released back to .req) is left untouched, so the stall TTL keeps accruing
# from the original hold and spawn_held is never re-journaled tick-over-tick.
_spawn_mark_held() {
  local _smh_id="$1" _smh_slug="$2" _smh_lane="$3" _smh_after="$4"
  [ -n "$(_spawn_held_epoch "$_smh_id")" ] && return 0
  printf '%s %s %s %s %s\n' "$_smh_id" "$(date +%s)" "$_smh_slug" "$_smh_lane" "$_smh_after" >> "$SPAWN_HELD_STATE"
  journal_append spawn_held slug "$_smh_slug" lane "$_smh_lane" after "$_smh_after"
}

# _spawn_clear_held <intent_id> — drop this intent's hold row (dependency met / spawned / skipped). A
# no-op when no row exists, so calling it on an intent that was never held is harmless.
_spawn_clear_held() {
  [ -s "$SPAWN_HELD_STATE" ] || return 0
  local _sch_tmp; _sch_tmp="$(mktemp "${SPAWN_HELD_STATE}.XXXXXX" 2>/dev/null)" || return 0
  if awk -v id="$1" '$1!=id' "$SPAWN_HELD_STATE" > "$_sch_tmp" 2>/dev/null; then
    mv -f "$_sch_tmp" "$SPAWN_HELD_STATE" 2>/dev/null || rm -f "$_sch_tmp" 2>/dev/null
  else
    rm -f "$_sch_tmp" 2>/dev/null
  fi
}

# ── Spawn-queue drain ────────────────────────────────────────────────────────────────────────────
# _drain_spawn_queue — called once per tick to pop pending spawn intents from the durable queue
# ($WORKTREES_DIR/spawn-queue/) and launch the matching builder lane. Concurrency cap mirrors the
# lane advisory gate: REVIEW_CONCURRENCY + SPAWN_AHEAD total active builders. FEATS (the live
# worktree roster) is computed earlier this tick, so active count is its length.
#
# DURABILITY CONTRACT (review gate, PR #151): an intent is consumed (`done`, rm) ONLY after its
# lane observably spawned, because the lanes have TWO no-builder exits a fire-and-forget launch could
# never see:
#   • the lane's own advisory saturation gate defers with EXIT 0 and the stable marker line
#     'review-gate saturated' (herd_spawn_gate_emit_defer) — a HELD spawn, not a failure: the
#     intent is RELEASED back to .req (spawn-step.sh release) for a later tick, and the drain
#     stops for this tick (siblings would also defer against the same gate);
#   • a hard failure (bad slug, existing worktree, git/network error) exits non-zero — the intent
#     is dropped LOUDLY (skip + journal), never silently.
# Every outcome journals (spawn_launched / spawn_deferred / spawn_skipped) so the next overnight
# post-mortem can answer "why did nothing spawn?" from `herd log` alone.
#
# HERD-237 — the lane no longer runs in the tick's foreground. The contract above is UNCHANGED: the
# lane's output and exit status are still captured and still decide the intent's fate, but that whole
# observe-and-consume tail moved WITH the lane into `_drain_lane_worker`, which runs in a background
# subshell (`_spawn_inflight_bg`). The tick fires it and moves on; a lane that takes 30 s to clone a
# worktree no longer stalls merges, collections and limit-parks for every other PR. Until its worker
# finishes, the intent stays CLAIMED (.req.mine) — so the drain is durable across a watcher death at
# any instant, exactly as before.
#
# THE CLAIM MUST NOW OUTLIVE A TICK, so `spawn-step.sh next`'s five-minute stale reclaim can no longer
# treat a surviving claim as proof of a dead watcher. The worker's first act is `spawn-step.sh own
# <claim> $BASHPID`, and the reclaim skips any claim whose owner is alive. Without that, a lane slower
# than five minutes has its intent re-served while it is still launching, its `done` becomes a no-op on
# a moved path, and the next free tick spawns the same slug again. Every `done`/`release`/`skip` now
# fails LOUD (exit 3 → a `spawn_claim_lost` journal line) when the claim it was handed has vanished,
# so a lost claim can never be mistaken for a consumed one.
#
# ONE LANE AT A TIME, still. The foreground drain implicitly serialized lanes, and stopped the tick
# outright on a saturation defer (`break`) so siblings would not defer against the same gate. Both
# properties survive without blocking: at most ONE lane is launched per tick, and none at all while a
# previous tick's lane is still in flight (`_lane_spawn_inflight`). A saturated gate therefore still
# costs exactly one lane invocation per tick, never one per queued intent.
#
# What does NOT change is the SCAN. The loop still walks the queue to its budget every tick, so a
# dependency hold is still recorded and journaled (spawn_held) on the tick it becomes visible — the
# HERD-94 invariant that one stalled dependency never freezes the queue. A runnable intent that cannot
# launch this tick (its slot is taken by a live lane) is simply RELEASED with the held ones and
# re-claimed next tick, in the same FIFO order. Net effect: the queue drains one intent per tick
# instead of N-in-one-blocking-tick — faster in wall-clock whenever a lane outlives the 4 s tick,
# which is every real lane.
#
# DEPENDENCY ORDERING (HERD-94): an intent may carry an after=<slug|pr#> (the .after sidecar, surfaced
# as the 4th claim line). While that dependency is NOT yet MERGED the intent is HELD: it stays claimed
# (.req.mine) for THIS tick so `next` skips past it to younger, independent intents — one stalled
# dependency never freezes the whole queue — and every held intent is RELEASED back to .req at the end
# of the tick to be re-checked next time. The hold is journaled spawn_held ONCE (via $SPAWN_HELD_STATE)
# and surfaces on the console (build_spawn_holds), going LOUD (stalled) past DEP_STALE_TTL. When the
# dependency finally merges the intent spawns in the same FIFO order it would have without after=, and
# spawn_released is journaled. Intents with NO after= are byte-identical to the pre-HERD-94 path.
#
# The task payload is read as the REMAINDER of the claim stream (not one line): task text may be
# multi-line and `read -r` would silently truncate it to its first line before the builder saw it.
#
# Fail-soft: a malformed intent is skipped with a logged warning — never crashes the watcher loop.
# Skipped entirely in dry-run mode (intents remain pending; no lane is spawned).
_drain_lane_worker() {
  local _dlw_claimed="$1" _dlw_slug="$2" _dlw_lane="$3" _dlw_ref="$4" _dlw_task="$5"
  local _dlw_out="" _dlw_rc=0 _dlw_bin="$HERE/herd-quick.sh"
  [ "$_dlw_lane" = "feature" ] && _dlw_bin="$HERE/herd-feature.sh"
  # (The claim is bound to this worker's pid by the drain, synchronously, before the tick continues —
  # see `spawn-step.sh own` at the launch site. $BASHPID would let the worker do it itself, but bash
  # 3.2 — still macOS's /bin/bash — has no BASHPID, and the parent already holds the pid as `$!`.)
  # Re-export the threaded tracker ref (HERD-64) as HERD_ITEM_REF so the lane carries it into the
  # PR's 'Refs:' line, the atomic claim (CLAIM_REQUIRED), and its own TRACKED_SPAWNS gate — an
  # intent that spawn.sh accepted as tracked is never re-refused at drain time. Empty ref =
  # unset-equivalent (every consumer tests for non-empty), so untracked intents are unaffected.
  _dlw_out="$(HERD_ITEM_REF="$_dlw_ref" bash "$_dlw_bin" "$_dlw_slug" "$_dlw_task" 2>&1)" || _dlw_rc=$?
  # Each outcome below is journaled only if spawn-step ACTED on the claim we still hold. It exits 3
  # when the claim has vanished (reclaimed under us, or already consumed) — journal that loudly as
  # spawn_claim_lost rather than report a spawn_launched for an intent still sitting in the queue.
  if [ "$_dlw_rc" -eq 0 ] && printf '%s' "$_dlw_out" | grep -q 'review-gate saturated'; then  # pipe-ok: bounded command output, under a pipe buffer
    # HELD, not spawned: the lane's advisory gate deferred (exit 0 + marker). Put the intent back for
    # a later tick. The drain already stopped for this tick when it launched this worker.
    if bash "$HERE/spawn-step.sh" release "$_dlw_claimed" >/dev/null 2>&1; then
      journal_append spawn_deferred slug "$_dlw_slug" lane "$_dlw_lane"
    else
      journal_append spawn_claim_lost slug "$_dlw_slug" lane "$_dlw_lane" action release
    fi
  elif [ "$_dlw_rc" -ne 0 ]; then
    # Hard failure: no builder exists. Drop the intent LOUDLY — skip logs a warning and the journal
    # records why, so a lost spawn is always visible in `herd log`.
    if bash "$HERE/spawn-step.sh" skip "$_dlw_claimed" "lane exited $_dlw_rc" >/dev/null 2>&1; then
      journal_append spawn_skipped slug "$_dlw_slug" lane "$_dlw_lane" reason "lane exited $_dlw_rc"
    else
      journal_append spawn_claim_lost slug "$_dlw_slug" lane "$_dlw_lane" action skip
    fi
  else
    # Spawned: only now is the intent consumed.
    if bash "$HERE/spawn-step.sh" done "$_dlw_claimed" >/dev/null 2>&1; then
      journal_append spawn_launched slug "$_dlw_slug" lane "$_dlw_lane"
    else
      journal_append spawn_claim_lost slug "$_dlw_slug" lane "$_dlw_lane" action done
    fi
  fi
  return 0
}

_drain_spawn_queue() {
  [ -z "${DRYRUN:-}" ] || return 0
  # Sweep dead spawn markers on EVERY tick — ABOVE the queue-empty fast exits below. A project with an
  # idle spawn queue still dispatches resolvers, and a `.spawn-inflight-resolve-*` corpse left here
  # keeps exempting its (possibly recycled) pid from bin/herd's duplicate-watcher reap.
  _spawn_inflight_sweep
  local _dsq_q="$TREES/spawn-queue"
  [ -d "$_dsq_q" ] || return 0
  ls "$_dsq_q"/*.req >/dev/null 2>&1 || return 0   # fast exit when queue is empty
  # This tick's ONE launch slot. Taken already when a lane launched by an earlier tick is still
  # running (its intent is claimed, its outcome not yet observed) — the pre-HERD-237 foreground drain
  # could not have started a second lane there either.
  local _dsq_can_launch=1
  _lane_spawn_inflight && _dsq_can_launch=0

  # Daily-budget governance (HERD-95): PAUSE draining when today's recorded spend has EXCEEDED
  # BUDGET_DAILY. The lanes refuse a spawn individually too, but pausing the drain here stops the
  # watcher from feeding the queue into those refusals every tick and burning claim churn. The pause is
  # journaled ONCE per continuous over-budget stretch ($_BUDGET_DRAIN_PAUSED) and cleared when spend
  # falls back under the ceiling. DORMANT when BUDGET_DAILY is empty (budget_daily_exceeded returns 1
  # with no work) → byte-identical to before. HERD_FORCE_SPAWN=1 on the watcher overrides the pause.
  if [ "${HERD_FORCE_SPAWN:-}" != "1" ]; then
    local _dsq_over
    if _dsq_over="$(budget_daily_exceeded)"; then
      if [ "$_BUDGET_DRAIN_PAUSED" != "1" ]; then
        journal_append budget_drain_paused spent "${_dsq_over%% *}" budget "${_dsq_over##* }"
        _BUDGET_DRAIN_PAUSED=1
      fi
      return 0
    fi
  fi
  if [ "$_BUDGET_DRAIN_PAUSED" = "1" ]; then
    journal_append budget_drain_resumed
    _BUDGET_DRAIN_PAUSED=""
  fi

  # Budget = pipeline cap minus currently active worktrees (FEATS already computed this tick).
  # HERD-159: sanitize via herd_numeric (or a pure case fallback when the helper is unavailable —
  # hermetic tests extract this function alone). Raw ${REVIEW_CONCURRENCY}+${SPAWN_AHEAD}
  # arithmetic aborts on a non-numeric typo and freezes the spawn queue.
  local _dsq_cap _dsq_budget _dsq_rc _dsq_sa
  if type herd_numeric >/dev/null 2>&1; then
    _dsq_rc="$(herd_numeric REVIEW_CONCURRENCY 2)" || true
    _dsq_sa="$(herd_numeric SPAWN_AHEAD 1)" || true
  else
    _dsq_rc="${REVIEW_CONCURRENCY:-2}"; case "$_dsq_rc" in ''|*[!0-9]*) _dsq_rc=2 ;; esac
    _dsq_sa="${SPAWN_AHEAD:-1}";       case "$_dsq_sa" in ''|*[!0-9]*) _dsq_sa=1 ;; esac
  fi
  _dsq_cap=$(( _dsq_rc + _dsq_sa ))
  _dsq_budget=$(( _dsq_cap - ${#FEATS[@]} ))
  [ "$_dsq_budget" -le 0 ] && return 0

  local _dsq_n=0 _dsq_held=()
  while [ "$_dsq_n" -lt "$_dsq_budget" ]; do
    # Claim one intent via spawn-step.sh (atomic rename, stale-reclaim, immediate return).
    # Payload lines: slug, lane, tracker ref (HERD-64; empty for an untracked/older intent), after
    # dependency (HERD-94; empty for none), then the task as EVERYTHING after them. The ref AND after
    # lines are ALWAYS present so this positional read stays fixed.
    local _dsq_line1="" _dsq_slug="" _dsq_lane="" _dsq_ref="" _dsq_after="" _dsq_task=""
    {
      IFS= read -r _dsq_line1
      IFS= read -r _dsq_slug
      IFS= read -r _dsq_lane
      IFS= read -r _dsq_ref
      IFS= read -r _dsq_after
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
        # HERD-94 dependency hold: an intent with after=<slug|pr#> waits until that dependency shows
        # MERGED. Unmet → DEFER: keep the claim (so this tick's later `next` calls skip it) and stash it
        # for an end-of-tick release; record + journal the hold ONCE. Crucially we do NOT spend budget
        # (_dsq_n unchanged) or `break`, so independent younger intents keep draining past a held one.
        local _dsq_id; _dsq_id="$(basename "${_dsq_claimed%.req.mine}")"
        if [ -n "$_dsq_after" ] && ! _spawn_dep_merged "$_dsq_after"; then
          _spawn_mark_held "$_dsq_id" "$_dsq_slug" "$_dsq_lane" "$_dsq_after"
          _dsq_held+=("$_dsq_claimed")
          continue
        fi
        # The launch slot is already spent this tick (a lane is running). Release this intent with the
        # dependency-held ones and re-claim it next tick — FIFO order is preserved by the INTENT_ID
        # filenames. It still SPENDS budget, so a long queue is walked at most _dsq_budget deep per
        # tick, exactly as the foreground drain walked it. Checked ABOVE the spawn_released announce
        # so a release is only ever announced on the tick that acts on it.
        if [ "$_dsq_can_launch" != "1" ]; then
          _dsq_held+=("$_dsq_claimed")
          _dsq_n=$(( _dsq_n + 1 )); continue
        fi
        # Dependency met (or none). If this intent had been held on a prior tick, announce the release
        # (spawn_released, dependency named) and clear its hold row before it spawns below.
        if [ -n "$_dsq_after" ] && [ -n "$(_spawn_held_epoch "$_dsq_id")" ]; then
          journal_append spawn_released slug "$_dsq_slug" lane "$_dsq_lane" after "$_dsq_after"
          _spawn_clear_held "$_dsq_id"
        fi
        # Launch the lane in the BACKGROUND (HERD-237). The worker observes the lane's output + exit
        # status and only then consumes/releases the intent, so the PR #151 durability contract is
        # unchanged; the tick just no longer waits for it. The marker keeps the worker out of
        # `_list_project_watchers` and holds the launch slot shut until the lane lands.
        _SPAWN_DISPATCH_SEQ=$(( ${_SPAWN_DISPATCH_SEQ-0} + 1 ))
        _spawn_inflight_bg "$(_spawn_inflight_file lane "$_dsq_slug" "${_dsq_id}-${_SPAWN_DISPATCH_SEQ}")" \
          _drain_lane_worker "$_dsq_claimed" "$_dsq_slug" "$_dsq_lane" "$_dsq_ref" "$_dsq_task"
        # BIND THE CLAIM TO THE WORKER (HERD-237), synchronously, before this tick continues.
        # `spawn-step.sh next` reclaims any claim older than five minutes, on the premise that only a
        # dead watcher leaves one behind — true while the lane ran in this loop's foreground, false now
        # that the worker holds the claim for the lane's whole duration. Recording the worker's pid
        # makes that reclaim liveness-aware, so a lane slower than five minutes (a slow clone, a wedged
        # driver call — the exact fault this design exists to tolerate) is never re-served and launched
        # a second time underneath us. If the worker already finished, `own` refuses (exit 3) rather
        # than leave a sidecar for a consumed intent; the 5-minute clock makes that window unreachable
        # by any reclaim anyway.
        bash "$HERE/spawn-step.sh" own "$_dsq_claimed" "$_SPAWN_INFLIGHT_BG_PID" >/dev/null 2>&1 || true
        _dsq_can_launch=0
        _dsq_n=$(( _dsq_n + 1 ))
        ;;
    esac
  done
  # Release every dependency-held intent back to .req for a later tick. They were kept claimed only so
  # `next` skipped them this tick; releasing preserves the .after (+ .ref) sidecar so the hold — and its
  # accruing stall TTL — survives. Order is preserved: they re-enter under their original INTENT_ID
  # filenames, which sort oldest-first, so FIFO among releasable intents holds.
  if [ "${#_dsq_held[@]}" -gt 0 ]; then
    local _dsq_h
    for _dsq_h in "${_dsq_held[@]}"; do
      bash "$HERE/spawn-step.sh" release "$_dsq_h" >/dev/null 2>&1 || true
    done
  fi
}

_ORPHAN_SWEEP_TICK=0
_ORPHAN_SWEEP_INTERVAL=15   # sweep every ~60 s (15 × 4 s sleep)
_TRACKER_SWEEP_TICK=0
_TRACKER_SWEEP_INTERVAL=45  # tracker-state self-heal every ~3 min (45 × 4 s sleep) — cheap + advisory
_PMS_SWEEP_INTERVAL=45      # post-merge hook reconcile (HERD-232) every ~3 min — one `gh pr list`, then
                            # a run-once ledger hit per PR. Shares the tracker sweep's cadence class:
                            # the drift it catches (a foreign/crashed merge's unrun hooks) is a rare
                            # merge-tail condition, not a per-tick one
_PMS_SWEEP_TICK=$_PMS_SWEEP_INTERVAL  # PRIMED so the FIRST tick sweeps, then every interval. The
                            # grounding incident is a watcher that died mid-do_merge: the restart that
                            # follows is exactly when the stranded hooks must be replayed, so a fresh
                            # process must not idle 3 min before noticing. (This is the cadence sibling
                            # of the one-shot _startup_reap_sweep above, which covers worktrees only.)
_MAIN_CI_SCAN_TICK=$_MAIN_CI_SCAN_INTERVAL  # HERD-334: primed so the FIRST MAIN_HEALTH_TICK=on tick probes branch CI, then every interval
_ENGINE_TICK=0
_ENGINE_INTERVAL=75         # engine auto-update check every ~5 min (75 × 4 s sleep). Byte-inert unless
                            # ENGINE_AUTOUPDATE=auto AND the engine is stale; the dispatch itself is
                            # further rate-limited by engine-version.sh's cooldown (HERD-179)
_INBOX_SCAN_INTERVAL=15     # HERD-184: operator-inbox refresh every ~60 s (15 × 4 s sleep) — the network
                            # reads (gh pr comments + tracker) never ride the 4 s repaint
_INBOX_SCAN_TICK=$_INBOX_SCAN_INTERVAL  # primed so the FIRST enabled tick scans, then every interval
_ADOPT_SCAN_INTERVAL=15     # HERD-369: adopt-remote-PRs scan every ~60 s (15 × 4 s sleep) — the fetch +
                            # worktree-add mutation never rides the 4 s repaint
_ADOPT_SCAN_TICK=$_ADOPT_SCAN_INTERVAL  # primed so the FIRST enabled tick scans, then every interval
_FINISH_STALL_SCAN_INTERVAL=15   # HERD-402: finish_stall_scan journal summary every ~60 s (15 × 4 s
                                  # sleep) — mirrors adopt_scan's cadence (HERD-388); only the summary
                                  # emission is throttled, the leg's own detection/action still runs
                                  # every tick (see the FEATS loop's _reconcile_finish_stall call)
_FINISH_STALL_SCAN_TICK=$_FINISH_STALL_SCAN_INTERVAL  # primed so the FIRST enabled tick emits, then every interval

# ENGINE WATCHDOG state (HERD-306) — the resident supervisor's fault memory across ticks. There is no
# bash action-pass fallback anymore: _engine_tick_watchdog runs the sole (Python) engine core, RETRIES
# a fault _ENGINE_TICK_RETRIES× with an _ENGINE_BACKOFF_BASE-second step, and after _ENGINE_FAULT_MAX
# consecutive faulty ticks declares the engine DOWN loudly (banner + engine_down journal + one notify),
# resetting on the first clean tick. Tuned for a ~4 s loop: 3 in-tick attempts, 3 faulty ticks (~tens of
# seconds) before the alarm — long enough to ride out a transient, short enough to be noticed.
_ENGINE_FAULT_STREAK=0      # consecutive faulty ticks (reset to 0 on any clean Python tick)
_ENGINE_FAULT_MAX=3         # declare 'engine down' after this many consecutive faulty ticks
_ENGINE_TICK_RETRIES=3      # in-tick attempts of the Python live tick before the tick counts as faulted
_ENGINE_BACKOFF_BASE=2      # seconds; in-tick backoff between attempts is attempt × this (2 s, 4 s)
_ENGINE_DOWN_DECLARED=""    # set once the loud engine-down posture is active; cleared on recovery
_HERD_ENGINE_TICK_LAST_ERR="" # last non-empty stderr line from the Python live tick (HERD-345); cleared on clean tick
_ENGINE_PAUSE_DECLARED=""   # HERD-347: set while the operator ENGINE_PAUSE banner/journal/notify is active; cleared on resume

# One-shot at STARTUP: resume teardown for any worktree whose PR merged but whose reap never ran
# (HERD-91 — the crash-between-merge-and-reap window). Runs once here, BEFORE the live loop, so a
# stranded worktree + idle builder tab is cleaned up on restart rather than lingering forever.
_startup_reap_sweep

# One-shot at STARTUP: this process just loaded the engine code that is on disk NOW, so any pending
# "main pulled new engine code — restart recommended" note (HERD-233) has been satisfied by the very
# restart that got us here. Drop it, or the row would outlive the condition it warns about.
rm -f "$MAIN_FRESH_RESTART" 2>/dev/null || true

# …and the SAME reasoning for its sibling (HERD-259): a restart re-validates the restart note but used
# to inherit $MAIN_FRESH_STATE unread, so a MAIN-STALE row whose divergence a human had already resolved
# came back with the new process. Both freshness rows are now derived from observed state at startup.
# (The tick loop re-derives it before every render too; this one-shot is what makes the FIRST paint of a
# new process honest, since nothing else has run yet.)
_main_fresh_recheck

# One-shot at STARTUP: reconcile the reviewer dispatch registry (HERD-113). After a herdr death+reload
# or a watcher restart, a reviewer pane can outlive its poller: this retires such orphaned/completed
# panes and clears their markers so a re-dispatch is clean and never duplicates a still-live reviewer.
# Byte-inert when there are no reviewer rows (the common startup) — no journal line, no pane touched.
_sweep_reviewer_registry

# One-shot at STARTUP: proactively close any STALE resolve·<slug> conflict-resolver tab (HERD-54) —
# a resolver that died/finished for a slug whose PR is no longer CONFLICTING. Prime AGENTS_JSON first
# so the shared _resolver_agent_alive liveness check (a live resolver is always spared) has a roster.
AGENTS_JSON="$(herd_driver_agent_list_json 2>/dev/null || echo '{}')"
_sweep_stale_resolve_tabs

while true; do
  _tick_render_reconcile
  sleep 4
done
