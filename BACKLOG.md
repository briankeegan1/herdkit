# herdkit — backlog

> Single source of truth for planned herdkit work. The coordinator owns this file; the async
> scribe is the only automated writer. 🔜 planned · 🚧 in progress · ✅ shipped. herdkit is
> developed *using the herd* (workspace wB) — these items get built through its own lanes.

## Now

- 🔜 **Pin/probe the herdr version** — every lane assumes herdr's exact CLI/JSON shape (`herdr tab create`, `result.tab.tab_id`, `herdr agent list`). A version skew breaks all lanes at once. Probe a supported herdr version on launch and fail with a clear message instead of cryptically. *(risk §8)*
- 🔜 **Agent-rule consistency check** — a CI/healthcheck step that greps the engine for residual single-consumer literals (hardcoded `northstar`, `$HOME/source/...`, Streamlit, `app/dashboard.py`) so a project-leak can never re-enter "generic" code. Guards the abstraction boundary the dogfood can't (§8).

## Next

- 🔜 **Phase 3: Linear adapter** — first opt-in API backend (`SCRIBE_BACKEND=linear`): implement `backends/linear.sh` against the 3-op contract (`_backend_add_item` / `_backend_mark_shipped` / `_backend_list_open`) using the Linear GraphQL API, creds from `.herd/secrets`. Reference implementation that proves the adapter interface beyond the file backends.
- 🔜 **Phase 3: feedback loop wiring** — wire the wB coordinator to drain `gh issue list` on the herdkit repo as a backlog source (via `_backend_list_open`), reproduce → fix via its own feature lane → cut a release `vX.Y`; consumers adopt via `herd upgrade`. Closes the cross-repo maintenance loop.
- 🔜 **Watcher: honor required checks / CODEOWNERS** — the `init` scout reads branch protection + CODEOWNERS, but the watcher must actually respect required status checks, required reviews, and merge queues before auto-merging, not just record them. *(risk §8: auto-merge across diverse CI)*

## Someday / Deferred

- 🔜 **Phase 4: onboard an external consumer** — run `herd init` (brownfield scout) against a genuinely different, structurally-distinct repo (a web server or a library, NOT another shell+Streamlit project). The real test of the abstraction: if `init` needs heavy hand-holding or the engine leaks assumptions, fix the boundary here before claiming "reusable" (§8).
- 🔜 **Claude-plugin wrapper** — offer a Claude Code plugin that vendors the CLI for the skill-delivery path, while keeping the shell CLI the source of truth (§4).
- 🔜 **GitHub-Issues file-less backend** — promote the "coming soon" GitHub-Issues tracker option in `herd init` to a real `backends/github.sh` for projects that track work entirely in issues.

## Recently shipped

- ✅ **Phase 2: scaffold the standalone repo** — extracted the generic engine, the `herd` CLI (`init` / `upgrade` / `report`), the templates (`coordinator.md.tmpl`, `config.example`, healthcheck examples), and herdkit's own dogfood config + coordinator skill.
