#!/usr/bin/env bash
# test-layout-reconcile.sh — hermetic tests for the shared EYES-ON-LAYOUT helper
# (scripts/herd/layout-reconcile.sh): layout_snapshot, layout_reconcile, layout_write_registry,
# and layout_fold_stray_tabs.
#
# Design (mirrors test-cli-reload.sh's rich-stub approach):
#   • herdr is STUBBED on PATH — a file-backed simulation of the pane/tab JSON API. State lives
#     under $HERDR_STATE:  panes/<id>/tab = tab_id · panes/<id>/cmd = foreground cmdline (the role
#     signal) · tabs/<id> = tab label. `tab close` deletes the tab file. NO process is ever spawned
#     and no real herdr tab/pane is touched — the tab-leak-guard stays green.
#   • The library is SOURCED directly and its functions called with faked pane/process-info JSON,
#     so the reconciler's decisions are asserted in isolation.
#
# Covers the three cases the backlog item names: stale-registry, duplicate-viewer, missing-pane.
# Run:  bash tests/test-layout-reconcile.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/herd/layout-reconcile.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── herdr stub (pane list / pane process-info / tab list / tab close) ─────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
S="${HERDR_STATE:?}"; mkdir -p "$S/tabs" "$S/panes"
case "${1:-} ${2:-}" in
  "pane list")
    python3 - "$S" <<'PY'
import sys,os,json
S=sys.argv[1]; d=os.path.join(S,"panes"); panes=[]
if os.path.isdir(d):
    for p in sorted(os.listdir(d)):
        tf=os.path.join(d,p,"tab")
        tab=open(tf).read().strip() if os.path.exists(tf) else ""
        panes.append({"pane_id":p,"tab_id":tab})
print(json.dumps({"result":{"panes":panes}}))
PY
    ;;
  "pane process-info")
    p="${4:-}"
    if [ ! -d "$S/panes/$p" ]; then printf '{"result":{}}\n'; exit 0; fi
    cmd=""; [ -f "$S/panes/$p/cmd" ] && cmd="$(cat "$S/panes/$p/cmd")"
    if [ -n "$cmd" ]; then
      printf '{"result":{"process_info":{"shell_pid":4242,"foreground_processes":[{"pid":5151,"cmdline":"%s"}]}}}\n' "$cmd"
    else
      printf '{"result":{"process_info":{"shell_pid":4242,"foreground_processes":[]}}}\n'
    fi ;;
  "tab list")
    python3 - "$S" <<'PY'
import sys,os,json
S=sys.argv[1]; d=os.path.join(S,"tabs")
tabs=[{"tab_id":t,"label":open(os.path.join(d,t)).read().strip()} for t in sorted(os.listdir(d))]
print(json.dumps({"result":{"tabs":tabs}}))
PY
    ;;
  "tab close")
    rm -f "$S/tabs/${3:-}"; printf '{"result":{}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# shellcheck source=/dev/null
. "$LIB"

# _pane STATE PANE TAB [CMD] — create a fake pane in the stub state.
_pane(){ local S="$1" p="$2" tab="$3" cmd="${4:-}"; mkdir -p "$S/panes/$p"; printf '%s' "$tab" > "$S/panes/$p/tab"; [ -n "$cmd" ] && printf '%s' "$cmd" > "$S/panes/$p/cmd"; return 0; }

# snapshot assertion helper: does the snapshot contain a "<role>\t<pane>" line?
_snap_has(){ printf '%s\n' "$1" | awk -F'\t' -v r="$2" -v p="$3" '$1==r&&$2==p{f=1} END{exit !f}'; }
# reconcile assertion helper: does the reconcile output contain "<key>=<val>" exactly?
_rec_is(){ printf '%s\n' "$1" | grep -qx "$2=$3"; }

# ── 1. layout_snapshot classifies every pane by its live foreground process ──
S="$T/s1"; mkdir -p "$S"; export HERDR_STATE="$S"
_pane "$S" pA tC 'claude --model x /coordinator'   # agent
_pane "$S" pL tC 'bash /x/backlog-view.sh'         # backlog
_pane "$S" pW tC 'bash /x/herd-watch.sh'           # watch
_pane "$S" pB tC ''                                # bare
_pane "$S" pO tW 'bash /x/backlog-view.sh'         # different tab — must not appear
snap="$(layout_snapshot w1 tC)"
_snap_has "$snap" agent   pA || fail "snapshot did not classify the claude pane as agent"
_snap_has "$snap" backlog pL || fail "snapshot did not classify the backlog-view pane as backlog"
_snap_has "$snap" watch   pW || fail "snapshot did not classify the herd-watch pane as watch"
_snap_has "$snap" bare    pB || fail "snapshot did not classify the empty pane as bare"
printf '%s\n' "$snap" | awk -F'\t' '$2=="pO"{f=1} END{exit !f}' \
  && fail "snapshot leaked a pane from a DIFFERENT tab" || true
ok

# ── 2. DUPLICATE VIEWER: two backlog panes → adopt the first, flag the other ─
S="$T/s2"; mkdir -p "$S"; export HERDR_STATE="$S"
_pane "$S" pA tC 'claude /coordinator'
_pane "$S" pL tC 'bash /x/backlog-view.sh'   # viewer 1 (first in scan order)
_pane "$S" pM tC 'bash /x/backlog-view.sh'   # viewer 2 (duplicate; sorts after pL)
_pane "$S" pW tC 'bash /x/agent-watch.sh'
rec="$(layout_reconcile w1 tC '' '' '')"
_rec_is "$rec" backlog pL     || fail "duplicate-viewer: first backlog viewer not adopted (got: $(printf '%s' "$rec" | grep '^backlog='))"
_rec_is "$rec" dup_backlog pM || fail "duplicate-viewer: second viewer not flagged as a duplicate (got: $(printf '%s' "$rec" | grep '^dup_backlog='))"
_rec_is "$rec" agent pA       || fail "duplicate-viewer: agent anchor not resolved"
_rec_is "$rec" watch pW       || fail "duplicate-viewer: watch not resolved"
_rec_is "$rec" missing ''     || fail "duplicate-viewer: nothing should be missing (got: $(printf '%s' "$rec" | grep '^missing='))"
ok

# ── 3. STALE REGISTRY: hints name panes that are GONE → ignored, live roles win ─
# The registry points every role at a dead pane id (poisoned by a prior bad reload). Reconcile
# must trust the LIVE roster, never a hint whose pane is no longer observed in the tab.
S="$T/s3"; mkdir -p "$S"; export HERDR_STATE="$S"
_pane "$S" pA tC 'claude /coordinator'
_pane "$S" pL tC 'bash /x/backlog-view.sh'
_pane "$S" pW tC 'bash /x/herd-watch.sh'
rec="$(layout_reconcile w1 tC pDEAD_a pDEAD_b pDEAD_w)"
_rec_is "$rec" agent pA   || fail "stale-registry: agent resolved from a stale hint instead of the live agent pane"
_rec_is "$rec" backlog pL || fail "stale-registry: backlog resolved from a stale hint instead of the live viewer"
_rec_is "$rec" watch pW   || fail "stale-registry: watch resolved from a stale hint instead of the live watcher"
_rec_is "$rec" missing '' || fail "stale-registry: reported a missing role despite all live roles present"
ok

# ── 4. MISSING PANE: a role is absent from the tab and the registry is stale → 'missing' ─
# Backlog + agent are live; there is NO watch pane and the registry watch id is dead. Reconcile
# must leave watch empty and name it in 'missing' so the caller CREATES it.
S="$T/s4"; mkdir -p "$S"; export HERDR_STATE="$S"
_pane "$S" pA tC 'claude /coordinator'
_pane "$S" pL tC 'bash /x/backlog-view.sh'
rec="$(layout_reconcile w1 tC '' '' pW_dead)"
_rec_is "$rec" watch ''      || fail "missing-pane: watch should be empty when no watch pane exists and the hint is stale"
_rec_is "$rec" missing watch || fail "missing-pane: 'watch' not named in missing (got: $(printf '%s' "$rec" | grep '^missing='))"
_rec_is "$rec" backlog pL    || fail "missing-pane: live backlog not adopted"
_rec_is "$rec" agent pA      || fail "missing-pane: live agent not adopted"
ok

# ── 5. VALID hint adopted: a registry pane STILL PRESENT (bare) is adopted for its role ─
# No live backlog viewer, but the registry backlog pane still exists as a bare console — reconcile
# adopts it (the caller will relaunch the viewer there), distinguishing a valid hint from a stale one.
S="$T/s5"; mkdir -p "$S"; export HERDR_STATE="$S"
_pane "$S" pA tC 'claude /coordinator'
_pane "$S" pR tC ''   # bare — the registry-named backlog pane, viewer died
rec="$(layout_reconcile w1 tC '' pR '')"
_rec_is "$rec" backlog pR    || fail "valid-hint: present bare registry pane not adopted for backlog"
_rec_is "$rec" missing watch || fail "valid-hint: watch (genuinely absent) not named in missing"
ok

# ── 6. layout_write_registry rewrites from OBSERVED ids, stamping the workspace ─
S="$T/s6"; mkdir -p "$S"; export HERDR_STATE="$S"
reg="$S/.herd-panes"
layout_write_registry "$reg" w1 tC pA pL pW
grep -qx 'coordinator-agent pA tC w1' "$reg" || fail "registry: coordinator-agent row wrong/missing"
grep -qx 'backlog pL tC w1'           "$reg" || fail "registry: backlog row wrong/missing"
grep -qx 'watch pW tC w1'             "$reg" || fail "registry: watch row wrong/missing"
# Empty roles omit their row entirely.
layout_write_registry "$reg" w1 tC pA pL ''
grep -q '^watch ' "$reg" && fail "registry: watch row written despite an empty watch pane" || true
[ "$(wc -l < "$reg")" -eq 2 ] || fail "registry: expected exactly 2 rows when watch is empty"
# The writer creates the parent dir if absent.
layout_write_registry "$S/nested/dir/.herd-panes" w1 tC pA '' ''
[ -f "$S/nested/dir/.herd-panes" ] || fail "registry: writer did not create the parent directory"
ok

# ── 7. layout_fold_stray_tabs closes standalone watch-/backlog- tabs, keeps coordinator ─
S="$T/s7"; mkdir -p "$S/tabs"; export HERDR_STATE="$S"
printf 'coordinator-herdtest' > "$S/tabs/tC"
printf 'watch-herdtest'       > "$S/tabs/tWs"
printf 'backlog-herdtest'     > "$S/tabs/tBs"
layout_fold_stray_tabs w1 herdtest
[ -f "$S/tabs/tC" ]  || fail "fold: coordinator tab was closed (must never happen)"
[ ! -f "$S/tabs/tWs" ] || fail "fold: stray watch-herdtest tab not closed"
[ ! -f "$S/tabs/tBs" ] || fail "fold: stray backlog-herdtest tab not closed"
ok

echo "ALL PASS ($pass checks)"
