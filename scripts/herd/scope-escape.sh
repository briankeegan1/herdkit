#!/usr/bin/env bash
# scope-escape.sh — HERD-575 SCOPING-ESCAPE TELEMETRY: the shared detector both sides of a diff-scoped
# gate (HERD-532) source, so they can never disagree about what "this sha ran scoped" means or how a
# downstream escape is proven:
#     • .herd/healthcheck.project.sh — persists that a sha's gate ran a NARROWED selection
#       (herd_scope_gate_record), right where it already computes that selection.
#     • scripts/herd/agent-watch.sh  — the main-health/CI red chokepoint (_main_health_set_red) asks
#       herd_scope_gate_was_scoped, then herd_scope_escape_check, to prove whether a red surfacing on
#       an already-scoped sha is a MISS the scoped selection could never have caught.
#
# WHY A RECOMPUTE, NOT A REPLAY: herd_scope_escape_check never reads back the ORIGINAL selection a
# gate ran — it recomputes fresh, against scripts/herd/suite-shard.sh's CURRENT rules, from the SAME
# changed paths. A rule change (a new `# suite-deps:` header, a widened WIDE-BLAST list) between the
# scoped run and the later red is re-proven, not assumed; an escape can never be reported against a
# mapping that has since been fixed.
#
# OBSERVABILITY ONLY — ZERO GATING CHANGE. Nothing here alters a verdict, blocks a merge, or reds a
# gate on its own; every function fails SOFT (a missing journal, python3, or diff all read as "cannot
# prove an escape", never "assume one"). SHIP-DORMANT BY CONSTRUCTION: herd_scope_gate_was_scoped can
# only ever find a record when HEALTH_SUITE_SCOPE=diff actually narrowed a gate (HERD-532's own
# default-off lever) — with scoping off (the shipped default), no sha is ever recorded scoped, so
# herd_scope_escape_check is always a silent no-op and the main-health red leg's journal line stays
# byte-identical to before this file existed.
#
# herd_scope_gate_record <sha> <selected-tests-newline-list> <curated-tests-newline-list>
#   Journal ONE `gate_scoped` event: sha, the selected count, the curated (total) count, and the
#   selected test basenames (space-joined) — the durable proof a later red needs. Call only when the
#   selection actually narrowed (the caller already knows this from suite-shard.sh's own contract).
#   Fail-soft: no journal_append in scope → silent no-op.
#
# herd_scope_gate_was_scoped <sha>
#   True (rc 0) iff a `gate_scoped` event naming <sha> exists in the resolved journal (the live file
#   only — a rotated archive is not consulted; a sha this old is past any main-health recheck window
#   anyway). Fail-soft: no journal / no python3 / unreadable file all read as "not scoped" (rc 1) — a
#   lookup failure must never itself manufacture a false escape claim.
#
# herd_scope_escape_check <sha> <failing-identity> <tests_dir> <changed-path>...
#   No-op (rc 1, nothing journaled) unless herd_scope_gate_was_scoped <sha>. Otherwise extracts every
#   `test-*.sh`-shaped token out of <failing-identity> (the same shape scripts/herd/agent-watch.sh's
#   own _health_fail_identity distils failing bats tests to); if it names none, this cannot prove
#   which test failed — rc 1, nothing journaled. Otherwise RECOMPUTES the scoped selection
#   (herd_suite_tests_for_diff over <tests_dir> + the given changed paths) and checks whether any
#   failing token is ABSENT from it. Present → scoping would have caught this failure (some other
#   transient, not a scoping defect) — rc 1, nothing journaled. A recompute that comes back as the
#   FULL curated set proves nothing either (the current rules would run everything) — rc 1. Only when
#   a failing token is missing from a genuinely NARROWED recompute does this journal `scope_escape`
#   (sha, the missed token(s), the recomputed selection's size/tests) and print ONE tab-separated
#   candidate row — "<missed-tests>\t<changed-paths;joined>\t<sha>" — on stdout for the caller to
#   append to the committed suite-deps candidate ledger. This function never touches the filesystem
#   beyond the journal, so it stays testable without a real git checkout to commit into.
#
# herd_scope_escape_append_candidate <candidate-file> <row>
#   Append <row> to <candidate-file> unless it is already the last thing recorded there for that exact
#   row (idempotent — a re-verified escape must never grow duplicate rows). No-op when <candidate-file>
#   does not already exist — never materializes a new one (mirrors refresh_codemap's "already adopted"
#   guard, docs/codemap.md).

herd_scope_gate_record() {
  local _sgr_sha="${1:-}" _sgr_sel="${2:-}" _sgr_curated="${3:-}"
  [ -n "$_sgr_sha" ] || return 0
  command -v journal_append >/dev/null 2>&1 || return 0
  local _sgr_n _sgr_total _sgr_joined
  _sgr_n="$(printf '%s\n' "$_sgr_sel" | grep -c .)"
  _sgr_total="$(printf '%s\n' "$_sgr_curated" | grep -c .)"
  _sgr_joined="$(printf '%s' "$_sgr_sel" | tr '\n' ' ')"
  journal_append gate_scoped sha "$_sgr_sha" selected "$_sgr_n" total "$_sgr_total" tests "$_sgr_joined"
  return 0
}

herd_scope_gate_was_scoped() {
  local _sgw_sha="${1:-}" _sgw_jf
  [ -n "$_sgw_sha" ] || return 1
  command -v _journal_file >/dev/null 2>&1 || return 1
  _sgw_jf="$(_journal_file 2>/dev/null)" || return 1
  [ -n "$_sgw_jf" ] && [ -f "$_sgw_jf" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  # Cheap text pre-filter before paying for python3 + real JSON parsing on a large journal.
  grep -qF "\"sha\":\"$_sgw_sha\"" "$_sgw_jf" 2>/dev/null || return 1
  HERD_SE_SHA="$_sgw_sha" python3 -c '
import sys, json, os
sha = os.environ.get("HERD_SE_SHA", "")
try:
    f = open(sys.argv[1], encoding="utf-8")
except OSError:
    sys.exit(1)
with f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("event") == "gate_scoped" and str(o.get("sha", "")) == sha:
            sys.exit(0)
sys.exit(1)
' "$_sgw_jf" 2>/dev/null
}

herd_scope_escape_check() {
  local _sec_sha="${1:-}" _sec_failed="${2:-}" _sec_tests_dir="${3:-}"
  shift 3 2>/dev/null || return 1
  [ -n "$_sec_sha" ] && [ -n "$_sec_tests_dir" ] || return 1
  herd_scope_gate_was_scoped "$_sec_sha" || return 1
  [ "$#" -gt 0 ] || return 1
  command -v herd_suite_tests_for_diff >/dev/null 2>&1 || return 1
  command -v herd_suite_curated_tests >/dev/null 2>&1 || return 1

  local _sec_tokens
  _sec_tokens="$(printf '%s\n' "$_sec_failed" | grep -oE 'test-[A-Za-z0-9_.-]+\.sh' 2>/dev/null | awk '!seen[$0]++')"
  [ -n "$_sec_tokens" ] || return 1   # the failing identity names no test-*.sh — cannot prove a miss

  local _sec_sel _sec_curated
  _sec_sel="$(herd_suite_tests_for_diff "$_sec_tests_dir" "$@")"
  _sec_curated="$(herd_suite_curated_tests "$_sec_tests_dir")"
  # A recompute that comes back as the whole curated set proves nothing — under the CURRENT rules the
  # original scoped run would have run everything too, so a red here can never be a scoping miss.
  [ -n "$_sec_sel" ] && [ "$_sec_sel" != "$_sec_curated" ] || return 1

  local _sec_tok _sec_missed=""
  while IFS= read -r _sec_tok; do
    [ -n "$_sec_tok" ] || continue
    grep -qxF -- "$_sec_tok" <<< "$_sec_sel" || _sec_missed="${_sec_missed}${_sec_tok},"
  done <<< "$_sec_tokens"
  _sec_missed="${_sec_missed%,}"
  [ -n "$_sec_missed" ] || return 1   # every failing token was already in the recomputed selection

  local _sec_sel_n _sec_curated_n _sec_paths="" _sec_p
  _sec_sel_n="$(printf '%s\n' "$_sec_sel" | grep -c .)"
  _sec_curated_n="$(printf '%s\n' "$_sec_curated" | grep -c .)"
  for _sec_p in "$@"; do _sec_paths="${_sec_paths}${_sec_p};"; done
  _sec_paths="${_sec_paths%;}"

  if command -v journal_append >/dev/null 2>&1; then
    journal_append scope_escape sha "$_sec_sha" failed "$_sec_missed" \
      selected "$_sec_sel_n" total "$_sec_curated_n" \
      tests "$(printf '%s' "$_sec_sel" | tr '\n' ' ')"
  fi

  printf '%s\t%s\t%s\n' "$_sec_missed" "$_sec_paths" "$_sec_sha"
  return 0
}

herd_scope_escape_append_candidate() {
  local _sac_file="${1:-}" _sac_row="${2:-}"
  [ -n "$_sac_file" ] && [ -n "$_sac_row" ] || return 0
  [ -f "$_sac_file" ] || return 0                              # never materialize a new ledger
  grep -qxF -- "$_sac_row" "$_sac_file" 2>/dev/null && return 0  # idempotent — never dup a row
  printf '%s\n' "$_sac_row" >> "$_sac_file" 2>/dev/null || true
  return 0
}
