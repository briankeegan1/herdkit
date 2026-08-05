#!/usr/bin/env bats
# test-resolver-conclude-wedge.bats — HERD-553 proof: herd-resolve.sh's predecessor-wedge precheck.
#
# Live bug: PR #679 looped merge_refused ×44 across three auto-dispatched resolvers. Each inherited a
# worktree already carrying MERGE_HEAD from a predecessor resolver that died AFTER staging its
# conflict resolution but BEFORE committing (killed mid-run) — every subsequent `git merge` in the
# fresh agent's own task contract just re-hit "fatal: You have not concluded your merge", forever.
# herd-resolve.sh now screens the worktree for that exact state BEFORE spawning anything:
#   • MERGE_HEAD + zero unmerged paths + zero conflict markers in what got staged → CONCLUDE
#     (commit --no-edit, run the smoke/health checks, push) instead of asking a fresh agent to
#     re-resolve conflicts that no longer exist.
#   • MERGE_HEAD + unmerged paths remaining → the merge itself is unsalvageable; `git merge --abort`
#     to a clean tree, then dispatch a fresh resolve exactly as before.
#   • no MERGE_HEAD → byte-identical to before this precheck existed.
#
# HERMETIC: real git repos + real merges (the precheck is git-plumbing-shaped, not agent-shaped), but
# herdr/claude/gh are stubbed (NETWORK-FREE, no real tabs, no real LLM) — same convention as
# tests/test-resolve-smoke-gate.sh. healthcheck.sh runs FOR REAL against the fixture worktree (its
# light profile is a pure syntax/lint gate; every engine-specific lint fail-soft-skips a tree with no
# scripts/herd/templates surface, so a plain non-herdkit fixture repo passes it cleanly — see that
# script's own "Fail-soft by construction" comments).
#
# Deliberately a standalone tests/*.bats file (not tests/test-*.sh): the heavy gate's bats runner
# globs tests/*.bats directly (.herd/healthcheck.project.sh), so this is auto-gated without needing
# tests/herd.bats wiring — the same convention tests/test-resolve-autofix.bats documents.

setup() {
  HERE="$(cd "$BATS_TEST_DIRNAME" && pwd)"
  RESOLVE="$HERE/../scripts/herd/herd-resolve.sh"
  [ -f "$RESOLVE" ]

  T="$(mktemp -d)"
  BIN="$T/bin"; mkdir -p "$BIN"
  cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "workspace focus"|"workspace create") printf '{"result":{"workspace":{"workspace_id":"wTest"},"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "tab list")   printf '{"result":{"tabs":[]}}\n' ;;
  "tab create") printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start") printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  "pane split") printf '{"result":{"pane":{"pane_id":"pTest"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
  chmod +x "$BIN/herdr"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/gh"; chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"

  export WORKSPACE_NAME="herdkit"
  export HERD_SKIP_PREFLIGHT=1
  export HERD_NO_APP=1

  # A real bare "origin" so a CONCLUDE-and-push run has something real to push to.
  ORIGIN="$T/origin.git"
  git init --bare -q "$ORIGIN"

  SEED="$T/seed"
  git init -q "$SEED"
  git -C "$SEED" config user.email "test@herdkit.local"
  git -C "$SEED" config user.name "herdkit test"
  git -C "$SEED" checkout -q -b main
  printf 'base\n' > "$SEED/shared.txt"
  git -C "$SEED" add shared.txt
  git -C "$SEED" commit -q -m "base"
  git -C "$SEED" remote add origin "$ORIGIN"
  git -C "$SEED" push -q origin main

  # The feature branch (the existing PR's head) diverges from shared.txt.
  git -C "$SEED" checkout -q -b feat/x
  printf 'feature-line\n' > "$SEED/shared.txt"
  git -C "$SEED" commit -q -am "feature change"
  git -C "$SEED" push -q -u origin feat/x

  # main moves on, touching the SAME line — this is what makes feat/x conflict.
  git -C "$SEED" checkout -q main
  printf 'main-line\n' > "$SEED/shared.txt"
  git -C "$SEED" commit -q -am "main change"
  git -C "$SEED" push -q origin main

  PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT"
  WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
  SLUG="feat-conclude-wedge"
  DIR="$WORKTREES_DIR/$SLUG"
  git clone -q "$ORIGIN" "$DIR"
  git -C "$DIR" checkout -q feat/x
  git -C "$DIR" config user.email "test@herdkit.local"
  git -C "$DIR" config user.name "herdkit test"

  CFG="$T/config"
  cat > "$CFG" <<EOF
PROJECT_ROOT="$PROJECT_ROOT"
WORKTREES_DIR="$WORKTREES_DIR"
WORKSPACE_NAME="herdkit"
MODEL_RESOLVER="resolver-model"
APP_PREVIEW_CMD=""
SMOKE_CMD=""
DEFAULT_BRANCH="origin/main"
EOF
  export HERD_CONFIG_FILE="$CFG"
  export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
  export HERDR_CALL_LOG="$T/herdr.log"; : > "$HERDR_CALL_LOG"
}

teardown() {
  rm -rf "$T"
}

@test "staged-complete fixture: MERGE_HEAD + fully staged resolution is concluded, checks run, pushed, journaled — no agent spawned" {
  git -C "$DIR" fetch -q origin
  run git -C "$DIR" merge origin/main
  [ "$status" -ne 0 ]   # a real conflict — confirms the fixture actually wedges
  [ -f "$DIR/.git/MERGE_HEAD" ]

  # The predecessor resolved it (a combined line) and staged it, but never committed.
  printf 'merged-line\n' > "$DIR/shared.txt"
  git -C "$DIR" add shared.txt

  run bash "$RESOLVE" "$SLUG"
  [ "$status" -eq 0 ]

  # Concluded: MERGE_HEAD is gone, and the merge commit landed with two parents (HEAD + 2 parent shas).
  [ ! -f "$DIR/.git/MERGE_HEAD" ]
  [ "$(git -C "$DIR" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" = "3" ]
  [ "$(cat "$DIR/shared.txt")" = "merged-line" ]

  # Pushed: origin/feat/x now points at our new HEAD.
  git -C "$DIR" fetch -q origin
  [ "$(git -C "$DIR" rev-parse HEAD)" = "$(git -C "$DIR" rev-parse origin/feat/x)" ]

  # Journaled.
  grep -q '"event":"resolver_concluded_predecessor"' "$JOURNAL_FILE"
  grep -q "\"slug\":\"$SLUG\"" "$JOURNAL_FILE"
  grep -q '"status":"pushed"' "$JOURNAL_FILE"

  # No agent was spawned — the wedge was fully resolved without one.
  ! grep -q 'agent start' "$HERDR_CALL_LOG"
}

@test "unmerged fixture: MERGE_HEAD with real conflicts is aborted clean, then a fresh resolve is dispatched" {
  git -C "$DIR" fetch -q origin
  run git -C "$DIR" merge origin/main
  [ "$status" -ne 0 ]
  [ -f "$DIR/.git/MERGE_HEAD" ]
  # Leave it exactly as a killed predecessor would: unresolved, unstaged, markers in place.
  grep -q '<<<<<<<' "$DIR/shared.txt"
  [ -n "$(git -C "$DIR" diff --name-only --diff-filter=U)" ]

  run bash "$RESOLVE" "$SLUG"
  [ "$status" -eq 0 ]

  # Aborted clean: no MERGE_HEAD, no markers, worktree matches the feature branch tip again.
  [ ! -f "$DIR/.git/MERGE_HEAD" ]
  ! grep -q '<<<<<<<' "$DIR/shared.txt"
  [ -z "$(git -C "$DIR" status --porcelain)" ]

  grep -q '"event":"resolver_wedge_aborted"' "$JOURNAL_FILE"
  grep -q "\"slug\":\"$SLUG\"" "$JOURNAL_FILE"
  grep -q '"reason":"unmerged_paths"' "$JOURNAL_FILE"

  # A fresh resolve WAS dispatched (the normal agent-spawn path ran).
  grep -q 'agent start' "$HERDR_CALL_LOG"
}

@test "clean tree (no MERGE_HEAD): precheck is a no-op — byte-identical dispatch, nothing journaled" {
  [ ! -f "$DIR/.git/MERGE_HEAD" ]

  run bash "$RESOLVE" "$SLUG"
  [ "$status" -eq 0 ]

  [ ! -f "$DIR/.git/MERGE_HEAD" ]
  ! grep -q '"event":"resolver_concluded_predecessor"' "$JOURNAL_FILE"
  ! grep -q '"event":"resolver_wedge_aborted"' "$JOURNAL_FILE"
  grep -q 'agent start' "$HERDR_CALL_LOG"
}
