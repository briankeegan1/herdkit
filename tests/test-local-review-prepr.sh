#!/usr/bin/env bash
# test-local-review-prepr.sh — hermetic tests for LOCAL_REVIEW=pre-pr wiring.
#
# The LOCAL_REVIEW config key was added key-only by the flow-preference PR; this exercises the wiring
# that consumes it. Three hermetic layers, NO network / NO real herdr / NO real gh / NO real claude:
#
#   PART A — the builder lanes (herd-quick.sh / herd-feature.sh) thread LOCAL_REVIEW into the
#            workflow-rules text of the externalized task spec:
#              · LOCAL_REVIEW=none (DEFAULT / unset)  → the rules are byte-unchanged: NO local-review
#                step, NO `herd-review.sh --local` (today's post-PR-only review).
#              · LOCAL_REVIEW=pre-pr                   → a pre-`gh pr create` step that runs
#                `herd-review.sh --local <slug>` and requires a 'REVIEW: PASS' before the PR.
#              · UNKNOWN value falls back SAFELY to none.
#
#   PART B — herd-review.sh --local <slug> (the REAL script, stubbed claude): reviews the LOCAL
#            worktree diff and honours the same PASS/BLOCK/INFRA-FAIL contract + exit codes as PR
#            mode, reading 'git diff DEFAULT_BRANCH...HEAD' and posting NO PR comment.
#
#   PART C — agent-watch.sh KEEPS the post-PR review as belt-and-suspenders (never trust-skips on a
#            builder marker) — a structural guard on the documented decision.
#
# Lane scaffold mirrors tests/test-flow-preference.sh; the --local scaffold mirrors
# tests/test-review-verdict-integrity.sh PART 2.
# Run:  bash tests/test-local-review-prepr.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
QUICK="$REPO/scripts/herd/herd-quick.sh"
FEATURE="$REPO/scripts/herd/herd-feature.sh"
REVIEW="$REPO/scripts/herd/herd-review.sh"
WATCH="$REPO/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git     >/dev/null 2>&1 || fail "git required to run this test"
[ -f "$REVIEW" ] || fail "herd-review.sh not found at $REVIEW"
[ -f "$WATCH" ]  || fail "agent-watch.sh not found at $WATCH"

# ── Shared scaffold — stubbed herdr/claude + throwaway repo (mirrors test-flow-preference PART B) ──
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "tab list")       printf '{"result":{"tabs":[]}}\n' ;;
  "tab create")     printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start")    printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  "agent list")     printf '{"result":{"agents":[]}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
# Default claude stub for the LANE scaffold (never actually reviews in PART A — just exits clean).
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

GREPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$GREPO" 2>/dev/null
git -C "$GREPO" checkout -q -b main
: > "$GREPO/seed.txt"
git -C "$GREPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$GREPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$GREPO" push -q -u origin main 2>/dev/null

export HOME="$T"                # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit" # matches the herdr stub's workspace label
export HERD_SKIP_PREFLIGHT=1    # no real herdr contract to probe
TREES="$T/trees"
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
# NOTE: the config deliberately OMITS LOCAL_REVIEW so each case sets it via the environment
# (herd-config.sh sources this file but never assigns that key, so the env var wins).
cat > "$CFG" <<EOF
PROJECT_ROOT="$GREPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit"
APP_PREVIEW_CMD=""
MODEL_QUICK="test-quick-model"
MODEL_FEATURE="test-feature-model"
MODEL_REVIEW="test-review-model"
EOF

################################################################################
# PART A — the lanes thread LOCAL_REVIEW into the externalized spec
################################################################################
# run_lane <script> <slug> [ENV=val ...] — run a lane with the given env, print the spec path.
run_lane(){
  local script="$1" slug="$2"; shift 2
  local o="$T/$slug.out"
  if ! HERD_NO_APP=1 env "$@" bash "$script" "$slug" "seed task body" >"$o" 2>&1; then
    fail "lane $(basename "$script") exited non-zero for '$slug'"$'\n'"$(cat "$o")"
  fi
  local spec="$TREES/$slug.task.md"
  [ -f "$spec" ] || fail "$slug: spec file not written at $spec"
  printf '%s' "$spec"
}
has(){  grep -Fq -- "$2" "$1" || fail "$3: spec missing expected text: $2"$'\n'"---"$'\n'"$(cat "$1")"; }
lacks(){ grep -Fq -- "$2" "$1" && fail "$3: spec UNEXPECTEDLY contains: $2"$'\n'"---"$'\n'"$(cat "$1")"; return 0; }

# ── A1 — DEFAULT (no LOCAL_REVIEW): NO local-review step (byte-unchanged post-PR-only). Both lanes. ──
for pair in "$QUICK:def-quick" "$FEATURE:def-feat"; do
  s="$(run_lane "${pair%%:*}" "${pair##*:}")"
  has  "$s" "Before running 'gh pr create'," "A1 ${pair##*:}"
  lacks "$s" "herd-review.sh --local"        "A1 ${pair##*:}"
  lacks "$s" "REVIEW: PASS"                   "A1 ${pair##*:}"
  ok
done

# ── A2 — LOCAL_REVIEW=pre-pr: pre-`gh pr create` local review gated on REVIEW: PASS. Both lanes. ──
for pair in "$QUICK:pre-quick" "$FEATURE:pre-feat"; do
  s="$(run_lane "${pair%%:*}" "${pair##*:}" LOCAL_REVIEW=pre-pr)"
  has "$s" "herd-review.sh --local"          "A2 ${pair##*:}"
  has "$s" "REVIEW: PASS"                     "A2 ${pair##*:}"
  has "$s" "REVIEW: BLOCK"                    "A2 ${pair##*:}"
  # the review MUST come BEFORE opening the PR (the local-review sentence names 'gh pr create').
  has "$s" "before running 'gh pr create'"   "A2 ${pair##*:}"
  ok
done

# ── A3 — UNKNOWN LOCAL_REVIEW falls back to none (no local-review step) ──────────────────────────
s="$(run_lane "$QUICK" "bogus-lr" LOCAL_REVIEW=sideways)"
lacks "$s" "herd-review.sh --local"        "A3"
has   "$s" "Before running 'gh pr create'," "A3"
ok

################################################################################
# PART B — herd-review.sh --local <slug>, the REAL script (stubs claude)
################################################################################
# Recording claude stub: logs its argv (NUL-separated) and emits a stream-json result whose text is
# the configured verdict (or an infra-shaped no-verdict / empty run).
CLAUDE_ARGS_LOG="$T/claude-args.log"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
[ -n "${CLAUDE_ARGS_LOG:-}" ] && printf '%s\0' "$@" >> "$CLAUDE_ARGS_LOG"
case "${STUB_LOCAL_MODE:-verdict}" in
  noverdict) printf '{"type":"result","subtype":"success","result":"I read the diff but never printed the machine line."}\n' ;;
  empty)     : ;;
  *)         printf '{"type":"result","subtype":"success","result":"%s"}\n' "${STUB_LOCAL_VERDICT:-REVIEW: PASS}" ;;
esac
exit 0
STUB
chmod +x "$BIN/claude"

run_local(){  # <slug> ; sets LR_OUT / LR_RC (claude behavior comes from STUB_LOCAL_* env)
  : > "$CLAUDE_ARGS_LOG"
  LR_OUT="$(HERD_NO_PANE=1 CLAUDE_ARGS_LOG="$CLAUDE_ARGS_LOG" WORKTREES_DIR="$TREES" \
            HERD_CONFIG_FILE="$CFG" bash "$REVIEW" --local "$1" 2>/dev/null)"
  LR_RC=$?
}

# ── B1 — local PASS → REVIEW: PASS, exit 0 ────────────────────────────────────────────────────────
STUB_LOCAL_MODE=verdict STUB_LOCAL_VERDICT="REVIEW: PASS" run_local slug-pass
[ "$LR_RC" -eq 0 ] || fail "B1: local PASS should exit 0 (got $LR_RC)"$'\n'"$LR_OUT"
printf '%s\n' "$LR_OUT" | grep -q '^REVIEW: PASS' || fail "B1: should print REVIEW: PASS (got: $LR_OUT)"
ok

# ── B2 — local BLOCK → REVIEW: BLOCK, exit 1 ──────────────────────────────────────────────────────
STUB_LOCAL_MODE=verdict STUB_LOCAL_VERDICT="REVIEW: BLOCK — off-by-one in the accumulation loop" run_local slug-block
[ "$LR_RC" -eq 1 ] || fail "B2: local BLOCK should exit 1 (got $LR_RC)"$'\n'"$LR_OUT"
printf '%s\n' "$LR_OUT" | grep -q '^REVIEW: BLOCK' || fail "B2: should print REVIEW: BLOCK (got: $LR_OUT)"
ok

# ── B3 — reviewer prints no verdict line → INFRA-FAIL, exit 2 (never a BLOCK) ─────────────────────
STUB_LOCAL_MODE=noverdict run_local slug-noverdict
[ "$LR_RC" -eq 2 ] || fail "B3: rc0-no-verdict should exit 2 INFRA-FAIL (got $LR_RC)"$'\n'"$LR_OUT"
printf '%s\n' "$LR_OUT" | grep -q '^REVIEW: INFRA-FAIL' || fail "B3: should print REVIEW: INFRA-FAIL (got: $LR_OUT)"
printf '%s\n' "$LR_OUT" | grep -q 'REVIEW: BLOCK' && fail "B3: no-verdict must NOT be a BLOCK"
ok

# ── B4 — empty reviewer output → INFRA-FAIL, exit 2 ──────────────────────────────────────────────
STUB_LOCAL_MODE=empty run_local slug-empty
[ "$LR_RC" -eq 2 ] || fail "B4: empty output should exit 2 INFRA-FAIL (got $LR_RC)"$'\n'"$LR_OUT"
printf '%s\n' "$LR_OUT" | grep -q '^REVIEW: INFRA-FAIL' || fail "B4: empty output should print INFRA-FAIL"
ok

# ── B5 — local mode reviews the LOCAL diff (git diff), NOT a PR (no gh pr diff / no PR comment) ───
STUB_LOCAL_MODE=verdict STUB_LOCAL_VERDICT="REVIEW: PASS" run_local slug-diff
# The reviewer prompt claude received must instruct a LOCAL diff read and must NOT reference a PR.
tr '\0' '\n' < "$CLAUDE_ARGS_LOG" | grep -Fq 'git diff origin/main...HEAD' \
  || fail "B5: local prompt should tell the reviewer to run 'git diff origin/main...HEAD'"$'\n'"$(tr '\0' '\n' < "$CLAUDE_ARGS_LOG")"
tr '\0' '\n' < "$CLAUDE_ARGS_LOG" | grep -Fq 'gh pr diff' \
  && fail "B5: local prompt must NOT reference 'gh pr diff' (there is no PR yet)"
tr '\0' '\n' < "$CLAUDE_ARGS_LOG" | grep -Fq 'gh pr comment' \
  && fail "B5: local prompt must NOT ask for a 'gh pr comment' (there is no PR yet)"
ok

# ── B6 — no accidental mode leak: with NO --local flag the script still needs <pr> <slug> (PR mode) ─
# Calling with a single non-flag arg must fail usage (PR mode requires two positional args), proving
# --local is the ONLY switch into local mode.
rc=0
HERD_NO_PANE=1 WORKTREES_DIR="$TREES" HERD_CONFIG_FILE="$CFG" bash "$REVIEW" only-one-arg >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "B6: PR mode with a single arg should fail usage (proves --local is required for local mode)"
ok

################################################################################
# PART C — agent-watch.sh keeps the post-PR review (belt-and-suspenders)
################################################################################
# The documented decision: LOCAL_REVIEW=pre-pr does NOT let the watcher trust-skip its own review.
grep -q 'belt-and-suspenders' "$WATCH" \
  || fail "C: agent-watch.sh should document the belt-and-suspenders decision (never trust-skip a local pre-PR review)"
grep -q 'LOCAL_REVIEW=pre-pr' "$WATCH" \
  || fail "C: agent-watch.sh should mention LOCAL_REVIEW=pre-pr in the review-dispatch note"
# The dispatch call itself is unconditional (no LOCAL_REVIEW guard around _dispatch_review).
grep -q 'HERD_REVIEW_RESULT_FILE="\$result".*bash "\$HERD_REVIEW_BIN"' "$WATCH" \
  || fail "C: the post-PR review dispatch must remain unconditional"
ok

echo "ALL PASS ($pass checks)"
