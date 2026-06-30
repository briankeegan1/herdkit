# herdkit — backlog

> Single source of truth for planned herdkit work. The coordinator owns this file; the async
> scribe is the only automated writer. 🔜 planned · 🚧 in progress · ✅ shipped. herdkit is
> developed *using the herd* (workspace wB) — these items get built through its own lanes.

## Now

- 🔜 **Backend-agnostic `herd report` (cross-repo dispatch optionality)** — the drain side (`herd backlog` / `_backend_list_open`) is now tracker-agnostic (file / GitHub Issues / Linear), but the *dispatch* side `herd report` still hardcodes `gh issue create`. Route it through the same 3-op adapter (`_backend_add_item` on the TARGET tracker, e.g. a `HERD_REPORT_BACKEND` / the engine repo's configured backend) so a cross-repo request can land in GitHub Issues **or Linear/Jira** — matching the agnostic drain. Closes the file-anywhere ↔ drain-anywhere symmetry.

## Someday / Deferred

- 🔜 **Phase 4: onboard an external consumer** — run `herd init` (brownfield scout) against a genuinely different, structurally-distinct repo (a web server or a library, NOT another shell project). The real test of the abstraction: if `init` needs heavy hand-holding or the engine leaks assumptions, fix the boundary here before claiming "reusable" (§8).
- 🔜 **Claude-plugin wrapper** — offer a Claude Code plugin that vendors the CLI for the skill-delivery path, while keeping the shell CLI the source of truth (§4).

## Recently shipped

- ✅ **Feedback loop — `herd backlog` drains the active backend** + `herd.sh` launcher: a project's coordinator reads open work from its tracker (file/github/linear) via `_backend_list_open`, so issues become the work source. *(PR #7)*
- ✅ **Linear backend** — `backends/linear.sh` (`SCRIBE_BACKEND=linear`): 3-op contract over Linear GraphQL; key isolated to gitignored `.herd/secrets`. *(PR #6)*
- ✅ **Watcher honors required checks / CODEOWNERS** — auto-merge gates on `mergeStateStatus=CLEAN`. *(PR #5)*
- ✅ **GitHub-Issues backend** — `backends/github.sh`; live-API smoke verified. *(PR #3)*
- ✅ **herdr version/contract preflight** — fail fast on missing/skewed herdr. *(PR #2, risk §8)*
- ✅ **Leak-guard** — healthcheck fails on single-consumer literals in the engine. *(PR #1, risk §8)*
- ✅ **Phase 2: scaffold the standalone repo** — generic engine, `herd` CLI, templates, dogfood config.
