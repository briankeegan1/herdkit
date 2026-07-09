#!/usr/bin/env bash
# scripts/herd/sim/sandbox-limit-resume-scenario.sh — P2a LIMIT-PARK / AUTO-RESUME e2e scenario.
#
# The auto-resume moat, proven end-to-end and hermetically. Where the P1 concurrency scenario
# (sandbox-concurrency-scenario.sh) drives the REAL watcher GATE loop, this P2a scenario drives the
# REAL watcher LIMIT path (agent-watch.sh, sourced in lib mode): a builder hits the account usage
# limit, the watcher DETECTS the park via the hook sentinel, SCHEDULES an in-place resume honoring
# HERD_LIMIT_RESUME_BUFFER, and at the reset RELAUNCHES the builder via `claude --continue`. Every
# step is the SHIPPED code — `_detect_limit_hit`, `_handle_limit_blocked`, `_resume_builder`,
# `record_limit`/`clear_limit`, `limit_state`/`limit_target_epoch` — called in the exact order and
# under the exact guard the watcher's action pass uses (agent-watch.sh:2910–2913). So the auto-resume
# accounting under test IS production's; this scenario breaks if that code regresses.
#
# The two moving parts that would be a live account + a live Claude session are the ONLY things
# stubbed, and both through documented seams:
#   • The rate-limit sentinel is written by the ACTUAL StopFailure/rate_limit hook command
#     (herd_write_ratelimit_hook installs it; we feed the harness EVENT on stdin — a JSON blob
#     carrying the usage-limit banner, exactly as Claude Code does) — so the injected sentinel is
#     whatever the hook's own extractor produces, never a hand-written value.
#   • `claude` is a stub shim on PATH: when the resume fires `claude --continue` in the builder's
#     worktree, the shim RECORDS its invocation (argv + cwd) and COMPLETES the parked task
#     deterministically (implements the pending feature + commits it, no model call), then flips the
#     agent to "working" so the watcher's wake-verify (`_wait_agent_working`) observes the resume.
#   The `herdr` agent surface is a file-driven stub (agent_status read from a state dir; `pane run`
#   EXECUTES the resume command so the real shim fires) — the same seam the unit tests stub.
#
# It asserts the auto-resume checkpoints in the scorecard:
#   detect     — `_detect_limit_hit` returns the reset epoch from the injected hook sentinel.
#   park       — first sighting records a `scheduled` limit hold + a DISTINCT NON-RED row (a usage
#                limit is an expected account event, never a red alarm) + journals `limit_detected`.
#   scheduled  — the resume target honors HERD_LIMIT_RESUME_BUFFER: target == reset + buffer (asserted
#                against a NON-default buffer so the knob is proven, not the fallback).
#   resume     — at reset+buffer the backstop relaunches via `claude --continue` IN the worktree; the
#                shim's invocation is recorded, journal logs `limit_resume_result` woke:1, row is green.
#   complete   — the resumed builder's deterministic task landed (feature committed on its branch) and
#                the limit ledger + sentinel were cleared.
# Plus a NEGATIVE path:
#   negative_no_park — with HERD_LIMIT_DETECT=off, the SAME injected sentinel yields NO detection, NO
#                ledger record, and NO `claude` relaunch (the feature kill-switch holds).
#
# VERIFICATION ARTIFACTS (into the artifacts dir):
#   • pane-<checkpoint>.txt — the watcher console frame (the real DISPLAY[] limit rows) captured back
#     THROUGH the driver read-pane surface (herd_driver_read_pane, headless → tails the agent log).
#   • screenshots/watcher-<checkpoint>.png — macOS screencapture; DEGRADES GRACEFULLY (no-false-red):
#     skips — never fails — when headless / not macOS / tool absent / permission missing / opted out.
#
# HERMETIC: fixture-repo only. Stubs `claude` + `herdr` (PATH), installs the real hook to write the
# sentinel, HERD_DRIVER=headless (no herdr panes/tabs), an ISOLATED WORKSPACE_NAME + temp
# WORKTREES_DIR + JOURNAL_FILE — so it never touches the real herdkit repo's PRs, panes, or journal,
# and the tab-leak-guard cannot miscount it. `git` is NOT stubbed (real local worktrees/commits).
# Zero model calls, zero quota, zero network.
#
# Usage:
#   bash scripts/herd/sim/sandbox-limit-resume-scenario.sh [--artifacts DIR] [--keep]
#     --artifacts DIR   put the repo + scorecard + artifacts here (default: a fresh mktemp dir)
#     --keep            do not delete the artifacts dir on exit (implied when --artifacts is given)
#   Env:
#     HERD_LIMIT_RESUME_BUFFER (default 120 here)  grace after the reset before relaunch — asserted
#     SANDBOX_NO_SCREENSHOT=1                       force-skip the screenshot step (set by the test)
#
# Exit: 0 = every checkpoint passed · 1 = at least one checkpoint failed (or a hard error).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"

# ── output helpers (mirror sandbox-concurrency-scenario.sh's style) ─────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
skip() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────
ART=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART="${2:-}"; KEEP=1; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sandbox-limit-resume-scenario: unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [ -z "$ART" ]; then ART="$(mktemp -d)"; fi
mkdir -p "$ART"
if [ -z "$KEEP" ]; then trap 'rm -rf "$ART"' EXIT; fi

SCENARIO="stub-limit-resume-e2e"
REPO="$ART/repo"
TREES="$ART/trees"
SHOTS="$ART/screenshots"
mkdir -p "$TREES" "$SHOTS"

# A NON-default buffer so the "scheduled" checkpoint proves HERD_LIMIT_RESUME_BUFFER is honored
# (the fallback default is 60; using 120 makes target == reset + buffer a non-vacuous assertion).
: "${HERD_LIMIT_RESUME_BUFFER:=120}"
export HERD_LIMIT_RESUME_BUFFER

# ── deterministic clock (HERD_NOW_EPOCH seam) ───────────────────────────────────────────────────
# A fixed base so every run is byte-stable. The reset is a NEAR-FUTURE epoch (~base + 300s).
#
# MINUTE-ALIGNED (HERD-246): the reset reaches the engine the way it reaches it in production — as a
# wall-clock time inside the banner text ("…will reset at 03:38"), which _parse_reset_epoch resolves
# to the next occurrence of that HH:MM with seconds ZEROED. A reset epoch carrying a seconds
# component could therefore never round-trip. Anchor RESET on a minute boundary so
# `banner → sentinel → _parse_reset_epoch` returns it exactly.
# TZ is pinned so the HH:MM the banner renders and the HH:MM the parser resolves cannot disagree.
export TZ="${TZ:-UTC}"
NOW0=2000000000
RESET=$(( (NOW0 / 60) * 60 + 300 ))
TARGET=$(( RESET + HERD_LIMIT_RESUME_BUFFER ))
RESET_HHMM="$(date -r "$RESET" +%H:%M 2>/dev/null || date -d "@$RESET" +%H:%M 2>/dev/null)"
# The usage-limit BANNER Claude prints when a turn ends rate-limited. This — not a bare epoch — is
# what the real rate_limit hook sees, and the only shape its extractor writes to the sentinel.
RESET_BANNER="Claude usage limit reached. Your limit will reset at ${RESET_HHMM}."

# ── checkpoint recording (bash 3.2: parallel indexed arrays, no assoc arrays) ───────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail="$*"
  detail="$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
    skip) skip "$name — $detail" ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s══ Sandbox LIMIT-RESUME scenario: %s (buffer=%ss) ══%s\n' \
  "$c_bold" "$SCENARIO" "$HERD_LIMIT_RESUME_BUFFER" "$c_rst"
printf '  artifacts: %s\n' "$ART"

# ── init: build the deterministic fixture (this is $PROJECT_ROOT / $MAIN for the watcher) ────────
step init "build deterministic local fixture"
FIXTURE_SHA="$(sandbox_fixture_build "$REPO")" || { bad "fixture build failed"; exit 1; }
info "fixture HEAD: $FIXTURE_SHA"
[ -f "$REPO/app/greet.sh" ] && checkpoint fixture_built pass "fixture at $REPO (HEAD ${FIXTURE_SHA:0:12})" \
  || checkpoint fixture_built fail "fixture missing app/greet.sh"

# ── start a stub builder in a worktree (a real branch/worktree off main; the "task" is the pending
#    farewell feature it will implement once resumed). Resolve to a PHYSICAL path so the hook's
#    `pwd -P` sentinel path matches the path _detect_limit_hit reads. ──────────────────────────────
step builder "start a stub builder in a worktree (mid-task; will hit the limit)"
_sf_git_env
SLUG="lim-builder"; BRANCH="sim/$SLUG"; PANE="pane-LIM"
git -C "$REPO" worktree add -q -b "$BRANCH" "$TREES/$SLUG" main 2>/dev/null \
  || { bad "worktree add failed for $SLUG"; exit 1; }
WT="$(cd "$TREES/$SLUG" && pwd -P)"
BRANCH_HEAD_BEFORE="$(git -C "$WT" rev-parse HEAD)"
if [ -d "$WT" ] && [ ! -f "$WT/app/farewell.sh" ]; then
  checkpoint builder_started pass "worktree $SLUG on $BRANCH off main; pending task not yet done"
else
  checkpoint builder_started fail "builder worktree not set up as expected at $WT"
fi

# ── hermetic stubs: claude shim + herdr (agent list / executing pane run), headless driver ───────
step stubs "install hermetic stubs (claude shim · herdr agent surface · headless driver)"
BIN="$ART/bin"; mkdir -p "$BIN"
AGENT_STATE_DIR="$ART/agent-state"; mkdir -p "$AGENT_STATE_DIR"
CLAUDE_INVOCATION_LOG="$ART/claude-invocations.log"; : > "$CLAUDE_INVOCATION_LOG"
HERDR_PANE_RUN_LOG="$ART/herdr-pane-run.log"; : > "$HERDR_PANE_RUN_LOG"
CLAUDE_DONE_MARKER="$ART/task-complete.marker"

# set_agent <slug> <status> <pane> — drive the file-backed agent_status the herdr stub reports.
set_agent() { printf '%s %s\n' "$2" "$3" > "$AGENT_STATE_DIR/$1"; }

# `claude` shim: the resumed session. Invoked via `herdr pane run` executing
# `cd <wt> && claude <flags> --continue <prompt>` — so CWD is the builder worktree.
cat > "$BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
# claude stub shim (limit-resume e2e): record the invocation, complete the parked task
# deterministically (implement + commit the pending feature; no model call), flip agent → working.
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >> "$CLAUDE_INVOCATION_LOG"
# Deterministic "work": the pending farewell feature the builder was mid-implementing when it parked.
cat > app/farewell.sh <<'FEAT'
#!/usr/bin/env bash
# farewell.sh — implemented by the RESUMED builder after the limit reset (deterministic; no model).
farewell() { printf 'goodbye, %s!\n' "${1:-world}"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then farewell "$@"; fi
FEAT
chmod +x app/farewell.sh
git add -A >/dev/null 2>&1 || true
GIT_AUTHOR_DATE='2020-01-01T00:00:00 +0000' GIT_COMMITTER_DATE='2020-01-01T00:00:00 +0000' \
  git commit -q -m 'resumed builder: implement farewell (post-limit)' >/dev/null 2>&1 || true
: > "$CLAUDE_DONE_MARKER"
# Flip the agent to "working" so the watcher's _wait_agent_working sees the resume take hold.
if [ -n "${RESUME_SLUG:-}" ] && [ -n "${AGENT_STATE_DIR:-}" ]; then
  pane="$(awk '{print $2}' "$AGENT_STATE_DIR/$RESUME_SLUG" 2>/dev/null)"
  printf 'working %s\n' "${pane:-pane-LIM}" > "$AGENT_STATE_DIR/$RESUME_SLUG"
fi
CLAUDE
chmod +x "$BIN/claude"

# `herdr` stub: agent list reflects the state dir; `pane run` EXECUTES the resume command (so the
# real claude shim fires) and logs it. Mirrors tests/test-limit-resume.sh's herdr stub, but the
# state is FILE-backed so the claude shim can flip status mid-run (a live e2e state machine).
cat > "$BIN/herdr" <<'HERDR'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    python3 - "$AGENT_STATE_DIR" <<'PY'
import sys, os, json
d = sys.argv[1]; agents = []
try:
    for name in sorted(os.listdir(d)):
        p = os.path.join(d, name)
        if not os.path.isfile(p):
            continue
        parts = open(p).read().split()
        status = parts[0] if parts else ""
        pane = parts[1] if len(parts) > 1 else ""
        agents.append({"name": name, "agent_status": status, "pane_id": pane})
except OSError:
    pass
print(json.dumps({"result": {"agents": agents}}))
PY
    ;;
  "pane run")
    # args: pane(1) run(2) <pane_id>(3) <command-text>(4)
    [ -n "${HERDR_PANE_RUN_LOG:-}" ] && printf '%s\n' "$4" >> "$HERDR_PANE_RUN_LOG"
    # Only EXECUTE a resume command (the `claude --continue` relaunch); never eval a raw prompt.
    case "$4" in *"&& claude "*) bash -c "$4" ;; esac
    ;;
  *) exit 0 ;;
esac
HERDR
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"
export AGENT_STATE_DIR CLAUDE_INVOCATION_LOG HERDR_PANE_RUN_LOG CLAUDE_DONE_MARKER RESUME_SLUG="$SLUG"

# The builder is mid-task and "working" before the limit hits.
set_agent "$SLUG" working "$PANE"
checkpoint stubs_installed pass "claude shim + file-driven herdr + headless driver ready"

# ── source the REAL watcher in lib mode (AGENT_WATCH_LIB=1 → functions only, no loop / re-exec) ──
step source "source the REAL agent-watch.sh (lib mode) with the limit knobs"
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$ART/no-such-config"    # ignore any ambient .herd/config
export HERD_DRIVER=headless                       # panes-as-a-view: no herdr tabs/panes ever created
export WORKSPACE_NAME="sandbox-limit-sim"         # isolated name (tab-leak-guard cannot miscount us)
export PROJECT_ROOT="$REPO"
export WORKTREES_DIR="$TREES"                      # → TREES: all ledgers/markers land here
export DEFAULT_BRANCH="main"
export JOURNAL_FILE="$ART/journal.jsonl"; : > "$JOURNAL_FILE"
# Keep the resume wake-verify snappy (the shim flips status synchronously, so no real wait occurs).
export HERD_RESUME_WAIT_TIMEOUT=3
WATCH="$HERE/../agent-watch.sh"
[ -f "$WATCH" ] || { bad "agent-watch.sh not found at $WATCH"; exit 1; }
# shellcheck source=/dev/null
. "$WATCH" || { bad "sourcing agent-watch.sh (lib mode) failed"; exit 1; }

# The limit-path functions we drive must exist (proves we bound to the real watcher, not a stand-in).
_missing=""
for fn in _detect_limit_hit _handle_limit_blocked _resume_builder _limit_sentinel_file \
          _parse_reset_epoch limit_state limit_target_epoch record_limit clear_limit \
          _find_builder_pane_id_any herd_write_ratelimit_hook; do
  type "$fn" >/dev/null 2>&1 || _missing="$_missing $fn"
done
if [ -z "$_missing" ]; then
  checkpoint watcher_bound pass "real agent-watch.sh limit functions sourced (lib mode)"
else
  checkpoint watcher_bound fail "missing limit functions:$_missing"
fi

# Silence terminal output the way the unit tests / concurrency scenario do.
render() { :; }

# ── DRIVE the real limit path, tick by tick (the exact shape of agent-watch.sh:2910–2913) ────────
# One tick == the watcher's per-builder limit decision: detect, then handle iff a hit or a live
# hold. Returns 0 when the tick HANDLED a limit (parked/waiting/resumed), 1 when not limit-blocked.
DISPLAY=()
run_limit_tick() {
  local _slug="$1" _dir="$2" _idx="$3" _reset _hit
  if _reset="$(_detect_limit_hit "$_slug" "$_dir")"; then _hit=1; else _hit=0; fi
  if [ "$_hit" = "1" ] || [ -n "$(limit_state "$_slug")" ]; then
    _handle_limit_blocked "$_slug" "$_dir" "$_idx" "${_reset:-0}"
    return 0
  fi
  return 1
}

# ── artifact helpers (console frame captured back THROUGH the driver read-pane surface) ──────────
PANE_SLUG="watch-console"
PANE_DIR="$TREES/.herd/agents/$PANE_SLUG"; mkdir -p "$PANE_DIR"
PANE_CAPTURES=0
capture_pane() {
  local label="$1"; shift
  printf '%s\n' "$*" > "$PANE_DIR/log"
  local out="$ART/pane-$label.txt" got
  got="$(herd_driver_read_pane "$PANE_SLUG" 2>/dev/null || true)"
  printf '%s\n' "$got" > "$out"
  [ -s "$out" ] && { PANE_CAPTURES=$((PANE_CAPTURES+1)); info "pane captured via driver read-pane → $out"; }
}
console_frame() {
  local title="$1"
  printf '🐑 herd watch · %s · %s\n' "$WORKSPACE_NAME" "$title"
  printf '   in flight\n'
  local r
  for r in ${DISPLAY[@]+"${DISPLAY[@]}"}; do [ -n "$r" ] && printf '%s\n' "$r"; done
}
SHOTS_TAKEN=0
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

# ── INJECT the limit sentinel via the ACTUAL StopFailure/rate_limit hook command ─────────────────
# Install the real hook, then run its command with the harness EVENT on stdin exactly as Claude Code
# would on a rate-limited turn end — so the sentinel matches the hook's format byte for byte (rather
# than being hand-written). The builder's session has now ended: mark it idle.
#
# HERD-246: stdin is a JSON EVENT carrying the banner, not a bare epoch. HERD-155 F3 tightened the
# hook's extractor to write ONLY banner-shaped text ("reset at/in <time>", else a "usage/session
# limit" line) precisely so a stray number in this blob could never be misread as a reset clock. The
# pre-HERD-246 sim piped the raw epoch, which matches neither pattern — the hook wrote an EMPTY
# sentinel, `detect` returned reset=0, and the schedule silently fell through to
# HERD_LIMIT_UNKNOWN_WAIT. Feeding the real event shape is what makes this an end-to-end proof.
step inject "inject the rate-limit sentinel via the real StopFailure hook, session ends"
herd_write_ratelimit_hook "$WT"
HOOK_CMD="$(python3 - "$WT/.claude/settings.json" <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    for e in d.get("hooks", {}).get("StopFailure", []):
        if e.get("matcher") == "rate_limit":
            print(e["hooks"][0]["command"]); break
except Exception:
    pass
PY
)"
if [ -n "$HOOK_CMD" ]; then
  # The StopFailure/rate_limit event blob, banner included — the hook extracts the banner → sentinel.
  HOOK_EVENT="$(HERD_SIM_BANNER="$RESET_BANNER" python3 -c 'import json, os; print(json.dumps({
    "session_id": "sim-0000-1111-2222",
    "transcript_path": "/dev/null",
    "reason": "rate_limit",
    "message": os.environ["HERD_SIM_BANNER"],
  }))')"
  printf '%s' "$HOOK_EVENT" | bash -c "$HOOK_CMD"
  info "hook command: $HOOK_CMD"
fi
set_agent "$SLUG" idle "$PANE"    # the parked session has ENDED (not working)
SENT="$(_limit_sentinel_file "$WT")"
# The sentinel must hold the extracted BANNER, and that banner must parse back to exactly $RESET —
# the round-trip (banner → hook → sentinel → _parse_reset_epoch) is the checkpoint, not a byte match.
_sent_txt="$(cat "$SENT" 2>/dev/null || true)"
if [ -f "$SENT" ] && [ -n "$_sent_txt" ] && \
   [ "$(HERD_NOW_EPOCH="$NOW0" _parse_reset_epoch "$_sent_txt")" = "$RESET" ]; then
  checkpoint sentinel_injected pass "hook extracted the banner → .herd-limit-sentinel ('$_sent_txt'), parses to reset epoch $RESET"
else
  checkpoint sentinel_injected fail "sentinel did not round-trip to $RESET (got '$_sent_txt')"
fi

# ── TICK 1 — DETECT + PARK (clock = base; reset is in the future) ────────────────────────────────
step park "tick 1: watcher detects the park and schedules the resume"
export HERD_NOW_EPOCH="$NOW0"
# detect on its own first (the checkpoint the whole moat rests on).
if _det="$(_detect_limit_hit "$SLUG" "$WT")"; then
  if [ "$_det" = "$RESET" ]; then
    checkpoint detect pass "_detect_limit_hit returned the reset epoch ($_det) from the hook sentinel"
  else
    checkpoint detect fail "detected but reset epoch wrong (got '$_det', want $RESET)"
  fi
else
  checkpoint detect fail "_detect_limit_hit did not detect the injected sentinel"
fi

DISPLAY=()
run_limit_tick "$SLUG" "$WT" 0
PARK_ROW="${DISPLAY[0]:-}"
capture_pane "parked" "$(console_frame "tick 1 · limit-hit · auto-resume scheduled")"
take_screenshot "parked"

# park: scheduled hold recorded, journal limit_detected, row present and NOT a red "needs you".
_state="$(limit_state "$SLUG")"
if [ "$_state" = "scheduled" ] && grep -q '"event":"limit_detected"' "$JOURNAL_FILE" \
   && printf '%s' "$PARK_ROW" | grep -q 'limit-hit' \
   && ! printf '%s' "$PARK_ROW" | grep -q 'needs you'; then
  checkpoint park pass "scheduled hold recorded + limit_detected journaled; row is a non-red limit-hit hold"
else
  checkpoint park fail "state='$_state' row='$PARK_ROW' (expected scheduled, non-red, limit_detected journaled)"
fi

# scheduled: the resume target honors HERD_LIMIT_RESUME_BUFFER (target == reset + buffer).
_target="$(limit_target_epoch "$SLUG")"
if [ "$_target" = "$TARGET" ]; then
  checkpoint scheduled pass "resume target $_target == reset $RESET + buffer $HERD_LIMIT_RESUME_BUFFER (buffer honored)"
else
  checkpoint scheduled fail "target $_target != reset+buffer $TARGET (HERD_LIMIT_RESUME_BUFFER not honored)"
fi

# ── TICK 2 — STILL WAITING (clock < target): no early resume ─────────────────────────────────────
step wait "tick 2: before the reset — hold, do NOT relaunch early"
export HERD_NOW_EPOCH="$(( TARGET - 20 ))"
_claude_before_wait="$(wc -l < "$CLAUDE_INVOCATION_LOG" | tr -d ' ')"
DISPLAY=()
run_limit_tick "$SLUG" "$WT" 0
WAIT_ROW="${DISPLAY[0]:-}"
_claude_after_wait="$(wc -l < "$CLAUDE_INVOCATION_LOG" | tr -d ' ')"
if [ "$_claude_before_wait" = "$_claude_after_wait" ] && printf '%s' "$WAIT_ROW" | grep -q 'auto-resume at'; then
  checkpoint waiting_no_early_resume pass "before reset: holding ('$WAIT_ROW'), claude NOT relaunched"
else
  checkpoint waiting_no_early_resume fail "early resume or wrong hold row (claude runs $_claude_before_wait→$_claude_after_wait, row '$WAIT_ROW')"
fi

# ── TICK 3 — RESUME (clock >= target): relaunch via `claude --continue` ──────────────────────────
step resume "tick 3: reset reached — relaunch in place via claude --continue"
export HERD_NOW_EPOCH="$(( TARGET + 100 ))"
DISPLAY=()
run_limit_tick "$SLUG" "$WT" 0
RESUME_ROW="${DISPLAY[0]:-}"
capture_pane "resumed" "$(console_frame "tick 3 · limit reset · resumed via --continue")"
take_screenshot "resumed"

# resume: exactly one claude invocation, with --continue, in the correct worktree; woke:1 journaled.
_claude_runs="$(wc -l < "$CLAUDE_INVOCATION_LOG" | tr -d ' ')"
if [ "$_claude_runs" -ge 1 ] \
   && grep -q -- '--continue' "$CLAUDE_INVOCATION_LOG" \
   && grep -qF "cwd=$WT" "$CLAUDE_INVOCATION_LOG" \
   && grep -q '"event":"limit_resume_result"' "$JOURNAL_FILE" \
   && grep -q '"woke":1' "$JOURNAL_FILE" \
   && printf '%s' "$RESUME_ROW" | grep -q 'resumed via --continue'; then
  checkpoint resume pass "relaunched via claude --continue in $WT; woke:1 journaled; green resumed row"
else
  checkpoint resume fail "resume path did not fire as expected (claude runs=$_claude_runs, row='$RESUME_ROW')"
fi

# complete: the resumed builder's deterministic task landed (feature committed on its branch) and the
# limit ledger + sentinel were cleared.
BRANCH_HEAD_AFTER="$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)"
_committed=no
git -C "$WT" cat-file -e "HEAD:app/farewell.sh" 2>/dev/null && [ "$BRANCH_HEAD_AFTER" != "$BRANCH_HEAD_BEFORE" ] && _committed=yes
if [ "$_committed" = yes ] && [ -f "$CLAUDE_DONE_MARKER" ] \
   && [ -z "$(limit_state "$SLUG")" ] && [ ! -f "$SENT" ]; then
  checkpoint complete pass "resumed task committed farewell on $BRANCH; ledger + sentinel cleared"
else
  checkpoint complete fail "task/cleanup incomplete (committed=$_committed marker=$([ -f "$CLAUDE_DONE_MARKER" ] && echo y || echo n) state='$(limit_state "$SLUG")' sentinel=$([ -f "$SENT" ] && echo present || echo gone))"
fi

# ── NEGATIVE PATH — HERD_LIMIT_DETECT=off ⇒ no park at all ───────────────────────────────────────
# A SEPARATE builder with the SAME injected sentinel, but the detection kill-switch off. The watcher
# must NOT detect, NOT record a hold, and NOT relaunch `claude`.
step negative "negative path: HERD_LIMIT_DETECT=off — the same sentinel yields NO park"
NEG_SLUG="neg-builder"; NEG_BRANCH="sim/$NEG_SLUG"
git -C "$REPO" worktree add -q -b "$NEG_BRANCH" "$TREES/$NEG_SLUG" main 2>/dev/null \
  || { bad "worktree add failed for $NEG_SLUG"; exit 1; }
NEG_WT="$(cd "$TREES/$NEG_SLUG" && pwd -P)"
set_agent "$NEG_SLUG" idle "pane-NEG"
herd_write_ratelimit_hook "$NEG_WT"
NEG_HOOK_CMD="$(python3 - "$NEG_WT/.claude/settings.json" <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    for e in d.get("hooks", {}).get("StopFailure", []):
        if e.get("matcher") == "rate_limit":
            print(e["hooks"][0]["command"]); break
except Exception:
    pass
PY
)"
[ -n "$NEG_HOOK_CMD" ] && printf '%s' "$RESET" | bash -c "$NEG_HOOK_CMD"
_claude_before_neg="$(wc -l < "$CLAUDE_INVOCATION_LOG" | tr -d ' ')"
export HERD_NOW_EPOCH="$NOW0"
_neg_detected=no
HERD_LIMIT_DETECT=off _detect_limit_hit "$NEG_SLUG" "$NEG_WT" >/dev/null 2>&1 && _neg_detected=yes
DISPLAY=()
HERD_LIMIT_DETECT=off run_limit_tick "$NEG_SLUG" "$NEG_WT" 0 && _neg_handled=yes || _neg_handled=no
_claude_after_neg="$(wc -l < "$CLAUDE_INVOCATION_LOG" | tr -d ' ')"
if [ "$_neg_detected" = no ] && [ "$_neg_handled" = no ] \
   && [ -z "$(limit_state "$NEG_SLUG")" ] && [ "$_claude_before_neg" = "$_claude_after_neg" ] \
   && [ -f "$(_limit_sentinel_file "$NEG_WT")" ]; then
  checkpoint negative_no_park pass "HERD_LIMIT_DETECT=off: sentinel present but NO detect, NO hold, NO relaunch"
else
  checkpoint negative_no_park fail "kill-switch leaked (detected=$_neg_detected handled=$_neg_handled state='$(limit_state "$NEG_SLUG")' claude $_claude_before_neg→$_claude_after_neg)"
fi

# Artifact-presence checkpoint.
if [ "$PANE_CAPTURES" -ge 1 ]; then
  checkpoint pane_text_captured pass "$PANE_CAPTURES console frame(s) captured via driver read-pane"
else
  checkpoint pane_text_captured fail "driver read-pane surface produced no pane text"
fi

# ── SCORECARD emitter (machine-readable JSON; mirrors the sandbox-sim family + limit fields) ─────
write_scorecard() {
  local out="$ART/scorecard.json" result="$1"
  local skipped=0 i n; n=${#CP_NAMES[@]}
  for ((i=0; i<n; i++)); do [ "${CP_STATUS[$i]}" = "skip" ] && skipped=$((skipped+1)); done
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
    printf '  "artifacts_dir": "%s",\n' "$ART"
    printf '  "repo_dir": "%s",\n' "$REPO"
    printf '  "fixture_sha": "%s",\n' "$FIXTURE_SHA"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "skipped": %d,\n' "$skipped"
    printf '  "reset_epoch": %d,\n' "$RESET"
    printf '  "resume_buffer": %d,\n' "$HERD_LIMIT_RESUME_BUFFER"
    printf '  "resume_target": %d,\n' "$TARGET"
    printf '  "claude_relaunches": %d,\n' "$_claude_runs"
    printf '  "task_completed": %s,\n' "$([ "$_committed" = yes ] && echo true || echo false)"
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

RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$(write_scorecard "$RESULT")"
printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:      %s\n' "$SCENARIO"
printf '  result:        %s\n' "$RESULT"
printf '  passed/failed: %d / %d\n' "$_pass" "$_fail"
printf '  reset→target:  %d → %d (buffer %d)\n' "$RESET" "$TARGET" "$HERD_LIMIT_RESUME_BUFFER"
printf '  claude runs:   %d\n' "$_claude_runs"
printf '  scorecard:     %s\n' "$SCARD"
printf '  artifacts:     %s\n' "$ART"

[ "$RESULT" = "pass" ] && exit 0 || exit 1
