#!/usr/bin/env bash
# test-resolver-liveness.sh — hermetic regression tests for RESOLVER FALSE-DEAD (HERD-206).
#
# THE BUG: the watcher decided a resolve·<slug> agent was dead from NEGATIVE evidence — "absent from
# $AGENTS_JSON". The tick's roster comes from herd_driver_agent_list_json, which falls back to '{}'
# whenever `herdr agent list` blips, and the membership test only matched the `name` identity key
# (herdr also carries it in `agent`). So a live, mid-merge resolver read DEAD ~90s after spawn (the
# instant its startup grace elapsed): the stale-resolve-tab reaper closed its tab, the respawn path
# re-dispatched onto the same worktree, and the PR looped to REFIX_MAX_ROUNDS and stranded. A
# MANUALLY-spawned resolver survived only because nothing was watching it.
#
# THE FIX under test: resolver rows get the SAME liveness discipline builders got in PR #260 —
# POSITIVE-EVIDENCE-ONLY death. _resolver_liveness_verdict is the single oracle:
#   ALIVE    roster-listed under EITHER identity key, OR the pane probe sees a live claude
#   STARTING inside the startup grace since the last dispatch — never a death verdict there
#   DEAD     the pane probe positively says gone (dead|missing), OR a READABLE roster omits it
#   UNKNOWN  probe blind AND roster unreadable — hold; never respawn, never reap
# and only DEAD authorizes a respawn (_resolver_in_flight) or a tab close (_sweep_stale_resolve_tabs).
#
# Cases:
#   (1)  helpers exist after sourcing
#   (2)  RED-FIRST: fresh spawn, roster empty, probe blind, inside grace  ⇒ STARTING, no respawn
#   (3)  RED-FIRST: past grace + UNREADABLE roster ('{}')                 ⇒ UNKNOWN, no respawn
#   (4)  RED-FIRST: past grace + roster ABSENT (unset AGENTS_JSON)        ⇒ UNKNOWN, no respawn
#   (5)  RED-FIRST: past grace + probe says ALIVE, roster readable+empty  ⇒ ALIVE, no respawn
#   (6)  RED-FIRST: roster lists the resolver under the `agent` key       ⇒ ALIVE, no respawn
#   (7)  past grace + readable empty roster + blind probe                 ⇒ DEAD (shipped respawn kept)
#   (8)  past grace + probe positively 'dead' (pid recorded, not running) ⇒ DEAD
#   (9)  _classify_conflict: an UNKNOWN-liveness resolver HOLDS the row and queues NO respawn
#   (10) _classify_conflict: a positively-DEAD resolver still queues the dead-resolver respawn
#   (11) RED-FIRST reaper: a probe-ALIVE resolver's tab is never closed, even with the PR gone
#   (12) RED-FIRST reaper: a fresh (STARTING) resolver's tab is never closed
#   (13) RED-FIRST reaper: a FAILING `gh pr list` sweeps nothing (blindness ≠ "all PRs merged")
#   (14) reaper: a positively-dead resolver + gone PR is still swept (shipped behavior kept)
#   (15) spawn_resolver journals a resolver_spawn ACK event carrying rc + acked
#   (16) RESOLVER LOOP: a flapping/unreadable roster never burns the respawn budget
#
# Liveness is driven through HERD_DRIVER=headless, whose probe reads
# $WORKTREES_DIR/.herd/agents/<name>/pid — so "probe alive/dead/blind" are real probe outcomes, not
# stubs of the function under test.
#
# Run:  bash tests/test-resolver-liveness.sh
# No `set -e`: several checks deliberately assert a non-zero predicate return.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── Stub binaries on PATH (NETWORK-FREE, no real tabs) ────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
export GH_PRLIST="$T/prlist.json"; printf '[]\n' > "$GH_PRLIST"
export GH_RC="$T/gh.rc"; printf '0\n' > "$GH_RC"     # flip to 1 to simulate an offline / rate-limited gh
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
_rc="$(cat "$GH_RC" 2>/dev/null || echo 0)"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  [ "$_rc" = "0" ] || exit "$_rc"
  cat "$GH_PRLIST" 2>/dev/null
fi
exit 0
STUB
export CLOSED="$T/closed.log"; : > "$CLOSED"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "tab close")      printf '%s\n' "${3:-}" >> "$CLOSED" ;;
  "workspace list") printf '{"result":{"workspaces":[]}}\n' ;;
  "tab list")       printf '{"result":{"tabs":[]}}\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/gh" "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Source agent-watch.sh in lib mode, headless driver ────────────────────────
export AGENT_WATCH_LIB=1
export HERD_DRIVER=headless          # liveness probe = the detached-agent registry (real pid checks)
export PROJECT_ROOT="$T/main"; mkdir -p "$PROJECT_ROOT"
export WORKTREES_DIR="$T/trees"; mkdir -p "$WORKTREES_DIR"
export HERD_CONFIG_FILE="$T/no-such-config"
export JOURNAL_FILE="$T/journal.jsonl"; : > "$JOURNAL_FILE"
export REFIX_MAX_ROUNDS=3
export DRYRUN=""
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
render() { :; }
TREES="$WORKTREES_DIR"
RESOLVE_STATE="$T/.agent-watch-resolve-attempts"
REG="$WORKTREES_DIR/.herd-tabs"

SLUG="fixit"; PR="77"; BRANCH="feat/fixit"; SHA="aaaaaaa1"
GRACE_DEFAULT=90

# ── fixtures ──────────────────────────────────────────────────────────────────
# roster_empty     — a READABLE roster carrying zero agents (positive absence)
# roster_unreadable— what herd_driver_agent_list_json emits when `herdr agent list` fails
# roster_named KEY — a roster listing resolve·$SLUG under the given identity key (name|agent)
roster_empty()      { printf '{"result":{"agents":[]}}'; }
roster_unreadable() { printf '{}'; }
roster_named()      { printf '{"result":{"agents":[{"%s":"resolve·%s","agent_status":"working"}]}}' "$1" "$SLUG"; }

# probe_alive / probe_dead / probe_blind — write (or clear) the headless registry pid file the
# liveness probe reads for the resolve·<slug> agent. A live pid ⇒ 'alive'; a recorded-but-gone pid ⇒
# 'dead'; no file ⇒ 'unknown' (blind).
_agent_pid_dir="$WORKTREES_DIR/.herd/agents/resolve·$SLUG"
probe_alive() { mkdir -p "$_agent_pid_dir"; printf '%s\n' "$$" > "$_agent_pid_dir/pid"; }
probe_dead()  { mkdir -p "$_agent_pid_dir"; printf '%s\n' "$(_dead_pid)" > "$_agent_pid_dir/pid"; }
probe_blind() { rm -rf "$WORKTREES_DIR/.herd/agents"; }
# A pid that is certainly not running: fork a true subshell and reap it.
_dead_pid() { ( exit 0 ) & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }

# dispatched_at <seconds-ago> — seed the resolve ledger with one dispatch that far in the past.
dispatched_at() {
  : > "$RESOLVE_STATE"
  printf '%s %s %s %s %s dispatched\n' "$(( $(date +%s) - $1 ))" "$PR" "$SLUG" "$BRANCH" "$SHA" >> "$RESOLVE_STATE"
}
# lane_marker_live / lane_marker_dead / lane_marker_clear — plant (or clear) the inflight marker a
# backgrounded resolver lane holds for $SLUG, with a live or a provably-dead worker pid.
lane_marker_file() { printf '%s%s-%s-x-1' "$SPAWN_INFLIGHT_PREFIX" resolve "$(_spawn_slug_key "$SLUG")"; }
lane_marker_live() { _marker_write "$(lane_marker_file)" "$$"; }
lane_marker_dead() { _marker_write "$(lane_marker_file)" "$(_dead_pid)"; }
lane_marker_clear(){ rm -f "$SPAWN_INFLIGHT_PREFIX"resolve-* 2>/dev/null || true; }

reset() {
  : > "$JOURNAL_FILE"; : > "$CLOSED"; : > "$REG"; : > "$RESOLVE_STATE"
  lane_marker_clear
  printf '[]\n' > "$GH_PRLIST"; printf '0\n' > "$GH_RC"
  probe_blind
  _RESOLVER_DEAD_GRACE="$GRACE_DEFAULT"
  AGENTS_JSON="$(roster_empty)"
}
verdict() { _resolver_liveness_verdict "$SLUG" "${1-$PR}"; }

# classify <sha> — run the shipped conflict classifier IN THIS SHELL (never a subshell: DISPLAY and the
# CONF_* queues are the observables). Sets CLASSIFY_N (respawns queued) and CLASSIFY_REASON.
classify() {
  DISPLAY=(); FLAIR_STATE=()
  CONF_IDX=(); CONF_SLUG=(); CONF_PR=(); CONF_BRANCH=(); CONF_SHA=(); CONF_REASON=()
  _classify_conflict 0 "$PR" "$SLUG" "$BRANCH" "$1"
  CLASSIFY_N="${#CONF_IDX[@]}"
  CLASSIFY_REASON="${CONF_REASON[0]:--}"
}
was_closed() { grep -qxF "$1" "$CLOSED" 2>/dev/null; }

# ── (1) helpers exist ─────────────────────────────────────────────────────────
for fn in _resolver_liveness_verdict _resolver_in_flight _resolver_agent_alive _resolver_roster_listed \
          _resolver_probe _roster_readable _resolver_grace_active resolver_last_dispatch_epoch_slug \
          _sweep_stale_resolve_tabs spawn_resolver _resolver_lane_starting _spawn_slug_key; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing (HERD-206 liveness seam)"
done
ok

# ── (2) fresh spawn, blind, INSIDE grace ⇒ STARTING, never a respawn ──────────
# This is the item's headline regression: "a fresh resolver reads unknown/idle briefly — never a
# death verdict inside ~90s of spawn".
reset
dispatched_at 5
[ "$(verdict)" = "STARTING" ] || fail "(2) fresh spawn inside grace must read STARTING, got '$(verdict)'"
_resolver_in_flight "$SLUG" "$PR" || fail "(2) a STARTING resolver must count as in-flight (no respawn)"
ok

# ── (3) past grace + UNREADABLE roster ⇒ UNKNOWN, never a respawn ─────────────
# `herdr agent list` blipped; herd_driver_agent_list_json fell back to '{}'. Blindness is not death.
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
AGENTS_JSON="$(roster_unreadable)"
[ "$(verdict)" = "UNKNOWN" ] || fail "(3) an unreadable roster must read UNKNOWN, got '$(verdict)' — false-dead"
_resolver_in_flight "$SLUG" "$PR" || fail "(3) an UNKNOWN-liveness resolver must NOT be respawned over"
ok

# ── (4) past grace + roster ABSENT entirely ⇒ UNKNOWN ─────────────────────────
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
AGENTS_JSON=""
[ "$(verdict)" = "UNKNOWN" ] || fail "(4) an absent roster must read UNKNOWN, got '$(verdict)'"
_resolver_in_flight "$SLUG" "$PR" || fail "(4) an absent roster must NOT authorize a respawn"
ok

# ── (5) past grace + pane probe ALIVE, roster readable+empty ⇒ ALIVE ──────────
# The delisted-but-running resolver: herdr dropped the registration, the process is still merging.
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
probe_alive
[ "$(_resolver_probe "$SLUG")" = "alive" ] || fail "(5) fixture broken: headless probe must read alive"
[ "$(verdict)" = "ALIVE" ] || fail "(5) a probe-alive resolver must read ALIVE, got '$(verdict)' — false-dead"
_resolver_agent_alive "$SLUG" || fail "(5) _resolver_agent_alive must accept pane-process evidence"
_resolver_in_flight "$SLUG" "$PR" || fail "(5) a probe-alive resolver must never be respawned over"
ok

# ── (6) roster lists it under the `agent` identity key ⇒ ALIVE ────────────────
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
AGENTS_JSON="$(roster_named agent)"
_resolver_roster_listed "$SLUG" || fail "(6) roster match must tolerate the \`agent\` identity key"
[ "$(verdict)" = "ALIVE" ] || fail "(6) an \`agent\`-keyed roster row must read ALIVE, got '$(verdict)'"
ok
# …and the `name` key still works.
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
AGENTS_JSON="$(roster_named name)"
[ "$(verdict)" = "ALIVE" ] || fail "(6) a \`name\`-keyed roster row must read ALIVE, got '$(verdict)'"
ok

# ── (7) past grace + READABLE empty roster + blind probe ⇒ DEAD ───────────────
# Positive absence: we could read the roster and it does not list the resolver. Shipped respawn kept.
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
[ "$(verdict)" = "DEAD" ] || fail "(7) readable-empty roster past grace must read DEAD, got '$(verdict)'"
_resolver_in_flight "$SLUG" "$PR" && fail "(7) a positively-dead resolver must free the dispatch slot"
ok

# ── (8) past grace + probe positively 'dead' ⇒ DEAD ───────────────────────────
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
probe_dead
AGENTS_JSON="$(roster_unreadable)"    # roster blind: the PROBE alone must carry the death verdict
[ "$(_resolver_probe "$SLUG")" = "dead" ] || fail "(8) fixture broken: headless probe must read dead"
[ "$(verdict)" = "DEAD" ] || fail "(8) a probe-dead resolver must read DEAD, got '$(verdict)'"
ok

# ── (8b) probe 'dead' INSIDE the grace is still STARTING (grace outranks death) ───
reset
dispatched_at 5
probe_dead
[ "$(verdict)" = "STARTING" ] || fail "(8b) no death verdict may be returned inside the startup grace"
ok

# ── (9) _classify_conflict: UNKNOWN liveness HOLDS the row, queues no respawn ─
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
AGENTS_JSON="$(roster_unreadable)"
classify "$SHA"
[ "$CLASSIFY_N" = "0" ] || fail "(9) UNKNOWN liveness queued $CLASSIFY_N respawn(s) — the false-dead loop"
case "${DISPLAY[0]}" in *"resolving conflict"*) : ;; *) fail "(9) UNKNOWN row must read 'resolving conflict…', got: ${DISPLAY[0]}" ;; esac
ok

# ── (10) _classify_conflict: positively-DEAD still queues the dead-resolver respawn ──
reset
dispatched_at $(( GRACE_DEFAULT + 60 ))
classify "$SHA"
[ "$CLASSIFY_N $CLASSIFY_REASON" = "1 dead-resolver" ] || fail "(10) a positively-dead resolver must still respawn, got '$CLASSIFY_N $CLASSIFY_REASON'"
ok

# ── (11) reaper: a probe-ALIVE resolver's tab is NEVER closed ─────────────────
# "The reaper must never kill a resolver whose pane process is alive."
reset
printf 'resolve·%s tab-live resolve\n' "$SLUG" > "$REG"
dispatched_at $(( GRACE_DEFAULT + 60 ))
probe_alive
printf '[]\n' > "$GH_PRLIST"          # PR gone (merged/closed) — the sweep's "stale" precondition
_sweep_stale_resolve_tabs
was_closed tab-live && fail "(11) the reaper closed a resolver whose pane process is ALIVE"
grep -q 'resolve·'"$SLUG"' tab-live' "$REG" || fail "(11) the reaper pruned a live resolver's registry row"
ok

# ── (12) reaper: a fresh (STARTING) resolver's tab is never closed ────────────
reset
printf 'resolve·%s tab-fresh resolve\n' "$SLUG" > "$REG"
dispatched_at 5                        # just dispatched: no roster row, no pane, inside grace
_sweep_stale_resolve_tabs
was_closed tab-fresh && fail "(12) the reaper closed a just-spawned resolver inside its startup grace"
ok

# ── (13) reaper: a FAILING gh pr list sweeps nothing ──────────────────────────
# An offline/rate-limited `gh pr list` emits the same empty output as "zero open PRs"; reading that
# as "every PR merged" closed every resolve tab in the workspace.
reset
printf 'resolve·%s tab-blindgh resolve\n' "$SLUG" > "$REG"
dispatched_at $(( GRACE_DEFAULT + 60 ))   # positively dead — only the gh blindness must spare it
printf '1\n' > "$GH_RC"
_sweep_stale_resolve_tabs
was_closed tab-blindgh && fail "(13) a failing 'gh pr list' let the reaper close a resolve tab"
ok

# ── (14) reaper: positively-dead resolver + gone PR ⇒ still swept ─────────────
reset
printf 'resolve·%s tab-stale resolve\n' "$SLUG" > "$REG"
dispatched_at $(( GRACE_DEFAULT + 60 ))
_sweep_stale_resolve_tabs
was_closed tab-stale || fail "(14) a positively-dead resolver on a gone PR must still be swept"
grep -q tab-stale "$REG" && fail "(14) the swept tab's registry row must be pruned"
ok

# ── (15) spawn_resolver journals a resolver_spawn ACK event (rc + acked) ──────
reset
STUB="$T/stub-resolve.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB"; chmod +x "$STUB"
HERD_RESOLVE_BIN="$STUB" spawn_resolver "$SLUG" "$PR" "$BRANCH" "$SHA"
_spawn_resolver_wait   # HERD-237: the resolver lane is dispatched in the background
grep -q '"event":"resolver_spawn"' "$JOURNAL_FILE" || fail "(15) spawn_resolver must journal a resolver_spawn ACK event"
grep -q '"acked":"no"' "$JOURNAL_FILE" || fail "(15) a resolver that never registered must journal acked=no"
grep -q '"rc":0' "$JOURNAL_FILE" || fail "(15) the ACK event must carry the lane's exit status"
[ "$(resolver_dispatch_count "$PR")" -eq 1 ] || fail "(15) the dispatch must still be recorded (budget sound)"
# A lane that FAILS to launch is journaled distinctly, and still records its dispatch.
reset
printf '#!/usr/bin/env bash\nexit 3\n' > "$STUB"
HERD_RESOLVE_BIN="$STUB" spawn_resolver "$SLUG" "$PR" "$BRANCH" "$SHA"
_spawn_resolver_wait   # HERD-237: the resolver lane is dispatched in the background
grep -q '"event":"resolver_spawn_failed"' "$JOURNAL_FILE" || fail "(15) a non-zero lane rc must journal resolver_spawn_failed"
grep -q '"event":"resolver_spawn_failed".*"rc":3' "$JOURNAL_FILE" || fail "(15) resolver_spawn_failed must carry the real rc"
ok

# ── (16) RESOLVER LOOP: a flapping/unreadable roster never burns the budget ───
# The stranding signature from the item: rounds 2-3 of #299/#309/#315/#319. Ten ticks of a blind
# watcher over a live resolver must produce ZERO extra dispatches — the budget stays at 1 and the PR
# never reaches "resolver gave up".
reset
dispatched_at 1
spawned=0
for tick in 1 2 3 4 5 6 7 8 9 10; do
  # Alternate the two blindness flavors the incident showed: an unreadable roster, and a readable
  # roster whose resolver is DELISTED while its process still runs.
  if [ $(( tick % 2 )) -eq 0 ]; then AGENTS_JSON="$(roster_unreadable)"; probe_blind
  else                               AGENTS_JSON="$(roster_empty)";      probe_alive
  fi
  # Age the dispatch past the grace so ONLY the liveness verdict can hold the row.
  dispatched_at $(( GRACE_DEFAULT + 60 ))
  classify "$SHA"
  spawned=$(( spawned + CLASSIFY_N ))
done
[ "$spawned" -eq 0 ] || fail "(16) resolver-loop: a blind watcher queued $spawned respawns over a live resolver"
[ "$(resolver_dispatch_count "$PR")" -eq 1 ] || fail "(16) resolver-loop: the respawn budget was burned"
case "${DISPLAY[0]}" in *"gave up"*) fail "(16) resolver-loop: the PR was stranded at the round cap" ;; esac
ok

# ── (19) HERD-237: a DISPATCHED-BUT-QUEUED resolver lane is STARTING, not DEAD ────────────────────
# The lane is backgrounded and serialized behind the lane lock, so the k-th lane of a merge burst can
# start minutes after its dispatch. `record_resolve_attempt` (which starts the 90s grace) fires on the
# tick, so the grace lapses long before the lane runs. A queued lane has no roster row and no pane —
# exactly a corpse's signature. Calling it DEAD re-dispatches a resolver that never started, burns the
# respawn budget, and ends in a false "resolver gave up (3 rounds)". The live lane marker is the truth.
reset
dispatched_at $(( GRACE_DEFAULT + 600 ))   # grace long lapsed
probe_blind                                 # no pane yet — the lane has not started the agent
AGENTS_JSON="$(roster_empty)"               # readable roster, resolver absent ⇒ would be DEAD
[ "$(verdict)" = "DEAD" ] || fail "(19) precondition: a grace-lapsed, unregistered resolver must read DEAD without a lane marker"
lane_marker_live
[ "$(verdict)" = "STARTING" ] || fail "(19) a live resolver LANE must read STARTING, got '$(verdict)' — a queued dispatch would be re-dispatched"
_resolver_in_flight "$SLUG" "$PR" || fail "(19) a live resolver lane must count as in-flight (the double-dispatch guard)"
ok

# ── (20) the classifier does not re-dispatch (nor burn a round) behind a live lane ────────────────
reset
dispatched_at $(( GRACE_DEFAULT + 600 ))
probe_blind; AGENTS_JSON="$(roster_empty)"
lane_marker_live
classify "$SHA"
[ "$CLASSIFY_N" = "0" ] || fail "(20) the classifier queued $CLASSIFY_N respawn(s) for a resolver whose lane is still running"
grep -q 'dead-resolver' "$JOURNAL_FILE" 2>/dev/null && fail "(20) a queued lane was journaled as a dead resolver"
ok

# ── (21) a DEAD lane worker restores the death verdict (liveness, not immortality) ────────────────
# The marker must not become a permanent "hands off": a watcher killed mid-dispatch leaves a marker
# whose pid is gone, and the resolver must then be re-dispatchable exactly as before.
reset
dispatched_at $(( GRACE_DEFAULT + 600 ))
probe_blind; AGENTS_JSON="$(roster_empty)"
lane_marker_dead
[ "$(verdict)" = "DEAD" ] || fail "(21) a marker for a DEAD lane worker must not mask a real death, got '$(verdict)'"
_resolver_in_flight "$SLUG" "$PR" && fail "(21) a dead lane worker's marker still read as in-flight (the resolver would never respawn)"
ok

# ── (22) an ALIVE-but-idle resolver is held while its lane worker still runs ──────────────────────
# HERD-225 frees an idle resolver for re-dispatch. But if THIS slug's lane is still running it is about
# to (re)start that very agent — re-dispatching races it into `herd-resolve.sh: agent name already used`.
reset
dispatched_at $(( GRACE_DEFAULT + 600 ))
AGENTS_JSON="$(printf '{"result":{"agents":[{"name":"resolve·%s","agent_status":"idle"}]}}' "$SLUG")"
_resolver_in_flight "$SLUG" "$PR" && fail "(22) precondition: an idle resolver past grace is free for re-dispatch"
lane_marker_live
_resolver_in_flight "$SLUG" "$PR" || fail "(22) an idle resolver whose lane worker is still running must be held"
ok

echo "ALL PASS ($pass checks) — resolver liveness: positive-evidence-only death (HERD-206)"
