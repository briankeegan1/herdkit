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
   herd coordinator
   # or
   herd new  # spawns coordinator + a feature lane side-by-side
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
- `MERGE_POLICY` must be set (auto-merge is OFF by default; set to `auto` or `held` to enable).
- `CLAIM_REQUIRED` should be `on` if a shared project (prevents concurrent operator claims).
- `COORDINATOR_WATCHDOG` should be enabled (so the coordinator auto-resumes on limit-hit or crash).
- Backlog must be well-prioritized (the coordinator respects top-to-bottom order).

**Launch**:
```bash
# One-time launch (if not already running)
herd new --unattended

# Or, in a shell script or cron job:
herd reload  # restart the watcher + coordinator if they've stalled
herd drain --await-merge  # blocks until all in-flight builders have merged, then exits 0 or 1
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
- **A builder is stuck**: Check `herd status` for in-flight worktrees. Run `herd why <pr#>` to see the full gate history. If it's wedged (no state change for >30 min), escalate: `herd escalate --worktree <name> --reason "builder-stuck-30min"`.
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
1. Check the builder's transcript: `herd log --component builder-<name> --tail 50`.
2. Decide:
   - **Relaunch**: `herd relaunch --builder <name>` to restart the agent in the same worktree.
   - **Salvage**: Manually inspect the worktree, commit any partial work, and open a PR by hand.
   - **Scrap**: `herd reap --builder <name>` to delete the worktree and move on.

### Coordinator CRASHES

**If attended**:
1. The watcher will detect the coordinator pane is gone and print a warning to the watch console.
2. Re-launch: `herd coordinator` (or `herd new` to start both).
3. The coordinator will re-read the journal and backlog, and resume from the last known state.

**If unattended**:
1. The `COORDINATOR_WATCHDOG` (if enabled) will detect the coordinator is down after `COORDINATOR_WATCHDOG_TIMEOUT` (default 5 min) and relaunch it.
2. If the watchdog is not enabled, the coordinator stays down; the watcher continues to merge ready PRs, but no new spawns happen.

## Emergency Stops

### Stop All Builders Gracefully

```bash
herd shutdown --graceful
# Allows all in-flight builders to finish; no new spawns.
# The coordinator will still run, but it won't spawn new worktrees.
```

### Kill the Watcher (Emergency)

```bash
herd watcher stop
# Stops the merge gate immediately.
# In-flight PRs stay open; no new merges happen.
# Useful if the merge gate is broken and blocking the pipeline.
```

### Restart Everything (Hard Reset)

```bash
herd reload --kill
# Kills both the coordinator and watcher, then re-launches them.
# All in-flight builders stay alive in their worktrees.
# Use only if the system is in a broken state and you want a clean restart.
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

3. **Set `MERGE_POLICY` explicitly**: Leaving it unset defaults to `held` (manual approval); in unattended mode, you probably want `auto`. Make the policy explicit.

4. **Monitor the first hour of an unattended run**: Watch `herd status` or the journal; if something breaks early (e.g., a builder crashes, review verdicts are nonsensical), you can catch it before the run diverges.

5. **Keep the coordinator heartbeat alive**: The coordinator emits a "tick" event to the journal every minute. If you see >2 min of silence, the coordinator may be wedged. Run `herd reload` to restart.

6. **Archive failed items promptly**: If a builder keeps failing the same item (e.g., a test always fails), archive it and move on rather than letting it loop. Looping wastes budget.

---

This SOP is the reference for operating herdkit in both attended and unattended modes. Deviations (e.g., a custom escalation policy) should be documented in your project's `.herd/config` comments or a local runbook.
