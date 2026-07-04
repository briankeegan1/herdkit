#!/usr/bin/env bash
# test-benchmark-drain.sh — hermetic proof of the herdkit-vs-harness FALSIFICATION drain benchmark.
#
# The benchmark (scripts/herd/sim/benchmark-drain.sh) exercises the ONE workload the raw Claude
# harness architecturally cannot complete (docs/positioning-thesis.md): drain an N-item backlog
# unattended, SURVIVING an interruption, resuming from durable state alone. This test asserts:
#
#   (a) HAPPY DRAIN — a fresh N=4 drain exits 0; every item's stub change lands on main; all four
#       backlog items flip to ✅; the worktrees/branches are torn down and main's tree is clean; the
#       scorecard reports result=pass with items_drained=4, duplicates=0, resumed_after_kill=false.
#   (b) SCORECARD SHAPE — the required drain fields are all present and machine-readable.
#   (c) RESTART SURVIVAL — --kill-at 2 hard-exits (137) after the 2nd item, leaving 2 ✅ / 2 🔜 on
#       disk; a plain re-run against the SAME --state resumes from that durable state, completes all
#       4 with 0 DUPLICATES, and the scorecard reports resumed_after_kill=true. This is the core
#       time/presence claim: no in-memory carryover, yet the run survives the crash.
#
# Fully hermetic: local git only, NO herdr, NO network, NO model. Mirrors tests/test-sandbox-sim.sh.
# Run:  bash tests/test-benchmark-drain.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DRAIN="$HERE/../scripts/herd/sim/benchmark-drain.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$DRAIN" ] || fail "missing $DRAIN"

# ── (a)+(b) HAPPY DRAIN + SCORECARD SHAPE ───────────────────────────────────────
ST="$T/happy"
bash "$DRAIN" --state "$ST" -n 4 >"$T/happy.out" 2>&1 \
  || fail "(a) happy-path drain exited non-zero"$'\n'"$(cat "$T/happy.out")"

SC="$ST/scorecard.json"
[ -f "$SC" ] || fail "(b) scorecard.json not emitted at $SC"
python3 - "$SC" <<'PY' || fail "(b) happy scorecard failed machine-readable assertions"
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("scenario","artifacts_dir","repo_dir","backlog_size","items_drained","drained_this_run",
          "remaining","resumed_after_kill","duplicates","gate_failures","wall_clock_s",
          "result","passed","failed","skipped","checkpoints"):
    assert k in d, "missing field: %s" % k
assert d["result"] == "pass", "result != pass: %r" % d["result"]
assert d["backlog_size"] == 4, "backlog_size != 4: %r" % d["backlog_size"]
assert d["items_drained"] == 4, "items_drained != 4: %r" % d["items_drained"]
assert d["remaining"] == 0, "remaining != 0: %r" % d["remaining"]
assert d["duplicates"] == 0, "duplicates != 0: %r" % d["duplicates"]
assert d["gate_failures"] == 0, "gate_failures != 0: %r" % d["gate_failures"]
assert d["resumed_after_kill"] is False, "resumed_after_kill should be false: %r" % d["resumed_after_kill"]
assert isinstance(d["checkpoints"], list) and d["checkpoints"], "no checkpoints"
print("happy scorecard OK: %d drained" % d["items_drained"])
PY

# Every item's stub change is on main; the builder branches/worktrees are torn down; tree is clean.
for tok in 01 02 03 04; do
  git -C "$ST/repo" cat-file -e "main:app/item-$tok.sh" 2>/dev/null \
    || fail "(a) app/item-$tok.sh not on main after drain"
done
[ -z "$(git -C "$ST/repo" branch --list 'bench/*')" ] || fail "(a) builder branches not torn down"
[ -z "$(git -C "$ST/repo" status --porcelain)" ]      || fail "(a) main tree not clean after drain"
grep -cE '^- ✅ \*\*Item' "$ST/repo/BACKLOG.md" | grep -qx 4 || fail "(a) not all 4 backlog items marked ✅"
echo "PASS (a)+(b) happy drain + scorecard shape"

# ── (c) RESTART SURVIVAL — kill mid-drain, resume from durable state, 0 duplicates ──────────────
KR="$T/killresume"
rc=0
bash "$DRAIN" --state "$KR" -n 4 --kill-at 2 >"$T/kill.out" 2>&1 || rc=$?
[ "$rc" -eq 137 ] || fail "(c) --kill-at 2 should hard-exit 137, got $rc"$'\n'"$(cat "$T/kill.out")"

# Durable state after the crash: exactly 2 shipped, 2 pending — and NO scorecard (a crash writes none).
[ "$(grep -cE '^- ✅ \*\*Item' "$KR/repo/BACKLOG.md")" -eq 2 ] || fail "(c) expected 2 ✅ items after kill"
[ "$(grep -cE '^- 🔜 \*\*Item' "$KR/repo/BACKLOG.md")" -eq 2 ] || fail "(c) expected 2 🔜 items after kill"
[ ! -f "$KR/scorecard.json" ] || fail "(c) a hard-killed run should not have written a scorecard"

# Re-run against the SAME --state: resume from disk alone, complete all 4, 0 duplicates.
bash "$DRAIN" --state "$KR" -n 4 >"$T/resume.out" 2>&1 \
  || fail "(c) resume run exited non-zero"$'\n'"$(cat "$T/resume.out")"

SCR="$KR/scorecard.json"
[ -f "$SCR" ] || fail "(c) scorecard.json not emitted by the resume run"
python3 - "$SCR" <<'PY' || fail "(c) resume scorecard assertions failed"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["result"] == "pass", "result != pass: %r" % d["result"]
assert d["items_drained"] == 4, "items_drained != 4 after resume: %r" % d["items_drained"]
assert d["drained_this_run"] == 2, "drained_this_run != 2 on resume: %r" % d["drained_this_run"]
assert d["remaining"] == 0, "remaining != 0 after resume: %r" % d["remaining"]
assert d["duplicates"] == 0, "duplicates must be 0: %r" % d["duplicates"]
assert d["resumed_after_kill"] is True, "resumed_after_kill should be true: %r" % d["resumed_after_kill"]
print("resume scorecard OK: 4 drained, 0 duplicates, resumed_after_kill=true")
PY

# All four items present on main exactly once (no re-ship duplicated a change).
for tok in 01 02 03 04; do
  n="$(git -C "$KR/repo" log --oneline --all -- "app/item-$tok.sh" | grep -c 'stub-builder')"
  [ "$n" -eq 1 ] || fail "(c) item $tok stub commit appears $n times (expected 1 — duplicate ship)"
done
[ "$(grep -cE '^- ✅ \*\*Item' "$KR/repo/BACKLOG.md")" -eq 4 ] || fail "(c) not all 4 items ✅ after resume"
echo "PASS (c) restart survival — killed after 2, resumed to 4, 0 duplicates"

echo "ALL PASS"
