#!/usr/bin/env bash
# test-sandbox-sim.sh — hermetic proof of the P0 sandbox-consumer simulation rig.
#
# Asserts:
#   (a) DETERMINISM — sandbox-fixture.sh builds a byte-identical repo every run: two independent
#       builds share the same HEAD sha AND the same tracked-tree manifest (git ls-files -s). The
#       seeded app + BACKLOG.md are present.
#   (b) END-TO-END STUB SCENARIO — sandbox-scenario.sh walks init→build→PR→gate→merge→teardown
#       against the local fixture with a STUB builder (no model call), exits 0, and every checkpoint
#       passes. The stub change (app/farewell.sh) lands on main; the builder branch is torn down.
#   (c) SCORECARD — a machine-readable scorecard.json is emitted with the expected shape/fields, and
#       reports result=pass with failed=0.
#   (d) FAULT PATH — with SANDBOX_FORCE_GATE_FAIL=1 the gate fails LOUDLY, the runner exits non-zero,
#       records gate_passed=fail + merged=skip + change_isolated=pass, and the broken change is NOT
#       on main (proves a failing gate never silently merges).
#
# Fully hermetic: local git only, NO herdr, NO network, NO model. Mirrors the throwaway-git
# conventions of tests/test-externalize-task-specs.sh and scripts/herd/sim/cross-repo-loop-sim.sh.
# Run:  bash tests/test-sandbox-sim.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$HERE/../scripts/herd/sim/sandbox-fixture.sh"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-scenario.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$FIXTURE" ]  || fail "missing $FIXTURE"
[ -f "$SCENARIO" ] || fail "missing $SCENARIO"

# ── (a) DETERMINISM ─────────────────────────────────────────────────────────────
sha1="$(bash "$FIXTURE" "$T/fx1" | awk '/^HEAD:/{print $2}')"
sha2="$(bash "$FIXTURE" "$T/fx2" | awk '/^HEAD:/{print $2}')"
[ -n "$sha1" ] || fail "(a) fixture 1 emitted no HEAD sha"
[ "$sha1" = "$sha2" ] || fail "(a) fixture is NON-deterministic: $sha1 != $sha2"

# Tree manifest (mode+objectsha+path) must match byte-for-byte across the two builds.
man1="$(git -C "$T/fx1" ls-files -s)"
man2="$(git -C "$T/fx2" ls-files -s)"
[ "$man1" = "$man2" ] || fail "(a) tracked-tree manifest differs between builds"

# Seeded content is present and shaped as expected.
[ -f "$T/fx1/app/greet.sh" ]      || fail "(a) app/greet.sh missing from fixture"
[ -f "$T/fx1/app/greet.test.sh" ] || fail "(a) app/greet.test.sh missing from fixture"
[ -f "$T/fx1/BACKLOG.md" ]        || fail "(a) BACKLOG.md missing from fixture"
grep -q '🔜' "$T/fx1/BACKLOG.md"  || fail "(a) seeded BACKLOG.md lacks a 🔜 item"
# Rebuilding over an existing fixture is idempotent (same sha again).
sha1b="$(bash "$FIXTURE" "$T/fx1" | awk '/^HEAD:/{print $2}')"
[ "$sha1b" = "$sha1" ] || fail "(a) rebuild is not idempotent: $sha1b != $sha1"
echo "PASS (a) deterministic fixture — HEAD $sha1"

# ── (b)+(c) END-TO-END HAPPY PATH + SCORECARD ───────────────────────────────────
ART="$T/run-happy"
bash "$SCENARIO" --artifacts "$ART" >"$T/happy.out" 2>&1 \
  || fail "(b) happy-path scenario exited non-zero"$'\n'"$(cat "$T/happy.out")"

SC="$ART/scorecard.json"
[ -f "$SC" ] || fail "(c) scorecard.json not emitted at $SC"

# Machine-readable: parse with python and assert shape + a clean result.
python3 - "$SC" <<'PY' || fail "(c) scorecard.json failed machine-readable assertions"
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("scenario","artifacts_dir","repo_dir","fixture_sha","result","passed","failed","skipped","checkpoints"):
    assert k in d, "missing field: %s" % k
assert d["result"] == "pass", "result != pass: %r" % d["result"]
assert d["failed"] == 0, "failed != 0: %r" % d["failed"]
assert isinstance(d["checkpoints"], list) and d["checkpoints"], "no checkpoints"
names = {c["name"]: c["status"] for c in d["checkpoints"]}
for req in ("fixture_built","builder_committed","pr_opened","gate_passed","merged","torn_down"):
    assert names.get(req) == "pass", "checkpoint %s not pass: %r" % (req, names.get(req))
# HERD-139 notify hermeticity: the main-health forced-red leg must surface its MAIN RED + recovery
# notifications ONLY to the durable sink (never the desktop), and the whole run must leak zero native
# desktop notifications.
assert names.get("main_health_notify_sink") == "pass", "main_health_notify_sink not pass: %r" % names.get("main_health_notify_sink")
assert names.get("notify_hermetic") == "pass", "notify_hermetic not pass: %r" % names.get("notify_hermetic")
print("scorecard OK: %d passed / %d failed" % (d["passed"], d["failed"]))
PY

# HERD-139: prove notify hermeticity from the OUTSIDE too — the run's captured-attempts log must
# record ZERO native desktop-notification attempts (osascript / notify-send). The durable sink DID
# capture the MAIN RED alarm (turned the leak into signal), but nothing reached a real desktop channel.
CAP="$ART/notify-captured.log"
if [ -f "$CAP" ] && grep -Eq '^(osascript|notify-send)\b' "$CAP"; then
  fail "(c) native desktop notification LEAKED during the sim run:"$'\n'"$(cat "$CAP")"
fi
grep -q 'MAIN RED' "$ART/tr-cd/.herd/notifications.log" 2>/dev/null \
  || fail "(c) the forced-red leg did not record a MAIN RED line in the durable notify sink"
echo "PASS (c') notify hermeticity — MAIN RED captured to the sink, zero native desktop leaks"

# The stub change landed on main and the builder branch was torn down.
git -C "$ART/repo" cat-file -e main:app/farewell.sh 2>/dev/null \
  || fail "(b) app/farewell.sh not present on main after merge"
git -C "$ART/repo" show-ref --verify --quiet refs/heads/sim/stub-builder \
  && fail "(b) builder branch not torn down"
echo "PASS (b)+(c) end-to-end stub scenario + scorecard"

# ── (d) FAULT PATH — gate fails LOUDLY, merge skipped, change isolated ───────────
ARTF="$T/run-fault"
rc=0
SANDBOX_FORCE_GATE_FAIL=1 bash "$SCENARIO" --artifacts "$ARTF" >"$T/fault.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "(d) fault scenario exited 0 despite a failing gate"$'\n'"$(cat "$T/fault.out")"

SCF="$ARTF/scorecard.json"
[ -f "$SCF" ] || fail "(d) scorecard.json not emitted on the fault path"
python3 - "$SCF" <<'PY' || fail "(d) fault scorecard assertions failed"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["result"] == "fail", "result != fail: %r" % d["result"]
assert d["failed"] >= 1, "expected >=1 failed checkpoint"
names = {c["name"]: c["status"] for c in d["checkpoints"]}
assert names.get("gate_passed") == "fail", "gate_passed should be fail: %r" % names.get("gate_passed")
assert names.get("merged") == "skip", "merged should be skip: %r" % names.get("merged")
assert names.get("change_isolated") == "pass", "change_isolated should be pass: %r" % names.get("change_isolated")
print("fault scorecard OK")
PY

# The broken change must NOT be on main (a failing gate never merges).
git -C "$ARTF/repo" cat-file -e main:app/farewell.sh 2>/dev/null \
  && fail "(d) broken change leaked onto main"
# main's greet.sh must still be the ORIGINAL (unbroken) output.
grep -q 'hello, %s!' "$ARTF/repo/app/greet.sh" \
  || fail "(d) main's greet.sh was clobbered by the broken builder change"
echo "PASS (d) fault path — gate failed loudly, merge skipped, change isolated"

echo "ALL PASS"
