# Rubric primitive — structured per-unit review rubrics (HERD-400)

A minimal, structured **rubric** a project can hand to the pre-merge review gate: a small list of
named criteria (each `required` or `advisory`, each with a one-line pass condition) that the
reviewer must judge **explicitly**, one verdict line per criterion, in addition to — and never
instead of — the gate's existing single PASS/BLOCK/INFRA-FAIL contract.

It is the **first cut** of the primitive: one config key, wired into the one review gate that
exists today (`scripts/herd/herd-review.sh` + `parse_review_verdict` in
`pysrc/herd/live_runtime.py`). It seeds from `docs/rubric-screening.md` — the batch-screening
primitive's `(item_id, criterion) → verdict` cell shape — but is grounded to a different seam: that
primitive scores a *batch of items* against a rubric with a dual-screener merge; this one scores
**one unit's diff** against a rubric **inline in the existing merge gate**, with no second pass and
no merge step of its own.

Ships **dormant, default-off, byte-identical when unset** (`RUBRIC_FILE=""`): every prompt site, the
parser, and the journal are unchanged unless a project opts in.

---

## The schema

A rubric is a **TSV file** (comment lines start with `#`, blank lines ignored) with exactly four
columns, mirroring the row shape already used by `templates/capabilities.tsv` /
`templates/conformance.tsv` in this repo:

| column | meaning |
|---|---|
| `id` | short, stable, machine-referenceable criterion id (free text, no `\|` or newline) |
| `text` | the criterion in one line, human-readable |
| `weight` | `required` or `advisory` — see below |
| `pass_condition` | one line describing what "PASS" looks like for this criterion |

```tsv
id	text	weight	pass_condition
scoped	Change touches only files inside its own worktree	required	No path outside the worktree is modified
tested	A test asserts the new/changed behavior	required	A test file changed alongside the behavior it covers
docs	User-facing behavior changes are documented	advisory	A doc/comment nearby explains the new lever
```

`weight` is **advisory to the reviewer's judgement**, not a second gate: this first cut does not
compute a pass/fail aggregate from the criteria (see "Non-goals"). It tells the reviewer how hard to
weigh a criterion when reasoning about the single PASS/BLOCK verdict it already owns.

## Where it plugs in

**Config key** `RUBRIC_FILE` (`scripts/herd/herd-config.sh`) — a repo-relative path, default `""`.
Resolved with the **exact same worktree-then-main lookup** `REVIEW_CHECKLIST` already uses
(`herd-review.sh` ~264-271): checked under the feature worktree first, then the main checkout; the
main checkout's copy wins if both exist. Absent, or naming a file that doesn't exist in either
location, is a silent no-op (fail-soft) — the reviewer prompt and the journal are byte-identical to
today.

**Prompt injection** — the same four prompt sites that already carry `CHECKLIST_TEXT`
(`herd-review.sh`): `LOCAL_TASK` (~461, pre-PR local review), `TASK` (~611, the single-reviewer PR
path), `PR_PANEL_TASK` (~618, the no-comment review-panel member task), and `AGENT_TASK` (~670, the
agent-pane task). Each gets the SAME rendered rubric block appended, built once from the resolved
file:

```
Also judge this project's REVIEW RUBRIC — one line per criterion, BEFORE your final verdict line:
  - [scoped] (required) Change touches only files inside its own worktree — pass: No path outside the worktree is modified
  - [tested] (required) A test asserts the new/changed behavior — pass: A test file changed alongside the behavior it covers
  - [docs] (advisory) User-facing behavior changes are documented — pass: A doc/comment nearby explains the new lever
For EACH criterion above, print one line, in the SAME order, BEFORE your final REVIEW: line and
nothing else on that line: 'RUBRIC: <id> | PASS|FAIL | <one-line reason>'. These lines inform your
reasoning; they do NOT by themselves decide PASS/BLOCK — your final REVIEW: line is still the ONLY
thing the merge gate reads to decide the merge, exactly as before.
```

The wording is deliberately explicit that the rubric is **advisory input to the reviewer's existing
judgement**, never a second gate — the overall PASS/BLOCK/INFRA-FAIL contract at the top of
`herd-review.sh` (the file's own header comment) is **unchanged**: the merge gate still reads exactly
one `REVIEW: PASS|BLOCK|INFRA-FAIL` line as the authority.

**Verdict shape** — one line per criterion, `RUBRIC: <id> | PASS|FAIL | <reason>`, printed (or, in
agent-pane mode, written to the private result file) immediately before the final `REVIEW:` line.
Pipe-delimited on purpose: unlike an em-dash, a `|` is unambiguous to split on and matches the
codebase's existing structured-verdict convention (the HERD-104 `rule: … | why: … | location: …`
BLOCK shape). A criterion line that isn't well-formed (wrong field count, an id that's empty, a
verdict that isn't `PASS`/`FAIL`) is **silently skipped** by the parser — it degrades to "this one
criterion produced no signal," never to an INFRA-FAIL of the whole review.

**Extraction + journal** — `parse_rubric_verdicts(text)` in `pysrc/herd/live_runtime.py` is a second,
independent pass over the SAME text `parse_review_verdict(text)` already parses (the review result
file's contents). It extracts every well-formed `RUBRIC:` line into `{"id", "verdict", "reason"}`.
`LiveGates.review()` calls it right after a result file collects into a durable `PASS`/`BLOCK`
verdict (never on an `INFRA` collect — there's no result to score). When at least one criterion
parsed, it appends ONE `rubric_verdicts` journal event:

```json
{"ts":"…","event":"rubric_verdicts","pr":"7","sha":"abc123","verdict":"PASS",
 "criteria":"[{\"id\":\"scoped\",\"verdict\":\"PASS\",\"reason\":\"…\"},…]"}
```

`criteria` is a JSON-encoded **string** (decode with `json.loads` to get the per-criterion list) —
journal values are bash-parity scalars (`journal.sh`'s int-or-string coercion), so a nested
array/object is carried as its own JSON string rather than spliced into the outer object. When zero
criteria parse cleanly (rubric unset, file absent, or every `RUBRIC:` line malformed), no event is
appended — byte-identical to before the file existed.

The `review_result_file` written by `_emit_verdict` (herd-review.sh) already carries — atomically,
temp+mv — exactly the final verdict line when no rubric is engaged. With a rubric engaged, the SAME
atomic write carries the criterion lines followed by the verdict line (still one atomic write, still
one file); the **stdout contract** (`herd-review.sh` prints exactly one verdict line as its final
output, per the file's own header) is untouched — rubric lines never appear on stdout, only in the
result file the python collector reads.

## Non-goals (first cut)

- **No pass/fail aggregate.** The rubric does not compute "N/M required criteria passed" and does
  not gate the merge on its own — only the reviewer's single `REVIEW:` line does, exactly as before
  `RUBRIC_FILE` existed. A future cut could add an aggregate as a NEW, opt-in gate; this cut is
  purely informational/forensic (`herd why <pr>` can show what the reviewer thought of each
  criterion after the fact).
- **No cross-PR dashboard.** The journal event is per-(pr, sha); rolling it up across PRs is a
  reporting concern for later, not this primitive.
- **No dual-screener merge.** Unlike `docs/rubric-screening.md`, there is exactly one reviewer pass
  (or one review PANEL, already a herdkit primitive on its own) — no second independent pass, no
  agreement/disagreement surface.
- **No panel-level rubric fold.** When a review PANEL is engaged (`REVIEW_PANEL`/`REVIEW_PANEL_MODELS`),
  every panelist judges the SAME rubric independently and its `RUBRIC:` lines all land in `$LOG`
  (the panel already folds each panelist's file in there for forensics); `parse_rubric_verdicts`
  extracts all of them in file order, so a criterion can appear more than once — one row per
  panelist that judged it. Deduping/folding per-criterion panel verdicts is a follow-on, not this cut.

## Verification

- `parse_rubric_verdicts` unit-tested both directions: well-formed `RUBRIC:` lines extract cleanly;
  malformed lines (missing fields, bad id, bad verdict word) are skipped and never raise or flip
  `parse_review_verdict`'s own PASS/BLOCK/INFRA determination.
- `tests/test-review-rubric-injection.sh` — the same hermetic scaffold `test-review-checklist-injection.sh`
  uses (stubbed `herdr`/`claude`, a throwaway git repo, `herd-review.sh --local <slug>`): asserts the
  rubric block is absent when `RUBRIC_FILE` is unset or names a missing file, and present + rendering
  the file's own criteria (replacing nothing — it is additive to `CHECKLIST_TEXT`) when the file
  exists in the worktree or the main checkout.
- `tests/test_live_runtime.py` — a fixture review-result-file carrying `RUBRIC:` + `REVIEW:` lines
  driven through the same hermetic `LiveGates.review()` harness `TestReviewOnceAndMarkers` already
  uses: asserts the `rubric_verdicts` journal event's shape, that a malformed criterion line degrades
  to a plain PASS/BLOCK (never INFRA-FAIL), and that a result file with NO `RUBRIC:` lines (the
  `RUBRIC_FILE`-unset case) never journals the event — byte-identical.
