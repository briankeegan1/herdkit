#!/usr/bin/env bash
# test-scribe-amend.sh — hermetic tests for the first-class AMEND verb (HERD-128). An operator
# directive that only ADDS a clarification/comment to an EXISTING backlog item used to have no
# first-class path — it had to be attached via a raw, unjournaled backend script. AMEND closes that
# gap: the drainer classifies "append this note to item <ref>" and routes to
#     scribe-step.sh amend <claimed_path> <ref> <note>
# which:
#   • file backend    → appends an indented, dated "↳ note" line UNDER the item's BACKLOG.md entry
#   • github/linear   → posts an issue comment (never touching state or title)
#   • other backends  → fail soft (a soft note; nothing posted)
# and, on every path, journals a tracker_write requested=amend component=scribe (HERD-85). An
# ambiguous or unmatched <ref> is a LOUD SKIP (skip-over-guess) — NOTHING is posted.
#
# The github/linear adapters are exercised against STUBBED network (a fake `gh` on PATH; an
# overridden `_linear_gql`) so the comment mutation and the journal line are asserted with no real
# API. Run:  bash tests/test-scribe-amend.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
STEP="$ROOT/scripts/herd/scribe-step.sh"
BACKENDS="$ROOT/scripts/herd/backends"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── Stub herdr on PATH so no real notification/tab is ever touched ────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── A temp git repo (the file backend commits into it) ────────────────────────
REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
TREES="$T/trees"; Q="$TREES/backlog-queue"; INBOX="$TREES/.scribe-reports"; mkdir -p "$Q"
JF="$T/journal.jsonl"

# A backlog with three DISTINCT items in "## Now" so we can prove a note lands under the RIGHT one.
cat > "$REPO/BACKLOG.md" <<'MD'
# Backlog

## Now
- 🔜 HERD-10 Add a dark-mode toggle to settings
- 🚧 HERD-11 Refactor the scheduler core
- ✅ HERD-12 Fix the login redirect bug

## Recently shipped
MD
git -C "$REPO" add BACKLOG.md; git -C "$REPO" commit -q -m init

CFG="$T/config"
cat > "$CFG" <<CFGEOF
HERD_VERSION=1
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="amendtest"
HERD_REMOTE="origin"
HERD_BRANCH_NAME="main"
BACKLOG_FILE="BACKLOG.md"
CFGEOF
# NOTE: SCRIBE_BACKEND is deliberately NOT pinned in the config — .herd/config is shell-sourced and a
# hard assignment would clobber the per-step env override. Each step() passes SCRIBE_BACKEND via env,
# which herd-config's ': "${SCRIBE_BACKEND:="file"}"' default then preserves.

# step <backend-dir> <backend> <args...> — run scribe-step.sh from inside $REPO. Captures combined
# output in $OUT and the exit code in $RC. Journals to $JF (the JOURNAL_FILE seam).
step() {
  local bdir="$1" backend="$2"; shift 2
  set +e
  OUT="$( cd "$REPO" && HERD_CONFIG_FILE="$CFG" SCRIBE_BACKEND_DIR="$bdir" SCRIBE_BACKEND="$backend" \
            JOURNAL_FILE="$JF" SCRIBE_POLL=0 bash "$STEP" "$@" 2>&1 )"
  RC=$?
  set -e
}
# mkreq <name> <text> — drop a claimed (.mine) request file; echoes its path.
mkreq() { local p="$Q/$1.req.mine"; printf '%s\n' "$2" > "$p"; printf '%s' "$p"; }

# ══ 1. FILE backend: the ↳ note lands under the RIGHT item only, dated + indented, state/title kept ═
: > "$JF"
p="$(mkreq 100 "clarify HERD-11")"
step "$BACKENDS" file amend "$p" "HERD-11" "blocked on the new API landing first"
[ "$RC" -eq 0 ]                                             || fail "1: file amend exited $RC ($OUT)"
BL="$REPO/BACKLOG.md"
# Exactly one ↳ note exists, and it is indented + dated.
[ "$(grep -c '↳' "$BL")" -eq 1 ]                            || fail "1: expected exactly one ↳ note ($(grep -n '↳' "$BL"))"
grep -qE '^  ↳ \[[0-9]{4}-[0-9]{2}-[0-9]{2}\] blocked on the new API' "$BL" || fail "1: ↳ note is not indented+dated ($(grep -n '↳' "$BL"))"
# It sits DIRECTLY under HERD-11 (item line + 1), not under HERD-10 or HERD-12.
item_ln="$(grep -n 'HERD-11 Refactor the scheduler core' "$BL" | head -1 | cut -d: -f1)"
note_ln="$(grep -n 'blocked on the new API' "$BL" | head -1 | cut -d: -f1)"
[ -n "$item_ln" ] && [ "$note_ln" -eq "$((item_ln + 1))" ] || fail "1: ↳ note not directly under HERD-11 (item=$item_ln note=$note_ln)"
# State + title of HERD-11 are UNCHANGED (still 🚧, same text), and the neighbours are untouched.
grep -qE '^- 🚧 HERD-11 Refactor the scheduler core$' "$BL" || fail "1: HERD-11 line changed (state/title must be untouched)"
grep -qE '^- 🔜 HERD-10 Add a dark-mode toggle to settings$' "$BL" || fail "1: HERD-10 was disturbed"
grep -qE '^- ✅ HERD-12 Fix the login redirect bug$' "$BL"  || fail "1: HERD-12 was disturbed"
# It journaled a tracker_write requested=amend component=scribe backend=file (HERD-85).
grep -q '"event":"tracker_write"' "$JF"                     || fail "1: no tracker_write journal line ($(cat "$JF"))"
grep -q '"requested":"amend"' "$JF"                         || fail "1: journal line missing requested=amend ($(cat "$JF"))"
grep -q '"component":"scribe"' "$JF"                        || fail "1: journal line missing component=scribe ($(cat "$JF"))"
grep -q '"backend":"file"' "$JF"                            || fail "1: journal line missing backend=file ($(cat "$JF"))"
[ ! -e "$p" ]                                               || fail "1: claimed file not cleaned up"
ok

# ══ 2. FILE backend, AMBIGUOUS ref (two items share a phrase → >1 match) → SKIP, nothing written ══
cat > "$REPO/BACKLOG.md" <<'MD'
# Backlog

## Now
- 🔜 HERD-30 Improve the cache layer
- 🔜 HERD-31 Improve the cache eviction policy

## Recently shipped
MD
git -C "$REPO" add BACKLOG.md; git -C "$REPO" commit -q -m two-cache
before="$(cat "$REPO/BACKLOG.md")"
: > "$JF"; : > "$INBOX" 2>/dev/null || true
p="$(mkreq 210 "note on cache")"
step "$BACKENDS" file amend "$p" "Improve the cache" "this note must be skipped"
[ "$RC" -eq 0 ]                                             || fail "2: exited $RC ($OUT)"
[ "$(cat "$REPO/BACKLOG.md")" = "$before" ]                || fail "2: ambiguous amend wrote to BACKLOG.md"
printf '%s\n' "$OUT" | grep -qi 'more than one'            || fail "2: no loud ambiguity reason on stderr ($OUT)"
grep -qi 'SKIPPED' "$INBOX"                                || fail "2: no SKIP line in the scribe report"
grep -q '"requested":"amend"' "$JF"                        || fail "2: ambiguous amend still journals the attempt ($(cat "$JF"))"
[ ! -e "$p" ]                                              || fail "2: claimed file not cleaned up"
ok

# ══ 3. FILE backend, ref matches NOTHING → SKIP, nothing written, loud reason ═════════════════════
before="$(cat "$REPO/BACKLOG.md")"
p="$(mkreq 300 "note on a ghost")"
step "$BACKENDS" file amend "$p" "HERD-999" "note for a nonexistent item"
[ "$RC" -eq 0 ]                                            || fail "3: exited $RC ($OUT)"
[ "$(cat "$REPO/BACKLOG.md")" = "$before" ]               || fail "3: unmatched amend wrote to BACKLOG.md"
printf '%s\n' "$OUT" | grep -qi 'no backlog item matching' || fail "3: no loud not-found reason ($OUT)"
ok

# ══ 4. GITHUB adapter (stubbed gh): posts an issue comment + journals amend, never a state change ══
GH_CALLS="$T/gh.calls"; : > "$GH_CALLS"
cat > "$BIN/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALLS"
exit 0
GHEOF
chmod +x "$BIN/gh"
: > "$JF"
(
  set -e
  export WORKTREES_DIR="$TREES" JOURNAL_FILE="$JF" HERD_COMPONENT="scribe" HERD_REPO=""
  . "$ROOT/scripts/herd/journal.sh"
  . "$BACKENDS/github.sh"
  _BACKEND_RESULT=""
  _backend_amend "42" "clarify: needs the new API first"
  [ "$_BACKEND_RESULT" = "DONE" ] || { echo "github amend result=$_BACKEND_RESULT" >&2; exit 1; }
) || fail "4: github _backend_amend did not report DONE"
grep -q 'issue comment 42' "$GH_CALLS"                     || fail "4: github amend did not call 'gh issue comment 42' ($(cat "$GH_CALLS"))"
grep -q 'clarify: needs the new API first' "$GH_CALLS"     || fail "4: github amend did not pass the note body ($(cat "$GH_CALLS"))"
grep -qE 'issue (close|edit|reopen)' "$GH_CALLS"           && fail "4: github amend touched issue STATE (must only comment) ($(cat "$GH_CALLS"))"
grep -q '"requested":"amend"' "$JF"                        || fail "4: github amend did not journal requested=amend ($(cat "$JF"))"
grep -q '"component":"scribe"' "$JF"                       || fail "4: github amend journal missing component=scribe"
grep -q '"backend":"github"' "$JF"                         || fail "4: github amend journal missing backend=github"
ok

# ══ 5. LINEAR adapter (stubbed _linear_gql): commentCreate mutation + journal, state untouched ════
LIN_CALLS="$T/linear.calls"; : > "$LIN_CALLS"; : > "$JF"
(
  set -e
  export WORKTREES_DIR="$TREES" JOURNAL_FILE="$JF" HERD_COMPONENT="scribe" LINEAR_API_KEY="dummy"
  . "$ROOT/scripts/herd/journal.sh"
  . "$BACKENDS/linear.sh"
  # Override the single HTTP seam: record the mutation payload; resolve to ONE issue; succeed.
  _linear_gql() {
    case "$1" in
      *commentCreate*) printf 'MUT %s\n' "$2" >> "$LIN_CALLS"; echo '{"data":{"commentCreate":{"success":true}}}' ;;
      *issueUpdate*|*issueCreate*) printf 'STATE %s\n' "$1" >> "$LIN_CALLS"; echo '{"data":{}}' ;;
      *) echo '{"data":{"issues":{"nodes":[{"id":"iss_123","identifier":"HERD-5"}]}}}' ;;
    esac
  }
  _BACKEND_RESULT=""
  _backend_amend "HERD-5" "please scope this to just the read path"
  [ "$_BACKEND_RESULT" = "DONE" ] || { echo "linear amend result=$_BACKEND_RESULT" >&2; exit 1; }
) || fail "5: linear _backend_amend did not report DONE"
grep -q '^MUT ' "$LIN_CALLS"                               || fail "5: linear amend did not fire commentCreate ($(cat "$LIN_CALLS"))"
grep -q 'please scope this to just the read path' "$LIN_CALLS" || fail "5: linear amend did not pass the note body ($(cat "$LIN_CALLS"))"
grep -q '"iss_123"' "$LIN_CALLS"                           || fail "5: linear amend commented on the wrong issue id ($(cat "$LIN_CALLS"))"
grep -q '^STATE ' "$LIN_CALLS"                             && fail "5: linear amend fired a STATE mutation (must only comment)"
grep -q '"requested":"amend"' "$JF"                        || fail "5: linear amend did not journal requested=amend ($(cat "$JF"))"
grep -q '"component":"scribe"' "$JF"                       || fail "5: linear amend journal missing component=scribe"
ok

# ══ 5b. LINEAR adapter, NO unique match → SKIP: nothing posted, still journals the attempt ════════
LIN_CALLS="$T/linear2.calls"; : > "$LIN_CALLS"; : > "$JF"
(
  set -e
  export WORKTREES_DIR="$TREES" JOURNAL_FILE="$JF" HERD_COMPONENT="scribe" LINEAR_API_KEY="dummy"
  . "$ROOT/scripts/herd/journal.sh"
  . "$BACKENDS/linear.sh"
  _linear_gql() {
    case "$1" in
      *commentCreate*) printf 'MUT %s\n' "$2" >> "$LIN_CALLS"; echo '{"data":{"commentCreate":{"success":true}}}' ;;
      *) echo '{"data":{"issues":{"nodes":[]}}}' ;;   # resolves to NOTHING
    esac
  }
  _BACKEND_RESULT=""
  _backend_amend "HERD-777" "note that must never post" 2>/dev/null
  [ "$_BACKEND_RESULT" = "NOCHANGE" ] || { echo "expected NOCHANGE, got $_BACKEND_RESULT" >&2; exit 1; }
) || fail "5b: linear amend with no match must report NOCHANGE"
[ ! -s "$LIN_CALLS" ]                                       || fail "5b: linear amend posted despite no unique match ($(cat "$LIN_CALLS"))"
grep -q '"requested":"amend"' "$JF"                        || fail "5b: no-match amend still journals the attempt ($(cat "$JF"))"
ok

# ══ 6. UNSUPPORTED backend (changelog: no amend op) → soft note, nothing posted, SKIP recorded ════
: > "$INBOX" 2>/dev/null || true
before="$(cat "$REPO/BACKLOG.md")"
p="$(mkreq 600 "note for changelog")"
step "$BACKENDS" changelog amend "$p" "HERD-30" "a note the changelog cannot attach"
[ "$RC" -eq 0 ]                                            || fail "6: changelog amend exited $RC ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'has no amend op'         || fail "6: unsupported backend did not print a soft note ($OUT)"
grep -qi 'SKIPPED' "$INBOX"                               || fail "6: unsupported backend did not record a SKIP"
[ "$(cat "$REPO/BACKLOG.md")" = "$before" ]               || fail "6: unsupported backend must not touch BACKLOG.md"
[ ! -e "$p" ]                                             || fail "6: claimed file not cleaned up"
ok

# ══ 7. DISPATCH: scribe-step 'amend' routes to _backend_amend with (ref, note) via a fake backend ═
FAKEDIR="$T/fakebackends"; mkdir -p "$FAKEDIR"
DISPATCH="$T/dispatch.log"; : > "$DISPATCH"
cat > "$FAKEDIR/fake.sh" <<FAKEEOF
#!/usr/bin/env bash
_backend_add_item()   { printf 'ADD\t%s\n' "\$2" >> "$DISPATCH"; _BACKEND_RESULT="DONE"; }
_backend_amend()      { printf 'AMEND\t%s\t%s\n' "\$1" "\$2" >> "$DISPATCH"; _BACKEND_RESULT="DONE"; }
_backend_mark_shipped(){ :; }
_backend_list_open()  { :; }
_backend_item_state() { ITEM_STATE="open"; }
FAKEEOF
p="$(mkreq 700 "append: this ships behind a flag")"
step "$FAKEDIR" fake amend "$p" "HERD-7" "this ships behind a flag"
[ "$RC" -eq 0 ]                                            || fail "7: dispatch amend exited $RC ($OUT)"
grep -qE $'^AMEND\tHERD-7\tthis ships behind a flag$' "$DISPATCH" || fail "7: amend did not dispatch (HERD-7, note) ($(cat "$DISPATCH"))"
grep -qE $'^ADD\t' "$DISPATCH"                            && fail "7: amend was wrongly filed as a NEW item"
[ ! -e "$p" ]                                             || fail "7: claimed file not cleaned up"
ok

# ══ 7b. DISPATCH: a backend amend that finds no unique match → scribe-step records a SKIP ═════════
: > "$DISPATCH"; : > "$INBOX" 2>/dev/null || true
cat > "$FAKEDIR/fake.sh" <<FAKEEOF
#!/usr/bin/env bash
_backend_add_item()   { printf 'ADD\t%s\n' "\$2" >> "$DISPATCH"; _BACKEND_RESULT="DONE"; }
_backend_amend()      { printf 'AMEND\t%s\n' "\$1" >> "$DISPATCH"; _BACKEND_RESULT="NOCHANGE"; }
_backend_mark_shipped(){ :; }
_backend_list_open()  { :; }
_backend_item_state() { ITEM_STATE="open"; }
FAKEEOF
p="$(mkreq 710 "append to something ambiguous")"
step "$FAKEDIR" fake amend "$p" "vague ref" "note"
[ "$RC" -eq 0 ]                                            || fail "7b: exited $RC ($OUT)"
grep -qi 'SKIPPED (not posted)' "$INBOX"                  || fail "7b: NOCHANGE amend did not record a SKIP ($(cat "$INBOX" 2>/dev/null))"
ok

# ══ 8. usage line documents the new amend verb ═══════════════════════════════════════════════════
step "$BACKENDS" file bogus-verb
printf '%s\n' "$OUT" | grep -q 'amend' || fail "8: usage does not mention amend ($OUT)"
ok

echo "ALL PASS ($pass checks)"
