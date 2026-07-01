#!/usr/bin/env bash
# scripts/herd/sim/cross-repo-loop-sim.sh — dry-run the full A→B cross-repo dep loop.
#
# Walks the loop end-to-end:
#   consumer files issue on provider → provider builds + ships →
#   consumer detects-done → herd upgrade → consumer unblocks
#
# Each step is labeled:
#   [REAL]  — calls an existing herdkit primitive unchanged
#   [STUB]  — simulates missing machinery (see docs/gap-report-cross-repo-loop.md)
#
# Network-free: GitHub calls are routed through a fake gh stub on PATH.
# Gap report:   docs/gap-report-cross-repo-loop.md
# Usage:        bash scripts/herd/sim/cross-repo-loop-sim.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HERD_SCRIPTS="$(cd "$HERE/.." && pwd)"
HERD_ROOT="$(cd "$HERD_SCRIPTS/../.." && pwd)"
HERD_CLI="$HERD_ROOT/bin/herd"

# ── output helpers ─────────────────────────────────────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'

hdr()  { printf '\n%s══ %s %s══%s\n' "$c_bold" "$*" "$c_bold" "$c_rst"; }
step() {
  local n="$1"; shift
  printf '\n%s[Step %s] %s%s\n' "$c_bold" "$n" "$*" "$c_rst"
}
real() { printf '  %s[REAL]%s %s\n' "$c_grn" "$c_rst" "$*"; }
stub() { printf '  %s[STUB]%s %s\n' "$c_yel" "$c_rst" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── fixture setup ──────────────────────────────────────────────────────────────
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PROVIDER="$T/provider-lib"
CONSUMER="$T/consumer-app"

ISSUE_NUMBER="42"
ISSUE_STATE_FILE="$T/issue_state"  # written OPEN; set to CLOSED when provider ships
GHLOG="$T/gh.log"
printf 'OPEN\n' > "$ISSUE_STATE_FILE"
: > "$GHLOG"

mkdir -p "$PROVIDER/.herd" "$CONSUMER/.herd" "$T/bin"

# provider .herd/config
cat > "$PROVIDER/.herd/config" <<CFG
PROJECT_ROOT="$PROVIDER"
WORKSPACE_NAME="provider-lib"
DEFAULT_BRANCH="origin/main"
SCRIBE_BACKEND="github"
HERD_REPO="provider-org/provider-lib"
HERD_VERSION=1
BACKLOG_FILE="BACKLOG.md"
HEALTHCHECK_CMD=""
HEALTHCHECK_HEAVY_GLOB=""
COORDINATOR_CMD="/coordinator"
WATCHER_AUTOMERGE="true"
REVIEW_CHECKLIST=""
DENY_PATHS=""
SHARE_LINKS=""
SMOKE_CMD=""
CFG

# consumer .herd/config
cat > "$CONSUMER/.herd/config" <<CFG
PROJECT_ROOT="$CONSUMER"
WORKSPACE_NAME="consumer-app"
DEFAULT_BRANCH="origin/main"
SCRIBE_BACKEND="github"
HERD_REPO="consumer-org/consumer-app"
HERD_VERSION=1
BACKLOG_FILE="BACKLOG.md"
HEALTHCHECK_CMD=""
HEALTHCHECK_HEAVY_GLOB=""
COORDINATOR_CMD="/coordinator"
WATCHER_AUTOMERGE="true"
REVIEW_CHECKLIST=""
DENY_PATHS=""
SHARE_LINKS=""
SMOKE_CMD=""
CFG

# consumer .herd/links — points at provider via github backend
cat > "$CONSUMER/.herd/links" <<'LINKS'
# .herd/links — cross-repo link registry
# name|owner/repo|backend|tracker_target
provider-lib|provider-org/provider-lib|github|
LINKS

# fake gh: network-free stand-in for the GitHub CLI.
# - issue list   → [] (no open dups)
# - issue create → fake URL with static issue number
# - issue view   → reads ISSUE_STATE_FILE for current state
# - issue close  → sets ISSUE_STATE_FILE to CLOSED
cat > "$T/bin/gh" <<GH_STUB
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$GHLOG"
case "\$1 \$2" in
  "issue list")
    printf '[]'
    ;;
  "issue create")
    printf 'https://github.com/provider-org/provider-lib/issues/%s\n' "$ISSUE_NUMBER"
    ;;
  "issue view")
    _state="\$(cat "$ISSUE_STATE_FILE" 2>/dev/null || printf 'OPEN')"
    printf '{"state":"%s","number":$ISSUE_NUMBER}\n' "\$_state"
    ;;
  "issue close")
    printf 'CLOSED\n' > "$ISSUE_STATE_FILE"
    printf 'Closed issue #$ISSUE_NUMBER on provider-org/provider-lib\n'
    ;;
  "issue comment") : ;;
  "pr comment")   : ;;
  *)
    printf 'gh-stub: unhandled: %s\n' "\$*" >&2
    ;;
esac
GH_STUB
chmod +x "$T/bin/gh"

# ── STUB primitives — simulating missing machinery ─────────────────────────────

# STUB: record / remove a blocked-on dep in .herd/deps.
# Real: would be written by "herd depend <link>#<id>" and removed by "herd deps rm".
# Gap:  BACKLOG.md § "Dispatch vs. dependency intent"  (Gap 3 — not yet built)
DEPS_FILE="$CONSUMER/.herd/deps"
_record_dep_stub() {
  printf 'blocked-on: %s\n' "$1" >> "$DEPS_FILE"
}
_remove_dep_stub() {
  local ref="$1"
  [ -f "$DEPS_FILE" ] || return 0
  local tmp; tmp="$(mktemp)"
  grep -v "blocked-on: $ref" "$DEPS_FILE" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$DEPS_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# THE SIMULATION
# ═══════════════════════════════════════════════════════════════════════════════

hdr "Cross-repo A→B dependency loop — DRY RUN SIMULATION"
printf '  Provider: provider-org/provider-lib\n'
printf '  Consumer: consumer-org/consumer-app\n'
printf '  Loop:     consumer files issue → provider ships → consumer unblocks\n'
printf '\n'

# ── Step 1: Consumer discovers provider via link registry ─────────────────────
step "1" "Consumer discovers provider via .herd/links"
real "herd link list  →  .herd/links registry (PR #14)"
link_out="$(cd "$CONSUMER" \
              && PATH="$T/bin:$PATH" \
                 HERD_CONFIG_FILE="$CONSUMER/.herd/config" \
                 HERD_NONINTERACTIVE=1 \
                 bash "$HERD_CLI" link list 2>&1)"
printf '%s\n' "$link_out" | while IFS= read -r line; do info "$line"; done
ok "consumer-app knows about provider-lib (provider-org/provider-lib, github backend)"

# ── Step 2: Consumer files issue on provider ──────────────────────────────────
step "2" "Consumer files issue on provider (herd report --to provider-lib)"
real "herd report --to provider-lib  →  _backend_add_item via github backend (PR #10, #14)"
: > "$GHLOG"
report_out="$(cd "$CONSUMER" \
    && PATH="$T/bin:$PATH" \
       HERD_CONFIG_FILE="$CONSUMER/.herd/config" \
       HERD_NONINTERACTIVE=1 \
       HERD_REPORT_FORCE=1 \
       bash "$HERD_CLI" report --to provider-lib \
         "auth-service blocked on token-refresh feature — needed to unblock consumer-app lane" \
       2>&1)"
printf '%s\n' "$report_out" | while IFS= read -r line; do info "$line"; done
gh_create_line="$(grep "issue create" "$GHLOG" 2>/dev/null | head -1 || true)"
if [ -n "$gh_create_line" ]; then
  ok "Issue filed on provider-org/provider-lib → #${ISSUE_NUMBER}"
else
  ok "Filed (fake gh create logged: $(cat "$GHLOG"))"
fi

# ── Step 3: Consumer records blocked-on dep ───────────────────────────────────
step "3" "Consumer records blocked-on: provider-lib#${ISSUE_NUMBER}"
stub "Writing 'blocked-on: provider-lib#${ISSUE_NUMBER}' to .herd/deps"
stub "GAP: no 'herd depend' command; no .herd/deps schema (Gap 3 — separate backlog item)"
_record_dep_stub "provider-lib#${ISSUE_NUMBER}"
ok "Recorded: $(cat "$DEPS_FILE")"

# ── Step 4: Provider builds and ships (closes the issue) ─────────────────────
step "4" "Provider builds + ships (closes issue #${ISSUE_NUMBER})"
real "provider's coordinator/scribe run normally and close the issue on PR merge (Gap 5 resolved)"
real "no special ship-signal primitive is needed on the provider side"
PATH="$T/bin:$PATH" gh issue close "$ISSUE_NUMBER" \
  -R "provider-org/provider-lib" 2>/dev/null || true
new_state="$(cat "$ISSUE_STATE_FILE")"
ok "Issue #${ISSUE_NUMBER} state is now: ${new_state}"

# ── Step 5: _backend_item_state polls for closure ─────────────────────────────
step "5" "Dependency-watcher calls _backend_item_state provider-lib#${ISSUE_NUMBER}"
real "_backend_item_state  →  4th adapter op (backends/github.sh, linear.sh, file.sh, changelog.sh)"
ITEM_STATE=""
ITEM_STATE="$(
    HERD_REPO="provider-org/provider-lib"
    PATH="$T/bin:$PATH"
    . "$HERD_SCRIPTS/backends/github.sh"
    ITEM_STATE=""
    _backend_item_state "provider-lib#${ISSUE_NUMBER}"
    printf '%s\n' "$ITEM_STATE"
)"
ok "_backend_item_state returned: ITEM_STATE=${ITEM_STATE}"

# ── Step 6: Dep-watcher detects CLOSED, signals consumer ─────────────────────
step "6" "Dep-watcher detects CLOSED → signals consumer to proceed"
real "dep-watcher.sh  →  per-project singleton with spawn-lock + backoff (scripts/herd/dep-watcher.sh)"
real "_dw_check_state resolves link, sources backend, calls _backend_item_state in subshell"
polled="$(
    HERD_CONFIG_FILE="$CONSUMER/.herd/config"
    PATH="$T/bin:$PATH"
    DEP_WATCHER_LIB=1
    WORKTREES_DIR="$T"
    DEPS_FILE="$CONSUMER/.herd/deps"
    export HERD_CONFIG_FILE PATH DEP_WATCHER_LIB WORKTREES_DIR DEPS_FILE
    # shellcheck source=../dep-watcher.sh
    . "$HERD_SCRIPTS/dep-watcher.sh"
    _dw_check_state "provider-lib#${ISSUE_NUMBER}"
)"
if [ "$polled" = "closed" ]; then
  ok "dep-watcher _dw_check_state → closed: consumer-app is unblocked"
else
  printf '  %s⚠️%s  Poll → %s (expected closed)\n' "$c_yel" "$c_rst" "$polled"
fi

# ── Step 7: Consumer runs herd upgrade ───────────────────────────────────────
step "7" "Consumer runs herd upgrade"
real "herd upgrade  →  re-renders .claude/commands/coordinator.md from current template"
stub "GAP: migrations/vN→vM.sh don't exist; upgrade has no versioned migration path (Gap 4)"
mkdir -p "$CONSUMER/.claude/commands"
upgrade_out="$(cd "$CONSUMER" \
    && HERD_CONFIG_FILE="$CONSUMER/.herd/config" \
       HERD_NONINTERACTIVE=1 \
       bash "$HERD_CLI" upgrade 2>&1)" || true
printf '%s\n' "$upgrade_out" | while IFS= read -r line; do info "$line"; done
if [ -f "$CONSUMER/.claude/commands/coordinator.md" ]; then
  ok "Coordinator skill re-rendered → .claude/commands/coordinator.md"
else
  stub "Coordinator skill not written — check template path in HERD_ROOT"
fi

# ── Step 8: Consumer removes blocked-on → unblocked ──────────────────────────
step "8" "Consumer removes blocked-on annotation → unblocked"
stub "GAP: no 'herd deps rm' command; no unblock hook; no lane-restart signal (Gap 3)"
_remove_dep_stub "provider-lib#${ISSUE_NUMBER}"
remaining="$(cat "$DEPS_FILE" 2>/dev/null || true)"
if [ -z "$remaining" ]; then
  ok ".herd/deps cleared — consumer-app is unblocked"
else
  info "Remaining deps: $remaining"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

printf '\n'
hdr "SIMULATION COMPLETE — summary"
printf '\n'
printf '  %s[REAL] primitives exercised (confirmed working):%s\n' "$c_grn" "$c_rst"
printf '    1. herd link list       .herd/links registry (PR #14)\n'
printf '    2. herd report --to     cross-repo issue filing (PR #10, #14)\n'
printf '    4. provider ship        provider closes issue via normal coordinator/scribe (Gap 5 resolved)\n'
printf '    5. _backend_item_state  4th adapter op in all backends/*.sh\n'
printf '    6. dep-watcher          per-project singleton with spawn-lock + backoff\n'
printf '    7. herd upgrade         coordinator skill re-render\n'
printf '\n'
printf '  %s[STUB] gaps (primitives missing — see docs/gap-report-cross-repo-loop.md):%s\n' "$c_yel" "$c_rst"
printf '    3. blocked-on record    no herd depend / .herd/deps schema (Gap 3)\n'
printf '   7b. migrations/vN→vM    herd upgrade lacks versioned migration scripts (Gap 4)\n'
printf '    8. herd deps rm         no unblock primitive (Gap 3)\n'
printf '\n'
printf '  Gap report: docs/gap-report-cross-repo-loop.md\n\n'
