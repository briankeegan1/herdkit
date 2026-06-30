# herdkit — backlog

> Single source of truth for planned herdkit work. The coordinator owns this file; the async
> scribe is the only automated writer. 🔜 planned · 🚧 in progress · ✅ shipped. herdkit is
> developed *using the herd* (workspace wB) — these items get built through its own lanes.

## Now

- 🔜 **Phase 3: feedback loop wiring** — now unblocked by the GitHub-Issues backend: wire the wB coordinator to drain `gh issue list` on the herdkit repo as a backlog source (via `_backend_list_open`), reproduce → fix via its own feature lane → cut a release `vX.Y`; consumers adopt via `herd upgrade`. Closes the cross-repo maintenance loop. *(Natural first task once herdkit self-hosts — it IS the dogfood loop.)*

## Someday / Deferred

- 🔜 **Phase 4: onboard an external consumer** — run `herd init` (brownfield scout) against a genuinely different, structurally-distinct repo (a web server or a library, NOT another shell project). The real test of the abstraction: if `init` needs heavy hand-holding or the engine leaks assumptions, fix the boundary here before claiming "reusable" (§8).
- 🔜 **Claude-plugin wrapper** — offer a Claude Code plugin that vendors the CLI for the skill-delivery path, while keeping the shell CLI the source of truth (§4).

## Recently shipped

- ✅ **Linear backend** — `backends/linear.sh` (`SCRIBE_BACKEND=linear`): 3-op contract over the Linear GraphQL API; key isolated to gitignored `.herd/secrets` (never in config); `herd init` promotes it when a key is supplied. *(PR #6)*
- ✅ **Watcher honors required checks / CODEOWNERS** — auto-merge now gates on `mergeStateStatus=CLEAN` (folds in required reviews/checks/up-to-date); holds BLOCKED/BEHIND/UNSTABLE instead of merging. *(PR #5)*
- ✅ **GitHub-Issues backend** — `backends/github.sh` (`SCRIBE_BACKEND=github`): 3-op contract over `gh issue create/comment/close/list`; `herd init` promotes it on `.github/` detection. Live-API smoke verified. *(PR #3)*
- ✅ **herdr version/contract preflight** — `herd-preflight.sh` fails fast when herdr is missing or its CLI/JSON shape skewed, before any lane touches it. *(PR #2, risk §8)*
- ✅ **Leak-guard** — healthcheck step + test that fails on any single-consumer literal leaking into the generic engine. *(PR #1, risk §8)*
- ✅ **Phase 2: scaffold the standalone repo** — generic engine, `herd` CLI (`init`/`upgrade`/`report`), templates, dogfood config + coordinator skill.
