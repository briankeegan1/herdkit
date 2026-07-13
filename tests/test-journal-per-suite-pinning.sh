#!/usr/bin/env bash
# test-journal-per-suite-pinning.sh — hermetic proof of HERD-363 PER-SUITE-RUN JOURNAL PINNING:
#
#   Two suite instances running CONCURRENTLY in the same environment must write to DISJOINT
#   journals, so a journal-grepping test can never count the OTHER run's events.
#
# The bug (PR #462 gate forensics): .herd/healthcheck.project.sh pinned ONE shared JOURNAL_FILE for
# a suite run (HERD-223), and the HERD-361 baseline-aware gate spawns a SECOND full suite that
# inherits this process's environment. The idempotent pin seams (journal-test-env.sh / run-suite.sh)
# KEPT the already-exported value, so both runs appended to one file; the baseline's fair-shaped
# events (exactly 6 per OFF-leg run) landed in the shared journal after the tree run's scenario mark
# and were counted by the sandbox-concurrency fairness leg (observed counts were exact multiples of 6).
# A line-count mark fences HISTORY but never a concurrent writer — only a disjoint path does.
#
# The fix pins a PER-PROCESS journal path (suffix $$) and stamps HERD_JOURNAL_PIN_PID, so a value
# pinned by a DIFFERENT process instance is re-pinned instead of kept. This test drives the REAL
# seams (scripts/herd/journal-test-env.sh + scripts/herd/journal.sh) — it breaks if they regress.
#
# Fully hermetic: temp dirs only, no network, never touches the live control room.
# Run:  bash tests/test-journal-per-suite-pinning.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
JOURNAL_SH="$ROOT/scripts/herd/journal.sh"
JTE_SH="$ROOT/scripts/herd/journal-test-env.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$JOURNAL_SH" ] || fail "journal.sh not found at $JOURNAL_SH"
[ -f "$JTE_SH" ]     || fail "journal-test-env.sh not found at $JTE_SH"

# Count events named "$2" in journal file "$1" (0 when the file is absent). `grep -c` prints the
# count AND exits 1 on zero matches, so capture stdout and swallow the status — never double-print.
count_events() {
  local jf="$1" ev="$2" n
  [ -f "$jf" ] || { printf '0'; return 0; }
  n="$(grep -c "\"event\":\"$ev\"" "$jf" 2>/dev/null)" || true
  printf '%s' "${n:-0}"
}

# ── (A) two CONCURRENT suite instances (separate processes) write DISJOINT journals ─────────────
# Model the gate exactly: a parent pins a SHARED journal (as the tree-run suite does), then spawns
# two child suite instances — each a distinct process (distinct $$). Each sources the fixed seam,
# which detects the inherited pin belongs to another process and re-pins its OWN per-run journal.
# Each child then journals the SAME fair-shaped events (the collision the baseline leg caused). The
# proof: the two children's journals are DIFFERENT files, each holds ONLY its own events, and the
# shared parent journal never received a single child event.
SHARED="$T/shared-suite-journal.jsonl"
: > "$SHARED"
CHILD="$T/child.sh"
cat > "$CHILD" <<EOF
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=scripts/herd/journal-test-env.sh
. "$JTE_SH" "\$1"            # \$1 = this child's private dir
# shellcheck source=scripts/herd/journal.sh
. "$JOURNAL_SH"
# Fair-shaped events, exactly as the baseline's test-merge-fairness.sh legs emit.
journal_append merge_fairness_priority prs 102,103 tag "\$2"
journal_append pr_starvation pr "\$2" laps 3
journal_append pr_starvation pr "\$2" laps 4
printf '%s\n' "\$JOURNAL_FILE"    # tell the parent where this instance pinned
EOF
chmod +x "$CHILD"

# Two instances started BACK-TO-BACK, sharing the parent's exported (foreign) pin.
export JOURNAL_FILE="$SHARED"
export HERD_JOURNAL_PIN_PID="$$"       # pinned by THIS (parent) process → foreign to each child
JF_A="$(bash "$CHILD" "$T/inst-a" alpha 2>/dev/null | tail -1)"
JF_B="$(bash "$CHILD" "$T/inst-b" bravo 2>/dev/null | tail -1)"
unset JOURNAL_FILE HERD_JOURNAL_PIN_PID

[ -n "$JF_A" ] && [ -n "$JF_B" ]        || fail "(A) a child suite instance did not report its journal path"
[ "$JF_A" != "$JF_B" ]                  || fail "(A) two concurrent suite instances pinned the SAME journal: $JF_A"
[ "$JF_A" != "$SHARED" ]                || fail "(A) instance A kept the foreign shared pin ($SHARED) instead of re-pinning"
[ "$JF_B" != "$SHARED" ]                || fail "(A) instance B kept the foreign shared pin ($SHARED) instead of re-pinning"
case "$JF_A" in "$T/inst-a"/journal.*.jsonl) ;; *) fail "(A) instance A pinned an unexpected path: $JF_A" ;; esac
case "$JF_B" in "$T/inst-b"/journal.*.jsonl) ;; *) fail "(A) instance B pinned an unexpected path: $JF_B" ;; esac

# Each private journal holds exactly its own events; neither perturbs the other's grep-assertions.
[ "$(count_events "$JF_A" merge_fairness_priority)" = "1" ] || fail "(A) instance A journal miscounts its own priority event"
[ "$(count_events "$JF_A" pr_starvation)" = "2" ]           || fail "(A) instance A journal miscounts its own starvation events"
[ "$(count_events "$JF_B" merge_fairness_priority)" = "1" ] || fail "(A) instance B journal miscounts its own priority event"
[ "$(count_events "$JF_B" pr_starvation)" = "2" ]           || fail "(A) instance B journal miscounts its own starvation events"
grep -q '"tag":"alpha"' "$JF_A" && ! grep -q '"tag":"bravo"' "$JF_A" \
  || fail "(A) instance A journal was contaminated by instance B's events"
grep -q '"tag":"bravo"' "$JF_B" && ! grep -q '"tag":"alpha"' "$JF_B" \
  || fail "(A) instance B journal was contaminated by instance A's events"

# The shared (foreign) journal must be untouched — no concurrent writer leaked into it.
[ "$(count_events "$SHARED" merge_fairness_priority)" = "0" ] || fail "(A) a child suite leaked events into the shared journal"
[ "$(count_events "$SHARED" pr_starvation)" = "0" ]           || fail "(A) a child suite leaked starvation events into the shared journal"
ok
echo "PASS (A) concurrent suite instances write DISJOINT journals; neither perturbs the other's grep"

# ── (B) idempotency preserved for a SINGLE run; foreign-process pins are re-pinned ──────────────
# (B1) same process, two sources → the first pin is kept (byte-stable for a single suite run).
(
  unset JOURNAL_FILE HERD_JOURNAL_PIN_PID 2>/dev/null || true
  . "$JTE_SH" "$T/b-one"
  first="$JOURNAL_FILE"
  case "$first" in "$T/b-one"/journal.*.jsonl) ;; *) exit 11 ;; esac
  [ "${HERD_JOURNAL_PIN_PID:-}" = "$$" ] || exit 12
  . "$JTE_SH" "$T/b-two"                 # SAME process → keep
  [ "$JOURNAL_FILE" = "$first" ] || exit 13
) || fail "(B1) a second source in the SAME process must keep the first pin (rc=$?)"

# (B2) an inherited value stamped by ANOTHER process is re-pinned (the concurrency fix).
(
  export JOURNAL_FILE="$T/foreign.jsonl"; : > "$T/foreign.jsonl"
  export HERD_JOURNAL_PIN_PID="999999"   # a pid that is not ours
  . "$JTE_SH" "$T/b-repin"
  [ "$JOURNAL_FILE" != "$T/foreign.jsonl" ] || exit 21
  case "$JOURNAL_FILE" in "$T/b-repin"/journal.*.jsonl) ;; *) exit 22 ;; esac
  [ "${HERD_JOURNAL_PIN_PID:-}" = "$$" ] || exit 23
) || fail "(B2) a value pinned by a DIFFERENT process must be re-pinned (rc=$?)"

# (B3) an inherited value with NO pin stamp (explicit user / suite pin) is always respected.
(
  export JOURNAL_FILE="$T/explicit.jsonl"; : > "$T/explicit.jsonl"
  unset HERD_JOURNAL_PIN_PID 2>/dev/null || true
  . "$JTE_SH" "$T/b-keep"
  [ "$JOURNAL_FILE" = "$T/explicit.jsonl" ] || exit 31
) || fail "(B3) an unstamped explicit pin must be respected (rc=$?)"
ok
echo "PASS (B) idempotent within a run; re-pins only a foreign-process value; respects explicit pins"

# ── (C) regression of the PR #462 class: a concurrent fair-shaped writer is NOT counted ─────────
# The exact fault: a foreign suite continuously appends the 6 fair-shaped events per OFF-leg run to
# what WOULD be the shared journal, while a consumer suite counts fair events since its own mark. With
# the fix, the consumer (a new process instance) re-pins a disjoint journal, so the foreign writer can
# never inflate its count — the "pr_starvation=6/15 while max laps=1" impossibility can't recur.
FOREIGN="$T/foreign-suite.jsonl"
: > "$FOREIGN"
# A background foreign writer hammering the shared path with 6 fair-shaped events per lap.
(
  # shellcheck source=scripts/herd/journal.sh
  JOURNAL_FILE="$FOREIGN" . "$JOURNAL_SH"
  export JOURNAL_FILE="$FOREIGN"
  for _lap in 1 2 3 4 5; do
    journal_append merge_fairness_priority prs 900 lap "$_lap"
    journal_append merge_fairness_priority prs 901 lap "$_lap"
    journal_append merge_fairness_priority prs 902 lap "$_lap"
    journal_append pr_starvation pr 900 lap "$_lap"
    journal_append pr_starvation pr 901 lap "$_lap"
    journal_append pr_starvation pr 902 lap "$_lap"
  done
) &
_writer=$!

CONSUMER="$T/consumer.sh"
cat > "$CONSUMER" <<EOF
#!/usr/bin/env bash
set -uo pipefail
# The consumer INHERITS the foreign shared pin (as the baseline leg inherited the tree run's) …
# shellcheck source=scripts/herd/journal-test-env.sh
. "$JTE_SH" "\$1"            # … but the fixed seam re-pins it disjoint (different process)
# shellcheck source=scripts/herd/journal.sh
. "$JOURNAL_SH"
# The consumer's OWN legs: one priority + one starvation event of its own.
journal_append merge_fairness_priority prs 102,103 mark consumer
journal_append pr_starvation pr consumer laps 3
printf '%s\n' "\$JOURNAL_FILE"
EOF
chmod +x "$CONSUMER"

export JOURNAL_FILE="$FOREIGN"          # the inherited shared pin …
export HERD_JOURNAL_PIN_PID="$$"        # … stamped by the foreign (this) process
JF_C="$(bash "$CONSUMER" "$T/consumer-dir" 2>/dev/null | tail -1)"
unset JOURNAL_FILE HERD_JOURNAL_PIN_PID
wait "$_writer" 2>/dev/null || true

[ -n "$JF_C" ] && [ "$JF_C" != "$FOREIGN" ] || fail "(C) consumer kept the foreign journal ($FOREIGN)"
# The consumer's journal holds ONLY its own two events — none of the foreign writer's 15+15.
[ "$(count_events "$JF_C" merge_fairness_priority)" = "1" ] \
  || fail "(C) consumer counted foreign priority events (got $(count_events "$JF_C" merge_fairness_priority), want 1)"
[ "$(count_events "$JF_C" pr_starvation)" = "1" ] \
  || fail "(C) consumer counted foreign starvation events (got $(count_events "$JF_C" pr_starvation), want 1)"
# Sanity: the foreign writer really did emit its 6-per-lap load (a non-vacuous collision window).
[ "$(count_events "$FOREIGN" pr_starvation)" -ge 6 ] \
  || fail "(C) the synthetic foreign writer never produced its fair-shaped load"
ok
echo "PASS (C) a concurrent fair-shaped writer never inflates a per-suite-pinned consumer's count"

echo "PASS: test-journal-per-suite-pinning ($pass checks)"
