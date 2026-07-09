#!/usr/bin/env bash
# test-stub-driver.sh — hermetic proof for the STUB PROOF DRIVER + runtime seam (HERD-177, driver
# portability P6): the portability seam works with a NON-CLAUDE runtime, and a driver missing an
# agent-exec binding degrades gracefully instead of crashing. This is the existence proof HERD-178
# (real codex/grok drivers) builds on.
#
# Covers:
#   (1) stub.driver PARSES, binds every mux DRIVER_* + agent-exec DRIVER_AGENT_* key, is ZERO-SECRET,
#       and its runtime is genuinely NON-CLAUDE (no `claude` token in any agent-exec binding).
#   (2) RENDER: `herd render` with HERD_DRIVER=stub succeeds, leaves no {{token}}, swaps every
#       tokenized mux incantation to the stub's (the herdr binding is gone) — a non-claude driver is a
#       DATA FILE, not a fork.
#   (3) RUNTIME SEAM: herd_driver_agent_runtime resolves `stub-agent` (not claude), and
#       herd_driver_oneshot_exec runs `stub-agent -p …` end-to-end — the seam is runtime-portable.
#   (4) BYTE-IDENTICAL DEFAULT: with HERD_DRIVER unset/herdr-claude the same seam runs `claude -p …`.
#   (5) ABSENT-BINDING DEGRADATION: a driver that omits DRIVER_AGENT_ONESHOT_EXEC → the seam degrades
#       to the default `claude` runtime and never crashes; herd_driver_agent_value on a missing key
#       or a missing driver file returns empty + rc 0 under `set -euo pipefail`.
#
# Fully hermetic: temp git repos + fake `stub-agent`/`claude` on PATH. NO real claude/herdr/gh/network.
# Run:  bash tests/test-stub-driver.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"
DRIVER_SH="$ROOT/scripts/herd/driver.sh"
STUB="$ROOT/templates/drivers/stub.driver"
GREP=/usr/bin/grep; command -v "$GREP" >/dev/null 2>&1 || GREP=grep

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

for f in "$HERD" "$DRIVER_SH" "$STUB"; do [ -f "$f" ] || fail "missing required file: $f"; done

MUX_KEYS="DRIVER_LIST_AGENTS DRIVER_FOCUS_AGENT DRIVER_SEND_TEXT DRIVER_SWITCH_MODEL \
DRIVER_START_AGENT DRIVER_CREATE_TAB DRIVER_READ_PANE DRIVER_SEND_KEYS"
AGENT_KEYS="DRIVER_AGENT_INTERACTIVE_SPAWN DRIVER_AGENT_ONESHOT_EXEC DRIVER_AGENT_RESUME \
DRIVER_AGENT_MODEL_SWITCH DRIVER_AGENT_PERMISSION_FLAG DRIVER_AGENT_LIMIT_PATTERN \
DRIVER_AGENT_SESSION_ID DRIVER_AGENT_COST_USAGE_KEYS"

# ── 1. stub.driver parses, binds every capability, zero-secret, and is NON-CLAUDE. ────────────────
( set -euo pipefail; . "$STUB"
  for k in $MUX_KEYS $AGENT_KEYS; do
    [ -n "${!k+set}" ] || { echo "  stub: $k not defined" >&2; exit 1; }
    [ -n "${!k}" ]     || { echo "  stub: $k is empty"    >&2; exit 1; }
  done
) || fail "(1) stub.driver does not parse / bind every capability"
if "$GREP" -E '^DRIVER_(AGENT_)?[A-Z_]+=' "$STUB" | "$GREP" -qiE '/users/|/home/|secret|password|apikey'; then
  fail "(1) stub.driver leaks a secret or absolute path"
fi
# The RUNTIME is non-claude: no agent-exec binding may name `claude` (that is the whole point).
if "$GREP" -E '^DRIVER_AGENT_[A-Z_]+=' "$STUB" | "$GREP" -qw 'claude'; then
  fail "(1) stub.driver's agent-exec bindings still name claude — not a non-claude runtime"
fi
runtime="$( . "$STUB"; printf '%s' "${DRIVER_AGENT_ONESHOT_EXEC%%[[:space:]]*}" )"
[ "$runtime" = "stub-agent" ] || fail "(1) stub runtime is '$runtime', expected stub-agent"
pass; echo "PASS (1) stub.driver parses, binds all keys, zero-secret, NON-claude runtime (stub-agent)"

# ── seed a minimal herd project `herd render` accepts (mirrors the driver tests). ─────────────────
seed_repo() {
  local d="$1" extra="${2:-}"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  ( cd "$d" && git commit -q --allow-empty -m init )
  mkdir -p "$d/.herd"
  cat > "$d/.herd/config" <<EOF
HERD_VERSION=1
WORKSPACE_NAME="herdkit"
PROJECT_ROOT="$d"
DEFAULT_BRANCH="origin/main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
HERD_REPO="briankeegan1/herdkit"
COORDINATOR_CMD="/coordinator"
$extra
EOF
}
render(){ local d="$1"; shift; ( cd "$d" && env "$@" bash "$HERD" render ); }

# ── 2. RENDER with HERD_DRIVER=stub succeeds, no leftover tokens, mux incantations swapped. ────────
P="$T/stubrepo"; mkdir -p "$P"; seed_repo "$P" 'HERD_DRIVER="stub"'
render "$P" >/dev/null 2>&1 || fail "(2) render with HERD_DRIVER=stub failed"
SK="$P/.claude/commands/coordinator.md"
"$GREP" -qE '\{\{' "$SK" && fail "(2) stub render left an unsubstituted {{token}}" || true
"$GREP" -qF 'stubmux agents' "$SK"  || fail "(2) stub list-agents incantation not rendered"
"$GREP" -qF 'stubmux send <slug> "<text>"' "$SK" || fail "(2) stub send-text incantation not rendered"
# The default herdr send-text binding is genuinely GONE from the tokenized site (data-driven swap).
"$GREP" -qF 'herdr pane run <agent-pane> "<text>"' "$SK" && fail "(2) herdr send-text binding survived the stub swap" || true
pass; echo "PASS (2) HERD_DRIVER=stub renders cleanly and swaps every tokenized mux incantation"

# ── fakes so the runtime seam runs without a real runtime ─────────────────────────────────────────
FB="$T/bin"; mkdir -p "$FB"
cat > "$FB/stub-agent" <<'EOF'
#!/usr/bin/env bash
{ printf 'RUNTIME:stub-agent\n'; for a in "$@"; do printf 'ARG:%s\n' "$a"; done; }
EOF
cat > "$FB/claude" <<'EOF'
#!/usr/bin/env bash
{ printf 'RUNTIME:claude\n'; for a in "$@"; do printf 'ARG:%s\n' "$a"; done; }
EOF
chmod +x "$FB/stub-agent" "$FB/claude"

# ── 3. RUNTIME SEAM: agent-runtime resolves stub-agent; oneshot runs it end-to-end. ───────────────
rt="$(HERD_DRIVER=stub HERD_DRIVERS_DIR="$ROOT/templates/drivers" \
      bash -c '. "'"$DRIVER_SH"'"; herd_driver_agent_runtime')"
[ "$rt" = "stub-agent" ] || fail "(3) herd_driver_agent_runtime under stub resolved '$rt', expected stub-agent"
out="$(HERD_DRIVER=stub HERD_DRIVERS_DIR="$ROOT/templates/drivers" PATH="$FB:$PATH" \
      bash -c '. "'"$DRIVER_SH"'"; herd_driver_oneshot_exec "hi there" "m1" --auto-approve')" \
  || fail "(3) herd_driver_oneshot_exec under stub exited non-zero"
echo "$out" | "$GREP" -q '^RUNTIME:stub-agent$' || fail "(3) one-shot seam did NOT run the stub runtime: $out"
echo "$out" | "$GREP" -q '^RUNTIME:claude$'     && fail "(3) one-shot seam fell back to claude under HERD_DRIVER=stub: $out" || true
# The prompt stayed one arg and --model carried the model — the arg composition is runtime-agnostic.
[ "$(echo "$out" | "$GREP" -c '^ARG:hi there$')" = 1 ] || fail "(3) multi-word prompt was not one arg: $out"
echo "$out" | "$GREP" -A1 '^ARG:--model$' | "$GREP" -q '^ARG:m1$' || fail "(3) --model not followed by the model value: $out"
pass; echo "PASS (3) the one-shot exec seam runs the stub (non-claude) runtime end-to-end"

# ── 4. BYTE-IDENTICAL DEFAULT: unset driver → the seam runs claude. ───────────────────────────────
out="$(HERD_DRIVERS_DIR="$ROOT/templates/drivers" PATH="$FB:$PATH" \
      bash -c '. "'"$DRIVER_SH"'"; herd_driver_oneshot_exec "hi" "m1"')" \
  || fail "(4) default-driver one-shot exec exited non-zero"
echo "$out" | "$GREP" -q '^RUNTIME:claude$' || fail "(4) default driver did not run claude: $out"
pass; echo "PASS (4) default driver runs claude (byte-identical) through the same seam"

# ── 5. ABSENT-BINDING DEGRADATION: a driver omitting the exec binding degrades to claude, no crash. ─
DD="$T/drivers"; mkdir -p "$DD"
# 'degraded' binds only the mux keys — NO DRIVER_AGENT_* at all (a driver with no exec surface).
cat > "$DD/degraded.driver" <<'EOF'
DRIVER_LIST_AGENTS='x list'
DRIVER_FOCUS_AGENT='x focus'
DRIVER_SEND_TEXT='x send'
DRIVER_SWITCH_MODEL='x model'
DRIVER_START_AGENT='x start'
DRIVER_CREATE_TAB='x tab'
DRIVER_READ_PANE='x read'
DRIVER_SEND_KEYS='x keys'
EOF
# 5a. herd_driver_agent_value (HERD-149) on a missing key → the [default] (empty here) + rc 0
#     (fail-soft under set -euo pipefail); herd_driver_agent_runtime built on it returns empty too.
b="$(HERD_DRIVER=degraded HERD_DRIVERS_DIR="$DD" \
     bash -c 'set -euo pipefail; . "'"$DRIVER_SH"'"; herd_driver_agent_value DRIVER_AGENT_ONESHOT_EXEC')" \
  || fail "(5a) herd_driver_agent_value aborted on an absent binding (must fail-soft)"
[ -z "$b" ] || fail "(5a) absent binding should be empty, got: $b"
r="$(HERD_DRIVER=degraded HERD_DRIVERS_DIR="$DD" \
     bash -c 'set -euo pipefail; . "'"$DRIVER_SH"'"; herd_driver_agent_runtime')" \
  || fail "(5a) herd_driver_agent_runtime aborted on a driver with no exec surface (must fail-soft)"
[ -z "$r" ] || fail "(5a) runtime for a driver with no exec surface should be empty, got: $r"
# 5b. herd_driver_agent_value against a MISSING driver file → the [default] (empty) + rc 0.
b="$(HERD_DRIVER=doesnotexist HERD_DRIVERS_DIR="$DD" \
     bash -c 'set -euo pipefail; . "'"$DRIVER_SH"'"; herd_driver_agent_value DRIVER_AGENT_ONESHOT_EXEC')" \
  || fail "(5b) herd_driver_agent_value aborted on a missing driver file (must fail-soft)"
[ -z "$b" ] || fail "(5b) missing driver file should yield empty binding, got: $b"
# 5c. the one-shot seam under the degraded driver degrades to claude and returns cleanly (no crash).
out="$(HERD_DRIVER=degraded HERD_DRIVERS_DIR="$DD" PATH="$FB:$PATH" \
      bash -c 'set -euo pipefail; . "'"$DRIVER_SH"'"; herd_driver_oneshot_exec "hi" "m1"')" \
  || fail "(5c) one-shot seam crashed under a driver missing its exec binding (must degrade, not crash)"
echo "$out" | "$GREP" -q '^RUNTIME:claude$' || fail "(5c) absent binding did not degrade to the claude default: $out"
pass; echo "PASS (5) a driver missing an agent-exec binding degrades cleanly to the default runtime"

echo "ALL PASS ($PASS checks)"
