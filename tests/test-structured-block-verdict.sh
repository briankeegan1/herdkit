#!/usr/bin/env bash
# test-structured-block-verdict.sh — hermetic tests for HERD-104: STRUCTURED BLOCK verdicts.
#
# herd-review.sh now emits a BLOCK as a single line carrying three ' | '-separated fields:
#   REVIEW: BLOCK — rule: <rule> | why: <why> | location: <file:line or function>
# The watcher parses + caches those fields sha-keyed and the REVIEW_AUTOFIX bounce surfaces them so a
# refix is actionable. The whole feature is BACKWARD-COMPATIBLE + FAIL-SOFT: a legacy/unstructured
# 'REVIEW: BLOCK — <freeform>' still parses (whole tail → why; rule/location empty), and PASS is
# byte-identical (no field ever appended).
#
# Coverage (agent-watch.sh, lib mode — stubs herdr/gh/git):
#   (1) _parse_block_fields: structured line → rule/why/location; field order independence
#   (2) _parse_block_fields: legacy freeform → why only, rule/location empty (fail-soft); explicit why:
#   (3) _review_gate_step on a structured BLOCK result: records BLOCK + caches the block-detail file
#   (4) _handle_block_verdict injects rule/why/location into the builder re-task prompt
#   (5) fail-soft: a BLOCK with NO cached detail (legacy) still bounces with the generic prompt
#   (6) _discard_stale_reviews drops a block-detail file for a superseded sha
#   (7) herd-review.sh prompts instruct the structured shape (source invariant)
#
# Run:  bash tests/test-structured-block-verdict.sh
# Fully hermetic: stubs gh/git/herdr on PATH; no network. No `set -e` (some checks assert non-zero).
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
# herdr stub: agent list returns one configurable idle agent; `pane run <pane> <text>` logs BOTH the
# target pane_id (STUB_PANE_RUN_LOG) and the full prompt TEXT (STUB_PANE_TEXT_LOG) so we can assert
# the structured finding is surfaced in the bounce.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
      "${STUB_AGENT_NAME:-}" "${STUB_AGENT_STATUS:-idle}" "${STUB_AGENT_PANE_ID:-pane-000}"
    ;;
  "pane run")
    [ -n "${STUB_PANE_RUN_LOG:-}" ]  && printf '%s\n' "$3" >> "$STUB_PANE_RUN_LOG"
    [ -n "${STUB_PANE_TEXT_LOG:-}" ] && printf '%s\n<<<END>>>\n' "$4" >> "$STUB_PANE_TEXT_LOG"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export REVIEW_CONCURRENCY=2
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _parse_block_fields _persist_block_fields _review_block_file _blk_trim \
          _review_gate_step _handle_block_verdict _discard_stale_reviews _review_result_file; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

render() { :; }   # no-op: no terminal output in tests
STUB_WAIT_FILE="$T/wait-codes.txt"
_wait_agent_working() {
  local c; c="$(head -1 "$STUB_WAIT_FILE" 2>/dev/null || true)"
  { tail -n +2 "$STUB_WAIT_FILE" 2>/dev/null || true; } > "${STUB_WAIT_FILE}.tmp"
  mv "${STUB_WAIT_FILE}.tmp" "$STUB_WAIT_FILE" 2>/dev/null || true
  return "${c:-0}"
}
PANE_LOG="$T/pane-run.log"; export STUB_PANE_RUN_LOG="$PANE_LOG"
TEXT_LOG="$T/pane-text.log"; export STUB_PANE_TEXT_LOG="$TEXT_LOG"

# ── (1) _parse_block_fields: structured line, canonical + shuffled field order ────
_parse_block_fields "REVIEW: BLOCK — rule: off-by-one | why: loop overshoots the last row | location: sum.sh:42"
[ "$_BLK_RULE" = "off-by-one" ]                 || fail "(1) rule mis-parsed (got '$_BLK_RULE')"
[ "$_BLK_WHY" = "loop overshoots the last row" ] || fail "(1) why mis-parsed (got '$_BLK_WHY')"
[ "$_BLK_LOCATION" = "sum.sh:42" ]              || fail "(1) location mis-parsed (got '$_BLK_LOCATION')"
ok
# Order independence — location first, rule last.
_parse_block_fields "REVIEW: BLOCK — location: agg.py:88 | why: swapped operands | rule: swapped-inputs"
[ "$_BLK_RULE" = "swapped-inputs" ]  || fail "(1b) rule (shuffled) mis-parsed (got '$_BLK_RULE')"
[ "$_BLK_WHY" = "swapped operands" ] || fail "(1b) why (shuffled) mis-parsed (got '$_BLK_WHY')"
[ "$_BLK_LOCATION" = "agg.py:88" ]   || fail "(1b) location (shuffled) mis-parsed (got '$_BLK_LOCATION')"
ok

# ── (2) fail-soft: legacy freeform → why only; missing fields stay empty ──────────
_parse_block_fields "REVIEW: BLOCK — off-by-one in the accumulation loop"
[ "$_BLK_WHY" = "off-by-one in the accumulation loop" ] || fail "(2) legacy freeform should become why (got '$_BLK_WHY')"
[ -z "$_BLK_RULE" ]     || fail "(2) legacy freeform must leave rule empty (got '$_BLK_RULE')"
[ -z "$_BLK_LOCATION" ] || fail "(2) legacy freeform must leave location empty (got '$_BLK_LOCATION')"
ok
# Partial structure: only rule + location, no why key → why empty, others set.
_parse_block_fields "REVIEW: BLOCK — rule: mutated-while-iterating | location: build.sh:12"
[ "$_BLK_RULE" = "mutated-while-iterating" ] || fail "(2b) partial rule mis-parsed"
[ "$_BLK_LOCATION" = "build.sh:12" ]         || fail "(2b) partial location mis-parsed"
[ -z "$_BLK_WHY" ]                            || fail "(2b) why should be empty when no why segment (got '$_BLK_WHY')"
ok

# ── (3) _review_gate_step on a structured BLOCK: records BLOCK + caches detail file ─
rm -f "$REVIEW_STATE"
printf 'REVIEW: BLOCK — rule: broken-dedup | why: keys collide on empty id | location: dedup.sh:70\n' \
  > "$(_review_result_file 100 sha100)"
[ "$(_review_gate_step 100 slug100 sha100)" = "BLOCK" ] || fail "(3) structured BLOCK should collect as BLOCK"
[ "$(review_verdict 100 sha100)" = "BLOCK" ]            || fail "(3) BLOCK should be cached in the ledger"
[ "$(review_verdict_source 100 sha100)" = "reviewer" ]  || fail "(3) BLOCK provenance should be 'reviewer'"
blkf="$(_review_block_file 100 sha100)"
[ -s "$blkf" ]                                    || fail "(3) block-detail file should be written"
[ "$(sed -n 1p "$blkf")" = "broken-dedup" ]       || fail "(3) cached rule wrong (got '$(sed -n 1p "$blkf")')"
[ "$(sed -n 2p "$blkf")" = "keys collide on empty id" ] || fail "(3) cached why wrong (got '$(sed -n 2p "$blkf")')"
[ "$(sed -n 3p "$blkf")" = "dedup.sh:70" ]        || fail "(3) cached location wrong (got '$(sed -n 3p "$blkf")')"
ok

# ── (4) _handle_block_verdict injects rule/why/location into the re-task prompt ────
rm -f "$REFIX_STATE" "$REVIEW_STATE"; : > "$PANE_LOG"; : > "$TEXT_LOG"
export STUB_AGENT_NAME="slug100" STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-100"
REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
record_review 100 sha100 BLOCK reviewer   # (block file from (3) is still present for pr=100 sha=sha100)
printf '0\n' > "$STUB_WAIT_FILE"
DISPLAY=()
_handle_block_verdict 100 slug100 sha100 0
[ -s "$PANE_LOG" ] || fail "(4) structured BLOCK should bounce the builder"
grep -q 'Rule violated: broken-dedup'         "$TEXT_LOG" || fail "(4) prompt must surface the rule"
grep -q 'Why: keys collide on empty id'       "$TEXT_LOG" || fail "(4) prompt must surface the why"
grep -q 'Location: dedup.sh:70'               "$TEXT_LOG" || fail "(4) prompt must surface the location"
grep -q 'gh pr view 100'                       "$TEXT_LOG" || fail "(4) prompt must still link the full review"
ok

# ── (5) fail-soft: a BLOCK with NO cached detail still bounces (generic prompt) ────
rm -f "$REFIX_STATE" "$REVIEW_STATE"; : > "$PANE_LOG"; : > "$TEXT_LOG"
rm -f "$(_review_block_file 101 sha101)"     # ensure no detail cached
export STUB_AGENT_NAME="slug101" STUB_AGENT_PANE_ID="pane-101"
record_review 101 sha101 BLOCK reviewer
printf '0\n' > "$STUB_WAIT_FILE"
DISPLAY=()
_handle_block_verdict 101 slug101 sha101 0
[ -s "$PANE_LOG" ] || fail "(5) a detail-less BLOCK must still bounce (backward-compat)"
grep -q 'was review-blocked' "$TEXT_LOG"  || fail "(5) generic prompt should still be sent"
grep -q 'Rule violated:'     "$TEXT_LOG"  && fail "(5) no finding line should appear without cached detail"
ok

# ── (6) _discard_stale_reviews drops a block-detail file for a superseded sha ──────
: > "$(_review_block_file 102 oldsha)"
: > "$(_review_block_file 102 newsha)"
_discard_stale_reviews 102 newsha
[ ! -e "$(_review_block_file 102 oldsha)" ] || fail "(6) stale-sha block file should be discarded"
[ -e "$(_review_block_file 102 newsha)" ]   || fail "(6) current-sha block file must be kept"
ok

# ── (7) source invariant: herd-review.sh prompts instruct the structured shape ────
n="$(grep -c "rule: <which correctness rule was violated> | why: <the reasoning> | location:" "$REVIEW")"
[ "$n" -ge 3 ] || fail "(7) all three reviewer prompts (PR/agent/local) should instruct the structured BLOCK shape (found $n)"
# PASS must remain byte-identical — the literal 'REVIEW: PASS' verdict is untouched.
grep -q "REVIEW: PASS" "$REVIEW" || fail "(7) herd-review.sh must still emit the literal REVIEW: PASS"
ok

echo "ALL PASS ($pass checks)"
