# SPIKE: Merge-result gate — decouple "verify against main" from the merge train and ship it now

**Tracker:** extension of the Linear item *"Merge train: ordered integration queue (scale past ~5 parallel seats)"* (Phase 4 of the HERD-240 program) — link the Linear ID when filing  
**Status:** design spike — proposes a small Phase-0 engine change ahead of the train  
**Date:** 2026-07-10  
**Audience:** coordinator + engine maintainers  
**Grounding:** external review of the gate pipeline (agent-watch pre-merge path, `healthcheck.sh`, `stale-dup-gate.sh`) against the item's two-seat burst data (~35 merges/day on one hot file, 4–6 lap PRs, collision window ≈ merge-rate × gate-latency ≈ 10 min)

## 0. Why this spike exists

The train item already contains the right verification semantics — *"each is verified
against main + the train ahead."* This spike's claim is narrower and about **sequencing**:
that verification step is not train-scale work, and the hole it closes is not a ~10-dev
problem. It is open **today at two seats**, independent of ordering, fairness (HERD-231), or
the DAG (HERD-235). Extract it from Phase 4, ship it standalone now, and the train later
generalizes it rather than introduces it. Bonus: it removes a chunk of the lap-PR pathology
from the two-seat data *before* the train is built, so the 10-writer fixture (HERD-236
extension) measures the train's real contribution, not this bug's.

## 1. The gap (verified in code)

The pre-merge healthcheck runs on the worktree **as-is**: `healthcheck.sh <wt>` diffs and
tests the branch's tree — **not** the merge result of the PR plus the current default-branch
tip. The stale-dup gate mitigates but is **file-level**: it holds a PR only when files *it
touched* also moved on the base.

Consequence — the semantic-conflict window: PR A and PR B merge textually clean, both test
green on their own (stale) base, and interact only through behavior (A changes a function's
contract; B adds a caller in a file A never touched). Every existing gate passes. Main
breaks. The main-health monitor catches it **after** landing — a backstop, not a gate.

It also feeds the re-stale loop directly: staleness is discovered late (bounce → refix →
re-gate), spending whole gate cycles on laps. Verifying the merge result up front converts
"merge, discover, bounce, re-gate" into one gate pass — i.e., it shrinks the very
merge-rate × gate-latency window the train item's arithmetic is built on.

## 2. Phase 0 — merge-result gate (small, ship before the train)

Before the pre-merge healthcheck, materialize the merge and gate **that**:

1. In the PR's worktree (or a temp copy), `git merge <DEFAULT_BRANCH tip>` — the same dance
   `STALE_BASE_AUTOFIX` already performs, minus the push.
2. Merge conflicts → already the resolver's lane; nothing new.
3. Run `healthcheck.sh` on the merged tree. Green → proceed to review/merge exactly as today
   (the instant-before-merge MERGEABLE/CLEAN re-verify unchanged).
4. Journal a `merge_result_gate` event carrying the base sha tested against; a base that
   moves between gate and merge re-arms the gate for the new (head, base) pair — the same
   sha-keying discipline as review verdicts.

Notes:

- **Baseline-aware inheritance (HERD-190)** must evaluate against the merged tree's base
  (the tip it merged), not the branch's old merge-base — otherwise an inherited-failure
  downgrade could mask a real interaction failure.
- **Gate-latency coupling:** the mechanical merge must NOT trigger a full re-review on its
  own — that would double gate latency and worsen the collision window. The item's
  **delta re-review companion** is the natural pairing: mechanical-rebase commits get the
  delta path. Until that lands, key the review verdict to the pre-merge head sha and let the
  merge-result gate re-run **healthcheck only**.
- **Throughput:** the health mutex already serializes; a strict serial merge-result gate at
  ~10 min latency sustains ~6 merges/hour vs today's ~4–5/hr peak. Phase 0 needs no
  concurrency work; batching/bisect stays with the train.
- **Cleanup:** if gating in the live worktree, reset to the pre-merge head afterward (the
  builder's tree must not silently gain a merge commit it didn't make); a temp worktree
  sidesteps this at the cost of disk + object-store lock pressure (respect
  HEALTH_CONCURRENCY).
- **De-risks the train's open question:** the item weighs GitHub's native merge queue vs an
  engine-native queue. Phase 0 is required under **either** answer — native queue: this gate
  is the required check the queue re-runs per position; engine-native: it is the train's
  per-slot verifier with the base generalized to the virtual tip. No wasted work.
- Flag-gate it (`MERGE_RESULT_GATE`, default off per ship-dormant doctrine) so the merge
  path stays byte-identical until a project opts in.

**Acceptance:** a hermetic sim scenario with two stub PRs, textually disjoint, semantically
conflicting (A redefines a function's output; B adds a consumer of the old contract): today
both land and main goes red; with the gate on, the second PR reds **pre-merge** into the
standard bounce/needs-you flow. No regression in the P0/P1 sandbox scenarios; journal shows
the tested base sha per merge. This scenario then joins the HERD-236 multi-seat sim as a
fixture the train's 10-writer cadence test inherits.

## 3. Relationship to Phase 4 (the train itself)

The train's per-slot operation is Phase 0 with the base generalized: merge the candidate
onto the **virtual tip** (main + the train ahead), gate that, merge in order — lapping
becomes structurally impossible, which is what actually retires the fairness/quiet-window
politeness (HERD-231) at scale. Batch mode (verify a train of N together, bisect on red) and
speculative slots are pure concurrency work on top of the same primitive. The companions
stay separate concerns as the item states: delta re-review shrinks gate latency (and unblocks
this gate's review-coupling note above); codemap spawn steering + hot-file decomposition
reduce overlap so fewer PRs need the train at all.

Sequencing: Phase 0 now as its own PR; the train remains Phase 4 of HERD-240 on Linear, with
Phase 0 named as its verifier primitive.
