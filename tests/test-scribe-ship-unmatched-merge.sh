#!/usr/bin/env bash
# test-scribe-ship-unmatched-merge.sh — hermetic tests for HERD-490's create-as-DONE auto-ship.
#
# The sweep's retroactive-linkage leg (sweep.sh's sweep_leg_links) files a ship-record for a merged
# PR whose tracker ref resolves to nothing. That work already shipped — it is not queued — so a plain
# Add would leave the new item sitting in the backend's default new-issue state (Backlog/Triage/
# unstarted) forever: a phantom row that never reflects reality. The leg's request body carries an
# ANCHORED "UNMATCHED-MERGE: <pr-url>" marker (mirroring HERD-183's sequencing-clause marker);
# scribe-step.sh's add-item path parses it and, on a successful create, immediately calls
# _backend_mark_shipped so the item is marked done in the SAME breath it is filed — and journals ONE
# tracker_create_unmatched_merge event (component=sweep reason=unmatched-merge) so the create is
# always auditable.
#
# The test drives scribe-step.sh against a FAKE backend and asserts the auto-ship decision directly —
# no network, no real backend, no repo writes outside a temp dir. Run:
#     bash tests/test-scribe-ship-unmatched-merge.sh
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
JOURNAL="$T/journal.jsonl"

# ── A FAKE backend whose add surfaces a stable identifier + a mark_shipped that records its call ──
FAKEDIR="$T/fakebackends"; mkdir -p "$FAKEDIR"
DISPATCH="$T/dispatch.log"
SHIPLOG="$T/ship.log"
cat > "$FAKEDIR/fake.sh" <<FAKEEOF
#!/usr/bin/env bash
_backend_add_item() { printf 'ADD\t%s\n' "\$2" >> "$DISPATCH"; printf 'HERD-900\n'; _BACKEND_RESULT="DONE"; }
_backend_mark_shipped() { printf 'SHIP\t%s\t%s\t%s\n' "\$1" "\$2" "\${HERD_COMPONENT:-}" >> "$SHIPLOG"; _BACKEND_RESULT="DONE"; }
_backend_list_open() { :; }
_backend_item_state() { ITEM_STATE="open"; }
FAKEEOF

CFG="$T/config"
cat > "$CFG" <<CFGEOF
HERD_VERSION=1
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="shiptest"
HERD_REMOTE="origin"
HERD_BRANCH_NAME="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="fake"
CFGEOF

# step add-item <path> <text> — run scribe-step from inside $REPO against the given backend dir.
step() {
  local bdir="$1"; shift
  set +e
  OUT="$( cd "$REPO" && HERD_CONFIG_FILE="$CFG" SCRIBE_BACKEND_DIR="$bdir" SCRIBE_POLL=0 \
            JOURNAL_FILE="$JOURNAL" bash "$STEP" "$@" 2>&1 )"
  RC=$?
  set -e
}
mkreq() { local p="$Q/$1.req.mine"; printf '%s\n' "$2" > "$p"; printf '%s' "$p"; }

# ══ 1. An Add WITH the UNMATCHED-MERGE marker auto-ships the NEW item ═════════════════════════════
: > "$DISPATCH"; : > "$SHIPLOG"; : > "$JOURNAL"
BODY=$'Relink merged PR #42 — its tracker item is missing\n\nsome text\n\nUNMATCHED-MERGE: https://github.com/x/y/pull/42\n'
p="$(mkreq 100 "$BODY")"
step "$FAKEDIR" add-item "$p" "$BODY"
[ "$RC" -eq 0 ]                                    || fail "1: add-item exited $RC ($OUT)"
grep -qE $'^ADD\t' "$DISPATCH"                     || fail "1: the item was not filed ($(cat "$DISPATCH"))"
grep -qE $'^SHIP\tHERD-900\thttps://github.com/x/y/pull/42\tsweep$' "$SHIPLOG" \
  || fail "1: mark_shipped was not called with (new-id, pr-url, component=sweep) ($(cat "$SHIPLOG"))"
grep -q '"event":"tracker_create_unmatched_merge"' "$JOURNAL" || fail "1: no tracker_create_unmatched_merge journal event"
grep -q '"ref":"HERD-900"' "$JOURNAL"       || fail "1: journal event missing the new item's ref"
grep -q '"component":"sweep"' "$JOURNAL"    || fail "1: journal event not attributed component=sweep"
grep -q '"reason":"unmatched-merge"' "$JOURNAL" || fail "1: journal event missing reason=unmatched-merge"
grep -q '"result":"DONE"' "$JOURNAL"        || fail "1: journal event did not record a confirmed DONE"
grep -q 'HERD-900 filed for an already-merged PR and marked done immediately' <<< "$OUT" \
  || fail "1: no auto-ship confirmation in output ($OUT)"
[ ! -e "$p" ]                                      || fail "1: claimed file not cleaned up"
ok

# ══ 2. An Add with NO marker never auto-ships (byte-identical add path) ═══════════════════════════
: > "$DISPATCH"; : > "$SHIPLOG"; : > "$JOURNAL"
p="$(mkreq 200 "Add a dark-mode toggle to the settings pane")"
step "$FAKEDIR" add-item "$p" "Add a dark-mode toggle to the settings pane"
[ "$RC" -eq 0 ]                                    || fail "2: add-item exited $RC ($OUT)"
grep -qE $'^ADD\t' "$DISPATCH"                     || fail "2: the item was not filed"
[ ! -s "$SHIPLOG" ]                                || fail "2: a marker-free Add wrongly auto-shipped ($(cat "$SHIPLOG"))"
if grep -q 'tracker_create_unmatched_merge' "$JOURNAL" 2>/dev/null; then
  fail "2: journaled an unmatched-merge event with no marker present"
fi
ok

# ══ 3. Near-miss prose (mentions "merged" but not the anchored marker) does NOT auto-ship ═════════
: > "$DISPATCH"; : > "$SHIPLOG"; : > "$JOURNAL"
p="$(mkreq 300 "This PR was already merged upstream, just filing a note about it.")"
step "$FAKEDIR" add-item "$p" "This PR was already merged upstream, just filing a note about it."
[ ! -s "$SHIPLOG" ] || fail "3: fuzzy 'merged' prose wrongly triggered auto-ship ($(cat "$SHIPLOG"))"
ok

# ══ 4. FAIL-SOFT: a backend with NO _backend_mark_shipped op skips, never hard-fails ══════════════
NOSHIPDIR="$T/noshipbackends"; mkdir -p "$NOSHIPDIR"
cat > "$NOSHIPDIR/fake.sh" <<'NOSHIPEOF'
#!/usr/bin/env bash
_backend_add_item() { printf 'HERD-901\n'; _BACKEND_RESULT="DONE"; }
_backend_list_open() { :; }
_backend_item_state() { ITEM_STATE="open"; }
NOSHIPEOF
: > "$JOURNAL"
p="$(mkreq 400 "UNMATCHED-MERGE: https://github.com/x/y/pull/43")"
step "$NOSHIPDIR" add-item "$p" "UNMATCHED-MERGE: https://github.com/x/y/pull/43"
[ "$RC" -eq 0 ]                                    || fail "4: no-mark-shipped backend hard-failed ($OUT)"
grep -q 'defines no _backend_mark_shipped op' <<< "$OUT" || fail "4: no soft note about the missing op ($OUT)"
grep -q '"result":"NOCHANGE"' "$JOURNAL"           || fail "4: journal did not record NOCHANGE when the op is absent"
[ ! -e "$p" ]                                      || fail "4: claimed file not cleaned up despite the soft skip"
ok

# ══ 5. FAIL-SOFT: the backend surfaces NO id for the new item — soft note, still filed ════════════
NOIDDIR="$T/noidbackends"; mkdir -p "$NOIDDIR"
cat > "$NOIDDIR/fake.sh" <<'NOIDEOF'
#!/usr/bin/env bash
_backend_add_item() { _BACKEND_RESULT="DONE"; }   # DONE but no id on stdout
_backend_mark_shipped() { :; }
_backend_list_open() { :; }
_backend_item_state() { ITEM_STATE="open"; }
NOIDEOF
: > "$JOURNAL"
p="$(mkreq 500 "UNMATCHED-MERGE: https://github.com/x/y/pull/44")"
step "$NOIDDIR" add-item "$p" "UNMATCHED-MERGE: https://github.com/x/y/pull/44"
[ "$RC" -eq 0 ]                                    || fail "5: no-id add-item hard-failed ($OUT)"
grep -q 'surfaced no id' <<< "$OUT"                || fail "5: no soft note about the missing id ($OUT)"
grep -q '"result":"NOCHANGE"' "$JOURNAL"           || fail "5: journal did not record NOCHANGE when no id surfaced"
ok

# ══ 6. A FAILED create (add-result != DONE) never attempts an auto-ship or a journal write ════════
FAILDIR="$T/failbackends"; mkdir -p "$FAILDIR"
cat > "$FAILDIR/fake.sh" <<'FAILEOF'
#!/usr/bin/env bash
_backend_add_item() { _BACKEND_RESULT="NOCHANGE"; _BACKEND_ERROR="cap"; }
_backend_mark_shipped() { echo "MUST NOT BE CALLED" >&2; exit 1; }
_backend_list_open() { :; }
_backend_item_state() { ITEM_STATE="open"; }
FAILEOF
: > "$JOURNAL"
p="$(mkreq 600 "UNMATCHED-MERGE: https://github.com/x/y/pull/45")"
step "$FAILDIR" add-item "$p" "UNMATCHED-MERGE: https://github.com/x/y/pull/45"
if grep -q 'tracker_create_unmatched_merge' "$JOURNAL" 2>/dev/null; then
  fail "6: a failed create still journaled an unmatched-merge event"
fi
if grep -q 'MUST NOT BE CALLED' <<< "$OUT"; then
  fail "6: mark_shipped ran despite the create having failed"
fi
ok

# ══ 7. A create that SUCCEEDS but whose auto-ship FAILS must still be reported as a successful
#       create — the ship outcome must never clobber the shared _BACKEND_RESULT the caller uses to
#       judge the CREATE. Before the fix, _scribe_auto_ship's own _BACKEND_RESULT="" + mark_shipped
#       overwrote the global the add-item case reads right after, so a failed ship would wrongly
#       divert an ALREADY-SUCCESSFUL create into the durable retry queue (and eventually re-file a
#       DUPLICATE item next drain — exactly the phantom this item exists to prevent).
FLAKYDIR="$T/flakybackends"; mkdir -p "$FLAKYDIR"
cat > "$FLAKYDIR/fake.sh" <<'FLAKYEOF'
#!/usr/bin/env bash
_backend_add_item() { printf 'HERD-902\n'; _BACKEND_RESULT="DONE"; }
_backend_mark_shipped() { _BACKEND_RESULT="NOCHANGE"; }   # the ship itself fails
_backend_list_open() { :; }
_backend_item_state() { ITEM_STATE="open"; }
FLAKYEOF
: > "$JOURNAL"
p="$(mkreq 700 "UNMATCHED-MERGE: https://github.com/x/y/pull/46")"
step "$FLAKYDIR" add-item "$p" "UNMATCHED-MERGE: https://github.com/x/y/pull/46"
[ "$RC" -eq 0 ]                                    || fail "7: add-item exited $RC ($OUT)"
grep -q '^DONE ' <<< "$OUT"                        || fail "7: a successful create with a failed ship was not reported DONE ($OUT)"
grep -q '"result":"NOCHANGE"' "$JOURNAL"           || fail "7: journal did not record the ship's own NOCHANGE result"
[ ! -e "$p" ]                                      || fail "7: claimed file left behind — the successful create was wrongly treated as unfiled"
# Scoped to THIS request's own pr (not global emptiness) — an earlier test section's genuinely
# failed create is expected to have its own, unrelated retry-queue entry sitting in $TREES.
if [ -d "$TREES/.create-retry" ] && grep -rl 'pull/46' "$TREES/.create-retry" >/dev/null 2>&1; then
  fail "7: a successful create was diverted into the durable retry queue because the ship failed"
fi
ok

echo "ALL PASS ($pass checks)"
