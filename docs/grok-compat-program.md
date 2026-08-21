# The Grok Build compatibility program (HERD-782)

The committed evidence doc for the **Full Grok Build coordinator compatibility** epic (HERD-782):
running the whole governed herdkit lifecycle with xAI's Grok Build CLI replacing Claude at the runtime
seam. This is the seat-of-evidence doc the epic's children (HERD-800…805) cite — what was empirically
observed against the real binary, what is proven live, and what is honestly deferred.

Every claim below was verified against the tree and the installed binary on **2026-08-21**. Where this
doc and a live probe disagree, the probe wins — run `herd doctor --runtime-conformance --probe` to
re-establish the evidence against the binary you actually have. `templates/capabilities.tsv` remains
the source of truth for commands and config keys.

## The seat: what is installed, and its auth state

| fact | observed value |
| --- | --- |
| binary path | `~/.local/bin/grok` → `~/.grok/bin/grok` (symlink) |
| version | `grok 1.0.5 (5115b46bc909)` |
| authentication | **NOT authenticated** — `grok models` prints `You are not authenticated.` |
| default model | `grok-4.6` |
| available models | `grok-4.6` (default), `grok-4.5` |

**Signing in is the one human step this program cannot self-serve.** `grok login` (browser) or `grok
login --device-code` / `XAI_API_KEY` are the documented paths; the coordinator must not attempt them.
Until a machine is signed in, every capability that needs a *completed model turn* stays deferred — but
a large amount is still verifiable authless (below), which is what this phase's live probes exploit.

The earlier "grok is not installed on this machine" notes in `scripts/herd/runtime-conformance.sh` and
`templates/drivers/grok.driver` were written when that was true; they are now **stale** and have been
corrected by this change.

## Ground truth: the headless surface (from `grok --help`, 1.0.5)

Confirmed flags/subcommands, observed directly (not inferred from an older docs page):

- `-p, --single <PROMPT>` — single-turn headless prompt, prints the response and exits (the `claude -p`
  analog). `--prompt-file` / `--prompt-json` are file/JSON variants.
- `--output-format {plain | json | streaming-json | streaming-messages-json}` (default `plain`):
  - `json` — one JSON object at the end (`{"type":"error","message":…}` on failure).
  - `streaming-json` — NDJSON of the agent-native **ACP** session updates.
  - **`streaming-messages-json` — NDJSON in the *Anthropic Messages API wire format*.** This is what the
    exec adapter parses: a documented, stable wire contract rather than a schema invented here.
  - `--include-partial-messages` adds incremental `stream_event` deltas (only affects
    `streaming-messages-json`).
- `--json-schema <SCHEMA>` — constrains structured output (implies `--output-format json`).
- `--permission-mode {default | acceptEdits | auto | dontAsk | bypassPermissions | plan}` and
  `--always-approve` (alias `--yolo`) — the tool-permission surface.
- `--rules <TEXT>` — extra rules appended to the system prompt. `--cwd <DIR>` sets the working dir.
- `-c/--continue`, `-r/--resume [<ID>]`, `-s/--session-id <UUID>`, `--fork-session` — session control.
- `--agent <NAME>` — select an agent definition by name.
- subcommands: `login`, `logout`, `models`, `inspect`, `sessions`, `agent` (headless relay), `doctor`,
  `plugin`, `memory`, `mcp`, `update`, …

## Observed wire format: `--output-format streaming-messages-json`

Captured live (unauthenticated) from `grok -p "…" --output-format streaming-messages-json --model
grok-4.6 --permission-mode acceptEdits --cwd <dir>` — two NDJSON lines, byte-for-byte the fixture frozen
in `tests/test-grok-exec-adapter.sh`:

```
{"type":"system","subtype":"init","session_id":"","apiKeySource":"user","model":"unknown",
 "cwd":"","permissionMode":"default","tools":[],"slash_commands":[],"mcp_servers":[],"skills":[],"uuid":"…"}
{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":0,"num_turns":0,
 "stop_reason":null,"total_cost_usd":0.0,"usage":{"input_tokens":0,"output_tokens":0,
 "cache_read_input_tokens":0,"cache_creation_input_tokens":0,"server_tool_use":{…}},"modelUsage":{},
 "errors":["Not signed in. …"],"session_id":"","uuid":"…"}
```

This is the Claude-Code stream-json envelope. Top-level `.type` values, and how the adapter folds them:

| `.type` | meaning | adapter state |
| --- | --- | --- |
| `system` (`subtype:init`) | session preamble — one, first; carries `session_id`, `model`, `cwd` | `starting` |
| `assistant` | a model message, Anthropic Messages wire shape; final reply text lives in `.message.content[].text` | `working` |
| `user` | a tool-result turn (when tools run) | `working` |
| `stream_event` | incremental delta (only with `--include-partial-messages`) | `working` |
| `result` | **THE terminal record** — `is_error` / `subtype` decide success | `completed` iff `is_error==false` |
| `error` | a top-level protocol error (the `json` format's failure shape) | `failed` |

Unlike codex (distinct `turn.completed` / `turn.failed` types), grok emits ONE `result` whose
`is_error` field is authoritative. Process exit code observed: `0` on a signed-in success, `1` on a
runtime failure (e.g. not-signed-in), **`2` on an argv/usage rejection** (a bad flag, before any
envelope) — the last is what makes flag-drift detectable.

> jq gotcha, recorded so it is not re-introduced: `$result.is_error // null` falls through on `false`
> as well as null, silently turning a real `is_error:false` (a SUCCESS) into null. The adapter indexes
> `.is_error` directly instead.

## What is proven LIVE (authless), and how

`scripts/herd/grok-exec-adapter.sh` (HERD-800) wraps one bounded turn: `grok -p <prompt>
--output-format streaming-messages-json --cwd <workdir> --permission-mode acceptEdits [--model …]`,
stdin closed, returning a normalized typed object. It NEVER passes `--always-approve` /
`--permission-mode bypassPermissions` (the isolation contract), and directory-scopes on `--cwd` (a
`--sandbox` profile name is deliberately NOT guessed — grok's profile names are undocumented on
`--help` and unobservable on this unauthenticated binary).

`scripts/herd/runtime-conformance.sh` turns grok's former single deferred row into **four authless,
version-keyed live probes** (surfaced by `herd doctor --runtime-conformance`):

| probe | asserts | result on this seat |
| --- | --- | --- |
| `grok-argv` | the adapter's exact invocation is accepted (init envelope emits, not an argv/usage rejection) — guards a relied-on flag being renamed/removed | ✓ pass |
| `grok-structured-output` | the exec adapter parses grok's real `streaming-messages-json` into a typed object with a terminal `result` envelope (wire FORMAT) | ✓ pass |
| `grok-rules-discovery` | `grok inspect` lists a project `AGENTS.md` as a project instruction (positive) while an empty project reports none (negative control) | ✓ pass |
| `grok-agent-discovery` | `grok inspect` lists a project-scope `.grok/agents` definition by name (positive) with a unique-name negative control | ✓ pass |

All four pass on the installed-but-unauthenticated binary because none needs a completed model turn.

### Finding: `.grok/agents` project scope changed since 1.0.3

`templates/drivers/grok.driver`'s roster notes come from a grok **1.0.3** hand-prototype and state that
a repo-local `./.grok/agents/` is IGNORED (only `~/.grok/agents` honored — the reason `DEFINITION_MODE`
is `install`). On **1.0.5**, `grok inspect` **does** surface a repo-local `./.grok/agents/<name>.md` as a
`project`-scope agent (proven by `grok-agent-discovery`). This is a real portability change. It is a
*discovery* observation only — whether `--agent <name>` then SELECTS and lets that definition GOVERN a
turn needs an authenticated run, so the driver's `DEFINITION_MODE=install` binding is left unchanged
here and the selection/governance question is carried by HERD-802 (interactive parity, needs auth).

## What is DEFERRED (honestly, not guessed)

Declared as `deferred` rows that print on every report — never omitted, never guessed:

- **`grok-exec-turn`** — a real turn run to COMPLETION with a real reply + session identity. Needs an
  **authenticated** grok. The wire FORMAT is already proven by `grok-structured-output`; only completion
  waits on `grok login`.
- **`grok-session-resume`** — `-c/--continue`, `-r/--resume` are documented but cannot be exercised
  unauthenticated, and nothing here holds a live session to re-enter (a later HERD-782 phase).
- **`grok-steering` / `grok-interruption`** — need durable app-server/leader coordination; a bounded
  one-shot can only be killed (a later HERD-782 phase).

## For the child items (HERD-801…805)

- **HERD-801** (runtime switch grok): the model roles are grounded — default `grok-4.6`, secondary
  `grok-4.5`; the exec surface is in `templates/drivers/grok.driver`.
- **HERD-802** (herdr interactive parity): resolves the `--agent`/`DEFINITION_MODE` selection+governance
  question this doc leaves open (needs a signed-in binary).
- **HERD-803** (refix bounce + wake proof): the exec adapter's `state`/`state_reason` vocabulary is the
  machine-readable turn outcome to build wake-proof on.
- **HERD-804** (gate proof / live disposable PR): the first item that genuinely needs `grok login`; the
  authless probes here are the pre-flight it can rely on.
- **HERD-805** (docs + skill templates): fold the streaming-messages-json accuracy and the
  installed-binary surface above into `README.md` / `docs/driver-abstraction.md`.

Once a machine is signed in, re-run `herd doctor --runtime-conformance --probe` — `grok-exec-turn`
becomes runnable and the deferred row upgrades to a real version-keyed pass.
