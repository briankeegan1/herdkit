# Worked-example rubric — "backlog item ready to build?"

A tiny, self-contained rubric used by the rubric-screening primitive's worked example
(`scripts/herd/experiment/fixtures/rubric-screening/`). Two independent screener agents grade the
same five backlog items against these three criteria and emit a verdict row per (item, criterion)
cell. `rubric-screen-merge.sh` then cross-checks the two passes.

Each cell gets a verdict from the vocabulary **pass | fail | unsure**:

- `pass`  — the item clearly satisfies the criterion.
- `fail`  — the item clearly does not.
- `unsure`— the screener cannot decide from the item text alone (always sent to human review).

## Criteria

1. **scoped** — the item describes a single, bounded change (not an open-ended epic).
2. **testable** — success is observable: there is a clear way to tell the change works.
3. **safe** — the change is default-off / reversible and does not touch a destructive path.

The items themselves are in `items.md`; the two screener passes are `screener-a.csv` and
`screener-b.json` (deliberately in different formats to exercise both loaders).
