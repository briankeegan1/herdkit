# herdkit Review Checklist Template and Guidelines

This document describes the review checklist framework: how to author one for your project, how the herdkit review gate interprets it, and the trade-offs between strictness and throughput.

## Overview

The **review checklist** is a concise, machine-parseable document that codifies what the review gate should validate for every PR. It is the contract between the engineering team and the review agent: "these criteria must all pass before auto-merge."

- **Committed to**: `.herd/review-checklist.md` in the repo root.
- **Read by**: The review lane (`herd-review.sh`), which invokes an LLM reviewer to assess the PR against each criterion.
- **Verdict**: The reviewer emits a single `REVIEW: PASS` or `REVIEW: BLOCK — <reasons>` line.
- **Effect**: A BLOCK halts the merge gate; a PASS allows the watcher to proceed.

## Authoring a Review Checklist

### Structure

The checklist is a markdown file with sections and bullet points. Example:

```markdown
# Review Checklist

## Correctness

- [ ] All code changes are syntactically correct and follow the project's language conventions.
- [ ] No obvious infinite loops, off-by-one errors, or use-after-free bugs.
- [ ] Error handling is present for all external I/O (file, network, database).
- [ ] No unhandled exceptions or panics in happy-path code.

## Safety & Security

- [ ] No SQL injection, XSS, command injection, or OWASP top-10 vulnerabilities.
- [ ] No hardcoded secrets, API keys, or credentials.
- [ ] No unsafe pointer arithmetic or memory unsafety (if applicable).
- [ ] Authentication/authorization boundaries are enforced.

## Testing

- [ ] New functions have unit tests.
- [ ] Integration tests cover the primary user path.
- [ ] Tests pass locally and in CI.

## Performance

- [ ] No obvious algorithmic regressions (e.g., O(n²) loop inside O(n) loop).
- [ ] No new unbounded allocations or memory leaks.

## Documentation

- [ ] Public APIs have docstrings.
- [ ] Behavior changes are documented in a migration guide (if applicable).
- [ ] Commits have clear messages ("why", not "what").

## Scope & Scale

- [ ] The PR is focused on a single feature or bug fix.
- [ ] No unnecessary refactoring or cleanup mixed in.
- [ ] The diff is reviewable in <10 minutes.
```

### Checklist Best Practices

1. **Be specific, not vague**: "No bugs" is not helpful; "no off-by-one errors in loop bounds" is.

2. **Distinguish critical from nice-to-have**: Use sub-sections or numbering to separate "must-pass" (correctness, security) from "should-pass" (nice docstrings, code style).

3. **Account for your stack**: A Go project's checklist differs from a Python one (no GC pauses, but goroutine leaks are relevant). Customize by language.

4. **Avoid criteria that are already gatekeeping elsewhere**: If your CI already runs tests and fails on test failure, don't repeat "tests pass" in the review checklist.

5. **Keep it to ~10 criteria**: A 30-item checklist is too strict and will cause review timeouts or false-BLOCK verdicts. Prioritize.

6. **Revisit it quarterly**: As the team and project evolve, the checklist should too. Archive old versions in a comment or a separate file.

## How the Review Gate Uses the Checklist

When a PR is opened:

1. **The coordinator** detects the PR and enqueues a review task.

2. **The review lane** (`herd-review.sh`) reads the checklist, the PR diff, and the repo context.

3. **The reviewer model** (default: Opus, a strong model) is invoked with a prompt like:
   ```
   Given the checklist:
   [ ... content of .herd/review-checklist.md ...]
   
   And the PR diff:
   [ ... git diff ... ]
   
   Assess whether the PR passes all checklist criteria.
   Verdict: REVIEW: PASS
   OR
   Verdict: REVIEW: BLOCK — <reasons>
   ```

4. **The review outcome** is written to the journal and the PR comment (via `gh pr comment`).

5. **The watcher** polls the review verdict. On BLOCK, it escalates to the coordinator (requeue, override, or archive). On PASS, it proceeds to the merge gate.

## Risk-Tiered Review (Optional)

If `REVIEW_ESCALATE_GLOB` is set, the review gate can apply different checklists or models based on the diff:

```bash
REVIEW_ESCALATE_GLOB="^(app/|engine/|proto/)"  # paths that are high-risk
REVIEW_MODEL_CHEAP="claude-3-5-sonnet"  # cheaper model for low-risk diffs
```

**Logic**:
- Diff touches high-risk path → use the full `REVIEW_CHECKLIST` with the standard `REVIEW_MODEL` (Opus).
- Diff is docs/tests only → skip review (`source=skipped-low-risk`); PASS automatically.
- Diff is low-risk → use the simplified checklist with `REVIEW_MODEL_CHEAP` (Sonnet).

This can reduce review cost by 50–70% without sacrificing safety for high-risk paths.

## Example: Go Project Checklist

```markdown
# Go Review Checklist

## Correctness

- [ ] No goroutine leaks: defer wg.Done(), channels are closed, context cancels propagate.
- [ ] No race conditions: shared state is protected by mutexes or channels.
- [ ] Error wrapping uses `fmt.Errorf("%w", err)` for proper error chains.
- [ ] Nil pointer dereferences are guarded with nil checks.

## Performance

- [ ] No unbounded slice growth: `append` loops pre-allocate capacity.
- [ ] No synchronous I/O in hot loops.
- [ ] Benchmarks pass (if applicable).

## Safety

- [ ] No unsafe pointer arithmetic; unsafe blocks have // SAFETY: comments.
- [ ] No unencrypted secrets in logs or config.
- [ ] Database queries are parameterized (no string concatenation).

## Testing

- [ ] New exported functions have at least one unit test.
- [ ] Integration tests cover the primary user path.
- [ ] Tests pass with `go test ./...` and `go test -race ./...`.

## Documentation

- [ ] Exported functions have package-level doc comments.
- [ ] Complex algorithms have inline comments explaining the approach.
- [ ] Commits have imperative mood ("Add X", not "Adds X" or "Added X").
```

## Example: Python Project Checklist

```markdown
# Python Review Checklist

## Correctness

- [ ] No off-by-one errors in slicing or loop ranges.
- [ ] Exception handling is specific: no bare `except:` clauses.
- [ ] Type hints are present for public functions.
- [ ] No mutable default arguments (e.g., `def f(x=[]):`).

## Performance

- [ ] No O(n²) loops or quadratic algorithms.
- [ ] No repeated file I/O in loops; cache or batch instead.
- [ ] Generator expressions used for large sequences.

## Safety

- [ ] No SQL injection: queries use parameterized placeholders.
- [ ] No hardcoded secrets.
- [ ] Requests are timeoutted: `requests.get(..., timeout=10)`.

## Testing

- [ ] New functions have unit tests in `tests/test_*.py`.
- [ ] Tests pass with `pytest` and `pytest -v --cov`.
- [ ] No test skips without a JIRA ticket reference.

## Documentation

- [ ] Public functions have docstrings (Google or NumPy style).
- [ ] README or CONTRIBUTING.md updated if behavior changes.
- [ ] Commits have clear messages explaining the "why".
```

## Common Review Failures and How to Fix Them

### "REVIEW: BLOCK — No error handling for network calls"

**Root cause**: The checklist requires error handling, the PR opens network calls without it.

**Fix**: Add error handling to the PR:
```python
try:
    response = requests.get(url, timeout=10)
    response.raise_for_status()
except requests.RequestException as e:
    logger.error("Failed to fetch %s: %s", url, e)
    return None
```

Then requeue the PR via the coordinator (spawn a refix builder / push a fix commit) — there is no dedicated requeue subcommand; a new push re-triggers the watcher gates.

### "REVIEW: BLOCK — Diff is too large, difficult to assess"

**Root cause**: The PR changes >500 lines or touches >10 files; the reviewer cannot be confident.

**Fix**: Split the PR into smaller, focused PRs (one feature per PR, one refactor per PR). Then requeue each.

Alternatively, if the large diff is necessary, add a comment to the PR body: "LARGE_DIFF_JUSTIFIED: <reason>" and override: `herd approve <pr#>`.

### "REVIEW: BLOCK — Insufficient test coverage"

**Root cause**: The checklist requires tests for new functions; the PR adds functions with no tests.

**Fix**: Add tests:
```python
def test_new_function():
    result = new_function(input)
    assert result == expected
```

Then requeue.

### Review is timing out (reviewer never returns a verdict)

**Root cause**: The diff is huge, or the reviewer's prompt is looping.

**Fix**: 
1. Set `REVIEW_TIMEOUT` to a higher value (default 120 seconds): `herd config set REVIEW_TIMEOUT 180`.
2. Simplify the checklist (fewer criteria).
3. Set `REVIEW_MODEL` to a faster model temporarily: `herd config set REVIEW_MODEL claude-3-5-sonnet`.

Then retry the review.

## Integration with Healthcheck

The review gate and healthcheck gate are **independent**:

- **Healthcheck**: Runs the test suite, linting, type checking. Objective, automated.
- **Review**: Reads the checklist against the diff. Subjective, LLM-based.

Both must PASS for auto-merge. A PR can:
- Healthcheck PASS, Review BLOCK (fix code issues, requeue).
- Healthcheck BLOCK, Review PASS (fix tests/lint, requeue).
- Both BLOCK (fix both, requeue).

If you want to **skip review for low-risk diffs** (e.g., docs-only), set `REVIEW_ESCALATE_GLOB`:

```bash
REVIEW_ESCALATE_GLOB="^(app/|engine/|proto/)"
REVIEW_SKIP_PATTERNS="^(docs/|README)"  # if supported
```

(Check your `herd-review.sh` version for exact syntax.)

## Checklist Ownership

- **Written by**: The engineering team, in consensus.
- **Committed to**: `.herd/review-checklist.md`, subject to code review like any source file.
- **Approved by**: The tech lead or architect (whoever owns code quality).
- **Reviewed quarterly**: Update the checklist as the project evolves or pain points emerge.

Any developer can propose a change to the checklist via a PR; the approval process is the same as any PR.

## Template: Starting Your Checklist

If you're new to herdkit and don't have a checklist yet, start with this minimal version and expand:

```markdown
# Review Checklist

## Correctness & Safety

- [ ] No syntax errors or type errors.
- [ ] Error handling is present for all I/O operations.
- [ ] No obvious bugs or logic errors.
- [ ] No security vulnerabilities (SQL injection, XSS, etc.).

## Testing

- [ ] Tests added for new code.
- [ ] Tests pass locally.

## Documentation

- [ ] Commit messages are clear.
- [ ] Public APIs are documented (if applicable).
```

Then, after the first few PRs, refine it based on what the reviewers actually flagged.

---

The review checklist is your team's code quality bar, codified. Invest time in getting it right; it pays dividends in faster, more confident merges.
