#!/usr/bin/env bash
# tests/test-merge-queue-sim.sh — hermetic multi-seat/high-cadence sim for HERD-273 (MERGE_QUEUE, §6.3).
#
# The claim (docs/engine-contract.md §6.3, docs/spikes/merge-result-gate.md §3): with the ordered
# integration queue on, at most one blessed candidate applies a merge per window — the deterministic
# front (ascending PR number) — so two siblings never land out of order and a red/conflicting front
# can never be lapped by a later candidate. This sim builds SIX candidate PRs against one real git
# repo (no network, no gh, no model, no herdr) and drives the REAL
# ``pysrc/herd/live_runtime.LiveTick`` pipeline — real subprocess health dispatch, real merge-result
# materialization, real (stubbed-project) healthcheck.sh runs, real merges into the shared origin's
# default branch — proving, via a machine-readable scorecard:
#
#   • bounded_train_slots       — PR 1 then PR 2 (both textually disjoint) land in strict PR-number
#                                  order, one per window, with NO merge_queue_hold noise once each is
#                                  actually front (bounded: nobody waits longer than its own turn).
#   • no_lapping_in_journal     — every merge event in the whole run, in wall-clock/journal order, is
#                                  STRICTLY ascending by PR number — the direct proof nothing lapped.
#   • conflict_head_blocks_later — PR 3 conflicts against the base ONLY after PR 2 lands ahead of it
#                                  (a REAL git conflict on the SAME line of lib.py) — proving the
#                                  per-slot verifier is checked against "main plus already-ordered
#                                  candidates", not a stale snapshot. While PR 3 sits CONFLICT-held as
#                                  queue front, PR 4/5/6 — individually green, textually disjoint —
#                                  are held too (`merge_queue_hold`, front_pr=3) and NEVER merge.
#   • no_starvation_threshold_crossed — the always-on re-stale counter never crosses
#                                  MERGE_FAIRNESS_STARVE_THRESHOLD while the queue is draining (no
#                                  pr_starvation event) — the queue's single-lane ordering does not
#                                  itself manufacture the re-stale thrashing MERGE_FAIRNESS exists to
#                                  observe.
#   • rearm_and_drain            — pushing a NEW sha for PR 3 (resolving the conflict) re-arms its
#                                  queue slot; PR 3 then PR 4 then PR 5 then PR 6 drain in order — every
#                                  candidate lands in a bounded number of ticks, each EXACTLY once.
#   • cleanup                    — no leftover ``.merge-result-tree-*`` dir and no stray worktree
#                                  remains once every candidate has resolved.
#
# Fully hermetic: a local git repo under $T only, a stub project healthcheck (no model, no network),
# a hand-rolled sim actuator that merges via plain `git` (never `gh`) and a stubbed-PASS review rail
# (review is untouched by this feature; only the health/merge-result rail and the queue's apply-gate
# are under test here).
#
# Run: bash tests/test-merge-queue-sim.sh [--artifacts DIR] [--keep]
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
    *) echo "test-merge-queue-sim: unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
[ -n "$KEEP" ] || trap 'rm -rf "$ART"' EXIT

step 1 "building the 6-PR fixture + driving LiveTick through the real seam"
PYTHONPATH="$REPO/pysrc" HERDKIT_REPO="$REPO" SIMDIR="$ART" python3 - <<'PY'
import json, os, subprocess, sys, time

REPO = os.environ["HERDKIT_REPO"]
T = os.environ["SIMDIR"]

# HERMETICITY (mirrors tests/test-merge-result-gate-sim.sh / tests/test_live_runtime.py's scrub): a
# healthcheck-descended environment exports herdkit's OWN live-engine main-health coordinates —
# MAIN_HEALTH_TICK=on, PROJECT_ROOT/MAIN pointing at the real herdkit checkout — which would collapse
# the single HEALTH_CONCURRENCY slot to the outer project's own main-health reservation. Scrub before
# pointing MAIN at this sim's own throwaway origin.
for _k in ("MAIN_HEALTH_TICK", "MAIN", "PROJECT_ROOT"):
    os.environ.pop(_k, None)

from herd.live_runtime import (LiveTick, LiveGates, LiveState, LiveJournal, LiveCandidate,
                               WakeResult, FixtureDiscovery)

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


# ── the fixture repo: base -> 6 PR branches ─────────────────────────────────────────────────────────
origin = os.path.join(T, "origin")
os.makedirs(origin)
git(origin, "init", "-q", "-b", "main")
git(origin, "config", "user.email", "sim@example.com")
git(origin, "config", "user.name", "sim")

write(origin, "lib.py", "def value():\n    return 1\n")
git(origin, "add", "-A")
git(origin, "commit", "-q", "-m", "base")
base0 = rev_parse(origin, "HEAD")

worktrees = {}
shas = {}


def make_pr(n, edit_lib_to=None, own_file=True):
    branch = "pr-%d" % n
    git(origin, "checkout", "-q", base0)
    git(origin, "checkout", "-q", "-b", branch)
    if edit_lib_to is not None:
        write(origin, "lib.py", "def value():\n    return %d\n" % edit_lib_to)
    if own_file:
        write(origin, "file%d.py" % n, "MARK = %d\n" % n)
    git(origin, "add", "-A")
    git(origin, "commit", "-q", "-m", "PR %d" % n)
    sha = rev_parse(origin, branch)
    wt = os.path.join(T, "wt-pr-%d" % n)
    git(origin, "worktree", "add", "-q", "--detach", wt, sha)
    worktrees[n] = wt
    shas[n] = sha
    return sha


# PR 1, 4, 5, 6: textually disjoint (own file only), never touch lib.py -> always individually green.
make_pr(1)
# PR 2: edits lib.py (no conflict against base0 — it is the FIRST to touch that line).
make_pr(2, edit_lib_to=2)
# PR 3: ALSO edits lib.py, off the SAME base0 line PR 2 edits — textually fine against base0 alone,
# but conflicts once PR 2 has already landed ahead of it (exactly the "main plus already-ordered
# candidates" case the virtual tip must catch).
make_pr(3, edit_lib_to=3)
make_pr(4)
make_pr(5)
make_pr(6)

git(origin, "checkout", "-q", "main")
main_wt = os.path.join(T, "wt-main")
git(origin, "worktree", "add", "-q", "--detach", main_wt, "main")

# The stub project health command: always clean (this sim tests the MERGE/QUEUE machinery, not the
# baseline-aware suite semantics already proven by tests/test-merge-result-gate-sim.sh).
hc_sh = os.path.join(T, "hc.sh")
with open(hc_sh, "w", encoding="utf-8") as fh:
    fh.write("#!/usr/bin/env bash\nexit 0\n")
os.chmod(hc_sh, 0o755)
herdconfig = os.path.join(T, "herdconfig")
with open(herdconfig, "w", encoding="utf-8") as fh:
    fh.write('HEALTHCHECK_CMD="%s"\n' % hc_sh)
os.environ["HERD_CONFIG_FILE"] = herdconfig
os.environ["MAIN"] = main_wt


# ── a hermetic actuator: REAL git merges into origin/main, never `gh` ───────────────────────────────
class SimActuator:
    def __init__(self, journal):
        self.journal = journal

    def merge(self, cand):
        r = sh(["git", "-C", origin, "merge", "--no-ff", "-m", "merge PR %s" % cand.pr, cand.sha],
              check=False)
        if r.returncode != 0:
            sh(["git", "-C", origin, "merge", "--abort"], check=False)
            self.journal.append("merge_refused", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                                "state", "CONFLICTING", "reason", "api_not_merged")
            return False
        git(main_wt, "checkout", "-q", rev_parse(origin, "main"))
        self.journal.append("merge", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha,
                            "method", "merge", "reason", "gates_passed")
        return True

    def reap(self, cand):
        sh(["git", "-C", origin, "worktree", "remove", "--force", cand.worktree], check=False)
        self.journal.append("reap", "pr", cand.pr, "slug", cand.slug, "sha", cand.sha, "reason", "merged")
        return True

    def post_gate_status(self, cand):
        return False

    def wake_builder(self, cand, prompt):
        return WakeResult("working", "working", True)

    def peek_status(self, cand):
        return "working"

    def worktree_dirty(self, cand):
        return False


# ── health = the REAL merge-result-gate rail; review = stubbed PASS (untouched by this feature) ────
class HybridGates:
    def __init__(self, real):
        self._real = real
        self.reused_health = False
        self.reused_review = False

    def health(self, cand):
        v = self._real.health(cand)
        self.reused_health = self._real.reused_health
        return v

    def review(self, cand):
        self.reused_review = False
        return "PASS"


class ListDiscovery:
    def __init__(self, get_pending):
        self._get = get_pending

    def discover(self):
        return self._get()


state_dir = os.path.join(T, "state")
os.makedirs(state_dir)
journal_path = os.path.join(T, "run.jsonl")
journal = LiveJournal(journal_path)
state = LiveState(state_dir)
real_gates = LiveGates(REPO, state, journal, config={"MERGE_QUEUE": "on", "HEALTH_CONCURRENCY": "3"})
gates = HybridGates(real_gates)
actuator = SimActuator(journal)
config = {"MERGE_POLICY": "auto", "MERGE_QUEUE": "on", "HEALTH_CONCURRENCY": "3"}

merged_prs = []
open_prs = [1, 2, 3, 4, 5, 6]


def cand_for(n):
    return LiveCandidate(pr=n, sha=shas[n], slug="pr-%d" % n, worktree=worktrees[n])


def pending():
    return [cand_for(n) for n in open_prs]


def run_tick():
    tick = LiveTick(config, ListDiscovery(pending), gates, actuator, journal, state=state)
    res = tick.run()
    for pr, action in res["outcomes"].items():
        if action == "MERGE":
            merged_prs.append(int(pr))
            open_prs.remove(int(pr))
    return res


def events():
    if not os.path.exists(journal_path):
        return []
    with open(journal_path, encoding="utf-8") as fh:
        return [json.loads(l) for l in fh if l.strip()]


# drive <cond> until it is true or <timeout> real seconds elapse — a WALL-CLOCK deadline (mirrors
# tests/test-merge-result-gate-sim.sh's poll_health), never a blind tick count. The health/merge-result
# verdict is produced by a REAL detached subprocess (materializes a git tree, runs the stub health
# command); a bare back-to-back tick loop with no pacing can run all N ticks in well under the
# subprocess's own completion time on a fast box, seeing WAIT forever and never observing the result
# CI happens to have time to produce between ticks. Sleeping between ticks gives the worker real time
# to finish regardless of machine speed.
def drive(cond, timeout=30.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        run_tick()
        if cond():
            return True
        time.sleep(0.05)
    return False


# ── drive ticks until PR 1 and PR 2 have landed and PR 3 has hit its conflict ────────────────────────
def _pr1_pr2_landed_pr3_conflicted():
    conflict_evs = [e for e in events() if e.get("event") == "merge_result_conflict"
                    and str(e.get("pr")) == "3"]
    return 1 in merged_prs and 2 in merged_prs and bool(conflict_evs)


drive(_pr1_pr2_landed_pr3_conflicted, timeout=30.0)

record("bounded_train_slots", merged_prs[:2] == [1, 2],
       "first landings=%r (expected [1, 2], one per window, no lapping)" % (merged_prs[:2],))

merge_evs = [e for e in events() if e.get("event") == "merge"]
merge_order = [int(e["pr"]) for e in merge_evs]
record("no_lapping_in_journal", merge_order == sorted(merge_order),
       "journal merge order=%r (must already be ascending)" % (merge_order,))

# ── PR 3 must now be conflict-held, and PR 4/5/6 (individually green) must NOT be allowed past it ──
# A real-time settle window (not a fixed tick count — see drive() above) so PR 4/5/6's own async health
# dispatches have wall-clock time to resolve into a stable HOLD before we sample outcomes: keep ticking
# until a SINGLE tick's outcomes show all three HELD, or 20s pass (held_prs then reflects the last tick,
# and the record() below fails honestly on a genuine regression rather than a premature sample).
held_prs = set()
_settle_deadline = time.time() + 20.0
while time.time() < _settle_deadline:
    held_prs = {int(pr) for pr, a in run_tick()["outcomes"].items() if a == "HOLD"}
    if {4, 5, 6} <= held_prs:
        break
    time.sleep(0.05)
record("conflict_head_blocks_later",
       3 not in merged_prs and not ({4, 5, 6} & set(merged_prs)) and {4, 5, 6} <= held_prs,
       "merged=%r held=%r (PR 3 must still be open+conflict-held; 4/5/6 must be HELD, not merged)"
       % (sorted(merged_prs), sorted(held_prs)))

# merge_queue_hold is once-guarded per (pr,sha) (§5.3: notify once per state per version key) — a
# candidate that was already held under an EARLIER front (1, then 2) does not re-fire just because
# the front's identity later moved to 3. The un-guarded per-tick merge_queue_window event is the
# reliable witness that the front genuinely became — and stayed — pr 3 while 4/5/6 sat open.
front3_windows = [e for e in events() if e.get("event") == "merge_queue_window"
                 and str(e.get("front_pr")) == "3"]
record("queue_front_became_the_stuck_pr", len(front3_windows) >= 1,
       "merge_queue_window events naming front_pr=3: %d" % len(front3_windows))

starvation = [e for e in events() if e.get("event") == "pr_starvation"]
record("no_starvation_threshold_crossed", starvation == [],
       "pr_starvation events=%r (the queue's own single-lane ordering must never manufacture this)"
       % (starvation,))

# ── resolve PR 3's conflict with a NEW sha (a rebase-style fix onto the now-current lib.py) ─────────
git(origin, "worktree", "remove", "--force", worktrees[3])
git(origin, "branch", "-D", "pr-3")
# Recreate PR 3's branch off the CURRENT main tip (post PR-2), keeping its own file, dropping the
# conflicting lib.py edit — the honest "someone pushed a fix" re-arm, not a synthetic override.
git(origin, "checkout", "-q", rev_parse(origin, "main"))
git(origin, "checkout", "-q", "-b", "pr-3")
write(origin, "file3.py", "MARK = 3\n")
git(origin, "add", "-A")
git(origin, "commit", "-q", "-m", "PR 3 v2: rebased, drop the conflicting lib.py edit")
shas[3] = rev_parse(origin, "pr-3")
worktrees[3] = os.path.join(T, "wt-pr-3-v2")
git(origin, "worktree", "add", "-q", "--detach", worktrees[3], shas[3])

drive(lambda: not open_prs, timeout=40.0)

record("rearm_and_drain", open_prs == [] and sorted(merged_prs) == [1, 2, 3, 4, 5, 6],
       "open=%r merged=%r (every PR must land exactly once)" % (open_prs, sorted(merged_prs)))

merge_evs2 = [e for e in events() if e.get("event") == "merge"]
merge_order2 = [int(e["pr"]) for e in merge_evs2]
dup = len(merge_order2) != len(set(merge_order2))
record("no_lapping_full_run", (not dup) and merge_order2 == sorted(merge_order2),
       "full-run journal merge order=%r (ascending, no duplicate)" % (merge_order2,))

leftover_trees = [n for n in os.listdir(state_dir) if n.startswith(".merge-result-tree-")]
still_on_disk = [p for p in worktrees.values() if os.path.exists(p)]
record("cleanup", leftover_trees == [] and still_on_disk == [],
       "leftover merge-result trees=%r; pr worktrees still on disk=%r"
       % (leftover_trees, still_on_disk))

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
  echo "ALL PASS — MERGE_QUEUE hermetic multi-seat sim (HERD-273)"
  exit 0
fi
echo
echo "FAIL — see $ART/scorecard.json"
exit 1
