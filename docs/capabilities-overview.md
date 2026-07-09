# Capabilities overview — the `herd` CLI + `.herd/config` levers

> A concise map of every `herd` subcommand and the key `.herd/config` levers, so you can find the
> right tool without reading the engine. This doc is **hand-written and curated for readability**;
> the machine-readable **source of truth** is [`templates/capabilities.tsv`](../templates/capabilities.tsv)
> — one row per command / lane / config key / lever / convention, with a `when_to_surface` column
> the coordinator skill renders from. When this doc and the TSV disagree, **the TSV wins** (it is
> what `herd config` validates against); open an issue so this overview can be reconciled.

Everything below is grounded in the engine as it ships (`bin/herd`, `scripts/herd/`). Nothing here
changes behavior — it documents what the flags already do. For the *pipeline* narrative (lanes,
merge control, the feedback loop) see [`../README.md`](../README.md).

---

## The `herd` CLI

`herd <command>` is the single front door. Grouped by what they do:

### Lifecycle — stand up, upgrade, rebuild

| command | what it does |
|---|---|
| `herd init` | Scout the repo (detects language: node / python / go / rust / java), interview, write `.herd/config`, seed `.herd/healthcheck.project.sh` from the template matching the detected stack, and render the coordinator skill. First-time onboarding. |
| `herd doctor` | One-pass dependency doctor: verifies `git`, `gh` (+auth), `claude`, `python3`, `herdr` (+its JSON contract) and that `python3` emits UTF-8; reports **every** problem at once with per-platform install hints. Soft deps (`glow`, `shellcheck`, `bats`) warn only; exits non-zero on any missing/broken hard dep. |
| `herd upgrade` | Bump `HERD_VERSION` and re-render the coordinator skill, preserving all `.herd/config` answers. |
| `herd render` | Re-render only the coordinator skill from the current config, without bumping the version. |
| `herd update [--force]` | Pull the engine (`git pull --ff-only` in the herdkit checkout), show the delta, re-render the skill, and reload — in one step. Refuses on a dirty engine checkout or mid-flight builders (`--force` overrides both guards). |
| `herd reload` | Rebuild the control room *around* the coordinator: stop + relaunch the watcher (pane visibility verified), ensure the pinned backlog pane, re-render the skill. Prints a per-component summary + the effective `MERGE_POLICY`; never closes the coordinator tab/agent. |
| `herd pane <watch\|backlog\|coordinator>` | Restart **one** control-room pane in place without a full reload. `coordinator` KILLS the live session, so it needs a typed `yes` or `--yes`. |

### Configuration

| command | what it does |
|---|---|
| `herd config list` | Print the effective keys + values (secret-shaped values masked). |
| `herd config get <KEY>` | Print one validated key's value. |
| `herd config set <KEY> <VALUE>` | Validate `<KEY>` against the capabilities manifest, edit `.herd/config` in place (comments preserved), then **do what the change requires**: restart the watcher (watcher-affecting keys) or re-render the coordinator skill (coordinator-facing keys). Never touches `DENY_PATHS` or `.herd/secrets`. |
| `herd config lint` | Flag **duplicate** keys in `.herd/config`. The config is shell-sourced, so a key assigned twice silently last-wins and can disable a gate — this lists every duplicated key and exits non-zero when any exist (scriptable). It reports; it never auto-dedups. |

### Forensics — read the engine journal (`.herd/journal.jsonl`)

| command | what it does |
|---|---|
| `herd log [--pr N] [--tail]` | Page the append-only journal: one readable line per gate event (dispatch, verdict + provenance, healthcheck attempt/outcome, refix bounce, merge, reap, infra death). `--pr N` filters to one PR; `--tail` follows live. |
| `herd why <pr#>` | Summarize **one** PR's full gate history chronologically — the first post-mortem tool when a PR is stuck or a gate/review/merge failed. Grounds the answer in recorded events. |
| `herd cost [--pr N]` | Aggregate the journal's token/cost events (measured per builder + per in-worktree review at merge time, deduped by message id, priced against the model→$ table): per-PR cost, cost-per-merged-PR, running totals by component + model. Read-only. **Prices are perishable** (`scripts/herd/cost.sh`) — verify against current rates. |

### Work source + cross-repo dispatch

| command | what it does |
|---|---|
| `herd backlog` | List open work items via the active `SCRIBE_BACKEND` (`file` / `github` / `linear`) in one uniform `#<id> <title>` shape — "what's my open work?" regardless of backend. |
| `herd report [--to <link>] [--dep] "<symptom>"` | File a cross-repo issue on `HERD_REPO` (or a peer from `.herd/links` via `--to`); deduplicates first. Default is fire-and-forget; `--dep` (requires `--to`) also records the filed item as a blocked-on dependency in `.herd/deps`. |
| `herd link list` | List peer repos registered in `.herd/links` (name · backend · routing target). |
| `herd depend <link>#<id>` | Record a **watched** blocked-on dependency on a peer-repo item; `dep-watcher.sh` polls it until the upstream closes, then notifies and un-blocks. |
| `herd deps <list\|rm\|demote>` | Inspect/edit recorded dependencies. A dep is editable data, never a freeze: `list` shows each dep + its current upstream state; `rm` drops one; `demote` reclassifies a hard blocker into a non-blocking watch row (instantly un-blocks the lane, keeps it on the radar). |

### Fleet — deterministic multi-project fan-out

`herd fleet <sub>` is a **no-LLM** fan-out over a flat project registry (default `~/.herd/fleet`,
one `name|path|repo` line per project). It never mutates a project's tree beyond what a delegated
per-project command already does; a missing / dirty / `gh`-unavailable project is reported, not
fatal.

| subcommand | what it does |
|---|---|
| `register <path>` | Add a herd project (read from its `.herd/config`) to the registry. |
| `list` | List registered projects (name · path · repo). |
| `discover [--register] <root>...` | Scan roots for `.herd/config` projects; print, and with `--register` add, each one found. |
| `status` | Read-only per-project rollup: branch, open PR count, watcher alive? (via the `herd-watch-<workspace>` argv0 marker), last journal activity. |
| `digest [--since <dur>]` | Cross-project standup aggregating each project's journal over a window (default 24h): per project — shipped/merged, needs-you holds + escalations, blocked verdicts, in-flight reviews, gate-failure count — plus a fleet summary line. |
| `inbox` | The cross-project **attention inbox** — one view of what needs you right now (blocked PRs, human-verify/approval holds, `gh`-live CONFLICTING PRs, failed health gates), each as `PR# · reason · suggested action`; a clean project shown as clean. |
| `governance` | Fleet-wide **global concurrency** view: total in-flight builders + reviews summed across all projects. The account usage limit is account-wide, so this helps avoid a fleet-wide limit-hit. Read-only. |
| `set <KEY> <VALUE>` | Propagate one policy across the whole fleet by delegating to each project's own **validated** `herd config set` (e.g. `MERGE_POLICY` / a model tier / `TOKEN_MODE`). |
| `upgrade` | Run `herd update` in every registered project (per-project outcome table). |
| `reload` | Run `herd reload` in every registered project (per-project outcome table). |

---

## The lanes

The lanes are the worker scripts under `scripts/herd/` that the coordinator delegates to; the
[README's "What you get — the lanes" table](../README.md#what-you-get--the-lanes) documents each in
the context of the pipeline. In brief: **coordinator** (control room), **feature** /
**quick** (isolated worktree builders → PR), **scribe** (serialized backlog writer),
**research** (read-only research queue), **resolver** (test-gated conflict resolver),
**review** (adversarial pre-merge correctness gate), **watcher** (live console + auto-merge state
machine), plus **dep-watcher** (polls `.herd/deps`) and the **backlog-reconcile** sweeps (drift
detection after merge bursts). See `templates/capabilities.tsv` for the full lane list and each
lane's `when_to_surface`.

---

## Key `.herd/config` levers

`.herd/config` is committed, code-shaped, and **zero-secret** (credentials live in `.herd/secrets`,
gitignored). Below are the levers you reach for most; the full validated key set with per-key
metadata is in `templates/capabilities.tsv` and viewable live with `herd config list`.

### Core wiring (set by `herd init`)

| key | purpose |
|---|---|
| `PROJECT_ROOT` | Absolute path to the project git root; all scripts derive paths from it. |
| `WORKTREES_DIR` | Where feature worktrees are created — a sibling of `PROJECT_ROOT`, never committed. |
| `DEFAULT_BRANCH` | Remote/branch to fork from and merge PRs into (e.g. `origin/main`). |
| `WORKSPACE_NAME` | Human-readable project label; surfaces in the coordinator title, agent names, and singleton identifiers. Two projects sharing one herdr instance must differ. |
| `BACKLOG_FILE` / `SCRIBE_BACKEND` | The work tracker: a markdown file (default), GitHub Issues, Linear, or an append-only changelog. |
| `HEALTHCHECK_CMD` | Project health command (exit 0 clean / 1 code error / 2 data-env tolerated). `herd init` seeds a stack-matched `.herd/healthcheck.project.sh`. |

### Model tiers + token budget

| key | purpose |
|---|---|
| `MODEL_COORDINATOR` / `MODEL_FEATURE` / `MODEL_QUICK` / `MODEL_SCRIBE` / `MODEL_RESEARCH` / `MODEL_REVIEW` / `MODEL_RESOLVER` | Per-role model map. Eco-leaning starter defaults; an explicit key always wins. |
| `TOKEN_MODE` | `standard` (default) \| `eco`. `eco` flips the **built-in** defaults to cheaper tiers; an explicit `MODEL_*` key always beats it. |
| `MODEL_ESCALATE_GLOB` | Egrep-`i` pattern of task text that deterministically forces the `MODEL_FEATURE` tier in either lane (a model step-up for judgment-heavy work). Blank → off. |

### Merge control + review gate

| key | purpose |
|---|---|
| `MERGE_POLICY` | The primary merge lever (**default `auto`**): `auto` (watcher merges on pass) \| `approve` (coordinator sign-off via `herd-approve.sh`) \| `observe` (never merges). Supersedes the legacy `WATCHER_AUTOMERGE` boolean; empty/unset derives from that boolean (also default true→auto). |
| `MERGE_METHOD` | `merge` \| `squash` \| `rebase`. |
| `DELETE_BRANCH_ON_MERGE` | `true` to clean up merged feature branches (default `false` preserves today's behavior). |
| `PR_FLOW` / `PR_READY_WHEN` | Open PRs `direct` (default) or `draft`; and who promotes a draft to ready (`builder` / `coordinator` / `human`). Threaded into the lane rules only. |
| `LOCAL_REVIEW` | `none` (default) \| `pre-pr`. When `pre-pr`, the builder runs an adversarial `herd-review.sh --local` pass against its worktree diff and must reach `REVIEW: PASS` **before** opening the PR — a correctness BLOCK is caught and fixed locally. The post-PR review gate still runs (belt-and-suspenders). |
| `REVIEW_AUTOFIX` / `REFIX_MAX_ROUNDS` | Auto-bounce a BLOCK review back to the builder to fix + push, bounded by max rounds **per rail** (default 3) before escalating to "needs you". Each rail (review / health / stale-base) budgets separately, a rail's rounds are refunded when its red resolves, and a derived per-PR ceiling of `3 x REFIX_MAX_ROUNDS` bounds a PR failing across all of them (HERD-229). |
| `STALE_BASE_AUTOFIX` | Auto-heal STALE-BASE holds from the pre-merge stale-duplicate gate (default off): bounce the live builder with `git merge $DEFAULT_BRANCH` (or dispatch the conflict resolver when no live builder remains), spending the stale rail's own `REFIX_MAX_ROUNDS` budget; DUPLICATE flavor stays human. |
| `MERGE_FAIRNESS` | Ready-PR priority (default `off`): a candidate whose gates are already green for its head sha is visited — and merged — **before** the action pass dispatches new gate work for any sibling, so it stops losing its sha to the merges those dispatches invite. Ordering only; every gate, the pre-merge re-verify and the merge policy still run, so nothing merges unpassed. The `starving · N re-stale laps` row and the `pr_restale` / `pr_starvation` journal events are **always on** and report regardless of this knob. |
| `HEALTHCHECK_AUTOFIX` | Auto-bounce a reproduced healthcheck **code error** back to the builder (failing test + suite-log path), on the same rails as `REVIEW_AUTOFIX`, spending the health rail's own `REFIX_MAX_ROUNDS` budget (refunded on the next CLEAN suite). Limit-parked / dead agents are preflighted; a `tab-leak-guard` trip is infra and never bounced. Default `false`. A row only reads "needs you" when nobody is working that red. |
| `REVIEW_ESCALATE_GLOB` / `REVIEW_MODEL_CHEAP` / `REVIEW_ESCALATE_MAXFILES` | Risk-tiered review: reserve the expensive reviewer for engine-critical paths and large diffs; docs/test-only diffs can be skipped with a recorded low-risk PASS. Classification **fails safe** (unreadable diff → strong tier). Blank glob → every PR gets the full review, unchanged. |
| `REVIEW_CONCURRENCY` / `SPAWN_AHEAD` / `HEALTH_CONCURRENCY` | Pipeline throughput knobs: parallel reviews, builder spawn lead over the gate, and serialized healthchecks (default 1 — feature worktrees share one git object store, so overlapping suites can false-red a clean PR). |

### Watcher lens + team mode

| key | purpose |
|---|---|
| `WATCHER_VIEW` (+ `WATCHER_VIEW_AUTHOR` / `_ASSIGNEE` / `_LABEL` / `_STATUS` / `_DEPS_LABEL`) | Narrow **which** open PRs the console displays each tick: `all` (default) \| `mine` \| `review-queue` \| `deps`, ANDed with the filters. **Selection only** — it never relaxes a merge gate. |
| `WATCHER_SCOPE` / `WATCHER_OWNER` | **Team mode (opt-in).** `mine` (default) = today's exact solo behavior. `all` = teammates' PRs are **displayed** but auto-merge is strictly scoped to PRs owned by `WATCHER_OWNER`; a teammate's PR shows "not mine — manual" and is never auto-merged. A **narrowing** gate — it can only withhold a merge, never authorize one the gates would deny. Fail-closed: an unresolvable owner withholds auto-merge. |

### App preview (feature lane)

`APP_PREVIEW_CMD` and its companions (`APP_PREVIEW_SERVER_ARGS`, `APP_PREVIEW_HEALTH_CMD`,
`APP_PREVIEW_HEALTH_PATH`, `APP_PREVIEW_PORT_BASE`) drive the live-preview pane for app-facing
changes. Blank `APP_PREVIEW_CMD` restricts lanes to `herd-quick.sh` only. The health probe is
precedence-ordered (health-cmd → HTTP path) and renders ⚪ unknown rather than a false-red 🔴 when a
non-HTTP preview can't be curled.

### Dependencies + limit auto-resume

| key | purpose |
|---|---|
| `DEP_POLL_MIN` / `DEP_POLL_MAX` / `DEP_STALE_TTL` | `dep-watcher.sh` cadence: initial poll, capped-exponential backoff ceiling, and the TTL after which a still-open dep with no movement surfaces as `stalled` (loudly, but still polled — never a freeze; `0` disables). |
| `HERD_LIMIT_DETECT` / `HERD_LIMIT_HOOK` (env) | Kill-switches for usage-limit detection + auto-resume, and for generating the per-worktree `rate_limit` hook. |
| `HERD_LIMIT_RESUME_BUFFER` / `HERD_LIMIT_UNKNOWN_WAIT` | Seconds to wait after the parsed reset before resuming a limit-blocked builder, and how long to hold when the reset time couldn't be parsed (≈ one 5h window). |
| `COORDINATOR_WATCHDOG` | `on` \| `off` (**default off**): opt-in coordinator auto-resume, **wired** in `agent-watch.sh` (`_handle_coordinator_watchdog`, per-tick). When `on` (and the watcher has been restarted so config is re-read), the watcher revives a **confirmed** limit-parked coordinator the same way it revives builders — at reset+buffer via `claude --continue`. Only acts when a limit sentinel/banner is present **and** the agent is not `working`; never touches a healthy coordinator; a `WORKSPACE_NAME`-keyed launch lock prevents double-launch; a failed resume escalates via notification without looping. Ships **dormant**: leave off to keep the coordinator human-managed; turn on for unattended/overnight runs so a limit-hit coordinator does not strand orchestration. |

---

## Conventions worth knowing

- **`HUMAN-VERIFY:`** — a PR-body marker a builder emits to declare manual steps it couldn't run
  itself (one per line). The watcher parses it and holds that PR for sha-keyed approval instead of
  auto-merging, so a manual step is never silently skipped. A new commit re-holds.
- **`herd-watch-<workspace>`** — the per-workspace argv0 the watcher re-execs under, so a running
  watcher is attributable to exactly one workspace in `ps`/`pgrep`; reaps never touch a sibling
  project's watcher.
- **Dead-builder detection** — the watcher surfaces a builder whose worktree is present but whose
  agent process vanished with no PR filed (a silent death that falls through the stall, orphan-tab,
  and limit-hit paths): a loud console row + one-shot notification so the operator knows. Detect +
  alert only; auto-respawn is deliberately deferred.
