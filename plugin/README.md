# herdkit-coordinator — Claude Code plugin

A **thin Claude Code plugin** that exposes the herdkit **coordinator** as an installable skill.

> **The herdkit CLI is the source of truth.** This plugin does not contain the coordinator logic.
> It wraps the CLI: on invocation it runs `herd render` (which renders the canonical coordinator
> skill from `templates/coordinator.md.tmpl` + your project's `.herd/config`) and hands off to that
> rendered file. Fix the coordinator once in the CLI/template; every install picks it up on the
> next render. See [`skills/herd-coordinator/SKILL.md`](skills/herd-coordinator/SKILL.md).

## What it is (and isn't)

| | |
|---|---|
| **Is** | A packaging layer so `/plugin install` can drop the coordinator into Claude Code, plus a launcher skill that bootstraps the CLI and delegates to the CLI-rendered `.claude/commands/coordinator.md`. |
| **Isn't** | A fork of the coordinator. It ships **no** coordinator prose of its own — no backlog menu, no lane-spawning logic, no review/merge state machine. Those live in the CLI (`bin/herd`, `scripts/herd/*`, `templates/coordinator.md.tmpl`) and stay there. |

## Prerequisites

The plugin is a wrapper, so the **herdkit CLI is a hard prerequisite** and must be installed and on
`PATH` first (the plugin calls `herd render` at runtime):

```sh
git clone https://github.com/briankeegan1/herdkit.git ~/source/herdkit
export PATH="$HOME/source/herdkit/bin:$PATH"   # or: bash ~/source/herdkit/install.sh
```

You also need the CLI's own dependencies (`herdr`, `claude`, `gh`, `git`, `python3`, `bash`) — run
`herd doctor` to verify. And the project you point it at must be herd-initialized
(`herd init` writes `.herd/config`).

## Install the plugin

The herdkit repository doubles as a **plugin marketplace** (`.claude-plugin/marketplace.json` at
the repo root lists this plugin under `plugin/`). From Claude Code:

```
/plugin marketplace add briankeegan1/herdkit
/plugin install herdkit-coordinator@herdkit
```

To install from a local checkout instead of GitHub:

```
/plugin marketplace add ~/source/herdkit
/plugin install herdkit-coordinator@herdkit
```

## Use it

In a herd-initialized project, invoke the skill (namespaced by plugin name):

```
/herdkit-coordinator:herd-coordinator
```

It will: verify `herd` is on `PATH` → confirm `.herd/config` exists (else prompt for `herd init`)
→ run `herd render` → read and follow the CLI-rendered `.claude/commands/coordinator.md`.

## Layout

```
.claude-plugin/marketplace.json          # repo-as-marketplace (root) — lists this plugin
plugin/
├── .claude-plugin/plugin.json           # plugin manifest
├── skills/herd-coordinator/SKILL.md     # the thin wrapper skill (delegates to the CLI)
└── README.md                            # this file
tests/test-plugin-manifest.sh            # hermetic manifest/skill validity test
```

## Keeping it in sync with the CLI

There is nothing to sync by hand: the plugin holds no coordinator content. When the coordinator
template or the engine changes, the CLI's next `herd render` reflects it, and the plugin (which
delegates to that render) is automatically current. The only plugin-owned surface is packaging
metadata (`plugin.json`, `marketplace.json`) and the launcher `SKILL.md`.

## Verifying the plugin format

The manifest and marketplace files were authored against the Claude Code plugin reference
(`.claude-plugin/plugin.json` manifest; skills under `skills/<name>/SKILL.md`; marketplace under
`.claude-plugin/marketplace.json`). The hermetic test asserts they are valid and internally
consistent, but it **cannot** exercise a real `/plugin install` — that requires a live Claude Code
session. See the PR's `HUMAN-VERIFY` block for the install smoke test a human must run.
