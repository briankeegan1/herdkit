#!/usr/bin/env bash
# resolver-pane.sh — THE shared resolver for the RESOLVER_PANE lever (HERD-286).
#
# One seam, one answer. Every surface that needs to know "is the resolver-pane feature active?" —
# the watcher (agent-watch.sh) and the spawn lane — MUST resolve through _effective_resolver_pane
# here. Inline re-implementations drift: the merge-policy.sh incident showed that a second copy
# with a different catch-all silently disagrees about which state the engine is in.
#
# The contract, in precedence order:
#   1. RESOLVER_PANE set to a RECOGNIZED on-value (on|true|yes|1) → "on".
#   2. RESOLVER_PANE empty/unset → "off" (ship-dormant default; byte-identical to pre-HERD-286).
#   3. RESOLVER_PANE set to anything else → "off" — fail-soft: a typo can never arm a path
#      that CLOSES panes (unlike merge-policy's strict-to-observe, closing a wrong pane is
#      worse than silently ignoring the lever, so we always default to the safe no-op).
#
# Pure helpers, no side effects: sourcing this file only defines functions, so any caller can
# source it at any point (before or after herd-config.sh) and lib-mode consumers never write
# a journal line. Bash 3.2 clean.

# _effective_resolver_pane — echo "on" | "off" per the contract above.
_effective_resolver_pane() {
  case "${RESOLVER_PANE:-off}" in on|true|yes|1) printf 'on' ;; *) printf 'off' ;; esac
}

# _resolver_pane_is_typo — return 0 iff RESOLVER_PANE is set to a non-empty UNRECOGNIZED value
# (neither an on-value nor the explicit "off" family). Callers use this to SURFACE the bad value
# (an advisory console line at launch); the recognized-value set is defined exactly once here.
# A typo reads OFF — it never arms a pane-closing path — so this is informational, not strict.
_resolver_pane_is_typo() {
  case "${RESOLVER_PANE:-}" in ''|on|true|yes|1|off|false|no|0) return 1 ;; *) return 0 ;; esac
}
