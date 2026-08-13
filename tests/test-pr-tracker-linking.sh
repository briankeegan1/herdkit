#!/usr/bin/env bash
# test-pr-tracker-linking.sh — hermetic tests for deterministic PR-to-tracker linking (HERD-39).
#
# suite-deps: .github/PULL_REQUEST_TEMPLATE.md
#
# HERD-733: check C3b below feeds the REAL, committed .github/PULL_REQUEST_TEMPLATE.md through the
# ref extractor and asserts it does NOT falsely match, so a docs-only diff that edits this file must
# still select this test — a docs-scoped selection that ran only the doc-drift/caps-sync/conformance
# lint tests would let that assertion silently stop running.
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

# Stub backend that LOGS every update-state call and reports DONE|NOCHANGE per $STUB_RESULT — or, for
# PART D's mixed-outcome cases, per-ref via $STUB_FAIL_REFS (a space-separated list of refs that get
# NOCHANGE regardless of $STUB_RESULT; unset/empty is byte-identical to the pre-HERD-587 stub).
BDIR="$T/backends"; mkdir -p "$BDIR"
STUB_BACKEND_LOG="$T/backend-calls.log"; : > "$STUB_BACKEND_LOG"
export STUB_BACKEND_LOG
cat > "$BDIR/stub.sh" <<'STUB'
#!/usr/bin/env bash
_backend_update_state() {
  printf 'update-state %s %s\n' "$1" "$2" >> "$STUB_BACKEND_LOG"
  local res="${STUB_RESULT:-DONE}"
  case " ${STUB_FAIL_REFS:-} " in
    *" $1 "*) res="NOCHANGE" ;;
  esac
  _BACKEND_RESULT="$res"
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
printf '## Refs\n\nRefs: <tracker-id — or delete this line if none>\n' > "$BODY_PH"
GH_PR_BODY_FILE="$BODY_PH" reconcile_backlog 504 some-slug sha504
[ "$(backend_calls)" -eq 0 ] || fail "C3: an unfilled template placeholder must not be dispatched as a ref (got $(backend_calls))"
[ "$(scribe_calls)"  -eq 1 ] || fail "C3: placeholder ref should fall back to fuzzy (got $(scribe_calls))"
ok

# ── C3b — the REAL PULL_REQUEST_TEMPLATE.md left unchanged (untracked PR) must NOT extract a ref ──
# gh pr view returns the raw body INCLUDING HTML comments; the template carries example text inside a
# <!-- --> block. An untracked PR opened from the template and left as-is must fall back to fuzzy —
# never silently mark an unrelated item shipped. This reproduces the review BLOCK on #156 directly.
reset_state
PRT="$REPO/.github/PULL_REQUEST_TEMPLATE.md"
[ -f "$PRT" ] || fail "C3b: PULL_REQUEST_TEMPLATE.md not found at $PRT"
GH_PR_BODY_FILE="$PRT" reconcile_backlog 505 template-slug sha505
[ "$(backend_calls)" -eq 0 ] || fail "C3b: unchanged PR template must NOT dispatch a backend ref (got $(backend_calls)) — comment-embedded example poisoned the extractor"
[ "$(scribe_calls)"  -eq 1 ] || fail "C3b: unchanged PR template should fall back to fuzzy (got $(scribe_calls))"
grep -q '"resolution":"fuzzy"' "$JOURNAL_FILE" || fail "C3b: unchanged template should journal resolution=fuzzy"
ok

# ── C3c — a 'Refs:' line buried in an HTML comment is stripped before extraction (defense-in-depth) ──
# Even if a comment example were a bare line-start 'Refs: WRONG-1', the comment strip removes it; the
# only REAL ref (outside comments) is the one that wins.
reset_state
BODY_CMT="$T/body-comment.md"
printf '## Refs\n\n<!--\nexample only, do not treat as real:\nRefs: WRONG-1\n-->\n\nRefs: RIGHT-2\n' > "$BODY_CMT"
GH_PR_BODY_FILE="$BODY_CMT" reconcile_backlog 506 cmt-slug sha506
[ "$(backend_calls)" -eq 1 ] || fail "C3c: expected exactly 1 backend call (the real ref), got $(backend_calls)"
grep -q '^update-state RIGHT-2 done$' "$STUB_BACKEND_LOG" || fail "C3c: must resolve the REAL ref RIGHT-2, not the comment example"$'\n'"$(cat "$STUB_BACKEND_LOG")"
grep -q 'WRONG-1' "$STUB_BACKEND_LOG" && fail "C3c: a comment-embedded 'Refs:' must NEVER be extracted"
ok

# ── C3d — a commented-out ref with NO real ref elsewhere → no dispatch, fuzzy fallback ──
reset_state
BODY_CMTONLY="$T/body-comment-only.md"
printf '## Refs\n\n<!-- Refs: GHOST-9 -->\n\n(no real tracker item)\n' > "$BODY_CMTONLY"
GH_PR_BODY_FILE="$BODY_CMTONLY" reconcile_backlog 507 ghost-slug sha507
[ "$(backend_calls)" -eq 0 ] || fail "C3d: a ref that exists ONLY inside a comment must not be dispatched (got $(backend_calls))"
[ "$(scribe_calls)"  -eq 1 ] || fail "C3d: comment-only ref should fall back to fuzzy (got $(scribe_calls))"
ok

# ── C4 — _reconcile_via_ref returns non-zero when the active backend has NO update-state op ──
# (the default 'file' backend records state by editing BACKLOG.md, not via dispatch — must fall back).
( SCRIBE_BACKEND=file SCRIBE_BACKEND_DIR="$REPO/scripts/herd/backends" _reconcile_via_ref HERD-39 ) \
  && fail "C4: _reconcile_via_ref must FAIL for a backend with no _backend_update_state op (file backend)"
ok

################################################################################
# PART D — MULTI-REF (HERD-587, GH #708): reconcile_backlog walks EVERY 'Refs:' line
################################################################################
# PR #708 carried FOUR bare 'Refs:' lines; the pre-fix code above resolved only the FIRST one
# (_reconcile_pr_ref) and silently treated the other three as if they weren't there — three tracker
# items sat open for two hours until a human hand-closed them. reconcile_backlog now walks EVERY
# distinct ref the tolerant parser (HERD-522) extracts (_reconcile_pr_refs) through the SAME
# verify-after-write done-transition (_reconcile_via_ref) PART B already proved for a single ref, one
# call per ref, journaling per ref. B1/B2 above (a single 'Refs:' line) already prove the n=1 case is
# byte-identical to before this item — this part proves n>1.
type _reconcile_pr_refs >/dev/null 2>&1 || fail "_reconcile_pr_refs not defined"
ok

# _journal_ref_resolution <ref> — the 'resolution' recorded on the reconcile event naming <ref>.
_journal_ref_resolution() {
  grep "\"ref\":\"$1\"" "$JOURNAL_FILE" | grep -oE '"resolution":"[a-z-]+"' | sed -E 's/.*:"([a-z-]+)"/\1/' | tail -n1
}

# ── D1 — three distinct bare 'Refs:' lines, ALL resolve → 3 backend calls, 3 per-ref explicit-ref
#         journal lines, NO fuzzy scribe request (the exact shape of PR #708, now fixed) ──
reset_state
BODY_MULTI="$T/body-multi.md"
printf 'Closes several trackers.\n\nRefs: HERD-101\nRefs: HERD-102\nRefs: HERD-103\n' > "$BODY_MULTI"
GH_PR_BODY_FILE="$BODY_MULTI" reconcile_backlog 601 multi-ref-slug sha601
[ "$(backend_calls)" -eq 3 ] || fail "D1: expected exactly 3 backend update-state calls, got $(backend_calls)"
for r in HERD-101 HERD-102 HERD-103; do
  grep -q "^update-state $r done\$" "$STUB_BACKEND_LOG" || fail "D1: backend not asked to mark $r done"$'\n'"$(cat "$STUB_BACKEND_LOG")"
  [ "$(_journal_ref_resolution "$r")" = "explicit-ref" ] || fail "D1: $r should journal resolution=explicit-ref, got '$(_journal_ref_resolution "$r")'"
done
[ "$(grep -c '"event":"reconcile"' "$JOURNAL_FILE")" -eq 3 ] \
  || fail "D1: expected exactly 3 reconcile journal lines (one per ref), got $(grep -c '"event":"reconcile"' "$JOURNAL_FILE")"
[ "$(scribe_calls)" -eq 0 ] || fail "D1: all-resolved multi-ref must NOT enqueue a fuzzy scribe request (got $(scribe_calls))"
ok

# ── D2 — mixed: 2 of 3 resolve, 1 NOCHANGE → still 3 backend calls + 3 per-ref journal lines
#         (2 explicit-ref, 1 fuzzy), but NO fuzzy scribe request — at least one ref DID resolve, and a
#         title/worktree fuzzy-match would risk mis-closing an UNRELATED item for the refs that did ──
reset_state
BODY_MIXED="$T/body-mixed.md"
printf 'Refs: HERD-201\nRefs: HERD-202\nRefs: HERD-203\n' > "$BODY_MIXED"
STUB_FAIL_REFS="HERD-202"
GH_PR_BODY_FILE="$BODY_MIXED" reconcile_backlog 602 mixed-ref-slug sha602
unset STUB_FAIL_REFS
[ "$(backend_calls)" -eq 3 ] || fail "D2: expected 3 backend calls (one per ref), got $(backend_calls)"
[ "$(_journal_ref_resolution HERD-201)" = "explicit-ref" ] || fail "D2: HERD-201 should resolve explicit-ref"
[ "$(_journal_ref_resolution HERD-202)" = "fuzzy"        ] || fail "D2: HERD-202 (NOCHANGE) should journal fuzzy"
[ "$(_journal_ref_resolution HERD-203)" = "explicit-ref" ] || fail "D2: HERD-203 should resolve explicit-ref"
[ "$(scribe_calls)" -eq 0 ] || fail "D2: a PARTIAL multi-ref success must NOT fall back to fuzzy scribe (got $(scribe_calls))"
ok

# ── D3 — ALL THREE fail (NOCHANGE) → 3 backend calls + 3 fuzzy journal lines, but exactly ONE fuzzy
#         scribe request for the whole PR (not one per failed ref) ──
reset_state
BODY_ALLFAIL="$T/body-allfail.md"
printf 'Refs: HERD-301\nRefs: HERD-302\nRefs: HERD-303\n' > "$BODY_ALLFAIL"
STUB_RESULT=NOCHANGE
GH_PR_BODY_FILE="$BODY_ALLFAIL" reconcile_backlog 603 allfail-slug sha603
unset STUB_RESULT
[ "$(backend_calls)" -eq 3 ] || fail "D3: expected 3 backend calls, got $(backend_calls)"
for r in HERD-301 HERD-302 HERD-303; do
  [ "$(_journal_ref_resolution "$r")" = "fuzzy" ] || fail "D3: $r should journal resolution=fuzzy"
done
[ "$(scribe_calls)" -eq 1 ] || fail "D3: an all-failed multi-ref PR should enqueue exactly ONE fuzzy scribe request, got $(scribe_calls)"
grep -q 'PR #603' "$SCRIBE_LOG" || fail "D3: fuzzy enqueue does not name the PR number"
ok

# ── D4 — a REPEATED ref line dispatches ONCE, not once per occurrence ──
reset_state
BODY_DUP="$T/body-dup.md"
printf 'Refs: HERD-401\nRefs: HERD-401\n' > "$BODY_DUP"
GH_PR_BODY_FILE="$BODY_DUP" reconcile_backlog 604 dup-ref-slug sha604
[ "$(backend_calls)" -eq 1 ] || fail "D4: a repeated ref line must dispatch ONCE, not once per occurrence (got $(backend_calls))"
ok

# ── D5 — idempotent: a re-run tick for the same multi-ref PR+sha neither re-dispatches nor re-enqueues ──
GH_PR_BODY_FILE="$BODY_DUP" reconcile_backlog 604 dup-ref-slug sha604
[ "$(backend_calls)" -eq 1 ] || fail "D5: idempotent re-run tick re-dispatched a multi-ref PR (got $(backend_calls), want 1)"
[ "$(scribe_calls)"  -eq 0 ] || fail "D5: idempotent re-run tick enqueued a scribe request"
ok

echo "ALL PASS ($pass checks)"
