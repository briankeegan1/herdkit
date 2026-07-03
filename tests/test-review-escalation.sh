#!/usr/bin/env bash
# test-review-escalation.sh — hermetic tests for EVIDENCE-TRIGGERED review escalation in agent-watch.sh.
#
# The pre-merge review gate normally picks its reviewer model from the risk tier (STRONG default, or
# CHEAP for a small low-risk diff when REVIEW_ESCALATE_GLOB is set). But a CHEAP reviewer that PASSes
# a diff the builder then has to refix — TWICE — is evidence the reviewer missed the real issue. After
# a builder's second refix round still arrives BLOCKed on a PR (refix_round_count reaches
# REVIEW_EVIDENCE_ESCALATE_ROUNDS, default 2), the gate ARMS a one-shot Opus escalation for that PR;
# the NEXT review dispatch is forced onto $REVIEW_MODEL_ESCALATED (claude-opus-4-8), overriding the
# risk tier. The arm is CONSUMED by that dispatch, so a later clean commit is not needlessly escalated.
#
# Proves the mandated cases:
#   (1) first-round BLOCK + second BLOCK on the same PR → the THIRD review dispatch uses the escalated
#       Opus model (overriding the cheap tier), and emits the ESCALATED step-up token + journal event
#   (2) NO escalation on the first BLOCK (one refix round → the tier model, not Opus)
#   (3) a new commit sha RESETS the escalation: after the escalated dispatch consumes the arm, the next
#       new-sha dispatch on the same PR is back on the tier model, not Opus
#   plus: escalation overrides even the glob-empty DEFAULT path (forces Opus, not $MODEL_REVIEW)
#
# Sources agent-watch.sh in lib mode with HERD_REVIEW_BIN pointed at a stub reviewer that logs the
# model it was dispatched on. Stubs gh/git/herdr — NETWORK-FREE, never spawns a real reviewer.
# Run:  bash tests/test-review-escalation.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
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

# ── Stub binaries on PATH ─────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in git herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"
done
# gh stub: only `gh pr diff <pr> --name-only` matters — emits $STUB_DIFF_PATHS. Everything else no-ops.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "diff" ]; then
  [ -n "${STUB_DIFF_PATHS:-}" ] && printf '%s\n' "$STUB_DIFF_PATHS"
  exit 0
fi
exit 0
GH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# ── Stub reviewer (stands in for herd-review.sh via the HERD_REVIEW_BIN seam) ─
# Logs "<pr> <model>" to $STUB_SPAWN_LOG where <model> is the tier the watcher dispatched it on
# (HERD_REVIEW_MODEL, or DEFAULT when unset). Writes the verdict atomically as its last act.
STUB_REVIEW="$T/stub-review.sh"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
pr="$1"
[ -n "${STUB_SPAWN_LOG:-}" ] && printf '%s %s\n' "$pr" "${HERD_REVIEW_MODEL:-DEFAULT}" >> "$STUB_SPAWN_LOG"
sleep "${STUB_DELAY:-0}"
if [ -n "${HERD_REVIEW_RESULT_FILE:-}" ]; then
  printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}" > "$HERD_REVIEW_RESULT_FILE.tmp.$$"
  mv "$HERD_REVIEW_RESULT_FILE.tmp.$$" "$HERD_REVIEW_RESULT_FILE"
fi
printf '%s\n' "${STUB_VERDICT:-REVIEW: PASS}"
STUB
chmod +x "$STUB_REVIEW"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
export HERD_REVIEW_BIN="$STUB_REVIEW"
export REVIEW_CONCURRENCY=5           # high enough that nothing QUEUEs in these tests
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _review_gate_step _dispatch_review _review_escalate_file _maybe_arm_review_escalation \
          record_refix refix_round_count; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
# Escalation defaults: 2 failed refix rounds, step up to Opus.
[ "${REVIEW_EVIDENCE_ESCALATE_ROUNDS:-2}" = "2" ] || fail "REVIEW_EVIDENCE_ESCALATE_ROUNDS default should be 2"
ESC_MODEL="${REVIEW_MODEL_ESCALATED:-claude-opus-4-8}"
[ "$ESC_MODEL" = "claude-opus-4-8" ] || fail "escalation target should be claude-opus-4-8 (got $ESC_MODEL)"
ok

export STUB_SPAWN_LOG="$T/spawns.log"; : > "$STUB_SPAWN_LOG"
export STUB_DELAY=0 STUB_VERDICT="REVIEW: PASS"
# A small, non-engine diff → the CHEAP tier, so escalation is visibly distinguishable from the tier.
GLOB='^bin/|^scripts/herd/agent-watch|herd-review'
export STUB_DIFF_PATHS=$'scripts/herd/journal.sh'

# dispatched_model <pr> — the model logged for the most recent dispatch of this PR.
dispatched_model() { awk -v p="$1" '$1==p{m=$2} END{print m}' "$STUB_SPAWN_LOG"; }

# ── UNIT: the arm marker is set only once the round threshold is crossed ──────
PR=400
record_refix "$PR" shaA slug-esc
_maybe_arm_review_escalation "$PR"
[ ! -f "$(_review_escalate_file "$PR")" ] || fail "(arm) one failed round must NOT arm escalation"
ok
record_refix "$PR" shaB slug-esc
_maybe_arm_review_escalation "$PR"
[ -f "$(_review_escalate_file "$PR")" ] || fail "(arm) the second failed round MUST arm escalation"
ok

# ── (1) THIRD dispatch (armed) → Opus, overriding the CHEAP tier ─────────────
REVIEW_ESCALATE_GLOB="$GLOB"   # tiering active: without escalation this diff would be CHEAP
step="$(_review_gate_step "$PR" slug-esc shaC)"
[ "$step" = "ESCALATED" ] || fail "(1) armed dispatch should report ESCALATED (got $step)"
wait_for 5 grep -q '^400 ' "$STUB_SPAWN_LOG" || fail "(1) escalated reviewer never spawned"
[ "$(dispatched_model "$PR")" = "$ESC_MODEL" ] \
  || fail "(1) armed PR must dispatch on Opus $ESC_MODEL (got $(dispatched_model "$PR"))"
ok
# The arm is CONSUMED by that dispatch.
[ ! -f "$(_review_escalate_file "$PR")" ] || fail "(1) the escalation arm must be consumed by dispatch"
ok
# (d) a durable journal record of the review-lane step-up.
grep -q '"event":"review_escalated"' "$JOURNAL_FILE" || fail "(1) review_escalated journal event missing"
grep -q "\"model\":\"$ESC_MODEL\"" "$JOURNAL_FILE"   || fail "(1) journal escalation must name the Opus model"
ok

# ── (3) a NEW commit sha resets the escalation → next dispatch back on the tier ─
# The arm was consumed above; a fresh sha with no re-arm dispatches on the CHEAP tier, not Opus.
: > "$STUB_SPAWN_LOG"
step="$(_review_gate_step "$PR" slug-esc shaD)"
[ "$step" = "RUNNING" ] || fail "(3) post-consume dispatch should be a plain RUNNING (got $step)"
wait_for 5 grep -q '^400 ' "$STUB_SPAWN_LOG" || fail "(3) reviewer never spawned for the new sha"
[ "$(dispatched_model "$PR")" = "$REVIEW_MODEL_CHEAP" ] \
  || fail "(3) a new sha must reset escalation back to the CHEAP tier (got $(dispatched_model "$PR"))"
ok

# ── (2) NO escalation on the FIRST BLOCK (one refix round → tier model, not Opus) ─
PR2=401
: > "$STUB_SPAWN_LOG"
record_refix "$PR2" shaA slug-two
_maybe_arm_review_escalation "$PR2"
[ ! -f "$(_review_escalate_file "$PR2")" ] || fail "(2) a single BLOCK must not arm escalation"
step="$(_review_gate_step "$PR2" slug-two shaB)"
[ "$step" = "RUNNING" ] || fail "(2) unescalated dispatch should be RUNNING (got $step)"
wait_for 5 grep -q '^401 ' "$STUB_SPAWN_LOG" || fail "(2) reviewer never spawned"
[ "$(dispatched_model "$PR2")" = "$REVIEW_MODEL_CHEAP" ] \
  || fail "(2) first BLOCK must dispatch on the CHEAP tier, not Opus (got $(dispatched_model "$PR2"))"
ok

# ── escalation overrides even the glob-EMPTY default path (forces Opus, not the default) ──
# With REVIEW_ESCALATE_GLOB empty the gate normally leaves HERD_REVIEW_MODEL unset (→ DEFAULT). An
# armed PR must still force Opus — evidence escalation is independent of the risk-tier opt-in.
PR3=402
REVIEW_ESCALATE_GLOB=""
: > "$STUB_SPAWN_LOG"
record_refix "$PR3" shaA slug-def
record_refix "$PR3" shaB slug-def
_maybe_arm_review_escalation "$PR3"
[ -f "$(_review_escalate_file "$PR3")" ] || fail "(default) two rounds must arm regardless of the glob"
step="$(_review_gate_step "$PR3" slug-def shaC)"
[ "$step" = "ESCALATED" ] || fail "(default) armed dispatch should report ESCALATED even with glob empty (got $step)"
wait_for 5 grep -q '^402 ' "$STUB_SPAWN_LOG" || fail "(default) escalated reviewer never spawned"
[ "$(dispatched_model "$PR3")" = "$ESC_MODEL" ] \
  || fail "(default) escalation must force Opus even on the glob-empty path (got $(dispatched_model "$PR3"))"
ok

echo "ALL PASS ($pass checks)"
