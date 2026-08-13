# Multi-operator ownership — who a seat's automation may act on (HERD-655, GitHub issue #771)

[`docs/multi-seat-doctrine.md`](multi-seat-doctrine.md) keeps **the engine** correct across many seats
run by the **same** operator (invariants reconciled every tick, one shared check per rule). This
document is the adjacent, narrower question: across **different operators** sharing one repo, which
surfaces let one seat's automation write to, or exercise authority over, another operator's PR — and
which of those are actually scoped today.

## The invariant

> **A seat's automation must never write to another operator's branch or clear another operator's
> holds without an explicit, journaled override.**

Every surface below is graded against it. "Own-only" means the invariant holds by construction. "All
with attribution" means it can act on a foreign PR but the action and the actor are both journaled
(a deliberate, visible override — the "explicit, journaled" half of the invariant). "All (unscoped)"
means today's shipped default fails the invariant outright.

## GROUNDED incident

emberglen, 2026-08-12, two operators sharing one repo. Seat A's `RESOLVE_AUTOFIX` rail discovered PR
#347 — authored by seat B, mid-edit under a standing do-not-touch rule — as a plain `CONFLICTING`
candidate, and dispatched the isolated conflict resolver against it. A manual interrupt caught the
dispatch before `spawn_resolver` pushed. **No surface in the write path asked whose PR it was.**

## What this PR ships

`AUTOFIX_SCOPE` (`own` default | `all`, `templates/capabilities.tsv`) — one shared check,
`_autofix_scope_permits` (`scripts/herd/agent-watch.sh`, ported for the one live rail to
`pysrc/herd/live_runtime.py`), consulted by the four **AUTOFIX write rails**:

| Rail | What it writes | Live consumer today | AUTOFIX_SCOPE default |
| --- | --- | --- | --- |
| `RESOLVE_AUTOFIX` | dispatches the conflict resolver onto a `CONFLICTING` PR's branch | **bash** — `_dispatch_conflict_autofix`, called every tick from `_tick_render_reconcile` | own |
| `STALE_BASE_AUTOFIX` | merge-up bounce (types into the builder's pane) or resolver dispatch on a stale-base hold | **python** — `LiveTick._walk`'s stale-base branch (the bash `_handle_stale_dup`/`_stale_dup_gate_step` twin lost its only caller at the P5b engine port, HERD-556, and is kept as the tested spec, exercised directly by its own suite) | own |
| `REVIEW_AUTOFIX` | re-task bounce (types into the builder's pane) on a review BLOCK | **bash-only, currently unreachable** — `_handle_block_verdict` has zero production callers since P5b; the ported engine's review-BLOCK refix (`LiveTick._bounce_and_wake`) bounces unconditionally today, with no `REVIEW_AUTOFIX` read at all | own |
| `HEALTHCHECK_AUTOFIX` | re-task bounce (types into the builder's pane) on a reproduced CODE ERROR | **bash-only, currently unreachable** — `_healthcheck_gate`/`_handle_health_codeerror` have had zero production callers since the Python port (see the retirement note above `_healthcheck_gate`'s definition); the ported engine's health-CODEERROR refix bounces unconditionally today, with no `HEALTHCHECK_AUTOFIX` read at all | own |

`own` resolves the operator's identity exactly like `WATCHER_OWNER` already does (`WATCHER_OWNER` →
`WATCHER_VIEW_AUTHOR` → `gh api user`, memoized once per process/tick) and fails **closed**: an
unresolved identity, or a mismatched author, withholds the write and journals `autofix_scope_withheld`
(`pr`, `author`, `rail`, `reason`). `all` is today's pre-HERD-655 behavior, explicit opt-in.

**Honest scope note:** because REVIEW_AUTOFIX's and HEALTHCHECK_AUTOFIX's *behavioral* consumers are
bash code the Python port already made unreachable, `AUTOFIX_SCOPE=own` closes the ownership gap in
their bash spec (tested directly, matches the WATCHER_SCOPE precedent, ready the day either rail is
restored) but does **not** currently gate a live write — because the ported engine performs that write
completely unconditionally, with no REVIEW_AUTOFIX/HEALTHCHECK_AUTOFIX read at all, own-or-foreign. That
gap pre-dates this change and is **not** closed by it; see "Known gaps" below.

## The full audit

Every surface where one seat's automation writes to or exercises authority over another operator's PR,
worktree, or hold.

| # | Surface | Scoping today | Default | Scoping key | Live in |
| --- | --- | --- | --- | --- | --- |
| 1 | `RESOLVE_AUTOFIX` resolver dispatch | **own-only** (this PR) | own | `AUTOFIX_SCOPE` | bash |
| 2 | `STALE_BASE_AUTOFIX` merge-up bounce / resolver dispatch | **own-only** (this PR) | own | `AUTOFIX_SCOPE` | python |
| 3 | `REVIEW_AUTOFIX` re-task bounce | own-only in the bash spec; **unscoped and unconditional** in the live python bounce (no REVIEW_AUTOFIX read at all — pre-existing gap) | own (spec) / always-on (live) | `AUTOFIX_SCOPE` (spec only) | bash spec, unreachable; python bounce unconditional |
| 4 | `HEALTHCHECK_AUTOFIX` re-task bounce | own-only in the bash spec; **unscoped and unconditional** in the live python bounce (no HEALTHCHECK_AUTOFIX read at all — pre-existing gap) | own (spec) / always-on (live) | `AUTOFIX_SCOPE` (spec only) | bash spec, unreachable; python bounce unconditional |
| 5 | `MERGE_POLICY=auto` merging a teammate's PR | **all (unscoped)** — see "The WATCHER_SCOPE=mine finding" below | mine (behaves as all) | `WATCHER_SCOPE` | python (`_select_candidates`); the bash twin is display-only dead weight (no live consumer since P5b) |
| 6 | `HUMAN_VERIFY_POLICY=auto` auto-clearing a teammate's HUMAN-VERIFY hold | inherits #5's scoping — it only runs for a candidate `_select_candidates` already let through | mine (behaves as all) | `WATCHER_SCOPE` (indirect) | python |
| 7 | `ADOPT_REMOTE_PRS` adopting a teammate's PR into a rail-targetable local worktree | **all (unscoped)** — no author read anywhere in `_adopt_remote_prs_scan` | off (on in the `yolo` posture) | none | bash |
| 8 | Reaper / sweep force-removal (`git worktree remove --force`) | unscoped by author, but gated by a strict sha-anchor proof (local HEAD == the PR's `headRefOid`, or an ancestor of it) and same-machine reach only | `SWEEP_AUTO=advise` (detect + row, no action); `auto` in the `yolo` posture | `SWEEP_AUTO` | bash |
| 9 | `backlog-reconcile` retitles | unscoped by author, but **never writes automatically** — `backlog-reconcile.sh`/`backlog-reconcile-sweep.sh` only enqueue a scribe request; no automated caller exists today (coordinator/human-invoked only) | dormant (no wiring) | none | dead as an automated surface |
| 10 | Pane send-keys addressing (`herd_driver_send_text`, `_find_builder_pane_id_any`) | unscoped by author — pane lookup is slug-keyed only — but structurally same-machine: a pane only exists where it was spawned, so this is downstream of #7/#5, never an independent cross-seat channel | always-on seam; gating lives in each caller | none on the seam itself | bash |
| 11 | Sha-keyed approval attribution (`herd-approve.sh approve`) | unscoped **and unattributed** — the ledger row (`epoch state pr sha`) carries no actor identity at all | n/a (human-invoked) | none | bash write; python read (`LiveGates`) |

### The `WATCHER_SCOPE=mine` finding

Rows 5–6 are the largest gap this audit surfaced, and it predates HERD-655. `WATCHER_SCOPE`'s
documented default (`mine`) reads as "own-only, ownership probe dormant"
(`templates/capabilities.tsv`'s `WATCHER_SCOPE` row) — but the code is a **no-op**, not a narrowing:

- bash: `_scope_permits_automerge` opens with `_watcher_team_mode || return 0` — under the default
  `mine`, it returns permit **unconditionally**, no author comparison, no ownership probe.
- python: `_select_candidates`'s owner filter runs only inside `if _watcher_scope(config) == "all":` —
  under `mine` it is skipped entirely.

So on the shipped default, **every** MERGEABLE+CLEAN teammate PR this seat has a local worktree for is
a normal auto-merge candidate, and any HUMAN-VERIFY hold on it auto-clears under
`HUMAN_VERIFY_POLICY=auto` exactly as if it were the operator's own. The only thing standing between a
teammate's PR and auto-merge on the default config is **whether this seat has a local worktree for
it** — which row #7 (`ADOPT_REMOTE_PRS`) supplies. The `yolo` posture ships `ADOPT_REMOTE_PRS=on` +
`MERGE_POLICY=auto` + `HUMAN_VERIFY_POLICY=auto` + `SWEEP_AUTO=auto` together — composing to "adopt any
open PR, merge it unscoped, auto-clear its human-verify hold, force-remove its worktree after."

This is a real, currently-shipped gap — narrower than the incident this PR closes (auto-merge is
already gated by the healthcheck + adversarial review + `require herd/gates` branch protection, so a
teammate's PR still cannot merge *ungated*; the gap is that it can merge **without the teammate's own
watcher ever being the one to do it**, silently). It is **out of scope for this PR** (a merge-candidacy
change is a different, higher-blast-radius surface than the four write rails HERD-655 was filed
against) and is left as a named, tracked gap rather than silently patched — see "Known gaps."

## Known gaps (fast-follow, not silently closed here)

1. **REVIEW_AUTOFIX / HEALTHCHECK_AUTOFIX have no live scope gate** — their bounce is unconditional in
   the ported Python engine (`LiveTick._bounce_and_wake`, shared across review/health/stale/coresim
   refix kinds). Wiring `AUTOFIX_SCOPE` in there means gating a function every refix kind depends on,
   including the two rails (`review`, `health`) that today bounce unconditionally by design decisions
   made outside HERD-655 — a distinct, higher-risk change than this PR's four named rails.
2. **`WATCHER_SCOPE=mine` is a no-op**, not own-only — rows 5–6 above. Fixing it is a merge-candidacy
   behavior change (not a write-rail scope), out of this PR's blast radius.
3. **`RESOLVE_CLAIM` (the cross-seat resolver-dispatch dedup) is armed only when `WATCHER_SCOPE=all`**
   (`templates/capabilities.tsv`'s `RESOLVE_CLAIM` row) — so a two-operator repo on the default `mine` also gets no
   cross-seat resolver dedup, compounding gap 2.
4. **`journal-act.sh`'s refix redelivery** (`JOURNAL_AUDIT_ACT=on`, in the `yolo` posture) reaches
   `_find_builder_pane_id_any` the same way the four AUTOFIX rails do, and is not behind
   `AUTOFIX_SCOPE` — a fifth autofix-shaped write rail this PR does not cover.
5. **`ADOPT_REMOTE_PRS` and sweep force-removal remain unscoped by author** (rows 7–8) — narrower risk
   than 1–4 (sweep requires a strict sha-anchor proof and same-machine reach; adoption's own row in
   `templates/capabilities.tsv` documents "any seat may adopt" as intended multi-seat behavior, not an
   oversight), but still worth an explicit author check if a future incident grounds it.

## Cross-links

- [`docs/multi-seat-doctrine.md`](multi-seat-doctrine.md) — the sibling doctrine for seat-independence
  *within* one operator's fleet (Rule 1: reconciled invariants; Rule 2: one shared check per surface —
  `AUTOFIX_SCOPE`'s single `_autofix_scope_permits` implementation follows Rule 2 directly).
- `templates/coordinator.md.tmpl`'s *How the engine acts on whose work* section — the coordinator-
  facing summary of this table, rendered into every project's coordinator skill.
- `templates/capabilities.tsv` — `AUTOFIX_SCOPE`, `WATCHER_SCOPE`, `WATCHER_OWNER`, `ADOPT_REMOTE_PRS`,
  `SWEEP_AUTO` rows.

Tracked as HERD-655, GitHub issue #771.
