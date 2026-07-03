#!/usr/bin/env bash
# test-spawn-rate-match.sh — hermetic proof of the advisory spawn-rate gate (SPAWN_AHEAD).
#
# Both lanes (herd-quick.sh, herd-feature.sh) source herd-spawn-gate.sh and, BEFORE creating any
# worktree/tab, HOLD a new builder spawn when the review pipeline is saturated:
#     live_reviews + queued_reviews >= REVIEW_CONCURRENCY  AND
#     in-flight builders            >  REVIEW_CONCURRENCY + SPAWN_AHEAD
# Review state is derived WITHOUT touching agent-watch.sh — from the sha-keyed review ledger
# (.agent-watch-reviewed), the in-flight review markers (.review-inflight-<pr>-<sha>), and
# `gh pr list`. Builder count = git worktrees under $WORKTREES_DIR.
#
# Asserts (for the quick lane, with a feature-lane cross-check):
#   0. empty pipeline                       → spawn PROCEEDS (regression: gate never blocks normally)
#   A. saturated gate (2 live reviews, 4 builders) → spawn DEFERRED + "review-gate saturated" message,
#      and NO worktree / NO `herdr agent start` for the held slug.
#   B. gate clears (reviews complete → 0 in pipeline) → deferred spawn PROCEEDS.
#   C. force-spawn (--force flag AND HERD_FORCE_SPAWN=1 env) → bypasses the gate despite saturation.
#   D. SPAWN_AHEAD=0 strict: 3 builders + saturated reviews → DEFERRED (cap=2); and the one-ahead lead
#      regression — SPAWN_AHEAD=1 with 3 builders + saturated reviews → PROCEEDS (3 is not > 3).
#
# Fully hermetic + NETWORK-FREE: a throwaway git repo (so worktrees add) + stubbed herdr/claude/gh.
# We assert on the presence/absence of the `herdr agent start … claude` invocation and the held
# slug's worktree — never launching a real builder or reviewer.
# Run:  bash tests/test-spawn-rate-match.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QUICK="$HERE/../scripts/herd/herd-quick.sh"
FEATURE="$HERE/../scripts/herd/herd-feature.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git    >/dev/null 2>&1 || fail "git required to run this test"

# ── Stubs (herdr + claude mirror tests/test-model-escalate.sh; gh serves a per-scenario PR list) ──
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
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
# gh stub: `gh pr list …` echoes the JSON file named by $GH_PRS_JSON (default: empty list).
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  cat "${GH_PRS_JSON:-/dev/null}" 2>/dev/null || printf '[]'
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# ── Throwaway git repo so worktree add … origin/main succeeds ────────────────────────────────────
REPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
: > "$REPO/seed.txt"
git -C "$REPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null

# ── Hermetic env ──────────────────────────────────────────────────────────────────────────────
export HOME="$T"                  # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit"   # matches the herdr stub's workspace label
export HERD_SKIP_PREFLIGHT=1      # no real herdr contract to probe
export HERD_NO_APP=1              # feature lane: no app-preview pane
TREES="$T/trees"; mkdir -p "$TREES"
TREES_P="$(cd "$TREES" && pwd -P)"   # physical path — `git worktree list` reports /private/var on macOS
export GH_PRS_JSON="$T/prs.json"; printf '[]' > "$GH_PRS_JSON"
CFG="$T/config"; export HERD_CONFIG_FILE="$CFG"

# A pid far above any real one (macOS/Linux pid_max) so a "not-live" review marker is deterministic
# (`kill -0 $DEAD` always fails). A constant avoids a `sleep & ; kill` background subshell, which on
# macOS bash 3.2 inherits this script's EXIT trap and would `rm -rf "$T"` mid-run when reaped.
DEAD=2147480000

# mkconfig <spawn_ahead> — project config with REVIEW_CONCURRENCY=2 and the given SPAWN_AHEAD.
mkconfig() {
  cat > "$CFG" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit"
APP_PREVIEW_CMD=""
REVIEW_CONCURRENCY="2"
SPAWN_AHEAD="${1:-1}"
EOF
}

# set_builders <n> — reset worktree state to EXACTLY n builder worktrees under $TREES (b1..bn).
# Removes every worktree under $TREES (including any spawned by a prior proceed-scenario) and every
# feat/* branch, so builder count is deterministic per scenario.
set_builders() {
  local want="$1" i d b
  git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | while read -r d; do
    case "$d/" in "$TREES_P"/*|"$TREES"/*) git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d" ;; esac
  done
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null | grep -E '^feat/' | while read -r b; do
    git -C "$REPO" branch -D "$b" >/dev/null 2>&1 || true
  done
  for i in $(seq 1 "$want"); do git -C "$REPO" worktree add "$TREES/b$i" -b "feat/b$i" origin/main >/dev/null 2>&1; done
}

# reset_reviews — clear all review state (ledger + inflight markers + gh PR list).
reset_reviews() { rm -f "$TREES"/.review-inflight-* "$TREES/.agent-watch-reviewed" 2>/dev/null || true; printf '[]' > "$GH_PRS_JSON"; }
mk_marker()  { printf '%s\n' "$2" > "$TREES/.review-inflight-$1-sha$1"; }   # <pr> <pid>
ledger_pass(){ printf '%s %s sha%s PASS reviewer\n' "1700000000" "$1" "$1" >> "$TREES/.agent-watch-reviewed"; }
gh_prs()     { python3 - "$@" > "$GH_PRS_JSON" <<'PY'
import sys, json
print(json.dumps([{"number": int(n), "headRefOid": "sha"+n} for n in sys.argv[1:]]))
PY
}

# run_lane <script> <slug> [--force] — run a lane hermetically; capture output + the herdr call log.
# Returns the lane's own exit code (both defer and proceed exit 0; a real error is non-zero).
run_lane() {
  local script="$1" slug="$2"; shift 2
  export HERDR_CALL_LOG="$T/$slug.herdr.log"; : > "$HERDR_CALL_LOG"
  OUT="$T/$slug.out"
  bash "$script" "$@" "$slug" "do a thing" > "$OUT" 2>&1
  return $?
}
started()  { grep -q "agent start" "$T/$1.herdr.log"; }               # `herdr agent start` was called
deferred() { grep -q "review-gate saturated" "$T/$1.out"; }           # the hold message was printed

# ═══ 0. empty pipeline → spawn PROCEEDS (regression: the gate never blocks normal operation) ═══
mkconfig 1; reset_reviews; set_builders 0
run_lane "$QUICK" s0 || fail "empty pipeline: lane exited non-zero"$'\n'"$(cat "$T/s0.out")"
started s0  || fail "empty pipeline: spawn was not started"$'\n'"$(cat "$T/s0.out")"
deferred s0 && fail "empty pipeline: spawn was wrongly deferred"$'\n'"$(cat "$T/s0.out")"

# ═══ A. saturated gate → spawn DEFERRED + message; no worktree / no agent start for the held slug ══
# 2 LIVE reviews (markers with this test's own live pid) + 4 builders. live=2 ≥ REVIEW_CONCURRENCY=2,
# builders 4 > 2+1. Both axes hold → defer.
mkconfig 1; reset_reviews; set_builders 4
gh_prs 101 102; mk_marker 101 "$$"; mk_marker 102 "$$"
run_lane "$QUICK" spawn-a || fail "saturated: lane exited non-zero"$'\n'"$(cat "$T/spawn-a.out")"
deferred spawn-a || fail "saturated: spawn was NOT deferred"$'\n'"$(cat "$T/spawn-a.out")"
started  spawn-a && fail "saturated: a builder was started despite a saturated gate"$'\n'"$(cat "$T/spawn-a.out")"
[ -e "$TREES/spawn-a" ]         && fail "saturated: a worktree was created for the held slug"
[ -e "$TREES/spawn-a.task.md" ] && fail "saturated: a task spec was written for the held slug"
grep -q "REVIEW_CONCURRENCY=2" "$T/spawn-a.out" || fail "saturated: message missing the review counts"$'\n'"$(cat "$T/spawn-a.out")"

# Feature lane behaves identically on the same saturated state.
run_lane "$FEATURE" spawn-a-feat || fail "saturated (feature): lane exited non-zero"$'\n'"$(cat "$T/spawn-a-feat.out")"
deferred spawn-a-feat || fail "saturated (feature): spawn was NOT deferred"$'\n'"$(cat "$T/spawn-a-feat.out")"
started  spawn-a-feat && fail "saturated (feature): a builder was started despite a saturated gate"

# ═══ B. gate clears (reviews COMPLETE → 0 in pipeline) → deferred spawn PROCEEDS ═══
# Same 2 PRs still open, but now their reviews finished: dead markers + PASS ledger rows → live=0,
# queued=0. Builders still 4, but the review axis no longer holds → proceed.
mkconfig 1; reset_reviews; set_builders 4
gh_prs 101 102; mk_marker 101 "$DEAD"; mk_marker 102 "$DEAD"; ledger_pass 101; ledger_pass 102
run_lane "$QUICK" spawn-b || fail "cleared gate: lane exited non-zero"$'\n'"$(cat "$T/spawn-b.out")"
started  spawn-b || fail "cleared gate: deferred spawn did not proceed once reviews completed"$'\n'"$(cat "$T/spawn-b.out")"
deferred spawn-b && fail "cleared gate: spawn was still deferred after the gate cleared"$'\n'"$(cat "$T/spawn-b.out")"

# ═══ C. force-spawn bypasses the gate despite saturation ═══
# --force flag:
mkconfig 1; reset_reviews; set_builders 4; gh_prs 101 102; mk_marker 101 "$$"; mk_marker 102 "$$"
run_lane "$QUICK" spawn-c --force || fail "force flag: lane exited non-zero"$'\n'"$(cat "$T/spawn-c.out")"
started spawn-c || fail "force flag: --force did not bypass a saturated gate"$'\n'"$(cat "$T/spawn-c.out")"
grep -q "force set" "$T/spawn-c.out" || fail "force flag: bypass notice not printed"$'\n'"$(cat "$T/spawn-c.out")"
# HERD_FORCE_SPAWN=1 env (same saturated state):
mkconfig 1; reset_reviews; set_builders 4; gh_prs 101 102; mk_marker 101 "$$"; mk_marker 102 "$$"
( export HERD_FORCE_SPAWN=1; run_lane "$QUICK" spawn-c-env || fail "force env: lane exited non-zero"$'\n'"$(cat "$T/spawn-c-env.out")"
  started spawn-c-env || fail "force env: HERD_FORCE_SPAWN=1 did not bypass a saturated gate"$'\n'"$(cat "$T/spawn-c-env.out")" ) || exit 1

# ═══ D. SPAWN_AHEAD tuning ═══
# D1 strict (SPAWN_AHEAD=0): cap = 2. 3 builders + 2 queued reviews → 3 > 2 AND 2 ≥ 2 → DEFER.
mkconfig 0; reset_reviews; set_builders 3; gh_prs 201 202     # 2 open PRs, no verdicts, no markers → queued=2
run_lane "$QUICK" spawn-d0 || fail "strict: lane exited non-zero"$'\n'"$(cat "$T/spawn-d0.out")"
deferred spawn-d0 || fail "strict (SPAWN_AHEAD=0): 3 builders past a saturated gate were NOT deferred"$'\n'"$(cat "$T/spawn-d0.out")"
started  spawn-d0 && fail "strict (SPAWN_AHEAD=0): a builder was started"

# D2 one-ahead lead (SPAWN_AHEAD=1, default): cap = 3. SAME 3 builders + 2 queued reviews →
# 3 is NOT > 3 → PROCEED. Proves the permitted one-build lead keeps the pipeline fed.
mkconfig 1; reset_reviews; set_builders 3; gh_prs 201 202
run_lane "$QUICK" spawn-d1 || fail "lead: lane exited non-zero"$'\n'"$(cat "$T/spawn-d1.out")"
started  spawn-d1 || fail "lead (SPAWN_AHEAD=1): the permitted one-build lead was wrongly deferred"$'\n'"$(cat "$T/spawn-d1.out")"
deferred spawn-d1 && fail "lead (SPAWN_AHEAD=1): 3 builders (== cap) should proceed, not defer"

echo "ALL PASS"
