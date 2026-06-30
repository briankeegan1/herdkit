# herdkit — backlog

> Single source of truth for planned herdkit work. The coordinator owns this file; the async
> scribe is the only automated writer. 🔜 planned · 🚧 in progress · ✅ shipped. herdkit is
> developed *using the herd* (workspace wB) — these items get built through its own lanes.

## Now

- 🚧 **Harden `herd report`** — backend-agnostic dispatch + dedup. (1) Route through the target tracker's `_backend_add_item` (via a `HERD_REPORT_BACKEND`, default github) instead of hardcoded `gh issue create`, so a cross-repo request can land in GitHub Issues **or Linear/Jira** — matching the agnostic drain. (2) Dedup-before-filing: scan the target's open items (`_backend_list_open`) and, on a likely match, warn + prompt (file anyway / cancel) instead of blindly creating a duplicate. *(building)*

## Cross-repo orchestration (deferred — validate via a simulation FIRST, don't over-build)

- 🔜 **`_backend_item_state <id>` op + dependency-watcher** — a 4th adapter op (`open|closed|in-progress`) so a consumer can record `blocked-on: <repo>#<id>`, poll it, and unblock when the provider closes it. Falls out as one adapter op across github/linear/devops; native dep-links when a shared Linear/DevOps org, poll-the-adapter when backends are independent.
- 🔜 **`herd upgrade` versioned migrations** — `migrations/vN→vM.sh` that transform a consumer's config/hooks to a new engine contract, so breaking engine changes are inherited without clobbering custom setup (engine stays pristine; only config + override hooks are local).
- 🔜 **Cross-repo dependency-loop SIMULATION** — dry-run the full A→B loop (file → build → ship → detect-done → `herd upgrade` → unblock) with existing primitives + thin stand-ins, to validate the design and produce a gap report BEFORE building the machinery above. Doubles as a Phase-4 brownfield test (stand up a structurally-different "Repo A").

## Someday / Deferred

- 🔜 **Phase 4: onboard an external consumer** — `herd init` against a genuinely different repo (web server/library, not another shell project); the real abstraction test (§8).
- 🔜 **Claude-plugin wrapper** — ship the skill as a Claude Code plugin while the CLI stays source of truth (§4).

## Recently shipped

- ✅ **Feedback loop — `herd backlog`** drains the active backend (file/github/linear) as the work source + `herd.sh` launcher. Cross-repo dispatch loop proven end-to-end (herd report → drain → build → close). *(PR #7, #9)*
- ✅ **Linear backend** — `backends/linear.sh`, GraphQL, key in gitignored `.herd/secrets`. *(PR #6)*
- ✅ **Watcher honors required checks / CODEOWNERS** — auto-merge gates on `mergeStateStatus=CLEAN`. *(PR #5)*
- ✅ **GitHub-Issues backend** — `backends/github.sh`; live-API smoke verified. *(PR #3)*
- ✅ **herdr version/contract preflight** — fail fast on missing/skewed herdr. *(PR #2, §8)*
- ✅ **Leak-guard** — healthcheck fails on single-consumer literals in the engine. *(PR #1, §8)*
- ✅ **Phase 2: scaffold the standalone repo** — generic engine, `herd` CLI, templates, dogfood config.
