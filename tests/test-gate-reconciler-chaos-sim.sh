#!/usr/bin/env bash
# tests/test-gate-reconciler-chaos-sim.sh — HERD-425 chaos legs (HERD-240 Phase 3 P3.4 closure item,
# docs/audits/2026-07-09-gating-hardening.md P3.4).
#
# The claim: an UNTRAPPABLE hard watcher death (SIGKILL — no atexit, no finally, no cleanup) at any of
# THREE production boundaries never leaves the system in a dishonest or stuck state. A fresh
# watcher/tick over the SAME durable state (the only thing that survives a real crash) must converge
# to one honest terminal outcome, with no duplicated remote side effect (merge / wake) and no
# stranded in-flight marker or worker. The three boundaries, each a real call site inside the
# PRODUCTION Python engine (pysrc/herd/live_runtime.py — not the retired bash action pass):
#
#   LEG A  mid_do_merge        LiveActuator.merge — killed AFTER the real `gh pr merge` action lands,
#                               BEFORE the journal `merge` record + `reap()` run. Recovery is the
#                               CURRENT hybrid reconciler architecture's own answer: LiveActuator never
#                               touches the bash $STATE ledger or the tracker at all (capabilities.tsv:
#                               do_merge — including reconcile_backlog — "has zero production call
#                               sites (superseded live by LiveActuator.merge)"), so EVERY Python-
#                               actuated merge, crashed or clean, is discharged by the same shared
#                               reconciler bash still runs on a cadence regardless of engine:
#                               _sweep_merged_prs (agent-watch.sh) via _pms_reconcile_one. This leg
#                               proves the crashed-Python-merge shape converges through exactly that
#                               seam, tested here as a genuine SIGKILL rather than the existing
#                               scripts/herd/sim/postmerge-reconcile-sim.sh's bash `exit 9` wrapper
#                               around the now-dead bash do_merge.
#
#   LEG B  mid_gate_collect     LiveGates.health — killed AFTER a dispatched suite worker's terminal
#                               verdict is read from its durable out-file, BEFORE it is cached
#                               (record_health_result). The code's own "at-least-once" design
#                               (live_runtime.py comment: "a crash mid-collect re-reads the dispatch
#                               file next tick") is the recovery path under test.
#
#   LEG C  mid_refix_bounce     LiveTick._bounce_and_wake — killed AFTER the builder pane is actually
#                               woken, BEFORE the refix_bounce/refix_wake_result journal pair lands.
#                               The once-guard ledger row was already written by the CALLER
#                               (_refix_check_and_record) before _bounce_and_wake was even reached, so
#                               recovery is "hold silently, never wake a second time" — the SAME path
#                               a normal budget-spent tick already takes (live_runtime.py:_walk, health
#                               leg: `round_num is None and reason is None` -> BLOCK).
#
# Each leg's kill is a REAL os.kill(os.getpid(), SIGKILL) fired from inside the shipped production
# code at the exact seam (pysrc/herd/live_runtime.py:_chaos_kill), gated by HERD_CHAOS_KILL_AT +
# HERD_CHAOS_GUARD (an existing-file check) — ship-dormant, byte-identical-when-off, fail-closed
# against accidental use outside this harness (proven by tests/test_live_runtime.py's seam-guard unit
# coverage). Every "tick" below is a genuinely separate `python3` subprocess — this is not a
# simplification for the sim: pysrc/herd/live_runtime.py's own module docstring states production
# already runs this way ("Bash stays the resident supervisor; Python is the tick" — each `--tick`
# invocation is a fresh interpreter, engine-version.sh:herd_engine_live_tick), so "kill mid-tick,
# restart" here is exactly production's granularity, not an approximation of it.
#
# Hermetic: a real local git repo, PATH-stubbed `gh`/`herdr` (never the network), the REAL
# scripts/herd/agent-watch.sh sourced in lib mode ONLY for LEG A's existing, already-proven
# _sweep_merged_prs reconciler (postmerge-reconcile-sim.sh already exhaustively covers that
# reconciler's own convergence properties — this sim does not re-prove them, only that a REAL
# Python-actuated SIGKILL lands in the exact shape it already knows how to heal). Zero model calls,
# zero quota, zero real gh/herdr network calls.
#
# Run: bash tests/test-gate-reconciler-chaos-sim.sh [--artifacts DIR] [--keep] [--reps N]
#   --reps N   run every leg N times for flake resistance (default 1; HERD_CHAOS_SIM_REPS is the same
#              knob via env, e.g. for a heavier CI pass — see docs/audits/2026-07-09-gating-hardening.md
#              P3.4 for how this sim fits the reconciler-hardening roadmap it closes)
# Exit: 0 = every checkpoint (every rep, every leg) passed · 1 = at least one failed.
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
[ -f "$REPO/scripts/herd/agent-watch.sh" ] || { echo "FAIL: scripts/herd/agent-watch.sh not found" >&2; exit 1; }

ART=""; KEEP=""; REPS="${HERD_CHAOS_SIM_REPS:-1}"
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    --reps)      REPS="${2:-1}"; shift 2 ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "test-gate-reconciler-chaos-sim: unknown arg: $1" >&2; exit 1 ;;
  esac
done
case "$REPS" in ''|*[!0-9]*) REPS=1 ;; esac
[ "$REPS" -ge 1 ] || REPS=1
[ -n "$ART" ] || ART="$(mktemp -d)"
mkdir -p "$ART"
[ -n "$KEEP" ] || trap 'rm -rf "$ART"' EXIT

printf '%s══ gate-reconciler chaos sim (HERD-425) ══%s\n' "$c_bold" "$c_rst"
printf '  artifacts: %s · reps: %s\n' "$ART" "$REPS"

DRIVER="$ART/driver.py"
cat > "$DRIVER" <<'PYEOF'
#!/usr/bin/env python3
# gate-reconciler-chaos-driver.py — written to the sim's artifacts dir at runtime (not committed; the
# single-file convention every scripts/herd/sim/*.sh and tests/test-*-sim.sh already follows). Drives
# all three HERD-425 chaos legs for exactly ONE rep; the bash wrapper loops this for --reps N.
import json, os, signal, subprocess, sys, time

REPO = os.environ["HERDKIT_REPO"]
WATCH_SH = os.environ["WATCH_SH"]
T = os.environ["SIMDIR"]
os.makedirs(T, exist_ok=True)

# Hermeticity scrub (mirrors tests/test-merge-queue-sim.sh / tests/test-merge-result-gate-sim.sh): an
# ambient .herd/config in a healthcheck-descended environment exports this repo's OWN live-engine
# coordinates (MAIN_HEALTH_TICK, MAIN, PROJECT_ROOT), which would collapse the sim's single
# HEALTH_CONCURRENCY slot / point discovery at the wrong tree. Scrub before doing anything else.
for _k in ("MAIN_HEALTH_TICK", "MAIN", "PROJECT_ROOT", "HERD_CONFIG_FILE"):
    os.environ.pop(_k, None)

checkpoints = {}


def record(name, ok_, detail=""):
    checkpoints[name] = {"result": "pass" if ok_ else "fail", "detail": detail}
    print(("PASS " if ok_ else "FAIL ") + name + (": " + detail if detail else ""))


def sh(args, cwd=None, check=True, env=None):
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, env=env)
    if check and r.returncode != 0:
        raise RuntimeError("cmd failed: %r\nSTDOUT:%s\nSTDERR:%s" % (args, r.stdout, r.stderr))
    return r


def git(repo, *args, check=True):
    return sh(["git", "-C", repo] + list(args), check=check)


def rev_parse(repo, ref):
    return git(repo, "rev-parse", ref).stdout.strip()


def write(path, content):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)


def chmod_x(path):
    os.chmod(path, 0o755)


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as fh:
        return [l for l in fh.read().splitlines() if l.strip()]


def journal_events(path):
    out = []
    for line in read_lines(path):
        try:
            out.append(json.loads(line))
        except Exception:
            pass
    return out


# ── the tick_runner.py child: one whole watcher-tick lifetime, python3 process boundary ─────────────
# Genuinely separate `python3` subprocesses so a chaos-kill is a REAL, untrappable os.kill(SIGKILL) —
# not a simulated exit() a `finally` could still run after.
TICK_RUNNER = os.path.join(T, "tick_runner.py")
write(TICK_RUNNER, r'''
import json, os, sys
sys.path.insert(0, os.environ["PYSRC"])
from herd.live_runtime import LiveActuator, LiveGates, LiveJournal, LiveState, LiveCandidate, LiveTick

def _cand(a):
    return LiveCandidate(pr=a["pr"], sha=a["sha"], slug=a["slug"], worktree=a.get("worktree", ""))

def main():
    leg, op = sys.argv[1], sys.argv[2]
    args = json.loads(sys.argv[3])
    state = LiveState(args["state_dir"])
    journal = LiveJournal(args["journal_path"])
    config = args.get("config") or {}
    cand = _cand(args)
    out = {}
    if leg == "merge":
        actuator = LiveActuator(args.get("home", "/nonexistent"), journal, config)
        if op == "attempt":
            if actuator.merge(cand):
                state.clear_merge_refusal(cand.pr, cand.sha)
                actuator.reap(cand)
                out["result"] = "MERGED"
            else:
                out["result"] = "HELD"
    elif leg == "collect":
        gates = LiveGates(args.get("home", "/nonexistent"), state, journal, config)
        out["result"] = gates.health(cand)
        out["reused"] = gates.reused_health
    elif leg == "bounce":
        actuator = LiveActuator(args.get("home", "/nonexistent"), journal, config)
        tick = LiveTick(config, None, None, actuator, journal, state=state)
        round_num, reason = tick._refix_check_and_record(cand, "health")
        if round_num is None and reason is None:
            out["result"] = "HELD"  # matches _walk's own mapping: once-guard holds -> BLOCK
        elif reason is not None:
            out["result"] = "ESCALATE"
            out["reason"] = reason
        else:
            out["result"] = tick._bounce_and_wake(cand, "health", round_num, "CODEERROR")
            out["round"] = round_num
    else:
        raise SystemExit("unknown leg: %s" % leg)
    sys.stdout.write(json.dumps(out) + "\n")

if __name__ == "__main__":
    main()
''')

CHAOS_GUARD = os.path.join(T, ".chaos-guard")
write(CHAOS_GUARD, "hermetic chaos harness sentinel\n")


def run_tick(leg, op, args, kill_at=None, extra_env=None):
    """Run one tick_runner.py subprocess. Returns (returncode, stdout, killed_by_sigkill)."""
    env = dict(os.environ)
    env["PYSRC"] = os.path.join(REPO, "pysrc")
    env["HERD_CHAOS_GUARD"] = CHAOS_GUARD
    if kill_at:
        env["HERD_CHAOS_KILL_AT"] = kill_at
    else:
        env.pop("HERD_CHAOS_KILL_AT", None)
    if extra_env:
        env.update(extra_env)
    proc = subprocess.run([sys.executable, TICK_RUNNER, leg, op, json.dumps(args)],
                          capture_output=True, text=True, env=env)
    killed = proc.returncode == -signal.SIGKILL
    return proc.returncode, proc.stdout.strip(), killed


print("driver starting, T=%s" % T)

# ═══ LEG B: mid_gate_collect ═════════════════════════════════════════════════════════════════════
print("\n=== LEG B: mid_gate_collect ===")
legb = os.path.join(T, "legb")
os.makedirs(legb, exist_ok=True)
wt = os.path.join(legb, "wt")
os.makedirs(wt, exist_ok=True)
git(wt, "init", "-q")
git(wt, "config", "user.email", "sim@sim")
git(wt, "config", "user.name", "sim")
write(os.path.join(wt, "f.txt"), "hi\n")
git(wt, "add", "-A")
git(wt, "commit", "-q", "-m", "init")

state_dir = os.path.join(legb, "state")
os.makedirs(state_dir)
journal_path = os.path.join(legb, "run.jsonl")

worker_log = os.path.join(legb, "worker-calls.log")
stub_hc = os.path.join(legb, "stub-hc.sh")
write(stub_hc, "#!/usr/bin/env bash\necho run >> %r\nexit 0\n" % worker_log)
chmod_x(stub_hc)
herdconfig = os.path.join(legb, "herdconfig")
write(herdconfig, 'HEALTHCHECK_CMD="%s"\n' % stub_hc)

cand_args = {"pr": "501", "sha": "shaB01", "slug": "legb-slug", "worktree": wt,
             "state_dir": state_dir, "journal_path": journal_path, "home": REPO}
env_b = {"HERD_CONFIG_FILE": herdconfig}

# tick 1: dispatch (no chaos) -> WAIT, real background worker starts
rc, out, killed = run_tick("collect", "collect", cand_args, extra_env=env_b)
record("legb_dispatch", (not killed) and json.loads(out).get("result") == "WAIT",
       "dispatch tick result=%r killed=%s" % (out, killed))

# wait for the (detached) worker to finish writing the dispatch out-file
disp = os.path.join(state_dir, ".health-dispatch-501-shaB01")
#
# HERD-434: this poll is a TEST-HARNESS observation window, not a production contract — health()
# itself never gives up on a slow dispatch, it just returns WAIT again next tick, forever. A too-
# tight window here was CI-red on both platforms while green on every local run (2026-07-28 through
# 2026-07-30): the dispatched worker is FOUR nested `bash` fork+execs deep (Popen -> healthcheck.sh
# -> `bash -c $HEALTHCHECK_CMD` -> the worker script's own `#!/usr/bin/env bash` shebang), each of
# which sources herd-config.sh + four lint scripts and runs a couple of `git` probes. Reproduced
# locally by inserting a fixed per-fork-exec delay (a PATH-shimmed `bash` sleeping before exec'ing
# the real one): at ~1s of added latency per hop the chain already lands at ~4.3s, at ~2s it lands
# at ~8.3s — linear in the hop count, so GH Actions' slower/shared/cold-cache runners (this is
# hermetic test #138 of 166, run sequentially, no warm page cache to lean on) landing past the old
# 15s bound is entirely plausible, and — because the SAME chain runs every tick — deterministic
# rather than occasional. A blown deadline here does NOT reveal a race in do_merge / gate-collect /
# refix-bounce: it just means this observation window gave up before the (correctly, eventually
# convergent) async dispatch finished, and every downstream checkpoint in this leg cascades false
# off that one early giveup. Widened, not removed, so a GENUINELY hung dispatch still fails loudly
# well inside run-suite.sh's 120s per-test cap (scripts/ci/run-suite.sh:HERD_CI_TEST_TIMEOUT).
deadline = time.time() + 75
while time.time() < deadline and not os.path.exists(disp):
    time.sleep(0.1)
record("legb_worker_landed", os.path.exists(disp), "dispatch out-file present: %s" % disp)

# tick 2: collect, KILLED mid-collect (after verdict parsed, before record_health_result)
rc, out, killed = run_tick("collect", "collect", cand_args, kill_at="mid_gate_collect", extra_env=env_b)
record("legb_killed_by_sigkill", killed, "rc=%s (want SIGKILL == -9)" % rc)
record("legb_no_premature_cache", not os.path.exists(os.path.join(state_dir, ".health-result-501-shaB01")),
       "cache file must not exist yet — died before record_health_result")
record("legb_scratch_survives_kill", os.path.exists(disp),
       "the dispatch out-file the killed process was reading must still be on disk")

# tick 3: restart, collect again (no chaos) -> must complete cleanly from the SAME durable out-file
rc, out, killed = run_tick("collect", "collect", cand_args, extra_env=env_b)
result3 = json.loads(out) if out else {}
record("legb_restart_converges", (not killed) and result3.get("result") == "CLEAN",
       "restart tick result=%r killed=%s" % (out, killed))
record("legb_no_redispatch", len(read_lines(worker_log)) == 1,
       "underlying suite ran exactly once across the crash (worker calls=%d)" % len(read_lines(worker_log)))
record("legb_scratch_cleaned", not os.path.exists(disp) and
       not os.path.exists(os.path.join(state_dir, ".health-inflight-501-shaB01")),
       "dispatch/inflight scratch files cleaned up after the clean collect")

# tick 4: fixed point — cache hit, zero further worker runs
rc, out, killed = run_tick("collect", "collect", cand_args, extra_env=env_b)
result4 = json.loads(out) if out else {}
record("legb_fixed_point", (not killed) and result4.get("result") == "CLEAN" and result4.get("reused") is True
       and len(read_lines(worker_log)) == 1,
       "re-collect reuses the cache (reused=%r), no further worker run" % result4.get("reused"))

# ═══ LEG C: mid_refix_bounce ═════════════════════════════════════════════════════════════════════
print("\n=== LEG C: mid_refix_bounce ===")
legc = os.path.join(T, "legc")
os.makedirs(legc, exist_ok=True)
state_dir_c = os.path.join(legc, "state")
os.makedirs(state_dir_c)
journal_path_c = os.path.join(legc, "run.jsonl")

BIN = os.path.join(legc, "bin")
os.makedirs(BIN, exist_ok=True)
ROSTER = os.path.join(legc, "roster.json")
WAKE_LOG = os.path.join(legc, "wake-calls.log")
write(ROSTER, json.dumps({"result": {"agents": [
    {"name": "legc-slug", "agent_status": "idle", "pane_id": "pane-1"}]}}))
herdr_stub = os.path.join(BIN, "herdr")
write(herdr_stub, r'''#!/usr/bin/env bash
case "$1 $2" in
  "agent list") cat "$ROSTER" ;;
  "pane run")
    printf '1\n' >> "$WAKE_LOG"
    python3 -c "
import json, os
p = os.environ['ROSTER']
d = json.load(open(p))
for a in d['result']['agents']:
    if a['pane_id'] == '$3':
        a['agent_status'] = 'working'
json.dump(d, open(p, 'w'))
" ;;
  "pane send-keys") : ;;
esac
exit 0
''')
chmod_x(herdr_stub)

cand_args_c = {"pr": "601", "sha": "shaC01", "slug": "legc-slug", "worktree": "",
               "state_dir": state_dir_c, "journal_path": journal_path_c, "home": REPO}
env_c = {"PATH": BIN + os.pathsep + os.environ.get("PATH", ""), "ROSTER": ROSTER, "WAKE_LOG": WAKE_LOG}

# tick 1: bounce, KILLED after wake_builder actuates but before refix_bounce/refix_wake_result journal.
rc, out, killed = run_tick("bounce", "bounce", cand_args_c, kill_at="mid_refix_bounce", extra_env=env_c)
record("legc_killed_by_sigkill", killed, "rc=%s (want SIGKILL == -9)" % rc)
record("legc_wake_sent_once", len(read_lines(WAKE_LOG)) == 1,
       "the builder pane received exactly one wake attempt (calls=%d)" % len(read_lines(WAKE_LOG)))
roster_after_1 = json.load(open(ROSTER))
record("legc_pane_genuinely_woken", roster_after_1["result"]["agents"][0]["agent_status"] == "working",
       "the wake side effect landed (agent_status=%r) even though bookkeeping did not"
       % roster_after_1["result"]["agents"][0]["agent_status"])
ledger_path = os.path.join(state_dir_c, ".agent-watch-refixed")
ledger_rows = read_lines(ledger_path)
record("legc_once_guard_written", len(ledger_rows) == 1,
       "exactly one refix once-guard row landed before the kill (rows=%d)" % len(ledger_rows))
evs1 = journal_events(journal_path_c)
record("legc_no_journal_pair_yet", not any(e.get("event") in ("refix_bounce", "refix_wake_result") for e in evs1),
       "process 1 died strictly before its journal writes — the honest, bounded observability gap")

# tick 2: restart. Once-guard already holds -> hold silently, NO second wake.
rc, out, killed = run_tick("bounce", "bounce", cand_args_c, extra_env=env_c)
result2 = json.loads(out) if out else {}
record("legc_restart_holds_silently", (not killed) and result2.get("result") == "HELD",
       "restart tick result=%r killed=%s" % (out, killed))
record("legc_no_duplicate_wake", len(read_lines(WAKE_LOG)) == 1,
       "still exactly one wake attempt total across both processes (calls=%d)" % len(read_lines(WAKE_LOG)))
record("legc_ledger_not_duplicated", len(read_lines(ledger_path)) == 1,
       "still exactly one once-guard row (rows=%d)" % len(read_lines(ledger_path)))

# tick 3: the builder pushes a fix (new sha) -> the sha-keyed once-guard naturally re-arms.
cand_args_c2 = dict(cand_args_c, sha="shaC02")
write(ROSTER, json.dumps({"result": {"agents": [
    {"name": "legc-slug", "agent_status": "idle", "pane_id": "pane-1"}]}}))
rc, out, killed = run_tick("bounce", "bounce", cand_args_c2, extra_env=env_c)
result3 = json.loads(out) if out else {}
# round=2, NOT round=1: only the ONCE-GUARD is sha-keyed (contract §4) — the rail's per-PR lifetime
# round count is not sha-keyed and correctly keeps counting (round 1 was shaC01's bounce). The proof
# here is narrower and more important: a fresh sha is NOT permanently held by the prior sha's
# once-guard — _refix_check_and_record grants a genuine new round rather than returning (None, None).
record("legc_new_sha_rearms", (not killed) and result3.get("result") == "BLOCK" and result3.get("round") == 2,
       "a fresh sha opens a fresh round (result=%r) — the system is not permanently wedged" % out)

# ═══ LEG A: mid_do_merge ═════════════════════════════════════════════════════════════════════════
print("\n=== LEG A: mid_do_merge ===")
lega = os.path.join(T, "lega")
os.makedirs(lega, exist_ok=True)
PR_A, SLUG_A = "701", "lega-slug"

MAIN = os.path.join(lega, "main")
TREES = os.path.join(lega, "trees")
os.makedirs(MAIN, exist_ok=True)
os.makedirs(TREES, exist_ok=True)
git(MAIN, "init", "-q", "-b", "main")
git(MAIN, "config", "user.email", "sim@sim")
git(MAIN, "config", "user.name", "sim")
write(os.path.join(MAIN, "base.txt"), "base\n")
git(MAIN, "add", "-A")
git(MAIN, "commit", "-q", "-m", "base")

WT_A = os.path.join(TREES, SLUG_A)
git(MAIN, "worktree", "add", "-q", "-b", "feat/%s" % SLUG_A, WT_A, "main")
write(os.path.join(WT_A, "feature.txt"), "the feature\n")
git(WT_A, "add", "-A")
sh(["git", "-c", "user.email=sim@sim", "-c", "user.name=sim", "-C", WT_A, "commit", "-qam", SLUG_A])
SHA_A = rev_parse(WT_A, "HEAD")

state_dir_a = os.path.join(lega, "state-marker")  # unused by the merge tick itself; LiveState needs a dir
os.makedirs(state_dir_a, exist_ok=True)
journal_path_a = os.path.join(lega, "run.jsonl")

GH_DIR = os.path.join(lega, "gh")
os.makedirs(GH_DIR, exist_ok=True)
BIN_A = os.path.join(lega, "bin")
os.makedirs(BIN_A, exist_ok=True)
gh_stub = os.path.join(BIN_A, "gh")
write(gh_stub, r'''#!/usr/bin/env bash
merged() { [ -f "$GH_DIR/merged" ]; }
case "${1:-} ${2:-}" in
  "pr merge")
    if ! merged; then
      git -C "$SIM_MAIN" merge -q --no-ff -m "merge #$SIM_PR" "feat/$SIM_SLUG" >/dev/null 2>&1 || exit 1
      : > "$GH_DIR/merged"
      printf '1\n' >> "$GH_DIR/merge-calls"
    fi
    exit 0 ;;
  "pr view")
    case "$*" in
      *"--json body"*) merged && cat "$GH_DIR/body.txt"; exit 0 ;;
      *"state,mergedAt"*|*state*) merged && printf 'MERGED\n' || printf 'OPEN\n'; exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
''')
chmod_x(gh_stub)

# herdr: a tab registry in one JSON file; `tab close` removes a tab (mirrors postmerge-reconcile-sim.sh).
herdr_stub_a = os.path.join(BIN_A, "herdr")
write(herdr_stub_a, r'''#!/usr/bin/env bash
case "$1 ${2:-}" in
  "workspace list") printf '{"result":{"workspaces":[{"name":"simws","workspace_id":"ws1"}]}}\n' ;;
  "tab list")       cat "$HERDR_TABS" ;;
  "tab close")      TAB="${3:-}" python3 -c '
import json, os
p = os.environ["HERDR_TABS"]; tid = os.environ["TAB"]
d = json.load(open(p))
d["result"]["tabs"] = [t for t in d["result"]["tabs"] if t["tab_id"] != tid]
json.dump(d, open(p, "w"))
' ;;
  "agent list")     printf '{"result":{"agents":[]}}\n' ;;
esac
exit 0
''')
chmod_x(herdr_stub_a)

write(os.path.join(GH_DIR, "body.txt"), "Implements the thing.\n\nRefs: HERD-425-sim\n")
tabs_json = os.path.join(lega, "tabs.json")
write(tabs_json, json.dumps({"result": {"tabs": [{"tab_id": "t-build", "label": SLUG_A, "workspace_id": "ws1"}]}}))
write(os.path.join(TREES, ".herd-tabs"), "%s t-build 0\n" % SLUG_A)

HERD_STUB = os.path.join(lega, "herd-stub")
os.makedirs(HERD_STUB, exist_ok=True)
scribe_log = os.path.join(lega, "scribe.log")
write(os.path.join(HERD_STUB, "scribe.sh"), '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s"\n' % scribe_log)
chmod_x(os.path.join(HERD_STUB, "scribe.sh"))
write(scribe_log, "")

pms_prs_json = os.path.join(lega, "merged-prs.json")

env_a_base = dict(os.environ)
env_a_base["PATH"] = BIN_A + os.pathsep + env_a_base.get("PATH", "")
env_a_base["PYSRC"] = os.path.join(REPO, "pysrc")
env_a_base["HERD_CHAOS_GUARD"] = CHAOS_GUARD
env_a_base["SIM_MAIN"] = MAIN
env_a_base["SIM_PR"] = PR_A
env_a_base["SIM_SLUG"] = SLUG_A
env_a_base["GH_DIR"] = GH_DIR

merge_args = {"pr": PR_A, "sha": SHA_A, "slug": SLUG_A, "worktree": WT_A,
              "state_dir": state_dir_a, "journal_path": journal_path_a, "home": REPO}

# tick 1: the REAL LiveActuator.merge — KILLED right after the merge lands, before journal+reap.
env1 = dict(env_a_base); env1["HERD_CHAOS_KILL_AT"] = "mid_do_merge"
proc1 = subprocess.run([sys.executable, TICK_RUNNER, "merge", "attempt", json.dumps(merge_args)],
                       capture_output=True, text=True, env=env1)
killed_a = proc1.returncode == -signal.SIGKILL
record("lega_killed_by_sigkill", killed_a, "rc=%s (want SIGKILL == -9)" % proc1.returncode)

merge_log = git(MAIN, "log", "--oneline").stdout
record("lega_merge_landed_before_death", ("merge #%s" % PR_A) in merge_log,
       "the remote merge action itself is unrecoverable and already landed")
record("lega_worktree_not_yet_reaped", os.path.isdir(WT_A),
       "process 1 died before reap() ever ran — worktree must still be on disk")
evs_a1 = journal_events(journal_path_a)
record("lega_no_merge_journal_yet", not any(e.get("event") == "merge" for e in evs_a1),
       "process 1 died strictly before the journal 'merge' write")

# ── the reconciler: a FRESH watcher tick (bash, _sweep_merged_prs) over the SAME durable state ──────
# LiveActuator never writes the bash $STATE ledger or touches the tracker at all (capabilities.tsv:
# do_merge — incl. reconcile_backlog — "has zero production call sites"), so this sweep is not a
# fallback for the crash case only: it is the SAME seam that discharges every Python-actuated merge,
# clean or crashed, in the current hybrid architecture.
write(pms_prs_json, json.dumps([
    {"number": int(PR_A), "headRefOid": SHA_A, "headRefName": "feat/%s" % SLUG_A,
     "mergedAt": "2026-01-01T00:00:00Z"}]))

sweep_sh = os.path.join(lega, "sweep_tick.sh")
write(sweep_sh, r'''#!/usr/bin/env bash
set -uo pipefail
export AGENT_WATCH_LIB=1
# shellcheck source=/dev/null
. "$WATCH_SH_SIM" || { echo "SOURCE-FAIL"; exit 2; }
MAIN="$SIM_MAIN"; TREES="$SIM_TREES"; SELF_WT="$SIM_MAIN/.self"
STATE="$TREES/.agent-watch-merged"
DEFAULT_BRANCH="main"; DRYRUN=""; WORKSPACE_NAME="simws"
export WORKSPACE_NAME
export HERD_DISPOSABLE_WORKSPACE=1
HERE="$SIM_STUB_HERD"
refresh_codemap() { :; }
refresh_symbol_index() { :; }
main_health_tick() { :; }
_sweep_merged_prs
''')
chmod_x(sweep_sh)

env_sweep = dict(env_a_base)
env_sweep.pop("HERD_CHAOS_KILL_AT", None)
env_sweep.update({
    "WATCH_SH_SIM": WATCH_SH, "SIM_MAIN": MAIN, "SIM_TREES": TREES, "SIM_STUB_HERD": HERD_STUB,
    "HERDR_TABS": tabs_json, "HERD_CONFIG_FILE": os.path.join(lega, "no-config"),
    "JOURNAL_FILE": journal_path_a, "HERD_PMS_PRS_JSON_FILE": pms_prs_json,
    "HERD_TRANSCRIPT_ROOT": os.path.join(lega, "transcripts"),
    # HERD-436: PROJECT_ROOT/WORKTREES_DIR/WORKSPACE_NAME pre-seeded via ENV (not just sweep_tick.sh's
    # post-source `TREES="$SIM_TREES"` reassignment) — herd-config.sh's PROJECT_ROOT/WORKTREES_DIR
    # FALLBACK runs DURING `. "$WATCH_SH_SIM"`, i.e. BEFORE sweep_tick.sh's own reassignment lines ever
    # execute. Every agent-watch.sh module-level constant derived from $TREES at source time (line 314:
    # `TREES="$WORKTREES_DIR"`, then RECONCILE_STATE/TRACKER_SWEEP_LEDGER/POSTMERGE_SWEPT_LEDGER/
    # POSTMERGE_NOTED_LEDGER, all `"$TREES/…"`) was baking in whatever WORKTREES_DIR the NO-CONFIG
    # fallback resolved BEFORE the override landed — HERD_CONFIG_FILE points at a nonexistent path, so
    # herd-config.sh falls through to `PROJECT_ROOT="$(_herd_main_worktree "$_HERD_REPO_DEFAULT")"`,
    # i.e. THIS REPO's real main working tree, so WORKTREES_DIR became the REAL "<project>-trees" pool
    # dir sitting next to it. Pre-seeding these three here — same values sweep_tick.sh already sets
    # post-source, just visible to the CHILD PROCESS from before it execs bash, so herd-config.sh's
    # `[ -z "${PROJECT_ROOT:-}" ]` / `: "${WORKTREES_DIR:=…}"` / `: "${WORKSPACE_NAME:=…}"` guards see
    # them already set and never touch the real filesystem — makes every such constant resolve inside
    # the sim's OWN sandbox from the first instruction, matching what "Hermetic: … zero real … network
    # calls" already promises for gh/herdr but this sim was not actually delivering for the filesystem.
    "PROJECT_ROOT": MAIN, "WORKTREES_DIR": TREES, "WORKSPACE_NAME": "simws",
})


def run_sweep():
    return subprocess.run(["bash", sweep_sh], capture_output=True, text=True, env=env_sweep)


# process 2: the reconciler. Must be a genuinely FRESH process (no in-memory carryover) over disk.
r2 = run_sweep()
record("lega_sweep_ran", r2.returncode == 0, "sweep exit=%s stderr=%s" % (r2.returncode, r2.stderr[:300]))
evs_a2 = journal_events(journal_path_a)
record("lega_reconciled_once", any(e.get("event") == "postmerge_reconciled" and str(e.get("pr")) == PR_A
                                   for e in evs_a2),
       "the sweep discharged the crashed merge's obligations (postmerge_reconciled)")
record("lega_merge_observed_honest", any(e.get("event") == "merge_observed" and str(e.get("pr")) == PR_A
                                         and e.get("reason") == "reconcile" for e in evs_a2),
       "the observed merge carries honest provenance (merge_observed, reason=reconcile) — never a bare "
       "'merge' event the sweep cannot back with its own reap")
record("lega_worktree_reaped", not os.path.isdir(WT_A), "the worktree is gone after reconcile")
record("lega_tracker_reconciled_once", len(read_lines(scribe_log)) == 1,
       "exactly one backlog/tracker reconcile enqueue (scribe calls=%d)" % len(read_lines(scribe_log)))
state_rows_exact = [l for l in read_lines(os.path.join(TREES, ".agent-watch-merged")) if len(l.split()) > 1 and l.split()[1] == PR_A]
record("lega_state_row_exactly_once", len(state_rows_exact) == 1,
       "$STATE carries exactly one merge row for PR #%s (rows=%d)" % (PR_A, len(state_rows_exact)))

# process 3: fixed point — re-running the sweep over a converged world is byte-inert.
before = len(journal_events(journal_path_a))
r3 = run_sweep()
after = len(journal_events(journal_path_a))
record("lega_sweep_fixed_point", before == after and r3.returncode == 0,
       "re-running the sweep is byte-inert (journal lines %d -> %d)" % (before, after))

# no duplicate remote merge: the stub gh's merge-calls counter increments ONLY on a genuine new commit.
merge_calls = read_lines(os.path.join(GH_DIR, "merge-calls"))
record("lega_no_duplicate_remote_merge", len(merge_calls) == 1,
       "the remote merge side effect happened exactly once (gh pr merge calls that created a NEW "
       "commit=%d)" % len(merge_calls))
merge_commit_count = merge_log.count("merge #%s" % PR_A)
record("lega_one_merge_commit_in_history", merge_commit_count == 1,
       "exactly one merge commit for PR #%s in main's history (count=%d)" % (PR_A, merge_commit_count))

# main-health eventually green: run the real healthcheck.sh (stubbed HEALTHCHECK_CMD) against main.
main_hc = os.path.join(lega, "main-hc.sh")
write(main_hc, "#!/usr/bin/env bash\nexit 0\n")
chmod_x(main_hc)
main_herdconfig = os.path.join(lega, "main-herdconfig")
write(main_herdconfig, 'HEALTHCHECK_CMD="%s"\n' % main_hc)
env_hc = dict(os.environ)
env_hc["HERD_CONFIG_FILE"] = main_herdconfig
r_hc = subprocess.run(["bash", os.path.join(REPO, "scripts", "herd", "healthcheck.sh"), MAIN],
                      capture_output=True, text=True, env=env_hc)
record("lega_main_health_green", r_hc.returncode == 0,
       "main-health after reconcile: rc=%s" % r_hc.returncode)

# Machine-readable scorecard: a top-level result=pass|fail alongside every named checkpoint — the
# top-level field is the one thing a caller (the healthcheck gate, herd conformance run, a human
# skimming rep-N/scorecard.json) needs to answer "did this rep pass" without walking every checkpoint.
overall = "pass" if checkpoints and all(v["result"] == "pass" for v in checkpoints.values()) else "fail"
scorecard = {"scenario": "gate-reconciler-chaos", "rep": os.environ.get("REP", "1"), "result": overall,
             "checkpoints": checkpoints}
with open(os.path.join(T, "scorecard.json"), "w", encoding="utf-8") as fh:
    json.dump(scorecard, fh, indent=2, sort_keys=True)
sys.exit(0 if overall == "pass" else 1)
PYEOF

FAIL=0

run_rep() {
  local rep="$1" repdir="$ART/rep-$1"
  rm -rf "$repdir"; mkdir -p "$repdir"
  PYTHONPATH="$REPO/pysrc" HERDKIT_REPO="$REPO" WATCH_SH="$REPO/scripts/herd/agent-watch.sh" \
  SIMDIR="$repdir" REP="$rep" python3 "$DRIVER"
}

for rep in $(seq 1 "$REPS"); do
  step "rep $rep/$REPS" "driving all three chaos legs"
  if run_rep "$rep"; then
    ok "rep $rep — all legs pass"
  else
    bad "rep $rep — at least one leg failed (see $ART/rep-$rep/scorecard.json)"
    FAIL=1
  fi
done

# Aggregate scorecard.json: one top-level result=pass|fail across every rep, plus each rep's own
# scorecard (checkpoints intact) nested under it — the single machine-readable artifact this scenario
# registers as its conformance sim proof (templates/conformance.tsv).
ART="$ART" python3 <<'PYEOF'
import glob, json, os
art = os.environ["ART"]
reps = []
overall = "pass"
for p in sorted(glob.glob(os.path.join(art, "rep-*", "scorecard.json")),
                key=lambda p: int(os.path.basename(os.path.dirname(p)).split("-")[1])):
    with open(p, encoding="utf-8") as fh:
        d = json.load(fh)
    reps.append(d)
    if d.get("result") != "pass":
        overall = "fail"
if not reps:
    overall = "fail"
aggregate = {"scenario": "gate-reconciler-chaos", "result": overall, "reps": len(reps),
             "rep_scorecards": reps}
with open(os.path.join(art, "scorecard.json"), "w", encoding="utf-8") as fh:
    json.dump(aggregate, fh, indent=2, sort_keys=True)
PYEOF

if [ "$FAIL" -eq 0 ]; then
  echo
  echo "ALL PASS — gate-reconciler chaos sim ($REPS rep(s), HERD-425)"
  info "scorecard: $ART/scorecard.json (result=pass)"
  exit 0
fi
echo
echo "FAIL — see $ART/scorecard.json"
exit 1
