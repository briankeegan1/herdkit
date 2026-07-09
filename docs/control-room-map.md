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

### 3 · Watcher gates the PR

The watcher polls open PRs and, for one that is `MERGEABLE` + `CLEAN`, runs two gates in order.
State words it paints (from `agent-watch.sh`):

- 🔨 **building** — agent working, no PR yet.
- 🩺 **health-check** — `healthcheck.sh` on the worktree. **Serialized** by a per-repo mutex
  (`HEALTH_CONCURRENCY`, default 1) because feature worktrees share one git object store. A CODE
  error is **retried once solo** — a transient self-heals as *flaky · infra (passed on retry)*;
  only a **reproducing** failure paints red. A ⚠️ data/env warning is fine.
- 🔬 **reviewing** — health passed: a **strong model adversarially correctness-reviews the diff**
  (`herd-review.sh`) *before* merge. Healthcheck proves the code *builds/boots*; review is the only
  gate that asks whether the diff is **correct**. Runs in the background up to `REVIEW_CONCURRENCY`;
  the project risk list from `REVIEW_CHECKLIST` is injected so the reviewer knows what "silently
  wrong" looks like here.
- ⏳ **merging** — health passed **and** review returned **PASS**: merging now.

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
  `herd-approve.sh approve <pr#>` so the step is never silently skipped.

Just before merging, the watcher **re-verifies** the PR is *still* MERGEABLE/CLEAN and still maps to
the expected branch — closing the window between classification and merge.

### 6 · Post-merge reconcile

When a PR lands, the watcher enqueues a **scribe** "reap" for the shipped item, and a
rename/move-aware pass (`backlog-reconcile.sh`) enqueues targeted scribe fixes for any `BACKLOG.md`
entries that pointed at paths/names the PR moved — so the backlog never silently dangles. The
**scribe is the one backlog writer**; the coordinator and watcher only *enqueue*.

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
- **Re-verify at the edge** — merge only after re-confirming MERGEABLE/CLEAN + branch mapping in the
  instant before landing.
- **Verdicts are sha-keyed** — a new commit invalidates a cached BLOCK/override and re-gates from
  the top; nothing merges on a stale verdict.
- **Escalate engine bugs OUT** — never patch the engine in a consuming clone; `herd report` files it
  upstream so the fix survives `herd upgrade` and reaches every consumer.

---

## Where to look next

| You want… | Go to |
|-----------|-------|
| which module/script does what | [`docs/codemap.md`](codemap.md) — `herd codemap` |
| a def→caller function index | [`docs/symbol-index.md`](symbol-index.md) — `herd symbol-index` |
| how the runtime/multiplexer is swapped | [`docs/driver-abstraction.md`](driver-abstraction.md) |
| live pipeline state right now | `herd pane watch` / `herd status` (the watcher console) |
| this map, rendered | `herd map` |
