#!/usr/bin/env bash
# git-scope-lint.sh — THE shared engine/project ISOLATION guard (HERD-435, GitHub issue #547): every
# git STAGING or COMMIT the engine performs against a REAL tree must name the paths it touches.
#
# THE PROPERTY BEING ENFORCED
# ---------------------------
# herdkit runs inside a live checkout that an operator also works in, beside a sibling worktree pool
# ($WORKTREES_DIR), and — as issue #547 reported — potentially beside or above an UNRELATED project
# repo. A single `git add -A` or `git commit -a` on such a tree sweeps up whatever happens to be
# sitting there: the operator's half-finished edit, a config.local, a nested foreign repo's gitlink.
# Today no engine path does that (audited for HERD-435: every `git add -A` in the tree is a sim
# fixture operating on a throwaway temp repo). But that isolation was EMERGENT — it held only because
# each call site was written carefully, and nothing stopped the next one from breaking it. This lint
# turns it into an ENFORCED property: repo-wide staging in a production path is a CODE error.
#
# TWO VIOLATION CLASSES
#   REPO-WIDE   `git add -A` / `--all` / `-u` / `.` / `:/` / `*`, and `git commit -a|-am|--all`.
#               These stage by SCAN, not by name — the shape that can reach a path the engine does
#               not own. Always a red in a production path.
#   UNSCOPED    a `git commit` with no `-- <pathspec>`. It commits whatever the INDEX holds, so a
#               path staged by someone else (an operator mid-edit in the shared checkout) rides along
#               under a message that never mentions it. Already documented as a live hazard in
#               pysrc/herd/work_unit.py's `_restore_pre_apply` docstring. Opt-out-able (below), since
#               the file/changelog scribe backends deliberately commit index-wide after a NAMED add.
#
# SIM FIXTURES ARE EXEMPT, BY CLASSIFICATION NOT BY ACCIDENT
# ----------------------------------------------------------
# scripts/herd/sim/, scripts/herd/experiment/ and tests/ build throwaway repos in temp dirs and
# legitimately `git add -A` them. Those paths are SCANNED and then classified FIXTURE, so the
# advisory reports how many were skipped and the distinction is itself testable — rather than falling
# out of a glob that happens not to recurse.
#
# OPT-OUT:  # herd-scope-ok: <why>
# It suppresses the offending line when it appears ON that line, anywhere in the same CONTINUED
# logical command (a line joined to the next by a trailing `\`, `,`, `(` or `[` — which covers a
# shell line continuation and a wrapped python argv list alike), OR on the contiguous run of comment
# lines immediately ABOVE that command (so a long call site can carry its rationale on its own line
# instead of a 200-column trailer). Pure-comment lines (a `#`-led line that merely documents the
# pattern, as this header does) are never flagged.
#
# ONE implementation, sourced (never executed) by BOTH gate surfaces so they can never disagree:
#     • scripts/herd/healthcheck.sh   — the builder's LIGHT pre-PR gate (caught before `gh pr create`)
#     • .herd/healthcheck.project.sh  — the heavy/merge gate (authoritative)
# Sourced-library precedent: caps-sync-lint.sh / gate-coverage-lint.sh / pipe-safety-lint.sh.
#
# Two functions:
#
# herd_git_scope_check <file>...
#   Pure form used by hermetic fixtures. Prints one 'GIT-SCOPE <file>:<lineno>: <class>: <code>' line
#   per offending line on stdout, then an ADVISORY summary. Exit: 0 = clean · 1 = hit(s) on stdout.
#   Classification is by PATH, so a fixture file passed here is skipped exactly as the scan would.
#   Each argument is read as a FILE with `grep -n` (no producer pipe → pipefail-safe, HERD-297).
#
# herd_git_scope_lint [<root>]
#   Entrypoint for the gate surfaces. Scans the engine surface under <root> (or cwd): bin/herd,
#   herd.sh, install.sh, scripts/herd/*.sh, scripts/herd/backends/*.sh, scripts/herd/work-units/*.sh,
#   scripts/ci/*.sh, migrations/*.sh, pysrc/herd/*.py — plus the fixture surface
#   (scripts/herd/sim/*.sh, scripts/herd/experiment/*.sh, tests/*.sh) which is classified, never
#   flagged. Exit: 0 = clean · 1 = hit(s) · 2 = skipped (infra; NEVER a red).
#   On a skip, $HERD_GIT_SCOPE_SKIP_REASON carries the one-line why.
#
# Fail-soft by construction: the scan runs ONLY in a herdkit ENGINE tree (one of scripts/herd/,
# pysrc/herd/ or bin/herd present). Every consuming project skips before a file is read — a consumer
# owns its own install.sh / scripts/ci and may stage however it likes there; this guard is about the
# engine's git operations, and must never red someone else's repo.

HERD_GIT_SCOPE_SKIP_REASON=""

# Lines are NORMALIZED before matching: quotes and commas become spaces. That makes ONE token grammar
# cover both the shell form (`git -C "$d" add -A`) and the python argv form
# (`["git", "-C", main, "add", "-A"]`), so the guard covers the python engine core too.
#
# A repo-wide STAGING selector: `git [-C d] add` … followed by a standalone -A/--all/-u/--update/./:/ /*.
# The `[^;&|]*` cannot cross a command separator, so `git add "$f" && echo -A` is not a hit; requiring
# whitespace immediately before the selector keeps the `.` in `git add some.file` from matching, and
# the trailing class accepts a command TERMINATOR as well as whitespace/EOL — `git add -A;` inside a
# one-line `{ …; }` body is the commonest real shape and must not slip through on the `;`.
HERD_GIT_SCOPE_ADD_RE='git[[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+[[:space:]]+)*add[[:space:]]+([^;&|]*[[:space:]])?(-A|--all|-u|--update|\.|:/|\*)([[:space:]]|[;&|)]|$)'
# `git commit -a` in any short-option cluster (-a, -am, -qam) or as --all. A long option can never
# match the cluster arm (`[[:alnum:]]` excludes the second `-`), so `--amend` is not a hit.
HERD_GIT_SCOPE_COMMITALL_RE='git[[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+[[:space:]]+)*commit[[:space:]]+([^;&|]*[[:space:]])?(-[[:alnum:]]*a[[:alnum:]]*|--all)([[:space:]]|[;&|)]|$)'
# Any `git commit` INVOCATION — the UNSCOPED candidate set, narrowed below by the ` -- ` test. The
# subcommand must be followed by an option, end-of-line, or a command terminator, so English prose
# that merely names the command (`die "git commit failed at $path"`) is not mistaken for a call.
HERD_GIT_SCOPE_COMMIT_RE='git[[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+[[:space:]]+)*commit([[:space:]]+-|[[:space:]]*([;&|)]|$))'

# _gs_is_fixture <path> — true for a sim/experiment/test file: a throwaway repo in a temp dir, where
# repo-wide staging is the correct, cheapest thing to do and must stay clean.
_gs_is_fixture() {
  case "$1" in
    */scripts/herd/sim/*|scripts/herd/sim/*) return 0 ;;
    */scripts/herd/experiment/*|scripts/herd/experiment/*) return 0 ;;
    */tests/*|tests/*) return 0 ;;
  esac
  return 1
}

# _gs_continues <line> — true when the NEXT physical line is part of the same logical command: a
# shell backslash continuation, or an unclosed argv list (a line ending in `,`, `(` or `[`). Used
# both to find a wrapped ` -- ` pathspec and to let one `# herd-scope-ok` cover the whole command.
_gs_continues() {
  case "$1" in
    *\\|*,|*\(|*\[) return 0 ;;
  esac
  return 1
}

# herd_git_scope_check <file>... — pure function; prints GIT-SCOPE lines + ADVISORY. Exit 0/1.
herd_git_scope_check() {
  local _gs_hits="" _gs_total=0 _gs_annot=0 _gs_fixture=0 _gs_f _gs_cands _gs_num _gs_code _gs_trim
  local _gs_n _gs_ln _gs_start _gs_end _gs_prev _gs_j _gs_ok _gs_norm _gs_class _gs_block _gs_ctrim
  local -a _gs_arr
  for _gs_f in "$@"; do
    [ -f "$_gs_f" ] || continue
    if _gs_is_fixture "$_gs_f"; then _gs_fixture=$((_gs_fixture + 1)); continue; fi

    # Candidate lines: any `git … add` or `git … commit`. The file is normalized THROUGH `tr` first —
    # the same quote/comma → space mapping applied per line below — so the python argv form
    # (`["git", "-C", main, "add", …]`) is a candidate exactly as the shell form is. `grep -n` reads
    # its whole input (no early exit, so no EPIPE — HERD-297) and the line numbers are unchanged by a
    # 1:1 character map. `|| true`: grep exits 1 on no-match. Skip the (usual) clean file before
    # paying to slurp it into an array.
    _gs_cands="$(tr '\042\047,' '   ' < "$_gs_f" 2>/dev/null \
      | grep -nE 'git[[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+[[:space:]]+)*(add[[:space:]]|commit([[:space:]]+-|[[:space:]]*([;&|)]|$)))' || true)"
    [ -n "$_gs_cands" ] || continue

    # Slurp into a 1-indexed array (bash 3.2 has no mapfile) so a continued command can be inspected
    # whole. The `|| [ -n "$_gs_ln" ]` keeps a final newline-less line.
    _gs_arr=(); _gs_n=0
    while IFS= read -r _gs_ln || [ -n "$_gs_ln" ]; do
      _gs_n=$((_gs_n + 1)); _gs_arr[_gs_n]="$_gs_ln"
    done < "$_gs_f"

    while IFS= read -r _gs_num; do
      [ -n "$_gs_num" ] || continue
      _gs_num="${_gs_num%%:*}"           # leading 'LINENO:' from grep -n
      _gs_code="${_gs_arr[_gs_num]}"
      # A pure-comment line only documents the pattern (this header, the sibling guards' notes).
      _gs_trim="${_gs_code#"${_gs_code%%[![:space:]]*}"}"
      case "$_gs_trim" in '#'*) continue ;; esac

      # Normalize quotes/commas to spaces so one grammar covers shell and python argv alike.
      _gs_norm="${_gs_code//[\"\',]/ }"

      # Bound the logical command this line belongs to: walk up while the previous line continues,
      # then down while the current one does.
      _gs_start="$_gs_num"
      while [ "$_gs_start" -gt 1 ]; do
        _gs_prev=$((_gs_start - 1))
        if _gs_continues "${_gs_arr[_gs_prev]}"; then _gs_start="$_gs_prev"; else break; fi
      done
      _gs_end="$_gs_num"
      while [ -n "${_gs_arr[_gs_end]+x}" ]; do
        if _gs_continues "${_gs_arr[_gs_end]}"; then _gs_end=$((_gs_end + 1)); else break; fi
      done

      # A `# herd-scope-ok` on ANY line of that command opts the whole command out (the offending
      # line may end in `\` or `,`, which cannot hold a trailing comment).
      _gs_ok=0; _gs_j="$_gs_start"; _gs_block=""
      while [ "$_gs_j" -le "$_gs_end" ]; do
        case "${_gs_arr[_gs_j]}" in *'# herd-scope-ok'*) _gs_ok=1 ;; esac
        _gs_block="${_gs_block} ${_gs_arr[_gs_j]//[\"\',]/ }"
        _gs_j=$((_gs_j + 1))
      done
      # …or on the contiguous comment run directly above the command, so a long call site can carry
      # its rationale on its own line. The run stops at the first non-comment line.
      _gs_j=$((_gs_start - 1))
      while [ "$_gs_ok" -eq 0 ] && [ "$_gs_j" -ge 1 ]; do
        _gs_ln="${_gs_arr[_gs_j]}"
        _gs_ctrim="${_gs_ln#"${_gs_ln%%[![:space:]]*}"}"
        case "$_gs_ctrim" in '#'*) ;; *) break ;; esac
        case "$_gs_ln" in *'# herd-scope-ok'*) _gs_ok=1 ;; esac
        _gs_j=$((_gs_j - 1))
      done
      if [ "$_gs_ok" -eq 1 ]; then _gs_annot=$((_gs_annot + 1)); continue; fi

      _gs_class=""
      if printf '%s' "$_gs_norm" | grep -qE "$HERD_GIT_SCOPE_ADD_RE"; then          # pipe-ok: one normalized line, far under a pipe buffer
        # Class strings deliberately omit the leading `git ` so this file never matches its own
        # grammar — the guard must be clean on the tree it guards, without needing an opt-out.
        _gs_class="REPO-WIDE staging (add -A/./-u) — name the paths instead"
      elif printf '%s' "$_gs_norm" | grep -qE "$HERD_GIT_SCOPE_COMMITALL_RE"; then  # pipe-ok: one normalized line, far under a pipe buffer
        _gs_class="REPO-WIDE commit (commit -a) — stages every tracked change"
      elif printf '%s' "$_gs_norm" | grep -qE "$HERD_GIT_SCOPE_COMMIT_RE"; then     # pipe-ok: one normalized line, far under a pipe buffer
        # Scoped when a ` -- ` pathspec appears anywhere in the same logical command (it is routinely
        # on a wrapped continuation line in the python argv form).
        case " $_gs_block " in
          *' -- '*) : ;;
          *) _gs_class="UNSCOPED commit (no -- pathspec) — commits the whole INDEX" ;;
        esac
      fi
      [ -n "$_gs_class" ] || continue

      _gs_total=$((_gs_total + 1))
      _gs_hits="${_gs_hits}GIT-SCOPE ${_gs_f}:${_gs_num}: ${_gs_class}: ${_gs_trim}"$'\n'
    done < <(printf '%s\n' "$_gs_cands")
  done

  printf '%s' "$_gs_hits"
  printf 'ADVISORY: %d unscoped git op(s); %d opted-out via # herd-scope-ok; %d fixture file(s) skipped (clean when 0 unscoped)\n' \
    "$_gs_total" "$_gs_annot" "$_gs_fixture"
  [ -z "$_gs_hits" ]
}

# herd_git_scope_lint [<root>] — scan the engine surface under <root> (or cwd). Exit 0/1/2.
herd_git_scope_lint() {
  local _gs_root="${1:-.}" _gs_files=() _gs_fx=() _gs_f _gs_out _gs_rc

  HERD_GIT_SCOPE_SKIP_REASON=""

  # ENGINE-TREE MARKER FIRST. This guard is about herdkit's OWN engine surface, so it must never
  # reach into a CONSUMING project's code: a consumer legitimately owns an `install.sh` or a
  # `scripts/ci/*.sh` that stages however it likes, and reding those would be a false red in someone
  # else's repo. scripts/herd/, pysrc/herd/ and bin/herd exist only in the engine checkout (a consumer
  # runs the CLI from $HERDKIT_HOME), so requiring one of them is the precise test for "this IS the
  # engine tree" — and every consuming project skips before a single file is read.
  if [ ! -d "$_gs_root/scripts/herd" ] && [ ! -d "$_gs_root/pysrc/herd" ] && [ ! -f "$_gs_root/bin/herd" ]; then
    HERD_GIT_SCOPE_SKIP_REASON="not a herdkit engine tree (no scripts/herd, pysrc/herd, or bin/herd)"
    return 2
  fi

  # An unmatched glob expands to the literal pattern; the `[ -f ]` guard drops it (no nullglob needed,
  # bash 3.2-safe).
  for _gs_f in "$_gs_root"/scripts/herd/*.sh "$_gs_root"/scripts/herd/backends/*.sh \
               "$_gs_root"/scripts/herd/work-units/*.sh "$_gs_root"/scripts/ci/*.sh \
               "$_gs_root"/migrations/*.sh "$_gs_root"/pysrc/herd/*.py; do
    [ -f "$_gs_f" ] && _gs_files+=("$_gs_f")
  done
  for _gs_f in "$_gs_root/bin/herd" "$_gs_root/herd.sh" "$_gs_root/install.sh"; do
    [ -f "$_gs_f" ] && _gs_files+=("$_gs_f")
  done

  if [ "${#_gs_files[@]}" -eq 0 ]; then
    HERD_GIT_SCOPE_SKIP_REASON="no engine git surface (scripts/herd, scripts/ci, pysrc, bin/herd) in this tree"
    return 2
  fi


  # The FIXTURE surface is scanned too — classified and counted, never flagged — so the sim-vs-
  # production distinction is an asserted property rather than an artifact of a non-recursive glob.
  for _gs_f in "$_gs_root"/scripts/herd/sim/*.sh "$_gs_root"/scripts/herd/experiment/*.sh \
               "$_gs_root"/tests/*.sh; do
    [ -f "$_gs_f" ] && _gs_fx+=("$_gs_f")
  done
  [ "${#_gs_fx[@]}" -gt 0 ] && _gs_files+=("${_gs_fx[@]}")

  _gs_out="$(herd_git_scope_check "${_gs_files[@]}")"; _gs_rc=$?
  printf '%s\n' "$_gs_out"
  return "$_gs_rc"
}
