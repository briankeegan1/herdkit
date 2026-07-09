#!/usr/bin/env bash
# merge-policy.sh — THE resolver for the effective merge policy (HERD-159, unified in HERD-210).
#
# One seam, one answer. Every surface that needs to know "will the watcher merge?" — the watcher
# itself (agent-watch.sh), `herd reload`'s summary (bin/herd cmd_reload), and the posture doctor
# (posture-lint.sh) — MUST resolve through _effective_merge_policy here. Inline re-implementations
# drift: cmd_reload carried a copy whose catch-all branch treated an UNRECOGNIZED MERGE_POLICY the
# same as an empty one, so `herd reload` printed "MERGE_POLICY: auto" for a typo the watcher was
# strictly failing to `observe`. An operator reading that summary believes a posture the engine is
# not running — the class of inconsistency that let PR #317 merge past a live BLOCK.
#
# The contract, in precedence order:
#   1. MERGE_POLICY set to a RECOGNIZED value (auto|approve|observe) → that value, verbatim.
#   2. MERGE_POLICY empty/unset → derive from the legacy WATCHER_AUTOMERGE boolean (back-compat).
#   3. MERGE_POLICY set to anything else → a TYPO, not a legacy-derivation trigger. Fail STRICT to
#      `observe` (never merge), so a fat-fingered key can never silently turn an approval-gated repo
#      into auto-merge. Values are case-SENSITIVE: MERGE_POLICY=AUTO is a typo, not `auto`.
#
# Pure helpers, no side effects: sourcing this file only defines functions, so any caller can source
# it at any point (before or after herd-config.sh) and lib-mode consumers never write a journal line.
# Surfacing a bad value to the human is the CALLER's job — agent-watch.sh journals merge_policy_invalid
# once at launch, `herd doctor --posture` lints it. This file only resolves. Bash 3.2 clean.

# _legacy_automerge_policy — the pre-MERGE_POLICY derivation from the legacy WATCHER_AUTOMERGE
# boolean: false/no/off/0 → approve, anything else (including unset) → auto. Also used directly by
# posture-lint.sh to report what the legacy lever *would* imply when it contradicts MERGE_POLICY.
_legacy_automerge_policy() {
  case "${WATCHER_AUTOMERGE:-true}" in
    false|no|off|0) printf 'approve' ;;
    *)              printf 'auto' ;;
  esac
}

# _effective_merge_policy — echo "auto" | "approve" | "observe" per the contract above.
_effective_merge_policy() {
  case "${MERGE_POLICY:-}" in
    auto|approve|observe) printf '%s' "$MERGE_POLICY" ;;
    '')                   _legacy_automerge_policy ;;
    *)                    printf 'observe' ;;
  esac
}

# _merge_policy_is_typo — return 0 iff MERGE_POLICY is set to a non-empty UNRECOGNIZED value, i.e. the
# rule-3 strict fallback is in force. Callers use this to SURFACE the bad value (agent-watch.sh's
# launch-time journal + red console line); it keeps the recognized-value set defined exactly once.
_merge_policy_is_typo() {
  case "${MERGE_POLICY:-}" in
    ''|auto|approve|observe) return 1 ;;
    *)                       return 0 ;;
  esac
}
