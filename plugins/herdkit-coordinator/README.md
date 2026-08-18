# herdkit-coordinator — Codex plugin

A **thin Codex plugin** that exposes the herdkit **coordinator** as an installable skill. It is the
Codex-side sibling of the Claude Code plugin under [`plugin/`](../../plugin/README.md), and it
follows that plugin's stated philosophy exactly.

> **The herdkit CLI is the source of truth.** This plugin does not contain the coordinator logic.
> It wraps the CLI: on invocation it runs `herd render` (which renders the canonical coordinator
> skill from `templates/coordinator.md.tmpl` + your project's `.herd/config` to
> `.agents/skills/herd-coordinator/SKILL.md`) and hands off to that rendered file. Fix the
> coordinator once in the CLI/template; every install picks it up on the next render. See
> [`skills/herd-coordinator/SKILL.md`](skills/herd-coordinator/SKILL.md).

## What it is (and isn't)

| | |
|---|---|
| **Is** | A packaging layer so `codex plugin add` can drop the coordinator into Codex, plus a launcher skill that bootstraps the CLI and delegates to the CLI-rendered `.agents/skills/herd-coordinator/SKILL.md`. |
| **Isn't** | A fork of the coordinator. It ships **no** coordinator prose of its own — no backlog menu, no lane-spawning logic, no review/merge state machine. Those live in the CLI (`bin/herd`, `scripts/herd/*`, `templates/coordinator.md.tmpl`) and stay there. |

## Prerequisites

The plugin is a wrapper, so the **herdkit CLI is a hard prerequisite** and must be installed and on
`PATH` first (the plugin calls `herd render` at runtime):

```sh
git clone https://github.com/briankeegan1/herdkit.git ~/source/herdkit
export PATH="$HOME/source/herdkit/bin:$PATH"   # or: bash ~/source/herdkit/install.sh
```

You also need the CLI's own dependencies (`herdr`, `gh`, `git`, `python3`, `bash`) — run
`herd doctor` to verify. And the project you point it at must be herd-initialized
(`herd init` writes `.herd/config`).

## Install the plugin

The herdkit repository doubles as a **Codex plugin marketplace**: `.agents/plugins/marketplace.json`
at the repo root lists this plugin, and its `source.path` (`./plugins/herdkit-coordinator`) resolves
relative to the marketplace root — the repo root.

From a local checkout:

```sh
codex plugin marketplace add ~/source/herdkit
codex plugin add herdkit-coordinator@herdkit
```

`codex plugin marketplace add` also accepts a Git source (`owner/repo[@ref]`, an HTTPS URL, or an SSH
URL), so the same two commands work against the published repository:

```sh
codex plugin marketplace add briankeegan1/herdkit
codex plugin add herdkit-coordinator@herdkit
```

Verify what Codex sees with `codex plugin list --available --json` (before install) and
`codex plugin list --json` (after).

## Use it

In a herd-initialized project, invoke the skill. Codex namespaces a plugin's skills by plugin name:

```
herdkit-coordinator:herd-coordinator
```

It will: verify `herd` is on `PATH` → confirm `.herd/config` exists (else prompt for `herd init`)
→ run `herd render` → read and follow the CLI-rendered `.agents/skills/herd-coordinator/SKILL.md`.

## Layout

```
.agents/plugins/marketplace.json                 # repo-as-Codex-marketplace (root) — lists this plugin
plugins/herdkit-coordinator/
├── .codex-plugin/plugin.json                    # Codex plugin manifest
├── skills/herd-coordinator/SKILL.md             # the thin wrapper skill (delegates to the CLI)
└── README.md                                    # this file
tests/test-codex-plugin-manifest.sh              # hermetic manifest/skill validity test
```

## Keeping it in sync with the CLI

There is nothing to sync by hand: the plugin holds no coordinator content. When the coordinator
template or the engine changes, the CLI's next `herd render` reflects it, and the plugin (which
delegates to that render) is automatically current. The only plugin-owned surface is packaging
metadata (`plugin.json`, `marketplace.json`) and the launcher `SKILL.md`.

Note that `codex plugin add` **caches** an install under `$CODEX_HOME/plugins/cache/<marketplace>/
<plugin>/<version>/`. Editing these files does not change an already-installed copy — bump
`version` in `plugin.json` (or `codex plugin remove` then `codex plugin add`) to pick the edit up.
That only affects plugin-owned packaging files; the coordinator brief itself is never cached,
because it is rendered by the CLI at invocation time.

## Why this convention, and how it was verified

Codex's plugin packaging surface is real and documented, not inferred. Every claim below was
checked against the installed `codex-cli 0.147.0` (`/opt/homebrew/bin/codex`):

- **The CLI surface.** `codex plugin --help` documents `add`, `list`, `remove`, and
  `marketplace {add,list,upgrade,remove}`. `codex plugin marketplace add` accepts "a local path,
  owner/repo[@ref], HTTPS Git URL, or SSH Git URL".
- **The documented spec.** Codex ships its own first-party `plugin-creator` system skill at
  `$CODEX_HOME/skills/.system/plugin-creator/`, whose `references/plugin-json-spec.md` is the
  canonical manifest spec (required `.codex-plugin/plugin.json`; `name`, `version` as strict semver,
  `description`, `author.name`; a required `interface` block with `displayName`,
  `shortDescription`, `longDescription`, `developerName`, `category`, `capabilities`, and
  `defaultPrompt`) and whose `references/plugin-json-spec.md` marketplace section defines
  `marketplace.json` (`name`, optional `interface.displayName`, and `plugins[]` entries carrying
  `source`, `policy.installation`, `policy.authentication`, and `category`). It also ships the
  executable validator `scripts/validate_plugin.py`, which mirrors the ingestion schema.
- **End-to-end install.** Against a sandboxed `CODEX_HOME`, this exact layout was added
  (`codex plugin marketplace add <root>` → resolved marketplace `herdkit`), listed
  (`codex plugin list --available --json` → `herdkit-coordinator@herdkit`, source resolved to
  `<root>/plugins/herdkit-coordinator`), and installed (`codex plugin add herdkit-coordinator@herdkit`
  → cached with `skills/herd-coordinator/SKILL.md` present). Codex's own
  `validate_plugin.py` passes on this plugin root.
- **Namespacing.** A live `codex exec` turn in a project that had *both* a rendered
  `.agents/skills/herd-coordinator/SKILL.md` and this installed plugin listed both, as
  `herd-coordinator` and `herdkit-coordinator:herd-coordinator` — so the plugin skill is namespaced
  by plugin name and does not shadow the per-project render.
