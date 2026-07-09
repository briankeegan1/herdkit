# Driver abstraction for the coordinator skill

**Status:** phase 1 (this document + a factoring restructure of `templates/coordinator.md.tmpl`) and
phase 2 (the render-time `{{DRIVER_*}}` token machinery + `HERD_DRIVER` config key) have **shipped**.
Phase 3 — an actual second driver, **`headless`** — has now shipped too; see
[Phase 3: the headless driver](#phase-3-the-headless-driver-shipped) at the end of this document.
The sections below (originally written for phase 1) describe the design that phases 2–3 realized.

A follow-on **agent-runtime portability epic (HERD-150)** extends the same `.driver` format to the
`claude`-specific *exec* surface (spawn / one-shot / resume / model-switch / limit-detection /
cost-parse). Its **phase 1 — the exec-surface audit + capability bindings — has shipped**, and
**phase 2 — routing the interactive-spawn LANES (`herd-feature.sh` / `herd-quick.sh` /
`herd-resolve.sh`) through the spawn binding (HERD-174) — has now shipped too**; see
[Agent-runtime portability epic](#agent-runtime-portability-epic-herd-150) at the end. Phases 3–4
(resume / model-switch, then limit-detection / session-identity / cost) are not built yet.

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
   and the auto-submit convention (text is typed then an explicit Enter is sent — HERD-186; a
   driver-specific submit shape a different runtime would rebind).

A "driver" is the concrete binding of the capabilities below to one multiplexer + one runtime.

---

## Capability model (the abstract driver interface)

Each capability is what a future driver definition must supply. The **herdr + Claude Code** column is
the current binding; the **token** column is the phase-2 substitution point (see below).

| Capability            | What it does                                                        | herdr + Claude Code today                            | Phase-2 token            |
| --------------------- | ------------------------------------------------------------------- | ---------------------------------------------------- | ------------------------ |
| `list-agents`         | Enumerate sub-agents with running / idle / blocked status           | `herdr agent list`                                   | `{{DRIVER_LIST_AGENTS}}` |
| `focus-agent`         | Jump to / hand off to a builder's agent by slug                     | `herdr agent focus <slug>`                           | `{{DRIVER_FOCUS_AGENT}}` |
| `send-text`           | Send a prompt/command to a builder's agent pane (auto-submitted)    | `herdr pane run …; herdr pane send-keys … Enter` (HERD-186) | `{{DRIVER_SEND_TEXT}}`   |
| `switch-model`        | Switch the agent runtime's model mid-session                        | send `/model <value>` via `send-text`                | `{{DRIVER_SWITCH_MODEL}}`|
| `start-agent`         | Spawn an agent on a task in a fresh tab/pane                         | the lane scripts (`herd-feature.sh` / `herd-quick.sh`)| `{{DRIVER_START_AGENT}}` |
| `create-tab`         | Create a tab/pane in the target workspace                            | `herdr tab create --workspace <ws>`                  | `{{DRIVER_CREATE_TAB}}`  |
| `read-pane`           | Capture a pane's current contents                                   | `herdr pane read <pane>`                             | `{{DRIVER_READ_PANE}}`   |
| `send-keys`           | Send raw keystrokes (control keys, menu navigation) to a pane       | `herdr pane send-keys <pane> <keys>`                 | `{{DRIVER_SEND_KEYS}}`   |

`send-text` vs `send-keys` is the same distinction the operator memory captures: **`send-text`
types then submits** (HERD-186: `pane run` + explicit `send-keys Enter` — live 2026-07-08 showed
`pane run` alone can leave text sitting in an agent prompt buffer), so a prompt goes in with one
capability call; **`send-keys` alone** is for raw control input (e.g. menu navigation) without a
surrounding prompt. Binding `send-text` to a send-then-Enter pair is exactly why the capability, not
the raw command, is the unit of abstraction.

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
DRIVER_SEND_TEXT='herdr pane run <agent-pane> "<text>"; herdr pane send-keys <agent-pane> Enter'
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

---

## Phase 3: the headless driver (shipped)

Phase 2's token machinery makes the coordinator *skill* driver-swappable at render time. But the
capability model above also names four capabilities the **watcher** and **lane scripts** exercise at
*runtime* — `start-agent`, `create-tab`, `read-pane`, `send-keys` — plus notifications and
`list-agents`, all still hard-wired to herdr. Phase 3 (HERD-7) adds the first non-herdr driver,
**`headless`**, and the runtime plumbing those capabilities need.

**Design principle: panes become a view, not a dependency.** Everything load-bearing — the watcher's
merge gating, journal writes, notifications, and limit detection — must run correctly with **no herdr
panes at all**. The herdr control room becomes an *optional* cockpit. This unlocks Windows / CI /
headless Linux, where no herdr exists.

### 1. The driver definition — `templates/drivers/headless.driver`

Binds all eight capabilities (same keys as `herdr-claude.driver`) to headless incantations. Selected
by `HERD_DRIVER=headless`; `herd render` then substitutes them into the coordinator skill exactly as
for any driver. Zero-secret, command-shapes only — same contract as every driver file.

### 2. The runtime shim — `scripts/herd/driver.sh`

The runtime counterpart to render-time tokenization: one seam that binds each capability to a
concrete implementation, dispatched on `HERD_DRIVER`. It is **sourced** (functions only, no side
effects — lib-safe) by `agent-watch.sh`, `dep-watcher.sh`, and the lane scripts after
`herd-config.sh`, and is also **runnable as a CLI** (`bash driver.sh <cap> …`) so the rendered
headless coordinator skill drives the same surface. Two hard guarantees:

- **Fail soft.** Every capability returns `0` (or a safe empty result) on any failure — a missing
  pane, a missing herdr, a missing registry never aborts a caller under `set -euo pipefail`. A
  missing pane must never stop load-bearing work.
- **Byte-identical default.** For `HERD_DRIVER=herdr-claude` every capability runs the *exact* herdr
  command it replaces, so the default driver's behavior is unchanged.

### 3. Capability semantics under headless

Each capability gets **either a real headless equivalent or explicit, documented view-only / no-op
semantics** — always fail-soft:

| Capability     | Headless implementation                                                                 |
| -------------- | --------------------------------------------------------------------------------------- |
| `start-agent`  | REAL — a **detached** background `claude` (nohup), stdout+stderr → a registry log        |
| `list-agents`  | REAL — a **detached-agent registry** (`$WORKTREES_DIR/.herd/agents/<slug>/`) rendered in herdr's JSON shape, so dead-builder reconciliation works with no panes |
| `read-pane`    | REAL — tails the detached agent's captured log                                           |
| notifications  | REAL — a durable `.herd/notifications.log` sink (+ best-effort native `osascript`/`notify-send`) |
| `send-text`    | BEST-EFFORT — appends to the agent's `input` queue file (a headless runtime may drain it) |
| `switch-model` | BEST-EFFORT — a `/model` line via `send-text` (same seam)                                |
| `focus-agent`  | VIEW — prints how to tail the agent's log (no pane to focus)                             |
| `create-tab`   | NO-OP — headless has no tabs                                                             |
| `send-keys`    | NO-OP — raw keystrokes are a pane concept                                                |

The **detached-agent registry** is the key to correctness: `list-agents` reports only live pids
(`kill -0`), so the watcher's dead-builder reconciliation — which keys off "agent vanished while the
worktree lives on with no PR" — behaves the same with or without panes, instead of falsely reaping
every builder because `herdr agent list` is empty.

### 4. What the watcher's load-bearing core does NOT depend on

Merge gating (`gh` + `healthcheck.sh` + the review gate) and journal writes were already
runtime-independent; phase 3 only had to route the pane-coupled bits — `list-agents` (liveness),
notifications, the limit-menu pane read/keys, and the auto-respawn spawn — through the shim, and make
each fail soft. Limit *detection* is primarily a hook-sentinel file (already headless-friendly); the
herdr clean-menu-select path is a pane concept, so under headless it falls straight through to the
existing `claude --continue` backstop.

---

## Agent-runtime portability epic (HERD-150)

Phases 1–3 above made the **multiplexer** (herdr → panes) swappable — the coordinator *skill*
renders per-driver, and the runtime shim (`scripts/herd/driver.sh`) routes the pane surface. But the
**agent runtime** — Claude Code itself — is still hard-wired: the lanes spawn `claude --model … "$prompt"`,
the drainers shell out to `claude -p …`, the watcher resumes with `claude --continue`, limit
detection greps the Claude usage-limit banner, and `cost.sh` parses Claude's transcript JSON. Swap
Claude for another agent runtime (an SDK loop, a different CLI) and every one of those breaks.

This epic factors the **agent-exec surface** out of the code and into the `.driver` file, the same
way phases 1–3 did the mux surface. It is scoped in **6 phases**; this document tracks P1, which has
shipped. **P1 is a pure data + docs change and routes NOTHING** — it only (a) audits every
claude-specific incantation into capability *classes* (the table below is the P2–P4 work map), and
(b) adds a binding per class to both shipped `.driver` files (`DRIVER_AGENT_*`), carrying today's
**exact** strings. Because no template token and no runtime call site consumes the new bindings yet,
`herd render` output and all runtime behavior are **byte-identical** — the safety rail is the
before/after render diff plus the parse/completeness unit test (`tests/test-driver-agent-exec.sh`).

### Phase status

| Phase | Scope                                                                                  | Status      |
| ----- | -------------------------------------------------------------------------------------- | ----------- |
| P1    | Audit the exec surface into capability classes; add `DRIVER_AGENT_*` bindings (data + docs, byte-identical) | **shipped** |
| P2    | Route the interactive-spawn **lanes** (feature/quick/resolve) through the spawn binding (spawn template + model flag + permission flag + session identity), resolved driver made REAL at spawn (HERD-174) | **shipped** |
| P3    | Route **resume + model-switch** through the bindings                                    | not built   |
| P4    | Route **limit-detection + session-identity + cost/telemetry** through the bindings      | not built   |
| P5    | Ship a second, non-Claude agent-runtime driver binding the exec surface                 | not built   |
| P6    | Drop the last direct `claude`/transcript reference from the engine tree                 | not built   |

### The exec surface: capability classes → call sites (the P2–P4 work map)

Every direct `claude`-specific incantation in `scripts/herd/*.sh` + `bin/herd`, grouped by the
capability class it belongs to. Each class has one `DRIVER_AGENT_*` binding (right column) carrying
the exact string herdr-claude uses today. `file:line` refs are the routing targets for P2–P4.
(Comment/prose mentions of these strings are excluded — only live call sites are listed.)

#### 1. interactive-spawn — `DRIVER_AGENT_INTERACTIVE_SPAWN`

Spawn an agent into a tab/pane on an opening prompt: `claude --model <model> --dangerously-skip-permissions "<prompt>"`.

| Site                                   | Role                                                      |
| -------------------------------------- | -------------------------------------------------------- |
| `scripts/herd/herd-feature.sh:230`     | builder lane (herdr `agent start … -- claude`)           |
| `scripts/herd/herd-quick.sh:235`       | quick-builder lane                                        |
| `scripts/herd/herd-resolve.sh:77`      | conflict-resolver lane (via `herd_driver_launch_agent`)  |
| `scripts/herd/herd-review.sh:505`      | agent-pane reviewer (via `herd_driver_launch_agent`)     |
| `scripts/herd/scribe.sh:205`           | scribe drainer agent-pane                                |
| `scripts/herd/research.sh:162`         | research drainer agent-pane                              |
| `scripts/herd/agent-watch.sh:3554`     | dead-builder auto-respawn (herdr)                        |
| `scripts/herd/driver.sh:544`           | herdr start-agent shim (positional argv)                 |
| `scripts/herd/driver.sh:641`           | herdr launch-agent shim (generalized argv)               |
| `scripts/herd/driver.sh:528`, `:616`   | headless start/launch (detached `nohup claude …`)        |

#### 2. one-shot-exec — `DRIVER_AGENT_ONESHOT_EXEC`

Headless one-shot query, no pane: `claude -p "<prompt>" --model <model> --dangerously-skip-permissions`.

| Site                               | Role                                          |
| ---------------------------------- | --------------------------------------------- |
| `scripts/herd/herd-advise.sh:113`  | mid-flight strong-model advisor               |
| `scripts/herd/herd-review.sh:287`  | local pre-merge review (headless `-p`)        |
| `scripts/herd/herd-review.sh:591`  | headless PR review (`-p`)                      |
| `bin/herd:557`                     | governance-sentence → enforcement-surface map |
| `bin/herd:764`                     | repo scout pass (interview defaults)          |

#### 3. resume — `DRIVER_AGENT_RESUME`

Resume an ended session in place with full context: `claude <flags> --continue "<prompt>"`.

| Site                                  | Role                                                             |
| ------------------------------------- | --------------------------------------------------------------- |
| `scripts/herd/agent-watch.sh:2671`    | builder in-place limit resume (`cd <wt> && claude … --continue`)|
| `scripts/herd/agent-watch.sh:3113+`   | coordinator limit-resume watchdog backstop (`claude --continue`)|

#### 4. model-switch — `DRIVER_AGENT_MODEL_SWITCH`

Switch model mid-session by sending `/model <model>` into a live session (delivered via the mux
`DRIVER_SEND_TEXT`). Render-time token: `{{DRIVER_SWITCH_MODEL}}`.

| Site                                  | Role                                       |
| ------------------------------------- | ------------------------------------------ |
| `templates/coordinator.md.tmpl:271`   | coordinator builder step-up (`/model` line)|

#### 5. permission-mode flag — `DRIVER_AGENT_PERMISSION_FLAG`

The tool-permission-bypass flag, defaulted by every lane: `--dangerously-skip-permissions`
(`HERD_CLAUDE_FLAGS` override).

| Site                                                                                        | Role                          |
| ------------------------------------------------------------------------------------------- | ----------------------------- |
| `herd-feature.sh:70`, `herd-quick.sh:77`, `herd-resolve.sh:32`, `herd-review.sh:125`        | builder / reviewer lane default |
| `herd-advise.sh:77`, `scribe.sh:31`, `research.sh:36`                                        | drainer / advisor default     |
| `agent-watch.sh:2667`, `agent-watch.sh:3535`                                                 | resume / respawn default      |
| `scripts/herd/driver.sh:525`, `:542`, `:609`                                                 | shim fallback default         |

#### 6. limit-detection pattern — `DRIVER_AGENT_LIMIT_PATTERN`

The Claude usage-limit signals: transcript banner regex, clean-menu regex, hook sentinel, menu keys.

| Site                                  | Role                                                              |
| ------------------------------------- | ---------------------------------------------------------------- |
| `scripts/herd/agent-watch.sh:2775`    | banner scrape regex `usage limit\|session limit\|hit your …`     |
| `scripts/herd/agent-watch.sh:2882`    | clean-menu detect regex `Upgrade your plan\|Stop and wait\|…`    |
| `scripts/herd/agent-watch.sh:2684`    | hook sentinel file `.herd-limit-sentinel`                        |
| `scripts/herd/agent-watch.sh:2871`    | limit-menu keystrokes (`Down Enter`)                             |
| `scripts/herd/herd-config.sh:775`     | `rate_limit` StopFailure hook writer (sentinel source)           |

`DRIVER_AGENT_LIMIT_PATTERN` binds the primary banner regex; P4 lifts the menu regex + keys + hook
matcher alongside it.

#### 7. session-identity — `DRIVER_AGENT_SESSION_ID`

Where a runtime session's transcript lives and how a session is fingerprinted:
`$HERD_TRANSCRIPT_ROOT` (default `$HOME/.claude/projects`) `/<cwd with / and . → ->/*.jsonl`.

| Site                                        | Role                                                     |
| ------------------------------------------- | -------------------------------------------------------- |
| `scripts/herd/cost.sh:272`                  | transcript-dir munge (`_cost_transcript_dir`)            |
| `scripts/herd/agent-watch.sh:2693`, `:3221` | same munge (limit-banner read / idle-token gauge)        |
| `scripts/herd/cost.sh:56`–`58`              | first-message fingerprints (coordinator/scribe/researcher) |

#### 8. cost/telemetry parse — `DRIVER_AGENT_COST_USAGE_KEYS`

The Claude transcript usage JSON fields `cost.sh` sums + prices.

| Site                              | Role                                                                        |
| --------------------------------- | --------------------------------------------------------------------------- |
| `scripts/herd/cost.sh:183`–`186`  | usage keys `input_tokens/output_tokens/cache_creation_input_tokens/cache_read_input_tokens` |
| `scripts/herd/cost.sh:195`–`196`  | `ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`                   |
| `scripts/herd/cost.sh:63`–`67`    | model→USD price table (Claude model ids)                                    |

### Why byte-identical (the P1 guarantee)

The new `DRIVER_AGENT_*` keys are sourced by `render_skill()` (they match `compgen -v DRIVER_`), but
`templates/coordinator.md.tmpl` contains **no** `{{DRIVER_AGENT_*}}` token, so the substitution loop
never touches them — the rendered skill is unchanged. No runtime script reads them either. The proof
is a before/after `herd render` diff (empty) plus `tests/test-driver-agent-exec.sh`, which asserts
both `.driver` files parse with the extended format, every class is bound in **both** drivers, the
bindings are zero-secret, and none of their values leak into a rendered skill.

### Phase 2 — routing the interactive-spawn lanes (HERD-174, shipped)

P2 makes the **interactive-spawn** binding *real at spawn*. The three lanes that open an agent on a
prompt — `herd-feature.sh`, `herd-quick.sh`, `herd-resolve.sh` — no longer hardcode
`claude --model <model> <flags> <prompt>` after the `herdr agent start … --`; they **compose** that
agent-runtime argv from the resolved driver's `DRIVER_AGENT_INTERACTIVE_SPAWN` + `DRIVER_AGENT_PERMISSION_FLAG`
bindings, through one seam.

- **The seam** — `herd_driver_agent_spawn_argv <driver> <model> <flags> <prompt>` (in `driver.sh`)
  tokenizes the driver's spawn template and substitutes the P1 classes: `<model>` (empty ⇒ the
  `--model` pair is dropped), the permission-flag token (⇒ the lane's `<flags>`, word-split; empty ⇒
  dropped), and `<prompt>`. It emits a NUL-delimited argv the callers read into a bash array. The
  builder lanes route through `herd_driver_launch_agent` (which now also composes its `--` tail via the
  seam); `herd-resolve.sh` already used that seam, so it inherited the routing.
- **Resolved driver made REAL, not discarded** — the model half of a runtime-qualified ref
  (`<driver>:<model>`, below) was resolved and then *thrown away*, so every spawn was always `claude`.
  Now the lanes resolve the **driver** too (`herd_model_driver_for`) and thread it to the seam, so a
  `MODEL_*` ref like `foo:opus` composes **`foo`'s** `DRIVER_AGENT_INTERACTIVE_SPAWN` — the qualified
  driver selects the spawn binding. For a bare model the driver resolves to the default, so the spawn is
  **byte-identical** to before.
- **Session identity for a non-native runtime (HERD-178 seam)** — the mux tracks a *native* `claude`
  agent by fingerprinting the pane's foreground process; a runtime whose spawn binding is not `claude`
  is invisible to that probe. `herd_driver_agent_runtime_native` classifies the resolved runtime and,
  when it is non-native, the lanes register the agent's identity + state with the mux via
  `herd_driver_report_agent` (`herdr pane report-agent`, also a `driver.sh report-agent` CLI verb) — a
  clean **no-op for the native runtime**, so the default path stays byte-identical.

**Proof:** the before/after `herd render` diff stays empty (no template/token consumes the routing —
`test-driver-agent-exec.sh` / `test-driver-abstraction.sh`), and `tests/test-driver-lane-spawn.sh`
asserts the composed spawn command byte-for-byte (default + every class edge), the foreign-runtime
composition (driver is real), and that all three lanes route through the one seam. P3–P4 (resume /
model-switch, then limit-detection / cost) still route their own classes later.

### Model matrix — runtime-qualified `MODEL_*` refs (HERD-151)

Building on P1's audit, every `MODEL_*` config value accepts an optionally runtime-qualified ref
**`<driver>:<model>`**: a **bare** model id (no colon) resolves to the **default driver**
(`herd_driver_name`) — byte-identical to before — while a `<driver>:` prefix pins that role's agent to
a shipped runtime driver (`templates/drivers/<name>.driver`) **and** model. This is the config surface
that will let the P2–P5 routing send different roles to different runtimes.

**Seam: `scripts/herd/driver.sh`, not `herd-config.sh`.** A model ref binds a role to a *runtime*, and
the runtime surface is exactly what the P1 `DRIVER_AGENT_*` audit factored into the `.driver` files.
The valid-driver set *is* the `templates/drivers/*.driver` enumeration `render_skill()` already
validates `HERD_DRIVER` against, so the resolver reuses that ground truth and sits next to the exec
bindings the routing phases will thread the resolved `(driver, model)` through. `driver.sh` is already
sourced by every spawn lane and by `bin/herd`, so one helper covers the whole spawn surface;
`herd-config.sh` only sets defaults and is sourced *everywhere*, where a loud resolver would be the
wrong altitude (config load must never abort — a spawn must, on a bad ref).

The resolver (`herd_model_resolve` / `herd_model_for_spawn`) is a **deliberate exception** to
`driver.sh`'s fail-soft rule: an **unknown driver prefix is a LOUD hard error at spawn time**, never a
silent `claude` fallback — a misconfigured ref is an operator error that must stop the spawn, not
downgrade to the wrong runtime. Fail-soft still protects the pane/mux capabilities (a missing `herdr`
never blocks the merge gate). The spawn lanes wrap their finalized model as
`MODEL="$(herd_model_for_spawn "$MODEL")" || exit 1`; the driver shims (`herd_driver_start_agent` /
`herd_driver_launch_agent`) resolve centrally so every routed lane is covered.

An advisory **suggestions catalog** (`templates/models.tsv`, browsable via `herd config models`) backs
`herd config set MODEL_*` with a tier/role-fit hint; it never refuses a model. `cost.sh` surfaces an
unknown/foreign model as an explicit `unpriced` marker rather than a silent `$0`. Proof:
`tests/test-model-matrix.sh`.

---

## HERD-177: portability guardrails — the no-new-hardcoded-claude lint + the stub proof driver

The epic above factors the claude-specific exec surface into the `.driver` files and routes it through
`scripts/herd/driver.sh` **incrementally** (P1 audited, P3 routed the one-shot drainers, P2/P4+ pending).
Two things were missing to make that portability real rather than aspirational, and to *keep* it real as
the tree evolves: a **ratchet** that stops the engine from re-growing hardcoded `claude`, and a concrete
**non-Claude driver** that exercises the seam end-to-end. HERD-177 ships both. They **unblock HERD-178**
(the real `codex` / `grok` drivers), which is now purely a matter of dropping in `.driver` files.

### P5 — the `no-new-hardcoded-claude` lint (`.herd/claude-hardcode-lint.sh`)

A dogfood gate (a sibling of the leak-guard / caps-sync / daemon-hermeticity gates in
`.herd/healthcheck.project.sh`, which the healthcheck runs as section 6). It scans the **engine tree** —
`scripts/herd/*.sh` (top level only, so the driver seam `driver.sh`, the `sim/` sandbox scripts and
`backends/` are out) plus `bin/herd` — for any non-comment line that **invokes** `claude` (or carries a
claude-specific incantation). Each such line is fingerprinted `<relpath>\t<whitespace-collapsed line>`
and diffed against the committed baseline `.herd/claude-hardcode-baseline.tsv`. A fingerprint **absent**
from the baseline is a NEW hardcoded `claude` outside the seam → the lint fails, naming `file:line`.

- **Where hardcoded `claude` is legitimate (never scanned):** the driver seam — `templates/drivers/*.driver`
  (where `claude` is *data*, the command shape a driver binds), `scripts/herd/driver.sh` (the ONE runtime
  shim that names the default runtime so everything else routes through it), and the P1 audit table above
  (the grandfathered un-routed sites, carried in the baseline until the routing phases retire them).
- **Why a baseline, not zero:** routing is incremental; many audited sites are still un-routed by design.
  The ratchet lets the count only ever go **down** as sites are routed (drop the baseline row), while
  blocking any **new** one — the actual invariant. Line *numbers* are not part of the fingerprint, so
  moving an existing invocation is not a false new-site; a routed-and-removed site is advisory (regen to
  tighten), never a red. **Fail-soft** on its own infra (missing baseline / no engine tree → tolerated
  ⚠️, exit 2), never a false red. Proof: `tests/test-claude-hardcode-lint.sh` (incl. a planted-invocation
  catch and the seam-exemption negative control).

### P6 — the stub proof driver (`templates/drivers/stub.driver`) + the runtime exec seam

The render-time seam already swaps a non-herdr **multiplexer** (phase 2, `test-driver-abstraction.sh`
§5). What was unproven is a non-Claude **runtime** flowing through the *runtime* shim. HERD-177 closes it:

1. **`stub.driver`** — a COMPLETE, non-herdr, **non-Claude** proof driver (mux = a fictional `stubmux`,
   runtime = a fictional `stub-agent`). Every tokenized mux `DRIVER_*` key is bound (so `herd render`
   with `HERD_DRIVER=stub` produces a valid coordinator skill and the completeness lint passes), and
   every `DRIVER_AGENT_*` exec class names `stub-agent`, **never `claude`**. It is a PROOF/REFERENCE
   driver, not a production runtime.
2. **The runtime exec seam consumes the driver's exec binding.** It reuses HERD-149's
   `herd_driver_agent_value <KEY> [default]` (a PURE grep-read of the active driver's `DRIVER_AGENT_*`
   value — no sourcing, fail-soft `<default>` on a missing file/key) and adds `herd_driver_agent_runtime`
   on top (the runtime executable = the first token of `DRIVER_AGENT_ONESHOT_EXEC`, else
   `INTERACTIVE_SPAWN`, else empty). `herd_driver_oneshot_exec` now runs **that** runtime: `stub-agent -p …`
   under `HERD_DRIVER=stub` (and `codex`/`grok` for those drivers), the drift-guarded byte-identical
   `claude -p …` literal for the default/claude case.
3. **Absent-binding degradation.** A driver that omits an exec binding (or a missing driver file) yields
   an empty runtime → the seam degrades to the default `claude` and **never crashes** under
   `set -euo pipefail`. This is the graceful-degradation guarantee a partial third-party driver relies on.

Proof: `tests/test-stub-driver.sh` — parse/zero-secret/non-claude, `HERD_DRIVER=stub` render + mux swap,
the one-shot seam running `stub-agent` end-to-end, the byte-identical claude default, and absent-binding
degradation. `main` stays GREEN: every existing driver/exec test (`test-driver-agent-exec.sh`,
`test-oneshot-exec-seam.sh`, `test-driver-abstraction.sh`, `test-model-matrix.sh`, `test-headless-driver.sh`)
is unchanged because the default path is byte-identical.
