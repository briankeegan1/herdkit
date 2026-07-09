#!/usr/bin/env bash
# test-grok-driver.sh — hermetic proof for the Grok Build agent-runtime driver (HERD-178).
#
# templates/drivers/grok.driver makes HERD_DRIVER=grok a REAL setting: it swaps the AGENT RUNTIME
# (Claude Code → xAI Grok Build CLI) while keeping herdr as the mux. This proof asserts the two things
# the task requires: (1) HERD_DRIVER=grok RESOLVES the binding table with NO missing-binding crash
# (a clean render, no leftover {{token}}); (2) the driver binds the full capability table — every mux
# key AND every agent-exec class — zero-secret, carrying Grok Build's REAL (researched, not guessed)
# flags, with the absent-binding degradation contract applied to the classes Grok does not expose.
#
# Fully hermetic: local temp git repo only. NO herdr, NO gh, NO grok, NO claude, NO network, NO model.
# Run:  bash tests/test-grok-driver.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"
DRIVER="$ROOT/templates/drivers/grok.driver"

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
    [ -n "${!k+set}" ] || { echo "  grok.driver: $k not defined" >&2; exit 1; }
    [ -n "${!k}" ]     || { echo "  grok.driver: $k is empty"    >&2; exit 1; }
  done
) || fail "grok.driver does not parse / bind every capability"
ok; echo "PASS (1) grok.driver parses and binds all 8 mux + 8 agent-exec capabilities"

# ── 2. ZERO-SECRET — command SHAPES only, no credentials / absolute host paths. ($HOME tokens ok.) ─
if grep -E '^DRIVER_[A-Z_]+=' "$DRIVER" | grep -qiE '/users/|/home/|secret|password|apikey'; then
  fail "grok.driver leaks a secret or absolute host path"
fi
ok; echo "PASS (2) grok.driver bindings are zero-secret"

# ── 3. Grok Build's REAL flags are bound (researched, not guessed) — an authenticity/drift guard. ─
exact(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]+=/,"");print}' "$DRIVER"; }
grepd(){ grep -qF -e "$1" "$DRIVER" || fail "grok.driver missing real flag/incantation: $1"; }
grepd 'grok --model <model> --always-approve'              # interactive spawn (grok's real flags)
grepd '--append-rules-to-system-prompt <agents-rules> "<prompt>"'  # grok-context-injection: additive conventions grounding
grepd 'grok -p "<prompt>" --model <model> --always-approve' # one-shot / headless (-p,--single)
grepd 'grok --continue --always-approve'                    # resume (-c,--continue)
grepd '--always-approve'                                    # permission / auto-approve flag
[ "$(exact DRIVER_AGENT_MODEL_SWITCH)" = "'/model <model>'" ] || fail "grok model-switch not '/model <model>'"
# The mux stays herdr — swap the RUNTIME, not the multiplexer.
[ "$(exact DRIVER_LIST_AGENTS)" = "'herdr agent list'" ] || fail "grok.driver mux LIST_AGENTS drifted off herdr"
# Grok must NOT carry Claude's exec incantations in a BINDING (proves the runtime really swapped);
# scope to assignment lines so prose mentions of `claude …` in comments are fine.
grep -E '^DRIVER_' "$DRIVER" | grep -qF -e 'claude --model' && fail "grok.driver still binds a raw 'claude' spawn" || true
grep -E '^DRIVER_' "$DRIVER" | grep -qF -e 'claude -p'      && fail "grok.driver still binds a raw 'claude -p' one-shot" || true
ok; echo "PASS (3) grok.driver binds Grok's real flags; mux stays herdr; no residual claude exec"

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

# ── 5. HERD_DRIVER=grok RESOLVES the binding table: a clean render, no missing-binding crash. ──────
R="$T/grokrepo"; mkdir -p "$R"; seed_repo "$R" 'HERD_DRIVER="grok"'
( cd "$R" && bash "$HERD" render ) >/dev/null || fail "HERD_DRIVER=grok render failed (missing-binding crash?)"
SK="$R/.claude/commands/coordinator.md"
[ -f "$SK" ] || fail "grok render produced no coordinator skill"
grep -qE '\{\{[A-Za-z_]' "$SK" && fail "grok render left an unsubstituted {{token}}" || true
# The four tokenized mux incantations rendered (herdr surface), proving the table resolved.
grep -qF 'herdr agent list' "$SK" || fail "grok render did not substitute the mux list-agents binding"
# No agent-exec value leaks into the rendered skill (nothing consumes them yet — byte-inert).
for k in $AGENT_KEYS; do
  [ "$k" = "DRIVER_AGENT_MODEL_SWITCH" ] && continue   # '/model' legitimately appears in skill prose
  v="$( . "$DRIVER"; printf '%s' "${!k}" )"
  grep -qF -e "$v" "$SK" && fail "agent-exec value for $k leaked into the rendered skill: $v" || true
done
ok; echo "PASS (5) HERD_DRIVER=grok renders cleanly — binding table resolves, no leftover token"

# ── 6. CONTEXT-INJECTION: a grok interactive spawn's COMPOSED argv carries the repo-root AGENTS.md
#      conventions (grok has no CLAUDE.md auto-load), while a claude spawn's argv is byte-IDENTICAL to
#      before (no conventions leak, no new flag) — the grok-context-injection invariant. ────────────
command -v python3 >/dev/null 2>&1 || fail "python3 required for the compose test"
CROOT="$T/convroot"; mkdir -p "$CROOT"
AGENTS_MARK="SENTINEL_AGENTS_CONVENTION_XYZZY"
printf '# AGENTS.md\n\n%s — builders never edit BACKLOG.md.\n' "$AGENTS_MARK" > "$CROOT/AGENTS.md"

# NUL token-separator, rendered as a real unit-separator byte (0x1f) so `[ = ]` can byte-compare the
# token stream and `case` can scan it. Built via printf so it is an actual control char, not literal text.
SEP="$(printf '\037')"

# Compose a grok spawn argv (NUL-separated) with PROJECT_ROOT pointed at the conventions repo. Source
# driver.sh + herd-config.sh hermetically (HERD_SKIP_PREFLIGHT, sandboxed HOME/config) so the REAL
# herd_agents_conventions resolves the file.
compose_argv() {  # compose_argv <driver> <project_root>
  HOME="$T" HERD_SKIP_PREFLIGHT=1 HERD_CONFIG_FILE="$T/noconfig" PROJECT_ROOT="$2" \
  WORKTREES_DIR="$T/trees" WORKSPACE_NAME="herdkit" DEFAULT_BRANCH="origin/main" \
  ROOT="$ROOT" DRV="$1" PR="$2" bash -c '
    set -uo pipefail
    . "$ROOT/scripts/herd/herd-config.sh" >/dev/null 2>&1 || true
    . "$ROOT/scripts/herd/driver.sh"
    PROJECT_ROOT="$PR" herd_driver_agent_spawn_argv "$DRV" "grok-model" "--always-approve" "POINTER_TEXT" \
      | tr "\0" "\037"
  '
}

grok_argv="$(compose_argv grok "$CROOT")"          || fail "composing a grok spawn argv failed"
claude_argv="$(compose_argv herdr-claude "$CROOT")" || fail "composing a claude spawn argv failed"

# (a) grok's composed argv carries the conventions AND the additive append-rules flag.
case "$grok_argv" in
  *"--append-rules-to-system-prompt"*) : ;;
  *) fail "grok spawn argv missing --append-rules-to-system-prompt: $grok_argv" ;;
esac
case "$grok_argv" in
  *"$AGENTS_MARK"*) : ;;
  *) fail "grok spawn argv does NOT inline the repo-root AGENTS.md conventions: $grok_argv" ;;
esac
# (b) a claude spawn is byte-identical to today: no conventions, no append-rules flag.
case "$claude_argv" in
  *"$AGENTS_MARK"*) fail "claude spawn argv LEAKED AGENTS.md conventions (must stay byte-identical): $claude_argv" ;;
esac
case "$claude_argv" in
  *"--append-rules-to-system-prompt"*) fail "claude spawn argv grew an append-rules flag (must stay byte-identical): $claude_argv" ;;
esac
# The claude argv is exactly the pre-injection native shape (proves byte-identity, not just absence).
[ "$claude_argv" = "claude${SEP}--model${SEP}grok-model${SEP}--always-approve${SEP}POINTER_TEXT${SEP}" ] \
  || fail "claude spawn argv drifted from the native shape: $claude_argv"

# (c) FAIL-SOFT: with NO AGENTS.md/CLAUDE.md at the root, grok's argv drops the flag+value pair and is
#     byte-identical to the plain grok spawn shape (no dangling --append-rules flag).
EMPTY="$T/emptyroot"; mkdir -p "$EMPTY"
grok_bare="$(compose_argv grok "$EMPTY")" || fail "composing a bare grok spawn argv failed"
case "$grok_bare" in
  *"--append-rules-to-system-prompt"*) fail "grok argv kept a dangling append-rules flag with no AGENTS.md: $grok_bare" ;;
esac
[ "$grok_bare" = "grok${SEP}--model${SEP}grok-model${SEP}--always-approve${SEP}POINTER_TEXT${SEP}" ] \
  || fail "bare grok spawn argv (no conventions) drifted from the plain grok shape: $grok_bare"
ok; echo "PASS (6) grok spawn argv inlines AGENTS.md conventions; claude byte-identical; fail-soft when absent"

echo "ALL PASS ($pass checks)"
