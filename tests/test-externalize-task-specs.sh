#!/usr/bin/env bash
# test-externalize-task-specs.sh — hermetic proof that both builder lanes EXTERNALIZE the task spec.
#
# The efficiency lever (respawn of #69): instead of passing the entire multi-KB task spec as a
# positional argv to `claude … "$TASK"`, each lane writes the full spec (caller task + workflow-rules
# footer) to $WORKTREES_DIR/<slug>.task.md (a SIBLING of the worktree — outside its tracked tree, so
# the builder never commits it) and hands the agent a SHORT pointer prompt referencing that file.
#
# Asserts, for BOTH lanes (herd-quick.sh, herd-feature.sh):
#   (a) HAPPY PATH — the spec file is written with the FULL content (caller task + rules footer), and
#       the `herdr agent start … -- claude …` argv carries only the SHORT pointer (referencing the
#       spec file) and NO LONGER inlines the multi-KB task body.
#   (b) FAILURE PATH — when the spec-file target is unwritable (here: the target path pre-exists as a
#       DIRECTORY, so the write fails), herd_write_task_spec returns NON-ZERO, the lane aborts under
#       `set -euo pipefail`, and NO builder is spawned (no `agent start … claude`) with a non-zero
#       exit. This is the fail-loud guarantee that #69 lacked — a failed spec write must not be
#       masked by a trailing pointer printf and silently spawn a builder against a missing spec.
#
# Fully hermetic: a throwaway git repo (so new-feature.sh's `git worktree add … origin/main` works) +
# stubbed herdr/claude (NETWORK-FREE, no real tabs, no real agent). Mirrors tests/test-model-escalate.sh.
# Run:  bash tests/test-externalize-task-specs.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QUICK="$HERE/../scripts/herd/herd-quick.sh"
FEATURE="$HERE/../scripts/herd/herd-feature.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git    >/dev/null 2>&1 || fail "git required to run this test"

# ── A distinctive multi-line marker that stands in for the multi-KB task body ──────────────────────
# It must (1) land verbatim in the spec FILE and (2) be ABSENT from the agent-start argv (the whole
# point of externalizing). A newline in it also proves a spec that could never ride safely in argv.
BIG_TASK="SENTINEL_BIG_TASK_BODY_MARKER build the externalized-spec thing"$'\n'"line-two SENTINEL_TASK_LINE_TWO with more body text to bulk it up"

# ── Stubs (mirror tests/test-model-escalate.sh) ────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "tab list")    printf '{"result":{"tabs":[]}}\n' ;;
  "tab create")  printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start") printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  "pane split")  printf '{"result":{"pane":{"pane_id":"pTest"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

# ── Throwaway git repo so new-feature.sh's `git worktree add … origin/main` succeeds ───────────
REPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
: > "$REPO/seed.txt"
git -C "$REPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null

# ── Hermetic env ───────────────────────────────────────────────────────────────
export HOME="$T"                  # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit"   # matches the herdr stub's workspace label
export HERD_SKIP_PREFLIGHT=1      # no real herdr contract to probe
TREES="$T/trees"
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
cat > "$CFG" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit"
APP_PREVIEW_CMD=""
MODEL_QUICK="test-quick-model"
MODEL_FEATURE="test-feature-model"
EOF

# agent_start_line <slug> — the logged `herdr agent start … -- claude …` invocation (empty if none).
agent_start_line() { grep -E 'agent start .*-- claude' "$T/$1.herdr.log" 2>/dev/null | head -1; }

# ── (a) HAPPY PATH — both lanes externalize the spec and pass only a short pointer ──────────────────
happy() {
  local script="$1" slug="$2"
  export HERDR_CALL_LOG="$T/$slug.herdr.log"; : > "$HERDR_CALL_LOG"
  HERD_NO_APP=1 bash "$script" "$slug" "$BIG_TASK" > "$T/$slug.out" 2>&1 \
    || fail "$(basename "$script") exited non-zero on the happy path for '$slug'"$'\n'"$(cat "$T/$slug.out")"

  local spec="$TREES/$slug.task.md"
  # The spec file lands OUTSIDE the worktree tracked tree (a sibling of $TREES/$slug), with FULL content.
  [ -f "$spec" ] || fail "$slug: spec file not written at $spec"
  grep -q "SENTINEL_BIG_TASK_BODY_MARKER"  "$spec" || fail "$slug: spec file missing the caller task body"
  grep -q "SENTINEL_TASK_LINE_TWO"          "$spec" || fail "$slug: spec file missing the caller task's 2nd line"
  grep -q "\[workflow rules\]"              "$spec" || fail "$slug: spec file missing the workflow-rules footer"
  case "$spec" in "$TREES/$slug/"*) fail "$slug: spec file is INSIDE the worktree tracked tree ($spec)";; esac

  local line; line="$(agent_start_line "$slug")"
  [ -n "$line" ] || fail "$slug: no 'herdr agent start … claude' invocation logged"$'\n'"$(cat "$HERDR_CALL_LOG")"
  # The argv carries the SHORT pointer referencing the spec file …
  case "$line" in *"Read your task spec at $spec"*) : ;; *) fail "$slug: agent-start argv lacks the spec-file pointer"$'\n'"$line";; esac
  # … and NO LONGER inlines the multi-KB task body.
  case "$line" in *SENTINEL_BIG_TASK_BODY_MARKER*) fail "$slug: agent-start argv STILL inlines the multi-KB task body"$'\n'"$line";; esac
  case "$line" in *"[workflow rules]"*) fail "$slug: agent-start argv STILL inlines the workflow-rules footer"$'\n'"$line";; esac
}
happy "$QUICK"   "ext-quick-happy"
happy "$FEATURE" "ext-feat-happy"

# ── (b) FAILURE PATH — unwritable spec target aborts the lane WITHOUT spawning a builder ────────────
# Force the spec write to fail by pre-creating the target path AS A DIRECTORY: `printf > <dir>` fails,
# so herd_write_task_spec returns non-zero and the lane aborts before `herdr agent start`. The
# worktree dir ($TREES/<slug>) is a DIFFERENT path, so new-feature.sh still succeeds first.
fail_path() {
  local script="$1" slug="$2"
  export HERDR_CALL_LOG="$T/$slug.herdr.log"; : > "$HERDR_CALL_LOG"
  mkdir -p "$TREES"                       # $TREES must exist for new-feature.sh's worktree add
  mkdir -p "$TREES/$slug.task.md"         # target path pre-exists as a DIR → the spec write must fail
  local rc=0
  HERD_NO_APP=1 bash "$script" "$slug" "$BIG_TASK" > "$T/$slug.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "$slug: lane exited 0 despite an unwritable spec target (fail-loud gap — the #69 bug)"$'\n'"$(cat "$T/$slug.out")"
  local line; line="$(agent_start_line "$slug")"
  [ -z "$line" ] || fail "$slug: a builder was spawned despite the spec write failing"$'\n'"$line"
}
fail_path "$QUICK"   "ext-quick-fail"
fail_path "$FEATURE" "ext-feat-fail"

echo "ALL PASS"
