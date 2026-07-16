#!/usr/bin/env bash
# test-model-escalate.sh — hermetic proof of MODEL_ESCALATE_GLOB, the deterministic model step-up,
# and MODEL_ESCALATE (HERD-376), the key naming WHICH model a match forces.
#
# Both lanes (herd-quick.sh, herd-feature.sh) resolve the model they pass to `claude --model` and,
# BEFORE spawning, force the escalation target — MODEL_ESCALATE if the operator set one, else
# MODEL_FEATURE (today's default) — when the coordinator-passed task text matches the egrep -i
# MODEL_ESCALATE_GLOB — overriding MODEL_QUICK and any per-spawn HERD_QUICK_MODEL / HERD_FEATURE_MODEL
# override. This guards the misjudgment case where a judgment-heavy engine PR is routed through the
# cheap quick lane, and (via MODEL_ESCALATE) lets the glob still reach a genuinely stronger tier now
# that MODEL_FEATURE itself defaults to a cheaper sonnet tier (HERD-102).
#
# Asserts, for BOTH lanes:
#   (a) glob MATCHES, MODEL_ESCALATE UNSET → resolves MODEL_FEATURE even when MODEL_QUICK is cheaper
#       AND even when a per-spawn quick/feature override is set (today's exact behavior, unchanged).
#   (b) glob EMPTY or NON-MATCHING → normal per-lane resolution is unchanged (regression guard).
#   (c) the 'escalated to <model> (MODEL_ESCALATE_GLOB matched)' notice is printed on match.
#   (d) glob MATCHES, MODEL_ESCALATE SET → resolves MODEL_ESCALATE (not MODEL_FEATURE), even over a
#       per-spawn override, and the notice names the MODEL_ESCALATE value.
#   (e) MODEL_ESCALATE explicitly EMPTY behaves byte-identically to unset (ship-dormant default).
#   (f) a runtime-qualified MODEL_ESCALATE ref ('<driver>:<model>') resolves through the SAME
#       herd_model_for_spawn/herd_model_driver_for shim as every other MODEL_* key.
#
# Fully hermetic: a throwaway git repo (so new-feature.sh's worktree add works) + stubbed herdr/claude
# (NETWORK-FREE, no real tabs, no real agent). We assert on the resolved `--model` arg in the logged
# `herdr agent start … -- claude --model …` invocation — never launching a real builder.
# Run:  bash tests/test-model-escalate.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QUICK="$HERE/../scripts/herd/herd-quick.sh"
FEATURE="$HERE/../scripts/herd/herd-feature.sh"
DRIVER_SH="$HERE/../scripts/herd/driver.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git    >/dev/null 2>&1 || fail "git required to run this test"

# ── Sentinel model tiers so the grep is unambiguous ────────────────────────────
Q_MODEL="MODEL-QUICK-CHEAP"      # MODEL_QUICK — the cheap default the escalation must beat
F_MODEL="MODEL-FEATURE-OPUS"     # MODEL_FEATURE — the tier the glob forces
OVERRIDE="MODEL-PERSPAWN-CHEAP"  # a per-spawn override that must ALSO lose to a matched glob

# ── Stubs (mirrors tests/test-model-flags.sh) ──────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
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
export PATH="$BIN:$PATH"

# ── Throwaway git repo so new-feature.sh's `git worktree add … origin/main` succeeds ───────────
REPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
: > "$REPO/seed.txt"
git -C "$REPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null

# ── Hermetic env ───────────────────────────────────────────────────────────────
export HOME="$T"                  # herd_pretrust_worktree writes $HOME/.claude.json — keep it in the sandbox
export WORKSPACE_NAME="herdkit"   # matches the herdr stub's workspace label
export HERD_SKIP_PREFLIGHT=1      # no real herdr contract to probe
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"

# mkconfig <escalate_glob> [model_escalate] — write the project config with a given MODEL_ESCALATE_GLOB
# (and, optionally, MODEL_ESCALATE — the key naming which model a match forces) value.
mkconfig() {
  cat > "$CFG" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit"
APP_PREVIEW_CMD=""
MODEL_QUICK="$Q_MODEL"
MODEL_FEATURE="$F_MODEL"
MODEL_ESCALATE_GLOB='${1:-}'
MODEL_ESCALATE='${2:-}'
EOF
}

# run_lane <script> <slug> <task> — run a lane hermetically; captures stdout+stderr to $OUT and the
# herdr call log to $HERDR_CALL_LOG. Per-spawn overrides come from the caller's environment.
run_lane() {
  local script="$1" slug="$2" task="$3"
  export HERDR_CALL_LOG="$T/$slug.herdr.log"; : > "$HERDR_CALL_LOG"
  OUT="$T/$slug.out"
  HERD_NO_APP=1 bash "$script" "$slug" "$task" > "$OUT" 2>&1 \
    || fail "$(basename "$script") exited non-zero for '$slug'"$'\n'"$(cat "$OUT")"
}

# resolved_model <slug> — the model actually passed to `claude --model` in the agent-start call.
resolved_model() {
  grep -oE 'agent start .*-- claude --model [^ ]+' "$T/$1.herdr.log" | grep -oE '[^ ]+$' | head -1
}

MATCH_TASK="Refactor cmd_reload wiring in bin/herd so reload targets the workspace"
PLAIN_TASK="Fix a small typo in the README onboarding paragraph"
GLOB='bin/herd|scripts/herd/agent-watch|herd-review|cmd_reload'

# ── (a) QUICK lane, glob matches, MODEL_QUICK cheap, no override → forces MODEL_FEATURE + notice ─
mkconfig "$GLOB"
( unset HERD_QUICK_MODEL HERD_FEATURE_MODEL; run_lane "$QUICK" "esc-quick-match" "$MATCH_TASK"
  m="$(resolved_model esc-quick-match)"
  [ "$m" = "$F_MODEL" ] || fail "quick lane: glob match did not force MODEL_FEATURE (got '$m')"$'\n'"$(cat "$T/esc-quick-match.herdr.log")"
  grep -qE "escalated to $F_MODEL \(MODEL_ESCALATE_GLOB matched\)" "$OUT" \
    || fail "quick lane: escalation notice not printed on match"$'\n'"$(cat "$OUT")"
) || exit 1

# ── (a) QUICK lane, glob matches, WITH a cheaper per-spawn HERD_QUICK_MODEL override → still FEATURE
mkconfig "$GLOB"
( export HERD_QUICK_MODEL="$OVERRIDE"; run_lane "$QUICK" "esc-quick-ovr" "$MATCH_TASK"
  m="$(resolved_model esc-quick-ovr)"
  [ "$m" = "$F_MODEL" ] || fail "quick lane: per-spawn HERD_QUICK_MODEL override survived a matched glob (got '$m')"
) || exit 1

# ── (a) FEATURE lane, glob matches, WITH a cheaper per-spawn HERD_FEATURE_MODEL override → FEATURE + notice
mkconfig "$GLOB"
( export HERD_FEATURE_MODEL="$OVERRIDE"; run_lane "$FEATURE" "esc-feat-ovr" "$MATCH_TASK"
  m="$(resolved_model esc-feat-ovr)"
  [ "$m" = "$F_MODEL" ] || fail "feature lane: per-spawn HERD_FEATURE_MODEL override survived a matched glob (got '$m')"
  grep -qE "escalated to $F_MODEL \(MODEL_ESCALATE_GLOB matched\)" "$OUT" \
    || fail "feature lane: escalation notice not printed on match"$'\n'"$(cat "$OUT")"
) || exit 1

# ── (b) QUICK lane, glob EMPTY → normal resolution (MODEL_QUICK), no notice (regression guard) ───
mkconfig ""
( unset HERD_QUICK_MODEL HERD_FEATURE_MODEL; run_lane "$QUICK" "esc-quick-empty" "$MATCH_TASK"
  m="$(resolved_model esc-quick-empty)"
  [ "$m" = "$Q_MODEL" ] || fail "quick lane: empty glob changed model resolution (got '$m', want '$Q_MODEL')"
  grep -qE "MODEL_ESCALATE_GLOB matched" "$OUT" && fail "quick lane: notice printed with empty glob" || true
) || exit 1

# ── (b) QUICK lane, glob set but NON-matching task → normal resolution, no notice ────────────────
mkconfig "$GLOB"
( unset HERD_QUICK_MODEL HERD_FEATURE_MODEL; run_lane "$QUICK" "esc-quick-nomatch" "$PLAIN_TASK"
  m="$(resolved_model esc-quick-nomatch)"
  [ "$m" = "$Q_MODEL" ] || fail "quick lane: non-matching task escalated anyway (got '$m', want '$Q_MODEL')"
  grep -qE "MODEL_ESCALATE_GLOB matched" "$OUT" && fail "quick lane: notice printed on a non-match" || true
) || exit 1

# ── (b) QUICK lane, glob empty, WITH a per-spawn override → the override is honored unchanged ─────
mkconfig ""
( export HERD_QUICK_MODEL="$OVERRIDE"; run_lane "$QUICK" "esc-quick-ovr-off" "$MATCH_TASK"
  m="$(resolved_model esc-quick-ovr-off)"
  [ "$m" = "$OVERRIDE" ] || fail "quick lane: empty glob did not honor HERD_QUICK_MODEL override (got '$m')"
) || exit 1

# ── (b) FEATURE lane, glob empty → normal resolution (MODEL_FEATURE) ─────────────────────────────
mkconfig ""
( unset HERD_QUICK_MODEL HERD_FEATURE_MODEL; run_lane "$FEATURE" "esc-feat-empty" "$PLAIN_TASK"
  m="$(resolved_model esc-feat-empty)"
  [ "$m" = "$F_MODEL" ] || fail "feature lane: empty glob changed model resolution (got '$m', want '$F_MODEL')"
) || exit 1

# ── (d) MODEL_ESCALATE set: a matched glob forces MODEL_ESCALATE, NOT MODEL_FEATURE ─────────────
ESCALATE_MODEL="MODEL-ESCALATE-STRONG"

# QUICK lane, glob matches, MODEL_ESCALATE set, no per-spawn override → forces MODEL_ESCALATE + notice
mkconfig "$GLOB" "$ESCALATE_MODEL"
( unset HERD_QUICK_MODEL HERD_FEATURE_MODEL; run_lane "$QUICK" "esc-quick-me" "$MATCH_TASK"
  m="$(resolved_model esc-quick-me)"
  [ "$m" = "$ESCALATE_MODEL" ] || fail "quick lane: MODEL_ESCALATE set but glob match resolved '$m' (want '$ESCALATE_MODEL')"
  grep -qE "escalated to $ESCALATE_MODEL \(MODEL_ESCALATE_GLOB matched\)" "$OUT" \
    || fail "quick lane: escalation notice did not name MODEL_ESCALATE"$'\n'"$(cat "$OUT")"
) || exit 1

# QUICK lane, glob matches, MODEL_ESCALATE set, WITH a per-spawn override → MODEL_ESCALATE still wins
mkconfig "$GLOB" "$ESCALATE_MODEL"
( export HERD_QUICK_MODEL="$OVERRIDE"; run_lane "$QUICK" "esc-quick-me-ovr" "$MATCH_TASK"
  m="$(resolved_model esc-quick-me-ovr)"
  [ "$m" = "$ESCALATE_MODEL" ] || fail "quick lane: per-spawn override survived a matched glob over MODEL_ESCALATE (got '$m')"
) || exit 1

# FEATURE lane, glob matches, MODEL_ESCALATE set, WITH a per-spawn override → MODEL_ESCALATE still wins + notice
mkconfig "$GLOB" "$ESCALATE_MODEL"
( export HERD_FEATURE_MODEL="$OVERRIDE"; run_lane "$FEATURE" "esc-feat-me-ovr" "$MATCH_TASK"
  m="$(resolved_model esc-feat-me-ovr)"
  [ "$m" = "$ESCALATE_MODEL" ] || fail "feature lane: per-spawn override survived a matched glob over MODEL_ESCALATE (got '$m')"
  grep -qE "escalated to $ESCALATE_MODEL \(MODEL_ESCALATE_GLOB matched\)" "$OUT" \
    || fail "feature lane: escalation notice did not name MODEL_ESCALATE"$'\n'"$(cat "$OUT")"
) || exit 1

# ── (e) MODEL_ESCALATE explicitly EMPTY behaves byte-identically to unset (ship-dormant default) ──
mkconfig "$GLOB" ""
( unset HERD_QUICK_MODEL HERD_FEATURE_MODEL; run_lane "$QUICK" "esc-quick-me-empty" "$MATCH_TASK"
  m="$(resolved_model esc-quick-me-empty)"
  [ "$m" = "$F_MODEL" ] || fail "quick lane: empty MODEL_ESCALATE did not fall back to MODEL_FEATURE (got '$m')"
) || exit 1

# ── (f) a runtime-qualified MODEL_ESCALATE ref resolves through the SAME driver shim as MODEL_FEATURE ─
# Mirrors tests/test-driver-lane-spawn.sh's foreign-driver proof: a made-up runtime driver, catalogued
# only in a throwaway HERD_DRIVERS_DIR, must still split correctly — proving MODEL_ESCALATE is not a
# second, parallel resolution path but flows through herd_model_for_spawn/herd_model_driver_for exactly
# as MODEL_FEATURE always has.
DD="$T/drivers"; mkdir -p "$DD"
cat > "$DD/foreign.driver" <<'DRV'
DRIVER_AGENT_INTERACTIVE_SPAWN='myrt run --model <model> --yolo "<prompt>"'
DRIVER_AGENT_PERMISSION_FLAG='--yolo'
DRV
( set +e
  export HERD_DRIVERS_DIR="$DD"
  MODEL_FEATURE="$F_MODEL" MODEL_ESCALATE="foreign:strong-ref"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"
  target="$(herd_model_escalate_target)"
  [ "$target" = "foreign:strong-ref" ] || { echo "FAIL: herd_model_escalate_target → '$target' (want 'foreign:strong-ref')"; exit 1; }
  drv="$(herd_model_driver_for "$target")" || { echo "FAIL: herd_model_driver_for could not resolve '$target'"; exit 1; }
  mdl="$(herd_model_for_spawn "$target")"  || { echo "FAIL: herd_model_for_spawn could not resolve '$target'"; exit 1; }
  [ "$drv" = "foreign" ]    || { echo "FAIL: resolved driver '$drv' != 'foreign'"; exit 1; }
  [ "$mdl" = "strong-ref" ] || { echo "FAIL: resolved model '$mdl' != 'strong-ref'"; exit 1; }
  exit 0
) || fail "runtime-qualified MODEL_ESCALATE did not resolve through the shared driver shim (see FAIL above)"

echo "ALL PASS"
