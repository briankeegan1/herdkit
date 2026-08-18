# herdkit as a herdr plugin

herdkit ships as a first-class [herdr plugin](https://herdr.dev/docs/plugins/) and is listed on the
[herdr plugin marketplace](https://herdr.dev/docs/marketplace/) (an automatic index of public GitHub
repos tagged `herdr-plugin`). The manifest is [`herdr-plugin.toml`](../../herdr-plugin.toml) at the
repo root; the two helper scripts live here.

## Install

```sh
herdr plugin install briankeegan1/herdkit          # from GitHub (confirms, then runs the build step)
herdr plugin install --yes briankeegan1/herdkit    # non-interactive
herdr plugin link ~/source/herdkit                 # or: a local checkout you already have
herdr plugin action list --plugin herdkit          # what you got
```

`herdr plugin install` clones this repository into herdr's plugin store — and **that clone IS the
herdkit engine** (`bin/herd`, `scripts/herd/`, `templates/`), so the plugin is self-contained:
every action runs `$HERDR_PLUGIN_ROOT/bin/herd`, never a separately installed copy. The one-time
`[[build]]` step runs [`install.sh`](../../install.sh) in *local* mode, which additionally symlinks
that `herd` into a writable directory on your `PATH` (or prints the exact `export PATH=…` line to
add) and runs `herd doctor` — advisory: a missing dependency (`gh`, `claude`, `python3`, …) is
reported with per-platform hints, never a failed install. That PATH wiring is what lets the
coordinator agent, builders, and your own shell all reach the same `herd`. `herdr plugin link`
skips the build step; run `bash install.sh` from the checkout yourself if `herd` is not on `PATH`.

Uninstall with `herdr plugin uninstall herdkit` (or `unlink`); remove the `herd` symlink by hand if
you want it gone too.

## Actions

All actions are **workspace-scoped**: invoke one from herdr's action menu (or a keybinding, below)
while focused on the workspace whose directory is the project you want to herd. Each opens one
plugin pane — a split below the focused pane by default — **in that project's directory** and runs
the matching `herd` subcommand there:

| action id | runs | notes |
|---|---|---|
| `herdkit.init` | `herd init` | interactive interview + repo scout → writes `.herd/config`, renders the coordinator skill |
| `herdkit.launch` | `scripts/herd/coordinator.sh` | the control room: coordinator agent + pinned backlog + 🐑 watch console (needs an initialized project) |
| `herdkit.reload` | `herd reload` | rebuild the control room around a live coordinator |
| `herdkit.status` | `herd status` | one-shot read-only snapshot; the pane's exit status is `herd status`'s (non-zero = needs attention) |
| `herdkit.backlog` | `herd backlog --rich` | open work items with state/assignee via the active tracker backend |
| `herdkit.doctor` | `herd doctor` | dependency doctor with per-platform hints |

One-shot verbs hold the pane open (`press Enter to close`) so the output stays readable; `init` hands
the tty straight to `herd`.

Bind a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+h"
type = "plugin_action"
command = "herdkit.status"
description = "herdkit status"
```

Pane placement is overridable per invocation via env on the action's process — herdr does not
expose that from the menu, so in practice set it in the manifest or a wrapper: `HERDKIT_PANE_PLACEMENT`
(`split` default | `tab` | `zoomed` | `overlay`) and `HERDKIT_PANE_DIRECTION` (`down` default | `right`).

## How it works (and the doctrine)

```
herdr-plugin.toml               root manifest — id "herdkit"; [[build]] = install.sh; six [[actions]]; one [[pane]] "run"
packaging/herdr/action.sh       every action → reads workspace_cwd + focused_pane_id from HERDR_PLUGIN_CONTEXT_JSON,
                                opens the `run` pane THERE via `herdr plugin pane open --cwd … --target-pane … --env HERDKIT_VERB=<verb>`
packaging/herdr/pane.sh         the pane's command: PATH="$HERDR_PLUGIN_ROOT/bin:$PATH", then herd <verb> (verb table above)
tests/test-herdr-plugin-manifest.sh   hermetic manifest/contract test (no herdr needed)
```

Two herdr facts shape the design (both verified against herdr 0.8.0):

- **Plugin commands start in the plugin root, not your project.** So an action never runs `herd`
  directly — it opens the plugin's pane with `--cwd` set to the workspace directory from the context
  JSON, and the pane does the work. Actions are pure "open a pane here" launchers.
- **A split/zoomed pane must target an existing pane**, and passing `--workspace` alongside
  `--target-pane` makes herdr reject the split. `action.sh` targets the focused pane and passes
  `--workspace` only when it degrades to a tab (no focused pane in the context).

Same doctrine as the [Claude Code plugin](../../plugin/README.md) and the
[Codex plugin](../../plugins/herdkit-coordinator/README.md): this is a **thin packaging layer**. It
contains no coordinator logic and no forked prose — the CLI (`bin/herd`, `scripts/herd/*`,
`templates/coordinator.md.tmpl`) stays the single source of truth; the plugin only decides *where*
to run it. Fix the engine once and every install picks it up on its next `herdr plugin install`
(or `git pull` in a linked checkout — `herd update` does that for you).

## Publishing (maintainers)

Nothing to submit: the marketplace indexes public repos carrying the GitHub topic **`herdr-plugin`**
and refreshes every ~30 minutes. Keep `version` in the manifest in step with
`plugin/.claude-plugin/plugin.json` (the test enforces it) and bump both when the packaging changes.
