# herdkit review checklist — what "silently wrong" looks like in the engine

Injected into the pre-merge review gate (herd-review.sh) via REVIEW_CHECKLIST. The reviewer hunts
adversarially for these in a PR's diff:

- a lane that **mislabels watcher state** (e.g. shows CLEAN/merging when the PR is actually
  conflicting, or "building" when the agent is idle) — wrong state drives a wrong merge.
- a **safety-rail bypass**: merging without re-verifying MERGEABLE/CLEAN, merging a BLOCK or an
  un-reviewed sha, re-spawning a resolver/reviewer that a guard should have stopped, or losing the
  review-once / resolve-once idempotency.
- a **queue race**: a non-atomic claim, a lost spawn lock, a drainer that processes a file it did
  not win, or a stale-claim reclaim that double-processes.
- a **scribe write that can clobber** a concurrent manual edit, or a push path that drops a commit
  on rejection instead of failing loud.
- a **project-leak**: a Northstar (or any one consumer's) literal hardcoded into "generic" engine
  code instead of read from `.herd/config`.
- **destructive git**: a force-push, a push to the default branch, or a `worktree remove` of the
  wrong dir (including the watcher's own worktree).
- a **config key read without a fallback**, so a project that hasn't set it breaks cryptically.
- a **tracker mutation from a builder diff**: any call that writes work-tracker state — a Linear
  issue update (`issueUpdate`, `stateId`/`assigneeId`/label mutation), a `gh issue edit/close/reopen`,
  or a read of `.herd/secrets` — the coordinator owns ALL item states; builders must never touch them.
