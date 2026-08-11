#!/usr/bin/env bash
# test-phase-anomaly-floor-margin.sh — hermetic mutation-prove for HERD-645: the phase-anomaly rail's
# filing threshold gets an ABSOLUTE floor on top of its pct multiplier, so a tight-distribution phase
# (a learned p95 close to its own nominal period) does not alarm on ordinary jitter.
#
# GROUNDED: tick_cadence filed 4 marginal anomaly items in 2 days (latest: a 60s tick vs a p95 of 47s
# on a QUIET box). HERD-618's load-aware widening (PR 737) works as specced, but that only widens the
# bar under LOAD — on a quiet box the pct multiplier alone let ordinary jitter around the nominal 60s
# tick clear it. The fix composes an absolute floor into the SAME base threshold PR 737 widens: the
# class-default filing bar for every phase is max(1.5x p95, p95 + 30s), never just 1.5x p95 alone.
#
# Same harness shape as tests/test-phase-anomaly-load-qualified.sh: sources the REAL agent-watch.sh in
# lib mode and drives _phase_anomaly_observe against the REAL pysrc/herd/store.py. loadavg is driven
# via HERD_FAKE_LOADAVG so both the quiet-box and loaded-box legs are deterministic.
#
# Fixture: 5 learning readings with a max (=p95, nearest-rank over n=5) of 47 → threshold
# max(47*1.5=70, 47+30=77)=77 → widened under-load threshold 154 (2x, HERD-618's default margin).
#
# Under test:
#   (1) QUIET box, 60s (under the 77 floor) → completely silent: no journal, no row, no filing.
#   (2) QUIET box, 90s (past the 77 floor) → files normally: journal + untagged row + one scribe item.
#   (3) LOADED box, 60s (under the 77 floor) → completely silent EVEN UNDER LOAD — the floor does not
#       move with load; only the fires-past-it widening does.
#   (4) LOADED box, 90s (past the 77 floor, short of the 154 widened bar) → the row/file split: journal
#       + a row tagged load_qualified render (display signal), but the tracker filing is withheld
#       (no tracker churn).
#
# Run:  bash tests/test-phase-anomaly-floor-margin.sh
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
export HERD_FAKE_LOADAVG=0     # quiet until a leg below overrides it
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _phase_anomaly_observe _phase_anomaly_row build_phase_anomalies; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
TREES="$WORKTREES_DIR"

JLOG="$T/journal.log"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
SCRIBELOG="$T/scribe.log"
_main_health_scribe() { printf '===\n%s\n' "$1" >> "$SCRIBELOG"; }
_wake_probe_epoch() { return 1; }   # the wake guard is orthogonal to this rail — pin it unavailable

_count_matches(){ local n; n="$(grep -c "$1" "$2" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac; printf '%s' "$n"; }
_scribed(){ _count_matches '^===$' "$SCRIBELOG"; }
_ledger_lines(){ _count_matches '' "${ANOMALY_LEDGER:-/nonexistent}"; }

# _learn <phase> — 5 calm readings whose nearest-rank p95 (n=5 ⇒ the max) is 47.
_learn() {
  local v
  for v in 45 46 44 45 47; do _phase_anomaly_observe "$1" "$1" "$v"; done
}

export ANOMALY_BASELINES=on
export ANOMALY_FILE_COOLDOWN_SECS=0   # isolate this rail from the cooldown rail (its own prove exists)
export HEALTH_LOAD_THRESHOLD=4

# ── (1) QUIET box, 60s — under the 77 floor: completely silent ──────────────────────────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
export HERD_FAKE_LOADAVG=0
_learn quiet_under
_phase_anomaly_observe quiet_under "quiet under" 60    # 60 <= 77 (max(70,77)) — sub-floor
[ ! -s "$JLOG" ]      || fail "a sub-floor quiet-box reading journaled anyway: $(cat "$JLOG")"
[ "$(_ledger_lines)" -eq 0 ] || fail "a sub-floor quiet-box reading painted a row: $(cat "$ANOMALY_LEDGER" 2>/dev/null)"
[ "$(_scribed)" -eq 0 ] || fail "a sub-floor quiet-box reading filed a tracker item"
ok

# ── (2) QUIET box, 90s — past the 77 floor: files normally ──────────────────────────────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
_learn quiet_over
_phase_anomaly_observe quiet_over "quiet over" 90    # 90 > 77 — clears the floor, quiet box
grep -q '^phase_anomaly ' "$JLOG" || fail "a past-floor quiet-box reading lost its journal line: $(cat "$JLOG")"
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" || fail "a past-floor quiet-box reading did not file: $(cat "$JLOG")"
[ "$(_scribed)" -eq 1 ] || fail "expected exactly one filed item on a quiet box: $(cat "$SCRIBELOG")"
_last_row="$(tail -n1 "$ANOMALY_LEDGER")"
case "$_last_row" in *$'\t'load_qualified) fail "a quiet-box row was tagged load_qualified: $(cat "$ANOMALY_LEDGER")" ;; esac
ok

# ── (3) LOADED box, 60s — the floor does NOT move with load: still completely silent ────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
export HERD_FAKE_LOADAVG=8    # >= HEALTH_LOAD_THRESHOLD=4, box reads as contended
_learn loaded_under
_phase_anomaly_observe loaded_under "loaded under" 60    # 60 <= 77 — sub-floor even under load
[ ! -s "$JLOG" ]      || fail "a sub-floor loaded-box reading journaled anyway: $(cat "$JLOG")"
[ "$(_ledger_lines)" -eq 0 ] || fail "a sub-floor loaded-box reading painted a row: $(cat "$ANOMALY_LEDGER" 2>/dev/null)"
[ "$(_scribed)" -eq 0 ] || fail "a sub-floor loaded-box reading filed a tracker item"
ok

# ── (4) LOADED box, 90s — past the 77 floor, short of the 154 widened bar: the row/file split ───────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
_learn loaded_over
_phase_anomaly_observe loaded_over "loaded over" 90    # 90 > 77 (fires), 90 <= 154 (within widened margin)
grep -q '^phase_anomaly ' "$JLOG" || fail "a load-qualified reading lost its journal line: $(cat "$JLOG")"
grep -q 'phase_anomaly_filed.*result load_qualified' "$JLOG" || fail "no load_qualified filing result: $(cat "$JLOG")"
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" && fail "a load-qualified reading filed anyway: $(cat "$JLOG")"
[ "$(_scribed)" -eq 0 ] || fail "a load-qualified reading filed a tracker item — display signal must not cause tracker churn: $(cat "$SCRIBELOG")"
[ -s "$ANOMALY_LEDGER" ] || fail "no advisory row painted for a sub-widened-floor exceedance"
_last_row="$(tail -n1 "$ANOMALY_LEDGER")"
case "$_last_row" in *$'\t'load_qualified) : ;; *) fail "the ledger row was not tagged load_qualified: $(cat "$ANOMALY_LEDGER")" ;; esac
build_phase_anomalies
case "$ANOMALY_ROWS" in *"loaded over"*) ok ;; *) fail "the rendered row does not name the phase: $ANOMALY_ROWS" ;; esac

echo "ok — phase-anomaly floor margin (HERD-645): $pass checks passed"
