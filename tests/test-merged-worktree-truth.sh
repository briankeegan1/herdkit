#!/usr/bin/env bash
# test-merged-worktree-truth.sh — hermetic proof for HERD-646 (mirrors GH #756, emberglen-godot).
#
# THE INCIDENT: a worktree whose PR had MERGED — clean tree, 0 commits ahead of the merged head, but 1
# commit BEHIND its remote (a commit landed on the branch's remote-tracking ref after this tree's own
# last push, e.g. a CI-unstick retry) — rendered a 💀 "died · re-spawn" row, and `herd sweep` skipped
# reaping it (swept:0). Both symptoms trace to the SAME bug: the sha anchor both retirement.sh and
# sweep.sh use to prove "this worktree's HEAD is exactly what GitHub merged" required byte-EQUALITY
# with the PR's headRefOid — a worktree merely BEHIND its remote (missing a commit that exists
# elsewhere, never local-only work) failed that equality and fell all the way back to "active", where
# agent-watch.sh's PR-less dead-builder classifier mistook it for a genuinely abandoned builder and
# recommended re-spawn — dangerous advice that would duplicate already-shipped work.
#
# TWO LEGS, proven independently:
#
#   LEG 2 — REAPER (retirement.sh / sweep.sh): the anchor now holds when a worktree's HEAD is the PR's
#     headRefOid *or a strict ancestor of it* (_sweep_anchor_ok, scripts/herd/sweep.sh). BEHIND is
#     provably safe (every commit here already exists on the remote); AHEAD or DIVERGED is refused
#     exactly as before — never a new way to license a teardown.
#     (B1) 1 commit BEHIND a merged PR's headRefOid → retire_classify: retiring
#     (B2) 2 commits BEHIND (N-behind, not just 1)  → retire_classify: retiring
#     (B3) 1 commit AHEAD of a merged PR's headRefOid (real, valid ancestor — not a bogus sha) →
#          retire_classify: active, UNCHANGED (refused; the ahead case is evidence-preserving)
#     (B4) sweep_leg_worktrees ACTUALLY REAPS the behind fixtures (dir gone, journaled reason=merged)
#     (B5) sweep_leg_worktrees leaves the ahead fixture untouched (no anchor ⇒ never touched)
#
#   LEG 1 — ROW TRUTH (agent-watch.sh's dead-builder classification): _reconcile_dead_builder resolves
#     _retire_state_of BEFORE ever classifying ALIVE/PENDING/DEAD. A slug retirement has already proven
#     non-active (retiring/held/deferred/stuck) is retirement's to reap, never re-spawned over.
#     (L1) a genuinely dead, non-retirement-owned builder still classifies DEAD and still notifies
#          "re-spawn" (control: the real detector is not disabled by this leg)
#     (L2) the SAME dead signature (no agent, no PR, past grace) on a slug retirement has already
#          classified 'retiring' NEVER classifies DEAD, NEVER notifies "re-spawn", and NEVER starts a
#          dead-first-seen anchor
#     (L3) the calm row rendered from that verdict says 'retiring…', never 're-spawn'
#
# Fully hermetic: a real git repo + real worktrees (the ancestor proof is git's own), gh/herdr stubbed
# on PATH, headless notification sink. NO network. Run:  bash tests/test-merged-worktree-truth.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
[ -f "$WATCH" ] || { echo "FAIL: agent-watch.sh not found at $WATCH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# Hermeticity guard (HERD-597 lesson, see test-retirement-invariant.sh): pin the journal BEFORE
# anything below can reach it, so a bare run never lands fixture-slug events in the live project journal.
export JOURNAL_FILE="$T/journal.jsonl"
export HERD_JOURNAL_HERMETIC=1
export HERD_DRIVER=headless   # notifications land in a durable log file, no herdr popup dependency

# ── stub gh on PATH: `gh pr view <branch> …` → the stored "STATE\toid\tnumber" line, or nothing ──
BIN="$T/bin"; mkdir -p "$BIN"
export GH_DIR="$T/gh"; mkdir -p "$GH_DIR"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  [ -f "$GH_DIR/${3:-}" ] && cat "$GH_DIR/${3:-}"
fi
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
herdr() { return 127; }   # no tabs/panes exist in this fixture; any real call is a loud failure

# ── a REAL repo: main checkout + a $TREES to hang worktrees off ───────────────────────────────────
REPO="$T/main"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
echo base > "$REPO/file.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm base
WTREES="$T/trees"; mkdir -p "$WTREES"

# ── source the SHIPPED watcher in lib mode (functions only, no loop / no config / no network) ─────
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
command -v retire_classify   >/dev/null 2>&1 || fail "retirement.sh helpers not in scope"
command -v sweep_leg_worktrees >/dev/null 2>&1 || fail "sweep.sh helpers not in scope"
command -v _reconcile_dead_builder >/dev/null 2>&1 || fail "_reconcile_dead_builder not in scope"
command -v _sweep_anchor_ok >/dev/null 2>&1 || fail "_sweep_anchor_ok (HERD-646 leg 2) not defined"

# Repoint every root/ledger path at the fixture AFTER sourcing (module-level values came from config).
MAIN="$REPO"; TREES="$WTREES"; WORKTREES_DIR="$WTREES"; SELF_WT="$T/self"
DEFAULT_BRANCH="main"; DRYRUN=""; DELETE_BRANCH_ON_MERGE="true"
STATE="$TREES/.agent-watch-merged"
DEAD_STATE="$TREES/.agent-watch-dead"
TRANSCRIPT_STATE="$TREES/.agent-watch-transcript"
export HERD_TRANSCRIPT_ROOT="$TREES/.transcripts"
ok

# mkwt <slug> — a real feature worktree on branch feat/<slug> with one unique commit. Echoes its HEAD sha.
mkwt() {
  local slug="$1"
  git -C "$REPO" worktree add -q -b "feat/$slug" "$WTREES/$slug" main 2>/dev/null
  echo "$slug" > "$WTREES/$slug/file.txt"
  git -C "$WTREES/$slug" add -A
  git -C "$WTREES/$slug" -c user.email=t@t.t -c user.name=t commit -qm "$slug"
  git -C "$WTREES/$slug" rev-parse HEAD
}
# mk_successor <base-sha> — one more commit ON TOP of <base-sha>, built in a throwaway DETACHED
# worktree so the object lands in the SHARED git object store WITHOUT moving any real worktree's own
# checked-out HEAD — exactly what "a commit landed on the remote after this tree's own last push"
# means: the object exists (as it would after a fetch), but this worktree's HEAD never advanced to it.
mk_successor() {
  local base="$1" tmp; tmp="$T/succ-$RANDOM$RANDOM"
  git -C "$REPO" worktree add -q --detach "$tmp" "$base" >/dev/null 2>&1
  echo "ci-retry" >> "$tmp/file.txt"
  git -C "$tmp" add -A
  git -C "$tmp" -c user.email=t@t.t -c user.name=t commit -qm successor >/dev/null
  local sha; sha="$(git -C "$tmp" rev-parse HEAD)"
  git -C "$REPO" worktree remove --force "$tmp" >/dev/null 2>&1
  printf '%s' "$sha"
}
# gh_says <branch> <STATE> <oid> <num>
gh_says() { mkdir -p "$GH_DIR/$(dirname "$1")"; printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$GH_DIR/$1"; }
RS=$'\x1f'
state_of() { retire_classify "$1" "$2" "$3" "${4:-0}" residual | cut -d"$RS" -f1; }
cold() { rm -f "$TREES"/.retire-anchor-* "$TREES"/.retire-probe-* 2>/dev/null; }

# ════════════════════════════════════════════════════════════════════════════════════════════════
# LEG 2 — REAPER: retirement.sh's classifier tolerates BEHIND, still refuses AHEAD
# ════════════════════════════════════════════════════════════════════════════════════════════════

# ── (B1) HEAD 1 commit BEHIND a merged PR's headRefOid → retiring ──────────────────────────────────
sha_b1="$(mkwt merged-behind)"
succ_b1="$(mk_successor "$sha_b1")"
gh_says "feat/merged-behind" MERGED "$succ_b1" 40
cold; [ "$(state_of merged-behind "$WTREES/merged-behind" feat/merged-behind 0)" = retiring ] \
  || fail "(B1) HEAD 1 commit BEHIND a merged PR's headRefOid must classify retiring"
ok; echo "PASS (B1) 0-ahead / 1-behind merged worktree classifies retiring"

# ── (B2) HEAD 2 commits BEHIND (N-behind, not just exactly 1) → retiring ────────────────────────────
sha_b2="$(mkwt merged-behind-2)"
succ_b2a="$(mk_successor "$sha_b2")"
succ_b2b="$(mk_successor "$succ_b2a")"
gh_says "feat/merged-behind-2" MERGED "$succ_b2b" 41
cold; [ "$(state_of merged-behind-2 "$WTREES/merged-behind-2" feat/merged-behind-2 0)" = retiring ] \
  || fail "(B2) HEAD 2 commits BEHIND a merged PR's headRefOid must classify retiring"
ok; echo "PASS (B2) 0-ahead / N-behind merged worktree classifies retiring"

# ── (B3) HEAD 1 commit AHEAD of a merged PR's headRefOid → active, UNCHANGED (never reaped) ────────
# A REAL, valid ancestor commit (not a bogus/never-existed sha) — proves _sweep_anchor_ok correctly
# refuses the wrong DIRECTION of ancestry, not merely a missing object.
sha_b3="$(mkwt merged-ahead)"
echo "extra local work" >> "$WTREES/merged-ahead/file.txt"
git -C "$WTREES/merged-ahead" add -A
git -C "$WTREES/merged-ahead" -c user.email=t@t.t -c user.name=t commit -qm "unshipped extra work"
gh_says "feat/merged-ahead" MERGED "$sha_b3" 42
cold; [ "$(state_of merged-ahead "$WTREES/merged-ahead" feat/merged-ahead 0)" = active ] \
  || fail "(B3) HEAD 1 commit AHEAD of a merged PR's headRefOid must stay active — refused, evidence-preserving"
ok; echo "PASS (B3) 1-ahead-of-merged-head worktree still refused (active), behavior unchanged"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# LEG 2 — REAPER: sweep.sh's own leg agrees and actually performs the reap
# ════════════════════════════════════════════════════════════════════════════════════════════════
_sweep_reset_counters
: > "$JOURNAL_FILE"
sweep_leg_worktrees "" || fail "sweep_leg_worktrees exited non-zero"

[ ! -d "$WTREES/merged-behind" ]   || fail "(B4) sweep did not reap the 1-behind merged worktree"
[ ! -d "$WTREES/merged-behind-2" ] || fail "(B4) sweep did not reap the N-behind merged worktree"
[ "$SWEEP_N_REAP" -ge 2 ] || fail "(B4) sweep's reap counter did not credit both behind fixtures, got $SWEEP_N_REAP"
grep -q '"event":"reap".*"slug":"merged-behind"' "$JOURNAL_FILE" \
  || fail "(B4) no reap journal event for merged-behind"
grep -q '"event":"reap".*"slug":"merged-behind-2"' "$JOURNAL_FILE" \
  || fail "(B4) no reap journal event for merged-behind-2"
ok; echo "PASS (B4) herd sweep actually reaps the behind fixtures — swept:0 no longer happens"

[ -d "$WTREES/merged-ahead" ] || fail "(B5) sweep must NEVER reap a worktree carrying commits ahead of the merged head"
ok; echo "PASS (B5) sweep still refuses the ahead-of-merged-head worktree"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# LEG 1 — ROW TRUTH: agent-watch.sh's dead-builder classification resolves retirement state FIRST
# ════════════════════════════════════════════════════════════════════════════════════════════════
NOTIFY_LOG="$TREES/.herd/notifications.log"
GRACE="$(_dead_grace_secs)"
NOW=3000000000

# ── (L1) CONTROL: a genuinely dead, non-retirement-owned builder still classifies DEAD + notifies ──
: > "$DEAD_STATE"
RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=()   # retirement has not claimed this slug
mkdir -p "$WTREES/ctrl-dead"
v1="$(HERD_NOW_EPOCH="$NOW" _reconcile_dead_builder ctrl-dead "$WTREES/ctrl-dead" "")"
[ "$v1" = PENDING ] || fail "(L1) control: first sighting should be PENDING, got $v1"
v2="$(HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_dead_builder ctrl-dead "$WTREES/ctrl-dead" "")"
[ "$v2" = DEAD ] || fail "(L1) control: past-grace, non-retiring dead builder must still classify DEAD, got $v2"
grep -q "ctrl-dead" "$NOTIFY_LOG" 2>/dev/null || fail "(L1) control: a genuine dead builder must still notify"
grep -q "re-spawn" "$NOTIFY_LOG" 2>/dev/null || fail "(L1) control: a genuine dead builder's notification must still say re-spawn"
ok; echo "PASS (L1) control — a genuinely unshipped dead builder still gets re-spawn advice"

# ── (L2)/(L3) the SAME dead signature, but retirement already owns this slug (PR merged) ───────────
: > "$DEAD_STATE"
: > "$NOTIFY_LOG"
RETIRE_SLUG=(); RETIRE_STATE=(); RETIRE_DETAIL=(); RETIRE_DIR=()
_retire_record merged-behind-live retiring "PR #40 merged" "$WTREES/merged-behind-live"
mkdir -p "$WTREES/merged-behind-live"
v1="$(HERD_NOW_EPOCH="$NOW" _reconcile_dead_builder merged-behind-live "$WTREES/merged-behind-live" "")"
[ "$v1" = retiring ] || fail "(L2) a slug retirement already classified 'retiring' must never read PENDING, got $v1"
v2="$(HERD_NOW_EPOCH="$((NOW + GRACE + 1))" _reconcile_dead_builder merged-behind-live "$WTREES/merged-behind-live" "")"
[ "$v2" = retiring ] || fail "(L2) a retiring slug must never cross into DEAD even past the dead-builder grace, got $v2"
[ -z "$(dead_first_seen merged-behind-live)" ] \
  || fail "(L2) a retiring slug must never start a dead-first-seen anchor"
! dead_notified merged-behind-live || fail "(L2) a retiring slug must never be marked dead-notified"
[ ! -s "$NOTIFY_LOG" ] || { grep -q "merged-behind-live" "$NOTIFY_LOG" && fail "(L2) must NEVER fire a 💀 dead-builder notification for a retiring slug"; }
ok; echo "PASS (L2) a merged/retiring slug never classifies DEAD, never notifies re-spawn"

row="$(_row_retirement "merged-behind-live" merged-behind-live "$v2" "PR #40 merged")"
case "$row" in *"re-spawn"*) fail "(L3) the calm retirement row must NEVER say re-spawn: $row" ;; esac
case "$row" in *"retiring"*) : ;; *) fail "(L3) the calm row must say retiring…, got: $row" ;; esac
ok; echo "PASS (L3) the row rendered from a retiring verdict reads calm, never re-spawn"

echo "ALL PASS ($pass checks)"
