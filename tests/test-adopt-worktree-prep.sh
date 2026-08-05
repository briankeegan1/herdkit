#!/usr/bin/env bash
# test-adopt-worktree-prep.sh — hermetic proof that an ADOPTED worktree gets the SAME preparation a
# LANE worktree gets (HERD-535, GitHub issue #660).
#
# THE BUG: ADOPT_REMOTE_PRS created worktrees with a bare `git worktree add`, which checks out TRACKED
# files only. The builder lanes follow that with the SHARE_LINKS symlink pass — the gitignored
# build/import caches (`node_modules`, `.venv`, `target`, `.godot`) a checkout needs to run anything.
# Adoption skipped it, so every adopted PR reached the gate with a tree whose suite could not import
# a thing: 12/12 health probes red, `health_codeerror`, indistinguishable from the branch breaking
# everything (measured in emberglen-godot, where lane worktrees carry a 34-45MB `.godot/` cache and
# every adopted one carried none). The autofix rails then bounced builders at phantom bugs.
#
# Asserts, in three parts:
#
#   A. LANE REGRESSION (real git, real new-feature.sh — the surface the extraction moved out of):
#      A1 a benign SHARE_LINK is still symlinked, and the link RESOLVES TO THE MAIN CHECKOUT's dir.
#      A2 the HERD-87 secrets guard still refuses `.herd/secrets`, loudly, and stays fail-soft — the
#         benign share alongside it is still provisioned and the worktree is still built.
#      A3 empty SHARE_LINKS still yields a pure code-only worktree, exit 0.
#
#   B. ADOPTION (agent-watch.sh in lib mode, stubbed git):
#      B1 SHARE_LINKS set → the adopted worktree GETS the symlinks (targets asserted), and the scan
#         journals `adopt_prepared … links=1`, with no unprepared ledger row.
#      B2 SHARE_LINKS empty → `adopt_unprepared` is journaled with a reason, and a ledger row is
#         written for the adopted dir.
#      B3 a configured SHARE_LINK that does not exist in the main checkout is also `adopt_unprepared`
#         (nothing was actually linked — reporting "prepared" there would be the lie).
#      B4 preparation is never fatal: the PR is still adopted (`pr_adopted`, ledger row) either way.
#
#   C. THE HEALTH-ROW QUALIFIER — the honesty rail that makes B2/B3 worth journaling:
#      C1 `_health_qualify_unprepared` is byte-identical passthrough for a worktree with no row.
#      C2 it appends the unprepared marker for an ADOPTED worktree that has one (resolvable by dir or
#         by slug) — and never for a PR the adopt leg did not adopt, so a stale row can never paint a
#         later LANE worktree born at the same path as a cache artifact.
#      C3 WIRED: `_handle_health_codeerror` itself paints the marker on the needs-you row (a pure-helper
#         assertion alone would pass even if nothing called it — the guards-are-blind failure shape).
#      C4 the marker clears once a later prep for that dir succeeds.
#
# Part A uses REAL git (a throwaway repo + stubbed herdr/claude, network-free). Part B/C source
# agent-watch.sh in lib mode with a scripted `git` stub, mirroring tests/test-adopt-remote-prs.sh.
# Run:  bash tests/test-adopt-worktree-prep.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NEWFEAT="$HERE/../scripts/herd/new-feature.sh"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v git >/dev/null 2>&1 || fail "git required to run this test"
[ -f "$NEWFEAT" ] || fail "new-feature.sh not found at $NEWFEAT"
[ -f "$WATCH" ]   || fail "agent-watch.sh not found at $WATCH"

CACHE_MARKER="SENTINEL_BUILD_CACHE_do_not_lose"
SECRET_MARKER="SENTINEL_LINEAR_API_KEY_do_not_leak"

# ══ PART A — LANE REGRESSION: the extracted pass behaves exactly as the inline one did ═════════════
# Deliberately BEFORE any git stub goes on PATH: new-feature.sh drives real `git worktree add`.

BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr";  chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

REPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
mkdir -p "$REPO/.herd"
printf 'SCRIBE_BACKEND=file\n'                     > "$REPO/.herd/config"
printf '.herd/secrets\nnode_modules/\n'            > "$REPO/.gitignore"
git -C "$REPO" -c user.email=t@t -c user.name=t add .herd/config .gitignore
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null
# Both land AFTER the commit (both gitignored): main-checkout only, never in the tree a worktree
# checks out. `node_modules` models the build cache; `.herd/secrets` is the HERD-87 vector.
printf 'LINEAR_API_KEY=%s\n' "$SECRET_MARKER" > "$REPO/.herd/secrets"
mkdir -p "$REPO/node_modules"; printf '%s\n' "$CACHE_MARKER" > "$REPO/node_modules/marker.txt"

export HOME="$T"                  # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit"
export HERD_SKIP_PREFLIGHT=1
LANE_TREES="$T/lane-trees"
LANE_CFG="$T/lane-config"

lane_cfg() {  # lane_cfg <SHARE_LINKS value>
  {
    printf 'PROJECT_ROOT="%s"\n'  "$REPO"
    printf 'WORKTREES_DIR="%s"\n' "$LANE_TREES"
    printf 'DEFAULT_BRANCH="origin/main"\n'
    printf 'WORKSPACE_NAME="herdkit"\n'
    printf 'APP_PREVIEW_CMD=""\n'
    printf 'SHARE_LINKS="%s"\n' "$1"
  } > "$LANE_CFG"
}
lane_worktree() {  # lane_worktree <slug> — run new-feature.sh; echo the worktree dir
  local slug="$1"
  HERD_CONFIG_FILE="$LANE_CFG" bash "$NEWFEAT" "$slug" > "$T/$slug.nf.out" 2>&1 \
    || fail "new-feature.sh exited non-zero for '$slug':"$'\n'"$(cat "$T/$slug.nf.out")"
  printf '%s' "$LANE_TREES/$slug"
}

# ── A1. A benign SHARE_LINK is symlinked, and it resolves to the MAIN CHECKOUT's dir ───────────────
lane_cfg "node_modules"
d="$(lane_worktree lane-plain)"
[ -L "$d/node_modules" ] || fail "(A1) lane regression: SHARE_LINK 'node_modules' was not symlinked into $d"
[ "$(readlink "$d/node_modules")" = "$REPO/node_modules" ] \
  || fail "(A1) lane symlink points at '$(readlink "$d/node_modules")', expected '$REPO/node_modules'"
grep -q "$CACHE_MARKER" "$d/node_modules/marker.txt" 2>/dev/null \
  || fail "(A1) the lane worktree cannot read the shared cache through its link"
pass; echo "PASS (A1) lane worktree still gets its SHARE_LINKS symlink, resolved to the main checkout"

# ── A2. HERD-87 secrets guard intact + fail-soft alongside a benign share ──────────────────────────
lane_cfg ".herd/secrets node_modules"
d="$(lane_worktree lane-mixed)"
grep -q "refusing SHARE_LINK" "$T/lane-mixed.nf.out" \
  || fail "(A2) the lane did not announce it refused the .herd/secrets link:"$'\n'"$(cat "$T/lane-mixed.nf.out")"
[ ! -e "$d/.herd/secrets" ] || fail "(A2) $d/.herd/secrets resolves — the secrets link was NOT refused"
if [ -n "$(grep -rIl "$SECRET_MARKER" "$d" 2>/dev/null)" ]; then
  fail "(A2) $SECRET_MARKER is reachable from within the worktree $d — secrets isolation breached"
fi
[ -L "$d/node_modules" ] || fail "(A2) refusing the dangerous link must not block the benign one (fail-soft)"
pass; echo "PASS (A2) lane secrets guard intact and fail-soft: dangerous link refused, benign one provisioned"

# ── A3. Empty SHARE_LINKS → a pure code-only worktree, still a success ─────────────────────────────
lane_cfg ""
d="$(lane_worktree lane-empty)"
[ -d "$d" ] || fail "(A3) empty SHARE_LINKS must still build a worktree"
[ ! -e "$d/node_modules" ] || fail "(A3) empty SHARE_LINKS must link nothing"
pass; echo "PASS (A3) empty SHARE_LINKS still yields a clean code-only lane worktree"

# ══ PART B/C — ADOPTION + the health-row qualifier ═════════════════════════════════════════════════
# From here on `git` is a scripted stub: the adopt leg must never touch the network or a real repo.

export GIT_CALL_LOG="$T/git-calls.log"; : > "$GIT_CALL_LOG"
cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_CALL_LOG" 2>/dev/null || true
if [ "$1" = "-C" ] && [ "$3" = "fetch" ]; then exit 0; fi
if [ "$1" = "-C" ] && [ "$3" = "worktree" ] && [ "$4" = "add" ]; then
  dir="$5"
  # Mirror the real command closely enough for the discovery predicate: a checked-out worktree is a
  # dir carrying a `.git` pointer file. Crucially it brings NO gitignored caches — that is the bug.
  mkdir -p "$dir" 2>/dev/null && printf 'gitdir: %s\n' "$dir/.git-real" > "$dir/.git" 2>/dev/null
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/git"
printf '#!/usr/bin/env bash\necho SENTINEL-NETWORK-LEAK\nexit 0\n' > "$BIN/gh"; chmod +x "$BIN/gh"
# Part A resolved (and bash HASHED) the REAL git. Drop the hash table or every call below would keep
# going to /usr/bin/git and quietly bypass the stub — a silently non-hermetic test.
hash -r 2>/dev/null || true

export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT/.herd"
export WORKSPACE_NAME="adoptpreptest"
export WATCHER_OWNER="me-operator"
export NO_COLOR=1
export JOURNAL_FILE="$T/journal.jsonl"
# The main checkout's shared cache the adopted worktree must end up linked to.
mkdir -p "$PROJECT_ROOT/node_modules"; printf '%s\n' "$CACHE_MARKER" > "$PROJECT_ROOT/node_modules/marker.txt"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in herd_share_links_prepare herd_share_link_exposes_secrets _adopt_prepare_worktree \
          _adopt_unprepared_mark _adopt_unprepared_note _adopt_unprepared_clear \
          _adopt_pr_ever_adopted _health_qualify_unprepared _handle_health_codeerror \
          _adopt_remote_prs_scan; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing agent-watch.sh"
done
pass; echo "PASS (B0) the shared prep helper and the adopt-prep/qualifier functions are all wired"

PRS='[{"number":701,"title":"add gizmo","headRefName":"feat/gizmo","headRefOid":"sha701","isDraft":false}]'
ADOPTED_DIR="$WORKTREES_DIR/gizmo"

reset_state() {
  : > "$GIT_CALL_LOG"
  : > "$JOURNAL_FILE"
  rm -f "$ADOPT_PR_LEDGER" "$ADOPT_FAILED_SEEN_LEDGER" "$ADOPT_SELFHEAL_SEEN_LEDGER" \
        "$ADOPT_MISMATCH_SEEN_LEDGER" "$ADOPT_VERIFY_LEDGER" "$ADOPT_ORPHAN_LEDGER" \
        "$ADOPT_ORPHAN_SEEN_LEDGER" "$ADOPT_UNPREPARED_LEDGER"
  rm -rf "${WORKTREES_DIR:?}"/* 2>/dev/null || true
}

# ── B1. SHARE_LINKS set → the adopted worktree GETS the symlinks + `adopt_prepared links=1` ────────
reset_state
SHARE_LINKS="node_modules" ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "" ""
[ -d "$ADOPTED_DIR" ] || fail "(B1) the adopt leg did not create the worktree: $(cat "$GIT_CALL_LOG")"
[ -L "$ADOPTED_DIR/node_modules" ] \
  || fail "(B1) GH #660: the ADOPTED worktree got no SHARE_LINKS symlink — this is the whole bug"
[ "$(readlink "$ADOPTED_DIR/node_modules")" = "$PROJECT_ROOT/node_modules" ] \
  || fail "(B1) adopted symlink points at '$(readlink "$ADOPTED_DIR/node_modules")', expected '$PROJECT_ROOT/node_modules'"
grep -q "$CACHE_MARKER" "$ADOPTED_DIR/node_modules/marker.txt" 2>/dev/null \
  || fail "(B1) the adopted worktree cannot read the shared cache through its link"
grep -q '"event":"adopt_prepared"' "$JOURNAL_FILE" \
  || fail "(B1) adopt_prepared not journaled: $(cat "$JOURNAL_FILE")"
grep -q '"links":1' "$JOURNAL_FILE" \
  || fail "(B1) adopt_prepared must report links=1: $(cat "$JOURNAL_FILE")"
grep -q '"event":"adopt_unprepared"' "$JOURNAL_FILE" \
  && fail "(B1) a prepared adopt must never journal adopt_unprepared: $(cat "$JOURNAL_FILE")"
[ ! -s "${ADOPT_UNPREPARED_LEDGER:-/dev/null}" ] \
  || fail "(B1) a prepared adopt must leave no unprepared ledger row: $(cat "$ADOPT_UNPREPARED_LEDGER")"
grep -q '"event":"pr_adopted"' "$JOURNAL_FILE" || fail "(B1/B4) the PR must still be adopted"
pass; echo "PASS (B1) an adopted worktree gets the lane's SHARE_LINKS symlinks + adopt_prepared links=1"

# ── B2. Empty SHARE_LINKS → `adopt_unprepared` + a ledger row; the adopt still succeeds ────────────
reset_state
SHARE_LINKS="" ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "" ""
grep -q '"event":"adopt_unprepared"' "$JOURNAL_FILE" \
  || fail "(B2) empty SHARE_LINKS must journal adopt_unprepared: $(cat "$JOURNAL_FILE")"
grep -q '"reason":"SHARE_LINKS is empty' "$JOURNAL_FILE" \
  || fail "(B2) adopt_unprepared must carry the reason: $(cat "$JOURNAL_FILE")"
grep -q '"event":"adopt_prepared"' "$JOURNAL_FILE" \
  && fail "(B2) empty SHARE_LINKS must never claim adopt_prepared: $(cat "$JOURNAL_FILE")"
grep -qF "$ADOPTED_DIR" "$ADOPT_UNPREPARED_LEDGER" 2>/dev/null \
  || fail "(B2) no unprepared ledger row for $ADOPTED_DIR: $(cat "$ADOPT_UNPREPARED_LEDGER" 2>/dev/null)"
# B4: preparation is advisory — the PR is adopted, once-guarded and enqueued for the discovery proof.
grep -q '"event":"pr_adopted"' "$JOURNAL_FILE" \
  || fail "(B4) an unprepared adopt must STILL be adopted: $(cat "$JOURNAL_FILE")"
grep -q -- "$(printf '701\tsha701\tadopted')" "$ADOPT_PR_LEDGER" \
  || fail "(B4) unprepared adopt missing from the success ledger: $(cat "$ADOPT_PR_LEDGER" 2>/dev/null)"
pass; echo "PASS (B2/B4) empty SHARE_LINKS journals adopt_unprepared + a ledger row, and still adopts"

# ── B3. A SHARE_LINK that does not exist in the main checkout is unprepared too, not "prepared 0" ──
reset_state
SHARE_LINKS="no-such-cache" ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "" ""
grep -q '"event":"adopt_unprepared"' "$JOURNAL_FILE" \
  || fail "(B3) an unresolvable SHARE_LINK must journal adopt_unprepared: $(cat "$JOURNAL_FILE")"
grep -q '"event":"adopt_prepared"' "$JOURNAL_FILE" \
  && fail "(B3) nothing was linked — claiming adopt_prepared would be the lie: $(cat "$JOURNAL_FILE")"
pass; echo "PASS (B3) a SHARE_LINK missing from the main checkout is reported unprepared, not prepared"

# ── C1/C2. The qualifier: byte-identical passthrough with no row, marker appended with one ─────────
DETAIL="2 tests failed (app/thing.test.sh)"
reset_state
out="$(_health_qualify_unprepared 701 "$WORKTREES_DIR/never-adopted" "never-adopted" "$DETAIL")"
[ "$out" = "$DETAIL" ] \
  || fail "(C1) a worktree with no unprepared row must pass the detail through byte-identically: '$out'"
pass; echo "PASS (C1) health detail is byte-identical for a worktree with no unprepared row"

SHARE_LINKS="" ADOPT_REMOTE_PRS=on PRS_LOOKUP_OK=1 _adopt_remote_prs_scan "$PRS" "" ""
out="$(_health_qualify_unprepared 701 "$ADOPTED_DIR" "gizmo" "$DETAIL")"
case "$out" in
  "$DETAIL"*"unprepared worktree"*) : ;;
  *) fail "(C2) expected the unprepared marker appended to the detail, got: '$out'" ;;
esac
# Either key resolves the row: the health row knows the dir, console surfaces know the slug.
case "$(_health_qualify_unprepared 701 "" "gizmo" "$DETAIL")" in
  *"unprepared worktree"*) : ;;
  *) fail "(C2) the qualifier must also resolve an unprepared worktree by SLUG" ;;
esac
# …but a PR the adopt leg NEVER adopted is never qualified, even standing on the exact same path/slug.
# That is a merged adopt's worktree reaped and a LANE worktree later born at the same place: a stale
# row must not paint somebody else's honest code red as a cache artifact.
out="$(_health_qualify_unprepared 999 "$ADOPTED_DIR" "gizmo" "$DETAIL")"
[ "$out" = "$DETAIL" ] \
  || fail "(C2) a NEVER-adopted PR must never inherit an unprepared row at the same path: '$out'"
pass; echo "PASS (C2) an unprepared ADOPTED worktree's detail is qualified (by dir or slug); a lane PR's is not"

# ── C3. WIRED: _handle_health_codeerror itself paints the marker (not just the pure helper) ────────
# DRYRUN routes to the no-bounce leg, which paints the honest needs-you row from the SAME detail.
DISPLAY=("row0")
DRYRUN=1 _handle_health_codeerror 701 gizmo sha701 0 "$ADOPTED_DIR" "$DETAIL" \
  || fail "(C3) _handle_health_codeerror returned non-zero"
case "${DISPLAY[0]}" in
  *"unprepared worktree"*) : ;;
  *) fail "(C3) the code-error ROW does not carry the unprepared marker — the qualifier is not wired into the row that reds the PR: '${DISPLAY[0]}'" ;;
esac
# …and a worktree with no row still paints the legacy row, unqualified.
DISPLAY=("row0")
DRYRUN=1 _handle_health_codeerror 702 other sha702 0 "$WORKTREES_DIR/never-adopted" "$DETAIL" \
  || fail "(C3) _handle_health_codeerror returned non-zero for the unmarked worktree"
case "${DISPLAY[0]}" in
  *"unprepared worktree"*) fail "(C3) a NON-adopted worktree's row must stay unqualified: '${DISPLAY[0]}'" ;;
esac
pass; echo "PASS (C3) the health CODE-ERROR row itself carries the marker — and only for an unprepared tree"

# ── C4. The marker CLEARS once a later prep for that dir succeeds ──────────────────────────────────
grep -qF "$ADOPTED_DIR" "$ADOPT_UNPREPARED_LEDGER" 2>/dev/null || fail "(C4) fixture: expected a standing row"
SHARE_LINKS="node_modules" _adopt_prepare_worktree 701 sha701 feat/gizmo gizmo "$ADOPTED_DIR"
[ -L "$ADOPTED_DIR/node_modules" ] || fail "(C4) the re-prep did not provision the link"
grep -qF "$ADOPTED_DIR" "$ADOPT_UNPREPARED_LEDGER" 2>/dev/null \
  && fail "(C4) a successful prep must clear the stale unprepared row: $(cat "$ADOPT_UNPREPARED_LEDGER")"
out="$(_health_qualify_unprepared 701 "$ADOPTED_DIR" "gizmo" "$DETAIL")"
[ "$out" = "$DETAIL" ] || fail "(C4) the qualifier must stop firing once the worktree is prepared: '$out'"
pass; echo "PASS (C4) a successful later prep clears the marker, so the qualifier never outlives the cause"

echo "ALL PASS ($PASS groups) — adopted worktrees are prepared like lane worktrees (HERD-535 / GH #660)"
