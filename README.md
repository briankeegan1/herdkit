# herdkit

<img width="3478" height="2228" alt="image" src="https://github.com/user-attachments/assets/bcaa4bfe-ecf0-4fab-a5b6-0c7a6332962f" />

**A durable, config-driven engine for running autonomous work through gated pipelines — built on
the herdr terminal multiplexer and [Claude Code](https://claude.com/claude-code).**

herdkit drains a backlog of **work items** into **work units** — one delivery attempt per item —
each built in isolation, gated on a healthcheck plus an adversarial review, and landed by a
detached **watcher** once every gate is green. Coding is the first, most-worked-out shape that
delivery takes (a git branch → a PR → `gh pr merge`), but it is a *kind* of work unit, not the
definition of one: the same open → gate → apply → reconcile → teardown pipeline also lands a
docs-only change straight onto the default branch with no PR at all. herdkit was extracted from a
real project so the pattern — not one project's wiring — can be reused, fixed once, and adopted
everywhere.

> **herdr vs herdkit.** `herdr` is the terminal/agent **multiplexer** (workspaces, tabs, panes,
> `herdr agent start`, notifications) — a hard dependency and the runtime substrate. **herdkit**
> is the **workflow built on top of it**. Every lane script shells out to `herdr …`; herdkit does
> not reimplement it. A `headless` driver runs the same engine with no panes at all (CI, Windows,
> headless Linux) — see [The driver seam](#the-driver-seam).

---

## What it is

herdkit is a long-lived **coordinator** that owns a backlog and delegates each item to an isolated
git-worktree **builder**, with async **scribe** and **research** lanes, a test-gated **conflict
resolver**, an adversarial **pre-merge review gate**, and a safety-railed **auto-merge watcher**.
Everything project-specific — paths, branch, model tiers, the health command, the tracker backend,
the merge policy — is read from a per-project `.herd/config`; the engine itself is generic. State
lives on disk, so the pipeline survives a builder hitting the account usage limit, the coordinator's
window closing, or the process being killed mid-drain: it resumes from where it stopped instead of
starting over.

---

## The loop

Every change — code or otherwise — moves through the same five stages, whichever **work-unit
kind** carries it (see [below](#work-unit-kinds)):

```
tracked item ──file-then-spawn──► isolated builder ──open──► gate ──apply──► reconcile ──► teardown
 (tracker)      (a builder never    (its own worktree,   (health +   (watcher lands   (tracker item   (worktree,
                starts unless it    its own branch)      review,     the change:      marked shipped;  tabs, and
                traces to a                               re-verified gh pr merge      Refs: line       ledgers
                tracker ref)                              instantly   or a scoped      resolved first,  released)
                                                           before      checkout+commit  scribe fallback)
                                                           landing)    otherwise)
```

**File-then-spawn.** Every builder spawn traces to a tracked work item — the tracker (a markdown
file, GitHub Issues, Linear, Jira, or an append-only changelog) is the single source of what is
being built, so two coordinator seats reading it see the same queue. `TRACKED_SPAWNS=required`
enforces this; `CLAIM_REQUIRED=on` adds an atomic pre-spawn claim so two seats can't double-build
the same item.

**Isolated builder.** The item is built in its own git worktree and branch — never the shared
checkout — by a sub-agent that opens a change and stops; it never merges, never edits the backlog,
never writes tracker state.

**Gate.** The watcher runs a healthcheck (project-defined, `HEALTHCHECK_CMD`) and an adversarial
review (a strong model reading the diff against `REVIEW_CHECKLIST`, default-to-BLOCK) — both
re-verified in the instant before landing, not just once earlier in the run.

**Apply.** For the `git-pr` kind this is `gh pr merge`; for `doc-apply` it's a scoped
`git checkout <revision> -- <paths>` + commit + push straight onto the default branch, no PR
anywhere in the chain. Either way it is **at-most-once** per revision.

**Reconcile + teardown.** The tracker item is marked shipped (an explicit `Refs:` line first, a
fuzzy scribe match otherwise) and the worktree, tabs, and ledgers are released — whether the merge
was performed by this seat's watcher, a foreign seat's, or a human clicking "merge" in a browser.

The lane scripts that carry this out:

| lane | script | what it does |
|---|---|---|
| **coordinator** | `coordinator.sh` | (re)launches the 2-pane control room: `[ live backlog │ /coordinator agent ]` with the watch console pinned below. Owns the backlog and delegates; never edits code in the main checkout. |
| **feature** | `herd-feature.sh` | full lane: a worktree off the latest default branch + `[ app preview │ sub-agent ]`. The agent builds the change and opens its work unit. |
| **quick** | `herd-quick.sh` | lightweight sibling for trivial / non-app changes: a worktree + a single agent pane, no preview. Same isolation + delivery flow, less ceremony. |
| **scribe** | `scribe.sh` / `scribe-step.sh` | async, serialized tracker writer. The coordinator *enqueues* changes; one drainer applies them through the active backend and commits (for the `file` backend) — so writes never clobber and the coordinator window stays free. |
| **research** | `research.sh` / `research-step.sh` / `research-get.sh` | read-only repo research queue. Fan-out Explore subagents, one report file per question; never mutates the repo. |
| **resolver** | `herd-resolve.sh` | isolated, test-gated conflict resolver for a CONFLICTING PR. Merges the default branch in, fixes **mechanical** conflicts, verifies, pushes — or aborts and **`ESCALATE:`**s a semantically-ambiguous one. Never blind-merges. |
| **review** | `herd-review.sh` | adversarial pre-merge correctness gate (a strong model, default-to-BLOCK). Reads the diff against the project's `REVIEW_CHECKLIST` and prints one machine-parseable verdict: `REVIEW: PASS` / `REVIEW: BLOCK — …`. |
| **watcher** | `agent-watch.sh` / `herd-watch.sh` | the live status console + auto-merge state machine. Applies only a unit that is gate-green, re-verifying in the instant before landing. Owns teardown after every merge, surfaces **dead builders** and **limit-parked** ones, and auto-resumes the latter. Safety-railed and idempotent. |

Two threads run through the whole pipeline: an append-only **engine journal** (`.herd/journal.jsonl`)
records every gate event as a forensic trail, and the watcher's review gate can **auto-bounce a
BLOCK back to the builder** to fix and push (`REVIEW_AUTOFIX`) — a failed review re-tasks itself
instead of stalling.

---

## The control room

`herd init` seeds the project, then `coordinator.sh` (or `herd reload`) stands up a small, fixed
set of panes: a **coordinator** pane (the LLM agent reading the tracker and dispatching lanes), a
pinned **watcher** console (the live gate/merge state machine — polls on a fixed tick, default
10 seconds), and a **backlog** pane showing open work. `herd pane <watch|backlog|coordinator>`
restarts one piece in place; `herd reload` rebuilds the whole room around a live coordinator without
closing it. With **`WATCH_HOTKEYS=on`** (default `off`, byte-inert, armed only on the watcher's own
interactive tty) the console gains a `v: view` hint row and `v` flips the `WATCHER_VIEW` lens
`mine` ↔ `all` **in memory for that watcher process only** — `herd config set` stays the durable
path. Everything the control room drives is generic engine + lane scripts — see
[`docs/COORDINATOR-SOP.md`](docs/COORDINATOR-SOP.md) for the full attended/unattended operating
playbook, escalation paths, and the state-machine handshake between coordinator, builder, and
watcher.

---

## The specialist agent roster

A builder carrying a **domain** definition makes materially fewer domain mistakes than a generic
one. herdkit ships that as a **committed roster**: `.herd/agents/<name>.md` — frontmatter
`name` / `description` / `sentinel`, body = the system prompt — scaffolded by `herd agents new`,
reviewable in the PR that changes it. Select one for a build with `HERD_AGENT=<name>` on the
feature / quick lanes; unset is a byte-identical spawn argv and task spec.

Committing definitions is necessary but **not sufficient**, because each runtime resolves them
differently — so the roster is a driver binding, not a convention:

| runtime | where it looks for definitions | by-name selector | mode | how a definition reaches a build |
|---|---|---|---|---|
| `herdr-claude` / `headless` | `.claude/agents/` — **repo** scope | none | `native` | already in the repo; with no selector the lane injects the body |
| `grok` | `~/.grok/agents/` — **user** scope | `--agent <name>` | `install` | published to user scope, then selected by name on the spawn argv |
| `codex` | none | none | `inject` | the lane prepends the definition body to the task spec |

`herd agents install` publishes the committed source to the active runtime's real lookup path —
load-bearing on a user-scope runtime, a clean no-op everywhere else, so the operator never has to
know which case they are in. Prompt **injection** is built as the first-class portable fallback, not
a degraded path: it is the one mechanism that works on any runtime, including one whose vendor never
ships the feature.

**The trap the verifier exists for.** An unknown agent name is *silently ignored*: the runtime does
not error, does not warn, does not exit non-zero — it runs as a plain builder, and the only symptom
is the agent making exactly the mistakes its definition forbids. A check that cannot fail proves
nothing, so `herd agents verify` is **empirical and two-sided** — it asks for a `sentinel:` string
that exists *only* inside that definition (proof the definition reached the model) **and** runs the
same probe against a name that provably does not exist (proof the probe is able to fail). Verdicts
(`ok` · `unresolved` · `indeterminate` · `no-sentinel` · `unverified`) cache by *(driver, definition
sha)*, so editing a definition invalidates its own verdict; `herd agents list` and `herd doctor`
read the cache, `herd doctor --probe` re-runs it live. Nothing here ever blocks: a name the cache
says does not resolve prints a **loud warning and spawns anyway**. The prototype evidence, the two
traps, and the per-runtime pre-audit are in
[`docs/spikes/specialist-agent-roster.md`](docs/spikes/specialist-agent-roster.md).

---

## The published plan

A coordinator's ranked *what we build next* used to live only in a conversation, where a second seat
could not read it and countermanding it meant cancelling N spawns by hand. `herd queue plan`
publishes the whole list as data — one TAB-separated candidate per line
(`<slug> <lane> <ref|-> <after|-> <task>`), **top candidate first; line order is the priority**.
Every candidate is enqueued through the shipped `spawn.sh` (same tracked-spawn gate, same ref
threading — no parallel implementation), then ONE pointer rename makes the new plan live and the
previous one dead in the same instant: supersede, never N cancels, with no window where both
generations drain and none where neither does. Validation runs over every line *before* anything is
published.

`herd queue list` and the watch console's **planned work** section render that plan through the same
reader, so the CLI and the pane can never disagree and a second seat *reads* the plan instead of
re-deriving it.

Underneath, **`INTENT_QUEUE=on`** (default **off**, ship-dormant) turns the durable spawn queue from
plain FIFO into a priority-ordered **intent** drain, so a slot that frees while the coordinator is
between turns gets filled by the watcher's drain instead of waiting for the next human turn; an
intent that ages past its TTL is retired to a loud `needs you` row (cleared with `herd intents`)
rather than launching stale. Off, the drain is byte-for-byte the pre-lever FIFO. Design:
[`docs/spikes/coordinator-work-queue.md`](docs/spikes/coordinator-work-queue.md).

---

## Work-unit kinds

The vehicle a change ships through is a thin **work-unit interface** (design:
[`docs/spikes/work-unit-abstraction.md`](docs/spikes/work-unit-abstraction.md)) — `open` / `gate` /
`apply` / `reconcile` / `teardown`, selected by `.herd/config`'s `WORK_UNIT_KIND`. Two kinds ship
today:

| kind | default? | vehicle |
|---|---|---|
| `git-pr` | **yes**, unqualified default | `gh pr create` → health + review gates → `gh pr merge`. Branch protection and PR review are the durable, auditable delivery vehicle for code |
| `doc-apply` | opt-in | a `<slug>.unit.json` manifest of `docs/`-scoped paths, landed straight onto the default branch with a scoped `git checkout <revision> -- <paths>` + commit + push — **no PR anywhere in the chain**, but the same health + review gates still run against the isolated worktree first |

A `doc-apply` manifest's paths must clear a fail-closed allowlist (`DOC_APPLY_PATH_GLOB`, default
`^docs/`) and each must resolve to exactly one real file at that revision — never a directory, never
a wildcard, never a silent partial apply.

`WORK_UNIT_KIND` unset (or any value a given kind doesn't cover) always resolves to `git-pr` — a
loud warning, never a silent behavior change. A `doc-apply` unit only exists once a manifest is
actually written to disk; with none present the lane is a hard no-op and nothing about the `git-pr`
path changes. This is the seam that keeps herdkit's arc general: coding is the first work-unit kind
worked all the way through, not the shape every future one has to fit.

---

## Tracker backends

`herd backlog` prints the project's open work items through the active `SCRIBE_BACKEND`, so the
same command answers "what's my open work?" regardless of where the tracker lives: a markdown file
(**`file`**, default, zero-secret, no network), **`github`** (Issues), **`linear`**, **`jira`**, or
an append-only **`changelog`**. Every backend emits the same one-line `#<id> <title>` shape and
implements the same small contract (add / mark-shipped / list-open, plus atomic claim); the API
backends (`github`/`linear`/`jira`) read credentials from `.herd/secrets` (gitignored) — the file
and changelog backends never touch it. Switch backends with one guided command:

```sh
herd backend switch <file|github|linear|jira|changelog> [--migrate]
```

which preflights credentials before changing anything, flips `SCRIBE_BACKEND` through the validated
config path, and — with `--migrate` — replays the old backend's open items into the new one.

> **Running the fleet against Jira?**
> [`docs/jira-guide.md`](docs/jira-guide.md) is the end-to-end walkthrough — credentials and
> project scoping, the issue → builder → PR → Done lifecycle against a Jira project, and the
> adapter's current limits.

If your Linear workspace hosts more than one team's issues under the same API key, set
`LINEAR_TEAM_ID` (`herd config set LINEAR_TEAM_ID <id>`, or alongside the API key in
`.herd/secrets`) to scope `herd backlog` and new-issue creation to just this project's team; unset
is byte-identical to before (every team the key can see).

---

## Multi-seat operation

herdkit is designed to be worked by **several coordinator seats at once** against the same repo —
each with its own watcher, builders, and merges. The [multi-seat doctrine](docs/multi-seat-doctrine.md)
is the two rules that keep them from interrupting each other:

1. **Prefer reconciled invariants over event side-effects.** State a behavior as *"the committed
   map matches the tree at `$MAIN`, checked every tick"*, not *"refresh the map when **I**
   merge"* — otherwise every seat but the one that happened to trigger the fix leaves the
   condition unrepaired.
2. **One shared deterministic check, enforced identically at every surface.** A rule that gates the
   merge but that the builder's own pre-PR profile can't see just gets authored clean, passes
   locally, and bounces at the gate later — wasted work that a single shared implementation would
   have caught up front.

On top of the doctrine, the dispatch-discipline levers are opt-in and byte-inert until set:

- **`TRACKED_SPAWNS=required`** refuses a spawn carrying no tracker ref.
- **`CLAIM_REQUIRED=on`** adds an atomic pre-spawn claim through the active tracker backend — a
  spawn on an item already claimed by someone else aborts loudly; fails soft when the backend is
  unreachable, so a solo operator is never hard-blocked.
- **`herd config set --shared <KEY> <VAL>`** applies a project-scoped policy change to the
  committed baseline via a tiny single-file PR (`config/<key>`), so an operator who can't push to
  the default branch still propagates policy the gated way.
- **`WATCHER_SCOPE=all`** turns on team mode: teammates' PRs are *displayed* but auto-merge is
  strictly scoped to `WATCHER_OWNER`'s own — a narrowing gate that can only withhold a merge, never
  authorize one. (See the honest scope note below: the default `mine` does **not** apply that
  narrowing.)

---

## Multi-operator ownership

The doctrine above keeps many seats correct when **one** operator runs them all. The adjacent,
narrower question — **different** operators sharing one repo — has its own invariant, and it was
grounded by an incident (two operators, one repo, 2026-08-12): a seat's `RESOLVE_AUTOFIX` rail
discovered a `CONFLICTING` PR authored by the *other* operator, mid-edit under a standing
do-not-touch rule, and dispatched the isolated conflict resolver at that branch. A manual interrupt
caught it. **No surface in the write path asked whose PR it was.**

> **A seat's automation must never write to another operator's branch, or clear another operator's
> holds, without an explicit, journaled override.**

**`AUTOFIX_SCOPE`** (`own` **default** | `all`) is the one shared check that enforces it — a single
implementation, per Rule 2 above, consulted by all four autofix **write** rails: `RESOLVE_AUTOFIX`
(resolver dispatch), `STALE_BASE_AUTOFIX` (merge-up bounce or resolver dispatch), `REVIEW_AUTOFIX`
(re-task bounce on a BLOCK) and `HEALTHCHECK_AUTOFIX` (re-task bounce on a reproduced code error).
`own` resolves the seat's identity exactly the way `WATCHER_OWNER` already does (`WATCHER_OWNER` →
`WATCHER_VIEW_AUTHOR` → `gh api user`, memoized once per process — never one probe per candidate)
and fails **closed**: an unresolvable identity, or an author that does not match it, *withholds* the
write and journals `autofix_scope_withheld` (pr, author, rail) so the coordinator sees the withhold
without a human pasting a pane. `all` is the previous behavior, kept as an explicit opt-in.

Two of those four rails are honest-but-incomplete today: `REVIEW_AUTOFIX` and `HEALTHCHECK_AUTOFIX`
carry the scope check in the tested bash spec, but the engine's live bounce path — shared across
every refix kind since the Python port — still bounces unconditionally, so the check does not yet
gate a live write there. That gap pre-dates the key and is named, not papered over.

`WATCHER_SCOPE` resolution is fail-closed on the same principle: when the live watcher process never
received the key at all, the engine core treats it as **unresolved** and applies team mode's
ownership gate rather than silently degrading to the permissive default, journaling one
`scope_unresolved` event per signature (self-healing once it recovers).

**Honest scope note.** `WATCHER_SCOPE=mine` — the shipped default — is a **no-op**, not own-only: it
skips the ownership comparison entirely, so a teammate's PR this seat happens to hold a local
worktree for is an ordinary auto-merge candidate. That is a real, currently-shipped gap; it is
narrower than it sounds (nothing merges *ungated* — the healthcheck, the adversarial review and
`require herd/gates` protection all still apply), and it is named as open rather than quietly
patched. [`docs/multi-operator-ownership.md`](docs/multi-operator-ownership.md) grades every surface
where one seat's automation can act on another operator's PR, worktree or hold — own-only, all
with attribution, or unscoped — and lists the gaps still open.

**Who is on it — `TEAM_PRESENCE`** (default **off**). The watcher discovers work through *local* git
worktrees, so a PR a teammate is actively building on *their* machine has no builder record here and
renders as `ungated — no builder record — … adopt`: uninformative on a solo repo, actively wrong
advice on a shared one. On, the watcher re-uses the existing claim machinery rather than inventing a
presence channel — a claim already sets an item's assignee and moves it in-progress, and every PR
body already carries its tracker ref — to join each ungated PR to its item on a throttled ~60s
cadence (one tracker round-trip per scan, cached for the 4s repaints). An in-progress, assigned item
renders the compact `👤 #<pr> <title> · <name> — building <id>` with the adopt nudge suppressed; an
unclaimed one renders `👤 #<pr> <title> · authored by <author> (no tracker claim)` — attribution
without inventing a claim. `TEAM_ALIASES` overrides the displayed name. Strictly read-only: it
writes no tracker state, opens no channel, and never gates or merges. Off is byte-inert.

---

## CI as the gate

The health verdict does not have to come from a suite this machine runs. **`HEALTH_SOURCE=ci`**
(default `local`, ship-dormant) stops the watcher dispatching local PR suites entirely and reads the
PR's own GitHub Actions conclusion **for its exact head sha** instead — the same suite CI already
ran in parallel, at zero local slot cost, so `HEALTH_CONCURRENCY` stops being the pipeline's
bottleneck and gate latency collapses to CI's own wall-clock. One shared implementation
(`pysrc/herd/ci_verdict.py`) decides all five mappings, so the watcher's gate, the main-health leg
and the fast-bounce leg can never disagree:

- **green** for the head sha → CLEAN; it merges through the ordinary rails.
- **red naming a real test** → CODEERROR carrying that test as the bounce evidence, on the *same*
  health rail a local red bounces on — same sha-keyed once-guard, same `REFIX_MAX_ROUNDS` budget,
  one rail, never two.
- **pending, or a cancelled-run chain** → WAIT. A cancel is no signal, never a red.
- **platform-infra failure** (action download, `Service Unavailable`, a runner that never acquired
  the job, a concurrency cancel) naming *no* test → WAIT plus one bounded, journaled
  `gh run rerun --failed` per run id. Only a completed run whose failures carry real test output is
  ever a code red.
- **no CI run at all**, or an unreachable / unauthenticated `gh` → fall back to the local suite and
  journal a loud `ci_health_fallback`. Never a silent skip, never an invented verdict.

Both hard rules are scar tissue: a real Actions outage held main red overnight, and a dispatched
verdict-collector that died mid-read stranded a main red for three days — so the verdict is a
per-tick *reconciled read* of live CI state, with no dispatched worker, no marker and no sha-cache
that a dying tick could strand.

**Diff-scoped CI.** The workflow's runner scopes the curated suite to the PR's diff (against its
merge-base with the base ref) **before** sharding it, so a shard whose scoped slice is empty exits
green in seconds instead of paying for a runner with nothing to run. Every run prints
`scoped N of M curated tests (reason)` — there is no silent cap. Three paths fail **closed** and say
so: no base ref (a push to main, or any caller that never opts in), a diff that cannot be obtained,
and a selection that comes back as the whole curated set (a wide-blast or unmappable path) each run
the full curated sharded set exactly as before.

**The blessing.** Independently of where the verdict comes from, **`GATE_STATUS=on`** (the default)
has the watcher post a `herd/gates` commit status as it clears each *(pr, sha)* — `success` only,
exactly once, and only ever by a watcher that actually ran the gates. Pair it with
`require herd/gates` branch protection (recipe:
[`docs/governance-gates.md`](docs/governance-gates.md)) and the gate becomes **fail-safe** across
seats and collaborators who keep merge rights: anyone may merge, but nothing **ungated** can,
because a commit no watcher blessed carries no success status. A gate FAIL posts *nothing* — the
fail-safe rests entirely on the absence of success, never on a red status, because a non-passing
status would flip a CLEAN sha out of the merge loop and silently break the block / override /
auto-refix paths.

---

## The driver seam

Almost everything the coordinator runs — the `herd` CLI, the lane scripts, `gh` — is runtime
independent. Only two surfaces are runtime-specific, and they are factored into a **driver**
(design: [`docs/driver-abstraction.md`](docs/driver-abstraction.md)):

1. **The multiplexer** — today `herdr` (tabs, panes, agent-status). A `headless` driver ships too:
   panes become an optional cockpit, not a dependency — a detached background process + a
   file-backed agent registry cover the same capabilities with no herdr at all, so the whole
   pipeline runs on Windows / CI / headless Linux.
2. **The agent runtime** — `templates/drivers/*.driver` files bind each capability (spawn, one-shot
   exec, resume, model-switch, permission flag, limit-detection, session identity, cost parsing, and
   the three agent-roster bindings above) to a concrete incantation. Three real runtimes ship:
   **`herdr-claude`** (the default, Claude Code), **`codex`** (OpenAI Codex CLI) and **`grok`** (xAI
   Grok Build CLI) — set `HERD_DRIVER=codex` (or `grok`) and the interactive-spawn lanes
   (`herd-feature.sh` / `herd-quick.sh` / `herd-resolve.sh`) compose that driver's real spawn argv
   instead of `claude`'s. herdr stays the multiplexer for all of them; only the agent process
   changes. A `stub.driver` proves the whole seam end-to-end without needing any third-party CLI.

**The `@degrade:` honesty convention.** A capability a runtime does not have — or that nobody has
*verified* it has — is bound to an explicit `@degrade:<reason>` sentinel rather than a guessed
incantation, and every consumer reads a `@degrade:` value as **absent** and takes its portable
fallback. That is why codex, which has no named-agent selection at all, degrades to prompt
injection instead of silently mis-selecting; why the non-Claude limit-detection and cost-token
bindings read `@degrade:no-verified-…-banner` instead of a plausible-looking regex; and why grok's
bindings ship marked verified-by-report on a machine where grok is not installed. The sentinel is
the difference between "we know this doesn't work" and "we hope this works."

The default (`HERD_DRIVER` unset, i.e. `herdr-claude`) is byte-identical to a herdkit with no driver
concept at all — the abstraction is additive, not a rewrite of the supported path.

---

## Governance profiles + fleet

A project's **governance** — merge/gate/PR/attribution/commit policy — is exportable as a portable,
versioned profile:

```sh
herd governance export --file gov.profile   # write the governance-scoped keys (secrets never travel)
herd governance apply gov.profile           # propose each key via the validated 'herd config set'
herd init --governance gov.profile          # seed a fresh install from a profile
herd fleet set --profile gov.profile        # roll a profile out across every registered project
```

`herd config set --shared` (above) is one way to change a *single* project's policy; a profile is
how the same stance travels between projects or gets captured for review. A profile is never
required to configure a project — it composes with the interview, manual `herd config set`, and
whatever a project's own `CLAUDE.md`/`AGENTS.md` already states (adoption is deterministic table
matching, never an LLM guess, and every source is optional and coequal).

`herd fleet` is a **deterministic, no-LLM** fan-out over a flat project registry (default
`~/.herd/fleet`) for running one herd install across many repos — `status` (per-project rollup:
branch, open PRs, watcher alive?, last activity), `inbox` (what needs you *now*, across projects),
`digest` (cross-project standup from each journal), `graph` (registry nodes + `.herd/links` /
`.herd/deps` edges), `set` (propagate one policy, validated per project), and `upgrade` / `reload`.

Every subcommand delegates to each project's own `herd` command and never mutates a tree beyond
what that delegated command already does, with one exception: `herd fleet new` seeds a BRAND NEW
project (that is its job) — `--archetype` / `--posture` pass straight to `herd init`; with neither
flag and no tty, it picks defaults itself and prints them loudly rather than silently defaulting to
a code-shaped project. A missing / dirty / `gh`-unavailable project is reported, not fatal.

---

## The sandbox sim rig

`scripts/herd/sim/` is a **zero-quota, deterministic** test rig for the workflow itself — it drives
the real gate/merge/concurrency/limit-park/pane machinery with **stub builders (no model call)**,
so behaviors that are otherwise expensive and non-deterministic to exercise get a hermetic proof.
It's a fidelity ladder:

| tier | proves |
|---|---|
| **P0** | happy path + gate-fault isolation; an unattended N-item drain that survives a hard `SIGKILL` and resumes from disk with **0 duplicates** |
| **P1** | `REVIEW_CONCURRENCY` / `HEALTH_CONCURRENCY=1` respected, no double-merge, queue drains — against the **real** watcher gate loop, N≥3 PRs |
| **P2a** | limit-park **detect → park → schedule → resume → complete**, plus the kill-switch — against the **real** watcher limit path |
| **P2b** | pane/tab existence + labels, agent `idle→working→done`, clean teardown (0 leaks) — against a **real, disposable** herdr control room |
| **P2c** | a real `gh pr create` / watcher poll / `gh pr merge` against an **opt-in, disposable** GitHub repo, auto-deleted on teardown |

Alongside the ladder, one scenario per hard-won behavior: **two real** watcher loops against a
shared stub remote (no duplicate gate runs, no double resolver dispatch), the whole governance
import → enforcement chain, a stale-engine watcher quiescing and re-execing onto new code
mid-drain, and a builder force-killed at every lifecycle stage leaving no corpse, no stacked
respawn and an honest tracker claim.

P0–P2a are fully hermetic (local git only, no hosted repo, no panes); P2b stands up a real but
disposable herdr workspace and P2c a real but disposable GitHub repo, both degrading to a clean skip
where the dependency is unavailable. Scenario-by-scenario detail:
[`scripts/herd/sim/README-sandbox-sim.md`](scripts/herd/sim/README-sandbox-sim.md).

---

## Grounding & efficiency

Builders don't re-explore the tree every session, and the review gate doesn't spend a strong model
on a docs typo:

- **Committed, deterministic engine maps.** `herd codemap` writes `docs/codemap.md` (file-level:
  module roles, who-sources-whom, config-key→consumer wiring) and `herd symbol-index` writes
  `docs/symbol-index.md` (function-level def→caller index); `herd map` renders the operator-facing
  flow diagram, `docs/control-room-map.md`. All three are bash-native, LLM-free, and idempotent —
  zero model quota, diff-reviewable — and the watcher regenerates + commits the first two after
  each merge, fail-soft.
- **Builder grounding via `CONTEXT_PROVISION`.** Set `CONTEXT_PROVISION=codemap` and every spawned
  builder's task spec tells it to read `docs/codemap.md` first, in the prompt-cache-shared stable
  prefix — so it starts oriented instead of grepping. Unset (default) leaves task specs
  byte-identical to before.
- **Risk-tiered review — `REVIEW_ESCALATE_GLOB`.** Off by default (every unit gets the full strong
  review). When set, engine-critical paths or a large diff get the strong reviewer; a docs/test-only
  diff is skipped with a `source=skipped-low-risk` PASS; any other small low-risk diff uses the
  cheaper `REVIEW_MODEL_CHEAP` tier. Classification fails safe (an unreadable diff → strong).
- **Healthcheck profiles — `HEALTHCHECK_HEAVY_GLOB`.** Match the diff paths that warrant the full
  suite; everything else runs the light `bash -n` profile.
- **Cost measurement — `herd cost` / `herd stats`.** `herd cost` reads the journal's token/$ events
  and reports per-unit and cost-per-merged-unit; `herd stats` is the zero-LLM digest of the same
  journal window (merges, review verdicts by provenance, refix bounces, limit park/resume). Both
  read-only — they measure, they never change a gate.

---

## Durability & forensics

- **Limit-park auto-resume.** When a builder's turn ends on the account usage limit, a `rate_limit`
  hook writes a per-worktree sentinel with the reset time. The watcher polls it, shows a
  **non-red** `limit-hit · auto-resume at HH:MM` row (a usage limit is an expected account event,
  not a failure), and at the reset relaunches the builder in place via `claude --continue`
  (`HERD_LIMIT_RESUME_BUFFER` waits past the exact reset instant; `HERD_LIMIT_DETECT=off` is the
  kill-switch).
- **Engine journal forensics.** The append-only `.herd/journal.jsonl` records every gate event.
  `herd log [--pr N] [--tail]` pages or follows the raw stream; `herd why <pr#>` reconstructs one
  unit's full gate history chronologically — the first post-mortem tool for "what happened to
  this one." `herd status` prints a one-shot, read-only, no-LLM health snapshot (watcher alive?
  dead builders? conflicting / blocked units?). `herd sweep [--dry-run]` runs every reaper the
  engine owns on demand (stale worktrees, tabs, dead-pid markers, orphaned processes, a watcher
  restart) — anything not provably disposable is flagged with evidence, never deleted.
- **Capability conformance.** `herd conformance report` joins `templates/capabilities.tsv` (every
  shipped capability) against `templates/conformance.tsv` (its proof mapping — a unit/sim/render
  test), so a capability with no proof, or a proof pointing at a deleted test, is a visible gap
  instead of a silent one.

---

## Install

**Requirements:** `herdr` (the terminal multiplexer), `claude` (Claude Code CLI), `gh`, `git`,
`python3`, and a modern `bash`. No specific OS or package manager is assumed — these tools work
on macOS and Linux alike. **On Windows, run herdkit under WSL2** (Ubuntu) — the supported path;
native Git Bash is best-effort only. See [`docs/windows.md`](docs/windows.md).

> **Running unattended on macOS?** macOS **TCC** permission prompts (Full Disk Access, Automation)
> can silently pause a builder that touches a protected resource with no one there to click Allow.
> Pre-grant the right permissions and run headless so a hidden consent dialog never stalls the herd —
> see [`docs/macos-unattended-permissions.md`](docs/macos-unattended-permissions.md).

### One command (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/briankeegan1/herdkit/main/install.sh | bash
```

This clones herdkit to `~/.herdkit`, symlinks the `herd` entrypoint into the first writable
directory on your `PATH` (or prints the exact `export PATH=…` line to add if none is writable),
runs `herd doctor` to flag any missing dependencies with per-platform install hints, and finishes
with the two-step quickstart. It is **idempotent**: re-run it any time to fast-forward-update the
engine (`git pull --ff-only`) and re-verify — it never clobbers local state, and refuses politely
on a dirty engine checkout (commit/stash first, or pass `--force`). Only `bash`, `git`, and `curl`
are needed to bootstrap. Install elsewhere with `HERDKIT_HOME=/path bash install.sh` (or pipe as
above with the env var set).

Then:

```sh
cd your-project
herd init
```

### Manual — clone + wire PATH yourself

```sh
git clone https://github.com/briankeegan1/herdkit.git ~/source/herdkit

# then pick ONE:
export PATH="$HOME/source/herdkit/bin:$PATH"        # zero-assumption; add it to ~/.bashrc / ~/.zshrc
ln -s ~/source/herdkit/bin/herd ~/.local/bin/herd   # symlink into any writable PATH directory
bash ~/source/herdkit/install.sh                    # auto-detect: picks the first writable one
```

The default **file** work-tracker backend needs no network and no secrets.

## Quickstart — `herd init`

From inside the project you want to herd:

```sh
cd ~/source/myproject
herd init          # interviews + scouts the repo, writes .herd/config, renders the skill
```

`herd init` **scouts** the repo (language/build, CI, branch protection, existing trackers) — and is
**stack-aware**: it detects the language (node / python / go / rust / java) and seeds
`.herd/healthcheck.project.sh` from the matching template, leaving non-Python repos free of
Python-shaped defaults. It also asks for a **project archetype** — `code` (default; the stack-aware
seeding above), `research-lab`, or `docs` — for a repo with no test suite to run: those two seed a
markdown/link/template-conformance lint instead, so a docs-only or research repo with
`language=unknown` never gets stuck with the Python-test-suite example. It runs the **work-tracker
discovery dialogue** (detects `BACKLOG.md` /
`TODO.md` / `CHANGELOG` / GitHub Issues; asks whether you use Linear/Jira), then writes:

- **`.herd/config`** — your project's answers (paths, default branch, model map, health/preview
  commands, privacy paths, routing, `WORK_UNIT_KIND`). Committed; **zero-secret**.
- **`.claude/commands/coordinator.md`** — the coordinator skill, *rendered* from
  `templates/coordinator.md.tmpl` with your config baked in (no conditionals — it reads as if
  hand-written for your project). Regenerate it any time with `herd upgrade`.
  **Gitignored, per-machine** (like `.herd/config.local`): the render is a derived artifact, never
  committed — teams share the *template*, and `herd init` / `update` / `reload` / `render` each
  rebuild it locally. A tracked copy would dirty every checkout the moment any of those ran.

Then launch the control room:

```sh
bash ~/source/herdkit/scripts/herd/coordinator.sh
```

## Joining someone else's herd project — `herd adopt`

`herd init` is for a project you are standing up. If you just **cloned** a project someone else
already herds, you want `herd adopt` instead:

```sh
git clone git@github.com:someone/theirproject.git
cd theirproject
herd adopt          # localize the clone for THIS machine — non-interactive, idempotent
herd render         # rebuild the per-machine coordinator skill
herd reload         # bring up the control room
```

Why a second command exists: `.herd/config` is **committed**, and it carries the author's *absolute*
`PROJECT_ROOT` and `WORKTREES_DIR`. Straight out of a clone, every lane, the watcher lock, the
worktree pool and the journal resolve into somebody else's home directory. `herd adopt` derives both
paths from the clone's physical location, writes them through the validated machine-scope setter
into the gitignored `.herd/config.local` overlay (the committed baseline is never touched, so the
clone stays byte-clean for its author and your next `git pull`), creates the worktree pool,
guarantees the overlay is git-ignored via checkout-local `.git/info/exclude`, then runs the doctor
and prints the next two commands.

It takes an optional path (default: the current directory), and re-running it on an already-localized
project is a no-op report. Use it again any time a project directory is **moved or renamed**.
Findings from the onboarding session that motivated it:
[docs/audits/2026-08-05-collaborator-onboarding.md](docs/audits/2026-08-05-collaborator-onboarding.md).

## Everyday commands

`herd` with no arguments prints the full CLI;
[`docs/capabilities-overview.md`](docs/capabilities-overview.md) is
the reference map of every subcommand and `.herd/config` lever, cross-referencing
`templates/capabilities.tsv` as the machine-readable source of truth. The handful you actually
reach for:

```sh
# Keep the install + control room current
herd update [--force]        # pull the engine (ff-only), re-render the skill, reload — one step
herd reload                  # rebuild the control room (watcher + backlog pane + re-render)
herd pane <watch|backlog|coordinator>   # restart ONE control-room pane in place, no full reload
herd doctor [--probe]        # dependency doctor; --probe also re-verifies the agent roster live
herd sweep [--dry-run]       # reap stale worktrees, tabs, dead-pid markers, orphaned processes

# Dispatch + inspect the work
herd backlog [--rich]        # open work items via the active tracker backend
herd queue [list|plan]       # read / publish the priority-ordered plan this pool builds next
herd agents <list|new|show|install|verify>   # the specialist agent roster
herd status                  # one-shot read-only health snapshot for THIS project (no LLM)
herd approve [list|<pr#>|why <pr#>]   # sign off a held PR (MERGE_POLICY=approve or a human-verify hold)
herd notes / herd intents    # clear builder findings + escalated spawn intents off the console

# Configure — validated against capabilities.tsv, never a blind write
herd config <list|get|set> [--shared] <KEY> [<VAL>]   # --shared = a tiny config/<key> PR (multi-operator)
herd posture <list|show|apply> <name>   # move onto a canonical operating posture in one validated bundle
herd governance <export|apply>          # merge/gate/PR/attribution policy as a portable profile

# Grounding maps — deterministic, LLM-free, committed
herd codemap                 # docs/codemap.md (file-level engine map); --check for staleness
herd symbol-index            # docs/symbol-index.md (function def→caller index)
herd map                     # docs/control-room-map.md (the one-page pipeline flow diagram)

# Forensics — read the append-only engine journal (.herd/journal.jsonl)
herd log [--pr N] [--tail]   # page the journal: one line per gate event; --tail follows live
herd why <pr#>               # one unit's full gate history — the first post-mortem tool
herd cost [--pr N] [--full]  # token/$ accounting; cost-per-merged unit
herd stats [--today|--since <date>|--pr N]   # zero-LLM digest of the journal window
herd conformance <report|run>   # capability ↔ proof-test coverage matrix

# Several herd projects at once — deterministic, no-LLM fan-out
herd fleet <status|inbox|digest|graph|set|upgrade|reload>
```

---

## Merge control — `MERGE_POLICY` (human-in-the-loop)

The watcher runs the full pipeline — healthcheck, then the adversarial review gate — on every
ready unit. **`MERGE_POLICY`** in `.herd/config` is the primary lever over the *last* step (apply),
a three-way switch:

- **`auto`** — on a review **PASS**, the watcher lands the unit itself. Full auto, safety-railed:
  walk away and work ships.
- **`approve`** — the watcher runs every gate but **holds before applying**, flagging the unit
  `ready · awaiting approval` and notifying you. It applies only once a coordinator signs off with
  `herd-approve.sh approve <pr#>`. Approval is **sha-keyed**: a commit pushed after the approval was
  written invalidates it — the gate cycle re-runs and a fresh approval is required.
- **`observe`** — runs every gate and reports/notifies, but **never applies** under any circumstance.

Either way the watcher never applies a conflict, a BLOCK, an un-reviewed commit, or a unit whose
state changed under it.

> **`WATCHER_AUTOMERGE` is legacy.** The old boolean is superseded by `MERGE_POLICY` and kept only
> for back-compat: when `MERGE_POLICY` is unset it derives from `WATCHER_AUTOMERGE` (`true` → `auto`,
> `false` → `approve`). Prefer `MERGE_POLICY`.

### Per-PR human-verify hold

A builder can't always finish a change end-to-end itself — some steps need a running app, a UI/pane
check, or human eyes. When that happens the builder declares each such step in a **`HUMAN-VERIFY:`**
block in the PR body (one step per line). Under `MERGE_POLICY=auto` the watcher then switches *that
one PR* to an approve-style hold — reusing the same approval ledger — so **all gates still run** but
the merge waits for a human to run the steps and `herd-approve.sh approve <pr#>`. Sibling PRs without
the marker keep auto-merging; the console shows `ready · human-verify pending`, and
`herd-approve.sh list` prints the declared steps — so a manual step is never silently skipped.

### The autofix rails — a red re-tasks itself

A machine-checkable defect in the builder's *own* diff does not need a human to relay it. Four
opt-in rails bounce one straight back to the builder that produced it — the watcher wakes its idle
agent with a re-task prompt to fix and push, and the gate cycle re-runs on the new commit — sharing
one sha-keyed once-guard and one **`REFIX_MAX_ROUNDS`** budget per PR (default 3, counting every
kind together) before escalating to `needs you`:

| lever | default | what it bounces |
|---|---|---|
| `REVIEW_AUTOFIX` | `false` | a BLOCK verdict from the adversarial review gate |
| `HEALTHCHECK_AUTOFIX` | `false` | a reproduced pre-merge healthcheck **code error**, handed back with the failing test line and the tailable suite log |
| `STALE_BASE_AUTOFIX` | `off` | a **stale-base** hold — touched files moved on `DEFAULT_BRANCH`, purely mechanical. The sibling **duplicate** hold (re-implements shipped work) is always a human judgment call and never self-heals |
| `RESOLVE_AUTOFIX` | `off` | a `CONFLICTING` PR — dispatches the isolated, test-gated resolver lane |

Off, each hold path is byte-identical: the console shows the standard `review blocked` /
`conflicting` row for the coordinator to re-task by hand. On, the row reads honestly while the fix
is in flight (`fix in progress · awaiting push (round k/3)`, `rebasing · awaiting push`).

All four consult **`AUTOFIX_SCOPE`** (default `own`), so a rail only ever writes to this seat's own
PRs — with one honest caveat, and the whole ownership picture, in
[Multi-operator ownership](#multi-operator-ownership).

### "Needs you" means nobody is on it

A red row is only ever labelled `needs you` when **no agent is working that red**, and it then carries
both the blocker (which test failed) and the remedy. While a builder is fixing it — bounced by the
watcher, or re-tasked by you — the row reads `fix in progress · awaiting push (round k/3)` instead. A
`needs you` on the console is always real work for you, never work already in flight.

### Catch a BLOCK before the PR opens — `LOCAL_REVIEW=pre-pr`

By default (`LOCAL_REVIEW=none`) correctness review happens once, post-PR, in the watcher's gate.
Set **`LOCAL_REVIEW=pre-pr`** and the builder *also* runs an adversarial `herd-review.sh --local`
pass against its own worktree diff **before** opening the PR, and must reach `REVIEW: PASS` first —
fixing any BLOCK locally instead of surfacing it as a public gate failure. The post-PR gate still
runs (belt-and-suspenders), so this shifts a class of BLOCK left without weakening the merge gate.

### Team mode — `WATCHER_SCOPE` (opt-in)

On a **shared** repo, set **`WATCHER_SCOPE=all`**: teammates' PRs are *displayed* but auto-merge is
strictly scoped to PRs owned by **`WATCHER_OWNER`** — a teammate's PR shows `not mine — manual` and
is never auto-merged, even when MERGEABLE+CLEAN+approved. Pairs with the `WATCHER_VIEW` lens
(`all` / `mine` / `review-queue` / `deps`), which narrows *which* PRs the console even displays. For
multi-operator dispatch discipline, pair it with `TRACKED_SPAWNS` + `CLAIM_REQUIRED` (see
[Multi-seat operation](#multi-seat-operation)).

The default `mine` does **not** apply that narrowing — it skips the ownership comparison entirely,
so on a shared repo `all` is the setting that actually scopes auto-merge. What the engine *does*
scope by default is the four autofix write rails (`AUTOFIX_SCOPE=own`); see
[Multi-operator ownership](#multi-operator-ownership) for the full grading.

### Where the health verdict comes from — `HEALTH_SOURCE`

The healthcheck half of the gate can be the local suite (`local`, default) or the PR's own CI
conclusion (`ci`) — same rails, same refix budget, one shared verdict implementation. See
[CI as the gate](#ci-as-the-gate).

---

## Fork vs config — how to customize

herdkit is **one engine, many consumers**. You almost never fork it:

- **Consuming projects customize via `.herd/config` + project override hooks in their own repo** —
  paths, branch, the workflow's own display brand (`WORKSPACE_NAME`), model map, the health command
  (`HEALTHCHECK_CMD`), the resolver smoke gate (`SMOKE_CMD`), the review risk list
  (`REVIEW_CHECKLIST`), privacy paths (`DENY_PATHS`), the work-tracker backend (`SCRIBE_BACKEND`),
  the work-unit kind (`WORK_UNIT_KIND`), the engine-bug escalation target (`HERD_REPO`), grounding
  sources (`CONTEXT_PROVISION`, `MCP_PROVISION`), the runtime driver (`HERD_DRIVER`), and the merge
  levers above. The generated skill renders these in. **Not a fork.** Engine improvements arrive via
  `herd upgrade`.
- **The herdkit owner develops the engine directly** in this repo (branch → PR → merge). herdkit is
  itself developed *using the herd* (its own `.herd/config`, `BACKLOG.md`, and coordinator skill —
  the ultimate dogfood).
- **Forking is only for diverging the engine itself** — e.g. replacing herdr with a different
  multiplexer or rewriting the watcher state machine. Per-project config does **not** belong in a
  fork; it belongs in `.herd/config` in the consuming repo.

### The feedback loop

When a consuming project hits an **engine** bug (a lane mislabels state, the watcher races, a
script leaks an assumption), don't patch it locally — that fix would be lost on the next
`herd upgrade` and never reach other consumers. File it out:

```sh
herd report "watcher merged a CONFLICTING PR — agent-watch auto-merge lane"
```

That opens a `gh issue` on `HERD_REPO`, stamped with your project + lane + version pin. The herdkit
coordinator drains those issues, fixes once, cuts a release, and every consumer adopts the fix with
`herd upgrade`. (An **app** bug — the symptom is in *your* code — stays local: a normal feature
lane. The coordinator skill carries this routing rule.)

---

## Where it's going

The direction is **build-your-own-workflow**: the same engine, configured — not forked — for any
project, and increasingly for work that isn't a GitHub PR at all. The seams already carry this —
pluggable **work-unit kinds** (`WORK_UNIT_KIND`, `git-pr` shipped, `doc-apply` shipped opt-in),
pluggable **work-tracker backends** (`SCRIBE_BACKEND`), a runtime **driver** binding (`HERD_DRIVER`,
with `headless`/`codex`/`grok` shipped alongside the default), pluggable **grounding sources**
(`CONTEXT_PROVISION`, `MCP_PROVISION`), and now a per-project **agent roster** (`HERD_AGENT`) — so
the near work is widening each: a `config-apply` work-unit kind for committed, non-secret config
surfaces; routing resume / model-switch / limit-detection through the non-Claude runtime drivers
(today only interactive-spawn and the agent-roster bindings are routed); more trackers; more
grounding lanes — each a small, well-scoped adapter behind a documented contract.

The other live thread is **many operators, not just many seats**: `AUTOFIX_SCOPE` scoped the four
autofix write rails this month, and the remaining unscoped surfaces are enumerated as open gaps in
[`docs/multi-operator-ownership.md`](docs/multi-operator-ownership.md) rather than quietly patched.
A few durability seams are still open too — tracked in `BACKLOG.md`, shipped dormant behind
default-off opt-in flags rather than self-activating.

---

## Philosophy

A handful of invariants recur across the engine because they were each learned the hard way (the
audit trail behind them is committed at [`docs/audits/`](docs/audits/)):

- **The gate merges — never a hand-merge.** The coordinator never calls `gh pr merge`, never
  bypasses a gate for mechanical reasons, and never hand-resolves a conflict except through the
  resolver lane. Its job at the merge stage is to route `needs you` rows, not to act as a second
  merge path.
- **Reconciled invariants over event side-effects.** A behavior that only self-repairs when *this*
  seat performed the triggering action leaves every other seat's version of that condition broken.
  State it instead as something checked and healed on every tick, regardless of who caused it.
- **No false-red consoles.** A red row must be verified-real — retry transients before alarming,
  and label infra/flaky distinctly from an actual code error. An operator who learns to ignore red
  rows has been trained to ignore the real ones too.
- **Fail-soft on optional dependencies.** A missing OPTIONAL tool, file, or capability skips
  silently — it never produces a red row and never aborts a caller running under
  `set -euo pipefail`. Gate keys fail strict instead: the safest default, with a loud warning.
- **Ship-dormant defaults.** New behavior is gated behind a config key (or an explicit opt-in)
  whose default is off, and turning it off is a hard no-op — byte-identical output, argv, and
  generated files to before the lever existed. So most of what this README describes is **off in a
  fresh install** — `HEALTH_SOURCE=ci`, `INTENT_QUEUE`, `TEAM_PRESENCE`, all four autofix rails,
  `LOCAL_REVIEW=pre-pr`, `WATCHER_SCOPE=all`, `REVIEW_ESCALATE_GLOB`, `CONTEXT_PROVISION` — each one
  `herd config set` away, and `herd posture apply` arms a whole coherent bundle at once.
- **Every builder traceable to a tracked item.** File-then-spawn is not a style preference: an
  off-book build is invisible to every other coordinator seat reading the same tracker, and
  invisible work is exactly what causes double-builds and lost context between sessions.

---

## Layout

```
bin/herd                       the CLI (init / doctor / upgrade / config / fleet / report / codemap / …)
scripts/herd/                   the generic engine (sources .herd/config via herd-config.sh)
  coordinator.sh  herd-feature.sh  herd-quick.sh  new-feature.sh  spawn.sh  spawn-step.sh
  scribe.sh  scribe-step.sh  research.sh  research-step.sh  research-get.sh
  healthcheck.sh  app-monitor.sh  backlog-view.sh  dep-watcher.sh  fleet.sh  cost.sh
  herd-resolve.sh  herd-review.sh  herd-claim.sh  agent-watch.sh  herd-watch.sh
  codemap.sh  symbol-index.sh  theme.sh  layout-reconcile.sh  task-spec-view.sh
  agents.sh                     the specialist agent roster (definitions, install, empirical verify)
  intent-queue.sh               the durable spawn queue's intents + published-plan generations
  work-unit.sh  work-units/{git-pr}.sh   the work-unit facade + the git-pr reference adapter
  backends/{file,github,linear,jira,changelog}.sh   the work-tracker adapters
  sim/                          the zero-quota deterministic sandbox sim rig (fidelity ladder)
scripts/ci/run-suite.sh         the CI runner: diff-scope the curated suite, then shard it
pysrc/herd/                     the python engine core (live_runtime.py; work_unit.py — GitPrAdapter
                                + DocApplyAdapter; ci_verdict.py — the one CI→health verdict mapping)
templates/                      coordinator.md.tmpl, config.example, capabilities.tsv, conformance.tsv,
                                agent-definition.md.tmpl, drivers/, postures.tsv, themes/
docs/                           codemap.md + symbol-index.md (committed engine maps) + reference docs
                                (isolation-boundary.md — what the engine will and will not touch;
                                multi-operator-ownership.md — whose work a seat may act on)
tests/                          hermetic shell + python tests and a bats wrapper
.herd/                          herdkit's OWN dogfood config + healthcheck + review checklist
  agents/                       its committed specialist agent definitions
```

## Tests

```sh
bash tests/test-herd-config.sh        # config loader: defaults + override + derived branch split
bash tests/test-research-step.sh      # research queue: enqueue → claim → report → get → finish
bash tests/test-backend-changelog.sh  # changelog backend 3-op contract
bash tests/test-cli.sh                # herd init / render (idempotent) / upgrade
bash tests/test-sandbox-sim.sh        # the sandbox sim rig: fixture determinism + end-to-end stub gate
bash tests/test-work-unit-kind.sh     # WORK_UNIT_KIND resolution: default + hard refusal on unknown kinds
bash tests/test-doc-drift.sh          # README/docs/templates ↔ capabilities.tsv: no phantom commands or keys
bash tests/test-agent-roster.sh       # the roster: byte-identical spawn when HERD_AGENT is unset, two-sided verify
bash tests/test-autofix-scope.sh      # AUTOFIX_SCOPE: own withholds a foreign-author write, fail-closed on no identity
bash tests/test-suite-shard.sh        # diff-scoped CI: the union of shards reconstructs the scoped set exactly
bats  tests/herd.bats                 # the above + bash -n + a no-leak grep (if bats is installed)
```

The dogfood healthcheck (`.herd/healthcheck.project.sh`) runs `bash -n` over every script,
`shellcheck` if installed, and the hermetic suite — it remains herdkit's own local dev tool and
the default merge gate every consumer project runs. As of 2026-08-06 (HERD-579), herdkit itself no
longer uses it as ITS merge gate (`HEALTHCHECK_CMD=true` in `.herd/config`, with a policy comment
and one-line revert): the full suite's unscopeable-diff / shared-box cost profile is uniquely bad
for herdkit's own engine PRs, so merge safety there rests on adversarial review + GitHub CI + the
main-health auto-repair loop instead. That is the same trade `HEALTH_SOURCE=ci` generalizes for any
project whose CI already runs the suite.

## License

MIT © 2026 Brian Keegan. See [LICENSE](LICENSE).
