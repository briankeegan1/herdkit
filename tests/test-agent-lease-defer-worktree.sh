#!/usr/bin/env bash
# test-agent-lease-defer-worktree.sh — regression proof for the HERD-581 pre-merge review finding
# (PR #710): a DENIED agent-class capacity lease must defer BEFORE any side effect (worktree, herdr
# tab, task-spec file) — exactly like the review-gate saturation check it sits beside — so the
# durable spawn queue's held-spawn contract (agent-watch.sh:_drain_lane_worker: a deferral that
# created nothing releases the intent for a CLEAN re-drain) holds for the lease too. Before the fix,
# the lease check ran AFTER new-feature.sh/tab-create, so a denied lease left an orphaned worktree +
# tab, and the NEXT drain tick's `git worktree add` on the now-existing dir failed under
# set -euo pipefail, permanently dropping the intent (spawn_skipped) instead of re-queueing it.
#
# Mirrors tests/test-spawn-rate-match.sh's own hermetic harness (stub herdr/claude/gh, throwaway git
# repo) so both gates are proven with the same shape of evidence.
#
# Asserts:
#   (a) with the agent tenant's ONLY unit already held elsewhere, both lanes DEFER (exit 0, the
#       'agent capacity lease unavailable' marker) — and NEITHER `herdr agent start`/`tab create` NOR
#       a worktree/task-spec file for the held slug is ever created.
#   (b) once that unit frees, the SAME slug proceeds cleanly (round-trip, no leftover state) — proving
#       the deferral truly created nothing that would need to be cleaned up before a retry.
#
# Fully hermetic + NETWORK-FREE. Run:  bash tests/test-agent-lease-defer-worktree.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QUICK="$HERE/../scripts/herd/herd-quick.sh"
FEATURE="$HERE/../scripts/herd/herd-feature.sh"
CAPLEDGER="$HERE/../scripts/herd/capacity-ledger.sh"
FLOCKRUN="$HERE/../scripts/herd/capacity_flock_run.py"

T="$(mktemp -d)"
# HERD-614: an ADMITTED lease (part (b) below) backgrounds+disowns capacity_agent_lease_hold
# (capacity-ledger.sh) — BY DESIGN it outlives the `bash "$QUICK"`/`bash "$FEATURE"` subprocess that
# spawned it, tracking the (fixture) agent's liveness via capacity-agent-lease-wait.sh, which polls
# herd_driver_agent_liveness (real `herdr agent list`/`herdr pane list` calls) for up to
# HERD_CAPACITY_AGENT_START_TIMEOUT_SECS (default 60s) before giving up — since the fixture "agent"
# never actually shows alive in the herdr stub's roster. Left alone, that detached process keeps
# polling long after THIS script's own asserts finish and its trap deletes $T (including $BIN/herdr),
# so its later polls fall through PATH to whatever tripwire stub the outer daemon-hermeticity sandbox
# (.herd/healthcheck.project.sh / tests/herd.bats) has shadowed in — an unattributable
# 'leak: suite herdr agent list'/'pane list'. Reap it explicitly before cleanup instead of shrinking
# the production timeout knobs: capacity_agent_lease_reserve's own admitted-vs-busy detection depends
# on the SAME background holder staying alive through its ~0.4s settle window (a busy attempt dies in
# microseconds; only a real admission survives that long), so racing capacity-agent-lease-wait.sh's
# timeout against that window breaks the very assertion this test proves. pkill -f matches on the
# leaf script + this run's OWN slugs (lease-deny-q/-f — never reused outside this file), never a
# sibling test's fixture, wherever the disowned process was reparented to.
reap_lease_waiters() {
  local pat i
  for pat in "capacity-agent-lease-wait.sh lease-deny-q" "capacity-agent-lease-wait.sh lease-deny-f"; do
    pkill -9 -f "$pat" >/dev/null 2>&1 || true
    # Confirm death (bounded ~2s) before returning — SIGKILL delivery is async, and this test's own
    # HOME="$T" makes python3 populate its bytecode cache under $T, so proceeding straight to `rm -rf
    # "$T"` while the just-killed capacity_flock_run.py parent is still unwinding can race a live write.
    i=0
    while [ "$i" -lt 20 ] && pgrep -f "$pat" >/dev/null 2>&1; do
      sleep 0.1
      i=$((i + 1))
    done
  done
}
cleanup() { reap_lease_waiters; rm -rf "$T"; }
trap cleanup EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v git    >/dev/null 2>&1 || fail "git required"

# ── Stubs (herdr + claude + gh mirror tests/test-spawn-rate-match.sh's own harness) ────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALL_LOG:-/dev/null}" 2>/dev/null || true
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wTest","label":"%s"}]}}\n' "${WORKSPACE_NAME:-herdkit}" ;;
  "tab list")    printf '{"result":{"tabs":[]}}\n' ;;
  "tab create")  printf '{"result":{"tab":{"tab_id":"tTest"},"root_pane":{"pane_id":"rTest"}}}\n' ;;
  "agent start") printf '{"result":{"agent":{"pane_id":"aTest"}}}\n' ;;
  "pane split")  printf '{"result":{"pane":{"pane_id":"pTest"}}}\n' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then printf '[]'; exit 0; fi
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# ── Throwaway git repo so worktree add … origin/main would succeed if reached ──────────────────────
REPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
: > "$REPO/seed.txt"
git -C "$REPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null

# ── Hermetic env ─────────────────────────────────────────────────────────────────────────────────
export HOME="$T"
export WORKSPACE_NAME="herdkit"
export HERD_SKIP_PREFLIGHT=1
export HERD_NO_APP=1
TREES="$T/trees"; mkdir -p "$TREES"
CFG="$T/config"
cat > "$CFG" <<EOF
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="herdkit"
APP_PREVIEW_CMD=""
REVIEW_CONCURRENCY="1"
SPAWN_AHEAD="1"
CAPACITY_BUDGET="on"
EOF
export HERD_CONFIG_FILE="$CFG"
export HERD_CAPACITY_CORES_OVERRIDE=8 HERD_FAKE_LOADAVG=0.1  # never let the overload breaker fire here

run_lane() {
  local script="$1" slug="$2"; shift 2
  export HERDR_CALL_LOG="$T/$slug.herdr.log"; : > "$HERDR_CALL_LOG"
  bash "$script" "$@" "$slug" "do a thing" > "$T/$slug.out" 2>&1
  return $?
}
started()  { grep -q "agent start" "$T/$1.herdr.log"; }
tab_created() { grep -q "^tab create" "$T/$1.herdr.log"; }
lease_deferred() { grep -q "agent capacity lease unavailable" "$T/$1.out"; }

# Agent tenant cap at REVIEW_CONCURRENCY=1 + SPAWN_AHEAD=1 = 2 -> reserved_top=1, reserved_bottom=1,
# general=0: 'spawn' candidates are exactly [slot 2]. Hold that ONE slot directly via the flock
# backbone (mirrors the capacity-ledger scenario's own harness) so any reserve attempt is denied.
HOLD_LOCK="$TREES/.capacity-agent-slot-2.lock"
HOLD_MARKER="$TREES/.capacity-agent-live-2"
python3 "$FLOCKRUN" --marker "$HOLD_MARKER" --class probe "$HOLD_LOCK" -- sleep 20 &
HOLDER=$!
_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$HOLD_MARKER" ] && { _ready=1; break; }; sleep 0.2; done
[ "$_ready" -eq 1 ] || fail "the slot-2 holder never wrote its marker — cannot prove anything"

# ═══ (a) lease denied → defer BEFORE any side effect, both lanes ══════════════════════════════════
run_lane "$QUICK" lease-deny-q || fail "quick lane exited non-zero on a lease defer"$'\n'"$(cat "$T/lease-deny-q.out")"
lease_deferred lease-deny-q || fail "quick lane: lease was not deferred"$'\n'"$(cat "$T/lease-deny-q.out")"
started lease-deny-q      && fail "quick lane: agent start was called despite a denied lease"$'\n'"$(cat "$T/lease-deny-q.herdr.log")"
tab_created lease-deny-q   && fail "quick lane: a herdr tab was created despite a denied lease"$'\n'"$(cat "$T/lease-deny-q.herdr.log")"
[ -e "$TREES/lease-deny-q" ]         && fail "quick lane: a worktree was created for the lease-held slug"
[ -e "$TREES/lease-deny-q.task.md" ] && fail "quick lane: a task spec was written for the lease-held slug"

run_lane "$FEATURE" lease-deny-f || fail "feature lane exited non-zero on a lease defer"$'\n'"$(cat "$T/lease-deny-f.out")"
lease_deferred lease-deny-f || fail "feature lane: lease was not deferred"$'\n'"$(cat "$T/lease-deny-f.out")"
started lease-deny-f      && fail "feature lane: agent start was called despite a denied lease"$'\n'"$(cat "$T/lease-deny-f.herdr.log")"
tab_created lease-deny-f   && fail "feature lane: a herdr tab was created despite a denied lease"$'\n'"$(cat "$T/lease-deny-f.herdr.log")"
[ -e "$TREES/lease-deny-f" ]         && fail "feature lane: a worktree was created for the lease-held slug"
[ -e "$TREES/lease-deny-f.task.md" ] && fail "feature lane: a task spec was written for the lease-held slug"
echo "PASS (a) a denied agent-class lease defers BEFORE any worktree/tab/task-spec side effect, in both lanes"

# ═══ (b) once the unit frees, the same slug proceeds cleanly (nothing to clean up first) ══════════
kill -9 "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
sleep 0.3
run_lane "$QUICK" lease-deny-q || fail "quick lane exited non-zero on the retry"$'\n'"$(cat "$T/lease-deny-q.out")"
started lease-deny-q || fail "quick lane: the SAME slug did not proceed once the lease freed"$'\n'"$(cat "$T/lease-deny-q.out")"
lease_deferred lease-deny-q && fail "quick lane: still deferring after the lease freed"$'\n'"$(cat "$T/lease-deny-q.out")"
[ -d "$TREES/lease-deny-q" ] || fail "quick lane: no worktree was created on the successful retry"
echo "PASS (b) the SAME slug proceeds cleanly once the lease frees — the earlier defer created nothing to reconcile"

echo "ALL PASS — a denied agent-class capacity lease is a clean, side-effect-free defer, matching the review-gate's own contract that the durable spawn queue's held-spawn re-drain depends on."
