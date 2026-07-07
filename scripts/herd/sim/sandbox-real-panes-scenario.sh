#!/usr/bin/env bash
# scripts/herd/sim/sandbox-real-panes-scenario.sh — P2b DISPOSABLE REAL-HERDR-PANES scenario.
#
# The pane/TUI layer that sim P0/P1/P2a explicitly SKIP. Where the P1 concurrency scenario
# (sandbox-concurrency-scenario.sh) and the P2a limit-resume scenario (sandbox-limit-resume-
# scenario.sh) both run HERD_DRIVER=headless (panes-as-a-view: NO herdr tabs/panes ever created),
# this P2b scenario stands up a REAL, disposable herdr control room against the local fixture and
# asserts the pane surface itself via herdr's JSON output:
#   • a control-room TAB with a watcher pane + a backlog pane (labels asserted);
#   • a builder TAB with a stub builder (a file/CLI-driven agent — no model call);
#   • agent-status transitions idle → working → done, each observed via `herdr agent list`;
#   • CLEAN TEARDOWN — the disposable workspace is closed and NO tab or pane is leaked afterward
#     (so the result satisfies the tab-leak-guard).
#
# RUNNER-CONTEXT SAFETY (tab-leak-guard / PR #180). This scenario creates REAL panes, so — unlike its
# headless siblings — it must not perturb the runner's own workspace. It never touches an existing
# workspace: it creates its OWN disposable workspace with a UNIQUE label (sandbox-realpanes-sim-<pid>)
# distinct from any project's WORKSPACE_NAME, drives ONLY tabs/panes it created there, and closes that
# whole workspace on teardown (also from an EXIT trap, so a mid-run failure still cleans up). Because
# the healthcheck's tab-leak-guard is SCOPED to the project's own workspace (WORKSPACE_NAME →
# workspace_id, .herd/healthcheck.project.sh), a disposable workspace with a different label is never
# counted — running this from inside a builder tab cannot false-red the guard on the runner's own tab.
#
# NO-FALSE-RED / HEADLESS CI. herdr is a hard dependency for the real-pane path only. When herdr is
# unavailable — not installed, no running server, or forced off via SANDBOX_NO_HERDR=1 (headless CI) —
# the scenario SKIPS the pane checkpoints loudly-but-cleanly (result "skip", exit 0) rather than
# failing. A usage-limit-style expected-absence is never a red alarm.
#
# HERMETIC(ish): the fixture is fixture-repo only (deterministic local git; reused from
# sandbox-fixture.sh). The only non-local surface is the disposable herdr workspace, which is created
# fresh and closed on exit — nothing persists. Zero model calls, zero quota, zero network beyond the
# local herdr socket.
#
# Usage:
#   bash scripts/herd/sim/sandbox-real-panes-scenario.sh [--artifacts DIR] [--keep] [--label NAME]
#     --artifacts DIR   put the repo + scorecard + artifacts here (default: a fresh mktemp dir)
#     --keep            do not delete the artifacts dir on exit (implied when --artifacts is given)
#     --label NAME      workspace label prefix (default: sandbox-realpanes-sim)
#   Env:
#     SANDBOX_NO_HERDR=1        force the clean SKIP path (no real workspace) — set by the test
#     SANDBOX_NO_SCREENSHOT=1   force-skip the screenshot step (set by the test)
#
# Exit: 0 = every checkpoint passed OR cleanly skipped · 1 = at least one checkpoint failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"

# ── output helpers (mirror the sandbox-sim family's style) ──────────────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
skip() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────
ART=""; KEEP=""; LABEL_PREFIX="sandbox-realpanes-sim"
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    --label)     LABEL_PREFIX="${2:-}"; shift 2 ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-real-panes-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [ -z "$ART" ]; then ART="$(mktemp -d)"; fi
mkdir -p "$ART"

SCENARIO="stub-real-panes-e2e"
REPO="$ART/repo"
SHOTS="$ART/screenshots"
mkdir -p "$SHOTS"

# A workspace label unique enough to never collide with a real project's WORKSPACE_NAME. $$ keeps it
# per-run; the label is a runtime handle, not part of the deterministic fixture, so this is fine.
WS_LABEL="$LABEL_PREFIX-$$"

# ── checkpoint recording (bash 3.2: parallel indexed arrays, no assoc arrays) ────────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0; _skip=0
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail="$*"
  detail="$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
    skip) _skip=$((_skip+1)); skip "$name — $detail" ;;
  esac
}

# ── scorecard state ──────────────────────────────────────────────────────────────
HERDR_OK=false
WSID=""
CTRL_TAB=""; BUILD_TAB=""
WATCH_PANE=""; BACKLOG_PANE=""; BUILD_PANE=""
TABS_CREATED=0; PANES_CREATED=0
TRANSITIONS=()          # agent states we OBSERVED, in order
LEAKED_TABS=-1          # -1 = not measured; else the post-teardown count in our workspace
PANE_CAPTURES=0
SHOTS_TAKEN=0

# ── teardown safety net: close the disposable workspace no matter how we exit ─────────────────────
_cleanup() {
  if [ -n "$WSID" ]; then herdr workspace close "$WSID" >/dev/null 2>&1 || true; fi
  if [ -z "$KEEP" ]; then rm -rf "$ART"; fi
}
trap _cleanup EXIT

# ── jq-free herdr JSON readers ────────────────────────────────────────────────────
# hj '<python expr over `d` (the parsed JSON)>' — reads stdin JSON, prints the expr.
hj() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" 2>/dev/null; }

# herdr_up — success iff herdr is installed, a server is reachable, and it speaks valid JSON.
herdr_up() {
  [ "${SANDBOX_NO_HERDR:-}" = "1" ] && return 1
  command -v herdr >/dev/null 2>&1 || return 1
  herdr workspace list >/dev/null 2>&1 || return 1
  herdr workspace list 2>/dev/null | python3 -c 'import sys,json; json.load(sys.stdin)' >/dev/null 2>&1
}

# tab_labels_in <wsid> — newline list of "tab_id<TAB>label" for a workspace.
tab_json()   { herdr tab list --workspace "$1" 2>/dev/null; }
pane_json()  { herdr pane list --workspace "$1" 2>/dev/null; }
# agent_status_of <slug> — the agent_status word herdr reports for a named agent (empty if absent).
agent_status_of() {
  herdr agent list 2>/dev/null | python3 -c '
import sys,json
name=sys.argv[1]
try:
    for a in (json.load(sys.stdin).get("result") or {}).get("agents") or []:
        if str(a.get("agent",""))==name or str(a.get("name",""))==name:
            print(str(a.get("agent_status",""))); break
except Exception:
    pass
' "$1" 2>/dev/null
}

# take_screenshot <label> — macOS screencapture at a checkpoint. DEGRADES GRACEFULLY (no-false-red):
# skips — never fails — when opted out / not macOS / tool absent / permission missing (empty capture).
take_screenshot() {
  local label="$1"; local out="$SHOTS/watcher-$label.png"
  if [ "${SANDBOX_NO_SCREENSHOT:-}" = "1" ]; then
    checkpoint "screenshot_$label" skip "opt-out (SANDBOX_NO_SCREENSHOT=1)"; return 0
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) ;;
    *) checkpoint "screenshot_$label" skip "not macOS (screencapture unavailable)"; return 0 ;;
  esac
  command -v screencapture >/dev/null 2>&1 || { checkpoint "screenshot_$label" skip "screencapture not found"; return 0; }
  if screencapture -x "$out" >/dev/null 2>&1 && [ -s "$out" ]; then
    SHOTS_TAKEN=$((SHOTS_TAKEN+1)); checkpoint "screenshot_$label" pass "captured $out"
  else
    rm -f "$out" 2>/dev/null || true
    checkpoint "screenshot_$label" skip "screencapture unavailable (headless or Screen Recording permission missing)"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s══ Sandbox REAL-PANES scenario: %s ══%s\n' "$c_bold" "$SCENARIO" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# ── init: build the deterministic fixture (a real cwd for the panes) ─────────────────────────────
step init "build deterministic local fixture"
FIXTURE_SHA="$(sandbox_fixture_build "$REPO")" || { bad "fixture build failed"; exit 1; }
info "fixture HEAD: $FIXTURE_SHA"
[ -f "$REPO/app/greet.sh" ] && checkpoint fixture_built pass "fixture at $REPO (HEAD ${FIXTURE_SHA:0:12})" \
  || checkpoint fixture_built fail "fixture missing app/greet.sh"

# ── availability guard: skip cleanly (never red) when herdr is unavailable ───────────────────────
step probe "probe herdr availability (real-pane path requires a live herdr server)"
if herdr_up; then
  HERDR_OK=true
  checkpoint herdr_available pass "herdr present + server reachable + JSON OK"
else
  reason="herdr unavailable"
  [ "${SANDBOX_NO_HERDR:-}" = "1" ] && reason="SANDBOX_NO_HERDR=1 (forced skip)"
  command -v herdr >/dev/null 2>&1 || reason="herdr not installed"
  checkpoint herdr_available skip "$reason — skipping the real-pane path (headless CI is clean, not red)"
  # Skip every downstream pane checkpoint LOUDLY (each recorded skip), then emit a skip scorecard.
  for cp in workspace_created control_room builder_tab agent_idle agent_working agent_done \
            pane_captured teardown_clean; do
    checkpoint "$cp" skip "no herdr — real-pane checkpoint not exercised"
  done
fi

# ── the real-pane path (only when herdr is up) ───────────────────────────────────────────────────
if [ "$HERDR_OK" = true ]; then

  # ── workspace: a fresh, disposable, ISOLATED workspace (unique label) ──────────────────────────
  step workspace "create a disposable isolated herdr workspace ($WS_LABEL)"
  WS_CREATE="$(herdr workspace create --label "$WS_LABEL" --cwd "$REPO" --no-focus 2>/dev/null || true)"
  WSID="$(printf '%s' "$WS_CREATE" | hj 'd["result"]["workspace"]["workspace_id"]')"
  CTRL_TAB="$(printf '%s' "$WS_CREATE" | hj 'd["result"]["tab"]["tab_id"]')"
  WATCH_PANE="$(printf '%s' "$WS_CREATE" | hj 'd["result"]["root_pane"]["pane_id"]')"
  if [ -n "$WSID" ] && [ -n "$CTRL_TAB" ] && [ -n "$WATCH_PANE" ]; then
    TABS_CREATED=$((TABS_CREATED+1)); PANES_CREATED=$((PANES_CREATED+1))
    checkpoint workspace_created pass "workspace $WSID (label $WS_LABEL), root tab $CTRL_TAB, root pane $WATCH_PANE"
  else
    checkpoint workspace_created fail "workspace create did not return ids (ws='$WSID' tab='$CTRL_TAB' pane='$WATCH_PANE')"
  fi

  # ── control room: watcher pane + backlog pane, both labelled, in the root tab ──────────────────
  if [ -n "$WSID" ]; then
    step control "build the control room: watcher + backlog panes"
    herdr tab rename "$CTRL_TAB" "herd-watch·rp" >/dev/null 2>&1 || true
    herdr pane rename "$WATCH_PANE" "watcher" >/dev/null 2>&1 || true
    # Split the root pane DOWN for the backlog view (a second pane in the same control-room tab).
    SPLIT="$(herdr pane split "$WATCH_PANE" --direction down --cwd "$REPO" --no-focus 2>/dev/null || true)"
    BACKLOG_PANE="$(printf '%s' "$SPLIT" | hj 'd["result"]["pane"]["pane_id"]')"
    [ -n "$BACKLOG_PANE" ] && { PANES_CREATED=$((PANES_CREATED+1)); herdr pane rename "$BACKLOG_PANE" "backlog" >/dev/null 2>&1 || true; }
    # Assert via JSON: the control-room tab carries exactly the watcher + backlog panes with labels.
    CTRL_OK="$(pane_json "$WSID" | python3 -c '
import sys,json
tab=sys.argv[1]
try:
    panes=(json.load(sys.stdin).get("result") or {}).get("panes") or []
    mine={str(p.get("label","")) for p in panes if str(p.get("tab_id",""))==tab}
    print("yes" if {"watcher","backlog"} <= mine else "no:"+",".join(sorted(mine)))
except Exception as e:
    print("err:"+str(e))
' "$CTRL_TAB" 2>/dev/null)"
    if [ "$CTRL_OK" = yes ]; then
      checkpoint control_room pass "control-room tab $CTRL_TAB has labelled watcher + backlog panes"
    else
      checkpoint control_room fail "watcher/backlog panes not both present+labelled ($CTRL_OK)"
    fi
  fi

  # ── builder tab: a stub builder (file/CLI-driven agent — no model) ─────────────────────────────
  if [ -n "$WSID" ]; then
    step builder "create a builder tab with a stub builder"
    BUILD_CREATE="$(herdr tab create --workspace "$WSID" --cwd "$REPO" --label "rp-builder" --no-focus 2>/dev/null || true)"
    BUILD_TAB="$(printf '%s' "$BUILD_CREATE" | hj 'd["result"]["tab"]["tab_id"]')"
    BUILD_PANE="$(printf '%s' "$BUILD_CREATE" | hj 'd["result"]["root_pane"]["pane_id"]')"
    [ -n "$BUILD_TAB" ] && TABS_CREATED=$((TABS_CREATED+1))
    [ -n "$BUILD_PANE" ] && PANES_CREATED=$((PANES_CREATED+1))
    # Give the pane visible content so the pane-read capture has something to show (no model call).
    if [ -n "$BUILD_PANE" ]; then
      herdr pane run "$BUILD_PANE" "printf 'rp stub builder: idle — awaiting task\n'" >/dev/null 2>&1 || true
    fi
    # Register the stub builder as an agent on its pane (the idle starting state).
    if [ -n "$BUILD_PANE" ]; then
      herdr pane report-agent "$BUILD_PANE" --source rp-sim --agent "rp-builder" --state idle >/dev/null 2>&1 || true
    fi
    BUILD_OK="$(tab_json "$WSID" | python3 -c '
import sys,json
tab=sys.argv[1]
try:
    tabs=(json.load(sys.stdin).get("result") or {}).get("tabs") or []
    print("yes" if any(str(t.get("tab_id",""))==tab and str(t.get("label",""))=="rp-builder" for t in tabs) else "no")
except Exception:
    print("err")
' "$BUILD_TAB" 2>/dev/null)"
    if [ "$BUILD_OK" = yes ] && [ -n "$BUILD_PANE" ]; then
      checkpoint builder_tab pass "builder tab $BUILD_TAB (label rp-builder), builder pane $BUILD_PANE"
    else
      checkpoint builder_tab fail "builder tab not created as expected (tab='$BUILD_TAB' pane='$BUILD_PANE' ok=$BUILD_OK)"
    fi
  fi

  # ── agent-status transitions idle → working → done (observed via herdr agent list) ─────────────
  if [ -n "$BUILD_PANE" ]; then
    step agent "drive + observe the stub builder's status transitions"

    # idle (the starting state reported above).
    st="$(agent_status_of rp-builder)"
    if [ "$st" = idle ]; then
      TRANSITIONS+=("idle"); checkpoint agent_idle pass "herdr agent list reports rp-builder = idle"
    else
      checkpoint agent_idle fail "expected idle, herdr agent list reports '$st'"
    fi

    # working.
    herdr pane report-agent "$BUILD_PANE" --source rp-sim --agent "rp-builder" --state working >/dev/null 2>&1 || true
    st="$(agent_status_of rp-builder)"
    if [ "$st" = working ]; then
      TRANSITIONS+=("working"); checkpoint agent_working pass "herdr agent list reports rp-builder = working"
    else
      checkpoint agent_working fail "expected working, herdr agent list reports '$st'"
    fi

    # done (herdr surfaces the custom-status word as agent_status).
    herdr pane run "$BUILD_PANE" "printf 'rp stub builder: done\n'" >/dev/null 2>&1 || true
    herdr pane report-agent "$BUILD_PANE" --source rp-sim --agent "rp-builder" --state idle --custom-status "done" >/dev/null 2>&1 || true
    st="$(agent_status_of rp-builder)"
    if [ "$st" = done ]; then
      TRANSITIONS+=("done"); checkpoint agent_done pass "herdr agent list reports rp-builder = done"
    else
      checkpoint agent_done fail "expected done, herdr agent list reports '$st'"
    fi
  fi

  # ── pane capture (best-effort artifact; degrades to skip, never fails) ─────────────────────────
  if [ -n "$BUILD_PANE" ]; then
    step capture "capture the builder pane's contents via herdr pane read"
    out="$ART/pane-builder.txt"
    herdr pane read "$BUILD_PANE" --source visible --lines 40 >"$out" 2>/dev/null || true
    if [ -s "$out" ]; then
      PANE_CAPTURES=$((PANE_CAPTURES+1)); checkpoint pane_captured pass "builder pane captured → $out"
    else
      checkpoint pane_captured skip "pane read returned no content (fresh/empty pane) — not a failure"
    fi
    # Optional screenshot at the 'done' checkpoint; degrades gracefully (no-false-red).
    take_screenshot "control-room"
  fi

  # ── CLEAN TEARDOWN: close the disposable workspace; assert nothing leaks ────────────────────────
  if [ -n "$WSID" ]; then
    step teardown "close the disposable workspace; assert no leaked tabs/panes"
    _wsid_closed="$WSID"
    herdr workspace close "$WSID" >/dev/null 2>&1 || true
    WSID=""    # closed — stop the EXIT trap double-closing.
    # Assert via JSON: the workspace is gone AND no tab/pane still references its id.
    LEAKED_TABS="$(herdr tab list 2>/dev/null | python3 -c '
import sys,json
ws=sys.argv[1]
try:
    tabs=(json.load(sys.stdin).get("result") or {}).get("tabs") or []
    print(sum(1 for t in tabs if str(t.get("workspace_id",""))==ws))
except Exception:
    print(-1)
' "$_wsid_closed" 2>/dev/null)"
    WS_GONE="$(herdr workspace list 2>/dev/null | python3 -c '
import sys,json
ws=sys.argv[1]
try:
    wss=(json.load(sys.stdin).get("result") or {}).get("workspaces") or []
    print("gone" if not any(str(w.get("workspace_id",""))==ws for w in wss) else "present")
except Exception:
    print("err")
' "$_wsid_closed" 2>/dev/null)"
    if [ "$WS_GONE" = gone ] && [ "$LEAKED_TABS" = 0 ]; then
      checkpoint teardown_clean pass "workspace $_wsid_closed closed; 0 leaked tabs/panes (tab-leak-guard clean)"
    else
      checkpoint teardown_clean fail "teardown left residue (workspace=$WS_GONE, leaked_tabs=$LEAKED_TABS)"
    fi
  fi
fi

# ── SCORECARD emitter (machine-readable JSON; mirrors the sandbox-sim family + real-pane fields) ──
_transitions_json() {
  local i out=""
  for i in ${TRANSITIONS[@]+"${TRANSITIONS[@]}"}; do
    out="$out${out:+, }\"$i\""
  done
  printf '[%s]' "$out"
}
write_scorecard() {
  local out="$ART/scorecard.json" result="$1"
  local i n; n=${#CP_NAMES[@]}
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
    printf '  "artifacts_dir": "%s",\n' "$ART"
    printf '  "repo_dir": "%s",\n' "$REPO"
    printf '  "fixture_sha": "%s",\n' "$FIXTURE_SHA"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "skipped": %d,\n' "$_skip"
    printf '  "herdr_available": %s,\n' "$HERDR_OK"
    printf '  "workspace_label": "%s",\n' "$WS_LABEL"
    printf '  "tabs_created": %d,\n' "$TABS_CREATED"
    printf '  "panes_created": %d,\n' "$PANES_CREATED"
    printf '  "agent_transitions": %s,\n' "$(_transitions_json)"
    printf '  "leaked_tabs": %d,\n' "$LEAKED_TABS"
    printf '  "pane_captures": %d,\n' "$PANE_CAPTURES"
    printf '  "screenshots": %d,\n' "$SHOTS_TAKEN"
    printf '  "checkpoints": [\n'
    for ((i=0; i<n; i++)); do
      printf '    {"name": "%s", "status": "%s", "detail": "%s"}' \
        "${CP_NAMES[$i]}" "${CP_STATUS[$i]}" "${CP_DETAIL[$i]}"
      [ "$i" -lt "$((n-1))" ] && printf ',\n' || printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
  } > "$out"
  printf '%s' "$out"
}

# RESULT: fail if any checkpoint failed; else skip when the real-pane path was not exercised; else pass.
if [ "$_fail" -gt 0 ]; then RESULT="fail"
elif [ "$HERDR_OK" != true ]; then RESULT="skip"
else RESULT="pass"; fi
SCARD="$(write_scorecard "$RESULT")"

printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:      %s\n' "$SCENARIO"
printf '  result:        %s\n' "$RESULT"
printf '  passed/failed/skipped: %d / %d / %d\n' "$_pass" "$_fail" "$_skip"
printf '  herdr:         %s\n' "$HERDR_OK"
printf '  transitions:   %s\n' "$(_transitions_json)"
printf '  leaked_tabs:   %s\n' "$LEAKED_TABS"
printf '  scorecard:     %s\n' "$SCARD"
printf '  artifacts:     %s\n' "$ART"

# A skip is a clean, deliberate no-op (headless CI): exit 0. Only a real failure is exit 1.
[ "$RESULT" = "fail" ] && exit 1 || exit 0
