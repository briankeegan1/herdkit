#!/usr/bin/env bash
# aging-pr.sh — THE shared AGING-PR TTL helper (HERD-334): ONE implementation of "how long may an
# engine-approved-but-unmerged PR sit before the watcher calls it AGING". The grounded gap (2026-07-11:
# PRs #440/#441 sat 7h with herd/gates PASSED but a required CI suite red, zero alarms) is that the
# console treats "engine approved it, branch protection blocks it, nothing is progressing" as a quiet
# steady state — no TTL covers it. Two surfaces read that TTL: the watcher render pass (agent-watch.sh,
# an OBSERVED-state advisory row) and the journal auditor (journal-audit.sh, a gates_passed-no-merge
# finding). They MUST agree on the threshold, so both source this file and read AGING_PR_TTL through the
# ONE getter here — never a second hard-coded copy that can drift.
#
# CONFIG: AGING_PR_TTL — seconds an engine-approved PR may stay blocked on a required check before it
# ages (default 3600 = 60m). 0 DISABLES the alarm entirely (mirrors DEP_STALE_TTL=0), so the render row
# and the audit finding both go byte-inert. A non-numeric value reads as the default — a typo can never
# widen or silence the alarm. Sourced (never executed); defining functions only, it has no side effects.

# _aging_pr_ttl_secs — the effective TTL in whole seconds (AGING_PR_TTL, default 3600; non-numeric →
# default; 0 passes through as 0 = disabled). Read LIVE on every call so a mid-process override (a test,
# `export AGING_PR_TTL=N`) is honored, exactly like journal-audit.sh's _num_or tunables.
_aging_pr_ttl_secs() {
  case "${AGING_PR_TTL:-}" in
    ''|*[!0-9]*) printf '3600' ;;
    *)           printf '%s' "$AGING_PR_TTL" ;;
  esac
}

# _aging_pr_armed — true iff the alarm is enabled (TTL > 0). AGING_PR_TTL=0 → false → both surfaces are
# byte-inert. The single arm check both the render pass and the auditor gate on.
_aging_pr_armed() {
  [ "$(_aging_pr_ttl_secs)" -gt 0 ] 2>/dev/null
}

# _aging_pr_over_ttl <since_epoch> <now_epoch> — the shared OVER-TTL predicate. Echoes the age in whole
# seconds (clamped ≥ 0) and returns 0 iff that age ≥ the effective TTL; returns 1 (and echoes nothing)
# when either argument is non-numeric, when the clock went backwards, or when the age is still under the
# TTL. This is the ONE comparison the render pass runs so it can never disagree with the auditor's
# threshold. Deterministic under test: the caller passes now (agent-watch.sh threads _now_epoch, which
# honors HERD_FAKE_NOW).
_aging_pr_over_ttl() {
  local _since="${1:-}" _now="${2:-}" _ttl _age
  case "$_since" in ''|*[!0-9]*) return 1 ;; esac
  case "$_now"   in ''|*[!0-9]*) return 1 ;; esac
  [ "$_now" -ge "$_since" ] 2>/dev/null || return 1
  _ttl="$(_aging_pr_ttl_secs)"
  [ "$_ttl" -gt 0 ] 2>/dev/null || return 1
  _age=$(( _now - _since ))
  printf '%s' "$_age"
  [ "$_age" -ge "$_ttl" ]
}
