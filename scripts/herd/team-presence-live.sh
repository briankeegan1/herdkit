#!/usr/bin/env bash
# team-presence-live.sh — HERD-661 (GitHub issue #639 phase 2): the LIVE half of teammate builder
# visibility. TEAM_PRESENCE=on (HERD-527, phase 1) already joins an ungated PR to its tracker item and
# says WHO claimed it; it has no notion of whether that claim is a live, actively-running build or an
# hours-stale assignment. TEAM_PRESENCE=live adds exactly that, reusing resolver-claim.sh's proven
# substrate (a single HTML-hidden marker PR comment, upserted in place, versioned v1, epoch-stamped —
# never a Statuses/Check-Run write) rather than inventing a new channel.
#
# PUBLISH. Once per throttled scan tick (never the 4s repaint — see agent-watch.sh's
# _team_presence_live_publish_tick, which iterates the tick's already-discovered FEATS table), a
# watcher upserts ONE marker comment per PR it itself authored and is actively building:
#
#   <!-- herd:team-presence-live v1
#   pr: <n>
#   slug: <worktree slug>
#   seat: <publishing seat's login>
#   status: <agent_status, e.g. working|idle — may be empty if unresolved>
#   epoch: <unix seconds this row was published>
#   -->
#
# A PR this seat did not author (an ADOPTED PR it merely gates on someone else's behalf) is never
# published to — publishing there would misrepresent who is actually building it. A worktree with no
# resolved PR publishes nothing ("no PR = nothing published" — the tracker claim already covers
# pre-PR intent, exactly like phase 1's join).
#
# CONSUME. _team_presence_live_status_for <pr> is the pure read side: it loads the marker (if any) and
# prints "<status>\t<epoch>" — nothing on absence, outage, or a malformed/forged comment. Callers age
# the epoch themselves (agent-watch.sh's _fmt_age) to render "active Nm ago" vs "last active Nh ago
# (stale?)".
#
# SEAT-SYMMETRIC (multi-seat doctrine): every seat runs the identical publish leg for its OWN PRs and
# the identical consume leg for EVERY teammate's — there is no seat-specific special-casing.
#
# FAIL-SOFT (outage doctrine, mirrors resolver-claim.sh): any `gh` read/write failure is "no live data"
# — never a fabricated status, never a crash, never a held row. A caller always falls back to
# TEAM_PRESENCE=on's plain attribution. Parsing NEVER evals the untrusted comment body. Bash 3.2 clean;
# pure helpers, no top-level side effects.

_TPL_MARKER='<!-- herd:team-presence-live v1'

# _team_presence_live_seat — this seat's identity for the publish. Reuses agent-watch.sh's memoized
# operator-identity resolver when sourced alongside it (the normal case); falls back to
# WATCHER_OWNER/WATCHER_VIEW_AUTHOR so this file stays independently sourceable/testable on its own.
_team_presence_live_seat() {
  if command -v _watcher_owner_login >/dev/null 2>&1; then
    _watcher_owner_login
    return 0
  fi
  printf '%s' "${WATCHER_OWNER:-${WATCHER_VIEW_AUTHOR:-}}"
}

# _team_presence_live_gh <site> <gh-args...> — every `gh` call in this file goes through here. Uses
# agent-watch.sh's timeout-wrapped `_gh_timeout` when sourced alongside it; falls back to plain `gh`
# so this file is independently sourceable/testable on its own.
_team_presence_live_gh() {
  if command -v _gh_timeout >/dev/null 2>&1; then
    _gh_timeout "$@"
  else
    local _tlg_site="$1"; shift
    gh "$@"
  fi
}

# _team_presence_live_render <pr> <slug> <seat> <status> <epoch> — the exact marker body (see header).
_team_presence_live_render() {
  printf '%s\npr: %s\nslug: %s\nseat: %s\nstatus: %s\nepoch: %s\n-->' \
    "$_TPL_MARKER" "$1" "$2" "$3" "$4" "$5"
}

# _team_presence_live_parse — read a marker comment BODY on stdin; print TPL_PR=/TPL_SLUG=/TPL_SEAT=/
# TPL_STATUS=/TPL_EPOCH= lines for the fields found inside the block. Pure text scan (no eval) — a
# body that isn't one of ours, or has no marker, prints nothing.
_team_presence_live_parse() {
  awk -v marker="$_TPL_MARKER" '
    index($0, marker) == 1 { inblock=1; next }
    inblock && $0 ~ /^-->[[:space:]]*$/ { inblock=0; exit }
    inblock {
      line = $0
      sub(/^[ \t]+/, "", line)
      n = index(line, ": ")
      if (n > 0) {
        k = substr(line, 1, n - 1); v = substr(line, n + 2)
        if (k == "pr")     print "TPL_PR="v
        if (k == "slug")   print "TPL_SLUG="v
        if (k == "seat")   print "TPL_SEAT="v
        if (k == "status") print "TPL_STATUS="v
        if (k == "epoch")  print "TPL_EPOCH="v
      }
    }
  '
}

# _team_presence_live_fields_valid — validate the TPL_* fields already set in the CALLER's shell
# (loaded via _team_presence_live_load below). Rejects a malformed/untrusted comment (garbage injected
# by a non-watcher commenter, a truncated edit, a future/incompatible marker version) rather than
# acting on it — an invalid marker reads as "no live data", never a crash or a fabricated status.
_team_presence_live_fields_valid() {
  case "$TPL_PR" in ''|*[!0-9]*) return 1 ;; esac
  case "$TPL_SLUG" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  case "$TPL_SEAT" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  case "$TPL_STATUS" in *[!A-Za-z0-9_.-]*) return 1 ;; esac
  case "$TPL_EPOCH" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

# _team_presence_live_load <pr> — find the CURRENT marker comment for <pr> (there is at most one,
# upserted in place) and load TPL_ID/TPL_PR/TPL_SLUG/TPL_SEAT/TPL_STATUS/TPL_EPOCH into the CALLER'S
# shell (called directly, never in a subshell — mirrors resolver-claim.sh's _resolve_claim_load).
# Returns 0 with valid fields loaded, 1 on no marker / outage / malformed comment (all fail-soft alike
# — callers never distinguish "no live row" from "unreadable live row").
TPL_ID=""; TPL_PR=""; TPL_SLUG=""; TPL_SEAT=""; TPL_STATUS=""; TPL_EPOCH=""
_team_presence_live_load() {
  local _tll_pr="$1" _tll_json _tll_line _tll_body _tll_jq _tll_k _tll_v
  TPL_ID=""; TPL_PR=""; TPL_SLUG=""; TPL_SEAT=""; TPL_STATUS=""; TPL_EPOCH=""
  # Same --paginate-without--jq discipline as resolver-claim.sh's _resolve_claim_load: fetching the
  # raw pages and letting a single local `jq` pass see the aggregated array avoids the per-page
  # --jq concatenation trap (a marker not on the LAST fetched page would otherwise corrupt the split).
  _tll_json="$(_team_presence_live_gh team_presence_live_read api "repos/{owner}/{repo}/issues/$_tll_pr/comments" --paginate 2>/dev/null || true)"
  [ -n "$_tll_json" ] || return 1
  _tll_jq='([.[] | select(.body != null and (.body|startswith("<!-- herd:team-presence-live v1")))] | last // {}) | "\(.id // "")\n\(.body // "")"'
  _tll_line="$(printf '%s' "$_tll_json" | jq -r "$_tll_jq" 2>/dev/null || true)"
  [ -n "$_tll_line" ] || return 1
  TPL_ID="${_tll_line%%$'\n'*}"
  _tll_body="${_tll_line#*$'\n'}"
  [ -n "$TPL_ID" ] || return 1
  # NEVER eval the parsed fields — the comment body is UNTRUSTED. Assign each recognized key
  # literally via `read`, so an injected `$(...)`/backtick sequence lands as inert text.
  while IFS='=' read -r _tll_k _tll_v; do
    case "$_tll_k" in
      TPL_PR)     TPL_PR="$_tll_v" ;;
      TPL_SLUG)   TPL_SLUG="$_tll_v" ;;
      TPL_SEAT)   TPL_SEAT="$_tll_v" ;;
      TPL_STATUS) TPL_STATUS="$_tll_v" ;;
      TPL_EPOCH)  TPL_EPOCH="$_tll_v" ;;
    esac
  done <<EOF_TLF
$(printf '%s\n' "$_tll_body" | _team_presence_live_parse)
EOF_TLF
  _team_presence_live_fields_valid || { TPL_ID=""; TPL_PR=""; TPL_SLUG=""; TPL_SEAT=""; TPL_STATUS=""; TPL_EPOCH=""; return 1; }
  return 0
}

# _team_presence_live_publish <pr> <slug> <seat> <status> — upsert THIS seat's marker comment on <pr>:
# PATCH the existing one (found via _team_presence_live_load) or POST a fresh one if none exists yet.
# Fail-soft: a gh failure journals team_presence_live_publish_failed and returns 0 — publishing is
# best-effort, it must never block the caller's own tick.
_team_presence_live_publish() {
  local _tlp_pr="$1" _tlp_slug="$2" _tlp_seat="$3" _tlp_status="$4" _tlp_epoch _tlp_body _tlp_id=""
  if command -v _console_now_epoch >/dev/null 2>&1; then
    _tlp_epoch="$(_console_now_epoch)"
  else
    _tlp_epoch="$(date +%s)"
  fi
  _tlp_body="$(_team_presence_live_render "$_tlp_pr" "$_tlp_slug" "$_tlp_seat" "$_tlp_status" "$_tlp_epoch")"
  if _team_presence_live_load "$_tlp_pr"; then _tlp_id="$TPL_ID"; fi
  if [ -n "$_tlp_id" ]; then
    if _team_presence_live_gh team_presence_live_publish api "repos/{owner}/{repo}/issues/comments/$_tlp_id" -X PATCH -f body="$_tlp_body" >/dev/null 2>&1; then
      command -v journal_append >/dev/null 2>&1 && journal_append team_presence_live_published pr "$_tlp_pr" slug "$_tlp_slug" mode edit
      return 0
    fi
  else
    if _team_presence_live_gh team_presence_live_publish api "repos/{owner}/{repo}/issues/$_tlp_pr/comments" -f body="$_tlp_body" >/dev/null 2>&1; then
      command -v journal_append >/dev/null 2>&1 && journal_append team_presence_live_published pr "$_tlp_pr" slug "$_tlp_slug" mode create
      return 0
    fi
  fi
  command -v journal_append >/dev/null 2>&1 && journal_append team_presence_live_publish_failed pr "$_tlp_pr" slug "$_tlp_slug"
  return 0
}

# _team_presence_live_status_for <pr> — the CONSUME primitive: "<status>\t<epoch>" for a live marker
# published by ANY seat on <pr> (never restricted to "seats other than me" — a solo seat simply never
# sees its OWN PRs in the ungated section to begin with, so this is naturally seat-symmetric), or
# nothing on no-marker / outage / malformed comment. Pure read; the caller decides freshness.
_team_presence_live_status_for() {
  local _tls_pr="${1:-}"
  [ -n "$_tls_pr" ] || return 0
  _team_presence_live_load "$_tls_pr" || return 0
  printf '%s\t%s' "$TPL_STATUS" "$TPL_EPOCH"
}
