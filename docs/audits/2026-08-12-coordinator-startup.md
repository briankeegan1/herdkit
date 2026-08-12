<!-- Provenance: builder audit for HERD-658, 2026-08-12. Committed as durable evidence. -->

> **Date:** 2026-08-12
> **Scope:** HERD-658 — "the coordinator skill takes a while to start up sometimes." Measure the
> three named cost centers (rendered-skill size/context-load, on-invocation state reads,
> pane/driver round-trips in `scripts/herd/coordinator.sh`), rank them, and implement the first
> mechanical win.
> **Environment:** herdkit's own dogfood checkout (`SCRIBE_BACKEND=linear`, a **remote** backend —
> the case the task spec calls out), on `origin/main` at the time of measurement, worktree
> `coordinator-startup-latency`. Numbers below are wall-clock, 3-run averages on this machine —
> treat them as directional, not as SLA guarantees; they scale with journal size and network
> latency, which both grow over time.

---

## 1. Executive summary

Startup latency has three independent cost centers. Measured, they rank:

| # | Cost center | Measured cost | Verdict |
|---|---|---|---|
| 1 | **On-invocation state reads** (`herd backlog`, `git worktree list`, `{{DRIVER_LIST_AGENTS}}`, 2× `herd log \| grep`) | **~2.1–2.4s serial**, of which the two `herd log` calls alone are **~1.4s (58%)** | Dominant, and half of it was pure waste — **fixed this PR** |
| 2 | **Rendered-skill size / context-load** | 125,479 bytes / 1,447 lines rendered; the capabilities index alone is 49,037 bytes (**39%** of the file) | Real and growing (355 capability rows today), but already has a mitigation in place (see §3) — no further change made here |
| 3 | **Pane/driver round-trips in `coordinator.sh`** | Each `herdr` call (`workspace list`, `tab list`, `agent list`, …) measured **<10ms**; ~10 such calls in the launch sequence ⇒ well under 100ms total | Negligible under normal conditions — not touched |

The implemented fix (§4) cuts the `herd log` component from two full journal parses to one,
saving **~0.6–0.7s per coordinator invocation** on this repo's 8.3MB journal, and the saving grows
with journal size since it eliminates a full re-parse rather than a fixed cost.

---

## 2. Method

Each cost center was measured directly against this checkout (not simulated), using `/usr/bin/time
-p`, 3 runs per measurement, from the worktree root:

```
time bash ./bin/herd render                       # (a) render cost
time herd backlog                                  # (b) on-invocation: backlog (Linear)
time (herd log | grep builder_note)                 # (b) on-invocation: herd log × 2 (before)
time (herd log | grep config_viability)
time herdr workspace list / tab list / agent list   # (c) pane/driver round-trips
```

`bash ./bin/herd render` (not the PATH-resolved `herd`) is required inside a worktree — the
globally installed `herd` symlink resolves to the **main checkout's** `bin/herd`, which renders
from the main checkout's `templates/`, not the worktree's edited one. This tripped the first
render attempt during this audit and is worth knowing for the next person editing
`coordinator.md.tmpl` in a worktree.

---

## 3. (a) Rendered-skill size and context-load share

`herd render` (`bin/herd:1980` `cmd_render` → `bin/herd:407` `render_skill`) takes **~0.9–1.0s**
end to end (mostly `bash bin/herd` startup + the `${caps_file}` TSV walk), and is a **per-machine,
one-time-per-config-change** cost — it does not re-run on every coordinator turn, only on
`init`/`update`/`reload`/`render`/`config set`. It is not part of the recurring per-session tax and
is not this audit's focus.

What *is* recurring is the **size of the rendered file the model ingests at the start of every
coordinator conversation**: 125,479 bytes / 1,447 lines. Breaking it down by section:

- The **capabilities index** (`## Herdkit capabilities — compact index`, rendered lines 838–1219)
  is **49,037 bytes — 39% of the whole rendered skill** — for 355 rows in
  `templates/capabilities.tsv` (396KB source), one terse bullet per row.
- `render_skill`'s own comment at `bin/herd:538-544` records that this compact-index form is
  *already* a deliberate cut-down from inlining the full `description` + `when_to_surface` columns
  for every row (which the comment estimates at ~50KB / ~72% of the *then*-smaller skill) — i.e.
  the "leaner core with the capability index loaded on demand" the task spec asks to evaluate has
  already shipped once, as a compact index with the full reference (`docs/capabilities-overview.md`
  / `capabilities.tsv` itself) reachable on demand rather than inlined.
- The residual finding: **even the compact index has grown to be the single largest section of the
  rendered skill again**, purely from the *count* of capability rows (355 and rising with every new
  `herd` subcommand/lane/config key). A further cut (e.g. dropping the index to a bare name list and
  pushing the one-line gloss fully on-demand, or paginating/sectioning it) is a real lever, but it
  changes what state ships inline on every session — exactly the kind of render-output change
  `AGENTS.md`'s "no workflow behavior change" framing asks to be conservative about, and it is not
  mechanical (it needs a design call about what glosses the coordinator can safely defer). Left as
  a **ranked, not implemented**, follow-up — see §6.

---

## 4. (b) On-invocation state reads — MEASURED, FIXED

Step 2 of `## On invocation` in `templates/coordinator.md.tmpl` instructs the coordinator to run,
serially, at the top of every turn where it re-orients:

1. `git worktree list` — fast (local git, no measurable cost)
2. `{{DRIVER_LIST_AGENTS}}` (→ `herdr agent list`) — **~6ms** (local herdr daemon, no network)
3. `herd log | grep builder_note` — **~0.5–0.7s**
4. `herd log | grep config_viability` — **~0.5–0.7s**

`herd backlog` (step 1 of the same section, the work-tracker read) is a **live, uncached Linear
GraphQL call** (`scripts/herd/backends/linear.sh:653` `_backend_list_open`, no local caching by
design — every call reflects the current tracker) — measured **~0.3–0.7s**. That cost is real but
is a single necessary network round trip already done once; there is nothing duplicated to cut
without changing what "fresh" means, so it is left alone.

`herd log` (`bin/herd:8318` `cmd_log`) is the interesting one: every invocation runs
`_journal_load_config`, then re-reads and re-formats the **entire** journal
(`$WORKTREES_DIR/.herd/journal.jsonl`, **8.3MB** on this dogfood checkout) through
`python3 -m herd.log`. The two-bullet instruction in the template calls it **twice in a row** —
once per grep pattern — paying that full parse-and-format cost twice to filter the *same* output
two different ways.

**Before** (two separate `herd log | grep <pattern>` invocations, 3-run average):

```
real 1.44
real 1.42
real 1.41
```

**After** (one `herd log` snapshot to a temp file, grep the file twice):

```
real 0.81
real 0.77
real 0.79
```

**~0.6–0.7s saved per coordinator invocation (≈45% cut of this step)** — and the saving is
proportional to journal size, so it grows as the engine journal grows rather than staying fixed.
(An earlier attempt captured the snapshot into a bash variable instead of a file —
`out="$(herd log)"` — which measured *worse*, ~1.17s, because bash's `$(...)` capture of an
8MB+ string is itself slow; the file-based snapshot avoids that trap.)

### The fix

`templates/coordinator.md.tmpl`, step 2 of `## On invocation`: replaced the two independent
`herd log | grep <pattern>` bullets with one snapshot (`_hl=$(mktemp); herd log > "$_hl"`) grepped
twice (`grep builder_note "$_hl"`, `grep config_viability "$_hl"`), cleaned up afterward
(`rm -f "$_hl"`). Both findings (**builder notes**, **config viability**) keep their full original
explanation text verbatim — only the commands changed, not what the coordinator does with the
output. As a side effect this also fixes a stale doc bug: the section's intro said "run all three,
they're fast" while listing **four** bullets (worktree list, driver-list-agents, and two `herd log`
calls) — collapsing the two `herd log` calls into one restores the count to three, matching the
prose.

Re-rendered and diffed (`bash ./bin/herd render`): no other lines changed, no `{{TOKEN}}` left
unsubstituted.

---

## 5. (c) Pane/driver round-trips in `scripts/herd/coordinator.sh`

`coordinator.sh` makes roughly ten `herdr` calls in its launch sequence (workspace resolve/focus,
tab list/close/create, pane launch × 2, pane rename × 2, agent launch, pane split). Each was
measured directly against the local `herdr` daemon:

```
herdr workspace list   real 0.00
herdr tab list          real 0.00
herdr agent list        real 0.00
```

All sub-10ms — `herdr` is a local multiplexer daemon, not a network service, so these round-trips
do not meaningfully contribute to "coordinator takes a while to start." The one bounded exception
is the STARTUP-RESTORE probe (`coordinator.sh:152-161`): it polls for the watcher lockfile up to
`HERD_STARTUP_LOCK_POLLS` (default 15) × 0.2s = **3s worst case**, but only on the degraded path
where the watcher hasn't grabbed its lock yet — not a cost paid on a healthy launch. No change made
here; it is not where the reported latency lives.

---

## 6. Ranked follow-ups (not implemented this PR)

1. **Capabilities index further compression** (§3) — the compact index is 39% of the rendered
   skill and grows with every new capability row. A deeper cut (bare name list + fully-on-demand
   gloss, or splitting the index out of the base render and loading it via the research lane) is
   the next real lever on rendered-skill size, but is a render-shape/behavior design decision, not
   a mechanical one — needs its own item.
2. **`herd backlog` caching under a remote backend** — every coordinator turn that re-orients pays
   a live Linear GraphQL round trip. A short-TTL cache would cut this, but trades off tracker
   freshness (a coordinator acting on stale backlog state is worse than a coordinator that's a few
   hundred ms slower) — worth a deliberate call, not a silent default.

Both are flagged as candidates for a follow-up backlog item; not filed here per `AGENTS.md`
(builders don't own the tracker).
