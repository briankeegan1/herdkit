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

## Falsification benchmark — `benchmark-drain.sh` (stub mode)

`benchmark-drain.sh` is **step 3** of the *herdkit vs the raw Claude harness* EPIC (see
`docs/positioning-thesis.md` + `BACKLOG.md`). The thesis names exactly one workload the raw harness
**architecturally cannot complete**: *drain an N-item backlog, unattended, surviving interruptions.*
A single Workflow invocation dies with its session — both its execution and its memory of what was
done vanish, so there is nothing durable to resume from. This harness exercises that claim **in stub
mode** (deterministic tiny changes, **no model call**) so the real overnight run later is just this
same harness with real builders + real limit resets swapped in.

It reuses `sandbox-fixture.sh` and runs the full herdkit flow per item with a **stub builder**:
`worktree branch off main → deterministic stub change → local pr.json → fixture health gate → merge
→ teardown → mark the backlog item ✅` (editing the fixture `BACKLOG.md` exactly as the scribe would).

The restart-survival test is the point: `--kill-at K` **hard-exits (SIGKILL)** the harness after the
K-th item, and a plain re-run against the **same `--state` dir** must resume from **durable state
alone** (worktrees / branches / backlog on disk — no in-memory carryover), completing the remaining
items **without duplicating** any already-shipped one.

```sh
# Fresh N=4 drain (state dir is DURABLE — never auto-deleted):
bash scripts/herd/sim/benchmark-drain.sh --state /tmp/bench -n 4
cat /tmp/bench/scorecard.json

# Restart survival: hard-exit after item 2, then resume from disk alone (0 duplicates):
bash scripts/herd/sim/benchmark-drain.sh --state /tmp/bench-kr -n 4 --kill-at 2   # exits 137
bash scripts/herd/sim/benchmark-drain.sh --state /tmp/bench-kr -n 4               # resumes → 4 shipped

# Fault-injection seed — break one item's gate so it fails LOUDLY and is never merged (stays 🔜):
BENCH_GATE_FAIL_ITEM=02 bash scripts/herd/sim/benchmark-drain.sh --state /tmp/bench-gf -n 3

# Live-run placeholder (prints and exits — see EPIC):
bash scripts/herd/sim/benchmark-drain.sh --real-builders
```

The scorecard mirrors `sandbox-scenario.sh`'s JSON and **adds** the EPIC's drain fields:
`backlog_size`, `items_drained` (cumulative ✅), `drained_this_run`, `remaining`,
`resumed_after_kill` (bool), `duplicates` (**must be 0**), `gate_failures`, `wall_clock_s`.

Flags: `--state DIR` (durable state/artifacts; `--artifacts` alias), `-n/--items N` (default 10),
`--kill-at K`, `--fresh` (wipe + re-seed), `--real-builders` (live-run placeholder). Hermetic proof:
`../../../tests/test-benchmark-drain.sh` (happy N=4 drain, scorecard shape, and the kill-at-2→resume
restart-survival path with 0 duplicates).

> **Still stub-mode.** Like `sandbox-scenario.sh`, this is local-only: no hosted repo, no herdr
> panes, no model. The `--real-builders` flag is a deliberate placeholder — the live overnight run
> (real builders + real usage-limit resets + operator hand-off) is the EPIC's step for later.

## P1 — scripted CONCURRENCY scenario — `sandbox-concurrency-scenario.sh`

Where the P0 `sandbox-scenario.sh` walks **one** PR through a re-implemented gate, this P1 scenario
opens **N≥3 stub-builder PRs simultaneously** and drives the **REAL watcher gate loop** against them.
It sources `scripts/herd/agent-watch.sh` in **lib mode** (`AGENT_WATCH_LIB=1`) and calls the shipped
gate functions — `_healthcheck_gate`, `_review_gate_step`, `_count_live_reviews`, `do_merge`,
`already_merged` — in the exact order the watcher's action pass runs them (`agent-watch.sh:2941`–3123),
tick by tick until the queue drains. So the concurrency accounting under test **is the production
code's**; the sim breaks if that code regresses.

Each PR is a real local worktree/branch off the fixture `main` with a deterministic tiny change
(**no model call**). The seams are stubbed hermetically: `gh` on `PATH` (records each merge), the
documented `HERD_REVIEW_BIN` / `HERD_HEALTHCHECK_BIN` test seams, `HERD_DRIVER=headless` (no herdr
panes/tabs ever created), an **isolated** `WORKSPACE_NAME` + temp `WORKTREES_DIR`. It never touches
the real herdkit repo's PRs, panes, or journal, and the tab-leak-guard cannot miscount it.

It asserts, as scorecard checkpoints:

- **(a) `REVIEW_CONCURRENCY` respected** — the observed peak of simultaneous in-flight reviews never
  exceeds the cap, and the cap **actively gated** (≥1 PR reported `QUEUED` while slots were full).
- **(b) `HEALTH_CONCURRENCY=1` serializes** — the stub healthcheck records the live
  `.health-inflight-*` marker count on every run and it is **always exactly 1** (no interleaving);
  a planted-holder probe additionally proves a second healthcheck **QUEUEs** rather than running.
- **(c) no double-merge, no skipped PR** — each PR's `gh pr merge` fires exactly once
  (`do_merge`'s `STATE` record makes `already_merged` idempotent) and every PR ends merged.
- **(d) the queue drains fully** — all PRs merged within the tick budget; worktrees reaped.

**Verification artifacts** (into the artifacts dir):

- `pane-<checkpoint>.txt` — the watcher console frame captured back **through the real driver
  read-pane surface** (`herd_driver_read_pane`, headless → tails the agent log). The frame carries
  the 🩺 health-check rows the real `_healthcheck_gate` paints — not a re-render.
- `screenshots/watcher-<checkpoint>.png` — macOS `screencapture` at key checkpoints. **Degrades
  gracefully** (no-false-red): skips with a note — never fails — when headless, not macOS,
  `screencapture` is absent, Screen Recording permission is missing (empty/failed capture), or
  `SANDBOX_NO_SCREENSHOT=1` is set.

```sh
# Drain 3 simultaneous stub PRs through the real gate loop; inspect the scorecard:
bash scripts/herd/sim/sandbox-concurrency-scenario.sh --artifacts /tmp/conc-run
cat /tmp/conc-run/scorecard.json

# Wider fan-out with a bigger review cap (5 PRs, 3 concurrent reviews):
REVIEW_CONCURRENCY=3 bash scripts/herd/sim/sandbox-concurrency-scenario.sh --artifacts /tmp/conc5 -n 5

# Headless / CI: skip screenshots (they’d otherwise skip themselves, but this is explicit):
SANDBOX_NO_SCREENSHOT=1 bash scripts/herd/sim/sandbox-concurrency-scenario.sh --artifacts /tmp/conc-ci
```

The scorecard mirrors `sandbox-scenario.sh`'s JSON and **adds** the concurrency fields: `prs`,
`review_concurrency`, `health_concurrency`, `peak_reviews_in_flight`, `reviews_queued`,
`health_runs`, `max_health_in_flight` (**must be 1**), `merges`, `double_merges` (**must be 0**),
`skipped_prs` (**must be 0**), `queue_drained`, `ticks`, `pane_captures`, `screenshots`.

Flags: `--artifacts DIR` (repo + scorecard + artifacts; `--keep` implied), `--keep`, `-n/--prs N`
(default 3, min 3). Env: `REVIEW_CONCURRENCY` (default 2), `SANDBOX_REVIEW_DELAY` (default 1 s — how
long each stub review stays in flight so the cap is observable), `SANDBOX_NO_SCREENSHOT`. Hermetic
proof: `../../../tests/test-sandbox-concurrency.sh` (drain + scorecard shape, the review cap, health
serialization, no-double-merge/no-skip/drain, artifact capture + graceful screenshot skip, and a
cap=3 parameterized run).

> This lands three of the P0 follow-ups below in **stub mode**: driving the real watcher loop, the
> concurrency-invariant assertions, and visual/pane confirmation. A hosted repo + a real herdr
> control room with live panes remain P1+ proper.

## P2a — end-to-end LIMIT-PARK / AUTO-RESUME scenario — `sandbox-limit-resume-scenario.sh`

The **auto-resume moat**, proven end-to-end and hermetically. Where the P1 concurrency scenario
drives the real watcher **gate** loop, this P2a scenario drives the real watcher **limit** path
(`agent-watch.sh`, sourced in lib mode): a stub builder hits the account usage limit, the watcher
**detects** the park via the hook sentinel, **schedules** an in-place resume honoring
`HERD_LIMIT_RESUME_BUFFER`, and at the reset **relaunches** the builder via `claude --continue`.
Every step is the shipped code — `_detect_limit_hit`, `_handle_limit_blocked`, `_resume_builder`,
`record_limit`/`clear_limit`, `limit_state`/`limit_target_epoch` — called in the exact order and
under the exact guard the watcher's action pass uses (`agent-watch.sh:2910`–2913). This is the e2e
proof of the auto-resume moat that HERD-42's A/B run invokes.

Only the two things that would be a live account + a live Claude session are stubbed, both through
documented seams: the rate-limit **sentinel is written by the ACTUAL `StopFailure`/`rate_limit` hook
command** (`herd_write_ratelimit_hook` installs it; a near-future reset epoch is fed on stdin exactly
as the harness would — so the injected sentinel matches the hook's format byte for byte), and
**`claude` is a stub shim on `PATH`** that records its invocation (argv + cwd), completes the parked
task deterministically (implements + commits the pending feature, no model call), and flips the agent
to `working` so the watcher's wake-verify observes the resume. The `herdr` agent surface is a
file-driven stub (the same seam the unit tests stub).

It asserts, as scorecard checkpoints:

- **`detect`** — `_detect_limit_hit` returns the reset epoch parsed from the injected hook sentinel.
- **`park`** — the first sighting records a `scheduled` hold + a **distinct NON-RED** console row (a
  usage limit is an expected account event, never a red alarm) + journals `limit_detected`.
- **`scheduled`** — the resume target honors `HERD_LIMIT_RESUME_BUFFER`: `target == reset + buffer`,
  asserted at a **non-default** buffer so the knob is proven, not the fallback.
- **`resume`** — at `reset + buffer` the backstop relaunches via `claude --continue` **in the
  worktree**; the shim's invocation is recorded, the journal logs `limit_resume_result` `woke:1`.
- **`complete`** — the resumed builder's deterministic task landed (feature committed on its branch)
  and the limit ledger + sentinel were cleared.
- **`negative_no_park`** — with `HERD_LIMIT_DETECT=off` the **same** injected sentinel yields no
  detection, no ledger record, and no `claude` relaunch (the feature kill-switch holds).

Verification artifacts mirror the concurrency scenario: `pane-<checkpoint>.txt` (the watcher's real
limit rows, captured back through `herd_driver_read_pane`) and `screenshots/watcher-<checkpoint>.png`
(macOS `screencapture`, **degrades gracefully** — skips, never fails).

```sh
# Drive the full limit-park → auto-resume path; inspect the scorecard:
bash scripts/herd/sim/sandbox-limit-resume-scenario.sh --artifacts /tmp/lr-run
cat /tmp/lr-run/scorecard.json

# Headless / CI: skip screenshots (they'd skip themselves, but this is explicit):
SANDBOX_NO_SCREENSHOT=1 bash scripts/herd/sim/sandbox-limit-resume-scenario.sh --artifacts /tmp/lr-ci
```

The scorecard mirrors the sandbox-sim JSON and **adds** the limit fields: `reset_epoch`,
`resume_buffer`, `resume_target` (**must equal** `reset_epoch + resume_buffer`), `claude_relaunches`
(**must be 1**), `task_completed` (**must be true**), `pane_captures`, `screenshots`.

Flags: `--artifacts DIR` (repo + scorecard + artifacts; `--keep` implied), `--keep`. Env:
`HERD_LIMIT_RESUME_BUFFER` (default 120 here — asserted), `SANDBOX_NO_SCREENSHOT`. Hermetic proof:
`../../../tests/test-sandbox-limit-resume.sh` (the five moat checkpoints, the buffer assertion, the
negative kill-switch path, artifact capture + graceful screenshot skip, hermeticity, and determinism
across two runs). Unit-level coverage of the same pieces lives in `../../../tests/test-limit-resume.sh`.

## Simulation tiers at a glance

| Tier | Scenario | Drives | Proves |
| --- | --- | --- | --- |
| **P0** | `sandbox-scenario.sh` | a re-implemented one-PR gate | happy path + gate-fault isolation |
| **P0** | `benchmark-drain.sh` | the full herdkit flow per item (stub) | unattended N-item drain **survives a hard kill** (0 duplicates) |
| **P1** | `sandbox-concurrency-scenario.sh` | the **real** watcher gate loop, N≥3 PRs | `REVIEW_CONCURRENCY` / `HEALTH_CONCURRENCY=1` / no double-merge / drain |
| **P2a** | `sandbox-limit-resume-scenario.sh` | the **real** watcher limit path | limit-park **detect → park → scheduled → resume → complete** + kill-switch |

> Every tier is stub-mode and hermetic (local git only, no hosted repo, no herdr panes, no model). A
> hosted sandbox repo (P2b) and a real herdr control room with live panes (P2c) remain the follow-ups
> below.

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
