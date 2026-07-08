#!/usr/bin/env bash
# burst.sh — the ONE reusable BOUNDED-CONCURRENCY FAN-OUT "seam" for herdkit's READ-ONLY work
# (native-burst, HERD-107). Read-only work (repo research, review-panel passes) can BURST — fan out
# several concurrent calls to cut wall-clock — as long as the fan-out stays BOUNDED. WRITE lanes
# (scribe / backlog / merge) must NEVER burst: their single-lane serialization is a correctness
# invariant, so they simply keep running one-at-a-time (equivalently: through this helper with a
# bound of 1, which is a strict serial loop). This is a SOURCEABLE library — never exec it — so a
# consuming script gets the three helpers below with no side effects at source time.
#
#   herd_burst_enabled            — is native-burst turned ON? (config-gated by NATIVE_BURST; default off)
#   herd_burst_bound [requested]  — the EFFECTIVE concurrency cap for a fan-out, honoring REVIEW_CONCURRENCY
#                                   as the ceiling. OFF → always 1 (serial), so every caller is
#                                   byte-identical to its pre-burst behavior when the feature is off.
#   herd_burst <bound> <fn> args… — run `fn <arg>` for each arg with AT MOST <bound> running concurrently.
#
# INVARIANTS (locked by tests/test-native-burst.sh):
#   • herd_burst NEVER runs more than <bound> workers at once (the "never exceeds the cap" property).
#   • bound<=1 → a STRICT serial loop, workers executed in argument order, one at a time — this is the
#     "writes stay serial" property: a WRITE lane runs at bound 1 and is provably never concurrent.
#   • config-gated + additive: with NATIVE_BURST unset/off, herd_burst_bound is 1 everywhere, so the
#     research + review lanes preserve today's exact serial behavior, byte-identical.
#
# PORTABILITY: no `wait -n`, no associative arrays — works on bash 3.2 (macOS). Concurrency is bounded
# by launching a BATCH of up to <bound> background workers, draining the whole batch with explicit
# per-pid `wait`, then starting the next batch. Peak concurrency is therefore never above <bound>.
# Workers run in background subshells, so a worker cannot mutate its parent's state — it communicates
# only through files it writes. That is exactly the read-only-fan-out / serial-write contract.

# herd_burst_enabled — success (0) iff native-burst is switched on via NATIVE_BURST. Anything other
# than an explicit on/1/true/yes (case-insensitive) is OFF, so an unset or garbage value fails safe.
herd_burst_enabled() {
  case "$(printf '%s' "${NATIVE_BURST:-off}" | tr '[:upper:]' '[:lower:]')" in
    on|1|true|yes|y) return 0 ;;
    *)               return 1 ;;
  esac
}

# herd_burst_bound [requested] — echo the effective fan-out cap.
#   • burst OFF                       → 1 (serial; the default, byte-identical to pre-burst behavior).
#   • burst ON, no <requested>        → REVIEW_CONCURRENCY (sanitized to an int >=1).
#   • burst ON, <requested> given     → min(requested, REVIEW_CONCURRENCY) — a caller may ask for FEWER
#                                        lanes than the ceiling, but never MORE (REVIEW_CONCURRENCY is
#                                        THE bound). Non-numeric/blank requested → the ceiling.
# REVIEW_CONCURRENCY defaults to 2 when unset (matching herd-config.sh) so the helper is self-contained
# and testable without sourcing the full config loader.
herd_burst_bound() {
  local requested="${1:-}" cap
  if ! herd_burst_enabled; then printf '1'; return 0; fi
  cap="${REVIEW_CONCURRENCY:-2}"
  case "$cap" in ''|*[!0-9]*) cap=2 ;; esac
  [ "$cap" -ge 1 ] 2>/dev/null || cap=1
  if [ -n "$requested" ]; then
    case "$requested" in ''|*[!0-9]*) requested="$cap" ;; esac
    [ "$requested" -ge 1 ] 2>/dev/null || requested=1
    [ "$requested" -lt "$cap" ] && cap="$requested"
  fi
  printf '%s' "$cap"
}

# herd_burst <bound> <fn> [arg...] — run `fn <arg>` for every arg with at most <bound> concurrent.
# Returns 0 iff every worker returned 0; 1 if any worker failed; 2 on a usage error (missing fn).
# A <bound> of 1 (or anything non-numeric/<1) is a strict serial loop in argument order.
herd_burst() {
  local bound="${1:-1}" fn="${2:-}"
  shift 2 2>/dev/null || return 2
  case "$bound" in ''|*[!0-9]*) bound=1 ;; esac
  [ "$bound" -ge 1 ] 2>/dev/null || bound=1
  [ -n "$fn" ] || return 2

  local rc=0 a p
  # Serial fast-path (bound 1): the WRITE-lane / burst-off contract — one worker at a time, in order.
  if [ "$bound" -le 1 ]; then
    for a in "$@"; do "$fn" "$a" || rc=1; done
    return "$rc"
  fi

  # Bounded fan-out: fill a batch of up to <bound> background workers, then drain it fully before
  # starting the next — so at most <bound> ever run at once (bash 3.2-safe; no `wait -n`).
  local pids=()
  for a in "$@"; do
    "$fn" "$a" &
    pids+=("$!")
    if [ "${#pids[@]}" -ge "$bound" ]; then
      for p in "${pids[@]}"; do wait "$p" || rc=1; done
      pids=()
    fi
  done
  # Drain the final partial batch. Guard the expansion so an empty array is safe under `set -u`.
  if [ "${#pids[@]}" -gt 0 ]; then
    for p in "${pids[@]}"; do wait "$p" || rc=1; done
  fi
  return "$rc"
}
