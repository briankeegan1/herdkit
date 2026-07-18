#!/usr/bin/env bash
# deps-parse.sh — THE shared .herd/deps row parser (HERD-389): exact-field ref matching for
# "blocked-on: <ref>  since=<epoch>" / "watch: <ref>  since=<epoch>" rows.
#
# A ref is matched by extracting the row's ref FIELD (stripping the "blocked-on: "/"watch: "
# prefix, then trimming everything from the first whitespace on — the since=<epoch> trailer)
# and comparing it for EXACT equality against the caller's <ref>. This anchors the match to the
# whole field: a substring/prefix test (e.g. `grep -Fv "blocked-on: ${ref}"`) would also match
# provider-lib#42 while removing provider-lib#4, corrupting an unrelated row.
#
# bin/herd (cmd_deps_rm / cmd_deps_demote / cmd_depend) and dep-watcher.sh (_dw_remove_dep) both
# source this ONE file so the anchored-match pattern cannot re-diverge between the two consumers.
#
# _deps_kind_of <file> <ref>   → prints "blocked-on" | "watch" | "" (empty = not present)
# _deps_set_kind <file> <ref> <new-kind> — rewrite the row's prefix, PRESERVING trailing fields
#   (since=…). Atomic via temp file + mv.
# _deps_remove <file> <ref>   — drop the row (blocked-on OR watch) for <ref>. Returns 0 if one was
#   removed, 1 if the ref was absent. Atomic temp-file + mv.

_deps_kind_of() {
  local f="$1" ref="$2" line r
  [ -f "$f" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      'blocked-on: '*) r="${line#blocked-on: }" ;;
      'watch: '*)      r="${line#watch: }" ;;
      *) continue ;;
    esac
    r="${r%%[[:space:]]*}"
    [ "$r" = "$ref" ] || continue
    case "$line" in 'blocked-on: '*) printf 'blocked-on' ;; *) printf 'watch' ;; esac
    return 0
  done < "$f"
}

_deps_set_kind() {
  local f="$1" ref="$2" newkind="$3" tmp line rest r
  [ -f "$f" ] || return 1
  tmp="${f}.$$"
  while IFS= read -r line; do
    case "$line" in
      'blocked-on: '*) rest="${line#blocked-on: }" ;;
      'watch: '*)      rest="${line#watch: }" ;;
      *) printf '%s\n' "$line"; continue ;;
    esac
    r="${rest%%[[:space:]]*}"
    if [ "$r" = "$ref" ]; then printf '%s: %s\n' "$newkind" "$rest"; else printf '%s\n' "$line"; fi
  done < "$f" > "$tmp"
  mv "$tmp" "$f"
}

_deps_remove() {
  local f="$1" ref="$2" tmp line r removed=1
  [ -f "$f" ] || return 1
  tmp="${f}.$$"
  while IFS= read -r line; do
    case "$line" in
      'blocked-on: '*) r="${line#blocked-on: }" ;;
      'watch: '*)      r="${line#watch: }" ;;
      *) printf '%s\n' "$line"; continue ;;
    esac
    r="${r%%[[:space:]]*}"
    if [ "$r" = "$ref" ]; then removed=0; continue; fi
    printf '%s\n' "$line"
  done < "$f" > "$tmp"
  mv "$tmp" "$f"
  return "$removed"
}
