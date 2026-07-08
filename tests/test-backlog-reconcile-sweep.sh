#!/usr/bin/env bash
# test-backlog-reconcile-sweep.sh — hermetic test of the periodic reconcile SWEEP
# (scripts/herd/backlog-reconcile-sweep.sh). The sweep cross-references OPEN 🔜 backlog items
# against recently-merged PRs + recent commit subjects and surfaces the probably-shipped-but-
# still-🔜 ones. This exercises it against fixture BACKLOG.md + stubbed gh/git output (no network,
# no gh, no herdr, no scribe agent) via the file/command seams:
#   HERD_SWEEP_PRS_FILE · HERD_SWEEP_COMMITS_FILE · HERD_RECONCILE_SCRIBE.
# Asserts:
#   (1) a shipped-but-🔜 item (title strongly matches a merged PR) IS detected as HIGH-confidence
#   (2) an unrelated 🔜 item is NOT flagged
#   (3) --enqueue calls the scribe seam; the DEFAULT run does NOT
#   (4) --enqueue enqueues ONLY the HIGH-confidence candidate, with a well-formed, verify-first request
# Run:  bash tests/test-backlog-reconcile-sweep.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-reconcile-sweep.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"

REPO="$T/repo"
mkdir -p "$REPO/.herd" "$T/trees"
export HERD_CONFIG_FILE="$REPO/.herd/config"
cat > "$REPO/.herd/config" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="main"
BACKLOG_FILE="BACKLOG.md"
EOF

# ── fixture backlog: two 🔜 items that SHIPPED (match merged work) + two that did not ──
cat > "$REPO/BACKLOG.md" <<'B'
# project backlog

## Planned
- 🔜 **Auto-refix resumes a done builder via the shared resume helper** *(issue #71)* — when a review BLOCK bounces to an idle builder, wake it through the shared resume helper.
- 🔜 **Prompt cache ordering keeps the stable system prefix first** — reorder the prompt so cached tokens stay contiguous.
- 🔜 **CSV importer for the ledger** — parse third-party spreadsheets into the ledger format.
- 🔜 **Dark mode toggle for the settings pane** — let users flip the theme at runtime.

## Recently shipped
- ✅ **Prior work** — already done
B

# ── stubbed merged PRs: "<pr#>\t<title>" (newest first) ───────────────────────
# PR #71 title matches the first 🔜 item almost word-for-word (HIGH). The others match nothing.
cat > "$T/prs.tsv" <<'P'
71	Auto-refix resumes a done builder via the shared resume helper
80	Prompt cache ordering keeps the stable system prefix first in the request
66	Healthcheck sha-cache avoids re-running an unchanged gate
P

# ── stubbed recent commits: "<sha>\t<subject>" (newest first) ─────────────────
# Includes bookkeeping/merge subjects that MUST be ignored even though they echo item text.
cat > "$T/commits.tsv" <<'C'
e381e30	Backlog: Reap auto-refix resumes done builder shared resume helper → PR
97c0eb8	Merge pull request #81 from feat/csv-importer-for-the-ledger
e504a8e	Review gate escalation after a failed refix round
970bbaa	Add a shared resume helper used by the builder wake path
C

export HERD_SWEEP_PRS_FILE="$T/prs.tsv"
export HERD_SWEEP_COMMITS_FILE="$T/commits.tsv"

# ── (1)+(2) default report: shipped items detected, unrelated ones excluded ────
out="$(bash "$SCRIPT")" || fail "default run exited non-zero"
printf '%s\n' "$out" | grep -q 'Auto-refix resumes a done builder' \
  || fail "sweep did not detect the shipped-but-🔜 auto-refix item ($out)"
printf '%s\n' "$out" | grep -qi 'HIGH' \
  || fail "sweep did not mark the auto-refix item HIGH-confidence ($out)"
printf '%s\n' "$out" | grep -q 'PR #71' \
  || fail "sweep did not cite the matching PR #71 ($out)"
# The unrelated items must NOT be flagged as candidates.
printf '%s\n' "$out" | grep -q 'CSV importer'  && fail "sweep false-flagged the unrelated CSV importer item"
printf '%s\n' "$out" | grep -q 'Dark mode'     && fail "sweep false-flagged the unrelated dark-mode item"
pass

# ── (3a) default run must NOT touch the scribe seam ────────────────────────────
REQDIR="$T/reqs"; mkdir -p "$REQDIR"
cat > "$T/fake-scribe.sh" <<FS
#!/usr/bin/env bash
printf '%s\n' "\$1" > "$REQDIR/req-\$\$-\$RANDOM.txt"
FS
chmod +x "$T/fake-scribe.sh"
HERD_RECONCILE_SCRIBE="$T/fake-scribe.sh" bash "$SCRIPT" >/dev/null 2>&1 || fail "default run (with seam set) exited non-zero"
[ -z "$(ls -A "$REQDIR" 2>/dev/null)" ] || fail "default run must NOT enqueue a scribe request"
pass

# ── (3b)+(4) --enqueue calls the scribe seam once per HIGH candidate ───────────
# Both 🔜 items that match merged PRs (#71, #80) are HIGH; the two unrelated items are excluded.
out="$(HERD_RECONCILE_SCRIBE="$T/fake-scribe.sh" bash "$SCRIPT" --enqueue)" \
  || fail "--enqueue run exited non-zero"
printf '%s\n' "$out" | grep -q 'enqueued 2 scribe reconcile request' \
  || fail "--enqueue did not report enqueuing the two HIGH candidates ($out)"
reqs=( "$REQDIR"/*.txt )
[ "${#reqs[@]}" -eq 2 ] || fail "expected exactly TWO scribe requests (one per HIGH item), got ${#reqs[@]}"
# The auto-refix request must be present, well-formed, and verify-first.
REQ="$(grep -l 'Auto-refix resumes a done builder' "$REQDIR"/*.txt | head -1)"
[ -n "$REQ" ] || fail "no request references the auto-refix item"
grep -q 'PR #71'               "$REQ" || fail "request lacks the matching PR reference"
grep -q 'gh pr view 71'        "$REQ" || fail "request lacks the verify command"
grep -q 'Edit ONLY BACKLOG.md' "$REQ" || fail "request lacks the edit-only guard"
grep -qi 'VERIFY FIRST'        "$REQ" || fail "request lacks the verify-first rule"
# No unrelated item was ever enqueued.
grep -rq 'CSV importer' "$REQDIR"/*.txt && fail "an unrelated item was wrongly enqueued"
grep -rq 'Dark mode'    "$REQDIR"/*.txt && fail "an unrelated item was wrongly enqueued"
pass

# ── (5) empty-match case: a backlog with no shipped items enqueues nothing ─────
cat > "$REPO/BACKLOG.md" <<'B'
# project backlog

## Planned
- 🔜 **A totally novel unshipped idea about quantum widgets** — nothing merged resembles this.
B
rm -f "$REQDIR"/*.txt
out="$(HERD_RECONCILE_SCRIBE="$T/fake-scribe.sh" bash "$SCRIPT" --enqueue)" \
  || fail "--enqueue (no matches) exited non-zero"
printf '%s\n' "$out" | grep -qi 'no probably-shipped\|no HIGH-confidence candidates to enqueue' \
  || fail "no-match run should report nothing to reconcile/enqueue ($out)"
[ -z "$(ls -A "$REQDIR" 2>/dev/null)" ] || fail "no-match run must NOT enqueue anything"
pass

# ── (6) EXACT-REF pass: the HERD-49 / PR #185 regression (HERD-138) ────────────
# The proven gap (2026-07-08): HERD-49 sat OPEN while merged PR #185 was literally titled
# "feat(HERD-49): …" 25h earlier — fuzzy title match + a short recent-PR window BOTH missed it.
# Model that exactly: the id-bearing PR is OLD (last in the full history) and is ABSENT from the
# recent fuzzy window, and the item's TITLE shares no key terms with any merged work. Only an
# exact-ref grep over the FULL merged history can catch it.
JOURNAL="$T/journal.jsonl"; export JOURNAL_FILE="$JOURNAL"; rm -f "$JOURNAL"
cat > "$REPO/BACKLOG.md" <<'B'
# project backlog

## Planned
- 🔜 **Add exact-ref pass before fuzzy title matching** *(HERD-49)* — scan merged PR titles for the item id.
- 🔜 **Some unrelated future idea about quantum widgets** *(HERD-77)* — nothing merged mentions this.

## Recently shipped
- ✅ **Prior work** — already done
B

# Recent fuzzy window (HERD_SWEEP_PRS_FILE) — does NOT contain #185, and matches nothing by terms.
cat > "$T/prs-recent.tsv" <<'P'
310	chore: bump dependency pins for the monthly refresh
309	docs: clarify the onboarding runbook wording
P
# FULL merged history for the exact pass — #185 is OLD (bottom of the list, well outside the window).
cat > "$T/prs-full.tsv" <<'P'
310	chore: bump dependency pins for the monthly refresh
309	docs: clarify the onboarding runbook wording
250	feat: assorted small cleanups
185	feat(HERD-49): reorder the prompt cache prefix so cached tokens stay contiguous
P
export HERD_SWEEP_PRS_FILE="$T/prs-recent.tsv"
export HERD_SWEEP_EXACT_PRS_FILE="$T/prs-full.tsv"
export HERD_SWEEP_COMMITS_FILE="$T/commits.tsv"   # bookkeeping/merge noise, matches nothing here

out="$(bash "$SCRIPT")" || fail "exact-ref default run exited non-zero ($out)"
printf '%s\n' "$out" | grep -q 'Add exact-ref pass before fuzzy title matching' \
  || fail "exact pass did not surface the HERD-49 item ($out)"
printf '%s\n' "$out" | grep -qi 'exact' \
  || fail "exact pass did not mark the HERD-49 item as an exact-ref match ($out)"
printf '%s\n' "$out" | grep -q 'PR #185' \
  || fail "exact pass did not cite the OLD matching PR #185 ($out)"
printf '%s\n' "$out" | grep -q 'HERD-49' \
  || fail "exact pass did not name the matched tracker id HERD-49 ($out)"
# The item with no matching PR must be left untouched.
printf '%s\n' "$out" | grep -q 'quantum widgets' && fail "exact pass false-flagged the unmatched HERD-77 item"
pass

# ── (7) EXACT-REF --enqueue: one verify-first request citing PR #185 ───────────
rm -f "$REQDIR"/*.txt "$JOURNAL"
out="$(HERD_RECONCILE_SCRIBE="$T/fake-scribe.sh" bash "$SCRIPT" --enqueue)" \
  || fail "exact-ref --enqueue run exited non-zero ($out)"
printf '%s\n' "$out" | grep -q 'enqueued 1 scribe reconcile request' \
  || fail "exact --enqueue did not report enqueuing the single exact candidate ($out)"
reqs=( "$REQDIR"/*.txt )
[ "${#reqs[@]}" -eq 1 ] || fail "expected exactly ONE scribe request (the exact-ref item), got ${#reqs[@]}"
REQ="${reqs[0]}"
grep -q 'HERD-49'               "$REQ" || fail "exact request lacks the tracker id HERD-49"
grep -q 'PR #185'              "$REQ" || fail "exact request lacks the matching PR #185"
grep -q 'gh pr view 185'      "$REQ" || fail "exact request lacks the verify command"
grep -qi 'VERIFY FIRST'       "$REQ" || fail "exact request lacks the verify-first rule"
grep -q 'Edit ONLY BACKLOG.md' "$REQ" || fail "exact request lacks the edit-only guard"
grep -q 'exact-ref match'     "$REQ" || fail "exact request should state it is an exact-ref match, not a term overlap"
pass

# ── (8) audit journal: a summary event is written on EVERY run (even a silent one) ──
grep -q '"event":"backlog_reconcile_sweep"' "$JOURNAL" \
  || fail "no backlog_reconcile_sweep summary event was journaled ($(cat "$JOURNAL" 2>/dev/null))"
grep -q '"exact_hits":1' "$JOURNAL" || fail "journal summary did not record the exact hit ($(cat "$JOURNAL"))"
# A silent 'nothing to reconcile' run must ALSO journal, so it is auditable.
cat > "$REPO/BACKLOG.md" <<'B'
# project backlog

## Planned
- 🔜 **A totally novel unshipped idea about quantum widgets** — nothing merged resembles this.
B
rm -f "$JOURNAL"
bash "$SCRIPT" >/dev/null 2>&1 || fail "silent run exited non-zero"
grep -q '"event":"backlog_reconcile_sweep"' "$JOURNAL" \
  || fail "a silent run must still journal a summary event for auditability"
grep -q '"exact_hits":0' "$JOURNAL" || fail "silent run should journal zero exact hits ($(cat "$JOURNAL"))"
pass
unset JOURNAL_FILE HERD_SWEEP_EXACT_PRS_FILE

echo "ALL PASS ($PASS checks)"
