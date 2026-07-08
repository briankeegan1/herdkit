# herdkit (npm)

Thin bootstrapper for **[herdkit](https://github.com/briankeegan1/herdkit)** — the config-driven
multi-agent coordinator workflow for Claude Code, built on the herdr terminal multiplexer.

herdkit is a bash engine. This npm package does **not** re-implement it; it clones the engine to a
managed checkout (`HERDKIT_HOME`, default `~/.herdkit`) and puts a `herd` command on your `PATH`
that execs the real `bin/herd`.

## Install

```bash
npm install -g herdkit
herd doctor      # verify git, gh, claude, python3, (optional) herdr
```

The `postinstall` step clones/updates the engine to `~/.herdkit`, pinned to this package's release
tag. It is **fail-soft**: if `git`/`bash` are missing it prints guidance and does not fail the npm
install — fix the environment, then `npm rebuild -g herdkit`.

## Requirements

- **bash + git** — load-bearing. On Windows, run under **WSL2** (the supported path; native Git
  Bash is best-effort only — see
  [docs/windows.md](https://github.com/briankeegan1/herdkit/blob/main/docs/windows.md)).
- **claude** (Claude Code CLI), **gh** (authenticated GitHub CLI) — for the agent/PR surfaces.
- **herdr** — optional; the headless driver runs without it.

## Environment knobs

| Var | Default | Meaning |
| --- | --- | --- |
| `HERDKIT_HOME` | `~/.herdkit` | where the engine checkout lives |
| `HERDKIT_REPO_URL` | the GitHub repo | clone source |
| `HERDKIT_REF` | `v<version>` | git ref to pin the checkout to |

## Uninstall

```bash
npm uninstall -g herdkit
rm -rf ~/.herdkit    # remove the managed engine checkout
```
