#!/usr/bin/env bash
# test-review-rubric-injection.sh — hermetic proof for RUBRIC_FILE (HERD-400, docs/rubric-primitive.md).
#
# WHY: herd-review.sh renders RUBRIC_BLOCK/RUBRIC_BLOCK_AGENT (~line 279-300) from $RUBRIC_FILE —
# a structured per-unit review rubric — and appends it to all four reviewer prompt sites. Nothing
# asserted that wiring; this is that test. Scaffold mirrors tests/test-review-checklist-injection.sh
# (stub herdr + a recording claude stub, a throwaway git repo, herd-review.sh --local <slug>).
#
# Run:  bash tests/test-review-rubric-injection.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REVIEW="$REPO/scripts/herd/herd-review.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git     >/dev/null 2>&1 || fail "git required to run this test"
[ -f "$REVIEW" ] || fail "herd-review.sh not found at $REVIEW"

# ── Shared scaffold — stubbed herdr/claude + throwaway repo (mirrors test-review-checklist-injection.sh) ──
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

CLAUDE_ARGS_LOG="$T/claude-args.log"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
[ -n "${CLAUDE_ARGS_LOG:-}" ] && printf '%s\0' "$@" >> "$CLAUDE_ARGS_LOG"
printf '{"type":"result","subtype":"success","result":"REVIEW: PASS"}\n'
exit 0
STUB
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

GREPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$GREPO" 2>/dev/null
git -C "$GREPO" checkout -q -b main
: > "$GREPO/seed.txt"
git -C "$GREPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$GREPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$GREPO" push -q -u origin main 2>/dev/null

export HOME="$T"
export WORKSPACE_NAME="herdkit"
export HERD_SKIP_PREFLIGHT=1
TREES="$T/trees"; mkdir -p "$TREES"
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
# NOTE: config deliberately OMITS RUBRIC_FILE so each case sets it via the environment.
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

run_local(){  # <slug> [ENV=val ...] ; sets PROMPT
  : > "$CLAUDE_ARGS_LOG"
  local slug="$1"; shift
  HERD_NO_PANE=1 CLAUDE_ARGS_LOG="$CLAUDE_ARGS_LOG" WORKTREES_DIR="$TREES" \
    HERD_CONFIG_FILE="$CFG" env "$@" bash "$REVIEW" --local "$slug" >/dev/null 2>&1 \
    || fail "$slug: herd-review.sh --local exited non-zero"
  PROMPT="$(python3 - "$CLAUDE_ARGS_LOG" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
for part in data.split(b"\0"):
    if b"ADVERSARIAL PRE-PR CORRECTNESS REVIEWER" in part:
        sys.stdout.buffer.write(part)
        break
PY
)"
  [ -n "$PROMPT" ] || fail "$slug: no reviewer prompt captured in claude argv"
}

################################################################################
# ABSENT direction — no rubric block, byte-identical to before RUBRIC_FILE existed
################################################################################

# ── 1 — RUBRIC_FILE unset → no rubric block, and the plain checklist/RULES text is untouched ───────
run_local slug-unset
printf '%s' "$PROMPT" | grep -qF "REVIEW RUBRIC" \
  && fail "1: unset RUBRIC_FILE must NOT inject a rubric block"
printf '%s' "$PROMPT" | grep -qF "RUBRIC:" \
  && fail "1: unset RUBRIC_FILE must NOT mention the RUBRIC: verdict-line format"
printf '%s' "$PROMPT" | grep -qF "do not add markdown, quotes, or extra text around it. THIS REVIEW:" \
  || fail "1: unset RUBRIC_FILE should leave the RULES→THIS REVIEW transition byte-identical (no stray space/text)"
ok

# ── 2 — RUBRIC_FILE set but the named file is missing → same no-op (fail-soft) ──────────────────────
run_local slug-missing-file RUBRIC_FILE=".herd/does-not-exist.tsv"
printf '%s' "$PROMPT" | grep -qF "REVIEW RUBRIC" \
  && fail "2: RUBRIC_FILE naming a missing file should still be a no-op"
ok

# ── 3 — RUBRIC_FILE set but the file has zero well-formed rows (header only) → no-op ────────────────
mkdir -p "$GREPO/.herd"
printf 'id\ttext\tweight\tpass_condition\n' > "$GREPO/.herd/empty-rubric.tsv"
run_local slug-empty-rubric RUBRIC_FILE=".herd/empty-rubric.tsv"
printf '%s' "$PROMPT" | grep -qF "REVIEW RUBRIC" \
  && fail "3: a header-only rubric file (zero criteria) should still be a no-op"
ok

################################################################################
# PRESENT direction — the committed rubric file injects a criteria checklist
################################################################################

# ── 4 — RUBRIC_FILE committed in the MAIN checkout ───────────────────────────────────────────────────
printf 'id\ttext\tweight\tpass_condition\n' > "$GREPO/.herd/rubric.tsv"
printf 'scoped\tChange touches only its own worktree\trequired\tNo path outside the worktree changed\n' >> "$GREPO/.herd/rubric.tsv"
printf 'docs\tUser-facing behavior is documented\tadvisory\tA nearby doc/comment explains it\n' >> "$GREPO/.herd/rubric.tsv"
run_local slug-main-rubric RUBRIC_FILE=".herd/rubric.tsv"
printf '%s' "$PROMPT" | grep -qF "REVIEW RUBRIC" \
  || fail "4: a present rubric file should inject the rubric block"
printf '%s' "$PROMPT" | grep -qF "[scoped] (required) Change touches only its own worktree" \
  || fail "4: the required criterion's id/weight/text should render verbatim"
printf '%s' "$PROMPT" | grep -qF "[docs] (advisory) User-facing behavior is documented" \
  || fail "4: the advisory criterion's id/weight/text should render verbatim"
printf '%s' "$PROMPT" | grep -qF "RUBRIC: <id> | PASS|FAIL | <one-line reason>" \
  || fail "4: the reviewer should be told the exact RUBRIC: verdict-line format"
printf '%s' "$PROMPT" | grep -qF "your final REVIEW: line is still the ONLY thing the merge gate reads" \
  || fail "4: the prompt must state the rubric is advisory-only — REVIEW: still alone decides the merge"
ok

# ── 5 — Fixture WORKTREE: the rubric file lives only in the feature worktree, not MAIN ─────────────
WT="$TREES/wt-rubric"
git -C "$GREPO" worktree add -q -b wt-rubric "$WT" main
mkdir -p "$WT/.herd"
printf 'id\ttext\tweight\tpass_condition\n' > "$WT/.herd/wt-only-rubric.tsv"
printf 'wt-only\tWorktree-local criterion\trequired\tSome condition\n' >> "$WT/.herd/wt-only-rubric.tsv"
run_local wt-rubric RUBRIC_FILE=".herd/wt-only-rubric.tsv"
printf '%s' "$PROMPT" | grep -qF "[wt-only] (required) Worktree-local criterion" \
  || fail "5: a rubric file committed only in the worktree should be picked up"
ok
git -C "$GREPO" worktree remove -f "$WT" >/dev/null 2>&1 || true

# ── 6 — RUBRIC_FILE composes with REVIEW_CHECKLIST (both present at once, independently injected) ──
printf 'CUSTOM_MARKER: verify every currency amount is stored in integer cents\n' > "$GREPO/.herd/review-checklist.md"
run_local slug-both-checklist-and-rubric RUBRIC_FILE=".herd/rubric.tsv" REVIEW_CHECKLIST=".herd/review-checklist.md"
printf '%s' "$PROMPT" | grep -qF "CUSTOM_MARKER" \
  || fail "6: REVIEW_CHECKLIST injection should be unaffected by RUBRIC_FILE"
printf '%s' "$PROMPT" | grep -qF "REVIEW RUBRIC" \
  || fail "6: RUBRIC_FILE injection should be unaffected by REVIEW_CHECKLIST"
ok

echo "ALL PASS ($pass checks)"
