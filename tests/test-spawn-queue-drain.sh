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
#   4. HERD-237: the lane runs in a BACKGROUND worker, so its claim now OUTLIVES the tick. The
#      five-minute stale reclaim in `next` must therefore be LIVENESS-aware: an in-flight lane's claim
#      is never re-served (which would spawn the same slug twice), while a genuinely abandoned claim
#      still ages out. And done/release/skip fail LOUD on a claim that has vanished, so a lost claim
#      can never be journaled as a spawn_launched.
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
  slow)  sleep 3; exit 0 ;;
  *)     exit 0 ;;
esac
FAKE
  chmod +x "$ENG/$lane"
done

# Harness: extract _drain_spawn_queue from agent-watch.sh and run one drain pass with stubbed
# journal_append (logs events) and the tick globals it reads (TREES, FEATS, caps, HERE).
JLOG="$T/journal.log"
DRAIN_SRC="$T/drain.sh"
: > "$DRAIN_SRC"
# HERD-237: the drain now fires its lane through a background worker guarded by an inflight marker,
# so the harness needs the worker + the marker helpers alongside _drain_spawn_queue itself.
for fn in _spawn_inflight_file _spawn_inflight_bg _spawn_inflight_sweep _lane_spawn_inflight \
          _drain_lane_worker _drain_spawn_queue; do
  sed -n "/^$fn()/,/^}/p" "$WATCH" >> "$DRAIN_SRC"
  grep -q "^$fn()" "$DRAIN_SRC" || fail "could not extract $fn from agent-watch.sh"
done

# run_drain — one tick's drain. HERD-237: the lane runs in a BACKGROUND worker, so the tick returns
# before the intent is consumed; `wait` synchronizes on that worker exactly as the next tick's
# _lane_spawn_inflight marker check would, and every assertion below still reads a settled queue.
run_drain() {
  ( export LANELOG LANE_MODE="$T/lane.mode" JLOG
    HERE="$ENG"; TREES="$T/trees"; FEATS=()
    SPAWN_INFLIGHT_PREFIX="$T/trees/.spawn-inflight-"
    _marker_write(){ printf '%s\n' "$2" > "$1" 2>/dev/null || true; }
    _marker_live(){ local p; p="$(sed -n 1p "$1" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
    REVIEW_CONCURRENCY=2; SPAWN_AHEAD=1; DRYRUN=""
    # HERD-95: the drain now consults budget_daily_exceeded + the _BUDGET_DRAIN_PAUSED tick state.
    # Stub the predicate DORMANT (return 1) and init the state so these cases test the drain path
    # under a no-budget watcher — byte-identical to pre-HERD-95 behavior. The budget PAUSE path is
    # covered by tests/test-budget-governance.sh.
    _BUDGET_DRAIN_PAUSED=""
    budget_daily_exceeded(){ return 1; }
    journal_append(){ printf '%s\n' "$*" >> "$JLOG"; }
    # shellcheck source=/dev/null
    . "$DRAIN_SRC"
    _drain_spawn_queue
    wait )
}

# run_drain_nowait — one tick's drain that does NOT wait for the lane worker, leaving it running
# (orphaned) exactly as a real tick does. Records the worker's pid so the caller can poll it.
run_drain_nowait() {
  ( export LANELOG LANE_MODE="$T/lane.mode" JLOG
    HERE="$ENG"; TREES="$T/trees"; FEATS=()
    SPAWN_INFLIGHT_PREFIX="$T/trees/.spawn-inflight-"
    _marker_write(){ printf '%s\n' "$2" > "$1" 2>/dev/null || true; }
    _marker_live(){ local p; p="$(sed -n 1p "$1" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
    REVIEW_CONCURRENCY=2; SPAWN_AHEAD=1; DRYRUN=""
    _BUDGET_DRAIN_PAUSED=""
    budget_daily_exceeded(){ return 1; }
    journal_append(){ printf '%s\n' "$*" >> "$JLOG"; }
    # shellcheck source=/dev/null
    . "$DRAIN_SRC"
    _drain_spawn_queue
    # _spawn_inflight_bg records the worker's pid. (Do NOT use $! here: the drain's own `next` runs
    # through a process substitution, which reassigns $! in bash.)
    printf '%s' "${_SPAWN_INFLIGHT_BG_PID:-}" > "$T/bgpid" )
}
# age <file> — backdate mtime past `next`'s 5-minute stale threshold (python3 is a herd hard dep).
age(){ python3 -c 'import os,sys,time; t=time.time()-600; os.utime(sys.argv[1],(t,t))' "$1"; }
# await_pid <pid> — poll until it exits (it is orphaned, so `wait` cannot reap it).
await_pid(){ local p="$1" n=0; while [ -n "$p" ] && kill -0 "$p" 2>/dev/null && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n+1)); done; }
step(){ WORKTREES_DIR="$T/trees" bash "$ENG/spawn-step.sh" "$@"; }

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

# ── Case 5: a LONG-RUNNING lane's claim is never stale-reclaimed (HERD-237 double-spawn regression) ─
# The exact race the review caught: `next` age-reclaims any .req.mine older than 5 min. With the lane
# backgrounded, an in-flight claim routinely gets that old, and re-serving it launches the SAME slug a
# second time. A live owner must keep its claim; the sibling intent must still be servable.
rm -f "$T/trees/spawn-queue"/* "$T/trees"/.spawn-inflight-* 2>/dev/null
enqueue slug-slow feature "a lane slower than the five-minute stale threshold"
enqueue slug-next feature "an independent sibling behind it"
echo slow > "$T/lane.mode"; : > "$LANELOG"; : > "$JLOG"
run_drain_nowait
BG="$(cat "$T/bgpid" 2>/dev/null || true)"
[ -n "$BG" ] || fail "(5) the drain launched no background lane worker"
mine="$(ls "$T/trees/spawn-queue"/*.req.mine 2>/dev/null | head -1)"
[ -n "$mine" ] || fail "(5) no claim is held while the lane runs"
[ -f "${mine%.req.mine}.owner" ] || fail "(5) the drain did not bind the claim to its lane worker (.owner)"
[ "$(head -1 "${mine%.req.mine}.owner")" = "$BG" ] || fail "(5) .owner names the wrong pid"

age "$mine"                                   # tick N+75: the claim is now 10 minutes old
out="$(step next)"
line1="${out%%$'\n'*}"
[ -f "$mine" ] || fail "(5) an IN-FLIGHT claim was stale-reclaimed — the lane will be launched twice"
case "$line1" in
  CLAIMED*) : ;;
  *) fail "(5) next did not serve the independent sibling (got: $line1)" ;;
esac
case "$line1" in
  *"$(basename "${mine%.req.mine}")"*) fail "(5) next re-served the in-flight intent itself" ;;
esac
step release "${line1#CLAIMED }" >/dev/null 2>&1 || true

await_pid "$BG"                               # the lane finally lands
[ "$(grep -c '^herd-feature.sh slug-slow' "$LANELOG")" = "1" ] \
  || fail "(5) slug-slow's lane ran $(grep -c '^herd-feature.sh slug-slow' "$LANELOG")× (double-spawn)"
grep -q "spawn_launched slug slug-slow" "$JLOG" || fail "(5) the landed lane never journaled spawn_launched"
grep -q "spawn_claim_lost" "$JLOG" && fail "(5) the worker lost its claim ($(cat "$JLOG"))"
ls "$T/trees/spawn-queue"/*.owner >/dev/null 2>&1 && fail "(5) an owner sidecar leaked past its worker"
pass

# ── Case 6: an ABANDONED claim (dead owner) still ages out, and its sidecar is cleaned ──────────────
# Liveness, not immortality: a watcher killed mid-spawn must not wedge its intent in the queue forever.
rm -f "$T/trees/spawn-queue"/* 2>/dev/null
enqueue slug-abandoned quick "claimed by a watcher that then died"
step next >/dev/null
mine="$(ls "$T/trees/spawn-queue"/*.req.mine | head -1)"
sleep 300 & DEADPID=$!
step own "$mine" "$DEADPID" >/dev/null
kill "$DEADPID" 2>/dev/null; wait "$DEADPID" 2>/dev/null || true
age "$mine"
out="$(step next)"
case "${out%%$'\n'*}" in
  CLAIMED*) : ;;
  *) fail "(6) an abandoned claim was not reclaimed after its owner died (got: ${out%%$'\n'*})" ;;
esac
ls "$T/trees/spawn-queue"/*.owner >/dev/null 2>&1 && fail "(6) the dead owner's sidecar was not cleaned"
pass

# ── Case 7: done/release/skip FAIL LOUD on a claim that has vanished ────────────────────────────────
# A silent `rm -f` on a moved path is how a lost claim becomes a phantom spawn_launched.
rm -f "$T/trees/spawn-queue"/* 2>/dev/null
enqueue slug-ghost quick "claim that will vanish under the worker"
step next >/dev/null
mine="$(ls "$T/trees/spawn-queue"/*.req.mine | head -1)"
rm -f "$mine"                                  # simulate: reclaimed (or already consumed) under us
for verb in done release skip; do
  if step "$verb" "$mine" "reason" >/dev/null 2>&1; then
    fail "(7) spawn-step $verb silently no-op'd a vanished claim (a lost claim reads as a success)"
  fi
done
pass

# ── Case 8: the worker journals spawn_claim_lost (never spawn_launched) when its claim is gone ──────
rm -f "$T/trees/spawn-queue"/* "$T/trees"/.spawn-inflight-* 2>/dev/null
enqueue slug-lost quick "its claim disappears mid-lane"
echo ok > "$T/lane.mode"; : > "$LANELOG"; : > "$JLOG"
( export LANELOG LANE_MODE="$T/lane.mode" JLOG
  HERE="$ENG"; TREES="$T/trees"
  journal_append(){ printf '%s\n' "$*" >> "$JLOG"; }
  # shellcheck source=/dev/null
  . "$DRAIN_SRC"
  _drain_lane_worker "$T/trees/spawn-queue/nonexistent.req.mine" slug-lost quick "" "task" )
grep -q "spawn_claim_lost slug slug-lost lane quick action done" "$JLOG" \
  || fail "(8) a worker whose claim vanished did not journal spawn_claim_lost ($(cat "$JLOG"))"
grep -q "spawn_launched" "$JLOG" && fail "(8) a worker with no claim journaled a phantom spawn_launched"
pass

# ── Case 9: `release` is a single atomic rename — it can never create a phantom empty .req ─────────
# `release` used to `mv` then `touch "$released"`. Backgrounded, it runs concurrently with the parent
# tick's `next`: if `next` re-claims the just-released intent in that gap, the trailing `touch` CREATES
# an empty <id>.req beside the live <id>.req.mine. Assert the touch happens BEFORE the rename, so the
# window does not exist — and that the released intent still gets a fresh stale-clock (HERD-116).
rm -f "$T/trees/spawn-queue"/* 2>/dev/null
enqueue slug-rel quick "release round-trip"
step next >/dev/null
mine="$(ls "$T/trees/spawn-queue"/*.req.mine | head -1)"
id="$(basename "${mine%.req.mine}")"
age "$mine"                                      # a stale-looking claim …
before_mtime="$(python3 -c 'import os,sys;print(int(os.stat(sys.argv[1]).st_mtime))' "$mine")"
step release "$mine" >/dev/null
released="$T/trees/spawn-queue/$id.req"
[ -f "$released" ] || fail "(9) release did not restore the .req"
[ "$(ls "$T/trees/spawn-queue"/*.req 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  || fail "(9) release produced more than one .req (a phantom empty intent)"
[ -s "$released" ] || fail "(9) the released intent is EMPTY — the phantom-.req race"
after_mtime="$(python3 -c 'import os,sys;print(int(os.stat(sys.argv[1]).st_mtime))' "$released")"
[ "$after_mtime" -gt "$before_mtime" ] || fail "(9) release did not restart the stale clock (HERD-116 spin)"
# And the release survives a `next` racing it: the claim it hands back is immediately re-servable.
out="$(step next)"
case "${out%%$'\n'*}" in CLAIMED*) : ;; *) fail "(9) a released intent was not re-servable" ;; esac
# The properties above hold for BOTH orderings; only the ORDER closes the interleaving window, and no
# black-box test can schedule that interleaving reliably. Assert the order itself, in the source.
python3 - "$STEP" <<'ORDER' || fail "(9) release must touch the CLAIM before renaming it — the mv-then-touch order recreates a phantom .req when next() wins the gap"
import re, sys
body = re.search(r'^  release\)(.*?)^    ;;', open(sys.argv[1]).read(), re.S | re.M).group(1)
t = body.index('touch "$mine"')
m = body.index('mv -f "$mine"')
sys.exit(0 if t < m else 1)
ORDER
pass

echo "ALL PASS ($PASS checks)"
