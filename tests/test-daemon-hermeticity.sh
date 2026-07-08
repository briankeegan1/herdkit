#!/usr/bin/env bash
# test-daemon-hermeticity.sh — hermetic proof of the HERD-189 DAEMON-HERMETICITY GUARD: the assertion
# that catches a test which would launch a REAL watcher/daemon/agent against the live control room.
#
# GROUNDED: tonight the suite risked touching real state — `herd config set` on a watcher-affecting
# key, `herd backend switch`, and a few probes reached the LIVE herdr/claude, and cmd_reload can spawn
# a real `nohup bash agent-watch.sh` watcher against a test's temp repo. The convention "each test
# stubs its own herdr" was unenforced: a test that forgot silently hit the real workspace.
#
# The guard has two halves, exercised here and kept IN LOCKSTEP with the sandbox the dogfood
# healthcheck (.herd/healthcheck.project.sh) wraps its test run in:
#   (A) an ENGINE choke point — agent-watch.sh, when HERD_HERMETIC_GUARD names a log file, records the
#       leak and EXITS before the argv0 re-exec / watch loop. Every watcher launch path (cmd_reload's
#       pane-run + background fallback, `herd pane watch`, herd-watch.sh, coordinator.sh, direct exec)
#       funnels through it, so a spawned watcher is caught and NEVER runs. INERT in production.
#   (B) a PATH SANDBOX — benign tripwire stubs for herdr/claude/codex that RECORD (never break) any
#       reach to the live agent-spawn surface into the same log. A properly-stubbed test shadows them
#       with its own bin dir and never trips; an unstubbed reach is logged.
# A non-empty log after a run ⇒ a test touched the live control room or spawned a real daemon.
#
# Fully hermetic: temp dirs only, NO network, never touches the real workspace. Run:
#     bash tests/test-daemon-hermeticity.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"

# hermetic_sandbox <dir> <logfile> — build the benign tripwire bin dir + empty log. Mirrors the
# _hk_hermetic_* sandbox in .herd/healthcheck.project.sh; keep the two in lockstep. Each stub records
# one TAB-separated '<test>\t<cmd>\t<args>' line and returns a harmless value so control flow is never
# distorted (the guard is a DETECTOR, not a breaker — it must not change a hermetic test's outcome).
hermetic_sandbox() {
  local dir="$1" log="$2" c
  mkdir -p "$dir/bin"; : > "$log"
  for c in herdr claude codex; do
    { printf '#!/usr/bin/env bash\n'
      printf 'printf '\''%%s\\t%%s\\t%%s\\n'\'' "${HERMETIC_TEST:-suite}" "%s" "$*" >> "%s"\n' "$c" "$log"
      case "$c" in herdr) printf 'echo '\''{}'\''\n' ;; claude) printf 'echo '\''claude 0.0.0'\''\n' ;; esac
      printf 'exit 0\n'; } > "$dir/bin/$c"
    chmod +x "$dir/bin/$c"
  done
}

# A valid project config so a launched agent-watch.sh clears the console-strict binding and REACHES
# the guard (a foreign cwd would be refused earlier — also hermetic, but not what we are asserting).
PROJ="$T/proj"; mkdir -p "$PROJ/.herd" "$T/trees"
cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$T/trees"
WORKSPACE_NAME="hermetic-guard-ws"
EOF

SB="$T/sandbox"; LOG="$T/leaks.log"
hermetic_sandbox "$SB" "$LOG"

# ── (A) ENGINE CHOKE POINT: a spawned watcher records + exits, never runs the loop ───────────────
: > "$LOG"
( cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" HERD_HERMETIC_GUARD="$LOG" \
    timeout 15 bash "$WATCH" ) ; rc=$?
[ "$rc" -eq 0 ] || fail "(A) guarded agent-watch.sh should exit 0 fast, got rc=$rc (did it enter the loop?)"
grep -q $'^agent-watch.sh\t' "$LOG" || fail "(A) guard did not record the watcher launch ($(cat "$LOG"))"
# No real watcher may survive the run (the guard exits BEFORE grabbing the singleton lock).
[ -f "$T/trees/.watcher-hermetic-guard-ws.pid" ] && fail "(A) guarded watcher grabbed the singleton lock — it entered the loop"
ok; echo "PASS (A) HERD_HERMETIC_GUARD makes a launched agent-watch.sh record + exit before the loop"

# (A2) Byte-inert without the var: agent-watch.sh sourced in LIB mode still just defines functions
# (the guard is downstream of the AGENT_WATCH_LIB early-return, so already-hermetic sourcing is
# unchanged). Sourcing must define the pure predicate and NOT write the guard log.
: > "$LOG"
( AGENT_WATCH_LIB=1 HERD_HERMETIC_GUARD="$LOG"; export AGENT_WATCH_LIB HERD_HERMETIC_GUARD
  # shellcheck source=/dev/null
  . "$WATCH" && type _should_automerge >/dev/null 2>&1 ) || fail "(A2) LIB-mode source broke"
[ -s "$LOG" ] && fail "(A2) LIB-mode source tripped the guard (should return before it): $(cat "$LOG")"
ok; echo "PASS (A2) LIB-mode sourcing returns before the guard — already-hermetic tests are unchanged"

# ── (B) PATH SANDBOX + guard CATCH a leaking fake test ───────────────────────────────────────────
# Fake test #1: reaches the live agent-spawn surface directly (forgot to stub herdr).
cat > "$T/bad-reach.sh" <<'BAD'
#!/usr/bin/env bash
herdr agent start scribe-x -- claude   # would spawn a real agent in the live workspace
claude --version                        # would launch the real agent runtime
echo done
BAD
chmod +x "$T/bad-reach.sh"

# Fake test #2: spawns the REAL watcher against a temp repo (the cmd_reload class of leak).
cat > "$T/bad-spawn.sh" <<BAD
#!/usr/bin/env bash
cd "$PROJ" || exit 1
HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$WATCH"
BAD
chmod +x "$T/bad-spawn.sh"

# Fake test #3: HERMETIC — installs its own herdr stub (shadowing the tripwire) and never spawns a
# watcher. Must leave the log clean.
cat > "$T/good.sh" <<GOOD
#!/usr/bin/env bash
b="$T/goodbin"; mkdir -p "\$b"
printf '#!/usr/bin/env bash\nexit 0\n' > "\$b/herdr"; chmod +x "\$b/herdr"
PATH="\$b:\$PATH" herdr agent list >/dev/null 2>&1
echo done
GOOD
chmod +x "$T/good.sh"

run_under_sandbox() { # <fake-test>
  HERMETIC_TEST="$(basename "$1")" PATH="$SB/bin:$PATH" HERD_HERMETIC_GUARD="$LOG" \
    timeout 20 bash "$1" >/dev/null 2>&1
}

: > "$LOG"; run_under_sandbox "$T/bad-reach.sh" || true
grep -q $'\therdr\t' "$LOG"  || fail "(B) sandbox missed the unstubbed 'herdr' reach ($(cat "$LOG"))"
grep -q $'\tclaude\t' "$LOG" || fail "(B) sandbox missed the unstubbed 'claude' reach ($(cat "$LOG"))"
ok; echo "PASS (B) a test that reaches the live herdr/claude surface is caught"

: > "$LOG"; run_under_sandbox "$T/bad-spawn.sh" || true
grep -q $'^agent-watch.sh\t' "$LOG" || fail "(B2) sandbox missed a real watcher spawn ($(cat "$LOG"))"
ok; echo "PASS (B2) a test that spawns a real watcher daemon is caught"

: > "$LOG"; run_under_sandbox "$T/good.sh" || fail "(B3) the hermetic fake test should exit 0"
[ -s "$LOG" ] && fail "(B3) a properly-stubbed hermetic test tripped the guard: $(cat "$LOG")"
ok; echo "PASS (B3) a properly-stubbed test shadows the tripwire and stays clean (no false positive)"

echo "ALL PASS ($pass checks)"
