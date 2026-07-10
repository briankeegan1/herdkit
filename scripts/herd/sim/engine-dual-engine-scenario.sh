#!/usr/bin/env bash
# scripts/herd/sim/engine-dual-engine-scenario.sh — HERD-308 CROSS-SEAT DUAL-ENGINE scenario.
#
# GROUNDED: the engine port (HERD-300) opens a dual-engine window in which two engines at DIFFERENT
# behavior levels can write the SAME worktree pool. No prior sim runs two watchers at different engine
# levels over ONE pool; every cross-seat invariant we had (blessing dedup, resolver single-flight) was
# proven with two SEPARATE pools. This scenario closes that gap for the leg-(a) invariant.
#
# FIX: two REAL watcher processes (agent-watch.sh sourced in lib mode, AGENT_WATCH_LIB=1) with
# ENGINE_SEAT_RECONCILE=on, sharing ONE $WORKTREES_DIR (one pool → one engine-seats registry → one
# journal). Seat NEW runs engine level 2; seat OLD runs level 1. Each seat runs the SHIPPED per-tick
# reconcile (_engine_seat_reconcile_tick) and then attempts the two consequential pool writes through
# the SHIPPED guarded paths — post_gate_status (the herd/gates blessing) and do_merge (the merge) —
# against a stub remote. The invariant: the STALE seat (OLD) HALTS — its writes are HELD, so the shared
# remote receives ZERO writes from it — while the LEAD seat (NEW) proceeds.
#
# Scorecard asserts (result:pass iff failed==0), written to $ART/scorecard.json and READ BACK from file:
#   • stale_seat_halted        — seat OLD reconciles STALE, its do_merge returns non-zero, and it posts
#                                neither a blessing nor a merge to the shared remote
#   • lead_seat_proceeds       — seat NEW reconciles LEAD and DOES post its blessing + merge
#   • cross_mismatch_writes=0   — zero writes on the shared remote from a below-max-level seat
#   • loud_halt_journaled       — an engine_seat_mismatch event is journaled to the shared pool journal
#   • migration_quiesce_refused — herd_engine_migration_guard REFUSES while OLD is still writing…
#   • migration_quiesce_ok      — …and PROCEEDS once OLD has quiesced
#
# Fully hermetic: local temp only; stubs gh (PATH). No network, no model, no real PRs, no git remote.
#
# Usage:
#   bash scripts/herd/sim/engine-dual-engine-scenario.sh [--artifacts DIR] [--keep]
#     --artifacts DIR   put the pool + scorecard here (default: a fresh mktemp dir)
#     --keep            do not delete the artifacts dir on exit (implied when --artifacts is given)
#
# Exit: 0 = every checkpoint passed · 1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE_DIR="$(cd "$HERE/.." && pwd)"
WATCH="$ENGINE_DIR/agent-watch.sh"

# ── output helpers ──────────────────────────────────────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────
ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "engine-dual-engine-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
[ -n "$KEEP" ] || trap 'rm -rf "$ART"' EXIT
[ -f "$WATCH" ] || { bad "agent-watch.sh not found at $WATCH"; exit 1; }

SCENARIO="dual-engine-cross-seat"
POOL="$ART/pool"                       # the ONE shared worktree pool both seats write
BIN="$ART/bin"
REMOTE="$ART/remote"                   # the shared stub-remote observation dir
mkdir -p "$POOL/.herd" "$BIN" "$REMOTE"
JOURNAL="$POOL/.herd/journal.jsonl"; : > "$JOURNAL"
BLESS_LOG="$REMOTE/blessings.log"; : > "$BLESS_LOG"     # one line per herd/gates POST: "<sha> <seat>"
MERGE_LOG="$REMOTE/merges.log";    : > "$MERGE_LOG"     # one line per merge:            "<pr> <seat>"

printf '%s══ Dual-engine cross-seat scenario: %s (2 seats · 1 pool · levels 2 vs 1) ══%s\n' \
  "$c_bold" "$SCENARIO" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# ── checkpoints (bash 3.2 parallel arrays) ──────────────────────────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=(); _pass=0; _fail=0
checkpoint() {
  local name="$1" status="$2"; shift 2; local detail="$*"
  detail="$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
  esac
}

# ── shared stub remote: gh ──────────────────────────────────────────────────────
# Seat identity rides HERD_SIM_SEAT. Only the two writes the guards protect are recorded.
step stubs "install shared stub remote (gh) + seat runner"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
seat="${HERD_SIM_SEAT:-?}"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then
  printf '%s %s\n' "${3:-?}" "$seat" >> "${SIM_MERGE_LOG:?}"
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  printf '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"","author":{"login":"?"},"body":"","comments":[]}\n'
  exit 0
fi
url=""; prev=""
for a in "$@"; do [ "$prev" = "api" ] && { url="$a"; break; }; prev="$a"; done
case "$url" in
  */statuses/*)          printf '%s %s\n' "${url##*/statuses/}" "$seat" >> "${SIM_BLESS_LOG:?}"; exit 0 ;;
  */commits/*/statuses)  printf '[]\n'; exit 0 ;;   # no foreign block → cross-seat guard passes
  */commits/*)           printf '2020-01-01T00:00:00Z\n'; exit 0 ;;
  user)                  printf '{"login":"%s"}\n' "$seat"; exit 0 ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

# ── seat runner: source the REAL watcher (lib mode) over the shared pool, run one tick ──────────────
# Usage: HERD_SIM_SEAT=<seat> HERD_ENGINE_LEVEL_FORCE=<n> bash $runner <reconcile|migrate-guard|quiesce>
SEAT_RUNNER="$ART/seat-runner.sh"
cat > "$SEAT_RUNNER" <<'RUNNER'
#!/usr/bin/env bash
set -uo pipefail
SEAT="${HERD_SIM_SEAT:?}"
POOL="${SIM_POOL:?}"
WATCH="${SIM_WATCH:?}"
CMD="${1:-reconcile}"

export PATH="${SIM_BIN:?}:$PATH"
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$POOL/no-such-config"
export WORKTREES_DIR="$POOL"
export JOURNAL_FILE="$POOL/.herd/journal.jsonl"
export WATCHER_OWNER="$SEAT"
export ENGINE_SEAT_RECONCILE=on
export GATE_STATUS=on
export SIM_BLESS_LOG SIM_MERGE_LOG

# shellcheck source=/dev/null
. "$WATCH" || { echo "seat $SEAT: source agent-watch failed" >&2; exit 1; }

# Neutralize post-merge side-quests orthogonal to the dual-engine invariant (same idiom as the
# concurrency/multiseat sims), so do_merge's write is the only thing we measure.
steps_run_at() { return 0; }
reconcile_backlog() { :; }
refresh_codemap() { :; }
refresh_symbol_index() { :; }
herd_teardown_slug() { :; }
cost_emit_merge() { :; }
record_merge() { :; }
_reconcile_pr_ref() { :; }

case "$CMD" in
  stamp)
    # Register this seat in the pool WITHOUT reconciling — models both watchers having stamped at the
    # top of their concurrent ticks before either reaches its write phase.
    herd_engine_seat_stamp active
    echo "stamped=$SEAT"
    ;;
  reconcile)
    # The SHIPPED per-tick reconcile arms $_ENGINE_SEAT_HALT for a stale seat.
    _engine_seat_reconcile_tick || true
    echo "verdict=${_HERD_SEAT_VERDICT:-?} self=${_HERD_SEAT_SELF_LEVEL:-?} max=${_HERD_SEAT_MAX_LEVEL:-?} halt=${_ENGINE_SEAT_HALT:-}"
    # Attempt the two guarded pool writes. A held seat records nothing on the shared remote.
    post_gate_status 90 shaDE success
    if do_merge slugDE 90 "$POOL/slugDE" shaDE; then echo "do_merge=merged"; else echo "do_merge=held"; fi
    ;;
  migrate-guard)
    # A synthetic migrator seat drives the P4 quiesce gate against whatever seats have stamped.
    if HERD_ENGINE_SEAT_ID=migrator herd_engine_migration_guard "P4-store-migrate" 2>&1; then
      echo "migration=proceed"
    else
      echo "migration=refused blockers=${_HERD_QUIESCE_BLOCKERS:-}"
    fi
    ;;
  quiesce)
    herd_engine_seat_quiesce
    echo "quiesced=$SEAT"
    ;;
  *) echo "seat runner: unknown cmd $CMD" >&2; exit 1 ;;
esac
RUNNER
chmod +x "$SEAT_RUNNER"

export SIM_POOL="$POOL" SIM_WATCH="$WATCH" SIM_BIN="$BIN"
export SIM_BLESS_LOG="$BLESS_LOG" SIM_MERGE_LOG="$MERGE_LOG"
checkpoint stubs_installed pass "shared gh remote + seat runner ready"

# ═══════════════════════════════════════════════════════════════════════════════
# DRIVE: NEW (level 2) then OLD (level 1) each take a tick over the shared pool.
# NEW stamps first so OLD sees a higher level present → OLD is the stale seat.
# ═══════════════════════════════════════════════════════════════════════════════
step drive "run both watchers over one pool — NEW (level 2) vs OLD (level 1)"

# Phase 1: both seats stamp (both watchers are live and have registered before either writes).
HERD_SIM_SEAT=new HERD_ENGINE_LEVEL_FORCE=2 bash "$SEAT_RUNNER" stamp >>"$ART/new.log" 2>&1 || true
HERD_SIM_SEAT=old HERD_ENGINE_LEVEL_FORCE=1 bash "$SEAT_RUNNER" stamp >>"$ART/old.log" 2>&1 || true
# Phase 2: each seat reconciles against the other's live stamp and then attempts its guarded writes.
NEW_OUT="$(HERD_SIM_SEAT=new HERD_ENGINE_LEVEL_FORCE=2 bash "$SEAT_RUNNER" reconcile 2>>"$ART/new.log")" || true
info "seat NEW: $NEW_OUT"
OLD_OUT="$(HERD_SIM_SEAT=old HERD_ENGINE_LEVEL_FORCE=1 bash "$SEAT_RUNNER" reconcile 2>>"$ART/old.log")" || true
info "seat OLD: $OLD_OUT"

# ── assert leg-(a) invariants from the shared remote + journal ──────────────────
step assert "assert the dual-engine invariant (stale halts · zero cross-mismatch writes)"

new_verdict="$(printf '%s' "$NEW_OUT" | sed -n 's/.*verdict=\([a-z]*\).*/\1/p')"
old_verdict="$(printf '%s' "$OLD_OUT" | sed -n 's/.*verdict=\([a-z]*\).*/\1/p')"
old_domerge="$(printf '%s' "$OLD_OUT" | sed -n 's/.*do_merge=\([a-z]*\).*/\1/p')"

# (1) lead seat proceeds
if [ "$new_verdict" = lead ] && grep -q ' new$' "$BLESS_LOG" && grep -q ' new$' "$MERGE_LOG"; then
  checkpoint lead_seat_proceeds pass "seat NEW read LEAD and posted its blessing + merge"
else
  checkpoint lead_seat_proceeds fail "NEW verdict=$new_verdict bless=$(grep -c ' new$' "$BLESS_LOG") merge=$(grep -c ' new$' "$MERGE_LOG")"
fi

# (2) stale seat halts loudly and writes nothing
OLD_BLESS="$(grep -c ' old$' "$BLESS_LOG" 2>/dev/null)"; OLD_BLESS="${OLD_BLESS:-0}"
OLD_MERGE="$(grep -c ' old$' "$MERGE_LOG" 2>/dev/null)"; OLD_MERGE="${OLD_MERGE:-0}"
if [ "$old_verdict" = stale ] && [ "$old_domerge" = held ] && [ "$OLD_BLESS" -eq 0 ] && [ "$OLD_MERGE" -eq 0 ]; then
  checkpoint stale_seat_halted pass "seat OLD read STALE, held its merge, and posted 0 blessings / 0 merges"
else
  checkpoint stale_seat_halted fail "OLD verdict=$old_verdict do_merge=$old_domerge bless=$OLD_BLESS merge=$OLD_MERGE"
fi

# (3) zero cross-mismatch writes — no write on the shared remote from the below-max-level (OLD) seat
CROSS_WRITES=$(( OLD_BLESS + OLD_MERGE ))
if [ "$CROSS_WRITES" -eq 0 ]; then
  checkpoint cross_mismatch_writes pass "0 writes on the shared remote from a below-max-level seat"
else
  checkpoint cross_mismatch_writes fail "cross_mismatch_writes=$CROSS_WRITES"
fi

# (4) the halt is loud in the journal
if grep -q engine_seat_mismatch "$JOURNAL" 2>/dev/null; then
  checkpoint loud_halt_journaled pass "engine_seat_mismatch journaled to the shared pool journal"
else
  checkpoint loud_halt_journaled fail "no engine_seat_mismatch event in $JOURNAL"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# LEG (b): the P4 migration quiesce gate over the same pool.
# ═══════════════════════════════════════════════════════════════════════════════
step migrate "drive the P4 migration-quiesce gate (refuse while OLD writes, proceed once quiesced)"
MG1="$(HERD_SIM_SEAT=migrator bash "$SEAT_RUNNER" migrate-guard 2>>"$ART/mg.log")" || true
info "guard (OLD still active): $MG1"
if printf '%s' "$MG1" | grep -q 'migration=refused'; then
  checkpoint migration_quiesce_refused pass "guard refused while a seat is still writing: $MG1"
else
  checkpoint migration_quiesce_refused fail "expected refusal, got: $MG1"
fi

# Quiesce both live seats, then re-drive the guard.
HERD_SIM_SEAT=new HERD_ENGINE_LEVEL_FORCE=2 bash "$SEAT_RUNNER" quiesce >>"$ART/mg.log" 2>&1 || true
HERD_SIM_SEAT=old HERD_ENGINE_LEVEL_FORCE=1 bash "$SEAT_RUNNER" quiesce >>"$ART/mg.log" 2>&1 || true
MG2="$(HERD_SIM_SEAT=migrator bash "$SEAT_RUNNER" migrate-guard 2>>"$ART/mg.log")" || true
info "guard (all quiesced): $MG2"
if printf '%s' "$MG2" | grep -q 'migration=proceed'; then
  checkpoint migration_quiesce_ok pass "guard proceeded once every seat quiesced: $MG2"
else
  checkpoint migration_quiesce_ok fail "expected proceed, got: $MG2"
fi

# ── SCORECARD (written to file, then READ BACK) ─────────────────────────────────
write_scorecard() {
  local out="$ART/scorecard.json" result="$1" i n; n=${#CP_NAMES[@]}
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
    printf '  "artifacts_dir": "%s",\n' "$ART"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "seats": 2,\n'
    printf '  "new_level": 2,\n'
    printf '  "old_level": 1,\n'
    printf '  "new_verdict": "%s",\n' "${new_verdict:-?}"
    printf '  "old_verdict": "%s",\n' "${old_verdict:-?}"
    printf '  "cross_mismatch_writes": %d,\n' "${CROSS_WRITES:-0}"
    printf '  "checkpoints": [\n'
    for ((i=0; i<n; i++)); do
      printf '    {"name": "%s", "status": "%s", "detail": "%s"}' \
        "${CP_NAMES[$i]}" "${CP_STATUS[$i]}" "${CP_DETAIL[$i]}"
      [ "$i" -lt "$((n-1))" ] && printf ',\n' || printf '\n'
    done
    printf '  ]\n}\n'
  } > "$out"
  printf '%s' "$out"
}
RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$(write_scorecard "$RESULT")"

# Read the verdict BACK from the file (the item's "scorecard green, read from file" acceptance).
FILE_RESULT="$(sed -n 's/.*"result": "\([a-z]*\)".*/\1/p' "$SCARD" | head -1)"
FILE_CROSS="$(sed -n 's/.*"cross_mismatch_writes": \([0-9]*\).*/\1/p' "$SCARD" | head -1)"

printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:                %s\n' "$SCENARIO"
printf '  passed/failed:           %d / %d\n' "$_pass" "$_fail"
printf '  new/old verdict:         %s / %s\n' "${new_verdict:-?}" "${old_verdict:-?}"
printf '  cross_mismatch_writes:   %s (from file: %s)\n' "${CROSS_WRITES:-0}" "${FILE_CROSS:-?}"
printf '  scorecard:               %s\n' "$SCARD"
printf '  result (from file):      %s\n' "${FILE_RESULT:-?}"

if [ "$FILE_RESULT" = pass ] && [ "${FILE_CROSS:-1}" = 0 ]; then
  exit 0
else
  exit 1
fi
