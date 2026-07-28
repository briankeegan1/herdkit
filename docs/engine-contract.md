# The herdkit engine contract

**Tracker:** HERD-301 (P0 of EPIC **HERD-300** — port the engine core to Python)
**Status:** contract freeze — **docs only, no engine code changes.** This is the specification
the Python engine-core port must honor.
**Date:** 2026-07-10
**Audience:** the port implementer + engine maintainers
**Scope:** the *engine core* the port targets — the watcher gate/merge state machine, sha-keyed
verdict ledgers, refix budgets, holds, and the journal readers. Lane glue, pane spawning, git
plumbing, `herdr` substrate, and project `healthcheck.project.sh` commands stay bash
(`docs/spikes/engine-port-python.md` §2).

---

## 0. How to read this contract

This document is the port's spec **and** a distillation of five months of scar tissue. The
comments in `scripts/herd/agent-watch.sh` are the real spec of the doctrine (row truth,
positive-evidence death, once-guards, sha-keying); the port must be written **from this
contract, not by transliterating the bash** (`docs/spikes/engine-port-python.md` §4, the
"don't port the doctrine wrong" risk).

Rules of this document:

- **Every normative rule carries at least one live-code anchor** in `file:line` form. An anchor
  names *where the rule lives today*, not necessarily how the port should structure it.
- **Anchors were re-verified against the live tree** at `agent-watch.sh` = 12,469 lines (the
  `docs/spikes/engine-port-python.md` "12,209" figure is an older snapshot; the 2026-07-09
  gating-hardening audit `docs/audits/2026-07-09-gating-hardening.md` cites the file at 7,706
  lines and **all of its line numbers are stale** — do not port from them).
- **IMPLEMENTED vs. TARGET.** Most of this contract is already realized in bash and the anchor
  points at the realization. Where a rule is *design-not-yet-built* — the four folded items in
  §6 — the rule is marked **TARGET** and the anchor points at the seam it slots into plus the
  spike that specifies it. The port implements the TARGET semantics; the bash tree is where they
  are absent.
- **Idempotence and sha-keying are the spine.** Almost every gate artifact is keyed on
  `(pr, sha)` (or `(pr, sha, kind)`); "run once per change, discard on a new change" is the
  single most repeated invariant in the engine. Read §2.4 first if you read nothing else.

Companion specs on the same seam (cross-reference, do not duplicate): the work-unit delivery
abstraction (`docs/spikes/work-unit-abstraction.md` — the gate/apply/reconcile spine
generalized past `git-pr`) and the merge-result gate (`docs/spikes/merge-result-gate.md` —
HERD-296, §6.4 here).

---

## 1. Vocabulary

| Term | Meaning |
|---|---|
| **Subject** | The thing under gate: a pull request, identified by its `pr#`. (The work-unit spike generalizes this to an opaque `unit_id`; today `pr#` is the subject key.) |
| **Version key** | The content fingerprint of the subject: the git head **`sha`**. Every verdict, budget, and hold is keyed on `(pr, sha)` — a new sha is a new thing to gate. |
| **Gate** | A deterministic readiness check that emits one of the four outcomes in §2.2 for a `(pr, sha)`. The two model/suite-backed gates are the **rails**: **review** (adversarial correctness) and **health** (healthcheck). |
| **Rail** | A gate that a builder can be bounced to fix and that carries its own refix budget: `review`, `health`, `stale` (stale-base), `ci`. |
| **Verdict** | A rail's recorded outcome for a `(pr, sha)`, with a **provenance** (`source`). |
| **Provenance** | Where a verdict came from: `reviewer` (a real model verdict) vs. non-reviewer sources. Only `reviewer` verdicts may bounce a builder (§4). |
| **Hold** | A gates-passed subject deliberately *not* merged, awaiting a human (or coordinator) signal: human-verify or approval. A hold is not a failure (§5.4–5.5). |
| **Refix budget** | The bounded number of times a subject may be bounced back to its builder to fix a rail failure, per rail, with a total ceiling (§4). |
| **Row truth** | The console-row doctrine: a row states *whose move it is*; `needs-you` means nobody/nothing is clearing it (§5.1). |
| **Blessing** | The one cross-seat-shared gate artifact: a `herd/gates=success` commit status on the head sha, posted after both rails pass (§2.3). |

---

## 2. The gate contract

> **In:** a subject (`pr#`) + a version key (`sha`).
> **Out:** exactly one of **PASS · BLOCK · ESCALATE · HOLD**.
> **Idempotent** per `(pr, sha)`: a recorded outcome is reused, never recomputed, until the sha
> moves.

### 2.1 The candidate pass (current gate sequence)

The watcher processes candidates one per loop iteration in the action pass
(`agent-watch.sh:11938`). The gates fire in a **fixed linear order**, each `continue`-ing the
iteration on a non-pass so no later (more expensive) gate runs on a doomed sha. The order — the
cheap deterministic checks first (HERD-227 already moved stale-dup to the front; the audit's
"gate order inverted" finding is closed here) — is:

| # | Step | Anchor | Cost class |
|---|---|---|---|
| 1 | infra circuit-breaker gate | `agent-watch.sh:11949` | trivial |
| 2 | cross-seat gate-dedup heal (skip if another seat blessed this sha) | `agent-watch.sh:11968` | trivial |
| 3 | **stale/dup gate** (pure git: merge-base + name-only diff) | `agent-watch.sh:11992` | deterministic-cheap |
| 4 | parallel review pre-dispatch (optional, `PARALLEL_REVIEW`) | `agent-watch.sh:12001` | LLM |
| 5 | **health gate** (healthcheck suite) | `agent-watch.sh:12009` | deterministic-slow |
| 6 | pre-merge re-verify (`gh pr view` — mergeable/state/head) | `agent-watch.sh:12028` | trivial |
| 7 | stale/dup **re-check against current base** (unconditional) | `agent-watch.sh:12104` | deterministic-cheap |
| 8 | **review gate** (consume the adversarial verdict) | `agent-watch.sh:12139` | LLM |
| 9 | cross-seat BLOCK precedence (another seat's standing BLOCK on this sha) | `agent-watch.sh:12191` | trivial |
| 10 | post the **blessing** (`herd/gates=success`) | `agent-watch.sh:12204` | trivial |
| 11 | hold / observe / merge **policy decision** | `agent-watch.sh:12257` | trivial |
| 12 | **do_merge** | `agent-watch.sh:12333` | apply |

Steps 3/7 are the same `_stale_dup_gate_step` check run twice — once early to cheapen, once
unconditionally in the instant before merge so clearance is always against the **current** base,
never inferred from this seat's prior work (`agent-watch.sh:12104`, the clean-but-behind clobber
guard). The port must preserve "re-evaluate the cheap deterministic gate against live base
immediately before applying."

### 2.2 The four normalized outcomes

The contract's four outcomes are a *normalization*; the bash tree realizes each under its own
name. The port emits the normalized outcome and maps to these behaviors:

| Outcome | Meaning | Live realization |
|---|---|---|
| **PASS** | This `(pr, sha)` cleared the rail; proceed. | review verdict `PASS` recorded `agent-watch.sh:2821`; a recorded PASS is reused, not re-run (`review_verdict` `agent-watch.sh:1626`, consulted `agent-watch.sh:12114`); health `CLEAN`/`FLAKY` `agent-watch.sh:10240`. |
| **BLOCK** | A rail found a real defect; bounce the builder to fix (subject to budget, §4). | review `BLOCK` recorded `agent-watch.sh:2826`, dispatched to `_handle_block_verdict` `agent-watch.sh:12125`; health `CODEERROR` `agent-watch.sh:10314`. |
| **ESCALATE** | The subject cannot progress autonomously; hand to a stronger reviewer or to a human. | review-tier escalation armed on repeated review bounces (`_maybe_arm_review_escalation`, evidence counter `refix_round_count_kind … review` `agent-watch.sh:7080`); refix budget exhausted → `needs-you` (§4, `_refix_budget_reason` `agent-watch.sh:6920`); conflict-resolver terminal `escalated` (`record_resolve_escalated` `agent-watch.sh:1619`). |
| **HOLD** | Gates passed but a policy requires a human/coordinator signal before merge. | merge-policy `HOLD` case `agent-watch.sh:12268`; human-verify hold `agent-watch.sh:12243`; approval-awaiting `agent-watch.sh:12273`. Holds do **not** fail and do **not** block siblings (§5.4, §6.2). |

**INFRA is not an outcome.** An infra death (reviewer produced no parseable verdict, SIGTERM,
driver missing) is *never* recorded as a verdict — it is a bounded retry that counts against the
circuit breaker, so an infrastructure outage can never become a per-PR code BLOCK
(`agent-watch.sh:2830`–`:2836`; breaker §3.3). The reviewer's own exit contract encodes this:
`0 = PASS, 1 = BLOCK, 2 = INFRA-FAIL` (`herd-review.sh:58`), and INFRA-FAIL is "transient;
watcher retries, never caches" (`herd-review.sh:38`).

### 2.3 The two rails and the blessing

**Review rail** — the pre-merge adversarial correctness gate. A strong model reads the diff and
emits exactly one verdict line to a result file, written atomically (temp+rename,
`herd-review.sh:206`,`:210`). The tokens are `REVIEW: PASS` / `REVIEW: BLOCK` (structured:
`rule | why | location`) / `REVIEW: INFRA-FAIL` (`herd-review.sh:894`–`:909`). Only a
**correctness** finding may BLOCK; advisory findings never gate (`herd-review.sh:595` task
rules). The reviewer reads a **pinned diff** — `git diff <merge-base>..<dispatch-sha>` from the
main checkout, *not* live `gh pr diff` — so a mid-review push cannot change what was reviewed
(`herd-review.sh:595`; live `gh pr diff` survives only as a fail-soft fallback
`herd-review.sh:583`). The verdict is keyed to the dispatch sha; this pinning is why the
verdict's content provably matches its sha.

**Health rail** — the healthcheck gate (`_healthcheck_gate` `agent-watch.sh:10220`), an
async-dispatch/collect state machine over states RUNNING / QUEUED / CLEAN / FLAKY / CODEERROR
(doc `agent-watch.sh:10207`). It runs `healthcheck.sh` on the worktree; the healthcheck exit
contract is **0 = clean (or tolerated data/env), 1 = real code error, 2 = data/env (tolerated,
folded to exit 0)** (`healthcheck.sh:10`–`:12`, dispatch `healthcheck.sh:277`–`:279`).
Baseline-aware inheritance (HERD-190) downgrades a code error whose failing tests *all* already
fail on the base to a tolerated ⚠️ (`healthcheck.sh:262`,`:267`,`:271`; base-set built by
checking out the base into a throwaway detached worktree and running the same suite,
`healthcheck.sh:174`,`:185`,`:201`). **This forgives inherited reds; it does not verify the
merge result — see §6.4.**

**The blessing** — the one cross-seat-shared gate artifact. After both rails pass, the watcher
posts a `herd/gates=success` commit status on the head sha (`GATE_STATUS_CONTEXT="herd/gates"`
`agent-watch.sh:413`; `post_gate_status` `agent-watch.sh:2980`, **only `success` is ever
posted** `agent-watch.sh:2984`; posted at `agent-watch.sh:12204`). Another seat that sees the
blessing skips re-gating (`_gate_status_blessed` `agent-watch.sh:3007`, consulted at step 2,
`agent-watch.sh:11968`). Every other gate ledger is seat-local (see the audit's §5 inventory);
the blessing is the only shared truth. The port keeps the blessing as the cross-implementation
handshake.

### 2.4 Idempotence and sha-keying (the spine)

- **Verdicts are recorded once per `(pr, sha)` and reused.** `review_verdict <pr> <sha>` returns
  the recorded verdict for that exact pair (`agent-watch.sh:1626`); a cached PASS falls straight
  through to merge (`agent-watch.sh:12114`), a cached BLOCK to the block handler
  (`agent-watch.sh:12125`). Health caches its terminal verdict per sha and reuses it with no
  suite re-run (`agent-watch.sh:10237`,`:10240`).
- **A new sha discards the old sha's in-flight and recorded work — and terminates the workers.**
  `_discard_stale_reviews` (`agent-watch.sh:2364`) reaps review markers for any sha ≠ current
  **and kills the in-flight reviewer pid** (`agent-watch.sh:2373`); `_discard_stale_health`
  (`agent-watch.sh:10050`) terminates the stale-sha health worker's whole process group
  (`_health_terminate_worker`, `agent-watch.sh:10058`). This is real supersession-cancel **on a
  new head sha** — but see §6.1: there is no cancel when a *sibling merge* re-stales a still-valid
  sha.
- **Apply is at-most-once per sha.** `do_merge` (`agent-watch.sh:5708`) merges with
  `--match-head-commit <sha>` (`agent-watch.sh:5760`) so GitHub refuses the merge unless the
  remote head is still exactly the gate-verified sha; a moved head returns non-zero without
  writing the merge ledger. The merge ledger row is written **record-first** so a PR is never
  re-merged: `<epoch> <pr#> <slug> [ref]` (`agent-watch.sh:5784` with ref / `:5786` ref-less).
- **Holds and budgets are sha-keyed too.** Approval/human-verify rows carry `$rsha`
  (`agent-watch.sh:12273`, `:12314`), refix stuck/dead markers carry the sha
  (`agent-watch.sh:6994`, `:7069` — "keyed by sha, so a new commit clears the way for a fresh
  bounce" `agent-watch.sh:6992`). A new sha re-arms every hold and re-opens every budget.

---

## 3. Journal event shapes

The journal is an append-only JSONL record, the forensic substrate for `herd why` / `herd log`
(`journal.sh:1`). It is **best-effort and silent**: `journal_append` runs its work in a
strict-mode-neutralized subshell and **always returns 0** (`journal.sh:159`), so it can never
break a caller under `set -euo pipefail`. Each line is one JSON object, written with a single
`O_APPEND` printf under PIPE_BUF so concurrent writers interleave whole lines with no lock
(`journal.sh:17`–`:19`). The port keeps this contract: append-only JSONL, one object per line,
never a hard dependency of any caller.

### 3.1 Record schema

Every event object **always carries `ts` (ISO-8601 UTC, Z-suffixed) and `event`**, then
arbitrary key/value pairs; integer-looking values serialize as JSON numbers, everything else as
strings (`journal.sh:20`–`:21`, construction at `journal.sh:134`). The signature is
`journal_append <event_type> [key value]...` (`journal.sh:156`). The timestamp comes from one
source, `_journal_ts` (`journal.sh:33`) — no caller formats its own clock (a local-clock writer
once emitted a future Z timestamp and poisoned `herd why` chronology). The port must route all
timestamps through one UTC source.

### 3.2 Provenance (`source`)

The review verdict is journaled as `verdict_recorded pr <pr> sha <sha> value <PASS|BLOCK> source
<source>` (`agent-watch.sh:1761`). The documented provenance enum is **`reviewer |
gate_default | infra`** (`agent-watch.sh:1756`). In the live tree:

- **`reviewer`** — a real `REVIEW: PASS`/`BLOCK` line; the default and the *only* provenance that
  may bounce a builder (`agent-watch.sh:2821`,`:2826`; safety hinge `review_verdict_source`
  `agent-watch.sh:1637`).
- **`gate_default`** — documented but **latent**: there is no live call site. A no-verdict run is
  treated as INFRA (retry), not a default BLOCK. The real non-reviewer sources actually emitted
  are `carried-forward` (delta re-review carry, `agent-watch.sh:1749`) and `skipped-low-risk`
  (`agent-watch.sh:2894`). *The port should treat provenance as an open enum whose invariant is
  "only `reviewer` bounces a builder," not a closed three-value set.*
- **`infra`** — never written as a verdict row. Infra deaths route to `record_review_retry`
  (never cached, `agent-watch.sh:2834`) + the circuit breaker (`agent-watch.sh:2835`); the
  forensic record is an `infra_event` line (e.g. `agent-watch.sh:10464`), not a verdict.

### 3.3 The INFRA circuit breaker

The breaker is the "env looks dead, stop dispatching" seam. One-line state `<state> <fails>
<opened> <probe_pr>`: `_breaker_read` `agent-watch.sh:2593`, `_breaker_write`
`agent-watch.sh:2602`. `_breaker_record_infra` (`agent-watch.sh:2610`) increments the
consecutive-non-verdict-death counter and OPENs at `INFRA_BREAKER_MAX` (journals
`infra_breaker_open` `agent-watch.sh:2621`); `_breaker_record_ok` (`agent-watch.sh:2635`) — a
real PASS/BLOCK proves the env alive — resets and CLOSEs. `_breaker_gate`
(`agent-watch.sh:2661`) returns `BLOCKED`/`PROBE`/`PASS` to halt or single-flight dispatch while
open (step 1 of the candidate pass, `agent-watch.sh:11949`). The port models this as an explicit
state machine (asyncio) rather than a whole-file RMW.

### 3.4 Event catalog (names, required fields)

Anchors point at the emit site; the k/v keys after `event` are the required fields.

| Event | Keys | Anchor |
|---|---|---|
| `verdict_recorded` | pr, sha, value(PASS\|BLOCK), source | `agent-watch.sh:1761` |
| `review_dispatched` | pr, sha, pid, model, log_path, pin | `agent-watch.sh:2545` |
| `healthcheck_started` | pr, slug, sha, pid, log_path | `agent-watch.sh:10390` |
| `healthcheck_outcome` | pr, slug, outcome(CLEAN\|FLAKY\|CODEERROR) | `agent-watch.sh:10273` |
| `stale_dup_hold` | pr, sha, slug, kind, reason | `agent-watch.sh:7896` |
| `refix_bounce` | pr, sha, slug, round, agent_status_before, rule, location | `agent-watch.sh:7321` |
| `refix_wake_result` | pr, sha, slug, round, agent_status_before, agent_status_after, woke, escalated | `agent-watch.sh:7359` |
| `refix_escalated_no_wake` | pr, sha, slug, kind, reason(no-live-builder), agent_status | port `live_runtime.py:LiveTick._bounce_and_wake` (HERD-370 — an unwoken bounce escalates to needs-you immediately, in the same tick, instead of holding silently) |
| `hold_applied` | pr, sha, slug, kind | `agent-watch.sh:12287` |
| `human_verify_policy` | pr, sha, slug, policy(auto), action | `agent-watch.sh:12314` |
| `approval_recorded` | pr, sha, state(approved), source | `herd-approve.sh:232` |
| `merge` | pr, slug, sha, method, reason(gates_passed) | `agent-watch.sh:5788` |
| `merge_refused_sha_moved` | pr, slug, sha, state | `agent-watch.sh:5764` |
| `gate_status` | pr, sha, state(success), context(herd/gates) | `agent-watch.sh:3205` / port `live_runtime.py:LiveActuator.post_gate_status` |
| `merge_refused` | pr, slug, sha, state, reason(api_not_merged) | port `live_runtime.py:LiveActuator.merge` (HERD-352 — the API verify refuses an unconfirmed merge) |
| `merge_refused_escalated` | pr, sha, slug, count, reason | port `live_runtime.py:LiveTick._walk` (HERD-352 — loud needs-you row after N refusals) |
| `main_health` | pr, sha, result(green\|red) | `agent-watch.sh:5420` / red `:5494` |
| `reconcile` | pr, slug, sha, ref, resolution(explicit-ref\|fuzzy) | `agent-watch.sh:4591` |
| `reap` | pr, slug, sha, reason | `agent-watch.sh:5278` |
| `cost` | component, pr, slug, model, in, out, cache_read, cache_write, usd, msgs, unpriced | `cost.sh:424` |
| `pr_restale` / `pr_starvation` | pr, sha, slug, kind (+ lap count) | `agent-watch.sh:3371`–`:3374` |
| `infra_breaker_open` / `_close` | — | `agent-watch.sh:2621` / `:2643` |

`merge_result_gate` (pr, sha, slug, base, verdict — §6.4, HERD-296) and `merge_queue_hold` /
`merge_queue_window` (pr, sha, slug, front_pr — §6.3, HERD-273) are Python-port-only additions with
no bash anchor by design: both items are folded into the port, never built in the retired bash
action pass (`pysrc/herd/live_runtime.py`, anchored in §6.3/§6.4).

---

## 4. Refix-budget semantics

The refix budget bounds how many times a subject is bounced back to its builder to fix a rail
failure. **This branch already implements the per-rail model (HERD-229);** the old
single-shared-per-PR counter is gone (`agent-watch.sh:6830`–`:6848` explains the split). The
port must honor the per-rail model, not the legacy shared one.

- **Per-rail budgets.** Each rail — `review`, `health`, `stale`, `ci` — has its own running
  count and its own cap. The central predicate is `_refix_budget_reason <pr> <kind>`
  (`agent-watch.sh:6920`): it blocks when the **rail** count ≥ rail cap (`agent-watch.sh:6925`)
  **or** the **total** count ≥ total cap (`agent-watch.sh:6928`). The four cap-consult sites all
  delegate to it: review `agent-watch.sh:7258`, ci `agent-watch.sh:7473`, stale
  `agent-watch.sh:7733`, health `agent-watch.sh:7995`.
- **The caps.** `REFIX_MAX_ROUNDS` defaults to **3** (`herd-config.sh:570`; coerced from garbage
  or 0 by `_refix_cap_num` `agent-watch.sh:6859`). The per-rail cap is that value
  (`refix_rail_cap` `agent-watch.sh:6866`). The **total ceiling is `3 × REFIX_MAX_ROUNDS`,
  derived, not a config key** (`refix_total_cap` `agent-watch.sh:6869` — there is no
  `REFIX_MAX_TOTAL`). The total is the runaway guard for a PR thrashing across different rails.
- **Refund-on-green (reset-on-progress).** When a rail's gate subsequently PASSes for a newer
  sha, that rail's running count is reset via `refix_rail_reset` (`agent-watch.sh:6949`), which
  appends a `reset` row that zeroes the rail's count in `refix_rail_count`
  (`agent-watch.sh:6897`). The three refund sites: review PASS → reset review
  (`agent-watch.sh:1765`), health CLEAN/FLAKY → reset health (`agent-watch.sh:10038`), stale
  base-fresh → reset stale (`agent-watch.sh:7887`). **Progress is not failure:** "same failure
  twice" is the loop signal, not "three different first-time failures ever."
- **The total ignores resets.** `refix_total_count` (`agent-watch.sh:6885`) counts lifetime
  bounces and deliberately does **not** refund on reset, so a PR that thrashes across rails still
  escalates at `3×`. `refix_round_count` is now just an alias for this lifetime total, retained
  for the "N failed refix rounds" escalation display (`agent-watch.sh:6890`,`:6892`).
- **Per-kind lifetime counter is evidence, not a budget.** `refix_round_count_kind`
  (`agent-watch.sh:6910`, "Not a budget: it is EVIDENCE" `agent-watch.sh:6906`) counts lifetime
  bounces of one kind and is read only to arm a stronger-reviewer escalation
  (`agent-watch.sh:7080`), never as a cap.
- **Ledger + sha-keying.** Bounces append to `$REFIX_STATE` (`.agent-watch-refixed`,
  `agent-watch.sh:309`) as `<epoch> <pr#> <sha> <slug> <kind>` (`record_refix`
  `agent-watch.sh:6940`,`:6942`); a reset row is the same shape with a trailing `reset`
  (`agent-watch.sh:6852`). The ledger is append-only and never wiped per-sha; instead the
  once-guard `refix_attempted` (`agent-watch.sh:6876`) is keyed on `(pr, sha, kind)` so a new sha
  naturally re-opens bounces, and stuck/dead markers carry the sha so a new commit clears them
  (`agent-watch.sh:6994`,`:7069`,`:6992`; stale-sha stuck markers swept in `_discard_stale_health`
  `agent-watch.sh:10072`).
- **The bounce itself.** The builder is re-woken through the **driver seam**
  (`herd_driver_send_text` `agent-watch.sh:7339`, targeting the idle/done builder pane
  `agent-watch.sh:7334`), never a raw `herdr pane run`, so a headless driver still receives the
  bounce. Each rail journals a `*_refix_bounce` before and a `*_refix_wake_result` after (review
  `agent-watch.sh:7321`/`:7359`, stale `:7792`/`:7846`, health `:8043`/`:8085`).

The port models the budget as typed per-`(pr, rail)` counters + a lifetime total, with
reset-on-green as an explicit transition — exactly the "doctrine-by-comment becomes a typed
transition function" win of `docs/spikes/engine-port-python.md` §0.2.

---

## 5. Row-truth doctrine, once-guards, positive-evidence death, holds

### 5.1 Row truth — `needs-you` means nobody is on it

A console row states **whose move it is**. `needs-you · <blocker> · <remedy>` is defined as
"YOUR move; a red hold that will NOT clear itself" (`agent-watch.sh:900`), and it always names
owner + age. The word **`idle` is banned** because it hides whose-move-it-is
(`agent-watch.sh:877`). A spare builder's `💤 awaiting task · assign or retire` row
(`_row_awaiting_task` `agent-watch.sh:913`,`:917`) is emitted **only** when a *successful* open-PR
lookup positively shows no PR for that branch (`agent-watch.sh:906`) — never inferred from a
failed lookup. The port's rule: **a row is a claim about who must act, and it must never be
derived from an absence of evidence.**

### 5.2 Positive-evidence death — blindness is never evidence of death

"'{}' / unparseable roster is NOT readable — the watcher is BLIND, and blindness is never
evidence" (`agent-watch.sh:3873`). `_roster_readable` (`agent-watch.sh:3876`) turns a
`herdr agent list` blip into a no-op hold instead of a fleet-wide "all died." A worker is
declared DEAD only when the roster is **positively readable and still omits it**
(`agent-watch.sh:3971`; otherwise `UNKNOWN` `agent-watch.sh:3972`). `_classify_dead_builder`
(`agent-watch.sh:9026`) returns `ALIVE` on any positive liveness signal — a live agent, an open
PR, or a growing transcript (`agent-watch.sh:9029`) — requiring positive evidence before a 💀.
**The port must require positive evidence to transition to a dead/absent state; a failed lookup
holds last-known-good, it does not kill.**

### 5.3 Once-guards — a hold fires its side effects exactly once per sha

A hold's noisy side effects (comment + operator notify + journal) fire once per `(pr, sha)` and
are recorded so they are not repeated. The pattern is a `*_noted` predicate + a `record_*`
writer: stale-dup `stale_dup_held_noted` (`agent-watch.sh:3306`) / `record_stale_dup_held`
(`agent-watch.sh:3312`, keyed `<epoch> <pr> <sha> <kind>`), used once at
`agent-watch.sh:11894`. Approval-awaiting and hv-informed have the same shape
(`approval_awaiting_noted` `agent-watch.sh:3262` / `record_approval_awaiting`
`agent-watch.sh:3274`; hv-informed `agent-watch.sh:12311`). The port models "notify once per
state per version key" as a first-class idempotent effect.

### 5.4 sha-keyed human-verify hold

A `HUMAN-VERIFY:` block in the PR body flips a gates-green PR into a hold. The parser is shared
(`human_verify_steps` `human-verify.sh:33`, marker regex `human-verify.sh:41`, `human_verify_has`
`human-verify.sh:72`); the body reader is **fail-closed** — an unreadable body returns 2, i.e.
"hold, don't merge" (`pr_human_verify_held` `agent-watch.sh:3689`). The apply site
(`agent-watch.sh:12243`) sets the hold, and the awaiting/approval rows are written per `$rsha`
(`agent-watch.sh:12273`), so a **new sha re-arms** the hold. Under `HUMAN_VERIFY_POLICY=auto`
the steps are journaled and commented but merged with a durable `human_verify_policy … policy
auto` record (`agent-watch.sh:12314`) — a *record*, not an approval. Under the default policy the
hold is surfaced loudly (§5.6) and waits for `herd-approve.sh approve`.

### 5.5 sha-keyed approval hold

Under `MERGE_POLICY=approve` (resolved through the one seam `_effective_merge_policy`,
`merge-policy.sh:35` — a typo fails **strict to `observe`**, never to auto,
`merge-policy.sh:15`), a merge waits on an explicit sha-keyed `approved` row. The ledger seam is
`approvals.sh` (`approval_state` `approvals.sh:50`, `approval_recorded` `approvals.sh:74`,
sha-prefix-anchored matching). The watcher consults it per `(pr, sha)` before the hold decision
(`approval_is_approved` `agent-watch.sh:3268`, used `agent-watch.sh:12255`). `herd-approve.sh`
writes the sha-keyed `approved` row (`herd-approve.sh:225`) and, critically, **the durable
evidence is the journal, not the ledger** — the ledger is purged at merge (`approvals.sh:16`),
so the port must treat `approval_recorded` (`herd-approve.sh:232`) + `human_verify_policy …
policy auto` (`agent-watch.sh:12314`) as the audit truth, and the ledger as a pre-merge-only
convenience. An override path exists (sha-keyed `override` row, `herd-approve.sh:297`).

### 5.6 Holds notify loudly, and are consumed on verdict/merge

A hold is not silent: it journals `hold_applied` (`agent-watch.sh:12287`), fires an operator
notify (`herd_driver_notify` `agent-watch.sh:12294`), and renders a green-with-pending row
(`agent-watch.sh:12303`). Gate workers are **retired on verdict-consumed**
(`_retire_reviewer_pane … verdict-consumed` `agent-watch.sh:2310`,`:2845`) and any worker past
its family timeout is TERMed by the corpse sweep (`_sweep_gate_corpses` `agent-watch.sh:10440`;
review TERM at `REVIEW_INFLIGHT_TIMEOUT` `agent-watch.sh:10461`, health group-terminate
`agent-watch.sh:10506`; the watcher never TERMs itself `agent-watch.sh:10460`). The port keeps
"a hold is loud, owned, and never a dropped signal."

---

## 6. The four folded items — semantics the port must implement

EPIC HERD-300 **folds** HERD-235, HERD-273, HERD-294, and HERD-296 into the port's P3
(`docs/spikes/engine-port-python.md` §3; they are closed-as-folded — not built in bash). Their
semantics are frozen **here**, so the port implements them from this contract. Each subsection
gives the current live state (what the bash tree does today) and the **TARGET** the port must
reach.

### 6.1 HERD-235 — gate-order DAG + supersession-cancel

**Live state.** The gate order is a **fixed linear sequence** in one loop body, not a declarative
DAG (§2.1 table, loop `agent-watch.sh:11938`). Supersession-cancel exists **only for a new head
sha**: `_discard_stale_reviews` kills the stale reviewer pid (`agent-watch.sh:2364`,`:2373`) and
`_discard_stale_health` terminates the stale health worker's process group
(`agent-watch.sh:10050`,`:10058`); the corpse sweep TERMs workers past a timeout
(`agent-watch.sh:10440`). What is **NOT PRESENT**: any cancel of a still-valid sha's in-flight
work when a *sibling merge* re-stales it, and any declaration of gates as ordered cost classes.

**TARGET.** Declare gates as a DAG of ordered cost classes (deterministic-cheap →
deterministic-slow → LLM), the action pass walks the DAG, and on **any** supersession of a sha —
a new head **or** a sibling merge that re-stales it — TERM the now-doomed in-flight workers for
that sha (generalizing the existing new-sha cancel to cross-candidate supersession). The cost
classes are already implicit in the §2.1 ordering; the port makes them explicit and reuses the
corpse-sweep TERM path as the cancel primitive. Structured concurrency (asyncio task groups,
`docs/spikes/engine-port-python.md` §0.4) makes "cancel the parent, cancel its children" the
natural implementation.

### 6.2 HERD-294 — starvation freeze

**Bash live state.** The bash **action pass that used to decide merges is gone**: `_tick_act` was
deleted at the P5 cutover (HERD-306, EPIC HERD-300's finale), and `ENGINE_IMPL` set to anything but
`python` is now treated as `python` with a loud one-time retirement warning
(`scripts/herd/engine-version.sh:290`) — the Python engine (`pysrc/herd/live_runtime.py`) is the
SOLE live core. What survives in `agent-watch.sh`, the live status console for the coordinator
(`docs/codemap.md`), is: (1) the re-stale lap **counter**, still wired live at both lap-losing
surfaces — the conflict classifier (`_classify_conflict` → `_restale_note`, `agent-watch.sh:5103`)
and the stale/duplicate hold path (`_restale_note` `agent-watch.sh:9059`) — recording into a shared
ledger file (`RESTALE_STATE=.agent-watch-restale`, `agent-watch.sh:438`,
`_RESTALE_STARVE_THRESHOLD=3` `:441`) via `restale_counted` (`:3866`)/`restale_count` (`:3873`)/
`_restale_note` (`:3882`, journals `pr_restale` `:3892` and, at/past threshold, `pr_starvation`
`:3894`), decorating the row with the loud `└─ starving · N re-stale laps` line (`_starvation_row`
`:3903`, `_restale_decorate_row` `:3912`, called `:9062` and `:13297`); and (2) the priority-**reorder**
helper, `_merge_fairness_reorder` (`:3978`, guarded by `_merge_fairness_enabled`/`MERGE_FAIRNESS`
`:3933`) — but with the action pass deleted it now has **no production callsite**.
`tests/test-merge-fairness.sh:47`–`:58` asserts exactly that: the helper still exists (kept for the
checks below and for the sim acceptance suite,
`scripts/herd/sim/sandbox-concurrency-scenario.sh:1327`,`:1391`) and that no `_tick_act` reference
lingers anywhere in the file. Candidate ordering — and therefore whether a starved PR ever actually
gets a clean merge window — is single-owner: Python.

**Python typed live runtime. IMPLEMENTED** (`MERGE_FAIRNESS`, HERD-340, folding this section closed
— the design-basis incident is PR #399's re-stale livelock, `tests/test-py-merge-fairness.sh:2`–`:3`).
Ship-dormant, default off, strict-validated like every other gate lever:
`_merge_fairness_enabled` (`live_runtime.py:1324`) treats any unrecognized `MERGE_FAIRNESS` value as
off — the byte-identical default — and `_starve_threshold` (`:1331`) falls back to the SAME default
as the bash counter (3, `agent-watch.sh:441`) when `MERGE_FAIRNESS_STARVE_THRESHOLD` is absent or
non-positive.

Each tick, `LiveTick._fairness_prepass` (`:2578`, called `:2922`, strictly before any candidate is
walked) is a no-op when the lever is off. When on, it (a) counts this tick's fresh re-stale laps for
a candidate that re-staled with real gate work already invested (`state.note_restale`, `:2598`),
journaling `pr_restale` (`:2600`) and, at/past threshold, `pr_starvation` (`:2602`) — the exact bash
journal schema (§3.4) — into the SAME shared ledger file bash's still-live conflict/stale-dup
classifiers also write to, so `_effective_laps` (`:2566`) sees every lap either implementation ever
recorded for that PR, not only the ones Python itself counted this tick; then (b) resolves the
head-of-line **starved set**: a candidate is starved when its laps reach threshold AND its own
merge policy would auto-merge it once green (`_would_automerge`, `:2572` — a PR parked on a human
hold never starves-and-freezes), bounded to ONE window per `(pr, sha)` via the once-guard (`:2609`,
`"fairness_window"`) so a rebased sha re-arms it and a PR that can never land does not freeze the
queue forever.

At the merge decision (`LiveTick._walk`), a candidate whose action would be MERGE is instead frozen
whenever some OTHER candidate is in the starved set (`:2855`, `self._starved - {cand.pr}`) — a new
`merge_frozen` edge, BLESSED→HOLD (`statemachine.py:120`,`:203`), journaled once as
`merge_fairness_freeze` (`live_runtime.py:2856`–`:2858`). The starved PR is excluded from its own
freeze set, so it still merges once it is itself ready. This is exactly the promotion this section
used to describe as TARGET: the ship-dormant bash reorder's *intent* ("merge the ready one first, so
the merge that would re-stale it never runs") realized as an actual HOLD enforcement — in the Python
core, not the bash tree, which never grows this. Proven by `tests/test_statemachine_props.py`
(`MergeFairnessFreeze`, `:262`), `tests/test_live_runtime.py` (`MergeFairnessFreeze` `:1510`,
`MergeFairnessState` `:1599`), and the hermetic dry-run sim `tests/test-py-merge-fairness.sh`
(freeze-on, byte-identical-off, no self-block, no freeze behind a human hold).

**TARGET — closed.** The three semantics this section asked the port to carry are all now
implemented: a gates-passed PR sitting in a HOLD is re-walked as a real candidate every tick, never
dropped (`LiveTick._walk` returns `HOLD` and re-attempts next tick, §5.1's row-truth doctrine); past
threshold, re-stale laps now freeze sibling `do_merge`s for one window (`merge_frozen`, above — the
piece that was genuinely missing before HERD-340); and holds notify loudly (§5.6, unchanged).
Nothing in §6.2 remains TARGET. The bash `_merge_fairness_reorder` stays the dormant, callsite-less
helper described above by design — folding HERD-294 closed means the semantics live in the Python
port, not that bash grows an enforcement path of its own (§6's intro).

### 6.3 HERD-273 — ordered integration queue (merge train)

**Live state. IMPLEMENTED** (Python port only; the bash action pass never grows this — the classic
merge is untouched there). `MERGE_QUEUE` (`live_runtime.py:_merge_queue_enabled`, strict-validated
like every other gate lever) is ship-dormant, default off. When on, `LiveTick` resolves this tick's
**queue front** *before* any candidate is walked — `LiveTick._queue_prepass`
(`live_runtime.py:2580`) — from the set `LiveTick._queue_eligible` (`live_runtime.py:2557`)
returns: every open, non-stale candidate whose merge policy would land it once green (the SAME
pure `_would_automerge` test §6.2's freeze uses), **independent of this tick's own health
outcome**. The front is the MINIMUM PR **number** (`_queue_sort_key`, `live_runtime.py:1329`) among
that set — a stable, collision-free total order every seat derives identically with no shared
ledger, since a PR's number never changes.

`LiveTick._walk` (§2.1 step 11, `live_runtime.py:2808`) then gates the apply step itself: a
candidate whose gates are green and whose policy says MERGE, but which is **not** this tick's
front, HOLDS instead (`queue_wait`, a new lifecycle edge BLESSED→HOLD,
`statemachine.py:QUEUE_WAIT`/`:208`, journaled once per `(pr, sha)` as `merge_queue_hold`) — even
though its own gates are exactly as green as the front's. Only the front actually reaches
`actuator.merge`. This makes lapping structurally impossible: two siblings blessed in the same
window can never land out of order, and — because membership does not depend on this tick's health
result — a front that is genuinely stuck (a real `CONFLICT` against a base a sibling just
advanced, or an exhausted refix budget) is **never silently vacated** for a later candidate to fill
its slot; the whole queue holds until a human/resolver clears it (a new sha re-arms membership;
row-truth §5.1 makes the stall loud, never silent). `merge_queue_window` is journaled every tick
the lever is on, naming the resolved front and the eligible-set size, for observability.

The **virtual tip** (§2.1's phrase for "default branch + the train ahead") needs no synthetic
chaining to generalize the §6.4 per-slot verifier: because only the front ever actually applies a
*real* merge, by the time a later queue position becomes front every already-ordered candidate
ahead of it has already really landed — the plain current default-branch tip **already is** the
virtual tip. `MERGE_QUEUE=on` implies the §6.4 verification unconditionally
(`LiveGates.__init__`, `live_runtime.py:1483`: `_merge_result_gate_enabled(cfg) or
_merge_queue_enabled(cfg)`) so the queue's correctness requirement is never a second,
independently-toggleable config key a project could leave mismatched — setting
`MERGE_RESULT_GATE` explicitly (on **or** off) alongside `MERGE_QUEUE=on` changes nothing.

Batch-verify-N + bisect-on-red and speculative parallel slots — pre-verifying position 2 against a
*projected*, not-yet-real, virtual tip while position 1 is still gating — are explicitly **not**
implemented; this ships only the ordering primitive (`docs/spikes/merge-result-gate.md` §3 calls
these out as pure concurrency work layered on the same primitive, the train's Phase 4 proper). The
tradeoff is throughput, not correctness: with `HEALTH_CONCURRENCY`'s default single slot already
serializing most of the work, a stuck front blocks the whole queue until cleared — accepted
per-doctrine (mirrors §6.4's own resolver-owned `CONFLICT`, which carries no refix budget either).
Proven by `tests/test_live_runtime.py` (`TestMergeQueueConfig`, `TestMergeQueueOrdering`),
`tests/test_statemachine_props.py` (`MergeQueueOrdering`), and the hermetic multi-seat sim
`tests/test-merge-queue-sim.sh` (real git, six candidate PRs, one genuinely conflicting against an
already-landed sibling — proving bounded slots, no lapping, and that the conflicting head blocks
every later candidate until re-armed by a new sha).

### 6.4 HERD-296 — merge-result gate

**Live state. IMPLEMENTED** (Python port only, `MERGE_RESULT_GATE`, ship-dormant default off,
strict-validated: `live_runtime.py:_merge_result_gate_enabled`, `:985`). The classic bash pre-merge
health gate still runs the suite on the **branch worktree as-is** and is untouched — this item
lives entirely in `pysrc/herd/live_runtime.py`, never in `agent-watch.sh`. With the lever on,
`LiveGates.health` (`live_runtime.py:1498`) diverts the whole health rail to
`LiveGates._merge_result_health` (`:1616`): before dispatch, `_resolve_default_branch_sha`
(`:992`) reads the current default-branch tip and `_materialize_merge_tree` (`:1044`) builds a
DETACHED, throwaway worktree at the PR's exact head sha merged with that tip (`git worktree add
--detach` + `git merge --no-edit`, never touching the builder's own branch or the shared default
checkout). The healthcheck suite then runs against **that** materialized tree via the same async
dispatch/collect/in-flight machinery the classic rail uses (`LiveGates._dispatch_merge_result`,
`:1691`), so refix/bounce, `HEALTH_CONCURRENCY` accounting (`_total_health_inflight`, combining the
classic and merge-result in-flight counts) and supersession-cancel all compose unchanged.

The tested `(head, base)` pair is cached (`LiveState.merge_result_verdict`/`record_merge_result_verdict`)
keyed on all three of `pr, sha, base` — a base move is simply a cache miss, which **re-arms** the
gate for the new pair (§2.4 sha-keying discipline, generalized to a compound key) — and a
`merge_result_gate` event journals the base actually tested. A real merge conflict never becomes a
cached verdict or a rail BLOCK: `_materialize_merge_tree` fails soft to the sentinel `"CONFLICT"`,
which `LiveTick._walk` folds into the SAME honest, resolver-owned hold the stale-dup gate uses
(`merge_result_conflict`, a new lifecycle edge HEALTH→STALE_HELD, `statemachine.py:MERGE_RESULT_CONFLICT`)
— never a bounce, never a red. Off (default): `LiveGates.health` never even reaches
`_merge_result_health`, no `.merge-result-*` file is ever written, and the classic per-branch
healthcheck dispatch is byte-identical to before the feature existed.

Proven by `tests/test_live_runtime.py` (`TestMergeResultGateConfig`, `TestMergeResultGateDispatch`,
`TestMergeResultGateWalk`, `TestMergeResultGateSupersession`, `TestMergeResultGateByteIdentical`)
and the hermetic sim `tests/test-merge-result-gate-sim.sh` (real git, two textually-disjoint PRs
that are each individually green but semantically incompatible once merged, plus a genuinely
conflicting third). §6.3's ordered queue reuses this verifier verbatim as its per-slot check, with
the base generalized to the virtual tip as described there.

---

## 7. What the port must NOT change

From `docs/spikes/engine-port-python.md` §2 and the byte-identical doctrine (`AGENTS.md`):

- **Journal schema** (append-only JSONL, `ts`+`event`+k/v, §3) — it is the cross-implementation
  parity oracle for P3 shadow mode (`docs/spikes/engine-port-python.md` §3, P3).
- **`.herd/config` surface and key semantics** — gate keys fail strict, cosmetic keys fail soft
  (`AGENTS.md`).
- **The blessing** (`herd/gates=success`, §2.3) — the one shared cross-seat artifact.
- **The merge apply contract** — `gh pr merge --match-head-commit <sha>`, method/delete-branch
  flags, record-first ledger (§2.4).
- **Ship-dormant / byte-identical-when-off** for every new lever (§6.2–6.4 targets ship default
  off).
- **Builder/coordinator ownership boundaries** — builders never write the tracker or `BACKLOG.md`
  (`AGENTS.md`); the port's watcher inherits this.

---

## 8. Verification of this document

Per the P0 acceptance criteria (HERD-301):

- **Docs-only diff.** This PR adds one file under `docs/` and touches no engine code; it rides
  the `DOCS_ONLY_GLOB` review tier.
- **Every normative rule carries at least one live-code anchor**, in `file:line` form, into
  `agent-watch.sh` / `approvals.sh` / `merge-policy.sh` / `herd-review.sh` / `healthcheck.sh` /
  `journal.sh` / `cost.sh` / `human-verify.sh` / `herd-config.sh` / `herd-approve.sh`.
- **Anchors were re-verified against the live tree** (`agent-watch.sh` @ 12,469 lines), not
  transliterated from the 2026-07-09 audit (whose numbers are stale at 7,706 lines). Spot-check
  any anchor with `sed -n '<line>p' <file>`.
- **IMPLEMENTED vs. TARGET is stated explicitly** for the four folded items (§6): HERD-235 gate
  order and new-sha supersession-cancel are IMPLEMENTED (DAG + cross-sibling cancel are TARGET);
  HERD-294 (§6.2, `MERGE_FAIRNESS`, HERD-340) is now fully IMPLEMENTED — Python-port-only,
  ship-dormant, default off — closing what was TARGET here (the bash re-stale counter stays
  IMPLEMENTED-and-live, the bash reorder stays a dormant helper with no production callsite since
  `_tick_act`'s deletion, HERD-306); HERD-296 (§6.4, `MERGE_RESULT_GATE`) and HERD-273 (§6.3,
  `MERGE_QUEUE`) are both IMPLEMENTED — Python-port-only, ship-dormant, default off — with
  batch-verify-N/bisect-on-red and speculative parallel slots (the train's Phase 4 proper) left as
  TARGET, out of scope for the ordering primitive.

---

## 9. References

- `docs/spikes/engine-port-python.md` — the EPIC (HERD-300) evidence doc; this contract is its P0.
- `docs/spikes/merge-result-gate.md` — HERD-296 design (§6.4).
- `docs/spikes/work-unit-abstraction.md` — the gate/apply/reconcile spine generalized past
  `git-pr` (same seam; the port's contract is the git-pr adapter's gate semantics).
- `docs/audits/2026-07-09-gating-hardening.md` — the incident audit that grounds §4–§6 (line
  numbers there are stale; re-anchored here).
- `docs/codemap.md` — module roles + config-key→consumer wiring.
- `AGENTS.md` — ship-dormant / byte-identical / fail-soft / ownership doctrine.
