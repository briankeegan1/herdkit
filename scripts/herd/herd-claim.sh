#!/usr/bin/env bash
# herd-claim.sh — atomic-ish work-item claiming (HERD-50). Sourced by the builder lanes
# (herd-quick.sh / herd-feature.sh) and called ONCE, BEFORE any worktree/agent is created.
#
# WHY: two operators now work one repo concurrently and the pick race is REAL. Picking is
# check-then-act — a coordinator reads `herd backlog`, spawns a builder, THEN enqueues an async
# `mark in-progress` the scribe drains minutes later. A second coordinator can pick the SAME item
# inside that window, and the scribe does NOT reject the duplicate state write (idempotent no-op) —
# so both builders run. This step closes that window by CLAIMING the item synchronously up front.
#
# CONTRACT (herd_claim_or_abort <slug>):
#   • Runs the claim ONLY when CLAIM_REQUIRED is on AND a tracker id is present (HERD_CLAIM_ID, else
#     the HERD_ITEM_REF the coordinator already threads). Otherwise returns 0 immediately — a no-id
#     or disabled spawn is byte-for-byte today's behavior (the async scribe still marks it in-progress).
#   • CLAIM GUARD (HERD-117): BEFORE claiming, it reads the item's CURRENT tracker state. A Done/Canceled
#     item is a STALE pick — claiming it would silently REOPEN a shipped item (the 2026-07-08 double-build:
#     a second operator's stale pick reclaimed HERD-55 minutes after it merged, flipping Done → In Progress
#     and spawning a duplicate PR that arrived already conflicting). So a closed item is REFUSED loudly
#     (evidence + a re-ground pointer), journaled as claim_refused reason=already-done, and the lane aborts
#     — the claim path NEVER transitions Done → In Progress (a reopen is a coordinator/scribe act only).
#     HERD_FORCE_SPAWN=1 is the deliberate, journaled override: build against the closed item anyway WITHOUT
#     reclaiming it (the tracker item stays closed). Fail-soft: a state that cannot be read falls through to
#     today's claim behavior with a journal note, so tracker flakiness never blocks a legitimate spawn.
#   • On a definitive "already claimed by another identity" it prints a LOUD abort and returns NON-ZERO,
#     so the lane exits before creating a worktree or agent.
#   • On our own successful claim, a self-claim (re-spawn of our own item), or a FAIL-SOFT backend error
#     (backend unreachable / no claim op / no such item) it returns 0 and the lane proceeds. Never
#     hard-block a solo operator on a backend hiccup.
#   • Byte-identical behavior for a claim on a genuinely OPEN item (the added state read is read-only).
#
# CLAIM RELEASE (herd_claim_release <id> <who> <slug> <reason>, HERD-162 F12):
#   The claim's missing other half. Nothing in the engine ever un-claimed an item, so a builder that
#   died BEFORE opening a PR left its tracker item claimed forever — the ALREADY abort above then
#   wedges it against every other operator, permanently, behind a message that is technically true and
#   operationally useless. herd_claim_release releases OUR OWN claim through the backend's
#   _backend_release_item op. It is gated by CLAIM_RELEASE (off | flag | release, default off), NEVER
#   steals another identity's claim, and NEVER touches the item's workflow state (a reopen/re-queue is
#   a coordinator act). The watcher's dead-builder reconcile is its only caller, and it owns the rails
#   that decide WHEN an item is genuinely abandoned. Fail-soft everywhere: a backend with no release op
#   degrades to `flag`.
#
# The claim itself is delegated to the active SCRIBE_BACKEND's _backend_claim_item op (backends/*.sh),
# sourced in a SUBSHELL so the _backend_* helpers never leak into the lane's namespace — the same
# discipline agent-watch.sh's _reconcile_via_ref and dep-watcher.sh's _dw_check_state use.
#
# Standalone (also how the hermetic tests drive it):
#   CLAIM_REQUIRED=on HERD_CLAIM_ID=HERD-50 WATCHER_OWNER=alice \
#     bash -c '. scripts/herd/herd-claim.sh; herd_claim_or_abort my-slug'

# Resolve this script's own dir so the backend lookup works no matter what HERE the caller set.
_HERD_CLAIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# journal.sh provides journal_append, which the backend's _backend_tw_journal uses to record a claim
# as a tracker_write (HERD-85). Source it only if a caller (the lane) has not already — best-effort,
# so a standalone claim without WORKTREES_DIR simply drops the entry and never blocks the claim.
command -v journal_append >/dev/null 2>&1 || . "$_HERD_CLAIM_DIR/journal.sh" 2>/dev/null || true

# engine-version.sh provides herd_engine_guard, the ENGINE VERSION HANDSHAKE (HERD-179) the claim
# crosses before it writes tracker state. Sourced only if the lane has not already; functions only.
# shellcheck source=/dev/null
command -v herd_engine_guard >/dev/null 2>&1 || . "$_HERD_CLAIM_DIR/engine-version.sh" 2>/dev/null || true

# _herd_claim_identity — the operator identity a claim is stamped with. WATCHER_OWNER wins (an
# explicit, gh-free identity), then WATCHER_VIEW_AUTHOR (reuse the watcher-lens identity, same order
# agent-watch.sh resolves), else the authenticated `gh api user` login. Empty when none resolves —
# the caller substitutes a placeholder so a claim is never stamped with an empty owner.
_herd_claim_identity() {
  if   [ -n "${WATCHER_OWNER:-}" ];       then printf '%s' "$WATCHER_OWNER"
  elif [ -n "${WATCHER_VIEW_AUTHOR:-}" ]; then printf '%s' "$WATCHER_VIEW_AUTHOR"
  else gh api user -q .login 2>/dev/null || true
  fi
}

# _herd_claim_dispatch <id> <identity> — source the active backend in a subshell and run its claim
# op. Prints "<RESULT>\t<OWNER>" on stdout where RESULT ∈ CLAIMED|SELF|ALREADY|UNREACHABLE. A backend
# that defines no _backend_claim_item op (e.g. changelog), an unknown backend, or a sourcing error all
# map to UNREACHABLE so the caller fails soft. Secrets are loaded for API backends exactly as
# scribe-step.sh / _reconcile_via_ref do.
_herd_claim_dispatch() {
  local id="$1" who="$2" bdir bfile
  bdir="${SCRIBE_BACKEND_DIR:-$_HERD_CLAIM_DIR/backends}"
  bfile="$bdir/${SCRIBE_BACKEND:-file}.sh"
  if [ ! -f "$bfile" ]; then printf 'UNREACHABLE\t'; return 0; fi
  (
    # API-backend credentials live in .herd/secrets (gitignored); file/changelog need none.
    if [ -n "${PROJECT_ROOT:-}" ] && [ -f "$PROJECT_ROOT/.herd/secrets" ]; then
      # shellcheck source=/dev/null
      . "$PROJECT_ROOT/.herd/secrets"
    fi
    # shellcheck source=/dev/null
    . "$bfile" 2>/dev/null || { printf 'UNREACHABLE\t'; exit 0; }
    command -v _backend_claim_item >/dev/null 2>&1 || { printf 'UNREACHABLE\t'; exit 0; }
    [ -n "${PROJECT_ROOT:-}" ] && cd "$PROJECT_ROOT" 2>/dev/null
    # Attribute the claim's tracker_write (HERD-85) to the 'claim' component.
    export HERD_COMPONENT="claim"
    _CLAIM_RESULT=""; _CLAIM_OWNER=""
    _backend_claim_item "$id" "$who" 2>/dev/null || true
    printf '%s\t%s' "${_CLAIM_RESULT:-UNREACHABLE}" "${_CLAIM_OWNER:-}"
  )
}

# _herd_state_dispatch <id> — read the item's CURRENT tracker state via the active backend's read-only
# _backend_item_state op, sourced in a SUBSHELL with the same namespace/secrets discipline as
# _herd_claim_dispatch (the _backend_* helpers never leak into the lane). Prints "<STATE>\t<UPDATED>" on
# stdout where STATE ∈ open|closed|in-progress and UPDATED is a best-effort last-updated stamp (may be
# empty — not every backend exposes one). A backend that cannot be sourced, defines no state op, or errors
# maps to a bare "UNREADABLE" (no tab) so the caller fails soft and falls through to today's claim path.
_herd_state_dispatch() {
  local id="$1" bdir bfile
  bdir="${SCRIBE_BACKEND_DIR:-$_HERD_CLAIM_DIR/backends}"
  bfile="$bdir/${SCRIBE_BACKEND:-file}.sh"
  if [ ! -f "$bfile" ]; then printf 'UNREADABLE'; return 0; fi
  (
    # API-backend credentials live in .herd/secrets (gitignored); file/changelog need none.
    if [ -n "${PROJECT_ROOT:-}" ] && [ -f "$PROJECT_ROOT/.herd/secrets" ]; then
      # shellcheck source=/dev/null
      . "$PROJECT_ROOT/.herd/secrets"
    fi
    # shellcheck source=/dev/null
    . "$bfile" 2>/dev/null || { printf 'UNREADABLE'; exit 0; }
    command -v _backend_item_state >/dev/null 2>&1 || { printf 'UNREADABLE'; exit 0; }
    [ -n "${PROJECT_ROOT:-}" ] && cd "$PROJECT_ROOT" 2>/dev/null
    ITEM_STATE=""; ITEM_UPDATED=""
    _backend_item_state "$id" 2>/dev/null || { printf 'UNREADABLE'; exit 0; }
    [ -n "${ITEM_STATE:-}" ] || { printf 'UNREADABLE'; exit 0; }
    printf '%s\t%s' "$ITEM_STATE" "${ITEM_UPDATED:-}"
  )
}

# _herd_force_spawn — is the deliberate HERD_FORCE_SPAWN override in effect? Same truthy set the other
# lanes/gates honor (herd-config.sh, herd-spawn-gate.sh). Returns 0 (forced) / 1 (not).
_herd_force_spawn() {
  case "${HERD_FORCE_SPAWN:-}" in
    1|true|yes|on|ON|On) return 0 ;;
    *) return 1 ;;
  esac
}

# herd_claim_or_abort <slug> — the lane-facing entry point. See the header contract. Returns 0 to
# PROCEED, non-zero to ABORT the spawn.
herd_claim_or_abort() {
  local slug="${1:-?}" id who parsed result owner
  # ENGINE VERSION HANDSHAKE (HERD-179), FIRST — this is the earliest write gate a lane crosses (it
  # runs before new-feature.sh, hence before herd_preflight's copy of the guard). A claim is a tracker
  # WRITE, and everything downstream of it (worktree, branch, tab, agent) is a write too, so an engine
  # below the project's committed ENGINE_MIN aborts the spawn here with the remedy `run herd update`.
  # Inert when the project pins no floor; HERD_ENGINE_SKIP_HANDSHAKE=1 downgrades it to a journaled warn.
  if command -v herd_engine_guard >/dev/null 2>&1; then
    herd_engine_guard "herd-claim ($slug)" || return 1
  fi
  # OFF by default → zero behavior change (the async scribe mark-in-progress path is untouched).
  case "${CLAIM_REQUIRED:-off}" in
    1|true|yes|on|ON|On) ;;
    *) return 0 ;;
  esac
  # Active only when a tracker id is present. HERD_CLAIM_ID (explicit) wins over the HERD_ITEM_REF the
  # coordinator already threads for tracked items. No id → passthrough (scribe marks it async).
  id="${HERD_CLAIM_ID:-${HERD_ITEM_REF:-}}"
  [ -n "$id" ] || return 0
  who="$(_herd_claim_identity)"; [ -n "$who" ] || who="unknown-operator"

  # ── CLAIM GUARD (HERD-117): never claim (and so never reopen) a Done/Canceled item ──────────────────
  # Read the item's CURRENT state up front. A closed item is a stale pick — refuse LOUDLY with evidence
  # + a re-ground pointer, journal it, and abort the spawn, so the claim below never flips Done → In
  # Progress. HERD_FORCE_SPAWN=1 builds against it anyway WITHOUT reclaiming (the item stays closed).
  # Fail-soft: an unreadable state journals a note and falls through to today's claim path — an OPEN item
  # is byte-for-byte unchanged (this read is read-only).
  local sparsed sstate supdated
  sparsed="$(_herd_state_dispatch "$id")"
  sstate="${sparsed%%$'\t'*}"
  case "$sparsed" in *$'\t'*) supdated="${sparsed#*$'\t'}" ;; *) supdated="" ;; esac
  case "$sstate" in
    closed)
      if _herd_force_spawn; then
        echo "⚠️  $id is Done/Canceled, but HERD_FORCE_SPAWN=1 — building '$slug' anyway WITHOUT reclaiming it (the tracker item stays closed; reopening is a coordinator/scribe act)." >&2
        journal_append claim_forced ref "$id" reason already-done state "$sstate" who "$who" slug "$slug"
        return 0
      fi
      echo "🛑 refusing to claim $id — it is already Done/Canceled${supdated:+ (last updated $supdated)}; a shipped item must NOT be silently reopened, NOT spawning '$slug' (no worktree, no agent)." >&2
      echo "    Your pick is stale — re-ground it against \`herd backlog\` (the item was almost certainly shipped since you read the queue)." >&2
      echo "    To build against it deliberately anyway — without reopening it — re-run with HERD_FORCE_SPAWN=1 (a journaled override)." >&2
      journal_append claim_refused ref "$id" reason already-done state "$sstate" who "$who" slug "$slug"
      return 1 ;;
    open|in-progress)
      : ;;   # genuinely open (or already started) → proceed to the claim exactly as before
    *)
      # UNREADABLE / anything unexpected → fail soft: note it and let the claim below run today's path.
      journal_append claim_state_unreadable ref "$id" backend "${SCRIBE_BACKEND:-file}" slug "$slug" ;;
  esac

  parsed="$(_herd_claim_dispatch "$id" "$who")"
  result="${parsed%%$'\t'*}"; owner="${parsed#*$'\t'}"
  case "$result" in
    CLAIMED)
      echo "🔒 claimed $id as '$who' — proceeding to build '$slug'."
      return 0 ;;
    SELF)
      echo "🔒 $id is already claimed by you ('$who') — proceeding to build '$slug'."
      return 0 ;;
    ALREADY)
      echo "🛑 $id is already claimed by '${owner:-another operator}' — backing off; NOT spawning '$slug' (no worktree, no agent)." >&2
      return 1 ;;
    UNREACHABLE|*)
      echo "⚠️  could not verify a claim on $id (backend '${SCRIBE_BACKEND:-file}' unreachable or has no claim op) — proceeding as unclaimed (solo-operator fail-soft)." >&2
      return 0 ;;
  esac
}

# ── CLAIM RELEASE (HERD-162 F12) ───────────────────────────────────────────────────────────────────

# herd_claim_release_mode — the effective CLAIM_RELEASE mode as exactly one token: off | flag | release.
# Any unrecognized value reads as off, so a typo can never start writing the tracker.
herd_claim_release_mode() {
  case "$(printf '%s' "${CLAIM_RELEASE:-off}" | tr '[:upper:]' '[:lower:]')" in
    release|on|true|yes|1) printf 'release' ;;
    flag|observe|warn)     printf 'flag' ;;
    *)                     printf 'off' ;;
  esac
}

# _herd_release_dispatch <id> <identity> — source the active backend in a SUBSHELL and run its
# _backend_release_item op, with the same namespace/secrets discipline as _herd_claim_dispatch (the
# _backend_* helpers never leak into the caller). Prints "<RESULT>\t<OWNER>" where
#   RELEASED    — our claim marker is gone; the item is re-pickable
#   NOTOURS     — the claim belongs to another identity (or to nobody) → we release NOTHING
#   UNREACHABLE — no backend file, no release op, a sourcing error, or a transport failure
# A backend that defines no release op (jira, changelog) maps to UNREACHABLE so the caller fails soft.
_herd_release_dispatch() {
  local id="$1" who="$2" bdir bfile
  bdir="${SCRIBE_BACKEND_DIR:-$_HERD_CLAIM_DIR/backends}"
  bfile="$bdir/${SCRIBE_BACKEND:-file}.sh"
  if [ ! -f "$bfile" ]; then printf 'UNREACHABLE\t'; return 0; fi
  (
    # API-backend credentials live in .herd/secrets (gitignored); file/changelog need none.
    if [ -n "${PROJECT_ROOT:-}" ] && [ -f "$PROJECT_ROOT/.herd/secrets" ]; then
      # shellcheck source=/dev/null
      . "$PROJECT_ROOT/.herd/secrets"
    fi
    # shellcheck source=/dev/null
    . "$bfile" 2>/dev/null || { printf 'UNREACHABLE\t'; exit 0; }
    command -v _backend_release_item >/dev/null 2>&1 || { printf 'UNREACHABLE\t'; exit 0; }
    [ -n "${PROJECT_ROOT:-}" ] && cd "$PROJECT_ROOT" 2>/dev/null
    # Attribute the release's tracker_write (HERD-85) to the 'claim' component, as the claim itself is.
    export HERD_COMPONENT="claim"
    _RELEASE_RESULT=""; _RELEASE_OWNER=""
    _backend_release_item "$id" "$who" 2>/dev/null || true
    printf '%s\t%s' "${_RELEASE_RESULT:-UNREACHABLE}" "${_RELEASE_OWNER:-}"
  )
}

# herd_claim_release <id> <who> <slug> <reason> — release OUR claim on <id> because <slug>'s builder is
# gone. Echoes exactly one token for the caller to surface: released | flagged | notours | unsupported.
# The CALLER owns the policy question ("is this builder genuinely abandoned?"); this function owns only
# the mechanism. Never non-zero — a release that cannot happen is surfaced, never fatal.
#   CLAIM_RELEASE=off      → 'off' and nothing else happens (this is also enforced by the caller).
#   CLAIM_RELEASE=flag     → journal claim_release_flagged; NO tracker write.
#   CLAIM_RELEASE=release  → dispatch to the backend; a backend with no release op degrades to 'flagged'.
herd_claim_release() {
  local id="${1:-}" who="${2:-}" slug="${3:-?}" reason="${4:-abandoned}" mode parsed result owner
  [ -n "$id" ] || { printf 'off'; return 0; }
  mode="$(herd_claim_release_mode)"
  [ "$mode" = off ] && { printf 'off'; return 0; }
  [ -n "$who" ] || who="$(_herd_claim_identity)"
  [ -n "$who" ] || who="unknown-operator"

  if [ "$mode" = flag ]; then
    journal_append claim_release_flagged ref "$id" slug "$slug" reason "$reason" who "$who"
    printf 'flagged'; return 0
  fi

  parsed="$(_herd_release_dispatch "$id" "$who")"
  result="${parsed%%$'\t'*}"; owner="${parsed#*$'\t'}"
  case "$result" in
    RELEASED)
      journal_append claim_released ref "$id" slug "$slug" reason "$reason" who "$who"
      printf 'released' ;;
    NOTOURS)
      # Someone else holds it (or nobody does) — releasing would steal/no-op. Say so, write nothing.
      journal_append claim_release_skipped ref "$id" slug "$slug" reason not-ours owner "${owner:-none}"
      printf 'notours' ;;
    UNREACHABLE|*)
      # No release op on this backend, or the backend could not be reached. Degrade to the flag mode's
      # contract — the wedge is surfaced and journaled, and a human re-queues it.
      journal_append claim_release_flagged ref "$id" slug "$slug" reason "$reason" who "$who" \
        detail "backend ${SCRIBE_BACKEND:-file} has no release op or was unreachable"
      printf 'unsupported' ;;
  esac
}
