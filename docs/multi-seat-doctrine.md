# The multi-seat doctrine

herdkit is worked by **many coordinator seats at once** — several operators, each with their own
watcher, builders, and merges, against the same repo. A behavior that is correct with one seat and
wrong with three is the single most common source of mid-run interruptions. Two rules keep the fleet
uninterrupted; both are enforced surfaces, not aspirations (the coordinator SOP's check 7, and the
pre-merge review checklist at `.herd/review-checklist.md`).

## Rule 1 — Prefer reconciled invariants over event side-effects

State a behavior as an **invariant reconciled every tick against observed state**, not as a side
effect that only fires when *this* seat/watcher happens to perform the triggering action. If the only
thing that repairs a condition is the seat that caused it, then every other seat's action leaves the
condition unrepaired.

The test: *does this hold regardless of which seat performed the triggering event?*

**Incident evidence**

- **HERD-218 — codemap goes stale after another seat's merge.** `refresh_codemap` used to fire only
  from `do_merge`, so a seat only refreshed `docs/codemap.md` for merges *it* performed; when another
  seat's watcher (or the gh UI) merged, this seat's next builder was spawned against a stale map.
  The invariant form — now implemented as `reconcile_map_freshness` on every watcher tick — is:
  *the committed map matches the tree at `$MAIN`* — probed via `codemap.sh --check` /
  `symbol-index.sh --check` against observed `$MAIN`, repaired whenever it drifts with
  `provenance=reconcile`, no matter who merged. The do_merge refresh remains the local-merge fast path.
- **HERD-233 — the `$MAIN` checkout itself goes stale after another seat's merge.** The only
  fast-forward of `$MAIN` lived inside `do_merge` (plus one riding the `CODEMAP_AUTOREFRESH` lever),
  so another seat's merges left this watcher 22 commits behind — running the *engine code it loads
  from there* — and a rejected generated-map push stranded `$MAIN` diverged until a human rebased.
  The invariant form — `reconcile_main_freshness` on every watcher tick, independent of any lever —
  is: *`$MAIN` equals `origin/<default>`* — fast-forwarded when behind (`main_ff`), healed when the
  only local commits are the engine's own regenerable maps (`main_heal`), and otherwise HELD with a
  loud console row rather than guessed at. A pull that carries new `agent-watch.sh` also notes that
  the running watcher is now stale code until restarted.
- **HERD-164 — retirement as an event handler.** Retiring a pane/worktree ran as a handler on the
  merge the seat performed, so panes belonging to work merged elsewhere were never retired. The
  invariant form: *no pane/worktree exists for a branch already merged into `$MAIN`* — evaluated
  against observed state each tick.

## Rule 2 — One shared deterministic check, enforced identically at every surface

When a rule gates work, implement it **once** and reuse that one implementation at **every**
enforcement surface — the builder's pre-PR light profile *and* the merge gate. Do not write a second
copy per surface, and do not leave the rule as prose the builder is expected to judge for itself.
A rule enforced only downstream converts into a bounced PR and a wasted builder run.

The test: *is any new check a single shared implementation, reused at every enforcement surface?*

**Incident evidence**

- **HERD-220 / PR #328 — caps-sync gate-only.** The caps-sync guard (a diff that adds a `cmd_*`
  subcommand, a config key, or a lane script must also touch `templates/capabilities.tsv`) lives in
  `.herd/healthcheck.project.sh:484`, which only the heavy merge-gate profile runs. The builder's
  light pre-PR profile cannot see it, so PR #328 was authored clean, passed locally, and bounced at
  the gate. Either the check runs at both surfaces from one implementation, or it is not a check the
  builder can satisfy.

## Why this is doctrine and not style

The goal is **many coordinator seats working this repo in parallel, uninterrupted, with minimal
issues**. A seat-local side effect and a per-surface duplicate both look correct in a single-seat
test and both fail the moment a second seat exists. Under Rule 1 a stale condition self-heals on the
next tick regardless of who caused it; under Rule 2 a violation is impossible to author rather than
expensive to discover. Treat merge-performer-dependent behavior and per-surface duplicate checks as
**correctness defects**, not as cleanups.

## The program pattern — the doctrine's work-organization arm

The two rules above keep *the engine* seat-independent; the **program pattern** keeps *the work* seat-
independent, and it is the same argument one layer up. A multi-item effort is filed as an **epic** (goal,
phases, child list) whose long-form evidence is a **committed doc**, and every child carries a one-line
backlink to both. The alternative — the effort's shape living in the coordinator seat that conceived it,
and its evidence living in that seat's transcript — is a side effect of one seat, exactly what Rule 1
forbids: a second seat picking up a child cannot see the goal, cannot read the audit that grounded it,
and re-derives (or contradicts) the sequencing. Committing the evidence and slotting every child into the
epic is the reconciled-invariant form of project context: any seat, at any tick, reads the repo and the
tracker and knows the whole program. See the *Programs* section of
[`COORDINATOR-SOP.md`](COORDINATOR-SOP.md) and check 8 of the authoring SOP.

## The dual-engine window — operational prescription (engine port, P3.5)

Rules 1 and 2 assume every seat runs the **same engine**. The engine port (HERD-300) breaks that
assumption for one bounded window: between P3 (a Python watcher runs beside the bash one) and P5
(cutover), two *different* engine implementations — or the same operator on two checkouts at different
levels — can write the **same worktree pool** at once. Two engines at different behavior levels
silently coexisting is the hazard: the newer one writes a format or semantics the older one then
clobbers, and the corruption (a half-migrated state store, a mis-shaped journal row, a claim written
two different ways) surfaces later, in the queue. The invariant form (HERD-308) is:

> **Every mutable-state write under the pool carries its writer's engine level, reconciled every
> watcher tick. Two distinct levels writing one pool is never silent — the stale seat halts loudly,
> so there are zero cross-mismatch writes.**

This is Rule 1 applied to the engine itself: the check is a per-tick reconcile against observed pool
state (`herd_engine_seat_reconcile` in [`scripts/herd/engine-seat.sh`](../scripts/herd/engine-seat.sh)),
not a side effect of whichever seat happens to write. It is enforced through one shared stamp
(`herd_engine_seat_stamp`) that the bash watcher calls today and the pysrc store accessors adopt
verbatim in P4, so the two implementations reconcile against a **single format**.

**The prescription — set these on every seat before opening the dual-engine window:**

1. **`ENGINE_AUTOUPDATE=check`** — every seat's console + `herd doctor` surface when the local engine
   has fallen behind the project's `ENGINE_MIN`, so no seat runs stale without saying so. (`auto` is
   also fine — it pulls the engine forward in a quiescent window — but `check` is the floor: never
   leave a fleet seat on `off` during the window.)
2. **`WATCHER_SELF_RESTART=on`** — when a seat pulls new engine code, its watcher quiesces and
   re-execs in place onto the new code, instead of running the old image against a config that now
   expects the new behavior. Without it, a seat that updated its checkout keeps running the *loaded*
   old code until a human restarts it — exactly the stale-writer the reconcile then has to halt.
3. **Bump `ENGINE_MIN` at every phase flip.** When a phase lands behavior a project's config or lanes
   come to depend on, raise `_HERD_ENGINE_LEVEL` in the same PR and stamp the project floor
   (`herd upgrade` does this monotonically). This makes an older checkout **refuse to write** rather
   than merely coexist — the handshake (HERD-179) and the pool reconcile (HERD-308) are complementary:
   the handshake stops a stale engine writing against a *pinned* project; the reconcile stops two
   engines writing one *pool* even before a floor is pinned.

**Enabling the pool reconcile:** set `ENGINE_SEAT_RECONCILE=on` on every seat sharing the pool. It is
ship-dormant (default `off`, a hard no-op) and inert for a single seat, so it costs nothing until a
second engine actually appears; turn it on for the whole window.

**Running a P4 store migration:** the migration runner must cross `herd_engine_migration_guard` first
— it refuses unless every other registered seat has **quiesced** (`herd_engine_seat_quiesce`) or an
operator has declared a deliberate **dual-write window** (`HERD_ENGINE_DUALWRITE=1`, journaled). A
migration never races a live engine writing the store.

Keep the window **short** (the epic's own risk note): the reconcile keeps it *safe*, but two engines
to keep honest is still two engines. See the P3.5 leg of
[`docs/spikes/engine-port-python.md`](spikes/engine-port-python.md).

## Where this is enforced

- **Authoring** — coordinator skill, *Authoring a backlog item* SOP, check 7 (MULTI-SEAT /
  INVARIANCE) and check 8 (PROGRAM). Source: `templates/coordinator.md.tmpl` (`herd render` renders it).
- **Review** — `.herd/review-checklist.md` (the `REVIEW_CHECKLIST` key in `.herd/config`), injected
  into the adversarial pre-merge review gate `herd-review.sh`.
- **Operations** — see [`COORDINATOR-SOP.md`](COORDINATOR-SOP.md) for the seat/watcher roles this
  doctrine constrains, and [`codemap.md`](codemap.md) for the module map.
- **Evidence** — incident evidence + hardening program: [`docs/audits/2026-07-09-gating-hardening.md`](audits/2026-07-09-gating-hardening.md).

Tracked as HERD-219.
