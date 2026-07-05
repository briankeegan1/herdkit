#!/usr/bin/env bash
# test-scribe-intent-dispatch.sh — hermetic tests for the scribe INTENT DISPATCH table (gh #139,
# second half). Before this work the drainer's only non-file verb was `add-item` → issueCreate, so a
# "mark HERD-22 done" or the watcher's "Reconcile: PR #N merged …" request was junk-filed as a brand
# new issue. The fix gives scribe-step.sh three intent verbs and routes each request text to exactly
# one of them:
#     add-item      → _backend_add_item        (a genuinely NEW item)
#     update-state  → _backend_update_state     (transition an EXISTING item's state)
#     skip          → nothing filed             (unmappable request; loud line in the report)
#
# This test drives scribe-step.sh against a FAKE backend that records which _backend_* op fired (and
# with what args) per request, so it asserts the DISPATCH TABLE directly — no network, no real
# backend, no repo writes outside a temp dir. The fake backend is reached via SCRIBE_BACKEND_DIR (the
# test seam), so nothing is written into the real scripts/herd/backends. Run:
#     bash tests/test-scribe-intent-dispatch.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STEP="$HERE/../scripts/herd/scribe-step.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── Stub herdr on PATH so no real notification/tab is ever touched ────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── A temp git repo + a .herd/config the step script sources ──────────────────
REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
TREES="$T/trees"; Q="$TREES/backlog-queue"; INBOX="$TREES/.scribe-reports"; mkdir -p "$Q"

# ── A FAKE backend that logs which op fired + its args to $DISPATCH ────────────
# Only the ops the intent verbs call are needed. Each records "<OP>\t<arg1>\t<arg2>" so the test can
# assert the dispatch decision, then sets _BACKEND_RESULT so scribe-step's report tail runs.
FAKEDIR="$T/fakebackends"; mkdir -p "$FAKEDIR"
DISPATCH="$T/dispatch.log"
cat > "$FAKEDIR/fake.sh" <<FAKEEOF
#!/usr/bin/env bash
_backend_add_item() { printf 'ADD\t%s\n' "\$2" >> "$DISPATCH"; _BACKEND_RESULT="DONE"; }
_backend_update_state() { printf 'UPDATE\t%s\t%s\n' "\$1" "\$2" >> "$DISPATCH"; _BACKEND_RESULT="DONE"; }
_backend_mark_shipped() { :; }
_backend_list_open() { :; }
_backend_item_state() { ITEM_STATE="open"; }
FAKEEOF

CFG="$T/config"
cat > "$CFG" <<CFGEOF
HERD_VERSION=1
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="dispatchtest"
HERD_REMOTE="origin"
HERD_BRANCH_NAME="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="fake"
CFGEOF

# step <args...> — run scribe-step.sh from inside $REPO, pointed at the fake backend dir. Captures
# combined output in $OUT and the exit code in $RC (never aborts the harness).
step() {
  set +e
  OUT="$( cd "$REPO" && HERD_CONFIG_FILE="$CFG" SCRIBE_BACKEND_DIR="$FAKEDIR" SCRIBE_POLL=0 \
            bash "$STEP" "$@" 2>&1 )"
  RC=$?
  set -e
}

# mkreq <name> — drop a claimed (.mine) request file whose body is the given text; echoes its path.
mkreq() { local p="$Q/$1.req.mine"; printf '%s\n' "$2" > "$p"; printf '%s' "$p"; }

: > "$DISPATCH"

# ══ 1. An ADD request routes to _backend_add_item (a new item), never update-state ═══════════════
p="$(mkreq 100 "Add a dark-mode toggle to the settings pane")"
step add-item "$p" "Add a dark-mode toggle to the settings pane"
[ "$RC" -eq 0 ]                                              || fail "1: add-item exited $RC ($OUT)"
grep -qE $'^ADD\t' "$DISPATCH"                               || fail "1: add-item did not fire _backend_add_item ($(cat "$DISPATCH"))"
grep -q "Add a dark-mode toggle" "$DISPATCH"                 || fail "1: add-item did not pass the request text"
grep -qE $'^UPDATE\t' "$DISPATCH"                            && fail "1: add-item wrongly fired _backend_update_state"
[ ! -e "$p" ]                                                || fail "1: claimed file not cleaned up"
ok

# ══ 2. A "mark done" request routes to _backend_update_state with (ref, state) — NOT add-item ════
# This is the exact junk-issue case: pre-fix it became issueCreate; now it must transition HERD-22.
: > "$DISPATCH"
p="$(mkreq 200 "Mark HERD-22 as Done (merged as PR #145)")"
step update-state "$p" "HERD-22" "done"
[ "$RC" -eq 0 ]                                              || fail "2: update-state exited $RC ($OUT)"
grep -qE $'^UPDATE\tHERD-22\tdone$' "$DISPATCH"              || fail "2: update-state did not dispatch (HERD-22, done) ($(cat "$DISPATCH"))"
grep -qE $'^ADD\t' "$DISPATCH"                               && fail "2: a state change was wrongly filed as a NEW item (the #139 bug)"
[ ! -e "$p" ]                                                || fail "2: claimed file not cleaned up"
ok

# ══ 3. The watcher's reconcile request also routes to update-state, never a new issue ════════════
: > "$DISPATCH"
p="$(mkreq 300 "Reconcile: PR #145 merged — find the backlog item and mark it done")"
step update-state "$p" "HERD-23" "done"
grep -qE $'^UPDATE\tHERD-23\tdone$' "$DISPATCH"              || fail "3: reconcile did not dispatch update-state (HERD-23, done) ($(cat "$DISPATCH"))"
grep -qE $'^ADD\t' "$DISPATCH"                               && fail "3: a reconcile request was junk-filed as a new issue"
ok

# ══ 4. in-progress + canceled states pass through verbatim ═══════════════════════════════════════
: > "$DISPATCH"
p="$(mkreq 400 "Start HERD-24")";   step update-state "$p" "HERD-24" "in-progress"
p="$(mkreq 401 "Drop HERD-25")";    step update-state "$p" "HERD-25" "canceled"
grep -qE $'^UPDATE\tHERD-24\tin-progress$' "$DISPATCH"       || fail "4: in-progress state not dispatched ($(cat "$DISPATCH"))"
grep -qE $'^UPDATE\tHERD-25\tcanceled$'    "$DISPATCH"       || fail "4: canceled state not dispatched"
ok

# ══ 5. An UNMAPPABLE request → skip: NOTHING is filed and a loud line lands in the scribe report ══
: > "$DISPATCH"; : > "$INBOX" 2>/dev/null || true
p="$(mkreq 500 "please refactor the whole scheduler sometime, thanks")"
step skip "$p" "not a backlog add or state change — free-form aside"
[ "$RC" -eq 0 ]                                              || fail "5: skip exited $RC ($OUT)"
[ ! -s "$DISPATCH" ]                                         || fail "5: skip filed something to the backend ($(cat "$DISPATCH"))"
grep -qi 'SKIPPED (not filed)' "$INBOX"                      || fail "5: skip did not record a loud SKIP line in the scribe report ($(cat "$INBOX" 2>/dev/null))"
printf '%s\n' "$OUT" | grep -qi 'SKIPPED (not filed)'        || fail "5: skip did not warn loudly on stderr ($OUT)"
[ ! -e "$p" ]                                                || fail "5: claimed file not cleaned up after skip"
ok

# ══ 6. update-state under the FILE backend is a guarded SKIP (files nothing) — the file backend
#       records state by editing BACKLOG.md, so a dispatch here means a misrouted stale drainer ════
: > "$DISPATCH"; : > "$INBOX" 2>/dev/null || true
sed 's/SCRIBE_BACKEND="fake"/SCRIBE_BACKEND="file"/' "$CFG" > "$CFG.file"
p="$(mkreq 600 "Mark HERD-30 done")"
set +e
OUT="$( cd "$REPO" && HERD_CONFIG_FILE="$CFG.file" SCRIBE_BACKEND_DIR="$HERE/../scripts/herd/backends" \
          SCRIBE_POLL=0 bash "$STEP" update-state "$p" "HERD-30" "done" 2>&1 )"
RC=$?
set -e
[ "$RC" -eq 0 ]                                              || fail "6: file-backend update-state exited $RC ($OUT)"
printf '%s\n' "$OUT" | grep -q 'issue #139'                 || fail "6: file-backend update-state did not warn about the misroute ($OUT)"
grep -qi 'SKIPPED (not filed)' "$INBOX"                      || fail "6: file-backend update-state did not record a SKIP ($(cat "$INBOX" 2>/dev/null))"
[ ! -e "$p" ]                                                || fail "6: claimed file not cleaned up"
ok

# ══ 7. usage line documents the new verbs ════════════════════════════════════════════════════════
step bogus-verb
printf '%s\n' "$OUT" | grep -q 'update-state' || fail "7: usage does not mention update-state ($OUT)"
printf '%s\n' "$OUT" | grep -q 'skip'         || fail "7: usage does not mention skip ($OUT)"
ok

echo "ALL PASS ($pass checks)"
