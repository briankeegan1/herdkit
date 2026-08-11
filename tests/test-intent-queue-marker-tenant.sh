#!/usr/bin/env bash
# test-intent-queue-marker-tenant.sh — HERD-639 (Phase 2 of HERD-625): the intent queue's SECOND
# TENANT — M3 queue-marker publish/supersede (docs/spikes/coordinator-work-queue.md §1.3, §2.2, §6) —
# riding the shared library end to end.
#
# WHY THIS FILE IS THE POINT OF PHASE 2. Phase 1 wrote its queue policy extraction-shaped by DISCIPLINE
# (§8's named risk). Extracting it into scripts/herd/intent-queue.sh only resolves that risk if a
# NON-SPAWN intent actually rides the same rails — otherwise "the substrate generalizes" is an
# assertion about code shape rather than an observed property. So this test follows one marker intent
# through every stage the doc names: ENQUEUE → the watcher's DRAIN → the EXISTING
# _backend_queue_item / _backend_unqueue_item paths → the JOURNAL, and asserts the failure semantics
# (§4.3) and the ship-dormant lever (§6) around it.
#
# It also closes a MEASURED gap, not a hypothetical one: on 2026-08-10, three 📌 markers were published
# and ZERO were ever superseded (§1.3) — one outlived its own claim by 90+ minutes, another was still
# live on an item closed Done — because nothing but a hand-run `herd backlog unqueue` ever cleared one.
#
# Cases:
#   (1) LEVER OFF          nothing enqueues and the drain returns on a NON-EMPTY queue: byte-identical.
#   (2) PUBLISH e2e        enqueue → drain → _backend_queue_item(ref, who, detail) with the same
#                          HERD_COMPONENT=plan attribution `herd backlog queue` uses → journal
#                          intent_marker_published → the intent is consumed.
#   (3) SUPERSEDE e2e      the same rails into _backend_unqueue_item → intent_marker_superseded.
#   (4) CONVERGENT         supersede + NOCHANGE ("no marker to clear") is the state the intent asked
#                          for → consumed, not retried (§5.3).
#   (5) TRANSIENT          publish + NOCHANGE → RELEASED with its attempt counter bumped, and dropped
#                          loudly once past INTENT_MAX_ATTEMPTS (§4.3: never silently, never forever).
#   (6) NO BACKEND OP      a backend with no planned-marker op is fail-soft terminal (§4.1), not a
#                          retry loop against a capability that will never appear.
#   (7) MALFORMED          unknown kind / empty ref / past INTENT_TTL are each skipped with a journal
#                          row, and the drain keeps going.
#   (8) BUDGET             one tick drains at most INTENT_DRAIN_BUDGET marker intents.
#   (9) PRODUCER: SPAWN    the REAL spawn.sh publishes a marker-publish intent for a TRACKED spawn
#                          under the lever, and NONE with it off.
#  (10) PRODUCER: CLAIM    the REAL _drain_lane_worker enqueues marker-supersede the moment a lane
#                          observably launched — the supersede trigger §1.3 says fires today for
#                          nobody — and that intent then drains into _backend_unqueue_item.
#
# Hermetic: temp dirs only. No network, no herdr, no real lanes, no tracker. The drain functions are
# EXTRACTED from agent-watch.sh (sed) exactly as tests/test-spawn-queue-drain.sh extracts them, the
# library is the shipped scripts/herd/intent-queue.sh, the lever resolver is extracted verbatim from
# the real herd-config.sh, and the backend is a STUB behind the engine's own SCRIBE_BACKEND_DIR seam —
# so the code under test is the shipped code all the way down to the backend boundary.
#
# Run:  bash tests/test-intent-queue-marker-tenant.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"
LIB="$REPO/scripts/herd/intent-queue.sh"
STEP="$REPO/scripts/herd/spawn-step.sh"
SPAWN="$REPO/scripts/herd/spawn.sh"
CONFIG="$REPO/scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "$WATCH" "$LIB" "$STEP" "$SPAWN" "$CONFIG"; do [ -f "$f" ] || fail "missing engine file: $f"; done

TREES="$T/trees"; mkdir -p "$TREES"
IQ="$TREES/intent-queue"
MAIN="$T/main"; mkdir -p "$MAIN/.herd"

# ── The extracted drain + the shipped library + the shipped lever ────────────────────────────────
DRAIN_SRC="$T/drain.sh"
: > "$DRAIN_SRC"
for fn in _intent_marker_apply _drain_intent_queue _intent_consume _intent_marker_enqueue \
          _drain_lane_worker; do
  sed -n "/^$fn()/,/^}/p" "$WATCH" >> "$DRAIN_SRC"
  grep -q "^$fn()" "$DRAIN_SRC" || fail "could not extract $fn from agent-watch.sh"
done
LEVER="$T/lever.sh"
sed -n '/^herd_intent_queue_on()/,/^}/p' "$CONFIG" > "$LEVER"
grep -q '^herd_intent_queue_on()' "$LEVER" || fail "could not extract herd_intent_queue_on from herd-config.sh"

# ── The STUB backend, reached through the engine's own SCRIBE_BACKEND_DIR seam ───────────────────
# Records every call ("<op>\t<ref>\t<who>\t<detail>\t<component>") and returns the verdict named by
# $BACKEND_MODE, so each case scripts DONE / NOCHANGE without a tracker, a git remote or a network.
BDIR="$T/backends"; mkdir -p "$BDIR"
cat > "$BDIR/stub.sh" <<'STUB'
_backend_queue_item() {
  printf 'queue\t%s\t%s\t%s\t%s\n' "$1" "${2:-}" "${3:-}" "${HERD_COMPONENT:-}" >> "$BACKEND_LOG"
  _BACKEND_RESULT="$(cat "$BACKEND_MODE" 2>/dev/null || echo DONE)"
}
_backend_unqueue_item() {
  printf 'unqueue\t%s\t%s\t\t%s\n' "$1" "${2:-}" "${HERD_COMPONENT:-}" >> "$BACKEND_LOG"
  _BACKEND_RESULT="$(cat "$BACKEND_MODE" 2>/dev/null || echo DONE)"
}
STUB
# A backend that HAS no planned-marker op at all (the file/github/jira split is real: the ops are
# OPTIONAL, per backends/*.sh).
printf '_backend_list_open() { :; }\n' > "$BDIR/noop.sh"

export BACKEND_LOG="$T/backend.log"
export BACKEND_MODE="$T/backend.mode"
JLOG="$T/journal.log"
echo DONE > "$BACKEND_MODE"

# tick — one _drain_intent_queue pass with the tick globals the extracted drain reads.
# $1 (optional) overrides SCRIBE_BACKEND for that pass.
tick() {
  ( HERE="$REPO/scripts/herd"; TREES="$TREES"; MAIN="$MAIN"; DRYRUN=""
    INTENT_QUEUE_DIR="$IQ"; INTENT_DRAIN_BUDGET="${BUDGET:-4}"; INTENT_MAX_ATTEMPTS=3
    INTENT_TTL="${TTL:-86400}"
    SCRIBE_BACKEND="${1:-stub}"; SCRIBE_BACKEND_DIR="$BDIR"
    journal_append(){ printf '%s\n' "$*" >> "$JLOG"; }
    IQ_ENGINE_DIR="$T/nowhere"                    # journal.sh is never reached from the library here
    # shellcheck source=/dev/null
    . "$LEVER"; . "$LIB"; . "$DRAIN_SRC"
    _drain_intent_queue )
}
# enqueue_marker <kind> <ref> <who> <detail> — through the SHIPPED producer (_intent_marker_enqueue).
enqueue_marker() {
  ( TREES="$TREES"; INTENT_QUEUE_DIR="$IQ"
    IQ_ENGINE_DIR="$T/nowhere"
    # shellcheck source=/dev/null
    . "$LEVER"; . "$LIB"; . "$DRAIN_SRC"
    _intent_marker_enqueue "$@" )
}
reqs(){ ls "$IQ"/*.req 2>/dev/null | wc -l | tr -d ' '; }
reset(){ rm -rf "$IQ"; : > "$BACKEND_LOG"; : > "$JLOG"; echo DONE > "$BACKEND_MODE"; }

# ── (1) LEVER OFF — nothing enqueues, and a non-empty queue is not drained ───────────────────────
reset
unset INTENT_QUEUE
enqueue_marker marker-publish HERD-639 alice "sequenced next"
[ -d "$IQ" ] && [ "$(reqs)" != "0" ] && fail "(1) the lever is OFF but an intent was enqueued"
# Seed one by hand (as an armed seat would have left behind) and prove the drain ignores it whole.
mkdir -p "$IQ"; printf 'marker-publish\nHERD-639\nalice\nd\n' > "$IQ/9999999999-0000000001-1.req"
tick
[ "$(reqs)" = "1" ] || fail "(1) the lever is OFF but the drain consumed an intent"
[ -s "$BACKEND_LOG" ] && fail "(1) the lever is OFF but the drain issued a backend write"
[ -s "$JLOG" ] && fail "(1) the lever is OFF but the drain journaled"
pass

export INTENT_QUEUE=on

# ── (2) PUBLISH end to end ───────────────────────────────────────────────────────────────────────
reset
enqueue_marker marker-publish HERD-639 alice "sequenced next"
[ "$(reqs)" = "1" ] || fail "(2) the producer did not publish an intent into the queue"
tick
[ "$(reqs)" = "0" ] || fail "(2) the drained intent was not consumed"
grep -q "^queue	HERD-639	alice	sequenced next	plan$" "$BACKEND_LOG" \
  || fail "(2) _backend_queue_item was not called through the plan component ($(cat "$BACKEND_LOG"))"
grep -q "intent_marker_published .*kind marker-publish ref HERD-639 result done" "$JLOG" \
  || fail "(2) intent_marker_published not journaled ($(cat "$JLOG"))"
# (the queue's own dotfiles — the .seq counter and its lock — are queue state, not intent state)
[ -z "$(ls "$IQ" 2>/dev/null)" ] || fail "(2) the consumed intent left sidecars behind: $(ls "$IQ")"
pass

# ── (3) SUPERSEDE end to end ─────────────────────────────────────────────────────────────────────
reset
enqueue_marker marker-supersede HERD-639 alice "claimed by feat-x"
tick
[ "$(reqs)" = "0" ] || fail "(3) the supersede intent was not consumed"
grep -q "^unqueue	HERD-639	alice		plan$" "$BACKEND_LOG" \
  || fail "(3) _backend_unqueue_item was not called ($(cat "$BACKEND_LOG"))"
grep -q "intent_marker_superseded .*kind marker-supersede ref HERD-639 result done" "$JLOG" \
  || fail "(3) intent_marker_superseded not journaled ($(cat "$JLOG"))"
pass

# ── (4) CONVERGENT: supersede + NOCHANGE is the requested state, not a failure ───────────────────
reset
echo NOCHANGE > "$BACKEND_MODE"
enqueue_marker marker-supersede HERD-639 alice ""
tick
[ "$(reqs)" = "0" ] || fail "(4) a supersede that found nothing to clear was retried — it had already converged"
grep -q "intent_marker_superseded .*result nochange" "$JLOG" \
  || fail "(4) the convergent supersede was not journaled honestly ($(cat "$JLOG"))"
pass

# ── (5) TRANSIENT: publish + NOCHANGE releases, accrues attempts, then drops LOUDLY ──────────────
reset
echo NOCHANGE > "$BACKEND_MODE"
enqueue_marker marker-publish HERD-777 alice "sequenced next"
id="$(basename "$(ls "$IQ"/*.req)" .req)"
tick
[ "$(reqs)" = "1" ] || fail "(5) a transient failure must RELEASE the intent for a later tick"
[ "$(cat "$IQ/$id.attempts" 2>/dev/null)" = "1" ] || fail "(5) the attempt counter did not accrue"
grep -q "intent_deferred .*attempts 1 result NOCHANGE" "$JLOG" || fail "(5) the defer was not journaled ($(cat "$JLOG"))"
tick                                        # attempt 2 — still released
[ "$(reqs)" = "1" ] || fail "(5) attempt 2 must still release"
tick                                        # attempt 3 = INTENT_MAX_ATTEMPTS — dropped
[ "$(reqs)" = "0" ] || fail "(5) an intent past INTENT_MAX_ATTEMPTS must leave the queue (never loop forever)"
grep -q "intent_skipped .*attempts 3 reason max attempts" "$JLOG" \
  || fail "(5) the drop past max attempts was not journaled ($(cat "$JLOG"))"
[ -f "$IQ/$id.attempts" ] && fail "(5) the attempts sidecar outlived its intent"
pass

# ── (6) A BACKEND WITH NO MARKER OP is fail-soft terminal ────────────────────────────────────────
reset
enqueue_marker marker-publish HERD-639 alice "sequenced next"
tick noop
[ "$(reqs)" = "0" ] || fail "(6) an intent must not retry against a backend that has no marker op"
[ -s "$BACKEND_LOG" ] && fail "(6) the noop backend somehow recorded a write"
grep -q "intent_marker_published .*result no-backend-op" "$JLOG" \
  || fail "(6) the fail-soft skip was not journaled ($(cat "$JLOG"))"
pass

# ── (7) MALFORMED intents are skipped, and the drain keeps going ─────────────────────────────────
reset
mkdir -p "$IQ"
printf 'marker-teleport\nHERD-639\nalice\nd\n' > "$IQ/9999999990-0000000001-1.req"   # unknown kind
printf 'marker-publish\n\nalice\nd\n'          > "$IQ/9999999990-0000000002-1.req"   # no ref
printf 'marker-publish\nHERD-1\nalice\nd\n'    > "$IQ/1-0000000003-1.req"            # enqueued at epoch 1
printf 'marker-publish\nHERD-OK\nalice\nd\n'   > "$IQ/9999999990-0000000004-1.req"   # the good one
tick 2>/dev/null
[ "$(reqs)" = "0" ] || fail "(7) the drain did not clear the malformed intents ($(ls "$IQ"))"
grep -q "intent_skipped .*reason unknown kind" "$JLOG"        || fail "(7) unknown kind not journaled ($(cat "$JLOG"))"
grep -q "intent_skipped .*reason empty kind or ref" "$JLOG"   || fail "(7) empty ref not journaled"
grep -q "intent_skipped .*reason aged past INTENT_TTL" "$JLOG" || fail "(7) the TTL skip did not fire on a day-stale intent"
grep -q "^queue	HERD-OK	" "$BACKEND_LOG" \
  || fail "(7) the drain stopped at a bad intent instead of continuing to the good one"
grep -q "^queue	HERD-1	" "$BACKEND_LOG" && fail "(7) a day-stale intent was WRITTEN to the tracker"
pass

# ── (8) BUDGET: one tick drains at most INTENT_DRAIN_BUDGET ──────────────────────────────────────
reset
mkdir -p "$IQ"
for n in 1 2 3 4 5 6; do
  printf 'marker-publish\nHERD-B%s\nalice\nd\n' "$n" > "$IQ/9999999991-000000000$n-1.req"
done
BUDGET=2 tick
[ "$(reqs)" = "4" ] || fail "(8) one tick must drain exactly its budget (2), left $(reqs) of 6"
[ "$(wc -l < "$BACKEND_LOG" | tr -d ' ')" = "2" ] || fail "(8) the budget did not bound the backend writes"
pass

# ── (9) PRODUCER: the REAL spawn.sh publishes a marker intent for a TRACKED spawn ────────────────
# Pin the project config via HERD_CONFIG_FILE (the seam every other CLI test uses) so an intent can
# never land in a real project's pool.
reset
PROJ="$T/proj"; mkdir -p "$PROJ/.herd"
cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKSPACE_NAME="testws"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$TREES"
EOF
( cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" INTENT_QUEUE=on HERD_ITEM_REF=HERD-639 \
    bash "$SPAWN" prod-slug quick "a tracked spawn" >/dev/null ) || fail "(9) spawn.sh failed"
[ "$(reqs)" = "1" ] || fail "(9) a TRACKED spawn under the lever published no marker intent"
q="$(ls "$IQ"/*.req)"
[ "$(sed -n 1p "$q")" = "marker-publish" ] || fail "(9) the wrong intent kind was published"
[ "$(sed -n 2p "$q")" = "HERD-639" ]       || fail "(9) the published intent carries the wrong ref"
rm -rf "$IQ" "$TREES/spawn-queue"
( cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" INTENT_QUEUE=off HERD_ITEM_REF=HERD-639 \
    bash "$SPAWN" prod-off quick "a tracked spawn" >/dev/null ) || fail "(9) spawn.sh failed with the lever off"
[ -d "$IQ" ] && fail "(9) the lever is OFF but spawn.sh created the intent queue — the enqueue is not byte-identical"
ls "$TREES/spawn-queue"/*.req >/dev/null 2>&1 || fail "(9) the lever-off enqueue did not queue the SPAWN itself"
pass

# ── (10) PRODUCER: a launched lane supersedes its own marker, and that intent drains ─────────────
# The §1.3 finding, inverted into an assertion: the CLAIM is the supersede trigger, and today nothing
# fires it. Drive the SHIPPED _drain_lane_worker with a fake lane and assert the intent it leaves
# behind reaches _backend_unqueue_item.
reset
rm -rf "$TREES/spawn-queue"; mkdir -p "$TREES/spawn-queue"
ENG="$T/eng"; mkdir -p "$ENG"
cp "$STEP" "$ENG/spawn-step.sh"
printf 'WORKTREES_DIR="%s"\nexport WORKTREES_DIR\n' "$TREES" > "$ENG/herd-config.sh"
cat > "$ENG/herd-quick.sh" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$ENG/herd-quick.sh"
printf 'lane-slug\nquick\nthe task\n' > "$TREES/spawn-queue/9999999992-0000000001-1.req"
claimed="$(WORKTREES_DIR="$TREES" bash "$ENG/spawn-step.sh" next | sed -n 1p)"
claimed="${claimed#CLAIMED }"
[ -f "$claimed" ] || fail "(10) could not claim the seed spawn intent"
( HERE="$ENG"; TREES="$TREES"; INTENT_QUEUE_DIR="$IQ"; WATCHER_OWNER="alice"
  IQ_ENGINE_DIR="$T/nowhere"
  journal_append(){ printf '%s\n' "$*" >> "$JLOG"; }
  # shellcheck source=/dev/null
  . "$LEVER"; . "$LIB"; . "$DRAIN_SRC"
  _drain_lane_worker "$claimed" lane-slug quick HERD-639 "the task" )
grep -q "spawn_launched slug lane-slug" "$JLOG" || fail "(10) the fake lane did not land ($(cat "$JLOG"))"
[ "$(reqs)" = "1" ] || fail "(10) a launched lane left NO supersede intent — §1.3's zero-supersede finding is unfixed"
q="$(ls "$IQ"/*.req)"
[ "$(sed -n 1p "$q")" = "marker-supersede" ] || fail "(10) the launched lane queued the wrong intent kind"
[ "$(sed -n 2p "$q")" = "HERD-639" ]         || fail "(10) the supersede intent carries the wrong ref"
tick
grep -q "^unqueue	HERD-639	alice		plan$" "$BACKEND_LOG" \
  || fail "(10) the lane's supersede intent never reached _backend_unqueue_item ($(cat "$BACKEND_LOG"))"
grep -q "intent_marker_superseded .*ref HERD-639" "$JLOG" || fail "(10) the supersede was not journaled"
pass

echo "ALL PASS ($PASS checks)"
