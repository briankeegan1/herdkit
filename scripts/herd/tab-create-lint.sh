#!/usr/bin/env bash
# tab-create-lint.sh — THE shared TAB-DISCIPLINE CREATION guard (HERD-569): engine code may open a
# workspace TAB only from the modules the tab-discipline invariant allows.
#
# THE PROPERTY BEING ENFORCED
# ---------------------------
# Operator directive, 2026-08-05, verbatim: "there shouldn't be ANY other tabs spawned other than
# builders, or the scribe". The workspace tab bar is the operator's SITUATIONAL-AWARENESS surface —
# one glance has to answer "what is the herd doing right now?" — so a tab that is neither a builder,
# the scribe, nor the control room is not a feature, it is noise that costs the operator a re-read.
# The invariant went wrong the ordinary way: no single change decided to spam the tab bar, but each
# new lane that wanted a view of its own reached for the cheapest primitive there is (open a tab) and
# nothing stopped the next one. That is the same EMERGENT-not-ENFORCED shape git-scope-lint.sh was
# written for, and it gets the same treatment — a lint that makes the property mechanical.
#
# The RECONCILED SWEEP (scripts/herd/tab-discipline.sh) is the runtime half: it retires whatever
# strays actually appear, no matter which seat or which build created them. This lint is the
# BUILD-TIME half, and the two are deliberately independent — the sweep cannot tell a stray tab from
# a deliberate one, and a lint cannot see a tab another seat's older build opened. Together they are
# the invariance-first pair docs/multi-seat-doctrine.md asks for: one shared check at every surface.
#
# WHAT IS A VIOLATION
#   A `herdr … tab create` invocation, or a call to the driver's `herd_driver_create_tab` seam, on a
#   non-comment line of a PRODUCTION engine file that is not one of the ALLOWED MODULES below and not
#   covered by a `callsite` row in the exemption table.
#
# THE ALLOWED MODULES — the three roles the invariant names, and nothing else
#   builder lane   scripts/herd/driver.sh (the one spawn seam every builder lane funnels through),
#                  scripts/herd/herd-feature.sh, scripts/herd/herd-quick.sh
#   scribe         scripts/herd/scribe.sh
#   control room   scripts/herd/coordinator.sh, bin/herd (the `herd reload` control-room rebuild)
#   These are matched by PATH, not by intent: a module earns its exemption by being the one that owns
#   an allowed tab's lifecycle, so moving a tab-create into one of them is a visible, reviewable act.
#
# THE EXEMPTION TABLE:  templates/tab-discipline-exempt.tsv,  `callsite<TAB><path><TAB><reason>`
# A row is a DECISION on the record, so — exactly as tests/lever-reachability-exempt.tsv does — the
# reason is MANDATORY (a bare row reds as EXEMPT-MALFORMED rather than silently laundering a finding)
# and a row that no longer excuses anything reds as STALE-EXEMPT (an exemption list that outlives what
# it excused is how a ratchet quietly stops ratcheting). The file also carries the BASELINE: the lanes
# that were already creating tabs the day this guard landed, each with the conversion it is waiting
# on. That is what lets the guard ship GREEN and work as a NO-NEW-TAB-CREATE ratchet from day one.
# Rows are FILE-scoped on purpose: line numbers churn under every edit above them, and a per-line
# baseline would go stale on contact. The cost is that a SECOND tab-create added to an
# already-exempted file does not red — which is why every baseline row names the conversion that
# retires it, rather than reading as a permanent licence.
#
# SIM FIXTURES ARE EXEMPT, BY CLASSIFICATION NOT BY ACCIDENT
# scripts/herd/sim/, scripts/herd/experiment/ and tests/ stand up REAL tabs in DISPOSABLE workspaces
# (sandbox-real-panes-scenario.sh is the whole point of the P2b tier) and must keep doing so. Those
# paths are SCANNED and then classified FIXTURE, so the advisory reports how many were skipped and the
# distinction is itself testable — rather than falling out of a glob that happens not to recurse.
#
# ONE implementation, sourced (never executed) by BOTH gate surfaces so they can never disagree:
#     • scripts/herd/healthcheck.sh   — the builder's LIGHT pre-PR gate (caught before `gh pr create`)
#     • .herd/healthcheck.project.sh  — the heavy/merge gate (authoritative)
# Sourced-library precedent: caps-sync-lint.sh / gate-coverage-lint.sh / git-scope-lint.sh.
#
# Two functions:
#
# herd_tab_create_check <file>...
#   Pure form used by hermetic fixtures. Prints one 'TAB-CREATE <file>:<lineno>: <class>: <code>' line
#   per offending line on stdout, then an ADVISORY summary. Exit: 0 = clean · 1 = hit(s) on stdout.
#   Classification is by PATH, so a fixture/allowed file passed here is skipped exactly as the scan
#   would skip it. Honors $HERD_TAB_CREATE_EXEMPT_FILE when set (empty ⇒ no exemptions).
#
# herd_tab_create_lint [<root>]
#   Entrypoint for the gate surfaces. Scans the engine surface under <root> (or cwd): bin/herd,
#   herd.sh, install.sh, scripts/herd/*.sh, scripts/herd/backends/*.sh, scripts/herd/work-units/*.sh,
#   scripts/ci/*.sh, migrations/*.sh, pysrc/herd/*.py — plus the fixture surface
#   (scripts/herd/sim/*.sh, scripts/herd/experiment/*.sh, tests/*.sh) which is classified, never
#   flagged. Also validates the exemption table itself (EXEMPT-MALFORMED / STALE-EXEMPT).
#   Exit: 0 = clean · 1 = hit(s) · 2 = skipped (infra; NEVER a red).
#   On a skip, $HERD_TAB_CREATE_SKIP_REASON carries the one-line why.
#
# Fail-soft by construction: the scan runs ONLY in a herdkit ENGINE tree (one of scripts/herd/,
# pysrc/herd/ or bin/herd present). Every consuming project skips before a file is read — a consumer
# owns its own scripts and may open whatever tabs it likes; this guard is about herdkit's own engine
# surface, and must never red someone else's repo.

HERD_TAB_CREATE_SKIP_REASON=""
HERD_TAB_CREATE_EXEMPT_FILE="${HERD_TAB_CREATE_EXEMPT_FILE:-}"

# Lines are NORMALIZED before matching: quotes and commas become spaces. That makes ONE token grammar
# cover both the shell form (`herdr tab create --label x`) and a python argv form
# (`["herdr", "tab", "create", …]`), so the guard covers a python call site too.
#
# The CLI form: `herdr [--flag …] tab create`. Requiring the subcommand to follow `herdr` (past any
# leading flags) is what keeps English prose out — herd-preflight.sh's help text says "herdr is the
# terminal/agent multiplexer that lanes drive (tab create, …)", and the token after `herdr` there is
# `is`, so it is not a call. The trailing class accepts a command TERMINATOR as well as whitespace/EOL.
HERD_TAB_CREATE_RE='herdr[[:space:]]+(-[^[:space:]]+[[:space:]]+)*tab[[:space:]]+create([[:space:]]|[;&|)]|$)'
# The DRIVER SEAM form: the driver's create-tab wrapper is the runtime-agnostic front for the same
# primitive, so a call to it is a tab create by another name. Its own definition line (and the
# `create-tab)` dispatch arm beside it) live in driver.sh, an allowed module, so they never reach here.
# ASSEMBLED FROM TWO HALVES so this line does not match its own grammar — the guard must be clean on
# the tree it guards, without needing an opt-out (the same trick git-scope-lint.sh plays with its class
# strings). Normalization maps the quotes to spaces, so the seam name never appears whole here.
HERD_TAB_CREATE_SEAM_RE='herd_driver'"_create_tab"

# _tc_is_fixture <path> — true for a sim/experiment/test file: a REAL tab in a DISPOSABLE workspace is
# the correct thing there (the P2b real-panes tier exists to prove the pane surface), and it must stay
# clean without an opt-out.
_tc_is_fixture() {
  case "$1" in
    */scripts/herd/sim/*|scripts/herd/sim/*) return 0 ;;
    */scripts/herd/experiment/*|scripts/herd/experiment/*) return 0 ;;
    */tests/*|tests/*) return 0 ;;
  esac
  return 1
}

# _tc_is_allowed_module <path> — true for the builder-lane / scribe / control-room modules that OWN an
# allowed tab's lifecycle. Suffix-matched so an absolute fixture path classifies exactly as the
# repo-relative scan path does.
_tc_is_allowed_module() {
  case "$1" in
    */scripts/herd/driver.sh|scripts/herd/driver.sh)             return 0 ;;  # builder lane (the one spawn seam)
    */scripts/herd/herd-feature.sh|scripts/herd/herd-feature.sh) return 0 ;;  # builder lane
    */scripts/herd/herd-quick.sh|scripts/herd/herd-quick.sh)     return 0 ;;  # builder lane
    */scripts/herd/scribe.sh|scripts/herd/scribe.sh)             return 0 ;;  # the scribe drainer
    */scripts/herd/coordinator.sh|scripts/herd/coordinator.sh)   return 0 ;;  # the control room
    */bin/herd|bin/herd)                                         return 0 ;;  # `herd reload` control-room rebuild
  esac
  return 1
}

# _tc_exempt_rows [<exempt-file>] — print the `callsite` rows of the exemption table as
# '<path><TAB><reason>' (reason may be empty — the caller decides that is EXEMPT-MALFORMED). Comment,
# blank and header rows are dropped, as are rows of another kind (the same table carries the sweep's
# `label` allowlist). Fail-soft: a missing/unreadable file yields nothing.
_tc_exempt_rows() {
  local _tc_file="${1:-$HERD_TAB_CREATE_EXEMPT_FILE}"
  [ -n "$_tc_file" ] && [ -f "$_tc_file" ] || return 0
  local _tc_kind _tc_pat _tc_reason
  while IFS=$'\t' read -r _tc_kind _tc_pat _tc_reason; do
    case "$_tc_kind" in ''|'#'*|kind) continue ;; callsite) ;; *) continue ;; esac
    [ -n "$_tc_pat" ] || continue
    printf '%s\t%s\n' "$_tc_pat" "$_tc_reason"
  done < "$_tc_file"
}

# herd_tab_create_check <file>... — pure function; prints TAB-CREATE lines + ADVISORY. Exit 0/1.
herd_tab_create_check() {
  local _tc_hits="" _tc_total=0 _tc_exempted=0 _tc_fixture=0 _tc_allowed=0
  local _tc_f _tc_cands _tc_num _tc_code _tc_trim _tc_norm _tc_class _tc_pat _tc_reason _tc_ok
  local -a _tc_arr

  # Read the exemption rows ONCE (a file read per scanned file would be the same table, 40 times over).
  local _tc_exempts; _tc_exempts="$(_tc_exempt_rows)"

  for _tc_f in "$@"; do
    [ -f "$_tc_f" ] || continue
    if _tc_is_fixture "$_tc_f"; then _tc_fixture=$((_tc_fixture + 1)); continue; fi
    if _tc_is_allowed_module "$_tc_f"; then _tc_allowed=$((_tc_allowed + 1)); continue; fi

    # Candidate lines. The file is normalized THROUGH `tr` first — the same quote/comma → space
    # mapping applied per line below — so a python argv form is a candidate exactly as the shell form
    # is. `grep -n` reads its whole input (no early exit, so no EPIPE — HERD-297) and the line numbers
    # are unchanged by a 1:1 character map. `|| true`: grep exits 1 on no-match. Skip the (usual)
    # clean file before paying to slurp it into an array.
    _tc_cands="$(tr '\042\047,' '   ' < "$_tc_f" 2>/dev/null \
      | grep -nE "$HERD_TAB_CREATE_RE|$HERD_TAB_CREATE_SEAM_RE" || true)"
    [ -n "$_tc_cands" ] || continue

    # Slurp into a 1-indexed array (bash 3.2 has no mapfile) so a hit can report its ORIGINAL line.
    # The `|| [ -n "$_tc_ln" ]` keeps a final newline-less line.
    _tc_arr=(); local _tc_n=0 _tc_ln
    while IFS= read -r _tc_ln || [ -n "$_tc_ln" ]; do
      _tc_n=$((_tc_n + 1)); _tc_arr[_tc_n]="$_tc_ln"
    done < "$_tc_f"

    while IFS= read -r _tc_num; do
      [ -n "$_tc_num" ] || continue
      _tc_num="${_tc_num%%:*}"                     # leading 'LINENO:' from grep -n
      _tc_code="${_tc_arr[_tc_num]}"
      # A pure-comment line only documents the pattern (this header, the sibling guards' notes, the
      # driver seam's own docstring).
      _tc_trim="${_tc_code#"${_tc_code%%[![:space:]]*}"}"
      case "$_tc_trim" in '#'*) continue ;; esac

      _tc_norm="${_tc_code//[\"\',]/ }"
      _tc_class=""
      if printf '%s' "$_tc_norm" | grep -qE "$HERD_TAB_CREATE_RE"; then           # pipe-ok: one normalized line, far under a pipe buffer
        # The class string deliberately splits the two tokens so this file never matches its own
        # grammar — the guard must be clean on the tree it guards, without needing an opt-out.
        _tc_class="TAB opened outside the builder-lane/scribe/control-room modules"
      elif printf '%s' "$_tc_norm" | grep -qE "$HERD_TAB_CREATE_SEAM_RE"; then    # pipe-ok: one normalized line, far under a pipe buffer
        _tc_class="driver tab-create SEAM called outside the builder-lane/scribe/control-room modules"
      fi
      [ -n "$_tc_class" ] || continue

      # Exempted? A `callsite` row whose path suffix-matches this file excuses every hit in it.
      _tc_ok=0
      while IFS=$'\t' read -r _tc_pat _tc_reason; do
        [ -n "$_tc_pat" ] || continue
        case "$_tc_f" in
          */"$_tc_pat"|"$_tc_pat")
            [ -n "$_tc_reason" ] && _tc_ok=1
            break ;;
        esac
      done <<EOF
$_tc_exempts
EOF
      if [ "$_tc_ok" -eq 1 ]; then _tc_exempted=$((_tc_exempted + 1)); continue; fi

      _tc_total=$((_tc_total + 1))
      _tc_hits="${_tc_hits}TAB-CREATE ${_tc_f}:${_tc_num}: ${_tc_class}: ${_tc_trim}"$'\n'
    done < <(printf '%s\n' "$_tc_cands")
  done

  printf '%s' "$_tc_hits"
  printf 'ADVISORY: %d out-of-module tab create(s); %d excused by templates/tab-discipline-exempt.tsv; %d allowed-module file(s); %d fixture file(s) skipped (clean when 0 out-of-module)\n' \
    "$_tc_total" "$_tc_exempted" "$_tc_allowed" "$_tc_fixture"
  [ -z "$_tc_hits" ]
}

# herd_tab_create_lint [<root>] — scan the engine surface under <root> (or cwd). Exit 0/1/2.
herd_tab_create_lint() {
  local _tc_root="${1:-.}" _tc_files=() _tc_fx=() _tc_f _tc_out _tc_rc=0 _tc_bad=""

  HERD_TAB_CREATE_SKIP_REASON=""

  # ENGINE-TREE MARKER FIRST. This guard is about herdkit's OWN engine surface, so it must never reach
  # into a CONSUMING project's code: a consumer owns its scripts and may open whatever tabs it likes,
  # and reding those would be a false red in someone else's repo. scripts/herd/, pysrc/herd/ and
  # bin/herd exist only in the engine checkout (a consumer runs the CLI from $HERDKIT_HOME), so
  # requiring one of them is the precise test for "this IS the engine tree" — and every consuming
  # project skips before a single file is read.
  if [ ! -d "$_tc_root/scripts/herd" ] && [ ! -d "$_tc_root/pysrc/herd" ] && [ ! -f "$_tc_root/bin/herd" ]; then
    HERD_TAB_CREATE_SKIP_REASON="not a herdkit engine tree (no scripts/herd, pysrc/herd, or bin/herd)"
    return 2
  fi

  # An unmatched glob expands to the literal pattern; the `[ -f ]` guard drops it (no nullglob needed,
  # bash 3.2-safe).
  for _tc_f in "$_tc_root"/scripts/herd/*.sh "$_tc_root"/scripts/herd/backends/*.sh \
               "$_tc_root"/scripts/herd/work-units/*.sh "$_tc_root"/scripts/ci/*.sh \
               "$_tc_root"/migrations/*.sh "$_tc_root"/pysrc/herd/*.py; do
    [ -f "$_tc_f" ] && _tc_files+=("$_tc_f")
  done
  for _tc_f in "$_tc_root/bin/herd" "$_tc_root/herd.sh" "$_tc_root/install.sh"; do
    [ -f "$_tc_f" ] && _tc_files+=("$_tc_f")
  done

  if [ "${#_tc_files[@]}" -eq 0 ]; then
    HERD_TAB_CREATE_SKIP_REASON="no engine tab surface (scripts/herd, scripts/ci, pysrc, bin/herd) in this tree"
    return 2
  fi

  # The FIXTURE surface is scanned too — classified and counted, never flagged — so the sim-vs-
  # production distinction is an asserted property rather than an artifact of a non-recursive glob.
  for _tc_f in "$_tc_root"/scripts/herd/sim/*.sh "$_tc_root"/scripts/herd/experiment/*.sh \
               "$_tc_root"/tests/*.sh; do
    [ -f "$_tc_f" ] && _tc_fx+=("$_tc_f")
  done
  [ "${#_tc_fx[@]}" -gt 0 ] && _tc_files+=("${_tc_fx[@]}")

  HERD_TAB_CREATE_EXEMPT_FILE="$_tc_root/templates/tab-discipline-exempt.tsv"

  _tc_out="$(herd_tab_create_check "${_tc_files[@]}")" || _tc_rc=1

  # The exemption table is itself part of the ratchet: a row with NO reason would silently launder a
  # finding, and a row that excuses nothing is debt pretending to be a decision. Staleness is decided
  # by RE-SCANNING the named file with exemptions OFF — a direct question ("would this row's file red
  # without it?") rather than a flag threaded out of the scan above, which runs in a command
  # substitution and could not carry state back anyway.
  local _tc_kind _tc_pat _tc_reason _tc_save="$HERD_TAB_CREATE_EXEMPT_FILE"
  if [ -f "$_tc_save" ]; then
    while IFS=$'\t' read -r _tc_kind _tc_pat _tc_reason; do
      case "$_tc_kind" in ''|'#'*|kind) continue ;; callsite) ;; *) continue ;; esac
      [ -n "$_tc_pat" ] || continue
      if [ -z "$_tc_reason" ]; then
        _tc_bad="${_tc_bad}EXEMPT-MALFORMED ${_tc_pat}: a callsite row needs a reason (why this module opens a tab, and what conversion retires the row)"$'\n'
        continue
      fi
      HERD_TAB_CREATE_EXEMPT_FILE=""
      if herd_tab_create_check "$_tc_root/$_tc_pat" >/dev/null 2>&1; then
        _tc_bad="${_tc_bad}STALE-EXEMPT ${_tc_pat}: excuses nothing on this tree (no out-of-module tab create there) — drop the row"$'\n'
      fi
      HERD_TAB_CREATE_EXEMPT_FILE="$_tc_save"
    done < "$_tc_save"
  fi

  printf '%s' "$_tc_bad"
  printf '%s\n' "$_tc_out"
  [ -z "$_tc_bad" ] || _tc_rc=1
  return "$_tc_rc"
}
