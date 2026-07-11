#!/usr/bin/env bash
# test-py-store.sh — gate proof for the P4 SQLite state store + migration runner (HERD-305, EPIC HERD-300).
#
# P4 moves the ~45 flat MUTABLE-state files (approvals, review ledger, health results, claims, refix
# rounds, once-guards, seat registry) into one SQLite (WAL) db behind accessor functions that mirror
# the flat-file semantics 1:1, with a one-shot, guarded, LOSSLESS migration. This test proves the
# load-bearing claims HERMETICALLY (no gh / git / herdr / network / model — python3 stdlib + sqlite3
# only), so it can never touch the real worktree pool:
#
#   (1) UNIT INVARIANTS — tests/test_store.py: accessor PARITY (flat vs sqlite answer identically),
#       lossless round-trip (files → db → files byte-identical, incl. no-trailing-newline + non-utf8),
#       CONCURRENT CLAIM (many writers, one winner, zero lost updates, both backends), sha-keyed RMW
#       (refix bump / once-guard / approval fold+purge / review last-row-wins), and backend resolution
#       (default FLAT, marker engages sqlite, env lever forces).
#   (2) MIGRATION-REFUSED-WHILE-SEATS-LIVE — the runner crosses the P3.5 quiesce gate
#       (herd_engine_migration_guard, engine-seat.sh) BEFORE any write: a live foreign seat REFUSES the
#       migration loudly (rc 1, names the seat, marker NOT written); quiescing the seat lets it PROCEED
#       (rc 0, marker written). The guard is WIRED, never reimplemented (reuses the engine-seat fixtures).
#   (3) SIM ON BOTH BACKENDS — the SAME live-runtime dry-run gate scenario reaches identical terminal
#       decisions with STORE_BACKEND=flat and STORE_BACKEND=sqlite (green on both substrates).
#   (4) BYTE-IDENTICAL-OFF — the ship default is a HARD no-op: resolve_backend is FLAT with nothing
#       migrated, `herd store --status` reports flat, and shadow-runtime stdout OMITS the store_backend
#       key (so its output is byte-identical to before this seam).
#
# Run:  bash tests/test-py-store.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
export PYTHONPATH="$REPO/pysrc"
export HERDKIT_HOME="$REPO"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
python3 -c 'import sqlite3' 2>/dev/null || { echo "FAIL: python3 sqlite3 required" >&2; exit 1; }
for f in pysrc/herd/store.py scripts/herd/engine-seat.sh scripts/herd/journal.sh \
         scripts/herd/engine-version.sh; do
  [ -f "$REPO/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
PASS=0
pass() { PASS=$((PASS + 1)); }

# ── (1) unit invariants ──────────────────────────────────────────────────────────────────────────
python3 "$HERE/test_store.py" >/dev/null 2>&1 \
  || fail "stdlib unit tests failed (run: PYTHONPATH=pysrc python3 tests/test_store.py)"
pass

# ── (2) migration-refused-while-seats-live (the P3.5 quiesce gate, wired) ─────────────────────────
# Freeze the clock deterministically (same seam test-engine-seat.sh uses) so the seeded seat is inside
# the active TTL window and reads as a LIVE writer.
POOL="$T/pool"; mkdir -p "$POOL/.herd"
export HERD_ENGINE_SEAT_NOW=1000 HERD_ENGINE_SEAT_TTL=120
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# A live FOREIGN seat writing the pool (id 'other', not the migrating seat).
printf 'other\t5\t1000\tactive\n' > "$POOL/.herd/engine-seats.tsv"
# A state file so there is something to migrate.
printf '1000 approved 42 abcdef\n' > "$POOL/.agent-watch-approvals"

# The migrating seat must NOT be 'other', so 'other' is an un-quiesced blocker. Refusal ⇒ rc 1.
set +e
HERD_ENGINE_SEAT_ID=migrator WORKTREES_DIR="$POOL" \
  python3 -c 'import sys; from herd import store; sys.exit(store.migrate(sys.argv[1]))' "$POOL" \
  >"$T/refuse.out" 2>"$T/refuse.err"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "migration should be REFUSED while a live seat writes (rc=$rc)"
grep -q 'other' "$T/refuse.err" || fail "refusal must name the un-quiesced seat 'other'"
[ -f "$POOL/.herd/store-backend" ] && fail "refused migration must NOT write the backend marker"
pass

# Quiesce the seat → the guard PROCEEDS (rc 0, marker written).
printf 'other\t5\t1001\tquiesced\n' >> "$POOL/.herd/engine-seats.tsv"
set +e
HERD_ENGINE_SEAT_ID=migrator WORKTREES_DIR="$POOL" \
  python3 -c 'import sys; from herd import store; sys.exit(store.migrate(sys.argv[1]))' "$POOL" \
  >"$T/ok.out" 2>"$T/ok.err"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "migration should PROCEED once every other seat quiesced (rc=$rc; $(cat "$T/ok.err"))"
[ -f "$POOL/.herd/store-backend" ] || fail "proceeded migration must write the backend marker"
grep -q 'engine_migration_applied' "$JOURNAL_FILE" || fail "applied migration must journal the event"
# rollback restores flat + drops the marker.
WORKTREES_DIR="$POOL" python3 -c 'import sys; from herd import store; sys.exit(store.rollback(sys.argv[1]))' "$POOL" \
  >/dev/null 2>&1 || fail "rollback should succeed"
[ -f "$POOL/.herd/store-backend" ] && fail "rollback must drop the backend marker"
pass
unset HERD_ENGINE_SEAT_NOW HERD_ENGINE_SEAT_TTL JOURNAL_FILE

# ── (3) sim: the SAME gate scenario green on BOTH backends ─────────────────────────────────────────
SIM="$T/sim"; mkdir -p "$SIM/.herd"
cat > "$T/scenario.json" <<'JSON'
{"config":{"MERGE_POLICY":"auto"},
 "candidates":[
   {"pr":1,"sha":"a1","slug":"feat-a","review":"PASS","health":"CLEAN","worktree":"/wt/1"},
   {"pr":2,"sha":"a2","slug":"feat-b","stale":true},
   {"pr":3,"sha":"a3","slug":"feat-c","review":"BLOCK","health":"CLEAN"},
   {"pr":5,"sha":"a5","slug":"feat-e","review":"INFRA","health":"CLEAN"}]}
JSON
run_sim() {  # $1 = backend
  WORKTREES_DIR="$SIM" STORE_BACKEND="$1" LIVE_DRYRUN_JOURNAL="$T/sim-$1.jsonl" \
    python3 -m herd.live_runtime --dry-run --fixture "$T/scenario.json" \
    | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["outcomes"],sort_keys=True))'
}
OUT_FLAT="$(run_sim flat)"   || fail "flat sim exited nonzero"
OUT_SQL="$(run_sim sqlite)"  || fail "sqlite sim exited nonzero"
[ -n "$OUT_FLAT" ] || fail "flat sim produced no outcomes"
[ "$OUT_FLAT" = "$OUT_SQL" ] || fail "backends diverged on the sim scenario: flat=$OUT_FLAT sqlite=$OUT_SQL"
echo "$OUT_FLAT" | grep -q '"1": "MERGE"' || fail "green PR should MERGE on both backends ($OUT_FLAT)"
echo "$OUT_FLAT" | grep -q '"3": "BLOCK"' || fail "review-block PR should BLOCK on both backends ($OUT_FLAT)"
[ -f "$SIM/.herd/store.db" ] || fail "sqlite sim should have opened a db"
pass

# ── (4) byte-identical-off (ship default is a HARD no-op) ─────────────────────────────────────────
OFF="$T/off"; mkdir -p "$OFF/.herd"
unset STORE_BACKEND
WORKTREES_DIR="$OFF" python3 -m herd.store --status | grep -q '^backend: flat$' \
  || fail "default backend must resolve flat (ship-dormant)"
# shadow-runtime stdout must OMIT the store_backend key under the default (byte-identical to pre-seam).
WORKTREES_DIR="$OFF" python3 -m herd.shadow_runtime --fixture "$T/scenario.json" \
  | grep -q 'store_backend' && fail "shadow stdout leaked store_backend under the default (not byte-identical)"
pass

echo "PASS ($PASS checks) — herd.store: accessors parity + lossless round-trip + concurrent-claim +"
echo "     migration guarded by seat-quiesce + sim green on both backends + byte-identical default."
