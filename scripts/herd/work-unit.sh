#!/usr/bin/env bash
# work-unit.sh — Phase 1 of the work-unit delivery abstraction (HERD-395/HERD-396): NAME the spine,
# implement nothing new. Full design: docs/spikes/work-unit-abstraction.md (interface at ~2.2,
# git-pr adapter table at ~2.3, phased migration at ~5, Phase 1 at ~396-405).
#
# WHY: herdkit's "work unit" is today a git PR end-to-end (open → gate → apply → reconcile →
# teardown, all PR-shaped through agent-watch.sh). The spike proposes a thin work-unit interface so a
# future non-PR kind (doc-apply, config-apply, …) can plug into the SAME pipeline. Phase 1 is the
# facade only: call sites CAN say `wunit_*` while the git-pr adapter body stays a pure move/rename —
# every wrapper below is a ONE-LINE delegation to the function or `gh` invocation that already IS
# today's git-pr path. No new behavior, no new config key, no existing caller switched over in this
# PR (grep the tree: nothing calls wunit_* yet). That is the HARD invariant this file exists to keep:
# with the facade unused, the engine's observable output is byte-identical to before it.
#
# THE SEVEN OPS (spike 2.2) map onto today's git-pr functions (spike 2.3) 1:1:
#   wunit_open       <gh pr create argv…>        → gh pr create           (builder's open path)
#   wunit_list_open  <gh pr list argv…>           → gh pr list             (tick discovery)
#   wunit_inspect    <gh pr view argv…>           → gh pr view             (body/state/checks)
#   wunit_gate       <pr#> <sha>                  → _cand_gates_ready      (health+review readiness)
#   wunit_apply      <slug> <pr#> <worktree> [sha]→ do_merge               (merge + post-merge hooks)
#   wunit_reconcile  <pr#> <slug> [sha]           → reconcile_backlog      (tracker mark-done)
#   wunit_teardown   <slug> <dir> [pr#] [sha] [reason] → _reap_slug        (worktree/ledger release)
#
# CONTRACT (mirrors engine-seat.sh / merge-policy.sh):
#   • SOURCED, never executed. Defines functions only; sourcing has no side effect.
#   • The four function-delegating ops (gate/apply/reconcile/teardown) call BASH FUNCTIONS that live
#     in agent-watch.sh. Rather than duplicate them, this file borrows agent-watch.sh's own
#     "source it in LIB mode if not already in scope" seam (sweep.sh / retirement.sh precedent):
#     if `do_merge` is not yet a known command, source agent-watch.sh with AGENT_WATCH_LIB=1 (functions
#     only, no tick loop). A caller — or a test — that has ALREADY defined `do_merge` (the real one, by
#     sourcing agent-watch.sh itself, or a fixture stub) is left untouched; this file never redefines
#     it and never sources agent-watch.sh twice.
#   • The three `gh`-delegating ops (open/list_open/inspect) pass their argv straight through to `gh
#     pr …` — no flag translation, no default injection — so a caller gets EXACTLY today's `gh`
#     invocation and exit code.
#   • Fail-soft only where the underlying op already is: a wrapper never adds a new failure mode; it
#     returns whatever its delegate returns.

# ── borrow agent-watch.sh's function bank (git-pr adapter body) ────────────────────────────────────
if ! command -v do_merge >/dev/null 2>&1; then
  _WUNIT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck disable=SC2034  # read by agent-watch.sh's own lib-mode guard on the next line
  AGENT_WATCH_LIB=1
  # shellcheck source=/dev/null
  . "$_WUNIT_HERE/agent-watch.sh"
  unset AGENT_WATCH_LIB
fi

# ── open / list_open / inspect — passthrough to `gh pr …` (today's git-pr open + discovery path) ──

# wunit_open [gh pr create args…] — publish a candidate delivery. Today's git-pr path is literally
# `gh pr create` (PR_CREATE_CMD in herd-feature.sh/herd-quick.sh is this same command, run by the
# builder's own shell — there is no engine function to delegate to besides `gh` itself).
wunit_open() {
  gh pr create "$@"
}

# wunit_list_open [gh pr list args…] — the tick's candidate-set query.
wunit_list_open() {
  gh pr list "$@"
}

# wunit_inspect [gh pr view args…] — read one unit's state/body/checks.
wunit_inspect() {
  gh pr view "$@"
}

# ── gate — delegates to the existing composite readiness check ─────────────────────────────────────

# wunit_gate <pr#> <sha> — readiness for THIS revision, read from the SAME ledgers the watcher's own
# merge-eligibility check reads (no dispatch, no gh, no git — _cand_gates_ready is itself read-only).
# Maps its boolean onto the spike's gate_result.status vocabulary (pass|hold|block|wait|error):
# ready → pass; not-yet-ready (no cached verdict yet, or an unoverridden BLOCK) → wait. Thin by
# construction: this wrapper invents no new gate logic, it only names the existing one.
wunit_gate() {
  if _cand_gates_ready "$@"; then
    printf 'pass\n'
    return 0
  fi
  printf 'wait\n'
  return 1
}

# ── apply / reconcile / teardown — delegate to the existing merge/reconcile/reap functions ─────────

# wunit_apply <slug> <pr#> <worktree> [sha] — land the unit (merge-or-apply). Exact argv `do_merge`
# already takes; this wrapper adds nothing.
wunit_apply() {
  do_merge "$@"
}

# wunit_reconcile <pr#> <slug> [sha] — mark the linked work item done (explicit ref first, fuzzy
# scribe fallback) via the existing post-merge hook.
wunit_reconcile() {
  reconcile_backlog "$@"
}

# wunit_teardown <slug> <dir> [pr#] [sha] [reason] — release isolation resources for this unit.
wunit_teardown() {
  _reap_slug "$@"
}

# ── ref — the shared unit-id composer (HERD-397, Phase 2 dual-write) ───────────────────────────────

# wunit_ref <kind> <id> — compose a namespaced unit ref, e.g. `wunit_ref git-pr 42` → "git-pr:42".
# Delegates to journal.sh's journal_unit_ref, which is ALREADY in scope by the time this file finishes
# loading (the agent-watch.sh borrow above transitively sources journal.sh; a caller with do_merge
# pre-defined has, by this codebase's convention, sourced journal.sh too). This file never re-derives
# the format itself — journal_unit_ref is THE single place it is composed, so the ref this facade
# hands out and the ref journal.sh's own pr→unit dual-write writes to every journal event can never
# diverge (spike docs/spikes/work-unit-abstraction.md §2.2 unit_id).
wunit_ref() {
  journal_unit_ref "$@"
}
