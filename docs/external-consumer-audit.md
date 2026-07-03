# External-consumer abstraction audit (Phase 4)

**Backlog item:** *Phase 4: onboard an external consumer.*
**Method:** a **synthetic-repo abstraction audit** — not a real external repo. We build a throwaway,
deterministic, **non-herdkit** fixture (a tiny Go HTTP server — the maximally-different stack from
herdkit's own bash + Python) and run the real init/scout/config-render/healthcheck logic against it,
so every place herdkit leaks its *own* assumptions onto a generic consumer surfaces safely against a
disposable target instead of someone's production repo.

This is a **doc + throwaway-fixture deliverable only.** It does **not** modify the engine to fix any
leak; each fix is a ranked follow-up backlog item at the end. (Per the task and AGENTS.md, the
coordinator owns the backlog — the follow-ups below are proposed, not filed.)

## The rig (reproduce it yourself)

Everything below is reproduced live by a hermetic probe — no network, no herdr panes, no model call,
no `herd doctor` gate. It reuses the sandbox-sim P0 fixture conventions under `scripts/herd/sim/`
(pinned git identity → byte-identical HEAD sha, ownership-marker refuse-to-clobber guard).

```sh
# Build the synthetic Go consumer fixture (deterministic; prints a stable HEAD sha):
bash scripts/herd/sim/external-consumer-fixture.sh /tmp/ext-consumer

# Drive the REAL scout / `herd render` / healthcheck.sh against it and emit a leak scorecard:
bash scripts/herd/sim/external-consumer-probe.sh --artifacts /tmp/ext-probe
cat /tmp/ext-probe/scorecard.json      # → result: "leaks-confirmed", leaks: 5

# Hermetic test (determinism + every documented leak reproduces + the headline gate leak, directly):
bash tests/test-external-consumer-audit.sh
```

The fixture is a conventional Go project — `go.mod`, `cmd/greetd/main.go`, `internal/greet/…` — with
**no** `BACKLOG.md`, **no** `app/` dir, **no** `.herd/`, **no** Python/`.venv`/Streamlit. That
"shares none of herdkit's assumptions" property is exactly what makes the leaks visible.

Probes marked **🔴 live** below are asserted by `external-consumer-probe.sh`; the rest are found by
reading the engine against the fixture (no code path silently green-lights them, so they're asserted
by inspection rather than execution).

---

## Leaks

Grouped by subsystem. Each: **file:line · what leaks · why it breaks a generic consumer · suggested
fix.** Line numbers are against this branch's tree.

### A. The dependency doctor hard-requires herdkit's own toolchain

`herd init` runs `herd_doctor` FIRST and **hard-gates** on it (`bin/herd:307-309`) before writing any
config — so a consumer that fails the doctor cannot initialize at all.

- **`scripts/herd/herd-preflight.sh:237`** — `for tool in git gh claude python3 herdr` marks
  **`herdr`, `claude`, and `python3` as HARD-required.**
  *What leaks:* herdkit's own runtime — the `herdr` pane multiplexer, the Claude Code CLI, and a
  Python 3 interpreter.
  *Why it breaks a generic consumer:* a Go / Rust / Java shop has none of these. They installed
  herdkit to get a *workflow*, and are blocked at the very first step unless they also install a
  bespoke terminal multiplexer, the Anthropic CLI, and Python — none of which their own project uses.
  *Fix:* split the dependency tiers by what the invoked command actually needs. `git`/`gh` are truly
  required; `herdr` is only needed to launch the control room (`coordinator.sh`), `claude` only when
  a lane spawns an agent, `python3` only for the JSON/UTF-8 helpers. Gate `herd init` on the
  minimal set; degrade the rest to warnings or check them lazily at the point of use.

- **`scripts/herd/herd-preflight.sh:203-215,259-275`** — the `python3` UTF-8 / cp1252 probe that
  prints 🐑 (U+1F411, herdkit's own pane-label emoji) and **hard-fails** (`hard_fail=1`, line 273)
  when Python can't encode it on Windows.
  *What leaks:* an entirely herdkit-internal concern — *herdkit's* emoji pane labels and box-drawing
  console — imposed as a hard dependency on the consumer.
  *Why it breaks a generic consumer:* a Go project that never renders a sheep-labelled pane is still
  failed on a Windows box whose Python defaults to cp1252.
  *Fix:* make this probe conditional on `herdr` actually being the chosen driver, not a universal
  init gate.

- **`scripts/herd/herd-preflight.sh:31,119,138,192,269`** — user-facing diagnostics hardwire the
  literal word **"herdkit"** ("the terminal/agent multiplexer herdkit drives", "herdkit exports
  PYTHONUTF8=1", etc.).
  *Why it breaks a generic consumer:* a team branding their own workflow sees "herdkit" leaking
  through their own doctor output. *Fix:* parameterize the tool/brand name (or drop it from copy).

### B. The healthcheck presumes a Python / Streamlit / `app/`-dir project

- **`scripts/herd/healthcheck.sh:114-153`** (`run_light`) — **🔴 live.** The light profile (the gate
  a consumer gets when `HEALTHCHECK_CMD` is unset) only ever syntax-checks **`*.sh` and `*.py`.**
  *What leaks:* the assumption that "code" means shell or Python.
  *Why it breaks a generic consumer:* a change that touches only `.go` (or `.rs`, `.java`, `.ts`)
  files gets **zero** real checking and is reported **`✅ light clean — 0 sh, 0 py ok` (exit 0).**
  The probe breaks a real `.go` source and watches the gate green-light it — a **silent-green
  correctness hazard**: broken code sails through the pre-merge gate. (The control in the test proves
  an equivalent broken `.sh` *is* caught — so the gate works; the gap is purely stack-specific.)
  *Fix:* either add per-language syntax probes keyed off scout's detected `lang` (e.g. `go vet` /
  `gofmt -l`, `cargo check`, `tsc --noEmit`), or — safer as a default — make the light profile
  **flag-the-absence** (a loud one-line `⚠️`, like the interaction gate already does) instead of
  emitting a confident `✅ clean` for files it cannot actually check.

- **`templates/healthcheck.project.sh:22-32`** — the example heavy command a consumer is told to copy
  runs `$PY -m py_compile app/*.py` with `PY="./.venv/bin/python"` and `pytest -q tests`.
  *What leaks:* a Python venv, an `app/*.py` source layout, and pytest.
  *Why it breaks a generic consumer:* a Go/Rust consumer copying the "example project healthcheck"
  gets a Python script that matches nothing in their repo. (A `templates/healthcheck.node.sh` exists
  for Node — but nothing for Go/Rust/Java, and `herd init` doesn't pick a template by scouted lang.)
  *Fix:* ship per-language healthcheck templates and have `herd init` seed the one matching scout's
  `lang` (Go → `go test ./...`, Rust → `cargo test`, …).

- **`scripts/herd/healthcheck.sh:26-43` + `templates/capabilities.tsv:54`** — the interaction gate is
  documented in terms of **`st.testing.v1.AppTest`** (the Streamlit testing API) driving "widgets".
  *What leaks:* Streamlit as the assumed UI framework.
  *Why it breaks a generic consumer:* a Go HTTP service or a library has no widgets and no AppTest
  harness; the only concrete example the coordinator is fed is Streamlit-only. *Fix:* reword to a
  framework-neutral "drive an input, assert the dependent output changed," with non-Streamlit
  examples.

- **`templates/config.example:19-20` + `templates/capabilities.tsv:52-53`** — **🔴 live.** The
  documented defaults for `HEALTHCHECK_HEAVY_GLOB` and `APP_SURFACE_GLOB` are **`^app/`.**
  *What leaks:* an `app/` directory as the app surface.
  *Why it breaks a generic consumer:* Go uses `cmd/` + `internal/`; Rust uses `src/`; Maven uses
  `src/main/java`. `^app/` matches none of them — so the heavy profile and the interaction gate
  **silently never fire** for the consumer (the probe confirms `^app/` matches no Go path). *Fix:*
  leave these blank by default (a matching-nothing glob is worse than an empty one, which the engine
  already treats as "always heavy"), and suggest a value from scout's detected layout.

### C. The app-preview machinery presumes a Streamlit web server

- **`scripts/herd/app-monitor.sh:23`** — the preview server is launched as
  `$APP_PREVIEW_CMD --server.port "$PORT" --server.headless true`.
  *What leaks:* **Streamlit's exact CLI flags** are force-appended to whatever the consumer set.
  *Why it breaks a generic consumer:* `./greetd --server.headless true`, `cargo run --server.port …`,
  or `java -jar app.jar --server.headless true` are rejected by those binaries and **crash on
  launch.** (The comment suggests wrapping the port "inside your own APP_PREVIEW_CMD," but the flags
  are appended unconditionally regardless.) *Fix:* pass no framework flags by default; let
  `APP_PREVIEW_CMD` be the complete command, and offer an opt-in `APP_PREVIEW_PORT_FLAG` for
  frameworks that want the port injected.

- **`scripts/herd/app-monitor.sh:44-48`** — health is probed with `curl -s http://localhost:$PORT/`
  and rendered as 🟢 *serving* / an `http://localhost` URL.
  *What leaks:* the preview is an HTTP server answering `GET /` with 200.
  *Why it breaks a generic consumer:* a CLI tool, a library, a gRPC service, or a server with a
  non-root health path never shows "serving" — the pane sits permanently 🔴. *Fix:* make the probe
  configurable (health path / command), and treat "no probe configured" as "preview running, health
  unknown" rather than red.

- **`scripts/herd/herd-feature.sh:124,137` and `scripts/herd/herd-resolve.sh:71,84`** — the free-port
  search is `for p in range(8501, 8600)` with the message `No free port in 8501-8599`.
  *What leaks:* **Streamlit's default port block (8501+).**
  *Why it breaks a generic consumer:* a Go (`:8080`) / Node (`:3000`) / Rails (`:3000`) app is
  launched on an alien port unrelated to its own convention, and the health probe checks that same
  alien port. *Fix:* derive the port range from config (`APP_PREVIEW_PORT_BASE`) or the app's own
  convention.

### D. Scout detects the stack, but nothing downstream consumes the detection

- **`bin/herd:144-157`** (`scout_repo`) — **🔴 live.** Scout correctly classifies the fixture as
  `lang=go` (it also knows `rust`, `node`, `python`).
  *What leaks:* the *absence* of any Go/Rust-aware path after detection. Scout's `lang` is printed
  in the interview banner (`bin/herd:321`) and then **never used again** — no template is chosen by
  it, no healthcheck default, no glob, no light-profile syntax probe.
  *Why it breaks a generic consumer:* herdkit knows it's a Go repo and still hands the consumer
  Python/Streamlit defaults (leaks B, C). *Fix:* thread `lang` through to template/glob/healthcheck
  selection (the single highest-leverage fix — it powers B and C).

- **`bin/herd:549-562`** — **🔴 live.** When scout finds no `BACKLOG.md`/`TODO.md`/`ROADMAP.md`, init
  offers to **create a `BACKLOG.md` in herdkit's own `🔜 planned · 🚧 in progress · ✅ shipped`
  status-emoji format.**
  *What leaks:* herdkit's bespoke backlog format/vocabulary.
  *Why it breaks a generic consumer:* a team already using GitHub Issues or a plain README gets a new
  emoji-encoded markdown file in a format they never chose. (This is a soft leak — GitHub Issues is
  offered as option 2 — but the *default* presumes the herdkit file format.) *Fix:* keep offering it,
  but make the default backend follow scout's `tracker` signal (`.github/` present → GitHub Issues).

### E. Config defaults and copy point at herdkit's own repo and domain

- **`bin/herd:1301`** — the **runtime** fallback `: "${HERD_REPO:=briankeegan1/herdkit}"` inside
  `cmd_report` (distinct from the init-interview default at `bin/herd:445`).
  *What leaks:* the engine author's personal GitHub repo as the escalation target.
  *Why it breaks a generic consumer:* if a consumer never sets `HERD_REPO`, `herd report` **silently
  files their engine-bug escalations against `briankeegan1/herdkit`** — a stranger's repo — instead
  of erroring. *Fix:* drop the hardcoded fallback; when `HERD_REPO` is unset, `herd report` should
  refuse and tell the user to set it (or infer the consumer's own origin remote).

- **`scripts/herd/new-feature.sh:24-25` + `templates/capabilities.tsv:41`** — `SHARE_LINKS` is
  documented with the example `"data .venv"`.
  *What leaks:* a Python `.venv` and a `data/` dir.
  *Why it breaks a generic consumer:* the *mechanism* is stack-neutral, but the only guidance a
  Go/Rust consumer sees is Python-shaped. *Fix:* neutral examples (e.g. `node_modules target`).

- **`scripts/herd/herd-feature.sh:18`, `scripts/herd/herd-resolve.sh:19`,
  `scripts/herd/new-feature.sh:7`** — standalone usage examples use
  `dividend-history` / "Add a dividend income history tab."
  *What leaks:* herdkit's own finance-dashboard dogfood domain.
  *Why it breaks a generic consumer:* minor, but the usage docs a consumer reads are steeped in
  another project's domain. *Fix:* neutral slugs (`add-healthcheck`, `fix-parser`).

- **`README.md:42-47`, `plugin/README.md`, `plugin/.claude-plugin/plugin.json`** — onboarding
  hard-requires `herdr`/`claude`/`python3` and cites `github.com/briankeegan1/herdkit` as the
  canonical install source. Same root as A/E; noted for completeness.

### F. The rendered coordinator skill presumes herdr + Claude Code

- **`templates/coordinator.md.tmpl`** (rendered via `render_skill`, `bin/herd:78-141`) — **🔴 live.**
  The probe renders the real skill against a generic Go `.herd/config` and finds **25** references to
  `herdr` / `claude`: `herdr agent list`, `herdr pane run <builder-agent-pane> "/model …"`,
  `herdr agent focus <slug>`, mid-flight Claude Code `/model` switching, etc.
  *What leaks:* the herdr multiplexer as the control room and Claude Code as the agent runtime, baked
  into the consumer's own coordinator skill.
  *Why it breaks a generic consumer:* a team driving agents another way inherits a skill full of
  `herdr`/`claude` incantations that don't apply. *Fix:* factor the runtime-specific control
  commands behind a small indirection so the skill can render for a non-herdr / non-Claude driver
  (larger effort; tracked as a lower-priority follow-up).

---

## Ranked follow-up backlog items

Ranked by **impact × how-blocking**. (Proposed for the coordinator to file — this PR does not edit
`BACKLOG.md`.)

1. **[P0] Doctor: tier dependencies by what the command needs.** Stop hard-gating `herd init` on
   `herdr`/`claude`/`python3`; require only `git`/`gh`, check the rest lazily at point-of-use or as
   warnings. Unblocks onboarding for any non-herdkit stack. *(Leak A — `herd-preflight.sh:237`.)*

2. **[P0] Light healthcheck must not green-light unchecked languages.** A `.go`/`.rs`/`.java`-only
   diff currently passes as `✅ light clean` with exit 0. Add per-language syntax probes keyed off
   scout's `lang`, or make the light profile flag-the-absence (`⚠️`) for file types it cannot check
   instead of a confident `✅`. Closes a silent-green correctness hazard. *(Leak B —
   `healthcheck.sh:114-153`.)*

3. **[P1] Stack-aware init: thread scout's `lang` through to templates + globs + healthcheck.** Ship
   Go/Rust/Java healthcheck templates alongside the existing Python/Node ones and select by `lang`;
   default `HEALTHCHECK_HEAVY_GLOB`/`APP_SURFACE_GLOB` to blank (or a layout-derived value) instead
   of `^app/`. Single highest-leverage change — powers B and C. *(Leaks D, B — `bin/herd:144-157`,
   `config.example`, `capabilities.tsv:52-53`.)*

4. **[P1] App-preview: de-Streamlit the launch + probe.** Stop force-appending
   `--server.port/--server.headless` (crashes non-Streamlit commands); make the port range and the
   health probe (path/command) configurable; treat "no probe" as "health unknown," not red.
   *(Leak C — `app-monitor.sh:23,44`; `herd-feature.sh:124`; `herd-resolve.sh:71`.)*

5. **[P1] `HERD_REPO`: no silent `briankeegan1/herdkit` fallback.** `herd report` should refuse (or
   infer the consumer's own remote) when `HERD_REPO` is unset, so a consumer's engine-bug reports
   never leak to a stranger's repo. *(Leak E — `bin/herd:1301`.)*

6. **[P2] De-Streamlit / de-Python the docs & copy.** Neutralize the `st.testing.v1.AppTest`
   interaction-gate wording, the `.venv`/`data` SHARE_LINKS examples, and the `dividend-history`
   dogfood slugs across `capabilities.tsv`, `config.example`, `healthcheck.sh`, and the lanes.
   *(Leaks B, E.)*

7. **[P2] De-brand doctor / README / coordinator output.** Parameterize the literal "herdkit",
   🐑 emoji, and `briankeegan1/herdkit` install source so a consumer's own workflow name/brand shows
   through. *(Leaks A, E, F.)*

8. **[P3] Renderable coordinator skill for non-herdr / non-Claude drivers.** Factor the 25
   herdr/claude control incantations in `coordinator.md.tmpl` behind an indirection so the skill can
   render for another agent runtime. Largest effort, lowest urgency (herdr+Claude is the supported
   path today). *(Leak F — `coordinator.md.tmpl`.)*

---

## Deliverables in this PR

| File | Role |
| --- | --- |
| `docs/external-consumer-audit.md` | This audit (the deliverable). |
| `scripts/herd/sim/external-consumer-fixture.sh` | Deterministic synthetic **non-herdkit** Go consumer fixture (reuses the sandbox-sim P0 conventions). |
| `scripts/herd/sim/external-consumer-probe.sh` | Drives the real scout / `herd render` / healthcheck against the fixture; emits a leak scorecard. |
| `tests/test-external-consumer-audit.sh` | Hermetic test: determinism + every documented leak reproduces + the headline gate leak, directly. |

No engine file is modified. `bin/herd`, `agent-watch.sh`, the lanes, `coordinator.sh`,
`herd-review.sh`, `dep-watcher.sh`, and `layout-reconcile.sh` were **read only**, never edited.
