#!/usr/bin/env bash
# bash-syntax-lint.sh — THE shared SYSTEM-BASH SYNTAX guard (HERD-608): herd_bash_syntax_lint [<root>]
# bash -n's every scripts/herd/*.sh under the SYSTEM /bin/bash — a HARDCODED path, never
# $(command -v bash) / a PATH-resolved bash.
#
# The class this guards against (builder-bisected on the watcher machine, journal-audit.sh's own
# HERD-608 incident): once a script under scripts/herd/ crosses roughly 1271 total lines, macOS's
# SYSTEM /bin/bash 3.2.57 — which is what the watcher pane resolves (no /opt/homebrew/bin on its
# PATH) — can throw a FALSE "syntax error near unexpected token `('" at an unrelated heredoc, while a
# modern bash (5.x, whatever a developer's PATH happens to resolve) and shellcheck both parse the
# identical file cleanly. A builder who only ever runs `bash -n` (or shellcheck) against PATH bash
# never sees the failure their change is about to trip in production — the FIRST place it becomes
# visible is the live watcher pane, mid-tick. This lint closes that blind spot by running the SAME
# probe (`bash -n`) under the SAME interpreter (/bin/bash) the watcher actually resolves, at both
# gate surfaces, so a script drifting toward the cliff is caught pre-PR instead of in production.
#
# ONE implementation, sourced (never executed) by BOTH gate surfaces so they can never disagree:
#     • scripts/herd/healthcheck.sh   — the builder's LIGHT pre-PR gate
#     • .herd/healthcheck.project.sh  — the heavy/merge gate (authoritative)
#
# herd_bash_syntax_check <file>...
#   Pure form used by hermetic fixtures. bash -n's each given file under /bin/bash. Prints one
#   'BASH-SYNTAX <file> — <err>' line per failure, then an ADVISORY summary. Exit 0 clean / 1 error(s).
#   Deliberately unconditional (no /bin/bash existence check) so a hermetic test can point it at
#   /bin/bash on any box that has one — the caller (herd_bash_syntax_lint) owns the skip decision.
#
# herd_bash_syntax_lint [<root>]
#   Entrypoint for the gate surfaces: bash -n's every scripts/herd/*.sh (non-recursive — mirrors
#   caps-sync-lint.sh's own "new lane script" surface) under <root> (or cwd). Exit 0 clean / 1 syntax
#   error / 2 skipped (infra; NEVER a red). On a skip, $HERD_BASH_SYNTAX_SKIP_REASON carries the
#   one-line why.
#
# FAIL-SOFT ON THE TOOL, NEVER ON THE FINDING: a machine with no /bin/bash at all (e.g. a Windows
# collaborator on Git Bash) is a SKIP, not a red — command absence is infra, not code. A machine whose
# /bin/bash happens NOT to be 3.2 (a Linux CI box, a container) still RUNS the probe under that
# /bin/bash rather than skipping: a real syntax error is real on every bash, so the check stays
# meaningful even where it cannot reproduce the specific 3.2 heredoc-parser cliff, and it never reds
# just because a tool is absent.

HERD_BASH_SYNTAX_SKIP_REASON=""

# herd_bash_syntax_check <file>... — pure function; prints BASH-SYNTAX lines + ADVISORY. Exit 0/1.
herd_bash_syntax_check() {
  local _bs_errs="" _bs_total=0 _bs_f _bs_out _bs_n=0
  for _bs_f in "$@"; do
    [ -f "$_bs_f" ] || continue
    _bs_total=$((_bs_total + 1))
    _bs_out="$(/bin/bash -n "$_bs_f" 2>&1)" \
      || _bs_errs="${_bs_errs}BASH-SYNTAX ${_bs_f} — $(printf '%s' "$_bs_out" | tail -1)"$'\n'
  done
  printf '%s' "$_bs_errs"
  [ -n "$_bs_errs" ] && _bs_n="$(printf '%s\n' "$_bs_errs" | grep -c '^BASH-SYNTAX')"
  printf 'ADVISORY: %d file(s) checked under /bin/bash; %d syntax error(s) (clean when 0)\n' "$_bs_total" "$_bs_n"
  [ -z "$_bs_errs" ]
}

# herd_bash_syntax_lint [<root>] — scan scripts/herd/*.sh under <root> (or cwd). Exit 0/1/2.
herd_bash_syntax_lint() {
  local _bs_root="${1:-.}" _bs_files=() _bs_f _bs_out _bs_rc

  HERD_BASH_SYNTAX_SKIP_REASON=""

  if [ ! -x /bin/bash ]; then
    HERD_BASH_SYNTAX_SKIP_REASON="/bin/bash not present on this machine"
    return 2
  fi

  for _bs_f in "$_bs_root"/scripts/herd/*.sh; do
    [ -f "$_bs_f" ] && _bs_files+=("$_bs_f")
  done

  if [ "${#_bs_files[@]}" -eq 0 ]; then
    HERD_BASH_SYNTAX_SKIP_REASON="no scripts/herd/*.sh in this tree"
    return 2
  fi

  _bs_out="$(herd_bash_syntax_check "${_bs_files[@]}")"; _bs_rc=$?
  printf '%s\n' "$_bs_out"
  return "$_bs_rc"
}
