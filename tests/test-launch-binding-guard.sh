#!/usr/bin/env bash
# test-launch-binding-guard.sh — hermetic tests for the issue #60 LAUNCH-BINDING GUARD.
#
# The 2026-07-02 incident: a console launched from a non-project dir (e.g. $HOME) silently bound to
# the ENGINE's own dogfood .herd/config via herd-config.sh's rule-3 fallback, then impersonated
# another repo's watcher on the same lockfile. This suite proves the three additive defenses:
#   A. herd-config.sh console-strict config binding — HERD_REQUIRE_PROJECT_CONFIG=1 refuses a
#      config that resolved ONLY via the rule-3 engine-dogfood fallback, while normal `herd` CLI
#      usage (no flag) still falls back as before.
#   B. herd_console_guard — the startup banner (resolved WORKSPACE_NAME + PROJECT_ROOT) and the
#      foreign-cwd refusal (names WORKSPACE_NAME/PROJECT_ROOT/PWD), bypassable by HERD_ALLOW_FOREIGN_CWD=1.
#   C. End-to-end wiring — coordinator.sh and agent-watch.sh refuse a foreign cwd, and the standard
#      --cwd PROJECT_ROOT launch path still starts cleanly.
#
# Fully stubbed: no network, no real tabs/panes; never touches the live watcher/panes/processes.
# Run:  bash tests/test-launch-binding-guard.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOADER="$HERE/../scripts/herd/herd-config.sh"
COORD="$HERE/../scripts/herd/coordinator.sh"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

# Physical tmpdir so the guard's `pwd -P` containment test compares like-for-like.
T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"
for f in "$LOADER" "$COORD" "$WATCH"; do [ -f "$f" ] || fail "missing script: $f"; done

# A "foreign" cwd with no .herd/config anywhere above it, and a real project + its config.
FOREIGN="$T/foreign"; mkdir -p "$FOREIGN"
PROJ="$T/proj"; mkdir -p "$PROJ/.herd" "$T/trees"
cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$T/trees"
WORKSPACE_NAME="proj-under-test"
EOF

# ── A. herd-config.sh console-strict config binding ──────────────────────────

# A1. flag set + rule-3 fallback (no HERD_CONFIG_FILE, no walk-up match) → REFUSE (non-zero).
outA1="$(cd "$FOREIGN" && HERD_REQUIRE_PROJECT_CONFIG=1 bash -c ". '$LOADER'" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "A1: console-strict did not refuse the rule-3 dogfood fallback (rc=$rc): $outA1"
printf '%s' "$outA1" | grep -q "REFUSING" || fail "A1: no REFUSING message ($outA1)"
printf '%s' "$outA1" | grep -Fq "$FOREIGN" || fail "A1: refusal did not name the offending \$PWD ($outA1)"
ok

# A2. NO flag, same setup → normal CLI fallback preserved (exit 0, no refusal); it silently binds
# to the ENGINE's own dogfood config (PROJECT_ROOT is set and is NOT the test project) — exactly the
# behavior the flag guards against for consoles, and exactly what `herd <cmd>` still relies on.
outA2="$(cd "$FOREIGN" && bash -c ". '$LOADER'; printf 'ROOT=%s\n' \"\$PROJECT_ROOT\"" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "A2: normal CLI resolution was refused (rc=$rc): $outA2"
printf '%s' "$outA2" | grep -q "REFUSING" && fail "A2: normal CLI resolution wrongly refused ($outA2)" || true
root_a2="$(printf '%s' "$outA2" | sed -n 's/^ROOT=//p')"
[ -n "$root_a2" ] || fail "A2: fallback did not set PROJECT_ROOT ($outA2)"
[ "$root_a2" != "$PROJ" ] || fail "A2: fallback unexpectedly bound to the test project ($outA2)"
ok

# A3. flag set + HERD_ALLOW_FOREIGN_CWD=1 → escape hatch, exit 0.
outA3="$(cd "$FOREIGN" && HERD_REQUIRE_PROJECT_CONFIG=1 HERD_ALLOW_FOREIGN_CWD=1 bash -c ". '$LOADER'" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "A3: escape hatch did not permit the fallback (rc=$rc): $outA3"
ok

# A4. flag set but an explicit HERD_CONFIG_FILE (env source, NOT fallback) → exit 0, config loaded.
outA4="$(cd "$FOREIGN" && HERD_REQUIRE_PROJECT_CONFIG=1 HERD_CONFIG_FILE="$PROJ/.herd/config" \
  bash -c ". '$LOADER'; printf 'WS=%s\n' \"\$WORKSPACE_NAME\"" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "A4: explicit HERD_CONFIG_FILE was wrongly refused (rc=$rc): $outA4"
printf '%s' "$outA4" | grep -qx "WS=proj-under-test" || fail "A4: config not loaded ($outA4)"
ok

# ── B. herd_console_guard: banner + foreign-cwd refusal ──────────────────────
# Source the loader with the project config (env source → no config-strict), then call the guard.
guard_run() {  # <cwd> [extra-env=val ...]
  local cwd="$1"; shift
  ( cd "$cwd" && env "$@" HERD_CONFIG_FILE="$PROJ/.herd/config" \
      bash -c ". '$LOADER'; herd_console_guard 'test-console'" 2>&1 )
}

# B1. PWD inside PROJECT_ROOT → PASS (exit 0) + banner names workspace + project.
outB1="$(guard_run "$PROJ")"; rc=$?
[ "$rc" -eq 0 ] || fail "B1: guard refused the standard in-project cwd (rc=$rc): $outB1"
printf '%s' "$outB1" | grep -q "workspace=proj-under-test" || fail "B1: banner missing WORKSPACE_NAME ($outB1)"
printf '%s' "$outB1" | grep -Fq "project=$PROJ"            || fail "B1: banner missing PROJECT_ROOT ($outB1)"
ok

# B2. PWD outside PROJECT_ROOT → REFUSE (non-zero) naming workspace / project / pwd.
outB2="$(guard_run "$FOREIGN")"; rc=$?
[ "$rc" -ne 0 ] || fail "B2: guard did not refuse a foreign cwd (rc=$rc): $outB2"
printf '%s' "$outB2" | grep -q "REFUSING to start test-console" || fail "B2: no refusal message ($outB2)"
printf '%s' "$outB2" | grep -q "proj-under-test" || fail "B2: refusal missing WORKSPACE_NAME ($outB2)"
printf '%s' "$outB2" | grep -Fq "$PROJ"          || fail "B2: refusal missing PROJECT_ROOT ($outB2)"
printf '%s' "$outB2" | grep -Fq "$FOREIGN"       || fail "B2: refusal missing offending \$PWD ($outB2)"
ok

# B3. Foreign cwd + HERD_ALLOW_FOREIGN_CWD=1 → PASS.
outB3="$(guard_run "$FOREIGN" HERD_ALLOW_FOREIGN_CWD=1)"; rc=$?
[ "$rc" -eq 0 ] || fail "B3: escape hatch did not permit a foreign cwd (rc=$rc): $outB3"
ok

# ── C. End-to-end console wiring ─────────────────────────────────────────────

# C1. coordinator.sh from a foreign cwd REFUSES (non-zero) before any herdr call.
outC1="$(cd "$FOREIGN" && HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$COORD" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "C1: coordinator.sh did not refuse a foreign cwd (rc=$rc): $outC1"
printf '%s' "$outC1" | grep -q "REFUSING to start coordinator" || fail "C1: coordinator refusal missing ($outC1)"
ok

# C2. coordinator.sh from the STANDARD in-project cwd starts cleanly (exit 0) + prints the banner.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "workspace list")   printf '{"result":{"workspaces":[]}}\n' ;;
  "workspace create") printf '{"result":{"workspace":{"workspace_id":"wTest"},"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "workspace focus")  : ;;
  "tab list")   printf '{"result":{"tabs":[]}}\n' ;;
  "tab create") printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "tab rename") : ;;
  "agent start") printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  "pane run")   : ;;
  "pane split") printf '{"result":{"pane":{"pane_id":"pTest"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"

outC2="$(cd "$PROJ" && PATH="$BIN:$PATH" HERD_NO_WATCH=1 HERD_SKIP_PREFLIGHT=1 \
  HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$COORD" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "C2: coordinator.sh did not start cleanly on the standard in-project path (rc=$rc): $outC2"
printf '%s' "$outC2" | grep -q "workspace=proj-under-test" || fail "C2: standard launch missing banner ($outC2)"
printf '%s' "$outC2" | grep -q "REFUSING" && fail "C2: standard launch was wrongly refused ($outC2)" || true
ok

# C3. agent-watch.sh (the watcher console) from a foreign cwd REFUSES end-to-end (before the loop).
outC3="$(cd "$FOREIGN" && HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$WATCH" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "C3: agent-watch.sh did not refuse a foreign cwd (rc=$rc): $outC3"
printf '%s' "$outC3" | grep -q "REFUSING to start herd watch" || fail "C3: agent-watch refusal missing ($outC3)"
ok

echo "ALL PASS ($pass checks)"
