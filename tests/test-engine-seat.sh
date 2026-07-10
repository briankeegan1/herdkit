#!/usr/bin/env bash
# test-engine-seat.sh — hermetic tests for CROSS-SEAT DUAL-ENGINE SAFETY (HERD-308, engine-port P3.5).
#
# Covers both legs of scripts/herd/engine-seat.sh plus its two agent-watch.sh enforcement surfaces:
#
#   (a) ENGINE-LEVEL STAMPS + PER-TICK RECONCILE
#       • single seat → COHERENT (rc 0), the solo-operator steady state
#       • a lower-level seat sharing the pool → the higher one reads LEAD, the lower one reads STALE
#       • STALE ⇒ herd_engine_seat_hold true; LEAD/COHERENT ⇒ false
#       • a mismatch journals engine_seat_mismatch ONCE per (verdict,levels) signature, not per tick
#       • an aged-out seat (past the TTL) no longer counts — a stopped engine is not a coexisting one
#       • the append-only registry survives concurrent writers (no lost update) and self-compacts
#   (b) P4 MIGRATION QUIESCE GATE
#       • another ACTIVE seat writing the pool → herd_engine_migration_guard REFUSES (rc 1), names it
#       • that seat quiesced (or aged out) → PROCEEDS (rc 0)
#       • an explicit dual-write window (HERD_ENGINE_DUALWRITE=1 / marker) → PROCEEDS, journaled
#   (c) AGENT-WATCH ENFORCEMENT (lib mode)
#       • ENGINE_SEAT_RECONCILE=on + a STALE tick → do_merge HOLDS (rc 1, no gh), post_gate_status HOLDS
#         (no blessing), each journaling engine_seat_write_held
#       • ENGINE_SEAT_RECONCILE=off → the guards are inert: the write path runs exactly as before (the
#         byte-identical-when-off invariant)
#
# Fully hermetic: local temp only, no network, no model. Run:  bash tests/test-engine-seat.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/herd/engine-seat.sh"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$LIB" ]   || fail "engine-seat.sh not found at $LIB"
[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v awk >/dev/null 2>&1 || fail "awk required"

# ── (a)+(b) unit-drive the lib directly ─────────────────────────────────────────
export WORKTREES_DIR="$T/pool"; mkdir -p "$WORKTREES_DIR/.herd"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export HERD_ENGINE_SEAT_NOW=1000     # freeze the clock so TTL math is deterministic
export HERD_ENGINE_SEAT_TTL=120
# shellcheck source=/dev/null
. "$HERE/../scripts/herd/journal.sh"
# shellcheck source=/dev/null
. "$HERE/../scripts/herd/engine-version.sh"
# shellcheck source=/dev/null
. "$LIB" || fail "sourcing engine-seat.sh failed"

REG="$WORKTREES_DIR/.herd/engine-seats.tsv"
journaled() { grep -q "$1" "$JOURNAL_FILE" 2>/dev/null; }
reset_journal() { : > "$JOURNAL_FILE"; }

# ── (a1) single seat is COHERENT ────────────────────────────────────────────────
: > "$REG"
HERD_ENGINE_SEAT_ID=solo HERD_ENGINE_LEVEL_FORCE=1 herd_engine_seat_reconcile \
  || fail "(a1) single seat must reconcile coherent (rc 0)"
[ "$_HERD_SEAT_VERDICT" = coherent ] || fail "(a1) verdict '$_HERD_SEAT_VERDICT' != coherent"
herd_engine_seat_hold && fail "(a1) a coherent seat must not hold"
ok

# ── (a2) two levels: the higher seat reads LEAD, the lower reads STALE ──────────
: > "$REG"; reset_journal
HERD_ENGINE_SEAT_ID=old HERD_ENGINE_LEVEL_FORCE=1 herd_engine_seat_stamp active
# the NEW engine (level 2) reconciles against the old level-1 seat → LEAD
if HERD_ENGINE_SEAT_ID=new HERD_ENGINE_LEVEL_FORCE=2 herd_engine_seat_reconcile; then
  fail "(a2) a mismatch must return non-zero"
fi
[ "$_HERD_SEAT_VERDICT" = lead ]  || fail "(a2) higher seat verdict '$_HERD_SEAT_VERDICT' != lead"
[ "$_HERD_SEAT_PEER" = old ]      || fail "(a2) lead peer '$_HERD_SEAT_PEER' != old"
[ "$_HERD_SEAT_MAX_LEVEL" = 2 ]   || fail "(a2) max level '$_HERD_SEAT_MAX_LEVEL' != 2"
herd_engine_seat_hold && fail "(a2) the LEADING seat must not hold (only the stale one halts)"
# the OLD engine (level 1) reconciles against the new level-2 seat → STALE
if HERD_ENGINE_SEAT_ID=old HERD_ENGINE_LEVEL_FORCE=1 herd_engine_seat_reconcile; then
  fail "(a2) stale seat must return non-zero"
fi
[ "$_HERD_SEAT_VERDICT" = stale ] || fail "(a2) lower seat verdict '$_HERD_SEAT_VERDICT' != stale"
[ "$_HERD_SEAT_PEER" = new ]      || fail "(a2) stale peer '$_HERD_SEAT_PEER' != new"
herd_engine_seat_hold || fail "(a2) a STALE seat MUST hold"
journaled engine_seat_mismatch || fail "(a2) no engine_seat_mismatch journaled"
ok

# ── (a3) mismatch journals ONCE per signature, not per tick ─────────────────────
reset_journal
HERD_ENGINE_SEAT_ID=old HERD_ENGINE_LEVEL_FORCE=1 herd_engine_seat_reconcile || true
HERD_ENGINE_SEAT_ID=old HERD_ENGINE_LEVEL_FORCE=1 herd_engine_seat_reconcile || true
HERD_ENGINE_SEAT_ID=old HERD_ENGINE_LEVEL_FORCE=1 herd_engine_seat_reconcile || true
n="$(grep -c engine_seat_mismatch "$JOURNAL_FILE" 2>/dev/null)"; n="${n:-0}"
[ "$n" -le 1 ] || fail "(a3) a persisting mismatch re-journaled every tick ($n events)"
ok

# ── (a4) an aged-out seat drops out of the reconcile ────────────────────────────
# The level-2 seat's last stamp is at t=1000; jump the clock past the TTL → it is gone → coherent again.
if HERD_ENGINE_SEAT_ID=old HERD_ENGINE_LEVEL_FORCE=1 HERD_ENGINE_SEAT_NOW=99999 herd_engine_seat_reconcile; then
  [ "$_HERD_SEAT_VERDICT" = coherent ] || fail "(a4) aged-out peer still counted: '$_HERD_SEAT_VERDICT'"
else
  fail "(a4) an aged-out peer must leave the pool coherent (rc 0)"
fi
ok

# ── (a5) concurrent writers: no lost update, and the log self-compacts ──────────
: > "$REG"
pids=""
for s in a b c d; do
  ( for i in $(seq 1 100); do HERD_ENGINE_SEAT_ID="seat-$s" HERD_ENGINE_LEVEL_FORCE=1 herd_engine_seat_stamp active; done ) &
  pids="$pids $!"
done
for p in $pids; do wait "$p"; done
# Every seat must still be present in the latest-row-per-seat view (append-only ⇒ no lost update).
rows="$(_herd_engine_seat_active_rows)"
for s in a b c d; do
  printf '%s\n' "$rows" | grep -q "^seat-$s	" || fail "(a5) seat-$s lost from the registry under concurrency"
done
# And compaction kept the file bounded (well under the 400 raw appends).
lines="$(grep -c . "$REG" 2>/dev/null)"; lines="${lines:-0}"
[ "$lines" -le 256 ] || fail "(a5) registry did not self-compact ($lines lines)"
ok

# ── (b1) migration REFUSES while another seat actively writes ───────────────────
: > "$REG"; reset_journal
HERD_ENGINE_SEAT_ID=writer HERD_ENGINE_LEVEL_FORCE=1 herd_engine_seat_stamp active
if HERD_ENGINE_SEAT_ID=migrator herd_engine_migration_guard "P4-migrate" 2>"$T/mg.err"; then
  fail "(b1) migration must refuse while a seat is actively writing"
fi
[ "$_HERD_QUIESCE_BLOCKERS" = writer ] || fail "(b1) blockers '$_HERD_QUIESCE_BLOCKERS' != writer"
grep -q 'refusing P4-migrate' "$T/mg.err" || fail "(b1) refusal message did not name the surface"
journaled engine_migration_refused || fail "(b1) no engine_migration_refused journaled"
ok

# ── (b2) the writer quiesces → migration proceeds ───────────────────────────────
HERD_ENGINE_SEAT_ID=writer HERD_ENGINE_LEVEL_FORCE=1 herd_engine_seat_quiesce
HERD_ENGINE_SEAT_ID=migrator herd_engine_migration_guard "P4-migrate" 2>/dev/null \
  || fail "(b2) migration must proceed once every other seat is quiesced"
ok

# ── (b3) an explicit dual-write window proceeds over an active writer, journaled ─
reset_journal
HERD_ENGINE_SEAT_ID=writer HERD_ENGINE_LEVEL_FORCE=1 herd_engine_seat_stamp active
HERD_ENGINE_SEAT_ID=migrator HERD_ENGINE_DUALWRITE=1 herd_engine_migration_guard "P4-migrate" 2>/dev/null \
  || fail "(b3) a declared dual-write window must let the migration proceed"
journaled engine_migration_dualwrite || fail "(b3) no engine_migration_dualwrite journaled"
# the marker-file form works too
touch "$WORKTREES_DIR/.herd/engine-dualwrite"
HERD_ENGINE_SEAT_ID=migrator herd_engine_migration_guard "P4-migrate" 2>/dev/null \
  || fail "(b3) the dual-write MARKER file must let the migration proceed"
rm -f "$WORKTREES_DIR/.herd/engine-dualwrite"
ok

# ── (c) agent-watch.sh enforcement in lib mode ──────────────────────────────────
# Source the real watcher and drive its do_merge / post_gate_status guards. A separate pool per section
# keeps the lib-drive registry above from colouring the watcher's own reconcile.
(
  set -uo pipefail
  BIN="$T/bin"; mkdir -p "$BIN"
  # gh stub: log every call so we can assert a HELD write reaches NO network.
  cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
exit 0
GH
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
  export GH_LOG="$T/gh.log"; : > "$GH_LOG"

  export AGENT_WATCH_LIB=1
  export HERD_CONFIG_FILE="$T/no-such-config"
  export WORKTREES_DIR="$T/wpool"; mkdir -p "$T/wpool/.herd"
  export JOURNAL_FILE="$T/wjournal.jsonl"; : > "$JOURNAL_FILE"
  export WATCHER_OWNER="watchSeat"
  export GATE_STATUS=on
  # shellcheck source=/dev/null
  . "$WATCH" || { echo "FAIL: sourcing agent-watch.sh (lib mode) failed" >&2; exit 1; }

  # Neutralize the pre-merge steps seam so do_merge's own path is what we measure.
  steps_run_at() { return 0; }

  wjournaled() { grep -q "$1" "$JOURNAL_FILE" 2>/dev/null; }

  # (c1) lever ON + a STALE tick → do_merge HOLDS, no gh, journals write_held.
  ENGINE_SEAT_RECONCILE=on
  _ENGINE_SEAT_HALT=1
  DRYRUN=""
  : > "$GH_LOG"
  if do_merge slugA 71 "$T/wpool/slugA" shaA; then
    echo "FAIL: (c1) do_merge must return non-zero when held" >&2; exit 1
  fi
  [ -s "$GH_LOG" ] && { echo "FAIL: (c1) a HELD merge reached the network" >&2; exit 1; }
  wjournaled engine_seat_write_held || { echo "FAIL: (c1) no engine_seat_write_held journaled for do_merge" >&2; exit 1; }

  # (c2) lever ON + STALE → post_gate_status HOLDS (no blessing POST), journals write_held.
  : > "$GH_LOG"; : > "$JOURNAL_FILE"
  post_gate_status 71 shaA success
  grep -q 'statuses/shaA' "$GH_LOG" && { echo "FAIL: (c2) a HELD blessing was posted" >&2; exit 1; }
  wjournaled engine_seat_write_held || { echo "FAIL: (c2) no engine_seat_write_held journaled for post_gate_status" >&2; exit 1; }

  # (c3) lever OFF → the guard is inert: the write path runs past it (reaches the network).
  ENGINE_SEAT_RECONCILE=off
  _ENGINE_SEAT_HALT=1        # halt armed, but the OFF lever must ignore it → byte-identical
  : > "$GH_LOG"
  post_gate_status 72 shaB success
  grep -q 'statuses/shaB' "$GH_LOG" || { echo "FAIL: (c3) lever OFF must not hold — the blessing must post" >&2; exit 1; }

  # (c4) the loud console row renders from a STALE state file, and OFF renders nothing (byte-identical).
  export NO_COLOR=1
  ENGINE_SEAT_RECONCILE=on
  printf 'stale 1 2 peerSeat\n' > "$ENGINE_SEAT_STATE"
  build_engine_seat_note
  printf '%s' "${HERD_ENGINE_SEAT_NOTE:-}" | grep -q 'DUAL-ENGINE HALT' \
    || { echo "FAIL: (c4) a stale state file must render the loud HALT row" >&2; exit 1; }
  printf '%s' "${HERD_ENGINE_SEAT_NOTE:-}" | grep -q 'peerSeat' \
    || { echo "FAIL: (c4) the HALT row must name the peer seat" >&2; exit 1; }
  ENGINE_SEAT_RECONCILE=off
  build_engine_seat_note
  [ -z "${HERD_ENGINE_SEAT_NOTE:-}" ] || { echo "FAIL: (c4) lever OFF must render no dual-engine row" >&2; exit 1; }
  echo "CSECTION-OK"
) > "$T/csection.out" 2>&1 || { cat "$T/csection.out" >&2; fail "(c) agent-watch enforcement section failed"; }
grep -q CSECTION-OK "$T/csection.out" || { cat "$T/csection.out" >&2; fail "(c) agent-watch enforcement did not complete"; }
ok

echo "PASS test-engine-seat.sh ($pass checks)"
