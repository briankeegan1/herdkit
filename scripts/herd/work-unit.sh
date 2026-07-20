#!/usr/bin/env bash
# work-unit.sh — the work-unit delivery abstraction facade (HERD-395/HERD-396/HERD-398). Phase 1 NAMED
# the spine; Phase 3 (HERD-398) MOVED the git-pr implementations behind it into
# scripts/herd/work-units/git-pr.sh, selected by WORK_UNIT_KIND. Full design:
# docs/spikes/work-unit-abstraction.md (interface at ~2.2, git-pr adapter table at ~2.3, phased
# migration at ~5, Phase 1 at ~396-405, Phase 3 at ~414-419, post-port amendment at ~9).
#
# WHY: herdkit's "work unit" is today a git PR end-to-end (open → gate → apply → reconcile →
# teardown, all PR-shaped through agent-watch.sh). The spike proposes a thin work-unit interface so a
# future non-PR kind (doc-apply, config-apply, …) can plug into the SAME pipeline. Phase 1 is the
# facade only: call sites CAN say `wunit_*` while the git-pr adapter body stays a pure move/rename —
# every wrapper below is a ONE-LINE delegation to the function or `gh` invocation that already IS
# today's git-pr path. No new behavior, no new config key. That is the HARD invariant this file exists
# to keep: with a wrapper unused, the engine's observable output is byte-identical to before it.
#
# REFERENCE-MODEL-ONLY VS. LIVE (P5, HERD-404 — read this before touching a wrapper below): the spike's
# post-port amendment (§9.1) found that HERD-306 (the Python engine-port finale) deleted the bash tick's
# action pass BEFORE HERD-401 (Phase 3b) went looking for a production call site to rewire through this
# facade. The result is a SPLIT, not a uniform seven wrappers:
#   • wunit_open / wunit_list_open / wunit_inspect / wunit_gate / wunit_apply — REFERENCE-MODEL-ONLY.
#     Zero production call sites (grep the tree: only tests/sim call them). Discovery, gate, and apply
#     now run live in pysrc/herd/live_runtime.py (_GraphQLDiscovery, LiveGates, LiveActuator) — a
#     Python reimplementation, not a caller of these wrappers. These five stay real and exercised (the
#     sim scenario suite + tests/test-work-unit.sh, tests/test-work-unit-kind.sh,
#     tests/test-work-unit-conformance.sh) because they ARE the semantic reference the spike's interface
#     was designed against and the python side (pysrc/herd/work_unit.py) is checked against — just not
#     the code path production traffic runs through.
#   • wunit_reconcile / wunit_teardown — LIVE. Called every merge by agent-watch.sh's
#     `_pms_reconcile_one` (:7724, :7726) and by `_startup_reap_sweep` (:6926), regardless of which
#     engine (bash or Python, on whichever seat) performed the merge — these two legs are POST-MERGE
#     sweep concerns that must fire identically either way, so they never moved to Python. See
#     agent-watch.sh:134-147 for the fuller account of what did and did not cross to Python.
#
# THE SEVEN OPS (spike 2.2) map onto today's git-pr functions (spike 2.3) 1:1:
#   wunit_open       <gh pr create argv…>        → gh pr create           (builder's open path)              [reference-model-only]
#   wunit_list_open  <gh pr list argv…>           → gh pr list             (tick discovery)                   [reference-model-only]
#   wunit_inspect    <gh pr view argv…>           → gh pr view             (body/state/checks)                [reference-model-only]
#   wunit_gate       <pr#> <sha>                  → _cand_gates_ready      (health+review readiness)          [reference-model-only]
#   wunit_apply      <slug> <pr#> <worktree> [sha]→ do_merge               (merge + post-merge hooks)         [reference-model-only]
#   wunit_reconcile  <pr#> <slug> [sha]           → reconcile_backlog      (tracker mark-done)                [LIVE]
#   wunit_teardown   <slug> <dir> [pr#] [sha] [reason] → _reap_slug        (worktree/ledger release)          [LIVE]
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

_WUNIT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ── borrow agent-watch.sh's function bank (git-pr adapter body) ────────────────────────────────────
if ! command -v do_merge >/dev/null 2>&1; then
  # shellcheck disable=SC2034  # read by agent-watch.sh's own lib-mode guard on the next line
  AGENT_WATCH_LIB=1
  # shellcheck source=/dev/null
  . "$_WUNIT_HERE/agent-watch.sh"
  unset AGENT_WATCH_LIB
fi

# ── borrow journal.sh's unit-ref composer if not already in scope ──────────────────────────────────
# The common path above already pulls this in (agent-watch.sh sources journal.sh), so this is a
# no-op there. It only fires for a caller that pre-defines do_merge (skipping the borrow above)
# without having sourced journal.sh itself — makes wunit_ref's dependency explicit rather than
# conventional (HERD-397 review: a bare "already in scope by convention" comment left it unasserted).
if ! command -v journal_unit_ref >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$_WUNIT_HERE/journal.sh"
fi

# ── resolve — validate a work-unit kind against what this build actually implements ────────────────

# wunit_resolve_adapter [kind] — validate a work-unit kind (arg1, else WORK_UNIT_KIND, else "git-pr")
# against what this build actually implements. Phase 3 (HERD-398) ships EXACTLY one adapter — git-pr
# (scripts/herd/work-units/git-pr.sh) — already loaded by the borrow block above, so every wunit_*
# wrapper below already IS the git-pr adapter body; this resolver is for a caller that wants to ASK
# "is <kind> supported" before routing through the facade (a future per-spawn WORK_UNIT_KIND override).
# UNLIKE agent-watch.sh's own boot-time WORK_UNIT_KIND check (herd-config.sh/agent-watch.sh: fails
# STRICT to git-pr with a loud warning, because the watcher itself must keep running through a config
# typo), this is a HARD refusal: prints the resolved kind on stdout and returns 0 for "git-pr"; prints
# a loud not-yet-supported message on stderr and returns 1 for anything else. There is no second
# adapter to fall back to here, so silently resolving an unimplemented kind to git-pr would be a lie
# this facade's whole purpose is to prevent.
wunit_resolve_adapter() {
  local _wra_kind="${1:-${WORK_UNIT_KIND:-git-pr}}"
  case "$_wra_kind" in
    git-pr)
      printf 'git-pr'
      return 0
      ;;
    *)
      printf '❌ herdkit: work-unit kind "%s" is not supported — the BASH facade ships exactly one kind, "git-pr", forever (doc-apply is a PYTHON-only adapter, HERD-399/pysrc/herd/work_unit.py; see spike §9.4 for why bash never gets a second kind).\n' "$_wra_kind" >&2
      return 1
      ;;
  esac
}

# ── open / list_open / inspect — passthrough to `gh pr …` (today's git-pr open + discovery path) ──

# wunit_open [gh pr create args…] — publish a candidate delivery. Today's git-pr path is literally
# `gh pr create` (PR_CREATE_CMD in herd-feature.sh/herd-quick.sh is this same command, run by the
# builder's own shell — there is no engine function to delegate to besides `gh` itself).
# REFERENCE-MODEL-ONLY (spike §9.1): zero production call sites — the builder's own shell still runs
# `gh pr create` directly via PR_CREATE_CMD, never through this wrapper. Exercised by
# tests/test-work-unit.sh + the sim scenario suite, not by any live caller.
wunit_open() {
  gh pr create "$@"
}

# wunit_list_open [gh pr list args…] — the tick's candidate-set query.
# REFERENCE-MODEL-ONLY (spike §9.1): superseded live by pysrc/herd/live_runtime.py's
# `_GraphQLDiscovery` (one batched GraphQL round-trip, not `gh pr list`). agent-watch.sh's own tick
# discovery deliberately does NOT call this wrapper either — see agent-watch.sh:12794 for why (its argv
# carries fields this raw passthrough cannot express).
wunit_list_open() {
  gh pr list "$@"
}

# wunit_inspect [gh pr view args…] — read one unit's state/body/checks.
# REFERENCE-MODEL-ONLY (spike §9.1): the live engine's discovery round-trip already bundles every
# inspect-shaped field, so `pysrc/herd/work_unit.py`'s `GitPrAdapter.inspect` returns the candidate
# `list_open` already produced instead of a separate fetch — there is no live caller of this wrapper.
wunit_inspect() {
  gh pr view "$@"
}

# ── gate — delegates to the existing composite readiness check ─────────────────────────────────────

# wunit_gate <pr#> <sha> — readiness for THIS revision, read from the SAME ledgers the watcher's own
# merge-eligibility check reads (no dispatch, no gh, no git — _cand_gates_ready is itself read-only).
# Maps its boolean onto the spike's gate_result.status vocabulary (pass|hold|block|wait|error):
# ready → pass; not-yet-ready (no cached verdict yet, or an unoverridden BLOCK) → wait. Thin by
# construction: this wrapper invents no new gate logic, it only names the existing one.
# REFERENCE-MODEL-ONLY (spike §9.1): live gate readiness runs through `LiveGates.health`/`.review`
# (pysrc/herd/live_runtime.py), composed by `pysrc/herd/work_unit.py`'s `GitPrAdapter.gate` into the
# fuller pass|hold|block|wait|error vocabulary this wrapper's 2-state boolean is a subset of — see
# tests/test-work-unit-conformance.sh for the tie asserting the two never drift apart. agent-watch.sh's
# own re-verify tick also deliberately does NOT call this wrapper (agent-watch.sh:3974) — its
# pass/wait print would leak into a console stream this caller does not want it in.
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
# REFERENCE-MODEL-ONLY (spike §9.1, HERD-401's filed finding): `do_merge` has ZERO production call
# sites — HERD-306 (the Python engine-port finale) deleted the bash tick's action pass that used to
# call it before this wrapper had a chance to be rewired in. Live merge-or-apply runs through
# `LiveActuator.merge` (pysrc/herd/live_runtime.py), wrapped by `pysrc/herd/work_unit.py`'s
# `GitPrAdapter.apply` — a Python reimplementation, not a caller of this wrapper or of `do_merge`.
wunit_apply() {
  do_merge "$@"
}

# wunit_reconcile <pr#> <slug> [sha] — mark the linked work item done (explicit ref first, fuzzy
# scribe fallback) via the existing post-merge hook.
# LIVE (spike §9.1): called every merge by agent-watch.sh's `_pms_reconcile_one` (agent-watch.sh:7724),
# regardless of which engine (bash or Python, on whichever seat) performed the merge — reconcile is a
# post-merge sweep concern the Python engine never took over.
wunit_reconcile() {
  reconcile_backlog "$@"
}

# wunit_teardown <slug> <dir> [pr#] [sha] [reason] — release isolation resources for this unit.
# LIVE (spike §9.1): called every merge by agent-watch.sh's `_pms_reconcile_one` (agent-watch.sh:7726)
# and by the startup reap-sweep, `_startup_reap_sweep` (agent-watch.sh:6926) — same reasoning as
# wunit_reconcile above; teardown never moved to Python either.
wunit_teardown() {
  _reap_slug "$@"
}

# ── ref — the shared unit-id composer (HERD-397, Phase 2 dual-write) ───────────────────────────────

# wunit_ref <kind> <id> — compose a namespaced unit ref, e.g. `wunit_ref git-pr 42` → "git-pr:42".
# Delegates to journal.sh's journal_unit_ref, which the borrow block above GUARANTEES is in scope
# (explicitly sourced if not already, not left to convention). This file never re-derives the format
# itself — journal_unit_ref is THE single place it is composed, so the ref this facade hands out and
# the ref journal.sh's own pr→unit dual-write writes to every journal event can never diverge (spike
# docs/spikes/work-unit-abstraction.md §2.2 unit_id).
wunit_ref() {
  journal_unit_ref "$@"
}
