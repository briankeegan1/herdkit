#!/usr/bin/env bash
# test-driver-agent-exec.sh — hermetic proof for PHASE 1 of the agent-runtime portability epic
# (HERD-150): the .driver format is extended with an AGENT-EXEC surface (DRIVER_AGENT_* bindings) that
# catalogues every claude-specific incantation by capability class, WITHOUT routing any call site yet.
#
# The CRITICAL P1 INVARIANT this locks in: the new bindings are pure data + docs. Nothing renders or
# consumes them, so `herd render` output and runtime behavior stay BYTE-IDENTICAL — proven here by
# rendering the SAME seed repo against the shipped driver and against a copy with the agent-exec block
# stripped, and asserting the two rendered skills are identical.
#
# Also covered: both shipped .driver files parse with the extended format; every capability class is
# bound in BOTH drivers; the new bindings are zero-secret (command shapes only); and herdr-claude
# carries today's EXACT strings.
#
# Fully hermetic: local temp git repos only. NO herdr, NO gh, NO claude, NO network, NO model.
# Run:  bash tests/test-driver-agent-exec.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"
HC="$ROOT/templates/drivers/herdr-claude.driver"
HL="$ROOT/templates/drivers/headless.driver"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

for f in "$HERD" "$HC" "$HL"; do [ -f "$f" ] || fail "missing required file: $f"; done

# The agent-exec capability classes P1 catalogues — one DRIVER_AGENT_* binding each.
AGENT_KEYS="DRIVER_AGENT_INTERACTIVE_SPAWN DRIVER_AGENT_ONESHOT_EXEC DRIVER_AGENT_RESUME \
DRIVER_AGENT_MODEL_SWITCH DRIVER_AGENT_PERMISSION_FLAG DRIVER_AGENT_LIMIT_PATTERN \
DRIVER_AGENT_SESSION_ID DRIVER_AGENT_COST_USAGE_KEYS"

# ── 1. Both .driver files PARSE with the extended format and DEFINE every agent-exec class. ───────
# Source each in a clean subshell (as render_skill does) and confirm every key is set + non-empty.
for df in "$HC" "$HL"; do
  # shellcheck disable=SC1090
  ( set -euo pipefail; . "$df"
    for k in $AGENT_KEYS; do
      [ -n "${!k+set}" ] || { echo "  $df: $k not defined" >&2; exit 1; }
      [ -n "${!k}" ]     || { echo "  $df: $k is empty"    >&2; exit 1; }
    done
  ) || fail "$df does not parse / bind every agent-exec class"
done
ok; echo "PASS (1) both drivers parse and bind all 8 agent-exec classes"

# ── 2. The bindings are ZERO-SECRET — command SHAPES only, no absolute host paths / credentials. ──
# ($HOME/.herd tokens are fine; a literal /Users//home/ or credential word is not.)
for df in "$HC" "$HL"; do
  if grep -E '^DRIVER_AGENT_[A-Z_]+=' "$df" | grep -qiE '/users/|/home/|secret|password|apikey'; then
    fail "$df: an agent-exec binding leaks a secret or absolute path"
  fi
done
ok; echo "PASS (2) agent-exec bindings are zero-secret"

# ── 3. herdr-claude carries today's EXACT strings for each class. ─────────────────────────────────
exact_binding(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]+=/,"");print}' "$HC"; }
check(){ [ "$(exact_binding "$1")" = "$2" ] || fail "herdr-claude $1 not the exact string: got [$(exact_binding "$1")]"; }
check DRIVER_AGENT_INTERACTIVE_SPAWN "'claude --model <model> --dangerously-skip-permissions \"<prompt>\"'"
check DRIVER_AGENT_ONESHOT_EXEC      "'claude -p \"<prompt>\" --model <model> --dangerously-skip-permissions'"
check DRIVER_AGENT_RESUME            "'claude --dangerously-skip-permissions --continue \"<prompt>\"'"
check DRIVER_AGENT_MODEL_SWITCH      "'/model <model>'"
check DRIVER_AGENT_PERMISSION_FLAG   "'--dangerously-skip-permissions'"
check DRIVER_AGENT_LIMIT_PATTERN     "'usage limit|session limit|hit your (usage|session) limit'"
check DRIVER_AGENT_COST_USAGE_KEYS   "'input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens'"
# The real code these mirror must still contain the exact string — a drift guard on the audit map.
# one-shot-exec has been ROUTED (HERD-150 P3): the `claude -p …` incantation now lives ONCE in the
# driver seam (herd_driver_oneshot_exec), and the drainer sites call THAT — so the guard follows the
# incantation to driver.sh and asserts the advisor site routes through the seam (no raw `claude -p`).
grep -qF 'claude -p "$prompt" --model "$model"' "$ROOT/scripts/herd/driver.sh" \
  || fail "one-shot-exec incantation drifted out of the driver seam (driver.sh: herd_driver_oneshot_exec)"
grep -qF 'herd_driver_oneshot_exec "$PROMPT" "$ADVISE_MODEL"' "$ROOT/scripts/herd/herd-advise.sh" \
  || fail "herd-advise.sh no longer routes its one-shot query through the driver seam"
grep -qF 'claude -p "$' "$ROOT/scripts/herd/herd-advise.sh" \
  && fail "herd-advise.sh still calls a RAW claude -p (must route through herd_driver_oneshot_exec)"
# resume + limit-detection have been ROUTED (HERD-176 / HERD-150 P4): the resume/limit phrase now
# live in the driver seam; agent-watch resolves them via the helpers (not a raw hardcode).
grep -qF "claude --dangerously-skip-permissions --continue" "$ROOT/scripts/herd/driver.sh" \
  || fail "resume fallback/default drifted out of the driver seam (driver.sh: herd_driver_agent_resume_cmd)"
grep -qF 'herd_driver_agent_resume_cmd' "$ROOT/scripts/herd/agent-watch.sh" \
  || fail "agent-watch.sh no longer routes resume through herd_driver_agent_resume_cmd"
grep -qF 'herd_driver_agent_limit_pattern' "$ROOT/scripts/herd/agent-watch.sh" \
  || fail "agent-watch.sh no longer routes limit-banner through herd_driver_agent_limit_pattern"
grep -qF 'usage limit|session limit|hit your (usage|session) limit' "$ROOT/scripts/herd/driver.sh" \
  || fail "limit-detection default drifted out of the driver seam (driver.sh: herd_driver_agent_limit_pattern)"
ok; echo "PASS (3) herdr-claude binds today's exact strings; audit sites still present"

# ── seed a minimal herd project `herd render` accepts (mirrors test-driver-abstraction.sh). ───────
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

# ── 4. BYTE-IDENTITY: rendering with the agent-exec block present vs stripped is identical. ────────
# Build a drivers dir holding (a) the shipped herdr-claude and (b) a copy with the DRIVER_AGENT_*
# block removed. Render the same repo against each; the coordinator skills must be byte-for-byte equal,
# proving the new bindings are inert (no token consumes them).
DD="$T/drivers"; mkdir -p "$DD"
cp "$HC" "$DD/herdr-claude.driver"
grep -v '^DRIVER_AGENT_' "$HC" > "$DD/stripped.driver"

P="$T/withexec";   mkdir -p "$P"; seed_repo "$P"
Q="$T/noexec";     mkdir -p "$Q"; seed_repo "$Q" 'HERD_DRIVER="stripped"'
render "$P" HERD_DRIVERS_DIR="$DD" >/dev/null || fail "render with agent-exec block failed"
render "$Q" HERD_DRIVERS_DIR="$DD" >/dev/null || fail "render with stripped driver failed"
SKP="$P/.claude/commands/coordinator.md"; SKQ="$Q/.claude/commands/coordinator.md"
sed "s#$P#PROOT#g" "$SKP" > "$T/withexec.md"
sed "s#$Q#PROOT#g" "$SKQ" > "$T/noexec.md"
diff -q "$T/withexec.md" "$T/noexec.md" >/dev/null \
  || { echo "--- present vs stripped differ ---"; diff "$T/withexec.md" "$T/noexec.md" | head; fail "agent-exec bindings changed the render (NOT byte-identical)"; }
ok; echo "PASS (4) render is byte-identical with vs without the agent-exec block"

# ── 5. No agent-exec binding value LEAKS into the rendered skill (nothing consumes them). ──────────
grep -qE '\{\{' "$SKP" && fail "rendered skill has an unsubstituted {{token}}" || true
for k in $AGENT_KEYS; do
  # shellcheck disable=SC1090
  v="$( . "$HC"; printf '%s' "${!k}" )"
  # The literal /model string legitimately appears in the skill's own prose; exclude that one class.
  [ "$k" = "DRIVER_AGENT_MODEL_SWITCH" ] && continue
  grep -qF -e "$v" "$SKP" && fail "agent-exec value for $k leaked into the rendered skill: $v" || true
done
ok; echo "PASS (5) no agent-exec binding leaks into the rendered coordinator skill"

echo "ALL PASS ($pass checks)"
