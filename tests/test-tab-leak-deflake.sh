#!/usr/bin/env bash
# test-tab-leak-deflake.sh — hermetic test of the tab-leak-guard's DEFLAKE mitigations (HERD-93).
#
# The guard in .herd/healthcheck.project.sh snapshots the "orphan" tabs (agent_status not in
# idle/working, label not on the engine whitelist) before and after the suite and fails on a net
# increase. On a busy control room, normal churn — builder/review·/resolve· tabs the engine spawns
# and reaps, and tabs flipping state mid-suite — was the last recurring FALSE-RED (named on both
# recent FLAKY gates, 2026-07-07): a wasted full-suite run + retry on most busy-day PRs. HERD-93
# adds two mitigations that kill it WITHOUT weakening the guard (no false-green):
#
#   (a) .herd-tabs REGISTRATION WHITELIST — every engine-minted tab is recorded by tab_id in
#       $WORKTREES_DIR/.herd-tabs. _hk_orphans() drops any tab whose tab_id is registered there, so a
#       legit watcher-spawned review·<slug> tab (NOT covered by the label whitelist) no longer trips.
#       EXACT tab_id match: a hermetic test's escaped tab is never engine-registered, so it still reds.
#   (b) SETTLE-RETRY — a leak on the first post-suite snapshot may be transient churn. The guard
#       re-snapshots after a settle window and reds ONLY if the leak is STILL present. Transient churn
#       clears; a genuinely leaked, agent-less tab persists and re-trips.
#
# The _hk_regtabs / _hk_orphans / _hk_leak_delta functions + the settle verdict below MIRROR
# .herd/healthcheck.project.sh and are kept in LOCKSTEP with it. herdr is stubbed (NETWORK-FREE) to
# return fixture JSON; the settle delay is skipped (we drive the two after-snapshots directly). Run:
#     bash tests/test-tab-leak-deflake.sh
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

# ── Fake project with a .herd/config pointing WORKTREES_DIR at a registry that whitelists ONE tab ──
# The engine records its minted tabs as '<label> <tab_id> <kind>' rows; only tab_id 'wE:tREG' (a
# watcher-spawned review·<slug>) is registered here, so ONLY that tab is dropped by the registration
# whitelist — every other orphan tab_id below is NOT registered and remains a real orphan candidate.
mkdir -p "$T/proj/.herd" "$T/trees"
printf 'WORKTREES_DIR="%s/trees"\n' "$T" > "$T/proj/.herd/config"
printf 'review·churn-slug wE:tREG review\ndriver-start-agent wE:tB0 builder\n' > "$T/trees/.herd-tabs"
cd "$T/proj"

# ── Mirrored guard logic (LOCKSTEP with .herd/healthcheck.project.sh) ─────────────────────────────
_hk_regtabs() {
  local _tree=""
  [ -f .herd/config ] && _tree="$(. .herd/config 2>/dev/null && printf '%s' "${WORKTREES_DIR:-}")"
  [ -n "$_tree" ] && [ -f "$_tree/.herd-tabs" ] || return 0
  awk 'NF>=2 {print $2}' "$_tree/.herd-tabs" 2>/dev/null || true
}

_hk_orphans() {
  command -v herdr >/dev/null 2>&1 || return 0
  herdr tab list 2>/dev/null | WSID="${1:-}" REGTABS="$(_hk_regtabs)" python3 -c '
import sys, json, os, re
_ENGINE = re.compile(r"^(scribe-|resolve·|research|herd-watch|backlog|coordinator)")
_REGTABS = set(filter(None, (os.environ.get("REGTABS", "") or "").split()))
try:
    tabs = (json.load(sys.stdin).get("result") or {}).get("tabs") or []
    wsid = os.environ.get("WSID", "")
    if wsid:
        tabs = [t for t in tabs if str(t.get("workspace_id", "")) == wsid]
    orphans = [t for t in tabs
               if str(t.get("agent_status", "")) not in ("idle", "working")
               and not _ENGINE.match(str(t.get("label", "")))
               and str(t.get("tab_id", "")) not in _REGTABS]
    print("orphan-tabs:%d" % len(orphans))
    print("orphan-panes:%d" % sum(int(t.get("pane_count", 0) or 0) for t in orphans))
    for lbl in sorted(str(t.get("label", "")) for t in orphans):
        print("orphan-label:" + lbl)
except Exception:
    pass
' 2>/dev/null || true
}

_hk_leak_delta() {
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

# guard_reds BEFORE AFTER1 AFTER2 -> exits 0 if the guard REDS (leak survives), 1 if clean.
# Mirrors the settle-retry verdict: check the delta on AFTER1; only if it trips, re-snapshot AFTER2
# (the post-settle snapshot) and keep the red only if the leak is STILL present. The real settle SLEEP
# is skipped here — we drive the two after-snapshots directly, which is what a 0s settle window does.
guard_reds() {
  local bj="$1" a1="$2" a2="$3"
  printf '%s' "$bj" > "$HERDR_TABLIST"; local b; b="$(_hk_orphans "")"
  printf '%s' "$a1" > "$HERDR_TABLIST"; local a; a="$(_hk_orphans "")"
  local leak; leak="$(_hk_leak_delta "$b" "$a")"
  if [ -n "$leak" ]; then
    printf '%s' "$a2" > "$HERDR_TABLIST"; a="$(_hk_orphans "")"
    leak="$(_hk_leak_delta "$b" "$a")"
  fi
  [ -n "$leak" ]
}

# ── Fixtures ─────────────────────────────────────────────────────────────────────────────────────
# BEFORE: an agent-backed working builder + a pre-existing agent-less orphan present in EVERY snapshot
# (so it nets to zero on its own and never itself trips the guard).
BEFORE='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"working","label":"feat-widget","pane_count":3,"tab_id":"t1","workspace_id":"wE"},
  {"agent_status":"unknown","label":"stray-preexisting","pane_count":2,"tab_id":"t2","workspace_id":"wE"}]}}'

# AFTER_REGISTERED: a watcher-spawned review·<slug> tab (tab_id wE:tREG, REGISTERED in .herd-tabs)
# appears mid-suite in 'unknown'. The label whitelist does NOT cover 'review·', but the registration
# whitelist drops it by tab_id → must NOT red. This is the exact HERD-93 residual false-red.
AFTER_REGISTERED='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"working","label":"feat-widget","pane_count":3,"tab_id":"t1","workspace_id":"wE"},
  {"agent_status":"unknown","label":"stray-preexisting","pane_count":2,"tab_id":"t2","workspace_id":"wE"},
  {"agent_status":"unknown","label":"review·churn-slug","pane_count":2,"tab_id":"wE:tREG","workspace_id":"wE"}]}}'

# AFTER_UNREGISTERED_LEAK: a NON-engine, NON-registered agent-less tab (tab_id wE:tLEAK) — a hermetic
# test's escaped tab. Not on the label whitelist, not in .herd-tabs → a real orphan. Used as both
# after1 AND after2 (it PERSISTS across the settle window) → must RED (no false-green).
AFTER_LEAK='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"working","label":"feat-widget","pane_count":3,"tab_id":"t1","workspace_id":"wE"},
  {"agent_status":"unknown","label":"stray-preexisting","pane_count":2,"tab_id":"t2","workspace_id":"wE"},
  {"agent_status":"unknown","label":"leaky-test-tab","pane_count":2,"tab_id":"wE:tLEAK","workspace_id":"wE"}]}}'

# ── Assertions ───────────────────────────────────────────────────────────────────────────────────

# 1. REGISTRATION WHITELIST: a registered review·<slug> tab appearing mid-suite does NOT red the guard
#    (even on the first snapshot, before any settle). This is the HERD-93 (a) fix.
if guard_reds "$BEFORE" "$AFTER_REGISTERED" "$AFTER_REGISTERED"; then
  fail "1: a registered review·<slug> tab (wE:tREG, in .herd-tabs) red the guard — should be whitelisted"
fi
ok

# 2. REGISTRATION no-false-green: a NON-registered, non-engine orphan that PERSISTS still reds.
if guard_reds "$BEFORE" "$AFTER_LEAK" "$AFTER_LEAK"; then ok; else
  fail "2: a non-registered persistent leak (wE:tLEAK) did NOT red — the registration whitelist over-fired"
fi

# 3. SETTLE-RETRY: a leak seen on the FIRST snapshot but GONE after settle (transient churn) does NOT
#    red — the post-settle snapshot is back to BEFORE. This is the HERD-93 (b) fix.
if guard_reds "$BEFORE" "$AFTER_LEAK" "$BEFORE"; then
  fail "3: transient churn (present in after1, cleared by after2) red the guard — settle-retry failed"
fi
ok

# 4. SETTLE-RETRY no-false-green: a leak present in BOTH the first and post-settle snapshots (a stable,
#    genuinely leaked agent-less tab) still reds. The settle window must not swallow a real leak.
if guard_reds "$BEFORE" "$AFTER_LEAK" "$AFTER_LEAK"; then ok; else
  fail "4: a STABLE leak surviving the settle window did NOT red — settle-retry weakened the guard"
fi

# 5. Combined: transient churn on the first snapshot that SETTLES to a registered engine tab (both
#    mitigations in play) is clean.
if guard_reds "$BEFORE" "$AFTER_LEAK" "$AFTER_REGISTERED"; then
  fail "5: churn settling to a registered engine tab red the guard — combined mitigations failed"
fi
ok

# 6. Steady state: identical before/after -> clean, no settle needed.
if guard_reds "$BEFORE" "$BEFORE" "$BEFORE"; then
  fail "6: guard red with identical before/after snapshots"
fi
ok

echo "ALL PASS ($pass checks)"
