#!/usr/bin/env bash
# test-scoped-builder-verification.sh — hermetic proof for the SCOPED builder verification block (HERD-99).
#
# The lane task-spec preamble (herd-quick.sh / herd-feature.sh) used to tell every builder to run the
# WHOLE healthcheck ('healthcheck.sh <dir>' with no profile → auto-heavy on a heavy-glob diff) before
# opening a PR — which the watcher then re-ran at gate time, paying the full heavy suite twice per PR.
# HERD-99 SCOPES the builder-side instruction to the change's own surface (the LIGHT profile + the
# builder's own new/changed tests) while leaving the watcher's gate-time full run as the authoritative
# pass. This proves that scoping, for BOTH lanes, without weakening any gate.
#
# Asserts, for BOTH lanes:
#   (a) the generated spec CONTAINS the scoped verification block — the --light invocation, the
#       explicit DESCOPED note naming what the builder no longer owns, the pointer that the watcher
#       re-runs the FULL profile as the authoritative gate, and the still-available --heavy escape.
#   (b) the generated spec NO LONGER contains the blanket full-suite instruction — the old bare
#       'healthcheck.sh "<dir>"  and get a clean pass' with NO profile flag.
#   (c) the scoped block sits in the STABLE preamble region (before the per-task body), so the shared
#       prompt-cache prefix stays maximal (same discipline the context-provision test asserts).
#   (d) lane behavior ASIDE FROM the spec text is unchanged: the agent-start argv is byte-identical to
#       the SHORT externalized pointer (carrying NONE of the verification text), and the herdr call
#       sequence (tab create → agent start) is unchanged — the behavior delta is confined to spec text.
#
# Fully hermetic: a throwaway git repo (so new-feature.sh's worktree add works) + stubbed herdr/claude
# (NETWORK-FREE, no real tabs/agent). Mirrors tests/test-context-provision.sh.
# Run:  bash tests/test-scoped-builder-verification.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QUICK="$HERE/../scripts/herd/herd-quick.sh"
FEATURE="$HERE/../scripts/herd/herd-feature.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git    >/dev/null 2>&1 || fail "git required to run this test"

BIG_TASK="SENTINEL_TASK_BODY build the scoped-verification thing"$'\n'"line-two SENTINEL_TASK_L2"
# The exact short pointer herd_write_task_spec hands the agent in place of the multi-KB spec.
POINTER_MARK="Read your task spec at"
# A stable substring of any verification prose — must NEVER leak into the argv (stays in the spec file).
VERIF_LEAK_MARK="healthcheck.sh"

# ── Stubs (mirror tests/test-context-provision.sh) ────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "tab list")       printf '{"result":{"tabs":[]}}\n' ;;
  "tab create")     printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start")    printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  "pane split")     printf '{"result":{"pane":{"pane_id":"pTest"}}}\n' ;;
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
export HOME="$T"                  # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit"
export HERD_SKIP_PREFLIGHT=1
TREES="$T/trees"
CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
{
  printf 'PROJECT_ROOT="%s"\n'   "$REPO"
  printf 'WORKTREES_DIR="%s"\n'  "$TREES"
  printf 'DEFAULT_BRANCH="origin/main"\n'
  printf 'WORKSPACE_NAME="herdkit"\n'
  printf 'APP_PREVIEW_CMD=""\n'
  printf 'MODEL_QUICK="test-quick-model"\n'
  printf 'MODEL_FEATURE="test-feature-model"\n'
} > "$CFG"

agent_start_line() { grep -E 'agent start .*-- claude' "$T/$1.herdr.log" 2>/dev/null | head -1; }
run_lane() {
  local script="$1" slug="$2"
  export HERDR_CALL_LOG="$T/$slug.herdr.log"; : > "$HERDR_CALL_LOG"
  HERD_NO_APP=1 bash "$script" "$slug" "$BIG_TASK" > "$T/$slug.out" 2>&1 \
    || fail "$(basename "$script") exited non-zero for '$slug'"$'\n'"$(cat "$T/$slug.out")"
}

for pair in "quick $QUICK" "feat $FEATURE"; do
  set -- $pair; slug="sv-$1"; script="$2"
  run_lane "$script" "$slug"
  spec="$TREES/$slug.task.md"
  [ -f "$spec" ] || fail "$slug: spec file not written at $spec"
  grep -q "\[workflow rules\]" "$spec" || fail "$slug: spec missing the workflow-rules preamble"

  # ── (a) the scoped verification block is present ───────────────────────────────────────────────
  grep -q 'healthcheck.sh ".*" --light' "$spec"       || fail "$slug: scoped --light invocation missing from the spec"
  grep -q "DESCOPED"                     "$spec"       || fail "$slug: the explicit DESCOPED note is missing"
  grep -q "AUTHORITATIVE merge gate"     "$spec"       || fail "$slug: the 'watcher re-runs the authoritative full profile' pointer is missing"
  grep -q 'healthcheck.sh ".*" --heavy'  "$spec"       || fail "$slug: the still-available --heavy escape hatch is missing (descoped must mean optional, not forbidden)"

  # ── (a2) the conformance-map builder convention rides in the same STABLE preamble (HERD-152) ────
  grep -q "templates/conformance.tsv" "$spec"          || fail "$slug: the conformance-map convention (add a proof/none-yet row for a new capability) is missing from the preamble"

  # ── (b) the blanket full-suite instruction is GONE ─────────────────────────────────────────────
  # The old preamble ran the profile-less 'healthcheck.sh "<dir>"  and get a clean pass' (auto → heavy
  # on a heavy-glob diff). A bare invocation with no --light/--heavy flag directly followed by "and
  # get a clean pass" is exactly that blanket instruction — it must no longer appear.
  if grep -Eq 'healthcheck\.sh "[^"]*"  and get a clean pass' "$spec"; then
    fail "$slug: the blanket full-suite instruction ('healthcheck.sh <dir>  and get a clean pass', no profile) is still present"
  fi

  # ── (c) the scoped block sits in the STABLE preamble, before the per-task body ─────────────────
  verif_ln=$(grep -n "DESCOPED"           "$spec" | head -1 | cut -d: -f1)
  body_ln=$( grep -n "SENTINEL_TASK_BODY" "$spec" | head -1 | cut -d: -f1)
  [ -n "$verif_ln" ] && [ -n "$body_ln" ] || fail "$slug: could not locate verification/body lines"
  [ "$verif_ln" -lt "$body_ln" ] || fail "$slug: the scoped block ($verif_ln) is NOT before the per-task body ($body_ln) — not in the stable preamble"

  # ── (d) lane behavior aside from spec text is unchanged: argv is the SHORT pointer only ────────
  line="$(agent_start_line "$slug")"
  case "$line" in *"$POINTER_MARK $spec"*) : ;; *) fail "$slug: agent-start argv is not the short spec-file pointer"$'\n'"$line" ;; esac
  case "$line" in *"$VERIF_LEAK_MARK"*) fail "$slug: verification text leaked into the agent-start argv (must stay externalized in the spec file)"$'\n'"$line" ;; esac
  # The herdr call sequence is unchanged: a tab was created and an agent started (no extra/missing calls).
  grep -Eq '^tab create' "$T/$slug.herdr.log" || fail "$slug: herdr 'tab create' call missing — lane runtime behavior changed"
  [ "$(grep -Ec 'agent start' "$T/$slug.herdr.log")" -eq 1 ] || fail "$slug: expected exactly one 'agent start' herdr call"
done
pass; echo "PASS (a-d) both lanes: scoped verification block present, blanket instruction gone, in the STABLE preamble, argv still externalized"

echo "ALL PASS ($PASS groups)"
