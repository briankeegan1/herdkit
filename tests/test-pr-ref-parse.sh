#!/usr/bin/env bash
# test-pr-ref-parse.sh — hermetic proof of HERD-522 / GH #637: the merge-time reconcile no longer
# SILENTLY misses a markdown-decorated `Refs:` line.
#
# THE INCIDENT. emberglen-godot PR #125 wrote its tracker ref as a markdown HEADING —
# `## Refs: EMG-111`. Every `Refs:` parser in the engine anchored at column 0, so all of them missed
# it identically: the PR merged, the reconcile fell through to the fuzzy path, the tracker item stayed
# open, and NOTHING warned. 29 of the 30 sibling PRs used a bare `Refs: X` and reconciled fine, so no
# rail ever went red.
#
# WHAT THIS PROVES
#   (1) ONE PARSER — scripts/herd/pr-ref.sh is the only implementation; the four surfaces that read a
#       PR's tracker ref (reconcile, sweep's relink leg, the stale-dup gate, the tracker-state sweep)
#       all route through it and none carries a second copy of the regex.
#   (2) TOLERANT MATCHING — heading / list item / blockquote / bold decoration all parse, and it is a
#       PURE WIDENING: every previously-matching body still yields the same ref, byte for byte.
#   (3) NO SHAPE TEST — `Refs: some-title-slug` still parses (the default `file` backend's item ref
#       IS a slug; the shape question belongs to the backend, never the engine).
#   (4) THE SILENT-MISS ALARM — a body that DECLARES a ref and yields none journals a loud
#       `reconcile_ref_unparsed` event (pr + the offending line), writes one ledger row, and renders
#       through the shared bounded-console-section machinery. Once per PR, never twice. Declaration-
#       shaped means `refs:` is the first WORD on its line, so a decoration this parser does NOT know
#       (`1. Refs:`, `| Refs: |`, `<b>Refs:</b>`) alarms rather than vanishing — the alarm's whole job.
#   (5) SILENT WHEN HEALTHY — a placeholder, a template comment, a `refs:` buried in prose, and a
#       one-line json blob carrying a `"body":"Refs: X"` field all produce NO event, NO ledger row,
#       and an EMPTY console section (byte-identical console).
#   (6) DEGRADED HOST — with python3 shadowed the shell fallback still parses every decorated shape,
#       and the alarm goes quiet rather than guessing.
#
# Fully hermetic: temp dirs only, no network, no live watcher loop (AGENT_WATCH_LIB=1).
# Run:  bash tests/test-pr-ref-parse.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/herd/pr-ref.sh"
WATCH="$REPO/scripts/herd/agent-watch.sh"
GATE="$REPO/scripts/herd/stale-dup-gate.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS+1)); }

[ -f "$LIB" ]   || fail "scripts/herd/pr-ref.sh not found — the shared parser is gone"
[ -f "$WATCH" ] || fail "agent-watch.sh not found"
[ -f "$GATE" ]  || fail "stale-dup-gate.sh not found"

# ══ (1) ONE IMPLEMENTATION, SHARED ═══════════════════════════════════════════════════════════════
# The multi-seat rule (docs/multi-seat-doctrine.md rule 2) applied to the exact seam #637 broke: four
# surfaces, one parser. A second copy anywhere is how the fix drifts back out of a surface later.
grep -q 'HERD_PR_REF_PY' "$LIB" || fail "(1) pr-ref.sh no longer defines the shared snippet"
for surface in agent-watch.sh stale-dup-gate.sh tracker-state-sweep.sh work-units/git-pr.sh; do
  f="$REPO/scripts/herd/$surface"
  grep -qE 'pr-ref\.sh|herd_pr_ref_from_body|HERD_PR_REF_PY' "$f" \
    || fail "(1) $surface no longer routes through the shared Refs: parser"
done
# …and nobody re-derives the regex. The tell is a `Refs:` literal glued to a REGEX construct — the
# four shapes the copies actually used: `refs:\s`, `refs:\*`, `Refs:[ \t]`, `Refs:[[:space:]]`, plus
# the case-folded `[Rr][Ee][Ff][Ss]` bracket idiom. Prose that merely mentions `refs:` is not a copy.
REF_REGEX_TELL='efs:(\\s|\\\*|\[ \\t\]|\[\[:space:\]\])|\[Rr\]\[Ee\]\[Ff\]\[Ss\]'
grep -qE "$REF_REGEX_TELL" "$LIB" || fail "(1) the tell no longer matches pr-ref.sh itself — it cannot detect a copy"
for surface in agent-watch.sh sweep.sh stale-dup-gate.sh tracker-state-sweep.sh work-units/git-pr.sh; do
  f="$REPO/scripts/herd/$surface"
  grep -qE "$REF_REGEX_TELL" "$f" \
    && fail "(1) $surface carries its own Refs: regex again instead of reusing pr-ref.sh:
$(grep -nE "$REF_REGEX_TELL" "$f")"
done
ok; echo "PASS (1) one Refs: parser, reused at every surface, re-implemented at none"

# shellcheck source=/dev/null
. "$LIB" || fail "sourcing pr-ref.sh failed"
for fn in herd_pr_ref_from_body herd_pr_ref_unparsed_line herd_pr_ref_all_from_body; do
  command -v "$fn" >/dev/null 2>&1 || fail "pr-ref.sh does not define $fn"
done

_ref()      { printf '%s' "$1" | herd_pr_ref_from_body; }
_unparsed() { printf '%s' "$1" | herd_pr_ref_unparsed_line; }
_all()      { printf '%s' "$1" | herd_pr_ref_all_from_body; }

# ══ (2) TOLERANT MATCHING — the decoration shapes, including #637's own ═══════════════════════════
while IFS='|' read -r label body want; do
  [ -n "$label" ] || continue
  got="$(_ref "$body")"
  [ "$got" = "$want" ] || fail "(2) $label: '$body' → '$got', wanted '$want'"
done <<'CASES'
heading (GH #637)|## Refs: EMG-111|EMG-111
deeper heading|#### Refs: HERD-522|HERD-522
list item (dash)|- Refs: HERD-1|HERD-1
list item (star)|* Refs: HERD-2|HERD-2
bold label|**Refs:** HERD-3|HERD-3
bold-wrapped whole|**Refs: HERD-4**|HERD-4
blockquote|> Refs: HERD-5|HERD-5
quoted list item|> - Refs: HERD-6|HERD-6
heading + bold|## **Refs:** HERD-7|HERD-7
CASES
ok; echo "PASS (2) markdown-decorated Refs: lines parse — heading, list, quote, bold"

# ══ (3) PURE WIDENING — every previously-matching body yields the SAME ref ════════════════════════
# These are the shapes the pre-HERD-522 parser handled. Each must be byte-identical, or the widening
# quietly changed the meaning of 30 000 merged PRs' worth of history.
while IFS='|' read -r label body want; do
  [ -n "$label" ] || continue
  got="$(_ref "$body")"
  [ "$got" = "$want" ] || fail "(3) REGRESSION $label: '$body' → '$got', wanted '$want'"
done <<'CASES'
bare|Refs: HERD-522|HERD-522
leading whitespace|   Refs: HERD-8|HERD-8
lowercase|refs: HERD-9|HERD-9
uppercase|REFS: HERD-10|HERD-10
trailing comma|Refs: HERD-267,|HERD-267
trailing period|Refs: HERD-267.|HERD-267
extra words after|Refs: HERD-11 and some prose|HERD-11
placeholder angle|Refs: <ID>|
placeholder none|Refs: none|
placeholder n/a|Refs: N/A|
no refs line at all|just a body, nothing tracked|
CASES
# The HTML-comment strip (a PR-template example ref lives in a `<!-- … -->` block) still runs FIRST,
# and still runs first for the DECORATED forms too — a commented-out heading must not win either.
got="$(_ref "$(printf '<!-- Refs: HERD-DECOY -->\nRefs: HERD-267.\n')")"
[ "$got" = "HERD-267" ] || fail "(3) the HTML-comment decoy poisoned the extractor ('$got')"
got="$(_ref "$(printf '<!-- ## Refs: HERD-DECOY -->\n## Refs: EMG-111\n')")"
[ "$got" = "EMG-111" ] || fail "(3) a COMMENTED decorated ref was preferred over the real one ('$got')"
# FIRST anchored line wins, decorated or not — a later line never overrides it.
got="$(_ref "$(printf '## Refs: EMG-111\nRefs: HERD-999\n')")"
[ "$got" = "EMG-111" ] || fail "(3) the first Refs: line no longer wins ('$got')"
ok; echo "PASS (3) pure widening — every previously-matching body parses identically"

# ══ (4) NO SHAPE TEST — the backend owns what an identifier looks like ════════════════════════════
# sweep.sh documents at length what happened the last time the engine hardcoded `KEY-42`: on the
# default `file` backend, whose item ref IS a title slug, every healthy merged PR was declared
# "never minted" and duplicate-filed. A slug must parse, and must NOT raise the silent-miss alarm.
got="$(_ref '## Refs: healthcheck-sha-cache')"
[ "$got" = "healthcheck-sha-cache" ] || fail "(4) a file-backend slug ref stopped parsing ('$got')"
[ -z "$(_unparsed '## Refs: healthcheck-sha-cache')" ] || fail "(4) a slug ref wrongly alarmed"
ok; echo "PASS (4) a title-slug ref still parses — no engine-side shape test"

# ══ (5) THE SILENT-MISS PROBE ════════════════════════════════════════════════════════════════════
# A DECLARATION that yields nothing usable is the shape #637 had. Two things are deliberately NOT a
# miss: a bare word after the colon IS a legitimate ref on the file backend (see (4)), so "garbage"
# means a colon followed by nothing this parser can turn into a token, not a value it dislikes; and
# the alarm is declaration-shaped, not any `refs:` anywhere (see (6)).
#
# The last three rows are the alarm EARNING ITS KEEP: decorations the PARSER does not handle. Each is
# a plausible next #637, and each is caught loudly instead of silently — which is the whole point of
# having an alarm rather than only a wider regex.
_alarms() {  # <label> <body> — the body must raise the alarm
  [ -n "$(_unparsed "$2")" ] || fail "(5) $1: '$2' raised NO alarm — the silent miss is back"
}
_alarms 'empty value'                            'Refs:'
_alarms 'punctuation-only value'                 'Refs: .'
_alarms 'bold label, value on the next line'     '**Refs:**'
_alarms 'numbered list (parser does not handle)' '1. Refs: HERD-1'
_alarms 'table cell (parser does not handle)'    '| Refs: HERD-1 |'
_alarms 'html tag (parser does not handle)'      '<b>Refs:</b> HERD-1'
# The offending LINE is what gets reported — an operator must see WHY it did not parse.
got="$(_unparsed 'Refs: .')"
[ "$got" = "Refs: ." ] || fail "(5) the alarm reported '$got' instead of the offending line"
# …whitespace-flattened, so it can never inject a TAB (the ledger is TSV) or ragged padding into a
# console row.
got="$(_unparsed "$(printf '  \tRefs:\t \n')")"
[ "$got" = "Refs:" ] || fail "(5) the reported line was not whitespace-flattened: [$got]"
ok; echo "PASS (5) a refs: mention that parses to nothing is reported, with the offending line"

# ══ (6) SILENT WHEN HEALTHY — no false alarms ════════════════════════════════════════════════════
# An alarm is worth exactly its precision. These are the shapes that must stay quiet, and the last
# two are not hypothetical — the heavy gate caught BOTH firing before the probe was narrowed from
# "any refs: on the line" to "refs: is the first word on the line".
_quiet() {  # <label> <body> — the body must NOT raise the alarm
  local got; got="$(_unparsed "$2")"
  [ -z "$got" ] || fail "(6) $1 wrongly alarmed with '$got'"
}
_quiet 'a parsed bare ref'            'Refs: HERD-522'
_quiet 'a parsed decorated ref'       '## Refs: EMG-111'
_quiet 'an explicit placeholder'      'Refs: <ID>'
_quiet 'an explicit none'             'Refs: none'
_quiet 'a body with no refs: at all'  'just a body, nothing tracked'
_quiet 'refs: buried in prose'        'the reconcile parses the refs: line at merge time'
# A `gh` stub that ignores `-q .body` hands the WHOLE json object over as the body — one line, with a
# `"body":"Refs: X"` field inside it. Read as a failed declaration, that alarmed on every merged PR in
# the sim suite (and, with the notify that used to fire here, leaked a desktop notification per PR).
_quiet 'a one-line json blob' '{"state":"MERGED","headRefName":"sim/feat-1","body":"Refs: HERD-236"}'
# The PR-TEMPLATE comment block is the highest-volume false-alarm risk: EVERY untracked PR in a repo
# with a classic PULL_REQUEST_TEMPLATE.md carries a commented-out `Refs:` example.
_quiet 'a PR-template comment' "$(printf '<!-- Refs: <ID> -->\nno tracker item for this one\n')"
ok; echo "PASS (6) quiet for a parsed ref, a placeholder, a template comment, prose, and a json blob"

# ══ (7) DEGRADED HOST — python3 shadowed ═════════════════════════════════════════════════════════
# python3 is a hard engine dep, but the parser sits on the merge tail and has always degraded to a
# grep/sed pass rather than dropping every explicit ref onto the fuzzy path. The decoration
# tolerance degrades WITH it (same widened anchor), and the alarm degrades to SILENCE — a probe that
# cannot be precise must not be loud.
NOPY="$(
  # shellcheck source=/dev/null
  . "$LIB"
  python3() { return 127; }
  for b in 'Refs: HERD-267.' '## Refs: EMG-111' '- Refs: HERD-1' '**Refs:** HERD-2' '**Refs: HERD-3**' '> Refs: HERD-4'; do
    printf '%s\n' "$(printf '%s' "$b" | herd_pr_ref_from_body)"
  done
  printf 'ALARM=[%s]\n' "$(printf 'Refs: .' | herd_pr_ref_unparsed_line)"
)"
[ "$NOPY" = "$(printf 'HERD-267\nEMG-111\nHERD-1\nHERD-2\nHERD-3\nHERD-4\nALARM=[]')" ] \
  || fail "(7) the no-python3 fallback returned:
$NOPY"
ok; echo "PASS (7) without python3 the decorated shapes still parse and the alarm stays quiet"

# ══ (8) THE JSON-ARRAY COMPOSITION the three list-callers share ══════════════════════════════════
# sweep.sh's relink leg, stale-dup-gate's merged-refs query and tracker-state-sweep's _merged_refs all
# prepend HERD_PR_REF_PY to their own `gh pr list --json number,body` driver. Prove the composition
# itself works — a snippet that only ever ran under `-c` in one file is a snippet with one user.
cat > "$T/prs.json" <<'JSON'
[{"number": 125, "body": "Implements the thing.\n\n## Refs: EMG-111\n"},
 {"number": 126, "body": "<!-- Refs: HERD-DECOY -->\nno ref\n"},
 {"number": 127, "body": "- Refs: HERD-7\n"}]
JSON
got="$(python3 -c "$HERD_PR_REF_PY"'
import sys, json
for p in json.load(sys.stdin):
    r = pr_ref_from_body(p.get("body") or "")
    if r:
        print("%s\t%s" % (p["number"], r))
' < "$T/prs.json")" || fail "(8) the JSON-array composition failed to run"
[ "$got" = "$(printf '125\tEMG-111\n127\tHERD-7')" ] || fail "(8) JSON-array extraction returned:
$got"
ok; echo "PASS (8) the shared snippet composes into the JSON-array drivers"

# ══ (9) THE STALE-DUP GATE reads the SAME ref ════════════════════════════════════════════════════
# The duplicate check compares this PR's ref against merged PRs' refs. If it read a decorated ref
# differently from the reconcile, a decorated re-ship of already-merged work would sail through the
# one gate built to catch it.
GATE_REF="$(
  # shellcheck source=/dev/null
  . "$GATE" >/dev/null 2>&1 || exit 1
  printf '## Refs: EMG-111\n' | stale_dup_extract_ref
)"
[ "$GATE_REF" = "EMG-111" ] || fail "(9) stale_dup_extract_ref returned '$GATE_REF' for a heading ref"
GATE_REF="$(
  # shellcheck source=/dev/null
  . "$GATE" >/dev/null 2>&1 || exit 1
  printf 'Refs: HERD-267,\n' | stale_dup_extract_ref
)"
[ "$GATE_REF" = "HERD-267" ] \
  || fail "(9) stale_dup_extract_ref returned '$GATE_REF' — it still drops the trailing-punctuation defense"
ok; echo "PASS (9) the stale-duplicate gate reads refs identically to the reconcile"

# ══ (9b) MULTI-REF (HERD-587, GH #708) — pr_ref_all_from_body / herd_pr_ref_all_from_body ═════════
# PR #708 carried FOUR bare 'Refs:' lines; three of the four tracker items sat open for two hours
# because every parser above is single-valued — it answers "what is THE ref", so it only ever returns
# the first. pr_ref_all_from_body is the set-valued sibling the merge-reconcile leg now walks: every
# anchored line, decoration-tolerant exactly like pr_ref_from_body, duplicates collapsed, first-seen
# order preserved.
got="$(_all "$(printf 'Refs: HERD-1\nRefs: HERD-2\nRefs: HERD-3\n')")"
[ "$got" = "$(printf 'HERD-1\nHERD-2\nHERD-3')" ] || fail "(9b) three bare Refs: lines → '$got', wanted HERD-1/2/3 in order"

# decoration-tolerant, same shapes as (2).
got="$(_all "$(printf '## Refs: HERD-1\n- Refs: HERD-2\n**Refs:** HERD-3\n')")"
[ "$got" = "$(printf 'HERD-1\nHERD-2\nHERD-3')" ] || fail "(9b) decorated multi-ref lines → '$got'"

# duplicates collapsed, first-seen order kept.
got="$(_all "$(printf 'Refs: HERD-1\nRefs: HERD-2\nRefs: HERD-1\n')")"
[ "$got" = "$(printf 'HERD-1\nHERD-2')" ] || fail "(9b) duplicate ref line not collapsed: '$got'"

# a single-ref body is the n=1 case — identical to pr_ref_from_body's answer.
got="$(_all 'Refs: HERD-522')"
[ "$got" = "HERD-522" ] || fail "(9b) single-ref body regressed: '$got'"

# a placeholder line does NOT abort the scan — unlike pr_ref_from_body (see (3): "the first Refs: line
# no longer wins" is deliberately NOT this function's rule), a later real ref still counts.
got="$(_all "$(printf 'Refs: <ID>\nRefs: HERD-9\n')")"
[ "$got" = "HERD-9" ] || fail "(9b) a placeholder line wrongly blanked out a later real ref: '$got'"
got_single="$(_ref "$(printf 'Refs: <ID>\nRefs: HERD-9\n')")"
[ -z "$got_single" ] || fail "(9b) pr_ref_from_body regressed on the same placeholder-first body: '$got_single'"

# no refs at all → empty.
got="$(_all 'just a body, nothing tracked')"
[ -z "$got" ] || fail "(9b) a ref-less body produced output: '$got'"

# the HTML-comment strip still runs first — a commented decoy must never appear in the set.
got="$(_all "$(printf '<!-- Refs: HERD-DECOY -->\nRefs: HERD-267\nRefs: HERD-268\n')")"
[ "$got" = "$(printf 'HERD-267\nHERD-268')" ] || fail "(9b) an HTML-comment decoy leaked into the multi-ref set: '$got'"
ok; echo "PASS (9b) pr_ref_all_from_body extracts every distinct ref, decoration-tolerant, dedup'd, comment-safe"

# ── (9c) DEGRADED HOST — python3 shadowed, multi-ref fallback ────────────────────────────────────
NOPY_ALL="$(
  # shellcheck source=/dev/null
  . "$LIB"
  python3() { return 127; }
  printf '%s' "$(printf 'Refs: HERD-1\n## Refs: HERD-2\nRefs: HERD-1\nRefs: <ID>\n')" | herd_pr_ref_all_from_body
)"
[ "$NOPY_ALL" = "$(printf 'HERD-1\nHERD-2')" ] \
  || fail "(9c) the no-python3 multi-ref fallback returned: $NOPY_ALL"
ok; echo "PASS (9c) without python3 the multi-ref extraction still dedups, decorates and skips placeholders"

# ══ (9d) HERD-613 — PER-BACKEND SHAPE GUARD ═══════════════════════════════════════════════════════
# PRs 712/719: an auto-spawned builder carried a `Refs:` line full of comma-joined TEST FILENAMES
# instead of a tracker id — a non-empty token that, pre-HERD-613, parsed clean under (4)'s "no shape
# test" rule and then sat forever as an unresolvable ESCALATED tracker-heal row. Under a backend with
# a KNOWN tracker-id shape (linear/jira: TEAM-NUMBER; github: optional-hash-digits), a token that does
# not conform is now treated exactly like an empty/placeholder token: pr_ref_from_body yields nothing
# and the silent-miss alarm reports it instead. The default `file` backend (and anything else this
# repo's suite never sets SCRIBE_BACKEND to) stays completely exempt — (4) above already proves that,
# unconditionally, since none of these tests ever export SCRIBE_BACKEND.
_ref_be()      { SCRIBE_BACKEND="$1" bash -c ". '$LIB'; printf '%s' \"\$1\" | herd_pr_ref_from_body" _ "$2"; }
_unparsed_be() { SCRIBE_BACKEND="$1" bash -c ". '$LIB'; printf '%s' \"\$1\" | herd_pr_ref_unparsed_line" _ "$2"; }
_all_be()      { SCRIBE_BACKEND="$1" bash -c ". '$LIB'; printf '%s' \"\$1\" | herd_pr_ref_all_from_body" _ "$2"; }

got="$(_ref_be linear 'Refs: HERD-613')"
[ "$got" = "HERD-613" ] || fail "(9d) a shape-valid linear ref stopped parsing under SCRIBE_BACKEND=linear: '$got'"
got="$(_unparsed_be linear 'Refs: HERD-613')"
[ -z "$got" ] || fail "(9d) a shape-valid linear ref wrongly alarmed: '$got'"

got="$(_ref_be linear 'Refs: test-py-merge-fairness.sh,test-py-live-runtime.sh')"
[ -z "$got" ] || fail "(9d) the PR-712/719 comma-joined-filenames shape parsed as a literal ref under linear: '$got'"
got="$(_unparsed_be linear 'Refs: test-py-merge-fairness.sh,test-py-live-runtime.sh')"
[ "$got" = "Refs: test-py-merge-fairness.sh,test-py-live-runtime.sh" ] \
  || fail "(9d) the PR-712/719 shape did not route to the silent-miss alarm: '$got'"

got="$(_ref_be github 'Refs: #45')"
[ "$got" = "#45" ] || fail "(9d) a shape-valid github ref stopped parsing under SCRIBE_BACKEND=github: '$got'"
got="$(_ref_be github 'Refs: 45')"
[ "$got" = "45" ] || fail "(9d) a bare-digits github ref stopped parsing: '$got'"
got="$(_ref_be github 'Refs: HERD-522')"
[ -z "$got" ] || fail "(9d) a linear-shaped ref wrongly parsed under SCRIBE_BACKEND=github: '$got'"

# the default (unset) backend, and any backend this map does not name, stay exempt — a title slug
# still parses under EVERY unnamed backend, never just 'file'.
got="$(_ref_be changelog 'Refs: healthcheck-sha-cache')"
[ "$got" = "healthcheck-sha-cache" ] || fail "(9d) a slug ref stopped parsing under an unnamed backend (changelog): '$got'"

# pr_ref_all_from_body: a shape-invalid line is SKIPPED (scan continues), not an abort — mirrors how a
# placeholder line is skipped in (9b), not treated as a first-line veto.
got="$(_all_be linear "$(printf 'Refs: test-a.sh,test-b.sh\nRefs: HERD-9\n')")"
[ "$got" = "HERD-9" ] || fail "(9d) a shape-invalid line wrongly blanked out a later valid multi-ref line: '$got'"
ok; echo "PASS (9d) a backend-shape-invalid Refs: token never parses as a literal ref, and alarms instead"

# ── herd_pr_ref_shape_ok / herd_pr_ref_find_in_text — the standalone wrappers LEG 1 reuses ────────
. "$LIB"
herd_pr_ref_shape_ok "HERD-613" linear || fail "(9d) herd_pr_ref_shape_ok rejected a valid linear shape"
! herd_pr_ref_shape_ok "not-a-tracker-id.sh" linear \
  || fail "(9d) herd_pr_ref_shape_ok accepted a shape-invalid token under linear"
herd_pr_ref_shape_ok "anything-goes" file || fail "(9d) herd_pr_ref_shape_ok rejected a slug under the file backend"

got="$(printf 'https://linear.app/herdkit/issue/HERD-613/guard-ref-shape' | herd_pr_ref_find_in_text linear)"
[ "$got" = "HERD-613" ] || fail "(9d) herd_pr_ref_find_in_text did not pull HERD-613 out of a linear issue URL: '$got'"
got="$(printf 'https://github.com/org/repo/issues/45' | herd_pr_ref_find_in_text github)"
[ "$got" = "45" ] || fail "(9d) herd_pr_ref_find_in_text did not pull 45 out of a github issue URL: '$got'"
got="$(printf 'no id anywhere in this text' | herd_pr_ref_find_in_text linear)"
[ -z "$got" ] || fail "(9d) herd_pr_ref_find_in_text fabricated a ref out of text with none: '$got'"
got="$(printf 'https://linear.app/herdkit/issue/HERD-613/x' | herd_pr_ref_find_in_text file)"
[ -z "$got" ] || fail "(9d) herd_pr_ref_find_in_text returned a ref for a backend with no fixed shape (file): '$got'"
ok; echo "PASS (9d) herd_pr_ref_shape_ok / herd_pr_ref_find_in_text — the LEG 1 create-output helpers"

# ══ Fixture for the watcher-side legs (10)–(12) ══════════════════════════════════════════════════
MAIN="$T/main"; TREES="$T/trees"
mkdir -p "$MAIN/.herd" "$TREES/.herd"
cat > "$MAIN/.herd/config" <<EOF
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH=main
EOF
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"
export AGENT_WATCH_LIB=1 HERD_DRIVER=headless HERMETIC_TEST=1
export HERD_CONFIG_FILE="$MAIN/.herd/config"
export PROJECT_ROOT="$MAIN" WORKTREES_DIR="$TREES" WORKSPACE_NAME="pr-ref-test"
export DEFAULT_BRANCH="origin/main" NO_COLOR=1
export JOURNAL_FILE="$T/journal.jsonl"
: > "$JOURNAL_FILE"

# ══ (10) THE ALARM: one journal event + one ledger row, per PR ═══════════════════════════════════
OUT="$(
  # shellcheck source=/dev/null
  . "$WATCH" >/dev/null 2>&1 || exit 1
  _reconcile_ref_unparsed_alarm 125 "$(printf 'Implements it.\n\nRefs:\n')"
  _reconcile_ref_unparsed_alarm 125 "$(printf 'Implements it.\n\nRefs:\n')"   # re-entered tick: silent
  _reconcile_ref_unparsed_alarm 126 "$(printf 'Refs: HERD-7\n')"              # parses: no alarm
  _reconcile_ref_unparsed_alarm 127 "$(printf 'nothing tracked here\n')"      # no mention: no alarm
  printf 'LEDGER=%s\n' "$REF_UNPARSED_FILE"
)" || fail "(10) sourcing agent-watch.sh (lib mode) / running the alarm failed"
LEDGER="${OUT#LEDGER=}"; LEDGER="$(printf '%s' "$LEDGER" | tail -n1)"
[ -s "$LEDGER" ] || fail "(10) the alarm wrote no ledger row"
[ "$(grep -c . "$LEDGER")" -eq 1 ] \
  || fail "(10) expected exactly ONE ledger row (once per PR), got $(grep -c . "$LEDGER"):
$(cat "$LEDGER")"
grep -q '	125	' "$LEDGER" || fail "(10) the ledger row does not name PR 125: $(cat "$LEDGER")"
[ "$(grep -c 'reconcile_ref_unparsed' "$JOURNAL_FILE")" -eq 1 ] \
  || fail "(10) expected exactly ONE reconcile_ref_unparsed event, got $(grep -c 'reconcile_ref_unparsed' "$JOURNAL_FILE")"
grep -q '"pr": *125' "$JOURNAL_FILE" || fail "(10) the event carries no pr field: $(cat "$JOURNAL_FILE")"
grep -q '"line":' "$JOURNAL_FILE"    || fail "(10) the event carries no offending line: $(cat "$JOURNAL_FILE")"
ok; echo "PASS (10) the silent miss journals reconcile_ref_unparsed once per PR, with the line"

# ══ (11) THE CONSOLE ROW — rendered through the shared bounded-section machinery ═════════════════
ROW="$(
  # shellcheck source=/dev/null
  . "$WATCH" >/dev/null 2>&1 || exit 1
  build_ref_unparsed
  printf '%s' "$REF_UNPARSED_ROWS"
)" || fail "(11) build_ref_unparsed failed"
[ -n "$ROW" ] || fail "(11) the alarm ledger rendered NO console row — the miss is still silent"
case "$ROW" in *"#125"*) : ;; *) fail "(11) the row does not name the PR: $ROW" ;; esac
case "$ROW" in *unlinked*) : ;; *) fail "(11) the row is not labelled unlinked: $ROW" ;; esac
# LOUD by classification: a 3h-old row (past CONSOLE_ROW_RETENTION) must NOT age out — the merge
# landed and the item is still open, so time makes it worse, not stale.
OLD="$(
  # shellcheck source=/dev/null
  . "$WATCH" >/dev/null 2>&1 || exit 1
  printf '%s\t%s\t%s\n' "$(( $(date +%s) - 10800 ))" 900 'Refs:' > "$REF_UNPARSED_FILE"
  build_ref_unparsed
  printf '%s' "$REF_UNPARSED_ROWS"
)"
case "$OLD" in *"#900"*) : ;; *) fail "(11) a 3h-old unlinked-merge row aged out of the display" ;; esac
ok; echo "PASS (11) the miss renders as a loud console row that never ages out"

# ══ (12) BYTE-IDENTICAL WHEN HEALTHY — empty ledger ⇒ no section at all ══════════════════════════
EMPTY="$(
  # shellcheck source=/dev/null
  . "$WATCH" >/dev/null 2>&1 || exit 1
  : > "$REF_UNPARSED_FILE"
  build_ref_unparsed
  printf '[%s]' "$REF_UNPARSED_ROWS"
)"
[ "$EMPTY" = "[]" ] || fail "(12) an empty ledger still rendered rows: $EMPTY"
GONE="$(
  # shellcheck source=/dev/null
  . "$WATCH" >/dev/null 2>&1 || exit 1
  rm -f "$REF_UNPARSED_FILE"
  build_ref_unparsed
  printf '[%s]' "$REF_UNPARSED_ROWS"
)"
[ "$GONE" = "[]" ] || fail "(12) a missing ledger still rendered rows: $GONE"
ok; echo "PASS (12) a repo whose refs all parse renders no section — console byte-identical"

echo "ALL PASS ($PASS checks)"
