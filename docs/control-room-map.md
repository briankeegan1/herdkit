# herdkit control-room map

> The **one-page decision graph** of how a change ships end-to-end in herdkit — read this to
> orient on *the flow*. Its two companions map different axes: [`docs/codemap.md`](codemap.md)
> is the **file map** (which module does what; regenerate with `herd codemap`), and
> [`docs/driver-abstraction.md`](driver-abstraction.md) is the **one runtime seam** (how the
> multiplexer + agent runtime are swapped). This doc is the **pipeline**: coordinator → lane →
> builder → gates → verdict → merge → reconcile. Render it any time with `herd map`.

Two roles run the whole show, and they never touch each other's turf:

- **The coordinator** — one agent in the control-room tab. Owns the **backlog** and **spawning**.
  It NEVER edits code in the main checkout and NEVER merges a PR.
- **The watcher** (`herd pane watch` → `agent-watch.sh` / `herd-watch.sh`) — a headless status console. Owns the
  **gates** and the **merge**. It NEVER writes the backlog and NEVER edits code.

Everything below is the handoff between them.

---

## The pipeline, one stage at a time

```
  ┌─────────────┐   pick item    ┌──────────────┐   spawn      ┌────────────────────┐
  │  BACKLOG    │ ─────────────▶ │ COORDINATOR  │ ───────────▶ │  BUILDER WORKTREE   │
  │ BACKLOG.md  │  (owns queue)  │  (control    │  a lane      │  isolated off the   │
  │             │                │   room tab)  │              │  default branch     │
  └─────────────┘                └──────────────┘              └─────────┬──────────┘
        ▲                                                                 │ build + verify OWN
        │ scribe (one async writer)                                       │ surface, open PR
        │                                                                 ▼
  ┌─────┴───────┐                                              ┌────────────────────┐
  │ post-merge  │ ◀─────────── merge ◀───────── verdict ◀───── │   WATCHER GATES    │
  │  RECONCILE  │              policy            PASS/BLOCK     │ healthcheck+review │
  └─────────────┘                                              └────────────────────┘
```

### 1 · Coordinator picks work

The coordinator reads `BACKLOG.md` (planning doc; the coordinator owns it) and chooses the next
item. It decides the **lane** by the shape of the change — never edits code itself.

**Two coordinators can now share one repo**, so picking is guarded on both axes — *plan time* and
*spawn time*:

| Guard | Key | What it closes |
|-------|-----|----------------|
| **atomic claim** | `CLAIM_REQUIRED` | the **spawn** race — the lane claims the item **synchronously, before** any worktree or agent exists, and aborts loudly if another identity holds it. A `Done`/`Canceled` item is refused (a stale pick must never reopen shipped work). |
| **📌 queue marker + assignee** | — | the **plan** race — `herd backlog queue <#id> [--after <blocker>]` publishes "I'm building this next" *and* sets the issue **assignee**, so a second seat sees it in any tracker client, not only in `herd backlog queued`. Advisory, never a lock: a marker older than 24h is flagged stale, and spawning supersedes it. |
| **traceable spawns** | `TRACKED_SPAWNS` | the **ref-less builder** — `required` refuses to spawn work that carries no tracker ref (`HERD_CLAIM_ID`, else the `HERD_ITEM_REF` the coordinator threads). |

The order is **file, then spawn**: the item exists in the tracker and carries a ref *before* an agent
does. `TRACKED_SPAWNS` enforces **visibility** (a ref exists); `CLAIM_REQUIRED` enforces
**exclusivity** (nobody double-builds it). Both are ship-dormant (`off`) and read the same ref.

### 2 · Lane → builder worktree

Every build happens in an **isolated git worktree** off the latest default branch, with its own
agent pane. The coordinator's checkout is never the build surface.

| Lane | Script | Layout | Use for |
|------|--------|--------|---------|
| **feature** | `herd-feature.sh <slug> [task…]` | `[ live app preview │ agent ]` | real features / render-affecting or risky changes (Opus builder) |
| **quick** | `herd-quick.sh <slug> [task…]` | single agent pane | trivial non-render edits: one-liners, config/string/script tweaks |

Both lanes obey the same sacred invariant: **branch → build → open a PR**. The builder verifies
only its **OWN surface** before the PR — the LIGHT healthcheck (`healthcheck.sh <worktree> --light`,
per-changed-file syntax) plus any test it added — because the watcher re-runs the authoritative
heavy profile at the gate (don't duplicate it locally).

Two things happen to a builder *mid-flight*, without a human in the loop:

- **findings travel by journal, not by clipboard.** A builder that discovers something the
  coordinator needs to know — "this red is a stale cached row", "my test isn't wired into the gate",
  "this hold is env, not code" — files it with `herd note "<finding>"`. The watcher drains new notes
  each tick into a needs-you-adjacent **builder notes** console section; `herd notes ack <n>` clears
  a handled one. No pane transcript ever has to be pasted by hand.
- **a usage-limit hit is a park, not a death.** When a builder blocks on the account limit the
  watcher paints a calm `limit-hit · auto-resume at HH:MM` row (never a red, never a stall), tries
  the clean route first — selecting *"stop and wait for limit to reset"* so the runtime's own
  wait-and-resume owns it — and keeps a scheduled `claude --continue` relaunch as the backstop. The
  record clears the instant a resume succeeds; only a failed-after-retry resume escalates.

### 3 · Watcher gates the PR — the gate ORDER

The watcher polls open PRs and, for one that is `MERGEABLE` + `CLEAN`, runs its gates **in this
order** (from `agent-watch.sh`). The order is load-bearing, not cosmetic: each gate is cheaper than
the one after it, so a doomed sha dies before anything expensive grades it. (Before any of this, a
worktree with no PR yet is simply 🔨 **building** — the agent is working.)

**0 · merge fairness** *(`MERGE_FAIRNESS`, default off)* — before any gate runs, the tick's
candidates are stably partitioned so PRs whose gates are **already green for this exact sha** are
visited before PRs that still need gate work. A PR one step from landing never queues behind
somebody else's fresh suite. Reordering changes *visit order only* — every gate below still runs on
a promoted candidate exactly as on a demoted one.

**1 · 🛑 stale / duplicate gate** — decides **FIRST**, before the review pre-dispatch and before the
healthcheck. It is deterministic and cheap (a duplicate tracker ref, or a pure-git merge-base file
overlap), and if it holds, it bounces the builder — superseding the very sha a suite or review would
be grading. Running it last once burned a ~9-minute heavy suite plus one Opus review per stale
cycle. Two flavors, and they route differently: **stale-base** (touched files moved on the default
branch) is mechanical and auto-healable; **duplicate** (this re-implements shipped work) is a human
judgment call. Disable with `STALE_DUP_DETECT=off`.

**2 · 🩺 health-check** — `healthcheck.sh` on the worktree. **Serialized** by a per-repo mutex
(`HEALTH_CONCURRENCY`, default 1) because feature worktrees share one git object store. A CODE
error is **retried once solo** — a transient self-heals as *flaky · infra (passed on retry)*;
only a **reproducing** failure paints red. A ⚠️ data/env warning is fine.

**3 · 🔬 adversarial review** — health passed: a **strong model adversarially correctness-reviews the
diff** (`herd-review.sh`) *before* merge. Healthcheck proves the code *builds/boots*; review is the
only gate that asks whether the diff is **correct**. Runs in the background up to
`REVIEW_CONCURRENCY`; the project risk list from `REVIEW_CHECKLIST` is injected so the reviewer knows
what "silently wrong" looks like here. (Under the parallel mode the review is *pre-dispatched*
alongside the suite to overlap wall-clock — the merge decision below still requires **both**.)

**4 · ⏸ HUMAN-VERIFY hold** — a PR whose body declares a `HUMAN-VERIFY:` block converts a green-gated
PR into an approve-style hold. `HUMAN_VERIFY_POLICY` picks who clears it: `hold` (default — a human
does), `coordinator` (the coordinator agent runs the steps and approves), `auto` (steps recorded as
informational, PR merges). An unreadable PR body **holds** rather than risk merging past a declared
step.

**5 · 🚦 MERGE_POLICY** — the last gate before landing (below). A hold here is a *policy choice*, not
a gate failure.

**Just before merging**, the watcher **re-verifies** the PR is *still* MERGEABLE/CLEAN and still maps
to the expected branch, and **unconditionally re-runs the stale-base check**. That re-check is not
redundant with step 1: a stale-base clearance is a function of the head sha **and** the base tip, and
another seat can merge and advance the base tip while our suite runs. The invariant is "no merge
without a clearance against the **current** base" — re-established from observed state, never
inferred from what this seat did.

- ⏳ **merging** — gates green, holds clear, re-verify clean: merging now, pinned to the gate-verified
  sha.

### 4 · Verdict branches

```
  healthcheck ──▶ CODE error (reproduces) ──▶ ⚠️ needs you        (never auto-merged)
       │
       └── green ──▶ review ──▶ PASS  ──▶ merge-policy gate ──▶ merge
                         │
                         ├── BLOCK ──▶ ⚠️ needs you            (cached per commit sha)
                         │
                         └── refix ──▶ push a new commit ──▶ re-gates from the top
```

- **PASS** → proceed to the merge-policy gate (below).
- **BLOCK** → **needs you**; never auto-merged. The verdict is cached against the commit sha; a
  human reads it with `herd-approve.sh why <pr#>` and can `herd-approve.sh override <pr#>` (the
  override dies the moment a new commit is pushed).
- **refix** → the builder (or a human) pushes a new commit; a new sha **re-runs every gate** from
  the top. Nothing merges on stale verdicts.
- **CONFLICTING** → 🔀 the watcher auto-spawns an isolated, test-gated **conflict resolver**
  (`herd-resolve.sh`): it merges the default branch in, fixes **mechanical** conflicts, re-runs
  smoke + healthcheck, and pushes so the PR flips CLEAN. It **escalates** semantically-ambiguous
  conflicts to a human instead of guessing; respawns are capped (*resolver gave up* → needs you).

### 4b · Refix rails — who fixes a red, and how many times

A red does not have to wait for a human. Three **rails** can bounce the failure straight back to the
live builder as a re-task prompt, each behind its own ship-dormant lever:

| Rail | Lever (default) | Bounces |
|------|-----------------|---------|
| **review** | `REVIEW_AUTOFIX` (`false`) | a review **BLOCK** → the builder gets the verdict |
| **health** | `HEALTHCHECK_AUTOFIX` (`false`) | a **reproduced** healthcheck CODE error → the builder gets the failing test + the tailable suite log |
| **stale** | `STALE_BASE_AUTOFIX` (`off`) | a **stale-base** hold → the builder gets a `git merge <default-branch>` re-task (or the conflict resolver, if no live builder remains) |

A tab-leak-guard trip is infra and is **never** bounced. `duplicate` is never bounced either — it
stays a human call.

**Budgets are per rail, and progress refunds them.** Each rail carries its own round counter capped
at `REFIX_MAX_ROUNDS` (default 3), and **a rail's counter is zeroed the moment that rail's red
resolves** — a review PASS after a BLOCK, a CLEAN suite after a red, a freshened base. A loop is the
*same* check failing again; three different checks each failing once is a pipeline converging, and it
should not exhaust anything. Bounding the whole PR is a derived **total ceiling of 3× `REFIX_MAX_ROUNDS`**
across all rails, counting every bounce ever recorded and ignoring resets. Exhausting **either** the
rail budget or the total ceiling escalates to needs-you. Bounces are sha-keyed per (pr, sha, rail), so
one BLOCK bounces once and a new commit earns a fresh round.

**Row truth: "needs you" means NOBODY is on it.** The console never paints needs-you at a red an
agent is actively fixing — a bounced builder, or one reading `working`, shows
`fix in progress · awaiting push (round k/N)`, where `k/N` is **that rail's** budget. So a needs-you
row is always real, unclaimed work carrying both the **blocker** and the **remedy**. The invariant is
one-way, deliberately: a needs-you row is trustworthy, while a *fix in progress* row can be a busy
agent doing something else. Erring that direction never types a prompt into a working agent, and the
next idle tick corrects the row.

### 5 · Merge policy — the last gate before landing

On a green + PASS PR, `MERGE_POLICY` (`.herd/config`) decides *who* pulls the trigger:

| Policy | Behavior |
|--------|----------|
| **auto** (default) | the watcher merges, full-auto and safety-railed |
| **approve** | the watcher **holds** until a human writes a sha-keyed `herd-approve.sh approve <pr#>` |
| **observe** | the watcher gates and reports but **never merges** — a human does |

Two extra holds compose with any policy, gating at different points on the timeline:

- **`PUSH_GATE=human`** — gate **before** the push, while the diff is still only local
  (`push-gate.sh`).
- **`PR_FLOW=draft`** — gate **after** the push, on an already-public draft PR.
- **`HUMAN-VERIFY:` block** — a builder that can't run a required manual step (a live smoke test, a
  UI/pane check) declares it, one per line, in the PR body. That flips **this PR** from auto-merge
  to an approve-style hold: **every gate still runs**, but the merge waits on
  `herd-approve.sh approve <pr#>` so the step is never silently skipped. `HUMAN_VERIFY_POLICY`
  decides who may clear it — `hold` (a human), `coordinator` (the coordinator agent runs the steps),
  or `auto` (declared steps recorded, PR merges).

Which green PR gets looked at first is `MERGE_FAIRNESS` (default off): with it on, PRs already green
for their current sha are visited ahead of PRs still needing gate work — visit order only, never a
skipped gate.

Just before merging, the watcher **re-verifies** the PR is *still* MERGEABLE/CLEAN and still maps to
the expected branch, and re-runs the stale-base check **unconditionally** against the *current* base
tip — closing both the window between classification and merge, and the one where another seat's
merge advanced the base while our suite ran.

### 6 · Post-merge reconcile, sweep, and retirement

When a PR lands, the watcher enqueues a **scribe** "reap" for the shipped item, and a
rename/move-aware pass (`backlog-reconcile.sh`) enqueues targeted scribe fixes for any `BACKLOG.md`
entries that pointed at paths/names the PR moved — so the backlog never silently dangles. The
**scribe is the one backlog writer**; the coordinator and watcher only *enqueue*. The committed maps
are refreshed on the same seam as a **reconciled invariant**, not as a merge side-effect, so a PR
another seat (or the GitHub UI) merged still converges.

**Retirement is an invariant, not an event.** A slug whose PR is MERGED or CLOSED — or whose worktree
is gone — has **no right** to hold an agent, a tab, a worktree, a branch, or a ledger row. That is a
property of the world, so it is reconciled on **every tick**: observe, compute what should not exist,
drive the idempotent teardown one step further, repeat until converged. Kill the watcher anywhere
inside a teardown and the next tick of the next watcher finishes the job. Teardown is anchored to the
**commit**, never the slug, and anything not provably disposable is flagged with evidence rather than
deleted. A teardown that fails to converge for too many ticks turns into a
`needs-you · retirement stuck` row pointing at `herd sweep`.

`herd sweep` is the on-demand form of the same reapers — worktrees, stale tabs, dead-pid inflight
markers, orphaned gate processes, and a watcher restart. Run `herd sweep --dry-run` first to read
the plan; nothing it cannot prove disposable is ever removed.

---

## Diagnose: `herd why` FIRST, always

When a PR is stuck, red, or merged-and-you-don't-know-how, do **not** start with process archaeology
— start with the recorded events:

```
herd why <pr#>
```

It replays that one PR's whole gate history from the engine journal, chronologically: every dispatch,
every verdict with its provenance, every healthcheck attempt and outcome, every auto-refix bounce and
whether the wake landed, and the merge and reap. Only when `herd why` comes up empty should you widen
to `herd log` (the raw journal) or `herd status` (a one-shot, read-only health snapshot of this
project: watcher alive? builders dead? PRs blocked?).

---

## Bug routing: APP vs HERD-ENGINE (decide every time)

Every reported problem routes to exactly one place — get this wrong and the fix is lost on the next
`herd upgrade`:

- **APP bug** — the symptom is in **this project's own code** (a wrong number, a broken tab, a
  failing connector). → spin a normal **feature/quick worktree in this project**.
- **HERD-ENGINE bug** — the symptom is in the **workflow itself** (a lane mislabels state, the
  watcher races, the resolver guesses, a script leaks another project's assumptions). → **escalate
  OUT** to the engine repo; do **not** patch it in this clone. File it with:

  ```
  herd report "<symptom + which lane>"
  ```

  (opens a `gh issue` on `HERD_REPO`, stamped with this project + lane + version pin; dedups first).

---

## Async lanes: fire-and-return work

Two lanes run **off to the side** so the coordinator's window stays free — it enqueues and returns
instantly, and exactly one drainer batches the queue:

- **scribe** (`scribe.sh "<change>"`) — the **one** backlog writer. Edits `BACKLOG.md`, commits
  **straight to the default branch** (no PR — it's a planning doc), reports back peripherally
  (✍️ *JUST SCRIBED* banner + notification + `.scribe-reports` inbox). Concurrency-safe via atomic
  per-file claim + push serialization.
- **research** (`research.sh "<question>"`) — a **read-only** repo Q&A drainer. Fans out Explore
  subagents, writes a per-request report to `.research-reports/<id>.md`. **Never** pulls, commits,
  branches, or mutates the checkout — capture the printed `REQ_ID` and fetch the report later.

---

## Safety rails (the invariants the whole graph rests on)

- **Isolation** — the coordinator NEVER edits code in the main checkout; every build is a throwaway
  worktree that branches → builds → PRs.
- **One writer per surface** — the scribe is the sole backlog writer; git push serializes it.
- **No false red** — a transient CODE error is retried solo before it can go red; a missing soft dep
  (glow, etc.) degrades one feature, never blocks (`herd doctor` names it).
- **Gate, don't guess** — healthcheck (builds?) + review (correct?) both pass before any auto-merge;
  the resolver fixes only mechanical conflicts and escalates the rest.
- **Cheapest gate first** — the deterministic stale/duplicate check runs before the suite and the
  reviewer, so no expensive gate ever grades a sha that is already doomed.
- **Re-verify at the edge** — merge only after re-confirming MERGEABLE/CLEAN + branch mapping **and**
  a stale-base clearance against the *current* base, in the instant before landing. Re-establish it
  from observed state; never infer it from what this seat did.
- **Rows tell the truth** — "needs you" means nobody is on it. A red an agent is actively fixing
  reads `fix in progress · awaiting push (round k/N)` instead, so the operator never context-switches
  into work already in flight.
- **Bounded self-healing** — every auto-refix rail carries its own round budget, refunded when that
  rail goes green, under one per-PR total ceiling. Nothing bounces forever; exhaustion escalates.
- **Retire by reconciliation** — merged/closed work holds no agent, tab, worktree, branch, or ledger
  row; teardown is recomputed every tick from the world, so a crash mid-teardown self-heals.
- **Verdicts are sha-keyed** — a new commit invalidates a cached BLOCK/override and re-gates from
  the top; nothing merges on a stale verdict.
- **Escalate engine bugs OUT** — never patch the engine in a consuming clone; `herd report` files it
  upstream so the fix survives `herd upgrade` and reaches every consumer.

---

## Where to look next

| You want… | Go to |
|-----------|-------|
| why a PR is stuck / what happened to it | `herd why <pr#>` — then `herd log`, `herd status` |
| the control room cleaned up after a crash | `herd sweep --dry-run`, then `herd sweep` |
| which module/script does what | [`docs/codemap.md`](codemap.md) — `herd codemap` |
| a def→caller function index | [`docs/symbol-index.md`](symbol-index.md) — `herd symbol-index` |
| how the runtime/multiplexer is swapped | [`docs/driver-abstraction.md`](driver-abstraction.md) |
| live pipeline state right now | `herd pane watch` / `herd status` (the watcher console) |
| this map, rendered | `herd map` |
