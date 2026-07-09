#!/usr/bin/env bash
# test-review-pin-dispatch-sha.sh — hermetic tests for HERD-230 (pin review input to dispatch sha).
#
# Incident 8b: the watcher keys the verdict to the DISPATCH sha, but the reviewer prompt used to
# instruct `gh pr diff <PR>` (LIVE head). A builder push mid-review made the reviewer read NEW
# content while the verdict was recorded against the OLD sha.
#
# This suite proves:
#   PART A — _pin_review_sha (agent-watch helper):
#     (1) fetch + rev-parse match  → pinned
#     (2) live head moved past sha → superseded (exit 1)
#     (3) fetch unavailable         → unpinned (fail-soft, exit 0)
#   PART B — _dispatch_review passes HERD_REVIEW_SHA (+ PIN_MODE) to the reviewer bin.
#   PART C — herd-review.sh: a review dispatched at sha X reviews X's content even if the PR head
#            advances to Y mid-review (prompt carries git diff <mb>..X, never live gh pr diff for
#            the content pin). Soft fallback to gh pr diff when pin objects are missing.
#
# Fully hermetic: local bare origin + real git; stubs gh/herdr/claude; no network.
# Run:  bash tests/test-review-pin-dispatch-sha.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"
REVIEW="$REPO/scripts/herd/herd-review.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ]  || fail "agent-watch.sh not found at $WATCH"
[ -f "$REVIEW" ] || fail "herd-review.sh not found at $REVIEW"
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Shared fixtures: bare origin with pull/N/head refs + a MAIN clone ────────────────────────────
ORIGIN="$T/origin.git"
MAIN="$T/main"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$MAIN" 2>/dev/null
git -C "$MAIN" checkout -q -b main
: > "$MAIN/seed.txt"
git -C "$MAIN" -c user.email=t@t -c user.name=t add seed.txt
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$MAIN" push -q -u origin main 2>/dev/null
BASE="$(git -C "$MAIN" rev-parse HEAD)"

# Two sequential feature commits X then Y on a PR branch.
git -C "$MAIN" checkout -q -b feat/pin
printf 'x-content\n' > "$MAIN/feat.txt"
git -C "$MAIN" -c user.email=t@t -c user.name=t add feat.txt
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q -m 'feat at X'
SHA_X="$(git -C "$MAIN" rev-parse HEAD)"
printf 'y-content\n' >> "$MAIN/feat.txt"
git -C "$MAIN" -c user.email=t@t -c user.name=t add feat.txt
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q -m 'feat at Y'
SHA_Y="$(git -C "$MAIN" rev-parse HEAD)"
git -C "$MAIN" push -q -u origin feat/pin 2>/dev/null

# GitHub-style PR head refs on the bare origin (what `git fetch origin pull/N/head:…` reads).
PR=42
git -C "$ORIGIN" update-ref "refs/pull/${PR}/head" "$SHA_X"
# Ensure MAIN is on main (reviewer reads from MAIN; pin objects must resolve here after fetch).
git -C "$MAIN" checkout -q main

# Stub PATH bits used by herd-review / agent-watch (do NOT stub real git — pin uses it).
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[]}}\n' ;;
  "tab list")       printf '{"result":{"tabs":[]}}\n' ;;
  "agent list")     printf '{"result":{"agents":[]}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
# Default gh stub: no-op success (pin path must NOT need gh).
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/gh"; chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

TREES="$T/trees"; mkdir -p "$TREES"
CFG="$T/config"
cat > "$CFG" <<EOF
PROJECT_ROOT="$MAIN"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit-pin-test"
APP_PREVIEW_CMD=""
MODEL_REVIEW="test-review-model"
EOF

################################################################################
# PART A — _pin_review_sha unit tests
################################################################################
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$TREES"
export HERD_CONFIG_FILE="$CFG"
export JOURNAL_FILE="$T/journal.jsonl"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type _pin_review_sha >/dev/null 2>&1 || fail "_pin_review_sha not defined after sourcing"
type _dispatch_review >/dev/null 2>&1 || fail "_dispatch_review not defined after sourcing"
# MAIN is set by agent-watch from PROJECT_ROOT via herd-config.
[ -n "${MAIN:-}" ] || fail "MAIN empty after sourcing agent-watch"
# herd-config may have re-resolved PROJECT_ROOT; force our fixture paths for the pin helper.
MAIN="$T/main"
PROJECT_ROOT="$T/main"
ok

# ── A1 — head matches dispatch sha → pinned ──────────────────────────────────────────────────────
git -C "$ORIGIN" update-ref "refs/pull/${PR}/head" "$SHA_X"
mode="$(_pin_review_sha "$PR" "$SHA_X")" || fail "A1: pin should succeed (exit 0) when head==sha"
[ "$mode" = "pinned" ] || fail "A1: expected pinned, got '$mode'"
# Objects for X must now resolve under MAIN (fetched into the pin ref).
git -C "$MAIN" cat-file -e "${SHA_X}^{commit}" 2>/dev/null \
  || fail "A1: pin fetch should materialise sha X under MAIN"
ok

# ── A2 — head moved past dispatch sha → superseded ───────────────────────────────────────────────
git -C "$ORIGIN" update-ref "refs/pull/${PR}/head" "$SHA_Y"
rc=0
mode="$(_pin_review_sha "$PR" "$SHA_X")" || rc=$?
[ "$rc" -eq 1 ] || fail "A2: superseded pin should exit 1 (got rc=$rc mode=$mode)"
[ "$mode" = "superseded" ] || fail "A2: expected superseded, got '$mode'"
ok

# ── A3 — fetch unavailable → unpinned (fail-soft) ───────────────────────────────────────────────
# Point at a PR ref that does not exist on origin → fetch fails → soft unpinned.
rc=0
mode="$(_pin_review_sha 999999 "$SHA_X")" || rc=$?
[ "$rc" -eq 0 ] || fail "A3: soft pin failure should exit 0 (got rc=$rc)"
[ "$mode" = "unpinned" ] || fail "A3: expected unpinned, got '$mode'"
ok

################################################################################
# PART B — _dispatch_review threads HERD_REVIEW_SHA (+ PIN_MODE) to the reviewer
################################################################################
STUB_REVIEW="$T/stub-review.sh"
STUB_SPAWN_ENV="$T/spawn-env.log"
cat > "$STUB_REVIEW" <<'STUB'
#!/usr/bin/env bash
# Log the pin env the watcher passed, then write a PASS verdict.
{
  printf 'pr=%s sha_env=%s pin_mode=%s\n' "${1:-}" "${HERD_REVIEW_SHA:-}" "${HERD_REVIEW_PIN_MODE:-}"
} >> "${STUB_SPAWN_ENV:-/dev/null}"
if [ -n "${HERD_REVIEW_RESULT_FILE:-}" ]; then
  printf 'REVIEW: PASS\n' > "${HERD_REVIEW_RESULT_FILE}.tmp.$$"
  mv "${HERD_REVIEW_RESULT_FILE}.tmp.$$" "$HERD_REVIEW_RESULT_FILE"
fi
printf 'REVIEW: PASS\n'
STUB
chmod +x "$STUB_REVIEW"
export HERD_REVIEW_BIN="$STUB_REVIEW"
export STUB_SPAWN_ENV
: > "$STUB_SPAWN_ENV"

# Reset PR head to X so pin succeeds.
git -C "$ORIGIN" update-ref "refs/pull/${PR}/head" "$SHA_X"
_dispatch_review "$PR" "slug-pin" "$SHA_X"
# Wait briefly for the detached reviewer to log + write its result.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$STUB_SPAWN_ENV" ] && break
  sleep 0.1
done
grep -q "pr=${PR} sha_env=${SHA_X} pin_mode=pinned" "$STUB_SPAWN_ENV" \
  || fail "B: dispatch must pass HERD_REVIEW_SHA=$SHA_X and PIN_MODE=pinned"$'\n'"$(cat "$STUB_SPAWN_ENV")"
ok

# Superseded head → no spawn (env log must not gain a new line for a different call).
: > "$STUB_SPAWN_ENV"
git -C "$ORIGIN" update-ref "refs/pull/${PR}/head" "$SHA_Y"
# Use a fresh sha key so adopt/result guards do not short-circuit before the pin.
_dispatch_review "$PR" "slug-super" "$SHA_X"
sleep 0.3
[ ! -s "$STUB_SPAWN_ENV" ] || fail "B2: superseded dispatch must NOT spawn a reviewer"$'\n'"$(cat "$STUB_SPAWN_ENV")"
ok

################################################################################
# PART C — herd-review.sh prompt pins to dispatch sha X even if head advances to Y
################################################################################
# Recording claude stub: dump argv (NUL-separated) so we can inspect the task prompt.
CLAUDE_ARGS_LOG="$T/claude-args.log"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
[ -n "${CLAUDE_ARGS_LOG:-}" ] && printf '%s\0' "$@" >> "$CLAUDE_ARGS_LOG"
printf '{"type":"result","subtype":"success","result":"REVIEW: PASS"}\n'
exit 0
STUB
chmod +x "$BIN/claude"

# Materialise X under MAIN via an explicit pin fetch (simulates a successful dispatch pin), then
# ADVANCE the live PR head to Y — the mid-review push. The reviewer must still be told to read X.
git -C "$ORIGIN" update-ref "refs/pull/${PR}/head" "$SHA_X"
git -C "$MAIN" fetch -q origin "+pull/${PR}/head:refs/herd-review/pin-${PR}-${SHA_X}" 2>/dev/null \
  || fail "C: setup fetch of X failed"
git -C "$ORIGIN" update-ref "refs/pull/${PR}/head" "$SHA_Y"   # mid-review push → head is now Y

: > "$CLAUDE_ARGS_LOG"
mkdir -p "$TREES/slug-c"
RES="$T/result-c"
# Unset HERD_REVIEW_BIN so we run the REAL herd-review.sh (not the PART B stub).
out="$(
  HERD_NO_PANE=1 \
  HERD_REVIEW_RESULT_FILE="$RES" \
  HERD_REVIEW_SHA="$SHA_X" \
  HERD_REVIEW_PIN_MODE="pinned" \
  HERD_CONFIG_FILE="$CFG" \
  WORKTREES_DIR="$TREES" \
  CLAUDE_ARGS_LOG="$CLAUDE_ARGS_LOG" \
  bash "$REVIEW" "$PR" "slug-c" 2>/dev/null
)"
rc=$?
[ "$rc" -eq 0 ] || fail "C: pinned review should exit 0 on PASS (got $rc)"$'\n'"$out"
printf '%s\n' "$out" | grep -q '^REVIEW: PASS' || fail "C: should print REVIEW: PASS (got: $out)"

prompt="$(tr '\0' '\n' < "$CLAUDE_ARGS_LOG")"
# Must instruct a git-diff against the DISPATCH sha X (not live gh pr diff for content).
printf '%s' "$prompt" | grep -Fq "$SHA_X" \
  || fail "C: prompt must name dispatch sha X"$'\n'"$prompt"
printf '%s' "$prompt" | grep -E -q "git -C .* diff .*${SHA_X}" \
  || fail "C: prompt must carry 'git … diff …<shaX>'"$'\n'"$prompt"
# Live-head content path must NOT be the instruction for reading the PR diff.
# (The prompt may mention gh pr diff as a "do NOT use" warning — that's fine — but must not
# instruct `gh pr diff <N>` as the read command in the THIS REVIEW trailer.)
printf '%s' "$prompt" | grep -E -q "read its pinned dispatch-sha diff with 'git " \
  || fail "C: THIS REVIEW trailer must pin to a git diff command"$'\n'"$prompt"
# And the trailer must NOT say read with 'gh pr diff N' as the active command.
printf '%s' "$prompt" | grep -E "read its (pinned dispatch-sha )?diff with 'gh pr diff" \
  && fail "C: must not instruct live 'gh pr diff' as the active read command"$'\n'"$prompt"
# Stable preamble keeps the placeholder (prompt-cache-stable).
printf '%s' "$prompt" | grep -Fq "git diff <merge-base>..<dispatch-sha>" \
  || fail "C: preamble must keep stable <merge-base>..<dispatch-sha> placeholder"$'\n'"$prompt"
# Content uniqueness: the X-only line must be in the pin range; Y-only must not be required.
# (We assert the prompt range ends at X; the actual `git diff` output is what the agent would see.)
mb="$(git -C "$MAIN" merge-base origin/main "$SHA_X")"
diff_x="$(git -C "$MAIN" diff "${mb}..${SHA_X}")"
diff_y="$(git -C "$MAIN" diff "${mb}..${SHA_Y}")"
printf '%s' "$diff_x" | grep -Fq 'x-content' || fail "C: X-range diff should contain x-content"
printf '%s' "$diff_x" | grep -Fq 'y-content' && fail "C: X-range diff must NOT contain y-content (Y is mid-review push)"
printf '%s' "$diff_y" | grep -Fq 'y-content' || fail "C: sanity — Y-range does contain y-content"
ok

# ── C2 — soft fallback when pin objects missing → live gh pr diff in the command ────────────────
# Empty MAIN-less sha with no objects: force fallback. Use a throwaway sha that is not in MAIN.
: > "$CLAUDE_ARGS_LOG"
RES2="$T/result-c2"
out2="$(
  HERD_NO_PANE=1 \
  HERD_REVIEW_RESULT_FILE="$RES2" \
  HERD_REVIEW_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
  HERD_REVIEW_PIN_MODE="unpinned" \
  HERD_CONFIG_FILE="$CFG" \
  WORKTREES_DIR="$TREES" \
  CLAUDE_ARGS_LOG="$CLAUDE_ARGS_LOG" \
  bash "$REVIEW" 77 "slug-c2" 2>/dev/null
)" || true
prompt2="$(tr '\0' '\n' < "$CLAUDE_ARGS_LOG")"
printf '%s' "$prompt2" | grep -Fq "gh pr diff 77" \
  || fail "C2: missing pin objects must fall back to live 'gh pr diff <PR>'"$'\n'"$prompt2"
ok

echo "ALL PASS ($pass checks)"
