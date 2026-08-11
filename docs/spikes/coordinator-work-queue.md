# SPIKE: The coordinator externalized work queue

**Tracker:** HERD-626 — *"spike: coordinator externalized work-queue design doc (Phase 0 of
HERD-625)."* This doc is the committed design deliverable that item calls for; cite it from HERD-626
and from every child of the epic.
**Status:** Phase 0 (design only). No engine code ships with this doc.
**Date:** 2026-08-10
**Audience:** coordinator + engine maintainers
**Grounding:** the 2026-08-10 herdkit drain — 12 merges between 11:10 and 18:56 UTC, read back from
`.herd/journal.jsonl` (`merge`, `spawn_wake_result`, `tracker_write`, `reconcile`,
`tracker_state_healed`, `builder_note`). Every number in §1 is from that journal, not from memory.
**Program:** Phase 0 of HERD-625 (*EPIC: coordinator externalize work queue*), which
[`docs/NORTHSTAR.md`](../NORTHSTAR.md) names under Unattended Reliability → Next: *"Coordinator
externalized work queue so a coordinator pause doesn't block mechanical throughput."*

## 0. Why this doc exists

herdkit already survives a coordinator pause for the things the **watcher** owns. A merge does not
wait for a coordinator turn; neither does a review, a limit-park resume, a retirement, a resolver
dispatch, or a post-merge reconcile. Those are reconciled invariants evaluated every tick against
observed state, exactly as [`docs/multi-seat-doctrine.md`](../multi-seat-doctrine.md) Rule 1
prescribes.

What still waits is a narrower and less obvious set: the **rote steps that live on the coordinator
seat because that is where they were written, not because they need judgment**. The dominant one is
*spawn the next item when a slot frees*. It has no judgment in it at the moment it fires — the
decision of *what* to build next was made hours earlier — yet it cannot happen without a live
conversational turn, because the intent that would carry it does not exist until a turn authors it.

The distinction this doc is built on:

> **The spawn queue already externalizes spawn EXECUTION. It does not externalize spawn SELECTION.**
> `spawn.sh` → `_drain_spawn_queue` runs perfectly without a coordinator; but an intent only exists
> because a coordinator turn wrote one. The engine's durability begins one step *after* the step that
> actually blocks.

Everything in §2–§6 follows from moving that boundary one step earlier, and from being strict about
where it must stop.

## 1. The evidence — 2026-08-10

### 1.1 Spawn-next: 4 h 36 m of idle review slot across a 7 h 45 m drain

Twelve PRs merged. Each merge freed a builder/review slot. Twelve builder spawns fired, in **six
clusters** — 11:10, 12:25, 14:20 (+14:38), 17:21, 18:11, 18:55 — each cluster within ~60 s of a
coordinator turn, and each cluster's members within ~40 s of each other.

Latency from the **first** slot-freeing merge after a cluster to the next spawn:

| First free slot | Merge | Next spawn | Slot idle |
|---|---|---|---|
| 11:43:47 | #728 `ref-shape-guard` | 12:25:50 `core-surface-gate` | **42 min** |
| 13:38:18 | #731 `dh-guard-attribution` | 14:20:29 `pane-first-frame` | **42 min** |
| 14:56:22 | #732 `pane-first-frame` | 17:21:20 `anomaly-load-baseline` | **144 min** |
| 17:47:47 | #737 `anomaly-load-baseline` | 18:11:50 `cost-table-opus5` | **24 min** |
| 18:30:50 | #739 `cost-table-opus5` | 18:55:35 `backend-switch-intents` | **24 min** |

**276 minutes** — 4 h 36 m — of a review slot standing empty inside a 7 h 45 m drain, on a day with a
non-empty backlog and an attended, healthy fleet.

The control reading is what makes this diagnostic rather than anecdotal: merge #736 at 17:20:51 was
followed by a spawn at **17:21:20 — 29 seconds later**, and merge #738 at 18:10:58 by a spawn at
18:11:50 — 52 seconds later. The mechanical path is fast. Those two merges simply happened to land
while a coordinator turn was already running. **The latency is seat presence, not engine
throughput**, and it is bimodal: ~30–60 s when a turn is live, 24–144 min when one is not.

### 1.2 Close-item-on-terminal-evidence: already externalized (and it shows what "good" looks like)

All twelve merged items reached Done **with no coordinator turn**:

- **5 via the fast path** — `reconcile` (`_reconcile_via_ref`, fired from the merge itself):
  HERD-578 (+2 min), HERD-577 (+1), HERD-612 (+2), HERD-618 (+2), HERD-619 (+1).
- **7 via the backstop** — `tracker_state_healed component=sweep`
  ([`tracker-state-sweep.sh`](../../scripts/herd/tracker-state-sweep.sh)): HERD-613 (+37 min),
  HERD-614 (+29), HERD-615 (+1), HERD-616 (+8), HERD-620 (+26), HERD-621 (+25), HERD-623 (+12).

This is the honest finding the taxonomy has to absorb: **the epic's second mechanical candidate is
mostly already built.** Its *merge-evidence* case needs no queue at all. Its shape — a fast path that
fires on the event, plus a reconciled sweep that repairs whatever the fast path missed regardless of
which seat merged — is the pattern §5 argues the drain should copy, not replace. What remains
un-externalized is closure on **non-merge** terminal evidence (a PR closed unmerged, an item
superseded by another that shipped, a duplicate); that is Phase 3, and it is small.

### 1.3 Queue-marker publish/supersede: publish fires, supersede never does

Three 📌 markers were published in a single turn at 11:10:58, 11:10:59 and 11:11:01 (HERD-577,
HERD-609, HERD-612; `tracker_write requested=queued component=plan`), and HERD-612 was re-published
at 14:20:05. **Zero `unqueue` writes occurred all day.**

`_backend_claim_item` does not clear the 📌 comment (only `_backend_unqueue_item` does, and its only
caller is a hand-run `herd backlog unqueue`), so HERD-577's marker outlived its own claim at 12:25:45
by more than 90 minutes, and HERD-609 was closed Done at 12:27:02 still carrying a live marker. It
never *looked* wrong, because `_backend_list_queued` filters completed and canceled issues out of the
view — the marker was superseded implicitly by the item closing, not explicitly by anything. That is
a stale-record class that a second seat reading raw tracker comments (rather than
`herd backlog queued`) sees, and it is the smallest possible tracker-write intent — which is why §6
makes it the queue's second tenant rather than something bigger.

### 1.4 Note-ack-after-route: the ack is the mechanical tail of a judgment

Five `builder_note` events (11:52, 13:09, 13:21, 13:24, 15:06). Four appear in
`.agent-watch-builder-notes-acked`; the 15:06 note was never acked and aged out of the display on its
own after the 2 h retention. Every ack followed a coordinator *routing* decision (act now / file it /
dismiss) and was itself a keystroke.

The split matters and §2 keeps it: **routing is judgment, acking is bookkeeping.** What can be
externalized is not "decide what this note means" but "clear the note once the artifact its routing
promised exists."

## 2. Taxonomy — what may leave the seat, and what never may

### 2.1 The four-part test

A duty is externalizable **only if all four hold**:

1. **Observable trigger.** Its firing condition is a predicate over state the engine can read (the
   pool, git, the tracker) — not over anything that exists only in a conversation.
2. **Validated-path action.** Executing it is a call to an engine path that already enforces its own
   invariants (`herd_claim_or_abort`, `herd_tracked_spawn_or_abort`, the spawn gate, the capacity
   lease, a backend op) — the queue adds no new way to mutate anything.
3. **Self-contained inputs.** Every input is durable and re-readable at drain time. If correctness
   depends on what the coordinator *knew* when it decided, the decision has to be re-grounded (§4.2)
   or it is not mechanical.
4. **Idempotent effect.** Executing twice is indistinguishable from once, including across two seats.

### 2.2 Mechanical — externalize

| Duty | Trigger | Action (existing path) | Evidence |
|---|---|---|---|
| **M1 · spawn-next-on-slot-free** | a builder/review slot is free AND a priority-ordered candidate is still open + unclaimed | the spawn queue → `herd-feature.sh` / `herd-quick.sh` (claim + tracked-spawn + gate + lease all unchanged) | §1.1 — 276 min idle |
| **M2 · close-item-on-terminal-evidence** | a PR carrying `Refs:` reached a terminal state | `_reconcile_via_ref` (fast path) + `tracker-state-sweep.sh` (backstop) | §1.2 — **already shipped for merge evidence**; residue is non-merge evidence |
| **M3 · queue-marker publish/supersede** | an intent is enqueued (publish) / its item is claimed, closed or dropped (supersede) | `_backend_queue_item` / `_backend_unqueue_item` | §1.3 — 3 publishes, 0 supersedes |
| **M4 · note-ack-after-route** | a note's routed artifact demonstrably exists (the filed item resolves; the re-task landed) | the existing ack ledger + `herd_console_visible_lines` | §1.4 — 4 acked by hand, 1 aged out |

M1 is the whole of Phase 1. M3 is the second tenant precisely *because* it is trivial — it proves the
substrate carries a non-spawn intent end to end before anything load-bearing rides it. M4 externalizes
only the ack, and only when the artifact is observable; a note routed as "dismiss — informational"
has no artifact, so its ack stays a coordinator act (or ages out, as today).

### 2.3 Judgment-bound — NEVER externalize

| Duty | Which test it fails | Why it cannot be queued |
|---|---|---|
| **Item authoring** | (1) observable trigger, (3) self-contained inputs | Filing an item is the act of deciding a problem exists and how to frame it. The authoring SOP's checks (grounding, verification plan, multi-seat, program slotting) are judgments over evidence a queue cannot re-derive. The scribe already externalizes the *write*; the *decision* is upstream of anything mechanical. |
| **Verdict overrides** | (2) validated path — by construction | Overriding a review BLOCK, approving a HUMAN-VERIFY hold, or forcing a merge is exactly the authority the gates exist to withhold. A queue that can carry an override is a bypass with a queue in front of it. `herd-approve.sh` stays a deliberate, journaled, identity-carrying act. |
| **Sequencing changes** | (3) self-contained inputs | Re-ordering the candidate list, editing an `after=` dependency, or re-prioritizing mid-drain is a re-read of the whole program. The queue *consumes* an order; it never computes one. Publishing a new order is a coordinator act (§4.4). |
| **Curation** | (1) + (3) | Closing as noise, merging duplicates, splitting or narrowing scope, deciding an item is superseded. §1.2's residue is deliberately scoped to *terminal evidence* — a PR that closed unmerged is observable; "this item is no longer worth doing" is not. |

The line is not "hard vs easy." It is **"is the decision already made and merely un-executed?"** M1's
decision was made when the coordinator ranked the backlog. A verdict override's decision is made in
the instant it is exercised — externalizing it would mean pre-authorizing an override for a failure
that has not happened yet, which is the definition of a bypass.

## 3. Substrate

### 3.1 What exists

Three queues already live in the worktree pool, all file-per-request with an atomic-rename claim:

| Queue | Drained by | Shape |
|---|---|---|
| `spawn-queue/` | the watcher tick (`_drain_spawn_queue`) — **purely mechanical** | typed positional intent + `.ref` / `.after` / `.owner` sidecars |
| `backlog-queue/` | an LLM scribe drainer (`scribe-step.sh`) | free-text request, interpreted by a model |
| `research-queue/` | an LLM research drainer (`research-step.sh`) | free-text question |

Only the spawn queue is in the right class: **data interpreted by the engine**, not prose interpreted
by a model. Its mechanics have been hardened against exactly the faults an intent queue will meet —
HERD-116 (re-serve spin), HERD-237 (duplicate launch when a claim outlives a tick; liveness-not-age
reclaim), HERD-94 (dependency holds), HERD-443 (same-second ordering inversion), and PR #151's
durability contract (consume only on observed launch; release on an advisory defer).

### 3.2 The options

**Option A — extend the spawn queue file format.** Add a `kind=` line; teach `_drain_spawn_queue` to
dispatch on it.
*Against:* the `.req` parse is **positional and frozen** — `spawn-step.sh next` emits slug / lane /
ref / after / task at fixed offsets and the drain reads them positionally. That format is frozen hard
enough that both HERD-64's tracker ref and HERD-94's dependency had to ride *sidecars* rather than
change it, specifically so an intent enqueued by an older engine still drains. Widening it now
re-opens the compatibility hazard those sidecars were invented to avoid. Worse, the drain's budget
(`REVIEW_CONCURRENCY + SPAWN_AHEAD`, one lane per tick) is a *builder-slot* budget; a marker-supersede
intent consumes no builder slot and must not queue behind one, nor spend one.

**Option B — a general intents ledger in the pool, mechanics extracted from the spawn queue.**
`$WORKTREES_DIR/intent-queue/`, a sibling of `spawn-queue/`, with the *same* claim primitives —
factored into one shared library both queues call, not copied.
*For:* separate budget and separate failure semantics per kind, without a second copy of the claim
logic. A per-surface duplicate of a rule is what multi-seat doctrine Rule 2 calls a correctness
defect, and the pool already demonstrates the drift it predicts: three near-identical `next`
implementations (spawn / scribe / research) whose reclaim, linger and ordering behavior have diverged.
*Against:* it is a library, and a library with one consumer is speculation.

**Option C — rows in the SQLite store.**
*Against:* the store's migration guard requires every other seat to have **quiesced**
(`herd_engine_migration_guard`), while the queue's whole purpose is to be writable and drainable by
any seat at any instant. The filesystem gives atomic rename and kernel-owned liveness for free — the
same argument [`capacity-admission.md`](capacity-admission.md) §2.4 made for choosing `flock(2)` over
a marker-and-mutex dance. Revisit only if a Python-core tenant needs it, and then only as one atomic
transaction.

**Option D — tracker comments as the queue** (the cross-seat spike's Option A, for shared state).
*Against:* the queue must work precisely when the coordinator is paused — including paused by a usage
limit or a network outage. A queue whose durability depends on a tracker round-trip fails in the
correlated case it exists to survive. The tracker remains the place intents *publish their effects*
(§1.3), never the place they are stored.

### 3.3 Recommendation

**Option B is the end state; Phase 1 ships on the spawn queue unchanged.**

The queue holds **typed intents — data, never shell commands**. This is not a style preference: a
queue of commands makes the pool directory an execution surface whose authentication boundary is
filesystem permissions, and any corrupt or hostile file becomes arbitrary code in the watcher's
process. A queue of typed intents has exactly one interpreter — the engine's dispatch table — so the
blast radius of a bad intent is bounded by the kinds that table knows and the validation each applies
(§4.1). [`journal-act.sh`](../../scripts/herd/journal-act.sh) is the pattern to copy verbatim: one
bounded action per invocation, dispatch by class into an existing rail, honest single-token results,
never self-arming, always rc 0.

The sequencing — end state now, library later — is deliberate. Phase 1's requirement (M1) is a
*spawn* intent, and the spawn queue is already exactly the right container for one. Extracting a
general library before its second tenant exists would be building the abstraction on one data point;
[`capacity-admission.md`](capacity-admission.md) §6 makes the same call (the comparator generalized in
P2, when the second tenant proved it). The binding constraint this puts on Phase 1: **its new code
must be written in the shape it will be extracted in** — priority selection and re-grounding as
standalone functions over a queue directory passed as an argument, not as inline logic wired to
`$Q`. If Phase 1 ignores that, Phase 2 pays for it twice.

## 4. Safety

### 4.1 Every action goes through the path a coordinator would have used

The queue adds no new mutation surface. Each intent kind resolves to one existing entry point, and
every guard on that entry point still runs, unchanged and in the same order:

| Kind | Entry point | Guards that still run |
|---|---|---|
| `spawn` | `herd-feature.sh` / `herd-quick.sh` | `herd_tracked_spawn_or_abort` (TRACKED_SPAWNS), `herd_claim_or_abort` (CLAIM_REQUIRED + the HERD-117 closed-item refusal), the advisory spawn gate (`herd_spawn_gate_saturated`), the HERD-581 agent capacity lease, `BUDGET_DAILY` |
| `marker-supersede` | `_backend_unqueue_item` via the active `SCRIBE_BACKEND` | backend identity, `_backend_tw_journal` attribution, fail-soft on a backend without the op |
| `close-on-evidence` | `_backend_update_state` (verified transition, HERD-70) | the sweep's own unresolvable-ref and shape checks (`pr-ref.sh`, HERD-613 leg 2) |
| `note-ack` | the ack ledger + `herd_console_visible_lines` | display-only; the journal keeps every note |

Two validation points, both mandatory: **at enqueue** (a malformed or unauthorized intent never
enters the durable queue — the same place `TRACKED_SPAWNS=required` already refuses today) and **at
drain** (re-validated before execution, because the queue is pool-shared and an intent may have been
written by another seat or another engine level, §5.3). An intent failing drain-time validation is
`skip`ped loudly with a journal row — never executed partially.

### 4.2 Re-grounding: the decision is re-checked against facts, not replayed

An intent enqueued at 11:10 and drained at 14:20 was authored against a three-hour-old reading of the
world. Before executing, the drain re-reads the item's current tracker state through the path that
already knows how to judge it — `herd_claim_or_abort`'s HERD-117 guard, which refuses a Done or
Canceled item and journals `claim_refused reason=already-done`. Today that refusal exits the lane
non-zero and the drain records `spawn_skipped`, which is *almost* the right behavior; Phase 1 makes it
exactly right by classifying it as **terminal-skip-and-continue** (drop this candidate, move to the
next in priority order) rather than as a generic hard failure that stops the tick.

A **staleness TTL** backs this up: an intent that has sat undrained past `INTENT_TTL` does not launch.
It escalates (§4.3). Launching a builder against a plan whose premises are a day old is worse than
not launching one, and the failure is silent — which is the class this whole design exists to remove.

### 4.3 Failure semantics: never loop silently, never loop forever

Failures split two ways, and the split is the design:

- **Transient** (backend unreachable, `gh` timeout, capacity lease unavailable, gate saturated): the
  intent is **released** back to the queue with its attempt counter incremented, exactly as a
  gate-deferred spawn is today. No console noise — a defer is not a failure.
- **Terminal** (item already Done, slug already exists, ref fails shape validation, unknown kind):
  escalate on the **first** occurrence. Retrying cannot change the answer.

After `INTENT_MAX_ATTEMPTS` (default 3) transient failures, an intent transitions to a terminal
**escalated** state: it leaves the drain set, journals once with its full context, and renders a
`needs-you` row naming the intent, the last failure, and the remedy.

Two lessons from 2026-08-10 are binding here, and this is the doc's most important constraint:

- **HERD-613 leg 3** — escalated tracker-heal rows stood loud on the console for **4+ days** because
  loud rows never age out by design and no ack path existed. The operator's report was "it's been
  there for days." *Therefore:* the escalated intent row ships **with its ack path in the same
  slice** — never a follow-up item. An escalation surface without a clearing surface is not a safety
  feature; it is a new permanent-red generator.
- **HERD-624 leg 2** — mark-shipped intents whose refs belonged to a retired backend were stamped
  unresolvable every sweep and warned forever, until an operator hand-edited the ledger. *Therefore:*
  an escalated intent has an **age-to-retired** terminal path — after the normal calm retention it
  leaves the console, journaling its retirement with its ref so the evidence survives. Terminal means
  terminal: an intent is queued, executed, cancelled or retired, and every one of those is reachable
  from every other state that precedes it. No state warns forever.

### 4.4 When a human countermands a queued intent

Three levels, in increasing order of what has already happened:

1. **Not yet claimed** — a new `cancel <intent-id>` op on `spawn-step.sh` (joining `next` / `own` /
   `done` / `release` / `skip`, and reached the same way the other queue mechanics are: invoked
   directly, not via a `herd` subcommand) renames the intent to a `.cancelled` terminal state and
   journals it. Atomic, so it races the drain safely: whichever
   rename wins decides, and the loser sees a vanished path and exits 3 — the loud-not-silent contract
   `spawn-step.sh` already enforces for `done`/`release`/`skip`.
2. **Claimed and launching** — the intent cannot be un-launched. The doc says so plainly rather than
   pretending otherwise: the human countermands the **builder** (close the PR, retire the worktree,
   release the claim), through the rails that already exist for exactly that. The window is one tick.
3. **Global stop** — `ENGINE_PAUSE` must freeze the intent drain exactly as it freezes the rest of the
   tick. An operator halting the fleet must not need to know an intent id, or that intents exist.

**Supersede over delete.** A coordinator changing its mind re-publishes the candidate list under a new
**generation** counter; the drain only ever executes intents from the newest generation, and older
un-claimed intents retire silently. Countermanding a plan is then one write instead of N deletes, and
the "did I get all of them?" failure mode disappears. This also makes M3 fall out for free: publishing
generation N+1 is precisely the event that supersedes generation N's 📌 markers.

## 5. Multi-seat

### 5.1 Pool-shared by construction

The queue lives under `$WORKTREES_DIR`, alongside `spawn-queue/`, `.agent-watch-merged` and the
capacity ledgers. Any seat's watcher drains it; the drain carries **no** `WATCHER_OWNER` scoping. The
identity that matters is attached to the *effect*, not the queue: the claim a drain performs carries
the draining seat's backend identity, so tracker-side ownership stays honest even though the intent
was authored by a different seat.

### 5.2 Reconciled-invariant drain semantics

Stated as an invariant reconciled every tick against observed state, per Rule 1:

> **At every tick, for the highest-priority un-claimed intent of the newest generation: if its
> preconditions hold against observed state — a free slot, an item still open and unclaimed, within
> TTL — it executes. Otherwise it is held, skipped, or escalated. This holds regardless of which seat
> enqueued it and which seat is ticking.**

The counter-example the rule forbids is the one §1.1 measured: today the trigger *is* a side effect of
one seat (a turn happening), so a slot freed while that seat is between turns is repaired by nobody.
§1.2's already-working closure path is the positive control — a fast path on the event plus a
reconciled sweep behind it, which is why all twelve items closed on a day when no coordinator turn
closed any of them. The drain should be built to the same shape, and for the same reason.

### 5.3 Idempotent execution

Three independent layers, none of which relies on the others:

1. **At-most-one claim** — the atomic rename (`.req` → `.req.mine`). Two seats racing the same intent:
   one `mv` wins, the other's fails and it moves to the next candidate. Proven mechanics; no new code.
2. **At-most-one effect** — even if a claim were somehow duplicated, the re-ground read (§4.2) sees
   the item already `started` and claimed by the first seat's identity, and refuses. This is the exact
   double-build HERD-117 was built to stop (2026-07-08: a stale pick reopened a shipped item and
   spawned a conflicting duplicate PR).
3. **Terminal-state writes are convergent** — `_backend_update_state` reports DONE only on a
   *confirmed* transition, and the tracker sweep ledgers a confirmed ref and never re-reads it. Two
   seats both closing one item converge on the same state.

### 5.4 Engine-level stamping

Intents are mutable pool state, so HERD-308 applies: **every intent carries the engine level of its
writer**, and a drainer whose level is below it **leaves the intent alone** (skip-without-consuming)
rather than executing it against semantics it does not implement. `herd_engine_seat_reconcile`
already surfaces the mismatch loudly. This is not hypothetical bookkeeping — an intent kind added in
level N+1 that an N-level watcher drains as "unknown kind → terminal escalate" would convert a
routine engine skew into a needs-you row per intent.

### 5.5 Cross-seat drain budget — CLOSED by Phase 4 (HERD-641)

*The open question, as Phase 0 stated it:* each watcher computed its spawn budget from **its own**
`FEATS` roster. Two seats draining one queue therefore each admitted up to their own cap, and the
fleet could exceed the machine's real budget. The mechanism to fix it already existed and was not the
queue's to reinvent: the HERD-581 `agent` capacity tenant is a genuine machine-wide count
(`capacity_agent_lease_hold`), and the drain should lease through it rather than counting worktrees.

*As shipped (Phase 4):* `_drain_spawn_queue` acquires that tenant's unit for the candidate's slug
immediately before the lane is dispatched — below the launch-slot and re-ground checks, so a tick that
cannot launch never touches the ledger and an already-Done candidate never leases one. Denied → the
intent is held and handed back for a later tick, exactly like a gate-deferred spawn. The per-seat
`${#FEATS[@]}` subtraction is gone from the armed path; what remains of `_dsq_budget` there is a pure
per-tick WALK BOUND. `capacity_agent_lease_armed` (capacity-ledger.sh) is the single arming rule both
the drain and the reserve read, so the two can never disagree, and the lane inherits the drain's unit
via `HERD_AGENT_LEASE_HELD` rather than leasing a second one for the same session.

Release stays a **reconciled invariant**, never an event side-effect of the drain: the detached holder
`capacity_agent_lease_hold` polls `herd_driver_agent_liveness` for the slug and releases when the
session is confirmed gone (or on its own start timeout if the lane never launched one). A seat that
crashes holding leases frees them by the same contract from below — the flock belongs to the holder
process, so the kernel drops it the instant that process dies and the next seat's reserve admits.

Fail-soft is byte-identical: no ledger in the tree, `CAPACITY_BUDGET` unset, no worktree pool or no
python3 → the legacy `cap - ${#FEATS[@]}` budget runs untouched. Proven in
[`sandbox-capacity-agent-lease-scenario.sh`](../../scripts/herd/sim/sandbox-capacity-agent-lease-scenario.sh)
by `drain_two_seats_one_admission`, `drain_crashed_holder_lease_frees` and
`drain_ledger_absent_legacy_identical`. **With this landed the epic may be described multi-seat safe.**

## 6. Phase cutlist

- **Phase 1 (smallest shippable slice) — priority-ordered spawn intents drained on slot-free.** A
  `.prio` sidecar (lowest first, FIFO within a band, absent = today's FIFO), drain-time re-grounding
  as terminal-skip-and-continue, `INTENT_TTL`, the `cancel` op, and the escalated `needs-you` row
  **with its ack + age-to-retired path in the same PR** (§4.3). Ship-dormant behind one config key; off
  = byte-identical to today's FIFO drain.
- **Phase 2 — extract `intent-queue.sh`** (claim / own / release / skip / done / priority / owner
  liveness) with `spawn-queue/` as tenant #1 (byte-identical), and land `marker-supersede` as tenant
  #2 — the smallest real tracker-write intent, and the proof the substrate generalizes.
- **Phase 3 — non-merge terminal evidence + note-ack.** Close-on-evidence for PRs closed unmerged and
  items superseded by a shipped sibling (§1.2's residue); `note-ack` for notes whose routed artifact
  is observable (§1.4).
- **Phase 4 — cross-seat drain budget. SHIPPED (HERD-641).** The drain leases the spawn slot through
  the HERD-581 `agent` capacity tenant instead of counting this seat's `FEATS`, releasing by the
  tenant's own retirement invariant and falling back byte-identically when the ledger is absent;
  closes §5.5, and with it the last reason not to call this epic multi-seat safe.
- **Phase 5 — the candidate list as a first-class surface.** Generation publish/supersede as a
  coordinator command plus a console section showing the pending plan, so a second seat reads the
  queue instead of re-deriving it.

## 7. Verification plan (for the Phase 1 item, not for this doc)

Sim-first per [`AGENTS.md`](../../AGENTS.md) — this changes spawn/concurrency behavior, so unit
asserts alone are not sufficient.

1. **Priority ordering** — intents enqueued out of priority order drain highest-priority-first; ties
   preserve FIFO by `INTENT_ID`, the HERD-443 invariant.
2. **Slot-free latency** — a scripted merge frees a slot and the very next tick launches the top
   candidate, with no coordinator process in the scenario at all. This is the §1.1 measurement,
   inverted into an assertion.
3. **Re-ground skip** — a candidate whose item is flipped Done between enqueue and drain is skipped
   with `spawn_skipped`, the drain **continues** to the next candidate, and no worktree, branch or
   agent is created.
4. **TTL escalation** — an intent aged past `INTENT_TTL` escalates instead of launching; the row is
   ack-able and ages to retired. Assert **both** halves — the HERD-613 lesson is that the escalation
   without the clearing path is itself the defect.
5. **Countermand race** — `cancel` and `next` racing one intent: exactly one wins, the loser exits 3
   and journals `spawn_claim_lost`; no double-launch, no phantom `.req`.
6. **Lever-off byte-identical** — with the key off, the drain's argv, journal lines and file layout are
   byte-for-byte today's; `tests/test-spawn-queue-drain.sh` passes unmodified.
7. **Mutation-prove the priority path** — forcing all priorities equal must make (1) go red. A
   passing ordering assertion over a queue that is FIFO anyway is vacuous.

## 8. Risks

- **Deep pre-enqueue commits to a plan the world outruns.** The whole latency win comes from queuing
  more decisions further ahead, which is exactly what makes them stale. §4.2's re-ground + TTL are the
  mitigation, and they are load-bearing, not decorative — Phase 1 without them is strictly worse than
  today, because a wrong spawn costs a full builder run plus a bounced PR.
- **Escalation-row sprawl.** Every new intent kind is a new way to produce a needs-you row. The
  age-to-retired path (§4.3) plus one shared row-rendering surface keeps this bounded; a kind that
  cannot age out does not ship.
- ~~**Two seats over-admitting.** Real until Phase 4 (§5.5). Do not describe Phase 1 as multi-seat
  safe.~~ **RETIRED — Phase 4 shipped (HERD-641).** The drain admits through the machine-wide HERD-581
  `agent` capacity lease instead of this seat's `FEATS` roster, so two seats draining one queue admit
  exactly one; see §5.5 for the shipped mechanism and its three proofs.
- **The abstraction arriving before its second consumer.** Mitigated by sequencing (§3.3), at the cost
  of a Phase 1 that must be written extraction-shaped by discipline rather than by structure. Worth
  naming explicitly in the Phase 2 item so a later builder does not have to rediscover it.
- **Scope creep into judgment.** The pressure to add "just one more" mechanical kind is how a queue of
  intents becomes a queue of decisions. §2.1's four-part test is the gate every future kind passes in
  its own item, restated in that item — not assumed from this doc.

## 9. What this deliberately does not do

It does not make the coordinator optional. It moves the **latency** of already-made decisions off the
seat; the **authority** stays exactly where it is. A paused coordinator should mean rote steps keep
flowing at engine speed and judgment waits — not that judgment gets made by a queue.

---

Part of HERD-625 — Phase 0; full context: docs/spikes/coordinator-work-queue.md.
