#!/usr/bin/env bash
# test-tab-leak-worktree-whitelist.sh — hermetic test of the tab-leak-guard's WORKTREE-SLUG whitelist
# (HERD-115 — mitigation (c) in .herd/healthcheck.project.sh).
#
# THE BUG: the .herd-tabs REGISTRATION whitelist (HERD-93, mitigation (a)) killed the false-red for the
# IN-TAB run, but NOT for the run the WATCHER invokes against a live builder worktree, where the
# .herd-tabs registry is not always resolvable at snapshot time. In that path an in-flight builder's OWN
# tab — whose LABEL is its worktree slug — flips out of idle/working mid-suite and is counted as a
# net-new orphan. Every watcher-side healthcheck for PRs #217/#218/#219 (2026-07-07) hit exactly this,
# reddening attempt=1 with "new: <the PR's own builder tab>" then settling FLAKY on retry.
#
# THE FIX: derive an ADDITIONAL whitelist from the LIVE worktree slugs ('git worktree list', basename
# of each) at suite start — INVOCATION-ORIGIN INDEPENDENT, since every worktree shares one .git and
# lists them all — and drop any tab whose LABEL matches a live slug. A FOREIGN leaked tab carries no
# live-worktree label, so it STILL reds (no false-green — asserted below).
#
# The _hk_worktree_slugs / _hk_orphans / _hk_leak_delta functions below MIRROR
# .herd/healthcheck.project.sh and are kept in LOCKSTEP with it. Both herdr AND git are stubbed
# (NETWORK-FREE): 'git worktree list --porcelain' returns fixture worktrees, 'herdr tab list' returns
# fixture JSON. Run:  bash tests/test-tab-leak-worktree-whitelist.sh
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required to run this test" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── Stub herdr AND git on PATH ────────────────────────────────────────────────────────────────────
# herdr 'tab list' cats $HERDR_TABLIST; git 'worktree list --porcelain' cats $GIT_WORKTREES. Both are
# byte-for-byte the shapes the real commands emit, so the mirrored helpers exercise the real parse path.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "tab list") cat "$HERDR_TABLIST" 2>/dev/null ;;
  *) exit 0 ;;
esac
EOF
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-} ${3:-}" in
  "worktree list --porcelain") cat "$GIT_WORKTREES" 2>/dev/null ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/herdr" "$BIN/git"
export PATH="$BIN:$PATH"
export HERDR_TABLIST="$T/tablist.json"
export GIT_WORKTREES="$T/worktrees.txt"

# A fake project. WORKTREES_DIR points at an EMPTY .herd-tabs registry — this reproduces the WATCHER
# PATH where the HERD-93 registration whitelist can NOT cover the builder's own tab, isolating the
# HERD-115 worktree-slug whitelist as the sole thing that keeps the builder's own tab from reddening.
mkdir -p "$T/proj/.herd" "$T/trees"
printf 'WORKTREES_DIR="%s/trees"\n' "$T" > "$T/proj/.herd/config"
: > "$T/trees/.herd-tabs"
cd "$T/proj"

# The live worktrees: the main checkout + two in-flight builder worktrees. Their basenames
# (feat-widget, tab-leak-guard-round2) are the slugs that key the builders' tab LABELS. Emitted in
# 'git worktree list --porcelain' shape.
cat > "$GIT_WORKTREES" <<EOF
worktree /Users/dev/source/herdkit
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree /Users/dev/source/herdkit-trees/feat-widget
HEAD 2222222222222222222222222222222222222222
branch refs/heads/feat/feat-widget

worktree /Users/dev/source/herdkit-trees/tab-leak-guard-round2
HEAD 3333333333333333333333333333333333333333
branch refs/heads/feat/tab-leak-guard-round2
EOF

# ── Mirrored guard logic (LOCKSTEP with .herd/healthcheck.project.sh) ─────────────────────────────
_hk_worktree_slugs() {
  command -v git >/dev/null 2>&1 || return 0
  git worktree list --porcelain 2>/dev/null | python3 -c '
import sys, os
for line in sys.stdin:
    if line.startswith("worktree "):
        p = line[len("worktree "):].strip()
        if p:
            print(os.path.basename(p))
' 2>/dev/null || true
}

_hk_regtabs() {
  local _tree=""
  [ -f .herd/config ] && _tree="$(. .herd/config 2>/dev/null && printf '%s' "${WORKTREES_DIR:-}")"
  [ -n "$_tree" ] && [ -f "$_tree/.herd-tabs" ] || return 0
  awk 'NF>=2 {print $2}' "$_tree/.herd-tabs" 2>/dev/null || true
}

_hk_orphans() {
  command -v herdr >/dev/null 2>&1 || return 0
  herdr tab list 2>/dev/null | WSID="${1:-}" REGTABS="$(_hk_regtabs)" WLSLUGS="${2:-}" python3 -c '
import sys, json, os, re
_ENGINE = re.compile(r"^(scribe-|resolve·|research|herd-watch|backlog|coordinator)")
_REGTABS = set(filter(None, (os.environ.get("REGTABS", "") or "").split()))
_WLSLUGS = set(filter(None, (os.environ.get("WLSLUGS", "") or "").splitlines()))
try:
    tabs = (json.load(sys.stdin).get("result") or {}).get("tabs") or []
    wsid = os.environ.get("WSID", "")
    if wsid:
        tabs = [t for t in tabs if str(t.get("workspace_id", "")) == wsid]
    orphans = [t for t in tabs
               if str(t.get("agent_status", "")) not in ("idle", "working")
               and not _ENGINE.match(str(t.get("label", "")))
               and str(t.get("tab_id", "")) not in _REGTABS
               and str(t.get("label", "")) not in _WLSLUGS]
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

# guard_reds BEFORE AFTER1 AFTER2 [WL] -> exits 0 if the guard REDS (leak survives), 1 if clean.
# Mirrors the settle-retry verdict: the worktree-slug whitelist is resolved ONCE at suite start (as in
# the real script) and reused for every snapshot. WL overrides the whitelist for the fail-soft test
# (pass "" to model git-absent / not-a-checkout); defaults to the live 'git worktree list' slugs.
guard_reds() {
  local bj="$1" a1="$2" a2="$3"
  local wl; if [ "$#" -ge 4 ]; then wl="$4"; else wl="$(_hk_worktree_slugs)"; fi
  printf '%s' "$bj" > "$HERDR_TABLIST"; local b; b="$(_hk_orphans wE "$wl")"
  printf '%s' "$a1" > "$HERDR_TABLIST"; local a; a="$(_hk_orphans wE "$wl")"
  local leak; leak="$(_hk_leak_delta "$b" "$a")"
  if [ -n "$leak" ]; then
    printf '%s' "$a2" > "$HERDR_TABLIST"; a="$(_hk_orphans wE "$wl")"
    leak="$(_hk_leak_delta "$b" "$a")"
  fi
  [ -n "$leak" ]
}

# ── Fixtures ─────────────────────────────────────────────────────────────────────────────────────
# BEFORE: the builder is working (agent-backed) — not an orphan.
BEFORE='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"working","label":"tab-leak-guard-round2","pane_count":2,"tab_id":"wE:tMB","workspace_id":"wE"}]}}'

# AFTER_BUILDER_FLIP: mid-suite the builder's OWN tab flips working->unknown. Its LABEL is a live
# worktree slug, so the HERD-115 whitelist drops it → must NOT red. This is the exact watcher-path
# self-tab false-red, reproduced with an empty .herd-tabs registry so ONLY the slug whitelist saves it.
AFTER_BUILDER_FLIP='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"unknown","label":"tab-leak-guard-round2","pane_count":2,"tab_id":"wE:tMB","workspace_id":"wE"}]}}'

# AFTER_FOREIGN_LEAK: a genuine suite leak — a NEW agent-less tab whose label is NOT any live worktree
# slug (a hermetic test's escaped 'review·<slug>' tab). Persists across the settle window → must RED.
AFTER_FOREIGN_LEAK='{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
  {"agent_status":"working","label":"tab-leak-guard-round2","pane_count":2,"tab_id":"wE:tMB","workspace_id":"wE"},
  {"agent_status":"unknown","label":"review·leaky-escape","pane_count":2,"tab_id":"wE:tLEAK","workspace_id":"wE"}]}}'

# ── Assertions ───────────────────────────────────────────────────────────────────────────────────

# 1. WORKTREE-SLUG WHITELIST (the HERD-115 fix): an in-flight builder's own tab flipping to unknown
#    mid-suite does NOT red — even on the FIRST snapshot, before any settle, and with an EMPTY
#    .herd-tabs registry (the watcher path where registration (a) can't help).
if guard_reds "$BEFORE" "$AFTER_BUILDER_FLIP" "$AFTER_BUILDER_FLIP"; then
  fail "1: the builder's OWN tab (label = live worktree slug) red the guard — should be whitelisted"
fi
ok

# 2. NO FALSE-GREEN: a FOREIGN agent-less tab (label NOT a live worktree slug) that persists still reds.
#    The slug whitelist must not weaken real-leak detection.
if guard_reds "$BEFORE" "$AFTER_FOREIGN_LEAK" "$AFTER_FOREIGN_LEAK"; then ok; else
  fail "2: a FOREIGN leak (label not a live worktree slug) did NOT red — the slug whitelist over-fired"
fi

# 3. Steady state: identical before/after -> clean, no settle needed.
if guard_reds "$BEFORE" "$BEFORE" "$BEFORE"; then
  fail "3: guard red with identical before/after snapshots"
fi
ok

# 4. FAIL-SOFT / control: with NO worktree-slug whitelist (git absent or not a checkout → empty set)
#    and an empty .herd-tabs registry, the SAME builder-flip snapshot that passed assertion 1 now REDS.
#    This proves (a) the slug whitelist is precisely what silences the self-tab red, and (b) fail-soft
#    degrades to the prior (a)/(b) behaviour — never to a false-green.
if guard_reds "$BEFORE" "$AFTER_BUILDER_FLIP" "$AFTER_BUILDER_FLIP" ""; then ok; else
  fail "4: with an empty worktree-slug whitelist the builder flip did NOT red — fail-soft is unsound"
fi

echo "ALL PASS ($pass checks)"
