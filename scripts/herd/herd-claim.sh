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
#   • On a definitive "already claimed by another identity" it prints a LOUD abort and returns NON-ZERO,
#     so the lane exits before creating a worktree or agent.
#   • On our own successful claim, a self-claim (re-spawn of our own item), or a FAIL-SOFT backend error
#     (backend unreachable / no claim op / no such item) it returns 0 and the lane proceeds. Never
#     hard-block a solo operator on a backend hiccup.
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
    _CLAIM_RESULT=""; _CLAIM_OWNER=""
    _backend_claim_item "$id" "$who" 2>/dev/null || true
    printf '%s\t%s' "${_CLAIM_RESULT:-UNREACHABLE}" "${_CLAIM_OWNER:-}"
  )
}

# herd_claim_or_abort <slug> — the lane-facing entry point. See the header contract. Returns 0 to
# PROCEED, non-zero to ABORT the spawn.
herd_claim_or_abort() {
  local slug="${1:-?}" id who parsed result owner
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
