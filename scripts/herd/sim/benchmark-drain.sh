#!/usr/bin/env bash
# scripts/herd/sim/benchmark-drain.sh — herdkit-vs-harness FALSIFICATION BENCHMARK (stub mode).
#
# EPIC step 3 of "herdkit vs the raw Claude harness" (see docs/positioning-thesis.md + BACKLOG.md).
# The thesis names ONE falsifying workload the raw Claude harness architecturally cannot complete:
#
#     drain an N-item backlog, unattended, SURVIVING INTERRUPTIONS (limit resets, restarts).
#
# A single Workflow invocation dies with its session — its execution AND its memory of what was done
# both vanish, so there is nothing durable to resume from. herdkit survives because it externalizes
# BOTH halves: execution → detached processes, state → git + files + the backlog. This harness
# EXERCISES that claim IN STUB MODE (deterministic tiny changes, NO model call) so the real overnight
# run later is just this harness with real builders + real limit resets swapped in.
#
# What it does, reusing the sim conventions (sandbox-fixture.sh):
#   (1) SEED    — a local fixture repo (sandbox_fixture_build) with an N-item BACKLOG.md (N=10,
#                 flag-tunable), every item marked 🔜.
#   (2) DRAIN   — for each 🔜 item, simulate the full herdkit flow with a STUB builder:
#                 worktree branch off main → deterministic stub change committed → local pr.json
#                 record → fixture health gate → merge → teardown → mark the backlog item ✅ (edit
#                 the fixture BACKLOG.md exactly as the scribe would).
#   (3) KILL    — --kill-at K hard-exits (SIGKILL) the harness mid-drain after item K. A subsequent
#                 re-run must RESUME FROM DURABLE STATE ALONE — worktrees/branches/backlog on disk,
#                 no in-memory carryover — completing the remaining items without duplicating any
#                 already-shipped one. This is the restart-survival test of the time/presence thesis.
#   (4) SCORECARD — items drained, resumed-after-kill (bool), duplicates (must be 0), gate failures,
#                 wall-clock, written as JSON like sandbox-scenario.sh's.
#   (5) --real-builders — placeholder stub for the live run; prints and exits (see EPIC).
#
# Usage:
#   bash scripts/herd/sim/benchmark-drain.sh --state DIR [-n N] [--kill-at K] [--fresh]
#     --state DIR   DURABLE state/artifacts dir (fixture repo + scorecard live here). REQUIRED for
#                   the resume test — the re-run reads this dir and nothing else. (--artifacts alias.)
#     -n, --items N seeded backlog size (default 10).
#     --kill-at K   hard-exit (SIGKILL) after fully shipping the K-th item THIS run (crash injection).
#     --fresh       wipe the state dir and re-seed before draining (default: resume if already seeded).
#     --real-builders   print "not implemented in stub mode — see EPIC" and exit (live-run placeholder).
#
# Fault injection (a seed of the P1 fault matrix, off by default):
#   BENCH_GATE_FAIL_ITEM=NN   break the app in item NN's worktree so its gate FAILS LOUDLY; the item
#                             is NOT merged, stays 🔜, and is counted in gate_failures (never merged).
#
# Exit: 0 = drain complete + 0 duplicates + 0 gate failures · 1 = incomplete/failed · 137 = --kill-at.
#
# Hermetic: local git only, NO herdr, NO network, NO model. Does NOT touch bin/herd, agent-watch.sh,
# the lanes, fleet.sh, or any engine script — a pure sim rig alongside sandbox-scenario.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/herd/sim/sandbox-fixture.sh
. "$HERE/sandbox-fixture.sh"

# ── output helpers (mirror sandbox-scenario.sh's style) ─────────────────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s[%s]%s %s\n' "$c_bold" "$1" "$c_rst" "$2"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
skip() { printf '  %s–%s %s\n' "$c_yel" "$c_rst" "$*"; }
info() { printf '  %s→%s %s\n' "$c_dim" "$c_rst" "$*"; }

# ── args ────────────────────────────────────────────────────────────────────────
STATE=""; N=10; KILL_AT=""; FRESH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state|--artifacts) STATE="${2:-}"; shift 2 ;;
    -n|--items)          N="${2:-}"; shift 2 ;;
    --kill-at)           KILL_AT="${2:-}"; shift 2 ;;
    --fresh)             FRESH=1; shift ;;
    --real-builders)     echo "benchmark-drain: --real-builders not implemented in stub mode — see the herdkit-vs-harness EPIC in BACKLOG.md (live run = this harness with real builders + real limit resets)."; exit 0 ;;
    -h|--help)           grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "benchmark-drain: unknown arg: $1" >&2; exit 1 ;;
  esac
done
case "$N" in ''|*[!0-9]*) echo "benchmark-drain: --items must be a positive integer" >&2; exit 1 ;; esac
[ "$N" -ge 1 ] || { echo "benchmark-drain: --items must be >= 1" >&2; exit 1; }
if [ -n "$KILL_AT" ]; then
  case "$KILL_AT" in ''|*[!0-9]*) echo "benchmark-drain: --kill-at must be a positive integer" >&2; exit 1 ;; esac
fi
if [ -z "$STATE" ]; then
  STATE="$(mktemp -d)"
  echo "benchmark-drain: no --state given; using ephemeral $STATE (resume across runs needs a stable --state DIR)" >&2
fi
mkdir -p "$STATE"
# The state dir is DURABLE by construction — never auto-deleted. Resume depends on it surviving.

REPO="$STATE/repo"
PRDIR="$STATE/pr"
mkdir -p "$PRDIR"

# ── checkpoint recording (bash 3.2: parallel indexed arrays, no assoc arrays) ───────────────────
CP_NAMES=(); CP_STATUS=(); CP_DETAIL=()
_pass=0; _fail=0
checkpoint() {
  local name="$1" status="$2"; shift 2
  local detail="$*"
  detail="$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')"
  CP_NAMES+=("$name"); CP_STATUS+=("$status"); CP_DETAIL+=("$detail")
  case "$status" in
    pass) _pass=$((_pass+1)); ok "$name — $detail" ;;
    fail) _fail=$((_fail+1)); bad "$name — $detail" ;;
    skip) skip "$name — $detail" ;;
  esac
}

# ── backlog helpers (the durable state the resume reads) ────────────────────────────────────────
# Seed an N-item backlog in herdkit's 🔜 status-emoji format. Deterministic; two-digit item tokens.
_bench_seed_backlog() {
  local n="$1" out="$2" i tok
  {
    printf '# Benchmark BACKLOG\n\n'
    printf 'Seeded %d-item backlog for the herdkit-vs-harness FALSIFICATION drain benchmark.\n' "$n"
    printf 'Deterministic — do not hand-edit. The drain harness flips 🔜 → ✅ as the scribe would.\n\n'
    for ((i=1; i<=n; i++)); do
      tok="$(printf '%02d' "$i")"
      printf -- '- 🔜 **Item %s: seed feature %s** — deterministic benchmark work item %s.\n' "$tok" "$tok" "$tok"
    done
  } > "$out"
}
# Item tokens (NN) still 🔜, in file order. This IS the work-queue — read from disk, never memory.
_bench_pending_tokens() {
  awk -F'Item ' '/^- 🔜 \*\*Item [0-9]+:/ { n=$2; sub(/[^0-9].*/,"",n); print n }' "$REPO/BACKLOG.md"
}
_bench_count_shipped() { local c; c="$(grep -cE '^- ✅ \*\*Item [0-9]+:' "$REPO/BACKLOG.md" 2>/dev/null)"; echo "${c:-0}"; }
_bench_count_pending() { local c; c="$(grep -cE '^- 🔜 \*\*Item [0-9]+:' "$REPO/BACKLOG.md" 2>/dev/null)"; echo "${c:-0}"; }
# Flip item NN from 🔜 to ✅ — exactly as the scribe marks an item shipped. Portable (temp+mv).
_bench_mark_shipped() {
  local tok="$1"
  awk -v tok="$tok" '
    index($0, "**Item " tok ":") && index($0, "🔜") { gsub(/🔜/, "✅"); print; next }
    { print }
  ' "$REPO/BACKLOG.md" > "$REPO/BACKLOG.md.tmp" && mv "$REPO/BACKLOG.md.tmp" "$REPO/BACKLOG.md"
}

# ── SCORECARD emitter (machine-readable JSON, no jq/python dependency) ───────────────────────────
# Mirrors sandbox-scenario.sh's shape and ADDS the drain-specific fields the EPIC asks for:
# backlog_size, items_drained (cumulative ✅), drained_this_run, remaining, resumed_after_kill,
# duplicates (must be 0), gate_failures, wall_clock_s.
write_scorecard() {
  local out="$STATE/scorecard.json" result="$1"
  local skipped=0 i n
  n=${#CP_NAMES[@]}
  for ((i=0; i<n; i++)); do [ "${CP_STATUS[$i]}" = "skip" ] && skipped=$((skipped+1)); done
  {
    printf '{\n'
    printf '  "scenario": "%s",\n' "$SCENARIO"
    printf '  "artifacts_dir": "%s",\n' "$STATE"
    printf '  "repo_dir": "%s",\n' "$REPO"
    printf '  "backlog_size": %d,\n' "$N"
    printf '  "items_drained": %d,\n' "$SHIPPED_TOTAL"
    printf '  "drained_this_run": %d,\n' "$DRAINED_THIS_RUN"
    printf '  "remaining": %d,\n' "$REMAINING"
    printf '  "resumed_after_kill": %s,\n' "$RESUMED_AFTER_KILL"
    printf '  "duplicates": %d,\n' "$DUPLICATES"
    printf '  "gate_failures": %d,\n' "$GATE_FAILURES"
    printf '  "wall_clock_s": %d,\n' "$SECONDS"
    printf '  "result": "%s",\n' "$result"
    printf '  "passed": %d,\n' "$_pass"
    printf '  "failed": %d,\n' "$_fail"
    printf '  "skipped": %d,\n' "$skipped"
    printf '  "checkpoints": [\n'
    for ((i=0; i<n; i++)); do
      printf '    {"name": "%s", "status": "%s", "detail": "%s"}' \
        "${CP_NAMES[$i]}" "${CP_STATUS[$i]}" "${CP_DETAIL[$i]}"
      [ "$i" -lt "$((n-1))" ] && printf ',\n' || printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
  } > "$out"
  printf '%s' "$out"
}

# ── drain-run counters (all derived from disk at start; nothing carried in memory across runs) ──
DUPLICATES=0; GATE_FAILURES=0; DRAINED_THIS_RUN=0
SHIPPED_TOTAL=0; REMAINING="$N"; RESUMED_AFTER_KILL="false"
SECONDS=0

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s══ herdkit-vs-harness falsification benchmark (STUB drain) ══%s\n' "$c_bold" "$c_rst"
printf '  state: %s\n' "$STATE"

# ── seed OR resume: the whole restart-survival test hinges on this branch ────────────────────────
# The fixture ownership marker (.herd/.sandbox-sim-fixture) is the durable proof the repo is already
# seeded. If it is present we RESUME — we must NOT reseed (that would rm -rf the repo and wipe every
# shipped item). If absent (or --fresh) we seed from scratch.
[ -n "$FRESH" ] && rm -rf "$REPO"
if [ -f "$REPO/.herd/.sandbox-sim-fixture" ]; then
  step resume "durable state found — resuming from disk (no in-memory carryover)"
  SHIPPED_TOTAL="$(_bench_count_shipped)"
  info "backlog already seeded; $SHIPPED_TOTAL item(s) shipped before this run"
  # A run that inherits prior progress is, by definition, resuming after an interruption.
  [ "$SHIPPED_TOTAL" -gt 0 ] && RESUMED_AFTER_KILL="true"
  # Re-derive N from the durable backlog so the scorecard matches the state we actually resumed.
  N="$(( $(_bench_count_shipped) + $(_bench_count_pending) ))"
  checkpoint resumed_from_disk pass "resumed with $SHIPPED_TOTAL/$N already shipped (resumed_after_kill=$RESUMED_AFTER_KILL)"
else
  step seed "build deterministic fixture + seed $N-item backlog"
  sandbox_fixture_build "$REPO" >/dev/null || { bad "fixture build failed"; SCENARIO="drain-fresh"; write_scorecard fail >/dev/null; exit 1; }
  _bench_seed_backlog "$N" "$REPO/BACKLOG.md"
  _sf_git_env
  git -C "$REPO" add BACKLOG.md
  git -C "$REPO" commit -q -m "seed: $N-item benchmark backlog"
  SHIPPED_TOTAL=0
  checkpoint backlog_seeded pass "seeded $N items, all 🔜"
fi
SCENARIO="drain"; [ "$RESUMED_AFTER_KILL" = "true" ] && SCENARIO="drain-resumed"

# Defensive reconcile: prune any dangling worktrees left by a hard kill; the drain re-creates them.
git -C "$REPO" worktree prune 2>/dev/null || true

# ── DRAIN loop ──────────────────────────────────────────────────────────────────────────────────
step drain "draining 🔜 items with a STUB builder (worktree → stub → pr.json → gate → merge → scribe)"
PENDING="$(_bench_pending_tokens)"
if [ -z "$PENDING" ]; then
  info "no 🔜 items remaining — backlog already fully drained"
fi

for tok in $PENDING; do
  BRANCH="bench/item-$tok"
  WT="$STATE/worktrees/item-$tok"

  # DUPLICATE GUARD: if this item's feature already exists on main it was already shipped — a resume
  # must never re-ship it. (Should be impossible since we only iterate 🔜 items, but proven here.)
  if git -C "$REPO" cat-file -e "main:app/item-$tok.sh" 2>/dev/null; then
    DUPLICATES=$((DUPLICATES+1))
    checkpoint "item_${tok}_duplicate" fail "item $tok already on main but still 🔜 — duplicate attempt"
    continue
  fi

  # worktree branch off main (real git worktree — faithful to the herdkit lane flow).
  git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
  git -C "$REPO" branch -D "$BRANCH" 2>/dev/null || true
  rm -rf "$WT"
  _sf_git_env
  if ! git -C "$REPO" worktree add -q "$WT" -b "$BRANCH" main 2>/dev/null; then
    checkpoint "item_${tok}_worktree" fail "could not create worktree/branch for item $tok"
    continue
  fi

  # STUB builder: a deterministic tiny change (no model call). Distinct file per item → no conflicts.
  cat > "$WT/app/item-$tok.sh" <<STUB
#!/usr/bin/env bash
# item-$tok.sh — deterministic STUB-builder change implementing benchmark backlog item $tok.
item_$tok() { printf 'item %s done\n' "$tok"; }
if [ "\${BASH_SOURCE[0]}" = "\$0" ]; then item_$tok "\$@"; fi
STUB
  chmod +x "$WT/app/item-$tok.sh"

  # Optional fault injection: break the app so this item's gate must catch it (off by default).
  if [ "${BENCH_GATE_FAIL_ITEM:-}" = "$tok" ]; then
    printf 'greet() { printf "BROKEN\\n"; }\n' > "$WT/app/greet.sh"
  fi

  git -C "$WT" add -A
  git -C "$WT" commit -q -m "stub-builder: implement item $tok"

  # local pr.json record (no hosted GitHub repo in stub mode; mirrors sandbox-scenario.sh's pr.json).
  HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"
  BASE_SHA="$(git -C "$REPO" rev-parse main)"
  cat > "$PRDIR/item-$tok.json" <<PR
{
  "item": "$tok",
  "branch": "$BRANCH",
  "base": "main",
  "head_sha": "$HEAD_SHA",
  "base_sha": "$BASE_SHA",
  "title": "stub-builder: implement item $tok",
  "hosted": false
}
PR

  # health gate: run the fixture's real gate against the builder worktree.
  gate_rc=0
  ( cd "$WT" && bash app/greet.test.sh ) >/dev/null 2>&1 || gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then
    GATE_FAILURES=$((GATE_FAILURES+1))
    checkpoint "item_${tok}_gate" fail "gate FAILED (rc=$gate_rc) — item $tok NOT merged, stays 🔜"
    # Teardown the failed builder; leave the item 🔜 (a broken change is never merged or shipped).
    git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
    git -C "$REPO" branch -D "$BRANCH" 2>/dev/null || true
    continue
  fi

  # merge (gate passed): bring the stub change onto main.
  _sf_git_env
  if ! git -C "$REPO" merge -q --no-ff -m "merge: $BRANCH" "$BRANCH" 2>/dev/null; then
    checkpoint "item_${tok}_merge" fail "merge of $BRANCH into main failed"
    git -C "$REPO" merge --abort 2>/dev/null || true
    git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
    git -C "$REPO" branch -D "$BRANCH" 2>/dev/null || true
    continue
  fi

  # teardown: remove the worktree + delete the branch.
  git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
  git -C "$REPO" branch -D "$BRANCH" 2>/dev/null || true

  # scribe: mark the backlog item ✅ and commit it — the DURABLE "shipped" record the resume reads.
  _bench_mark_shipped "$tok"
  _sf_git_env
  git -C "$REPO" add BACKLOG.md
  git -C "$REPO" commit -q -m "scribe: mark item $tok shipped"

  SHIPPED_TOTAL=$((SHIPPED_TOTAL+1))
  DRAINED_THIS_RUN=$((DRAINED_THIS_RUN+1))
  ok "item $tok drained (merged + scribed); $SHIPPED_TOTAL/$N shipped"

  # ── INTERRUPTION INJECTION: hard-exit AFTER fully shipping the K-th item this run ───────────────
  # SIGKILL cannot be trapped — it is a genuine crash. Durable state (branches/backlog on disk) is
  # left consistent (this item is fully shipped + scribed); the re-run resumes from it alone.
  if [ -n "$KILL_AT" ] && [ "$DRAINED_THIS_RUN" -eq "$KILL_AT" ]; then
    printf '\n%s[kill]%s --kill-at %s reached after item %s — hard-exiting (SIGKILL) to simulate a crash.\n' \
      "$c_bold" "$c_rst" "$KILL_AT" "$tok"
    printf '  re-run with the same --state %s to resume from durable state.\n' "$STATE"
    kill -9 "$$"
  fi
done

# ── scorecard ─────────────────────────────────────────────────────────────────────────────────
REMAINING="$(_bench_count_pending)"
SHIPPED_TOTAL="$(_bench_count_shipped)"

# Final assertions: complete drain, zero duplicates, zero gate failures.
if [ "$REMAINING" -eq 0 ]; then
  checkpoint drain_complete pass "all $N items shipped (0 remaining)"
else
  checkpoint drain_complete fail "$REMAINING item(s) still 🔜 after drain"
fi
if [ "$DUPLICATES" -eq 0 ]; then
  checkpoint no_duplicates pass "0 duplicate ships"
else
  checkpoint no_duplicates fail "$DUPLICATES duplicate ship attempt(s)"
fi
if [ "$GATE_FAILURES" -eq 0 ]; then
  checkpoint no_gate_failures pass "0 gate failures"
else
  checkpoint no_gate_failures skip "$GATE_FAILURES gate failure(s) (fault-injection) — those items left 🔜"
fi

RESULT="pass"; [ "$_fail" -gt 0 ] && RESULT="fail"
SCARD="$(write_scorecard "$RESULT")"
printf '\n%s══ scorecard ══%s\n' "$c_bold" "$c_rst"
printf '  scenario:            %s\n' "$SCENARIO"
printf '  backlog_size:        %d\n' "$N"
printf '  items_drained:       %d (this run: %d)\n' "$SHIPPED_TOTAL" "$DRAINED_THIS_RUN"
printf '  remaining:           %d\n' "$REMAINING"
printf '  resumed_after_kill:  %s\n' "$RESUMED_AFTER_KILL"
printf '  duplicates:          %d\n' "$DUPLICATES"
printf '  gate_failures:       %d\n' "$GATE_FAILURES"
printf '  wall_clock_s:        %d\n' "$SECONDS"
printf '  result:              %s\n' "$RESULT"
printf '  scorecard:           %s\n' "$SCARD"

[ "$RESULT" = "pass" ] && exit 0 || exit 1
