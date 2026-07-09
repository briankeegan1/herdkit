# SPIKE: Cross-seat coordination substrate for seat-local gate ledgers

**Tracker:** HERD-234 (audit N8 / G5)  
**Status:** design spike only — **no engine code changes** in this PR  
**Date:** 2026-07-09  
**Audience:** coordinator + engine maintainers  
**Grounding:** `docs/audits/2026-07-09-gating-hardening.md` §3 G5 + §7 N8; doctrine `docs/multi-seat-doctrine.md` R1  
**Companion:** the only existing shared gate artifact is documented in `docs/governance-gates.md` (HERD-194)

## 0. Why this spike exists

herdkit is worked by **many coordinator seats at once** against one repo
([`docs/multi-seat-doctrine.md`](../multi-seat-doctrine.md)). Each seat runs its own watcher,
builders, and `$TREES` (= `WORKTREES_DIR`, default `${PROJECT_ROOT}-trees` —
`scripts/herd/herd-config.sh:120`, bound as `TREES` at `scripts/herd/agent-watch.sh:132`).

**GROUNDED fact (audit G5):** with `WATCHER_SCOPE=all`, gates dedup across seats **only** via the
`herd/gates` commit status (`agent-watch.sh:8817-8828`, `_gate_status_blessed:2500-2506`).
Everything else that bounds budgets, holds, and dispatch is a file under **this seat's** `$TREES`.
Two seats watching the same CONFLICTING PR both call `spawn_resolver` into their own worktrees and
race `git push` on the same branch (`spawn_resolver` at `:3545-3561`, keyed on seat-local
`$RESOLVE_STATE` at `:142`).

This is the doctrine's named correctness defect (R1: seat-local side-effects look correct with one
seat and fail with three). HERD-194 / HERD-247 already share *one* class of truth (blessing +
standing BLOCK) over GitHub. This spike inventories the rest and proposes how to share what must
be shared — without changing single-seat behavior by one byte until a later, gated implementation PR.

> **Non-goal of this spike:** implementing any shared ledger, changing `agent-watch.sh` behavior,
> or shipping a multi-seat sim. Deliverable is this design doc only. First concrete follow-up:
> **resolver single-flight across seats**.

---

## 1. Shared substrate already in place (baseline)

| Artifact | Where | What it shares | What it does NOT share |
|---|---|---|---|
| `herd/gates` commit status (context `herd/gates`) | GitHub Statuses API via `post_gate_status` (`agent-watch.sh:2473-2494`); context constant `:253` | "this sha already cleared health+review" — other seats heal ledger + skip re-running gates (`:8817-8828`) | budgets, holds, resolver dispatch, approvals, in-flight workers |
| Seat-local post ledger `$GATE_STATUS_STATE` | `$TREES/.agent-watch-gate-status` (`:249`) | nothing across seats — only at-most-once *post* dedup for THIS watcher | foreign posts (read live via `_gate_status_blessed`) |
| Standing-BLOCK guards (HERD-247) | PR review comments + `herd/gates` (`:2508-2515`) | a foreign BLOCK is terminal for the sha (setter + merge guards) | PASS/verdict ledgers still seat-local; two seats still double-dispatch reviewers before either comments |
| Tracker claim (HERD-50) | backend (`herd-claim.sh:31`, `_backend_claim_item`) | "this work item is owned by identity X" across operators | gate/PR lifecycle; not a substitute for resolver single-flight |

The rest of this doc focuses on the **six** ledgers the audit and backlog item name as the
cross-seat coordination surface: refix budget, stale-dup notes, approvals, resolver-dispatch,
review-inflight, claim.

---

## 2. Inventory — each seat-local ledger (file:line + storage)

Every "seat-local" claim below is grounded against live code. Storage root is always
`$TREES` = `$WORKTREES_DIR` unless noted. Two seats with different checkouts ⇒ different
`$PROJECT_ROOT-trees` directories ⇒ **independent files** for every row below.

### 2.1 Refix budget

| Field | Value |
|---|---|
| **Storage** | `$TREES/.agent-watch-refixed` (`REFIX_STATE`) |
| **Binding** | `agent-watch.sh:158-161` |
| **Row format** | `"<epoch> <pr#> <headSha> <slug> <kind>"` with `kind ∈ review\|health\|stale` (`:5005-5009`, `record_refix:5044-5047`) |
| **Readers (behavior)** | `refix_attempted` once-guard (`:5014-5018`); `refix_round_count` shared per-PR cap (`:5021-5026`); `refix_round_count_kind` for escalation evidence (`:5028-5036`) |
| **Budget semantics** | review / health / stale-base autofixes **share one per-PR budget** capped at `REFIX_MAX_ROUNDS` (`:5007-5008`) |
| **Seat-local proof** | append is bare `>> "$REFIX_STATE"` (`:5046`); no network read, no shared lock, no foreign-seat visibility |

**Cross-seat failure mode:** seat A spends 3 rounds on review BLOCKs; seat B's independent ledger
still has budget 0/3 and bounces the same builder (or a second worktree on the same PR) three more
times. Cap is per-seat, not per-PR.

### 2.2 Stale-dup hold notes

| Field | Value |
|---|---|
| **Storage** | `$TREES/.agent-watch-stale-dup` (`STALE_DUP_STATE`) |
| **Binding** | `agent-watch.sh:225-229` |
| **Row format** | `"<epoch> <pr#> <sha> <kind>"` (`record_stale_dup_held:2804-2807`) |
| **Readers (behavior)** | `stale_dup_held_noted` (`:2796-2802`) — gates the once-per-sha **side effects** (PR comment + notification + journal), not the hold itself |
| **Hold decision** | live re-check via `stale_dup_check` in `stale-dup-gate.sh` (deterministic git + tracker-ref) — the decision is already seat-independent; only the *notify-once* ledger is local |
| **Seat-local proof** | `grep` against `$STALE_DUP_STATE` only (`:2800-2801`); each seat re-comments once |

**Cross-seat failure mode:** two seats each post one stale-dup hold comment + notify (noisy,
not a merge-correctness defect). The hold itself re-derives from live state every tick, so
**merge refusal does not depend on the ledger**.

### 2.3 Approvals (`MERGE_POLICY=approve|observe`)

| Field | Value |
|---|---|
| **Storage** | `$TREES/.agent-watch-approvals` (`APPROVALS`) |
| **Binding** | `agent-watch.sh:166-170`; same path in `herd-approve.sh:45` |
| **Row format** | `"<epoch> awaiting\|approved\|observed\|hv-informed <pr#> <headSha>"` (`:167-169`, writers `:2767-2793`) |
| **Readers (behavior)** | `approval_awaiting_noted` (`:2754-2757`); `approval_is_approved` (`:2760-2764`); `herd-approve.sh approve <pr#>` writes the `approved` row into **this** `$WORKTREES_DIR` |
| **Seat-local proof** | both the watcher that holds and the CLI that approves open the **local** file (`herd-approve.sh:45`); no GitHub write of the approval token itself |

**Cross-seat failure mode:** operator runs `herd approve 42` on seat A; seat B's watcher never
sees the `approved` row and keeps the PR on `ready · awaiting approval`. Conversely, seat B can
auto-merge under a different `MERGE_POLICY` while seat A still holds. Approvals are **not** a
shared truth today.

### 2.4 Resolver-dispatch ledger

| Field | Value |
|---|---|
| **Storage** | `$TREES/.agent-watch-resolve-attempts` (`RESOLVE_STATE`) |
| **Binding** | `agent-watch.sh:134-142` |
| **Row format** | `"<epoch> <pr#> <slug> <branch> <sha> dispatched\|escalated"` (`record_resolve_attempt:1397-1400`, `record_resolve_escalated:1403-1406`) |
| **Result file** | `$TREES/.resolve-result-<pr>-<sha>` (`_resolve_result_file:3245`) — also seat-local |
| **Readers (behavior)** | `resolver_dispatched_sha` (`:1360-1364`); `resolver_dispatch_count` budget (`:1353-1358`); `resolver_escalated_sha` terminal (`:1366-1371`); `_resolver_in_flight` same-seat liveness (`:3447-3493`) |
| **Dispatch** | `spawn_resolver` **record-first** then runs `herd-resolve.sh` (`:3545-3561`) into `$TREES/<slug>` (this seat's worktree) |
| **Seat-local proof** | every once-guard and budget counter reads only `$RESOLVE_STATE` (`:1361-1363`); `_resolver_in_flight` probes **this** seat's agent roster / tabs (`:3473-3492`), never another host |

**Cross-seat failure mode (the sharpest defect):**

1. PR #N is `CONFLICTING`.
2. Seat A: `resolver_dispatched_sha` false → `spawn_resolver` → worktree A merges + pushes.
3. Seat B: independent `$RESOLVE_STATE` also false → `spawn_resolver` → worktree B merges + pushes.
4. Both push the same branch → race, force-needed, or thrash; budgets double-count independently.

Same-seat double-dispatch is already prevented (`_resolver_in_flight:3447-3450` documents the
race). Cross-seat has **no equivalent guard**.

### 2.5 Review-inflight markers

| Field | Value |
|---|---|
| **Storage** | `$TREES/.review-inflight-<pr>-<sha>` (+ result/tier/block/registry siblings) |
| **Binding** | `agent-watch.sh:1630-1632`, path helper `:1666-1687` |
| **Body** | pid + start-time + dispatch timestamp (restart-safe substrate, `:1689-1705`) |
| **Verdict ledger** | `$TREES/.agent-watch-reviewed` (`REVIEW_STATE:150`) — also seat-local |
| **Seat-local proof** | never-double-dispatch is "marker exists with live pid" on **this** `$TREES` (`:1630-1632`); foreign seats cannot see the marker or the pid |

**Cross-seat failure mode:** two seats each dispatch an Opus reviewer for the same `(pr,sha)`
(cost burn). HERD-247 prevents a later PASS from overwriting a standing foreign BLOCK
(`:2508-2515`), but does **not** prevent the double dispatch itself. The combined
`herd/gates=success` blessing only lands **after** both gates pass, so pre-green work is
duplicated per seat (`:8817-8828` only helps once a blessing already exists).

### 2.6 Claim (work-item ownership)

| Field | Value |
|---|---|
| **Storage** | **not** under `$TREES` — lives in the active tracker backend |
| **Entry** | `herd_claim_or_abort` in `herd-claim.sh:130+`; contract `:11-29` |
| **Mechanism** | `_backend_claim_item` per backend (`herd-claim.sh:31`, e.g. file backend stamps `(claimed by <WHO>)` on `BACKLOG.md`; Linear/GitHub/Jira use assignee / state) |
| **When** | builder lanes, **before** worktree creation (`herd-feature.sh` / `herd-quick.sh` source `herd-claim.sh`) |
| **Cross-seat status** | **already shared** (tracker is the multi-operator truth). Residual races are backend-specific (file backend documents a pull-then-push residual; API backends use claim-verify) |

**Not a gate ledger.** Included because the audit/N8 list names it and because operators often
conflate "item claimed" with "PR lifecycle owned." Claim prevents double-**build** of a tracker
item; it does **not** prevent double-**resolve** or double-**review** of an open PR.

---

## 3. Classification

Legend:

- **must-share** — incorrect multi-seat behavior if seat-local (correctness or hard budget)
- **needs-coordination** — wasteful or noisy multi-seat behavior; correctness eventually heals
- **fine-seat-local** — correctly models per-seat resources (panes, agents, this host's processes)

| Ledger | Class | Why |
|---|---|---|
| **Resolver-dispatch** (`$RESOLVE_STATE` + `.resolve-result-*`) | **must-share** | Two resolvers on one branch is a push race. Same-seat guard exists; cross-seat does not. First implementation target. |
| **Refix budget** (`$REFIX_STATE`) | **must-share** | Cap is a PR-level safety rail ("stop bouncing forever"); per-seat caps multiply the rail out of existence. |
| **Approvals** (`$APPROVALS`) | **must-share** (when `MERGE_POLICY=approve`) | Human sign-off is a *repo* decision, not a seat decision. Seat-local approve cannot release another seat's hold. |
| **Review verdict ledger** (`$REVIEW_STATE`) | **must-share** (long-term) / **needs-coordination** (near-term) | Double PASS is mostly cost (HERD-247 covers BLOCK×PASS). Sharing verdicts avoids double Opus **and** is the natural path to per-gate blessings later (audit N9 note). Near-term: inflight claim is enough to stop the burn. |
| **Review-inflight** (`.review-inflight-*`) | **needs-coordination** | Correctness mitigated by HERD-247 + final `herd/gates` blessing; primary harm is **cost/latency**. A shared "review claimed for (pr,sha)" is enough. |
| **Stale-dup notes** (`$STALE_DUP_STATE`) | **needs-coordination** (notify-once) / hold is already shared | Hold re-derives from live git/tracker. Sharing the note prevents double PR comments only. |
| **Claim** (tracker backend) | **fine as shared** (already) | Do not re-implement under `$TREES`. Keep HERD-50 as the item-ownership substrate. |
| Health inflight/results, dead/limit/transcript, inbox, flair, push-holds, infra breaker | **fine-seat-local** (mostly) | Bind to **this seat's** agents, panes, and host. Exception: if two seats share one network `$TREES` (rare), RMW races apply (audit §5) — fix with locking, not GitHub. |
| `$GATE_STATUS_STATE` post ledger | **fine-seat-local** | Dedup of *our* POSTs; live truth is GitHub. |

### 3.1 Classification diagram (decision flow)

```
Is the ledger about a PR/sha invariant that must hold no matter who ticks?
  YES → must-share (resolver, refix budget, approve, eventually review verdict)
  NO  → Is it a once-only side effect (comment/notify) on shared surfaces?
          YES → needs-coordination (stale-dup note, review-inflight claim)
          NO  → Is it about this seat's process/pane/host?
                  YES → fine-seat-local
                  NO  → re-examine (probably must-share)
```

---

## 4. Shared-substrate options (with tradeoffs)

All options assume **GitHub is already the integration point** for this coding path (PRs, statuses,
comments). A future work-unit abstraction (HERD-163) may host the same shapes behind a non-PR unit;
the *classes* above stay valid.

### Option A — PR-comment ledger (machine-parseable)

**Shape:** watcher posts (or updates) a hidden / marker comment on the PR, e.g.

```
<!-- herd:ledger
resolve: dispatched pr=42 sha=abc seat=alice epoch=…
refix: review pr=42 sha=abc round=2
approve: approved pr=42 sha=abc by=bob
-->
```

| Pros | Cons |
|---|---|
| Zero new infra; every seat already reads PR comments (inbox, HERD-247 BLOCK scan) | Comment spam / edit races; need idempotent edit-by-marker, not append-forever |
| Auditable in the PR timeline | Rate limits; parse fragility; must never look like human review comments |
| Works offline-from-`$TREES` (any seat, any host) | Not a great fit for high-churn counters (every refix tick) |
| Natural fit for **approvals** and **resolver claim** (human-visible optional) | Secrets/PII: keep seat ids non-sensitive (login only) |

**Best for:** resolver single-flight claim, human approval records, terminal escalations.

### Option B — Commit-status namespace (extend HERD-194)

**Shape:** additional contexts alongside `herd/gates`, e.g.

| Context | States | Meaning |
|---|---|---|
| `herd/gates` | `success` only (today) | both gates green |
| `herd/resolve` | `pending` = in flight, `success` = DONE for sha, *(no failure — same SUCCESS-ONLY lesson)* | resolver claim / outcome |
| `herd/review` | `pending` / `success` | review claimed / PASS (BLOCK stays comment-based per HERD-247) |

| Pros | Cons |
|---|---|
| Same API + protection story as HERD-194; `_gate_status_blessed` pattern reuses | Status API is **per-sha**, not per-PR — fine for sha-keyed ledgers, awkward for PR-level budgets |
| Branch protection *could* require them later | **Do not** post non-passing states that flip `mergeStateStatus` to `UNSTABLE` (HERD-194 lesson at `:2429-2437`) — `pending` is especially dangerous on the default unprotected config |
| Live read is one `gh api …/statuses` | Description field is short; limited structured data |
| Natural "absence = free" claim protocol | Context proliferation; operators must understand the namespace |

**Best for:** sha-keyed **claims** (resolve/review in flight) where absence means free and
`success` means done — **if** `pending` is proven safe under the project's protection config, or
replaced by "description-only updates on a single neutral context" carefully designed not to
change mergeability. Safer variant: use **Check Runs** (Option B′) which can be `neutral` /
in-progress without the Statuses mergeability footgun.

### Option B′ — Check Runs API

Same idea as B, but `conclusion: neutral` / status `in_progress` / `completed` without the
Statuses-API mergeStateStatus trap. Slightly more API surface; better structured output summary.

### Option C — Shared git ref / state branch

**Shape:** `refs/herd/ledger` or branch `herd/state` holding append-only JSONL; seats fetch/push
with compare-and-swap (force-with-lease).

| Pros | Cons |
|---|---|
| Full structured state; not limited by status description length | **Push races** re-introduce the exact concurrency problem we are solving |
| Works without GitHub-feature coupling | Polling lag; auth; pollution of ref namespace |
| Could host all ledgers in one file | Operational burden (GC, corruption, "who rewound the ledger") |

**Best for:** nothing in v1. Revisit only if GitHub API options are blocked (GHES feature gaps).

### Option D — Single-owner claim via `herd/claims` status (seat election)

**Shape:** one seat "owns" a PR's gate lifecycle (posts `herd/claims` for the PR head); other seats
observe-only for that PR (still may build other PRs).

| Pros | Cons |
|---|---|
| Minimizes shared state (one claim row vs every ledger) | Owner death / offline → stuck PR unless TTL + steal |
| Matches "one watcher is enough" operational intuition | Fairness / starvation if one seat claims everything |
| Can compose with HERD-194 (owner is who may bless) | Still need shared claim substrate (A or B) for the election itself |

**Best for:** an optional policy mode (`GATE_OWNERSHIP=claim`) on top of per-ledger sharing —
not a replacement for resolver single-flight.

### 4.1 Recommendation

| Priority | Ledger | Substrate |
|---|---|---|
| P0 | Resolver single-flight | **Option A (PR comment marker)** *or* **Option B′ check-run `herd/resolve`** — prefer B′ if we can keep it invisible; A if we want zero new API surface and human-debuggable claims |
| P1 | Approvals | **Option A** (or a dedicated `herd-approve` PR comment / label `herd:approved:<sha>`) so `herd approve` is repo-global |
| P1 | Refix budget | **Option A** compact counter in the same ledger comment *or* journal+PR comment on each bounce (append-only events, reconstruct count) |
| P2 | Review-inflight / verdict | **Option B′** `herd/review` check-run, or carry-forward of PASS via comment; align with any future per-gate blessing (N9) |
| P3 | Stale-dup notify-once | **Option A** one-line marker, or accept double-comment as cosmetic |
| — | Claim (tracker) | **keep as-is** |

**Anti-recommendation:** do **not** put these ledgers on a shared network filesystem `$TREES`
and call it done. The watcher singleton lock is same-host-only (audit G5); two machines on one
NFS `$TREES` already race every RMW ledger. Shared `$TREES` is a deployment footgun, not a
coordination protocol.

---

## 5. Sketch — cross-seat resolver-dispatch dedup (first concrete follow-up)

### 5.1 Goal

For a given `(pr, headSha)` that is `CONFLICTING`, **at most one** resolver is dispatched across
all seats. Single-seat behavior remains **byte-identical** when no foreign claim exists.

### 5.2 Protocol (v1 — PR-comment claim)

Marker comment body (exact schema for the implementation PR):

```
<!-- herd:resolve-claim v1
pr: 42
sha: abcdef0
seat: alice
slug: my-feature
epoch: 1720000000
state: claimed | done | escalated
-->
```

**Algorithm** (runs inside `_classify_conflict` / before `spawn_resolver`, after existing
same-seat `_resolver_in_flight`):

1. **Read** PR comments (or a single edited bot comment found by marker). Filter `herd:resolve-claim v1` for this `pr`.
2. If a claim exists for **this sha** with `state=claimed` and age `< RESOLVE_CLAIM_TTL` (e.g. 45 min, ≥ resolver grace + typical resolve time):
   - If `seat` is us → treat as our in-flight (existing path).
   - If `seat` is foreign → **HOLD** row: `resolving conflict… (seat <other>)`; do **not** spawn; do **not** burn `$RESOLVE_STATE` budget.
3. If claim is `done` / `escalated` for this sha → same terminal handling as today's
   `_resolve_result` / `resolver_escalated_sha` (heal local ledgers from the shared marker).
4. If no live claim (or TTL expired → steal allowed):
   - **CAS-ish publish:** post/edit claim comment `state=claimed` for this sha **before**
     `record_resolve_attempt` + spawn (record-shared-first, then record-local, then spawn).
   - On comment API failure → fail-soft: today's single-seat path (never block solo on gh flake).
5. Resolver exit:
   - On DONE/ESCALATE → update shared claim to terminal state (best-effort) **and** write local
     `.resolve-result-*` as today.
6. **TTL steal:** if foreign claim is older than TTL and PR still CONFLICTING at same or new sha,
   journal `resolve_claim_steal` and claim. Prevents dead-seat stuck forever (doctrine R1).

### 5.3 Same-seat path stays byte-identical

When `WATCHER_SCOPE=mine` (default solo) **or** when the comment read returns no foreign claim:

- No new console rows.
- Local `$RESOLVE_STATE` / `_resolver_in_flight` unchanged.
- Optional: still write the shared claim (so a second seat that joins later sees us) behind
  `WATCHER_SCOPE=all` only — keeps default solo free of extra `gh` writes.

### 5.4 Failure modes the sketch must absorb

| Failure | Handling |
|---|---|
| Two seats post claims in the same second | Both may spawn once (TOCTOU). Mitigate with short pre-spawn re-read; accept rare double as better than none. Full CAS needs if-match edit or check-run id. |
| Seat claims then crashes | TTL steal. |
| Resolver pushes, claim not updated | Next tick: PR no longer CONFLICTING → no dispatch; orphan claim ages out. |
| `gh` outage | Fail-soft to local-only (solo progress > cross-seat purity). |
| Human resolves in UI | PR leaves CONFLICTING; claim ignored. |

### 5.5 What this does **not** solve (sequenced later)

- Refix budget sharing (P1)
- Approval portability (P1)
- Review double-dispatch (P2)
- Merge fairness / starvation (HERD-231 / N5 — independent)

### 5.6 Verification plan (for the implementation item, not this spike)

Hermetic multi-seat sim (audit N10): two watchers, two `$TREES`, one stub remote, one CONFLICTING
PR → scorecard `resolver_double_dispatch == 0`. Fault leg: claim API down → still progresses
(single-seat path). Register in `templates/conformance.tsv` when the capability ships.

---

## 6. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Statuses `pending` breaks mergeability** (HERD-194 lesson) | High | Prefer comment markers or Check Runs `neutral`; never post non-success Statuses that change `mergeStateStatus` in unprotected configs |
| **TOCTOU double-claim** | Medium | Pre-spawn re-read; TTL; treat rare double as degraded not fatal |
| **Comment noise / operator confusion** | Medium | HTML-hidden markers; optional `herd` bot account; never use human-facing review comment shape |
| **TTL too short** | Medium | Bound TTL to `max(resolver runtime p99, _RESOLVER_DEAD_GRACE)` with headroom; journal steals |
| **TTL too long** | Medium | Dead seat sticks; pair with seat liveness heartbeat later if needed |
| **Scope creep into shared `$TREES`** | High | Explicitly out of scope; doctrine wants repo-visible truth, not NFS |
| **Single-seat behavior drift** | High | Feature-gate on `WATCHER_SCOPE=all` (or new `CROSS_SEAT_LEDGER=off` default); posture-matrix byte-identical on solo |
| **Approval spoofing** | Medium | Only trust comments from known watcher identities / repo collaborators with write; mirror HERD-247 foreign-BLOCK trust model |
| **Cost of per-tick comment fetches** | Low | Cache etag / only fetch for CONFLICTING + approve-held PRs; memo per tick like other gh reads |

---

## 7. Phased path (single-seat byte-identical at every step)

Each phase is a separate PR. **Default config remains solo-identical** until an explicit lever
turns cross-seat coordination on (recommend reusing `WATCHER_SCOPE=all` as the master signal,
plus a ship-dormant `CROSS_SEAT_LEDGER=off|on` if we need finer control).

### Phase 0 — this spike (HERD-234) ✅

- Design doc only (this file).
- No engine code.
- Unblocks sequencing for resolver single-flight.

### Phase 1 — Resolver single-flight (follow-up item)

- Implement §5 behind `WATCHER_SCOPE=all` (no-op in default `mine`).
- Local `$RESOLVE_STATE` remains source of truth for same-seat budget/rows; shared claim is an
  **additional** guard, not a rewrite.
- Tests: unit parse/claim helpers; multi-seat sim scorecard (N10).
- Conformance row when capability is real.

### Phase 2 — Approvals as shared truth

- `herd-approve.sh approve` writes a repo-visible record (marker comment or label
  `herd:approved:<sha>`).
- Watcher `approval_is_approved` reads shared record first, falls back to local ledger (heal).
- `MERGE_POLICY=auto` path untouched.

### Phase 3 — Refix budget as shared counter

- On `record_refix`, also append a shared bounce event.
- `refix_round_count` = max(local, shared-reconstructed) so solo never softens the cap, and
  multi-seat cannot exceed it.
- Pairs with any per-rail budget redesign (audit N3) — do **not** redesign budget math in the
  same PR as the substrate move.

### Phase 4 — Review claim + optional verdict share

- Shared review-inflight claim (stop double Opus).
- Optional: foreign PASS adoption when HERD-247 would already allow merge (never adopt foreign
  PASS over standing BLOCK).
- Sets up per-gate blessing granularity (audit N9).

### Phase 5 — Cosmetic / notify dedup

- Stale-dup once-note, CI check notify, etc.
- Only after P0–P2 correctness ledgers land.

### Phase invariant (all phases)

> If `CROSS_SEAT_LEDGER` is off (or `WATCHER_SCOPE=mine`), the gate loop's observable behavior —
> dispatches, budgets, comments, merges — is **byte-identical** to pre-phase main, proven by the
> existing posture-matrix / sandbox sim green paths.

---

## 8. Proposed follow-up backlog shape (for the coordinator)

Not filed by this spike (builders do not mutate the tracker). Suggested children under the
gating-hardening epic:

1. **HERD-234.1 — Resolver single-flight across seats** (§5) — must-share; Phase 1.
2. **HERD-234.2 — Portable approvals** (Phase 2).
3. **HERD-234.3 — Shared refix budget counter** (Phase 3).
4. **HERD-234.4 — Review claim / verdict share** (Phase 4).
5. Depends on **N10 multi-seat sim** for proof of 234.1+.

---

## 9. Summary

| Question | Answer |
|---|---|
| What is seat-local today? | Nearly every gate ledger under `$TREES` (§2); only `herd/gates` (+ HERD-247 BLOCK comments, + tracker claims) is shared. |
| What must be shared first? | **Resolver-dispatch** (push race), then **approvals** and **refix budget**. |
| What substrate? | Prefer **PR-comment markers** and/or **Check Runs**; extend the HERD-194 status model carefully; avoid non-success Statuses and avoid "shared NFS `$TREES`". |
| How do we not break solo? | Gate on team scope / explicit lever; local ledgers remain; shared guards are additive fail-soft. |
| Deliverable of HERD-234? | **This doc only.** |

Refs: HERD-234.
