# herdkit North Star: Project Direction and Vision

## Purpose

This document articulates the long-term direction, architectural principles, and success criteria for herdkit as a multi-agent orchestration platform. It is the north star for prioritization, scope decisions, and design trade-offs across releases.

## Vision Statement

**herdkit enables durable, autonomous, human-supervised multi-agent workflows that drain backlogs into merged, verified code — unattended, surviving interruptions, and costing less than manual orchestration.**

The project is grounded in three design principles:

1. **Decoupling**: Execution and state are decoupled from session lifetime and operator presence. A builder hitting the usage limit, a coordinator window being closed, or a process killed mid-drain does NOT lose work — the pipeline resumes from where it stopped.

2. **Genericity**: The engine is generic; everything project-specific is read from a per-project `.herd/config`. The same orchestration layer works for herdkit, northstar, and any future multi-agent backlog drain.

3. **Safety by architecture**: Security and correctness are not bolted on after; they are structural. Auto-merge happens only on a PR that is mergeable + clean, healthcheck-green, AND review-passed. All gates are re-verified in the instant before merge. The pipeline fails closed on ambiguity.

## Core Capabilities (Today)

- **Multi-agent lanes**: Coordinator, feature builders, quick builders, async scribe, research, resolver, review, watcher.
- **Durable state**: Append-only engine journal (`journal.jsonl`), worktree snapshots, per-item gate history for forensics.
- **Limit-aware execution**: When a builder hits the account usage limit, the watcher parks it with a resume timestamp and auto-relaunches at the reset time.
- **Safety gates**: Healthcheck + adversarial pre-merge review + instant-before-merge re-verification.
- **Cost measurement**: Per-PR and cost-per-merged-PR accounting via `herd cost`.
- **Multi-operator support** (opt-in): Atomic pre-spawn claims, tracked-spawn enforcement, team-mode auto-merge scoping, and shared config propagation.
- **Sandbox test rig**: Hermetic, zero-quota proof that the gate/merge/concurrency/limit-park flow works at scale.

## Roadmap: Priorities and Themes

### 1. **Unattended Reliability** (Current Focus)

The system must survive multi-hour or multi-day drains with minimal human intervention.

**Shipped**:
- Limit-park auto-resume via `rate_limit` hooks and send-keys watcher intelligence.
- Coordinator watchdog for out-of-session coordinator failures.
- Dead-builder detection and surfacing.
- Sandbox sim P0–P2 validation of interrupt-survival and merge correctness.

**Next**:
- Real overnight unattended runs with live limit resets and operator hand-off (the "step 4" benchmarking run).
- Cross-project token governance and global concurrency capping (account-wide limit handling across N projects).
- Coordinator externalized work queue so a coordinator pause doesn't block mechanical throughput.

### 2. **Multi-Project Orchestration** (Fleet Coordinator - P0-P4 Shipped, Polish Ongoing)

A single human can operate N herdkit projects (e.g., herdkit + northstar) from one meta-workspace.

**Shipped**:
- Project registry and `herd fleet` CLI (register/list/status/upgrade/reload).
- Cross-project digest, standup, and attention inbox.
- NL master coordinator and fleet control room.
- Relationship graph and policy propagation (e.g., set `MERGE_POLICY` across all projects).

**Next**:
- Validate multi-project token governance and interrupt-survival at scale.
- NL routing refinements (improved intent-to-project mapping).
- Fleet cost reporting and cross-project budget tracking.

### 3. **Cost and Efficiency** (Instrumentation Complete, Optimizations Ongoing)

Every stage of the pipeline is measurable; major redundancies are eliminated.

**Shipped**:
- Per-builder and per-review token accounting.
- Flow-audit findings doc and follow-up efficiency levers.
- Risk-tiered review (skip low-risk diffs, escalate high-risk ones).
- Healthcheck profiles (light vs. heavy per-file-path).
- Cost-per-merged-PR tracking and cross-session aggregation.

**Next**:
- Auto-tuning of `REVIEW_CONCURRENCY`, `HEALTH_CONCURRENCY`, and per-PR model tier based on live cost/wall-clock metrics.
- Eliminate manufactured transient flakes (the sha-cache fix is one instance; audit for others).
- Pareto-optimal gate sequencing (don't run review on a diff that will healthcheck-BLOCK anyway).

### 4. **External-Consumer Onboarding** (P1-P4 Shipped; Integration Complete)

The engine is reusable; non-herdkit teams can adopt it.

**Shipped**:
- Language-agnostic healthcheck templates (Go, Rust, Java, Python, etc.).
- De-Streamlit/de-Python documentation and copy.
- De-branding machinery (whitelabel the `herdkit` name and install source).
- Driver abstraction for non-herdr/non-Claude runtimes (machines ready; second driver awaits a customer).
- Phase-4 audit findings document and integration validation.

**Next**:
- Real external-team dogfood (a second customer or internal team using the engine).
- Hardening edge cases from live multi-stack usage.
- Docstring and template improvements driven by real onboarding friction.

### 5. **Architectural Resilience** (Ongoing)

The system must be debuggable, resilient to edge cases, and provably correct.

**Shipped**:
- Deterministic codemap and symbol index (bash-native, zero-quota, diff-reviewable).
- Control-room map and connector-seam documentation.
- Engine-journal forensics (`herd why`, `herd log`, `herd status`).
- Sandbox sim P0–P2 hermetic proof of correctness.

**Next**:
- Live replication scenarios (e.g., what happens if the watcher crashes mid-merge, or the scribe gets stuck).
- Distributed, multi-workspace state coherence (does the master coordinator's journal stay in sync with per-project coordinators).
- Formal correctness proofs for the auto-merge gate sequence (a theorem, not just tests).

## Success Criteria

1. **Unattended overnight drain**: An N-item backlog drains to merged PRs with zero human intervention, surviving ≥2 account usage limit resets and a coordinated kill/restart cycle mid-drain, with zero duplicate merges.

2. **Multi-project at scale**: Five projects orchestrated from one master coordinator; `herd fleet` commands complete in <10s; cross-project digest generated correctly; token governance prevents any single project starving others.

3. **Cost below manual**: For the same N-PR backlog, `herd cost` totals <50% of the cost to manually build each PR with a full strong review.

4. **External adoption**: A second team (non-herdkit, non-northstar) successfully runs herdkit on their own repo with <1 day of integration time; no code changes to herdkit required.

5. **Debuggability**: An operator can run `herd why <pr#>` and understand every gate decision, timing, and outcome without reading source code.

## Design Constraints

- **No silent data loss**: If execution is interrupted, state is never lost. Resume-from-disk must be byte-identical to a non-interrupted run (determinism).
- **Fail closed on ambiguity**: Any gate that cannot reach a definitive verdict must BLOCK, never PASS.
- **No unauthorized writes**: The coordinator owns the backlog and tracker. No builder or lane script mutates the tracker state (claims/labels/assignee).
- **Session-independent resumability**: A session can be killed and restarted; the pipeline drains identically.
- **Per-project isolation**: One project's over-concurrency or budget overrun must not cascade to others.

## Temporal Roadmap

| Phase | Theme | Horizon | Prerequisite |
|-------|-------|---------|--------------|
| **Now** | Unattended reliability + real overnight validation | 2–4 weeks | Limit-auto-resume + coordinator watchdog (🚧 ships soon) |
| **Soon** | Fleet polish + multi-project token governance | 4–8 weeks | Unattended overnight results (confidence-building) |
| **Later** | Cost optimization + auto-tuning | 8–16 weeks | Cost instrumentation (✅ shipped); flow audit findings (foundation) |
| **After** | External adoption + hardened edge cases | 16+ weeks | A real second customer or team onboard |
| **Someday** | Distributed state coherence + formal correctness | Open | Strong demand signal from multi-team operations |

## Relation to Competitors

- **vs. Raw Claude/Harness**: herdkit decouples execution from session lifetime; the harness cannot. Unattended operation over hours/days is unique to herdkit.
- **vs. GitHub Actions**: Actions are event-driven; herdkit is backlog-driven and durable. An Actions workflow that hits the usage limit cannot pause and resume cleanly.
- **vs. IDPs (Backstage, etc.)**: IDPs manage *infrastructure* provisioning; herdkit manages *code* workflows. Complementary, not competitive.

## Open Questions

1. **Is the sandbox sim fidelity enough?** Will a real overnight run reveal behaviors the P0–P2 scenarios miss? (To be answered by Step 4: real overnight run.)
2. **How much do multi-project teams care about token governance?** Is "total concurrency across all projects" the right lever, or should it be per-model or per-review-type? (To be answered by external-team feedback.)
3. **Can the engine scale to 50+ items in flight?** Do performance cliffs appear as the watcher tick loop gets more PR-checks? (To be measured in the herdkit-vs-harness EPIC.)
4. **What breaks first under real 24/7 operation?** Is it a limit-resume edge case, a flake in the merge gate, or something unforeseen? (To be learned from the overnight benchmark run.)

## Stakeholders & Ownership

- **Operator/SRE**: Uses `herd` CLI, reads journals, approves human-verify PRs, tunes config.
- **Coordinator**: An LLM agent owning backlog, dispatch, and orchestration logic.
- **Builders**: Isolated agent processes, each working in a worktree.
- **Watcher**: Detached process, polls gate state, merges, resurfaces failures.
- **Engine maintainers**: Fix bugs, ship efficiency/reliability improvements, validate with the sandbox sim.

---

This north star is the source of truth for herdkit's direction. It evolves quarterly based on live usage, unblock research, and architectural discoveries. The backlog, PRs, and issue tracker are subordinate to this document — they implement it, but they do not override it.
