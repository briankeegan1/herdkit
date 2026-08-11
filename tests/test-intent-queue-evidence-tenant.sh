#!/usr/bin/env bash
# test-intent-queue-evidence-tenant.sh — HERD-640 (Phase 3 of HERD-625): the intent queue's M2 RESIDUE
# tenant — close-item-on-NON-MERGE terminal evidence (docs/spikes/coordinator-work-queue.md §1.2,
# §2.2 M2, §6 Phase 3) — riding the SHARED library end to end.
#
# WHAT THE RESIDUE IS. §1.2 is the doc's honest finding: M2 is mostly already built. On 2026-08-10 all
# twelve merged items reached Done with NO coordinator turn (5 via the merge-time fast path, 7 via
# tracker-state-sweep.sh's backstop). What nothing reads is the NON-merge evidence — a PR carrying
# `Refs:` that CLOSED UNMERGED — so its item sits in whatever state the abandoned build left it in.
#
# THE EVIDENCE RULE IS THE POINT, and it is what these cases pin: act ONLY when the decision is
# already made and merely UNEXECUTED (§2.3's line). A merged sibling carrying the same ref means the
# work shipped; no sibling at all means it did not and nobody is on it; BOTH a merged and an open
# sibling means the evidence does not decide — and then the queue must write nothing and say so.
#
# Cases:
#   (1) LEVER OFF        the sweep's scan never runs: no intent, no ledger row, no journal event.
#   (2) SUPERSEDED       closed-unmerged PR + a MERGED sibling carrying the same ref → one
#                        close-on-evidence intent → the drain drives the item to the CLOSED-NOT-DONE
#                        terminal (`canceled`) and posts a POINTER COMMENT naming the shipping PR.
#   (3) AMBIGUOUS        a merged sibling AND an open one → journals a coordinator-facing event,
#                        enqueues NOTHING and writes NOTHING (§2.3 keeps curation on the seat).
#   (4) WORK REMAINS     no sibling at all → a `work-remains` intent → the drain releases OUR OWN
#                        claim (_backend_release_item) and never touches the workflow state.
#   (5) IN FLIGHT        an OPEN sibling only → nothing is queued and nothing is ledgered, so the
#                        reading is re-taken next sweep when that PR merges or closes.
#   (6) RE-GROUND        an item already CLOSED at drain time is CONVERGED: consumed, zero writes.
#   (7) TRANSIENT        a backend that cannot resolve the item releases the intent with its attempt
#                        counter bumped, then drops it loudly past INTENT_MAX_ATTEMPTS (§4.3).
#   (8) IDEMPOTENT       a second sweep over the same evidence enqueues nothing new.
#   (9) ONE SUBSTRATE    the producer publishes through the shared library (iq_enqueue), not a
#                        hand-rolled write — asserted by source inspection, because a second copy of
#                        the queue mechanics is the exact defect Phase 2 exists to prevent.
#
# Hermetic: temp dirs only. No network, no gh, no tracker. The PRODUCER is the REAL
# tracker-state-sweep.sh driven through its documented PR seams; the CONSUMER is the REAL drain
# extracted from agent-watch.sh (the same sed extraction tests/test-intent-queue-marker-tenant.sh
# uses); the library is the shipped scripts/herd/intent-queue.sh; the backend is a STUB behind the
# engine's own SCRIBE_BACKEND_DIR seam.
#
# Run:  bash tests/test-intent-queue-evidence-tenant.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"
LIB="$REPO/scripts/herd/intent-queue.sh"
SWEEP="$REPO/scripts/herd/tracker-state-sweep.sh"
CONFIG="$REPO/scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"
for f in "$WATCH" "$LIB" "$SWEEP" "$CONFIG"; do [ -f "$f" ] || fail "missing engine file: $f"; done

TREES="$T/trees"; mkdir -p "$TREES"
IQ="$TREES/intent-queue"
MAIN="$T/main"; mkdir -p "$MAIN/.herd"
printf '# backlog\n- untouched sentinel\n' > "$MAIN/BACKLOG.md"
BACKLOG_BEFORE="$(cksum "$MAIN/BACKLOG.md")"

# ── the extracted drain + the shipped library + the shipped lever ────────────────────────────────
DRAIN_SRC="$T/drain.sh"
: > "$DRAIN_SRC"
for fn in _intent_marker_apply _intent_evidence_apply _drain_intent_queue _intent_consume; do
  sed -n "/^$fn()/,/^}/p" "$WATCH" >> "$DRAIN_SRC"
  grep -q "^$fn()" "$DRAIN_SRC" || fail "could not extract $fn from agent-watch.sh"
done
LEVER="$T/lever.sh"
sed -n '/^herd_intent_queue_on()/,/^}/p' "$CONFIG" > "$LEVER"
grep -q '^herd_intent_queue_on()' "$LEVER" || fail "could not extract herd_intent_queue_on from herd-config.sh"

# ── the STUB backend, reached through the engine's own SCRIBE_BACKEND_DIR seam ───────────────────
# STUB_STATES  "<ref> <state>" (open|in-progress|closed|FAIL; FAIL = a genuine resolve FAILURE).
# STUB_UPDATES one "<ref> <want> <component> <pr>" line per _backend_update_state call.
# STUB_AMENDS  one "<ref> <note>" line per _backend_amend call.
# STUB_RELEASE the _RELEASE_RESULT _backend_release_item reports (default RELEASED).
BDIR="$T/backends"; mkdir -p "$BDIR"
cat > "$BDIR/stub.sh" <<'STUB'
_backend_item_state() {
  local s
  s="$(awk -v r="$1" '$1==r{print $2; exit}' "$STUB_STATES" 2>/dev/null)"
  if [ "${s:-}" = "FAIL" ]; then ITEM_STATE=""; return 1; fi
  ITEM_STATE="${s:-open}"
}
_backend_update_state() {
  printf '%s %s %s %s\n' "$1" "$2" "${HERD_COMPONENT:-none}" "${HERD_TW_PR:-none}" >> "$STUB_UPDATES"
  _BACKEND_RESULT="$(cat "$STUB_MODE" 2>/dev/null || echo DONE)"
  # A confirmed transition flips the stored state, exactly as a real backend's readback would — which
  # is what makes the merged-evidence half of M2 observably AUTHORITATIVE in the cases below.
  if [ "$_BACKEND_RESULT" = "DONE" ]; then
    awk -v r="$1" '$1!=r{print} END{print r" closed"}' "$STUB_STATES" > "$STUB_STATES.tmp" 2>/dev/null \
      && mv "$STUB_STATES.tmp" "$STUB_STATES"
  fi
}
_backend_amend() { printf '%s %s\n' "$1" "$2" >> "$STUB_AMENDS"; _BACKEND_RESULT="DONE"; }
_backend_release_item() {
  printf '%s %s\n' "$1" "${2:-}" >> "$STUB_RELEASES"
  _RELEASE_RESULT="$(cat "$STUB_RELEASE" 2>/dev/null || echo RELEASED)"
}
STUB
export STUB_STATES="$T/states.txt"     STUB_UPDATES="$T/updates.log"
export STUB_AMENDS="$T/amends.log"     STUB_RELEASES="$T/releases.log"
export STUB_MODE="$T/mode.txt"         STUB_RELEASE="$T/release-mode.txt"
JLOG="$T/journal.log"

# ── the PRODUCER: the real tracker-state-sweep.sh through its PR seams ───────────────────────────
export HERD_CONFIG_FILE="$MAIN/.herd/config"
cat > "$MAIN/.herd/config" <<EOF
PROJECT_ROOT="$MAIN"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="stub"
EOF
export SCRIBE_BACKEND_DIR="$BDIR"
export HERD_TSWEEP_LEDGER="$TREES/.tracker-swept"
export HERD_TSWEEP_NOTE_FILE="$TREES/.tracker-heals"
export HERD_TSWEEP_UNRESOLVED_FILE="$TREES/.tracker-unresolved-counts"
export HERD_TSWEEP_CLOSED_LEDGER="$TREES/.closed-unmerged-scanned"
export JOURNAL_FILE="$TREES/journal.jsonl"

# sweep [<lever>] — one real sweep pass with the fixtures below. MERGED is the merged-PR seam the
# existing backstop already reads; CLOSED/OPEN are the Phase-3 ones.
sweep() {
  INTENT_QUEUE="${1:-on}" \
  HERD_TSWEEP_PRS_FILE="$T/merged.tsv" \
  HERD_TSWEEP_CLOSED_FILE="$T/closed.tsv" \
  HERD_TSWEEP_OPEN_FILE="$T/open.tsv" \
  bash "$SWEEP" 2>&1
}
# tick — one real _drain_intent_queue pass over the queue the sweep published into.
tick() {
  ( HERE="$REPO/scripts/herd"; TREES="$TREES"; MAIN="$MAIN"; DRYRUN=""
    INTENT_QUEUE_DIR="$IQ"; INTENT_DRAIN_BUDGET="${BUDGET:-4}"; INTENT_MAX_ATTEMPTS=3
    INTENT_TTL="${TTL:-86400}"
    SCRIBE_BACKEND="stub"; SCRIBE_BACKEND_DIR="$BDIR"; INTENT_QUEUE=on
    journal_append(){ printf '%s\n' "$*" >> "$JLOG"; }
    IQ_ENGINE_DIR="$T/nowhere"
    # shellcheck source=/dev/null
    . "$LEVER"; . "$LIB"; . "$DRAIN_SRC"
    _drain_intent_queue )
}
reqs(){ ls "$IQ"/*.req 2>/dev/null | wc -l | tr -d ' '; }
intent_line(){ local f; for f in "$IQ"/*.req; do sed -n "$1p" "$f"; return 0; done; }
reset() {
  rm -rf "$IQ" "$HERD_TSWEEP_CLOSED_LEDGER" "$HERD_TSWEEP_LEDGER" "$JOURNAL_FILE"
  : > "$STUB_UPDATES"; : > "$STUB_AMENDS"; : > "$STUB_RELEASES"; : > "$JLOG"
  echo DONE > "$STUB_MODE"; echo RELEASED > "$STUB_RELEASE"
  : > "$T/merged.tsv"; : > "$T/closed.tsv"; : > "$T/open.tsv"
}
jhas(){ grep -q "$1" "$JOURNAL_FILE" 2>/dev/null; }

# ── (1) LEVER OFF — the scan never runs ──────────────────────────────────────────────────────────
reset
printf '740\tHERD-100\n' > "$T/closed.tsv"
printf '751\tHERD-100\n' > "$T/merged.tsv"
out="$(sweep off)" || fail "(1) sweep exited non-zero: $out"
[ -d "$IQ" ] && fail "(1) the lever is OFF but the scan created the intent queue"
[ -s "$HERD_TSWEEP_CLOSED_LEDGER" ] && fail "(1) the lever is OFF but the scan ledgered a verdict"
jhas intent_evidence && fail "(1) the lever is OFF but the scan journaled"
pass

# ── (2a) SUPERSEDED, end to end — the pointer comment lands on the item the work shipped for ─────
# The realistic ordering: the merge-evidence half of M2 (the sweep's own loop, AUTHORITATIVE for a ref
# a merged PR carries) heals the item to Done first, in this same sweep. The residue's job is then the
# one thing that half cannot say — WHY the other PR closed unmerged — and it must NOT re-write a
# terminal that has already been reached.
reset
printf 'HERD-100 in-progress\n' > "$STUB_STATES"
printf '740\tHERD-100\n' > "$T/closed.tsv"
printf '751\tHERD-100\n' > "$T/merged.tsv"     # the sibling that SHIPPED the work
out="$(sweep on)" || fail "(2a) sweep exited non-zero: $out"
[ "$(reqs)" = "1" ] || fail "(2a) the superseded evidence published no intent ($out)"
[ "$(intent_line 1)" = "close-on-evidence" ] || fail "(2a) wrong intent kind: $(intent_line 1)"
[ "$(intent_line 2)" = "HERD-100" ]          || fail "(2a) wrong ref: $(intent_line 2)"
[ "$(intent_line 4)" = "superseded pr=740 via=751" ] \
  || fail "(2a) wrong disposition payload: $(intent_line 4)"
jhas '"event":"intent_evidence_queued"' || fail "(2a) the enqueue was not journaled"
grep -q '^HERD-100 done sweep 751$' "$STUB_UPDATES" \
  || fail "(2a) the merge-evidence half did not heal the item first ($(cat "$STUB_UPDATES"))"
tick
[ "$(reqs)" = "0" ] || fail "(2a) the intent was not consumed"
grep -q '^HERD-100 .*#751' "$STUB_AMENDS" \
  || fail "(2a) no pointer comment naming the PR that shipped it ($(cat "$STUB_AMENDS"))"
grep -q '^HERD-100 canceled' "$STUB_UPDATES" \
  && fail "(2a) the residue re-wrote a terminal the authoritative half had already reached"
grep -q 'intent_evidence_closed .*ref HERD-100' "$JLOG" \
  || fail "(2a) intent_evidence_closed not journaled ($(cat "$JLOG"))"
[ "$(cksum "$MAIN/BACKLOG.md")" = "$BACKLOG_BEFORE" ] || fail "(2a) the sweep edited BACKLOG.md"
pass

# ── (2b) SUPERSEDED with the item STILL OPEN — driven to the closed-NOT-done terminal ────────────
# Nothing marked it Done, and a CLOSED-UNMERGED PR is not evidence of completion, so the doc's verdict
# for this branch applies: closed, NOT done, with the pointer comment. Driven at the CONSUMER through
# the shared library's own publish, so the case is exercised independently of which producer wrote it.
reset
printf 'HERD-150 in-progress\n' > "$STUB_STATES"
( TREES="$TREES"; IQ_ENGINE_DIR="$T/nowhere"
  # shellcheck source=/dev/null
  . "$LIB"; iq_enqueue "$IQ" "close-on-evidence
HERD-150
alice
superseded pr=770 via=771" >/dev/null ) || fail "(2b) could not publish the intent"
tick
[ "$(reqs)" = "0" ] || fail "(2b) the intent was not consumed"
grep -q '^HERD-150 canceled sweep 770$' "$STUB_UPDATES" \
  || fail "(2b) the still-open item was not driven to the closed-NOT-done terminal ($(cat "$STUB_UPDATES"))"
grep -q '^HERD-150 .*#771' "$STUB_AMENDS" \
  || fail "(2b) no pointer comment naming the PR that shipped it ($(cat "$STUB_AMENDS"))"
grep -q 'intent_evidence_closed .*ref HERD-150 result done' "$JLOG" \
  || fail "(2b) intent_evidence_closed not journaled ($(cat "$JLOG"))"
pass

# ── (3) AMBIGUOUS — a merged sibling AND an open one: journal, and do nothing ────────────────────
reset
printf 'HERD-200 in-progress\n' > "$STUB_STATES"
printf '741\tHERD-200\n' > "$T/closed.tsv"
printf '752\tHERD-200\n' > "$T/merged.tsv"
printf '760\tHERD-200\n' > "$T/open.tsv"
out="$(sweep on)" || fail "(3) sweep exited non-zero: $out"
[ -d "$IQ" ] && [ "$(reqs)" != "0" ] && fail "(3) an AMBIGUOUS reading published an intent — the queue decided what only a coordinator may"
jhas '"event":"intent_evidence_ambiguous"' || fail "(3) the ambiguity was not journaled for the coordinator"
# The merge-evidence half may legitimately heal the ref (its merged sibling IS evidence of shipping);
# what must never happen is the RESIDUE writing a terminal of its own off an undecided reading.
grep -q 'canceled' "$STUB_UPDATES" && fail "(3) an ambiguous reading drove a terminal ($(cat "$STUB_UPDATES"))"
[ -s "$STUB_RELEASES" ] && fail "(3) an ambiguous reading released a claim ($(cat "$STUB_RELEASES"))"
awk '$2=="HERD-200" && $4=="ambiguous"{f=1} END{exit !f}' "$HERD_TSWEEP_CLOSED_LEDGER" \
  || fail "(3) the ambiguity was not ledgered — it would re-journal every sweep"
pass

# ── (4) WORK REMAINS — no sibling: the claim is released, the state is left alone ────────────────
reset
printf 'HERD-300 in-progress\n' > "$STUB_STATES"
printf '742\tHERD-300\n' > "$T/closed.tsv"
out="$(sweep on)" || fail "(4) sweep exited non-zero: $out"
[ "$(reqs)" = "1" ] || fail "(4) no intent for the work-remains reading ($out)"
[ "$(intent_line 4)" = "work-remains pr=742" ] || fail "(4) wrong disposition payload: $(intent_line 4)"
tick
[ "$(reqs)" = "0" ] || fail "(4) the intent was not consumed"
grep -q '^HERD-300 ' "$STUB_RELEASES" || fail "(4) the abandoned claim was not released ($(cat "$STUB_RELEASES"))"
[ -s "$STUB_UPDATES" ] && fail "(4) work-remains must NEVER write the workflow state ($(cat "$STUB_UPDATES"))"
grep -q 'intent_evidence_closed .*ref HERD-300 result done' "$JLOG" || fail "(4) the release was not journaled"
# NOTOURS (unassigned, or another operator's claim) is the already-left-open state, not a failure.
reset
printf 'HERD-301 open\n' > "$STUB_STATES"; echo NOTOURS > "$STUB_RELEASE"
printf '743\tHERD-301\n' > "$T/closed.tsv"
sweep on >/dev/null || fail "(4) sweep exited non-zero"
tick
[ "$(reqs)" = "0" ] || fail "(4) a NOTOURS release was retried instead of read as converged"
grep -q 'intent_evidence_closed .*ref HERD-301 result converged' "$JLOG" \
  || fail "(4) the converged release was not journaled honestly ($(cat "$JLOG"))"
pass

# ── (5) IN FLIGHT — an open sibling only: wait, and do not ledger the wait ───────────────────────
reset
printf 'HERD-400 in-progress\n' > "$STUB_STATES"
printf '744\tHERD-400\n' > "$T/closed.tsv"
printf '761\tHERD-400\n' > "$T/open.tsv"
out="$(sweep on)" || fail "(5) sweep exited non-zero: $out"
[ -d "$IQ" ] && [ "$(reqs)" != "0" ] && fail "(5) an in-flight ref published an intent"
[ -s "$HERD_TSWEEP_CLOSED_LEDGER" ] \
  && fail "(5) an in-flight reading was ledgered — it must be re-taken when that PR resolves"
jhas '"event":"intent_evidence_ambiguous"' && fail "(5) a live sibling is not an ambiguity"
pass

# ── (6) RE-GROUND — the item closed between enqueue and drain: CONVERGED, with zero writes ───────
# §4.2's rule, inverted into an assertion: the decision is RE-CHECKED against the item's current
# state, never replayed. A work-remains intent whose item somebody closed in the meantime must not
# un-wedge a claim on it — closing it was curation, and curation stays on the seat (§2.3).
reset
printf 'HERD-500 in-progress\n' > "$STUB_STATES"
printf '745\tHERD-500\n' > "$T/closed.tsv"
sweep on >/dev/null || fail "(6) sweep exited non-zero"
[ "$(reqs)" = "1" ] || fail "(6) no intent to re-ground"
[ "$(intent_line 4)" = "work-remains pr=745" ] || fail "(6) wrong disposition: $(intent_line 4)"
printf 'HERD-500 closed\n' > "$STUB_STATES"     # the world moved between enqueue and drain
: > "$STUB_UPDATES"
tick
[ "$(reqs)" = "0" ] || fail "(6) the converged intent was not consumed"
[ -s "$STUB_UPDATES" ]  && fail "(6) the drain wrote to an item that was ALREADY terminal ($(cat "$STUB_UPDATES"))"
[ -s "$STUB_RELEASES" ] && fail "(6) the drain released a claim on an item that was already terminal"
[ -s "$STUB_AMENDS" ]   && fail "(6) the drain commented on an item that was already terminal"
grep -q 'intent_evidence_closed .*result converged' "$JLOG" || fail "(6) the re-ground skip was not journaled"
pass

# ── (7) TRANSIENT — an unresolvable item releases, accrues attempts, then drops LOUDLY ───────────
reset
printf 'HERD-600 FAIL\n' > "$STUB_STATES"       # the backend cannot answer for this ref
printf '746\tHERD-600\n' > "$T/closed.tsv"
printf '754\tHERD-600\n' > "$T/merged.tsv"
sweep on >/dev/null || fail "(7) sweep exited non-zero"
id="$(basename "$(ls "$IQ"/*.req)" .req)"
tick
[ "$(reqs)" = "1" ] || fail "(7) a transient backend failure must RELEASE the intent"
[ "$(cat "$IQ/$id.attempts" 2>/dev/null)" = "1" ] || fail "(7) the attempt counter did not accrue"
tick; tick
[ "$(reqs)" = "0" ] || fail "(7) an intent past INTENT_MAX_ATTEMPTS must leave the queue"
grep -q 'intent_skipped .*reason max attempts' "$JLOG" || fail "(7) the loud drop was not journaled"
[ -s "$STUB_UPDATES" ] && fail "(7) a state write fired despite an unresolvable item"
pass

# ── (8) IDEMPOTENT — a second sweep over the same evidence publishes nothing new ─────────────────
reset
printf 'HERD-700 in-progress\n' > "$STUB_STATES"
printf '747\tHERD-700\n' > "$T/closed.tsv"
printf '755\tHERD-700\n' > "$T/merged.tsv"
sweep on >/dev/null || fail "(8) first sweep exited non-zero"
[ "$(reqs)" = "1" ] || fail "(8) the first sweep published no intent"
sweep on >/dev/null || fail "(8) second sweep exited non-zero"
[ "$(reqs)" = "1" ] || fail "(8) a re-scan of the SAME evidence duplicated the intent ($(reqs) queued)"
pass

# ── (9) ONE SUBSTRATE — the producer publishes through the shared library, not a copy of it ──────
grep -q 'iq_enqueue "\$WORKTREES_DIR/intent-queue"' "$SWEEP" \
  || fail "(9) tracker-state-sweep.sh does not publish through the shared iq_enqueue"
grep -qE '^\s*mv .*\.req' "$SWEEP" \
  && fail "(9) tracker-state-sweep.sh hand-rolls a queue rename — that is the parallel implementation Phase 2 exists to prevent"
grep -q '_backend_update_state "\$_iea_ref" canceled' "$WATCH" \
  || fail "(9) the drain does not reach the tracker through the existing verified update-state op"
pass

echo "ALL PASS ($PASS checks)"
