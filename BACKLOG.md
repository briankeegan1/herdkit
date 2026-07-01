# herdkit — backlog

> Single source of truth for planned herdkit work. The coordinator owns this file; the async
> scribe is the only automated writer. 🔜 planned · 🚧 in progress · ✅ shipped. herdkit is
> developed *using the herd* (workspace wB) — these items get built through its own lanes.

## Cross-repo orchestration (deferred — validate via a simulation FIRST, don't over-build; link registry foundation ✅ shipped PR #14)

- 🔜 **`_backend_item_state <id>` op + dependency-watcher** — a 4th adapter op (`open|closed|in-progress`) so a consumer records `blocked-on: <repo>#<id>`, polls it, and unblocks when the provider closes it. One adapter op across github/linear/devops; native dep-links when a shared Linear/DevOps org, poll-the-adapter when backends are independent.
- 🔜 **`herd upgrade` versioned migrations** — `migrations/vN→vM.sh` transform a consumer's config/hooks to a new engine contract, so breaking changes are inherited without clobbering custom setup.
- 🔜 **Cross-repo dependency-loop SIMULATION** — dry-run the full A→B loop (file → build → ship → detect-done → `herd upgrade` → unblock) with existing primitives + thin stand-ins, to validate the design + produce a gap report BEFORE building the machinery above. Doubles as a Phase-4 brownfield test.

## Enterprise / multi-user optionality (deferred — solo is the default today; bank the config seams now)

- 🔜 **Dispatch vs. dependency intent** — `herd report --to B` (fire-and-forget issue, default) vs `--to B --dep` / `herd depend B#id` (records `blocked-on` + watched). Reclassify/remove via `herd deps rm|demote` — a dep is editable data, never stuck. *(Depends on the link registry above for `--to <project>`.)*
- 🔜 **Watcher flexibility for long-pending deps** — backoff polling; richer dep states (`open/in-review/in-progress/stalled/closed`); surface `stalled` + optional TTL so a slow enterprise PR never silently rots. A `blocked-on` is a status line, never a workspace freeze.
- 🔜 **Configurable watcher views** — lenses `mine | all | deps | review-queue` + filters (author/assignee/label/status); default in `.herd/config`.
- 🔜 **Multi-user / team mode** — `WATCHER_SCOPE=mine|all` + ownership/assignee filter; auto-merge scoped to OWNED PRs only (never blind-merge teammates'), building on the required-checks gate (PR #5). `solo` default; `team` is a config flip.

## Reliability / safety

- 🚧 **Watcher singleton spawn-lock + stale reap** *(worktree: `watcher-spawn-lock`)* — `herd-watch.sh`/`agent-watch.sh` has no per-project singleton guard, unlike coordinator/scribe/researcher which received per-project spawn-locks in PR #11. Observed up to 8 concurrent watchers in a single session, all auto-merging and racing on `gh pr merge`. Fix: add a per-project spawn-lock (keyed by `WORKSPACE_NAME`, matching the PR #11 pattern) so exactly one watcher runs per project; detect and reap stale watchers that persist across sessions/days. Ground implementation against `scripts/herd/herd-watch.sh`, `agent-watch.sh`, and the PR #11 spawn-lock mechanism. Safety hazard for all herdkit consumers — duplicate auto-mergers racing on `gh pr merge` is the primary risk.
- 🔜 **Lane-spawned builders can silently stall on the folder-trust prompt** — agents spawned by `herd-quick.sh` / `herd-feature.sh` (via `herdr agent start ... -- claude --dangerously-skip-permissions`) can hang on Claude Code's "Is this a project you trust?" folder-trust gate, which `--dangerously-skip-permissions` does NOT bypass. Observed this session: a gate-fix builder sat idle with ZERO commits (and an earlier one vanished entirely) until a human pressed Enter to accept the trust prompt — the coordinator had no signal it was stuck. Fix options: (1) pre-trust the worktree directory before/at launch so a fresh worktree is accepted non-interactively (e.g. write a `.claude/settings.json` or equivalent trust marker in `new-feature.sh` before the agent starts); (2) have the coordinator detect a builder that is idle-with-no-commits or absent shortly after spawn and surface a "builder stalled" warning instead of assuming progress. Ground against `scripts/herd/herd-quick.sh`, `herd-feature.sh`, `new-feature.sh`, and the `herdr agent start` invocation (line 62 of `herd-quick.sh`). Affects all herdkit consumers — a silently-stalled builder looks identical to "nothing happening".

## Someday / Deferred

- 🔜 **Platform-agnostic install + shell portability** — don't assume brew or any one PATH dir. (1) README install: lead with the zero-assumption option (add `bin/` to `PATH`), then "symlink to ANY PATH dir", then brew-tap / curl-installer as conveniences — drop the hardcoded `/usr/local/bin`. Optional `install.sh` that detects a writable PATH dir. (2) Shell-portability audit so it runs on Linux too: `sed -i` (GNU vs BSD), `date`/`stat` flags, confirm the `flock`→mkdir fallback + the symlink-resolution (PR-in-flight) cover the gaps. Real requirement is herdr + claude + gh + git + python3, not the OS/brew.
- 🔜 **Phase 4: onboard an external consumer** — `herd init` against a genuinely different repo (web server/library); the real abstraction test (§8).
- 🔜 **Claude-plugin wrapper** — ship the skill as a Claude Code plugin while the CLI stays source of truth (§4).

## Recently shipped

- ✅ **Cross-repo link registry (`.herd/links`)** — foundation for general peer dispatch (A → any project B); each link = name + repo coordinates + backend adapter + tracker target, so `herd report --to <project>` resolves arbitrary linked projects; `tracker_target` wired as `LINEAR_TEAM_ID`. *(PR #14, follow-up e1a6877)*
- ✅ **Multi-tenancy: project-scoped singletons** — coordinator/scribe/researcher tab+agent names suffixed by `WORKSPACE_NAME`, so two projects coexist in one herdr without colliding (tab-close + spawn-locks now per-project). *(PR #11)*
- ✅ **Harden `herd report`** — backend-agnostic dispatch (`HERD_REPORT_BACKEND` → `_backend_add_item`) + dedup-before-filing. *(PR #10)*
- ✅ **Feedback loop — `herd backlog`** drains the active backend (file/github/linear) as the work source + `herd.sh` launcher. Cross-repo dispatch loop proven end-to-end. *(PR #7, #9)*
- ✅ **Linear backend** — GraphQL, key in gitignored `.herd/secrets`. *(PR #6)*
- ✅ **Watcher honors required checks / CODEOWNERS** — auto-merge gates on `mergeStateStatus=CLEAN`. *(PR #5)*
- ✅ **GitHub-Issues backend** — live-API smoke verified. *(PR #3)*
- ✅ **herdr version/contract preflight** — fail fast on missing/skewed herdr. *(PR #2)*
- ✅ **Leak-guard** — healthcheck fails on single-consumer literals. *(PR #1)*
- ✅ **Phase 2: scaffold the standalone repo** — engine, CLI, templates, dogfood config.
