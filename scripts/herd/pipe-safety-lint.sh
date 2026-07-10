#!/usr/bin/env bash
# pipe-safety-lint.sh — THE shared pipe-safety guard (HERD-299): a NEW '<producer> | grep -q'
# (or '| grep -m', '| head') is a latent false-red under `set -o pipefail`.
#
# The bug (proven live, PR #412 / HERD-297): grep -q / grep -m / head STOP reading as soon as they
# have what they need (grep -q exits on the first match, grep -m after N matches, head after N
# lines/bytes). Their producer keeps writing; once the producer's output exceeds the platform pipe
# buffer (macOS 16KB vs Linux 64KB) it is still mid-write when the consumer closes the pipe, takes
# EPIPE, and exits nonzero. Under a caller's `set -o pipefail` the whole pipeline then goes nonzero —
# so a producer whose output merely GREW past a pipe buffer silently flips a pipeline's status. This
# is exactly how gate-coverage-lint.sh misreported wired tests as UNGATED and turned macOS CI
# chronically red once tests/herd.bats crossed 16KB. #412 SWEPT the existing shared-lint instances
# (grep files/here-strings directly, never pipe a producer into grep -q); this lint is the GUARD that
# stops a new one from landing.
#
# The safe forms — neither has a producer process, so neither can EPIPE — are NOT flagged:
#     grep -q PATTERN FILE          # grep reads the file directly (no pipe)
#     grep -q PATTERN <<< "$var"    # here-string is a temp file (no pipe)
# The unsafe form is a literal pipe into the early-exit consumer:  <producer> | grep -q / -m / head.
#
# Opt-out: a verified-small / status-not-gated producer may carry an inline  # pipe-ok: <why>
# annotation. It suppresses the offending line when it appears ON that line OR anywhere within the
# same `\`-continued logical command (so a multi-line pipeline can carry ONE annotation on whichever
# physical line has room, since a line ending in `\` cannot hold a trailing comment). Pure-comment
# lines (a `#`-led line that merely documents the pattern, as this header does) are never flagged.
#
# ONE implementation, sourced (never executed) by BOTH gate surfaces so they can never disagree:
#     • scripts/herd/healthcheck.sh   — the builder's LIGHT pre-PR gate (caught before `gh pr create`)
#     • .herd/healthcheck.project.sh  — the heavy/merge gate (authoritative)
# Sourced-library precedent: caps-sync-lint.sh / gate-coverage-lint.sh.
#
# Two functions:
#
# herd_pipe_safety_check <file>...
#   Pure form used by hermetic fixtures. Prints one 'PIPE-UNSAFE <file>:<lineno>: <code>' line per
#   offending line on stdout, then an ADVISORY summary. Exit: 0 = clean · 1 = hit(s) on stdout.
#   Each argument is read as a FILE with `grep -n` (no producer pipe → the detector is itself
#   pipefail-safe, the very property it enforces).
#
# herd_pipe_safety_lint [<root>]
#   Entrypoint for the gate surfaces. Scans scripts/herd/*.sh + scripts/ci/*.sh + bin/herd under
#   <root> (or cwd). Exit: 0 = clean · 1 = hit(s) · 2 = skipped (infra; NEVER a red).
#   On a skip, $HERD_PIPE_SAFETY_SKIP_REASON carries the one-line why.
#
# Fail-soft by construction: a tree with none of the scan surface (every consuming project — this is
# herdkit's own engine surface) skips, never a false red.

HERD_PIPE_SAFETY_SKIP_REASON=""

# The anti-pattern regex — a pipe into a producer-terminating consumer:
#   • grep with an early-exit option (-q quiet / -m max-count) as the FIRST token after grep, so a
#     `q`/`m` buried inside a later quoted pattern (e.g. `grep -v 'a-quux'`) never false-reds.
#   • head — stops after N lines/bytes.
# `-[[:alnum:]]*[qm]` matches -q, -qE, -qxF, -qiE, -Eq, -Eiq, -m, -m1, … (option cluster ending in q/m).
HERD_PIPE_SAFETY_RE='\|[[:space:]]*(grep[[:space:]]+-[[:alnum:]]*[qm]|head\b)'  # pipe-ok: the detector's own pattern literal, not a pipeline

# herd_pipe_safety_check <file>... — pure function; prints PIPE-UNSAFE lines + ADVISORY. Exit 0/1.
herd_pipe_safety_check() {
  local _ps_hits="" _ps_total=0 _ps_annot=0 _ps_f _ps_cands _ps_num _ps_code _ps_trim
  local _ps_n _ps_ln _ps_start _ps_end _ps_prev _ps_j _ps_ok
  local -a _ps_arr
  for _ps_f in "$@"; do
    [ -f "$_ps_f" ] || continue
    # Find candidate lines by grepping the FILE directly (no producer pipe — the detector must never
    # do the very thing it forbids). `|| true`: grep exits 1 on no-match. Skip the (usual) clean file
    # before paying to slurp it into an array.
    _ps_cands="$(grep -nE "$HERD_PIPE_SAFETY_RE" "$_ps_f" 2>/dev/null || true)"
    [ -n "$_ps_cands" ] || continue

    # Slurp the file into a 1-indexed array (bash 3.2 has no mapfile) so we can inspect the whole
    # `\`-continued command around each candidate. The `|| [ -n "$_ps_ln" ]` keeps a final
    # newline-less line.
    _ps_arr=(); _ps_n=0
    while IFS= read -r _ps_ln || [ -n "$_ps_ln" ]; do
      _ps_n=$((_ps_n + 1)); _ps_arr[_ps_n]="$_ps_ln"
    done < "$_ps_f"

    while IFS= read -r _ps_num; do
      [ -n "$_ps_num" ] || continue
      _ps_num="${_ps_num%%:*}"           # leading 'LINENO:' from grep -n
      _ps_code="${_ps_arr[_ps_num]}"
      # Skip a pure-comment line: after trimming leading whitespace the first char is '#'. Such a line
      # only documents the pattern (this header, the sibling lints' EPIPE notes) — never live code.
      _ps_trim="${_ps_code#"${_ps_code%%[![:space:]]*}"}"
      case "$_ps_trim" in '#'*) continue ;; esac

      # Determine the `\`-continued logical command this line belongs to: walk up while the previous
      # physical line ends in a backslash, then down while the current one does. A `# pipe-ok` on ANY
      # line of that block opts the whole command out (a line ending in `\` cannot hold a comment).
      _ps_start="$_ps_num"
      while [ "$_ps_start" -gt 1 ]; do
        _ps_prev=$((_ps_start - 1))
        case "${_ps_arr[_ps_prev]}" in *\\) _ps_start="$_ps_prev" ;; *) break ;; esac
      done
      _ps_end="$_ps_num"
      while [ -n "${_ps_arr[_ps_end]+x}" ]; do
        case "${_ps_arr[_ps_end]}" in *\\) _ps_end=$((_ps_end + 1)) ;; *) break ;; esac
      done
      _ps_ok=0; _ps_j="$_ps_start"
      while [ "$_ps_j" -le "$_ps_end" ]; do
        case "${_ps_arr[_ps_j]}" in *'# pipe-ok'*) _ps_ok=1; break ;; esac
        _ps_j=$((_ps_j + 1))
      done
      if [ "$_ps_ok" -eq 1 ]; then _ps_annot=$((_ps_annot + 1)); continue; fi

      _ps_total=$((_ps_total + 1))
      _ps_hits="${_ps_hits}PIPE-UNSAFE ${_ps_f}:${_ps_num}: ${_ps_trim}"$'\n'
    done < <(printf '%s\n' "$_ps_cands")
  done

  printf '%s' "$_ps_hits"
  printf 'ADVISORY: %d pipe-unsafe line(s); %d opted-out via # pipe-ok (clean when 0 unsafe)\n' \
    "$_ps_total" "$_ps_annot"
  [ -z "$_ps_hits" ]
}

# herd_pipe_safety_lint [<root>] — scan the default engine surface under <root> (or cwd). Exit 0/1/2.
herd_pipe_safety_lint() {
  local _ps_root="${1:-.}" _ps_files=() _ps_f _ps_out _ps_rc

  HERD_PIPE_SAFETY_SKIP_REASON=""

  # An unmatched glob expands to the literal pattern; the `[ -f ]` guard drops it (no nullglob needed,
  # bash 3.2-safe). scripts/herd/*.sh + scripts/ci/*.sh + bin/herd — whichever exist.
  for _ps_f in "$_ps_root"/scripts/herd/*.sh "$_ps_root"/scripts/ci/*.sh; do
    [ -f "$_ps_f" ] && _ps_files+=("$_ps_f")
  done
  [ -f "$_ps_root/bin/herd" ] && _ps_files+=("$_ps_root/bin/herd")

  if [ "${#_ps_files[@]}" -eq 0 ]; then
    HERD_PIPE_SAFETY_SKIP_REASON="no scripts/herd, scripts/ci, or bin/herd surface in this tree"
    return 2
  fi

  _ps_out="$(herd_pipe_safety_check "${_ps_files[@]}")"; _ps_rc=$?
  printf '%s\n' "$_ps_out"
  return "$_ps_rc"
}
