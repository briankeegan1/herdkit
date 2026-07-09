<!-- Provenance: coordinator deep-audit agent, 2026-07-09. Committed verbatim as durable evidence. -->

> **Date:** 2026-07-09
> **Provenance:** produced by the herdkit coordinator's deep-audit agent, grounding every claim
> against live code (`file:line`) or journal lines on main `9905138`.
> **Program:** evidence base for the **HERD-240** gating-hardening epic on Linear (HERD team);
> the items it proposes (N1–N12) and amendments (A1–A9) are tracked as children of that epic.
>
> The body below is the audit as delivered, unedited.

---

# Gating & Lifecycle Hardening Audit — 2026-07-09

Scope: the gate/merge/lifecycle engine (`scripts/herd/agent-watch.sh` @ 7706 lines on main `9905138`, plus `herd-review.sh`, `herd-resolve.sh`, `healthcheck.sh`, `stale-dup-gate.sh`), the multi-seat doctrine, the sim/conformance rigs, the live Linear backlog, and today's journal. Every claim below was verified against live code (file:line) or journal lines — not the incident narration.

Layer vocabulary: the doctrine doc (`docs/multi-seat-doctrine.md`) formalizes two rules — **R1: reconciled invariants over event side-effects** ("does this hold regardless of which seat performed the triggering event?") and **R2: one shared deterministic check at every enforcement surface**. The audit uses the operator's three-layer lens on top: **prevent** (gate refuses the bad state), **display** (console/journal tells the truth about it), **reconcile** (a per-tick invariant repairs it no matter which seat/event caused it).

---

## 1. Executive summary

The engine's per-gate machinery is individually strong (sha-keyed verdicts, corpse sweeps, positive-evidence liveness, record-first idempotency), but the afternoon's 8 hand-nudges all trace to **four structural classes**, only two of which are fully covered by filed items:

1. **Gate ordering is inverted** (uncovered). The cheap, deterministic stale-base/duplicate gate runs LAST — after a full heavy healthcheck completes and after the parallel review pre-dispatch fires (`agent-watch.sh:7328` review kick → `7336` health → `7411` stale-dup). Today's journal shows the exact burn: PR #328 `healthcheck_started 14:23:57` → `CLEAN 14:26:22` → `stale_dup_hold 14:26:24` → bounce → new sha → repeat. Every stale-base cycle wastes one ~9-min heavy suite + one Opus review that is doomed the moment the bounce fires. The reviewer additionally reads the **live** diff (`gh pr diff <PR>`, `herd-review.sh:434,441,493`) while its verdict is keyed to the dispatch-time sha — provenance is muddy on any mid-review push.
2. **Budgets and fairness have no per-rail / no-progress semantics** (uncovered). `refix_round_count` deliberately shares one per-PR budget across review/health/stale rails (`agent-watch.sh:3880-3885`); PR #328 spent rounds 1-3 on three *different* first-time failures, then a genuinely new review BLOCK found the budget empty. Nothing guarantees a gates-passed PR eventually merges under multi-seat merge pressure (three conflict/stale cycles in 90 min on #328); there is no ready-PR priority, no merge-queue, no starvation counter.
3. **The tab-leak-guard infra exemption swallows every bats red at BOTH surfaces** (only half-covered). Main-health side: `agent-watch.sh:3160-3164` + `:3271-3273` (covered by HERD-222). Gate side: `:6043-6044` classifies any log containing the *passing* `ok N ... tab-leak-guard` line as the exemption, and `:6148-6151` then refuses to sha-cache it → an **unbounded per-tick re-dispatch loop** with no bounce and no escalation (the PR #333 loop). No filed item covers the gate side or bounds infra re-dispatch. This is an R2 violation: the same exemption logic is duplicated, differently wrong, at two surfaces.
4. **Seat-local state is the default substrate** (uncovered as a class). Every dedup/budget/hold ledger lives under this seat's `$TREES` (refix rounds, stale-dup noted, approval awaiting, resolver dispatch counts, review retries, breaker). The only cross-seat-shared gate artifact is the `herd/gates` commit status (HERD-194). Two coordinator seats today would double-comment holds, double-spend budgets, race resolvers onto the same PR from two worktrees, and hold/approve independently. The doctrine calls seat-local state a correctness defect; the engine has one shared primitive and ~a dozen seat-local ones.

Plus one meta-finding: **HERD-223's guard did not stop the pollution** — today's live journal still carries fixture `retire_*`/`reap` events for fake slugs (`retiree`, `conv`, `stuck`, `hd`, 13:51–14:35Z), emitted by PR #328's worktree suite runs (the branch predates the #337 guard and `retirement` events are a new family). Hermeticity needs a reconcile layer (a journal lint), not only a prevent layer.

Counts: **12 proposed new backlog items** (N1–N12), **9 amendments to existing items** (A1–A9), 2 doc-drift fixes.

---

## 2. Coverage matrix — the 12 incidents

Legend: ✅ covered (landed or filed), 🚧 filed-not-built, ❌ missing.

| # | Incident | Evidence (verified) | Item(s) | Prevent | Display | Reconcile | What's missing |
|---|---|---|---|---|---|---|---|
| 1 | `do_merge` misread nonzero `gh pr merge` as sha-moved; 17 MERGED PRs skipped all post-merge hooks | Fix live at `agent-watch.sh:3315-3331` (re-check `state==MERGED`) | HERD-221 (merged #338) | ✅ | ⚠️ `merge_refused_sha_moved` is also journaled when `gh pr view` itself fails (`:3322-3324`) — dishonest label on a gh outage | ❌ | No reconciler replays post-merge hooks for a PR that merged **without** this seat's do_merge (foreign merge, crash, the 17-PR backlog). `_startup_reap_sweep` (`:3435`) covers only worktree teardown, only at startup. → New item N6. |
| 2 | Main-health tick is seat/event-local; killed tick lost; 19h stale MAIN RED; label named a passing test | `main_health_tick` called only from `do_merge` (`:3379`); no-slot defers "until a later **merge** tick" (`:3240`); mislabel at `:3160-3164` (grep matches a *passing* `ok N tab-leak-guard` line) routed to infra at `:3271-3273` | HERD-222 (filed) | 🚧 | 🚧 (honest labels in scope) | 🚧 (per-tick reconcile in scope) | HERD-222 must also cover: re-dispatch from the **tick** when the current main sha has no marker (not only from the next merge), and the no-slot deferral path. Amend A1. |
| 3 | tab-leak-guard exemption swallows ALL bats reds; gate side = endless re-dispatch on #333 | Main-health: `:3160-3164`, `:3271-3273`. Gate: `_health_worker:6043-6044` + never-cache `:6148-6151` → re-dispatch every tick, no cap, no bounce (autofix explicitly skips it, `:4299-4300`) | HERD-222 covers main-health **only** | ❌ gate side | ❌ (row says transient forever) | ❌ | New item N2: exemption must match only a **failing** line (`not ok .* tab-leak-guard`), shared helper at both surfaces (R2); plus a bounded infra re-dispatch budget → needs-you. |
| 4 | Test fixtures write into the real journal | Guard landed: `journal.sh:58-64` (HERD-223, #337). **Still leaking**: live journal 13:51–14:35Z today carries `retire_converged/retire_hold/reap` for fixture slugs (`retiree`, `conv`, `stuck`, `hd`, PR #77/#18/#19/#20/#23) from PR #328's worktree suite runs; `trigger_tick`/`trigger_spawn` fixtures at 13:56Z | HERD-223 (merged #337) | ⚠️ partial | ✅ (visible in `herd log`) | ❌ | Amend A2: (a) PR #328 must rebase onto the guard / its suite must export the hermetic env; (b) add a journal **lint** (reconcile layer): a healthcheck leg that greps the live journal for known-fixture slugs/events — the ratchet that catches the next unguarded suite. |
| 5 | Alive-but-idle resolver blocks re-dispatch forever; no re-task path; hand-typed twice | `_resolver_in_flight:2624-2626` — only DEAD frees; roster presence **at any status** = ALIVE (`:2542-2543`); new-commit path holds while in-flight (`:2730-2733`); the only dispatch primitive is `spawn_resolver:2640` (new tab), no send-into-existing-pane path | HERD-225 (filed) | 🚧 | ❌ row renders "resolving conflict…" indefinitely (`:2704`, `:2731`) | ❌ | Amend A3: HERD-225 should include (a) retire-on-verdict (mirror `_retire_reviewer_pane`, verdict-consumed, `:1949`), (b) a marker-age **deadline** for resolvers (reviews/health have corpse-sweep timeouts, `:6213-6227`; resolvers have none — a hung ALIVE resolver holds forever), (c) a re-task path into an idle resolver pane, (d) honest row ("resolver idle · PR still conflicting"). |
| 6 | Resolver exited on scratch branch `pr328`; branch-name join made the PR invisible → no gates, 'awaiting task' | Join is branch-name-only: `_discover_feature_worktrees` `pr_by_branch.get(branch)` (`:6555`, `:6574`). Resolver task prompt (`herd-resolve.sh:75`) has **no exit contract about branches** — nothing forbids scratch branches or requires restoring the PR branch | HERD-226 (filed) | 🚧 (sha-fallback join) | ❌ (rendered as awaiting-task, i.e. incident 7) | 🚧 (branch auto-repair) | Amend A4: HERD-226 should also amend the resolver/builder task contracts (prevent layer): "work on the PR's branch; never leave the worktree on another branch; restoring the branch is part of DONE". Cheap and closes the source, not just the symptom. |
| 7 | Failed PR lookup renders '💤 awaiting task · assign or retire' | `gh pr list … \|\| echo '[]'` (`:7067`) — a gh outage is indistinguishable from zero PRs; every builder then takes the `-z $prnum` ladder (`:7105-7138`) → 💤 or 💀. No PR-side analog of `_roster_readable` (`:2523`, "blindness is never evidence of death") | HERD-224 (filed) | 🚧 | 🚧 | ❌ | Amend A5: on an unreadable PR fetch, freeze last-known-good `PRS_JSON` (cached) and render a loud "gh unreadable — holding last view" banner; suppress dead-builder **crossings** (not just rows) while PR data is unreadable, mirroring the roster rule. |
| 8 | Parallel-dispatch bounce doomed an in-flight review; reviewer reads live diff vs sha-keyed verdict | Order: `_predispatch_review_if_parallel:7328` → health `:7336` → re-verify `:7355` → stale-dup `:7411`. Journal proof 14:23:56 review_dispatched(8c15d1) → 14:26:25 stale_refix_bounce → 14:29:57 BLOCK(8c15d1, already doomed) → 14:31:43 fresh review. Live-diff reads: `herd-review.sh:434,441,493` | **none** | ❌ | ⚠️ (`_discard_stale_reviews:1596` reaps superseded reviews — after the burn) | ❌ | New items N1 (gate ordering) and N4 (review input pinning). Note: `_discard_stale_reviews` discards, it does not **cancel** — a doomed reviewer runs to completion at full cost; the gate-order DAG (N9) adds supersession-cancel. |
| 9 | One shared refix budget across rails; fresh round-3 BLOCK had no bounce left | Shared-by-design: `refix_round_count:3880-3885` ("review / health / stale-base autofixes SHARE one per-PR budget"); per-kind counter exists (`refix_round_count_kind:3891`) but is used only as escalation evidence (`:4022-4027`), never as the cap. All three handlers cap on the shared count: `:4151` (review), `:4396` (stale), health analog in `_handle_health_codeerror` | **none** | ❌ | ✅ rows show k/cap honestly | ❌ | New item N3: per-(pr,kind) budgets + a higher total cap; reset a kind's budget when that kind subsequently PASSes (progress ≠ failure); "same failure twice" is the loop signal, not "three different failures ever". |
| 10 | Stale-base starvation/livelock under multi-seat merge pressure; 3 cycles in 90 min | No priority/queue anywhere in the candidate loop (`:7279` iterates FEATS discovery order); every other-seat merge re-stales hot PRs; each cycle costs a full heavy suite + review (see #8); delta-review carry-forward exists (`_maybe_carry_forward_review:1229`, HERD-204) but there is **no health analog** — every integration merge re-runs the full suite | **none** | ❌ | ❌ (no "re-staled N times" surfacing) | ❌ | New item N5 (merge fairness + starvation counter); N10 (multi-seat/starvation sim). |
| 11 | MAIN checkout drifted 22 commits; watcher ran stale code; unpushed symbol-index commit diverged | ff-pull inside do_merge (`:3366`) AND per-tick inside `reconcile_map_freshness:3044` — but the per-tick pull is **gated on CODEMAP_AUTOREFRESH** (`:3034-3035`): maps off ⇒ no MAIN freshness reconcile at all. Unpushed commits: `refresh_symbol_index` rebase-retries once (`:2979-2982`) then journals `pushed no` (`:2984`) and **nothing ever retries the push** — the reconcile probe sees a locally-fresh map and memoizes (`:3079-3082`) | HERD-218 (merged #341) — partially | ⚠️ | ⚠️ (`pushed=no` journaled once; today 13:54:43Z) | ⚠️ coupled to codemap lever; no push-retry | New item N7: MAIN-freshness as its own invariant (ff-pull on a cadence regardless of codemap lever; surface behind-by-N; heal `pushed=no` divergence by retrying rebase+push or resetting the regenerable commit — the files are declared regenerable in `derived-files.sh`). |
| 12 | Seat-dependent merge side-effects as a class | do_merge side-effect inventory: `$STATE` row `:3340-3343`, flair `:3348`, `purge_pr_approvals:3353`, `purge_pr_ci_checks:3356`, `cost_emit_merge:3360`, `reconcile_backlog:3364`, ff `:3366`, codemap `:3371`, symbol-index `:3374`, main-health `:3379`, steps `:3384-3387`, `_reap_slug:3392` | HERD-218 ✅ (maps), HERD-222 🚧 (main-health), HERD-164/PR#328 🚧 (reap/retire), `_sweep_tracker_state:3831` ✅ (mark-shipped, ~3 min cadence) | mixed | mixed | mixed | Still event-only (no reconcile for a foreign/cross-seat merge): **approval + CI-ledger purge** (phantom rows accumulate forever), **cost accounting** (rows silently absent), **$STATE "recently landed" row**, **pipeline post-merge steps**, **flair** (cosmetic, fine). → New item N6 (one merged-PR reconcile sweep that closes the whole class). |

---

## 3. Newly found gaps (beyond the incident list), with evidence

### G1 — Gate order burns expensive gates on deterministically-doomed candidates (the full enumeration)
Paths where an expensive dispatch fires before a cheap deterministic decision that can doom the sha:
- **Parallel review before everything**: `_predispatch_review_if_parallel` at `:7328` fires before the health gate (`:7336`), before the pre-merge re-verify (`:7355`), and before stale-dup (`:7411`). Doomed-by-design cases: (i) stale-base autofix bounce (incident 8); (ii) mergeability regressed between list and action (`:7381-7397` — review already dispatched at `candsha`); (iii) health CODEERROR + `HEALTHCHECK_AUTOFIX=on` — the bounce will supersede the sha while the review runs; (iv) sha skew — predispatch uses list-time `candsha` (`:7328`) while the action pass re-verifies `rsha` (`:7355`); a push in between burns a review at a sha the loop will never act on.
- **Heavy healthcheck before stale-dup**: even in default serial mode, `_healthcheck_gate` (`:7336`) runs (and must complete — `RUNNING → continue` at `:7338-7340` means stale-dup is unreachable until the suite lands) before `stale_dup_check` (`:7411`). The stale-base probe is pure git (`stale-dup-gate.sh:20-26` — merge-base + name-only diffs, deterministic, sub-second). Ordering it first saves one full heavy suite per stale cycle. Journal proof in §1.
- **No supersession-cancel**: `_discard_stale_reviews:1596` and `_discard_stale_health:5910` reap *markers* for old shas but the worker processes run to completion (SIGTERM only on the corpse-sweep **timeout** path, `:6213-6227`). A superseding push should terminate in-flight workers for the old sha.

### G2 — Reviewer input is unpinned (diff-at-HEAD, verdict-at-dispatch-sha)
`herd-review.sh` instructs every PR-mode reviewer to `gh pr diff <PR>` (`:434` single, `:441` panel, `:493` agent-mode) — the live head. The verdict is recorded against the dispatch sha (`_review_gate_step:1925,1930`). A push mid-review desynchronizes reviewed-content from verdict-sha; sha-keying discards the verdict (safe) but the burn is real and, worse, a PASS collected just before the discard window can bless content it never read if the push lands between diff-read and verdict-write. Fix: pin the input — `git fetch origin pull/<n>/head` at dispatch, review `git diff <merge-base>..<sha>` from the pinned ref (works headless; `gh pr diff` takes no sha).

### G3 — Stale-base bounce path bypasses the driver seam
The review bounce routes through `herd_driver_send_text` (`:4226,4230`), but the stale-base bounce calls `herdr pane run` directly (`:4461,4465`). Under `HERD_DRIVER=headless` the stale-base autofix silently no-ops (kills HERD-199 in the exact multi-seat/headless posture the operator is heading toward). Belongs to HERD-176/HERD-150 P3-P4 — amend A6.

### G4 — Foreground, untimeouted work inside the tick loop
The tick makes numerous foreground `gh` calls (per-candidate `gh pr view` `:7355`, comments `:7416-7427`, status posts) and launches lanes foreground: `_drain_spawn_queue` runs `herd-feature.sh` synchronously (`:6978-6980`), `spawn_resolver` runs `herd-resolve.sh` synchronously (`:2644-2645`). One hung `gh` or a slow spawn stalls **all** gating (merges, collections, limit-parks) — the whole control room rides one loop with no per-call timeout. Under many seats/agents this is the availability bottleneck. (The exec-hang probe `:1860` guards only `claude`, not `gh`.)

### G5 — Cross-seat: the ledger substrate is seat-local (the full list)
With `WATCHER_SCOPE=all`, gates dedup across seats **only** via the `herd/gates` commit status (`:7309-7313`, `_gate_status_blessed:2095`). Everything else is per-seat `$TREES` state, so two seats watching the same PR each: comment the stale-dup hold once (`stale_dup_held_noted:2222` seat-local), spend independent refix budgets (`$REFIX_STATE`), dispatch **independent resolvers** into their own worktrees for the same CONFLICTING PR (resolver ledgers `:1043-1102` are seat-local; the two resolvers then race on `git push` to the same branch), track approvals independently (`herd approve` on seat A never releases seat B's hold row), and re-run health/review per seat (mitigated for review+health only by the blessing check — but the blessing is posted **after both gates pass**, so two seats duplicate the entire gate run for any PR that isn't green yet). Worse: the ONE mutex that exists (HERD-209's singleton, `:6685-6730`) is same-host-only (`kill -0` + `flock`) — two machines sharing a network-mounted `$TREES` would both adopt the "stale" lock and run concurrently, at which point every un-locked RMW ledger in §5 is live-racy. See §5 inventory. This is the doctrine's named correctness defect, uncovered by any filed item → New item N8 (spike).

### G6 — `merge_refused_sha_moved` mislabels gh outages
`do_merge:3321-3324`: when `gh pr merge` fails AND `gh pr view` also fails (network), state reads `""` ≠ MERGED → journals `merge_refused_sha_moved` though nothing moved. Honest-labels convention (HERD-173 lineage) says name it `merge_gh_unreadable`. One-line fix, fold into N6 or A1.

### G7 — Idle builders consume spawn budget; the row invites the wrong fix
`_drain_spawn_queue` budget = cap − `${#FEATS[@]}` (`:6919`) — FEATS counts idle/awaiting-task and dead builders. Combined with incident 7 (a gh blip renders live builders as 'awaiting task · assign or retire'), the console actively invites retiring a builder the autofix rails need, and spares silently throttle new spawns. Display fix rides HERD-224; the budget semantics (should a 💤 spare count against SPAWN_AHEAD?) deserves one line in HERD-224's scope — amend A5.

### G8 — Main-health no-slot deferral can strand a sha unticked
`main_health_tick:3240`: no free slot → journal + return **without marking**, retried only on the next merge event. Last merge of the day landing during a busy gate window ⇒ that main sha is never health-ticked until the next merge (hours/days). Covered conceptually by HERD-222's reconcile framing — make it explicit (amend A1).

### G9 — Doc/engine drift found while grounding
- `MERGE_POLICY` default: `COORDINATOR-SOP.md:75,312` say default `held`; `control-room-map.md:103` + `capabilities-overview.md:124` say `auto`. TSV is declared source of truth — reconcile the docs.
- `COORDINATOR_WATCHDOG`: `capabilities-overview.md:176-184` says "not yet wired"; it IS wired (`_handle_coordinator_watchdog:5184`, called `:7670`). Update the doc.

---

## 4. Lifecycle contract matrix (HERD-193 lens: owner / deadline / liveness / retire / budget)

| Population | Liveness | Deadline/timeout | Retire-on-done | Respawn budget | Re-task path | Gaps |
|---|---|---|---|---|---|---|
| Builder | ladder + dead-grace (`_classify_dead_builder:5530`), limit-park (`:5045`) | ❌ none — only a stall **warning** row (`:7167-7171`); a builder can spin forever | via merge reap + retirement (PR #328) | 1× autorespawn, work-guarded (`:5654`) | refix bounce (review/health/stale) | no absolute deadline; owner recorded nowhere |
| Reviewer | inflight marker + pid + registry (`:1382,1531`) | ✅ corpse sweep TERMs past family timeout (`:6213-6227`) | ✅ verdict-consumed retire (`:1949`) + startup sweep (`:7035`) | `_REVIEW_RETRY_MAX` | n/a (one-shot) | the model contract — closest to complete |
| Health worker | marker + pid | ✅ corpse sweep | ✅ collect frees slot | implicit via sha-cache | n/a | fine |
| Resolver | positive-evidence verdict (`:2605`), 90s grace | ❌ **no timeout** — a hung-ALIVE resolver holds `_resolver_in_flight` forever (`:2624`) | ❌ no verdict-consumed retire; stale-tab sweep only when PR no longer CONFLICTING (`:3721`) | REFIX_MAX_ROUNDS dispatches | ❌ none (incident 5) | the weakest contract; HERD-225 + A3 |
| Scribe/drainer | linger deadline in `scribe-step.sh:196-224` | partial | ❌ stale wrong-mode drainer is **warned, not retired** (`scribe-step.sh:243-261`, issue #139) | — | — | auto-retire wrong-mode drainers |
| Researcher | none found (`research.sh` — no watcher integration) | ❌ | ❌ | ❌ | ❌ | entirely outside the supervision perimeter |
| Coordinator | watchdog (`:5184`) behind COORDINATOR_WATCHDOG | — | n/a | launch-lock (`:5170`) | — | doc drift (G9) |
| Watcher itself | singleton lock (HERD-209, `:6685`) | — | — | — | — | ✅ as of #334 |

HERD-193 is the right umbrella; amend A7 to enumerate exactly these holes (resolver deadline, researcher supervision, drainer auto-retire, builder absolute deadline as an opt-in knob).

---

## 5. `$TREES` state-file inventory — stale-forever audit

Exhaustive enumeration of every `$TREES/.…` family (writer/reader/purge/keying) is in the Appendix. Scope fact first: `$TREES` is **one directory per project** (`herd-config.sh:120` — `${PROJECT_ROOT}-trees`), shared by every watcher, lane, worker, and manual invocation for that project. The **only mutex in the system** is the watcher singleton lock (`.watcher-<ws>.pid`, `agent-watch.sh:6685-6730`), and it is **same-host-only** (`kill -0` + `flock`) — two seats on two machines (or two checkouts) sharing one `$TREES` are not actually serialized by anything.

Sharpest findings:
1. **Slug-reuse phantom holds** (stale-forever, user-visible): `.agent-watch-push-holds` + `.agent-watch-push-hold-<slug>[.body]` (`push-gate.sh:162-183`) are slug-keyed and never purged on reap/retire — even the in-flight retirement invariant's `_retire_ledger_files` deliberately excludes them. An abandoned hold + later slug-name reuse paints a false `ready · awaiting push approval` row (read at `agent-watch.sh:7096`) on an unrelated new builder.
2. **`.agent-watch-respawn` (DEAD_RESPAWN_STATE) is slug-keyed with no purge path** (`record_respawn:5632`): a reused slug inherits the dead predecessor's spent one-shot respawn budget forever.
3. **Closed-unmerged PRs leak everything**: `purge_pr_approvals`/`purge_pr_ci_checks` fire only inside `do_merge` (`:3353,3356`). A PR closed without merging leaves phantom approval "awaiting" rows plus `.review-escalate-<pr>` (armed, never consumed), `.resolve-result-*`, `.health-cachehit-<pr>`, `.agent-watch-refix-dead/stuck-*`, `.health-result-*` forever — these families are invalidated only by a **newer sha on the same PR**. Closed-PR purge is a missing sweep leg (folded into N6's scope).
4. **Global un-mutexed read-modify-write state**: the INFRA circuit breaker (`_breaker_read/_breaker_write:1697-1708`, a global whole-file RMW that a lost increment corrupts for *every* PR), the codemap reconcile memo (dirty-tree-guarded, not locked), and the per-slug upsert ledgers (`DEAD_STATE:5503`, `LIMIT_STATE:4866`, `SENDKEYS_STATE:4925`, `TRANSCRIPT_STATE:5406` — temp+mv upserts that silently drop a concurrent writer's row). Exactly the shape two seats on one `$TREES` would trigger — input to N8.
5. **One non-atomic cache write**: `.herd-baseline-notok-<sha>` (`healthcheck.sh:179-193`) uses a bare `>` redirect — torn-write-exposed under concurrent health workers.
6. **Self-invalidating (sha-keyed) families are sound**: review/health inflight+result markers, main-health markers — new sha keys fresh files; corpse sweep + `_discard_stale_*` reap the rest. The append-only ledgers ($STATE, REFIX, REVIEW, resolve-attempts) grow forever by design; only REFIX's growth is semantically loaded (incident 9).

---

## 6. Hardening roadmap

### Phase 0 — land what's in flight (this week)
| What | Why | Size |
|---|---|---|
| P0.1 Land PR #328 (HERD-164 retirement invariant) — **after** rebasing onto the #337 journal guard so its suite stops polluting the live journal (evidence §2 row 4) | incident-12 class; stops today's live pollution | S (rebase) |
| P0.2 Verify HERD-209 singleton (#334), HERD-221 (#338), HERD-218 (#341), HERD-220 (#333), HERD-223 (#337) via one full sim pass + `herd conformance report` | regression floor for everything below | S |
| P0.3 File the new items (§7) + amendments (§8) | stop discovering gaps one at a time | S |

### Phase 1 — reconcile-layer completions + cheap reorders (days; all S/M, independent unless noted)
| What | Why (incidents) | Surface | Size |
|---|---|---|---|
| P1.1 = N2 tab-leak-guard exemption fix + bounded infra re-dispatch | #3 (gate side), stops unbounded loops | `agent-watch.sh:6043,6148,3160`; shared helper | S |
| P1.2 = N1 gate reorder: stale-dup before health dispatch & review predispatch | #8, #10 (cost per cycle) | main loop `:7328-7434` | M |
| P1.3 = HERD-222 build (per-tick main-health reconcile + honest labels + no-slot re-attempt) | #2, G8 | `main_health_tick`, tick top | M |
| P1.4 = HERD-224 build + A5 (gh-unreadable ≠ no-PR; frozen last-known-good; dead-crossing suppression) | #7, G7 | `:7067`, discovery, dead ladder | M |
| P1.5 = HERD-225 build + A3 (resolver retire-on-verdict, deadline, re-task, honest row) | #5 | resolver block `:2493-2741` | M |
| P1.6 = HERD-226 build + A4 (sha-fallback join + branch repair + resolver exit contract) | #6 | `:6536-6581`, `herd-resolve.sh:75` | M |
| P1.7 = N6 merged-PR post-merge reconcile sweep (hooks as invariants for foreign/crashed merges; includes G6 label fix) | #1 residue, #12 class | new sweep on tracker cadence | M |
| P1.8 = N7 MAIN-freshness invariant decoupled from codemap lever + pushed=no healing | #11 | `reconcile_map_freshness`, `refresh_symbol_index` | S |
| P1.9 = A2 journal fixture lint (reconcile layer of HERD-223) | #4 | healthcheck leg | S |

### Phase 2 — structural redesigns (1–2 weeks, sequenced)
| What | Why | Depends on | Size |
|---|---|---|---|
| P2.1 = N3 refix budget redesign (per-rail + reset-on-progress) | #9 | P1.2 (order changes what bounces) | M |
| P2.2 = N4 review input pinning (pinned fetch @ dispatch sha) | #8b, G2 | none | M |
| P2.3 = N9 gate-order DAG + supersession-cancel (declare gates with cost class; cancel in-flight expensive work when the sha is superseded) | #8, #10, G1 | P1.2 proves the ordering win first | L |
| P2.4 = N5 merge fairness: ready-PR priority, re-stale starvation counter → auto-priority, optional serialized merge window across candidates | #10 | P2.3 helps but not required | L |
| P2.5 = N8 cross-seat ledger spike: which seat-local ledgers must move to shared substrate (PR labels/statuses/comments vs shared dir); resolver single-flight across seats is the first concrete target | G5 | doctrine; do the spike before building | M (spike) |
| P2.6 = HERD-193 build (supervised-process contract) closing §4's holes; + A6 driver-routed stale bounce (HERD-176) | lifecycle class, G3 | P1.5 | M/L |
| P2.7 = N11 tick-loop availability: timeout-wrapped `gh`, background lane spawns | G4 | none | M |

### Phase 3 — systemic assurance (parallel with late Phase 2)
| What | Why | Size |
|---|---|---|
| P3.1 = N10 multi-seat + starvation sim tier: two real watchers, one shared repo — asserts gate-dedup via blessing, no double-comment, no double-resolver, a gates-passed PR merges within K ticks under merge pressure | proves G5/P2.4/P2.5; extends the existing P1 concurrency scenario | L |
| P3.2 Conformance ratchet extension: every gate/autofix capability row in `templates/capabilities.tsv` must map to a **sim** proof in `templates/conformance.tsv` (today `none-yet` is allowed silently; make `herd conformance report` red on gate-class gaps) — new gates ship with sim proofs by construction | the "stop discovering one at a time" mechanism | M |
| P3.3 = N12 journal-driven self-audit: a cadenced auditor replaying the journal for invariant violations (merge without reap; dispatched without outcome > TTL; bounce without wake_result; red row older than TTL; `pushed=no` without a later `pushed=yes`; fixture events) → operator inbox rows | turns the journal into the gap-finder; catches the *unknown* unknowns | M/L |
| P3.4 Chaos legs: extend the benchmark-drain SIGKILL harness to kill the watcher mid-do_merge, mid-collect, mid-bounce; scorecard asserts the reconcile sweeps converge | proves every Phase-1 reconciler | M |

---

## 7. Proposed new backlog items (SOP: title / GROUNDED / FIX+SURFACE / SEQUENCING / VERIFICATION PLAN / CONVENTIONS / MULTI-SEAT)

### N1 — Gate order: stale-dup decides before health dispatch and review predispatch
- **GROUNDED**: journal 2026-07-09 14:23:57→14:26:24 (PR #328): full heavy suite ran to CLEAN, then `stale_dup_hold` fired and bounced the sha — suite + any parallel review wasted per stale cycle. Order in code: `agent-watch.sh:7328` (review kick) → `:7336` (health) → `:7411` (stale-dup). The stale-base probe is deterministic git (`stale-dup-gate.sh` merge-base + name-only diff).
- **FIX + SURFACE**: in the action pass, run `stale_dup_check` (and the `:7355` re-verify) BEFORE `_predispatch_review_if_parallel` and `_healthcheck_gate`; on hold, `continue` without dispatching either. Keep the once-per-sha comment guard. Surface: `agent-watch.sh` main loop `:7277-7434` only — no gate logic changes.
- **SEQUENCING**: touches the same loop lines as HERD-222/N2 builders will — spawn after P0; conflicts with any in-flight agent-watch.sh PR (check `git worktree list`).
- **VERIFICATION PLAN**: sim — extend `sandbox-concurrency-scenario.sh` with a stale-base candidate; scorecard asserts `healthcheck_started` count == 0 for a sha that stale-holds, and the existing green path is unchanged. Hermetic: unit on the reordered decision function.
- **CONVENTIONS**: behavior change is ordering-only; when STALE_DUP_DETECT=off the pass is byte-identical.
- **MULTI-SEAT**: pure reorder of a shared check — R2 preserved (one `stale_dup_check` implementation).

### N2 — tab-leak-guard exemption must match only FAILING lines; bound infra re-dispatch
- **GROUNDED**: PR #333 endless re-dispatch loop (live incident). `agent-watch.sh:6043` greps the whole log — a passing `ok N … tab-leak-guard` line in any bats red matches; `:6148-6151` then never caches → per-tick re-dispatch, no cap; `:3160-3164` same bug on main-health (mislabeled the 19h MAIN RED).
- **FIX + SURFACE**: one shared helper (`_health_leak_guard_red <log>` → true only when the **first failing** line, via `_health_first_notok`, names tab-leak-guard) used at both `_health_worker:6043` and `_main_health_worker:3160`. Add a per-(pr,sha) infra re-dispatch budget (mirror `_REVIEW_RETRY_MAX`) → FAILED/needs-you on exhaustion.
- **SEQUENCING**: same functions HERD-222 will touch — build N2 first (S), let HERD-222 consume the shared helper.
- **VERIFICATION PLAN**: hermetic test: a fixture log with `not ok … some-real-test` + `ok … tab-leak-guard` must classify CODEERROR (both surfaces); a log whose first `not ok` names tab-leak-guard classifies infra; loop test asserts re-dispatch stops at the cap.
- **CONVENTIONS**: fail-soft (no log → current behavior); honest labels.
- **MULTI-SEAT**: R2 — today the exemption is two divergent copies; this makes it one shared check.

### N3 — Refix budget: per-rail rounds with reset-on-progress; total cap stays
- **GROUNDED**: PR #328 spent round 1 (health/caps-sync), round 2 (review), round 3 (stale-base) — three different first-time failures — then a fresh review BLOCK (14:29:57Z) had no bounce left. Shared-by-design at `agent-watch.sh:3880-3885`; caps consumed at `:4151`, `:4396`.
- **FIX + SURFACE**: cap each kind at `REFIX_MAX_ROUNDS_<KIND>` (default = REFIX_MAX_ROUNDS) and keep a higher total cap (`REFIX_MAX_TOTAL`, default 2×) as the runaway guard; when a kind's gate subsequently PASSes for a newer sha, reset that kind's count (append a `reset` row — ledger stays append-only). Surface: `refix_round_count*`/`record_refix` (`:3873-3906`) + the three cap consult sites.
- **SEQUENCING**: after N1 (ordering changes which bounces fire); coordinate with HERD-222.
- **VERIFICATION PLAN**: unit on the counting/reset functions with a synthetic ledger; sim leg: health-bounce → pass → review-block must still bounce.
- **CONVENTIONS**: new keys default to today's numbers ⇒ behavior change only in the mixed-kind case that stranded #328; capabilities.tsv rows + caps-sync.
- **MULTI-SEAT**: budget stays seat-local for now (see N8) — note it in the item.

### N4 — Pin review input to the dispatch sha
- **GROUNDED**: `herd-review.sh:434,441,493` instruct `gh pr diff <PR>` (live head); verdicts keyed to dispatch sha (`agent-watch.sh:1925,1930`). A mid-review push desynchronizes reviewed-content from verdict-sha (incident 8b).
- **FIX + SURFACE**: at dispatch, `git fetch origin pull/<n>/head:<tmp-ref>` pinned at the dispatch sha (verify `rev-parse` matches; if the head already moved, abort cheaply — the sha is superseded anyway); reviewer prompt reads `git diff <merge-base>..<sha>` from `$MAIN`. Surface: `_dispatch_review` (`agent-watch.sh:1621`) + the three TASK strings in `herd-review.sh`.
- **SEQUENCING**: independent; keep prompt-cache-stable preamble (herd-review.sh's cache-sharing note).
- **VERIFICATION PLAN**: sim: push a new commit mid-review (the concurrency scenario already drives real reviewers) and assert the verdict's sha equals the content reviewed (scorecard field); hermetic: pinned-fetch helper unit.
- **CONVENTIONS**: fail-soft — pin failure falls back to today's live-diff path with a journal note.
- **MULTI-SEAT**: pinning makes the verdict portable across seats (a blessed sha provably reviewed-as-that-sha).

### N5 — Merge fairness: ready-PR priority + starvation surfacing
- **GROUNDED**: PR #328 went through three conflict/stale cycles in 90 min (journal 13:00–14:35Z); candidate order is worktree-discovery order (`agent-watch.sh:7279`); nothing guarantees a gates-passed PR merges before a sibling merge re-stales it.
- **FIX + SURFACE**: (a) order candidates: gates-green-awaiting-merge first, then by oldest first-candidate epoch (persist per-PR first-seen); (b) a per-PR `restale_count`; at threshold, surface a loud row AND hold sibling do_merges for one tick window while the starved PR finishes its final gate ("merge window"); (c) journal `merge_deferred_fairness`. Surface: candidate assembly `:7087-7241` + do_merge callsite.
- **SEQUENCING**: after N1; the DAG (N9) can subsume the window later.
- **VERIFICATION PLAN**: sim: N PRs all touching one file, assert every PR merges within K cycles and `restale_count` never exceeds threshold+1 (new scorecard fields); fault leg: fairness off reproduces starvation.
- **CONVENTIONS**: ship-dormant `MERGE_FAIRNESS=off` default until simmed; byte-identical off.
- **MULTI-SEAT**: within-seat only at first; cross-seat fairness needs N8's substrate — say so in the item.

### N6 — Post-merge hooks become a reconciled sweep (foreign/crashed merges)
- **GROUNDED**: 17 MERGED PRs skipped every hook (incident 1) and only worktree teardown had a resume path (`_startup_reap_sweep:3435`, startup-only). Cross-seat merges skip: approval purge (`:3353`), CI purge (`:3356`), cost (`:3360`), backlog reconcile (`:3364`), $STATE row (`:3340`), post-merge steps (`:3384`). Also G6: `merge_refused_sha_moved` journaled on a gh outage (`:3322-3324`).
- **FIX + SURFACE**: a cadenced `_sweep_merged_prs` (tracker-sweep cadence): list recently-MERGED PRs (one `gh pr list --state merged` scoped by time), for each without a `$STATE` row run the idempotent hook chain (record row reason=reconcile, reconcile_backlog, purges, reap if worktree exists; skip cost when no transcript). Rename the G6 journal label honestly. Surface: new function + tick cadence block `:7679-7692`.
- **SEQUENCING**: independent; shares cadence machinery with `_sweep_tracker_state`.
- **VERIFICATION PLAN**: sim: merge a PR via raw `gh pr merge` (not do_merge) in the real-remote or stub tier; scorecard asserts the sweep produces the $STATE row + reconcile + reap; chaos leg (P3.4) kills the watcher mid-do_merge and asserts convergence.
- **CONVENTIONS**: fail-soft per PR; idempotent (record-first); bounded lookback window.
- **MULTI-SEAT**: this IS doctrine R1 for the whole hook class — the item that retires incident 12.

### N7 — MAIN checkout freshness is its own invariant (decoupled from the codemap lever)
- **GROUNDED**: the only per-tick ff-pull lives inside `reconcile_map_freshness:3044`, gated on CODEMAP_AUTOREFRESH (`:3034-3035`); `refresh_symbol_index` journals `pushed no` (`:2984`, live today 13:54:43Z) and nothing retries the push — incident 11's divergence needed a hand rebase; the watcher runs code from $MAIN, so drift = stale engine.
- **FIX + SURFACE**: extract the ff-pull + behind-by-N probe into `reconcile_main_freshness` called unconditionally on a cadence; render a "main behind origin by N" row when ff is impossible; heal `pushed=no`: on next reconcile, retry rebase+push once, else (the commit touches only `derived-files.sh`-declared regenerables) reset it and let the next refresh regenerate. Surface: `:3028-3086`, `:2964-2985`.
- **SEQUENCING**: independent; small.
- **VERIFICATION PLAN**: hermetic: local bare-remote fixture — advance remote, assert reconcile ffs with codemap off; create a diverged generated commit, assert heal path; never touches a non-regenerable commit (negative leg).
- **CONVENTIONS**: never force; regenerable-only resets; fail-soft.
- **MULTI-SEAT**: R1 — main freshness must hold regardless of which seat merged.

### N8 — Spike: cross-seat coordination substrate for seat-local gate ledgers
- **GROUNDED**: §3 G5 — the only shared artifact is the herd/gates status; refix budgets, stale-dup noted, approvals, resolver dispatch ledgers are `$TREES`-local. Two seats on one CONFLICTING PR both `spawn_resolver` into their own worktrees and race pushes (`:2640-2655` keyed on seat-local ledgers).
- **FIX + SURFACE**: a design spike (docs/spikes/): enumerate each ledger (this audit's appendix is the input), classify {must-share, seat-local-fine, display-only}, choose substrate per class (PR labels/comments/statuses = zero-infra shared truth; a shared-state branch; or single-owner claims via a `herd/claims` status). Deliverable: doc + the first concrete follow-up item (resolver single-flight across seats).
- **SEQUENCING**: before any Phase-2 fairness work goes cross-seat; after HERD-163 work-unit spike (its abstraction may host the claim).
- **VERIFICATION PLAN**: spike = doc; the follow-up item carries the sim (two watchers, one PR, exactly one resolver — N10's rig).
- **CONVENTIONS**: doc-only; no behavior change.
- **MULTI-SEAT**: this is the doctrine's enforcement backlog for R1's "seat-local state is a defect".

### N9 — Gate-order DAG + supersession-cancel (structural)
- **GROUNDED**: G1's enumeration; `_discard_stale_reviews:1596`/`_discard_stale_health:5910` discard results but never terminate workers — a doomed Opus review runs to completion; gate order is hardcoded in one 350-line loop body.
- **FIX + SURFACE**: declare gates as ordered cost classes (deterministic-cheap → deterministic-slow → LLM) in one table; the action pass walks the table; on sha supersession, TERM in-flight workers for the old sha (reusing the corpse-sweep TERM path `:6213-6227`). Surface: main loop + a small gate-registry; a refactor, behavior-preserving except cancels.
- **SEQUENCING**: after N1 lands the cheap win; this is the generalization. Big agent-watch.sh surface — nothing else in flight on the loop.
- **VERIFICATION PLAN**: sim: mid-gate push must TERM the old-sha reviewer (assert via registry) and total reviewer-seconds drop vs baseline; full posture-matrix pass byte-identical on green paths.
- **CONVENTIONS**: refactor-with-proof; DAG table is engine-internal (not operator config) in v1.
- **MULTI-SEAT**: sets up per-gate blessing granularity later (share health/review outcomes, not just the combined blessing).

### N10 — Sim tier: multi-seat + starvation scenario
- **GROUNDED**: no scenario in `sim/README-sandbox-sim.md` runs TWO watchers against one repo; every multi-seat invariant (blessing dedup `:7309`, double-comment, double-resolver, fairness) is currently proven only in prod.
- **FIX + SURFACE**: `sandbox-multiseat-scenario.sh`: two real watcher gate loops, two `$TREES`, one stub/real remote; scorecard: `duplicate_gate_runs`, `duplicate_hold_comments`, `resolver_double_dispatch`, `max_restale_cycles`, all-PRs-drained. Fault leg: singleton lock off → must go red.
- **SEQUENCING**: after N5/N8 define the invariants it asserts; rig reuses the P1 concurrency scenario scaffolding.
- **VERIFICATION PLAN**: the scenario IS the plan; register in `templates/conformance.tsv` for the multi-seat capability rows.
- **CONVENTIONS**: hermetic by default; real-remote behind the existing SANDBOX_REAL_REMOTE opt-in.
- **MULTI-SEAT**: the proof rig for the whole doctrine.

### N11 — Tick-loop availability: timeout-wrapped gh + background spawns
- **GROUNDED**: G4 — foreground `herd-feature.sh` per intent (`:6978-6980`), foreground `herd-resolve.sh` (`:2644`), unwrapped `gh` throughout the action pass; one hang stalls all gating; the exec-hang probe covers only claude (`:1860`).
- **FIX + SURFACE**: a `_gh` wrapper with `HERD_GH_TIMEOUT` (default generous, e.g. 30s) used in the tick path; move lane launches to background with the spawn-ack pattern `spawn_resolver` already uses (`:2646-2653`). Surface: tick-path gh callsites + `_drain_spawn_queue`.
- **SEQUENCING**: independent; touch-everything diff — schedule when no other agent-watch.sh PR is in flight.
- **VERIFICATION PLAN**: hermetic: a stub `gh` that sleeps must not stall the tick past the timeout (drive the extracted wrapper); sim regression pass.
- **CONVENTIONS**: fail-soft (timeout ⇒ same code path as today's gh failure); default long enough to be behavior-invisible.
- **MULTI-SEAT**: availability floor for running many seats unattended.

### N12 — Journal-driven self-audit (the gap-finder)
- **GROUNDED**: every incident in this audit was visible in the journal before a human noticed (stale MAIN RED 19h; `pushed=no` 13:54Z; fixture events; review dispatched with no verdict). Nothing reads the journal for invariant violations.
- **FIX + SURFACE**: `journal-audit.sh` on the sweep cadence, replaying a bounded window for: merge without reap; `*_dispatched` without a terminal outcome past family TTL; `refix_bounce` without `refix_wake_result`; red state older than TTL; `pushed=no` never followed by `pushed=yes`; known-fixture slugs (A2's lint feeds this). Findings → operator-inbox rows + `journal_audit` events (never gates).
- **SEQUENCING**: after P1 lands (so it audits the new invariants too); pairs with HERD-202 (builder-notes channel) on the inbox surface.
- **VERIFICATION PLAN**: hermetic fixtures: a synthetic journal per violation class must yield exactly one finding; a clean journal yields zero (byte-quiet).
- **CONVENTIONS**: advisory-only, ship-dormant behind `JOURNAL_AUDIT=off`, fail-soft, bounded window.
- **MULTI-SEAT**: audits observed state (the journal) — seat-independent by construction.

---

## 8. Proposed amendments to existing items

- **A1 → HERD-222** (main-health invariant): scope must include (a) re-dispatch from the *tick* whenever the current `$MAIN` HEAD has no `.main-health-<sha>` marker (not only from the next merge event — `agent-watch.sh:3379` is the only caller today); (b) the no-slot deferral (`:3240`) re-attempted per tick; (c) consume N2's shared failing-line exemption helper; (d) honest infra labels (include G6's `merge_refused_sha_moved` rename if N6 doesn't take it).
- **A2 → HERD-223** (journal hermeticity): the #337 guard did not stop pollution — live journal 13:51–14:35Z today still carries fixture `retire_*`/`reap`/`trigger_*` events from PR #328's worktree suite runs. Add: (a) PR #328 rebases onto the guard; (b) a journal fixture-lint healthcheck leg (grep live journal for fixture slugs/event families) as the ratchet; feeds N12.
- **A3 → HERD-225** (resolver lifecycle): add retire-on-verdict (mirror `_retire_reviewer_pane` `:1949`), a resolver marker-age deadline in the corpse sweep (today resolvers are the only gate population with no timeout — `_resolver_in_flight:2624` holds forever on hung-ALIVE), a re-task path into an idle resolver pane, and an honest "resolver idle · PR still conflicting" row replacing the indefinite "resolving conflict…" (`:2704,2731`).
- **A4 → HERD-226** (sha-resilient matching): include the *prevent* layer — resolver + builder task-contract line: never exit leaving the worktree on a non-PR branch (`herd-resolve.sh:75` has no branch exit contract); branch auto-repair covers the residue.
- **A5 → HERD-224** (row truth): specify the mechanism — PR fetch failure must be *detectable* (distinguish `gh pr list` rc≠0 from genuinely-empty at `agent-watch.sh:7067`), freeze last-known-good `PRS_JSON`, banner the blindness, and suppress dead-builder *crossings* + spawn-budget effects (G7: FEATS count throttles `_drain_spawn_queue:6919`) while PR data is unreadable — the PR-side analog of `_roster_readable:2523`'s "blindness is never evidence of death".
- **A6 → HERD-176** (driver-routed watcher wakes): add the stale-base bounce's raw `herdr pane run` callsites (`agent-watch.sh:4461,4465`) — currently the only bounce path that bypasses `herd_driver_send_text`, so headless driver silently loses STALE_BASE_AUTOFIX.
- **A7 → HERD-193** (supervised-process contract): enumerate the concrete holes from §4 — resolver deadline, researcher entirely unsupervised, wrong-mode drainer warned-but-never-retired (`scribe-step.sh:243-261`), builder absolute deadline as an opt-in knob, owner field journaled at every spawn.
- **A8 → HERD-216 / HERD-141** (knob-aware doctrine / posture profiles): fold in the new knobs this audit introduces (MERGE_FAIRNESS, REFIX_MAX_ROUNDS_<KIND>, JOURNAL_AUDIT, HERD_GH_TIMEOUT) so posture profiles and the coordinator skill stay knob-complete; and fix the two doc drifts (G9: MERGE_POLICY default contradiction across COORDINATOR-SOP vs control-room-map/capabilities-overview; COORDINATOR_WATCHDOG described as unwired while wired at `agent-watch.sh:5184,7670`).
- **A9 → HERD-164 / PR #328** (retirement invariant): its `_retire_ledger_files` deliberately excludes the push-gate hold files and the respawn ledger — add both to the retire sweep (or to N6's closed-PR purge): `.agent-watch-push-hold-<slug>[.body]` + the slug's `.agent-watch-push-holds` rows (§5 finding 1 — phantom "awaiting push approval" on slug reuse) and the slug's `.agent-watch-respawn` row (§5 finding 2 — inherited spent respawn budget). Both are slug-keyed, both stale-forever today.

---

## Appendix — `$TREES` state-file inventory (full)

`$TREES` = `WORKTREES_DIR`, one per project (`herd-config.sh:120`; `agent-watch.sh:127-128,193`). Only mutex: watcher singleton `.watcher-<ws>.pid` (`agent-watch.sh:6685-6730`, same-host-only) + the gate-corpse-sweep mkdir mutex (`:6242-6254`). Ledger appends are bare `>>`; upserts are temp+mv (crash-safe, not concurrent-writer-safe).

### A. Append-only merge/gate ledgers (pr/sha-keyed rows)
| File | Writer | Purge | Staleness |
|---|---|---|---|
| `.agent-watch-merged` ($STATE) | `do_merge:3340,3342` | never (by design) | history; grows forever, harmless |
| `.agent-watch-resolve-attempts` | `record_resolve_attempt:1103` | never | budget rows never reset (feeds incident 9's resolver analog) |
| `.agent-watch-reviewed` | `record_review:1248` | never | sha-keyed rows, fine |
| `.agent-watch-review-retries` | `record_review_retry:1524` | never | pr+sha, fine |
| `.agent-watch-refixed` ($REFIX_STATE) | `record_refix:3905` | never | the incident-9 budget file — no reset, no purge |
| `.agent-watch-overrides` | `herd-approve.sh:287` | never | sha-keyed, fine |
| `.agent-watch-approvals` | `:2191,2202,2216` | `purge_pr_approvals:2241` from do_merge only | **closed-unmerged PR ⇒ phantom rows forever** |
| `.agent-watch-gate-status` | `:2057` | never | idempotent dedup, fine |
| `.agent-watch-stale-dup` | `record_stale_dup_held:2228` | never | notify-once rows, fine |
| `.agent-watch-ci-checks` | `_ci_record_checked:2283` | `purge_pr_ci_checks:2291` from do_merge only | closed-unmerged leak |
| `.agent-watch-healthchecks` | `record_healthcheck:5991` | never | provenance, fine |
| `.agent-watch-tracker-swept` / `-heals` | `tracker-state-sweep.sh:181/163` | never / self-trimmed to 50 | fine |

### B. Review substrate (sha-keyed, mostly self-cleaning)
| File | Writer | Purge | Staleness |
|---|---|---|---|
| `.review-inflight-<pr>-<sha>` | `_dispatch_review:1621-1653` | collect `:1948`, dead-reap `:1956`, stale-sha `:1596-1613`, corpse sweep `:6263-6284` | sound (pid-recycle guarded `:1428-1439`) |
| `.review-result-<pr>-<sha>` | `herd-review.sh:150-158` (atomic) | collect `:1948`; stale-sha discard | sound |
| `.review-tier/-block-<pr>-<sha>` | `:1491/1296` | collect + stale-sha | sound |
| `.review-escalate-<pr>` | `_maybe_arm_review_escalation:4026` | consumed on next dispatch `:2012` **only** | **PR-keyed; PR closed before consumption ⇒ armed forever** |
| `.review-registry-<pr>-<sha>` | `:1651`, `herd-review.sh:611-616` | retire `:1561`, startup sweep `:1570`, stale-sha | sound |
| `.review-log-<slug>` | `herd-review.sh:393-424` | rolling keep-5 | slug-keyed; reuse mixes histories (cosmetic) |

### C. Health substrate
| File | Writer | Purge | Staleness |
|---|---|---|---|
| `.health-inflight-<key>` | `_health_acquire:5881` | release `:5883`, corpse sweep | sound |
| `.health-dispatch-<key>` | worker (atomic) | collector | sound |
| `.health-log-<key>` | worker | rotate keep-5 `:5775-5783` | sound |
| `.health-result-<pr>-<sha>` | `record_health_result:5901` | new-sha only (`_discard_stale_health:5910`) | never purged on close/merge — disk leak only |
| `.health-cachehit-<pr>` | `_journal_cache_hit:5945` | **never** | one file per PR forever |
| `.agent-watch-refix-stuck-<kind>-<pr>-<sha>` | `:3940` | new-sha only `:5918-5926` | closed-PR leak |
| `.agent-watch-refix-dead-<pr>-<sha>` | `:4013` (sites `:4168,4398,4416,4570,4587`) | **never** | notify-once markers accumulate forever |
| `.resolve-result-<pr>-<sha>` | resolver via `:2644` | **never** (no rm anywhere) | leak; functionally superseded per sha |
| `.main-health-<sha>` | `_collect_main_health:3268` | **never** | one 0-byte marker per merge sha |
| `.main-health-pr-<sha>` | `:3250` | collect `:3278` | leaks only if never collected |
| `.agent-watch-main-health` | `_main_health_set_red:3209` | cleared on green `:3188` | single global row, sound |
| `.herd-baseline-notok-<base-sha>` | `healthcheck.sh:179-193` (**bare `>`, non-atomic**) | **never** | torn-write-exposed under concurrent workers |

### D. Per-slug upsert ledgers (temp+mv RMW — concurrent-writer-lossy)
`DEAD_STATE` (`_dead_upsert:5503`, cleared on liveness), `DEAD_RESPAWN_STATE` (`record_respawn:5632`, **never cleared — slug reuse inherits spent budget**), `LIMIT_STATE` (`:4866`/`:4873`), `SENDKEYS_STATE` (`:4925`/`:4932`), `TRANSCRIPT_STATE` (`:5406`, continuously refreshed). RMW = two concurrent writers can drop each other's rows.

### E. Slug-keyed markers
| File | Writer | Purge | Staleness |
|---|---|---|---|
| `.herd-ref-<slug>` | lanes (`_slug_ref_file:429`) | `_reap_slug:3100` | sound |
| `.agent-watch-push-holds` + `.agent-watch-push-hold-<slug>[.body]` | `push-gate.sh:162-183,201,283` (.body via non-atomic cp/`>`) | **never** (excluded even from retirement.sh's sweep) | **phantom "awaiting push approval" on slug reuse** (read at `agent-watch.sh:7096`) |
| `.agent-watch-flair-celebrate` | `do_merge:3348` | consumed each render `:709` | sound |
| `.herd-tabs` registry rows | lanes (`:5690`, `herd-resolve.sh:62`, `herd-review.sh:634`) | orphan sweep `_herd_tabs_drop_row:3670` (cadenced) | one-cadence transient staleness (HERD-215 covers prune-on-close) |

### F. Global singletons
| File | Writer | Race |
|---|---|---|
| `.agent-watch-infra-breaker` | `_breaker_write:1706` (whole-file RMW, no lock) | lost increments/transitions corrupt the **global** breaker for every PR |
| `.codemap-reconcile-sha` | `:3021` | dirty-tree-guarded, not locked; two seats can double-commit maps |
| `.sweep-auto-acted` | `:6645` | benign (redundant re-sweep) |
| `.watcher-<ws>.pid` / `.depwatcher-<ws>.pid` | `:6685-6730` | the lock itself; same-host-only |
| `.gate-corpse-sweep.lock.d` | `:6242-6254` (mkdir mutex, stale-reclaim 60s) | sound same-host |

### G. Bounded surfaces (no staleness found)
Inbox ledger/seen (trimmed to 50/1000, `:826-836,773,798-821`), spawn-held (self-GC per tick `:538-563,6831`), spawn-queue `.req` files (claim/release/skip protocol in `spawn-step.sh` with stale-reclaim).

### H. Retirement invariant (branch `feat/retirement-invariant`, PR #328 — not yet on main)
`.retire-<slug>` (escalation counter; cleared on converge/active `retirement.sh:119-122,879-904`), `.retire-anchor-<slug>-<sha>` (MERGED/CLOSED memo; swept at teardown `:220-227,565`), `.retire-probe-<slug>-<sha>` (30s TTL), `.retire-noted-<slug>-<kind>` (cleared with state). `retire_converge` (`:552-571`) also runs `clear_dead/clear_limit/clear_sendkeys/purge_pr_approvals/purge_pr_ci_checks` — good; but its own comment (`:192-219`) documents that it deliberately does NOT touch `.health-*`, `.review-escalate-*`, `.resolve-result-*`, `.agent-watch-refix-*` — and nothing else purges `review-escalate`/`resolve-result`/`refix-dead`/`health-cachehit` on a closed-unmerged PR either (§5 finding 3), nor the push-gate/respawn slug files (A9).
