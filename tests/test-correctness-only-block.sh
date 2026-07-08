#!/usr/bin/env bash
# test-correctness-only-block.sh — hermetic tests for HERD-105: the pre-merge review gate BLOCKs on
# CORRECTNESS ONLY; style/hardening/nitpick findings are reclassified as NON-blocking advisory notes.
#
# The reviewer now classifies every finding as CORRECTNESS (blocking) or ADVISORY (non-blocking) and
# BLOCKs only when there is >=1 correctness finding; otherwise it PASSes, carrying any advisory
# findings as ' | '-separated 'advisory:' notes after the em-dash:
#   REVIEW: PASS — advisory: <note> | advisory: <note>
# The watcher merges on PASS regardless, and surfaces each advisory note to the JOURNAL (never gates).
# The whole feature is BACKWARD-COMPATIBLE + FAIL-SOFT + BYTE-IDENTICAL when unused: a finding-free
# 'REVIEW: PASS' has no advisory tail, records/echoes exactly as before, and journals zero advisories.
#
# Coverage:
#   PART 1 (agent-watch.sh, lib mode — stubs herdr/gh/git):
#     (1) _record_advisory_notes journals one review_advisory per note (structured, multi + order/case)
#     (2) a bare 'REVIEW: PASS' journals ZERO advisories (byte-identical: no em-dash tail)
#     (3) _review_gate_step on a PASS-with-advisory result: collects PASS, caches PASS (source
#         reviewer), MERGE PROCEEDS, and each advisory note is journalled
#     (4) fail-soft: a PASS with a malformed tail (no 'advisory:' key) → PASS, zero advisories
#     (5) a value cap keeps one pathological note from bloating the journal
#   PART 2 (herd-review.sh, real script — stubs claude/gh/herdr):
#     (6) reviewer prints a PASS-with-advisory line → herd-review.sh emits it VERBATIM (exit 0)
#     (7) reviewer prints a bare 'REVIEW: PASS' → emits byte-identical 'REVIEW: PASS' (exit 0)
#     (8) a genuine CORRECTNESS block still BLOCKs (exit 1) — advisory reclassification never swallows it
#   PART 3 (source invariants):
#     (9) all three reviewer prompts (PR/agent/local) instruct correctness-only blocking + the advisory PASS shape
#    (10) the HERD-104 structured BLOCK shape is untouched (backward-compat preserved)
#
# Run:  bash tests/test-correctness-only-block.sh
# Fully hermetic: stubs gh/git/herdr/claude on PATH; no network, no live herdr pane.
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
REVIEW="$HERE/../scripts/herd/herd-review.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ]  || fail "agent-watch.sh not found at $WATCH"
[ -f "$REVIEW" ] || fail "herd-review.sh not found at $REVIEW"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH (network-free) ─────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list") printf '{"result":{"agents":[]}}\n' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# review_advisory journal events land in this file (JOURNAL_FILE overrides the derived path).
JOURNAL="$T/journal.jsonl"; export JOURNAL_FILE="$JOURNAL"
_adv_count() { grep -c '"event":"review_advisory"' "$JOURNAL" 2>/dev/null; true; }

################################################################################
# PART 1 — agent-watch.sh in lib mode
################################################################################
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export REVIEW_CONCURRENCY=2
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _record_advisory_notes _review_gate_step record_review review_verdict \
          review_verdict_source _review_result_file _blk_trim; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# ── (1) _record_advisory_notes: one review_advisory per note (multi + order/case-insensitive) ─────
: > "$JOURNAL"
_record_advisory_notes 1 sha1 "REVIEW: PASS — advisory: prefer printf over echo | Advisory: add a unit test | advisory: tighten quoting"
[ "$(_adv_count)" -eq 3 ] || fail "(1) three advisory notes should journal three events (got $(_adv_count))"
grep -q '"note":"prefer printf over echo"' "$JOURNAL" || fail "(1) first advisory note not journalled"
grep -q '"note":"add a unit test"'         "$JOURNAL" || fail "(1) case-insensitive 'Advisory:' note not journalled"
grep -q '"note":"tighten quoting"'         "$JOURNAL" || fail "(1) third advisory note not journalled"
grep -q '"pr":1' "$JOURNAL" && grep -q '"sha":"sha1"' "$JOURNAL" || fail "(1) advisory event missing pr/sha"
ok

# ── (2) a bare PASS journals ZERO advisories (byte-identical: no em-dash tail) ─────────────────────
: > "$JOURNAL"
_record_advisory_notes 2 sha2 "REVIEW: PASS"
[ "$(_adv_count)" -eq 0 ] || fail "(2) a bare PASS must journal zero advisories (got $(_adv_count))"
ok

# ── (3) _review_gate_step on a PASS-with-advisory: collect PASS + cache + journal advisories ───────
rm -f "$REVIEW_STATE"; : > "$JOURNAL"
printf 'REVIEW: PASS — advisory: rename $x to $count | advisory: guard the empty-input case\n' \
  > "$(_review_result_file 30 sha30)"
[ "$(_review_gate_step 30 slug30 sha30)" = "PASS" ] || fail "(3) PASS-with-advisory should collect as PASS (merge proceeds)"
[ "$(review_verdict 30 sha30)" = "PASS" ]           || fail "(3) PASS should be cached in the ledger"
[ "$(review_verdict_source 30 sha30)" = "reviewer" ] || fail "(3) collected PASS provenance should be 'reviewer'"
[ "$(_adv_count)" -eq 2 ] || fail "(3) both advisory notes should be journalled (got $(_adv_count))"
grep -q '"note":"guard the empty-input case"' "$JOURNAL" || fail "(3) advisory note not surfaced to journal"
ok

# ── (4) fail-soft: PASS with a malformed tail (no 'advisory:' key) → PASS, zero advisories ─────────
rm -f "$REVIEW_STATE"; : > "$JOURNAL"
printf 'REVIEW: PASS — looks correct to me, nice work\n' > "$(_review_result_file 31 sha31)"
[ "$(_review_gate_step 31 slug31 sha31)" = "PASS" ] || fail "(4) malformed-tail PASS should still collect as PASS"
[ "$(review_verdict 31 sha31)" = "PASS" ]           || fail "(4) malformed-tail PASS should still cache PASS"
[ "$(_adv_count)" -eq 0 ] || fail "(4) a tail with no 'advisory:' key must journal zero advisories (got $(_adv_count))"
ok

# ── (5) value cap: a pathological note is truncated (<=200 chars) so it can't bloat the journal ────
: > "$JOURNAL"
_big="$(printf 'x%.0s' {1..500})"
_record_advisory_notes 5 sha5 "REVIEW: PASS — advisory: $_big"
_len="$(grep -o '"note":"x*"' "$JOURNAL" | head -1 | sed -E 's/.*"note":"(x*)".*/\1/' | tr -d '\n' | wc -c)"
[ "$_len" -le 200 ] || fail "(5) advisory note should be capped at 200 chars (got $_len)"
[ "$_len" -eq 200 ] || fail "(5) a 500-char note should truncate to exactly 200 (got $_len)"
ok

################################################################################
# PART 2 — herd-review.sh (real script, stubbed claude)
################################################################################
# (6) reviewer prints a PASS-with-advisory line → herd-review.sh emits it VERBATIM (exit 0).
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","result":"Only style nits found.\\nREVIEW: PASS — advisory: prefer printf | advisory: add a test"}\n'
exit 0
STUB
chmod +x "$BIN/claude"
RES6="$T/res-6"
out="$(HERD_NO_PANE=1 HERD_REVIEW_RESULT_FILE="$RES6" WORKTREES_DIR="$T/trees" \
       HERD_CONFIG_FILE="$T/no-such-config" JOURNAL_FILE="$T/j6" bash "$REVIEW" 6 slug6 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] || fail "(6) PASS-with-advisory should exit 0 (got $rc)"
printf '%s\n' "$out" | grep -qF 'REVIEW: PASS — advisory: prefer printf | advisory: add a test' \
  || fail "(6) herd-review.sh should emit the advisory PASS line verbatim to stdout"
grep -qF 'REVIEW: PASS — advisory: prefer printf | advisory: add a test' "$RES6" \
  || fail "(6) result file should carry the advisory PASS line verbatim"
ok

# (7) reviewer prints a bare PASS → emit byte-identical 'REVIEW: PASS' (exit 0).
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","result":"Diff is correct.\\nREVIEW: PASS"}\n'
exit 0
STUB
chmod +x "$BIN/claude"
RES7="$T/res-7"
out="$(HERD_NO_PANE=1 HERD_REVIEW_RESULT_FILE="$RES7" WORKTREES_DIR="$T/trees" \
       HERD_CONFIG_FILE="$T/no-such-config" JOURNAL_FILE="$T/j7" bash "$REVIEW" 7 slug7 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] || fail "(7) bare PASS should exit 0 (got $rc)"
printf '%s\n' "$out" | grep -qx 'REVIEW: PASS' || fail "(7) bare PASS must be emitted byte-identically as 'REVIEW: PASS'"
grep -qx 'REVIEW: PASS' "$RES7" || fail "(7) result file should contain exactly 'REVIEW: PASS'"
ok

# (8) a genuine CORRECTNESS block still BLOCKs (exit 1) — advisory reclassification never swallows it.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","result":"Found a real bug.\\nREVIEW: BLOCK — rule: off-by-one | why: loop overshoots | location: sum.sh:42"}\n'
exit 0
STUB
chmod +x "$BIN/claude"
RES8="$T/res-8"
out="$(HERD_NO_PANE=1 HERD_REVIEW_RESULT_FILE="$RES8" WORKTREES_DIR="$T/trees" \
       HERD_CONFIG_FILE="$T/no-such-config" JOURNAL_FILE="$T/j8" bash "$REVIEW" 8 slug8 2>/dev/null)"
rc=$?
[ "$rc" -eq 1 ] || fail "(8) a correctness BLOCK must exit 1 (got $rc)"
printf '%s\n' "$out" | grep -q '^REVIEW: BLOCK — rule: off-by-one' || fail "(8) the structured BLOCK must survive"
ok

################################################################################
# PART 3 — source invariants
################################################################################
# (9) all three reviewer prompts instruct correctness-only blocking + the advisory PASS shape.
n_block="$(grep -c 'BLOCK ON CORRECTNESS ONLY' "$REVIEW")"
[ "$n_block" -ge 3 ] || fail "(9) all three prompts should instruct 'BLOCK ON CORRECTNESS ONLY' (found $n_block)"
n_adv="$(grep -c "advisory: <one-line note> | advisory: <one-line note>" "$REVIEW")"
[ "$n_adv" -ge 3 ] || fail "(9) all three prompts should instruct the advisory PASS shape (found $n_adv)"
# The obsolete 'SCOPE = CORRECTNESS ONLY. Ignore style' framing must be gone (it discarded, not surfaced, advisories).
grep -q 'Ignore style, naming, formatting' "$REVIEW" && fail "(9) the old 'Ignore style' framing should be replaced by classification"
ok

# (10) the HERD-104 structured BLOCK shape is untouched (backward-compat preserved).
n_struct="$(grep -c "rule: <which correctness rule was violated> | why: <the reasoning> | location:" "$REVIEW")"
[ "$n_struct" -ge 3 ] || fail "(10) the structured BLOCK shape must remain in all three prompts (found $n_struct)"
grep -q "REVIEW: PASS" "$REVIEW" || fail "(10) herd-review.sh must still emit the literal REVIEW: PASS"
ok

echo "ALL PASS ($pass checks)"
