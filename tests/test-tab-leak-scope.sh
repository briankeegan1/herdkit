#!/usr/bin/env bash
# test-tab-leak-scope.sh — hermetic test of the tab-leak-guard's WORKSPACE SCOPING (issue #78).
#
# The guard in .herd/healthcheck.project.sh snapshots the "orphan" tabs (agent_status not in
# idle/working) before and after the suite and fails on a net increase. BEFORE #78 the scan ran
# 'herdr tab list' UNSCOPED across ALL herdr workspaces, so a tab in a SIBLING project's workspace
# (e.g. northstar's coordinator, workspace wC) that transiently went non-idle during the healthcheck
# window was miscounted as a new orphan → FALSE-RED on an innocent PR. The fix scopes the scan to
# THIS project's OWN workspace (WORKSPACE_NAME → workspace_id).
#
# These functions MIRROR _hk_workspace_id / _hk_orphans / the delta compare in
# .herd/healthcheck.project.sh and are kept in LOCKSTEP with them. herdr is stubbed (NETWORK-FREE)
# to return fixture JSON with tabs across TWO workspaces + non-idle sibling builder tabs. Run:
#     bash tests/test-tab-leak-scope.sh
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required to run this test" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── Stub herdr on PATH: 'tab list' cats $HERDR_TABLIST, 'workspace list' cats $HERDR_WSLIST ──────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "tab list")       cat "$HERDR_TABLIST" 2>/dev/null ;;
  "workspace list") cat "$HERDR_WSLIST"  2>/dev/null ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# Fake project root with a .herd/config naming our workspace — exercises the real config read path.
mkdir -p "$T/proj/.herd"
printf 'WORKSPACE_NAME="herdkit"\n' > "$T/proj/.herd/config"
cd "$T/proj"

# Workspace list: label "herdkit" -> wE, label "northstar" -> wC (constant across the run).
export HERDR_WSLIST="$T/wslist.json"
cat > "$HERDR_WSLIST" <<'EOF'
{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"active_tab_id":"wC:t1G","agent_status":"idle","focused":false,"label":"northstar","number":1,"pane_count":5,"tab_count":2,"workspace_id":"wC"},{"active_tab_id":"wE:t1","agent_status":"done","focused":true,"label":"herdkit","number":2,"pane_count":12,"tab_count":5,"workspace_id":"wE"}]}}
EOF
export HERDR_TABLIST="$T/tablist.json"

# ── Mirrored guard logic (LOCKSTEP with .herd/healthcheck.project.sh) ─────────────────────────────
_hk_workspace_id() {
  command -v herdr >/dev/null 2>&1 || return 0
  local _ws=""
  [ -f .herd/config ] && _ws="$(. .herd/config 2>/dev/null && printf '%s' "${WORKSPACE_NAME:-}")"
  [ -n "$_ws" ] || return 0
  herdr workspace list 2>/dev/null | LABEL="$_ws" python3 -c '
import sys, json, os
try:
    wss = (json.load(sys.stdin).get("result") or {}).get("workspaces") or []
    print(next((str(w.get("workspace_id", "")) for w in wss
                if str(w.get("label", "")) == os.environ["LABEL"]), ""), end="")
except Exception:
    pass
' 2>/dev/null || true
}

_hk_orphans() {
  command -v herdr >/dev/null 2>&1 || return 0
  herdr tab list 2>/dev/null | WSID="${1:-}" python3 -c '
import sys, json, os
try:
    tabs = (json.load(sys.stdin).get("result") or {}).get("tabs") or []
    wsid = os.environ.get("WSID", "")
    if wsid:
        tabs = [t for t in tabs if str(t.get("workspace_id", "")) == wsid]
    orphans = [t for t in tabs if str(t.get("agent_status", "")) not in ("idle", "working")]
    print("orphan-tabs:%d" % len(orphans))
    print("orphan-panes:%d" % sum(int(t.get("pane_count", 0) or 0) for t in orphans))
    for lbl in sorted(str(t.get("label", "")) for t in orphans):
        print("orphan-label:" + lbl)
except Exception:
    pass
' 2>/dev/null || true
}

# Returns non-empty (a "trip") when after has MORE orphan tabs/panes than before — mirrors the
# healthcheck's verdict step.
_hk_delta() {
  BEF="$1" AFT="$2" python3 -c '
import os
def parse(s):
    tabs = panes = 0
    for line in s.splitlines():
        if line.startswith("orphan-tabs:"):  tabs  = int(line.split(":",1)[1] or 0)
        elif line.startswith("orphan-panes:"): panes = int(line.split(":",1)[1] or 0)
    return tabs, panes
bt, bp = parse(os.environ["BEF"])
at, ap = parse(os.environ["AFT"])
if at > bt or ap > bp:
    print("orphan tabs %d->%d, orphan panes %d->%d" % (bt, at, bp, ap))
' 2>/dev/null || true
}

# guard_trips WSID BEFORE_JSON AFTER_JSON -> exits 0 if the guard TRIPS, 1 if clean.
guard_trips() {
  local wsid="$1" beforej="$2" afterj="$3"
  printf '%s' "$beforej" > "$HERDR_TABLIST"; local b; b="$(_hk_orphans "$wsid")"
  printf '%s' "$afterj"  > "$HERDR_TABLIST"; local a; a="$(_hk_orphans "$wsid")"
  [ -n "$(_hk_delta "$b" "$a")" ]
}

# ── Fixtures ─────────────────────────────────────────────────────────────────────────────────────
# BEFORE: northstar coordinator (wC) is idle; our workspace (wE) has a working coordinator +
# a working sibling builder + a pre-existing 'done' orphan that is present in BOTH snapshots.
BEFORE='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"idle","label":"coordinator-northstar","pane_count":3,"tab_id":"wC:t1G","workspace_id":"wC"},
  {"agent_status":"working","label":"coordinator-herdkit","pane_count":3,"tab_id":"wE:t1","workspace_id":"wE"},
  {"agent_status":"working","label":"fleet-coordinator-p0","pane_count":2,"tab_id":"wE:tB0","workspace_id":"wE"},
  {"agent_status":"done","label":"backlog-autoreconcile","pane_count":3,"tab_id":"wE:tAQ","workspace_id":"wE"}]}}'

# AFTER_SIBLING: the ONLY change is the northstar coordinator (wC) going non-idle ("done"), plus the
# sibling builder churning working->done in OUR workspace... no — keep our workspace identical here so
# the sole delta is cross-workspace. This is the exact issue #78 repro.
AFTER_SIBLING='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"done","label":"coordinator-northstar","pane_count":3,"tab_id":"wC:t1G","workspace_id":"wC"},
  {"agent_status":"working","label":"coordinator-herdkit","pane_count":3,"tab_id":"wE:t1","workspace_id":"wE"},
  {"agent_status":"working","label":"fleet-coordinator-p0","pane_count":2,"tab_id":"wE:tB0","workspace_id":"wE"},
  {"agent_status":"done","label":"backlog-autoreconcile","pane_count":3,"tab_id":"wE:tAQ","workspace_id":"wE"}]}}'

# AFTER_LEAK: a genuine leak INTO OUR workspace — a new agent-less 'review·' orphan tab appears in wE.
AFTER_LEAK='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"idle","label":"coordinator-northstar","pane_count":3,"tab_id":"wC:t1G","workspace_id":"wC"},
  {"agent_status":"working","label":"coordinator-herdkit","pane_count":3,"tab_id":"wE:t1","workspace_id":"wE"},
  {"agent_status":"working","label":"fleet-coordinator-p0","pane_count":2,"tab_id":"wE:tB0","workspace_id":"wE"},
  {"agent_status":"done","label":"backlog-autoreconcile","pane_count":3,"tab_id":"wE:tAQ","workspace_id":"wE"},
  {"agent_status":"unknown","label":"review·leaky-test","pane_count":2,"tab_id":"wE:tZ9","workspace_id":"wE"}]}}'

# ── Assertions ───────────────────────────────────────────────────────────────────────────────────

# 0. Workspace resolution: WORKSPACE_NAME=herdkit -> wE.
[ "$(_hk_workspace_id)" = "wE" ] || fail "0: _hk_workspace_id did not resolve herdkit -> wE (got '$(_hk_workspace_id)')"
ok

WSID="$(_hk_workspace_id)"

# 1. SCOPED: a sibling project's tab (wC) going non-idle does NOT trip the guard for our workspace.
if guard_trips "$WSID" "$BEFORE" "$AFTER_SIBLING"; then
  fail "1: cross-workspace (northstar/wC) orphan tripped the guard — should be ignored when scoped to wE"
fi
ok

# 2. UNSCOPED (pre-#78 behaviour) WOULD trip on that same change — proves the bug the scoping fixes.
if guard_trips "" "$BEFORE" "$AFTER_SIBLING"; then
  ok
else
  fail "2: unscoped scan should have tripped on the northstar orphan (regression: the bug is not reproduced)"
fi

# 3. SCOPED: a genuine same-project, same-workspace (wE) leak DOES trip the guard.
if guard_trips "$WSID" "$BEFORE" "$AFTER_LEAK"; then
  ok
else
  fail "3: a real leak into OUR workspace (wE review·leaky-test) did NOT trip the guard"
fi

# 4. SCOPED steady state: no change at all -> clean.
if guard_trips "$WSID" "$BEFORE" "$BEFORE"; then
  fail "4: guard tripped with identical before/after snapshots"
fi
ok

echo "ALL PASS ($pass checks)"
