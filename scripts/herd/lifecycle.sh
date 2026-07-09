#!/usr/bin/env bash
# lifecycle.sh — the SUPERVISED-PROCESS CONTRACT (HERD-193): no spawned process lingers unaccounted.
#
# Every agent population herdkit spawns — builders, reviewers, resolvers, the scribe/research drainer
# singletons, the health/review gate workers, sim runners — should carry four properties. The
# 2026-07-09 gating-hardening audit (docs/audits/2026-07-09-gating-hardening.md §4) mapped which
# populations have which today; the holes are all of the same shape:
#
#   OWNER     which component spawned it — journaled AT SPAWN, so a stray process is attributable.
#   DEADLINE  a max lifetime appropriate to its job, after which it is PRESUMED HUNG.
#   LIVENESS  how a supervisor verifies it is really working (a pid, or a heartbeat file).
#   RETIRE    who tears it down and when — named at spawn, so an expiry ROUTES to a real owner.
#
# This file is the shared bookkeeping for those four properties. It is OBSERVABILITY-FIRST by
# construction: it JOURNALS and SURFACES, and it never kills anything. Teardown stays with each
# population's existing owner (the gate corpse sweep, the drainer reclaim gate, the stall detector,
# the resolver escalation) — a blind kill from a generic supervisor is exactly the false-positive
# machine this engine has spent months removing.
#
# ── The ledger ───────────────────────────────────────────────────────────────────────────────────
# One file per supervised process, under $WORKTREES_DIR/.lifecycle/ (override: HERD_LIFECYCLE_DIR):
#
#     <population>__<sanitized-id>       one TAB-separated line:
#         population  id  owner  probe  deadline_secs  spawn_epoch  route
#
# Per-record files (not one shared ledger) because §5 of the audit indicts every read-modify-write
# ledger in $TREES: two concurrent writers silently drop each other's rows. A record is written once,
# with a temp+rename, and removed once. Two seats can never lose each other's spawns.
#
# ── The probe (LIVENESS) ─────────────────────────────────────────────────────────────────────────
#   pid:<n>            the process is alive iff kill -0 succeeds. Deadline is measured from SPAWN.
#   heartbeat:<file>   the process is alive iff <file>'s mtime is fresh. Deadline is measured from
#                      the LAST BEAT. This is the drainers' existing DRAINER_HEARTBEAT_TIMEOUT
#                      semantics (drainer-liveness.sh) — INTEGRATED here, not duplicated: a drainer
#                      legitimately runs for hours, so absolute lifetime is the wrong deadline for it.
#   none               no liveness signal; deadline from spawn only.
#
# A STALE BEAT IS NOT, BY ITSELF, A HANG. HERD-122 learned this the hard way: a frozen heartbeat is
# equally the signature of a drainer that FINISHED (its last beat is simply its last), and reclaiming
# on the beat alone false-positived a live drainer. So a stale beat is CORROBORATED against the agent's
# real liveness before it is called a hang — exactly as herd_drainer_should_reclaim does:
#     agent dead    → `exited`  (it finished or crashed; retire the record, never a fabricated hang)
#     agent alive   → `expired` (silent but running: the genuine hang this contract exists to surface)
#     unprobeable   → `live`    (blindness is never evidence of anything)
# The drainers additionally retire their own record on their normal completion path (`*-step.sh finish`
# → STOP), so a clean drain is accounted for the moment it ends, without waiting for corroboration.
#
# ── The deadline ─────────────────────────────────────────────────────────────────────────────────
# REUSES the timeout each population already has, so this file introduces no new tunables:
#   reviewer / health-worker   → REVIEW_INFLIGHT_TIMEOUT / HEALTH_INFLIGHT_TIMEOUT (the corpse sweep's)
#   scribe-drainer / research-drainer → DRAINER_HEARTBEAT_TIMEOUT (the reclaim gate's)
#   anything else              → _LC_FALLBACK_DEADLINE
#
# ── What each population actually gets from this leg ─────────────────────────────────────────────
# The GATE WORKERS (reviewer, health-worker) share their deadline with the corpse sweep, which runs
# EARLIER in the same tick, TERMs the timed-out worker and drops the record. So in practice a gate
# worker is surfaced by the corpse sweep, and what this leg adds for them is the exited/reconcile path:
# a worker that died before its teardown ran is still accounted for. `lifecycle_expired` is their
# BACKSTOP — it fires only when the corpse sweep is lagging or disabled. The DRAINERS have no corpse
# sweep at all, so the expiry path is their primary surface, and the resolver/builder populations
# (unwired here, on the HERD-225 / stall-detector rails) are what the routes are reserved for.
#
# One honest limit on reviewer LIVENESS: the recorded pid is the herd-review.sh POLLER, not the
# reviewer's agent pane, which outlives it. Pane orphans stay HERD-113's `_retire_reviewer_pane` /
# startup-sweep problem; this record supervises the process the watcher itself forked.
#
# ── SHIP-DORMANT, BYTE-IDENTICAL WHEN OFF ────────────────────────────────────────────────────────
# LIFECYCLE_CONTRACTS=off (the default) makes every public function an immediate no-op: no record is
# written, no journal event is emitted, no inbox row is appended, the sweep reads nothing. Sourcing
# this file only defines functions — no top-level side effects — so a lane that sources it is
# byte-identical to one that does not.
#
# FAIL-SOFT: every write is best-effort and swallowed. A read-only $TREES, a missing directory, a
# vanished record — none of it can abort a caller running under `set -euo pipefail`. Every public
# function returns 0 except the predicates, which are documented below.
#
# Sourced (never executed) AFTER herd-config.sh and journal.sh:
#     . "$HERE/herd-config.sh"
#     . "$HERE/journal.sh"
#     . "$HERE/lifecycle.sh"

# _LC_FALLBACK_DEADLINE — the deadline for a population with no existing timeout of its own. A
# literal, not a config key: the whole point is to reuse each population's real timeout, and a
# catch-all knob would invite operators to tune the wrong dial. 30 min matches the gate families.
_LC_FALLBACK_DEADLINE=1800

# _LC_EXIT_GRACE — how long the sweep waits, after first observing that a pid-probed process has
# EXITED, before retiring the record itself with the generic reason `exited`. The population's own
# teardown runs later in the tick (a health worker's result is collected, a reviewer's verdict is
# consumed) and retires the record with its TRUE reason; without this grace the sweep would always win
# the race and the journal would read `exited` for every cleanly-finished gate worker. The grace only
# delays bookkeeping — nothing waits on it.
_LC_EXIT_GRACE=60

# lifecycle_enabled — the ship-dormant gate. Returns 0 only when LIFECYCLE_CONTRACTS is truthy.
# EVERY public function consults this first.
lifecycle_enabled() {
  case "$(printf '%s' "${LIFECYCLE_CONTRACTS:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# lifecycle_dir — the record directory. HERD_LIFECYCLE_DIR is the test seam. Empty ⇒ no destination
# ⇒ every caller drops (the same contract journal.sh uses for an unresolvable journal path).
lifecycle_dir() {
  if [ -n "${HERD_LIFECYCLE_DIR:-}" ]; then printf '%s' "$HERD_LIFECYCLE_DIR"; return 0; fi
  [ -n "${WORKTREES_DIR:-}" ] || return 1
  printf '%s' "$WORKTREES_DIR/.lifecycle"
}

# _lc_safe <token> — squash everything outside [A-Za-z0-9._-] to '_' so a population/id pair is
# always one safe filename component. A sha, a pr-sha key, an agent name and a slug all survive intact.
_lc_safe() { printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_' ; }

# _lc_record_file <population> <id> — the record path for one supervised process.
_lc_record_file() {
  local _d; _d="$(lifecycle_dir)" || return 1
  [ -n "$_d" ] || return 1
  printf '%s/%s__%s' "$_d" "$(_lc_safe "$1")" "$(_lc_safe "$2")"
}

# _lc_now — epoch seconds. A test seam (HERD_LIFECYCLE_NOW) pins it so deadline math is deterministic.
_lc_now() {
  if [ -n "${HERD_LIFECYCLE_NOW:-}" ]; then printf '%s' "$HERD_LIFECYCLE_NOW"; return 0; fi
  date +%s 2>/dev/null || printf '0'
}

# _lc_num <value> <default> — <value> when it is a bare non-negative integer, else <default>.
_lc_num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

# lifecycle_deadline <population> — seconds this population may run before it is PRESUMED HUNG.
# Reuses the population's existing timeout key; never invents one.
lifecycle_deadline() {
  case "${1:-}" in
    reviewer)                        _lc_num "${REVIEW_INFLIGHT_TIMEOUT:-}" 1800 ;;
    health-worker)                   _lc_num "${HEALTH_INFLIGHT_TIMEOUT:-}" 1800 ;;
    scribe-drainer|research-drainer) _lc_num "${DRAINER_HEARTBEAT_TIMEOUT:-}" 900 ;;
    *)                               printf '%s' "$_LC_FALLBACK_DEADLINE" ;;
  esac
}

# lifecycle_route <population> — WHO tears this population down. An expiry is routed to this owner;
# lifecycle.sh never tears anything down itself. Each token names machinery that already exists.
lifecycle_route() {
  case "${1:-}" in
    reviewer|health-worker)          printf 'gate-corpse-sweep' ;;
    scribe-drainer|research-drainer) printf 'drainer-reclaim' ;;
    builder)                         printf 'stall-detector' ;;
    resolver)                        printf 'resolver-escalation' ;;
    *)                               printf 'operator' ;;
  esac
}

# _lc_pid_live <pid> — 0 when the pid names a live process. A non-numeric/absent pid is NOT evidence
# of death (blindness is never evidence of death — the roster rule) → treated as live.
_lc_pid_live() {
  case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$1" -gt 0 ] 2>/dev/null || return 0
  kill -0 "$1" 2>/dev/null
}

# _lc_beat_age <file> — seconds since <file>'s mtime, or empty when it cannot be read. Uses the same
# portable `find -newermt`-free idiom the engine already relies on: python3 for the stat, since GNU
# and BSD `stat` disagree on flags and uutils shadows both.
_lc_beat_age() {
  local _f="${1:-}" _now _mt
  [ -n "$_f" ] && [ -e "$_f" ] || return 1
  _mt="$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$_f" 2>/dev/null)" || return 1
  case "$_mt" in ''|*[!0-9]*) return 1 ;; esac
  _now="$(_lc_now)"
  printf '%s' "$(( _now - _mt ))"
}

# _lc_agent_liveness <agent-name> — corroborate a heartbeat population's real liveness. Prints
# alive | dead | unknown. Delegates to whichever probe the caller has already sourced:
# herd_drainer_live_status (drainer-liveness.sh — status-first, then the process probe) if present,
# else herd_driver_agent_liveness (driver.sh) directly. A caller that sourced NEITHER (or a runtime
# with no control surface) gets `unknown`, which every consumer below treats as "no evidence".
_lc_agent_liveness() {
  local _n="${1:-}"
  [ -n "$_n" ] || { printf 'unknown'; return 0; }
  if command -v herd_drainer_live_status >/dev/null 2>&1; then
    herd_drainer_live_status "$_n" 2>/dev/null || printf 'unknown'
  elif command -v herd_driver_agent_liveness >/dev/null 2>&1; then
    herd_driver_agent_liveness "$_n" 2>/dev/null || printf 'unknown'
  else
    printf 'unknown'
  fi
}

# ── The four properties, written once ────────────────────────────────────────────────────────────
# lifecycle_spawn <population> <id> <probe> [owner] [deadline_secs]
#   Record a supervised process and journal `lifecycle_spawn` with all four properties. <probe> is
#   pid:<n> | heartbeat:<file> | none. <owner> defaults to the caller's script name; <deadline_secs>
#   to lifecycle_deadline <population>. Idempotent-ish: a re-spawn of the same key overwrites the
#   record (a re-dispatch legitimately supersedes). ALWAYS returns 0.
lifecycle_spawn() {
  lifecycle_enabled || return 0
  local _pop="${1:-}" _id="${2:-}" _probe="${3:-none}" _owner="${4:-}" _dl="${5:-}"
  [ -n "$_pop" ] && [ -n "$_id" ] || return 0
  local _rf; _rf="$(_lc_record_file "$_pop" "$_id")" || return 0
  [ -n "$_owner" ] || _owner="$(basename -- "${0:-unknown}" 2>/dev/null || printf 'unknown')"
  [ -n "$_dl" ] || _dl="$(lifecycle_deadline "$_pop")"
  _dl="$(_lc_num "$_dl" "$_LC_FALLBACK_DEADLINE")"
  local _route _spawn_epoch _dir
  _route="$(lifecycle_route "$_pop")"
  _spawn_epoch="$(_lc_now)"
  _dir="${_rf%/*}"
  [ -d "$_dir" ] || mkdir -p "$_dir" 2>/dev/null || return 0
  # temp+rename so a reader never sees a half-written record. The temp name is DOT-PREFIXED and carries
  # no `__`, so a concurrent lifecycle_sweep's `*__*` glob can never pick it up mid-write.
  local _tmp; _tmp="$(mktemp "${_dir}/.lctmp.XXXXXX" 2>/dev/null)" || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$_pop" "$_id" "$_owner" "$_probe" "$_dl" "$_spawn_epoch" "$_route" > "$_tmp" 2>/dev/null \
    && mv -f "$_tmp" "$_rf" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  # A fresh spawn re-arms the once-only expiry notice and clears any exit observation (a superseding
  # dispatch is neither still-expired nor still-gone).
  rm -f "${_rf}.expired" "${_rf}.gone" 2>/dev/null || true
  journal_append lifecycle_spawn population "$_pop" id "$_id" owner "$_owner" \
    probe "$_probe" deadline "$_dl" route "$_route" component lifecycle
  return 0
}

# lifecycle_retire <population> <id> [reason]
#   The process is accounted for: drop its record and journal `lifecycle_retire`. Called from each
#   population's real teardown point (verdict-consumed, result collected, drainer reclaimed) and by
#   the sweep when a pid-probed process has simply exited. Retiring an unknown record is a silent
#   no-op — retirement is idempotent by construction. ALWAYS returns 0.
lifecycle_retire() {
  lifecycle_enabled || return 0
  local _pop="${1:-}" _id="${2:-}" _reason="${3:-done}"
  [ -n "$_pop" ] && [ -n "$_id" ] || return 0
  local _rf; _rf="$(_lc_record_file "$_pop" "$_id")" || return 0
  [ -f "$_rf" ] || return 0                  # never journal a retirement we cannot evidence
  local _owner _spawn_epoch _lived
  _owner="$(cut -f3 < "$_rf" 2>/dev/null)"
  _spawn_epoch="$(cut -f6 < "$_rf" 2>/dev/null)"
  _spawn_epoch="$(_lc_num "$_spawn_epoch" 0)"
  _lived=0
  [ "$_spawn_epoch" -gt 0 ] 2>/dev/null && _lived=$(( $(_lc_now) - _spawn_epoch ))
  rm -f "$_rf" "${_rf}.expired" "${_rf}.gone" 2>/dev/null || true
  journal_append lifecycle_retire population "$_pop" id "$_id" owner "${_owner:-unknown}" \
    reason "$_reason" lived_secs "$_lived" component lifecycle
  return 0
}

# lifecycle_records — print every live record, one TSV line each (the file's own line). Read-only;
# prints nothing when off / empty. Exit 0 always.
lifecycle_records() {
  lifecycle_enabled || return 0
  local _d; _d="$(lifecycle_dir)" || return 0
  [ -d "$_d" ] || return 0
  local _f
  for _f in "$_d"/*__*; do
    [ -f "$_f" ] || continue
    case "${_f##*/}" in *.expired|*.gone) continue ;; esac
    cat -- "$_f" 2>/dev/null || true
  done
  return 0
}

# _lc_state <probe> <deadline> <spawn_epoch> [agent-id] — classify ONE record against ground truth.
# Prints exactly one token:
#   live     — within deadline, and (pid probe) the process is alive
#   exited   — POSITIVE evidence the process is gone. It is accounted for; retire it.
#   expired  — past its deadline while STILL RUNNING: the hang this contract exists to surface.
# A probe we cannot read (missing heartbeat, non-numeric pid, no control surface) yields `live`:
# fail-soft, never fabricate a death OR a hang. Same rule drainer-liveness.sh applies to an absent beat.
_lc_state() {
  local _probe="${1:-none}" _dl="${2:-0}" _spawn="${3:-0}" _id="${4:-}" _now _age
  _dl="$(_lc_num "$_dl" "$_LC_FALLBACK_DEADLINE")"
  _spawn="$(_lc_num "$_spawn" 0)"
  _now="$(_lc_now)"
  case "$_probe" in
    pid:*)
      _lc_pid_live "${_probe#pid:}" || { printf 'exited'; return 0; }
      _age=$(( _now - _spawn ))
      ;;
    heartbeat:*)
      # Silence past the window is the deadline for a heartbeat population (a drainer may legitimately
      # live for hours). An absent/unreadable beat is treated as fresh — fail-soft.
      _age="$(_lc_beat_age "${_probe#heartbeat:}")" || { printf 'live'; return 0; }
      [ "$_age" -gt "$_dl" ] 2>/dev/null || { printf 'live'; return 0; }
      # STALE BEAT — but a frozen heartbeat is equally the signature of a drainer that FINISHED. Never
      # call it a hang without corroboration (HERD-122): only an agent that is POSITIVELY ALIVE while
      # silent is hung. A dead agent has simply ended; anything unprobeable is no evidence at all.
      case "$(_lc_agent_liveness "$_id")" in
        dead)  printf 'exited' ;;
        alive) printf 'expired' ;;
        *)     printf 'live' ;;
      esac
      return 0
      ;;
    *)
      _age=$(( _now - _spawn ))
      ;;
  esac
  if [ "$_age" -gt "$_dl" ] 2>/dev/null; then printf 'expired'; else printf 'live'; fi
  return 0
}

# _lc_inbox_append <ref> <snippet> — one operator-inbox row, the same TSV shape agent-watch.sh's
# _inbox_record writes: <epoch>\t<source>\t<ref>\t<author>\t<snippet>, tail-bounded to the SAME
# INBOX_LEDGER_MAX (defined by agent-watch.sh, our only production caller) so the two can never drift.
# Best-effort. No inbox destination ⇒ silent no-op.
_lc_inbox_append() {
  [ -n "${HERD_LIFECYCLE_INBOX:-}" ] || [ -n "${WORKTREES_DIR:-}" ] || return 0
  local _inbox="${HERD_LIFECYCLE_INBOX:-${WORKTREES_DIR:-}/.agent-watch-inbox}"
  local _ref="$1" _snip="$2" _n _max
  # ${VAR-} (no colon) so the caps-sync ghost scan does not read agent-watch.sh's script-local
  # INBOX_LEDGER_MAX as a config knob — the same idiom journal.sh uses for its test signals.
  _max="$(_lc_num "${INBOX_LEDGER_MAX-}" 50)"
  _snip="$(printf '%s' "$_snip" | tr '\t\n' '  ')"; _snip="${_snip:0:120}"
  mkdir -p "$(dirname -- "$_inbox")" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\n' "$(_lc_now)" "lifecycle" "$_ref" "lifecycle" "$_snip" >> "$_inbox" 2>/dev/null || return 0
  _n="$(wc -l < "$_inbox" 2>/dev/null | tr -cd '0-9')"
  if [ "${_n:-0}" -gt "$_max" ]; then
    local _keep; _keep="$(mktemp "${_inbox}.XXXXXX" 2>/dev/null)" || return 0
    tail -n "$_max" "$_inbox" > "$_keep" 2>/dev/null && mv -f "$_keep" "$_inbox" 2>/dev/null || rm -f "$_keep" 2>/dev/null
  fi
  return 0
}

# lifecycle_sweep — the per-tick supervision leg. For every record:
#   • exited  → lifecycle_retire … reason=exited. The reconcile layer: a worker that died without
#               running its teardown is still accounted for, whichever seat or event killed it.
#   • expired → journal `lifecycle_expired` ONCE (a .expired guard file keys it) carrying the
#               population's ROUTE, and append one operator-inbox row. NEVER a kill, never a gate.
#               The route names the existing owner that already knows how to tear this population
#               down (the corpse sweep TERMs a timed-out gate worker; the drainer reclaim gate spawns
#               a fresh drainer; the stall detector rows a quiet builder; the resolver escalation
#               re-tasks). This leg makes the expiry VISIBLE and ATTRIBUTABLE; the owner acts.
#   • live    → nothing at all. A record that goes healthy again (a heartbeat resumes) has its
#               .expired guard cleared, so a later expiry is journaled afresh rather than swallowed.
#
# Prints one `<population>\t<id>\t<route>` line per NEWLY-expired record (the caller may surface it);
# byte-quiet otherwise. ALWAYS returns 0 — a supervisor that can abort its supervisor is no supervisor.
lifecycle_sweep() {
  lifecycle_enabled || return 0
  local _d; _d="$(lifecycle_dir)" || return 0
  [ -d "$_d" ] || return 0
  local _f _pop _id _owner _probe _dl _spawn _route _state _gone_at
  for _f in "$_d"/*__*; do
    [ -f "$_f" ] || continue
    case "${_f##*/}" in *.expired|*.gone) continue ;; esac
    IFS=$'\t' read -r _pop _id _owner _probe _dl _spawn _route < "$_f" 2>/dev/null || continue
    [ -n "$_pop" ] && [ -n "$_id" ] || continue
    _state="$(_lc_state "$_probe" "$_dl" "$_spawn" "$_id")"
    case "$_state" in
      exited)
        # The process is GONE. Give its own population's teardown _LC_EXIT_GRACE to retire the record
        # with the TRUE reason (verdict-consumed / collected / drained) — it runs later in this tick.
        # Only once that grace lapses does the sweep claim the record with the generic `exited`, so the
        # journal reports what actually happened rather than always racing to the vaguest answer.
        if [ ! -f "${_f}.gone" ]; then
          printf '%s\n' "$(_lc_now)" > "${_f}.gone" 2>/dev/null || true
          continue
        fi
        _gone_at="$(_lc_num "$(cat "${_f}.gone" 2>/dev/null | tr -cd '0-9')" 0)"
        [ "$(( $(_lc_now) - _gone_at ))" -ge "$_LC_EXIT_GRACE" ] 2>/dev/null || continue
        lifecycle_retire "$_pop" "$_id" exited
        ;;
      expired)
        [ -f "${_f}.expired" ] && continue           # already surfaced; do not re-flood
        : > "${_f}.expired" 2>/dev/null || true
        journal_append lifecycle_expired population "$_pop" id "$_id" owner "${_owner:-unknown}" \
          probe "$_probe" deadline "$_dl" route "${_route:-operator}" \
          age_secs "$(( $(_lc_now) - $(_lc_num "$_spawn" 0) ))" component lifecycle
        _lc_inbox_append "lifecycle:${_pop}" \
          "$_pop $_id past deadline (${_dl}s) · owner=${_owner:-unknown} · route=${_route:-operator}"
        printf '%s\t%s\t%s\n' "$_pop" "$_id" "${_route:-operator}"
        ;;
      *)
        # Healthy again → re-arm the once-only notice so a future expiry is not swallowed, and drop any
        # stale exit observation (a heartbeat that resumed was never gone).
        rm -f "${_f}.expired" "${_f}.gone" 2>/dev/null || true
        ;;
    esac
  done
  return 0
}
