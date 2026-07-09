#!/usr/bin/env bash
# console-section.sh — THE shared bounded-console-section helper (HERD-243).
#
# The watcher renders several append-only LEDGERS as console sections (tracker heals, builder notes).
# Left alone, an append-only ledger renders forever: a handled row sits on screen until a newer row
# displaces it, and the operator learns to ignore the whole section. This library is the ONE place
# that decides which ledger rows are still worth an operator's eyes:
#
#   (a) CALM rows (an auto-healed drift, a builder note) age out of DISPLAY after CONSOLE_ROW_RETENTION
#       (2h). They stay in the ledger and in the journal — this is display-only.
#   (b) LOUD rows (a FAILED heal) never age out while unresolved. A stuck drift stays on screen.
#   (c) ACK — a row whose exact ledger line is present in an ack file is hidden immediately
#       (`herd notes ack`). History is untouched; only the console clears.
#   (d) TRIM — every ledger is bounded on write to CONSOLE_LEDGER_MAX rows, so no surface grows
#       unbounded.
#
# ONE implementation, SOURCED (never executed) by every surface that reads or writes those ledgers so
# they can never disagree — sourced-library precedent: merge-policy.sh, caps-sync-lint.sh.
#     • scripts/herd/agent-watch.sh       — renders both sections each tick
#     • scripts/herd/tracker-state-sweep.sh — writes (and trims) the heal ledger
#     • bin/herd                          — `herd notes` lists / acks builder notes
#
# Fail-soft by construction: an unparseable epoch, a missing file, a clock that ran backwards → the
# row is SHOWN (a surface never silently swallows a row it failed to classify).

# Display retention for calm rows, in seconds. Inline constant on purpose: this is a legibility
# property of the console, not an operator knob (no config key, no manifest row).
CONSOLE_ROW_RETENTION=7200          # 2h
# Rows kept in any bounded ledger FILE (tail-keep, applied on write).
CONSOLE_LEDGER_MAX=20

_console_now_epoch() { printf '%s' "${HERD_FAKE_NOW:-$(date +%s)}"; }
_console_reverse_file() { tac "$1" 2>/dev/null || tail -r "$1" 2>/dev/null; }

# herd_console_row_visible <now-epoch> <row-epoch> <calm|loud>
#   0 = render this row · 1 = aged out. Loud rows are always visible; so is any row whose epoch (or
#   the clock) does not parse, so a classifier bug can never hide a row.
herd_console_row_visible() {
  local _cs_now="$1" _cs_epoch="$2" _cs_loud="${3:-calm}" _cs_age
  [ "$_cs_loud" = "loud" ] && return 0
  case "$_cs_epoch" in ''|*[!0-9]*) return 0 ;; esac
  case "$_cs_now"   in ''|*[!0-9]*) return 0 ;; esac
  _cs_age=$(( _cs_now - _cs_epoch ))
  [ "$_cs_age" -lt 0 ] && return 0        # clock skew → show
  [ "$_cs_age" -le "$CONSOLE_ROW_RETENTION" ]
}

# herd_console_classify_tracker_heal <line>   ("<epoch> <status> <ref> <pr> <found-state>")
#   Prints "<epoch>\t<calm|loud>". A `healed` row is calm (the drift was auto-corrected); anything
#   else is a FAILED heal — loud, and it stays on screen until the sweep succeeds.
herd_console_classify_tracker_heal() {
  local _cs_epoch _cs_status _cs_rest
  local IFS=$' \t\n'
  read -r _cs_epoch _cs_status _cs_rest <<EOF
$1
EOF
  case "${_cs_status:-}" in
    healed) printf '%s\tcalm' "${_cs_epoch:-}" ;;
    *)      printf '%s\tloud' "${_cs_epoch:-}" ;;
  esac
}

# herd_console_classify_builder_note <line>   ("<epoch>\t<slug>\t<text>\t<ts>")
#   Prints "<epoch>\tcalm". Every builder note is informational: it ages out, and it can be acked.
herd_console_classify_builder_note() {
  local _cs_epoch
  IFS=$'\t' read -r _cs_epoch _ <<EOF
$1
EOF
  printf '%s\tcalm' "${_cs_epoch:-}"
}

# herd_console_acked <ack-file> <line>  → 0 when this exact ledger line has been acknowledged.
herd_console_acked() {
  local _cs_ack="${1:-}" _cs_line="$2"
  [ -n "$_cs_ack" ] && [ -s "$_cs_ack" ] || return 1
  grep -Fxq -- "$_cs_line" "$_cs_ack" 2>/dev/null
}

# herd_console_visible_lines <ledger> <limit> <classify-fn> [ack-file]
#   The RAW ledger lines that still deserve console space: newest first, aged-out and acked rows
#   dropped (a dropped row does NOT consume a slot), at most <limit> rows. Prints nothing for a
#   missing/empty ledger — the caller renders no section at all.
herd_console_visible_lines() {
  local _cs_file="$1" _cs_limit="$2" _cs_classify="$3" _cs_ack="${4:-}"
  [ -s "$_cs_file" ] || return 0
  local _cs_line _cs_meta _cs_epoch _cs_loud _cs_now _cs_n=0
  _cs_now="$(_console_now_epoch)"
  while IFS= read -r _cs_line; do
    [ -n "$_cs_line" ] || continue
    _cs_meta="$("$_cs_classify" "$_cs_line")" || continue
    IFS=$'\t' read -r _cs_epoch _cs_loud <<EOF
$_cs_meta
EOF
    herd_console_row_visible "$_cs_now" "${_cs_epoch:-}" "${_cs_loud:-calm}" || continue
    herd_console_acked "$_cs_ack" "$_cs_line" && continue
    printf '%s\n' "$_cs_line"
    _cs_n=$(( _cs_n + 1 ))
    [ "$_cs_n" -ge "$_cs_limit" ] && break
  done < <(_console_reverse_file "$_cs_file")
  return 0
}

# herd_console_section <ledger> <limit> <classify-fn> <render-fn> [ack-file]
#   The rendered section body: <render-fn> is called once per visible line (newest first) and prints
#   ONE console row (no trailing newline needed). Empty output ⇒ the section is omitted entirely, so
#   an unused surface leaves the console byte-identical.
herd_console_section() {
  local _cs_file="$1" _cs_limit="$2" _cs_classify="$3" _cs_render="$4" _cs_ack="${5:-}"
  local _cs_line _cs_row _cs_rows=""
  while IFS= read -r _cs_line; do
    [ -n "$_cs_line" ] || continue
    _cs_row="$("$_cs_render" "$_cs_line")" || continue
    [ -n "$_cs_row" ] || continue
    _cs_rows="${_cs_rows}${_cs_row}"$'\n'
  done < <(herd_console_visible_lines "$_cs_file" "$_cs_limit" "$_cs_classify" "$_cs_ack")
  printf '%s' "$_cs_rows"
}

# herd_console_trim <file> [max]  — tail-keep the last <max> lines (default CONSOLE_LEDGER_MAX).
#   Call on every append. Always returns 0: a ledger that cannot be trimmed is never a hard error.
herd_console_trim() {
  local _cs_file="$1" _cs_max="${2:-$CONSOLE_LEDGER_MAX}" _cs_n _cs_tmp
  [ -f "$_cs_file" ] || return 0
  case "$_cs_max" in ''|*[!0-9]*) return 0 ;; esac
  _cs_n="$(wc -l < "$_cs_file" 2>/dev/null | tr -cd '0-9')"
  [ "${_cs_n:-0}" -gt "$_cs_max" ] 2>/dev/null || return 0
  _cs_tmp="$_cs_file.tmp.$$"
  tail -n "$_cs_max" "$_cs_file" > "$_cs_tmp" 2>/dev/null \
    && mv "$_cs_tmp" "$_cs_file" 2>/dev/null \
    || rm -f "$_cs_tmp" 2>/dev/null
  return 0
}
