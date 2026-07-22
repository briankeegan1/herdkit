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
#   • PANE ROLE LABELS at spawn (HERD-135): the agent pane is named by its slug via the driver, and the
#     label is asserted queryable — the role the dead-agent-eyes probe consumes instead of guessing;
#   • agent-status transitions idle → working → done, each observed via `herdr agent list`;
#   • RE-TASK WAKE (HERD-186): a live 'done' builder is re-tasked via the SHIPPED type+Enter path
#     (herd_driver_send_text → pane run + send-keys Enter) and the agent wakes (refix_wake_result
#     woke=1) — the 2026-07-08 stuck-in-prompt-buffer bug class;
#   • ALIVE/DEAD/MISSING dead-agent eyes, all three verdicts against REAL panes: claude launched AS the
#     pane root (shell_pid == claude pid) ⇒ 'alive' — never a fabricated death (PR #260 review); kill
#     the pane process ⇒ 'dead' (pane present, unresponsive); REMOVE the agent pane entirely ⇒ 'missing'
#     (HERD-135) — the SHIPPED status classifier reads 'agentmissing' (NOT done) for an open-PR builder
#     with no agent (the #249 false-'done' incident);
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
# shellcheck source=scripts/herd/sim/sim-notify-stub.sh
. "$HERE/sim-notify-stub.sh"   # notify hermeticity (HERD-139) — installed after the herdr probe

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

# report_agent_done <pane> <slug> — flip a stub agent's reported status word to 'done'. herdr 0.7.5
# renamed the custom-status word to `--message` (issue #514 fallout: --custom-status is gone; herdr
# surfaces the message word as agent_status); older herdr still speaks --custom-status. Try new,
# fall back to old — best-effort either way (the pre-#514 call was already `|| true`).
report_agent_done() {
  herdr pane report-agent "$1" --source rp-sim --agent "$2" --state idle --message "done" >/dev/null 2>&1 \
    || herdr pane report-agent "$1" --source rp-sim --agent "$2" --state idle --custom-status "done" >/dev/null 2>&1 || true
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
  for cp in workspace_created control_room reload_pane_verify_timeout builder_tab pane_labels_on_spawn agent_idle agent_working agent_done \
            pane_captured notify_stubbed reviewer_pane_retired_on_verdict reviewer_pane_close_refused_on_mismatch \
            context_guard_refuses_real_teardown \
            resolver_pane_retired_on_done resolver_pane_kept_on_escalate \
            health_pane_retired_on_outcome \
            builder_agent_alive_claude_root builder_retask_wakes_on_enter builder_agent_dead \
            builder_refix_escalates_on_dead builder_agent_missing teardown_clean; do
    checkpoint "$cp" skip "no herdr — real-pane checkpoint not exercised"
  done
fi

# ── the real-pane path (only when herdr is up) ───────────────────────────────────────────────────
if [ "$HERDR_OK" = true ]; then

  # driver seam (functions only; no side effects) — herd_driver_pane_rename / herd_driver_agent_liveness
  # power the HERD-135 role-label + agent-missing checkpoints below.
  # shellcheck source=scripts/herd/driver.sh
  . "$HERE/../driver.sh"

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

  # ── RELOAD PANE-VERIFY IS BOUNDED (HERD-208): a WEDGED `herdr pane process-info` must ABORT the
  # eyes/verify within the hard timeout — NEVER block. Live 2026-07-09 WSL2: process-info never
  # returned for an existing-but-idle pane, so `herd reload`'s pane-verify hung INDEFINITELY (had to be
  # killed) instead of degrading to the headless watcher. Prove the shipped guard (_reload_timeout in
  # layout-reconcile.sh, the shared "eyes" every mutating path routes through) against a REAL pane:
  # first classify it FAST (non-vacuous baseline), then WEDGE `herdr pane process-info` for that pane
  # via a PATH shim (exec sleep — the wedge shape) and assert the shipped _reload_pane_role returns
  # 'gone' within the per-call timeout. The OUTER `timeout` is the real assertion: the probe RETURNS
  # rather than hanging. This is the PANE-seam reproduction the residual (HERD-208) calls for.
  if [ -n "$WSID" ] && [ -n "$BACKLOG_PANE" ]; then
    step reloadverify "reload pane-verify aborts on a wedged herdr subcall, never blocks (HERD-208)"
    # shellcheck source=scripts/herd/layout-reconcile.sh
    . "$HERE/../layout-reconcile.sh"   # _reload_timeout / _reload_pane_role (functions only, no side effects)
    _rv_role_fast="$(_reload_pane_role "$BACKLOG_PANE" 2>/dev/null || true)"
    # A herdr shim that WEDGES process-info for THIS pane (exec sleep) and forwards everything else to
    # the real/stub herdr — models the WSL2 subcall that never returns.
    RVSHIM="$ART/rvshim"; mkdir -p "$RVSHIM"
    _rv_real="$(command -v herdr 2>/dev/null || true)"
    cat > "$RVSHIM/herdr" <<RVH
#!/usr/bin/env bash
if [ "\${1:-}" = "pane" ] && [ "\${2:-}" = "process-info" ]; then
  case " \$* " in *" $BACKLOG_PANE "*) exec sleep 120 ;; esac
fi
exec "$_rv_real" "\$@"
RVH
    chmod +x "$RVSHIM/herdr"
    # A probe that re-sources the shipped guard with the wedging shim on PATH and classifies the pane.
    cat > "$ART/rv-probe.sh" <<RVP
. "$HERE/../layout-reconcile.sh"
_reload_pane_role "$BACKLOG_PANE"
RVP
    _rv_out="$(timeout 12 env PATH="$RVSHIM:$PATH" HERD_RELOAD_HERDR_TIMEOUT=1 bash "$ART/rv-probe.sh" 2>/dev/null)"; _rv_rc=$?
    if [ -z "$_rv_real" ]; then
      checkpoint reload_pane_verify_timeout skip "herdr not resolvable on PATH to build the wedge shim"
    elif [ "$_rv_role_fast" != gone ] && [ "$_rv_rc" != 124 ] && [ "$_rv_out" = gone ]; then
      checkpoint reload_pane_verify_timeout pass \
        "wedged herdr process-info aborted to 'gone' within the 1s per-call timeout (baseline role '$_rv_role_fast'); reload eyes never block"
    else
      checkpoint reload_pane_verify_timeout fail \
        "verify did not abort cleanly (baseline='$_rv_role_fast' outer_rc=$_rv_rc wedged_out='$_rv_out')"
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

  # ── PANE ROLE LABELS AT SPAWN (HERD-135): the lane names each pane by role via the driver so the
  # coordinator (and the dead-agent-eyes probe) read a pane's role by LABEL instead of guessing from
  # position/cmdline — the fix for the #249 incident where a `claude --continue` was typed into the
  # task-spec viewer pane. Exercise the SHIPPED driver call the lanes use (herd_driver_pane_rename) to
  # label the builder's agent pane with its slug, then assert the label is queryable via herdr JSON.
  if [ -n "$WSID" ] && [ -n "$BUILD_PANE" ]; then
    step labels "name the agent pane by role via the driver (herd_driver_pane_rename)"
    herd_driver_pane_rename "$BUILD_PANE" "rp-builder"
    LBL_OK="$(pane_json "$WSID" | BP="$BUILD_PANE" python3 -c '
import sys,json,os
bp=os.environ["BP"]
try:
    panes=(json.load(sys.stdin).get("result") or {}).get("panes") or []
    print(next((str(p.get("label","")) for p in panes if str(p.get("pane_id",""))==bp), ""))
except Exception:
    print("err")
' 2>/dev/null)"
    if [ "$LBL_OK" = "rp-builder" ]; then
      checkpoint pane_labels_on_spawn pass "agent pane $BUILD_PANE labelled 'rp-builder' via the driver (role readable by the probe)"
    else
      checkpoint pane_labels_on_spawn fail "agent pane label not set as expected (got '$LBL_OK')"
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

    # done (herdr surfaces the custom-status/message word as agent_status).
    herdr pane run "$BUILD_PANE" "printf 'rp stub builder: done\n'" >/dev/null 2>&1 || true
    report_agent_done "$BUILD_PANE" "rp-builder"
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

  # ── notify hermeticity (HERD-139): stub ONLY notify, keep REAL panes ───────────────────────────
  # The lib-mode phases that follow (reviewer-retire, dead-eyes refix) run the DEFAULT herdr-claude
  # driver and call herd_driver_notify → a REAL `herdr notification show` on the operator's desktop
  # (the dead-eyes refix genuinely fires a '💀 agent dead' alarm). Install the shared notify stub HERE
  # — AFTER the timing-sensitive agent-status transition phase above, so the real herdr answers those
  # polls with no added latency (verdicts byte-identical) — a PATH-stubbed `herdr` that intercepts ONLY
  # the `notification` subcommand and FORWARDS every other subcommand to the real herdr. Prove it: a
  # probe notification is CAPTURED (never delivered) while real herdr still answers non-notify calls.
  step notify "real-panes tier stubs ONLY notify (real panes kept; notification captured, not delivered)"
  sim_notify_install "$ART"
  # shellcheck source=scripts/herd/driver.sh
  . "$HERE/../driver.sh"   # herd_driver_notify (functions only; no side effects)
  _rp_before="$(sim_notify_captured_count 'RP NOTIFY PROBE')"
  ( unset HERD_DRIVER; herd_driver_notify "🔔 RP NOTIFY PROBE" "real-panes notify must be stubbed, not delivered" default )
  _rp_after="$(sim_notify_captured_count 'RP NOTIFY PROBE')"
  _rp_herdr_live=no; herdr workspace list >/dev/null 2>&1 && _rp_herdr_live=yes   # forwarded to REAL herdr
  _rp_native="$(sim_notify_native_attempts)"
  if [ "$_rp_after" -gt "$_rp_before" ] && [ "$_rp_herdr_live" = yes ] && [ "$_rp_native" = 0 ]; then
    checkpoint notify_stubbed pass "herdr notification INTERCEPTED to the sink (captured=$_rp_after); real herdr still answers non-notify commands; zero native desktop notifications"
  else
    checkpoint notify_stubbed fail "real-panes notify stub failed (captured before=$_rp_before after=$_rp_after; herdr_live=$_rp_herdr_live; native=$_rp_native)"
  fi

  # ── REVIEWER-PANE LIFECYCLE (HERD-113): the reviewer pane is GONE after its verdict is consumed ──
  # Stand up a REAL review split pane inside the builder's tab (the agent-pane placement herd-review.sh
  # uses), register it in a dispatch-registry row with a waiting PASS verdict, then drive the SHIPPED
  # watcher verdict-consumption path (_review_gate_step, sourced from agent-watch.sh in lib mode) and
  # assert the pane is CLOSED afterward — the fix for the 2026-07-08 incident where a reviewer session
  # sat idle 30+ min after its verdict was read. Exercises the real herdr pane close via the driver seam.
  if [ -n "$WSID" ] && [ -n "$BUILD_PANE" ]; then
    step reviewpane "reviewer pane is retired on verdict consumption (shipped path, real pane)"
    RV_SPLIT="$(herdr pane split "$BUILD_PANE" --direction down --cwd "$REPO" --no-focus 2>/dev/null || true)"
    RV_PANE="$(printf '%s' "$RV_SPLIT" | hj 'd["result"]["pane"]["pane_id"]')"
    [ -n "$RV_PANE" ] && { PANES_CREATED=$((PANES_CREATED+1)); herdr pane rename "$RV_PANE" "review·rp-builder" >/dev/null 2>&1 || true; }
    # Confirm the review pane actually exists before we assert it later disappears (non-vacuous).
    _rv_present() {
      pane_json "$WSID" | RVP="$1" python3 -c '
import sys,json,os
rvp=os.environ["RVP"]
try:
    panes=(json.load(sys.stdin).get("result") or {}).get("panes") or []
    print("yes" if any(str(p.get("pane_id",""))==rvp for p in panes) else "no")
except Exception:
    print("err")
' 2>/dev/null
    }
    if [ -n "$RV_PANE" ] && [ "$(_rv_present "$RV_PANE")" = yes ]; then
      # Isolated trees + registry row + a waiting PASS verdict for a synthetic (pr,sha).
      RVT="$ART/reviewtrees"; mkdir -p "$RVT/.herd"
      RV_PR=555; RV_SHA="rvsha555"; RV_SLUG="rp-builder"
      RV_JOURNAL="$ART/rv-journal.jsonl"; : > "$RV_JOURNAL"
      printf '%s %s\n' "$$" "$RV_PANE" > "$RVT/.review-registry-$RV_PR-$RV_SHA"
      printf 'REVIEW: PASS\n'          > "$RVT/.review-result-$RV_PR-$RV_SHA"
      # Drive the SHIPPED verdict-consumption path in a subshell so agent-watch.sh's globals/functions
      # never clobber this scenario's. HERD_DRIVER defaults to herdr-claude → a REAL `herdr pane close`.
      # HERD_DISPOSABLE_WORKSPACE=1: this scenario runs from the healthcheck's builder WORKTREE, so the
      # HERD-310 pane-mutation guard is armed — declare this a disposable sim close so it retires the
      # scenario's OWN throwaway pane instead of being refused as if it were the operator's control room.
      ( export AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$ART/no-such-config" \
               PROJECT_ROOT="$REPO" WORKTREES_DIR="$RVT" DEFAULT_BRANCH=main HERD_DISPOSABLE_WORKSPACE=1 \
               WORKSPACE_NAME="rp-reviewpane-sim" JOURNAL_FILE="$RV_JOURNAL"
        # shellcheck source=/dev/null
        . "$HERE/../agent-watch.sh" >/dev/null 2>&1 || exit 3
        v="$(_review_gate_step "$RV_PR" "$RV_SLUG" "$RV_SHA" 2>/dev/null)"
        [ "$v" = "PASS" ] || exit 4
      ) ; RV_RC=$?
      # Give herdr a beat to reflect the close, then assert the pane is GONE, the registry row was
      # dropped, and the retirement was journaled.
      _rv_gone="no"; _i=0
      while [ "$_i" -lt 25 ]; do
        [ "$(_rv_present "$RV_PANE")" = no ] && { _rv_gone=yes; break; }
        _i=$((_i+1)); sleep 0.2
      done
      _rv_reg_dropped=no; [ ! -f "$RVT/.review-registry-$RV_PR-$RV_SHA" ] && _rv_reg_dropped=yes
      _rv_journaled=no; grep -q '"event":"reviewer_pane_retired"' "$RV_JOURNAL" 2>/dev/null && _rv_journaled=yes
      if [ "$RV_RC" = 0 ] && [ "$_rv_gone" = yes ] && [ "$_rv_reg_dropped" = yes ] && [ "$_rv_journaled" = yes ]; then
        checkpoint reviewer_pane_retired_on_verdict pass \
          "review pane $RV_PANE closed on verdict consumption; registry row dropped; reviewer_pane_retired journaled"
      else
        checkpoint reviewer_pane_retired_on_verdict fail \
          "pane not retired as expected (gate_rc=$RV_RC pane_gone=$_rv_gone reg_dropped=$_rv_reg_dropped journaled=$_rv_journaled)"
      fi
    else
      checkpoint reviewer_pane_retired_on_verdict fail "could not stand up the review split pane (RV_PANE='$RV_PANE')"
    fi
  fi

  # ── GUARDED PANE CLOSE (HERD-134): a stale/recycled registry pane id must NEVER kill a neighbour ──
  # Model the 2026-07-08 incident directly: plant a reviewer dispatch-registry row that points at the
  # BUILDER's OWN pane (exactly as a stale/recycled id would), then drive the SHIPPED verdict-consumption
  # path (_retire_reviewer_pane via _review_gate_step). The guarded close reads the pane's LIVE identity
  # (agent:rp-builder — NOT a reviewer) and must REFUSE: assert the builder pane SURVIVES, a
  # pane_close_refused is journaled with both identities, and NO reviewer_pane_retired is emitted (the
  # decoy was never retired). The reviewpane checkpoint above already proves a genuine reviewer still
  # closes — together they show the guard is byte-identical on a match and loud-refusing on a mismatch.
  if [ -n "$WSID" ] && [ -n "$BUILD_PANE" ]; then
    step guardedclose "a stale registry id pointing at the builder is REFUSED, not closed (HERD-134)"
    _bp_present() {
      pane_json "$WSID" | BPP="$1" python3 -c '
import sys,json,os
bpp=os.environ["BPP"]
try:
    panes=(json.load(sys.stdin).get("result") or {}).get("panes") or []
    print("yes" if any(str(p.get("pane_id",""))==bpp for p in panes) else "no")
except Exception:
    print("err")
' 2>/dev/null
    }
    if [ "$(_bp_present "$BUILD_PANE")" = yes ]; then
      GDT="$ART/guardtrees"; mkdir -p "$GDT/.herd"
      GD_PR=556; GD_SHA="gdsha556"; GD_SLUG="rp-builder"
      GD_JOURNAL="$ART/gd-journal.jsonl"; : > "$GD_JOURNAL"
      # Registry row points at the BUILDER pane (the stale/recycled-id hazard); a PASS verdict waits.
      printf '%s %s\n' "$$" "$BUILD_PANE" > "$GDT/.review-registry-$GD_PR-$GD_SHA"
      printf 'REVIEW: PASS\n'            > "$GDT/.review-result-$GD_PR-$GD_SHA"
      # Drive the SHIPPED path in a subshell (same isolation the reviewpane step uses). HERD_DRIVER
      # defaults to herdr-claude → a REAL identity probe + `herdr pane close` behind the guard.
      ( export AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$ART/no-such-config" \
               PROJECT_ROOT="$REPO" WORKTREES_DIR="$GDT" DEFAULT_BRANCH=main \
               WORKSPACE_NAME="rp-guardedclose-sim" JOURNAL_FILE="$GD_JOURNAL"
        # shellcheck source=/dev/null
        . "$HERE/../agent-watch.sh" >/dev/null 2>&1 || exit 3
        _review_gate_step "$GD_PR" "$GD_SLUG" "$GD_SHA" >/dev/null 2>&1 || true
      )
      # Assert the builder pane SURVIVES across a short window (a wrong close would remove it).
      _bp_survived=yes; _i=0
      while [ "$_i" -lt 12 ]; do
        [ "$(_bp_present "$BUILD_PANE")" = yes ] || { _bp_survived=no; break; }
        _i=$((_i+1)); sleep 0.2
      done
      _gd_refused=no; grep -q '"event":"pane_close_refused"' "$GD_JOURNAL" 2>/dev/null && _gd_refused=yes
      _gd_retired=no; grep -q '"event":"reviewer_pane_retired"' "$GD_JOURNAL" 2>/dev/null && _gd_retired=yes
      if [ "$_bp_survived" = yes ] && [ "$_gd_refused" = yes ] && [ "$_gd_retired" = no ]; then
        checkpoint reviewer_pane_close_refused_on_mismatch pass \
          "stale registry id → builder pane $BUILD_PANE SURVIVED; pane_close_refused journaled; no false retire"
      else
        checkpoint reviewer_pane_close_refused_on_mismatch fail \
          "guard did not refuse as expected (builder_survived=$_bp_survived refused=$_gd_refused false_retire=$_gd_retired)"
      fi
    else
      checkpoint reviewer_pane_close_refused_on_mismatch fail "builder pane not present to serve as decoy (BUILD_PANE='$BUILD_PANE')"
    fi
  fi

  # ── CONTEXT-GUARD (HERD-310): a test-side TAB teardown against the LIVE control room is REFUSED ─────
  # Reproduce the 2026-07-10 incident directly against REAL panes. A test run from a builder WORKTREE
  # drove herd_teardown_slug against the operator's LIVE socket and closed the {slug, review·slug,
  # resolve·slug} tabs — severing an in-flight review and killing the builder agent. Here the FIXTURE
  # workspace plays the operator's control room: we call the SHIPPED herd_teardown_slug on the builder
  # slug from a WORKTREE context (WORKTREES_DIR + cwd inside it) with a NON-disposable WORKSPACE_NAME,
  # and assert the shared guard (herd_context_pane_guard, HERD-310) REFUSES it: the builder pane/tab
  # SURVIVES and a control_pane_mutation_refused is journaled. Non-vacuous: the refusal event only
  # exists if the guard reached a would-be close and withheld it. (The disposable-workspace ALLOW
  # direction — where a real sandbox-* sim tears down its own panes — is proven in the hermetic unit
  # tests/test-context-guard-panes.sh; exercising it HERE would close the builder tab the downstream
  # resolver/teardown checkpoints still need.)
  if [ -n "$WSID" ] && [ -n "${BUILD_TAB:-}" ] && [ -n "$BUILD_PANE" ]; then
    step contextguard "a WORKTREE-context herd_teardown_slug against the live room is REFUSED (HERD-310)"
    _cg_present() {
      pane_json "$WSID" | CGP="$1" python3 -c '
import sys,json,os
cgp=os.environ["CGP"]
try:
    panes=(json.load(sys.stdin).get("result") or {}).get("panes") or []
    print("yes" if any(str(p.get("pane_id",""))==cgp for p in panes) else "no")
except Exception:
    print("err")
' 2>/dev/null
    }
    if [ "$(_cg_present "$BUILD_PANE")" = yes ]; then
      CGT="$ART/cg-trees"; mkdir -p "$CGT/wt/.herd"
      CG_JOURNAL="$ART/cg-journal.jsonl"; : > "$CG_JOURNAL"
      # Drive the SHIPPED teardown from a builder WORKTREE (cwd inside WORKTREES_DIR ⇒ clause B) against
      # a NON-disposable workspace name, so the guard must refuse. journal.sh first so the refusal
      # journals; herd-config.sh (which sources context-guard.sh + defines herd_teardown_slug) next.
      ( cd "$CGT/wt" || exit 9
        export WORKTREES_DIR="$CGT" WORKSPACE_NAME="rp-contextguard-operator" \
               HERD_CONFIG_FILE="$ART/no-such-config" JOURNAL_FILE="$CG_JOURNAL"
        # shellcheck source=/dev/null
        . "$HERE/../journal.sh" >/dev/null 2>&1 || exit 8
        # shellcheck source=/dev/null
        . "$HERE/../herd-config.sh" >/dev/null 2>&1 || exit 7
        herd_teardown_slug "rp-builder" >/dev/null 2>&1 || true
      )
      # The builder pane must SURVIVE (a would-be close would remove it), and the refusal must journal.
      _cg_survived=yes; _i=0
      while [ "$_i" -lt 12 ]; do
        [ "$(_cg_present "$BUILD_PANE")" = yes ] || { _cg_survived=no; break; }
        _i=$((_i+1)); sleep 0.2
      done
      _cg_refused=no; grep -q '"event":"control_pane_mutation_refused"' "$CG_JOURNAL" 2>/dev/null && _cg_refused=yes
      if [ "$_cg_survived" = yes ] && [ "$_cg_refused" = yes ]; then
        checkpoint context_guard_refuses_real_teardown pass \
          "worktree-context herd_teardown_slug REFUSED: builder pane $BUILD_PANE SURVIVED; control_pane_mutation_refused journaled; ZERO real closes"
      else
        checkpoint context_guard_refuses_real_teardown fail \
          "guard did not refuse the teardown (builder_survived=$_cg_survived refused=$_cg_refused)"
      fi
    else
      checkpoint context_guard_refuses_real_teardown fail "builder pane not present to protect (BUILD_PANE='$BUILD_PANE')"
    fi
  fi

  # ── RESOLVER-PANE LIFECYCLE (HERD-280): retired on DONE, KEPT on ESCALATE ─────────────────────────
  # The resolver is a pane that retires on result-consumed, exactly like a reviewer pane — but its two
  # verdicts part ways. Stand up a REAL resolve split pane inside the builder's tab (the placement
  # herd-resolve.sh uses under RESOLVER_PANE=on), plant its dispatch-registry row plus a waiting verdict,
  # and drive the SHIPPED watcher reconcile (_reconcile_resolver_panes, sourced from agent-watch.sh in
  # lib mode) against a REAL herdr pane close:
  #   DONE     → the pane is CLOSED, the row dropped, resolver_pane_retired journaled … and the WORKTREE
  #              is untouched (the retirement invariant, not this path, reaps the tree at merge).
  #   ESCALATE → the pane STAYS. It is the evidence the needs-you row sends a human to read.
  # Each leg gets its own $TREES + journal so "no retire happened" is an honest assertion.
  if [ -n "$WSID" ] && [ -n "$BUILD_PANE" ]; then
    step resolverpane "resolver pane retires on DONE and survives ESCALATE (shipped path, real panes)"
    _rs_present() {
      pane_json "$WSID" | RSP="$1" python3 -c '
import sys,json,os
rsp=os.environ["RSP"]
try:
    panes=(json.load(sys.stdin).get("result") or {}).get("panes") or []
    print("yes" if any(str(p.get("pane_id",""))==rsp for p in panes) else "no")
except Exception:
    print("err")
' 2>/dev/null
    }
    # Split a real resolver pane into the builder's tab and label it with the resolver identity the
    # HERD-134 guarded close proves against before closing. Runs in a command substitution, so the
    # PANES_CREATED bookkeeping stays with the caller (a subshell's increment would be lost).
    _rs_split_pane() {
      local _out _pane
      _out="$(herdr pane split "$BUILD_PANE" --direction down --cwd "$REPO" --no-focus 2>/dev/null || true)"
      _pane="$(printf '%s' "$_out" | hj 'd["result"]["pane"]["pane_id"]')"
      [ -n "$_pane" ] && herdr pane rename "$_pane" "resolve·rp-builder" >/dev/null 2>&1 || true
      printf '%s' "$_pane"
    }
    # Run the shipped reconcile against <trees> in a subshell so agent-watch.sh's globals never clobber
    # this scenario's. HERD_DRIVER defaults to herdr-claude → a REAL `herdr pane close` behind the guard.
    _rs_reconcile() {
      # HERD_DISPOSABLE_WORKSPACE=1: as with the reviewer retire above, this real close runs from the
      # healthcheck's builder worktree — declare it a disposable sim close so the HERD-310 guard allows
      # the scenario to retire its OWN throwaway resolver pane (never the operator's control room).
      ( export AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$ART/no-such-config" \
               PROJECT_ROOT="$REPO" WORKTREES_DIR="$1" DEFAULT_BRANCH=main RESOLVER_PANE=on HERD_DISPOSABLE_WORKSPACE=1 \
               WORKSPACE_NAME="rp-resolverpane-sim" JOURNAL_FILE="$2"
        # shellcheck source=/dev/null
        . "$HERE/../agent-watch.sh" >/dev/null 2>&1 || exit 3
        _reconcile_resolver_panes
      )
    }

    # ── leg 1: RESOLVE: DONE → the pane is retired, the worktree is not ──────────────────────────────
    RS_PANE="$(_rs_split_pane)"; [ -n "$RS_PANE" ] && PANES_CREATED=$((PANES_CREATED+1))
    if [ -n "$RS_PANE" ] && [ "$(_rs_present "$RS_PANE")" = yes ]; then
      RST="$ART/resolvetrees"; mkdir -p "$RST/.herd"
      RS_WT="$RST/rp-builder"; mkdir -p "$RS_WT"          # the worktree that must SURVIVE the retire
      RS_JOURNAL="$ART/rs-journal.jsonl"; : > "$RS_JOURNAL"
      printf '%s - split 601 rssha601\n' "$RS_PANE" > "$RST/.resolve-registry-601-rssha601"
      printf 'RESOLVE: DONE\n'                      > "$RST/.resolve-result-601-rssha601"
      _rs_reconcile "$RST" "$RS_JOURNAL"; RS_RC=$?
      _rs_gone="no"; _i=0
      while [ "$_i" -lt 25 ]; do
        [ "$(_rs_present "$RS_PANE")" = no ] && { _rs_gone=yes; break; }
        _i=$((_i+1)); sleep 0.2
      done
      _rs_reg_dropped=no; [ ! -f "$RST/.resolve-registry-601-rssha601" ] && _rs_reg_dropped=yes
      _rs_journaled=no; grep -q '"event":"resolver_pane_retired"' "$RS_JOURNAL" 2>/dev/null && _rs_journaled=yes
      _rs_consumed=no; grep -q '"reason":"result-consumed"' "$RS_JOURNAL" 2>/dev/null && _rs_consumed=yes
      _rs_wt=no; [ -d "$RS_WT" ] && _rs_wt=yes
      if [ "$RS_RC" = 0 ] && [ "$_rs_gone" = yes ] && [ "$_rs_reg_dropped" = yes ] \
         && [ "$_rs_journaled" = yes ] && [ "$_rs_consumed" = yes ] && [ "$_rs_wt" = yes ]; then
        checkpoint resolver_pane_retired_on_done pass \
          "resolve pane $RS_PANE closed on DONE; row dropped; resolver_pane_retired reason=result-consumed journaled; worktree still present"
      else
        checkpoint resolver_pane_retired_on_done fail \
          "pane not retired as expected (rc=$RS_RC gone=$_rs_gone reg_dropped=$_rs_reg_dropped journaled=$_rs_journaled consumed=$_rs_consumed worktree=$_rs_wt)"
      fi
    else
      checkpoint resolver_pane_retired_on_done fail "could not stand up the resolve split pane (RS_PANE='$RS_PANE')"
    fi

    # ── leg 2: RESOLVE: ESCALATE → the pane stays open for the human ─────────────────────────────────
    ES_PANE="$(_rs_split_pane)"; [ -n "$ES_PANE" ] && PANES_CREATED=$((PANES_CREATED+1))
    if [ -n "$ES_PANE" ] && [ "$(_rs_present "$ES_PANE")" = yes ]; then
      EST="$ART/escalatetrees"; mkdir -p "$EST/.herd"
      ES_JOURNAL="$ART/es-journal.jsonl"; : > "$ES_JOURNAL"
      printf '%s - split 602 essha602\n' "$ES_PANE" > "$EST/.resolve-registry-602-essha602"
      printf 'RESOLVE: ESCALATE\n'                  > "$EST/.resolve-result-602-essha602"
      _rs_reconcile "$EST" "$ES_JOURNAL"           # two ticks: a later one must not change its mind
      _rs_reconcile "$EST" "$ES_JOURNAL"; ES_RC=$?
      _es_alive=yes; _i=0
      while [ "$_i" -lt 12 ]; do
        [ "$(_rs_present "$ES_PANE")" = yes ] || { _es_alive=no; break; }
        _i=$((_i+1)); sleep 0.2
      done
      _es_reg_kept=no; [ -f "$EST/.resolve-registry-602-essha602" ] && _es_reg_kept=yes
      _es_retired=no; grep -q '"event":"resolver_pane_retired"' "$ES_JOURNAL" 2>/dev/null && _es_retired=yes
      if [ "$ES_RC" = 0 ] && [ "$_es_alive" = yes ] && [ "$_es_reg_kept" = yes ] && [ "$_es_retired" = no ]; then
        checkpoint resolver_pane_kept_on_escalate pass \
          "escalated resolve pane $ES_PANE still open across two reconcile ticks; row kept; no retire journaled"
      else
        checkpoint resolver_pane_kept_on_escalate fail \
          "escalated pane not preserved (rc=$ES_RC alive=$_es_alive reg_kept=$_es_reg_kept false_retire=$_es_retired)"
      fi
    else
      checkpoint resolver_pane_kept_on_escalate fail "could not stand up the escalate split pane (ES_PANE='$ES_PANE')"
    fi
  fi

  # ── HEALTH-PANE LIFECYCLE (HERD-313 leg a): retired the instant the suite ENDS ─────────────────────
  # The disposable `health·<slug>` view pane is a plain tail of the live suite log (no agent, no model);
  # it is stamped with a `health·<slug>` label so the HERD-134 guarded close recognizes it, and the
  # watcher's per-tick reconcile retires it the moment the (pr,sha) inflight marker is gone (the suite
  # finished/collected/died). Stand up a REAL split pane labelled `health·rp-builder`, plant its registry
  # row with NO inflight marker (the ended state), drive the SHIPPED reconcile (_reconcile_health_panes,
  # from agent-watch.sh in lib mode) against a REAL herdr pane close, and assert the pane is CLOSED, the
  # row dropped, and health_pane_retired journaled — the disposable-pane analogue of the reviewer/resolver
  # retire legs above.
  if [ -n "$WSID" ] && [ -n "$BUILD_PANE" ]; then
    step healthpane "health pane retires on outcome (shipped reconcile, real pane)"
    HP_SPLIT="$(herdr pane split "$BUILD_PANE" --direction down --cwd "$REPO" --no-focus 2>/dev/null || true)"
    HP_PANE="$(printf '%s' "$HP_SPLIT" | hj 'd["result"]["pane"]["pane_id"]')"
    [ -n "$HP_PANE" ] && { PANES_CREATED=$((PANES_CREATED+1)); herdr pane rename "$HP_PANE" "health·rp-builder" >/dev/null 2>&1 || true; }
    _hp_present() {
      pane_json "$WSID" | HPP="$1" python3 -c '
import sys,json,os
hpp=os.environ["HPP"]
try:
    panes=(json.load(sys.stdin).get("result") or {}).get("panes") or []
    print("yes" if any(str(p.get("pane_id",""))==hpp for p in panes) else "no")
except Exception:
    print("err")
' 2>/dev/null
    }
    if [ -n "$HP_PANE" ] && [ "$(_hp_present "$HP_PANE")" = yes ]; then
      HPT="$ART/healthtrees"; mkdir -p "$HPT/.herd"
      HP_PR=557; HP_SHA="hpsha557"
      HP_JOURNAL="$ART/hp-journal.jsonl"; : > "$HP_JOURNAL"
      # Registry row for an ENDED suite (no .health-inflight-* marker planted ⇒ reconcile retires it).
      printf '%s - health·rp-builder\n' "$HP_PANE" > "$HPT/.health-pane-registry-$HP_PR-$HP_SHA"
      # HERD_DISPOSABLE_WORKSPACE=1: the real close runs from the healthcheck's builder worktree, so the
      # HERD-310 guard is armed — declare a disposable sim close so it retires the scenario's OWN pane.
      ( export AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$ART/no-such-config" \
               PROJECT_ROOT="$REPO" WORKTREES_DIR="$HPT" DEFAULT_BRANCH=main HEALTH_PANE=on HERD_DISPOSABLE_WORKSPACE=1 \
               WORKSPACE_NAME="rp-healthpane-sim" JOURNAL_FILE="$HP_JOURNAL"
        # shellcheck source=/dev/null
        . "$HERE/../agent-watch.sh" >/dev/null 2>&1 || exit 3
        _reconcile_health_panes
      ) ; HP_RC=$?
      _hp_gone="no"; _i=0
      while [ "$_i" -lt 25 ]; do
        [ "$(_hp_present "$HP_PANE")" = no ] && { _hp_gone=yes; break; }
        _i=$((_i+1)); sleep 0.2
      done
      _hp_reg_dropped=no; [ ! -f "$HPT/.health-pane-registry-$HP_PR-$HP_SHA" ] && _hp_reg_dropped=yes
      _hp_journaled=no; grep -q '"event":"health_pane_retired"' "$HP_JOURNAL" 2>/dev/null && _hp_journaled=yes
      if [ "$HP_RC" = 0 ] && [ "$_hp_gone" = yes ] && [ "$_hp_reg_dropped" = yes ] && [ "$_hp_journaled" = yes ]; then
        checkpoint health_pane_retired_on_outcome pass \
          "health pane $HP_PANE closed once the suite ended; registry row dropped; health_pane_retired journaled"
      else
        checkpoint health_pane_retired_on_outcome fail \
          "pane not retired as expected (rc=$HP_RC gone=$_hp_gone reg_dropped=$_hp_reg_dropped journaled=$_hp_journaled)"
      fi
    else
      checkpoint health_pane_retired_on_outcome fail "could not stand up the health split pane (HP_PANE='$HP_PANE')"
    fi
  fi

  # ── CLAUDE-AS-ROOT LIVENESS (PR #260 review): the lane launches claude DIRECTLY as the pane ROOT
  # (`herdr agent start … -- claude`, no wrapping shell), so the pane's shell_pid IS the claude pid. The
  # probe excludes the pane's shell so a BARE shell reads 'dead' — but it must NOT drop the shell_pid
  # entry when that entry is ITSELF claude, or it fabricates a death for a live idle builder ('💀 AGENT
  # DEAD'). Stand up a REAL claude-as-root pane via the lane's exact incantation and assert the SHIPPED
  # probe reads 'alive'. The killed-pane 'dead' + removed-pane 'missing' checkpoints below cover the
  # other two liveness verdicts; together the three prove the classifier end to end.
  if [ -n "$WSID" ] && [ -n "$BUILD_TAB" ]; then
    step clauderoot "claude launched AS the pane root (shell_pid == claude pid) reads 'alive', not a fabricated death"
    CR_BIN="$ART/clauderootbin"; mkdir -p "$CR_BIN"
    # A resident fake claude whose cmdline retains 'claude' (a bash script sleeping until killed).
    printf '#!/usr/bin/env bash\nsleep 3600\n' > "$CR_BIN/claude"; chmod +x "$CR_BIN/claude"
    # Stand the pane up CLI-agnostically (issue #514): herdr ≥0.7.5 `agent start` no longer creates
    # panes and its --kind runs the CANONICAL executable, so it cannot launch this stub. Split a real
    # pane and `exec` the stub as the pane's ROOT process — the exact shell_pid == claude-pid shape
    # the pre-0.7.5 lane's `agent start … -- claude` produced (and old-herdr machines still produce).
    CR_SPLIT="$(herdr pane split "$BUILD_PANE" --direction down --cwd "$REPO" --no-focus 2>/dev/null || true)"
    CR_PANE="$(printf '%s' "$CR_SPLIT" | hj 'd["result"]["pane"]["pane_id"]')"
    if [ -n "$CR_PANE" ]; then
      herdr pane run "$CR_PANE" "exec $CR_BIN/claude" >/dev/null 2>&1 || true
      # Register the identity the probe resolves (the pre-0.7.5 flow registered it via agent start).
      herdr pane report-agent "$CR_PANE" --source rp-sim --agent "cair-root-builder" --state working >/dev/null 2>&1 || true
    fi
    [ -z "$CR_PANE" ] && CR_PANE="$(herd_driver_agent_pane_id cair-root-builder 2>/dev/null || true)"
    [ -n "$CR_PANE" ] && PANES_CREATED=$((PANES_CREATED+1))
    # Poll until the probe sees the live claude root.
    _cr_live="no"; _i=0
    while [ "$_i" -lt 25 ]; do
      [ "$(herd_driver_agent_liveness cair-root-builder "$CR_PANE" 2>/dev/null)" = "alive" ] && { _cr_live=yes; break; }
      _i=$((_i+1)); sleep 0.2
    done
    # NON-VACUOUS: prove the pane really IS claude-as-root — the shell_pid appears AMONG the foreground
    # processes with 'claude' in its cmdline (the exact shape that fooled the pre-fix classifier).
    _cr_isroot="$(herdr pane process-info --pane "$CR_PANE" 2>/dev/null | python3 -c '
import sys,json
pi=(json.load(sys.stdin).get("result") or {}).get("process_info") or {}
sh=pi.get("shell_pid"); fps=pi.get("foreground_processes") or []
print("yes" if any(p.get("pid")==sh and "claude" in (p.get("cmdline") or "") for p in fps) else "no")
' 2>/dev/null || true)"
    _cr_pgid="$(herdr pane process-info --pane "$CR_PANE" 2>/dev/null | python3 -c '
import sys,json
pi=(json.load(sys.stdin).get("result") or {}).get("process_info") or {}
print(pi.get("foreground_process_group_id") or "")
' 2>/dev/null || true)"
    if [ "$_cr_live" = yes ] && [ "$_cr_isroot" = yes ]; then
      checkpoint builder_agent_alive_claude_root pass \
        "claude-as-root pane $CR_PANE (shell_pid == claude pid) reads 'alive' — the pane-shell exclusion did not fabricate a death"
    else
      checkpoint builder_agent_alive_claude_root fail \
        "claude-as-root liveness wrong (live=$_cr_live is_root=$_cr_isroot pane=$CR_PANE)"
    fi
    # Cleanup: kill the detached claude process GROUP + close its pane (never leak a sleep or a pane).
    [ -n "$_cr_pgid" ] && kill -TERM -"$_cr_pgid" >/dev/null 2>&1 || true
    [ -n "$CR_PANE" ] && herdr pane close "$CR_PANE" >/dev/null 2>&1 || true
  fi

  # ── RE-TASK WAKE (HERD-186): a live 'done' builder must WAKE when the auto-refix bounce types the
  # re-task prompt AND submits Enter. Live 2026-07-08: `herdr pane run` alone left text in the agent
  # prompt buffer (REVIEW_AUTOFIX + coordinator nudges silently no-op'd until a human Enter). Drives
  # the SHIPPED path (_handle_block_verdict → herd_driver_send_text: pane run + send-keys Enter) against
  # REAL panes with a live session, then asserts refix_wake_result woke=1 and agent_status=working.
  # The sandbox has no model to flip status on its own, so a thin PATH wrapper simulates the agent's
  # reaction: after a review-blocked pane run + Enter on the builder pane, report-agent → working.
  # That proves the SHIPPED submit sequence ran end-to-end (without the Enter, the wrapper never flips
  # and the bounce escalates woke=0). Runs BEFORE deadeyes so the builder pane is still wakeable.
  if [ -n "$WSID" ] && [ -n "$BUILD_PANE" ]; then
    step retask "re-task a done builder via type+Enter; assert the agent wakes (HERD-186)"
    # shellcheck source=scripts/herd/driver.sh
    . "$HERE/../driver.sh"

    # Live session on the builder pane so the liveness probe is 'alive' (not dead → escalate).
    WAKE_CLAUDE_BIN="$ART/wakeclaudebin"; mkdir -p "$WAKE_CLAUDE_BIN"
    printf '#!/usr/bin/env bash\nsleep 3600\n' > "$WAKE_CLAUDE_BIN/claude"; chmod +x "$WAKE_CLAUDE_BIN/claude"
    herdr pane run "$BUILD_PANE" "$WAKE_CLAUDE_BIN/claude" >/dev/null 2>&1 || true
    _wake_alive=no; _i=0
    while [ "$_i" -lt 25 ]; do
      [ "$(herd_driver_agent_liveness rp-builder "$BUILD_PANE" 2>/dev/null)" = "alive" ] && { _wake_alive=yes; break; }
      _i=$((_i+1)); sleep 0.2
    done
    # Builder reads 'done' (session still up, awaiting re-task) — the HERD-186 stuck-prompt shape.
    report_agent_done "$BUILD_PANE" "rp-builder"

    if [ "$_wake_alive" = yes ]; then
      WT="$ART/waketrees"; mkdir -p "$WT"
      W_JOURNAL="$ART/wake-journal.jsonl"; : > "$W_JOURNAL"
      W_DISPLAY="$ART/wake-display.txt"; : > "$W_DISPLAY"
      W_MARK="$ART/wake-pending"; rm -f "$W_MARK"
      # PATH wrapper: forward everything; on send-keys Enter after a review-blocked run to BUILD_PANE,
      # flip the agent to working (the sandbox agent has no model to react itself).
      W_SHIM="$ART/wake-shim"; mkdir -p "$W_SHIM"
      _w_real="$(command -v herdr 2>/dev/null || true)"
      cat > "$W_SHIM/herdr" <<WAKEHERDR
#!/usr/bin/env bash
_real="$_w_real"
_pane="${BUILD_PANE}"
_mark="${W_MARK}"
if [ "\${1:-}" = "pane" ] && [ "\${2:-}" = "run" ] && [ "\${3:-}" = "\$_pane" ]; then
  case "\${4:-}" in *review-blocked*) printf '%s\n' "\$_pane" > "\$_mark" 2>/dev/null || true ;; esac
fi
if [ "\${1:-}" = "pane" ] && [ "\${2:-}" = "send-keys" ] && [ "\${3:-}" = "\$_pane" ]; then
  _keys="\$*"
  if [ -f "\$_mark" ] && case " \$_keys " in *" Enter "*) true ;; *) false ;; esac; then
    if [ -n "\$_real" ] && [ -x "\$_real" ]; then "\$_real" "\$@" || true; else true; fi
    "\$_real" pane report-agent "\$_pane" --source rp-sim --agent "rp-builder" --state working >/dev/null 2>&1 || true
    rm -f "\$_mark"
    exit 0
  fi
fi
if [ -n "\$_real" ] && [ -x "\$_real" ]; then exec "\$_real" "\$@"; fi
exit 0
WAKEHERDR
      chmod +x "$W_SHIM/herdr"
      (
        export PATH="$W_SHIM:$PATH"
        export AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$ART/no-such-config" \
               PROJECT_ROOT="$REPO" WORKTREES_DIR="$WT" DEFAULT_BRANCH=main \
               WORKSPACE_NAME="rp-retask-sim" JOURNAL_FILE="$W_JOURNAL" \
               HERD_REFIX_WAIT_TIMEOUT=8
        # shellcheck source=/dev/null
        . "$HERE/../agent-watch.sh" >/dev/null 2>&1 || exit 3
        render() { :; }
        # Speedy poll: no real multi-second sleeps; the wrapper flips status on Enter immediately.
        sleep() { :; }
        date() {
          if [ "${1:-}" = "+%s" ]; then
            # Advance a file-backed clock so the backed-off wait window terminates quickly.
            local _c="$WT/.mock-clock"; local n
            n=$(( $(cat "$_c" 2>/dev/null || echo 1000) + 1 )); echo "$n" > "$_c"; printf '%s\n' "$n"
          else command date "$@"; fi
        }
        REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
        DISPLAY=()
        _handle_block_verdict "186" "rp-builder" "wakesha186" "0" || true
        printf '%s' "${DISPLAY[0]:-}" > "$W_DISPLAY"
      ) ; W_RC=$?
      _w_st="$(agent_status_of rp-builder)"
      _w_woke=no; grep -q '"event":"refix_wake_result"' "$W_JOURNAL" 2>/dev/null \
        && grep 'refix_wake_result' "$W_JOURNAL" | tail -1 | grep -q '"woke":1' && _w_woke=yes
      _w_enter=no; [ ! -f "$W_MARK" ] && _w_enter=yes   # mark consumed ⇒ Enter path ran
      if [ "$W_RC" = 0 ] && [ "$_w_woke" = yes ] && [ "$_w_st" = working ]; then
        checkpoint builder_retask_wakes_on_enter pass \
          "type+Enter re-task woke the done builder (refix_wake_result woke=1; agent_status=working)"
      else
        checkpoint builder_retask_wakes_on_enter fail \
          "re-task did not wake (rc=$W_RC woke=$_w_woke status='$_w_st' enter_consumed=$_w_enter disp='$(cat "$W_DISPLAY" 2>/dev/null | tr -d '\n')')"
      fi
      # Reset agent to done for the deadeyes step that follows (it expects a non-working target).
      report_agent_done "$BUILD_PANE" "rp-builder"
    else
      checkpoint builder_retask_wakes_on_enter fail \
        "could not stand up a live session to re-task (liveness='$(herd_driver_agent_liveness rp-builder "$BUILD_PANE" 2>/dev/null)')"
    fi
  fi

  # ── DEAD-AGENT EYES (HERD-114): kill the builder's pane process, assert the liveness probe flips to
  # 'dead' and a refix bounce ESCALATES (needs you · agent dead) instead of waking a dead pane. Models
  # the 2026-07-08 incident where a herdr server stop killed a builder's claude while its pane/PR
  # persisted and a REVIEW_AUTOFIX bounce would have typed a re-task into the dead pane. Drives the
  # SHIPPED probe (herd_driver_agent_liveness) + the SHIPPED refix path (_handle_block_verdict, sourced
  # in lib mode) against REAL panes. The stub builder has no real claude, so we stand up a long-lived
  # foreground process WITH a 'claude' argv0 as the live session, then kill it to strand a bare pane.
  if [ -n "$WSID" ] && [ -n "$BUILD_PANE" ]; then
    step deadeyes "kill the builder pane process → agent-dead; a refix bounce escalates, never wakes"
    # shellcheck source=scripts/herd/driver.sh
    . "$HERE/../driver.sh"   # herd_driver_agent_liveness (functions only; no side effects)

    # the pane's foreground PROCESS GROUP id (the running job; == shell_pid when the shell is idle)
    _fg_pgid() {
      herdr pane process-info --pane "$1" 2>/dev/null | python3 -c '
import sys,json
try: pi=(json.load(sys.stdin).get("result") or {}).get("process_info") or {}
except Exception: pi={}
print(pi.get("foreground_process_group_id") or "")
' 2>/dev/null
    }
    _live_of() { herd_driver_agent_liveness rp-builder "$BUILD_PANE" 2>/dev/null; }

    # 1) Stand up the "live session": the stub builder has no real claude, so run a long-lived
    #    foreground process whose cmdline contains 'claude' (an executable literally named `claude`
    #    that sleeps) — the same signal herd_driver_agent_liveness reads for a real builder. NOT
    #    exec'd, so the pane's shell stays the parent and returns to a bare prompt once we kill the job.
    CLAUDE_BIN="$ART/claudebin"; mkdir -p "$CLAUDE_BIN"
    printf '#!/usr/bin/env bash\nsleep 3600\n' > "$CLAUDE_BIN/claude"; chmod +x "$CLAUDE_BIN/claude"
    _pgid_before=""
    herdr pane run "$BUILD_PANE" "$CLAUDE_BIN/claude" >/dev/null 2>&1 || true
    _alive="no"; _i=0
    while [ "$_i" -lt 25 ]; do
      [ "$(_live_of)" = "alive" ] && { _alive=yes; _pgid_before="$(_fg_pgid "$BUILD_PANE")"; break; }
      _i=$((_i+1)); sleep 0.2
    done

    if [ "$_alive" = yes ]; then
      # 2) Kill the pane's foreground JOB (whole process group) → the pane falls back to a bare shell.
      [ -n "$_pgid_before" ] && kill -TERM -"$_pgid_before" >/dev/null 2>&1 || true
      _dead="no"; _i=0
      while [ "$_i" -lt 25 ]; do [ "$(_live_of)" = "dead" ] && { _dead=yes; break; }; _i=$((_i+1)); sleep 0.2; done
      if [ "$_dead" = yes ]; then
        checkpoint builder_agent_dead pass "killed pane process; herd_driver_agent_liveness flipped alive→dead"
      else
        checkpoint builder_agent_dead fail "liveness did not flip to dead after the pane process was killed (got '$(_live_of)')"
      fi
    else
      checkpoint builder_agent_dead fail "could not stand up a live 'claude' foreground to kill (liveness='$(_live_of)')"
    fi

    # 3) Drive the SHIPPED refix bounce against the now-dead builder and assert it ESCALATES (needs you
    #    · agent dead) and never wakes. Isolated trees/journal + REVIEW_AUTOFIX on. A subshell so
    #    agent-watch.sh's globals never clobber the scenario's.
    if [ "${_dead:-no}" = yes ]; then
      BVT="$ART/deadtrees"; mkdir -p "$BVT"
      BV_JOURNAL="$ART/bv-journal.jsonl"; : > "$BV_JOURNAL"
      BV_DISPLAY="$ART/bv-display.txt"; : > "$BV_DISPLAY"
      ( export AGENT_WATCH_LIB=1 HERD_CONFIG_FILE="$ART/no-such-config" \
               PROJECT_ROOT="$REPO" WORKTREES_DIR="$BVT" DEFAULT_BRANCH=main \
               WORKSPACE_NAME="rp-deadeyes-sim" JOURNAL_FILE="$BV_JOURNAL"
        # shellcheck source=/dev/null
        . "$HERE/../agent-watch.sh" >/dev/null 2>&1 || exit 3
        render() { :; }
        REVIEW_AUTOFIX=true; DRYRUN=""; REFIX_MAX_ROUNDS=3
        DISPLAY=()
        _handle_block_verdict "600" "rp-builder" "deadsha600" "0" || true
        printf '%s' "${DISPLAY[0]:-}" > "$BV_DISPLAY"
      ) ; BV_RC=$?
      _bv_disp="$(cat "$BV_DISPLAY" 2>/dev/null || true)"
      _bv_escalated=no; printf '%s' "$_bv_disp" | grep -q "agent dead" && _bv_escalated=yes
      _bv_journaled=no; grep -q '"event":"refix_escalated_dead"' "$BV_JOURNAL" 2>/dev/null && _bv_journaled=yes
      # "escalates instead of waking": the escalation event is present AND the wake-result event is NOT.
      _bv_no_wake=no; grep -q '"event":"refix_wake_result"' "$BV_JOURNAL" 2>/dev/null || _bv_no_wake=yes
      if [ "$BV_RC" = 0 ] && [ "$_bv_escalated" = yes ] && [ "$_bv_journaled" = yes ] && [ "$_bv_no_wake" = yes ]; then
        checkpoint builder_refix_escalates_on_dead pass \
          "refix bounce escalated to 'agent dead' (refix_escalated_dead journaled; no wake attempted)"
      else
        checkpoint builder_refix_escalates_on_dead fail \
          "refix bounce did not escalate cleanly (rc=$BV_RC escalated=$_bv_escalated journaled=$_bv_journaled no_wake=$_bv_no_wake disp='$_bv_disp')"
      fi
    else
      checkpoint builder_refix_escalates_on_dead fail "skipped refix assertion — the pane process was not confirmed dead"
    fi
  fi

  # ── AGENT MISSING (HERD-135): the tab has NO agent pane AT ALL. The deadeyes step above left the
  # builder pane a BARE shell (process killed, pane present ⇒ 'dead'); now CLOSE that pane entirely so
  # the agent is neither in the roster NOR does any pane carry its label. Assert the SHIPPED probe reads
  # 'missing' (NOT dead, NOT alive) and the SHIPPED status classifier buckets it 'agentmissing' (NOT
  # done) for an open-PR builder — the #249 incident where 'done · PR #249' hid a tab with zero agents.
  # A refix would then have nobody to wake; the operator sees the truth. Complements the dead-vs-missing
  # split: 'dead' = pane present but unresponsive; 'missing' = no agent pane at all.
  if [ -n "$WSID" ] && [ -n "$BUILD_PANE" ]; then
    step missingeyes "remove the agent pane entirely → agent-missing; status reads 'agent missing', never done"
    # shellcheck source=scripts/herd/status.sh
    . "$HERE/../status.sh"   # _status_classify_builder (functions only; no side effects)
    _mp_present() {
      pane_json "$WSID" | MP="$1" python3 -c '
import sys,json,os
mp=os.environ["MP"]
try:
    panes=(json.load(sys.stdin).get("result") or {}).get("panes") or []
    print("yes" if any(str(p.get("pane_id",""))==mp for p in panes) else "no")
except Exception:
    print("err")
' 2>/dev/null
    }
    herdr pane close "$BUILD_PANE" >/dev/null 2>&1 || true
    _mp_gone="no"; _i=0
    while [ "$_i" -lt 25 ]; do
      [ "$(_mp_present "$BUILD_PANE")" = no ] && { _mp_gone=yes; break; }
      _i=$((_i+1)); sleep 0.2
    done
    # The SHIPPED probe: no agent in the roster AND no pane carries its label ⇒ 'missing'.
    _mp_live="$(herd_driver_agent_liveness rp-builder 2>/dev/null || printf 'unknown')"
    # The SHIPPED classifier: has_agent=0, an open PR (has_pr=1) + commits ⇒ 'agentmissing', NEVER done.
    _mp_bucket="$(_status_classify_builder 0 "" 1 1 "" 2>/dev/null || true)"
    if [ "$_mp_gone" = yes ] && [ "$_mp_live" = "missing" ] && [ "$_mp_bucket" = "agentmissing" ]; then
      checkpoint builder_agent_missing pass \
        "agent pane removed → liveness 'missing' (not dead/alive); status classifier reads 'agentmissing' (not done) for an open-PR builder with no agent"
    else
      checkpoint builder_agent_missing fail \
        "agent-missing not surfaced as expected (pane_gone=$_mp_gone liveness='$_mp_live' bucket='$_mp_bucket')"
    fi
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

# ── notify hermeticity invariant (HERD-139) ─────────────────────────────────────────────────────
# Across the whole run (every lib-mode escalation the phases drove) not one notification may have
# reached a real desktop channel. The notify stub captures any native osascript/notify-send attempt;
# with the fix this is 0 — a non-zero count means a real-pane phase leaked an alarm to the desktop.
step notify-invariant "harness invariant — zero notifications delivered outside the sink"
_notify_native="$(sim_notify_native_attempts)"
if [ "$_notify_native" = 0 ]; then
  checkpoint notify_hermetic pass "no native desktop notification fired during the run (all notifications captured to the sink)"
else
  checkpoint notify_hermetic fail "$_notify_native native desktop notification(s) LEAKED outside the sink (see ${SIM_NOTIFY_CAPTURED:-unset})"
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
