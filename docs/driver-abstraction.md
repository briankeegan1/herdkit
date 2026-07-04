# Driver abstraction for the coordinator skill

**Status:** phase 1 (this document + a factoring restructure of `templates/coordinator.md.tmpl`).
Phase 2 (an actual second runtime) is **designed here, not built**.

**Origin:** Leak F in [`external-consumer-audit.md`](external-consumer-audit.md) and the backlog item
*"[P3] Renderable coordinator skill for non-herdr/non-Claude drivers."* The rendered coordinator
skill hard-codes the herdr multiplexer and the Claude Code agent runtime as its control surface, so
a team on a different runtime (a VS Code extension, a CI bot, a different multiplexer) cannot swap
the control surface without forking the whole coordinator template.

**This phase deliberately does not pick or support a second runtime.** The single supported path is
still herdr + Claude Code, and the rendered skill is **functionally identical** to before. The goal
is only to make the driver surface **visible** (catalogued and greppable) and **single-sourced** (one
place that defines each capability → incantation), so the phase-2 swap becomes mechanical.

---

## The driver: two runtime-specific surfaces

Almost everything the coordinator runs is runtime-independent and needs no abstraction:

- the **engine CLI** — `herd backlog`, `herd config …`, `herd why`, `herd log`, `herd report`,
  `herd update`;
- the **lane scripts** under `scripts/herd/` — `herd-feature.sh`, `herd-quick.sh`, `scribe.sh`,
  `research.sh`, `herd-resolve.sh`, `herd-approve.sh`, `backlog-reconcile.sh`;
- the **git host** — `gh pr …`, `gh issue`.

These are the same no matter which agent runtime builds the code. The **driver** is only the two
surfaces that *are* runtime-specific:

1. **The multiplexer** — today `herdr`. Owns tabs, panes, and the mapping from a builder *slug* to a
   live *agent pane*. Provides: list agents, focus an agent, send text to a pane, create a tab, read
   a pane, send raw keys.
2. **The agent runtime** — today Claude Code. Controlled by text (and `/`-commands) delivered *through*
   the multiplexer into an agent pane. Provides: start an agent on a task, switch model mid-session,
   and the auto-submit convention (text sent to a Claude Code pane is submitted without a separate
   Enter keystroke — a driver-specific behavior a different runtime would not share).

A "driver" is the concrete binding of the capabilities below to one multiplexer + one runtime.

---

## Capability model (the abstract driver interface)

Each capability is what a future driver definition must supply. The **herdr + Claude Code** column is
the current binding; the **token** column is the phase-2 substitution point (see below).

| Capability            | What it does                                                        | herdr + Claude Code today                            | Phase-2 token            |
| --------------------- | ------------------------------------------------------------------- | ---------------------------------------------------- | ------------------------ |
| `list-agents`         | Enumerate sub-agents with running / idle / blocked status           | `herdr agent list`                                   | `{{DRIVER_LIST_AGENTS}}` |
| `focus-agent`         | Jump to / hand off to a builder's agent by slug                     | `herdr agent focus <slug>`                           | `{{DRIVER_FOCUS_AGENT}}` |
| `send-text`           | Send a prompt/command to a builder's agent pane (auto-submitted)    | `herdr pane run <agent-pane> "<text>"`               | `{{DRIVER_SEND_TEXT}}`   |
| `switch-model`        | Switch the agent runtime's model mid-session                        | send `/model <value>` via `send-text`                | `{{DRIVER_SWITCH_MODEL}}`|
| `start-agent`         | Spawn an agent on a task in a fresh tab/pane                         | the lane scripts (`herd-feature.sh` / `herd-quick.sh`)| `{{DRIVER_START_AGENT}}` |
| `create-tab`         | Create a tab/pane in the target workspace                            | `herdr tab create --workspace <ws>`                  | `{{DRIVER_CREATE_TAB}}`  |
| `read-pane`           | Capture a pane's current contents                                   | `herdr pane read <pane>`                             | `{{DRIVER_READ_PANE}}`   |
| `send-keys`           | Send raw keystrokes (control keys, menu navigation) to a pane       | `herdr pane send-keys <pane> <keys>`                 | `{{DRIVER_SEND_KEYS}}`   |

`send-text` vs `send-keys` is the same distinction the operator memory captures: **`send-text`
auto-submits on Claude Code**, so a prompt goes in with one call; **`send-keys`** is for raw control
input (e.g. menu navigation) and never auto-submits. A driver for a runtime that does *not* auto-submit
would bind `send-text` to a send-then-Enter pair — which is exactly why the capability, not the raw
command, is the unit of abstraction.

---

## Inventory: driver incantations in `templates/coordinator.md.tmpl`

Every place the coordinator skill is currently bound to herdr + Claude Code. After the phase-1
restructure each carries a `DRIVER:<capability>` marker, so the surface is one `grep DRIVER:` away.
The **"Driver commands (herdr + Claude Code)"** section near the top of the template is the single
source that defines these; the rows below are the inline uses that reference it.

| # | Template location                                          | Incantation                                        | Capability                                  |
| - | ---------------------------------------------------------- | -------------------------------------------------- | ------------------------------------------- |
| 1 | *Driver commands* reference section                        | (defines all four inline capabilities)             | `list-agents` `focus-agent` `send-text` `switch-model` |
| 2 | *On invocation* — "Get current state of in-flight work"    | `herdr agent list`                                 | `list-agents`                               |
| 3 | *Implement an item* — step 5, "how to jump"                | `herdr agent focus <slug>`                         | `focus-agent`                               |
| 4 | *Step up a builder mid-flight* — the `/model` step-up      | `herdr pane run <agent-pane> "/model <value>"`     | `send-text` + `switch-model`                |
| 5 | *Step up a builder mid-flight* — "target the agent pane"   | `herdr agent list` (name == slug)                  | `list-agents`                               |
| 6 | *Step up a builder mid-flight* — "a separate pane run"     | `herdr pane run`                                    | `send-text`                                 |
| 7 | *Check running agents* — step 1, match agents to PRs       | `herdr agent list`                                 | `list-agents`                               |
| 8 | *Auto-refix false branch* — "re-task builders by hand"     | `herdr agent focus <slug>`                         | `focus-agent`                               |

So the coordinator skill itself binds **four** distinct capabilities — `list-agents`, `focus-agent`,
`send-text`, `switch-model` — across eight sites. The remaining capabilities in the model above
(`start-agent`, `create-tab`, `read-pane`, `send-keys`) are exercised by the **lane scripts** and the
**watcher**, not by inline skill text; they are inventoried here so a phase-2 driver definition covers
the entire surface, not just the four the skill names.

The audit's "~25 herdr/claude control incantations" counts every herdr/claude/gh mention across the
file. Narrowed to the *runtime-specific* driver surface (excluding the runtime-independent `herd`
engine CLI and `gh` git host, which never need a driver), the skill's own binding collapses to the
four capabilities / eight sites above — which is what phase 2 must tokenize.

---

## Phase-2 design (described, not built)

The mechanism reuses the existing render pipeline in `bin/herd` (`render_skill()`), which already
turns `templates/coordinator.md.tmpl` into `.claude/commands/<name>.md` by pure bash string
replacement of `{{TOKEN}}`s sourced from `.herd/config` (`{{WORKSPACE_NAME}}`, `{{PROJECT_ROOT}}`,
`{{HERD_REPO}}`, `{{SCRIPTS_DIR}}`, `{{CAPABILITIES}}`, …). Phase 2 adds a driver dimension to that
same substitution.

### 1. A driver definition file

Add a small, declarative driver file — e.g. `templates/drivers/<driver>.driver` shipped with the
engine, selected per project by a new `.herd/config` key `DRIVER` (default `herdr-claude`). Each file
binds every capability to a concrete incantation:

```sh
# templates/drivers/herdr-claude.driver — the default binding (byte-identical to today's output)
DRIVER_LIST_AGENTS='herdr agent list'
DRIVER_FOCUS_AGENT='herdr agent focus <slug>'
DRIVER_SEND_TEXT='herdr pane run <agent-pane> "<text>"'
DRIVER_SWITCH_MODEL='send `/model <value>` via herdr pane run'
DRIVER_START_AGENT='bash {{SCRIPTS_DIR}}/herd-feature.sh <slug> "<task>"'
DRIVER_CREATE_TAB='herdr tab create --workspace <ws>'
DRIVER_READ_PANE='herdr pane read <pane>'
DRIVER_SEND_KEYS='herdr pane send-keys <pane> <keys>'
```

A different runtime ships its own file (e.g. `vscode-copilot.driver`, `ci-bot.driver`) binding the
same keys to its own control surface. The file is shell (sourced, like `.herd/config` already is), so
it composes with the existing `render_skill` sourcing model with no new parser.

### 2. Tokenize the template

Replace each inline incantation in `coordinator.md.tmpl` with its `{{DRIVER_*}}` token (the markers
added in phase 1 mark exactly the sites). The *prose* around each token — the "when / why" that makes
the skill useful — stays; only the concrete command becomes a token. The **"Driver commands"**
reference section becomes the rendered summary of the active driver's bindings.

### 3. Extend `render_skill()`

In `bin/herd`, after sourcing `.herd/config`, `render_skill()` also sources the selected driver file
(`${DRIVER:-herdr-claude}`) and adds the `DRIVER_*` keys to its existing line-by-line replacement
loop — the same `line="${line//\{\{TOKEN\}\}/$VALUE}"` pattern already used for the current tokens. No
new machinery: one more sourced file, one more block of substitutions. `herd config` gains `DRIVER` as
a validated key (capabilities manifest) so `herd config set DRIVER <name>` re-renders the skill,
exactly as other coordinator-facing keys already do.

### 4. Guarantees to preserve

- **Default is byte-identical.** With `DRIVER=herdr-claude` the rendered skill must match today's
  output exactly — the phase-1 restructure already keeps rendered behavior equivalent, so tokenizing
  against the default binding is a no-op diff. The hermetic template lint should assert this.
- **`GENERATED BY … DO NOT HAND-EDIT` header and every existing `{{TOKEN}}` stay intact.**
- **No secrets in the driver file.** It is committed, so it holds only command shapes, never
  credentials (same contract as `.herd/config`).
- **Capability completeness is validated.** A driver file missing a capability the template tokenizes
  should fail the render loudly (an unrendered `{{DRIVER_*}}` token), not silently emit a broken
  skill — mirroring the existing "no leftover `{{tokens}}`" lint.

### Non-goals for phase 2

Building an actual second driver (VS Code / CI), abstracting the lane scripts' own internals, or
touching the watcher's pane I/O. Phase 2 is only: *definition file + token substitution + config key*,
so that a future driver is a data file, not a fork.
