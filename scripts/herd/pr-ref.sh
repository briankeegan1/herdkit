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
# CONTRACT: sourced (never executed) — it defines shell functions plus the python snippet the
# JSON-array callers prepend to their own driver. Sourcing is idempotent and side-effect-free, so a
# surface that also sources a sibling which sources this file is safe. Bash 3.2 clean.

# HERD_PR_REF_PY — the python half, prepended to whichever driver the caller needs (one body on
# stdin, or a whole `gh pr list --json number,body` array). Same shape as backends/linear.sh's
# _LINEAR_PICK_STATE_PY. Exports four names:
#   pr_ref_from_body(body)      → THE ref, or "" (no Refs: line / placeholder / no token) — the FIRST
#                                 anchored line decides, single-valued (see its own docstring)
#   pr_ref_all_from_body(body)  → EVERY distinct ref (HERD-587), a list, in first-seen order — every
#                                 anchored line contributes, set-valued (see its own docstring)
#   pr_ref_unparsed_line(body)  → the offending line when the body DECLARES a ref but yields none;
#                                 "" when a ref parsed, when no line is declaration-shaped, or when
#                                 the declaration is an explicit placeholder
#   pr_ref_declared_none(line)  → True for an explicit placeholder line (used by the two above)
#
# The decoration class `[\s#*>-]` is written with `-` LAST so it is a literal, not a range, in both
# python and the egrep fallback below.
HERD_PR_REF_PY='
import os
import re
_PR_REF_PLACEHOLDER = {"none", "n/a", "na"}
_PR_REF_TRAILING = ".,;:!)]}*"
# leading decoration (heading/list/quote/bold) · "refs:" · a closing bold · the token
_PR_REF_LINE = re.compile(r"^[\s#*>-]*refs:\**\s*(\S+)", re.IGNORECASE)

# HERD-613: per-backend tracker-id SHAPE, for the backends whose identifiers truly have ONE fixed
# shape (uppercase-letters-dash-digits for linear/jira, e.g. HERD-123; optional-hash-digits for
# github, e.g. #45). A backend not named here (the default `file` backend, whose item ref IS a title
# slug — see test (4) in tests/test-pr-ref-parse.sh — plus changelog and anything future) is EXEMPT:
# this is a NARROWING of, never a repeal of, the pr-ref.sh "NO SHAPE TEST" invariant from HERD-522 —
# the shape question still belongs to the backend, never the engine, for every backend that has no
# one fixed shape.
_PR_REF_BACKEND_SHAPES = {
    "linear": re.compile(r"^[A-Z][A-Z0-9]*-[0-9]+$"),
    "jira":   re.compile(r"^[A-Z][A-Z0-9]*-[0-9]+$"),
    "github": re.compile(r"^#?[0-9]+$"),
}
# The FIND-anywhere counterpart, used to pull a real ref out of free-form text (a backend create
# call'"'"'s own URL/identifier output) rather than out of an anchored `Refs:` line — see
# pr_ref_find_in_text. Linear/jira URLs embed the identifier as its own path segment
# (".../issue/HERD-123/some-title-slug"); github issue-create returns ".../issues/<num>".
_PR_REF_BACKEND_FIND = {
    "linear": re.compile(r"\b([A-Z][A-Z0-9]*-[0-9]+)\b"),
    "jira":   re.compile(r"\b([A-Z][A-Z0-9]*-[0-9]+)\b"),
    "github": re.compile(r"/issues/([0-9]+)\b|(?:^|[\s#])([0-9]+)\s*$"),
}

def _pr_ref_backend():
    return (os.environ.get("SCRIBE_BACKEND") or "file").strip().lower()

def pr_ref_shape_ok(token, backend=None):
    """True when <token> conforms to <backend>'"'"'s known tracker-id SHAPE (HERD-613), or when the
    backend defines no fixed shape at all — that stays quiet-by-design (see _PR_REF_BACKEND_SHAPES)."""
    pat = _PR_REF_BACKEND_SHAPES.get((backend or _pr_ref_backend()))
    return True if pat is None else bool(pat.match(token))

def pr_ref_find_in_text(text, backend=None):
    """Best-effort: the FIRST substring of <text> that conforms to <backend>'"'"'s tracker-id SHAPE —
    for pulling a real ref out of a backend create call'"'"'s own output (a URL or bare identifier),
    NEVER out of a PR body (pr_ref_from_body owns that, anchored at a `Refs:` line). "" when the
    backend defines no fixed shape or none is found; callers must treat that as UNKNOWN and never
    fabricate a ref from it."""
    pat = _PR_REF_BACKEND_FIND.get((backend or _pr_ref_backend()))
    if pat is None or not text:
        return ""
    m = pat.search(text)
    if not m:
        return ""
    for g in m.groups():
        if g:
            return g
    return m.group(0)
# DECLARATION-SHAPED, the alarm'"'"'s wider net: `refs:` is the first WORD on the line, whatever sits in
# front of it, so long as none of it is a word itself. That admits every decoration this parser does
# NOT yet know — a numbered list (`1. Refs:`), a table cell (`| Refs: |`), an HTML tag
# (`<b>Refs:</b>`), a bullet glyph — which is exactly the alarm'"'"'s job: to catch the decoration AFTER
# this one. It excludes a `refs:` buried in PROSE ("see the refs: line") and, importantly, one buried
# in a one-line JSON blob — a `gh` stub that ignores `-q .body` hands the whole `{"state":…,"body":
# "Refs: X"}` object over as the body, and treating that as a failed declaration alarms on every
# merged PR in the sim suite.
_PR_REF_MENTION = re.compile(
    r"^[^0-9A-Za-z]*(?:\d+[.)][^0-9A-Za-z]*)?(?:<[A-Za-z/][^>]*>[^0-9A-Za-z]*)*refs:", re.IGNORECASE)

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
    backend = _pr_ref_backend()
    for line in _pr_ref_decomment(body).splitlines():
        if not _PR_REF_LINE.match(line):
            continue
        # FIRST anchored Refs: line decides — a placeholder there means "no ref", and we do NOT keep
        # scanning for a later line (pre-HERD-522 semantics, preserved exactly).
        tok = _pr_ref_token(line)
        if not tok or tok.startswith("<") or tok.lower() in _PR_REF_PLACEHOLDER:
            return ""
        # HERD-613: a token that does not conform to the ACTIVE backend'"'"'s known tracker-id shape is
        # never a literal ref — treated exactly like an empty/placeholder token so the caller (the
        # silent-miss alarm below) reports it instead of a builder or the tracker-heal sweep ever
        # probing it. PRs 712/719: an auto-spawned builder wrote a comma-joined list of failing TEST
        # FILENAMES as its own `Refs:` line — a non-empty token that used to parse clean and then sat
        # forever as an unresolvable ESCALATED tracker-heal row with no operator clear path.
        if not pr_ref_shape_ok(tok, backend):
            return ""
        return tok
    return ""

def pr_ref_all_from_body(body):
    """EVERY distinct ref from EVERY anchored Refs: line in the body (HERD-587), in first-seen order,
    duplicates collapsed. Unlike pr_ref_from_body, a placeholder line does NOT stop the scan — it is
    just skipped, so a later real Refs: line still counts. This is a DIFFERENT contract from
    pr_ref_from_body, on purpose: pr_ref_from_body answers a single-valued question ("what is THE
    ref"), so a placeholder-first body must yield none, not skip ahead; this answers a set-valued
    question ("which trackers does this PR carry"), so a stray placeholder line among several real
    refs should not blank out the real ones."""
    seen = []
    backend = _pr_ref_backend()
    for line in _pr_ref_decomment(body).splitlines():
        if not _PR_REF_LINE.match(line):
            continue
        tok = _pr_ref_token(line)
        if not tok or tok.startswith("<") or tok.lower() in _PR_REF_PLACEHOLDER:
            continue
        if not pr_ref_shape_ok(tok, backend):    # HERD-613: skip this line, keep scanning others
            continue
        if tok not in seen:
            seen.append(tok)
    return seen

def pr_ref_unparsed_line(body, cap=200):
    """The SILENT-MISS probe. "" when no line DECLARES a ref, when a ref parsed, or when the
    declaration is an explicit placeholder; otherwise the first offending line, whitespace-flattened
    and capped so it is safe to journal and to render on one console row."""
    body = _pr_ref_decomment(body)
    if pr_ref_from_body(body):
        return ""
    for line in body.splitlines():
        if not _PR_REF_MENTION.match(line):
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

# herd_pr_ref_all_from_body — read a PR body on stdin, print EVERY distinct `Refs:` value (HERD-587),
# one per line, in first-seen order; nothing when the body carries none. The shell-side entry point to
# pr_ref_all_from_body — see its docstring for how this differs from herd_pr_ref_from_body's single-
# valued "first line decides" contract.
#
# NO-PYTHON3 FALLBACK, same posture as herd_pr_ref_from_body: minus the HTML-comment strip, every
# matching line (not just the first) runs through the same decoration-tolerant anchor + punctuation
# strip + placeholder guard, then duplicates are collapsed.
herd_pr_ref_all_from_body() {
  local body out rc
  body="$(cat)"
  if command -v python3 >/dev/null 2>&1; then
    out="$(printf '%s' "$body" | python3 -c "$HERD_PR_REF_PY"'
import sys
for r in pr_ref_all_from_body(sys.stdin.read()):
    print(r)' 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      [ -n "$out" ] && printf '%s\n' "$out"
      return 0
    fi
  fi
  # Degraded path: same rules as herd_pr_ref_from_body, minus the HTML-comment strip, every line.
  printf '%s\n' "$body" \
    | grep -iE '^[[:space:]#*>-]*Refs:[*]*[[:space:]]*[^[:space:]]' \
    | sed -E 's/^[[:space:]#*>-]*[Rr][Ee][Ff][Ss]:[*]*[[:space:]]*//; s/[[:space:]].*$//; s/[.,;:!)}*]+$//' \
    | grep -viE '^(<.*|none|n/a|na)$' \
    | awk '!seen[$0]++' 2>/dev/null || true
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

# herd_pr_ref_shape_ok <token> [backend] — HERD-613: true (exit 0) when <token> conforms to
# [backend]'s (default: $SCRIBE_BACKEND, else "file") known tracker-id shape, or when that backend
# defines no fixed shape at all. The shell-side entry point to pr_ref_shape_ok. Fail-soft: no python3
# → trusts the token (exit 0) — a shape probe that cannot run must never manufacture a false alarm.
herd_pr_ref_shape_ok() {
  local _sok_tok="$1" _sok_backend="${2:-${SCRIBE_BACKEND:-file}}"
  command -v python3 >/dev/null 2>&1 || return 0
  TOK="$_sok_tok" BACKEND="$_sok_backend" python3 -c "$HERD_PR_REF_PY"'
import os, sys
sys.exit(0 if pr_ref_shape_ok(os.environ["TOK"], os.environ["BACKEND"]) else 1)' 2>/dev/null
}

# herd_pr_ref_find_in_text <backend> — read free-form text on stdin (a backend create call's OWN
# URL/identifier output — NEVER a PR body; herd_pr_ref_from_body owns that job), print the FIRST
# substring conforming to <backend>'s tracker-id shape, or nothing when the backend has no fixed shape
# or none is found. The shell-side entry point to pr_ref_find_in_text. Callers must treat empty output
# as UNKNOWN and never fabricate a ref from it. Fail-soft: no python3 → prints nothing.
herd_pr_ref_find_in_text() {
  local _fit_backend="${1:-${SCRIBE_BACKEND:-file}}" _fit_text
  _fit_text="$(cat)"
  [ -n "$_fit_text" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  printf '%s' "$_fit_text" | BACKEND="$_fit_backend" python3 -c "$HERD_PR_REF_PY"'
import os, sys
sys.stdout.write(pr_ref_find_in_text(sys.stdin.read(), os.environ.get("BACKEND")))' 2>/dev/null || true
}
