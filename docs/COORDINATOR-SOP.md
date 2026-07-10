# Coordinator Standard Operating Procedure

This document describes the operational playbook for running and monitoring the herdkit coordinator in both attended and unattended modes.

> Several coordinator seats work the same repo in parallel. The two rules that keep them from
> interrupting each other — reconciled invariants over event side-effects, and one shared check at
> every enforcement surface — are in [`multi-seat-doctrine.md`](multi-seat-doctrine.md).

## Roles and Responsibilities

### The Coordinator Agent

The coordinator is a long-lived LLM agent responsible for:

- **Backlog ownership**: Reading the current BACKLOG.md or external project tracker, understanding priority/state/blockers, and deciding what to spawn next.
- **Lane dispatch**: Spawning builders, scribe drainers, and research agents via `herd-feature.sh`, `herd-quick.sh`, `scribe.sh`, `research.sh`, etc.
- **Escalation handling**: When the watcher surfaces a `BLOCK` (a failed review or resolver escalation), the coordinator decides whether to:
  - Requeue it for a builder retry (if fixable).
  - Escalate it to the human for judgment (marked `HUMAN-VERIFY` or `ESCALATE`).
  - Archive it or defer it.
- **Concurrency governance**: Respecting `SPAWN_AHEAD` (how many in-flight builders to maintain) and `REVIEW_CONCURRENCY` (how many PRs to review in parallel).
- **State machine handshake**: Detecting when the watcher has merged a PR, reaping its worktree, and freeing up a concurrency slot for the next spawn.

The coordinator **never**:
- Edits code directly (it spawns builders who do).
- Mutates the backlog file (the scribe drainer does; the coordinator enqueues changes).
- Force-merges a PR or bypasses the review gate.

### The Watcher (Detached Process)

The watcher is a detached, non-LLM process that:

- **Polls PR state**: Every `WATCHER_TICK` seconds (default 10), checks each in-flight PR for mergeable status, healthcheck completion, and review verdict.
- **Verifies gates instantly before merge**: Runs a final healthcheck + review pass in the instant before pushing the merge button.
- **Merges cleanly**: Pushes the PR only if ALL gates pass in that final instant.
- **Surfaces failures**: Writes BLOCK events to the journal and the control-room console so the coordinator sees them immediately.
- **Auto-resumes limit-hit builders**: Detects the `rate_limit` sentinel on a worktree, waits for the reset time, and relaunches the builder via `claude --continue`.
- **Detects dead builders**: Finds worktrees with no live agent and no open PR, and escalates to the coordinator.

The watcher **always**:
- Fails closed (would rather BLOCK a PR than auto-merge an unverified one).
- Runs idempotently (re-polling the same PR multiple times returns the same verdict).
- Never touches the coordinator process.

## Operational Modes

### Attended Mode (Operator at Console)

**When to use**: Interactive work, building a single feature, or training/onboarding.

1. **Launch the coordinator**:
   ```bash
   bash scripts/herd/coordinator.sh   # 2-pane control room (backlog + coordinator)
   # or restart one pane later:
   herd pane coordinator              # relaunches the coordinator agent pane
   herd reload                        # rebuild watcher + backlog around a live coordinator
   ```

2. **Monitor the control room**: The coordinator pane shows the backlog and agent output; the watcher row (pinned below) streams live PR gate transitions.

3. **Respond to escalations**: If a review BLOCKS or the resolver escalates, the coordinator will ask for direction. You can:
   - Type `requeue <pr#>` to send it back to a builder for fix.
   - Type `approve <pr#>` to bypass the gate (records the override in the journal).
   - Type `archive <pr#>` or `defer <pr#>` to stash it.

4. **Adjust spawn rate**: Edit `.herd/config` on the fly (e.g., `SPAWN_AHEAD=1`) and run `herd reload` to tune concurrency.

5. **Monitor cost**: Run `herd cost` in a separate pane to track per-PR spend in real time.

### Unattended Mode (Operator Away, Cron/Scheduled)

**When to use**: Long overnight drains, batch work, or production backlog clearing.

**Prerequisites**:
- All gates must be deterministic and pass-safe (e.g., healthcheck must not be flaky, review verdicts must not time out).
- `MERGE_POLICY` should be set explicitly for unattended intent (default is `auto` — the watcher merges on pass; use `approve` for coordinator sign-off via `herd-approve.sh`, or `observe` to never merge).
- `CLAIM_REQUIRED` should be `on` if a shared project (prevents concurrent operator claims).
- `COORDINATOR_WATCHDOG` should be enabled (so the coordinator auto-resumes on limit-hit or crash).
- Backlog must be well-prioritized (the coordinator respects top-to-bottom order).

**Launch**:
```bash
# One-time launch (if not already running)
bash scripts/herd/coordinator.sh

# Or, in a shell script or cron job:
herd reload   # restart the watcher + re-render around a live coordinator if they've stalled
herd status   # poll until open PRs clear / DEAD builders go to zero (no await-merge CLI)
```

**Monitoring** (if you step away but stay reachable):
```bash
# Check status every 5 minutes
watch -n 300 'herd status'

# Or, get a Slack/email alert if something goes red
herd status --json | jq '.watcher.alive | select(. == false)' && notify_ops "Watcher is dead"
```

**Troubleshooting**:
- **Watcher is dead**: Run `herd reload` to restart it. If it dies again immediately, check the watcher log: `herd log --component watcher --tail 20`.
- **Coordinator is paused on limit**: The `COORDINATOR_WATCHDOG` should have auto-resumed it. Check the journal: `herd log --component coordinator --tail 20`. If no auto-resume event, the watchdog may not be enabled; enable it with `herd config set COORDINATOR_WATCHDOG on`.
- **A builder is stuck**: Check `herd status` for in-flight worktrees. Run `herd why <pr#>` to see the full gate history. If it's wedged (no state change for >30 min), surface it to the human (a HUMAN-VERIFY / ESCALATE note via the coordinator) — there is no dedicated escalate subcommand; the journal + status console carry the trail.
- **A review keeps BLOCKING**: Run `herd log --pr <pr#>` to see the review comments. Either the code needs fixing, or the review gate is too strict. If misconfigured, adjust `REVIEW_CHECKLIST` or set `REVIEW_MODEL_CHEAP` for non-blocking passes.

## State Machine: The Merge Dance

The coordinator, watcher, and builder execute an interlocking state machine:

```
Coordinator                         Builder                    Watcher
│                                    │                          │
├─ [SPAWN] ──────────────────────────> spawns worktree          │
│  (enqueue spawn,                   └─ edits code              │
│   write dispatch                   └─ opens PR                │
│   event to journal)                                           │
│                                                               │
│                                                               ├─ [POLL] ──────────────┐
│                                                               │  (every 10s)          │
│                                                               │  check PR .mergeable? │
│                                    ├─ [HEALTHCHECK] ────────> check .healthcheck?   │
│                                    │                          check .review?        │
│                                    │                          │                     │
│                                    │                          ├─ [VERDICT]          │
│                                    │                          │  all gates pass? ──┐ │
│                                    │                          │                    │ │
│                                    │                          ├─ [RECHECK] ────────┘
│                                    │                          │  (instant before)
│                                    │                          │  re-run healthcheck
│                                    │                          │  + review to confirm
│                                    │                          │
│                                    │                          ├─ [MERGE] ◄──────────┐
│                                    │                          │  git push           │
│                                    │                          │  if still passing    │
│                                    │                          │                     │
│                                    │                          ├─ [JOURNAL]         │
│                                    │                          │  record: merge ok   │
│                                    │                          │  PR#, sha, timestamp│
│                                    │                          │                     │
│                                    │                          ├─ [REAP] ◄──────────┘
│                                    │                          │  rm -rf worktree
│                                    │                          │  close pane/tab
│                                    │                          │  (if builder still
│                                    │                          │   exists, kill it)
│                                    │                          │
├─ [DEQUEUE] ◄──────────────────────┴──────────────────────────┤
│  (watcher emit merge journal event) 
│  (scribe read event, mark item closed/merged)
│  (coordinator free up concurrency slot)
│  (spawn next item from backlog)
│
```

### Critical Invariants

1. **No merge without all gates GREEN**: The watcher re-verifies healthcheck + review in the instant before merge. If either changes to RED, the merge is BLOCKED.

2. **No double-merge**: Only one watcher process can own the merge decision. If two watcher processes run (e.g., after a crash recovery), the `WORKSPACE_NAME` launcher lock ensures only one proceeds.

3. **No merge race during builder rebase**: If a builder is rebasing the worktree (e.g., after a conflict resolve) while the watcher is checking mergeable status, the watcher will see a stale state. The resolver's post-rebase push increments a `__git_rebase_counter__` tag so the watcher detects the new state.

4. **No data loss on coordinator crash**: The coordinator's task dispatch is written to the journal before the lane script launches. If the coordinator dies before flushing a spawn event, the scribe drainer's read of the journal will see the missing event and re-enqueue it (idempotency).

## Concurrency Governance

The coordinator respects two concurrency limits:

- **`SPAWN_AHEAD` (default 3)**: How many builder worktrees to keep in-flight (building, waiting for review, or pending merge). The coordinator spawns the next backlog item only when a current builder has merged and been reaped.

- **`REVIEW_CONCURRENCY` (default 2)**: How many PRs to review in parallel. The review lane can dispatch up to N reviewers simultaneously; excess PRs queue.

**Example**:
- `SPAWN_AHEAD=3`: Keep builders 1, 2, 3 in flight; when builder 1 merges, spawn builder 4.
- `REVIEW_CONCURRENCY=2`: Review builders 1 and 2 in parallel; builder 3 waits for a reviewer slot to free.

**Tuning**:
- Increase `SPAWN_AHEAD` if builders are waiting idle (you have budget and builders are not conflicting).
- Decrease it if you hit the usage limit frequently (too much in-flight work for your quota).
- Increase `REVIEW_CONCURRENCY` if review is the bottleneck; decrease if review is crashing the model.

## Human-Verify Holds

If a builder adds a `HUMAN-VERIFY:` block to the PR body (e.g., "requires manual smoke test of the UI"), the merge gate will BLOCK and the PR stays in a "human-verify" hold. The coordinator will **not** auto-merge.

**To clear a human-verify hold**:
```bash
herd-approve.sh approve <pr#>
# or, from the control room console:
approve <pr#>
```

This records an `APPROVE` event in the journal (audit trail) and releases the hold so the watcher can merge.

## Builder Notes

A builder that hits a load-bearing mid-build finding (a red row that is a stale cached result, a test not wired into the gate, a hold that is env rather than code) files it with `herd note "<finding>"`. That journals a `builder_note` event, and the watcher surfaces it in the console's **builder notes** section within a tick — no human clipboard paste. The coordinator is the only consumer: nothing else in the engine acts on a note.

The loop is **read → route → ack**, run on invocation and every time you check running agents — *before* re-tasking a builder or overriding a gate, since a note often explains the very row you are about to act on. Read the open notes with `herd log | grep builder_note`, or with the ack-aware `notes` subcommand (`notes` lists them numbered, newest first) once HERD-243 has landed it. Route each one: **act now** if it changes your next move, **file it** via the scribe with the note quoted verbatim if it is real work that outlives this build, or **dismiss** it as informational. Then ack the handled note (`notes ack <n>`, or `notes ack all`) so the console clears and the next coordinator seat does not re-route it. The ack is display-only — the journal keeps every note. Where that subcommand is not yet present in the engine build, read and route exactly the same way; handled notes age out of the display on their own instead of clearing on command. The coordinator skill carries the full command surface.

## Programs

Most work larger than one PR is a **program**: an epic item on the tracker plus the children that build
it. The coordinator owns the shape.

An **epic** carries three things and nothing else: the **goal** (what is true when the program is done),
the **phases** (ordered groups of work, each with a reason it must come after the one before it), and the
**child list** (one line per child item, ticked as it lands). It is a map, not an essay — the essay lives
elsewhere.

**Long-form evidence lives as a committed doc, never only as a session artifact.** A post-mortem or audit
goes in `docs/audits/` (dated: `docs/audits/2026-07-09-gating-hardening.md`); a design goes in `docs/`.
An agent transcript, a pane's scrollback, and a coordinator's summary all evaporate; the next seat, and
every builder spawned six weeks from now, can only read what is in the repo. Every item in a program
cites the committed path, so a builder that needs the *why* can `cat` it instead of asking a human.

**The maintenance rule** — three obligations, in order:

1. **Read the epic before picking a child.** The phase ordering is the sequencing decision; a child
   pulled out of order collides with work that has not landed yet.
2. **Tick children on land.** When a child's PR merges, enqueue the epic update through the scribe
   (`bash scripts/herd/scribe.sh "..."`) like any other tracker write — the coordinator never hand-edits
   the tracker. An epic whose child list lies is worse than no epic.
3. **A new gap gets filed AND slotted.** Discovering work mid-program means two writes, not one: file the
   item (against the *Authoring a backlog item* SOP), and add it to the epic's phase list. A filed-but-
   unslotted item is invisible to the next seat, which reads the epic, not the queue.

The trigger to create one, from the authoring SOP's check 8: the **third** item sharing a single root
cause with no epic covering them. Create the epic first, then file the child against it — file-then-spawn,
so no builder is ever spawned against a program that does not exist on the tracker yet.

The live exemplar is the **HERD-240** gating-hardening epic: its evidence base is committed at
[`docs/audits/2026-07-09-gating-hardening.md`](audits/2026-07-09-gating-hardening.md), its children each
carry a `Part of HERD-240 — Phase N; full context: docs/audits/2026-07-09-gating-hardening.md` backlink,
and its phases sequence the reconcile-layer completions ahead of the structural redesigns that depend on
them.

## Escalation Paths

### Review BLOCKS

**Trigger**: The review agent rates the PR as high-risk or non-conforming.

**Action**:
1. Run `herd why <pr#>` to see the detailed review findings.
2. Decide:
   - **Builder refix**: Type `requeue <pr#>` to send it back to the original builder with the review comments.
   - **Manual override**: Type `approve <pr#>` with a reason to bypass and merge (use sparingly; records override).
   - **Archive**: Type `archive <pr#>` to defer / descope it.

### Resolver ESCALATES

**Trigger**: A merge conflict exists, but the conflict resolver cannot resolve it mechanically (e.g., a semantic conflict, not a line-level edit conflict).

**Action**:
1. Run `herd log --pr <pr#>` to see the conflict details.
2. Manually resolve the conflict in the resolver's worktree:
   ```bash
   cd .herd/worktrees/<pr#>-resolver/
   git status  # see conflicts
   # edit files to resolve
   git add .
   git commit -m "Resolve conflict: ..."
   ```
3. Re-run the resolver: `herd-resolve.sh continue <pr#>` (or the coordinator will retry automatically).

### Dead Builder

**Trigger**: A worktree exists, but the agent process crashed and no PR was opened.

**Action**:
1. Check the builder's transcript: `herd log --tail 50` (filter by worktree/PR as needed).
2. Decide:
   - **Relaunch**: re-spawn the builder lane against the same worktree (coordinator / `spawn.sh`) — there is no dedicated relaunch subcommand.
   - **Salvage**: Manually inspect the worktree, commit any partial work, and open a PR by hand.
   - **Scrap**: `herd sweep --dry-run` then `herd sweep` to reap disposable worktrees/tabs (or remove the worktree by hand when it still has unique commits).

### Coordinator CRASHES

**If attended**:
1. The watcher will detect the coordinator pane is gone and print a warning to the watch console.
2. Re-launch: `herd pane coordinator` (or `bash scripts/herd/coordinator.sh` / `herd reload` to rebuild the control room).
3. The coordinator will re-read the journal and backlog, and resume from the last known state.

**If unattended**:
1. The `COORDINATOR_WATCHDOG` (if enabled) will detect the coordinator is down after `COORDINATOR_WATCHDOG_TIMEOUT` (default 5 min) and relaunch it.
2. If the watchdog is not enabled, the coordinator stays down; the watcher continues to merge ready PRs, but no new spawns happen.

## Emergency Stops

### Stop All Builders Gracefully

```bash
# There is no dedicated shutdown subcommand. To stop new spawns while in-flight work finishes:
#   1) leave the coordinator idle (do not enqueue more spawn.sh intents), and/or
#   2) set SPAWN_AHEAD=0 + herd config set / herd reload so the drain stays capped.
# In-flight builders finish; the watcher keeps merging ready PRs.
herd status   # confirm builders drain and open PRs clear
```

### Kill the Watcher (Emergency)

```bash
herd pane watch
# Restarts the watcher pane in place (stops the prior watcher process first).
# In-flight PRs stay open; merges resume once the new watcher is healthy.
# Useful if the merge gate is wedged and needs a fresh process.
```

### Restart Everything (Hard Reset)

```bash
herd reload
# Rebuilds the control room around a live coordinator: stop + relaunch watcher,
# ensure the backlog pane, re-render the skill. Never closes the coordinator tab.
# All in-flight builders stay alive in their worktrees.
# Use when the system is in a broken state and you want a clean control-room restart.
```

## Forensic Commands

### See the Full Gate History of a PR

```bash
herd why <pr#>
```

Output: Chronological timeline of every gate event (spawn, healthcheck attempt/result, review dispatch/verdict, merge, reap, limit-park/resume).

### Follow Live Gate Events

```bash
herd log --tail
```

Output: Real-time stream of journal events.

### Check System Health

```bash
herd status
```

Output: One-shot snapshot — watcher alive? Dead builders? Conflicting PRs? Usage limit near?

### Check Cost So Far

```bash
herd cost [--pr <pr#>] [--session] [--full]
```

Output: Token and USD spend per PR, per session, or total (with coordinator + scribe overhead).

## Best Practices

1. **Validate your backlog before launching unattended**: Run a quick interactive session to flush any low-hanging bugs or misconfigured items.

2. **Test the review gate on a dummy PR**: If you've changed `REVIEW_CHECKLIST`, run one manual review to ensure it's not too strict or crashing.

3. **Set `MERGE_POLICY` explicitly**: Leaving it unset defaults to `auto` (watcher merges on pass; empty derives from legacy `WATCHER_AUTOMERGE`, which also defaults true→auto). Recognized values: `auto` | `approve` | `observe`. Make the policy explicit so operators never guess.

4. **Monitor the first hour of an unattended run**: Watch `herd status` or the journal; if something breaks early (e.g., a builder crashes, review verdicts are nonsensical), you can catch it before the run diverges.

5. **Keep the coordinator heartbeat alive**: The coordinator emits a "tick" event to the journal every minute. If you see >2 min of silence, the coordinator may be wedged. Run `herd reload` to restart.

6. **Archive failed items promptly**: If a builder keeps failing the same item (e.g., a test always fails), archive it and move on rather than letting it loop. Looping wastes budget.

## Full-autonomy doctrine

The full-autonomy doctrine is the complete set of binding rules and practices for running
this coordinator seat without human supervision. It was codified from the 2026-07-09
gating-hardening session (evidence at
[`docs/audits/2026-07-09-gating-hardening.md`](audits/2026-07-09-gating-hardening.md))
and tracked as HERD-270. The coordinator skill source (`templates/coordinator.md.tmpl`)
carries the per-session reference; this section is the full operational playbook.

### Configuration prerequisites

Full autonomy requires these knobs to be set:

```
COORDINATOR_AUTONOMY=full          # no mid-item approval pauses
REVIEW_AUTOFIX=true                # BLOCK reviews bounce to the builder automatically
HEALTHCHECK_AUTOFIX=true           # red healthchecks bounce to the builder automatically
STALE_BASE_AUTOFIX=on              # stale-base holds self-heal via merge-up or resolver
SWEEP_AUTO=auto                    # safe debris runs on the watcher's sweep cadence
CLAIM_REQUIRED=on                  # prevents double-claiming under multiple seats
TRACKED_SPAWNS=required            # prevents off-book spawns
```

Set each with `herd config set <KEY> <VALUE>`. `posture-lint.sh` (via `herd doctor`)
reports which knobs are not at their full-autonomy values.

### Why a doctrine, not just configuration

The knobs set WHAT the coordinator may do autonomously. The doctrine says HOW to
exercise that autonomy — diagnostic order, multi-seat coordination, when to wait vs.
act, and how to persist context. Both are required. A coordinator with the full knob
set but no doctrine will still burn needless rounds: it acts before reading the gate
record, re-tasks a builder the engine was already bouncing, or loses context across
sessions and re-derives it from scratch.

### The six binding rules (full rationale)

The `## Operating posture` block in the rendered coordinator skill provides a compact
summary. The full rationale for each rule:

1. **End-to-end pipelines.** Run each item from pick → spawn → gate monitoring → close
   without pausing for confirmation on mechanical steps. Pause only for genuine judgment
   calls: semantic merge conflicts (a human must choose between two valid meanings),
   product ambiguity (the backlog item is underspecified and a human must clarify), or
   budget/safety decisions the engine cannot make. Every other step is mechanical — the
   audit trail and gate output make the right action unambiguous without human input.

2. **File-then-spawn.** Every builder spawn must trace to a tracked work item. The
   tracker is the single source of what is being built; two coordinator seats reading
   the same tracker see the same queue. Off-book spawns corrupt that picture: the second
   seat reads the tracker, sees the item open, and double-builds. Set
   `TRACKED_SPAWNS=required` so the lanes enforce this; `CLAIM_REQUIRED=on` so a claim
   atomically locks the item against a second seat's spawn.

3. **Respect review bandwidth.** `REVIEW_CONCURRENCY` (default 2) is the real throughput
   ceiling. Spawning ahead of it queues PRs waiting for a reviewer slot, not code
   readiness. Count open PRs (`gh pr list --state open | wc -l`) and hold new spawns
   when that count approaches `REVIEW_CONCURRENCY + SPAWN_AHEAD`.

4. **Let the GATE merge.** The watcher's gate → merge sequence is the authoritative ship
   path. The coordinator never calls `gh pr merge`, never bypasses the gate with
   `herd-approve.sh` for mechanical reasons, and never hand-resolves a conflict except
   through `herd-resolve.sh`. Its role at the merge stage is to surface `needs you` rows
   and route them to the right sub-agent or human.

5. **Reconcile the tracker on every merge.** Whether the merge was by this seat's
   watcher, a foreign seat's watcher, or a human via the GitHub UI, the tracker item
   must be closed. The watcher's merged-PR sweep catches the hook chain (retirement,
   cost accounting, backlog reconcile) for foreign merges, but the TRACKER ITEM is the
   coordinator's responsibility — scribe-driven, not automatic.

6. **Sweep debris.** `herd sweep --dry-run` shows what is safe to remove; `herd sweep`
   removes it. Run on the `SWEEP_AUTO` cadence (when `SWEEP_AUTO=auto` the watcher
   runs safe legs automatically; when `advise`, the coordinator gets a console
   recommendation to run manually). Never let dead worktrees and stale panes accumulate:
   each occupies a concurrency slot, biases `herd status`, and confuses multi-seat
   visibility.

### Diagnostic-first rule (no exceptions)

The rule: **read the record before acting.** The 2026-07-09 session recorded nudges
where the coordinator acted on a red row before reading the gate history, and the row
was a no-op situation — an infra transient, an autofix round already in progress, or a
hold that would clear on the next tick. The correct diagnostic sequence:

```bash
herd notes                     # drain and route builder notes (ack-aware listing)
herd log | grep builder_note   # fallback / full history including already-handled notes
herd why <pr#>                 # chronological gate history for the PR you are about to act on
```

Only AFTER draining notes and reading `herd why`: re-task, override, or escalate.

**What `herd why` surfaces:**

- `infra_event` — a Claude death or API timeout; NOT a code error; do not re-task.
- `verdict_recorded source=gate_default` — gate defaulted to PASS (no reviewer ran);
  NOT a human-approved review.
- `refix_wake_result escalated=true` — the autofix bounce failed to wake the builder;
  the PR needs a manual re-task despite showing a `refixing` state.
- `healthcheck_started` count — how many suite runs this PR has consumed; a count > 3
  may indicate a flaky test or misconfigured suite.
- `stale_dup_hold` — the PR's base is stale; when `STALE_BASE_AUTOFIX=on` this
  self-heals on the next tick without coordinator action.

**What to do with each finding:**

- Infra transient → wait one watcher tick; it clears on its own.
- `gate_default` PASS → the review gate did not actually run; do not treat as approval.
- `refix_wake_result escalated=true` → re-task the builder manually.
- `stale_dup_hold` + `STALE_BASE_AUTOFIX=on` → wait for self-heal.
- BLOCK verdict with review comments → decide: builder refix, manual override (with
  explicit reason), or archive.

### Autofix-aware behavior (full doctrine)

When the full autofix suite is on (`REVIEW_AUTOFIX + HEALTHCHECK_AUTOFIX + STALE_BASE_AUTOFIX`),
the engine runs an automated bounce/refix cycle for every code error. The coordinator's
role is monitor-and-escalate only:

| Console row | What it means | Coordinator action |
|---|---|---|
| `refixing (round k/3)` | Engine bounced the builder; it is working the fix | **Wait** |
| `fix in progress · awaiting push (round k/3)` | Builder received the bounce and pushed | **Wait** |
| `needs you · auto-refix failed` | Engine exhausted bounce budget | **Re-task with context** |
| `needs you · refix limit …` | Same: budget exhausted | **Re-task with context** |
| `needs you` (no round suffix) | Autofix not applicable or off | **Re-task** |

**Re-tasking with context** means reading `herd why <pr#>` first, then sending the
builder the failing test line + suite log path — not a blind re-task. A blind bounce
on a budget-exhausted PR will also exhaust the bounce budget for the next rail.

**Round budget semantics:** rounds are per-rail (`review`, `health`, `stale-base` each
have their own count) and reset when that rail subsequently passes. A PR that fails
review (round 1), gets review to pass (reset), then fails health (round 1 of health)
has NOT exhausted any budget — each rail's count reset when its gate passed. The total
per-PR ceiling (`3 × REFIX_MAX_ROUNDS`) stops a PR that keeps failing across ALL rails.

**When partial autofix is on:** check which knobs are on and which duties remain manual
(the `## Duties that stay MANUAL` sub-section in the rendered coordinator skill lists
them explicitly for the current config). The diagnostic-first rule still applies for
every manual duty before acting.

### Multi-seat discipline (complete doctrine)

Several coordinator seats may work this repo in parallel. Seat-local plans and
event side-effects are the root causes of most inter-seat interruptions (see
`docs/multi-seat-doctrine.md` Rule 1: reconciled invariants > event side-effects).

**Before picking an item to spawn:**

1. `herd backlog queued` — list all live 📌 markers.
2. For each fresh (< 24h) marker: skip unless the plan was clearly abandoned or you
   have an explicit reason to override (state the reason out loud before proceeding).
3. For each `ADVISORY: >24h stale` marker: treat as advisory only — pick the item.

**After deciding to spawn (before the lane command):**

1. Run the pre-spawn impact analysis: `graphify update --no-cluster` + cross the
   candidate's file surface against in-flight worktrees (see *Pre-spawn impact/conflict
   analysis* in the coordinator skill). Sequence colliding items.
2. Publish a 📌 marker: `herd backlog queue <#id> --after <blocker>`. This covers the
   plan-time window between "decided to spawn" and "spawned" — a second seat reading
   the tracker in that window will see the marker and hold off.

**Why a marker AND a claim?**
The **claim** (`CLAIM_REQUIRED=on`) fires AT spawn time — atomic guard against two
simultaneous spawns. The **marker** is published BEFORE spawn, covering the "decided
to build this next" state that may last minutes or hours. Together they close the full
race window: plan-time → spawn-time → build-time.

**Cross-seat conflict cost:** two seats spawning against the same file surface produce
a merge conflict. The conflict resolver (`herd-resolve.sh`) handles it, but resolver
spawns use concurrency slots: one avoidable conflict = one wasted review + one health
run + one resolver slot. Pre-spawn impact analysis is the prevention layer; the claim
is the last-resort guard.

### Session continuity (full doctrine)

Full autonomy means the coordinator must resume work between sessions without a human
briefing. Three requirements:

1. **Project memory is updated every session.** The local memory store holds what was
   learned this session — decisions made, vocabulary, domain quirks (see *Persist
   project & domain context* in the skill). Failing to update it means the next session
   re-derives context from scratch, which is attended operation in disguise. Update at
   the END of every session, not only when asked.

2. **Long-form evidence is committed.** A post-mortem, an audit, a design, or a test
   protocol that any builder or the next coordinator session must read goes in a
   committed doc (`docs/audits/`, `docs/spikes/`, `docs/`). A session artifact (pane
   scrollback, coordinator summary) evaporates on session boundary. The committed doc
   path is cited in every tracker item that needs the background.

3. **Epics are filed before their children.** A multi-item effort whose shape lives only
   in the coordinator's current session is a session artifact. File the epic on the
   tracker first, commit the evidence doc, then file the children — each with a backlink
   to the epic and the committed doc. The next seat reads the repo; if the shape is not
   there, the seat re-derives it (or contradicts it).

### The eight 2026-07-09 hand-nudges and their doctrine mappings

Each nudge traces to a missing or unexercised doctrine practice. Understanding these
mappings lets the coordinator recognize and self-route each class without human help:

| # | Incident summary | Missing practice | Doctrine section |
|---|---|---|---|
| 1 | Opus review burned on stale-base bounce (gate ordering) | Wait for cheap gate before dispatching expensive one | *Autofix-aware* — wait for stale-base self-heal before acting |
| 2 | 19h MAIN RED: main-health tick event-only, not reconciled | Reconciled invariant > event side-effect (R1) | *Multi-seat discipline* — hold spawns when MAIN is red |
| 3 | PR #333 endless infra re-dispatch loop | Read gate history before concluding a PR is stuck | *Diagnostic-first* — `herd why` reveals the infra loop |
| 4 | Test fixtures polluted the live journal | `herd why` context before concluding gate results are real | *Diagnostic-first* — verify journal context, check provenance |
| 5 | Idle resolver held re-dispatch forever (no deadline) | Builder notes surface mid-flight resolver state | *Builder notes* — drain and route before acting on resolver row |
| 6 | Resolver exited on scratch branch; PR became invisible | Read builder notes + `herd why` before declaring PR lost | *Diagnostic-first* — full history before drastic action |
| 7 | Failed `gh pr list` rendered live builders as dead | Confirm status before acting; blindness ≠ evidence of death | *Diagnostic-first* — never act on a potentially-blind read |
| 8 | Seat-local ledgers: double-comment, double-resolver race | Multi-seat marker + claim closes the race window | *Multi-seat discipline* — marker before spawn, claim at spawn |

Evidence base: [`docs/audits/2026-07-09-gating-hardening.md`](audits/2026-07-09-gating-hardening.md),
incidents 1–12 and gaps G1–G9. Epic: HERD-240. Item: HERD-270.

---

This SOP is the reference for operating herdkit in both attended and unattended modes. Deviations (e.g., a custom escalation policy) should be documented in your project's `.herd/config` comments or a local runbook.
