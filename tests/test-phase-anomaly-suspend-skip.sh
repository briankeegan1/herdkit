#!/usr/bin/env bash
# test-phase-anomaly-suspend-skip.sh — hermetic mutation-prove for HERD-512: the two guards that stop
# the HERD-496 phase-anomaly rail from false-filing.
#
# GROUNDED (journal, 2026-08-04): tick_cadence measures WALL CLOCK between tick invocations, so a
# macOS suspend / dark-wake window reads as a slow tick — 4 bogus anomaly items filed overnight
# (134s/189s/181s/2049s against a p95 of 35-173s), and the sleep-inflated samples went into the ROLLING
# BASELINE (tick_cadence median 32s → 129s), desensitizing the rail against a real stall.
#
# Same harness shape as tests/test-phase-anomaly-baselines.sh: sources the REAL agent-watch.sh in lib
# mode and drives _phase_anomaly_observe against the REAL pysrc/herd/store.py, with WORKTREES_DIR
# pinned to a throwaway temp dir. journal_append / _main_health_scribe are overridden to log files.
# _wake_probe_epoch is the declared TEST SEAM for leg (a) — overriding it places a fake suspend/wake
# boundary inside vs outside a measured interval without needing a machine that actually sleeps.
#
# Under test:
#   (a1) _sysctl_timeval_epoch parses the real darwin `{ sec = N, usec = M } <date>` shape, a bare
#        integer, and rejects garbage (empty + rc 1 → the probe reads as unavailable).
#   (a2) probe UNAVAILABLE (rc 1) → observe exactly as before HERD-512 (fail-soft, never silences).
#   (a3) wake boundary OUTSIDE the measured interval → observe + file, unchanged.
#   (a4) wake boundary INSIDE the measured interval → skipped ENTIRELY: no journal line, no ledger
#        row, no filing, and — the load-bearing half — NO BASELINE SAMPLE (the store is untouched).
#   (b1) two above-threshold readings for the SAME phase inside ANOMALY_FILE_COOLDOWN_SECS collapse to
#        ONE enqueued + one result=cooldown, while BOTH still journal `phase_anomaly` and BOTH still
#        paint a console ledger row (the operator loses no visibility).
#   (b2) a DIFFERENT phase is not gagged by another phase's cooldown (the cooldown is PER phase).
#   (b3) once the window elapses, the same phase files again.
#   (b4) ANOMALY_FILE_COOLDOWN_SECS=0 is off — the pre-HERD-512 behavior, every reading may file.
#   (c)  ANOMALY_BASELINES=off stays byte-inert: neither guard writes any state at all.
#
# Run:  bash tests/test-phase-anomaly-suspend-skip.sh
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
# tests/test-phase-anomaly-load-qualified.sh; this file exercises the wake-skip + cooldown rails alone.
export HERD_FAKE_LOADAVG=0
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _sysctl_timeval_epoch _wake_probe_epoch _interval_spans_wake \
          _anomaly_file_cooldown_secs _anomaly_file_in_cooldown _anomaly_file_stamp \
          _phase_anomaly_observe; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
TREES="$WORKTREES_DIR"

JLOG="$T/journal.log"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
SCRIBELOG="$T/scribe.log"
_main_health_scribe() { printf '===\n%s\n' "$1" >> "$SCRIBELOG"; }

_baseline_file() { printf '%s' "$TREES/.agent-watch-phase-duration-$1"; }
# Count helpers that always print a bare integer — `grep -c` exits 1 on a zero count, so the naive
# `cmd || echo 0` shape would print "0" TWICE on an existing-but-empty log.
_count_matches(){ local n; n="$(grep -c "$1" "$2" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac; printf '%s' "$n"; }
_scribed(){ _count_matches '^===$' "$SCRIBELOG"; }
_ledger_lines(){ _count_matches '' "${ANOMALY_LEDGER:-/nonexistent}"; }

# The measurement clock is PINNED for the whole prove, so every interval below is exact and the
# suspend/wake fixtures can be placed relative to a known "now" rather than a racing wall clock.
NOW=1000000
export HERD_FAKE_NOW="$NOW"

# _learn <phase> — 5 calm readings (100 110 90 100 120), enough for _ANOMALY_MIN_SAMPLES; prior p95 is
# then 120, so a later reading past the HERD-645-floored threshold (max(180,150)=180) is anomalous.
# Runs with the wake probe UNAVAILABLE.
_learn() {
  local v
  _wake_probe_epoch() { return 1; }
  for v in 100 110 90 100 120; do _phase_anomaly_observe "$1" "$1" "$v"; done
}

# ── (a1) _sysctl_timeval_epoch parses the shapes the darwin probe actually sees ─────────────────────
got="$(_sysctl_timeval_epoch '{ sec = 1785818873, usec = 568344 } Tue Aug  4 00:47:53 2026')"
[ "$got" = "1785818873" ] || fail "timeval parse: want 1785818873, got '$got'"
got="$(_sysctl_timeval_epoch '1785818873')"
[ "$got" = "1785818873" ] || fail "bare-int parse: want 1785818873, got '$got'"
_sysctl_timeval_epoch 'not a timeval' >/dev/null 2>&1 && fail "garbage must not parse as an epoch"
_sysctl_timeval_epoch '' >/dev/null 2>&1 && fail "an empty probe value must not parse as an epoch"
ok

# _interval_spans_wake's own truth table, against the same seam the chokepoint uses.
_wake_probe_epoch() { printf '%s' "$(( NOW - 20 ))"; }
_interval_spans_wake "$(( NOW - 40 ))" "$NOW" || fail "a wake INSIDE the interval must read as spanning"
_interval_spans_wake "$(( NOW - 10 ))" "$NOW" && fail "a wake BEFORE the interval must not read as spanning"
_wake_probe_epoch() { return 1; }
_interval_spans_wake "$(( NOW - 40 ))" "$NOW" && fail "an unavailable probe must fail soft to 'no wake'"
ok

export ANOMALY_BASELINES=on
export ANOMALY_FILE_COOLDOWN_SECS=0     # leg (a) isolates the wake guard; leg (b) arms the cooldown

# ── (a2) probe UNAVAILABLE → byte-identical to pre-HERD-512: the anomaly still fires ────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
_learn noprobe_phase
[ ! -s "$JLOG" ] || fail "the learning samples themselves fired: $(cat "$JLOG")"
_wake_probe_epoch() { return 1; }
_phase_anomaly_observe noprobe_phase "noprobe phase" 400
grep -q '^phase_anomaly ' "$JLOG" || fail "no-probe host lost the anomaly: $(cat "$JLOG")"
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" || fail "no-probe host did not file: $(cat "$JLOG")"
ok

# ── (a3) wake OUTSIDE the measured interval → observe + file, unchanged ─────────────────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
_learn outside_phase
_wake_probe_epoch() { printf '%s' "$(( NOW - 500 ))"; }   # interval is [NOW-400, NOW] — well clear
_phase_anomaly_observe outside_phase "outside phase" 400
grep -q '^phase_anomaly ' "$JLOG" || fail "a wake outside the interval suppressed a REAL anomaly: $(cat "$JLOG")"
[ "$(_ledger_lines)" -eq 1 ] || fail "expected one ledger row: $(cat "$ANOMALY_LEDGER" 2>/dev/null)"
[ "$(_scribed)" -eq 1 ] || fail "expected one filed item: $(cat "$SCRIBELOG")"
ok

# ── (a4) wake INSIDE the measured interval → skipped entirely, INCLUDING the baseline sample ────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
_learn asleep_phase
BASE_BEFORE="$T/asleep-before.txt"; cp "$(_baseline_file asleep_phase)" "$BASE_BEFORE"
_wake_probe_epoch() { printf '%s' "$(( NOW - 20 ))"; }     # inside [NOW-400, NOW]
_phase_anomaly_observe asleep_phase "asleep phase" 400
[ ! -s "$JLOG" ]      || fail "a sleep-spanning interval journaled anyway: $(cat "$JLOG")"
[ "$(_ledger_lines)" -eq 0 ] || fail "a sleep-spanning interval painted a row: $(cat "$ANOMALY_LEDGER")"
[ "$(_scribed)" -eq 0 ] || fail "a sleep-spanning interval filed an item: $(cat "$SCRIBELOG")"
cmp -s "$BASE_BEFORE" "$(_baseline_file asleep_phase)" \
  || fail "a sleep-spanning interval POLLUTED the rolling baseline (the HERD-512 root cause)"
ok

# The same phase, same duration, with the boundary moved out of the interval, still fires — proving
# (a4) suppressed the reading for the WAKE reason and not because the phase went quiet.
_wake_probe_epoch() { printf '%s' "$(( NOW - 500 ))"; }
_phase_anomaly_observe asleep_phase "asleep phase" 400
grep -q '^phase_anomaly ' "$JLOG" || fail "the skip was not wake-scoped — the phase never fires: $(cat "$JLOG")"
ok

# ── (b) PER-PHASE FILING COOLDOWN ───────────────────────────────────────────────────────────────────
_wake_probe_epoch() { return 1; }        # leg (b) isolates the cooldown; the wake guard is inert here
export ANOMALY_FILE_COOLDOWN_SECS=1800

# (b1) two DISTINCT above-threshold readings for the same phase inside the window
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
rm -f "$(_anomaly_file_stamp_path burst_phase)"
_learn burst_phase
_phase_anomaly_observe burst_phase "burst phase" 400     # prior p95 120 → threshold max(180,150)=180 → fires, files
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" || fail "first reading did not file: $(cat "$JLOG")"
_phase_anomaly_observe burst_phase "burst phase" 2000    # prior p95 400 → threshold max(600,430)=600 → fires again
grep -q 'phase_anomaly_filed.*result cooldown' "$JLOG" || fail "second reading was not withheld: $(cat "$JLOG")"
[ "$(_scribed)" -eq 1 ] || fail "the cooldown did not collapse the burst: $(cat "$SCRIBELOG")"
# visibility is NOT what the cooldown withholds — both readings still journal and still paint a row
[ "$(grep -c '^phase_anomaly ' "$JLOG")" -eq 2 ] || fail "a cooled-down anomaly lost its journal line: $(cat "$JLOG")"
[ "$(_ledger_lines)" -eq 2 ] || fail "a cooled-down anomaly lost its console row: $(cat "$ANOMALY_LEDGER")"
ok

# (b2) the cooldown is PER PHASE — a different phase is not gagged by burst_phase's stamp
: > "$JLOG"; : > "$SCRIBELOG"
rm -f "$(_anomaly_file_stamp_path other_phase)"
_learn other_phase
_phase_anomaly_observe other_phase "other phase" 400
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" || fail "one phase's cooldown gagged another: $(cat "$JLOG")"
ok

# (b3) once the window elapses, the same phase files again
: > "$JLOG"; : > "$SCRIBELOG"
export HERD_FAKE_NOW="$(( NOW + 1801 ))"
_phase_anomaly_observe burst_phase "burst phase" 9000    # a fresh identity, past the elapsed window
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" || fail "the cooldown never expired: $(cat "$JLOG")"
[ "$(_scribed)" -eq 1 ] || fail "expected exactly one filing after the window elapsed: $(cat "$SCRIBELOG")"
export HERD_FAKE_NOW="$NOW"
ok

# (b4) 0 = off — the pre-HERD-512 behavior: two distinct readings both file
: > "$JLOG"; : > "$SCRIBELOG"
export ANOMALY_FILE_COOLDOWN_SECS=0
rm -f "$(_anomaly_file_stamp_path off_cooldown_phase)"
_wake_probe_epoch() { return 1; }
_learn off_cooldown_phase
_phase_anomaly_observe off_cooldown_phase "off cooldown phase" 400
_phase_anomaly_observe off_cooldown_phase "off cooldown phase" 2000
[ "$(_scribed)" -eq 2 ] || fail "cooldown=0 withheld a filing anyway: $(cat "$SCRIBELOG")"
grep -q 'result cooldown' "$JLOG" && fail "cooldown=0 journaled a cooldown result: $(cat "$JLOG")"
ok

# a non-numeric value falls back to the DOCUMENTED default, never to 0 (a typo must not re-arm the storm)
ANOMALY_FILE_COOLDOWN_SECS=notanumber
[ "$(_anomaly_file_cooldown_secs)" = "1800" ] || fail "a non-numeric cooldown did not fall back to 1800"
ANOMALY_FILE_COOLDOWN_SECS=0
ok

# ── (c) ANOMALY_BASELINES=off — both guards stay byte-inert ─────────────────────────────────────────
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
unset ANOMALY_BASELINES
export ANOMALY_FILE_COOLDOWN_SECS=1800
_wake_probe_epoch() { printf '%s' "$(( NOW - 20 ))"; }
_phase_anomaly_observe dormant_phase "dormant phase" 99999
[ ! -s "$JLOG" ] || fail "off by default: a journal line was written: $(cat "$JLOG")"
[ "$(_scribed)" -eq 0 ] || fail "off by default: an item was filed"
[ "$(_ledger_lines)" -eq 0 ] || fail "off by default: a row was written"
[ ! -f "$(_anomaly_file_stamp_path dormant_phase)" ] || fail "off by default: a cooldown stamp was written"
[ ! -f "$(_baseline_file dormant_phase)" ] || fail "off by default: the store was touched at all"
ok

echo "ok — phase-anomaly suspend-skip + filing cooldown (HERD-512): $pass checks passed"
