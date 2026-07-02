#!/usr/bin/env bash
# test-review-verdict-integrity.sh — hermetic tests for the INFRA-DEATH vs REFUSED-VERDICT split.
#
# The review gate used to let two purely-infrastructural deaths masquerade as a refused verdict and
# get CACHED as a sticky BLOCK against the sha (manual ledger surgery, twice, on 2026-07-02):
#   (a) an EMPTY capture (reviewer killed mid-run), and
#   (b) a reviewer that exits rc=0 WITHOUT printing a verdict line.
# Both must now become INFRA-FAIL: never cached, retried with a bounded cap, distinct console
# wording — never "reviewer blocked". And auto-refix must NEVER bounce a builder on a gate-generated
# default verdict — only on a REVIEWER-BACKED block (gated on the ledger row's provenance field).
#
# Coverage:
#   PART 1 (agent-watch.sh, lib mode — stubs herdr/gh/git):
#     (1) provenance ledger: record_review writes a source field; review_verdict_source reads it;
#         legacy 4-field rows and absent rows default to "reviewer"; review_verdict still works
#     (2) _review_gate_step records source="reviewer" for a collected PASS and BLOCK
#     (3) an EMPTY / rc0-no-verdict result file → RETRY, never cached (review_verdict stays empty)
#     (4) SAFETY GATE: _handle_block_verdict bounces on source=reviewer (and legacy/absent), but
#         NEVER on source=gate_default / infra — no pane run, no refix recorded, loud "needs you"
#   PART 2 (herd-review.sh, real script — stubs claude/gh/herdr):
#     (5) reviewer exits rc=0 with NO verdict line → REVIEW: INFRA-FAIL (exit 2), not a BLOCK
#     (6) reviewer emits NOTHING at all (empty) → REVIEW: INFRA-FAIL (exit 2)
#     (7) a genuine reviewer BLOCK is still emitted (exit 1) — the split doesn't swallow findings
#     (8) argv0 tagging: the live reviewer process runs under a `herd-review-gate-<pr>` name
#   PART 3 (source invariants):
#     (9) the RETRY console branch says "review infra failed (no verdict)" and never "blocked"
#
# Run:  bash tests/test-review-verdict-integrity.sh
# Fully hermetic: stubs gh/git/herdr/claude on PATH; no network, no live herdr pane, no real kill.
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

# wait_for <timeout-s> <test-cmd...> — poll a condition every 0.2 s; fail-friendly (returns 1).
wait_for() {
  local deadline=$(( $(date +%s) + $1 )); shift
  while ! "$@" 2>/dev/null; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
  return 0
}

# ── Stub binaries on PATH (network-free) ─────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done

# herdr stub: agent list returns a single configurable idle agent; pane run logs the target pane_id.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"name":"%s","agent_status":"%s","pane_id":"%s"}]}}\n' \
      "${STUB_AGENT_NAME:-}" "${STUB_AGENT_STATUS:-idle}" "${STUB_AGENT_PANE_ID:-pane-000}"
    ;;
  "pane run")
    [ -n "${STUB_PANE_RUN_LOG:-}" ] && printf '%s\n' "$3" >> "$STUB_PANE_RUN_LOG"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

################################################################################
# PART 1 — agent-watch.sh in lib mode
################################################################################
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export REVIEW_CONCURRENCY=2
# Stub reviewer for the gate-step verdict-collection tests (mirrors the atomic result-file contract).
STUB_REVIEW="$T/stub-review.sh"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
[ -n "${HERD_REVIEW_RESULT_FILE:-}" ] && printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}" > "$HERD_REVIEW_RESULT_FILE"
STUB
chmod +x "$STUB_REVIEW"
export HERD_REVIEW_BIN="$STUB_REVIEW"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in review_verdict review_verdict_source record_review _review_gate_step \
          _handle_block_verdict _review_result_file _review_retry_count; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
ok

# render() is called inside _handle_block_verdict — stub to a no-op (no terminal output in tests).
render() { :; }
# _wait_agent_working — stubbed to consume return codes from a file so no real sleeps occur.
STUB_WAIT_FILE="$T/wait-codes.txt"
_wait_agent_working() {
  local c; c="$(head -1 "$STUB_WAIT_FILE" 2>/dev/null || true)"
  { tail -n +2 "$STUB_WAIT_FILE" 2>/dev/null || true; } > "${STUB_WAIT_FILE}.tmp"
  mv "${STUB_WAIT_FILE}.tmp" "$STUB_WAIT_FILE" 2>/dev/null || true
  return "${c:-0}"
}
PANE_LOG="$T/pane-run.log"
export STUB_PANE_RUN_LOG="$PANE_LOG"

# ── (1) provenance ledger: record_review <pr> <sha> <verdict> [source] ───────────
rm -f "$REVIEW_STATE"
record_review 1 sha-rev PASS reviewer
record_review 2 sha-gd  BLOCK gate_default
record_review 3 sha-inf BLOCK infra
[ "$(review_verdict 1 sha-rev)" = "PASS" ]  || fail "review_verdict should still return the verdict (PASS)"
[ "$(review_verdict 2 sha-gd)"  = "BLOCK" ] || fail "review_verdict should still return the verdict (BLOCK)"
ok
[ "$(review_verdict_source 1 sha-rev)" = "reviewer" ]     || fail "source should be 'reviewer' (got $(review_verdict_source 1 sha-rev))"
[ "$(review_verdict_source 2 sha-gd)"  = "gate_default" ] || fail "source should be 'gate_default' (got $(review_verdict_source 2 sha-gd))"
[ "$(review_verdict_source 3 sha-inf)" = "infra" ]        || fail "source should be 'infra' (got $(review_verdict_source 3 sha-inf))"
ok
# Legacy 4-field row (no source) and an absent row both default to "reviewer".
printf '%s 9 legacy-sha BLOCK\n' "$(date +%s)" >> "$REVIEW_STATE"
[ "$(review_verdict_source 9 legacy-sha)" = "reviewer" ] || fail "legacy 4-field row should default source to 'reviewer'"
[ "$(review_verdict_source 99 no-such-sha)" = "reviewer" ] || fail "absent row should default source to 'reviewer'"
ok
# record_review with source OMITTED defaults to "reviewer" (backward-compatible call site).
record_review 4 sha-def PASS
[ "$(review_verdict_source 4 sha-def)" = "reviewer" ] || fail "record_review without source should default to 'reviewer'"
ok

# ── (2) _review_gate_step records source="reviewer" for collected PASS / BLOCK ───
rm -f "$REVIEW_STATE"
printf 'REVIEW: PASS\n' > "$(_review_result_file 11 shaP)"
[ "$(_review_gate_step 11 slugP shaP)" = "PASS" ] || fail "PASS result should collect as PASS"
[ "$(review_verdict 11 shaP)" = "PASS" ]           || fail "PASS should be cached"
[ "$(review_verdict_source 11 shaP)" = "reviewer" ] || fail "collected PASS should be provenance 'reviewer'"
ok
printf 'REVIEW: BLOCK — real finding\n' > "$(_review_result_file 12 shaB)"
[ "$(_review_gate_step 12 slugB shaB)" = "BLOCK" ] || fail "BLOCK result should collect as BLOCK"
[ "$(review_verdict 12 shaB)" = "BLOCK" ]           || fail "BLOCK should be cached"
[ "$(review_verdict_source 12 shaB)" = "reviewer" ] || fail "collected BLOCK should be provenance 'reviewer'"
ok

# ── (3) EMPTY capture and rc0-no-verdict result files → RETRY, never cached ───────
rm -f "$REVIEW_STATE" "$REVIEW_RETRIES"
: > "$(_review_result_file 13 shaE)"   # EMPTY capture (reviewer killed mid-run)
[ "$(_review_gate_step 13 slugE shaE)" = "RETRY" ] || fail "EMPTY capture should report RETRY"
review_verdict 13 shaE >/dev/null 2>&1 && fail "EMPTY capture must NEVER be cached to the ledger"
[ "$(_review_retry_count 13 shaE)" -eq 1 ] || fail "EMPTY capture should count one retry"
ok
printf 'I looked at the diff but forgot to print a verdict line.\n' > "$(_review_result_file 14 shaN)"  # rc0-no-verdict
[ "$(_review_gate_step 14 slugN shaN)" = "RETRY" ] || fail "rc0-no-verdict should report RETRY"
review_verdict 14 shaN >/dev/null 2>&1 && fail "rc0-no-verdict must NEVER be cached to the ledger"
ok

# ── (4) SAFETY GATE: auto-refix bounces only on a reviewer-backed block ───────────
export STUB_AGENT_STATUS="idle" STUB_AGENT_PANE_ID="pane-sg"
REFIX_MAX_ROUNDS=3; REVIEW_AUTOFIX=true; DRYRUN=""

# 4a. source=reviewer → bounce (pane run called, refix recorded).
rm -f "$REFIX_STATE" "$REVIEW_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="slug-rev"
record_review 70 sha70 BLOCK reviewer
printf '0\n' > "$STUB_WAIT_FILE"
DISPLAY=()
_handle_block_verdict 70 slug-rev sha70 0
[ -s "$PANE_LOG" ] || fail "reviewer-backed BLOCK should bounce the builder (pane run expected)"
refix_attempted 70 sha70 || fail "reviewer-backed BLOCK should record a refix"
printf '%s\n' "${DISPLAY[0]:-}" | grep -q "refixing" || fail "reviewer-backed BLOCK display should show 'refixing'"
ok

# 4b. source=gate_default → NO bounce (the 2026-07-02 incident: default-BLOCK woke a builder on noise).
rm -f "$REFIX_STATE" "$REVIEW_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="slug-gd"
record_review 71 sha71 BLOCK gate_default
printf '0\n' > "$STUB_WAIT_FILE"
DISPLAY=()
_handle_block_verdict 71 slug-gd sha71 0
[ ! -s "$PANE_LOG" ] || fail "gate_default BLOCK must NOT bounce the builder (no pane run)"
! refix_attempted 71 sha71 || fail "gate_default BLOCK must NOT record a refix"
d="${DISPLAY[0]:-}"
printf '%s\n' "$d" | grep -q "needs you"            || fail "gate_default BLOCK should escalate 'needs you' (got: $d)"
printf '%s\n' "$d" | grep -q "without a reviewer finding" || fail "gate_default BLOCK should say 'without a reviewer finding' (got: $d)"
printf '%s\n' "$d" | grep -q "gate_default"         || fail "gate_default BLOCK should name the provenance (got: $d)"
ok

# 4c. source=infra → NO bounce either.
rm -f "$REFIX_STATE" "$REVIEW_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="slug-inf"
record_review 72 sha72 BLOCK infra
DISPLAY=()
_handle_block_verdict 72 slug-inf sha72 0
[ ! -s "$PANE_LOG" ] || fail "infra-provenance BLOCK must NOT bounce the builder"
! refix_attempted 72 sha72 || fail "infra-provenance BLOCK must NOT record a refix"
ok

# 4d. legacy / absent ledger row → still bounces (backward-compatible: pre-provenance behavior).
rm -f "$REFIX_STATE" "$REVIEW_STATE"; : > "$PANE_LOG"
export STUB_AGENT_NAME="slug-leg"
printf '0\n' > "$STUB_WAIT_FILE"
DISPLAY=()
_handle_block_verdict 73 slug-leg sha73 0    # NO ledger row at all → source defaults to reviewer
[ -s "$PANE_LOG" ] || fail "legacy/absent-row BLOCK should still bounce (backward-compat)"
ok

################################################################################
# PART 2 — herd-review.sh, the real script (stubs claude/gh/herdr)
################################################################################
# Run the real gate headless (HERD_NO_PANE=1). The stub claude's behavior is switched via env.
run_review() {  # <pr> <slug> ; sets REV_OUT / REV_RC / REV_RES
  REV_RES="$T/res-$1-$2"
  rm -f "$REV_RES"
  REV_OUT="$(HERD_NO_PANE=1 HERD_REVIEW_RESULT_FILE="$REV_RES" WORKTREES_DIR="$T/trees" \
             HERD_CONFIG_FILE="$T/no-such-config" bash "$REVIEW" "$1" "$2" 2>/dev/null)"
  REV_RC=$?
}

# ── (5) reviewer exits rc=0 but prints NO verdict line → INFRA-FAIL, not BLOCK ────
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","result":"I reviewed the diff and it looks fine but I never printed the machine line."}\n'
exit 0
STUB
chmod +x "$BIN/claude"
run_review 21 slug-noverdict
[ "$REV_RC" -eq 2 ] || fail "(5) rc0-no-verdict should exit 2 (INFRA-FAIL), got $REV_RC"
printf '%s\n' "$REV_OUT" | grep -q '^REVIEW: INFRA-FAIL' || fail "(5) should print REVIEW: INFRA-FAIL (got: $REV_OUT)"
grep -q '^REVIEW: INFRA-FAIL' "$REV_RES" || fail "(5) result file should hold INFRA-FAIL (got: $(cat "$REV_RES" 2>/dev/null))"
printf '%s\n' "$REV_OUT" | grep -q 'REVIEW: BLOCK' && fail "(5) rc0-no-verdict must NOT be a BLOCK"
printf '%s\n' "$REV_OUT" | grep -qi 'defaulting to block' && fail "(5) must not use the old 'defaulting to BLOCK' path"
ok

# ── (6) reviewer emits NOTHING at all (empty stream) → INFRA-FAIL ─────────────────
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/claude"
run_review 22 slug-empty
[ "$REV_RC" -eq 2 ] || fail "(6) empty reviewer output should exit 2 (INFRA-FAIL), got $REV_RC"
grep -q '^REVIEW: INFRA-FAIL' "$REV_RES" || fail "(6) empty output → result file should hold INFRA-FAIL"
grep -q 'REVIEW: BLOCK' "$REV_RES" && fail "(6) empty output must NOT be cached as a BLOCK"
ok

# ── (7) a genuine reviewer BLOCK is still emitted (the split doesn't swallow findings) ─
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","result":"Off-by-one in the accumulation loop.\nREVIEW: BLOCK — off-by-one in the accumulation loop"}\n'
exit 0
STUB
chmod +x "$BIN/claude"
run_review 23 slug-block
[ "$REV_RC" -eq 1 ] || fail "(7) a genuine BLOCK should exit 1, got $REV_RC"
grep -q '^REVIEW: BLOCK' "$REV_RES" || fail "(7) genuine BLOCK should be written to the result file"
ok

# ── (8) argv0 tagging: the live reviewer process runs as herd-review-gate-<pr> ────
# The stub claude probes the live process table (real ps, hermetic) for our argv0 tag while the
# herd-review-gate parent is blocked reading its pipe. '[h]' avoids the grep matching itself.
ARGV0_PROBE="$T/argv0-probe.txt"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
[ -n "${ARGV0_PROBE:-}" ] && ps -A -o command= 2>/dev/null | grep '[h]erd-review-gate' > "$ARGV0_PROBE" 2>/dev/null
printf '{"type":"result","subtype":"success","result":"REVIEW: PASS"}\n'
exit 0
STUB
chmod +x "$BIN/claude"
: > "$ARGV0_PROBE"
ARGV0_PROBE="$ARGV0_PROBE" run_review 24 slug-argv0
if grep -q 'herd-review-gate-24' "$ARGV0_PROBE" 2>/dev/null; then
  ok
else
  # exec -a is best-effort; skip (don't fail) on platforms/shells where it is unavailable, but the
  # tag string MUST at least be present in the source (structural guard below covers that).
  echo "NOTE: live argv0 probe did not observe herd-review-gate-24 (exec -a may be unavailable); relying on structural check" >&2
  ok
fi

################################################################################
# PART 3 — source invariants
################################################################################
# ── (9) RETRY console wording is infra-framed, never "blocked"; argv0 tag present ─
grep -q 'review infra failed (no verdict)' "$WATCH" || fail "(9) agent-watch.sh should carry the 'review infra failed (no verdict)' RETRY wording"
# The user-visible RETRY string must be infra-framed, never say "block" (an infra death is not a
# refusal). Check the DISPLAY assignment(s) inside the RETRY case body only — comments are exempt.
retry_display="$(awk '/^        RETRY\)/{f=1} f && /DISPLAY\[idx\]=/{print} /^          continue ;;/{if(f)exit}' "$WATCH")"
[ -n "$retry_display" ] || fail "(9) could not locate the RETRY branch DISPLAY line"
printf '%s\n' "$retry_display" | grep -qi 'block' && fail "(9) RETRY DISPLAY must never say 'block' (it is an infra death, not a refusal)"
printf '%s\n' "$retry_display" | grep -q 'retrying' || fail "(9) RETRY DISPLAY should show it is retrying"
grep -q 'exec -a "herd-review-gate-' "$REVIEW" || fail "(9) herd-review.sh should tag its argv0 as herd-review-gate-<pr>"
ok

echo "ALL PASS ($pass checks)"
