# AGENTS.md — herdkit engine conventions

Conventions every agent working in this repo (builder, resolver, coordinator, or a human) must
follow. This file is the portable, runtime-agnostic sibling of the auto-loaded `CLAUDE.md`: Claude
Code reads `CLAUDE.md` for free, but a non-Claude runtime (grok, codex, …) does not, so the engine
inlines these conventions into every builder's task spec and grounds grok's system prompt from this
file. Keep it short, factual, and current.

## The ship-a-change pipeline (code → PR → gate → merge)

1. **Build ONLY your change in your worktree.** Each item is built in an isolated git worktree; do
   not reach outside it.
2. **Verify your OWN surface, then open a PR.** Run `scripts/herd/healthcheck.sh "<worktree>" --light`
   (per-changed-file syntax) plus any test you added or changed, and get a clean pass. Fix any CODE
   errors; data/env warnings are fine. The whole-project heavy profile is DESCOPED for builders —
   the auto-merge watcher re-runs the full profile as the authoritative merge gate.
3. **The watcher owns the merge.** A builder never merges its own PR. The watcher merges ready PRs
   only after both gates go green (healthcheck + adversarial pre-merge review). If your change needs
   a manual step you cannot perform (a live smoke test, a UI/pane check), declare it in a
   `HUMAN-VERIFY:` block in the PR body — one step per line — which holds the PR for a human approve.

## Ownership boundaries

- **The tracker and `BACKLOG.md` are coordinator-owned.** Builders NEVER edit `BACKLOG.md` and never
  write the work tracker (a Linear/GitHub issue's state, labels, or assignee). A builder that mutates
  tracker state corrupts the queue. The coordinator owns ALL item states.
- **Never read or commit `.herd/secrets`.** Credentials never land in a committed or generated file.
  `DENY_PATHS` stays honored.

## Design invariants for new behavior

- **Ship-dormant / default-off.** New behavior is gated behind a config key (or an explicit opt-in)
  whose default is OFF. Turning it off must be a HARD no-op.
- **Byte-identical-when-off.** With the new lever off, output/argv/task-specs/generated files must be
  byte-for-byte identical to before your change. Tests assert this.
- **Fail-soft.** A missing OPTIONAL tool, file, or capability skips SILENTLY — it never produces a red
  row and never aborts a caller running under `set -euo pipefail`. Gate keys fail STRICT (fall back to
  the safest default and warn loudly); cosmetic keys fail soft to the documented default.

## Commits & attribution

- **NO AI co-author trailer on commits.** Never add `Co-Authored-By: Claude …` or a
  `Generated with Claude` line. (`ATTRIBUTION_POLICY=no-ai-coauthor` enforces this at the gate.)

## Testing discipline

- **Run `scripts/herd/healthcheck.sh` before every PR** (see the pipeline above).
- **Sim-first for load-bearing changes.** Any change to gate / merge / concurrency / limit / pane
  behavior must be proven with a simulation, not only unit asserts. Use the scenarios under
  `scripts/herd/sim/` (e.g. `sandbox-concurrency-scenario.sh`, `retirement-invariant-sim.sh`).
- **Prove your lever both ways.** Add a test asserting behavior when ON and byte-identical output
  when OFF.

## Orienting fast

A deterministic map of the engine tree is committed at `docs/codemap.md` (module roles,
who-sources-whom, config-key → consumer wiring; regenerate with `herd codemap`) and a function-level
def→caller index at `docs/symbol-index.md` (`herd symbol-index`). Read them FIRST to skip
re-exploring the tree.
