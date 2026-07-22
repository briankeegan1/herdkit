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
> headless Linux) — see [The driver seam](#the-driver-seam-herdr--claude-today-swappable).

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
closing it. Everything the control room drives is generic engine + lane scripts — see
[`docs/COORDINATOR-SOP.md`](docs/COORDINATOR-SOP.md) for the full attended/unattended operating
playbook, escalation paths, and the state-machine handshake between coordinator, builder, and
watcher.

---

## Work-unit kinds

The vehicle a change ships through is a thin **work-unit interface** (design:
[`docs/spikes/work-unit-abstraction.md`](docs/spikes/work-unit-abstraction.md)) — `open` / `gate` /
`apply` / `reconcile` / `teardown`, selected by `.herd/config`'s `WORK_UNIT_KIND`. Two kinds ship
today:

| kind | default? | vehicle | notes |
|---|---|---|---|
| `git-pr` | **yes**, unqualified default | `gh pr create` → health + review gates → `gh pr merge` — today's exact pipeline | code changes; branch protection and PR review are the durable, auditable delivery vehicle |
| `doc-apply` | opt-in | a `<slug>.unit.json` manifest naming a set of `docs/`-scoped file paths, landed straight onto the default branch with a scoped `git checkout <revision> -- <paths>` + commit + push — **no PR anywhere in the chain** | still runs the same health + review gates against the isolated worktree; the manifest's paths must clear a fail-closed allowlist (`DOC_APPLY_PATH_GLOB`, default `^docs/`) and each must resolve to exactly one real file at that revision — never a directory, never a wildcard, never a silent partial apply |

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

On top of the doctrine, multi-operator features are opt-in and byte-inert until set:

- **`TRACKED_SPAWNS=required`** refuses a spawn carrying no tracker ref.
- **`CLAIM_REQUIRED=on`** adds an atomic pre-spawn claim through the active tracker backend — a
  spawn on an item already claimed by someone else aborts loudly; fails soft when the backend is
  unreachable, so a solo operator is never hard-blocked.
- **`herd config set --shared <KEY> <VAL>`** applies a project-scoped policy change to the
  committed baseline via a tiny single-file PR (`config/<key>`), so an operator who can't push to
  the default branch still propagates policy the gated way.
- **`WATCHER_SCOPE=all`** turns on team mode: teammates' PRs are *displayed* but auto-merge stays
  strictly scoped to `WATCHER_OWNER`'s own — a narrowing gate that can only withhold a merge, never
  authorize one.

---

## The driver seam (herdr + claude today, swappable)

Almost everything the coordinator runs — the `herd` CLI, the lane scripts, `gh` — is runtime
independent. Only two surfaces are runtime-specific, and they are factored into a **driver**
(design: [`docs/driver-abstraction.md`](docs/driver-abstraction.md)):

1. **The multiplexer** — today `herdr` (tabs, panes, agent-status). A `headless` driver ships too:
   panes become an optional cockpit, not a dependency — a detached background process + a
   file-backed agent registry cover the same capabilities with no herdr at all, so the whole
   pipeline runs on Windows / CI / headless Linux.
2. **The agent runtime** — today Claude Code. `templates/drivers/*.driver` files bind each
   capability (spawn, one-shot exec, resume, model-switch, permission flag, limit-detection,
   session identity, cost parsing) to a concrete incantation. Two non-Claude runtime drivers ship
   today, **`codex`** (OpenAI Codex CLI) and **`grok`** (xAI Grok Build CLI) — set `HERD_DRIVER=codex`
   (or `grok`) and the interactive-spawn lanes (`herd-feature.sh` / `herd-quick.sh` /
   `herd-resolve.sh`) compose that driver's real spawn argv instead of `claude`'s. herdr stays the
   multiplexer for all of them; only the agent process changes. Resume, model-switch, and
   limit-detection routing for the non-Claude runtimes are still ahead — a `stub.driver` proves the
   whole seam end-to-end without needing any real third-party CLI.

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
`~/.herd/fleet`) for running one herd install across many repos:

```sh
herd fleet register <path>       # add a project to the registry
herd fleet status                # per-project rollup: branch, open PRs, watcher alive?, last activity
herd fleet inbox                 # cross-project attention inbox: what needs you right now
herd fleet digest [--since 24h]  # cross-project standup built from each project's journal
herd fleet graph [--json]        # relationship graph: registry projects as nodes, .herd/links + .herd/deps as edges
herd fleet set <KEY> <VALUE>     # propagate one policy across the fleet (validated per project)
herd fleet upgrade | reload      # run 'herd update' / 'herd reload' in every registered project
```

It never mutates a project's tree beyond what the delegated per-project command already does; a
missing / dirty / `gh`-unavailable project is reported, not fatal.

---

## The sandbox sim rig

`scripts/herd/sim/` is a **zero-quota, deterministic** test rig for the workflow itself — it drives
the real gate/merge/concurrency/limit-park/pane machinery with **stub builders (no model call)**,
so behaviors that are otherwise expensive and non-deterministic to exercise get a hermetic proof.
It's a fidelity ladder:

| tier | scenario | proves |
|---|---|---|
| P0 | `sandbox-scenario.sh` · `benchmark-drain.sh` | happy path + gate-fault isolation; an unattended N-item drain that survives a hard `SIGKILL` and resumes from disk with **0 duplicates** |
| P1 | `sandbox-concurrency-scenario.sh` | `REVIEW_CONCURRENCY` / `HEALTH_CONCURRENCY=1` respected, no double-merge, queue drains — against the **real** watcher gate loop, N≥3 PRs |
| P2a | `sandbox-limit-resume-scenario.sh` | limit-park **detect → park → schedule → resume → complete**, plus the kill-switch — against the **real** watcher limit path |
| P2b | `sandbox-real-panes-scenario.sh` | pane/tab existence + labels, agent `idle→working→done`, clean teardown (0 leaks) — against a **real, disposable** herdr control room |
| P2c | `sandbox-real-remote-scenario.sh` | a real `gh pr create` / watcher poll / `gh pr merge` against an **opt-in, disposable** GitHub repo, auto-deleted on teardown |
| — | `sandbox-multiseat-scenario.sh` | **two real** watcher gate loops, one shared stub remote: no duplicate gate runs, no duplicate hold comments, no double resolver dispatch, bounded re-stale cycles |
| — | `sandbox-governance-scenario.sh` | the whole governance import → enforcement chain, zero model calls: `CLAUDE.md` → mapped keys → held / refused / reddened at the gate |
| — | `sandbox-self-restart-scenario.sh` | a stale-engine watcher quiesces, drains in-flight work, and re-execs onto new code with nothing dispatched mid-drain and nothing discarded |
| — | `builder-chaos-sim.sh` | recovery hygiene: a builder force-killed at every lifecycle stage leaves no corpse, no stacked respawn, no lost work, and an honest tracker claim |

P0–P2a are fully hermetic (local git only, no hosted repo, no panes); P2b stands up a real but
disposable herdr workspace and P2c a real but disposable GitHub repo, both degrading to a clean skip
where the dependency is unavailable. Details in
[`scripts/herd/sim/README-sandbox-sim.md`](scripts/herd/sim/README-sandbox-sim.md).

> **Looking for the full command + config reference?** See
> [`docs/capabilities-overview.md`](docs/capabilities-overview.md) — a concise map of every `herd`
> subcommand and the key `.herd/config` levers, cross-referencing `templates/capabilities.tsv` as
> the machine-readable source of truth.

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
```

**Option 1 — zero-assumption: add `bin/` to PATH** (no symlink, no write permissions needed):

```sh
# bash / zsh
echo 'export PATH="$HOME/source/herdkit/bin:$PATH"' >> ~/.bashrc   # or ~/.zshrc
source ~/.bashrc
```

**Option 2 — symlink to any writable directory already on PATH:**

```sh
# Works with /usr/local/bin, /opt/homebrew/bin, ~/.local/bin, or any other directory on your PATH.
ln -s ~/source/herdkit/bin/herd ~/.local/bin/herd
```

**Option 3 — auto-detect install location** (picks the first writable PATH directory for you):

```sh
bash ~/source/herdkit/install.sh
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
Python-shaped defaults. It runs the **work-tracker discovery dialogue** (detects `BACKLOG.md` /
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

Other commands:

```sh
herd upgrade                 # bump the engine pin + re-render the skill, keeping your answers
herd update [--force]        # pull the engine (ff-only), re-render the skill, reload — one step
herd reload                  # rebuild the control room (watcher + backlog pane + re-render)
herd pane <watch|backlog|coordinator>   # restart ONE control-room pane in place, no full reload
herd doctor                  # one-pass dependency doctor (git, gh, claude, python3, herdr …)
herd backlog                 # list open work items via the active backend (see below)
herd report "<symptom + lane>"   # file an engine bug as a gh issue on HERD_REPO (see below)
herd sweep [--dry-run]       # reap stale worktrees, tabs, dead-pid markers, orphaned processes

# Grounding maps — deterministic, LLM-free, committed:
herd codemap                 # regenerate docs/codemap.md (file-level engine map); --check for staleness
herd symbol-index            # regenerate docs/symbol-index.md (function def→caller index)
herd map                     # render docs/control-room-map.md (the one-page pipeline flow diagram)

# Inspect / change a workflow preference post-init (validated against capabilities.tsv):
herd config list             # print effective keys + values (source: baseline | local; secrets masked)
herd config get <KEY>        # print one validated key's value
herd config set <KEY> <VAL>  # edit in place, then restart the watcher / re-render the skill
herd config set --shared <KEY> <VAL>   # project-scoped change via a tiny config/<key> PR (multi-operator)

# Export / apply a project's GOVERNANCE (merge/gate/PR/attribution/commit policy) as a portable profile:
herd governance export --file gov.profile   # write the governance-scoped keys (secrets/machine keys never travel)
herd governance apply gov.profile           # propose each key via the validated 'herd config set' (--yes for automation)
herd init --governance gov.profile          # seed a fresh install from a profile
herd fleet set --profile gov.profile        # roll a profile out across every registered project

# Forensics — read the append-only engine journal (.herd/journal.jsonl):
herd log [--pr N] [--tail]   # page the journal: one line per gate event; --tail follows live
herd why <pr#>               # summarize one unit's full gate history — the first post-mortem tool
herd status                  # one-shot read-only health snapshot for THIS project (no LLM)
herd cost [--pr N]           # per-builder + review token/$ accounting; cost-per-merged unit
herd stats [--today|--since <date>|--pr N]   # zero-LLM digest of the journal window
herd conformance <report|run>   # capability ↔ proof-test coverage matrix
herd changelog generate      # journal-driven CHANGELOG.md [Unreleased] (deterministic, no LLM)
herd changelog tag <ver>     # promote [Unreleased] + local git tag (see docs/releasing.md)
herd link list               # list peer repos registered in .herd/links
herd link --scan [--write]   # propose peer links from the fleet registry; --write applies

# Manage several herd projects at once — deterministic, no-LLM fan-out (see below):
herd fleet status            # per-project rollup: branch, open PRs, watcher alive?, last activity
herd fleet inbox             # cross-project attention inbox: what needs you right now
herd fleet digest [--since D]  # cross-project standup from each project's journal
herd fleet set <KEY> <VAL>   # propagate one policy across the fleet (validated per project)

# Sign off held PRs (MERGE_POLICY=approve or a HUMAN-VERIFY hold):
herd approve list            # gate-passed PRs awaiting approval
herd approve <pr#>           # sha-keyed approval → watcher merges
herd approve why <pr#>       # the review verdict + block reason for one PR
# (`herd approve` is an alias for `bash scripts/herd/herd-approve.sh`, which also still works)
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

### Auto-refix a BLOCK review — `REVIEW_AUTOFIX`

When `.herd/config` sets **`REVIEW_AUTOFIX=true`**, a BLOCK verdict is bounced straight back to the
builder: the watcher wakes the builder's idle agent with a re-task prompt to fix and push, then the
gate cycle re-runs on the new commit. This is bounded by **`REFIX_MAX_ROUNDS`** (default 3) bounces
per PR — after which it escalates to `needs you`. When `REVIEW_AUTOFIX=false` (default), a BLOCK just
shows the standard `review blocked` row for the coordinator to re-task by hand.

### Auto-heal a stale base — `STALE_BASE_AUTOFIX`

The pre-merge stale-duplicate gate holds two flavors: **duplicate** (re-implements shipped work —
always a human judgment call) and **stale-base** (touched files moved on `DEFAULT_BRANCH` — purely
mechanical). When `.herd/config` sets **`STALE_BASE_AUTOFIX=on`**, a stale-base hold self-heals on
the same rails as review autofix: sha-keyed once-guard, shared `REFIX_MAX_ROUNDS` budget, honest
console row `rebasing · awaiting push`. Default is **`off`** (ship-dormant) so the hold path stays
byte-identical until a project opts in.

### Auto-refix a red healthcheck — `HEALTHCHECK_AUTOFIX`

A reproduced pre-merge healthcheck **code error** is the same shape of finding as a BLOCK review — a
machine-checkable defect in the builder's own diff — so **`HEALTHCHECK_AUTOFIX=true`** bounces it back
the same way, handing the builder the failing test line and the path to the tailable suite log. The
round budget is **shared with the review refix**: `REFIX_MAX_ROUNDS` counts both kinds together, one
budget per PR. Default `false`.

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

A solo install auto-merges the operator's own PRs, exactly as before (`WATCHER_SCOPE=mine`, the
default). On a **shared** repo, set **`WATCHER_SCOPE=all`**: teammates' PRs are *displayed* but
auto-merge is strictly scoped to PRs owned by **`WATCHER_OWNER`** — a teammate's PR shows
`not mine — manual` and is never auto-merged, even when MERGEABLE+CLEAN+approved. Pairs with the
`WATCHER_VIEW` lens (`all` / `mine` / `review-queue` / `deps`), which narrows *which* PRs the
console even displays. For multi-operator dispatch discipline, pair it with `TRACKED_SPAWNS` +
`CLAIM_REQUIRED` (see [Multi-seat operation](#multi-seat-operation)).

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
pluggable **work-tracker backends** (`SCRIBE_BACKEND`), a runtime **driver** binding
(`HERD_DRIVER`, with `headless`/`codex`/`grok` already shipped alongside the default), and
pluggable **grounding sources** (`CONTEXT_PROVISION`, `MCP_PROVISION`) — so the near work is
widening each: a `config-apply` work-unit kind for committed, non-secret config surfaces; routing
resume / model-switch / limit-detection through the non-Claude runtime drivers (today only
interactive-spawn is routed); more trackers; more grounding lanes — each a small, well-scoped
adapter behind a documented contract. A few durability seams are still open — tracked in
`BACKLOG.md`, shipped dormant behind default-off opt-in flags rather than self-activating.

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
  generated files to before the lever existed.
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
  work-unit.sh  work-units/{git-pr}.sh   the work-unit facade + the git-pr reference adapter
  backends/{file,github,linear,jira,changelog}.sh   the work-tracker adapters
  sim/                          the zero-quota deterministic sandbox sim rig (fidelity ladder)
pysrc/herd/                     the python engine core (live_runtime.py, work_unit.py — GitPrAdapter + DocApplyAdapter)
templates/                      coordinator.md.tmpl, config.example, capabilities.tsv, drivers/, themes/
docs/                           codemap.md + symbol-index.md (committed engine maps) + reference docs
tests/                          hermetic shell + python tests and a bats wrapper
.herd/                          herdkit's OWN dogfood config + healthcheck + review checklist
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
bats  tests/herd.bats                 # the above + bash -n + a no-leak grep (if bats is installed)
```

The dogfood healthcheck (`.herd/healthcheck.project.sh`) runs `bash -n` over every script,
`shellcheck` if installed, and the hermetic suite — so herdkit gates its own PRs the same way it
gates a consumer's.

## License

MIT © 2026 Brian Keegan. See [LICENSE](LICENSE).
