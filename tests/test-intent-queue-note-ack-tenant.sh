#!/usr/bin/env bash
# test-intent-queue-note-ack-tenant.sh — HERD-640 (Phase 3 of HERD-625): the intent queue's M4 tenant —
# note-ack-after-route (docs/spikes/coordinator-work-queue.md §1.4, §2.2 M4, §6 Phase 3).
#
# THE SPLIT THIS FILE PINS. §1.4 measured five builder notes on 2026-08-10: four were acked by hand
# after the coordinator routed them, and the fifth was never acked at all — it aged out of the display
# on its own two hours later, which is indistinguishable on screen from "handled". The doc's reading is
# that ROUTING IS JUDGMENT and ACKING IS BOOKKEEPING, so only the second half may leave the seat, and
# only when the artifact the routing promised is OBSERVABLE. A note routed as "dismiss — informational"
# has no artifact at all, and these cases assert it is never auto-acked rather than merely documenting
# that it should not be.
#
# Cases:
#   (1) LEVER OFF        the route scan is a hard no-op: nothing enqueued, the pending row untouched.
#   (2) PRODUCER         `herd notes route <n> item:<ref>` records the note's VERBATIM ledger line
#                        against its artifact and acks NOTHING yet; with no artifact it REFUSES
#                        (the dismiss case) and points at `herd notes ack`.
#   (3) WAITS            an artifact that does not resolve yet queues nothing and keeps the row —
#                        the wait is a durable scan, never an intent burning its attempt budget.
#   (4) ITEM ARTIFACT    the item resolving in the tracker enqueues ONE note-ack intent, which the
#                        drain executes into the SAME ack ledger `herd notes ack` writes, so the note
#                        leaves the console and the journal keeps it.
#   (5) PR ARTIFACT      a re-task's PR that LANDED (the reap ledger — the same predicate a HERD-94
#                        dependency hold uses) is equally an artifact.
#   (6) DISMISS          a note with no route row is never touched by the scan, however many passes run.
#   (7) IDEMPOTENT       a second ack for the same note is CONVERGED, and the ack ledger gains no
#                        duplicate line.
#   (8) GC               a route whose note has already left the console retires quietly.
#   (9) ONE SUBSTRATE    the producer publishes through the shared library (iq_enqueue) and the
#                        consumer clears through the shared ack ledger — no second implementation of
#                        either, which is the property Phase 2 exists to keep.
#
# Hermetic: temp dirs only, no network, no live watcher. The scan/drain functions are EXTRACTED from
# agent-watch.sh (sed) exactly as tests/test-intent-queue-marker-tenant.sh extracts them — they live
# below the AGENT_WATCH_LIB early return, which is why lib-mode sourcing is not an option here — and
# everything under them is the shipped code: the shared intent-queue library, the shared
# console-section ack helpers, the real journal and the real `herd notes route` CLI.
# Run:  bash tests/test-intent-queue-note-ack-tenant.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"
HERD_BIN="$REPO/bin/herd"
LIB="$REPO/scripts/herd/intent-queue.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
for f in "$WATCH" "$HERD_BIN" "$LIB"; do [ -f "$f" ] || fail "missing engine file: $f"; done

MAIN="$T/main"; TREES="$T/trees"
mkdir -p "$MAIN/.herd" "$TREES"

# ── the STUB backend, behind the engine's own SCRIBE_BACKEND_DIR seam ────────────────────────────
# STUB_ITEMS lists the refs the tracker can resolve; anything else fails to resolve, which is exactly
# the "the scribe's create has not landed yet" state M4 must wait through.
BDIR="$T/backends"; mkdir -p "$BDIR"
cat > "$BDIR/stub.sh" <<'STUB'
_backend_item_state() {
  if grep -Fxq -- "$1" "$STUB_ITEMS" 2>/dev/null; then ITEM_STATE="open"; return 0; fi
  ITEM_STATE=""; return 1
}
STUB
export STUB_ITEMS="$T/items.txt"; : > "$STUB_ITEMS"

cat > "$MAIN/.herd/config" <<EOF
PROJECT_ROOT="$MAIN"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH=main
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="stub"
EOF

BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

export HERD_CONFIG_FILE="$MAIN/.herd/config"
export WORKTREES_DIR="$TREES"
export PROJECT_ROOT="$MAIN"
export WORKSPACE_NAME="note-ack-test"
export SCRIBE_BACKEND="stub"
export SCRIBE_BACKEND_DIR="$BDIR"
export JOURNAL_FILE="$TREES/journal.jsonl"
export NO_COLOR=1
export INTENT_QUEUE=off

# ── the SHIPPED code under test: the scan/drain functions, the library, the lever, the ack helpers ──
SRC="$T/watch-fns.sh"; : > "$SRC"
for fn in _note_artifact_exists _scan_note_routes _intent_note_ack_apply _intent_marker_apply \
          _intent_evidence_apply _drain_intent_queue _intent_consume _spawn_dep_merged; do
  sed -n "/^$fn()/,/^}/p" "$WATCH" >> "$SRC"
  grep -q "^$fn()" "$SRC" || fail "could not extract $fn from agent-watch.sh"
done
# shellcheck source=/dev/null
. "$REPO/scripts/herd/herd-config.sh"          # the ONE lever resolver (herd_intent_queue_on)
# shellcheck source=/dev/null
. "$REPO/scripts/herd/console-section.sh"      # herd_console_acked / _trim / the visibility rule
# shellcheck source=/dev/null
. "$REPO/scripts/herd/journal.sh"              # the real journal, pinned to JOURNAL_FILE
IQ_ENGINE_DIR="$REPO/scripts/herd"
# shellcheck source=/dev/null
. "$LIB"
# shellcheck source=/dev/null
. "$SRC"
# The tick globals the extracted functions read, resolved exactly as the watcher resolves them.
HERE="$REPO/scripts/herd"
TREES="$TREES"; MAIN="$MAIN"; DRYRUN=""
STATE="$TREES/.agent-watch-merged"
INTENT_QUEUE_DIR="$TREES/intent-queue"
INTENT_DRAIN_BUDGET=4; INTENT_MAX_ATTEMPTS=3; INTENT_TTL=86400
BUILDER_NOTES_LEDGER="$TREES/.agent-watch-builder-notes"
BUILDER_NOTES_ACK="$TREES/.agent-watch-builder-notes-acked"
BUILDER_NOTES_ROUTES="$TREES/.agent-watch-builder-notes-routes"
BUILDER_NOTES_LEDGER_MAX="$CONSOLE_LEDGER_MAX"
WATCHER_OWNER="alice"
# _spawn_dep_merged's gh FALLBACK, stubbed to "not merged" so only the reap ledger can answer yes.
_gh_timeout(){ return 1; }
for fn in _scan_note_routes _note_artifact_exists _intent_note_ack_apply _drain_intent_queue \
          iq_enqueue herd_console_acked herd_intent_queue_on _spawn_dep_merged; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after wiring the harness"
done

NOW="$(date +%s)"
note_line(){ printf '%s\t%s\t%s\t%s' "$NOW" "$1" "$2" "2026-08-11T12:00:00Z"; }
reqs(){ ls "$INTENT_QUEUE_DIR"/*.req 2>/dev/null | wc -l | tr -d ' '; }
routes(){ grep -c . "$BUILDER_NOTES_ROUTES" 2>/dev/null || echo 0; }
visible(){ herd_console_visible_lines "$BUILDER_NOTES_LEDGER" 5 herd_console_classify_builder_note "$BUILDER_NOTES_ACK"; }
reset() {
  rm -rf "$INTENT_QUEUE_DIR" "$BUILDER_NOTES_ROUTES" "$BUILDER_NOTES_ACK" "$BUILDER_NOTES_LEDGER" \
         "$JOURNAL_FILE" "$STATE"
  : > "$STUB_ITEMS"
}
# route <n> <artifact> — the REAL producer CLI.
route(){ ( cd "$MAIN" && bash "$HERD_BIN" notes route "$@" ); }

# ── (1) LEVER OFF — the scan is a hard no-op ─────────────────────────────────────────────────────
reset
note_a="$(note_line feat-alpha "the caps guard reds on a stale row")"
printf '%s\n' "$note_a" > "$BUILDER_NOTES_LEDGER"
printf 'HERD-641\n' > "$STUB_ITEMS"
printf '%s\titem\tHERD-641\t%s\n' "$NOW" "$note_a" > "$BUILDER_NOTES_ROUTES"
INTENT_QUEUE=off _scan_note_routes
[ -d "$INTENT_QUEUE_DIR" ] && fail "(1) the lever is OFF but the scan created the intent queue"
[ "$(routes)" = "1" ] || fail "(1) the lever is OFF but the scan consumed the pending route"
[ -s "$BUILDER_NOTES_ACK" ] && fail "(1) the lever is OFF but a note was acked"
pass

export INTENT_QUEUE=on

# ── (2) PRODUCER — `herd notes route` records the artifact and acks NOTHING ──────────────────────
reset
note_a="$(note_line feat-alpha "the caps guard reds on a stale row")"
printf '%s\n' "$note_a" > "$BUILDER_NOTES_LEDGER"
out="$(route 1 item:HERD-641 2>&1)" || fail "(2) herd notes route failed: $out"
[ "$(routes)" = "1" ] || fail "(2) the routing recorded no pending row ($out)"
row="$(cat "$BUILDER_NOTES_ROUTES")"
[ "$(printf '%s' "$row" | cut -f2)" = "item" ]     || fail "(2) wrong artifact kind: $row"
[ "$(printf '%s' "$row" | cut -f3)" = "HERD-641" ] || fail "(2) wrong artifact: $row"
[ "$(printf '%s' "$row" | cut -f4-)" = "$note_a" ] \
  || fail "(2) the route does not carry the note's VERBATIM ledger line — the ack could never match it"
[ -s "$BUILDER_NOTES_ACK" ] && fail "(2) routing acked the note immediately — routing is not acking"
[ -n "$(visible)" ] || fail "(2) the note left the console before its artifact existed"
# DISMISS: no artifact, no row, and the refusal names the manual path.
out="$(route 1 2>&1)" && fail "(2) a routing with NO artifact was accepted — a dismissed note must never be auto-acked"
case "$out" in *"herd notes ack"*) ;; *) fail "(2) the refusal does not point at the manual ack path: $out" ;; esac
[ "$(routes)" = "1" ] || fail "(2) the refused routing still wrote a row"
pass

# ── (3) WAITS — an artifact that does not resolve yet queues nothing and keeps the row ───────────
: > "$STUB_ITEMS"          # the scribe's create has not landed
_scan_note_routes
[ -d "$INTENT_QUEUE_DIR" ] && fail "(3) an unresolved artifact enqueued an intent"
[ "$(routes)" = "1" ] || fail "(3) the pending route was dropped while still waiting"
[ -n "$(visible)" ] || fail "(3) the note left the console while its artifact did not exist"
pass

# ── (4) ITEM ARTIFACT — it resolves ⇒ one intent ⇒ the drain acks the note ───────────────────────
printf 'HERD-641\n' > "$STUB_ITEMS"
_scan_note_routes
[ "$(reqs)" = "1" ] || fail "(4) a resolved artifact enqueued no note-ack intent"
q="$(ls "$INTENT_QUEUE_DIR"/*.req)"
[ "$(sed -n 1p "$q")" = "note-ack" ]      || fail "(4) wrong intent kind: $(sed -n 1p "$q")"
[ "$(sed -n 2p "$q")" = "item:HERD-641" ] || fail "(4) wrong artifact on the intent: $(sed -n 2p "$q")"
[ "$(sed -n 4p "$q")" = "$note_a" ]       || fail "(4) the intent does not carry the note line verbatim"
[ "$(routes)" = "0" ] || fail "(4) the route row outlived the intent it became"
[ -n "$(visible)" ] || fail "(4) the note left the console BEFORE the ack intent drained"
_drain_intent_queue
[ "$(reqs)" = "0" ] || fail "(4) the note-ack intent was not consumed"
herd_console_acked "$BUILDER_NOTES_ACK" "$note_a" || fail "(4) the note's exact ledger line is not in the ack ledger"
[ -z "$(visible)" ] || fail "(4) the note is still on the console after its ack"
grep -q '"event":"intent_note_acked"' "$JOURNAL_FILE" || fail "(4) the ack was not journaled"
grep -Fq -- "$(printf '%s' "$note_a" | cut -f3)" "$BUILDER_NOTES_LEDGER" \
  || fail "(4) the ack destroyed the note ledger — an ack is DISPLAY-only"
pass

# ── (5) PR ARTIFACT — a landed re-task PR is equally an artifact ─────────────────────────────────
reset
note_b="$(note_line feat-beta "bounced: the fix needs the resolver, not a rebase")"
printf '%s\n' "$note_b" > "$BUILDER_NOTES_LEDGER"
out="$(route 1 pr:812 2>&1)" || fail "(5) herd notes route pr: failed: $out"
[ "$(printf '%s' "$(cat "$BUILDER_NOTES_ROUTES")" | cut -f2)" = "pr" ] || fail "(5) pr: prefix did not resolve to kind=pr"
_scan_note_routes
[ -d "$INTENT_QUEUE_DIR" ] && fail "(5) a PR that has NOT landed enqueued an ack"
printf '%s 812 feat-beta HERD-9\n' "$NOW" > "$STATE"     # the reap ledger: PR 812 merged
_scan_note_routes
[ "$(reqs)" = "1" ] || fail "(5) a landed PR artifact enqueued no note-ack intent"
[ "$(sed -n 2p "$(ls "$INTENT_QUEUE_DIR"/*.req)")" = "pr:812" ] || fail "(5) wrong artifact on the intent"
_drain_intent_queue
herd_console_acked "$BUILDER_NOTES_ACK" "$note_b" || fail "(5) the note was not acked after its PR landed"
pass

# ── (6) DISMISS — a note with no route row is never auto-acked ───────────────────────────────────
reset
note_c="$(note_line feat-gamma "FYI: the sandbox rig prints a harmless locale warning")"
printf '%s\n' "$note_c" > "$BUILDER_NOTES_LEDGER"
printf 'HERD-641\n' > "$STUB_ITEMS"
printf '%s 999 feat-gamma\n' "$NOW" > "$STATE"
_scan_note_routes; _drain_intent_queue; _scan_note_routes; _drain_intent_queue
herd_console_acked "$BUILDER_NOTES_ACK" "$note_c" \
  && fail "(6) a note nobody routed was auto-acked — a dismissed note has no artifact and must never be"
[ -n "$(visible)" ] || fail "(6) the unrouted note left the console"
pass

# ── (7) IDEMPOTENT — a second ack converges instead of duplicating ───────────────────────────────
reset
note_d="$(note_line feat-delta "the health pane row is stale, not red")"
printf '%s\n' "$note_d" > "$BUILDER_NOTES_LEDGER"
printf 'HERD-700\n' > "$STUB_ITEMS"
route 1 item:HERD-700 >/dev/null 2>&1 || fail "(7) route failed"
_scan_note_routes; _drain_intent_queue
[ "$(grep -c . "$BUILDER_NOTES_ACK")" = "1" ] || fail "(7) the first ack wrote $(grep -c . "$BUILDER_NOTES_ACK") lines"
# A duplicate intent (a racing seat, a re-published route) must converge, not double-write.
iq_enqueue "$INTENT_QUEUE_DIR" "note-ack
item:HERD-700
alice
$note_d" >/dev/null
_drain_intent_queue
[ "$(reqs)" = "0" ] || fail "(7) the duplicate ack intent was retried instead of converging"
[ "$(grep -c . "$BUILDER_NOTES_ACK")" = "1" ] \
  || fail "(7) the duplicate ack appended a second line ($(grep -c . "$BUILDER_NOTES_ACK"))"
grep -q '"event":"intent_note_acked".*"result":"converged"' "$JOURNAL_FILE" \
  || fail "(7) the convergent ack was not journaled honestly"
pass

# ── (8) GC — a route whose note has left the console retires quietly ─────────────────────────────
reset
note_e="$(note_line feat-eps "a note that ages out before its artifact lands")"
printf '%s\n' "$note_e" > "$BUILDER_NOTES_LEDGER"
printf 'HERD-800\n' > "$STUB_ITEMS"
route 1 item:HERD-800 >/dev/null 2>&1 || fail "(8) route failed"
printf '%s\n' "$(note_line feat-eps "an unrelated later note")" > "$BUILDER_NOTES_LEDGER"  # the row was evicted
_scan_note_routes
[ "$(routes)" = "0" ] || fail "(8) a route whose note is gone was kept — no state may warn forever"
[ -d "$INTENT_QUEUE_DIR" ] && fail "(8) a route with no live note still enqueued an ack"
pass

# ── (9) ONE SUBSTRATE — both halves ride the shared surfaces, not copies of them ─────────────────
grep -q 'iq_enqueue "\$INTENT_QUEUE_DIR" "note-ack' "$WATCH" \
  || fail "(9) the note-route scan does not publish through the shared iq_enqueue"
grep -q 'herd_console_acked "\$BUILDER_NOTES_ACK"' "$WATCH" \
  || fail "(9) the ack executor does not read the SHARED ack ledger the operator's own ack writes"
grep -qE '^\s*mv .*\.req' "$WATCH" \
  && fail "(9) the watcher hand-rolls a queue rename outside the library"
# The producer (bin/herd) and the consumer (the watcher) must name the SAME pending-route file. A
# rename on one side alone is silent — the CLI would keep recording routes nobody ever scans.
grep -q 'BUILDER_NOTES_ROUTES="\$TREES/\.agent-watch-builder-notes-routes"' "$WATCH" \
  || fail "(9) the watcher's route-ledger path moved — the CLI producer would write to a file nobody reads"
grep -q 'routes="\$WORKTREES_DIR/\.agent-watch-builder-notes-routes"' "$HERD_BIN" \
  || fail "(9) bin/herd's route-ledger path moved — the watcher would scan a file nobody writes"
pass

echo "ALL PASS ($PASS checks)"
