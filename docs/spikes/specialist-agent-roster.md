# Specialist agent roster — evidence + per-runtime matrix

> Epic **HERD-666**. This child (**HERD-667**) ships the definitions, the `herd agents` CLI, the
> driver bindings and lane selection. The read-only control-room pane is child 2 (**HERD-668**).
> Committed as the epic's evidence doc: what was prototyped by hand, the two traps that prototype
> surfaced, and the pre-audit of what each runtime actually does.

## 1. Where this came from: the emberglen 9-agent prototype

The idea was proven by hand, outside the engine, on **emberglen-godot**: nine domain agents (one per
subsystem) authored as markdown definitions and pointed at that project's builders. It worked — a
builder carrying a domain definition made materially fewer domain mistakes than a generic one — but
it worked *only* on the machine where it had been hand-installed, and only for the one runtime it had
been hand-tuned against. Two failure modes showed up almost immediately, and they are the reason this
is an engine feature with an empirical verifier rather than a documented convention.

## 2. The two traps

### T1 — user scope vs repo scope

A runtime may resolve agent definitions from a **USER-scope** directory and ignore a repo-local copy
entirely. Verified on grok 1.0.3: `~/.grok/agents/` is honored; a repo-local `./.grok/agents/` is
not read at all.

The consequence is that *committing* definitions is necessary but not sufficient. The committed
source is the reviewable artifact (it belongs in the repo, in version control, in the PR that changes
it); the runtime needs a copy where it actually looks. So **publishing is load-bearing**, and it is a
first-class command:

```
herd agents install     # publish .herd/agents/*.md → the active driver's real lookup path
```

`install` is a clean no-op where nothing needs publishing (a native repo-scope runtime, or a runtime
with no lookup path at all), so it is safe to run everywhere and the operator never has to know which
case they are in.

### T2 — silent fallback on an unknown name

An **unknown agent name is silently ignored**. The runtime does not error, does not warn, and does
not exit non-zero: it simply runs as a plain builder. The *only* symptom is the agent making exactly
the mistakes its definition forbids — a signal no rail can read and a human only notices in hindsight.

This is what makes a naive verifier worthless. "Did the spawn succeed?" is always yes. "Did the
output look reasonable?" is always yes. A check that cannot fail proves nothing.

So `herd agents verify` is **empirical and two-sided**:

| half | what it does | what it proves |
|---|---|---|
| positive | select the definition (by name where the runtime has a selector; by injecting its body where it does not) and ask for the `sentinel:` value from its frontmatter — a string that exists **only** inside that definition | the definition reached the model |
| negative control | run the same probe against a name that provably does not exist | the probe is *able* to fail — if this also returns the sentinel, the check cannot discriminate |

Verdicts: `ok` · `unresolved` (positive produced no sentinel — trap T2 caught in the act) ·
`indeterminate` (the negative control passed too, so the probe proves nothing) · `no-sentinel` (the
definition declares none, so nothing empirical can be asserted) · `unverified` (the runtime binary is
not present on this machine).

Verdicts cache by **(driver, definition sha)** in the worktree pool, so editing a definition
invalidates its own verdict with no explicit cache-busting, and `herd doctor` can report roster state
from the cache without spawning anything. `herd doctor --probe` re-runs the probe live.

## 3. Pre-audit — what each runtime actually does (2026-08-12, this machine)

| runtime | definition dir | by-name selector | mode | how it was established |
|---|---|---|---|---|
| **claude 2.1.229** (`herdr-claude`, `headless`) | `.claude/agents/*.md`, **repo scope** | none | ~~`native`~~ **`inject`** — see § 3a | verified on this machine |
| **codex 0.147.0** | ~~none~~ `.codex/agents/*.toml`, **repo scope** | none | `inject` — see § 3b | verified on this machine |
| **grok 1.0.3** | `~/.grok/agents/`, **user scope** | `--agent <name>` | `install` | **verified by report** — grok is not installed here |
| **stub** (proof driver) | `$HOME/.stub-agent/agents` | `--agent <name>` | `install` | the hermetic test vehicle |

### 3a. Correction (2026-08-13, HERD-729): claude's mode was `native`, and that was wrong

The 2026-08-12 pre-audit called claude `native` on a true-but-insufficient fact: claude 2.1.229 does
read `.claude/agents/*.md` with no publishing step. What the pre-audit missed is *what kind of
reading* that is. `.claude/agents/*.md` defines **subagent types for Claude Code's own Agent/Task
tool** — delegated to at the orchestrating model's discretion, inside an interactive/harness session.
It is not, and was never, a mechanism for loading a definition as the **main session's own persona**
for a detached `claude -p` oneshot. A lane spawn (`herd-feature.sh` / `herd-quick.sh` under
`HERD_AGENT=<name>`) needs the LATTER — the whole build governed by the specialist's rules — and a
top-level oneshot never automatically invokes a same-named subagent just because a file with that
name happens to sit in `.claude/agents/`.

This surfaced from real use, not a re-audit: HERD-729 was grounded live when `herd agents install`
published `docs-gardener` + `engine-rails` to `.claude/agents/` (mode said `native`, "nothing to
publish needed" — true, and irrelevant) and `herd agents verify docs-gardener` still reported
`unresolved`, while `engine-rails` reported `ok`. The `ok`/`unresolved` split turned out to be
ordinary probe-timeout flakiness on a long injected definition (fixed by raising
`HERD_AGENT_VERIFY_TIMEOUT` and retrying once on an empty probe result — see
`scripts/herd/agents.sh`), not a mechanism difference; both agents were always resolving through
**inject**, because `herd_roster_probe_kind` was already independent of `DEFINITION_MODE` and had
already resolved to `inject` for claude (no by-name selector — see § 5). The `native` *label* was
simply asserting a fact that, while true, never mattered: nothing in the roster's actual resolution
path — not `verify`, not a lane spawn — ever reads `.claude/agents/*.md` for HERD_AGENT's purpose.
`templates/drivers/herdr-claude.driver` and `headless.driver` now bind
`DRIVER_AGENT_DEFINITION_MODE=inject`, so the field agrees with the mechanism in use, and
`herd agents install` correctly reports "nothing to publish" for these drivers instead of copying
files nothing reads for this purpose. `DRIVER_AGENT_DEFINITION_DIR` stays bound — the fact itself is
still true and may matter for a future Task-tool-delegation capability — only `DEFINITION_MODE`
changed.

### 3b. Correction (2026-08-18, HERD-761, epic HERD-754 step 5): codex's dir was `none`, and that was wrong too

HERD-754 itself flagged the 2026-08-12 pre-audit as stale: "templates/drivers/codex.driver records
Codex 0.147.0 as having no native project agent-definition surface, while current Codex documentation
supports project-scoped custom agents under `.codex/agents/*.toml`." Re-verified live against the real
binary (`/opt/homebrew/bin/codex`, codex-cli 0.147.0) rather than trusting either the ticket's claim or
the driver's own prior audit:

- **`.codex/agents/*.toml` is real and natively parsed — the pre-audit's "no dir" was wrong.**
  Dropping a deliberately incomplete file there (`name` + `description`, no `developer_instructions`)
  makes a plain `codex exec` turn in that workdir emit `Ignoring malformed agent role definition:
  agent role file at <path> must define `developer_instructions`` — codex only produces that message
  for a file it opened and tried to deserialize as an "agent role", so the directory is genuinely
  scanned at startup, not absent. (`sentinel` is not a recognized field either — an early probe with
  one got `unknown field `sentinel`` — the real, minimal valid shape is `name` + `description` +
  `developer_instructions`, discovered by trial against the deserializer's own error messages, the
  same "researched, not guessed" discipline the rest of this file's flags follow.)
- **A by-name selector is still genuinely absent — the pre-audit's "no selector" was right.**
  `codex exec --agent probe ...` fails immediately with clap's own `error: unexpected argument
  '--agent' found`; neither `codex --help` nor `codex exec --help` lists one, and a string search of
  the compiled binary for `--agent`/`agent_name`-shaped CLI flags found none.
- **The directory is real but irrelevant to what HERD_AGENT needs — the exact T3 shape § 3a already
  found for claude.** codex ships `multi_agent`/`multi_agent_v2` feature flags and
  `SubagentStart`/`SubagentStop` hook event types (`codex features list`, and strings in the compiled
  binary), consistent with `.codex/agents/*.toml` defining SUBAGENT roles codex's own internal
  multi-agent machinery may dispatch to — never a MAIN session's own persona. Verified live: a fully
  valid `.codex/agents/probe.toml` (unique sentinel in `developer_instructions`) produced **zero**
  effect on a bare `codex exec` oneshot turn asked for that sentinel — it answered `NO-SENTINEL`,
  exactly as if the file were not there. The roster's inject fallback was verified the same way, in
  the same session: the SAME sentinel, delivered via `herd_roster_lane_spec_block`'s real injected
  block instead, came back correctly. `tests/test-codex-agent-roster-live.sh` is the automated,
  skip-if-`codex`-absent proof of both halves.

So `DRIVER_AGENT_DEFINITION_DIR` moves from `@degrade:no-agent-definition-lookup-path-codex-0.147.0`
to the real `.codex/agents` (mirroring claude's real-dir-but-inject-mode shape exactly), and
`DRIVER_AGENT_SELECT_FLAG`'s `@degrade:` reason text is corrected to name the flag that is actually
missing rather than the directory that, it turns out, is not. `DEFINITION_MODE` does not change: it
was already `inject`, and re-verifying the runtime only confirmed that was the right mechanism all
along — this correction is about `DEFINITION_DIR`'s *honesty*, not about which mechanism a lane uses.

Notes that matter for the bindings:

- **claude also has an `--agents <json>` spawn flag.** It passes *inline* definitions rather than
  naming one from the definition dir, so it is not a by-name selector and is not what the roster
  binds. The definition **dir** is the primary path (it needs no argv surgery and works for a TUI
  spawn as well as a headless one). `--agents` is noted here as the known alternative if a future
  need — e.g. passing a definition that is not on disk — makes it the better seam.
- **codex has a real `.codex/agents/*.toml` dir but no named-agent selection** — see § 3b. This is
  why prompt injection is built as the first-class portable fallback rather than a degraded path: it
  is the one mechanism that works on *any* runtime, including one whose vendor's native definition
  surface (real or not) does not reach the main session. On codex the lane prepends the definition
  body to the task spec, and this is verified live in `tests/test-codex-agent-roster-live.sh` —
  positive: body injected, sentinel returns; negative control: `.codex/agents/*.toml` alone, with no
  injection, sentinel must not return.
- **grok is not installed on this machine.** Its bindings ship **verified-by-report**, marked with
  the drivers' existing `@degrade:` convention for anything that was *not* reported, and
  `herd agents verify` fail-softs to `unverified — grok binary not present on this machine` rather
  than a red row. Post-merge live verification on a grok-equipped machine is owned by the second
  operator (operator decision, 2026-08-12).
- **Every driver already binds `DRIVER_AGENT_ONESHOT_EXEC`, but the shared verify helper's use of it
  is BROKEN for codex (found 2026-08-18, HERD-761, not fixed here — out of this ticket's scope).**
  `herd_driver_oneshot_exec_as` (`scripts/herd/driver.sh`) does not actually compose from a driver's
  `DRIVER_AGENT_ONESHOT_EXEC` template; it extracts only the runtime binary name and then hardcodes
  claude's own shape, `"$_rt" -p "$prompt" --model "$model" "$@"`. That shape happens to match
  herdr-claude/headless/grok/stub's bindings (`<bin> -p "<prompt>" --model <model> …`) but NOT codex's
  real one (`codex exec --model <model> --dangerously-bypass-approvals-and-sandbox "<prompt>"` — no
  `-p` at all). Reproduced live: `codex -p "hello there" --model gpt-5.1-codex
  --dangerously-bypass-approvals-and-sandbox` fails immediately with `error: invalid value 'hello
  there' for '--profile <CONFIG_PROFILE_V2>'` — codex's top-level `-p` means `--profile`, a completely
  different flag, so the "prompt" is consumed as a profile name and the real prompt is dropped. This
  means `herd agents verify`/`herd doctor --probe`/`herd advise`/the review panel's codex dispatch are
  all currently non-functional for codex specifically (every other shipped driver is unaffected — see
  the audit for the `-p`-shaped bindings above). `tests/test-codex-agent-roster-live.sh` therefore
  proves the roster's inject mechanism directly (composing the real `codex exec --model … "<prompt>"`
  shape itself, matching `DRIVER_AGENT_ONESHOT_EXEC`'s own documented incantation) rather than through
  `herd_roster_verify`/`herd_driver_oneshot_exec_as`, which would currently misreport it as
  `unresolved`. Filed via `herd note` for the coordinator; fixing the shared composer to actually
  read/substitute each driver's `DRIVER_AGENT_ONESHOT_EXEC` template (the way
  `herd_driver_agent_spawn_argv` already does for `DRIVER_AGENT_INTERACTIVE_SPAWN`) is cross-cutting
  work outside HERD-761's roster-binding scope.

## 4. What HERD-667 ships

1. **Committed definitions** — `.herd/agents/<name>.md`: frontmatter `name` / `description` /
   `sentinel`, body = the system prompt. Scaffolded from `templates/agent-definition.md.tmpl`.
2. **`herd agents`** (`scripts/herd/agents.sh`) — `list` (roster + the active driver's cached
   resolution state, definition mode and lookup path), `new`, `show`, `install`, `verify`.
3. **Three driver bindings** on every shipped driver — `DRIVER_AGENT_DEFINITION_DIR`,
   `DRIVER_AGENT_SELECT_FLAG`, `DRIVER_AGENT_DEFINITION_MODE`. A driver missing them (an out-of-tree
   runtime) degrades to `inject`, never a red row.
4. **Lane selection** — `HERD_AGENT=<name>` on `herd-feature.sh` / `herd-quick.sh` / `spawn.sh`
   (which threads it through the durable queue's `.agent` sidecar to the watcher's drain). Set and
   supported ⇒ the select flag is appended to the spawn `<flags>` (which the spawn composer already
   word-splits into the argv) or the body is injected into the task spec. A name the verify cache
   says does not resolve prints a **loud warning and spawns anyway** — never a block. Unset ⇒ a
   byte-identical spawn argv and task spec, asserted by `tests/test-agent-roster.sh`.

## 5. Design decisions worth recording

- **The sentinel lives in the definition, not in the verifier.** A verifier-side secret would prove
  the verifier ran, not that the definition reached the model. Putting it in the frontmatter — and
  scaffolding it in by default — is what makes the positive half meaningful.
- **`probe kind` is independent of `definition mode`.** claude has a native repo-scope definition dir
  *and* no by-name spawn selector, so the lane injects and `verify` probes the injection path. The
  rule is "probe the mechanism the LANE would actually use", not "probe the mechanism the vendor
  advertises".
- **Never blocking.** Every failure mode — no definition, unresolved, indeterminate, no runtime
  binary, an unwritable cache — degrades to a note or a warning. A specialist agent is an aid; the
  build ships either way. The one thing that is never allowed is *silence*, which is precisely what
  trap T2 hands you by default.
