#!/usr/bin/env bash
# ci-repair.sh — CI auto-repair for INHERITED reds (HERD-250).
#
# WHY THIS EXISTS
# --------------
# GROUNDED (PR #353, 2026-07-09): #353 sat UNSTABLE with suite(macos) FAILING while herd/gates
# PASSED — its ~14-commits-behind branch still contained two hermetic reds already fixed on main
# by #354, so ITS CI inherited main's OLD bugs. No healer fired: STALE_BASE_AUTOFIX keys on
# TOUCHED-file overlap only (the PR's diff did not overlap the moved files), and nothing in the
# engine read GitHub Actions CI state as a heal trigger. A branch that is BEHIND main, has a
# FAILING required CI check, and already carries a herd/gates=success blessing is the inherited-red
# case: main almost certainly already has the fix; a base-refresh (merge origin/main) is the
# mechanical remedy. A REAL new-code CI failure (failing CI on an up-to-date branch, or without
# gates) must NEVER be auto-healed — it surfaces needs-you.
#
# WHAT IT DECIDES (the watcher dispatches the heal; this file is the pure predicate)
# ---------------------------------------------------------------------------------
# Eligible for base-refresh IFF ALL of:
#   (1) CI_AUTOREPAIR is on (default OFF — ship-dormant / byte-inert)
#   (2) the PR has a FAILING required CI check (caller already classified; not re-probed here)
#   (3) herd/gates PASSED for the head sha (blessing = our health+review already green)
#   (4) the branch is BEHIND the base tip (merge-base != base tip)
#
# NEVER silently merges a red PR. The only side effect this module enables is a base-refresh
# bounce (or resolver dispatch) the watcher already knows how to do for STALE_BASE_AUTOFIX.
# After the refresh, a still-red PR that is no longer behind falls to needs-you as a real failure.
#
# CONTRACT
# --------
# ci_autorepair_enabled
#   returns 0 iff CI_AUTOREPAIR opts in. Unrecognized value → off.
#
# ci_repair_branch_behind <dir> <base-branch> <head-ref>
#   returns 0 iff head does NOT contain the base tip (strictly behind). Fail-soft: missing
#   dir/refs → not behind (return 1) so we never heal on a probe failure.
#
# ci_repair_gates_passed <sha> [pr#]
#   returns 0 iff the head sha carries herd/gates=success. Test seam HERD_CI_REPAIR_GATES_PASSED
#   (1/true/on → yes; 0/false/off → no) bypasses the network for hermetic tests.
#
# ci_repair_eligible <dir> <base-branch> <head-sha>
#   returns 0 iff a FAILING-CI PR (caller-proven) is eligible for base-refresh. Sets
#   _CI_REPAIR_REASON on success. Fail-soft / off → return 1, empty reason.
#
# Test seams (HERD_-namespaced so the config-manifest ghost-key lint exempts them):
#   HERD_CI_REPAIR_GATES_PASSED   force gates-passed predicate (1|0 / true|false / on|off)
#   HERD_CI_REPAIR_BEHIND         force branch-behind predicate (1|0 / true|false / on|off)
#
# Sourced AFTER herd-config.sh (and ideally after journal.sh), exactly like stale-dup-gate.sh:
#   . "$HERE/ci-repair.sh"

# ci_autorepair_enabled — master lever. Default OFF (ship-dormant). Any unrecognized value → off.
ci_autorepair_enabled() {
  case "$(printf '%s' "${CI_AUTOREPAIR:-off}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# _ci_repair_truthy <val> — print yes|no|unset for a seam value (stdout is the case key; no
# reliance on exit codes inside command substitution).
_ci_repair_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes) printf 'yes' ;;
    0|false|off|no) printf 'no' ;;
    *) printf 'unset' ;;
  esac
}

# ci_repair_branch_behind <dir> <base-branch> <head-ref> — true when head is strictly BEHIND base
# (base tip is not an ancestor of head / merge-base != base tip). Pure git; no network. Fail-soft:
# any probe failure → return 1 (treat as not-behind so we do not heal).
ci_repair_branch_behind() {
  local dir="$1" base="$2" head="$3" mb basetip
  # Test seam: force the behind predicate without a real worktree.
  case "$(_ci_repair_truthy "${HERD_CI_REPAIR_BEHIND:-}")" in
    yes) return 0 ;;
    no)  return 1 ;;
  esac
  [ -d "$dir" ] || return 1
  [ -n "$base" ] && [ -n "$head" ] || return 1
  mb="$(git -C "$dir" merge-base "$base" "$head" 2>/dev/null)" || return 1
  [ -n "$mb" ] || return 1
  basetip="$(git -C "$dir" rev-parse "$base" 2>/dev/null)" || return 1
  [ -n "$basetip" ] || return 1
  # Up to date (or ahead on this line): merge-base equals base tip → NOT behind.
  [ "$basetip" != "$mb" ]
}

# ci_repair_gates_passed <sha> [pr#] — true when herd/gates=success is on the head sha.
# Prefer the watcher's live helper when already sourced; else hit the Statuses API. Fail-soft → false.
ci_repair_gates_passed() {
  local sha="$1" state
  case "$(_ci_repair_truthy "${HERD_CI_REPAIR_GATES_PASSED:-}")" in
    yes) return 0 ;;
    no)  return 1 ;;
  esac
  [ -n "$sha" ] || return 1
  # When agent-watch is sourced, reuse its gate-status probe (same context string + fail-soft).
  if type _gate_status_blessed >/dev/null 2>&1; then
    _gate_status_blessed "$sha"
    return $?
  fi
  state="$(gh api "repos/{owner}/{repo}/commits/$sha/statuses" \
             --jq '[.[] | select(.context=="herd/gates")][0].state' 2>/dev/null || true)"
  [ "$state" = "success" ]
}

# ci_repair_eligible <dir> <base-branch> <head-sha>
# Pure decision for the inherited-red case. Caller has already proven a FAILING required CI check
# (so we never re-fetch the rollup here). Returns 0 → heal; 1 → leave to needs-you.
# Sets _CI_REPAIR_REASON on eligibility (one-line human reason for the journal / prompt).
ci_repair_eligible() {
  local dir="$1" base="$2" head="$3"
  _CI_REPAIR_REASON=""
  ci_autorepair_enabled || return 1
  [ -n "$head" ] || return 1
  # Gates must already be green for this sha — without that blessing we cannot tell "inherited
  # red on main's old bugs" from "our own health/review would also fail".
  ci_repair_gates_passed "$head" || return 1
  # Behind base is the inherited-red signal. An up-to-date branch with red CI is a REAL failure.
  ci_repair_branch_behind "$dir" "$base" "$head" || return 1
  _CI_REPAIR_REASON="CI red + herd/gates green + branch behind ${base:-main} — likely inherited from already-fixed main bugs; base-refresh to pick up the fixes"
  return 0
}
