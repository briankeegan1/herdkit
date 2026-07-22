#!/usr/bin/env bash
# test-driver-launch-agent.sh — hermetic proof for the GENERALIZED start-agent seam
# (herd_driver_launch_agent, HERD-57 / audit D1). The six previously-hardcoded non-builder
# agent-launch lanes — coordinator, fleet room, resolver, reviewer, researcher, scribe — now route
# their `herdr agent start … -- claude` through the driver seam instead of bypassing it, so
# HERD_DRIVER=headless covers the WHOLE herd, not just feature/quick builders.
#
# Covers:
#   0. Every routed lane script (+ bin/herd) sources driver.sh AND calls herd_driver_launch_agent
#      (structural anchor: a future refactor that drops the routing fails here).
#   1. herdr-claude: each lane shape produces argv BYTE-IDENTICAL to the old hardcoded call — proven
#      against a stub herdr on PATH. Covers the varying dimensions D1 named: custom agent name,
#      arbitrary cwd, explicit tab, split direction (right/down/none), focus flag (human seat vs
#      builder), env passthrough, an explicit-empty flags set, and an omitted model.
#   2. headless: each routed shape spawns a DETACHED claude into the registry with the right cwd,
#      env passthrough, model omission, and the forced --dangerously-skip-permissions a detached
#      (tty-less) agent needs even for a human-seat lane.
#
# Fully hermetic: local temp dirs + a stub herdr/claude on PATH. NO real herdr/claude/gh/network.
# Run:  bash tests/test-driver-launch-agent.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DRIVER_SH="$ROOT/scripts/herd/driver.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# ── 0. Every routed site sources the shim AND calls the generalized seam. ─────────────────────────
declare -a LANES=(
  "scripts/herd/coordinator.sh"
  "scripts/herd/herd-resolve.sh"
  "scripts/herd/herd-review.sh"
  "scripts/herd/research.sh"
  "scripts/herd/scribe.sh"
)
for f in "${LANES[@]}"; do
  grep -qE '^\. "\$HERE/driver\.sh"' "$ROOT/$f" || fail "$f does not source driver.sh"
  grep -qF 'herd_driver_launch_agent' "$ROOT/$f" || fail "$f does not call herd_driver_launch_agent"
done
# fleet.sh is SOURCED by bin/herd (not standalone); bin/herd owns the sourcing.
grep -qF 'herd_driver_launch_agent' "$ROOT/scripts/herd/fleet.sh" || fail "fleet.sh does not call herd_driver_launch_agent"
grep -qE '\. "\$SCRIPTS_DIR/driver\.sh"' "$ROOT/bin/herd" || fail "bin/herd does not source driver.sh"
grep -qF 'herd_driver_launch_agent' "$ROOT/bin/herd" || fail "bin/herd does not call herd_driver_launch_agent"
# No routed lane still bypasses the seam with a raw `herdr agent start … claude` (builder lanes and
# the autorespawn keep their intentional inline herdr path; those are NOT in the routed set).
for f in "${LANES[@]}" "scripts/herd/fleet.sh"; do
  grep -nE 'herdr agent start' "$ROOT/$f" | grep -vE '#|"could not|BOTTOM SPLIT|--split down' \
    && fail "$f still has a bypassing raw 'herdr agent start' call"
done
ok; echo "PASS (0) every routed lane sources driver.sh and calls herd_driver_launch_agent"

# ── 1. herdr-claude: byte-identical argv per lane shape. ──────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do printf '[%s]\n' "$a"; done
STUB
chmod +x "$BIN/herdr"
emit(){ for a in "$@"; do printf '[%s]\n' "$a"; done; }

( set +e
  export HERD_DRIVER="herdr-claude" PATH="$BIN:$PATH"
  # The seam late-binds this; stub it so an unset workspace still resolves deterministically.
  herd_resolve_workspace_id(){ printf 'ws-RESOLVED'; }
  # shellcheck source=/dev/null
  . "$DRIVER_SH"

  chk(){ # chk <label> <got-fn-args...> -- <expected emit args...>
    local label="$1"; shift
    local -a got exp; local seen=0
    for a in "$@"; do
      if [ "$a" = "--SEP--" ]; then seen=1; continue; fi
      if [ "$seen" = 0 ]; then got+=("$a"); else exp+=("$a"); fi
    done
    if ! diff <(herd_driver_launch_agent "${got[@]}") <(emit "${exp[@]}") >/dev/null; then
      echo "FAIL: $label not byte-identical"; diff <(herd_driver_launch_agent "${got[@]}") <(emit "${exp[@]}"); exit 1
    fi
  }

  # coordinator.sh: custom name, explicit WS, --split right, focus (no --no-focus), model, no flags.
  chk coordinator \
    name=coord workspace=ws1 cwd=/repo tab=tabA split=right focus=yes model=opus pointer=/coordinator \
    --SEP-- agent start coord --workspace ws1 --cwd /repo --tab tabA --split right -- claude --model opus /coordinator

  # herd-resolve.sh (WS set): --split right --no-focus, yolo flags. HERD-418: the caller's requested
  # name carries the dotted role separator, but the REGISTERED name (what herdr actually sees) is the
  # sanitized form — herdr 0.7.5 rejects the raw dotted name outright (invalid_agent_name).
  chk resolve-ws \
    name=resolve·x workspace=ws1 cwd=/dir tab=tabB split=right model=sonnet flags=--dangerously-skip-permissions pointer=TASK \
    --SEP-- agent start resolve-x --workspace ws1 --cwd /dir --tab tabB --split right --no-focus -- claude --model sonnet --dangerously-skip-permissions TASK

  # herd-resolve.sh (WS empty, mirrors ${_WS_ID:+…}): --workspace omitted entirely.
  chk resolve-nows \
    name=resolve·x workspace= cwd=/dir tab=tabB split=right model=sonnet flags=--dangerously-skip-permissions pointer=TASK \
    --SEP-- agent start resolve-x --cwd /dir --tab tabB --split right --no-focus -- claude --model sonnet --dangerously-skip-permissions TASK

  # research.sh: no split, --no-focus, --env passthrough.
  chk research \
    name=researcher workspace=ws1 cwd=/repo tab=tabC env=RESEARCH_TAB=tabC model=haiku flags=--dangerously-skip-permissions pointer=PROMPT \
    --SEP-- agent start researcher --workspace ws1 --cwd /repo --tab tabC --no-focus --env RESEARCH_TAB=tabC -- claude --model haiku --dangerously-skip-permissions PROMPT

  # fleet.sh: HUMAN seat — focus (no --no-focus) AND zero flags (no --dangerously-skip-permissions).
  chk fleet \
    name=fleet workspace=ws1 cwd=/room tab=tabD focus=yes model=opus pointer=/fleet \
    --SEP-- agent start fleet --workspace ws1 --cwd /room --tab tabD -- claude --model opus /fleet

  # bin/herd _pane_agent_start (coordinator relaunch): NO model (--model omitted), focus, no flags.
  chk pane-relaunch \
    name=coord workspace=ws1 cwd=/repo tab=tabE split=down focus=yes pointer=/coordinator \
    --SEP-- agent start coord --workspace ws1 --cwd /repo --tab tabE --split down -- claude /coordinator

  # herd-review.sh: --split down --no-focus, yolo flags. HERD-418: registered name is sanitized.
  chk review \
    name=review·x workspace=ws1 cwd=/cwd tab=btab split=down model=opus flags=--dangerously-skip-permissions pointer=ATASK \
    --SEP-- agent start review-x --workspace ws1 --cwd /cwd --tab btab --split down --no-focus -- claude --model opus --dangerously-skip-permissions ATASK
  exit 0
) || fail "herdr-claude byte-identical argv checks failed (see FAIL above)"
ok; echo "PASS (1) herdr-claude: every routed lane shape emits byte-identical argv"

# ── 2. headless: each routed shape detaches a real agent into the registry. ───────────────────────
CBIN="$T/cbin"; mkdir -p "$CBIN"
cat > "$CBIN/claude" <<'STUB'
#!/usr/bin/env bash
{ echo "CWD=$(pwd)"; echo "RESEARCH_TAB=${RESEARCH_TAB:-<unset>}"; echo "ARGV:"; for a in "$@"; do printf '  [%s]\n' "$a"; done; }
sleep 0.4
STUB
chmod +x "$CBIN/claude"
( set +e
  export HERD_DRIVER="headless" PATH="$CBIN:$PATH" WORKTREES_DIR="$T/proj"
  mkdir -p "$WORKTREES_DIR/.herd" "$T/repo"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"

  # research: env passthrough + model present.
  herd_driver_launch_agent name=researcher workspace=ws1 cwd="$T/repo" tab=tabC env=RESEARCH_TAB=tabC \
    model=haiku flags=--dangerously-skip-permissions pointer="RP" || { echo "FAIL: research launch rc"; exit 1; }
  [ -s "$WORKTREES_DIR/.herd/agents/researcher/pid" ] || { echo "FAIL: research pid not written"; exit 1; }
  sleep 0.5
  L="$WORKTREES_DIR/.herd/agents/researcher/log"
  grep -qF "CWD=$T/repo" "$L" || { echo "FAIL: research cwd wrong"; cat "$L"; exit 1; }
  grep -qF "RESEARCH_TAB=tabC" "$L" || { echo "FAIL: research env not passed through"; cat "$L"; exit 1; }
  grep -qF "[haiku]" "$L" || { echo "FAIL: research model not passed"; cat "$L"; exit 1; }

  # fleet human seat: no flags on herdr, but headless FORCES --dangerously-skip-permissions (tty-less).
  herd_driver_launch_agent name=fleet cwd="$T/repo" tab=tabD focus=yes model=opus pointer="/fleet" \
    || { echo "FAIL: fleet launch rc"; exit 1; }
  sleep 0.5
  grep -qF "[--dangerously-skip-permissions]" "$WORKTREES_DIR/.herd/agents/fleet/log" \
    || { echo "FAIL: headless detached human seat not forced to skip permissions"; cat "$WORKTREES_DIR/.herd/agents/fleet/log"; exit 1; }

  # coordinator relaunch: NO model → --model absent from the detached argv.
  herd_driver_launch_agent name=coordX cwd="$T/repo" tab=tabE split=down focus=yes pointer="/coordinator" \
    || { echo "FAIL: coordX launch rc"; exit 1; }
  sleep 0.5
  grep -qF "[--model]" "$WORKTREES_DIR/.herd/agents/coordX/log" \
    && { echo "FAIL: --model leaked into a model-less detached launch"; cat "$WORKTREES_DIR/.herd/agents/coordX/log"; exit 1; }

  # A bad cwd fails soft (non-zero) without aborting — mirrors the builder headless path.
  herd_driver_launch_agent name=bad cwd="$T/no-such-dir" model=opus pointer=x 2>/dev/null \
    && { echo "FAIL: bad cwd should return non-zero"; exit 1; }
  exit 0
) || fail "headless detached-launch checks failed (see FAIL above)"
ok; echo "PASS (2) headless: routed shapes detach into the registry (cwd/env/model/forced-yolo)"

# ── 3. HERD-171: ANTHROPIC_BASE_URL endpoint env injection (byte-identical when unset). ───────────
# When the machine-scoped key is set, launch-agent injects --env ANTHROPIC_BASE_URL=… so Claude Code
# hits the enterprise/local gateway. When unset, argv stays byte-identical to section (1).
( set +e
  export HERD_DRIVER="herdr-claude" PATH="$BIN:$PATH"
  herd_resolve_workspace_id(){ printf 'ws-RESOLVED'; }
  # shellcheck source=/dev/null
  . "$DRIVER_SH"

  # Unset → no --env from the endpoint helper (existing caller env still works).
  unset ANTHROPIC_BASE_URL
  got="$(herd_driver_launch_agent name=ep workspace=ws1 cwd=/repo tab=t1 model=opus pointer=P)"
  printf '%s\n' "$got" | grep -qF -- '--env' \
    && { echo "FAIL: --env leaked when ANTHROPIC_BASE_URL unset"; printf '%s\n' "$got"; exit 1; }
  # helper itself emits nothing
  [ -z "$(herd_driver_endpoint_env_lines)" ] || { echo "FAIL: endpoint_env_lines non-empty when unset"; exit 1; }

  # Set → --env ANTHROPIC_BASE_URL=<url> appears before the runtime tail.
  export ANTHROPIC_BASE_URL="https://corp.example/v1"
  got="$(herd_driver_launch_agent name=ep workspace=ws1 cwd=/repo tab=t1 model=opus pointer=P)"
  printf '%s\n' "$got" | grep -qF -- '[--env]' || { echo "FAIL: missing --env when URL set"; printf '%s\n' "$got"; exit 1; }
  printf '%s\n' "$got" | grep -qF -- '[ANTHROPIC_BASE_URL=https://corp.example/v1]' \
    || { echo "FAIL: missing ANTHROPIC_BASE_URL value in argv"; printf '%s\n' "$got"; exit 1; }
  # composes with an explicit caller env (both present)
  got="$(herd_driver_launch_agent name=ep workspace=ws1 cwd=/repo tab=t1 env=RESEARCH_TAB=x model=opus flags=--dangerously-skip-permissions pointer=P)"
  printf '%s\n' "$got" | grep -qF -- '[RESEARCH_TAB=x]' || { echo "FAIL: caller env dropped"; printf '%s\n' "$got"; exit 1; }
  printf '%s\n' "$got" | grep -qF -- '[ANTHROPIC_BASE_URL=https://corp.example/v1]' \
    || { echo "FAIL: endpoint env dropped when composing with caller env"; printf '%s\n' "$got"; exit 1; }
  exit 0
) || fail "HERD-171 endpoint env injection checks failed (see FAIL above)"
ok; echo "PASS (3) HERD-171: ANTHROPIC_BASE_URL injects --env when set, silent when unset"

# Headless inherits the endpoint export into the detached child.
( set +e
  export HERD_DRIVER="headless" PATH="$CBIN:$PATH" WORKTREES_DIR="$T/proj-ep" ANTHROPIC_BASE_URL="http://127.0.0.1:9"
  mkdir -p "$WORKTREES_DIR/.herd" "$T/repo"
  # Rebuild a claude stub that prints the endpoint env.
  cat > "$CBIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-<unset>}"
sleep 0.2
STUB
  chmod +x "$CBIN/claude"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"
  herd_driver_launch_agent name=ep-local cwd="$T/repo" model=haiku flags=--dangerously-skip-permissions pointer=P \
    || { echo "FAIL: headless endpoint launch rc"; exit 1; }
  sleep 0.4
  grep -qF "ANTHROPIC_BASE_URL=http://127.0.0.1:9" "$WORKTREES_DIR/.herd/agents/ep-local/log" \
    || { echo "FAIL: headless child missing ANTHROPIC_BASE_URL"; cat "$WORKTREES_DIR/.herd/agents/ep-local/log"; exit 1; }
  exit 0
) || fail "HERD-171 headless endpoint export checks failed (see FAIL above)"
ok; echo "PASS (4) HERD-171: headless detached child inherits ANTHROPIC_BASE_URL"

echo "ALL PASS ($pass checks)"
