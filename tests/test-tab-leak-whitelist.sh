#!/usr/bin/env bash
# test-tab-leak-whitelist.sh — hermetic test of the tab-leak-guard's ENGINE-LABEL WHITELIST (HERD-51).
#
# The guard in .herd/healthcheck.project.sh snapshots the "orphan" tabs (agent_status not in
# idle/working) before and after the suite and fails on a net increase. BEFORE HERD-51 that status
# test alone counted a legitimate ENGINE tab — a resolve·<slug> conflict-resolver, a scribe-* drainer,
# a research/researcher drainer, or a control-room pane (herd-watch*/backlog*/coordinator*) — spawned
# CONCURRENTLY by unrelated activity and caught mid-spawn in an 'unknown'/'blocked' state as a net-new
# orphan → FALSE-RED on an innocent PR (three real false-reds, incl. PR #162's "resolve·codemap-
# freshness"). The fix EXCLUDES tabs whose label matches a known-engine whitelist from the orphan set,
# symmetrically in both snapshots, WITHOUT weakening the guard: a genuinely suite-leaked, agent-less
# tab (label NOT matching the whitelist, e.g. herd-review's standalone review·<slug>) must still red.
#
# The _hk_orphans / delta functions below MIRROR .herd/healthcheck.project.sh and are kept in
# LOCKSTEP with it. herdr is stubbed (NETWORK-FREE) to return fixture JSON. Run:
#     bash tests/test-tab-leak-whitelist.sh
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required to run this test" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── Stub herdr on PATH: 'tab list' cats $HERDR_TABLIST ───────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "tab list") cat "$HERDR_TABLIST" 2>/dev/null ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"
export HERDR_TABLIST="$T/tablist.json"

# ── Mirrored guard logic (LOCKSTEP with .herd/healthcheck.project.sh, incl. the ENGINE whitelist) ─
_hk_orphans() {
  command -v herdr >/dev/null 2>&1 || return 0
  herdr tab list 2>/dev/null | WSID="${1:-}" python3 -c '
import sys, json, os, re
_ENGINE = re.compile(r"^(scribe-|resolve·|research|herd-watch|backlog|coordinator)")
try:
    tabs = (json.load(sys.stdin).get("result") or {}).get("tabs") or []
    wsid = os.environ.get("WSID", "")
    if wsid:
        tabs = [t for t in tabs if str(t.get("workspace_id", "")) == wsid]
    orphans = [t for t in tabs
               if str(t.get("agent_status", "")) not in ("idle", "working")
               and not _ENGINE.match(str(t.get("label", "")))]
    print("orphan-tabs:%d" % len(orphans))
    print("orphan-panes:%d" % sum(int(t.get("pane_count", 0) or 0) for t in orphans))
    for lbl in sorted(str(t.get("label", "")) for t in orphans):
        print("orphan-label:" + lbl)
except Exception:
    pass
' 2>/dev/null || true
}

# Returns non-empty (a "trip") when after has MORE orphan tabs/panes than before.
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

# guard_trips BEFORE_JSON AFTER_JSON -> exits 0 if the guard TRIPS, 1 if clean. (No workspace scoping
# here — that axis is covered by test-tab-leak-scope.sh; this test isolates the label whitelist.)
guard_trips() {
  local beforej="$1" afterj="$2"
  printf '%s' "$beforej" > "$HERDR_TABLIST"; local b; b="$(_hk_orphans "")"
  printf '%s' "$afterj"  > "$HERDR_TABLIST"; local a; a="$(_hk_orphans "")"
  [ -n "$(_hk_delta "$b" "$a")" ]
}

# ── Fixtures ─────────────────────────────────────────────────────────────────────────────────────
# BEFORE: a steady mix — an agent-backed working builder + a pre-existing agent-less orphan present in
# BOTH snapshots (so it nets to zero on its own).
BEFORE='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"working","label":"feat-widget","pane_count":3,"tab_id":"t1","workspace_id":"wE"},
  {"agent_status":"unknown","label":"review·preexisting","pane_count":2,"tab_id":"t2","workspace_id":"wE"}]}}'

# AFTER_ENGINE: an engine conflict-resolver tab spawned CONCURRENTLY during the suite window, caught
# mid-spawn in an 'unknown' state. Its label matches the whitelist → must NOT trip the guard. This is
# the exact HERD-51 false-red (PR #162's "resolve·codemap-freshness").
AFTER_ENGINE='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"working","label":"feat-widget","pane_count":3,"tab_id":"t1","workspace_id":"wE"},
  {"agent_status":"unknown","label":"review·preexisting","pane_count":2,"tab_id":"t2","workspace_id":"wE"},
  {"agent_status":"unknown","label":"resolve·codemap-freshness","pane_count":2,"tab_id":"t3","workspace_id":"wE"}]}}'

# AFTER_LEAK: a genuine suite leak — a NEW agent-less, NON-engine 'review·<slug>' orphan tab. Must trip.
AFTER_LEAK='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"working","label":"feat-widget","pane_count":3,"tab_id":"t1","workspace_id":"wE"},
  {"agent_status":"unknown","label":"review·preexisting","pane_count":2,"tab_id":"t2","workspace_id":"wE"},
  {"agent_status":"unknown","label":"review·leaky-test","pane_count":2,"tab_id":"t9","workspace_id":"wE"}]}}'

# ── Assertions ───────────────────────────────────────────────────────────────────────────────────

# 1. WHITELIST: a concurrent engine tab (resolve·<slug>, 'unknown') appearing during the suite does
#    NOT trip the guard. This is the HERD-51 fix.
if guard_trips "$BEFORE" "$AFTER_ENGINE"; then
  fail "1: concurrent engine tab 'resolve·codemap-freshness' tripped the guard — should be whitelisted"
fi
ok

# 2. REAL LEAK STILL REDS: a genuinely orphaned NON-engine tab still trips the guard.
if guard_trips "$BEFORE" "$AFTER_LEAK"; then
  ok
else
  fail "2: a real non-engine leak (review·leaky-test) did NOT trip the guard — the guard was weakened"
fi

# 3. EVERY whitelisted prefix is honored: each known-engine label, appearing net-new in a non-idle
#    ('blocked') state, is excluded from the orphan set and does not trip. A control non-engine label
#    in the SAME shape DOES trip — proving it is the label, not the status, that spares the engine tab.
for lbl in "scribe-drain-42" "resolve·some-conflict" "research-index" "researcher-web" \
           "herd-watch-p0" "backlog-autoreconcile" "coordinator-herdkit"; do
  after='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
    {"agent_status":"working","label":"feat-widget","pane_count":3,"tab_id":"t1","workspace_id":"wE"},
    {"agent_status":"unknown","label":"review·preexisting","pane_count":2,"tab_id":"t2","workspace_id":"wE"},
    {"agent_status":"blocked","label":"'"$lbl"'","pane_count":2,"tab_id":"tX","workspace_id":"wE"}]}}'
  if guard_trips "$BEFORE" "$after"; then
    fail "3: whitelisted engine label '$lbl' tripped the guard"
  fi
done
ok

# 3b. Control: a non-engine tab in the identical shape/state DOES trip — the whitelist is label-driven.
control='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"working","label":"feat-widget","pane_count":3,"tab_id":"t1","workspace_id":"wE"},
  {"agent_status":"unknown","label":"review·preexisting","pane_count":2,"tab_id":"t2","workspace_id":"wE"},
  {"agent_status":"blocked","label":"stray-leaked-tab","pane_count":2,"tab_id":"tX","workspace_id":"wE"}]}}'
if guard_trips "$BEFORE" "$control"; then ok; else
  fail "3b: a non-engine 'stray-leaked-tab' in blocked state did NOT trip — control invalid"
fi

# 4. Steady state: identical before/after -> clean.
if guard_trips "$BEFORE" "$BEFORE"; then
  fail "4: guard tripped with identical before/after snapshots"
fi
ok

echo "ALL PASS ($pass checks)"
