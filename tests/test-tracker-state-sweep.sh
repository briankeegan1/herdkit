#!/usr/bin/env bash
# test-tracker-state-sweep.sh — hermetic test of the periodic tracker-state SELF-HEAL sweep
# (scripts/herd/tracker-state-sweep.sh, HERD-86). The sweep re-asserts Done for a recently-merged PR
# whose tracker item drifted (stuck open after merge — the HERD-67/HERD-69 incidents). It drives the
# REAL script against a STUBBED backend that returns a stale state, through the documented seams:
#   HERD_TSWEEP_PRS_FILE · SCRIBE_BACKEND[_DIR] · HERD_TSWEEP_LEDGER · HERD_TSWEEP_NOTE_FILE · JOURNAL_FILE.
#
# Asserts:
#   (1) a stale (in-progress) merged ref IS healed: _backend_update_state fires with target 'done',
#       carrying the HERD-85 attribution (HERD_COMPONENT=sweep + the merged PR#), a tracker_state_healed
#       journal event is written (ref/pr/found-state/component=sweep), and a console note is surfaced.
#   (2) an already-Done (closed) merged ref is NOT healed and never triggers a state write.
#   (3) CONCURRENCY: with several merged refs at once, ONLY the drifted ones heal; the sweep is
#       gate-neutral — it never merges, never edits BACKLOG.md, never touches git.
#   (4) IDEMPOTENT: a second sweep re-reads NOTHING (every healed/clean ref is ledgered) — zero new
#       backend reads, zero new heals, zero new journal events.
#   (5) a heal that FAILS (backend returns NOCHANGE) is journaled as heal_failed, surfaced as a loud
#       'failed' note, and NOT ledgered — so it retries and heals on the next sweep.
#   (6) the default `file` backend (no update-state op) makes the sweep byte-inert.
# Run:  bash tests/test-tracker-state-sweep.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/tracker-state-sweep.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCRIPT" ] || fail "tracker-state-sweep.sh not found at $SCRIPT"

REPO="$T/repo"
mkdir -p "$REPO/.herd" "$T/trees"
export HERD_CONFIG_FILE="$REPO/.herd/config"
cat > "$REPO/.herd/config" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="stub"
EOF
# A BACKLOG.md the sweep must NEVER touch (gate-neutrality proof).
printf '# backlog\n- untouched sentinel line\n' > "$REPO/BACKLOG.md"
BACKLOG_SHA_BEFORE="$(cksum "$REPO/BACKLOG.md")"

# ── stub backend: state read from a file, state write logged to a file ────────
# STUB_STATES: "<ref> <state>" lines (state ∈ open|in-progress|closed|FAIL). Missing ref → open.
#   FAIL simulates a genuine resolve-FAILURE (HERD-411): _backend_item_state returns 1, ITEM_STATE unset
#   — as opposed to a backend explicitly resolving a ref to `open`.
# STUB_RESULTS: "<ref> <result>" lines forcing _backend_update_state's _BACKEND_RESULT (default DONE).
# STUB_UPDATES: appended one "<ref> <want> <component> <pr>" line per _backend_update_state call.
# STUB_READS: appended one "<ref>" line per _backend_item_state call — proves whether a ref was probed.
BACKENDS="$T/backends"; mkdir -p "$BACKENDS"
export STUB_STATES="$T/states.txt"
export STUB_RESULTS="$T/results.txt"
export STUB_UPDATES="$T/updates.log"
export STUB_READS="$T/reads.log"
: > "$STUB_RESULTS"; : > "$STUB_UPDATES"; : > "$STUB_READS"
cat > "$BACKENDS/stub.sh" <<'STUB'
#!/usr/bin/env bash
_backend_item_state() {
  local ref="$1" s
  printf '%s\n' "$ref" >> "$STUB_READS"
  s="$(awk -v r="$ref" '$1==r{print $2; exit}' "$STUB_STATES" 2>/dev/null)"
  if [ "$s" = "FAIL" ]; then
    ITEM_STATE=""
    return 1
  fi
  ITEM_STATE="${s:-open}"
}
_backend_update_state() {
  local ref="$1" want="$2" res
  printf '%s %s %s %s\n' "$ref" "$want" "${HERD_COMPONENT:-none}" "${HERD_TW_PR:-none}" >> "$STUB_UPDATES"
  res="$(awk -v r="$ref" '$1==r{print $2; exit}' "$STUB_RESULTS" 2>/dev/null)"
  _BACKEND_RESULT="${res:-DONE}"
  # A verified DONE flips the stored state to closed (mirrors a real backend's confirmed transition).
  if [ "$_BACKEND_RESULT" = "DONE" ]; then
    awk -v r="$ref" '$1!=r{print} END{print r" closed"}' "$STUB_STATES" > "$STUB_STATES.tmp" 2>/dev/null \
      && mv "$STUB_STATES.tmp" "$STUB_STATES"
  fi
}
STUB
export SCRIBE_BACKEND_DIR="$BACKENDS"

export HERD_TSWEEP_LEDGER="$T/trees/.tracker-swept"
export HERD_TSWEEP_NOTE_FILE="$T/trees/.tracker-heals"
export HERD_TSWEEP_UNRESOLVED_FILE="$T/trees/.tracker-unresolved-counts"
export JOURNAL_FILE="$T/trees/journal.jsonl"

run_sweep() { HERD_TSWEEP_PRS_FILE="$1" bash "$SCRIPT"; }
journal_events() { local n; n="$(grep -c "$1" "$JOURNAL_FILE" 2>/dev/null)"; echo "${n:-0}"; }

# ── fixtures: three merged refs — one stale, one already-Done, one stale ──────
cat > "$STUB_STATES" <<'S'
HERD-67 in-progress
HERD-70 closed
HERD-69 open
S
cat > "$T/prs.tsv" <<'P'
187	HERD-67
205	HERD-70
197	HERD-69
P

# ── (1)+(2)+(3) first sweep: heal the two drifted refs, leave the Done one alone ─
: > "$HERD_TSWEEP_LEDGER" 2>/dev/null || true
out="$(run_sweep "$T/prs.tsv")" || fail "sweep exited non-zero: $out"

# (1) both drifted refs got a verified 'done' write, stamped component=sweep + their merged PR#.
grep -q '^HERD-67 done sweep 187$' "$STUB_UPDATES" || fail "HERD-67 not healed with sweep attribution + PR 187 ($(cat "$STUB_UPDATES"))"
grep -q '^HERD-69 done sweep 197$' "$STUB_UPDATES" || fail "HERD-69 not healed with sweep attribution + PR 197 ($(cat "$STUB_UPDATES"))"
# tracker_state_healed journal events for both.
[ "$(journal_events tracker_state_healed)" -eq 2 ] || fail "expected 2 tracker_state_healed events, got $(journal_events tracker_state_healed)"
grep -q '"event":"tracker_state_healed"' "$JOURNAL_FILE"     || fail "no tracker_state_healed event in journal"
grep -q '"component":"sweep"' "$JOURNAL_FILE"                || fail "heal event not attributed component=sweep"
grep -q '"found_state":"in-progress"' "$JOURNAL_FILE"        || fail "heal event does not record the found (stale) state"
# console notes surfaced for both heals.
grep -q ' healed HERD-67 187 in-progress$' "$HERD_TSWEEP_NOTE_FILE" || fail "no console note for the HERD-67 heal"
grep -q ' healed HERD-69 197 open$'        "$HERD_TSWEEP_NOTE_FILE" || fail "no console note for the HERD-69 heal"
printf '%s\n' "$out" | grep -q 'healed 2' || fail "summary did not report 2 heals ($out)"
pass

# (2) the already-Done ref was NEVER written.
grep -q '^HERD-70 ' "$STUB_UPDATES" && fail "an already-Done ref (HERD-70) was needlessly written"
pass

# (3) gate-neutral: BACKLOG.md untouched, no failures.
[ "$(cksum "$REPO/BACKLOG.md")" = "$BACKLOG_SHA_BEFORE" ] || fail "sweep modified BACKLOG.md — must be gate-neutral"
[ "$(journal_events tracker_state_heal_failed)" -eq 0 ] || fail "unexpected heal_failed event on the happy path"
pass

# ── (4) idempotent: a second identical sweep re-reads/heals/journals NOTHING ───
: > "$STUB_UPDATES"
before_events="$(grep -c . "$JOURNAL_FILE" 2>/dev/null || echo 0)"
out2="$(run_sweep "$T/prs.tsv")" || fail "second sweep exited non-zero"
[ -s "$STUB_UPDATES" ] && fail "idempotent sweep re-issued a state write ($(cat "$STUB_UPDATES"))"
after_events="$(grep -c . "$JOURNAL_FILE" 2>/dev/null || echo 0)"
[ "$before_events" -eq "$after_events" ] || fail "idempotent sweep wrote new journal events ($before_events → $after_events)"
printf '%s\n' "$out2" | grep -q 'no tracker drift' || fail "second sweep should report no drift ($out2)"
pass

# ── (5) a heal that FAILS is journaled + surfaced as 'failed' and retries next sweep ─
: > "$HERD_TSWEEP_LEDGER"; : > "$STUB_UPDATES"; : > "$HERD_TSWEEP_NOTE_FILE"
cat > "$STUB_STATES" <<'S'
HERD-88 in-progress
S
printf '188\tHERD-88\n' > "$T/prs2.tsv"
echo 'HERD-88 NOCHANGE' > "$STUB_RESULTS"          # force the backend write to fail (unverified)
out="$(run_sweep "$T/prs2.tsv" 2>/dev/null)" || fail "failing-heal sweep exited non-zero"
[ "$(journal_events tracker_state_heal_failed)" -ge 1 ] || fail "a failed heal was not journaled"
grep -q ' failed HERD-88 188 in-progress$' "$HERD_TSWEEP_NOTE_FILE" || fail "failed heal not surfaced as a 'failed' note"
awk '$2=="HERD-88"{f=1} END{exit !f}' "$HERD_TSWEEP_LEDGER" 2>/dev/null && fail "a FAILED heal must NOT be ledgered (it must retry)"
# Now let the write succeed — the retry heals it (proves 'stays visible, retries next sweep').
: > "$STUB_RESULTS"
run_sweep "$T/prs2.tsv" >/dev/null 2>&1 || fail "retry sweep exited non-zero"
grep -q '^HERD-88 done sweep 188$' "$STUB_UPDATES" || fail "retry did not heal the previously-failed ref"
awk '$2=="HERD-88"{f=1} END{exit !f}' "$HERD_TSWEEP_LEDGER" 2>/dev/null || fail "successful retry should ledger the ref"
pass

# ── (5b) REAL gh-output parse path: a MULTI-LINE PR body with a mid-body 'Refs:' line ──
# Regression guard for the live-repo defect the PRS_FILE seam masked: gh returns MULTI-LINE bodies, so
# a line-oriented parse only ever saw each body's first line and dropped the deeper 'Refs:' line (a
# repo of ref-carrying merges scanned 0). Feed the RAW `gh pr list --json` JSON through the real parse.
: > "$HERD_TSWEEP_LEDGER"; : > "$STUB_UPDATES"; : > "$HERD_TSWEEP_NOTE_FILE"
cat > "$STUB_STATES" <<'S'
HERD-91 in-progress
S
# Realistic bodies: PR #211's 'Refs:' is buried under many lines (and a decoy in an HTML comment);
# PR #212 carries no ref at all.
python3 - "$T/prs.json" <<'PY'
import sys, json
prs = [
  {"number": 211, "body": "## What\n\nHeal drift.\n\n<!-- Refs: HERD-DECOY (template example, must be ignored) -->\n\nMore prose here.\nAnd another line.\n\nRefs: HERD-91\n\n🤖 Generated with Claude Code\n"},
  {"number": 212, "body": "## What\n\nUnrelated change with a multi-line body\nbut no Refs line at all.\n"},
]
open(sys.argv[1], "w").write(json.dumps(prs))
PY
out="$(HERD_TSWEEP_PRS_JSON_FILE="$T/prs.json" bash "$SCRIPT")" || fail "json-parse sweep exited non-zero: $out"
printf '%s\n' "$out" | grep -q 'healed 1' || fail "json-parse run did not report the single heal ($out)"
grep -q '^HERD-91 done sweep 211$' "$STUB_UPDATES" \
  || fail "multi-line body: mid-body 'Refs: HERD-91' was not parsed/healed from real gh JSON ($(cat "$STUB_UPDATES"))"
# The HTML-comment decoy ref must never be healed, and the ref-less PR must be skipped.
grep -q 'HERD-DECOY' "$STUB_UPDATES" && fail "an HTML-comment decoy Refs was wrongly parsed"
[ "$(grep -c . "$STUB_UPDATES")" -eq 1 ] || fail "expected exactly ONE heal from the JSON path, got $(grep -c . "$STUB_UPDATES")"
pass

# ── (7) HERD-411: a resolve-FAILURE ref goes silent, then ledgers after N sweeps with ONE event ─
: > "$HERD_TSWEEP_LEDGER"; : > "$HERD_TSWEEP_UNRESOLVED_FILE"; : > "$STUB_UPDATES"; : > "$STUB_READS"
: > "$HERD_TSWEEP_NOTE_FILE"; : > "$JOURNAL_FILE"
cat > "$STUB_STATES" <<'S'
HERD-99 FAIL
S
printf '199\tHERD-99\n' > "$T/prs3.tsv"

out="$(run_sweep "$T/prs3.tsv")" || fail "sweep 1/3 (resolve-failure) exited non-zero: $out"
[ "$(journal_events tracker_state_unresolvable)" -eq 0 ] || fail "escalated on sweep 1 (too early)"
awk '$2=="HERD-99"{f=1} END{exit !f}' "$HERD_TSWEEP_LEDGER" 2>/dev/null && fail "ledgered on sweep 1 (too early)"
[ -s "$HERD_TSWEEP_NOTE_FILE" ] && fail "a resolve-failure must never write the console-note ledger (sweep 1)"

out="$(run_sweep "$T/prs3.tsv")" || fail "sweep 2/3 (resolve-failure) exited non-zero: $out"
[ "$(journal_events tracker_state_unresolvable)" -eq 0 ] || fail "escalated on sweep 2 (too early)"

out="$(run_sweep "$T/prs3.tsv")" || fail "sweep 3/3 (resolve-failure) exited non-zero: $out"
[ "$(journal_events tracker_state_unresolvable)" -eq 1 ] || fail "expected exactly 1 tracker_state_unresolvable event by sweep 3, got $(journal_events tracker_state_unresolvable)"
grep -q '"ref":"HERD-99"' "$JOURNAL_FILE"                     || fail "unresolvable event does not name HERD-99"
awk '$2=="HERD-99"{f=1} END{exit !f}' "$HERD_TSWEEP_LEDGER" 2>/dev/null || fail "HERD-99 was not ledgered as unresolvable after 3 sweeps"
grep -qF 'HERD-99' "$HERD_TSWEEP_UNRESOLVED_FILE" 2>/dev/null && fail "the per-ref counter should be cleared once ledgered"
[ -s "$HERD_TSWEEP_NOTE_FILE" ] && fail "an unresolvable ref must never write the console-note ledger (it would render as a permanent loud row)"
[ "$(journal_events tracker_state_heal_failed)" -eq 0 ] || fail "a resolve-failure must never journal tracker_state_heal_failed"
reads_before="$(grep -c . "$STUB_READS" 2>/dev/null || echo 0)"

# Once ledgered, a 4th sweep must never probe the backend again for HERD-99.
: > "$STUB_READS"
out="$(run_sweep "$T/prs3.tsv")" || fail "sweep 4 (post-unresolvable) exited non-zero: $out"
[ -s "$STUB_READS" ] && fail "a ledgered-unresolvable ref must never be re-probed ($(cat "$STUB_READS"))"
[ "$(journal_events tracker_state_unresolvable)" -eq 1 ] || fail "sweep 4 must not re-journal tracker_state_unresolvable"
pass

# ── (8) HERD-411: a genuinely-open ref among resolve-failures still heals exactly as today ────
: > "$HERD_TSWEEP_LEDGER"; : > "$HERD_TSWEEP_UNRESOLVED_FILE"; : > "$STUB_UPDATES"; : > "$JOURNAL_FILE"; : > "$HERD_TSWEEP_NOTE_FILE"
cat > "$STUB_STATES" <<'S'
HERD-100 open
S
printf '200\tHERD-100\n' > "$T/prs4.tsv"
out="$(run_sweep "$T/prs4.tsv")" || fail "sweep (genuinely-open) exited non-zero: $out"
grep -q '^HERD-100 done sweep 200$' "$STUB_UPDATES" || fail "a genuinely-open ref must still heal unchanged ($(cat "$STUB_UPDATES"))"
printf '%s\n' "$out" | grep -q 'healed 1' || fail "genuinely-open ref should report 1 heal ($out)"
pass

# ── (9) HERD-411: a bare github-shaped ref under the (non-github) stub backend classifies
#        unresolvable IMMEDIATELY — no waiting for N sweeps, and the backend is NEVER even probed ──
: > "$HERD_TSWEEP_LEDGER"; : > "$HERD_TSWEEP_UNRESOLVED_FILE"; : > "$STUB_UPDATES"; : > "$STUB_READS"
: > "$JOURNAL_FILE"; : > "$HERD_TSWEEP_NOTE_FILE"
: > "$STUB_STATES"      # the backend has NOTHING for #514 — proves it's never even asked
printf '515\t#514\n' > "$T/prs5.tsv"
out="$(run_sweep "$T/prs5.tsv")" || fail "sweep (shape-mismatch) exited non-zero: $out"
[ "$(journal_events tracker_state_unresolvable)" -eq 1 ] || fail "shape-mismatch did not journal exactly 1 tracker_state_unresolvable event ($out)"
grep -q '"ref":"#514"' "$JOURNAL_FILE"                        || fail "unresolvable event does not name #514"
awk '$2=="#514"{f=1} END{exit !f}' "$HERD_TSWEEP_LEDGER" 2>/dev/null || fail "#514 was not ledgered as unresolvable"
[ -s "$STUB_READS" ] && fail "a ref-shape mismatch must never probe the backend at all ($(cat "$STUB_READS"))"
[ -s "$STUB_UPDATES" ] && fail "a ref-shape mismatch must never attempt a state write"
[ -s "$HERD_TSWEEP_NOTE_FILE" ] && fail "a shape-mismatch ref must never write the console-note ledger"
pass

# ── (6) the file backend (no update-state op) makes the sweep byte-inert ───────
cat > "$REPO/.herd/config" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
EOF
: > "$STUB_UPDATES"
out="$(unset SCRIBE_BACKEND_DIR; run_sweep "$T/prs.tsv")" || fail "file-backend sweep exited non-zero"
printf '%s\n' "$out" | grep -qi 'inert' || fail "file backend should report the sweep is inert ($out)"
[ -s "$STUB_UPDATES" ] && fail "file backend must not dispatch any state write"
pass

echo "ALL PASS ($PASS checks)"
