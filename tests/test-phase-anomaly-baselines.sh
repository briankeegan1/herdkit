#!/usr/bin/env bash
# test-phase-anomaly-baselines.sh — hermetic mutation-prove for HERD-496: per-phase duration
# baselines + anomaly self-filing.
#
# Sources the REAL agent-watch.sh in lib mode and drives _phase_anomaly_observe directly against the
# REAL pysrc/herd/store.py (WORKTREES_DIR pinned to a throwaway temp dir, so the pool is hermetic).
# journal_append and _main_health_scribe are overridden to log files so the test can inspect exactly
# what fired, without touching a real journal or a real scribe drainer.
#
# Under test:
#   (0) ship-dormant — ANOMALY_BASELINES unset/off is a hard no-op even on a wild outlier.
#   (1) under-learned — fewer than _ANOMALY_MIN_SAMPLES prior readings never judges, however slow.
#   (2) a LEARNED baseline + one instance past 2x its own p95 → ONE journal line, ONE advisory row,
#       ONE filed (scribed) item.
#   (3) a REPEAT of the exact same reading (same phase+seconds+p95 — the honest identity) dedups the
#       FILING: a second scribe item is never enqueued, and the dedup result is journaled.
#   (4) below threshold, once learned, stays completely SILENT — no journal, no row, no filing.
#
# Run:  bash tests/test-phase-anomaly-baselines.sh
set -uo pipefail
HERE_T="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE_T/../scripts/herd/agent-watch.sh"
[ -f "$WATCH" ] || { echo "FAIL: agent-watch.sh not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── Stub gh / herdr on PATH (network-free); the real store.py runs for real ─────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ────────────────────────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees/.herd"
export HERD_CONFIG_FILE="$T/no-such-config"
# HERD-618: pin loadavg QUIET so this prove is deterministic regardless of the real box's load —
# _anomaly_load_high (the under-load filing-margin guard) has its own dedicated fixture in
# tests/test-phase-anomaly-load-qualified.sh; this file exercises the pre-HERD-618 filing rail alone.
export HERD_FAKE_LOADAVG=0
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _anomaly_baselines_enabled _phase_duration_observe _phase_anomaly_observe build_phase_anomalies; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
TREES="$WORKTREES_DIR"

JLOG="$T/journal.log"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
SCRIBELOG="$T/scribe.log"
_main_health_scribe() { printf '===\n%s\n' "$1" >> "$SCRIBELOG"; }

_baseline_file() { printf '%s' "$TREES/.agent-watch-phase-duration-$1"; }

# ── (0) ship-dormant: off (the ANOMALY_BASELINES default) is a hard no-op ───────────────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER" "$(_baseline_file off_phase)"
unset ANOMALY_BASELINES
_phase_anomaly_observe off_phase "off phase" 99999
[ ! -s "$JLOG" ]           || fail "off by default: a journal line was written: $(cat "$JLOG")"
[ ! -s "$SCRIBELOG" ]      || fail "off by default: a scribe item was filed"
[ ! -s "${ANOMALY_LEDGER:-/nonexistent}" ] || fail "off by default: an advisory row was written"
[ ! -f "$(_baseline_file off_phase)" ] || fail "off by default: the store was touched at all"
ok

export ANOMALY_BASELINES=on
# HERD-512: pin the per-phase FILING COOLDOWN off, so the legacy legs below keep exercising the
# HONEST-IDENTITY dedup rail in isolation (with the 1800s default armed, step (3)'s repeat would be
# withheld as result=cooldown before it ever reached the identity marker, and the assertion would be
# testing the wrong rail). The cooldown itself has its own prove: tests/test-phase-anomaly-suspend-skip.sh.
export ANOMALY_FILE_COOLDOWN_SECS=0

# ── (1) under-learned: fewer than 5 prior readings never judges, however slow ───────────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
for v in 9999 8888 7777 6666; do _phase_anomaly_observe learning_phase "learning phase" "$v"; done
[ ! -s "$JLOG" ] || fail "an under-learned baseline judged anyway: $(cat "$JLOG")"
[ ! -s "${ANOMALY_LEDGER:-/nonexistent}" ] || fail "an under-learned baseline painted a row"
ok

# ── (2) LEARN a baseline (5 calm readings), then one instance past 2x p95 fires ONCE ────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
for v in 10 11 9 10 12; do _phase_anomaly_observe slow_phase "slow phase" "$v"; done
[ ! -s "$JLOG" ] || fail "the 5 learning samples themselves must never file: $(cat "$JLOG")"
# snapshot the baseline BEFORE the anomalous reading, to replay the identical instant in step (3)
SNAP="$T/snap-slow.txt"; cp "$(_baseline_file slow_phase)" "$SNAP"
_phase_anomaly_observe slow_phase "slow phase" 40    # prior p95=12 (max of 9..12) -> threshold 24 -> fires
grep -q '^phase_anomaly ' "$JLOG"                       || fail "no phase_anomaly journal line: $(cat "$JLOG")"
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG"  || fail "no enqueued filing: $(cat "$JLOG")"
[ "$(grep -c "^===$" "$SCRIBELOG")" -eq 1 ] || fail "expected exactly one scribe item: $(cat "$SCRIBELOG")"
[ -s "$ANOMALY_LEDGER" ] || fail "no advisory row written"
[ "$(wc -l < "$ANOMALY_LEDGER")" -eq 1 ] || fail "expected exactly one ledger row: $(cat "$ANOMALY_LEDGER")"
grep -q "slow phase" "$ANOMALY_LEDGER" || fail "the ledger row does not name the phase: $(cat "$ANOMALY_LEDGER")"
ok

# ── (3) a REPEAT of the EXACT same reading (same phase+seconds+baseline) dedups the FILING ─────────
# Restore the baseline to its PRE-anomaly snapshot — simulating a second seat (or a retried tick)
# observing the SAME completed instance against the SAME prior baseline, not a baseline the first
# observation has already folded in (which would shift p95 and change the identity entirely).
: > "$JLOG"
cp "$SNAP" "$(_baseline_file slow_phase)"
_phase_anomaly_observe slow_phase "slow phase" 40
grep -q 'phase_anomaly_filed.*result dedup' "$JLOG" || fail "no dedup result journaled on repeat: $(cat "$JLOG")"
[ "$(grep -c "^===$" "$SCRIBELOG")" -eq 1 ] || fail "a repeat reading re-filed a SECOND scribe item: $(cat "$SCRIBELOG")"
ok

# ── (4) below threshold, once learned, stays SILENT ─────────────────────────────────────────────────
# $ANOMALY_LEDGER is the ONE shared console ledger across every phase (mirrors builder notes / tracker
# heals) — NOT wiped here, since step (2) left a real standing row on it; a below-threshold reading
# must add NOTHING to it, so the invariant is "line count unchanged", not "the file is now empty".
: > "$JLOG"; : > "$SCRIBELOG"
_ledger_lines_before="$( [ -f "${ANOMALY_LEDGER:-/nonexistent}" ] && wc -l < "$ANOMALY_LEDGER" || echo 0)"
for v in 10 11 9 10 12; do _phase_anomaly_observe calm_phase "calm phase" "$v"; done
_phase_anomaly_observe calm_phase "calm phase" 20    # prior p95=12 -> threshold 24 -> 20 is UNDER it
[ ! -s "$JLOG" ]      || fail "an under-threshold reading fired anyway: $(cat "$JLOG")"
_ledger_lines_after="$(wc -l < "$ANOMALY_LEDGER")"
[ "$_ledger_lines_before" -eq "$_ledger_lines_after" ] || fail "an under-threshold reading painted a NEW row"
[ "$(wc -l < "$SCRIBELOG")" -eq 0 ] || fail "an under-threshold reading filed a tracker item: $(cat "$SCRIBELOG")"
ok

# ── build_phase_anomalies renders the standing row from step (2) ────────────────────────────────────
build_phase_anomalies
[ -n "${ANOMALY_ROWS:-}" ] || fail "build_phase_anomalies rendered nothing despite a standing row"
case "$ANOMALY_ROWS" in *"slow phase"*) ok ;; *) fail "the rendered row does not name the phase: $ANOMALY_ROWS" ;; esac

echo "ok — phase-anomaly baselines (HERD-496): $pass checks passed"
