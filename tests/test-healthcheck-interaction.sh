#!/usr/bin/env bash
# test-healthcheck-interaction.sh — hermetic tests for the framework-generic interaction gate in
# scripts/herd/healthcheck.sh (issue #15). A render smoke ("does the app render?") is blind to
# broken interactivity — a widget whose value no longer moves the output still renders clean. Two
# OPTIONAL .herd/config keys close that gap without the engine hardcoding any UI framework:
#   APP_SURFACE_GLOB     — egrep of diff paths that are the app surface (empty → gate OFF).
#   INTERACTION_TEST_CMD — project command that drives a widget and asserts the dependent output
#                          changed (e.g. an `st.testing.v1.AppTest` harness); exit 0 clean, 1 code
#                          error, 2 data/env (tolerated) — mirrors HEALTHCHECK_CMD.
#
# Covers, driving the REAL healthcheck.sh against a temp git repo with a stubbed app-surface diff:
#   (1) DISABLED   — empty APP_SURFACE_GLOB → gate never runs, no warning, cmd not invoked (proves
#                    the feature is a true no-op for every existing project)
#   (2) GATE PASS  — glob matches + cmd exits 0 → clean, "INTERACTION TESTS CLEAN", cmd ran
#   (3) GATE FAIL  — glob matches + cmd exits 1 → rc 1 (blocks the merge), reason carried; --oneline
#                    is exactly one line prefixed "❌ interaction —"
#   (4) DATA/ENV   — glob matches + cmd exits 2 → tolerated (rc 0), surfaced as data/env ⚠️
#   (5) WARN       — glob matches + cmd EMPTY → loud one-line warning, NOT red (rc 0); --oneline is
#                    one ⚠️ line
#   (6) NO MATCH   — glob set but the diff misses the app surface → no warning, cmd not invoked
#
# Network-free: a temp git repo, stub INTERACTION_TEST_CMD / HEALTHCHECK_CMD scripts, temp config
# via HERD_CONFIG_FILE. Run:  bash tests/test-healthcheck-interaction.sh
# No `set -e`: several checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HC="$HERE/../scripts/herd/healthcheck.sh"
[ -f "$HC" ] || { echo "healthcheck.sh not found at $HC" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git required to run this test" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }
nlines() { printf '%s\n' "$1" | grep -c .; }   # count non-empty lines in a captured string

# ── A worktree that looks like a real repo (committed seed on 'main') ─────────
WT="$T/wt"; mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" checkout -q -b main 2>/dev/null || git -C "$WT" checkout -q main
git -C "$WT" config user.email t@t.test
git -C "$WT" config user.name  herd-test
echo seed > "$WT/seed.txt"; git -C "$WT" add seed.txt; git -C "$WT" commit -qm seed

# ── Stub interaction commands: log each invocation, emit a line, exit deterministically ───────
IT_LOG="$T/it-invocations.log"
mk_stub() {  # <path> <exit-code> <oneline reason>
  cat > "$1" <<STUB
#!/usr/bin/env bash
printf 'ran\n' >> "$IT_LOG"
printf '%s\n' "$3"
exit $2
STUB
  chmod +x "$1"
}
mk_stub "$T/it-pass.sh" 0 "drove the slider → dependent output changed"
mk_stub "$T/it-fail.sh" 1 "slider no longer affects output"
mk_stub "$T/it-env.sh"  2 "connection refused while booting the harness"

# ── Stub HEALTHCHECK_CMD so the MAIN profile is deterministically clean (heavy runs) ──────────
HC_STUB="$T/hc-main.sh"
cat > "$HC_STUB" <<'STUB'
#!/usr/bin/env bash
if [ "${2:-}" = "--oneline" ]; then echo "clean — render smoke ok"; else echo "CLEAN"; echo "render smoke ok"; fi
exit 0
STUB
chmod +x "$HC_STUB"

CFG="$T/config"
export HERD_CONFIG_FILE="$CFG"
write_cfg() {  # <APP_SURFACE_GLOB> <INTERACTION_TEST_CMD>
  cat > "$CFG" <<CFGEOF
PROJECT_ROOT="$WT"
WORKTREES_DIR="$T/trees"
DEFAULT_BRANCH="main"
WORKSPACE_NAME="itest"
HEALTHCHECK_CMD="$HC_STUB"
HEALTHCHECK_HEAVY_GLOB=""
APP_SURFACE_GLOB="$1"
INTERACTION_TEST_CMD="$2"
CFGEOF
}

# The "diff" is represented by untracked files (a new app file wouldn't show in `git diff` yet —
# exactly what _changed_files unions in). ^app/ matches the app surface; docs/ does not.
set_app_diff()    { mkdir -p "$WT/app";  echo "value = st.slider('v')" > "$WT/app/panel.py"; }
set_nonapp_diff() { mkdir -p "$WT/docs"; echo "notes" > "$WT/docs/readme.md"; }
clear_diff()      { rm -rf "$WT/app" "$WT/docs" 2>/dev/null || true; }

run_hc() { bash "$HC" "$WT" "$@"; }

# ── (1) DISABLED — empty APP_SURFACE_GLOB is a true no-op even with a cmd + app diff ──────────
write_cfg "" "$T/it-pass.sh"
clear_diff; set_app_diff; : > "$IT_LOG"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "disabled: expected rc 0 (got $rc)"
printf '%s' "$out" | grep -qi 'interaction' && fail "disabled: output must not mention the interaction gate"
[ -s "$IT_LOG" ] && fail "disabled: interaction cmd must NOT run when APP_SURFACE_GLOB is empty"
printf '%s' "$out" | grep -q 'render smoke ok' || fail "disabled: main profile output should still pass through"
ok

# ── (2) GATE PASS — glob matches + cmd exits 0 ───────────────────────────────
write_cfg "^app/" "$T/it-pass.sh"
clear_diff; set_app_diff; : > "$IT_LOG"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "pass: expected rc 0 (got $rc)"
printf '%s' "$out" | grep -q 'INTERACTION TESTS CLEAN' || fail "pass: full output should show INTERACTION TESTS CLEAN"
[ -s "$IT_LOG" ] || fail "pass: interaction cmd should have been invoked"
ok

# ── (3) GATE FAIL — glob matches + cmd exits 1 → blocks the merge ────────────
write_cfg "^app/" "$T/it-fail.sh"
clear_diff; set_app_diff
out="$(run_hc)"; rc=$?
[ "$rc" -eq 1 ] || fail "fail: a code-error interaction test must gate (rc 1, got $rc)"
printf '%s' "$out" | grep -q 'INTERACTION TESTS FAILED' || fail "fail: should show INTERACTION TESTS FAILED"
printf '%s' "$out" | grep -q 'slider no longer affects output' || fail "fail: should carry the cmd's reason"
ok
oneout="$(run_hc --oneline)"; orc=$?
[ "$orc" -eq 1 ] || fail "fail --oneline: expected rc 1 (got $orc)"
[ "$(nlines "$oneout")" -eq 1 ] || fail "fail --oneline: watcher needs exactly one line (got: $oneout)"
printf '%s' "$oneout" | grep -q '❌ interaction —' || fail "fail --oneline: expected '❌ interaction —' prefix (got: $oneout)"
ok

# ── (4) DATA/ENV — glob matches + cmd exits 2 → tolerated, not red ───────────
write_cfg "^app/" "$T/it-env.sh"
clear_diff; set_app_diff
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "dataenv: exit-2 must be tolerated (rc 0, got $rc)"
printf '%s' "$out" | grep -qi 'data/env' || fail "dataenv: should surface a data/env note"
printf '%s' "$out" | grep -q 'INTERACTION TESTS FAILED' && fail "dataenv: must not be reported as a failure"
ok

# ── (5) WARN — glob matches + cmd EMPTY → loud absence warning, never red ────
write_cfg "^app/" ""
clear_diff; set_app_diff
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "warn: a missing declaration must NOT fail the gate (rc 0, got $rc)"
printf '%s' "$out" | grep -q 'no interaction tests declared' || fail "warn: missing the absence warning"
printf '%s' "$out" | grep -q 'render smoke cannot see widget→output causality' || fail "warn: missing the causality phrase"
printf '%s' "$out" | grep -q 'INTERACTION TESTS FAILED' && fail "warn: absence is a warning, not a failure"
ok
oneout="$(run_hc --oneline)"; orc=$?
[ "$orc" -eq 0 ] || fail "warn --oneline: expected rc 0 (got $orc)"
[ "$(nlines "$oneout")" -eq 1 ] || fail "warn --oneline: must be exactly one line (got: $oneout)"
printf '%s' "$oneout" | grep -q '⚠️' || fail "warn --oneline: expected a ⚠️ prefix (got: $oneout)"
printf '%s' "$oneout" | grep -q 'no interaction tests declared' || fail "warn --oneline: expected the warning text (got: $oneout)"
ok

# ── (6) NO MATCH — glob set but the diff misses the app surface → nothing fires ──────────────
write_cfg "^app/" ""            # empty cmd: a bare 'diff missed' must not even warn
clear_diff; set_nonapp_diff
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "nomatch: expected rc 0 (got $rc)"
printf '%s' "$out" | grep -q 'no interaction tests declared' && fail "nomatch: must NOT warn when the diff misses the app surface"
ok
write_cfg "^app/" "$T/it-pass.sh"   # cmd set: a diff that misses the app surface must not run it
clear_diff; set_nonapp_diff; : > "$IT_LOG"
out="$(run_hc)"; rc=$?
[ "$rc" -eq 0 ] || fail "nomatch: expected rc 0 with cmd set (got $rc)"
[ -s "$IT_LOG" ] && fail "nomatch: interaction cmd must NOT run when the diff misses the app surface"
ok

echo "ALL PASS ($pass checks)"
