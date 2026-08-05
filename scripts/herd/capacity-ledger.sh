#!/usr/bin/env bash
# capacity-ledger.sh — HERD-557 P1: the shared SUITE-CAPACITY LEDGER. docs/spikes/capacity-admission.md
# is the design doc; read it first. This file is the ledger's generic acquire-and-run machinery;
# scripts/herd/healthcheck.sh's run_heavy() is its FIRST TENANT (heavy suites — builder-local and
# watcher-dispatched). Behind CAPACITY_BUDGET (herd-config.sh; off default, ship-dormant).
#
# GROUNDED (HERD-557, external design review 2026-08-05): priority ordering AT ACQUIRE TIME does not
# fix possession-starvation — leases are non-preemptive, so a BURST of low-class work that grabs every
# unit first holds the box regardless of who arrives next and in what order (a later, higher-class
# waiter still has to wait for a low-class holder to finish; that's unavoidable without killing a
# running suite, which we never do). The fix is not time-based aging (rejected: it fights the
# RETRY-SOLO drain barrier and couples correctness to a wall clock) — it's a hard RESERVED-SLICE
# partition of the ledger's own units:
#   • a reserved TOP slice (default 1 unit when cap >= 1) that only the WATCHER class may ever lease —
#     a builder-local burst can never touch it, so a watcher suite always has a unit to admit into,
#     however saturated the general pool is.
#   • a reserved BOTTOM slice (default 1 unit when cap >= 2) that only the BUILDER-LOCAL class may
#     ever lease — symmetric guarantee against the reverse (a watcher burst crowding out every
#     builder-local suite indefinitely).
#   • whatever remains (cap - top - bottom, often 0 at the default cap=2) is the GENERAL pool, open to
#     either class on a first-acquire-wins basis — no priority comparator needed there once both ends
#     are structurally protected; a fair race is fine because starvation is already impossible.
# RETRY-SOLO (the flaky-test solo re-run) is not a priority level in that partition at all — it is a
# DRAIN BARRIER: it waits for the WHOLE ledger (every unit, both reserved slices and general) to be
# free, holds ALL of them at once so nothing else can start while it runs, then releases the lot. It
# gives up (env-suspect, HERD-546) if it cannot get there within its window.
# nice(1) +10 on the ACTUAL builder-local suite subprocess is the second half of the possession fix —
# even a builder-local run that legitimately holds a unit yields real CPU to a concurrently-running
# watcher/retry-solo suite via the OS scheduler, rather than contending as an equal.
#
# BACKBONE: capacity_flock_run.py performs the actual acquire as one ATOMIC, NON-BLOCKING flock(2) —
# portable to macOS and Linux — tied to that helper's own process/fd lifetime, so a crashed or killed
# holder's unit is released BY THE KERNEL the instant it dies. There is no reconciler, no TTL escheat
# of a live holder (forbidden — see the design doc), and no wedged-lock watchdog to write: none of
# that failure surface exists when the backbone is a real OS-level lock instead of a marker file this
# script would otherwise have to police. The `.capacity-*-live-*` marker files this library writes are
# OBSERVABILITY ONLY (queue display + journal); `capacity_reclaim_dead` is a courtesy best-effort sweep
# of a marker whose pid died before its own cleanup ran, NEVER a gating decision — the flock already
# made the real decision correctly regardless of marker staleness.
#
# OVERLOAD BREAKER: even when the ledger itself has room, a box whose loadavg is far past its core
# count is already oversubscribed by work the ledger can't see — admission freezes (every class,
# including watcher) until it cools, a safety net independent of — and orthogonal to — unit counting.
#
# Fail-soft throughout: CAPACITY_BUDGET=off, an unresolved pool dir, or a missing python3 all fall back
# to the caller running UNSLOTTED (never blocked, never a fabricated cap) — see
# capacity_acquire_and_run's early-return guards below. healthcheck.sh additionally keeps its original
# HERD-529 `_lss_*` flat-cap machinery completely untouched as ITS OWN fallback for that same
# fail-soft contract (ledger unavailable → today's flat slot cap) — see the call site in
# run_heavy() for the exact selection logic.
HERE_CAPLEDGER="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

capacity_budget_enabled() { [ "${CAPACITY_BUDGET:-off}" = "on" ]; }

# capacity_pool_dir — the SAME cross-worktree pool HERD-529's `_lss_*` uses ($WORKTREES_DIR). Empty
# when unresolved/missing — every caller below treats that as "run unslotted", exactly like `_lss_*`.
capacity_pool_dir() {
  [ -n "${WORKTREES_DIR:-}" ] && [ -d "$WORKTREES_DIR" ] && printf '%s' "$WORKTREES_DIR"
}

capacity_now_epoch() { printf '%s' "${HERD_FAKE_NOW:-$(date +%s)}"; }

# capacity_python_bin — resolve a python3 interpreter, or empty (fail-soft: caller runs unslotted).
# HERD_CAPACITY_PYTHON_BIN is a test seam mirroring the codebase's other HERD_*_CMD override style.
capacity_python_bin() {
  if [ -n "${HERD_CAPACITY_PYTHON_BIN:-}" ]; then printf '%s' "$HERD_CAPACITY_PYTHON_BIN"; return 0; fi
  command -v python3 2>/dev/null
}

_cap_journal() {
  command -v journal_append >/dev/null 2>&1 && journal_append "$@" >/dev/null 2>&1
  return 0
}

# ── overload breaker ──────────────────────────────────────────────────────────────────────────────
# capacity_cores — logical core count; HERD_CAPACITY_CORES_OVERRIDE is a deterministic test seam.
capacity_cores() {
  local n="${HERD_CAPACITY_CORES_OVERRIDE:-}"
  if [ -z "$n" ]; then n="$(command -v nproc >/dev/null 2>&1 && nproc 2>/dev/null || true)"; fi
  if [ -z "$n" ]; then n="$(command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu 2>/dev/null || true)"; fi
  case "$n" in ''|*[!0-9]*) printf '4' ;; *) printf '%s' "$n" ;; esac
}

# capacity_loadavg_1m — cross-platform 1-minute loadavg; HERD_FAKE_LOADAVG is the SAME test seam
# agent-watch.sh's _health_loadavg_1m already defines, so one fixture can pin both. Empty (never a
# fabricated number) when unreadable — capacity_overload_high treats empty as "unknown, don't judge".
capacity_loadavg_1m() {
  [ -n "${HERD_FAKE_LOADAVG:-}" ] && { printf '%s' "$HERD_FAKE_LOADAVG"; return 0; }
  if [ -r /proc/loadavg ]; then awk '{print $1}' /proc/loadavg 2>/dev/null; return 0; fi
  if command -v sysctl >/dev/null 2>&1; then sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'; return 0; fi
  return 0
}

# capacity_overload_high — true iff loadavg1m is at/over HERD_CAPACITY_OVERLOAD_MULT (default 1.5x)
# times the core count. Unreadable loadavg -> false (fail-soft; never freezes on unknown data).
capacity_overload_high() {
  local load cores mult
  load="$(capacity_loadavg_1m)"
  case "$load" in ''|*[!0-9.]*) return 1 ;; esac
  cores="$(capacity_cores)"
  mult="${HERD_CAPACITY_OVERLOAD_MULT:-1.5}"
  case "$mult" in ''|*[!0-9.]*) mult=1.5 ;; esac
  awk -v l="$load" -v c="$cores" -v m="$mult" 'BEGIN{exit !(l >= c * m)}'
}

# ── reserved-slice partition — THE one comparator every class (and every future tenant: spawn-gate,
# agent leases) routes through. cap is the ledger's total unit count for this tenant. ────────────────
capacity_reserved_top() {
  local cap="$1"
  local v="${HERD_CAPACITY_RESERVED_TOP_OVERRIDE:-}"
  if [ -n "$v" ]; then case "$v" in *[!0-9]*) : ;; *) printf '%s' "$v"; return 0 ;; esac; fi
  # cap>=2, matching capacity_reserved_bottom's own threshold — NOT cap>=1. A cap=1 ledger has exactly
  # one unit; reserving it for watcher-only would EXCLUDE builder-local from ever acquiring at all (not
  # merely lower-priority it — a correctness bug, not the intended possession fix). At cap=1 neither
  # reservation applies: the single unit is "general", a fair race between classes — degenerate but
  # SAFE, matching the flat single-slot behavior this ledger evolved from.
  [ "$cap" -ge 2 ] 2>/dev/null && printf '1' || printf '0'
}
capacity_reserved_bottom() {
  local cap="$1"
  local v="${HERD_CAPACITY_RESERVED_BOTTOM_OVERRIDE:-}"
  if [ -n "$v" ]; then case "$v" in *[!0-9]*) : ;; *) printf '%s' "$v"; return 0 ;; esac; fi
  [ "$cap" -ge 2 ] 2>/dev/null && printf '1' || printf '0'
}

# capacity_slot_partition <idx> <cap> — "top" (slot 1, watcher-only) | "bottom" (last slot,
# builder-local-only) | "general" (everything between, either class). Slot 1 is always attempted first
# by the top class and last by the bottom class (and vice versa) purely by construction below.
capacity_slot_partition() {
  local idx="$1" cap="$2" top bot
  top="$(capacity_reserved_top "$cap")"
  bot="$(capacity_reserved_bottom "$cap")"
  if [ "$top" -ge 1 ] 2>/dev/null && [ "$idx" -le "$top" ]; then printf 'top'; return 0; fi
  if [ "$bot" -ge 1 ] 2>/dev/null && [ "$idx" -gt "$((cap - bot))" ]; then printf 'bottom'; return 0; fi
  printf 'general'
}

# capacity_candidate_slots <class> <cap> — the ORDERED list of slot indices this class may attempt,
# own-reserved-slice first (a guaranteed, uncontested fast path) then the general pool (a fair race —
# no priority needed there once both ends are structurally protected). retry-solo does not call this;
# it targets every slot at once (see capacity_acquire_and_run) as a drain barrier, not a partition.
capacity_candidate_slots() {
  local class="$1" cap="$2" i part reserved=() general=()
  i=1
  while [ "$i" -le "$cap" ]; do
    part="$(capacity_slot_partition "$i" "$cap")"
    case "$class" in
      watcher)       [ "$part" = "top" ]    && reserved+=("$i") ;;
      builder-local) [ "$part" = "bottom" ] && reserved+=("$i") ;;
    esac
    [ "$part" = "general" ] && general+=("$i")
    i=$((i + 1))
  done
  printf '%s\n' "${reserved[@]:-}" "${general[@]:-}" | grep -v '^$'
}

# ── marker + lock file naming (flat namespace under the pool dir, matching HERD-529's own style) ────
capacity_lockfile()  { printf '%s/.capacity-%s-slot-%s.lock' "$1" "$2" "$3"; }
capacity_markerfile() { printf '%s/.capacity-%s-live-%s' "$1" "$2" "$3"; }

# capacity_count_live / capacity_has_live_class — OBSERVABILITY reads over the marker files a
# capacity_flock_run.py invocation currently holding a lock has written. Never used to GATE — the
# flock inside capacity_flock_run.py is the sole source of truth for whether a unit is actually free.
capacity_count_live() {
  local pool="$1" tenant="$2" n=0 f
  for f in "$pool"/.capacity-"$tenant"-live-*; do
    [ -e "$f" ] || continue
    local pid; pid="$(sed -n '1p' "$f" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && n=$((n + 1))
  done
  printf '%s' "$n"
}
capacity_has_live_class() {
  local pool="$1" tenant="$2" want="$3" f pid cls
  for f in "$pool"/.capacity-"$tenant"-live-*; do
    [ -e "$f" ] || continue
    pid="$(sed -n '1p' "$f" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || continue
    cls="$(sed -n '2p' "$f" 2>/dev/null)"
    [ "$cls" = "$want" ] && return 0
  done
  return 1
}

# capacity_reclaim_dead — best-effort courtesy sweep: drop a marker whose pid is provably dead (it
# crashed before its own `finally` cleanup ran). ESCHEAT DEAD PIDS ONLY — a marker whose pid is alive
# is NEVER removed here regardless of age; the ledger never second-guesses a live holder (that was the
# rejected TTL-escheat design — see docs/spikes/capacity-admission.md). Purely cosmetic: a lock this
# misses is still correctly free (the OS released it when the process died), so a stale marker only
# ever costs the DISPLAY an inflated "live" count until the next sweep, never a wrong admission.
capacity_reclaim_dead() {
  local pool="$1" tenant="$2" f pid
  for f in "$pool"/.capacity-"$tenant"-live-*; do
    [ -e "$f" ] || continue
    pid="$(sed -n '1p' "$f" 2>/dev/null)"
    case "$pid" in
      ''|*[!0-9]*) rm -f "$f" 2>/dev/null || true ;;
      *) kill -0 "$pid" 2>/dev/null || { rm -f "$f" 2>/dev/null || true; _cap_journal capacity_lease_reclaimed tenant "$tenant" reason dead_pid; } ;;
    esac
  done
}

_cap_solo_wait_secs() {
  local v="${HERD_CAPACITY_SOLO_WAIT_SECS:-90}"
  case "$v" in ''|*[!0-9]*) printf '90' ;; *) printf '%s' "$v" ;; esac
}

# capacity_acquire_and_run <tenant> <cap> <class> -- <cmd...> — THE main entry point. Blocks (polling,
# visible wait lines to stderr — see the HERD-529 rationale in healthcheck.sh for why stderr, not
# stdout) until admitted, runs <cmd...> with the acquired unit(s) held, and returns ITS exit status.
# class: watcher | builder-local | retry-solo. On a fail-soft path (no pool, no python3) runs <cmd...>
# UNSLOTTED immediately — the caller (healthcheck.sh) only reaches this function once it has already
# decided the ledger IS the right path (CAPACITY_BUDGET=on); this function's own fail-soft is defense
# in depth, not the primary off-switch (see the call site for the primary CAPACITY_BUDGET=off routing
# to the untouched legacy `_lss_*` flat-cap path instead).
capacity_acquire_and_run() {
  local tenant="$1" cap="$2" class="$3"; shift 3
  [ "${1:-}" = "--" ] && shift

  local pool; pool="$(capacity_pool_dir)"
  if [ -z "$pool" ]; then "$@"; return $?; fi
  local py; py="$(capacity_python_bin)"
  if [ -z "$py" ]; then "$@"; return $?; fi

  case "$cap" in ''|*[!0-9]*) cap=2 ;; esac
  [ "$cap" -ge 1 ] 2>/dev/null || cap=1

  local run_cmd=()
  if [ "$class" = "builder-local" ] && command -v nice >/dev/null 2>&1; then
    run_cmd=(nice -n 10 "$@")
  else
    run_cmd=("$@")
  fi

  local enq; enq="$(capacity_now_epoch)"
  _cap_journal capacity_lease_queued tenant "$tenant" class "$class" pid "$$"

  if [ "$class" = "retry-solo" ]; then
    local window; window="$(_cap_solo_wait_secs)"
    while :; do
      capacity_reclaim_dead "$pool" "$tenant"
      if capacity_overload_high; then
        printf 'waiting for exclusive suite capacity (retry-solo — box overloaded, deferring)\n' >&2
      else
        local locks=() i=1
        while [ "$i" -le "$cap" ]; do locks+=("$(capacity_lockfile "$pool" "$tenant" "$i")"); i=$((i + 1)); done
        local marker; marker="$(capacity_markerfile "$pool" "$tenant" solo)"
        "$py" "$HERE_CAPLEDGER/capacity_flock_run.py" --marker "$marker" --class retry-solo "${locks[@]}" -- "${run_cmd[@]:-}"
        local rc=$?
        if [ "$rc" -ne 75 ]; then
          local now; now="$(capacity_now_epoch)"
          _cap_journal capacity_lease_admitted tenant "$tenant" class retry-solo wait_secs $((now - enq))
          return "$rc"
        fi
        printf 'waiting for exclusive suite capacity (retry-solo, other suite(s) still live)\n' >&2
      fi
      local now2; now2="$(capacity_now_epoch)"
      if [ $((now2 - enq)) -ge "$window" ]; then
        _cap_journal capacity_solo_env_suspect tenant "$tenant" window_secs "$window"
        printf '⚠️  RETRY-SOLO: exclusive suite capacity unattainable within %ss under contention — classifying env-suspect (HERD-557)\n' "$window"
        return 2
      fi
      sleep "${HERD_CAPACITY_POLL_SECS:-2}" 2>/dev/null || sleep 2
    done
  fi

  while :; do
    capacity_reclaim_dead "$pool" "$tenant"
    if capacity_overload_high; then
      printf 'waiting for suite capacity (class=%s — box overloaded, deferring)\n' "$class" >&2
      sleep "${HERD_CAPACITY_POLL_SECS:-2}" 2>/dev/null || sleep 2
      continue
    fi
    if capacity_has_live_class "$pool" "$tenant" retry-solo; then
      printf 'waiting for suite capacity (class=%s — retry-solo draining the ledger)\n' "$class" >&2
      sleep "${HERD_CAPACITY_POLL_SECS:-2}" 2>/dev/null || sleep 2
      continue
    fi
    local idx
    for idx in $(capacity_candidate_slots "$class" "$cap"); do
      local lk marker rc
      lk="$(capacity_lockfile "$pool" "$tenant" "$idx")"
      marker="$(capacity_markerfile "$pool" "$tenant" "$idx")"
      "$py" "$HERE_CAPLEDGER/capacity_flock_run.py" --marker "$marker" --class "$class" "$lk" -- "${run_cmd[@]:-}"
      rc=$?
      if [ "$rc" -ne 75 ]; then
        local now; now="$(capacity_now_epoch)"
        _cap_journal capacity_lease_admitted tenant "$tenant" class "$class" slot "$idx" wait_secs $((now - enq))
        return "$rc"
      fi
    done
    local live; live="$(capacity_count_live "$pool" "$tenant")"
    printf 'waiting for suite capacity (class=%s, %s live, cap=%s)\n' "$class" "$live" "$cap" >&2
    sleep "${HERD_CAPACITY_POLL_SECS:-2}" 2>/dev/null || sleep 2
  done
}
