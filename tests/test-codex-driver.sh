#!/usr/bin/env bash
# test-codex-driver.sh — hermetic proof for the Codex agent-runtime driver (HERD-178).
#
# templates/drivers/codex.driver makes HERD_DRIVER=codex a REAL setting: it swaps the AGENT RUNTIME
# (Claude Code → OpenAI Codex CLI) while keeping herdr as the mux. This proof asserts the two things
# the task requires: (1) HERD_DRIVER=codex RESOLVES the binding table with NO missing-binding crash
# (a clean render, no leftover {{token}}); (2) the driver binds the full capability table — every mux
# key AND every agent-exec class — zero-secret, carrying Codex's REAL (researched, not guessed) flags,
# with the absent-binding degradation contract applied to the classes Codex does not expose.
#
# Fully hermetic: local temp git repo only. NO herdr, NO gh, NO codex, NO claude, NO network, NO model.
# Run:  bash tests/test-codex-driver.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"
DRIVER="$ROOT/templates/drivers/codex.driver"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$DRIVER" ] || fail "missing driver file: $DRIVER"

MUX_KEYS="DRIVER_LIST_AGENTS DRIVER_FOCUS_AGENT DRIVER_SEND_TEXT DRIVER_SWITCH_MODEL \
DRIVER_START_AGENT DRIVER_CREATE_TAB DRIVER_READ_PANE DRIVER_SEND_KEYS"
AGENT_KEYS="DRIVER_AGENT_INTERACTIVE_SPAWN DRIVER_AGENT_ONESHOT_EXEC DRIVER_AGENT_RESUME \
DRIVER_AGENT_MODEL_SWITCH DRIVER_AGENT_PERMISSION_FLAG DRIVER_AGENT_LIMIT_PATTERN \
DRIVER_AGENT_SESSION_ID DRIVER_AGENT_COST_USAGE_KEYS"

# ── 1. The driver PARSES and DEFINES every mux + agent-exec capability (set, non-empty). ──────────
( set -euo pipefail; . "$DRIVER"
  for k in $MUX_KEYS $AGENT_KEYS; do
    [ -n "${!k+set}" ] || { echo "  codex.driver: $k not defined" >&2; exit 1; }
    [ -n "${!k}" ]     || { echo "  codex.driver: $k is empty"    >&2; exit 1; }
  done
) || fail "codex.driver does not parse / bind every capability"
ok; echo "PASS (1) codex.driver parses and binds all 8 mux + 8 agent-exec capabilities"

# ── 2. ZERO-SECRET — command SHAPES only, no credentials / absolute host paths. ($HOME tokens ok.) ─
if grep -E '^DRIVER_[A-Z_]+=' "$DRIVER" | grep -qiE '/users/|/home/|secret|password|apikey'; then
  fail "codex.driver leaks a secret or absolute host path"
fi
ok; echo "PASS (2) codex.driver bindings are zero-secret"

# ── 3. Codex's REAL flags are bound (researched, not guessed) — an authenticity/drift guard. ──────
exact(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]+=/,"");print}' "$DRIVER"; }
grepd(){ grep -qF -e "$1" "$DRIVER" || fail "codex.driver missing real flag/incantation: $1"; }
grepd 'codex --model <model> --dangerously-bypass-approvals-and-sandbox "<prompt>"'   # interactive
grepd 'codex exec --model <model>'                                                    # one-shot exec
grepd 'resume --last'                                                                 # resume
grepd '--dangerously-bypass-approvals-and-sandbox'                                    # permission flag
[ "$(exact DRIVER_AGENT_MODEL_SWITCH)" = "'/model <model>'" ] || fail "codex model-switch not '/model <model>'"
# The mux stays herdr — swap the RUNTIME, not the multiplexer.
[ "$(exact DRIVER_LIST_AGENTS)" = "'herdr agent list'" ] || fail "codex.driver mux LIST_AGENTS drifted off herdr"
# Codex must NOT carry Claude's exec incantations in a BINDING (proves the runtime really swapped);
# scope to assignment lines so prose mentions of `claude …` in comments are fine.
grep -E '^DRIVER_' "$DRIVER" | grep -qF -e 'claude --model' && fail "codex.driver still binds a raw 'claude' spawn" || true
grep -E '^DRIVER_' "$DRIVER" | grep -qF -e 'claude -p'      && fail "codex.driver still binds a raw 'claude -p' one-shot" || true
ok; echo "PASS (3) codex.driver binds Codex's real flags; mux stays herdr; no residual claude exec"

# ── 4. Absent-binding DEGRADATION CONTRACT — unexposed classes carry the fail-safe @degrade sentinel.
for k in DRIVER_AGENT_LIMIT_PATTERN DRIVER_AGENT_COST_USAGE_KEYS; do
  v="$( . "$DRIVER"; printf '%s' "${!k}" )"
  case "$v" in @degrade:*) : ;; *) fail "$k should carry the @degrade sentinel, got: $v" ;; esac
done
# Fail-safe property: used as a regex the sentinel must NOT match a real usage-limit banner line.
lim="$( . "$DRIVER"; printf '%s' "$DRIVER_AGENT_LIMIT_PATTERN" )"
printf 'you have hit your usage limit\n' | grep -qE "$lim" \
  && fail "@degrade limit sentinel wrongly matches a real banner (not fail-safe)" || true
ok; echo "PASS (4) degradation contract: unexposed classes carry a fail-safe @degrade sentinel"

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

# ── 5. HERD_DRIVER=codex RESOLVES the binding table: a clean render, no missing-binding crash. ─────
R="$T/codexrepo"; mkdir -p "$R"; seed_repo "$R" 'HERD_DRIVER="codex"'
( cd "$R" && bash "$HERD" render ) >/dev/null || fail "HERD_DRIVER=codex render failed (missing-binding crash?)"
SK="$R/.claude/commands/coordinator.md"
[ -f "$SK" ] || fail "codex render produced no coordinator skill"
grep -qE '\{\{[A-Za-z_]' "$SK" && fail "codex render left an unsubstituted {{token}}" || true
# The four tokenized mux incantations rendered (herdr surface), proving the table resolved.
grep -qF 'herdr agent list' "$SK" || fail "codex render did not substitute the mux list-agents binding"
# No agent-exec value leaks into the rendered skill (nothing consumes them yet — byte-inert).
for k in $AGENT_KEYS; do
  [ "$k" = "DRIVER_AGENT_MODEL_SWITCH" ] && continue   # '/model' legitimately appears in skill prose
  v="$( . "$DRIVER"; printf '%s' "${!k}" )"
  grep -qF -e "$v" "$SK" && fail "agent-exec value for $k leaked into the rendered skill: $v" || true
done
ok; echo "PASS (5) HERD_DRIVER=codex renders cleanly — binding table resolves, no leftover token"

echo "ALL PASS ($pass checks)"
