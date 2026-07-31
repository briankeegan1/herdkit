#!/usr/bin/env bash
# test-main-freshness.sh — hermetic tests for the TICK-LEVEL MAIN-checkout freshness reconcile
# (reconcile_main_freshness in agent-watch.sh, HERD-233).
#
# Multi-seat doctrine: the freshness of $MAIN is a RECONCILED INVARIANT, not a do_merge side-effect.
# When another seat merges, $MAIN goes stale and this watcher keeps running the engine code it loads
# from there; when a generated-map push is rejected, $MAIN is left DIVERGED with no retry path.
#
#   (1) FRESH ($MAIN == origin) → byte-inert: no commit, no journal, no state file
#   (2) BEHIND (origin advanced out-of-band, do_merge never ran) → ff-pull + journal main_ff.
#       Runs with CODEMAP_AUTOREFRESH=false: freshness is DECOUPLED from the codemap lever.
#   (3) the ff delta rewrote agent-watch.sh → 'restart recommended' note + restart=yes journaled
#   (4) AHEAD-only generated-map commit (the `pushed=no` corpse) → pushed, journal main_heal
#   (5) DIVERGED with only generated-map local commits → rebase onto origin + push, journal main_heal
#   (6) DIVERGED with a local commit nobody generated → HELD: no rebase, LOUD row, journaled ONCE
#   (7) DIRTY tree while behind → HELD (dirty-tree): never pull over a human's work
#   (8) MID-OP (live gate marker) → defer silently
#   (9) FETCH FAILURE (unreachable remote) → fail-soft: no journal, no state, tree untouched
#
# HERD-259 — the held row is re-derived from OBSERVED state every tick, so it CLEARS on recovery:
#  (11) a held row whose tree went clean+current clears the file + the row in ONE tick, journaling
#       main_fresh_recovered exactly once (the live incident: 'dirty-tree 4 0' held for 20+ min)
#  (12) it clears ABOVE the defers that used to strand it — a live gate marker, an unfetchable remote
#  (13) a GENUINELY stale MAIN is untouched: state file + rendered row byte-identical, no journal
#  (14) a still-dirty tree keeps its own hold; DRYRUN clears nothing; no state file ⇒ byte-inert
#
# Sources agent-watch.sh in lib mode and drives reconcile_main_freshness against a REAL local git
# repo wired to a bare "origin", with a second clone standing in for the other seat that pushes.
# journal_append is overridden to a log.
# Run:  bash tests/test-main-freshness.sh
set -uo pipefail
HERE_T="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE_T/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required to run this test"

# ── Stub gh / herdr on PATH (network-free); git stays REAL ────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode ─────────────────────────────────────────────────────────────
export AGENT_WATCH_LIB=1
export WORKTREES_DIR="$T/trees"; mkdir -p "$T/trees"
export HERD_CONFIG_FILE="$T/no-such-config"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
for fn in reconcile_main_freshness build_main_freshness _main_fresh_generated_only \
          _main_fresh_note_restart _main_fresh_hold _main_fresh_recheck _main_fresh_recovered \
          _watch_gate_inflight; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined"
done

JLOG="$T/journal.log"; : > "$JLOG"
journal_append() { printf '%s\n' "$*" >> "$JLOG"; }

# ── Real git repo wired to a bare origin, plus a SECOND clone = "the other seat" ──────────────────
ORIGIN="$T/origin.git"; git init -q --bare "$ORIGIN"
gitcfg() { git -C "$1" config user.email t@t.test; git -C "$1" config user.name tester; }

MAIN="$T/main"; git clone -q "$ORIGIN" "$MAIN" 2>/dev/null
git -C "$MAIN" checkout -q -B main; gitcfg "$MAIN"
mkdir -p "$MAIN/docs" "$MAIN/scripts/herd"
printf 'MAP v1\n'    > "$MAIN/docs/codemap.md"
printf 'INDEX v1\n'  > "$MAIN/docs/symbol-index.md"
printf 'engine v1\n' > "$MAIN/scripts/herd/agent-watch.sh"
printf 'hello\n'     > "$MAIN/README.md"
git -C "$MAIN" add -A; git -C "$MAIN" commit -q -m init; git -C "$MAIN" push -q origin main

SEAT="$T/seat2"; git clone -q "$ORIGIN" "$SEAT" 2>/dev/null; gitcfg "$SEAT"

HERD_REMOTE=origin; HERD_BRANCH_NAME=main; DEFAULT_BRANCH=origin/main
mkdir -p "$TREES"
MAIN_FRESH_STATE="$TREES/.agent-watch-main-freshness"
MAIN_FRESH_RESTART="$TREES/.agent-watch-main-restart"

commits()  { git -C "$MAIN" rev-list --count HEAD; }
head_sha() { git -C "$MAIN" rev-parse HEAD; }
origin_sha() { git -C "$MAIN" rev-parse origin/main; }
jhas()     { grep -q "$1" "$JLOG"; }
jcount()   { grep -c "$1" "$JLOG" 2>/dev/null || printf '0'; }
reset_state() { : > "$JLOG"; rm -f "$MAIN_FRESH_STATE" "$MAIN_FRESH_RESTART"; }

# seat_push <file> <content> <msg> — the OTHER seat lands a commit on origin/main (no do_merge here).
seat_push() {
  git -C "$SEAT" pull -q --ff-only origin main >/dev/null 2>&1
  mkdir -p "$SEAT/$(dirname "$1")"
  printf '%s\n' "$2" > "$SEAT/$1"
  git -C "$SEAT" add -A; git -C "$SEAT" commit -q -m "$3"; git -C "$SEAT" push -q origin main
}

# ── (1) FRESH → byte-inert ────────────────────────────────────────────────────────────────────────
reset_state
h0="$(head_sha)"
reconcile_main_freshness
[ "$(head_sha)" = "$h0" ]      || fail "(1) FRESH moved HEAD"
[ ! -s "$JLOG" ]               || fail "(1) FRESH journaled: $(cat "$JLOG")"
[ ! -e "$MAIN_FRESH_STATE" ]   || fail "(1) FRESH wrote a held state file"
build_main_freshness
[ -z "${MAIN_FRESHNESS:-}" ]   || fail "(1) FRESH rendered a row: $MAIN_FRESHNESS"
ok

# ── (2) BEHIND → ff-pull + main_ff, WITH the codemap lever OFF (decoupled) ────────────────────────
reset_state
seat_push README.md "other seat was here" "feat: other seat merge"
h0="$(head_sha)"
CODEMAP_AUTOREFRESH=false reconcile_main_freshness
[ "$(head_sha)" = "$(origin_sha)" ] || fail "(2) BEHIND did not fast-forward"
[ "$(head_sha)" != "$h0" ]          || fail "(2) BEHIND left HEAD stale"
jhas 'main_ff behind 1 from'        || fail "(2) missing main_ff journal line: $(cat "$JLOG")"
jhas 'restart no'                   || fail "(2) a README-only pull must not recommend a restart: $(cat "$JLOG")"
[ ! -e "$MAIN_FRESH_RESTART" ]      || fail "(2) README-only pull left a restart note"
[ ! -e "$MAIN_FRESH_STATE" ]        || fail "(2) a healed ff left a held state file"
ok

# ── (3) the pulled delta rewrote agent-watch.sh → restart recommended ─────────────────────────────
reset_state
seat_push scripts/herd/agent-watch.sh "engine v2" "feat: engine change"
CODEMAP_AUTOREFRESH=false reconcile_main_freshness
[ "$(head_sha)" = "$(origin_sha)" ] || fail "(3) engine pull did not fast-forward"
jhas 'restart yes'                  || fail "(3) engine pull did not journal restart=yes: $(cat "$JLOG")"
[ -s "$MAIN_FRESH_RESTART" ]        || fail "(3) engine pull left no restart note"
build_main_freshness
case "${MAIN_FRESHNESS:-}" in *"restart recommended"*) ;; *) fail "(3) restart row not rendered: ${MAIN_FRESHNESS:-<empty>}" ;; esac
case "${MAIN_FRESHNESS:-}" in *"MAIN STALE"*) fail "(3) restart note must not paint a STALE row" ;; esac
rm -f "$MAIN_FRESH_RESTART"
ok

# ── (4) AHEAD-only generated-map commit (the `pushed=no` corpse) → pushed ─────────────────────────
reset_state
printf 'MAP v2\n' > "$MAIN/docs/codemap.md"
git -C "$MAIN" commit -q -m "chore: refresh codemap (reconcile)" -- docs/codemap.md
h0="$(head_sha)"
reconcile_main_freshness
[ "$(head_sha)" = "$h0" ]                       || fail "(4) a pure push moved HEAD"
[ "$(origin_sha)" = "$h0" ]                     || fail "(4) the stranded generated commit was not pushed"
jhas 'main_heal ahead 1 behind 0 result pushed' || fail "(4) missing main_heal journal: $(cat "$JLOG")"
[ ! -e "$MAIN_FRESH_STATE" ]                    || fail "(4) a healed push left a held state file"
ok

# ── (5) DIVERGED, local commits are generated maps only → rebase + push ───────────────────────────
reset_state
printf 'INDEX v2\n' > "$MAIN/docs/symbol-index.md"
git -C "$MAIN" commit -q -m "chore: refresh symbol-index (reconcile)" -- docs/symbol-index.md
seat_push README.md "seat2 raced us" "feat: concurrent seat merge"
reconcile_main_freshness
[ "$(head_sha)" = "$(origin_sha)" ]        || fail "(5) DIVERGED generated-only did not converge with origin"
[ "$(cat "$MAIN/docs/symbol-index.md")" = "INDEX v2" ] \
                                           || fail "(5) the rebase lost the generated commit"
grep -q 'seat2 raced us' "$MAIN/README.md" || fail "(5) the rebase lost the other seat's commit"
jhas 'main_heal ahead 1 behind 1 result pushed' || fail "(5) missing main_heal journal: $(cat "$JLOG")"
ok

# ── (6) DIVERGED with a local commit nobody generated → HELD, never rebased ───────────────────────
reset_state
printf 'a human wrote this\n' > "$MAIN/NOTES.md"
git -C "$MAIN" add NOTES.md; git -C "$MAIN" commit -q -m "wip: hand edit on main"
seat_push README.md "seat2 again" "feat: another seat merge"
h0="$(head_sha)"
reconcile_main_freshness
[ "$(head_sha)" = "$h0" ]                  || fail "(6) HELD rebased a human's commit — must never"
[ "$(head_sha)" != "$(origin_sha)" ]       || fail "(6) HELD pushed a human's commit — must never"
jhas 'main_freshness result held reason local-commits behind 1 ahead 1' \
                                           || fail "(6) missing held journal: $(cat "$JLOG")"
build_main_freshness
case "${MAIN_FRESHNESS:-}" in *"MAIN STALE"*"local commits"*) ;; *) fail "(6) held row not rendered: ${MAIN_FRESHNESS:-<empty>}" ;; esac
# The same unchanged hold journals ONCE (the row persists; the journal does not spam).
reconcile_main_freshness
[ "$(jcount 'main_freshness')" = "1" ]     || fail "(6) held reason re-journaled: $(jcount 'main_freshness') lines"
ok

# Recover: drop the human commit so the remaining legs start from a clean, ff-able MAIN.
git -C "$MAIN" reset -q --hard origin/main

# ── (7) DIRTY tree while behind → HELD (dirty-tree), never pull over the work ─────────────────────
reset_state
seat_push README.md "seat2 while we were dirty" "feat: seat merge during local edit"
printf 'uncommitted work\n' > "$MAIN/WIP.md"
git -C "$MAIN" add WIP.md
h0="$(head_sha)"
reconcile_main_freshness
[ "$(head_sha)" = "$h0" ]                  || fail "(7) DIRTY tree was pulled over"
[ -f "$MAIN/WIP.md" ]                      || fail "(7) DIRTY tree lost the uncommitted file"
jhas 'main_freshness result held reason dirty-tree behind 1 ahead 0' \
                                           || fail "(7) missing dirty-tree held journal: $(cat "$JLOG")"
build_main_freshness
case "${MAIN_FRESHNESS:-}" in *"uncommitted changes"*) ;; *) fail "(7) dirty row not rendered: ${MAIN_FRESHNESS:-<empty>}" ;; esac
git -C "$MAIN" reset -q --hard HEAD; rm -f "$MAIN/WIP.md"
ok

# ── (8) MID-OP (live gate marker) → defer silently ────────────────────────────────────────────────
reset_state
INF="$TREES/.review-inflight-99-shaMID"
_marker_write "$INF" "$$"          # live: this pid, this starttime
h0="$(head_sha)"
reconcile_main_freshness
[ "$(head_sha)" = "$h0" ]                  || fail "(8) MID-OP pulled while a gate was live"
[ ! -s "$JLOG" ]                           || fail "(8) MID-OP journaled: $(cat "$JLOG")"
[ ! -e "$MAIN_FRESH_STATE" ]               || fail "(8) MID-OP wrote a held state file"
rm -f "$INF"
ok

# Bonus: once the gate clears, the deferred ff DOES happen on the next tick.
reset_state
reconcile_main_freshness
[ "$(head_sha)" = "$(origin_sha)" ]        || fail "(8b) post-mid-op ff did not happen"
jhas 'main_ff'                             || fail "(8b) post-mid-op missing main_ff: $(cat "$JLOG")"
ok

# ── (9) FETCH FAILURE → fail-soft (never blocks the tick, never alarms) ───────────────────────────
reset_state
seat_push README.md "unreachable-remote leg" "feat: seat merge we cannot fetch"
git -C "$MAIN" remote set-url origin "$T/no-such-origin.git"
h0="$(head_sha)"
reconcile_main_freshness || fail "(9) a fetch failure returned non-zero — must be fail-soft"
[ "$(head_sha)" = "$h0" ]                  || fail "(9) fetch failure moved HEAD"
[ ! -s "$JLOG" ]                           || fail "(9) fetch failure journaled: $(cat "$JLOG")"
[ ! -e "$MAIN_FRESH_STATE" ]               || fail "(9) fetch failure raised a false MAIN STALE row"
git -C "$MAIN" remote set-url origin "$ORIGIN"
ok

# ── (10) DRYRUN → byte-inert ──────────────────────────────────────────────────────────────────────
reset_state
h0="$(head_sha)"
DRYRUN=1 reconcile_main_freshness
[ "$(head_sha)" = "$h0" ]                  || fail "(10) DRYRUN moved HEAD"
[ ! -s "$JLOG" ]                           || fail "(10) DRYRUN journaled: $(cat "$JLOG")"
ok

# ── (11) RECOVERED: a held row whose condition healed clears within ONE tick (HERD-259) ───────────
# The 2026-07-09 incident, reproduced: the file says 'dirty-tree 4 0'; the checkout is clean + current.
#
# HERD-455 / GH #569 UPDATE: the RENDER no longer paints a row it can observe to be false, so this
# fixture no longer has a "still painting" moment to assert. That is the fix, not a weakening — the
# render-tick reconcile is what makes the row clear WITHOUT a restart and without depending on any of
# _main_fresh_recheck's early returns. Both halves are asserted here: the render drops it (and journals
# the recovery exactly once), and the recheck path clears an identical hold on its own too.
reset_state
git -C "$MAIN" fetch -q origin main >/dev/null 2>&1
git -C "$MAIN" reset -q --hard origin/main
_main_fresh_hold dirty-tree 4 0
: > "$JLOG"
build_main_freshness
[ -z "${MAIN_FRESHNESS:-}" ] || fail "(11) the render painted a row observed git state disproves: $MAIN_FRESHNESS"
[ ! -e "$MAIN_FRESH_STATE" ] || fail "(11) the render left the disproved state file: $(cat "$MAIN_FRESH_STATE")"
jhas 'main_fresh_recovered reason dirty-tree was_behind 4 was_ahead 0' \
                               || fail "(11) missing main_fresh_recovered journal: $(cat "$JLOG")"
build_main_freshness
[ -z "${MAIN_FRESHNESS:-}" ]   || fail "(11) the row outlived its state file: $MAIN_FRESHNESS"
[ "$(jcount 'main_fresh_recovered')" = "1" ] || fail "(11) recovery re-journaled: $(jcount 'main_fresh_recovered') lines"
# …and the HERD-259 recovery path is untouched: an identical hold clears on the recheck alone.
_main_fresh_hold dirty-tree 4 0
: > "$JLOG"
_main_fresh_recheck
[ ! -e "$MAIN_FRESH_STATE" ] || fail "(11) clean+current MAIN kept its held state file: $(cat "$MAIN_FRESH_STATE")"
jhas 'main_fresh_recovered'    || fail "(11) the recheck path stopped journaling recovery"
_main_fresh_recheck            # the transition journals ONCE; a recovered tick is byte-inert thereafter
[ "$(jcount 'main_fresh_recovered')" = "1" ] || fail "(11) recheck recovery re-journaled"
ok

# ── (12) it clears ABOVE the defers that used to strand it ────────────────────────────────────────
# A live gate marker: the reconcile proper must keep its hands off the tree, but the read-only recheck
# above it still clears the row (this is what made the incident survive 20+ minutes of busy ticks).
reset_state
_main_fresh_hold dirty-tree 4 0
INF="$TREES/.review-inflight-98-shaGATE"
_marker_write "$INF" "$$"
: > "$JLOG"
reconcile_main_freshness
[ ! -e "$MAIN_FRESH_STATE" ] || fail "(12) a mid-gate tick left a recovered row standing"
jhas 'main_fresh_recovered'  || fail "(12) mid-gate recovery not journaled: $(cat "$JLOG")"
rm -f "$INF"
ok

# An unfetchable remote: the reconcile bails before it can compare, the recheck reads the local ref.
reset_state
_main_fresh_hold dirty-tree 4 0
git -C "$MAIN" remote set-url origin "$T/no-such-origin.git"
reconcile_main_freshness     || fail "(12b) a fetch failure returned non-zero — must be fail-soft"
[ ! -e "$MAIN_FRESH_STATE" ] || fail "(12b) an unfetchable remote left a recovered row standing"
git -C "$MAIN" remote set-url origin "$ORIGIN"
ok

# ── (13) a GENUINELY stale MAIN is untouched — byte-identical file + row, no recovery journal ─────
reset_state
printf 'a human wrote this too\n' > "$MAIN/NOTES2.md"
git -C "$MAIN" add NOTES2.md; git -C "$MAIN" commit -q -m "wip: another hand edit on main"
seat_push README.md "seat2 once more" "feat: yet another seat merge"
reconcile_main_freshness
held_before="$(cat "$MAIN_FRESH_STATE" 2>/dev/null || true)"
[ -n "$held_before" ] || fail "(13) fixture did not hold a genuinely diverged MAIN"
build_main_freshness; row_before="${MAIN_FRESHNESS:-}"
: > "$JLOG"
_main_fresh_recheck
[ -s "$MAIN_FRESH_STATE" ] || fail "(13) a genuinely diverged MAIN had its row cleared"
[ "$(cat "$MAIN_FRESH_STATE")" = "$held_before" ] || fail "(13) the held state file was rewritten"
build_main_freshness
[ "${MAIN_FRESHNESS:-}" = "$row_before" ] || fail "(13) the held row is not byte-identical"
[ ! -s "$JLOG" ]                          || fail "(13) a still-held row journaled: $(cat "$JLOG")"
ok
git -C "$MAIN" reset -q --hard origin/main

# ── (14) still-dirty keeps its hold; DRYRUN clears nothing; no state file ⇒ byte-inert ────────────
reset_state
_main_fresh_hold dirty-tree 1 0
printf 'uncommitted work\n' > "$MAIN/WIP2.md"; git -C "$MAIN" add WIP2.md
_main_fresh_recheck
[ -s "$MAIN_FRESH_STATE" ] || fail "(14) a still-dirty tree cleared its own dirty-tree hold"
git -C "$MAIN" reset -q --hard HEAD; rm -f "$MAIN/WIP2.md"

DRYRUN=1 _main_fresh_recheck
[ -s "$MAIN_FRESH_STATE" ] || fail "(14) DRYRUN mutated state — an observation run clears nothing"

reset_state
: > "$JLOG"
_main_fresh_recheck
[ ! -s "$JLOG" ]           || fail "(14) with no row held the recheck is not byte-inert: $(cat "$JLOG")"
ok

# ── (15) RE-DERIVE: a hold with FROZEN counts is recomputed from observed state (HERD-293) ─────────
# The live incident 2026-07-10: the file held 'dirty-tree 3 0'; the operator pulled so HEAD caught up
# (real behind=0) but the tree stayed dirty, so the old recheck returned early and the stale "behind by 3"
# kept painting across restarts. Now the recheck RE-DERIVES the line — reason stays dirty-tree, the count
# refreshes to the observed 0 — even while a live gate marker (the defer that used to starve the reconcile)
# is present, because the recheck runs read-only ABOVE that defer.
reset_state
git -C "$MAIN" fetch -q origin main >/dev/null 2>&1
git -C "$MAIN" reset -q --hard origin/main                                  # HEAD caught up: real behind=0
printf 'uncommitted work\n' > "$MAIN/WIP3.md"; git -C "$MAIN" add WIP3.md   # ...but the tree is dirty
_main_fresh_hold dirty-tree 3 0                                             # the stale, frozen hold
INF="$TREES/.review-inflight-97-shaFROZEN"
_marker_write "$INF" "$$"                                                   # a live gate: recheck ignores it
: > "$JLOG"
_main_fresh_recheck
[ "$(cat "$MAIN_FRESH_STATE" 2>/dev/null || true)" = "dirty-tree 0 0" ] \
  || fail "(15) frozen counts not re-derived: $(cat "$MAIN_FRESH_STATE" 2>/dev/null || echo '<none>')"
jhas 'main_freshness result held reason dirty-tree behind 0 ahead 0' \
  || fail "(15) re-derived hold not journaled: $(cat "$JLOG")"
build_main_freshness
case "${MAIN_FRESHNESS:-}" in *"MAIN STALE"*"uncommitted changes"*) ;; *) fail "(15) re-derived dirty row not rendered: ${MAIN_FRESHNESS:-<empty>}" ;; esac
# Re-run with the SAME observed state: the line is unchanged, so _main_fresh_hold dedups the journal.
_main_fresh_recheck
[ "$(jcount 'main_freshness result held')" = "1" ] || fail "(15) an unchanged re-derive re-journaled: $(jcount 'main_freshness result held') lines"
# Now clean the tree: clean + 0-behind + 0-ahead clears the row in the same read-only recheck.
git -C "$MAIN" reset -q --hard HEAD; rm -f "$MAIN/WIP3.md"
: > "$JLOG"
_main_fresh_recheck
[ ! -e "$MAIN_FRESH_STATE" ]                     || fail "(15) a cleaned tree kept its held row: $(cat "$MAIN_FRESH_STATE")"
jhas 'main_fresh_recovered reason dirty-tree'   || fail "(15) the cleared row was not journaled: $(cat "$JLOG")"
rm -f "$INF"
ok

# ── (16) RE-DERIVE keeps a genuine local-commits hold current, and never invents one (HERD-293) ────
# A clean, diverged checkout with a human commit: the recheck must re-hold 'local-commits' with fresh
# counts (not clear it, not relabel it), and a generated-only divergence it must NOT re-hold (the reconcile
# heals that) — it is left for the reconcile below the defer.
reset_state
printf 'a human wrote this three\n' > "$MAIN/NOTES3.md"
git -C "$MAIN" add NOTES3.md; git -C "$MAIN" commit -q -m "wip: hand edit three"
seat_push README.md "seat2 for 16" "feat: seat merge sixteen"
git -C "$MAIN" fetch -q origin main >/dev/null 2>&1                         # local ref advances: real behind=1
_main_fresh_hold local-commits 9 1                                         # stale behind count (9, not 1)
: > "$JLOG"
_main_fresh_recheck
[ "$(cat "$MAIN_FRESH_STATE" 2>/dev/null || true)" = "local-commits 1 1" ] \
  || fail "(16) local-commits counts not re-derived: $(cat "$MAIN_FRESH_STATE" 2>/dev/null || echo '<none>')"
jhas 'main_freshness result held reason local-commits behind 1 ahead 1' \
  || fail "(16) re-derived local-commits not journaled: $(cat "$JLOG")"
git -C "$MAIN" reset -q --hard origin/main
ok

# ── (17) BEHIND + UNTRACKED-ONLY → still fast-forwards (HERD-422) ─────────────────────────────────
# An untracked file sitting in $MAIN must NOT be treated as tree dirt: before the fix this painted a
# false MAIN STALE (dirty-tree) and never even attempted the ff, forever, since nothing ever removes
# the untracked file on its own.
reset_state
seat_push README.md "seat2 while untracked cruft sat around" "feat: seat merge past untracked cruft"
printf 'scratch, never added\n' > "$MAIN/SCRATCH.md"
h0="$(head_sha)"
reconcile_main_freshness
[ "$(head_sha)" = "$(origin_sha)" ] || fail "(17) untracked-only tree was NOT fast-forwarded"
[ "$(head_sha)" != "$h0" ]          || fail "(17) untracked-only left HEAD stale"
jhas 'main_ff behind 1 from'        || fail "(17) missing main_ff journal: $(cat "$JLOG")"
[ ! -e "$MAIN_FRESH_STATE" ]        || fail "(17) a healed ff left a held state file"
[ "$(cat "$MAIN/SCRATCH.md" 2>/dev/null || true)" = "scratch, never added" ] \
                                     || fail "(17) the untracked file was touched by the ff"
rm -f "$MAIN/SCRATCH.md"
ok

# ── (18) BEHIND + a TRACKED (unstaged) modification → still HELD (dirty-tree) ─────────────────────
# The untracked exemption must not leak into tracked dirt: an unstaged edit to a file git already
# tracks is real work and must still refuse the pull, exactly like the staged case in (7).
reset_state
seat_push README.md "seat2 while a tracked file was dirty" "feat: seat merge past tracked edit"
printf 'hello\nlocal edit, not staged\n' > "$MAIN/README.md"
h0="$(head_sha)"
reconcile_main_freshness
[ "$(head_sha)" = "$h0" ]           || fail "(18) tracked-dirty tree was pulled over"
jhas 'main_freshness result held reason dirty-tree behind 1 ahead 0' \
                                     || fail "(18) missing dirty-tree held journal: $(cat "$JLOG")"
git -C "$MAIN" checkout -q -- README.md
git -C "$MAIN" fetch -q origin main >/dev/null 2>&1
git -C "$MAIN" reset -q --hard origin/main   # catch up: (19) needs a known behind=1 to start from
ok

# ── (19) UNTRACKED COLLISION → left to `git merge --ff-only` to refuse safely, never overwritten ───
# The one real case where an untracked path matters: the incoming commit would create a file that
# already sits untracked in $MAIN. The fix must not pre-emptively hold on it (it is still untracked
# status), but ff-only itself must refuse rather than silently clobbering the untracked content, and
# the existing ff-failed path must surface that as an honest hold.
reset_state
seat_push COLLIDE.md "seat2's version" "feat: seat adds a file that collides with local untracked"
printf 'local untracked version, never added\n' > "$MAIN/COLLIDE.md"
h0="$(head_sha)"
reconcile_main_freshness
[ "$(head_sha)" = "$h0" ]           || fail "(19) an untracked collision let the ff proceed"
[ "$(head_sha)" != "$(origin_sha)" ] || fail "(19) an untracked collision converged with origin"
[ "$(cat "$MAIN/COLLIDE.md")" = "local untracked version, never added" ] \
                                     || fail "(19) the untracked file was overwritten by the ff attempt"
jhas 'main_freshness result held reason ff-failed behind 1 ahead 0' \
                                     || fail "(19) missing ff-failed held journal: $(cat "$JLOG")"
build_main_freshness
case "${MAIN_FRESHNESS:-}" in *"MAIN STALE"*) ;; *) fail "(19) ff-failed row not rendered: ${MAIN_FRESHNESS:-<empty>}" ;; esac
rm -f "$MAIN/COLLIDE.md"
ok

echo "PASS: test-main-freshness.sh ($pass checks)"
