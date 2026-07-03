# Sandbox consumer simulation — P0 (local-only)

A safe, hermetic, local-only slice of the backlog item *"Sandbox consumer — a dummy repo + herdr
workspace for live workflow simulation."* This P0 builds the deterministic scaffolding; it does
**not** create a hosted GitHub repo and does **not** spin real herdr panes (those are P1+ — see the
follow-up note below).

## What ships in P0

| File | Role |
| --- | --- |
| `sandbox-fixture.sh`  | Deterministic LOCAL fixture generator. Builds a throwaway git repo (tiny real app + seeded `BACKLOG.md` + minimal `.herd/config`) that resets to a **byte-identical** starting state — same files, same pinned git identity/date, same HEAD sha — every run. |
| `sandbox-scenario.sh` | Scenario-runner **skeleton**. Walks `init → (stubbed) build → PR → gate → merge → teardown` using a **STUB builder** (deterministic tiny file change, **no model call**). Asserts every checkpoint via git/file state and emits a machine-readable scorecard. |
| `README-sandbox-sim.md` | This file. |
| `../../../tests/test-sandbox-sim.sh` | Hermetic test: fixture determinism, end-to-end stub scenario, scorecard emission, and the gate-fault path. |

## Usage

```sh
# Build a deterministic fixture and print its (stable) HEAD sha:
bash scripts/herd/sim/sandbox-fixture.sh /tmp/sandbox-fixture

# Run the happy-path scenario, keeping artifacts to inspect the scorecard:
bash scripts/herd/sim/sandbox-scenario.sh --artifacts /tmp/sandbox-run
cat /tmp/sandbox-run/scorecard.json

# Fault-injection seed: break the app so the gate fails LOUDLY and the merge is skipped:
SANDBOX_FORCE_GATE_FAIL=1 bash scripts/herd/sim/sandbox-scenario.sh --artifacts /tmp/sandbox-fail
```

## Scorecard format

`scorecard.json` (written to the artifacts dir at the end of every run):

```json
{
  "scenario": "stub-happy-path",
  "artifacts_dir": "…",
  "repo_dir": "…/repo",
  "fixture_sha": "…",
  "result": "pass",
  "passed": 8,
  "failed": 0,
  "skipped": 0,
  "checkpoints": [
    { "name": "fixture_built", "status": "pass", "detail": "…" }
  ]
}
```

`status` is one of `pass` / `fail` / `skip`. `result` is `pass` iff `failed == 0`.

## Explicitly DEFERRED to P1+ (backlog follow-up note)

> The coordinator owns `BACKLOG.md`; this P0 does not edit it. Fold the follow-ups below into the
> existing *"Sandbox consumer …"* backlog item when scheduling P1.

- **P1 — hosted sandbox repo.** Provision a real `herdkit-sandbox` GitHub repo and a `herd sim
  init` that deterministically resets its remote state (fresh branch, clean worktrees, seeded
  issues). `sandbox-scenario.sh`'s local `pr.json` record becomes a real `gh pr create`.
  (Grep for `TODO(P1)` in `sandbox-fixture.sh` / `sandbox-scenario.sh`.)
- **P1 — real herdr control room.** A dedicated `sandbox` workspace where scenarios spin up a REAL
  control room; assert placement/layout/labels/teardown via `herdr tab list` / `pane list` /
  `agent list` JSON at each checkpoint. P0 asserts git/file state only.
- **P1 — visual confirmation.** Capture pane contents / OS screenshots at checkpoints and have a
  vision-capable judge assert observable truths ("3 panes present", "watch console painting rows").
- **P1 — fault-injection scenarios.** Grow the `SANDBOX_FORCE_GATE_FAIL` seed into the full
  2026-07-02 bug-class matrix: kill-watcher-mid-review (INFRA retry, not cached BLOCK),
  never-committed backlog file, `PYTHONIOENCODING=ascii` (cp1252), missing optional deps (glow),
  duplicate-watcher race, focused-workspace misdirection — each asserting a LOUD failure.
- **P1 — opt-in real-model smoke mode** for the stub builder.
- **P1 — heavy-gate wiring.** Trigger a sandbox sim run before merging engine PRs that touch
  pane-creating scripts (`coordinator.sh`, lanes, `herd-review.sh`, `agent-watch.sh`, `cmd_reload`),
  analogous to `HEALTHCHECK_HEAVY_GLOB` but for the workflow surface.
