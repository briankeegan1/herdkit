#!/usr/bin/env bash
# test-risk-scoped-prpr-review.sh — hermetic tests for LOCAL_REVIEW=risk-scoped + LOCAL_REVIEW_GLOB
# (HERD-100). The blanket LOCAL_REVIEW=pre-pr reviews EVERY builder diff before its PR; journal
# analysis shows round-1 BLOCKs cluster on high-churn engine files, so risk-scoped runs the local
# review ONLY when the builder's diff surface matches LOCAL_REVIEW_GLOB — low-risk diffs skip straight
# to the PR (the watcher's post-PR gate stays authoritative). This exercises the wiring that threads
# that decision into the builder task spec, and the diff-surface-vs-glob classification it encodes.
#
#   PART A — the builder lanes (herd-quick.sh / herd-feature.sh) thread LOCAL_REVIEW into the spec:
#              · LOCAL_REVIEW=risk-scoped + a valid LOCAL_REVIEW_GLOB → the spec carries a CONDITIONAL
#                local-review instruction: list the diff surface (git diff …--name-only), egrep it
#                against the glob, review-then-PR on a match, SKIP straight to the PR on no match.
#              · risk-scoped + EMPTY glob         → FAIL-SOFT: loud warn + fall back to unconditional
#                pre-pr (review everything); NO risk-scoped conditional in the spec.
#              · risk-scoped + INVALID glob regex → same FAIL-SOFT fallback + warn.
#              · LOCAL_REVIEW=pre-pr (regression) → unconditional review, NO risk-scoped conditional.
#              · LOCAL_REVIEW=none / unset        → byte-unchanged: NO local-review step at all.
#
#   PART B — the diff-surface-vs-glob classification the spec instructs the builder to run really
#            discriminates a matching (engine) surface from a non-matching (low-risk) one, using the
#            EXACT egrep the rule names.
#
# Scaffold mirrors tests/test-local-review-prepr.sh PART A (stubbed herdr/claude, throwaway repo).
# Run:  bash tests/test-risk-scoped-prpr-review.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
QUICK="$REPO/scripts/herd/herd-quick.sh"
FEATURE="$REPO/scripts/herd/herd-feature.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git     >/dev/null 2>&1 || fail "git required to run this test"

# ── Shared scaffold — stubbed herdr/claude + throwaway repo (mirrors test-local-review-prepr) ──────
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

export HOME="$T"
export WORKSPACE_NAME="herdkit"
export HERD_SKIP_PREFLIGHT=1
TREES="$T/trees"
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
# Config OMITS LOCAL_REVIEW / LOCAL_REVIEW_GLOB so each case sets them via the environment.
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

# run_lane <script> <slug> [ENV=val ...] — run a lane, print the spec path. Combined stdout+stderr is
# captured to the DETERMINISTIC path "$T/<slug>.out" (referenced directly by callers that assert on a
# warning — run_lane executes in a command-substitution subshell, so it cannot export a var upward).
run_lane(){
  local script="$1" slug="$2"; shift 2
  local out="$T/$slug.out"
  if ! HERD_NO_APP=1 env "$@" bash "$script" "$slug" "seed task body" >"$out" 2>&1; then
    fail "lane $(basename "$script") exited non-zero for '$slug'"$'\n'"$(cat "$out")"
  fi
  local spec="$TREES/$slug.task.md"
  [ -f "$spec" ] || fail "$slug: spec file not written at $spec"
  printf '%s' "$spec"
}
has(){  grep -Fq -- "$2" "$1" || fail "$3: spec missing expected text: $2"$'\n'"---"$'\n'"$(cat "$1")"; }
lacks(){ grep -Fq -- "$2" "$1" && fail "$3: spec UNEXPECTEDLY contains: $2"$'\n'"---"$'\n'"$(cat "$1")"; return 0; }

GLOB='^scripts/herd/|^bin/'

################################################################################
# PART A — the lanes thread LOCAL_REVIEW=risk-scoped into the externalized spec
################################################################################

# ── A1 — risk-scoped + valid glob: CONDITIONAL local review keyed on the diff surface. Both lanes. ──
for pair in "$QUICK:rs-quick" "$FEATURE:rs-feat"; do
  s="$(run_lane "${pair%%:*}" "${pair##*:}" LOCAL_REVIEW=risk-scoped LOCAL_REVIEW_GLOB="$GLOB")"
  has "$s" "herd-review.sh --local"                    "A1 ${pair##*:}"
  has "$s" "REVIEW: PASS"                               "A1 ${pair##*:}"
  has "$s" "REVIEW: BLOCK"                              "A1 ${pair##*:}"
  # the risk-scoping mechanics: the builder lists its diff surface and egreps it against THE glob
  has "$s" "git diff origin/main...HEAD --name-only"   "A1 ${pair##*:}"
  has "$s" "$GLOB"                                      "A1 ${pair##*:}"
  # the low-risk branch: no match → skip the review and open the PR directly
  has "$s" "SKIP the local review"                     "A1 ${pair##*:}"
  has "$s" "before running 'gh pr create'"             "A1 ${pair##*:}"
  ok
done

# ── A2 — REGRESSION: LOCAL_REVIEW=pre-pr stays UNCONDITIONAL (no risk-scoped diff-surface gate). ────
for pair in "$QUICK:pp-quick" "$FEATURE:pp-feat"; do
  s="$(run_lane "${pair%%:*}" "${pair##*:}" LOCAL_REVIEW=pre-pr)"
  has  "$s" "herd-review.sh --local"                   "A2 ${pair##*:}"
  has  "$s" "REVIEW: PASS"                              "A2 ${pair##*:}"
  lacks "$s" "--name-only"                              "A2 ${pair##*:}"   # no risk-scoping in pre-pr
  lacks "$s" "SKIP the local review"                    "A2 ${pair##*:}"
  ok
done

# ── A3 — FAIL-SOFT: risk-scoped with an EMPTY glob → loud warn + fall back to unconditional pre-pr. ─
s="$(run_lane "$QUICK" "rs-emptyglob" LOCAL_REVIEW=risk-scoped)"
has   "$s" "herd-review.sh --local"                    "A3"   # still reviews (safe fallback)
lacks "$s" "--name-only"                               "A3"   # but NOT risk-scoped
lacks "$s" "SKIP the local review"                     "A3"
grep -Fq "LOCAL_REVIEW_GLOB is empty" "$T/rs-emptyglob.out" \
  || fail "A3: empty-glob fallback must warn on stderr"$'\n'"$(cat "$T/rs-emptyglob.out")"
ok

# ── A4 — FAIL-SOFT: risk-scoped with an INVALID glob regex → loud warn + fall back to pre-pr. ───────
s="$(run_lane "$QUICK" "rs-badglob" LOCAL_REVIEW=risk-scoped LOCAL_REVIEW_GLOB='[unterminated(')"
has   "$s" "herd-review.sh --local"                    "A4"
lacks "$s" "--name-only"                               "A4"
grep -Fq "invalid LOCAL_REVIEW_GLOB regex" "$T/rs-badglob.out" \
  || fail "A4: invalid-glob fallback must warn on stderr"$'\n'"$(cat "$T/rs-badglob.out")"
ok

# ── A5 — DEFAULT (LOCAL_REVIEW unset): byte-unchanged, NO local-review step. Both lanes. ───────────
for pair in "$QUICK:none-quick" "$FEATURE:none-feat"; do
  s="$(run_lane "${pair%%:*}" "${pair##*:}")"
  lacks "$s" "herd-review.sh --local"                  "A5 ${pair##*:}"
  lacks "$s" "--name-only"                             "A5 ${pair##*:}"
  ok
done

# ── A6 — an UNKNOWN glob-less mode is unaffected: LOCAL_REVIEW=sideways → none (no review step). ────
s="$(run_lane "$QUICK" "rs-bogusmode" LOCAL_REVIEW=sideways LOCAL_REVIEW_GLOB="$GLOB")"
lacks "$s" "herd-review.sh --local"                    "A6"
ok

################################################################################
# PART B — the diff-surface-vs-glob classification the rule instructs really discriminates
################################################################################
# The rule tells the builder to run  git diff … --name-only | grep -qE "$GLOB". Prove that egrep
# separates an ENGINE surface (must review) from a LOW-RISK surface (skips) for a sample diff.
engine=$'scripts/herd/agent-watch.sh\nREADME.md'   # a matching engine path present
lowrisk=$'README.md\ndocs/notes.md'                # docs-only, no engine path
printf '%s\n' "$engine"  | grep -qE "$GLOB" || fail "B: an engine-surface diff must MATCH the risk glob"
printf '%s\n' "$lowrisk" | grep -qE "$GLOB" && fail "B: a low-risk docs diff must NOT match the risk glob"
ok

echo "ALL PASS ($pass checks)"
