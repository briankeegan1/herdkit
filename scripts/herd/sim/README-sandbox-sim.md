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

## POSTURE MATRIX — `sandbox-posture-matrix.sh` (HERD-153)

Where the scenarios above each prove **one** governance stance, the posture matrix proves the shipped
gate loop under **every canonical posture** at once. The postures are committed, authoritative data in
[`templates/postures.tsv`](../../../templates/postures.tsv) — the SINGLE source of truth (HERD-141 init
v2 will consume the same file). Each posture is a small named bundle of `.herd/config` keys:

| Posture | Keys | Invariant the sim asserts |
|---|---|---|
| `solo-auto` | `MERGE_POLICY=auto` | drains fully — **byte-identical** to today's single-posture run |
| `team-approve` | `MERGE_POLICY=approve` `HUMAN_VERIFY_POLICY=hold` | **nothing merges without a sha-keyed approval** |
| `gated-push` | `PUSH_GATE=human` `PR_FLOW=draft` | **nothing reaches the remote** before the push is approved |
| `custom-steps` | `STEPS_PROFILE=approve-stage` | an approve-stage hold **releases exactly once per (sha,step)** |
| `observe-only` | `MERGE_POLICY=observe` | **nothing merges, ever** |
| `full-auto` | `MERGE_POLICY=auto` `REVIEW_AUTOFIX=true` `HEALTHCHECK_AUTOFIX=true` `COORDINATOR_AUTONOMY=full` `DEAD_BUILDER_AUTORESPAWN=on` `HUMAN_VERIFY_POLICY=coordinator` `STALE_BASE_AUTOFIX=on` `SWEEP_AUTO=auto` | drains fully — the engine-autonomous **hands-off** bundle (auto-merges on green like `solo-auto`, with the autofix/respawn/self-heal levers on) |

Each posture routes to the scenario that structurally exercises its invariant and runs it with the new
`--posture` flag (the merge-policy postures through `sandbox-concurrency-scenario.sh`, which drives the
real `do_merge` gate loop; the push/steps postures through `sandbox-scenario.sh`, which drives the real
`push-gate.sh` + `steps.sh` seams). The matrix emits **one scorecard per posture** under
`<artifacts>/<posture>/scorecard.json` and a combined `<artifacts>/matrix.json`.

```bash
# Run the whole matrix (one scorecard per posture + matrix.json):
SANDBOX_NO_SCREENSHOT=1 bash scripts/herd/sim/sandbox-posture-matrix.sh --artifacts /tmp/posture-matrix

# A single posture through its scenario:
bash scripts/herd/sim/sandbox-concurrency-scenario.sh --posture team-approve --artifacts /tmp/ta
bash scripts/herd/sim/sandbox-scenario.sh --posture gated-push --artifacts /tmp/gp

# Regression self-check — the injected PR #249 defect (a steps ledger that double-releases / releases a
# stale sha) MUST come back RED, flipping exactly the posture_invariant checkpoint:
SANDBOX_FORCE_STEPS_FAULT=1 bash scripts/herd/sim/sandbox-scenario.sh --posture custom-steps --artifacts /tmp/csf
```

The default (no `--posture`) invocation of either scenario is **byte-identical** to today — the posture
logic is inert when unset, so the per-merge sims stay cheap. The matrix is an **explicit** invocation
(a nightly candidate, not a per-merge gate). Hermetic proof:
[`../../../tests/test-sandbox-posture-matrix.sh`](../../../tests/test-sandbox-posture-matrix.sh) — the
six posture invariants, the caught fault, and the byte-identical solo-auto check.

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
command** (`herd_write_ratelimit_hook` installs it; the harness *event* — a JSON blob carrying the
usage-limit banner — is fed on stdin exactly as Claude Code does, so the injected sentinel is
whatever the hook's own extractor produces rather than a hand-written value), and
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

## P2b — disposable REAL-HERDR-PANES scenario — `sandbox-real-panes-scenario.sh`

The **pane/TUI layer** that P0/P1/P2a explicitly skip (all three run `HERD_DRIVER=headless` —
panes-as-a-view, *no herdr tabs/panes ever created*). This P2b scenario is the one tier that stands
up a **REAL, disposable herdr control room** against the local fixture and asserts the pane surface
itself via herdr's JSON output:

- a control-room **tab** with a **watcher pane + a backlog pane** (labels asserted via `pane list`);
- a **builder tab** with a **stub builder** (a file/CLI-driven agent via `herdr pane report-agent` —
  no model call);
- **agent-status transitions** `idle → working → done`, each observed via `herdr agent list`;
- **CLEAN TEARDOWN** — the disposable workspace is closed and **NO tab or pane is leaked** afterward
  (`leaked_tabs` **must be 0**), so the result satisfies the tab-leak-guard.

**Runner-context safety (tab-leak-guard / PR #180).** Because it creates *real* panes, the scenario
never touches an existing workspace: it creates its **own disposable workspace** with a UNIQUE label
(`sandbox-realpanes-sim-<pid>`), distinct from any project's `WORKSPACE_NAME`, drives only the
tabs/panes it created there, and closes that whole workspace on teardown (also from an **EXIT trap**,
so a mid-run failure still cleans up). The healthcheck's tab-leak-guard is **scoped** to the project's
own workspace (`.herd/healthcheck.project.sh`), so a disposable workspace with a different label is
never counted — running this **from inside a builder tab cannot false-red the guard** on the runner's
own tab.

**No-false-red / headless CI.** herdr is a hard dependency for the real-pane path only. When herdr is
unavailable — not installed, no running server, or forced off via `SANDBOX_NO_HERDR=1` — the scenario
**skips the pane checkpoints loudly-but-cleanly** (`result: "skip"`, exit 0) rather than failing. An
expected absence is never a red alarm.

```sh
# Stand up a real disposable control room, drive it, tear it down; inspect the scorecard:
bash scripts/herd/sim/sandbox-real-panes-scenario.sh --artifacts /tmp/rp-run
cat /tmp/rp-run/scorecard.json

# Headless / CI (or anywhere without a live herdr server): degrades to a clean SKIP, never a red:
SANDBOX_NO_HERDR=1 bash scripts/herd/sim/sandbox-real-panes-scenario.sh --artifacts /tmp/rp-ci
```

The scorecard mirrors the sandbox-sim JSON and **adds** the real-pane fields: `herdr_available`
(bool), `workspace_label`, `tabs_created`, `panes_created`, `agent_transitions` (**must be**
`["idle","working","done"]`), `leaked_tabs` (**must be 0**), `pane_captures`, `screenshots`.

Flags: `--artifacts DIR` (repo + scorecard + artifacts; `--keep` implied), `--keep`, `--label NAME`
(workspace label prefix, default `sandbox-realpanes-sim`). Env: `SANDBOX_NO_HERDR=1` (force the clean
skip), `SANDBOX_NO_SCREENSHOT=1`. Hermetic proof: `../../../tests/test-sandbox-real-panes.sh` drives
the scenario two ways WITHOUT ever touching the real herdr server — the SKIP path (clean skip, 0
fails) and a **FILE-BACKED stub `herdr`** (a JSON state machine, no real panes) that exercises the
full flow + teardown accounting — plus the scorecard shape and hermeticity checks.

> This lands the P1 follow-ups *"real herdr control room"* and *"visual confirmation"* below, in
> stub-builder mode. A hosted sandbox GitHub repo (the other P1/P2 follow-up) remains open.

## P2c — opt-in EPHEMERAL REAL-REMOTE (GitHub) tier — `sandbox-real-remote-scenario.sh`

The **hosted-repo tier** that P0/P1/P2a/P2b explicitly skip (all of them PATH-stub `gh` and never
touch a hosted repo). This P2c scenario adds the one tier that runs `gh` for **REAL** against a live
remote — behind an **env opt-in** so it stays off by default and off in CI:

- with `SANDBOX_REAL_REMOTE=1` **and** a real, **authenticated** `gh`, it provisions a **DISPOSABLE
  private** repo under the authenticated account (a clearly-sandboxed name `herd-sim-<ts>-<pid>`),
  pushes the local fixture to it, and drives the herd PR flow — `gh pr create`, the watcher's PR
  polling (`gh pr view --json mergeable,mergeStateStatus`), and `gh pr merge` — against that live
  remote;
- **DEFAULT (env unset) is byte-identical hermetic STUB** behavior: a self-contained `gh` PATH stub
  records create/merge and answers view/list, and **no network/repo is ever touched**;
- the real tier fires **only** when opted-in AND gh is authenticated — otherwise it degrades to a
  clean **SKIP** (`result "skip"`, exit 0). This **dual guard** is what keeps the hermetic CI suite
  off the real tier: even `SANDBOX_REAL_REMOTE=1` with an unauthenticated gh **skips** rather than
  reaching out (proven by the test's guard case, which asserts **zero** `gh repo create` attempts).

**GUARANTEED cleanup, including failure paths.** A disposable repo on a live account is never
stranded: an **EXIT/INT/TERM trap** runs `gh repo delete` on the provisioned repo no matter how the
run exits; if deletion fails it emits a **LOUD warning naming the repo** and appends it to a stable
leftover log (`$TMPDIR/herd-sim-leftover-repos.log`); and a **`--sweep`** helper lists (with `--yes`,
deletes) any lingering `herd-sim-*` repos on the account to mop up after a crash.

```sh
# DEFAULT — hermetic stub tier (no network, no repo); inspect the scorecard:
bash scripts/herd/sim/sandbox-real-remote-scenario.sh --artifacts /tmp/rr-stub
cat /tmp/rr-stub/scorecard.json

# OPT-IN — real disposable GitHub repo (requires `gh auth login`); repo is deleted on teardown:
SANDBOX_REAL_REMOTE=1 bash scripts/herd/sim/sandbox-real-remote-scenario.sh --artifacts /tmp/rr-real

# Mop up any stray sandbox repos a crashed run could not delete:
bash scripts/herd/sim/sandbox-real-remote-scenario.sh --sweep          # dry-run list
bash scripts/herd/sim/sandbox-real-remote-scenario.sh --sweep --yes    # actually delete
```

The scorecard mirrors the sandbox-sim JSON and **adds** the real-remote fields: `remote`
(**`real`|`stub`**), `real_remote_ran` (bool), `repo_slug`, `repo_created`, `repo_deleted`,
`pr_number`, `pr_merged`.

Flags: `--artifacts DIR` (repo + scorecard + artifacts; `--keep` implied), `--keep`, `--sweep`
(+ `--yes`). Env: `SANDBOX_REAL_REMOTE=1` (opt in to the real tier), `SANDBOX_REPO_PREFIX` (disposable
repo-name prefix, default `herd-sim`). Hermetic proof: `../../../tests/test-sandbox-real-remote.sh`
drives the DEFAULT stub path (full flow, no repo create) and the **real-requested-but-unauthenticated
GUARD** path (clean skip, zero `gh repo create` attempts — CI can never reach GitHub), plus the
scorecard shape, the `--sweep` no-op, and hermeticity. The suite **never** sets
`SANDBOX_REAL_REMOTE=1` against a real gh — the live-remote run is a **HUMAN-VERIFY** step.

> This lands the last open P1 follow-up — a **hosted sandbox repo** — as an opt-in ephemeral tier
> (disposable, auto-deleted), completing the fidelity ladder from stub → real-watcher → real-panes →
> real-remote.

## HERD-74 — SHARED-CONFIG ADOPTION scenario — `sandbox-shared-config-scenario.sh`

Closes the gate gap for `herd config set --shared`. That command opens its `config/<key>` PR from a
branch with **no worktree** — and agent-watch.sh discovers work via `git worktree list`, **not** open
PRs — so before the fix the config PR sat **ungated forever** (observed 2026-07-07: PRs #190/#191 had
zero journal entries and needed hand-merging). The fix makes `set --shared` **leave its throwaway
worktree in the pool** (`WORKTREES_DIR`) so the standard discovery → gate → merge → reap machinery
adopts it like any feature worktree — no bespoke watcher PR-discovery path.

This scenario drives **both halves against real code**, hermetically:

- it runs the **real** `bin/herd config set --shared <KEY> <VALUE>` against a fixture that has its own
  bare origin (gh stubbed) — the production path that now leaves the adoptable worktree + opens the PR
  (`shared_pr_opened`, `worktree_persisted`);
- it then sources the **real** `agent-watch.sh` (lib mode) and drives the SHIPPED gate functions
  (`_healthcheck_gate`, `_review_gate_step`, `review_verdict`, `do_merge`, `already_merged`) over the
  worktree it **discovers from the real `git worktree list`** — the exact discovery input the watcher's
  action pass parses — proving the `config/<key>` branch with no pre-existing worktree gets
  **adopted** (`discovered_by_watcher`), **gated + merged once** (`gated_and_merged`), and **reaped**
  (`reaped`, via `do_merge`'s real `git worktree remove`).

```sh
bash scripts/herd/sim/sandbox-shared-config-scenario.sh --artifacts /tmp/sharedcfg-run
cat /tmp/sharedcfg-run/scorecard.json
```

The scorecard mirrors the sandbox-sim JSON and **adds**: `key`, `branch`, `pr`, `merges`,
`healthcheck_runs`, `merged`. Hermetic proof: `../../../tests/test-sandbox-shared-config.sh`.

## HERD-127 — end-to-end GOVERNANCE scenario — `sandbox-governance-scenario.sh`

Proves the WHOLE governance **import→enforcement chain** at zero quota, in one hermetic run. A fixture
consumer's `CLAUDE.md` carries the canonical operator ruleset — *"I review every change before it is
uploaded"*, *"never co-author Claude"*, a branch convention, a commit-subject convention — and the
scenario drives every consumed feature as REAL code against a throwaway fixture. The only thing stubbed
is the LLM (never called — the deterministic `templates/governance-map.tsv` alone classifies, proven by
a `claude` PATH shim whose invocation log must stay empty) and `gh pr create` on the push-gate resume
(a local seam, exactly as `sandbox-scenario.sh`'s push-gate phase). **Zero model calls, deterministic,
no network, no herdr panes.**

It asserts, in order, as scorecard checkpoints:

- **(1) adoption** (HERD-119) — the deterministic table maps each `CLAUDE.md` sentence to its key:
  `PUSH_GATE=human` · `ATTRIBUTION_POLICY=no-ai-coauthor` · `BRANCH_TEMPLATE=feat/{slug}` ·
  `COMMIT_CONVENTION=^(feat|fix|…)` (real `_gov_statements` / `_gov_match` from `governance.sh`).
- **(2) PUSH_GATE=human** (HERD-123) — a finished stub builder is HELD pre-push; **NOTHING** reaches the
  bare `origin` until a human `approve`s, and approve resumes the push + PR.
- **(3) ATTRIBUTION_POLICY** (HERD-121) — a commit carrying a `Co-Authored-By: Claude` trailer REDS the
  real `healthcheck.sh` gate, **naming the offending sha**; a trailer-free commit stays green (no false red).
- **(4) BRANCH_TEMPLATE / COMMIT_CONVENTION** (HERD-120 / HERD-124) — a non-conforming branch name (via
  the real `herd_branch_parse`→`herd_branch_render` round-trip) and a non-conforming commit subject (via
  the real commit-convention lint) are both REFUSED; the conforming forms are accepted.
- **(5) reset contract** — the governance-augmented fixture rebuilds **byte-identical** (same HEAD sha)
  across three independent builds; teardown leaves no residue.

```sh
# Drive the whole import→enforcement chain; inspect the scorecard:
bash scripts/herd/sim/sandbox-governance-scenario.sh --artifacts /tmp/gov-run
cat /tmp/gov-run/scorecard.json

# Negative leg — flip ONE assertion (the attribution commit drops its trailer) so the gate stays
# green when it must red; the scorecard must FAIL LOUDLY (result=fail, exit 1):
SANDBOX_FORCE_GOVERNANCE_FAIL=1 bash scripts/herd/sim/sandbox-governance-scenario.sh --artifacts /tmp/gov-fail
```

The scorecard mirrors the sandbox-sim JSON and **adds** the governance fields: `governance_source`,
`statements`, `mapped_keys` (**must be 4**), `push_held`, `push_resumed`, `attribution_red`,
`offending_sha`, `branch_refused`, `commit_refused`, `reset_identical`, `model_calls` (**must be 0**).

Flags: `--artifacts DIR` (repo(s) + scorecard; `--keep` implied), `--keep`. Env:
`SANDBOX_FORCE_GOVERNANCE_FAIL=1` (the negative leg). Hermetic proof:
`../../../tests/test-sandbox-governance.sh` (end-to-end all-pass, field accounting, the negative leg's
single-flip loud failure, determinism across two runs, and no leak into the real repo).

## HERD-236 — MULTI-SEAT + STARVATION scenario — `sandbox-multiseat-scenario.sh`

No prior tier runs **two watchers** against one repo. Every multi-seat invariant (blessing dedup via
`herd/gates`, hold-comment once-per-sha, resolver single-flight, merge fairness under re-stale
pressure) was proven only in prod. This tier closes that gap.

It stands up **two REAL watcher gate loops** (`agent-watch.sh` sourced in lib mode,
`AGENT_WATCH_LIB=1`), each with its **own `$TREES`** (seat-local ledgers) and a **shared stub
remote** (`gh` on `PATH` recording merges / statuses / comments). Both seats clone one bare origin
carrying N≥2 stub-builder PRs (deterministic tiny changes, **no model call**), with
`WATCHER_SCOPE=all` and alternating PR authors so each seat owns half the queue. Tick-by-tick each
seat drives the **shipped** gate functions (`_healthcheck_gate`, `_review_gate_step`,
`post_gate_status`, `do_merge`, `_classify_conflict` / `spawn_resolver`, `_restale_note` /
`_merge_fairness_reorder`) until the shared remote shows every owned PR `MERGED`.

Scorecard asserts (`result: pass` iff `failed == 0`):

| Field | Invariant |
| --- | --- |
| `duplicate_gate_runs` | **0** — each `(pr,sha)` gets at most one `herd/gates=success` POST / no cross-seat health re-run for the same owned sha |
| `duplicate_hold_comments` | **0** — each `(pr, kind)` hold comment lands at most once across seats |
| `resolver_double_dispatch` | **0** — the owning seat dispatches a resolver **exactly once** for a CONFLICTING sha (2nd tick holds) |
| `max_restale_cycles` | **bounded** — under `MERGE_FAIRNESS=on`, max re-stale laps ≤ `_RESTALE_STARVE_THRESHOLD` while the queue drains |
| `queue_drained` | **true** — every owned PR merges exactly once on the shared remote |

```sh
# Drain 4 PRs across two seats; inspect the scorecard:
bash scripts/herd/sim/sandbox-multiseat-scenario.sh --artifacts /tmp/multiseat-run
cat /tmp/multiseat-run/scorecard.json

# Wider fan-out:
bash scripts/herd/sim/sandbox-multiseat-scenario.sh --artifacts /tmp/ms6 -n 6
```

Flags: `--artifacts DIR` (`--keep` implied), `--keep`, `-n/--prs N` (default 4, min 2). Env:
`MERGE_FAIRNESS` (default `on`), `SANDBOX_REVIEW_DELAY` (default 0). Hermetic proof:
`../../../tests/test-sandbox-multiseat.sh`.

> Two seats, one stub remote, zero model calls, no herdr panes. The scorecard also records
> `cross_seat_resolver_probe` (whether a second seat's empty local ledger would also dispatch a
> resolver for the same CONFLICTING sha — the G5 observation from the multi-seat doctrine audit);
> the shippable fail-gate is per-seat single-flight (`resolver_double_dispatch=0`).

## HERD-251 — WATCHER SELF-RESTART scenario — `sandbox-self-restart-scenario.sh`

The watcher executes the engine code it loaded at startup. When another seat merges a commit that
rewrites `scripts/herd/agent-watch.sh`, HERD-233 notices and leaves a *"restart recommended"* note —
and an operator restarts by hand (six times on 2026-07-09). `WATCHER_SELF_RESTART=on` turns that note
into a **quiesce-then-exec**, and this tier proves the whole loop against the shipped code.

It drives the **real watcher tick** in the shipped order — `_healthcheck_gate` /
`_dispatch_review` / `spawn_resolver` (the action pass) → `reconcile_main_freshness` →
`_self_restart_tick` (`agent-watch.sh` sourced in lib mode, `AGENT_WATCH_LIB=1`) — against a **real**
local git repo wired to a bare origin, with a second clone standing in for the seat that merges. The
healthcheck worker is a **real background process** writing a **real restart-safe inflight marker**, so
the drain accounting under test is production's.

Scorecard checkpoints (`result: pass` iff `failed == 0`):

| Checkpoint | Invariant |
| --- | --- |
| `suite_inflight` | tick 1 dispatches a real suite; its inflight marker is live |
| `no_arm_midsuite` | the engine merge lands **mid-suite** → the reconcile defers: no ff, no note, no quiesce |
| `suite_collects` | the in-flight suite finishes and its verdict is **collected** — a drain never discards paid work |
| `quiesce_armed` | the next tick fast-forwards `$MAIN`; the delta rewrote the watcher → armed + `watcher_quiesce` |
| `console_drain_row` | the console note reads `restarting on new engine code · draining N workers` |
| `no_new_dispatch` | mid-quiesce a second PR's healthcheck is **held** (no suite), the review spawns no reviewer, the resolver burns no respawn round |
| `stale_heal_burns_no_guard` | the stale-base heal holds **above** `record_refix` — the refix once-guard and rail budget are untouched, so the sha stays healable |
| `drain_waits` | a live gate worker **blocks** the exec and resets the idle streak |
| `self_restart_fires` | once drained for 2 consecutive ticks → `watcher_self_restart reason=engine-update shas=<old>..<new>` |
| `gates_resume_on_new_code` | after the restart `$MAIN` holds the new engine image and the held PR's suite dispatches again |
| `cap_expiry` | a worker that never drains still restarts at the inline **15-minute** cap |
| `lever_off_identical` | `WATCHER_SELF_RESTART=off` → no arm, no hold, no journal; the row still reads `restart recommended` |

```sh
# Drive the full quiesce → drain → restart loop; inspect the scorecard:
bash scripts/herd/sim/sandbox-self-restart-scenario.sh --artifacts /tmp/sr-run
cat /tmp/sr-run/scorecard.json

# Give the stub suite a longer dwell so the mid-suite merge window is wider:
SIM_SUITE_SECS=5 bash scripts/herd/sim/sandbox-self-restart-scenario.sh --artifacts /tmp/sr-slow
```

The scorecard mirrors the sandbox-sim JSON and **adds** `engine_sha` (the sha whose pull carried the
new watcher code), `restart_cap_secs` (**must be 900**) and `suite_dwell_secs`.

Flags: `--artifacts DIR` (`--keep` implied), `--keep`. Env: `SIM_SUITE_SECS` (default 2). Hermetic
proof: [`../../../tests/test-sandbox-self-restart.sh`](../../../tests/test-sandbox-self-restart.sh).

> **The one thing not performed is the `exec` itself.** A lib-mode scenario cannot replace its own
> process image with a live watcher — `HERD_HERMETIC_GUARD` exists precisely to forbid that — so
> `_self_restart_exec` is **recorded**, and the restarted watcher is modeled by re-applying
> `agent-watch.sh`'s own startup steps (a fresh process carries no quiesce state, and startup drops the
> restart note). The real function's journal line and its fail-soft refusal are proven in
> [`../../../tests/test-watcher-self-restart.sh`](../../../tests/test-watcher-self-restart.sh).

## HERD-162 — recovery hygiene under chaos — `builder-chaos-sim.sh`

The **adversary** for the recovery paths. Everything the watcher does when a builder dies is a claim
about a world it did not observe fail, so this sim force-kills a builder at each lifecycle stage and
checks that the recovery acts only on positive evidence.

Its fidelity rests on one detail: the stub `herdr` **enforces `agent_name_taken`** — an agent name
stays held until the pane or tab holding it is closed, exactly as under real herdr, where `claude` is
the pane's root process. That is the single fact that made the pre-HERD-162 respawn fail structurally
in the very crash it existed for (it created the new tab *first*, then collided with the corpse). A
stub that let `agent start` succeed over a corpse would prove nothing; the last checkpoint asserts the
constraint is real.

| Stage the builder is killed at | Invariant the sim asserts |
| --- | --- |
| pre-commit, agent still registered | the corpse's pane + tab + registry row are reaped **before** the respawn creates anything; exactly one agent and one tab end the tick |
| pre-commit, autorespawn **off** | nothing will restart it → the tracker **claim is released**, and the 💀 notification says so |
| mid-work (commits) / dirty tree | worktree, branch and tab all survive; the claim is **HELD** — releasing it would invite a duplicate build on unrecovered work |
| died **again** after its one respawn | the at-most-once budget denies a second respawn (no loop); the claim goes back |
| limit-parked, then killed | the stale limit + sendkeys rows are purged — no `claude --continue` is injected into the fresh builder |
| listed-but-**unwakeable** (herdr crash) | a positive `liveness=dead` probe overrides the stale listing; the name is freed **before** `agent start` |
| merged (the terminal reap) | all four slug-keyed ledgers close with the slug; a prefix-sharing neighbour's rows are untouched; re-reaping is a silent no-op |
| **SIGKILL mid-corpse-reap** | pane closed, tab not — a brand-new process converges the orphan tab and registry row away, then respawns exactly once |

```sh
# Run the whole chaos matrix; inspect the scorecard:
bash scripts/herd/sim/builder-chaos-sim.sh --artifacts /tmp/chaos
cat /tmp/chaos/scorecard.json
```

Flags: `--artifacts DIR` (`--keep` implied), `--keep`. Fully hermetic (local git, stub `herdr`, no
network, no model, no real tab). Unit companions:
[`test-dead-builder-respawn.sh`](../../../tests/test-dead-builder-respawn.sh) (corpse cleanup),
[`test-reap-slug-ledgers.sh`](../../../tests/test-reap-slug-ledgers.sh) (ledger lifecycle),
[`test-claim-release.sh`](../../../tests/test-claim-release.sh) (claim release).

## Simulation tiers at a glance

| Tier | Scenario | Drives | Proves |
| --- | --- | --- | --- |
| **P0** | `sandbox-scenario.sh` | a re-implemented one-PR gate | happy path + gate-fault isolation |
| **P0** | `benchmark-drain.sh` | the full herdkit flow per item (stub) | unattended N-item drain **survives a hard kill** (0 duplicates) |
| **P1** | `sandbox-concurrency-scenario.sh` | the **real** watcher gate loop, N≥3 PRs | `REVIEW_CONCURRENCY` / `HEALTH_CONCURRENCY=1` / no double-merge / drain |
| **P2a** | `sandbox-limit-resume-scenario.sh` | the **real** watcher limit path | limit-park **detect → park → scheduled → resume → complete** + kill-switch |
| **P2b** | `sandbox-real-panes-scenario.sh` | a **real** disposable herdr control room | pane/tab existence + labels, agent `idle→working→done`, **clean teardown (0 leaks)** |
| **P2c** | `sandbox-real-remote-scenario.sh` | a **real** disposable GitHub repo (opt-in) | real `gh pr create` / watcher poll / `gh pr merge`, **guaranteed repo cleanup** |
| **HERD-74** | `sandbox-shared-config-scenario.sh` | real `config set --shared` **+** the real watcher gate | a `config/<key>` branch with **no worktree** is **adopted → gated → merged → reaped** |
| **HERD-127** | `sandbox-governance-scenario.sh` | the real HERD-119 adoption table **+** the shipped PUSH_GATE / ATTRIBUTION / BRANCH_TEMPLATE / COMMIT_CONVENTION gates | the whole governance **import→enforcement chain**: `CLAUDE.md` → mapped keys → held/refused/reddened at the gate (zero model calls) |
| **HERD-236** | `sandbox-multiseat-scenario.sh` | **two real** watcher gate loops, two `$TREES`, one stub remote | multi-seat: `duplicate_gate_runs=0` / `duplicate_hold_comments=0` / `resolver_double_dispatch=0` / `max_restale_cycles` bounded / all-PRs-drained |
| **HERD-251** | `sandbox-self-restart-scenario.sh` | the **real** watcher tick + a **real** background suite worker | stale-engine **quiesce → drain → in-place re-exec**: nothing dispatched mid-drain, nothing in flight discarded, cap expiry, kill-switch |
| **HERD-162** | `builder-chaos-sim.sh` | the **real** dead-builder reconcile / corpse reap / respawn / `_reap_slug`, against a stub herdr that **enforces `agent_name_taken`** | recovery hygiene: a builder force-killed at **every lifecycle stage** (pre-commit, mid-work, dirty, limit-parked, died-again, listed-but-unwakeable) leaves **no corpse** (reaped before the respawn creates anything), **no stacked respawn**, **no immortal ledger row**, **no lost work**, and an **honest claim** (released iff genuinely abandoned) — plus a SIGKILL mid-corpse-reap that the next process converges |

> P0/P1/P2a are stub-mode and fully hermetic (local git only, no hosted repo, **no herdr panes**, no
> model). **P2b** is the pane/TUI tier: it drives a REAL but **disposable** herdr control room (unique
> workspace, closed on teardown) and **degrades to a clean skip** when herdr is unavailable. **P2c**
> is the hosted-repo tier: **opt-in** (`SANDBOX_REAL_REMOTE=1`), it provisions a **disposable** private
> GitHub repo (auto-deleted on teardown, incl. failure paths) and, without the opt-in or a real
> authenticated gh, is **byte-identical hermetic stub** / a clean skip — so CI never touches GitHub.

## Explicitly DEFERRED to P1+ (backlog follow-up note)

> The coordinator owns `BACKLOG.md`; this P0 does not edit it. Fold the follow-ups below into the
> existing *"Sandbox consumer …"* backlog item when scheduling P1.

- ~~**P1 — hosted sandbox repo.**~~ **DONE (P2c — `sandbox-real-remote-scenario.sh`).** Instead of a
  single persistent `herdkit-sandbox` repo, the opt-in P2c tier provisions a **disposable** private
  repo per run (`herd-sim-<ts>-<pid>`), pushes the fixture, runs a real `gh pr create` / watcher poll
  / `gh pr merge`, and **deletes the repo on teardown** (trap-guaranteed, with a `--sweep` mop-up and
  a loud leftover warning). Default (env unset) stays byte-identical hermetic stub. (The `TODO(P1)`
  markers in `sandbox-fixture.sh` / `sandbox-scenario.sh` still note where a *persistent* seeded repo
  would slot in, if ever wanted.)
- ~~**P1 — real herdr control room.**~~ **DONE (P2b — `sandbox-real-panes-scenario.sh`).** A
  disposable `sandbox-realpanes-sim-<pid>` workspace where the scenario spins up a REAL control room
  and asserts placement/labels/agent-status/teardown via `herdr tab list` / `pane list` / `agent
  list` JSON at each checkpoint.
- **P1 — visual confirmation.** *(Partially P2b.)* P2b captures the builder pane's contents via
  `herdr pane read` and an OS `screencapture` at the control-room checkpoint (both degrade
  gracefully). Still open: a **vision-capable judge** that asserts observable truths from those
  captures ("3 panes present", "watch console painting rows").
- **P1 — fault-injection scenarios.** Grow the `SANDBOX_FORCE_GATE_FAIL` seed into the full
  2026-07-02 bug-class matrix: kill-watcher-mid-review (INFRA retry, not cached BLOCK),
  never-committed backlog file, `PYTHONIOENCODING=ascii` (cp1252), missing optional deps (glow),
  duplicate-watcher race, focused-workspace misdirection — each asserting a LOUD failure.
- **P1 — opt-in real-model smoke mode** for the stub builder.
- **P1 — heavy-gate wiring.** Trigger a sandbox sim run before merging engine PRs that touch
  pane-creating scripts (`coordinator.sh`, lanes, `herd-review.sh`, `agent-watch.sh`, `cmd_reload`),
  analogous to `HEALTHCHECK_HEAVY_GLOB` but for the workflow surface.
