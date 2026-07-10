#!/usr/bin/env bash
# test-model-preflight.sh — hermetic sim of the MODEL ACCESSIBILITY PREFLIGHT (HERD-282): builder
# lanes must refuse EARLY when the resolved runtime binary is not on PATH, rather than launching a
# doomed builder that wedges silently at an empty prompt.
#
# Proves three properties for BOTH lanes (herd-quick.sh / herd-feature.sh):
#   A. BOGUS MODEL (runtime binary missing from PATH) → lane exits 1 with a loud ❌ message naming
#      the bad ref and the missing binary; no worktree created, no agent started, no claim made.
#   B. FINE MODEL (runtime binary present via stub) → lane proceeds normally, agent started (byte-
#      identical to before this check when the model is accessible).
#   C. BYPASS (HERD_SKIP_MODEL_PREFLIGHT=1) → preflight is skipped; lane proceeds even for a
#      missing binary (test / CI escape hatch, mirrors HERD_SKIP_PREFLIGHT).
#
# Also proves the unit-level behavior of herd_model_preflight_accessible (driver.sh) directly:
#   D. Function returns 0 (no output) for a fine model / missing binary with BYPASS.
#   E. Function returns 1 with a loud ❌ for a definitively missing binary.
#   F. Function returns 0 (fail-soft) when the driver has no resolvable binary.
#
# Fully hermetic: stub herdr/claude/gh binaries + a custom HERD_DRIVERS_DIR + a throwaway git sandbox.
# Run:  bash tests/test-model-preflight.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DRIVER_SH="$ROOT/scripts/herd/driver.sh"
QUICK="$ROOT/scripts/herd/herd-quick.sh"
FEATURE="$ROOT/scripts/herd/herd-feature.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git    >/dev/null 2>&1 || fail "git required to run this test"
for f in "$DRIVER_SH" "$QUICK" "$FEATURE"; do [ -f "$f" ] || fail "missing script: $f"; done

# ── Stub binaries + a custom drivers dir ─────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "tab list")    printf '{"result":{"tabs":[]}}\n' ;;
  "tab create")  printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start") printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  "pane split")  printf '{"result":{"pane":{"pane_id":"pTest"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then printf '[]'; exit 0; fi
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# A custom drivers directory containing both the real herdr-claude driver (for the fine-model case)
# and a fake driver whose interactive-spawn binary is deliberately not on PATH.
DD="$T/drivers"; mkdir -p "$DD"
cp "$ROOT/templates/drivers/herdr-claude.driver" "$DD/herdr-claude.driver"
cp "$ROOT/templates/drivers/headless.driver"     "$DD/headless.driver"
# fake-missing: a driver whose runtime binary 'totally-missing-runtime' is NOT on PATH.
cat > "$DD/fake-missing.driver" <<'DRV'
DRIVER_AGENT_INTERACTIVE_SPAWN='totally-missing-runtime --model <model> "<prompt>"'
DRIVER_AGENT_ONESHOT_EXEC='totally-missing-runtime -p "<prompt>" --model <model>'
DRIVER_AGENT_PERMISSION_FLAG='--always-approve'
DRV
export HERD_DRIVERS_DIR="$DD"

# ── Throwaway git repo (new-feature.sh needs a real worktree) ─────────────────────────────────────
REPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
: > "$REPO/seed.txt"
git -C "$REPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null

export HOME="$T"          # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit"
export HERD_SKIP_PREFLIGHT=1
export HERD_NO_APP=1
LTREES="$T/trees"; mkdir -p "$LTREES"
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"

# write_cfg <MODEL_QUICK_value> — write a minimal hermetic project config.
write_cfg() {
  cat > "$CFG" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$LTREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit"
APP_PREVIEW_CMD=""
REVIEW_CONCURRENCY="2"
SPAWN_AHEAD="1"
MODEL_QUICK="${1:-claude-sonnet-4-6}"
MODEL_FEATURE="${1:-claude-sonnet-4-6}"
EOF
}

# run_lane <lane-script> <slug> — run a lane; capture output + herdr call log.
run_lane() {
  local script="$1" slug="$2"
  export HERDR_CALL_LOG="$T/$slug.herdr.log"; : > "$HERDR_CALL_LOG"
  bash "$script" "$slug" "do a thing" > "$T/$slug.out" 2>&1
  echo $?
}
agent_started() { grep -q "agent start" "$T/$1.herdr.log"; }
worktree_exists() { [ -d "$LTREES/$1" ]; }
journal_event()  { grep -q "$2" "$LTREES/.herd/journal.jsonl" 2>/dev/null; }

# ══ D. Unit-level: herd_model_preflight_accessible in driver.sh ══════════════════════════════════
(
  set +e
  export HERD_DRIVERS_DIR="$DD"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"

  # D1: fine model (binary 'claude' IS on PATH via our stub) → returns 0, no output.
  out="$(herd_model_preflight_accessible "claude-sonnet-4-6" "herdr-claude" "claude-sonnet-4-6" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || fail "D1: fine model should return 0 (got rc=$rc)"
  [ -z "$out"  ] || fail "D1: fine model should produce no output (got: $out)"

  # D2: missing binary → returns 1 with ❌ naming the bad ref and the missing binary.
  out="$(herd_model_preflight_accessible "fake-missing:grok-4.5" "fake-missing" "grok-4.5" 2>&1)"
  rc=$?
  [ "$rc" -eq 1 ] || fail "D2: missing binary should return 1 (got rc=$rc)"
  case "$out" in *'❌'*) : ;; *) fail "D2: missing binary must emit ❌ (got: $out)" ;; esac
  case "$out" in *'fake-missing:grok-4.5'*) : ;; *) fail "D2: error must name the bad ref (got: $out)" ;; esac
  case "$out" in *'totally-missing-runtime'*) : ;; *) fail "D2: error must name the missing binary (got: $out)" ;; esac
  case "$out" in *'fake-missing'*) : ;; *) fail "D2: error must name the driver (got: $out)" ;; esac

  # D3: bypass (HERD_SKIP_MODEL_PREFLIGHT=1) with a missing binary → returns 0, no output.
  out="$(HERD_SKIP_MODEL_PREFLIGHT=1 herd_model_preflight_accessible "fake-missing:x" "fake-missing" "x" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || fail "D3: bypass should return 0 (got rc=$rc)"
  [ -z "$out"  ] || fail "D3: bypass should produce no output (got: $out)"

  # D4: driver has no resolvable binary (empty/absent .driver file) → fail-soft, returns 0.
  printf '' > "$DD/nobinary.driver"   # empty driver file → herd_driver_agent_runtime returns empty
  out="$(herd_model_preflight_accessible "nobinary:x" "nobinary" "x" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || fail "D4: unresolvable binary should fail-soft (return 0), got rc=$rc"
  [ -z "$out"  ] || fail "D4: fail-soft case must produce no output (got: $out)"

  # D5: empty driver arg → fail-soft, returns 0.
  out="$(herd_model_preflight_accessible "some-ref" "" "some-model" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || fail "D5: empty driver should fail-soft (return 0), got rc=$rc"

  exit 0
) || exit 1
pass; echo "PASS (D) unit: herd_model_preflight_accessible — fine/missing/bypass/fail-soft cases"

# ══ A. Lane refuses: bogus model with missing runtime binary ══════════════════════════════════════
for lane_script in "$QUICK" "$FEATURE"; do
  lane_name="$(basename "$lane_script" .sh)"

  write_cfg "fake-missing:grok-4.5"
  rc="$(run_lane "$lane_script" "bogus-${lane_name}")"

  [ "$rc" = "1" ] || fail "A (${lane_name}): bogus model must exit 1 (got rc=$rc)"$'\n'"$(cat "$T/bogus-${lane_name}.out")"
  case "$(cat "$T/bogus-${lane_name}.out")" in
    *'❌'*) : ;;
    *) fail "A (${lane_name}): refusal must print ❌"$'\n'"$(cat "$T/bogus-${lane_name}.out")" ;;
  esac
  case "$(cat "$T/bogus-${lane_name}.out")" in
    *'fake-missing:grok-4.5'*) : ;;
    *) fail "A (${lane_name}): refusal must name the bad model ref"$'\n'"$(cat "$T/bogus-${lane_name}.out")" ;;
  esac
  case "$(cat "$T/bogus-${lane_name}.out")" in
    *'totally-missing-runtime'*) : ;;
    *) fail "A (${lane_name}): refusal must name the missing binary"$'\n'"$(cat "$T/bogus-${lane_name}.out")" ;;
  esac
  agent_started  "bogus-${lane_name}" && fail "A (${lane_name}): bogus model must NOT start an agent"
  worktree_exists "bogus-${lane_name}" && fail "A (${lane_name}): bogus model must NOT create a worktree"
  journal_event "bogus-${lane_name}" "model_preflight_refused" \
    || fail "A (${lane_name}): refusal must journal model_preflight_refused"

  pass; echo "PASS (A) ${lane_name}: bogus model with missing binary refuses loudly, creates nothing"
done

# ══ B. Lane proceeds: fine model (claude stub is on PATH) ════════════════════════════════════════
for lane_script in "$QUICK" "$FEATURE"; do
  lane_name="$(basename "$lane_script" .sh)"

  write_cfg "claude-sonnet-4-6"
  rc="$(run_lane "$lane_script" "fine-${lane_name}")"

  [ "$rc" = "0" ] || fail "B (${lane_name}): fine model must exit 0 (got rc=$rc)"$'\n'"$(cat "$T/fine-${lane_name}.out")"
  agent_started "fine-${lane_name}" || fail "B (${lane_name}): fine model must start an agent"
  worktree_exists "fine-${lane_name}" || fail "B (${lane_name}): fine model must create a worktree"

  pass; echo "PASS (B) ${lane_name}: fine model proceeds normally, agent started"
done

# ══ C. Bypass: HERD_SKIP_MODEL_PREFLIGHT=1 lets the lane through even with a missing binary ═════
for lane_script in "$QUICK" "$FEATURE"; do
  lane_name="$(basename "$lane_script" .sh)"

  write_cfg "fake-missing:grok-4.5"
  # With the bypass, the lane gets past the preflight and then tries to launch the agent.
  # The agent launch will fail (totally-missing-runtime is not a real agent), but that is expected —
  # we only care that the PREFLIGHT is bypassed (the worktree is created and the lane proceeds past
  # the model check into the spawn attempt). Capture the exit code but don't require 0.
  rc="$(HERD_SKIP_MODEL_PREFLIGHT=1 run_lane "$lane_script" "bypass-${lane_name}")"
  # The preflight did NOT refuse — evidence: the worktree was created (the lane got past the check).
  worktree_exists "bypass-${lane_name}" \
    || fail "C (${lane_name}): bypass must let the lane past the preflight (worktree not created)"$'\n'"$(cat "$T/bypass-${lane_name}.out")"
  # The lane must NOT have printed the preflight ❌ message.
  grep -q "herd: model.*cannot spawn" "$T/bypass-${lane_name}.out" \
    && fail "C (${lane_name}): bypass must suppress the preflight ❌ message"$'\n'"$(cat "$T/bypass-${lane_name}.out")"

  pass; echo "PASS (C) ${lane_name}: HERD_SKIP_MODEL_PREFLIGHT=1 bypasses the preflight (lane proceeds past the check)"
done

echo "ALL PASS ($PASS checks)"
