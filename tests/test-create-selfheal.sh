#!/usr/bin/env bash
# test-create-selfheal.sh — hermetic proof of tracker-create SELF-HEAL (HERD-267).
#
# THE INCIDENT this locks down: Linear's free-tier ISSUE CAP began refusing `issueCreate` with a 400.
# scribe-step.sh's add path read the refusal as NOCHANGE, ran its ordinary report-and-cleanup tail,
# and DELETED the claimed request file. Six coordinator filings vanished over two hours — empty queue,
# no journal line, no console row — and PR #377 recorded the cap as an "API flake", so nothing learned
# that every later create was doomed too.
#
# Asserts, against a STUB backend that fails on demand (no network, no model, no real tracker):
#   (1) FAIL-N-THEN-SUCCEED — a create that fails is NOT consumed: the original request text lands in
#       the durable retry queue byte-for-byte, `next` re-injects it once its backoff elapses, and the
#       eventual success RESOLVES the entry (the queue drains to empty).
#   (2) NEVER LOSE THE TEXT — the durable entry holds the request verbatim, newlines and all.
#   (3) CAP = PERMANENT, LOUD, NO SPIN — a 400 USAGE_LIMIT_EXCEEDED goes permanent on its FIRST
#       attempt, journals create_retry_permanent, prints a distinct label, and is NEVER due again.
#   (4) COALESCING — the same request failing three times is ONE entry reading attempts=3 and ONE
#       console row, not three stacked rows.
#   (5) CLASSIFICATION — cap / auth / transient / unknown are told apart, cap outranking rate-limit.
#   (6) THE BACKEND REPORTS WHY — linear.sh's _linear_error_text lifts errors[0].extensions.code out
#       of a GraphQL refusal, which is the fact that was missing during the incident.
#   (7) CREATE_RETRY_MAX — a transient failure goes permanent once the attempt budget is spent.
#   (8) BYTE-IDENTICAL WHEN OFF — with CREATE_SELFHEAL=off the add path behaves exactly as it did
#       before HERD-267: no retry directory, no diversion, the old NOCHANGE report tail.
#   (9) BYTE-IDENTICAL WHEN EMPTY — a SUCCESSFUL create writes no entry and its report tail is
#       unchanged; `next` on an empty retry queue re-injects nothing.
#  (10) SWEEP RETROACTIVE LINKAGE — a merged PR whose `Refs:` names no tracker item is detected,
#       narrated, and its search-first relink request enqueued exactly once (seen-ledger); a PR whose
#       ref RESOLVES is left alone; --dry-run enqueues nothing.
#
# Run:  bash tests/test-create-selfheal.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STEP="$HERE/../scripts/herd/scribe-step.sh"
LIB="$HERE/../scripts/herd/create-retry.sh"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
LINEAR="$HERE/../scripts/herd/backends/linear.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── fixture: stub herdr, a temp repo, a temp trees dir, a config ─────────────
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
TREES="$T/trees"; Q="$TREES/backlog-queue"; INBOX="$TREES/.scribe-reports"; RETRY="$TREES/.create-retry"
mkdir -p "$Q"

# ── a STUB backend whose add fails while a control file says so ──────────────
# $T/fail-with holds the error string _backend_add_item reports (empty file ⇒ the create succeeds).
# This is the whole test seam: the drainer cannot tell it from a real refusal.
FAKEDIR="$T/fakebackends"; mkdir -p "$FAKEDIR"
cat > "$FAKEDIR/stub.sh" <<STUBEOF
#!/usr/bin/env bash
_backend_add_item() {
  _BACKEND_ERROR=""
  local err; err="\$(cat "$T/fail-with" 2>/dev/null)"
  if [ -n "\$err" ]; then
    _BACKEND_RESULT="NOCHANGE"; _BACKEND_ERROR="\$err"; return 0
  fi
  printf 'HERD-900\n'
  _BACKEND_RESULT="DONE"
}
_backend_update_state() { _BACKEND_RESULT="DONE"; }
_backend_mark_shipped() { :; }
_backend_list_open() { :; }
_backend_item_state() { ITEM_STATE="open"; }
STUBEOF
: > "$T/fail-with"

CFG="$T/config"
cat > "$CFG" <<CFGEOF
HERD_VERSION=1
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="selfhealtest"
HERD_REMOTE="origin"
HERD_BRANCH_NAME="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="stub"
CFGEOF

JOURNAL="$T/journal.jsonl"; : > "$JOURNAL"

# step <args…> — run scribe-step.sh against the stub backend. $OUT = combined output, $RC = exit code.
# HERD_CREATE_RETRY_NOW freezes the clock so backoff is asserted, not raced.
step() {
  set +e
  OUT="$( cd "$REPO" && HERD_CONFIG_FILE="$CFG" SCRIBE_BACKEND_DIR="$FAKEDIR" SCRIBE_POLL=0 \
            JOURNAL_FILE="$JOURNAL" HERMETIC_TEST=1 \
            HERD_CREATE_RETRY_NOW="${NOW:-1000}" HERD_CREATE_RETRY_BASE="${BASE:-60}" \
            CREATE_SELFHEAL="${SELFHEAL:-on}" CREATE_RETRY_MAX="${MAXTRY:-5}" \
            bash "$STEP" "$@" 2>&1 )"
  RC=$?
  set -e
}
mkreq() { local p="$Q/$1.req.mine"; printf '%s' "$2" > "$p"; printf '%s' "$p"; }
entries() { ls "$RETRY"/*.meta 2>/dev/null | grep -c . || true; }
jhas() { grep -q "$1" "$JOURNAL" 2>/dev/null; }

REQ_TEXT='Add a dark-mode toggle
with a second line and  spacing preserved'

# ══ (1)+(2) a failed create is DIVERTED, never consumed; the text survives verbatim ══════════════
printf 'HTTP 503 Service Unavailable\n' > "$T/fail-with"
p="$(mkreq 100 "$REQ_TEXT")"
step add-item "$p" "$REQ_TEXT"
[ "$RC" -eq 0 ]                       || fail "(1) add-item exited $RC ($OUT)"
[ ! -e "$p" ]                         || fail "(1) the claimed file was left behind"
[ "$(entries)" = "1" ]                || fail "(1) no durable retry entry was written ($(ls "$RETRY" 2>/dev/null))"
HASH="$(basename "$(ls "$RETRY"/*.meta)" .meta)"
[ "$(cat "$RETRY/$HASH.text")" = "$REQ_TEXT" ] || fail "(2) the request text was not preserved verbatim"
grep -q '^state=pending' "$RETRY/$HASH.meta"   || fail "(1) a 503 was not left pending for retry"
grep -q '^last_class=transient' "$RETRY/$HASH.meta" || fail "(1) a 503 was not classified transient"
jhas '"event":"scribe_add_failed"'    || fail "(1) the failure was not journaled"
jhas '"reason":"transient"'           || fail "(1) the journal did not carry the reason"
printf '%s\n' "$OUT" | grep -q 'SAVED'|| fail "(1) the failure was not surfaced loudly ($OUT)"
ok; echo "PASS (1)(2) a refused create is diverted to the durable queue; the text survives verbatim"

# ══ (9a) `next` does NOT re-inject before the backoff elapses ════════════════════════════════════
NOW=1010 step next
ls "$Q"/*.req >/dev/null 2>&1 && fail "(9a) an entry was re-injected inside its backoff window"
ok; echo "PASS (9a) backoff is honored — nothing re-injected early"

# ══ (1b) once the backoff elapses, `next` re-injects the SAME text and claims it ═════════════════
NOW=2000 step next
printf '%s\n' "$OUT" | grep -q '^CLAIMED '  || fail "(1b) the re-injected request was not claimed ($OUT)"
printf '%s\n' "$OUT" | grep -q 'dark-mode'  || fail "(1b) the re-injected request lost its text ($OUT)"
jhas '"event":"create_retry_reinjected"'    || fail "(1b) the re-injection was not journaled"
CLAIMED="$(printf '%s\n' "$OUT" | sed -n 's/^CLAIMED //p' | head -n1)"
[ -f "$CLAIMED" ]                           || fail "(1b) the claimed path does not exist"
ok; echo "PASS (1b) a due entry rides the drainer's own next poll"

# ══ (1c) the eventual SUCCESS resolves the entry — the durable queue drains to empty ═════════════
: > "$T/fail-with"
NOW=2000 step add-item "$CLAIMED" "$REQ_TEXT"
[ "$RC" -eq 0 ]            || fail "(1c) the successful retry exited $RC ($OUT)"
[ "$(entries)" = "0" ]     || fail "(1c) the entry survived a confirmed create ($(ls "$RETRY"))"
jhas '"event":"create_retry_resolved"' || fail "(1c) the resolve was not journaled"
ok; echo "PASS (1c) a confirmed create resolves the durable entry"

# ══ (1d) ENTRY IDENTITY survives the drainer's LLM — the duplicate-forever trap ══════════════════
# A retried request passes back through the scribe Claude, which may hand `add-item` a text that
# differs from the stored one by a re-wrapped line. If the entry were keyed on THAT text, the success
# would resolve nothing and the entry would re-inject (and re-file) forever. The key comes from the
# re-injected file's own name instead, so a mangled text still resolves the right entry.
rm -rf "$RETRY"
printf 'upstream timeout\n' > "$T/fail-with"
p="$(mkreq 150 "$REQ_TEXT")"
NOW=8000 step add-item "$p" "$REQ_TEXT"
[ "$(entries)" = "1" ] || fail "(1d) setup: no entry"
IDH="$(basename "$(ls "$RETRY"/*.meta)" .meta)"
: > "$T/fail-with"
RETRY_REQ="$Q/8500-retry-${IDH}.req.mine"; printf '%s' "$REQ_TEXT" > "$RETRY_REQ"
NOW=8500 step add-item "$RETRY_REQ" "Add a dark-mode toggle (reflowed by the drainer)"
[ "$(entries)" = "0" ]                || fail "(1d) a reflowed retry did not resolve its entry — it would re-file forever"
[ "$(cat "$RETRY/$IDH.text" 2>/dev/null)" = "" ] || fail "(1d) the entry text file survived resolution"
# …and the same key protects the FAILURE path from forking a second entry.
printf 'upstream timeout\n' > "$T/fail-with"
p="$(mkreq 151 "$REQ_TEXT")"; NOW=8600 step add-item "$p" "$REQ_TEXT"
IDH="$(basename "$(ls "$RETRY"/*.meta)" .meta)"
RETRY_REQ="$Q/8700-retry-${IDH}.req.mine"; printf '%s' "$REQ_TEXT" > "$RETRY_REQ"
NOW=8700 step add-item "$RETRY_REQ" "Add a dark-mode toggle (reflowed again)"
[ "$(entries)" = "1" ] || fail "(1d) a reflowed retry forked a second entry instead of coalescing"
grep -q '^attempts=2' "$RETRY/$IDH.meta" || fail "(1d) the reflowed retry did not bump the original entry"
[ "$(cat "$RETRY/$IDH.text")" = "$REQ_TEXT" ] || fail "(1d) the ORIGINAL request text was overwritten by the LLM's variant"
ok; echo "PASS (1d) a retry's entry identity comes from the engine's filename, not the drainer's text"

# ══ (3) a CAP-style 400 is PERMANENT on the first attempt: loud, journaled, and never due ════════
: > "$JOURNAL"; rm -rf "$RETRY"
printf 'USAGE_LIMIT_EXCEEDED You have reached the issue limit for your plan\n' > "$T/fail-with"
p="$(mkreq 200 "File the cap-killed item")"
NOW=3000 step add-item "$p" "File the cap-killed item"
CAPHASH="$(basename "$(ls "$RETRY"/*.meta)" .meta)"
grep -q '^state=permanent'  "$RETRY/$CAPHASH.meta" || fail "(3) a cap failure was not marked permanent"
grep -q '^last_class=cap'   "$RETRY/$CAPHASH.meta" || fail "(3) a cap failure was not classified 'cap'"
grep -q '^attempts=1'       "$RETRY/$CAPHASH.meta" || fail "(3) a cap failure spent more than one attempt"
jhas '"event":"create_retry_permanent"'            || fail "(3) the permanent transition was not journaled"
printf '%s\n' "$OUT" | grep -q 'ISSUE CAP'         || fail "(3) the cap was not labeled distinctly ($OUT)"
printf '%s\n' "$OUT" | grep -q 'NOT be retried'    || fail "(3) the no-spin promise was not surfaced ($OUT)"
# …and it must NEVER spin: no matter how far the clock advances, `next` re-injects nothing.
NOW=999999 step next
ls "$Q"/*.req >/dev/null 2>&1 && fail "(3) a PERMANENT cap failure was re-injected — it will spin forever"
[ -f "$RETRY/$CAPHASH.text" ] || fail "(3) 'permanent' discarded the request text — it must only stop RETRYING"
ok; echo "PASS (3) a cap failure is permanent, loud, retains its text, and never spins"

# ══ (4) COALESCING — one request failing 3× is ONE entry (attempts=3) and ONE row ════════════════
rm -rf "$RETRY"
printf 'upstream timeout\n' > "$T/fail-with"
for i in 1 2 3; do
  p="$(mkreq "30$i" "Coalesce me")"
  NOW=$(( 4000 + i )) step add-item "$p" "Coalesce me"
done
[ "$(entries)" = "1" ] || fail "(4) repeated failures stacked $(entries) entries instead of coalescing to 1"
CO="$(basename "$(ls "$RETRY"/*.meta)" .meta)"
grep -q '^attempts=3' "$RETRY/$CO.meta" || fail "(4) the coalesced entry does not carry a retry count of 3"
ROWS="$( HERD_CONFIG_FILE="$CFG" HERMETIC_TEST=1 JOURNAL_FILE="$JOURNAL" CREATE_SELFHEAL=on bash "$LIB" rows )"
[ "$(printf '%s\n' "$ROWS" | grep -c .)" = "1" ] || fail "(4) create_retry_rows stacked per attempt: $ROWS"
printf '%s' "$ROWS" | grep -q 'Coalesce me'       || fail "(4) the coalesced row lost its title"
ok; echo "PASS (4) repeated failures of one request coalesce into one row with a retry count"

# ══ (5) CLASSIFICATION — the trap runs BOTH ways ═════════════════════════════════════════════════
# A cap read as a flake wastes every retry (the incident). A THROTTLE read as a wall is the mirror
# image: the self-heal never fires on the commonest recoverable failure, and the operator is sent to
# raise a cap they never hit. Both are false reds. The strings below are the ones the backends really
# emit — `_linear_error_text` feeds "<extensions.code> <message>", so RATELIMITED arrives glued to
# "Rate limit exceeded", which is exactly what a generic *limit exceeded* cap pattern would swallow.
# shellcheck source=/dev/null
WORKTREES_DIR="$TREES" . "$LIB"
[ "$(create_retry_class 'USAGE_LIMIT_EXCEEDED rate limit reached')" = cap ] \
  || fail "(5) 'usage limit' lost to 'rate limit' — the exact mislabel behind the incident"
[ "$(create_retry_class 'USAGE_LIMIT_EXCEEDED You have reached the issue limit for your plan')" = cap ] \
  || fail "(5) a real Linear cap refusal is not a cap"
# …and the mirror: every real Linear throttling shape must stay RETRYABLE.
for s in 'RATELIMITED Rate limit exceeded' \
         'Rate limit exceeded, please try again later' \
         'RATELIMITED You have exceeded the rate limit' \
         'RATE_LIMIT_EXCEEDED too many requests' \
         'rate-limit exceeded'; do
  [ "$(create_retry_class "$s")" = transient ] \
    || fail "(5) '$s' classified $(create_retry_class "$s"), not transient — a self-clearing throttle would be marked a PERMANENT wall"
  create_retry_permanent_class "$(create_retry_class "$s")" \
    && fail "(5) '$s' is permanent — the retry queue would never fire on it"
done
[ "$(create_retry_class 'AUTHENTICATION_ERROR bad key')" = auth ]    || fail "(5) auth misclassified"
[ "$(create_retry_class 'HTTP 503 upstream')" = transient ]          || fail "(5) 5xx misclassified"
[ "$(create_retry_class '503')" = transient ]                        || fail "(5) a bare 5xx status misclassified"
[ "$(create_retry_class 'rate limit, try again')" = transient ]      || fail "(5) rate limit misclassified"
[ "$(create_retry_class '')" = unknown ]                             || fail "(5) empty error misclassified"
# A generic limit-exceeded with no rate/usage qualifier is a cap by elimination…
[ "$(create_retry_class 'LIMIT_EXCEEDED you have exceeded the limit')" = cap ] \
  || fail "(5) a generic limit-exceeded no longer reads as a cap"
# …but a 3-digit run that merely starts with 5 is NOT an http 5xx.
[ "$(create_retry_class 'Issue 501 not found')" = unknown ] \
  || fail "(5) 'Issue 501 not found' was read as a 5xx — the loose numeric match is back"
create_retry_permanent_class cap  || fail "(5) cap is not permanent"
create_retry_permanent_class auth || fail "(5) auth is not permanent"
create_retry_permanent_class transient && fail "(5) transient must stay retryable"
create_retry_permanent_class unknown   && fail "(5) unknown must stay retryable (never discard a recoverable request)"
ok; echo "PASS (5) cap vs throttle vs auth vs unknown — neither a wall nor a hiccup reads as the other"

# ══ (5b) a REAL Linear rate limit survives the whole pipeline as a RETRYABLE entry ════════════════
# End-to-end, not just the classifier: the throttle must leave a pending entry that `next` re-injects.
rm -rf "$RETRY"
printf 'RATELIMITED Rate limit exceeded\n' > "$T/fail-with"
p="$(mkreq 250 "Throttled filing")"
NOW=9000 step add-item "$p" "Throttled filing"
RL="$(basename "$(ls "$RETRY"/*.meta)" .meta)"
grep -q '^last_class=transient' "$RETRY/$RL.meta" || fail "(5b) a Linear rate limit was not classified transient"
grep -q '^state=pending'        "$RETRY/$RL.meta" || fail "(5b) a Linear rate limit was marked PERMANENT — the self-heal never fires on it"
printf '%s\n' "$OUT" | grep -q 'ISSUE CAP' && fail "(5b) a throttle was labeled as an issue cap ($OUT)"
NOW=99000 step next
printf '%s\n' "$OUT" | grep -q '^CLAIMED ' || fail "(5b) the throttled request was never re-injected ($OUT)"
ok; echo "PASS (5b) a real Linear rate limit stays pending and is retried, never walled"

# ══ (6) the linear backend reports WHY — the fact that was missing during the incident ═══════════
# shellcheck source=/dev/null
LINEAR_API_KEY=x . "$LINEAR" >/dev/null 2>&1
E="$(printf '%s' '{"errors":[{"message":"issue limit reached","extensions":{"code":"USAGE_LIMIT_EXCEEDED"}}]}' | _linear_error_text)"
case "$E" in *USAGE_LIMIT_EXCEEDED*) : ;; *) fail "(6) _linear_error_text dropped the GraphQL error code (got '$E')" ;; esac
[ "$(create_retry_class "$E")" = cap ] || fail "(6) a real Linear cap refusal does not classify as 'cap'"
[ -z "$(printf '%s' '{"data":{"issueCreate":{"success":false}}}' | _linear_error_text)" ] \
  || fail "(6) a response with no errors array invented an error"
ok; echo "PASS (6) linear.sh lifts the refusal reason out of the GraphQL response"

# ══ (7) CREATE_RETRY_MAX bounds the transient class ══════════════════════════════════════════════
rm -rf "$RETRY"
printf 'upstream timeout\n' > "$T/fail-with"
for i in 1 2; do
  p="$(mkreq "40$i" "Budgeted retry")"
  MAXTRY=2 NOW=$(( 5000 + i )) step add-item "$p" "Budgeted retry"
done
BH="$(basename "$(ls "$RETRY"/*.meta)" .meta)"
grep -q '^state=permanent' "$RETRY/$BH.meta" || fail "(7) CREATE_RETRY_MAX=2 did not retire the entry after 2 attempts"
ok; echo "PASS (7) CREATE_RETRY_MAX bounds the retryable classes"

# ══ (8) BYTE-IDENTICAL WHEN OFF — the pre-HERD-267 drop-on-failure behavior, exactly ═════════════
rm -rf "$RETRY"
printf 'USAGE_LIMIT_EXCEEDED cap\n' > "$T/fail-with"
p="$(mkreq 500 "Off means off")"
SELFHEAL=off NOW=6000 step add-item "$p" "Off means off"
[ "$RC" -eq 0 ]                 || fail "(8) the off path exited $RC ($OUT)"
[ ! -d "$RETRY" ]               || fail "(8) CREATE_SELFHEAL=off still created a retry directory"
[ ! -e "$p" ]                   || fail "(8) the off path changed the claim cleanup"
printf '%s\n' "$OUT" | grep -q 'SAVED' && fail "(8) the off path emitted the HERD-267 retry line"
printf '%s\n' "$OUT" | grep -q 'NOCHANGE' || fail "(8) the off path did not report the old NOCHANGE result ($OUT)"
SELFHEAL=off NOW=6000 step next
ls "$Q"/*.req >/dev/null 2>&1 && fail "(8) the off path re-injected something"
ok; echo "PASS (8) CREATE_SELFHEAL=off is the pre-HERD-267 behavior, byte for byte"

# ══ (9b) BYTE-IDENTICAL WHEN EMPTY — a successful create writes nothing and reports as before ════
rm -rf "$RETRY"; : > "$T/fail-with"
p="$(mkreq 600 "A perfectly ordinary item")"
NOW=7000 step add-item "$p" "A perfectly ordinary item"
[ ! -d "$RETRY" ] || fail "(9b) a SUCCESSFUL create wrote a retry entry"
printf '%s\n' "$OUT" | grep -q 'DONE' || fail "(9b) the success report tail changed ($OUT)"
printf '%s\n' "$OUT" | grep -q 'HERD-900' || fail "(9b) the backend's add stdout was swallowed ($OUT)"
ok; echo "PASS (9b) the happy path is untouched — no entry, unchanged report tail"

# ══ (11) A FAILED DURABLE WRITE NEVER REPORTS "SAVED" — the claim is kept, the request survives ══
# The one invariant this file names non-negotiable ("never lose the original text") had no confirmation
# on the single path that deletes the other copy. Simulate an unwritable retry directory: the claimed
# .req must SURVIVE, the step must exit non-zero, and it must not print the reassuring SAVED line.
rm -rf "$RETRY"
printf 'upstream timeout\n' > "$T/fail-with"
p="$(mkreq 700 "Must not vanish")"
: > "$RETRY"                       # a FILE where the directory must go → mkdir -p fails
NOW=9500 step add-item "$p" "Must not vanish"
[ "$RC" -ne 0 ]  || fail "(11) a failed durable write exited 0 — the caller believes the text is safe"
[ -e "$p" ]      || fail "(11) the ONLY surviving copy of the request was deleted after a failed durable write"
printf '%s\n' "$OUT" | grep -q 'SAVED' && fail "(11) claimed the request was SAVED when the write failed ($OUT)"
printf '%s\n' "$OUT" | grep -q 'DURABLE WRITE FAILED' || fail "(11) the failed write was not surfaced ($OUT)"
rm -f "$RETRY" "$p"
ok; echo "PASS (11) a failed durable write keeps the claim and refuses to claim the text is safe"

# ══ (12) A RE-INJECTED REQUEST THE DRAINER SKIPS IS TERMINAL — it must not re-inject forever ══════
# attempts is only bumped by create_retry_enqueue, so an entry whose retries all route to skip/amend/
# update-state could never converge on CREATE_RETRY_MAX either.
for verb in skip amend update-state; do
  rm -rf "$RETRY"; printf 'upstream timeout\n' > "$T/fail-with"
  p="$(mkreq "80${#verb}" "Terminal via $verb")"
  NOW=9600 step add-item "$p" "Terminal via $verb"
  TH="$(basename "$(ls "$RETRY"/*.meta)" .meta)"
  RQ="$Q/9700-retry-${TH}.req.mine"; printf 'Terminal via %s' "$verb" > "$RQ"
  case "$verb" in
    skip)         NOW=9700 step skip "$RQ" "not a backlog add" ;;
    amend)        NOW=9700 step amend "$RQ" "HERD-22" "a note" ;;
    update-state) NOW=9700 step update-state "$RQ" "HERD-22" "done" ;;
  esac
  [ "$(entries)" = "0" ] || fail "(12) '$verb' left the durable entry behind — it will re-inject forever"
done
ok; echo "PASS (12) skip / amend / update-state release a re-injected entry (no infinite re-inject)"

# ══ (13) REINJECT IS DEDUPED — an entry already sitting in the queue is not queued twice ═════════
rm -rf "$RETRY"; rm -f "$Q"/*.req "$Q"/*.mine 2>/dev/null
printf 'upstream timeout\n' > "$T/fail-with"
p="$(mkreq 900 "Dedupe me")"
NOW=10000 step add-item "$p" "Dedupe me"
DH="$(basename "$(ls "$RETRY"/*.meta)" .meta)"
reinject() { HERD_CONFIG_FILE="$CFG" HERMETIC_TEST=1 JOURNAL_FILE="$JOURNAL" CREATE_SELFHEAL=on \
  HERD_CREATE_RETRY_NOW="$1" bash "$LIB" reinject "$Q" 2>/dev/null; }
[ "$(reinject 20000)" = "1" ] || fail "(13) the due entry was not re-injected"
# Same hash still queued (an unread .req) → a second, later reinject must not duplicate it.
[ "$(reinject 40000)" = "0" ] || fail "(13) an entry already in the queue was re-injected twice"
[ "$(ls "$Q"/*-retry-"$DH".req 2>/dev/null | grep -c .)" = "1" ] || fail "(13) a duplicate .req was written"
rm -f "$Q"/*.req
ok; echo "PASS (13) reinject skips an entry that is already sitting in the queue"

# ══ (14) THE changelog BACKEND IS EXEMPT — its NOCHANGE means 'no staged edit', not 'refused' ════
# Same reasoning as the `file` exemption: feeding it the retry queue would eventually render a
# '🚫 tracker create BLOCKED' row for a condition no create can fix.
rm -rf "$RETRY"
sed 's/SCRIBE_BACKEND="stub"/SCRIBE_BACKEND="changelog"/' "$CFG" > "$CFG.changelog"
cat > "$FAKEDIR/changelog.sh" <<'CLEOF'
_backend_add_item() { _BACKEND_RESULT="NOCHANGE"; }
_backend_list_open() { :; }
CLEOF
p="$(mkreq 950 "Changelog item")"
set +e
OUT="$( cd "$REPO" && HERD_CONFIG_FILE="$CFG.changelog" SCRIBE_BACKEND_DIR="$FAKEDIR" SCRIBE_POLL=0 \
          JOURNAL_FILE="$JOURNAL" HERMETIC_TEST=1 CREATE_SELFHEAL=on \
          bash "$STEP" add-item "$p" "Changelog item" 2>&1 )"
RC=$?
set -e
[ "$RC" -eq 0 ]   || fail "(14) the changelog add exited $RC ($OUT)"
[ ! -d "$RETRY" ] || fail "(14) a local (changelog) backend's NOCHANGE fed the tracker retry queue"
ok; echo "PASS (14) local backends (file, changelog) never feed the tracker-create retry queue"

# ══ (10) SWEEP RETROACTIVE LINKAGE ═══════════════════════════════════════════════════════════════
# Source sweep.sh through agent-watch.sh's lib seam, exactly as `herd sweep` does.
SWTREES="$T/swtrees"; SWQ="$SWTREES/backlog-queue"; mkdir -p "$SWTREES"
SWBACKENDS="$T/swbackends"; mkdir -p "$SWBACKENDS"
# The TRI-STATE probe: 1 = exists, 0 = provably missing (the API answered, zero matches), 2 = UNPROVEN.
# HERD-77 stands in for a ref the tracker refuses to answer about (auth error / outage / rate limit).
cat > "$SWBACKENDS/stub.sh" <<'SWEOF'
_backend_item_missing() {
  case "$1" in
    HERD-1)    return 1 ;;   # exists
    HERD-4242) return 0 ;;   # the API answered: nothing there
    *)         return 2 ;;   # we do not know
  esac
}
_backend_add_item() { _BACKEND_RESULT="DONE"; }
_backend_list_open() { :; }
SWEOF
# A backend with NO tri-state probe at all (the pre-fix shape): every identifier must read UNPROVEN.
cat > "$SWBACKENDS/noprobe.sh" <<'SWEOF'
_backend_show_item() { return 1; }   # collapses not-found and every transport failure — unusable as proof
_backend_add_item() { _BACKEND_RESULT="DONE"; }
_backend_list_open() { :; }
SWEOF
# A backend whose tracker is DOWN: every probe is UNPROVEN. This is the outage that must not relink.
cat > "$SWBACKENDS/down.sh" <<'SWEOF'
_backend_item_missing() { return 2; }
_backend_add_item() { _BACKEND_RESULT="DONE"; }
_backend_list_open() { :; }
SWEOF
cat > "$T/prs.json" <<'PRJSON'
[
 {"number": 1, "url": "https://x/pull/1", "body": "Refs: HERD-1\n"},
 {"number": 2, "url": "https://x/pull/2", "body": "Refs: tracker-create-selfheal\n"},
 {"number": 3, "url": "https://x/pull/3", "body": "Refs: HERD-4242\n"},
 {"number": 4, "url": "https://x/pull/4", "body": "no ref at all\n"},
 {"number": 5, "url": "https://x/pull/5", "body": "<!-- Refs: HERD-9999 (example) -->\nreal body\n"},
 {"number": 6, "url": "https://x/pull/6", "body": "Refs: HERD-1,\n"},
 {"number": 7, "url": "https://x/pull/7", "body": "Refs: HERD-77\n"}
]
PRJSON
SWJOURNAL="$T/sweep-journal.jsonl"; : > "$SWJOURNAL"
SWOUT="$T/sweep.out"
set +e
(
  export AGENT_WATCH_LIB=1 HERD_DRIVER=headless HERMETIC_TEST=1
  export PROJECT_ROOT="$REPO" WORKTREES_DIR="$SWTREES" WORKSPACE_NAME=selfhealsweep
  export DEFAULT_BRANCH="origin/main" HERD_CONFIG_FILE="$T/no-such-config"
  export JOURNAL_FILE="$SWJOURNAL"
  export SCRIBE_BACKEND=stub SCRIBE_BACKEND_DIR="$SWBACKENDS"
  export HERD_RELINK_PR_JSON="$T/prs.json" CREATE_SELFHEAL=on
  # shellcheck source=/dev/null
  . "$WATCH" >/dev/null 2>&1 || exit 9
  # (10a) --dry-run narrates but enqueues nothing.
  _sweep_reset_counters
  sweep_leg_links 1 > "$SWOUT" 2>&1
  ls "$SWQ"/*.req >/dev/null 2>&1 && { echo "DRYRUN-ENQUEUED"; exit 1; }
  [ "$SWEEP_N_LINK" -eq 2 ] || { echo "DRYCOUNT=$SWEEP_N_LINK"; exit 2; }
  # (10b) the live run enqueues one request per unlinked PR, and only those.
  _sweep_reset_counters
  sweep_leg_links "" >> "$SWOUT" 2>&1
  [ "$SWEEP_N_LINK" -eq 2 ] || { echo "LIVECOUNT=$SWEEP_N_LINK"; exit 3; }
  # (10c) a second run is idempotent — the seen-ledger keeps it from re-filing.
  _sweep_reset_counters
  sweep_leg_links "" >> "$SWOUT" 2>&1
  [ "$SWEEP_N_LINK" -eq 0 ] || { echo "RERUNCOUNT=$SWEEP_N_LINK"; exit 4; }
  # (10d) the watcher's auto path is THROTTLED — it runs every cadence tick, and a missing tracker
  # item is hours-old debris, not a per-tick emergency. The CLI (no throttle arg) always scans.
  _sweep_relink_scan_due ""  || { echo "CLI-THROTTLED"; exit 5; }
  _sweep_relink_scan_due ""  || { echo "CLI-THROTTLED-TWICE"; exit 5; }
  _sweep_relink_scan_due 1   || { echo "AUTO-FIRST-BLOCKED"; exit 6; }
  _sweep_relink_scan_due 1   && { echo "AUTO-SECOND-NOT-THROTTLED"; exit 7; }
  exit 0
)
SWRC=$?
set -e
[ "$SWRC" -eq 0 ] || fail "(10) sweep_leg_links subshell exited $SWRC ($(cat "$SWOUT" 2>/dev/null))"
n="$(ls "$SWQ"/*relink*.req 2>/dev/null | grep -c . || true)"
[ "$n" = "2" ] || fail "(10) expected 2 relink requests queued, got $n"
ls "$SWQ" | grep -q 'relink-2' || fail "(10) the slug-only ref (PR #2) was not relinked"
ls "$SWQ" | grep -q 'relink-3' || fail "(10) the unresolvable identifier (PR #3) was not relinked"
ls "$SWQ" | grep -q 'relink-1' && fail "(10) PR #1's RESOLVABLE ref was wrongly relinked"
ls "$SWQ" | grep -q 'relink-4' && fail "(10) a ref-less PR was wrongly relinked"
ls "$SWQ" | grep -q 'relink-5' && fail "(10) a Refs: inside an HTML comment poisoned the extractor"
ls "$SWQ" | grep -q 'relink-6' && fail "(10) 'Refs: HERD-1,' — trailing punctuation — was read as a non-identifier and relinked"
ls "$SWQ" | grep -q 'relink-7' && fail "(10) an UNPROVEN ref (the tracker would not answer) was relinked"
grep -q '"event":"link_heal"' "$SWJOURNAL"   || fail "(10) the relink was not journaled"
grep -q '"result":"unproven"' "$SWJOURNAL"   || fail "(10) the leg did not journal that it stood down on an unanswerable ref"
grep -q '🔗' "$SWOUT"                        || fail "(10) the leg narrated nothing"
grep -q '⏸' "$SWOUT"                         || fail "(10) the stand-down was not narrated"
head -n1 "$SWQ"/*relink-2*.req | grep -q '^Relink merged PR #2' \
  || fail "(10) the relink request's first line is not a short title (linear turns it into the issue title)"
grep -q 'SEARCH FIRST' "$SWQ"/*relink-2*.req || fail "(10) the relink request does not instruct a search before filing"
ok; echo "PASS (10) relink acts only on a PROVABLE miss: punctuation, comments, and unanswerable refs are left alone"

# ══ (15) A TRACKER OUTAGE IS NOT PROOF THAT THE ITEM IS MISSING ═══════════════════════════════════
# The blocking regression. sweep_run_safe_legs calls this leg with dry="" on every watcher tick, so
# reading "the API did not answer" as "the item was never created" writes up to HERD_RELINK_LIMIT
# duplicate scribe requests and stamps each PR into the one-way seen-ledger. It fires co-incident with
# an expired key — exactly when create_retry_class is correctly calling creates auth/permanent.
# Two shapes must both stand down: a tracker that is DOWN, and a backend with no tri-state probe at all.
for backend in down noprobe; do
  DTREES="$T/dtrees-$backend"; DQ="$DTREES/backlog-queue"; mkdir -p "$DTREES"
  DJ="$T/d-$backend.jsonl"; : > "$DJ"
  set +e
  (
    export AGENT_WATCH_LIB=1 HERD_DRIVER=headless HERMETIC_TEST=1
    export PROJECT_ROOT="$REPO" WORKTREES_DIR="$DTREES" WORKSPACE_NAME=selfhealdown
    export DEFAULT_BRANCH="origin/main" HERD_CONFIG_FILE="$T/no-such-config"
    export JOURNAL_FILE="$DJ" SCRIBE_BACKEND="$backend" SCRIBE_BACKEND_DIR="$SWBACKENDS"
    export HERD_RELINK_PR_JSON="$T/prs.json" CREATE_SELFHEAL=on
    # shellcheck source=/dev/null
    . "$WATCH" >/dev/null 2>&1 || exit 9
    _sweep_reset_counters
    sweep_leg_links "" > "$T/down-$backend.out" 2>&1
    # ONLY the slug-only PR #2 is provable without a lookup. Every identifier is UNPROVEN.
    [ "$SWEEP_N_LINK" -eq 1 ] || { echo "COUNT=$SWEEP_N_LINK"; exit 3; }
    exit 0
  )
  DRC=$?
  set -e
  [ "$DRC" -eq 0 ] || fail "(15) [$backend] leg exited $DRC ($(cat "$T/down-$backend.out" 2>/dev/null))"
  m="$(ls "$DQ"/*relink*.req 2>/dev/null | grep -c . || true)"
  [ "$m" = "1" ] || fail "(15) [$backend] an unreachable/unprobeable tracker enqueued $m relinks — duplicates incoming"
  ls "$DQ" | grep -q 'relink-2' || fail "(15) [$backend] the slug-only ref stopped relinking (it needs no lookup)"
  ls "$DQ" | grep -q 'relink-1' && fail "(15) [$backend] an outage was read as proof that HERD-1 is missing"
  ls "$DQ" | grep -q 'relink-3' && fail "(15) [$backend] an outage was read as proof that HERD-4242 is missing"
  grep -q '"result":"unproven"' "$DJ" || fail "(15) [$backend] the stand-down was not journaled"
  grep -q '⏸' "$T/down-$backend.out"  || fail "(15) [$backend] a zero-finding sweep silently hid the outage"
done
ok; echo "PASS (15) an unreachable / unprobeable tracker never proves an item missing (no duplicate filings)"

# ══ (16) linear.sh's TRI-STATE probe tells 'nothing there' from 'no answer' ═══════════════════════
export LINEAR_API_KEY=x
# shellcheck source=/dev/null
. "$LINEAR" >/dev/null 2>&1
_probe() { _linear_gql() { printf '%s' "$STUBRESP"; }; _backend_item_missing HERD-267; printf '%s' "$?"; }
STUBRESP='{"data":{"issues":{"nodes":[]}}}';                     [ "$(_probe)" = 0 ] || fail "(16) a clean zero-match answer is not PROVABLY MISSING"
STUBRESP='{"data":{"issues":{"nodes":[{"identifier":"HERD-267"}]}}}'; [ "$(_probe)" = 1 ] || fail "(16) a resolved issue is not EXISTS"
STUBRESP='{"errors":[{"message":"Authentication required","extensions":{"code":"AUTHENTICATION_ERROR"}}]}'
[ "$(_probe)" = 2 ] || fail "(16) an AUTH error was read as 'missing' — an expired key would relink every PR"
STUBRESP='{"errors":[{"message":"Rate limit exceeded","extensions":{"code":"RATELIMITED"}}],"data":null}'
[ "$(_probe)" = 2 ] || fail "(16) a RATE LIMIT was read as 'missing'"
STUBRESP=''                                                    ; [ "$(_probe)" = 2 ] || fail "(16) an empty body (unreachable host) was read as 'missing'"
STUBRESP='<html>502 Bad Gateway</html>'                        ; [ "$(_probe)" = 2 ] || fail "(16) an unparseable body was read as 'missing'"
STUBRESP='{"data":{}}'                                         ; [ "$(_probe)" = 2 ] || fail "(16) a data envelope with no issues key was read as 'missing'"
# A curl that cannot reach the host: _linear_gql itself fails.
_linear_gql() { return 7; }; [ "$(_backend_item_missing HERD-267 >/dev/null 2>&1; printf '%s' "$?")" = 2 ] \
  || fail "(16) a transport failure was read as 'missing'"
ok; echo "PASS (16) linear's tri-state probe: missing / exists / UNPROVEN are three distinct answers"

# ══ (17) THE Refs: EXTRACTOR IS ONE IMPLEMENTATION, SHARED ═══════════════════════════════════════
# sweep.sh must not carry a second copy of merge-time reconcile's parser (docs/multi-seat-doctrine.md).
grep -q 'HERD_PR_REF_PY' "$HERE/../scripts/herd/agent-watch.sh" || fail "(17) the shared extractor is gone"
grep -q 'HERD_PR_REF_PY' "$HERE/../scripts/herd/sweep.sh" \
  || fail "(17) sweep.sh no longer reuses the shared Refs: extractor"
grep -q 'refs:' "$HERE/../scripts/herd/sweep.sh" \
  && fail "(17) sweep.sh re-implements the Refs: regex instead of reusing HERD_PR_REF_PY"
ok; echo "PASS (17) one Refs: implementation, reused at both surfaces"

echo "ALL PASS ($PASS checks)"
