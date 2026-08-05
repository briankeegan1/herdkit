#!/usr/bin/env bash
# review-pregate.sh — THE shared MECHANICAL-RED PRE-GATE + SMALL-MECHANICAL-DIFF FLOOR (HERD-559).
#
# WHY THIS EXISTS
# ---------------
# Once the healthcheck gate is fast, the ~5 minutes of serial LLM review is what binds every PR. Two
# cheap, deterministic wins sit in front of it, and this file is the ONE implementation of both:
#
#   (1) MECHANICAL-RED PRE-GATE — three mechanical reds shipped review-only in one day (a caps-sync
#       miss, a pipe-safety miss, a doc-drift miss). Each burned a full adversarial review slot to
#       report something a lint answers in seconds. `herd_review_pregate` runs the EXISTING shared
#       lint set against the diff BEFORE a reviewer is ever dispatched, so the LLM review only ever
#       sees mechanically-clean diffs and a mechanical red bounces to the builder immediately.
#   (2) SMALL-MECHANICAL-DIFF FLOOR — `herd_review_mech_floor` recognizes the diff shapes that carry
#       no correctness surface for an adversarial reviewer to find (a TSV-row edit, a pure rename, a
#       version bump) so they route to the CHEAP reviewer tier instead of the strong one.
#
# ONE IMPLEMENTATION, THREE CALL SITES — this file is the chokepoint; nothing re-implements a lint:
#   • scripts/herd/agent-watch.sh   — the bash review dispatch leg (_review_gate_step): red ⇒ no
#                                     reviewer is spawned at all, so no review slot is burned
#   • pysrc/herd/live_runtime.py    — the LIVE engine core's review rail (LiveGates.review): same
#   • scripts/herd/herd-review.sh   — the reviewer's own preamble: defence in depth for a DIRECT
#                                     invocation (a manual `herd-review.sh <pr> <slug>`), where the
#                                     model is still not spawned — the verdict is emitted from here
#
# Every caller invokes this file as a SUBPROCESS (`bash review-pregate.sh lint <tree>`), never by
# sourcing it into a long-lived watcher: the lint bodies are read from the TREE UNDER TEST when it
# carries its own copies (a branch that CHANGES a lint is linted by its own version, exactly as
# healthcheck.sh does), and builder-authored code must never be sourced into the watcher process.
# Sourcing is supported for the hermetic tests, which call the functions directly.
#
# LEVERS (both ship DORMANT — default off; off is a HARD no-op, no lint runs, no journal, no output):
#   REVIEW_PREGATE=off|on          — leg (1), the mechanical-red pre-gate
#   REVIEW_MECH_FLOOR=off|on       — leg (2), the small-mechanical-diff floor
#   REVIEW_MECH_FLOOR_MAXFILES     — floor ceiling on changed files (default 5)
#   REVIEW_MECH_FLOOR_MAXLINES     — floor ceiling on changed lines  (default 40)
#
# CONTRACT
#   herd_review_pregate <tree> [<base-ref>]
#       Runs the cheap deterministic lint set with <tree> as cwd. Prints the findings of EVERY red
#       lint (never stops at the first — one bounce must carry the whole picture).
#       Exit: 0 = clean · 1 = mechanical red (findings on stdout) · 2 = skipped (infra; NEVER a red).
#       On a skip, $HERD_REVIEW_PREGATE_SKIP_REASON carries the one-line why.
#   herd_review_mech_floor <tree> [<base-ref>]
#       Exit: 0 = mechanically-shaped (floor applies, route CHEAP) · 1 = not · 2 = undecidable.
#       $HERD_REVIEW_MECH_FLOOR_REASON carries the one-line why for 0 and 1 alike.
#   CLI: `bash review-pregate.sh lint  <tree> [<base-ref>]`
#        `bash review-pregate.sh floor <tree> [<base-ref>]`   (same exit codes; reason on stderr)
#
# FAIL-SOFT BY CONSTRUCTION, everywhere: a missing lint file, a tree with no engine surface, an
# unresolvable diff, a missing python3 — every one of them SKIPS silently. This gate may only ever
# turn a red that a lint ACTUALLY reported into a red; it must never invent one, because a false
# pre-gate red bounces a builder onto nothing.

set -uo pipefail

HERD_REVIEW_PREGATE_SKIP_REASON=""
HERD_REVIEW_MECH_FLOOR_REASON=""

_PREGATE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ── lever resolvers ───────────────────────────────────────────────────────────────────────────────
# Both are strict on|off with an off-by-default fail-safe: anything that is not exactly `on` is off,
# so a typo'd key can never silently activate a gate that bounces builders.
herd_review_pregate_enabled()    { [ "${REVIEW_PREGATE:-off}" = "on" ]; }
herd_review_mech_floor_enabled() { [ "${REVIEW_MECH_FLOOR:-off}" = "on" ]; }

# _pregate_load_lint <lint-file-basename> <tree> <fallback-fn> — source ONE shared lint, preferring the
# tree-under-test's own copy (a branch that changes the lint is linted by its own version) and falling
# back to this engine's. When neither exists, define <fallback-fn> as a no-op returning 2 (skipped) so
# every call site below stays a straight-line call with no presence check. Mirrors healthcheck.sh's
# own fail-soft loader verbatim — the two must not diverge.
_pregate_load_lint() {
  local _pl_base="$1" _pl_tree="$2" _pl_fn="$3" _pl_src
  _pl_src="$_PREGATE_HERE/$_pl_base"
  [ -f "$_pl_tree/scripts/herd/$_pl_base" ] && _pl_src="$_pl_tree/scripts/herd/$_pl_base"
  if [ -f "$_pl_src" ]; then
    # shellcheck source=/dev/null
    . "$_pl_src" 2>/dev/null && return 0
  fi
  eval "$_pl_fn() { return 2; }"
  return 0
}

# ── leg (1): the mechanical-red pre-gate ─────────────────────────────────────────────────────────
# THE LINT SET, in the order a builder is most likely to have tripped it. Every one of these is an
# EXISTING shared implementation already run by both healthcheck profiles — this adds no new rule,
# it only moves the SAME rules in front of the reviewer:
#   caps-sync          templates/capabilities.tsv not updated alongside a capability-growing change
#   config-manifest    the ghost/dead-key scan over the config manifest (tests/test-config-manifest.sh)
#   journal-emission   a consumer parses an event name no producer emits
#   pipe-safety        a NEW '<producer> | grep -q/-m|head' — EPIPE-unsafe under pipefail
#   git-scope          a production engine path stages repo-wide or commits without a pathspec
#   doc-drift          README/docs/templates reference a command absent from capabilities.tsv
#
# _pregate_run_set <tree> <base-or-empty> — run the whole set with <tree> as cwd and print one
# "<lint>\t<finding>" row per finding line. Runs in a SUBSHELL so the cd and the sourced lint bodies
# (which come from <tree>, i.e. possibly a DIFFERENT revision on each call) can never leak between the
# tree pass and the baseline pass. An EMPTY <base> skips caps-sync, the one lint that reasons about a
# diff rather than the tree — the baseline snapshot has no diff to reason about.
# The LAST row is always the bookkeeping row "#ran<TAB><n>" — how many lints actually EXECUTED (as
# opposed to skipping for a missing file / absent scan surface). It rides stdout with the findings so
# no second channel or temp file is needed, and the caller strips it before comparing finding sets.
_pregate_run_set() {
  (
    local _rs_tree="$1" _rs_base="$2" _rs_ran=0 _rs_errs _rs_rc
    cd "$_rs_tree" 2>/dev/null || { printf '#ran\t0\n'; return 0; }

    _pregate_load_lint caps-sync-lint.sh         "$_rs_tree" herd_caps_sync_lint
    _pregate_load_lint doc-drift-lint.sh         "$_rs_tree" herd_doc_drift_lint
    _pregate_load_lint journal-emission-lint.sh  "$_rs_tree" herd_journal_emission_lint
    _pregate_load_lint pipe-safety-lint.sh       "$_rs_tree" herd_pipe_safety_lint
    _pregate_load_lint git-scope-lint.sh         "$_rs_tree" herd_git_scope_lint

    if [ -n "$_rs_base" ]; then
      _rs_errs="$(herd_caps_sync_lint "$_rs_base" 2>/dev/null)"; _rs_rc=$?
      case "$_rs_rc" in
        0) _rs_ran=$((_rs_ran+1)) ;;
        1) _rs_ran=$((_rs_ran+1)); _pregate_emit caps-sync "$_rs_errs" ;;
      esac
    fi

    # config-manifest ghost/dead-key scan — the manifest's own self-enforcement lint. It ships as a
    # hermetic TEST (tests/test-config-manifest.sh) rather than a sourceable library, so it is invoked
    # as one; only its FAIL lines are findings (its PASS roll-call is not). No reimplementation.
    if [ -f tests/test-config-manifest.sh ] && command -v python3 >/dev/null 2>&1; then
      _rs_ran=$((_rs_ran+1))
      if ! _rs_errs="$(bash tests/test-config-manifest.sh 2>&1)"; then
        _pregate_emit config-manifest "$(grep '^FAIL' <<< "$_rs_errs")"
      fi
    fi

    _rs_errs="$(herd_journal_emission_lint . 2>/dev/null)"; _rs_rc=$?
    case "$_rs_rc" in
      0) _rs_ran=$((_rs_ran+1)) ;;
      1) _rs_ran=$((_rs_ran+1)); _pregate_emit journal-emission "$_rs_errs" ;;
    esac

    _rs_errs="$(herd_pipe_safety_lint . 2>/dev/null)"; _rs_rc=$?
    case "$_rs_rc" in
      0) _rs_ran=$((_rs_ran+1)) ;;
      1) _rs_ran=$((_rs_ran+1)); _pregate_emit pipe-safety "$_rs_errs" ;;
    esac

    _rs_errs="$(herd_git_scope_lint . 2>/dev/null)"; _rs_rc=$?
    case "$_rs_rc" in
      0) _rs_ran=$((_rs_ran+1)) ;;
      1) _rs_ran=$((_rs_ran+1)); _pregate_emit git-scope "$_rs_errs" ;;
    esac

    _rs_errs="$(herd_doc_drift_lint . 2>/dev/null)"; _rs_rc=$?
    case "$_rs_rc" in
      0) _rs_ran=$((_rs_ran+1)) ;;
      1) _rs_ran=$((_rs_ran+1)); _pregate_emit doc-drift "$_rs_errs" ;;
    esac

    printf '#ran\t%s\n' "$_rs_ran"
  )
}

# _pregate_emit <lint> <findings-block> — one tab-separated row per non-empty finding line. The rows
# are what the baseline subtraction compares, so they must be STABLE: no timestamps, no paths outside
# the tree, nothing that differs between two runs of the same code on the same content.
_pregate_emit() {
  local _pe_lint="$1" _pe_line
  while IFS= read -r _pe_line; do
    [ -n "$_pe_line" ] || continue
    printf '%s\t%s\n' "$_pe_lint" "$_pe_line"
  done <<< "$2"
}

# _pregate_headline <lint> — the one-line explanation the builder is bounced with, per lint.
_pregate_headline() {
  case "$1" in
    caps-sync)        printf 'capabilities manifest not updated alongside an engine change' ;;
    config-manifest)  printf 'a config key is a GHOST (read but undeclared) or DEAD (declared but unread) in templates/capabilities.tsv' ;;
    journal-emission) printf 'a consumer parses a journal event name no producer emits' ;;
    pipe-safety)      printf 'a producer piped into an early-exit consumer is EPIPE-unsafe under pipefail' ;;
    git-scope)        printf 'a production engine path stages repo-wide or commits without a pathspec' ;;
    doc-drift)        printf 'README/docs/templates reference a command or key absent from capabilities.tsv' ;;
    *)                printf 'mechanical lint red' ;;
  esac
}

# _pregate_baseline_tree <tree> <base> — materialize the MERGE BASE's content into a temp dir and echo
# its path (empty on any failure). `git archive | tar -x`, NOT `git worktree add`: a temp worktree
# would register in `git worktree list`, which is the very surface the watcher uses to DISCOVER work
# (a transient entry there could be mistaken for a feature worktree). The archive has no .git, so the
# baseline pass sees no diff — which is exactly why _pregate_run_set skips caps-sync for it.
_pregate_baseline_tree() {
  local _bt_tree="$1" _bt_base="$2" _bt_sha _bt_dir
  _bt_sha="$(git -C "$_bt_tree" merge-base "$_bt_base" HEAD 2>/dev/null)" || return 0
  [ -n "$_bt_sha" ] || return 0
  _bt_dir="$(mktemp -d 2>/dev/null)" || return 0
  if git -C "$_bt_tree" archive "$_bt_sha" 2>/dev/null | tar -x -C "$_bt_dir" 2>/dev/null; then  # pipe-ok: tar consumes the WHOLE archive stream; no early exit, no EPIPE
    printf '%s' "$_bt_dir"
    return 0
  fi
  rm -rf "$_bt_dir" 2>/dev/null || true
  return 0
}

# herd_review_pregate <tree> [<base-ref>] — see the CONTRACT block at the top of this file.
#
# BASELINE-SUBTRACTED, and that is the load-bearing half. A tree scan reports every violation PRESENT,
# not every violation this diff INTRODUCED — and the merge gate runs a DIFF-SCOPED suite, so a lint
# red can (and provably does) sit on the default branch unnoticed. Bouncing a builder onto somebody
# else's standing red would be a false red of the worst kind: the builder cannot fix it inside its own
# item, so the PR would wedge. So a red is only ever reported when it is ABSENT at the merge base.
# When the baseline cannot be computed the whole pre-gate SKIPS (rc 2) rather than reporting the
# unsubtracted set — the reviewer then runs exactly as it does today. Fail-soft always beats false-red.
herd_review_pregate() {
  local _pg_tree="${1:-.}" _pg_base="${2:-${DEFAULT_BRANCH:-main}}"
  local _pg_cur _pg_ran _pg_bl_dir _pg_bl _pg_new _pg_lint _pg_line _pg_last="" _pg_out=""

  HERD_REVIEW_PREGATE_SKIP_REASON=""
  if [ ! -d "$_pg_tree" ]; then
    HERD_REVIEW_PREGATE_SKIP_REASON="no such tree: $_pg_tree"
    return 2
  fi

  _pg_cur="$(_pregate_run_set "$_pg_tree" "$_pg_base" 2>/dev/null)"
  _pg_ran="$(sed -n 's/^#ran	//p' <<< "$_pg_cur")"
  case "$_pg_ran" in ''|*[!0-9]*) _pg_ran=0 ;; esac
  _pg_cur="$(grep -v '^#ran	' <<< "$_pg_cur")"

  if [ -z "$_pg_cur" ]; then
    # NOTHING ran (a consuming project: no manifest, no engine scan surface) → SKIP, not clean. The
    # distinction is load-bearing for the caller's journal: "the pre-gate found nothing wrong" and
    # "the pre-gate had nothing to look at" must never read the same.
    if [ "$_pg_ran" -eq 0 ]; then
      HERD_REVIEW_PREGATE_SKIP_REASON="no lintable engine surface in $_pg_tree"
      return 2
    fi
    return 0
  fi

  _pg_bl_dir="$(_pregate_baseline_tree "$_pg_tree" "$_pg_base")"
  if [ -z "$_pg_bl_dir" ] || [ ! -d "$_pg_bl_dir" ]; then
    HERD_REVIEW_PREGATE_SKIP_REASON="could not materialize the merge base against $_pg_base — not attributing a lint red to this diff"
    return 2
  fi
  _pg_bl="$(_pregate_run_set "$_pg_bl_dir" "" 2>/dev/null)"
  _pg_bl="$(grep -v '^#ran	' <<< "$_pg_bl")"
  rm -rf "$_pg_bl_dir" 2>/dev/null || true

  if [ -z "$_pg_bl" ]; then
    _pg_new="$_pg_cur"
  else
    # Exact whole-line set subtraction against a FILE of baseline rows (never `producer | grep`):
    # every row this diff did not introduce is dropped. grep exits 1 when nothing survives — that is
    # the all-pre-existing case, i.e. clean.
    _pg_new="$(grep -Fxv -f <(printf '%s\n' "$_pg_bl") <<< "$_pg_cur")"
  fi
  [ -n "$_pg_new" ] || return 0

  # Format the surviving rows back into per-lint blocks: one headline, then that lint's findings.
  while IFS=$'\t' read -r _pg_lint _pg_line; do
    [ -n "${_pg_lint:-}" ] || continue
    if [ "$_pg_lint" != "$_pg_last" ]; then
      _pg_out="${_pg_out}PREGATE ${_pg_lint}: $(_pregate_headline "$_pg_lint")"$'\n'
      _pg_last="$_pg_lint"
    fi
    _pg_out="${_pg_out}  ${_pg_line}"$'\n'
  done <<< "$_pg_new"
  printf '%s' "$_pg_out"
  return 1
}

# ── leg (2): the small-mechanical-diff floor ─────────────────────────────────────────────────────
# A diff is MECHANICALLY SHAPED when every changed file is one of three shapes an adversarial
# correctness reviewer has no surface to work on:
#   (a) a TSV row edit      — *.tsv (the manifests: capabilities/conformance/models/postures/…)
#   (b) a pure rename       — R100: 100% similarity, i.e. the content did not change at all
#   (c) a version bump      — every removed line pairs with an added line that is IDENTICAL except
#                             for a dotted numeric token (1.2 / 1.2.3): a version, and nothing else
# …AND the diff is small (<= REVIEW_MECH_FLOOR_MAXFILES files, <= REVIEW_MECH_FLOOR_MAXLINES changed
# lines) AND no changed path matches REVIEW_ESCALATE_GLOB.
#
# FAILS SAFE IN ONE DIRECTION ONLY: every uncertainty (no git, unresolvable base, empty diff, a shape
# this cannot prove) returns NOT-mechanical (or undecidable), so the floor can only ever DOWNGRADE a
# diff it has positively recognized. ESCALATION WINS: an operator's REVIEW_ESCALATE_GLOB match refuses
# the floor outright, so pinning a path into that glob is an absolute veto over this classifier.
herd_review_mech_floor() {
  local _mf_tree="${1:-.}" _mf_base="${2:-${DEFAULT_BRANCH:-main}}"
  local _mf_maxf _mf_maxl _mf_ns _mf_n _mf_lines _mf_status _mf_path _mf_newpath

  HERD_REVIEW_MECH_FLOOR_REASON=""
  _mf_maxf="${REVIEW_MECH_FLOOR_MAXFILES:-5}"; case "$_mf_maxf" in ''|*[!0-9]*) _mf_maxf=5 ;; esac
  _mf_maxl="${REVIEW_MECH_FLOOR_MAXLINES:-40}"; case "$_mf_maxl" in ''|*[!0-9]*) _mf_maxl=40 ;; esac

  if ! git -C "$_mf_tree" rev-parse --git-dir >/dev/null 2>&1; then
    HERD_REVIEW_MECH_FLOOR_REASON="not a git tree: $_mf_tree"
    return 2
  fi
  # -M: ask git for rename detection, so a pure rename reaches us as R100 rather than an add+delete
  # pair that no shape rule could ever recognize.
  if ! _mf_ns="$(git -C "$_mf_tree" diff -M --name-status "${_mf_base}...HEAD" 2>/dev/null)"; then
    HERD_REVIEW_MECH_FLOOR_REASON="no resolvable diff against $_mf_base"
    return 2
  fi
  if [ -z "$_mf_ns" ]; then
    HERD_REVIEW_MECH_FLOOR_REASON="empty diff against $_mf_base"
    return 2
  fi

  _mf_n="$(printf '%s\n' "$_mf_ns" | grep -c .)"   # pipe-ok: grep -c consumes ALL input; no early exit, no EPIPE
  if [ "$_mf_n" -gt "$_mf_maxf" ] 2>/dev/null; then
    HERD_REVIEW_MECH_FLOOR_REASON="$_mf_n changed files exceeds the floor's $_mf_maxf"
    return 1
  fi

  # ESCALATION WINS — checked before any shape rule, so an operator glob is an absolute veto. Matched
  # against the PATHS, never the raw --name-status rows: those carry a leading "<status>\t", which
  # would silently break every anchored pattern (a '^templates/' glob can never match "M\ttemplates/…").
  # BOTH sides of a rename are checked — a rename OUT of a pinned path is as much an escalate-glob hit
  # as a rename into one. The -n guard matters: an EMPTY glob would make `grep -qE ""` match every path.
  local _mf_paths
  _mf_paths="$(awk -F'\t' '{ for (i = 2; i <= NF; i++) if ($i != "") print $i }' <<< "$_mf_ns")"
  if [ -n "${REVIEW_ESCALATE_GLOB:-}" ] && grep -qE "${REVIEW_ESCALATE_GLOB}" <<< "$_mf_paths"; then
    HERD_REVIEW_MECH_FLOOR_REASON="a changed path matches REVIEW_ESCALATE_GLOB"
    return 1
  fi

  _mf_lines="$(git -C "$_mf_tree" diff -M --numstat "${_mf_base}...HEAD" 2>/dev/null \
                 | awk '{ a=$1; d=$2; if (a=="-") a=0; if (d=="-") d=0; t+=a+d } END { print t+0 }')"  # pipe-ok: awk consumes ALL input; no early exit
  case "$_mf_lines" in ''|*[!0-9]*) _mf_lines=0 ;; esac
  if [ "$_mf_lines" -gt "$_mf_maxl" ] 2>/dev/null; then
    HERD_REVIEW_MECH_FLOOR_REASON="$_mf_lines changed lines exceeds the floor's $_mf_maxl"
    return 1
  fi

  # Per-file shape. A single unrecognized file refuses the whole diff — the floor is all-or-nothing.
  while IFS=$'\t' read -r _mf_status _mf_path _mf_newpath; do
    [ -n "${_mf_status:-}" ] || continue
    case "$_mf_status" in
      R100)
        # (b) pure rename: 100% similarity means git proved the content is byte-identical.
        continue ;;
      R*|C*)
        # A rename/copy WITH edits — the edits are what a reviewer would read. Not mechanical.
        HERD_REVIEW_MECH_FLOOR_REASON="$_mf_path: rename/copy with content edits"
        return 1 ;;
    esac
    case "$_mf_path" in
      *.tsv)
        # (a) a manifest row edit.
        continue ;;
    esac
    # (c) version bump: prove it on this file's own patch.
    if _pregate_is_version_bump "$_mf_tree" "$_mf_base" "$_mf_path"; then
      continue
    fi
    HERD_REVIEW_MECH_FLOOR_REASON="$_mf_path: not a TSV row, pure rename, or version bump"
    return 1
  done <<< "$_mf_ns"

  HERD_REVIEW_MECH_FLOOR_REASON="$_mf_n file(s), $_mf_lines line(s): TSV-row / rename / version-bump shaped"
  return 0
}

# _pregate_is_version_bump <tree> <base> <path> — true iff EVERY changed line in this file's patch is
# a version bump: the removed lines and the added lines are the same lines, in the same order, once
# every dotted numeric token (1.2, 1.2.3, 10.4.0) is masked out. A pure addition or a pure deletion is
# NOT a bump (the counts differ) — a version bump replaces a line, it never introduces or removes one.
_pregate_is_version_bump() {
  local _vb_tree="$1" _vb_base="$2" _vb_path="$3" _vb_patch
  _vb_patch="$(git -C "$_vb_tree" diff -M "${_vb_base}...HEAD" -- "$_vb_path" 2>/dev/null)" || return 1
  [ -n "$_vb_patch" ] || return 1
  awk '
    # Skip the file headers: ---/+++ are metadata, not content lines.
    /^--- / || /^\+\+\+ / { next }
    /^-/ { s = substr($0, 2); gsub(/[0-9]+(\.[0-9]+)+/, "<V>", s); old[++no] = s; next }
    /^\+/ { s = substr($0, 2); gsub(/[0-9]+(\.[0-9]+)+/, "<V>", s); new[++nn] = s; next }
    END {
      if (no == 0 || no != nn) exit 1          # nothing changed, or an add/delete — not a bump
      for (i = 1; i <= no; i++) if (old[i] != new[i]) exit 1
      exit 0
    }
  ' <<< "$_vb_patch"
}

# ── CLI ───────────────────────────────────────────────────────────────────────────────────────────
# Executed (not sourced) form, so every caller runs this in its own subprocess and no builder-authored
# lint body is ever sourced into a long-lived watcher. Exit codes are the function contracts verbatim.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    lint)
      shift
      herd_review_pregate "${1:-.}" "${2:-${DEFAULT_BRANCH:-main}}"; _pg_cli_rc=$?
      [ "$_pg_cli_rc" -eq 2 ] && [ -n "$HERD_REVIEW_PREGATE_SKIP_REASON" ] \
        && printf 'pregate skipped: %s\n' "$HERD_REVIEW_PREGATE_SKIP_REASON" >&2
      exit "$_pg_cli_rc" ;;
    floor)
      shift
      herd_review_mech_floor "${1:-.}" "${2:-${DEFAULT_BRANCH:-main}}"; _pg_cli_rc=$?
      [ -n "$HERD_REVIEW_MECH_FLOOR_REASON" ] && printf '%s\n' "$HERD_REVIEW_MECH_FLOOR_REASON" >&2
      exit "$_pg_cli_rc" ;;
    *)
      printf 'usage: review-pregate.sh lint|floor <tree> [<base-ref>]\n' >&2
      exit 64 ;;
  esac
fi
