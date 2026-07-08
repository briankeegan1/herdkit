#!/usr/bin/env bash
# test-spawn-queue-deps.sh — hermetic test of dependency-aware spawn ordering (HERD-94): an intent may
# carry an after=<slug|pr#> that HOLDS it in the durable queue until that dependency shows MERGED. No
# herdr, no network, no real lanes — the drain + its dependency helpers are EXTRACTED from
# agent-watch.sh (sed) and run in a harness with FAKE lane scripts and a STUBBED gh, exactly like
# test-spawn-queue-drain.sh.
#
# Under test:
#   1. spawn.sh HERD_SPAWN_AFTER=<x> writes the .after sidecar; spawn-step.sh next emits it as the
#      4th claim line; done/skip drop it, release KEEPS it (the hold survives a round-trip).
#   2. _spawn_dep_merged: empty dep = met; pr# matches the reap-ledger PR column; slug matches its
#      slug column; a gh MERGED fallback when the ledger is blind.
#   3. Concurrency: enqueue A and B(after=A) → B spawns ONLY after A merges, in FIFO order; spawn_held
#      journals ONCE (not per tick), spawn_released once at the release.
#   4. A stalled hold (older than DEP_STALE_TTL) surfaces a LOUD console row; build_spawn_holds GCs a
#      hold whose intent has vanished.
#
# Run:  bash tests/test-spawn-queue-deps.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
STEP="$HERE/../scripts/herd/spawn-step.sh"
SPAWN="$HERE/../scripts/herd/spawn.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# Fake engine dir: real spawn-step.sh + a stub herd-config.sh, scriptable fake lanes, and a stub gh
# on PATH so the dependency check's ledger-miss fallback never touches the network.
ENG="$T/eng"; mkdir -p "$ENG"
cp "$STEP" "$ENG/spawn-step.sh"
printf 'WORKTREES_DIR="%s"\nexport WORKTREES_DIR\n' "$T/trees" > "$ENG/herd-config.sh"
mkdir -p "$T/trees/spawn-queue"

BIN="$T/bin"; mkdir -p "$BIN"
# Stub gh: MERGED only for a branch/number listed in $GH_MERGED (space-separated); else empty (= not
# merged). `gh pr view <target> --json state -q .state`.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
target="$3"   # `gh pr view <target> --json ...`  → $1=pr $2=view $3=target
for m in $GH_MERGED; do [ "$m" = "$target" ] && { echo MERGED; exit 0; }; done
exit 0
GH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export GH_MERGED=""

# Hermetic project config for spawn.sh (pins WORKTREES_DIR into the test queue).
PROJ="$T/proj"; mkdir -p "$PROJ/.herd"
cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKSPACE_NAME="testws"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$T/trees"
EOF

LANELOG="$T/lane.log"
for lane in herd-feature.sh herd-quick.sh; do
  cat > "$ENG/$lane" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$1" >> "$LANELOG"
exit 0
FAKE
  chmod +x "$ENG/$lane"
done

# Harness: extract the drain + its HERD-94 dependency helpers, run one drain pass with stubbed
# journal_append and the tick globals it reads.
JLOG="$T/journal.log"
DRAIN_SRC="$T/drain.sh"
: > "$DRAIN_SRC"
for fn in _spawn_dep_merged _spawn_held_epoch _spawn_mark_held _spawn_clear_held _drain_spawn_queue; do
  sed -n "/^$fn()/,/^}/p" "$WATCH" >> "$DRAIN_SRC"
  grep -q "^$fn()" "$DRAIN_SRC" || fail "could not extract $fn from agent-watch.sh"
done

STATE="$T/trees/.agent-watch-merged"
SPAWN_HELD_STATE="$T/trees/.agent-watch-spawn-held"

run_drain() {
  ( export LANELOG JLOG
    HERE="$ENG"; TREES="$T/trees"; FEATS=()
    REVIEW_CONCURRENCY=2; SPAWN_AHEAD=1; DRYRUN=""
    STATE="$STATE"; SPAWN_HELD_STATE="$SPAWN_HELD_STATE"; DEP_STALE_TTL="${DEP_STALE_TTL:-86400}"
    journal_append(){ printf '%s\n' "$*" >> "$JLOG"; }
    # shellcheck source=/dev/null
    . "$DRAIN_SRC"
    _drain_spawn_queue )
}

enqueue(){ ( cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$SPAWN" "$@" >/dev/null ); }

# ── Case 1: spawn.sh writes the .after sidecar; spawn-step.sh threads it through next/release/done ──
rm -f "$T/trees/spawn-queue"/*
HERD_SPAWN_AFTER="dep-slug" enqueue slug-dep feature "task with a dep"
aft=$(ls "$T/trees/spawn-queue"/*.after 2>/dev/null | head -1)
[ -n "$aft" ] && [ "$(cat "$aft")" = "dep-slug" ] || fail "spawn.sh did not write the .after sidecar (dep-slug)"
# next emits: CLAIMED, slug, lane, ref(empty), after, task
out="$(WORKTREES_DIR="$T/trees" bash "$ENG/spawn-step.sh" next)"
[ "$(printf '%s\n' "$out" | sed -n '5p')" = "dep-slug" ] || fail "spawn-step next did not emit the after dep on line 5 (got: $(printf '%s' "$out" | sed -n '5p'))"
[ "$(printf '%s\n' "$out" | sed -n '6p')" = "task with a dep" ] || fail "task text shifted off line 6 after the after line"
mine=$(ls "$T/trees/spawn-queue"/*.mine | head -1)
# release KEEPS the .after sidecar (the hold must survive a round-trip)
WORKTREES_DIR="$T/trees" bash "$ENG/spawn-step.sh" release "$mine"
ls "$T/trees/spawn-queue"/*.after >/dev/null 2>&1 || fail "release dropped the .after sidecar — the dependency hold would be lost"
# done DROPS the .after sidecar
mine2=$(ls "$T/trees/spawn-queue"/*.req | head -1); mv "$mine2" "$mine2.mine"
WORKTREES_DIR="$T/trees" bash "$ENG/spawn-step.sh" done "$mine2.mine"
ls "$T/trees/spawn-queue"/*.after >/dev/null 2>&1 && fail "done left an orphan .after sidecar behind"
pass

# ── Case 2: an intent with NO after= is byte-identical (no sidecar, drains immediately) ─────────────
rm -f "$T/trees/spawn-queue"/*
enqueue slug-plain quick "no dependency"
ls "$T/trees/spawn-queue"/*.after >/dev/null 2>&1 && fail "a no-after enqueue must not create an .after sidecar"
: > "$LANELOG"; : > "$JLOG"; GH_MERGED=""
run_drain
grep -q "herd-quick.sh slug-plain" "$LANELOG" || fail "a no-after intent should spawn immediately"
ls "$T/trees/spawn-queue"/*.req >/dev/null 2>&1 && fail "no-after intent was not consumed"
pass

# ── Case 3: concurrency — B(after=A) spawns ONLY after A merges; spawn_held once, released once ─────
rm -f "$T/trees/spawn-queue"/* "$STATE" "$SPAWN_HELD_STATE"
enqueue slug-a feature "build A first"
HERD_SPAWN_AFTER="slug-a" enqueue slug-b feature "build B after A"

# Tick 1 — A unmerged (empty ledger, gh not-merged): A spawns, B held.
: > "$LANELOG"; : > "$JLOG"; GH_MERGED=""
run_drain
grep -q "herd-feature.sh slug-a" "$LANELOG" || fail "A (no dep) should spawn on tick 1"
grep -q "herd-feature.sh slug-b" "$LANELOG" && fail "B(after=A) must NOT spawn while A is unmerged"
ls "$T/trees/spawn-queue"/*.req >/dev/null 2>&1 || fail "held B should survive as .req (released at tick end)"
grep -q "spawn_held slug slug-b lane feature after slug-a" "$JLOG" || fail "spawn_held (with the dep named) not journaled ($(cat "$JLOG"))"
awk '$1=="slug-b" || $3=="slug-b"{f=1} END{exit !f}' "$SPAWN_HELD_STATE" 2>/dev/null || fail "B not recorded in the held-state ledger"

# Tick 2 — A still unmerged: B held again, but spawn_held must NOT re-journal (once per intent).
: > "$LANELOG"; : > "$JLOG"; GH_MERGED=""
run_drain
grep -q "herd-feature.sh slug-b" "$LANELOG" && fail "B must still be held on tick 2 while A is unmerged"
grep -q "spawn_held" "$JLOG" && fail "spawn_held re-journaled on a later tick (must be once per intent)"

# Tick 3 — A now MERGED (reap ledger row: '<epoch> <pr> <slug>'): B releases and spawns, FIFO.
printf '%s 42 slug-a\n' "$(date +%s)" >> "$STATE"
: > "$LANELOG"; : > "$JLOG"; GH_MERGED=""
run_drain
grep -q "herd-feature.sh slug-b" "$LANELOG" || fail "B should spawn once A is MERGED"
ls "$T/trees/spawn-queue"/*.req >/dev/null 2>&1 && fail "released B was not consumed after spawning"
grep -q "spawn_released slug slug-b lane feature after slug-a" "$JLOG" || fail "spawn_released (with the dep named) not journaled ($(cat "$JLOG"))"
awk '$1=="slug-b" || $3=="slug-b"{f=1} END{exit f}' "$SPAWN_HELD_STATE" 2>/dev/null || fail "B's held-state row not cleared after release"
pass

# ── Case 4: gh MERGED fallback — dependency by pr#, ledger blind, gh says merged → spawns ───────────
rm -f "$T/trees/spawn-queue"/* "$STATE" "$SPAWN_HELD_STATE"
HERD_SPAWN_AFTER="#77" enqueue slug-c feature "build C after PR 77"
[ "$(cat "$T/trees/spawn-queue"/*.after)" = "77" ] || fail "spawn.sh should strip a leading '#' from a pr# dep"
: > "$LANELOG"; : > "$JLOG"; GH_MERGED="77"   # gh reports #77 MERGED even though the ledger is empty
run_drain
grep -q "herd-feature.sh slug-c" "$LANELOG" || fail "C(after=#77) should spawn when gh reports the PR MERGED"
pass

# ── Case 5: _spawn_dep_merged unit checks (empty=met, pr# + slug ledger columns) ────────────────────
( STATE="$STATE"; SPAWN_HELD_STATE="$SPAWN_HELD_STATE"; DRYRUN=""
  # shellcheck source=/dev/null
  . "$DRAIN_SRC"
  printf '111 99 landed-slug\n' > "$STATE"
  GH_MERGED=""
  _spawn_dep_merged ""            || exit 11   # empty dependency is trivially met
  _spawn_dep_merged 99            || exit 12   # pr# matches the ledger PR column
  _spawn_dep_merged landed-slug   || exit 13   # slug matches the ledger slug column
  _spawn_dep_merged 12345         && exit 14   # absent pr# → not met (gh empty)
  _spawn_dep_merged missing-slug  && exit 15   # absent slug → not met (gh empty)
  exit 0
) || fail "_spawn_dep_merged unit check failed (code $?)"
pass

# ── Case 6: build_spawn_holds — a stalled hold is LOUD; a fresh one is calm; vanished intents GC ────
BUILD_SRC="$T/build.sh"; : > "$BUILD_SRC"
for fn in _slug_ref_file _slug_ref _slug_cell _fmt_age build_spawn_holds; do
  sed -n "/^$fn()/,/^}/p" "$WATCH" >> "$BUILD_SRC"
  grep -q "^$fn()" "$BUILD_SRC" || fail "could not extract $fn from agent-watch.sh"
done
run_holds() {
  ( TREES="$T/trees"; SPAWN_HELD_STATE="$SPAWN_HELD_STATE"; DEP_STALE_TTL="$1"; SLUGW=28
    C_RESET='' C_DIM='' C_RED='<RED>' C_YELLOW='<YEL>' C_GREEN='' C_CYAN=''
    # shellcheck source=/dev/null
    . "$BUILD_SRC"
    build_spawn_holds
    printf '%s' "$SPAWN_HOLDS" )
}
now=$(date +%s)
rm -f "$T/trees/spawn-queue"/*
# A hold whose intent still exists, held 10000s ago → stalled at TTL=1.
printf '%s %s held-slug feature dep-x\n' "int-old" "$(( now - 10000 ))" > "$SPAWN_HELD_STATE"
: > "$T/trees/spawn-queue/int-old.req"
holds="$(run_holds 1)"
printf '%s' "$holds" | grep -q "stalled" || fail "an over-TTL hold must render a 'stalled' row ($holds)"
printf '%s' "$holds" | grep -q "<RED>"  || fail "a stalled hold must be LOUD (red) ($holds)"
printf '%s' "$holds" | grep -q "after dep-x" || fail "the hold row must name the dependency"
# Same hold under a generous TTL → calm 'waiting', not stalled.
holds="$(run_holds 86400)"
printf '%s' "$holds" | grep -q "waiting" || fail "an under-TTL hold must render a calm 'waiting' row ($holds)"
printf '%s' "$holds" | grep -q "stalled" && fail "an under-TTL hold must NOT be stalled ($holds)"
# GC: a held row whose intent has vanished (operator cleared the .req) is pruned from the ledger.
rm -f "$T/trees/spawn-queue/int-old.req"
holds="$(run_holds 1)"
[ -z "$holds" ] || fail "a hold for a vanished intent should not render ($holds)"
grep -q "int-old" "$SPAWN_HELD_STATE" 2>/dev/null && fail "build_spawn_holds must GC the vanished intent's row"
pass

# ── Case 7 (HERD-116): an aged, dependency-held intent must NOT spin the drain ──────────────────────
# Regression for the watcher freeze. spawn-step.sh `next` reclaims abandoned `.mine` claims via
# `find -mmin +5`, but `mv` preserves mtime — so an intent enqueued >5 min ago (a dependency-held one
# lingers for exactly this long) used to be reclaimed-and-re-served on EVERY `next` within a single
# drain tick: claim → dep-check → held/continue → the next `next` sees a >5min `.mine`, resurrects it,
# re-serves the SAME intent — an unbounded loop with a `gh pr view` per pass that starved the watcher.
# The fix: `next` touches the claim on claim and `release` touches on release, so `-mmin +5` measures
# CLAIM age, not enqueue age. One tick now serves an aged held intent EXACTLY ONCE, then releases it;
# a genuinely abandoned claim still ages past 5 min from its last touch (legitimate reclaim preserved).
rm -f "$T/trees/spawn-queue"/* "$STATE" "$SPAWN_HELD_STATE"
HERD_SPAWN_AFTER="dep-unmerged" enqueue slug-aged feature "aged held intent, older than the stale TTL"
# Backdate the intent + sidecars well past the 5-minute stale window (fixed epoch — no date math, so
# this is identical on macOS/BSD and Linux) to reproduce the exact "enqueued long ago, still held" case.
touch -t 202001010000 "$T/trees/spawn-queue"/*.req "$T/trees/spawn-queue"/*.after
# Counting gh: log every dep-check. After a small safety cap it reports MERGED so that if the spin is
# ever reintroduced the tick TERMINATES (and these assertions fail loudly) instead of hanging forever.
GHCOUNT="$T/gh.count"; : > "$GHCOUNT"; export GHCOUNT
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
echo x >> "$GHCOUNT"
[ "$(wc -l < "$GHCOUNT")" -gt 2 ] && { echo MERGED; exit 0; }  # break any reintroduced spin
exit 0   # empty = dependency not merged
GH
chmod +x "$BIN/gh"
: > "$LANELOG"; : > "$JLOG"
run_drain   # must return; on the buggy code the safety cap trips and the assertions below catch it
[ "$(wc -l < "$GHCOUNT")" -eq 1 ] || fail "aged held intent triggered $(wc -l < "$GHCOUNT") dep-checks in one tick — expected exactly 1 (stale-reclaim spin)"
grep -q "herd-feature.sh slug-aged" "$LANELOG" && fail "an aged, dependency-held intent must NOT spawn while its dep is unmerged"
ls "$T/trees/spawn-queue"/*.req >/dev/null 2>&1 || fail "aged held intent should be released back to .req at tick end"
ls "$T/trees/spawn-queue"/*.after >/dev/null 2>&1 || fail "aged held intent lost its .after sidecar — the dependency hold would be dropped"
find "$T/trees/spawn-queue" -name '*.req' -mmin +5 | grep -q . && fail "released intent is still >5min stale — the claim/release touch did not restart the stale clock"
grep -q "spawn_held slug slug-aged lane feature after dep-unmerged" "$JLOG" || fail "aged held intent should journal spawn_held once ($(cat "$JLOG"))"
# Restore the shared not-merged gh stub for any later cases.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
target="$3"
for m in $GH_MERGED; do [ "$m" = "$target" ] && { echo MERGED; exit 0; }; done
exit 0
GH
chmod +x "$BIN/gh"
pass

echo "ALL PASS ($PASS checks)"
