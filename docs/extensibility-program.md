# The configurable-workflow program (HERD-275)

The committed evidence doc for the **configurable-workflow** epic. herdkit's long arc is a general
autonomous-operations engine, not only a coding co-pilot — which means an operator has to be able to
reshape the pipeline without editing engine code. This doc is the inventory: what already ships, what
is still missing, and in what order the gaps close.

Every file, config key and command named below was verified against the tree on 2026-07-10.
`templates/capabilities.tsv` is the source of truth for keys and commands; where this doc and the
manifest disagree, the manifest wins.

## Goal

A herdkit consumer can:

- **(a)** select or disable gate **policy** without touching code;
- **(b)** define their **own** gates;
- **(c)** swap agent **runtimes** (codex / grok / headless) per role;
- **(d)** export and import the whole **governance bundle**;
- **(e)** eventually run **non-PR-shaped** work units.

(a) through (d) ship today. (e) does not.

## Already there

### Gate policy as config

The whole merge stance is data. `MERGE_POLICY` picks who merges (`auto` — the watcher merges on
pass; `approve` — a coordinator approval is required; `observe` — the watcher never merges).
`PUSH_GATE=human` holds a finished builder *before* anything reaches GitHub; `PR_FLOW=draft` plus
`PR_READY_WHEN` gates *after* upload; `MERGE_POLICY=approve` gates after review. The three compose —
they are gates at three different moments, not three spellings of one gate.

`HUMAN_VERIFY_POLICY` decides what a `HUMAN-VERIFY:` block in a PR body means to the watcher
(`hold` / `coordinator` / `auto`). `STALE_DUP_DETECT` toggles the deterministic stale-duplicate
pre-merge gate. Each self-healing rail has its own toggle: `REVIEW_AUTOFIX`, `HEALTHCHECK_AUTOFIX`,
`MAIN_HEALTH_AUTOFIX`, `STALE_BASE_AUTOFIX`.

### Named governance postures

`templates/postures.tsv` is the canonical, committed set of posture bundles — a posture is a
human-named group of config keys that select one coherent stance. Seven ship: `solo-auto`,
`team-approve`, `gated-push`, `custom-steps`, `observe-only`, `full-auto`, `docs-lab` (HERD-409/#520
— pairs with the docs/research-lab PROJECT ARCHETYPE: a cheap docs review tier + lighter model
tiers). `herd init` (v2 posture
profiles, HERD-141/153) consumes the file to offer them at setup time and render the chosen bundle
into `.herd/config`; the posture-matrix sim (`scripts/herd/sim/sandbox-posture-matrix.sh`) proves the
gate loop under each one. Adding a posture to that file — not to the sim or the installer — is what
makes every consumer pick it up.

### Operator-defined gates (HERD-132)

`.herd/steps.tsv` declares custom stages at four seams: `post-build`, `post-healthcheck`,
`pre-merge`, `post-merge`. A step's `run` is a shell command or `skill:<name>` (a repo
`.claude/skills` skill invoked in the builder's session); `on_fail` is `block` or `warn`; `hold` is
`none`, `notify`, or `approve`, where `approve` records a sha-keyed hold released by
`herd-approve.sh`. An absent or empty step list is a byte-identical pipeline — no journal event, no
console row.

The stance here is **add-only**, and it is load-bearing: steps ADD checks and never replace or bypass
the built-in review/healthcheck floor. The seams run steps *after* the built-in gates for that stage,
so a step can only add a hold, never remove one. The rules live in the `scripts/herd/steps.sh` header.

### Project-owned gate contents

The gate *slots* are fixed; what runs inside them belongs to the project. `HEALTHCHECK_CMD` carries
an exit contract (0 clean / 1 code error / 2 data-env tolerated), `HEALTHCHECK_HEAVY_GLOB` decides
which diffs force the heavy profile, and `INTERACTION_TEST_CMD` drives an input and asserts the
dependent output moved. `REVIEW_CHECKLIST` injects a project risk checklist into the pre-merge review.
Review cost is tiered by diff shape: `DOCS_ONLY_GLOB` and `REVIEW_ESCALATE_GLOB` classify a diff,
`REVIEW_MODEL_DOCS` / `REVIEW_MODEL_CHEAP` / `REVIEW_MODEL_ESCALATED` name the model per tier.
Classification fails safe — an unreadable diff is treated as STRONG, and escalation always wins over
the docs tier.

### The runtime seam (P1–P4)

Driver bindings live in `templates/drivers/`: `herdr-claude.driver`, `headless.driver`,
`codex.driver`, `grok.driver`, `stub.driver`, with the shared library in `scripts/herd/driver.sh` and
the design in `docs/driver-abstraction.md`. `herd-review.sh` launches reviewers through
`herd_driver_oneshot_exec` rather than a hardcoded `claude -p`. Model references are
driver-qualified — the `MODEL_* ref <driver>:<model>` convention (HERD-151) — so a role can name a
runtime alongside a model.

**P4 has shipped** (PR #380, HERD-176, merged 2026-07-10): the watcher's resume, limit-banner
vocabulary, refix wake and model-switch now route through driver bindings. That was the last mile for
running non-Claude builders under the full gate loop.

### Portable governance

`herd governance export` writes the governance-scoped subset of config keys to a file (secrets and
machine-local keys never travel); `herd governance apply` proposes each key back through the validated
`herd config set` path rather than blind-writing, and a malformed bundle is refused with zero writes.
`herd governance hooks render` projects the same rules into session-time Claude Code hooks, so the
merge gate and the keyboard enforce one ruleset. Work-tracker backends are equally swappable —
`file`, `github`, `linear`, `jira`, `changelog` via `SCRIBE_BACKEND` and the guided
`herd backend switch`.

## What's needed

### Phase A — mixed-vendor review panel (HERD-276)

`REVIEW_PANEL` already fans out N concurrent reviewer passes over the same diff under
`NATIVE_BURST=on`, but every panelist launches on the single `REVIEW_MODEL`. Driver-qualified refs
already exist. Nobody has wired the two shipped seams together. Phase A adds a key (e.g.
`REVIEW_PANEL_MODELS`, space-separated driver-qualified refs) to the panel dispatch in
`herd-review.sh`, so each panelist launches via its own ref through `herd_driver_oneshot_exec`, with a
configurable verdict-merge policy (all-pass / majority / any-block-wins) recorded sha-keyed through
the existing review ledger. Ship-dormant: unset ⇒ byte-identical single-model panel; a missing driver
binary at dispatch reports INFRA, never a false BLOCK.

### Phase B — gate-order DAG + supersession-cancel (HERD-235)

Gate order is hardcoded in one long watcher loop body, and `_discard_stale_reviews` /
`_discard_stale_health` discard results without terminating workers — a doomed Opus review runs to
completion. Phase B declares gates as ordered cost classes (deterministic-cheap →
deterministic-slow → LLM) in one table that the action pass walks, and on sha supersession TERMs the
in-flight workers for the old sha via the existing corpse-sweep path. Behavior-preserving except for
the cancels. Gate topology becomes composable data; the DAG table stays engine-internal (not operator
config) in v1.

### Phase C — work-unit abstraction

De-PR-shape the loop for non-code domains. Today a work unit *is* a git PR end to end. The design
spike is merged and committed at `docs/spikes/work-unit-abstraction.md` (PR #339); the phase item gets
filed when the phase activates.

## Children and related items

- [HERD-276](https://linear.app/brian-keegan/issue/HERD-276) — Phase A: mixed-vendor review panel.
- [HERD-235](https://linear.app/brian-keegan/issue/HERD-235) — Phase B: gate-order DAG + supersession-cancel.
- [HERD-176](https://linear.app/brian-keegan/issue/HERD-176) — Phase 0: driver portability P4 (done, PR #380).
- [HERD-277](https://linear.app/brian-keegan/issue/HERD-277) — this doc.
- Phase C has no item yet; its spike is `docs/spikes/work-unit-abstraction.md` (PR #339).

Related but **not** children: HERD-102 (executor-tier experiment) exercises the model-tier seam, and
HERD-42 (the A/B run) validates the engine premise. Neither gates this program.
