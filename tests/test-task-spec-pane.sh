#!/usr/bin/env bash
# test-task-spec-pane.sh — hermetic proof of the builder-tab task-spec pane viewer (TASK_PANE_VIEW,
# default on) plus the backend-mode list_to_md readability reshape. Fully network-free: throwaway git
# repos + stubbed herdr/claude, no real tabs/panes/agents, no model, no gh.
#
# Coverage:
#   1. VIEWER SCRIPT (task-spec-view.sh) — renders a present spec (cat fallback), shows a QUIET DIM
#      'task spec removed' line (no red, per the no-false-red rule) for a missing/reaped spec, and is
#      wired to glow + the bundled tokyonight style.
#   2. LANES — herd-quick.sh and herd-feature.sh send the viewer into the tab's ROOT pane via the
#      driver send-text surface (the `herdr pane run` equivalent) when TASK_PANE_VIEW is on/default;
#      NOT when off; herd-feature does NOT when the root pane is hosting the app preview; and the
#      HEADLESS driver cleanly NO-OPs (no pane run at all — panes are a view, not a dependency).
#   3. LAYOUT-RECONCILE — a viewer pane in a BUILDER tab is never scanned into the COORDINATOR tab's
#      snapshot, and classifies as 'busy' (never backlog/watch/agent), so `herd reload` can never
#      misclassify it as a control-room role or flag it as a duplicate viewer to close.
#   4. list_to_md RESHAPE — a tracker "#<id> <title>" line becomes a code-chip id + bold title with a
#      blank line between entries (real theme hierarchy), and the title text is preserved.
#
# Run:  bash tests/test-task-spec-pane.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VIEWER="$ROOT/scripts/herd/task-spec-view.sh"
QUICK="$ROOT/scripts/herd/herd-quick.sh"
FEATURE="$ROOT/scripts/herd/herd-feature.sh"
LAYOUT="$ROOT/scripts/herd/layout-reconcile.sh"
BACKLOG="$ROOT/scripts/herd/backlog-view.sh"
CAPS="$ROOT/templates/capabilities.tsv"
CFG_EXAMPLE="$ROOT/templates/config.example"
HCONFIG="$ROOT/scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "$VIEWER" "$QUICK" "$FEATURE" "$LAYOUT" "$BACKLOG" "$CAPS" "$CFG_EXAMPLE" "$HCONFIG"; do
  [ -f "$f" ] || fail "missing required file: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v git     >/dev/null 2>&1 || fail "git required"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 1. VIEWER SCRIPT — present render, missing-file soft note, tokyonight wiring
# ════════════════════════════════════════════════════════════════════════════════════════════════
# Run with glow OFF PATH so the deterministic cat branch is exercised (glow's TTY colors are stripped
# when captured anyway). MAX_TICKS caps the loop; TICK_SECS=0 keeps it instant.
run_viewer() {
  local spec="$1" out="$2"
  env -i HOME="$HOME" PATH="/usr/bin:/bin" TERM=xterm \
    TASK_PANE_VIEW_MAX_TICKS=1 TASK_PANE_VIEW_TICK_SECS=0 \
    bash "$VIEWER" "$spec" </dev/null >"$out" 2>/dev/null || true
}

SPEC="$T/demo.task.md"
printf '# Task spec\n\n[workflow rules] build the thing SENTINEL_SPEC_BODY\n' > "$SPEC"
run_viewer "$SPEC" "$T/v-present.out"
grep -q "📋 task spec" "$T/v-present.out"       || fail "(1) viewer did not render the task-spec header"
grep -q "SENTINEL_SPEC_BODY" "$T/v-present.out"  || fail "(1) viewer did not render the spec body (cat fallback)"
pass; echo "PASS (1a) viewer renders a present spec (header + body via cat fallback)"

# Missing/reaped spec → one quiet DIM line, never red (no-false-red).
run_viewer "$T/gone.task.md" "$T/v-missing.out"
grep -q "task spec removed" "$T/v-missing.out"  || fail "(1) viewer did not show the quiet 'task spec removed' line for a missing spec"
# The dim SGR is \033[2m; a red foreground/background (\033[...31m / \033[...41m) would violate no-false-red.
if grep -aE $'\033\\[[0-9;]*3[1]m|\033\\[[0-9;]*4[1]m' "$T/v-missing.out" >/dev/null; then
  fail "(1) viewer used a RED color for the missing-spec notice (violates the no-false-red rule)"
fi
grep -aq $'\033\\[2m' "$T/v-missing.out"         || fail "(1) viewer's missing-spec notice is not dim (\\033[2m)"
pass; echo "PASS (1b) missing/reaped spec → quiet DIM 'task spec removed' line, never red"

# Wired to glow + the bundled tokyonight style (the theming requirement), with a cat fallback.
# glow is invoked through the glow_pane wrapper (pins a truecolor profile + detaches the muted
# tty), so accept either the bare `glow` or the `glow_pane` form.
grep -Eq 'glow(_pane)? -s "\$STYLE"' "$VIEWER"   || fail "(1) viewer does not render via glow -s \"\$STYLE\" (tokyonight)"
grep -q 'STYLE="$HERE/tokyonight.json"' "$VIEWER" || fail "(1) viewer does not use the bundled tokyonight.json style"
grep -Eq 'glow(_pane)? -s dark' "$VIEWER"        || fail "(1) viewer lacks the glow -s dark fallback"
grep -Eq 'cat "\$SPEC"' "$VIEWER"                || fail "(1) viewer lacks the plain cat fallback"
pass; echo "PASS (1c) viewer renders via glow + tokyonight style (else glow -s dark, else cat)"

# The glow_pane wrapper must PIN a color profile so repeated repaints render identically without
# re-detecting the terminal (CLICOLOR_FORCE + COLORTERM=truecolor), and detach glow's stdin from the
# keyboard-muted pane tty (</dev/null) so glow never blocks on/misreads its capability probe.
grep -Eq 'glow_pane\(\)' "$VIEWER"                        || fail "(1) viewer lacks the glow_pane wrapper"
grep -Eq 'CLICOLOR_FORCE=1.*COLORTERM=truecolor' "$VIEWER" || fail "(1) glow_pane does not pin a truecolor profile"
grep -q '</dev/null' "$VIEWER"                            || fail "(1) glow_pane does not detach stdin from the muted tty"
pass; echo "PASS (1d) glow_pane pins a truecolor profile + detaches the muted tty"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 2. LANES — viewer sent into ROOT via the driver send-text surface; off/app-preview/headless gates
# ════════════════════════════════════════════════════════════════════════════════════════════════
BIN="$T/bin"; mkdir -p "$BIN"
# Stub herdr — logs EVERY call to $HERDR_CALL_LOG; returns the tab/pane ids the lanes parse.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "tab list")       printf '{"result":{"tabs":[]}}\n' ;;
  "tab create")     printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start")    printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

# Throwaway git repo so new-feature.sh's `git worktree add … origin/main` succeeds.
REPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
: > "$REPO/seed.txt"
git -C "$REPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null

export HOME="$T"                 # herd_pretrust_worktree writes $HOME/.claude.json — keep it sandboxed
export WORKSPACE_NAME="herdkit"  # matches the herdr stub's workspace label
export HERD_SKIP_PREFLIGHT=1
TREES="$T/trees"

# write_cfg <extra lines…> — a fresh .herd/config for one lane run.
make_cfg() {
  local extra="$1"; local cfg="$T/config.$RANDOM"
  cat > "$cfg" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit"
MODEL_QUICK="test-quick-model"
MODEL_FEATURE="test-feature-model"
$extra
EOF
  printf '%s' "$cfg"
}

# run_lane <script> <slug> <cfg> [env KEY=VAL …] — run a lane, logging herdr calls to a per-slug file.
run_lane() {
  local script="$1" slug="$2" cfg="$3"; shift 3
  local log="$T/$slug.herdr.log"; : > "$log"
  env HERD_CONFIG_FILE="$cfg" HERDR_CALL_LOG="$log" WORKSPACE_NAME="herdkit" \
      HOME="$T" HERD_SKIP_PREFLIGHT=1 PATH="$PATH" "$@" \
      bash "$script" "$slug" "seed task" >"$T/$slug.out" 2>&1 || \
      fail "$(basename "$script") exited non-zero for '$slug'"$'\n'"$(cat "$T/$slug.out")"
  printf '%s' "$log"
}

# viewer_run_line <log> — the logged `pane run <pane> bash …task-spec-view.sh …` call, if any.
viewer_run_line() { grep -E 'pane run [^ ]+ bash .*task-spec-view\.sh' "$1" 2>/dev/null | head -1; }

# 2a. herd-quick, TASK_PANE_VIEW default (unset → on) → viewer sent into the ROOT pane (rTest).
CFG="$(make_cfg 'APP_PREVIEW_CMD=""')"
LOG="$(run_lane "$QUICK" "tsp-quick-on" "$CFG")"
line="$(viewer_run_line "$LOG")"
[ -n "$line" ]                                   || fail "(2a) quick lane did not launch the task-spec viewer by default"$'\n'"$(cat "$LOG")"
case "$line" in *"pane run rTest bash"*) : ;; *) fail "(2a) viewer not sent into the ROOT pane (rTest): $line" ;; esac
case "$line" in *"$TREES/tsp-quick-on.task.md"*) : ;; *) fail "(2a) viewer command does not reference the slug's task spec: $line" ;; esac
pass; echo "PASS (2a) herd-quick launches the task-spec viewer into ROOT by default (TASK_PANE_VIEW on)"

# 2b. herd-quick, TASK_PANE_VIEW=off → NO viewer pane run (bare shell restored exactly).
CFG="$(make_cfg 'APP_PREVIEW_CMD=""'$'\n''TASK_PANE_VIEW="off"')"
LOG="$(run_lane "$QUICK" "tsp-quick-off" "$CFG")"
[ -z "$(viewer_run_line "$LOG")" ]               || fail "(2b) quick lane launched the viewer while TASK_PANE_VIEW=off"
pass; echo "PASS (2b) herd-quick TASK_PANE_VIEW=off → no viewer (bare shell restored)"

# 2c. herd-feature with NO app preview (APP_PREVIEW_CMD="") → root pane unused → viewer launched.
CFG="$(make_cfg 'APP_PREVIEW_CMD=""')"
LOG="$(run_lane "$FEATURE" "tsp-feat-noapp" "$CFG")"
line="$(viewer_run_line "$LOG")"
[ -n "$line" ]                                   || fail "(2c) feature lane (no preview) did not launch the viewer in the idle root pane"
case "$line" in *"pane run rTest bash"*) : ;; *) fail "(2c) feature viewer not sent into ROOT (rTest): $line" ;; esac
pass; echo "PASS (2c) herd-feature with no app preview launches the viewer into the idle root pane"

# 2d. herd-feature WITH app preview → root pane hosts app-monitor → viewer NOT launched (never hijack).
CFG="$(make_cfg 'APP_PREVIEW_CMD="echo app"')"
LOG="$(run_lane "$FEATURE" "tsp-feat-app" "$CFG")"
grep -qE 'pane run rTest bash .*app-monitor\.sh' "$LOG" || fail "(2d) app preview was not launched into ROOT — precondition failed"$'\n'"$(cat "$LOG")"
[ -z "$(viewer_run_line "$LOG")" ]               || fail "(2d) viewer clobbered the app-preview pane (must never touch a live process)"
pass; echo "PASS (2d) herd-feature with app preview → viewer withheld (root pane hosts the preview)"

# 2e. HEADLESS driver → no panes → the viewer cleanly no-ops (no task-spec-view pane run at all).
CFG="$(make_cfg 'APP_PREVIEW_CMD=""')"
LOG="$(run_lane "$QUICK" "tsp-quick-headless" "$CFG" HERD_DRIVER=headless)"
[ -z "$(viewer_run_line "$LOG")" ]               || fail "(2e) headless driver launched a viewer pane run (should be a clean no-op)"
[ -d "$TREES/.herd/agents/tsp-quick-headless" ]  || fail "(2e) headless lane did not start a detached agent (registry dir missing)"
pass; echo "PASS (2e) headless driver → viewer is a clean no-op (panes are a view, not a dependency)"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 3. LAYOUT-RECONCILE — a builder-tab viewer is never a control-room role (tab-isolated + 'busy')
# ════════════════════════════════════════════════════════════════════════════════════════════════
# File-backed herdr stub (mirrors test-layout-reconcile.sh): pane list / process-info from $HERDR_STATE.
LBIN="$T/lbin"; mkdir -p "$LBIN"
cat > "$LBIN/herdr" <<'STUB'
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
  *) printf '{"result":{}}\n' ;;
esac
exit 0
STUB
chmod +x "$LBIN/herdr"

(
  export PATH="$LBIN:$PATH"
  S="$T/lstate"; mkdir -p "$S"; export HERDR_STATE="$S"
  # shellcheck source=/dev/null
  . "$LAYOUT"
  _pane(){ local p="$1" tab="$2" cmd="${3:-}"; mkdir -p "$S/panes/$p"; printf '%s' "$tab" > "$S/panes/$p/tab"; [ -n "$cmd" ] && printf '%s' "$cmd" > "$S/panes/$p/cmd"; return 0; }

  # Coordinator tab tC: the three real control-room roles.
  _pane pA tC 'claude --model x /coordinator'          # agent
  _pane pL tC 'bash /x/backlog-view.sh'                # backlog viewer
  _pane pW tC 'bash /x/agent-watch.sh'                 # watch console
  # Builder tab tB: the task-spec viewer in the builder's root pane.
  _pane pV tB 'bash /x/task-spec-view.sh /trees/foo.task.md'

  # The viewer classifies as 'busy' — NOT backlog/watch/agent/bare — so reload never treats it as a
  # control-room role nor flags it as a duplicate backlog viewer to close.
  role="$(_reload_pane_role pV)"
  [ "$role" = "busy" ] || { echo "FAIL: (3) task-spec viewer classified as '$role', expected 'busy'" >&2; exit 1; }

  # The builder-tab viewer NEVER appears in the COORDINATOR tab's snapshot (reconcile scopes to one tab).
  snap="$(layout_snapshot w1 tC)"
  if printf '%s\n' "$snap" | awk -F'\t' '$2=="pV"{f=1} END{exit !f}'; then
    echo "FAIL: (3) builder-tab viewer pane leaked into the coordinator tab snapshot" >&2; exit 1
  fi

  # Reconcile of the coordinator tab resolves the real roles and flags NO duplicate backlog viewer.
  rec="$(layout_reconcile w1 tC '' '' '')"
  printf '%s\n' "$rec" | grep -qx 'backlog=pL'     || { echo "FAIL: (3) backlog role not the real viewer" >&2; exit 1; }
  printf '%s\n' "$rec" | grep -qx 'agent=pA'       || { echo "FAIL: (3) agent role not the real coordinator pane" >&2; exit 1; }
  printf '%s\n' "$rec" | grep -qx 'watch=pW'       || { echo "FAIL: (3) watch role not the real watcher" >&2; exit 1; }
  printf '%s\n' "$rec" | grep -qx 'dup_backlog='   || { echo "FAIL: (3) a duplicate backlog viewer was flagged (viewer misclassified)" >&2; exit 1; }
) || exit 1
pass; echo "PASS (3) builder-tab viewer is tab-isolated + classifies 'busy' — never a control-room role"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 4. list_to_md RESHAPE — code-chip id + bold title + blank-line division; title preserved
# ════════════════════════════════════════════════════════════════════════════════════════════════
# Extract the REAL list_to_md function body and eval it in isolation (backlog-view.sh has side effects
# on source), so we assert the shaping the live viewer actually emits — not a re-implementation.
FUNC="$(sed -n '/^list_to_md() {/,/^}/p' "$BACKLOG")"
[ -n "$FUNC" ] || fail "(4) could not extract list_to_md from backlog-view.sh"
(
  eval "$FUNC"   # define the REAL function in this subshell, then exercise it (output to files keeps blanks)
  list_to_md "#HERD-25 Add pluggable theming across surfaces" > "$T/l1.md"
  list_to_md "just a plain title"                             > "$T/l2.md"
)
# The whole item on one bullet: inline CODE chip id (themed tag) BEFORE a BOLD title (theme strong).
grep -q '^- `#HERD-25` \*\*Add pluggable theming across surfaces\*\*$' "$T/l1.md" \
  || fail "(4) item shape is not '- \`#id\` **title**'"$'\n'"$(cat "$T/l1.md")"
# A blank line divides entries visually (loose list) — the item line is followed by an empty line.
awk 'NR==1 && /#HERD-25/ {a=1} NR==2 && $0=="" {b=1} END{exit (a&&b)?0:1}' "$T/l1.md" \
  || fail "(4) no blank-line divider after the item"$'\n'"$(cat -A "$T/l1.md" 2>/dev/null || cat "$T/l1.md")"
# Title text is preserved verbatim (readability, not lossy shaping).
grep -q 'Add pluggable theming across surfaces' "$T/l1.md" || fail "(4) title text was lost in shaping"
pass; echo "PASS (4a) '#id title' → '- \`#id\` **title**' + blank-line division (chip id + bold title)"

# A bare title with no id → whole line bolded (still gets theme hierarchy, never a naked flat line).
grep -q '^- \*\*just a plain title\*\*$' "$T/l2.md" || fail "(4) id-less line not bolded"
pass; echo "PASS (4b) id-less line → bold bullet (theme hierarchy preserved)"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# 5. Config-key documentation — TASK_PANE_VIEW is a documented, read-from-config key (default on)
# ════════════════════════════════════════════════════════════════════════════════════════════════
grep -Eq ': "\$\{TASK_PANE_VIEW:="on"\}"' "$HCONFIG" || fail "(5) herd-config.sh does not default TASK_PANE_VIEW to on"
awk -F'\t' '$1=="TASK_PANE_VIEW" && $2=="config"{f=1} END{exit f?0:1}' "$CAPS" \
  || fail "(5) TASK_PANE_VIEW missing a 'config' row in capabilities.tsv"
awk -F'\t' '$1=="scripts/herd/task-spec-view.sh" && $2=="reference"{f=1} END{exit f?0:1}' "$CAPS" \
  || fail "(5) task-spec-view.sh missing a 'reference' row in capabilities.tsv"
grep -q "TASK_PANE_VIEW" "$CFG_EXAMPLE"           || fail "(5) TASK_PANE_VIEW not documented in config.example"
pass; echo "PASS (5) TASK_PANE_VIEW documented in herd-config.sh (default on), capabilities.tsv, config.example"

echo
echo "ALL PASS ($PASS checks) — builder-tab task-spec viewer + backend list readability reshape."
