---
name: herd-coordinator
description: Launch the herdkit coordinator — browse/add backlog items and delegate work to isolated git-worktree sub-agents. A thin wrapper around the herdkit CLI, which renders the canonical, per-project coordinator skill; this skill bootstraps the CLI and hands off to what it renders.
---

# herdkit coordinator (plugin wrapper)

This skill is a **thin packaging layer only**. The **herdkit CLI is the single source of
truth** for coordinator behavior:

- `herd` (`bin/herd`) renders the canonical coordinator skill from
  `templates/coordinator.md.tmpl` **+** the project's `.herd/config` into
  `.claude/commands/<COORDINATOR_CMD>.md` (default `.claude/commands/coordinator.md`).
- That render substitutes per-project values (`WORKSPACE_NAME`, `PROJECT_ROOT`,
  `DEFAULT_BRANCH`, `BACKLOG_FILE`, `SCRIPTS_DIR`, `DENY_PATHS`, …) and a live capabilities
  manifest from `templates/capabilities.tsv`.

This plugin does **not** copy, fork, or paraphrase that logic. It bootstraps the CLI and then
**hands off** to whatever the CLI renders, so there is exactly one coordinator definition and it
lives in the CLI. If this wrapper and the CLI-rendered file ever disagree, **the rendered file
wins.**

## What to do when invoked

1. **Verify the herdkit CLI is available.** Run `command -v herd` (or `herd --help`). If `herd`
   is not on `PATH`, tell the user to install herdkit
   (<https://github.com/briankeegan1/herdkit> — add `bin/` to `PATH` or run its `install.sh`) and
   stop. This plugin cannot substitute for the CLI; the CLI is the runtime and the source of truth.

2. **Ensure the project is herd-initialized.** Check for `.herd/config` at the repo root.
   - **Missing** → the project isn't set up for herdkit. Tell the user to run `herd init` first
     (it scouts the repo, interviews, writes `.herd/config`, and renders the coordinator skill),
     then re-invoke. Stop.
   - **Present** → continue.

3. **(Re)render the canonical coordinator skill from the CLI.** Run:

   ```sh
   herd render
   ```

   `herd render` re-renders **only** the coordinator skill from the current `.herd/config` (no
   version bump) and prints the path it wrote — e.g. `.claude/commands/coordinator.md`. Rendering
   on invocation is what keeps this plugin thin: the brief is per-project and would drift the
   instant the template or `.herd/config` changed, so a statically-shipped copy is never correct.

4. **Hand off to the CLI-rendered skill.** Read the file `herd render` printed (default
   `.claude/commands/coordinator.md`) and follow everything below its frontmatter **verbatim** as
   your operating instructions for this session. That rendered file is the real coordinator brief:
   the backlog menu (`herd backlog`), lane spawning (`herd-feature.sh` / `herd-quick.sh`),
   review + auto-merge handling, the conflict resolver, and backlog writes via the scribe.

**Do not reimplement any coordinator behavior in this wrapper.** Your only job here is steps 1–4:
confirm the CLI, ensure the render, and delegate to it.

## Why a wrapper and not a copy

The coordinator brief is generated per project and evolves with the engine. Shipping a frozen copy
inside the plugin would (a) fork the logic the moment the template or a project's `.herd/config`
changed, and (b) hardcode one project's `WORKSPACE_NAME`/paths into a package meant to be generic.
Rendering through the CLI on every invocation keeps the plugin a thin launcher and the CLI
canonical — fix the coordinator once in the template, and every install picks it up on the next
`herd render`.
