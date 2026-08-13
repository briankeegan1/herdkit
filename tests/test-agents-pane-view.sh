#!/usr/bin/env bash
# test-agents-pane-view.sh — hermetic tests for scripts/herd/agents-pane-view.sh (HERD-668): the
# read-only AGENTS_PANE control-room pane renderer.
#
# Asserts:
#   (1) AGENTS_PANE defaults to "off" (herd-config.sh) — the ship-dormant contract.
#   (2) the renderer shows the roster (name + CACHED verdict glyph, never a live probe) and an
#       explicit empty-roster hint when none exists.
#   (3) the renderer shows each in-flight builder paired with the specialist agent it was spawned
#       under (the .herd-agent-<slug> marker), falling back to "general" when the marker is absent.
#   (4) "(none in flight)" when the builder registry is empty/absent.
#
# HERMETIC: no herdr, no network, no model call — a single bounded pass through the real render loop
# (AGENTS_PANE_VIEW_MAX_POLLS=1) with its tty muting pointed at /dev/null (mirrors backlog-view.sh's
# test hooks: BACKLOG_VIEW_TTY / BACKLOG_VIEW_MAX_POLLS).
#
# Run:  bash tests/test-agents-pane-view.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/scripts/herd/agents-pane-view.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

[ -f "$SCRIPT" ] || fail "missing $SCRIPT"

# ── (1) AGENTS_PANE defaults to off ────────────────────────────────────────────────────────────────
grep -qE '^: "\$\{AGENTS_PANE:="off"\}"' "$ROOT/scripts/herd/herd-config.sh" \
  || fail "(1) AGENTS_PANE is not declared off-by-default in herd-config.sh"
pass; echo "PASS (1) AGENTS_PANE defaults to off in herd-config.sh"

# _project <dir> <extra-config-lines...> — a minimal project the console guard accepts.
_project() {
  local p="$1"; shift
  mkdir -p "$p/.herd"
  {
    echo "PROJECT_ROOT=\"$p\""
    echo "WORKTREES_DIR=\"$p/.worktrees\""
    echo "WORKSPACE_NAME=\"apv-test\""
    echo "DEFAULT_BRANCH=\"origin/main\""
    echo "BACKLOG_FILE=\"BACKLOG.md\""
    echo "SCRIBE_BACKEND=\"file\""
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$p/.herd/config"
  mkdir -p "$p/.worktrees"
}

_render() {
  local p="$1"
  HERD_CONFIG_FILE="$p/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 \
    AGENTS_PANE_VIEW_TTY=/dev/null AGENTS_PANE_VIEW_MAX_POLLS=1 AGENTS_PANE_VIEW_COLS_CMD="$T/cols.sh" \
    bash "$SCRIPT" 2>/dev/null
}
printf '#!/usr/bin/env bash\necho 32\n' > "$T/cols.sh"; chmod +x "$T/cols.sh"

# ── (2) empty roster → an explicit hint, never a blank pane ──────────────────────────────────────
P2="$T/p2"; _project "$P2"
out="$(_render "$P2")"
case "$out" in *"no roster"*) : ;; *) fail "(2) empty-roster pane did not print a hint: [$out]" ;; esac
pass; echo "PASS (2) empty roster renders an explicit hint"

# ── (3) roster entry + CACHED verdict, no live probe ──────────────────────────────────────────────
P3="$T/p3"; _project "$P3"
mkdir -p "$P3/.herd/agents"
printf '%s\n' '---' 'description: a test agent' 'sentinel: TEST-SENTINEL-1' '---' 'body' \
  > "$P3/.herd/agents/tester.md"
out="$(_render "$P3")"
case "$out" in *tester*) : ;; *) fail "(3a) roster entry 'tester' not rendered: [$out]" ;; esac
# Unverified (no cache row yet) renders the '?' glyph, not a false checkmark.
case "$out" in *'?'*) : ;; *) fail "(3a) unverified entry did not render the '?' glyph: [$out]" ;; esac
pass; echo "PASS (3a) roster entry renders with its unverified glyph, no live probe"

# Seed an 'ok' cache verdict for the SAME (driver, name, sha) key the renderer reads, via the real
# agents.sh cache writer — never hand-crafting the ledger row format.
sha="$(HERD_CONFIG_FILE="$P3/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 bash -c '
  . "'"$ROOT"'/scripts/herd/herd-config.sh"
  . "'"$ROOT"'/scripts/herd/agents.sh"
  herd_roster_sha "$PROJECT_ROOT/.herd/agents/tester.md"
')"
[ -n "$sha" ] || fail "(3b) could not compute the definition sha (no hasher on this machine?)"
HERD_CONFIG_FILE="$P3/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 bash -c '
  . "'"$ROOT"'/scripts/herd/herd-config.sh"
  . "'"$ROOT"'/scripts/herd/agents.sh"
  herd_roster_cache_put herdr-claude tester "'"$sha"'" ok "probe=flag sentinel returned"
'
out="$(_render "$P3")"
case "$out" in *"✓"*) : ;; *) fail "(3b) cached 'ok' verdict did not render the ✓ glyph: [$out]" ;; esac
pass; echo "PASS (3b) a cached 'ok' verdict renders the ✓ glyph — proves the CACHE path, not a probe"

# ── (4) no builder registry → '(none in flight)' ──────────────────────────────────────────────────
out="$(_render "$P3")"
case "$out" in *"none in flight"*) : ;; *) fail "(4) empty builder registry did not render '(none in flight)': [$out]" ;; esac
pass; echo "PASS (4) no in-flight builders renders an explicit '(none in flight)' line"

# ── (5) in-flight builders paired with their specialist agent (or 'general' when unmarked) ────────
P5="$T/p5"; _project "$P5"
printf 'with-agent %s builder\n' t1  > "$P5/.worktrees/.herd-tabs"
printf 'no-agent %s builder\n'  t2 >> "$P5/.worktrees/.herd-tabs"
printf 'tester\n' > "$P5/.worktrees/.herd-agent-with-agent"
out="$(_render "$P5")"
case "$out" in *"with-agent"*) : ;; *) fail "(5) builder slug 'with-agent' not rendered: [$out]" ;; esac
case "$out" in *"no-agent"*)   : ;; *) fail "(5) builder slug 'no-agent' not rendered: [$out]" ;; esac
case "$out" in *tester*) : ;; *) fail "(5) specialist agent 'tester' not rendered for with-agent: [$out]" ;; esac
case "$out" in *general*) : ;; *) fail "(5) unmarked builder did not fall back to 'general': [$out]" ;; esac
pass; echo "PASS (5) in-flight builders render slug + specialist agent (or 'general' when unmarked)"

echo "ALL PASS ($PASS checks)"
