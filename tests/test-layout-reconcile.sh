#!/usr/bin/env bash
# test-layout-reconcile.sh — hermetic tests for the shared EYES-ON-LAYOUT helper
# (scripts/herd/layout-reconcile.sh): layout_snapshot, layout_reconcile, layout_write_registry,
# and layout_fold_stray_tabs.
#
# Design (mirrors test-cli-reload.sh's rich-stub approach):
#   • herdr is STUBBED on PATH — a file-backed simulation of the pane/tab JSON API. State lives
#     under $HERDR_STATE:  panes/<id>/tab = tab_id · panes/<id>/cmd = foreground cmdline (the role
#     signal) · panes/<id>/label = last `pane rename` label (HERD-650) · tabs/<id> = tab label.
#     `tab close` deletes the tab file. NO process is ever spawned and no real herdr tab/pane is
#     touched — the tab-leak-guard stays green.
#   • The library is SOURCED directly and its functions called with faked pane/process-info JSON,
#     so the reconciler's decisions are asserted in isolation.
#
# Covers the three cases the backlog item names: stale-registry, duplicate-viewer, missing-pane —
# plus (HERD-650) the role-LABEL reconcile layout_write_registry now performs on every pass.
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
  "pane rename")
    p="${3:-}"; shift 3 || true
    if [ -n "$p" ] && [ -d "$S/panes/$p" ]; then printf '%s' "$*" > "$S/panes/$p/label"; fi
    printf '{"result":{}}\n' ;;
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
_rec_is(){ grep -qx "$2=$3" <<< "$(printf '%s\n' "$1")"; }

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
_pane "$S" pA tC 'claude /coordinator'
_pane "$S" pL tC 'bash /x/backlog-view.sh'
_pane "$S" pW tC 'bash /x/herd-watch.sh'
reg="$S/.herd-panes"
layout_write_registry "$reg" w1 tC pA pL pW wsX
grep -qx 'coordinator-agent pA tC w1' "$reg" || fail "registry: coordinator-agent row wrong/missing"
grep -qx 'backlog pL tC w1'           "$reg" || fail "registry: backlog row wrong/missing"
grep -qx 'watch pW tC w1'             "$reg" || fail "registry: watch row wrong/missing"
# Empty roles omit their row entirely.
layout_write_registry "$reg" w1 tC pA pL '' wsX
grep -q '^watch ' "$reg" && fail "registry: watch row written despite an empty watch pane" || true
[ "$(wc -l < "$reg")" -eq 2 ] || fail "registry: expected exactly 2 rows when watch is empty"
# The writer creates the parent dir if absent.
layout_write_registry "$S/nested/dir/.herd-panes" w1 tC pA '' '' wsX
[ -f "$S/nested/dir/.herd-panes" ] || fail "registry: writer did not create the parent directory"
ok

# ── 6b. HERD-650: layout_write_registry re-asserts each resolved pane's role LABEL ──────────────
# The write above (pA/pL/pW all present) must ALSO have labelled every resolved pane via the stub's
# `pane rename` — this is the actual reconcile the fix adds, not just the registry text file. Reuses
# coordinator.sh's PRE-EXISTING `<role>·<ws>` family (HERD-310 stamp coverage) rather than a
# conflicting scheme, so a workspace-qualified ws_name arg yields a workspace-qualified label.
[ "$(cat "$S/panes/pA/label" 2>/dev/null)" = "coordinator·wsX" ] || fail "label: coordinator-agent pane not labelled 'coordinator·wsX'"
[ "$(cat "$S/panes/pL/label" 2>/dev/null)" = "backlog·wsX" ]     || fail "label: backlog pane not labelled 'backlog·wsX'"
[ "$(cat "$S/panes/pW/label" 2>/dev/null)" = "watch·wsX" ]       || fail "label: watch pane not labelled 'watch·wsX'"
ok

# ── 6c. HERD-650: a hand-cleared label self-heals on the NEXT write_registry pass ────────────────
# Simulates the exact incident: a restart erodes the label (here, a human/older-herdr clears it) —
# the next reconcile pass (any caller of layout_write_registry: reload / herd pane * / coordinator.sh)
# must restore it WITHOUT anything else changing hands.
: > "$S/panes/pL/label"
[ -z "$(cat "$S/panes/pL/label")" ] || fail "label self-heal setup: clear did not take"
layout_write_registry "$reg" w1 tC pA pL pW wsX
[ "$(cat "$S/panes/pL/label")" = "backlog·wsX" ] || fail "label self-heal: hand-cleared backlog label was not restored on the next pass"
ok

# ── 6d. HERD-650: agent-pane naming (herd_driver_pane_rename's OWN callers) is UNTOUCHED ─────────
# layout_write_registry must label ONLY the three control-room roles it was given — never reach for
# or rename any OTHER pane (e.g. a builder agent pane a different lane already named by slug).
_pane "$S" pOther tC 'claude /builder'
layout_write_registry "$reg" w1 tC pA pL pW wsX
[ -f "$S/panes/pOther/label" ] && fail "label: layout_write_registry touched an unrelated pane's label" || true
ok

# ── 6e. HERD-650: no ws_name supplied → fails soft to the bare (unqualified) role word ────────────
S6E="$T/s6e"; mkdir -p "$S6E"; export HERDR_STATE="$S6E"
_pane "$S6E" pA tC 'claude /coordinator'
_pane "$S6E" pL tC 'bash /x/backlog-view.sh'
_pane "$S6E" pW tC 'bash /x/herd-watch.sh'
layout_write_registry "$S6E/.herd-panes" w1 tC pA pL pW
[ "$(cat "$S6E/panes/pA/label" 2>/dev/null)" = "coordinator" ] || fail "label fallback: coordinator-agent pane not labelled 'coordinator' without a ws_name"
[ "$(cat "$S6E/panes/pL/label" 2>/dev/null)" = "backlog" ]     || fail "label fallback: backlog pane not labelled 'backlog' without a ws_name"
[ "$(cat "$S6E/panes/pW/label" 2>/dev/null)" = "watch" ]       || fail "label fallback: watch pane not labelled 'watch' without a ws_name"
export HERDR_STATE="$S"
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

# ── 8. DRIVER-AWARE pane-role classification (HERD-428) ──────────────────────
# _reload_pane_role's 'agent' branch used to substring-match the LITERAL 'claude', so a codex/grok
# agent pane fell through to 'busy' (never 'agent') under a non-Claude HERD_DRIVER. It now reads the
# ACTIVE driver's DRIVER_AGENT_PROCESS_SIGNATURE (scripts/herd/driver.sh's
# herd_driver_agent_process_signature) instead. Source the REAL driver.sh (functions only, no side
# effects) so the signature resolves against the REAL templates/drivers/*.driver files — proving this
# against the shipped codex.driver, not a test double.
# shellcheck source=/dev/null
. "$HERE/../scripts/herd/driver.sh"

S="$T/s8"; mkdir -p "$S"; export HERDR_STATE="$S"
_pane "$S" pClaude tC 'claude --model x /coordinator'
_pane "$S" pCodex  tC 'codex --model x --dangerously-bypass-approvals-and-sandbox hello'
_pane "$S" pBare   tC ''

# BYTE-IDENTICAL default: HERD_DRIVER unset resolves to herdr-claude, so classification is unchanged —
# a claude pane is 'agent', a bare pane is 'bare', and (since the default signature is only 'claude') a
# codex pane is NOT recognized as this driver's agent.
unset HERD_DRIVER
[ "$(_reload_pane_role pClaude)" = "agent" ] || fail "driver-aware: default driver did not classify a claude pane as agent"
[ "$(_reload_pane_role pBare)"   = "bare"  ] || fail "driver-aware: default driver did not classify an empty pane as bare"
[ "$(_reload_pane_role pCodex)"  = "busy"  ] || fail "driver-aware: default driver should not recognize a codex process as its own agent"

# HERD_DRIVER=codex: a codex pane now classifies 'agent' (the gap this ships fixes) — the codex.driver
# DRIVER_AGENT_PROCESS_SIGNATURE binding is consulted for real. A claude pane is correspondingly NOT
# this driver's agent (scoped to the ACTIVE driver, not a blanket match), and a bare pane is unaffected.
export HERD_DRIVER=codex
[ "$(_reload_pane_role pCodex)"  = "agent" ] || fail "driver-aware: HERD_DRIVER=codex did not classify a codex pane as agent"
[ "$(_reload_pane_role pClaude)" = "busy"  ] || fail "driver-aware: HERD_DRIVER=codex should not recognize a claude process as its own agent"
[ "$(_reload_pane_role pBare)"   = "bare"  ] || fail "driver-aware: HERD_DRIVER=codex misclassified a bare pane"
unset HERD_DRIVER
ok

# ── 9. HERD-650: once driver.sh is sourced, layout_write_registry labels via
# herd_driver_pane_rename — which is headless-AWARE, so a headless driver is a clean no-op (no
# `pane rename` call reaches herdr at all) while herdr-claude (the default) still labels normally.
S="$T/s9"; mkdir -p "$S"; export HERDR_STATE="$S"
_pane "$S" pA tC 'claude /coordinator'
_pane "$S" pL tC 'bash /x/backlog-view.sh'
_pane "$S" pW tC 'bash /x/herd-watch.sh'
reg="$S/.herd-panes"

export HERD_DRIVER=headless
layout_write_registry "$reg" w1 tC pA pL pW wsX
[ -f "$S/panes/pA/label" ] && fail "label: headless driver must NOT rename any pane" || true
[ -f "$S/panes/pL/label" ] && fail "label: headless driver must NOT rename any pane" || true
[ -f "$S/panes/pW/label" ] && fail "label: headless driver must NOT rename any pane" || true

unset HERD_DRIVER
layout_write_registry "$reg" w1 tC pA pL pW wsX
[ "$(cat "$S/panes/pA/label" 2>/dev/null)" = "coordinator·wsX" ] || fail "label: default driver (via herd_driver_pane_rename) did not label the agent pane"
[ "$(cat "$S/panes/pL/label" 2>/dev/null)" = "backlog·wsX" ]     || fail "label: default driver (via herd_driver_pane_rename) did not label the backlog pane"
[ "$(cat "$S/panes/pW/label" 2>/dev/null)" = "watch·wsX" ]       || fail "label: default driver (via herd_driver_pane_rename) did not label the watch pane"
ok

# ── 10. HERD-668: _reload_pane_role classifies an agents-pane-view.sh pane as 'agents' ───────────
S="$T/s10"; mkdir -p "$S"; export HERDR_STATE="$S"
_pane "$S" pAg tC 'bash /x/agents-pane-view.sh'
[ "$(_reload_pane_role pAg)" = "agents" ] || fail "agents-pane: pane running agents-pane-view.sh not classified 'agents'"
ok

# ── 11. HERD-668: layout_write_registry's optional 8th 'agents' arg ──────────────────────────────
# BYTE-IDENTICAL WHEN OMITTED: every pre-existing call site (coordinator.sh/cmd_reload/herd pane *
# before this lever existed, and AGENTS_PANE=off today) never passes an 8th arg — the registry must
# carry no 'agents' row and the label pass must touch no extra pane, exactly like test 6's baseline.
S="$T/s11"; mkdir -p "$S"; export HERDR_STATE="$S"
_pane "$S" pA tC 'claude /coordinator'
_pane "$S" pL tC 'bash /x/backlog-view.sh'
_pane "$S" pW tC 'bash /x/herd-watch.sh'
reg="$S/.herd-panes"
layout_write_registry "$reg" w1 tC pA pL pW wsX
grep -q '^agents ' "$reg" && fail "registry: an 'agents' row appeared despite no 8th arg (AGENTS_PANE=off must be byte-identical)" || true
[ "$(wc -l < "$reg")" -eq 3 ] || fail "registry: expected exactly 3 rows when the 8th (agents) arg is omitted"

# ON: an 8th arg writes the 4th role row and labels it agents·<ws_name>, alongside the other three.
_pane "$S" pAg tC ''
layout_write_registry "$reg" w1 tC pA pL pW wsX pAg
grep -qx 'agents pAg tC w1' "$reg" || fail "registry: agents row wrong/missing when the 8th arg is supplied"
[ "$(wc -l < "$reg")" -eq 4 ] || fail "registry: expected exactly 4 rows when the agents pane is supplied"
[ "$(cat "$S/panes/pAg/label" 2>/dev/null)" = "agents·wsX" ] || fail "label: agents pane not labelled 'agents·wsX'"
# Empty 8th arg again → row/label drop back out (never leaves a stale 'agents' row lying around).
layout_write_registry "$reg" w1 tC pA pL pW wsX
grep -q '^agents ' "$reg" && fail "registry: stale 'agents' row survived a write with no 8th arg" || true
ok

echo "ALL PASS ($pass checks)"
