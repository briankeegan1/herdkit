#!/usr/bin/env bash
# resolver-claim.sh — HERD-423: cross-seat resolver-dispatch claim (Phase 1 of
# docs/spikes/cross-seat-coordination.md §5). Closes the proven gap (audit G5 / N8): two seats with
# separate local $TREES and one shared GitHub remote could each independently `spawn_resolver` the
# SAME conflicting (PR, head sha), racing pushes. This file adds a repo-visible v1 claim so at most
# one seat dispatches per (pr, sha) — layered ON TOP of the existing same-seat `_resolver_in_flight`
# guard (agent-watch.sh), never replacing it.
#
# SHIP-DORMANT / BYTE-IDENTICAL-WHEN-OFF: every public function here is a no-op (no gh call, no
# journal line, no file write) unless BOTH:
#   1. RESOLVE_CLAIM is a recognized on-value (on|true|yes|1), AND
#   2. WATCHER_SCOPE=all (team mode) — reusing the existing lever per the spike's §7 recommendation.
# WATCHER_SCOPE=mine (the default) or RESOLVE_CLAIM off/unset ⇒ _effective_resolve_claim reads "off"
# and every caller below returns immediately with zero side effects — solo behavior is untouched.
#
# SUBSTRATE: a single HTML-hidden marker PR comment (never a Statuses/Check-Run write — a non-success
# Statuses write can strand a PR's mergeability, per agent-watch.sh's HERD-247 note). One comment is
# upserted in place (found by marker, edited via `gh api … -X PATCH`), never appended-to-forever:
#
#   <!-- herd:resolve-claim v1
#   pr: <n>
#   sha: <headsha, or - if unknown>
#   seat: <claiming seat's login>
#   slug: <claiming seat's worktree slug>
#   epoch: <unix seconds the claim was published>
#   state: claimed | done | escalated
#   -->
#
# FAIL-SOFT (outage doctrine): any `gh` read/write failure is treated as "no claim" — never a
# fabricated foreign claim, never a held gate, never a crash. A caller always falls back to its
# existing local-only (same-seat) behavior. Bash 3.2 clean; pure helpers, no top-level side effects.

_RESOLVE_CLAIM_MARKER='<!-- herd:resolve-claim v1'

# _effective_resolve_claim — echo "on" | "off". See file header for the exact two-part gate.
_effective_resolve_claim() {
  case "${RESOLVE_CLAIM:-off}" in
    on|true|yes|1) ;;
    *) printf 'off'; return 0 ;;
  esac
  case "${WATCHER_SCOPE:-mine}" in
    all) printf 'on' ;;
    *) printf 'off' ;;
  esac
}

# _resolve_claim_ttl — seconds a `claimed` state stays foreign-binding before a stuck/dead seat's
# claim is stealable. RESOLVE_CLAIM_TTL overrides; any non-numeric value falls back to the safe
# default (45 min — comfortably above resolver grace + a typical resolve round).
_resolve_claim_ttl() {
  case "${RESOLVE_CLAIM_TTL:-}" in
    ''|*[!0-9]*) printf '2700' ;;
    *) printf '%s' "$RESOLVE_CLAIM_TTL" ;;
  esac
}

# _resolve_claim_seat — this seat's identity for the claim. Reuses agent-watch.sh's memoized
# operator-identity resolver when sourced alongside it; falls back to WATCHER_OWNER/WATCHER_VIEW_AUTHOR
# directly so this file is independently testable (unit tests source it alone).
_resolve_claim_seat() {
  if command -v _watcher_owner_login >/dev/null 2>&1; then
    _watcher_owner_login
    return 0
  fi
  printf '%s' "${WATCHER_OWNER:-${WATCHER_VIEW_AUTHOR:-}}"
}

# _resolve_claim_gh <site> <gh-args...> — every `gh` call in this file goes through here. Uses
# agent-watch.sh's timeout-wrapped `_gh_timeout` when sourced alongside it (the normal case); falls
# back to plain `gh` so this file is independently sourceable/testable on its own.
_resolve_claim_gh() {
  if command -v _gh_timeout >/dev/null 2>&1; then
    _gh_timeout "$@"
  else
    local _rcg_site="$1"; shift
    gh "$@"
  fi
}

# _resolve_claim_render <pr> <sha> <seat> <slug> <epoch> <state> — the exact marker body (see header).
_resolve_claim_render() {
  printf '%s\npr: %s\nsha: %s\nseat: %s\nslug: %s\nepoch: %s\nstate: %s\n-->' \
    "$_RESOLVE_CLAIM_MARKER" "$1" "$2" "$3" "$4" "$5" "$6"
}

# _resolve_claim_parse — read a claim comment BODY on stdin; print RC_PR=/RC_SHA=/RC_SEAT=/RC_SLUG=/
# RC_EPOCH=/RC_STATE= lines for the fields found inside the marker block. Pure text scan (no eval) —
# a body that isn't a claim comment, or has no marker, prints nothing.
_resolve_claim_parse() {
  awk -v marker="$_RESOLVE_CLAIM_MARKER" '
    index($0, marker) == 1 { inblock=1; next }
    inblock && $0 ~ /^-->[[:space:]]*$/ { inblock=0; exit }
    inblock {
      line = $0
      sub(/^[ \t]+/, "", line)
      n = index(line, ": ")
      if (n > 0) {
        k = substr(line, 1, n - 1); v = substr(line, n + 2)
        if (k == "pr")    print "RC_PR="v
        if (k == "sha")   print "RC_SHA="v
        if (k == "seat")  print "RC_SEAT="v
        if (k == "slug")  print "RC_SLUG="v
        if (k == "epoch") print "RC_EPOCH="v
        if (k == "state") print "RC_STATE="v
      }
    }
  '
}

# _resolve_claim_fields_valid — validate the RC_* fields already set in the CALLER's shell (loaded
# via _resolve_claim_load below). Rejects a malformed/untrusted comment (garbage injected by a
# non-watcher commenter, a truncated edit, a future/incompatible marker version) rather than acting on
# it. Never a crash, never a hold from garbage — an invalid claim reads as "no claim".
_resolve_claim_fields_valid() {
  case "$RC_PR" in ''|*[!0-9]*) return 1 ;; esac
  case "$RC_SHA" in ''|-) ;; *[!0-9a-fA-F]*) return 1 ;; esac
  case "$RC_SEAT" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  case "$RC_SLUG" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  case "$RC_EPOCH" in ''|*[!0-9]*) return 1 ;; esac
  case "$RC_STATE" in claimed|done|escalated) ;; *) return 1 ;; esac
  return 0
}

# _resolve_claim_load <pr> — find the CURRENT claim comment for <pr> (there is at most one, upserted
# in place) and load RC_ID / RC_PR / RC_SHA / RC_SEAT / RC_SLUG / RC_EPOCH / RC_STATE into the CALLER'S
# shell (called directly, never in a subshell, exactly like agent-watch.sh's other memoized readers).
# Returns 0 with valid fields loaded, 1 on no claim / outage / malformed comment (all fail-soft alike
# — callers never distinguish "no claim" from "unreadable claim", both mean "proceed as solo").
RC_ID=""; RC_PR=""; RC_SHA=""; RC_SEAT=""; RC_SLUG=""; RC_EPOCH=""; RC_STATE=""
_resolve_claim_load() {
  local _rcl_pr="$1" _rcl_line _rcl_body _rcl_jq _rcl_k _rcl_v
  RC_ID=""; RC_PR=""; RC_SHA=""; RC_SEAT=""; RC_SLUG=""; RC_EPOCH=""; RC_STATE=""
  # jq prints "<id>\n<body>" -- id on the first line, body the rest. An id is plain digits (never
  # contains a newline), so a plain bash prefix-strip cleanly separates them without an exotic
  # delimiter byte or a `read` call (`read` always stops at the first newline regardless of IFS,
  # which does not fit a multi-line body).
  _rcl_jq='([.[] | select(.body != null and (.body|startswith("<!-- herd:resolve-claim v1")))] | last // {}) | "\(.id // "")\n\(.body // "")"'
  _rcl_line="$(_resolve_claim_gh resolve_claim_read api "repos/{owner}/{repo}/issues/$_rcl_pr/comments" --paginate --jq "$_rcl_jq" 2>/dev/null || true)"
  [ -n "$_rcl_line" ] || return 1
  RC_ID="${_rcl_line%%$'\n'*}"
  _rcl_body="${_rcl_line#*$'\n'}"
  [ -n "$RC_ID" ] || return 1
  # NEVER eval the parsed fields — the comment body is UNTRUSTED (anyone with comment access on the
  # repo could forge a marker). Assign each recognized key literally via `read`, so an injected
  # `$(...)` or backtick sequence in a value is stored as inert text, never interpreted as shell.
  while IFS='=' read -r _rcl_k _rcl_v; do
    case "$_rcl_k" in
      RC_PR)    RC_PR="$_rcl_v" ;;
      RC_SHA)   RC_SHA="$_rcl_v" ;;
      RC_SEAT)  RC_SEAT="$_rcl_v" ;;
      RC_SLUG)  RC_SLUG="$_rcl_v" ;;
      RC_EPOCH) RC_EPOCH="$_rcl_v" ;;
      RC_STATE) RC_STATE="$_rcl_v" ;;
    esac
  done <<EOF_RCF
$(printf '%s\n' "$_rcl_body" | _resolve_claim_parse)
EOF_RCF
  _resolve_claim_fields_valid || { RC_ID=""; RC_PR=""; RC_SHA=""; RC_SEAT=""; RC_SLUG=""; RC_EPOCH=""; RC_STATE=""; return 1; }
  return 0
}

# _resolve_claim_publish <pr> <sha> <seat> <slug> <state> — upsert the marker comment: PATCH the
# existing one (found via _resolve_claim_load) or POST a fresh one if none exists yet. Fail-soft:
# a gh failure journals resolve_claim_publish_failed and returns 0 — publishing is best-effort, it
# must never block the caller's own dispatch/local-progress path.
_resolve_claim_publish() {
  local _rcp_pr="$1" _rcp_sha="$2" _rcp_seat="$3" _rcp_slug="$4" _rcp_state="$5" _rcp_epoch _rcp_body _rcp_id=""
  _rcp_epoch="$(date +%s)"
  _rcp_body="$(_resolve_claim_render "$_rcp_pr" "$_rcp_sha" "$_rcp_seat" "$_rcp_slug" "$_rcp_epoch" "$_rcp_state")"
  if _resolve_claim_load "$_rcp_pr"; then _rcp_id="$RC_ID"; fi
  if [ -n "$_rcp_id" ]; then
    if _resolve_claim_gh resolve_claim_publish api "repos/{owner}/{repo}/issues/comments/$_rcp_id" -X PATCH -f body="$_rcp_body" >/dev/null 2>&1; then
      command -v journal_append >/dev/null 2>&1 && journal_append resolve_claim_published pr "$_rcp_pr" sha "${_rcp_sha:--}" state "$_rcp_state" mode edit
      return 0
    fi
  else
    if _resolve_claim_gh resolve_claim_publish api "repos/{owner}/{repo}/issues/$_rcp_pr/comments" -f body="$_rcp_body" >/dev/null 2>&1; then
      command -v journal_append >/dev/null 2>&1 && journal_append resolve_claim_published pr "$_rcp_pr" sha "${_rcp_sha:--}" state "$_rcp_state" mode create
      return 0
    fi
  fi
  command -v journal_append >/dev/null 2>&1 && journal_append resolve_claim_publish_failed pr "$_rcp_pr" sha "${_rcp_sha:--}" state "$_rcp_state"
  return 0
}

# _resolve_claim_should_hold <pr> <sha> <slug> — the decision point, called from spawn_resolver
# BEFORE record_resolve_attempt/the actual spawn (spike §5.2). Prints nothing; rc:
#   0 = HOLD — a live foreign claim owns this exact (pr,sha); do NOT spawn, do NOT burn local budget.
#   1 = proceed — no claim, own claim, a claim for a DIFFERENT (stale) sha, or a TTL-expired steal.
# Off (lever/scope) ⇒ always 1, no gh call at all — byte-identical to pre-HERD-423.
_resolve_claim_should_hold() {
  local _rch_pr="$1" _rch_sha="${2:--}" _rch_slug="$3" _rch_me _rch_age _rch_ttl
  [ "$(_effective_resolve_claim)" = "on" ] || return 1
  _rch_me="$(_resolve_claim_seat)"
  _resolve_claim_load "$_rch_pr" || return 1
  [ "$RC_SHA" = "$_rch_sha" ] || return 1               # claim is for a different/older sha — stale
  [ -n "$_rch_me" ] && [ "$RC_SEAT" = "$_rch_me" ] && return 1   # our own prior claim — local ledger governs
  case "$RC_STATE" in
    done|escalated)
      return 0 ;;                                       # foreign terminal verdict for THIS sha — never redo it
    claimed)
      _rch_ttl="$(_resolve_claim_ttl)"
      _rch_age=$(( $(date +%s) - RC_EPOCH ))
      [ "$_rch_age" -lt 0 ] && _rch_age=0
      if [ "$_rch_age" -lt "$_rch_ttl" ]; then
        return 0                                        # live foreign claim, inside TTL — hold
      fi
      command -v journal_append >/dev/null 2>&1 && journal_append resolve_claim_steal pr "$_rch_pr" sha "${_rch_sha:--}" \
        foreign_seat "$RC_SEAT" age "$_rch_age" ttl "$_rch_ttl"
      return 1                                          # TTL expired — bounded steal, proceed
      ;;
  esac
  return 1
}

# _resolve_claim_publish_claimed <pr> <sha> <slug> — publish/renew OUR "claimed" state for (pr,sha)
# BEFORE the local record+spawn (spike §5.2 step 4: "record-shared-first, then record-local, then
# spawn"). No-op when the lever/scope is off.
_resolve_claim_publish_claimed() {
  [ "$(_effective_resolve_claim)" = "on" ] || return 0
  local _rcpc_pr="$1" _rcpc_sha="${2:--}" _rcpc_slug="$3" _rcpc_me
  _rcpc_me="$(_resolve_claim_seat)"
  [ -n "$_rcpc_me" ] || return 0                        # unresolvable identity — never claim under "" (fail-soft)
  _resolve_claim_publish "$_rcpc_pr" "$_rcpc_sha" "$_rcpc_me" "$_rcpc_slug" claimed
}

# _resolve_claim_publish_terminal <pr> <sha> <slug> <done|escalated> — best-effort terminal update at
# the result/escalation seam (_classify_conflict), so a foreign seat sees the finished/escalated
# state instead of an aging "claimed" row. No-op when the lever/scope is off.
_resolve_claim_publish_terminal() {
  [ "$(_effective_resolve_claim)" = "on" ] || return 0
  local _rcpt_pr="$1" _rcpt_sha="${2:--}" _rcpt_slug="$3" _rcpt_state="$4" _rcpt_me
  case "$_rcpt_state" in done|escalated) ;; *) return 0 ;; esac
  _rcpt_me="$(_resolve_claim_seat)"
  [ -n "$_rcpt_me" ] || return 0
  _resolve_claim_publish "$_rcpt_pr" "$_rcpt_sha" "$_rcpt_me" "$_rcpt_slug" "$_rcpt_state"
}
