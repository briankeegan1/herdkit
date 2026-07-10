#!/usr/bin/env bash
# engine-seat.sh — CROSS-SEAT DUAL-ENGINE SAFETY (HERD-308, engine-port P3.5).
#
# WHY: the engine port (HERD-300) opens a DUAL-ENGINE WINDOW — a bash watcher and a Python watcher, or
# two operators on different engine checkouts, writing the SAME mutable state under one worktree pool.
# Two engines at different behavior levels silently coexisting is the hazard: the newer one writes a
# format/semantics the older one then clobbers, and the corruption (a half-migrated state store, a
# mis-shaped journal row, a claim written two different ways) is discovered later, in the queue. The
# engine version handshake (engine-version.sh) stops a STALE engine from writing against a project that
# has PINNED a floor (ENGINE_MIN); this file is the complementary POOL-LEVEL invariant that needs no
# committed floor: every seat STAMPS the engine level it writes at into a shared pool registry, and the
# watcher RECONCILES that registry every tick. Two distinct levels writing one pool is never silent —
# the STALE seat halts loudly (its writes are HELD) so there are ZERO cross-mismatch writes.
#
# THE ONE SHARED STAMP (leg a). Every mutable-state write under the worktree pool carries the writer's
# engine level through ONE helper — herd_engine_seat_stamp — which appends the writer's (seat, level,
# time, state) to $WORKTREES_DIR/.herd/engine-seats.tsv. Bash-side today the watcher stamps once per
# tick (the tick IS its unit of mutable-state work over the pool); in P4 the pysrc store accessors adopt
# the SAME row format on every store write, so the reconcile below is implementation-agnostic. The
# registry is APPEND-ONLY (atomic sub-PIPE_BUF appends, journal.sh's concurrent-writer discipline) so
# two seats writing at once never lose an update; readers collapse to the latest row per seat.
#
# THE RECONCILE (leg a). herd_engine_seat_reconcile stamps this seat, reads the ACTIVE seats (a row is
# active while it is younger than the TTL — a seat that stopped writing ages out), and compares levels:
#   • COHERENT — one distinct active level (the overwhelmingly common single-seat case) → proceed.
#   • STALE    — this seat's level is BELOW the highest active level → HALT: loud console row, journaled
#                engine_seat_mismatch, and herd_engine_seat_hold returns true so writes are refused.
#   • LEAD     — this seat is at the highest level but a lower-level seat shares the pool → proceed, but
#                say so loudly (never silent coexistence); the stale seat is the one that halts.
#
# THE QUIESCE GATE (leg b) — machinery for the P4 migration runner (which does not exist yet; this is
# the seam it will call). A store migration must not run while another engine is still writing the
# store. herd_engine_migration_guard refuses to migrate unless every OTHER registered seat is QUIESCED
# (herd_engine_seat_quiesce marks a seat's row quiesced) or an explicit DUAL-WRITE WINDOW is declared
# (HERD_ENGINE_DUALWRITE=1, or a marker under the pool). A seat aged past the TTL is gone, not a blocker.
#
# CONTRACT (mirrors engine-version.sh):
#   • SOURCED, never executed. Defines functions + reads everything LAZILY at call time; sourcing has
#     NO side effect (safe in lib mode and hermetic tests, and before herd-config.sh sets WORKTREES_DIR).
#   • FAIL-SOFT except where the HALT is the feature: an unresolvable pool, an unreadable/garbage
#     registry, or a missing clock all degrade to COHERENT — the reconcile never INVENTS a halt.
#   • SHIP-DORMANT: the watcher only stamps/reconciles under ENGINE_SEAT_RECONCILE=on (default off);
#     with it off nothing is written and behavior is byte-identical. Single-seat is always coherent, so
#     even ON it is a hard no-op for a solo operator.
#   • Test seams: HERD_ENGINE_SEAT_ID (pretend this seat id), HERD_ENGINE_SEAT_REGISTRY (registry path),
#     HERD_ENGINE_SEAT_NOW (pretend this epoch), HERD_ENGINE_SEAT_TTL (active window secs),
#     HERD_ENGINE_DUALWRITE / HERD_ENGINE_DUALWRITE_MARKER (declare a dual-write window).

# Resolve this script's dir so the engine-version.sh + journal.sh lookups work from any HERE.
_HERD_SEAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# journal.sh provides journal_append (best-effort, never fails a caller). Source only if the caller has
# not already — the same discipline herd-claim.sh / engine-version.sh use.
# shellcheck source=/dev/null
command -v journal_append >/dev/null 2>&1 || . "$_HERD_SEAT_DIR/journal.sh" 2>/dev/null || true
# engine-version.sh provides herd_engine_level — THE level every stamp carries. Sourced only if absent.
# shellcheck source=/dev/null
command -v herd_engine_level >/dev/null 2>&1 || . "$_HERD_SEAT_DIR/engine-version.sh" 2>/dev/null || true

# Reconcile-result globals — set by herd_engine_seat_reconcile, read by the console note + the hold
# predicate. Initialised to the coherent single-seat answer so a caller that reads them before any
# reconcile ran (a lib-mode unit of do_merge) sees "no halt" and stays byte-identical.
_HERD_SEAT_VERDICT="coherent"
_HERD_SEAT_SELF_LEVEL=""
_HERD_SEAT_MAX_LEVEL=""
_HERD_SEAT_PEER=""
_HERD_SEAT_JOURNAL_SIG=""
_HERD_QUIESCE_BLOCKERS=""

# herd_engine_seat_id — this seat's identity, resolved the SAME order a claim is (herd-claim.sh):
# WATCHER_OWNER (explicit, gh-free) → WATCHER_VIEW_AUTHOR (the watcher-lens identity) → host:pid (a
# stable-per-process fallback so a registry row is never keyed on an empty id). HERD_ENGINE_SEAT_ID
# overrides it outright (the documented test seam + the way a P4 runner names a synthetic seat).
herd_engine_seat_id() {
  if   [ -n "${HERD_ENGINE_SEAT_ID:-}" ];   then printf '%s' "$HERD_ENGINE_SEAT_ID"
  elif [ -n "${WATCHER_OWNER:-}" ];         then printf '%s' "$WATCHER_OWNER"
  elif [ -n "${WATCHER_VIEW_AUTHOR:-}" ];   then printf '%s' "$WATCHER_VIEW_AUTHOR"
  else printf '%s:%s' "${HOSTNAME:-host}" "$$"
  fi
}

# herd_engine_seat_registry — the append-only pool registry path. HERD_ENGINE_SEAT_REGISTRY (test seam)
# wins; else $WORKTREES_DIR/.herd/engine-seats.tsv (the pool's own .herd/ state dir, beside the journal).
# Returns non-zero when neither resolves, so a caller with no pool simply skips (fail-soft, no invention).
herd_engine_seat_registry() {
  if [ -n "${HERD_ENGINE_SEAT_REGISTRY:-}" ]; then printf '%s' "$HERD_ENGINE_SEAT_REGISTRY"; return 0; fi
  [ -n "${WORKTREES_DIR:-}" ] || return 1
  printf '%s' "$WORKTREES_DIR/.herd/engine-seats.tsv"
}

# _herd_engine_seat_now — the current epoch, overridable by HERD_ENGINE_SEAT_NOW (test seam). A clock
# that cannot be read degrades to 0, which makes every row read as "just now" (never fabricates an
# aged-out seat — the same absence-is-not-evidence rule engine-version's staleness read follows).
_herd_engine_seat_now() {
  if [ -n "${HERD_ENGINE_SEAT_NOW:-}" ]; then printf '%s' "$HERD_ENGINE_SEAT_NOW"; return 0; fi
  date +%s 2>/dev/null || printf '0'
}

# _herd_engine_seat_ttl — the active-window seconds. A seat whose latest stamp is older than this has
# stopped writing and is treated as GONE (not a coexisting engine, not a migration blocker). Default
# 120s ≫ the 4s watcher tick, so a live seat is never falsely aged out. HERD_ENGINE_SEAT_TTL overrides;
# 0/garbage disables aging (every stamped row counts) — the strict-safe direction for the reconcile.
_herd_engine_seat_ttl() {
  case "${HERD_ENGINE_SEAT_TTL:-}" in
    ''|*[!0-9]*) printf '120' ;;
    *)           printf '%s' "$HERD_ENGINE_SEAT_TTL" ;;
  esac
}

# _herd_engine_seat_int <value> — a non-negative integer or 0 (guards a garbage level column so a
# corrupt registry row can never fabricate a mismatch out of a non-numeric comparison).
_herd_engine_seat_int() {
  case "${1:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac
}

# herd_engine_seat_stamp [state] — append ONE row recording that THIS seat wrote the pool at its current
# engine level. state is active (default) or quiesced. Append-only + atomic (a single sub-PIPE_BUF
# printf under O_APPEND, like journal.sh) so concurrent seats never lose an update. Best-effort:
# ALWAYS returns 0; an unwritable pool simply drops the stamp (the reconcile then reads what it can).
# Opportunistically COMPACTS the file (keep only the latest row per seat) when it grows past a bound, so
# a long-lived watcher stamping every tick does not grow it without limit; a lost compaction race just
# leaves a larger file, never wrong data (the compacted snapshot is always latest-per-seat).
herd_engine_seat_stamp() {
  local state="${1:-active}" reg id lvl now dir
  reg="$(herd_engine_seat_registry)" || return 0
  id="$(herd_engine_seat_id)"; [ -n "$id" ] || return 0
  lvl="$(_herd_engine_seat_int "$(herd_engine_level 2>/dev/null || printf 0)")"
  now="$(_herd_engine_seat_now)"
  dir="${reg%/*}"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  # Atomic append. id/state carry no tabs; level/now are integers — the row can never be shredded.
  printf '%s\t%s\t%s\t%s\n' "$id" "$lvl" "$now" "$state" >> "$reg" 2>/dev/null || return 0
  # Compaction (best-effort): if the append log has many more lines than there are seats, rewrite it to
  # the latest row per seat. Threshold generous so it fires rarely; guarded so a failure is a no-op.
  local n; n="$(wc -l < "$reg" 2>/dev/null | tr -cd '0-9')"; n="${n:-0}"
  if [ "$n" -gt 256 ] 2>/dev/null; then
    local tmp; tmp="$(mktemp "${dir}/.engine-seats.XXXXXX" 2>/dev/null)" || return 0
    if awk -F'\t' '{ lvl[$1]=$2; ep[$1]=$3; st[$1]=$4; seen[$1]=1 }
                   END { for (i in seen) printf "%s\t%s\t%s\t%s\n", i, lvl[i], ep[i], st[i] }' \
         "$reg" 2>/dev/null > "$tmp"; then
      mv "$tmp" "$reg" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
  return 0
}

# _herd_engine_seat_active_rows — print the LATEST row per seat that is still within the TTL window, as
# "<id>\t<level>\t<epoch>\t<state>". The registry is chronological, so the last row per id wins. Empty
# output (returns 0) when there is no registry, no pool, or every row has aged out.
_herd_engine_seat_active_rows() {
  local reg now ttl
  reg="$(herd_engine_seat_registry)" || return 0
  [ -f "$reg" ] && [ -r "$reg" ] || return 0
  now="$(_herd_engine_seat_now)"; ttl="$(_herd_engine_seat_ttl)"
  awk -F'\t' -v now="$now" -v ttl="$ttl" '
    NF >= 3 { id=$1; lvl[id]=$2; ep[id]=$3; st[id]=$4 }   # last row per id wins (chronological file)
    END {
      for (i in lvl) {
        age = now - ep[i]
        if (ttl <= 0 || age < 0 || age <= ttl)
          printf "%s\t%s\t%s\t%s\n", i, lvl[i], ep[i], (st[i]=="" ? "active" : st[i])
      }
    }' "$reg" 2>/dev/null
}

# _herd_engine_seat_journal_mismatch — journal ONE engine_seat_mismatch per distinct (verdict,self,max)
# signature, so a persisting mismatch does not re-journal every 4s tick. Best-effort.
_herd_engine_seat_journal_mismatch() {
  local sig="${_HERD_SEAT_VERDICT}:${_HERD_SEAT_SELF_LEVEL}:${_HERD_SEAT_MAX_LEVEL}"
  [ "$sig" = "$_HERD_SEAT_JOURNAL_SIG" ] && return 0
  _HERD_SEAT_JOURNAL_SIG="$sig"
  command -v journal_append >/dev/null 2>&1 || return 0
  journal_append engine_seat_mismatch verdict "$_HERD_SEAT_VERDICT" \
    self_level "$_HERD_SEAT_SELF_LEVEL" max_level "$_HERD_SEAT_MAX_LEVEL" \
    seat "$(herd_engine_seat_id)" peer "${_HERD_SEAT_PEER:-}" || true
}

# herd_engine_seat_reconcile — THE per-tick invariant (leg a). Stamps this seat active, then reconciles
# the pool's active seats. Sets the _HERD_SEAT_* globals and returns 0 (COHERENT) or 1 (mismatch:
# verdict stale|lead). Fail-soft: any read failure leaves the coherent defaults and returns 0.
herd_engine_seat_reconcile() {
  local self self_lvl rows max peer distinct id lvl ep st
  self="$(herd_engine_seat_id)"
  self_lvl="$(_herd_engine_seat_int "$(herd_engine_level 2>/dev/null || printf 0)")"
  _HERD_SEAT_VERDICT="coherent"
  _HERD_SEAT_SELF_LEVEL="$self_lvl"
  _HERD_SEAT_MAX_LEVEL="$self_lvl"
  _HERD_SEAT_PEER=""

  herd_engine_seat_stamp active
  rows="$(_herd_engine_seat_active_rows)" || rows=""
  [ -n "$rows" ] || return 0

  max="$self_lvl"; distinct=""; peer=""
  while IFS=$'\t' read -r id lvl ep st; do
    [ -n "$id" ] || continue
    lvl="$(_herd_engine_seat_int "$lvl")"
    case " $distinct " in *" $lvl "*) : ;; *) distinct="${distinct:+$distinct }$lvl" ;; esac
    [ "$lvl" -gt "$max" ] && max="$lvl"
    # Remember a seat at a level DIFFERENT from ours to name in the loud row.
    if [ "$id" != "$self" ] && [ "$lvl" -ne "$self_lvl" ]; then peer="$id"; fi
  done <<EOF
$rows
EOF

  _HERD_SEAT_MAX_LEVEL="$max"
  _HERD_SEAT_PEER="$peer"

  # One distinct active level ⇒ every writer agrees ⇒ coherent (the single-seat steady state).
  case "$distinct" in *" "*) : ;; *) return 0 ;; esac

  if [ "$self_lvl" -lt "$max" ]; then
    _HERD_SEAT_VERDICT="stale"
  else
    _HERD_SEAT_VERDICT="lead"
  fi
  _herd_engine_seat_journal_mismatch
  return 1
}

# herd_engine_seat_hold — TRUE (0) when the last reconcile found THIS seat stale under a live mismatch.
# THE predicate a write path consults to refuse a cross-mismatch write. Coherent/lead ⇒ false (proceed).
herd_engine_seat_hold() { [ "${_HERD_SEAT_VERDICT:-coherent}" = stale ]; }

# ── QUIESCE machinery for the P4 migration runner (leg b) ─────────────────────────────────────────

# _herd_engine_dualwrite_marker — the dual-write-window marker path ($WORKTREES_DIR/.herd/engine-dualwrite
# by default; HERD_ENGINE_DUALWRITE_MARKER overrides). Returns non-zero when no pool resolves.
_herd_engine_dualwrite_marker() {
  if [ -n "${HERD_ENGINE_DUALWRITE_MARKER:-}" ]; then printf '%s' "$HERD_ENGINE_DUALWRITE_MARKER"; return 0; fi
  [ -n "${WORKTREES_DIR:-}" ] || return 1
  printf '%s' "$WORKTREES_DIR/.herd/engine-dualwrite"
}

# herd_engine_dualwrite_active — TRUE (0) when an operator has DECLARED a dual-write window: the
# HERD_ENGINE_DUALWRITE env truthy, or the marker file present. This is the deliberate, auditable
# override that lets a migration proceed while two engines intentionally both write (P4's transitional
# window) — the analog of engine-version.sh's HERD_ENGINE_SKIP_HANDSHAKE escape hatch.
herd_engine_dualwrite_active() {
  case "${HERD_ENGINE_DUALWRITE:-}" in 1|true|yes|on|ON|On) return 0 ;; esac
  local marker; marker="$(_herd_engine_dualwrite_marker)" || return 1
  [ -n "$marker" ] && [ -f "$marker" ]
}

# herd_engine_seat_quiesce — mark THIS seat quiesced (it has stopped writing the store; the migration
# may run). Just a stamp with state=quiesced; best-effort, always 0.
herd_engine_seat_quiesce() { herd_engine_seat_stamp quiesced; }

# herd_engine_quiesce_ok [self-id] — TRUE (0) when a store migration may proceed: every OTHER registered
# active seat is quiesced (or has aged out), OR a dual-write window is declared. FALSE (1) when at least
# one other seat is still actively writing — the blockers are left in $_HERD_QUIESCE_BLOCKERS. Reads the
# TTL-filtered active set, so a seat that simply stopped (past TTL) is not a blocker.
herd_engine_quiesce_ok() {
  local self="${1:-}" rows id lvl ep st
  [ -n "$self" ] || self="$(herd_engine_seat_id)"
  _HERD_QUIESCE_BLOCKERS=""
  herd_engine_dualwrite_active && return 0
  rows="$(_herd_engine_seat_active_rows)" || rows=""
  while IFS=$'\t' read -r id lvl ep st; do
    [ -n "$id" ] || continue
    [ "$id" = "$self" ] && continue
    [ "$st" = quiesced ] && continue
    _HERD_QUIESCE_BLOCKERS="${_HERD_QUIESCE_BLOCKERS:+$_HERD_QUIESCE_BLOCKERS }$id"
  done <<EOF
$rows
EOF
  [ -z "$_HERD_QUIESCE_BLOCKERS" ]
}

# herd_engine_migration_guard [surface] — THE gate the P4 migration runner crosses BEFORE it migrates
# the store. Returns 0 to PROCEED, 1 to REFUSE. A declared dual-write window proceeds (journaled). All
# other seats quiesced/aged-out proceeds. Otherwise it REFUSES loudly — naming the un-quiesced seats and
# the remedy — and journals engine_migration_refused, so a migration never silently races a live writer.
herd_engine_migration_guard() {
  local surface="${1:-migration}"
  if herd_engine_dualwrite_active; then
    command -v journal_append >/dev/null 2>&1 && \
      journal_append engine_migration_dualwrite surface "$surface" seat "$(herd_engine_seat_id)" || true
    return 0
  fi
  if herd_engine_quiesce_ok; then
    return 0
  fi
  command -v journal_append >/dev/null 2>&1 && \
    journal_append engine_migration_refused surface "$surface" seat "$(herd_engine_seat_id)" \
      blockers "$_HERD_QUIESCE_BLOCKERS" || true
  {
    printf '\xf0\x9f\x9b\x91 engine migration: refusing %s \xe2\x80\x94 %s other seat(s) are still writing this pool: %s\n' \
      "$surface" "$(printf '%s' "$_HERD_QUIESCE_BLOCKERS" | wc -w | tr -d ' ')" "$_HERD_QUIESCE_BLOCKERS"
    printf '    a store migration must not race a live engine. Remedy: quiesce every seat first,\n'
    printf '    or declare a deliberate dual-write window with HERD_ENGINE_DUALWRITE=1 (journaled).\n'
  } >&2
  return 1
}
