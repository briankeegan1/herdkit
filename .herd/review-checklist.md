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
- **merge-performer-dependent or seat-local state** (see `docs/multi-seat-doctrine.md`) — many
  coordinator seats work this repo at once, so treat these as correctness defects, not cleanups:
  a behavior wired as an **event side-effect that only fires for the seat that acted** (a refresh or
  a retirement done inside `do_merge`, so another seat's merge leaves the state stale) where an
  **invariant reconciled every tick against observed state** was needed; or a check that is **not one
  shared implementation reused at every enforcement surface** — enforced at the merge gate but not in
  the builder's pre-PR light profile, duplicated per surface, or left as prose the builder must judge.
- a **tracker mutation from a builder diff**: any call that writes work-tracker state — a Linear
  issue update (`issueUpdate`, `stateId`/`assigneeId`/label mutation), a `gh issue edit/close/reopen`,
  or a read of `.herd/secrets` — the coordinator owns ALL item states; builders must never touch them.
