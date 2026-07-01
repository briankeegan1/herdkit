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
| **watcher** | `agent-watch.sh` / `herd-watch.sh` | the live status console + auto-merge state machine. Merges only a PR that is MERGEABLE+CLEAN, healthcheck-green, **and** review-PASSed — re-verifying in the instant before merge. Owns teardown after a merge. Safety-railed and idempotent. |

The engine is **generic**; everything project-specific is read from a per-project `.herd/config`.

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

`herd init` **scouts** the repo (language/build, CI, branch protection, existing trackers), runs
the **work-tracker discovery dialogue** (detects `BACKLOG.md` / `TODO.md` / `CHANGELOG` / GitHub
Issues; asks whether you use Linear/Jira/DevOps — those are *coming soon*, v1 ships file backends),
then writes:

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
herd backlog                 # list open work items via the active backend (see below)
herd report "<symptom + lane>"   # file an engine bug as a gh issue on HERD_REPO (see below)
```

---

## The `WATCHER_AUTOMERGE` lever (human-in-the-loop)

The watcher runs the full pipeline — healthcheck, then the adversarial review gate — on every
ready PR. `WATCHER_AUTOMERGE` in `.herd/config` controls the *last* step:

- **`true`** (default) — on a review **PASS**, the watcher calls `gh pr merge` itself. Full auto,
  safety-railed: walk away and PRs land.
- **`false`** — the watcher still runs healthcheck + review, but on PASS it **flags the PR
  `ready · awaiting human merge`** and notifies you instead of merging. You keep the merge button;
  the gates still run.

Either way the watcher never merges a conflict, a BLOCK, an un-reviewed commit, or a PR whose state
changed under it.

---

## Fork vs config — how to customize

herdkit is **one engine, many consumers**. You almost never fork it:

- **Consuming projects customize via `.herd/config` + project override hooks in their own repo** —
  paths, branch, model map, the health command (`HEALTHCHECK_CMD`), the resolver smoke gate
  (`SMOKE_CMD`), the review risk list (`REVIEW_CHECKLIST`), privacy paths (`DENY_PATHS`), the
  work-tracker backend (`SCRIBE_BACKEND`), and the auto-merge lever. The generated skill renders
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
bin/herd                       the CLI (init / upgrade / report / render)
scripts/herd/                   the generic engine (sources .herd/config via herd-config.sh)
  coordinator.sh  herd-feature.sh  herd-quick.sh  new-feature.sh
  scribe.sh  scribe-step.sh  research.sh  research-step.sh  research-get.sh
  healthcheck.sh  app-monitor.sh  backlog-view.sh
  herd-resolve.sh  herd-review.sh  agent-watch.sh  herd-watch.sh
  backends/{file,changelog}.sh  the work-tracker adapters
templates/                      coordinator.md.tmpl, config.example, healthcheck examples
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
