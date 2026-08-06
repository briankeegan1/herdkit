#!/usr/bin/env bash
# capacity-agent-lease-wait.sh <slug> — HERD-581 (HERD-557 P2): the CMD capacity_agent_lease_hold
# (capacity-ledger.sh) runs UNDER the flock, once a "spawn" class unit is admitted for <slug>. Blocks
# first until <slug>'s agent SESSION goes alive (driver-agnostic: herd_driver_agent_liveness, so this
# works identically for herdr-managed panes and headless detached agents — see driver.sh), giving up
# as a start-timeout if it never does (the runtime launch presumably failed; a lease must not be held
# forever for a spawn that never actually happened), then blocks until that liveness has STOPPED for
# HERD_CAPACITY_AGENT_DEATH_CONFIRM_TRIES consecutive polls — debounced so one transient herdr hiccup
# (a probe returning 'unknown', not positive death evidence) never releases a still-live lease, the
# same "no false reds" discipline every other liveness probe in this engine follows.
#
# Exiting either way is the WHOLE release mechanism: capacity_flock_run.py's own process exit is what
# the kernel reclaims the flock on (docs/spikes/capacity-admission.md) — this script's only job is to
# know WHEN that should happen. The caller journals the release with the exit code below.
#
# Exit codes: 0 = the agent was observed exiting after having gone alive (normal reclaim) ·
#             3 = the agent never went alive within the start timeout (spawn presumably failed).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"
# shellcheck source=/dev/null
. "$HERE/driver.sh"

SLUG="${1:?usage: capacity-agent-lease-wait.sh <slug>}"
START_TIMEOUT="${HERD_CAPACITY_AGENT_START_TIMEOUT_SECS:-60}"
CONFIRM="${HERD_CAPACITY_AGENT_DEATH_CONFIRM_TRIES:-3}"
POLL="${HERD_CAPACITY_AGENT_HOLD_POLL_SECS:-5}"
case "$START_TIMEOUT" in ''|*[!0-9]*) START_TIMEOUT=60 ;; esac
case "$CONFIRM" in ''|*[!0-9]*) CONFIRM=3 ;; esac
case "$POLL" in ''|*[!0-9]*) POLL=5 ;; esac

_liveness() { herd_driver_agent_liveness "$SLUG" 2>/dev/null; }
_alive() { [ "$(_liveness)" = "alive" ]; }

waited=0
until _alive; do
  waited=$((waited + POLL))
  [ "$waited" -ge "$START_TIMEOUT" ] 2>/dev/null && exit 3
  sleep "$POLL" 2>/dev/null || sleep 5
done

# Death confirmation counts ONLY positive death evidence ('dead' / 'missing') toward CONFIRM — a
# probe-blind 'unknown' read (herdr hiccup, transient process-info miss) is SKIPPED: it neither resets
# nor advances the counter, so it can never manufacture a release on its own. Without this split,
# 'unknown' silently counted as death alongside 'dead' — CONFIRM consecutive hiccups would release a
# still-live lease, contradicting the "no false reds" contract every other liveness probe follows.
dead=0
while :; do
  sleep "$POLL" 2>/dev/null || sleep 5
  case "$(_liveness)" in
    alive)         dead=0 ;;
    dead|missing)  dead=$((dead + 1)); [ "$dead" -ge "$CONFIRM" ] && exit 0 ;;
    *)             : ;;  # unknown — inconclusive, hold the counter where it was
  esac
done
