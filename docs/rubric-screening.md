# Rubric-screening primitive (HERD-166)

A **non-code workflow template** for screening a batch of items against a rubric with LLM screener
agents, then cross-checking two independent passes so a human only reviews where they *disagree*.

It is a **primitive**, not a wired feature: nothing in the engine calls it, so the repo is
byte-identical when it is unused. You adopt it by running its steps by hand (or from your own
coordinator prompt). It ships **dormant, default-off, and fail-soft**.

The moving parts:

| Part | Path |
|------|------|
| This workflow template | `docs/rubric-screening.md` |
| Verdict contract (schema) | *below* — enforced by the merge step |
| Dual-screener merge (code) | `scripts/herd/experiment/rubric-screen-merge.sh` |
| Worked example (rubric + items + two passes) | `scripts/herd/experiment/fixtures/rubric-screening/` |
| Verify / sim (renders the disagreement surface) | `scripts/herd/sim/rubric-screen-sim.sh` |
| Hermetic unit test | `tests/test-rubric-screen-merge.sh` |

---

## The verdict contract

A **screener agent** reads the rubric and the batch and emits one row per **cell** — a
`(item_id, criterion)` pair. Five columns / keys, accepted as **CSV**, **TSV**, or **JSON** (an
array of objects):

| field | meaning |
|-------|---------|
| `item_id` | stable id of the item being screened (free text; keys the batch) |
| `criterion` | the rubric criterion this row judges (free text) |
| `verdict` | one of the vocabulary — default **`pass` \| `fail` \| `unsure`**, case-insensitive |
| `reason` | the screener's short justification (free text; may be empty) |
| `confidence` | a number in `[0,1]`, or empty (→ `null`) — how sure the screener is |

Rules the merge step **enforces** (a violation is a clean exit 1, never a partial report):

- All five columns/keys must be present.
- `verdict` must be in the vocabulary (`--labels` overrides the default set, e.g.
  `--labels include,exclude`).
- `confidence` must parse as a number in `[0,1]`, or be empty.
- A `(item_id, criterion)` **cell must be unique** within one file — a duplicate means the screener
  contradicted itself and is rejected.

`unsure` is special: a cell where **either** screener says `unsure` is always routed to human review,
even when both say `unsure` (they agree it's undecidable — a human breaks the tie).

CSV example (one screener pass):

```csv
item_id,criterion,verdict,reason,confidence
item-01,scoped,pass,"single flag, clearly bounded",0.95
item-01,safe,pass,"--dry-run only prints",0.98
item-02,scoped,unsure,"no scope given — cannot tell",0.3
```

---

## Step 1 — fan out two screeners over the items (quick lane)

Screening is a **read-only, per-item** judgement — exactly the shape the **quick lane** exists for.
Ride the quick-lane fan-out; **do not** open a per-item worktree (there is no code change to isolate;
a worktree per item would be pure overhead). One screener pass = one quick-lane agent that reads the
rubric + the whole batch and writes **one** verdict file.

Run **two independent passes** — ideally different models or differently-worded screener prompts — so
their agreement is meaningful:

```sh
# lane=quick — the lightweight, no-per-item-worktree lane (see scripts/herd/spawn.sh).
spawn.sh screen-a quick "Screen the items in <batch> against <rubric>. Emit ONE row per
    (item_id, criterion) cell as CSV with columns item_id,criterion,verdict,reason,confidence.
    verdict ∈ {pass,fail,unsure}; confidence ∈ [0,1]. Write screener-a.csv."
spawn.sh screen-b quick "…same batch, same rubric, independent judgement… Write screener-b.json."
```

Each agent fans out **over the items internally** and produces its verdict file. The two agents never
see each other's answers — that independence is the whole point.

## Step 2 — merge the two passes and surface the disagreements

```sh
scripts/herd/experiment/rubric-screen-merge.sh \
    --a screener-a.csv --b screener-b.json \
    --out rubric-merge.json --surface-csv disagreements.csv
```

The merge is **deterministic and read-only** (same inputs → byte-identical report; it never touches
git, a worktree, a pane, a tracker, or the journal — it is **not** the watcher's git-merge path). It
writes:

- **`rubric-merge.json`** — the full report:
  - `coverage` — cell counts per screener, common cells, and the **coverage gaps** (`only_in_a` /
    `only_in_b`: cells one screener judged and the other skipped).
  - `agreement` — `agreements`, `disagreements`, `agreement_rate`, **Cohen's `cohen_kappa`**
    (chance-corrected agreement; `null` when undefined), and a `confusion` matrix.
  - `review_surface` — the pile a human must adjudicate: every **disagreement** (verdicts differ)
    plus every **agree-unsure** cell, each with both verdicts, reasons, and confidences.
  - `verdict` — `clean_merge` (no review surface **and** no coverage gap), `needs_human_review`,
    and the counts.
- **`disagreements.csv`** *(optional)* — just the `review_surface`, ready to open in a spreadsheet
  for triage.

## Step 3 — a human reviews only the surface

`disagreements.csv` (or `review_surface`) is the *only* thing a human needs to look at. Everything the
two screeners agreed on (that isn't `unsure`) is settled. A `clean_merge: true` report means there is
nothing to review — the two passes agreed on every cell and covered the same batch.

---

## Try it — the worked example

The committed worked example screens five backlog items against a three-criterion rubric
(`scoped` / `testable` / `safe`), with the two passes deliberately in different formats:

```sh
bash scripts/herd/sim/rubric-screen-sim.sh
```

It drives the real merge over `scripts/herd/experiment/fixtures/rubric-screening/`, renders the
disagreement surface, and asserts it: **1 real disagreement** (item-04 `safe` — one screener reads
"purge" as a destructive path, the other as a routine reversible job) plus **2 agree-unsure** cells
(item-02 is too vague to scope or test). That is the surface a human would adjudicate.
