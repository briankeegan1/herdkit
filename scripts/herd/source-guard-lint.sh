#!/usr/bin/env bash
# source-guard-lint.sh — THE shared dot-source-guard drift guard (HERD-632): a fail-soft
# `. "$VAR/lib.sh"` (a best-effort, optional-dependency source, meant to degrade gracefully when the
# file is absent) must be preceded by a `[ -f ]` test — or wrapped in a real subshell — or it is a
# LATENT WHOLE-PROCESS CRASH, not the graceful skip its own `2>/dev/null || true` implies.
#
# THE BUG (HERD-632, proven live: scripts/herd/herd-claim.sh lines 56/61): bash treats `.` (source) as
# a SPECIAL BUILTIN. Per POSIX, a special builtin that hits an error — including "no such file" — may
# terminate the shell OUTRIGHT under `set -e`, bypassing the `||` entirely. So the classic fail-soft
# idiom
#     command -v some_func >/dev/null 2>&1 || . "$DIR/lib.sh" 2>/dev/null || true
# reads as "best effort, never fatal" but is NOT: under a caller's `set -euo pipefail` (the herdkit
# convention), a missing lib.sh kills the whole process — `2>/dev/null` only silences the message,
# `|| true` never runs. The fix is a `[ -f ]` test BEFORE the `.`, which short-circuits the `&&` and
# never invokes the special builtin on a path that cannot exist:
#     command -v some_func >/dev/null 2>&1 || { [ -f "$DIR/lib.sh" ] && . "$DIR/lib.sh" 2>/dev/null; } || true
# A REAL subshell also protects (its own fatal exit only kills the subshell; the parent sees an
# ordinary non-zero status): `( . "$DIR/lib.sh" 2>/dev/null; ... ) || true`, `result="$( . ... )"`, and
# `< <( . ... )` are all safe without a `[ -f ]` test. A bare `{ ...; } || true` GROUP is NOT a
# subshell and does NOT protect — the fatal exit still propagates through it.
#
# SCOPE: only a FAIL-SOFT dot-source is a bug. A source whose failure is meant to be FATAL (no
# `2>/dev/null`, or a `|| exit N` / `|| return N` with N != 0) already dies either way — the special
# builtin's bypass and the intended `||` land on the same outcome, so there is nothing to guard. This
# lint therefore only flags a dot-source of a NON-LITERAL (variable) path whose own fallback resolves
# to SUCCESS/continue (`|| true`, `|| return`, `|| return 0`, or a `{ …; exit 0; }` / `{ …; return 0; }`
# block) — exactly the shape that silently inverts from "skip gracefully" to "kill the process".
#
# SIM FIXTURES ARE EXEMPT, BY CLASSIFICATION NOT BY ACCIDENT
# ------------------------------------------------------------
# scripts/herd/sim/, scripts/herd/experiment/ and tests/ deliberately construct a missing-lib source to
# PROVE the guard (or the bug) — same FIXTURE classification git-scope-lint.sh / tab-create-lint.sh use.
# Those paths are scanned and counted, never flagged.
#
# OPT-OUT:  # source-guard-ok: <why>
# Suppresses the offending line when it appears on that line or the contiguous comment run directly
# above it — for a verified case this lint's line/subshell heuristics cannot prove safe (e.g. a
# subshell opened many lines above a helper function boundary).
#
# ONE implementation, sourced (never executed) by BOTH gate surfaces so they can never disagree:
#     • scripts/herd/healthcheck.sh   — the builder's LIGHT pre-PR gate (caught before `gh pr create`)
#     • .herd/healthcheck.project.sh  — the heavy/merge gate (authoritative)
# Sourced-library precedent: caps-sync-lint.sh / gate-coverage-lint.sh / pipe-safety-lint.sh / git-scope-lint.sh.
#
# Two functions:
#
# herd_source_guard_check <file>...
#   Pure form used by hermetic fixtures. Prints one 'SOURCE-GUARD <file>:<lineno>: <code>' line per
#   offending line on stdout, then an ADVISORY summary. Exit: 0 = clean · 1 = hit(s) on stdout.
#   Each argument is read as a FILE with `grep -n` (no producer pipe → pipefail-safe, HERD-297).
#
# herd_source_guard_lint [<root>]
#   Entrypoint for the gate surfaces. Scans the engine surface under <root> (or cwd): bin/herd,
#   herd.sh, install.sh, scripts/herd/*.sh, scripts/herd/backends/*.sh, scripts/herd/work-units/*.sh,
#   scripts/ci/*.sh, migrations/*.sh — plus the fixture surface (scripts/herd/sim/*.sh,
#   scripts/herd/experiment/*.sh, tests/*.sh) which is classified, never flagged.
#   Exit: 0 = clean · 1 = hit(s) · 2 = skipped (infra; NEVER a red).
#   On a skip, $HERD_SOURCE_GUARD_SKIP_REASON carries the one-line why.
#
# Fail-soft by construction: the scan runs ONLY in a herdkit ENGINE tree (one of scripts/herd/ or
# bin/herd present). Every consuming project skips before a file is read.

HERD_SOURCE_GUARD_SKIP_REASON=""

# A candidate: a dot-source of a NON-LITERAL path — `.` followed by whitespace then a `"$...` or bare
# `$...` token (a literal `.` "$HERE/foo.sh" with foo.sh baked in is still a variable-rooted path; a
# fully-literal path never appears this way in the engine, which always composes paths from a resolved
# HERE/DIR variable).
HERD_SOURCE_GUARD_DOT_RE='(^|[^.[:alnum:]])\.[[:space:]]+"?\$[A-Za-z_{]'

# FAIL-SOFT signature: the line's own error handling resolves to SUCCESS/continue — `|| true`,
# `|| return` (bare or `return 0`), or `exit 0` / `return 0` inside a `{ ... }` fallback block reached
# via `||`. Deliberately does NOT match `|| exit 1` / `|| exit 2` / `|| return 1` etc. — those already
# die under the special-builtin bypass exactly as they would through the intended `||`, so there is no
# behavior to guard.
HERD_SOURCE_GUARD_FAILSOFT_RE='\|\|[[:space:]]*(true|return)([[:space:]]|;|$)|\|\|[[:space:]]*\{[^}]*\b(exit|return)[[:space:]]+0\b'

# _sg_is_fixture <path> — true for a sim/experiment/test file: these deliberately construct a
# missing-lib source to prove the guard, and must never be scanned as production code.
_sg_is_fixture() {
  case "$1" in
    */scripts/herd/sim/*|scripts/herd/sim/*) return 0 ;;
    */scripts/herd/experiment/*|scripts/herd/experiment/*) return 0 ;;
    */tests/*|tests/*) return 0 ;;
  esac
  return 1
}

# _sg_path_token <line> — the argument of the ACTUAL dot-source on <line>, quotes stripped, so it can
# be compared against a `[ -f ... ]` test's own argument. Anchors on the LITERAL `. "$...` / `. $...`
# token (not just "the first dot in the line", which a `.sh` extension inside an earlier `[ -f "$X" ]`
# guard on the SAME line would otherwise false-match) and takes the LAST such occurrence — the real
# source call, since a same-line guard's own `[ -f "$X" ]` never itself matches `\.[[:space:]]+"?\$`.
_sg_path_token() {
  local _spt
  _spt="$(printf '%s\n' "$1" | grep -oE '\.[[:space:]]+"?\$[A-Za-z_][^"[:space:];|&]*"?' | tail -1)"  # pipe-ok: single captured line, far under a pipe buffer
  _spt="${_spt#.}"
  _spt="${_spt#"${_spt%%[![:space:]]*}"}"   # trim leading whitespace left by the dot
  printf '%s' "${_spt//\"/}"
}

# _sg_guarded_by_test <blob> <path> — does <blob> (quote-stripped) contain a `-f <path>` test for the
# SAME path the candidate line sources? Covers both the same-line compound form
# (`{ [ -f "$X" ] && . "$X" ...; } || true`) and the preceding-guard-clause form
# (`[ -f "$X" ] || return 0` on the line(s) directly above the source, spawn-step.sh's shape).
_sg_guarded_by_test() {
  local _sg_blob _sg_path
  _sg_blob="$(printf '%s' "$1" | tr -d '"')"
  _sg_path="$(printf '%s' "$2" | tr -d '"')"
  [ -n "$_sg_path" ] || return 1
  case "$_sg_blob" in
    *"-f $_sg_path"*|*"-f  $_sg_path"*) return 0 ;;
  esac
  return 1
}

# _sg_guarded_by_subshell <file> <lineno> — approximate: walk backward from <lineno> looking for the
# nearest structurally-relevant line. A line ending in `(` (bare `(`, or a `$(` / `<(` opener — all
# three protect identically, HERD-632: the fatal special-builtin exit only kills the subshell, the
# parent sees an ordinary non-zero status) found before any line that STARTS with `)` (a multi-line
# block that already closed) means <lineno> sits inside a real subshell. Bounded to 60 lines and to a
# function-definition boundary so the walk can never run away. Approximate by design (a textual scan,
# not a parser) — a genuine false negative is expected to opt out with `# source-guard-ok: <why>`.
_sg_guarded_by_subshell() {
  local _sgb_file="$1" _sgb_line="$2" _sgb_i _sgb_ln _sgb_trim _sgb_steps=0
  _sgb_i=$((_sgb_line - 1))
  while [ "$_sgb_i" -ge 1 ] && [ "$_sgb_steps" -lt 60 ]; do
    _sgb_ln="$(sed -n "${_sgb_i}p" "$_sgb_file" 2>/dev/null)"
    _sgb_trim="${_sgb_ln#"${_sgb_ln%%[![:space:]]*}"}"
    case "$_sgb_trim" in
      ')'*) return 1 ;;                                    # a block already closed — not inside one
      *[A-Za-z_]'()'*'{') return 1 ;;                       # crossed a function boundary — stop
    esac
    case "$_sgb_ln" in *'(') return 0 ;; esac               # bare/$(/<( opener — subshell-safe
    _sgb_i=$((_sgb_i - 1)); _sgb_steps=$((_sgb_steps + 1))
  done
  return 1
}

# herd_source_guard_check <file>... — pure function; prints SOURCE-GUARD lines + ADVISORY. Exit 0/1.
herd_source_guard_check() {
  local _sg_hits="" _sg_total=0 _sg_annot=0 _sg_fixture=0 _sg_f _sg_cands _sg_num _sg_code _sg_trim
  local _sg_n _sg_ln _sg_ok _sg_j _sg_path _sg_blob _sg_start
  local -a _sg_arr
  for _sg_f in "$@"; do
    [ -f "$_sg_f" ] || continue
    if _sg_is_fixture "$_sg_f"; then _sg_fixture=$((_sg_fixture + 1)); continue; fi

    # Candidate lines: any dot-source-of-variable that is ALSO fail-soft. `grep -n` reads the FILE
    # directly (no producer pipe → pipefail-safe, HERD-297). `|| true`: grep exits 1 on no-match.
    _sg_cands="$(grep -nE "$HERD_SOURCE_GUARD_DOT_RE" "$_sg_f" 2>/dev/null | grep -E "$HERD_SOURCE_GUARD_FAILSOFT_RE" || true)"  # pipe-ok: both greps read/re-filter an already-captured string, no producer process
    [ -n "$_sg_cands" ] || continue

    _sg_arr=(); _sg_n=0
    while IFS= read -r _sg_ln || [ -n "$_sg_ln" ]; do
      _sg_n=$((_sg_n + 1)); _sg_arr[_sg_n]="$_sg_ln"
    done < "$_sg_f"

    while IFS= read -r _sg_num; do
      [ -n "$_sg_num" ] || continue
      _sg_num="${_sg_num%%:*}"           # leading 'LINENO:' from grep -n
      _sg_code="${_sg_arr[_sg_num]}"
      _sg_trim="${_sg_code#"${_sg_code%%[![:space:]]*}"}"
      case "$_sg_trim" in '#'*) continue ;; esac   # pure-comment line (this header, sibling notes)

      # Opt-out: '# source-guard-ok' on the offending line, or on the contiguous comment run directly
      # above it.
      _sg_ok=0
      case "$_sg_code" in *'# source-guard-ok'*) _sg_ok=1 ;; esac
      _sg_j=$((_sg_num - 1))
      while [ "$_sg_ok" -eq 0 ] && [ "$_sg_j" -ge 1 ]; do
        _sg_ln="${_sg_arr[_sg_j]}"
        case "${_sg_ln#"${_sg_ln%%[![:space:]]*}"}" in '#'*) ;; *) break ;; esac
        case "$_sg_ln" in *'# source-guard-ok'*) _sg_ok=1 ;; esac
        _sg_j=$((_sg_j - 1))
      done
      if [ "$_sg_ok" -eq 1 ]; then _sg_annot=$((_sg_annot + 1)); continue; fi

      # Guarded by an explicit `[ -f <same-path> ]` test — same line, or a preceding guard-clause line
      # (spawn-step.sh's `[ -f "$X" ] || return 0` directly above the source; look back up to 4 lines).
      _sg_path="$(_sg_path_token "$_sg_code")"
      _sg_start=$((_sg_num - 4)); [ "$_sg_start" -lt 1 ] && _sg_start=1
      _sg_blob=""
      _sg_j="$_sg_start"
      while [ "$_sg_j" -le "$_sg_num" ]; do
        _sg_blob="${_sg_blob} ${_sg_arr[_sg_j]}"
        _sg_j=$((_sg_j + 1))
      done
      if _sg_guarded_by_test "$_sg_blob" "$_sg_path"; then continue; fi

      # Guarded by a real subshell (the fatal exit only kills the subshell, never the caller).
      if _sg_guarded_by_subshell "$_sg_f" "$_sg_num"; then continue; fi

      _sg_total=$((_sg_total + 1))
      _sg_hits="${_sg_hits}SOURCE-GUARD ${_sg_f}:${_sg_num}: ${_sg_trim}"$'\n'
    done < <(printf '%s\n' "$_sg_cands")
  done

  printf '%s' "$_sg_hits"
  printf 'ADVISORY: %d unguarded fail-soft dot-source(s); %d opted-out via # source-guard-ok; %d fixture file(s) skipped (clean when 0 unguarded)\n' \
    "$_sg_total" "$_sg_annot" "$_sg_fixture"
  [ -z "$_sg_hits" ]
}

# herd_source_guard_lint [<root>] — scan the engine surface under <root> (or cwd). Exit 0/1/2.
herd_source_guard_lint() {
  local _sg_root="${1:-.}" _sg_files=() _sg_fx=() _sg_f _sg_out _sg_rc

  HERD_SOURCE_GUARD_SKIP_REASON=""

  # ENGINE-TREE MARKER FIRST — this guard is about herdkit's OWN engine surface (see git-scope-lint.sh
  # for the same precedent): a consuming project never reaches the scan.
  if [ ! -d "$_sg_root/scripts/herd" ] && [ ! -f "$_sg_root/bin/herd" ]; then
    HERD_SOURCE_GUARD_SKIP_REASON="not a herdkit engine tree (no scripts/herd or bin/herd)"
    return 2
  fi

  for _sg_f in "$_sg_root"/scripts/herd/*.sh "$_sg_root"/scripts/herd/backends/*.sh \
               "$_sg_root"/scripts/herd/work-units/*.sh "$_sg_root"/scripts/ci/*.sh \
               "$_sg_root"/migrations/*.sh; do
    [ -f "$_sg_f" ] && _sg_files+=("$_sg_f")
  done
  for _sg_f in "$_sg_root/bin/herd" "$_sg_root/herd.sh" "$_sg_root/install.sh"; do
    [ -f "$_sg_f" ] && _sg_files+=("$_sg_f")
  done

  if [ "${#_sg_files[@]}" -eq 0 ]; then
    HERD_SOURCE_GUARD_SKIP_REASON="no engine source surface (scripts/herd, scripts/ci, bin/herd) in this tree"
    return 2
  fi

  # The FIXTURE surface is scanned too — classified and counted, never flagged.
  for _sg_f in "$_sg_root"/scripts/herd/sim/*.sh "$_sg_root"/scripts/herd/experiment/*.sh \
               "$_sg_root"/tests/*.sh; do
    [ -f "$_sg_f" ] && _sg_fx+=("$_sg_f")
  done
  [ "${#_sg_fx[@]}" -gt 0 ] && _sg_files+=("${_sg_fx[@]}")

  _sg_out="$(herd_source_guard_check "${_sg_files[@]}")"; _sg_rc=$?
  printf '%s\n' "$_sg_out"
  return "$_sg_rc"
}
