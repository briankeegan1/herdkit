<!-- Provenance: HERD-329 (EPIC HERD-300). Committed evidence for the 2026-07-10 engine-port night.
     Every claim is grounded in the engine journal (`herd log`), the Linear tracker, or the GitHub PR
     record — cited by UTC timestamp or PR number, never from memory. -->

> **Date of events:** 2026-07-10 evening → 2026-07-11 early morning
> **Author:** builder for **HERD-329** (child of the engine-port EPIC **HERD-300**)
> **Method:** each claim carries a journal timestamp (UTC, from `.herd/journal.jsonl` via `herd log`),
> a git commit sha, a Linear issue id, or a GitHub PR number. Where a claim is an operator
> characterization rather than a machine record, it is labeled as such and tied to the nearest hard
> evidence.
> **Time base:** journal timestamps are UTC (`Z`). Git commit times quoted from `git log` are the
> committer's local **EDT (−04:00)** and are converted to UTC inline. The operator's "afternoon/night"
> narration is EDT.

---

# The 2026-07-10 Engine-Port Night — committed evidence for HERD-300

Scope: the night the Python engine core (EPIC **HERD-300**) went from a committed spike to its first
autonomous merges on a live seat. This document is the durable substrate the program discipline
requires — long-form evidence lives in a committed doc, never only in a coordinator session — and it
is the runbook substrate for **P5** (HERD-306, cutover). It records what the record shows: the
timeline, the soak-1 findings and which *direction* the engine failed, the kill-switch round-trip, the
parity result, the fast-lane debt the speed run took on and how it was repaid, the cost, the operator
decision trail verbatim, and the residuals carried forward.

One load-bearing distinction used throughout: the journal emits two different merge families.

- **`merge` … `method=--merge reason=gates_passed`** — *this* engine performed the merge autonomously
  after its own gates went green.
- **`merge_observed … reason=reconcile`** — the watcher *observed* a merge it did not perform (a
  hand-merge / external merge) and reconciled state afterward.

GitHub's `mergedBy` field is **not** a reliable discriminator here: the engine merges through
`gh pr merge` using the `briankeegan1` token, so `mergedBy=briankeegan1` appears on both
engine-autonomous and hand-merged PRs. The autonomous-vs-hand distinction in this document always
comes from the **journal event type**, not from `mergedBy`.

---

## 1. Timeline

All times UTC. "flip" = the `briankeegan1` seat switching `ENGINE_IMPL` to `python`
(machine-local: `herd config set --local ENGINE_IMPL python` + `herd pane watch`).

| When (UTC) | Event | Evidence |
|---|---|---|
| 07-10 18:42:55 | **EPIC HERD-300 filed** on Linear | HERD-300 `createdAt=2026-07-10T18:42:55.620Z` |
| 07-10 18:43–18:44 | P0–P5 child items filed with backlinks | HERD-301 `18:43:42Z` … HERD-305 `18:44:18Z`, HERD-306 `18:44:25Z` |
| 07-10 18:47:57 | **Spike doc committed** — `docs/spikes/engine-port-python.md` | commit `c518a0a` (`2026-07-10T14:47:57-04:00`), subject `docs(spike): engine core port to Python — phased EPIC evidence (HERD-300)` |
| 07-10 19:04:03 | **P0 merged** — engine contract freeze (`docs/engine-contract.md`) | `merge pr=413` `19:04:04Z`; PR #413 (HERD-301) |
| 07-10 19:08:58 | **P1 merged** — `herd why/log/cost` ported (byte-identical readers) | `merge pr=414` `19:08:59Z`; PR #414 (HERD-302) |
| 07-10 19:40:13 | **P2 merged** — pure decision core ported | `merge pr=415` `19:40:14Z`; PR #415 (HERD-303) |
| 07-10 19:56:26 | **P1b merged** — `herd status` bash-gather/python-format split | `merge pr=416` `19:56:27Z`; PR #416 (HERD-307) |
| 07-10 22:53–23:44 | **P3 fleet lands** (state machine, parity harness, driver dispatch, shadow runtime, dual-engine safety, parity bridge, live mode) — all via **`merge_observed reason=reconcile`** (hand-merged, watcher reconciled) | PRs #421, #422, #423, #425, #424, #426, #429; journal `merge_observed` `22:53:40Z`–`23:44:46Z` |
| 07-10 **23:45:15** | **First flip** — first `engine_live_dispatched surface=python engine_level=1` | journal `23:45:15Z` (the python engine begins owning the tick) |
| 07-11 00:11:55 → 00:40:24 | **Kill-switch round-trip** — python dispatch pauses **28 min** (fall back to bash, then re-flip); see §4 | 1709 s gap in the `engine_live_dispatched` stream; `reload_outcome … control_room rebuilt` at `00:12:01Z` and `00:40:05Z` |
| 07-11 00:26–00:40 | P3g/P3h land via **`merge_observed reason=reconcile`** (still hand-merged) | `merge_observed pr=432` `00:30:15Z`, `pr=433` `00:40:28Z` |
| 07-11 02:09–02:43 | Parity burn-down (#431) and oracle-v2 (#434) land | see §5 |
| 07-11 **02:43:12** | **First autonomous merge under the Python engine** — PR #434, P3i oracle-v2 | `merge pr=434 method=--merge reason=gates_passed` `02:43:13Z` — the first `merge` (not `merge_observed`) event after the flip |
| 07-11 03:19:05 | **2nd clean autonomous merge** — PR #435, review-debt repayment | `merge pr=435 … reason=gates_passed` `03:19:06Z` |
| 07-11 **03:44:26** | **3rd clean autonomous merge** — PR #436, sim deflake | `merge pr=436 … reason=gates_passed` `03:44:27Z` |
| 07-11 ~03:44 | **Second-seat green light** — compressed criteria met (3 real PRs end-to-end + 1 parity green); see §8 | derived from #434/#435/#436 `merge` events + §5 parity |

The P0–P2 layer (#413–#416) merged **on the bash engine** — every one carries a `merge … reason=gates_passed`
event *before* the 23:45 flip. The P3 fleet (#420–#433) merged **externally** (`merge_observed reason=reconcile`)
while the freshly-flipped Python engine held rather than merged (§3). The first three PRs the Python
engine merged *itself* were #434 → #435 → #436, `02:43 → 03:44`.

---

## 2. What shipped (the P-phase → PR → issue map)

| PR | Title / slug | Issue | Merge family | Merged (UTC) |
|---|---|---|---|---|
| #413 | engine contract freeze (P0) | HERD-301 | `merge` (bash) | 07-10 19:04:04Z |
| #414 | port `herd why/log/cost` (P1) | HERD-302 | `merge` (bash) | 07-10 19:08:59Z |
| #415 | port pure decision core (P2) | HERD-303 | `merge` (bash) | 07-10 19:40:14Z |
| #416 | port `herd status` (P1b) | HERD-307 | `merge` (bash) | 07-10 19:56:27Z |
| #421 | typed lifecycle state machine (P3b) | HERD-315 | `merge_observed` | 07-10 23:12:50Z |
| #422 | journal-diff parity harness (P3a) | HERD-314 | `merge_observed` | 07-10 23:12:51Z |
| #423 | driver-table dispatch layer (P3d) | HERD-317 | `merge_observed` | 07-10 23:29:04Z |
| #425 | shadow watcher runtime (P3c) | HERD-316 | `merge_observed` | 07-10 23:29:05Z |
| #424 | cross-seat dual-engine safety (P3.5) | HERD-308 | `merge_observed` | 07-11 00:12:25Z |
| #426 | scenario→fixture parity bridge (P3e) | HERD-319 | `merge_observed` | 07-11 00:12:26Z |
| #429 | live engine mode `ENGINE_IMPL=python` (P3f) | HERD-320 | `merge_observed` | 07-11 00:12:28Z |
| #432 | factor watcher tick `_tick_act`/`_tick_render_reconcile` (P3g) | HERD-323 | `merge_observed` | 07-11 00:30:15Z |
| #433 | live-mode gate dispatch + journal wiring + scope (P3h) | HERD-324 | `merge_observed` | 07-11 00:40:28Z |
| #431 | P3 parity burn-down (shadow models steps/panel/gate) | HERD-304 | `merge_observed` | 07-11 02:14:07Z |
| #434 | **oracle v2 — legitimate journal parity (P3i)** | HERD-325 | **`merge` (python)** | 07-11 02:43:13Z |
| #435 | **review-debt — journal-shape fixes + findings** | HERD-321 | **`merge` (python)** | 07-11 03:19:06Z |
| #436 | deflake chaos/lifecycle sims under load | HERD-326 | **`merge` (python)** | 07-11 03:44:27Z |

(#427 WEDGE_AUTOWAKE manifest and #428 MODEL_REVIEW validate merged the same window via `merge_observed`
by `Chase84000` — second-seat, still on bash — and are not port-core; noted only so the PR-number
sequence has no unexplained gaps.)

---

## 3. Soak-1 findings and the failure direction

Soak-1 = the first live run of the Python engine on the `briankeegan1` seat, from the 23:45 flip
through the first autonomous merge at 02:43. The headline: **the engine failed in the safe
direction.** It dispatched work (941 `engine_live_dispatched surface=python` events across the night)
but during soak-1 it did **not** carry the full gate→merge→journal→scope loop to completion — every
P3 PR that landed in the window merged as `merge_observed reason=reconcile`, i.e. a **human** merged it
and the watcher reconciled after. A port that *held and let a human finish the merge* is failing safe;
the dangerous direction — merging something it should not have — did not occur (there is no
`merge … reason=gates_passed` for any P3 PR before #434).

Concrete soak-1 findings, each tied to the increment that surfaced it:

- **Held-not-merged (the whole P3 fleet).** #421/#422 (`merge_observed 23:12`), #423/#425 (`23:29`),
  #424/#426/#429 (`00:12`), #432 (`00:30`), #433 (`00:40`) all reconciled from external merges. The
  Python live tick was dispatching and rendering but the autonomous merge action did not fire — the
  operator merged by hand and the watcher's reconcile layer caught up (`postmerge_reconciled`,
  `tracker_write … component=reconcile … result=DONE`). This is the P3h (#433, HERD-324) gap: live-mode
  gate dispatch + journal wiring + scope was the increment meant to close it, and the first PR that
  actually merged *through* the python tick is #434, 2h+ after the flip.

- **P3g tick split (#432, HERD-323) — render/act separation.** #432 factored the watcher tick into
  `_tick_act` + `_tick_render_reconcile`. Until that split, the python tick's *render* (console
  section) and *act* (gate/merge) paths were not cleanly separable, so the live tick could dispatch
  without a faithful console render — the "console" half of the tick lagged the "act" half. #432
  merged `00:30:15Z` (still `merge_observed`), i.e. the fix itself landed by hand during soak-1.

- **P3f live-mode was HUMAN-VERIFY-held by design (#429, HERD-320).** The builder note at
  `2026-07-10T23:43:38Z` (slug `port-p3f-live-mode`, full text in
  `.builder-notes-full/1783727018-port-p3f-live-mode.txt`) records that the live `--tick` path
  (`gh` discovery + `gh pr merge` + `git worktree remove`) **cannot be builder-verified hermetically**,
  so #429 declared **two** human-verify steps — *one live throwaway-PR tick* and *a kill-switch fault
  check* — shipped dormant / byte-identical-off. Soak-1 *is* the operator executing those two steps
  live. The kill-switch fault check is the round-trip recorded in §4.

**Failure-direction analysis.** Every soak-1 miss was a *sin of omission* (didn't merge, didn't render,
didn't yet emit a family) rather than a *sin of commission* (merged wrongly, mis-gated, corrupted
state). That is exactly the design intent stated in the EPIC — "bash `set -e` silent-skip class →
Python loud-failure default" and "ship-dormant / byte-identical-when-off": with the lever mid-adoption
the engine's worst observed behavior was to defer to the bash path and to the human. The residual risk
it did **not** yet exercise (autonomous-merge safety under two concurrent watchers) is enumerated in
§9 and in the #435 S5 findings.

---

## 4. Kill-switch record

The P3f note declared a **kill-switch fault check** as a human-verify step. The journal shows it
exercised as a clean 28-minute round-trip:

- The `engine_live_dispatched surface=python` stream, which ticks every ~5 s, has exactly **one** gap
  over 90 s across the whole night: **`00:11:55Z → 00:40:24Z` (1709 s ≈ 28 min).**
- Bracketing that gap are two full control-room rebuilds — `reload_outcome component=control_room
  result=rebuilt around the coordinator` at **`00:12:01Z`** and **`00:40:05Z`** — the visible trace of
  `herd pane watch` being re-run twice (flip the seat's `ENGINE_IMPL` back to `bash`, confirm the bash
  engine picks the tick back up, then re-flip to `python`).
- During the pause the bash engine kept the pipeline moving: #432 (P3g) reconciled at `00:30:15Z`
  inside the gap. When python dispatch resumed at `00:40:24Z`, #433 (P3h) reconciled four seconds
  later (`00:40:28Z`).

Interpretation (operator characterization, anchored to the above): the kill-switch works as
specified — flipping `ENGINE_IMPL=bash` + `herd pane watch` hands the tick back to the bash engine
with no dropped work, and re-flipping resumes the python tick. This matches the operator's standing
guarantee that "bash fallback stays one command away on both seats" (§8, the compressed-criteria
comment). No `watcher_self_restart`/`watcher_quiesce` fired for this transition (those appear only for
`reason=engine-update` earlier in the day at `00:36:46Z`/`00:41:39Z` on 07-10 and `16:30:43Z`/`16:38:40Z`),
confirming the round-trip was an operator-driven config flip, not an auto-update quiesce.

---

## 5. Parity results

Parity — a byte-faithful journal diff between the bash engine and the python shadow on the same
scenario — was the **P3a acceptance instrument** (#422, HERD-314). Its arc across the night:

1. **P3e / burn-down (#431, HERD-304) — modeled, but positionally divergent.** The builder note at
   `2026-07-11T00:08:08Z` (full text in `.builder-notes-full/1783728488-port-parity-burndown.txt`)
   records that `shadow_runtime` now **models all 6 missing families byte-exactly** (steps run+hold
   lifecycle, review-panel verdict/fold/pin, `review_log_retained`, `gate_status`, `herd-review`
   `infra_event`) and is a **canonical subset** of the real sandbox stream — *47/50 family events,
   zero over-emission*. But `parity-run --shadow auto` **still reported DIVERGENT** and could not reach
   positional OK by faithful modeling: `parity.py` diffs **positionally**, while the real stream is a
   leg-grouped, path-sorted concat prefixed by `main_health`(×6) + `push_hold`(×5) — families outside
   HERD-304's scope — and the shadow additionally carries its own `shadow_*` frames the bash tree never
   emits. The builder explicitly refused to force green by filtering ("would require modeling
   `main_health`/`push` AND suppressing the shadow's own frames … which the task forbids") and filed
   the engine question up: *should `parity.py` canonicalize away shadow-private `shadow_*` frames so the
   oracle compares semantic streams?*

2. **P3i / oracle v2 (#434, HERD-325) — legitimate parity.** The answer to that question shipped as
   PR #434, titled *"oracle v2 — legitimate journal parity on sandbox-scenario"*. This is the PR that
   turned the parity verdict green **without** filtering — the oracle was taught to compare semantic
   streams (canonicalize the volatile/shadow-private frames) rather than demand positional identity.
   #434 is also, not coincidentally, the **first autonomous python-engine merge** (`merge … reason=gates_passed`
   `02:43:13Z`): the milestone the operator shorthands as **"JOURNAL PARITY: OK"** is P3i achieving a
   *legitimate* (non-forced) journal-parity pass on the sandbox scenario.

**Honest caveat.** Parity was demonstrated on the **sandbox scenario** via oracle v2. The
**concurrency scenario** head-to-head was *not* closed the same night (see §9, residuals) — the
compressed second-seat bar (§8) required *one* parity green, which the sandbox scenario supplied.

---

## 6. Fast-lane debt ledger and its repayment

The port fleet was built in **speed mode**: the P3 PRs (#420–#433) were **hand-merged and reconciled**
(`merge_observed reason=reconcile`) rather than carried through the watcher's full authoritative gate.
The adversarial pre-merge **review gate did not complete** on several of them — the journal shows
`herd-review` reviewers timing out or being severed before writing a verdict:

- `infra_event component=herd-review pr=422 … reviewer timed out (1800s)` `23:39:41Z` (P3a)
- `infra_event component=herd-review pr=421 … reviewer timed out (1800s)` `23:36:47Z` (P3b)
- `infra_event component=herd-review pr=423 … review severed (SIGTERM/SIGPIPE)` `23:42:50Z` (P3d)
- `infra_event component=herd-review pr=426 … reviewer timed out` `00:08:37Z` (P3e)
- `infra_event component=herd-review pr=429 … reviewer timed out` `00:13:48Z` (P3f)
- `infra_event component=herd-review pr=432 … reviewer timed out` `00:55:33Z` (P3g)
- `infra_event component=herd-review pr=433 … review severed` `01:09:08Z` (P3h)

That is the debt: **the cross-module Python port surface merged without a completed per-PR adversarial
review.** The operator filed **HERD-321** at `2026-07-10T23:34:51Z` — *"Post-hoc adversarial review:
fast-laned port surface (2026-07-10 speed debt)"* — to pay it back as a single whole-surface review.

**Repayment — PR #435 (HERD-321), merged `03:19:06Z`.** Method (from the PR body): *five parallel seam
reviewers* (statemachine↔decisions; journal event shapes vs contract §3/§7; driver degrade; live-runtime
double-dispatch across an `ENGINE_IMPL` flip; readers + `__all__` + #424 heal), each finding
independently re-verified against `docs/engine-contract.md` and the bash sources of truth. It fixed
four contract-conformance defects directly (all behind the `ENGINE_IMPL=python` lever, byte-identical
with the lever off):

1. `pysrc/herd/__init__.py` — `status` was the sole package member missing from `__all__`.
2. `live_runtime.py:728` — live `review_dispatched` was missing contract-required `model` + `log_path`
   (would feed empty fields to `herd why`/`herd log`/cost and diverge from the shadow on every dispatch).
3. `live_runtime.py:918,939` — `refix_bounce` (both rails) was missing `agent_status_before` + `location`
   (5 of 7 contract fields).
4. `fixture_extract.py:222` — `_PanelFold.observe` sha guard was inconsistent with its two siblings
   (an empty-sha late event could clobber the panel's real sha).

And it **routed five structural findings** (confirmed, mostly latent while the module is not yet
live-wired) rather than papering over them:

- **S1** — `statemachine.next_after_block(STALE_HELD, …)` raises `IllegalTransition` on the common
  open-budget stale bounce; the docstrings advertise a table edge that does not exist (`statemachine.py:264`,
  missing `(STALE_HELD, REFIX_BOUNCE)` at `:138`). *Reproduced.* Latent (module not yet live-wired).
- **S2** — the port unifies both refix rails under `refix_bounce` keyed by `rule` (contract §3.4 has no
  `health_refix_bounce`) while bash emits a distinct `health_refix_bounce` — a **P3-acceptance parity
  decision** to make, not a local edit. Also `round=1` is hardcoded live/shadow.
- **S3** — the parity canonicalizer (`parity.py`) has two edges: (a) `_ABS_PATH_RE` doesn't fold the
  shadow's `log_path="(shadow)"` stub, causing a *false* divergence on a volatile field; (b) the global
  path-sub runs over semantic strings too, so a genuine "reviewer flagged the wrong file" divergence
  could be **masked**. Recommends a known-volatile-key allowlist.
- **S4** — `driver.oneshot_dispatch(ref=…)` can silently downgrade a bad ref to the active runtime
  (`driver.py:382,422`) — exactly the silent runtime downgrade the module docstring promises never
  happens. Python-only, currently unwired.
- **S5** — dual-engine multi-seat safety (HERD-308) has real gaps, all latent while `_HERD_ENGINE_LEVEL`
  is uniformly 1. **S5a (CONFIRMED):** the Python live tick bypasses `_ENGINE_SEAT_HALT` entirely — the
  halt is consulted only in bash's `post_gate_status`/`do_merge`, which are skipped when Python owns the
  tick; `LiveActuator.merge` has no equivalent check. This bites only with two concurrent watchers or a
  real engine-level bump.

Net: the fast lane bought speed by deferring the per-PR review gate on ~13 PRs; HERD-321/#435 repaid it
with a whole-surface adversarial pass that fixed four conformance bugs and left a **routed, honest
ledger** (S1–S5) instead of silent debt. S2/S3/S5 are carried forward in §9.

---

## 7. Cost rollup

From the journal's `cost` events (measured per builder + review at merge time). **A measurement gap
must be stated up front:** cost is captured at the moment *this engine* records a `merge`, so the P3
fleet that merged via `merge_observed reason=reconcile` (#420–#433) carries **no cost row at all** —
the recorded rollup below therefore **understates** the true port spend. Only the engine-merged PRs in
the #413–#436 window have cost attribution:

| PR | Slug | Builder USD | Review USD | Model (review) |
|---|---|---:|---:|---|
| #413 | port-p0-contract | 6.18 | — | — |
| #414 | port-p1-readonly-tools | 6.69 | 1.36 | opus-4-8 |
| #415 | port-p2-decision-core | 6.05 | 0.56 | sonnet-4-6 |
| #416 | port-p1b-status | 10.76 | 2.28 | sonnet-4-6 |
| #434 | port-p3i-oracle-v2 | 11.87 | 1.00 | sonnet-4-6 |
| #435 | port-review-debt | 7.38 | 0.59 | sonnet-4-6 |
| #436 | flaky-chaos-sims | 9.65 | 1.09 | sonnet-4-6 |
| — | **port-core subtotal (7 PRs)** | **58.58** | **6.88** | **≈ $65.44** |
| #417 | bats-dynamic-discovery *(non-port, interleaved)* | 8.87 | 0.72 | sonnet-4-6 |
| #419 | pipe-safety-lint *(non-port, interleaved)* | 5.86 | 1.27 | opus-4-8 |
| — | **window total (#413–#436, all recorded rows)** | | | **≈ $82.17** |

Observations: builders ran on `claude-opus-4-8` throughout; reviews mostly ran on the cheaper
`claude-sonnet-4-6` (P1 and pipe-safety on opus). The single most expensive builder was #434
(oracle v2, $11.87 — the parity-canonicalization work). The per-merged-PR cost for the recorded set is
in the ~$6–$13 range, consistent with the engine's prior overnight economics. **The true port cost is
higher than $65.44** by the unrecorded cost of the 13 reconcile-merged P3 PRs — quantifying that gap
is itself a residual (§9).

---

## 8. Operator decision trail

The compressed-criteria decision that governed the night, quoted **verbatim** from the HERD-300 EPIC
comments (Brian Keegan).

**Comment 1 — ownership (`2026-07-10T22:49:26Z`):**

> Operator taking full ownership of the port (2026-07-10): HERD-300, HERD-304, HERD-305, HERD-306,
> HERD-308 all assigned to briankeeganmusic on Linear.

**Comment 2 — the original four-part soak bar (`2026-07-10T23:32:39Z`), later superseded:**

> SECOND-SEAT SWITCH CRITERIA (Chase → python engine), set by operator 2026-07-10 night. Chase's seat
> flips ENGINE_IMPL=python (machine-local: herd config set --local ENGINE_IMPL python + herd pane
> watch) only when ALL FOUR hold: (1) the briankeegan1 seat has soaked on the python engine through
> real work — 10+ live merges or ~12h with zero engine-attributable interventions; (2) P3e parity
> burn-down complete — head-to-head green on sandbox + concurrency scenarios, divergence list empty or
> explicitly accepted; (3) ENGINE_SEAT_RECONCILE=on at BOTH seats before his flip (the P3.5 tripwire
> for the dual-engine window); (4) his machine prepped: herd update past the P3f engine level,
> ENGINE_AUTOUPDATE=check, WATCHER_SELF_RESTART=on. The COMMITTED ENGINE_IMPL default does NOT flip
> until both seats have soaked (P5, HERD-306). Coordinator will ping the operator when 1–2 are met;
> expected 2026-07-11 afternoon if tonight's cutover is clean.

**Comment 3 — the compressed bar that actually governed (`2026-07-10T23:37:12Z`), SUPERSEDES comment 2:**

> SWITCH CRITERIA COMPRESSED by operator 2026-07-10 late — SUPERSEDES the four-part soak criteria in
> the prior comment. New bar for the second seat (Chase): (1) the briankeegan1 seat's python engine
> completes THREE real PRs end-to-end (gate → merge → reap) cleanly, and (2) ONE parity head-to-head
> green (P3e) on the sandbox scenario. That is hours after the first flip, not 48. Chase then flips
> machine-local (herd update to past-P3f level, then herd config set --local ENGINE_IMPL python + herd
> pane watch) with ENGINE_SEAT_RECONCILE=on at BOTH seats — retained deliberately as the dual-engine
> tripwire. Operator explicitly accepts finding residual bugs live ('go in messy'); bash fallback
> stays one command away on both seats (config.local ENGINE_IMPL=bash + herd pane watch). Committed
> default flip (P5) still waits for both seats running clean.

**Was the compressed bar met?** Yes, against the record:

- *"THREE real PRs end-to-end (gate → merge → reap) cleanly"* → #434 (`merge` `02:43:13Z`), #435
  (`merge` `03:19:06Z`), #436 (`merge` `03:44:27Z`) — three consecutive `merge … reason=gates_passed`
  events on the python engine, each followed by its `reap`.
- *"ONE parity head-to-head green (P3e) on the sandbox scenario"* → oracle v2 / #434 legitimate journal
  parity (§5).

Both conditions cleared by `~03:44` — the **second-seat green light**. The operator's "go in messy /
bash fallback one command away" posture is corroborated by the §4 kill-switch round-trip working as a
one-command flip, and the committed-default flip (P5) explicitly remains gated on *both* seats.

---

## 9. Residuals carried forward

Open items the night did **not** close, each with its owner:

1. **Concurrency-scenario parity gap.** Parity was proven on the *sandbox* scenario (oracle v2, #434).
   The *concurrency* scenario head-to-head — part of the original four-part bar (comment 2, criterion 2)
   but dropped from the compressed bar — remains unclosed. Owner: **P3e/HERD-304 follow-through**;
   the S3 canonicalizer edges (below) block a trustworthy concurrency diff.
2. **Parity canonicalizer edges (S3, #435).** (a) `(shadow)` `log_path` stubs don't fold → false
   divergence; (b) the global path-sub can mask a *semantic* divergence. Until fixed, a green
   concurrency parity is not fully trustworthy. Owner: parity.py / HERD-321 routing.
3. **Health-rail bounce parity decision (S2, #435).** `refix_bounce{rule=healthcheck}` (python) vs
   `health_refix_bounce` (bash) is an unresolved **P3-acceptance** contract-normalization question; a
   bash↔python diff will diverge on the health bounce until it's decided.
4. **Dual-engine multi-seat safety (S5, #435; HERD-308).** S5a **confirmed**: the Python live tick
   bypasses `_ENGINE_SEAT_HALT` (`LiveActuator.merge` has no halt check). Latent while every seat is at
   engine-level 1, but it *must* be closed before two seats run the python engine concurrently.
5. **Latent state-machine + driver defects (S1, S4, #435).** `next_after_block(STALE_HELD, refix_bounce)`
   raises (S1); `oneshot_dispatch` can silently downgrade a bad `ref` (S4). Both confirmed, both latent
   because the modules aren't live-wired yet — landmines to clear before P3g/P3h paths are load-bearing.
6. **Cost-attribution gap (§7).** The 13 reconcile-merged P3 PRs carry no `cost` row; true port spend is
   understated. Either a reconcile-time cost capture or a manual reconstruction is owed for an honest
   P5 economics story.
7. **P4 (HERD-305, In Progress) — state store to SQLite** and **P5 (HERD-306, Backlog) — cutover + bash
   core deletion** are unstarted work. P4 execution waits for a quiesce window; P5's committed
   `ENGINE_IMPL` default flip waits on *both* seats soaking clean (operator, comment 3). **This document
   is P5's runbook substrate.**

---

*End of audit. Every timestamp above is a UTC journal line; every PR number resolves in the GitHub
record; the operator quotes in §8 are verbatim HERD-300 EPIC comments. Corrections belong in a
follow-up commit to this file, not in a session.*
