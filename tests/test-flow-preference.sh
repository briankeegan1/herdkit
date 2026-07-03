#!/usr/bin/env bash
# test-flow-preference.sh — the flow-preference first increment (PR_FLOW / PR_READY_WHEN threaded
# into the LANE RULES, plus the new init-written keys). Two hermetic layers, NO network / NO real
# herdr / NO real gh:
#
#   PART A — `herd init` writes the new keys with SAFE DEFAULTS that preserve today's exact behavior:
#            PR_FLOW=direct, PR_READY_WHEN=builder, DELETE_BRANCH_ON_MERGE=false, LOCAL_REVIEW=none.
#
#   PART B — the builder lanes (herd-quick.sh / herd-feature.sh) thread PR_FLOW + PR_READY_WHEN into
#            the workflow-rules text of the externalized task spec:
#              · defaults (direct + builder)  → a plain `gh pr create`, NO --draft, NO draft wording
#                (byte-for-byte today's behavior).
#              · PR_FLOW=draft                → `gh pr create --draft` (the watcher already HOLDS
#                draft PRs at agent-watch.sh:157 — this PR does not touch that).
#              · PR_READY_WHEN honored in the wording: builder self-promotes; coordinator/human leave
#                it in draft and must NOT run `gh pr ready`.
#              · UNKNOWN values fall back SAFELY: bad PR_FLOW → direct; bad PR_READY_WHEN → builder.
#
# Lane scaffold mirrors tests/test-externalize-task-specs.sh (stubbed herdr/claude + a throwaway git
# repo so new-feature.sh's `git worktree add … origin/main` works). The spec is inspected in the
# externalized file $WORKTREES_DIR/<slug>.task.md.
# Run:  bash tests/test-flow-preference.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
QUICK="$REPO/scripts/herd/herd-quick.sh"
FEATURE="$REPO/scripts/herd/herd-feature.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git     >/dev/null 2>&1 || fail "git required to run this test"

# ── PART A — herd init writes the new keys with safe, behavior-preserving defaults ─────────────────
# No gh remote → GitHub detection skips gracefully (irrelevant to the flow keys, which are fixed
# defaults via ask()); HERD_NONINTERACTIVE=1 makes every ask() return its default.
A="$T/initproj"; mkdir -p "$A"
git -C "$A" init -q
git -C "$A" config user.email t@t.t; git -C "$A" config user.name t
git -C "$A" commit -q --allow-empty -m init
git -C "$A" branch -M main
out="$(cd "$A" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" init 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "A: herd init exited non-zero (rc=$RC)"$'\n'"$out"
cfg="$A/.herd/config"
[ -f "$cfg" ] || fail "A: init wrote no .herd/config"
grep -qE '^PR_FLOW="direct"$'                "$cfg" || fail "A: PR_FLOW default not direct"$'\n'"$(cat "$cfg")"
grep -qE '^PR_READY_WHEN="builder"$'          "$cfg" || fail "A: PR_READY_WHEN default not builder"
grep -qE '^DELETE_BRANCH_ON_MERGE="false"$'   "$cfg" || fail "A: DELETE_BRANCH_ON_MERGE default not false (must preserve today's retain-branch behavior)"
grep -qE '^LOCAL_REVIEW="none"$'              "$cfg" || fail "A: LOCAL_REVIEW default not none"
ok

# ── PART B scaffold — stubbed herdr/claude + throwaway repo (mirrors test-externalize-task-specs) ──
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "tab list")       printf '{"result":{"tabs":[]}}\n' ;;
  "tab create")     printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start")    printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  "pane split")     printf '{"result":{"pane":{"pane_id":"pTest"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
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
# NOTE: the config deliberately OMITS PR_FLOW/PR_READY_WHEN so each case can set them via the
# environment (herd-config.sh sources this file but never assigns those keys, so the env var wins).
cat > "$CFG" <<EOF
PROJECT_ROOT="$GREPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit"
APP_PREVIEW_CMD=""
MODEL_QUICK="test-quick-model"
MODEL_FEATURE="test-feature-model"
EOF

# run_lane <script> <slug> [ENV=val ...] — run a lane with the given PR_* env, print the spec path.
# Fails loudly if the lane errors or the externalized spec file is not written.
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

# ── B1 — DEFAULTS (no PR_* set): plain `gh pr create`, NO --draft, NO draft wording. Both lanes. ──
for pair in "$QUICK:def-quick" "$FEATURE:def-feat"; do
  s="$(run_lane "${pair%%:*}" "${pair##*:}")"
  has  "$s" "Before running 'gh pr create'," "B1 ${pair##*:}"
  lacks "$s" "gh pr create --draft"          "B1 ${pair##*:}"
  lacks "$s" "as a DRAFT"                     "B1 ${pair##*:}"
  ok
done

# ── B2 — PR_FLOW=draft, default readiness (builder): --draft + builder self-promote wording ──────
for pair in "$QUICK:draft-quick" "$FEATURE:draft-feat"; do
  s="$(run_lane "${pair%%:*}" "${pair##*:}" PR_FLOW=draft)"
  has "$s" "gh pr create --draft"                          "B2 ${pair##*:}"
  has "$s" "promote it yourself with 'gh pr ready"          "B2 ${pair##*:}"
  ok
done

# ── B3 — PR_FLOW=draft, PR_READY_WHEN=coordinator: leave in draft, coordinator promotes ──────────
s="$(run_lane "$QUICK" "draft-coord" PR_FLOW=draft PR_READY_WHEN=coordinator)"
has "$s" "gh pr create --draft"          "B3"
has "$s" "COORDINATOR promotes it"        "B3"
has "$s" "do NOT run 'gh pr ready'"       "B3"
ok

# ── B4 — PR_FLOW=draft, PR_READY_WHEN=human: leave in draft, human promotes ──────────────────────
s="$(run_lane "$FEATURE" "draft-human" PR_FLOW=draft PR_READY_WHEN=human)"
has "$s" "gh pr create --draft"     "B4"
has "$s" "a HUMAN promotes it"       "B4"
has "$s" "do NOT run 'gh pr ready'"  "B4"
ok

# ── B5 — UNKNOWN PR_FLOW falls back to direct (no --draft) ────────────────────────────────────────
s="$(run_lane "$QUICK" "bogus-flow" PR_FLOW=sideways PR_READY_WHEN=human)"
lacks "$s" "gh pr create --draft"          "B5"
has  "$s" "Before running 'gh pr create'," "B5"
ok

# ── B6 — draft + UNKNOWN PR_READY_WHEN falls back to builder (self-promote wording) ───────────────
s="$(run_lane "$FEATURE" "bogus-ready" PR_FLOW=draft PR_READY_WHEN=nobody)"
has "$s" "gh pr create --draft"                 "B6"
has "$s" "promote it yourself with 'gh pr ready" "B6"
ok

echo "ALL PASS ($pass checks)"
