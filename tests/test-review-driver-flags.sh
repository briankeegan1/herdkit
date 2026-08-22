#!/usr/bin/env bash
# test-review-driver-flags.sh — HERD-775: the pre-merge reviewer must hand each runtime ITS OWN flags.
#
# Live incident (2026-08-18): MODEL_REVIEW=codex:gpt-5.6-sol made herd-review.sh compose
#   codex exec --model gpt-5.6-sol --dangerously-bypass-approvals-and-sandbox "<prompt>" \
#     --dangerously-skip-permissions --output-format stream-json --verbose
# because every dispatch site appended the hardcoded $CLAUDE_FLAGS + claude's stream-json output flags
# regardless of the resolved driver. codex rejects `--dangerously-skip-permissions` on argv, so every
# review exited rc=2 with no verdict → INFRA → the PR livelocked BLOCKED under a green CI (114 INFRA
# events on one PR). Sibling of HERD-770 (the same leak in the research/scribe drainers).
#
# Contract proven here, through the REAL herd-review.sh (HERD_NO_PANE=1) against recording stub
# runtimes:
#   (1) codex-resolved MODEL_REVIEW → the codex runtime receives ITS permission flag
#       (--dangerously-bypass-approvals-and-sandbox, from templates/drivers/codex.driver) and NONE of
#       claude's flags (--dangerously-skip-permissions / --output-format / --verbose / stream-json);
#       the verdict line the runtime prints on stdout is still parsed (exit 0 = PASS).
#   (2) bare (claude) MODEL_REVIEW → BYTE-IDENTICAL to before: exactly
#       `--dangerously-skip-permissions --output-format stream-json --verbose`, in that order.
#   (3) HERD_CLAUDE_FLAGS override still wins verbatim — for claude AND for a non-claude runtime
#       (the HERD-201 seam's stated precedence), while the claude-only output flags stay claude-only.
#   (4) the local (pre-PR) path uses the same derivation (source-level: no dispatch site left on the
#       raw $CLAUDE_FLAGS + literal output flags).
# Hermetic: stub gh/git/herdr/pgrep, a throwaway project, no network. Run: bash tests/test-review-driver-flags.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REVIEW="$ROOT/scripts/herd/herd-review.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASSN=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASSN=$((PASSN+1)); }

BIN="$T/bin"; mkdir -p "$BIN"
for cmd in pgrep gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

P="$T/proj"; mkdir -p "$P/.herd" "$P/trees"
P_REAL="$(cd "$P" && pwd -P)"
cat > "$P/.herd/config" <<CFG
HERD_VERSION=1
PROJECT_ROOT="$P_REAL"
WORKTREES_DIR="$P_REAL/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="testproj"
MODEL_REVIEW="claude-sonnet-4-6"
CFG

# Recording runtimes: log the FULL argv (one arg per line, NUL-safe enough for flags) to
# $REVIEW_CALLS.<name>, then print a PASS verdict the way each runtime really would —
# claude as a stream-json result event, codex as plain final-message text on stdout.
export REVIEW_CALLS="$T/calls"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REVIEW_CALLS.claude"
printf '{"type":"result","subtype":"success","result":"REVIEW: PASS"}\n'
STUB
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REVIEW_CALLS.codex"
# Real codex exec rejects an unknown flag on argv — mirror that so the leak is FATAL here too.
for a in "$@"; do
  case "$a" in
    --dangerously-skip-permissions|--output-format|--verbose|stream-json)
      echo "error: unexpected argument '$a' found" >&2; exit 2 ;;
  esac
done
printf 'REVIEW: PASS\n'
STUB
chmod +x "$BIN/claude" "$BIN/codex"

_review(){
  rm -f "$REVIEW_CALLS".*
  set +e
  REVIEW_OUT="$(env "$@" \
    HERD_NO_PANE=1 \
    WORKTREES_DIR="$P_REAL/trees" \
    HERD_CONFIG_FILE="$T/no-such-config" \
    JOURNAL_FILE="$T/journal" \
    HERD_REVIEW_RESULT_FILE="$T/res" \
    REVIEW_CALLS="$REVIEW_CALLS" \
    bash "$REVIEW" "42" "slug-42" 2>&1)"
  RC=$?
  set -e
}
_argv_has(){ grep -qxF -- "$2" "$1"; }

# ── (1) codex-resolved reviewer: codex flags only, verdict parsed ────────────────────────────────
_review HERD_REVIEW_MODEL="codex:gpt-5.6-sol"
[ -f "$REVIEW_CALLS.codex" ] || fail "(1) codex:… MODEL_REVIEW must dispatch the codex runtime (out: $REVIEW_OUT)"
[ ! -f "$REVIEW_CALLS.claude" ] || fail "(1) codex:… MODEL_REVIEW must NOT also launch claude"
_argv_has "$REVIEW_CALLS.codex" "exec" || fail "(1) codex argv must be the driver's oneshot shape (codex exec …): $(tr '\n' ' ' < "$REVIEW_CALLS.codex")"
_argv_has "$REVIEW_CALLS.codex" "--dangerously-bypass-approvals-and-sandbox" \
  || fail "(1) codex must receive ITS permission flag: $(tr '\n' ' ' < "$REVIEW_CALLS.codex")"
for bad in --dangerously-skip-permissions --output-format stream-json --verbose; do
  _argv_has "$REVIEW_CALLS.codex" "$bad" && fail "(1) claude-only flag '$bad' leaked into the codex reviewer argv: $(tr '\n' ' ' < "$REVIEW_CALLS.codex")"
done
[ "$(grep -cx -- '--json' "$REVIEW_CALLS.codex" || true)" = "1" ] \
  || fail "(1) Codex reviewer must request its documented JSON event stream"
[ "$RC" -eq 0 ] || fail "(1) codex reviewer printed 'REVIEW: PASS' on stdout — the gate must parse it as PASS (rc=$RC, out: $REVIEW_OUT)"
ok; echo "PASS (1) codex-resolved reviewer gets codex flags only and its verdict is parsed"

# ── (2) bare claude reviewer: byte-identical flag tail ──────────────────────────────────────────
_review HERD_REVIEW_MODEL="claude-opus-4-8"
[ -f "$REVIEW_CALLS.claude" ] || fail "(2) bare MODEL_REVIEW must dispatch claude (out: $REVIEW_OUT)"
tail_n="$(tail -n 4 "$REVIEW_CALLS.claude" | tr '\n' ' ')"
[ "$tail_n" = "--dangerously-skip-permissions --output-format stream-json --verbose " ] \
  || fail "(2) claude argv tail must be byte-identical to pre-HERD-775 (got: '$tail_n')"
[ "$RC" -eq 0 ] || fail "(2) claude PASS verdict must still parse (rc=$RC)"
ok; echo "PASS (2) claude reviewer argv is byte-identical"

# ── (3) HERD_CLAUDE_FLAGS override wins verbatim on both runtimes; output flags stay claude-only ──
_review HERD_REVIEW_MODEL="claude-opus-4-8" HERD_CLAUDE_FLAGS="--permission-mode plan"
tail_n="$(tail -n 5 "$REVIEW_CALLS.claude" | tr '\n' ' ')"
[ "$tail_n" = "--permission-mode plan --output-format stream-json --verbose " ] \
  || fail "(3a) HERD_CLAUDE_FLAGS must replace the permission flag verbatim for claude (got: '$tail_n')"
_review HERD_REVIEW_MODEL="codex:gpt-5.6-sol" HERD_CLAUDE_FLAGS="--approve-for-me"
_argv_has "$REVIEW_CALLS.codex" "--approve-for-me" \
  || fail "(3b) HERD_CLAUDE_FLAGS override must win verbatim for a non-claude runtime too (HERD-201 precedence): $(tr '\n' ' ' < "$REVIEW_CALLS.codex")"
_argv_has "$REVIEW_CALLS.codex" "--dangerously-bypass-approvals-and-sandbox" \
  && fail "(3b) with an explicit override the driver's own flag must NOT also be appended"
for bad in --output-format stream-json --verbose; do
  _argv_has "$REVIEW_CALLS.codex" "$bad" && fail "(3b) claude output flag '$bad' must never reach codex"
done
ok; echo "PASS (3) HERD_CLAUDE_FLAGS override precedence preserved on both runtimes"

# ── (4) source-level: no dispatch site left on the raw literal ─────────────────────────────────
_sites="$(grep -n 'herd_driver_oneshot_exec_as' "$REVIEW" || true)"
grep -q '\$CLAUDE_FLAGS' <<<"$_sites" \
  && fail "(4) a herd_driver_oneshot_exec_as site still appends the raw \$CLAUDE_FLAGS — route it through _review_runtime_flags"
grep -q -- '--output-format stream-json' <<<"$_sites" \
  && fail "(4) a herd_driver_oneshot_exec_as site still hardcodes claude's stream-json output flags"
n="$(grep -c '_review_runtime_flags "' "$REVIEW" || true)"
[ "${n:-0}" -ge 3 ] || fail "(4) expected the panel, local and headless dispatch sites (>=3) to use _review_runtime_flags (found $n)"
grep -q 'flags="\$(herd_driver_lane_permission_flags "\$_REVIEW_DRV"' "$REVIEW" \
  || fail "(4) the interactive reviewer launch (herd_driver_launch_agent) must derive its flags via herd_driver_lane_permission_flags"
ok; echo "PASS (4) every reviewer dispatch site derives runtime flags per driver"

echo ""
echo "ALL $PASSN tests PASSED — HERD-775 reviewer hands each runtime its own flags"
