#!/usr/bin/env bash
# test-scribe-deadletter.sh — HERD-391: a scribe request that reaches the drainer's cleanup tail
# WITHOUT being filed must never just vanish.
#
# THE INCIDENT this locks down: a scribe add whose body carried an absolute private temp path was
# claimed (the "JUST SCRIBED" banner fired) and then never filed — no tracker_write, no create event,
# no CREATE_SELFHEAL retry entry, no error. An identical re-file vanished identically. The gap:
# `commit`'s file-backend path (and every SKIP) fell straight into _report_and_cleanup, which deletes
# the claimed request the instant `git diff --cached --quiet` finds nothing staged — whether that
# NOCHANGE means "a guard silently declined to write this" or "a stale-drainer misroute" or "nothing
# unmappable to file". Whatever the reason, the request's own bytes were the only surviving copy and
# they were `rm -f`'d with nothing durable left behind.
#
# Asserts, against the REAL file backend (no stub, no network):
#   (1) A request whose drainer "edit" never touches BACKLOG_FILE (simulating a guard's silent refusal
#       on a denied-path-carrying body, or any other silent no-op) is NOT vanished: it is dead-lettered
#       byte-for-byte under $WORKTREES_DIR/.scribe-deadletter/ and a scribe_drop journal event names the
#       reason — while the claim is still cleaned up exactly as before (no change to the happy-path
#       receipt/inbox/notify contract).
#   (2) A CLEAN request whose drainer DOES edit BACKLOG_FILE still files normally: it lands in the
#       commit, is NOT dead-lettered, and no scribe_drop event is journaled for it.
#   (3) The `skip` verb (an explicit "unmappable" classification) is dead-lettered the same way — the
#       drainer's reason survives durably, not only as a transient stderr line.
#   (4) CREATE_SELFHEAL=off is byte-identical to the pre-HERD-391 behavior: no .scribe-deadletter
#       directory, no scribe_drop event — the same lever HERD-267 already gated this class of durability
#       on.
#
# Run:  bash tests/test-scribe-deadletter.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
STEP="$ROOT/scripts/herd/scribe-step.sh"
BACKENDS="$ROOT/scripts/herd/backends"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); }

# ── Stub herdr on PATH so no real notification/tab is ever touched ────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── A temp git repo the file backend commits into ─────────────────────────────
REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
cat > "$REPO/BACKLOG.md" <<'MD'
# Backlog

## Now
- 🔜 existing-item — an already-queued item

## Recently shipped
MD
git -C "$REPO" add BACKLOG.md; git -C "$REPO" commit -q -m init

TREES="$T/trees"; Q="$TREES/backlog-queue"; INBOX="$TREES/.scribe-reports"
DEADLETTER="$TREES/.scribe-deadletter"
mkdir -p "$Q"
JF="$T/journal.jsonl"; : > "$JF"

CFG="$T/config"
cat > "$CFG" <<CFGEOF
HERD_VERSION=1
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="deadlettertest"
HERD_REMOTE="origin"
HERD_BRANCH_NAME="main"
BACKLOG_FILE="BACKLOG.md"
CFGEOF
# SCRIBE_BACKEND is deliberately not pinned in the config (see test-scribe-amend.sh) — each step()
# passes it via env so herd-config's default assignment never clobbers a per-call override.

# step <selfheal> <args...> — run scribe-step.sh against the REAL file backend from inside $REPO.
step() {
  local selfheal="$1"; shift
  set +e
  OUT="$( cd "$REPO" && HERD_CONFIG_FILE="$CFG" SCRIBE_BACKEND_DIR="$BACKENDS" SCRIBE_BACKEND=file \
            JOURNAL_FILE="$JF" SCRIBE_POLL=0 CREATE_SELFHEAL="$selfheal" bash "$STEP" "$@" 2>&1 )"
  RC=$?
  set -e
}
# mkreq <name> <text> — drop a claimed (.mine) request file; echoes its path.
mkreq() { local p="$Q/$1.req.mine"; printf '%s' "$2" > "$p"; printf '%s' "$p"; }
dl_count() { ls "$DEADLETTER"/*.req 2>/dev/null | grep -c . || true; }

DENIED_TEXT='Add a widget
note: request filed from /private/tmp/claude-501/-Users-realuser-source-project/scratchpad/note.txt'

# ══ (1) A guard's silent refusal (no BACKLOG_FILE edit) is dead-lettered, not vanished ═══════════════
p="$(mkreq 100 "$DENIED_TEXT")"
# Simulate the drainer declining to write the sensitive body: BACKLOG_FILE is left untouched.
step on commit "$p" "add widget"
[ "$RC" -eq 0 ]           || fail "(1) commit exited $RC ($OUT)"
[ ! -e "$p" ]             || fail "(1) the claimed file was left behind"
[ "$(dl_count)" = "1" ]   || fail "(1) expected one dead-letter entry, got $(dl_count) ($(ls "$DEADLETTER" 2>/dev/null))"
DLFILE="$(ls "$DEADLETTER"/*.req)"
[ "$(cat "$DLFILE")" = "$DENIED_TEXT" ] || fail "(1) the dead-lettered request lost its original bytes"
grep -q '"event":"scribe_drop"' "$JF"    || fail "(1) no scribe_drop journal event ($(cat "$JF"))"
grep -q '"result":"NOCHANGE"' "$JF"      || fail "(1) the journal did not carry the NOCHANGE result"
# The happy-path receipt/inbox/notify tail is unchanged: the claim is still cleaned up and reported.
[ -f "$INBOX" ] && grep -q 'add widget' "$INBOX" || fail "(1) the inbox line was not written"
ok; echo "PASS (1) a guarded/no-op commit dead-letters the original request instead of vanishing"

# ══ (2) A CLEAN request whose drainer DOES edit BACKLOG_FILE still files normally ════════════════════
: > "$JF"; rm -rf "$DEADLETTER"
CLEAN_TEXT='Add a clean, unremarkable feature request'
p="$(mkreq 200 "$CLEAN_TEXT")"
printf -- '- 🔜 clean-feature — %s\n' "$CLEAN_TEXT" >> "$REPO/BACKLOG.md"
step on commit "$p" "add clean-feature"
[ "$RC" -eq 0 ]                                   || fail "(2) commit exited $RC ($OUT)"
git -C "$REPO" log -1 --name-only | grep -q BACKLOG.md \
  || fail "(2) the clean edit was not committed"
git -C "$REPO" show HEAD:BACKLOG.md | grep -q 'clean-feature' \
  || fail "(2) the clean item is not in the committed BACKLOG.md"
[ "$(dl_count)" = "0" ]                           || fail "(2) a filed request was wrongly dead-lettered"
grep -q '"event":"scribe_drop"' "$JF" && fail "(2) a filed request wrongly journaled scribe_drop"
[ ! -e "$p" ]                                      || fail "(2) the claimed file was left behind"
ok; echo "PASS (2) a clean, actually-filed request is never dead-lettered"

# ══ (3) an explicit `skip` (unmappable request) is ALSO dead-lettered, not just noted on stderr ══════
: > "$JF"; rm -rf "$DEADLETTER"
SKIP_TEXT='Some unmappable operator aside that is not an add, a state change, or a note'
p="$(mkreq 300 "$SKIP_TEXT")"
step on skip "$p" "not mappable to any backend verb"
[ "$RC" -eq 0 ]           || fail "(3) skip exited $RC ($OUT)"
[ "$(dl_count)" = "1" ]   || fail "(3) skip was not dead-lettered ($(dl_count))"
DLFILE="$(ls "$DEADLETTER"/*.req)"
[ "$(cat "$DLFILE")" = "$SKIP_TEXT" ] || fail "(3) the skipped request lost its original text"
grep -q '"event":"scribe_drop"' "$JF"        || fail "(3) skip did not journal scribe_drop"
grep -q '"result":"SKIP"' "$JF"              || fail "(3) the journal did not carry the SKIP result"
grep -q 'not mappable to any backend verb' "$JF" || fail "(3) the drainer's reason was not preserved"
ok; echo "PASS (3) an explicit skip is dead-lettered with its reason, durably"

# ══ (4) CREATE_SELFHEAL=off is byte-identical to the pre-HERD-391 behavior ═══════════════════════════
: > "$JF"; rm -rf "$DEADLETTER"
p="$(mkreq 400 "$DENIED_TEXT")"
step off commit "$p" "add widget"
[ "$RC" -eq 0 ]              || fail "(4) commit exited $RC ($OUT)"
[ ! -d "$DEADLETTER" ]       || fail "(4) CREATE_SELFHEAL=off still created a dead-letter directory"
grep -q '"event":"scribe_drop"' "$JF" && fail "(4) CREATE_SELFHEAL=off still journaled scribe_drop"
[ ! -e "$p" ]                || fail "(4) the off path changed the claim cleanup"
ok; echo "PASS (4) CREATE_SELFHEAL=off keeps the pre-HERD-391 behavior byte-identical"

echo "ALL PASS ($PASS checks)"
