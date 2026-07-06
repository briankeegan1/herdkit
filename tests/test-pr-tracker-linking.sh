#!/usr/bin/env bash
# test-pr-tracker-linking.sh — hermetic tests for deterministic PR-to-tracker linking (HERD-39).
#
# Three network-free layers, NO real herdr / gh / claude / scribe drainer:
#
#   PART A — the builder lanes (herd-quick.sh / herd-feature.sh) thread HERD_ITEM_REF into the
#            workflow-rules text of the externalized task spec:
#              · HERD_ITEM_REF UNSET → the rules carry NO 'Refs:' requirement (byte-unchanged prompt).
#              · HERD_ITEM_REF=HERD-39 → the rules REQUIRE a 'Refs: HERD-39' line in the PR body.
#            Scaffold mirrors tests/test-local-review-prepr.sh PART A.
#
#   PART B — agent-watch.sh merge-time reconcile resolves an EXPLICIT ref FIRST: given a merged PR
#            whose body carries 'Refs: HERD-39', reconcile_backlog dispatches the active backend's
#            update-state op (a stub backend that LOGS every update-state call) and does NOT fall to
#            the fuzzy scribe path. The journal records resolution=explicit-ref.
#
#   PART C — fuzzy fallback is preserved: a ref-LESS merged PR (and a ref whose backend cannot resolve
#            it) still enqueue exactly one fuzzy scribe reconcile request, journaled resolution=fuzzy,
#            with the backend's update-state NEVER driven for the ref-less case.
#            Lib-mode scaffold mirrors tests/test-autoreconcile.sh.
#
# Run:  bash tests/test-pr-tracker-linking.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
QUICK="$REPO/scripts/herd/herd-quick.sh"
FEATURE="$REPO/scripts/herd/herd-feature.sh"
WATCH="$REPO/scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git     >/dev/null 2>&1 || fail "git required to run this test"
[ -f "$QUICK" ]   || fail "herd-quick.sh not found at $QUICK"
[ -f "$FEATURE" ] || fail "herd-feature.sh not found at $FEATURE"
[ -f "$WATCH" ]   || fail "agent-watch.sh not found at $WATCH"

################################################################################
# PART A — the lanes thread HERD_ITEM_REF into the externalized spec
################################################################################
# Stubbed herdr/claude + a throwaway origin/clone repo (mirrors test-local-review-prepr PART A).
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

export HOME="$T"                 # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit"
export HERD_SKIP_PREFLIGHT=1
TREES="$T/trees"
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
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

# run_lane <script> <slug> [ENV=val ...] — run a lane; print the externalized spec path.
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
has(){   grep -Fq -- "$2" "$1" || fail "$3: spec missing expected text: $2"$'\n'"---"$'\n'"$(cat "$1")"; }
lacks(){ grep -Fq -- "$2" "$1" && fail "$3: spec UNEXPECTEDLY contains: $2"$'\n'"---"$'\n'"$(cat "$1")"; return 0; }

# ── A1 — HERD_ITEM_REF UNSET: NO 'Refs:' requirement (byte-unchanged prompt). Both lanes. ──
for pair in "$QUICK:noref-quick" "$FEATURE:noref-feat"; do
  s="$(run_lane "${pair%%:*}" "${pair##*:}")"
  lacks "$s" "Refs:"                          "A1 ${pair##*:}"
  lacks "$s" "tracked as"                     "A1 ${pair##*:}"
  # the surrounding rules text is otherwise intact
  has   "$s" "Before running 'gh pr create'," "A1 ${pair##*:}"
  ok
done

# ── A2 — HERD_ITEM_REF=HERD-39: REQUIRE a 'Refs: HERD-39' line in the PR body. Both lanes. ──
for pair in "$QUICK:ref-quick" "$FEATURE:ref-feat"; do
  s="$(run_lane "${pair%%:*}" "${pair##*:}" HERD_ITEM_REF=HERD-39)"
  has "$s" "Refs: HERD-39"   "A2 ${pair##*:}"
  has "$s" "tracked as HERD-39" "A2 ${pair##*:}"
  has "$s" "PR body"         "A2 ${pair##*:}"
  ok
done

# ── A3 — a DIFFERENT ref id is threaded verbatim (not hardcoded to HERD-39) ──
s="$(run_lane "$QUICK" "ref-eng" HERD_ITEM_REF=ENG-7)"
has  "$s" "Refs: ENG-7" "A3"
lacks "$s" "Refs: HERD-39" "A3"
ok

################################################################################
# PART B & C — agent-watch.sh reconcile: explicit-ref first, fuzzy fallback
################################################################################
# Stub gh: `gh pr view <pr> --json body -q .body` echoes $GH_PR_BODY_FILE; everything else is a no-op.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  [ -n "${GH_PR_BODY_FILE:-}" ] && [ -f "$GH_PR_BODY_FILE" ] && cat "$GH_PR_BODY_FILE"
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/gh"
# git already resolvable (the PART A clone put a real git on PATH); herdr stub already present.

# Stub backend that LOGS every update-state call and reports DONE|NOCHANGE per $STUB_RESULT.
BDIR="$T/backends"; mkdir -p "$BDIR"
STUB_BACKEND_LOG="$T/backend-calls.log"; : > "$STUB_BACKEND_LOG"
export STUB_BACKEND_LOG
cat > "$BDIR/stub.sh" <<'STUB'
#!/usr/bin/env bash
_backend_update_state() {
  printf 'update-state %s %s\n' "$1" "$2" >> "$STUB_BACKEND_LOG"
  _BACKEND_RESULT="${STUB_RESULT:-DONE}"
}
STUB

# Source agent-watch.sh in lib mode with our own config/trees (mirrors test-autoreconcile.sh).
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees2"; mkdir -p "$WORKTREES_DIR"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

# Redirect $HERE at a stub dir whose scribe.sh LOGS every fuzzy enqueue (one line per call).
STUBHERD="$T/herd-stub"; mkdir -p "$STUBHERD"
SCRIBE_LOG="$T/scribe-calls.log"; : > "$SCRIBE_LOG"
cat > "$STUBHERD/scribe.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$SCRIBE_LOG"
STUB
chmod +x "$STUBHERD/scribe.sh"
HERE="$STUBHERD"

# Point the reconcile's backend dispatch at the stub backend.
export SCRIBE_BACKEND=stub
export SCRIBE_BACKEND_DIR="$BDIR"

scribe_calls()  { [ -s "$SCRIBE_LOG" ] && grep -c . "$SCRIBE_LOG" || echo 0; }
backend_calls() { [ -s "$STUB_BACKEND_LOG" ] && grep -c . "$STUB_BACKEND_LOG" || echo 0; }
reset_state()   { : > "$RECONCILE_STATE"; : > "$SCRIBE_LOG"; : > "$STUB_BACKEND_LOG"; : > "$JOURNAL_FILE"; }

type reconcile_backlog  >/dev/null 2>&1 || fail "reconcile_backlog not defined"
type _reconcile_pr_ref  >/dev/null 2>&1 || fail "_reconcile_pr_ref not defined"
type _reconcile_via_ref >/dev/null 2>&1 || fail "_reconcile_via_ref not defined"
[ -n "${RECONCILE_STATE:-}" ] || fail "RECONCILE_STATE ledger var not set"
ok

# ── B1 — merged PR carries 'Refs: HERD-39' → explicit-ref dispatch, NO fuzzy scribe ──
reset_state
BODY="$T/body-ref.md"; printf '## Summary\n\nDeterministic linking.\n\nRefs: HERD-39\n' > "$BODY"
GH_PR_BODY_FILE="$BODY" reconcile_backlog 501 pr-tracker-linking sha501
[ "$(backend_calls)" -eq 1 ] || fail "B1: expected exactly 1 backend update-state call, got $(backend_calls)"
grep -q '^update-state HERD-39 done$' "$STUB_BACKEND_LOG" || fail "B1: backend not asked to mark HERD-39 done"$'\n'"$(cat "$STUB_BACKEND_LOG")"
[ "$(scribe_calls)" -eq 0 ] || fail "B1: explicit-ref path must NOT enqueue a fuzzy scribe request (got $(scribe_calls))"
grep -q '"resolution":"explicit-ref"' "$JOURNAL_FILE" || fail "B1: journal missing resolution=explicit-ref"$'\n'"$(cat "$JOURNAL_FILE")"
grep -q '"ref":"HERD-39"' "$JOURNAL_FILE" || fail "B1: journal missing the resolved ref"
ok

# ── B2 — idempotent: a re-run tick for the same PR+sha neither re-dispatches nor re-enqueues ──
GH_PR_BODY_FILE="$BODY" reconcile_backlog 501 pr-tracker-linking sha501
[ "$(backend_calls)" -eq 1 ] || fail "B2: re-run tick re-dispatched (got $(backend_calls), want 1)"
[ "$(scribe_calls)"  -eq 0 ] || fail "B2: re-run tick enqueued a scribe request (got $(scribe_calls))"
ok

# ── C1 — ref-LESS merged PR → fuzzy scribe fallback, backend update-state NEVER driven ──
reset_state
BODY_NOREF="$T/body-noref.md"; printf '## Summary\n\nNo tracker item here.\n' > "$BODY_NOREF"
GH_PR_BODY_FILE="$BODY_NOREF" reconcile_backlog 502 legacy-slug sha502
[ "$(backend_calls)" -eq 0 ] || fail "C1: ref-less PR must NOT drive the backend (got $(backend_calls))"
[ "$(scribe_calls)"  -eq 1 ] || fail "C1: ref-less PR should enqueue exactly 1 fuzzy scribe request (got $(scribe_calls))"
grep -q '^Reconcile:'                "$SCRIBE_LOG" || fail "C1: fuzzy enqueue is not a 'Reconcile:' request"
grep -q 'worktree legacy-slug'       "$SCRIBE_LOG" || fail "C1: fuzzy enqueue does not name the slug"
grep -q 'PR #502'                    "$SCRIBE_LOG" || fail "C1: fuzzy enqueue does not name the PR number"
grep -q '"resolution":"fuzzy"'       "$JOURNAL_FILE" || fail "C1: journal missing resolution=fuzzy"
ok

# ── C2 — ref present but backend cannot resolve it (NOCHANGE) → fall back to fuzzy, journaled fuzzy ──
reset_state
STUB_RESULT=NOCHANGE
GH_PR_BODY_FILE="$BODY" reconcile_backlog 503 pr-tracker-linking sha503
unset STUB_RESULT
[ "$(backend_calls)" -eq 1 ] || fail "C2: backend should be TRIED once for the ref (got $(backend_calls))"
[ "$(scribe_calls)"  -eq 1 ] || fail "C2: a NOCHANGE backend must fall back to the fuzzy scribe path (got $(scribe_calls))"
grep -q '"resolution":"fuzzy"' "$JOURNAL_FILE" || fail "C2: unresolved ref should journal resolution=fuzzy"
# the ref is still recorded on the fuzzy journal line for the audit trail
grep -q '"ref":"HERD-39"'      "$JOURNAL_FILE" || fail "C2: journal should still record the unresolved ref"
ok

# ── C3 — placeholder ref (unfilled PR-template line) is treated as NO ref → fuzzy ──
reset_state
BODY_PH="$T/body-placeholder.md"
printf '## Refs\n\nRefs: <tracker-id, e.g. HERD-39 — or remove this line if none>\n' > "$BODY_PH"
GH_PR_BODY_FILE="$BODY_PH" reconcile_backlog 504 some-slug sha504
[ "$(backend_calls)" -eq 0 ] || fail "C3: an unfilled template placeholder must not be dispatched as a ref (got $(backend_calls))"
[ "$(scribe_calls)"  -eq 1 ] || fail "C3: placeholder ref should fall back to fuzzy (got $(scribe_calls))"
ok

# ── C4 — _reconcile_via_ref returns non-zero when the active backend has NO update-state op ──
# (the default 'file' backend records state by editing BACKLOG.md, not via dispatch — must fall back).
( SCRIBE_BACKEND=file SCRIBE_BACKEND_DIR="$REPO/scripts/herd/backends" _reconcile_via_ref HERD-39 ) \
  && fail "C4: _reconcile_via_ref must FAIL for a backend with no _backend_update_state op (file backend)"
ok

echo "ALL PASS ($pass checks)"
