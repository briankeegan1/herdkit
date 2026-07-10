#!/usr/bin/env bash
# test-py-parity.sh — tests for the P3a journal-diff PARITY HARNESS (HERD-314, EPIC HERD-300).
#
# The harness is the engine port's acceptance instrument: canonicalize two journal event streams
# (strip timestamps/pids/paths, stable field order) and diff them.
#   • pysrc/herd/parity.py            — canonicalize + diff (exit 0 identical / 1 divergent / 2 infra)
#   • scripts/herd/sim/parity-run.sh  — drive a sim scenario, collect its journal, self-diff it
#
# This proves the two verification criteria from the item body:
#   (A) UNIT FIXTURES with known-divergent journals produce the report (value diff, length diff,
#       invalid JSON), AND a pair that differs ONLY in timestamps/pids/paths canonicalizes to
#       IDENTICAL (canonicalization does real work, not a byte compare).
#   (B) SELF-DIFF GREEN on sandbox-scenario.sh via parity-run.sh, with the SCORECARD read from file.
#
# Hermetic + stdlib-only (the P1 packaging rule): the fixture legs touch no journal/watcher/panes/
# gh/network; the sandbox leg runs the repo's own deterministic sim (no model call). If the sandbox
# scenario cannot run in this environment (infra), that leg SKIPS loudly — it never false-reds.
# Run:  bash tests/test-py-parity.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PYSRC="$REPO/pysrc"
PARITY_RUN="$REPO/scripts/herd/sim/parity-run.sh"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$PYSRC/herd/parity.py" ] || { echo "FAIL: pysrc/herd/parity.py missing" >&2; exit 1; }
[ -f "$PARITY_RUN" ]           || { echo "FAIL: scripts/herd/sim/parity-run.sh missing" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; skips=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
skip() { skips=$((skips+1)); printf '  – SKIP: %s\n' "$1"; }

parity() { PYTHONPATH="$PYSRC" python3 -m herd.parity "$@"; }

# ── (A1) canonicalization: identical events modulo ts/pid/paths → PARITY (exit 0) ────────────────
# Same event stream, but every volatile category differs: a different ts, a different pid, a
# different absolute log_path/tmp prefix. Canonicalization must fold them to identity.
cat > "$T/real.jsonl" <<'EOF'
{"ts":"2026-07-10T00:00:01Z","event":"review_dispatched","pr":42,"sha":"abc123","pid":9911,"model":"opus","log_path":"/tmp/run-aaa/review.log","pin":"base..abc123"}
{"ts":"2026-07-10T00:00:02Z","event":"healthcheck_started","pr":42,"slug":"feat","sha":"abc123","pid":9912,"log_path":"/tmp/run-aaa/health.log"}
{"ts":"2026-07-10T00:00:03Z","event":"healthcheck_outcome","pr":42,"slug":"feat","outcome":"CLEAN"}
{"ts":"2026-07-10T00:00:04Z","event":"verdict_recorded","pr":42,"sha":"abc123","value":"PASS","source":"reviewer"}
{"ts":"2026-07-10T00:00:05Z","event":"merge","pr":42,"slug":"feat","sha":"abc123","method":"squash","reason":"gates_passed"}
EOF
# Volatile-only twin: bumped ts (different order-of-magnitude), different pids, different tmp prefix,
# and one event with keys emitted in a DIFFERENT ORDER (stable field order must neutralize it).
cat > "$T/twin.jsonl" <<'EOF'
{"ts":"2026-07-10T09:99:99Z","event":"review_dispatched","pr":42,"sha":"abc123","pid":22001,"model":"opus","log_path":"/private/var/folders/zz/other/review.log","pin":"base..abc123"}
{"log_path":"/private/var/folders/zz/other/health.log","pid":22002,"ts":"2026-07-10T10:00:00Z","event":"healthcheck_started","pr":42,"slug":"feat","sha":"abc123"}
{"ts":"2026-07-10T10:00:01Z","event":"healthcheck_outcome","pr":42,"slug":"feat","outcome":"CLEAN"}
{"ts":"2026-07-10T10:00:02Z","event":"verdict_recorded","pr":42,"sha":"abc123","value":"PASS","source":"reviewer"}
{"ts":"2026-07-10T10:00:03Z","event":"merge","pr":42,"slug":"feat","sha":"abc123","method":"squash","reason":"gates_passed"}
EOF
if parity "$T/real.jsonl" "$T/twin.jsonl" >/dev/null 2>&1; then
  ok "canonicalization: ts/pid/path/field-order differences fold to PARITY (exit 0)"
else
  fail "volatile-only twin was reported divergent — canonicalization is incomplete"
fi

# ── (A2) a real VALUE divergence is reported and exits 1 ─────────────────────────────────────────
sed 's/"CLEAN"/"CODEERROR"/' "$T/real.jsonl" > "$T/div.jsonl"
out="$(parity "$T/real.jsonl" "$T/div.jsonl" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "value divergence should exit 1, got $rc"
printf '%s\n' "$out" | grep -q "DIVERGENT" || fail "value divergence: no DIVERGENT header"
printf '%s\n' "$out" | grep -q "outcome" || fail "value divergence: report did not name the 'outcome' field"
printf '%s\n' "$out" | grep -q "CODEERROR" || fail "value divergence: report did not show the shadow value"
ok "value divergence → per-mismatch report names the field, exit 1"

# ── (A3) a LENGTH divergence (missing event) is reported and exits 1 ─────────────────────────────
head -4 "$T/real.jsonl" > "$T/short.jsonl"
out="$(parity "$T/real.jsonl" "$T/short.jsonl" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "length divergence should exit 1, got $rc"
printf '%s\n' "$out" | grep -qi "MISSING from shadow" || fail "length divergence: missing-event not reported"
ok "length divergence → missing-event reported, exit 1"

# ── (A4) an unreadable/invalid journal is INFRA (exit 2), never a silent green ────────────────────
printf 'this is not json\n' > "$T/bad.jsonl"
parity "$T/real.jsonl" "$T/bad.jsonl" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "invalid JSON should exit 2 (infra), got $rc"
parity "$T/real.jsonl" "$T/no-such-file.jsonl" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "missing shadow file should exit 2 (infra), got $rc"
ok "invalid/missing journal → INFRA exit 2 (loud, not a false green)"

# ── (A5) --perturb round-trip: perturb touches ONLY volatile fields → self-diff PARITY ───────────
parity --perturb "$T/real.jsonl" > "$T/perturbed.jsonl" 2>/dev/null || fail "--perturb errored"
# The perturbed copy must differ on disk (ts/pid/paths changed) …
if cmp -s "$T/real.jsonl" "$T/perturbed.jsonl"; then
  fail "--perturb produced a byte-identical copy (it must change the volatile fields)"
fi
# … yet canonicalize back to identity.
parity "$T/real.jsonl" "$T/perturbed.jsonl" >/dev/null 2>&1 \
  || fail "perturbed copy diverged from source — perturb/canon are not inverse on volatile fields"
ok "--perturb changes volatile fields on disk yet canonicalizes back to PARITY"

# ── (A6) a divergence in a NON-volatile field survives perturbation (perturb can't mask a real diff)
sed 's/"squash"/"rebase"/' "$T/perturbed.jsonl" > "$T/perturbed-div.jsonl"
parity "$T/real.jsonl" "$T/perturbed-div.jsonl" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "a real (method) divergence under perturbation should still exit 1, got $rc"
ok "a non-volatile divergence is NOT masked by perturbation (exit 1)"

# ── (B) SELF-DIFF GREEN on the sandbox scenario via parity-run.sh, scorecard read from file ───────
# Runs the repo's deterministic sim (no model call). An infra inability to run the scenario SKIPS;
# a genuine parity divergence FAILS.
if ! command -v git >/dev/null 2>&1; then
  skip "parity-run self-diff: git unavailable"
else
  RUN_ART="$T/sandbox"; mkdir -p "$RUN_ART"
  run_out="$(bash "$PARITY_RUN" --artifacts "$RUN_ART" 2>&1)"; rc=$?
  case "$rc" in
    0)
      printf '%s\n' "$run_out" | grep -q "journal parity: OK" \
        || fail "parity-run exited 0 but did not report journal parity OK"
      printf '%s\n' "$run_out" | grep -q "scorecard:" \
        || fail "parity-run did not read/surface the scorecard from file"
      [ -f "$RUN_ART/scorecard.json" ] || fail "scenario scorecard.json missing after parity-run"
      [ -s "$RUN_ART/journal-real.jsonl" ] || fail "parity-run collected an empty real journal"
      ok "parity-run self-diff on sandbox-scenario.sh: GREEN + scorecard read from file"
      ;;
    2)
      skip "parity-run self-diff: scenario could not run in this env (infra, rc=2)"
      printf '%s\n' "$run_out" | tail -4 | sed 's/^/      /'
      ;;
    *)
      printf '%s\n' "$run_out" | tail -15 >&2
      fail "parity-run reported a real journal DIVERGENCE on a self-diff (rc=$rc) — canon bug"
      ;;
  esac
fi

echo "ALL PASS ($pass assertions, $skips skipped)"
