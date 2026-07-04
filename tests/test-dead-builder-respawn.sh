#!/usr/bin/env bash
# test-dead-builder-respawn.sh — hermetic test for the watcher's bounded, opt-in dead-builder
# AUTO-RESPAWN (follow-up to the DETECT+SURFACE shipped in PR #117). It sources agent-watch.sh's pure
# helpers via the AGENT_WATCH_LIB guard (helpers only, no live loop), stubs `herdr` on PATH so a
# respawn is CAPTURED (tab create → agent start) and no real pane/agent is ever launched, builds real
# throwaway git worktrees to exercise the work-detection rail, drives the clock with HERD_NOW_EPOCH,
# and asserts the flag + classification + reconciliation logic. The four spec-mandated cases:
#   • off (flag unset/off)               → OFF          (never respawns; byte-inert)
#   • on + commitless-dead + clean       → RESPAWN once  (fresh agent started; ledger records it)
#   • on + dead WITH commits             → SKIP_WORK     (escalate, never blow away work)
#   • on + already-respawned + dead again → SKIP_ALREADY (escalate, never a second respawn / loop)
# Plus the pure helpers (_dead_autorespawn_on flag parse, _worktree_has_work commits/dirty, the
# _classify_respawn ordering) and the at-most-once ledger + notification behavior.
# Run:  bash tests/test-dead-builder-respawn.sh
# No `set -e`: some checks deliberately expect a non-zero predicate return; we assert explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git     >/dev/null 2>&1 || fail "git required to run this test"

# ── stub `herdr` on PATH: capture notifications + the respawn spawn, launch nothing real ───────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
# Only the surfaces auto-respawn touches are stubbed:
#   notification show <title> …  → append <title> to $HERDR_NOTIFY_LOG
#   workspace list               → empty workspace set (spawn proceeds unpinned, no --workspace)
#   tab create …                 → valid JSON with a fake tab + root pane id
#   agent start <slug> …         → append the whole invocation to $HERDR_AGENT_LOG (proof of respawn)
case "${1:-}/${2:-}" in
  notification/show) printf '%s\n' "${3:-}" >> "${HERDR_NOTIFY_LOG:?HERDR_NOTIFY_LOG unset}" ;;
  workspace/list)    printf '%s\n' '{"result":{"workspaces":[]}}' ;;
  tab/create)        printf '%s\n' '{"result":{"tab":{"tab_id":"tab-fake"},"root_pane":{"pane_id":"pane-fake"}}}' ;;
  agent/start)       printf '%s\n' "$*" >> "${HERDR_AGENT_LOG:?HERDR_AGENT_LOG unset}" ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# Source the watcher's helpers WITHOUT its live loop, fully hermetic (no repo/.herd walk-up).
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in _dead_autorespawn_on _worktree_has_work _classify_respawn respawn_recorded \
          record_respawn _respawn_builder_in_worktree _maybe_autorespawn_dead_builder; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

# Redirect every stateful path at the temp dir (plain globals; safe to reassign post-source).
TREES="$T/trees"; mkdir -p "$TREES"
DEAD_STATE="$T/.agent-watch-dead"
DEAD_RESPAWN_STATE="$T/.agent-watch-respawn"
DEFAULT_BRANCH="main"                    # local base ref (no origin/ in this hermetic repo)
export HERDR_NOTIFY_LOG="$T/notify.log"; : > "$HERDR_NOTIFY_LOG"
export HERDR_AGENT_LOG="$T/agent.log";   : > "$HERDR_AGENT_LOG"
export JOURNAL_FILE="$T/journal.log"     # keep journal_append writes inside the temp dir if honored
NOW=1000000000

# mkrepo <dir> <clean|commits|dirty> — build a throwaway git worktree in the requested state.
mkrepo() {
  local d="$1" kind="$2"
  git -c init.defaultBranch=main init -q "$d"
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  case "$kind" in
    clean)   : ;;                                                             # HEAD==main, tree clean
    commits) git -C "$d" checkout -q -b feat
             git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m ahead ;;  # 1 ahead
    dirty)   printf 'wip\n' > "$d/scratch.txt" ;;                             # untracked change present
  esac
}

# ── _dead_autorespawn_on: DEFAULT OFF; only on|true|yes|1 enable it ───────────────────────────────
( unset DEAD_BUILDER_AUTORESPAWN; _dead_autorespawn_on ) && fail "unset flag must be OFF"
DEAD_BUILDER_AUTORESPAWN=off  _dead_autorespawn_on && fail "off must be OFF"
DEAD_BUILDER_AUTORESPAWN=junk _dead_autorespawn_on && fail "garbage must be OFF"
DEAD_BUILDER_AUTORESPAWN=on   _dead_autorespawn_on || fail "on must be ON"
DEAD_BUILDER_AUTORESPAWN=true _dead_autorespawn_on || fail "true must be ON"
DEAD_BUILDER_AUTORESPAWN=1    _dead_autorespawn_on || fail "1 must be ON"
ok

# ── _worktree_has_work: clean → no work; commits ahead → work; dirty tree → work ──────────────────
mkrepo "$T/wt-clean"   clean
mkrepo "$T/wt-commits" commits
mkrepo "$T/wt-dirty"   dirty
_worktree_has_work "$T/wt-clean"   && fail "a clean worktree (0 ahead) must have NO work"
_worktree_has_work "$T/wt-commits" || fail "a worktree with commits ahead must have work"
_worktree_has_work "$T/wt-dirty"   || fail "a dirty worktree (untracked change) must have work"
_worktree_has_work "$T/nope"       || fail "an un-inspectable path must fail SAFE (has work)"
ok

# ── _classify_respawn: pure ordering (OFF → SKIP_ALREADY → SKIP_WORK → RESPAWN) ────────────────────
#                      on has-work already
[ "$(_classify_respawn 0 0 0)" = "OFF" ]          || fail "flag off → OFF"
[ "$(_classify_respawn 0 1 1)" = "OFF" ]          || fail "flag off overrides everything → OFF"
[ "$(_classify_respawn 1 0 1)" = "SKIP_ALREADY" ] || fail "already-respawned → SKIP_ALREADY"
[ "$(_classify_respawn 1 1 1)" = "SKIP_ALREADY" ] || fail "already beats work in ordering → SKIP_ALREADY"
[ "$(_classify_respawn 1 1 0)" = "SKIP_WORK" ]    || fail "has work (not yet respawned) → SKIP_WORK"
[ "$(_classify_respawn 1 0 0)" = "RESPAWN" ]      || fail "on + clean + fresh → RESPAWN"
ok

# ════════════════════════════════════════════════════════════════════════════════════════════════
# End-to-end reconciliation via _maybe_autorespawn_dead_builder (the DEAD-crossing entry point).
# reset — truncate every captured surface between scenarios.
reset() { : > "$HERDR_NOTIFY_LOG"; : > "$HERDR_AGENT_LOG"; : > "$DEAD_RESPAWN_STATE"; }

# ── (1) OFF never respawns — byte-inert: no spawn, no ledger, no notification ──────────────────────
reset
mkrepo "$T/wt-off" clean; printf 'spec\n' > "$TREES/off-slug.task.md"
v="$(DEAD_BUILDER_AUTORESPAWN=off HERD_NOW_EPOCH="$NOW" _maybe_autorespawn_dead_builder off-slug "$T/wt-off")"
[ "$v" = "OFF" ]                        || fail "(1) flag off should verdict OFF, got $v"
[ -s "$HERDR_AGENT_LOG" ]               && fail "(1) OFF must NOT start any agent"
respawn_recorded off-slug              && fail "(1) OFF must NOT write the respawn ledger"
[ -s "$HERDR_NOTIFY_LOG" ]             && fail "(1) OFF must NOT fire an extra notification"
ok

# ── (2) ON + commitless-dead + clean → RESPAWN once (fresh agent, pointed at the existing spec) ────
reset
mkrepo "$T/wt-live" clean; printf 'spec\n' > "$TREES/live-slug.task.md"
v="$(DEAD_BUILDER_AUTORESPAWN=on HERD_NOW_EPOCH="$NOW" _maybe_autorespawn_dead_builder live-slug "$T/wt-live")"
[ "$v" = "RESPAWN" ]                            || fail "(2) on+clean+fresh should verdict RESPAWN, got $v"
grep -q "agent start live-slug" "$HERDR_AGENT_LOG" || fail "(2) RESPAWN must start a fresh agent for the slug"
grep -q "claude" "$HERDR_AGENT_LOG"            || fail "(2) respawn must launch claude in the worktree"
respawn_recorded live-slug                     || fail "(2) RESPAWN must record the at-most-once ledger"
grep -q "respawned" "$DEAD_RESPAWN_STATE"      || fail "(2) ledger line must mark state=respawned"
grep -q "auto-respawned: live-slug" "$HERDR_NOTIFY_LOG" || fail "(2) RESPAWN should fire a ♻️ notification"
ok

# ── (2b) at-most-once: the SAME slug dying AGAIN → SKIP_ALREADY, NO second spawn ───────────────────
: > "$HERDR_AGENT_LOG"; : > "$HERDR_NOTIFY_LOG"   # keep the ledger from (2)
v="$(DEAD_BUILDER_AUTORESPAWN=on HERD_NOW_EPOCH="$((NOW+9))" _maybe_autorespawn_dead_builder live-slug "$T/wt-live")"
[ "$v" = "SKIP_ALREADY" ]              || fail "(2b) a re-death after one respawn should verdict SKIP_ALREADY, got $v"
[ -s "$HERDR_AGENT_LOG" ]              && fail "(2b) SKIP_ALREADY must NOT start a second agent (no loop)"
grep -q "died again: live-slug" "$HERDR_NOTIFY_LOG" || fail "(2b) SKIP_ALREADY should escalate via notification"
ok

# ── (3) ON + dead WITH commits → SKIP_WORK (escalate, never blow away work) ────────────────────────
reset
mkrepo "$T/wt-work" commits; printf 'spec\n' > "$TREES/work-slug.task.md"
v="$(DEAD_BUILDER_AUTORESPAWN=on HERD_NOW_EPOCH="$NOW" _maybe_autorespawn_dead_builder work-slug "$T/wt-work")"
[ "$v" = "SKIP_WORK" ]                 || fail "(3) on+dead-with-commits should verdict SKIP_WORK, got $v"
[ -s "$HERDR_AGENT_LOG" ]              && fail "(3) SKIP_WORK must NOT respawn over committed work"
respawn_recorded work-slug            && fail "(3) SKIP_WORK must NOT spend the respawn budget"
grep -q "has work): work-slug" "$HERDR_NOTIFY_LOG" || fail "(3) SKIP_WORK should escalate via notification"
ok

# ── (3b) a dirty (uncommitted) tree is also work → SKIP_WORK, no respawn ───────────────────────────
reset
mkrepo "$T/wt-dirty2" dirty; printf 'spec\n' > "$TREES/dirty-slug.task.md"
v="$(DEAD_BUILDER_AUTORESPAWN=on HERD_NOW_EPOCH="$NOW" _maybe_autorespawn_dead_builder dirty-slug "$T/wt-dirty2")"
[ "$v" = "SKIP_WORK" ]                 || fail "(3b) on+dead-with-dirty-tree should verdict SKIP_WORK, got $v"
[ -s "$HERDR_AGENT_LOG" ]              && fail "(3b) SKIP_WORK must NOT respawn over uncommitted changes"
ok

# ── (4) ON + clean but the task spec is MISSING → respawn attempt fails → escalate, no budget spent ─
reset
mkrepo "$T/wt-nospec" clean   # NO $TREES/nospec-slug.task.md written
v="$(DEAD_BUILDER_AUTORESPAWN=on HERD_NOW_EPOCH="$NOW" _maybe_autorespawn_dead_builder nospec-slug "$T/wt-nospec" 2>/dev/null)"
[ "$v" = "RESPAWN" ]                   || fail "(4) verdict is still RESPAWN (the spawn ATTEMPT is what fails), got $v"
[ -s "$HERDR_AGENT_LOG" ]             && fail "(4) a missing spec must abort BEFORE any agent start"
respawn_recorded nospec-slug          && fail "(4) a failed respawn must NOT spend the at-most-once budget"
grep -q "auto-respawn failed: nospec-slug" "$HERDR_NOTIFY_LOG" || fail "(4) a failed respawn should escalate"
ok

# ── (5) DRYRUN: on + clean → logs intent but spawns nothing and spends no budget ───────────────────
reset
mkrepo "$T/wt-dry" clean; printf 'spec\n' > "$TREES/dry-slug.task.md"
v="$(DRYRUN=1 DEAD_BUILDER_AUTORESPAWN=on HERD_NOW_EPOCH="$NOW" _maybe_autorespawn_dead_builder dry-slug "$T/wt-dry" 2>/dev/null)"
[ "$v" = "RESPAWN" ]                   || fail "(5) dry-run still classifies RESPAWN, got $v"
[ -s "$HERDR_AGENT_LOG" ]             && fail "(5) DRYRUN must NOT start an agent"
respawn_recorded dry-slug             && fail "(5) DRYRUN must NOT write the ledger"
ok

echo "ALL PASS ($pass checks)"
