#!/usr/bin/env bash
# test-spawn-queue-drain.sh — hermetic test of the watcher's durable spawn-queue drain
# (_drain_spawn_queue in agent-watch.sh + spawn-step.sh queue mechanics). No herdr, no network,
# no real lanes: the drain function is EXTRACTED from agent-watch.sh (sed) and run in a harness
# with FAKE herd-feature.sh / herd-quick.sh lane scripts whose behavior each case scripts.
#
# The durability contract under test (BLOCK review on PR #151): an intent is consumed ONLY when
# its lane observably spawned —
#   1. lane spawns (exit 0, quiet)             → intent consumed, journal spawn_launched, and a
#      MULTI-LINE task reaches the lane intact (read-one-line would truncate it).
#   2. lane defers (exit 0 + 'review-gate saturated') → intent RELEASED back to .req for a later
#      tick, journal spawn_deferred, and the drain STOPS this tick (sibling intent not claimed).
#   3. lane hard-fails (exit 1)                → intent dropped LOUDLY: journal spawn_skipped
#      with the exit code (never a silent disappearance).
# Plus: spawn-step.sh release round-trips .req.mine → .req byte-identically.
#
# Run:  bash tests/test-spawn-queue-drain.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"
STEP="$HERE/../scripts/herd/spawn-step.sh"
SPAWN="$HERE/../scripts/herd/spawn.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# Fake engine dir: real spawn-step.sh + a stub herd-config.sh it sources (only WORKTREES_DIR is
# needed), plus scriptable fake lanes. The extracted drain calls "$HERE/<lane>.sh" so HERE must
# point here inside the harness.
ENG="$T/eng"; mkdir -p "$ENG"
cp "$STEP" "$ENG/spawn-step.sh"
printf 'WORKTREES_DIR="%s"\nexport WORKTREES_DIR\n' "$T/trees" > "$ENG/herd-config.sh"
mkdir -p "$T/trees/spawn-queue"

# Hermetic project config: spawn.sh sources the REAL herd-config.sh, which resolves the project's
# .herd/config and would override an ambient WORKTREES_DIR — pin it via HERD_CONFIG_FILE (the same
# seam every other CLI test uses) so intents can NEVER land in a real project's spawn queue.
PROJ="$T/proj"; mkdir -p "$PROJ/.herd"
cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKSPACE_NAME="testws"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
WORKTREES_DIR="$T/trees"
EOF

LANELOG="$T/lane.log"
# Fake lanes: mode via $LANE_MODE file — 'ok' (quiet exit 0), 'defer' (saturation marker, exit 0),
# 'fail' (exit 1). Each invocation logs "<script> <slug>" and the task payload (verbatim) for
# multi-line assertions.
for lane in herd-feature.sh herd-quick.sh; do
  cat > "$ENG/$lane" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$1" >> "$LANELOG"
printf 'TASK<<%s>>\n' "$2" >> "$LANELOG"
case "$(cat "$LANE_MODE" 2>/dev/null)" in
  defer) printf '⏸️  review-gate saturated — holding spawn until a slot opens (slug: %s)\n' "$1"; exit 0 ;;
  fail)  echo "boom: transient git failure" >&2; exit 1 ;;
  *)     exit 0 ;;
esac
FAKE
  chmod +x "$ENG/$lane"
done

# Harness: extract _drain_spawn_queue from agent-watch.sh and run one drain pass with stubbed
# journal_append (logs events) and the tick globals it reads (TREES, FEATS, caps, HERE).
JLOG="$T/journal.log"
DRAIN_SRC="$T/drain.sh"
sed -n '/^_drain_spawn_queue()/,/^}/p' "$WATCH" > "$DRAIN_SRC"
grep -q '_drain_spawn_queue()' "$DRAIN_SRC" || fail "could not extract _drain_spawn_queue from agent-watch.sh"

run_drain() {
  ( export LANELOG LANE_MODE="$T/lane.mode" JLOG
    HERE="$ENG"; TREES="$T/trees"; FEATS=()
    REVIEW_CONCURRENCY=2; SPAWN_AHEAD=1; DRYRUN=""
    journal_append(){ printf '%s\n' "$*" >> "$JLOG"; }
    # shellcheck source=/dev/null
    . "$DRAIN_SRC"
    _drain_spawn_queue )
}

enqueue(){ ( cd "$PROJ" && HERD_CONFIG_FILE="$PROJ/.herd/config" bash "$SPAWN" "$@" >/dev/null ); }
# Guard the guard: an enqueue must land in the TEST queue, or every later assertion is meaningless
# (and a real project queue was just polluted). Fail immediately if the seam ever breaks.
enqueue probe quick "hermetic probe" \
  && ls "$T/trees/spawn-queue"/*.req >/dev/null 2>&1 \
  || fail "hermetic enqueue seam broken — intent did not land in the test queue"
rm -f "$T/trees/spawn-queue"/*.req

# ── Case 1: lane spawns → intent consumed, spawn_launched, multi-line task intact ───────────────
MULTI="line one of the spec
line two: edge cases
line three: verify"
enqueue slug-ok quick "$MULTI"
echo ok > "$T/lane.mode"; : > "$LANELOG"; : > "$JLOG"
run_drain
ls "$T/trees/spawn-queue" | grep -q . && fail "spawned intent was not consumed ($(ls "$T/trees/spawn-queue"))"
grep -q "herd-quick.sh slug-ok" "$LANELOG" || fail "quick lane was not invoked for slug-ok"
grep -q "line two: edge cases" "$LANELOG" || fail "multi-line task truncated before the lane saw it"
grep -q "spawn_launched slug slug-ok lane quick" "$JLOG" || fail "spawn_launched not journaled ($(cat "$JLOG"))"
pass

# ── Case 2: lane defers → intent released back to .req, spawn_deferred, drain stops this tick ───
enqueue slug-held feature "first held task"
enqueue slug-second feature "second task behind the gate"
echo defer > "$T/lane.mode"; : > "$LANELOG"; : > "$JLOG"
run_drain
reqs=$(ls "$T/trees/spawn-queue"/*.req 2>/dev/null | wc -l | tr -d ' ')
[ "$reqs" = "2" ] || fail "deferred intents must BOTH survive as .req (found $reqs; held one lost = the exact BLOCK bug)"
ls "$T/trees/spawn-queue"/*.mine 2>/dev/null | grep -q . && fail "release left a .mine claim behind"
grep -q "spawn_deferred slug slug-held lane feature" "$JLOG" || fail "spawn_deferred not journaled ($(cat "$JLOG"))"
[ "$(grep -c '^herd-feature.sh' "$LANELOG")" = "1" ] || fail "drain must STOP after a defer (siblings defer against the same gate)"
pass

# ── Case 3: lane hard-fails → intent dropped LOUDLY (journal spawn_skipped with exit code) ──────
rm -f "$T/trees/spawn-queue"/*.req
enqueue slug-bad quick "task that will fail to launch"
echo fail > "$T/lane.mode"; : > "$LANELOG"; : > "$JLOG"
run_drain
ls "$T/trees/spawn-queue" | grep -q . && fail "hard-failed intent should be dropped (with a loud journal trail)"
grep -q "spawn_skipped slug slug-bad lane quick reason lane exited 1" "$JLOG" \
  || fail "spawn_skipped (lane exited 1) not journaled ($(cat "$JLOG"))"
pass

# ── Case 4: spawn-step.sh release round-trips the claim byte-identically ────────────────────────
enqueue slug-rt quick "round trip payload"
f=$(ls "$T/trees/spawn-queue"/*.req | head -1)
before=$(cat "$f")
WORKTREES_DIR="$T/trees" bash "$ENG/spawn-step.sh" next >/dev/null
mine=$(ls "$T/trees/spawn-queue"/*.mine | head -1)
WORKTREES_DIR="$T/trees" bash "$ENG/spawn-step.sh" release "$mine"
after=$(cat "$f" 2>/dev/null) || fail "release did not restore the .req file"
[ "$before" = "$after" ] || fail "release altered the intent payload"
pass

echo "ALL PASS ($PASS checks)"
