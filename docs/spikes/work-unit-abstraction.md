# SPIKE: Work-unit delivery abstraction

**Tracker:** HERD-163 (epic: HERD-395)  
**Status:** **SHIPPED** — the epic closed at Phase 5 (HERD-404, this doc's own §10). Two kinds ship
today: `git-pr` (default, both engines — the byte-identical original pipeline) and `doc-apply` (opt-in,
**python engine only**, HERD-399 — a manifest-driven docs-only delivery gated by the
`_safe_manifest_path` invariant, §9.3/`docs/capabilities-overview.md`'s "Work-unit delivery kind"
section). The bash `wunit_*` facade stays the tested **reference model**; the live seam is the python
engine (§9.1). Originally landed as a design-only spike (no engine changes) on 2026-07-09; every
section below this line documents the phase it was written at — read §9 and §10 for what actually
shipped and where the two implementations diverged from the original plan.  
**Date:** 2026-07-09 (spike) → 2026-07-20 (epic close)  
**Audience:** coordinator + engine maintainers  

## 0. Why this spike exists

herdkit's long arc is a **general autonomous-operations engine** (custom gates, shareable posture configs, non-code domains), not only a coding/GitHub co-pilot. Today a "work unit" **is** a git PR end-to-end:

- builder lanes open PRs,
- the watcher gates and merges PRs,
- reconcile keys off PR refs,
- cost / why / stats are PR-keyed.

That coupling is load-bearing and deliberate for the coding path — GitHub's PR is a durable, auditable delivery vehicle — but it blocks non-PR deliveries (config apply, doc-only apply, ops runbooks, non-git domains). This spike inventories the coupling, proposes a thin **work-unit interface** of which **git-PR is one implementation**, sketches a second implementation to prove the abstraction, and lays out a **phased migration that keeps the git-PR path byte-identical**.

> **Non-goal of this spike:** implementing the interface, changing watcher/lane scripts, or shipping a second unit kind. Deliverable is this design doc only.

---

## 1. Inventory: where the engine assumes `work unit == git PR`

Every claim below cites a real, spot-checkable `file:line` in this tree (as of the commit that lands this doc). Grouped by pipeline stage.

### 1.1 Builder lanes — open a PR as the unit of delivery

| Assumption | Citation | What hard-codes PR |
|---|---|---|
| Feature lane's create command is `gh pr create` (or `--draft`) | `scripts/herd/herd-feature.sh:160-176` | `PR_CREATE_CMD` resolved to `gh pr create` / `gh pr create --draft`; draft readiness via `gh pr ready <pr#>` |
| Quick lane identical create/ready wiring | `scripts/herd/herd-quick.sh:167-182` | same pattern as feature |
| Workflow rules tell the builder to open a PR, not merge, not touch backlog | `scripts/herd/herd-feature.sh:263-270` | `"Before running '$PR_CREATE_CMD'…"`, `"Do NOT merge the PR"`, `HUMAN-VERIFY` in **PR body**, approve by `<pr#>` |
| Quick lane same workflow rules | `scripts/herd/herd-quick.sh:271-278` | same text surface |
| Tracker linkage is a `Refs:` line **in the PR body** | `scripts/herd/herd-feature.sh:236-246`, `scripts/herd/herd-quick.sh:245-253` | `REFS_RULE` requires `Refs: <id>` in PR body for merge-time reconcile |
| Push gate resumes into push **+ PR create** | `scripts/herd/push-gate.sh:5-18`, `:220-227`, `:270-277` | `_pg_pr_create` defaults to `gh pr create`; resume message is "opening its PR" |
| Dead-builder / refix re-prompt ends with `gh pr create` | `scripts/herd/agent-watch.sh:5541` | pointer: `… then gh pr create.` |
| `new-feature.sh` operator hint is PR-create | `scripts/herd/new-feature.sh:91` | `"When done: gh pr create # then the watcher reviews & merges"` |
| Config-shared PR helper in CLI | `bin/herd:2165-2291` | `_config_shared_pr` path is `git push` + `gh pr create` |

### 1.2 Watcher discovery — the tick is a `gh pr list`

| Assumption | Citation | What hard-codes PR |
|---|---|---|
| Header / auto-merge rule is MERGEABLE+CLEAN PR → health → review → `gh pr merge` | `scripts/herd/agent-watch.sh:39-46` | explicit `gh pr merge <n> --merge` contract |
| Every tick fetches open PRs as the candidate set | `scripts/herd/agent-watch.sh:6928-6933` | `PRS_JSON="$(gh pr list --json …)"` then view-filter |
| Feature discovery joins worktrees **to open PRs** | `scripts/herd/agent-watch.sh:6940-6958` | record fields include `prnum`, `mergeable`, `mstate`, `headsha` from PR JSON |
| Inbox feed is PR comments on the tick's open PRs | `scripts/herd/agent-watch.sh:735-737`, `:838-870`, `:894-909` | `_inbox_fetch_pr_comments` → `gh pr view --json comments`; notify `"PR #${prnum}"` |
| Status one-shot also lists open PRs | `scripts/herd/status.sh:10`, `:189` | `gh pr list --json number,title,headRefName,…` |
| Team-mode / author scoping is PR author | `scripts/herd/agent-watch.sh:6370` (field list comment) | tick fields include PR `author` under team mode |

### 1.3 Gate path — review, health, holds are PR+sha keyed

| Assumption | Citation | What hard-codes PR |
|---|---|---|
| Review ledger rows are `<epoch> <pr#> <headSha> <verdict>` | `scripts/herd/agent-watch.sh:143-146`, `:1112-1116`, `:1243-1248` | `review_verdict` / `record_review` key on PR **and** sha |
| Review dispatch / tier uses `gh pr diff` | `scripts/herd/agent-watch.sh:1450-1464`, `:1487-1488` | `_classify_review_tier` runs `gh pr diff "$pr" --name-only` |
| Review harness default mode is PR number + `gh pr diff` / `gh pr comment` | `scripts/herd/herd-review.sh:81-88`, `:116-128`, `:434`, `:638`, `:692` | usage `herd-review.sh <pr> <slug>`; task text hard-codes PR #; posts `gh pr comment` |
| Local pre-PR review exists but is explicitly **not** the merge unit | `scripts/herd/herd-review.sh:81-88`, `:116-120` | `--local` reads `git diff`; "there is no PR yet"; merge gate still post-PR |
| HUMAN-VERIFY is parsed from **PR body** | `scripts/herd/human-verify.sh:1-16`, `scripts/herd/agent-watch.sh:2410-2421` | `_pr_body` → `gh pr view --json body`; hold is per-PR |
| Approvals ledger + CLI are PR-numbered | `scripts/herd/agent-watch.sh:163-165`, `:2170-2238`; `scripts/herd/herd-approve.sh:48-75`, `:183-223`, `:247-288` | `herd-approve.sh approve <pr#>`; `pr_merged` via `gh pr view … state` |
| Merge method / delete-branch flags are `gh pr merge` flags | `scripts/herd/agent-watch.sh:2467-2477` | `_merge_method_flag` → `--merge` / `--squash` / `--rebase` |
| CI check-run gate reads PR status rollup | `scripts/herd/agent-watch.sh:2302-2369` | `gh pr view --json statusCheckRollup` |
| Stale-dup / resolver / refix prompts name `PR #N` | `scripts/herd/agent-watch.sh:4002-4118`, `:4268-4317`, `:4440-4478` | operator-facing copy and builder wake text |
| Resolver task assumes a PR will flip CLEAN for the watcher | `scripts/herd/herd-resolve.sh:75` | "The PR will then flip to CLEAN…"; escalates via `gh pr comment` |
| Spawn-hold `after=` accepts slug **or PR number** | `scripts/herd/spawn.sh:16`, `:49`; `scripts/herd/agent-watch.sh:259-261` | dep release when PR shows MERGED |

### 1.4 Merge-or-apply — `do_merge` is `gh pr merge` + post-hooks

| Assumption | Citation | What hard-codes PR |
|---|---|---|
| `do_merge <slug> <pr#> <worktree> [sha]` | `scripts/herd/agent-watch.sh:3147-3258` | signature is PR-centric; pin via `--match-head-commit` |
| Apply step is `gh pr merge` | `scripts/herd/agent-watch.sh:3180-3196` | merge + MERGED-state recheck on non-zero |
| Merge ledger `$STATE` rows are `<epoch> <pr#> <slug> [ref]` | `scripts/herd/agent-watch.sh:129`, `:3202-3208` | idempotency key is PR number |
| `already_merged` matches PR# + slug | `scripts/herd/agent-watch.sh:1020-1023` | |
| Post-merge cost emit is keyed by PR | `scripts/herd/agent-watch.sh:3225`; `scripts/herd/cost.sh:12-13`, `:389-425` | `cost_emit_merge "$pr" "$slug" "$worktree"` → journal `cost … pr "$pr"` |
| Candidate pass calls `do_merge` with `$prnum` | `scripts/herd/agent-watch.sh:7491` | |

### 1.5 Reconcile — shipped work is "PR #N merged"

| Assumption | Citation | What hard-codes PR |
|---|---|---|
| Explicit tracker ref extracted from **merged PR body** | `scripts/herd/agent-watch.sh:2755-2786` | `_reconcile_pr_ref` → `gh pr view --json body` + `Refs:` line |
| `reconcile_backlog <pr#> <slug> <sha>` | `scripts/herd/agent-watch.sh:2820-2850` | scribe request: `"Reconcile: PR #${rb_pr} … shipped (PR #${rb_pr})"` |
| Reconcile ledger keyed by pr+sha | `scripts/herd/agent-watch.sh:215-220`, `:2743-2753` | `RECONCILE_STATE` |
| Backend write journals `HERD_TW_PR` | `scripts/herd/agent-watch.sh:2809-2812` | `export HERD_COMPONENT=reconcile HERD_TW_PR="$pr"` |
| Scribe treats "Reconcile: PR #N merged" as amend-not-new | `scripts/herd/scribe-step.sh:20`, `:286` | comment + routing for watcher's reconcile/reap requests |
| Offline backlog-reconcile CLI resolves a PR to a git range | `scripts/herd/backlog-reconcile.sh:60-76`, `:167`, `:220` | `gh pr view` for oids; verify cmd `gh pr diff ${pr}` |

### 1.6 Teardown — reap is post-PR-merge

| Assumption | Citation | What hard-codes PR |
|---|---|---|
| `_reap_slug <slug> <dir> <pr#> <sha> [reason]` | `scripts/herd/agent-watch.sh:2953-2971` | journal `reap pr …` |
| Startup reap-sweep proves MERGED via `gh pr view` | `scripts/herd/agent-watch.sh:3261-3349` | `_srs_gh_view`; never reap without head OID from PR |
| Orphan / resolve-tab sweeps consult `gh pr list` | `scripts/herd/agent-watch.sh:3413`, `:3614-3618`, `:3681` | open-PR set is the truth for "still in flight" |
| Purge ledgers on merge/reap by PR number | `scripts/herd/agent-watch.sh:2232-2291`, `:3218-3221` | `purge_pr_approvals`, `purge_pr_ci_checks` |

### 1.7 Forensics & measurement — `why` / `cost` / `stats` / journal

| Assumption | Citation | What hard-codes PR |
|---|---|---|
| Journal is the substrate for `herd why <pr>` | `scripts/herd/journal.sh:1-5`, `:11` | events carry `pr` field |
| `herd log --pr N` / `herd why <pr#>` | `bin/herd:5160-5189`, `:5185-5189` | CLI requires numeric PR |
| `herd cost [--pr N]` / cost-per-merged-PR | `bin/herd:5294-5310`, `:5411-5456`; `scripts/herd/cost.sh:6`, `:35-36` | rollup keyed by PR number |
| `herd stats [--pr N]` | `bin/herd:5486-5500`, `:5588` | same |
| Help text frames measurement as per-PR | `bin/herd:5903-5941` | |

### 1.8 Governance, policy, and product copy

| Assumption | Citation | What hard-codes PR |
|---|---|---|
| Merge policy answers "will the watcher **merge**?" | `scripts/herd/merge-policy.sh:2-17` | auto / approve / observe around PR merge |
| North star: "drain backlogs into **merged, verified code**" + PR gates | `docs/NORTHSTAR.md:9`, `:17`, `:25` | vision sentence and safety principle |
| Positioning thesis: durable path is "branch + PR + branch protection" | `docs/positioning-thesis.md:52-56`, `:80-81`, `:102-107` | time/presence decoupling still via PRs |
| Driver abstraction deliberately leaves git host out of the driver | `docs/driver-abstraction.md:38` | "the **git host** — `gh pr …`, `gh issue`" listed as runtime-independent — i.e. assumed universal |

### 1.9 What is *not* PR-shaped (already portable seams)

These are relevant because a work-unit interface can **reuse** them rather than re-abstract them:

| Portable surface | Citation | Why it already generalizes |
|---|---|---|
| Runtime **driver** (mux + agent exec) | `docs/driver-abstraction.md`, `scripts/herd/driver.sh` | herdr-claude / headless / stub — orthogonal to delivery vehicle |
| Tracker **backends** (file / github / linear / jira) | `scripts/herd/backends/*.sh`, claim + update-state | work *items* are already multi-backend; only *delivery* is PR-only |
| Healthcheck profiles | `scripts/herd/healthcheck.sh` | takes a worktree/dir, not a PR |
| Pipeline steps seams | `scripts/herd/steps.sh`; pre/post-merge hooks in `do_merge` | already named seams; "merge" is the overloaded word |
| Local review mode | `scripts/herd/herd-review.sh --local` | proves review can run without a PR number |
| Journal event schema | `journal_append event k v…` | free-form keys; `pr` is convention, not schema-enforced |
| Scribe / research drainers | `scribe.sh`, `research.sh` | already non-PR units of work (but they are **engine lanes**, not backlog delivery units) |

### 1.10 Coupling map (one picture)

```
  backlog item (tracker backend: file|gh|linear|jira)
        │
        ▼  spawn (slug + HERD_ITEM_REF)
  builder lane ──worktree──► gh pr create  ─────────────────────┐
        │                                                         │
        │                    ┌────────────────────────────────────┘
        │                    ▼
        │            watcher tick: gh pr list
        │                    │
        │         gate: health(worktree) + review(gh pr diff)
        │         hold: HUMAN-VERIFY / MERGE_POLICY / steps
        │                    │
        │                    ▼
        │            do_merge: gh pr merge
        │                    │
        ├──── cost_emit_merge(pr) ── journal ── herd why/cost/stats
        ├──── reconcile_backlog(pr) ── Refs: / scribe "PR #N shipped"
        └──── _reap_slug(pr) ── worktree + tabs + ledgers
```

**Bottom line:** isolation (worktree), agent runtime (driver), and tracker state (backends) already have seams. The **delivery + gate + apply + reconcile + teardown** chain is a single PR-shaped spine through `agent-watch.sh`.

---

## 2. Proposed work-unit interface

### 2.1 Vocabulary

| Term | Meaning |
|---|---|
| **Work item** | A backlog / tracker row (already multi-backend). Identity: tracker ref (`HERD-163`, issue URL, …). |
| **Work unit** | One delivery attempt for a work item (or an untracked ad-hoc task). Identity: opaque `unit_id` + `kind`. |
| **Kind** | Implementation binding: `git-pr` (today), future `doc-apply`, `config-apply`, … |
| **Artifact** | Kind-specific payload handle (PR number, apply-manifest path, …). |
| **Revision** | Kind-specific content fingerprint for "review once per change" (git head sha today). |

A work unit is **not** the worktree, the agent, or the tracker item. Those remain separate:

- worktree / sandbox = **execution isolation** (may be optional for some kinds),
- agent session = **runtime** (driver-owned),
- tracker item = **intent / queue** (backend-owned),
- work unit = **delivery vehicle + gate target**.

### 2.2 Interface contract

A work-unit **adapter** implements five operations. Names match the pipeline the watcher already runs; only the vehicle changes.

```text
work_unit.open      (ctx) → unit
work_unit.gate      (unit, revision) → gate_result
work_unit.apply     (unit, revision) → apply_result   # "merge-or-apply"
work_unit.reconcile (unit) → reconcile_result
work_unit.teardown  (unit) → teardown_result
```

Plus two **query** ops the tick needs:

```text
work_unit.list_open (ctx) → [unit…]
work_unit.inspect   (unit) → { revision, state, body, labels… }
```

#### Semantics

| Op | Responsibility | Success means | Failure posture |
|---|---|---|---|
| **open** | Publish a candidate delivery from a finished builder (or equivalent). Idempotent on same revision when the kind allows. | Unit is discoverable by `list_open`. | Builder stays in "building"; no gate yet. |
| **gate** | Run the authoritative readiness checks for this revision: health, adversarial review, policy holds, kind-specific remote checks. | `gate_result.status ∈ {pass, hold, block, wait}` with structured reason. | Never apply on non-pass. Sha-/revision-keyed once. |
| **apply** | Land the unit's change into the target of record (merge PR, apply docs, write config, …). Must be **at-most-once** per revision (or stronger). | Target of record reflects the unit; unit enters terminal-applied state. | No reconcile/teardown if apply did not land. |
| **reconcile** | Mark the linked work item done (explicit ref first, fuzzy fallback). Best-effort; must not undo apply. | Tracker/backlog reflects shipped (or no-op if untracked). | Advisory sweep is backstop (today's posture). |
| **teardown** | Release isolation resources (worktree, tabs, ledgers, markers). Idempotent. | No stranded resources for this unit. | Startup reap-sweep equivalent resumes. |

#### Shared types (logical — not a language binding yet)

```text
unit = {
  unit_id:   string,          # stable opaque id (for git-pr: "pr:123" or raw "123" during migration)
  kind:      "git-pr" | …,
  slug:      string,          # builder/isolation key (may be empty for non-worktree kinds)
  revision:  string,          # content fingerprint
  item_ref:  string | null,   # tracker ref if known
  artifact:  kind-specific,   # e.g. { pr_number, head_ref, base_ref }
}

gate_result = {
  status:  pass | hold | block | wait | error,
  reason:  string,
  holds:   [ { kind, detail }… ],   # human-verify, approve, push-gate, steps…
  evidence: { health?, review?, remote? }
}

apply_result = { status: applied | refused | already | error, reason }
```

#### Journal & ledger discipline

- Journal events keep a **`unit`** field (and optionally legacy `pr` for git-pr).  
  Example: `journal_append merge unit "pr:42" kind git-pr slug foo sha abc…`
- Ledgers that today key on `<pr#> <sha>` key on `<unit_id> <revision>` instead.
- `herd why` / `cost` / `stats` accept `--unit <id>` with `--pr N` as a **git-pr alias** for `unit=pr:N`.

#### Config seam

```bash
# .herd/config (proposed; not implemented by this spike)
WORK_UNIT_KIND=git-pr          # default — today's behavior
# future: WORK_UNIT_KIND=doc-apply  or a per-spawn override HERD_WORK_UNIT_KIND=
```

Kind selection is **project-default + optional per-spawn override**, mirroring `HERD_DRIVER` / lane choice — not a runtime guess from file paths (guessing is a later convenience, never the safety floor).

### 2.3 `git-pr` adapter = today's path, named

| Interface op | Today's function / command | Notes |
|---|---|---|
| `open` | builder runs `gh pr create` (`PR_CREATE_CMD`) | Draft/ready via `PR_FLOW` / `PR_READY_WHEN` |
| `list_open` | `gh pr list --json …` | Tick discovery |
| `inspect` | `gh pr view` / fields on list | body, headRefOid, mergeable, checks |
| `gate` | healthcheck + `herd-review.sh` + holds + CI/status | Already multi-gate; PR is only the handle |
| `apply` | `do_merge` → `gh pr merge --match-head-commit` | At-most-once via `$STATE` |
| `reconcile` | `reconcile_backlog` | `Refs:` then fuzzy scribe |
| `teardown` | `_reap_slug` + purge ledgers | Startup sweep resumes |

The migration goal is: **call sites speak the interface; the git-pr adapter body is a move/rename of existing code**, not a rewrite.

### 2.4 What stays *outside* the work-unit interface

Do **not** fold these in — they already have better homes:

| Concern | Owner |
|---|---|
| Agent runtime / panes | `driver.sh` / `HERD_DRIVER` |
| Tracker claim / state | backends + `herd-claim.sh` (coordinator-owned) |
| Health command definition | `HEALTHCHECK_CMD` / project healthcheck |
| Review checklist content | `REVIEW_CHECKLIST` |
| Merge *policy* (auto/approve/observe) | `merge-policy.sh` — applies to any unit's apply decision |
| Pipeline steps | `steps.sh` seams rename conceptually to pre-apply / post-apply over time |

---

## 3. Second implementation sketch: `doc-apply` (and `config-apply` sibling)

### 3.1 Why `doc-apply` first

A second kind must **prove the interface without forking the safety model**. Constraints:

1. Still durable and audit-friendly.
2. Does not require inventing a non-git remote on day one.
3. Exercises open → gate → apply → reconcile → teardown with **different** artifact semantics than a PR.
4. Low blast radius if wrong (docs are the softest landing surface in this repo).

**`doc-apply`**: a work unit whose delivery is "apply a documentation change set onto the default branch (or a docs publish target) **without** opening a GitHub PR," while still running health + review gates against the isolated worktree.

This is deliberately adjacent to paths the engine already special-cases:

- post-merge codemap / symbol-index refresh commits **straight to the default branch** with no PR (`agent-watch.sh:2853-2857`, `:3232-3239`),
- scribe commits backlog edits on its own path,
- `DOCS_ONLY_GLOB` already exists as a risk/classification lever.

### 3.2 Lifecycle (concrete)

```text
1. open
   - Builder finishes in worktree (same lane isolation as today).
   - Instead of `gh pr create`, writes:
       $WORKTREES_DIR/<slug>.unit.json
         { "kind":"doc-apply", "slug":"…", "revision":"<headsha>",
           "item_ref":"HERD-…"|null, "paths":["docs/…"], "title":"…",
           "body":"…\nRefs: HERD-…\n", "opened_at":… }
   - unit_id = "doc:<slug>:<shortsha>" (or content-addressed hash of manifest).
   - Optional: also write a HUMAN-VERIFY / Refs block into the manifest body
     (same markers human-verify.sh already parses — feed body text, not gh).

2. list_open / inspect
   - Watcher globs `*.unit.json` with kind=doc-apply and state!=applied|reaped.
   - revision = manifest.revision (re-read worktree HEAD; refuse if diverged).

3. gate
   - healthcheck.sh <worktree> (same).
   - herd-review.sh --local <slug>  OR a shared "review this diff" entrypoint
     that already exists for pre-PR review — no gh pr diff.
   - Holds: HUMAN-VERIFY from manifest body; MERGE_POLICY-equivalent APPLY_POLICY
     (auto|approve|observe) reused from merge-policy.sh with rename-later alias.
   - Kind-specific: path allowlist (only docs/** or DOCS_ONLY_GLOB); refuse if
     non-doc paths present (fail closed).

4. apply
   - On the main checkout: fetch worktree commits for allowed paths only
     (e.g. `git checkout <revision> -- <paths>` or format-patch | am scoped),
     commit on default branch with message carrying unit_id + Refs,
     push ff-only (never force) — same posture as codemap refresh.
   - Record apply in a unit ledger (generic $STATE analogue):
       <epoch> <unit_id> <slug> <revision> [item_ref]
   - At-most-once: refuse if unit_id already applied.

5. reconcile
   - Read item_ref from manifest (or Refs: in body) → _reconcile_via_ref
     (already PR-agnostic once given a ref!).
   - Else fuzzy scribe: "Reconcile: unit doc:… (worktree <slug>) applied — …".

6. teardown
   - Same _reap_slug mechanics; journal unit_id instead of/in addition to pr.
```

### 3.3 `config-apply` (sibling, later)

Same adapter shape; gate path allowlist is config surfaces (e.g. `.herd/config` keys that are code-shaped and committed, `templates/`, posture files). **Stricter** than doc-apply:

- require `APPLY_POLICY=approve` by default for config kind,
- never touch `.herd/secrets`,
- optionally require a second review tier (`REVIEW_ESCALATE_GLOB` already exists).

Shipping doc-apply first keeps the second implementation a **proof**, not a security redesign.

### 3.4 What this proves about the interface

| Interface requirement | How doc-apply stresses it |
|---|---|
| open ≠ git host | Manifest file, no `gh pr create` |
| list_open ≠ `gh pr list` | Filesystem registry |
| gate without PR number | `--local` review + worktree health |
| apply ≠ `gh pr merge` | Scoped checkout/commit on default branch |
| reconcile without PR body | Manifest carries Refs / item_ref (reuse `_reconcile_via_ref`) |
| teardown without MERGED PR state | Unit ledger + worktree presence |
| forensics without `--pr` | `unit` field in journal |

### 3.5 Explicit non-goals for the second kind

- Not a substitute for branch protection on **code** paths — code stays `git-pr`.
- Not multi-host (GitLab/Gerrit) — that's another adapter (`git-mr`, …), not doc-apply.
- Not "skip review for docs" — review still runs; only the **vehicle** changes.
- Not coordinator auto-choice from path heuristics in v1 — spawn sets the kind.

---

## 4. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Accidental behavior change on git-pr path** while factoring | Critical | Phase 0–1 are docs + façade only; adapter body is move-only; hermetic suite + sandbox sim must stay green; default `WORK_UNIT_KIND=git-pr` |
| **Double-apply / missed teardown** if apply and unit ledger disagree | Critical | Keep today's order: record apply **first**, then hooks, then teardown; startup sweep generalized from `_startup_reap_sweep` |
| **doc-apply bypasses branch protection** | High | Path allowlist fail-closed; never apply non-doc paths; code always `git-pr`; optional server-side rules later |
| **Ledger / journal schema drift** (`pr` vs `unit`) | High | Dual-write `pr` + `unit` during migration; `--pr` remains alias; no reader requires `unit` until phase 3 |
| **Reviewer / cost fingerprints key on "PR #"** | Medium | Cost fingerprint already moved off `PR #` (`cost.sh:35-36`); review prompts parameterize "unit under review" |
| **Spawn deps `after=<pr#>`** | Medium | Accept `after=<unit_id>` and keep numeric PR as git-pr shorthand |
| **Operator UX confusion** (approve by unit id) | Medium | `herd-approve.sh` accepts unit id; git-pr units still accept bare numbers |
| **Premature abstraction** (YAGNI) | Medium | Ship interface only when second kind is scheduled; this spike is the decision record, not a green light to factor everything |
| **Scribe fuzzy match** still PR-worded | Low | Template string becomes "unit … applied/merged"; fuzzy path remains best-effort |
| **Fleet / multi-seat** assumptions about PR authors | Medium | Team-mode author filter becomes kind-specific inspector field (`author` / `opener`) |

---

## 5. Phased migration (git-PR path stays byte-identical)

Principle: **each phase is shippable alone; default config yields today's behavior bit-for-bit on the git-pr path** (same `gh` argv, same ledger line formats, same journal keys until an explicit dual-write phase).

### Phase 0 — this spike (docs only) ✅

- Land `docs/spikes/work-unit-abstraction.md` (this file).
- No engine changes. No config keys. No capabilities row required beyond docs.

### Phase 1 — name the spine (façade, no new kind)

**Goal:** call sites can say `work_unit_*` while still only implementing git-pr.

1. Add `scripts/herd/work-unit.sh` (sourced) defining:
   - `work_unit_list_open`, `work_unit_inspect`, `work_unit_gate_step`, `work_unit_apply`, `work_unit_reconcile`, `work_unit_teardown`
   - default implementation: thin wrappers around existing functions / `gh pr …`
2. Optionally route **new** call sites through the façade; leave `do_merge` body in place.
3. Tests: existing hermetic suite green; no new behavior.
4. **Byte-identical guarantee:** wrappers pass argv through; no new config.

### Phase 2 — generic unit id in journals (dual-write)

1. On merge/apply/reap/review events: write `unit="pr:<n>"` **and** keep `pr=<n>`.
2. `herd why` / `log` / `cost` / `stats`: accept `--unit` and keep `--pr` as alias.
3. Ledgers: either keep `<pr#>` lines for git-pr **or** dual-key with a version tag; prefer **keep format** for git-pr rows so startup sweeps stay compatible.
4. Tests: journal readers; alias CLI.

### Phase 3 — extract git-pr adapter module

1. Move `gh pr list/view/diff/merge/comment` usage from `agent-watch.sh` into `scripts/herd/work-units/git-pr.sh` (or similar).
2. Watcher tick becomes: `units = work_unit_list_open` → per-unit gate/apply.
3. **Acceptance:** sandbox sim + full suite; dogfood on herdkit with `WORK_UNIT_KIND=git-pr` only; compare merge ledger and `gh` traffic samples if needed.
4. Still **no** second kind enabled by default.

### Phase 4 — ship `doc-apply` behind opt-in

1. Implement `scripts/herd/work-units/doc-apply.sh`.
2. Lane rule text: when `HERD_WORK_UNIT_KIND=doc-apply` (or project default), builder opens a unit manifest instead of `gh pr create`.
3. Capabilities + conformance rows for the new kind and config key.
4. Dogfood: a real docs-only backlog item through doc-apply on a throwaway branch/project.
5. HUMAN-VERIFY any live smoke the suite cannot cover.

### Phase 5 — optional renames / cleanup

1. Rename operator-facing "merge" copy to "apply" where kind-neutral (console, merge-policy alias `APPLY_POLICY`).
2. Drop dual-write only after one full release of dual-read.
3. Consider `config-apply` and non-git kinds as separate tracker items.

### Phase ordering rationale

```text
docs → façade → dual-write forensics → extract adapter → second kind → cleanup
```

Extracting **before** dual-write risks breaking `herd why` mid-refactor. Shipping a second kind **before** the façade invites a parallel copy of `do_merge`. Cleanup last avoids forcing operators onto new vocabulary early.

### Byte-identical checklist (every phase that touches engine code)

- [ ] Default config / unset `WORK_UNIT_KIND` → git-pr only  
- [ ] `gh pr merge` argv unchanged (method flag, delete-branch, `--match-head-commit`)  
- [ ] `$STATE` / review / reconcile ledger line formats unchanged for pure git-pr traffic  
- [ ] Builder prompt for default projects still ends in `gh pr create`  
- [ ] Hermetic suite + sandbox sim green  
- [ ] No tracker-state writes from builders (coordinator ownership invariant)

---

## 6. Decision record

| Decision | Choice | Why |
|---|---|---|
| Abstract delivery, not runtime | Work-unit interface separate from `HERD_DRIVER` | Driver already covers mux/agent; delivery is the remaining hard-code |
| Keep tracker backends out of work-unit | Reuse `item_ref` + `_reconcile_via_ref` | Items and deliveries are different lifetimes |
| Second kind = doc-apply | Soft surface, reuses local review + direct-commit posture | Proves interface without multi-host or secrets risk |
| Migration = façade first | Avoid big-bang rewrite of `agent-watch.sh` (~7.5k lines) | Risk is concentrated in one file today |
| git-pr remains default forever-shaped | Coding path stays first-class | North star still includes merged verified code |

### Open questions (not blocking this spike)

1. Should `unit_id` for git-pr be bare `123` or namespaced `pr:123` in ledgers? (Recommendation: namespaced in journal; bare still accepted on CLI.)
2. Does observe/approve policy rename to apply-policy in the same release as phase 5, or keep `MERGE_POLICY` as eternal alias?
3. Fleet rollup: per-kind counters or a single "units applied" metric?
4. Is there a third kind needed before multi-host (`git-mr`), or does host variance stay inside `git-pr` via `gh` vs glab adapters?

---

## 7. Verification of this document

Self-consistency checks performed while writing:

- Every inventory row cites an existing path under `scripts/herd/`, `bin/herd`, or `docs/`.
- Interface ops map 1:1 onto today's open → gate → merge → reconcile → reap spine (`agent-watch.sh` tick + `do_merge`).
- Second implementation reuses existing portable pieces (`herd-review.sh --local`, `_reconcile_via_ref`, codemap direct-commit posture) rather than inventing parallel gate machinery.
- Phased plan states an explicit byte-identical default at every engine-touching phase.
- No engine code is modified by the PR that lands this file.

Spot-check protocol for reviewers:

```bash
# pick any citation from §1, e.g.:
sed -n '3147,3196p' scripts/herd/agent-watch.sh   # do_merge / gh pr merge
sed -n '6928,6933p' scripts/herd/agent-watch.sh   # gh pr list tick
sed -n '160,176p'   scripts/herd/herd-feature.sh   # PR_CREATE_CMD
sed -n '389,425p'   scripts/herd/cost.sh           # cost_emit_merge pr key
sed -n '5185,5189p' bin/herd                       # herd why <pr#>
```

---

## 8. References

- Tracker: **HERD-163**
- Related seams already shipped: `docs/driver-abstraction.md` (runtime), tracker backends under `scripts/herd/backends/`, `docs/NORTHSTAR.md`, `docs/positioning-thesis.md`
- Engine map: `docs/codemap.md` (regenerate with `herd codemap` if stale after later code changes)

---

## 9. Post-port amendment (HERD-403, 2026-07-19)

**Status:** design amendment, landed alongside a python interface SKELETON (this PR). Supersedes
none of §§1–8 as history — the bash inventory above is still an accurate description of the bash
tree — but corrects where **production** delivery actually runs today, and re-targets Phase 4.

### 9.0 The finding this amendment is built on

Phases 0, 1, 2, 3 and 3b of §5 all landed as designed, **on the bash side**: the spike (HERD-163),
the `wunit_*` façade (HERD-396, `scripts/herd/work-unit.sh`), the journal dual-write (HERD-397), the
git-pr adapter extraction (HERD-398, `scripts/herd/work-units/git-pr.sh`), and the tick's
reconcile/teardown call sites rewired through the façade (HERD-401). Every one of those PRs is real,
tested, and byte-identical-by-construction, exactly as designed.

But **in parallel**, a separate epic (HERD-300, the engine port; finale HERD-306) replaced the bash
watcher's own tick loop with a Python core, `pysrc/herd/live_runtime.py`. By the time HERD-401 went
looking for a production call site to rewire `do_merge` through the façade, there wasn't one: HERD-306
had already deleted the bash tick's action pass (`_tick_act`) that used to walk merge candidates and
call `do_merge`. `LiveActuator` (`live_runtime.py:1686`) independently reimplements merge/reap via its
own `gh pr merge` / `git worktree remove` subprocess calls — it does not shell out to bash's
`do_merge` at all. This is the filed finding (`herd note`, HERD-401's commit message) that this
amendment writes down formally: **the live work-unit seam is the Python engine; the bash `wunit_*`
façade + git-pr adapter are the sim-exercised reference model**, not the production path.

### 9.1 Where the live seams actually are

| Spike §2.2 op | Live (production) implementation | Reference model (bash, still real, no longer live) |
|---|---|---|
| discovery / `list_open` | `discover_via_graphql` (`live_runtime.py:1045`) — ONE batched GraphQL round-trip, wrapped by `_GraphQLDiscovery` (`:1228`) | `wunit_list_open` → `gh pr list` (`work-unit.sh`) |
| gate | `LiveGates` (`live_runtime.py:1244`) — `.health()` / `.review()`, the ASYNC dispatch/collect rails; these still SHELL OUT to the same bash leaf scripts (`healthcheck.sh`, `herd-review.sh`) — "Python replaces the loop, bash leaves stay leaves" (module docstring) | `wunit_gate` → `_cand_gates_ready` (`work-unit.sh`) |
| apply | `LiveActuator.merge` (`live_runtime.py:1703`) — `gh pr merge`, verified via `gh pr view --json state` (never trusts the merge command's own exit code, HERD-352) | `wunit_apply` → `do_merge` (`work-unit.sh`) — **zero production call sites** (HERD-401 finding) |
| the refix-bounce prompts | `LiveTick._refix_prompt` (`live_runtime.py:1989`) — the re-task text typed into a builder's pane on a health/review bounce, plus `LiveActuator.wake_builder`'s real pane-wake verification (`:1850`) | bash's own refix prompt strings (`agent-watch.sh`, pre-port) — same text, no longer the live sender |
| reconcile | **bash**, still: `agent-watch.sh`'s `_pms_reconcile_one` (`:7618`) calls `wunit_reconcile` → `reconcile_backlog` (`:7724`) for every merge, regardless of which engine actuated it | same — this leg never moved |
| teardown | **bash**, still: `_pms_reconcile_one` (`:7726`) and `_startup_reap_sweep` (`:6876`, call at `:6926`) call `wunit_teardown` → `_reap_slug` | same — this leg never moved, and `LiveActuator.reap`'s own docstring says why: the cross-seat reap authority is deliberately the bash sweep, not the actuator that merged |

In short: **discovery, gate, and apply crossed to Python; reconcile and teardown stay in bash**,
because they are POST-MERGE sweep concerns that must fire identically whichever engine (bash or
Python, on whichever seat) performed the merge — `_pms_reconcile_one` and `_startup_reap_sweep` are
the one shared place that watches "is this PR merged yet" and cleans up, and HERD-401 already routed
both through the `wunit_*` names. The gate DAG's *leaves* (the health/review rails) did not move
either, in the sense that matters for this spike: they are still `healthcheck.sh` / `herd-review.sh`,
bash scripts, dispatched now by a Python caller instead of a bash one — "leaves stay leaves" holds
across the port, not just within it.

### 9.2 The python-side WorkUnit adapter interface (this PR's skeleton)

`pysrc/herd/work_unit.py` lands the interface's Python half, mirroring the bash façade's own shape
(`WorkUnitAdapter` base + one concrete adapter, spike §2.2's five ops + two queries) rather than
inventing a different vocabulary:

- **Shared types** (§2.2), as plain `__slots__` classes (matching `live_runtime.py`'s own
  `LiveCandidate`/`WakeResult` convention, not `@dataclass` — no new style for one module):
  `WorkUnit` (`unit_id`, `kind`, `slug`, `revision`, `item_ref`, `artifact`), `GateResult` (`status`
  ∈ `pass|hold|block|wait|error`, `reason`, `holds`, `evidence`), `ApplyResult` (`status` ∈
  `applied|refused|already|error`, `reason`).
- **`WorkUnitAdapter`** — the base class. Every op raises `NotImplementedError`, named with the op
  and the adapter's own kind, so a half-built adapter fails loud instead of silently no-op-ing.
- **`GitPrAdapter(WorkUnitAdapter)`**, `kind = "git-pr"` — WRAPS the existing pieces from §9.1,
  reimplementing none of them:
  - `list_open` → one-line delegation to `_GraphQLDiscovery(config, repo).discover()`.
  - `inspect` → the candidate `list_open` already produced (the batched GraphQL query bundles every
    inspect-shaped field into the same round-trip; there is no separate git-pr fetch to wrap).
  - `gate` → composes `LiveGates.health` + `.review` into one `GateResult` (rail readiness only —
    the merge-POLICY holds stay in `herd.decisions`, reused verbatim, per §2.4).
  - `apply` → one-line delegation to `LiveActuator.merge`.
  - `open`, `reconcile`, `teardown` → deliberately **NOT implemented** (`NotImplementedError`, each
    docstring naming why): `open` is a builder-lane concern (`gh pr create`) the watcher engine core
    never performed even in bash; `reconcile`/`teardown` are §9.1's bash-owned legs — there is no
    existing Python code path to wrap yet, and this skeleton does not invent one.
  - Every collaborator (`gates`, `actuator`, `discovery`) is constructor-injectable, the same
    Live\*/Fixture\* seam `LiveTick` already offers, so a caller — or a test — can hand the adapter
    `FixtureGates`/`DryRunActuator` instead of the real, subprocess-shelling live pieces.
- **`resolve_adapter(kind=None, **kwargs)`** — how `WORK_UNIT_KIND` selects the adapter in Python:
  explicit `kind` arg, else `kwargs["config"]["WORK_UNIT_KIND"]` (the same config dict
  `live_runtime._config_from_env` assembles — extended by this PR to carry the key through, inertly),
  else the `WORK_UNIT_KIND` env var, else `"git-pr"`. An unsupported kind is a **hard refusal**
  (`UnsupportedWorkUnitKind`), mirroring `wunit_resolve_adapter`'s own hard-refusal contract — not
  `agent-watch.sh`'s boot-time SOFT fallback (which protects the resident bash watcher process from
  dying over a config typo; this module has no resident process to protect, so it refuses loudly
  instead of quietly substituting a different adapter than the one asked for).

**This is a skeleton, not a wired call site.** Nothing in `live_runtime.py` imports or calls
`herd.work_unit` — `LiveTick` still talks to `_GraphQLDiscovery`/`LiveGates`/`LiveActuator` directly,
by name, exactly as before this file existed. Landing it changes no observable behavior (the
byte-identical checklist, §5, holds): the one one-line addition to `live_runtime.py` itself (carrying
`WORK_UNIT_KIND` into the assembled config dict) is inert until something reads that key, and nothing
does yet.

### 9.3 Bash `wunit_*` remains the reference model — the conformance tie

The bash façade (`scripts/herd/work-unit.sh`, `scripts/herd/work-units/git-pr.sh`) is not being
retired or deprecated by this amendment. It stays the **reference model** the spike's interface was
designed against: it is exercised live by the sandbox sim scenario suite
(`scripts/herd/sim/sandbox-*.sh`) and by the hermetic bash tests (`tests/test-work-unit.sh`,
`tests/test-work-unit-kind.sh`, and the rest of the HERD-401 verification list), so the interface's
SEMANTICS — what "gate", "apply", "reconcile", "teardown" mean, and how a kind gets resolved — stay
proven even though production traffic no longer flows through `do_merge`.

The **conformance tie** keeping the two implementations semantically paired, so they can never
silently drift onto different definitions of "supported kind": `templates/conformance.tsv`'s
`WORK_UNIT_KIND` row points at `tests/test-work-unit-kind.sh` on the bash side; this PR's
`tests/test_live_runtime.py` adapter-resolution tests are the Python-side half of that SAME tie —
both assert the identical resolution contract (default `git-pr`; anything else is a **hard**,
loud refusal, never a silent fallback to a different kind). A future kind that ships on one side
without an equivalent assertion on the other is exactly the drift this pairing is meant to catch;
`WORK_UNIT_KIND`'s `templates/capabilities.tsv` row (already registered, HERD-398) needs no new row
for this PR — it still describes the one kind either engine implements.

### 9.4 Phase 4 (`doc-apply`), re-planned for the python engine

**SHIPPED as PR #511 (HERD-399), per the re-plan below** — `DocApplyAdapter` landed as a sibling class
in `pysrc/herd/work_unit.py` (not a separate `doc_apply.py`; the module never grew large enough to
warrant the split), registered in `work_unit._ADAPTERS` next to `git-pr`, proven by
`tests/test_live_runtime.py`'s hermetic `TestDocApplyAdapter` suite (no sim scenario script was
needed — the existing `unittest` rig covered it), with capabilities.tsv + conformance.tsv rows added
in that same PR (`herd.work_unit.DocApplyAdapter`, `<slug>.unit.json`, `DOC_APPLY_PATH_GLOB`). The
plan below is left as written — it is an accurate account of what was decided and then built.

§5's original Phase 4 planned `scripts/herd/work-units/doc-apply.sh` — a second BASH adapter,
because at spike-writing time bash was the only engine. That target is now wrong: building a bash
`doc-apply` rail would create a second reference-model-only adapter nobody actuates, mirroring
`git-pr`'s own post-port fate before it ships. The re-plan:

1. A real `doc-apply` kind is a Python adapter — `DocApplyAdapter(WorkUnitAdapter)` (a sibling class
   in `work_unit.py`, or its own `pysrc/herd/work_units/doc_apply.py` if it grows large), registered
   in `work_unit._ADAPTERS` next to `git-pr`, following §3.2's lifecycle (manifest-based `open`,
   filesystem-glob `list_open`, path-allowlisted `gate`, scoped-checkout `apply` onto the default
   branch — no `gh pr create` anywhere in the chain).
2. **Proof is a sim scenario**, reusing the SAME hermetic rig `LiveTick` already has
   (`FixtureDiscovery`/`FixtureGates`/`DryRunActuator`) rather than a new bash sim script — a
   `doc-apply` scenario dict drives `resolve_adapter("doc-apply", …)` through open → gate → apply →
   (reconcile/teardown remain bash's job, §9.1) exactly as `tests/test_live_runtime.py` already
   drives the git-pr gate DAG hermetically, no `gh`/`git`/pane ever invoked.
3. Capabilities + conformance rows are still required at that point (a real second kind, a real new
   `WORK_UNIT_KIND=doc-apply` value) — this PR adds neither, because it ships no second kind, only
   the interface + the one already-registered kind.
4. `git-pr` stays default and stays first-class; `doc-apply` is additive, opt-in, and — per §3.5 —
   still not a coordinator auto-choice from path heuristics.

### 9.5 What did not change

- The decision record (§6), the risk table (§4), and §§1–3's inventory stand as an accurate account
  of the bash tree at the time each was written.
- `WORK_UNIT_KIND` default (`git-pr`) and its bash boot-time soft-fallback behavior are unchanged.
- No capabilities/conformance rows are added by this PR (§9.2's skeleton adds no `cmd_*`, no config
  key, no `scripts/herd/*.sh` file — `WORK_UNIT_KIND` was already registered by HERD-398).

---

## 10. Phase-completion table — epic closure (HERD-404, P5)

The epic (HERD-395) is CLOSED as of this PR. Every phase below shipped exactly the scope its own PR
description claims; nothing here was reverted or re-planned away except doc-apply's vehicle (bash →
python, §9.4).

| Phase | PR | Tracker | What shipped |
|---|---|---|---|
| P1 | #505 | HERD-396 | Named the spine: `scripts/herd/work-unit.sh`'s `wunit_*` façade, git-pr only, every wrapper a one-line delegation — byte-identical, no caller switched over. |
| P2 | #507 | HERD-397 | Journal dual-write: every `pr`-carrying event also gets an additive `unit="git-pr:<n>"` field (`journal.sh` / `shadow_journal.py`), so a future reader can key on `unit` without breaking `--pr`. |
| P3 | #508 | HERD-398 | Extracted the git-pr adapter body out of `agent-watch.sh` into `scripts/herd/work-units/git-pr.sh` — a pure move, same function names, zero behavior change. |
| P3b | #509 | HERD-401 | Rewired the watcher tick's reconcile/teardown call sites through the `wunit_*` facade; filed the finding this whole §9 amendment is built on — `do_merge`/`wunit_apply` had zero production call sites left, because HERD-306 (engine port) had already deleted the bash action pass that used to call it. |
| P3c | #510 | HERD-403 | Landed the python-side `WorkUnitAdapter` interface skeleton (`pysrc/herd/work_unit.py`) — `GitPrAdapter` wrapping the live engine's discovery/gates/actuator pieces; the §9 post-port amendment (this doc) documenting where the live seam actually is. |
| P4 | #511 | HERD-399 | Shipped `doc-apply` — a real second kind, python-only, manifest-driven (`<slug>.unit.json`), gated by the `_safe_manifest_path` accepted-input invariant; opt-in via `WORK_UNIT_KIND=doc-apply`. |
| P5 | this PR | HERD-404 | Epic closure: the bash/python conformance tie (`tests/test-work-unit-conformance.sh`) the P3c amendment promised (§9.3); reference-model-only markings on every `wunit_*` wrapper that has no live call site; retired stale "P4 adds a second kind" phase language now that P4 shipped; `docs/capabilities-overview.md` + this doc's status header brought to the shipped state; this table. |

**Byte-identical-by-construction holds across every phase**: P1–P3c never switched a production caller
onto the bash facade (P3b's own finding is that there was no live caller left to switch), and P4's
`doc-apply` is strictly opt-in (no manifest on disk → `list_open` returns `[]`, nothing about the
`git-pr` path is touched). The sim scenario suite (`scripts/herd/sim/sandbox-scenario.sh`,
`sandbox-concurrency-scenario.sh`) and the hermetic bash + python test suites stay green with
`WORK_UNIT_KIND` unset, proving the default git-pr pipeline never moved.

---

*End of spike. Implementation, if approved, starts at Phase 1 under a new tracker item — not as a silent follow-on in this PR.* Post-port amendment §9 (HERD-403) landed alongside the Python interface skeleton it describes, per that item's own task spec — not a silent follow-on either. Phase-completion table (§10, HERD-404) closes the epic — also per that item's own task spec, not a silent follow-on.
