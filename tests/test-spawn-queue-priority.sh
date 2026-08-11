#!/usr/bin/env bash
# test-spawn-queue-priority.sh — HERD-630 (Phase 1 of HERD-625): priority-ordered spawn intents
# drained on slot-free, ship-dormant behind INTENT_QUEUE.
#
# This file implements docs/spikes/coordinator-work-queue.md §7's verification plan literally. Its
# numbering IS that plan's numbering:
#
#   (1) PRIORITY ORDERING — intents enqueued out of priority order drain lowest-band-first; ties
#       preserve FIFO by INTENT_ID (the HERD-443 invariant).
#   (2) SLOT-FREE LATENCY — a tick with no free slot launches nothing; the VERY NEXT tick after a slot
#       frees launches the top candidate. There is no coordinator process anywhere in this file — that
#       is the §1.1 measurement (4 h 36 m of idle review slot) inverted into an assertion.
#   (3) RE-GROUND SKIP — a candidate whose item flipped Done between enqueue and drain is skipped with
#       spawn_skipped, the drain CONTINUES to the next candidate (which launches in the same tick), and
#       no lane runs for the skipped one.
#   (4) TTL ESCALATION — an intent aged past INTENT_TTL escalates instead of launching, and BOTH halves
#       of the clearing path work: `herd intents ack` clears the row immediately, and the watcher's own
#       age-to-retired sweep clears it (journaling spawn_intent_retired with the ref) on its own. The
#       HERD-613 lesson is that the escalation without the clearing path is itself the defect.
#   (5) COUNTERMAND RACE — `cancel` and `next` racing one intent: exactly one wins, the loser exits 3,
#       no double-launch, no phantom .req; a worker whose claim was cancelled under it journals
#       spawn_claim_lost rather than a phantom spawn_launched.
#   (6) LEVER-OFF BYTE-IDENTICAL — with INTENT_QUEUE unset the drain order is the untouched FIFO, no
#       re-ground read is issued at all, nothing expires and no escalation ledger is created.
#       (tests/test-spawn-queue-drain.sh passing UNMODIFIED is the other half of this assert and lives
#       in that file — it is not copied here.)
#   (7) MUTATION-PROOF — forcing every priority equal must make (1) go RED. A passing ordering
#       assertion over a queue that is FIFO anyway is vacuous, so this case proves it is not.
#
# Hermetic: temp dirs only. No network, no herdr, no real lanes, no live watcher loop. The drain
# functions are EXTRACTED from agent-watch.sh (sed) exactly as tests/test-spawn-queue-drain.sh extracts
# them, so the code under test is the shipped code, and the INTENT_QUEUE resolver is extracted from the
# REAL herd-config.sh so the lever's truthiness is the shipped rule, not a copy.
#
# Run:  bash tests/test-spawn-queue-priority.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WATCH="$REPO/scripts/herd/agent-watch.sh"
STEP="$REPO/scripts/herd/spawn-step.sh"
SPAWN="$REPO/scripts/herd/spawn.sh"
CONSOLE="$REPO/scripts/herd/console-section.sh"
CONFIG="$REPO/scripts/herd/herd-config.sh"
HERD_BIN="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "$WATCH" "$STEP" "$SPAWN" "$CONSOLE" "$CONFIG" "$HERD_BIN"; do
  [ -f "$f" ] || fail "missing engine file: $f"
done

# ── Fake engine dir ──────────────────────────────────────────────────────────────────────────────
# The REAL spawn-step.sh beside a stub herd-config.sh that carries (a) WORKTREES_DIR and (b) the REAL
# herd_intent_queue_on, extracted verbatim from herd-config.sh. Extracting rather than re-declaring is
# the point: the shared library's iq_lever_on (intent-queue.sh, HERD-639) DELEGATES to that resolver, so
# if the shipped truthiness rule ever changes, this harness changes with it instead of silently testing
# a stale copy. (HERD-639: the copied spawn-step.sh finds the library by walking up from this repo — see
# its own resolution comment — so the mechanics under test here are still the shipped ones.)
ENG="$T/eng"; mkdir -p "$ENG"
cp "$STEP" "$ENG/spawn-step.sh"
{
  printf 'WORKTREES_DIR="%s"\nexport WORKTREES_DIR\n' "$T/trees"
  sed -n '/^herd_intent_queue_on()/,/^}/p' "$CONFIG"
} > "$ENG/herd-config.sh"
grep -q '^herd_intent_queue_on()' "$ENG/herd-config.sh" \
  || fail "could not extract herd_intent_queue_on from herd-config.sh"
mkdir -p "$T/trees/spawn-queue"
Q="$T/trees/spawn-queue"

# Hermetic project config for spawn.sh (which sources the REAL herd-config.sh and would otherwise
# resolve a real project's .herd/config): pin it via HERD_CONFIG_FILE, the same seam every other CLI
# test uses, so an intent can NEVER land in a real project's spawn queue.
PROJ="$T/proj"; mkdir -p "$PROJ/.herd"
cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKSPACE_NAME="testws"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$T/trees"
EOF

LANELOG="$T/lane.log"
STATELOG="$T/state.log"     # every re-ground backend read, one ref per line (assert-on-absence in (6))
for lane in herd-feature.sh herd-quick.sh; do
  cat > "$ENG/$lane" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$1" >> "$LANELOG"
exit 0
FAKE
  chmod +x "$ENG/$lane"
done

# ── Harness: extract the drain + escalation surfaces from agent-watch.sh ─────────────────────────
DRAIN_SRC="$T/drain.sh"
: > "$DRAIN_SRC"
for fn in _spawn_slug_key _spawn_inflight_file _lane_lifecycle_key _lane_lifecycle_spawn \
          _lane_lifecycle_retire _spawn_inflight_bg _spawn_inflight_sweep _lane_spawn_inflight \
          _spawn_held_epoch _spawn_clear_held _intent_escalate _intent_reground_closed \
          _intent_escalation_row _intent_escalations_retire build_intent_escalations \
          _drain_lane_worker _drain_spawn_queue; do
  sed -n "/^$fn()/,/^}/p" "$WATCH" >> "$DRAIN_SRC"
  grep -q "^$fn()" "$DRAIN_SRC" || fail "could not extract $fn from agent-watch.sh"
done

JLOG="$T/journal.log"
# The fake clock every case reasons against. PINNED TO THE REAL CLOCK on purpose: iq_expired
# measures an intent's age from the INTENT_ID's own epoch against a real `date +%s` (that is the whole
# point of the field — see spawn-step.sh), while the console surfaces read HERD_FAKE_NOW. A synthetic
# far-future NOW would make an "aged" id look like it was enqueued in the future and silently never
# expire, so the two clocks are kept on the same timeline.
NOW="$(date +%s)"
ESC_LEDGER="$T/trees/.agent-watch-intent-escalations"
ESC_ACK="$T/trees/.agent-watch-intent-escalations-acked"

# _harness — the tick globals + stubs the extracted drain reads. Sourced inside every drain subshell.
# CLOSED_REFS lists the refs the stub tracker reports Done; every other ref reads open.
cat > "$T/harness.sh" <<HARNESS
HERE="$ENG"; TREES="$T/trees"
SPAWN_INFLIGHT_PREFIX="$T/trees/.spawn-inflight-"
SPAWN_HELD_STATE="$T/trees/.agent-watch-spawn-held"
INTENT_ESCALATION_LEDGER="$ESC_LEDGER"
INTENT_ESCALATION_ACK="$ESC_ACK"
REVIEW_CONCURRENCY=2; SPAWN_AHEAD=1; DRYRUN=""
_BUDGET_DRAIN_PAUSED=""
C_RED=""; C_RESET=""; C_DIM=""; C_BOLD=""; C_YELLOW=""
_marker_write(){ printf '%s\n' "\$2" > "\$1" 2>/dev/null || true; }
_marker_live(){ local p; p="\$(sed -n 1p "\$1" 2>/dev/null)"; [ -n "\$p" ] && kill -0 "\$p" 2>/dev/null; }
budget_daily_exceeded(){ return 1; }
journal_append(){ printf '%s\n' "\$*" >> "$JLOG"; }
_now_epoch(){ printf '%s' "\${HERD_FAKE_NOW:-$NOW}"; }
epoch_to_hhmm(){ printf '00:00'; }
_slug_cell(){ printf '%s' "\$1"; }
# The re-ground backend read (herd-claim.sh's _herd_state_dispatch in production). Logs every call so
# case (6) can assert the lever-off drain issues NONE.
_herd_state_dispatch(){
  printf '%s\n' "\$1" >> "$STATELOG"
  case " \${CLOSED_REFS:-} " in *" \$1 "*) printf 'closed\t' ;; *) printf 'open\t' ;; esac
}
. "$CONSOLE"
. "$ENG/herd-config.sh"   # the REAL herd_intent_queue_on, extracted above
. "$DRAIN_SRC"
HARNESS

# run_drain [FEATS-count] — one tick's drain, then `wait` for the backgrounded lane worker (the next
# tick's _lane_spawn_inflight check is what does this in production).
run_drain() {
  ( export LANELOG JLOG
    local n="${1:-0}" i
    # shellcheck source=/dev/null
    . "$T/harness.sh"
    FEATS=(); for ((i=0;i<n;i++)); do FEATS+=("busy$i"); done
    _drain_spawn_queue
    wait )
}
step(){ WORKTREES_DIR="$T/trees" bash "$ENG/spawn-step.sh" "$@"; }
enqueue(){ ( cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$SPAWN" "$@" ); }
qreset(){ rm -f "$Q"/* "$T/trees"/.spawn-inflight-* 2>/dev/null; : > "$LANELOG"; : > "$JLOG"; : > "$STATELOG"; }

# claim_order — call `next` until the queue is empty and print the claimed SLUGS in drain order.
claim_order() {
  local out line1 slug
  while :; do
    out="$(step next 2>/dev/null)" || break
    line1="${out%%$'\n'*}"
    case "$line1" in CLAIMED*) ;; *) break ;; esac
    slug="$(printf '%s\n' "$out" | sed -n 2p)"   # pipe-ok: bounded claim payload, far under a pipe buffer
    printf '%s ' "$slug"
  done
}

# plant <slug> <prio> — enqueue an intent and give it a priority band. Returns via $LAST_ID.
LAST_ID=""
plant() {
  local slug="$1" prio="${2:-}" ref="${3:-}" out
  out="$(HERD_ITEM_REF="$ref" enqueue "$slug" quick "task for $slug")" \
    || fail "plant: enqueue of $slug failed: $out"
  # spawn.sh's own "INTENT_ID <id>" line — never an mtime guess, which ties for same-second enqueues.
  LAST_ID="$(printf '%s\n' "$out" | sed -n 's/^INTENT_ID //p' | sed -n 1p)"   # pipe-ok: two short lines
  [ -n "$LAST_ID" ] || fail "plant: could not read the INTENT_ID for $slug (got: $out)"
  [ -n "$prio" ] && printf '%s\n' "$prio" > "$Q/$LAST_ID.prio"
  return 0
}

# ── Guard the guard ──────────────────────────────────────────────────────────────────────────────
enqueue probe quick "hermetic probe" >/dev/null \
  && ls "$Q"/*.req >/dev/null 2>&1 \
  || fail "hermetic enqueue seam broken — intent did not land in the test queue"
qreset

# ── (1) PRIORITY ORDERING — lowest band first, FIFO within a band ────────────────────────────────
# Enqueue order (FIFO) is a,b,c,d; bands are 30,10,30,20 → drain order must be b(10) d(20) a(30) c(30),
# with a BEFORE c because they share a band and a was enqueued first.
qreset
plant a 30; plant b 10; plant c 30; plant d 20
export INTENT_QUEUE=on
order="$(claim_order)"
[ "$order" = "b d a c " ] || fail "(1) priority order wrong: got '$order', want 'b d a c '"
pass

# ── (7) MUTATION-PROOF — force every priority equal and (1)'s expectation MUST go red ────────────
# Without this, (1) could be passing on a queue that is FIFO anyway. Same four intents, same enqueue
# order, all bands equal → the drain order must fall back to FIFO and therefore NOT match (1)'s.
qreset
plant a 30; plant b 30; plant c 30; plant d 30
order_mut="$(claim_order)"
[ "$order_mut" != "b d a c " ] \
  || fail "(7) MUTATION NOT DETECTED — all-equal priorities still produced the priority order, so (1) is vacuous"
[ "$order_mut" = "a b c d " ] \
  || fail "(7) all-equal priorities must drain FIFO by INTENT_ID: got '$order_mut', want 'a b c d '"
pass

# ── (6) LEVER-OFF BYTE-IDENTICAL — the same queue, unarmed, drains in the untouched FIFO ─────────
qreset
plant a 30; plant b 10; plant c 30; plant d 20
unset INTENT_QUEUE
order_off="$(claim_order)"
[ "$order_off" = "a b c d " ] \
  || fail "(6) lever OFF must drain the untouched FIFO: got '$order_off', want 'a b c d '"
pass

# …and an unarmed drain issues NO re-ground read, expires nothing, and creates no escalation surface,
# even over a queue whose top intent is BOTH long-expired and tracked to a closed item.
qreset
plant stale-off 10 HERD-CLOSED
oldid="$((NOW - 999999))-0000000001-1"
mv "$Q/$LAST_ID.req" "$Q/$oldid.req"; mv "$Q/$LAST_ID.prio" "$Q/$oldid.prio" 2>/dev/null || true
mv "$Q/$LAST_ID.ref" "$Q/$oldid.ref" 2>/dev/null || true
CLOSED_REFS="HERD-CLOSED" INTENT_TTL=60 run_drain 0
grep -q "herd-quick.sh stale-off" "$LANELOG" || fail "(6) lever OFF must still launch the intent unchanged"
[ -s "$STATELOG" ] && fail "(6) lever OFF issued a re-ground backend read ($(cat "$STATELOG"))"
[ -e "$ESC_LEDGER" ] && fail "(6) lever OFF wrote an escalation ledger"
ls "$Q"/*.escalated >/dev/null 2>&1 && fail "(6) lever OFF escalated an intent"
grep -q "spawn_launched slug stale-off lane quick" "$JLOG" || fail "(6) lever OFF journal changed ($(cat "$JLOG"))"
pass

export INTENT_QUEUE=on

# ── (2) SLOT-FREE LATENCY — no slot, no launch; the very next tick after a slot frees launches the
#        TOP candidate. No coordinator process exists anywhere in this scenario. ───────────────────
qreset
plant low-prio 40; plant top-prio 5
CLOSED_REFS="" INTENT_TTL=0 run_drain 3          # FEATS = cap (2+1) → budget 0 → nothing may launch
[ -s "$LANELOG" ] && fail "(2) a saturated tick launched a lane ($(cat "$LANELOG"))"
[ "$(ls -1 "$Q"/*.req 2>/dev/null | wc -l | tr -d ' ')" = "2" ] \
  || fail "(2) a saturated tick must leave BOTH intents pending"
CLOSED_REFS="" INTENT_TTL=0 run_drain 0          # a merge freed the slot; this is the very next tick
grep -q "herd-quick.sh top-prio" "$LANELOG" \
  || fail "(2) the tick after a slot freed did not launch the top candidate ($(cat "$LANELOG"))"
grep -q "herd-quick.sh low-prio" "$LANELOG" \
  && fail "(2) the lower band jumped ahead of the top candidate"
grep -q "spawn_launched slug top-prio lane quick" "$JLOG" || fail "(2) spawn_launched not journaled"
pass

# ── (3) RE-GROUND SKIP — the top candidate's item shipped since it was queued ────────────────────
# It must be skipped with spawn_skipped, nothing may be created for it, and the drain must CONTINUE:
# the next candidate launches in the SAME tick (the launch slot was never spent).
qreset
plant shipped-already 10 HERD-DONE
plant still-open 20 HERD-OPEN
CLOSED_REFS="HERD-DONE" INTENT_TTL=0 run_drain 0
grep -q "herd-quick.sh shipped-already" "$LANELOG" \
  && fail "(3) a re-grounded-closed intent launched a lane — no worktree/branch/agent may be created"
grep -q "spawn_skipped slug shipped-already lane quick reason re-ground: item already done ref HERD-DONE" "$JLOG" \
  || fail "(3) spawn_skipped (re-ground) not journaled ($(cat "$JLOG"))"
grep -q "herd-quick.sh still-open" "$LANELOG" \
  || fail "(3) the drain did not CONTINUE to the next candidate after a re-ground skip ($(cat "$LANELOG"))"
ls "$Q"/*.req "$Q"/*.mine >/dev/null 2>&1 \
  && fail "(3) the queue should be drained ($(ls "$Q"))"
pass

# …and an UNREADABLE / open item is never skipped (fail-soft: tracker flakiness must not stall the queue).
qreset
plant open-item 10 HERD-OPEN
CLOSED_REFS="" INTENT_TTL=0 run_drain 0
grep -q "herd-quick.sh open-item" "$LANELOG" || fail "(3b) an OPEN item must launch exactly as before"
grep -q "spawn_skipped" "$JLOG" && fail "(3b) an open item was skipped by the re-ground leg"
pass

# ── (4) TTL ESCALATION — an intent aged past INTENT_TTL escalates instead of launching ───────────
qreset
plant forgotten 10 HERD-STALE
oldid="$((NOW - 200000))-0000000002-1"
mv "$Q/$LAST_ID.req" "$Q/$oldid.req"
mv "$Q/$LAST_ID.prio" "$Q/$oldid.prio" 2>/dev/null || true
mv "$Q/$LAST_ID.ref"  "$Q/$oldid.ref"  2>/dev/null || true
CLOSED_REFS="" INTENT_TTL=86400 run_drain 0
[ -s "$LANELOG" ] && fail "(4) an expired intent launched a lane ($(cat "$LANELOG"))"
[ -f "$Q/$oldid.escalated" ] || fail "(4) the expired intent was not retired to its terminal .escalated state"
ls "$Q"/*.req >/dev/null 2>&1 && fail "(4) an escalated intent is still servable as .req"
grep -q "spawn_intent_escalated intent $oldid slug forgotten lane quick ref HERD-STALE" "$JLOG" \
  || fail "(4) spawn_intent_escalated not journaled ($(cat "$JLOG"))"
grep -q "forgotten" "$ESC_LEDGER" || fail "(4) no escalation row was written to the console ledger"
pass

# The row RENDERS, loudly, and does not age out on its own the way a calm row would.
rows="$( . "$T/harness.sh"; build_intent_escalations; printf '%s' "$INTENT_ESCALATION_ROWS" )"
grep -q "needs-you · spawn intent escalated" <<< "$rows" \
  || fail "(4) the escalation did not render a needs-you row (got: $rows)"
grep -q "HERD-STALE" <<< "$rows" || fail "(4) the needs-you row does not name the intent's ref"
rows_later="$( . "$T/harness.sh"; HERD_FAKE_NOW=$(( NOW + 3600 )) build_intent_escalations
               printf '%s' "$INTENT_ESCALATION_ROWS" )"
grep -q "needs-you · spawn intent escalated" <<< "$rows_later" \
  || fail "(4) the escalation row aged out early — an escalation is LOUD until acked or retired"
pass

# (4a) CLEARING PATH ONE — `herd intents ack` takes it off the console immediately (the real command).
run_herd() { HERD_CONFIG_FILE="$PROJ/.herd/config" HERD_FAKE_NOW="$NOW" HERMETIC_TEST=1 NO_COLOR=1 \
  bash "$HERD_BIN" "$@" 2>&1; }
out="$(cd "$PROJ" && run_herd intents)" || fail "(4a) herd intents failed: $out"
grep -q "forgotten" <<< "$out" || fail "(4a) herd intents did not list the escalated intent (got: $out)"
out="$(cd "$PROJ" && run_herd intents ack 1)" || fail "(4a) herd intents ack 1 failed: $out"
grep -q "forgotten" "$ESC_ACK" || fail "(4a) ack did not record the exact ledger line"
grep -q "forgotten" "$ESC_LEDGER" || fail "(4a) ack must never rewrite the ledger (history preserved)"
out="$(cd "$PROJ" && run_herd intents)" || fail "(4a) herd intents failed after ack: $out"
grep -q "forgotten" <<< "$out" && fail "(4a) an acked escalation is still on the console"
rows_acked="$( . "$T/harness.sh"; build_intent_escalations; printf '%s' "$INTENT_ESCALATION_ROWS" )"
[ -z "$rows_acked" ] || fail "(4a) the watcher still renders an acked escalation (got: $rows_acked)"
pass

# (4b) CLEARING PATH TWO — AGE-TO-RETIRED. The half HERD-613 leg 3 shipped without, and HERD-624 leg 2
# proved is not optional: a row nobody acks must still reach a terminal state, journaling its evidence.
rm -f "$ESC_ACK"
: > "$JLOG"
[ -f "$Q/$oldid.escalated" ] || fail "(4b) precondition: the terminal queue record should still exist"
( . "$T/harness.sh"; HERD_FAKE_NOW=$(( NOW + 9000 )) _intent_escalations_retire )
grep -q "forgotten" "$ESC_ACK" 2>/dev/null \
  || fail "(4b) an escalation past CONSOLE_ROW_RETENTION never retired itself — a permanent-red generator"
grep -q "spawn_intent_retired intent $oldid slug forgotten lane quick ref HERD-STALE" "$JLOG" \
  || fail "(4b) retirement did not journal its evidence WITH the ref ($(cat "$JLOG"))"
[ -e "$Q/$oldid.escalated" ] && fail "(4b) the terminal queue record was not GC'd with its row"
[ -e "$Q/$oldid.ref" ] && fail "(4b) the escalated intent's sidecars leaked past retirement"
rows_retired="$( . "$T/harness.sh"; HERD_FAKE_NOW=$(( NOW + 9000 )) build_intent_escalations
                 printf '%s' "$INTENT_ESCALATION_ROWS" )"
[ -z "$rows_retired" ] || fail "(4b) a retired escalation is still on the console (got: $rows_retired)"
pass

# ── (5) COUNTERMAND RACE — cancel vs next over one intent ────────────────────────────────────────
# (5a) cancel WINS: the intent is terminal, `next` never sees it, and no phantom .req is left behind.
qreset
rm -f "$ESC_LEDGER" "$ESC_ACK"
plant doomed 10
step cancel "$LAST_ID" >/dev/null 2>&1 || fail "(5a) cancel of a pending intent must succeed"
[ -f "$Q/$LAST_ID.cancelled" ] || fail "(5a) cancel did not produce the terminal .cancelled record"
ls "$Q"/*.req >/dev/null 2>&1 && fail "(5a) a phantom .req survived the cancel ($(ls "$Q"))"
out="$(step next)"
[ "${out%%$'\n'*}" = "EMPTY" ] || fail "(5a) next served a cancelled intent (got: ${out%%$'\n'*})"
pass

# (5b) next WINS: cancel loses the rename race and exits 3 LOUDLY — never a silent no-op that would
# leave the operator believing a launching builder was countermanded.
qreset
plant survivor 10
step next >/dev/null
mine="$(ls "$Q"/*.req.mine | sed -n 1p)"
rc=0; step cancel "$LAST_ID" >/dev/null 2>&1 || rc=$?
[ "$rc" = "3" ] || fail "(5b) cancel of an ALREADY-CLAIMED intent must exit 3 (got rc=$rc)"
[ -f "$mine" ] || fail "(5b) the loser's cancel destroyed a live claim"
ls "$Q"/*.cancelled >/dev/null 2>&1 && fail "(5b) cancel produced a terminal record it did not win"
pass

# (5c) …and the drain worker holding a claim that vanished under it journals spawn_claim_lost, never a
# phantom spawn_launched — the no-double-launch half of the race.
: > "$JLOG"; : > "$LANELOG"
step cancel "$LAST_ID" >/dev/null 2>&1 || true
rm -f "$mine"                                    # the claim disappears under the worker
( export LANELOG JLOG
  # shellcheck source=/dev/null
  . "$T/harness.sh"
  _drain_lane_worker "$mine" survivor quick "" "task" )
grep -q "spawn_claim_lost slug survivor lane quick action done" "$JLOG" \
  || fail "(5c) a worker whose claim vanished did not journal spawn_claim_lost ($(cat "$JLOG"))"
grep -q "spawn_launched" "$JLOG" && fail "(5c) a worker with no claim journaled a phantom spawn_launched"
pass

echo "ALL PASS ($PASS checks)"
