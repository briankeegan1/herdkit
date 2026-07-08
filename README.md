# herdkit

**A reusable, config-driven multi-agent "herd" workflow for [Claude Code](https://claude.com/claude-code), built on the [herdr](https://github.com/) terminal multiplexer.**

herdkit is the orchestration layer — a long-lived **coordinator** that owns a backlog and
delegates each piece of work to an isolated git-worktree **sub-agent**, with async **scribe** and
**research** lanes, a test-gated **conflict resolver**, an adversarial **pre-merge review gate**,
and a safety-railed **auto-merge watcher**. It was extracted from a real project so the pattern —
not one project's wiring — can be reused, fixed once, and adopted everywhere.

> **herdr vs herdkit.** `herdr` is the terminal/agent **multiplexer** (workspaces, tabs, panes,
> `herdr agent start`, notifications) — a hard dependency and the runtime substrate. **herdkit**
> is the **workflow built on top of it**. Every lane script shells out to `herdr …`; herdkit does
> not reimplement it. (A `headless` driver runs the same engine with no panes — see
> [Where it's going](#where-its-going).)

---

## The goal

A **durable, self-governing, config-driven agent workflow that drains a backlog to merged, verified
PRs — unattended, on your own machine, surviving interruptions.** You point it at a repo and a work
source; it picks items, builds each in isolation, gates every merge on a healthcheck plus an
adversarial review, and lands the green ones. It keeps running when a builder hits the account usage
limit, when the coordinator's window is closed, or when the process is killed mid-drain: state lives
on disk, so the pipeline resumes from where it stopped instead of starting over. The engine is
generic; everything project-specific is read from a per-project `.herd/config`.

---

## What it does today

### The lanes

| lane | script | what it does |
|---|---|---|
| **coordinator** | `coordinator.sh` | (re)launches the 2-pane control room: `[ live backlog │ /coordinator agent ]` with the watch console pinned below. The coordinator owns the backlog and delegates; it never edits code in the main checkout. |
| **feature** | `herd-feature.sh` | full lane: a worktree off the latest default branch + `[ app preview │ sub-agent ]`. The agent builds the feature and opens a PR. |
| **quick** | `herd-quick.sh` | lightweight sibling for trivial / non-app changes: a worktree + a single agent pane, no preview. Same isolation + PR flow, less ceremony. |
| **scribe** | `scribe.sh` / `scribe-step.sh` | async, serialized backlog writer. The coordinator *enqueues* changes; one drainer applies them to `BACKLOG_FILE` and commits — so writes never clobber and the coordinator window stays free. |
| **research** | `research.sh` / `research-step.sh` / `research-get.sh` | read-only repo research queue. Fan-out Explore subagents, one report file per question; never mutates the repo. |
| **resolver** | `herd-resolve.sh` | isolated, test-gated conflict resolver for a CONFLICTING PR. Merges the default branch in, fixes **mechanical** conflicts, verifies, pushes — or aborts and **`ESCALATE:`**s a semantically-ambiguous one. Never blind-merges. |
| **review** | `herd-review.sh` | adversarial pre-merge correctness gate (a strong model, default-to-BLOCK). Reads the PR diff against the project's `REVIEW_CHECKLIST` and prints one machine-parseable verdict: `REVIEW: PASS` / `REVIEW: BLOCK — …`. |
| **watcher** | `agent-watch.sh` / `herd-watch.sh` | the live status console + auto-merge state machine. Merges only a PR that is MERGEABLE+CLEAN, healthcheck-green, **and** review-PASSed — re-verifying in the instant before merge. Owns teardown after a merge. Also surfaces **dead builders** (a worktree whose agent vanished with no PR) and **auto-resumes builders paused on the account usage limit**. Safety-railed and idempotent. |

The engine is **generic**; everything project-specific is read from a per-project `.herd/config`.
Two threads run through the whole pipeline: an append-only **engine journal**
(`.herd/journal.jsonl`) records every gate event as a forensic trail, and the watcher's review gate
can **auto-bounce a BLOCK back to the builder** to fix and push (the refix loop), so a failed review
re-tasks itself instead of stalling.

### Grounding & efficiency

Builders don't re-explore the tree every session, and the review gate doesn't spend a strong model on
a docs typo:

- **Committed, deterministic engine maps.** `herd codemap` writes `docs/codemap.md` (file-level:
  module roles, who-sources-whom, and config-key→consumer wiring) and `herd symbol-index` writes
  `docs/symbol-index.md` (function-level def→caller index). Both are **bash-native, LLM-free, and
  idempotent** (rewrite only on real change), so they cost zero model quota and stay diff-reviewable.
  `CODEMAP_AUTOREFRESH` (default on) has the watcher regenerate and commit them straight to the
  default branch after each merge, fail-soft. *Honest scope: the symbol index is a heuristic token
  scan, not a parser — its limits are spelled out in the artifact header.*
- **Builder grounding via `CONTEXT_PROVISION`.** Set `CONTEXT_PROVISION=codemap` and every spawned
  builder's task spec carries a pointer, in its prompt-cache-shared **stable** prefix, telling it to
  read `docs/codemap.md` first — so it starts oriented instead of grepping. Unset (default) leaves
  task specs byte-identical to before; unknown sources are ignored (forward-compatible).
- **Pre-spawn conflict analysis via graphify.** The coordinator can run `graphify update --no-cluster`
  (also LLM-free, zero quota; resolved from `GRAPHIFY_BIN` or `graphify` on PATH, else skipped
  silently) to cross each in-flight worktree's changed files against the others and the candidate
  item's likely file surface — sequencing or warning on overlap **before** it spawns. *Honest scope:
  file-level overlap only; bash cross-file call resolution is weak, so this is not a call graph.*
- **Risk-tiered review — `REVIEW_ESCALATE_GLOB`.** Off by default (every PR gets the full strong
  review). When set, engine-critical paths or a large diff get the strong reviewer; a docs/test-only
  diff is **skipped** with a `source=skipped-low-risk` PASS; any other small low-risk diff uses the
  cheaper `REVIEW_MODEL_CHEAP` tier. Classification fails safe (an unreadable diff → strong). A
  sibling `MODEL_ESCALATE_GLOB` steps the *builder* model up for judgment-heavy tasks the same way.
- **Healthcheck profiles — `HEALTHCHECK_HEAVY_GLOB`.** Match the diff paths that warrant the full
  suite (e.g. `^app/`); everything else runs the light `bash -n` profile. Blank means every change is
  heavy (today's behavior).
- **Cost measurement — `herd cost`.** Reads the journal's token/$ events (measured per builder and
  per in-worktree review at merge time, deduped by message id, priced against a dated model table)
  and reports per-PR and **cost-per-merged-PR**. Read-only — it measures spend, it never changes a
  gate.

### Durability & forensics

- **Limit-park auto-resume — a first-class durability feature.** When a builder's turn ends on the
  account usage limit, a `rate_limit` Claude Code hook writes a per-worktree `.herd-limit-sentinel`
  with the reset time. The watcher polls it as the primary, version-robust signal (a banner-scrape
  fallback covers environments without the hook), shows a **non-red** `limit-hit · auto-resume at
  HH:MM` row, and at the reset relaunches the builder in place via `claude --continue`
  (`HERD_LIMIT_RESUME_BUFFER` waits past the exact reset instant; `HERD_LIMIT_DETECT=off` is the
  kill-switch). A usage limit is an expected account event, not a failure — so the pipeline waits it
  out and continues.
- **Engine journal forensics — `herd why` / `herd log`.** The append-only `.herd/journal.jsonl`
  records every gate event (review dispatch, verdict + provenance, healthcheck attempt/outcome, refix
  bounce, merge, reap, limit park/resume). `herd log [--pr N] [--tail]` pages or follows the raw
  stream; `herd why <pr#>` reconstructs one PR's full gate history chronologically — the first
  post-mortem tool for "what happened to this PR." `herd status` prints a one-shot, read-only,
  no-LLM health snapshot for the project (watcher alive? dead builders? conflicting / blocked PRs?).

### Multi-operator

A solo install needs none of this, but a shared repo does — so every one of these is **opt-in** and
byte-inert until set:

- **`TRACKED_SPAWNS=required`** makes "every builder maps to a tracked work item" a project policy:
  a spawn carrying no tracker ref is refused, creating nothing (`HERD_FORCE_SPAWN=1` is the explicit,
  journaled escape hatch).
- **`CLAIM_REQUIRED=on`** adds an atomic pre-spawn claim: before creating a worktree the lane reads
  the item's state through the active backend, flips it to In Progress + assigned to the operator,
  and re-reads to verify — a spawn on an item **already claimed by someone else aborts loudly**. It
  fails soft when the backend is unreachable, so a solo operator is never hard-blocked. With both
  keys on, every spawn is claimed (exclusivity) and visible in the tracker (traceability).
- **`herd config set --shared <KEY> <VAL>`** applies a project-scoped policy change to the committed
  baseline **and opens a tiny single-file PR** (branch `config/<key>`) — so an operator who can't
  push to the default branch still propagates policy the gated way; others receive it via `git pull`
  + `herd update`. (Per-user / per-machine choices route to the gitignored `.herd/config.local`
  instead.)
- **`WATCHER_SCOPE=all`** turns on team mode: teammates' PRs are *displayed* but auto-merge is
  strictly scoped to `WATCHER_OWNER`'s own PRs (a narrowing gate — it can only withhold a merge,
  never authorize one; fail-closed).

### The sandbox sim rig

`scripts/herd/sim/` is a **zero-quota, deterministic** test rig for the workflow itself — it drives
the real gate/merge/concurrency/limit-park/pane machinery with **stub builders (no model call)**, so
the behaviors that are otherwise expensive and non-deterministic to exercise get a hermetic proof.
It's a **fidelity ladder**:

| tier | scenario | drives | proves |
|---|---|---|---|
| **P0** | `sandbox-scenario.sh` · `benchmark-drain.sh` | a one-PR gate; the full flow per item | happy path + gate-fault isolation; an unattended N-item drain that **survives a hard `SIGKILL`** and resumes from disk with **0 duplicates** |
| **P1** | `sandbox-concurrency-scenario.sh` | the **real** watcher gate loop, N≥3 PRs | `REVIEW_CONCURRENCY` / `HEALTH_CONCURRENCY=1` respected, no double-merge, queue drains |
| **P2a** | `sandbox-limit-resume-scenario.sh` | the **real** watcher limit path | limit-park **detect → park → schedule → resume → complete**, plus the kill-switch |
| **P2b** | `sandbox-real-panes-scenario.sh` | a **real, disposable** herdr control room | pane/tab existence + labels, agent `idle→working→done`, **clean teardown (0 leaks)** |

P0–P2a are fully hermetic (local git only, no hosted repo, no panes); P2b stands up a real but
disposable herdr workspace and **degrades to a clean skip** where herdr is unavailable. Details in
[`scripts/herd/sim/README-sandbox-sim.md`](scripts/herd/sim/README-sandbox-sim.md).

> **Looking for the full command + config reference?** See
> [`docs/capabilities-overview.md`](docs/capabilities-overview.md) — a concise map of every `herd`
> subcommand and the key `.herd/config` levers, cross-referencing `templates/capabilities.tsv` as
> the machine-readable source of truth.

---

## Install

**Requirements:** `herdr` (the terminal multiplexer), `claude` (Claude Code CLI), `gh`, `git`,
`python3`, and a modern `bash`. No specific OS or package manager is assumed — these tools work
on macOS and Linux alike.

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
`TODO.md` / `CHANGELOG` / GitHub Issues; asks whether you use Linear/Jira/DevOps — those are
*coming soon*, v1 ships file backends), then writes:

- **`.herd/config`** — your project's answers (paths, default branch, model map, health/preview
  commands, privacy paths, routing). Committed; **zero-secret**.
- **`.claude/commands/coordinator.md`** — the coordinator skill, *rendered* from
  `templates/coordinator.md.tmpl` with your config baked in (no conditionals — it reads as if
  hand-written for your project). Regenerate it any time with `herd upgrade`.

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

# Grounding maps — deterministic, LLM-free, committed:
herd codemap                 # regenerate docs/codemap.md (file-level engine map); --check for staleness
herd symbol-index            # regenerate docs/symbol-index.md (function def→caller index)

# Inspect / change a workflow preference post-init (validated against capabilities.tsv):
herd config list             # print effective keys + values (source: baseline | local; secrets masked)
herd config get <KEY>        # print one validated key's value
herd config set <KEY> <VAL>  # edit in place, then restart the watcher / re-render the skill
herd config set --shared <KEY> <VAL>   # project-scoped change via a tiny config/<key> PR (multi-operator)
herd config lint             # flag DUPLICATE keys (shell last-wins can silently disable a gate)

# Export / apply a project's GOVERNANCE (merge/gate/PR/attribution/commit policy) as a portable profile:
herd governance export --file gov.profile   # write the governance-scoped keys (secrets/machine keys never travel)
herd governance apply gov.profile           # propose each key via the validated 'herd config set' (--yes for automation)
herd init --governance gov.profile          # seed a fresh install from a profile
herd fleet set --profile gov.profile        # roll a profile out across every registered project

# Forensics — read the append-only engine journal (.herd/journal.jsonl):
herd log [--pr N] [--tail]   # page the journal: one line per gate event; --tail follows live
herd why <pr#>               # summarize one PR's full gate history — the first post-mortem tool
herd status                  # one-shot read-only health snapshot for THIS project (no LLM)
herd cost [--pr N]           # per-builder + review token/$ accounting; cost-per-merged-PR
herd link list               # list peer repos registered in .herd/links

# Manage several herd projects at once — deterministic, no-LLM fan-out (see below):
herd fleet status            # per-project rollup: branch, open PRs, watcher alive?, last activity
herd fleet inbox             # cross-project attention inbox: what needs you right now
herd fleet digest [--since D]  # cross-project standup from each project's journal
herd fleet set <KEY> <VAL>   # propagate one policy across the fleet (validated per project)

# Sign off held PRs (MERGE_POLICY=approve or a HUMAN-VERIFY hold):
bash scripts/herd/herd-approve.sh list           # gate-passed PRs awaiting approval
bash scripts/herd/herd-approve.sh approve <pr#>  # sha-keyed approval → watcher merges
```

---

## Merge control — `MERGE_POLICY` (human-in-the-loop)

The watcher runs the full pipeline — healthcheck, then the adversarial review gate — on every
ready PR. **`MERGE_POLICY`** in `.herd/config` is the primary lever over the *last* step (merge),
a three-way switch:

- **`auto`** — on a review **PASS**, the watcher calls `gh pr merge` itself. Full auto,
  safety-railed: walk away and PRs land.
- **`approve`** — the watcher runs every gate but **holds before merging**, flagging the PR
  `ready · awaiting approval` and notifying you. It merges only once a coordinator signs off with
  `herd-approve.sh approve <pr#>`. Approval is **sha-keyed**: a commit pushed after the approval was
  written invalidates it — the gate cycle re-runs and a fresh approval is required.
- **`observe`** — runs every gate and reports/notifies, but **never merges** under any circumstance.

Either way the watcher never merges a conflict, a BLOCK, an un-reviewed commit, or a PR whose state
changed under it.

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
(`HUMAN_VERIFY_POLICY` can instead flag such a PR coordinator-actionable, or treat the steps as
informational and merge on green gates.)

### Auto-refix a BLOCK review — `REVIEW_AUTOFIX`

When `.herd/config` sets **`REVIEW_AUTOFIX=true`**, a BLOCK verdict is bounced straight back to the
builder: the watcher wakes the builder's idle agent with a re-task prompt to fix and push, then the
gate cycle re-runs on the new commit. This is bounded by **`REFIX_MAX_ROUNDS`** (default 3) bounces
per PR — after which it escalates to `needs you`. When `REVIEW_AUTOFIX=false` (default), a BLOCK just
shows the standard `review blocked` row for the coordinator to re-task by hand.

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
`not mine — manual` and is never auto-merged, even when MERGEABLE+CLEAN+approved. It is a
**narrowing** gate: it can only ever *withhold* a merge, never authorize one the gates would deny,
and it fails closed. Pairs with the `WATCHER_VIEW` lens (`all` / `mine` / `review-queue` / `deps`),
which narrows *which* PRs the console even displays. For multi-operator dispatch discipline, pair it
with `TRACKED_SPAWNS` + `CLAIM_REQUIRED` (see [Multi-operator](#multi-operator)).

---

## Manage several projects — `herd fleet`

`herd fleet` is a **deterministic, no-LLM** fan-out over a flat project registry (default
`~/.herd/fleet`), for running one herd install across many repos at once:

```sh
herd fleet register <path>       # add a herd project to the registry
herd fleet status                # per-project rollup: branch, open PRs, watcher alive?, last activity
herd fleet inbox                 # attention inbox: blocked PRs, holds, conflicts, failed gates — per repo
herd fleet digest [--since 24h]  # cross-project standup built from each project's journal
herd fleet set MERGE_POLICY auto # propagate one policy across the fleet (validated per project)
herd fleet upgrade | reload      # run 'herd update' / 'herd reload' in every registered project
```

It never mutates a project's tree beyond what the delegated per-project command already does; a
missing / dirty / `gh`-unavailable project is reported, not fatal.

---

## Fork vs config — how to customize

herdkit is **one engine, many consumers**. You almost never fork it:

- **Consuming projects customize via `.herd/config` + project override hooks in their own repo** —
  paths, branch, the workflow's own display brand (`WORKSPACE_NAME`), model map, the health command
  (`HEALTHCHECK_CMD`), the resolver smoke gate (`SMOKE_CMD`), the review risk list
  (`REVIEW_CHECKLIST`), privacy paths (`DENY_PATHS`), the work-tracker backend (`SCRIBE_BACKEND`),
  the engine-bug escalation target (`HERD_REPO`), grounding sources (`CONTEXT_PROVISION`,
  `MCP_PROVISION`), the runtime driver (`HERD_DRIVER`), and the merge/review levers above. The
  generated skill renders these in. **Not a fork.** Engine improvements arrive via `herd upgrade`.
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

## Work source & backends — `herd backlog`

`herd backlog` prints the project's **OPEN work items** through the active `SCRIBE_BACKEND`, so the
same command answers "what's my open work?" regardless of where the tracker lives — greping
`BACKLOG_FILE` (**`file`**, default), `gh issue list` (**`github`**), or a Linear query
(**`linear`**). Every backend emits the same one-line `#<id> <title>` shape, so a coordinator
**drains its tracker as the work source**: it lists open items, picks one, and delegates it to a
lane. Combined with `herd report` (which files an engine bug as an issue on `HERD_REPO`), it closes
the cross-repo dispatch loop.

The scribe's write path is pluggable: every backend implements three ops
(`scripts/herd/backends/<name>.sh`) — `_backend_add_item`, `_backend_mark_shipped`,
`_backend_list_open` (plus `_backend_claim_item` for atomic claiming). **v1 ships file backends
only:** `file` (edits `BACKLOG_FILE`, zero-secret) and `changelog` (append-only under
`## [Unreleased]`). Linear / Jira / Azure DevOps are Phase 3 targets — a backend that implements
those functions is a complete, first-class integration. API backends read credentials from
`.herd/secrets` (gitignored); the file backends never touch it. Switch backends with a single
guided command, `herd backend switch <name> [--migrate]`.

---

## Where it's going

The direction is **build-your-own-workflow**: the same engine, configured — not forked — for any
project. The seams already carry this — pluggable **work-tracker backends** (`SCRIBE_BACKEND`), a
runtime **driver** binding (`HERD_DRIVER`, with a `headless` driver that runs the whole pipeline
with no panes for CI / Windows / headless Linux), and pluggable **grounding sources**
(`CONTEXT_PROVISION`, `MCP_PROVISION`) — so the near work is widening each: more trackers, more
drivers, more grounding lanes, each a small, well-scoped adapter behind a documented contract. Beyond
that: **broader artifact surfaces** so the same drain-a-backlog loop lands changes that aren't only
code, and steady work on **adoptability across stacks** (the stack-aware `herd init`, the
dependency doctor, and the hermetic sim rig all serve this). A few durability seams are still open —
tracked in `BACKLOG.md`, shipped dormant behind default-off opt-in flags rather than self-activating.

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
  backends/{file,changelog}.sh  the work-tracker adapters
  sim/                          the zero-quota deterministic sandbox sim rig (fidelity ladder)
templates/                      coordinator.md.tmpl, config.example, capabilities.tsv, drivers/, themes/
docs/                           codemap.md + symbol-index.md (committed engine maps) + reference docs
tests/                          hermetic shell tests + a bats wrapper
.herd/                          herdkit's OWN dogfood config + healthcheck + review checklist
```

## Tests

```sh
bash tests/test-herd-config.sh        # config loader: defaults + override + derived branch split
bash tests/test-research-step.sh      # research queue: enqueue → claim → report → get → finish
bash tests/test-backend-changelog.sh  # changelog backend 3-op contract
bash tests/test-cli.sh                # herd init / render (idempotent) / upgrade
bash tests/test-sandbox-sim.sh        # the sandbox sim rig: fixture determinism + end-to-end stub gate
bats  tests/herd.bats                 # the above + bash -n + a no-leak grep (if bats is installed)
```

The dogfood healthcheck (`.herd/healthcheck.project.sh`) runs `bash -n` over every script,
`shellcheck` if installed, and the hermetic suite — so herdkit gates its own PRs the same way it
gates a consumer's.

## License

MIT © 2026 Brian Keegan. See [LICENSE](LICENSE).
