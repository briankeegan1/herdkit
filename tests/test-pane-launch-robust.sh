#!/usr/bin/env bash
# test-pane-launch-robust.sh — structural unit test for HERD-322 (pane-launch robustness).
#
# Verifies:
#   1. herd_pane_launch exists in driver.sh and prepends a leading space (first-char-drop guard)
#   2. coordinator.sh uses herd_pane_launch (not bare herdr pane run) for backlog-view + herd-watch
#   3. _reload_pane_run_verified in bin/herd sends an explicit Enter after pane run
#   4. cmd_pane_watch in bin/herd has a non-zero exit path when the watcher fails to start
#   5. herd_pane_launch with HERD_DRIVER=headless is a no-op (headless guard present)
#
# Fully hermetic: no herdr, no claude, no network. Run: bash tests/test-pane-launch-robust.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS+1)); }

DRIVER="$REPO/scripts/herd/driver.sh"
COORD="$REPO/scripts/herd/coordinator.sh"
HERD="$REPO/bin/herd"

# ── 1. herd_pane_launch exists and adds a leading space ──────────────────────────────────────────
grep -qE '^herd_pane_launch\(\)' "$DRIVER" \
  || fail "herd_pane_launch function must be defined in driver.sh"
ok; echo "PASS (1a) herd_pane_launch defined in driver.sh"

# The leading-space guard: the pane run line inside herd_pane_launch must prepend ' $cmd', not '$cmd'.
# Grep for the herdr pane run call inside the function — it must pass " \$cmd" (space before $cmd).
awk '/^herd_pane_launch\(\)/,/^}/' "$DRIVER" \
  | grep -qE 'herdr pane run.*" \$cmd"' \
  || fail "herd_pane_launch must pass \" \$cmd\" (leading space) to herdr pane run — the first-char-drop guard"
ok; echo "PASS (1b) herd_pane_launch passes a leading-space-prefixed command to herdr pane run"

# The explicit Enter: the function must also send-keys Enter to submit the command.
awk '/^herd_pane_launch\(\)/,/^}/' "$DRIVER" \
  | grep -qE 'herdr pane send-keys.*Enter' \
  || fail "herd_pane_launch must send-keys Enter after pane run to ensure the shell executes the command"
ok; echo "PASS (1c) herd_pane_launch sends an explicit Enter after pane run"

# The headless guard: must be a no-op when headless (HERD-322 requirement, avoids orphan fallbacks).
awk '/^herd_pane_launch\(\)/,/^}/' "$DRIVER" \
  | grep -qE '_herd_driver_is_headless' \
  || fail "herd_pane_launch must check _herd_driver_is_headless and return early"
ok; echo "PASS (1d) herd_pane_launch has a headless guard (no-op on HERD_DRIVER=headless)"

# ── 2. coordinator.sh uses herd_pane_launch for both pane launches ───────────────────────────────
# backlog-view pane
grep -qE 'herd_pane_launch.*backlog-view\.sh' "$COORD" \
  || fail "coordinator.sh must use herd_pane_launch for backlog-view.sh (not bare herdr pane run)"
ok; echo "PASS (2a) coordinator.sh uses herd_pane_launch for the backlog-view pane launch"

# herd-watch pane
grep -qE 'herd_pane_launch.*herd-watch\.sh' "$COORD" \
  || fail "coordinator.sh must use herd_pane_launch for herd-watch.sh (not bare herdr pane run)"
ok; echo "PASS (2b) coordinator.sh uses herd_pane_launch for the herd-watch pane launch"

# No bare herdr pane run for shell commands inside coordinator.sh (only herd_pane_launch or splits).
# Bare `herdr pane run` for shell commands (backlog-view/herd-watch) must be gone.
if grep -qE 'herdr pane run.*backlog-view\.sh|herdr pane run.*herd-watch\.sh' "$COORD"; then
  fail "coordinator.sh still has bare herdr pane run for backlog-view or herd-watch — route through herd_pane_launch"
fi
ok; echo "PASS (2c) coordinator.sh has no bare herdr pane run for backlog-view or herd-watch"

# ── 3. _reload_pane_run_verified in bin/herd sends an explicit Enter ─────────────────────────────
# Find the function and verify both the leading space and the send-keys Enter are present.
awk '/^_reload_pane_run_verified\(\)/,/^}/' "$HERD" \
  | grep -qE 'herdr pane run.*" \$cmd"' \
  || fail "_reload_pane_run_verified must pass \" \$cmd\" (leading space) to herdr pane run"
ok; echo "PASS (3a) _reload_pane_run_verified passes a leading-space-prefixed command to herdr pane run"

awk '/^_reload_pane_run_verified\(\)/,/^}/' "$HERD" \
  | grep -qE 'herdr pane send-keys.*Enter' \
  || fail "_reload_pane_run_verified must send-keys Enter after pane run"
ok; echo "PASS (3b) _reload_pane_run_verified sends an explicit Enter after pane run"

# ── 4. cmd_pane_watch has a non-zero exit path for watcher-start failure ─────────────────────────
# The `return 1` (or equivalent) must appear somewhere inside cmd_pane_watch.
awk '/^cmd_pane_watch\(\)/,/^}/' "$HERD" \
  | grep -qE 'return 1' \
  || fail "cmd_pane_watch must have a return 1 path for when the watcher fails to start (HERD-322)"
ok; echo "PASS (4a) cmd_pane_watch has a return 1 path"

# The headless fallback must exist: cmd_pane_watch's nohup calls use ${HERD_CONFIG_FILE:-…}
# (parameter-expansion form), whereas cmd_reload uses the simpler $cfg form — this grep is unique.
grep -qE 'HERD_CONFIG_FILE:-.*nohup bash' "$HERD" \
  || fail "cmd_pane_watch must have a headless fallback (nohup background spawn) matching cmd_reload's pattern"
ok; echo "PASS (4b) cmd_pane_watch has a headless nohup fallback when pane launch fails"

# ── 5. Hermetic smoke-test: source driver.sh with HERD_DRIVER=headless; herd_pane_launch is no-op ─
(
  set -euo pipefail
  HERD_DRIVER=headless
  # driver.sh sources herd-config.sh; we only need the functions — stub its deps.
  _herd_driver_is_headless() { [ "${HERD_DRIVER:-}" = "headless" ]; }
  # Source just the herd_pane_launch function block from driver.sh without running the whole file.
  eval "$(awk '/^herd_pane_launch\(\)/,/^}/' "$DRIVER")"
  # With HERD_DRIVER=headless the function must return 0 without calling herdr (which isn't on PATH here).
  HERD_DRIVER=headless herd_pane_launch "w1:p1" "bash /some/script.sh"
) || fail "herd_pane_launch with HERD_DRIVER=headless must not fail or call herdr"
ok; echo "PASS (5) herd_pane_launch is a safe no-op under HERD_DRIVER=headless"

echo ""
echo "ALL PASS ($PASS checks) — test-pane-launch-robust.sh"
