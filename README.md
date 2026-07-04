# herdkit

**A reusable, config-driven multi-agent "herd" workflow for [Claude Code](https://claude.com/claude-code), built on the [herdr](https://github.com/) terminal multiplexer.**

herdkit is the orchestration layer — a long-lived **coordinator** that owns a backlog and
delegates each piece of work to an isolated git-worktree **sub-agent**, with async **scribe** and
**research** lanes, a test-gated **conflict resolver**, an adversarial **pre-merge review gate**,
and a safety-railed **auto-merge watcher**. It was extracted from the Northstar project so the
pattern — not one project's wiring — can be reused, fixed once, and adopted everywhere.

> **herdr vs herdkit.** `herdr` is the terminal/agent **multiplexer** (workspaces, tabs, panes,
> `herdr agent start`, notifications) — a hard dependency and the runtime substrate. **herdkit**
> is the **workflow built on top of it**. Every lane script shells out to `herdr …`; herdkit does
> not reimplement it.

---

## What you get — the lanes

| lane | script | what it does |
|---|---|---|
| **coordinator** | `coordinator.sh` | (re)launches the 2-pane control room: `[ live backlog │ /coordinator agent ]` with the watch console pinned below. The coordinator owns the backlog and delegates; it never edits code in the main checkout. |
| **feature** | `herd-feature.sh` | full lane: a worktree off the latest default branch + `[ app preview │ sub-agent ]`. The agent builds the feature and opens a PR. |
| **quick** | `herd-quick.sh` | lightweight sibling for trivial / non-app changes: a worktree + a single agent pane, no preview. Same isolation + PR flow, less ceremony. |
| **scribe** | `scribe.sh` / `scribe-step.sh` | async, serialized backlog writer. The coordinator *enqueues* changes; one drainer applies them to `BACKLOG_FILE` and commits — so writes never clobber and the coordinator window stays free. |
| **research** | `research.sh` / `research-step.sh` / `research-get.sh` | read-only repo research queue. Fan-out Explore subagents, one report file per question; never mutates the repo. |
| **resolver** | `herd-resolve.sh` | isolated, test-gated conflict resolver for a CONFLICTING PR. Merges the default branch in, fixes **mechanical** conflicts, verifies, pushes — or aborts and **`ESCALATE:`**s a semantically-ambiguous one. Never blind-merges. |
| **review** | `herd-review.sh` | adversarial pre-merge correctness gate (a strong model, default-to-BLOCK). Reads the PR diff against the project's `REVIEW_CHECKLIST` and prints one machine-parseable verdict: `REVIEW: PASS` / `REVIEW: BLOCK — …`. |
| **watcher** | `agent-watch.sh` / `herd-watch.sh` | the live status console + auto-merge state machine. Merges only a PR that is MERGEABLE+CLEAN, healthcheck-green, **and** review-PASSed — re-verifying in the instant before merge. Owns teardown after a merge. Also surfaces **dead builders** (a worktree whose agent vanished with no PR) and auto-resumes builders paused on the account usage limit. Safety-railed and idempotent. |

Two threads run through the whole pipeline: an append-only **engine journal**
(`.herd/journal.jsonl`) records every gate event as a forensic trail — read it back with `herd why`
and `herd log` — and the watcher's review gate can **auto-bounce a BLOCK back to the builder** to fix
and push (the refix loop), so a failed review re-tasks itself instead of stalling.

The engine is **generic**; everything project-specific is read from a per-project `.herd/config`.

> **Looking for the full command + config reference?** See
> [`docs/capabilities-overview.md`](docs/capabilities-overview.md) — a concise map of every `herd`
> subcommand and the key `.herd/config` levers, cross-referencing `templates/capabilities.tsv` as
> the machine-readable source of truth.

---

## Install

**Requirements:** `herdr` (the terminal multiplexer), `claude` (Claude Code CLI), `gh`, `git`,
`python3`, and a modern `bash`. No specific OS or package manager is assumed — these tools work
on macOS and Linux alike.

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

# Inspect / change a workflow preference post-init (validated against capabilities.tsv):
herd config list             # print effective keys + values (secrets masked)
herd config get <KEY>        # print one validated key's value
herd config set <KEY> <VAL>  # edit in place, then restart the watcher / re-render the skill
herd config lint             # flag DUPLICATE keys (shell last-wins can silently disable a gate)

# Forensics — read the append-only engine journal (.herd/journal.jsonl):
herd log [--pr N] [--tail]   # page the journal: one line per gate event; --tail follows live
herd why <pr#>               # summarize one PR's full gate history — the first post-mortem tool
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
  `ready · awaiting approval` and notifying you. It merges only once a coordinator signs off:

  ```sh
  bash scripts/herd/herd-approve.sh list          # gate-passed PRs awaiting approval (+ verdicts)
  bash scripts/herd/herd-approve.sh approve <pr#>  # sha-keyed approval → watcher merges next poll
  ```

  Approval is **sha-keyed**: a commit pushed after the approval was written invalidates it — the
  gate cycle re-runs and a fresh approval is required.
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
the merge waits for a human to run the steps and

```sh
bash scripts/herd/herd-approve.sh approve <pr#>
```

Sibling PRs without the marker keep auto-merging. The console shows
`ready · human-verify pending · herd-approve.sh approve <pr#>`, and `herd-approve.sh list` prints the
declared steps — so a manual step is never silently skipped. (Under `approve`/`observe` the hold is
redundant, since those policies already gate every PR.)

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
and it fails closed (an unresolvable owner withholds auto-merge). Pairs with the `WATCHER_VIEW` lens
(`all` / `mine` / `review-queue` / `deps`), which narrows *which* PRs the console even displays.

---

## Manage several projects — `herd fleet`

`herd fleet` is a **deterministic, no-LLM** fan-out over a flat project registry (default
`~/.herd/fleet`), for running one herd install across many repos at once:

```sh
herd fleet register <path>       # add a herd project to the registry
herd fleet status                # per-project rollup: branch, open PRs, watcher alive?, last activity
herd fleet inbox                 # attention inbox: blocked PRs, holds, conflicts, failed gates — per repo
herd fleet digest [--since 24h]  # cross-project standup built from each project's journal
herd fleet governance            # global concurrency: total in-flight builders + reviews (limit is account-wide)
herd fleet set MERGE_POLICY auto # propagate one policy across the fleet (validated per project)
herd fleet upgrade | reload      # run 'herd update' / 'herd reload' in every registered project
```

It never mutates a project's tree beyond what the delegated per-project command already does; a
missing / dirty / `gh`-unavailable project is reported, not fatal.

> **Experimental / in progress — coordinator auto-resume + watchdog.** The watcher already
> auto-resumes *builders* paused on the account usage limit, but the **coordinator** itself has no
> watchdog: if it hits the limit unattended it parks at Claude's interactive menu with nothing to
> revive it. A watchdog to close that seam is **in progress**, intended to land dormant behind a
> **default-off, opt-in `COORDINATOR_WATCHDOG` flag**. It is **not yet wired in the current
> engine** — roadmap, not a lever you can set today (tracked in `BACKLOG.md`).

---

## Fork vs config — how to customize

herdkit is **one engine, many consumers**. You almost never fork it:

- **Consuming projects customize via `.herd/config` + project override hooks in their own repo** —
  paths, branch, the workflow's own display brand (`WORKSPACE_NAME`, which surfaces in `herd doctor`
  and the coordinator skill instead of the literal "herdkit"), model map, the health command
  (`HEALTHCHECK_CMD`), the resolver smoke gate (`SMOKE_CMD`), the review risk list
  (`REVIEW_CHECKLIST`), privacy paths (`DENY_PATHS`), the work-tracker backend (`SCRIBE_BACKEND`),
  the engine-bug escalation target (`HERD_REPO` — where `herd report` files; not the herdkit
  author's repo unless you leave it unset), and the auto-merge lever. The generated skill renders
  these in. **Not a fork.** Engine improvements arrive via `herd upgrade`.
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

## Drain the work source — `herd backlog`

`herd backlog` prints the project's **OPEN work items** through the active `SCRIBE_BACKEND`,
so the same command answers "what's my open work?" regardless of where the tracker lives:

- **`file`** (default) — greps `BACKLOG_FILE` for queued (🔜) / in-progress (🚧) items.
- **`github`** — runs `gh issue list --state open`.
- **`linear`** — queries Linear for issues whose state isn't completed/canceled.

Every backend emits the same one-line `#<id> <title>` shape, so a non-file project surfaces
its issue tracker as actionable work rather than a tracked file:

```sh
$ herd backlog
#8 [herdkit] README: add a usage example for 'herd backlog'. Lane: docs.
#5 watcher: re-verify MERGEABLE in the instant before merge. Lane: app.
```

This is how a coordinator **drains its tracker as the work source**: it lists open items via
the backend, picks one, and delegates it to a lane. Combined with `herd report` (which files an
engine bug as an issue on `HERD_REPO`), it closes the cross-repo dispatch loop — a consumer
reports out, the herdkit coordinator drains those issues with `herd backlog`, and ships the fix.

## Work-tracker backends

The scribe's write path is pluggable via `SCRIBE_BACKEND`. Every backend implements three ops
(`scripts/herd/backends/<name>.sh`):

```sh
_backend_add_item    REQ_ID TEXT     # create a new item
_backend_mark_shipped SLUG  PR_URL   # reap/stamp a shipped item
_backend_list_open                   # print open items
```

**v1 ships file backends only:** `file` (default; edits `BACKLOG_FILE`, zero-secret) and
`changelog` (append-only under `## [Unreleased]`). Linear / Jira / Azure DevOps are Phase 3
targets — a backend that implements those three functions is a complete, first-class integration.
API backends read credentials from `.herd/secrets` (gitignored); the file backends never touch it.

---

## Layout

```
bin/herd                       the CLI (init / doctor / upgrade / config / fleet / report / …)
scripts/herd/                   the generic engine (sources .herd/config via herd-config.sh)
  coordinator.sh  herd-feature.sh  herd-quick.sh  new-feature.sh
  scribe.sh  scribe-step.sh  research.sh  research-step.sh  research-get.sh
  healthcheck.sh  app-monitor.sh  backlog-view.sh  dep-watcher.sh  fleet.sh
  herd-resolve.sh  herd-review.sh  agent-watch.sh  herd-watch.sh
  backends/{file,changelog}.sh  the work-tracker adapters
templates/                      coordinator.md.tmpl, config.example, capabilities.tsv, healthcheck examples
docs/                           reference + research docs (capabilities-overview.md, …)
tests/                          hermetic shell tests + a bats wrapper
.herd/                          herdkit's OWN dogfood config + healthcheck + review checklist
```

## Tests

```sh
bash tests/test-herd-config.sh        # config loader: defaults + override + derived branch split
bash tests/test-research-step.sh      # research queue: enqueue → claim → report → get → finish
bash tests/test-backend-changelog.sh  # changelog backend 3-op contract
bash tests/test-cli.sh                # herd init / render (idempotent) / upgrade
bats  tests/herd.bats                 # the above + bash -n + a no-leak grep (if bats is installed)
```

The dogfood healthcheck (`.herd/healthcheck.project.sh`) runs `bash -n` over every script,
`shellcheck` if installed, and the hermetic suite — so herdkit gates its own PRs the same way it
gates a consumer's.

## License

MIT © 2026 Brian Keegan. See [LICENSE](LICENSE).
