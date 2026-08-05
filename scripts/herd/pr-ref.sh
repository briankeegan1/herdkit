#!/usr/bin/env bash
# pr-ref.sh — THE ONE implementation of "given a PR body, print its explicit `Refs:` value" (HERD-522).
#
# WHY THIS FILE EXISTS
# --------------------
# The rule "the merged PR's `Refs: <id>` line is how work links back to the tracker" is read by FOUR
# independent surfaces, and until HERD-522 each carried its OWN copy of the regex:
#
#   • merge-time reconcile      agent-watch.sh's HERD_PR_REF_PY / herd_pr_ref_from_body, called from
#                               work-units/git-pr.sh (_reconcile_pr_ref → reconcile_backlog)
#   • the retroactive-link leg  sweep.sh (_sweep_relink_pr_rows) — already reused the snippet
#   • the stale-duplicate gate  stale-dup-gate.sh (stale_dup_extract_ref + a SECOND inline python in
#                               _stale_dup_merged_refs)
#   • the tracker-state sweep   tracker-state-sweep.sh (_merged_refs, a third inline python)
#
# Three of those said "MIRRORS agent-watch.sh" in a comment, which is what a copy always says right
# up until it drifts. Per the multi-seat doctrine (docs/multi-seat-doctrine.md, rule 2: one
# reconciled invariant, one shared check at every surface) they are now ONE parser, sourced here.
#
# THE DEFECT THAT FORCED THE UNIFICATION (GH #637, evidence emberglen-godot PR #125)
# ----------------------------------------------------------------------------------
# The parser anchored `Refs:` at COLUMN 0. A builder wrote its ref as a markdown HEADING —
# `## Refs: EMG-111` — and every surface above missed it in the same way and with the SAME silence:
# the merge landed, the reconcile fell through to the fuzzy path, the tracker item stayed open, and
# NOTHING said so. 29 of the 30 sibling PRs used a bare `Refs: X` and reconciled fine, so no rail
# ever went red — the classic herdkit failure shape of a guard whose SCAN SURFACE misses the defect.
#
# The two halves of the fix live here so they can never disagree:
#   (1) TOLERANT MATCHING — leading markdown decoration and whitespace are skipped (headings `#`,
#       list items `-`/`*`, blockquotes `>`, bold `**`), and a bold-wrapped `**Refs:**` closes
#       cleanly. This is a PURE WIDENING: `^[[:space:]]*` is a strict subset of the new prefix class,
#       so every body that matched before matches identically now.
#   (2) THE SILENT-MISS ALARM — herd_pr_ref_unparsed_line reports a body that MENTIONS `refs:`
#       (case-insensitive, anywhere) yet yields no ref. That is the shape #637 had, and it is exactly
#       what "the parser missed it with zero warning" means. The reconcile path journals
#       `reconcile_ref_unparsed` for it and the watcher renders a loud console row.
#
# THE RULES, in one place:
#   • STRIP HTML COMMENT BLOCKS FIRST. `gh pr view --json body` returns raw markdown with `<!-- … -->`
#     intact — GitHub does not strip them from a classic PULL_REQUEST_TEMPLATE.md. An example `Refs:`
#     buried in the template's own comment would otherwise poison every untracked PR (and, since
#     HERD-522, would fire a false silent-miss alarm on every one of them).
#   • The FIRST `Refs:` line, case-insensitive, anchored at line start THROUGH the decoration class
#     above; first whitespace-delimited token after the colon.
#   • STRIP TRAILING PUNCTUATION. `Refs: HERD-267,` and `Refs: HERD-267.` are the same ref as
#     `Refs: HERD-267`. Without this the sweep's shape test reads `267,` as "not an identifier" and
#     declares — with no lookup at all — that the item was never minted. `*` joined the strip set with
#     the decoration widening, so `**Refs: HERD-267**` yields `HERD-267` and not `HERD-267**`.
#   • A template PLACEHOLDER (`<…>`, none, n/a, na) is NOT a ref — and, deliberately, NOT a silent
#     miss either: it is an explicit "this PR tracks nothing", so it never raises the alarm.
#   • NO SHAPE TEST. What counts as an identifier belongs to the BACKEND, never to the engine — the
#     default `file` backend's item ref IS a title slug. sweep.sh documents at length what happened
#     the last time the engine hardcoded `KEY-42`. So `Refs: some-branch-slug` PARSES; only a body
#     whose `refs:` yields no token at all is a miss.
#
# CONTRACT: sourced (never executed) — it defines two shell functions plus the python snippet the
# JSON-array callers prepend to their own driver. Sourcing is idempotent and side-effect-free, so a
# surface that also sources a sibling which sources this file is safe. Bash 3.2 clean.

# HERD_PR_REF_PY — the python half, prepended to whichever driver the caller needs (one body on
# stdin, or a whole `gh pr list --json number,body` array). Same shape as backends/linear.sh's
# _LINEAR_PICK_STATE_PY. Exports three names:
#   pr_ref_from_body(body)      → the ref, or "" (no Refs: line / placeholder / no token)
#   pr_ref_unparsed_line(body)  → the offending line when the body MENTIONS refs: but yields no ref;
#                                 "" when a ref parsed, when nothing mentions refs:, or when the
#                                 mention is an explicit placeholder
#   pr_ref_declared_none(line)  → True for an explicit placeholder line (used by the two above)
#
# The decoration class `[\s#*>-]` is written with `-` LAST so it is a literal, not a range, in both
# python and the egrep fallback below.
HERD_PR_REF_PY='
import re
_PR_REF_PLACEHOLDER = {"none", "n/a", "na"}
_PR_REF_TRAILING = ".,;:!)]}*"
# leading decoration (heading/list/quote/bold) · "refs:" · a closing bold · the token
_PR_REF_LINE = re.compile(r"^[\s#*>-]*refs:\**\s*(\S+)", re.IGNORECASE)
# the LOOSE mention: any "refs:" anywhere on the line, however decorated or buried in prose
_PR_REF_MENTION = re.compile(r"refs:", re.IGNORECASE)

def _pr_ref_decomment(body):
    return re.sub(r"<!--.*?-->", "", body or "", flags=re.DOTALL)

def _pr_ref_token(line):
    """The raw token on an anchored Refs: line, trailing punctuation stripped. "" when the line does
    not match, or matches with nothing usable left after the strip."""
    m = _PR_REF_LINE.match(line)
    if not m:
        return ""
    return m.group(1).rstrip(_PR_REF_TRAILING)

def pr_ref_declared_none(line):
    """True when this line explicitly declares NO ref (the PR template placeholder). A declared none
    is a decision, not a miss — it never raises the silent-miss alarm."""
    tok = _pr_ref_token(line)
    return bool(tok) and (tok.startswith("<") or tok.lower() in _PR_REF_PLACEHOLDER)

def pr_ref_from_body(body):
    for line in _pr_ref_decomment(body).splitlines():
        if not _PR_REF_LINE.match(line):
            continue
        # FIRST anchored Refs: line decides — a placeholder there means "no ref", and we do NOT keep
        # scanning for a later line (pre-HERD-522 semantics, preserved exactly).
        tok = _pr_ref_token(line)
        if not tok or tok.startswith("<") or tok.lower() in _PR_REF_PLACEHOLDER:
            return ""
        return tok
    return ""

def pr_ref_unparsed_line(body, cap=200):
    """The SILENT-MISS probe. "" when the body has no refs: intent, when a ref parsed, or when the
    only mention is an explicit placeholder; otherwise the first offending line, whitespace-flattened
    and capped so it is safe to journal and to render on one console row."""
    body = _pr_ref_decomment(body)
    if pr_ref_from_body(body):
        return ""
    for line in body.splitlines():
        if not _PR_REF_MENTION.search(line):
            continue
        if pr_ref_declared_none(line):
            return ""
        flat = " ".join(line.split())
        return (flat[:cap - 1] + "…") if len(flat) > cap else flat
    return ""
'

# herd_pr_ref_from_body — read a PR body on stdin, print its `Refs:` value (empty when there is none).
# The shell-side entry point to HERD_PR_REF_PY.
#
# NO-PYTHON3 FALLBACK. python3 is a hard engine dep, but this function sits on the merge tail, and the
# pre-HERD-267 code degraded to a grep/sed pass rather than silently dropping every explicit ref onto
# the fuzzy path. That degradation is preserved: the comment strip is what needs python (a multi-line
# regex), so without it we grep the RAW body — the decoration-tolerant anchor, the punctuation strip
# and the placeholder guard are all still a partial defense, exactly as before.
herd_pr_ref_from_body() {
  local body ref
  body="$(cat)"
  if command -v python3 >/dev/null 2>&1; then
    ref="$(printf '%s' "$body" | python3 -c "$HERD_PR_REF_PY"'
import sys
sys.stdout.write(pr_ref_from_body(sys.stdin.read()))' 2>/dev/null)" && { printf '%s' "$ref"; return 0; }
  fi
  # Degraded path: same rules, minus the HTML-comment strip.
  ref="$(printf '%s\n' "$body" \
    | grep -iE '^[[:space:]#*>-]*Refs:[*]*[[:space:]]*[^[:space:]]' \
    | head -n1 \
    | sed -E 's/^[[:space:]#*>-]*[Rr][Ee][Ff][Ss]:[*]*[[:space:]]*//; s/[[:space:]].*$//; s/[.,;:!)}*]+$//' 2>/dev/null || true)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
  case "$ref" in
    ''|'<'*|none|None|NONE|n/a|N/A|na|NA) return 0 ;;
  esac
  printf '%s' "$ref"
}

# herd_pr_ref_unparsed_line — read a PR body on stdin; print the offending line when the body MENTIONS
# `refs:` yet yields no parseable ref, else nothing. The shell-side entry point to
# pr_ref_unparsed_line. Fail-soft to SILENCE: without python3 (or on any error) it prints nothing, so
# a degraded host raises no alarm rather than a wrong one — an alarm is only ever worth as much as its
# precision, and the reconcile it annotates already degrades to the fuzzy path on its own.
herd_pr_ref_unparsed_line() {
  local body
  body="$(cat)"
  [ -n "$body" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  printf '%s' "$body" | python3 -c "$HERD_PR_REF_PY"'
import sys
sys.stdout.write(pr_ref_unparsed_line(sys.stdin.read()))' 2>/dev/null || true
}
