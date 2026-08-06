# SPIKE: Unified machine-capacity admission control for all workload classes

**Tracker:** HERD-557 — *"DESIGN: unified machine-capacity admission control for all workload
classes."* This doc is the committed design deliverable the item calls for; cite it from HERD-557.
**Status:** P1 shipped (suites only, behind `CAPACITY_BUDGET`); P2 shipped (HERD-581 — agent spawns
join as a second ledger tenant, §6's first bullet); this doc also records the remaining P3 roadmap.
**Date:** 2026-08-05, updated 2026-08-06 (P2)
**Audience:** coordinator + engine maintainers
**Grounding:** operator diagnosis 2026-08-05 (*"this is a major design flaw then, is it not"*) after
load ~35 on 14 cores stretched a 6-minute suite to 38 minutes; external design review (`herd advise`,
gpt-5.6-sol) of the first draft of this doc, 2026-08-05, whose accepted verdict superseded that draft's
aging-based anti-starvation plan — see §5.
**Program:** capstone sibling of GATE_SCALE (HERD-542) and the HERD-529 local-suite slot machinery this
spike evolves.

## 0. Why this doc exists

Every subsystem herdkit spawns — builder lanes, builder-local suites, watcher-dispatched suites,
reviewers, resolvers, panes — independently assumes it may use the whole machine. Nothing owns total
admission. Today's governance (`LOCAL_SUITE_CONCURRENCY`, `HEALTH_CONCURRENCY`/`REVIEW_CONCURRENCY`,
`GATE_SCALE`) caps each spawner *separately*; the classes still compound (5 suites + 8 builders + 3
reviewers ≈ 80 processes on one box). A second, related flaw: fixed wall-clock timeouts make
correctness verdicts *load-sensitive* — the same code passes idle and fails busy — partially mitigated
by the HERD-546 env-suspect leg but not solved.

P1 (this PR) scopes down to the slice that was actually measured failing: **heavy suite admission** —
builder-local `healthcheck.sh --heavy` runs vs. the watcher's own dispatch, both already sharing the
HERD-529 `LOCAL_SUITE_CONCURRENCY` slot pool. P2/P3 generalize the same primitives to builder spawns,
reviews, and merges (§6).

## 1. Four pathologies

**(a) Priority inversion.** A watcher suite verifying a mergeable candidate — the thing standing
between the fleet and a merge — has no more claim on a free slot than an exploratory builder-local run.
Under contention, "whoever asked first" is not "whoever the fleet needs answered first."

**(b) Retry amplification.** HERD-546's retry-before-red re-run exists specifically to tell a *real*
code error apart from a load-induced flake. Running that re-run *at the same concurrency as everything
else* defeats its own purpose — a solo re-run contending with three other suites is not a clean signal,
so a genuinely flaky test can misclassify as CODEERROR under exactly the load that made it flaky in the
first place.

**(c) Spawning-into-idleness.** A spawn/dispatch decision made from a stale or partial view of live
load routes new work onto a box that looks idle in the decision-maker's cached picture but is not, in
reality — the decision and the admission are two different reads of "how busy is this box," taken at
different times by different code, and they drift.

**(d) Circular wait through load.** No single process deadlocks, but the *system* can still wedge:
builder-local suites saturate the box → the watcher's own suite (verifying a merge that would *free*
capacity by letting that builder retire) queues behind them → nothing retires → the saturation that
caused the wait is never relieved by anything currently running. Not a lock-graph cycle; a resource
graph one, mediated entirely by "the box is busy," which no single component can see whole.

P1 closes (a) and (b) directly for suites, and gives (c)/(d) a structural backstop (the reserved-top
slice in §2 is precisely "a unit builder-local possession can never wait (d) out"). It does not attempt
a general circular-wait proof across every class — that's P2/P3 scope once spawns and reviews are also
ledger tenants.

## 2. The lease-ledger design

### 2.1 Why priority-at-acquire-time is not enough

The obvious fix — "sort waiters by class, admit the highest-priority one next" — was the P1 draft's
first design. An external review caught the flaw before it shipped: **leases are non-preemptive.**
Priority only decides who wins a *contested* acquisition; it says nothing about a unit a lower class
already legitimately holds. A burst of builder-local suites that all arrive first still *holds the box*
regardless of what arrives after and in what priority order — "sort the queue" doesn't help a waiter
that's queued behind possession, not behind ordering. This is **possession-starvation**, and it is the
actual shape of pathology (a) under load.

Time-based **aging** (promote a long-waiting low-class lease's effective priority) was the next draft
and was also rejected, for three reasons the review gave: it still doesn't fix possession (an aged
waiter still has to wait for a *currently held* unit to free — aging changes who's *next*, not who's
*now*), it fights the RETRY-SOLO drain barrier (which needs to mean "wait for everything," not "wait
unless you've aged past it"), and it couples correctness to a wall clock the ledger has no other need
of.

### 2.2 What P1 actually builds: a hard reserved-slice partition + OS-level yield

Instead, each ledger's `cap` units are hard-partitioned, by **slot index**, into three regions:

- **reserved-top** (1 unit once `cap >= 2`) — leasable *only* by the top class present in this ledger
  (for the suites tenant: `watcher`). A builder-local burst can never touch this slot, at any queue
  depth, so a watcher suite always has a unit to admit into — possession-starvation of the top class is
  structurally impossible, not merely discouraged.
- **reserved-bottom** (1 unit once `cap >= 2`) — leasable *only* by the bottom class (`builder-local`).
  The symmetric guarantee: a watcher burst can never starve builder-local either.
- **general** (`cap - reserved_top - reserved_bottom`, often 0 at the shipped default `cap=2`) — either
  class may lease it, first-acquire-wins. No comparator is needed here: once both ends are structurally
  protected, a fair race for the middle is fine — starvation was already the thing the reserved slices
  exist to prevent.

Both thresholds require `cap >= 2`, not `cap >= 1` — an earlier draft reserved the top slot down to
`cap=1`, which turned out to be a real bug caught while writing the sim (§7): at `cap=1` there is
exactly one unit, and reserving it exclusively for `watcher` doesn't merely lower builder-local's
priority, it **excludes it from ever acquiring at all** — an unbounded hang, strictly worse than the
starvation this design exists to prevent. At `cap=1` neither reservation applies; the single unit is
"general," a fair race between classes — degenerate but safe, and identical to the flat single-slot
behavior this ledger evolved from.

`capacity_candidate_slots(class, cap)` (`scripts/herd/capacity-ledger.sh`) is the **one function** every
acquire attempt routes through to get its ordered candidate list (own reserved slice first, then
general) — the single total-order comparator the item's amended design conclusions call for; a future
tenant (spawn-gate, §6) extends the same function rather than growing a second one.

This still leaves the *within-partition* possession question: once builder-local legitimately holds its
own unit (or a general one), nothing preempts it — we do not kill running suites. The second half of the
fix is an OS-level yield, not a ledger rule: **`nice -n 10` on the builder-local suite subprocess.** It
does not change *admission*, it changes how the kernel schedules CPU once both a builder-local and a
higher-class suite are concurrently running — the low-class run still finishes, just yielding real CPU
to its neighbor instead of contending as an equal. Preemption (actually killing/suspending a running
low-class suite) was explicitly left off the table unless nice + reserved-slice prove insufficient in
practice.

### 2.3 RETRY-SOLO is a drain barrier, not a priority level

The HERD-546 retry-before-red re-run needs a *clean* measurement — contention with a sibling suite would
undermine the very thing it's trying to establish (is this test really flaky, or did it fail for a real
reason). It is not "higher priority than watcher" (a priority level, position in an order); it is a
**drain barrier**: wait for every unit in the ledger — both reserved slices and general — to be free,
hold all of them at once so nothing else can start while it runs, then release the lot. Implemented
directly by the acquire backbone (§2.4): a solo attempt passes *every* slot's lock file and asks for
all of them, all-or-nothing; every other class's attempt only ever asks for one slot's lock, so as long
as retry-solo holds any lock, every other single-slot attempt on that same file fails busy by
construction — no separate "is a barrier active" flag needed. If a solo attempt cannot achieve that
within its window (`HERD_CAPACITY_SOLO_WAIT_SECS`, default 90s), it gives up and the caller classifies
the run **env-suspect** (piggybacking the ledger's own env-suspect note onto HERD-546's existing
red-ledger row for the same key) rather than either blocking forever or running contended.

### 2.4 The acquire backbone: one atomic flock, not a marker-and-mutex dance

The P1 draft's first acquire mechanism (mirroring HERD-529's own `_lss_*`) was a `mkdir`-based mutex
guarding a read-count-then-write critical section over pid+start-time marker files — the same shape
HERD-529 and the watcher's `.health-inflight-*` pool already use. The external review flagged this as
unnecessary surface: it needs a reconciler (sweep dead markers), a TTL escheat policy (what if a live
holder just... never releases), and a wedged-lock watchdog (what if the mutex-holder dies mid-critical-
section) — three failure modes that only exist because the *marker* is standing in for a *lock*.

P1 instead acquires via `scripts/herd/capacity_flock_run.py`: one real, non-blocking, exclusive
`flock(2)` (via Python's `fcntl`, portable to both Linux and macOS/BSD — the platform HERD-529's own
comments explicitly called out avoiding a `flock(1)` CLI dependency for) per unit, held on a file
descriptor owned by the process that acquired it. Acquire and "run with the unit held" are the *same*
call: the helper locks, then runs the given command as a child, then exits with the child's status. The
kernel releases the flock the instant that process exits, crashes, or is `SIGKILL`ed — **there is
nothing to reconcile.** A dead holder's unit is free the moment it's dead, with zero marker-liveness
scanning required for *correctness*.

This directly resolves the "governor self-safety" properties the original design brief asked for, but
not always the way it originally imagined:

| Brief asked for | P1 delivers | Why it changed |
|---|---|---|
| pid-stamped leases | ✅ — the observability marker still carries pid+class+epoch | unchanged in spirit |
| tick reconcile | `capacity_reclaim_dead` — a courtesy sweep of markers whose pid is provably dead | now cosmetic, not load-bearing (the flock already released) |
| TTL escheat | **rejected** — a live holder's unit is *never* reclaimed by age | a TTL-escheat under load evicts exactly the runs load slowed down legitimately — self-defeating; forbidden outright by the review |
| no blocking-acquire-while-holding | ✅ — each acquire is one blocking call to `capacity_flock_run.py` that itself runs the command and returns; there is no separate "hold" state a caller could re-enter | achieved structurally, not by a guard flag |
| wedged-ledger watchdog | **deleted as a failure surface** — there is no lock file that can wedge, because flock ownership is tied to a live process's fd table, not a `mkdir` directory a crashed process can leave behind | the watchdog existed to fix a problem the marker-mutex design created; the flock design doesn't create it |

**Escheat, precisely:** *only* a dead pid is ever reclaimed, and only from the cosmetic marker layer —
never a live holder, never by age. This is the one place P1 deliberately narrows the original brief
rather than extending it, on the review's explicit objection.

### 2.5 Overload breaker

Ledger accounting can say "room" while the box is already oversubscribed by work the ledger has no
visibility into (another process entirely, a runaway build, thermal throttling). Before any class
attempts an acquisition, `capacity_overload_high()` checks loadavg(1m) against `cores × 1.5` (both
overridable test seams); over that line, admission freezes for *every* class, including watcher, until
the box cools — independent of, and a safety net under, unit counting. This is not a deadlock: nothing
new needs to admit for load to drop, since running suites finishing is itself what relieves it.

## 3. Admission order

The full, system-wide order this item's design conclusions specify:

```
watcher tick  >  reviews / merges  >  watcher suites  >  builder-local suites  >  new spawns
```

P1 implements the middle two rungs — `watcher suites` and `builder-local suites` — as the two classes of
one ledger tenant (`suite`). The reserved-top slice (§2.2) *is* "watcher suites" winning against
"builder-local suites" structurally; there is no rung above it inside the P1 ledger to protect against,
because P1 has no tick/review/merge tenant yet. P2 (HERD-581) adds the bottom rung, `new spawns`, as its
own tenant (`agent`, class `spawn`) rather than a third class of the `suite` tenant — spawns are a count
resource, a different shape from suites' CPU units (§4), so they get a separate ledger/cap while still
routing through the SAME comparator. `reviews / merges` and `watcher tick` (the top two rungs) remain
P3. §6 describes how the partition **nests** once those tenants exist: from a future `tick` tenant's
point of view, today's whole `suite` ledger (including its own reserved-top) becomes something closer to
the *middle* of a larger order, and `reserved-top` grows from "1 fixed unit" into "N units, sub-
partitioned tick > reviews/merges > watcher-suites in turn." The comparator function
(`capacity_candidate_slots`) is written generically enough (class, not tenant, drives the partition
match) that this is an extension, not a rewrite — P2 is the first proof of that claim.

## 4. Reserved-slice sizing (why 1 and 1, not aging, answers "how much")

At the shipped default `LOCAL_SUITE_CONCURRENCY=2`, `reserved_top=1` + `reserved_bottom=1` consumes the
entire ledger — there is no general pool at cap=2, which is fine: each class gets exactly one
guaranteed, uncontested unit, and same-class queuing (two watcher suites at once) is an ordinary FIFO
wait, not a starvation problem. Raising the cap (say to 4) keeps both reserved slices at their fixed
floor and grows the general pool, so a bigger/idle box gets more *shared* throughput without diluting
either guarantee. `HERD_CAPACITY_RESERVED_TOP_OVERRIDE` / `HERD_CAPACITY_RESERVED_BOTTOM_OVERRIDE` are
test seams (§7's mutation-prove leg forces `reserved_top=0` to show the possession leg goes red without
it — the partition is load-bearing, not vacuous).

Per-class **flat count caps** (as opposed to the scalar CPU-unit ledger P1 implements) were noted as a
P2/P3 concern once agent leases — a genuinely different resource shape (an agent is a count, not a CPU
fraction) — join the ledger; suites are a single homogeneous resource dimension and don't need a second
cap axis. **Shipped in P2 (HERD-581):** the AGENT tenant's `spawn` class carries exactly that flat count
cap (`REVIEW_CONCURRENCY + SPAWN_AHEAD`, no new key), routed through the same
`capacity_candidate_slots` comparator as the SUITE tenant's CPU-unit classes — see §6.

## 5. What the external review changed (for the record)

A first full draft of this spike proposed the priority-at-acquire-time design (§2.1) with time-based
aging as the anti-starvation mechanism, a `mkdir`-mutex + pid/start-time marker backbone mirroring
HERD-529 verbatim, and TTL escheat + a wedged-lock watchdog as its self-safety story — i.e., essentially
the original design brief's own wording, implemented literally. An external review (`herd advise`,
gpt-5.6-sol) caught that this doesn't fix the pathology it was built for (possession, not ordering, is
what starves the bottom class) and that the marker-mutex backbone manufactures its own failure surface
(reconciler/TTL/watchdog) rather than borrowing a kernel primitive that doesn't need one. The verdict —
reserved-slice + nice instead of aging, flock instead of marker-mutex, escheat-dead-pids-only, an
overload breaker, suite ownership questions deferred — is what §2–§4 describe; nothing in this section
is speculative, it's the actual revision history so a later reader doesn't wonder why the code doesn't
match the item's original prose verbatim.

One review point is recorded here but **explicitly out of scope for P1**: reversing suite *ownership*
so heavy suites run on builders at PR-open (parallel, off the merge critical path) with the watcher
doing a light digest-verify against a trust record, rather than the watcher dispatching its own heavy
run. That's a dispatch-ownership redesign, not a capacity-admission one — P1's brief is "evolve the
HERD-529 slot machinery," and the trust-record half of that idea already exists (`health-trust.sh`,
HERD-531). Filing it as a roadmap item is correct; building it under HERD-557 P1 is scope creep.

## 6. P2/P3 roadmap

- **Agent leases (P2) — SHIPPED (HERD-581).** Builder spawns are a second ledger tenant (`agent`),
  alongside `suite`. Spawns are a *count* resource (bounded by `REVIEW_CONCURRENCY + SPAWN_AHEAD`, no
  new key), not a CPU-unit one — the first real use of the "per-class flat count caps alongside CPU
  units" axis noted in §4. The lane spawn step (`herd-feature.sh` / `herd-quick.sh`) leases a `spawn`
  class unit — routed through the SAME `capacity_candidate_slots` comparator (`builder-local|spawn` both
  match the bottom reserved slice — "spawns stay the bottom class") — BEFORE launching the runtime, held
  by a detached process (`capacity_agent_lease_hold`, `capacity-agent-lease-wait.sh`) that polls the
  driver-agnostic `herd_driver_agent_liveness` and releases (journaling `capacity_lease_released`) once
  the agent session ends — the "P1 semaphore pattern" adapted for a long-lived session instead of a
  foreground subprocess `capacity_acquire_and_run` can `wait()` on directly. `herd-spawn-gate.sh`'s
  existing advisory ALSO now consults the SUITE tenant (`capacity_suite_queue_saturated`): a fully
  contended suite ledger defers a new spawn even when `REVIEW_CONCURRENCY` alone has headroom, closing
  §1(c)'s spawning-into-idleness pathology for real. The AGENT tenant's own reserved-top slot is never
  matched by any class that exists yet, so it stays structurally un-leasable — deliberate headroom for a
  future higher-priority tenant (reviews/merges, next), not a bug.
- **Reviews/merges as ledger tenants (P2/P3).** Once these exist, the reserved-top slice nests as
  described in §3 — `tick` gets first claim, `reviews/merges` next, `watcher suites` beneath that, each
  a partition of the rung above's "general" pool.
- **GATE_SCALE folds in as a derived view (P3).** `REVIEW_CONCURRENCY`/`HEALTH_CONCURRENCY`'s
  live-fleet-size scaling (HERD-542) stops being an independent formula and becomes one more caller
  reading the ledger's own live occupancy — GATE_SCALE's `_gate_scale_derive` and the ledger's `cap`
  resolution converge on the same "how many live builders right now" primitive
  (`_sg_count_inflight_builders`) rather than each deriving it separately, closing the compounding gap
  §0 opened with.
- **Calibrated weights (P3).** Today every unit in a ledger is worth "1." Once telemetry exists (P3, not
  P1/P2 guesswork) on what a suite/agent/review actually costs the box, units can carry a calibrated
  weight instead of a flat count — deliberately deferred; the review's explicit caution against
  "lever sprawl" (a real risk it ranked as the *amplifier* of every other risk at scale) argues for
  measuring before adding a second tuning axis, not before it's justified by data.
- **SQLite-backed tenants (P3+).** If a future Python-core tenant (the engine's store already migrated
  to SQLite) needs its own atomic acquire, any such acquire must be **one atomic transaction** — the
  same "correctness lives in one real primitive, not a marker convention" principle §2.4 applies here,
  transplanted to a different storage engine. Not needed by P1 (pure bash/flock, no SQLite involved).

## 7. Verification plan

Sim-first per AGENTS.md (this is a concurrency/gate-timing change). `tests/test-capacity-ledger.sh`
drives `scripts/herd/sim/sandbox-capacity-ledger-scenario.sh`, which spawns real background processes
against a stub suite command (the same harness shape as `tests/test-local-suite-slot.sh`) and asserts,
as scorecard checkpoints:

1. **Possession leg** — a burst of builder-local suites arrives first and holds every general +
   reserved-bottom unit; a watcher suite arriving after still admits within one poll tick via the
   reserved-top slot, never blocked by the burst.
2. **Retry-solo drain barrier** — a solo request waits out concurrently-running suites, then runs with
   zero observed overlap (a shared busy-file marker, mirroring `test-local-suite-slot.sh`'s own overlap
   proof); a solo request that cannot drain within a short test window gives up and classifies
   env-suspect rather than blocking forever or running contended.
3. **Dead-lessee reclaim** — killing a unit's holder mid-run frees that unit immediately (inherent to
   flock; no explicit reclaim code is exercised for *correctness* here, only the observability sweep).
4. **Lever-off byte-identical** — `CAPACITY_BUDGET` unset/off never creates a single `.capacity-*` file;
   `tests/test-local-suite-slot.sh` (unmodified) continues to pass, proving the legacy `_lss_*` path is
   untouched.
5. **Mutation-prove the partition** — forcing `HERD_CAPACITY_RESERVED_TOP_OVERRIDE=0` makes the
   possession leg (1) go red, proving the reserved-slice mechanism is load-bearing rather than a
   vacuously-true assertion.
6. **Overload breaker** — a faked high loadavg freezes admission for a class that would otherwise have
   a free unit.

The gate is currently no-op'd (per the task brief); these are run directly and reported clean in the PR
rather than relying on the merge-gate suite to have picked them up.
