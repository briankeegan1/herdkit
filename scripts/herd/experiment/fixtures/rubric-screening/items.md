# Worked-example items (the batch being screened)

Five backlog items screened against `rubric.md`. Kept deliberately terse — the interesting part is
where the two screeners AGREE vs where they DIVERGE.

| item_id  | summary                                                                      |
|----------|------------------------------------------------------------------------------|
| item-01  | Add a `--dry-run` flag to the export script (prints, does not write).         |
| item-02  | "Make the dashboard better." (no scope, no acceptance criteria)               |
| item-03  | Cache the config lookup; add a unit test asserting a second call is a hit.    |
| item-04  | Purge stale rows nightly from the audit table.                               |
| item-05  | Rename an internal helper; no behavior change; existing tests still cover it. |

The expected cross-check (see `scripts/herd/sim/rubric-screen-sim.sh`):

- Both screeners **agree** on item-01, item-03, and item-05 (all `pass`).
- They **disagree** on item-04's *safe* criterion — one reads "purge" as a destructive path
  (`fail`), the other as a routine reversible job (`pass`). → human review.
- Both are **unsure** whether item-02 is *scoped* / *testable* — the item text is too vague. Agreeing
  on "unsure" is still surfaced for a human to break the tie.
