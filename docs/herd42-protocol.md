# HERD-42 experiment protocol — herdkit vs. a well-run bare harness (the A/B)

> **Status:** design-frozen for the run committed to **2026-07-10**. This is step 5 of the
> falsification EPIC (see `docs/positioning-thesis.md` for step 1 and `scripts/herd/sim/` for the
> stub-mode benchmark, step 3). Scope is closed: this document specifies exactly one A/B run and the
> deterministic scoring for it — no open-ended follow-ons.
>
> **The deterministic judge is `scripts/herd/experiment/herd42-score.sh`.** Its verdict rules
> (§7–§8) are committed here **in advance** so the result cannot be re-argued after the numbers land.

## 1. The claim under test

herdkit's thesis (`docs/positioning-thesis.md`) is narrow and falsifiable: **herdkit ships more
merged work per unit of operator time because execution and state are decoupled from session
lifetime and operator presence** — the raw harness cannot do this architecturally, because a single
Workflow/session invocation dies with its session. The one workload that forces the difference is
*drain a backlog, unattended, across a usage-limit window*: the moment a bare session parks on a
usage limit with the operator away, its execution and its memory of what was done both vanish.

This A/B tests that claim on a **real** workload with **real-model** builders on both arms.

## 2. The two arms

Both arms drain the **same task set** (§3) against the **same fixed acceptance suite** (§5), and
both must span at least one **usage-limit window** (§6) so limit-park / auto-resume is exercised.

- **Arm H — herdkit.** The full engine: coordinator + watcher, worktree-per-task builders, the
  pre-merge review gate, auto-merge, and usage-limit auto-resume. Unattended after hand-off.
- **Arm B — bare harness, used WELL (steelman, not strawman).** Native Claude Code driven by a
  competent operator using its own best primitives: git worktrees for isolation, Workflow /
  subagents for parallel fan-out, and its own review flow (e.g. `/code-review`) before merge. The
  operator is allowed every native affordance. What Arm B is **not** given is any herdkit script,
  journal, cost summer, watcher, or auto-resume daemon — that is the architectural difference being
  measured, and lending it across would confound the result.

The point of steelmanning Arm B is honesty: if herdkit only wins against a hobbled baseline, it does
not win. Arm B must be run by an operator who genuinely knows the native harness.

## 3. The task set — drawn from a CONSUMER-shaped project

The tasks are drawn from the **sandbox consumer sim fixture** — the throwaway "real app + seeded
backlog" project the fidelity ladder culminates in (`scripts/herd/sim/sandbox-fixture.sh`,
`README-sandbox-sim.md`), driven here by **real-model builders** (the ladder's final rung), **not**
herdkit-on-herdkit.

**Why not herdkit-on-herdkit.** Running the A/B on the herdkit repo itself confounds the result: the
engine would be both the tool under test and the codebase under change, and its conventions
(BACKLOG.md, `.herd/`, the gate scripts) would advantage the arm that already speaks them. A neutral
consumer-shaped fixture is a fair board for both arms.

**Task set requirements:**

- **8–12 tasks**, each a self-contained change to the fixture app (feature, fix, or refactor) with a
  clear, pre-written acceptance check (§5). Small enough that a competent builder finishes one in a
  bounded session; varied enough that throughput is meaningful.
- **Frozen before the run.** The exact task list, wording, and acceptance suite are committed to the
  fixture and are **byte-identical** for both arms. Neither operator may edit tasks mid-run.
- **No task depends on herdkit-specific conventions.** A task is phrased as "make the app do X,
  verified by acceptance check Y" — never "update BACKLOG.md" or "emit a journal event."
- **Sized to cross a usage-limit window** (§6): the set must be large enough that a single
  uninterrupted session cannot drain it before a limit is hit under the run's model/plan.

## 4. Metrics (the one normalized set)

Both arms are reduced to the **same four metrics** by the scorer. Identical math for each arm — see
the parity checklist (§9).

| Metric | Definition | Better |
| --- | --- | --- |
| **Merged-task throughput** | count of tasks whose change landed on the fixture's main branch | higher |
| **Dollars per merged change** | total model spend for the arm ÷ merged tasks | lower |
| **Defect escape rate** | merged changes that FAIL the fixed acceptance suite ÷ merged tasks | lower |
| **Human intervention count** | discrete operator actions required during the run (§4.1) | lower |

### 4.1 What counts as a "human intervention"

An intervention is a **discrete point where the run required an operator to act** — the currency of
the time/presence thesis. Counted identically in intent for both arms; sourced differently because
the arms are instrumented differently (§9):

- **Arm H (from the journal, derived by the scorer):** one intervention per
  - `hold_applied` event — a human-verify hold that an operator must clear with `herd-approve.sh`, **plus**
  - `limit_resume_result` with `woke=0` — an auto-resume that could not wake the builder and forced a
    manual wake.

  Routine merges, review dispatch, and *successful* auto-resumes are **not** interventions — they
  happen with the operator absent, which is the entire point.
- **Arm B (from the operator's ledger, §9.2):** one intervention per operator touch that the run
  could not proceed without — re-prompting a stalled/limit-parked session, restarting a dead
  Workflow, manually merging, manually re-running review, or resuming after the operator's own
  absence. The Arm-B operator logs each as one line in the ledger with a timestamp and a reason.

The asymmetry is the finding, not a bias: Arm H's interventions are what the engine could not
automate; Arm B's are what the operator had to do because nothing automated it. Both are counted
honestly against the same "operator had to act" definition.

## 5. The fixed acceptance suite (the defect oracle)

A single, frozen acceptance suite grades **both** arms' merged changes — the same checks, run the
same way, by a neutral third party (not either arm's operator). It is committed to the fixture before
the run and never edited during it.

- For each merged change, the corresponding acceptance check is run against the fixture's main
  branch. A merged change that **fails** its check is a **defect that escaped** — it got past the
  arm's own review into main.
- The suite result per arm is recorded as `{"suite_total": <merged changes graded>, "escaped":
  <how many failed>}` and handed to the scorer as that arm's `--*-defects` input.
- The suite is deterministic and re-runnable; a third party can reproduce the escaped count from the
  merged fixture state alone.

## 6. The usage-limit window (mandatory for both arms)

The thesis is about surviving a limit park unattended, so **both arms must cross at least one
usage-limit window during the run**, with the operator **away** for that window:

- The run is scheduled / sized so that draining the task set on the run's model+plan hits a usage
  limit at least once (§3 sizing requirement). If a natural limit is not hit, the run is invalid and
  is **aborted** (§8) — a comparison that never parks on a limit tests nothing.
- Arm H records the park as `limit_detected` and the recovery as `limit_resume_result` in its
  journal automatically. Arm B's operator records each limit park and how the session recovered
  (auto? manual re-prompt? session lost?) in the ledger (`limit_events`, plus one intervention line
  per manual recovery).
- **Operator-away discipline:** during the limit window, neither operator may babysit. Arm H is
  expected to auto-resume; Arm B's behavior across the window is exactly what the experiment
  measures. Any operator action during the window is logged as an intervention.

## 7. Scoring — deterministic, committed in advance

`scripts/herd/experiment/herd42-score.sh` is the judge. It is **purely deterministic and read-only**:
same inputs → **byte-identical** `scorecard.json` (no clock, no randomness, no engine state). It is
unit-tested against fixture journals with known-input → exact-output assertions
(`tests/test-herd42-score.sh`).

```sh
scripts/herd/experiment/herd42-score.sh \
  --herd-journal <arm-H .herd/journal.jsonl> \
  --herd-defects <arm-H acceptance result .json> \
  --bare-ledger  <arm-B accounting ledger .json> \
  --bare-defects <arm-B acceptance result .json> \
  --out scorecard.json
```

**How each arm's raw numbers are sourced (this is the whole normalization):**

- **Arm H — from the engine's own artifacts, nothing hand-entered:**
  - merged throughput = count of `merge` events in `.herd/journal.jsonl` (deduped by PR).
  - dollars = sum of the `cost` events' `usd` in that same journal — **identical to what `herd cost`
    reports**, because `herd cost` aggregates those very events; reading them directly is equivalent
    and deterministic.
  - human interventions = `hold_applied` count + `limit_resume_result{woke=0}` count (§4.1).
  - `spanned_limit_window` = at least one `limit_detected` event.
- **Arm B — from the hand-kept ledger the protocol mandates (§9.2)** — merged count, total dollars
  (from the native harness's own usage/billing readout), intervention count, and limit-event count.

The scorer computes `usd_per_merged_change` and `defect_escape_rate` with the **same formula** for
both arms, then emits a per-metric `comparison` winner and the `verdict` block below.

## 8. Verdict rules — abort AND falsification criteria (committed IN ADVANCE)

The scorer sets these in `scorecard.json`'s `verdict`. They are fixed here **before** the run so no
result can be reinterpreted after the fact.

**ABORT (the run yields no valid verdict; `verdict.abort = true` with reasons) if any hold:**

1. **No limit window was exercised** by either arm — `spanned_limit_window` false for both. The one
   workload the experiment exists to test never occurred; the run is void (re-run, do not conclude).
2. **The acceptance suite graded 0 merged changes** for an arm (`suite_total == 0`) — there is no
   defect oracle, so escape rate is undefined.
3. **Neither arm merged any task** — nothing to score.

An aborted run is **not** a herdkit win or loss. It is re-run (or the design is fixed) before 2026-07-10
where possible; if unfixable in time, the abort itself is reported honestly.

**FALSIFICATION — herdkit LOSES (`verdict.falsified = true`) iff, across a fairly-crossed limit
window (`both_spanned_limit_window == true`), the well-run bare arm matches-or-beats herdkit on
EVERY metric:**

- Arm B merged ≥ Arm H merged, **and**
- Arm B dollars-per-merged ≤ Arm H dollars-per-merged, **and**
- Arm B defect-escape-rate ≤ Arm H defect-escape-rate, **and**
- Arm B human-interventions ≤ Arm H human-interventions.

If Arm B dominates on all four while both crossed a limit window, herdkit adds nothing the raw
harness cannot do, and **the thesis is falsified** — we commit to that verdict. This is the
honest-disposition clause of the positioning thesis made mechanical.

**HERDKIT CONFIRMED (`verdict.herdkit_thesis_confirmed = true`)** iff both arms crossed a limit
window, Arm H matches-or-beats Arm B on every metric, and Arm B does **not** also dominate. The
expected mechanism of a herdkit win is Arm B **losing throughput and/or gaining interventions across
the limit window** (a parked session the operator was away from), while Arm H auto-resumed unattended.

Any outcome that is neither full domination — a **mixed** result (each arm wins some metrics) — is
reported as-is: `falsified` and `herdkit_thesis_confirmed` are both false, and the per-metric
`comparison` block stands as the honest finding. A mixed result is **not** spun as a herdkit win.

## 9. Instrumentation-parity checklist (proving neither arm gets hidden help)

The two arms are instrumented differently by necessity (herdkit journals itself; the bare harness
does not), so parity is about **equal measurement fairness**, not identical mechanism. Every box must
be checked and initialed by a neutral party before the scorer is run.

### 9.1 Same board, same oracle

- [ ] **Identical task set.** Both arms drain the byte-identical frozen task list from the same
      fixture commit. Diff the two fixtures' task files → empty.
- [ ] **Identical acceptance suite.** The same frozen suite grades both arms, run by a neutral third
      party, not either operator. Suite files diff → empty.
- [ ] **Same starting state.** Both arms start from the same fixture HEAD sha
      (`sandbox-fixture.sh` is byte-deterministic — assert the sha).
- [ ] **Same model tier + plan** for builders on both arms (so dollars and limit-timing are
      comparable). Record the model id and plan for each arm.
- [ ] **Both crossed a real usage-limit window** with the operator away (§6). If either did not, the
      run **aborts** (§8.1) — this is enforced by the scorer, not left to judgment.

### 9.2 No hidden help to EITHER arm

- [ ] **Arm B gets no herdkit.** No herdkit script, journal, cost summer, watcher, auto-resume, or
      `.herd/` convention is available to Arm B. It runs native Claude Code only.
- [ ] **Arm B gets every NATIVE affordance.** Worktrees, Workflow/subagents, and its own review flow
      are all permitted and expected — Arm B is steelmanned, not hobbled (§2).
- [ ] **Arm H gets no manual babysitting** beyond what the journal records as an intervention. The
      operator hands off and stays away; any touch is journaled and counted (§4.1).
- [ ] **Cost captured comparably.** Arm H dollars = the journal `cost` events (= `herd cost`); Arm B
      dollars = the native harness's own usage/billing readout for the run. Both cover builder **and**
      review model spend. Note the one known asymmetry honestly: herdkit's cost summer can miss
      review spend on PRs that blocked and never merged (see `scripts/herd/cost.sh` header) — since
      only *merged* changes count for dollars-per-merged, this affects neither arm's denominator, but
      it is disclosed here rather than hidden.
- [ ] **Interventions logged to one definition.** Both arms count against the single "operator had to
      act" definition (§4.1). Arm B's operator logs each as a timestamped ledger line; Arm H's are
      derived from the journal. A neutral party reviews Arm B's ledger for honesty before scoring.
- [ ] **The scorer is the only judge.** Both arms are reduced to metrics by the same deterministic
      `herd42-score.sh` with the same formulas; no arm's numbers are hand-adjusted after the fact.

**Bare-arm ledger format** (`ledger.json`, one object; the operator maintains it live and a neutral
party audits it before scoring):

```json
{
  "merged_tasks": 7,
  "usd_total": 44.10,
  "human_interventions": 12,
  "limit_events": 2
}
```

(The per-intervention timestamped detail lines the operator keeps for the audit are separate; only
these four normalized totals feed the scorer, mirroring exactly the four things the scorer derives
from Arm H's journal.)

## 10. Run-day checklist

1. Freeze the fixture task set + acceptance suite; assert the fixture HEAD sha (§9.1). Commit them.
2. Record model tier + plan for both arms.
3. Hand off Arm H (unattended); start Arm B with its operator. Both drain the same set; both must
   cross a limit window with the operator away.
4. At the end, run the acceptance suite (neutral party) → `herd-defects` / `bare-defects` results.
5. Collect Arm H's `.herd/journal.jsonl` and Arm B's audited `ledger.json`.
6. Run `herd42-score.sh` → `scorecard.json`. The `verdict` block is the committed-in-advance result.
7. Report the scorecard as-is, mixed results included. No post-hoc reinterpretation.
