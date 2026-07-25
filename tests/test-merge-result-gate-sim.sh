#!/usr/bin/env bash
# tests/test-merge-result-gate-sim.sh — hermetic sim for HERD-296 (MERGE_RESULT_GATE, §6.4).
#
# The claim (docs/spikes/merge-result-gate.md §0/§2, docs/engine-contract.md §6.4): PR A and PR B can
# each test green on their own stale base, merge textually clean, and interact only through behavior —
# every existing gate passes and the default branch breaks. This sim builds EXACTLY that fixture with
# real git (no network, no gh, no model, no herdr) and drives the REAL
# ``pysrc/herd/live_runtime.LiveGates.health`` seam — real subprocess dispatch, real merge
# materialization, real (stubbed-project) healthcheck.sh run — proving:
#
#   • gate_off_permits_old_outcome — PR B's OWN worktree (unrebased, individually green) still reads
#     CLEAN under MERGE_RESULT_GATE off — today's gap, preserved byte-identically when the lever is off.
#   • gate_on_blocks_before_merge  — the SAME candidate, gate ON, is CODEERROR: the materialized
#     (head + current base) tree is gated BEFORE merge, catching the interaction the branch-as-is
#     suite cannot see.
#   • cleanup                     — after the gate-on suite resolves, the throwaway merge worktree is
#     gone from disk AND from `git worktree list` — no leaked merge commit, no temporary state.
#   • base_move_rearms            — a FURTHER base move re-arms the gate for the same head sha (a new
#     base sha is a cache miss, never a stale reuse of the old verdict).
#   • conflict_holds_not_blocked  — a candidate whose materialized merge hits a REAL conflict reports
#     the ``CONFLICT`` sentinel, not a cached verdict and not a rail BLOCK (resolver-owned).
#
# The fixture: a base commit with lib.py::contract() == 1. PR A (merged into main first) redefines
# contract() to return 2. PR B — branched off the SAME base, never touching lib.py — adds consumer.py,
# which asserts contract() == 1. Textually disjoint files; individually green against their own base;
# semantically incompatible once both are present.
#
# Fully hermetic: a local git repo under $T only, a stub project healthcheck (no model, no network).
# Writes a machine-readable scorecard to $ART/scorecard.json (read back and asserted below).
#
# Run: bash tests/test-merge-result-gate-sim.sh [--artifacts DIR] [--keep]
# Exit: 0 = every checkpoint passed · 1 = at least one failed.
set -uo pipefail

c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$REPO/pysrc/herd/live_runtime.py" ] || { echo "FAIL: pysrc/herd/live_runtime.py not found" >&2; exit 1; }

ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "test-merge-result-gate-sim: unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
[ -n "$KEEP" ] || trap 'rm -rf "$ART"' EXIT

step 1 "building the fixture + driving LiveGates.health() through the real seam"
PYTHONPATH="$REPO/pysrc" HERDKIT_REPO="$REPO" SIMDIR="$ART" python3 - <<'PY'
import json, os, subprocess, sys, time

REPO = os.environ["HERDKIT_REPO"]
T = os.environ["SIMDIR"]

# HERMETICITY (mirrors tests/test_live_runtime.py's module-level scrub): a healthcheck-descended
# environment EXPORTS herdkit's OWN live-engine main-health coordinates — MAIN_HEALTH_TICK=on,
# PROJECT_ROOT/MAIN pointing at the real herdkit checkout (herd-config.sh:678, HERD-359). Left in
# place, _main_health_pending() would consult THIS sim's own throwaway MAIN dir (set below) with no
# markers yet and reserve the single HEALTH_CONCURRENCY slot for a "main-health" verdict that never
# arrives — collapsing the effective slot count to 0 and wedging poll_health() in WAIT forever (the
# 2026-07-25 PR #541 CODEERROR: this sim timed out under the real heavy suite, which sources the
# project's own .herd/config, but passed standalone where no such env is exported). Scrub the trio
# before touching MAIN ourselves so the sim's health dispatch is never held hostage by the outer
# project's own main-health reservation.
for _k in ("MAIN_HEALTH_TICK", "MAIN", "PROJECT_ROOT"):
    os.environ.pop(_k, None)

from herd.live_runtime import LiveGates, LiveState, LiveJournal, LiveCandidate, WAIT

scorecard = {}


def record(name, ok_, detail=""):
    scorecard[name] = {"result": "pass" if ok_ else "fail", "detail": detail}
    print(("PASS " if ok_ else "FAIL ") + name + (": " + detail if detail else ""))


def sh(args, cwd=None, check=True):
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError("cmd failed: %r\nSTDOUT:%s\nSTDERR:%s" % (args, r.stdout, r.stderr))
    return r


def git(repo, *args, check=True):
    return sh(["git", "-C", repo] + list(args), check=check)


def rev_parse(repo, ref):
    return git(repo, "rev-parse", ref).stdout.strip()


def write(repo, relpath, content):
    full = os.path.join(repo, relpath)
    os.makedirs(os.path.dirname(full) or repo, exist_ok=True)
    with open(full, "w", encoding="utf-8") as fh:
        fh.write(content)


def poll_health(gates, cand, timeout=20.0):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = gates.health(cand)
        if last != WAIT:
            return last
        time.sleep(0.05)
    raise RuntimeError("health() did not resolve within %ss (last=%r)" % (timeout, last))


# ── the fixture repo: base -> PR A (merged first) + PR B (textually disjoint, stale) ───────────────
origin = os.path.join(T, "origin")
os.makedirs(origin)
git(origin, "init", "-q", "-b", "main")
git(origin, "config", "user.email", "sim@example.com")
git(origin, "config", "user.name", "sim")

write(origin, "lib.py", "def contract():\n    return 1\n")
git(origin, "add", "-A")
git(origin, "commit", "-q", "-m", "base: lib.contract() == 1")
base0 = rev_parse(origin, "HEAD")

git(origin, "checkout", "-q", "-b", "pr-a")
write(origin, "lib.py", "def contract():\n    return 2\n")
git(origin, "commit", "-q", "-am", "PR A: contract() now returns 2")

git(origin, "checkout", "-q", base0)
git(origin, "checkout", "-q", "-b", "pr-b")
write(origin, "consumer.py",
      "from lib import contract\n"
      "def use():\n"
      "    if contract() != 1:\n"
      "        print('not ok 1 - consumer expected the OLD contract() == 1')\n"
      "        raise SystemExit(1)\n"
      "    print('ok 1 - consumer sees the expected contract')\n")
git(origin, "add", "-A")
git(origin, "commit", "-q", "-m", "PR B: consume the contract, expecting the old value")
pr_b_sha = rev_parse(origin, "HEAD")

# Merge PR A into main FIRST — the base moves out from under PR B (today's ordinary race).
git(origin, "checkout", "-q", "main")
git(origin, "merge", "-q", "--no-edit", "pr-a")

# PR C: a THIRD candidate that edits the SAME line of lib.py as PR A — a genuine merge conflict
# against the current base, proving the resolver-owned conflict path (never a cached verdict).
git(origin, "checkout", "-q", base0)
git(origin, "checkout", "-q", "-b", "pr-c")
write(origin, "lib.py", "def contract():\n    return 3\n")
git(origin, "commit", "-q", "-am", "PR C: contract() now returns 3 (conflicts with PR A's edit)")
pr_c_sha = rev_parse(origin, "HEAD")

# PR B's own worktree — checked out at its OWN head, never rebased onto the new main tip.
pr_b_wt = os.path.join(T, "wt-pr-b")
git(origin, "worktree", "add", "-q", "--detach", pr_b_wt, pr_b_sha)
pr_c_wt = os.path.join(T, "wt-pr-c")
git(origin, "worktree", "add", "-q", "--detach", pr_c_wt, pr_c_sha)

# A live checkout of the CURRENT default branch — plays $MAIN for the gate.
main_wt = os.path.join(T, "wt-main")
git(origin, "worktree", "add", "-q", "--detach", main_wt, "main")

# The stub project health command: import consumer.py if present on the gated tree and run its
# check; absent -> nothing to check (so the SAME command also cleanly gates PR A or main alone).
check_py = os.path.join(T, "check.py")
with open(check_py, "w", encoding="utf-8") as fh:
    fh.write(
        "import sys\n"
        "sys.path.insert(0, sys.argv[1])\n"
        "try:\n"
        "    import consumer\n"
        "except ImportError:\n"
        "    print('ok 1 - no consumer.py on this tree')\n"
        "    raise SystemExit(0)\n"
        "consumer.use()\n"
    )
hc_sh = os.path.join(T, "hc.sh")
with open(hc_sh, "w", encoding="utf-8") as fh:
    fh.write("#!/usr/bin/env bash\nset -e\nexec python3 \"%s\" \"$1\"\n" % check_py)
os.chmod(hc_sh, 0o755)

herdconfig = os.path.join(T, "herdconfig")
with open(herdconfig, "w", encoding="utf-8") as fh:
    fh.write('HEALTHCHECK_CMD="%s"\n' % hc_sh)

os.environ["HERD_CONFIG_FILE"] = herdconfig
os.environ["MAIN"] = main_wt

# ── checkpoint 1: gate OFF permits today's outcome (PR B green on its own stale base) ───────────────
os.makedirs(os.path.join(T, "state-off"))
state_off = LiveState(state_dir=os.path.join(T, "state-off"))
journal_off = LiveJournal(os.path.join(T, "off.jsonl"))
gates_off = LiveGates(REPO, state_off, journal_off, config={})
cand_off = LiveCandidate(pr=101, sha=pr_b_sha, slug="pr-b", worktree=pr_b_wt)
verdict_off = poll_health(gates_off, cand_off)
record("gate_off_permits_old_outcome", verdict_off == "CLEAN",
       "verdict=%s (expected CLEAN — branch-as-is, unaware main already moved)" % verdict_off)
no_footprint = not any(n.startswith(".merge-result-") for n in os.listdir(state_off.dir))
record("gate_off_leaves_no_footprint", no_footprint,
       "MERGE_RESULT_GATE off must never write a .merge-result-* file")

# ── checkpoint 2: gate ON blocks the SAME candidate before merge ───────────────────────────────────
os.makedirs(os.path.join(T, "state-on"))
state_on = LiveState(state_dir=os.path.join(T, "state-on"))
journal_on = LiveJournal(os.path.join(T, "on.jsonl"))
gates_on = LiveGates(REPO, state_on, journal_on, config={"MERGE_RESULT_GATE": "on"})
cand_on = LiveCandidate(pr=102, sha=pr_b_sha, slug="pr-b", worktree=pr_b_wt)
verdict_on = poll_health(gates_on, cand_on)
record("gate_on_blocks_before_merge", verdict_on == "CODEERROR",
       "verdict=%s (expected CODEERROR — merged tree exposes the interaction)" % verdict_on)

tree_on = state_on.merge_result_tree_path(cand_on.pr, cand_on.sha)
worktree_list = git(origin, "worktree", "list").stdout
record("cleanup_no_leftover_tree",
       (not os.path.exists(tree_on)) and (tree_on not in worktree_list),
       "tree_path=%s exists=%s listed=%s" % (tree_on, os.path.exists(tree_on), tree_on in worktree_list))

events_on = [json.loads(l) for l in open(os.path.join(T, "on.jsonl"), encoding="utf-8") if l.strip()]
gate_events = [e for e in events_on if e.get("event") == "merge_result_gate"]
record("merge_result_gate_journaled_with_base",
       len(gate_events) == 1 and gate_events[0].get("verdict") == "CODEERROR" and gate_events[0].get("base"),
       "events=%r" % gate_events)
first_base = gate_events[0]["base"] if gate_events else None

# ── checkpoint 3: a FURTHER base move re-arms the gate for the SAME head sha ────────────────────────
write(origin, "README.md", "advance the base once more\n")
git(origin, "checkout", "-q", "main")
git(origin, "add", "-A")
git(origin, "commit", "-q", "-m", "advance main once more")
new_tip = rev_parse(origin, "main")
git(main_wt, "checkout", "-q", new_tip)

verdict_on2 = poll_health(gates_on, cand_on)
events_on2 = [json.loads(l) for l in open(os.path.join(T, "on.jsonl"), encoding="utf-8") if l.strip()]
gate_events2 = [e for e in events_on2 if e.get("event") == "merge_result_gate"]
second_base = gate_events2[-1]["base"] if len(gate_events2) >= 2 else None
record("base_move_rearms_gate",
       verdict_on2 == "CODEERROR" and len(gate_events2) == 2 and second_base and second_base != first_base,
       "verdict=%s bases=%s" % (verdict_on2, [e.get("base") for e in gate_events2]))

# ── checkpoint 4: a REAL conflict reports CONFLICT, never a cached verdict / rail BLOCK ─────────────
os.makedirs(os.path.join(T, "state-conflict"))
state_conflict = LiveState(state_dir=os.path.join(T, "state-conflict"))
journal_conflict = LiveJournal(os.path.join(T, "conflict.jsonl"))
gates_conflict = LiveGates(REPO, state_conflict, journal_conflict, config={"MERGE_RESULT_GATE": "on"})
cand_conflict = LiveCandidate(pr=103, sha=pr_c_sha, slug="pr-c", worktree=pr_c_wt)
verdict_conflict = gates_conflict.health(cand_conflict)   # synchronous: materialize fails before dispatch
record("conflict_holds_not_blocked", verdict_conflict == "CONFLICT",
       "verdict=%s (expected CONFLICT — resolver-owned, never a cached verdict)" % verdict_conflict)
record("conflict_never_cached",
       state_conflict.merge_result_verdict(cand_conflict.pr, cand_conflict.sha, os.environ.get("_UNUSED", "")) is None,
       "a CONFLICT must never be readable back as a terminal verdict")

with open(os.path.join(T, "scorecard.json"), "w", encoding="utf-8") as fh:
    json.dump(scorecard, fh, indent=2, sort_keys=True)

sys.exit(0 if all(v["result"] == "pass" for v in scorecard.values()) else 1)
PY
py_rc=$?

step 2 "scorecard (read back from $ART/scorecard.json)"
FAIL=0
if [ -f "$ART/scorecard.json" ]; then
  while IFS=$'\t' read -r name result; do
    if [ "$result" = "pass" ]; then ok "$name"; else bad "$name"; FAIL=$((FAIL + 1)); fi
  done < <(python3 -c "
import json
d = json.load(open('$ART/scorecard.json'))
for k in sorted(d):
    print(k + '\t' + d[k]['result'])
")
else
  bad "no scorecard.json produced — driver errored before writing it"
  FAIL=1
fi

if [ "$FAIL" -eq 0 ] && [ "$py_rc" -eq 0 ]; then
  echo
  echo "ALL PASS — MERGE_RESULT_GATE hermetic sim (HERD-296)"
  exit 0
fi
echo
echo "FAIL — see $ART/scorecard.json"
exit 1
