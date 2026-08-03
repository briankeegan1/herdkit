#!/usr/bin/env bash
# watcher-resurrect.sh — external-cadence WATCHER RESURRECTION (HERD-489).
#
# THE GAP THIS CLOSES. A watcher died and stayed dead for 5 HOURS (2026-08-02) before a human
# noticed. Every existing revival lever — WATCHER_SELF_RESTART (HERD-251), WATCHER_SINGLETON_RECONCILE
# (HERD-450), COORDINATOR_WATCHDOG — is code the watcher's OWN tick loop executes. All three are
# provably inert against the failure that actually happened: the process was not running AT ALL, so
# nothing was ticking to notice or act. Reviving a fully-dead watcher needs a cadence that lives
# OUTSIDE the watcher process. That is what this script is: a short-lived, external PROBE an
# operator's cron or launchd job invokes on a schedule (see docs/COORDINATOR-SOP.md for the recipe),
# never a long-running daemon of its own.
#
# WHAT IT DOES, in one pass:
#   1. LIVENESS — classify THIS project's watcher through the shared watcher-exempt.sh seam
#      (watcher_singleton_verdict, HERD-450): the SAME argv0 + lockfile/flock reconciled check
#      `herd status` and the watcher's own WATCHER_SINGLETON_RECONCILE tick use. Acts ONLY on a
#      CONFIRMED zero-mains verdict (state NONE). OK / LOCK_DRIFT / DUPLICATE / HANDOFF all mean at
#      least one main is alive (or the ambiguity is someone else's to resolve) and are left STRICTLY
#      alone — this is the "never double a live watcher" guarantee, enforced by never even attempting
#      a relaunch outside the one state that means nobody is home.
#   2. RESURRECT — on NONE, journal `watcher_resurrect_detected` LOUDLY (before touching anything),
#      then relaunch through the VERIFIED stop/start seam `herd reload` (issue #579) — never a
#      home-grown kill/spawn. `herd reload`'s own stop leg is a no-op over an already-empty lockfile
#      (nothing to stop) and its launch leg re-checks liveness (_watcher_lock_pid_if_live) before
#      spawning, so even a concurrent probe/operator race cannot produce a duplicate. On a CONFIRMED
#      live pid afterward, journal `watcher_resurrected`; otherwise `watcher_resurrect_failed` and
#      exit 1 so a cron job's own failure channel (mail, `systemctl status`, launchd's exit-code log)
#      surfaces it.
#
# SHIP-DORMANT: WATCHER_RESURRECT (default off, herd-config.sh) gates the ENTIRE probe — off is a
# byte-inert no-op even when this script is invoked directly: no verdict call, no journal write, no
# relaunch, exit 0. Installing a cron/launchd job that calls `herd watcher-resurrect` is therefore
# safe before the key is ever turned on.
#
# Usage:  bash watcher-resurrect.sh [probe]   (exposed as `herd watcher-resurrect`)
#   probe (default, the only action) — run one liveness check; resurrect on a confirmed-dead
#   watcher, no-op otherwise. Prints one summary line to stdout (or stderr on failure) for a cron
#   log; never prompts, never touches herdr panes.
#
# WATCHER_RESURRECT_LIB=1 sources this in lib mode (functions only, no CLI dispatch) for hermetic
# tests — same convention as agent-watch.sh / sweep.sh / dep-watcher.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"
# shellcheck source=/dev/null
[ -f "$HERE/watcher-exempt.sh" ] && . "$HERE/watcher-exempt.sh"
# shellcheck source=/dev/null
[ -f "$HERE/journal.sh" ] && . "$HERE/journal.sh"

# watcher_resurrect_enabled — success iff WATCHER_RESURRECT is on. The one ship-dormant gate.
watcher_resurrect_enabled() {
  case "${WATCHER_RESURRECT:-off}" in on|true|1) return 0 ;; *) return 1 ;; esac
}

# watcher_resurrect_herd_bin — resolve the `herd` CLI: PATH first (so a project install or a test's
# fake `herd` wins — same resolution order as backlog-view.sh's run_backend_mode), else the bundled
# binary two directories up from this script.
watcher_resurrect_herd_bin() {
  local hb; hb="$(command -v herd 2>/dev/null || true)"
  [ -n "$hb" ] || hb="$HERE/../../bin/herd"
  printf '%s' "$hb"
}

# watcher_resurrect_probe — the one action. Exit 0 when disabled, healthy, or successfully
# resurrected; exit 1 only when a CONFIRMED-dead watcher's relaunch attempt leaves no live pid — a
# real failure worth a cron job's non-zero exit.
watcher_resurrect_probe() {
  watcher_resurrect_enabled || return 0
  declare -f watcher_singleton_verdict >/dev/null 2>&1 || return 0

  local verdict state
  verdict="$(watcher_singleton_verdict)"
  state="${verdict%%$'\t'*}"
  # Only NONE (zero live mains) is ours to act on. Every other state names at least one live main
  # (or a benign self-restart handoff window) — never touched here.
  [ "$state" = "NONE" ] || return 0

  declare -f journal_append >/dev/null 2>&1 \
    && journal_append watcher_resurrect_detected workspace "${WORKSPACE_NAME:-}" state "$state"
  printf 'watcher-resurrect: no live watcher for workspace %s (state=%s) — relaunching via herd reload\n' \
    "${WORKSPACE_NAME:-}" "$state"

  local herd_bin; herd_bin="$(watcher_resurrect_herd_bin)"
  ( cd "${PROJECT_ROOT:-.}" && "$herd_bin" reload ) >/dev/null 2>&1 || true

  local newpid=""
  if [ -n "${HERD_WATCHER_LOCK:-}" ] && [ -f "$HERD_WATCHER_LOCK" ]; then
    newpid="$(cat "$HERD_WATCHER_LOCK" 2>/dev/null || true)"
  fi
  if [ -n "$newpid" ] && kill -0 "$newpid" 2>/dev/null; then
    declare -f journal_append >/dev/null 2>&1 \
      && journal_append watcher_resurrected workspace "${WORKSPACE_NAME:-}" pid "$newpid" via reload
    printf 'watcher-resurrect: RESURRECTED — pid %s now holds the lock\n' "$newpid"
    return 0
  fi

  declare -f journal_append >/dev/null 2>&1 \
    && journal_append watcher_resurrect_failed workspace "${WORKSPACE_NAME:-}"
  printf 'watcher-resurrect: FAILED to relaunch — no live watcher after herd reload (run herd reload by hand)\n' >&2
  return 1
}

if [ "${WATCHER_RESURRECT_LIB:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

case "${1:-probe}" in
  probe) watcher_resurrect_probe ;;
  -h|--help) printf 'usage: watcher-resurrect.sh [probe]\n' ;;
  *) printf 'usage: watcher-resurrect.sh [probe]\n' >&2; exit 2 ;;
esac
