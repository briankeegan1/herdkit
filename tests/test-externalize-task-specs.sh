#!/usr/bin/env bash
# test-externalize-task-specs.sh — hermetic proof of the "externalize task specs" efficiency lever.
#
# Both lanes (herd-quick.sh, herd-feature.sh) now write the FULL task spec (caller task + the
# standing workflow-rules footer) to a FILE at $WORKTREES_DIR/<slug>.task.md — a SIBLING of the
# worktree dir, outside its tracked tree — and seed the agent with a SHORT pointer prompt that
# references that file, instead of inlining the multi-KB task as a `claude "<task>"` argv.
#
# Asserts, for BOTH lanes:
#   (a) the task file $WORKTREES_DIR/<slug>.task.md exists and contains BOTH the caller task
#       (a unique sentinel) AND the workflow-rules footer (healthcheck line) — full spec preserved.
#   (b) the `herdr agent start … -- claude …` invocation carries a SHORT pointer prompt that
#       references the .task.md path and does NOT inline the multi-KB task sentinel.
#   (c) the task file is a SIBLING of the worktree, never inside the worktree's tracked tree.
#
# Fully hermetic: a throwaway git repo (so new-feature.sh's worktree add works) + stubbed herdr/claude
# (NETWORK-FREE, no real tabs, no real agent). Mirrors tests/test-model-escalate.sh.
# Run:  bash tests/test-externalize-task-specs.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QUICK="$HERE/../scripts/herd/herd-quick.sh"
FEATURE="$HERE/../scripts/herd/herd-feature.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git    >/dev/null 2>&1 || fail "git required to run this test"

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
MODEL_QUICK="stub-quick-model"
MODEL_FEATURE="stub-feature-model"
EOF

# A caller task with a UNIQUE, multi-KB sentinel body — the whole point is that this bulk no longer
# rides in argv. The sentinel must appear in the spec file but NOT in the agent-start invocation.
SENTINEL="SENTINEL-UNIQUE-TASK-BODY-9f3ac71d"
BULK="$(python3 -c 'print("payload-"*400)')"   # ~3.6 KB of filler to make the argv-bloat case real
TASK="$SENTINEL Build the thing precisely. $BULK"

# assert_lane <script> <slug> [extra herdr flags check]
assert_lane() {
  local script="$1" slug="$2"
  export HERDR_CALL_LOG="$T/$slug.herdr.log"; : > "$HERDR_CALL_LOG"
  local out="$T/$slug.out"
  HERD_NO_APP=1 bash "$script" "$slug" "$TASK" > "$out" 2>&1 \
    || fail "$(basename "$script") exited non-zero for '$slug'"$'\n'"$(cat "$out")"

  local taskfile="$TREES/$slug.task.md"

  # (a) task file exists with the full spec: caller sentinel + workflow-rules footer.
  [ -f "$taskfile" ] || fail "$(basename "$script"): task file not written at $taskfile"
  grep -q "$SENTINEL"        "$taskfile" || fail "$(basename "$script"): task file missing the caller task sentinel"
  grep -q "payload-payload"  "$taskfile" || fail "$(basename "$script"): task file missing the multi-KB task body"
  grep -q "\[workflow rules\]" "$taskfile" || fail "$(basename "$script"): task file missing the workflow-rules footer"
  grep -q "healthcheck.sh"   "$taskfile" || fail "$(basename "$script"): task file missing the healthcheck rule"

  # (c) the file is a SIBLING of the worktree, never inside the worktree's tracked tree.
  [ -f "$TREES/$slug/$slug.task.md" ] && fail "$(basename "$script"): task file leaked INSIDE the worktree"
  # And not tracked/stageable from within the worktree (it lives outside the working dir entirely).
  case "$taskfile" in "$TREES/$slug/"*) fail "$(basename "$script"): task file path is inside the worktree dir" ;; esac

  # (b) the agent-start invocation carries a SHORT pointer, references the file, and does NOT inline
  #     the multi-KB task. The herdr stub logs each call's "$*"; find the agent-start line.
  local startline
  startline="$(grep -E '^agent start ' "$HERDR_CALL_LOG" | head -1)"
  [ -n "$startline" ] || fail "$(basename "$script"): no 'agent start' call logged"$'\n'"$(cat "$HERDR_CALL_LOG")"
  grep -q -- "-- claude --model" <<<"$startline" || fail "$(basename "$script"): agent-start did not launch claude --model"$'\n'"$startline"
  grep -q "$slug.task.md" <<<"$startline" || fail "$(basename "$script"): pointer prompt does not reference the task file"$'\n'"$startline"
  grep -q "$SENTINEL"     <<<"$startline" && fail "$(basename "$script"): the multi-KB task sentinel is STILL inlined in argv"$'\n'"$startline"
  grep -q "payload-payload" <<<"$startline" && fail "$(basename "$script"): the multi-KB task body is STILL inlined in argv"$'\n'"$startline"

  echo "  ok: $(basename "$script")"
}

echo "externalize-task-specs:"
assert_lane "$QUICK"   "ext-quick"
assert_lane "$FEATURE" "ext-feature"

echo "ALL PASS"
