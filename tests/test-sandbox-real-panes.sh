#!/usr/bin/env bash
# test-sandbox-real-panes.sh — hermetic proof of the P2b DISPOSABLE REAL-HERDR-PANES simulation
# (scripts/herd/sim/sandbox-real-panes-scenario.sh), which stands up a REAL herdr control room
# (watcher pane + backlog pane + a builder tab with a stub builder), asserts pane/tab existence,
# labels, and agent-status transitions (idle→working→done) via herdr's JSON output, then closes the
# disposable workspace and proves NO tab/pane leaked.
#
# The scenario's ONLY non-local surface is the herdr socket, so this test drives it two ways WITHOUT
# ever touching the real herdr server (keeping the healthcheck suite hermetic and leak-guard-safe):
#
#   (A) SKIP PATH — with SANDBOX_NO_HERDR=1 the scenario must degrade LOUDLY-BUT-CLEANLY: result
#       "skip", exit 0, every pane checkpoint recorded as `skip` (never `fail`). This is the
#       headless-CI / no-false-red contract.
#   (B) STUB-HERDR PATH — a FILE-BACKED fake `herdr` on PATH (a JSON state machine; NO real panes,
#       NO server) lets the scenario run its FULL flow: create workspace → control room → builder tab
#       → idle/working/done transitions → close + assert clean teardown. Proves the assertion and
#       teardown accounting, deterministically, with zero real herdr side effects.
#   (C) SCORECARD SHAPE — the sandbox-sim JSON plus the real-pane fields (herdr_available,
#       tabs_created, panes_created, agent_transitions, leaked_tabs, …).
#   (D) HERMETIC — neither path leaves a new entry in the real repo tree.
#
# Fully hermetic: local git only, NO real herdr, NO network, NO model, NO screenshots (opt-out).
# Mirrors the conventions of tests/test-sandbox-sim.sh and tests/test-sandbox-limit-resume.sh.
# Run:  bash tests/test-sandbox-real-panes.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="$HERE/../scripts/herd/sim/sandbox-real-panes-scenario.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || fail "git required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -f "$SCENARIO" ] || fail "missing $SCENARIO"

# Baseline of the real repo's working-tree status BEFORE any scenario runs, so (D) can prove the
# scenario adds NOTHING of its own to the real tree.
REPO_ROOT="$(cd "$HERE/.." && pwd)"
BASELINE_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"

# jq-free scorecard readers.
sc() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
cp_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["checkpoints"]:
    if c["name"]==sys.argv[2]: print(c["status"]); break
' "$1" "$2"
}
cp_count_status() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for c in d["checkpoints"] if c["status"]==sys.argv[2]))
' "$1" "$2"
}

# ── (A) SKIP PATH — herdr forced off: clean skip, never a red ────────────────────
ARTS="$T/skip"
SANDBOX_NO_HERDR=1 SANDBOX_NO_SCREENSHOT=1 \
  bash "$SCENARIO" --artifacts "$ARTS" >"$T/skip.out" 2>&1 \
  || fail "(A) skip path exited non-zero (must exit 0)"$'\n'"$(cat "$T/skip.out")"
SCS="$ARTS/scorecard.json"
[ -f "$SCS" ] || fail "(A) scorecard.json not emitted at $SCS"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCS" || fail "(A) skip scorecard not valid JSON"
[ "$(sc "$SCS" result)" = "skip" ]           || fail "(A) result should be skip (got $(sc "$SCS" result))"
[ "$(sc "$SCS" failed)" -eq 0 ]              || fail "(A) skip path must have 0 failures"
[ "$(sc "$SCS" herdr_available)" = "False" ] || fail "(A) herdr_available should be False on skip"
[ "$(cp_status "$SCS" herdr_available)" = "skip" ] || fail "(A) herdr_available checkpoint should be skip"
# No pane checkpoint may FAIL on the skip path; several must be recorded as skip (loud, not silent).
[ "$(cp_count_status "$SCS" fail)" -eq 0 ]   || fail "(A) skip path recorded a FAIL — must never false-red"
[ "$(cp_count_status "$SCS" skip)" -ge 5 ]   || fail "(A) skip path should loudly skip the pane checkpoints"
# The fixture still builds locally even with no herdr.
[ "$(cp_status "$SCS" fixture_built)" = "pass" ] || fail "(A) fixture_built should still pass with no herdr"
# HERD-139: the notify-hermeticity invariant holds even on the skip path (nothing ran → nothing leaked),
# and the notify-stub checkpoint is loudly skipped (never a false fail) when there is no herdr.
[ "$(cp_status "$SCS" notify_hermetic)" = "pass" ] || fail "(A) notify_hermetic should pass on the skip path"
[ "$(cp_status "$SCS" notify_stubbed)" = "skip" ]  || fail "(A) notify_stubbed should be skip with no herdr"
echo "PASS (A) SANDBOX_NO_HERDR=1 → clean loud skip (result=skip, exit 0, 0 fails)"

# ── build a FILE-BACKED stub `herdr` (a JSON state machine — no real panes, no server) ────────────
BIN="$T/bin"; mkdir -p "$BIN"
STATE="$T/herdr-state.json"; printf '{"workspaces":{},"next":1}\n' > "$STATE"
cat > "$BIN/herdr" <<'HERDR'
#!/usr/bin/env bash
# Hermetic file-backed herdr stub: a minimal JSON state machine over $HERDR_STATE. Implements only
# the surface the real-panes scenario drives. NO real panes, NO server, NO network.
exec python3 - "$HERDR_STATE" "$@" <<'PY'
import sys, json, os
state_path = sys.argv[1]
args = sys.argv[2:]
def load():
    try: return json.load(open(state_path))
    except Exception: return {"workspaces": {}, "next": 1}
def save(s): json.dump(s, open(state_path, "w"))
def nid(s, pfx):
    n = s["next"]; s["next"] = n + 1; return "%s%d" % (pfx, n)
def emit(result): print(json.dumps({"result": result})); sys.exit(0)
def opt(name, default=None):
    return args[args.index(name)+1] if name in args and args.index(name)+1 < len(args) else default
def all_panes(s):
    for wid, w in s["workspaces"].items():
        for tid, t in w["tabs"].items():
            for pid, p in t["panes"].items():
                yield wid, tid, pid, p
s = load()
cmd = " ".join(args[:2])

if cmd == "workspace list":
    emit({"workspaces": [{"workspace_id": wid, "label": w["label"]} for wid, w in s["workspaces"].items()]})

if cmd == "workspace create":
    wid = nid(s, "w"); tid = nid(s, wid + ":t"); pid = nid(s, wid + ":p")
    s["workspaces"][wid] = {"label": opt("--label", ""), "tabs": {tid: {"label": "1", "panes": {pid: {"label": None, "agent": None, "agent_status": "unknown"}}}}}
    save(s)
    emit({"workspace": {"workspace_id": wid, "label": s["workspaces"][wid]["label"]},
          "tab": {"tab_id": tid, "workspace_id": wid},
          "root_pane": {"pane_id": pid, "tab_id": tid, "workspace_id": wid}})

if cmd == "workspace close":
    s["workspaces"].pop(args[2], None); save(s); emit({"type": "ok"})

if cmd == "tab create":
    wid = opt("--workspace")
    if wid not in s["workspaces"]: emit({})
    tid = nid(s, wid + ":t"); pid = nid(s, wid + ":p")
    s["workspaces"][wid]["tabs"][tid] = {"label": opt("--label", ""), "panes": {pid: {"label": None, "agent": None, "agent_status": "unknown"}}}
    save(s)
    emit({"tab": {"tab_id": tid, "workspace_id": wid, "label": opt("--label", "")},
          "root_pane": {"pane_id": pid, "tab_id": tid, "workspace_id": wid}})

if cmd == "tab list":
    wid = opt("--workspace")
    tabs = []
    for w_id, w in s["workspaces"].items():
        if wid and w_id != wid: continue
        for tid, t in w["tabs"].items():
            statuses = [p.get("agent_status") for p in t["panes"].values() if p.get("agent")]
            tabs.append({"tab_id": tid, "workspace_id": w_id, "label": t["label"],
                         "agent_status": statuses[0] if statuses else "unknown", "pane_count": len(t["panes"])})
    emit({"tabs": tabs})

if cmd == "tab rename":
    for w in s["workspaces"].values():
        if args[2] in w["tabs"]: w["tabs"][args[2]]["label"] = args[3]
    save(s); emit({"type": "ok"})

if cmd == "pane split":
    src = args[2]
    for wid, w in s["workspaces"].items():
        for tid, t in w["tabs"].items():
            if src in t["panes"]:
                pid = nid(s, wid + ":p")
                t["panes"][pid] = {"label": None, "agent": None, "agent_status": "unknown"}
                save(s); emit({"pane": {"pane_id": pid, "tab_id": tid, "workspace_id": wid}})
    emit({})

if cmd == "pane close":
    pane = args[2]
    for w in s["workspaces"].values():
        for t in w["tabs"].values():
            t["panes"].pop(pane, None)
    save(s); emit({"type": "ok"})

if cmd == "pane list":
    wid = opt("--workspace")
    panes = []
    for w_id, t_id, p_id, p in all_panes(s):
        if wid and w_id != wid: continue
        panes.append({"pane_id": p_id, "tab_id": t_id, "workspace_id": w_id,
                      "label": p["label"], "agent_status": p["agent_status"]})
    emit({"panes": panes})

if cmd == "pane process-info":
    # Report the pane's FOREGROUND from the pid `pane run` recorded (below): a still-running pid ⇒ that
    # command is the live foreground (the deadeyes 'claude' sleeper); a gone pid ⇒ a bare shell. shell_pid
    # is kept DISTINCT from the fg pid so the driver's "drop the shell" filter never discards the fg. A
    # gone pane ⇒ no process_info at all — the HERD-135 'missing' signal.
    pane = opt("--pane")
    for _, _, p_id, p in all_panes(s):
        if p_id == pane:
            fg_pid = p.get("fg_pid"); fg_cmd = p.get("fg_cmd", "")
            alive = False
            if isinstance(fg_pid, int):
                try: os.kill(fg_pid, 0); alive = True
                except OSError: alive = False
            # claude-as-ROOT panes (agent start -- claude): the foreground process IS the pane shell, so
            # shell_pid == fg_pid — the exact shape that fooled the pre-fix classifier. Otherwise shell_pid
            # is a DISTINCT wrapper (fg is a child of the pane shell), the deadeyes shell+child model.
            if p.get("fg_root") and isinstance(fg_pid, int):
                shell = fg_pid
            else:
                shell = (fg_pid + 1000000) if isinstance(fg_pid, int) else 4242
            if alive:
                emit({"process_info": {"shell_pid": shell, "foreground_process_group_id": fg_pid,
                                       "foreground_processes": [{"pid": fg_pid, "cmdline": fg_cmd}]}})
            else:
                emit({"process_info": {"shell_pid": shell, "foreground_process_group_id": shell,
                                       "foreground_processes": []}})
    emit({})

if cmd == "pane rename":
    for _, _, p_id, p in all_panes(s):
        if p_id == args[2]: p["label"] = args[3]
    save(s); emit({"type": "ok"})

if cmd == "pane report-agent":
    # herdr 0.7.5 renamed the custom-status word to --message (issue #514); model BOTH so the
    # scenario's new-first/old-fallback report helper lands the word on either CLI generation.
    pane = args[2]; custom = opt("--custom-status") or opt("--message"); st = opt("--state", "unknown")
    for _, _, p_id, p in all_panes(s):
        if p_id == pane:
            p["agent"] = opt("--agent"); p["agent_status"] = custom if custom else st
    save(s); emit({"type": "ok"})

if cmd == "pane run":
    # Model a foreground process so `pane process-info` (above) can report live/gone foreground exactly
    # as a real pane would (the dead-vs-missing eyes flow). Launch the command DETACHED in its OWN
    # session (pgid == pid) and record the pid in pane state: a resident command (the deadeyes 'claude'
    # sleeper) stays alive until the scenario kills its process GROUP; a printf exits at once ⇒ gone.
    pane = args[2] if len(args) > 2 else ""
    runcmd = args[3] if len(args) > 3 else ""
    if pane and runcmd:
        import subprocess
        for _, _, p_id, p in all_panes(s):
            if p_id == pane:
                try:
                    proc = subprocess.Popen(["/bin/sh", "-c", runcmd], start_new_session=True,
                                            stdin=subprocess.DEVNULL,
                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    p["fg_pid"] = proc.pid; p["fg_cmd"] = runcmd
                    # `exec <cmd>` replaces the pane's shell, so the command BECOMES the pane root
                    # (shell_pid == its pid) — the claude-as-root shape the scenario stands up
                    # CLI-agnostically since issue #514 (0.7.5 agent start can't launch a stub).
                    if runcmd.strip().startswith("exec "):
                        p["fg_root"] = True
                    save(s)
                except Exception:
                    pass
    sys.exit(0)

if cmd == "agent start":
    # Model the lane's `herdr agent start … --tab <t> --split <d> -- <cmd>`: create a NEW pane in the
    # tab whose ROOT process is <cmd> (claude launched directly, no wrapping shell — so process-info
    # reports shell_pid == that pid via the fg_root flag). Background it detached so it stays 'alive'
    # until the scenario kills its process GROUP.
    name = args[2] if len(args) > 2 else ""
    tab = opt("--tab")
    runcmd = ""
    if "--" in args:
        i = args.index("--"); runcmd = " ".join(args[i+1:])
    for wid, w in s["workspaces"].items():
        if tab and tab in w["tabs"]:
            pid = nid(s, wid + ":p")
            p = {"label": None, "agent": name, "agent_status": "idle", "fg_root": True}
            if runcmd:
                import subprocess
                try:
                    proc = subprocess.Popen(["/bin/sh", "-c", runcmd], start_new_session=True,
                                            stdin=subprocess.DEVNULL,
                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    p["fg_pid"] = proc.pid; p["fg_cmd"] = runcmd
                except Exception:
                    pass
            w["tabs"][tab]["panes"][pid] = p
            save(s)
            emit({"agent": {"pane_id": pid, "tab_id": tab, "workspace_id": wid, "name": name}})
    emit({})

if cmd == "pane read":
    print("rp stub builder: done"); sys.exit(0)

if cmd == "pane send-keys":
    # HERD-186: accept send-keys (Enter submit after pane run). No state change here — the scenario's
    # wake-shim flips agent status via report-agent after Enter, modelling a real agent reacting.
    sys.exit(0)

if cmd == "agent list":
    agents = []
    for w_id, t_id, p_id, p in all_panes(s):
        if p.get("agent"):
            # Emit both `name` (lane-started identity) and `agent` (report-agent label) so the
            # shipped _find_builder_pane_id_any / _agent_status matchers resolve the builder.
            agents.append({"name": p["agent"], "agent": p["agent"], "agent_status": p["agent_status"],
                           "pane_id": p_id, "tab_id": t_id, "workspace_id": w_id})
    emit({"agents": agents})

sys.exit(0)
PY
HERDR
chmod +x "$BIN/herdr"
export HERDR_STATE="$STATE"

# ── (B) STUB-HERDR PATH — full flow against the fake herdr; everything passes ─────
ARTR="$T/run"
PATH="$BIN:$PATH" SANDBOX_NO_SCREENSHOT=1 \
  bash "$SCENARIO" --artifacts "$ARTR" --label rp-test >"$T/run.out" 2>&1 \
  || fail "(B) stub-herdr run exited non-zero"$'\n'"$(cat "$T/run.out")"
SCR="$ARTR/scorecard.json"
[ -f "$SCR" ] || fail "(B) scorecard.json not emitted at $SCR"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCR" || fail "(B) run scorecard not valid JSON"
[ "$(sc "$SCR" scenario)" = "stub-real-panes-e2e" ] || fail "(B) unexpected scenario name"
[ "$(sc "$SCR" result)" = "pass" ]                  || fail "(B) result should be pass (got $(sc "$SCR" result))"
[ "$(sc "$SCR" failed)" -eq 0 ]                     || fail "(B) failed should be 0"
[ "$(sc "$SCR" herdr_available)" = "True" ]         || fail "(B) herdr_available should be True with stub herdr"
# The pane/tab/agent checkpoints all pass — including the HERD-135 role-label + alive/dead/missing eyes.
# The stub models `pane process-info` off a detached process (recorded by `pane run` for the deadeyes
# kill flow, and by `agent start` for the claude-as-ROOT pane where shell_pid == the claude pid — the
# PR #260 false-death shape). alive→dead on kill, →missing on pane removal, and claude-as-root ⇒ alive.
for cpn in workspace_created control_room builder_tab pane_labels_on_spawn agent_idle agent_working \
           agent_done builder_agent_alive_claude_root builder_retask_wakes_on_enter builder_agent_dead \
           builder_refix_escalates_on_dead builder_agent_missing context_guard_refuses_real_teardown teardown_clean; do
  [ "$(cp_status "$SCR" "$cpn")" = "pass" ] || fail "(B) checkpoint $cpn not pass"
done
# HERD-310: the context-guard checkpoint proves a WORKTREE-context herd_teardown_slug against the live
# control room is REFUSED (zero real closes + a journaled control_pane_mutation_refused).
[ "$(cp_status "$SCR" context_guard_refuses_real_teardown)" = "pass" ] \
  || fail "(B) context_guard_refuses_real_teardown must pass"
# The observed transitions are exactly idle → working → done.
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["agent_transitions"])' "$SCR")" = "['idle', 'working', 'done']" ] \
  || fail "(B) agent_transitions should be idle,working,done"
# Two tabs (control room + builder) and eight panes (watcher, backlog, builder, the reviewer split for
# the reviewer-pane-lifecycle checkpoint, the two resolver splits for the HERD-280 retire/escalate legs,
# the health split for the HERD-313 retire-on-outcome checkpoint, and the claude-as-root pane for the
# alive checkpoint). All but the ESCALATE resolver pane are closed again within their own steps — that
# one stays open BY DESIGN and goes with the workspace at teardown.
[ "$(sc "$SCR" tabs_created)" -eq 2 ]  || fail "(B) tabs_created should be 2 (got $(sc "$SCR" tabs_created))"
[ "$(sc "$SCR" panes_created)" -eq 8 ] || fail "(B) panes_created should be 8 (got $(sc "$SCR" panes_created))"
# The reviewer pane is retired on verdict consumption (HERD-113).
[ "$(cp_status "$SCR" reviewer_pane_retired_on_verdict)" = "pass" ] || fail "(B) reviewer_pane_retired_on_verdict not pass"
# The resolver pane retires on a consumed DONE and SURVIVES an ESCALATE (HERD-280).
[ "$(cp_status "$SCR" resolver_pane_retired_on_done)" = "pass" ]  || fail "(B) resolver_pane_retired_on_done not pass"
[ "$(cp_status "$SCR" resolver_pane_kept_on_escalate)" = "pass" ] || fail "(B) resolver_pane_kept_on_escalate not pass"
# The disposable health pane retires the moment its suite ends (HERD-313 leg a).
[ "$(cp_status "$SCR" health_pane_retired_on_outcome)" = "pass" ] || fail "(B) health_pane_retired_on_outcome not pass"
# CLEAN TEARDOWN: zero leaked tabs, and the fake herdr's state has no workspaces left behind.
[ "$(sc "$SCR" leaked_tabs)" -eq 0 ] || fail "(B) leaked_tabs must be 0 (got $(sc "$SCR" leaked_tabs))"
LEFT="$(python3 -c 'import json; print(len(json.load(open("'"$STATE"'"))["workspaces"]))')"
[ "$LEFT" -eq 0 ] || fail "(B) stub herdr left $LEFT workspace(s) — teardown did not close the workspace"
echo "PASS (B) stub-herdr full flow: control room + builder + idle→working→done + clean teardown"

# ── (C) SCORECARD SHAPE — sandbox-sim fields plus the real-pane fields ───────────
for k in scenario artifacts_dir repo_dir fixture_sha result passed failed skipped \
         herdr_available workspace_label tabs_created panes_created agent_transitions \
         leaked_tabs pane_captures screenshots checkpoints; do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert sys.argv[2] in d' "$SCR" "$k" \
    || fail "(C) scorecard missing field: $k"
done
echo "PASS (C) scorecard shape (sandbox-sim + real-pane fields)"

# ── (D) HERMETIC — nothing leaked into the real repo tree by either path ─────────
NOW_STATUS="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort || true)"
NEW_ENTRIES="$(comm -13 <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$NOW_STATUS") | grep -v '^$' || true)"
[ -z "$NEW_ENTRIES" ] || fail "(D) scenario leaked into the real repo tree:"$'\n'"$NEW_ENTRIES"
echo "PASS (D) hermetic — no leak into the real repo"

echo "ALL PASS"
