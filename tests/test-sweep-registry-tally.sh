#!/usr/bin/env bash
# test-sweep-registry-tally.sh — HERD-215: the two sweep-housekeeping defects (follow-ups to HERD-191).
#
# (1) REGISTRY LEAK. A tab closed OUTSIDE the sweep's own close+drop path (a crash, a herdr reload, a
#     manual `herdr tab close`) used to leave its $TREES/.herd-tabs row behind forever, and the cheap
#     stale-tab tally (worktree-absence only) counted that DEAD row as a live mess across restarts.
#     FIX: closing a tab drops its row in the SAME action, AND the detection pass prunes any row whose
#     tab_id no longer exists at all (self-consistent registry) — regardless of who closed it.
#
# (2) TALLY HONESTY. The housekeeping line recomputed only on the throttled ~60 s scan, so it kept
#     advertising a mess long after cleanup (cry-wolf). FIX: a finished sweep (auto OR a manual
#     `herd sweep` in another process) stamps a tally-invalidate file; the watcher recomputes the
#     instant it sees a fresh stamp, and between scans annotates a cached reading with its age.
#
# Fully hermetic: a temp git repo + one real worktree, stubbed gh/herdr (the live tab set is a file the
# subtests rewrite), a synthetic empty process table, headless driver, pinned clock. NO network/panes.
# Run:  bash tests/test-sweep-registry-tally.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASS=$((PASS+1)); }
[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── fixture: a real git repo + one live worktree ─────────────────────────────
export MAINDIR="$T/proj"; export TREESDIR="$T/proj-trees"
mkdir -p "$MAINDIR" "$TREESDIR"
git init -q -b main "$MAINDIR"
git -C "$MAINDIR" config user.email t@t.local; git -C "$MAINDIR" config user.name t
echo base > "$MAINDIR/f.txt"; git -C "$MAINDIR" add -A; git -C "$MAINDIR" commit -qm base
git -C "$MAINDIR" update-ref refs/remotes/origin/main HEAD
# 'live-slug' is the one live worktree — its tab (tabKEEP) must always survive.
git -C "$MAINDIR" worktree add -q -b feat/live-slug "$TREESDIR/live-slug" main >/dev/null 2>&1

# ── stubs ────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
# gh: no open PRs, so any registry slug lacking a worktree is a genuine orphan.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then printf '[]\n'; exit 0; fi
exit 0
EOF
# herdr: `tab list` echoes $HERDR_TABS_JSON (subtests rewrite it to vary the LIVE tab set) and honors an
# rc override (offline-blip simulation); `tab close` is logged; everything else is inert.
export HERDR_TABS_JSON="$T/tabs.json"; printf '{"result":{"tabs":[]}}\n' > "$HERDR_TABS_JSON"
export TAB_CLOSED="$T/tab-closed"; : > "$TAB_CLOSED"
export HERDR_RC="$T/herdr-rc"; printf '0' > "$HERDR_RC"
cat > "$BIN/herdr" <<'EOF'
#!/usr/bin/env bash
case "${1:-}/${2:-}" in
  workspace/list) printf '{"result":{"workspaces":[{"workspace_id":"ws1","label":"sweepws"}]}}\n' ;;
  tab/list)
    rc="$(cat "$HERDR_RC" 2>/dev/null || echo 0)"
    [ "$rc" = "0" ] || exit "$rc"
    cat "$HERDR_TABS_JSON" 2>/dev/null || printf '{"result":{"tabs":[]}}\n' ;;
  tab/close) printf '%s\n' "${3:-}" >> "$TAB_CLOSED" ;;
  agent/list) printf '{"result":{"agents":[]}}\n' ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$BIN/gh" "$BIN/herdr"
export PATH="$BIN:$PATH"
set_tabs(){ printf '%s\n' "$1" > "$HERDR_TABS_JSON"; }

# ── source the engine in lib mode ────────────────────────────────────────────
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless
export PROJECT_ROOT="$MAINDIR" WORKTREES_DIR="$TREESDIR" WORKSPACE_NAME=sweepws
export DEFAULT_BRANCH="origin/main"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
# Synthetic empty process table so sweep_orphan_procs never touches the real box.
printf '#!/usr/bin/env bash\nprintf ""\n' > "$T/ps-stub"; chmod +x "$T/ps-stub"
export HERD_SWEEP_PS_CMD="$T/ps-stub"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render(){ :; }
[ "$MAIN" = "$MAINDIR" ] || fail "MAIN did not bind to the fixture repo (got '$MAIN')"
[ "$TREES" = "$TREESDIR" ] || fail "TREES did not bind to the fixture worktrees dir (got '$TREES')"

# ── (1) loading ──────────────────────────────────────────────────────────────
for fn in _herd_tabs_prune_orphans _sweep_orphan_tabs _sweep_tally_invalidated _sweep_fmt_age \
          _sweep_stamp_tally sweep_leg_tabs sweep_cheap_tab_count build_sweep_note _sweep_trigger_tick; do
  type "$fn" >/dev/null 2>&1 || fail "(1) $fn not defined after sourcing"
done
ok; echo "PASS (1) HERD-215 helpers load via the AGENT_WATCH_LIB seam"

# ── (2) the registry prune helper ────────────────────────────────────────────
set_tabs '{"result":{"tabs":[{"tab_id":"tabKEEP","label":"live-slug","workspace_id":"ws1"}]}}'
cat > "$TREESDIR/.herd-tabs" <<'EOF'
live-slug tabKEEP builder
zombie tabZOMBIE builder
EOF
_herd_tabs_prune_orphans "$TREESDIR/.herd-tabs"
grep -q 'tabZOMBIE' "$TREESDIR/.herd-tabs" && fail "(2) a row whose tab no longer exists was not pruned"
grep -q 'tabKEEP'   "$TREESDIR/.herd-tabs" || fail "(2) a live tab's row was wrongly pruned"
grep -q '"event":"sweep_tab_prune"' "$JOURNAL_FILE" || fail "(2) the prune was not journaled"
grep -q 'tabZOMBIE' "$JOURNAL_FILE" || fail "(2) the pruned tab_id was not journaled"
# SAFETY: NO degenerate read may be taken as "every tab gone → wipe the registry". Each of the four
# failure shapes below must leave BOTH rows intact.
seed_two(){ cat > "$TREESDIR/.herd-tabs" <<'EOF'
live-slug tabKEEP builder
zombie tabZOMBIE builder
EOF
}
# (a) rc != 0 — herdr offline / rate-limited.
seed_two; printf '3' > "$HERDR_RC"
_herd_tabs_prune_orphans "$TREESDIR/.herd-tabs"
grep -q 'tabZOMBIE' "$TREESDIR/.herd-tabs" && grep -q 'tabKEEP' "$TREESDIR/.herd-tabs" || fail "(2) rc!=0 wrongly wiped the registry"
printf '0' > "$HERDR_RC"
# (b) rc 0 but BLANK stdout.
seed_two; : > "$HERDR_TABS_JSON"
_herd_tabs_prune_orphans "$TREESDIR/.herd-tabs"
grep -q 'tabZOMBIE' "$TREESDIR/.herd-tabs" && grep -q 'tabKEEP' "$TREESDIR/.herd-tabs" || fail "(2) a blank rc-0 read wiped the registry"
# (c) rc 0, valid JSON, but ZERO tabs — the ambiguous case (empty room vs blip) → refuse.
seed_two; set_tabs '{"result":{"tabs":[]}}'
_herd_tabs_prune_orphans "$TREESDIR/.herd-tabs"
grep -q 'tabZOMBIE' "$TREESDIR/.herd-tabs" && grep -q 'tabKEEP' "$TREESDIR/.herd-tabs" || fail "(2) a zero-tabs read wiped the registry"
# (d) rc 0 but UNPARSEABLE garbage.
seed_two; set_tabs 'not json at all'
_herd_tabs_prune_orphans "$TREESDIR/.herd-tabs"
grep -q 'tabZOMBIE' "$TREESDIR/.herd-tabs" && grep -q 'tabKEEP' "$TREESDIR/.herd-tabs" || fail "(2) an unparseable rc-0 read wiped the registry"
ok; echo "PASS (2) prune drops dead-tab rows, spares live rows, journals; every degenerate read is a safe no-op"

# ── (3) closing a tab drops its row in the SAME action ───────────────────────
# 'ghost' has a LIVE (open) tab but no worktree and no PR → a genuine orphan → closed + row dropped.
set_tabs '{"result":{"tabs":[{"tab_id":"tabKEEP","label":"live-slug","workspace_id":"ws1"},{"tab_id":"tabGHOST","label":"ghost","workspace_id":"ws1"}]}}'
cat > "$TREESDIR/.herd-tabs" <<'EOF'
live-slug tabKEEP builder
ghost tabGHOST builder
EOF
: > "$TAB_CLOSED"
_sweep_orphan_tabs
grep -q 'tabGHOST' "$TAB_CLOSED"               || fail "(3) the genuine orphan tab was not closed"
grep -q 'ghost tabGHOST' "$TREESDIR/.herd-tabs" && fail "(3) the closed tab's row was not dropped in the same action"
grep -q 'tabKEEP' "$TREESDIR/.herd-tabs"       || fail "(3) the live row was wrongly removed"
ok; echo "PASS (3) closing an orphan tab removes its registry row atomically"

# ── (4) the detection pass prunes orphan rows + the tally reads 0 same-tick ───
# Registry: one live row, one genuine orphan (live tab, dead slug), two DEAD rows (tab gone entirely).
set_tabs '{"result":{"tabs":[{"tab_id":"tabKEEP","label":"live-slug","workspace_id":"ws1"},{"tab_id":"tabGHOST2","label":"ghost2","workspace_id":"ws1"}]}}'
cat > "$TREESDIR/.herd-tabs" <<'EOF'
live-slug tabKEEP builder
ghost2 tabGHOST2 builder
deadrow1 tabDEAD1 builder
deadrow2 tabDEAD2 builder
EOF
BEFORE="$(sweep_cheap_tab_count)"   # ghost2 + deadrow1 + deadrow2 (live-slug has a worktree) = 3
[ "$BEFORE" = "3" ] || fail "(4) expected the cheap tally to over-count 3 dead/orphan rows, got '$BEFORE'"
: > "$TAB_CLOSED"
sweep_leg_tabs "" >/dev/null
grep -q 'tabDEAD1' "$TAB_CLOSED"        && fail "(4) a nonexistent tab was 'closed' (should only be pruned)"
grep -Eq 'tabDEAD1|tabDEAD2' "$TREESDIR/.herd-tabs" && fail "(4) the dead rows were not pruned by detection"
grep -q 'tabGHOST2' "$TAB_CLOSED"       || fail "(4) the genuine orphan tab was not closed"
AFTER="$(sweep_cheap_tab_count)"
[ "$AFTER" = "0" ] || fail "(4) the tally did not read 0 same-tick after the sweep, got '$AFTER'"
ok; echo "PASS (4) detection prunes orphan rows; the stale-tab tally clears to 0 without a manual prune"

# ── (5) tally invalidation stamp + dry-run inertness ─────────────────────────
rm -f "$TREESDIR/.sweep-tally-stamp"
export HERD_FAKE_NOW=500
_SWEEP_LAST_SCAN=100
_sweep_stamp_tally
[ -f "$TREESDIR/.sweep-tally-stamp" ] || fail "(5) the tally stamp was not written"
[ "$(cat "$TREESDIR/.sweep-tally-stamp")" = "500" ] || fail "(5) the stamp value is wrong"
_sweep_tally_invalidated || fail "(5) a stamp newer than the last scan must invalidate"
_SWEEP_LAST_SCAN=600
_sweep_tally_invalidated && fail "(5) a stamp older than the last scan must NOT invalidate"
unset HERD_FAKE_NOW
# A manual sweep stamps; a --dry-run (touched nothing) must not.
rm -f "$TREESDIR/.sweep-tally-stamp"
( cd "$T" && sweep_main --dry-run >/dev/null 2>&1 ) || fail "(5) dry-run exited non-zero"
[ -f "$TREESDIR/.sweep-tally-stamp" ] && fail "(5) --dry-run must not stamp the tally"
( cd "$T" && sweep_main --no-restart >/dev/null 2>&1 ) || fail "(5) live sweep exited non-zero"
[ -f "$TREESDIR/.sweep-tally-stamp" ] || fail "(5) a live sweep must stamp the tally"
ok; echo "PASS (5) a live sweep stamps the tally-invalidate file; --dry-run stays inert"

# ── (6) the watcher recomputes same-tick on invalidation (no cadence wait) ───
export SWEEP_AUTO=advise
cat > "$TREESDIR/.herd-tabs" <<'EOF'
live-slug tabKEEP builder
EOF
# A cached mess from a prior scan, and the scan tick nowhere near the cadence.
_SWEEP_C_TABS=3; _SWEEP_C_MARKERS=0; _SWEEP_C_PROCS=0
_SWEEP_LAST_SCAN=100; _SWEEP_SCAN_TICK=0
printf '300\n' > "$TREESDIR/.sweep-tally-stamp"   # a finished sweep, newer than the last scan
export HERD_FAKE_NOW=400
_sweep_trigger_tick
[ "$_SWEEP_C_TABS" = "0" ] || fail "(6) the tally was not recomputed same-tick on invalidation, got '$_SWEEP_C_TABS'"
build_sweep_note
[ -z "$SWEEP_NOTE" ] || fail "(6) the housekeeping line did not clear after cleanup"
unset HERD_FAKE_NOW SWEEP_AUTO
ok; echo "PASS (6) an invalidation stamp forces an immediate recompute; the cry-wolf line clears"

# ── (7) the staleness age note ───────────────────────────────────────────────
[ "$(_sweep_fmt_age 45)"   = "45s" ] || fail "(7) fmt 45s"
[ "$(_sweep_fmt_age 240)"  = "4m"  ] || fail "(7) fmt 4m"
[ "$(_sweep_fmt_age 7200)" = "2h"  ] || fail "(7) fmt 2h"
export SWEEP_AUTO=advise
_SWEEP_C_TABS=1; _SWEEP_C_MARKERS=0; _SWEEP_C_PROCS=0
_SWEEP_LAST_SCAN=1000; export HERD_FAKE_NOW=1240   # reading is 240 s = 4m old
build_sweep_note
case "$SWEEP_NOTE" in *"as of 4m ago"*) : ;; *) fail "(7) a cached reading must carry its age: '$SWEEP_NOTE'" ;; esac
_SWEEP_LAST_SCAN=1240   # scanned THIS tick → age 0 → no caveat
build_sweep_note
case "$SWEEP_NOTE" in *"as of"*) fail "(7) a this-tick-fresh reading must carry no staleness caveat" ;; *) : ;; esac
unset HERD_FAKE_NOW SWEEP_AUTO
ok; echo "PASS (7) a cached tally renders 'as of Nm ago'; a fresh one does not"

echo
echo "ALL PASS ($PASS checks)"
