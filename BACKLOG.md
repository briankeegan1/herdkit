# herdkit — backlog

> Single source of truth for planned herdkit work. The coordinator owns this file; the async
> scribe is the only automated writer. 🔜 planned · 🚧 in progress · ✅ shipped. herdkit is
> developed *using the herd* (workspace wB) — these items get built through its own lanes.

## Now

- 🔜 **Phase 3: feedback loop wiring** — now unblocked by the GitHub-Issues backend: wire the wB coordinator to drain `gh issue list` on the herdkit repo as a backlog source (via `_backend_list_open`), reproduce → fix via its own feature lane → cut a release `vX.Y`; consumers adopt via `herd upgrade`. Closes the cross-repo maintenance loop.

## Next

- 🔜 **Phase 3: Linear adapter** — first opt-in API backend (`SCRIBE_BACKEND=linear`): implement `backends/linear.sh` against the 3-op contract using the Linear GraphQL API, creds from `.herd/secrets`. The `backends/github.sh` shipped backend is now the reference pattern.
- 🔜 **Watcher: honor required checks / CODEOWNERS** — the `init` scout reads branch protection + CODEOWNERS, but the watcher must actually respect required status checks, required reviews, and merge queues before auto-merging, not just record them. *(risk §8: auto-merge across diverse CI)*

## Someday / Deferred

- 🔜 **Phase 4: onboard an external consumer** — run `herd init` (brownfield scout) against a genuinely different, structurally-distinct repo (a web server or a library, NOT another shell project). The real test of the abstraction: if `init` needs heavy hand-holding or the engine leaks assumptions, fix the boundary here before claiming "reusable" (§8).
- 🔜 **Claude-plugin wrapper** — offer a Claude Code plugin that vendors the CLI for the skill-delivery path, while keeping the shell CLI the source of truth (§4).

## Recently shipped

- ✅ **GitHub-Issues backend** — `backends/github.sh` (`SCRIBE_BACKEND=github`): the 3-op contract against `gh issue create/comment/close/list`; `herd init` promotes it on `.github/` detection. Live-API smoke verified (create→list→close). *(PR #3)*
- ✅ **herdr version/contract preflight** — `herd-preflight.sh` fails fast with an actionable message when herdr is missing or its CLI/JSON shape has skewed, before any lane touches it; wired into `coordinator.sh` + `new-feature.sh`. *(PR #2, risk §8)*
- ✅ **Leak-guard** — healthcheck step + hermetic test that fails on any single-consumer literal (`northstar`, hardcoded `$HOME/source/` paths, Streamlit) leaking into the generic engine; guards the abstraction boundary the dogfood can't see. *(PR #1, risk §8)*
- ✅ **Phase 2: scaffold the standalone repo** — extracted the generic engine, the `herd` CLI (`init` / `upgrade` / `report`), templates, and herdkit's own dogfood config + coordinator skill.
