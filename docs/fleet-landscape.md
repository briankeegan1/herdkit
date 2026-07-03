# Competitive landscape & prior-art — the fleet-coordinator vision

**Status:** living research doc · **Retrieved:** 2026-07-03 (all findings as-of this date unless a
different date is cited) · **Method:** live web research (WebSearch/WebFetch), not model training
memory · **Refresh owner:** coordinator/backlog

> ⚠️ **PERISHABLE.** The AI-agent-orchestration space moves *monthly*; every vendor claim below is
> a point-in-time snapshot with an as-of date. Treat anything older than ~8 weeks as stale and
> re-verify against the primary source before quoting it. Suggested refresh cadence: **every 6–8
> weeks**, or immediately before any positioning/fundraising/roadmap decision. See
> [Refresh cadence](#refresh-cadence) at the end.

---

## What we're comparing against — the fleet-coordinator vision

herdkit today is a per-project **coordinator**: a long-lived agent that owns one project's backlog
and delegates each item to an isolated git-worktree sub-agent, gated by an adversarial review +
auto-merge watcher (`README.md`). The **fleet coordinator** (EPIC, P0 shipped in PR #94) adds a
*parent* layer above the per-project coordinators. As built, `herd fleet` is a **deterministic,
no-LLM** fan-out over a flat project registry (`~/.herd/fleet`, records `name|path|repo`):
`register | list | discover | status | upgrade | reload`, where every per-project action
*delegates to that project's own `herd`* and never reimplements it (`scripts/herd/fleet.sh`).

The **full vision** this doc measures the market against is the next layer up:

> A **persistent master coordinator over per-project _autonomous_ AI dev coordinators**, that (a)
> accepts a **natural-language command** and routes it to the right project's agent, and (b) rolls
> up a **cross-project status digest** — all **self-hosted / terminal-native**, model-flexible, and
> PR/CI-native.

The six sections below locate that vision in the current market. **Key reframe (backlog,
2026-07-02):** "tie many projects under one control plane" is a *mature, named* pattern — IDPs,
monorepo project-graphs, GitOps fleets. herdkit's novelty is not the control plane; it is applying
that proven pattern to **autonomous AI-agent coordinators**, self-hosted and terminal-native.

---

## Q1 — AI-agent orchestration platforms: does any ship a master cross-project coordinator?

**Short answer (as-of 2026-07-03): the *multi-agent-across-repos* pattern is now table stakes, but
it is delivered almost entirely as cloud SaaS dashboards, not as a self-hosted/terminal-native
master-over-coordinators layer. The closest to a "mission control across repos" is GitHub's Mission
Control; the closest to "a coordinator that spawns sub-coordinators" is Cognition's Devin-orchestrates-Devins.**

| Platform | Multi-agent? | Cross-**repo** dispatch? | Cross-repo **status rollup**? | Self-hosted / terminal-native? | As-of |
|---|---|---|---|---|---|
| **GitHub Copilot — Mission Control / Agents panel** | ✅ | ✅ "across one repo or many" from one prompt box | ⚠️ "My Work" view shows active sessions/PRs across connected repos; **no aggregated digest/metrics described** | ❌ cloud (github.com), desktop app | 2025-12-01 |
| **Factory.ai (Droids)** | ✅ coordinator droid decomposes → code/review/docs/test droids | ⚠️ parallel droids; ticket-native (Linear/Jira) | ⚠️ per-session; no cross-repo rollup surfaced | ⚠️ IDE/CLI/Slack, cloud control | 2026-04 |
| **Devin / Cognition** | ✅ **Devin-orchestrates-Devins**: parent scopes, allocates, monitors, compiles | ⚠️ parallel managed Devins, each its own VM | ⚠️ parent compiles results; not a portfolio digest | ⚠️ Devin Desktop "command center"; cloud | 2026-06 |
| **Cursor — background/cloud agents** | ✅ `/multitask` subagent fleet (v3.2, 2026-04-24) | ✅ multi-repo cloud agents (2026-05-13); multi-root workspaces | ⚠️ Agents Window; no portfolio rollup | ⚠️ **self-hosted cloud agents on your infra** exist; IDE-native, not terminal | 2026-04→05 |
| **Google Jules** | ✅ `--parallel` (max 5/prompt); 15–60 concurrent tasks | ✅ "queue the same refactor against ten or twenty repos in parallel" | ⚠️ task list; no digest | ❌ cloud; has a `jules` CLI | 2026 |
| **OpenAI Codex (cloud + app)** | ✅ subagents; parallel sandboxes | ✅ "agents work in parallel across projects"; worktrees | ⚠️ macOS app manages many agents; no portfolio digest | ⚠️ Codex CLI + cloud; app is macOS | 2026-04+ |
| **Sourcegraph Amp** | ✅ parallel sub-agents; Deep mode | ⚠️ codebase-wide; spun out as standalone co. 2026 | ❌ | ⚠️ CLI + IDE; cloud index | 2026 |
| **OpenHands (ex-OpenDevin)** | ✅ multiple agents in parallel; Large-Codebase SDK maps deps + orders changes | ⚠️ dependency-ordered multi-change | ❌ | ✅ **MIT-licensed, self-hostable, sandboxed Docker** — closest OSS analog | 2026 |

**Read of Q1.** Everyone can now run *many agents in parallel*, and several (GitHub, Jules,
Cursor, Sourcegraph) can *fan one change across many repos*. What is still **absent** from the
named platforms is a **persistent parent coordinator that sits over per-project _autonomous
coordinators_ and rolls the portfolio up into a digest**. Devin's "orchestrate Devins" is the
nearest architectural cousin (coordinator → sub-coordinators), but it is ephemeral-per-task and
cloud-bound, not a standing fleet layer. GitHub Mission Control is the nearest *UX* cousin (one box,
many repos) but is explicitly a cloud dashboard with no self-hosted/terminal form and — per the
primary source — **no described status-rollup/metrics layer**, just a live session list.

Sources: [GitHub blog — orchestrate agents with Mission Control (2025-12-01)](https://github.blog/ai-and-ml/github-copilot/how-to-orchestrate-agents-using-mission-control/) ·
[GitHub blog — Agents panel](https://github.blog/news-insights/product-news/agents-panel-launch-copilot-coding-agent-tasks-anywhere-on-github/) ·
[Factory docs](https://docs.factory.ai/welcome) · [Latent.Space — Factory "A-SWE droid army"](https://www.latent.space/p/factory) ·
[Cognition — Devin agents can orchestrate other Devins](https://aidevsetup.com/insider/devin-agents-can-now-orchestrate-other-devins-what-it-means) ·
[The Agent Report — Devin Desktop command center (2026-06)](https://the-agent-report.com/2026/06/cognition-devin-desktop-agent-orchestration/) ·
[Cursor — self-hosted cloud agents](https://cursor.com/blog/self-hosted-cloud-agents) · [Cursor changelog 2026-04-24 (multitask/worktrees/multi-root)](https://cursor.com/changelog/04-24-26) · [Cursor — multi-repo dev environments](https://cursor.com/blog/cloud-agent-development-environments) ·
[WorkOS — Codex, Jules & agentic parallel coding](https://workos.com/blog/agentic-parallel-coding) · [Jules](https://jules.google/) ·
[OpenAI Codex cloud docs](https://developers.openai.com/codex/cloud) · [OpenAI — Codex app](https://openai.com/index/introducing-the-codex-app/) · [OpenAI Codex subagents](https://developers.openai.com/codex/subagents) ·
[Sourcegraph spins out Amp](https://tessl.io/blog/sourcegraph-spins-out-ai-coding-agent-amp-as-a-standalone-company/) · [OpenHands](https://www.openhands.dev/).

---

## Q2 — IDPs / portals: the closest prior art for "one control plane over all projects"

**Short answer: this is the strongest prior art, and it is actively converging on our space.**
Port has explicitly rebranded around the exact idea — a portal as the **command-and-control center
for AI agents** — and raised to fund it. This is the vocabulary herdkit should borrow.

- **Port** raised a **$100M Series C (announced 2025-12-11**, led by General Atlantic; ~$158M total,
  ~$800M valuation) to build an **"agentic engineering platform"** layered on its portal — a
  *"command-and-control center"* where agents (backed by Port's **knowledge graph** of services and
  components) resolve tickets, self-heal incidents, fix vulns, and enforce standards, with humans
  **in-the-loop** approving via the dashboard. Port's **Skills** (2026) are reusable instruction
  sets that load into agents by context and are *"instantly available across Cursor, Claude, and any
  MCP-compatible client."* Data model = **blueprints** (custom entities + relationships).
  [SiliconANGLE (2025-12-11)](https://siliconangle.com/2025/12/11/port-nets-100m-turn-developer-portal-agentic-ai-hub/) ·
  [Port — Agentic-SDLC platform](https://www.port.io/) · [Port — Skills](https://www.port.io/blog/introducing-skills-in-port).
- **Cortex** now positions literally as *"Mission control for the AI software factory,"* helping
  orgs *"roll out AI coding agents with the security, testing, and ownership standards to scale
  safely."* [cortex.io](https://www.cortex.io/).
- **Backstage / OpsLevel / Humanitec** remain catalog/scorecard/self-service platforms; Backstage
  is the OSS baseline (plugin ecosystem), the others commercial. No evidence yet of a native
  autonomous-coding-agent orchestration layer as advanced as Port's. [Encore — platform
  engineering tools compared](https://encore.cloud/resources/platform-engineering-tools) · [OpsLevel
  — Cortex vs Backstage](https://www.opslevel.com/resources/cortex-vs-backstage-whats-the-best-internal-developer-portal).

**Vocabulary to borrow (the design lexicon of the mature control-plane pattern):**

| IDP term | herdkit analog today | Gap to close |
|---|---|---|
| **Catalog** (services/components) | `~/.herd/fleet` project registry | thin; no metadata/ownership |
| **Relationship / dependency graph** | `.herd/deps` + `.herd/links` (cross-repo) | not visualized/rolled up |
| **Scorecards** | healthcheck (per-project pass/fail) | no portfolio scorecard |
| **Self-service actions / templates** | `herd init`, coordinator skill | not a template gallery |
| **Affected-detection** | (monorepo-style; see Q3) | absent at fleet level |
| **Portfolio rollup** | `herd fleet status` table | deterministic, no digest/NL |

**Read of Q2.** IDPs are the **template for herdkit's control-plane layer**, and Port in particular
is racing toward "an IDP *for agents*." The difference: IDPs are **enterprise SaaS catalogs bolting
agents on**, aimed at platform teams governing dozens-to-hundreds of services; herdkit is a
**terminal-native, self-hosted, single-operator** control plane where the *coordinators themselves*
are the primitives. Borrow the vocabulary; do not try to out-catalog Port.

---

## Q3 — Monorepo / multi-repo orchestration: is anyone adding AI-agent fan-out?

**Short answer: yes, aggressively — this is the fastest-moving adjacent front.** The proven
"project-graph + affected + fan-one-change-to-all" primitives are being wrapped with agent fan-out.

- **Nx — Polygraph** (announced **~2026-06-23**): connects multiple repos into a single *"synthetic
  monorepo"* so agents can work across them; a **parent/orchestrator agent** coordinates cloud
  agents to make coherent cross-repo changes and **auto-submits PRs**. Nx Cloud reworked Nx Agents
  (~4× faster) and its 2026 roadmap is explicitly "expanding agent autonomy." This is the **closest
  monorepo-world analog to a fleet coordinator**. [The New Stack — Nx Polygraph (2026-06-23)](https://thenewstack.io/nx-polygraph-synthetic-monorepo-agents/) ·
  [Nx 2026 roadmap](https://nx.dev/blog/nx-2026-roadmap) · [Nx — enhance AI](https://nx.dev/docs/features/enhance-ai).
- **Sourcegraph — Agentic Batch Changes** (**public beta 2026-06-30**, cloud; self-hosted with
  Sourcegraph 7.5 on **2026-07-08**): from a **single prompt**, an agent uses code search + Deep
  Search to find the repos needing a change, validates in one repo, expands the rollout across
  *"hundreds or thousands of repositories,"* reacts to CI, and **delegates judgment calls to
  frontier agents (Claude Code, Codex) via Sourcegraph MCP.** This is the **most direct
  "NL-command → fan across all repos" product shipping today.** [Yahoo/PR — Agentic Batch Changes
  public beta](https://finance.yahoo.com/technology/ai/articles/sourcegraph-launches-agentic-batch-changes-140000070.html) ·
  [Sourcegraph — Batch Changes](https://sourcegraph.com/batch-changes).
- **Turborepo/Vercel, Bazel, Pants, meta** — remain build/graph tools; no first-party autonomous
  agent fan-out surfaced as of retrieval. **Renovate/Dependabot** remain the proven "fan one
  (dependency) change to all repos" bots — narrow, deterministic, not general agent dispatch.

**Read of Q3.** The monorepo world *already ships* NL-command-to-fan-out (Sourcegraph) and
orchestrator-agent-across-repos (Nx Polygraph). But both are **task-scoped batch tools** ("apply
*this change* everywhere"), not **persistent per-project coordinators with their own standing
backlogs**. They fan a *change*; herdkit fans a *command to autonomous agents that each own their
project*. That distinction is herdkit's core defensibility — and also where these players are the
most likely to encroach.

---

## Q4 — Cross-project rollup / eng-intelligence: reporting vs command-dispatch?

**Short answer: still overwhelmingly *reporting*, not *dispatch* — but the wall is cracking.**

- **Jellyfish** — investment alignment, roadmap vs maintenance vs unplanned, DevFinOps (eng spend →
  finance); board-level reporting. **Reporting.**
- **Swarmia** — team-health/DevEx metrics, working agreements; developer-liked. **Reporting.**
- **LinearB** — the lone one with real **workflow automation**: **gitStream** automates PR routing,
  labeling, review assignment by complexity rules. This is *dispatch-adjacent* — automated routing
  of work — but it routes to **humans**, not agents. [codepulse — Jellyfish vs LinearB vs Swarmia
  (2026)](https://codepulsehq.com/guides/engineering-analytics-tools-comparison) · [Appfire —
  LinearB alternatives (2026)](https://appfire.com/resources/blog/linearb-alternatives).
- No evidence (as-of retrieval) that Jellyfish/Swarmia/Jira Advanced Roadmaps have added **agent
  command-dispatch**; they remain the "day-summary across projects" analog on the *reporting* side.

**Read of Q4.** Eng-intelligence is the prior art for herdkit's **cross-project digest** half, and
LinearB's gitStream is the prior art for **rule-based routing**. The unfilled seam: **routing work
to _agents_ and _acting_, not just measuring.** herdkit's `herd fleet status` + the future NL
dispatch layer sits precisely in that seam — but note these vendors own the *executive-reporting*
surface herdkit does not (and probably should not) chase.

---

## Q5 — THE SPECIFIC FUSION: master coordinator over per-project autonomous coordinators, NL + digest, self-hosted/terminal-native

**Does anyone ship exactly this? As-of 2026-07-03: no single product hits all of {master-over-
per-project-_autonomous-coordinators_ + NL command + cross-project digest + self-hosted +
terminal-native}. The market covers each axis separately; herdkit is unusual in fusing them.**

**Who is closest, and on which axis:**

| Contender | Master-over-coordinators | NL command dispatch | Cross-project digest | Self-hosted | Terminal-native |
|---|---|---|---|---|---|
| **GitHub Mission Control** | ⚠️ over agents, not coordinators | ✅ | ⚠️ live list only | ❌ | ❌ |
| **Sourcegraph Agentic Batch Changes** | ❌ over a change | ✅ | ⚠️ per-batch tracking | ✅ (7.5 self-hosted) | ⚠️ web-first |
| **Nx Polygraph** | ⚠️ orchestrator agent | ⚠️ | ⚠️ | ⚠️ | ❌ |
| **Devin orchestrate-Devins** | ✅ parent→sub-agents | ✅ | ⚠️ compiled per-task | ❌ | ⚠️ desktop |
| **Port (agentic IDP)** | ⚠️ governs agents via graph | ⚠️ actions/skills | ✅ portfolio (services) | ⚠️ | ❌ |
| **OpenHands** | ⚠️ | ✅ | ❌ | ✅ MIT | ⚠️ |
| **OSS orchestrators** (vibe-kanban, Conductor, Claude Squad, amux, Claworc, agentsmesh) | ⚠️ parallel agents | ⚠️ | ⚠️ kanban view | ✅ mostly | ✅ many | 

  *(OSS-orchestrator landscape: [awesome-cli-coding-agents](https://github.com/bradAGI/awesome-cli-coding-agents) ·
  [awesome-agent-orchestrators](https://github.com/andyrewlee/awesome-agent-orchestrators) ·
  [Augment — 9 open-source agent orchestrators (2026)](https://www.augmentcode.com/tools/open-source-agent-orchestrators) ·
  [Claworc](https://claworc.com/). These are largely single-machine "run N agents in parallel, watch
  a kanban" tools — closest on **self-hosted/terminal-native**, but weakest on **persistent
  per-project coordinators with their own backlogs + a cross-project digest.**)*

**The exact GAP no one fills:** a **standing, self-hosted, terminal-native parent** that (1) treats
each project's **autonomous coordinator** (with its own backlog, review gate, auto-merge) as the
unit, (2) takes an **NL command** and routes it to the right project's coordinator, and (3) emits a
**cross-project digest** ("what shipped/blocked/needs-eyes across all my projects today"). Cloud
platforms orchestrate *agents/changes*; OSS tools run *parallel agents on one box*; IDPs *govern*
agents over a service catalog. None run *coordinators-of-coordinators, offline, from a terminal*.

**herdkit's defensible differentiation:**
- **Self-hosted / terminal-native / offline-capable** — the file backend needs no network, no
  secrets, no SaaS account (`README.md`). None of GitHub/Devin/Jules/Codex/Factory offer this;
  Cursor's "self-hosted cloud agents" and Sourcegraph 7.5 self-hosted are the only cloud players
  with a real on-prem story, and both are IDE/web-first, not terminal-native.
- **Transparent / hackable** — plain bash lane scripts + an append-only engine journal
  (`herd why`, `herd log`); every gate event is a forensic record. Nothing to reverse-engineer.
- **Model-flexible** — not welded to one vendor's model; can ride whichever CLI/model the operator
  chooses.
- **PR/CI-native by construction** — worktree isolation + adversarial review + auto-merge watcher
  re-verifying at the instant of merge; the coordinator never edits the main checkout.
- **Coordinator-as-primitive** — the fleet layer composes *coordinators*, each already owning a
  backlog + gates, rather than raw agents. This is the architectural claim no competitor makes.

**Competitive RISK — who could subsume it, how fast:**
- **GitHub (highest risk, fastest).** Mission Control already does one-box-many-repos dispatch; a
  cross-repo digest + an org-agents rollup is a plausible next quarter. Distribution is unmatched.
  What they will *not* do soon: a self-hosted/offline/terminal-native form or full transparency —
  that is herdkit's moat against them. *Watch: any "org agents rollup / portfolio" GA.*
- **Sourcegraph (high, medium-fast).** Agentic Batch Changes + self-hosted 7.5 + MCP delegation to
  Claude Code/Codex is architecturally *very* close to "NL command → fan to per-repo agents,
  self-hostable." If they reframe from *batch change* to *standing per-repo coordinators*, they
  overlap hard. *Watch: any "persistent per-repo agent" or scheduling story.*
- **Port / Cortex (medium, slower).** They own the control-plane *vocabulary* and enterprise
  distribution; if "IDP for agents" matures into per-service standing coordinators, they cover the
  enterprise variant — but remain SaaS/dashboard, not terminal-native/solo-operator.
- **Nx (medium, adjacent).** Polygraph's orchestrator-agent-across-repos could grow a standing
  layer, but Nx is monorepo-gravitational and build-centric.
- **OSS orchestrators (low individually, high in aggregate).** vibe-kanban/Conductor/Claworc/
  agentsmesh already own self-hosted+terminal; if one adds *per-project coordinators with backlogs +
  a cross-project digest*, it is the most direct clone. Lowest switching cost, least distribution.

---

## Q6 — Pricing / positioning / adoption signals for the "one person, many projects" persona

**The market is priced for *teams and seats*, not for a *single operator running many projects*.**
This is a genuine positioning wedge for a self-hosted tool with no per-seat rent.

| Product | Entry / relevant pricing (as-of) | Fit for solo-many-projects |
|---|---|---|
| **Cursor** | Business **$40/seat/mo**; Pro tiers + Enterprise custom | seat-priced; multi-repo is a Business/Enterprise feature |
| **Devin** | Core **$20/mo + ~$2.25/ACU**; Team **$500/mo** (~250 ACU); Enterprise custom | usage (ACU) burn scales with autonomy; pricey at fleet scale |
| **GitHub Copilot** | Usage-based since **2026-06-01**: Pro $10, Pro+ $39, Business **$19/user/mo**, Enterprise $39/user/mo, all + AI-credit metering | seat + token metering; coding-agent burns credits |
| **Google Jules** | Free intro (15 tasks/day, 3 concurrent); paid via **AI Pro $19.99/mo** (5×) / **AI Ultra ~$100–125/mo** (20×) | task-throttled; parallel-repo refactors gated to paid |
| **Factory.ai** | No public per-seat price found; enterprise sales-led (raised **$150M Series C, ~$1.5B, 2026-04**) | enterprise-oriented; not self-serve solo |
| **herdkit** | **$0 infra** — self-hosted, file backend, no seats, bring-your-own-model | **native fit**: cost scales with model tokens only |

Sources: [Cursor pricing 2026 (NxCode)](https://www.nxcode.io/resources/news/cursor-ai-pricing-plans-guide-2026) ·
[Devin pricing 2026 (costbench)](https://costbench.com/software/ai-coding-assistants/devin-ai/) ·
[GitHub Copilot → usage-based billing](https://github.blog/news-insights/company-news/github-copilot-is-moving-to-usage-based-billing/) · [Copilot plans](https://github.com/features/copilot/plans) ·
[Jules limits & plans](https://jules.google/docs/usage-limits/) · [SiliconANGLE — Jules free/paid](https://siliconangle.com/2025/08/06/google-makes-jules-ai-coding-agent-available-everyone-free-paid-plans/) ·
[tech-insider — Factory $150M Series C (2026)](https://tech-insider.org/factory-ai-150-million-series-c-khosla-coding-droids-2026/) ·
[Digital Applied — AI coding tool pricing shake-up (June 2026)](https://www.digitalapplied.com/blog/ai-coding-tool-pricing-june-2026-seat-economics-guide).

**Positioning signal.** Every commercial player prices for **organizations** — per-seat, per-ACU,
or per-token, with the multi-repo/agent-orchestration features gated behind Business/Enterprise or
higher usage tiers. The **"one person, many personal/side projects"** operator is *underserved* by
this pricing: they want fan-out and rollup but will not pay $40–500/seat/mo per surface. A
self-hosted, bring-your-own-model tool whose only marginal cost is model tokens is the natural home
for that persona — and, notably, for privacy-sensitive / offline / regulated single operators the
cloud tools cannot serve at all.

> ⚠️ **Sourcing caveat.** Several exact figures above (Devin ACU rate, Jules concurrency tiers,
> Factory valuation) come from *secondary aggregators*, not first-party pricing pages, and some
> pages carry marketing-forward phrasing. Re-confirm against vendor pricing pages before quoting in
> any external/commercial context. Factory.ai per-seat pricing was **not found** on a primary source.

---

## Positioning verdict

**The control-plane pattern is mature and the market is converging on our doorstep — but the
specific fusion herdkit targets is still unoccupied, and its most defensible axes are the ones the
incumbents structurally will not copy soon.**

1. **Do not claim to have invented the control plane.** IDPs (Port, Cortex), monorepo graphs (Nx),
   and GitOps fleets own that pattern and its vocabulary. Adopt their lexicon —
   *catalog · dependency graph · scorecards · self-service actions · affected-detection · portfolio
   rollup* — and position herdkit *within* it, per the 2026-07-02 reframe.
2. **The genuinely differentiated claim is narrow and true:** *a persistent, self-hosted,
   terminal-native master coordinator over per-project **autonomous** dev coordinators, with NL
   command dispatch and a cross-project digest, model-flexible and PR/CI-native.* No shipping
   product occupies all of that as-of 2026-07-03.
3. **Where the market already wins — cede it:** parallel-agents-in-the-cloud (everyone),
   fan-a-change-across-1000-repos (Sourcegraph), enterprise governance/reporting (Port, Jellyfish),
   monorepo build orchestration (Nx). Don't fight there.
4. **Defensible moats:** self-hosted/offline · transparent/hackable bash + journal · model-flexible ·
   coordinator-as-primitive · zero-seat economics for the solo-many-projects persona.
5. **Sharpest risks:** **GitHub** (fastest, on dispatch+rollup UX) and **Sourcegraph** (closest
   architecture: NL→fan-out, self-hostable, MCP-delegated). herdkit's insurance against both is the
   axis they won't prioritize: **offline, terminal-native, transparent, single-operator.**

**Net:** herdkit should position as *"the self-hosted, terminal-native control plane for your fleet
of autonomous project coordinators"* — borrowing IDP vocabulary, conceding the cloud/enterprise
surfaces, and defending the offline/transparent/solo-operator ground the incumbents won't contest.

---

## Refresh cadence

- **Cadence:** re-verify **every 6–8 weeks**, and always before a positioning/roadmap/fundraising
  decision. This space ships monthly; treat every claim as expiring.
- **Priority watch-list (the players that could subsume the fusion):** GitHub Mission Control (any
  "org agents / portfolio rollup" GA) · Sourcegraph (persistent per-repo agents / scheduling) ·
  Nx Polygraph (standing orchestrator layer) · Port (per-service standing coordinators) · OSS
  orchestrators (vibe-kanban / Conductor / Claworc / agentsmesh adding per-project coordinators +
  cross-project digest).
- **How to refresh:** re-run the six queries live (do **not** answer from model memory — training
  cutoff ~Jan 2026 is stale for this topic); update as-of dates; prefer first-party sources over
  aggregators; explicitly note anything that could not be verified rather than filling from memory.
- **Known gaps in this pass (fill next refresh):** Factory.ai primary pricing; Humanitec/OpsLevel
  agent-orchestration specifics; Jira Advanced Roadmaps agent-dispatch status; primary-source
  confirmation of Nx Polygraph cross-repo-PR mechanics (headline confirmed, article body not
  fetched).
