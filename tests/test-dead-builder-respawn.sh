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
#   agent start <slug> …         → append the whole invocation to $HERDR_AGENT_LOG (proof of respawn);
#                                  exits NON-ZERO when HERDR_AGENT_START_FAIL is set (simulates the
#                                  residual agent_name_taken race the HERD-136 cleanup path guards).
#   tab close <id>               → append <id> to $HERDR_TAB_CLOSE_LOG (proof the corpse tab is reaped)
#   agent list / tab list        → the CORPSE WORLD, read from $HERDR_AGENTS_JSON / $HERDR_TABS_JSON
#                                  (empty rosters when unset — the pre-HERD-162 shape every earlier
#                                  case below runs under, so those cases stay byte-identical).
#   pane close <id>              → retire every agent row whose pane_id is <id>. Under real herdr the
#                                  agent registration lives and dies with its pane (claude is the
#                                  pane's ROOT process), so this is the stub's whole point: it is what
#                                  makes the name become FREE and proves the reap did the freeing.
# Every invocation is appended to $HERDR_ACTION_LOG, in order — the ORDERING assertions (corpse reaped
# BEFORE the new tab is created) read that log and nothing else.
printf '%s\n' "$*" >> "${HERDR_ACTION_LOG:-/dev/null}"
case "${1:-}/${2:-}" in
  notification/show) printf '%s\n' "${3:-}" >> "${HERDR_NOTIFY_LOG:?HERDR_NOTIFY_LOG unset}" ;;
  workspace/list)    printf '%s\n' '{"result":{"workspaces":[]}}' ;;
  tab/create)        printf '%s\n' '{"result":{"tab":{"tab_id":"tab-fake"},"root_pane":{"pane_id":"pane-fake"}}}' ;;
  tab/close)         printf '%s\n' "${3:-}" >> "${HERDR_TAB_CLOSE_LOG:-/dev/null}"
                     [ -n "${HERDR_TABS_JSON:-}" ] && TAB="${3:-}" python3 -c '
import json, os
p = os.environ["HERDR_TABS_JSON"]; tid = os.environ["TAB"]
d = json.load(open(p))
d["result"]["tabs"] = [t for t in d["result"]["tabs"] if t["tab_id"] != tid]
json.dump(d, open(p, "w"))' 2>/dev/null ;;
  pane/close)        printf '%s\n' "${3:-}" >> "${HERDR_PANE_CLOSE_LOG:-/dev/null}"
                     [ -n "${HERDR_AGENTS_JSON:-}" ] && PANE="${3:-}" python3 -c '
import json, os
p = os.environ["HERDR_AGENTS_JSON"]; pid = os.environ["PANE"]
d = json.load(open(p))
d["result"]["agents"] = [a for a in d["result"]["agents"] if a.get("pane_id") != pid]
json.dump(d, open(p, "w"))' 2>/dev/null ;;
  agent/list)        if [ -n "${HERDR_AGENTS_JSON:-}" ]; then cat "$HERDR_AGENTS_JSON"
                     else printf '%s\n' '{"result":{"agents":[]}}'; fi ;;
  tab/list)          if [ -n "${HERDR_TABS_JSON:-}" ]; then cat "$HERDR_TABS_JSON"
                     else printf '%s\n' '{"result":{"tabs":[]}}'; fi ;;
  agent/start)       printf '%s\n' "$*" >> "${HERDR_AGENT_LOG:?HERDR_AGENT_LOG unset}"
                     [ -n "${HERDR_AGENT_START_FAIL:-}" ] && exit 1 ;;
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
          record_respawn _respawn_builder_in_worktree _maybe_autorespawn_dead_builder \
          _reap_builder_corpse _slug_builder_tab_ids; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

# Redirect every stateful path at the temp dir (plain globals; safe to reassign post-source).
TREES="$T/trees"; mkdir -p "$TREES"
DEAD_STATE="$T/.agent-watch-dead"
DEAD_RESPAWN_STATE="$T/.agent-watch-respawn"
LIMIT_STATE="$T/.agent-watch-limit"
SENDKEYS_STATE="$T/.agent-watch-limit-sendkeys"
DEFAULT_BRANCH="main"                    # local base ref (no origin/ in this hermetic repo)
export HERDR_NOTIFY_LOG="$T/notify.log"; : > "$HERDR_NOTIFY_LOG"
export HERDR_AGENT_LOG="$T/agent.log";   : > "$HERDR_AGENT_LOG"
export HERDR_TAB_CLOSE_LOG="$T/tabclose.log"; : > "$HERDR_TAB_CLOSE_LOG"
export HERDR_PANE_CLOSE_LOG="$T/paneclose.log"; : > "$HERDR_PANE_CLOSE_LOG"
export HERDR_ACTION_LOG="$T/actions.log"; : > "$HERDR_ACTION_LOG"
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
reset() { : > "$HERDR_NOTIFY_LOG"; : > "$HERDR_AGENT_LOG"; : > "$DEAD_RESPAWN_STATE"; : > "$HERDR_TAB_CLOSE_LOG"
          : > "$HERDR_PANE_CLOSE_LOG"; : > "$HERDR_ACTION_LOG"; : > "$JOURNAL_FILE"
          : > "$LIMIT_STATE"; : > "$SENDKEYS_STATE"
          unset HERDR_AGENTS_JSON HERDR_TABS_JSON; }

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

# ── (6) HERD-136: ON + clean but agent start FAILS after the tab was created (a residual
#        agent_name_taken race) → the just-created tab MUST be closed (no corpse-tab shrapnel like the
#        observed wE:tMP/tMQ), the reap MUST be journaled, and the at-most-once budget is NOT spent. ──
reset
mkrepo "$T/wt-taken" clean; printf 'spec\n' > "$TREES/taken-slug.task.md"
v="$(HERDR_AGENT_START_FAIL=1 DEAD_BUILDER_AUTORESPAWN=on HERD_NOW_EPOCH="$NOW" _maybe_autorespawn_dead_builder taken-slug "$T/wt-taken" 2>/dev/null)"
[ "$v" = "RESPAWN" ]                                    || fail "(6) verdict is still RESPAWN (the spawn ATTEMPT is what fails), got $v"
grep -q "agent start taken-slug" "$HERDR_AGENT_LOG"    || fail "(6) the respawn must have ATTEMPTED an agent start"
grep -q "tab-fake" "$HERDR_TAB_CLOSE_LOG"              || fail "(6) a failed agent start MUST close the just-created tab (no corpse tab)"
grep -q "builder_respawn_tab_reaped" "$JOURNAL_FILE"  || fail "(6) the corpse-tab cleanup must be journaled"
respawn_recorded taken-slug                            && fail "(6) a failed respawn must NOT spend the at-most-once budget"
grep -q "auto-respawn failed: taken-slug" "$HERDR_NOTIFY_LOG" || fail "(6) a failed respawn should still escalate"
ok

# ════════════════════════════════════════════════════════════════════════════════════════════════
# HERD-162 F6 — CORPSE CLEANUP IS STEP 0 OF EVERY RESPAWN.
#
# The bug: _respawn_builder_in_worktree created the NEW tab first and only then ran `agent start
# <slug>`, which fails agent_name_taken because the DEAD builder's agent row (and the pane holding it)
# is still registered. That is the HERD-114 crash the whole feature exists FOR — a herdr crash leaves
# an agent LISTED with a dead process — so the respawn structurally failed in exactly the case it was
# written to handle, and left the new tab as shrapnel. The corpse must be reaped BEFORE anything else.

# corpse_world <slug> — a herdr world holding the dead builder's registry row and its builder tab,
# plus a LIVE NEIGHBOUR agent sharing the tab, and a sibling slug's tab that must never be touched.
corpse_world() {
  local slug="$1"
  export HERDR_AGENTS_JSON="$T/agents.json" HERDR_TABS_JSON="$T/tabs.json"
  cat > "$HERDR_AGENTS_JSON" <<EOF
{"result":{"agents":[
  {"name":"$slug","pane_id":"pane-corpse","agent_status":"idle"},
  {"name":"$slug-sibling","pane_id":"pane-sibling","agent_status":"working"}]}}
EOF
  cat > "$HERDR_TABS_JSON" <<EOF
{"result":{"tabs":[
  {"tab_id":"tab-corpse","label":"$slug","workspace_id":""},
  {"tab_id":"tab-review","label":"review·$slug","workspace_id":""},
  {"tab_id":"tab-sibling","label":"$slug-sibling","workspace_id":""}]}}
EOF
  printf '%s tab-corpse builder\nreview·%s tab-review review\n%s-sibling tab-sibling builder\n' \
    "$slug" "$slug" "$slug" > "$TREES/.herd-tabs"
}

# ── (7) a corpse is retired BEFORE the new tab is created, and the respawn then SUCCEEDS ───────────
reset
corpse_world corpse-slug
mkrepo "$T/wt-corpse" clean; printf 'spec\n' > "$TREES/corpse-slug.task.md"
# Stale slug-keyed markers a reincarnated agent must not inherit (a limit target would schedule a
# `claude --continue` INTO the fresh builder at the old reset time).
record_limit    corpse-slug 900 999999 scheduled
record_sendkeys corpse-slug 900 cleared
v="$(DEAD_BUILDER_AUTORESPAWN=on HERD_NOW_EPOCH="$NOW" _maybe_autorespawn_dead_builder corpse-slug "$T/wt-corpse")"
[ "$v" = "RESPAWN" ]                                     || fail "(7) on+clean+corpse should verdict RESPAWN, got $v"
grep -q "agent start corpse-slug" "$HERDR_AGENT_LOG"     || fail "(7) the respawn must start a fresh agent once the name is free"
respawn_recorded corpse-slug                             || fail "(7) a SUCCESSFUL respawn spends the at-most-once budget"

# ORDERING is the whole fix: the corpse's pane and tab close BEFORE `tab create` ever runs.
create_at="$(grep -n '^tab create' "$HERDR_ACTION_LOG" | head -1 | cut -d: -f1)"
pane_at="$(grep -n '^pane close pane-corpse' "$HERDR_ACTION_LOG" | head -1 | cut -d: -f1)"
tab_at="$(grep -n '^tab close tab-corpse' "$HERDR_ACTION_LOG" | head -1 | cut -d: -f1)"
[ -n "$create_at" ] && [ -n "$pane_at" ] && [ -n "$tab_at" ] \
  || fail "(7) expected pane close + tab close + tab create in the action log; got:$(printf '\n%s' "$(cat "$HERDR_ACTION_LOG")")"
[ "$pane_at" -lt "$create_at" ] || fail "(7) the corpse PANE was closed AFTER the new tab was created (the HERD-114 bug)"
[ "$tab_at"  -lt "$create_at" ] || fail "(7) the corpse TAB was closed AFTER the new tab was created (the HERD-114 bug)"
ok

grep -q "builder_corpse_reaped" "$JOURNAL_FILE"          || fail "(7) the corpse reap must be journaled"
grep -q "builder_respawn_tab_reaped" "$JOURNAL_FILE"     && fail "(7) a clean respawn must NOT need the HERD-136 shrapnel cleanup"
ok

# The corpse's tab-registry row is pruned; the SIBLING's row and tab survive untouched.
grep -q "^corpse-slug tab-corpse" "$TREES/.herd-tabs"    && fail "(7) the corpse's .herd-tabs row survived the reap"
grep -q "^corpse-slug-sibling tab-sibling" "$TREES/.herd-tabs" || fail "(7) the reap pruned a live sibling's registry row"
grep -q "tab-sibling" "$HERDR_TAB_CLOSE_LOG"             && fail "(7) the reap closed a live sibling's tab"
grep -q "pane-sibling" "$HERDR_PANE_CLOSE_LOG"           && fail "(7) the reap closed a live sibling's pane"
ok

# The review· tab is a PR gate's, not a pre-PR builder's corpse — a respawn must never close it.
grep -q "tab-review" "$HERDR_TAB_CLOSE_LOG"              && fail "(7) the corpse reap closed the review tab"
ok

# The poisonous slug-keyed markers are gone; the dead anchor + respawn budget (the caller's own
# decision state) are deliberately left for _reconcile_dead_builder / the reap to own.
[ -z "$(limit_state corpse-slug)" ]                      || fail "(7) a stale limit target survived — would inject --continue into the fresh builder"
[ -z "$(sendkeys_state corpse-slug)" ]                   || fail "(7) a stale sendkeys row survived the corpse reap"
grep -q '"reaped":"pane,tab,limit"' "$JOURNAL_FILE"      || fail "(7) the corpse-reap event should name what it reaped: $(grep builder_corpse_reaped "$JOURNAL_FILE")"
ok

# ── (8) a corpse that CANNOT be retired blocks the respawn BEFORE a tab is created ─────────────────
# A herdr that lists an agent with NO pane (a crashed server) leaves nothing to close, so the name
# stays held. The old code created a tab, hit agent_name_taken, and closed it again. Now the respawn
# refuses up front — same escalation, zero shrapnel.
reset
export HERDR_AGENTS_JSON="$T/agents2.json"
printf '%s\n' '{"result":{"agents":[{"name":"held-slug","pane_id":"","agent_status":"idle"}]}}' > "$HERDR_AGENTS_JSON"
mkrepo "$T/wt-held" clean; printf 'spec\n' > "$TREES/held-slug.task.md"
v="$(DEAD_BUILDER_AUTORESPAWN=on HERD_NOW_EPOCH="$NOW" _maybe_autorespawn_dead_builder held-slug "$T/wt-held" 2>/dev/null)"
[ "$v" = "RESPAWN" ]                                     || fail "(8) verdict is still RESPAWN (the spawn ATTEMPT is what is blocked), got $v"
grep -q "^tab create" "$HERDR_ACTION_LOG"                && fail "(8) a held agent name must block the respawn BEFORE any tab is created"
[ -s "$HERDR_AGENT_LOG" ]                                && fail "(8) a held agent name must not even attempt agent start"
grep -q "builder_respawn_blocked" "$JOURNAL_FILE"        || fail "(8) the blocked respawn must be journaled"
respawn_recorded held-slug                               && fail "(8) a blocked respawn must NOT spend the at-most-once budget"
grep -q "auto-respawn failed: held-slug" "$HERDR_NOTIFY_LOG" || fail "(8) a blocked respawn must still escalate"
ok

# ── (9) the corpse reap is idempotent, and byte-inert under headless ───────────────────────────────
reset
corpse_world idem-slug
_reap_builder_corpse idem-slug "$T/wt-corpse" || fail "(9) the first corpse reap should leave the name free"
_reap_builder_corpse idem-slug "$T/wt-corpse" || fail "(9) a second reap over an already-clean world must succeed"
[ "$(grep -c '^pane close pane-corpse' "$HERDR_ACTION_LOG")" = "1" ] \
  || fail "(9) the second reap re-closed an already-closed pane"
ok

reset
corpse_world headless-slug
HERD_DRIVER=headless _reap_builder_corpse headless-slug "$T/wt-corpse" || fail "(9) headless corpse reap must succeed"
[ -s "$HERDR_ACTION_LOG" ] && fail "(9) headless has no panes/tabs — the corpse reap must touch herdr not at all"
ok

echo "ALL PASS ($pass checks)"
