#!/usr/bin/env bash
# red-ledger.sh — THE shared RED-ROW LEDGER + RECHECK-CADENCE helper (HERD-539).
#
# Every console red today explains itself differently (or not at all) and clears itself differently
# (or never automatically): MAIN RED renders its failing identity inline but carries no last-verified
# timestamp; the 'unlinked merges' alarm (HERD-522) never re-checks itself and never clears once
# written. This is the ONE shared primitive both — and any future red class — can use: a durable,
# keyed ledger of "why a red is red" (the SAME text the caller journals at diagnosis time, so a row's
# 'why' IS the diagnosing excerpt, never a second guess) plus a last-verified clock any reconcile can
# test against a recheck cadence, mirroring the MAIN_HEALTH_RECHECK_MINS pattern (HERD-222,
# docs/multi-seat-doctrine.md Rule 1) generalized past main-health alone.
#
# Storage: one TAB-separated line per dedup KEY in a ledger file the caller names (agent-watch.sh's is
# $TREES/.agent-watch-red-ledger, shared across every red class — the <class> field tells rows apart,
# not the file):
#     <key>\t<class>\t<first-seen-epoch>\t<last-verified-epoch>\t<why>
# A repeat note() on the same key keeps first-seen and refreshes why + last-verified. The ledger is
# KEYED (unlike an append-only console section), so a note/clear REWRITES the file (tmp + mv, the same
# atomic-replace console-section.sh's trim uses) instead of only ever appending.
#
# ONE implementation, SOURCED (never executed), so a red's rendered 'why' and last-verified timestamp
# can never drift from what was actually diagnosed/reverified:
#     • scripts/herd/agent-watch.sh        — notes + renders (main-health, ref-unparsed)
#     • scripts/herd/work-units/git-pr.sh  — notes at first-alarm time (ref-unparsed)
#
# SHIP-DORMANT: RED_LEDGER=off (default) makes every function below a pure no-op — no file write, no
# journal line, empty reads — so a red row's rendered text stays BYTE-IDENTICAL to before this file
# existed. Fail-soft throughout: an unwritable ledger, a malformed row, a missing journal.sh — every
# one degrades to "show the row without the extra context", never a hard error.

_RED_LEDGER_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# console-section.sh supplies _console_now_epoch (the HERD_FAKE_NOW test seam) and CONSOLE_LEDGER_MAX,
# reused here rather than duplicated. Sourcing it twice (agent-watch.sh already does, earlier) is a
# no-op — precedent: pr-ref.sh, work-unit.sh.
if ! command -v _console_now_epoch >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$_RED_LEDGER_HERE/console-section.sh"
fi

# _red_ledger_enabled — true iff RED_LEDGER opts in. Default OFF; any unrecognized value reads as off
# (fail toward dormant — mirrors _main_health_enabled).
_red_ledger_enabled() {
  case "$(printf '%s' "${RED_LEDGER:-off}" | tr '[:upper:]' '[:lower:]')" in
    on|true|1) return 0 ;;
    *) return 1 ;;
  esac
}

# _red_ledger_sanitize <text> — collapse tabs/newlines/CRs to spaces so a why string can never split a
# TAB-separated row or grow the ledger an extra line.
_red_ledger_sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   '
}

# herd_red_ledger_engine_shaped <why> — HERD-547: the routing rule templates/coordinator.md.tmpl
# documents at "Routing: APP bug vs HERD-ENGINE bug" made mechanical — true iff <why> (a red's
# diagnosing text, the SAME string herd_red_ledger_note caches) names a path under herdkit's OWN
# engine surface (bin/herd, herd.sh, install.sh, scripts/herd/**, scripts/ci/**, migrations/**,
# pysrc/herd/**): the SAME engine-surface set git-scope-lint.sh already treats as "this is the
# workflow machinery, not a consuming project's code" (HERD-435). False for everything else,
# including an empty/missing why — a red this function cannot place is a PROJECT-shaped red by
# default, never escalated. Pure string match — no git, no I/O, no RED_LEDGER/RED_AUTOESCALATE gate
# of its own — so it is provable in isolation; a caller decides what to do with the classification.
herd_red_ledger_engine_shaped() {
  case "${1:-}" in
    *bin/herd*|*herd.sh*|*install.sh*|*scripts/herd/*|*scripts/ci/*|*migrations/*|*pysrc/herd/*) return 0 ;;
    *) return 1 ;;
  esac
}

# herd_red_ledger_note <ledger-file> <key> <class> <why> [now-epoch]
#   Upsert: a NEW key records first-seen=now; an EXISTING key keeps its original first-seen and just
#   refreshes why + last-verified. No-op (RED_LEDGER off, or an empty key/ledger-file) → nothing
#   written. Always returns 0 — a red row's OWN diagnosis must never fail because the ledger could not
#   be written.
herd_red_ledger_note() {
  _red_ledger_enabled || return 0
  local _rl_file="$1" _rl_key="$2" _rl_class="$3" _rl_why="$4" _rl_now="${5:-}"
  [ -n "$_rl_file" ] && [ -n "$_rl_key" ] || return 0
  [ -n "$_rl_now" ] || _rl_now="$(_console_now_epoch)"
  local _rl_first="$_rl_now"
  if [ -s "$_rl_file" ]; then
    local _rl_prev
    _rl_prev="$(awk -F'\t' -v k="$_rl_key" '$1==k{print $3; exit}' "$_rl_file" 2>/dev/null)"
    case "$_rl_prev" in ''|*[!0-9]*) : ;; *) _rl_first="$_rl_prev" ;; esac
  fi
  mkdir -p "$(dirname "$_rl_file")" 2>/dev/null || true
  local _rl_tmp="$_rl_file.tmp.$$"
  { [ -s "$_rl_file" ] && awk -F'\t' -v k="$_rl_key" '$1!=k' "$_rl_file" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$_rl_key" "$_rl_class" "$_rl_first" "$_rl_now" "$(_red_ledger_sanitize "$_rl_why")"
  } > "$_rl_tmp" 2>/dev/null && mv "$_rl_tmp" "$_rl_file" 2>/dev/null || rm -f "$_rl_tmp" 2>/dev/null
  command -v herd_console_trim >/dev/null 2>&1 && herd_console_trim "$_rl_file" "${CONSOLE_LEDGER_MAX:-20}"
  return 0
}

# herd_red_ledger_get <ledger-file> <key>
#   Prints "<class>\t<why>\t<first-seen>\t<last-verified>" for the matching row, or nothing when
#   RED_LEDGER is off, the file/key is missing, or the row cannot be read.
herd_red_ledger_get() {
  _red_ledger_enabled || return 0
  local _rl_file="$1" _rl_key="$2"
  [ -s "${_rl_file:-}" ] 2>/dev/null || return 0
  awk -F'\t' -v k="$_rl_key" '$1==k{printf "%s\t%s\t%s\t%s", $2, $5, $3, $4; exit}' "$_rl_file" 2>/dev/null
  return 0
}

# herd_red_ledger_clear <ledger-file> <key> [reason]
#   Drop the key's row (a red went green) and journal ONE red_cleared event carrying the key + reason
#   (HERD-539: 'reverified' is the reason every cadence-driven auto-clear in this file uses). Returns
#   0 only when a row was actually present and removed — the caller's signal that this was a real
#   clear, not a no-op on an already-clear key; 1 otherwise (including RED_LEDGER off). Fail-soft: an
#   unwritable ledger still journals the clear (the ledger is a cache, the journal is the record).
herd_red_ledger_clear() {
  _red_ledger_enabled || return 1
  local _rl_file="$1" _rl_key="$2" _rl_reason="${3:-reverified}"
  [ -s "${_rl_file:-}" ] 2>/dev/null || return 1
  awk -F'\t' -v k="$_rl_key" '$1==k{f=1} END{exit !f}' "$_rl_file" 2>/dev/null || return 1
  local _rl_tmp="$_rl_file.tmp.$$"
  awk -F'\t' -v k="$_rl_key" '$1!=k' "$_rl_file" > "$_rl_tmp" 2>/dev/null \
    && mv "$_rl_tmp" "$_rl_file" 2>/dev/null || rm -f "$_rl_tmp" 2>/dev/null
  command -v journal_append >/dev/null 2>&1 && journal_append red_cleared key "$_rl_key" reason "$_rl_reason"
  return 0
}

# herd_red_ledger_age_mins <epoch> [now-epoch] — whole minutes since <epoch>; empty on a bad/missing
# epoch (never "infinitely old" — mirrors _main_health_file_age_mins).
herd_red_ledger_age_mins() {
  local _rl_epoch="${1:-}" _rl_now="${2:-}"
  case "$_rl_epoch" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$_rl_now" ] || _rl_now="$(_console_now_epoch)"
  case "$_rl_now" in ''|*[!0-9]*) return 0 ;; esac
  local _rl_age=$(( (_rl_now - _rl_epoch) / 60 ))
  [ "$_rl_age" -ge 0 ] 2>/dev/null || _rl_age=0
  printf '%s' "$_rl_age"
}

# herd_red_ledger_recheck_due <last-verified-epoch> <recheck-mins> [now-epoch]
#   0 (due) iff recheck-mins > 0 AND the row is at least that many minutes old; 1 otherwise (including
#   a non-numeric mins/epoch) — the exact cadence test reconcile_main_health already runs inline,
#   lifted here so any red class can reuse it (extends the MAIN_HEALTH_RECHECK_MINS pattern past
#   main-health, per HERD-539 leg 2).
herd_red_ledger_recheck_due() {
  local _rl_lv="${1:-}" _rl_mins="${2:-0}" _rl_now="${3:-}"
  case "$_rl_mins" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_rl_mins" -gt 0 ] 2>/dev/null || return 1
  local _rl_age; _rl_age="$(herd_red_ledger_age_mins "$_rl_lv" "$_rl_now")"
  case "$_rl_age" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_rl_age" -ge "$_rl_mins" ] 2>/dev/null
}

# herd_red_ledger_suffix <last-verified-epoch> [now-epoch]
#   " · verified Xm ago" ready to splice onto a row, or empty for a bad/missing epoch. Display only —
#   never gates anything, and the caller decides whether to call it at all (RED_LEDGER off means no
#   entry ever exists to have an epoch, so this is naturally byte-inert in that case too).
herd_red_ledger_suffix() {
  local _rl_age; _rl_age="$(herd_red_ledger_age_mins "${1:-}" "${2:-}")"
  case "$_rl_age" in ''|*[!0-9]*) return 0 ;; esac
  printf ' %s· verified %sm ago%s' "${C_DIM:-}" "$_rl_age" "${C_RESET:-}"
}

# herd_red_ledger_row_suffix <ledger-file> <key> [now-epoch]
#   herd_red_ledger_get + herd_red_ledger_suffix in one call — the shape every row-builder wants:
#   splice this straight onto the end of an existing red row string.
herd_red_ledger_row_suffix() {
  _red_ledger_enabled || return 0
  local _rl_row; _rl_row="$(herd_red_ledger_get "$1" "$2")"
  [ -n "$_rl_row" ] || return 0
  local _rl_class _rl_why _rl_first _rl_lv
  IFS=$'\t' read -r _rl_class _rl_why _rl_first _rl_lv <<EOF
$_rl_row
EOF
  herd_red_ledger_suffix "${_rl_lv:-}" "${3:-}"
}
