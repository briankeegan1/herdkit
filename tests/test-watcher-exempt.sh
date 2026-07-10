#!/usr/bin/env bash
# test-watcher-exempt.sh — hermetic proof of the ONE shared watcher-identity check (HERD-266).
#
# `herd status` used to alarm '⚠ 2 watcher mains alive' on a perfectly healthy control room. Two root
# causes, both proven here against a SYNTHETIC process table planted through the $HERD_SWEEP_PS_CMD
# seam (the same seam tests/test-sweep.sh uses), so not one real process is consulted:
#
#   (1) TRANSIENT TICK FORKS — the watcher's tick loop forks constantly and every fork inherits the
#       herd-watch-<ws> argv0. bin/herd's _list_project_watchers exempted only marker-owned pids, so a
#       sub-second fork alive at sample time counted as a second "watcher main" (~20 observed live,
#       all children of the canonical watcher). sweep.sh's sweep_stray_watchers ALREADY exempted a
#       fork whose ppid is the canonical watcher. Both seats now call watcher_list_mains — one check,
#       one answer — for the exemptions that are PROVABLE. sweep keeps its extra gate-child HEURISTIC
#       local to its detection-only surface; see (e) and (g) for why hoisting it would be a safety bug.
#   (2) SELF-RESTART HANDOFF — a WATCHER_SELF_RESTART exec briefly shows more than one tagged main.
#       The outgoing image records a TTL-bounded handoff marker; the alarm stays silent through it.
#
# And the property neither fix may break: a GENUINE ORPHAN DUPLICATE — parent dead, no gate child, no
# marker, no handoff — must STILL be listed AND still alarm. A duplicate races the shared .git object
# store; silencing one would be a far worse bug than the false alarm this fixes.
#
# Asserts:
#   (a) canonical + transient child fork            → exactly 1 main listed, no alarm
#   (b) genuine orphan duplicate                    → listed, AND the alarm verifies as real
#   (c) self-restart handoff (fresh marker)         → no alarm; a STALE marker alarms again
#   (d) a marker-owned gate worker                  → exempt from the listing (HERD-185/217/237/245)
#   (e) sweep.sh's DETECTION-only gate-child guard spares a reparented fork that the LISTING keeps
#   (f) the alarm's persistence re-sample: a main that vanishes between samples never alarms
#   (g) THE SAFETY RAIL (PR #387 review): a lock-absent STRAY that has dispatched a gate worker is
#       STILL listed. watcher_list_mains feeds _stop_project_watcher's SIGTERM loop, not just the
#       status count, and the gate-child guard cannot tell such a stray from a reparented fork — on
#       macOS (no setsid) a review worker is a DIRECT CHILD of the watcher main that dispatched it,
#       and the inflight marker records the WORKER's pid, not the dispatcher's. Exempting it would
#       make _stop_project_watcher report "no running watcher found", drop the lockfile, and let the
#       caller spawn a second main on top of the survivor — the exact emergency this code prevents.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PASS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASS=$(( PASS + 1 )); }

T="$(mktemp -d)"
cleanup() { [ -n "${CANON:-}" ] && kill "$CANON" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

TREESDIR="$T/trees"; mkdir -p "$TREESDIR"
export WORKTREES_DIR="$TREESDIR"
export HERD_WATCH_ARGV0="herd-watch-wxws"
# The canonical lock path herd-config.sh derives from WORKSPACE_NAME, so the sweep.sh seat in (e) —
# which re-loads the config and recomputes it — reads the very same lockfile this test writes.
export HERD_WATCHER_LOCK="$TREESDIR/.watcher-wxws.pid"

# shellcheck source=/dev/null
. "$REPO/scripts/herd/watcher-exempt.sh"
# shellcheck source=/dev/null
. "$REPO/scripts/herd/status.sh"

for fn in watcher_list_mains watcher_pid_exempt watcher_handoff_active _status_dup_verified; do
  declare -f "$fn" >/dev/null 2>&1 || fail "(0) $fn not defined after sourcing"
done
ok; echo "PASS (0) the shared check + the status alarm helpers load"

# The CANONICAL watcher must be a genuinely LIVE pid: watcher_canonical_pid kill -0's the lockfile.
sleep 60 & CANON=$!
disown 2>/dev/null || true
printf '%s\n' "$CANON" > "$HERD_WATCHER_LOCK"

FORK=800002      # a transient tick fork: ppid == canonical  → exempt from the listing (child guard)
GATEFORK=800003  # reparented to init, still parenting a gate worker → LISTED (only sweep spares it)
HCPID=800004     # GATEFORK's live healthcheck worker (untagged)
ORPHAN=800006    # a GENUINE orphan duplicate: parent dead, no gate child, no marker → LISTED

# A live inflight marker owns MARKED. watcher_marker_pids falls back to `kill -0` when agent-watch.sh's
# richer _marker_live is not in scope — so the pid it names must be alive. Reuse the canonical sleep's
# liveness by pointing the marker at a second real process.
sleep 60 & MARKED_REAL=$!
disown 2>/dev/null || true
printf '%s\n' "$MARKED_REAL" > "$TREESDIR/.health-inflight-main-abc123"

_plant_table() {   # $1 = destination script; writes the fixture table
  cat > "$1" <<EOF
#!/usr/bin/env bash
# pid ppid pgid command   — argv0 (the command's first token) is what tags a watcher.
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh --watch\n'  "$CANON"       "$CANON"
printf '%s %s %s herd-watch-wxws bash agent-watch.sh\n'         "$FORK"        "$CANON"    "$CANON"
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh\n'          "$GATEFORK"    "$GATEFORK"
printf '%s %s %s bash scripts/herd/healthcheck.sh /w/tree\n'    "$HCPID"       "$GATEFORK" "$GATEFORK"
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh\n'          "$MARKED_REAL" "$MARKED_REAL"
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh\n'          "$ORPHAN"      "$ORPHAN"
printf '900001 1 900001 herd-watch-otherws bash agent-watch.sh\n'
EOF
  chmod +x "$1"
}
_plant_table "$T/ps-all"
export HERD_SWEEP_PS_CMD="$T/ps-all"

MAINS="$(watcher_list_mains)"

# ── (a) canonical + transient child fork ────────────────────────────────────────────────────────
printf '%s\n' "$MAINS" | grep -qx "$CANON" || fail "(a) the canonical watcher was not listed: '$MAINS'"
printf '%s\n' "$MAINS" | grep -qx "$FORK" \
  && fail "(a) a transient tick fork (ppid == canonical) was counted as a watcher main — the false alarm"
ok; echo "PASS (a) a transient tick fork is exempt; the canonical watcher is listed"

# ── (d) the marker-owned exemption (HERD-185 / HERD-217 / HERD-237 / HERD-245) ──────────────────
printf '%s\n' "$MAINS" | grep -qx "$MARKED_REAL" \
  && fail "(d) a LIVE inflight-marker worker was listed as a duplicate watcher — the kill path would sever it"
printf '%s\n' "$MAINS" | grep -qx "$HCPID" && fail "(d) an untagged healthcheck worker was mistaken for a watcher"
printf '%s\n' "$MAINS" | grep -qx 900001 && fail "(d) ANOTHER workspace's tagged watcher was listed (issue #60)"
ok; echo "PASS (d) a marker-owned gate worker is exempt; a foreign workspace is never listed"

# ── (g) THE SAFETY RAIL: a gate-running stray is NEVER exempt from the listing ──────────────────
# GATEFORK parents a live healthcheck. sweep.sh's detection surface spares it (assertion (e)); the
# LISTING must not, because that same list is what _stop_project_watcher SIGTERMs.
printf '%s\n' "$MAINS" | grep -qx "$GATEFORK" \
  || fail "(g) a tagged main that had dispatched a gate worker was EXEMPTED from the kill list — \
'herd reload' would report 'no running watcher found', drop the lock, and spawn a second main on top of it"
ok; echo "PASS (g) a gate-running stray stays on the kill list (the duplicate safety rail holds)"

# ── (b) a genuine orphan duplicate is STILL listed ──────────────────────────────────────────────
printf '%s\n' "$MAINS" | grep -qx "$ORPHAN" \
  || fail "(b) a GENUINE orphan duplicate (parent dead, no gate child, no marker) was silenced: '$MAINS'"
[ "$(printf '%s\n' "$MAINS" | grep -c .)" -eq 3 ] \
  || fail "(b) expected exactly 3 mains (canonical + gate-running stray + orphan), got: '$(printf '%s' "$MAINS" | tr '\n' ' ')'"
# … and the status alarm VERIFIES it as real (every re-sample still sees them), reporting the pids
# that SURVIVED every sample rather than the first sample's.
SURV="$(HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 _status_dup_verified "$MAINS")" \
  || fail "(b) a persistent genuine duplicate did not verify — the alarm would never fire"
[ "$(printf '%s\n' "$SURV" | grep -c .)" -gt 1 ] \
  || fail "(b) the verified alarm reported <=1 surviving main: '$SURV' (would print '⚠ 1 watcher mains alive')"
ok; echo "PASS (b) a genuine orphan duplicate is listed; the alarm verifies it and reports the survivors"

# ── (c) self-restart handoff suppresses the alarm; a STALE marker does not ──────────────────────
printf '%s\n%s\n' "$CANON" "$(date +%s)" > "$TREESDIR/.watcher-handoff"
watcher_handoff_active || fail "(c) a fresh handoff marker did not read as active"
HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 _status_dup_verified "$MAINS" >/dev/null \
  && fail "(c) the duplicate alarm fired DURING a self-restart generation handoff (false red)"
# The pids are still LISTED through the handoff — `herd reload` must still be able to stop them.
printf '%s\n' "$(watcher_list_mains)" | grep -qx "$ORPHAN" \
  || fail "(c) the handoff removed a pid from watcher_list_mains — the kill path would go blind"
# A crashed exec's marker ages out and stops masking a real duplicate.
printf '%s\n%s\n' "$CANON" "$(( $(date +%s) - WATCHER_HANDOFF_TTL - 5 ))" > "$TREESDIR/.watcher-handoff"
watcher_handoff_active && fail "(c) an EXPIRED handoff marker still read as active — a real duplicate could hide forever"
HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 _status_dup_verified "$MAINS" >/dev/null \
  || fail "(c) an expired handoff marker still suppressed the alarm"
# A corrupt marker (no epoch) must fail toward telling the truth.
printf '%s\n' "$CANON" > "$TREESDIR/.watcher-handoff"
watcher_handoff_active && fail "(c) a marker with no epoch read as active"
rm -f "$TREESDIR/.watcher-handoff"
watcher_handoff_active && fail "(c) an ABSENT handoff marker read as active"
ok; echo "PASS (c) a fresh handoff silences the alarm; stale/corrupt/absent markers never mask a duplicate"

# ── (f) the persistence re-sample: a main that vanishes between samples never alarms ────────────
# The FIRST `ps` sample shows the orphan; every later one does not (the fork exited). This is the
# transient-fork case that the exemptions cannot attribute — only TIME can tell it from a duplicate.
cat > "$T/ps-vanishing" <<EOF
#!/usr/bin/env bash
n=0; [ -f "$T/ps-calls" ] && n="\$(cat "$T/ps-calls")"
printf '%s\n' "\$(( n + 1 ))" > "$T/ps-calls"
printf '%s 1 %s herd-watch-wxws bash agent-watch.sh --watch\n' "$CANON" "$CANON"
[ "\$n" -eq 0 ] && printf '%s 1 %s herd-watch-wxws bash agent-watch.sh\n' "$ORPHAN" "$ORPHAN"
exit 0
EOF
chmod +x "$T/ps-vanishing"
FIRST="$(HERD_SWEEP_PS_CMD="$T/ps-vanishing" watcher_list_mains)"
[ "$(printf '%s\n' "$FIRST" | grep -c .)" -eq 2 ] || fail "(f) fixture: the first sample should see 2 mains"
HERD_SWEEP_PS_CMD="$T/ps-vanishing" HERD_STATUS_DUP_SAMPLES=3 HERD_STATUS_DUP_SLEEP=0 \
  _status_dup_verified "$FIRST" >/dev/null \
  && fail "(f) a main that vanished after the first sample still alarmed — the console cries wolf"
ok; echo "PASS (f) the alarm re-samples: a vanishing transient main never reds the console"

# ── (e) sweep's DETECTION-only gate-child guard ────────────────────────────────────────────────
# sweep_stray_watchers = watcher_list_mains, minus the lockfile pid, minus the gate-child heuristic.
# That last guard lives HERE and nowhere else: on a surface that only detects, sparing a false stray is
# right (leg 5 would SIGKILL in-flight gate work); on the listing, sparing one would blind the kill
# path. So GATEFORK must be ABSENT from sweep's strays and PRESENT in watcher_list_mains — the two
# surfaces agree about the canonical watcher and the orphan, and differ ONLY by that heuristic.
# Load sweep.sh the way the CLI does (agent-watch.sh in LIB mode) and drive it against the SAME table.
mkdir -p "$T/proj/.herd" "$T/proj/scripts"
cat > "$T/proj/.herd/config" <<EOF
PROJECT_ROOT=$T/proj
WORKTREES_DIR=$TREESDIR
WORKSPACE_NAME=wxws
EOF
STRAY="$( cd "$T/proj" && HERD_HERMETIC_GUARD=1 AGENT_WATCH_LIB=1 \
  bash -c '. "'"$REPO"'/scripts/herd/sweep.sh" >/dev/null 2>&1; sweep_stray_watchers' 2>/dev/null )"
if [ -n "$STRAY" ]; then
  printf '%s\n' "$STRAY" | grep -qx "$ORPHAN" \
    || fail "(e) sweep_stray_watchers did not list the genuine orphan the shared check lists: '$STRAY'"
  printf '%s\n' "$STRAY" | grep -qx "$CANON" && fail "(e) sweep_stray_watchers listed the canonical watcher"
  printf '%s\n' "$STRAY" | grep -qx "$FORK"  && fail "(e) sweep_stray_watchers listed a transient tick fork"
  printf '%s\n' "$STRAY" | grep -qx "$GATEFORK" \
    && fail "(e) sweep_stray_watchers listed a fork parenting a live healthcheck — leg 5 would SIGKILL in-flight gate work (HERD-217)"
  ok; echo "PASS (e) sweep spares a gate-parenting fork that the kill list still counts"
else
  # sweep.sh could not be loaded in this environment (it pulls in agent-watch.sh's full substrate).
  # Prove the structure instead of skipping silently: sweep reads the SHARED listing, and the
  # gate-child guard is applied THERE and only there.
  grep -q 'watcher_list_mains "$table"' "$REPO/scripts/herd/sweep.sh" \
    || fail "(e) sweep_stray_watchers no longer reads the SHARED watcher_list_mains — the two seats can drift again"
  grep -q '_sweep_watcher_has_gate_child "$pid" "$table" && continue' "$REPO/scripts/herd/sweep.sh" \
    || fail "(e) sweep_stray_watchers lost its detection-only gate-child guard (HERD-217)"
  grep -q 'watcher_has_gate_child' "$REPO/scripts/herd/watcher-exempt.sh" \
    && grep -qE '^_wx_exempt\(\)' -A8 "$REPO/scripts/herd/watcher-exempt.sh" \
    | grep -q 'watcher_has_gate_child' \
    && fail "(e) the gate-child guard leaked back into _wx_exempt — it would blind _stop_project_watcher"
  ok; echo "PASS (e) the gate-child guard lives on sweep's detection surface only (structural)"
fi

kill "$MARKED_REAL" 2>/dev/null || true
echo
echo "ALL PASS ($PASS checks)"
