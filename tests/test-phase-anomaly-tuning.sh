#!/usr/bin/env bash
# test-phase-anomaly-tuning.sh — hermetic mutation-prove for HERD-807: the three anomaly-rail
# sensitivity fixes on top of HERD-496's per-phase baselines.
#
#   1. ANOMALY_THRESHOLD_PCT + ANOMALY_FLOOR_MARGIN_SECS are now VALIDATED CONFIG KEYS (were the inline
#      constants _ANOMALY_THRESHOLD_PCT / _ANOMALY_FLOOR_MARGIN_SECS). UNSET is byte-identical to the
#      old hardcoded 150/30; setting either moves the filing bar; a non-numeric value falls back to the
#      default.
#   2. JUDGE-BEFORE-LEARN: an ABOVE-BAR reading is judged but NEVER folded into the rolling baseline, so
#      the outliers the rail flags can no longer drag up the p95 it judges against (observed: render-pass
#      p95 crept 44s→37m). A below-bar (normal) reading IS still learned.
#   3. SUSPEND SANITY CLASSIFIER: a reading past 20x its learned p95 that ALSO coincides with a matching
#      gap in the engine journal's own tick stream is a wall-clock suspend artifact the darwin wake probe
#      missed — journaled result=suspend-artifact, never filed, never learned. NEGATIVE CONTROLS: a
#      genuine ~2x degradation with no gap still files; a genuinely massive (>20x) but BUSY-journal
#      degradation (the watcher kept ticking) still files.
#   4. ANOMALY_BASELINES=off stays byte-inert through all of the above.
#
# Same harness shape as tests/test-phase-anomaly-suspend-skip.sh: sources the REAL agent-watch.sh in lib
# mode and drives _phase_anomaly_observe against the REAL pysrc/herd/store.py, WORKTREES_DIR pinned to a
# throwaway temp dir. journal_append / _main_health_scribe are overridden to log files. HERD_FAKE_NOW
# pins the measurement clock; the wake probe is pinned UNAVAILABLE so this file isolates the tuning +
# learn-exclusion + suspend-classifier rails from HERD-512's darwin sysctl guards.
#
# Run:  bash tests/test-phase-anomaly-tuning.sh
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
export HERD_FAKE_LOADAVG=0     # pin the box QUIET — the load-qualified rail has its own fixture
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"

for fn in _anomaly_threshold_pct _anomaly_floor_margin_secs _phase_duration_peek \
          _anomaly_journal_max_gap_secs _anomaly_reading_is_suspend_artifact _phase_anomaly_observe; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done
TREES="$WORKTREES_DIR"

JLOG="$T/journal.log"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }
SCRIBELOG="$T/scribe.log"
_main_health_scribe() { printf '===\n%s\n' "$1" >> "$SCRIBELOG"; }
_wake_probe_epoch() { return 1; }     # wake guard OUT — this file is about the other three rails

_baseline_file() { printf '%s' "$TREES/.agent-watch-phase-duration-$1"; }
_count_matches(){ local n; n="$(grep -c "$1" "$2" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac; printf '%s' "$n"; }
_scribed(){ _count_matches '^===$' "$SCRIBELOG"; }
_ledger_lines(){ _count_matches '' "${ANOMALY_LEDGER:-/nonexistent}"; }
_baseline_lines(){ local f; f="$(_baseline_file "$1")"; [ -f "$f" ] && wc -l < "$f" | tr -cd '0-9' || printf 0; }

NOW=1000000
export HERD_FAKE_NOW="$NOW"

# _learn <phase> <v...> — feed calm readings; default set has nearest-rank p95 (n=5 ⇒ max) of 120.
_learn() {
  local ph="$1"; shift
  local vals=("$@"); [ "${#vals[@]}" -gt 0 ] || vals=(100 110 90 100 120)
  local v; for v in "${vals[@]}"; do _phase_anomaly_observe "$ph" "$ph" "$v"; done
}

# _iso <epoch> — ISO-8601 UTC, the exact shape journal.sh writes.
_iso(){ python3 -c 'import sys,datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
_jline(){ printf '{"ts":"%s","event":"tick"}\n' "$(_iso "$1")"; }

export ANOMALY_BASELINES=on
export ANOMALY_FILE_COOLDOWN_SECS=0     # isolate from the cooldown rail (its own prove exists)

# ══ 1. CONFIG KEYS ═════════════════════════════════════════════════════════════════════════════════

# (1a) UNSET → byte-identical to the old hardcoded 150/30: threshold = max(120*1.5=180, 120+30=150)=180.
unset ANOMALY_THRESHOLD_PCT ANOMALY_FLOOR_MARGIN_SECS
[ "$(_anomaly_threshold_pct)" = "150" ]   || fail "default ANOMALY_THRESHOLD_PCT should be 150"
[ "$(_anomaly_floor_margin_secs)" = "30" ] || fail "default ANOMALY_FLOOR_MARGIN_SECS should be 30"
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
_learn t_def_under; _phase_anomaly_observe t_def_under "t def under" 179   # 179 <= 180 → silent
[ ! -s "$JLOG" ] || fail "179 under the default 180 bar fired anyway: $(cat "$JLOG")"
_learn t_def_over;  _phase_anomaly_observe t_def_over  "t def over"  181   # 181 > 180 → fires
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" || fail "181 over the default 180 bar did not file: $(cat "$JLOG")"
ok

# (1b) ANOMALY_THRESHOLD_PCT widens the pct leg: 300% → threshold = max(120*3=360, 150)=360.
export ANOMALY_THRESHOLD_PCT=300
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
_learn t_pct_under; _phase_anomaly_observe t_pct_under "t pct under" 300   # 300 <= 360 → now silent (fired at default)
[ ! -s "$JLOG" ] || fail "300 under the widened 360 bar fired anyway: $(cat "$JLOG")"
_learn t_pct_over;  _phase_anomaly_observe t_pct_over  "t pct over"  400   # 400 > 360 → fires
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" || fail "400 over the widened 360 bar did not file: $(cat "$JLOG")"
unset ANOMALY_THRESHOLD_PCT
ok

# (1c) ANOMALY_FLOOR_MARGIN_SECS widens the floor leg: 1000 → threshold = max(180, 120+1000=1120)=1120.
export ANOMALY_FLOOR_MARGIN_SECS=1000
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
_learn t_floor_under; _phase_anomaly_observe t_floor_under "t floor under" 500   # 500 <= 1120 → silent
[ ! -s "$JLOG" ] || fail "500 under the widened 1120 floor fired anyway: $(cat "$JLOG")"
unset ANOMALY_FLOOR_MARGIN_SECS
ok

# (1d) a non-numeric value falls back to the documented default, never disarms the bar.
export ANOMALY_THRESHOLD_PCT=notanumber
[ "$(_anomaly_threshold_pct)" = "150" ] || fail "a non-numeric ANOMALY_THRESHOLD_PCT did not fall back to 150"
export ANOMALY_FLOOR_MARGIN_SECS=oops
[ "$(_anomaly_floor_margin_secs)" = "30" ] || fail "a non-numeric ANOMALY_FLOOR_MARGIN_SECS did not fall back to 30"
unset ANOMALY_THRESHOLD_PCT ANOMALY_FLOOR_MARGIN_SECS
ok

# ══ 2. JUDGE-BEFORE-LEARN: the anomaly-poisoning fix ═══════════════════════════════════════════════

# (2a) a NORMAL (below-bar) reading IS folded into the rolling baseline — the window keeps learning.
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
_learn learn_normal
[ "$(_baseline_lines learn_normal)" -eq 5 ] || fail "expected 5 learned samples, got $(_baseline_lines learn_normal)"
_phase_anomaly_observe learn_normal "learn normal" 130   # 130 <= 180 → normal → recorded
[ "$(_baseline_lines learn_normal)" -eq 6 ] || fail "a normal reading was NOT learned (window did not grow)"
[ ! -s "$JLOG" ] || fail "a normal reading fired: $(cat "$JLOG")"
ok

# (2b) an ABOVE-BAR reading is judged+filed but NEVER folded in — the baseline is byte-identical after.
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
_learn learn_anom
BASE_BEFORE="$T/learn-anom-before.txt"; cp "$(_baseline_file learn_anom)" "$BASE_BEFORE"
_phase_anomaly_observe learn_anom "learn anom" 400   # 400 > 180 → fires + files
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" || fail "the above-bar reading did not file: $(cat "$JLOG")"
cmp -s "$BASE_BEFORE" "$(_baseline_file learn_anom)" \
  || fail "an above-bar reading POLLUTED the rolling baseline (the render-pass 44s→37m root cause)"
ok

# (2c) the poisoning story end to end: with the OLD fold-in-everything behavior, a repeated anomaly would
# ratchet its own p95 up until the next equal reading fell UNDER the (now inflated) bar and went silent.
# With judge-before-learn each equal above-bar reading is judged against the SAME learned p95 and fires.
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
export ANOMALY_FILE_COOLDOWN_SECS=0
_learn ratchet
for i in 1 2 3; do _phase_anomaly_observe ratchet "ratchet" 400; done
[ "$(_count_matches '^phase_anomaly ' "$JLOG")" -eq 3 ] \
  || fail "a repeated above-bar reading stopped firing — the baseline was still being poisoned: $(cat "$JLOG")"
ok

# ══ 3. SUSPEND SANITY CLASSIFIER ══════════════════════════════════════════════════════════════════
# Learn a tight p95 of 44, so a huge reading (2000) is well past 20x (=880).
export JOURNAL_FILE="$T/synthetic-journal.jsonl"

# (3a) >20x p95 WITH a matching journal gap → suspend-artifact: journaled, NEVER filed, NEVER learned.
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
_learn suspend_match 40 42 38 41 44
BASE_BEFORE="$T/suspend-before.txt"; cp "$(_baseline_file suspend_match)" "$BASE_BEFORE"
: > "$JOURNAL_FILE"                       # a 1850s hole ending 50s before now — the watcher went quiet
_jline $((NOW - 1900)) >> "$JOURNAL_FILE"
_jline $((NOW - 50))   >> "$JOURNAL_FILE"
_phase_anomaly_observe suspend_match "render pass" 2000   # 2000 > 20*44=880, gap 1850 >= 1000
grep -q '^phase_anomaly .*result suspend-artifact' "$JLOG" || fail "a suspend artifact was not journaled as such: $(cat "$JLOG")"
[ "$(_scribed)" -eq 0 ]      || fail "a suspend artifact was FILED to the tracker: $(cat "$SCRIBELOG")"
[ "$(_ledger_lines)" -eq 0 ] || fail "a suspend artifact painted a console row: $(cat "$ANOMALY_LEDGER" 2>/dev/null)"
grep -q 'phase_anomaly_filed' "$JLOG" && fail "a suspend artifact reached the filing legs: $(cat "$JLOG")"
cmp -s "$BASE_BEFORE" "$(_baseline_file suspend_match)" \
  || fail "a suspend artifact POLLUTED the rolling baseline"
ok

# _anomaly_reading_is_suspend_artifact's own truth table against the same synthetic journal.
_anomaly_reading_is_suspend_artifact 2000 44 || fail "2000 vs p95 44 WITH a matching gap must classify as suspend"
_anomaly_reading_is_suspend_artifact 800  44 && fail "800 is under 20x p95 — must NOT classify as suspend"
ok

# (3b) NEGATIVE CONTROL — a genuinely massive (>20x) but BUSY-journal degradation still files. The
# watcher kept ticking every 60s through the whole interval, so there is no matching gap: real work.
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
_learn busy_big 40 42 38 41 44
python3 - "$JOURNAL_FILE" "$NOW" <<'PY'
import sys, datetime
jf, now = sys.argv[1], int(sys.argv[2])
with open(jf, "w", encoding="utf-8") as fh:
    off = 2100
    while off >= 0:                       # a steady 60s tick across [now-2100, now] — no hole
        ts = datetime.datetime.fromtimestamp(now - off, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        fh.write('{"ts":"%s","event":"tick"}\n' % ts)
        off -= 60
PY
_phase_anomaly_observe busy_big "busy big" 2000   # 2000 > 20x, but journal never went quiet
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" || fail "a busy-journal massive degradation was wrongly suppressed: $(cat "$JLOG")"
grep -q 'result suspend-artifact' "$JLOG" && fail "a busy-journal degradation was mislabeled a suspend artifact: $(cat "$JLOG")"
[ "$(_scribed)" -eq 1 ] || fail "a genuine massive degradation did not file: $(cat "$SCRIBELOG")"
ok

# (3c) NEGATIVE CONTROL (the spec's own) — a genuine ~2x degradation with no gap still files. 2x never
# even reaches the 20x classifier, so the journal is irrelevant; it files on the ordinary bar.
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
: > "$JOURNAL_FILE"                        # empty journal — no gap probe possible
_learn twox 40 42 38 41 44
_phase_anomaly_observe twox "two x" 100    # 100 = ~2.3x p95 44, > bar max(66,74)=74, < 20x=880
grep -q 'phase_anomaly_filed.*result enqueued' "$JLOG" || fail "a genuine 2x degradation did not file: $(cat "$JLOG")"
grep -q 'result suspend-artifact' "$JLOG" && fail "a 2x degradation was mislabeled a suspend artifact: $(cat "$JLOG")"
ok

# (3d) the gap probe itself is FAIL-SOFT: no journal file → no gap → not a suspend artifact (never
# silences a genuine anomaly on a blind guess).
unset JOURNAL_FILE
rm -f "$TREES/.herd/journal.jsonl"
_anomaly_reading_is_suspend_artifact 2000 44 && fail "with no journal to read, a reading must NOT classify as suspend"
export JOURNAL_FILE="$T/synthetic-journal.jsonl"
ok

# ══ 4. ANOMALY_BASELINES=off — every HERD-807 leg stays byte-inert ═════════════════════════════════
: > "$JLOG"; : > "$SCRIBELOG"; rm -f "$ANOMALY_LEDGER"
unset ANOMALY_BASELINES
: > "$JOURNAL_FILE"
_jline $((NOW - 1900)) >> "$JOURNAL_FILE"
_jline $((NOW - 50))   >> "$JOURNAL_FILE"
_phase_anomaly_observe dormant "dormant" 2000
[ ! -s "$JLOG" ]           || fail "off by default: a journal line was written: $(cat "$JLOG")"
[ "$(_scribed)" -eq 0 ]    || fail "off by default: an item was filed"
[ "$(_ledger_lines)" -eq 0 ] || fail "off by default: a row was written"
[ ! -f "$(_baseline_file dormant)" ] || fail "off by default: the store was touched at all"
ok

echo "ok — phase-anomaly tuning + judge-before-learn + suspend classifier (HERD-807): $pass checks passed"
