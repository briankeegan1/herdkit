#!/usr/bin/env bash
# test-phase-anomaly-load-qualified.sh — hermetic mutation-prove for HERD-618: the phase-anomaly
# rail's FILING bar widens while this box looks contended, so a marginal exceedance produced by
# ambient load (not a real regression) journals as load-qualified instead of filing a tracker item.
#
# GROUNDED (2026-08-10): the ANOMALY_BASELINES rail false-filed two tick-cadence anomaly items under
# heavy drain load (15m loadavg ~11 on 14 cores) for exceedances only marginally past their learned
# p95 — the baseline was learned on a quieter box, so an under-load reading routinely clears the
# normal 2x-p95 threshold without being a real stall. Same class of false-file as HERD-512's
# suspend-skip fix; this is the load-side counterpart.
#
# Same harness shape as tests/test-phase-anomaly-baselines.sh and
# tests/test-phase-anomaly-suspend-skip.sh: sources the REAL agent-watch.sh in lib mode and drives
# _phase_anomaly_observe against the REAL pysrc/herd/store.py. loadavg is driven via HERD_FAKE_LOADAVG
# (_health_loadavg_1m's declared test seam, shared with ENV_SUSPECT_TIMEOUT's own HERD-546 tests) so
# every fixture below is deterministic regardless of the real box's ambient load.
#
# Under test:
#   (1) _anomaly_load_high: fail-soft on an unreadable/empty loadavg (never guesses "high"); true once
#       loadavg1m >= HEALTH_LOAD_THRESHOLD; a non-numeric HEALTH_LOAD_THRESHOLD falls back to 4.
#   (2) LOADED box + an exceedance past the normal threshold but short of the WIDENED (2x) margin →
#       journals `phase_anomaly` + paints a ledger row TAGGED load_qualified, does NOT file, and
#       journals `phase_anomaly_filed result load_qualified`.
#   (3) The SAME reading on a QUIET box (loadavg under threshold) → files normally, untagged row.
#   (4) LOADED box + an exceedance BEYOND the widened margin → files anyway, even under load.
#   (5) ANOMALY_BASELINES=off stays byte-inert even under load (the ship-dormant gate is checked
#       before the load probe is ever consulted).
#
# Run:  bash tests/test-phase-anomaly-load-qualified.sh
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
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _anomaly_load_high _phase_anomaly_observe _phase_anomaly_row build_phase_anomalies; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
TREES="$WORKTREES_DIR"

JLOG="$T/journal.log"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
SCRIBELOG="$T/scribe.log"
_main_health_scribe() { printf '===\n%s\n' "$1" >> "$SCRIBELOG"; }

_baseline_file() { printf '%s' "$TREES/.agent-watch-phase-duration-$1"; }
_count_matches(){ local n; n="$(grep -c "$1" "$2" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac; printf '%s' "$n"; }
_scribed(){ _count_matches '^===$' "$SCRIBELOG"; }

# The wake guard is orthogonal to this rail — pin it unavailable so it never masks a reading here.
_wake_probe_epoch() { return 1; }

NOW=2000000
export HERD_FAKE_NOW="$NOW"

# _learn <phase> — 5 calm readings (100 110 90 100 120); prior p95 is then 120 → HERD-645-floored
# normal threshold max(120*1.5=180, 120+30=150)=180 (pct-dominant at this scale, so the readings below
# exercise the SAME load-margin math PR 737 originally proved — the floor's own edge behavior has its
# dedicated fixture in tests/test-phase-anomaly-floor-margin.sh) → widened under-load threshold 360
# (2x, HERD-618's default margin).
_learn() {
  local v
  for v in 100 110 90 100 120; do _phase_anomaly_observe "$1" "$1" "$v"; done
}

export ANOMALY_BASELINES=on
export ANOMALY_FILE_COOLDOWN_SECS=0   # isolate this rail from the cooldown rail (its own prove exists)
export HEALTH_LOAD_THRESHOLD=8

# ── (1) _anomaly_load_high truth table ───────────────────────────────────────────────────────────
# _health_loadavg_1m falls through to a REAL sysctl/proc read once HERD_FAKE_LOADAVG is unset/empty
# (there is always a real box under the test), so the "probe unavailable" leg overrides the probe
# function in a SUBSHELL — the redefinition never leaks back into the parent shell's function table.
( _health_loadavg_1m() { return 1; }; _anomaly_load_high ) \
  && fail "an empty/unreadable loadavg must fail soft to 'not high'"
ok
export HERD_FAKE_LOADAVG=7
_anomaly_load_high && fail "7 must read as under an 8 threshold"
ok
export HERD_FAKE_LOADAVG=8
_anomaly_load_high || fail "8 must read as AT the 8 threshold (>=, not >)"
ok
export HERD_FAKE_LOADAVG=11
_anomaly_load_high || fail "11 must read as over the 8 threshold"
ok
HEALTH_LOAD_THRESHOLD=notanumber
_anomaly_load_high || fail "a non-numeric threshold must fall back to the documented default (4), and 11 clears 4"
HEALTH_LOAD_THRESHOLD=8
ok

# ── (2) LOADED box, moderate exceedance (past threshold=24, short of widened=48) ────────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
export HERD_FAKE_LOADAVG=11    # mirrors the grounding incident's contended box
_learn loaded_phase
[ ! -s "$JLOG" ] || fail "the learning samples themselves fired under load: $(cat "$JLOG")"
_phase_anomaly_observe loaded_phase "loaded phase" 300    # 300 > 180 (fires), 300 <= 360 (within widened margin)
grep -q '^phase_anomaly ' "$JLOG" || fail "a load-qualified reading lost its journal line: $(cat "$JLOG")"
grep -q 'phase_anomaly_filed.*result load_qualified' "$JLOG" || fail "no load_qualified filing result: $(cat "$JLOG")"
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" && fail "a load-qualified reading filed anyway: $(cat "$JLOG")"
[ "$(_scribed)" -eq 0 ] || fail "a load-qualified reading filed a tracker item: $(cat "$SCRIBELOG")"
[ -s "$ANOMALY_LEDGER" ] || fail "no advisory row painted"
grep -q "loaded phase" "$ANOMALY_LEDGER" || fail "the ledger row does not name the phase: $(cat "$ANOMALY_LEDGER")"
_last_row="$(tail -n1 "$ANOMALY_LEDGER")"
case "$_last_row" in *$'\t'load_qualified) : ;; *) fail "the ledger row was not tagged load_qualified: $(cat "$ANOMALY_LEDGER")" ;; esac
build_phase_anomalies
case "$ANOMALY_ROWS" in *"load-qualified"*) ok ;; *) fail "the rendered row does not show the load-qualified tag: $ANOMALY_ROWS" ;; esac

# ── (3) the SAME reading on a QUIET box still files ─────────────────────────────────────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
export HERD_FAKE_LOADAVG=2      # under the 8 threshold
_learn quiet_phase
_phase_anomaly_observe quiet_phase "quiet phase" 300
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" || fail "the same exceedance on a quiet box did not file: $(cat "$JLOG")"
grep -q 'result load_qualified' "$JLOG" && fail "a quiet box journaled a load_qualified result: $(cat "$JLOG")"
[ "$(_scribed)" -eq 1 ] || fail "expected exactly one filed item on a quiet box: $(cat "$SCRIBELOG")"
_last_row="$(tail -n1 "$ANOMALY_LEDGER")"
case "$_last_row" in *$'\t'load_qualified) fail "a quiet-box row was tagged load_qualified: $(cat "$ANOMALY_LEDGER")" ;; esac
ok

# ── (4) LOADED box, exceedance BEYOND the widened margin still files ────────────────────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
export HERD_FAKE_LOADAVG=11
_learn beyond_phase
_phase_anomaly_observe beyond_phase "beyond phase" 400    # 400 > 360 (widened) — files despite load
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" || fail "an exceedance beyond the widened margin did not file under load: $(cat "$JLOG")"
[ "$(_scribed)" -eq 1 ] || fail "expected exactly one filed item beyond the widened margin: $(cat "$SCRIBELOG")"
ok

# ── (5) ANOMALY_BASELINES=off stays byte-inert even under heavy load ────────────────────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
unset ANOMALY_BASELINES
export HERD_FAKE_LOADAVG=99
_phase_anomaly_observe dormant_phase "dormant phase" 99999
[ ! -s "$JLOG" ]      || fail "off by default: a journal line was written under load: $(cat "$JLOG")"
[ "$(_scribed)" -eq 0 ] || fail "off by default: an item was filed under load"
[ ! -f "$(_baseline_file dormant_phase)" ] || fail "off by default: the store was touched at all"
ok

echo "ok — phase-anomaly load-qualified filing margin (HERD-618): $pass checks passed"
