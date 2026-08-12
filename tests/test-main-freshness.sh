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
# HERD-651 — the RESTART NOTE arms on the whole surface the watcher LOADS, not just agent-watch.sh:
#  (20) a delta to scripts/herd/<any lib>, pysrc/herd/, or bin/herd arms it (agent-watch.sh unchanged)
#  (21) docs-only, templates-only and README-only deltas NEVER arm it
#  (22) the live miss: HEAD moved OUT-OF-BAND (do_merge's own ff) so the reconcile sees 0-ahead/0-behind
#       — the startup baseline sha still arms the note, journals once, and never advances itself
#  (23) fail-soft: no baseline / an unreadable sha / DRYRUN ⇒ pre-HERD-651 behavior, no note invented
#  (24) end to end: a sweep.sh-only merge arms the note AND the HERD-251 self-restart fires after the
#       quiesce drains; with the lever off the same note only renders 'restart recommended'
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
          _watch_gate_inflight _main_fresh_engine_delta _main_fresh_engine_staleness \
          _watch_record_start_head _self_restart_tick _self_restart_quiescing \
          _self_restart_hold_dispatch; do
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

# ══ HERD-651: the RESTART NOTE's arm condition is the whole surface the watcher LOADS ══════════════
# The watcher sources a dozen-plus libs out of scripts/herd/ and shells out to pysrc/herd/ + bin/herd,
# but the note used to arm ONLY when the delta rewrote agent-watch.sh itself — so a merged sibling left
# it running stale code indefinitely (LIVE 2026-08-11: PR #749's reaper landed in sweep.sh; the watcher
# missed the dead row it fixes for ~7 hours with WATCHER_SELF_RESTART=on).
git -C "$MAIN" fetch -q origin main >/dev/null 2>&1
git -C "$MAIN" reset -q --hard origin/main        # legs above left MAIN behind an ff-failed hold

# armed <file> <label> — a seat lands <file>, we reconcile: the ff MUST leave a restart note.
armed() {
  reset_state
  seat_push "$1" "engine delta for $2" "feat: $2"
  reconcile_main_freshness
  [ "$(head_sha)" = "$(origin_sha)" ] || fail "(20) $2: the ff did not happen"
  jhas 'restart yes'                  || fail "(20) $2 did not journal restart=yes: $(cat "$JLOG")"
  [ -s "$MAIN_FRESH_RESTART" ]        || fail "(20) $2 left no restart note"
}
# unarmed <file> <label> — the same, for a path the watcher never loads: NO note, ever.
unarmed() {
  reset_state
  seat_push "$1" "not engine code — $2" "docs: $2"
  reconcile_main_freshness
  [ "$(head_sha)" = "$(origin_sha)" ] || fail "(21) $2: the ff did not happen"
  jhas 'restart no'                   || fail "(21) $2 did not journal restart=no: $(cat "$JLOG")"
  [ ! -e "$MAIN_FRESH_RESTART" ]      || fail "(21) $2 armed a restart the watcher does not need"
}

# ── (20) a delta to any LOADED path arms the note ────────────────────────────────────────────────
armed scripts/herd/sweep.sh          "sweep.sh sibling lib (the live 2026-08-11 miss)"
armed pysrc/herd/live_runtime.py     "the python engine core the watcher shells out to"
armed bin/herd                       "the CLI the watcher shells out to"
armed scripts/herd/agent-watch.sh    "agent-watch.sh itself — exactly as before"
ok

# ── (21) docs-only and templates-only deltas NEVER arm ───────────────────────────────────────────
# templates/ is the one worth stating: templates are RENDER inputs (`herd render` writes the control-room
# artifacts from them), never sourced by the running watcher — a templates merge changes what the next
# render emits, not what this process executes, so it must not cost a restart.
unarmed docs/COORDINATOR-SOP.md      "a docs-only merge"
unarmed templates/capabilities.tsv   "a templates-only merge"
unarmed README.md                    "a README-only merge"
ok

# ── (22) THE LIVE MISS: HEAD moves OUT-OF-BAND, so the reconcile never sees a delta at all ────────
# do_merge fast-forwards $MAIN itself right after this seat's own merge (an operator pull, `herd update`
# and a sibling seat's checkout do the same). By the time the reconcile looks, $MAIN is 0-ahead/0-behind
# and the whole leg is byte-inert — which is why 13:31's merge went unnoticed until a hand restart. The
# baseline sha this process loaded from closes that: the note arms off OBSERVED HEAD vs that baseline.
reset_state
_watch_record_start_head                                   # pin: this "process" loaded the code at HEAD
base="$WATCH_START_HEAD"
[ -n "$base" ]                       || fail "(22) the startup baseline was never recorded"
seat_push scripts/herd/retirement.sh "retirement v2" "feat: sibling lib landed while we ran"
git -C "$MAIN" fetch -q origin main >/dev/null 2>&1
git -C "$MAIN" reset -q --hard origin/main                 # ← do_merge's own ff: HEAD moved, not by us
reconcile_main_freshness
[ -s "$MAIN_FRESH_RESTART" ]         || fail "(22) an out-of-band engine move left no restart note"
jhas "main_freshness result restart-note reason engine-stale shas ${base}..$(head_sha)" \
                                     || fail "(22) the stale-engine arm was not journaled: $(cat "$JLOG")"
build_main_freshness
case "${MAIN_FRESHNESS:-}" in *"restart recommended"*) ;; *) fail "(22) restart row not rendered: ${MAIN_FRESHNESS:-<empty>}" ;; esac
case "${MAIN_FRESHNESS:-}" in *"MAIN STALE"*) fail "(22) a fresh-but-stale-engine MAIN must not paint a STALE row" ;; esac
# A STANDING note is byte-inert: the row persists, the journal does not spam, and the baseline is NOT
# advanced (this process still runs the old code) — the restart is what re-pins it.
: > "$JLOG"
reconcile_main_freshness
[ ! -s "$JLOG" ]                     || fail "(22) a standing restart note re-journaled: $(cat "$JLOG")"
[ "$WATCH_START_HEAD" = "$base" ]    || fail "(22) the baseline advanced without a restart"
ok

# …and the same out-of-band move with a DOCS-only delta arms nothing.
reset_state
_watch_record_start_head
seat_push docs/NOTES-651.md "prose" "docs: prose only, out of band"
git -C "$MAIN" fetch -q origin main >/dev/null 2>&1
git -C "$MAIN" reset -q --hard origin/main
reconcile_main_freshness
[ ! -e "$MAIN_FRESH_RESTART" ]       || fail "(22b) a docs-only out-of-band move restarted the watcher"
[ ! -s "$JLOG" ]                     || fail "(22b) a docs-only out-of-band move journaled: $(cat "$JLOG")"
ok

# ── (23) FAIL-SOFT + byte-inert without a baseline ───────────────────────────────────────────────
# No baseline (a lib-mode source, an unreadable checkout) ⇒ pre-HERD-651 behavior exactly: the leg is
# skipped and only the reconcile's own ff/heal delta can arm. An unreadable sha never guesses a restart.
reset_state
WATCH_START_HEAD=""
seat_push scripts/herd/driver.sh "driver v2" "feat: sibling lib, no baseline pinned"
git -C "$MAIN" fetch -q origin main >/dev/null 2>&1
git -C "$MAIN" reset -q --hard origin/main
reconcile_main_freshness
[ ! -e "$MAIN_FRESH_RESTART" ]       || fail "(23) an empty baseline still armed a note"
[ ! -s "$JLOG" ]                     || fail "(23) an empty baseline journaled: $(cat "$JLOG")"
_main_fresh_engine_delta "deadbeef" "$(head_sha)" && fail "(23) an unreadable sha claimed an engine delta"
_watch_record_start_head
DRYRUN=1 reconcile_main_freshness
[ ! -e "$MAIN_FRESH_RESTART" ]       || fail "(23) DRYRUN armed a restart note"
ok

# ── (24) END TO END: a sweep.sh-only merge arms the note AND the self-restart fires after quiesce ──
# The whole point of the widening: with WATCHER_SELF_RESTART=on, the note the sibling merge now raises
# drains the gate and re-execs, instead of sitting on the console for hours. The exec itself is stubbed
# (this process must never replace its own image); the DECISION is what is under test.
reset_state
_watch_record_start_head
seat_push scripts/herd/sweep.sh "sweep v2 — scratch-worktree reaper" "fix(sweep): reap dead scratch worktrees"
reconcile_main_freshness
[ -s "$MAIN_FRESH_RESTART" ]         || fail "(24) the sibling merge did not arm the note"
EXECED=""
_self_restart_exec() { EXECED="$1"; return 0; }
_SELF_RESTART_ARMED=""; _SELF_RESTART_IDLE_TICKS=0; _SELF_RESTART_GAVE_UP=""
export WATCHER_SELF_RESTART=on
_self_restart_tick                                          # arms the quiesce; 0 workers → idle=1
_self_restart_quiescing              || fail "(24) the note did not arm the quiesce"
_self_restart_hold_dispatch          || fail "(24) the quiesce is not holding new gate dispatch"
[ -z "$EXECED" ]                     || fail "(24) restarted after a single quiet tick"
_self_restart_tick                                          # idle=2 → re-exec
[ "$EXECED" = "drained" ]            || fail "(24) the self-restart never fired after the drain (got '${EXECED:-<none>}')"
jhas 'watcher_quiesce reason engine-update'                 || fail "(24) the quiesce was not journaled: $(cat "$JLOG")"
# …and with the lever OFF the same note only RECOMMENDS a restart: no quiesce, no hold, no exec.
reset_state; _watch_record_start_head
seat_push scripts/herd/sweep.sh "sweep v3" "fix(sweep): another sibling change"
reconcile_main_freshness
[ -s "$MAIN_FRESH_RESTART" ]         || fail "(24) lever-off: the note must still be raised"
EXECED=""; _SELF_RESTART_ARMED=""; _SELF_RESTART_IDLE_TICKS=0; _SELF_RESTART_GAVE_UP=""
WATCHER_SELF_RESTART=off _self_restart_tick
WATCHER_SELF_RESTART=off _self_restart_tick
_self_restart_quiescing              && fail "(24) lever-off armed the quiesce"
[ -z "$EXECED" ]                     || fail "(24) lever-off re-execed the watcher"
build_main_freshness
case "${MAIN_FRESHNESS:-}" in *"restart recommended"*) ;; *) fail "(24) lever-off lost the recommendation row: ${MAIN_FRESHNESS:-<empty>}" ;; esac
unset WATCHER_SELF_RESTART
ok

echo "PASS: test-main-freshness.sh ($pass checks)"
