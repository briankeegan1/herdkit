# SPIKE: Port the engine core to Python — proposed as a phased EPIC

**Tracker:** file on Linear as an EPIC (ID TBD) — phasing below is a *proposal*; the
coordinator owns how this is decomposed, sequenced into the backlog, and whether/when each
phase is worth scheduling  
**Status:** design spike only — **no engine code changes** in this PR  
**Date:** 2026-07-10  
**Audience:** coordinator + engine maintainers  
**Grounding:** external review of the engine (2026-07-10), measured against the tree at
HEAD: `agent-watch.sh` = 12,209 lines (5,085 comment / 7,124 code), 785 command
substitutions, 103 `gh` invocations, 42 jq/python3 parse spawns, **45 distinct string-parsed
state files** guarded by hand-rolled flock/mkdir mutexes. Prior art: the health re-dispatch
fork-bomb (fixed by PR #408) is the signature bug class of shell-managed process groups.

## 0. Thesis

The workflow, gates, journal semantics, config surface, and herdr substrate are **not** in
question — they are the product and they stay. The proposal is only that the *engine core*
(watcher state machine, gate sequencing, state storage, journal readers) migrate from bash
to Python, because four structural bug factories in the current implementation stop
existing rather than being carefully avoided:

1. **State.** The 45 flat state files + mutex dance collapse into SQLite (WAL mode):
   atomic claims, transactional sha-keyed read-modify-write, no lock fallbacks. The race
   class behind the fork-bomb becomes unrepresentable. Journal stays append-only JSONL
   (greppable, rsync-able); SQLite holds *mutable* state only.
2. **Invariants.** Doctrine currently enforced by comments and discipline (row truth,
   sha-keying, refix budgets) becomes an explicit lifecycle enum + transition function —
   illegal transitions throw. Side benefit: our own review gate and healthcheck are far
   sharper on typed Python (mypy/ruff/pytest) than on bash, where shellcheck is the ceiling.
3. **Failure loudness.** bash `set -e` semantics silently skip in conditionals, command
   substitutions, and test-position calls; Python inverts the default — unhandled failure
   propagates. The "gate silently skipped, everything looked green" class mostly disappears.
4. **Concurrency.** asyncio task groups give structured concurrency — cancelling a parent
   cancels its children — the categorical fix for re-dispatch/orphan bugs. Review/health
   slots become semaphores instead of file locks.

Secondary: per-tick fork storms (hundreds of subprocesses) become in-process work with the
per-PR `gh` calls batched into one GraphQL query per tick; hermetic-world shell tests
largely become millisecond pytest units + property-based (hypothesis) checks over the state
machine; contributor surface changes kind (a ~3–5k-line typed core invites PRs; a 12k-line
bash file repels them).

## 1. Non-issues (verified, for the record)

- **herdr compatibility:** unchanged to improved. Python drives `herdr …` via subprocess
  exactly as bash does; herdr's socket API additionally allows one persistent connection
  receiving agent-state *events* instead of poll-and-scrape. The substrate never notices.
- **Performance:** the watcher is a long-lived daemon (interpreter startup is paid once);
  eliminating per-tick forks makes it lighter on CPU, not heavier. One-shot CLI starts
  ~50ms slower — imperceptible. RAM ~40MB — irrelevant.
- **Tokens:** the engine makes no model calls in either language; runtime token spend is
  identical. Self-development tokens go **down**: builders stop paying to load/edit a file
  too large to read in one pass, and review-gate diffs shrink.
- **Install burden:** zero — `python3` is already a hard dependency.
- **Why not Go:** the workload is I/O-bound (Go's speed buys nothing), python3 is already
  required (Go adds a toolchain), and the herd is more fluent in Python. Go's real edge —
  a single static binary — is herdr's distribution story, not ours.

## 2. What stays bash — permanently

Lane glue and pane spawning, git plumbing wrappers, `install.sh`, project
`healthcheck.project.sh` commands, and anything that is genuinely "run three commands in
order." The port target is the engine core only: watcher, gates, mutable state, journal
readers — roughly 25k lines of bash becoming an estimated 3–5k of typed Python.

## 3. Proposed EPIC phasing — coordinator to reorganize as it sees fit

Strangler pattern along the seams we already own (journal schema, `.herd/config`, state
files, the sim rig). Each phase ships independently, is individually abandonable, and never
breaks the bash engine. Suggested order (the coordinator may reorder, merge, split, or
park any of these; only the *shadow-mode acceptance discipline* in P3 is strongly advised):

- **P0 — contract freeze (docs only).** Write down the gate contract the port must honor:
  subject + version key in, PASS/BLOCK/ESCALATE/HOLD out, idempotence per key, journal
  event shapes, refix-budget semantics. This is the port's spec *and* independently useful
  (see the work-unit-abstraction spike — same seam).
- **P1 — read-only tools.** `herd why` / `log` / `status` / `cost` as `python -m herd.*`
  behind the existing CLI names. Zero risk, deletes ~1.5k lines, proves packaging.
- **P2 — pure decision core.** Port the already-factored pure merge-decision helper +
  sha-keying + refix-budget arithmetic as pure functions with pytest + hypothesis coverage.
  Bash watcher calls into it (or keeps its copy) — either way, parity-test the two.
- **P3 — the state machine, in shadow mode.** Python watcher runs beside the bash watcher
  in the sim rig (P0–P2a scenarios), **dry-run only**, and the acceptance gate is a journal
  diff: same inputs → same event stream. The sim rig is implementation-agnostic (it drives
  behavior through stubs, not bash internals), so it is already the cross-implementation
  acceptance suite most ports have to build first. Only after sustained parity does a
  project opt in via a flag (e.g. `ENGINE_IMPL=python`, ship-dormant per doctrine).
- **P3.5 — dual-engine safety (HERD-308, the hard gate before P4).** The moment two engines
  can write the same worktree pool, "different behavior levels silently coexisting" becomes a
  corruption source. This leg makes it unrepresentable: every mutable-state write carries its
  writer's engine level through **one shared stamp** (`scripts/herd/engine-seat.sh`), reconciled
  every watcher tick — a second level writing the pool halts the *stale* seat loudly (its
  merge/blessing writes are HELD), so there are zero cross-mismatch writes. It also ships the
  **quiesce gate** P4 depends on: `herd_engine_migration_guard` refuses a store migration unless
  every seat has quiesced or a dual-write window is declared. Ship-dormant (`ENGINE_SEAT_RECONCILE`,
  default off) and inert for a single seat. The bash stamp format is the one the P4 store accessors
  adopt verbatim. Operational prescription (`ENGINE_AUTOUPDATE=check`, `WATCHER_SELF_RESTART=on`,
  `ENGINE_MIN` bump at every phase flip) is in the *dual-engine window* section of
  [`docs/multi-seat-doctrine.md`](../multi-seat-doctrine.md).
- **P4 — state store.** Migrate the 45 state files to SQLite behind the same accessors,
  with a one-shot migration + rollback path (the migrations/ convention already exists). The
  migration runner crosses `herd_engine_migration_guard` (P3.5) first, so it never runs while
  another seat is still writing the store; the store accessors adopt P3.5's engine-level stamp.
- **P5 — cutover + deletion.** Flag flips default, bash core moves to a deprecation window,
  then deletion. Celebrate by watching `herd cost` report what the port PRs cost.

## 4. Risks the coordinator should weigh

- **Opportunity cost:** this competes with feature work (merge-result gate, forge/driver
  seams) for builder capacity. P0–P2 are cheap and hedge nothing; P3+ is the real spend.
- **Dual-engine window:** between P3 and P5 there are two implementations to keep honest —
  the journal-diff gate keeps parity, and P3.5's per-tick engine-level reconcile
  (`ENGINE_SEAT_RECONCILE`) keeps two engines from silently clobbering one pool. Keep it short.
- **Don't port the doctrine wrong:** the comments in `agent-watch.sh` are the spec of five
  months of scar tissue (row truth, positive-evidence death, once-guards). P0's contract
  doc is the mitigation — port from the *contract*, not by transliterating bash.
