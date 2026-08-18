#!/usr/bin/env bash
# test-drainer-permission-flags.sh — the research/scribe drainers derive the spawn's PERMISSION FLAG
# from the RESOLVED runtime driver (via the shared herd_driver_lane_permission_flags seam), instead of
# eagerly hardcoding claude's --dangerously-skip-permissions and passing that explicit <flags> into
# herd_driver_launch_agent (HERD-770).
#
# WHY: on 2026-08-18, HERD_DRIVER=codex + MODEL_RESEARCH=codex:gpt-5.6-terra made research.sh launch
# codex with claude-only --dangerously-skip-permissions; Codex CLI 0.147.0 rejected the flag and never
# started. Root cause: both drainers set CLAUDE_FLAGS="${HERD_CLAUDE_FLAGS:---dangerously-skip-permissions}"
# and passed that NON-EMPTY value as flags=…, which OVERRIDES the driver's own DRIVER_AGENT_PERMISSION_FLAG
# token inside herd_driver_agent_spawn_argv. The fix resolves flags through the driver keyed to the
# (optionally runtime-qualified) drainer model.
#
# This drives the REAL research.sh / scribe.sh end-to-end with a stub herdr on PATH (HERD_HERDR_ATTACH_CLI=no
# → the byte-identical pre-0.7.5 `agent start … -- <runtime tail>` shape) and asserts the composed runtime
# tail after `--` for three regimes each:
#   • Codex runtime      → tail is `codex … --dangerously-bypass-approvals-and-sandbox` and NEVER carries
#                          --dangerously-skip-permissions;
#   • Claude/default     → tail is BYTE-IDENTICAL to today's `claude --model <model>
#                          --dangerously-skip-permissions <prompt>`;
#   • explicit override  → an EXPLICIT HERD_CLAUDE_FLAGS wins verbatim for ANY runtime (override precedence).
#
# Fully hermetic: local temp dirs + a stub herdr. NO real herdr/claude/codex/gh/network/model.
# Run:  bash tests/test-drainer-permission-flags.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPTS="$ROOT/scripts/herd"
GREP=/usr/bin/grep; command -v "$GREP" >/dev/null 2>&1 || GREP=grep

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── Hermetic project + a stub herdr that records the `agent start` argv it is handed. ───────────────
PROJ="$T/proj"; TREES="$T/trees"; mkdir -p "$PROJ/.herd" "$TREES"
cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$TREES"
EOF

BIN="$T/bin"; mkdir -p "$BIN"
CAP="$T/launch.argv"
cat > "$BIN/herdr" <<STUB
#!/usr/bin/env bash
# Minimal herdr: enough for the drainers' tab-create + roster probe + the pre-0.7.5 agent-start spawn.
case "\$1 \$2" in
  "tab create")     printf '{"result":{"tab":{"tab_id":"T1"},"root_pane":{"pane_id":"P1"}}}\n' ;;
  "agent list")     printf '{"result":{"agents":[]}}\n' ;;
  "workspace list") printf '{"result":{"workspaces":[]}}\n' ;;
  "agent start")    : > "$CAP"; for a in "\$@"; do printf '%s\n' "\$a" >> "$CAP"; done ;;
  *)                : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"

# run_drainer <script> <VAR=VAL …> — run the drainer hermetically and echo the composed RUNTIME TAIL
# (the tokens after the `--` the stub recorded), space-joined on one line. Empty on no capture.
run_drainer() {
  local script="$1"; shift
  rm -f "$CAP"
  ( set -a
    HERD_CONFIG_FILE="$PROJ/.herd/config"
    HERD_DRIVERS_DIR="$ROOT/templates/drivers"
    HERD_HERDR_ATTACH_CLI=no            # force the byte-identical `agent start … -- <runtime>` shape
    PATH="$BIN:$PATH"
    set +a
    # Each named override (HERD_DRIVER=…, RESEARCH_MODEL=…, HERD_CLAUDE_FLAGS=…) is exported for the run.
    local kv
    for kv in "$@"; do export "$kv"; done
    bash "$SCRIPTS/$script" "regression question" >/dev/null 2>&1
  )
  [ -f "$CAP" ] || { printf ''; return 0; }
  # Emit only the tokens AFTER the first standalone `--` (the runtime tail).
  awk 'seen{printf "%s%s", sep, $0; sep=" "} $0=="--"{seen=1}' "$CAP"
}

for pair in "research.sh:RESEARCH_MODEL:🔎" "scribe.sh:SCRIBE_MODEL:✍️"; do
  script="${pair%%:*}"; rest="${pair#*:}"; mvar="${rest%%:*}"
  label="$script"

  # 1. CODEX runtime — the exact HERD-770 repro. Tail must carry the codex bypass flag and NEVER
  #    the claude flag, and must invoke `codex`, not `claude`.
  tail="$(run_drainer "$script" HERD_DRIVER=codex "$mvar=codex:gpt-5.6-terra")"
  case "$tail" in
    codex*) : ;;
    *) fail "($label codex) runtime tail did not launch codex: [$tail]" ;;
  esac
  case "$tail" in
    *--dangerously-bypass-approvals-and-sandbox*) : ;;
    *) fail "($label codex) tail missing --dangerously-bypass-approvals-and-sandbox: [$tail]" ;;
  esac
  case "$tail" in
    *--dangerously-skip-permissions*) fail "($label codex) tail LEAKED the claude-only --dangerously-skip-permissions: [$tail]" ;;
  esac
  case "$tail" in
    *"--model codex:gpt-5.6-terra"*) fail "($label codex) model ref not split (driver prefix reached the runtime): [$tail]" ;;
    *"--model gpt-5.6-terra"*) : ;;
    *) fail "($label codex) tail missing the resolved bare model gpt-5.6-terra: [$tail]" ;;
  esac
  pass

  # 2. CLAUDE / DEFAULT — byte-identical to today's shape. Default driver (HERD_DRIVER unset →
  #    herdr-claude), default model. The tail is exactly `claude --model <model>
  #    --dangerously-skip-permissions <prompt…>`: the permission token sits immediately after the
  #    resolved model, unchanged, and the codex bypass flag never appears.
  tail="$(run_drainer "$script")"
  [[ "$tail" =~ ^claude\ --model\ [^\ ]+\ --dangerously-skip-permissions\  ]] \
    || fail "($label default) tail not byte-identical to the claude shape: [$tail]"
  case "$tail" in
    *--dangerously-bypass-approvals-and-sandbox*) fail "($label default) default spawn wrongly carries the codex bypass flag: [$tail]" ;;
  esac
  pass

  # 3. EXPLICIT OVERRIDE — HERD_CLAUDE_FLAGS wins verbatim for ANY runtime (precedence preserved).
  #    Under the codex runtime the override REPLACES the driver's own permission token.
  tail="$(run_drainer "$script" HERD_DRIVER=codex "$mvar=codex:gpt-5.6-terra" HERD_CLAUDE_FLAGS="--foo --bar")"
  case "$tail" in
    *"--foo --bar"*) : ;;
    *) fail "($label override) explicit HERD_CLAUDE_FLAGS not honored verbatim: [$tail]" ;;
  esac
  case "$tail" in
    *--dangerously-bypass-approvals-and-sandbox*) fail "($label override) override did not replace the driver's own permission flag: [$tail]" ;;
    *--dangerously-skip-permissions*) fail "($label override) override did not replace the permission flag: [$tail]" ;;
  esac
  pass
done

# ── Wiring guard: neither drainer eagerly hardcodes the claude flag; both route through the seam. ───
for f in research scribe; do
  ! "$GREP" -Eq '^[[:space:]]*CLAUDE_FLAGS="\$\{HERD_CLAUDE_FLAGS:---dangerously-skip-permissions\}"' "$SCRIPTS/$f.sh" \
    || fail "(wiring) $f.sh still eagerly hardcodes CLAUDE_FLAGS to the claude flag"
  "$GREP" -q 'herd_driver_lane_permission_flags' "$SCRIPTS/$f.sh" \
    || fail "(wiring) $f.sh does not resolve flags through herd_driver_lane_permission_flags"
done
pass

echo "ALL PASS ($PASS checks)"
