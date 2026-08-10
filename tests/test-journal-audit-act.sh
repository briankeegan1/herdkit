#!/usr/bin/env bash
# test-journal-audit-act.sh — hermetic proof that journal-audit FINDINGS BECOME ACTIONS (HERD-544).
#
# Drives the REAL scripts/herd/journal-audit.sh against synthetic journals with JOURNAL_AUDIT_ACT on,
# through the documented action seams (HERD_JOURNAL_AUDIT_ACT_CMD, HERD_JOURNAL_AUDIT_SCRIBE_CMD), so
# no action ever reaches a live control room: the rail stub RECORDS the class/key/ctx it was handed
# and prints a result token; the scribe stub RECORDS each filed request. Asserts, as the item's
# verification legs require:
#   (1) FLAG OFF is byte-identical advisory-only — no rail invocation, no scribe call, no audit_acted
#       event, and the journal_audit findings + inbox rows are byte-for-byte what the auditor emitted
#       before this feature existed.
#   (2) An orphaned dispatch (dispatch_no_outcome) RE-DISPATCHES ONCE — one rail call, journaled
#       audit_acted result=<token> — and THEN, with the finding still standing, escalates exactly
#       once and never acts again, however many sweeps run.
#   (3) An UNMAPPED finding class files EXACTLY ONE deduped tracker item, and never a second one on
#       any later sweep (its filing is terminal — it can never escalate into a duplicate).
#   (4) Each mapped class is routed to the rail with the CONTEXT it needs (pr/sha/slug/round), and
#       every class journal-audit.sh claims to map is a class journal-act.sh actually has an arm for.
#   (5) The action is at most ONCE PER FINDING KEY even when the finding is already in the seen-ledger
#       (muting the REPORT must never mute the HEAL — and must never re-fire it either).
#   (6) FAIL-SOFT: a rail that fails/prints nothing, and a scribe that fails, both still journal an
#       honest result and never fail the sweep.
#   (7) BOUNDED: at most HERD_JOURNAL_AUDIT_ACT_MAX actions fire per sweep; the findings not reached
#       are acted on the next sweep, never dropped.
#   (8) journal-act.sh itself answers an UNKNOWN class `unmapped` with no control room at all.
#   HERD-600: watcher_restart_blocked and checkout_unclean are DELIBERATE no-action classes ((3e)/(3f)),
#       same shape as (3b)/(3c), and recurrence-escalate via (3d)'s machinery like any other no-action
#       class. HERD-602 (3g): an unmapped class dedups its filing on the CLASS, not the per-finding key
#       — two distinct keys of the same unmapped class in one sweep, or across sweeps, still file only
#       ONE tracker item, ever. HERD-606: merged_hv_no_approval is ALSO a deliberate no-action class
#       (3h), same shape and same #723 pattern as (3e)/(3f); and (3i) proves the per-class recurrence
#       high-water mark — a historical journal replay of an ALREADY-counted event must never inflate
#       the recurrence tally, even when the once-guard's own per-key protection is lost.
#
# Fully hermetic: writes only under a mktemp dir; the shared-pool once-guard lands in the temp
# WORKTREES_DIR, so the at-most-once guarantee is proven against the REAL store, not a stub.
# Run:  bash tests/test-journal-audit-act.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/scripts/herd/journal-audit.sh"
ACT="$REPO/scripts/herd/journal-act.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCRIPT" ] || fail "journal-audit.sh not found at $SCRIPT"
[ -f "$ACT" ] || fail "journal-act.sh not found at $ACT"

REPO_FIX="$T/repo"
mkdir -p "$REPO_FIX/.herd" "$T/trees/.herd"
export HERD_CONFIG_FILE="$REPO_FIX/.herd/config"
cat > "$REPO_FIX/.herd/config" <<EOF
PROJECT_ROOT="$REPO_FIX"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="main"
EOF

export JOURNAL_FILE="$T/trees/.herd/journal.jsonl"
export HERD_JOURNAL_AUDIT_INBOX="$T/trees/.agent-watch-inbox"
export HERD_JOURNAL_AUDIT_SEEN="$T/trees/.agent-watch-journal-audit-seen"
export HERD_JOURNAL_AUDIT_PENDING="$T/trees/.agent-watch-journal-audit-pending"
export HERD_JOURNAL_AUDIT_NOACTION_COUNT="$T/trees/.agent-watch-journal-audit-noaction-count"
export HERD_APPROVALS_FILE="$T/trees/.agent-watch-approvals"
# PR-body source: check (g) is not the main subject of this file, so the default (no per-pr override
# file) is an empty body — declares no HUMAN-VERIFY block. (2d) below drives the merged_hv_unknown
# no-action class through the same seam by dropping a "$pr.fail" marker.
export HERD_JOURNAL_AUDIT_PR_BODY_CMD="bash $T/pr-body.sh"
mkdir -p "$T/bodies"
cat > "$T/pr-body.sh" <<'FIXTURE'
#!/usr/bin/env bash
pr="$1"
[ -f "$T/bodies/$pr.fail" ] && exit 7
[ -f "$T/bodies/$pr.md" ] && exec cat "$T/bodies/$pr.md"
exit 0
FIXTURE
export HERD_JOURNAL_AUDIT_NOW="2026-08-05T16:00:00Z"
export JOURNAL_AUDIT_WINDOW_SECS=86400
export JOURNAL_AUDIT_DISPATCH_TTL=600
export JOURNAL_AUDIT_REFIX_TTL=120
export JOURNAL_AUDIT_RED_TTL=600
export JOURNAL_AUDIT_MERGE_GRACE=60
export JOURNAL_AUDIT_PUSHED_GRACE=120

# ── stubs for the two action seams ───────────────────────────────────────────────────────────────
RAILLOG="$T/rail.log"        # one "<class>|<key>|<ctx…>" line per rail invocation
SCRIBELOG="$T/scribe.log"    # one record per filed tracker request (blank-line separated)
RAILRESULT="$T/rail.result"  # what the stub prints back as the result token
cat > "$T/rail.sh" <<'RAIL'
#!/usr/bin/env bash
# Stands in for scripts/herd/journal-act.sh: records the invocation, prints the pinned result token.
cls="$1"; key="$2"; shift 2
printf '%s|%s|%s\n' "$cls" "$key" "$*" >> "$RAILLOG"
[ -f "$T/rail.fail" ] && exit 4          # fail-soft leg: rail dies with no output
cat "$RAILRESULT" 2>/dev/null || printf 'slot_freed\n'
RAIL
cat > "$T/scribe.sh" <<'SCRIBE'
#!/usr/bin/env bash
# Stands in for scripts/herd/scribe.sh: records the request text; never spawns a drainer.
[ -f "$T/scribe.fail" ] && exit 9
{ printf '%s\n' "$1"; printf -- '--8<--\n'; } >> "$SCRIBELOG"
SCRIBE
export T RAILLOG SCRIBELOG RAILRESULT
export HERD_JOURNAL_AUDIT_ACT_CMD="bash $T/rail.sh"
export HERD_JOURNAL_AUDIT_SCRIBE_CMD="bash $T/scribe.sh"
printf 'slot_freed\n' > "$RAILRESULT"

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────
jline() { printf '{"ts":"%s",%s}\n' "$1" "$2" >> "$JOURNAL_FILE"; }
reset_surfaces() {
  # The shared-pool once-guard is REAL (pysrc/herd/store.py, whichever backend it resolves) and its
  # state lives under $WORKTREES_DIR/.herd — so the pool is wiped WHOLESALE between cases rather than
  # by guessing a backend's file layout, and each case starts with every guard unclaimed.
  rm -rf "$T/trees/.herd" 2>/dev/null || true
  mkdir -p "$T/trees/.herd"
  : > "$JOURNAL_FILE"; : > "$HERD_JOURNAL_AUDIT_INBOX"
  rm -f "$HERD_JOURNAL_AUDIT_SEEN" "$HERD_JOURNAL_AUDIT_PENDING" "$HERD_JOURNAL_AUDIT_NOACTION_COUNT" "$RAILLOG" "$SCRIBELOG" "$T/rail.fail" "$T/scribe.fail"
  # HERD-606: the per-class no-action recurrence high-water mark lives in the shared pool (pool-root
  # .agent-watch-noaction-hwm-<class> flat files, or the sqlite backend once one engages) and — like
  # the once-guard state under .herd/ above — is deliberately NOT reset by the "wipe .herd wholesale"
  # line: it is meant to survive a restart. Between UNRELATED test cases it must still start fresh, or
  # a later case's identical event timestamp reads as "already counted" by an earlier case's mark.
  rm -f "$T"/trees/.agent-watch-noaction-hwm-* 2>/dev/null || true
}
run_audit() {  # run_audit <on|off> [extra KEY=VALUE env assignments…]
  # `env` (not a bare assignment prefix): a QUOTED "${@:2}" expansion is a command word to bash, not a
  # parsed assignment, so the extra KEY=VALUE args must be handed to a program that applies them.
  env JOURNAL_AUDIT=on JOURNAL_AUDIT_ACT="$1" "${@:2}" bash "$SCRIPT" 2>&1
}
count_event() { grep -c "\"event\":\"$1\"" "$JOURNAL_FILE" 2>/dev/null | tr -cd '0-9'; }
rail_calls() { [ -f "$RAILLOG" ] && grep -c . "$RAILLOG" 2>/dev/null | tr -cd '0-9' || printf 0; }
scribe_calls() { [ -f "$SCRIBELOG" ] && grep -c -- '--8<--' "$SCRIBELOG" 2>/dev/null | tr -cd '0-9' || printf 0; }

# An orphaned review dispatch: dispatched 2h back, no verdict ever recorded (past DISPATCH_TTL).
seed_orphan_dispatch() {
  jline "2026-08-05T14:00:00Z" '"event":"review_dispatched","pr":700,"sha":"deadbeef1234","slug":"orphan-lane"'
}

# ── (1) FLAG OFF is byte-identical advisory-only ─────────────────────────────────────────────────
# The strongest form of "ship-dormant": run the SAME dirty journal twice — once with the ACT lever off
# and once against a pristine copy of the pre-feature surfaces — and require the emitted journal_audit
# lines and inbox rows to match byte-for-byte, with zero rail/scribe invocations and no audit_acted.
reset_surfaces
seed_orphan_dispatch
jline "2026-08-05T14:00:00Z" '"event":"codemap_refresh","pushed":"no"'      # an UNMAPPED class
out="$(run_audit off)" || fail "(1) audit exited non-zero with the ACT lever off: $out"
[ "$(rail_calls)" = "0" ] || fail "(1) ACT off must never invoke a rail, got $(rail_calls) call(s)"
[ "$(scribe_calls)" = "0" ] || fail "(1) ACT off must never file a tracker item, got $(scribe_calls)"
[ "$(count_event audit_acted)" = "0" ] || fail "(1) ACT off must journal no audit_acted event"
grep -q '"event":"journal_audit"' "$JOURNAL_FILE" || fail "(1) ACT off must still REPORT findings"
off_findings="$(grep '"event":"journal_audit"' "$JOURNAL_FILE" | sed 's/"ts":"[^"]*",//')"
# Drop field 1 (the epoch) so the comparison is of CONTENT, not of when the two runs happened.
off_inbox="$(cut -f2- "$HERD_JOURNAL_AUDIT_INBOX")"
[ -n "$off_inbox" ] || fail "(1) ACT off must still write advisory inbox rows"
# Same journal, lever ON: the REPORT half must be unchanged (only actions are added).
reset_surfaces
seed_orphan_dispatch
jline "2026-08-05T14:00:00Z" '"event":"codemap_refresh","pushed":"no"'
out="$(run_audit on)" || fail "(1) audit exited non-zero with the ACT lever on: $out"
on_findings="$(grep '"event":"journal_audit"' "$JOURNAL_FILE" | sed 's/"ts":"[^"]*",//')"
# The ACTION rows carry their own refs (field 3: audit-act:/audit-escalated:) — strip them and the
# ADVISORY rows that remain must be exactly what the lever-off run wrote.
on_inbox="$(awk -F'\t' '$3 !~ /^audit-(act|escalated):/' "$HERD_JOURNAL_AUDIT_INBOX" | cut -f2-)"
[ "$off_findings" = "$on_findings" ] || fail "(1) the REPORT half must be byte-identical with the lever on:
--- off ---
$off_findings
--- on ---
$on_findings"
[ "$off_inbox" = "$on_inbox" ] || fail "(1) the advisory inbox rows must be byte-identical with the lever on"
pass
echo "PASS (1) JOURNAL_AUDIT_ACT=off is byte-identical advisory-only; on adds actions without changing findings"

# ── (2) orphaned dispatch acts ONCE, then escalates after JOURNAL_AUDIT_ESCALATE_AFTER re-observations,
#        then is silent forever ─────────────────────────────────────────────────────────────────────
reset_surfaces
seed_orphan_dispatch
out="$(run_audit on)" || fail "(2) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2) sweep 1 must drive the rail exactly once, got $(rail_calls)"
grep -q '^dispatch_no_outcome|' "$RAILLOG" || fail "(2) the rail must be handed the dispatch_no_outcome class: $(cat "$RAILLOG")"
[ "$(count_event audit_acted)" = "1" ] || fail "(2) sweep 1 must journal exactly one audit_acted"
grep -q '"result":"slot_freed"' "$JOURNAL_FILE" || fail "(2) the rail's result token must be journaled verbatim"
[ "$(scribe_calls)" = "0" ] || fail "(2) a MAPPED class must not file an item on its first action"
# Sweep 2: the finding is STILL in the journal, but this is only the FIRST re-observation — the
# default JOURNAL_AUDIT_ESCALATE_AFTER=2 grants one sweep of grace (HERD-564/573: escalating on the
# very next sighting was the pre-fix bug — reverify_pending in particular needs time to land). No
# re-act (once per key), no escalation yet.
out="$(run_audit on)" || fail "(2) sweep 2 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2) sweep 2 must NOT re-drive the rail (once per key), got $(rail_calls)"
[ "$(count_event audit_acted)" = "1" ] || fail "(2) sweep 2 is still within the grace window — no escalation yet"
[ "$(scribe_calls)" = "0" ] || fail "(2) sweep 2 must not file anything yet, got $(scribe_calls)"
# Sweep 3: the SECOND re-observation reaches JOURNAL_AUDIT_ESCALATE_AFTER=2 → escalate LOUDLY, once.
out="$(run_audit on)" || fail "(2) sweep 3 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2) sweep 3 must NOT re-drive the rail (once per key), got $(rail_calls)"
[ "$(count_event audit_acted)" = "2" ] || fail "(2) sweep 3 must journal the escalation as an audit_acted"
grep -q '"result":"escalated"' "$JOURNAL_FILE" || fail "(2) sweep 3 must journal result=escalated"
[ "$(scribe_calls)" = "1" ] || fail "(2) the escalation must file exactly one item, got $(scribe_calls)"
grep -q 'audit-escalated:dispatch_no_outcome' "$HERD_JOURNAL_AUDIT_INBOX" || fail "(2) the escalation must be LOUD in the operator inbox"
# Sweeps 4+: fully silent — no re-act, no second escalation, no duplicate item, no more pending tracking.
out="$(run_audit on)" || fail "(2) sweep 4 exited non-zero: $out"
out="$(run_audit on)" || fail "(2) sweep 5 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2) a settled finding must never re-act, got $(rail_calls) rail call(s)"
[ "$(count_event audit_acted)" = "2" ] || fail "(2) a settled finding must journal no further audit_acted"
[ "$(scribe_calls)" = "1" ] || fail "(2) a settled finding must never file a second item"
[ ! -s "$HERD_JOURNAL_AUDIT_PENDING" ] || fail "(2) an escalated finding must stop being tracked: $(cat "$HERD_JOURNAL_AUDIT_PENDING")"
pass
echo "PASS (2) orphaned dispatch acts once, escalates after the grace window, then is permanently silent"

# ── (2b) JOURNAL_AUDIT_ESCALATE_AFTER=1 reproduces the immediate-next-sighting escalate (N=1) ──────
reset_surfaces
seed_orphan_dispatch
out="$(run_audit on JOURNAL_AUDIT_ESCALATE_AFTER=1)" || fail "(2b) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2b) sweep 1 must act once, got $(rail_calls)"
out="$(run_audit on JOURNAL_AUDIT_ESCALATE_AFTER=1)" || fail "(2b) sweep 2 exited non-zero: $out"
[ "$(count_event audit_acted)" = "2" ] || fail "(2b) with ESCALATE_AFTER=1, sweep 2 must already escalate"
grep -q '"result":"escalated"' "$JOURNAL_FILE" || fail "(2b) sweep 2 must journal result=escalated"
pass
echo "PASS (2b) JOURNAL_AUDIT_ESCALATE_AFTER is a live configurable seam (1 = escalate on the very next sighting)"

# ── (2c) a MAPPED finding that CLEARS after its action journals audit_finding_cleared, never escalates
reset_surfaces
jline "2026-08-05T13:00:00Z" '"event":"main_health","pr":900,"sha":"cafe9000","result":"red","failed":"tests/x.sh"'
out="$(run_audit on)" || fail "(2c) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2c) sweep 1 must drive the re-verify rail once, got $(rail_calls)"
grep -q '^red_state_stale|' "$RAILLOG" || fail "(2c) the rail must be handed the red_state_stale class: $(cat "$RAILLOG")"
[ -s "$HERD_JOURNAL_AUDIT_PENDING" ] || fail "(2c) an acted mapped finding must be tracked as pending"
# The re-verify's result LANDS: a green after the red — exactly what reconcile_main_health's own
# cadence would eventually journal, whether the rail armed it or (reverify_pending) merely observed
# that a check was already owed. The auditor must CONSUME this, not just stop finding the row by luck.
jline "2026-08-05T13:05:00Z" '"event":"main_health","pr":901,"sha":"cafe9001","result":"green"'
out="$(run_audit on)" || fail "(2c) sweep 2 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2c) a cleared finding must never re-drive the rail, got $(rail_calls)"
grep -q '"event":"audit_finding_cleared"' "$JOURNAL_FILE" || fail "(2c) a resolved finding must journal audit_finding_cleared"
grep -q '"class":"red_state_stale"' "$JOURNAL_FILE" || fail "(2c) the cleared event must name its class"
grep -q 'audit-cleared:red_state_stale' "$HERD_JOURNAL_AUDIT_INBOX" || fail "(2c) a cleared finding must get an advisory inbox row"
[ ! -s "$HERD_JOURNAL_AUDIT_PENDING" ] || fail "(2c) a cleared finding must stop being tracked: $(cat "$HERD_JOURNAL_AUDIT_PENDING")"
# Further sweeps: no escalation ever fires for a key that already cleared.
out="$(run_audit on)" || fail "(2c) sweep 3 exited non-zero: $out"
[ "$(count_event audit_acted)" = "1" ] || fail "(2c) a cleared finding must never escalate, got $(count_event audit_acted) audit_acted event(s)"
[ "$(scribe_calls)" = "0" ] || fail "(2c) a cleared finding must never file anything, got $(scribe_calls)"
pass
echo "PASS (2c) a mapped finding that resolves journals audit_finding_cleared and stops tracking"

# ── (2d) red_state_stale RE-CONFIRMS for the SAME sha across multiple sweeps — it must dedupe to ONE
#         tracked finding and converge (escalate), never spawn a fresh PENDING row per re-confirmation
#         (HERD-597). reconcile_main_health re-journals `main_health result=red` on its own cadence
#         while a red stands, so the pre-fix key (sha+the red EVENT's own ts) turned every
#         re-confirmation into a BRAND NEW finding — the live PENDING ledger held three such orphaned
#         rows for the SAME sha, all count=1, none ever reaching JOURNAL_AUDIT_ESCALATE_AFTER ────────
reset_surfaces
jline "2026-08-05T13:00:00Z" '"event":"main_health","pr":902,"sha":"d5ef2756","result":"red","failed":"tests/y.sh"'
out="$(run_audit on)" || fail "(2d) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2d) sweep 1 must drive the re-verify rail once, got $(rail_calls)"
[ "$(wc -l < "$HERD_JOURNAL_AUDIT_PENDING" | tr -cd '0-9')" = "1" ] || fail "(2d) sweep 1 must track exactly one pending row, got: $(cat "$HERD_JOURNAL_AUDIT_PENDING")"
# A re-confirmation: a FRESH main_health red event, same sha, no green in between. This must not read
# as a brand-new finding.
jline "2026-08-05T13:10:00Z" '"event":"main_health","pr":902,"sha":"d5ef2756","result":"red","failed":"tests/y.sh"'
out="$(run_audit on)" || fail "(2d) sweep 2 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2d) a re-confirmed red must never re-drive the rail, got $(rail_calls)"
[ "$(wc -l < "$HERD_JOURNAL_AUDIT_PENDING" | tr -cd '0-9')" = "1" ] || fail "(2d) a re-confirmed red must still track exactly ONE pending row, got: $(cat "$HERD_JOURNAL_AUDIT_PENDING")"
[ "$(count_event audit_acted)" = "1" ] || fail "(2d) sweep 2 is within the grace window — no escalation yet"
# A second re-confirmation, still the same sha: the second re-observation the lifecycle pass sees
# (JOURNAL_AUDIT_ESCALATE_AFTER default 2) — escalate LOUDLY, exactly once, for the single tracked row.
jline "2026-08-05T13:20:00Z" '"event":"main_health","pr":902,"sha":"d5ef2756","result":"red","failed":"tests/y.sh"'
out="$(run_audit on)" || fail "(2d) sweep 3 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2d) escalation must never re-drive the rail, got $(rail_calls)"
[ "$(count_event audit_acted)" = "2" ] || fail "(2d) sweep 3 must escalate the single tracked finding"
grep -q '"result":"escalated"' "$JOURNAL_FILE" || fail "(2d) sweep 3 must journal result=escalated"
[ "$(scribe_calls)" = "1" ] || fail "(2d) the escalation must file exactly one item, got $(scribe_calls)"
[ ! -s "$HERD_JOURNAL_AUDIT_PENDING" ] || fail "(2d) an escalated finding must stop being tracked: $(cat "$HERD_JOURNAL_AUDIT_PENDING")"
# Further re-confirmations of the same sha: fully silent — the finding already settled.
jline "2026-08-05T13:30:00Z" '"event":"main_health","pr":902,"sha":"d5ef2756","result":"red","failed":"tests/y.sh"'
out="$(run_audit on)" || fail "(2d) sweep 4 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2d) a settled finding must never re-act, got $(rail_calls)"
[ "$(count_event audit_acted)" = "2" ] || fail "(2d) a settled finding must journal no further audit_acted"
[ "$(scribe_calls)" = "1" ] || fail "(2d) a settled finding must never file a second item"
pass
echo "PASS (2d) red_state_stale re-confirmations of the same sha dedupe to one tracked finding and converge (HERD-597)"

# ── (2e) HERD-631 leg a: SHA-AGNOSTIC DEDUP — a SECOND sha under the SAME main_health
#         dispatch_no_outcome class refreshes the ONE tracked finding instead of triggering a second
#         action or a second filed item (the pre-fix shape that produced HERD-627/628/629: three
#         distinct shas of what was really one gap, each escalating into its own duplicate item) ──────
reset_surfaces
jline "2026-08-05T12:00:00Z" '"event":"main_health","pr":"?","sha":"aaaa1111","result":"dispatched","pid":1'
out="$(run_audit on)" || fail "(2e) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2e) sweep 1 must drive the rail exactly once, got $(rail_calls)"
grep -q '^dispatch_no_outcome|dispatch_no_outcome|main_health|' "$RAILLOG" || fail "(2e) the rail must be handed the bucketed (sha-less) key: $(cat "$RAILLOG")"
[ "$(wc -l < "$HERD_JOURNAL_AUDIT_PENDING" | tr -cd '0-9')" = "1" ] || fail "(2e) sweep 1 must track exactly one pending row, got: $(cat "$HERD_JOURNAL_AUDIT_PENDING")"
# A SECOND, distinct sha — a fresh corpse under the SAME rail (main_health), still unresolved. This
# must refresh the ONE tracked finding, never act again and never file a second item.
jline "2026-08-05T12:30:00Z" '"event":"main_health","pr":"?","sha":"bbbb2222","result":"dispatched","pid":2'
out="$(run_audit on)" || fail "(2e) sweep 2 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2e) a second sha under the same class must NOT re-drive the rail, got $(rail_calls)"
[ "$(wc -l < "$HERD_JOURNAL_AUDIT_PENDING" | tr -cd '0-9')" = "1" ] || fail "(2e) a second sha under the same class must still track exactly ONE pending row, got: $(cat "$HERD_JOURNAL_AUDIT_PENDING")"
[ "$(scribe_calls)" = "0" ] || fail "(2e) a second sha under the same class must not file anything yet, got $(scribe_calls)"
[ "$(count_event audit_acted)" = "1" ] || fail "(2e) sweep 2 is within the grace window — no escalation yet"
# A third sha, past JOURNAL_AUDIT_ESCALATE_AFTER=2 re-observations of the SAME tracked finding →
# escalate LOUDLY exactly once — for the single tracked row, never per-sha.
jline "2026-08-05T13:00:00Z" '"event":"main_health","pr":"?","sha":"cccc3333","result":"dispatched","pid":3'
out="$(run_audit on)" || fail "(2e) sweep 3 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2e) escalation must never re-drive the rail, got $(rail_calls)"
[ "$(count_event audit_acted)" = "2" ] || fail "(2e) sweep 3 must escalate the single tracked finding"
grep -q '"result":"escalated"' "$JOURNAL_FILE" || fail "(2e) sweep 3 must journal result=escalated"
[ "$(scribe_calls)" = "1" ] || fail "(2e) three distinct shas of one class must file exactly ONE item, got $(scribe_calls)"
[ ! -s "$HERD_JOURNAL_AUDIT_PENDING" ] || fail "(2e) an escalated finding must stop being tracked: $(cat "$HERD_JOURNAL_AUDIT_PENDING")"
pass
echo "PASS (2e) HERD-631: a second/third sha under the same main_health dispatch_no_outcome class refreshes the one tracked finding instead of filing duplicates"

# ── (2f) HERD-631 leg a, red_state_stale flavor: a red on a SECOND, DIFFERENT sha (no green in
#         between) refreshes the same tracked finding rather than opening a second one ────────────────
reset_surfaces
jline "2026-08-05T12:00:00Z" '"event":"main_health","pr":900,"sha":"dddd4444","result":"red","failed":"tests/a.sh"'
out="$(run_audit on)" || fail "(2f) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2f) sweep 1 must drive the re-verify rail once, got $(rail_calls)"
[ "$(wc -l < "$HERD_JOURNAL_AUDIT_PENDING" | tr -cd '0-9')" = "1" ] || fail "(2f) sweep 1 must track exactly one pending row, got: $(cat "$HERD_JOURNAL_AUDIT_PENDING")"
# main advances to a DIFFERENT sha that is ALSO red — still the same standing incident, not a second one.
jline "2026-08-05T12:30:00Z" '"event":"main_health","pr":901,"sha":"eeee5555","result":"red","failed":"tests/a.sh"'
out="$(run_audit on)" || fail "(2f) sweep 2 exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(2f) a red on a different sha must NOT re-drive the rail, got $(rail_calls)"
[ "$(wc -l < "$HERD_JOURNAL_AUDIT_PENDING" | tr -cd '0-9')" = "1" ] || fail "(2f) a red on a different sha must still track exactly ONE pending row, got: $(cat "$HERD_JOURNAL_AUDIT_PENDING")"
jline "2026-08-05T13:00:00Z" '"event":"main_health","pr":902,"sha":"ffff6666","result":"red","failed":"tests/a.sh"'
out="$(run_audit on)" || fail "(2f) sweep 3 exited non-zero: $out"
[ "$(count_event audit_acted)" = "2" ] || fail "(2f) sweep 3 must escalate the single tracked finding"
[ "$(scribe_calls)" = "1" ] || fail "(2f) three distinct shas of one standing red must file exactly ONE item, got $(scribe_calls)"
pass
echo "PASS (2f) HERD-631: a red on a different sha refreshes the one tracked red_state_stale finding instead of filing duplicates"

# ── (3) an UNMAPPED finding class files EXACTLY ONE deduped item, ever ──────────────────────────
reset_surfaces
jline "2026-08-05T14:00:00Z" '"event":"codemap_refresh","pushed":"no"'      # pushed_no_unresolved: no rail
out="$(run_audit on)" || fail "(3) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "0" ] || fail "(3) an unmapped class must never reach a rail, got $(rail_calls)"
[ "$(scribe_calls)" = "1" ] || fail "(3) an unmapped class must file exactly one item, got $(scribe_calls)"
grep -q '"result":"filed"' "$JOURNAL_FILE" || fail "(3) the filing must be journaled result=filed"
filed_title="$(sed -n 1p "$SCRIBELOG")"
[ "$filed_title" = "journal-audit: pushed_no_unresolved has no mapped auto-action" ] \
  || fail "(3) the filed item's FIRST line must be a short title (the tracker takes line 1 verbatim): $filed_title"
[ "${#filed_title}" -le 78 ] || fail "(3) the title line must stay under 80 chars, got ${#filed_title}"
grep -q 'Dedup key: pushed_no_unresolved|' "$SCRIBELOG" || fail "(3) the filed item must carry the finding's dedup key"
# Later sweeps: the class is still found, but the filing was TERMINAL — never a duplicate item.
out="$(run_audit on)" || fail "(3) sweep 2 exited non-zero: $out"
out="$(run_audit on)" || fail "(3) sweep 3 exited non-zero: $out"
[ "$(scribe_calls)" = "1" ] || fail "(3) an unmapped class must file EXACTLY ONE item across sweeps, got $(scribe_calls)"
[ "$(count_event audit_acted)" = "1" ] || fail "(3) an unmapped class must journal exactly one audit_acted"
pass
echo "PASS (3) an unmapped finding class files exactly one deduped item and never escalates into a duplicate"

# ── (3b) fixture_slug is a DELIBERATE no-action class (HERD-562): never a rail, never a filed item,
#         and the SAME once-guard shape as everything else — a single journaled reason, ever ─────────
reset_surfaces
jline "2026-08-05T15:00:00Z" '"event":"reap","pr":77,"slug":"retiree","sha":"fff","reason":"merged"'
out="$(run_audit on)" || fail "(3b) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "0" ] || fail "(3b) fixture_slug must never reach a rail, got $(rail_calls)"
[ "$(scribe_calls)" = "0" ] || fail "(3b) fixture_slug must never file a tracker item, got $(scribe_calls)"
grep -q '"class":"fixture_slug".*"result":"no_action"' "$JOURNAL_FILE" \
  || fail "(3b) fixture_slug must journal result=no_action: $(grep audit_acted "$JOURNAL_FILE")"
grep -q '"event":"audit_acted".*"reason":' "$JOURNAL_FILE" || fail "(3b) the no-action must carry a reason"
grep -q 'audit-noaction:fixture_slug' "$HERD_JOURNAL_AUDIT_INBOX" || fail "(3b) the no-action must still get an advisory inbox row"
# The REPORT half is untouched by this — fixture_slug still shows up as an ordinary journal_audit finding.
grep -q '"event":"journal_audit".*"kind":"fixture_slug"' "$JOURNAL_FILE" || fail "(3b) fixture_slug must still be REPORTED (advisory)"
# Later sweeps: journaled exactly once, ever — no re-fire, no escalate, no PENDING tracking at all.
out="$(run_audit on)" || fail "(3b) sweep 2 exited non-zero: $out"
out="$(run_audit on)" || fail "(3b) sweep 3 exited non-zero: $out"
[ "$(rail_calls)" = "0" ] || fail "(3b) fixture_slug must never reach a rail across sweeps, got $(rail_calls)"
[ "$(scribe_calls)" = "0" ] || fail "(3b) fixture_slug must never file across sweeps, got $(scribe_calls)"
[ "$(grep -c '"result":"no_action"' "$JOURNAL_FILE")" = "1" ] || fail "(3b) the no-action must journal exactly once, ever"
[ ! -s "$HERD_JOURNAL_AUDIT_PENDING" ] || fail "(3b) a no-action class must never be tracked as pending"
pass
echo "PASS (3b) fixture_slug is a deliberate no-action class — journals a reason once, never acts on the live journal"

# ── (3c) merged_hv_unknown is a DELIBERATE no-action class (HERD-563): a transient PR-body read
#         failure is not a gap to file work against — the next sweep just re-probes ───────────────
reset_surfaces
jline "2026-08-05T12:00:00Z" '"event":"merge","pr":210,"slug":"hv-210","sha":"decaf210"'
jline "2026-08-05T12:01:00Z" '"event":"reap","pr":210,"slug":"hv-210","sha":"decaf210","reason":"merged"'
: > "$T/bodies/210.fail"     # the PR-body fetch fails → merged_hv_unknown, not merged_hv_no_approval
out="$(run_audit on)" || fail "(3c) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "0" ] || fail "(3c) merged_hv_unknown must never reach a rail, got $(rail_calls)"
[ "$(scribe_calls)" = "0" ] || fail "(3c) merged_hv_unknown must never file a tracker item, got $(scribe_calls)"
grep -q '"class":"merged_hv_unknown".*"result":"no_action"' "$JOURNAL_FILE" \
  || fail "(3c) merged_hv_unknown must journal result=no_action: $(grep audit_acted "$JOURNAL_FILE")"
[ ! -s "$HERD_JOURNAL_AUDIT_PENDING" ] || fail "(3c) a no-action class must never be tracked as pending"
pass
echo "PASS (3c) merged_hv_unknown is a deliberate no-action class — a transient read failure never files an item"

# ── (3d) RECURRENCE ESCALATION (HERD-597): a deliberate no-action class that keeps recurring under
#         DISTINCT finding keys files ONE class-scoped item at HERD_JOURNAL_AUDIT_NOACTION_RECUR_MAX
#         occurrences, then goes quiet forever. Live case: fixture_slug fired for slug=retiree,
#         slug=conv and slug=stuck across separate sweeps — three distinct keys of the SAME class —
#         and never escalated at all before this, because the per-key no-action guard in (3b)/(3c) is
#         (correctly) keyed per finding, not per class ──────────────────────────────────────────────
reset_surfaces
jline "2026-08-05T15:00:00Z" '"event":"reap","pr":77,"slug":"retiree","sha":"fff","reason":"merged"'
out="$(run_audit on HERD_JOURNAL_AUDIT_NOACTION_RECUR_MAX=3)" || fail "(3d) sweep 1 exited non-zero: $out"
[ "$(scribe_calls)" = "0" ] || fail "(3d) a single occurrence must never file anything, got $(scribe_calls)"
[ "$(grep -c '"result":"no_action"' "$JOURNAL_FILE")" = "1" ] || fail "(3d) sweep 1 must journal exactly one no_action"
# A second, DISTINCT slug — a different finding key, same class.
jline "2026-08-05T15:05:00Z" '"event":"reap","pr":78,"slug":"conv","sha":"eee","reason":"merged"'
out="$(run_audit on HERD_JOURNAL_AUDIT_NOACTION_RECUR_MAX=3)" || fail "(3d) sweep 2 exited non-zero: $out"
[ "$(scribe_calls)" = "0" ] || fail "(3d) two distinct occurrences must still not file, got $(scribe_calls)"
# A THIRD, distinct slug — the third distinct occurrence of the SAME class → escalate exactly once.
jline "2026-08-05T15:10:00Z" '"event":"reap","pr":79,"slug":"stuck","sha":"ddd","reason":"merged"'
out="$(run_audit on HERD_JOURNAL_AUDIT_NOACTION_RECUR_MAX=3)" || fail "(3d) sweep 3 exited non-zero: $out"
[ "$(scribe_calls)" = "1" ] || fail "(3d) the third distinct occurrence must file exactly one recurring item, got $(scribe_calls)"
grep -q '"class":"fixture_slug".*"result":"recurring_filed"' "$JOURNAL_FILE" \
  || fail "(3d) the recurrence escalation must journal result=recurring_filed: $(grep audit_acted "$JOURNAL_FILE")"
grep -q 'Dedup key: recurring:fixture_slug' "$SCRIBELOG" || fail "(3d) the filed item's dedup key must be CLASS-scoped, not per-slug: $(cat "$SCRIBELOG")"
grep -q 'audit-recurring:fixture_slug' "$HERD_JOURNAL_AUDIT_INBOX" || fail "(3d) the recurrence escalation must be LOUD in the operator inbox"
filed_title="$(sed -n 1p "$SCRIBELOG")"
[ "$filed_title" = "journal-audit: fixture_slug keeps recurring (HERD-597)" ] || fail "(3d) unexpected filed title: $filed_title"
# A fourth distinct occurrence: the CLASS already escalated — never a second filed item, ever.
jline "2026-08-05T15:15:00Z" '"event":"reap","pr":80,"slug":"hd","sha":"ccc","reason":"merged"'
out="$(run_audit on HERD_JOURNAL_AUDIT_NOACTION_RECUR_MAX=3)" || fail "(3d) sweep 4 exited non-zero: $out"
[ "$(scribe_calls)" = "1" ] || fail "(3d) a class that already escalated must never file a second item, got $(scribe_calls)"
[ ! -s "$HERD_JOURNAL_AUDIT_PENDING" ] || fail "(3d) a no-action class must never be tracked as pending, even when recurring"
pass
echo "PASS (3d) a recurring no-action class (3+ distinct keys) files exactly one class-scoped item (HERD-597)"

# ── (3e) watcher_restart_blocked is a DELIBERATE no-action class (HERD-600, #708 pattern): never a
#         rail (an unidentified holder_pid must never be auto-killed), never a filed item per
#         occurrence, journals its reason once ──────────────────────────────────────────────────────
reset_surfaces
jline "2026-08-05T15:00:00Z" '"event":"watcher_restart_blocked","holder_pid":54321,"workspace":"ws-a"'
out="$(run_audit on)" || fail "(3e) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "0" ] || fail "(3e) watcher_restart_blocked must never reach a rail, got $(rail_calls)"
[ "$(scribe_calls)" = "0" ] || fail "(3e) watcher_restart_blocked must never file a tracker item, got $(scribe_calls)"
grep -q '"class":"watcher_restart_blocked".*"result":"no_action"' "$JOURNAL_FILE" \
  || fail "(3e) watcher_restart_blocked must journal result=no_action: $(grep audit_acted "$JOURNAL_FILE")"
grep -q 'audit-noaction:watcher_restart_blocked' "$HERD_JOURNAL_AUDIT_INBOX" || fail "(3e) the no-action must still get an advisory inbox row"
grep -q '"event":"journal_audit".*"kind":"watcher_restart_blocked"' "$JOURNAL_FILE" || fail "(3e) watcher_restart_blocked must still be REPORTED (advisory)"
out="$(run_audit on)" || fail "(3e) sweep 2 exited non-zero: $out"
out="$(run_audit on)" || fail "(3e) sweep 3 exited non-zero: $out"
[ "$(rail_calls)" = "0" ] || fail "(3e) watcher_restart_blocked must never reach a rail across sweeps, got $(rail_calls)"
[ "$(scribe_calls)" = "0" ] || fail "(3e) watcher_restart_blocked must never file across sweeps, got $(scribe_calls)"
[ "$(grep -c '"result":"no_action"' "$JOURNAL_FILE")" = "1" ] || fail "(3e) the no-action must journal exactly once, ever"
pass
echo "PASS (3e) watcher_restart_blocked is a deliberate no-action class — journals a reason once, never acts on the live journal"

# ── (3f) checkout_unclean is a DELIBERATE no-action class (HERD-600, #708 pattern): the evidence is
#         preserved for a human, so no rail may auto-discard it and no per-occurrence item is filed ───
reset_surfaces
jline "2026-08-05T15:00:00Z" '"event":"checkout_unclean","result":"detected","head":"abc12345","paths":"scratch.txt","detached":"no"'
out="$(run_audit on)" || fail "(3f) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "0" ] || fail "(3f) checkout_unclean must never reach a rail, got $(rail_calls)"
[ "$(scribe_calls)" = "0" ] || fail "(3f) checkout_unclean must never file a tracker item, got $(scribe_calls)"
grep -q '"class":"checkout_unclean".*"result":"no_action"' "$JOURNAL_FILE" \
  || fail "(3f) checkout_unclean must journal result=no_action: $(grep audit_acted "$JOURNAL_FILE")"
grep -q '"event":"journal_audit".*"kind":"checkout_unclean"' "$JOURNAL_FILE" || fail "(3f) checkout_unclean must still be REPORTED (advisory)"
out="$(run_audit on)" || fail "(3f) sweep 2 exited non-zero: $out"
[ "$(scribe_calls)" = "0" ] || fail "(3f) checkout_unclean must never file across sweeps, got $(scribe_calls)"
[ "$(grep -c '"result":"no_action"' "$JOURNAL_FILE")" = "1" ] || fail "(3f) the no-action must journal exactly once, ever"
pass
echo "PASS (3f) checkout_unclean is a deliberate no-action class — journals a reason once, never acts on the live journal"

# ── (3h) merged_hv_no_approval is a DELIBERATE no-action class (HERD-606, #723 pattern): the PR is
#         already merged, so no rail can retroactively verify unrun HUMAN-VERIFY steps or undo the
#         merge — real signal, but nothing bounded to route it to ──────────────────────────────────────
reset_surfaces
jline "2026-08-05T12:00:00Z" '"event":"merge","pr":211,"slug":"hv-211","sha":"decaf211"'
jline "2026-08-05T12:01:00Z" '"event":"reap","pr":211,"slug":"hv-211","sha":"decaf211","reason":"merged"'
printf 'Some PR body.\n\nHUMAN-VERIFY:\n- smoke test the UI\n' > "$T/bodies/211.md"
out="$(run_audit on)" || fail "(3h) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "0" ] || fail "(3h) merged_hv_no_approval must never reach a rail, got $(rail_calls)"
[ "$(scribe_calls)" = "0" ] || fail "(3h) merged_hv_no_approval must never file a tracker item, got $(scribe_calls)"
grep -q '"class":"merged_hv_no_approval".*"result":"no_action"' "$JOURNAL_FILE" \
  || fail "(3h) merged_hv_no_approval must journal result=no_action: $(grep audit_acted "$JOURNAL_FILE")"
grep -q 'audit-noaction:merged_hv_no_approval' "$HERD_JOURNAL_AUDIT_INBOX" || fail "(3h) the no-action must still get an advisory inbox row"
grep -q '"event":"journal_audit".*"kind":"merged_hv_no_approval"' "$JOURNAL_FILE" || fail "(3h) merged_hv_no_approval must still be REPORTED (advisory)"
[ ! -s "$HERD_JOURNAL_AUDIT_PENDING" ] || fail "(3h) a no-action class must never be tracked as pending"
out="$(run_audit on)" || fail "(3h) sweep 2 exited non-zero: $out"
out="$(run_audit on)" || fail "(3h) sweep 3 exited non-zero: $out"
[ "$(rail_calls)" = "0" ] || fail "(3h) merged_hv_no_approval must never reach a rail across sweeps, got $(rail_calls)"
[ "$(scribe_calls)" = "0" ] || fail "(3h) merged_hv_no_approval must never file across sweeps, got $(scribe_calls)"
[ "$(grep -c '"result":"no_action"' "$JOURNAL_FILE")" = "1" ] || fail "(3h) the no-action must journal exactly once, ever"
pass
echo "PASS (3h) merged_hv_no_approval is a deliberate no-action class — journals a reason once, never acts on the live journal"

# ── (3i) HERD-606: the no-action recurrence counter's per-class HIGH-WATER MARK backstops the
#         per-key once-guard. Simulate the once-guard's protection being lost (its fallback ledger is
#         tail-trimmed, or a pool GC drops old markers — see _ja_act_once's own comment) so the SAME
#         checkout_unclean event is re-claimed as "new" on a later sweep: the HWM (the event's own
#         timestamp never having advanced) must still stop it from inflating the recurrence tally a
#         second time — the exact false-filing shape HERD-604/605 exists to prevent.
reset_surfaces
jline "2026-08-05T15:00:00Z" '"event":"checkout_unclean","result":"detected","head":"abc12345","paths":"scratch.txt","detached":"no"'
out="$(run_audit on HERD_JOURNAL_AUDIT_NOACTION_RECUR_MAX=2)" || fail "(3i) sweep 1 exited non-zero: $out"
[ "$(scribe_calls)" = "0" ] || fail "(3i) sweep 1 must not yet reach the recurrence threshold, got $(scribe_calls)"
grep -q '^checkout_unclean	1$' "$HERD_JOURNAL_AUDIT_NOACTION_COUNT" \
  || fail "(3i) sweep 1 must count exactly one occurrence: $(cat "$HERD_JOURNAL_AUDIT_NOACTION_COUNT" 2>/dev/null)"
# Simulate the once-guard losing its claim on this key (its flat marker under .herd/ is gone — the
# SAME failure mode _ja_act_once's own comment calls out for its seen-ledger fallback) WITHOUT touching
# the HWM state (which lives at the pool root, not under .herd/ — see reset_surfaces above).
rm -f "$T"/trees/.herd/once-* 2>/dev/null || true
out="$(run_audit on HERD_JOURNAL_AUDIT_NOACTION_RECUR_MAX=2)" || fail "(3i) sweep 2 exited non-zero: $out"
# The once-guard WAS bypassed (proof the simulated loss actually took effect): a second no_action fired.
[ "$(grep -c '"class":"checkout_unclean".*"result":"no_action"' "$JOURNAL_FILE")" = "2" ] \
  || fail "(3i) the once-guard loss must be real (a second no_action expected): $(grep audit_acted "$JOURNAL_FILE")"
# But the HWM must have refused to recount the SAME (non-newer) timestamp — no premature recurrence.
grep -q '^checkout_unclean	1$' "$HERD_JOURNAL_AUDIT_NOACTION_COUNT" \
  || fail "(3i) a historical replay (same event ts) must NOT advance the recurrence count: $(cat "$HERD_JOURNAL_AUDIT_NOACTION_COUNT" 2>/dev/null)"
[ "$(scribe_calls)" = "0" ] \
  || fail "(3i) a historical replay must never file a false recurrence item (HERD-604/605), got $(scribe_calls)"
pass
echo "PASS (3i) HERD-606: the per-class high-water mark stops a historical journal replay from inflating the recurrence tally, even when the once-guard's own protection is lost"

# ── (3g) HERD-602: an unmapped class that keeps recurring under DISTINCT finding keys (a new pr, a
#         new ts) must still file EXACTLY ONE tracker item, ever — dedup keyed on the CLASS, not the
#         per-finding key. Two distinct pushed_no_unresolved keys in the SAME sweep, then a third one
#         on a later sweep ───────────────────────────────────────────────────────────────────────────
reset_surfaces
jline "2026-08-05T14:00:00Z" '"event":"codemap_refresh","pushed":"no"'
jline "2026-08-05T14:05:00Z" '"event":"symbol_index_refresh","pushed":"no"'
out="$(run_audit on)" || fail "(3g) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "0" ] || fail "(3g) an unmapped class must never reach a rail, got $(rail_calls)"
[ "$(scribe_calls)" = "1" ] || fail "(3g) two distinct keys of the SAME unmapped class must file exactly ONE item, got $(scribe_calls)"
[ "$(count_event audit_acted)" = "2" ] || fail "(3g) both distinct findings must still be individually acted on/journaled, got $(count_event audit_acted)"
grep -q '"result":"filed"' "$JOURNAL_FILE" || fail "(3g) exactly one of the two must journal result=filed"
grep -q '"result":"already_filed_for_class"' "$JOURNAL_FILE" || fail "(3g) the second distinct key must journal result=already_filed_for_class, not file again"
# A THIRD distinct key on a later sweep: still no second filed item, ever.
jline "2026-08-05T14:10:00Z" '"event":"some_other_refresh","pushed":"no"'
out="$(run_audit on)" || fail "(3g) sweep 2 exited non-zero: $out"
[ "$(scribe_calls)" = "1" ] || fail "(3g) a THIRD distinct key on a later sweep must still not file a second item, got $(scribe_calls)"
pass
echo "PASS (3g) HERD-602: an unmapped class dedups its filing on the CLASS, not the per-finding key — files exactly once ever"

# ── (4) each mapped class routes to the rail WITH the context it needs ──────────────────────────
reset_surfaces
jline "2026-08-05T14:00:00Z" '"event":"review_dispatched","pr":700,"sha":"deadbeef1234","slug":"orphan-lane"'
jline "2026-08-05T15:00:00Z" '"event":"refix_bounce","pr":701,"sha":"cafe0001","slug":"bouncy","round":2'
jline "2026-08-05T13:00:00Z" '"event":"main_health","pr":702,"sha":"bbbb2222","result":"red","failed":"tests/x.sh"'
jline "2026-08-05T13:00:00Z" '"event":"merge","pr":703,"slug":"unreaped","sha":"cccc3333"'
out="$(run_audit on HERD_JOURNAL_AUDIT_ACT_MAX=10)" || fail "(4) sweep exited non-zero: $out"
[ "$(rail_calls)" = "4" ] || fail "(4) all four mapped classes must reach a rail, got $(rail_calls): $(cat "$RAILLOG")"
grep -q '^dispatch_no_outcome|.*|.*pr=700' "$RAILLOG"   || fail "(4) dispatch ctx must carry pr: $(cat "$RAILLOG")"
grep -q '^dispatch_no_outcome|.*slug=orphan-lane' "$RAILLOG" || fail "(4) dispatch ctx must carry slug"
grep -q '^refix_bounce_no_wake|.*slug=bouncy' "$RAILLOG"  || fail "(4) the re-bounce rail needs slug — it wakes a pane"
grep -q '^refix_bounce_no_wake|.*round=2' "$RAILLOG"      || fail "(4) the re-bounce ctx must carry the round"
grep -q '^red_state_stale|.*sha=bbbb2222' "$RAILLOG"      || fail "(4) the re-verify ctx must carry the red sha"
grep -q '^merge_without_reap|.*slug=unreaped' "$RAILLOG"  || fail "(4) the retirement ctx must carry the slug"
[ "$(scribe_calls)" = "0" ] || fail "(4) mapped classes must not file items on their first action"
# Every class journal-audit.sh claims to map must be a class journal-act.sh actually has an arm for.
mapped="$(sed -n '/^_ja_act_mapped()/,/^}/p' "$SCRIPT" | sed -n 's/^ *\(.*\)) return 0 ;;$/\1/p' | tr '|' '\n')"
[ -n "$mapped" ] || fail "(4) could not read _ja_act_mapped's class list out of journal-audit.sh"
armed="$(sed -n 's/^  \(merge_without_reap[^)]*\)).*$/\1/p' "$ACT" | tr '|' '\n')"
[ -n "$armed" ] || fail "(4) could not read journal-act.sh's recognized-class list"
for c in $mapped; do
  # Whole-line membership by parameter expansion, never `printf | grep -q` (EPIPE under pipefail).
  case $'\n'"$armed"$'\n' in
    *$'\n'"$c"$'\n'*) ;;
    *) fail "(4) journal-audit.sh maps '$c' but journal-act.sh has no arm for it" ;;
  esac
done
pass
echo "PASS (4) every mapped class routes to the rail with its context, and both files agree on the mapping"

# ── (5) a finding already in the seen-ledger is still ACTED on, exactly once ─────────────────────
# Muting the REPORT must never mute the HEAL. Pre-mark the finding key as seen, then sweep: no new
# journal_audit event fires (it is muted), but the action does — once.
reset_surfaces
seed_orphan_dispatch
printf '%s\n' 'dispatch_no_outcome|review_dispatched|pr=700|sha=deadbeef1234' > "$HERD_JOURNAL_AUDIT_SEEN"
out="$(run_audit on)" || fail "(5) sweep exited non-zero: $out"
[ "$(count_event journal_audit)" = "0" ] || fail "(5) a seen finding must not be re-REPORTED"
[ "$(rail_calls)" = "1" ] || fail "(5) a seen finding must still be ACTED on, got $(rail_calls)"
pass
echo "PASS (5) a seen-ledger-muted finding is still healed — muting the report never mutes the heal"

# ── (6) FAIL-SOFT: a dead rail and a dead scribe never fail the sweep ───────────────────────────
reset_surfaces
seed_orphan_dispatch
touch "$T/rail.fail"
out="$(run_audit on)" || fail "(6) a failing rail must not fail the sweep: $out"
grep -q '"result":"failed"' "$JOURNAL_FILE" || fail "(6) a rail that produced nothing must journal result=failed, not a heal"
rm -f "$T/rail.fail"
reset_surfaces
jline "2026-08-05T14:00:00Z" '"event":"codemap_refresh","pushed":"no"'
touch "$T/scribe.fail"
out="$(run_audit on)" || fail "(6) a failing scribe must not fail the sweep: $out"
grep -q '"result":"file_failed"' "$JOURNAL_FILE" || fail "(6) a scribe that failed must journal result=file_failed, never filed"
rm -f "$T/scribe.fail"
# The at-most-once guard's OWN fallback: with the shared-pool store unreachable (HERDKIT_HOME pointed
# at a tree with no pysrc), the guard degrades to the seat-local seen-ledger. The sweep must still run
# under `set -e`, still act, and still act only ONCE — the property, not the mechanism, is what holds.
reset_surfaces
seed_orphan_dispatch
out="$(run_audit on HERDKIT_HOME="$T/no-pysrc")" || fail "(6) a missing store must not fail the sweep: $out"
[ "$(rail_calls)" = "1" ] || fail "(6) with no store the fallback guard must still act once, got $(rail_calls)"
out="$(run_audit on HERDKIT_HOME="$T/no-pysrc")" || fail "(6) sweep 2 with no store exited non-zero: $out"
[ "$(rail_calls)" = "1" ] || fail "(6) the fallback guard must not re-act, got $(rail_calls)"
pass
echo "PASS (6) fail-soft: a dead rail, a dead scribe and an unreachable shared-pool store all degrade honestly"

# ── (7) BOUNDED per sweep — and nothing is dropped ──────────────────────────────────────────────
reset_surfaces
jline "2026-08-05T14:00:00Z" '"event":"review_dispatched","pr":800,"sha":"aaa1","slug":"l1"'
jline "2026-08-05T14:00:00Z" '"event":"review_dispatched","pr":801,"sha":"aaa2","slug":"l2"'
jline "2026-08-05T14:00:00Z" '"event":"review_dispatched","pr":802,"sha":"aaa3","slug":"l3"'
out="$(run_audit on HERD_JOURNAL_AUDIT_ACT_MAX=2)" || fail "(7) sweep 1 exited non-zero: $out"
[ "$(rail_calls)" = "2" ] || fail "(7) the per-sweep budget must cap actions at 2, got $(rail_calls)"
out="$(run_audit on HERD_JOURNAL_AUDIT_ACT_MAX=2)" || fail "(7) sweep 2 exited non-zero: $out"
# Sweep 2's lifecycle pass re-observes the two already-acted findings (still below
# JOURNAL_AUDIT_ESCALATE_AFTER, so no budget spent there) and the fresh budget acts on the third —
# the THIRD finding must eventually be acted on, never dropped by the cap. Later sweeps would go on to
# spend budget on escalating the first two (past JOURNAL_AUDIT_ESCALATE_AFTER re-observations), but
# that is HERD_JOURNAL_AUDIT_ACT_MAX/JOURNAL_AUDIT_ESCALATE_AFTER doing their OWN job (proven by (2)
# and (2b) above) — this test only asserts the "never dropped" half.
out="$(run_audit on HERD_JOURNAL_AUDIT_ACT_MAX=2)" || fail "(7) sweep 3 exited non-zero: $out"
out="$(run_audit on HERD_JOURNAL_AUDIT_ACT_MAX=2)" || fail "(7) sweep 4 exited non-zero: $out"
[ "$(rail_calls)" = "3" ] || fail "(7) every finding must be acted on eventually (3 expected), got $(rail_calls): $(cat "$RAILLOG")"
grep -q 'pr=802' "$RAILLOG" || fail "(7) the finding deferred by the budget must be acted on a later sweep"
pass
echo "PASS (7) actions are bounded per sweep and a deferred finding is acted on later, never dropped"

# ── (8) journal-act.sh answers an UNKNOWN class without standing up a control room ──────────────
out="$(bash "$ACT" totally_unknown_class 'some|key' pr=1 2>&1)" || fail "(8) journal-act.sh must always exit 0: $out"
[ "$out" = "unmapped" ] || fail "(8) an unknown class must print exactly 'unmapped', got '$out'"
out="$(HERD_JOURNAL_ACT_SELFTEST=1 bash "$ACT" merge_without_reap 'k' slug=x 2>&1)" \
  || fail "(8) journal-act.sh self-test must exit 0: $out"
[ "$out" = "selftest" ] || fail "(8) a RECOGNIZED class must be recognized before any library load, got '$out'"
out="$(bash "$ACT" 2>&1)" || fail "(8) journal-act.sh with no arguments must still exit 0: $out"
[ "$out" = "unmapped" ] || fail "(8) no arguments must degrade to 'unmapped', got '$out'"
# DRYRUN acts on nothing, even for a class that HAS a rail — and says so instead of claiming a heal.
out="$(DRYRUN=1 bash "$ACT" red_state_stale 'k' sha=abc 2>&1)" || fail "(8) a dry run must exit 0: $out"
[ "$out" = "dryrun" ] || fail "(8) a dry run must answer 'dryrun' and touch nothing, got '$out'"
pass
echo "PASS (8) journal-act.sh answers unknown/absent/dry-run invocations without a control room, always exit 0"

echo "ALL PASS ($PASS checks) — journal-audit findings become ACTIONS (HERD-544)."
