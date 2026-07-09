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
# S1/S2: a clean happy run must have ZERO skipped checkpoints — a skip here would mean a whole phase
# silently didn't run (a missing lib), which now degrades the result to "pass-with-skips". Pinning
# skipped==0 AND every phase checkpoint below is what turns a silent-skip into a LOUD wrapper failure.
assert d["skipped"] == 0, "happy run must skip nothing (a skipped phase = coverage gap): %r" % d["skipped"]
assert isinstance(d["checkpoints"], list) and d["checkpoints"], "no checkpoints"
names = {c["name"]: c["status"] for c in d["checkpoints"]}
# Pin EVERY phase-level checkpoint the happy path emits (push_gate_* and pipeline_steps_* included), so
# a phase that stops emitting its checkpoint — e.g. a *_lib skip because a lib went missing — is caught
# here as a MISSING pinned name rather than sliding through as a still-green scorecard.
EXPECTED = (
  "fixture_built", "fixture_clean",
  "builder_committed",
  "pr_opened",
  "gate_passed",
  "merged",
  "torn_down", "final_clean",
  "main_health_dormant", "main_health_green", "main_health_red", "main_health_recovery",
  "main_health_notify_sink", "main_health_nonheavy_red",
  "cross_seat_block_held", "cross_seat_block_no_bless", "cross_seat_block_resolved",
  "push_gate_held_no_push", "push_gate_listed", "push_gate_resumed", "push_gate_stale_refused",
  "pipeline_steps_held", "pipeline_steps_listed", "pipeline_steps_released", "pipeline_steps_order",
  "pipeline_steps_block", "pipeline_steps_off", "pipeline_steps_merge_resume", "pipeline_steps_two_approve",
  "notify_hermetic",
)
for req in EXPECTED:
    assert names.get(req) == "pass", "phase checkpoint %s not pass (missing/skipped?): %r" % (req, names.get(req))
# And nothing UNEXPECTED slipped in (keeps the pin exhaustive — a new phase must be added here too).
extra = sorted(set(names) - set(EXPECTED))
assert not extra, "unpinned checkpoint(s) appeared — add them to EXPECTED: %r" % extra
print("scorecard OK: %d passed / %d failed / %d checkpoints all pinned" % (d["passed"], d["failed"], len(names)))
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
# FAULT-INJECTION SELF-CHECK (convention, model: test-sandbox-governance.sh:87-89): forcing ONE fault
# must flip EXACTLY one checkpoint — no more (a broad flip would mean the force flag has side effects)
# and no fewer. The flipped one must be gate_passed specifically.
assert d["failed"] == 1, "forced fault must flip EXACTLY 1 checkpoint: %r" % d["failed"]
names = {c["name"]: c["status"] for c in d["checkpoints"]}
flipped = [c["name"] for c in d["checkpoints"] if c["status"] == "fail"]
assert flipped == ["gate_passed"], "the single flipped checkpoint must be gate_passed: %r" % flipped
# The gate-failed branch SKIPS the merge (designed, optional skip → still recorded status "skip") and
# proves the broken change stayed isolated off main.
assert names.get("merged") == "skip", "merged should be skip: %r" % names.get("merged")
assert names.get("change_isolated") == "pass", "change_isolated should be pass: %r" % names.get("change_isolated")
print("fault scorecard OK — exactly 1 flip (gate_passed), merge skipped, change isolated")
PY

# The broken change must NOT be on main (a failing gate never merges).
git -C "$ARTF/repo" cat-file -e main:app/farewell.sh 2>/dev/null \
  && fail "(d) broken change leaked onto main"
# main's greet.sh must still be the ORIGINAL (unbroken) output.
grep -q 'hello, %s!' "$ARTF/repo/app/greet.sh" \
  || fail "(d) main's greet.sh was clobbered by the broken builder change"
echo "PASS (d) fault path — gate failed loudly, merge skipped, change isolated"

echo "ALL PASS"
