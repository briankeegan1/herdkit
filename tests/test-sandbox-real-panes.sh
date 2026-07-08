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

if cmd == "pane rename":
    for _, _, p_id, p in all_panes(s):
        if p_id == args[2]: p["label"] = args[3]
    save(s); emit({"type": "ok"})

if cmd == "pane report-agent":
    pane = args[2]; custom = opt("--custom-status"); st = opt("--state", "unknown")
    for _, _, p_id, p in all_panes(s):
        if p_id == pane:
            p["agent"] = opt("--agent"); p["agent_status"] = custom if custom else st
    save(s); emit({"type": "ok"})

if cmd == "pane run":
    sys.exit(0)   # no-op: nothing to execute in the stub

if cmd == "pane read":
    print("rp stub builder: done"); sys.exit(0)

if cmd == "agent list":
    agents = []
    for w_id, t_id, p_id, p in all_panes(s):
        if p.get("agent"):
            agents.append({"agent": p["agent"], "agent_status": p["agent_status"],
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
# The pane/tab/agent checkpoints all pass.
for cpn in workspace_created control_room builder_tab agent_idle agent_working agent_done teardown_clean; do
  [ "$(cp_status "$SCR" "$cpn")" = "pass" ] || fail "(B) checkpoint $cpn not pass"
done
# The observed transitions are exactly idle → working → done.
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["agent_transitions"])' "$SCR")" = "['idle', 'working', 'done']" ] \
  || fail "(B) agent_transitions should be idle,working,done"
# Two tabs (control room + builder) and four panes (watcher, backlog, builder, + the reviewer split
# stood up for the reviewer-pane-lifecycle checkpoint, which is then retired on verdict consumption).
[ "$(sc "$SCR" tabs_created)" -eq 2 ]  || fail "(B) tabs_created should be 2 (got $(sc "$SCR" tabs_created))"
[ "$(sc "$SCR" panes_created)" -eq 4 ] || fail "(B) panes_created should be 4 (got $(sc "$SCR" panes_created))"
# The reviewer pane is retired on verdict consumption (HERD-113).
[ "$(cp_status "$SCR" reviewer_pane_retired_on_verdict)" = "pass" ] || fail "(B) reviewer_pane_retired_on_verdict not pass"
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
