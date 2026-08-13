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
| **claude 2.1.229** (`herdr-claude`, `headless`) | `.claude/agents/*.md`, **repo scope** | none | `native` | verified on this machine |
| **codex 0.147.0** | none | none | `inject` | verified on this machine |
| **grok 1.0.3** | `~/.grok/agents/`, **user scope** | `--agent <name>` | `install` | **verified by report** — grok is not installed here |
| **stub** (proof driver) | `$HOME/.stub-agent/agents` | `--agent <name>` | `install` | the hermetic test vehicle |

Notes that matter for the bindings:

- **claude also has an `--agents <json>` spawn flag.** It passes *inline* definitions rather than
  naming one from the definition dir, so it is not a by-name selector and is not what the roster
  binds. The definition **dir** is the primary path (it needs no argv surgery and works for a TUI
  spawn as well as a headless one). `--agents` is noted here as the known alternative if a future
  need — e.g. passing a definition that is not on disk — makes it the better seam.
- **codex has no named-agent selection at all.** This is why prompt injection is built as the
  first-class portable fallback rather than a degraded path: it is the one mechanism that works on
  *any* runtime, including one whose vendor never ships the feature. On codex the lane prepends the
  definition body to the task spec, and `verify` probes exactly that mechanism — positive: body
  injected, sentinel returns; negative control: nothing injected, sentinel must not return.
- **grok is not installed on this machine.** Its bindings ship **verified-by-report**, marked with
  the drivers' existing `@degrade:` convention for anything that was *not* reported, and
  `herd agents verify` fail-softs to `unverified — grok binary not present on this machine` rather
  than a red row. Post-merge live verification on a grok-equipped machine is owned by the second
  operator (operator decision, 2026-08-12).
- **Every driver already binds `DRIVER_AGENT_ONESHOT_EXEC`**, which is the single seam the shared
  verify helper rides. That is why verification needed no new exec surface: it reuses
  `herd_driver_oneshot_exec_as`, the same one-shot path the advisor and the review panel use.

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
