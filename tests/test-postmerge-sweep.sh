#!/usr/bin/env bash
# test-postmerge-sweep.sh — hermetic tests for the POST-MERGE RECONCILE SWEEP (HERD-232):
# _sweep_merged_prs in agent-watch.sh, which re-derives a merged PR's post-merge obligations from the
# world instead of firing them as side effects of THIS seat's do_merge.
#
#   (1) ledger helpers: _pms_swept / _pms_record (pr+sha keyed), obligation probes
#   (2) a merged PR with NO $STATE row (a foreign / crashed merge) → the sweep runs the missing hooks,
#       writes the merge row, enqueues the reconcile, and journals postmerge_reconciled with the list
#   (3) already-reconciled → BYTE-INERT: no journal line, no duplicate $STATE row, no re-enqueue
#   (4) foreign-seat-handled (tracker sweep already confirmed the ref Done) → DEFER the shared hook,
#       journal postmerge_deferred, still discharge this seat's own local obligations
#   (5) ledger residue (approvals + CI rows) for a merged PR is purged, and named in `missing`
#   (6) worktree teardown: reap ONLY when the worktree HEAD == the merged PR's headRefOid; a live
#       (re-spawned) slug and a DIRTY tree are both left alone AND left un-swept, so a later pass retries
#   (7) cost is claimed only where a builder transcript ledger actually exists
#   (8) gh unreadable → the whole pass is skipped quietly (never a partial reconcile)
#
# Sources agent-watch.sh in lib mode (AGENT_WATCH_LIB=1). The merged-PR list arrives through the
# HERD_PMS_PRS_JSON_FILE seam (raw `gh pr list --json` output), so NO network is ever touched; $HERE is
# redirected at a stub dir so no real scribe drainer runs. The worktrees under test are REAL git repos,
# so the sha anchor + dirty-tree guard exercise the real rev-parse / status paths.
# Run:  bash tests/test-postmerge-sweep.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
for b in python3 git; do command -v "$b" >/dev/null 2>&1 || fail "$b required to run this test"; done

# ── Stub binaries on PATH (NETWORK-FREE) ──────────────────────────────────────
# `gh` must NEVER be reached: the PR list comes from the JSON seam and every gh-backed helper the sweep
# can touch (_reconcile_pr_ref) is overridden below. A stub that exits non-zero proves that.
BIN="$T/bin"; mkdir -p "$BIN"
# This `gh` PRINTS A VALID-LOOKING PR LIST **AND STILL FAILS** — a rate-limit / auth blip that truncates
# mid-page. It is the adversary for check (8): the sweep must trust the EXIT STATUS, not the bytes,
# because reconciling off a truncated list silently skips the obligations of every PR that got cut.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '[{"number":100,"headRefOid":"eee555","headRefName":"feat/offline"}]\n'
exit 7
STUB
chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ─────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_TRANSCRIPT_ROOT="$T/transcripts"; mkdir -p "$HERD_TRANSCRIPT_ROOT"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

DRYRUN=""
MAIN="$T/main"; mkdir -p "$MAIN"
SELF_WT="$T/self"

# Stub $HERE/scribe.sh so reconcile_backlog's fuzzy path logs instead of spawning a drainer.
STUBHERD="$T/herd-stub"; mkdir -p "$STUBHERD"
SCRIBE_LOG="$T/scribe-calls.log"; : > "$SCRIBE_LOG"
cat > "$STUBHERD/scribe.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$SCRIBE_LOG"
STUB
chmod +x "$STUBHERD/scribe.sh"
HERE="$STUBHERD"

# The PR body / tracker-ref read is the sweep's only per-PR network call. Drive it from a variable.
PR_REF=""
_reconcile_pr_ref() { printf '%s' "$PR_REF"; }
_slug_ref() { printf ''; }                       # no per-worktree marker in this fixture

# Reap is proven end-to-end against real worktrees in the sim; here we only assert the DECISION.
REAP_LOG="$T/reap.log"; : > "$REAP_LOG"
_reap_slug() { printf '%s %s %s\n' "$1" "$3" "${5:-}" >> "$REAP_LOG"; }
COST_LOG="$T/cost.log"; : > "$COST_LOG"
cost_emit_merge() { printf '%s %s\n' "$1" "$2" >> "$COST_LOG"; }

for fn in _sweep_merged_prs _pms_reconcile_one _pms_swept _pms_record _pms_state_row \
          _pms_approvals_rows _pms_ci_rows _pms_journal_has _pms_tracker_ledgered _pms_reconcile_handled; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined (must live above the AGENT_WATCH_LIB return)"
done
[ -n "${POSTMERGE_SWEPT_LEDGER:-}" ] || fail "POSTMERGE_SWEPT_LEDGER ledger var not set"
ok

# ── helpers ───────────────────────────────────────────────────────────────────
PRS_JSON="$T/prs.json"; export HERD_PMS_PRS_JSON_FILE="$PRS_JSON"

# prs <pr> <sha> <branch> [...] — write the raw `gh pr list --json` payload the seam reads. Emits the
# PRs NEWEST-first with descending mergedAt, exactly as real `gh pr list --state merged` does, so the
# sweep's own oldest-first re-sort is what the ordering checks exercise.
prs() {
  python3 -c '
import sys, json
a = sys.argv[1:]
n = len(a) // 3
out = []
for i in range(n):
    # newest first: PR at index 0 gets the LATEST mergedAt
    out.append({"number": int(a[3*i]), "headRefOid": a[3*i+1], "headRefName": a[3*i+2],
                "mergedAt": "2026-07-0%dT12:00:00Z" % (9 - i)})
print(json.dumps(out))' "$@" > "$PRS_JSON"
}

# mergedAt epoch for the k-th PR passed to prs() (k is 0-based), for asserting $STATE stamps.
prs_epoch() { python3 -c '
import sys, calendar, time
print(calendar.timegm(time.strptime("2026-07-0%dT12:00:00Z" % (9 - int(sys.argv[1])), "%Y-%m-%dT%H:%M:%SZ")))' "$1"; }

reset_world() {
  : > "$STATE"; : > "$RECONCILE_STATE"; : > "$APPROVALS"; : > "$CI_CHECKS_STATE"
  : > "$TRACKER_SWEEP_LEDGER"; : > "$POSTMERGE_SWEPT_LEDGER"; : > "$POSTMERGE_NOTED_LEDGER"
  : > "$JOURNAL_FILE"; : > "$SCRIBE_LOG"; : > "$REAP_LOG"; : > "$COST_LOG"
  PR_REF=""
}

jlines()      { [ -s "$JOURNAL_FILE" ] && grep -c . "$JOURNAL_FILE" || echo 0; }
jhas()        { grep -q "\"event\":\"$1\"" "$JOURNAL_FILE" 2>/dev/null; }
jmissing()    { sed -n 's/.*"event":"postmerge_reconciled".*"missing":"\([^"]*\)".*/\1/p' "$JOURNAL_FILE"; }
scribe_calls(){ [ -s "$SCRIBE_LOG" ] && grep -c . "$SCRIBE_LOG" || echo 0; }
state_rows()  { awk -v p="$1" '$2==p{n++} END{print n+0}' "$STATE" 2>/dev/null; }

# real_wt <slug> [dirty] — a real git repo at $TREES/<slug>; echoes its HEAD sha.
real_wt() {
  local d="$TREES/$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo base > "$d/f.txt"; git -C "$d" add -A
  git -C "$d" -c commit.gpgsign=false commit -qm base
  [ "${2:-}" = dirty ] && echo "uncommitted work" >> "$d/f.txt"
  git -C "$d" rev-parse HEAD
}

# ── (1) ledger helpers + obligation probes ────────────────────────────────────
reset_world
_pms_swept 5 aaa && fail "_pms_swept true on an empty ledger"
_pms_record 5 aaa
_pms_swept 5 aaa || fail "_pms_swept false after _pms_record"
_pms_swept 5 bbb && fail "_pms_swept must be sha-keyed"
_pms_swept 6 aaa && fail "_pms_swept must be pr-keyed"

_pms_state_row 42 && fail "_pms_state_row true on an empty merge ledger"
printf '%s 42 my-slug HERD-1\n' "$(date +%s)" >> "$STATE"
_pms_state_row 42  || fail "_pms_state_row false for a recorded merge"
_pms_state_row 4   && fail "_pms_state_row must match the whole PR field (4 vs 42)"

printf '%s awaiting 42 deadbeef\n' "$(date +%s)" >> "$APPROVALS"
_pms_approvals_rows 42 || fail "_pms_approvals_rows false with a live approval row"
_pms_approvals_rows 43 && fail "_pms_approvals_rows must be pr-keyed"
printf '42 deadbeef failure macos\n' >> "$CI_CHECKS_STATE"
_pms_ci_rows 42 || fail "_pms_ci_rows false with a live CI row"
_pms_ci_rows 4  && fail "_pms_ci_rows must match the whole PR field (4 vs 42)"
ok

# ── (2) a foreign / crashed merge: no $STATE row → run the missing hooks ──────
reset_world
prs 91 abc123 feat/lost-merge
_sweep_merged_prs || fail "_sweep_merged_prs returned non-zero on a clean pass"
[ "$(state_rows 91)" -eq 1 ] || fail "the sweep must write the \$STATE merge row (got $(state_rows 91))"
grep -q ' 91 lost-merge' "$STATE" || fail "the \$STATE row must carry the branch's slug (got: $(cat "$STATE"))"
# THE MERGE⇒REAP INVARIANT (review BLOCK). journal-audit.sh rule (a) reads every `merge` event as
# "this seat merged a PR and owes a later `reap`". This PR has no worktree here, so no reap is owed and
# none will ever be emitted. Journaling `merge` would therefore mint a permanent, unfixable
# merge_without_reap finding for precisely the foreign merges this sweep exists to serve.
jhas merge && fail "the sweep must NEVER journal a bare 'merge' event — it asserts a reap obligation it cannot discharge"
jhas merge_observed || fail "the sweep must journal merge_observed for a merge it did not perform"
grep -q '"event":"merge_observed".*"reason":"reconcile".*"reap_owed":"no"' "$JOURNAL_FILE" \
  || fail "a worktree-less reconciled merge must record reap_owed=no (got: $(cat "$JOURNAL_FILE"))"
jhas postmerge_reconciled  || fail "the sweep must journal postmerge_reconciled"
[ "$(jmissing)" = "state_row,reconcile" ] \
  || fail "missing list should be 'state_row,reconcile', got '$(jmissing)'"
[ "$(scribe_calls)" -eq 1 ] || fail "the sweep must enqueue exactly one reconcile (got $(scribe_calls))"
reconcile_enqueued 91 abc123 || fail "reconcile_backlog must have ledgered pr+sha"
_pms_swept 91 abc123 || fail "a fully-reconciled PR must be recorded run-once"
# The $STATE row is stamped with the PR's REAL mergedAt, not the moment we noticed it.
[ "$(awk '$2==91{print $1}' "$STATE")" = "$(prs_epoch 0)" ] \
  || fail "the \$STATE row must carry the PR's mergedAt epoch (got: $(cat "$STATE"))"
ok

# ── (2b) merge⇒reap: when a reap IS owed, say so ─────────────────────────────
reset_world
owed_sha="$(real_wt owed)"
prs 90 "$owed_sha" feat/owed
_sweep_merged_prs
grep -q '"event":"merge_observed".*"reap_owed":"yes"' "$JOURNAL_FILE" \
  || fail "a reconciled merge WITH a reapable worktree must record reap_owed=yes (got: $(cat "$JOURNAL_FILE"))"
grep -q "^owed 90 postmerge-sweep$" "$REAP_LOG" || fail "…and it must actually reap"
jhas merge && fail "still no bare 'merge' event, even when a reap is owed"
ok

# ── (2c) catch-up batch lands in TRUE merge order, newest last ────────────────
# gh returns newest-first; build_landed renders the LAST THREE $STATE rows. Appending in gh's order
# would show the OLDEST three PRs of a catch-up batch as the most recent landings.
reset_world
prs 71 s71 feat/p71  72 s72 feat/p72  73 s73 feat/p73
_sweep_merged_prs
[ "$(awk '{print $2}' "$STATE" | tr '\n' ' ')" = "73 72 71 " ] \
  || fail "catch-up rows must be appended oldest-first (got: $(awk '{print $2}' "$STATE" | tr '\n' ' '))"
ok

# ── (3) a second pass over the reconciled world is BYTE-INERT ─────────────────
# Re-establish (2)'s world: the checks above each reset it, and this section is about what a SECOND
# pass does to an ALREADY-reconciled PR.
reset_world
prs 91 abc123 feat/lost-merge
_sweep_merged_prs || fail "establishing pass returned non-zero"
[ "$(state_rows 91)" -eq 1 ] || fail "establishing pass did not write the \$STATE row"
before="$(jlines)"
_sweep_merged_prs || fail "second pass returned non-zero"
[ "$(jlines)" -eq "$before" ]  || fail "a reconciled PR must journal nothing on re-run (was $before, now $(jlines))"
[ "$(state_rows 91)" -eq 1 ]   || fail "a reconciled PR must not get a duplicate \$STATE row"
[ "$(scribe_calls)" -eq 1 ]    || fail "a reconciled PR must not re-enqueue a reconcile"
ok
# …and even with the run-once ledger wiped, the per-obligation probes alone keep it inert. (Belt and
# braces: the ledger is an optimisation, the probes are the correctness argument.)
: > "$POSTMERGE_SWEPT_LEDGER"; : > "$JOURNAL_FILE"
_sweep_merged_prs || fail "re-probe pass returned non-zero"
[ "$(jlines)" -eq 0 ]        || fail "obligations already met must journal nothing (got: $(cat "$JOURNAL_FILE"))"
[ "$(state_rows 91)" -eq 1 ] || fail "re-probe wrote a duplicate \$STATE row"
[ "$(scribe_calls)" -eq 1 ]  || fail "re-probe re-enqueued a reconcile"
_pms_swept 91 abc123 || fail "an already-clean PR must still be recorded run-once"
ok
# …and the braces alone hold too: with the run-once row present but the world wiped clean underneath it,
# the sweep must short-circuit BEFORE probing a single obligation. This is what stops a reconciled PR
# from being re-processed forever (and what a merge-ledger rotation would otherwise turn into a re-run).
reset_world
prs 91 abc123 feat/lost-merge
_pms_record 91 abc123
_sweep_merged_prs || fail "run-once pass returned non-zero"
[ ! -s "$STATE" ]           || fail "the run-once ledger must short-circuit before any obligation runs"
[ "$(jlines)" -eq 0 ]       || fail "a swept PR must journal nothing (got: $(cat "$JOURNAL_FILE"))"
[ "$(scribe_calls)" -eq 0 ] || fail "a swept PR must not re-enqueue a reconcile"
ok

# ── (4) foreign-seat-handled: the tracker sweep already confirmed the ref Done ─
# The shared hook (reconcile) must DEFER — no scribe enqueue, no tracker double-write — while this
# seat's own local obligation (the $STATE row) is still discharged.
reset_world
prs 92 def456 feat/foreign-merge
PR_REF="HERD-999"
printf '%s HERD-999 92\n' "$(date +%s)" >> "$TRACKER_SWEEP_LEDGER"
_sweep_merged_prs || fail "_sweep_merged_prs returned non-zero on the deferral path"
[ "$(scribe_calls)" -eq 0 ] || fail "a foreign-handled ref must NOT re-enqueue a reconcile"
reconcile_enqueued 92 def456 && fail "a deferred reconcile must not claim the pr+sha ledger"
jhas postmerge_deferred     || fail "a deferral must be journaled"
grep -q '"event":"postmerge_deferred".*"evidence":"tracker-swept"' "$JOURNAL_FILE" \
  || fail "the deferral must name its evidence (got: $(cat "$JOURNAL_FILE"))"
[ "$(state_rows 92)" -eq 1 ] || fail "a deferred reconcile must not block THIS seat's own obligations"
[ "$(jmissing)" = "state_row" ] || fail "missing list should be 'state_row' only, got '$(jmissing)'"
ok
# The journal is an evidence source in its own right: a `reconcile` row for the PR defers too.
reset_world
prs 93 aaa111 feat/journal-evidence
journal_append reconcile pr 93 slug journal-evidence sha aaa111 resolution fuzzy
_pms_reconcile_handled 93 aaa111 >/dev/null || fail "a journaled reconcile must count as evidence"
[ "$(_pms_reconcile_handled 93 aaa111)" = journal ] || fail "evidence kind should be 'journal'"
_sweep_merged_prs
[ "$(scribe_calls)" -eq 0 ] || fail "journal evidence must suppress the re-enqueue"
ok

# ── (5) ledger residue is purged, and named in `missing` ─────────────────────
reset_world
prs 94 bbb222 feat/residue
printf '%s 94 residue\n' "$(date +%s)" >> "$STATE"        # merge row already there
record_reconcile 94 bbb222 residue                        # reconcile already done
printf '%s awaiting 94 bbb222\n' "$(date +%s)" >> "$APPROVALS"
printf '%s awaiting 95 ccc333\n' "$(date +%s)" >> "$APPROVALS"   # a DIFFERENT, live PR
printf '94 bbb222 failure macos\n' >> "$CI_CHECKS_STATE"
printf '95 ccc333 success linux\n' >> "$CI_CHECKS_STATE"
_sweep_merged_prs || fail "_sweep_merged_prs returned non-zero on the purge path"
[ "$(jmissing)" = "approvals,ci_checks" ] || fail "missing should be 'approvals,ci_checks', got '$(jmissing)'"
_pms_approvals_rows 94 && fail "the merged PR's approval rows must be purged"
_pms_ci_rows 94        && fail "the merged PR's CI rows must be purged"
_pms_approvals_rows 95 || fail "a DIFFERENT live PR's approval rows must survive"
_pms_ci_rows 95        || fail "a DIFFERENT live PR's CI rows must survive"
ok

# ── (6) worktree teardown is anchored on the sha, never the slug ──────────────
# (a) HEAD == merged headRefOid → reap.
reset_world
head_sha="$(real_wt reapable)"
prs 96 "$head_sha" feat/reapable
printf '%s 96 reapable\n' "$(date +%s)" >> "$STATE"; record_reconcile 96 "$head_sha" reapable
_sweep_merged_prs
grep -q "^reapable 96 postmerge-sweep$" "$REAP_LOG" || fail "a merged, clean, sha-matched worktree must be reaped (got: $(cat "$REAP_LOG"))"
[ "$(jmissing)" = "reap" ] || fail "missing should be 'reap', got '$(jmissing)'"
_pms_swept 96 "$head_sha"  || fail "a reaped PR must be recorded run-once"
ok

# (b) HEAD != merged headRefOid (a re-spawned slug, new commits) → NEVER reap, and NEVER record
#     run-once, so a later pass can still reap once the tree really is disposable.
reset_world
real_wt live-slug >/dev/null
prs 97 0000000000000000000000000000000000000000 feat/live-slug
printf '%s 97 live-slug\n' "$(date +%s)" >> "$STATE"; record_reconcile 97 0000000000000000000000000000000000000000 live-slug
_sweep_merged_prs
[ -s "$REAP_LOG" ] && fail "a worktree whose HEAD is not the merged sha must NEVER be reaped"
[ -d "$TREES/live-slug" ] || fail "the live worktree must survive"
_pms_swept 97 0000000000000000000000000000000000000000 && fail "a deferred reap must NOT be recorded run-once (it must retry)"
ok

# (c) sha matches but the tree carries uncommitted work → hold loudly, never force-remove.
reset_world
dirty_sha="$(real_wt dirty-slug dirty)"
prs 98 "$dirty_sha" feat/dirty-slug
printf '%s 98 dirty-slug\n' "$(date +%s)" >> "$STATE"; record_reconcile 98 "$dirty_sha" dirty-slug
_sweep_merged_prs
[ -s "$REAP_LOG" ] && fail "a DIRTY merged worktree must never be reaped — that is lost work"
jhas postmerge_reap_skip || fail "a held dirty worktree must journal postmerge_reap_skip"
grep -q '"reason":"dirty-worktree"' "$JOURNAL_FILE" || fail "the skip must name the reason"
_pms_swept 98 "$dirty_sha" && fail "a held worktree must NOT be recorded run-once"
ok

# (d) a held worktree PLUS real outstanding obligations: the obligations must still be discharged this
#     pass, and the PR must STILL be left un-swept so the held reap is retried. (The two decisions are
#     independent — a pass that ran hooks is not thereby "done".)
reset_world
dirty_sha="$(real_wt half-done dirty)"
prs 101 "$dirty_sha" feat/half-done
record_reconcile 101 "$dirty_sha" half-done
printf '%s awaiting 101 %s\n' "$(date +%s)" "$dirty_sha" >> "$APPROVALS"
_sweep_merged_prs
[ "$(state_rows 101)" -eq 1 ] || fail "outstanding obligations must run even when the reap is held"
_pms_approvals_rows 101 && fail "the approval residue must be purged even when the reap is held"
jhas postmerge_reconciled || fail "a pass that ran hooks must journal postmerge_reconciled"
[ "$(jmissing)" = "state_row,approvals" ] || fail "missing should be 'state_row,approvals', got '$(jmissing)'"
[ -s "$REAP_LOG" ] && fail "the dirty worktree must still not be reaped"
_pms_swept 101 "$dirty_sha" && fail "a pass with a HELD reap must NOT be recorded run-once, even after running hooks"
ok

# ── (7) cost is claimed only where a builder transcript ledger exists ─────────
reset_world
cost_sha="$(real_wt costly)"
prs 99 "$cost_sha" feat/costly
printf '%s 99 costly\n' "$(date +%s)" >> "$STATE"; record_reconcile 99 "$cost_sha" costly
mkdir -p "$(_cost_transcript_dir "$TREES/costly")"
_sweep_merged_prs
[ "$(jmissing)" = "cost,reap" ] || fail "with a transcript, missing should be 'cost,reap', got '$(jmissing)'"
grep -q '^99 costly$' "$COST_LOG" || fail "cost_emit_merge must run before the reap (got: $(cat "$COST_LOG"))"
ok
# …and with no transcript dir, cost is silently skipped (proven by (6a): missing was 'reap' alone).

# (7b) COST IS NEVER DOUBLE-COUNTED. The transcript dir lives OUTSIDE the worktree
# ($HOME/.claude/projects/<munged-path>), so it survives a reap: a do_merge that emitted `cost` and then
# died before teardown would otherwise have its cost re-emitted here. cost_day_total sums `cost` events
# unconditionally into budget_daily_exceeded, so a duplicate inflates the day's spend.
reset_world
cost_sha="$(real_wt already-costed)"
prs 89 "$cost_sha" feat/already-costed
printf '%s 89 already-costed\n' "$(date +%s)" >> "$STATE"; record_reconcile 89 "$cost_sha" already-costed
mkdir -p "$(_cost_transcript_dir "$TREES/already-costed")"
# cost.sh journals `cost component <c> pr <n> …` — `pr` is NOT the first key, so the guard must not
# assume adjacency to "event".
journal_append cost component builder pr 89 slug already-costed model m usd 1.23
_pms_journal_has cost 89 || fail "_pms_journal_has must find a cost event whose pr is not the first key"
_pms_journal_has cost 8  && fail "_pms_journal_has must match the whole pr field (8 vs 89)"
_sweep_merged_prs
[ "$(jmissing)" = "reap" ] || fail "an already-costed PR must not re-claim cost, got '$(jmissing)'"
[ ! -s "$COST_LOG" ] || fail "cost_emit_merge must NOT re-run for an already-costed PR (got: $(cat "$COST_LOG"))"
ok

# ── (7c) a permanently-deferred PR notifies ONCE, not every pass ──────────────
reset_world
noisy_sha="$(real_wt noisy dirty)"
prs 88 "$noisy_sha" feat/noisy
printf '%s HERD-88 88\n' "$(date +%s)" >> "$TRACKER_SWEEP_LEDGER"; PR_REF="HERD-88"
_sweep_merged_prs; _sweep_merged_prs; _sweep_merged_prs
[ "$(grep -c '"event":"postmerge_reap_skip"' "$JOURNAL_FILE")" -eq 1 ] \
  || fail "a permanently dirty worktree must journal postmerge_reap_skip ONCE, got $(grep -c '"event":"postmerge_reap_skip"' "$JOURNAL_FILE")"
[ "$(grep -c '"event":"postmerge_deferred"' "$JOURNAL_FILE")" -eq 1 ] \
  || fail "a repeated deferral must journal ONCE, got $(grep -c '"event":"postmerge_deferred"' "$JOURNAL_FILE")"
_pms_swept 88 "$noisy_sha" && fail "the held PR must still be retried (never marked swept)"
[ -d "$TREES/noisy" ] || fail "the dirty worktree must survive all three passes"
ok

# ── (7d) a branch that does not fit BRANCH_TEMPLATE is never treated as our slug ─
# herd_branch_parse's prefix strip is a no-op on a miss, so `chore/bump-deps` under `feat/{slug}` comes
# back verbatim. A real slug is one path segment (it names a dir under $TREES), so a '/' means "not ours".
reset_world
mkdir -p "$TREES/chore"                       # a decoy: $TREES/chore/bump-deps must never be probed
prs 87 fff777 chore/bump-deps
_sweep_merged_prs
grep -q ' 87 -' "$STATE" || fail "a non-template branch must record the '-' slug, got: $(cat "$STATE")"
[ ! -s "$REAP_LOG" ]     || fail "a non-template branch must never drive a reap"
rmdir "$TREES/chore" 2>/dev/null
ok

# ── (7e) the run-once ledger is bounded ──────────────────────────────────────
reset_world
[ "${_PMS_LEDGER_KEEP:-0}" -gt "$_PMS_LOOKBACK" ] \
  || fail "the ledger bound must exceed the lookback, else a live PR's row could be trimmed"
i=0; while [ "$i" -lt $((_PMS_LEDGER_KEEP + 25)) ]; do _pms_record "$i" "sha$i"; i=$((i+1)); done
[ "$(grep -c . "$POSTMERGE_SWEPT_LEDGER")" -eq "$_PMS_LEDGER_KEEP" ] \
  || fail "the swept ledger must be trimmed to $_PMS_LEDGER_KEEP rows, got $(grep -c . "$POSTMERGE_SWEPT_LEDGER")"
_pms_swept $((_PMS_LEDGER_KEEP + 24)) "sha$((_PMS_LEDGER_KEEP + 24))" \
  || fail "trimming must keep the NEWEST rows (the tail), not the oldest"
ok

# ── (7f) the landed row credits the PR's OWN tracker ref, not a reused slug's marker ─
# do_merge runs inside the lane that owns `.herd-ref-<slug>`, so the two always agree. The sweep can be
# looking at an OLD merged PR whose slug has since been re-spawned, and the live marker then holds the
# NEW lane's ref. Preferring the marker would credit the wrong tracker item on the landed row.
reset_world
PR_REF="HERD-OLD-PR"                          # what the merged PR's own body says
_slug_ref() { printf 'HERD-NEW-LANE'; }       # what the re-spawned slug's live marker says
prs 86 aaa888 feat/reused-slug
_sweep_merged_prs
grep -q ' 86 reused-slug HERD-OLD-PR' "$STATE" \
  || fail "the landed row must carry the PR's own Refs:, not the reused slug's marker (got: $(cat "$STATE"))"
_slug_ref() { printf ''; }                    # restore
ok
# …and with no Refs: line on the PR, the slug marker is still the fallback (never worse than do_merge).
reset_world
PR_REF=""
_slug_ref() { printf 'HERD-FALLBACK'; }
prs 85 aaa999 feat/no-refs
_sweep_merged_prs
grep -q ' 85 no-refs HERD-FALLBACK' "$STATE" \
  || fail "with no PR Refs: line the slug marker must still supply the ref (got: $(cat "$STATE"))"
_slug_ref() { printf ''; }
ok

# ── (7g) a child that reads stdin cannot truncate the sweep ──────────────────
# The loop body invokes gh, git, scribe.sh and herd_teardown_slug. If the PR list were fed on stdin, the
# first child to read it would swallow the remaining PRs and the sweep would silently stop early.
reset_world
_reap_slug() { cat >/dev/null 2>&1 || true; printf '%s %s %s\n' "$1" "$3" "${5:-}" >> "$REAP_LOG"; }
s84="$(real_wt g84)"; s83="$(real_wt g83)"; s82="$(real_wt g82)"
prs 84 "$s84" feat/g84  83 "$s83" feat/g83  82 "$s82" feat/g82
_sweep_merged_prs
for p in 84 83 82; do
  [ "$(state_rows $p)" -eq 1 ] || fail "PR #$p was skipped — a stdin-reading child truncated the sweep"
done
[ "$(grep -c . "$REAP_LOG")" -eq 3 ] || fail "all three worktrees must be reaped (got $(grep -c . "$REAP_LOG"))"
_reap_slug() { printf '%s %s %s\n' "$1" "$3" "${5:-}" >> "$REAP_LOG"; }   # restore
ok

# ── (8) an unreadable gh skips the whole pass — never a partial reconcile ─────
# The stub gh prints a WELL-FORMED one-PR list and exits 7. PR #100 has no $STATE row and no reconcile,
# so a sweep that trusted the bytes over the exit status would happily "reconcile" it off a list that
# may have been truncated before the other 29 PRs — silently skipping their obligations forever
# (they'd never re-appear, having scrolled out of the lookback window). Nothing may happen here.
reset_world
unset HERD_PMS_PRS_JSON_FILE          # fall through to the real `gh` — the failing stub
_sweep_merged_prs || fail "_sweep_merged_prs must return 0 (fail-soft) when gh is unreadable"
[ "$(jlines)" -eq 0 ]       || fail "a gh outage must journal nothing (got: $(cat "$JOURNAL_FILE"))"
[ ! -s "$STATE" ]           || fail "a gh outage must not write any merge row"
[ "$(scribe_calls)" -eq 0 ] || fail "a gh outage must not enqueue anything"
[ ! -s "$POSTMERGE_SWEPT_LEDGER" ] || fail "a gh outage must not mark anything swept"
export HERD_PMS_PRS_JSON_FILE="$PRS_JSON"
ok

echo "PASS: test-postmerge-sweep.sh ($pass checks)"
