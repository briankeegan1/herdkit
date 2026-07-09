# Sensitive-data deployment patterns

**Status:** docs + small config (HERD-171). Not a compliance certification, not a full DLP
implementation. Everything below is grounded in seams that **already ship** in this tree today.

**Origin:** HERD-171. Operators who process regulated or otherwise sensitive payloads need two
things herdkit can already support without inventing a new runtime:

1. Point the **claude** agent runtime at an **enterprise/BAA-covered** or **local** model endpoint.
2. Keep raw identifiers **outside** the agent loop via the existing **connector-edges** pattern,
   with the engine **journal** as the forensic record of what crossed the boundary.

---

## Part 1 — Configurable model endpoint

### What already exists

| Seam | Where | What it does today |
|------|--------|--------------------|
| **Model matrix (HERD-151)** | `MODEL_*` keys, `templates/models.tsv`, `herd_model_resolve` in `scripts/herd/driver.sh` | Every role accepts a bare model id or a runtime-qualified `<driver>:<model>` ref. A bare value is byte-identical to pre-matrix configs. |
| **Driver exec surface (HERD-150)** | `templates/drivers/*.driver`, `scripts/herd/driver.sh` | Interactive spawn, one-shot exec, and related bindings are catalogued per driver. Spawn + one-shot already route through the seam for the shipped drivers. |
| **Machine-scoped overlay (HERD-47)** | `.herd/config.local` (gitignored) | Per-machine keys (models, driver, operator prefs) stay out of the committed baseline. |

Together these already let a runtime pick **which model** (and optionally **which driver**) a role
uses. What was missing was a first-class, machine-local place to say **which endpoint** the *claude*
runtime should call — Claude Code itself already honors the standard `ANTHROPIC_BASE_URL` env var;
herdkit just needed to accept and propagate it.

### The config key: `ANTHROPIC_BASE_URL`

| | |
|--|--|
| **Key** | `ANTHROPIC_BASE_URL` |
| **Scope** | `machine` — `herd config set ANTHROPIC_BASE_URL <url>` writes `.herd/config.local`, **not** the committed `.herd/config` |
| **Default** | empty → Claude Code's default Anthropic endpoint (byte-identical to before) |
| **Wiring** | `scripts/herd/herd-config.sh` exports the value when set; `scripts/herd/driver.sh` injects it as `--env` on herdr agent start and into detached/headless children |
| **Companion auth** | `ANTHROPIC_API_KEY` (and any other Anthropic client creds) stay in **`.herd/secrets`** or the control-room process environment — never in committed config. See the `.herd/secrets` lever in `templates/capabilities.tsv`. |

```sh
# On THIS machine only (gitignored overlay):
herd config set ANTHROPIC_BASE_URL "https://my-corp.example/v1"

# Companion key (gitignored secrets file — not a herd config key):
#   echo 'ANTHROPIC_API_KEY="…"' >> .herd/secrets
#   chmod 600 .herd/secrets
```

### Supported patterns

#### A. Enterprise / BAA-covered endpoint

Use when policy requires model traffic to stay on a vendor enterprise gateway (or a private reverse
proxy in front of one) that your org's BAA / DPA covers:

1. Set `ANTHROPIC_BASE_URL` to that gateway's base URL (machine-local).
2. Put the gateway API key in `.herd/secrets` as `ANTHROPIC_API_KEY` (or export it in the shell that
   launches the control room, so interactive herdr agents and one-shot drainers inherit it).
3. Keep `MODEL_*` on the model ids that gateway accepts (still the model matrix — HERD-151).

Herdkit does **not** negotiate BAAs, attest residency, or inspect TLS. It only relocates the wire
Claude Code already uses.

#### B. Local model endpoint

Use when a local OpenAI/Anthropic-compatible server (ollama + proxy, llama.cpp server, vLLM, etc.)
exposes an Anthropic-compatible API Claude Code can reach:

1. Set `ANTHROPIC_BASE_URL` to the local base (e.g. `http://127.0.0.1:11434` or your proxy's URL).
2. Set `ANTHROPIC_API_KEY` if the local server requires one (many local stacks accept a dummy value).
3. Point `MODEL_*` at the **ids that local stack advertises**. The suggestions catalog
   (`templates/models.tsv`) is advisory only — an uncatalogued id is allowed with a soft note.

Honest limits:

- A local stack that is **not** Claude-compatible still needs a non-Claude **driver** (the model
  matrix's `<driver>:<model>` form, HERD-151). Shipping production `codex` / `grok` drivers is
  separate work (agent-runtime portability epic; see `docs/driver-abstraction.md`). Do not invent
  driver behavior here.
- Mid-session resume / model-switch / limit-detection paths that are not yet fully routed through
  the driver exec seam still inherit process environment; the endpoint key is env-level, so a
  process that already has `ANTHROPIC_BASE_URL` exported continues to use it. Remaining routing
  phases are documented in `docs/driver-abstraction.md` — treat incomplete routing as a
  **forward-reference**, not as shipped behavior.

### What this is *not*

- Not a second model catalog. `templates/models.tsv` stays advisory.
- Not a committed secret store. Gateway URLs and API keys stay machine-local / gitignored.
- Not a claim that herdkit is HIPAA/SOC2/etc. certified.

---

## Part 2 — De-identify → process → re-identify (documented pattern)

### What already exists

The **connector-edges** pattern (HERD-170, shipped) is edges-only: two thin templates and zero
per-service framework. Full contract: [`docs/connector-seams.md`](connector-seams.md).

```
   ┌── FETCH edge ──┐        run reads          ┌── POST edge ──┐
   │ url/API ──▶ file│ ─────────────────▶ … ──▶ │ file ──▶ endpoint│
   └────────────────┘   (pre-run / in-run)       └────────────────┘
      templates/connector-fetch.sh                templates/connector-post.sh
```

- **FETCH** (`templates/connector-fetch.sh`) — pre-run converter: URL/API → file. Optional
  `CONNECTOR_FETCH_SCREEN` transform over the bytes before they land.
- **POST** (`templates/connector-post.sh`) — post-merge step via the existing `steps.tsv` seam
  (`scripts/herd/steps.sh`): file → endpoint. Fail-soft by default (`on_fail=warn`).
- **Journal** (`.herd/journal.jsonl`, `scripts/herd/journal.sh`) — append-only forensic trail.
  Pipeline steps emit `step_run` events with `name`, `at`, `outcome` (pass|warn|fail|held). Inspect
  with `herd log` / `herd why <pr#>`.

### Pattern shape (document only — not a shipped product feature)

For payloads that must not enter the agent loop in raw form:

```
  1. UPSTREAM DE-IDENTIFY (FETCH + screen)
     CONNECTOR_FETCH_URL  →  raw extract
     CONNECTOR_FETCH_SCREEN → strip/hash/tokenize PII → .herd/inbox/work.tsv
     (map of token→original stays OUTSIDE the worktree, e.g. operator-only path)

  2. PROCESS (the herd run)
     Builders / review / merge only ever read the de-identified file.
     DENY_PATHS / SHARE_LINKS guards already keep .herd/secrets out of worktrees (HERD-87).

  3. DOWNSTREAM RE-IDENTIFY (POST)
     A project-local step (or CONNECTOR_POST_CMD override) re-joins tokens → original ids,
     then POSTs the result. Wire as a post-merge row in .herd/steps.tsv:

       reidentify-post   post-merge   bash .herd/connector-post.sh   warn   none

  4. PROVE THE BOUNDARY (journal)
     steps.sh journals step_run for every edge that ran (name + outcome + sha).
     `herd log` / `herd why <pr>` reconstruct what crossed post-merge — and what warned.
```

Worked zero-network proof of the raw edges (not the de-id transforms themselves):
`tests/test-connector-seams.sh` (fetch → screen → post with stubbed `*_CMD`, no network).

### Operator checklist

1. Copy the two templates into the project (e.g. `.herd/connector-fetch.sh`,
   `.herd/connector-post.sh`) — ship-dormant until URLs are set.
2. Implement **project-local** de-id / re-id as `CONNECTOR_FETCH_SCREEN` / `CONNECTOR_POST_CMD`
   (or thin wrappers). herdkit does not ship a PII redactor.
3. Keep the token map and raw extracts off builder worktrees (no `SHARE_LINKS` to secrets; prefer
   paths outside the pool).
4. Prefer `on_fail=warn` on the post-merge re-id step so a dead sink never wedges a green merge.
5. After a run, `herd log --tail` (or `herd why <pr>`) confirms `step_run` outcomes for the edges.

### What this is *not*

- Not an automatic PII detector or tokenizer — you bring the screen/re-id commands.
- Not in-workflow API calls from the agent — edges stay file-in / file-out
  (see "What this is *not*" in `docs/connector-seams.md`).
- Not a substitute for access control on the token map or the destination systems.

---

## Quick reference

| Goal | Lever |
|------|--------|
| Enterprise/BAA or local model wire | `ANTHROPIC_BASE_URL` (machine) + `ANTHROPIC_API_KEY` in `.herd/secrets` / env |
| Model *id* per role | `MODEL_*` (+ optional `<driver>:` prefix, HERD-151) |
| Pre-run pull + screen (de-id) | `templates/connector-fetch.sh` + `CONNECTOR_FETCH_SCREEN` |
| Post-merge push (re-id + deliver) | `templates/connector-post.sh` + `.herd/steps.tsv` post-merge row |
| Prove what crossed | `.herd/journal.jsonl` → `herd log` / `herd why` (`step_run` events) |

Further reading: [`docs/connector-seams.md`](connector-seams.md), [`docs/driver-abstraction.md`](driver-abstraction.md),
`templates/config.example` (commented `ANTHROPIC_BASE_URL` block), `templates/capabilities.tsv`
(manifest rows for the key and the secrets lever).
