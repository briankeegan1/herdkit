#!/usr/bin/env bash
# test-review-checklist-injection.sh — hermetic proof for REVIEW_CHECKLIST (HERD-379).
#
# WHY: herd-review.sh composes CHECKLIST_TEXT (~line 265) that gets embedded into the reviewer
# prompt — a project-specific risk list read from $REVIEW_CHECKLIST when the key is set AND the
# named file exists (checked under the feature worktree first, then the main checkout), else a
# generic correctness checklist. Nothing asserted that wiring; this is that test.
#
# Scaffold mirrors tests/test-local-review-prepr.sh PART B: stub herdr + a recording claude stub,
# a throwaway git repo, and herd-review.sh --local <slug> (no PR/gh machinery needed — local mode
# exits before any of that). Runs BOTH directions:
#   • ABSENT  (key unset, or key set but the file is missing) → the generic fallback checklist text.
#   • PRESENT (a real checklist file, in a fixture worktree AND in the main checkout) → the file's
#     own text is injected and the generic fallback text is gone (replaced, not appended).
#
# Run:  bash tests/test-review-checklist-injection.sh
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

# ── Shared scaffold — stubbed herdr/claude + throwaway repo (mirrors test-local-review-prepr.sh) ───
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

# Recording claude stub: logs argv (NUL-separated, so the multi-line prompt survives intact) and
# always PASSes so the gate exits 0 without us caring about the verdict.
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

export HOME="$T"                # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit" # matches the herdr stub's workspace label
export HERD_SKIP_PREFLIGHT=1    # no real herdr contract to probe
TREES="$T/trees"; mkdir -p "$TREES"
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
# NOTE: config deliberately OMITS REVIEW_CHECKLIST so each case sets it via the environment
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

GENERIC='wrong values/math (sign errors, off-by-one, rounding, unit/type mix-ups)'
run_local(){  # <slug> [ENV=val ...] ; sets PROMPT
  : > "$CLAUDE_ARGS_LOG"
  local slug="$1"; shift
  HERD_NO_PANE=1 CLAUDE_ARGS_LOG="$CLAUDE_ARGS_LOG" WORKTREES_DIR="$TREES" \
    HERD_CONFIG_FILE="$CFG" env "$@" bash "$REVIEW" --local "$slug" >/dev/null 2>&1 \
    || fail "$slug: herd-review.sh --local exited non-zero"
  # The claude stub logs NUL-separated argv; a present checklist file embeds a real newline in the
  # prompt arg ("the project's risk checklist:\n<file contents>"), so a naive `tr '\0' '\n' | grep`
  # would truncate the argument at that newline. Split on NUL in python3 instead, to keep the whole
  # multi-line prompt argument intact for the substring checks below.
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
# ABSENT direction — generic fallback checklist
################################################################################

# ── 1 — REVIEW_CHECKLIST unset → the generic fallback checklist, no project-checklist framing ──────
run_local slug-unset
printf '%s' "$PROMPT" | grep -qF "$GENERIC" \
  || fail "1: unset REVIEW_CHECKLIST should inject the generic fallback checklist text"
printf '%s' "$PROMPT" | grep -qF "the project's risk checklist:" \
  && fail "1: unset REVIEW_CHECKLIST must NOT claim a project checklist"
ok

# ── 2 — REVIEW_CHECKLIST set but the named file is missing → same generic fallback (fail-soft) ─────
run_local slug-missing-file REVIEW_CHECKLIST=".herd/does-not-exist.md"
printf '%s' "$PROMPT" | grep -qF "$GENERIC" \
  || fail "2: REVIEW_CHECKLIST naming a missing file should still fall back to the generic checklist"
printf '%s' "$PROMPT" | grep -qF "the project's risk checklist:" \
  && fail "2: a missing checklist file must NOT claim a project checklist"
ok

################################################################################
# PRESENT direction — the committed checklist file replaces the generic fallback
################################################################################

# ── 3 — REVIEW_CHECKLIST file committed in the MAIN checkout ────────────────────────────────────────
mkdir -p "$GREPO/.herd"
printf 'CUSTOM_MAIN_MARKER: verify every currency amount is stored in integer cents\n' > "$GREPO/.herd/review-checklist.md"
run_local slug-main-checklist REVIEW_CHECKLIST=".herd/review-checklist.md"
printf '%s' "$PROMPT" | grep -qF "the project's risk checklist:" \
  || fail "3: a present checklist file should switch to the project-checklist framing"
printf '%s' "$PROMPT" | grep -qF "CUSTOM_MAIN_MARKER" \
  || fail "3: the checklist file's own text should be injected verbatim"
printf '%s' "$PROMPT" | grep -qF "$GENERIC" \
  && fail "3: the checklist file should REPLACE the generic fallback, not sit alongside it"
ok

# ── 4 — Fixture WORKTREE: the checklist file lives only in the feature worktree, not MAIN ──────────
# Deliberately a DIFFERENT filename than case 3's — herd-review.sh checks CWD first but MAIN wins
# when BOTH have the same repo-relative path, so reusing case 3's filename would silently re-test
# case 3 instead of proving the worktree-only lookup.
WT="$TREES/wt-checklist"
git -C "$GREPO" worktree add -q -b wt-checklist "$WT" main
mkdir -p "$WT/.herd"
printf 'CUSTOM_WORKTREE_MARKER: verify pagination cursors never skip or repeat a row\n' > "$WT/.herd/wt-only-checklist.md"
run_local wt-checklist REVIEW_CHECKLIST=".herd/wt-only-checklist.md"
printf '%s' "$PROMPT" | grep -qF "the project's risk checklist:" \
  || fail "4: a checklist file committed only in the worktree should switch to project-checklist framing"
printf '%s' "$PROMPT" | grep -qF "CUSTOM_WORKTREE_MARKER" \
  || fail "4: the worktree-local checklist file's text should be injected verbatim"
printf '%s' "$PROMPT" | grep -qF "$GENERIC" \
  && fail "4: the worktree checklist file should REPLACE the generic fallback, not sit alongside it"
ok
git -C "$GREPO" worktree remove -f "$WT" >/dev/null 2>&1 || true

echo "ALL PASS ($pass checks)"
