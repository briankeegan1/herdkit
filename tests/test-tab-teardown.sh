#!/usr/bin/env bash
# test-tab-teardown.sh — hermetic tests for tab teardown:
#   Part A: herd_teardown_slug (herd-config.sh)
#     1. Closes builder, review·, and resolve· tabs for the slug
#     2. Does NOT close tabs for other slugs
#     3. Workspace scoping — tabs in a different workspace are not closed
#     4. Gracefully handles an empty tab list
#     5. Retry + loud warning when a tab survives the first close attempt
#   Part B: _sweep_orphan_tabs (agent-watch.sh)
#     6. Closes orphaned review· and resolve· tabs (no live worktree, no open PR)
#     7. Preserves tabs for live slugs (worktree exists)
#     8. Preserves tabs for slugs with open PRs
#     9. Does NOT close the coordinator tab
#    10. Closes orphaned bare builder tabs
#    11. Skips entirely in dry-run mode
#
# Stubs herdr/gh/git (NETWORK-FREE). Run:  bash tests/test-tab-teardown.sh
# No `set -e`: some checks assert non-zero returns explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$HERE/../scripts/herd/herd-config.sh"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Shared stub wiring ────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
CLOSE_LOG="$T/close.log"         # one tab_id per line, in order of close calls
LIST_RESP="$T/list.json"         # current tab list JSON; updated by close stub
CLOSE_FAIL="$T/close-fail.txt"   # tab IDs that survive close (simulate flaky close)
WT_OUTPUT="$T/wt-output.txt"     # git worktree list --porcelain output for sweep tests
PR_OUTPUT="$T/pr-output.json"    # gh pr list --json headRefName output for sweep tests
export CLOSE_LOG LIST_RESP CLOSE_FAIL WT_OUTPUT PR_OUTPUT

# herdr stub
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wA","label":"%s"}]}}\n' \
      "${WORKSPACE_NAME:-herdkit}"
    ;;
  "tab list")
    cat "${LIST_RESP:?LIST_RESP unset}" 2>/dev/null \
      || printf '{"result":{"tabs":[]}}\n'
    ;;
  "tab close")
    tid="$3"
    printf '%s\n' "$tid" >> "${CLOSE_LOG:?CLOSE_LOG unset}"
    # If this tab is in the fail list, leave it in the tab list (simulate sticky tab).
    if grep -qx "$tid" "${CLOSE_FAIL:-/dev/null}" 2>/dev/null; then
      :  # do NOT remove from list
    else
      python3 -c "
import json, sys
with open('${LIST_RESP}') as fh: d = json.load(fh)
d['result']['tabs'] = [t for t in d.get('result',{}).get('tabs',[]) if t.get('tab_id') != '${tid}']
print(json.dumps(d))
" > "${LIST_RESP}.tmp" 2>/dev/null && mv "${LIST_RESP}.tmp" "${LIST_RESP}" || true
    fi
    ;;
  *) ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"

# gh stub — returns PR list from $PR_OUTPUT
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") cat "${PR_OUTPUT:-/dev/null}" 2>/dev/null || printf '[]\n' ;;
  *) exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"

# git stub — returns worktree list from $WT_OUTPUT
cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q 'porcelain'; then
  cat "${WT_OUTPUT:-/dev/null}" 2>/dev/null || true
fi
exit 0
STUB
chmod +x "$BIN/git"

export PATH="$BIN:$PATH"

# helper: write tab-list JSON from "id:label:wsid" triples
write_tabs() {
  python3 -c "
import json, sys
tabs = []
for s in sys.argv[1:]:
    parts = s.split(':')
    tabs.append({'tab_id': parts[0], 'label': parts[1],
                 'workspace_id': parts[2] if len(parts) > 2 else 'wA'})
print(json.dumps({'result': {'tabs': tabs}}))
" "$@" > "$LIST_RESP"
}
# helper: reset both log and fail list
clear_state() { : > "$CLOSE_LOG"; : > "$CLOSE_FAIL"; }

# ── Source herd-config.sh (defines herd_teardown_slug) ───────────────────────
export HERD_CONFIG_FILE="$T/no-config"
export WORKSPACE_NAME="herdkit"
# shellcheck source=/dev/null
. "$CONFIG" || fail "sourcing herd-config.sh failed"
type herd_teardown_slug >/dev/null 2>&1 || fail "herd_teardown_slug not defined"
ok

# ── 1. Teardown closes builder, review·, and resolve· tabs for the slug ──────
write_tabs "t1:my-slug:wA" "t2:review·my-slug:wA" "t3:resolve·my-slug:wA" "t4:other-slug:wA"
clear_state
herd_teardown_slug "my-slug"
grep -qx "t1" "$CLOSE_LOG" || fail "1: builder tab t1 not closed"
ok
grep -qx "t2" "$CLOSE_LOG" || fail "1: review tab t2 not closed"
ok
grep -qx "t3" "$CLOSE_LOG" || fail "1: resolve tab t3 not closed"
ok
! grep -qx "t4" "$CLOSE_LOG" || fail "1: other-slug tab t4 should NOT be closed"
ok

# ── 2. Teardown does NOT close tabs for other slugs ──────────────────────────
write_tabs "tA:alpha:wA" "tB:review·alpha:wA" "tC:beta:wA"
clear_state
herd_teardown_slug "alpha"
grep -qx "tA" "$CLOSE_LOG" || fail "2: alpha builder tab should be closed"
ok
grep -qx "tB" "$CLOSE_LOG" || fail "2: review·alpha tab should be closed"
ok
! grep -qx "tC" "$CLOSE_LOG" || fail "2: beta tab should NOT be closed"
ok

# ── 3. Workspace scoping — tabs in a different workspace are not closed ───────
write_tabs "x1:my-slug:wA" "x2:my-slug:wB" "x3:review·my-slug:wB"
clear_state
herd_teardown_slug "my-slug"
grep -qx "x1" "$CLOSE_LOG" || fail "3: tab in wA (our workspace) should be closed"
ok
! grep -qx "x2" "$CLOSE_LOG" || fail "3: builder tab in wB (other workspace) should NOT be closed"
ok
! grep -qx "x3" "$CLOSE_LOG" || fail "3: review tab in wB (other workspace) should NOT be closed"
ok

# ── 4. Gracefully handles empty tab list ─────────────────────────────────────
printf '{"result":{"tabs":[]}}\n' > "$LIST_RESP"
clear_state
herd_teardown_slug "any-slug"   # must not crash
ok

# ── 5. Retry + loud warning when a tab survives the first close attempt ───────
write_tabs "sticky:my-slug:wA"
clear_state
printf 'sticky\n' > "$CLOSE_FAIL"   # this tab will survive close
warn="$(herd_teardown_slug "my-slug" 2>&1)"
# Two close attempts should be logged.
count="$(grep -c '^sticky$' "$CLOSE_LOG")"
[ "$count" -ge 2 ] || fail "5: expected at least 2 close attempts for sticky tab (got $count)"
ok
# Warning must mention the tab id and the slug.
printf '%s' "$warn" | grep -q "sticky" || fail "5: warning should mention tab id 'sticky'"
ok
printf '%s' "$warn" | grep -q "my-slug" || fail "5: warning should mention slug 'my-slug'"
ok

# ── Source agent-watch.sh in lib mode (defines _sweep_orphan_tabs) ───────────
: > "$CLOSE_FAIL"   # reset fail list
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export MAIN="$T/main"; mkdir -p "$T/main"
export DRYRUN=""
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
type _sweep_orphan_tabs >/dev/null 2>&1 || fail "_sweep_orphan_tabs not defined"
ok

# ── 6. Orphan sweep closes orphaned review· and resolve· tabs ────────────────
write_tabs "r1:review·gone-slug:wA" "r2:resolve·gone-slug:wA"
printf '' > "$WT_OUTPUT"   # no live worktrees
printf '[]\n' > "$PR_OUTPUT"   # no open PRs
clear_state
_sweep_orphan_tabs
grep -qx "r1" "$CLOSE_LOG" || fail "6: orphaned review·gone-slug tab r1 should be closed"
ok
grep -qx "r2" "$CLOSE_LOG" || fail "6: orphaned resolve·gone-slug tab r2 should be closed"
ok

# ── 7. Orphan sweep preserves tabs for live slugs (worktree exists) ──────────
LIVE_DIR="$T/trees/live-feat"
printf 'worktree %s\nbranch refs/heads/feat/live-feat\n\nworktree %s\nbranch refs/heads/main\n\n' \
  "$LIVE_DIR" "$MAIN" > "$WT_OUTPUT"
write_tabs "p1:review·live-feat:wA" "p2:live-feat:wA"
printf '[]\n' > "$PR_OUTPUT"
clear_state
_sweep_orphan_tabs
! grep -qx "p1" "$CLOSE_LOG" || fail "7: review·live-feat should NOT be closed (worktree exists)"
ok
! grep -qx "p2" "$CLOSE_LOG" || fail "7: live-feat builder tab should NOT be closed (worktree exists)"
ok

# ── 8. Orphan sweep preserves tabs for slugs with open PRs ───────────────────
printf '' > "$WT_OUTPUT"   # no worktrees
printf '[{"headRefName":"feat/pr-slug"}]\n' > "$PR_OUTPUT"
write_tabs "q1:review·pr-slug:wA" "q2:pr-slug:wA"
clear_state
_sweep_orphan_tabs
! grep -qx "q1" "$CLOSE_LOG" || fail "8: review·pr-slug should NOT be closed (open PR exists)"
ok
! grep -qx "q2" "$CLOSE_LOG" || fail "8: pr-slug builder tab should NOT be closed (open PR exists)"
ok

# ── 9. Orphan sweep does NOT close the coordinator tab ───────────────────────
write_tabs "c1:coordinator-herdkit:wA"
printf '' > "$WT_OUTPUT"
printf '[]\n' > "$PR_OUTPUT"
clear_state
_sweep_orphan_tabs
! grep -qx "c1" "$CLOSE_LOG" || fail "9: coordinator tab should NOT be closed by orphan sweep"
ok

# ── 10. Orphan sweep closes orphaned bare builder tabs ───────────────────────
write_tabs "b1:old-feat:wA"
printf '' > "$WT_OUTPUT"
printf '[]\n' > "$PR_OUTPUT"
clear_state
_sweep_orphan_tabs
grep -qx "b1" "$CLOSE_LOG" || fail "10: orphaned builder tab old-feat should be closed"
ok

# ── 11. Orphan sweep skips entirely in dry-run mode ──────────────────────────
write_tabs "d1:review·orphan:wA" "d2:orphan:wA"
printf '' > "$WT_OUTPUT"; printf '[]\n' > "$PR_OUTPUT"
clear_state
DRYRUN=1 _sweep_orphan_tabs
[ ! -s "$CLOSE_LOG" ] || fail "11: orphan sweep should make no closes in dry-run mode"
ok

echo "ALL PASS ($pass checks)"
