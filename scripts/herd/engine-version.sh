#!/usr/bin/env bash
# engine-version.sh — the ENGINE VERSION HANDSHAKE + ENGINE_AUTOUPDATE (HERD-179).
#
# WHY: the engine (this herdkit checkout) and the project (its committed .herd/config, lanes, gates)
# ship on DIFFERENT clocks. A second operator — or the same operator on a second machine — can run a
# months-old engine against a config that assumes behavior only a newer engine has. Today nothing
# notices: the stale engine happily CLAIMS an item, spawns a lane, drains a scribe request, or flips
# the backend, and the damage (a mis-claimed item, a half-migrated tracker, a lane wired to a gate
# that no longer exists) is discovered later, in the queue. The handshake makes that unrepresentable:
# the project commits the minimum engine level it needs, and a stale engine REFUSES to write.
#
# THE TWO NUMBERS:
#   _HERD_ENGINE_LEVEL   the LOCAL engine's monotonic behavior level (below — the engine's own stamp).
#   ENGINE_MIN           the project's committed floor, in .herd/config. `herd upgrade` stamps it to
#                        the level of the engine that ran the upgrade; it only ever RISES (monotonic).
#   stale  ⇔  local level < ENGINE_MIN.   ENGINE_MIN unset/0 ⇒ never stale (byte-identical off).
#
# BUMPING _HERD_ENGINE_LEVEL: raise it by exactly one in the SAME PR as an engine change whose
# behavior a project's config or lanes come to depend on (an ENGINE-BEHAVIOR merge). Do NOT bump for
# a docs/test/refactor change. Bumping it makes every project whose ENGINE_MIN reaches that level
# refuse writes from an older checkout — that is the point, and `herd update` is the remedy.
#
# WHAT REFUSES vs WHAT WARNS:
#   WRITE paths refuse (herd_engine_guard): lane spawn preflight, herd-claim, scribe-step apply,
#     `herd backend switch`. Each prints the remedy text `run herd update` and journals the refusal.
#   READ paths warn only (herd_engine_warn_if_stale): `herd status`, `herd doctor`'s advisory row.
#   ESCAPE HATCH: HERD_ENGINE_SKIP_HANDSHAKE=1 turns any refusal into a warning — and JOURNALS the
#     bypass (engine_handshake_bypass), so "I forced it" is always recoverable from `herd log`.
#
# ENGINE_AUTOUPDATE = off (ship default) | check | auto
#   off    nothing observes staleness beyond the always-advisory doctor row.
#   check  the watcher paints one quiet 'engine outdated' note and `herd doctor` calls it out.
#   auto   the watcher additionally dispatches `herd update` in a QUIESCENT window — reusing that
#          command's own builders-mid-flight refusal (it aborts under HERD_NONINTERACTIVE rather than
#          swap the engine under a running builder), rate-limited by a cooldown so a persistent
#          refusal never hammers the remote.
#
# CONTRACT (mirrors agent-update.sh):
#   • SOURCED, not executed. Defines functions + one constant ONLY; sourcing has NO side effects, so
#     it is safe in lib mode and hermetic tests. Every value (ENGINE_MIN, ENGINE_AUTOUPDATE) is read
#     LAZILY at call time, so sourcing BEFORE herd-config.sh is fine.
#   • FAIL-SOFT except where refusal IS the feature: an unreadable config, a missing journal, or a
#     non-numeric level degrade to "not stale" — the handshake never invents a lockout.
#   • Test seams: HERD_ENGINE_LEVEL_FORCE (pretend this local level), HERD_ENGINE_UPDATE_CMD,
#     HERD_ENGINE_UPDATE_SYNC, HERD_ENGINE_COOLDOWN_FILE, HERD_ENGINE_COOLDOWN_SECS.

# The LOCAL engine's behavior level. Monotonic. See "BUMPING" above before you touch this.
_HERD_ENGINE_LEVEL=1

# journal.sh provides journal_append (best-effort, never fails a caller). Source it only if the
# caller has not already — the same discipline herd-claim.sh uses. A journal that cannot resolve a
# destination simply drops the entry; a refusal is still printed and still refuses.
_HERD_ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
command -v journal_append >/dev/null 2>&1 || . "$_HERD_ENGINE_DIR/journal.sh" 2>/dev/null || true

# _herd_engine_int <value> — a non-negative integer, or 0. Guards every comparison below against a
# garbage ENGINE_MIN ("v2", "", "latest"): a config typo must never fabricate a stale-engine lockout.
_herd_engine_int() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '0' ;;
    *)           printf '%s' "$1" ;;
  esac
}

# herd_engine_level — this checkout's engine level. HERD_ENGINE_LEVEL_FORCE overrides it (test seam).
herd_engine_level() { _herd_engine_int "${HERD_ENGINE_LEVEL_FORCE:-$_HERD_ENGINE_LEVEL}"; }

# herd_engine_min — the project's committed floor (ENGINE_MIN from .herd/config, via herd-config.sh).
# Unset ⇒ 0 ⇒ the handshake is inert: a project that has never stamped a floor is never stale.
herd_engine_min() { _herd_engine_int "${ENGINE_MIN:-0}"; }

# herd_engine_stale — TRUE (0) when the local engine is BELOW the project's floor.
herd_engine_stale() { [ "$(herd_engine_level)" -lt "$(herd_engine_min)" ]; }

# herd_engine_autoupdate_mode — the normalized knob: off | check | auto. Anything else is off, so a
# typo degrades to the ship default rather than to an unattended `git pull`.
herd_engine_autoupdate_mode() {
  case "${ENGINE_AUTOUPDATE:-off}" in
    check) printf 'check' ;;
    auto)  printf 'auto' ;;
    *)     printf 'off' ;;
  esac
}

# _herd_engine_journal <event> <surface> — one journal line carrying both levels. Best-effort.
_herd_engine_journal() {
  command -v journal_append >/dev/null 2>&1 || return 0
  journal_append "$1" surface "${2:-}" engine_level "$(herd_engine_level)" engine_min "$(herd_engine_min)" || true
}

# herd_engine_guard <surface> — THE WRITE-PATH GUARD. Returns 0 when the engine is current (the
# overwhelmingly common path: one integer compare, no I/O, no journal). Returns 1 — after printing the
# refusal and its remedy to stderr — when the engine is stale, so the caller aborts BEFORE it writes.
# HERD_ENGINE_SKIP_HANDSHAKE (any non-empty value) downgrades the refusal to a journaled warning.
herd_engine_guard() {
  local surface="${1:-write}" lvl min
  herd_engine_stale || return 0
  lvl="$(herd_engine_level)"; min="$(herd_engine_min)"
  if [ -n "${HERD_ENGINE_SKIP_HANDSHAKE:-}" ]; then
    _herd_engine_journal engine_handshake_bypass "$surface"
    printf '\xe2\x9a\xa0 engine handshake BYPASSED for %s (HERD_ENGINE_SKIP_HANDSHAKE) \xe2\x80\x94 local engine level %s < ENGINE_MIN %s; the bypass is journaled. Remedy: run herd update\n' \
      "$surface" "$lvl" "$min" >&2
    return 0
  fi
  _herd_engine_journal engine_handshake_refused "$surface"
  {
    printf '\xe2\x9c\x97 engine handshake: refusing %s \xe2\x80\x94 this project requires engine level %s (ENGINE_MIN in .herd/config) but the local herdkit engine is level %s (stale).\n' \
      "$surface" "$min" "$lvl"
    printf '    remedy: run herd update\n'
    printf '    (deliberate, journaled bypass: HERD_ENGINE_SKIP_HANDSHAKE=1 <command>)\n'
  } >&2
  return 1
}

# herd_engine_warn_if_stale <surface> — THE READ-PATH ADVISORY. Never refuses; always returns 0. A
# read against a stale engine is safe (it observes, it does not act), but the operator should know
# their view may predate the project's expectations.
herd_engine_warn_if_stale() {
  local surface="${1:-read}"
  herd_engine_stale || return 0
  printf '\xe2\x9a\xa0 engine handshake: local herdkit engine is level %s but this project requires ENGINE_MIN=%s \xe2\x80\x94 %s still works (reads warn, writes refuse). Remedy: run herd update\n' \
    "$(herd_engine_level)" "$(herd_engine_min)" "$surface" >&2
  return 0
}

# herd_engine_doctor_row — the ADVISORY `herd doctor` section. Report-only: it never changes the
# doctor's exit contract (a stale engine is an operator action, not a missing dependency). Prints the
# two levels, the autoupdate mode, and — when stale — the remedy plus which surfaces refuse.
herd_engine_doctor_row() {
  local lvl min mode
  lvl="$(herd_engine_level)"; min="$(herd_engine_min)"; mode="$(herd_engine_autoupdate_mode)"
  printf '\nEngine (version handshake, advisory):\n'
  if [ "$min" -eq 0 ]; then
    printf '  \xe2\x9c\x93 engine level %s \xe2\x80\x94 this project pins no floor (ENGINE_MIN unset); the handshake is inert\n' "$lvl"
  elif herd_engine_stale; then
    printf '  \xe2\x9a\xa0 engine outdated \xe2\x80\x94 local engine level %s < ENGINE_MIN %s required by this project\n' "$lvl" "$min"
    printf '      write paths (lane spawn, claim, scribe apply, backend switch) refuse until you: run herd update\n'
    printf '      (bypass, journaled: HERD_ENGINE_SKIP_HANDSHAKE=1)\n'
  else
    printf '  \xe2\x9c\x93 engine current (level %s \xe2\x89\xa5 ENGINE_MIN %s)\n' "$lvl" "$min"
  fi
  printf '  \xc2\xb7 ENGINE_AUTOUPDATE=%s' "$mode"
  case "$mode" in
    off)   printf ' (no watcher note, no auto-update; `herd update` is manual)\n' ;;
    check) printf ' (the watcher notes an outdated engine; `herd update` stays manual)\n' ;;
    auto)  printf ' (the watcher runs `herd update` for you in a quiescent window)\n' ;;
  esac
  return 0
}

# _herd_engine_min_in_file <cfg> — the ENGINE_MIN currently assigned in <cfg> (last assignment wins,
# matching shell sourcing), as an integer; 0 when absent/garbage. Reads the FILE, not the environment:
# `herd upgrade` must stamp what is committed, not what a stray export says.
_herd_engine_min_in_file() {
  local cfg="${1:-}" v
  # CANNOT-TELL ⇒ 0 ⇒ no floor ⇒ the guard passes. Absence of evidence is never evidence of staleness
  # (the same no-fabrication rule the liveness probe follows: unknown never fabricates death). The
  # -r test also keeps an unreadable config from leaking a raw "Permission denied" out of sed.
  [ -f "$cfg" ] && [ -r "$cfg" ] || { printf '0'; return 0; }
  v="$(sed -n -E 's/^[[:space:]]*ENGINE_MIN=["'"'"']?([0-9]+).*/\1/p' "$cfg" 2>/dev/null | tail -1)"
  _herd_engine_int "$v"
}

# herd_engine_min_stamp <cfg> — MONOTONIC stamp: raise <cfg>'s ENGINE_MIN to this engine's level,
# appending the key when absent. NEVER lowers it (a project upgraded by a newer engine elsewhere must
# not be un-pinned by an older one running `herd upgrade`). Echoes the resulting ENGINE_MIN so the
# caller can report a change; returns 0 always.
herd_engine_min_stamp() {
  local cfg="${1:-}" lvl cur tmp
  # A config we cannot read or write is not one we can stamp: echo the floor we know (0) and leave it
  # alone, SILENTLY. Testing -w up front matters because a failing `>>` redirect prints its own
  # "Permission denied" diagnostic while the redirection is being SET UP — before any 2>/dev/null on
  # that same command can suppress it — so the check, not the redirect, is what keeps this quiet.
  [ -f "$cfg" ] && [ -r "$cfg" ] && [ -w "$cfg" ] || { printf '%s' "$(_herd_engine_min_in_file "$cfg")"; return 0; }
  lvl="$(herd_engine_level)"
  cur="$(_herd_engine_min_in_file "$cfg")"
  if [ "$lvl" -le "$cur" ]; then printf '%s' "$cur"; return 0; fi
  if grep -qE '^[[:space:]]*ENGINE_MIN=' "$cfg" 2>/dev/null; then
    tmp="$(mktemp)"
    if sed -E "s/^([[:space:]]*ENGINE_MIN=).*/\1$lvl/" "$cfg" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$cfg"
    else
      rm -f "$tmp"; printf '%s' "$cur"; return 0
    fi
  else
    {
      printf '\n# ENGINE_MIN — the minimum herdkit ENGINE LEVEL this project requires (HERD-179). Stamped by\n'
      printf '# `herd upgrade`; monotonic (only ever rises). An engine below it REFUSES every write path\n'
      printf '# (lane spawn, claim, scribe apply, backend switch) with the remedy: run herd update.\n'
      printf 'ENGINE_MIN=%s\n' "$lvl"
    } >> "$cfg" 2>/dev/null || { printf '%s' "$cur"; return 0; }
  fi
  printf '%s' "$lvl"
}

# ── ENGINE_AUTOUPDATE=auto: the quiescent-window updater ─────────────────────────────────────────
# _herd_engine_cooldown_file — where the last auto-update ATTEMPT was stamped. Under WORKTREES_DIR
# (the watcher's own state dir) so it survives a watcher restart; overridable as a test seam.
_herd_engine_cooldown_file() {
  if [ -n "${HERD_ENGINE_COOLDOWN_FILE:-}" ]; then printf '%s' "$HERD_ENGINE_COOLDOWN_FILE"; return 0; fi
  [ -n "${WORKTREES_DIR:-}" ] || return 1
  printf '%s' "$WORKTREES_DIR/.herd-engine-autoupdate-attempt"
}

# _herd_engine_cooldown_active — TRUE (0) when an attempt was made less than HERD_ENGINE_COOLDOWN_SECS
# ago (default 900). This is what keeps a PERSISTENT refusal — builders mid-flight all afternoon, a
# diverged engine branch — from re-running `herd update` every watcher tick.
_herd_engine_cooldown_active() {
  local f secs last now
  f="$(_herd_engine_cooldown_file)" || return 1
  [ -s "$f" ] || return 1
  secs="$(_herd_engine_int "${HERD_ENGINE_COOLDOWN_SECS:-900}")"
  [ "$secs" -gt 0 ] || return 1
  read -r last _ < "$f" 2>/dev/null || return 1
  last="$(_herd_engine_int "$last")"
  now="$(date +%s 2>/dev/null || printf '0')"
  [ "$now" -gt 0 ] || return 1
  [ "$(( now - last ))" -lt "$secs" ]
}

_herd_engine_cooldown_stamp() {
  local f; f="$(_herd_engine_cooldown_file)" || return 0
  date +%s > "$f" 2>/dev/null || true
  return 0
}

# herd_engine_autoupdate_tick — called by the watcher on a low-frequency tick. A HARD no-op unless
# ENGINE_AUTOUPDATE=auto AND the engine is stale AND the cooldown has expired. Then it dispatches
# `herd update`, whose OWN preflight is the quiescent-window check: under HERD_NONINTERACTIVE it
# refuses outright when builders are mid-flight (their lanes reference engine scripts live) or the
# engine checkout is dirty. Dispatched DETACHED by default — `herd update` ends in `herd reload`,
# which restarts this very watcher, so it must not run inside the tick that spawned it. The sync seam
# (HERD_ENGINE_UPDATE_SYNC=1) runs it inline and journals the outcome; that is how the unit drives it.
# Always returns 0 — an auto-update can never break a tick.
herd_engine_autoupdate_tick() {
  [ "$(herd_engine_autoupdate_mode)" = auto ] || return 0
  herd_engine_stale || return 0
  _herd_engine_cooldown_active && return 0
  _herd_engine_cooldown_stamp

  local cmd root log
  cmd="${HERD_ENGINE_UPDATE_CMD:-herd update}"
  root="${PROJECT_ROOT:-$(pwd)}"
  _herd_engine_journal engine_autoupdate_dispatched autoupdate

  if [ -n "${HERD_ENGINE_UPDATE_SYNC:-}" ]; then
    # shellcheck disable=SC2086  # $cmd intentionally word-splits into argv.
    if ( cd "$root" 2>/dev/null && HERD_NONINTERACTIVE=1 $cmd ) >/dev/null 2>&1; then
      _herd_engine_journal engine_autoupdate_done autoupdate
    else
      # The expected non-zero here is `herd update`'s OWN refusal (builders mid-flight / dirty engine
      # checkout / diverged branch). Not an error — the window was not quiescent. Retry after cooldown.
      _herd_engine_journal engine_autoupdate_refused autoupdate
    fi
    return 0
  fi

  log="${WORKTREES_DIR:-$root}/.herd-engine-autoupdate.log"
  # shellcheck disable=SC2086  # $cmd intentionally word-splits into argv.
  ( cd "$root" 2>/dev/null && HERD_NONINTERACTIVE=1 nohup $cmd >>"$log" 2>&1 & ) >/dev/null 2>&1 || true
  return 0
}
