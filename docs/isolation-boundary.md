# The engine/project isolation boundary

*What the herdkit engine will and will not touch — and what enforces it.*
Filed as HERD-435 / GitHub issue #547 ("herdkit engine and unrelated project repos must be isolated").

herdkit runs inside a live checkout that a human is also working in, drives a pool of builder
worktrees beside it, and may sit on a machine that hosts entirely unrelated projects. This document
states the boundary in both directions, names the guard that enforces each half, and records what was
verified empirically rather than reasoned about.

---

## 1. The tree layout

```
~/source/myproject/            PROJECT_ROOT   — the main checkout. The engine commits here.
~/source/myproject-trees/      WORKTREES_DIR  — the builder worktree pool. A SIBLING, never inside.
                               (default "${PROJECT_ROOT}-trees", scripts/herd/herd-config.sh:201)
~/source/some-other-project/   an unrelated repo. Outside both. The engine never sees it.
```

`WORKTREES_DIR` is a **sibling** of `PROJECT_ROOT`, not a subdirectory, and it is never committed:
worktrees are registered under `PROJECT_ROOT/.git/worktrees/` and their checkouts live outside the
tracked tree entirely. Nothing the engine writes into the pool can reach a herdkit commit.

**Recommended layout: keep unrelated projects OUTSIDE the herdkit working tree.** Not because the
engine would eat them — §3 shows it does not — but because a nested repo shows up as untracked noise
in the shared checkout's `git status`, where a *human*'s `git add -A` can swallow it as a gitlink.
The engine's own discipline cannot protect you from your own shell.

If the other project wants herdkit's pipeline, give it its **own herd project** (`herd init`, or
`herd fleet new` for a one-command spin-up) with its own `PROJECT_ROOT`, `WORKSPACE_NAME`, worktree
pool and watcher lock. If it just needs agents, use isolated Claude Code worktree agents — not the
shared live engine, whose watcher, health slots and default branch are already carrying this seat's
work.

---

## 2. Engine → project: every git write names its paths

**The rule.** No engine path stages by scan. Every production staging call names the paths it means,
and every automatic commit carries a `--` pathspec:

| site | shape |
|---|---|
| `scripts/herd/agent-watch.sh:5453,5550` (codemap + symbol-index reconcile — the only **automatic** commits) | `git -C "$MAIN" commit -q -m "$msg" -- "$out"` |
| `scripts/herd/backends/file.sh`, `backends/changelog.sh` (scribe) | `git add "$BACKLOG_FILE"` then an index-scoped commit |
| `scripts/herd/fleet.sh:257` (project seed) | `git add -- "${commit_paths[@]}"` |
| `bin/herd` (`config set --shared`) | `git -C "$wt" add .herd/config` + `commit … -- .herd/config` |
| `pysrc/herd/work_unit.py:697,699` (the python core's doc-apply adapter) | `git add --` / `git commit … --` + explicit paths |

Every `git add -A` in the tree lives under `scripts/herd/sim/` and operates on a throwaway fixture
repo in a temp dir. No production path has one. There is no `git clean` anywhere in the engine — the
one git operation that would *delete* an untracked nested repo is simply never run.

**What enforces it.** That property used to be *emergent*: it held only because each call site was
written carefully, and nothing stopped the next one from breaking it. `scripts/herd/git-scope-lint.sh`
makes it **enforced**. It reds, in any production engine path:

- **repo-wide staging** — `git add -A` / `--all` / `-u` / `.` / `:/` / `*`, and `git commit -a|-am|--all`;
- **an unscoped commit** — a `git commit` with no `-- <pathspec>`, which takes the whole index and can
  therefore carry a path someone else staged in the shared checkout.

The lint is sourced by **both** gate surfaces — `scripts/herd/healthcheck.sh` (the builder's light
pre-PR gate) and `.herd/healthcheck.project.sh` (the authoritative heavy/merge gate) — so they can
never disagree. It covers the shell surface and `pysrc/herd/*.py` alike: lines are normalized
(quotes and commas to spaces) so one grammar matches `git -C "$d" add -A` and
`["git", "-C", d, "add", "-A"]` equally.

`scripts/herd/sim/`, `scripts/herd/experiment/` and `tests/` are classified **FIXTURE**: they build
throwaway repos in temp dirs, `git add -A` is the right thing there, and they are scanned, counted in
the advisory, and never flagged. The distinction is asserted by test, not left to a glob that happens
not to recurse.

**The escape hatch.** A deliberate exception carries an inline rationale:

```sh
# herd-scope-ok: index-scoped — the named `git add "$BACKLOG_FILE"` above is all that is staged.
git commit -q -m "$msg" 2>/dev/null || true
```

honored on the offending line, anywhere in a continued command, or on the comment run directly above
it. The seven annotations in the tree today are the scribe backends' index-scoped commits (which
commit after a named `git add`), the `fleet new` seed commit, and one line of operator hint text.

---

## 3. What actually happens to a nested repo — measured, not reasoned

`tests/test-nested-repo-isolation.sh` puts a real second git repo *inside* a fixture herdkit tree and
runs the **real** engine paths over it. Observed, and now asserted as a regression:

| operation | result |
|---|---|
| baseline | the nested repo is one untracked entry, `?? game/` — nothing more |
| scribe `_backend_add_item` / `_file_marker_commit` (real code) | commit touches exactly one file, `BACKLOG.md` |
| the watcher's reconcile commit shape, `commit -m msg -- <out>` | confined to its single output file |
| `git worktree add` into the sibling pool | nested repo untouched; **absent** from the builder worktree (it was never on the branch) |
| `git reset --hard` (the engine's rollback shape) | the untracked nested repo survives intact — `reset` rewrites tracked paths only |
| **counterfactual:** `git add -A` in the same tree | **stages the nested repo as a gitlink** (`A  game`) |

Across all of them the nested repo is never staged, never committed, never appears in `git ls-files`
or in the outer repo's history, never moves, and its own HEAD never advances.

The last row is the point of the lint: the hazard is real, it is one careless line away, and it is now
a gate error rather than a matter of everyone remembering.

---

## 4. Project → engine: already covered, with evidence

The reverse direction — an unrelated project disturbing a live herdkit engine — is carried by
machinery that already exists. Each accidental path has a named guard:

| failure mode | guard |
|---|---|
| a console launched from a foreign `$PWD` silently binds to herdkit's own dogfood config and impersonates another repo's watcher on the same lockfile (the 2026-07-02 cross-project kill, issue #60) | the **launch-binding guard**, `scripts/herd/herd-config.sh:225` — `HERD_REQUIRE_PROJECT_CONFIG=1` (set by agent-watch, herd-watch, backlog-view, coordinator) hard-exits on a rule-3 fallback bind; `HERD_ALLOW_FOREIGN_CWD=1` is the documented opt-in |
| one project's watcher reaped as another's "duplicate" | the **argv0 tag**, `scripts/herd/agent-watch.sh:13758` — each watcher re-execs once as `herd-watch-<workspace>`, so a sibling project's watcher is never mistaken for a dup |
| a builder worktree actuating the operator's control room (`herd config set`, `herd reload` → watcher death mid-run) | `scripts/herd/context-guard.sh` — one reconciled check in `bin/herd`'s dispatch; actuators are legal only from the main checkout, reads stay fully allowed |
| a healthcheck run in one project reding on another project's panes/tabs | the **leak-guard's workspace scoping**, `.herd/healthcheck.project.sh` (issue #78) — only tabs leaked into *our* workspace count |

**The remaining gap: none that a guard should close.** After accounting for those four, the one
scenario left in issue #547 — "pointing an unrelated project's content-builders at the shared live
engine collides with active epic work on this seat" — is not an accident the engine can detect. It is
a *deliberate* decision to run two bodies of work through one seat, and it is already answered by
existing machinery rather than by a missing check: give the second project its own herd project
(`herd init` / `herd fleet new`), which gives it its own `PROJECT_ROOT`, `WORKSPACE_NAME`, worktree
pool, watcher lock and health slots — or use isolated worktree agents for its content work. That is a
layout choice, documented in §1, not a hole. Inventing a guard for it would only red a configuration
an operator chose on purpose.

---

## See also

- `scripts/herd/git-scope-lint.sh` — the guard, and its `# herd-scope-ok` contract
- `tests/test-git-scope-lint.sh` — the lint reds in production paths, stays clean on sim fixtures
- `tests/test-nested-repo-isolation.sh` — the measured nested-repo guarantee
- `docs/multi-seat-doctrine.md` — many coordinator seats in parallel, invariance-first
- `scripts/herd/context-guard.sh` — the builder-vs-control-room invariant
