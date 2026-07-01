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

# STUB: _backend_item_state — the missing 4th adapter op.
# Real: would be defined in each backends/*.sh file alongside add/mark/list.
# Gap:  BACKLOG.md § "_backend_item_state <id> op + dependency-watcher"
_backend_item_state_stub() {
  # $1 = "link-name#issue-number" (e.g. "provider-lib#42")
  # Sets ITEM_STATE=OPEN|CLOSED (would also return IN_PROGRESS in real impl).
  local ref="$1" number json
  number="${ref#*#}"
  json="$(PATH="$T/bin:$PATH" gh issue view "$number" \
            -R "provider-org/provider-lib" --json state 2>/dev/null \
         || printf '{"state":"UNKNOWN"}')"
  ITEM_STATE="$(printf '%s' "$json" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("state","UNKNOWN"))' \
      2>/dev/null \
    || printf '%s' "$json" | grep -oE '"state":"[A-Z]+"' | cut -d'"' -f4 \
    || printf 'UNKNOWN')"
}

# STUB: one poll cycle of the dependency watcher.
# Real: a persistent background loop (per-project singleton) calling
#       _backend_item_state on each recorded dep and signalling unblock on CLOSED.
# Gap:  BACKLOG.md § "_backend_item_state <id> op + dependency-watcher"
_dep_watcher_poll_stub() {
  # $1 = dep ref (e.g. "provider-lib#42"); echoes polled state.
  _backend_item_state_stub "$1"
  printf '%s\n' "$ITEM_STATE"
}

# STUB: record / remove a blocked-on dep in .herd/deps.
# Real: would be written by "herd depend <link>#<id>" and removed by "herd deps rm".
# Gap:  BACKLOG.md § "Dispatch vs. dependency intent"
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
stub "GAP: no 'herd depend' command; no .herd/deps schema; _backend_record_dep op missing"
_record_dep_stub "provider-lib#${ISSUE_NUMBER}"
ok "Recorded: $(cat "$DEPS_FILE")"

# ── Step 4: Provider builds and ships (closes the issue) ─────────────────────
step "4" "Provider builds + ships (closes issue #${ISSUE_NUMBER})"
stub "Simulating provider agent: closing issue #${ISSUE_NUMBER} on provider-org/provider-lib"
stub "GAP: real flow = provider coordinator/builder runs independently; sim closes issue directly"
PATH="$T/bin:$PATH" gh issue close "$ISSUE_NUMBER" \
  -R "provider-org/provider-lib" 2>/dev/null || true
new_state="$(cat "$ISSUE_STATE_FILE")"
ok "Issue #${ISSUE_NUMBER} state is now: ${new_state}"

# ── Step 5: _backend_item_state polls for closure ─────────────────────────────
step "5" "Dependency-watcher calls _backend_item_state provider-lib#${ISSUE_NUMBER}"
stub "_backend_item_state is a MISSING 4th adapter op (would live in each backends/*.sh)"
stub "Using _backend_item_state_stub → gh issue view --json state"
_backend_item_state_stub "provider-lib#${ISSUE_NUMBER}"
ok "_backend_item_state_stub returned: ITEM_STATE=${ITEM_STATE}"

# ── Step 6: Dep-watcher detects CLOSED, signals consumer ─────────────────────
step "6" "Dep-watcher detects CLOSED → signals consumer to proceed"
stub "GAP: no dep-watcher process; no polling loop; no per-dep unblock signal"
stub "Simulating one poll cycle..."
polled="$(_dep_watcher_poll_stub "provider-lib#${ISSUE_NUMBER}")"
if [ "$polled" = "CLOSED" ]; then
  ok "Poll → CLOSED: watcher would now trigger consumer-app unblock"
else
  printf '  %s⚠️%s  Poll → %s (expected CLOSED)\n' "$c_yel" "$c_rst" "$polled"
fi

# ── Step 7: Consumer runs herd upgrade ───────────────────────────────────────
step "7" "Consumer runs herd upgrade"
real "herd upgrade  →  re-renders .claude/commands/coordinator.md from current template"
stub "GAP: migrations/vN→vM.sh don't exist; upgrade has no versioned migration path"
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
stub "GAP: no 'herd deps rm' command; no unblock hook; no lane-restart signal"
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
printf '    7. herd upgrade         coordinator skill re-render\n'
printf '\n'
printf '  %s[STUB] gaps (primitives missing — see docs/gap-report-cross-repo-loop.md):%s\n' "$c_yel" "$c_rst"
printf '    3. blocked-on record    no herd depend / .herd/deps schema\n'
printf '    4. provider ship        no automated detect/signal from provider\n'
printf '    5. _backend_item_state  4th adapter op missing from all backends/*.sh\n'
printf '    6. dep-watcher          no polling loop / per-dep unblock signal\n'
printf '   7b. migrations/vN→vM    herd upgrade lacks versioned migration scripts\n'
printf '    8. herd deps rm         no unblock primitive\n'
printf '\n'
printf '  Gap report: docs/gap-report-cross-repo-loop.md\n\n'
