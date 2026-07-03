# Flow audit — end-to-end redundancy, speed-ups & gate necessity/correctness

> Research pass for the **AUDIT** umbrella item in `BACKLOG.md` (§ Efficiency / cost). Maps the
> herdkit pipeline stage-by-stage and, at each stage, looks for four things: **(a) redundant work**,
> **(b) speed-ups**, **(c) unnecessary gates** (anything duplicating GitHub's own
> branch-protection / required-checks, or adding latency without safety value), and **(d) gate
> issues / correctness** (races, false-reds, manufactured transients, cache-a-wrong-verdict).
> Deliverable is this doc **plus the ranked follow-up list at the end** — not a code change.
> Docs-only: no engine script is touched here; each finding below is scoped to become its own
> backlog item owned by whoever builds it.

Audited at commit `13653fe` (branch `feat/flow-audit`), 2026-07-03. Citations are `file:line` into
`scripts/herd/` unless noted.

---

## Measurement basis (honest caveat)

The cost/latency instrumentation precursor is **shipped** — `scripts/herd/cost.sh` (token summer +
perishable price table), the `herd cost` reader in `bin/herd`, and `cost` journal events emitted from
`do_merge` (`cost_emit_merge`, `agent-watch.sh:610`). The audit was asked to ground per-stage claims
in those real numbers. **In this checkout there is no runtime data to read:** `herd cost` returns
*"No cost events recorded yet"* and no `.herd/journal.jsonl` exists in either the worktree or the main
repo — nothing has drained through the instrumented merge path here. So cost figures below are
**derived** (from the price table in `cost.sh:57-68` and the dogfood model choices), not measured, and
are labelled as such.

What **is** measured, live, in this worktree:

| Metric | Value | How measured |
|---|---|---|
| **Healthcheck wall-time (CLEAN, heavy profile)** | **~99 s** (`34.8s user + 27.2s sys`, `1:39` real) | timed `bash scripts/herd/healthcheck.sh <worktree>` |
| Hermetic test files run per healthcheck | **48** (`tests/test-*.sh`) + 1 `.bats` | `ls tests/test-*.sh \| wc -l` |
| Base tick cadence | **fixed `sleep 4`** (`agent-watch.sh:1963`) | source read |
| Orphan sweep cadence | every **15 ticks (~60 s)** (`agent-watch.sh:1644`) | source read |
| Review model (dogfood default) | **`claude-opus-4-8`** on every PR (`.herd/config:28`) | config read |
| Derived Opus review price | **$5 / Mtok in, $25 / Mtok out** (`cost.sh:60`) | price table |

**Takeaway:** the audit could not "cut measured hot-spots" for token/$ because no journal exists to
measure — so the first action item is procedural: **run one real drain to populate the journal**,
then re-confirm the cost rankings below against `herd cost`. Latency claims *are* grounded (the ~99 s
healthcheck is the dominant measured cost) and the correctness findings are static-analysis facts that
need no runtime data.

---

## Stage-by-stage findings

### 1 · Backlog / scribe

- **(a) Redundant — per-item `git pull` inside the drain loop.** `scribe-step.sh:67` runs
  `git pull --ff-only --quiet` on **every claimed backlog item**, not once per drain session. A burst
  of N scribe requests → N sequential pulls of the same branch. `_report_and_cleanup`
  (`scribe-step.sh:40-48`) also forks a `git rev-parse` + `herdr notification show` per item.
- **(b/c) Good — the drainer is persistent, not per-item churn.** `scribe.sh` ensures exactly one
  drainer (dedup via `herdr agent list` + a spawn-lock, `scribe.sh:34-66`); the tab closes only when
  the queue empties (`scribe-step.sh:89-92`). No spawn/teardown per item — this stage is already lean
  on process churn. The only per-item cost is the pull + the notification fork.

### 2 · Lane spawn (builder worktree)

- **(a) Redundant — full `git fetch` on every spawn.** `new-feature.sh:19` runs
  `git -C "$REPO" fetch -q "$HERD_REMOTE"` for **every** lane spawn, even when the coordinator queues
  several builders back-to-back off the same `$DEFAULT_BRANCH`. ~8-10 subprocesses per quick spawn,
  ~12-14 per feature spawn (feature adds an allowlist append, an inline `python3` free-port scan
  `herd-feature.sh:81-90`, a pane rename, and an app-monitor pane run).
- **(d→shipped) Multi-KB argv is fixed.** Task specs are externalized to
  `$WORKTREES_DIR/$SLUG.task.md` and only a short pointer rides in argv (`herd_write_task_spec`,
  `herd-config.sh:582-599`; called `herd-quick.sh:81`, `herd-feature.sh:74`). Shipped `fd74659`.
- **(b) Prompt-cache ordering is inverted — confirmed.** Both lanes build the spec as
  `SPEC="$TASK"$'\n\n'"$RULES"` — **unique task first, static `[workflow rules]` block last**
  (`herd-quick.sh:79`, `herd-feature.sh:72`; `$RULES` at `herd-quick.sh:70-73` /
  `herd-feature.sh:63-66`). Anthropic's prompt cache keys on the longest shared *prefix*, so close-in-
  time spawns share nothing. Already tracked as a 🔜 backlog item ("Prompt-cache-aware prompt
  ordering"); this audit **confirms** it and adds that `$RULES` also interpolates `$HERE/$DIR/
  $BACKLOG_FILE`, so the block is not byte-identical across slugs even after inversion — the stable
  prefix must be the AGENTS/tool preamble, not the whole footer.

### 3 · Build (isolated builder)

- No new redundancy beyond the known "isolated builders re-derive context from files" cost, which is
  inherent to worktree isolation and out of scope for a cheap win. The MODEL_ESCALATE_GLOB step-up
  (`herd-quick.sh:42-47`) already routes judgment-heavy engine surfaces to the stronger tier — shipped
  `PR#64`.

### 4 · Watcher tick loop (`agent-watch.sh`)

- **(a) Redundant — per-candidate `gh pr view` re-verify duplicates the once-per-tick `gh pr list`.**
  Each tick opens with one `gh pr list --json number,…,mergeable,mergeStateStatus,headRefOid`
  (`agent-watch.sh:1650`). Then, **per merge candidate**, the action loop re-fetches the *same fields*
  with `gh pr view --json mergeable,mergeStateStatus,headRefName,headRefOid | python3`
  (`agent-watch.sh:1799-1805`). So mergeability is queried **twice per tick per candidate** — an extra
  `gh` round-trip that scales `O(N candidates)` and pushes toward GitHub rate limits.
- **(b) Speed-up — fixed 4 s tick has no idle backoff.** `sleep 4` is a hard-coded literal with no
  config key and no adaptive backoff (`agent-watch.sh:1963`). An **idle** herd (zero in-flight work)
  still forks `gh pr list` + `herdr agent list` + `git worktree list` + a `python3` join every 4 s
  (`agent-watch.sh:1650-1659`) — pure rate-limit and (negligible-but-nonzero) cost with no throughput
  gain.
- **(a) Redundant — nothing memoized across ticks except the sha-keyed gate markers.** The full PR/
  agent/worktree join and the header/landed render are rebuilt from scratch every 4 s
  (`agent-watch.sh:1647-1683`); builder-liveness `git status --porcelain` runs per worktree per tick
  (`agent-watch.sh:1255,1723`). Correctly cached across ticks: the healthcheck verdict
  (`.health-result-<pr>-<sha>`, `agent-watch.sh:1435`), the review ledger (per-sha rows,
  `record_review` `:283`), and the review markers (`.review-*-<pr>-<sha>`, `:305-307`).
- **(d) Correctness — `gh pr view` empty-parse surfaces a transient as a red row.** The python at
  `agent-watch.sh:1800-1805` emits empty strings on a JSON/network failure; an empty `rmergeable`
  then falls to the non-MERGEABLE branch (`:1811`) and paints *"needs you · changed under us"*
  (`:1818`) on a transient `gh` hiccup. Not cached (re-evaluated next tick), but it is a visible
  **false-red** — exactly the class the "no false-red consoles" directive targets.

### 5 · Healthcheck gate

- **(b) Speed-up — the 48-file hermetic suite runs sequentially; ~99 s measured.** The heavy profile
  runs `bash -n` over all scripts, `shellcheck -S error` (if present), then the hermetic tests in a
  sequential loop (`.herd/healthcheck.project.sh:20-99`). Measured wall-time here is **~99 s** and it
  is CPU-bound (62% CPU, `34.8s user`). The tests are hermetic (they stub herdr), so the *intra-suite*
  files are candidates for parallelization independent of the cross-PR mutex.
- **(c/d) `HEALTH_CONCURRENCY=1` serialization — real reason, but the mitigation is itself a smell.**
  Default `1` (`herd-config.sh:181`, enforced by `_health_slot_free` `agent-watch.sh:1414`). The stated
  reason: all feature worktrees **share one `.git` object store**, so overlapping suites race on git
  locks and paint false-red (`agent-watch.sh:1379-1390`). This is a genuine shared-resource argument,
  **not** pure conservatism — but it is a *git-lock* argument, not a working-dir-isolation one, and the
  code's own retry-before-red (below) exists specifically to forgive the contention it can't fully
  prevent. That the gate must launder its own lock races is evidence the serialization is defensive.
- **(d) Gate issue — retry-before-red can launder a *real* intermittent failure into a merged pass.**
  A first heavy rc=1 (code error) triggers **one solo retry still holding the mutex**
  (`agent-watch.sh:1540-1546`); pass-on-retry is recorded `FLAKY` and **proceeds as passing**
  (`:1551`), reproduce-on-retry is `CODEERROR` red (`:1560`). The retry reduces cross-worktree
  contention (it runs solo) — but it does **not** distinguish an infra/lock flake from a genuinely
  flaky *test* or a real bug that fails ~50% of the time. Such a bug passes the gate as `FLAKY` and
  merges. The code comment even admits a prior tick *"MANUFACTURED its own transient
  code-error→flaky-pass"* (`agent-watch.sh:1425-1426`).
- **(d) Gate issue — a sticky `CODEERROR` can cache a contention false-red.** `CODEERROR` is cached
  per-sha and re-surfaces every later tick **without re-running** (`agent-watch.sh:1506-1510`, written
  `:1560`). A code-error that reproduces across *both* the initial run and the single solo retry only
  because of sustained lock contention on the shared object store becomes a sticky red for that sha —
  the exact failure mode the header acknowledges (`:1378-1379`).
- **(a) Duplicative-by-design vs the builder.** The healthcheck re-runs the same test suite the
  builder ran locally pre-PR. The sha-cache (shipped `PR#66`) dedupes it **across ticks** but not
  against the builder's own run — acceptable (the gate must be authoritative), noted for completeness.

### 6 · Review gate (`herd-review.sh`)

- **(c) Unnecessary-for-some-diffs — Opus on every PR by default; the tiering shipped but is OFF.**
  `MODEL_REVIEW` defaults to `claude-opus-4-8` (`.herd/config:28`) and every PR gets a full
  adversarial review — the single biggest recurring engine cost (`herd-config.sh:140`). The
  risk-tiered gate **shipped** as `PR#73` (`REVIEW_ESCALATE_GLOB` + `REVIEW_MODEL_CHEAP` +
  `REVIEW_ESCALATE_MAXFILES`, classify at `agent-watch.sh:318-334`, dispatch `:463-483`): docs/test-
  only diffs → **review skipped** (PASS recorded `source=skipped-low-risk`), small low-risk → cheap
  tier, engine-surface glob / large diff → Opus, fails safe to Opus. **But `REVIEW_ESCALATE_GLOB` is
  empty in the dogfood `.herd/config`, so tiering is off and the herd still pays Opus-on-every-PR** —
  including on this very docs-only PR. The lever is built; it is simply not switched on.
- **(b) Prompt-cache ordering is inverted in the review prompts too.** Both the headless `TASK`
  (`herd-review.sh:228`) and the agent-pane `AGENT_TASK` (`:245`) **open** with the PR-unique tokens:
  *"…REVIEWER for PR #${PR} (branch slug '${SLUG}') of the project '${WORKSPACE_NAME}'…"*. The stable
  adversarial preamble and the (per-project-stable) checklist follow. So the first tokens vary per PR
  and defeat cross-PR prefix caching. The existing prompt-ordering backlog item flagged this to
  "audit" — **confirmed here**: fix the review prompts alongside the lane prompts.
- **(b/c) No HC↔review compute overlap, and no waste.** Review is read-only (`gh pr diff` +
  at most one `gh pr comment`), never re-runs tests, and is reached only after a CLEAN/FLAKY
  healthcheck (`herd-review.sh:5-9,38`). The two gates are independently bounded
  (`REVIEW_CONCURRENCY=2`, `HEALTH_CONCURRENCY=1`) and background reviews for different PRs overlap. No
  redundant test execution between them.
- **(d) Verdict-caching is well-guarded.** INFRA-FAIL / empty / rc0-no-verdict are **never cached** and
  are retried (bounded `_REVIEW_RETRY_MAX=3`, `agent-watch.sh:446-450`); only `source=reviewer`
  verdicts are cached and eligible to auto-refix (`:283,861`). This is the right defense against
  caching a transient as a sticky BLOCK (regression `:409-410` explicitly fixed). Residual accepted
  property: a genuine-but-wrong reviewer PASS is cached per-sha until a new commit — inherent to
  trusting the model's verdict, not a bug.

### 7 · Auto-refix rounds + wake verification

- **(b/d) Solid.** `REVIEW_AUTOFIX` is `true` in the dogfood (`.herd/config:47`; engine default
  `false`, `herd-config.sh:182`). Only `source=reviewer` verdicts may bounce a builder
  (`agent-watch.sh:861-865`); round cap `REFIX_MAX_ROUNDS=3` per-sha (`:871`, `record_refix` written
  *before* send `:879`); wake verified by a status-flip poll (`_wait_agent_working`, up to 15 s,
  `:892-893`) with one re-send on timeout (`:897-898`) and a `claude --continue` resume fallback for a
  dead session (`:913`). No cheap win here — this stage already retries-before-alarming and verifies
  the wake, matching the "no false-red" directive.

### 8 · Merge re-verification (`do_merge`)

- **(c) Lean — `do_merge` does not re-gate.** It records idempotency state first (`:605`), then goes
  straight to `gh pr merge` (`:603`) and relies on **GitHub's own** merge enforcement (a failed merge
  → `return 1`). It does **not** re-run healthcheck/review. Good — no duplicated gate at merge time.
- **(d) Correctness — the `candsha`/`rsha` divergence race.** The healthcheck is keyed to `CAND_SHA`
  captured from the once-per-tick `gh pr list` (`agent-watch.sh:1745`, passed to the gate `:1784`),
  while the review-and-merge path uses a **later** `rsha` from the per-candidate `gh pr view`
  (`:1799,1825,1830`). If a new commit lands **between** those two `gh` calls in the same tick, the
  healthcheck verdict being merged on belongs to `candsha` (the *prior* commit) while review + merge
  run against `rsha`. The window is small (one tick) but the failure is silent: a merge can proceed
  on a healthcheck that never ran against the merged sha. This is the sharpest correctness finding.

### 9 · Reap

- **(b/c) Lean.** `do_merge` reaps in order (`agent-watch.sh:604-621`): record state → journal `merge`
  → `cost_emit_merge` (best-effort, silent, `cost.sh:219`) → scribe backlog-reap enqueue → `git pull
  --ff-only` main → `git worktree remove --force` → journal `reap` → `herd_teardown_slug` (closes
  builder/review/resolver tabs). Orphan-tab sweep is amortized to every 15th tick
  (`_sweep_orphan_tabs`, `:640,1960`), not every tick — already the right cadence.
- **(d) Instrumentation gap, not a gate bug — the review-cost blind spot.** `cost.sh` is honest that
  it captures cost only at merge from the *builder worktree's* transcript dir, so **reviews on PRs
  that BLOCKED and never merged, and reviews that ran after the worktree was reaped, are not counted**
  (`cost.sh:24-26`). Since review is the biggest cost and blocked PRs are exactly the expensive
  multi-round cases, `herd cost`'s "cost per merged PR" **undercounts total review spend**. The
  efficiency program is "measure first" — its measurement has a known blind spot on its own top line.

### Cross-cutting: journal write cost

- **(b) `journal.sh` forks a `python3` per event** for JSON encoding (`journal.sh:87-103`), plus a
  `date -u` and a `wc -c` size check, inside a strict-mode-neutralized subshell (`:114-117`). Cheap per
  call, but every gate event (`review_dispatched`, `verdict_recorded`, `healthcheck_outcome`,
  `refix_bounce`, `merge`, `reap`, `cost`, …) pays a Python interpreter startup. Multiplied across a
  busy drain it is a measurable, avoidable constant.

---

## Already shipped (do NOT re-propose)

The audit confirmed these previously-planned optimizations are landed; ranked follow-ups below must
not re-open them:

| Optimization | Status | Evidence |
|---|---|---|
| Healthcheck **sha-cache** (per-`<pr>-<sha>` verdict, stop re-running unchanged commit each tick) | ✅ `PR#66` | `e59daf3`; markers `agent-watch.sh:1435`, hit event `healthcheck_cache_hit` |
| **Task-spec externalization** (full spec → file, short pointer in argv) | ✅ `fd74659` | `herd_write_task_spec` `herd-config.sh:582-599` |
| **Cost instrumentation** (token summer + `herd cost` + `cost` journal events) | ✅ `PR#68` / `e2a0ae5` | `cost.sh`; `cost_emit_merge` `agent-watch.sh:610` |
| **Risk-tiered review** (`REVIEW_ESCALATE_GLOB`, cheap tier, docs/test skip, fail-safe to Opus) | ✅ `PR#73` — **but OFF by default in dogfood** | `8c15456`; classify `agent-watch.sh:318-334` |
| **MODEL_ESCALATE_GLOB** deterministic model step-up (builder lanes) | ✅ `PR#64` | `herd-quick.sh:42-47` |
| Auto-refix resume + limit-hit auto-resume; launch-binding guard; per-workspace argv0 marker | ✅ `PR#71 / PR#67 / PR#65` | Recently-shipped in `BACKLOG.md` |

Note the nuance on `PR#73`: the *mechanism* shipped, so "build risk-tiered review" is done — but the
dogfood config never sets `REVIEW_ESCALATE_GLOB`, so the biggest measured cost lever is **built and
unused**. That gap is follow-up #2 below, and it is config-only, not a re-build.

---

## Ranked follow-up items

Ranked by **(safety/value × confidence) ÷ effort**. Each is scoped to become its own `BACKLOG.md`
entry. Correctness bugs lead; then the highest-value/lowest-effort cost lever; then speed-ups; then
minor efficiency. Items already in the backlog are marked *(existing 🔜 — reprioritized/confirmed)*.

1. **Close the `candsha`/`rsha` divergence race in the merge path.** *(new — correctness, highest)*
   Capture one authoritative head sha per candidate per tick and thread the **same** sha through
   healthcheck, review, and merge, or re-assert `head == candsha` immediately before `gh pr merge` and
   abort/retry the tick if it moved. Prevents merging on a healthcheck verdict that never ran against
   the merged commit. Touch: `agent-watch.sh:1745,1784,1799,1825,1830`. Small diff, high safety;
   hermetic test: inject a sha change between `pr list` and `pr view` → assert no merge.

2. **Enable `REVIEW_ESCALATE_GLOB` in the dogfood `.herd/config`.** *(new — cost, highest value/lowest
   effort)* The tiering mechanism shipped (`PR#73`) but the dogfood never switches it on, so the herd
   still pays Opus on every PR (including docs-only). Set `REVIEW_ESCALATE_GLOB` to the engine-surface
   pattern (reuse `MODEL_ESCALATE_GLOB`'s `bin/herd|agent-watch|herd-review|cmd_reload`), pick
   `REVIEW_MODEL_CHEAP=claude-sonnet-4-6`, and verify docs/test-only PRs skip review. Config-only,
   near-zero risk (fails safe to Opus), directly attacks the biggest cost. Validate on the sim rig.

3. **Harden healthcheck retry-before-red to forgive only *infra/lock* flakes, not arbitrary `rc=1`.**
   *(new — gate correctness)* Today a single solo retry that happens to pass records `FLAKY` and
   **merges**, so a genuinely flaky test / a ~50%-failing real bug is laundered into a pass
   (`agent-watch.sh:1540-1555`). Gate the "forgive" branch on an infra signature (git `.lock`
   contention, herdr-stub timeout) rather than any rc=1; a non-infra reproduce-or-not should either
   re-run more than once or surface as needs-you. Prevents the manufactured-transient class from
   shipping bad code. Hermetic test: a deterministically-flaky test file → assert it does **not** cache
   `FLAKY`+merge.

4. **Drop the redundant per-candidate `gh pr view` re-verify and add retry-before-false-red.**
   *(new — redundant work + false-red)* Reuse the fields already returned by the once-per-tick
   `gh pr list` (`agent-watch.sh:1650`) instead of a second `gh pr view` per candidate
   (`:1799-1805`); where a fresh read is genuinely needed at merge time, retry a transient
   empty/parse-failure before painting *"changed under us"* (`:1818`). Cuts an `O(N candidates)` gh
   round-trip and removes a visible false-red on gh hiccups.

5. **Parallelize the intra-suite hermetic tests in the healthcheck.** *(new — speed-up, biggest
   measured latency)* The 48 `tests/test-*.sh` files run sequentially for a **measured ~99 s**
   (`.herd/healthcheck.project.sh:94`). They are hermetic (stubbed herdr), so run them under a bounded
   `xargs -P` / job pool **within** a single healthcheck, independent of the cross-PR
   `HEALTH_CONCURRENCY=1` mutex (which guards the shared `.git` object store, a separate concern).
   Target: ~99 s → ~15-25 s. Keep the tab-leak / leak-guard / caps-sync post-checks serial. Requires
   confirming no two hermetic tests collide on a temp path.

6. **Make the tick cadence adaptive (idle backoff) and configurable.** *(new — rate-limit + cost)*
   Replace the hard-coded `sleep 4` (`agent-watch.sh:1963`) with a `WATCH_INTERVAL` config key and an
   idle backoff: when a tick finds zero in-flight builders/PRs, grow the sleep (e.g. 4 s → 15 s → 30 s
   cap) and reset to the floor the moment work appears. Stops an idle herd from forking `gh pr list` +
   `herdr agent list` + `git worktree list` every 4 s against GitHub's rate limit.

7. **Fix prompt-cache ordering in the review prompts (extends the existing lane-prompt item).**
   *(existing 🔜 — confirmed & widened)* The prompt-ordering backlog item covers the lanes; this audit
   **confirms** both review prompts are also inverted (`herd-review.sh:228,245` open with `PR #${PR}`).
   Fold the review prompts into that item's scope: stable adversarial preamble + checklist first,
   per-PR diff/number last; add the prompt-order lint it already proposes to `herd-review.sh` too.

8. **Close the review-cost instrumentation blind spot.** *(new — measurement completeness)* `herd
   cost` misses reviews on PRs that BLOCKED-and-never-merged or ran after worktree reap
   (`cost.sh:24-26`) — the expensive multi-round cases — so "cost per merged PR" undercounts review
   spend. Emit a `cost` event at **review completion** (not only at merge) keyed by pr+sha, so blocked-
   PR review cost is counted. Needed for the whole efficiency program to rank cost levers honestly.

9. **Coalesce the per-spawn `git fetch`.** *(new — minor redundancy)* `new-feature.sh:19` fetches on
   every lane spawn; skip it if `$DEFAULT_BRANCH` was fetched within the last N seconds (timestamp
   marker), so a coordinator queueing several builders back-to-back fetches once, not N times.

10. **Replace `journal.sh`'s per-event `python3` JSON encode with a bash encoder.** *(new — micro-
    efficiency, high multiplier)* Every journal event forks a Python interpreter (`journal.sh:87-103`).
    A small pure-bash JSON-string escaper (the fields are known/simple) removes a process startup from
    every gate event on a busy drain. Lowest priority — correctness-neutral, additive.

**Already-tracked items this audit reinforces (no new entry needed, but re-confirmed live):** the
prompt-cache-ordering item (#7 above), *evidence-based model escalation*, and *match builder spawn
rate to `REVIEW_CONCURRENCY`* — all three remain 🔜 in `BACKLOG.md` and this audit found nothing that
changes their scope, only that the instrumentation to prioritize them (item #8) should land first.

---

*Cross-references: the six efficiency levers in `BACKLOG.md` § Efficiency / cost (this doc's parent),
the sandbox-consumer sim rig (validate any flow change from items 1-6 there before shipping), and the
herdkit-vs-harness EPIC (shares the cost-instrumentation precursor). Findings 1, 3, and 8 are the ones
most worth building before any further cost tuning — a correct, fully-measured pipeline is the
prerequisite for cutting it safely.*
