<!-- Provenance: builder doc for HERD-740, child of EPIC HERD-737, 2026-08-13. Committed as durable
     evidence — the full two-round Sol × Fable advisory exchange, the negotiated month plan, and the
     streak scorecard for the weeks-2-3 trial, so the program survives session boundaries. -->

> **Date:** 2026-08-13
> **Scope:** HERD-740 — commit the advisor record + synthesized month plan + streak scorecard for
> the Governance & Proof month ([HERD-737](https://linear.app/brian-keegan/issue/HERD-737),
> operator-approved 2026-08-13).
> **Advisors:** **Sol** = `gpt-5.6-sol`, run via codex. **Fable** = `claude-fable-5`. Each was given
> the same brief independently (round 1), then shown the other's round-1 memo and asked to sharpen,
> concede, or defend (round 2). All four memos below are reproduced **verbatim** from the source
> transcripts.
> **Children:** [HERD-738](https://linear.app/brian-keegan/issue/HERD-738) (budget governance),
> [HERD-739](https://linear.app/brian-keegan/issue/HERD-739) (outcome ledger MVP) — the other two
> week-1 build items under this EPIC. This document is the third week-1 child.

---

## 1. The brief

The brief given to both advisors, independently and without seeing each other's answer.

> # herdkit advisor brief — 2026-08-13
>
> You are advising the operator of **herdkit**, an open-source agentic engineering engine
> (bash+python core, Claude Code / codex / grok driver seam) that drains a work tracker into
> isolated builder agents, gates every change behind healthcheck + adversarial LLM review,
> auto-merges, reconciles the tracker, and heals itself. It is developed by running itself.
>
> ## Where it stands (all verified live, last 30h)
> - 31 PRs item→spawn→build→CI→review→merge→reconcile with ~4 human judgment interventions; 999
>   merges lifetime in 46 days; a sibling consumer project (emberglen-godot, a Godot game, 2
>   operators on 2 machines, 587 merges/15 days, 10 domain-specialist agents) runs the same engine
>   with a local Godot gate instead of GitHub CI.
> - Shipped this week: specialist agent roster (committed definitions, empirical sentinel verify
>   with negative control, big-3 driver bindings incl. prompt-injection fallback, roster pane);
>   multi-operator ownership contract (AUTOFIX_SCOPE own-default on every branch-writing rail); CI
>   diff-scoping + shard right-sizing (21m → 8-12m, docs PRs → lint-only); maintenance gardener
>   (weekly trigger diffs merges vs docs, files its own rollup backlog items — its first real finding
>   already shipped as a PR); gh rate-limit hardening (right-bucket backoff, pooled reads, idle
>   cadence); health-suite provable in-flight identity (adopt-or-reap); spawn-driver-aware liveness
>   for mixed-runtime fleets.
> - Failure culture: every rail failure observed live became a merged engine fix within hours, built
>   by the pipeline that exhibited the failure.
>
> ## Known gaps / candidate directions (operator + coordinator analysis)
> A. INTENT_QUEUE + published plan (herd queue plan) exists but is OFF in herdkit's own repo —
>    coordinator still hand-sequences between turns. SPAWN_AHEAD=1.
> B. BUDGET_DAILY unset everywhere — last night ran $353 with no ceiling.
> C. The "fully autonomous" claim is unscored: the zero-hand-nudge unattended streak metric has
>    never been formally run (a week-long scored streak was the old north-star test).
> D. TEAM_PRESENCE off in herdkit itself despite a second operator claiming items.
> E. Work-unit abstraction (beyond PR-shaped work: doc-apply adapter exists, design doc committed)
>    is early — the "general autonomous-operations engine" thesis is directional, not proven.
> F. Moat analysis (2026-07): native Claude Code absorbed parallel worktrees/orchestration/review;
>    herdkit's moat = usage-limit auto-resume + no-cloud daemon + concurrency governance + now
>    multi-operator/multi-runtime + self-maintenance. Roadmap doc has: packaging/artifact
>    abstraction, rubric primitive, clinical wedge; Jira guide shipped, Forge app gated on adoption.
> G. Coordinator seat is still a live LLM session holding strategy/judgment; the engine executes and
>    heals. Coordinator startup was profiled (125KB rendered skill; state reads fixed).
> H. Scale ceilings are external: one machine, per-user gh API budgets, GitHub 5-slot macOS runner
>    cap.
> I. Review quality: Opus adversarial review caught 2 real correctness bugs this week; review is the
>    cost + latency center after CI.
>
> ## Your task
> As an independent advisor: (1) rank the FIVE highest-leverage improvements for herdkit over the
> next month, each with a one-paragraph rationale grounded in the brief; (2) name the biggest risk
> or blind spot the operator is not seeing; (3) name one thing you would explicitly NOT do despite
> it seeming attractive. Be opinionated and concrete; disagree with the brief's own framing where
> warranted. Keep it under 700 words.

---

## 2. Round 1 — independent memos

### 2a. Sol (`gpt-5.6-sol`, via codex) — round 1

> ## Top five improvements for the next month
>
> 1. **Run a scored, seven-day unattended production trial.**
>    This is the missing proof, and it should outrank more feature work. Freeze discretionary
>    improvements, enable `INTENT_QUEUE`, publish the plan, and define success before starting: zero
>    human nudges, no incorrect merges, bounded recovery time, tracker consistency, and spend below
>    a fixed ceiling. Classify every intervention as safety judgment, product judgment,
>    infrastructure recovery, or mere convenience. The current evidence proves impressive throughput
>    with low intervention; it does not yet prove autonomy.
>
> 2. **Install hard economic governance immediately.**
>    A $353 uncapped night is not a configuration omission—it is a control-system failure. Set
>    `BUDGET_DAILY` everywhere, plus per-item and per-rail limits, forecast-at-completion, and
>    automatic degradation: reduce concurrency, switch model tier, postpone noncritical review, then
>    stop safely. Measure dollars per accepted change, per reverted change, and per autonomous hour.
>    Usage-limit auto-resume is only a moat if the system cannot autonomously resume itself into an
>    uncontrolled bill.
>
> 3. **Remove strategy from the live coordinator session.**
>    Turn on `INTENT_QUEUE` in herdkit itself and make sequencing reproducible from committed policy
>    and state. The coordinator should supply exceptional judgment, not retain the operating plan in
>    conversational context. Add explicit priority, dependency, risk class, maximum spend, and
>    “requires human judgment” fields to queued intent. Then test coordinator replacement mid-run.
>    If a fresh session cannot reconstruct and continue operations reliably, the system still has an
>    undocumented human-shaped component.
>
> 4. **Build an outcome ledger, not a larger throughput dashboard.**
>    The headline numbers—999 merges, 31 recent PRs—are strong but dangerously easy to optimize.
>    Track post-merge defects, reversions, escaped regressions, duplicate work, time-to-detection,
>    maintenance burden created, and whether each change advanced a declared objective. Include
>    delayed evaluation at 24 hours and seven days. The gardener is valuable here: it should detect
>    not only documentation drift but low-value churn and recurring architectural debt. The
>    north-star should become valuable, durable outcomes per dollar—not merges.
>
> 5. **Turn adversarial review into a calibrated risk system.**
>    Opus caught two real bugs, so eliminating expensive review would be reckless. Instead, collect
>    reviewer findings and label true positives, false positives, severity, file type, and whether CI
>    could have caught them. Use that evidence to route low-risk changes through cheaper models or
>    deterministic checks while retaining Opus for concurrency, state reconciliation, security
>    boundaries, and branch-writing rails. Run occasional shadow reviews to detect quality decay.
>    This attacks the main latency/cost center without weakening the gate blindly.
>
> ## Biggest blind spot
>
> **Herdkit may be proving that it can produce and repair changes faster than it is proving those
> changes are worth producing.** Self-development creates a closed evaluation loop: the same system
> proposes work, implements it, reviews it, records the merge, and treats failures as new work. That
> can generate genuine improvement—but also a convincing perpetual-motion merge factory. The sibling
> project broadens the evidence, yet both deployments remain unusually automation-friendly and
> operator-coupled. Independent outcome evaluation and a deliberately boring unattended period would
> be more revealing than another hundred merges.
>
> ## What I would explicitly not do
>
> **Do not pursue the general work-unit abstraction or “autonomous-operations engine” positioning
> next month.** Packaging, clinical workflows, Forge integrations, and non-PR adapters are
> attractive expansion surfaces, but they multiply failure semantics before the core autonomy,
> economics, and outcome quality are measured. Keep PR-shaped engineering as the product boundary
> until herdkit can pass the scored unattended trial with bounded spend and demonstrate that its
> merges produce durable value.

### 2b. Fable (`claude-fable-5`) — round 1

> ## Five highest-leverage moves (ranked)
>
> **1. Set BUDGET_DAILY today, then build budget-aware scheduling.** A $353 uncapped night is the
> single fact in this brief that can end the project — not gradually, but in one bad loop where the
> gardener files items, builders drain them, and review bills Opus on all of it. You've built a
> self-feeding work generator (gardener → backlog → auto-merge) with no economic governor. A hard
> ceiling is an afternoon of work; the month-scale version — spend attribution per work item, and
> the daemon degrading gracefully (defer low-priority items, drop to cheaper review tiers) as the
> budget drains — is also a genuine moat piece. "Concurrency governance" without cost governance is
> half a governor.
>
> **2. Run the scored zero-nudge streak, for real, for a week.** Item C is the whole thesis sitting
> unmeasured. Everything else in the brief is evidence of throughput; nothing is evidence of
> autonomy. Running it also forces the right engineering in the right order: the streak definition
> makes hand-sequencing count as a nudge, which forces item A (INTENT_QUEUE on in herdkit's own
> repo, SPAWN_AHEAD above 1) and item D (TEAM_PRESENCE on, since a second operator claiming items
> during the streak is otherwise a confound). Treat A and D as streak prerequisites, not separate
> projects. If the streak fails at day 2, that failure is the highest-value roadmap input you can
> get this month.
>
> **3. Turn on the queue in your own repo before shipping anything else coordinator-shaped.** Called
> out separately from #2 because it's a credibility issue, not just a prerequisite: herdkit's pitch
> is "developed by running itself," and the most strategic subsystem — planned intent — is off at
> home. Whatever friction kept it off is the exact friction adopters will hit. Find it, fix it,
> write it down.
>
> **4. Tier the review gate the way you tiered CI.** Diff-scoping took CI from 21m to 8–12m and docs
> PRs to lint-only; review, now the cost and latency center, has no equivalent. Opus catching 2 real
> correctness bugs this week says don't weaken it — it says spend it where it pays. Cheap-model
> triage classifies diffs by risk (touched rails, concurrency, auth-adjacent paths → full
> adversarial Opus; mechanical/docs/test-only → light pass), and the negative-control sentinel
> technique you already built for specialist verification can validate that the triage tier isn't
> sleeping.
>
> **5. Put one non-PR work-unit into live production use.** The doc-apply adapter exists as a design
> doc plus early code; the "general autonomous-operations engine" thesis stays directional until one
> non-code pipeline runs unattended somewhere real — even something small, like the gardener's
> rollup docs flowing through doc-apply in herdkit itself. One live instance beats any amount of
> abstraction work, and it's the cheapest possible test of whether the work-unit seam is right
> before you build packaging on top of it.
>
> ## The blind spot
>
> Nothing in the loop measures whether the work was worth doing. Every gate you've built —
> healthcheck, adversarial review, reconciliation — scores *correctness*; none scores *value*. "999
> merges in 46 days" is a throughput number, and now the gardener generates its own backlog, meaning
> the system can autonomously produce, approve, and merge plausible-but-marginal work indefinitely,
> and every metric you track will call that success. The ~4 human interventions per 31 PRs are
> probably where value judgment actually lives, and the brief frames them as residue to eliminate
> rather than the scarcest input to instrument. Before chasing zero nudges, define what the
> coordinator seat is *for* — because the streak metric, taken alone, rewards removing exactly the
> judgment that makes the merges matter.
>
> ## What I would not do
>
> Don't attack the scale ceilings (multi-machine, runner caps, API budgets — item H), even though
> it's the most engineering-attractive item on the list. Throughput is demonstrably not your
> constraint: you merge faster than you can verify value, and cost is uncapped. Scaling out
> multiplies an unmetered spend rate and an unscored autonomy claim across more hardware. Same
> logic, secondarily, for the Forge app and clinical wedge — you correctly gated those on adoption;
> hold that gate. The month belongs to governance and proof, not capacity.

---

## 3. Round 2 — rebuttals

Each advisor was shown the other's round-1 memo and asked to sharpen, concede, or defend.

### 3a. Sol (`gpt-5.6-sol`, via codex) — round 2

> Fable sharpens my position in three ways. First, budget governance is not merely co-equal with
> the streak: the hard ceiling is a day-zero safety prerequisite. Second, `INTENT_QUEUE` and
> `TEAM_PRESENCE` should be treated as streak infrastructure, not independent roadmap projects.
> Third, human interventions should be measured for the value judgment they contribute—not simply
> counted as autonomy failures. A zero-nudge run that eliminates useful judgment could score well
> while producing worse work.
>
> I concede the disagreement, narrowly. One live gardener-rollup flow through `doc-apply` is not
> “work-unit expansion” in the roadmap sense; it is an internal seam test using an existing adapter.
> That evidence could prevent months of abstraction built around the wrong contract. I would permit
> exactly one bounded production instance, with:
>
> - No external customer or irreversible side effects
> - A dedicated daily and per-run spend cap
> - Deterministic rollback to the current PR path
> - Explicit correctness, latency, intervention, and cost criteria
> - No adapter framework, packaging, Forge work, or second use case this month
>
> If it starts generating generalization work, stop. The exception tests the seam; it does not
> broaden the product boundary.
>
> Ordering is now clear:
>
> **Week 1:** Set `BUDGET_DAILY` immediately, add per-item limits and safe-stop behavior, define the
> streak scorecard, enable and exercise `INTENT_QUEUE`, turn on presence tracking, ship the minimum
> ledger, and run the bounded `doc-apply` seam test. Freeze other discretionary work. Week 1 is
> instrumentation and qualification—not the streak.
>
> **Weeks 2–3:** Lock configuration and run the seven consecutive production days. No feature changes
> during the run. Budget-triggered degradation is valid autonomous behavior; manual budget rescue is
> an intervention. If the run fails, preserve the evidence rather than resetting the clock
> invisibly.
>
> **Week 4:** Analyze failures and reviewer economics, then make only evidence-driven changes. Review
> tiering follows collected labels.
>
> The one-week minimum viable outcome ledger is a committed append-only record—SQLite or JSONL, not
> a new dashboard—with one row per intent/work unit containing:
>
> - Stable ID, declared objective, requester/source
> - Risk class, expected value, acceptance test
> - Start/end time, models used, token and dollar cost
> - Human interventions, categorized with reason
> - Review findings and CI outcome
> - Final disposition: accepted, rejected, reverted, duplicate, abandoned
> - Production signals at merge, +24 hours, and +7 days
> - Defect/reversion links and evaluator judgment: valuable, neutral, harmful, or unknown
>
> Ship three outputs: a CLI summary of cost and outcomes, a daily Markdown report, and alerts for
> missing evaluations, reversions, budget breaches, or “unknown” value. No elaborate UI. The
> ledger’s first job is to make marginal autonomous work visible.

### 3b. Fable (`claude-fable-5`) — round 2

> **1. Where Sol sharpens my position.** Four places. The intervention taxonomy (safety / product /
> infra-recovery / convenience) is strictly better than my "instrument the interventions" — it
> converts nudges from failures-to-eliminate into labeled data, which is what I was gesturing at
> without operationalizing. The mid-run coordinator-replacement test is the falsifiable version of
> my item 3: "queue on at home" proves configuration; "a fresh session continues operations" proves
> the plan actually lives in committed state. The explicit degradation ladder (reduce concurrency →
> cheaper tier → postpone review → safe stop) is more buildable than my "degrade gracefully." And on
> review tiering, Sol correctly inserts a step I skipped: label the findings Opus is already
> producing *before* routing by risk class, so the triage tiers are calibrated on evidence rather
> than my guesses about which paths are dangerous. I adopt all four.
>
> **2. The disagreement: concede timing, defend the item.** Sol is right that nothing new runs
> during the trial week — a doc-apply rollout mid-streak confounds the very measurement we both rank
> first, and I concede that cleanly. But a month-long ban is the wrong lesson from the right
> instinct. Sol treats all expansion surfaces as equivalent; they aren't. Forge and clinical
> multiply *external* failure semantics — hold that gate. Gardener rollups through doc-apply are
> work the system already does, in a repo we control, with a failure mode of one revertible docs
> commit. Crucially, a month of PR-only success generates zero evidence about whether the work-unit
> seam is right — and the seam is the thesis. The cheapest time to discover it's wrong is before
> packaging exists on top of it. So: trial passes → week 3, doc-apply goes live on rollups only,
> budget-capped, inside the ledger. If the trial fails, Sol wins by default — everything waits.
>
> **3. One mechanism: an outcome ledger where interventions are the labels.** These aren't rival
> proposals; one is the store, the other is the ground truth. Build Sol's per-work-item ledger —
> declared objective, spend, delayed re-evaluation at 24 hours and 7 days, reversions, defects traced
> back. Then log every human intervention as a first-class ledger entry, classified by Sol's taxonomy
> and attached to the items it touched. The interventions become the value labels that calibrate
> everything automated: if the four monthly nudges cluster on items the ledger scored as fine, the
> automated scoring is blind exactly where I feared. One table, two write paths, and the streak
> metric stops rewarding the deletion of judgment — a convenience-class intervention counts against
> autonomy, a product-judgment intervention counts as signal the system failed to surface a decision.
>
> **4. The single week-1 action: set BUDGET_DAILY everywhere, with safe-stop, today.** Not because
> it beats the trial in importance, but because it's ordered first by necessity: "spend below a
> fixed ceiling" is a line in Sol's own trial scorecard, so the ceiling is a trial prerequisite — and
> it's the only item on either list where one bad night ends the project before any measurement
> matters. An afternoon of work removes the tail risk; everything else survives being a week late.

---

## 4. Synthesized month plan

Both advisors converged in round 2. This is the negotiated plan, not either advisor's initial
ranking: the month is **governance and proof**, not capacity or expansion — throughput
(999 merges / 46 days) is already demonstrated; autonomy, economics, and outcome value are not.

### Week 1 — instrumentation and qualification (not the streak)

Freeze discretionary feature work. Build, in this order of necessity:

- **(a) Budget governance** — `BUDGET_DAILY` + per-item cap + a degradation ladder (reduce
  concurrency → cheaper review tier → postpone non-critical dispatch → safe-stop) + safe-stop
  everywhere, journaled at every rung. This is the day-zero prerequisite: a $353 uncapped night is
  the one fact in the brief that ends the project outright, not gradually. Tracked as
  [HERD-738](https://linear.app/brian-keegan/issue/HERD-738).
- **(b) Outcome ledger MVP** — one committed append-only record (JSONL, not a dashboard) per work
  item: declared objective, risk class, spend, review findings, CI outcome, disposition, and delayed
  re-evaluation at +24h/+7d. Human interventions are logged as first-class entries against this same
  ledger, classified by the taxonomy in §5 below and attached to the item(s) they touched — the
  ledger is the store, the interventions are the ground-truth labels. Tracked as
  [HERD-739](https://linear.app/brian-keegan/issue/HERD-739).
- **(c) Streak infrastructure armed at home** — `INTENT_QUEUE`/`TEAM_PRESENCE`/`SPAWN_AHEAD` are
  streak *prerequisites*, not separate roadmap projects (both advisors converged on this in round
  2): hand-sequencing during the trial counts as a nudge, so the queue must carry priority,
  dependency, risk class, max spend, and "requires human judgment" fields before week 2 starts. The
  streak scorecard (§5) is committed **before** the trial begins, not derived after the fact.

### Weeks 2–3 — the scored seven-day unattended trial

Configuration is locked for seven consecutive days. No feature changes land during the run. Full
scoring definition is §5. Two negotiated rules apply throughout:

- **Budget-triggered degradation is valid autonomous behavior** — the ladder doing its job (dropping
  concurrency, downgrading review tier, postponing non-critical dispatch, or safe-stopping) does
  **not** break the streak.
- **Manual budget rescue is an intervention** — a human overriding a safe-stop the system correctly
  triggered is exactly the kind of avoidable nudge the streak is measuring for.

**Week 3, conditional on the trial still running clean:** exactly one bounded `doc-apply` production
instance — the maintenance gardener's rollup docs flowing through the existing `doc-apply` adapter,
herdkit-internal only — under five guardrails, negotiated in round 2 (Sol proposed them; Fable's
concession narrowed the ban from a month-long freeze to this one bounded exception):

1. No external customer or irreversible side effects.
2. A dedicated daily and per-run spend cap, separate from `BUDGET_DAILY`.
3. Deterministic rollback to the current (human-in-loop) PR path if the instance misbehaves.
4. Explicit, written-down correctness, latency, intervention, and cost criteria — checked, not
   assumed.
5. No adapter framework, no packaging, no Forge work, and no second use case this month. If it
   starts generating generalization work, stop — the exception tests the work-unit seam, it does not
   broaden the product boundary.

If the trial fails at any point, the doc-apply exception does not run — the trial's evidence takes
priority over the seam test (§5, failed-trial rule).

### Week 4 — evidence-driven only

No speculative engineering. Two inputs, both produced by the trial itself:

- **Reviewer economics.** Route review tiering from the *labeled* Opus findings collected during the
  trial (true positive / false positive / severity / file type / CI-catchable) — label first, route
  second, exactly as both advisors converged on. Do not guess which paths are dangerous; the trial
  produced the evidence.
- **Failure analysis.** Whatever broke the streak (or, if it passed clean, whatever the ledger's
  delayed +24h/+7d evaluations surface) becomes the next month's input — not a fresh brainstorm.

### Explicitly not this month

Both advisors independently named the same "attractive but wrong" items, and converged on all of
them in round 2:

- **Multi-machine scale-out / runner-cap engineering** (brief item H) — throughput is not the
  constraint; the system already merges faster than it can verify value, and cost is uncapped.
  Scaling out multiplies an unmetered spend rate and an unscored autonomy claim across more
  hardware.
- **The Forge app** and the **clinical wedge** — correctly gated on adoption already; hold that
  gate.
- **The general work-unit abstraction / "autonomous-operations engine" positioning**, and **a second
  work-unit adapter** — the one narrow exception is the bounded `doc-apply` seam test above; nothing
  broader. Packaging or a second adapter before the trial has run would multiply failure semantics
  before autonomy, economics, and outcome quality are measured.

---

## 5. Streak scorecard — weeks 2–3 trial

This is the precise, pre-committed definition of the scored unattended trial referenced throughout
§4. It is committed **before** the trial starts, per both advisors' round-2 agreement that the
scorecard must exist ahead of the run, not be reconstructed afterward to fit what happened.

### 5.1 Trial window

**Seven consecutive calendar days**, with configuration **locked** for the full window: no feature
merges, no config changes to gate/concurrency/budget/queue behavior, no manual backlog
re-sequencing. `INTENT_QUEUE`, `TEAM_PRESENCE`, and `SPAWN_AHEAD>1` must already be live and
exercised from week 1 — turning them on mid-trial is itself a configuration change and would void
the run.

### 5.2 Pass criteria

The trial **passes** only if every one of the following holds for all seven days:

1. **Zero convenience-or-avoidable interventions**, per the taxonomy in §5.3.
2. **No incorrect merges** — no merge later reverted for a defect, no merge that violated a
   documented design invariant (ship-dormant, byte-identical-when-off, fail-soft, or any other
   `AGENTS.md` invariant), and no merge the outcome ledger's own review-findings/CI-outcome fields
   contradict at merge time.
3. **Recovery from any rail failure within its own existing budget** — every rail (health probes,
   drainer liveness, spawn-gate, CI retry, etc.) already has a configured timeout/retry window; a
   rail that self-heals but blows past its *own* configured window, or that requires a human nudge
   to finish recovering, fails this criterion. No new recovery-window numbers are invented for the
   trial — the rail's existing contract is the bar.
4. **Total spend under `BUDGET_DAILY` every day** — checked against the ledger's daily cost
   summary, not estimated.
5. **Tracker consistent at every daily audit** — every PR merged that day is reconciled to its
   correct tracker state by the next daily audit, with no orphaned, duplicate, or stuck-mid-state
   items.

### 5.3 Intervention taxonomy

Every human touch to the pipeline during the trial window is logged as a first-class outcome-ledger
entry (per §4b / HERD-739) and classified into exactly one of four categories. Only two of the four
break the streak.

| Category | Definition | Example | Breaks the streak? |
|---|---|---|---|
| **Safety** | Stops or prevents an unsafe, destructive, or irreversible action. | Operator kills a builder about to force-push over a protected branch, or aborts a rail mid-action after detecting state corruption. | **No** — always legitimate; logged, not counted as failure. |
| **Product** | Supplies a judgment call about *value* or *objective* that the system had no committed policy to derive on its own. | Operator picks between two valid architectural approaches an ambiguous backlog item left open. | **No**, but it is flagged in the ledger as "system failed to surface a decision" — a week-4 input, not a pass/fail gate. |
| **Infra-recovery (unavoidable)** | Recovers from an external/infrastructure fault for which **no automated recovery path exists**. | An empty-commit retrigger during a GitHub Actions "Service Unavailable" outage (the wedged-run playbook — no autofix covers `ci-log-unreadable` by design). | **No.** |
| **Infra-recovery (avoidable)** | Recovers from a fault for which an automated recovery path **does exist**, but a human acted manually instead of letting it run. | Operator manually re-runs a healthcheck that the health-serialize retry would have re-run itself within its window. | **Yes** — counts as an avoidable intervention. |
| **Convenience** | A nudge that was not forced by safety, an undocumented policy gap, or an infra fault — it only saves time or matches a preference. | Operator manually re-orders the intent queue, manually approves a PR that would have auto-merged shortly, or performs a **manual budget rescue** overriding a correctly-triggered safe-stop. | **Yes** — always counts against the streak. |

"Zero convenience-or-avoidable interventions" (criterion 1 above) means: zero rows classified
**convenience**, and zero rows classified **infra-recovery (avoidable)**. Safety and product rows
are logged and reviewed but do not fail the trial by themselves.

### 5.4 Mid-run coordinator-replacement test

A falsifiable test of whether the plan genuinely lives in committed state rather than in the live
coordinator session's conversational context (Sol round 1 item 3; Fable round 2 confirms it as the
sharper version of the same claim). Procedure, scheduled in advance (not reactive to a failure):

1. On a predetermined day inside the seven-day window (day 3 or 4), the operator terminates the live
   coordinator session with **no handoff message and no context transfer** — the session simply
   ends.
2. A brand-new coordinator session is started cold, with access to nothing but committed state:
   the tracker, `INTENT_QUEUE`, `BACKLOG.md`, the engine journal, and committed docs — no prior
   conversation.
3. The fresh session's normal on-invocation orientation (its state-read step) must reconstruct the
   current plan and continue draining/sequencing queued work **without operator narration**.
4. **Pass:** the fresh session picks up from committed state alone and continues normal operation.
   **Fail:** the fresh session requires the operator to explain what was happening or re-derive
   strategy conversationally — that need-to-explain is itself logged as a **product** (at best) or
   **convenience** (if it was just habit rather than a genuine gap) intervention, scored per §5.3.

### 5.5 Failed-trial evidence-preservation rule

If any pass criterion in §5.2 is violated at any point in the seven days, the trial **stops being
scored as passing at that point** — but the clock is never silently reset and a fresh run never
started invisibly. Instead:

1. The specific day, the criterion that broke, and the classification (§5.3) are recorded.
2. Full evidence — the relevant journal excerpt, cost events, and PR/commit refs — is committed to a
   dated `docs/audits/` entry **before** any new attempt starts.
3. A new seven-day clock may only begin after that evidence is committed; the failure itself becomes
   week-4 input (§4), not a discarded false start. A failed trial is data, not a do-over.

---

## 6. Cross-links

- **EPIC:** [HERD-737](https://linear.app/brian-keegan/issue/HERD-737) — Governance & Proof month
  (Sol × Fable advisor plan, 2026-08-13).
- **Week-1 sibling children:**
  [HERD-738](https://linear.app/brian-keegan/issue/HERD-738) — budget governance
  (`BUDGET_DAILY`, per-item cap, degradation ladder, safe-stop).
  [HERD-739](https://linear.app/brian-keegan/issue/HERD-739) — outcome ledger MVP (per-item value
  record, interventions as labeled entries).
- **This item:** [HERD-740](https://linear.app/brian-keegan/issue/HERD-740) — this document.
